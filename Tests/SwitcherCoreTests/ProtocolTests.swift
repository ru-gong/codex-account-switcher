import XCTest
@testable import SwitcherCore

final class ProtocolTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("switcher-protocol-tests-" + UUID().uuidString); try SecureIO.prepareDirectory(root) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func mock(_ mode: String) throws -> URL {
        let url = root.appendingPathComponent("mock-backend")
        let script = #"""
#!/usr/bin/python3
import sys,json,os,time
mode = MODE
def send(o):
 print(json.dumps(o),flush=True)
for line in sys.stdin:
 obj=json.loads(line)
 method=obj.get('method')
 if not method: continue
 if method=='initialized': continue
 if method=='initialize':
  assert 'OPENAI_API_KEY' not in os.environ
  assert 'refresh_token' not in line
  send({'id':obj['id'],'result':{}})
 elif method=='account/login/start':
  if mode=='login':
   import base64
   fd=os.open(os.path.join(os.environ['CODEX_HOME'],'auth.json'),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
   os.write(fd,base64.b64decode('FAKE_AUTH')); os.close(fd)
   send({'method':'account/login/completed','params':{'loginId':'test-login','success':True}})
   send({'id':obj['id'],'result':{'type':'chatgpt','loginId':'test-login','authUrl':'https://auth.openai.com/authorize?state=synthetic'}})
   continue
  assert obj['params']['type']=='chatgptAuthTokens'
  assert 'refresh_token' not in line and 'SYNTHETIC_REFRESH' not in line
  send({'id':obj['id'],'result':{'type':'chatgptAuthTokens'}})
 elif method=='account/rateLimits/read':
  if mode=='refresh': send({'id':900,'method':'account/chatgptAuthTokens/refresh','params':{'reason':'unauthorized'}})
  elif mode=='malformed': print('not json',flush=True)
  elif mode=='slow': time.sleep(10)
  elif mode=='429': send({'id':obj['id'],'error':{'code':-1,'data':{'httpStatusCode':429},'message':'rate limited'}})
  else: send({'id':obj['id'],'result':{'rateLimitsByLimitId':{'codex':{'primary':{'usedPercent':25,'windowDurationMins':300,'resetsAt':1800000000},'secondary':None}}}})
"""#.replacingOccurrences(of: "MODE", with: "'" + mode + "'").replacingOccurrences(of: "FAKE_AUTH", with: try Demo.credential("B").data.base64EncodedString())
        try SecureIO.write(Data(script.utf8), to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    func testAccessOnlyProtocolNeverSendsRefreshToken() throws {
        let q = try AppServer.quota(binary: mock("normal"), credential: Demo.credential("A"), cancellation: Cancellation())
        XCTAssertEqual(q.primary?.remaining, 75)
    }
    func testOfficialLoginContractAndEarlyCompletionNotification() throws {
        var opened: URL?
        let credential = try AppServer.login(binary: mock("login"), cancellation: Cancellation()) { opened = $0 }
        XCTAssertEqual(opened?.host, "auth.openai.com")
        XCTAssertEqual(credential.identity.key, try Demo.credential("B").identity.key)
    }
    func testServerRefreshRequestIsRefused() throws {
        XCTAssertThrowsError(try AppServer.quota(binary: mock("refresh"), credential: Demo.credential("A"), cancellation: Cancellation())) { XCTAssertEqual($0 as? SwitcherError, .expired) }
    }
    func test429PreservedAsRateLimit() throws {
        XCTAssertThrowsError(try AppServer.quota(binary: mock("429"), credential: Demo.credential("A"), cancellation: Cancellation())) { XCTAssertEqual($0 as? SwitcherError, .rateLimited) }
    }
    func testMalformedProtocolFailsClosed() throws {
        XCTAssertThrowsError(try AppServer.quota(binary: mock("malformed"), credential: Demo.credential("A"), cancellation: Cancellation())) { XCTAssertEqual($0 as? SwitcherError, .protocolError) }
    }
    func testCancellationTerminatesOnlyOwnedChildPromptly() throws {
        let token = Cancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { token.cancel() }
        let start = Date()
        XCTAssertThrowsError(try AppServer.quota(binary: mock("slow"), credential: Demo.credential("A"), cancellation: token)) { XCTAssertEqual($0 as? SwitcherError, .cancelled) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }
    func testKeychainFailureNeverWritesMain() throws {
        final class Denied: SecretStore {
            func put(_ data: Data) throws -> String { throw SwitcherError.keychain }
            func get(_ reference: String) throws -> Data { throw SwitcherError.keychain }
            func remove(_ reference: String) throws { throw SwitcherError.keychain }
        }
        let home = root.appendingPathComponent("home"); try SecureIO.prepareDirectory(home)
        let auth = home.appendingPathComponent("auth.json"), original = try Demo.credential("A").data
        try SecureIO.write(original, to: auth)
        let engine = try Engine(root: root.appendingPathComponent("state"), authURL: auth, secrets: Denied(), writersStopped: {}, environmentAllowed: {})
        XCTAssertThrowsError(try engine.importCurrent()) { XCTAssertEqual($0 as? SwitcherError, .keychain) }
        XCTAssertEqual(try SecureIO.read(auth), original); XCTAssertEqual(try engine.snapshot().accounts.count, 0)
    }
    func testOwnedWorkspaceCleanupPreservesActiveAndForeignDirectories() throws {
        let live = try LoginWorkspace(base: root)
        let dead = root.appendingPathComponent(UUID().uuidString), foreign = root.appendingPathComponent(UUID().uuidString)
        try SecureIO.prepareDirectory(dead); try SecureIO.prepareDirectory(foreign)
        try SecureIO.write(canonical(["kind": "codex-account-switcher-login-v1", "uid": getuid(), "parent": Int32.max]), to: dead.appendingPathComponent("switcher-owner.json"))
        try SecureIO.write(Data("foreign".utf8), to: foreign.appendingPathComponent("sentinel"))
        try LoginWorkspace.cleanup(base: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        try live.remove()
    }
}
