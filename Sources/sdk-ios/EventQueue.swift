import Foundation

final class EventQueue {
  private let userDefaults: UserDefaults
  private let storageKey = "com.vestara.queue.v1"
  private let limit = 500
  private let accessQueue = DispatchQueue(label: "com.vestara.event-queue")

  init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
  }

  func enqueue(_ event: [String: Any]) {
    accessQueue.sync {
      var events = loadEvents()

      if events.count >= limit {
        if let index = events.firstIndex(where: { (($0["event_type"] as? String) ?? "") != "crash" }) {
          events.remove(at: index)
        } else {
          events.removeFirst()
        }
      }

      events.append(event)
      save(events)
    }
  }

  func peek(limit: Int) -> [[String: Any]] {
    accessQueue.sync {
      Array(loadEvents().prefix(limit))
    }
  }

  func removeFirst(_ count: Int) {
    accessQueue.sync {
      var events = loadEvents()

      guard count > 0 else {
        return
      }

      let boundedCount = min(count, events.count)
      events.removeFirst(boundedCount)
      save(events)
    }
  }

  func count() -> Int {
    accessQueue.sync {
      loadEvents().count
    }
  }

  private func loadEvents() -> [[String: Any]] {
    guard let data = userDefaults.data(forKey: storageKey) else {
      return []
    }

    guard
      let object = try? JSONSerialization.jsonObject(with: data, options: []),
      let events = object as? [[String: Any]]
    else {
      userDefaults.removeObject(forKey: storageKey)
      return []
    }

    return events
  }

  private func save(_ events: [[String: Any]]) {
    guard let data = try? JSONSerialization.data(withJSONObject: events, options: []) else {
      userDefaults.removeObject(forKey: storageKey)
      return
    }

    userDefaults.set(data, forKey: storageKey)
  }
}
