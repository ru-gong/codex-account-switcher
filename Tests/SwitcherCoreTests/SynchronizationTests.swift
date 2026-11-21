import XCTest
@testable import SwitcherCore

final class SynchronizationTests: XCTestCase {
    private var root: URL!
    private var engine: Engine!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("switcher-sync-tests-" + UUID().uuidString)
        engine = try Demo.make(root: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func accounts() throws -> [Account] { try engine.snapshot().accounts }
    private func quota() throws -> Quota { try Quota.parse(["rateLimits": ["primary": ["usedPercent": 19, "windowDurationMins": 300]]]) }
    private func ledgerData() throws -> Data { try SecureIO.read(engine.root.appendingPathComponent("accounts.json")) }
    private func providerCredential(subject: String, workspace: String, email: String?, user: String? = nil) throws -> Credential {
        var auth: [String: Any] = ["chatgpt_account_id": workspace, "chatgpt_plan_type": "pro"]
        if let user { auth["chatgpt_user_id"] = user }
        var claims: [String: Any] = ["iss": "https://auth.openai.com", "sub": subject,
                                    "https://api.openai.com/auth": auth, "exp": 4_102_444_800]
        if let email { claims["email"] = email }
        let payload = try canonical(claims).base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let token = "eyJhbGciOiJub25lIn0." + payload + ".SYNTHETIC_ONLY"
        return try Credential(data: canonical([
            "tokens": ["id_token": token, "access_token": token, "refresh_token": "SYNTHETIC_REFRESH",
                       "account_id": workspace, "oauth_provenance": ["fixture": "provider-neutral", "future": [1, 2]],
                       "login_owner_id": "SYNTHETIC_TOKEN_OWNER"],
            "login_owner_id": "SYNTHETIC_ROOT_OWNER", "auth_mode": "chatgpt", "future_metadata": ["preserved": true]
        ]))
    }

    func testProviderSubjectsAndAppleEmailVariantsUseUserWorkspaceIdentity() throws {
        let googleOne = try providerCredential(subject: "google-oauth2|synthetic-one", workspace: "synthetic-workspace", email: "shared@example.invalid")
        let googleTwo = try providerCredential(subject: "google-oauth2|synthetic-two", workspace: "synthetic-workspace", email: "shared@example.invalid")
        let appleRelay = try providerCredential(subject: "apple|synthetic-three", workspace: "synthetic-workspace", email: "synthetic-apple-relay@example.invalid")
        let appleWithoutEmail = try providerCredential(subject: "apple|synthetic-three", workspace: "synthetic-workspace", email: nil)
        let appleOtherWorkspace = try providerCredential(subject: "apple|synthetic-three", workspace: "synthetic-other-workspace", email: nil)
        XCTAssertEqual(Set([googleOne.identity.key, googleTwo.identity.key, appleRelay.identity.key]).count, 3)
        XCTAssertEqual(appleRelay.identity, appleWithoutEmail.identity, "An optional display email cannot change account identity")
        XCTAssertNotEqual(appleRelay.identity, appleOtherWorkspace.identity)
        XCTAssertEqual(appleWithoutEmail.email, "未提供邮箱")

        let googleWithOpenAIUser = try providerCredential(subject: "google-oauth2|synthetic-one", workspace: "synthetic-workspace", email: nil, user: "synthetic-openai-user")
        let appleWithSameOpenAIUser = try providerCredential(subject: "apple|synthetic-three", workspace: "synthetic-workspace", email: nil, user: "synthetic-openai-user")
        XCTAssertEqual(googleWithOpenAIUser.identity, appleWithSameOpenAIUser.identity, "OpenAI user and workspace take precedence over provider subject")
    }

    func testSwitchPreservesProviderMetadataAndUnknownTokenFields() throws {
        let providerEngine = try Demo.make(root: root.appendingPathComponent("provider-fixture"), seed: false)
        let credentials = try [
            providerCredential(subject: "google-oauth2|synthetic-one", workspace: "synthetic-one", email: "one@example.invalid"),
            providerCredential(subject: "google-oauth2|synthetic-two", workspace: "synthetic-two", email: "two@example.invalid"),
            providerCredential(subject: "apple|synthetic-three", workspace: "synthetic-three", email: "synthetic-apple-relay@example.invalid")
        ]
        try SecureIO.write(credentials[0].data, to: providerEngine.authURL)
        try providerEngine.importCurrent()
        for credential in credentials.dropFirst() { try providerEngine.importAuthorized(credential) }
        XCTAssertEqual(try providerEngine.snapshot().accounts.count, 3)
        for target in credentials.dropFirst() {
            try providerEngine.switchAccount(target.identity.key, policy: SwitchPolicy(version: "synthetic", allowCapabilityTrial: true), validateTarget: { _ in })
            XCTAssertEqual(try SecureIO.read(providerEngine.authURL), target.data, "Switching preserves complete canonical credential data including future metadata")
            let written = try XCTUnwrap(JSONSerialization.jsonObject(with: SecureIO.read(providerEngine.authURL)) as? [String: Any])
            let tokens = try XCTUnwrap(written["tokens"] as? [String: Any])
            XCTAssertEqual(tokens["login_owner_id"] as? String, "SYNTHETIC_TOKEN_OWNER")
            XCTAssertEqual(written["login_owner_id"] as? String, "SYNTHETIC_ROOT_OWNER")
            XCTAssertEqual(try canonical(XCTUnwrap(tokens["oauth_provenance"])), try canonical(["fixture": "provider-neutral", "future": [1, 2]]))
            try providerEngine.confirmDesktop(targetKey: target.identity.key, continuityObserved: false, version: "synthetic")
        }
    }

    func testExpiredQuotaFailureRemainsExpiredAndRequestsRelogin() throws {
        let account = try accounts()[1]
        let report = try QuotaRefresh.run(engine: engine, accounts: [account], cancellation: Cancellation()) { _, _ in
            throw SwitcherError.expired
        }
        let saved = try accounts()[1]
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.needsAuthorization, 0)
        XCTAssertEqual(saved.quotaError, SwitcherError.expired.rawValue)
        XCTAssertEqual(saved.fingerprint, account.fingerprint)
        XCTAssertTrue(QuotaRefresh.status(for: saved).contains("重新登录"))
        XCTAssertTrue(SwitcherError.expired.localizedDescription.contains("重新登录"))
    }

