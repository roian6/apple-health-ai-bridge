#if HEALTH_BRIDGE_ISOLATED_HELPER_TEST_HOST
import CryptoKit
import Darwin
import Foundation

// Compiled with the real main.swift body; no Bundle, Security or ubiquity entry.
enum NativePairingLocalFakeTests {
    private struct Failure: Error { let message: String }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message: message) }
    }
    private static func refuses(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw Failure(message: "Unsafe input was accepted")
    }

    static func runAll() {
        let tests: [(String, () throws -> Void)] = [
            ("testNativeCancellationCapability", testNativeCancellationCapability),
            ("testNativeExactPublicationReceiptAndIdempotence", testNativeExactPublicationReceiptAndIdempotence),
            ("testNativeRefusalsAfterCapability", testNativeRefusalsAfterCapability),
            ("testExistingACKExactPublicationAndIdempotence", testExistingACKExactPublicationAndIdempotence),
            ("testExistingACKRefusesUnsafeInputs", testExistingACKRefusesUnsafeInputs),
        ]
        var failed = 0
        for (name, body) in tests {
            do { try body(); print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        print("CASES=\(tests.count) PASSED=\(tests.count - failed) FAILED=\(failed) SKIPPED=0")
        Darwin.exit(failed == 0 ? 0 : 1)
    }

    private static func capability(_ f: Fixture) throws {
        try require(try f.run("--native-pairing-cancellation-v1") == "native-pairing-cancellation-v1:available",
            "Missing cancellation-capable native helper")
        try require(f.publications == 0 && f.observations == 0, "Capability must not publish")
    }

    static func testNativeCancellationCapability() throws {
        let f = try Fixture(); defer { f.close() }
        try capability(f)
    }

    static func testNativeExactPublicationReceiptAndIdempotence() throws {
        for name in ["completion.hbp", "cancelled.hbp"] {
            let f = try Fixture(); defer { f.close() }
            try capability(f) // Failure here leaves all subsequent publication checks NOT_REACHED.
            let request = try f.stage(native: true, name: name)
            try f.createAppPairingDirectory()
            _ = try f.run("pairing:" + f.requestID)
            let receiptBytes = try Data(contentsOf: f.receipt)
            let receipt = try JSONSerialization.jsonObject(with: receiptBytes) as? NSDictionary
            var expected = request
            expected["published"] = true
            expected["bootstrapVersion"] = 1
            try require(receipt == expected as NSDictionary, "Receipt must bind every request field including finalName")
            try require(try Data(contentsOf: f.nativeFinal(name)) == f.payload, "Exact native bytes")
            // Native provider movement may consume staging; the adapter restages the same bytes on retry.
            try f.write(f.payload, to: f.source(native: true))
            _ = try f.run("pairing:" + f.requestID)
            let repeated = try JSONSerialization.jsonObject(with: Data(contentsOf: f.receipt)) as? NSDictionary
            try require(repeated == receipt, "Idempotent receipt")
            try require(try Data(contentsOf: f.nativeFinal(name)) == f.payload, "Idempotent native bytes")
            try require(f.publications == 1, "Exact existing content must not be republished")
            try require(!FileManager.default.fileExists(atPath: f.mailboxRoot.appendingPathComponent("deliveries").path),
                "Pairing must not create delivery topology")
        }
    }

    static func testNativeRefusalsAfterCapability() throws {
        let probe = try Fixture(); defer { probe.close() }
        try capability(probe) // Do not let unsupported native dispatch make a refusal test pass.
        for fault in ["name", "version", "requestID", "invitationID", "size", "digest", "requestSymlink",
                      "sourceSymlink", "conflict", "absentAppDirectory"] {
            let f = try Fixture(); defer { f.close() }
            var request = try f.stage(native: true, name: "completion.hbp")
            if fault != "absentAppDirectory" { try f.createAppPairingDirectory() }
            switch fault {
            case "name": request["finalName"] = "../request.hbp"
            case "version": request["version"] = 2
            case "requestID": request["requestID"] = String(repeating: "f", count: 32)
            case "invitationID": request["invitationID"] = "../unsafe"
            case "size": request["byteCount"] = 65_537
            case "digest": request["sha256"] = String(repeating: "0", count: 64)
            case "conflict": try f.write(Data("conflicting synthetic bytes".utf8), to: f.nativeFinal("completion.hbp"))
            default: break
            }
            try f.write(JSONSerialization.data(withJSONObject: request), to: f.request)
            if fault == "requestSymlink" { try f.replaceWithSymlink(f.request) }
            if fault == "sourceSymlink" { try f.replaceWithSymlink(f.source(native: true)) }
            try refuses { _ = try f.run("pairing:" + f.requestID) }
            try require(f.publications == 0, "Refused request must not publish: \(fault)")
            try require(!FileManager.default.fileExists(atPath: f.receipt.path), "No success receipt for refusal")
            if fault == "absentAppDirectory" {
                try require(!FileManager.default.fileExists(atPath: f.mailboxRoot.path), "Helper must not create provider topology")
            }
            if fault == "conflict" {
                try require(try Data(contentsOf: f.nativeFinal("completion.hbp")) == Data("conflicting synthetic bytes".utf8),
                    "Conflicting content must survive")
            }
        }
    }

    static func testExistingACKExactPublicationAndIdempotence() throws {
        let f = try Fixture(); defer { f.close() }
        let request = try f.stage(native: false, name: f.ackName)
        _ = try f.run(f.requestID)
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: f.receipt)) as? [String: Any]
        try require(receipt != nil, "ACK receipt missing")
        for (key, value) in request {
            try require((receipt?[key] as? NSObject) == (value as? NSObject), "ACK receipt binding: \(key)")
        }
        for flag in ["published", "exactBytes", "isUbiquitous", "uploadErrorAbsent", "sourceOutsideProvider"] {
            try require(receipt?[flag] as? Bool == true, "ACK receipt flag: \(flag)")
        }
        try require(try Data(contentsOf: f.ackFinal) == f.payload, "Exact ACK bytes")
        try f.write(f.payload, to: f.source(native: false))
        _ = try f.run(f.requestID)
        try require(f.publications == 1, "ACK retry must remain idempotent")
        try require(try Data(contentsOf: f.ackFinal) == f.payload, "ACK retry bytes")
    }

    static func testExistingACKRefusesUnsafeInputs() throws {
        for fault in ["name", "digest", "requestSymlink", "sourceSymlink", "conflict"] {
            let f = try Fixture(); defer { f.close() }
            var request = try f.stage(native: false, name: f.ackName)
            if fault == "name" { request["finalName"] = "../unsafe.hba" }
            if fault == "digest" { request["sha256"] = String(repeating: "0", count: 64) }
            try f.write(JSONSerialization.data(withJSONObject: request), to: f.request)
            if fault == "requestSymlink" { try f.replaceWithSymlink(f.request) }
            if fault == "sourceSymlink" { try f.replaceWithSymlink(f.source(native: false)) }
            if fault == "conflict" {
                try f.mkdir(f.ackFinal.deletingLastPathComponent())
                try f.write(Data("conflicting synthetic bytes".utf8), to: f.ackFinal)
            }
            try refuses { _ = try f.run(f.requestID) }
            try require(f.publications == 0, "Unsafe ACK must not publish")
            try require(!FileManager.default.fileExists(atPath: f.receipt.path), "No ACK success receipt on refusal")
        }
    }

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeHelperFake-\(UUID().uuidString)")
        let requestID = String(repeating: "a", count: 32)
        let invitationID = String(repeating: "b", count: 32)
        let receiver = String(repeating: "c", count: 32), device = String(repeating: "d", count: 32)
        let ackName = String(repeating: "e", count: 32) + ".hba"
        let payload = Data("synthetic opaque encrypted publication bytes".utf8)
        var publications = 0, observations = 0
        var app: URL { root.appendingPathComponent("protocol") }
        var provider: URL { root.appendingPathComponent("provider") }
        var mailboxRoot: URL { provider.appendingPathComponent("Documents/HealthBridgeMailbox/v1") }
        var request: URL { app.appendingPathComponent("requests/\(requestID).json") }
        var receipt: URL { app.appendingPathComponent("receipts/\(requestID).json") }
        var ackFinal: URL { mailboxRoot.appendingPathComponent("\(receiver)/\(device)/acks/\(ackName)") }
        func nativeFinal(_ name: String) -> URL { mailboxRoot.appendingPathComponent("pairing/\(invitationID)/\(name)") }
        func source(native: Bool) -> URL { app.appendingPathComponent("staging/\(requestID).\(native ? "hbp" : "hba")") }
        init() throws {
            try mkdir(root)
            try mkdir(provider)
            for name in ["requests", "staging", "receipts"] { try mkdir(app.appendingPathComponent(name)) }
        }
        func mkdir(_ url: URL) throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        func write(_ bytes: Data, to url: URL) throws {
            try bytes.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        func replaceWithSymlink(_ url: URL) throws {
            let target = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: target)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        }
        func createAppPairingDirectory() throws { try mkdir(nativeFinal("completion.hbp").deletingLastPathComponent()) }
        func stage(native: Bool, name: String) throws -> [String: Any] {
            var value: [String: Any] = ["version": 1, "requestID": requestID, "finalName": name,
                "byteCount": payload.count, "sha256": SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()]
            if native { value["invitationID"] = invitationID }
            else { value["receiver"] = receiver; value["device"] = device }
            try write(payload, to: source(native: native))
            try write(JSONSerialization.data(withJSONObject: value), to: request)
            return value
        }
        func run(_ argument: String) throws -> String {
            try runHelper(arguments: [argument], applicationRoot: { self.app }, io: HelperPublicationIO(
                providerRoot: { self.provider },
                publish: { source, final in
                    try NativePairingLocalFakeTests.require(source.path.hasPrefix(self.app.path + "/"), "Private staging required")
                    try NativePairingLocalFakeTests.require(final.path.hasPrefix(self.provider.path + "/"), "Private fake provider required")
                    self.publications += 1
                    try self.write(Data(contentsOf: source), to: final)
                },
                observe: { final in
                    try NativePairingLocalFakeTests.require(final.path.hasPrefix(self.provider.path + "/"), "Private observation required")
                    self.observations += 1
                    return (true, nil)
                }, wait: { preconditionFailure("Successful fake observation must not wait") }
            ))
        }
        func close() { try? FileManager.default.removeItem(at: root) }
    }
}
#endif
