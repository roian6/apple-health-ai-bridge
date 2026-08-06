import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class RepairSyntheticMailboxKeychain: MailboxKeychainClient, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var privateItems: [String: Data] = [:]
    private var trustItems: [String: Data] = [:]
    private var storeCount = 0
    private var removalCount = 0
    var storeFailureNumber: Int?
    var removalFailureNumber: Int?
    var transactionBarrier: (@Sendable () -> Void)?

    init(transactionBarrier: (@Sendable () -> Void)? = nil) {
        self.transactionBarrier = transactionBarrier
    }

    func withExclusiveAccess<T>(service: String, _ body: () throws -> T) throws -> T {
        transactionBarrier?()
        return try lock.withLock(body)
    }

    func data(service: String, account: String) throws -> Data? {
        lock.withLock { privateItems["\(service)\0\(account)"] }
    }

    func store(_ data: Data, service: String, account: String) throws {
        try lock.withLock {
            try failStoreWhenConfigured()
            privateItems["\(service)\0\(account)"] = data
        }
    }

    func trustData(service: String, record: MailboxTrustRecord) throws -> Data? {
        lock.withLock { trustItems["\(service)\0\(record.rawValue)"] }
    }

    func storeTrust(
        _ data: Data,
        service: String,
        record: MailboxTrustRecord
    ) throws {
        try lock.withLock {
            try failStoreWhenConfigured()
            trustItems["\(service)\0\(record.rawValue)"] = data
        }
    }

    func remove(service: String, account: String) throws {
        try lock.withLock {
            try failRemovalWhenConfigured()
            privateItems.removeValue(forKey: "\(service)\0\(account)")
        }
    }

    func removeTrust(service: String, record: MailboxTrustRecord) throws {
        try lock.withLock {
            try failRemovalWhenConfigured()
            trustItems.removeValue(forKey: "\(service)\0\(record.rawValue)")
        }
    }

    func removePrivateIdentity() {
        lock.withLock {
            privateItems = privateItems.filter { key, _ in
                !key.hasSuffix("\0identity-v1")
            }
        }
    }

    func removePrivateIdentityAndMarker() {
        lock.withLock {
            privateItems = privateItems.filter { key, _ in
                !key.hasSuffix("\0identity-v1") && !key.hasSuffix("\0initialized-v1")
            }
        }
    }

    func removeExpectedIdentity() {
        lock.withLock {
            privateItems = privateItems.filter { key, _ in
                !key.hasSuffix("\0expected-identity-v1")
            }
            trustItems = trustItems.filter { key, _ in
                !key.hasSuffix("\0expected-identity-v1")
            }
        }
    }

    func removeProvisioning() {
        lock.withLock {
            trustItems = trustItems.filter { key, _ in
                !key.hasSuffix("\0monotonic-generation-v1")
            }
        }
    }

    func allStateSnapshot() -> RepairAllStateSnapshot {
        lock.withLock {
            RepairAllStateSnapshot(
                privateItems: privateItems,
                trustItems: trustItems
            )
        }
    }

    func simulateTransitionCrash(
        old: RepairAllStateSnapshot,
        new: RepairAllStateSnapshot,
        includeExpectedAnchor: Bool
    ) {
        lock.withLock {
            privateItems = old.privateItems
            trustItems = old.trustItems
            if let identity = new.privateItems.first(where: {
                $0.key.hasSuffix("\0identity-v1")
            }) {
                privateItems[identity.key] = identity.value
            }
            if includeExpectedAnchor,
               let anchor = new.trustItems.first(where: {
                   $0.key.hasSuffix("\0expected-identity-v1")
               }) {
                trustItems[anchor.key] = anchor.value
            }
        }
    }

    func mutableStateSnapshot() -> RepairMutableStateSnapshot {
        lock.withLock {
            RepairMutableStateSnapshot(
                privateItems: privateItems.filter { key, _ in
                    key.hasSuffix("\0identity-v1")
                        || key.hasSuffix("\0expected-identity-v1")
                },
                trustItems: trustItems.filter { key, _ in
                    key.hasSuffix("\0expected-identity-v1")
                }
            )
        }
    }

    func restoreMutableState(_ snapshot: RepairMutableStateSnapshot) {
        lock.withLock {
            privateItems = privateItems.filter { key, _ in
                !key.hasSuffix("\0identity-v1") && !key.hasSuffix("\0expected-identity-v1")
            }
            trustItems = trustItems.filter { key, _ in
                !key.hasSuffix("\0expected-identity-v1")
            }
            privateItems.merge(snapshot.privateItems) { _, restored in restored }
            trustItems.merge(snapshot.trustItems) { _, restored in restored }
        }
    }

    func expectedSigningKeyID() -> String? {
        lock.withLock {
            guard let data = expectedIdentityDataLocked(),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }
            return json["signing_key_id"] as? String
        }
    }

    func persistedContinuityData() -> Data? {
        lock.withLock {
            guard let data = expectedIdentityDataLocked(),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let continuity = json["continuity"]
            else {
                return nil
            }
            return try? JSONSerialization.data(
                withJSONObject: continuity,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        }
    }

    func expectedIdentityData() -> Data? {
        lock.withLock {
            expectedIdentityDataLocked()
        }
    }

    func mutateIdentityJSON(_ mutate: (inout [String: Any]) -> Void) {
        lock.withLock {
            guard let entry = privateItems.first(where: { $0.key.hasSuffix("\0identity-v1") }),
                  var json = try? JSONSerialization.jsonObject(with: entry.value) as? [String: Any],
                  case let key = entry.key
            else {
                return
            }
            mutate(&json)
            privateItems[key] = try? JSONSerialization.data(
                withJSONObject: json,
                options: [.sortedKeys]
            )
        }
    }

    func replaceMarker(_ data: Data) {
        lock.withLock {
            guard let key = privateItems.keys.first(where: {
                $0.hasSuffix("initialized-v1")
            }) else {
                return
            }
            privateItems[key] = data
        }
    }

    func replaceExpectedIdentity(_ data: Data) {
        lock.withLock {
            if let key = trustItems.keys.first(where: {
                $0.hasSuffix("\0expected-identity-v1")
            }) {
                trustItems[key] = data
                return
            }
            guard let key = privateItems.keys.first(where: {
                $0.hasSuffix("\0expected-identity-v1")
            }) else {
                return
            }
            privateItems[key] = data
        }
    }

    private func expectedIdentityDataLocked() -> Data? {
        trustItems.first(where: { $0.key.hasSuffix("\0expected-identity-v1") })?.value
            ?? privateItems.first(where: {
                $0.key.hasSuffix("\0expected-identity-v1")
            })?.value
    }

    private func failStoreWhenConfigured() throws {
        storeCount += 1
        if storeCount == storeFailureNumber {
            throw MailboxKeychainBackendError(status: errSecNotAvailable)
        }
    }

    private func failRemovalWhenConfigured() throws {
        removalCount += 1
        if removalCount == removalFailureNumber {
            throw MailboxKeychainBackendError(status: errSecNotAvailable)
        }
    }
}