    func testCurrentDesktopRefreshAdvancesVaultAndQuotaWithoutWritingAuth() throws {
        let old = try accounts()[0], refreshed = try Demo.credential("A", revision: 2)
        try engine.updateQuota(old.id, fingerprint: old.fingerprint, quota: nil, error: .expired)
        try SecureIO.write(refreshed.data, to: engine.authURL)
        let beforeAuth = try SecureIO.read(engine.authURL), result = try quota()
        let report = try QuotaRefresh.run(engine: engine, accounts: [old], cancellation: Cancellation()) { credential, _ in
            XCTAssertEqual(credential.fingerprint, refreshed.fingerprint)
            return result
        }
        let saved = try accounts()[0]
        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(saved.generation, old.generation + 1)
        XCTAssertEqual(saved.mainBaseline, refreshed.fingerprint)
        XCTAssertTrue(saved.knownFingerprints.contains(old.fingerprint))
        XCTAssertTrue(saved.secretHistory.contains(old.secret))
        XCTAssertEqual(saved.quota, result)
        XCTAssertNil(saved.quotaError)
        XCTAssertNil(saved.quotaRetryAfter)
        XCTAssertEqual(try SecureIO.read(engine.authURL), beforeAuth)
    }

    func testManuallySelectedKnownCredentialEstablishesBaselineForNextRefresh() throws {
        let saved = try accounts()[1]
        XCTAssertNil(saved.mainBaseline)
        try SecureIO.write(Demo.credential("B").data, to: engine.authURL)
        XCTAssertEqual(try engine.credentialForQuota(saved).fingerprint, saved.fingerprint)
        let observed = try accounts()[1]
        XCTAssertEqual(observed.mainBaseline, saved.fingerprint)
        XCTAssertEqual(observed.generation, saved.generation)
        let refreshed = try Demo.credential("B", revision: 2)
        try SecureIO.write(refreshed.data, to: engine.authURL)
        XCTAssertEqual(try engine.credentialForQuota(observed).fingerprint, refreshed.fingerprint)
        XCTAssertEqual(try accounts()[1].generation, saved.generation + 1)
    }

