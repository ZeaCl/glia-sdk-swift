# Guía de Integración — Glia Swift SDK (`GliaSDK` & `GliaUI`)

Esta guía describe cómo integrar el SDK oficial de **Glia** (`v1.0.0`) en cualquier aplicación iOS o macOS escrita en Swift y SwiftUI.

---

## 🏗️ 1. Arquitectura y Módulos

El paquete se divide en dos módulos desacoplados:

1. **`GliaSDK` (Core / Red y Protocolo)**:
   - Implementa la conexión WebSocket con **Phoenix Channels v2** (`phx_join`, `run`, heartbeat de 30s y reconexión automática con backoff exponencial).
   - Manejo de streaming en tiempo real: razonamiento del agente (`thinking_delta`), fragmentos de texto (`message_delta`), invocación de herramientas (`tool_call` y `tool_result`), y finalización (`done`).
   - 100% compatible con **Swift 6 Concurrency** (`Sendable`, `Actor-isolated`, tipos seguros con `JSONValue`).
   - Cero dependencias de UI (compilable tanto en iOS/macOS como en Linux).

2. **`GliaUI` (Componentes Visuales SwiftUI)**:
   - **`GliaChatView`**: Vista de chat con scroll automático suave hacia los nuevos tokens, sugerencias rápidas de prompt, banner de estado y chips visuales para herramientas ejecutadas.
   - **`GliaChatViewModel`**: `@MainActor` observable que gestiona los mensajes (`GliaChatMessage`), el estado de conexión y la sincronización con el cliente de red.
   - **`GliaTheme`**: Estructura de diseño para adaptar la apariencia al sistema de diseño de la aplicación.

---

## 📦 2. Instalación

### Opción A: A través de Xcode (Recomendado para apps iOS)
1. En Xcode, abre tu proyecto.
2. Ve a **File > Add Package Dependencies...**
3. En la barra de búsqueda, pega la URL del repositorio:
   ```text
   https://github.com/ZeaCl/glia-sdk-swift.git
   ```
4. En **Dependency Rule**, selecciona **Up to Next Major Version** a partir de `1.0.0`.
5. Selecciona tu target principal y marca las librerías a vincular:
   - `GliaSDK` (Requerido)
   - `GliaUI` (Requerido para usar `GliaChatView`)

### Opción B: A través de `Package.swift`
Agrega el paquete en la sección `dependencies` de tu manifiesto:

```swift
// swift-tools-version: 5.9
dependencies: [
    .package(url: "https://github.com/ZeaCl/glia-sdk-swift.git", from: "1.0.0")
],
targets: [
    .target(
        name: "TuApp",
        dependencies: [
            .product(name: "GliaSDK", package: "glia-sdk-swift"),
            .product(name: "GliaUI", package: "glia-sdk-swift")
        ]
    )
]
```

---

## 🚀 3. Paso a Paso de Integración

### Paso 1: Configurar e Inicializar `GliaClient`

El cliente requiere el endpoint del gateway, el identificador de la aplicación (`appId`), el ID del usuario (`userId`) y opcionalmente un Bearer token de autenticación (Soma PAT o JWT):

```swift
import GliaSDK

let client = GliaClient(
    gatewayUrl: "https://api.zea.cl/glia/v1", // Se normaliza automáticamente a wss://api.zea.cl/glia/v1/socket/websocket?vsn=2.0.0
    appId: "nutrisnaps",
    userId: "user_uuid_12345",
    token: "token_autenticacion_soma_si_aplica",
    systemPrompt: "Eres un asistente nutricional inteligente especializado en análisis de comidas."
)
```

> [!TIP]
> **Normalización Automática**: No te preocupes si configuras `https://` o `http://`; el SDK convierte internamente el protocolo a WebSockets seguros (`wss://` / `ws://`) y añade los query parameters del protocolo Phoenix (`vsn=2.0.0` y `token=...`).

---

### Paso 2: Crear la Pantalla con `GliaChatView`

