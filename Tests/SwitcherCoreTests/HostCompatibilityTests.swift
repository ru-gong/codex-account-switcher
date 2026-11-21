import XCTest
@testable import SwitcherCore

final class HostCompatibilityTests: XCTestCase {
    private var root: URL!
    private var app: URL!
    private let machOMagic = Data([0xcf, 0xfa, 0xed, 0xfe, 0, 0, 0, 0])

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("switcher-host-tests-" + UUID().uuidString)
        app = root.appendingPathComponent("Codex.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult private func fixture(_ relative: String, data: Data? = nil) throws -> URL {
        let url = app.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data ?? machOMagic).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    private func rejects(_ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation()) { XCTAssertEqual($0 as? SwitcherError, .unsupportedVersion) }
    }

    func testNestedBackendTakesPrecedenceAndLegacyStillResolves() throws {
        let legacy = try fixture(HostConfiguration.backendPaths[1])
        XCTAssertEqual(try HostConfiguration.resolveBinary(in: app), legacy)
        let nested = try fixture(HostConfiguration.backendPaths[0])
        XCTAssertEqual(try HostConfiguration.resolveBinary(in: app), nested)
    }
    func testUnknownFutureLocationDoesNotSearchPathOrExecuteWrapper() throws {
        try fixture("Contents/Resources/future/codex")
        try fixture("Contents/Resources/codex-cli/bin/codex", data: Data("#!/bin/sh\nexit 0\n".utf8))
        rejects { _ = try HostConfiguration.resolveBinary(in: app) }
    }
    func testPresentInvalidPrimaryDoesNotSilentlyFallBack() throws {
        try fixture(HostConfiguration.backendPaths[0], data: Data("#!/bin/sh\nexit 0\n".utf8))
        try fixture(HostConfiguration.backendPaths[1])
        rejects { _ = try HostConfiguration.resolveBinary(in: app) }
    }
    func testNonExecutableBackendRejected() throws {
        let binary = try fixture(HostConfiguration.backendPaths[0])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: binary.path)
        rejects { _ = try HostConfiguration.resolveBinary(in: app) }
    }
    func testSymlinkToExternalExecutableRejected() throws {
        let outside = root.appendingPathComponent("outside")
        try machOMagic.write(to: outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outside.path)
        let link = app.appendingPathComponent(HostConfiguration.backendPaths[1])
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        rejects { _ = try HostConfiguration.resolveBinary(in: app) }
    }
    func testSymlinkedParentCannotEscapeOfficialBundle() throws {
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try machOMagic.write(to: outside.appendingPathComponent("codex"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outside.appendingPathComponent("codex").path)
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: contents.appendingPathComponent("Resources"), withDestinationURL: outside)
        rejects { _ = try HostConfiguration.resolveBinary(in: app) }
    }
    func testDanglingPrimaryParentDoesNotFallBackToLegacy() throws {
        try fixture(HostConfiguration.backendPaths[1])
        let link = app.appendingPathComponent("Contents/Resources/codex-cli")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("missing"))
        rejects { _ = try HostConfiguration.resolveBinary(in: app) }
    }
    func testUnsignedBundleWithEligibleVersionIsRejected() throws {
        try fixture(HostConfiguration.backendPaths[0])
        let info: [String: Any] = ["CFBundleShortVersionString": "26.1021.31345", "CFBundleVersion": "21828", "CFBundleIdentifier": "com.openai.codex"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        var host = HostConfiguration(home: root)
        host.appURL = app
        rejects { try host.validateVersion() }
    }
    func testBackendReplacementInvalidatesDefaultStorageCacheKey() throws {
        let binary = try fixture(HostConfiguration.backendPaths[0])
        let before = try HostConfiguration.backendCacheKey(binary, version: "same")
        try FileManager.default.removeItem(at: binary)
        try fixture(HostConfiguration.backendPaths[0], data: machOMagic + Data([1,2,3,4]))
        XCTAssertNotEqual(before, try HostConfiguration.backendCacheKey(binary, version: "same"))
        XCTAssertNotEqual(try HostConfiguration.backendCacheKey(binary, version: "same"), try HostConfiguration.backendCacheKey(binary, version: "new"))
    }
    func testDefaultStorageRequiresExplicitFileResult() {
        XCTAssertTrue(HostConfiguration.hasFileStorage(["config": ["cli_auth_credentials_store": "file"]]))
        for response: [String: Any] in [[:], ["config": [:]], ["config": ["cli_auth_credentials_store": NSNull()]], ["config": ["cli_auth_credentials_store": "auto"]], ["config": ["cli_auth_credentials_store": "keyring"]], ["config": ["cli_auth_credentials_store": true]]] {
            XCTAssertFalse(HostConfiguration.hasFileStorage(response))
        }
    }
}