    func testNewCredentialInvalidatesCachedQuotaAndOldErrors() throws {
        let old = try accounts()[1]
        try engine.updateQuota(old.id, fingerprint: old.fingerprint, quota: nil, error: .expired)
        try engine.importAuthorized(Demo.credential("B", revision: 2), expectedKey: old.id, expectedGeneration: old.generation)
        let saved = try accounts()[1]
        XCTAssertNil(saved.quota)
        XCTAssertNil(saved.quotaError)
        XCTAssertNil(saved.quotaRetryAfter)
    }

    func testDivergentCurrentVaultBlocksOnlyCurrentQuota() throws {
        let old = try accounts()[0]
        try engine.importAuthorized(Demo.credential("A", revision: 2), expectedKey: old.id, expectedGeneration: old.generation)
        let refreshed = try Demo.credential("A", revision: 3)
        try SecureIO.write(refreshed.data, to: engine.authURL)
        let all = try accounts(), result = try quota()
        let report = try QuotaRefresh.run(engine: engine, accounts: all, cancellation: Cancellation()) { credential, _ in
            XCTAssertNotEqual(credential.identity.key, old.id, "A fork must not query the saved older token")
            return result
        }
        XCTAssertEqual(report.updated, 2)
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(try accounts()[0].fingerprint, all[0].fingerprint)
        XCTAssertEqual(try engine.mainCredential().fingerprint, refreshed.fingerprint)
        XCTAssertEqual(try accounts()[0].quotaError, SwitcherError.conflict.rawValue)
    }

    func testKnownOlderDesktopGenerationNeverDowngradesNewerVault() throws {
        let old = try accounts()[0]
        try engine.importAuthorized(Demo.credential("A", revision: 2), expectedKey: old.id, expectedGeneration: old.generation)
        let current = try accounts()[0], ledgerBefore = try ledgerData()
        XCTAssertThrowsError(try engine.credentialForQuota(current)) { XCTAssertEqual($0 as? SwitcherError, .conflict) }
        XCTAssertEqual(try ledgerData(), ledgerBefore)
        XCTAssertEqual(try engine.mainCredential().fingerprint, old.fingerprint)
        XCTAssertEqual(try engine.credentialForProbe(old.id).fingerprint, current.fingerprint)
    }

    func testExternalWriteDuringSyncCannotCommitStaleVaultMetadata() throws {
        let old = try accounts()[0], ledgerBefore = try ledgerData()
        try SecureIO.write(Demo.credential("A", revision: 2).data, to: engine.authURL)
        let externallySelected = try Demo.credential("C", revision: 3)
        engine.fault = { point in
            if point == "ledgerBeforeRename" { try SecureIO.write(externallySelected.data, to: self.engine.authURL) }
        }
        XCTAssertThrowsError(try engine.credentialForQuota(old)) { XCTAssertEqual($0 as? SwitcherError, .conflict) }
        engine.fault = nil
        XCTAssertEqual(try ledgerData(), ledgerBefore)
        XCTAssertEqual(try engine.mainCredential().fingerprint, externallySelected.fingerprint)
        XCTAssertEqual(try engine.credentialForProbe(old.id).fingerprint, old.fingerprint)
    }

    func testUnknownDesktopAccountIsNotAddedDuringQuotaRefresh() throws {
        let all = try accounts(), unknown = try Demo.credential("D"), result = try quota()
        try SecureIO.write(unknown.data, to: engine.authURL)
        let report = try QuotaRefresh.run(engine: engine, accounts: all, cancellation: Cancellation()) { _, _ in result }
        XCTAssertEqual(report.updated, all.count)
        XCTAssertEqual(try accounts().map(\.id), all.map(\.id))
        XCTAssertEqual(try engine.mainCredential().fingerprint, unknown.fingerprint)
    }

