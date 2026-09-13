import Foundation
import Darwin
import Security

public struct Writer: Identifiable { public var id: Int32; public var name: String }
public struct HostConfiguration {
    public static let testedVersion = "26.908.40834 (8881)"
    public static let testedVersions: Set<String> = ["26.903.61454 (8378)", "26.903.71938 (8576)", testedVersion]
    public var appURL = URL(fileURLWithPath: "/Applications/Codex.app")
    public var home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) { self.home = home.standardizedFileURL.resolvingSymlinksInPath() }
    public var binary: URL { appURL.appendingPathComponent("Contents/Resources/codex") }
    public var version: String {
        guard let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")), let version = info["CFBundleShortVersionString"] as? String, let build = info["CFBundleVersion"] as? String else { return "未知" }
        return "\(version) (\(build))"
    }
    public func validateVersion() throws {
        guard Self.testedVersions.contains(version), FileManager.default.isExecutableFile(atPath: binary.path) else { throw SwitcherError.unsupportedVersion }
        // Pin the vendor as well as the displayed version before handing the backend any token.
        var code: SecStaticCode?, requirement: SecRequirement?
        let rule = "anchor apple generic and identifier \"com.openai.codex\" and certificate leaf[subject.OU] = \"2DC432GLL2\""
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement) == errSecSuccess else { throw SwitcherError.unsupportedVersion }
    }
    public func validate() throws {
        try validateVersion(); try SecureIO.validateDirectory(home)
        // Limited to explicitly selected default desktop home; a CLI override alone does not redirect Electron data.
        let desktopHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").resolvingSymlinksInPath()
        guard home == desktopHome else { throw SwitcherError.unsupportedBackend }
        for path in ["/etc/codex/managed_config.toml", "/etc/codex/requirements.toml", "/Library/Managed Preferences/com.openai.codex.plist"] {
            if FileManager.default.fileExists(atPath: path) { throw SwitcherError.unsupportedBackend }
        }
        let config = home.appendingPathComponent("config.toml")
        // Conservative extraction: do not infer file mode from a stale auth.json or attempt a TOML rewrite.
        let text = FileManager.default.fileExists(atPath: config.path) ? try String(contentsOf: config, encoding: .utf8) : ""
        // Supported backends use file storage by default; recheck this with each backend upgrade.
        // Explicit keyring/auto, managed configuration and ambiguous syntax still fail closed.
        guard Self.explicitFileBackend(text, defaultIsFile: true) else { throw SwitcherError.unsupportedBackend }
    }
    public static func explicitFileBackend(_ config: String, defaultIsFile: Bool = false) -> Bool {
        let restricted = ["forced_login_method", "forced_chatgpt_workspace_id", "chatgpt_base_url", "cli_auth_credentials_store", "profile"]
        var file = false, inTable = false, hits = 0
        for raw in config.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") { inTable = true }
            if line.contains("\"\"\"") || line.contains("'''") { return false }
            if line.contains("cli_auth_credentials_store") {
                hits += 1
                guard !inTable, line.range(of: #"^cli_auth_credentials_store\s*=\s*["']file["']\s*(#.*)?$"#, options: .regularExpression) != nil else { return false }
                file = true
            }
            for key in restricted where key != "cli_auth_credentials_store" {
                if line.range(of: "^[\\\"']?" + key + "[\\\"']?\\s*[.=]", options: .regularExpression) != nil { return false }
            }
        }
        return (file && hits == 1) || (hits == 0 && defaultIsFile)
    }
    public static func isWriterExecutable(_ path: String) -> Bool {
        // This exact bundled helper only handles crash reports. It can outlive the desktop.
        // Unknown helpers and all real Codex/CLI backends remain blocking writers.
        let crashReporter = #"^/Applications/Codex\.app/Contents/Frameworks/Codex Framework\.framework/Versions/[0-9]+(?:\.[0-9]+){3}/Helpers/browser_crashpad_handler$"#
        if path.range(of: crashReporter, options: .regularExpression) != nil { return false }
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return name == "codex" || name == "codex-app-server" || name == "codex-daemon" || path.contains("/Codex.app/") || path.contains("/Codex/codex-browser-app/")
    }
    public func writers() throws -> [Writer] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axo", "pid=,comm="]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { throw SwitcherError.writersRunning }
        return text.split(separator: "\n").compactMap { line in
            let fields = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, let pid = Int32(fields[0]), pid != getpid(), Self.isWriterExecutable(String(fields[1])) else { return nil }
            return Writer(id: pid, name: URL(fileURLWithPath: String(fields[1])).lastPathComponent)
        }
    }
    public func requireStopped() throws { guard try writers().isEmpty else { throw SwitcherError.writersRunning } }
}

public final class Cancellation {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func cancel() { lock.lock(); value = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
