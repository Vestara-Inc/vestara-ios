import Foundation
#if canImport(UIKit)
import UIKit
#endif

public enum LogLevel: String {
  case debug
  case info
  case warning
  case error
  case fatal
}

public enum Vestara {
  private static let sdkVersion = "0.1.2"
  private static let defaultAPIURL = URL(string: "https://api.vestara.dev")!
  private static let accessQueue = DispatchQueue(label: "com.vestara.state")
  private static var queue: EventQueue?
  private static var uploader: Uploader?
  private static var deviceInfo: DeviceInfo?
  private static var crashHandler: CrashHandler?
  private static var breadcrumbBuffer: BreadcrumbBuffer?
  private static var mainThreadWatchdog: MainThreadWatchdog?
  private static var sessionID = UUID().uuidString
  private static var environment = "production"
  private static var targetCategory = "ios_app"
  private static var serviceName: String?
  private static var appIdentifier: String?
  private static var loggingEnabled = true
  private static var autoRumEnabled = true
  private static var user: [String: String] = [:]
  private static var configureSystemUptime: Double = 0
  private static var settingsTimer: DispatchSourceTimer?
  private static var observersBound = false
  private static var configured = false
  private static var beforeSend: (([String: Any]) throws -> [String: Any]?)? = nil

  public static func configure(
    token: String,
    apiURL: URL? = nil,
    environment: String = "production",
    targetCategory: String? = nil,
    serviceName: String? = nil,
    appIdentifier: String? = nil,
    autoRum: Bool = true,
    beforeSend: (([String: Any]) throws -> [String: Any]?)? = nil
  ) {
    accessQueue.sync {
      guard !token.isEmpty else {
        return
      }

      let nextQueue = EventQueue()
      let nextDeviceInfo = DeviceInfo()
      let nextCrashHandler = CrashHandler()
      let nextBreadcrumbBuffer = BreadcrumbBuffer()
      let nextUploader = Uploader(
        queue: nextQueue,
        token: token,
        apiURL: apiURL ?? defaultAPIURL,
        crashHandler: nextCrashHandler,
        beforeSend: beforeSend
      )
      let nextWatchdog = MainThreadWatchdog()

      Self.queue = nextQueue
      Self.deviceInfo = nextDeviceInfo
      Self.crashHandler = nextCrashHandler
      Self.breadcrumbBuffer = nextBreadcrumbBuffer
      Self.uploader = nextUploader
      Self.mainThreadWatchdog = nextWatchdog
      Self.sessionID = UUID().uuidString
      Self.environment = environment
      Self.targetCategory = targetCategory ?? "ios_app"
      Self.serviceName = serviceName
      Self.appIdentifier = appIdentifier ?? Bundle.main.bundleIdentifier
      Self.loggingEnabled = true
      Self.autoRumEnabled = autoRum
      Self.configured = true
      Self.beforeSend = beforeSend
      Self.configureSystemUptime = ProcessInfo.processInfo.systemUptime

      nextWatchdog.configure { detectedAfter, message in
        Self.handleANR(detectedAfter: detectedAfter, message: message)
      }

      nextDeviceInfo.networkChangeCallback = { networkType in
        Self.breadcrumbBuffer?.add(category: "network", message: "Network: \(networkType)", level: "info")
        Self.crashHandler?.updateBreadcrumbSnapshot(Self.breadcrumbBuffer?.snapshot ?? "")
      }

      let context = CrashHandler.Context(
        sessionID: sessionID,
        deviceID: nextDeviceInfo.deviceID,
        environment: environment,
        appVersion: nextDeviceInfo.appVersion,
        osVersion: nextDeviceInfo.osVersion,
        deviceModel: nextDeviceInfo.deviceModel,
        sdkVersion: sdkVersion,
        targetCategory: targetCategory ?? "ios_app",
        appIdentifier: appIdentifier ?? Bundle.main.bundleIdentifier,
        serviceName: serviceName
      )

      nextCrashHandler.install(context: context)
      nextUploader.uploadPendingCrashes()
      nextUploader.start()
      nextWatchdog.start()
      bindLifecycleObservers()
      startSettingsPolling()
      pollDeviceSettings()
    }

    if autoRum {
      Self.reportAppStart()
    }
  }

