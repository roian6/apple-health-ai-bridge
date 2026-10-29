import Foundation
import HealthKit
import XCTest
@testable import HealthBridgeCompanion

final class NutritionReceiver: @unchecked Sendable {
    enum Capability { case legacy, supported, unsupported, malformed, offline }
    private let lock = NSLock()
    private var capabilityValue = Capability.supported
    private var statusValue = 202
    private var batchesValue: [HealthBridgeBatchV1] = []
    private var recordsValue: [String: HealthBridgeSample] = [:]
    private var workoutsValue: [String: HealthBridgeWorkout] = [:]
    private var credentialsValue: [String] = []
    var capability: Capability {
        get { lock.withLock { capabilityValue } }
        set { lock.withLock { capabilityValue = newValue } }
    }
    var status: Int {
        get { lock.withLock { statusValue } }
        set { lock.withLock { statusValue = newValue } }
    }
    var batches: [HealthBridgeBatchV1] { lock.withLock { batchesValue } }
    var records: [HealthBridgeSample] { lock.withLock { Array(recordsValue.values) } }
    var workouts: [HealthBridgeWorkout] { lock.withLock { Array(workoutsValue.values) } }
    var credentials: [String] { lock.withLock { credentialsValue } }

    func respond(_ request: URLRequest, body: Data?) throws -> (Int, Data) {
        try lock.withLock {
            if capabilityValue == .offline { throw URLError(.notConnectedToInternet) }
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
            let receiver = try XCTUnwrap(Self.receiver)
            let (status, data) = try receiver.respond(request, body: body)
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
    private var ids: [String: UUID] = [:]

    init(directPairing: Bool = true) throws {
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
        outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
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
        eligibleTypeCodes: [String]? = nil,
        readDailyActivityAggregates: (@MainActor (
            [String], Date, Date, Calendar
        ) async throws -> [HealthKitDailyActivityAggregate])? = nil
    ) async throws -> HealthBridgeCompanionViewModel {
        let vm = HealthBridgeCompanionViewModel(
            receiverClient: client, settingsStore: settings,
            pairingStateStore: ReceiverPairingStateStore(
                pendingStore: NutritionTokenStore(), installationIDStore: NutritionTokenStore(),
                cancellationStore: NutritionTokenStore()
            ),
            backgroundSyncStore: BackgroundSyncSettingsStore(userDefaults: defaults),
            automaticSyncDiagnosticStore: AutomaticSyncDiagnosticStore(fileURL: root.appendingPathComponent("diagnostics.json")),
            healthPermissionRequestStore: CompanionHealthPermissionRequestStore(userDefaults: defaults),
            healthHistoryDepthStore: HealthHistoryDepthSelectionStore(userDefaults: defaults),
            historicalBackfillStateStore: HealthHistoricalBackfillStateStore(userDefaults: defaults),
            quantityObservationStore: QuantityObservationStore(userDefaults: defaults),
            coreLaneUploadProofStore: CoreLaneUploadProofStore(userDefaults: defaults),
            outbox: outbox, outboxDirectoryURL: outbox.directoryURL,
            cursorStore: cursors, cursorStoreFileURL: cursors.fileURL,
            sleepManifestStore: try FileSleepSyncManifestStore(fileURL: root.appendingPathComponent("sleep.json")),
            sleepManifestFileURL: root.appendingPathComponent("sleep.json"),
            sleepResetEpochStore: SleepResetEpochStore(tokenStore: NutritionTokenStore(), epochFloorProvider: { 1 }),
            mailboxKeyStore: mailbox?.keys ?? MailboxKeyStore(service: suite, keychain: NutritionKeychain()),
            automaticSyncEligibleTypeCodesForTesting: eligibleTypeCodes,
            readDailyActivityAggregates: readDailyActivityAggregates ?? { _, _, _, _ in [] },
            scheduleDirectBackgroundUploads: { 0 },
            cancelInheritedLegacyUploads: {
                BackgroundUploadCancellationResult(cancelledCount: 0, fullyFinalized: true)
            },
            platformBackgroundPayloadDrain: { true },
            productionMailboxDelivery: mailbox.map { fixture in
                { @MainActor @Sendable in fixture.delivery() }
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
            requestProjectionReadAuthorization: { _ in }
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
