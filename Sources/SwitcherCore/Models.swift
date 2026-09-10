import Foundation
import CryptoKit
import CoreFoundation

public enum SwitcherError: String, Error, LocalizedError {
    case busy, unsafePath, io, uncertainWrite, invalidAuth, identityMismatch, missingAccount, conflict, pendingRecovery, writersRunning, unsupportedBackend, unsupportedVersion, capabilityUnknown, keychain, keychainAuthorizationRequired, cancelled, timeout, protocolError, loginFailed, expired, unknownQuota, unauthorized, forbidden, rateLimited, offline, serverError
    public var errorDescription: String? {
        switch self {
        case .busy: return "另一个操作正在进行，请稍后重试。"
        case .unsafePath: return "路径、所有者或文件权限不符合安全要求。"
        case .io: return "本地文件操作失败；原始凭据和恢复记录已保留。"
        case .uncertainWrite: return "写入可能已提交，请先进入恢复检查。"
        case .invalidAuth: return "无法识别 ChatGPT 凭据，或令牌已过期。"
        case .identityMismatch: return "账号或工作区与预期不一致。"
        case .missingAccount: return "账号不存在。"
        case .conflict: return "凭据出现外部变更或分叉，已停止覆盖。请重新登录确认。"
        case .pendingRecovery: return "上一次切换尚未确认，请先确认或恢复。"
        case .writersRunning: return "请先完全退出 Codex、Codex CLI 和使用同一登录的 IDE 扩展。"
        case .unsupportedBackend: return "尚未确认使用 file 凭据后端，或存在受管配置。请按使用说明完成环境核验。"
        case .unsupportedVersion: return "Codex 版本尚未验证，本次只允许查看。"
        case .capabilityUnknown: return "目标账号的浏览器和 Computer History 连续性尚未人工核验。"
        case .keychainAuthorizationRequired: return "凭据需要授权。请在账号菜单中点“授权此账号”，后台不会弹出密码窗口。"
        case .keychain: return "钥匙串操作失败或被拒绝；不会回退到明文存储。"
        case .cancelled: return "操作已取消。"
        case .timeout: return "Codex 后端响应超时。"
        case .protocolError: return "Codex 后端协议不兼容或响应异常。"
        case .loginFailed: return "登录未完成，请重试。"
        case .expired: return "访问令牌已过期，请重新授权此账号。"
        case .unknownQuota: return "额度暂时无法确认；已保留上次结果。"
        case .unauthorized: return "授权无效，请重新登录。"
        case .forbidden: return "此账号或工作区没有所需权限。"
        case .rateLimited: return "服务限制了请求频率，5 分钟后可重试。"
        case .offline: return "网络不可用，已保留上次结果。"
        case .serverError: return "服务暂时不可用，稍后重试。"
        }
    }
}

public func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
public func canonical(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) }

public struct Identity: Codable, Equatable, Hashable {
    public var issuer: String
    public var user: String
    public var workspace: String
    public var key: String { digest(Data([issuer, user, workspace].joined(separator: "\u{0}").utf8)) }
}

/// JWT claims identify a local record. Authenticity is established by official login, not by decoding.
public struct Credential {
    public let data: Data
    public let identity: Identity
    public let email: String
    public let accessToken: String
    public let plan: String?
    public let expiresAt: Date?
    public var fingerprint: String { digest(data) }

