import Logging
@preconcurrency import Sentry

/// The Sentry-facing side of `SentryLogHandler`.
///
/// The log handler does not call `SentrySDK` directly — it sends every emission
/// through a `SentrySink`. Use `SentrySink.live` in production (the default), or
/// inject a custom sink in tests to inspect what would have been sent.
public struct SentrySink: Sendable {
    /// Receives a single emission from a `SentryLogHandler`.
    ///
    /// - Note: May be called from any thread; implementations must be thread-safe.
    public var send: @Sendable (Outgoing) -> Void

    public init(send: @Sendable @escaping (Outgoing) -> Void) {
        self.send = send
    }

    /// One thing leaving the handler bound for Sentry.
    public enum Outgoing: Sendable {
        /// Add a breadcrumb. Emitted for every accepted log statement and provides
        /// the trail of context that Sentry attaches to subsequent captured events.
        case breadcrumb(Breadcrumb)

        /// Capture a Sentry event (creates an issue). Emitted only for `.error` and
        /// `.critical` levels.
        case capture(Capture)
    }

    /// A Sentry event capture request originating from a log statement.
    public struct Capture: Sendable {
        /// What the captured event is anchored to.
        public enum Subject: Sendable {
            /// The log statement carried an `Error` — captured via `SentrySDK.capture(error:)`.
            case error(any Error)
            /// No `Error` was attached — captured via `SentrySDK.capture(message:)`.
            case message(String)
        }

        public var subject: Subject
        public var level: SentryLevel
        /// The swift-log logger label that emitted the log.
        public var label: String
        /// The originating swift-log event. Carries source/file/function/line and the message.
        public var event: LogEvent
        /// Effective metadata for this log statement: handler-stored metadata, then
        /// `metadataProvider`, then call-site metadata, last write wins.
        public var metadata: Logger.Metadata
        /// Pre-formatted extras for `SentryScope.setExtras(_:)`. Includes the merged
        /// metadata plus `file`, `function`, `line`, `source`, and `error.*` keys when
        /// applicable. When `subject == .error`, the log message is also attached as
        /// `log.message`. Values are JSON-serialisable.
        public var extras: [String: any Sendable]

        public init(
            subject: Subject,
            level: SentryLevel,
            label: String,
            event: LogEvent,
            metadata: Logger.Metadata,
            extras: [String: any Sendable]
        ) {
            self.subject = subject
            self.level = level
            self.label = label
            self.event = event
            self.metadata = metadata
            self.extras = extras
        }
    }
}
