import CryptoKit
import Foundation

public final class MailboxQASigningIdentity: MailboxSigningIdentityProviding {
    private let signing: Curve25519.Signing.PrivateKey
    private let agreement: Curve25519.KeyAgreement.PrivateKey

    public init(record: MailboxQAPairingRecordV1) throws {
        signing = try record.signingPrivateKey
        agreement = try record.agreementPrivateKey
    }

    public func loadOrCreate() throws -> MailboxPublicIdentity {
        try MailboxPublicIdentity(
            signingPrivateKey: signing.rawRepresentation,
            agreementPrivateKey: agreement.rawRepresentation
        )
    }

    public func sign(_ message: Data) throws -> Data {
        try signing.signature(for: message)
    }
}

public final class MailboxQADurableFinalizer: OutboxDeliveryCommitFinalizing {
    private let marker: URL

    public init(applicationSupportRoot: URL) {
        marker = applicationSupportRoot.appendingPathComponent(
            "committed-finalization-v1.json"
        )
    }

    public func isFinalized(
        _ context: OutboxDeliveryFinalizationContext
    ) throws -> Bool {
        guard FileManager.default.fileExists(atPath: marker.path) else {
            return false
        }
        let decoded = try JSONDecoder().decode(
            Marker.self,
            from: Data(contentsOf: marker)
        )
        return decoded.itemID == context.itemID
            && decoded.receiverBindingID == context.ownership.receiverBindingID
    }

    public func finalize(_ context: OutboxDeliveryFinalizationContext) throws {
        if try isFinalized(context) { return }
        let data = try canonicalJSON(
            Marker(
                v: 1,
                kind: "health_bridge.mailbox_qa_finalization.v1",
                itemID: context.itemID,
                receiverBindingID: context.ownership.receiverBindingID
            )
        )
        try data.write(to: marker, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: marker.path
        )
    }

    private struct Marker: Codable {
        let v: Int
        let kind: String
        let itemID: String
        let receiverBindingID: String

        enum CodingKeys: String, CodingKey {
            case v, kind
            case itemID = "item_id"
            case receiverBindingID = "receiver_binding_id"
        }
    }
}

public struct MailboxQADeviceReportContext: Sendable {
    public let runID: String
    public let challenge: String
    public let head: String
    public let qaBundleFingerprint: String
    public let qaContainerFingerprint: String
    public let executableSHA256: String
    public let deviceFingerprint: String
    public let deviceModel: String
    public let osVersion: String
    public let startedAtMS: Int64
    public let finishedAtMS: Int64
    public let protectionState: String
}

public enum MailboxQADeviceReport {
    private static let domain = Data(
        "health-bridge/mailbox/m3/v1/device-report/signature".utf8
    )

    public static func signed(
        context: MailboxQADeviceReportContext,
        state: MailboxQADurableStateV1,
        signer: MailboxQASigningIdentity
    ) throws -> Data {
        guard let envelopeSHA256 = state.envelopeSHA256 else {
            throw MailboxQAHarnessError.invalidState
        }
        let unsigned = Unsigned(
            v: 1,
            kind: "health_bridge.mailbox_m3_device_report.v1",
            runID: context.runID,
            challenge: context.challenge,
            head: context.head,
            qaBundleFingerprint: context.qaBundleFingerprint,
            qaContainerFingerprint: context.qaContainerFingerprint,
            executableSHA256: context.executableSHA256,
            deviceFingerprint: context.deviceFingerprint,
            deviceModel: context.deviceModel,
            osVersion: context.osVersion,
            startedAtMS: context.startedAtMS,
            finishedAtMS: context.finishedAtMS,
            transitionCounts: state.transitions,
            syntheticPayloadSHA256: SHA256.hash(
                data: MailboxQASyntheticPayload.exactBytes
            ).map { String(format: "%02x", $0) }.joined(),
            envelopeSHA256: envelopeSHA256,
            envelopeReuseCount: state.envelopeReuseCount,
            lifecycleEpoch: state.lifecycleEpoch,
            restartEpoch: state.restartEpoch,
            finalizationCount: state.finalizationCount,
            faultInjectionCount: state.faultInjectionCount,
            foregroundObservationCount: state.foregroundObservationCount,
            backgroundObservationCount: state.backgroundObservationCount,
            protectedDataAvailableCount: state.protectedDataAvailableCount,
            protectedDataUnavailableCount: state.protectedDataUnavailableCount,
            protectionState: context.protectionState
        )
        let canonical = try canonicalJSON(unsigned)
        let signature = try signer.sign(domain + Data([0]) + canonical)
        return try canonicalJSON(
            Signed(unsigned: unsigned, signature: signature.base64URLEncodedString())
        )
    }

    private struct Unsigned: Codable {
        let v: Int
        let kind: String
        let runID: String
        let challenge: String
        let head: String
        let qaBundleFingerprint: String
        let qaContainerFingerprint: String
        let executableSHA256: String
        let deviceFingerprint: String
        let deviceModel: String
        let osVersion: String
        let startedAtMS: Int64
        let finishedAtMS: Int64
        let transitionCounts: MailboxQATransitionCountsV1
        let syntheticPayloadSHA256: String
        let envelopeSHA256: String
        let envelopeReuseCount: Int
        let lifecycleEpoch: Int
        let restartEpoch: Int
        let finalizationCount: Int
        let faultInjectionCount: Int
        let foregroundObservationCount: Int
        let backgroundObservationCount: Int
        let protectedDataAvailableCount: Int
        let protectedDataUnavailableCount: Int
        let protectionState: String

        enum CodingKeys: String, CodingKey {
            case v, kind, challenge, head
            case runID = "run_id"
            case qaBundleFingerprint = "qa_bundle_fingerprint"
            case qaContainerFingerprint = "qa_container_fingerprint"
            case executableSHA256 = "executable_sha256"
            case deviceFingerprint = "device_fingerprint"
            case deviceModel = "device_model"
            case osVersion = "os_version"
            case startedAtMS = "started_at_ms"
            case finishedAtMS = "finished_at_ms"
            case transitionCounts = "transition_counts"
            case syntheticPayloadSHA256 = "synthetic_payload_sha256"
            case envelopeSHA256 = "envelope_sha256"
            case envelopeReuseCount = "envelope_reuse_count"
            case lifecycleEpoch = "lifecycle_epoch"
            case restartEpoch = "restart_epoch"
            case finalizationCount = "finalization_count"
            case faultInjectionCount = "fault_injection_count"
            case foregroundObservationCount = "foreground_observation_count"
            case backgroundObservationCount = "background_observation_count"
            case protectedDataAvailableCount = "protected_data_available_count"
            case protectedDataUnavailableCount = "protected_data_unavailable_count"
            case protectionState = "protection_state"
        }
    }

    private struct Signed: Encodable {
        let unsigned: Unsigned
        let signature: String

        func encode(to encoder: Encoder) throws {
            try unsigned.encode(to: encoder)
            var container = encoder.container(keyedBy: SignatureKey.self)
            try container.encode(signature, forKey: .signature)
        }

        private enum SignatureKey: String, CodingKey {
            case signature
        }
    }
}

func canonicalJSON<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
