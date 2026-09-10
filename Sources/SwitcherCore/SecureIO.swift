import Foundation
import Darwin
import Security

public enum SecureIO {
    public static func prepareDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try validateDirectory(url)
    }
    public static func validateDirectory(_ url: URL) throws {
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFDIR, s.st_uid == getuid(), s.st_mode & 0o022 == 0,
              url.standardizedFileURL.resolvingSymlinksInPath().path == url.standardizedFileURL.path else { throw SwitcherError.unsafePath }
    }
    private static func validateFile(_ fd: Int32) throws {
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid(), s.st_nlink == 1,
              s.st_mode & 0o077 == 0, s.st_size <= 16_777_216 else { throw SwitcherError.unsafePath }
    }
    public static func read(_ url: URL) throws -> Data {
        try validateDirectory(url.deletingLastPathComponent())
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ELOOP ? SwitcherError.unsafePath : SwitcherError.io }
        defer { close(fd) }
        try validateFile(fd)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 { if errno == EINTR { continue }; throw SwitcherError.io }
            data.append(buffer, count: count)
            guard data.count <= 16_777_216 else { throw SwitcherError.io }
        }
    }
    /// preCommit runs after temp fsync, immediately before rename. An error after rename is uncertain, never a cancellation.
    public static func write(_ data: Data, to url: URL, preCommit: () throws -> Void = {}, afterRename: () throws -> Void = {}) throws {
        let parent = url.deletingLastPathComponent()
        try validateDirectory(parent)
        var destination = stat()
        if lstat(url.path, &destination) == 0 { _ = try read(url) }
        else if errno != ENOENT { throw SwitcherError.io }
        let temp = parent.appendingPathComponent(".switcher-" + UUID().uuidString + ".tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SwitcherError.io }
        var renamed = false
        defer { close(fd); if !renamed { unlink(temp.path) } }
        guard fchmod(fd, 0o600) == 0 else { throw SwitcherError.io }
        try data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw SwitcherError.io }; sent += n
            }
        }
        guard fsync(fd) == 0 else { throw SwitcherError.io }
        try preCommit()
        try validateDirectory(parent)
        guard rename(temp.path, url.path) == 0 else { throw SwitcherError.io }
        renamed = true
        do {
            try afterRename()
            let dir = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard dir >= 0 else { throw SwitcherError.io }; defer { close(dir) }
            guard fsync(dir) == 0 else { throw SwitcherError.io }
        } catch { throw SwitcherError.uncertainWrite }
    }
}

public final class ProcessLock {
    private let url: URL
    public init(root: URL) { url = root.appendingPathComponent("transaction.lock") }
    public func withLock<T>(_ body: () throws -> T) throws -> T {
        try SecureIO.validateDirectory(url.deletingLastPathComponent())
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SwitcherError.unsafePath }; defer { close(fd) }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid(), s.st_nlink == 1, s.st_mode & 0o077 == 0 else { throw SwitcherError.unsafePath }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw SwitcherError.busy }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

public protocol SecretStore {
    func put(_ data: Data) throws -> String
    func get(_ reference: String) throws -> Data
    func remove(_ reference: String) throws
}
/// Only used with synthetic credentials in explicitly selected demo/test roots.
public final class TestSecretStore: SecretStore {
    private let root: URL
    public init(root: URL) throws { self.root = root; try SecureIO.prepareDirectory(root) }
    public func put(_ data: Data) throws -> String { let ref = UUID().uuidString; try SecureIO.write(data, to: root.appendingPathComponent(ref)); return ref }
    public func get(_ reference: String) throws -> Data { guard UUID(uuidString: reference) != nil else { throw SwitcherError.unsafePath }; return try SecureIO.read(root.appendingPathComponent(reference)) }
    public func remove(_ reference: String) throws { guard UUID(uuidString: reference) != nil else { throw SwitcherError.unsafePath }; let url = root.appendingPathComponent(reference); if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
}
