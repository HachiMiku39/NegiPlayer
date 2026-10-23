import Foundation

public struct SensMeBatchInput: Sendable {
    public let id: String
    public let source: URL
    public let cached: CachedSensMe?
    public init(id: String, source: URL, cached: CachedSensMe? = nil) {
        self.id = id; self.source = source; self.cached = cached
    }
}

public struct SensMeBatchOutcome: Sendable {
    public enum Value: Sendable {
        case analyzed(CachedSensMe), cached(CachedSensMe), failed(String)
    }
    public let id: String
    public let source: URL
    public let value: Value
}

public struct SensMeBatchSummary: Sendable {
    public var analyzed = 0, cached = 0, failed = 0
    public var completed: Int { analyzed + cached + failed }
    public init() {}
}

public enum SensMeBatchAnalyzer {
    public static let defaultWorkers = 8

    /// The callback checkpoints each outcome before its task completes. A
    /// persistence error stops scheduling; a track analysis error does not.
    public static func run(_ inputs: [SensMeBatchInput], workers: Int = defaultWorkers,
                           analyze: @escaping @Sendable (URL) throws -> CachedSensMe = { try SensMeEngine.analyze(source: $0) },
                           checkpoint: @escaping @Sendable (SensMeBatchOutcome) async throws -> Void) async throws -> SensMeBatchSummary {
        guard (1...16).contains(workers), Set(inputs.map(\.id)).count == inputs.count else {
            throw EnrichmentError("SensMe 任务配置无效")
        }
        return try await withThrowingTaskGroup(of: SensMeBatchOutcome.self) { group in
            var next = 0, summary = SensMeBatchSummary()
            for _ in 0..<min(workers, inputs.count) {
                let input = inputs[next]; next += 1
                group.addTask(priority: .utility) { try await one(input, analyze: analyze, checkpoint: checkpoint) }
            }
            while let outcome = try await group.next() {
                switch outcome.value {
                case .analyzed: summary.analyzed += 1
                case .cached: summary.cached += 1
                case .failed: summary.failed += 1
                }
                try Task.checkCancellation()
                if next < inputs.count {
                    let input = inputs[next]; next += 1
                    group.addTask(priority: .utility) { try await one(input, analyze: analyze, checkpoint: checkpoint) }
                }
            }
            return summary
        }
    }

    private static func one(_ input: SensMeBatchInput,
                            analyze: @Sendable (URL) throws -> CachedSensMe,
                            checkpoint: @Sendable (SensMeBatchOutcome) async throws -> Void) async throws -> SensMeBatchOutcome {
        try Task.checkCancellation()
        let value: SensMeBatchOutcome.Value
        do {
            if let cached = input.cached, cached.engineVersion == SensMeEngine.version,
               cached.hasValidBlobChecksum,
               try SourceDigest.sha256(input.source) == cached.sourceSHA256 {
                value = .cached(cached)
            } else {
                value = .analyzed(try analyze(input.source))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            value = .failed(error.localizedDescription)
        }
        let outcome = SensMeBatchOutcome(id: input.id, source: input.source, value: value)
        try await checkpoint(outcome)
        return outcome
    }
}
