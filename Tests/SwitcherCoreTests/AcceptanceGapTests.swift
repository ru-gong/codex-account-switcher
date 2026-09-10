import XCTest
import Darwin
@testable import SwitcherCore

/// Additional acceptance scenarios use only Demo credentials and a fresh synthetic root.
/// No production Keychain, auth.json, browser profile, or History settings are accessed.
final class AcceptanceGapTests: XCTestCase {
    private var root: URL!
    private var engine: Engine!
    private let trial = SwitchPolicy(version: "acceptance-synthetic", allowCapabilityTrial: true)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("switcher-acceptance-gap-" + UUID().uuidString)
        engine = try Demo.make(root: root)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func key(_ name: String) throws -> String { try Demo.credential(name).identity.key }
    private func account(_ name: String) throws -> Account {
        let id = try key(name)
        return try XCTUnwrap(engine.snapshot().accounts.first { $0.id == id })
    }
    private func journal() throws -> Data {
        try SecureIO.read(engine.root.appendingPathComponent("accounts.json"))
    }
    private func expect(_ code: SwitcherError, _ action: () throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) {
            XCTAssertEqual($0 as? SwitcherError, code, file: file, line: line)
        }
    }
    private func alternate(store: SecretStore? = nil,
                           writers: @escaping () throws -> Void = {}) throws -> Engine {
        try Engine(root: engine.root, authURL: engine.authURL,
                   secrets: store ?? TestSecretStore(root: root.appendingPathComponent("fake-secrets")),
                   writersStopped: writers, environmentAllowed: {})
    }
    private func jwt(_ claims: [String: Any]) throws -> String {
        let payload = try canonical(claims).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return "eyJhbGciOiJub25lIn0." + payload + ".SYNTHETIC_ONLY"
    }

    func testMalformedAndInconsistentCredentialsNeverReachImport() throws {
        let original = try Demo.credential("B")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: original.data) as? [String: Any])
        let originalTokens = try XCTUnwrap(object["tokens"] as? [String: Any])
        var samples: [(Data, SwitcherError)] = [(Data("{broken".utf8), .invalidAuth), (try canonical([:]), .invalidAuth)]
        for field in ["id_token", "access_token", "refresh_token", "account_id"] {
            var tokens = originalTokens; tokens.removeValue(forKey: field)
            var modified = object; modified["tokens"] = tokens
            samples.append((try canonical(modified), .invalidAuth))
        }
        for field in ["id_token", "access_token"] {
            var tokens = originalTokens; tokens[field] = "not-a-jwt"
            var modified = object; modified["tokens"] = tokens
            samples.append((try canonical(modified), .invalidAuth))
        }
        for field in ["id_token", "access_token"] {
            var claims = try XCTUnwrap(Credential.claims(originalTokens[field] as! String))
            var identity = try XCTUnwrap(claims["https://api.openai.com/auth"] as? [String: Any])
            identity["chatgpt_account_id"] = "wrong-synthetic-workspace"
            claims["https://api.openai.com/auth"] = identity
            var tokens = originalTokens; tokens[field] = try jwt(claims)
            var modified = object; modified["tokens"] = tokens
            samples.append((try canonical(modified), .identityMismatch))
        }
        var claims = try XCTUnwrap(Credential.claims(originalTokens["access_token"] as! String))
        var identity = try XCTUnwrap(claims["https://api.openai.com/auth"] as? [String: Any])
        identity["chatgpt_user_id"] = "wrong-synthetic-user"
        claims["https://api.openai.com/auth"] = identity
        var tokens = originalTokens; tokens["access_token"] = try jwt(claims)
        var modified = object; modified["tokens"] = tokens
        samples.append((try canonical(modified), .identityMismatch))
        let beforeAuth = try SecureIO.read(engine.authURL), beforeJournal = try journal()
        let targetSecret = root.appendingPathComponent("fake-secrets").appendingPathComponent(try account("B").secret)
        for (data, expected) in samples {
            expect(expected) {
                let parsed = try Credential(data: data)
                try engine.importAuthorized(parsed, expectedKey: key("B"), expectedGeneration: 1)
            }
            XCTAssertEqual(try SecureIO.read(engine.authURL), beforeAuth)
            XCTAssertEqual(try journal(), beforeJournal)
            // Also reject already-stored damage during preflight, before any probe or journal write.
            try SecureIO.write(data, to: targetSecret)
            expect(expected) {
                try engine.switchAccount(key("B"), policy: trial, validateTarget: { _ in XCTFail("Damaged credentials must not reach probe") })
            }
            XCTAssertEqual(try SecureIO.read(engine.authURL), beforeAuth)
            XCTAssertEqual(try journal(), beforeJournal)
            try SecureIO.write(original.data, to: targetSecret)
        }
    }

    func testFutureFieldsSurviveBothDirectionsAndConfirmation() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Demo.credential("B", revision: 2).data) as? [String: Any])
        object["future_nested"] = ["text": "无敏感测试/保留", "values": [1, NSNull(), true]] as [String: Any]
        var tokens = object["tokens"] as! [String: Any]
        tokens["future_token_metadata"] = ["revision": 42, "enabled": true]
        object["tokens"] = tokens
        let future = try Credential(data: canonical(object))
        try engine.importAuthorized(future, expectedKey: key("B"), expectedGeneration: 1)
        for name in ["B", "A", "B"] {
            try engine.switchAccount(key(name), policy: trial, validateTarget: { _ in })
            try engine.confirmDesktop(targetKey: key(name), continuityObserved: false, version: trial.version)
        }
        XCTAssertEqual(try engine.mainCredential().data, future.data)
        XCTAssertNil(try engine.snapshot().transaction)
    }

    private final class FaultingVault: SecretStore {
        let wrapped: TestSecretStore
        var denyReads = false, denyWrites = false
        init(_ wrapped: TestSecretStore) { self.wrapped = wrapped }
        func get(_ reference: String) throws -> Data {
            if denyReads { throw SwitcherError.keychain }
            return try wrapped.get(reference)
        }
        func put(_ data: Data) throws -> String {
            if denyWrites { throw SwitcherError.keychain }
            return try wrapped.put(data)
        }
        func remove(_ reference: String) throws { try wrapped.remove(reference) }
    }

    func testTargetVaultReadDeniedLeavesAuthAndJournalUntouched() throws {
        let vault = FaultingVault(try TestSecretStore(root: root.appendingPathComponent("fake-secrets")))
        vault.denyReads = true
        let other = try alternate(store: vault)
        let beforeAuth = try SecureIO.read(engine.authURL), beforeJournal = try journal()
        expect(.keychain) { try other.switchAccount(key("B"), policy: trial, validateTarget: { _ in XCTFail("Probe must not run") }) }
        XCTAssertEqual(try SecureIO.read(engine.authURL), beforeAuth)
        XCTAssertEqual(try journal(), beforeJournal)
    }

    func testSourceVaultSaveDeniedKeepsLatestMainAndDoesNotStartSwitch() throws {
        let fresh = try Demo.credential("A", revision: 9)
        try SecureIO.write(fresh.data, to: engine.authURL)
        let vault = FaultingVault(try TestSecretStore(root: root.appendingPathComponent("fake-secrets")))
        vault.denyWrites = true
        let other = try alternate(store: vault), beforeJournal = try journal()
        expect(.keychain) { try other.switchAccount(key("B"), policy: trial, validateTarget: { _ in }) }
        XCTAssertEqual(try engine.mainCredential().data, fresh.data)
        XCTAssertEqual(try journal(), beforeJournal)
        XCTAssertNil(try engine.snapshot().transaction)
        XCTAssertEqual(try account("A").generation, 1)
    }

    func testReadOnlyAuthDirectoryBlocksWriteAndRecoveryKeepsOriginal() throws {
        guard getuid() != 0 else { throw XCTSkip("Requires an ordinary macOS user") }
        let parent = engine.authURL.deletingLastPathComponent()
        let before = try SecureIO.read(engine.authURL)
        XCTAssertEqual(chmod(parent.path, 0o500), 0)
        defer { _ = chmod(parent.path, 0o700) }
        expect(.io) { try engine.switchAccount(key("B"), policy: trial, validateTarget: { _ in }) }
        XCTAssertEqual(try SecureIO.read(engine.authURL), before)
        XCTAssertNotNil(try engine.snapshot().transaction)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: parent.path).contains { $0.hasPrefix(".switcher-") })
        XCTAssertEqual(chmod(parent.path, 0o700), 0)
        try engine.recover(rollback: true)
        XCTAssertNil(try engine.snapshot().transaction)
        XCTAssertEqual(try SecureIO.read(engine.authURL), before)
    }

    func testForeignOwnedDirectoryRejectedWithoutReadingSystemFiles() throws {
        guard getuid() != 0 else { throw XCTSkip("Requires an ordinary macOS user") }
        // Read-only stat/validation; no create, chmod, chown, or file read in this directory.
        let foreign = URL(fileURLWithPath: "/private/etc", isDirectory: true)
        var info = stat()
        XCTAssertEqual(lstat(foreign.path, &info), 0)
        XCTAssertNotEqual(info.st_uid, getuid())
        expect(.unsafePath) { try SecureIO.validateDirectory(foreign) }
        XCTAssertNil(try engine.snapshot().transaction)
    }

    func testTargetServiceFailuresNeverCommitOrDiscardSourceRefresh() throws {
        let fresh = try Demo.credential("A", revision: 9)
        try SecureIO.write(fresh.data, to: engine.authURL)
        let beforeJournal = try journal()
        for error: SwitcherError in [.expired, .unauthorized, .forbidden, .offline, .serverError, .timeout, .protocolError] {
            expect(error) { try engine.switchAccount(key("B"), policy: trial, validateTarget: { _ in throw error }) }
            XCTAssertEqual(try engine.mainCredential().data, fresh.data)
            XCTAssertEqual(try journal(), beforeJournal)
            XCTAssertNil(try engine.snapshot().transaction)
        }
    }

    func testRollbackWaitsForWritersThenRetainsRefreshedTarget() throws {
        try engine.switchAccount(key("B"), policy: trial, validateTarget: { _ in })
        try engine.noteLaunched()
        let refreshedB = try Demo.credential("B", revision: 9)
        try SecureIO.write(refreshedB.data, to: engine.authURL)
        var running = true
        let other = try alternate(writers: { if running { throw SwitcherError.writersRunning } })
        let beforeJournal = try journal()
        expect(.writersRunning) { try other.recover(rollback: true) }
        XCTAssertEqual(try engine.mainCredential().data, refreshedB.data)
        XCTAssertEqual(try journal(), beforeJournal)
        running = false
        try other.recover(rollback: true)
        XCTAssertEqual(try engine.mainCredential().identity.key, try key("A"))
        XCTAssertEqual(try engine.credentialForProbe(key("B")).data, refreshedB.data)
        XCTAssertEqual(try account("B").generation, 2)
        XCTAssertNil(try engine.snapshot().transaction)
    }

    func testExternalIdentityBeforeLaunchRemainsUntouchedAndPending() throws {
        try engine.switchAccount(key("B"), policy: trial, validateTarget: { _ in })
        let external = try Demo.credential("C", revision: 3)
        try SecureIO.write(external.data, to: engine.authURL)
        let beforeJournal = try journal()
        expect(.conflict) { try engine.prepareLaunch() }
        XCTAssertEqual(try engine.mainCredential().data, external.data)
        XCTAssertEqual(try journal(), beforeJournal)
        XCTAssertNotNil(try engine.snapshot().transaction)
    }

    func testIdentityOnlyConfirmationCapturesRefreshWithoutGrantingContinuity() throws {
        try engine.switchAccount(key("B"), policy: trial, validateTarget: { _ in })
        try engine.noteLaunched()
        let refreshedB = try Demo.credential("B", revision: 9)
        try SecureIO.write(refreshedB.data, to: engine.authURL)
        try engine.confirmDesktop(targetKey: key("B"), continuityObserved: false, version: trial.version)
        XCTAssertNil(try engine.snapshot().transaction)
        XCTAssertEqual(try engine.mainCredential().data, refreshedB.data)
        XCTAssertEqual(try engine.credentialForProbe(key("B")).data, refreshedB.data)
        XCTAssertEqual(try account("B").generation, 2)
        XCTAssertNil(try account("B").continuityVerifiedVersion)
    }

    func testCancellationAfterAuthCommitPreventsLaunchAndPreservesRecovery() throws {
        let token = Cancellation()
        try engine.switchAccount(key("B"), policy: trial, cancellation: token, validateTarget: { _ in })
        let beforeAuth = try SecureIO.read(engine.authURL), beforeJournal = try journal()
        token.cancel()
        expect(.cancelled) { try engine.prepareLaunch(cancellation: token) }
        XCTAssertEqual(try SecureIO.read(engine.authURL), beforeAuth)
        XCTAssertEqual(try journal(), beforeJournal)
        XCTAssertEqual(try engine.snapshot().transaction?.phase, .written)
        try engine.recover(rollback: true)
        XCTAssertEqual(try engine.mainCredential().identity.key, try key("A"))
        XCTAssertNil(try engine.snapshot().transaction)
    }

    func testCancellationDuringFinalLaunchChecksPreservesCommittedAuth() throws {
        try engine.switchAccount(key("B"), policy: trial, validateTarget: { _ in })
        let token = Cancellation()
        let other = try alternate(writers: { token.cancel() })
        let beforeAuth = try SecureIO.read(engine.authURL), beforeJournal = try journal()
        expect(.cancelled) { try other.prepareLaunch(cancellation: token) }
        XCTAssertEqual(try SecureIO.read(engine.authURL), beforeAuth)
        XCTAssertEqual(try journal(), beforeJournal)
    }
}
