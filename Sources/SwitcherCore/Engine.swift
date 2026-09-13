import Foundation

public final class Engine {
    public let root: URL
    public let authURL: URL
    private let secrets: SecretStore
    private let lock: ProcessLock
    private let writersStopped: () throws -> Void
    private let environmentAllowed: () throws -> Void
    /// Fault hooks are used only by tests; no production hook is installed.
    public var fault: ((String) throws -> Void)?
    private var ledgerURL: URL { root.appendingPathComponent("accounts.json") }

    public init(root: URL, authURL: URL, secrets: SecretStore, writersStopped: @escaping () throws -> Void, environmentAllowed: @escaping () throws -> Void) throws {
        self.root = root; self.authURL = authURL; self.secrets = secrets
        self.writersStopped = writersStopped; self.environmentAllowed = environmentAllowed
        try SecureIO.prepareDirectory(root)
        lock = ProcessLock(root: root)
    }
    private func readLedger() throws -> Ledger {
        if !FileManager.default.fileExists(atPath: ledgerURL.path) { return Ledger() }
        guard let value = try? JSONDecoder().decode(Ledger.self, from: SecureIO.read(ledgerURL)), value.schema == 1 else { throw SwitcherError.io }; return value
    }
    private func save(_ ledger: Ledger) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try SecureIO.write(try encoder.encode(ledger), to: ledgerURL, preCommit: { try self.fault?("ledgerBeforeRename") }, afterRename: { try self.fault?("ledgerAfterRename") })
        // Never delete a new immutable secret on an uncertain metadata commit.
    }
    public func snapshot() throws -> Ledger { try lock.withLock { try readLedger() } }
    public func mainCredential() throws -> Credential { try Credential(data: SecureIO.read(authURL)) }
    private func accountIndex(_ key: String, in ledger: Ledger) throws -> Int {
        guard let i = ledger.accounts.firstIndex(where: { $0.id == key }) else { throw SwitcherError.missingAccount }; return i
    }
    private func credential(_ account: Account) throws -> Credential {
        let c = try Credential(data: secrets.get(account.secret))
        guard c.identity == account.identity, c.fingerprint == account.fingerprint else { throw SwitcherError.identityMismatch }; return c
    }
    public func credentialForProbe(_ key: String) throws -> Credential {
        try lock.withLock { let l = try readLedger(); return try credential(l.accounts[accountIndex(key, in: l)]) }
    }
    private func put(_ value: Credential, into ledger: inout Ledger, alias: String? = nil) throws {
        if let i = ledger.accounts.firstIndex(where: { $0.id == value.identity.key }) {
            if ledger.accounts[i].fingerprint == value.fingerprint { return }
            let ref = try secrets.put(value.data)
            ledger.accounts[i].secretHistory.append(ref)
            ledger.accounts[i].knownFingerprints.append(value.fingerprint)
            ledger.accounts[i].secret = ref
            ledger.accounts[i].fingerprint = value.fingerprint
            ledger.accounts[i].generation += 1
            ledger.accounts[i].plan = value.plan
        } else {
            let ref = try secrets.put(value.data)
            let mask: String
            if let at = value.email.firstIndex(of: "@") { mask = String(value.email.prefix(2)) + "***" + value.email[at...] } else { mask = "未提供邮箱" }
            ledger.accounts.append(Account(identity: value.identity, alias: String((alias ?? "账号 \(ledger.accounts.count + 1)").prefix(40)), maskedEmail: mask, plan: value.plan, secret: ref, generation: 1, fingerprint: value.fingerprint, knownFingerprints: [value.fingerprint], secretHistory: [ref], mainBaseline: nil, continuityVerifiedVersion: nil, quota: nil, quotaError: nil))
        }
    }
    /// A disk credential can advance the vault only when the vault still equals the last observed disk baseline.
    private func reconcile(_ disk: Credential, ledger: inout Ledger) throws {
        let i = try accountIndex(disk.identity.key, in: ledger), a = ledger.accounts[i]
        if disk.fingerprint == a.fingerprint { ledger.accounts[i].mainBaseline = disk.fingerprint; return }
        if a.knownFingerprints.contains(disk.fingerprint) {
            // Disk has an older generation. Keep the newer vault secret (Q01).
            ledger.accounts[i].mainBaseline = disk.fingerprint; return
        }
        guard a.mainBaseline == a.fingerprint else { throw SwitcherError.conflict }
        try put(disk, into: &ledger)
        ledger.accounts[i].mainBaseline = disk.fingerprint
    }
    public func importCurrent(alias: String? = nil) throws {
        try lock.withLock {
            try environmentAllowed()
            var l = try readLedger(); guard l.transaction == nil else { throw SwitcherError.pendingRecovery }
            let c = try mainCredential()
            if l.accounts.contains(where: { $0.id == c.identity.key }) { try reconcile(c, ledger: &l) }
            else { try put(c, into: &l, alias: alias); l.accounts[try accountIndex(c.identity.key, in: l)].mainBaseline = c.fingerprint }
            guard try mainCredential().fingerprint == c.fingerprint else { throw SwitcherError.conflict }
            l.lastEvent = "已导入当前账号"; try save(l)
        }
    }
    /// Only official isolated login should call this in the app. CAS spans the entire asynchronous login.
    public func importAuthorized(_ value: Credential, expectedKey: String? = nil, expectedGeneration: Int? = nil, alias: String? = nil) throws {
        try lock.withLock {
            var l = try readLedger(); guard l.transaction == nil else { throw SwitcherError.pendingRecovery }
            if let expectedKey, expectedKey != value.identity.key { throw SwitcherError.identityMismatch }
            if let i = l.accounts.firstIndex(where: { $0.id == value.identity.key }) {
                guard expectedGeneration == l.accounts[i].generation else { throw SwitcherError.conflict }
                let currentIdentity = try mainCredential().identity
                if currentIdentity == value.identity { try writersStopped() }
            } else if expectedGeneration != nil { throw SwitcherError.conflict }
            try put(value, into: &l, alias: alias); l.lastEvent = "官方登录凭据已存入钥匙串"; try save(l)
        }
    }
    public func rename(_ key: String, alias: String) throws {
        try lock.withLock { var l = try readLedger(); let i = try accountIndex(key, in: l); l.accounts[i].alias = String(alias.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)); try save(l) }
    }
    public func markContinuity(_ key: String, version: String, available: Bool = true) throws {
        try lock.withLock {
            var l = try readLedger(); guard l.transaction == nil else { throw SwitcherError.pendingRecovery }
            // This records the user's explicit observation of the current desktop, not a machine inference.
            guard try mainCredential().identity.key == key else { throw SwitcherError.identityMismatch }
            let i = try accountIndex(key, in: l)
            l.accounts[i].continuityVerifiedVersion = available ? version : nil
            l.accounts[i].continuityUnavailableVersion = available ? nil : version
            l.lastEvent = available ? "已记录当前账号连续性可用" : "已记录当前账号连续性不可用"
            try save(l)
        }
    }
    public func delete(_ key: String) throws {
        try lock.withLock {
            var l = try readLedger(); guard l.transaction == nil else { throw SwitcherError.pendingRecovery }
            guard try mainCredential().identity.key != key else { throw SwitcherError.conflict }
            let i = try accountIndex(key, in: l), refs = l.accounts[i].secretHistory
            l.accounts.remove(at: i); l.pendingSecretDeletes = (l.pendingSecretDeletes ?? []) + refs
            l.lastEvent = "已移除账号，正在清理其钥匙串凭据"; try save(l)
            // Delete only after a confirmed metadata commit. A failure leaves a harmless orphan, not a dangling reference.
            try cleanupDeletedSecretsUnlocked(&l)
        }
    }
    private func cleanupDeletedSecretsUnlocked(_ ledger: inout Ledger) throws {
        for ref in ledger.pendingSecretDeletes ?? [] {
            try secrets.remove(ref)
            ledger.pendingSecretDeletes?.removeAll { $0 == ref }
            try save(ledger)
        }
        ledger.lastEvent = "已清理删除账号的钥匙串凭据"; try save(ledger)
    }
    public func cleanupDeletedSecrets() throws {
        try lock.withLock { var l = try readLedger(); try cleanupDeletedSecretsUnlocked(&l) }
    }
    public func updateQuota(_ key: String, fingerprint: String, quota: Quota?, error: SwitcherError?) throws {
        try lock.withLock {
            var l = try readLedger(); let i = try accountIndex(key, in: l)
            guard l.accounts[i].fingerprint == fingerprint else { throw SwitcherError.conflict }
            if let quota { l.accounts[i].quota = quota; l.accounts[i].quotaError = nil; l.accounts[i].quotaRetryAfter = nil }
            else { l.accounts[i].quota?.stale = true; l.accounts[i].quotaError = (error ?? .unknownQuota).rawValue; l.accounts[i].quotaRetryAfter = Date().addingTimeInterval(error == .rateLimited ? 300 : 60) }
            l.lastEvent = quota == nil ? "额度查询失败，已保留旧值" : "额度已更新"
            try save(l)
        }
    }
    private func replaceMain(_ value: Credential, expected: String, cancellation: Cancellation? = nil) throws {
        try SecureIO.write(value.data, to: authURL, preCommit: {
            try self.fault?("authBeforeRename")
            if cancellation?.isCancelled == true { throw SwitcherError.cancelled }
            try self.writersStopped()
            guard try self.mainCredential().fingerprint == expected else { throw SwitcherError.conflict }
        }, afterRename: { try self.fault?("authAfterRename") })
    }
    public func switchAccount(_ key: String, policy: SwitchPolicy, cancellation: Cancellation? = nil, validateTarget: (Credential) throws -> Void) throws {
        try lock.withLock {
            try environmentAllowed(); try writersStopped()
            var l = try readLedger(); guard l.transaction == nil else { throw SwitcherError.pendingRecovery }
            let disk = try mainCredential()
            guard disk.identity.key != key else { return } // defer always releases flock (N01).
            let i = try accountIndex(key, in: l)
            guard policy.allowCapabilityTrial || l.accounts[i].continuityVerifiedVersion == policy.version else { throw SwitcherError.capabilityUnknown }
            let target = try credential(l.accounts[i]); try validateTarget(target)
            if cancellation?.isCancelled == true { throw SwitcherError.cancelled }
            try reconcile(disk, ledger: &l)
            let source = l.accounts[try accountIndex(disk.identity.key, in: l)]
            l.transaction = Transaction(id: UUID().uuidString, source: source.id, target: key, sourceSecret: source.secret, sourceDiskFingerprint: disk.fingerprint, targetFingerprint: target.fingerprint, phase: .prepared, started: Date())
            l.lastEvent = "切换已准备"; try save(l); try fault?("prepared")
            do {
                try replaceMain(target, expected: disk.fingerprint, cancellation: cancellation)
                try fault?("authWritten")
                l.transaction?.phase = .written
                l.accounts[i].mainBaseline = target.fingerprint
                l.lastEvent = "凭据已切换，等待启动和桌面身份确认"; try save(l)
            } catch {
                // Any ambiguous state keeps the journal. No automatic cancel or automatic rollback.
                l.transaction?.phase = .recoveryRequired; l.lastEvent = "切换中断，等待恢复检查"; try? save(l)
                throw error
            }
        }
    }
    public func noteLaunched() throws {
        try lock.withLock { var l = try readLedger(); guard l.transaction != nil else { return }; l.transaction?.phase = .pendingConfirmation; try save(l) }
    }
    public func prepareLaunch(cancellation: Cancellation? = nil) throws {
        try lock.withLock {
            if cancellation?.isCancelled == true { throw SwitcherError.cancelled }
            try environmentAllowed(); try writersStopped()
            let l = try readLedger(); guard let tx = l.transaction else { throw SwitcherError.pendingRecovery }
            guard try mainCredential().fingerprint == tx.targetFingerprint else { throw SwitcherError.conflict }
            // Cancellation after the auth commit preserves the journal for explicit confirmation/recovery.
            if cancellation?.isCancelled == true { throw SwitcherError.cancelled }
        }
    }
    /// Explicit human resolution: preserve an externally selected desktop account without writing auth.
    public func acceptExternalDesktop(expectedKey: String) throws {
        try lock.withLock {
            var l = try readLedger(); guard l.transaction != nil else { throw SwitcherError.pendingRecovery }
            let disk = try mainCredential(); guard disk.identity.key == expectedKey else { throw SwitcherError.identityMismatch }
            if l.accounts.contains(where: { $0.id == expectedKey }) {
                do { try reconcile(disk, ledger: &l) }
                catch SwitcherError.conflict {
                    // Explicit human choice of the working desktop resolves a fork. All previous secrets remain archived.
                    try put(disk, into: &l)
                    l.accounts[try accountIndex(expectedKey, in: l)].mainBaseline = disk.fingerprint
                }
            }
            else { try put(disk, into: &l); l.accounts[try accountIndex(expectedKey, in: l)].mainBaseline = disk.fingerprint }
            guard try mainCredential().fingerprint == disk.fingerprint else { throw SwitcherError.conflict }
            l.transaction = nil; l.lastEvent = "用户确认保留外部桌面账号，原切换已结束"; try save(l)
        }
    }
    public func confirmDesktop(targetKey: String, continuityObserved: Bool, version: String) throws {
        try lock.withLock {
            var l = try readLedger(); guard let tx = l.transaction, tx.target == targetKey else { throw SwitcherError.identityMismatch }
            let disk = try mainCredential(); guard disk.identity.key == tx.target else { throw SwitcherError.identityMismatch }
            // This may capture a refresh performed by the newly launched desktop.
            let i = try accountIndex(tx.target, in: l)
            l.accounts[i].mainBaseline = tx.targetFingerprint
            try reconcile(disk, ledger: &l)
            if continuityObserved { l.accounts[i].continuityVerifiedVersion = version; l.accounts[i].continuityUnavailableVersion = nil }
            l.transaction = nil; l.lastEvent = "用户已确认桌面账号及工作区"; try save(l)
        }
    }
    /// Recovery and rollback use the exact same lock as switch/import/refresh (Q02/Q03).
    public func recover(rollback: Bool) throws {
        try lock.withLock {
            try environmentAllowed(); try writersStopped()
            var l = try readLedger(); guard let tx = l.transaction else { return }
            let disk = try mainCredential()
            if disk.fingerprint == tx.sourceDiskFingerprint || disk.fingerprint == tx.rollbackFingerprint {
                l.transaction = nil; l.lastEvent = "确认原凭据完整，已结束未提交切换"; try save(l); return
            }
            guard disk.identity.key == tx.target else { throw SwitcherError.conflict }
            if !rollback { throw SwitcherError.pendingRecovery }
            let i = try accountIndex(tx.target, in: l)
            l.accounts[i].mainBaseline = tx.targetFingerprint
            try reconcile(disk, ledger: &l)
            let source = try credential(l.accounts[accountIndex(tx.source, in: l)])
            l.transaction?.phase = .recoveryRequired; l.transaction?.rollbackFingerprint = source.fingerprint
            l.lastEvent = "准备回退，已保存目标账号最新凭据"; try save(l)
            try replaceMain(source, expected: disk.fingerprint)
            try fault?("rollbackWritten")
            l.accounts[try accountIndex(tx.source, in: l)].mainBaseline = source.fingerprint
            l.transaction = nil; l.lastEvent = "已回退到原账号，等待在 Codex 中确认"; try save(l)
        }
    }
    public func diagnostics() throws -> Data {
        try lock.withLock {
            let l = try readLedger()
            // Allowlist only: never export identity, paths, email, hashes or keychain references.
            let accounts: [[String: Any]] = l.accounts.enumerated().map { n, a in
                ["ordinal": n + 1, "generation": a.generation, "hasQuota": a.quota != nil, "quotaStale": a.quota?.isStale ?? true, "continuityChecked": a.continuityVerifiedVersion != nil]
            }
            return try canonical(["schema": 1, "appVersion": "0.4.2", "accountCount": accounts.count, "accounts": accounts, "transactionPhase": l.transaction?.phase.rawValue ?? "none"])
        }
    }
}
