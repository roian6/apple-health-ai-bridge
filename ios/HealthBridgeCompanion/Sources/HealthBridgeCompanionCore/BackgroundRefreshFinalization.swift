import Foundation

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
