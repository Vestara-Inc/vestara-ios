import Foundation

public enum RumMetricType: String, CaseIterable {
  case appStart = "app_start"
  case screenLoad = "screen_load"
  case slowFrame = "slow_frame"
  case networkRequest = "network_request"
  case memory
  case custom
  case screenView = "screen_view"
  case screenDuration = "screen_duration"
  case appForeground = "app_foreground"
  case appBackground = "app_background"
  case anrOrFreeze = "anr_or_freeze"
  case crashFreeSession = "crash_free_session"
}

public enum RumMetricUnit: String, CaseIterable {
  case ms
  case count
  case bytes
  case percent
}

enum RumMetricPayloadBuilder {
  static func buildPayload(
    metricType: RumMetricType,
    value: Double,
    unit: RumMetricUnit?,
    name: String?,
    screen: String?,
    route: String?,
    operation: String?,
    tags: [String: Any]?
  ) -> [String: Any]? {
    guard value.isFinite else { return nil }

    var payload: [String: Any] = [
      "metric_type": metricType.rawValue,
      "value": value,
    ]

    if let unit = unit {
      payload["unit"] = unit.rawValue
    }

    if let name = name, !name.isEmpty {
      payload["name"] = String(name.prefix(128))
    }

    if let screen = screen, !screen.isEmpty {
      payload["screen"] = String(screen.prefix(256))
    }

    if let route = route, !route.isEmpty {
      let sanitized = Self.sanitizedRoute(route)
      payload["route"] = String(sanitized.prefix(256))
    }

    if let operation = operation, !operation.isEmpty {
      payload["operation"] = String(operation.prefix(128))
    }

    if let tags = tags {
      let cleaned = Self.sanitizedTags(tags)
      if !cleaned.isEmpty {
        payload["tags"] = cleaned
      }
    }

    return payload
  }

  static func sanitizedRoute(_ route: String) -> String {
    let queryIndex = route.firstIndex(of: "?")
    let fragmentIndex = route.firstIndex(of: "#")
    let cutIndex: String.Index
    switch (queryIndex, fragmentIndex) {
    case let (q?, f?):
      cutIndex = min(q, f)
    case let (q?, nil):
      cutIndex = q
    case let (nil, f?):
      cutIndex = f
    case (nil, nil):
      return route
    }
    return String(route[..<cutIndex])
  }

  static func sanitizedTags(_ tags: [String: Any]) -> [String: Any] {
    var result: [String: Any] = [:]
    var count = 0

    for (key, value) in tags {
      guard count < 20 else { break }
      let cleanKey = String(key.prefix(64))

      switch value {
      case let str as String:
        result[cleanKey] = String(str.prefix(1024))
        count += 1
      case let num as NSNumber:
        if CFGetTypeID(num as CFTypeRef) == CFBooleanGetTypeID() {
          result[cleanKey] = num.boolValue
          count += 1
        } else if num.doubleValue.isFinite {
          result[cleanKey] = num.doubleValue
          count += 1
        }
      default:
        break
      }
    }

    return result
  }
}
