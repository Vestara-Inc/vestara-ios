import XCTest
import Foundation
@testable import VestaraSDK

// MARK: - Mock URLProtocol for Controlled Ingest Testing

final class MockURLProtocol: URLProtocol {
  static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?

  override class func canInit(with request: URLRequest) -> Bool {
    return true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    return request
  }

  override func startLoading() {
    guard let handler = MockURLProtocol.requestHandler else {
      client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: -1, userInfo: nil))
      return
    }

    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      if let data = data {
        client?.urlProtocol(self, didLoad: data)
      }
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

// MARK: - Crash Reliability Test Suite

final class CrashReliabilityTests: XCTestCase {
  private var testDirectory: URL?
  private let dummyAPIURL = URL(string: "https://vestara-mock-test.local")!

  override func setUp() {
    super.setUp()
    let uniqueID = UUID().uuidString
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vestara-tests-\(uniqueID)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    testDirectory = dir
    CrashHandler.customCrashDirectoryURL = dir
    Vestara.resetForTesting()
    MockURLProtocol.requestHandler = nil
  }

  override func tearDown() {
    Vestara.resetForTesting()
    CrashHandler.customCrashDirectoryURL = nil
    if let dir = testDirectory {
      try? FileManager.default.removeItem(at: dir)
      testDirectory = nil
    }
    MockURLProtocol.requestHandler = nil
    super.tearDown()
  }

