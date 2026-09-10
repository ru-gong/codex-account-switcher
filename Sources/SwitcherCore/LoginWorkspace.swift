import Foundation
import Darwin

/// A private directory with provenance. Cleanup requires BOTH recorded processes to be gone.
public final class LoginWorkspace {
    private struct Owner: Codable {
        var kind = "codex-account-switcher-login-v1"
        var uid = getuid()
        var parent: Int32
        var child: Int32?
    }
    public let url: URL
    private let base: URL
    private var owner: Owner
    private var removed = false
    public init(base: URL? = nil) throws {
        self.base = base ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("codex-switcher-owned-logins")
        try SecureIO.prepareDirectory(self.base)
        self.url = self.base.appendingPathComponent(UUID().uuidString)
        self.owner = Owner(parent: getpid(), child: nil)
        try ProcessLock(root: self.base).withLock {
            try Self.cleanupUnlocked(base: self.base)
            try SecureIO.prepareDirectory(self.url)
            try self.saveOwner()
        }
    }
    private func saveOwner() throws { try SecureIO.write(JSONEncoder().encode(owner), to: url.appendingPathComponent("switcher-owner.json")) }
    public func childStarted(_ pid: Int32) throws { owner.child = pid; try saveOwner() }
    public func remove() throws {
        guard !removed else { return }
        try ProcessLock(root: base).withLock {
            try SecureIO.validateDirectory(url)
            let actual = try JSONDecoder().decode(Owner.self, from: SecureIO.read(url.appendingPathComponent("switcher-owner.json")))
            guard actual.kind == owner.kind, actual.uid == getuid(), actual.parent == owner.parent, actual.child == owner.child else { throw SwitcherError.unsafePath }
            if let child = owner.child, Self.alive(child) { throw SwitcherError.busy }
            try FileManager.default.removeItem(at: url); removed = true
        }
    }
    private static func alive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return true }
        if kill(pid, 0) == 0 { return true }; return errno != ESRCH
    }
    public static func cleanup(base: URL) throws { try ProcessLock(root: base).withLock { try cleanupUnlocked(base: base) } }
    private static func cleanupUnlocked(base: URL) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: base.path) where UUID(uuidString: name) != nil {
            let dir = base.appendingPathComponent(name)
            guard (try? SecureIO.validateDirectory(dir)) != nil,
                  let data = try? SecureIO.read(dir.appendingPathComponent("switcher-owner.json")),
                  let owner = try? JSONDecoder().decode(Owner.self, from: data), owner.kind == "codex-account-switcher-login-v1", owner.uid == getuid(),
                  !alive(owner.parent), owner.child.map({ !alive($0) }) ?? true else { continue }
            try FileManager.default.removeItem(at: dir)
        }
    }
}
