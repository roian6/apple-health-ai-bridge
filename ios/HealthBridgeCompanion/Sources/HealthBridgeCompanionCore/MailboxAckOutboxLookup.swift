import CryptoKit
import Foundation

public final class FileOutboxMailboxAckLookup: MailboxAckOutboxLookingUp {
    private let outbox: FileOutbox
    private let deviceSigningPublicKey: Curve25519.Signing.PublicKey

    public init(
        outbox: FileOutbox,
        deviceSigningPublicKey: Curve25519.Signing.PublicKey
    ) {
        self.outbox = outbox
        self.deviceSigningPublicKey = deviceSigningPublicKey
    }

    func record(for item: FileOutboxItem) throws -> MailboxAckOutboxRecord {
        guard let binding = item.mailboxBinding,
              let receiverBindingID = item.receiverIdentity,
              binding.envelopeFilename == "\(item.id).hbe" else {
            throw FileOutboxMailboxError.finalizationConflict
        }
        let envelope = try MailboxRegularFileReader.read(
            outbox.directoryURL.appendingPathComponent(binding.envelopeFilename),
            maximumBytes: MailboxLayoutV1.maximumDeliveryBytes
        )
        guard Self.sha256(envelope) == binding.envelopeSHA256 else {
            throw FileOutboxMailboxError.finalizationConflict
        }
        let claims = try DeliveryProtocolV1.inspectDelivery(
            envelope,
            senderSigningPublicKey: deviceSigningPublicKey
        )
        let payload = try MailboxRegularFileReader.read(
            item.fileURL,
            maximumBytes: Int64(DeliveryProtocolV1.maxPayloadBytes)
        )
        guard Self.sha256(payload) == binding.payloadSHA256,
              claims.payloadSHA256 == binding.payloadSHA256 else {
            throw FileOutboxMailboxError.finalizationConflict
        }
        return MailboxAckOutboxRecord(
            envelopeID: claims.envelopeID,
            payloadSHA256: binding.payloadSHA256,
            receiverID: claims.receiverID,
            deviceID: claims.deviceID,
            receiverBindingID: receiverBindingID,
            connectionGeneration: claims.connectionGeneration,
            receiverAgreementKeyID: claims.receiverAgreementKeyID,
            deviceSigningKeyID: claims.senderSigningKeyID
        )
    }

    public func lookup(envelopeID: Data) throws -> MailboxAckLookupResult {
        var matches: [MailboxAckOutboxRecord] = []
        for item in try outbox.mailboxBoundItemsForAckScanning() {
            guard let binding = item.mailboxBinding,
                  let receiverBindingID = item.receiverIdentity,
                  binding.envelopeFilename == "\(item.id).hbe" else {
                continue
            }
            if let state = item.deliveryState,
               state.phase == .committedFinalized {
                guard let ownership = state.ownership,
                      let receipt = state.committedReceipt,
                      ownership.receiverBindingID == receiverBindingID,
                      receipt.payloadSHA256 == binding.payloadSHA256 else {
                    return .conflict
                }
                guard receipt.envelopeID == envelopeID else { continue }
                matches.append(
                    MailboxAckOutboxRecord(
                        envelopeID: receipt.envelopeID,
                        payloadSHA256: binding.payloadSHA256,
                        receiverID: ownership.receiverID,
                        deviceID: ownership.deviceID,
                        receiverBindingID: ownership.receiverBindingID,
                        connectionGeneration: ownership.connectionGeneration,
                        receiverAgreementKeyID: ownership.receiverAgreementKeyID,
                        deviceSigningKeyID: ownership.deviceSigningKeyID
                    )
                )
                continue
            }
            let envelopeURL = outbox.directoryURL
                .appendingPathComponent(binding.envelopeFilename)
            let envelope = try MailboxRegularFileReader.read(
                envelopeURL,
                maximumBytes: MailboxLayoutV1.maximumDeliveryBytes
            )
            guard Self.sha256(envelope) == binding.envelopeSHA256 else {
                return .conflict
            }
            let claims: DeliveryEnvelopeClaimsV1
            do {
                claims = try DeliveryProtocolV1.inspectDelivery(
                    envelope,
                    senderSigningPublicKey: deviceSigningPublicKey
                )
            } catch {
                return .conflict
            }
            guard claims.envelopeID == envelopeID else { continue }
            let payload: Data
            do {
                payload = try MailboxRegularFileReader.read(
                    item.fileURL,
                    maximumBytes: Int64(DeliveryProtocolV1.maxPayloadBytes)
                )
            } catch {
                return .conflict
            }
            guard Self.sha256(payload) == binding.payloadSHA256,
                  claims.payloadSHA256 == binding.payloadSHA256 else {
                return .conflict
            }
            matches.append(
                MailboxAckOutboxRecord(
                    envelopeID: claims.envelopeID,
                    payloadSHA256: binding.payloadSHA256,
                    receiverID: claims.receiverID,
                    deviceID: claims.deviceID,
                    receiverBindingID: receiverBindingID,
                    connectionGeneration: claims.connectionGeneration,
                    receiverAgreementKeyID: claims.receiverAgreementKeyID,
                    deviceSigningKeyID: claims.senderSigningKeyID
                )
            )
        }
        guard matches.count < 2 else { return .conflict }
        return matches.first.map(MailboxAckLookupResult.active) ?? .unknown
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