  private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
  }

  @discardableResult
  private func createTestCrashFile(named name: String, message: String = "Fatal test crash", environment: String = "production") -> URL {
    let directory = CrashHandler.crashDirectoryURL()
    let fileURL = directory.appendingPathComponent(name)
    let content = [
      "type=exception",
      "name=TestCrash",
      "message=\(message)",
      "stack=frame1\\nframe2",
      "session_id=\(UUID().uuidString)",
      "device_id=test-device-uuid",
      "environment=\(environment)",
      "sdk_version=0.1.4",
      "app_version=1.0.0",
      "os_version=18.0",
      "device_model=iPhone",
      "target_category=ios_app",
    ].joined(separator: "\n")
    try! content.write(to: fileURL, atomically: true, encoding: .utf8)
    return fileURL
  }

  private func extractBody(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
      return body
    }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var buffer = [UInt8](repeating: 0, count: 4096)
    var data = Data()
    while stream.hasBytesAvailable {
      let read = stream.read(&buffer, maxLength: buffer.count)
      if read > 0 {
        data.append(buffer, count: read)
      } else {
        break
      }
    }
    return data
  }

  // MARK: - Blocker 1: Periodic Tick and Foreground Recovery Tests

  func testPeriodicTickRetriesWhenBackoffPermitsAndDeletesAcknowledgedFile() {
    let fileURL = createTestCrashFile(named: "pending-periodic-retry.crash")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

    var simulatedNow = Date()
    let session = makeMockSession()
    let crashHandler = CrashHandler()
    let queue = EventQueue()
    let uploader = Uploader(
      queue: queue,
      token: "test-token",
      apiURL: dummyAPIURL,
      crashHandler: crashHandler,
      session: session
    )
    uploader.nowProvider = { simulatedNow }

    var attemptCount = 0
    MockURLProtocol.requestHandler = { request in
      attemptCount += 1
      if attemptCount == 1 {
        // First attempt fails with network error
        throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
      } else {
        // Subsequent attempt succeeds
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let body = try! JSONSerialization.data(withJSONObject: ["accepted": 1, "rejected": 0], options: [])
        return (response, body)
      }
    }

    // Step 1: Periodic tick triggers initial attempt, which fails
    uploader.performPeriodicTick()

    let exp1 = expectation(description: "first attempt finished")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertEqual(attemptCount, 1)
      XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "File must be retained when upload fails")
      XCTAssertEqual(uploader.currentCrashRetryDelay, 20.0, "Backoff should have doubled to 20s")
      exp1.fulfill()
    }
    wait(for: [exp1], timeout: 1.0)

    // Step 2: Periodic tick immediately without advancing time (elapsed 0s < 20s backoff) -> must NOT retry
    uploader.performPeriodicTick()

    let exp2 = expectation(description: "immediate periodic tick suppressed by backoff")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
      XCTAssertEqual(attemptCount, 1, "Should not retry before backoff duration has elapsed")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
      exp2.fulfill()
    }
    wait(for: [exp2], timeout: 1.0)

    // Step 3: Advance simulated time beyond 20s backoff
    simulatedNow = simulatedNow.addingTimeInterval(25.0)

    // Periodic tick now permits retry and succeeds
    uploader.performPeriodicTick()

    let exp3 = expectation(description: "periodic tick after backoff succeeds")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertEqual(attemptCount, 2)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "File must be deleted after acknowledged retry")
      exp3.fulfill()
    }
    wait(for: [exp3], timeout: 1.0)
  }

  func testForegroundRecoveryTriggersUploadAndDeletesFile() {
    let session = makeMockSession()
    var uploadCount = 0
    let exp = expectation(description: "foreground recovery uploads crash")

    MockURLProtocol.requestHandler = { request in
      if request.url?.path.contains("v1/ingest") == true {
        uploadCount += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let body = try! JSONSerialization.data(withJSONObject: ["accepted": 1, "rejected": 0], options: [])
        exp.fulfill()
        return (response, body)
      } else {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let body = try! JSONSerialization.data(withJSONObject: ["logging_enabled": true], options: [])
        return (response, body)
      }
    }

    // 1. Configure Vestara using mocked URLSession while NO crash file exists
    Vestara.internalConfigure(
      token: "test-token",
      apiURL: dummyAPIURL,
      environment: "production",
      autoRum: false,
      session: session
    )

    // 2. Ensure configuration-time work cannot satisfy the foreground ingest expectation
    XCTAssertEqual(uploadCount, 0, "No crash upload request must occur during configure when no crash file exists")

    // 3. Create the persisted crash AFTER configuration
    let fileURL = createTestCrashFile(named: "pending-foreground-recovery.crash")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

    // 4. Invoke production foreground recovery directly
    Vestara.handleAppDidBecomeActive()

    // 5. Prove exactly one crash ingest request occurs from that recovery action
    wait(for: [exp], timeout: 2.0)
    XCTAssertEqual(uploadCount, 1, "Exactly one crash ingest request must occur from foreground recovery")

    // 6. Prove the acknowledged crash file is deleted
    let expFile = expectation(description: "file deleted")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "Crash file must be deleted upon acknowledgement")
      expFile.fulfill()
    }
    wait(for: [expFile], timeout: 1.0)
  }

  // MARK: - Blocker 2: Mock URLSession Injection and Environment Tests

  func testConfiguringSDKWithLiveEmitsProductionEnvironment() {
    let session = makeMockSession()
    var capturedBody: [String: Any]?
    let exp = expectation(description: "ingest called with live environment")

    MockURLProtocol.requestHandler = { request in
      if request.url?.path.contains("v1/ingest") == true {
        if let data = self.extractBody(from: request),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let events = json["events"] as? [[String: Any]],
           let first = events.first,
           let payload = first["payload"] as? [String: Any],
           payload["message"] as? String == "Testing live normalization" {
          capturedBody = json
          exp.fulfill()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let body = try! JSONSerialization.data(withJSONObject: ["accepted": 1, "rejected": 0], options: [])
        return (response, body)
      } else {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let body = try! JSONSerialization.data(withJSONObject: ["logging_enabled": true], options: [])
        return (response, body)
      }
    }

    Vestara.internalConfigure(
      token: "test-token",
      apiURL: dummyAPIURL,
      environment: "live",
      autoRum: false,
      session: session
    )

    Vestara.log(.info, "Testing live normalization")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
      Vestara.flushForTesting()
    }

    wait(for: [exp], timeout: 2.0)

    let events = capturedBody?["events"] as? [[String: Any]]
    let firstEvent = events?.first
    XCTAssertEqual(firstEvent?["environment"] as? String, "production")
  }

  func testConfiguringSDKWithDevEmitsDevelopmentEnvironment() {
    let session = makeMockSession()
    var capturedBody: [String: Any]?
    let exp = expectation(description: "ingest called with dev environment")

    MockURLProtocol.requestHandler = { request in
      if request.url?.path.contains("v1/ingest") == true {
        if let data = self.extractBody(from: request),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let events = json["events"] as? [[String: Any]],
           let first = events.first,
           let payload = first["payload"] as? [String: Any],
           payload["message"] as? String == "Testing dev normalization" {
          capturedBody = json
          exp.fulfill()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let body = try! JSONSerialization.data(withJSONObject: ["accepted": 1, "rejected": 0], options: [])
        return (response, body)
      } else {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let body = try! JSONSerialization.data(withJSONObject: ["logging_enabled": true], options: [])
        return (response, body)
      }
    }

    Vestara.internalConfigure(
      token: "test-token",
      apiURL: dummyAPIURL,
      environment: "dev",
      autoRum: false,
      session: session
    )

    Vestara.log(.info, "Testing dev normalization")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
      Vestara.flushForTesting()
    }

    wait(for: [exp], timeout: 2.0)

    let events = capturedBody?["events"] as? [[String: Any]]
    let firstEvent = events?.first
    XCTAssertEqual(firstEvent?["environment"] as? String, "development")
  }

  // MARK: - Blocker 3: Directory Isolation Verification

  func testIsolatedCrashDirectoryDoesNotTouchNormalCaches() {
    guard let testDir = testDirectory else {
      XCTFail("testDirectory must be configured")
      return
    }

    let activeDir = CrashHandler.crashDirectoryURL()
    XCTAssertEqual(activeDir.path, testDir.path, "Crash directory must point to the isolated temporary directory")
    XCTAssertTrue(FileManager.default.fileExists(atPath: activeDir.path))
  }

  // MARK: - Blocker 4: Signal Persistence Does Not Overwrite Earlier Crash

  func testSignalCrashPersistenceDoesNotOverwriteEarlierCrash() {
    let fileNameA = "pending-signal-A-\(UUID().uuidString).crash"
    let fileNameB = "pending-signal-B-\(UUID().uuidString).crash"
    let dir = CrashHandler.crashDirectoryURL()
    let fileA = dir.appendingPathComponent(fileNameA)
    let fileB = dir.appendingPathComponent(fileNameB)

    // Step 1 & 2: Prepare signal context/path A and invoke production signal persistence
    CrashHandler.prepareSignalContext(uniqueFileName: fileNameA)
    CrashHandler.persistSignal(SIGSEGV)

    // Step 3: Verify file A exists and contains crash data
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileA.path), "File A must exist")
    let contentsA = try? String(contentsOf: fileA, encoding: .utf8)
    XCTAssertNotNil(contentsA)
    XCTAssertTrue(contentsA?.contains("type=signal") == true)
    XCTAssertTrue(contentsA?.contains("signal=11") == true)

    // Step 4 & 5: Prepare signal context/path B and invoke production signal persistence
    CrashHandler.prepareSignalContext(uniqueFileName: fileNameB)
    CrashHandler.persistSignal(SIGBUS)

    // Step 6: Verify file A still exists unchanged, file B exists, and they are distinct
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileA.path), "File A must still exist")
    let currentContentsA = try? String(contentsOf: fileA, encoding: .utf8)
    XCTAssertEqual(contentsA, currentContentsA, "File A contents must remain completely unchanged")

    XCTAssertTrue(FileManager.default.fileExists(atPath: fileB.path), "File B must exist")
    let contentsB = try? String(contentsOf: fileB, encoding: .utf8)
    XCTAssertNotNil(contentsB)
    XCTAssertTrue(contentsB?.contains("type=signal") == true)
    XCTAssertTrue(contentsB?.contains("signal=10") == true)

    XCTAssertNotEqual(fileA.path, fileB.path, "File A and File B must be distinct files")
  }

  // MARK: - Blocker 5: Rejection Backoff Not Reset by Later Successes

  func testRejectionBackoffIsNotResetByLaterSuccessInSameCycle() {
    let file1 = createTestCrashFile(named: "pending-fail-first.crash", message: "crash-rejected")
    let file2 = createTestCrashFile(named: "pending-pass-second.crash", message: "crash-accepted")

    let session = makeMockSession()
    let crashHandler = CrashHandler()
    let uploader = Uploader(
      queue: EventQueue(),
      token: "test-token",
      apiURL: dummyAPIURL,
      crashHandler: crashHandler,
      session: session
    )

    MockURLProtocol.requestHandler = { request in
      let bodyData = self.extractBody(from: request)
      var isAccepted = false
      if let data = bodyData, let str = String(data: data, encoding: .utf8) {
        if str.contains("crash-accepted") {
          isAccepted = true
        }
      }

      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      let body = try! JSONSerialization.data(
        withJSONObject: isAccepted ? ["accepted": 1, "rejected": 0] : ["accepted": 0, "rejected": 1],
        options: []
      )
      return (response, body)
    }

    XCTAssertEqual(uploader.currentCrashRetryDelay, 10.0, "Initial retry delay should be 10s")

    uploader.uploadPendingCrashes(force: true)

    let exp = expectation(description: "mixed cycle completed")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
      // First crash was rejected -> must remain on disk
      XCTAssertTrue(FileManager.default.fileExists(atPath: file1.path), "Rejected crash file must remain")
      // Second crash was accepted -> must be deleted
      XCTAssertFalse(FileManager.default.fileExists(atPath: file2.path), "Acknowledged crash file must be deleted")
      // Retry delay must remain backed off to 20.0s (NOT reset to 10.0s by crash 2's success)
      XCTAssertEqual(uploader.currentCrashRetryDelay, 20.0, "Rejection backoff must not be reset by later successes in cycle")
      exp.fulfill()
    }
    wait(for: [exp], timeout: 1.5)
  }

  // MARK: - Blocker 6: Normalize Already Persisted Live/Dev Crashes

  func testPersistedCrashWithLiveEnvironmentNormalizedToProductionOnUpload() {
    let fileURL = createTestCrashFile(named: "pending-legacy-live.crash", environment: "live")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

    let session = makeMockSession()
    let crashHandler = CrashHandler()
    let uploader = Uploader(
      queue: EventQueue(),
      token: "test-token",
      apiURL: dummyAPIURL,
      crashHandler: crashHandler,
      session: session
    )

    var capturedEnv: String?
    let exp = expectation(description: "legacy live crash uploaded")

    MockURLProtocol.requestHandler = { request in
      if let data = self.extractBody(from: request),
         let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let events = json["events"] as? [[String: Any]],
         let first = events.first {
        capturedEnv = first["environment"] as? String
      }

      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      let body = try! JSONSerialization.data(withJSONObject: ["accepted": 1, "rejected": 0], options: [])
      exp.fulfill()
      return (response, body)
    }

    uploader.uploadPendingCrashes(force: true)

    wait(for: [exp], timeout: 1.5)
    XCTAssertEqual(capturedEnv, "production", "Legacy 'live' environment must be normalized to 'production' in outbound payload")

    let expDelete = expectation(description: "file deleted after ack")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "Acknowledged file must be deleted")
      expDelete.fulfill()
    }
    wait(for: [expDelete], timeout: 1.0)
  }

  func testPersistedCrashWithDevEnvironmentNormalizedToDevelopmentOnUpload() {
    let fileURL = createTestCrashFile(named: "pending-legacy-dev.crash", environment: "dev")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

    let session = makeMockSession()
    let crashHandler = CrashHandler()
    let uploader = Uploader(
      queue: EventQueue(),
      token: "test-token",
      apiURL: dummyAPIURL,
      crashHandler: crashHandler,
      session: session
    )

    var capturedEnv: String?
    let exp = expectation(description: "legacy dev crash uploaded")

    MockURLProtocol.requestHandler = { request in
      if let data = self.extractBody(from: request),
         let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let events = json["events"] as? [[String: Any]],
         let first = events.first {
        capturedEnv = first["environment"] as? String
      }

      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      let body = try! JSONSerialization.data(withJSONObject: ["accepted": 1, "rejected": 0], options: [])
      exp.fulfill()
      return (response, body)
    }

    uploader.uploadPendingCrashes(force: true)

    wait(for: [exp], timeout: 1.5)
    XCTAssertEqual(capturedEnv, "development", "Legacy 'dev' environment must be normalized to 'development' in outbound payload")

    let expDelete = expectation(description: "file deleted after ack")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "Acknowledged file must be deleted")
      expDelete.fulfill()
    }
    wait(for: [expDelete], timeout: 1.0)
  }

  // MARK: - Exact Backend Acknowledgement Regression Tests

  func testCrashDeletedOnlyWhenAccepted1Rejected0() {
    let fileURL = createTestCrashFile(named: "pending-exact-ack.crash")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

    let session = makeMockSession()
    let crashHandler = CrashHandler()
    let uploader = Uploader(
      queue: EventQueue(),
      token: "test-token",
      apiURL: dummyAPIURL,
      crashHandler: crashHandler,
      session: session
    )

    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      let body = try! JSONSerialization.data(withJSONObject: ["accepted": 1, "rejected": 0], options: [])
      return (response, body)
    }

    uploader.uploadPendingCrashes(force: true)

    let exp = expectation(description: "file deleted")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
      exp.fulfill()
    }
    wait(for: [exp], timeout: 1.0)
  }

  func testCrashRetainedWhenBackendReturnsAccepted0Rejected1() {
    let fileURL = createTestCrashFile(named: "pending-backend-rejection.crash")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

    let session = makeMockSession()
    let crashHandler = CrashHandler()
    let uploader = Uploader(
      queue: EventQueue(),
      token: "test-token",
      apiURL: dummyAPIURL,
      crashHandler: crashHandler,
      session: session
    )

    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      let body = try! JSONSerialization.data(withJSONObject: ["accepted": 0, "rejected": 1], options: [])
      return (response, body)
    }

    uploader.uploadPendingCrashes(force: true)

    let exp = expectation(description: "file retained on rejection")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
      exp.fulfill()
    }
    wait(for: [exp], timeout: 1.0)
  }

  func testCrashRetainedOnHttp500() {
    let fileURL = createTestCrashFile(named: "pending-http-500.crash")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

    let session = makeMockSession()
    let crashHandler = CrashHandler()
    let uploader = Uploader(
      queue: EventQueue(),
      token: "test-token",
      apiURL: dummyAPIURL,
      crashHandler: crashHandler,
      session: session
    )

    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
      let body = "Internal Server Error".data(using: .utf8)
      return (response, body)
    }

    uploader.uploadPendingCrashes(force: true)

    let exp = expectation(description: "file retained on HTTP 500")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
      exp.fulfill()
    }
    wait(for: [exp], timeout: 1.0)
  }

  func testCrashRetainedOnNetworkFailure() {
    let fileURL = createTestCrashFile(named: "pending-network-failure.crash")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

    let session = makeMockSession()
    let crashHandler = CrashHandler()
    let uploader = Uploader(
      queue: EventQueue(),
      token: "test-token",
      apiURL: dummyAPIURL,
      crashHandler: crashHandler,
      session: session
    )

    MockURLProtocol.requestHandler = { _ in
      throw NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: nil)
    }

    uploader.uploadPendingCrashes(force: true)

    let exp = expectation(description: "file retained on network failure")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
      exp.fulfill()
    }
    wait(for: [exp], timeout: 1.0)
  }

  func testCrashRetainedOnMalformed2xxResponse() {
    let fileURL = createTestCrashFile(named: "pending-malformed-2xx.crash")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

    let session = makeMockSession()
    let crashHandler = CrashHandler()
    let uploader = Uploader(
      queue: EventQueue(),
      token: "test-token",
      apiURL: dummyAPIURL,
      crashHandler: crashHandler,
      session: session
    )

    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      let body = "OK but not json".data(using: .utf8)
      return (response, body)
    }

    uploader.uploadPendingCrashes(force: true)

    let exp = expectation(description: "file retained on non-json 200")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
      exp.fulfill()
    }
    wait(for: [exp], timeout: 1.0)
  }

  func testMultiplePendingCrashesMixedOutcomesOnlyDeletesAcknowledged() {
    let file1 = createTestCrashFile(named: "pending-mixed-1.crash", message: "crash-acknowledged")
    let file2 = createTestCrashFile(named: "pending-mixed-2.crash", message: "crash-rejected")

    let session = makeMockSession()
    let crashHandler = CrashHandler()
    let uploader = Uploader(
      queue: EventQueue(),
      token: "test-token",
      apiURL: dummyAPIURL,
      crashHandler: crashHandler,
      session: session
    )

    MockURLProtocol.requestHandler = { request in
      let bodyData = self.extractBody(from: request)
      var isAccepted = false
      if let data = bodyData, let str = String(data: data, encoding: .utf8) {
        if str.contains("crash-acknowledged") {
          isAccepted = true
        }
      }

      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      let body = try! JSONSerialization.data(
        withJSONObject: isAccepted ? ["accepted": 1, "rejected": 0] : ["accepted": 0, "rejected": 1],
        options: []
      )
      return (response, body)
    }

    uploader.uploadPendingCrashes(force: true)

    let exp = expectation(description: "first deleted, second retained")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
      XCTAssertFalse(FileManager.default.fileExists(atPath: file1.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: file2.path))
      exp.fulfill()
    }
    wait(for: [exp], timeout: 1.5)
  }

  func testBeforeSendDroppingCrashDeletesFile() {
    let fileURL = createTestCrashFile(named: "pending-beforesend-drop.crash")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

    let session = makeMockSession()
    let crashHandler = CrashHandler()
    let uploader = Uploader(
      queue: EventQueue(),
      token: "test-token",
      apiURL: dummyAPIURL,
      crashHandler: crashHandler,
      beforeSend: { _ in
        return nil // Intentional drop
      },
      session: session
    )

    uploader.uploadPendingCrashes(force: true)

    let exp = expectation(description: "file deleted when beforeSend returns nil")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
      exp.fulfill()
    }
    wait(for: [exp], timeout: 1.0)
  }

  // MARK: - Concurrency & Synchronization

  func testConcurrentContextUpdatesAndExceptionPersistence() {
    let crashHandler = CrashHandler()
    let iterations = 100
    let group = DispatchGroup()

    for i in 0..<iterations {
      group.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        crashHandler.updateUser(id: "user-\(i)", email: "user-\(i)@test.com")
        crashHandler.updateBreadcrumbSnapshot("[{\"message\":\"crumb-\(i)\"}]")
        group.leave()
      }

      group.enter()
      DispatchQueue.global(qos: .utility).async {
        let exception = NSException(name: NSExceptionName("TestConcurrencyException"), reason: "Testing races", userInfo: nil)
        CrashHandler.handleException(exception)
        group.leave()
      }
    }

    let result = group.wait(timeout: .now() + 3.0)
    XCTAssertEqual(result, .success, "Concurrent context updates and crash writes must not deadlock or crash")
  }

  // MARK: - Environment Normalization Unit Tests

  func testEnvironmentNormalizationUnit() {
    XCTAssertEqual(Vestara.normalizeEnvironment("live"), "production")
    XCTAssertEqual(Vestara.normalizeEnvironment("Live"), "production")
    XCTAssertEqual(Vestara.normalizeEnvironment("LIVE"), "production")
    XCTAssertEqual(Vestara.normalizeEnvironment("dev"), "development")
    XCTAssertEqual(Vestara.normalizeEnvironment("Dev"), "development")
    XCTAssertEqual(Vestara.normalizeEnvironment("DEV"), "development")
    XCTAssertEqual(Vestara.normalizeEnvironment("production"), "production")
    XCTAssertEqual(Vestara.normalizeEnvironment("staging"), "staging")
    XCTAssertEqual(Vestara.normalizeEnvironment("development"), "development")
    XCTAssertEqual(Vestara.normalizeEnvironment("preview"), "preview")
    XCTAssertEqual(Vestara.normalizeEnvironment("custom_qa"), "custom_qa")
  }

  // MARK: - Blocker 1: Lifecycle & Foreground Retries Respect Backoff

  func testForegroundAndLifecycleRetriesRespectExponentialBackoff() {
    let fileURL = createTestCrashFile(named: "pending-lifecycle-backoff.crash")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

    var simulatedNow = Date()
    let session = makeMockSession()
    let crashHandler = CrashHandler()
    let queue = EventQueue()
    let uploader = Uploader(
      queue: queue,
      token: "test-token",
      apiURL: dummyAPIURL,
      crashHandler: crashHandler,
      session: session
    )
    uploader.nowProvider = { simulatedNow }

    var requestCount = 0
    var shouldReject = true

    MockURLProtocol.requestHandler = { request in
      if request.url?.path.contains("v1/ingest") == true {
        requestCount += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let body = try! JSONSerialization.data(
          withJSONObject: shouldReject ? ["accepted": 0, "rejected": 1] : ["accepted": 1, "rejected": 0],
          options: []
        )
        return (response, body)
      } else {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let body = try! JSONSerialization.data(withJSONObject: ["logging_enabled": true], options: [])
        return (response, body)
      }
    }

    // 1. First upload fails/rejects
    uploader.uploadPendingCrashes(force: true)

    let exp1 = expectation(description: "first attempt failed/rejected")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertEqual(requestCount, 1)
      XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "File must be retained upon rejection")
      // 2. Retry delay increases to 20s
      XCTAssertEqual(uploader.currentCrashRetryDelay, 20.0, "Retry delay must double to 20.0s")
      exp1.fulfill()
    }
    wait(for: [exp1], timeout: 1.0)

    // 3. Foreground/lifecycle recovery before delay expiration does NOT make another request
    // Advance simulated time by 5s (5s elapsed < 20s delay)
    simulatedNow = simulatedNow.addingTimeInterval(5.0)

    // 5. Prove repeated lifecycle events cannot hammer the uploader inside the backoff window
    uploader.uploadPendingCrashes(force: true)
    uploader.uploadPendingCrashes(force: true)
    uploader.uploadPendingCrashes(force: false)
    uploader.performPeriodicTick()

    let exp2 = expectation(description: "lifecycle triggers inside backoff window are suppressed")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertEqual(requestCount, 1, "Repeated lifecycle triggers inside backoff window must NOT create additional requests")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
      exp2.fulfill()
    }
    wait(for: [exp2], timeout: 1.0)

    // 4. Periodic/lifecycle retry after simulated time advances beyond delay DOES retry
    // Advance simulated time by 20s more (total 25s elapsed >= 20s delay)
    simulatedNow = simulatedNow.addingTimeInterval(20.0)
    shouldReject = false

    uploader.uploadPendingCrashes(force: true)

    let exp3 = expectation(description: "retry after backoff expiration succeeds")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertEqual(requestCount, 2, "Upload must retry once backoff delay has elapsed")
      XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "File must be deleted after acknowledged retry")
      XCTAssertEqual(uploader.currentCrashRetryDelay, 10.0, "Retry delay must reset to 10.0s upon success")
      exp3.fulfill()
    }
    wait(for: [exp3], timeout: 1.0)
  }

  func testVestaraForegroundRecoverySuppressedByBackoffUntilDelayExpires() {
    var simulatedNow = Date()
    Uploader.defaultNowProvider = { simulatedNow }
    defer { Uploader.defaultNowProvider = nil }

    let session = makeMockSession()
    var requestCount = 0
    var shouldReject = true

    MockURLProtocol.requestHandler = { request in
      if request.url?.path.contains("v1/ingest") == true {
        requestCount += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let body = try! JSONSerialization.data(
          withJSONObject: shouldReject ? ["accepted": 0, "rejected": 1] : ["accepted": 1, "rejected": 0],
          options: []
        )
        return (response, body)
      } else {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let body = try! JSONSerialization.data(withJSONObject: ["logging_enabled": true], options: [])
        return (response, body)
      }
    }

    // Configure Vestara while NO crash exists
    Vestara.internalConfigure(
      token: "test-token",
      apiURL: dummyAPIURL,
      environment: "production",
      autoRum: false,
      session: session
    )

    let fileURL = createTestCrashFile(named: "pending-vestara-backoff.crash")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

    // Initial foreground recovery attempt fails/rejects
    Vestara.handleAppDidBecomeActive()

    let exp1 = expectation(description: "initial foreground attempt fails")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertEqual(requestCount, 1)
      XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
      exp1.fulfill()
    }
    wait(for: [exp1], timeout: 1.0)

    // Advance 5s (inside 20s backoff) and trigger foreground repeatedly
    simulatedNow = simulatedNow.addingTimeInterval(5.0)
    Vestara.handleAppDidBecomeActive()
    Vestara.handleAppDidBecomeActive()

    let exp2 = expectation(description: "repeated foreground within backoff window does not request")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertEqual(requestCount, 1, "Foregrounding within backoff window must NOT bypass backoff")
      XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
      exp2.fulfill()
    }
    wait(for: [exp2], timeout: 1.0)

    // Advance 20s more (25s total >= 20s backoff)
    simulatedNow = simulatedNow.addingTimeInterval(20.0)
    shouldReject = false

    Vestara.handleAppDidBecomeActive()

    let exp3 = expectation(description: "foregrounding after backoff expires succeeds")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertEqual(requestCount, 2)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
      exp3.fulfill()
    }
    wait(for: [exp3], timeout: 1.0)
  }

  // MARK: - Blocker 2: Regular Queued Events Ingest Acknowledgement Tests

  func testQueuedEventsFullAcceptanceRemovesQueue() {
    let session = makeMockSession()
    let queue = EventQueue()
    let crashHandler = CrashHandler()
    let uploader = Uploader(
      queue: queue,
      token: "test-token",
      apiURL: dummyAPIURL,
      crashHandler: crashHandler,
      session: session
    )

    let eventCount = 3
    for i in 1...eventCount {
      queue.enqueue(["event_type": "log", "message": "event-\(i)"])
    }
    XCTAssertEqual(queue.count(), 3)

    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      let body = try! JSONSerialization.data(withJSONObject: ["accepted": 3, "rejected": 0], options: [])
      return (response, body)
    }

    uploader.flushQueuedEvents()

    let exp = expectation(description: "queue fully accepted and removed")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertEqual(queue.count(), 0, "Queued events must be removed when accepted == N and rejected == 0")
      exp.fulfill()
    }
    wait(for: [exp], timeout: 1.0)
  }

  func testQueuedEventsFullRejectionRetainsQueue() {
    let session = makeMockSession()
    let queue = EventQueue()
    let crashHandler = CrashHandler()
    let uploader = Uploader(
      queue: queue,
      token: "test-token",
      apiURL: dummyAPIURL,
      crashHandler: crashHandler,
      session: session
    )

    let eventCount = 3
    for i in 1...eventCount {
      queue.enqueue(["event_type": "log", "message": "event-\(i)"])
    }
    XCTAssertEqual(queue.count(), 3)

    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      let body = try! JSONSerialization.data(withJSONObject: ["accepted": 0, "rejected": 3], options: [])
      return (response, body)
    }

    uploader.flushQueuedEvents()

    let exp = expectation(description: "queue retained on full rejection")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertEqual(queue.count(), 3, "Queued events must be retained when accepted == 0 and rejected == N")
      exp.fulfill()
    }
    wait(for: [exp], timeout: 1.0)
  }

  func testQueuedEventsPartialAcceptanceRetainsWholeQueue() {
    let session = makeMockSession()
    let queue = EventQueue()
    let crashHandler = CrashHandler()
    let uploader = Uploader(
      queue: queue,
      token: "test-token",
      apiURL: dummyAPIURL,
      crashHandler: crashHandler,
      session: session
    )

    let eventCount = 3
    for i in 1...eventCount {
      queue.enqueue(["event_type": "log", "message": "event-\(i)"])
    }
    XCTAssertEqual(queue.count(), 3)

    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      let body = try! JSONSerialization.data(withJSONObject: ["accepted": 1, "rejected": 2], options: [])
      return (response, body)
    }

    uploader.flushQueuedEvents()

    let exp = expectation(description: "queue retained on partial acceptance")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertEqual(queue.count(), 3, "Original queued batch must remain when partial acceptance occurs")
      exp.fulfill()
    }
    wait(for: [exp], timeout: 1.0)
  }

  func testQueuedEventsMalformed2xxRetainsQueue() {
    let session = makeMockSession()
    let queue = EventQueue()
    let crashHandler = CrashHandler()
    let uploader = Uploader(
      queue: queue,
      token: "test-token",
      apiURL: dummyAPIURL,
      crashHandler: crashHandler,
      session: session
    )

    let eventCount = 3
    for i in 1...eventCount {
      queue.enqueue(["event_type": "log", "message": "event-\(i)"])
    }
    XCTAssertEqual(queue.count(), 3)

    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      let body = "OK but not json".data(using: .utf8)
      return (response, body)
    }

    uploader.flushQueuedEvents()

    let exp = expectation(description: "queue retained on malformed 2xx")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertEqual(queue.count(), 3, "Queued events must remain when 2xx response has invalid/missing acknowledgement JSON")
      exp.fulfill()
    }
    wait(for: [exp], timeout: 1.0)
  }

  func testQueuedEventsHttpOrNetworkFailureRetainsQueue() {
    let session = makeMockSession()
    let queue = EventQueue()
    let crashHandler = CrashHandler()
    let uploader = Uploader(
      queue: queue,
      token: "test-token",
      apiURL: dummyAPIURL,
      crashHandler: crashHandler,
      session: session
    )

    let eventCount = 3
    for i in 1...eventCount {
      queue.enqueue(["event_type": "log", "message": "event-\(i)"])
    }
    XCTAssertEqual(queue.count(), 3)

    MockURLProtocol.requestHandler = { _ in
      throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
    }

    uploader.flushQueuedEvents()

    let exp = expectation(description: "queue retained on network failure")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertEqual(queue.count(), 3, "Queued events must remain on network failure or HTTP error")
      exp.fulfill()
    }
    wait(for: [exp], timeout: 1.0)
  }

  // MARK: - Blocker: Recover already-queued live/dev telemetry

  func testExistingQueuedLiveEventNormalizedToProductionOnFlush() {
    let session = makeMockSession()
    let queue = EventQueue()
    let crashHandler = CrashHandler()
    let uploader = Uploader(
      queue: queue,
      token: "test-token",
      apiURL: dummyAPIURL,
      crashHandler: crashHandler,
      session: session
    )

    queue.enqueue([
      "event_type": "log",
      "message": "queued-live-log",
      "environment": "live",
    ])
    XCTAssertEqual(queue.count(), 1)

    var outboundEnvironment: String?
    let exp = expectation(description: "outbound live normalized to production")

    MockURLProtocol.requestHandler = { request in
      if let data = self.extractBody(from: request),
         let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let events = json["events"] as? [[String: Any]],
         let first = events.first {
        outboundEnvironment = first["environment"] as? String
      }

      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      let body = try! JSONSerialization.data(withJSONObject: ["accepted": 1, "rejected": 0], options: [])
      exp.fulfill()
      return (response, body)
    }

    uploader.flushQueuedEvents()

    wait(for: [exp], timeout: 1.0)
    XCTAssertEqual(outboundEnvironment, "production", "Outbound queued event with 'live' environment must be normalized to 'production'")

    let expDelete = expectation(description: "queued event removed after full acceptance")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertEqual(queue.count(), 0, "Queued event must be removed after successful acknowledgement")
      expDelete.fulfill()
    }
    wait(for: [expDelete], timeout: 1.0)
  }

  func testExistingQueuedDevEventNormalizedToDevelopmentOnFlush() {
    let session = makeMockSession()
    let queue = EventQueue()
    let crashHandler = CrashHandler()
    let uploader = Uploader(
      queue: queue,
      token: "test-token",
      apiURL: dummyAPIURL,
      crashHandler: crashHandler,
      session: session
    )

    queue.enqueue([
      "event_type": "log",
      "message": "queued-dev-log",
      "environment": "dev",
    ])
    XCTAssertEqual(queue.count(), 1)

    var outboundEnvironment: String?
    let exp = expectation(description: "outbound dev normalized to development")

    MockURLProtocol.requestHandler = { request in
      if let data = self.extractBody(from: request),
         let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let events = json["events"] as? [[String: Any]],
         let first = events.first {
        outboundEnvironment = first["environment"] as? String
      }

      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      let body = try! JSONSerialization.data(withJSONObject: ["accepted": 1, "rejected": 0], options: [])
      exp.fulfill()
      return (response, body)
    }

    uploader.flushQueuedEvents()

    wait(for: [exp], timeout: 1.0)
    XCTAssertEqual(outboundEnvironment, "development", "Outbound queued event with 'dev' environment must be normalized to 'development'")

    let expDelete = expectation(description: "queued event removed after full acceptance")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertEqual(queue.count(), 0, "Queued event must be removed after successful acknowledgement")
      expDelete.fulfill()
    }
    wait(for: [expDelete], timeout: 1.0)
  }

  func testExistingQueuedUnknownEnvironmentRemainsUnchangedOnFlush() {
    let session = makeMockSession()
    let queue = EventQueue()
    let crashHandler = CrashHandler()
    let uploader = Uploader(
      queue: queue,
      token: "test-token",
      apiURL: dummyAPIURL,
      crashHandler: crashHandler,
      session: session
    )

    queue.enqueue([
      "event_type": "log",
      "message": "queued-custom-log",
      "environment": "custom_qa",
    ])
    XCTAssertEqual(queue.count(), 1)

    var outboundEnvironment: String?
    let exp = expectation(description: "outbound custom_qa preserved")

    MockURLProtocol.requestHandler = { request in
      if let data = self.extractBody(from: request),
         let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let events = json["events"] as? [[String: Any]],
         let first = events.first {
        outboundEnvironment = first["environment"] as? String
      }

      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      let body = try! JSONSerialization.data(withJSONObject: ["accepted": 1, "rejected": 0], options: [])
      exp.fulfill()
      return (response, body)
    }

    uploader.flushQueuedEvents()

    wait(for: [exp], timeout: 1.0)
    XCTAssertEqual(outboundEnvironment, "custom_qa", "Unknown environment value 'custom_qa' must remain unchanged and not be silently converted")

    let expDelete = expectation(description: "queued event removed after full acceptance")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      XCTAssertEqual(queue.count(), 0)
      expDelete.fulfill()
    }
    wait(for: [expDelete], timeout: 1.0)
  }

  func testRuntimeContextReturnsNilWhenUnconfigured() {
    Vestara.resetForTesting()
    XCTAssertNil(Vestara.getRuntimeContext())
  }

  func testRuntimeContextReturnsActiveIdentityWhenConfigured() {
    Vestara.resetForTesting()
    Vestara.configure(
      token: "test-token",
      apiURL: dummyAPIURL,
      environment: "production",
      autoRum: false
    )
    let ctx = Vestara.getRuntimeContext()
    XCTAssertNotNil(ctx)
    XCTAssertFalse(ctx!.sessionID.isEmpty)
    XCTAssertFalse(ctx!.deviceID.isEmpty)
  }

  func testClearUserRemovesUserFromCrashContext() {
    Vestara.resetForTesting()
    Vestara.configure(
      token: "test-token",
      apiURL: dummyAPIURL,
      environment: "production",
      autoRum: false
    )
    Vestara.setUser(id: "user-123", email: "user@test.com")
    _ = Vestara.getRuntimeContext()
    Vestara.clearUser()

    let exception = NSException(name: NSExceptionName("TestClearUserException"), reason: "Testing clear user", userInfo: nil)
    CrashHandler.handleException(exception)

    let pending = CrashHandler().loadPendingCrashes()
    XCTAssertEqual(pending.count, 1)
    let payload = pending[0].event["payload"] as? [String: Any]
    XCTAssertNil(payload?["user"], "Old user id/email must be absent from crash payload after clearUser")
  }

  func testStageReactNativeFatalSuccess() {
    Vestara.resetForTesting()
    Vestara.configure(
      token: "test-token",
      apiURL: dummyAPIURL,
      environment: "production",
      autoRum: false
    )

    let crashId = "rn-crash-uuid-123"
    let multilineStack = """
    TypeError: null is not an object (evaluating 'foo.bar')
        at evaluate (app.bundle:12:34)
        at render (app.bundle:56:78)
    """
    let breadcrumbsJson = "[{\"category\":\"navigation\",\"message\":\"opened_screen\"}]"

    let success = Vestara.stageReactNativeFatal(
      crashId: crashId,
      message: "TypeError: null is not an object (evaluating 'foo.bar')",
      errorType: "TypeError",
      stack: multilineStack,
      jsBreadcrumbsJson: breadcrumbsJson
    )

    XCTAssertTrue(success)

    let pending = CrashHandler().loadPendingCrashes()
    XCTAssertEqual(pending.count, 1)

    let event = pending[0].event
    XCTAssertEqual(event["event_type"] as? String, "crash")

    guard let payload = event["payload"] as? [String: Any] else {
      XCTFail("Missing payload in staged crash event")
      return
    }

    XCTAssertEqual(payload["origin"] as? String, "react_native_js")
    XCTAssertEqual(payload["crash_id"] as? String, crashId)
    XCTAssertEqual(payload["fatal"] as? Bool, true)
    XCTAssertEqual(payload["handled"] as? Bool, false)
    XCTAssertEqual(payload["exception_type"] as? String, "TypeError")
    XCTAssertEqual(payload["message"] as? String, "TypeError: null is not an object (evaluating 'foo.bar')")

    let stackTrace = payload["stack_trace"] as? [[String: Any]]
    XCTAssertNotNil(stackTrace)
    XCTAssertGreaterThanOrEqual(stackTrace?.count ?? 0, 1)

    let breadcrumbs = payload["breadcrumbs"] as? [[String: Any]]
    XCTAssertNotNil(breadcrumbs)
    XCTAssertEqual(breadcrumbs?.count, 1)
  }

  func testStageReactNativeFatalWhenUnconfigured() {
    Vestara.resetForTesting()
    let success = Vestara.stageReactNativeFatal(
      crashId: "rn-crash-unconfigured",
      message: "Unconfigured failure",
      errorType: nil,
      stack: nil,
      jsBreadcrumbsJson: nil
    )
    XCTAssertFalse(success)
  }

  func testStageReactNativeFatalBoundsAndMultilineEscaping() {
    Vestara.resetForTesting()
    Vestara.configure(
      token: "test-token",
      apiURL: dummyAPIURL,
      environment: "production",
      autoRum: false
    )

    let hugeMessage = String(repeating: "line with = sign\n", count: 800)
    let hugeStack = String(repeating: "at foo (file.js:1:2)\n", count: 2000)

    let success = Vestara.stageReactNativeFatal(
      crashId: "rn-crash-huge",
      message: hugeMessage,
      errorType: "LargeError",
      stack: hugeStack,
      jsBreadcrumbsJson: nil
    )

    XCTAssertTrue(success)

    let pending = CrashHandler().loadPendingCrashes()
    XCTAssertEqual(pending.count, 1)

    let payload = pending[0].event["payload"] as? [String: Any]
    XCTAssertEqual(payload?["origin"] as? String, "react_native_js")
    XCTAssertEqual(payload?["crash_id"] as? String, "rn-crash-huge")

    let message = payload?["message"] as? String
    XCTAssertTrue(message?.contains("[truncated]") == true)
    XCTAssertLessThanOrEqual(message?.count ?? 0, 8192 + 20)

    let stackTrace = payload?["stack_trace"] as? [[String: Any]]
    XCTAssertNotNil(stackTrace)
    XCTAssertLessThanOrEqual(stackTrace?.count ?? 0, 50)
  }

  func testStageReactNativeFatalReversibleMessageAndMultilineStack() {
    Vestara.resetForTesting()
    Vestara.configure(
      token: "test-token",
      apiURL: dummyAPIURL,
      environment: "production",
      autoRum: false
    )

    let testMessage = "Error line 1\nError line 2 with literal \\n characters inside"
    let testStack = "at onPress (index.js:10:5)\nat dispatch (redux.js:25:8)\nat handleClick (Button.js:30:12)"

    let success = Vestara.stageReactNativeFatal(
      crashId: "rn-crash-reversible",
      message: testMessage,
      errorType: "CustomError",
      stack: testStack,
      jsBreadcrumbsJson: nil
    )

    XCTAssertTrue(success)

    let pending = CrashHandler().loadPendingCrashes()
    XCTAssertEqual(pending.count, 1)

    guard let payload = pending[0].event["payload"] as? [String: Any] else {
      XCTFail("Missing payload")
      return
    }

    let recoveredMessage = payload["message"] as? String
    XCTAssertEqual(recoveredMessage, testMessage, "Message containing both actual newline and literal \\n must be preserved exactly without conflation")

    let stackTrace = payload["stack_trace"] as? [[String: Any]]
    XCTAssertNotNil(stackTrace)
    XCTAssertEqual(stackTrace?.count, 3, "Stack trace with 3 lines must reconstruct 3 distinct frames")
    XCTAssertEqual(stackTrace?[0]["function"] as? String, "onPress")
    XCTAssertEqual(stackTrace?[1]["function"] as? String, "dispatch")
    XCTAssertEqual(stackTrace?[2]["function"] as? String, "handleClick")
  }

  func testStageReactNativeFatalBreadcrumbsBoundedTo16KB() {
    Vestara.resetForTesting()
    Vestara.configure(
      token: "test-token",
      apiURL: dummyAPIURL,
      environment: "production",
      autoRum: false
    )

    let smallBreadcrumbs = "[{\"category\":\"ui\",\"message\":\"click\"}]"
    let successSmall = Vestara.stageReactNativeFatal(
      crashId: "rn-crash-crumbs-small",
      message: "Small crumbs error",
      errorType: "Error",
      stack: nil,
      jsBreadcrumbsJson: smallBreadcrumbs
    )
    XCTAssertTrue(successSmall)

    let singleCrumb = "{\"category\":\"ui\",\"message\":\"\(String(repeating: "c", count: 500))\"}"
    let hugeBreadcrumbs = "[" + (1...40).map { _ in singleCrumb }.joined(separator: ",") + "]"
    XCTAssertGreaterThan(hugeBreadcrumbs.utf8.count, 16 * 1024, "Test setup: huge breadcrumbs must exceed 16 KB")

    let successHuge = Vestara.stageReactNativeFatal(
      crashId: "rn-crash-crumbs-huge",
      message: "Huge crumbs error",
      errorType: "Error",
      stack: nil,
      jsBreadcrumbsJson: hugeBreadcrumbs
    )
    XCTAssertTrue(successHuge)

    let pending = CrashHandler().loadPendingCrashes()
    XCTAssertEqual(pending.count, 2)

    let smallEvent = pending.first { (($0.event["payload"] as? [String: Any])?["crash_id"] as? String) == "rn-crash-crumbs-small" }
    let smallPayload = smallEvent?.event["payload"] as? [String: Any]
    XCTAssertNotNil(smallPayload?["breadcrumbs"], "Breadcrumbs <= 16 KB must be persisted")

    let hugeEvent = pending.first { (($0.event["payload"] as? [String: Any])?["crash_id"] as? String) == "rn-crash-crumbs-huge" }
    let hugePayload = hugeEvent?.event["payload"] as? [String: Any]
    XCTAssertNil(hugePayload?["breadcrumbs"], "Breadcrumbs > 16 KB must be omitted")
  }

  // MARK: - RN-2D: Duplicate Suppression Tests

  func testStageReactNativeFatalArmsExceptionSuppressionTokenOnly() {
    Vestara.resetForTesting()
    Vestara.configure(
      token: "test-token",
      apiURL: dummyAPIURL,
      environment: "production",
      autoRum: false
    )

    XCTAssertFalse(CrashHandler.isFatalExceptionSuppressionArmedForTest())
    XCTAssertFalse(CrashHandler.isSignalSuppressionArmedForTest())

    let success = Vestara.stageReactNativeFatal(
      crashId: "rn-crash-suppression-seq",
      message: "Fatal JS crash",
      errorType: "TypeError",
      stack: nil,
      jsBreadcrumbsJson: nil
    )
    XCTAssertTrue(success)
    XCTAssertTrue(CrashHandler.isFatalExceptionSuppressionArmedForTest(), "Stage success must arm ONLY the fatal exception token")
    XCTAssertFalse(CrashHandler.isSignalSuppressionArmedForTest(), "SIGABRT token must remain disarmed until exception is handled")
  }

  func testExpectedRCTFatalExceptionSuppressesPersistenceAndArmsSignalToken() {
    Vestara.resetForTesting()
    Vestara.configure(
      token: "test-token",
      apiURL: dummyAPIURL,
      environment: "production",
      autoRum: false
    )

    let success = Vestara.stageReactNativeFatal(
      crashId: "rn-crash-suppressed-id",
      message: "Fatal JS crash",
      errorType: "TypeError",
      stack: nil,
      jsBreadcrumbsJson: nil
    )
    XCTAssertTrue(success)

    let rctException = NSException(
      name: NSExceptionName("RCTFatalException: Unhandled JS Exception: Fatal JS crash"),
      reason: "Fatal JS crash",
      userInfo: nil
    )

    XCTAssertTrue(CrashHandler.isFatalExceptionSuppressionArmedForTest(), "Exception token must be armed prior to handleException")
    XCTAssertFalse(CrashHandler.isSignalSuppressionArmedForTest(), "Signal token must not be armed yet")

    CrashHandler.handleException(rctException)

    XCTAssertFalse(CrashHandler.isFatalExceptionSuppressionArmedForTest(), "Exception token must be consumed")
    XCTAssertTrue(CrashHandler.isSignalSuppressionArmedForTest(), "SIGABRT token must now be armed for imminent abort()")

    let pending = CrashHandler().loadPendingCrashes()
    XCTAssertEqual(pending.count, 1, "Only the staged react_native_js crash file must exist")
    let payload = pending[0].event["payload"] as? [String: Any]
    XCTAssertEqual(payload?["origin"] as? String, "react_native_js")
    XCTAssertEqual(payload?["crash_id"] as? String, "rn-crash-suppressed-id")

    let sigabrtSuppressed = CrashHandler.consumeSignalSuppression(SIGABRT)
    XCTAssertTrue(sigabrtSuppressed, "Expected SIGABRT following suppressed RCTFatalException must be suppressed")
    XCTAssertFalse(CrashHandler.isSignalSuppressionArmedForTest(), "SIGABRT token must be consumed once")
  }

  func testStageFailureDoesNotArmSuppressionToken() {
    Vestara.resetForTesting()
    let success = Vestara.stageReactNativeFatal(
      crashId: "rn-crash-unconfigured",
      message: "Error",
      errorType: "Error",
      stack: nil,
      jsBreadcrumbsJson: nil
    )
    XCTAssertFalse(success)
    XCTAssertFalse(CrashHandler.isFatalExceptionSuppressionArmedForTest())
    XCTAssertFalse(CrashHandler.isSignalSuppressionArmedForTest())

    let rctException = NSException(
      name: NSExceptionName("RCTFatalException: Error"),
      reason: "Error",
      userInfo: nil
    )
    XCTAssertFalse(CrashHandler.handleExceptionSuppression(rctException), "Exception must not be suppressed when staging failed")
    XCTAssertFalse(CrashHandler.consumeSignalSuppression(SIGABRT), "SIGABRT must not be suppressed when staging failed")
  }

  func testArmedExceptionTokenDoesNotSuppressUnrelatedNSException() {
    Vestara.resetForTesting()
    Vestara.configure(
      token: "test-token",
      apiURL: dummyAPIURL,
      environment: "production",
      autoRum: false
    )

    let success = Vestara.stageReactNativeFatal(
      crashId: "rn-crash-unrelated-test",
      message: "Fatal JS crash",
      errorType: "TypeError",
      stack: nil,
      jsBreadcrumbsJson: nil
    )
    XCTAssertTrue(success)

    let unrelatedException = NSException(
      name: NSExceptionName("NSInvalidArgumentException"),
      reason: "unrecognized selector sent to instance",
      userInfo: nil
    )

    let suppressed = CrashHandler.handleExceptionSuppression(unrelatedException)
    XCTAssertFalse(suppressed, "Unrelated NSException must not be suppressed")
    XCTAssertTrue(CrashHandler.isFatalExceptionSuppressionArmedForTest(), "Token must remain armed when unrelated exception occurs")
    XCTAssertFalse(CrashHandler.isSignalSuppressionArmedForTest(), "Signal token must NOT be armed by unrelated exception")

    CrashHandler.handleException(unrelatedException)

    let pending = CrashHandler().loadPendingCrashes()
    XCTAssertEqual(pending.count, 2, "Both staged RN crash and unrelated native exception must exist")
    let exceptionCrash = pending.first { ($0.event["payload"] as? [String: Any])?["exception_type"] as? String == "NSInvalidArgumentException" }
    XCTAssertNotNil(exceptionCrash)
  }

  func testSignalSuppressionDoesNotSuppressNonSigabrtSignals() {
    Vestara.resetForTesting()
    Vestara.configure(
      token: "test-token",
      apiURL: dummyAPIURL,
      environment: "production",
      autoRum: false
    )

    let success = Vestara.stageReactNativeFatal(
      crashId: "rn-crash-signal-test",
      message: "Fatal JS crash",
      errorType: "TypeError",
      stack: nil,
      jsBreadcrumbsJson: nil
    )
    XCTAssertTrue(success)

    let rctException = NSException(
      name: NSExceptionName("RCTFatalException: test"),
      reason: "test",
      userInfo: nil
    )
    XCTAssertTrue(CrashHandler.handleExceptionSuppression(rctException))
    XCTAssertTrue(CrashHandler.isSignalSuppressionArmedForTest())

    XCTAssertFalse(CrashHandler.consumeSignalSuppression(SIGSEGV), "SIGSEGV must never be suppressed")
    XCTAssertFalse(CrashHandler.consumeSignalSuppression(SIGBUS), "SIGBUS must never be suppressed")
    XCTAssertFalse(CrashHandler.consumeSignalSuppression(SIGILL), "SIGILL must never be suppressed")
    XCTAssertFalse(CrashHandler.consumeSignalSuppression(SIGFPE), "SIGFPE must never be suppressed")
    XCTAssertFalse(CrashHandler.consumeSignalSuppression(SIGTRAP), "SIGTRAP must never be suppressed")
    XCTAssertTrue(CrashHandler.isSignalSuppressionArmedForTest(), "Signal token must remain intact for expected SIGABRT")
  }

  func testOneShotTokensAreConsumedAndDoNotSuppressSecondEvent() {
    Vestara.resetForTesting()
    Vestara.configure(
      token: "test-token",
      apiURL: dummyAPIURL,
      environment: "production",
      autoRum: false
    )

    let success = Vestara.stageReactNativeFatal(
      crashId: "rn-crash-oneshot-test",
      message: "Fatal JS crash",
      errorType: "TypeError",
      stack: nil,
      jsBreadcrumbsJson: nil
    )
    XCTAssertTrue(success)

    let rctException = NSException(
      name: NSExceptionName("RCTFatalException: first"),
      reason: "first",
      userInfo: nil
    )
    XCTAssertTrue(CrashHandler.handleExceptionSuppression(rctException))

    let secondException = NSException(
      name: NSExceptionName("RCTFatalException: second"),
      reason: "second",
      userInfo: nil
    )
    XCTAssertFalse(CrashHandler.handleExceptionSuppression(secondException), "Second RCTFatalException must not be suppressed without new stage")

    XCTAssertTrue(CrashHandler.consumeSignalSuppression(SIGABRT))
    XCTAssertFalse(CrashHandler.consumeSignalSuppression(SIGABRT), "Second SIGABRT must not be suppressed without new stage")
  }
}
