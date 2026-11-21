import Foundation
import Darwin
import Security

public struct Writer: Identifiable { public var id: Int32; public var name: String }
public struct HostConfiguration {
    public static let testedVersion = "26.1021.31345 (21828)"
    public static let minimumCompatibleVersion = "26.903.61454 (8378)"
    public static let testedVersions: Set<String> = [minimumCompatibleVersion, "26.903.71938 (8576)", "26.908.40834 (8881)", "26.908.70816 (9275)", "26.911.61220 (9647)", "26.915.31029 (9771)", testedVersion]
    /// Only known locations inside the verified desktop bundle. Never launch a PATH
    /// executable or the newer package's shell wrapper with account credentials.
    static let backendPaths = ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "Contents/Resources/codex"]
    public var appURL = URL(fileURLWithPath: "/Applications/Codex.app")
    public var home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) { self.home = home.standardizedFileURL.resolvingSymlinksInPath() }
    public var binary: URL { (try? Self.resolveBinary(in: appURL)) ?? appURL.appendingPathComponent(Self.backendPaths[0]) }
    static func resolveBinary(in appURL: URL) throws -> URL {
        let bundle = appURL.standardizedFileURL.resolvingSymlinksInPath()
        for relative in backendPaths {
            let candidate = bundle.appendingPathComponent(relative).standardizedFileURL
            var componentURL = bundle, missing = false
            var metadata = stat()
            let components = relative.split(separator: "/")
            for (index, component) in components.enumerated() {
                componentURL.appendPathComponent(String(component))
                if lstat(componentURL.path, &metadata) != 0 {
                    guard errno == ENOENT else { throw SwitcherError.unsupportedVersion }
                    missing = true; break
                }
                guard metadata.st_mode & S_IFMT != S_IFLNK,
                      index == components.count - 1 || metadata.st_mode & S_IFMT == S_IFDIR else { throw SwitcherError.unsupportedVersion }
            }
            if missing { continue }
            // A present unexpected primary entry must not silently fall back to an older backend.
            guard candidate.resolvingSymlinksInPath() == candidate,
                  candidate.path.hasPrefix(bundle.path + "/"), metadata.st_mode & S_IFMT == S_IFREG,
                  FileManager.default.isExecutableFile(atPath: candidate.path) else { throw SwitcherError.unsupportedVersion }
            let descriptor = open(candidate.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw SwitcherError.unsupportedVersion }
            defer { close(descriptor) }
            var magic = [UInt8](repeating: 0, count: 4)
            guard Darwin.read(descriptor, &magic, 4) == 4,
                  [[0xcf,0xfa,0xed,0xfe], [0xfe,0xed,0xfa,0xcf], [0xca,0xfe,0xba,0xbe], [0xbe,0xba,0xfe,0xca], [0xca,0xfe,0xba,0xbf], [0xbf,0xba,0xfe,0xca]].contains(magic) else { throw SwitcherError.unsupportedVersion }
            return candidate
        }
        throw SwitcherError.unsupportedVersion
    }
    public var version: String {
        guard let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")), let version = info["CFBundleShortVersionString"] as? String, let build = info["CFBundleVersion"] as? String else { return "未知" }
        return "\(version) (\(build))"
    }
    public static func versionComponents(_ value: String) -> [Int]? {
        let parts = value.split(separator: " ")
        guard parts.count == 2, parts[1].first == "(", parts[1].last == ")" else { return nil }
        let release = parts[0].split(separator: ".")
        guard release.count == 3,
              let major = Int(release[0]), let train = Int(release[1]), let patch = Int(release[2]),
              let build = Int(parts[1].dropFirst().dropLast()) else { return nil }
        return [major, train, patch, build]
    }
    public static func isVersionEligible(_ value: String) -> Bool {
        guard let current = versionComponents(value), let minimum = versionComponents(minimumCompatibleVersion) else { return false }
        return !current.lexicographicallyPrecedes(minimum)
    }
    public func validateVersion() throws {
        guard Self.isVersionEligible(version) else { throw SwitcherError.unsupportedVersion }
        let executable = try Self.resolveBinary(in: appURL)
        // Verify both the enclosing desktop and the actual nested executable. A valid
        // desktop signature alone must not authorize a substituted or unsigned backend.
        try Self.validateSignature(appURL, identifier: "com.openai.codex")
        try Self.validateSignature(executable)
    }
    private static func validateSignature(_ url: URL, identifier: String? = nil) throws {
        var code: SecStaticCode?, requirement: SecRequirement?
        var rule = "anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\""
        if let identifier { rule += " and identifier \"\(identifier)\"" }
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement) == errSecSuccess else { throw SwitcherError.unsupportedVersion }
    }
    public func validate() throws {
        try validateVersion(); try SecureIO.validateDirectory(home)
        // Limited to explicitly selected default desktop home; a CLI override alone does not redirect Electron data.
        let desktopHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").resolvingSymlinksInPath()
        guard home == desktopHome else { throw SwitcherError.unsupportedBackend }
        for path in ["/etc/codex/config.toml", "/etc/codex/managed_config.toml", "/etc/codex/requirements.toml", "/Library/Managed Preferences/com.openai.codex.plist"] {
            if FileManager.default.fileExists(atPath: path) { throw SwitcherError.unsupportedBackend }
        }
        let config = home.appendingPathComponent("config.toml")
        // Conservative extraction: do not infer file mode from a stale auth.json or attempt a TOML rewrite.
        let text = FileManager.default.fileExists(atPath: config.path) ? try String(contentsOf: config, encoding: .utf8) : ""
        // Explicit keyring/auto, managed configuration and ambiguous syntax fail closed.
        // When omitted, ask this actual official backend in an empty temporary home;
        // never assume that all future versions keep today's default file storage.
        guard Self.explicitFileBackend(text, defaultIsFile: true) else { throw SwitcherError.unsupportedBackend }
        if !Self.explicitFileBackend(text) { try validateDefaultStorage() }
    }
    private func validateDefaultStorage() throws {
        let executable = try Self.resolveBinary(in: appURL)
        let key = try Self.backendCacheKey(executable, version: version)
        if DefaultStorageCache.contains(key) { return }
        let server = try AppServer(binary: executable, forceFileStorage: false)
        defer { server.close() }
        let result = try server.request("config/read", params: ["includeLayers": false])
        guard Self.hasFileStorage(result) else { throw SwitcherError.unsupportedBackend }
        let account = try server.request("account/read", params: ["refreshToken": false])
        guard account["account"] is NSNull,
              try Self.backendCacheKey(executable, version: version) == key else { throw SwitcherError.unsupportedBackend }
        DefaultStorageCache.insert(key)
    }
    static func hasFileStorage(_ response: [String: Any]) -> Bool {
        guard let config = response["config"] as? [String: Any] else { return false }
        return config["cli_auth_credentials_store"] as? String == "file"
    }
    static func backendCacheKey(_ executable: URL, version: String) throws -> String {
        var metadata = stat()
        guard lstat(executable.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { throw SwitcherError.unsupportedVersion }
        return [executable.path, version, String(metadata.st_dev), String(metadata.st_ino), String(metadata.st_size), String(metadata.st_mtimespec.tv_sec), String(metadata.st_mtimespec.tv_nsec), String(metadata.st_ctimespec.tv_sec), String(metadata.st_ctimespec.tv_nsec)].joined(separator: "|")
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

private enum DefaultStorageCache {
    private static let lock = NSLock()
    private static var keys = Set<String>()
    static func contains(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return keys.contains(key)
    }
    static func insert(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        // A small process-only cache; upgrades invalidate the key and every operation
        // still verifies the current official signatures before consulting it.
        if keys.count > 8 { keys.removeAll() }
        keys.insert(key)
    }
}

public final class Cancellation {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func cancel() { lock.lock(); value = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
