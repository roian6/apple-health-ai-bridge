import CryptoKit
import Foundation

struct MailboxAckCandidate {
    let authenticated: AuthenticatedDeliveryAckV1
    let bytes: Data
    let classification: MailboxAckClassification
    let handle: MailboxAckDeletionHandle
}

enum MailboxAckClassifier {
    static func classify(_ candidates: [MailboxAckCandidate]) -> [MailboxAckEvent] {
        let groups = Dictionary(grouping: candidates) {
            $0.authenticated.envelopeID
        }
        return groups.keys.sorted(by: lexicalDataOrder).flatMap {
            envelopeID -> [MailboxAckEvent] in
            guard let group = groups[envelopeID]?.sorted(by: candidateOrder),
                  let first = group.first else {
                return []
            }
            guard !group.contains(where: { $0.classification == .conflict }),
                  group.allSatisfy({ $0.bytes == first.bytes }) else {
                return [
                    MailboxAckEvent(
                        classification: .conflict,
                        receipt: first.authenticated.receipt,
                        handle: first.handle
                    ),
                ]
            }
            return group.enumerated().map { index, candidate in
                MailboxAckEvent(
                    classification: index == 0
                        ? candidate.classification
                        : .duplicateIdentical,
                    receipt: candidate.authenticated.receipt,
                    handle: candidate.handle
                )
            }
        }
    }

    private static func candidateOrder(
        _ lhs: MailboxAckCandidate,
        _ rhs: MailboxAckCandidate
    ) -> Bool {
        lhs.handle.fileName < rhs.handle.fileName
    }

    private static func lexicalDataOrder(_ lhs: Data, _ rhs: Data) -> Bool {
        lhs.lexicographicallyPrecedes(rhs)
    }
}

extension MailboxAckScanner {
    func makeCandidate(
        _ authenticated: AuthenticatedDeliveryAckV1,
        bytes: Data,
        identity: MailboxAckFileIdentity,
        fileName: String,
        classification: MailboxAckClassification
    ) -> MailboxAckCandidate {
        MailboxAckCandidate(
            authenticated: authenticated,
            bytes: bytes,
            classification: classification,
            handle: MailboxAckDeletionHandle(
                fileName: fileName,
                acknowledgmentSHA256: Self.sha256(bytes),
                identity: identity,
                envelopeID: authenticated.envelopeID
            )
        )
    }

    func classification(_ receipt: DeliveryReceiptV1) -> MailboxAckClassification {
        switch receipt.result {
        case .committed:
            .committed
        case .retryable:
            .retryableNack
        case .terminal:
            .terminalNack
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
