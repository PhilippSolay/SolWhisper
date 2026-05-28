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
            guard let url = URL(string: hook.urlString) else {
                DebugLog.shared.log(icon: "🪝",
                                    label: "Webhook \"\(hook.name)\" bad URL",
                                    value: hook.urlString, ok: false)
                failed.append(hook.name)
                continue
            }
            let body = MustacheRenderer.render(hook.payloadTemplate, values: values)
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
