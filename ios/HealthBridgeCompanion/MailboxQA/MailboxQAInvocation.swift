import CryptoKit
import Foundation
import Security
import UIKit

@MainActor
final class MailboxQAInvocation {
    private var activeHarness: MailboxQAHarness?

    func handle(_ url: URL) async -> MailboxQAInvocationOutcome {
        try? writeEntryMarker()
        guard url.host == "invoke" else {
            return .failed(
                stage: "validate_url",
                error: MailboxQAInvocationError.malformedInvocation
            )
        }
        var stage = "load_configuration"
        do {
            let configuration = try MailboxQAConfiguration.load()
            stage = "validate_url"
            guard url.scheme == configuration.urlScheme else {
                throw MailboxQAInvocationError.malformedInvocation
            }
            stage = "parse_request"
            let request = try MailboxQARequest(url: url)
            stage = "validate_identity"
            guard request.sourceCommit == configuration.sourceCommit,
                  request.bundleIdentifier == configuration.bundleIdentifier,
                  request.containerIdentifier == configuration.containerIdentifier,
                  request.keychainService == configuration.keychainService,
                  request.outboxRoot == configuration.outboxRoot
            else {
                throw MailboxQAInvocationError.identityMismatch
            }
            switch request.action {
            case .pair:
                stage = "pair"
                try await QAMailboxPairing.redeem(
                    request: request,
                    configuration: configuration
                )
                activeHarness = nil
                try writeOutput(
                    action: request.action,
                    status: "paired",
                    configuration: configuration
                )
                return .succeeded(status: "paired")
            case .advance:
                stage = "open_harness"
                let harness = try harness(
                    configuration: configuration
                )
                stage = "observe_protected_data"
                try harness.observeProtectedData(
                    available: UIApplication.shared.isProtectedDataAvailable
                )
                stage = "advance"
                var state = try harness.advance(fault: request.fault)
                if request.fault == nil {
                    for _ in 0..<15 where state.lastPhase != .providerObserved {
                        if state.lastPhase == .published {
                            try await Task.sleep(nanoseconds: 2_000_000_000)
                        }
                        state = try harness.advance()
                    }
                }
                try writeOutput(
                    action: request.action,
                    status: state.lastPhase?.rawValue ?? "collected",
                    configuration: configuration
                )
                return .succeeded(status: state.lastPhase?.rawValue ?? "collected")
            case .scanFinalize:
                stage = "open_harness"
                let harness = try harness(
                    configuration: configuration
                )
                stage = "observe_protected_data"
                try harness.observeProtectedData(
                    available: UIApplication.shared.isProtectedDataAvailable
                )
                stage = "scan_finalize"
                let state = try harness.scanAndFinalize()
                try writeOutput(
                    action: request.action,
                    status: state.lastPhase?.rawValue ?? "hold",
                    configuration: configuration
                )
                return .succeeded(status: state.lastPhase?.rawValue ?? "hold")
            case .signedReport:
                stage = "open_harness"
                let harness = try harness(configuration: configuration)
                stage = "observe_protected_data"
                try harness.observeProtectedData(
                    available: UIApplication.shared.isProtectedDataAvailable
                )
                stage = "signed_report"
                let report = try harness.signedReport(
                    try deviceReportContext(configuration: configuration)
                )
                try writePrivate(
                    report,
                    to: try applicationSupportRoot(configuration)
                        .appendingPathComponent("device-report.hbjcs1")
                )
                try writeOutput(
                    action: request.action,
                    status: "report_written",
                    configuration: configuration
                )
                return .succeeded(status: "report_written")
            case .cleanup:
                stage = "open_harness"
                let harness = try harness(configuration: configuration)
                stage = "cleanup"
                try harness.removeQAProviderArtifacts()
                try QAMailboxPairing.delete(
                    service: configuration.keychainService
                )
                activeHarness = nil
                try writeOutput(
                    action: request.action,
                    status: "qa_artifacts_removed",
                    configuration: configuration
                )
                return .succeeded(status: "qa_artifacts_removed")
            }
        } catch {
            try? writeFailure(error, stage: stage)
            return .failed(stage: stage, error: error)
        }
    }

