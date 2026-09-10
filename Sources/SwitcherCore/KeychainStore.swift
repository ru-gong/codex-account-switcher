import Foundation
import Security

/// Injectable only for tests: no test credential needs the user's Keychain.
struct KeychainBackend {
    var getInteraction: () throws -> Bool
    var setInteraction: (Bool) throws -> Void
    var add: ([String: Any]) -> OSStatus
    var read: ([String: Any]) -> (OSStatus, Data?)
    var remove: ([String: Any]) -> OSStatus

    static let system = KeychainBackend(getInteraction: {
        var allowed = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess else { throw SwitcherError.keychain }
        return allowed.boolValue
    }, setInteraction: { allowed in
        guard SecKeychainSetUserInteractionAllowed(allowed) == errSecSuccess else { throw SwitcherError.keychain }
    }, add: { SecItemAdd($0 as CFDictionary, nil) }, read: { query in
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        return (status, value as? Data)
    }, remove: { SecItemDelete($0 as CFDictionary) })
}

/// Legacy credentials remain protected in their existing Keychain items.
/// Normal reads/writes/deletes never ask macOS to display authorization UI.
public final class KeychainStore: SecretStore {
    private static let interactionLock = NSRecursiveLock()
    private let service: String
    private let backend: KeychainBackend
    private let authorizationContext = "local.codex-switcher.authorization.\(UUID().uuidString)"
    private var authorizedInteraction: Bool { Thread.current.threadDictionary[authorizationContext] as? Bool ?? false }
    private var cache: [String: Data] = [:]

    public convenience init(service: String = "local.codex-account-switcher.credentials.v1") {
        self.init(service: service, backend: .system)
    }
    init(service: String, backend: KeychainBackend) {
        self.service = service
        self.backend = backend
    }

    /// Call only from a visible, explicit user authorization action in the app.
    /// Background refreshes and CLI commands never call this method.
    public func withUserAuthorization<T>(_ body: () throws -> T) rethrows -> T {
        // Authorization applies only to this synchronous action on this thread.
        // Do not hold the Security lock while the caller acquires its Engine lock.
        let context = Thread.current.threadDictionary
        let previous = context[authorizationContext]
        context[authorizationContext] = true
        defer {
            if let previous { context[authorizationContext] = previous }
            else { context.removeObject(forKey: authorizationContext) }
        }
        return try body()
    }

    public func clearSessionCache() {
        Self.interactionLock.lock(); defer { Self.interactionLock.unlock() }
        cache.removeAll()
    }

    private func query(_ ref: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: ref]
    }

    private func operation<T>(_ body: () throws -> T) throws -> T {
        let previous = try backend.getInteraction()
        try backend.setInteraction(authorizedInteraction)
        defer { try? backend.setInteraction(previous) }
        return try body()
    }

    private func check(_ status: OSStatus) throws {
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
            throw SwitcherError.keychainAuthorizationRequired
        }
        guard status == errSecSuccess else { throw SwitcherError.keychain }
    }

    public func put(_ data: Data) throws -> String {
        Self.interactionLock.lock(); defer { Self.interactionLock.unlock() }
        let ref = UUID().uuidString
        var q = query(ref)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        try operation { try check(backend.add(q)) }
        cache[ref] = data
        return ref
    }

    public func get(_ reference: String) throws -> Data {
        Self.interactionLock.lock(); defer { Self.interactionLock.unlock() }
        if let data = cache[reference] { return data }
        var q = query(reference)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let data = try operation { () throws -> Data in
            let (status, value) = backend.read(q)
            try check(status)
            guard let value else { throw SwitcherError.keychain }
            return value
        }
        cache[reference] = data
        return data
    }

    public func remove(_ reference: String) throws {
        Self.interactionLock.lock(); defer { Self.interactionLock.unlock() }
        cache.removeValue(forKey: reference)
        try operation {
            let status = backend.remove(query(reference))
            if status != errSecItemNotFound { try check(status) }
        }
    }
}
