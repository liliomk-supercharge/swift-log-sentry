# swift-log-sentry

[![Swift Package Index](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fidolize%2Fswift-log-sentry%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/idolize/swift-log-sentry)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fidolize%2Fswift-log-sentry%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/idolize/swift-log-sentry)

A [Sentry](https://sentry.io) backend for [swift-log](https://github.com/apple/swift-log).

## Behavior

Each accepted log statement takes exactly one of three paths, decided by its level:

- At or above `captureLevel` (default `.error`) → captured as a Sentry event so an issue is
  created. With an `Error` attached → `SentrySDK.capture(error:)`; otherwise →
  `SentrySDK.capture(message:)`.
- At or above `breadcrumbLevel` (default `.trace`) but below `captureLevel` → added as a
  Sentry breadcrumb so it appears in the trail attached to subsequent events.
- Below `breadcrumbLevel` → dropped.

This split — error/critical become events *instead of* breadcrumbs — matches the behavior
of Sentry's Python logging integration and avoids the noise of an error appearing both as
a breadcrumb and as the event it triggered.

Captured events are scoped with a `logger=<label>` tag, a `source=<module>` tag, and the
merged metadata as scope extras (alongside `file`, `function`, `line`, and `error.*` keys).

### Tuning the thresholds

Both knobs accept `Logger.Level?`; pass `nil` to disable that path entirely.

```swift
// Drop chatty trace/debug, keep info+ as breadcrumbs, capture error+:
SentryLogHandler(label: label, breadcrumbLevel: .info)

// Capture only `.critical`; everything else falls back to breadcrumbs:
SentryLogHandler(label: label, captureLevel: .critical)

// Breadcrumbs only, never capture:
SentryLogHandler(label: label, captureLevel: nil)
```

### Metadata

Metadata is merged in the canonical swift-log order, last write wins:

1. Handler-stored metadata (`logger[metadataKey:] = …`)
2. `Logger.MetadataProvider`'s contribution
3. Per-call metadata (`logger.info("…", metadata: […])`)

Nested dictionaries and arrays are preserved structurally — they go to Sentry as nested data,
not as stringified blobs.

### Level mapping

| swift-log    | Sentry  |
| ------------ | ------- |
| trace, debug | debug   |
| info, notice | info    |
| warning      | warning |
| error        | error   |
| critical     | fatal   |

## Installation

In your `Package.swift`:

```swift
.package(url: "https://github.com/idolize/swift-log-sentry.git", from: "2.1.0"),
```

Add `LoggingSentry` to your target's dependencies:

```swift
.target(
    name: "BestExampleApp",
    dependencies: [
        .product(name: "LoggingSentry", package: "swift-log-sentry"),
    ]
)
```

## Usage

Start the Sentry SDK first, then bootstrap swift-log to use `SentryLogHandler`:

```swift
import Logging
import LoggingSentry
import Sentry

SentrySDK.start { options in
    options.dsn = "<your DSN>"
}

LoggingSystem.bootstrap { label in
    SentryLogHandler(label: label)
}

let logger = Logger(label: "MyApp")
logger.info("hello", metadata: ["userId": "u-1"])
logger.error("download failed", error: error, metadata: ["url": "\(url)"])
```

### Metadata provider

```swift
let provider = Logger.MetadataProvider {
    ["traceId": "\(currentTraceID())"]
}

LoggingSystem.bootstrap { label in
    SentryLogHandler(label: label, metadataProvider: provider)
}
```

## Testing

The handler does not call `SentrySDK` directly — it routes everything through `SentrySink`,
so tests can inject a recorder:

```swift
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SentrySink.Outgoing] = []

    func record(_ item: SentrySink.Outgoing) {
        lock.lock(); defer { lock.unlock() }
        items.append(item)
    }
}

let recorder = Recorder()
let handler = SentryLogHandler(
    label: "Test",
    sink: SentrySink { recorder.record($0) }
)

handler.log(event: …)
// inspect what was recorded
```

## License

MIT — see [LICENSE.md](LICENSE.md).
