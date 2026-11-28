import Foundation
import HealthKit
import XCTest
@testable import HealthBridgeCompanion

final class NutritionReceiver: @unchecked Sendable {
    enum Capability { case legacy, supported, unsupported, malformed, offline }
    private let lock = NSLock()
    private var capabilityValue = Capability.supported
    private var statusValue = 202
    private var rejectedCursorKindValue: String?
    private var requestSizesValue: [Int] = []
    private var batchesValue: [HealthBridgeBatchV1] = []
    private var recordsValue: [String: HealthBridgeSample] = [:]
    private var workoutsValue: [String: HealthBridgeWorkout] = [:]
    private var credentialsValue: [String] = []
    private var httpRequestsValue = 0
    private var responseProbeValue: NutritionCodecProbe?
    var responseProbe: NutritionCodecProbe? {
        get { lock.withLock { responseProbeValue } }
        set { lock.withLock { responseProbeValue = newValue } }
    }
    var capability: Capability {
        get { lock.withLock { capabilityValue } }
        set { lock.withLock { capabilityValue = newValue } }
    }
    var status: Int {
        get { lock.withLock { statusValue } }
        set { lock.withLock { statusValue = newValue } }
    }
    var batches: [HealthBridgeBatchV1] { lock.withLock { batchesValue } }
    var requestSizes: [Int] { lock.withLock { requestSizesValue } }
    var rejectedCursorKind: String? {
        get { lock.withLock { rejectedCursorKindValue } }
        set { lock.withLock { rejectedCursorKindValue = newValue } }
    }
    var records: [HealthBridgeSample] { lock.withLock { Array(recordsValue.values) } }
    var workouts: [HealthBridgeWorkout] { lock.withLock { Array(workoutsValue.values) } }
    var credentials: [String] { lock.withLock { credentialsValue } }
    var httpRequests: Int { lock.withLock { httpRequestsValue } }

    func recordHTTPRequest() { lock.withLock { httpRequestsValue += 1 } }

