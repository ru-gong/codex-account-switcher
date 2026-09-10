import Foundation
import Darwin

/// Compiled by scripts/started_crash_acceptance.py with the unchanged production core.
/// This worker has no production paths or Keychain store; all credentials come from Demo.
@main
enum StartedCrashWorker {
    static func main() {
        do {
            guard CommandLine.arguments.count == 3 else { throw SwitcherError.protocolError }
            let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
            guard root.lastPathComponent.hasPrefix("switcher-started-crash-") else { throw SwitcherError.unsafePath }
            let operation = CommandLine.arguments[2]
            if operation == "init" { _ = try Demo.make(root: root); return }
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent("SYNTHETIC-ONLY").path) else { throw SwitcherError.unsafePath }
            let demo = try Demo.make(root: root, seed: false)
            let writer = root.appendingPathComponent("synthetic-writer-active")
            let engine = try Engine(root: demo.root, authURL: demo.authURL,
                                    secrets: TestSecretStore(root: root.appendingPathComponent("fake-secrets")),
                                    writersStopped: {
                if FileManager.default.fileExists(atPath: writer.path) { throw SwitcherError.writersRunning }
            }, environmentAllowed: {})
            let policy = SwitchPolicy(version: "synthetic-started-crash", allowCapabilityTrial: true)
            let b = try Demo.credential("B").identity.key
            switch operation {
            case "started-wait":
                try engine.switchAccount(b, policy: policy, validateTarget: { _ in })
                try engine.prepareLaunch()
                try engine.noteLaunched()
                // Simulates the newly launched app rotating B while its writer remains active.
                try SecureIO.write(Demo.credential("B", revision: 9).data, to: engine.authURL)
                try SecureIO.write(Data("synthetic writer only".utf8), to: writer)
                try SecureIO.write(Data("pendingConfirmation and refreshed B".utf8), to: root.appendingPathComponent("ready"))
                let deadline = Date().addingTimeInterval(25)
                while Date() < deadline { usleep(10_000) }
                throw SwitcherError.timeout
            case "rollback":
                try engine.recover(rollback: true)
            case "select-b-again":
                try engine.switchAccount(b, policy: policy, validateTarget: { _ in })
                try engine.confirmDesktop(targetKey: b, continuityObserved: false, version: policy.version)
            default:
                throw SwitcherError.protocolError
            }
            print("ok")
        } catch {
            print((error as? SwitcherError)?.rawValue ?? "unexpected")
            exit(1)
        }
    }
}
