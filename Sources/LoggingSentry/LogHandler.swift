import Foundation
import Logging
import Sentry

/// A swift-log `LogHandler` that forwards log statements to Sentry.
///
/// ## Behavior
/// Each accepted log statement takes exactly one of three paths, decided by its level:
/// - At or above `captureLevel` → capture as a Sentry event (creates an issue):
///   - With `error:` parameter set → `SentrySDK.capture(error:)`
///   - Without an `error:` parameter → `SentrySDK.capture(message:)`
/// - At or above `breadcrumbLevel` (but below `captureLevel`) → add as a Sentry breadcrumb.
/// - Below `breadcrumbLevel` → dropped (the breadcrumb buffer isn't filled with noise).
///
/// Captured events are tagged with `logger=<label>` and `source=<module>` and carry the merged
/// metadata as scope extras alongside `file`, `function`, `line`, and `error.*` keys. When the
/// event carries an `Error`, the log message itself is also attached as `log.message` so the
/// developer's call-site message survives even though Sentry titles the issue from the error.
///
/// ## Metadata
/// Metadata is merged in canonical swift-log order, with later sources overriding earlier ones:
/// handler-stored metadata → `metadataProvider` → per-call metadata.
///
/// ## Level mapping (swift-log → Sentry)
/// | swift-log    | Sentry  |
/// | ------------ | ------- |
/// | trace, debug | debug   |
/// | info, notice | info    |
/// | warning      | warning |
/// | error        | error   |
/// | critical     | fatal   |
public struct SentryLogHandler: LogHandler {
    /// The swift-log label this handler was created for. Used as the breadcrumb category
    /// and as the `logger` tag on captured events.
    public let label: String

    /// Lowest level to emit as a Sentry breadcrumb. Levels strictly below this are dropped.
    /// Set to `nil` to never emit breadcrumbs. Defaults to `.trace`.
    public let breadcrumbLevel: Logger.Level?

    /// Lowest level to capture as a Sentry event (creating an issue). Levels at or above this
    /// are captured *instead of* being added as a breadcrumb. Set to `nil` to never capture.
    /// Defaults to `.error`.
    public let captureLevel: Logger.Level?

    private let sink: SentrySink

    public var metadata = Logger.Metadata()
    public var metadataProvider: Logger.MetadataProvider?
    public var logLevel: Logger.Level = .info

    /// Create a log handler for the given label.
    ///
    /// - Parameters:
    ///   - label: The swift-log label.
    ///   - metadataProvider: Optional provider whose metadata is merged on every log statement
    ///     (between handler-stored metadata and per-call metadata).
    ///   - breadcrumbLevel: Lowest level to emit as a breadcrumb. `nil` disables breadcrumbs.
    ///   - captureLevel: Lowest level to capture as a Sentry event. `nil` disables captures.
    ///   - sink: Where emissions are sent. Defaults to `.live`, which forwards to `SentrySDK`.
    public init(
        label: String,
        metadataProvider: Logger.MetadataProvider? = nil,
        breadcrumbLevel: Logger.Level? = .trace,
        captureLevel: Logger.Level? = .error,
        sink: SentrySink = .live
    ) {
        self.label = label
        self.metadataProvider = metadataProvider
        self.breadcrumbLevel = breadcrumbLevel
        self.captureLevel = captureLevel
        self.sink = sink
    }

    public func log(event: LogEvent) {
        let body = event.message.description
        let merged = effectiveMetadata(for: event)
        let level = Self.sentryLevel(for: event.level)
        var extras = makeExtras(event: event, metadata: merged)

        if let captureLevel, event.level >= captureLevel {
            let subject: SentrySink.Capture.Subject
            if let error = event.error {
                subject = .error(error)
                extras["log.message"] = body
            } else {
                subject = .message(body)
            }
            sink.send(.capture(SentrySink.Capture(
                subject: subject,
                level: level,
                label: label,
                event: event,
                metadata: merged,
                extras: extras
            )))
        } else if let breadcrumbLevel, event.level >= breadcrumbLevel {
            let crumb = Breadcrumb()
            crumb.category = label
            crumb.level = level
            crumb.type = "log"
            crumb.message = body
            crumb.timestamp = Date()
            crumb.data = extras
            sink.send(.breadcrumb(crumb))
        }
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { self.metadata[key] }
        set { self.metadata[key] = newValue }
    }

    private func effectiveMetadata(for event: LogEvent) -> Logger.Metadata {
        var merged = self.metadata
        if let provided = self.metadataProvider?.get(), !provided.isEmpty {
            merged.merge(provided) { _, new in new }
        }
        if let explicit = event.metadata, !explicit.isEmpty {
            merged.merge(explicit) { _, new in new }
        }
        return merged
    }

    private func makeExtras(event: LogEvent, metadata: Logger.Metadata) -> [String: any Sendable] {
        var extras = MetadataConversion.toAny(metadata)
        extras["source"] = event.source
        extras["file"] = event.file
        extras["function"] = event.function
        extras["line"] = Int(event.line)
        if let error = event.error {
            extras["error.type"] = String(reflecting: type(of: error))
            extras["error.message"] = "\(error)"
        }
        return extras
    }

    private static func sentryLevel(for level: Logger.Level) -> SentryLevel {
        switch level {
        case .trace, .debug:
            return .debug
        case .info, .notice:
            return .info
        case .warning:
            return .warning
        case .error:
            return .error
        case .critical:
            return .fatal
        }
    }
}
