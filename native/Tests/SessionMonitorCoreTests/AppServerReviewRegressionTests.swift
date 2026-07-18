import Foundation
import XCTest
@testable import SessionMonitorCore

private let supportedUserAgent = "codex-session-monitor/0.144.0 (Mac OS 14.0; arm64)"

private func initializeResult(userAgent: String?) -> String {
    guard let userAgent else {
        return #"{"protocolVersion":"2026-07-01"}"#
    }
    return #"{"protocolVersion":"2026-07-01","userAgent":"\#(userAgent)"}"#
}

private let supportedInitializeResult = initializeResult(userAgent: supportedUserAgent)

final class AppServerReviewRegressionTests: XCTestCase {
    private let endpoint = AppServerEndpoint.unixWebSocket(
        socketURL: URL(fileURLWithPath: "/tmp/scrubbed-app-server.sock"),
        requestPath: "/"
    )
    private let fixedNow = Date(timeIntervalSince1970: 1_784_332_800)

    func testConnectionInitializesOnceAcrossPollsThenEOFBacksOffAndReinitializes() async throws {
        let transport = ReviewFakeAppServerTransport(steps: [
            .response("initialize", result: supportedInitializeResult),
            .response("thread/loaded/list", result: #"{"data":[],"nextCursor":null}"#),
            .response("thread/list", result: activeListResult),
            .response("thread/loaded/list", result: #"{"data":[],"nextCursor":null}"#),
            .response("thread/list", result: activeListResult),
            .failure("thread/loaded/list", AppServerTransportFailure.connectionClosed),
            .failure("initialize", AppServerTransportFailure.connectionClosed),
            .failure("initialize", AppServerTransportFailure.connectionClosed),
            .response("initialize", result: supportedInitializeResult),
            .response("thread/loaded/list", result: #"{"data":[],"nextCursor":null}"#),
            .response("thread/list", result: #"{"data":[],"nextCursor":null}"#),
        ])
        let sleeper = RecordingReconnectSleeper()
        let source = AppServerSource(
            endpoint: endpoint,
            transport: transport,
            reconnectBackoff: AppServerReconnectBackoff(
                baseDelayMilliseconds: 250,
                maximumDelayMilliseconds: 500
            ),
            reconnectSleeper: { delay in await sleeper.record(delay) },
            now: { self.fixedNow }
        )

        let first = await source.poll(since: nil)
        let second = await source.poll(since: nil)
        let failed = await source.poll(since: nil)
        let retryOne = await source.poll(since: nil)
        let retryTwo = await source.poll(since: nil)
        let recovered = await source.poll(since: nil)
        let requests = await transport.recordedRequests()
        let delays = await sleeper.recordedDelays()

        XCTAssertEqual(first.events.map(\.kind), [.modelActivity])
        XCTAssertTrue(second.events.isEmpty, "An unchanged active snapshot is not fresh activity")
        XCTAssertEqual(failed.health.status, .unavailable)
        XCTAssertEqual(retryOne.health.status, .unavailable)
        XCTAssertEqual(retryTwo.health.status, .unavailable)
        XCTAssertEqual(recovered.health.status, .healthy)
        XCTAssertEqual(requests.filter { $0.method == "initialize" }.count, 4)
        XCTAssertEqual(delays, [250, 500, 500], "Injected sleep observes the configured cap")
    }

    func testSupportedUserAgentResumesThreadsHistoryFreeAndListsExactInventoryScope() async throws {
        let transport = ReviewFakeAppServerTransport(steps: [
            .response("initialize", result: supportedInitializeResult),
            .response("thread/loaded/list", result: #"{"data":["loaded-a","loaded-b"],"nextCursor":null}"#),
            .response("thread/resume", result: resumedResult("loaded-a")),
            .response("thread/resume", result: resumedResult("loaded-b")),
            .response("thread/list", result: #"{"data":[],"nextCursor":"page-2"}"#),
            .response("thread/list", result: #"{"data":[],"nextCursor":null}"#),
            .response("thread/loaded/list", result: #"{"data":["loaded-a","loaded-b"],"nextCursor":null}"#),
            .response("thread/list", result: #"{"data":[],"nextCursor":null}"#),
        ])
        let source = AppServerSource(
            endpoint: endpoint,
            transport: transport,
            now: { self.fixedNow }
        )

        _ = await source.poll(since: nil)
        _ = await source.poll(since: nil)
        let requests = await transport.recordedRequests()

        XCTAssertEqual(
            requests.map(\.method),
            [
                "initialize", "thread/loaded/list", "thread/resume", "thread/resume",
                "thread/list", "thread/list", "thread/loaded/list", "thread/list",
            ]
        )
        XCTAssertEqual(requests.map(\.id), Array(1...8))
        XCTAssertTrue(try requests[0].nestedBoolParam("experimentalApi", in: "capabilities"))
        XCTAssertEqual(try requests[2].stringParam("threadId"), "loaded-a")
        XCTAssertEqual(try requests[3].stringParam("threadId"), "loaded-b")
        XCTAssertTrue(try requests[2].boolParam("excludeTurns"))
        XCTAssertTrue(try requests[3].boolParam("excludeTurns"))
        XCTAssertEqual(try requests[2].paramKeys(), Set(["threadId", "excludeTurns"]))
        XCTAssertEqual(try requests[3].paramKeys(), Set(["threadId", "excludeTurns"]))
        XCTAssertEqual(try requests[5].stringParam("cursor"), "page-2")
        for index in [4, 5, 7] {
            XCTAssertEqual(try requests[index].intParam("limit"), 100)
            XCTAssertTrue(try requests[index].boolParam("useStateDbOnly"))
            XCTAssertEqual(
                try requests[index].stringArrayParam("sourceKinds"),
                Self.allDocumentedSourceKinds
            )
        }
        XCTAssertEqual(
            try requests[4].paramKeys(),
            Set(["limit", "sourceKinds", "useStateDbOnly"])
        )
        XCTAssertEqual(
            try requests[5].paramKeys(),
            Set(["limit", "sourceKinds", "useStateDbOnly", "cursor"])
        )
        XCTAssertEqual(
            try requests[7].paramKeys(),
            Set(["limit", "sourceKinds", "useStateDbOnly"])
        )
        XCTAssertFalse(requests.contains { ["thread/start", "thread/restart", "turn/start"].contains($0.method) })
        XCTAssertEqual(requests.filter { $0.method == "thread/resume" }.count, 2, "Subscriptions are per connection")
    }

    func testSupportedPrereleaseAndArbitraryOriginatorUseNumericVersionTuple() async {
        let supportedCases = [
            "codex-session-monitor/0.145.0-beta.1 (Mac OS 14.0; arm64)",
            "future_codex_client/9.9.9 (Mac OS 14.0; arm64)",
        ]

        for userAgent in supportedCases {
            let transport = ReviewFakeAppServerTransport(steps: [
                .response("initialize", result: initializeResult(userAgent: userAgent)),
                .response("thread/loaded/list", result: #"{"data":[],"nextCursor":null}"#),
                .response("thread/list", result: #"{"data":[],"nextCursor":null}"#),
            ])
            let source = AppServerSource(endpoint: endpoint, transport: transport, now: { self.fixedNow })

            let result = await source.poll(since: nil)
            let requests = await transport.recordedRequests()

            XCTAssertEqual(result.health, SourceHealth(status: .healthy), userAgent)
            XCTAssertEqual(
                requests.map(\.method),
                ["initialize", "thread/loaded/list", "thread/list"],
                userAgent
            )
        }
    }

    func testUnsupportedOrUnparseableUserAgentFailsBeforeAnyInventoryOrResume() async throws {
        let unsupportedCases: [(String, String?)] = [
            ("below minimum", "codex-session-monitor/0.143.99-beta.1 (Mac OS 14.0; arm64)"),
            ("malformed version", "codex-session-monitor/not-a-version (Mac OS 14.0; arm64)"),
            ("missing", nil),
        ]

        for (name, userAgent) in unsupportedCases {
            let transport = ReviewFakeAppServerTransport(steps: [
                .response("initialize", result: initializeResult(userAgent: userAgent)),
            ])
            let source = AppServerSource(endpoint: endpoint, transport: transport, now: { self.fixedNow })

            let result = await source.poll(since: nil)
            let requests = await transport.recordedRequests()
            let notifications = await transport.recordedNotifications()
            let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)

            XCTAssertEqual(result.health.status, .unavailable, name)
            XCTAssertEqual(result.health.issues, [.appServerProtocol(.unsupportedVersion)], name)
            XCTAssertTrue(result.events.isEmpty, name)
            XCTAssertEqual(requests.map(\.method), ["initialize"], name)
            XCTAssertTrue(try requests[0].nestedBoolParam("experimentalApi", in: "capabilities"), name)
            XCTAssertTrue(notifications.isEmpty, "Do not acknowledge an unsupported connection: \(name)")
            XCTAssertFalse(encoded.contains("turns"), name)
        }
    }

    func testExperimentalExcludeTurnsRejectionFailsOptionalSourceClosedWithoutHistoryFallback() async throws {
        let transport = ReviewFakeAppServerTransport(steps: [
            .response("initialize", result: supportedInitializeResult),
            .response("thread/loaded/list", result: #"{"data":["loaded-old-server"],"nextCursor":null}"#),
            .failure("thread/resume", AppServerTransportFailure.serverError(code: -32602)),
        ])
        let source = AppServerSource(endpoint: endpoint, transport: transport, now: { self.fixedNow })

        let result = await source.poll(since: nil)
        let requests = await transport.recordedRequests()

        XCTAssertEqual(result.health.status, .unavailable)
        XCTAssertEqual(result.health.issues, [.appServerProtocol(.transportViolation)])
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(requests.map(\.method), ["initialize", "thread/loaded/list", "thread/resume"])
        XCTAssertTrue(try requests[0].nestedBoolParam("experimentalApi", in: "capabilities"))
        XCTAssertTrue(try requests[2].boolParam("excludeTurns"))
        XCTAssertEqual(try requests[2].paramKeys(), Set(["threadId", "excludeTurns"]))
        XCTAssertEqual(
            requests.filter { $0.method == "thread/resume" }.count,
            1,
            "Never retry resume without excludeTurns on older App Servers"
        )
    }

    func testIdenticalDuplicateThreadRowsAcrossPagesDeduplicateToOneHealthyEvent() async {
        let duplicate = listedThreadResult(id: "duplicate", status: "active")
        let transport = ReviewFakeAppServerTransport(steps: [
            .response("initialize", result: supportedInitializeResult),
            .response("thread/loaded/list", result: #"{"data":[],"nextCursor":null}"#),
            .response("thread/list", result: pagedResult(rows: [duplicate], nextCursor: "page-2")),
            .response("thread/list", result: pagedResult(rows: [duplicate], nextCursor: nil)),
        ])
        let source = AppServerSource(endpoint: endpoint, transport: transport, now: { self.fixedNow })

        let result = await source.poll(since: nil)

        XCTAssertEqual(result.health, SourceHealth(status: .healthy))
        XCTAssertEqual(result.events.map(\.sessionID), ["duplicate"])
        XCTAssertEqual(result.events.map(\.kind), [.modelActivity])
    }

    func testConflictingDuplicateThreadRowsDegradeWithoutFalseActivity() async {
        let active = listedThreadResult(id: "conflict", status: "active")
        let waiting = listedThreadResult(
            id: "conflict",
            status: "active",
            activeFlags: ["waitingOnApproval"]
        )
        let transport = ReviewFakeAppServerTransport(steps: [
            .response("initialize", result: supportedInitializeResult),
            .response("thread/loaded/list", result: #"{"data":[],"nextCursor":null}"#),
            .response("thread/list", result: pagedResult(rows: [active], nextCursor: "page-2")),
            .response("thread/list", result: pagedResult(rows: [waiting], nextCursor: nil)),
        ])
        let source = AppServerSource(endpoint: endpoint, transport: transport, now: { self.fixedNow })

        let result = await source.poll(since: nil)

        XCTAssertEqual(result.health.status, .degraded)
        XCTAssertEqual(result.health.issues, [.appServerProtocol(.malformedMessage)])
        XCTAssertFalse(result.events.contains { $0.sessionID == "conflict" })
    }

    func testIdenticalStatusNotificationIsSuppressedAcrossRepeatedPolls() async {
        let row = listedThreadResult(id: "unchanged", status: "active")
        let notification = threadStatusChanged(id: "unchanged", status: "active")
        let transport = ReviewFakeAppServerTransport(
            steps: [
                .response("initialize", result: supportedInitializeResult),
                .response("thread/loaded/list", result: #"{"data":[],"nextCursor":null}"#),
                .response("thread/list", result: pagedResult(rows: [row], nextCursor: nil)),
                .response("thread/loaded/list", result: #"{"data":[],"nextCursor":null}"#),
                .response("thread/list", result: pagedResult(rows: [row], nextCursor: nil)),
            ],
            notificationBatches: [[notification], [notification]]
        )
        let source = AppServerSource(endpoint: endpoint, transport: transport, now: { self.fixedNow })

        let first = await source.poll(since: nil)
        let second = await source.poll(since: nil)

        XCTAssertEqual(first.events.map(\.sessionID), ["unchanged"])
        XCTAssertEqual(first.events.map(\.kind), [.modelActivity])
        XCTAssertTrue(second.events.isEmpty, "Repeated identical notifications must not refresh activity")
    }

    func testRepeatedPaginationCursorTerminatesWithinConfiguredBound() async {
        let transport = ReviewFakeAppServerTransport(steps: [
            .response("initialize", result: supportedInitializeResult),
            .response("thread/loaded/list", result: #"{"data":[],"nextCursor":"loop"}"#),
            .response("thread/loaded/list", result: #"{"data":[],"nextCursor":"loop"}"#),
        ])
        let source = AppServerSource(
            endpoint: endpoint,
            transport: transport,
            maximumPaginationPages: 2,
            maximumPaginationItems: 4,
            now: { self.fixedNow }
        )

        let result = await source.poll(since: nil)
        let requests = await transport.recordedRequests()

        XCTAssertEqual(result.health.status, .unavailable)
        XCTAssertEqual(result.health.issues, [.appServerProtocol(.malformedMessage)])
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(requests.filter { $0.method == "thread/loaded/list" }.count, 2)
    }

    func testPaginationItemCountTerminatesWithinConfiguredBound() async {
        let rows = (1...3).map { listedThreadResult(id: "bounded-\($0)", status: "active") }
        let transport = ReviewFakeAppServerTransport(steps: [
            .response("initialize", result: supportedInitializeResult),
            .response("thread/loaded/list", result: #"{"data":[],"nextCursor":null}"#),
            .response("thread/list", result: pagedResult(rows: rows, nextCursor: nil)),
        ])
        let source = AppServerSource(
            endpoint: endpoint,
            transport: transport,
            maximumPaginationPages: 2,
            maximumPaginationItems: 2,
            now: { self.fixedNow }
        )

        let result = await source.poll(since: nil)

        XCTAssertEqual(result.health.status, .unavailable)
        XCTAssertEqual(result.health.issues, [.appServerProtocol(.malformedMessage)])
        XCTAssertTrue(result.events.isEmpty)
    }

    func testPaginationRejectsMissingOrWrongDataAndNonStringCursor() async {
        let malformedCases: [(String, [ReviewStep])] = [
            (
                "loaded missing data",
                [.response("initialize", result: supportedInitializeResult),
                 .response("thread/loaded/list", result: #"{"nextCursor":null}"#)]
            ),
            (
                "loaded wrong data",
                [.response("initialize", result: supportedInitializeResult),
                 .response("thread/loaded/list", result: #"{"data":"wrong","nextCursor":null}"#)]
            ),
            (
                "loaded numeric cursor",
                [.response("initialize", result: supportedInitializeResult),
                 .response("thread/loaded/list", result: #"{"data":[],"nextCursor":7}"#)]
            ),
            (
                "listed missing data",
                [.response("initialize", result: supportedInitializeResult),
                 .response("thread/loaded/list", result: #"{"data":[],"nextCursor":null}"#),
                 .response("thread/list", result: #"{"nextCursor":null}"#)]
            ),
            (
                "listed wrong data",
                [.response("initialize", result: supportedInitializeResult),
                 .response("thread/loaded/list", result: #"{"data":[],"nextCursor":null}"#),
                 .response("thread/list", result: #"{"data":"wrong","nextCursor":null}"#)]
            ),
            (
                "listed numeric cursor",
                [.response("initialize", result: supportedInitializeResult),
                 .response("thread/loaded/list", result: #"{"data":[],"nextCursor":null}"#),
                 .response("thread/list", result: #"{"data":[],"nextCursor":7}"#)]
            ),
        ]

        for (name, steps) in malformedCases {
            let transport = ReviewFakeAppServerTransport(steps: steps)
            let source = AppServerSource(endpoint: endpoint, transport: transport, now: { self.fixedNow })

            let result = await source.poll(since: nil)

            XCTAssertEqual(result.health.status, .unavailable, name)
            XCTAssertEqual(result.health.issues, [.appServerProtocol(.malformedMessage)], name)
            XCTAssertTrue(result.events.isEmpty, name)
        }
    }

    func testAbsentAndNullPaginationCursorsBothTerminateLoadedAndListedInventory() async {
        let terminalCursorCases = [
            ("absent", #"{"data":[]}"#, #"{"data":[]}"#),
            ("null", #"{"data":[],"nextCursor":null}"#, #"{"data":[],"nextCursor":null}"#),
        ]

        for (name, loadedPage, listedPage) in terminalCursorCases {
            let transport = ReviewFakeAppServerTransport(steps: [
                .response("initialize", result: supportedInitializeResult),
                .response("thread/loaded/list", result: loadedPage),
                .response("thread/list", result: listedPage),
            ])
            let source = AppServerSource(endpoint: endpoint, transport: transport, now: { self.fixedNow })

            let result = await source.poll(since: nil)
            let requests = await transport.recordedRequests()

            XCTAssertEqual(result.health, SourceHealth(status: .healthy), name)
            XCTAssertTrue(result.events.isEmpty, name)
            XCTAssertEqual(
                requests.map(\.method),
                ["initialize", "thread/loaded/list", "thread/list"],
                name
            )
        }
    }

    func testInventoryMapsDocumentedStatusesAndTreatsNotLoadedAsAHealthyClear() async {
        let rows = [
            listedThreadResult(id: "a-active", status: "active"),
            listedThreadResult(
                id: "b-approval",
                status: "active",
                activeFlags: ["waitingOnApproval"]
            ),
            listedThreadResult(
                id: "c-user",
                status: "active",
                activeFlags: ["waitingOnUserInput"]
            ),
            listedThreadResult(id: "d-idle", status: "idle"),
            listedThreadResult(id: "e-system-error", status: "systemError"),
            listedThreadResult(id: "f-not-loaded", status: "notLoaded"),
        ]
        let transport = ReviewFakeAppServerTransport(steps: [
            .response("initialize", result: supportedInitializeResult),
            .response("thread/loaded/list", result: #"{"data":[],"nextCursor":null}"#),
            .response("thread/list", result: pagedResult(rows: rows, nextCursor: nil)),
        ])
        let source = AppServerSource(endpoint: endpoint, transport: transport, now: { self.fixedNow })

        let result = await source.poll(since: nil)
        let requests = await transport.recordedRequests()

        XCTAssertEqual(result.health, SourceHealth(status: .healthy))
        XCTAssertEqual(
            result.events.map(\.sessionID),
            ["a-active", "b-approval", "c-user", "d-idle", "e-system-error"]
        )
        XCTAssertEqual(
            result.events.map(\.kind),
            [.modelActivity, .waitingForApproval, .waitingForUser, .completed, .failed]
        )
        XCTAssertFalse(result.events.contains { $0.sessionID == "f-not-loaded" })
        XCTAssertFalse(requests.contains { $0.method == "thread/resume" })
    }

    func testMalformedInventoryRowsAndStatusesDegradeWithoutFalseEvents() async {
        let malformedRows = [
            ("missing id", #"{"status":{"type":"active","activeFlags":[]}}"#),
            ("missing status", #"{"id":"malformed"}"#),
            ("missing type", #"{"id":"malformed","status":{"activeFlags":[]}}"#),
            ("active missing flags", #"{"id":"malformed","status":{"type":"active"}}"#),
            ("wrong flags type", #"{"id":"malformed","status":{"type":"active","activeFlags":"waitingOnApproval"}}"#),
            ("unknown flag", #"{"id":"malformed","status":{"type":"active","activeFlags":["unknownFlag"]}}"#),
            ("unknown type", #"{"id":"malformed","status":{"type":"mystery"}}"#),
        ]

        for (name, row) in malformedRows {
            let transport = ReviewFakeAppServerTransport(steps: [
                .response("initialize", result: supportedInitializeResult),
                .response("thread/loaded/list", result: #"{"data":[],"nextCursor":null}"#),
                .response("thread/list", result: pagedResult(rows: [row], nextCursor: nil)),
            ])
            let source = AppServerSource(endpoint: endpoint, transport: transport, now: { self.fixedNow })

            let result = await source.poll(since: nil)

            XCTAssertEqual(result.health.status, .degraded, name)
            XCTAssertEqual(result.health.issues, [.appServerProtocol(.malformedMessage)], name)
            XCTAssertTrue(result.events.isEmpty, name)
        }
    }

    func testStatusNotificationsMapTransitionsSuppressDuplicatesAndClearNotLoaded() async {
        let row = listedThreadResult(id: "transition", status: "active")
        let notifications = [
            threadStatusChanged(id: "transition", status: "active"),
            threadStatusChanged(id: "transition", status: "idle"),
            threadStatusChanged(id: "transition", status: "idle"),
            threadStatusChanged(id: "transition", status: "systemError"),
            threadStatusChanged(id: "transition", status: "systemError"),
            threadStatusChanged(id: "transition", status: "notLoaded"),
            threadStatusChanged(id: "transition", status: "active"),
        ]
        let transport = ReviewFakeAppServerTransport(
            steps: [
                .response("initialize", result: supportedInitializeResult),
                .response("thread/loaded/list", result: #"{"data":[],"nextCursor":null}"#),
                .response("thread/list", result: pagedResult(rows: [row], nextCursor: nil)),
            ],
            notificationBatches: [notifications]
        )
        let source = AppServerSource(endpoint: endpoint, transport: transport, now: { self.fixedNow })

        let result = await source.poll(since: nil)

        XCTAssertEqual(result.health, SourceHealth(status: .healthy))
        XCTAssertEqual(result.events.map(\.sessionID), Array(repeating: "transition", count: 4))
        XCTAssertEqual(result.events.map(\.kind), [.modelActivity, .completed, .failed, .modelActivity])
    }

    func testMalformedStatusNotificationsDegradeWithoutFalseEvents() async {
        let malformedNotifications = [
            threadStatusChangedRaw(threadID: nil, statusJSON: #"{"type":"active","activeFlags":[]}"#),
            threadStatusChangedRaw(threadID: "bad-status", statusJSON: nil),
            threadStatusChangedRaw(threadID: "bad-type", statusJSON: #"{"activeFlags":[]}"#),
            threadStatusChangedRaw(threadID: "bad-flags-missing", statusJSON: #"{"type":"active"}"#),
            threadStatusChangedRaw(threadID: "bad-flags-type", statusJSON: #"{"type":"active","activeFlags":"waitingOnApproval"}"#),
            threadStatusChangedRaw(threadID: "bad-flag", statusJSON: #"{"type":"active","activeFlags":["unknownFlag"]}"#),
            threadStatusChangedRaw(threadID: "bad-unknown", statusJSON: #"{"type":"mystery"}"#),
        ]
        let transport = ReviewFakeAppServerTransport(
            steps: [
                .response("initialize", result: supportedInitializeResult),
                .response("thread/loaded/list", result: #"{"data":[],"nextCursor":null}"#),
                .response("thread/list", result: #"{"data":[],"nextCursor":null}"#),
            ],
            notificationBatches: [malformedNotifications]
        )
        let source = AppServerSource(endpoint: endpoint, transport: transport, now: { self.fixedNow })

        let result = await source.poll(since: nil)

        XCTAssertEqual(result.health.status, .degraded)
        XCTAssertEqual(result.health.issues, [.appServerProtocol(.malformedMessage)])
        XCTAssertTrue(result.events.isEmpty)
    }

    func testItemKindsDoNotMasqueradeAsToolsAndContentIsDiscarded() async throws {
        let notifications = [
            itemStarted(id: "agent", type: "agentMessage", bodyKey: "text"),
            itemStarted(id: "reasoning", type: "reasoning", bodyKey: "summary"),
            itemStarted(id: "plan", type: "plan", bodyKey: "text"),
            itemStarted(id: "compact", type: "contextCompaction", bodyKey: "text"),
            itemStarted(id: "command", type: "commandExecution", bodyKey: "command", processID: 41),
            itemStarted(id: "mcp", type: "mcpToolCall", bodyKey: "arguments", processID: 42),
        ]
        let transport = ReviewFakeAppServerTransport(
            steps: [
                .response("initialize", result: supportedInitializeResult),
                .response("thread/loaded/list", result: #"{"data":[],"nextCursor":null}"#),
                .response("thread/list", result: #"{"data":[],"nextCursor":null}"#),
            ],
            notificationBatches: [notifications]
        )
        let source = AppServerSource(endpoint: endpoint, transport: transport, now: { self.fixedNow })

        let result = await source.poll(since: nil)
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)

        XCTAssertEqual(
            result.events.map(\.kind),
            [
                .modelActivity, .modelActivity, .modelActivity, .contextCompaction,
                .toolStarted(processID: 41), .toolStarted(processID: 42),
            ]
        )
        XCTAssertFalse(result.events.prefix(4).contains { event in
            if case .toolStarted = event.kind { return true }
            return false
        })
        XCTAssertFalse(encoded.contains("FIXTURE_REVIEW_BODY_MUST_BE_DROPPED"))
    }

    private var activeListResult: String {
        #"{"data":[{"id":"active-thread","status":{"type":"active","activeFlags":[]}}],"nextCursor":null}"#
    }

    private static let allDocumentedSourceKinds = [
        "cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview",
        "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown",
    ]
}

private actor RecordingReconnectSleeper {
    private var delays: [Int] = []
    func record(_ milliseconds: Int) { delays.append(milliseconds) }
    func recordedDelays() -> [Int] { delays }
}

private struct ReviewRequest: Sendable {
    let method: String
    let id: Int
    let payload: Data

    func stringParam(_ key: String) throws -> String {
        try XCTUnwrap(params()[key] as? String)
    }

    func stringArrayParam(_ key: String) throws -> [String] {
        try XCTUnwrap(params()[key] as? [String])
    }

    func boolParam(_ key: String) throws -> Bool {
        try XCTUnwrap(params()[key] as? Bool)
    }

    func intParam(_ key: String) throws -> Int {
        try XCTUnwrap(params()[key] as? Int)
    }

    func nestedBoolParam(_ key: String, in parent: String) throws -> Bool {
        let object = try XCTUnwrap(params()[parent] as? [String: Any])
        return try XCTUnwrap(object[key] as? Bool)
    }

    func paramKeys() throws -> Set<String> {
        Set(try params().keys)
    }

    private func params() throws -> [String: Any] {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
        return try XCTUnwrap(object["params"] as? [String: Any])
    }
}

private enum ReviewStep: @unchecked Sendable {
    case response(String, result: String)
    case failure(String, Error)
}

private actor ReviewFakeAppServerTransport: AppServerTransport {
    private var steps: [ReviewStep]
    private var notificationBatches: [[Data]]
    private var requests: [ReviewRequest] = []
    private var notifications: [Data] = []

    init(steps: [ReviewStep], notificationBatches: [[Data]] = []) {
        self.steps = steps
        self.notificationBatches = notificationBatches
    }

    func request(_ payload: Data, at endpoint: AppServerEndpoint) async throws -> Data {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
        let method = try XCTUnwrap(object["method"] as? String)
        let id = try XCTUnwrap((object["id"] as? NSNumber)?.intValue)
        requests.append(ReviewRequest(method: method, id: id, payload: payload))
        guard !steps.isEmpty else {
            throw ReviewFakeTransportFailure.unexpectedRequest(method)
        }
        let step = steps.removeFirst()
        switch step {
        case let .response(expectedMethod, result):
            XCTAssertEqual(method, expectedMethod)
            return Data("{\"id\":\(id),\"result\":\(result)}".utf8)
        case let .failure(expectedMethod, error):
            XCTAssertEqual(method, expectedMethod)
            throw error
        }
    }

    func notify(_ payload: Data, at endpoint: AppServerEndpoint) async throws {
        notifications.append(payload)
    }

    func drainNotifications(at endpoint: AppServerEndpoint) async throws -> [Data] {
        guard !notificationBatches.isEmpty else { return [] }
        return notificationBatches.removeFirst()
    }

    func recordedRequests() -> [ReviewRequest] { requests }
    func recordedNotifications() -> [Data] { notifications }
}

private enum ReviewFakeTransportFailure: Error {
    case unexpectedRequest(String)
}

private func resumedResult(_ threadID: String) -> String {
    "{\"thread\":{\"id\":\"\(threadID)\",\"status\":{\"type\":\"active\",\"activeFlags\":[]}}}"
}

private func listedThreadResult(
    id: String,
    status: String,
    activeFlags: [String] = []
) -> String {
    #"{"id":"\#(id)","status":\#(threadStatusJSON(type: status, activeFlags: activeFlags))}"#
}

private func pagedResult(rows: [String], nextCursor: String?) -> String {
    let cursor = nextCursor.map { #""\#($0)""# } ?? "null"
    return #"{"data":[\#(rows.joined(separator: ","))],"nextCursor":\#(cursor)}"#
}

private func threadStatusJSON(type: String, activeFlags: [String] = []) -> String {
    guard type == "active" else { return #"{"type":"\#(type)"}"# }
    let flags = activeFlags.map { #""\#($0)""# }.joined(separator: ",")
    return #"{"type":"active","activeFlags":[\#(flags)]}"#
}

private func threadStatusChanged(
    id: String,
    status: String,
    activeFlags: [String] = []
) -> Data {
    threadStatusChangedRaw(
        threadID: id,
        statusJSON: threadStatusJSON(type: status, activeFlags: activeFlags)
    )
}

private func threadStatusChangedRaw(threadID: String?, statusJSON: String?) -> Data {
    var fields: [String] = []
    if let threadID { fields.append(#""threadId":"\#(threadID)""#) }
    if let statusJSON { fields.append(#""status":\#(statusJSON)"#) }
    let json = #"{"method":"thread/status/changed","params":{\#(fields.joined(separator: ","))}}"#
    return Data(json.utf8)
}

private func itemStarted(
    id: String,
    type: String,
    bodyKey: String,
    processID: Int? = nil
) -> Data {
    let process = processID.map { ",\"processId\":\($0)" } ?? ""
    let json = "{\"method\":\"item/started\",\"params\":{\"threadId\":\"thread-items\","
        + "\"turnId\":\"turn-items\",\"item\":{\"id\":\"\(id)\",\"type\":\"\(type)\""
        + process + ",\"\(bodyKey)\":\"FIXTURE_REVIEW_BODY_MUST_BE_DROPPED\"}}}"
    return Data(json.utf8)
}
