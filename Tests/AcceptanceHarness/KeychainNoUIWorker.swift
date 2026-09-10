import Foundation
import Security

/// Uses only an explicit, UUID-named test service. Does not open production state.
@main struct KeychainNoUIWorker {
    static func main() {
        do {
            let args = CommandLine.arguments
            guard args.count >= 3, args[2].hasPrefix("local.codex-account-switcher.no-ui-test."),
                  UUID(uuidString: String(args[2].dropFirst("local.codex-account-switcher.no-ui-test.".count))) != nil else { throw SwitcherError.unsafePath }
            let store = KeychainStore(service: args[2])
            let data = Data("SYNTHETIC_NO_UI_TEST".utf8)
            switch args[1] {
            case "create": print(try store.put(data))
            case "read":
                guard args.count == 4 else { throw SwitcherError.unsafePath }
                // Numeric diagnostic on owned fake items only; never logs item contents.
                var allowed = DarwinBoolean(false)
                let policyRead = SecKeychainGetUserInteractionAllowed(&allowed)
                let policyWrite = SecKeychainSetUserInteractionAllowed(false)
                let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: args[2], kSecAttrAccount as String: args[3],
                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
                var value: CFTypeRef?
                let rawStatus = SecItemCopyMatching(query as CFDictionary, &value)
                _ = SecKeychainSetUserInteractionAllowed(allowed.boolValue)
                FileHandle.standardError.write(Data("policyRead=\(policyRead) policyWrite=\(policyWrite) item=\(rawStatus)\n".utf8))
                guard try store.get(args[3]) == data else { throw SwitcherError.keychain }
                print("READ_OK")
            case "delete":
                guard args.count == 4 else { throw SwitcherError.unsafePath }
                try store.remove(args[3]); print("DELETE_OK")
            default: throw SwitcherError.unsafePath
            }
        } catch {
            print((error as? SwitcherError)?.rawValue ?? "error")
            exit(1)
        }
    }
}
