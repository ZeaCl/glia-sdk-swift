# 🚀 Epic: Architectural Improvements and Advanced Capabilities for Glia SDKs

This epic coordinates the architectural enhancements identified in the code review of the **Glia Swift SDK** ([`ZeaCl/glia-sdk-swift`](https://github.com/ZeaCl/glia-sdk-swift)) and their parity and implementation across the **Glia Kotlin SDK** ([`ZeaCl/glia-sdk-kotlin`](https://github.com/ZeaCl/glia-sdk-kotlin)).

---

## 🎯 Objective

Evolve the Glia client SDKs towards next-generation mobile autonomous agent environments, incorporating:
1. **Client-Side Tool Calling:** Invocation of native device tools and callback results.
2. **Session Resumption:** Fault-tolerant resumption of streaming and network blips.
3. **Multimodality:** Native support for images, attachments, and vision in messaging and UI.
4. **Local Persistence:** Decoupled local storage adapter and offline cache.

---

## 🌳 Parity Matrix & GitHub Issue Tracking

| Capability / Feature | 🍏 iOS & macOS / Swift (`glia-sdk-swift`) | 🤖 Android / Kotlin (`glia-sdk-kotlin`) |
| :--- | :---: | :---: |
| **Main Epic** | [#14](https://github.com/ZeaCl/glia-sdk-swift/issues/14) | [ZeaCl/glia-sdk-kotlin#2](https://github.com/ZeaCl/glia-sdk-kotlin/issues/2) |
| **1. Client-Side Tool Calling** | [#10](https://github.com/ZeaCl/glia-sdk-swift/issues/10) | [ZeaCl/glia-sdk-kotlin#3](https://github.com/ZeaCl/glia-sdk-kotlin/issues/3) |
| **2. Session Resumption & State Sync** | [#11](https://github.com/ZeaCl/glia-sdk-swift/issues/11) | [ZeaCl/glia-sdk-kotlin#4](https://github.com/ZeaCl/glia-sdk-kotlin/issues/4) |
| **3. Multimodal Messaging (Images & Vision)** | [#12](https://github.com/ZeaCl/glia-sdk-swift/issues/12) | [ZeaCl/glia-sdk-kotlin#5](https://github.com/ZeaCl/glia-sdk-kotlin/issues/5) |
| **4. Local Persistence & Offline Cache** | [#13](https://github.com/ZeaCl/glia-sdk-swift/issues/13) | [ZeaCl/glia-sdk-kotlin#6](https://github.com/ZeaCl/glia-sdk-kotlin/issues/6) |

---

## 📋 Improvement Details

### 1. Client-Side Tool Calling
- **Problem:** Currently tools (`GliaToolDefinition`) assume remote execution via backend webhooks.
- **Solution:**
  - Add execution target (`webhook` vs `client`).
  - Client method: `sendToolResult(callId, result)` to send the `tool_result` frame to the Phoenix socket.
  - Dispatcher in the ViewModel to resolve local device tools (GPS, camera, biometrics) with visual feedback in chat.

### 2. Session Resumption & State Synchronization
- **Problem:** Momentary disconnections during active streaming (`message_delta` / `thinking_delta`) cause token loss and leave UI state hanging.
- **Solution:**
  - Checkpointing of received sequences (`lastSequenceId`).
  - Send `resume_token` or `last_seq` in the `phx_join` handshake to retransmit lost tokens.
  - Clean fallback state in UI with retry options if the session expired on the server.

### 3. Multimodal Messaging (Images, Attachments, and Vision)
- **Problem:** Messaging contract `send(prompt: String)` is 100% plain text.
- **Solution:**
  - `GliaContentPart` structure supporting text and images (URL or base64/binary).
  - Image picker and preview in the input bar of `GliaChatView` (SwiftUI) and `GliaChat` (Jetpack Compose).

### 4. Integrated Local Persistence & Offline Cache
- **Problem:** Each host application must reimplement history storage and reloading logic.
- **Solution:**
  - Abstraction `GliaChatStorage` / `GliaChatStorageProtocol`.
  - Standard implementation based on cached JSON files.
  - Automatic reactive integration with `GliaChatViewModel`.
