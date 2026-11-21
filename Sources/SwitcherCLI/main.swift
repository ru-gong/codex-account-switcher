import Foundation
import SwitcherCore
import Darwin
import AppKit

do {
    let args = Array(CommandLine.arguments.dropFirst())
    switch args.first {
    case "delete-account", "refresh-display-names":
        let host = HostConfiguration()
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexAccountSwitcher")
        let engine = try Engine(root: root, authURL: host.home.appendingPathComponent("auth.json"), secrets: KeychainStore(), writersStopped: { try host.requireStopped() }, environmentAllowed: { try host.validate() })
        let before = try engine.mainCredential().fingerprint
        if args.first == "delete-account" {
            guard args.count == 2 else { throw SwitcherError.missingAccount }
            let matches = try engine.snapshot().accounts.filter { $0.alias == args[1] }
            guard matches.count == 1 else { throw SwitcherError.missingAccount }
            try engine.delete(matches[0].id)
            guard try !engine.snapshot().accounts.contains(where: { $0.id == matches[0].id }) else { throw SwitcherError.conflict }
            print("PASS: selected saved account and its Keychain credentials removed")
        } else {
            var updated = 0, blocked = 0
            for account in try engine.snapshot().accounts {
                do { _ = try engine.credentialForQuota(account); updated += 1 }
                catch { blocked += 1; print("Display metadata unavailable: \((error as? SwitcherError)?.rawValue ?? "internal")") }
            }
            print("Display metadata: updated=\(updated); blocked=\(blocked)")
        }
        guard try engine.mainCredential().fingerprint == before else { throw SwitcherError.conflict }
        print("Main auth unchanged: true")
    case "prepare-live", "sync-current", "login-new", "probe-live", "live-status":
        let host = HostConfiguration(); try host.validate()
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexAccountSwitcher")
        let engine = try Engine(root: root, authURL: host.home.appendingPathComponent("auth.json"), secrets: KeychainStore(), writersStopped: { try host.requireStopped() }, environmentAllowed: { try host.validate() })
        let before = try engine.mainCredential()
        if args.first == "prepare-live" {
            let alias = args.count > 1 ? args[1] : "当前账号"
            try engine.importCurrent(alias: alias)
            guard try engine.credentialForProbe(before.identity.key).fingerprint == before.fingerprint else { throw SwitcherError.conflict }
            guard try engine.mainCredential().fingerprint == before.fingerprint else { throw SwitcherError.conflict }
            print("PASS: current account imported to Keychain; main auth unchanged; no switch performed")
        } else if args.first == "sync-current" {
            let account = try engine.snapshot().accounts.first(where: { $0.id == before.identity.key })
            guard let account else { throw SwitcherError.missingAccount }
            let quota = try AppServer.quota(binary: host.binary, credential: before, cancellation: Cancellation())
            try engine.saveValidatedCurrent(before, expectedGeneration: account.generation)
            try engine.updateQuota(account.id, fingerprint: before.fingerprint, quota: quota, error: nil)
            guard try engine.mainCredential().fingerprint == before.fingerprint else { throw SwitcherError.conflict }
            print("PASS: validated current login saved with prior generations retained; quota updated; main auth unchanged")
        } else if args.first == "login-new" {
            print("WAITING_FOR_LOGIN: 请在官方浏览器页面登录新账号 B；保持当前 Codex 打开。")
            fflush(stdout)
            let token = Cancellation()
            let credential = try AppServer.login(binary: host.binary, cancellation: token) { url in
                if NSWorkspace.shared.open(url) { print("LOGIN_PAGE_OPEN_REQUEST_ACCEPTED"); fflush(stdout) }
                else { token.cancel() }
            }
            guard credential.identity != before.identity else { throw SwitcherError.identityMismatch }
            try engine.importAuthorized(credential, alias: "B · 新账号")
            guard try engine.credentialForProbe(credential.identity.key).fingerprint == credential.fingerprint else { throw SwitcherError.conflict }
            print("PASS: distinct new account imported; no switch performed")
            if try engine.mainCredential().fingerprint != before.fingerprint { print("NOTICE: main auth changed externally during login; inspect before switching") }
        } else if args.first == "probe-live" {
            let accounts = try engine.snapshot().accounts
            let report = try QuotaRefresh.run(engine: engine, accounts: accounts, cancellation: Cancellation()) { credential, cancellation in
                try AppServer.quota(binary: host.binary, credential: credential, cancellation: cancellation)
            }
            print("Quota: updated=\(report.updated); authorizationRequired=\(report.needsAuthorization); failed=\(report.failed)")
            for (n, account) in try engine.snapshot().accounts.enumerated() {
                print("Account \(n + 1): quotaError=\(account.quotaError ?? "none"); primaryReset=\(account.quota?.primary?.resetsAt != nil); secondaryReset=\(account.quota?.secondary?.resetsAt != nil)")
            }
            let unchanged = try engine.mainCredential().fingerprint == before.fingerprint
            print("Main auth unchanged: \(unchanged)")
            if report.failed > 0 || report.needsAuthorization > 0 || !unchanged { exit(1) }
        } else {
            let ledger = try engine.snapshot()
            print("Accounts: \(ledger.accounts.count); pending transaction: \(ledger.transaction != nil)")
            for (n, a) in ledger.accounts.enumerated() { print("Account \(n + 1): current=\(a.id == before.identity.key); generation=\(a.generation); quotaError=\(a.quotaError ?? "none")") }
        }
    case "probe-current":
        let host = HostConfiguration(); try host.validate()
        let authURL = host.home.appendingPathComponent("auth.json")
        let before = try Credential(data: SecureIO.read(authURL))
        let quota = try AppServer.quota(binary: host.binary, credential: before, cancellation: Cancellation())
        guard try Credential(data: SecureIO.read(authURL)).fingerprint == before.fingerprint else { throw SwitcherError.conflict }
        guard quota.primary != nil || quota.secondary != nil else { throw SwitcherError.unknownQuota }
        print("PASS: current account completed the isolated quota protocol check; main auth unchanged")
        print("Quota fields: primary=\(quota.primary != nil); primaryReset=\(quota.primary?.resetsAt != nil); secondary=\(quota.secondary != nil); secondaryReset=\(quota.secondary?.resetsAt != nil)")
    case "host-check":
        let host = HostConfiguration()
        print("Codex version: \(host.version)")
        print("Potential writers: \(try host.writers().count)")
        do { try host.validate(); print("Environment: eligible for further acceptance") } catch { print("Environment: \((error as? SwitcherError)?.rawValue ?? "unavailable")") }
    case "protocol-smoke":
        let host = HostConfiguration(); try host.validateVersion()
        let server = try AppServer(binary: host.binary); defer { server.close() }
        let result = try server.request("account/read", params: ["refreshToken": false])
        guard result["account"] is NSNull else { throw SwitcherError.protocolError }
        print("PASS: isolated official backend initialized; account=null; no login performed")
    case "keychain-smoke":
        let store = KeychainStore(service: "local.codex-account-switcher.acceptance." + UUID().uuidString)
        let data = Data("SYNTHETIC_KEYCHAIN_ACCEPTANCE".utf8)
        let reference = try store.put(data)
        defer { try? store.remove(reference) }
        store.clearSessionCache()
        guard try store.get(reference) == data else { throw SwitcherError.keychain }
        try store.remove(reference)
        do { _ = try store.get(reference); throw SwitcherError.conflict }
        catch SwitcherError.keychain { print("PASS: synthetic Keychain create/read/delete verified; no production credentials accessed") }
    case "demo-init":
        guard args.count == 2 else { throw SwitcherError.unsafePath }
        let engine = try Demo.make(root: URL(fileURLWithPath: args[1]).standardizedFileURL.resolvingSymlinksInPath())
        print("PASS: \(try engine.snapshot().accounts.count) synthetic accounts")
    case "demo-worker":
        guard args.count >= 4 else { throw SwitcherError.unsafePath }
        let root = URL(fileURLWithPath: args[1]).standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("SYNTHETIC-ONLY").path) else { throw SwitcherError.unsafePath }
        let engine = try Demo.make(root: root, seed: false)
        let action = args[2], name = args[3]
        if args.count > 4 {
            let point = args[4]
            engine.fault = { p in
                if p == point {
                    try SecureIO.write(Data("ready".utf8), to: root.appendingPathComponent("barrier"))
                    if args.count > 5 && args[5] == "crash" { _exit(86) }
                    let deadline = Date().addingTimeInterval(15)
                    while !FileManager.default.fileExists(atPath: root.appendingPathComponent("release").path) && Date() < deadline { usleep(10_000) }
                }
            }
        }
        switch action {
        case "import": try engine.importAuthorized(Demo.credential(name))
        case "switch": try engine.switchAccount(Demo.credential(name).identity.key, policy: SwitchPolicy(version: "demo", allowCapabilityTrial: true), validateTarget: { _ in })
        case "rollback": try engine.recover(rollback: true)
        case "inspect":
            let l = try engine.snapshot()
            print("accounts=\(l.accounts.count); transaction=\(l.transaction?.phase.rawValue ?? "none"); main=\(try engine.mainCredential().identity.user)")
        default: throw SwitcherError.protocolError
        }
        print("PASS")
    default:
        print("switcherctl host-check | protocol-smoke | probe-current | sync-current | prepare-live | login-new | probe-live | live-status | delete-account <exact-alias> | refresh-display-names | demo-init <empty-root> | demo-worker <synthetic-root> import|switch|rollback|inspect <A-D> [fault-point] [crash]")
    }
} catch {
    // Error descriptions from dependencies may contain credential material; emit allowlisted codes only.
    print("ERROR: \((error as? SwitcherError)?.rawValue ?? "internal")")
    exit(1)
}