    func observeLifecycle(foreground: Bool) async {
        do {
            let configuration = try MailboxQAConfiguration.load()
            try harness(configuration: configuration).observeLifecycle(
                foreground: foreground
            )
        } catch {
            return
        }
    }

    func observeProtectedData(available: Bool) async {
        do {
            let configuration = try MailboxQAConfiguration.load()
            try harness(configuration: configuration).observeProtectedData(
                available: available
            )
        } catch {
            return
        }
    }

    private func harness(
        configuration: MailboxQAConfiguration
    ) throws -> MailboxQAHarness {
        if let activeHarness { return activeHarness }
        guard let providerRoot = FileManager.default.url(
            forUbiquityContainerIdentifier: configuration.containerIdentifier
        ) else {
            throw MailboxQAInvocationError.identityMismatch
        }
        let record = try QAMailboxPairing.load(
            service: configuration.keychainService
        )
        let created = try MailboxQAHarness(
            applicationSupportRoot: applicationSupportRoot(configuration),
            providerRoot: providerRoot,
            containerIdentifier: configuration.containerIdentifier,
            pairing: record
        )
        activeHarness = created
        return created
    }

    private func writeFailure(_ error: Error, stage: String) throws {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }
        let failure = error as NSError
        let encoded = try JSONSerialization.data(
            withJSONObject: [
                "v": 1,
                "kind": "health_bridge.mailbox_qa_failure.v1",
                "stage": stage,
                "error_domain": failure.domain,
                "error_code": failure.code,
            ],
            options: [.sortedKeys]
        )
        try writePrivate(
            encoded,
            to: support.appendingPathComponent("MailboxQALastFailure.json")
        )
    }

    private func writeEntryMarker() throws {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }
        let encoded = try JSONSerialization.data(
            withJSONObject: [
                "v": 1,
                "kind": "health_bridge.mailbox_qa_invocation_entry.v1",
            ],
            options: [.sortedKeys]
        )
        try writePrivate(
            encoded,
            to: support.appendingPathComponent("MailboxQALastEntry.json")
        )
    }
}

struct MailboxQAInvocationOutcome: Equatable {
    let succeeded: Bool
    let status: String
    let stage: String?
    let errorDomain: String?
    let errorCode: Int?

    static func succeeded(status: String) -> Self {
        Self(
            succeeded: true,
            status: status,
            stage: nil,
            errorDomain: nil,
            errorCode: nil
        )
    }

    static func failed(stage: String, error: Error) -> Self {
        let failure = error as NSError
        return Self(
            succeeded: false,
            status: "failed",
            stage: stage,
            errorDomain: failure.domain,
            errorCode: failure.code
        )
    }
}

enum MailboxQAInvocationError: Error {
    case malformedInvocation
    case identityMismatch
    case pairingRejected
    case keychainFailure
    case existingPairingMismatch
}

