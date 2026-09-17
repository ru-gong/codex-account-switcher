import SwiftUI
import AppKit
@preconcurrency import SwitcherCore

@MainActor final class Model: ObservableObject {
    @Published var ledger = Ledger()
    @Published var current: String?
    @Published var message = "就绪"
    @Published var busy = false
    @Published var selection: String?
    @Published var writers: [Writer] = []
    @Published var alias = ""
    @Published var desktopConfirmed = false
    @Published var continuityConfirmed = false
    @Published var autoQuota: Bool {
        didSet {
            if !demo { quotaPreferences.automatic = autoQuota }
            if autoQuota { autoRefresh() }
        }
    }
    @Published var authorizationAccount: String?
    @Published var compatibilityError: SwitcherError?
    private let credentialStore = KeychainStore()
    private var sessionObservers: [NSObjectProtocol] = []
    private var quotaTimer: Timer?
    private let quotaPreferences = QuotaRefreshPreferences()
    private var quotaSchedule = QuotaRefreshSchedule()
    private var observedHostVersion: String?
    let demo: Bool
    let trial: Bool
    let host = HostConfiguration()
    var engine: Engine?
    private var cancellation = Cancellation()
    private let queue = DispatchQueue(label: "local.codex-switcher.worker", qos: .userInitiated)
    var version: String { demo ? "演示环境" : host.version }
    var selected: Account? { ledger.accounts.first { $0.id == selection } }
    var currentAlias: String { ledger.accounts.first { $0.id == current }?.alias ?? "未导入" }
    var compatibilityNotice: String? {
        guard compatibilityError == .unsupportedVersion else { return nil }
        return "Codex \(host.version) 未通过兼容检查，额度查询与切换已暂停。请更新切换台。"
    }
    var releaseLabel: String { Bundle.main.object(forInfoDictionaryKey: "SwitcherReleaseChannel") as? String == "release" ? "0.4.4" : "0.4.4 候选" }

