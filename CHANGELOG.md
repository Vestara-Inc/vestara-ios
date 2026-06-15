# Changelog

## 0.1.1

- Fix crash capture for Swift `fatalError()` / `SIGTRAP` crashes by registering `SIGTRAP` in the crash handler.

## 0.1.0

- Initial beta SDK package.
- Added runtime target metadata support for clean dashboard grouping:
  - targetCategory
  - serviceName
  - appIdentifier
- `appIdentifier` defaults to Bundle.main.bundleIdentifier when omitted.
