import XCTest
@testable import VestaraSDK

final class RumMetricTests: XCTestCase {
  func testAppStartPayloadShape() {
    let payload = RumMetricPayloadBuilder.buildPayload(
      metricType: .appStart, value: 1250.5, unit: .ms,
      name: nil, screen: nil, route: nil, operation: nil, tags: nil
    )
    XCTAssertNotNil(payload)
    XCTAssertEqual(payload?["metric_type"] as? String, "app_start")
    XCTAssertEqual(payload?["value"] as? Double, 1250.5)
    XCTAssertEqual(payload?["unit"] as? String, "ms")
  }

  func testScreenLoadPayloadShape() {
    let payload = RumMetricPayloadBuilder.buildPayload(
      metricType: .screenLoad, value: 450, unit: .ms,
      name: nil, screen: "HomeScreen", route: nil, operation: nil, tags: nil
    )
    XCTAssertNotNil(payload)
    XCTAssertEqual(payload?["metric_type"] as? String, "screen_load")
    XCTAssertEqual(payload?["value"] as? Double, 450)
    XCTAssertEqual(payload?["unit"] as? String, "ms")
    XCTAssertEqual(payload?["screen"] as? String, "HomeScreen")
  }

  func testSlowFramePayloadShape() {
    let payload = RumMetricPayloadBuilder.buildPayload(
      metricType: .slowFrame, value: 120, unit: .ms,
      name: nil, screen: nil, route: nil, operation: nil, tags: nil
    )
    XCTAssertNotNil(payload)
    XCTAssertEqual(payload?["metric_type"] as? String, "slow_frame")
    XCTAssertEqual(payload?["value"] as? Double, 120)
    XCTAssertEqual(payload?["unit"] as? String, "ms")
  }

  func testNetworkRequestStripsQueryFromRoute() {
    let payload = RumMetricPayloadBuilder.buildPayload(
      metricType: .networkRequest, value: 340, unit: .ms,
      name: "GET /api/users",
      screen: nil,
      route: "/api/users?token=secret&page=1#section",
      operation: "GET",
      tags: nil
    )
    XCTAssertNotNil(payload)
    XCTAssertEqual(payload?["route"] as? String, "/api/users")
    XCTAssertEqual(payload?["operation"] as? String, "GET")
  }

  func testMemoryPayloadShape() {
    let payload = RumMetricPayloadBuilder.buildPayload(
      metricType: .memory, value: 64_000_000, unit: .bytes,
      name: "heap", screen: nil, route: nil, operation: nil, tags: nil
    )
    XCTAssertNotNil(payload)
    XCTAssertEqual(payload?["metric_type"] as? String, "memory")
    XCTAssertEqual(payload?["value"] as? Double, 64_000_000)
    XCTAssertEqual(payload?["unit"] as? String, "bytes")
    XCTAssertEqual(payload?["name"] as? String, "heap")
  }

  func testCustomPayloadShape() {
    let payload = RumMetricPayloadBuilder.buildPayload(
      metricType: .custom, value: 42, unit: nil,
      name: "my_custom_metric", screen: nil, route: nil, operation: nil,
      tags: ["env": "staging", "version": 2, "active": true]
    )
    XCTAssertNotNil(payload)
    XCTAssertEqual(payload?["metric_type"] as? String, "custom")
    XCTAssertEqual(payload?["value"] as? Double, 42)
    XCTAssertEqual(payload?["name"] as? String, "my_custom_metric")
    let tags = payload?["tags"] as? [String: Any]
    XCTAssertNotNil(tags)
    XCTAssertEqual(tags?["env"] as? String, "staging")
    XCTAssertEqual(tags?["version"] as? Double, 2)
    XCTAssertEqual(tags?["active"] as? Bool, true)
  }

