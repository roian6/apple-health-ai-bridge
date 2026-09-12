import Foundation

public final class BoundedAsyncValueLatch<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Value?, Never>] = []
    private var result: Value?
    private var isResolved = false

    public init() {}

    public func resolve(_ value: sending Value) {
        finish(with: value)
    }

    public func wait(timeout: TimeInterval) async -> Value? {
        let boundedTimeout = timeout.isFinite
            ? min(max(timeout, 0), 86_400)
            : 86_400
        return await withTaskCancellationHandler {
            if Task.isCancelled {
                finish(with: nil)
            }
            return await withCheckedContinuation { continuation in
                install(continuation)
                if boundedTimeout == 0 {
                    finish(with: nil)
                } else {
                    let nanoseconds = UInt64(boundedTimeout * 1_000_000_000)
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: nanoseconds)
                        self?.finish(with: nil)
                    }
                }
            }
        } onCancel: {
            self.finish(with: nil)
        }
    }

    private func install(_ continuation: CheckedContinuation<Value?, Never>) {
        lock.lock()
        if isResolved {
            let result = result
            lock.unlock()
            continuation.resume(returning: result)
            return
        }
        waiters.append(continuation)
        lock.unlock()
    }

    private func finish(with value: sending Value?) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        result = value
        let continuations = waiters
        waiters.removeAll()
        lock.unlock()
        continuations.forEach { $0.resume(returning: value) }
    }
}

@MainActor
public final class BackgroundRefreshFinalizationOwner {
    public private(set) var remainingGenerations: [String: Int] = [:]
    private var admitted = false
    private var finalized = false

    public init() {}

    public func admit(_ generations: [String: Int]) {
        admitted = true
        remainingGenerations = generations
    }

    public func complete(_ typeCodes: [String]) {
        for typeCode in typeCodes { remainingGenerations.removeValue(forKey: typeCode) }
    }

    public func takeAdmission() -> Bool {
        defer { admitted = false }
        return admitted
    }

    public func run(
        work: () async -> Void,
        finalize: () async -> Void
    ) async {
        guard !finalized else { return }
        // Claim before the first suspension so reentrant calls cannot run twice.
        finalized = true
        await work()
        // Cleanup runs in the cancelled task, not a detached payload task. Awaiting
        // it is mandatory: expiration must never bypass retention or resubmission.
        await finalize()
    }
}

public enum BackgroundRefreshFinalizationPolicy {
    public static func shouldScheduleNextRefresh(
        enabled: Bool, ready: Bool, admissionOpen: Bool,
        capturedGeneration: String, currentGeneration: String
    ) -> Bool {
        enabled && ready && admissionOpen && capturedGeneration == currentGeneration
    }
}

@MainActor
public final class BackgroundRefreshRequestCoalescer {
    private var submittedGeneration: String?

    public init() {}
    public func requestWasConsumed() { submittedGeneration = nil }
    public func invalidate() { submittedGeneration = nil }

    public func submitIfNeeded(generation: String, submit: () throws -> Void) throws {
        guard submittedGeneration != generation else { return }
        try submit()
        // Failed submissions remain eligible at the next external opportunity;
        // there is no retry loop and a pending request is never pushed later.
        submittedGeneration = generation
    }
}