    func testPendingSwitchPreventsCurrentCredentialReconciliation() throws {
        let all = try accounts()
        try engine.switchAccount(all[1].id, policy: SwitchPolicy(version: "synthetic", allowCapabilityTrial: true), validateTarget: { _ in })
        try SecureIO.write(Demo.credential("B", revision: 3).data, to: engine.authURL)
        let target = try accounts()[1], before = try ledgerData()
        XCTAssertThrowsError(try engine.credentialForQuota(target)) { XCTAssertEqual($0 as? SwitcherError, .pendingRecovery) }
        XCTAssertEqual(try ledgerData(), before)
        XCTAssertNotNil(try engine.snapshot().transaction)
    }

    func testStaleAccountSnapshotDoesNotStopOtherAccountQueries() throws {
        let all = try accounts(), result = try quota()
        try engine.importAuthorized(Demo.credential("B", revision: 2), expectedKey: all[1].id, expectedGeneration: all[1].generation)
        var queried: [String] = []
        XCTAssertThrowsError(try QuotaRefresh.run(engine: engine, accounts: all, cancellation: Cancellation()) { credential, _ in
            queried.append(credential.identity.key)
            return result
        }) { XCTAssertEqual($0 as? SwitcherError, .conflict) }
        XCTAssertEqual(queried, [all[0].id, all[2].id])
        XCTAssertNil(try accounts()[1].quotaError)
        XCTAssertEqual(try accounts()[2].quota, result)
    }

    func testDeniedCurrentSynchronizationNeverFallsBackToOldVault() throws {
        final class AddDenied: SecretStore {
            let wrapped: TestSecretStore
            init(_ root: URL) throws { wrapped = try TestSecretStore(root: root) }
            func get(_ reference: String) throws -> Data { try wrapped.get(reference) }
            func put(_ data: Data) throws -> String { throw SwitcherError.keychainAuthorizationRequired }
            func remove(_ reference: String) throws { try wrapped.remove(reference) }
        }
        let all = try accounts(), refreshed = try Demo.credential("A", revision: 2), result = try quota()
        try SecureIO.write(refreshed.data, to: engine.authURL)
        let other = try Engine(root: engine.root, authURL: engine.authURL,
                               secrets: AddDenied(root.appendingPathComponent("fake-secrets")), writersStopped: {}, environmentAllowed: {})
        let report = try QuotaRefresh.run(engine: other, accounts: all, cancellation: Cancellation()) { credential, _ in
            XCTAssertNotEqual(credential.identity.key, all[0].id)
            return result
        }
        XCTAssertEqual(report.needsAuthorization, 1)
        XCTAssertEqual(report.updated, 2)
        XCTAssertEqual(try accounts()[0].fingerprint, all[0].fingerprint)
        XCTAssertEqual(try engine.mainCredential().fingerprint, refreshed.fingerprint)
    }

    func testCurrentSameGenerationQueriesDiskWhileNoncurrentRequiresVaultRead() throws {
        final class ReadDenied: SecretStore {
            var reads = 0
            func get(_ reference: String) throws -> Data { reads += 1; throw SwitcherError.keychainAuthorizationRequired }
            func put(_ data: Data) throws -> String { XCTFail("Unchanged credentials must not create another secret"); throw SwitcherError.keychain }
            func remove(_ reference: String) throws { XCTFail("Quota queries must not remove credentials") }
        }
        let all = try accounts(), denied = ReadDenied(), beforeAuth = try SecureIO.read(engine.authURL), result = try quota()
        let other = try Engine(root: engine.root, authURL: engine.authURL, secrets: denied, writersStopped: {}, environmentAllowed: {})
        let report = try QuotaRefresh.run(engine: other, accounts: all, cancellation: Cancellation()) { credential, _ in
            XCTAssertEqual(credential.identity.key, all[0].id)
            XCTAssertEqual(credential.fingerprint, all[0].fingerprint)
            return result
        }
        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(report.needsAuthorization, 2)
        XCTAssertEqual(denied.reads, 2, "Only noncurrent accounts require saved vault reads")
        XCTAssertEqual(try SecureIO.read(engine.authURL), beforeAuth)
        XCTAssertNil(try accounts()[0].quotaError)
    }

