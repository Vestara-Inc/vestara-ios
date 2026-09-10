import Foundation
import Network

final class Uploader {
  private let queue: EventQueue
  private let session: URLSession
  private let token: String
  private let apiURL: URL
  private let crashHandler: CrashHandler
  private let beforeSend: (([String: Any]) throws -> [String: Any]?)?
  private let workQueue = DispatchQueue(label: "com.vestara.uploader")
  private let monitorQueue = DispatchQueue(label: "com.vestara.network-monitor")
  private var timer: DispatchSourceTimer?
  private var isUploading = false
  private var isUploadingCrashes = false
  private var wasOnline = false
  private var monitor: AnyObject?

  private let initialCrashRetryDelay: TimeInterval = 10.0
  private let maxCrashRetryDelay: TimeInterval = 120.0
  private var crashRetryDelay: TimeInterval = 10.0
  private var lastCrashUploadAttempt: Date = .distantPast

  static var defaultNowProvider: (() -> Date)? = nil
  var nowProvider: () -> Date = { Date() }
  var currentCrashRetryDelay: TimeInterval {
    var delay: TimeInterval = 0
    workQueue.sync {
      delay = self.crashRetryDelay
    }
    return delay
  }

  init(
    queue: EventQueue,
    token: String,
    apiURL: URL,
    crashHandler: CrashHandler,
    beforeSend: (([String: Any]) throws -> [String: Any]?)? = nil,
    session: URLSession? = nil
  ) {
    self.queue = queue
    self.token = token
    self.apiURL = apiURL
    self.crashHandler = crashHandler
    self.session = session ?? URLSession(configuration: .default)
    self.beforeSend = beforeSend
    if let defaultProvider = Uploader.defaultNowProvider {
      self.nowProvider = defaultProvider
    }
  }

  func start() {
    workQueue.async {
      self.timer?.cancel()
      let nextTimer = DispatchSource.makeTimerSource(queue: self.workQueue)
      nextTimer.schedule(deadline: .now() + 10, repeating: 10)
      nextTimer.setEventHandler { [weak self] in
        self?.performPeriodicTick()
      }
      self.timer = nextTimer
      nextTimer.resume()
      self.startNetworkMonitor()
    }
  }

  func performPeriodicTick() {
    flushQueuedEvents()
    uploadPendingCrashes(force: false)
  }

  func stop() {
    workQueue.async {
      self.timer?.cancel()
      self.timer = nil
      self.stopNetworkMonitor()
    }
  }

