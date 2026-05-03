import CoreGraphics
import Foundation

/// Vision returns observations bottom-up (its Y axis is Cartesian — origin at
/// the lower-left corner of the image). The post-processor sorts them top-to-
/// bottom, optionally joins wrapped lines, and preserves paragraph breaks
/// detected from large vertical gaps.
public struct LineObservation: Sendable {
    public let text: String
    public let confidence: Float
    public let boundingBox: CGRect    // Vision-normalized [0, 1], Y goes up

    public init(text: String, confidence: Float = 1, boundingBox: CGRect) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

public enum LineBreakMode: String, Sendable, Codable {
    case keep
    case remove
}

public enum OCRPostProcessor {

    /// Threshold for "this is a paragraph break, not a line wrap": current gap
    /// between two lines exceeds 1.6× the median line height in the document.
    static let paragraphGapMultiplier: CGFloat = 1.6

    public static func process(_ observations: [LineObservation],
                                mode: LineBreakMode) -> String {
        guard !observations.isEmpty else { return "" }

        // Vision Y is bottom-up — larger maxY = higher on screen. Sort
        // descending so the first element is the topmost line.
        let sorted = observations.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }

        switch mode {
        case .keep:
            return sorted.map(\.text).joined(separator: "\n")
                          .trimmingCharacters(in: .whitespacesAndNewlines)
        case .remove:
            return joinAcrossWraps(sorted)
        }
    }

    /// Joins wrapped lines within paragraphs, preserves paragraph breaks
    /// across large vertical gaps, collapses runs of whitespace.
    private static func joinAcrossWraps(_ lines: [LineObservation]) -> String {
        guard !lines.isEmpty else { return "" }
        let heights = lines.map { $0.boundingBox.height }.sorted()
        let median = heights[heights.count / 2]
        let gapThreshold = max(median * paragraphGapMultiplier, 0.0001)

        var paragraphs: [String] = []
        var current: [String] = [lines[0].text]

        for i in 1..<lines.count {
            let prev = lines[i - 1]
            let cur = lines[i]
            // prev's bottom in Vision-Y is `minY`; cur's top is `maxY`.
            // Since we're walking top-to-bottom, prev is higher on screen
            // (larger maxY), so the gap between them is `prev.minY - cur.maxY`.
            let gap = prev.boundingBox.minY - cur.boundingBox.maxY
            if gap > gapThreshold {
                paragraphs.append(current.joined(separator: " "))
                current = [cur.text]
            } else {
                current.append(cur.text)
            }
        }
        paragraphs.append(current.joined(separator: " "))

        let joined = paragraphs.joined(separator: "\n\n")
        return collapseWhitespace(joined)
    }

    private static func collapseWhitespace(_ s: String) -> String {
        // Collapse runs of horizontal whitespace into a single space without
        // touching the `\n\n` paragraph separators.
        var result = ""
        result.reserveCapacity(s.count)
        var prevWasSpace = false
        for ch in s {
            if ch == " " || ch == "\t" {
                if !prevWasSpace {
                    result.append(" ")
                    prevWasSpace = true
                }
            } else {
                result.append(ch)
                prevWasSpace = false
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
