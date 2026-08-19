import Foundation

/// One-stop dispatcher that pushes a meeting (transcript + summary) to all
/// currently-enabled integrations: Hermes, Obsidian, and any custom webhooks.
///
/// Used by:
/// - `MeetingController` automatically when a recording finishes.
/// - `MeetingDetailView` on-demand via the "Send to integrations" button —
///   so the user can re-push after editing the title, re-summarizing, or
///   importing a file.
///
/// Failures are logged but never thrown — one bad integration shouldn't
/// take the others down with it.
///
/// `@MainActor`-isolated because both call sites (`MeetingController`,
/// `MeetingDetailView`) are MainActor and the dependencies it touches
/// (`CustomWebhookStore.shared`, `DebugLog.shared`) are too.
@MainActor
struct IntegrationFanout {

    struct Result: Equatable {
        var sent: [String]
        var failed: [String]
        var skipped: [String]

        var isEmpty: Bool { sent.isEmpty && failed.isEmpty }
        var summary: String {
            var parts: [String] = []
            if !sent.isEmpty   { parts.append("sent: \(sent.joined(separator: ", "))") }
            if !failed.isEmpty { parts.append("failed: \(failed.joined(separator: ", "))") }
            return parts.joined(separator: " · ")
        }
    }

    /// Names of every integration the user has switched on. Drives the
    /// enabled-state of the "Send to integrations" button.
    static var enabledNames: [String] {
        var names: [String] = []
        if HermesIntegration.isEnabled   { names.append("Hermes") }
        if KirosIntegration.isEnabled    { names.append("Kiros") }
        if ObsidianIntegration.isEnabled { names.append("Obsidian") }
        for hook in CustomWebhookStore.shared.enabled {
            names.append(hook.name)
        }
        return names
    }

    static var hasAnyEnabled: Bool { !enabledNames.isEmpty }

    @discardableResult
    static func send(meeting: Meeting,
                     transcriptMarkdown: String,
                     summaryMarkdown: String,
                     audioFileURL: URL?) async -> Result {
        var sent: [String] = []
        var failed: [String] = []
        var skipped: [String] = []

        if HermesIntegration.isEnabled {
            do {
                let status = try await HermesIntegration.send(
                    meeting: meeting,
                    transcriptMarkdown: transcriptMarkdown,
                    summaryMarkdown: summaryMarkdown
                )
                let ok = status < 400
                DebugLog.shared.log(icon: "🌐", label: "Hermes sent",
                                    value: "HTTP \(status)", ok: ok)
                if ok { sent.append("Hermes") } else { failed.append("Hermes") }
            } catch {
                DebugLog.shared.log(icon: "🌐", label: "Hermes failed",
                                    value: "\(error)", ok: false)
                failed.append("Hermes")
            }
        } else {
            skipped.append("Hermes")
        }

        if KirosIntegration.isEnabled {
            do {
                let status = try await KirosIntegration.send(
                    meeting: meeting,
                    transcriptMarkdown: transcriptMarkdown,
                    summaryMarkdown: summaryMarkdown
                )
                let ok = status < 400
                DebugLog.shared.log(icon: "🗂️", label: "Kiros sent",
                                    value: status == -1 ? "skipped (unconfigured)" : "HTTP \(status)",
                                    ok: ok)
                if ok { sent.append("Kiros") } else { failed.append("Kiros") }
            } catch {
                DebugLog.shared.log(icon: "🗂️", label: "Kiros failed",
                                    value: "\(error)", ok: false)
                failed.append("Kiros")
            }
        } else {
            skipped.append("Kiros")
        }

        if ObsidianIntegration.isEnabled {
            do {
                let url = try ObsidianIntegration.write(
                    meeting: meeting,
                    transcriptMarkdown: transcriptMarkdown,
                    summaryMarkdown: summaryMarkdown,
                    audioFileURL: audioFileURL
                )
                DebugLog.shared.log(icon: "📓", label: "Obsidian written",
                                    value: url?.lastPathComponent ?? "no path")
                sent.append("Obsidian")
            } catch {
                DebugLog.shared.log(icon: "📓", label: "Obsidian failed",
                                    value: "\(error)", ok: false)
                failed.append("Obsidian")
            }
        } else {
            skipped.append("Obsidian")
        }

        let values = MustacheRenderer.values(
            for: meeting,
            transcriptMarkdown: transcriptMarkdown,
            summaryMarkdown: summaryMarkdown
        )
        for hook in CustomWebhookStore.shared.enabled {
            let url: URL
            do {
                url = try IntegrationURL.validated(hook.urlString)
            } catch {
                DebugLog.shared.log(icon: "🪝",
                                    label: "Webhook \"\(hook.name)\" rejected URL",
                                    value: "\(hook.urlString): \(error.localizedDescription)", ok: false)
                failed.append(hook.name)
                continue
            }
            // JSON payloads must escape interpolated values so a transcript with
            // a quote/newline can't break the JSON or inject sibling keys.
            let isJSON = hook.contentType.lowercased().contains("json")
            let body = isJSON
                ? MustacheRenderer.renderJSON(hook.payloadTemplate, values: values)
                : MustacheRenderer.render(hook.payloadTemplate, values: values)
            let secret = (try? KeychainStore.string(forKey: hook.keychainKey)) ?? nil
            let webhook = OutboundWebhook(url: url,
                                           secret: secret,
                                           extraHeaders: hook.headers)
            do {
                let status = try await webhook.post(body: Data(body.utf8),
                                                     contentType: hook.contentType)
                let ok = status < 400
                DebugLog.shared.log(icon: "🪝",
                                    label: "Webhook \"\(hook.name)\" sent",
                                    value: "HTTP \(status)", ok: ok)
                if ok { sent.append(hook.name) } else { failed.append(hook.name) }
            } catch {
                DebugLog.shared.log(icon: "🪝",
                                    label: "Webhook \"\(hook.name)\" failed",
                                    value: "\(error)", ok: false)
                failed.append(hook.name)
            }
        }

        return Result(sent: sent, failed: failed, skipped: skipped)
    }
}

// MARK: - Shared integration URL validation

/// Validates a user-supplied integration URL before we POST a transcript to it.
/// Requires `https` so transcripts never leave over cleartext, with an explicit
/// exception for loopback hosts (localhost / 127.0.0.1 / ::1) over plain http so
/// a locally-run ingest endpoint still works. Any other scheme (plain http to a
/// remote host, file, ftp, ...) is rejected. Top-level (non-isolated) so the
/// non-MainActor HermesIntegration can call it too.
enum IntegrationURL {

    enum ValidationError: LocalizedError, Equatable {
        case malformed(String)
        case insecureScheme(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let s):
                return "Invalid integration URL: \(s)"
            case .insecureScheme(let s):
                return "Integration URL must use https (http allowed only for localhost): \(s)"
            }
        }
    }

    /// Hosts permitted to use plain `http`.
    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// Returns a validated `URL` or throws `ValidationError`.
    static func validated(_ string: String) throws -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else {
            throw ValidationError.malformed(string)
        }
        if scheme == "https" { return url }
        if scheme == "http", loopbackHosts.contains(host) { return url }
        throw ValidationError.insecureScheme(string)
    }
}
