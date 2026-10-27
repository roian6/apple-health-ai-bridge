import Foundation

/// Operation-local transport selection and connection fencing. No retained support cache.
public enum ReceiverCapabilityResolver {
    @MainActor
    public static func resolve(
        settingsStore: ReceiverSettingsStore,
        client: ReceiverClient,
        readMailbox: @MainActor (MailboxConnectionIdentityV1) async throws -> ReceiverCapabilities?,
        validate: @MainActor () throws -> Void = {}
    ) async throws -> ReceiverCapabilities? {
        try await resolve(
            connection: settingsStore.currentConnectionRecordV2(),
            currentConnection: { try settingsStore.currentConnectionRecordV2() },
            readDirect: { url, token in await client.receiverCapabilities(forBatchURL: url, bearerToken: token) },
            readMailbox: readMailbox, validate: validate
        )
    }

    @MainActor
    static func resolve(
        connection: ReceiverConnectionRecordV2?,
        currentConnection: @MainActor () throws -> ReceiverConnectionRecordV2?,
        readDirect: @MainActor (URL, String) async throws -> ReceiverCapabilities?,
        readMailbox: @MainActor (MailboxConnectionIdentityV1) async throws -> ReceiverCapabilities?,
        validate: @MainActor () throws -> Void = {}
    ) async throws -> ReceiverCapabilities? {
        try Task.checkCancellation()
        try validate()
        let result: ReceiverCapabilities?
        switch connection?.activation {
        case .paired(activeTransport: .mailbox):
            if case .available(let identity)? = connection?.mailboxIdentity {
                result = try await readMailbox(identity)
            } else { result = nil }
        case .paired(activeTransport: .directHTTP):
            let direct = connection?.transportConfigurations.compactMap { config -> DirectHTTPConnectionConfigurationV1? in
                if case .directHTTP(activation: .active, configuration: let value) = config { return value }
                return nil
            }.first
            if let direct, let url = URL(string: direct.receiverURLString) {
                result = try await readDirect(url, direct.bearerToken)
            } else { result = nil }
        default: result = nil
        }
        try Task.checkCancellation()
        try validate()
        guard try currentConnection() == connection else { throw CancellationError() }
        return result
    }
}
