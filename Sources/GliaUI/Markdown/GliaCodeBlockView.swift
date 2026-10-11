#if canImport(SwiftUI)
import SwiftUI

/// Renders a multiline code block with monospaced font, contrast background, language tag, and copy-to-clipboard action.
public struct GliaCodeBlockView: View {
    private let language: String?
    private let code: String
    private let theme: GliaTheme

    @State private var isCopied: Bool = false

    public init(
        language: String?,
        code: String,
        theme: GliaTheme
    ) {
        self.language = language
        self.code = code
        self.theme = theme
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: Language badge & copy button
            HStack {
                Text((language?.uppercased() ?? "CODE"))
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(theme.textMutedColor)

                Spacer()

                Button(action: copyToClipboard) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                        Text(isCopied ? "Copied" : "Copy")
                            .font(.caption2)
                    }
                    .foregroundColor(isCopied ? theme.primaryColor : theme.textMutedColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.3))

            // Code content with horizontal scroll
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundColor(theme.codeBlockTextColor)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.codeBlockBackground)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private func copyToClipboard() {
        GliaClipboard.copy(code)
        withAnimation {
            isCopied = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                withAnimation {
                    isCopied = false
                }
            }
        }
    }
}
#endif
