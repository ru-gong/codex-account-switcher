import Foundation
import Darwin

/// Single worker owns the stdio stream. It never sends a refresh token to a quota process.
public final class AppServer {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let home: URL
    private let workspace: LoginWorkspace
    private let cancel: Cancellation
    private var buffer = Data(), sequence = 0
    private var notifications: [[String: Any]] = []
    private var started = false
    public init(binary: URL, cancellation: Cancellation = Cancellation()) throws {
        self.cancel = cancellation
        workspace = try LoginWorkspace()
        home = workspace.url
        process.executableURL = binary
        process.arguments = ["app-server", "--stdio", "-c", "cli_auth_credentials_store=\"file\"", "-c", "analytics.enabled=false"]
        process.currentDirectoryURL = home
        // Intentionally no inherited API keys, endpoint overrides, hooks or MCP configuration.
        process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "CODEX_HOME": home.path, "TMPDIR": home.path]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do {
            try process.run(); started = true
            try workspace.childStarted(process.processIdentifier)
            _ = try request("initialize", params: ["clientInfo": ["name": "codex_account_switcher", "version": "0.4.0"], "capabilities": ["experimentalApi": true]])
            try send(["method": "initialized", "params": [:]])
        } catch { close(); throw error }
    }
    deinit { close() }
    public func close() {
        if started {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                // This is exclusively the child we started in an empty private home, never a user Codex process.
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit(); started = false
        }
        try? output.fileHandleForReading.close()
        // Exact freshly allocated directory only. No scanning/cleanup of other instances' temporary files.
        try? workspace.remove()
    }
    private func send(_ message: [String: Any]) throws {
        var data = try canonical(message); data.append(10)
        do { try input.fileHandleForWriting.write(contentsOf: data) } catch { throw SwitcherError.protocolError }
    }
    private func readMessage(deadline: Date) throws -> [String: Any] {
        while true {
            if cancel.isCancelled { throw SwitcherError.cancelled }
            if Date() > deadline { throw SwitcherError.timeout }
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw SwitcherError.protocolError }; return object
            }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; throw SwitcherError.protocolError }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let n = Darwin.read(descriptor.fd, &bytes, bytes.count)
            guard n > 0 else { throw SwitcherError.protocolError }
            buffer.append(bytes, count: n)
            guard buffer.count < 2_097_152 else { throw SwitcherError.protocolError }
        }
    }
    private func unsolicited(_ message: [String: Any]) throws {
        if let id = message["id"], message["method"] != nil {
            try send(["id": id, "error": ["code": -32601, "message": "Host does not provide token refresh or tool execution"]])
            if message["method"] as? String == "account/chatgptAuthTokens/refresh" { throw SwitcherError.expired }
        } else {
            notifications.append(message)
            guard notifications.count <= 100 else { throw SwitcherError.protocolError }
        }
    }
    public func request(_ method: String, params: [String: Any] = [:], timeout: TimeInterval = 25) throws -> [String: Any] {
        sequence += 1; let id = sequence
        try send(["id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let message = try readMessage(deadline: deadline)
            if message["id"] as? Int == id, message["method"] == nil {
                if let error = message["error"] as? [String: Any] { throw Self.classify(error) }
                guard let result = message["result"] as? [String: Any] else { throw SwitcherError.protocolError }; return result
            }
            try unsolicited(message)
        }
    }
    public static func classify(_ error: [String: Any]) -> SwitcherError {
        let message = (error["message"] as? String ?? "").lowercased()
        let data = error["data"] as? [String: Any] ?? [:]
        let status = data["statusCode"] as? Int ?? data["httpStatusCode"] as? Int ?? error["code"] as? Int
        if status == 401 || message.contains("401") || message.contains("unauthorized") { return .unauthorized }
        if status == 403 || message.contains("403") || message.contains("forbidden") { return .forbidden }
        if status == 429 || message.contains("429") || message.contains("rate limit") { return .rateLimited }
        if let status, (500...599).contains(status) { return .serverError }
        if message.contains("timeout") || message.contains("timed out") { return .timeout }
        if message.contains("connect") || message.contains("dns") || message.contains("network") { return .offline }
        return .protocolError
    }
    public func waitForLogin(id: String) throws -> Credential {
        let deadline = Date().addingTimeInterval(600)
        while true {
            let message: [String: Any]
            if !notifications.isEmpty { message = notifications.removeFirst() }
            else { message = try readMessage(deadline: deadline) }
            if message["method"] as? String == "account/login/completed", let params = message["params"] as? [String: Any], params["loginId"] as? String == id {
                guard params["success"] as? Bool == true else { throw SwitcherError.loginFailed }
                return try Credential(data: SecureIO.read(home.appendingPathComponent("auth.json")))
            }
            if message["id"] != nil { try unsolicited(message) }
        }
    }
    public static func login(binary: URL, cancellation: Cancellation, openURL: (URL) -> Void) throws -> Credential {
        let server = try AppServer(binary: binary, cancellation: cancellation); defer { server.close() }
        let response = try server.request("account/login/start", params: ["type": "chatgpt", "useHostedLoginSuccessPage": true, "appBrand": "codex"])
        guard let id = response["loginId"] as? String, let raw = response["authUrl"] as? String, let url = URL(string: raw), url.scheme == "https", let host = url.host,
              ["auth.openai.com", "auth0.openai.com", "chatgpt.com"].contains(host) else { throw SwitcherError.protocolError }
        openURL(url)
        return try server.waitForLogin(id: id)
    }
    public static func quota(binary: URL, credential: Credential, cancellation: Cancellation) throws -> Quota {
        guard let expiry = credential.expiresAt, expiry.timeIntervalSinceNow > 60 else { throw SwitcherError.expired }
        let server = try AppServer(binary: binary, cancellation: cancellation); defer { server.close() }
        var params: [String: Any] = ["type": "chatgptAuthTokens", "accessToken": credential.accessToken, "chatgptAccountId": credential.identity.workspace]
        if let plan = credential.plan { params["chatgptPlanType"] = plan }
        _ = try server.request("account/login/start", params: params)
        return try Quota.parse(server.request("account/rateLimits/read"))
    }
}
