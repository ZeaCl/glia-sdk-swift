# Integration Guide — Glia Swift SDK (`GliaSDK` & `GliaUI`)

This guide describes how to integrate the official **Glia** Swift SDK (`v1.0.0`) into any iOS or macOS application written in Swift and SwiftUI.

---

## 🏗️ 1. Architecture and Modules

The package is split into two decoupled modules:

1. **`GliaSDK` (Core / Networking and Protocol)**:
   - Implements WebSocket connection with **Phoenix Channels v2** (`phx_join`, `run`, 30s heartbeat, and automatic exponential backoff reconnect).
   - Real-time streaming management: agent reasoning (`thinking_delta`), text deltas (`message_delta`), tool invocation (`tool_call` and `tool_result`), and completion (`done`).
   - 100% compliant with **Swift 6 Concurrency** (`Sendable`, `Actor-isolated`, strongly typed with `JSONValue`).
   - Zero UI dependencies (compiles on iOS, macOS, and Linux).

2. **`GliaUI` (SwiftUI Visual Components)**:
   - **`GliaChatView`**: Chat view with smooth auto-scroll to new tokens, suggested prompt chips, status banner, and visual badges for executed tools.
   - **`GliaChatViewModel`**: `@MainActor` observable managing messages (`GliaChatMessage`), connection state, and synchronization with the network client.
   - **`GliaTheme`**: Design structure to customize the appearance to your app's design system.

---

## 📦 2. Installation

### Option A: Via Xcode (Recommended for iOS apps)
1. In Xcode, open your project.
2. Go to **File > Add Package Dependencies...**
3. In the search bar, paste the repository URL:
   ```text
   https://github.com/ZeaCl/glia-sdk-swift.git
   ```
4. Under **Dependency Rule**, select **Up to Next Major Version** starting from `1.0.0`.
5. Select your main target and check the libraries to link:
   - `GliaSDK` (Required)
   - `GliaUI` (Required to use `GliaChatView`)

### Option B: Via `Package.swift`
Add the package to the `dependencies` section of your manifest:

```swift
// swift-tools-version: 5.9
dependencies: [
    .package(url: "https://github.com/ZeaCl/glia-sdk-swift.git", from: "1.0.0")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "GliaSDK", package: "glia-sdk-swift"),
            .product(name: "GliaUI", package: "glia-sdk-swift")
        ]
    )
]
```

---

## 🚀 3. Integration Step-by-Step

### Step 1: Configure and Initialize `GliaClient`

The client requires the gateway endpoint, the application identifier (`appId`), user ID (`userId`), and optionally a Bearer authentication token (JWT):

```swift
import GliaSDK

let client = GliaClient(
    gatewayUrl: "https://api.yourdomain.com/glia/v1", // Automatically normalized to wss://api.yourdomain.com/glia/v1/socket/websocket?vsn=2.0.0
    appId: "demo_app",
    userId: "user_uuid_12345",
    token: "jwt_bearer_token_if_applicable",
    systemPrompt: "You are an intelligent assistant."
)
```

> [!TIP]
> **Automatic Normalization**: Do not worry if you pass `https://` or `http://`; the SDK internally converts the protocol to secure WebSockets (`wss://` / `ws://`) and adds the required Phoenix parameters (`vsn=2.0.0` and `token=...`).

---

### Step 2: Build the Screen with `GliaChatView`

Create your SwiftUI view injecting the client into `GliaChatViewModel`. The ViewModel connects automatically and observes streaming events:

```swift
import SwiftUI
import GliaSDK
import GliaUI

struct AssistantChatScreen: View {
    @StateObject private var viewModel: GliaChatViewModel

    init(client: GliaClientProtocol) {
        _viewModel = StateObject(wrappedValue: GliaChatViewModel(client: client))
    }

    var body: some View {
        GliaChatView(
            viewModel: viewModel,
            title: "AI Assistant",
            welcomeMessage: "Hello! How can I help you today?",
            placeholder: "Ask me anything...",
            suggestedPrompts: [
                "What is my current account status?",
                "Suggest a plan for today",
                "How do I get started?"
            ],
            theme: GliaTheme.customTheme,
            disconnectOnDisappear: false // Recommended: keep false if view is in a NavigationStack or sheet
        )
        .navigationTitle("AI Assistant")
        .navigationBarTitleDisplayMode(.inline)
    }
}
```

