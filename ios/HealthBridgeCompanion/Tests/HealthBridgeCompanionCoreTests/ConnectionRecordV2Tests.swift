import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class ConnectionRecordV2Tests: XCTestCase {
    func testLegacyV1BootstrapPreservesPrimaryBytes() throws {
        let suiteName = "ConnectionRecordV2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = try legacyAtomicRecord(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-legacy-token",
            generation: 41,
            bindingID: "synthetic-binding-41"
        )
        let tokenStore = ConnectionV2CapturingTokenStore(initialToken: legacy)
        let backupStore = ConnectionV2CapturingTokenStore()
        let store = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: tokenStore,
            preCutoverBackupStore: backupStore
        )

        XCTAssertEqual(try store.ensureAtomicConnectionRecord(), "synthetic-binding-41")
        XCTAssertEqual(tokenStore.savedToken, legacy)
        XCTAssertEqual(tokenStore.saveCount, 0)
        XCTAssertEqual(store.receiverURLString, "https://synthetic.example/v1/batches")
        XCTAssertEqual(try store.loadBearerToken(), "synthetic-legacy-token")
        XCTAssertEqual(store.receiverSettingsGenerationToken, "g41")
        XCTAssertEqual(store.receiverBindingID, "synthetic-binding-41")
        XCTAssertTrue(backupStore.savedToken.isEmpty)

        let record = try XCTUnwrap(store.currentConnectionRecordV2())
        XCTAssertEqual(
            record.localScope,
            ReceiverLocalConnectionScopeV1(generation: 41, bindingID: "synthetic-binding-41")
        )
        XCTAssertEqual(
            record.mailboxIdentity,
            .unavailable(.notProvisionedByLegacyHTTPPairing)
        )
        XCTAssertEqual(record.activation, .paired(activeTransport: .directHTTP))
        XCTAssertEqual(
            record.transportConfigurations,
            [
                .directHTTP(
                    activation: .active,
                    configuration: DirectHTTPConnectionConfigurationV1(
                        receiverURLString: "https://synthetic.example/v1/batches",
                        bearerToken: "synthetic-legacy-token"
                    )
                ),
            ]
        )

        let restarted = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: tokenStore,
            preCutoverBackupStore: backupStore
        )
        XCTAssertEqual(try restarted.ensureAtomicConnectionRecord(), "synthetic-binding-41")
        XCTAssertEqual(try restarted.currentConnectionRecordV2(), record)
        XCTAssertEqual(tokenStore.savedToken, legacy)
        XCTAssertEqual(tokenStore.saveCount, 0)
        XCTAssertTrue(backupStore.savedToken.isEmpty)
    }

    func testSameValueDirectSaveKeepsV1PrimaryAcrossRestart() throws {
        let suiteName = "ConnectionRecordV2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = try authenticBaselineLegacyAtomicRecord(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-legacy-token",
            generation: 41,
            bindingID: "synthetic-binding-41"
        )
        let tokenStore = ConnectionV2CapturingTokenStore(initialToken: legacy)
        let backupStore = ConnectionV2CapturingTokenStore()
        let store = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: tokenStore,
            preCutoverBackupStore: backupStore
        )

        try store.save(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-legacy-token"
        )

        XCTAssertEqual(tokenStore.savedToken, legacy)
        XCTAssertTrue(backupStore.savedToken.isEmpty)
        let restarted = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: tokenStore,
            preCutoverBackupStore: backupStore
        )
        XCTAssertEqual(try restarted.ensureAtomicConnectionRecord(), "synthetic-binding-41")
        XCTAssertEqual(tokenStore.savedToken, legacy)
    }

    func testChangedDirectSaveKeepsStrictV1WithoutCutoverBackup() throws {
        let suiteName = "ConnectionRecordV2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = try legacyAtomicRecord(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-legacy-token",
            generation: 41,
            bindingID: "synthetic-binding-41"
        )
        let tokenStore = ConnectionV2CapturingTokenStore(initialToken: legacy)
        let backupStore = ConnectionV2CapturingTokenStore()
        let store = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: tokenStore,
            preCutoverBackupStore: backupStore
        )

        try store.save(
            receiverURLString: "https://changed.example/v1/batches",
            bearerToken: "synthetic-changed-token"
        )

        XCTAssertTrue(tokenStore.savedToken.hasPrefix("health-bridge-connection-v1:"))
        XCTAssertFalse(tokenStore.savedToken.hasPrefix("health-bridge-connection-v2:"))
        XCTAssertTrue(backupStore.savedToken.isEmpty)
        let projection = try XCTUnwrap(store.currentConnectionRecordV2())
        XCTAssertEqual(projection.localScope.generation, 42)
        XCTAssertFalse(projection.localScope.bindingID.isEmpty)
        XCTAssertEqual(
            projection.transportConfigurations,
            [
                .directHTTP(
                    activation: .active,
                    configuration: DirectHTTPConnectionConfigurationV1(
                        receiverURLString: "https://changed.example/v1/batches",
                        bearerToken: "synthetic-changed-token"
                    )
                ),
            ]
        )
    }

    func testChangedDirectSaveLeavesPrimaryAndMirrorsUnchangedWhenStaleBackupClearFails() throws {
        let suiteName = "ConnectionRecordV2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("https://synthetic.example/v1/batches", forKey: "receiverURLString")
        defaults.set(41, forKey: "receiverSettingsGeneration")
        let legacy = try legacyAtomicRecord(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-legacy-token",
            generation: 41,
            bindingID: "synthetic-binding-41"
        )
        let staleBackup = try legacyAtomicRecord(
            receiverURLString: "https://stale.example/v1/batches",
            bearerToken: "synthetic-stale-token",
            generation: 40,
            bindingID: "synthetic-stale-binding"
        )
        let tokenStore = ConnectionV2CapturingTokenStore(initialToken: legacy)
        let backupStore = ConnectionV2CapturingTokenStore(initialToken: staleBackup)
        backupStore.shouldFailSave = true
        let store = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: tokenStore,
            preCutoverBackupStore: backupStore
        )

        XCTAssertThrowsError(try store.save(
            receiverURLString: "https://changed.example/v1/batches",
            bearerToken: "synthetic-changed-token"
        ))
        XCTAssertEqual(tokenStore.savedToken, legacy)
        XCTAssertEqual(defaults.string(forKey: "receiverURLString"), "https://synthetic.example/v1/batches")
        XCTAssertEqual(defaults.integer(forKey: "receiverSettingsGeneration"), 41)
    }

    func testChangedDirectSaveKeepsV1PrimaryWhenPrimaryWriteFailsAfterStaleBackupClear() throws {
        let suiteName = "ConnectionRecordV2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("https://synthetic.example/v1/batches", forKey: "receiverURLString")
        defaults.set(41, forKey: "receiverSettingsGeneration")
        let legacy = try legacyAtomicRecord(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-legacy-token",
            generation: 41,
            bindingID: "synthetic-binding-41"
        )
        let staleBackup = try legacyAtomicRecord(
            receiverURLString: "https://stale.example/v1/batches",
            bearerToken: "synthetic-stale-token",
            generation: 40,
            bindingID: "synthetic-stale-binding"
        )
        let tokenStore = ConnectionV2CapturingTokenStore(initialToken: legacy)
        tokenStore.shouldFailSave = true
        let backupStore = ConnectionV2CapturingTokenStore(initialToken: staleBackup)
        let store = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: tokenStore,
            preCutoverBackupStore: backupStore
        )

        XCTAssertThrowsError(try store.save(
            receiverURLString: "https://changed.example/v1/batches",
            bearerToken: "synthetic-changed-token"
        ))
        XCTAssertEqual(tokenStore.savedToken, legacy)
        XCTAssertTrue(backupStore.savedToken.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "receiverURLString"), "https://synthetic.example/v1/batches")
        XCTAssertEqual(defaults.integer(forKey: "receiverSettingsGeneration"), 41)
    }

    func testUnknownFieldPrimaryV1CannotCutOverToMailbox() throws {
        let suiteName = "ConnectionRecordV2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let rawJSON = #"{"version":1,"receiverURLString":"https://synthetic.example/v1/batches","bearerToken":"synthetic-legacy-token","generation":41,"bindingID":"synthetic-binding-41","unexpected":"synthetic"}"#
        let raw = "health-bridge-connection-v1:" + Data(rawJSON.utf8).base64EncodedString()
        let tokenStore = ConnectionV2CapturingTokenStore(initialToken: raw)
        let backupStore = ConnectionV2CapturingTokenStore()
        let store = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: tokenStore,
            preCutoverBackupStore: backupStore
        )

        XCTAssertThrowsError(try store.saveMailboxPairing(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-legacy-token",
            mailboxIdentity: syntheticMailboxIdentity(connectionGeneration: 42),
            expectedGeneration: "g41"
        )) { error in
            XCTAssertEqual(error as? ReceiverSettingsRecordError, .invalidRecord)
        }
        XCTAssertEqual(tokenStore.savedToken, raw)
        XCTAssertEqual(tokenStore.saveCount, 0)
        XCTAssertTrue(backupStore.savedToken.isEmpty)
        XCTAssertEqual(backupStore.saveCount, 0)
    }

    func testMatchingV2AndCanonicalBackupRestorePrimaryV1Bytes() throws {
        let suiteName = "ConnectionRecordV2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("https://stale.example/v1/batches", forKey: "receiverURLString")
        defaults.set(1, forKey: "receiverSettingsGeneration")
        let legacy = try legacyAtomicRecord(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-legacy-token",
            generation: 41,
            bindingID: "synthetic-binding-41"
        )
        let projection = directHTTPProjection(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-legacy-token",
            generation: 41,
            bindingID: "synthetic-binding-41"
        )
        let currentV2 = try taggedV2Record(projection)
        let tokenStore = ConnectionV2CapturingTokenStore(initialToken: currentV2)
        let backupStore = ConnectionV2CapturingTokenStore(initialToken: legacy)
        let store = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: tokenStore,
            preCutoverBackupStore: backupStore
        )

        XCTAssertEqual(try store.ensureAtomicConnectionRecord(), "synthetic-binding-41")
        XCTAssertEqual(tokenStore.savedToken, legacy)
        XCTAssertEqual(tokenStore.saveCount, 1)
        XCTAssertEqual(backupStore.savedToken, legacy)
        XCTAssertEqual(backupStore.saveCount, 0)
        XCTAssertEqual(store.receiverURLString, "https://synthetic.example/v1/batches")
        XCTAssertEqual(store.receiverSettingsGenerationToken, "g41")
        XCTAssertEqual(try store.currentConnectionRecordV2(), projection)
        XCTAssertEqual(tokenStore.savedToken, legacy)
        XCTAssertEqual(tokenStore.saveCount, 1)
    }

    func testMatchingV2AndAuthenticBaselineBackupRestorePrimaryV1Bytes() throws {
        let suiteName = "ConnectionRecordV2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = try authenticBaselineLegacyAtomicRecord(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-legacy-token",
            generation: 41,
            bindingID: "synthetic-binding-41"
        )
        let projection = directHTTPProjection(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-legacy-token",
            generation: 41,
            bindingID: "synthetic-binding-41"
        )
        let currentV2 = try taggedV2Record(projection)
        let tokenStore = ConnectionV2CapturingTokenStore(initialToken: currentV2)
        let backupStore = ConnectionV2CapturingTokenStore(initialToken: legacy)
        let store = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: tokenStore,
            preCutoverBackupStore: backupStore
        )

        XCTAssertEqual(try store.ensureAtomicConnectionRecord(), "synthetic-binding-41")
        XCTAssertEqual(tokenStore.savedToken, legacy)
        XCTAssertEqual(tokenStore.saveCount, 1)
        XCTAssertEqual(try store.currentConnectionRecordV2(), projection)
        XCTAssertEqual(tokenStore.savedToken, legacy)
    }

    func testNoncanonicalOrAmbiguousV2NeverRestoresPreCutoverBackup() throws {
        let record = directHTTPProjection(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-legacy-token",
            generation: 41,
            bindingID: "synthetic-binding-41"
        )
        let canonical = try taggedV2Record(record)
        let encoded = String(canonical.dropFirst("health-bridge-connection-v2:".count))
        let canonicalData = try XCTUnwrap(Data(base64Encoded: encoded))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonicalData) as? [String: Any]
        )
        object["unexpected"] = "synthetic"
        let unknownData = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        let canonicalJSON = try XCTUnwrap(String(data: canonicalData, encoding: .utf8))
        let duplicateJSON = "{\"version\":2," + String(canonicalJSON.dropFirst())
        let candidates = [
            "health-bridge-connection-v2:" + unknownData.base64EncodedString(),
            "health-bridge-connection-v2:" + Data(duplicateJSON.utf8).base64EncodedString(),
        ]
        let legacy = try legacyAtomicRecord(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-legacy-token",
            generation: 41,
            bindingID: "synthetic-binding-41"
        )

        for candidate in candidates {
            let suiteName = "ConnectionRecordV2Tests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let tokenStore = ConnectionV2CapturingTokenStore(initialToken: candidate)
            let backupStore = ConnectionV2CapturingTokenStore(initialToken: legacy)
            let store = ReceiverSettingsStore(
                userDefaults: defaults,
                tokenStore: tokenStore,
                preCutoverBackupStore: backupStore
            )

            XCTAssertThrowsError(try store.ensureAtomicConnectionRecord()) { error in
                XCTAssertEqual(error as? ReceiverSettingsRecordError, .invalidRecord)
            }
            XCTAssertEqual(tokenStore.savedToken, candidate)
            XCTAssertEqual(tokenStore.saveCount, 0)
            XCTAssertEqual(backupStore.savedToken, legacy)
        }
    }

    func testV2RestoreRequiresExactDirectHTTPProjection() throws {
        let legacy = try legacyAtomicRecord(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-legacy-token",
            generation: 41,
            bindingID: "synthetic-binding-41"
        )
        let mailboxIdentity = syntheticMailboxIdentity(connectionGeneration: 41)
        let direct = DirectHTTPConnectionConfigurationV1(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-legacy-token"
        )
        let mismatches: [(String, ReceiverConnectionRecordV2)] = [
            (
                "generation",
                directHTTPProjection(
                    receiverURLString: direct.receiverURLString,
                    bearerToken: direct.bearerToken,
                    generation: 42,
                    bindingID: "synthetic-binding-41"
                )
            ),
            (
                "binding",
                directHTTPProjection(
                    receiverURLString: direct.receiverURLString,
                    bearerToken: direct.bearerToken,
                    generation: 41,
                    bindingID: "synthetic-binding-other"
                )
            ),
            (
                "endpoint",
                directHTTPProjection(
                    receiverURLString: "https://different.example/v1/batches",
                    bearerToken: direct.bearerToken,
                    generation: 41,
                    bindingID: "synthetic-binding-41"
                )
            ),
            (
                "bearer token",
                directHTTPProjection(
                    receiverURLString: direct.receiverURLString,
                    bearerToken: "synthetic-different-token",
                    generation: 41,
                    bindingID: "synthetic-binding-41"
                )
            ),
            (
                "mailbox identity",
                ReceiverConnectionRecordV2(
                    localScope: ReceiverLocalConnectionScopeV1(
                        generation: 41,
                        bindingID: "synthetic-binding-41"
                    ),
                    mailboxIdentity: .available(mailboxIdentity),
                    activation: .paired(activeTransport: .directHTTP),
                    transportConfigurations: [
                        .directHTTP(activation: .active, configuration: direct),
                    ]
                )
            ),
            (
                "extra inactive transport",
                ReceiverConnectionRecordV2(
                    localScope: ReceiverLocalConnectionScopeV1(
                        generation: 41,
                        bindingID: "synthetic-binding-41"
                    ),
                    mailboxIdentity: .available(mailboxIdentity),
                    activation: .paired(activeTransport: .directHTTP),
                    transportConfigurations: [
                        .directHTTP(activation: .active, configuration: direct),
                        .mailbox(
                            activation: .inactive,
                            configuration: MailboxConnectionConfigurationV1()
                        ),
                    ]
                )
            ),
            (
                "mailbox active and direct inactive",
                ReceiverConnectionRecordV2(
                    localScope: ReceiverLocalConnectionScopeV1(
                        generation: 41,
                        bindingID: "synthetic-binding-41"
                    ),
                    mailboxIdentity: .available(mailboxIdentity),
                    activation: .paired(activeTransport: .mailbox),
                    transportConfigurations: [
                        .directHTTP(activation: .inactive, configuration: direct),
                        .mailbox(
                            activation: .active,
                            configuration: MailboxConnectionConfigurationV1()
                        ),
                    ]
                )
            ),
        ]

        for (name, record) in mismatches {
            let suiteName = "ConnectionRecordV2Tests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let currentV2 = try taggedV2Record(record)
            let tokenStore = ConnectionV2CapturingTokenStore(initialToken: currentV2)
            let backupStore = ConnectionV2CapturingTokenStore(initialToken: legacy)
            let store = ReceiverSettingsStore(
                userDefaults: defaults,
                tokenStore: tokenStore,
                preCutoverBackupStore: backupStore
            )

            _ = try store.ensureAtomicConnectionRecord()

            XCTAssertEqual(tokenStore.savedToken, currentV2, name)
            XCTAssertEqual(tokenStore.saveCount, 0, name)
            XCTAssertEqual(backupStore.savedToken, legacy, name)
            XCTAssertEqual(backupStore.saveCount, 0, name)
        }
    }

    func testAbsentBackupDoesNotRewritePrimaryV2() throws {
        let suiteName = "ConnectionRecordV2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let record = directHTTPProjection(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-legacy-token",
            generation: 41,
            bindingID: "synthetic-binding-41"
        )
        let currentV2 = try taggedV2Record(record)
        let tokenStore = ConnectionV2CapturingTokenStore(initialToken: currentV2)
        let backupStore = ConnectionV2CapturingTokenStore()
        let store = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: tokenStore,
            preCutoverBackupStore: backupStore
        )

        XCTAssertEqual(try store.currentConnectionRecordV2(), record)
        XCTAssertEqual(tokenStore.savedToken, currentV2)
        XCTAssertEqual(tokenStore.saveCount, 0)
        XCTAssertTrue(backupStore.savedToken.isEmpty)
    }

    func testMalformedOrUnknownFieldBackupFailsClosedWithoutRewritingV2() throws {
        let record = directHTTPProjection(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-legacy-token",
            generation: 41,
            bindingID: "synthetic-binding-41"
        )
        let currentV2 = try taggedV2Record(record)
        let unknownFieldJSON = #"{"version":1,"receiverURLString":"https://synthetic.example/v1/batches","bearerToken":"synthetic-legacy-token","generation":41,"bindingID":"synthetic-binding-41","unexpected":"synthetic"}"#
        let duplicateFieldJSON = #"{"version":1,"version":1,"receiverURLString":"https://synthetic.example/v1/batches","bearerToken":"synthetic-legacy-token","generation":41,"bindingID":"synthetic-binding-41"}"#
        let backups = [
            "health-bridge-connection-v1:not-base64",
            "health-bridge-connection-v1:" + Data(unknownFieldJSON.utf8).base64EncodedString(),
            "health-bridge-connection-v1:" + Data(duplicateFieldJSON.utf8).base64EncodedString(),
        ]

        for backup in backups {
            let suiteName = "ConnectionRecordV2Tests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let tokenStore = ConnectionV2CapturingTokenStore(initialToken: currentV2)
            let backupStore = ConnectionV2CapturingTokenStore(initialToken: backup)
            let store = ReceiverSettingsStore(
                userDefaults: defaults,
                tokenStore: tokenStore,
                preCutoverBackupStore: backupStore
            )

            XCTAssertThrowsError(try store.ensureAtomicConnectionRecord()) { error in
                XCTAssertEqual(error as? ReceiverSettingsRecordError, .invalidRecord)
            }
            XCTAssertEqual(tokenStore.savedToken, currentV2)
            XCTAssertEqual(tokenStore.saveCount, 0)
            XCTAssertEqual(backupStore.savedToken, backup)
            XCTAssertEqual(backupStore.saveCount, 0)
        }
    }

    func testFailedMatchingV2RestorePreservesPrimaryAndMirrors() throws {
        let suiteName = "ConnectionRecordV2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("https://unchanged.example/v1/batches", forKey: "receiverURLString")
        defaults.set(9, forKey: "receiverSettingsGeneration")
        let legacy = try legacyAtomicRecord(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-legacy-token",
            generation: 41,
            bindingID: "synthetic-binding-41"
        )
        let currentV2 = try taggedV2Record(directHTTPProjection(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-legacy-token",
            generation: 41,
            bindingID: "synthetic-binding-41"
        ))
        let tokenStore = ConnectionV2CapturingTokenStore(initialToken: currentV2)
        tokenStore.shouldFailSave = true
        let backupStore = ConnectionV2CapturingTokenStore(initialToken: legacy)
        let store = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: tokenStore,
            preCutoverBackupStore: backupStore
        )

        XCTAssertThrowsError(try store.ensureAtomicConnectionRecord())
        XCTAssertEqual(tokenStore.savedToken, currentV2)
        XCTAssertEqual(defaults.string(forKey: "receiverURLString"), "https://unchanged.example/v1/batches")
        XCTAssertEqual(defaults.integer(forKey: "receiverSettingsGeneration"), 9)
    }

    func testNewPairedDirectWriteUsesV1WithProjectedUnavailableMailboxIdentity() throws {
        let suiteName = "ConnectionRecordV2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tokenStore = ConnectionV2CapturingTokenStore()
        let backupStore = ConnectionV2CapturingTokenStore()
        let store = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: tokenStore,
            preCutoverBackupStore: backupStore
        )

        try store.save(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-new-token"
        )

        XCTAssertTrue(
            tokenStore.savedToken.hasPrefix("health-bridge-connection-v1:"),
            "direct-only atomic connection writes must remain rollback-readable V1"
        )
        let record = try XCTUnwrap(store.currentConnectionRecordV2())
        XCTAssertEqual(record.mailboxIdentity, .unavailable(.notProvisionedByLegacyHTTPPairing))
        XCTAssertEqual(record.activation, .paired(activeTransport: .directHTTP))
        XCTAssertTrue(backupStore.savedToken.isEmpty)
    }

    func testUnpairedStateUsesV1AndDeletesStalePreCutoverBackup() throws {
        let suiteName = "ConnectionRecordV2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tokenStore = ConnectionV2CapturingTokenStore()
        let backupStore = ConnectionV2CapturingTokenStore(initialToken: "preserved-v1-backup")
        let store = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: tokenStore,
            preCutoverBackupStore: backupStore
        )

        try store.clearReceiverSettings()

        let record = try XCTUnwrap(store.currentConnectionRecordV2())
        XCTAssertEqual(record.activation, .unpaired)
        XCTAssertTrue(record.transportConfigurations.isEmpty)
        XCTAssertEqual(record.localScope.bindingID, "")
        XCTAssertEqual(record.mailboxIdentity, .unavailable(.notProvisionedByLegacyHTTPPairing))
        XCTAssertTrue(tokenStore.savedToken.hasPrefix("health-bridge-connection-v1:"))
        XCTAssertTrue(backupStore.savedToken.isEmpty)
    }

    func testMailboxCutoverNeverOccursWhenV1BackupCannotBePreserved() throws {
        let suiteName = "ConnectionRecordV2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = try legacyAtomicRecord(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-legacy-token",
            generation: 7,
            bindingID: "synthetic-binding-7"
        )
        let tokenStore = ConnectionV2CapturingTokenStore(initialToken: legacy)
        let backupStore = ConnectionV2CapturingTokenStore()
        backupStore.shouldFailSave = true
        let store = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: tokenStore,
            preCutoverBackupStore: backupStore
        )

        XCTAssertThrowsError(try store.saveMailboxPairing(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-legacy-token",
            mailboxIdentity: syntheticMailboxIdentity(connectionGeneration: 8),
            expectedGeneration: "g7"
        ))
        XCTAssertEqual(tokenStore.savedToken, legacy)
        XCTAssertTrue(backupStore.savedToken.isEmpty)
    }

    func testMailboxCutoverKeepsV1PrimaryWhenV2WriteFailsAfterBackup() throws {
        let suiteName = "ConnectionRecordV2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = try legacyAtomicRecord(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-legacy-token",
            generation: 8,
            bindingID: "synthetic-binding-8"
        )
        let tokenStore = ConnectionV2CapturingTokenStore(initialToken: legacy)
        let backupStore = ConnectionV2CapturingTokenStore()
        tokenStore.shouldFailSave = true
        let store = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: tokenStore,
            preCutoverBackupStore: backupStore
        )

        let identity = syntheticMailboxIdentity(connectionGeneration: 9)
        XCTAssertThrowsError(try store.saveMailboxPairing(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-legacy-token",
            mailboxIdentity: identity,
            expectedGeneration: "g8"
        ))
        XCTAssertEqual(tokenStore.savedToken, legacy)
        XCTAssertEqual(backupStore.savedToken, legacy)

        tokenStore.shouldFailSave = false
        try store.saveMailboxPairing(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-legacy-token",
            mailboxIdentity: identity,
            expectedGeneration: "g8"
        )
        XCTAssertTrue(tokenStore.savedToken.hasPrefix("health-bridge-connection-v2:"))
        XCTAssertEqual(backupStore.savedToken, legacy)
        let record = try XCTUnwrap(store.currentConnectionRecordV2())
        XCTAssertEqual(record.activation, .paired(activeTransport: .mailbox))
        XCTAssertEqual(record.mailboxIdentity, .available(identity))
    }

    func testMailboxIdentityAvailabilityRoundTripsEveryRequiredIdentifier() throws {
        let identity = syntheticMailboxIdentity(connectionGeneration: 43)
        let available = MailboxConnectionIdentityAvailability.available(identity)

        let encoded = try JSONEncoder().encode(available)
        let decoded = try JSONDecoder().decode(
            MailboxConnectionIdentityAvailability.self,
            from: encoded
        )

        XCTAssertEqual(decoded, available)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["availability"] as? String, "available")
        let encodedIdentity = try XCTUnwrap(object["identity"] as? [String: Any])
        XCTAssertEqual(Set(encodedIdentity.keys), [
            "connectionGeneration",
            "deviceID",
            "deviceAgreementKeyID",
            "devicePrincipal",
            "deviceSigningKeyID",
            "opaqueBinding",
            "receiverAgreementKeyID",
            "receiverAgreementPublicKey",
            "receiverID",
            "receiverSigningKeyID",
            "receiverSigningPublicKey",
        ])
        XCTAssertFalse(encodedIdentity.values.contains { $0 is NSNull })
    }

    func testMailboxActiveRecordRetainsInactiveDirectConfigurationExactly() throws {
        let suiteName = "ConnectionRecordV2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identity = syntheticMailboxIdentity(connectionGeneration: 91)
        let record = ReceiverConnectionRecordV2(
            localScope: ReceiverLocalConnectionScopeV1(
                generation: 18,
                bindingID: "synthetic-local-binding"
            ),
            mailboxIdentity: .available(identity),
            activation: .paired(activeTransport: .mailbox),
            transportConfigurations: [
                .directHTTP(
                    activation: .inactive,
                    configuration: DirectHTTPConnectionConfigurationV1(
                        receiverURLString: "https://synthetic.example/v1/batches",
                        bearerToken: "synthetic-retained-token"
                    )
                ),
                .mailbox(
                    activation: .active,
                    configuration: MailboxConnectionConfigurationV1()
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let raw = "health-bridge-connection-v2:"
            + (try encoder.encode(record)).base64EncodedString()
        let tokenStore = ConnectionV2CapturingTokenStore(initialToken: raw)
        let store = ReceiverSettingsStore(userDefaults: defaults, tokenStore: tokenStore)

        XCTAssertEqual(try store.ensureAtomicConnectionRecord(), "synthetic-local-binding")
        XCTAssertEqual(try store.currentConnectionRecordV2(), record)
        XCTAssertEqual(store.receiverURLString, "https://synthetic.example/v1/batches")
        XCTAssertEqual(try store.loadBearerToken(), "synthetic-retained-token")
        XCTAssertEqual(store.receiverSettingsGenerationToken, "g18")
        XCTAssertEqual(tokenStore.savedToken, raw)
    }

    func testLegacyMutationsHoldWhileMailboxTransportIsActive() throws {
        let suiteName = "ConnectionRecordV2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identity = syntheticMailboxIdentity(connectionGeneration: 92)
        let record = ReceiverConnectionRecordV2(
            localScope: ReceiverLocalConnectionScopeV1(
                generation: 19,
                bindingID: "synthetic-local-binding"
            ),
            mailboxIdentity: .available(identity),
            activation: .paired(activeTransport: .mailbox),
            transportConfigurations: [
                .directHTTP(
                    activation: .inactive,
                    configuration: DirectHTTPConnectionConfigurationV1(
                        receiverURLString: "https://synthetic.example/v1/batches",
                        bearerToken: "synthetic-retained-token"
                    )
                ),
                .mailbox(
                    activation: .active,
                    configuration: MailboxConnectionConfigurationV1()
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let raw = "health-bridge-connection-v2:"
            + (try encoder.encode(record)).base64EncodedString()
        let tokenStore = ConnectionV2CapturingTokenStore(initialToken: raw)
        let backupStore = ConnectionV2CapturingTokenStore()
        let store = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: tokenStore,
            preCutoverBackupStore: backupStore
        )

        XCTAssertThrowsError(
            try store.save(
                receiverURLString: "https://replacement.example/v1/batches",
                bearerToken: "synthetic-replacement-token"
            )
        ) { error in
            XCTAssertEqual(
                error as? ReceiverSettingsRecordError,
                .transportSwitchRequiresCommittedEmptyOutbox
            )
        }
        XCTAssertThrowsError(try store.clearReceiverSettings()) { error in
            XCTAssertEqual(
                error as? ReceiverSettingsRecordError,
                .transportSwitchRequiresCommittedEmptyOutbox
            )
        }
        XCTAssertEqual(tokenStore.savedToken, raw)
        XCTAssertEqual(try store.currentConnectionRecordV2(), record)
        XCTAssertEqual(store.receiverURLString, "https://synthetic.example/v1/batches")
        XCTAssertEqual(try store.loadBearerToken(), "synthetic-retained-token")
        XCTAssertEqual(store.receiverSettingsGenerationToken, "g19")
        XCTAssertEqual(store.receiverBindingID, "synthetic-local-binding")
        XCTAssertTrue(backupStore.savedToken.isEmpty)
    }

    func testMailboxPairingWriteActivatesMailboxAndRetainsDirectFallback() throws {
        let suiteName = "ConnectionRecordV2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tokenStore = ConnectionV2CapturingTokenStore()
        let store = ReceiverSettingsStore(
            userDefaults: defaults,
            tokenStore: tokenStore
        )
        let identity = syntheticMailboxIdentity(connectionGeneration: 1)

        try store.saveMailboxPairing(
            receiverURLString: "https://synthetic.example/v1/batches",
            bearerToken: "synthetic-retained-token",
            mailboxIdentity: identity,
            expectedGeneration: "g0"
        )

        let record = try XCTUnwrap(store.currentConnectionRecordV2())
        XCTAssertEqual(record.localScope.bindingID, identity.opaqueBinding)
        XCTAssertEqual(record.mailboxIdentity, .available(identity))
        XCTAssertEqual(record.activation, .paired(activeTransport: .mailbox))
        XCTAssertEqual(record.transportConfigurations, [
            .directHTTP(
                activation: .inactive,
                configuration: DirectHTTPConnectionConfigurationV1(
                    receiverURLString: "https://synthetic.example/v1/batches",
                    bearerToken: "synthetic-retained-token"
                )
            ),
            .mailbox(
                activation: .active,
                configuration: MailboxConnectionConfigurationV1()
            ),
        ])
    }

    func testMalformedV2TagAndTornLegacyStateRemainRepairRequired() throws {
        let suiteName = "ConnectionRecordV2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let malformed = Data(#"{"version":2,"activation":{"state":"invented"}}"#.utf8)
        let tokenStore = ConnectionV2CapturingTokenStore(
            initialToken: "health-bridge-connection-v2:" + malformed.base64EncodedString()
        )
        let store = ReceiverSettingsStore(userDefaults: defaults, tokenStore: tokenStore)
        XCTAssertThrowsError(try store.ensureAtomicConnectionRecord()) { error in
            XCTAssertEqual(error as? ReceiverSettingsRecordError, .invalidRecord)
        }

        let tornStore = ConnectionV2CapturingTokenStore(initialToken: "synthetic-token-only")
        let torn = ReceiverSettingsStore(userDefaults: defaults, tokenStore: tornStore)
        XCTAssertThrowsError(try torn.ensureAtomicConnectionRecord()) { error in
            XCTAssertEqual(error as? ReceiverSettingsRecordError, .invalidRecord)
        }
    }
}

private func syntheticMailboxIdentity(
    connectionGeneration: UInt64
) -> MailboxConnectionIdentityV1 {
    MailboxConnectionIdentityV1(
        receiverID: String(repeating: "1", count: 32),
        deviceID: String(repeating: "2", count: 32),
        devicePrincipal: "installation:" + String(repeating: "3", count: 64),
        deviceSigningKeyID: String(repeating: "4", count: 32),
        deviceAgreementKeyID: String(repeating: "5", count: 32),
        receiverSigningKeyID: "6c9a98e60055e4d14e5d591d6b7c1104",
        receiverAgreementKeyID: "cf09eac7ec4fb8e8acc48b7cc1ee77e5",
        receiverSigningPublicKey: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
        receiverAgreementPublicKey: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8",
        opaqueBinding: "Q0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0M",
        connectionGeneration: connectionGeneration
    )
}

private final class ConnectionV2CapturingTokenStore: ReceiverTokenStoring {
    private(set) var savedToken: String
    private(set) var saveCount = 0
    var shouldFailSave = false

    init(initialToken: String = "") {
        savedToken = initialToken
    }

    func loadToken() throws -> String {
        savedToken
    }

    func saveToken(_ token: String) throws {
        saveCount += 1
        if shouldFailSave {
            throw ConnectionV2SyntheticError.saveFailed
        }
        savedToken = token
    }
}

private enum ConnectionV2SyntheticError: Error {
    case saveFailed
}

private func legacyAtomicRecord(
    receiverURLString: String,
    bearerToken: String,
    generation: UInt64,
    bindingID: String
) throws -> String {
    let object: [String: Any] = [
        "bearerToken": bearerToken,
        "bindingID": bindingID,
        "generation": generation,
        "receiverURLString": receiverURLString,
        "version": 1,
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return "health-bridge-connection-v1:" + data.base64EncodedString()
}

private struct AuthenticBaselineConnectionRecordV1: Codable {
    let version: Int
    let receiverURLString: String
    let bearerToken: String
    let generation: UInt64
    let bindingID: String
}

private func authenticBaselineLegacyAtomicRecord(
    receiverURLString: String,
    bearerToken: String,
    generation: UInt64,
    bindingID: String
) throws -> String {
    let record = AuthenticBaselineConnectionRecordV1(
        version: 1,
        receiverURLString: receiverURLString,
        bearerToken: bearerToken,
        generation: generation,
        bindingID: bindingID
    )
    let data = try JSONEncoder().encode(record)
    return "health-bridge-connection-v1:" + data.base64EncodedString()
}

private func directHTTPProjection(
    receiverURLString: String,
    bearerToken: String,
    generation: UInt64,
    bindingID: String
) -> ReceiverConnectionRecordV2 {
    ReceiverConnectionRecordV2(
        localScope: ReceiverLocalConnectionScopeV1(
            generation: generation,
            bindingID: bindingID
        ),
        mailboxIdentity: .unavailable(.notProvisionedByLegacyHTTPPairing),
        activation: .paired(activeTransport: .directHTTP),
        transportConfigurations: [
            .directHTTP(
                activation: .active,
                configuration: DirectHTTPConnectionConfigurationV1(
                    receiverURLString: receiverURLString,
                    bearerToken: bearerToken
                )
            ),
        ]
    )
}

private func taggedV2Record(_ record: ReceiverConnectionRecordV2) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return "health-bridge-connection-v2:"
        + (try encoder.encode(record)).base64EncodedString()
}
