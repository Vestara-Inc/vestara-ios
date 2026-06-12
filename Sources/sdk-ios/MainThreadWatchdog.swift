import Foundation

final class MainThreadWatchdog {
  private let checkInterval: TimeInterval
  private let gracePeriod: TimeInterval
  private let lock = NSLock()
  private let sentinelLock = NSLock()
  private var watchdogThread: Thread?
  private var isRunning = false
  private var isActive = false
  private var reportedThisHang = false
  private var graceTimer: DispatchSourceTimer?
  private var anrCallback: ((TimeInterval, String) -> Void)?
  private var started = false

  init(
    checkInterval: TimeInterval = 5.0,
    gracePeriod: TimeInterval = 10.0
  ) {
    self.checkInterval = checkInterval
    self.gracePeriod = gracePeriod
  }

  func configure(anrCallback: @escaping (TimeInterval, String) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    self.anrCallback = anrCallback
  }

  func start() {
    lock.lock()
    defer { lock.unlock() }

    guard !started else { return }
    started = true
    isRunning = true
    isActive = false
    reportedThisHang = false

    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(deadline: .now() + gracePeriod)
    timer.setEventHandler { [weak self] in
      self?.activateWatchdog()
    }
    graceTimer = timer
    timer.resume()
  }

  func stop() {
    lock.lock()
    defer { lock.unlock() }

    graceTimer?.cancel()
    graceTimer = nil

    isRunning = false
    isActive = false
    started = false
    reportedThisHang = false

    watchdogThread?.cancel()
    watchdogThread = nil
  }

  private func activateWatchdog() {
    lock.lock()
    guard isRunning else {
      lock.unlock()
      return
    }
    isActive = true
    lock.unlock()

    let thread = Thread { [weak self] in
      self?.runWatchdog()
    }
    thread.name = "com.vestara.main-thread-watchdog"
    thread.qualityOfService = .utility

    lock.lock()
    watchdogThread = thread
    lock.unlock()

    thread.start()
  }

  private func runWatchdog() {
    while true {
      let sentinel = DispatchSemaphore(value: 0)

      let blockStart = DispatchTime.now()

      DispatchQueue.main.async { [weak self] in
        self?.sentinelLock.lock()
        self?.reportedThisHang = false
        self?.sentinelLock.unlock()
        sentinel.signal()
      }

      let result = sentinel.wait(timeout: .now() + checkInterval)

      let blockEnd = DispatchTime.now()
      let elapsedNanos = blockEnd.uptimeNanoseconds - blockStart.uptimeNanoseconds
      _ = Double(elapsedNanos) / 1_000_000_000

      lock.lock()
      let active = isActive
      let alreadyReported: Bool = sentinelLock.withLock { reportedThisHang }
      lock.unlock()

      guard active else { break }

      if result == .timedOut && !alreadyReported {
        sentinelLock.lock()
        reportedThisHang = true
        sentinelLock.unlock()

        let callback = lock.withLock { anrCallback }
        callback?(checkInterval, "Main thread blocked for at least \(Int(checkInterval))s")
      }

      Thread.sleep(forTimeInterval: checkInterval)
    }
  }
}

extension NSLock {
  fileprivate func withLock<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}