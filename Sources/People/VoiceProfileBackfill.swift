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
        // Every profile without an embedding is a candidate. We previously
        // required `sourceMeetingID + sourceSpeakerLetter` already on the
        // profile, but the seven existing profiles in the field were saved
        // before those fields were populated (the Settings → People "Add
        // name" path still creates pure name-stubs), so the strict gate made
        // the whole backfill a no-op for everyone. The name-fallback below
        // catches those by scanning meetings for a `speakerNames` mapping
        // matching the profile name.
        let initial = profileStore.profiles.filter { !$0.hasEmbedding }
        guard !initial.isEmpty else { return 0 }

        DebugLog.shared.log(icon: "👥", label: "Voice backfill start",
                            value: "\(initial.count) profile(s) missing embeddings")

        var captured = 0
        for stale in initial {
            // Re-read in case a prior iteration touched it.
            guard let profile = profileStore.profiles.first(where: { $0.id == stale.id }),
                  !profile.hasEmbedding else { continue }

            // Resolve which (meeting, speakerLetter) supplies this profile's
            // audio. Prefer the explicit link, BUT reject the channel-level
            // aliases (`__other__` / `__me__`) — those tag the mic vs system
            // channel, not a diarized speaker letter, so the embedder's
            // `segments.speakerID == letter` filter would always match zero
            // segments and silently fail. When we see one, fall back to the
            // name search across diarized meetings; if THAT works, the
            // search updates the link to a real letter for next time.
            let source: (meeting: Meeting, letter: String)?
            let hasUsableLink = profile.sourceMeetingID != nil
                && profile.sourceSpeakerLetter != nil
                && profile.sourceSpeakerLetter != "__other__"
                && profile.sourceSpeakerLetter != "__me__"
            if hasUsableLink,
               let meetingID = profile.sourceMeetingID,
               let letter = profile.sourceSpeakerLetter,
               let meeting = meetingStore.meetings.first(where: { $0.id == meetingID }) {
                source = (meeting, letter)
            } else {
                source = findSourceByName(
                    profileName: profile.name,
                    meetingStore: meetingStore
                )
            }

            guard let (meeting, letter) = source else {
                DebugLog.shared.log(icon: "👥", label: "Voice backfill skipped",
                                    value: "\(profile.name) · no diarized meeting names this person yet",
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

            // If we resolved via name-fallback, stamp the link back onto the
            // profile so the next run takes the fast path. Done BEFORE the
            // expensive capture call so a crash mid-capture still leaves
            // useful state behind.
            if profile.sourceMeetingID == nil || profile.sourceSpeakerLetter == nil {
                var updated = profile
                updated.sourceMeetingID = meeting.id
                updated.sourceSpeakerLetter = letter
                profileStore.update(updated)
            }

            // Persistent-log every transition so silent hangs in
            // FluidAudio model download or audio resample are diagnosable
            // from the file log without needing the in-app Debug panel.
            DebugLog.shared.log(icon: "👥", label: "Voice backfill capture",
                                value: "\(profile.name) · meeting=\(meeting.id.uuidString.prefix(8)) · letter=\(letter) · audio=\(audioURL.lastPathComponent)",
                                ok: false)
            let current = profileStore.profiles.first(where: { $0.id == profile.id }) ?? profile
            // Force the heavy capture onto the cooperative pool with an
            // explicit detached Task, so a modal alert holding MainActor
            // (the launch-time permissions prompt is the canonical example)
            // can never block the resample + embedding-extraction work.
            // The function's own `MainActor.run { store.update(...) }` for
            // the final persist will queue and run when MainActor is freed
            // — by then the expensive work is already done.
            let result: Result<Void, Error> = await Task.detached(priority: .background) {
                do {
                    try await VoiceProfileEmbedder.capture(
                        profile: current,
                        speakerLetter: letter,
                        in: transcript,
                        audioURL: audioURL,
                        store: profileStore
                    )
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success:
                DebugLog.shared.log(icon: "👥", label: "Voice backfill captured",
                                    value: "\(profile.name) ✓",
                                    ok: false)
                captured += 1
            case .failure(let error):
                DebugLog.shared.log(icon: "👥", label: "Voice backfill failed",
                                    value: "\(profile.name) · \(error.localizedDescription)",
                                    ok: false)
            }
        }
        return captured
    }

    /// Searches every meeting for a `speakerNames` entry mapping any letter
    /// to `profileName` (case-insensitive), and picks the candidate where
    /// that letter has the most `speakerID`-tagged transcript segments —
    /// the richer the audio signal, the better the embedding. Returns nil
    /// if no diarized meeting references the name yet.
    ///
    /// Internal (not `private`) so the unit tests can exercise the search
    /// logic without spinning up the embedder + audio I/O.
    @available(macOS 14.0, *)
    static func findSourceByName(
        profileName: String,
        meetingStore: MeetingStore
    ) -> (meeting: Meeting, letter: String)? {
        let target = profileName.lowercased()
        var best: (meeting: Meeting, letter: String, signalCount: Int)?

        for meeting in meetingStore.meetings {
            guard let names = meeting.speakerNames, !names.isEmpty else { continue }
            // Letters mapping to this profile name in this meeting.
            let letters = names
                .filter { $0.value.lowercased() == target }
                .map { $0.key }
            guard !letters.isEmpty else { continue }
            guard let transcript = try? meetingStore.loadTranscript(for: meeting) else { continue }
            // Count how many segments each candidate letter actually tags.
            for letter in letters {
                let count = transcript.segments.filter { $0.speakerID == letter }.count
                guard count > 0 else { continue }
                if best == nil || count > best!.signalCount {
                    best = (meeting, letter, count)
                }
            }
        }
        guard let best else { return nil }
        DebugLog.shared.log(icon: "👥", label: "Voice backfill resolved",
                            value: "\(profileName) → meeting \(best.meeting.id.uuidString.prefix(8)) · speaker \(best.letter) · \(best.signalCount) segments")
        return (best.meeting, best.letter)
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
