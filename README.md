# Glia Swift SDK (`glia-sdk-swift`)

Official Swift client SDK and SwiftUI UI components for **Glia** — the high-performance, cloud-agnostic agent runtime built on Phoenix Channels WebSockets.

---

## 🚀 Features

- **Protocol Parity:** Built on standard Phoenix Channels v2 (`phx_join`, `run`, heartbeat, exponential reconnect with backoff).
- **Strict Concurrency & Type Safety:** 100% Swift 6 Concurrency compliant, actor-isolated `GliaClient`, and strongly typed `JSONValue` eliminating `@unchecked Sendable`.
- **DIP & Testability:** Decoupled WebSocket transport layer (`WebSocketConnectionProtocol`) enabling deterministic in-memory unit testing.
- **Cloud & Vendor Agnostic:** Connects to any Glia instance (Docker, AWS, GCP, Bare-Metal, localhost).
- **Domain & Client Agnostic:** Zero client-specific hardcoding. Fully customizable themes, system prompts, and declarative tools.
- **Real-Time Streaming:** Sub-second streaming of tokens (`message_delta`), reasoning traces (`thinking_delta`), and tool calls (`tool_call`, `tool_result`).
- **SwiftUI Ready:** Includes `GliaChatView` with live streaming, smooth auto-scroll, collapsible thinking accordion, accessibility (a11y) support, and dynamic tool status chips.

---

## 📦 Installation (Swift Package Manager)

Add the dependency in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ZeaCl/glia-sdk-swift.git", from: "1.0.0")
]
```

Or in Xcode: **File > Add Package Dependencies...** and enter `https://github.com/ZeaCl/glia-sdk-swift.git`.

---

## 🛠️ Usage

### 1. Initialize GliaClient (Core)

```swift
import GliaSDK

let client = GliaClient(
    gatewayUrl: "https://glia.yourdomain.com", // Automatically normalized to wss://.../socket/websocket
    appId: "your-app-id",
    userId: "user-12345",
    token: "jwt-bearer-token"
)

// Connect (suspends until phx_join confirms status: "ok")
try await client.connect()

// Define dynamic tools with strongly typed JSONValue parameters
let quoteTool = GliaToolDefinition(
    name: "calculate_quote",
    description: "Calculates an estimate",
    parameters: [
        "type": "object",
        "properties": [
            "amount": ["type": "number"]
        ]
    ],
    webhookUrl: "https://api.yourdomain.com/quote"
)

// Send a prompt with optional system prompt and tools
try await client.send(
    prompt: "¿Cuál es el balance del fondo?",
    systemPrompt: "Eres un asistente financiero.",
    tools: [quoteTool]
)

// Observe real-time streaming events
let events = await client.observeEvents()
for await event in events {
    switch event {
    case .thinkingDelta(let thought):
        print("Thinking: \(thought)")
    case .messageDelta(let chunk):
        print("Message: \(chunk)")
    case .toolCall(let name, let args):
        print("Tool: \(name) with args: \(args)")
    case .done:
        print("Completed!")
    default:
        break
    }
}
```

### 2. Embed GliaChatView (SwiftUI)

```swift
import SwiftUI
import GliaSDK
import GliaUI

struct ChatScreen: View {
    @StateObject private var viewModel: GliaChatViewModel

    init(client: any GliaClientProtocol) {
        _viewModel = StateObject(wrappedValue: GliaChatViewModel(client: client))
    }

    var body: some View {
        GliaChatView(
            viewModel: viewModel,
            title: "Mi Asistente",
            welcomeMessage: "¡Hola! ¿En qué puedo ayudarte?",
            placeholder: "Escribe tu consulta...",
            suggestedPrompts: [
                "Consultar estado de cuenta",
                "Programar una reunión"
            ],
            theme: GliaTheme(
                primaryColor: Color.blue,
                userBubbleColor: Color.blue,
                backgroundColor: Color.black
            ),
            disconnectOnDisappear: false // Preserves connection on modal sheets or navigation
        )
    }
}
```

---

## 🧪 Running Tests & CI/CD

### Local Unit Tests
```bash
swift test
```

### Strict Swift 6 Concurrency Check
```bash
swift test -Xswiftc -strict-concurrency=complete
```

### End-to-End Live Integration Tests
To test against a live Phoenix Channels gateway running on `localhost:4003` (or custom endpoint):
```bash
GLIA_LIVE_TEST=1 GLIA_LIVE_URL="ws://localhost:4003" swift test --filter GliaLiveIntegrationTests
```

### Google Cloud Build & Microglia Security Audit
This repository contains [`cloudbuild.yaml`](cloudbuild.yaml) aligned with ZEA GCP standards (`southamerica-west1`):
```bash
# Run security audit locally with Microglia
microglia scan . --details
```

---

## 📄 License

MIT © ZEA Platform
