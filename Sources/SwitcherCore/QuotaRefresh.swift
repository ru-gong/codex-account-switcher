import Foundation

public struct QuotaRefreshPreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var automatic: Bool {
        get { defaults.object(forKey: "automaticQuotaRefresh") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "automaticQuotaRefresh") }
    }
}

public enum QuotaRefreshTrigger: Equatable {
    case automatic, manual, authorized(String)
}

/// All lifecycle triggers share one schedule, independent of whether the menu is open.
public struct QuotaRefreshSchedule {
    private var lastAttempt: Date?
    public init() {}
    public mutating func started(at now: Date) { lastAttempt = now }
    public func accountsDue(_ accounts: [Account], trigger: QuotaRefreshTrigger, now: Date) -> [Account] {
        if let lastAttempt {
            let elapsed = now.timeIntervalSince(lastAttempt)
            // A backwards wall-clock change must not suspend refresh indefinitely.
            if elapsed >= 0 {
                if trigger == .automatic && elapsed < 900 { return [] }
                if trigger == .manual && elapsed < 15 { return [] }
            }
        }
        return accounts.filter { account in
            if case .authorized(let id) = trigger, account.id != id { return false }
            if let retry = account.quotaRetryAfter, retry > now {
                // Explicit approval resolves only a Keychain failure, never a server rate limit.
                guard trigger == .authorized(account.id), account.quotaError == SwitcherError.keychainAuthorizationRequired.rawValue else { return false }
            }
            if trigger == .automatic, let quota = account.quota,
               !quota.stale, account.quotaError == nil,
               (0..<900).contains(now.timeIntervalSince(quota.fetchedAt)) { return false }
            return true
        }
    }
}

public struct QuotaRefreshReport {
    public var updated = 0
    public var needsAuthorization = 0
    public var failed = 0
    public var message: String {
        var parts: [String] = []
        if updated > 0 { parts.append("已更新 \(updated) 个账号") }
        if needsAuthorization > 0 { parts.append("\(needsAuthorization) 个待授权") }
        if failed > 0 { parts.append("\(failed) 个查询失败") }
        return parts.isEmpty ? "暂无可刷新的账号" : parts.joined(separator: "；")
    }
}

public enum QuotaRefresh {
    /// Keep failures local to an account; a successful last account must not hide earlier failures.
    public static func run(engine: Engine, accounts: [Account], cancellation: Cancellation,
                           fetch: (Credential, Cancellation) throws -> Quota) throws -> QuotaRefreshReport {
        var report = QuotaRefreshReport()
        for account in accounts {
            if cancellation.isCancelled { throw SwitcherError.cancelled }
            let quota: Quota
            do {
                let credential = try engine.credentialForProbe(account.id)
                guard credential.fingerprint == account.fingerprint else { throw SwitcherError.conflict }
                quota = try fetch(credential, cancellation)
            } catch {
                if cancellation.isCancelled || error as? SwitcherError == .cancelled { throw SwitcherError.cancelled }
                let failure = error as? SwitcherError ?? .unknownQuota
                try engine.updateQuota(account.id, fingerprint: account.fingerprint, quota: nil, error: failure)
                if failure == .keychainAuthorizationRequired { report.needsAuthorization += 1 }
                else { report.failed += 1 }
                continue
            }
            if cancellation.isCancelled { throw SwitcherError.cancelled }
            try engine.updateQuota(account.id, fingerprint: account.fingerprint, quota: quota, error: nil)
            report.updated += 1
        }
        return report
    }

    public static func status(for account: Account, now: Date = Date()) -> String {
        if let error = account.quotaError {
            switch SwitcherError(rawValue: error) {
            case .keychainAuthorizationRequired: return "待授权 · 点击授权后更新"
            case .expired, .unauthorized, .invalidAuth: return "登录已过期 · 请重新登录"
            case .rateLimited: return "请求受限 · 稍后重试"
            case .offline: return "网络不可用 · 已保留旧值"
            default: return "查询失败 · 已保留上次结果"
            }
        }
        guard let quota = account.quota else { return "额度待查询" }
        return quota.stale || now.timeIntervalSince(quota.fetchedAt) >= 900 ? "额度已过期 · 等待刷新" : ""
    }
}
