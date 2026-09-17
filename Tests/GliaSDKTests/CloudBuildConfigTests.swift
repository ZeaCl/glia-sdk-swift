import XCTest

final class CloudBuildConfigTests: XCTestCase {
    func testCloudBuildFileExistsAndValidatesStandards() throws {
        // Encontrar ruta relativa a Package.swift usando #filePath (Swift 6 compatible)
        let currentFileURL = URL(fileURLWithPath: #filePath)
        let rootURL = currentFileURL
            .deletingLastPathComponent() // GliaSDKTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root

        let cloudbuildURL = rootURL.appendingPathComponent("cloudbuild.yaml")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: cloudbuildURL.path),
            "cloudbuild.yaml debe existir en la raíz del repositorio"
        )

        let content = try String(contentsOf: cloudbuildURL, encoding: .utf8)

        // Validar steps obligatorios
        XCTAssertTrue(content.contains("id: swift-test"), "Debe contener step swift-test")
        XCTAssertTrue(content.contains("entrypoint: swift"), "Debe invocar entrypoint swift")
        XCTAssertTrue(content.contains("id: microglia-audit"), "Debe contener step microglia-audit")
        XCTAssertTrue(content.contains("entrypoint: microglia"), "Debe invocar entrypoint microglia")
        XCTAssertTrue(content.contains("scan"), "Microglia debe ejecutar scan")

        // Validar estándares ZEA
        XCTAssertTrue(content.contains("_REGION: southamerica-west1"), "Debe configurar región southamerica-west1")
        XCTAssertTrue(content.contains("_SWIFT_IMAGE: 'swift:6.0-noble'"), "Debe utilizar contenedor oficial Swift 6")
        XCTAssertTrue(content.contains("machineType: 'E2_HIGHCPU_8'"), "Debe utilizar machineType estándar E2_HIGHCPU_8")
        XCTAssertTrue(content.contains("logging: CLOUD_LOGGING_ONLY"), "Debe configurar logging CLOUD_LOGGING_ONLY")
    }
}