struct MailboxQARequest: Decodable {
    let v: Int
    let kind: String
    let runID: String
    let challenge: String
    let sourceCommit: String
    let bundleIdentifier: String
    let containerIdentifier: String
    let keychainService: String
    let outboxRoot: String
    let namespace: String
    let redeemURL: URL?
    let invitationSecret: String?
    let action: MailboxQAAction
    let fault: MailboxQAFault?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case v, kind, challenge, namespace, action, fault
        case runID = "run_id"
        case sourceCommit = "source_commit"
        case bundleIdentifier = "bundle_identifier"
        case containerIdentifier = "container_identifier"
        case keychainService = "keychain_service"
        case outboxRoot = "outbox_root"
        case redeemURL = "redeem_url"
        case invitationSecret = "invitation_secret"
    }

    init(url: URL) throws {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ), let encoded = components.queryItems?.first(
            where: { $0.name == "request" }
        )?.value, let data = Data(base64Encoded: encoded) else {
            throw MailboxQAInvocationError.malformedInvocation
        }
        guard let fields = try JSONSerialization.jsonObject(with: data)
            as? [String: Any],
              Set(fields.keys).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))),
              Set([
                  "v", "kind", "run_id", "challenge", "source_commit",
                  "bundle_identifier", "container_identifier",
                  "keychain_service", "outbox_root", "namespace", "action",
              ]).isSubset(of: Set(fields.keys)) else {
            throw MailboxQAInvocationError.malformedInvocation
        }
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        guard decoded.v == 1,
              decoded.kind == "health_bridge.mailbox_qa_invocation.v1",
              decoded.runID.utf8.count == 32,
              decoded.runID.utf8.allSatisfy(Self.isLowerHex),
              try strictBase64URL(decoded.challenge, count: 32).count == 32,
              decoded.sourceCommit.utf8.count == 40,
              decoded.sourceCommit.utf8.allSatisfy(Self.isLowerHex),
              decoded.namespace.hasPrefix("qa-"),
              decoded.namespace.utf8.allSatisfy({
                  (48 ... 57).contains($0)
                      || (97 ... 122).contains($0)
                      || $0 == 45
              }) else {
            throw MailboxQAInvocationError.malformedInvocation
        }
        switch decoded.action {
        case .pair:
            guard let redeemURL = decoded.redeemURL,
                  decoded.invitationSecret?.isEmpty == false,
                  redeemURL.scheme == "http",
                  redeemURL.path == "/qa/v1/pairing/redeem",
                  redeemURL.port.map({ (1024 ... 65535).contains($0) }) == true,
                  redeemURL.user == nil,
                  redeemURL.password == nil,
                  redeemURL.query == nil,
                  redeemURL.fragment == nil,
                  Self.isPrivateReceiverHost(redeemURL.host),
                  decoded.fault == nil else {
                throw MailboxQAInvocationError.malformedInvocation
            }
        case .advance:
            guard decoded.redeemURL == nil,
                  decoded.invitationSecret == nil else {
                throw MailboxQAInvocationError.malformedInvocation
            }
        case .scanFinalize, .signedReport, .cleanup:
            guard decoded.redeemURL == nil,
                  decoded.invitationSecret == nil,
                  decoded.fault == nil else {
                throw MailboxQAInvocationError.malformedInvocation
            }
        }
        self = decoded
    }

    private static func isPrivateReceiverHost(_ host: String?) -> Bool {
        guard let octets = host?.split(separator: ".", omittingEmptySubsequences: false),
              octets.count == 4,
              let first = Int(octets[0]),
              let second = Int(octets[1]),
              octets.allSatisfy({ octet in
                  guard let value = Int(octet) else { return false }
                  return value >= 0
                      && value <= 255
                      && String(value) == String(octet)
              })
        else {
            return false
        }
        return first == 10
            || (first == 100 && second >= 64 && second <= 127)
            || first == 127
            || (first == 172 && second >= 16 && second <= 31)
            || (first == 192 && second == 168)
    }

    private static func isLowerHex(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
    }
}

