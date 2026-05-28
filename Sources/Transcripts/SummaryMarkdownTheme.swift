import MarkdownUI
import SwiftUI

extension Theme {
    /// Tuned for the summary card in `MeetingDetailView` — denser than the
    /// MarkdownUI default, with a heading scale that doesn't overpower the
    /// surrounding chrome and tables that read cleanly on the panel's
    /// translucent background.
    static let solwhisperSummary = Theme()
        .text {
            FontSize(13)
            ForegroundColor(.primary)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
            BackgroundColor(Color.secondary.opacity(0.18))
        }
        .strong { FontWeight(.semibold) }
        .link { ForegroundColor(.accentColor) }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(20)
                }
                .markdownMargin(top: 4, bottom: 6)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(16)
                }
                .markdownMargin(top: 16, bottom: 6)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(14)
                }
                .markdownMargin(top: 12, bottom: 4)
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.18))
                .markdownMargin(top: 0, bottom: 8)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.2))
        }
        .bulletedListMarker(.disc)
        .numberedListMarker(.decimal)
        .blockquote { configuration in
            configuration.label
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.5))
                        .frame(width: 2)
                }
                .markdownTextStyle { ForegroundColor(.secondary) }
        }
        .codeBlock { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.2))
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(12)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .markdownMargin(top: 6, bottom: 10)
        }
        .table { configuration in
            configuration.label
                .markdownTableBorderStyle(
                    .init(color: .secondary.opacity(0.35))
                )
                .markdownMargin(top: 8, bottom: 12)
        }
        .tableCell { configuration in
            configuration.label
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .markdownTextStyle {
                    FontSize(12)
                }
        }
        .thematicBreak {
            Divider().padding(.vertical, 6)
        }
}
