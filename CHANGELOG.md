# Changelog

## 0.1.2

- Preserve runtime target identity fields in native crash payloads.
- Add automatic mobile RUM lifecycle events.
- Keep Swift `fatalError()` / `SIGTRAP` crash capture from 0.1.1.

## 0.1.1

- Fix crash capture for Swift `fatalError()` / `SIGTRAP` crashes by registering `SIGTRAP` in the crash handler.

## 0.1.0

- Initial beta SDK package.
- Added runtime target metadata support for clean dashboard grouping:
  - targetCategory
  - serviceName
  - appIdentifier
- `appIdentifier` defaults to Bundle.main.bundleIdentifier when omitted.
