import XCTest
@testable import SwitcherCore

final class SwitchCoordinatorTests: XCTestCase {
    private var root: URL!
    private var coordinator: SwitchCoordinator!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("switch-coordinator-tests-" + UUID().uuidString)
        coordinator = try SwitchCoordinator(root: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func run(token: Cancellation = Cancellation(),
                     validate: () throws -> Void = {}, quit: () throws -> Void = {},
                     wait: () throws -> Void = {}, commit: () throws -> Bool = { true },
                     launch: () throws -> Void = {}, note: () throws -> Void = {},
                     progress: (SwitchAttempt) -> Void = { _ in }) throws -> SwitchAttempt {
        try coordinator.run(cancellation: token, validateTarget: validate, requestQuit: quit,
                            waitForStopped: wait, commit: commit, launch: launch,
                            noteLaunched: note, progress: progress)
    }

    func testExpiredTargetNeverQuitsOrWrites() throws {
        XCTAssertThrowsError(try run(validate: { throw SwitcherError.expired },
                                    quit: { XCTFail("Invalid target must not quit Codex") },
                                    commit: { XCTFail("Invalid target must not write credentials"); return true })) {
            XCTAssertEqual($0 as? SwitcherError, .expired)
        }
        let status = try XCTUnwrap(coordinator.latestAttempt())
        XCTAssertEqual(status.stage, .validating)
        XCTAssertEqual(status.outcome, .failed)
        XCTAssertFalse(status.credentialMayHaveChanged)
    }

    func testQuitDenialNeverWritesOrLaunches() throws {
        XCTAssertThrowsError(try run(quit: { throw SwitcherError.writersRunning },
                                    commit: { XCTFail("Must not commit after quit denial"); return true },
                                    launch: { XCTFail("Must not launch after quit denial") }))
        let status = try XCTUnwrap(coordinator.latestAttempt())
        XCTAssertEqual(status.stage, .requestingQuit)
        XCTAssertEqual(status.errorCode, SwitcherError.writersRunning.rawValue)
        XCTAssertFalse(status.credentialMayHaveChanged)
    }

    func testRemainingWritersBlockCommit() throws {
        XCTAssertThrowsError(try run(wait: { throw SwitcherError.writersRunning },
                                    commit: { XCTFail("Remaining writers must block commit"); return true }))
        XCTAssertEqual(try coordinator.latestAttempt()?.stage, .waitingForExit)
    }

    func testSuccessfulLaunchRemainsPendingUntilDesktopConfirmation() throws {
        var calls: [String] = []
        let status = try run(validate: { calls.append("validate") }, quit: { calls.append("quit") },
                             wait: { calls.append("wait") }, commit: { calls.append("commit"); return true },
                             launch: { calls.append("launch") }, note: { calls.append("note") })
        XCTAssertEqual(calls, ["validate", "quit", "wait", "commit", "launch", "note"])
        XCTAssertEqual(status.outcome, .awaitingConfirmation)
        XCTAssertEqual(status.stage, .awaitingConfirmation)
        XCTAssertTrue(status.credentialMayHaveChanged)
        XCTAssertEqual(try coordinator.latestAttempt()?.outcome, .awaitingConfirmation)
    }

    func testLaunchFailureKeepsCommittedStateAndDoesNotMarkLaunched() throws {
        var committed = false
        XCTAssertThrowsError(try run(commit: { committed = true; return true },
                                    launch: { throw SwitcherError.timeout },
                                    note: { XCTFail("Launch was not confirmed") }))
        let status = try XCTUnwrap(coordinator.latestAttempt())
        XCTAssertTrue(committed)
        XCTAssertTrue(status.credentialMayHaveChanged)
        XCTAssertEqual(status.stage, .launching)
        XCTAssertEqual(status.outcome, .failed)
    }

    func testUncertainCommitFailureIsRecordedWithoutRetryOrRollback() throws {
        var commits = 0
        XCTAssertThrowsError(try run(commit: { commits += 1; throw SwitcherError.uncertainWrite },
                                    launch: { XCTFail("Ambiguous commit cannot launch") }))
        let status = try XCTUnwrap(coordinator.latestAttempt())
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(status.stage, .committing)
        XCTAssertTrue(status.credentialMayHaveChanged)
        XCTAssertEqual(status.errorCode, SwitcherError.uncertainWrite.rawValue)
    }

    func testCancellationBeforeCommitHasNoCredentialEffects() throws {
        let token = Cancellation()
        XCTAssertThrowsError(try run(token: token, wait: { token.cancel() },
                                    commit: { XCTFail("Cancelled before commit"); return true })) {
            XCTAssertEqual($0 as? SwitcherError, .cancelled)
        }
        XCTAssertFalse(try XCTUnwrap(coordinator.latestAttempt()).credentialMayHaveChanged)
        XCTAssertEqual(try coordinator.latestAttempt()?.outcome, .cancelled)
    }

    func testCancellationAfterCommitPreservesPendingRecoveryAndSkipsLaunch() throws {
        let token = Cancellation()
        var pending = false
        XCTAssertThrowsError(try run(token: token, commit: { pending = true; token.cancel(); return true },
                                    launch: { XCTFail("Cancelled after commit") }))
        let status = try XCTUnwrap(coordinator.latestAttempt())
        XCTAssertTrue(pending)
        XCTAssertTrue(status.credentialMayHaveChanged)
        XCTAssertEqual(status.outcome, .cancelled)
    }

    func testCancellationFromProgressStopsBeforeTheNextAction() throws {
        let token = Cancellation()
        XCTAssertThrowsError(try run(token: token, quit: { XCTFail("Cancelled by progress observer") },
                                    progress: { if $0.stage == .requestingQuit { token.cancel() } }))
        XCTAssertEqual(try coordinator.latestAttempt()?.outcome, .cancelled)
    }

    func testNoOpDoesNotClaimDesktopSwitched() throws {
        let status = try run(commit: { false }, launch: { XCTFail("Already current must not relaunch") },
                             note: { XCTFail("No pending transaction") })
        XCTAssertEqual(status.outcome, .unchanged)
        XCTAssertFalse(status.credentialMayHaveChanged)
    }

    func testCallbacksDoNotHoldEngineLockAndDiagnosticsContainNoRawError() throws {
        struct PrivateError: Error, CustomStringConvertible { var description = "PRIVATE_ACCOUNT_TOKEN_EMAIL" }
        XCTAssertThrowsError(try run(validate: {
            try ProcessLock(root: self.root).withLock { }
            throw PrivateError()
        })) { XCTAssertEqual($0 as? SwitcherError, .io) }
        let data = try SecureIO.read(root.appendingPathComponent("switch-attempt.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schema", "stage", "outcome", "credentialMayHaveChanged", "errorCode", "updatedAt"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE_ACCOUNT_TOKEN_EMAIL"))
        let restored = try SwitchCoordinator(root: root)
        XCTAssertEqual(try restored.latestAttempt()?.errorCode, SwitcherError.io.rawValue)
    }
}
