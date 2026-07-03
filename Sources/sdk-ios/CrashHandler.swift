import Foundation
import Darwin

final class CrashHandler {
  struct Context {
    let sessionID: String
    let deviceID: String
    let environment: String
    let appVersion: String
    let osVersion: String
    let deviceModel: String
    let sdkVersion: String
    let targetCategory: String
    let appIdentifier: String?
    let serviceName: String?
  }

  struct PendingCrash {
    let fileURL: URL
    let event: [String: Any]
  }

  private static let directoryName = "VestaraCrashes"
  private static let signalFileName = "pending-signal.crash"
  private static var context = Context(
    sessionID: "",
    deviceID: "",
    environment: "production",
    appVersion: "unknown",
    osVersion: "unknown",
    deviceModel: "iPhone",
    sdkVersion: "0.0.0",
    targetCategory: "ios_app",
    appIdentifier: nil,
    serviceName: nil
  )
  private static var user: [String: String] = [:]
  private static var breadcrumbSnapshot: String = ""
  private static var signalPath = [CChar](repeating: 0, count: 1024)
  private static var signalBase = [UInt8](repeating: 0, count: 2048)
  private static var signalBaseLength = 0
  private static let signalMessage = Array("message=Signal crash\n".utf8)
  private static let signalPrefix = Array("signal=".utf8)
  private static let newline = [UInt8(10)]

  func install(context: Context) {
    CrashHandler.context = context
    CrashHandler.prepareSignalContext()
    CrashHandler.installExceptionHandler()
    CrashHandler.installSignalHandlers()
  }

  func updateUser(id: String, email: String?) {
    CrashHandler.user = [
      "id": id,
      "email": email ?? "",
    ]
  }

  func updateBreadcrumbSnapshot(_ snapshot: String) {
    CrashHandler.breadcrumbSnapshot = snapshot
  }

  func loadPendingCrashes() -> [PendingCrash] {
    let directory = CrashHandler.crashDirectoryURL()
    guard let fileURLs = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }

    return fileURLs.compactMap { fileURL in
      guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
        return nil
      }

      let lines = contents.split(separator: "\n")
      var values: [String: String] = [:]

      for line in lines {
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        values[String(parts[0])] = String(parts[1]).replacingOccurrences(of: "\\n", with: "\n")
      }

      guard let event = CrashHandler.crashEvent(from: values, fileURL: fileURL) else {
        return nil
      }