  public static func log(
    _ level: LogLevel,
    _ message: String,
    data: [String: Any]? = nil
  ) {
    accessQueue.async {
      guard configured, loggingEnabled, let queue, let event = makeLogEvent(level: level, message: message, data: data) else {
        return
      }

      breadcrumbBuffer?.add(category: "log", message: message, level: level.rawValue, data: data)
      crashHandler?.updateBreadcrumbSnapshot(breadcrumbBuffer?.snapshot ?? "")

      var finalEvent: [String: Any]? = event
      if let hook = beforeSend {
        do {
          finalEvent = try hook(event)
        } catch {
          finalEvent = event
        }
      }

      if let e = finalEvent {
        queue.enqueue(e)
      }

      if queue.count() >= 100 {
        uploader?.flushQueuedEvents()
      }
    }
  }

  public static func setUser(
    id: String,
    email: String? = nil
  ) {
    accessQueue.async {
      guard configured, !id.isEmpty else {
        return
      }

      user = [
        "id": id,
        "email": email ?? "",
      ]
      crashHandler?.updateUser(id: id, email: email)
    }
  }

  public static func startSession() {
    accessQueue.async {
      guard configured else {
        return
      }

      sessionID = UUID().uuidString
      breadcrumbBuffer?.clear()
    }
  }

  public static func trackRumMetric(
    _ metricType: RumMetricType,
    value: Double,
    unit: RumMetricUnit? = nil,
    name: String? = nil,
    screen: String? = nil,
    route: String? = nil,
    operation: String? = nil,
    tags: [String: Any]? = nil
  ) {
    accessQueue.async {
      guard configured, let queue else {
        return
      }

      guard let payload = RumMetricPayloadBuilder.buildPayload(
        metricType: metricType,
        value: value,
        unit: unit,
        name: name,
        screen: screen,
        route: route,
        operation: operation,
        tags: tags
      ) else {
        return
      }

      guard let event = makeEvent(eventType: "rum_metric", payload: payload) else {
        return
      }

      var finalEvent: [String: Any]? = event
      if let hook = beforeSend {
        do {
          finalEvent = try hook(event)
        } catch {
          finalEvent = event
        }
      }

      if let e = finalEvent {
        queue.enqueue(e)
      }

      if queue.count() >= 100 {
        uploader?.flushQueuedEvents()
      }
    }
  }

  public static func reportAppStart() {
    let elapsed = ProcessInfo.processInfo.systemUptime - configureSystemUptime
    let valueMs = elapsed * 1000
    trackRumMetric(.appStart, value: valueMs, unit: .ms)
  }

  private static func makeLogEvent(
    level: LogLevel,
    message: String,
    data: [String: Any]?
  ) -> [String: Any]? {
    guard let deviceInfo else {
      return nil
    }

    var payload: [String: Any] = [
      "level": level.rawValue,
      "message": message,
      "network_type": deviceInfo.currentNetworkType(),
    ]

    if let normalizedData = normalizeDictionary(data), !normalizedData.isEmpty {
      payload["data"] = normalizedData
    }

    if let userPayload = userPayload() {
      payload["user"] = userPayload
    }

    return makeEvent(eventType: "log", payload: payload)
  }

  static func makeEvent(eventType: String, payload: [String: Any]) -> [String: Any]? {
    guard let deviceInfo else {
      return nil
    }

    var baseEvent: [String: Any] = [
      "event_type": eventType,
      "session_id": sessionID,
      "device_id": deviceInfo.deviceID,
      "timestamp": ISO8601DateFormatter().string(from: Date()),
      "sdk_version": sdkVersion,
      "app_version": deviceInfo.appVersion,
      "os_name": "ios",
      "os_version": deviceInfo.osVersion,
      "device_model": deviceInfo.deviceModel,
      "environment": environment,
      "target_category": targetCategory,
      "payload": payload,
    ]
    
    if let sn = serviceName { baseEvent["service_name"] = sn }
    if let ai = appIdentifier { baseEvent["app_identifier"] = ai }
    
    return baseEvent
  }

