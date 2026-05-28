import Foundation

/// One-shot pass that retroactively fills in missing voiceprint embeddings
/// and re-runs auto-matching across already-recorded meetings.
///
/// **Why this exists.** Until the recent embedder fix, voiceprint capture
/// silently hung on long files (the old synchronous resampler). Every
/// profile the user saved during that window was persisted as
/// name-only — the JSON file landed but the embedding never did. As a
/// result the Settings → People list looks like "no voice prints" even
/// though seven profiles exist on disk, and auto-naming has been
/// effectively dead for months. This routine:
///
/// 1. **Backfill.** For each profile that has a `sourceMeetingID` +
///    `sourceSpeakerLetter` but no `embedding`, re-load that meeting's
///    transcript + audio and run the (now-working) embedder.
/// 2. **Auto-match.** Once the candidate profile pool has real embeddings
///    again, walk every meeting that was diarized and re-run
///    `VoiceMatcher.match` to fill in `speakerNames` entries that the
///    user hasn't already set manually.
///
/// Both steps are idempotent: backfill skips profiles that already have
/// embeddings; the matcher already refuses to overwrite manual names
/// ([VoiceMatcher.swift:62]).
///
/// Runs at app launch on a background Task so it never blocks the menu
/// bar coming up. macOS 14+ only (FluidAudio's floor) — the whole thing
/// is a no-op on older versions.
@MainActor
enum VoiceProfileBackfill {

    /// Kicks off backfill in the background. Safe to call multiple times.
    static func runAtLaunch(meetingStore: MeetingStore,
                             profileStore: VoiceProfileStore) {
        guard #available(macOS 14.0, *) else { return }
        Task { @MainActor in
            await runOnce(meetingStore: meetingStore, profileStore: profileStore)
        }
    }

    @available(macOS 14.0, *)
    static func runOnce(meetingStore: MeetingStore,
                         profileStore: VoiceProfileStore) async {
        let backfillCount = await backfillMissingEmbeddings(
            meetingStore: meetingStore,
            profileStore: profileStore
        )
        let matchCount = await rematchExistingMeetings(
            meetingStore: meetingStore,
            profileStore: profileStore
        )
        if backfillCount > 0 || matchCount > 0 {
            DebugLog.shared.log(icon: "👥", label: "Voice backfill done",
                                value: "captured=\(backfillCount) · matched=\(matchCount)")
        }
    }

    // MARK: - Step 1: backfill missing embeddings

    @available(macOS 14.0, *)
    private static func backfillMissingEmbeddings(
        meetingStore: MeetingStore,
        profileStore: VoiceProfileStore
    ) async -> Int {
        // Snapshot the candidate list. Each iteration reloads the profile
        // from the store so we see fresh `hasEmbedding` after a successful
        // capture earlier in the same run.
        let initial = profileStore.profiles.filter {
            !$0.hasEmbedding
                && $0.sourceMeetingID != nil
                && $0.sourceSpeakerLetter != nil
        }
        guard !initial.isEmpty else { return 0 }

        DebugLog.shared.log(icon: "👥", label: "Voice backfill start",
                            value: "\(initial.count) profile(s) missing embeddings")

        var captured = 0
        for stale in initial {
            // Re-read in case a prior iteration touched it.
            guard let profile = profileStore.profiles.first(where: { $0.id == stale.id }),
                  !profile.hasEmbedding,
                  let meetingID = profile.sourceMeetingID,
                  let letter = profile.sourceSpeakerLetter else { continue }

            guard let meeting = meetingStore.meetings.first(where: { $0.id == meetingID }) else {
                DebugLog.shared.log(icon: "👥", label: "Voice backfill skipped",
                                    value: "\(profile.name) · source meeting not found",
                                    ok: false)
                continue
            }
            guard let transcript = try? meetingStore.loadTranscript(for: meeting) else {
                DebugLog.shared.log(icon: "👥", label: "Voice backfill skipped",
                                    value: "\(profile.name) · transcript unreadable",
                                    ok: false)
                continue
            }
            guard let audioURL = meetingStore.audioFileURL(for: meeting) else {
                DebugLog.shared.log(icon: "👥", label: "Voice backfill skipped",
                                    value: "\(profile.name) · audio file missing",
                                    ok: false)
                continue
            }

            do {
                try await VoiceProfileEmbedder.capture(
                    profile: profile,
                    speakerLetter: letter,
                    in: transcript,
                    audioURL: audioURL,
                    store: profileStore
                )
                captured += 1
            } catch {
                DebugLog.shared.log(icon: "👥", label: "Voice backfill failed",
                                    value: "\(profile.name) · \(error.localizedDescription)",
                                    ok: false)
            }
        }
        return captured
    }

    // MARK: - Step 2: re-run match across existing meetings

    @available(macOS 14.0, *)
    private static func rematchExistingMeetings(
        meetingStore: MeetingStore,
        profileStore: VoiceProfileStore
    ) async -> Int {
        let candidates = profileStore.profiles.filter { $0.hasEmbedding }
        guard !candidates.isEmpty else { return 0 }

        var meetingsMatched = 0
        for meeting in meetingStore.meetings {
            guard let transcript = try? meetingStore.loadTranscript(for: meeting) else { continue }
            // Only worth running when diarization actually populated speakerID
            // and at least one letter still has no manual name. The matcher
            // already refuses to overwrite existing entries; this gate just
            // saves the cost of resampling each meeting's audio.
            let speakerLetters = Set(transcript.segments.compactMap { $0.speakerID })
            guard !speakerLetters.isEmpty else { continue }
            let named = Set((meeting.speakerNames ?? [:]).keys)
            guard !speakerLetters.isSubset(of: named) else { continue }

            guard let audioURL = meetingStore.audioFileURL(for: meeting) else { continue }

            let matches = await VoiceMatcher.match(
                meeting: meeting,
                transcript: transcript,
                audioURL: audioURL,
                store: meetingStore,
                profileStore: profileStore
            )
            if !matches.isEmpty { meetingsMatched += 1 }
        }
        return meetingsMatched
    }
}
