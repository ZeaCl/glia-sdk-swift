import XCTest
@testable import GliaSDK

final class GliaLiveIntegrationTests: XCTestCase {
    func testLiveGatewayStreamingConnection() async throws {
        // Ejecutar solo si GLIA_LIVE_TEST=1 está presente en el entorno
        guard ProcessInfo.processInfo.environment["GLIA_LIVE_TEST"] == "1" else {
            throw XCTSkip("GLIA_LIVE_TEST=1 no está configurado. Omitiendo prueba E2E en vivo contra backend Phoenix Channels.")
        }

        let gatewayUrl = ProcessInfo.processInfo.environment["GLIA_LIVE_URL"] ?? "ws://localhost:4003"
        let appId = ProcessInfo.processInfo.environment["GLIA_LIVE_APP_ID"] ?? "test_app"
        let userId = ProcessInfo.processInfo.environment["GLIA_LIVE_USER_ID"] ?? "test_user_\(UUID().uuidString.prefix(8))"
        let token = ProcessInfo.processInfo.environment["GLIA_LIVE_TOKEN"]

        let options = GliaOptions(
            gatewayUrl: gatewayUrl,
            appId: appId,
            userId: userId,
            token: token,
            timeout: 10.0,
            autoReconnect: false
        )

        let client = GliaClient(options: options)

        // 1. Conexión y phx_join sincrónico
        try await client.connect()
        let isConnected = await client.isConnected
        XCTAssertTrue(isConnected, "El cliente debe confirmar conexión y handshake phx_join exitoso")

        // 2. Observar stream de eventos
        let stream = await client.observeEvents()

        // 3. Enviar prompt
        try await client.send(prompt: "Hola desde test E2E de Swift SDK")

        let streamTask = Task { () -> (done: Bool, deltas: Int, error: String?) in
            var deltas = 0
            for await event in stream {
                guard !Task.isCancelled else { break }
                switch event {
                case .messageDelta, .thinkingDelta:
                    deltas += 1
                case .done:
                    return (done: true, deltas: deltas, error: nil)
                case .error(let msg):
                    return (done: false, deltas: deltas, error: msg)
                default:
                    break
                }
            }
            return (done: false, deltas: deltas, error: Task.isCancelled ? "Timeout: no se recibió evento done en 15 segundos" : "Stream finalizó prematuramente")
        }

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000) // 15s timeout
            streamTask.cancel()
        }

        let result = await streamTask.value
        timeoutTask.cancel()

        if let error = result.error {
            XCTFail("Fallo en stream en vivo: \(error)")
        }
        XCTAssertTrue(result.done, "Debe completarse el turno con evento done")
        XCTAssertGreaterThan(result.deltas, 0, "Debe haberse recibido al menos un chunk/delta de respuesta")

        // 4. Desconexión voluntaria limpia
        await client.disconnect()
        let finalConnected = await client.isConnected
        XCTAssertFalse(finalConnected, "El cliente debe reflejar desconexión limpia")
    }
}