    init() {
        demo = CommandLine.arguments.contains("--demo")
        trial = CommandLine.arguments.contains("--e1") || CommandLine.arguments.contains("--live-acceptance")
        autoQuota = demo ? false : quotaPreferences.automatic
        if !demo, let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        do {
            if demo { engine = try Demo.make(); message = "演示模式 · 所有账号与额度均为模拟数据" }
            else {
                let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexAccountSwitcher")
                let host = self.host
                engine = try Engine(root: root, authURL: host.home.appendingPathComponent("auth.json"), secrets: credentialStore, writersStopped: { try host.requireStopped() }, environmentAllowed: { try host.validate() })
                message = "就绪"
            }
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
                let store = credentialStore
                sessionObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: nil) { _ in store.clearSessionCache() })
            }
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
                sessionObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.autoRefresh() }
                })
            }
            refresh()
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.autoRefresh() }
            }
            quotaTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            autoRefresh()
        } catch { message = safe(error) }
    }
    func safe(_ error: Error) -> String { (error as? SwitcherError)?.localizedDescription ?? "操作未完成，请检查路径、权限和交付说明。" }
    func refresh() {
        guard let engine else { return }
        do {
            refreshCompatibility()
            let previousIdentity = current, previousTransaction = ledger.transaction?.id
            ledger = try engine.snapshot(); current = try? engine.mainCredential().identity.key
            if previousIdentity != current || previousTransaction != ledger.transaction?.id { desktopConfirmed = false; continuityConfirmed = false }
            if selection == nil { selection = current ?? ledger.accounts.first?.id }
            writers = demo ? [] : (try host.writers())
        } catch { message = safe(error) }
    }
    private func refreshCompatibility() {
        guard !demo else { return }
        let version = host.version
        if observedHostVersion != version { compatibilityError = nil; observedHostVersion = version }
        if !HostConfiguration.testedVersions.contains(version) { compatibilityError = .unsupportedVersion }
    }
    func perform(_ label: String, successMessage: String? = nil, completion: ((Error?) -> Void)? = nil, _ operation: @escaping (Engine, Cancellation) throws -> Void) {
        guard !busy, let engine else { return }
        busy = true; message = label; cancellation = Cancellation(); let token = cancellation
        queue.async {
            let error: Error?
            do { try operation(engine, token); error = nil } catch let e { error = e }
            DispatchQueue.main.async {
                self.busy = false; self.refresh()
                self.message = error.map { self.safe($0) } ?? successMessage ?? self.ledger.lastEvent
                if error as? SwitcherError == .keychainAuthorizationRequired { self.authorizationAccount = self.selection ?? self.current }
                if error as? SwitcherError == .unsupportedVersion { self.compatibilityError = .unsupportedVersion }
                completion?(error)
            }
        }
    }
    func authorizeSelected(_ id: String? = nil) {
        guard let key = id ?? authorizationAccount ?? selection,
              let account = ledger.accounts.first(where: { $0.id == key }) else { return }
        let store = credentialStore
        perform("为此账号请求一次系统授权…", successMessage: "已授权", completion: { error in
            if error == nil {
                self.authorizationAccount = nil
                self.refreshQuota(trigger: .authorized(account.id))
            } else if error as? SwitcherError == .keychainAuthorizationRequired {
                self.authorizationAccount = account.id
            }
        }) { engine, _ in
            _ = try store.withUserAuthorization { try engine.credentialForProbe(account.id) }
        }
    }
    func importCurrent() { perform("读取当前凭据…") { engine, _ in try engine.importCurrent() } }
    func login(existing: Account? = nil) {
        if demo { message = "演示模式不发起真实登录。"; return }
        if ledger.transaction != nil { message = SwitcherError.pendingRecovery.localizedDescription; return }
        if let existing, existing.id == current && !writers.isEmpty { message = SwitcherError.writersRunning.localizedDescription; return }
        let host = self.host
        perform("正在等待官方浏览器登录；可随时取消…") { engine, token in
            try host.validateVersion()
            let credential = try AppServer.login(binary: host.binary, cancellation: token) { url in DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
            if token.isCancelled { throw SwitcherError.cancelled }
            try engine.importAuthorized(credential, expectedKey: existing?.id, expectedGeneration: existing?.generation)
        }
    }
    func refreshQuota(trigger: QuotaRefreshTrigger = .manual) {
        guard !busy else { return }
        if demo { message = "演示额度已就绪（模拟数据）。"; return }
        refreshCompatibility()
        guard HostConfiguration.testedVersions.contains(host.version) else {
            if trigger != .automatic { message = compatibilityNotice ?? SwitcherError.unsupportedVersion.localizedDescription }
            return
        }
        guard let engine else { return }
        let accounts: [Account]
        do { accounts = try engine.snapshot().accounts } catch { message = safe(error); return }
        let due = quotaSchedule.accountsDue(accounts, trigger: trigger, now: Date())
        guard !due.isEmpty else {
            if trigger != .automatic { message = accounts.isEmpty ? "请先添加账号" : "请稍后刷新；等待请求间隔或服务重试时间。" }
            return
        }
        quotaSchedule.started(at: Date())
        let host = self.host
        var report: QuotaRefreshReport?
        perform("查询额度…", completion: { error in
            if error == nil, let report {
                self.compatibilityError = nil
                self.message = report.message
                if trigger == .manual && due.count < accounts.count { self.message += "；其余账号等待重试时间" }
            }
        }) { engine, token in
            report = try QuotaRefresh.run(engine: engine, accounts: due, cancellation: token, validateEnvironment: { try host.validateVersion() }) { credential, token in
                try AppServer.quota(binary: host.binary, credential: credential, cancellation: token)
            }
        }
    }
    func switchToSelected() {
        guard let selected else { return }
        let host = self.host, demo = self.demo, trial = self.trial
        desktopConfirmed = false; continuityConfirmed = false
        perform("检查环境及目标账号…") { engine, token in
            try engine.switchAccount(selected.id, policy: SwitchPolicy(version: host.version, allowCapabilityTrial: demo || trial), cancellation: token) { credential in
                if !demo { _ = try AppServer.quota(binary: host.binary, credential: credential, cancellation: token) }
            }
            if try engine.snapshot().transaction != nil {
                if !demo {
                    try engine.prepareLaunch(cancellation: token)
                    let semaphore = DispatchSemaphore(value: 0)
                    var launchError: Error?
                    DispatchQueue.main.async {
                        // The request may have been cancelled while this main-queue block was waiting.
                        guard !token.isCancelled else { launchError = SwitcherError.cancelled; semaphore.signal(); return }
                        NSWorkspace.shared.openApplication(at: host.appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in launchError = error; semaphore.signal() }
                    }
                    guard semaphore.wait(timeout: .now() + 25) == .success else { throw SwitcherError.timeout }
                    if let launchError { throw (launchError as? SwitcherError) ?? SwitcherError.io }
                }
                try engine.noteLaunched()
            }
        }
    }
    func confirm() {
        guard desktopConfirmed, let tx = ledger.transaction else { return }
        let observed = continuityConfirmed, version = host.version
        perform("记录桌面确认…") { engine, _ in try engine.confirmDesktop(targetKey: tx.target, continuityObserved: observed, version: version) }
    }
    func recover() { perform("核对现场并回退…") { engine, _ in try engine.recover(rollback: true) } }
    func keepExternal() {
        guard desktopConfirmed, let current else { return }
        perform("保留已经人工确认的外部账号…") { engine, _ in try engine.acceptExternalDesktop(expectedKey: current) }
    }
    func markContinuity() {
        guard continuityConfirmed, let current else { return }; let version = host.version
        perform("保存人工核验记录…") { engine, _ in try engine.markContinuity(current, version: version) }
    }
    func markUnavailable() {
        guard let current else { return }; let version = host.version
        perform("记录不可用状态…") { engine, _ in try engine.markContinuity(current, version: version, available: false) }
    }
    func rename() { guard let selected else { return }; let alias = self.alias; perform("修改别名…") { engine, _ in try engine.rename(selected.id, alias: alias) } }
    func deleteSelected() { guard let selected else { return }; selection = current; perform("删除非当前账号…") { engine, _ in try engine.delete(selected.id) } }
    func cleanupSecrets() { perform("重试清理已删除账号的钥匙串凭据…") { engine, _ in try engine.cleanupDeletedSecrets() } }
    func cancel() { cancellation.cancel(); message = "正在取消；若凭据已写入，会保留待确认事务，已开始的系统启动不会被强制终止。" }
    func export() {
        guard let engine else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "switcher-diagnostics.json"; panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do { try engine.diagnostics().write(to: url, options: .atomic); message = "已导出脱敏诊断（不含账号身份、令牌或邮箱）。" } catch { message = safe(error) }
        }
    }
    func help() {
        if let url = Bundle.main.url(forResource: "README", withExtension: "md") { NSWorkspace.shared.open(url) }
        else { message = "请阅读项目目录内 README.md 和 docs/真实验收操作说明.md。" }
    }
    func autoRefresh() { if autoQuota && !demo { refreshQuota(trigger: .automatic) } }
}

