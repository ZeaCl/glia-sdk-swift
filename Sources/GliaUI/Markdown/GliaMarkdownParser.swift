#if canImport(SwiftUI)
import Foundation

/// Fast, zero-dependency Markdown block parser optimized for real-time streaming LLM outputs.
public struct GliaMarkdownParser {
    public static func parse(_ markdown: String) -> [GliaMarkdownBlock] {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var blocks: [GliaMarkdownBlock] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines between blocks
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // 1. Code Block: Starts with ``` or ~~~
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fencePrefix = trimmed.hasPrefix("```") ? "```" : "~~~"
                let langRaw = trimmed.dropFirst(fencePrefix.count).trimmingCharacters(in: .whitespaces)
                let language = langRaw.isEmpty ? nil : langRaw
                var codeLines: [String] = []
                i += 1

                while i < lines.count {
                    let nextTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.hasPrefix(fencePrefix) {
                        // Closing fence
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(language: language, code: codeLines.joined(separator: "\n")))
                continue
            }

            // 2. Horizontal Divider: ---, ***, ___
            if isDivider(trimmed) {
                blocks.append(.divider)
                i += 1
                continue
            }

            // 3. Headings: # to ######
            if let heading = parseHeading(trimmed) {
                blocks.append(heading)
                i += 1
                continue
            }

            // 4. Blockquotes: Lines starting with >
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let curTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    guard curTrimmed.hasPrefix(">") else { break }
                    let stripped = stripQuotePrefix(curTrimmed)
                    quoteLines.append(stripped)
                    i += 1
                }
                blocks.append(.blockquote(text: quoteLines.joined(separator: "\n")))
                continue
            }

            // 5. Table: Line with | followed by separator line with | --- |
            if line.contains("|") && i + 1 < lines.count && isTableSeparator(lines[i + 1]) {
                let headers = parseTableRow(line)
                i += 2 // skip header and separator
                var rows: [[String]] = []
                while i < lines.count {
                    let curTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !curTrimmed.isEmpty, lines[i].contains("|") else { break }
                    rows.append(parseTableRow(lines[i]))
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            // 6. Bullet Lists: -, *, +
            if isBulletListItem(trimmed) {
                var items: [String] = []
                while i < lines.count {
                    let curTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    guard isBulletListItem(curTrimmed) else { break }
                    items.append(stripBulletPrefix(curTrimmed))
                    i += 1
                }
                blocks.append(.bulletList(items: items))
                continue
            }

            // 7. Numbered Lists: 1. , 2. , etc.
            if let firstNumbered = parseNumberedListItem(trimmed) {
                var items: [GliaMarkdownBlock.NumberedListItem] = [firstNumbered]
                i += 1
                while i < lines.count {
                    let curTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    guard let numbered = parseNumberedListItem(curTrimmed) else { break }
                    items.append(numbered)
                    i += 1
                }
                blocks.append(.numberedList(items: items))
                continue
            }

            // 8. Paragraph: Default block
            var paragraphLines: [String] = [line]
            i += 1
            while i < lines.count {
                let nextLine = lines[i]
                let nextTrimmed = nextLine.trimmingCharacters(in: .whitespaces)

                // Stop paragraph at blank line or next structural block
                if nextTrimmed.isEmpty ||
                    nextTrimmed.hasPrefix("```") ||
                    nextTrimmed.hasPrefix("~~~") ||
                    isDivider(nextTrimmed) ||
                    parseHeading(nextTrimmed) != nil ||
                    nextTrimmed.hasPrefix(">") ||
                    isBulletListItem(nextTrimmed) ||
                    parseNumberedListItem(nextTrimmed) != nil ||
                    (nextLine.contains("|") && i + 1 < lines.count && isTableSeparator(lines[i + 1])) {
                    break
                }
                paragraphLines.append(nextLine)
                i += 1
            }
            blocks.append(.paragraph(text: paragraphLines.joined(separator: "\n")))
        }

        return blocks
    }

    // MARK: - Helpers

    private static func isDivider(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        guard let first = trimmed.first, first == "-" || first == "*" || first == "_" else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    private static func parseHeading(_ text: String) -> GliaMarkdownBlock? {
        guard text.hasPrefix("#") else { return nil }
        var level = 0
        for char in text {
            if char == "#" {
                level += 1
            } else {
                break
            }
        }
        guard level >= 1 && level <= 6 else { return nil }
        let afterHashes = text.dropFirst(level)
        guard afterHashes.hasPrefix(" ") else { return nil }
        let headingText = afterHashes.trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: headingText)
    }

    private static func stripQuotePrefix(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("> ") {
            return String(trimmed.dropFirst(2))
        } else if trimmed.hasPrefix(">") {
            return String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let parts = line.split(separator: "|", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return false }
        for part in parts {
            let cell = part.trimmingCharacters(in: .whitespaces)
            guard !cell.isEmpty else { return false }
            var hasHyphen = false
            for ch in cell {
                if ch == "-" {
                    hasHyphen = true
                } else if ch != ":" && ch != " " {
                    return false
                }
            }
            if !hasHyphen { return false }
        }
        return true
    }

    private static func parseTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") {
            trimmed.removeFirst()
        }
        if trimmed.hasSuffix("|") {
            trimmed.removeLast()
        }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func isBulletListItem(_ text: String) -> Bool {
        return text.hasPrefix("- ") || text.hasPrefix("* ") || text.hasPrefix("+ ")
    }

    private static func stripBulletPrefix(_ text: String) -> String {
        return String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    private static func parseNumberedListItem(_ text: String) -> GliaMarkdownBlock.NumberedListItem? {
        guard let dotIndex = text.firstIndex(of: ".") else { return nil }
        let numStr = text[..<dotIndex].trimmingCharacters(in: .whitespaces)
        guard let number = Int(numStr) else { return nil }
        let afterDot = text[text.index(after: dotIndex)...]
        guard afterDot.hasPrefix(" ") else { return nil }
        let itemText = afterDot.trimmingCharacters(in: .whitespaces)
        return GliaMarkdownBlock.NumberedListItem(number: number, text: itemText)
    }
}
#endif