private enum QAMailboxPairing {
    static func redeem(
        request: MailboxQARequest,
        configuration: MailboxQAConfiguration
    ) async throws {
        if let existing = try loadIfPresent(
            service: configuration.keychainService
        ) {
            try existing.validate()
            guard let invitationSecret = request.invitationSecret,
                  let redeemURL = request.redeemURL else {
                throw MailboxQAInvocationError.malformedInvocation
            }
            guard existing.runID == request.runID,
                  existing.challenge == request.challenge,
                  existing.sourceCommit == request.sourceCommit,
                  existing.namespace == request.namespace,
                  existing.invitationFingerprint
                  == sha256(Data(invitationSecret.utf8)),
                  existing.redeemEndpointFingerprint
                  == sha256(Data(redeemURL.absoluteString.utf8)) else {
                throw MailboxQAInvocationError.existingPairingMismatch
            }
            return
        }
        guard let invitationSecret = request.invitationSecret,
              let redeemURL = request.redeemURL else {
            throw MailboxQAInvocationError.malformedInvocation
        }
        let signing = Curve25519.Signing.PrivateKey()
        let agreement = Curve25519.KeyAgreement.PrivateKey()
        let credential = try randomCredential()
        let installationID = UUID().uuidString.lowercased()
        let body = try JSONEncoder().encode(
            RedeemRequest(
                invitationSecret: invitationSecret,
                deviceCredential: credential,
                installationID: installationID,
                deviceSigningPublicKey: base64URL(
                    signing.publicKey.rawRepresentation
                ),
                deviceAgreementPublicKey: base64URL(
                    agreement.publicKey.rawRepresentation
                ),
                namespace: request.namespace,
                runID: request.runID,
                challenge: request.challenge
            )
        )
        var urlRequest = URLRequest(url: redeemURL)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.timeoutInterval = 15
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200
        else {
            throw MailboxQAInvocationError.pairingRejected
        }
        let completion = try MailboxQAPairingCompletionV1.strictDecode(
            data,
            namespace: request.namespace,
            runID: request.runID
        )
        let receiverID = try decodeBase64URL(completion.receiverID, byteCount: 16)
        let deviceID = try decodeBase64URL(completion.deviceID, byteCount: 16)
        _ = try decodeBase64URL(
            completion.receiverBindingID,
            byteCount: 32
        )
        let receiverSigningPublicKey = try decodeBase64URL(
            completion.receiverSigningPublicKey,
            byteCount: 32
        )
        let receiverAgreementPublicKey = try decodeBase64URL(
            completion.receiverAgreementPublicKey,
            byteCount: 32
        )
        let persisted = MailboxQAPairingRecordV1(
                v: 1,
                kind: "health_bridge.mailbox_qa_pairing_record.v1",
                runID: request.runID,
                challenge: request.challenge,
                sourceCommit: request.sourceCommit,
                namespace: request.namespace,
                invitationFingerprint: sha256(Data(invitationSecret.utf8)),
                redeemEndpointFingerprint: sha256(
                    Data(redeemURL.absoluteString.utf8)
                ),
                receiverID: receiverID,
                deviceID: deviceID,
                receiverBindingID: completion.receiverBindingID,
                connectionGeneration: completion.connectionGeneration,
                receiverSigningPublicKey: receiverSigningPublicKey,
                receiverAgreementPublicKey: receiverAgreementPublicKey,
                receiverSigningKeyID: completion.receiverSigningKeyID,
                receiverAgreementKeyID: completion.receiverAgreementKeyID,
                deviceSigningPrivateKey: signing.rawRepresentation,
                deviceAgreementPrivateKey: agreement.rawRepresentation,
                deviceCredential: credential,
                installationID: installationID
        )
        try persisted.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let record = try encoder.encode(persisted)
        try save(record, service: configuration.keychainService)
    }

    private static func randomCredential() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            == errSecSuccess
        else {
            throw MailboxQAInvocationError.keychainFailure
        }
        return "hb_" + base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(
        _ encoded: String,
        byteCount: Int
    ) throws -> Data {
        let canonicalAlphabet = encoded.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || byte == 45
                || byte == 95
        }
        guard !encoded.isEmpty, canonicalAlphabet else {
            throw MailboxQAInvocationError.pairingRejected
        }
        let standard = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let decoded = Data(base64Encoded: standard + padding),
              decoded.count == byteCount,
              base64URL(decoded) == encoded
        else {
            throw MailboxQAInvocationError.pairingRejected
        }
        return decoded
    }

    private static func save(_ data: Data, service: String) throws {
        let lookup: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "qa-mailbox-connection-v1",
        ]
        let query: [CFString: Any] = lookup.merging([
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { _, new in new }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status != errSecDuplicateItem else {
            throw MailboxQAInvocationError.existingPairingMismatch
        }
        guard status == errSecSuccess else {
            throw MailboxQAInvocationError.keychainFailure
        }
    }

    static func delete(service: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "qa-mailbox-connection-v1",
        ]
        guard SecItemDelete(query as CFDictionary) == errSecSuccess else {
            throw MailboxQAInvocationError.keychainFailure
        }
    }

    static func load(service: String) throws -> MailboxQAPairingRecordV1 {
        guard let record = try loadIfPresent(service: service) else {
            throw MailboxQAInvocationError.keychainFailure
        }
        try record.validate()
        return record
    }

    private static func loadIfPresent(
        service: String
    ) throws -> MailboxQAPairingRecordV1? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "qa-mailbox-connection-v1",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else {
            throw MailboxQAInvocationError.keychainFailure
        }
        query.removeAll()
        return try JSONDecoder().decode(MailboxQAPairingRecordV1.self, from: data)
    }
}

