import Foundation
import XCTest
@testable import SessionMonitorCore

final class AppServerReviewRegressionTests: XCTestCase {
    private let endpoint = AppServerEndpoint.unixWebSocket(
        socketURL: URL(fileURLWithPath: "/tmp/scrubbed-app-server.sock"),
        requestPath: "/"
    )
    private let fixedNow = Date(timeIntervalSince1970: 1_784_332_800)

    func testConnectionInitializesOnceAcrossPollsThenEOFBacksOffAndReinitializes() async throws {
        let transport = ReviewFakeAppServerTransport(steps: [
            .response("initialize", result: #"{"protocolVersion":"2026-07-01"}"#),
            .response("thread/loaded/list", result: #"{"data":[],"nextCursor":null}"#),
            .response("thread/list", result: activeListResult),
            .response("thread/loaded/list", result: #"{"data":[],"nextCursor":null}"#),
            .response("thread/list", result: activeListResult),
            .failure("thread/loaded/list", AppServerTransportFailure.connectionClosed),
            .failure("initialize", AppServerTransportFailure.connectionClosed),
            .failure("initialize", AppServerTransportFailure.connectionClosed),
            .response("initialize", result: #"{"protocolVersion":"2026-07-01"}"#),
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

    func testLoadedThreadsAreResumedOnceAndThreadInventoryPaginatesAllSourceKinds() async throws {
        let transport = ReviewFakeAppServerTransport(steps: [
            .response("initialize", result: #"{"protocolVersion":"2026-07-01"}"#),
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
        XCTAssertEqual(try requests[2].stringParam("threadId"), "loaded-a")
        XCTAssertEqual(try requests[3].stringParam("threadId"), "loaded-b")
        XCTAssertEqual(try requests[5].stringParam("cursor"), "page-2")
        XCTAssertEqual(
            Set(try requests[4].stringArrayParam("sourceKinds")),
            Set(Self.allDocumentedSourceKinds)
        )
        XCTAssertFalse(requests.contains { ["thread/start", "thread/restart", "turn/start"].contains($0.method) })
        XCTAssertEqual(requests.filter { $0.method == "thread/resume" }.count, 2, "Subscriptions are per connection")
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
                .response("initialize", result: #"{"protocolVersion":"2026-07-01"}"#),
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

    func notify(_ payload: Data, at endpoint: AppServerEndpoint) async throws {}

    func drainNotifications(at endpoint: AppServerEndpoint) async throws -> [Data] {
        guard !notificationBatches.isEmpty else { return [] }
        return notificationBatches.removeFirst()
    }

    func recordedRequests() -> [ReviewRequest] { requests }
}

private func resumedResult(_ threadID: String) -> String {
    "{\"thread\":{\"id\":\"\(threadID)\",\"status\":{\"type\":\"active\",\"activeFlags\":[]},\"turns\":[]}}"
}

private func itemStarted(
    id: String,
    type: String,
    bodyKey: String,
    processID: Int? = nil
) -> Data {
    let process = processID.map { ",\"processId\":\($0)" } ?? ""
    return Data(
        "{\"method\":\"item/started\",\"params\":{\"threadId\":\"thread-items\","
            + "\"turnId\":\"turn-items\",\"item\":{\"id\":\"\(id)\",\"type\":\"\(type)\""
            + process + ",\"\(bodyKey)\":\"FIXTURE_REVIEW_BODY_MUST_BE_DROPPED\"}}}".utf8
    )
}
