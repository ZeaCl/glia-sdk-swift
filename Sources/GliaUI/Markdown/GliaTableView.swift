#if canImport(SwiftUI)
import SwiftUI

/// Renders a Markdown table using SwiftUI's native Grid component (iOS 16+, macOS 13+).
public struct GliaTableView: View {
    private let headers: [String]
    private let rows: [[String]]
    private let theme: GliaTheme

    public init(
        headers: [String],
        rows: [[String]],
        theme: GliaTheme
    ) {
        self.headers = headers
        self.rows = rows
        self.theme = theme
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                // Header row
                GridRow {
                    ForEach(0..<headers.count, id: \.self) { col in
                        GliaInlineMarkdownText(
                            headers[col],
                            color: theme.agentBubbleTextColor,
                            font: .caption.bold(),
                            linkColor: theme.primaryColor
                        )
                        .padding(.vertical, 4)
                    }
                }

                // Header separator line spanning across grid
                Divider()
                    .background(theme.tableBorderColor)
                    .gridCellColumns(max(headers.count, 1))

                // Data rows
                ForEach(0..<rows.count, id: \.self) { rowIndex in
                    let row = rows[rowIndex]
                    GridRow {
                        ForEach(0..<headers.count, id: \.self) { colIndex in
                            let cellText = colIndex < row.count ? row[colIndex] : ""
                            GliaInlineMarkdownText(
                                cellText,
                                color: theme.agentBubbleTextColor,
                                font: .caption,
                                linkColor: theme.primaryColor
                            )
                            .padding(.vertical, 2)
                        }
                    }
                    if rowIndex < rows.count - 1 {
                        Divider()
                            .background(theme.tableBorderColor.opacity(0.4))
                            .gridCellColumns(max(headers.count, 1))
                    }
                }
            }
            .padding(12)
        }
        .background(theme.tableHeaderBackground)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(theme.tableBorderColor, lineWidth: 1)
        )
    }
}
#endif