private struct RedeemRequest: Encodable {
    let invitationSecret: String
    let deviceCredential: String
    let installationID: String
    let deviceSigningPublicKey: String
    let deviceAgreementPublicKey: String
    let namespace: String
    let runID: String
    let challenge: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case namespace, challenge
        case invitationSecret = "invitation_secret"
        case deviceCredential = "device_credential"
        case installationID = "installation_id"
        case deviceSigningPublicKey = "device_signing_public_key"
        case deviceAgreementPublicKey = "device_agreement_public_key"
        case runID = "run_id"
    }
}

private struct MailboxQAInvocationOutput: Encodable {
    let v: Int
    let kind: String
    let action: MailboxQAAction
    let status: String
}

private func applicationSupportRoot(
    _ configuration: MailboxQAConfiguration
) throws -> URL {
    guard let support = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first else {
        throw MailboxQAInvocationError.identityMismatch
    }
    let fingerprint = SHA256.hash(
        data: Data(configuration.bundleIdentifier.utf8)
    ).prefix(8).map { String(format: "%02x", $0) }.joined()
    let root = support.appendingPathComponent(
        "\(configuration.outboxRoot)-\(fingerprint)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    return root
}

private func writeOutput(
    action: MailboxQAAction,
    status: String,
    configuration: MailboxQAConfiguration
) throws {
    try writePrivate(
        try canonicalJSON(
            MailboxQAInvocationOutput(
                v: 1,
                kind: "health_bridge.mailbox_qa_invocation_output.v1",
                action: action,
                status: status
            )
        ),
        to: try applicationSupportRoot(configuration)
            .appendingPathComponent("invocation-output-v1.json")
    )
}

private func writePrivate(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: url.path
    )
}

private func deviceReportContext(
    configuration: MailboxQAConfiguration
) throws -> MailboxQADeviceReportContext {
    guard let executable = Bundle.main.executableURL,
          let vendor = UIDevice.current.identifierForVendor else {
        throw MailboxQAInvocationError.identityMismatch
    }
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    let pairing = try QAMailboxPairing.load(
        service: configuration.keychainService
    )
    return MailboxQADeviceReportContext(
        runID: pairing.runID,
        challenge: pairing.challenge,
        head: configuration.sourceCommit,
        qaBundleFingerprint: shortFingerprint(
            domain: "health-bridge/mailbox/m3/v1/qa-bundle",
            value: configuration.bundleIdentifier
        ),
        qaContainerFingerprint: shortFingerprint(
            domain: "health-bridge/mailbox/m3/v1/qa-container",
            value: configuration.containerIdentifier
        ),
        executableSHA256: sha256(try Data(contentsOf: executable)),
        deviceFingerprint: shortFingerprint(
            domain: "health-bridge/mailbox/m3/v1/device",
            value: vendor.uuidString.lowercased()
        ),
        deviceModel: UIDevice.current.model,
        osVersion: UIDevice.current.systemVersion,
        startedAtMS: now,
        finishedAtMS: now,
        protectionState: UIApplication.shared.isProtectedDataAvailable
            ? "available"
            : "unavailable"
    )
}

private func shortFingerprint(domain: String, value: String) -> String {
    var material = Data(domain.utf8)
    material.append(0)
    material.append(Data(value.utf8))
    return SHA256.hash(data: material).prefix(8).map {
        String(format: "%02x", $0)
    }.joined()
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