    func testUnexpectedSourcePreventsSwitchIncludingSameTargetNoop() throws {
        let all = try accounts(), externallySelected = try Demo.credential("C", revision: 2)
        try SecureIO.write(externallySelected.data, to: engine.authURL)
        let before = try ledgerData(), beforeAuth = try SecureIO.read(engine.authURL)
        for target in [all[1].id, all[2].id] {
            XCTAssertThrowsError(try engine.switchAccount(target, policy: SwitchPolicy(version: "synthetic", allowCapabilityTrial: true), expectedSourceKey: all[0].id, validateTarget: { _ in
                XCTFail("Unexpected source must be rejected before validating the target")
            })) { XCTAssertEqual($0 as? SwitcherError, .conflict) }
        }
        XCTAssertEqual(try ledgerData(), before)
        XCTAssertEqual(try SecureIO.read(engine.authURL), beforeAuth)
        XCTAssertNil(try engine.snapshot().transaction)
    }

    func testExpectedSourceAllowsItsRotatedCredentialAndPreservesItForRecovery() throws {
        let all = try accounts(), refreshed = try Demo.credential("A", revision: 2)
        try SecureIO.write(refreshed.data, to: engine.authURL)
        try engine.switchAccount(all[1].id, policy: SwitchPolicy(version: "synthetic", allowCapabilityTrial: true), expectedSourceKey: all[0].id, validateTarget: { _ in })
        let after = try engine.snapshot(), transaction = try XCTUnwrap(after.transaction)
        XCTAssertEqual(try engine.mainCredential().identity.key, all[1].id)
        XCTAssertEqual(transaction.source, all[0].id)
        XCTAssertEqual(transaction.sourceDiskFingerprint, refreshed.fingerprint)
        XCTAssertEqual(after.accounts[0].generation, all[0].generation + 1)
        XCTAssertEqual(try engine.credentialForProbe(all[0].id).fingerprint, refreshed.fingerprint)
    }

    func testExplicitValidatedCurrentResolvesUnknownForkAndPreservesHistory() throws {
        let initial = try accounts()[0]
        try engine.importAuthorized(Demo.credential("A", revision: 2), expectedKey: initial.id, expectedGeneration: initial.generation)
        let forked = try accounts()[0], validated = try Demo.credential("A", revision: 3)
        try engine.updateQuota(forked.id, fingerprint: forked.fingerprint, quota: nil, error: .expired)
        try SecureIO.write(validated.data, to: engine.authURL)
        let beforeAuth = try SecureIO.read(engine.authURL)
        XCTAssertThrowsError(try engine.credentialForQuota(forked)) { XCTAssertEqual($0 as? SwitcherError, .conflict) }
        try engine.saveValidatedCurrent(validated, expectedGeneration: forked.generation)
        let saved = try accounts()[0]
        XCTAssertEqual(saved.generation, forked.generation + 1)
        XCTAssertEqual(saved.fingerprint, validated.fingerprint)
        XCTAssertEqual(saved.mainBaseline, validated.fingerprint)
        XCTAssertEqual(Array(saved.secretHistory.dropLast()), forked.secretHistory)
        XCTAssertEqual(Array(saved.knownFingerprints.dropLast()), forked.knownFingerprints)
        XCTAssertNil(saved.quotaError)
        XCTAssertNil(saved.quotaRetryAfter)
        XCTAssertEqual(try engine.credentialForProbe(saved.id).fingerprint, validated.fingerprint)
        XCTAssertEqual(try SecureIO.read(engine.authURL), beforeAuth)
        XCTAssertNil(try engine.snapshot().transaction)
    }

