# Changelog

## 0.1.3

- Fixed persisted crash reports becoming stranded after transient upload failures.
- Added periodic and foreground crash retry with bounded backoff.
- Prevented later signal crashes from overwriting earlier unacknowledged crash reports.
- Crash reports are now deleted only after explicit backend acceptance.
- Regular queued telemetry now validates ingest acknowledgement before removal.
- Existing and new `live` environments normalize to `production`.
- Existing and new `dev` environments normalize to `development`.
- Improved crash-context synchronization.
- Added regression coverage for crash persistence, retries, backend rejection, queue acknowledgement, and environment normalization.

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