struct MainView: View {
    @ObservedObject var model: Model
    @State private var advanced = false
    @State private var acceptanceTools = false
    @State private var deleteAccount: Account?
    @State private var renameAccount: Account?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "person.2.fill").foregroundStyle(.teal)
                Text("Codex 账号").font(.headline)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button { model.refreshQuota() } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新额度").accessibilityLabel("刷新额度").disabled(model.busy)
                Button { model.login() } label: { Image(systemName: "plus") }
                    .help("添加账号").accessibilityLabel("添加账号").disabled(model.busy || model.ledger.transaction != nil)
            }.buttonStyle(.borderless).padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.demo { Text("演示 · 假账号与假额度").font(.caption).foregroundStyle(.secondary) }
                    if let notice = model.compatibilityNotice {
                        Text(notice).font(.callout).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let tx = model.ledger.transaction { pendingCard(tx) }
                    if model.ledger.accounts.isEmpty {
                        VStack(spacing: 12) {
                            Text("添加你的 Codex 账号").font(.headline)
                            Text("先保存当前账号，再添加备用账号。").font(.callout).foregroundStyle(.secondary)
                            Button("保存当前账号") { model.importCurrent() }.buttonStyle(.borderedProminent)
                        }.frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                    ForEach(model.ledger.accounts) { account in accountRow(account) }
                    if let id = model.authorizationAccount, let account = model.ledger.accounts.first(where: { $0.id == id }), account.quotaError != SwitcherError.keychainAuthorizationRequired.rawValue {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(account.alias) 需要授权").font(.callout.bold())
                            Text("后台已停止读取。只有点击下面的按钮才会出现系统授权窗口。").font(.caption).foregroundStyle(.secondary)
                            Button("授权此账号") { model.authorizeSelected() }.disabled(model.busy)
                        }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if !model.demo && !model.writers.isEmpty {
                        Text("切换前请退出 Codex 及共享登录的 CLI / IDE。切换完成后会自动打开 Codex。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("更多设置", isExpanded: $advanced) { advancedSettings.padding(.top, 10) }
                        .font(.callout).padding(.top, 2)
                }.padding(14)
            }.frame(maxHeight: .infinity)
            Divider()
            HStack(alignment: .top, spacing: 8) {
                Text(model.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if model.busy { Button("取消") { model.cancel() }.font(.caption) }
            }.padding(12)
        }
        .frame(width: 390, height: advanced ? 670 : 510)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if !model.busy { model.refresh(); model.autoRefresh() } }
        .alert("删除保存的账号？", isPresented: Binding(get: { deleteAccount != nil }, set: { if !$0 { deleteAccount = nil } })) {
            Button("取消", role: .cancel) { deleteAccount = nil }
            Button("删除", role: .destructive) {
                if let account = deleteAccount { model.selection = account.id; model.deleteSelected() }
                deleteAccount = nil
            }
        } message: { Text("只删除切换台中该账号的授权，不删除 Codex 任务或浏览器数据。") }
        .alert("修改账号名称", isPresented: Binding(get: { renameAccount != nil }, set: { if !$0 { renameAccount = nil } })) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renameAccount = nil }
            Button("保存") {
                if let account = renameAccount { model.selection = account.id; model.alias = renameText; model.rename() }
                renameAccount = nil
            }.disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func accountRow(_ account: Account) -> some View {
        let isCurrent = account.id == model.current
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(account.alias).font(.callout.weight(.semibold)).lineLimit(1)
                        if isCurrent { Text(model.ledger.transaction == nil ? "当前" : "待确认").font(.caption2).foregroundStyle(.teal) }
                    }
                    Text(account.maskedEmail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if !isCurrent {
                    Button("切换") { model.selection = account.id; model.switchToSelected() }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(model.busy || model.ledger.transaction != nil || model.compatibilityNotice != nil)
                }
                Menu {
                    Button("修改名称…") { renameAccount = account; renameText = account.alias }
                    Button("重新登录") { model.login(existing: account) }
                    Button("授权此账号") { model.authorizeSelected(account.id) }
                    Divider()
                    Button("删除账号…", role: .destructive) { deleteAccount = account }.disabled(isCurrent || model.ledger.transaction != nil)
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.busy)
                .accessibilityLabel("\(account.alias)的更多操作")
            }
            HStack {
                Text(account.plan?.capitalized ?? "套餐未知")
                Spacer()
                Text(remaining(account)).monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary)
            if let window = account.quota?.primary { ProgressView(value: window.remaining, total: 100).tint(.teal) }
            let status = QuotaRefresh.status(for: account, environmentError: model.compatibilityError)
            if !status.isEmpty {
                HStack {
                    Text(status).font(.caption2).foregroundStyle(.orange)
                    Spacer(minLength: 0)
                    if account.quotaError == SwitcherError.keychainAuthorizationRequired.rawValue {
                        Button("授权") { model.authorizeSelected(account.id) }.controlSize(.small).disabled(model.busy)
                    }
                }
            }
            if let fetched = account.quota?.fetchedAt {
                HStack(spacing: 3) {
                    Text("上次更新")
                    Text(fetched, style: .relative)
                    Text("前")
                }.font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(12)
            .background(isCurrent ? Color.teal.opacity(0.07) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func remaining(_ account: Account) -> String {
        guard let q = account.quota else { return account.quotaError == "keychainAuthorizationRequired" ? "待授权" : "额度待查询" }
        let values = [q.primary, q.secondary].compactMap { $0 }.map { "\(duration($0.windowDurationMins)) \(Int($0.remaining))%" }
        return (q.isStale ? "旧值 · " : "剩余 · ") + values.joined(separator: " / ")
    }

    private func duration(_ minutes: Int) -> String {
        if minutes % 1440 == 0 { return "\(minutes / 1440)天" }
        if minutes % 60 == 0 { return "\(minutes / 60)小时" }
        return "\(minutes)分钟"
    }

    private func pendingCard(_ tx: SwitcherCore.Transaction) -> some View {
        let target = model.ledger.accounts.first { $0.id == tx.target }?.alias ?? "目标账号"
        return VStack(alignment: .leading, spacing: 8) {
            Text("确认已切到 \(target)").font(.callout.weight(.semibold))
            Text("在 Codex 中核对账号和工作区后，点击确认。").font(.caption).foregroundStyle(.secondary)
            Button("我已核对账号与工作区") {
                model.desktopConfirmed = true
                model.continuityConfirmed = false
                model.confirm()
            }.buttonStyle(.borderedProminent).tint(.teal)
                .disabled(model.busy || model.current != tx.target)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("自动刷新额度（每 15 分钟）", isOn: $model.autoQuota)
            Text("需要钥匙串授权时停止后台读取，不弹密码。休眠或退出登录时清除本次凭据缓存。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("检查状态") { model.refresh() }.disabled(model.busy)
                Button("保存当前账号") { model.importCurrent() }.disabled(model.busy || model.ledger.transaction != nil)
            }
            if model.ledger.transaction != nil {
                Button("退出 Codex 后回退") { model.recover() }.disabled(model.busy)
                if let tx = model.ledger.transaction, model.current != tx.target {
                    Toggle("我已核对当前外部账号", isOn: $model.desktopConfirmed)
                    Button("保留当前账号并结束切换") { model.keepExternal() }.disabled(model.busy || !model.desktopConfirmed)
                }
            } else if model.trial && model.current != nil {
                DisclosureGroup("验收工具", isExpanded: $acceptanceTools) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("仅记录本次人工观察，不监测或控制 Computer History。").font(.caption).foregroundStyle(.secondary)
                        if let account = model.ledger.accounts.first(where: { $0.id == model.current }), account.continuityVerifiedVersion == model.host.version {
                            Text("当前 Codex 版本已保存人工核验记录").font(.caption)
                        }
                        Toggle("我已完成本次连续性检查", isOn: $model.continuityConfirmed)
                        Button("保存观察结果") { model.markContinuity() }.disabled(model.busy || !model.continuityConfirmed)
                        Button("记录连续性不可用") { model.markUnavailable() }.disabled(model.busy)
                    }.padding(.top, 8)
                }
            }
            if !(model.ledger.pendingSecretDeletes ?? []).isEmpty {
                Button("重试凭据清理") { model.cleanupSecrets() }.disabled(model.busy)
            }
            HStack { Button("诊断") { model.export() }; Button("说明") { model.help() }; Spacer(); Button("退出") { NSApp.terminate(nil) } }.disabled(model.busy)
            Text("\(model.releaseLabel) · Codex \(model.version)").font(.caption2).foregroundStyle(.secondary)
            if model.trial { Text("验收模式：完整连续性仍需实际验证。").font(.caption2).foregroundStyle(.orange) }
        }.buttonStyle(.borderless)
    }
}

@main struct SwitcherApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        MenuBarExtra(model.demo ? "演示账号" : model.currentAlias, systemImage: "person.2") {
            MainView(model: model)
        }.menuBarExtraStyle(.window)
    }
}
