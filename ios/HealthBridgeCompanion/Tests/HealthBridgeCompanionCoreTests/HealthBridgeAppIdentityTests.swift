import XCTest
@testable import HealthBridgeCompanionCore

final class HealthBridgeAppIdentityTests: XCTestCase {
    func testFallbackBundleIdentifierIsPublicNeutral() {
        XCTAssertEqual(
            HealthBridgeAppIdentity.fallbackBundleIdentifier,
            "com.example.HealthBridgeCompanion"
        )
    }

    func testNormalizedBundleIdentifierFallsBackForMissingValues() {
        XCTAssertEqual(
            HealthBridgeAppIdentity.normalizedBundleIdentifier(nil),
            HealthBridgeAppIdentity.fallbackBundleIdentifier
        )
        XCTAssertEqual(
            HealthBridgeAppIdentity.normalizedBundleIdentifier("   "),
            HealthBridgeAppIdentity.fallbackBundleIdentifier
        )
    }

    func testDerivedIdentifiersUseCurrentBundleNamespace() {
        let bundleIdentifier = HealthBridgeAppIdentity.bundleIdentifier

        XCTAssertFalse(bundleIdentifier.isEmpty)
        XCTAssertEqual(
            HealthBridgeAppIdentity.appRefreshIdentifier,
            "\(bundleIdentifier).refresh"
        )
        XCTAssertEqual(
            HealthBridgeAppIdentity.backgroundUploadSessionIdentifier,
            "\(bundleIdentifier).background-upload.v2"
        )
        XCTAssertEqual(
            HealthBridgeAppIdentity.legacyBackgroundUploadSessionIdentifiers,
            ["\(bundleIdentifier).background-upload"]
        )
        XCTAssertFalse(
            HealthBridgeAppIdentity.legacyBackgroundUploadSessionIdentifiers.contains(
                HealthBridgeAppIdentity.backgroundUploadSessionIdentifier
            )
        )
        XCTAssertEqual(
            HealthBridgeAppIdentity.keychainServiceName,
            "\(bundleIdentifier).receiver"
        )
    }
}
