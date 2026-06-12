# Vestara iOS SDK

Native Swift SDK for Vestara. Zero external dependencies. Supports iOS 14+.

## Installation

**Swift Package Manager**

Use the latest tagged release. For the first public beta, use version `0.1.0` or newer.

In Xcode: File → Add Package Dependencies → enter `https://github.com/Vestara-Inc/vestara-ios`.

Or in `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/Vestara-Inc/vestara-ios.git", from: "0.1.0")
]
```

Then add `VestaraSDK` as a target dependency.

## Quick Start

```swift
import VestaraSDK

@main
struct MyApp: App {
    init() {
        Vestara.configure(
            token: "YOUR_SDK_TOKEN",
            environment: "production",
            targetCategory: "ios_app",
            serviceName: "iOS App"
        )
    }
}
```

## Runtime target metadata

You can provide metadata to identify this application in the dashboard:
- `targetCategory`: The kind of target (e.g., `ios_app`).
- `serviceName`: Human-readable name (e.g., `iOS App`).
- `appIdentifier`: Optional technical identifier (defaults to `Bundle.main.bundleIdentifier` if omitted).

## Usage

```swift
// Manual log
Vestara.log(.info, "User tapped checkout button")
Vestara.log(.error, "Payment failed: insufficient funds")

// Capture error with context
Vestara.captureError(error, context: ["operation": "checkout"])

// Set user
Vestara.setUser(id: "user-123", email: "user@example.com")

// Start new session
Vestara.startSession()

// Crashes are captured automatically — no extra code needed.
```

## What it captures automatically

Vestara can automatically capture various events depending on platform availability and configuration:

- Signal-based crashes such as `SIGSEGV` and `SIGABRT`
- Objective-C `NSException` capture where available
- Main-thread ANR/freeze watchdog signals
- App lifecycle breadcrumbs (foreground/background)
- Network connectivity breadcrumbs
- Recent breadcrumbs attached to crash payloads
- Mobile RUM metrics if enabled/configured
- Runtime target metadata when configured

> [!IMPORTANT]
> **Privacy Note:** Vestara does not intentionally collect passwords, payment data, or full request bodies. Use `beforeSend` to redact or drop sensitive fields before events are queued. Developers should avoid sending secrets, tokens, passwords, payment data, or unnecessary personal data.

## Configuration

```swift
Vestara.configure(
    token: "YOUR_SDK_TOKEN",
    environment: "production",
    targetCategory: "ios_app",
    serviceName: "iOS App"
)
```

### Before send hook

The `beforeSend` closure lets you inspect, modify, or drop events before they are queued:

```swift
Vestara.configure(
    token: "YOUR_SDK_TOKEN",
    beforeSend: { event in
        // Redact sensitive data
        var modified = event
        if var data = event["payload"] as? [String: Any],
           var payloadData = data["data"] as? [String: Any],
           let _ = payloadData["password"] {
            data["data"] = payloadData
            data["data"]?["password"] = "[REDACTED]"
            modified["payload"] = data
            return modified
        }

        // Drop noisy events
        if let message = (event["payload"] as? [String: Any])?["message"] as? String,
           message.contains("heartbeat") {
            return nil  // drops the event
        }

        return event
    }
)
```

Behavior:
- Return a modified dictionary to send the modified version
- Return `nil` to drop the event
- The beforeSend hook is non-throwing in Swift; fail-open on throw is not applicable

Note: The Vestara backend also applies server-side redaction as a safety layer.

## Mobile RUM (Real User Monitoring)

```swift
// Track a screen load duration
Vestara.trackRumMetric(.screenLoad, value: 450, unit: .ms, screen: "HomeScreen")

// Track a network request
Vestara.trackRumMetric(.networkRequest, value: 340, unit: .ms,
                        name: "GET /api/users",
                        route: "/api/users?token=secret",
                        operation: "GET")

// Report app start time (call after launch completes)
Vestara.reportAppStart()

// Custom metric with tags
Vestara.trackRumMetric(.custom, value: 42, name: "items_loaded",
                        tags: ["source": "cache", "count": 15, "fresh": true])
```

See the backend contract for accepted `metric_type`, `unit`, and `value` constraints. Tags are bounded client-side (max 20 entries, keys ≤64 chars, string values ≤1024 chars). Non-finite values are dropped. Route query strings and fragments are stripped automatically.

## Custom API URL

For local development, staging, or self-hosted deployments, pass `apiURL`:

```swift
Vestara.configure(
    token: "YOUR_SDK_TOKEN",
    apiURL: URL(string: "http://localhost:3000"),
    environment: "development"
)
```

Do not set `apiURL` for normal Vestara SaaS usage.

## Running the Sample

The package includes a `SampleApp` executable target demonstrating SDK integration:

```bash
swift run SampleApp
```

This runs the sample in the SPM host context (macOS). It exercises `Vestara.configure(...)`, `Vestara.log(...)`, `Vestara.setUser(...)`, and `Vestara.startSession()`.

For iOS simulator or device testing, embed `VestaraSDK` as a dependency in a host iOS app and follow the Quick Start pattern above.

## SDK Token

Find your SDK token in the Vestara dashboard under **Settings → SDK & Token**.

> The SDK token is write-only — it can only ingest events. It cannot read your data.

## License

This SDK is licensed under the Apache License 2.0.

Copyright 2026 Ahsan Iqbal.

Vestara, the Vestara name, logos, domain, and related branding are not granted under this license.