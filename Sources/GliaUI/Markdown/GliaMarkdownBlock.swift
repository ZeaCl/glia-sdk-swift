#if canImport(SwiftUI)
import SwiftUI

/// Structural representation of Markdown content blocks
public enum GliaMarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case codeBlock(language: String?, code: String)
    case table(headers: [String], rows: [[String]])
    case blockquote(text: String)
    case bulletList(items: [String])
    case numberedList(items: [NumberedListItem])
    case divider

    public struct NumberedListItem: Equatable, Sendable {
        public let number: Int
        public let text: String

        public init(number: Int, text: String) {
            self.number = number
            self.text = text
        }
    }
}
#endif
