import Foundation

public enum Demo {
    public static func credential(_ name: String, revision: Int = 1, workspace: String? = nil) throws -> Credential {
        func jwt(_ object: [String: Any]) throws -> String {
            let payload = try canonical(object).base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            return "eyJhbGciOiJub25lIn0." + payload + ".SYNTHETIC_ONLY"
        }
        let w = workspace ?? "demo-workspace-" + name
        let auth: [String: Any] = ["chatgpt_user_id": "demo-user-" + name, "chatgpt_account_id": w, "chatgpt_plan_type": "plus"]
        let common: [String: Any] = ["iss": "https://auth.openai.com", "sub": "demo-user-" + name, "email": name.lowercased() + "@example.invalid", "https://api.openai.com/auth": auth, "exp": 4_102_444_800, "demo_revision": revision]
        return try Credential(data: canonical(["tokens": ["id_token": try jwt(common), "access_token": try jwt(common), "refresh_token": "SYNTHETIC_REFRESH_\(name)_\(revision)", "account_id": w], "auth_mode": "chatgpt", "unknown_future_field": ["preserved": true]]))
    }
    public static func make(root: URL? = nil, seed: Bool = true) throws -> Engine {
        let root = root ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("codex-switcher-demo-" + UUID().uuidString)
        try SecureIO.prepareDirectory(root)
        let marker = root.appendingPathComponent("SYNTHETIC-ONLY")
        if !FileManager.default.fileExists(atPath: marker.path) {
            guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else { throw SwitcherError.unsafePath }
            try SecureIO.write(Data("Synthetic test credentials only".utf8), to: marker)
        }
        guard try SecureIO.read(marker) == Data("Synthetic test credentials only".utf8) else { throw SwitcherError.unsafePath }
        let home = root.appendingPathComponent("codex-home"); try SecureIO.prepareDirectory(home)
        let engine = try Engine(root: root.appendingPathComponent("state"), authURL: home.appendingPathComponent("auth.json"), secrets: TestSecretStore(root: root.appendingPathComponent("fake-secrets")), writersStopped: {}, environmentAllowed: {})
        if try seed && engine.snapshot().accounts.isEmpty {
            try SecureIO.write(credential("A").data, to: engine.authURL)
            try engine.importCurrent(alias: "日常开发")
            for name in ["B", "C"] { try engine.importAuthorized(credential(name), alias: name == "B" ? "备用账号" : "测试账号") }
            let all = try engine.snapshot().accounts
            for (n, a) in all.enumerated() {
                let quota = try Quota.parse(["rateLimits": ["primary": ["usedPercent": [16, 72, 100][n], "windowDurationMins": 300, "resetsAt": Date().addingTimeInterval(7200).timeIntervalSince1970], "secondary": ["usedPercent": [32, 40, 95][n], "windowDurationMins": 10080]]])
                try engine.updateQuota(a.id, fingerprint: a.fingerprint, quota: quota, error: nil)
            }
        }
        return engine
    }
}
