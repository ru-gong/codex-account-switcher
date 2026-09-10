import XCTest
import Security
@testable import SwitcherCore

final class KeychainInteractionTests: XCTestCase {
    private final class Fake {
        var allowed = true
        var calls: [(String, Bool)] = []
        var requiresApproval = true
        var failSettingPolicy = false
        let data = Data("SYNTHETIC_SESSION_CREDENTIAL".utf8)
        var backend: KeychainBackend {
            KeychainBackend(getInteraction: { self.allowed }, setInteraction: {
                if self.failSettingPolicy { throw SwitcherError.keychain }
                self.allowed = $0
            }, add: { _ in
                self.calls.append(("add", self.allowed))
                return self.requiresApproval && !self.allowed ? errSecInteractionNotAllowed : errSecSuccess
            }, read: { _ in
                self.calls.append(("read", self.allowed))
                return self.requiresApproval && !self.allowed ? (errSecInteractionNotAllowed, nil) : (errSecSuccess, self.data)
            }, remove: { _ in
                self.calls.append(("remove", self.allowed))
                return self.requiresApproval && !self.allowed ? errSecInteractionNotAllowed : errSecSuccess
            })
        }
        func store() -> KeychainStore { KeychainStore(service: "synthetic-only", backend: backend) }
    }

    func testBackgroundReadNeverPromptsAndRestoresProcessPolicy() throws {
        let fake = Fake(), store = fake.store()
        XCTAssertThrowsError(try store.get("fake-reference")) { XCTAssertEqual($0 as? SwitcherError, .keychainAuthorizationRequired) }
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertFalse(fake.calls[0].1)
        XCTAssertTrue(fake.allowed)
    }

    func testUserAuthorizationCachesImmutableCredentialUntilSessionClear() throws {
        let fake = Fake(), store = fake.store()
        XCTAssertEqual(try store.withUserAuthorization { try store.get("fake-reference") }, fake.data)
        XCTAssertTrue(fake.calls[0].1)
        for _ in 0..<10 { XCTAssertEqual(try store.get("fake-reference"), fake.data) }
        XCTAssertEqual(fake.calls.count, 1)
        store.clearSessionCache()
        XCTAssertThrowsError(try store.get("fake-reference"))
        XCTAssertFalse(fake.calls.last!.1)
    }

    func testFailedExplicitActionCannotLeavePromptingEnabledForNextOperation() throws {
        let fake = Fake(), store = fake.store()
        XCTAssertThrowsError(try store.withUserAuthorization { throw SwitcherError.cancelled })
        XCTAssertThrowsError(try store.get("another-reference"))
        XCTAssertFalse(fake.calls.last!.1)
    }

    func testExplicitAuthorizationDoesNotEnableAnotherThreadOrHoldEngineLockOrder() throws {
        let fake = Fake(), store = fake.store()
        let completed = expectation(description: "background read stops without waiting for explicit action")
        store.withUserAuthorization {
            DispatchQueue.global().async {
                do { _ = try store.get("background-reference"); XCTFail("background read must require authorization") }
                catch { XCTAssertEqual(error as? SwitcherError, .keychainAuthorizationRequired) }
                completed.fulfill()
            }
            wait(for: [completed], timeout: 2)
        }
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertFalse(fake.calls[0].1)
    }

    func testBackgroundAddAndDeleteAlsoForbidUIAndPreserveFailures() throws {
        let fake = Fake(), store = fake.store()
        XCTAssertThrowsError(try store.put(fake.data)) { XCTAssertEqual($0 as? SwitcherError, .keychainAuthorizationRequired) }
        XCTAssertThrowsError(try store.remove("fake-reference")) { XCTAssertEqual($0 as? SwitcherError, .keychainAuthorizationRequired) }
        XCTAssertEqual(fake.calls.map(\.0), ["add", "remove"])
        XCTAssertTrue(fake.calls.allSatisfy { !$0.1 })
    }

    func testPermissionPolicyFailureDoesNotCallSecurityOperations() throws {
        let fake = Fake(), store = fake.store()
        fake.failSettingPolicy = true
        XCTAssertThrowsError(try store.get("fake-reference"))
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testDeleteInvalidatesCachedCredentialEvenWhenDeletionIsDenied() throws {
        let fake = Fake(), store = fake.store()
        _ = try store.withUserAuthorization { try store.get("fake-reference") }
        XCTAssertThrowsError(try store.remove("fake-reference"))
        XCTAssertThrowsError(try store.get("fake-reference"))
        XCTAssertEqual(fake.calls.map(\.0), ["read", "remove", "read"])
    }

    func testPromptBlockPreventsEngineSwitchBeforeAnyAuthWrite() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("switcher-no-prompt-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let demo = try Demo.make(root: root), fake = Fake()
        let engine = try Engine(root: demo.root, authURL: demo.authURL, secrets: fake.store(), writersStopped: {}, environmentAllowed: {})
        let before = try SecureIO.read(demo.authURL)
        XCTAssertThrowsError(try engine.switchAccount(Demo.credential("B").identity.key, policy: SwitchPolicy(version: "test", allowCapabilityTrial: true), validateTarget: { _ in XCTFail() })) {
            XCTAssertEqual($0 as? SwitcherError, .keychainAuthorizationRequired)
        }
        XCTAssertEqual(try SecureIO.read(demo.authURL), before)
        XCTAssertNil(try demo.snapshot().transaction)
    }
}