  func testInvalidNonFiniteValueNotQueued() {
    let infPayload = RumMetricPayloadBuilder.buildPayload(
      metricType: .custom, value: Double.infinity, unit: nil,
      name: nil, screen: nil, route: nil, operation: nil, tags: nil
    )
    XCTAssertNil(infPayload)

    let nanPayload = RumMetricPayloadBuilder.buildPayload(
      metricType: .custom, value: Double.nan, unit: nil,
      name: nil, screen: nil, route: nil, operation: nil, tags: nil
    )
    XCTAssertNil(nanPayload)
  }

  func testScreenViewPayloadShape() {
    let payload = RumMetricPayloadBuilder.buildPayload(
      metricType: .screenView, value: 1, unit: .count,
      name: nil, screen: "HomeScreen", route: nil, operation: nil, tags: nil
    )
    XCTAssertNotNil(payload)
    XCTAssertEqual(payload?["metric_type"] as? String, "screen_view")
    XCTAssertEqual(payload?["value"] as? Double, 1)
    XCTAssertEqual(payload?["screen"] as? String, "HomeScreen")
  }

  func testScreenDurationPayloadShape() {
    let payload = RumMetricPayloadBuilder.buildPayload(
      metricType: .screenDuration, value: 3200, unit: .ms,
      name: nil, screen: "HomeScreen", route: nil, operation: nil, tags: nil
    )
    XCTAssertNotNil(payload)
    XCTAssertEqual(payload?["metric_type"] as? String, "screen_duration")
    XCTAssertEqual(payload?["value"] as? Double, 3200)
    XCTAssertEqual(payload?["screen"] as? String, "HomeScreen")
  }

  func testAppForegroundPayloadShape() {
    let payload = RumMetricPayloadBuilder.buildPayload(
      metricType: .appForeground, value: 1, unit: .count,
      name: nil, screen: nil, route: nil, operation: nil, tags: nil
    )
    XCTAssertNotNil(payload)
    XCTAssertEqual(payload?["metric_type"] as? String, "app_foreground")
    XCTAssertEqual(payload?["value"] as? Double, 1)
  }

  func testAppBackgroundPayloadShape() {
    let payload = RumMetricPayloadBuilder.buildPayload(
      metricType: .appBackground, value: 1, unit: .count,
      name: nil, screen: nil, route: nil, operation: nil, tags: nil
    )
    XCTAssertNotNil(payload)
    XCTAssertEqual(payload?["metric_type"] as? String, "app_background")
    XCTAssertEqual(payload?["value"] as? Double, 1)
  }

  func testAnrOrFreezePayloadShape() {
    let payload = RumMetricPayloadBuilder.buildPayload(
      metricType: .anrOrFreeze, value: 5200, unit: .ms,
      name: nil, screen: nil, route: nil, operation: nil, tags: nil
    )
    XCTAssertNotNil(payload)
    XCTAssertEqual(payload?["metric_type"] as? String, "anr_or_freeze")
    XCTAssertEqual(payload?["value"] as? Double, 5200)
    XCTAssertEqual(payload?["unit"] as? String, "ms")
  }

  func testCrashFreeSessionPayloadShape() {
    let payload = RumMetricPayloadBuilder.buildPayload(
      metricType: .crashFreeSession, value: 0, unit: .count,
      name: nil, screen: nil, route: nil, operation: nil, tags: nil
    )
    XCTAssertNotNil(payload)
    XCTAssertEqual(payload?["metric_type"] as? String, "crash_free_session")
    XCTAssertEqual(payload?["value"] as? Double, 0)
  }

  func testTagsAllowStringNumberBool() {
    let tags: [String: Any] = [
      "name": "Alice",
      "score": 95,
      "premium": true,
    ]
    let payload = RumMetricPayloadBuilder.buildPayload(
      metricType: .custom, value: 1, unit: nil,
      name: nil, screen: nil, route: nil, operation: nil, tags: tags
    )
    XCTAssertNotNil(payload)
    let result = payload?["tags"] as? [String: Any]
    XCTAssertEqual(result?["name"] as? String, "Alice")
    XCTAssertEqual(result?["score"] as? Double, 95)
    XCTAssertEqual(result?["premium"] as? Bool, true)
  }

