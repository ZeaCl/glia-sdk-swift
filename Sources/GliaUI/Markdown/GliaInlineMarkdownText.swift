#if canImport(SwiftUI)
import SwiftUI

/// Renders inline markdown text (bold, italic, strikethrough, inline code, and links) using native AttributedString.
public struct GliaInlineMarkdownText: View {
    private let text: String
    private let color: Color
    private let font: Font
    private let linkColor: Color

    public init(
        _ text: String,
        color: Color,
        font: Font = .body,
        linkColor: Color = .blue
    ) {
        self.text = text
        self.color = color
        self.font = font
        self.linkColor = linkColor
    }

    public var body: some View {
        if let attributed = parseAttributedString(text) {
            Text(attributed)
                .font(font)
                .foregroundColor(color)
                .tint(linkColor)
        } else {
            Text(text)
                .font(font)
                .foregroundColor(color)
        }
    }

    private func parseAttributedString(_ string: String) -> AttributedString? {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return try? AttributedString(markdown: string, options: options)
    }
}
#endif
