import XCTest

final class CloudBuildConfigTests: XCTestCase {
    func testCloudBuildFileExistsAndValidatesStandards() throws {
        // Find relative path to Package.swift using #filePath (Swift 6 compatible)
        let currentFileURL = URL(fileURLWithPath: #filePath)
        let rootURL = currentFileURL
            .deletingLastPathComponent() // GliaSDKTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root

        let cloudbuildURL = rootURL.appendingPathComponent("cloudbuild.yaml")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: cloudbuildURL.path),
            "cloudbuild.yaml must exist at the repository root"
        )

        let content = try String(contentsOf: cloudbuildURL, encoding: .utf8)

        // Validate mandatory steps
        XCTAssertTrue(content.contains("id: swift-test"), "Must contain step swift-test")
        XCTAssertTrue(content.contains("entrypoint: swift"), "Must invoke entrypoint swift")
        XCTAssertTrue(content.contains("id: microglia-audit"), "Must contain step microglia-audit")
        XCTAssertTrue(content.contains("entrypoint: microglia"), "Must invoke entrypoint microglia")
        XCTAssertTrue(content.contains("scan"), "Microglia must execute scan")

        // Validate standards
        XCTAssertTrue(content.contains("_REGION: southamerica-west1"), "Must configure southamerica-west1 region")
        XCTAssertTrue(content.contains("_SWIFT_IMAGE: 'swift:6.0-noble'"), "Must use official Swift 6 container")
        XCTAssertTrue(content.contains("machineType: 'E2_HIGHCPU_8'"), "Must use standard machineType E2_HIGHCPU_8")
        XCTAssertTrue(content.contains("logging: CLOUD_LOGGING_ONLY"), "Must configure logging CLOUD_LOGGING_ONLY")
    }
}