  private static func handleANR(detectedAfter: TimeInterval, message: String) {
    accessQueue.async {
      guard configured, let queue else { return }

      breadcrumbBuffer?.add(
        category: "anr",
        message: message,
        level: "error"
      )
      crashHandler?.updateBreadcrumbSnapshot(breadcrumbBuffer?.snapshot ?? "")

      guard let event = makeLogEvent(
        level: .fatal,
        message: message,
        data: [
          "detected_after_ms": detectedAfter * 1000,
          "session_id": sessionID,
        ]
      ) else { return }

      queue.enqueue(event)

      if queue.count() >= 100 {
        uploader?.flushQueuedEvents()
      }
    }
  }

  private static func normalizeDictionary(_ dictionary: [String: Any]?) -> [String: Any]? {
    guard let dictionary else {
      return nil
    }

    var normalized: [String: Any] = [:]

    for (key, value) in dictionary {
      if let safeValue = normalizeValue(value) {
        normalized[key] = safeValue
      }
    }

    return normalized
  }

  private static func normalizeValue(_ value: Any) -> Any? {
    switch value {
    case let string as String:
      return string
    case let number as NSNumber:
      return number
    case let dictionary as [String: Any]:
      return normalizeDictionary(dictionary)
    case let array as [Any]:
      return array.compactMap { normalizeValue($0) }
    case let date as Date:
      return ISO8601DateFormatter().string(from: date)
    default:
      return String(describing: value)
    }
  }

  private static func userPayload() -> [String: Any]? {
    guard let id = user["id"], !id.isEmpty else {
      return nil
    }

    var payload: [String: Any] = ["id": id]
    let email = user["email"] ?? ""

    if !email.isEmpty {
      payload["email"] = email
    }

    return payload
  }

  private static func startSettingsPolling() {
    settingsTimer?.cancel()
    let nextTimer = DispatchSource.makeTimerSource(queue: accessQueue)
    nextTimer.schedule(deadline: .now() + 60, repeating: 60)
    nextTimer.setEventHandler {
      pollDeviceSettings()
    }
    settingsTimer = nextTimer
    nextTimer.resume()
  }

  private static func stopSettingsPolling() {
    settingsTimer?.cancel()
    settingsTimer = nil
  }

  private static func pollDeviceSettings() {
    guard let uploader, let deviceInfo else {
      return
    }

    uploader.fetchLoggingEnabled(deviceID: deviceInfo.deviceID) { enabled in
      guard let enabled else {
        return
      }

      accessQueue.async {
        loggingEnabled = enabled
      }
    }
  }

  private static func bindLifecycleObservers() {
    guard !observersBound else {
      return
    }

    observersBound = true
#if canImport(UIKit)
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: nil
    ) { _ in
      accessQueue.async {
        breadcrumbBuffer?.add(category: "app.lifecycle", message: "App foregrounded", level: "info")
        crashHandler?.updateBreadcrumbSnapshot(breadcrumbBuffer?.snapshot ?? "")
        startSettingsPolling()
        pollDeviceSettings()
        uploader?.flushQueuedEvents()
        mainThreadWatchdog?.start()

        if autoRumEnabled {
          trackRumMetric(.appForeground, value: 0.0)
        }
      }
    }

    NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification,
      object: nil,
      queue: nil
    ) { _ in
      accessQueue.async {
        breadcrumbBuffer?.add(category: "app.lifecycle", message: "App backgrounded", level: "info")
        crashHandler?.updateBreadcrumbSnapshot(breadcrumbBuffer?.snapshot ?? "")
        stopSettingsPolling()
        mainThreadWatchdog?.stop()

        if autoRumEnabled {
          trackRumMetric(.appBackground, value: 0.0)
        }
      }
    }
#endif
  }
}
