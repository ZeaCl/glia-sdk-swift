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

        var receivedDone = false
        var deltasCount = 0

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000) // 15 segundos timeout E2E
        }

        for await event in stream {
            switch event {
            case .messageDelta, .thinkingDelta:
                deltasCount += 1
            case .done:
                receivedDone = true
                break
            case .error(let msg):
                XCTFail("Se recibió error inesperado del gateway en vivo: \(msg)")
                break
            default:
                break
            }

            if receivedDone {
                break
            }
        }

        timeoutTask.cancel()

        XCTAssertTrue(receivedDone, "Debe completarse el turno con evento done")
        XCTAssertGreaterThan(deltasCount, 0, "Debe haberse recibido al menos un chunk/delta de respuesta")

        // 4. Desconexión voluntaria limpia
        await client.disconnect()
        let finalConnected = await client.isConnected
        XCTAssertFalse(finalConnected, "El cliente debe reflejar desconexión limpia")
    }
}
