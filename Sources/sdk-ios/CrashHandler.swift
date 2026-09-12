import Foundation
import Darwin
#if canImport(VestaraCSignalState)
@_implementationOnly import VestaraCSignalState
#endif

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
  private static let contextLock = NSLock()
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
    vestara_signal_state_reset()
    CrashHandler.prepareSignalContext()
    CrashHandler.installExceptionHandler()
    CrashHandler.installSignalHandlers()
  }

  func updateUser(id: String, email: String?) {
    CrashHandler.contextLock.lock()
    CrashHandler.user = [
      "id": id,
      "email": email ?? "",
    ]
    CrashHandler.contextLock.unlock()
  }

  func clearUser() {
    CrashHandler.contextLock.lock()
    CrashHandler.user = [:]
    CrashHandler.contextLock.unlock()
  }

  func updateBreadcrumbSnapshot(_ snapshot: String) {
    CrashHandler.contextLock.lock()
    CrashHandler.breadcrumbSnapshot = snapshot
    CrashHandler.contextLock.unlock()
  }

  /**
   * Synchronously stages a fatal React Native JavaScript crash to disk as a pending .crash file.
   * Uses authoritative native context, bounds error strings, and writes atomically.
   * Returns true only on successful persistence; returns false if context is missing or write fails.
   */
  func stageFatal(
    crashId: String,
    message: String,
    errorType: String?,
    stack: String?,
    jsBreadcrumbsJson: String?
  ) -> Bool {
    guard !CrashHandler.context.sessionID.isEmpty && !CrashHandler.context.deviceID.isEmpty else {
      return false
    }

    let boundedMessage = message.count > 8192 ? String(message.prefix(8192)) + " [truncated]" : (message.isEmpty ? "Fatal React Native JS error" : message)
    let boundedErrorType = (errorType?.isEmpty ?? true) ? "ReactNativeFatalError" : String(errorType!.prefix(256))
    let boundedStack = (stack?.count ?? 0) > 32768 ? String(stack!.prefix(32768)) : (stack ?? "")

    CrashHandler.contextLock.lock()
    let rawBreadcrumbs = jsBreadcrumbsJson ?? CrashHandler.breadcrumbSnapshot
    let currentUser = CrashHandler.user
    CrashHandler.contextLock.unlock()

    let validBreadcrumbs: String
    if let jsCrumbs = jsBreadcrumbsJson {
      if !jsCrumbs.isEmpty && jsCrumbs.utf8.count <= 16 * 1024 {
        validBreadcrumbs = jsCrumbs
      } else {
        validBreadcrumbs = ""
      }
    } else {
      if !rawBreadcrumbs.isEmpty && rawBreadcrumbs.utf8.count <= 16 * 1024 {
        validBreadcrumbs = rawBreadcrumbs
      } else {
        validBreadcrumbs = ""
      }
    }

    let fileURL = CrashHandler.crashDirectoryURL().appendingPathComponent("pending-rn-\(crashId).crash")

    let escapedMessage = CrashHandler.escapeValue(boundedMessage)
    let escapedStack = CrashHandler.escapeValue(boundedStack)
    let escapedType = CrashHandler.escapeValue(boundedErrorType)
    let rnMessageB64 = Data(boundedMessage.utf8).base64EncodedString()
    let rnStackB64 = Data(boundedStack.utf8).base64EncodedString()

    let contentLines = [
      "type=react_native_js",
      "origin=react_native_js",
      "crash_id=\(crashId)",
      "name=\(escapedType)",
      "message=\(escapedMessage)",
      "stack=\(escapedStack)",
      "rn_message_b64=\(rnMessageB64)",
      "rn_stack_b64=\(rnStackB64)",
      "session_id=\(CrashHandler.context.sessionID)",
      "device_id=\(CrashHandler.context.deviceID)",
      "environment=\(CrashHandler.context.environment)",
      "sdk_version=\(CrashHandler.context.sdkVersion)",
      "app_version=\(CrashHandler.context.appVersion)",
      "os_version=\(CrashHandler.context.osVersion)",
      "device_model=\(CrashHandler.context.deviceModel)",
      "target_category=\(CrashHandler.context.targetCategory)",
      "app_identifier=\(CrashHandler.context.appIdentifier ?? "")",
      "service_name=\(CrashHandler.context.serviceName ?? "")",
      "user_id=\(currentUser["id"] ?? "")",
      "user_email=\(currentUser["email"] ?? "")",
      "breadcrumbs=\(validBreadcrumbs)",
    ]
    let messageText = contentLines.joined(separator: "\n")

    guard let data = messageText.data(using: .utf8) else {
      return false
    }

    do {
      try data.write(to: fileURL, options: .atomic)
      vestara_signal_state_arm_exception()
      return true
    } catch {
      try? FileManager.default.removeItem(at: fileURL)
      return false
    }
  }

  static func escapeValue(_ value: String) -> String {
    return value
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .replacingOccurrences(of: "\n", with: "\\n")
  }

  static func parseJsStack(_ stack: String) -> [[String: Any]] {
    guard !stack.isEmpty else { return [] }
    var frames: [[String: Any]] = []
    let lines = stack.split(separator: "\n")
    for rawLine in lines {
      if frames.count >= 50 { break }
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty { continue }

      if let openParen = line.range(of: " ("), let closeParen = line.range(of: ")", options: .backwards, range: openParen.upperBound..<line.endIndex) {
        let funcPart = String(line[line.startIndex..<openParen.lowerBound]).replacingOccurrences(of: "at ", with: "").trimmingCharacters(in: .whitespaces)
        let location = String(line[openParen.upperBound..<closeParen.lowerBound])
        let locParts = location.split(separator: ":")
        let file = locParts.count > 0 ? String(locParts[0]) : "unknown"
        let lineNum = locParts.count > 1 ? (Int(locParts[1]) ?? 0) : 0
        frames.append(["function": funcPart.isEmpty ? "anonymous" : funcPart, "file": file, "line": lineNum])
        continue
      }

      if line.hasPrefix("at ") {
        let location = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        let locParts = location.split(separator: ":")
        let file = locParts.count > 0 ? String(locParts[0]) : "unknown"
        let lineNum = locParts.count > 1 ? (Int(locParts[1]) ?? 0) : 0
        frames.append(["function": "anonymous", "file": file, "line": lineNum])
        continue
      }

      if let atRange = line.range(of: "@") {
        let funcPart = String(line[line.startIndex..<atRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let location = String(line[atRange.upperBound...])
        let locParts = location.split(separator: ":")
        let file = locParts.count > 0 ? String(locParts[0]) : "unknown"
        let lineNum = locParts.count > 1 ? (Int(locParts[1]) ?? 0) : 0
        frames.append(["function": funcPart.isEmpty ? "anonymous" : funcPart, "file": file, "line": lineNum])
        continue
      }

      frames.append(["function": line, "file": "unknown", "line": 0])
    }
    return frames
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

    let sortedURLs = fileURLs
      .filter { $0.pathExtension == "crash" }
      .sorted { u1, u2 in
        let d1 = (try? u1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
        let d2 = (try? u2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
        if d1 == d2 {
          return u1.lastPathComponent < u2.lastPathComponent
        }
        return d1 < d2
      }

    return sortedURLs.compactMap { fileURL in
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
      if let data = breadcrumbsJSON.data(using: .utf8) {
        if let breadcrumbs = try? JSONDecoder().decode([Breadcrumb].self, from: data) {
          payload["breadcrumbs"] = breadcrumbs.map { [
            "timestamp": $0.timestamp,
            "category": $0.category,
            "message": $0.message,
            "level": $0.level,
            "data": $0.data as Any,
          ]}
        } else if let genericArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
          payload["breadcrumbs"] = genericArray
        }
      }
    }

    guard
      let sessionID = values["session_id"],
      let deviceID = values["device_id"],
      let rawEnvironment = values["environment"],
      let sdkVersion = values["sdk_version"],
      let appVersion = values["app_version"],
      let osVersion = values["os_version"],
      let deviceModel = values["device_model"]
    else {
      return nil
    }

    let environment = Vestara.normalizeEnvironment(rawEnvironment)

    if let targetCategory = values["target_category"], !targetCategory.isEmpty {
      payload["target_category"] = targetCategory
    }
    if let appIdentifier = values["app_identifier"], !appIdentifier.isEmpty {
      payload["app_identifier"] = appIdentifier
    }
    if let serviceName = values["service_name"], !serviceName.isEmpty {
      payload["service_name"] = serviceName
    }
    if let origin = values["origin"], !origin.isEmpty {
      payload["origin"] = origin
    }
    if let crashId = values["crash_id"], !crashId.isEmpty {
      payload["crash_id"] = crashId
    }
    if values["type"] == "react_native_js" {
      payload["fatal"] = true
      payload["handled"] = false

      if let b64Msg = values["rn_message_b64"],
         let data = Data(base64Encoded: b64Msg),
         let decodedMsg = String(data: data, encoding: .utf8) {
        payload["message"] = decodedMsg
      }

      var jsStack = values["stack"] ?? ""
      if let b64Stack = values["rn_stack_b64"],
         let data = Data(base64Encoded: b64Stack),
         let decodedStack = String(data: data, encoding: .utf8) {
        jsStack = decodedStack
        payload["stack"] = decodedStack
      }

      if !jsStack.isEmpty {
        payload["stack_trace"] = parseJsStack(jsStack)
      }
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

    CrashHandler.contextLock.lock()
    let currentBreadcrumbs = breadcrumbSnapshot
    let currentUser = user
    CrashHandler.contextLock.unlock()

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
      "user_id=\(currentUser["id"] ?? "")",
      "user_email=\(currentUser["email"] ?? "")",
      "breadcrumbs=\(currentBreadcrumbs)",
    ].joined(separator: "\n")

    try? message.data(using: .utf8)?.write(to: fileURL, options: .atomic)
  }

  static func handleException(_ exception: NSException) {
    if handleExceptionSuppression(exception) {
      return
    }
    persistException(exception)
  }

  internal static func handleExceptionSuppression(_ exception: NSException) -> Bool {
    if exception.name.rawValue.hasPrefix("RCTFatalException") {
      if vestara_signal_state_consume_exception() {
        vestara_signal_state_arm_sigabrt()
        return true
      }
    }
    return false
  }

  internal static func consumeSignalSuppression(_ signalCode: Int32) -> Bool {
    return vestara_signal_state_consume_sigabrt(signalCode)
  }

  internal static func resetSuppressionTokensForTest() {
    vestara_signal_state_reset()
  }

  internal static func isFatalExceptionSuppressionArmedForTest() -> Bool {
    return vestara_signal_state_is_exception_armed()
  }

  internal static func isSignalSuppressionArmedForTest() -> Bool {
    return vestara_signal_state_is_sigabrt_armed()
  }

  static func prepareSignalContext(uniqueFileName: String? = nil) {
    let fileName = uniqueFileName ?? "pending-signal-\(UUID().uuidString).crash"
    let path = crashDirectoryURL().appendingPathComponent(fileName).path

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

    CrashHandler.contextLock.lock()
    let currentBreadcrumbs = breadcrumbSnapshot
    CrashHandler.contextLock.unlock()

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
      "breadcrumbs=\(currentBreadcrumbs)",
    ].joined(separator: "\n") + "\n"

    let baseBytes = Array(base.utf8)
    signalBaseLength = min(baseBytes.count, signalBase.count)
    for i in 0..<signalBase.count {
      signalBase[i] = i < baseBytes.count ? baseBytes[i] : 0
    }
  }

  static var customCrashDirectoryURL: URL? = nil

  static func crashDirectoryURL() -> URL {
    if let custom = customCrashDirectoryURL {
      try? FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
      return custom
    }
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

    _ = close(fileDescriptor)
  }
}

private func logFlowSignalHandler(_ signalCode: Int32) -> Void {
  if vestara_signal_state_consume_sigabrt(signalCode) {
    signal(signalCode, SIG_DFL)
    raise(signalCode)
    return
  }
  CrashHandler.persistSignal(signalCode)
  signal(signalCode, SIG_DFL)
  raise(signalCode)
}

private func logFlowExceptionHandler(_ exception: NSException) -> Void {
  CrashHandler.handleException(exception)
}