    func testValidatedCurrentRejectsStaleGeneration() throws {
        let initial = try accounts()[0]
        try engine.importAuthorized(Demo.credential("A", revision: 2), expectedKey: initial.id, expectedGeneration: initial.generation)
        let validated = try Demo.credential("A", revision: 3)
        try SecureIO.write(validated.data, to: engine.authURL)
        let before = try ledgerData(), beforeAuth = try SecureIO.read(engine.authURL)
        XCTAssertThrowsError(try engine.saveValidatedCurrent(validated, expectedGeneration: initial.generation)) { XCTAssertEqual($0 as? SwitcherError, .conflict) }
        XCTAssertEqual(try ledgerData(), before)
        XCTAssertEqual(try SecureIO.read(engine.authURL), beforeAuth)
    }

    func testValidatedCurrentRejectsDiskChangedAfterValidation() throws {
        let saved = try accounts()[0], validated = try Demo.credential("A", revision: 2)
        try SecureIO.write(Demo.credential("A", revision: 3).data, to: engine.authURL)
        let before = try ledgerData(), beforeAuth = try SecureIO.read(engine.authURL)
        XCTAssertThrowsError(try engine.saveValidatedCurrent(validated, expectedGeneration: saved.generation)) { XCTAssertEqual($0 as? SwitcherError, .conflict) }
        XCTAssertEqual(try ledgerData(), before)
        XCTAssertEqual(try SecureIO.read(engine.authURL), beforeAuth)
    }

    func testValidatedCurrentCommitCASPreservesExternalDiskChange() throws {
        let saved = try accounts()[0], validated = try Demo.credential("A", revision: 2), external = try Demo.credential("C", revision: 3)
        try SecureIO.write(validated.data, to: engine.authURL)
        let before = try ledgerData()
        engine.fault = { point in
            if point == "ledgerBeforeRename" { try SecureIO.write(external.data, to: self.engine.authURL) }
        }
        XCTAssertThrowsError(try engine.saveValidatedCurrent(validated, expectedGeneration: saved.generation)) { XCTAssertEqual($0 as? SwitcherError, .conflict) }
        engine.fault = nil
        XCTAssertEqual(try ledgerData(), before)
        XCTAssertEqual(try engine.mainCredential().fingerprint, external.fingerprint)
        XCTAssertEqual(try engine.credentialForProbe(saved.id).fingerprint, saved.fingerprint)
    }

    func testValidatedCurrentNeverAcceptsKnownOlderGeneration() throws {
        let initial = try accounts()[0], older = try engine.mainCredential()
        try engine.importAuthorized(Demo.credential("A", revision: 2), expectedKey: initial.id, expectedGeneration: initial.generation)
        let saved = try accounts()[0], before = try ledgerData(), beforeAuth = try SecureIO.read(engine.authURL)
        XCTAssertThrowsError(try engine.saveValidatedCurrent(older, expectedGeneration: saved.generation)) { XCTAssertEqual($0 as? SwitcherError, .conflict) }
        XCTAssertEqual(try ledgerData(), before)
        XCTAssertEqual(try SecureIO.read(engine.authURL), beforeAuth)
    }

    func testValidatedCurrentCannotAddUnknownIdentity() throws {
        let unknown = try Demo.credential("D")
        try SecureIO.write(unknown.data, to: engine.authURL)
        let before = try ledgerData()
        XCTAssertThrowsError(try engine.saveValidatedCurrent(unknown, expectedGeneration: 1)) { XCTAssertEqual($0 as? SwitcherError, .missingAccount) }
        XCTAssertEqual(try ledgerData(), before)
        XCTAssertEqual(try engine.mainCredential().fingerprint, unknown.fingerprint)
    }

    func testValidatedCurrentCannotResolvePendingSwitch() throws {
        let all = try accounts()
        try engine.switchAccount(all[1].id, policy: SwitchPolicy(version: "synthetic", allowCapabilityTrial: true), validateTarget: { _ in })
        let current = try engine.mainCredential(), saved = try accounts()[1], before = try ledgerData()
        XCTAssertThrowsError(try engine.saveValidatedCurrent(current, expectedGeneration: saved.generation)) { XCTAssertEqual($0 as? SwitcherError, .pendingRecovery) }
        XCTAssertEqual(try ledgerData(), before)
        XCTAssertEqual(try engine.mainCredential().fingerprint, current.fingerprint)
    }
}