struct RepairMutableStateSnapshot {
    let privateItems: [String: Data]
    let trustItems: [String: Data]
}

struct RepairAllStateSnapshot: Equatable {
    let privateItems: [String: Data]
    let trustItems: [String: Data]

    var isEmpty: Bool {
        privateItems.isEmpty && trustItems.isEmpty
    }
}

extension MailboxKeyRecoveryAuthorization {
    static let allowedForTesting = Self(
        receiverActivationIsUnpaired: true,
        pendingPairingExists: false,
        terminalTransitionIsPending: false,
        pendingOutboxCount: 0,
        operationIsActive: false
    )
}

final class RepairBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private let participants: Int
    private var arrivals = 0

    init(participants: Int) {
        self.participants = participants
    }

    func wait() {
        condition.lock()
        arrivals += 1
        if arrivals == participants {
            condition.broadcast()
        } else {
            while arrivals < participants {
                condition.wait()
            }
        }
        condition.unlock()
    }
}

final class RepairResults<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []
    private var capturedErrors: [MailboxKeyStoreError] = []

    func capture(_ operation: () throws -> Value) {
        do {
            let value = try operation()
            lock.withLock { values.append(value) }
        } catch let error as MailboxKeyStoreError {
            lock.withLock { capturedErrors.append(error) }
        } catch {
            XCTFail("unexpected error type")
        }
    }

    func successes() throws -> [Value] {
        lock.withLock { values }
    }

    func errors() -> [MailboxKeyStoreError] {
        lock.withLock { capturedErrors }
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

func repairService() -> String {
    "com.example.HealthBridgeCompanion.mailbox-repair-tests.\(UUID().uuidString)"
}