    public init(data: Data) throws {
        guard data.count < 1_048_576,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let idToken = tokens["id_token"] as? String,
              let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty,
              let workspace = tokens["account_id"] as? String, !workspace.isEmpty,
              let id = Self.claims(idToken), let ac = Self.claims(access),
              let issuer = id["iss"] as? String, issuer.hasPrefix("https://"),
              let subject = id["sub"] as? String, !subject.isEmpty else { throw SwitcherError.invalidAuth }
        let idAuth = id["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let accessAuth = ac["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        for claim in [idAuth, accessAuth] {
            if let w = claim["chatgpt_account_id"] as? String, w != workspace { throw SwitcherError.identityMismatch }
        }
        if let a = idAuth["chatgpt_user_id"] as? String, let b = accessAuth["chatgpt_user_id"] as? String, a != b { throw SwitcherError.identityMismatch }
        self.data = try canonical(obj)
        identity = Identity(issuer: issuer, user: idAuth["chatgpt_user_id"] as? String ?? accessAuth["chatgpt_user_id"] as? String ?? subject, workspace: workspace)
        email = id["email"] as? String ?? "未提供邮箱"
        accessToken = access
        plan = accessAuth["chatgpt_plan_type"] as? String ?? idAuth["chatgpt_plan_type"] as? String
        expiresAt = (ac["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
    }
    public static func claims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded) else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }
}

public struct QuotaWindow: Codable, Equatable {
    public var usedPercent: Double
    public var windowDurationMins: Int
    public var resetsAt: Date?
    public var remaining: Double { max(0, min(100, 100 - usedPercent)) }
}
public struct Quota: Codable, Equatable {
    public var primary: QuotaWindow?
    public var secondary: QuotaWindow?
    public var fetchedAt: Date
    public var stale: Bool
    public var isStale: Bool { stale || Date().timeIntervalSince(fetchedAt) > 900 }
    public static func parse(_ result: [String: Any]) throws -> Quota {
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        guard let entry = (buckets?["codex"] as? [String: Any]) ?? (result["rateLimits"] as? [String: Any]),
              entry["limitId"] == nil || entry["limitId"] is NSNull || entry["limitId"] as? String == "codex" else { throw SwitcherError.unknownQuota }
        func window(_ value: Any?) throws -> QuotaWindow? {
            if value == nil || value is NSNull { return nil }
            guard let o = value as? [String: Any], let number = o["usedPercent"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw SwitcherError.unknownQuota }
            let used = number.doubleValue
            guard used.isFinite, used >= 0, used <= 100,
                  let duration = o["windowDurationMins"] as? NSNumber, CFGetTypeID(duration) != CFBooleanGetTypeID(),
                  let mins = Int(exactly: duration.doubleValue), mins > 0 else { throw SwitcherError.unknownQuota }
            return QuotaWindow(usedPercent: used, windowDurationMins: mins, resetsAt: (o["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        let p = try window(entry["primary"]), s = try window(entry["secondary"])
        guard p != nil || s != nil else { throw SwitcherError.unknownQuota }
        return Quota(primary: p, secondary: s, fetchedAt: Date(), stale: false)
    }
}

public struct Account: Codable, Identifiable {
    public var id: String { identity.key }
    public var identity: Identity
    public var alias: String
    public var maskedEmail: String
    public var plan: String?
    public var secret: String
    public var generation: Int
    public var fingerprint: String
    public var knownFingerprints: [String]
    public var secretHistory: [String]
    public var mainBaseline: String?
    public var continuityVerifiedVersion: String?
    public var quota: Quota?
    public var quotaError: String?
    public var quotaRetryAfter: Date?
    public var continuityUnavailableVersion: String?
}

public enum Phase: String, Codable {
    case prepared, written, pendingConfirmation, recoveryRequired
    public var label: String {
        switch self { case .prepared: return "已准备，需核对现场"; case .written: return "凭据已写入"; case .pendingConfirmation: return "等待桌面确认"; case .recoveryRequired: return "需要恢复检查" }
    }
}
public struct Transaction: Codable, Identifiable {
    public var id: String
    public var source: String
    public var target: String
    public var sourceSecret: String
    public var sourceDiskFingerprint: String
    public var targetFingerprint: String
    public var phase: Phase
    public var started: Date
    public var rollbackFingerprint: String?
}
public struct Ledger: Codable {
    public var schema = 1
    public var accounts: [Account] = []
    public var transaction: Transaction?
    public var lastEvent = "尚未导入账号"
    public var pendingSecretDeletes: [String]?
    public init() {}
}

public struct SwitchPolicy {
    public var version: String
    public var allowCapabilityTrial: Bool
    public init(version: String, allowCapabilityTrial: Bool = false) { self.version = version; self.allowCapabilityTrial = allowCapabilityTrial }
}
