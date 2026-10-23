import XCTest
#if canImport(SwiftUI)
import SwiftUI
#endif
@testable import GliaSDK
@testable import GliaUI

final class GliaMarkdownTests: XCTestCase {

    func testParseHeadings() {
        let text = """
        # Heading 1
        ## Heading 2
        ### Heading 3
        ###### Heading 6
        """
        let blocks = GliaMarkdownParser.parse(text)
        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(blocks[0], .heading(level: 1, text: "Heading 1"))
        XCTAssertEqual(blocks[1], .heading(level: 2, text: "Heading 2"))
        XCTAssertEqual(blocks[2], .heading(level: 3, text: "Heading 3"))
        XCTAssertEqual(blocks[3], .heading(level: 6, text: "Heading 6"))
    }

    func testParseCodeBlocksWithAndWithoutLanguage() {
        let text = """
        ```swift
        let x = 10
        print(x)
        ```

        ```
        plain code
        ```
        """
        let blocks = GliaMarkdownParser.parse(text)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0], .codeBlock(language: "swift", code: "let x = 10\nprint(x)"))
        XCTAssertEqual(blocks[1], .codeBlock(language: nil, code: "plain code"))
    }

    func testParseUnclosedCodeBlockDuringStreaming() {
        // Simulates an assistant stream that is halfway through writing code
        let text = """
        Aquí tienes el código:
        ```python
        def hello():
            return "world"
        """
        let blocks = GliaMarkdownParser.parse(text)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0], .paragraph(text: "Aquí tienes el código:"))
        XCTAssertEqual(blocks[1], .codeBlock(language: "python", code: "def hello():\n    return \"world\""))
    }

    func testParseTable() {
        let text = """
        | Endpoint | Método | Estado |
        | :--- | :---: | ---: |
        | /v1/chat | POST | 200 OK |
        | /v1/telemetry | POST | 204 No Content |
        """
        let blocks = GliaMarkdownParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
        if case .table(let headers, let rows) = blocks[0] {
            XCTAssertEqual(headers, ["Endpoint", "Método", "Estado"])
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows[0], ["/v1/chat", "POST", "200 OK"])
            XCTAssertEqual(rows[1], ["/v1/telemetry", "POST", "204 No Content"])
        } else {
            XCTFail("Expected table block, got \(blocks[0])")
        }
    }

    func testParseBlockquote() {
        let text = """
        > Este es un quote importante.
        > Continúa en la siguiente línea.
        """
        let blocks = GliaMarkdownParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0], .blockquote(text: "Este es un quote importante.\nContinúa en la siguiente línea."))
    }

    func testParseBulletAndNumberedLists() {
        let text = """
        - Item 1
        - Item 2
        * Item 3

        1. Primero
        2. Segundo
        3. Tercero
        """
        let blocks = GliaMarkdownParser.parse(text)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0], .bulletList(items: ["Item 1", "Item 2", "Item 3"]))
        XCTAssertEqual(blocks[1], .numberedList(items: [
            .init(number: 1, text: "Primero"),
            .init(number: 2, text: "Segundo"),
            .init(number: 3, text: "Tercero")
        ]))
    }

    func testParseDivider() {
        let text = """
        Arriba
        ---
        Abajo
        """
        let blocks = GliaMarkdownParser.parse(text)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0], .paragraph(text: "Arriba"))
        XCTAssertEqual(blocks[1], .divider)
        XCTAssertEqual(blocks[2], .paragraph(text: "Abajo"))
    }

    func testParseEmptyAndWhitespaceString() {
        XCTAssertTrue(GliaMarkdownParser.parse("").isEmpty)
        XCTAssertTrue(GliaMarkdownParser.parse("   \n\n  \t ").isEmpty)
    }

    func testStreamingPerformance500ChunksUnder500Milliseconds() {
        // Measure performance during simulated 500-token streaming
        var currentStream = ""
        let tokens = [
            "Hola, ", "te presento ", "**Glia SDK** ", "para Swift.\n\n",
            "```swift\n", "let client = ", "GliaClient(options: .init(", "url: \"wss://api.zea.cl\"))\n",
            "```\n\n", "| Feature | Status |\n", "| --- | --- |\n", "| Streaming | Ready |\n",
            "| Markdown | Added |\n\n", "1. Instalar\n", "2. Configurar\n"
        ]

        let startTime = CFAbsoluteTimeGetCurrent()
        for i in 0..<500 {
            currentStream += tokens[i % tokens.count]
            let blocks = GliaMarkdownParser.parse(currentStream)
            XCTAssertFalse(blocks.isEmpty)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        // 500 iterations must take under 0.5 seconds in unoptimized debug mode (< 1ms per iteration)
        XCTAssertLessThan(elapsed, 0.5, "Incremental markdown parsing took too long: \(elapsed)s")
    }

    #if canImport(SwiftUI)
    func testGliaMarkdownViewInstantiation() {
        let theme = GliaTheme()
        let markdown = """
        # Título
        Texto con **negrita**, *cursiva*, ~~tachado~~ y [enlace](https://zea.cl).
        ```swift
        print("Hello Zea")
        ```
        """
        let view = GliaMarkdownView(markdown: markdown, theme: theme, isStreaming: false)
        XCTAssertNotNil(view)
    }

    @MainActor
    func testGliaChatViewInstantiation() {
        let client = GliaClient(options: .init(gatewayUrl: "https://api.zea.cl", appId: "test", userId: "test"))
        let viewModel = GliaChatViewModel(client: client)
        let chatView = GliaChatView(viewModel: viewModel)
        XCTAssertNotNil(chatView)
    }
    #endif
}
