import XCTest
@testable import SwitcherCore

final class QuotaRefreshTests: XCTestCase {
    private var root: URL!
    private var engine: Engine!
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("quota-tests-" + UUID().uuidString)
        engine = try Demo.make(root: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func accounts() throws -> [Account] { try engine.snapshot().accounts }
    private func quota() throws -> Quota { try Quota.parse(["rateLimits": ["primary": ["usedPercent": 21, "windowDurationMins": 300]]]) }

    func testAutoRefreshDefaultsOnAndExplicitOffSurvivesRelaunch() throws {
        let suite = "synthetic-quota-preferences-" + UUID().uuidString
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let first = QuotaRefreshPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertTrue(first.automatic)
        first.automatic = false
        let reopened = QuotaRefreshPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertFalse(reopened.automatic)
        reopened.automatic = true
        XCTAssertTrue(first.automatic)
    }

    func testStartupChecksStaleAccountsButRetainsFreshCache() throws {
        var all = try accounts()
        all[0].quota?.fetchedAt = now
        all[1].quota?.fetchedAt = now.addingTimeInterval(-900)
        all[2].quota = nil
        XCTAssertEqual(QuotaRefreshSchedule().accountsDue(all, trigger: .automatic, now: now).map(\.id), Array(all.dropFirst()).map(\.id))
    }

    func testMenuAndWakeShareFifteenMinuteThrottleWithoutDeferringManualRefresh() throws {
        let all = try accounts()
        var schedule = QuotaRefreshSchedule()
        schedule.started(at: now)
        for seconds in [0.0, 30, 600, 899] {
            XCTAssertTrue(schedule.accountsDue(all, trigger: .automatic, now: now.addingTimeInterval(seconds)).isEmpty)
        }
        XCTAssertEqual(schedule.accountsDue(all, trigger: .automatic, now: now.addingTimeInterval(900)).count, all.count)
        XCTAssertTrue(schedule.accountsDue(all, trigger: .manual, now: now.addingTimeInterval(14)).isEmpty)
        XCTAssertEqual(schedule.accountsDue(all, trigger: .manual, now: now.addingTimeInterval(15)).count, all.count)
    }

    func testClockMovingBackwardsDoesNotDisableRefresh() throws {
        var schedule = QuotaRefreshSchedule()
        schedule.started(at: now.addingTimeInterval(3_600))
        XCTAssertEqual(schedule.accountsDue(try accounts(), trigger: .automatic, now: now).count, 3)
    }

    func testApprovalImmediatelyRetriesOnlyApprovedAccountDespiteLocalCooldown() throws {
        var all = try accounts(), schedule = QuotaRefreshSchedule()
        schedule.started(at: now)
        all[1].quotaError = SwitcherError.keychainAuthorizationRequired.rawValue
        all[1].quotaRetryAfter = now.addingTimeInterval(60)
        XCTAssertEqual(schedule.accountsDue(all, trigger: .authorized(all[1].id), now: now).map(\.id), [all[1].id])
        XCTAssertTrue(schedule.accountsDue(all, trigger: .authorized("deleted"), now: now).isEmpty)
    }

    func testServerRetryTimeIsRespectedByEveryTriggerIncludingApproval() throws {
        var all = try accounts()
        all[0].quotaError = SwitcherError.rateLimited.rawValue
        all[0].quotaRetryAfter = now.addingTimeInterval(300)
        for trigger: QuotaRefreshTrigger in [.automatic, .manual, .authorized(all[0].id)] {
            XCTAssertFalse(QuotaRefreshSchedule().accountsDue(all, trigger: trigger, now: now).contains { $0.id == all[0].id })
        }
        XCTAssertEqual(QuotaRefreshSchedule().accountsDue(all, trigger: .authorized(all[0].id), now: now.addingTimeInterval(300)).count, 1)
    }

    func testCachedQuotaCannotHideAuthorizationOrExpiredLogin() throws {
        var account = try accounts()[0]
        XCTAssertNotNil(account.quota)
        account.quotaError = SwitcherError.keychainAuthorizationRequired.rawValue
        XCTAssertTrue(QuotaRefresh.status(for: account).contains("待授权"))
        account.quotaError = SwitcherError.expired.rawValue
        XCTAssertTrue(QuotaRefresh.status(for: account).contains("重新登录"))
        account.quotaError = nil
        account.quota?.fetchedAt = now
        XCTAssertEqual(QuotaRefresh.status(for: account, now: now), "")
        XCTAssertEqual(QuotaRefresh.status(for: account, now: now.addingTimeInterval(900)), "额度数据待更新")
    }

    func testUnsupportedVersionIsDistinctFromStaleQuotaAndExpiredLogin() throws {
        var account = try accounts()[0]
        account.quota?.fetchedAt = now.addingTimeInterval(-86_400)
        XCTAssertEqual(QuotaRefresh.status(for: account, now: now, environmentError: .unsupportedVersion), "暂停查询 · Codex 版本需适配")
        XCTAssertEqual(QuotaRefresh.status(for: account, now: now), "额度数据待更新")
        account.quotaError = SwitcherError.expired.rawValue
        XCTAssertEqual(QuotaRefresh.status(for: account, now: now), "登录已过期 · 请重新登录")
    }

    func testCompatibilityFailurePrecedesKeychainAndKeepsAuthAndCachedQuotaUnchanged() throws {
        final class SpyStore: SecretStore {
            var reads = 0
            func get(_ reference: String) throws -> Data { reads += 1; throw SwitcherError.keychainAuthorizationRequired }
            func put(_ data: Data) throws -> String { throw SwitcherError.keychain }
            func remove(_ reference: String) throws { throw SwitcherError.keychain }
        }
        let store = SpyStore(), original = try SecureIO.read(engine.authURL)
        let all = try accounts()
        let probe = try Engine(root: engine.root, authURL: engine.authURL, secrets: store, writersStopped: {}, environmentAllowed: {})
        XCTAssertThrowsError(try QuotaRefresh.run(engine: probe, accounts: all, cancellation: Cancellation(), validateEnvironment: {
            throw SwitcherError.unsupportedVersion
        }) { _, _ in
            XCTFail("Must not send any credentials to an unsupported backend")
            return try self.quota()
        }) { XCTAssertEqual($0 as? SwitcherError, .unsupportedVersion) }
        XCTAssertEqual(store.reads, 0)
        XCTAssertEqual(try SecureIO.read(engine.authURL), original)
        XCTAssertEqual(try accounts().map(\.quota), all.map(\.quota))
        XCTAssertTrue(try accounts().allSatisfy { $0.quotaError == nil })
    }

    func testExplicitBackendPermissionIsPreservedEvenWithRemainingQuota() throws {
        let q = try Quota.parse(["ordinaryUsageAllowed": false, "rateLimitsByLimitId": ["codex": ["normalModelSlug": "synthetic-model", "primary": ["usedPercent": 20, "windowDurationMins": 300]]]])
        XCTAssertEqual(q.primary?.remaining, 80)
        XCTAssertEqual(q.ordinaryUsageAllowed, false)
        var account = try accounts()[0]; account.quota = q
        XCTAssertEqual(QuotaRefresh.status(for: account), "服务端暂不允许使用包含额度")
        XCTAssertEqual(try JSONDecoder().decode(Quota.self, from: JSONEncoder().encode(q)).ordinaryUsageAllowed, false)
    }

    func testMissingOrNullBackendPermissionIsNeverInferredFromPercentages() throws {
        for used in [0, 100] {
            var result: [String: Any] = ["rateLimits": ["primary": ["usedPercent": used, "windowDurationMins": 300]]]
            XCTAssertNil(try Quota.parse(result).ordinaryUsageAllowed)
            result["ordinaryUsageAllowed"] = NSNull()
            XCTAssertNil(try Quota.parse(result).ordinaryUsageAllowed)
            result["ordinaryUsageAllowed"] = true
            XCTAssertEqual(try Quota.parse(result).ordinaryUsageAllowed, true)
        }
    }

    func testNumericOrStringBackendPermissionIsRejected() throws {
        for value: Any in [0, 1, "true"] {
            XCTAssertThrowsError(try Quota.parse(["ordinaryUsageAllowed": value, "rateLimits": ["primary": ["usedPercent": 20, "windowDurationMins": 300]]])) {
                XCTAssertEqual($0 as? SwitcherError, .unknownQuota)
            }
        }
    }

    func testPreUpgradeCachedQuotaDecodesWithoutNewPermissionField() throws {
        let old = Data(#"{"primary":{"usedPercent":20,"windowDurationMins":300},"fetchedAt":800000000,"stale":false}"#.utf8)
        let decoded = try JSONDecoder().decode(Quota.self, from: old)
        XCTAssertEqual(decoded.primary?.remaining, 80)
        XCTAssertNil(decoded.ordinaryUsageAllowed)
    }

    func testMixedBatchReportsEveryOutcomeAndPreservesFailedCacheAndAuthFile() throws {
        let all = try accounts(), before = try SecureIO.read(engine.authURL), next = try quota()
        let report = try QuotaRefresh.run(engine: engine, accounts: all, cancellation: Cancellation()) { credential, _ in
            if credential.identity.key == all[0].id { throw SwitcherError.keychainAuthorizationRequired }
            if credential.identity.key == all[1].id { throw SwitcherError.offline }
            return next
        }
        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(report.needsAuthorization, 1)
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.message, "已更新 1 个账号；1 个待授权；1 个查询失败")
        let after = try accounts()
        XCTAssertEqual(after[0].quota?.primary, all[0].quota?.primary)
        XCTAssertEqual(after[0].quota?.stale, true)
        XCTAssertEqual(after[0].quotaError, "keychainAuthorizationRequired")
        XCTAssertEqual(after[1].quotaError, "offline")
        XCTAssertEqual(after[2].quota, next)
        XCTAssertEqual(try SecureIO.read(engine.authURL), before)
        XCTAssertEqual(after.map(\.fingerprint), all.map(\.fingerprint))
        XCTAssertEqual(after.map(\.continuityVerifiedVersion), all.map(\.continuityVerifiedVersion))
        XCTAssertNil(try engine.snapshot().transaction)
    }

    func testSuccessfulRetryClearsErrorAndBackoff() throws {
        let account = try accounts()[0], next = try quota()
        try engine.updateQuota(account.id, fingerprint: account.fingerprint, quota: nil, error: .keychainAuthorizationRequired)
        let due = QuotaRefreshSchedule().accountsDue(try accounts(), trigger: .authorized(account.id), now: Date())
        let report = try QuotaRefresh.run(engine: engine, accounts: due, cancellation: Cancellation()) { _, _ in next }
        XCTAssertEqual(report.updated, 1)
        let updated = try accounts()[0]
        XCTAssertNil(updated.quotaError)
        XCTAssertNil(updated.quotaRetryAfter)
        XCTAssertEqual(updated.quota, next)
    }

    func testCancelledQueryDoesNotMarkAccountsAsFailed() throws {
        let all = try accounts(), token = Cancellation()
        XCTAssertThrowsError(try QuotaRefresh.run(engine: engine, accounts: all, cancellation: token) { _, _ in
            token.cancel()
            throw SwitcherError.cancelled
        }) { XCTAssertEqual($0 as? SwitcherError, .cancelled) }
        XCTAssertTrue(try accounts().allSatisfy { $0.quotaError == nil })
    }

    func testStaleSnapshotCannotOverwriteNewCredentialQuota() throws {
        let all = try accounts()
        try engine.importAuthorized(Demo.credential("B", revision: 2), expectedKey: all[1].id, expectedGeneration: all[1].generation)
        XCTAssertThrowsError(try QuotaRefresh.run(engine: engine, accounts: [all[1]], cancellation: Cancellation()) { _, _ in
            XCTFail("Credential changed; must not query it under an old snapshot")
            return try self.quota()
        }) { XCTAssertEqual($0 as? SwitcherError, .conflict) }
        XCTAssertNil(try accounts()[1].quotaError)
    }
}
