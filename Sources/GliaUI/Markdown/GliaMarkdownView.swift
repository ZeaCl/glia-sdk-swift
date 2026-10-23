#if canImport(SwiftUI)
import SwiftUI

/// Main Markdown renderer view for assistant message bubbles and streaming responses.
public struct GliaMarkdownView: View {
    private let markdown: String
    private let theme: GliaTheme
    private let isStreaming: Bool

    public init(
        markdown: String,
        theme: GliaTheme,
        isStreaming: Bool = false
    ) {
        self.markdown = markdown
        self.theme = theme
        self.isStreaming = isStreaming
    }

    public var body: some View {
        let blocks = GliaMarkdownParser.parse(markdown)

        if blocks.isEmpty {
            // Render plain text fallback if empty or purely unparsed
            Text(markdown)
                .font(.body)
                .foregroundColor(theme.agentBubbleTextColor)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    renderBlock(block)
                }
            }
        }
    }

    @ViewBuilder
    private func renderBlock(_ block: GliaMarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            GliaInlineMarkdownText(
                text,
                color: theme.agentBubbleTextColor,
                font: .body,
                linkColor: theme.primaryColor
            )

        case .heading(let level, let text):
            GliaInlineMarkdownText(
                text,
                color: theme.agentBubbleTextColor,
                font: headingFont(for: level),
                linkColor: theme.primaryColor
            )
            .padding(.top, 2)

        case .codeBlock(let language, let code):
            GliaCodeBlockView(
                language: language,
                code: code,
                theme: theme
            )

        case .table(let headers, let rows):
            GliaTableView(
                headers: headers,
                rows: rows,
                theme: theme
            )

        case .blockquote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.primaryColor)
                    .frame(width: 3)

                GliaInlineMarkdownText(
                    text,
                    color: theme.textMutedColor,
                    font: .body.italic(),
                    linkColor: theme.primaryColor
                )
            }
            .padding(.vertical, 2)

        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .foregroundColor(theme.primaryColor)
                            .font(.body.bold())
                        GliaInlineMarkdownText(
                            item,
                            color: theme.agentBubbleTextColor,
                            font: .body,
                            linkColor: theme.primaryColor
                        )
                    }
                }
            }

        case .numberedList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(item.number).")
                            .foregroundColor(theme.textMutedColor)
                            .font(.body.monospacedDigit())
                        GliaInlineMarkdownText(
                            item.text,
                            color: theme.agentBubbleTextColor,
                            font: .body,
                            linkColor: theme.primaryColor
                        )
                    }
                }
            }

        case .divider:
            Divider()
                .background(theme.tableBorderColor)
                .padding(.vertical, 4)
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1:
            return .title2.bold()
        case 2:
            return .title3.bold()
        case 3:
            return .headline.bold()
        case 4:
            return .subheadline.bold()
        default:
            return .body.bold()
        }
    }
}
#endif
