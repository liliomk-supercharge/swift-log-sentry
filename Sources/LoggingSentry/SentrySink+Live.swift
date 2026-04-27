import Sentry

extension SentrySink {
    /// The default sink. Forwards breadcrumbs and captures to the running Sentry SDK.
    ///
    /// Captured events are scoped with:
    /// - `level` set to the mapped `SentryLevel`.
    /// - A `logger` tag carrying the swift-log label.
    /// - A `source` tag carrying the swift-log source (i.e. the originating module).
    /// - All merged metadata, plus `file`/`function`/`line`/`source` and `error.*`
    ///   keys when applicable, attached as scope extras.
    public static let live = SentrySink { outgoing in
        switch outgoing {
        case .breadcrumb(let crumb):
            SentrySDK.addBreadcrumb(crumb)

        case .capture(let capture):
            let scopeBlock: @Sendable (Scope) -> Void = { scope in
                scope.setLevel(capture.level)
                scope.setTag(value: capture.label, key: "logger")
                scope.setTag(value: capture.event.source, key: "source")
                scope.setExtras(capture.extras as [String: Any])
            }
            switch capture.subject {
            case .error(let error):
                SentrySDK.capture(error: error, block: scopeBlock)
            case .message(let message):
                SentrySDK.capture(message: message, block: scopeBlock)
            }
        }
    }
}
