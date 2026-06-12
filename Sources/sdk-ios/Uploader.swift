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

  init(queue: EventQueue, token: String, apiURL: URL, crashHandler: CrashHandler, beforeSend: (([String: Any]) throws -> [String: Any]?)? = nil) {
    self.queue = queue
    self.token = token
    self.apiURL = apiURL
    self.crashHandler = crashHandler
    self.session = URLSession(configuration: .default)
    self.beforeSend = beforeSend
  }

  func start() {
    workQueue.async {
      self.timer?.cancel()
      let nextTimer = DispatchSource.makeTimerSource(queue: self.workQueue)
      nextTimer.schedule(deadline: .now() + 10, repeating: 10)
      nextTimer.setEventHandler { [weak self] in
        self?.flushQueuedEvents()
      }
      self.timer = nextTimer
      nextTimer.resume()
      self.startNetworkMonitor()
    }
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
              self.uploadPendingCrashes()
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
      self.upload(events: events) { success in
        self.workQueue.async {
          if success {
            self.queue.removeFirst(events.count)
            self.isUploading = false

            if self.queue.count() > 0 {
              self.flushQueuedEvents()
            }
          } else {
            self.isUploading = false
          }
        }
      }
    }
  }

  func uploadPendingCrashes() {
    workQueue.async {
      guard !self.isUploadingCrashes else {
        return
      }

      let pending = self.crashHandler.loadPendingCrashes()

      guard !pending.isEmpty else {
        return
      }

      var eventsToUpload: [[String: Any]] = []
      for crash in pending {
        if let hook = self.beforeSend {
          do {
            if let filtered = try hook(crash.event) {
              eventsToUpload.append(filtered)
            }
          } catch {
            eventsToUpload.append(crash.event)
          }
        } else {
          eventsToUpload.append(crash.event)
        }
      }

      guard !eventsToUpload.isEmpty else {
        self.crashHandler.deleteCrashFiles(at: pending.map(\.fileURL))
        return
      }

      self.isUploadingCrashes = true

      self.upload(events: eventsToUpload) { [weak self] success in
        self?.workQueue.async {
          self?.isUploadingCrashes = false

          if success {
            self?.crashHandler.deleteCrashFiles(at: pending.map(\.fileURL))
          }
        }
      }
    }
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

    guard let body = try? JSONSerialization.data(withJSONObject: ["events": events], options: []) else {
      completion(false)
      return
    }

    request.httpBody = body

    session.dataTask(with: request) { _, response, _ in
      guard let httpResponse = response as? HTTPURLResponse else {
        completion(false)
        return
      }

      completion((200..<300).contains(httpResponse.statusCode))
    }.resume()
  }
}
