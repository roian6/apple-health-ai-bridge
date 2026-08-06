import CryptoKit
import Darwin
import Foundation

public final class MailboxQAHarness {
    let applicationSupportRoot: URL
    private let stateURL: URL
    let pairing: MailboxQAPairingRecordV1
    let outbox: FileOutbox
    let locator: MailboxResolvedLocatorV1
    let signer: MailboxQASigningIdentity
    let envelopeID: () -> Data
    let observeEnvelope: (URL, String) throws -> Bool
    private var state: MailboxQADurableStateV1

    public convenience init(
        applicationSupportRoot: URL,
        providerRoot: URL?,
        containerIdentifier: String,
        pairing: MailboxQAPairingRecordV1
    ) throws {
        try self.init(
            applicationSupportRoot: applicationSupportRoot,
            providerRoot: providerRoot,
            containerIdentifier: containerIdentifier,
            pairing: pairing,
            envelopeID: { Self.randomID() },
            observeEnvelope: MailboxQAProviderObserver.observe
        )
    }

    init(
        applicationSupportRoot: URL,
        providerRoot: URL?,
        containerIdentifier: String,
        pairing: MailboxQAPairingRecordV1,
        envelopeID: @escaping () -> Data,
        observeEnvelope: @escaping (URL, String) throws -> Bool
    ) throws {
        try pairing.validate()
        self.applicationSupportRoot = applicationSupportRoot
        self.pairing = pairing
        self.envelopeID = envelopeID
        self.observeEnvelope = observeEnvelope
        try FileManager.default.createDirectory(
            at: applicationSupportRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        stateURL = applicationSupportRoot.appendingPathComponent(
            "qa-durable-state-v1.json"
        )
        outbox = try FileOutbox(
            directory: applicationSupportRoot.appendingPathComponent(
                "outbox-v4",
                isDirectory: true
            )
        )
        locator = try MailboxLocatorV1.resolveIsolated(
            providerRoot: providerRoot,
            containerIdentifier: containerIdentifier,
            receiverComponent: pairing.receiverID.hexV1,
            deviceComponent: pairing.deviceID.hexV1,
            localRecordURL: applicationSupportRoot.appendingPathComponent(
                "mailbox-locator-v1.json"
            )
        )
        signer = try MailboxQASigningIdentity(record: pairing)
        if FileManager.default.fileExists(atPath: stateURL.path) {
            var recovered = try JSONDecoder().decode(
                MailboxQADurableStateV1.self,
                from: Data(contentsOf: stateURL)
            )
            guard recovered.runID == pairing.runID,
                  recovered.challenge == pairing.challenge,
                  recovered.sourceCommit == pairing.sourceCommit
            else {
                throw MailboxQAHarnessError.existingPairingMismatch
            }
            recovered.lifecycleEpoch += 1
            if let itemID = recovered.itemID,
               let binding = try outbox.mailboxBinding(for: itemID),
               binding.envelopeSHA256 == recovered.envelopeSHA256 {
                recovered.restartEpoch += 1
                recovered.envelopeReuseCount += 1
            }
            state = recovered
        } else {
            state = MailboxQADurableStateV1(
                v: 1,
                kind: "health_bridge.mailbox_qa_durable_state.v1",
                runID: pairing.runID,
                challenge: pairing.challenge,
                sourceCommit: pairing.sourceCommit,
                itemID: nil,
                lastPhase: nil,
                envelopeSHA256: nil,
                envelopeReuseCount: 0,
                lifecycleEpoch: 1,
                restartEpoch: 0,
                finalizationCount: 0,
                faultInjectionCount: 0,
                foregroundObservationCount: 0,
                backgroundObservationCount: 0,
                protectedDataAvailableCount: 0,
                protectedDataUnavailableCount: 0,
                transitions: MailboxQATransitionCountsV1()
            )
        }
        try persist()
    }

    @discardableResult
    public func advance(
        fault: MailboxQAFault? = nil
    ) throws -> MailboxQADurableStateV1 {
        guard state.lastPhase != .committedFinalized else {
            throw MailboxQAHarnessError.invalidState
        }
        let item = try ensureSyntheticItem()
        let coordinator = try coordinator(fault: fault)
        if fault != nil {
            guard try coordinator.state(itemID: item.id)?.phase == .encrypted else {
                throw MailboxQAHarnessError.invalidState
            }
            state.faultInjectionCount += 1
        }
        let updated = try coordinator.advance(itemID: item.id)
        try observe(updated.phase)
        if let binding = try outbox.mailboxBinding(for: item.id) {
            if let previous = state.envelopeSHA256,
               previous != binding.envelopeSHA256 {
                throw MailboxQAHarnessError.invalidState
            }
            state.envelopeSHA256 = binding.envelopeSHA256
        }
        try persist()
        return state
    }

    @discardableResult
    public func scanAndFinalize() throws -> MailboxQADurableStateV1 {
        guard let itemID = state.itemID else {
            throw MailboxQAHarnessError.invalidState
        }
        let coordinator = try coordinator(fault: nil)
        let report = try scanner().scan()
        for event in report.events {
            switch event.classification {
            case .committed:
                let disposition = try coordinator.consume(event, itemID: itemID)
                guard disposition == .ackVerified else {
                    throw MailboxQAHarnessError.invalidState
                }
                try observe(.ackVerified)
                let previousCount = state.finalizationCount
                let finalized = try coordinator.finalizeCommitted(itemID: itemID)
                guard finalized.phase == .committedFinalized else {
                    throw MailboxQAHarnessError.invalidState
                }
                if previousCount == state.finalizationCount {
                    state.finalizationCount += 1
                }
                try observe(.committedFinalized)
                try coordinator.deleteAcknowledgment(for: event, itemID: itemID)
            case .retryableNack:
                guard try coordinator.consume(event, itemID: itemID)
                    == .retryableFailure else {
                    throw MailboxQAHarnessError.invalidState
                }
                try observe(.retryableFailure)
            case .terminalNack:
                guard try coordinator.consume(event, itemID: itemID) == .terminalHold else {
                    throw MailboxQAHarnessError.invalidState
                }
                try observe(.terminalFailure)
            case .duplicateIdentical, .conflict:
                throw MailboxQAHarnessError.invalidState
            }
        }
        try persist()
        return state
    }

    public func signedReport(
        _ context: MailboxQADeviceReportContext
    ) throws -> Data {
        try MailboxQADeviceReport.signed(
            context: context,
            state: state,
            signer: signer
        )
    }

    public func observeLifecycle(foreground: Bool) throws {
        if foreground {
            state.foregroundObservationCount += 1
        } else {
            state.backgroundObservationCount += 1
        }
        try persist()
    }

    public func observeProtectedData(available: Bool) throws {
        if available {
            state.protectedDataAvailableCount += 1
        } else {
            state.protectedDataUnavailableCount += 1
        }
        try persist()
    }

    public func removeQAProviderArtifacts() throws {
        let finalized = state.lastPhase == .committedFinalized
            && state.finalizationCount == 1
        let pristine = state.lastPhase == nil
            && state.itemID == nil
            && state.envelopeSHA256 == nil
            && state.finalizationCount == 0
        let terminal = if state.lastPhase == .terminalFailure,
                          let itemID = state.itemID {
            try outbox.deliveryState(for: itemID)?.phase == .terminalFailure
        } else {
            false
        }
        guard finalized || pristine || terminal else {
            throw MailboxQAHarnessError.invalidState
        }
        try MailboxLocatorV1.revalidate(locator)
        if FileManager.default.fileExists(atPath: locator.deviceRoot.path) {
            try FileManager.default.removeItem(at: locator.deviceRoot)
        }
    }

    private func ensureSyntheticItem() throws -> FileOutboxItem {
        if let itemID = state.itemID,
           let existing = try outbox.pendingItem(id: itemID) {
            guard try Data(contentsOf: existing.fileURL)
                == MailboxQASyntheticPayload.exactBytes
            else {
                throw MailboxQAHarnessError.invalidState
            }
            return existing
        }
        let result = try outbox.enqueueIfAbsent(
            MailboxQASyntheticPayload.exactBytes,
            receiverIdentity: pairing.receiverBindingID
        )
        state.itemID = result.item.id
        return result.item
    }

    private func observe(_ phase: OutboxDeliveryPhase) throws {
        if state.lastPhase != phase {
            state.transitions.observe(phase)
            state.lastPhase = phase
        }
    }

    private func persist() throws {
        var existing = stat()
        if lstat(stateURL.path, &existing) == 0 {
            guard (existing.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  existing.st_nlink == 1 else {
                throw MailboxQAHarnessError.invalidState
            }
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let data = try canonicalJSON(state)
        let temporary = stateURL.deletingLastPathComponent().appendingPathComponent(
            ".qa-durable-state-v1.\(UUID().uuidString).tmp"
        )
        var descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var keepTemporary = true
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            if keepTemporary { _ = unlink(temporary.path) }
        }

        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    data.count - offset
                )
            }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            offset += written
        }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.close(descriptor) == 0 else {
            descriptor = -1
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        descriptor = -1
        guard rename(temporary.path, stateURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        keepTemporary = false

        let directory = open(stateURL.deletingLastPathComponent().path, O_RDONLY)
        guard directory >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(directory) }
        if fsync(directory) != 0, errno != EINVAL, errno != ENOTSUP {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func randomID() -> Data {
        var value = UUID().uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