    func respond(_ request: URLRequest, body: Data?) throws -> (Int, Data) {
        try lock.withLock {
            if capabilityValue == .offline { throw URLError(.notConnectedToInternet) }
            if request.url?.path == "/v1/pairing/redeem" {
                return (200, Data("""
                {"schema_id":"health_bridge.receiver_pairing_completion.v1",
                 "schema_version":"1.0.0","label":"Synthetic receiver",
                 "receiver_url":"http://127.0.0.1:8766/v1/batches"}
                """.utf8))
            }
            if request.url?.path == "/v1/capabilities" {
                credentialsValue.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
                switch capabilityValue {
                case .legacy: return (404, Data())
                case .malformed: return (200, Data(#"{"nutrition_supported":"true"}"#.utf8))
                case .supported, .unsupported:
                    let value = capabilityValue == .supported ? "true" : "false"
                    return (200, Data("""
                    {"schema_id":"health_bridge.receiver_capabilities.v1",
                     "batch_schema_id":"health_bridge.batch.v1","nutrition_supported":\(value)}
                    """.utf8))
                case .offline: throw URLError(.notConnectedToInternet)
                }
            }
            guard let body else { return (200, Data(#"{"status":"ok"}"#.utf8)) }
            let batch = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: body)
            batchesValue.append(batch)
            requestSizesValue.append(body.count)
            if let rejectedCursorKindValue,
               batch.sync.cursors.contains(where: { $0.cursorKind == rejectedCursorKindValue }) {
                return (503, Data())
            }
            if capabilityValue != .supported && NutritionCompatibility.containsNutrition(batch) {
                return (422, Data())
            }
            if statusValue == 202 {
                for sample in batch.samples { recordsValue[sample.clientRecordID] = sample }
                for workout in batch.workouts {
                    workoutsValue[workout.sourceKey + "\n" + workout.clientRecordID] = workout
                }
            }
            return (statusValue, Data(#"{"status":"accepted"}"#.utf8))
        }
    }
}

final class NutritionURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var receiver: NutritionReceiver?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let receiver = try XCTUnwrap(Self.receiver)
            receiver.recordHTTPRequest()
            var body = request.httpBody
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var bytes = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    guard count >= 0 else { throw URLError(.cannotDecodeContentData) }
                    if count == 0 { break }
                    data.append(contentsOf: bytes.prefix(count))
                }
                body = data
            }
            let (status, data) = try receiver.respond(request, body: body)
            if body != nil { receiver.responseProbe?.record() }
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json", "Cache-Control": "no-store"]
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class NutritionFixture {
    let root: URL
    let suite = "NutritionCompatibility.\(UUID().uuidString)"
    let defaults: UserDefaults
    let tokenStore = NutritionTokenStore()
    let settings: ReceiverSettingsStore
    let outbox: FileOutbox
    let cursors: FileSyncCursorStore
    let receiver = NutritionReceiver()
    let session: URLSession
    let client: ReceiverClient
    let anchor: String
    var values: [String: Double] = ["weight": 70, "dietary_protein": 12]
    var reads: [String] = []
    var acceptedTransferResetEpochURL: URL {
        root.appendingPathComponent("accepted-transfer").appendingPathComponent("reset-epoch")
    }
    lazy var acceptedTransferStore = LastAcceptedTransferObservationStore(
        userDefaults: defaults, resetEpochURL: acceptedTransferResetEpochURL
    )
    private var ids: [String: UUID] = [:]

    init(directPairing: Bool = true, outboxFileManager: FileManager = .default) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        settings = ReceiverSettingsStore(
            userDefaults: defaults, tokenStore: tokenStore,
            preCutoverBackupStore: NutritionTokenStore(), synchronize: { true }
        )
        if directPairing {
            try settings.save(receiverURLString: "http://127.0.0.1:8765/v1/batches",
                              bearerToken: "synthetic-nutrition")
        }
        outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"), fileManager: outboxFileManager)
        cursors = try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json"))
        anchor = try HealthKitAnchorCursorCodec.encode(HKQueryAnchor(fromValue: 42))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NutritionURLProtocol.self]
        session = URLSession(configuration: configuration)
        client = ReceiverClient(session: session)
        NutritionURLProtocol.receiver = receiver
    }

    func makeViewModel(
        mailbox: NutritionMailboxFixture? = nil,
        backgroundSyncStore: BackgroundSyncSettingsStore? = nil,
        eligibleTypeCodes: [String]? = nil,
        readDailyActivityAggregates: (@MainActor (
            [String], Date, Date, Calendar
        ) async throws -> [HealthKitDailyActivityAggregate])? = nil,
        readAnchoredStepChanges: (@MainActor (
            String?, Date?, Date
        ) async throws -> HealthKitAnchoredStepChanges)? = nil,
        readAnchoredWorkoutChanges: (@MainActor (
            String?, Date?, Date
        ) async throws -> HealthKitAnchoredWorkoutChanges)? = nil,
        readWorkoutHistory: (@MainActor (Date, Date) async throws -> [HealthKitWorkoutSummary])? = nil,
        readAnchoredSleepChanges: (@MainActor (
            String?, Date?, Date
        ) async throws -> HealthKitAnchoredSleepChanges)? = nil,
        requestReadAuthorization: @escaping @MainActor ([String]) async throws -> Void = { _ in },
        terminalBackgroundPayloadDrain: (@MainActor () async -> Bool)? = nil,
        reopenStorage: Bool = false,
        outboxFileManager: FileManager = .default
    ) async throws -> HealthBridgeCompanionViewModel {
        let deliveryOutbox = reopenStorage
            ? try FileOutbox(directory: outbox.directoryURL, fileManager: outboxFileManager) : outbox
        let deliveryCursors = reopenStorage ? try FileSyncCursorStore(fileURL: cursors.fileURL) : cursors
        let sleepStore = try FileSleepSyncManifestStore(fileURL: root.appendingPathComponent("sleep.json"))
        let mailboxSleepStore = readAnchoredSleepChanges == nil ? nil : sleepStore
        let backgroundSyncStore = backgroundSyncStore ?? BackgroundSyncSettingsStore(userDefaults: defaults)
        let vm = HealthBridgeCompanionViewModel(
            receiverClient: client, settingsStore: settings,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: NutritionTokenStore(), installationIDStore: NutritionTokenStore(),
                cancellationStore: NutritionTokenStore()
            ),
            backgroundSyncStore: backgroundSyncStore,
            automaticSyncDiagnosticStore: AutomaticSyncDiagnosticStore(fileURL: root.appendingPathComponent("diagnostics.json")),
            healthPermissionRequestStore: CompanionHealthPermissionRequestStore(userDefaults: defaults),
            healthHistoryDepthStore: HealthHistoryDepthSelectionStore(userDefaults: defaults),
            historicalBackfillStateStore: HealthHistoricalBackfillStateStore(userDefaults: defaults),
            quantityObservationStore: QuantityObservationStore(userDefaults: defaults),
            coreLaneUploadProofStore: CoreLaneUploadProofStore(userDefaults: defaults),
            acceptedTransferStore: acceptedTransferStore,
            outbox: deliveryOutbox, outboxDirectoryURL: outbox.directoryURL,
            cursorStore: deliveryCursors, cursorStoreFileURL: cursors.fileURL,
            sleepManifestStore: sleepStore,
            sleepManifestFileURL: root.appendingPathComponent("sleep.json"),
            sleepResetEpochStore: SleepResetEpochStore(tokenStore: NutritionTokenStore(), epochFloorProvider: { 1 }),
            mailboxKeyStore: mailbox?.keys ?? MailboxKeyStore(service: suite, keychain: NutritionKeychain()),
            readAnchoredSleepChanges: readAnchoredSleepChanges,
            readAnchoredStepChanges: readAnchoredStepChanges,
            readAnchoredWorkoutChanges: readAnchoredWorkoutChanges,
            readWorkoutHistory: readWorkoutHistory,
            automaticSyncEligibleTypeCodesForTesting: eligibleTypeCodes,
            readDailyActivityAggregates: readDailyActivityAggregates ?? { _, _, _, _ in [] },
            scheduleDirectBackgroundUploads: { 0 },
            cancelInheritedLegacyUploads: {
                BackgroundUploadCancellationResult(cancelledCount: 0, fullyFinalized: true)
            },
            terminalBackgroundPayloadDrain: terminalBackgroundPayloadDrain,
            platformBackgroundPayloadDrain: { true },
            productionMailboxDelivery: mailbox.map { fixture in
                { @MainActor in
                    fixture.delivery(outbox: deliveryOutbox, cursorStore: deliveryCursors,
                                     pendingGenerationStore: backgroundSyncStore, sleepStore: mailboxSleepStore)
                }
            },
            readAnchoredQuantityChanges: { [self] type, previous, start, now in
                reads.append(type)
                if ids[type] == nil { ids[type] = UUID() }
                let samples: [HealthKitQuantitySampleSummary]
                if let value = values[type], previous != anchor {
                    samples = [HealthKitQuantitySampleSummary(
                        uuid: try XCTUnwrap(ids[type]), typeCode: type,
                        start: Date(timeIntervalSince1970: 1_790_000_000),
                        end: Date(timeIntervalSince1970: 1_790_000_060), value: value
                    )]
                } else { samples = [] }
                return HealthKitAnchoredQuantityChanges(
                    typeCode: type, samples: samples, deletedSamples: [], anchorCursorValue: anchor,
                    windowStart: start ?? now, windowEnd: now
                )
            },
            requestProjectionReadAuthorization: requestReadAuthorization
        )
        await vm.bootstrap()
        return vm
    }

    func cursor(_ type: String) throws -> String? {
        try cursors.cursorValue(
            receiverBindingID: XCTUnwrap(settings.receiverBindingID),
            sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: GenericQuantitySyncBatchFactory.anchoredCursorKind(for: type)
        )
    }

    func mixedBatch(workoutEnergy: Double? = nil) throws -> HealthBridgeBatchV1 {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let batches = try ["weight", "dietary_protein"].map { type in
            if ids[type] == nil { ids[type] = UUID() }
            return try XCTUnwrap(GenericQuantitySyncBatchFactory.makeAnchoredQuantityBatches(
                changes: HealthKitAnchoredQuantityChanges(
                    typeCode: type,
                    samples: [HealthKitQuantitySampleSummary(
                        uuid: try XCTUnwrap(ids[type]), typeCode: type, start: now,
                        end: now.addingTimeInterval(60), value: values[type] ?? 12
                    )],
                    deletedSamples: [], anchorCursorValue: anchor, windowStart: now, windowEnd: now
                ), generatedAt: now
            ).first)
        }
        let first = batches[0]
        return HealthBridgeBatchV1(
            generatedAt: first.generatedAt, exportWindow: first.exportWindow, sources: first.sources,
            healthTypes: batches.flatMap(\.healthTypes), samples: batches.flatMap(\.samples),
            workouts: workoutEnergy.map { energy in
                [HealthBridgeWorkout(
                    clientRecordID: "synthetic-workout", sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
                    workoutType: "running", startTime: first.exportWindow.startTime,
                    endTime: first.exportWindow.endTime, durationSeconds: 0, energyKcal: energy
                )]
            } ?? [], sleepSessions: [], deletedRecords: [],
            sync: HealthBridgeSyncContext(syncWindow: first.sync.syncWindow, cursors: batches.flatMap(\.sync.cursors))
        )
    }

    func enqueueMixed(workoutEnergy: Double? = nil) throws -> FileOutboxItem {
        let identity = try XCTUnwrap(settings.receiverBindingID)
        return try XCTUnwrap(outbox.enqueueSequence(
            [JSONEncoder().encode(mixedBatch(workoutEnergy: workoutEnergy))], receiverIdentity: identity,
            cursorCheckpoint: FileOutboxCursorCheckpoint(
                receiverIdentity: identity, sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
                cursorKind: GenericQuantitySyncBatchFactory.anchoredCursorKind(for: "dietary_protein"),
                cursorValue: anchor
            )
        ).first)
    }

    func cleanup() {
        session.invalidateAndCancel()
        NutritionURLProtocol.receiver = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