---

### Step 3: Customize Visual Theme (`GliaTheme`)

You can adapt conversation colors (bubbles, background, text, and chips) to your app's branding:

```swift
extension GliaTheme {
    static var customTheme: GliaTheme {
        GliaTheme(
            backgroundColor: Color(.systemBackground),
            surfaceColor: Color(.secondarySystemBackground),
            surfaceContainerHigh: Color(.tertiarySystemBackground),
            primaryColor: Color.blue,                 // Accent color / send button
            textColor: Color(.label),
            textMutedColor: Color(.secondaryLabel),
            userBubbleColor: Color.blue.opacity(0.85),
            userBubbleTextColor: .white,
            agentBubbleColor: Color(.secondarySystemBackground),
            agentBubbleTextColor: Color(.label),
            thinkingBgColor: Color.orange.opacity(0.12),
            thinkingTextColor: Color.orange,
            thinkingBorderColor: Color.orange.opacity(0.35),
            errorColor: Color.red
        )
    }
}
```

---

### Step 4: Declare Dynamic Client Tools (Optional)

If the assistant can invoke functions or webhooks, define them using `GliaToolDefinition` and the strongly typed `JSONValue`:

```swift
let sampleTool = GliaToolDefinition(
    name: "calculate_estimate",
    description: "Calculates an estimate for the requested items",
    parameters: [
        "type": "object",
        "properties": [
            "item_name": ["type": "string"],
            "quantity": ["type": "number"]
        ],
        "required": ["item_name", "quantity"]
    ],
    webhookUrl: "https://api.yourdomain.com/v1/estimates"
)

// Send with tools available for this turn:
viewModel.send(
    prompt: "Calculate an estimate for 2 units of product A",
    tools: [sampleTool]
)
```

When the agent decides to invoke the tool, `GliaChatView` displays an animated badge with the tool name (`"Tool: calculate_estimate"`), which remains associated with the final assistant message.

---

### Step 5: Connection and Lifecycle Management

* **Initial Connection**: When instantiating `GliaChatViewModel`, its `connect()` method automatically subscribes to events. To trigger connection manually:
  ```swift
  viewModel.connect()
  ```
* **Disconnection**: If the screen is destroyed or user logs out:
  ```swift
  viewModel.disconnect()
  ```
* **`disconnectOnDisappear`**: 
  * Defaults to `false`. Prevents premature disconnection when navigating to child views or backgrounding the app.
  * Set to `true` if you want immediate disconnection when the view disappears.

---

## 🔒 4. Network and Security Considerations (Info.plist)

If testing in local development with non-TLS connections (`http://localhost:4003`), configure **App Transport Security (ATS)** exceptions in your `Info.plist`:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

For production environments (`https://gateway.yourdomain.com`), TLS is enabled by default and requires no extra ATS configuration.

---

## 📋 5. Core Types Summary

| Type | Module | Description |
| :--- | :--- | :--- |
| **`GliaClient`** | `GliaSDK` | Main network actor. Manages WebSocket connection, tokens, and streaming. |
| **`GliaOptions`** | `GliaSDK` | Configuration options (timeout, auto-reconnect, prompts). |
| **`GliaStreamEvent`** | `GliaSDK` | Real-time event enum (`messageDelta`, `thinkingDelta`, `toolCall`, `done`). |
| **`JSONValue`** | `GliaSDK` | Safe JSON representation (`Sendable`, `Codable`) without `@unchecked Sendable`. |
| **`GliaChatView`** | `GliaUI` | Full SwiftUI chat interface for rendering assistant conversations. |
| **`GliaChatViewModel`** | `GliaUI` | Reactive ViewModel managing messages and streaming state. |
| **`GliaTheme`** | `GliaUI` | Visual theme customization palette. |