      return PendingCrash(fileURL: fileURL, event: event)
    }
  }

  func deleteCrashFiles(at urls: [URL]) {
    urls.forEach { url in
      try? FileManager.default.removeItem(at: url)
    }
  }

  private static func crashEvent(from values: [String: String], fileURL: URL) -> [String: Any]? {
    let fileTimestamp = ((try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate) ?? Date()
    let timestamp = ISO8601DateFormatter().string(from: fileTimestamp)
    var payload: [String: Any] = [
      "message": values["message"] ?? "App crash recovered on next launch",
      "crash_type": values["type"] ?? "signal",
      "stack": values["stack"] ?? "",
      "recovered": true,
    ]

    if let signal = values["signal"], !signal.isEmpty {
      payload["signal"] = signal
    }

    if let exception = values["name"], !exception.isEmpty {
      payload["exception_type"] = exception
    }

    if let userID = values["user_id"], !userID.isEmpty {
      var recoveredUser: [String: Any] = ["id": userID]
      let email = values["user_email"] ?? ""

      if !email.isEmpty {
        recoveredUser["email"] = email
      }

      payload["user"] = recoveredUser
    }

    if let breadcrumbsJSON = values["breadcrumbs"], !breadcrumbsJSON.isEmpty {
      if let data = breadcrumbsJSON.data(using: .utf8),
         let breadcrumbs = try? JSONDecoder().decode([Breadcrumb].self, from: data) {
        payload["breadcrumbs"] = breadcrumbs.map { [
          "timestamp": $0.timestamp,
          "category": $0.category,
          "message": $0.message,
          "level": $0.level,
          "data": $0.data,
        ]}
      }
    }

    guard
      let sessionID = values["session_id"],
      let deviceID = values["device_id"],
      let environment = values["environment"],
      let sdkVersion = values["sdk_version"],
      let appVersion = values["app_version"],
      let osVersion = values["os_version"],
      let deviceModel = values["device_model"]
    else {
      return nil
    }

    if let targetCategory = values["target_category"], !targetCategory.isEmpty {
      payload["target_category"] = targetCategory
    }
    if let appIdentifier = values["app_identifier"], !appIdentifier.isEmpty {
      payload["app_identifier"] = appIdentifier
    }
    if let serviceName = values["service_name"], !serviceName.isEmpty {
      payload["service_name"] = serviceName
    }

    var baseEvent: [String: Any] = [
      "event_type": "crash",
      "session_id": sessionID,
      "device_id": deviceID,
      "timestamp": timestamp,
      "sdk_version": sdkVersion,
      "app_version": appVersion,
      "os_name": "ios",
      "os_version": osVersion,
      "device_model": deviceModel,
      "environment": environment,
      "payload": payload,
    ]

    if let targetCategory = values["target_category"], !targetCategory.isEmpty {
      baseEvent["target_category"] = targetCategory
    } else {
      baseEvent["target_category"] = "ios_app"
    }

    if let appIdentifier = values["app_identifier"], !appIdentifier.isEmpty {
      baseEvent["app_identifier"] = appIdentifier
    }

    if let serviceName = values["service_name"], !serviceName.isEmpty {
      baseEvent["service_name"] = serviceName
    }

    return baseEvent
  }

  private static func installExceptionHandler() {
    NSSetUncaughtExceptionHandler(logFlowExceptionHandler)
  }

  private static func installSignalHandlers() {
    [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP].forEach { signalCode in
      signal(signalCode, logFlowSignalHandler)
    }
  }

  private static func persistException(_ exception: NSException) {
    let fileURL = crashDirectoryURL().appendingPathComponent("pending-exception-\(UUID().uuidString).crash")
    let stack = exception.callStackSymbols.joined(separator: "\n").replacingOccurrences(of: "\n", with: "\\n")
    let message = [
      "type=exception",
      "name=\(exception.name.rawValue)",
      "message=\((exception.reason ?? "Objective-C exception").replacingOccurrences(of: "\n", with: " "))",
      "stack=\(stack)",
      "session_id=\(context.sessionID)",
      "device_id=\(context.deviceID)",
      "environment=\(context.environment)",
      "sdk_version=\(context.sdkVersion)",
      "app_version=\(context.appVersion)",
      "os_version=\(context.osVersion)",
      "device_model=\(context.deviceModel)",
      "target_category=\(context.targetCategory)",
      "app_identifier=\(context.appIdentifier ?? "")",
      "service_name=\(context.serviceName ?? "")",
      "user_id=\(user["id"] ?? "")",
      "user_email=\(user["email"] ?? "")",
      "breadcrumbs=\(breadcrumbSnapshot)",
    ].joined(separator: "\n")

    try? message.data(using: .utf8)?.write(to: fileURL, options: .atomic)
  }

  static func handleException(_ exception: NSException) {
    persistException(exception)
  }

  private static func prepareSignalContext() {
    let path = crashDirectoryURL().appendingPathComponent(signalFileName).path

    var pathCStr = [CChar](repeating: 0, count: 1024)
    var pathIdx = 0
    path.withCString { ptr in
      while pathIdx < 1023 && ptr[pathIdx] != 0 {
        pathCStr[pathIdx] = ptr[pathIdx]
        pathIdx += 1
      }
      pathCStr[pathIdx] = 0
    }

    for i in 0..<signalPath.count {
      signalPath[i] = i < pathCStr.count ? pathCStr[i] : 0
    }

    let base = [
      "type=signal",
      "session_id=\(context.sessionID)",
      "device_id=\(context.deviceID)",
      "environment=\(context.environment)",
      "sdk_version=\(context.sdkVersion)",
      "app_version=\(context.appVersion)",
      "os_version=\(context.osVersion)",
      "device_model=\(context.deviceModel)",
      "target_category=\(context.targetCategory)",
      "app_identifier=\(context.appIdentifier ?? "")",
      "service_name=\(context.serviceName ?? "")",
      "breadcrumbs=\(breadcrumbSnapshot)",
    ].joined(separator: "\n") + "\n"

    let baseBytes = Array(base.utf8)
    signalBaseLength = min(baseBytes.count, signalBase.count)
    for i in 0..<signalBase.count {
      signalBase[i] = i < baseBytes.count ? baseBytes[i] : 0
    }
  }

  static func crashDirectoryURL() -> URL {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let directory = base.appendingPathComponent(directoryName, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  static func persistSignal(_ signalCode: Int32) {
    let fileDescriptor = signalPath.withUnsafeBufferPointer { buffer -> Int32 in
      guard let baseAddress = buffer.baseAddress else { return -1 }
      return open(baseAddress, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
    }

    guard fileDescriptor >= 0 else {
      return
    }

    signalBase.withUnsafeBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else { return }
      _ = write(fileDescriptor, baseAddress, signalBaseLength)
    }

    signalMessage.withUnsafeBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else { return }
      _ = write(fileDescriptor, baseAddress, buffer.count)
    }

    signalPrefix.withUnsafeBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else { return }
      _ = write(fileDescriptor, baseAddress, buffer.count)
    }

    var digits = [UInt8](repeating: 0, count: 12)
    var index = digits.count
    var value = signalCode

    repeat {
      index -= 1
      digits[index] = UInt8(value % 10) + 48
      value /= 10
    } while value > 0 && index > 0

    digits.withUnsafeBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else { return }
      _ = write(fileDescriptor, baseAddress.advanced(by: index), buffer.count - index)
    }

    newline.withUnsafeBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else { return }
      _ = write(fileDescriptor, baseAddress, buffer.count)
    }

    let breadcrumbsKey = Array("breadcrumbs=".utf8)
    breadcrumbsKey.withUnsafeBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else { return }
      _ = write(fileDescriptor, baseAddress, buffer.count)
    }

    let breadcrumbsValue = Array(breadcrumbSnapshot.utf8)
    breadcrumbsValue.withUnsafeBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else { return }
      _ = write(fileDescriptor, baseAddress, buffer.count)
    }

    newline.withUnsafeBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else { return }
      _ = write(fileDescriptor, baseAddress, buffer.count)
    }

    _ = close(fileDescriptor)
  }
}

private func logFlowSignalHandler(_ signalCode: Int32) -> Void {
  CrashHandler.persistSignal(signalCode)
  signal(signalCode, SIG_DFL)
  raise(signalCode)
}

private func logFlowExceptionHandler(_ exception: NSException) -> Void {
  CrashHandler.handleException(exception)
}
