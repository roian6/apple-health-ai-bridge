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
        if CommandLine.arguments.count == 3,
           ["--ipc-crash-child", "--ipc-wire-child"].contains(CommandLine.arguments[1]) {
            do {
                let f = try Fixture(root: URL(fileURLWithPath: CommandLine.arguments[2]))
                f.consumeIPCSource = true
                if CommandLine.arguments[1] == "--ipc-crash-child" {
                    f.duringIPCPublication = {
                        try PublicationIPCPipe(descriptor: STDOUT_FILENO).write(Data([1]))
                        _ = try PublicationIPCPipe(descriptor: STDIN_FILENO).read(1)
                    }
                    let result = f.ipc(try frame(canonical(f.ipcHeader("ack")), f.payload))
                    Darwin.exit(result.exitCode)
                }
                let reader = try PublicationIPCPipe(descriptor: STDIN_FILENO)
                let result = runPublicationIPC(input: reader.read, applicationRoot: { f.app }, io: f.io)
                try PublicationIPCPipe(descriptor: STDOUT_FILENO).write(result.response)
                Darwin.exit(result.exitCode)
            } catch { Darwin.exit(3) }
        }
        let tests: [(String, () throws -> Void)] = [
            ("testIPCDiscoveryWithoutStorage", testIPCDiscoveryWithoutStorage),
            ("testIPCAllPublicationsAndRetry", testIPCAllPublicationsAndRetry),
            ("testIPCRejectsNoncanonicalHeadersBeforeStorage", testIPCRejectsNoncanonicalHeadersBeforeStorage),
            ("testIPCFramingDigestAndBounds", testIPCFramingDigestAndBounds),
            ("testIPCProbeAndCrashRemnants", testIPCProbeAndCrashRemnants),
            ("testIPCRejectsUnsafeStorage", testIPCRejectsUnsafeStorage),
            ("testIPCBusyAndCleanup", testIPCBusyAndCleanup),
            ("testIPCConflictsAndProviderPathSafety", testIPCConflictsAndProviderPathSafety),
            ("testIPCSafeFailuresAndAttachment", testIPCSafeFailuresAndAttachment),
            ("testIPCPipeBoundsEOFAndDeadlines", testIPCPipeBoundsEOFAndDeadlines),
            ("testIPCActualProcessPipes", testIPCActualProcessPipes),
            ("testIPCKilledLockOwnerRecovery", testIPCKilledLockOwnerRecovery),
            ("testIPCErrorAttributionAndCleanupFailure", testIPCErrorAttributionAndCleanupFailure),
            ("testCapabilitiesFirstCreateAndSameBytes", testCapabilitiesFirstCreateAndSameBytes),
            ("testCapabilitiesChangedBytesReplace", testCapabilitiesChangedBytesReplace),
            ("testCapabilitiesPublicationFailurePreservesOldBytes", testCapabilitiesPublicationFailurePreservesOldBytes),
            ("testCapabilitiesRefuseUnsafeInputs", testCapabilitiesRefuseUnsafeInputs),
            ("testCapabilitiesRejectDirectoryReplacementDuringPublication", testCapabilitiesRejectDirectoryReplacementDuringPublication),
            ("testCapabilitiesRejectStagingReplacementDuringPublication", testCapabilitiesRejectStagingReplacementDuringPublication),
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

    static func testIPCDiscoveryWithoutStorage() throws {
        let f = try Fixture(); defer { f.close() }
        let output = try runHelper(arguments: ["--publication-ipc-v1-capabilities"],
            applicationRoot: { throw Failure(message: "Discovery touched private storage") }, io: f.io)
        try require(output == "publication-ipc-v1:ack,pairing,receiver_capabilities,storage_probe",
            "IPC discovery must promise all implemented operations")
        try require(f.publications == 0 && f.observations == 0, "Discovery must not touch provider")
    }

    private static func frame(_ header: Data, _ payload: Data = Data()) -> Data {
        let n = UInt32(header.count)
        return Data([UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
            + header + payload
    }
    private static func canonical(_ fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func response(_ result: PublicationIPCResult) throws -> [String: Any] {
        let bytes = result.response
        try require(bytes.count >= 5 && bytes.count <= 8_196, "Bounded framed response")
        let length = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        try require(length == bytes.count - 4, "Exactly one response without trailing bytes")
        let body = Data(bytes.dropFirst(4))
        guard let fields = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw Failure(message: "Response object missing")
        }
        try require(try canonical(fields) == body, "Canonical response")
        try require(result.exitCode == (fields["status"] as? String == "ok" ? 0 : 3), "Status and exit agree")
        return fields
    }
    private static func errorCode(_ result: PublicationIPCResult, _ expected: String) throws {
        let fields = try response(result)
        try require(result.exitCode == 3 && fields["code"] as? String == expected, "Expected safe code \(expected)")
    }
    static func testIPCAllPublicationsAndRetry() throws {
        for operation in ["ack", "pairing", "cancelled", "receiver_capabilities"] {
            let f = try Fixture(); defer { f.close() }
            try f.createAppPairingDirectory()
            try f.mkdir(f.capabilitiesFinal.deletingLastPathComponent())
            f.consumeIPCSource = true
            let header = f.ipcHeader(operation)
            let input = try frame(canonical(header), f.payload)
            let first = try response(f.ipc(input))
            var expected = header
            expected["status"] = "ok"
            switch operation {
            case "ack":
                for key in ["published", "exactBytes", "isUbiquitous", "uploadErrorAbsent", "sourceOutsideProvider"] {
                    expected[key] = true
                }
                expected["errorDomain"] = NSNull(); expected["errorCode"] = NSNull()
            case "receiver_capabilities":
                expected["stored"] = true; expected["exactBytes"] = true; expected["isUbiquitous"] = true
            default: expected["published"] = true; expected["bootstrapVersion"] = 1
            }
            try require(first as NSDictionary == expected as NSDictionary, "Full receipt binds accepted request")
            let final = operation == "ack" ? f.ackFinal : operation == "receiver_capabilities"
                ? f.capabilitiesFinal : f.nativeFinal(operation == "cancelled" ? "cancelled.hbp" : "completion.hbp")
            try require(try Data(contentsOf: final) == f.payload, "Native publication bytes")
            try require(try response(f.ipc(input)) as NSDictionary == expected as NSDictionary, "Lost-response retry")
            try require(f.publications == 1, "Retry must not republish exact bytes")
            if operation == "receiver_capabilities" {
                let changed = Data("changed synthetic declaration".utf8)
                let result = f.ipc(try frame(canonical(f.ipcHeader(operation, bytes: changed)), changed))
                try require(result.exitCode == 0, "Mutable capabilities replace")
                try require(try Data(contentsOf: final) == changed, "Changed capabilities bytes")
            }
            try f.requireEmptyIPC()
        }
    }
    static func testIPCRejectsNoncanonicalHeadersBeforeStorage() throws {
        let f = try Fixture(); defer { f.close() }
        let valid = try canonical(f.ipcHeader("storage_probe"))
        let text = String(decoding: valid, as: UTF8.self)
        var malformed = [
            text.replacingOccurrences(of: "\"version\":1", with: "\"version\":true"),
            text.replacingOccurrences(of: "\"version\":1", with: "\"version\":1.0"),
            text.replacingOccurrences(of: "\"version\":1", with: "\"version\":1e0"),
            text.replacingOccurrences(of: "\"version\":1", with: "\"version\":01"),
            text.replacingOccurrences(of: "\"version\":1", with: "\"version\":+1"),
            text.replacingOccurrences(of: "\"version\":1", with: "\"version\":null"),
            text.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1"),
            text.replacingOccurrences(of: "\"byteCount\":0", with: "\"byteCount\":-0"),
            text.replacingOccurrences(of: "\"byteCount\":0", with: "\"byteCount\":\"0\""),
            text.replacingOccurrences(of: "\"byteCount\":0", with: "\"byteCount\":[]"),
            text.replacingOccurrences(of: "\"byteCount\":0", with: "\"byteCount\":{}"),
            text.replacingOccurrences(of: "\"byteCount\":0", with: "\"byteCount\":NaN"),
            text.replacingOccurrences(of: "\"operation\"", with: "\"\\u006fperation\""),
            text.replacingOccurrences(of: "storage_probe", with: "unknown"),
            text.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"extra\":0"),
            " " + text, "[]", "{}"
        ].map { Data($0.utf8) }
        malformed.append(Data([0xff]))
        for header in malformed {
            var touched = false
            var remaining = frame(header)
            let result = runPublicationIPC(input: { n in
                let chunk = Data(remaining.prefix(n)); remaining.removeFirst(chunk.count); return chunk
            }, applicationRoot: { touched = true; return f.app }, io: f.io)
            try errorCode(result, "invalid_request")
            let fields = try response(result)
            try require(Set(fields.keys) == Set(["version", "operation", "requestID", "status", "code"]),
                "Invalid header gets only unbound fields")
            try require(fields["requestID"] is NSNull && !touched, "Invalid header must not resolve storage")
        }
    }
    static func testIPCFramingDigestAndBounds() throws {
        let f = try Fixture(); defer { f.close() }
        let header = try canonical(f.ipcHeader("ack"))
        let good = frame(header, f.payload)
        let wrongDigest = try response(f.ipc(frame(header, Data(repeating: 0, count: f.payload.count))))
        try require(wrongDigest["requestID"] as? String == f.requestID && wrongDigest["operation"] as? String == "ack",
            "Valid header remains bound on digest failure")
        for input in [Data(), Data([0, 0, 0]), Data([0, 0, 0, 0]), Data([0, 0, 32, 1]),
                      Data([255, 255, 255, 255]), Data(good.dropLast()), good + Data([0]),
                      frame(header, Data(repeating: 0, count: f.payload.count)), good + good] {
            try errorCode(f.ipc(input), "invalid_request")
            try require(!FileManager.default.fileExists(atPath: f.ipcRoot.path), "Invalid frame cannot stage")
        }
        for (key, value) in [("receiver", "../outside"), ("device", String(repeating: "A", count: 32)),
                             ("requestID", "short"), ("sha256", String(repeating: "g", count: 64)),
                             ("finalName", "../outside.hba")] {
            var fields = f.ipcHeader("ack"); fields[key] = value
            try errorCode(f.ipc(try frame(canonical(fields), f.payload)), "invalid_request")
        }
        for (operation, maximum) in [("ack", 1_048_576), ("pairing", 65_536), ("receiver_capabilities", 8_192)] {
            for count in [0, maximum + 1] {
                var fields = f.ipcHeader(operation); fields["byteCount"] = count
                try errorCode(f.ipc(try frame(canonical(fields))), "invalid_request")
            }
            let bytes = Data(repeating: 0x61, count: maximum)
            try f.createAppPairingDirectory()
            try f.mkdir(f.capabilitiesFinal.deletingLastPathComponent())
            try require(f.ipc(try frame(canonical(f.ipcHeader(operation, bytes: bytes)), bytes)).exitCode == 0,
                "Inclusive operation payload maximum")
        }
        try require(f.publications == 3, "All boundary positive controls publish")
    }
    static func testIPCProbeAndCrashRemnants() throws {
        let f = try Fixture(); defer { f.close() }
        f.forbidProvider = true
        let probe = try frame(canonical(f.ipcHeader("storage_probe")))
        try require(f.ipc(probe).exitCode == 0, "Probe without provider")
        try f.write(Data("legacy".utf8), to: f.request)
        let request = f.ipcRoot.appendingPathComponent("requests/\(f.requestID).json")
        let source = f.ipcRoot.appendingPathComponent("staging/\(f.requestID).hbp")
        try f.write(Data("incomplete".utf8), to: request)
        try f.write(f.payload, to: source)
        try require(f.ipc(probe).exitCode == 0, "Safe crash remnants swept")
        for lane in ["requests", "staging", "receipts"] {
            try f.write(Data("probe crash".utf8), to: f.ipcRoot.appendingPathComponent("\(lane)/.storage-probe"))
        }
        try require(f.ipc(probe).exitCode == 0, "Probe remnants swept")
        try f.requireEmptyIPC()
        try require(try Data(contentsOf: f.request) == Data("legacy".utf8), "Legacy lanes never swept")
    }
    static func testIPCRejectsUnsafeStorage() throws {
        for fault in ["unknown", "overflow", "symlink", "hardlink", "wideMode", "oversize", "receipt",
                      "sourceOversize", "probeOversize", "fifo", "rootSymlink",
                      "laneSymlink", "laneMode", "lockSymlink", "lockHardlink", "lockMode"] {
            let f = try Fixture(); defer { f.close() }
            let probe = try frame(canonical(f.ipcHeader("storage_probe")))
            try require(f.ipc(probe).exitCode == 0, "Safe storage positive control")
            let lane = f.ipcRoot.appendingPathComponent("requests")
            let file = lane.appendingPathComponent("\(f.requestID).json")
            switch fault {
            case "unknown": try f.write(f.payload, to: lane.appendingPathComponent("foreign"))
            case "overflow":
                try f.write(f.payload, to: file)
                try f.write(f.payload, to: lane.appendingPathComponent("\(f.invitationID).json"))
            case "receipt": try f.write(f.payload, to: f.ipcRoot.appendingPathComponent("receipts/\(f.requestID).json"))
            case "sourceOversize":
                try f.write(Data(repeating: 1, count: 1_048_577), to: f.ipcRoot.appendingPathComponent("staging/\(f.requestID).hba"))
            case "probeOversize": try f.write(Data(repeating: 1, count: 65), to: lane.appendingPathComponent(".storage-probe"))
            case "fifo": try require(mkfifo(file.path, 0o600) == 0, "Synthetic FIFO setup")
            case "rootSymlink": try f.replaceWithSymlink(f.ipcRoot)
            case "laneSymlink": try f.replaceWithSymlink(lane)
            case "laneMode": try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lane.path)
            case "lockSymlink": try f.replaceWithSymlink(f.ipcRoot.appendingPathComponent("lock"))
            case "lockHardlink":
                try FileManager.default.linkItem(at: f.ipcRoot.appendingPathComponent("lock"), to: f.root.appendingPathComponent("linked"))
            case "lockMode":
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.ipcRoot.appendingPathComponent("lock").path)
            default:
                try f.write(fault == "oversize" ? Data(repeating: 1, count: 8_193) : f.payload, to: file)
                if fault == "symlink" { try f.replaceWithSymlink(file) }
                if fault == "hardlink" { try FileManager.default.linkItem(at: file, to: f.root.appendingPathComponent("linked")) }
                if fault == "wideMode" { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
            }
            try errorCode(f.ipc(probe), "unsafe_storage")
        }
    }
    static func testIPCBusyAndCleanup() throws {
        let f = try Fixture(); defer { f.close() }
        try f.createAppPairingDirectory()
        f.duringIPCPublication = {
            let probe = try frame(canonical(f.ipcHeader("storage_probe")))
            try errorCode(f.ipc(probe), "helper_busy")
            let names = try FileManager.default.contentsOfDirectory(atPath: f.ipcRoot.appendingPathComponent("requests").path)
            try require(names == ["\(f.requestID).json"], "Contender cannot sweep active request")
        }
        try require(f.ipc(try frame(canonical(f.ipcHeader("pairing")), f.payload)).exitCode == 0, "Lock owner publishes")
        try f.requireEmptyIPC()
        try require(f.ipc(try frame(canonical(f.ipcHeader("storage_probe")))).exitCode == 0, "Lock released before return")
    }
    static func testIPCConflictsAndProviderPathSafety() throws {
        for operation in ["ack", "pairing", "cancelled"] {
            let f = try Fixture(); defer { f.close() }
            let final = operation == "ack" ? f.ackFinal : f.nativeFinal(operation == "cancelled" ? "cancelled.hbp" : "completion.hbp")
            try f.mkdir(final.deletingLastPathComponent())
            let original = Data("other immutable payload".utf8)
            try f.write(original, to: final)
            try errorCode(f.ipc(try frame(canonical(f.ipcHeader(operation)), f.payload)), "destination_conflict")
            try require(try Data(contentsOf: final) == original, "Conflicting final remains untouched")
            try f.requireEmptyIPC()
        }
        let f = try Fixture(); defer { f.close() }
        try f.mkdir(f.ackFinal.deletingLastPathComponent())
        try f.replaceWithSymlink(f.ackFinal.deletingLastPathComponent())
        try errorCode(f.ipc(try frame(canonical(f.ipcHeader("ack")), f.payload)), "publication_failed")
        try require(f.publications == 0, "ACK refuses symlink provider lane")
    }
    static func testIPCSafeFailuresAndAttachment() throws {
        let f = try Fixture(); defer { f.close() }
        try f.createAppPairingDirectory()
        f.failPublication = true
        let input = try frame(canonical(f.ipcHeader("pairing")), f.payload)
        let result = f.ipc(input)
        try errorCode(result, "publication_failed")
        try require(!String(decoding: result.response, as: UTF8.self).contains("synthetic"), "No raw error output")
        try f.requireEmptyIPC()
        f.failPublication = false
        f.duringIPCPublication = {
            let lane = f.ipcRoot.appendingPathComponent("staging")
            try FileManager.default.moveItem(at: lane, to: f.root.appendingPathComponent("detached-stage"))
            try f.mkdir(lane)
        }
        try errorCode(f.ipc(input), "unsafe_storage")
        try require(!FileManager.default.fileExists(atPath: f.nativeFinal("completion.hbp").path), "Detached private lane prevents publication")
    }
    static func testIPCPipeBoundsEOFAndDeadlines() throws {
        let input = Pipe()
        let reader = try PublicationIPCPipe(descriptor: input.fileHandleForReading.fileDescriptor)
        try input.fileHandleForWriting.write(contentsOf: Data([1, 2, 3]))
        try input.fileHandleForWriting.close()
        try require(try reader.read(2) == Data([1, 2]), "Bounded read never consumes extra bytes")
        try require(try reader.read(2) == Data([3]), "Partial EOF returned")
        try require(try reader.read(1).isEmpty, "EOF returned")
        let blocked = Pipe()
        let expired = try PublicationIPCPipe(descriptor: blocked.fileHandleForReading.fileDescriptor, deadline: 0)
        try refuses { _ = try expired.read(1) }
        let output = Pipe()
        let writer = try PublicationIPCPipe(descriptor: output.fileHandleForWriting.fileDescriptor)
        try writer.write(Data([4, 5, 6]))
        try require(try output.fileHandleForReading.read(upToCount: 3) == Data([4, 5, 6]), "Actual bounded pipe output")
        try refuses { try writer.write(Data(repeating: 0, count: 8_197)) }
        let expiredWriter = try PublicationIPCPipe(descriptor: output.fileHandleForWriting.fileDescriptor, deadline: 0)
        try refuses { try expiredWriter.write(Data([1])) }
        try output.fileHandleForReading.close()
        try refuses { try writer.write(Data([1])) }
    }

    static func testIPCActualProcessPipes() throws {
        let f = try Fixture(); defer { f.close() }
        let payload = Data(repeating: 0x61, count: 1_048_576)
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--ipc-wire-child", f.root.path]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        try input.fileHandleForWriting.write(contentsOf: frame(canonical(f.ipcHeader("ack", bytes: payload)), payload))
        try input.fileHandleForWriting.close()
        let reader = try PublicationIPCPipe(descriptor: output.fileHandleForReading.fileDescriptor)
        var bytes = Data()
        while true {
            let part = try reader.read(8_197 - bytes.count)
            if part.isEmpty { break }
            bytes.append(part)
            try require(bytes.count <= 8_196, "Actual process stdout bound")
        }
        process.waitUntilExit()
        let fields = try response(PublicationIPCResult(response: bytes, exitCode: process.terminationStatus))
        try require(fields["status"] as? String == "ok" && process.terminationReason == .exit, "Shared process entry success")
        try require(try Data(contentsOf: f.ackFinal) == payload, "Actual pipe publication exact bytes")
        try f.requireEmptyIPC()
    }

    static func testIPCKilledLockOwnerRecovery() throws {
        let f = try Fixture(); defer { f.close() }
        let process = Process(), input = Pipe(), ready = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--ipc-crash-child", f.root.path]
        process.standardInput = input; process.standardOutput = ready; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let reader = try PublicationIPCPipe(descriptor: ready.fileHandleForReading.fileDescriptor)
        try require(try reader.read(1) == Data([1]), "Child reached staged publication barrier")
        let probe = try frame(canonical(f.ipcHeader("storage_probe")))
        try errorCode(f.ipc(probe), "helper_busy")
        try require(kill(process.processIdentifier, SIGKILL) == 0, "Kill only the owned staged child")
        process.waitUntilExit()
        try require(process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL, "Actual crash control")
        for lane in ["requests", "staging"] {
            try require(try FileManager.default.contentsOfDirectory(atPath: f.ipcRoot.appendingPathComponent(lane).path).count == 1,
                "Killed invocation leaves one bounded entry per used lane")
        }
        try require(f.ipc(probe).exitCode == 0, "Next helper invocation sweeps killed-owner remnants")
        try f.requireEmptyIPC()
        try require(f.ipc(try frame(canonical(f.ipcHeader("ack")), f.payload)).exitCode == 0, "Fresh publication after crash")
    }

    static func testIPCErrorAttributionAndCleanupFailure() throws {
        let f = try Fixture(); defer { f.close() }
        let probe = try frame(canonical(f.ipcHeader("storage_probe")))
        for (code, expected) in [(EACCES, "storage_access_denied"), (EPERM, "storage_access_denied"), (EIO, "storage_io_failed")] {
            var remaining = probe
            let result = runPublicationIPC(input: { maximum in
                let bytes = Data(remaining.prefix(maximum)); remaining.removeFirst(bytes.count); return bytes
            }, applicationRoot: { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }, io: f.io)
            try errorCode(result, expected)
        }
        f.providerError = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let input = try frame(canonical(f.ipcHeader("ack")), f.payload)
        try errorCode(f.ipc(input), "publication_failed")
        try f.requireEmptyIPC()
        f.providerError = nil
        f.afterIPCObservation = {
            let source = f.ipcRoot.appendingPathComponent("staging/\(f.requestID).hba")
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)
        }
        try errorCode(f.ipc(input), "unsafe_storage")
        try require(try Data(contentsOf: f.ackFinal) == f.payload, "Cleanup failure never rolls provider back")
        let source = f.ipcRoot.appendingPathComponent("staging/\(f.requestID).hba")
        try require(FileManager.default.fileExists(atPath: source.path), "Unsafe cleanup preserves evidence")
    }

    static func testCapabilitiesFirstCreateAndSameBytes() throws {
        let f = try Fixture(); defer { f.close() }
        let request = try f.stageCapabilities(f.payload)
        _ = try f.run("capabilities:" + f.requestID)
        var expected = request
        expected["stored"] = true; expected["exactBytes"] = true; expected["isUbiquitous"] = true
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: f.receipt)) as? NSDictionary
        try require(receipt == expected as NSDictionary, "Metadata receipt must bind operation, identity and bytes")
        try require(try Data(contentsOf: f.capabilitiesFinal) == f.payload, "First-create exact metadata")
        _ = try f.stageCapabilities(f.payload)
        _ = try f.run("capabilities:" + f.requestID)
        try require(f.publications == 1, "Same bytes must not rewrite metadata")
    }

    static func testCapabilitiesChangedBytesReplace() throws {
        let f = try Fixture(); defer { f.close() }
        _ = try f.stageCapabilities(f.payload)
        _ = try f.run("capabilities:" + f.requestID)
        let changed = Data("changed synthetic signed metadata".utf8)
        _ = try f.stageCapabilities(changed)
        _ = try f.run("capabilities:" + f.requestID)
        try require(try Data(contentsOf: f.capabilitiesFinal) == changed, "Metadata must replace changed bytes")
        try require(f.publications == 2, "Only changed metadata is republished")
    }

    static func testCapabilitiesPublicationFailurePreservesOldBytes() throws {
        let f = try Fixture(); defer { f.close() }
        _ = try f.stageCapabilities(f.payload)
        _ = try f.run("capabilities:" + f.requestID)
        _ = try f.stageCapabilities(Data("changed synthetic signed metadata".utf8))
        try FileManager.default.removeItem(at: f.receipt)
        f.failPublication = true
        try refuses { _ = try f.run("capabilities:" + f.requestID) }
        try require(try Data(contentsOf: f.capabilitiesFinal) == f.payload, "Failed replace must preserve old bytes")
        try require(!FileManager.default.fileExists(atPath: f.receipt.path), "Failure cannot issue a success receipt")
    }

    static func testCapabilitiesRejectDirectoryReplacementDuringPublication() throws {
        let f = try Fixture(); defer { f.close() }
        _ = try f.stageCapabilities(f.payload)
        _ = try f.run("capabilities:" + f.requestID)
        _ = try f.stageCapabilities(Data("changed synthetic metadata".utf8))
        try FileManager.default.removeItem(at: f.receipt)
        f.detachOnPublication = true
        try refuses { _ = try f.run("capabilities:" + f.requestID) }
        try require(!FileManager.default.fileExists(atPath: f.receipt.path), "Detached namespace cannot issue success")
        let old = f.root.appendingPathComponent("detached-device/receiver-capabilities.json")
        try require(try Data(contentsOf: old) == f.payload, "Old detached bytes must survive")
    }

    static func testCapabilitiesRejectStagingReplacementDuringPublication() throws {
        let f = try Fixture(); defer { f.close() }
        _ = try f.stageCapabilities(f.payload)
        _ = try f.run("capabilities:" + f.requestID)
        _ = try f.stageCapabilities(Data("changed synthetic metadata".utf8))
        try FileManager.default.removeItem(at: f.receipt)
        f.replaceStagingOnPublication = true
        try refuses { _ = try f.run("capabilities:" + f.requestID) }
        try require(try Data(contentsOf: f.capabilitiesFinal) == f.payload, "Replaced staging must preserve the old declaration")
        try require(!FileManager.default.fileExists(atPath: f.receipt.path), "Replaced staging cannot issue success")
    }

    static func testCapabilitiesRefuseUnsafeInputs() throws {
        // Reach actual supported dispatch first; unsupported commands cannot satisfy refusal controls.
        let probe = try Fixture(); defer { probe.close() }
        _ = try probe.stageCapabilities(probe.payload)
        _ = try probe.run("capabilities:" + probe.requestID)
        for fault in ["operation", "size", "digest", "requestID", "receiver", "extra", "requestSymlink", "sourceSymlink", "targetSymlink", "sourceHardlink", "targetHardlink", "oversize"] {
            let f = try Fixture(); defer { f.close() }
            var request = try f.stageCapabilities(f.payload)
            if fault == "operation" { request["operation"] = "ack" }
            if fault == "size" { request["byteCount"] = 8_193 }
            if fault == "digest" { request["sha256"] = String(repeating: "0", count: 64) }
            if fault == "requestID" { request["requestID"] = String(repeating: "f", count: 32) }
            if fault == "receiver" { request["receiver"] = "../outside" }
            if fault == "extra" { request["finalName"] = "arbitrary.json" }
            try f.write(JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]), to: f.request)
            if fault == "requestSymlink" { try f.replaceWithSymlink(f.request) }
            if fault == "sourceSymlink" { try f.replaceWithSymlink(f.capabilitiesSource) }
            if fault == "targetSymlink" {
                try f.write(f.payload, to: f.capabilitiesFinal)
                try f.replaceWithSymlink(f.capabilitiesFinal)
            }
            if fault == "sourceHardlink" {
                try FileManager.default.linkItem(at: f.capabilitiesSource, to: f.root.appendingPathComponent("linked-source"))
            }
            if fault == "targetHardlink" {
                try f.write(f.payload, to: f.capabilitiesFinal)
                try FileManager.default.linkItem(at: f.capabilitiesFinal, to: f.root.appendingPathComponent("linked-target"))
            }
            if fault == "oversize" { try f.write(Data(repeating: 0x61, count: 8_193), to: f.capabilitiesSource) }
            try refuses { _ = try f.run("capabilities:" + f.requestID) }
            try require(f.publications == 0, "Unsafe metadata must not publish")
            try require(!FileManager.default.fileExists(atPath: f.receipt.path), "No success receipt for refusal")
        }
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
        let root: URL
        let requestID = String(repeating: "a", count: 32)
        let invitationID = String(repeating: "b", count: 32)
        let receiver = String(repeating: "c", count: 32), device = String(repeating: "d", count: 32)
        let ackName = String(repeating: "e", count: 32) + ".hba"
        let payload = Data("synthetic opaque encrypted publication bytes".utf8)
        var publications = 0, observations = 0
        var failPublication = false
        var detachOnPublication = false
        var replaceStagingOnPublication = false
        var consumeIPCSource = false
        var forbidProvider = false
        var duringIPCPublication: (() throws -> Void)?
        var afterIPCObservation: (() throws -> Void)?
        var providerError: Error?
        var ipcRoot: URL { app.appendingPathComponent("ipc-v1") }
        func ipcHeader(_ operation: String, bytes: Data? = nil) -> [String: Any] {
            let payload = operation == "storage_probe" ? Data() : bytes ?? self.payload
            var fields: [String: Any] = ["version": 1, "operation": operation == "cancelled" ? "pairing" : operation,
                "requestID": requestID, "byteCount": payload.count,
                "sha256": SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()]
            if operation == "pairing" || operation == "cancelled" {
                fields["invitationID"] = invitationID
                fields["finalName"] = operation == "cancelled" ? "cancelled.hbp" : "completion.hbp"
            } else if operation != "storage_probe" {
                fields["receiver"] = receiver; fields["device"] = device
                if operation == "ack" { fields["finalName"] = ackName }
            }
            return fields
        }
        func ipc(_ bytes: Data) -> PublicationIPCResult {
            var offset = 0
            return runPublicationIPC(input: { maximum in
                let end = min(offset + min(maximum, 997), bytes.count)
                let result = bytes.subdata(in: offset..<end); offset = end; return result
            }, applicationRoot: { self.app }, io: io)
        }
        func requireEmptyIPC() throws {
            for lane in ["requests", "staging", "receipts"] {
                try NativePairingLocalFakeTests.require(
                    try FileManager.default.contentsOfDirectory(atPath: ipcRoot.appendingPathComponent(lane).path).isEmpty,
                    "IPC leaves no private payload or receipt")
            }
        }
        var app: URL { root.appendingPathComponent("protocol") }
        var provider: URL { root.appendingPathComponent("provider") }
        var mailboxRoot: URL { provider.appendingPathComponent("Documents/HealthBridgeMailbox/v1") }
        var request: URL { app.appendingPathComponent("requests/\(requestID).json") }
        var receipt: URL { app.appendingPathComponent("receipts/\(requestID).json") }
        var ackFinal: URL { mailboxRoot.appendingPathComponent("\(receiver)/\(device)/acks/\(ackName)") }
        var capabilitiesFinal: URL { mailboxRoot.appendingPathComponent("\(receiver)/\(device)/receiver-capabilities.json") }
        var capabilitiesSource: URL { app.appendingPathComponent("staging/\(requestID).json") }
        func stageCapabilities(_ bytes: Data) throws -> [String: Any] {
            try mkdir(capabilitiesFinal.deletingLastPathComponent())
            let request: [String: Any] = [
                "version": 1, "operation": "receiver_capabilities", "requestID": requestID,
                "receiver": receiver, "device": device, "byteCount": bytes.count,
                "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            ]
            try write(bytes, to: capabilitiesSource)
            try write(JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]), to: self.request)
            return request
        }
        func nativeFinal(_ name: String) -> URL { mailboxRoot.appendingPathComponent("pairing/\(invitationID)/\(name)") }
        func source(native: Bool) -> URL { app.appendingPathComponent("staging/\(requestID).\(native ? "hbp" : "hba")") }
        init(root: URL? = nil) throws {
            self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("NativeHelperFake-\(UUID().uuidString)")
            try mkdir(self.root)
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
            try runHelper(arguments: [argument], applicationRoot: { self.app }, io: io)
        }
        var io: HelperPublicationIO {
            HelperPublicationIO(
                providerRoot: {
                    if self.forbidProvider { throw Failure(message: "Unexpected provider access") }
                    if let error = self.providerError { throw error }
                    return self.provider
                },
                publish: { source, final in
                    try self.duringIPCPublication?()
                    try NativePairingLocalFakeTests.require(source.path.hasPrefix(self.app.path + "/"), "Private staging required")
                    try NativePairingLocalFakeTests.require(final.path.hasPrefix(self.provider.path + "/"), "Private fake provider required")
                    if self.detachOnPublication {
                        let directory = final.deletingLastPathComponent()
                        try FileManager.default.moveItem(at: directory, to: self.root.appendingPathComponent("detached-device"))
                        try self.mkdir(directory)
                    }
                    if self.failPublication { throw Failure(message: "synthetic failure before publication") }
                    self.publications += 1
                    if self.consumeIPCSource { try FileManager.default.moveItem(at: source, to: final) }
                    else { try self.write(Data(contentsOf: source), to: final) }
                },
                observe: { final in
                    try NativePairingLocalFakeTests.require(final.path.hasPrefix(self.provider.path + "/"), "Private observation required")
                    self.observations += 1
                    try self.afterIPCObservation?()
                    return (true, nil)
                }, wait: { preconditionFailure("Successful fake observation must not wait") },
                replaceMetadata: { payload, final, validatePaths in
                    if self.replaceStagingOnPublication {
                        try self.write(Data(contentsOf: self.capabilitiesSource), to: self.capabilitiesSource)
                    }
                    if self.detachOnPublication {
                        let directory = final.deletingLastPathComponent()
                        try FileManager.default.moveItem(at: directory, to: self.root.appendingPathComponent("detached-device"))
                        try self.mkdir(directory)
                    }
                    if self.failPublication { throw Failure(message: "synthetic failure before replacement") }
                    self.publications += 1
                    try coordinatedCapabilityReplacement(payload, final, validatePaths)
                }
            )
        }
        func close() { try? FileManager.default.removeItem(at: root) }
    }
}
#endif
