import Foundation
import Logging
@preconcurrency import Sentry
import XCTest

@testable import LoggingSentry

final class LoggingSentryTests: XCTestCase {

    // MARK: - Test fixtures

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _items: [SentrySink.Outgoing] = []

        func record(_ item: SentrySink.Outgoing) {
            lock.lock(); defer { lock.unlock() }
            _items.append(item)
        }

        var items: [SentrySink.Outgoing] {
            lock.lock(); defer { lock.unlock() }
            return _items
        }

        var breadcrumbs: [Breadcrumb] {
            items.compactMap {
                if case .breadcrumb(let crumb) = $0 { return crumb }
                return nil
            }
        }

        var captures: [SentrySink.Capture] {
            items.compactMap {
                if case .capture(let capture) = $0 { return capture }
                return nil
            }
        }
    }

    private func makeSink(_ recorder: Recorder) -> SentrySink {
        SentrySink { recorder.record($0) }
    }

    private func makeEvent(
        level: Logger.Level,
        message: String = "msg",
        error: (any Error)? = nil,
        metadata: Logger.Metadata? = nil,
        source: String = "module",
        file: String = "test.swift",
        function: String = "test()",
        line: UInt = 1
    ) -> LogEvent {
        LogEvent(
            level: level,
            message: "\(message)",
            error: error,
            metadata: metadata,
            source: source,
            file: file,
            function: function,
            line: line
        )
    }

    // MARK: - swift-log integration

    func test_swiftLogIntegration_bootstrap() {
        let recorder = Recorder()
        let sink = makeSink(recorder)

        LoggingSystem.bootstrap { label in
            SentryLogHandler(label: label, sink: sink)
        }

        var logger = Logger(label: "Testing")
        logger[metadataKey: "test-key"] = "test-metadata"
        logger.info("Hello World!")

        XCTAssertEqual(logger[metadataKey: "test-key"], "test-metadata")

        let crumb = recorder.breadcrumbs.first
        XCTAssertEqual(crumb?.level, .info)
        XCTAssertEqual(crumb?.message, "Hello World!")
        XCTAssertEqual(crumb?.category, "Testing")
        XCTAssertEqual(crumb?.type, "log")
        XCTAssertEqual(crumb?.data?["test-key"] as? String, "test-metadata")
        XCTAssertNotNil(crumb?.data?["file"])
        XCTAssertNotNil(crumb?.data?["function"])
        XCTAssertNotNil(crumb?.data?["line"])
        XCTAssertNotNil(crumb?.timestamp)
    }

    // MARK: - Level mapping

    func test_levelMapping_coversAllLevels() {
        let mappings: [(Logger.Level, SentryLevel)] = [
            (.trace, .debug),
            (.debug, .debug),
            (.info, .info),
            (.notice, .info),
            (.warning, .warning),
            (.error, .error),
            (.critical, .fatal),
        ]

        for (loggerLevel, sentryLevel) in mappings {
            let recorder = Recorder()
            let handler = SentryLogHandler(label: "App", sink: makeSink(recorder))
            handler.log(event: makeEvent(level: loggerLevel))

            let emittedLevel = recorder.breadcrumbs.first?.level ?? recorder.captures.first?.level
            XCTAssertEqual(
                emittedLevel,
                sentryLevel,
                "Logger.\(loggerLevel) should map to SentryLevel.\(sentryLevel)"
            )
        }
    }

    // MARK: - Metadata merging

    func test_metadata_persistentIsKeptWhenCallSiteAlsoSet() {
        let recorder = Recorder()
        var handler = SentryLogHandler(label: "App", sink: makeSink(recorder))
        handler[metadataKey: "user_id"] = "u-1"
        handler[metadataKey: "request_id"] = "stale"

        handler.log(event: makeEvent(
            level: .info,
            metadata: ["request_id": "fresh", "endpoint": "/login"]
        ))

        let data = recorder.breadcrumbs.first?.data
        XCTAssertEqual(data?["user_id"] as? String, "u-1", "persistent metadata must survive a per-call dict")
        XCTAssertEqual(data?["request_id"] as? String, "fresh", "call-site keys override persistent ones")
        XCTAssertEqual(data?["endpoint"] as? String, "/login")
    }

    func test_metadata_providerOverridesHandler_callSiteOverridesProvider() {
        let recorder = Recorder()
        let provider = Logger.MetadataProvider { ["trace_id": "tr-1", "span_id": "sp-1"] }
        var handler = SentryLogHandler(label: "App", metadataProvider: provider, sink: makeSink(recorder))
        handler[metadataKey: "trace_id"] = "ignored"

        handler.log(event: makeEvent(
            level: .info,
            metadata: ["span_id": "sp-2"]
        ))

        let data = recorder.breadcrumbs.first?.data
        XCTAssertEqual(data?["trace_id"] as? String, "tr-1", "provider overrides handler.metadata")
        XCTAssertEqual(data?["span_id"] as? String, "sp-2", "call-site overrides provider")
    }

    func test_metadata_nestedDictAndArrayPreserved() {
        let recorder = Recorder()
        let handler = SentryLogHandler(label: "App", sink: makeSink(recorder))

        handler.log(event: makeEvent(
            level: .info,
            metadata: [
                "request": ["id": "r-1", "method": "GET"],
                "tags": ["a", "b", "c"],
            ]
        ))

        let data = recorder.breadcrumbs.first?.data
        XCTAssertEqual((data?["request"] as? [String: Any])?["id"] as? String, "r-1")
        XCTAssertEqual((data?["request"] as? [String: Any])?["method"] as? String, "GET")
        XCTAssertEqual(data?["tags"] as? [String], ["a", "b", "c"])
    }

    func test_metadata_locationFieldsAlwaysAttached() {
        let recorder = Recorder()
        let handler = SentryLogHandler(label: "App", sink: makeSink(recorder))

        handler.log(event: makeEvent(
            level: .info,
            source: "MyModule",
            file: "Foo.swift",
            function: "doThing()",
            line: 42
        ))

        let data = recorder.breadcrumbs.first?.data
        XCTAssertEqual(data?["source"] as? String, "MyModule")
        XCTAssertEqual(data?["file"] as? String, "Foo.swift")
        XCTAssertEqual(data?["function"] as? String, "doThing()")
        XCTAssertEqual(data?["line"] as? Int, 42)
    }

    func test_metadata_errorFieldsAttachedAtAnyLevel() {
        struct Boom: Error {}
        let recorder = Recorder()
        let handler = SentryLogHandler(label: "App", sink: makeSink(recorder))

        handler.log(event: makeEvent(level: .warning, error: Boom()))

        let data = recorder.breadcrumbs.first?.data
        XCTAssertTrue((data?["error.type"] as? String)?.contains("Boom") ?? false)
        XCTAssertNotNil(data?["error.message"])
    }

    // MARK: - Capture behaviour

    func test_capture_errorLevelWithErrorObject() {
        struct Boom: Error {}
        let recorder = Recorder()
        var handler = SentryLogHandler(label: "Net", sink: makeSink(recorder))
        handler[metadataKey: "session"] = "s-1"
        let err = Boom()

        handler.log(event: makeEvent(
            level: .error,
            message: "request failed",
            error: err,
            metadata: ["status": "500"]
        ))

        XCTAssertEqual(recorder.items.count, 1, "error-level should emit only a capture, not also a breadcrumb")
        XCTAssertTrue(recorder.breadcrumbs.isEmpty)
        XCTAssertEqual(recorder.captures.count, 1)

        let capture = recorder.captures.first
        XCTAssertEqual(capture?.level, .error)
        XCTAssertEqual(capture?.label, "Net")
        if case .error(let captured) = capture?.subject {
            XCTAssertTrue(captured is Boom)
        } else {
            XCTFail("expected .error subject, got \(String(describing: capture?.subject))")
        }
        XCTAssertEqual(capture?.extras["session"] as? String, "s-1")
        XCTAssertEqual(capture?.extras["status"] as? String, "500")
        XCTAssertEqual(capture?.extras["file"] as? String, "test.swift")
        XCTAssertEqual(capture?.extras["line"] as? Int, 1)
        XCTAssertTrue((capture?.extras["error.type"] as? String)?.contains("Boom") ?? false)
        XCTAssertEqual(
            capture?.extras["log.message"] as? String,
            "request failed",
            "log message should be attached as log.message when capturing an error"
        )
    }

    func test_capture_messageSubjectDoesNotDuplicateLogMessageInExtras() {
        let recorder = Recorder()
        let handler = SentryLogHandler(label: "Net", sink: makeSink(recorder))

        handler.log(event: makeEvent(level: .error, message: "request failed", error: nil))

        let capture = recorder.captures.first
        XCTAssertNil(
            capture?.extras["log.message"],
            "no log.message extra when the message itself is the capture subject"
        )
    }

    func test_capture_errorLevelWithoutErrorObjectFallsBackToMessage() {
        let recorder = Recorder()
        let handler = SentryLogHandler(label: "Net", sink: makeSink(recorder))

        handler.log(event: makeEvent(
            level: .error,
            message: "request failed",
            error: nil,
            metadata: ["status": "500"]
        ))

        XCTAssertTrue(recorder.breadcrumbs.isEmpty)
        XCTAssertEqual(recorder.captures.count, 1)
        let capture = recorder.captures.first
        XCTAssertEqual(capture?.level, .error)
        if case .message(let body) = capture?.subject {
            XCTAssertEqual(body, "request failed")
        } else {
            XCTFail("expected .message subject, got \(String(describing: capture?.subject))")
        }
        XCTAssertEqual(capture?.extras["status"] as? String, "500")
    }

    func test_capture_criticalWithoutErrorFallsBackToMessage() {
        let recorder = Recorder()
        let handler = SentryLogHandler(label: "Boot", sink: makeSink(recorder))

        handler.log(event: makeEvent(level: .critical, message: "kaboom"))

        XCTAssertEqual(recorder.captures.count, 1)
        XCTAssertEqual(recorder.captures.first?.level, .fatal)
        if case .message(let body) = recorder.captures.first?.subject {
            XCTAssertEqual(body, "kaboom")
        } else {
            XCTFail("expected .message subject")
        }
    }

    func test_capture_criticalWithErrorCapturesError() {
        struct Boom: Error {}
        let recorder = Recorder()
        let handler = SentryLogHandler(label: "Boot", sink: makeSink(recorder))

        handler.log(event: makeEvent(level: .critical, error: Boom()))

        XCTAssertEqual(recorder.captures.count, 1)
        XCTAssertEqual(recorder.captures.first?.level, .fatal)
        if case .error = recorder.captures.first?.subject {} else {
            XCTFail("expected .error subject")
        }
    }

    func test_capture_subErrorLevelsOnlyAddBreadcrumb() {
        let nonCapturing: [Logger.Level] = [.trace, .debug, .info, .notice, .warning]
        struct Boom: Error {}

        for level in nonCapturing {
            let recorder = Recorder()
            let handler = SentryLogHandler(label: "App", sink: makeSink(recorder))

            handler.log(event: makeEvent(level: level, error: Boom()))

            XCTAssertEqual(recorder.breadcrumbs.count, 1, "level=\(level)")
            XCTAssertTrue(recorder.captures.isEmpty, "level=\(level) should not capture")
        }
    }

    // MARK: - Threshold knobs

    func test_breadcrumbLevel_dropsLowerLevels() {
        let recorder = Recorder()
        let handler = SentryLogHandler(label: "App", breadcrumbLevel: .info, sink: makeSink(recorder))

        handler.log(event: makeEvent(level: .trace))
        handler.log(event: makeEvent(level: .debug))
        handler.log(event: makeEvent(level: .info))
        handler.log(event: makeEvent(level: .warning))

        XCTAssertEqual(recorder.breadcrumbs.count, 2, "trace and debug should be dropped")
        XCTAssertEqual(recorder.breadcrumbs.first?.level, .info)
        XCTAssertEqual(recorder.breadcrumbs.last?.level, .warning)
    }

    func test_breadcrumbLevel_nilDisablesBreadcrumbs() {
        let recorder = Recorder()
        let handler = SentryLogHandler(label: "App", breadcrumbLevel: nil, sink: makeSink(recorder))

        handler.log(event: makeEvent(level: .info))
        handler.log(event: makeEvent(level: .warning))
        handler.log(event: makeEvent(level: .error))

        XCTAssertTrue(recorder.breadcrumbs.isEmpty)
        XCTAssertEqual(recorder.captures.count, 1, ".error still captures because captureLevel is unchanged")
    }

    func test_captureLevel_higherThanLevelMeansNoCapture() {
        let recorder = Recorder()
        let handler = SentryLogHandler(label: "App", captureLevel: .critical, sink: makeSink(recorder))

        handler.log(event: makeEvent(level: .error))
        handler.log(event: makeEvent(level: .critical))

        XCTAssertEqual(recorder.breadcrumbs.count, 1, ".error falls back to a breadcrumb when captureLevel=.critical")
        XCTAssertEqual(recorder.breadcrumbs.first?.level, .error)
        XCTAssertEqual(recorder.captures.count, 1)
        XCTAssertEqual(recorder.captures.first?.level, .fatal)
    }

    func test_captureLevel_nilDisablesCaptures() {
        let recorder = Recorder()
        let handler = SentryLogHandler(label: "App", captureLevel: nil, sink: makeSink(recorder))

        handler.log(event: makeEvent(level: .error))
        handler.log(event: makeEvent(level: .critical))

        XCTAssertTrue(recorder.captures.isEmpty)
        XCTAssertEqual(recorder.breadcrumbs.count, 2, "without captures, error/critical fall back to breadcrumbs")
    }

    func test_thresholds_bothNilDropsEverything() {
        let recorder = Recorder()
        let handler = SentryLogHandler(
            label: "App",
            breadcrumbLevel: nil,
            captureLevel: nil,
            sink: makeSink(recorder)
        )

        handler.log(event: makeEvent(level: .critical))

        XCTAssertTrue(recorder.items.isEmpty)
    }

    // MARK: - Value semantics (swift-log contract)

    func test_handlerHasValueSemantics() {
        let recorder = Recorder()
        var handler1 = SentryLogHandler(label: "L", sink: makeSink(recorder))
        handler1.logLevel = .debug
        handler1[metadataKey: "only-on"] = "first"

        var handler2 = handler1
        handler2.logLevel = .error
        handler2[metadataKey: "only-on"] = "second"

        XCTAssertEqual(handler1.logLevel, .debug)
        XCTAssertEqual(handler2.logLevel, .error)
        XCTAssertEqual(handler1[metadataKey: "only-on"], "first")
        XCTAssertEqual(handler2[metadataKey: "only-on"], "second")
    }

    // MARK: - Live tracker smoke test

    func test_live_doesNotCrashWithoutSentryBootstrap() {
        let handler = SentryLogHandler(label: "Smoke")
        handler.log(event: makeEvent(level: .critical, message: "smoke"))
        handler.log(event: makeEvent(level: .info, message: "smoke"))
    }
}
