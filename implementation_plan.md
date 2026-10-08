# Plan de Implementación: Soporte de Telemetría Móvil y Reporte de Errores en GliaClient (Issue #17)

## 1. Resumen Ejecutivo
Implementar capacidades nativas de telemetría y reporte de errores en `glia-sdk-swift` para aplicaciones iOS en el ecosistema ZEA. El sistema transmitirá eventos y errores a través de la conexión WebSocket existente (Phoenix Channels) usando el evento `"track_event"` sobre el topic de sesión, incorporando buffer offline FIFO de hasta 50 elementos, supresión de errores repetidos (circuit breaker de 60s), sanitización Zero-PII, truncado a 1.024 caracteres, identificador secuencial y ciclo de vida iOS.

---

## 2. Arquitectura de la Solución

### A. Nuevos Componentes en `Sources/GliaSDK/Telemetry/`

1. **`TelemetrySanitizer`**:
   - Trunca cadenas a un máximo de 1.024 caracteres.
   - Detecta y enmascara campos sensibles (Zero PII):
     - Llaves: `password`, `token`, `secret`, `authorization`, `jwt`, `email`, `bearer`, `auth`, `credit_card`.
     - Patrones de valores: expresiones regulares para tokens JWT (`eyJh...`), correos electrónicos (`user@domain.com`).
   - Sanitiza diccionarios de metadatos `[String: JSONValue]`.

2. **`TelemetryEvent`**:
   - Estructura `Sendable`, `Codable`, `Equatable`.
   - Propiedades:
     - `seq`: Entero autoincremental por sesión (evita desincronización de reloj).
     - `type`: `"error"` o `"event"`.
     - `name`: Nombre descriptivo (ej. `"error"` o evento personalizado).
     - `flow`: Flujo de negocio (ej. `"food_scan"`).
     - `endpoint`: Ruta o endpoint API opcional (ej. `"/api/analyze/food"`).
     - `message`: Mensaje descriptivo sanitizado (truncado a 1.024 chars).
     - `code`: Código de error opcional.
     - `errorType`: Nombre del tipo del error (ej. `"DecodingError"`).
     - `metadata`: Diccionario `[String: JSONValue]` sanitizado.
   - Método `toPhoenixPayload() -> [String: JSONValue]`.

3. **`TelemetryManager` (Actor)**:
   - Administra el estado de telemetría:
     - **Buffer FIFO**: Capacidad fija de 50 eventos. Al llegar al límite, descarta los más antiguos.
     - **Circuit Breaker**: Diccionario de supresión con clave `\(flow):\(code ?? errorType)`. Si se recibe un error idéntico dentro de 60 segundos, se suprime silenciosamente.
     - **Contador secuencial `seq`**: Inicia en 1 y se incrementa atómicamente por cada evento aceptado.
     - **Manejo de Background/Foreground**: Pausa de temporizadores internos y retención íntegra del buffer.
     - **Flush**: Provee `flush() -> [TelemetryEvent]` para enviar todos los eventos acumulados al reconectar el socket.

### B. Modificaciones en `Sources/GliaSDK/`

1. **`GliaClientProtocol`**:
   - Agregar firmas:
     ```swift
     func trackError(flow: String, error: Error, endpoint: String?, code: String?, metadata: [String: JSONValue]?) async
     func trackEvent(name: String, flow: String?, metadata: [String: JSONValue]?) async
     ```
   - Extensiones de conveniencia con valores por defecto y soporte de `metadata: [String: Any]?`.

2. **`GliaClient`**:
   - Instancia Singleton estática thread-safe:
     ```swift
     public static var shared: GliaClient { get set }
     public static func configure(shared: GliaClient)
     ```
   - Integración de `TelemetryManager`:
     - Al invocar `trackError` o `trackEvent`:
       - `TelemetryManager` procesa sanitización, circuit breaker y asigna `seq`.
       - Si está conectado (`isConnected == true`), se emite inmediatamente un `PhoenixFrame` con `event: "track_event"`.
       - Si está desconectado, `TelemetryManager` encola el evento en el buffer FIFO.
     - Al conectarse/reconectarse con éxito (`joinChannel` exitoso):
       - Se vacía el buffer (`flush()`) y se transmiten los eventos encolados en ráfaga a través del WebSocket.
   - Observadores de Ciclo de Vida iOS (`UIApplication.didEnterBackgroundNotification` / `UIApplication.willEnterForegroundNotification`) gestionados de forma segura con `#if canImport(UIKit) && !os(watchOS)`.

---

## 3. Plan de Pruebas (Test-Driven Development)

Crearemos una suite dedicada `Tests/GliaSDKTests/TelemetryTests.swift`:

1. **`testTrackErrorImmediateSendWhenConnected`**:
   - Verifica que con socket conectado se envía de inmediato un `PhoenixFrame` con `event: "track_event"` sin peticiones HTTP.
2. **`testOfflineFIFOBufferingAndMaxCapacity50`**:
   - Con el socket desconectado, se envían 60 eventos distintos.
   - Verifica que solo se retienen 50 y que los primeros 10 fueron descartados (FIFO).
3. **`testOfflineBufferFlushingOnReconnect`**:
   - Encola eventos offline, simula reconexión y verifica que se transmiten todos los eventos pendientes en ráfaga y el buffer queda vacío.
4. **`testCircuitBreakerSuppression60Seconds`**:
   - Simula 40 errores para el mismo flujo y código en ráfaga.
   - Verifica que solo el primer error se procesa y los 39 restantes son suprimidos.
   - Verifica que tras avanzar 61 segundos (vencimiento de ventana), el siguiente error sí se transmite.
5. **`testSanitizationZeroPIIAndPayloadTruncation`**:
   - Envía cadenas de más de 2.000 caracteres: verifica truncado a 1.024 caracteres.
   - Envía metadatos con `password`, `token`, JWTs, emails: verifica que son redactados/enmascarados.
6. **`testHighConcurrencyStress1000Tasks`**:
   - Ejecuta 1.000 tareas concurrentes invocando `trackError` y `trackEvent`.
   - Verifica ausencia de carreras de hilos (`Sendable` thread-safety) y consistencia del estado.
7. **`testGliaClientSharedConfiguration`**:
   - Verifica acceso e inicialización de `GliaClient.shared`.

---

## 4. Criterios de Aceptación
- Todos los escenarios del issue #17 cumplidos.
- 100% de la suite de pruebas pasando (`swift test`).
- Cero breaking changes en la API existente de chat y streaming.
- Respeto a las directivas de ZEA Platform.