Crea tu vista en SwiftUI inyectando el cliente en el `GliaChatViewModel`. El ViewModel se conecta automáticamente y escucha el flujo de streaming:

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
            title: "Asistente NutriSnaps",
            welcomeMessage: "¡Hola! Soy tu asistente de nutrición. ¿En qué te puedo orientar hoy?",
            placeholder: "Pregúntame sobre tus comidas, recetas o calorías...",
            suggestedPrompts: [
                "¿Cuánta proteína tiene mi último desayuno?",
                "Sugiere un snack saludable de 200 kcal",
                "¿Cómo voy con mi meta diaria de agua?"
            ],
            theme: GliaTheme.nutrisnapsTheme,
            disconnectOnDisappear: false // Recomendado: mantener en false si la vista está en un NavigationStack o modal
        )
        .navigationTitle("Asistente IA")
        .navigationBarTitleDisplayMode(.inline)
    }
}
```

---

### Paso 3: Personalizar el Tema Visual (`GliaTheme`)

Puedes adaptar todos los colores de la conversación (burbujas, fondo, textos y chips) al branding de tu app:

```swift
extension GliaTheme {
    static var nutrisnapsTheme: GliaTheme {
        GliaTheme(
            backgroundColor: Color(.systemBackground),
            surfaceColor: Color(.secondarySystemBackground),
            surfaceContainerHigh: Color(.tertiarySystemBackground),
            primaryColor: Color.green,                 // Color de acento / botón enviar
            textColor: Color(.label),
            textMutedColor: Color(.secondaryLabel),
            userBubbleColor: Color.green.opacity(0.85),
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

### Paso 4: Declarar Herramientas Dinámicas del Cliente (Opcional)

Si el asistente puede invocar funciones locales o webhooks de tu servicio, defínelas usando `GliaToolDefinition` y la estructura fuertemente tipada `JSONValue`:

```swift
let logFoodTool = GliaToolDefinition(
    name: "log_food_entry",
    description: "Registra un alimento consumido en el diario del usuario",
    parameters: [
        "type": "object",
        "properties": [
            "food_name": ["type": "string"],
            "calories": ["type": "number"]
        ],
        "required": ["food_name", "calories"]
    ],
    webhookUrl: "https://api.nutrisnaps.cl/v1/food-logs"
)

// Enviar con herramientas disponibles para este turno:
viewModel.send(
    prompt: "Anota un café con leche y tostadas que comí recién",
    tools: [logFoodTool]
)
```

Cuando el agente decida invocar la herramienta, `GliaChatView` mostrará un badge animado con el nombre de la acción (`"Acción: log_food_entry"`), el cual permanecerá asociado al mensaje final del asistente.

---

### Paso 5: Manejo del Ciclo de Vida y Conexión

* **Conexión Inicial**: Al instanciar `GliaChatViewModel`, su método `connect()` se suscribe automáticamente a los eventos. Si deseas conectarlo manualmente o reconectar ante un botón de reintento:
  ```swift
  viewModel.connect()
  ```
* **Desconexión**: Si la pantalla se destruye definitivamente o el usuario cierra sesión:
  ```swift
  viewModel.disconnect()
  ```
* **`disconnectOnDisappear`**: 
  * Por defecto es `false`. Esto previene que si el usuario navega a una sub-pantalla o minimiza temporalmente la aplicación, la conexión WebSocket se corte innecesariamente.
  * Si deseas que se desconecte inmediatamente al salir de la pantalla, configúralo como `true`.

---

## 🔒 4. Consideraciones de Seguridad y Red (Info.plist)

Si pruebas en entornos locales de desarrollo con conexiones HTTP/WS sin TLS (`http://localhost:4003`), asegúrate de permitir excepciones de **App Transport Security (ATS)** en tu `Info.plist`:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

Para entornos de producción (`https://api.zea.cl/glia`), TLS está habilitado por defecto y no requiere ninguna configuración adicional en ATS.

---

## 📋 5. Resumen de Tipos Principales

| Tipo | Módulo | Descripción |
| :--- | :--- | :--- |
| **`GliaClient`** | `GliaSDK` | Actor principal de red. Gestiona conexión WebSocket, tokens y streaming. |
| **`GliaOptions`** | `GliaSDK` | Parámetros de inicialización (timeout, reconexión automática, prompts). |
| **`GliaStreamEvent`** | `GliaSDK` | Enum con deltas en tiempo real (`messageDelta`, `thinkingDelta`, `toolCall`, `done`). |
| **`JSONValue`** | `GliaSDK` | Representación segura (`Sendable`, `Codable`) de JSON sin `@unchecked Sendable`. |
| **`GliaChatView`** | `GliaUI` | Vista SwiftUI completa para renderizar el chat con el asistente. |
| **`GliaChatViewModel`** | `GliaUI` | ViewModel reactivo para gestionar mensajes y estado de streaming. |
| **`GliaTheme`** | `GliaUI` | Estructura de personalización estética de la interfaz. |
