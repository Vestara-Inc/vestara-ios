import Foundation

final class BreadcrumbBuffer {
  private static let limit = 50
  private let queue = DispatchQueue(label: "com.vestara.breadcrumb-buffer")
  private var breadcrumbs: [Breadcrumb] = []
  private var preSerializedSnapshot: String = ""

  var snapshot: String {
    queue.sync { preSerializedSnapshot }
  }

  func add(category: String, message: String, level: String, data: [String: Any]? = nil) {
    queue.async {
      let breadcrumb = Breadcrumb(
        timestamp: ISO8601DateFormatter().string(from: Date()),
        category: category,
        message: message,
        level: level,
        data: data
      )

      self.breadcrumbs.append(breadcrumb)

      if self.breadcrumbs.count > Self.limit {
        self.breadcrumbs.removeFirst()
      }

      self.updatePreSerializedSnapshot()
    }
  }

  func clear() {
    queue.async {
      self.breadcrumbs.removeAll()
      self.updatePreSerializedSnapshot()
    }
  }

  private func updatePreSerializedSnapshot() {
    guard let data = try? JSONEncoder().encode(breadcrumbs),
          let json = String(data: data, encoding: .utf8) else {
      preSerializedSnapshot = ""
      return
    }

    preSerializedSnapshot = json
  }
}

struct Breadcrumb: Codable {
  let timestamp: String
  let category: String
  let message: String
  let level: String
  let data: [String: String]?

  enum CodingKeys: String, CodingKey {
    case timestamp
    case category
    case message
    case level
    case data
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    timestamp = try container.decode(String.self, forKey: .timestamp)
    category = try container.decode(String.self, forKey: .category)
    message = try container.decode(String.self, forKey: .message)
    level = try container.decode(String.self, forKey: .level)
    data = try container.decodeIfPresent([String: String].self, forKey: .data)
  }

  init(timestamp: String, category: String, message: String, level: String, data: [String: Any]? = nil) {
    self.timestamp = timestamp
    self.category = category
    self.message = message
    self.level = level
    self.data = data?.mapValues { String(describing: $0) }
  }
}