  private func startNetworkMonitor() {
    if #available(iOS 12.0, macOS 10.14, *) {
      let netMonitor = NWPathMonitor()
      self.monitor = netMonitor

      netMonitor.pathUpdateHandler = { [weak self] path in
        guard let self else { return }

        let isOnline = path.status == .satisfied

        self.monitorQueue.async {
          let previouslyOnline = self.wasOnline
          self.wasOnline = isOnline

          if isOnline && !previouslyOnline {
            self.workQueue.async {
              self.flushQueuedEvents()
              self.uploadPendingCrashes(force: false)
            }
          }
        }
      }

      netMonitor.start(queue: monitorQueue)
    }
  }

  private func stopNetworkMonitor() {
    if #available(iOS 12.0, macOS 10.14, *) {
      (monitor as? NWPathMonitor)?.cancel()
    }
    monitor = nil
    wasOnline = false
  }

  func flushQueuedEvents() {
    workQueue.async {
      guard !self.isUploading else {
        return
      }

      let events = self.queue.peek(limit: 100)

      guard !events.isEmpty else {
        return
      }

      self.isUploading = true
      self.upload(events: events) { [weak self] success in
        self?.workQueue.async {
          if success {
            self?.queue.removeFirst(events.count)
            self?.isUploading = false

            if (self?.queue.count() ?? 0) > 0 {
              self?.flushQueuedEvents()
            }
          } else {
            self?.isUploading = false
          }
        }
      }
    }
  }

  func uploadPendingCrashes(force: Bool = false) {
    workQueue.async {
      guard !self.isUploadingCrashes else {
        return
      }

      let now = self.nowProvider()
      if now.timeIntervalSince(self.lastCrashUploadAttempt) < self.crashRetryDelay {
        return
      }

      let pending = self.crashHandler.loadPendingCrashes()
      guard !pending.isEmpty else {
        self.crashRetryDelay = self.initialCrashRetryDelay
        self.lastCrashUploadAttempt = .distantPast
        return
      }

      self.isUploadingCrashes = true
      self.lastCrashUploadAttempt = now
      self.uploadCrashesSequentially(Array(pending), cycleHadFailure: false)
    }
  }

  private func uploadCrashesSequentially(_ remaining: [CrashHandler.PendingCrash], cycleHadFailure: Bool) {
    guard let nextCrash = remaining.first else {
      self.isUploadingCrashes = false
      if !cycleHadFailure {
        self.crashRetryDelay = self.initialCrashRetryDelay
        self.lastCrashUploadAttempt = .distantPast
      }
      return
    }

    var eventToUpload: [String: Any]? = nextCrash.event
    if let hook = self.beforeSend {
      do {
        eventToUpload = try hook(nextCrash.event)
      } catch {
        eventToUpload = nextCrash.event
      }
    }

    // Intentional drop by beforeSend hook: delete file and proceed to next.
    guard let event = eventToUpload else {
      self.crashHandler.deleteCrashFiles(at: [nextCrash.fileURL])
      self.uploadCrashesSequentially(Array(remaining.dropFirst()), cycleHadFailure: cycleHadFailure)
      return
    }

    self.uploadSingleCrashEvent(event: event) { [weak self] outcome in
      guard let self = self else { return }
      self.workQueue.async {
        switch outcome {
        case .acknowledged:
          // Delete only when backend explicitly accepted: accepted == 1 && rejected == 0.
          self.crashHandler.deleteCrashFiles(at: [nextCrash.fileURL])
          self.uploadCrashesSequentially(Array(remaining.dropFirst()), cycleHadFailure: cycleHadFailure)

        case .rejected:
          // Backend returned 2xx but rejected == 1 or accepted != 1 (schema/limit rejection).
          // Retain the file (do NOT delete), apply backoff for next retry cycle, but proceed with remaining crashes.
          self.crashRetryDelay = min(self.crashRetryDelay * 2, self.maxCrashRetryDelay)
          self.uploadCrashesSequentially(Array(remaining.dropFirst()), cycleHadFailure: true)

        case .transportError:
          // HTTP != 2xx, network failure, or unparseable response body.
          // Retain the file, apply backoff, stop current upload cycle.
          self.crashRetryDelay = min(self.crashRetryDelay * 2, self.maxCrashRetryDelay)
          self.isUploadingCrashes = false
        }
      }
    }
  }

  enum CrashUploadOutcome {
    case acknowledged
    case rejected
    case transportError
  }

  struct IngestAcknowledgement {
    let accepted: Int
    let rejected: Int
  }

  static func parseIngestAcknowledgement(data: Data?, response: URLResponse?, error: Error?) -> IngestAcknowledgement? {
    guard
      error == nil,
      let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode),
      let data = data,
      let json = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    else {
      return nil
    }

    guard
      let acceptedNumber = json["accepted"] as? NSNumber,
      let rejectedNumber = json["rejected"] as? NSNumber
    else {
      return nil
    }

    return IngestAcknowledgement(accepted: acceptedNumber.intValue, rejected: rejectedNumber.intValue)
  }

  private func uploadSingleCrashEvent(event: [String: Any], completion: @escaping (CrashUploadOutcome) -> Void) {
    let url = apiURL.appendingPathComponent("v1/ingest")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(token, forHTTPHeaderField: "X-SDK-Token")

    guard let body = try? JSONSerialization.data(withJSONObject: ["events": [event]], options: []) else {
      completion(.transportError)
      return
    }

    request.httpBody = body

    session.dataTask(with: request) { data, response, error in
      guard let ack = Uploader.parseIngestAcknowledgement(data: data, response: response, error: error) else {
        completion(.transportError)
        return
      }

      if ack.accepted == 1 && ack.rejected == 0 {
        completion(.acknowledged)
      } else {
        completion(.rejected)
      }
    }.resume()
  }

  func fetchLoggingEnabled(deviceID: String, completion: @escaping (Bool?) -> Void) {
    var components = URLComponents(url: apiURL.appendingPathComponent("v1/sdk/device-settings"), resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "device_id", value: deviceID),
    ]

    guard let url = components?.url else {
      completion(nil)
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue(token, forHTTPHeaderField: "X-SDK-Token")

    session.dataTask(with: request) { data, response, _ in
      guard
        let httpResponse = response as? HTTPURLResponse,
        200..<300 ~= httpResponse.statusCode,
        let data,
        let object = try? JSONSerialization.jsonObject(with: data, options: []),
        let payload = object as? [String: Any],
        let loggingEnabled = payload["logging_enabled"] as? Bool
      else {
        completion(nil)
        return
      }

      completion(loggingEnabled)
    }.resume()
  }

  private func upload(events: [[String: Any]], completion: @escaping (Bool) -> Void) {
    let url = apiURL.appendingPathComponent("v1/ingest")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(token, forHTTPHeaderField: "X-SDK-Token")

    let outboundEvents: [[String: Any]] = events.map { event in
      guard let rawEnv = event["environment"] as? String else {
        return event
      }
      var copy = event
      copy["environment"] = Vestara.normalizeEnvironment(rawEnv)
      return copy
    }

    guard let body = try? JSONSerialization.data(withJSONObject: ["events": outboundEvents], options: []) else {
      completion(false)
      return
    }

    request.httpBody = body

    session.dataTask(with: request) { data, response, error in
      guard let ack = Uploader.parseIngestAcknowledgement(data: data, response: response, error: error) else {
        completion(false)
        return
      }

      let isFullyAccepted = (ack.accepted == outboundEvents.count && ack.rejected == 0)
      completion(isFullyAccepted)
    }.resume()
  }
}
