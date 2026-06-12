import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

final class DeviceInfo {
  private let userDefaults: UserDefaults
  private let deviceIDKey = "com.vestara.device-id"
  private let monitor: AnyObject?
  private let monitorQueue = DispatchQueue(label: "com.vestara.network-monitor")
  private let lock = DispatchQueue(label: "com.vestara.device-info")
  private var networkType = "none"
  var networkChangeCallback: ((String) -> Void)?

  let deviceID: String
  let osVersion: String
  let deviceModel: String
  let appVersion: String
  let buildVersion: String

  init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
    self.deviceID = DeviceInfo.loadDeviceID(userDefaults: userDefaults, key: deviceIDKey)
#if canImport(UIKit)
    self.osVersion = UIDevice.current.systemVersion
    self.deviceModel = UIDevice.current.model
#else
    self.osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    self.deviceModel = "Apple Device"
#endif
    let info = Bundle.main.infoDictionary ?? [:]
    self.appVersion = info["CFBundleShortVersionString"] as? String ?? "unknown"
    self.buildVersion = info["CFBundleVersion"] as? String ?? "unknown"

    if #available(iOS 12.0, macOS 10.14, *) {
      let nextMonitor = NWPathMonitor()
      self.monitor = nextMonitor

      nextMonitor.pathUpdateHandler = { [weak self] path in
        let nextType: String

        if path.status != .satisfied {
          nextType = "none"
        } else if path.usesInterfaceType(.wifi) {
          nextType = "wifi"
        } else if path.usesInterfaceType(.cellular) {
          nextType = "cellular"
        } else {
          nextType = "other"
        }

        self?.lock.async {
          let previousType = self?.networkType
          self?.networkType = nextType

          if previousType != nextType {
            DispatchQueue.main.async {
              self?.networkChangeCallback?(nextType)
            }
          }
        }
      }

      nextMonitor.start(queue: monitorQueue)
    } else {
      self.monitor = nil
    }
  }

  func currentNetworkType() -> String {
    lock.sync {
      networkType
    }
  }

  private static func loadDeviceID(userDefaults: UserDefaults, key: String) -> String {
    if let existing = userDefaults.string(forKey: key), !existing.isEmpty {
      return existing
    }

    let next = UUID().uuidString
    userDefaults.set(next, forKey: key)
    return next
  }
}
