# Glia Swift SDK (`glia-sdk-swift`)

Official Swift client SDK and SwiftUI UI components for **Glia** — the high-performance, cloud-agnostic agent runtime built on Phoenix Channels WebSockets.

---

## 🚀 Features

- **Protocol Parity:** Built on standard Phoenix Channels v2 (`phx_join`, `run`, heartbeat, exponential reconnect).
- **Cloud & Vendor Agnostic:** Connects to any Glia instance (Docker, AWS, GCP, Bare-Metal, localhost).
- **Domain & Client Agnostic:** Zero client-specific hardcoding. Fully customizable themes, system prompts, and declarative tools.
- **Real-Time Streaming:** Sub-second streaming of tokens (`message_delta`), reasoning traces (`thinking_delta`), and tool calls (`tool_call`, `tool_result`).
- **SwiftUI Ready:** Includes `GliaChatView` with live streaming, collapsible thinking accordion, and dynamic tool status chips.

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
    gatewayUrl: "wss://glia.yourdomain.com",
    appId: "your-app-id",
    userId: "user-12345",
    token: "jwt-bearer-token"
)

// Connect
try await client.connect()

// Send a prompt with optional dynamic tools
try await client.send(
    prompt: "¿Cuál es el balance del fondo?",
    systemPrompt: "Eres un asistente financiero."
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
        print("Tool: \(name)")
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

    init(client: GliaClient) {
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
            )
        )
    }
}
```

---

## 📄 License

MIT © ZEA Platform
