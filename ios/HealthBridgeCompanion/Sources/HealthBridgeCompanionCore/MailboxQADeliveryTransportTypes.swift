#if HEALTH_BRIDGE_MAILBOX_QA
import Foundation

enum MailboxKeyStoreError: Error {
    case malformedState
}

public struct DeliveryTransportInput: Equatable, Sendable {
    public let item: FileOutboxItem
    public let persistedBytes: Data

    public init(item: FileOutboxItem) throws {
        self.item = item
        persistedBytes = try Data(contentsOf: item.fileURL)
    }
}

public enum DeliveryTransportResult: CaseIterable, Equatable, Sendable {
    case collected
    case published
    case observed
    case committed
    case terminal
    case retryable
}

public protocol DeliveryTransport {
    @discardableResult
    func deliver(_ input: DeliveryTransportInput) throws -> DeliveryTransportResult
}

public struct DirectUploadCompletionDescriptor: Equatable, Sendable {
    public let itemID: String
    public let receiverGeneration: String
    public let receiverBindingID: String

    public init(
        itemID: String,
        receiverGeneration: String,
        receiverBindingID: String
    ) {
        self.itemID = itemID
        self.receiverGeneration = receiverGeneration
        self.receiverBindingID = receiverBindingID
    }
}
#endif
