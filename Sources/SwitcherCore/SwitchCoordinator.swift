import Foundation

public enum SwitchStage: String, Codable {
    case validating, requestingQuit, waitingForExit, committing, launching, awaitingConfirmation

    public var label: String {
        switch self {
        case .validating: return "检查目标账号"
        case .requestingQuit: return "请求退出 Codex"
        case .waitingForExit: return "等待 Codex 完全退出"
        case .committing: return "保存并切换登录凭据"
        case .launching: return "重新打开 Codex"
        case .awaitingConfirmation: return "等待核对实际账号"
        }
    }
}

public enum SwitchAttemptOutcome: String, Codable {
    case running, awaitingConfirmation, unchanged, failed, cancelled
}

/// Diagnostic evidence only. Never contains credentials, identity, account aliases or dependency errors.
/// It does not authorize recovery or replace the Engine's transaction journal.
public struct SwitchAttempt: Codable {
    public var schema = 1
    public var stage: SwitchStage
    public var outcome: SwitchAttemptOutcome
    public var credentialMayHaveChanged: Bool
    public var errorCode: String?
    public var updatedAt: Date
}

/// Serial orchestration on the app's worker queue. All effects are explicit callbacks.
/// The coordinator never kills a process, retries a switch, or rolls back credentials.
public final class SwitchCoordinator {
    private let statusURL: URL
    private let storageLock: ProcessLock
    private let runLock = NSLock()

    public init(root: URL) throws {
        try SecureIO.prepareDirectory(root)
        statusURL = root.appendingPathComponent("switch-attempt.json")
        storageLock = ProcessLock(root: root)
    }

    public func latestAttempt() throws -> SwitchAttempt? {
        try storageLock.withLock {
            guard FileManager.default.fileExists(atPath: statusURL.path) else { return nil }
            let result = try JSONDecoder().decode(SwitchAttempt.self, from: SecureIO.read(statusURL))
            guard result.schema == 1 else { throw SwitcherError.io }
            return result
        }
    }

    private func save(_ attempt: SwitchAttempt) throws {
        try storageLock.withLock {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try SecureIO.write(encoder.encode(attempt), to: statusURL)
        }
    }

    @discardableResult
    public func run(cancellation: Cancellation,
                    validateTarget: () throws -> Void,
                    requestQuit: () throws -> Void,
                    waitForStopped: () throws -> Void,
                    commit: () throws -> Bool,
                    launch: () throws -> Void,
                    noteLaunched: () throws -> Void,
                    progress: (SwitchAttempt) -> Void = { _ in }) throws -> SwitchAttempt {
        guard runLock.try() else { throw SwitcherError.busy }
        defer { runLock.unlock() }

        var attempt = SwitchAttempt(stage: .validating, outcome: .running,
                                    credentialMayHaveChanged: false, updatedAt: Date())
        func checkCancellation() throws {
            if cancellation.isCancelled { throw SwitcherError.cancelled }
        }
        func enter(_ stage: SwitchStage) throws {
            try checkCancellation()
            attempt.stage = stage
            attempt.updatedAt = Date()
            try save(attempt)
            progress(attempt)
            try checkCancellation()
        }

        do {
            try enter(.validating)
            try validateTarget()
            try enter(.requestingQuit)
            try requestQuit()
            try enter(.waitingForExit)
            try waitForStopped()
            try enter(.committing)
            // Record uncertainty before calling the transaction engine, including a crash inside it.
            attempt.credentialMayHaveChanged = true
            attempt.updatedAt = Date()
            try save(attempt)
            try checkCancellation()
            let pending = try commit()
            if !pending {
                attempt.credentialMayHaveChanged = false
                attempt.outcome = .unchanged
                attempt.updatedAt = Date()
                try save(attempt)
                progress(attempt)
                return attempt
            }
            try enter(.launching)
            try launch()
            try checkCancellation()
            try noteLaunched()
            attempt.stage = .awaitingConfirmation
            attempt.outcome = .awaitingConfirmation
            attempt.updatedAt = Date()
            try save(attempt)
            progress(attempt)
            return attempt
        } catch {
            let safeError = error as? SwitcherError ?? .io
            attempt.outcome = safeError == .cancelled ? .cancelled : .failed
            attempt.errorCode = safeError.rawValue
            attempt.updatedAt = Date()
            // An audit-write failure must never discard the Engine's recovery journal or replace
            // the actual error. The last durable stage still describes the interrupted attempt.
            try? save(attempt)
            progress(attempt)
            throw safeError
        }
    }
}