  func testTagsBoundedTo20Entries() {
    var tags: [String: Any] = [:]
    for i in 0..<25 {
      tags["key\(i)"] = i
    }
    let payload = RumMetricPayloadBuilder.buildPayload(
      metricType: .custom, value: 1, unit: nil,
      name: nil, screen: nil, route: nil, operation: nil, tags: tags
    )
    XCTAssertNotNil(payload)
    let result = payload?["tags"] as? [String: Any]
    XCTAssertEqual(result?.count, 20)
  }

  func testLongOptionalStringsTruncated() {
    let longName = String(repeating: "a", count: 200)
    let longScreen = String(repeating: "b", count: 400)
    let longRoute = String(repeating: "c", count: 400)
    let longOperation = String(repeating: "d", count: 200)

    let payload = RumMetricPayloadBuilder.buildPayload(
      metricType: .screenLoad, value: 100, unit: .ms,
      name: longName, screen: longScreen, route: longRoute, operation: longOperation, tags: nil
    )
    XCTAssertNotNil(payload)
    XCTAssertEqual((payload?["name"] as? String)?.count, 128)
    XCTAssertEqual((payload?["screen"] as? String)?.count, 256)
    XCTAssertEqual((payload?["route"] as? String)?.count, 256)
    XCTAssertEqual((payload?["operation"] as? String)?.count, 128)
  }

  func testTagKeyAndValueBounded() {
    let longKey = String(repeating: "k", count: 100)
    let longValue = String(repeating: "v", count: 2000)
    let tags = [longKey: longValue]

    let payload = RumMetricPayloadBuilder.buildPayload(
      metricType: .custom, value: 1, unit: nil,
      name: nil, screen: nil, route: nil, operation: nil, tags: tags
    )
    XCTAssertNotNil(payload)
    let result = payload?["tags"] as? [String: Any]
    XCTAssertEqual(result?.first?.key.count, 64)
    XCTAssertEqual((result?.first?.value as? String)?.count, 1024)
  }

  func testTrackRumMetricEnqueuesRumMetricEventType() {
    var capturedEventType: String?
    let expectation = XCTestExpectation(description: "rum_metric enqueued")

    Vestara.configure(token: "test-rum-enqueue-type", beforeSend: { event in
      capturedEventType = event["event_type"] as? String
      return event
    })

    Vestara.trackRumMetric(.custom, value: 1.0)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      XCTAssertEqual(capturedEventType, "rum_metric")
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 1.0)
  }

  func testSanitizedRouteWithoutQueryOrFragment() {
    let sanitized = RumMetricPayloadBuilder.sanitizedRoute("/api/users")
    XCTAssertEqual(sanitized, "/api/users")
  }

  func testSanitizedRouteStripsQueryString() {
    let sanitized = RumMetricPayloadBuilder.sanitizedRoute("/api/users?token=abc&page=1")
    XCTAssertEqual(sanitized, "/api/users")
  }

  func testSanitizedRouteStripsFragment() {
    let sanitized = RumMetricPayloadBuilder.sanitizedRoute("/api/users#section")
    XCTAssertEqual(sanitized, "/api/users")
  }

  func testSanitizedRouteStripsQueryAndFragment() {
    let sanitized = RumMetricPayloadBuilder.sanitizedRoute("/api/users?token=abc#section")
    XCTAssertEqual(sanitized, "/api/users")
  }

  func testSanitizedRouteStripsFragmentBeforeQuery() {
    let sanitized = RumMetricPayloadBuilder.sanitizedRoute("/api/users#section?not-a-query")
    XCTAssertEqual(sanitized, "/api/users")
  }
}
