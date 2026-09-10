import XCTest
@testable import SwitcherCore
import Darwin

final class CoreTests: XCTestCase {
    var engine: Engine!
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("switcher-tests-" + UUID().uuidString)
        engine = try Demo.make(root: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func key(_ name: String) throws -> String { try Demo.credential(name).identity.key }
    func account(_ name: String) throws -> Account { try XCTUnwrap(engine.snapshot().accounts.first { $0.id == (try? key(name)) }) }
    func switchTo(_ name: String) throws { try engine.switchAccount(key(name), policy: SwitchPolicy(version: "demo", allowCapabilityTrial: true), validateTarget: { _ in }) }
    func confirm(_ name: String) throws { try engine.confirmDesktop(targetKey: key(name), continuityObserved: true, version: "demo") }
    func writeMain(_ name: String, _ rev: Int = 1) throws { try SecureIO.write(Demo.credential(name, revision: rev).data, to: engine.authURL) }
    func expect(_ code: SwitcherError, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual($0 as? SwitcherError, code, file: file, line: line) }
    }
    func testRoundTripAndManualConfirmation() throws {
        try switchTo("B"); XCTAssertNotNil(try engine.snapshot().transaction)
        try confirm("B"); try switchTo("A"); try confirm("A")
        XCTAssertEqual(try engine.mainCredential().identity.key, try key("A")); XCTAssertNil(try engine.snapshot().transaction)
    }
    func testQ01NewVaultMustNotBeDowngradedByOldDisk() throws {
        try engine.importAuthorized(Demo.credential("A", revision: 9), expectedKey: key("A"), expectedGeneration: 1)
        try switchTo("B"); try confirm("B"); try switchTo("A")
        XCTAssertEqual(try engine.mainCredential().fingerprint, try Demo.credential("A", revision: 9).fingerprint)
        XCTAssertEqual(try account("A").generation, 2)
    }
    func testExternalRefreshCapturedBeforeSwitch() throws {
        try writeMain("A", 2); try switchTo("B"); try confirm("B"); try switchTo("A")
        XCTAssertEqual(try engine.mainCredential().fingerprint, try Demo.credential("A", revision: 2).fingerprint)
    }
    func testDivergentVaultAndDiskBlock() throws {
        try engine.importAuthorized(Demo.credential("A", revision: 2), expectedKey: key("A"), expectedGeneration: 1)
        try writeMain("A", 3)
        expect(.conflict) { try switchTo("B") }
        XCTAssertEqual(try engine.mainCredential().fingerprint, try Demo.credential("A", revision: 3).fingerprint)
    }
    func testSameAccountRepeatedReleasesLock() throws {
        let before = try SecureIO.read(engine.authURL)
        for _ in 0..<10 { try switchTo("A"); XCTAssertEqual(try engine.snapshot().accounts.count, 3) }
        XCTAssertEqual(try SecureIO.read(engine.authURL), before); XCTAssertNil(try engine.snapshot().transaction)
    }
    func testPendingBlocksSwitchAndImport() throws {
        try switchTo("B")
        expect(.pendingRecovery) { try switchTo("C") }
        expect(.pendingRecovery) { try engine.importAuthorized(Demo.credential("D")) }
        expect(.pendingRecovery) { try engine.importCurrent() }
    }
    func testRecoveryRetainsNewTargetRefresh() throws {
        try switchTo("B"); try writeMain("B", 9); try engine.recover(rollback: true)
        XCTAssertEqual(try account("B").fingerprint, try Demo.credential("B", revision: 9).fingerprint)
        XCTAssertEqual(try engine.mainCredential().identity.key, try key("A"))
    }
    func testRecoveryDoesNotOverwriteExternalC() throws {
        try switchTo("B"); try writeMain("C")
        expect(.conflict) { try engine.recover(rollback: true) }
        XCTAssertEqual(try engine.mainCredential().identity.key, try key("C")); XCTAssertNotNil(try engine.snapshot().transaction)
    }
    func testPreparedFailureCanEndWithoutReplaying() throws {
        engine.fault = { if $0 == "prepared" { throw SwitcherError.io } }
        expect(.io) { try switchTo("B") }; engine.fault = nil
        try engine.recover(rollback: true)
        XCTAssertNil(try engine.snapshot().transaction); XCTAssertEqual(try engine.mainCredential().identity.key, try key("A"))
    }
    func testUnreadablePreparedNeverClearsJournal() throws {
        engine.fault = { if $0 == "prepared" { throw SwitcherError.io } }
        expect(.io) { try switchTo("B") }; engine.fault = nil
        try SecureIO.write(Data("broken".utf8), to: engine.authURL)
        expect(.invalidAuth) { try engine.recover(rollback: true) }; XCTAssertNotNil(try engine.snapshot().transaction)
    }
    func testAuthPostRenameFailureRemainsRecoverable() throws {
        engine.fault = { if $0 == "authAfterRename" { throw SwitcherError.io } }
        expect(.uncertainWrite) { try switchTo("B") }; engine.fault = nil
        XCTAssertEqual(try engine.mainCredential().identity.key, try key("B"))
        try engine.recover(rollback: true); XCTAssertEqual(try engine.mainCredential().identity.key, try key("A"))
    }
    func testLedgerPostRenameDoesNotDeleteReferencedSecret() throws {
        engine.fault = { if $0 == "ledgerAfterRename" { throw SwitcherError.io } }
        expect(.uncertainWrite) { try engine.importAuthorized(Demo.credential("D")) }; engine.fault = nil
        XCTAssertEqual(try engine.credentialForProbe(key("D")).identity.key, try key("D"))
    }
    func testRollbackPostWriteCrashCanFinishWithNewSource() throws {
        try engine.importAuthorized(Demo.credential("A", revision: 9), expectedKey: key("A"), expectedGeneration: 1)
        try switchTo("B")
        engine.fault = { if $0 == "rollbackWritten" { throw SwitcherError.io } }
        expect(.io) { try engine.recover(rollback: true) }; engine.fault = nil
        try engine.recover(rollback: true)
        XCTAssertNil(try engine.snapshot().transaction); XCTAssertEqual(try engine.mainCredential().fingerprint, try Demo.credential("A", revision: 9).fingerprint)
    }
    func testExternalMutationAtFinalCheckPreserved() throws {
        engine.fault = { if $0 == "authBeforeRename" { try self.writeMain("C") } }
        expect(.conflict) { try switchTo("B") }
        XCTAssertEqual(try engine.mainCredential().identity.key, try key("C"))
    }
    func testTwoEnginesShareLockAcrossAllMutations() throws {
        let second = try Demo.make(root: root, seed: false)
        try ProcessLock(root: engine.root).withLock {
            expect(.busy) { try second.importCurrent() }
            expect(.busy) { try second.importAuthorized(Demo.credential("D")) }
            expect(.busy) { try second.recover(rollback: true) }
            expect(.busy) { try second.rename(key("A"), alias: "changed") }
        }
        XCTAssertEqual(try second.snapshot().accounts.count, 3)
    }
    func testGenerationCASIncludesWholeLogin() throws {
        try engine.importAuthorized(Demo.credential("B", revision: 2), expectedKey: key("B"), expectedGeneration: 1)
        expect(.conflict) { try engine.importAuthorized(Demo.credential("B", revision: 3), expectedKey: key("B"), expectedGeneration: 1) }
        XCTAssertEqual(try account("B").generation, 2)
    }
    func testDifferentWorkspacesDistinct() throws {
        let other = try Demo.credential("A", workspace: "second-workspace")
        try engine.importAuthorized(other)
        XCTAssertNotEqual(other.identity.key, try key("A")); XCTAssertEqual(try engine.snapshot().accounts.count, 4)
    }
    func testWrongLoginIdentityRejected() throws {
        expect(.identityMismatch) { try engine.importAuthorized(Demo.credential("C"), expectedKey: key("B"), expectedGeneration: 1) }
    }
    func testUnknownCredentialFieldsPreserved() throws {
        let value = try Demo.credential("A")
        XCTAssertNotNil((try JSONSerialization.jsonObject(with: value.data) as? [String: Any])?["unknown_future_field"])
        expect(.invalidAuth) { _ = try Credential(data: Data("{}".utf8)) }
    }
    func testWrongSecretIdentityRejected() throws {
        let a = try account("B")
        let fakeRoot = root.appendingPathComponent("fake-secrets")
        try SecureIO.write(Demo.credential("C").data, to: fakeRoot.appendingPathComponent(a.secret))
        expect(.identityMismatch) { try switchTo("B") }
        XCTAssertEqual(try engine.mainCredential().identity.key, try key("A"))
    }
    func testCapabilityUnknownBlocksBeforeWrite() throws {
        expect(.capabilityUnknown) { try engine.switchAccount(key("B"), policy: SwitchPolicy(version: "live"), validateTarget: { _ in XCTFail("Must not probe") }) }
        XCTAssertNil(try engine.snapshot().transaction)
    }
    func testWritersBlockAndDoNotQueue() throws {
        let e = try Engine(root: engine.root, authURL: engine.authURL, secrets: TestSecretStore(root: root.appendingPathComponent("fake-secrets")), writersStopped: { throw SwitcherError.writersRunning }, environmentAllowed: {})
        expect(.writersRunning) { try e.switchAccount(key("B"), policy: SwitchPolicy(version: "demo", allowCapabilityTrial: true), validateTarget: { _ in }) }
        XCTAssertNil(try engine.snapshot().transaction)
    }
    func testCancellationAtCommitIsSafe() throws {
        let token = Cancellation()
        engine.fault = { if $0 == "authBeforeRename" { token.cancel() } }
        expect(.cancelled) { try engine.switchAccount(key("B"), policy: SwitchPolicy(version: "demo", allowCapabilityTrial: true), cancellation: token, validateTarget: { _ in }) }
        XCTAssertEqual(try engine.mainCredential().identity.key, try key("A"))
    }
    func testConfirmWrongDesktopDoesNotCommit() throws {
        try switchTo("B"); try writeMain("C")
        expect(.identityMismatch) { try confirm("B") }; XCTAssertNotNil(try engine.snapshot().transaction)
    }
    func testExplicitExternalResolutionDoesNotRewriteAuth() throws {
        try switchTo("B"); try writeMain("C")
        let before = try SecureIO.read(engine.authURL)
        try engine.acceptExternalDesktop(expectedKey: key("C"))
        XCTAssertEqual(try SecureIO.read(engine.authURL), before)
        XCTAssertNil(try engine.snapshot().transaction)
    }
    func testExplicitForkResolutionKeepsPriorSecretGenerations() throws {
        try engine.importAuthorized(Demo.credential("A", revision: 9), expectedKey: key("A"), expectedGeneration: 1)
        try switchTo("B"); try writeMain("A", 10)
        let old = try account("A").secretHistory
        try engine.acceptExternalDesktop(expectedKey: key("A"))
        XCTAssertEqual(try account("A").fingerprint, try Demo.credential("A", revision: 10).fingerprint)
        XCTAssertTrue(try Set(account("A").secretHistory).isSuperset(of: old))
        XCTAssertNil(try engine.snapshot().transaction)
    }
    func testInterruptedSecretDeletionCanRetry() throws {
        final class DeniedRemove: SecretStore {
            let wrapped: TestSecretStore
            init(_ wrapped: TestSecretStore) { self.wrapped = wrapped }
            func get(_ reference: String) throws -> Data { try wrapped.get(reference) }
            func put(_ data: Data) throws -> String { try wrapped.put(data) }
            func remove(_ reference: String) throws { throw SwitcherError.keychain }
        }
        let ref = try account("C").secret
        let other = try Engine(root: engine.root, authURL: engine.authURL, secrets: DeniedRemove(TestSecretStore(root: root.appendingPathComponent("fake-secrets"))), writersStopped: {}, environmentAllowed: {})
        expect(.keychain) { try other.delete(key("C")) }
        XCTAssertTrue(try engine.snapshot().pendingSecretDeletes!.contains(ref))
        try engine.cleanupDeletedSecrets()
        XCTAssertTrue(try engine.snapshot().pendingSecretDeletes!.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("fake-secrets").appendingPathComponent(ref).path))
    }
    func testCurrentCannotBeDeleted() throws {
        expect(.conflict) { try engine.delete(key("A")) }; try engine.delete(key("C")); XCTAssertEqual(try engine.snapshot().accounts.count, 2)
    }
    func testQuotaWindowsAndMultiBucketPrecedence() throws {
        let q = try Quota.parse(["rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 25, "windowDurationMins": 300], "secondary": ["usedPercent": 100, "windowDurationMins": 10080]]], "rateLimits": ["primary": ["usedPercent": 99, "windowDurationMins": 1]]])
        XCTAssertEqual(q.primary?.remaining, 75); XCTAssertEqual(q.secondary?.remaining, 0); XCTAssertEqual(q.secondary?.windowDurationMins, 10080)
    }
    func testUnknownQuotaRetainsStaleCache() throws {
        for obj: [String: Any] in [[:], ["rateLimits": NSNull()], ["rateLimits": ["primary": ["usedPercent": -1, "windowDurationMins": 1]]], ["rateLimits": ["primary": ["usedPercent": 101, "windowDurationMins": 1]]]] { expect(.unknownQuota) { _ = try Quota.parse(obj) } }
        let a = try account("A"), old = a.quota?.primary
        try engine.updateQuota(a.id, fingerprint: a.fingerprint, quota: nil, error: .rateLimited)
        XCTAssertEqual(try account("A").quota?.primary, old); XCTAssertTrue(try account("A").quota!.isStale)
        XCTAssertGreaterThan(try account("A").quotaRetryAfter!.timeIntervalSinceNow, 290)
    }
    func testQuotaCASRejectsOldAccountGeneration() throws {
        let a = try account("B")
        try engine.importAuthorized(Demo.credential("B", revision: 2), expectedKey: a.id, expectedGeneration: a.generation)
        expect(.conflict) { try engine.updateQuota(a.id, fingerprint: a.fingerprint, quota: a.quota, error: nil) }
    }
    func testErrorClassificationAndNoSecretsInDiagnostics() throws {
        for (status, error) in [(401, SwitcherError.unauthorized), (403, .forbidden), (429, .rateLimited), (500, .serverError)] { XCTAssertEqual(AppServer.classify(["data": ["statusCode": status], "message": "SYNTHETIC_SECRET"]), error) }
        let text = String(data: try engine.diagnostics(), encoding: .utf8)!
        for forbidden in ["SYNTHETIC", "access_token", "refresh_token", "example.invalid", "demo-user", try account("A").secret] { XCTAssertFalse(text.contains(forbidden)) }
    }
    func testExplicitBackendConservative() {
        XCTAssertTrue(HostConfiguration.explicitFileBackend("cli_auth_credentials_store = \"file\"\n[features]\nx = true"))
        for config in ["", "cli_auth_credentials_store='keyring'", "cli_auth_credentials_store='auto'", "[a]\ncli_auth_credentials_store='file'", "cli_auth_credentials_store='file'\nprofile='other'", "cli_auth_credentials_store='file'\nforced_chatgpt_workspace_id='x'"] { XCTAssertFalse(HostConfiguration.explicitFileBackend(config)) }
    }
    func testKnownVersionDefaultFileAndExplicitOverrides() {
        XCTAssertTrue(HostConfiguration.explicitFileBackend("", defaultIsFile: true))
        XCTAssertTrue(HostConfiguration.explicitFileBackend("model = 'example'\n[features]\nx = true", defaultIsFile: true))
        for config in ["cli_auth_credentials_store = 'keyring'", "cli_auth_credentials_store = 'auto'", "cli_auth_credentials_store = 'ephemeral'", "profile='work'", "forced_chatgpt_workspace_id='x'", "chatgpt_base_url='https://example.invalid'", "[auth]\ncli_auth_credentials_store='file'", "\"cli_auth_credentials_store\"='keyring'"] {
            XCTAssertFalse(HostConfiguration.explicitFileBackend(config, defaultIsFile: true), config)
        }
    }
    func testWriterClassification() {
        for path in ["/Applications/Codex.app/Contents/MacOS/Codex", "/a/.vscode/extensions/openai/bin/codex", "/usr/local/bin/codex-daemon"] { XCTAssertTrue(HostConfiguration.isWriterExecutable(path)) }
        for path in ["/a/codex切换账号/switcherctl", "/usr/bin/python3", "/Applications/CodexAccountSwitcher.app/Contents/MacOS/CodexAccountSwitcher"] { XCTAssertFalse(HostConfiguration.isWriterExecutable(path)) }
    }
    func testOnlyExactBundledCrashReporterIsExcluded() {
        let base = "/Applications/Codex.app/Contents/Frameworks/Codex Framework.framework/Versions/152.0.7977.83/Helpers/"
        XCTAssertFalse(HostConfiguration.isWriterExecutable(base + "browser_crashpad_handler"))
        for path in [base + "codex", base + "browser_crashpad_handler-other", "/tmp/Codex.app/Contents/Helpers/browser_crashpad_handler", "/Applications/Codex.app/Contents/MacOS/ChatGPT", "/Applications/Codex.app/Contents/Resources/codex", "/Users/test/Library/Application Support/Codex/codex-browser-app/browser"] {
            XCTAssertTrue(HostConfiguration.isWriterExecutable(path), path)
        }
    }
    func testSecurePermissionsSymlinkAndForeignTemp() throws {
        let sentinel = root.appendingPathComponent("sentinel")
        try SecureIO.write(Data("do not touch".utf8), to: sentinel)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sentinel)
        expect(.unsafePath) { _ = try SecureIO.read(link) }
        expect(.unsafePath) { try SecureIO.write(Data("evil".utf8), to: link) }
        let foreign = engine.authURL.deletingLastPathComponent().appendingPathComponent(".switcher-foreign.tmp")
        try SecureIO.write(Data("foreign".utf8), to: foreign); try switchTo("B"); try engine.recover(rollback: true)
        XCTAssertEqual(try SecureIO.read(foreign), Data("foreign".utf8))
        let attrs = try FileManager.default.attributesOfItem(atPath: engine.authURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testAtomicWriteReportsCommittedUncertainty() throws {
        let path = root.appendingPathComponent("atomic")
        expect(.uncertainWrite) { try SecureIO.write(Data("complete".utf8), to: path, afterRename: { throw SwitcherError.io }) }
        XCTAssertEqual(try SecureIO.read(path), Data("complete".utf8))
    }
    func testTenSyntheticSwitchesDoNotTouchHistoryBrowserOrProjects() throws {
        let names = ["browser-fixture", "history-fixture", "project-fixture", "config-fixture"]
        var before: [String: Data] = [:]
        for name in names { let value = Data(("SYNTHETIC_BOUNDARY_" + name).utf8); before[name] = value; try SecureIO.write(value, to: root.appendingPathComponent(name)) }
        for _ in 0..<5 { try switchTo("B"); try confirm("B"); try switchTo("A"); try confirm("A") }
        for name in names { XCTAssertEqual(try SecureIO.read(root.appendingPathComponent(name)), before[name]) }
        XCTAssertNil(try engine.snapshot().transaction)
    }
}
