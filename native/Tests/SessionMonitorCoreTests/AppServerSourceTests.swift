import Darwin
import Foundation
import XCTest
@testable import SessionMonitorCore

final class AppServerSourceTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_784_332_800)

    func testDiscoveryUsesOnlyExplicitOrFirstBoundedDocumentedUnixSocketCandidate() throws {
        let socket = try BoundUnixSocketFixture()
        defer { socket.remove() }
        let regularFile = socket.directoryURL.appendingPathComponent("not-a-socket")
        try Data().write(to: regularFile)
        let missingCandidates = (0..<AppServerEndpointDiscovery.maximumDocumentedCandidates)
            .map { socket.directoryURL.appendingPathComponent("missing-\($0).sock") }

        let beyondBound = AppServerEndpointDiscovery(
            explicitSocketURL: nil,
            documentedSocketCandidates: missingCandidates + [socket.socketURL]
        ).discover()
        let regularFileResult = AppServerEndpointDiscovery(
            explicitSocketURL: nil,
            documentedSocketCandidates: [regularFile]
        ).discover()
        let explicit = AppServerEndpointDiscovery(
            explicitSocketURL: socket.socketURL,
            documentedSocketCandidates: missingCandidates
        ).discover()

        XCTAssertNil(beyondBound, "Discovery must not scan beyond its documented candidate bound")
        XCTAssertNil(regularFileResult, "A path is attachable only when it is a Unix socket")
        XCTAssertEqual(
            explicit,
            .unixWebSocket(socketURL: socket.socketURL.standardizedFileURL, requestPath: "/")
        )
    }

    func testPollInitializesListsThreadsAndMapsStructuredNotificationsWithoutContent() async throws {
        let frames = try appServerFixtureFrames()
        let transport = FakeAppServerTransport(
            responses: Array(frames.prefix(2)),
            notifications: Array(frames.dropFirst(2))
        )
        let runner = RecordingConnectionRunner(
            output: "codex 1 user 1u IPv4 0 TCP 127.0.0.1:1->203.0.113.4:443 (ESTABLISHED)"
        )
        let endpoint = AppServerEndpoint.unixWebSocket(
            socketURL: URL(fileURLWithPath: "/tmp/scrubbed-app-server.sock"),
            requestPath: "/"
        )
        let source = AppServerSource(
            endpoint: endpoint,
            transport: transport,
            diagnosticConnectionProbe: ConnectionProbe(runner: runner),
            now: { self.fixedNow }
        )

        let result = await source.poll(since: nil)
        let exchange = await transport.snapshot()
        let connectionProbeCallCount = await runner.callCount()

        XCTAssertEqual(source.id, .appServer)
        XCTAssertEqual(result.health, SourceHealth(status: .healthy))
        XCTAssertEqual(exchange.requests.count, 2)
        XCTAssertEqual(try methodAndID(in: exchange.requests[0]), WireCall(method: "initialize", id: 1))
        XCTAssertEqual(try methodAndID(in: exchange.requests[1]), WireCall(method: "thread/list", id: 2))
        XCTAssertEqual(exchange.notifications.count, 1)
        XCTAssertEqual(
            try methodAndID(in: exchange.notifications[0]),
            WireCall(method: "initialized", id: nil)
        )
        XCTAssertTrue((exchange.requests + exchange.notifications).allSatisfy { data in
            guard let object = try? jsonObject(data) else { return false }
            return object["jsonrpc"] == nil
        }, "Codex App Server JSON-RPC omits jsonrpc on the wire")
        XCTAssertTrue(exchange.endpoints.allSatisfy { $0 == endpoint })

        XCTAssertEqual(
            result.events.map(\.kind),
            [
                .modelActivity,
                .waitingForApproval,
                .waitingForUser,
                .turnStarted,
                .toolStarted(processID: 4242),
                .modelActivity,
                .completed,
                .interrupted,
                .failed,
                .toolStarted(processID: 5252),
                .modelActivity,
            ]
        )
        XCTAssertTrue(result.events.allSatisfy { $0.source == .appServer })
        XCTAssertTrue(result.events.allSatisfy { $0.eventTime == fixedNow })
        XCTAssertEqual(result.events.first?.sessionID, "thread-from-list")

        let commandStart = try XCTUnwrap(result.events.first { $0.itemID == "command-1" && $0.kind == .toolStarted(processID: 4242) })
        XCTAssertEqual(commandStart.toolName, "commandExecution")
        let commandCompletion = try XCTUnwrap(result.events.first { $0.itemID == "command-1" && $0.kind == .modelActivity })
        XCTAssertEqual(commandCompletion.durationMilliseconds, 1_250)
        let toolStart = try XCTUnwrap(result.events.first { $0.itemID == "tool-1" && $0.kind == .toolStarted(processID: 5252) })
        XCTAssertEqual(toolStart.toolName, "mcpToolCall")

        let encodedData = try JSONEncoder().encode(result)
        let encoded = String(decoding: encodedData, as: UTF8.self)
        for forbidden in [
            "FIXTURE_APP_SERVER_COMMAND_BODY_SHOULD_BE_DROPPED",
            "FIXTURE_APP_SERVER_COMMAND_OUTPUT_SHOULD_BE_DROPPED",
            "FIXTURE_APP_SERVER_TURN_OUTPUT_SHOULD_BE_DROPPED",
            "FIXTURE_APP_SERVER_ERROR_BODY_SHOULD_BE_DROPPED",
            "FIXTURE_APP_SERVER_TOOL_ARGUMENTS_SHOULD_BE_DROPPED",
            "FIXTURE_APP_SERVER_TOOL_OUTPUT_SHOULD_BE_DROPPED",
        ] {
            XCTAssertFalse(encoded.contains(forbidden), "Retained forbidden App Server content")
        }
        let serialized = try JSONSerialization.jsonObject(with: encodedData)
        XCTAssertFalse(containsJSONKey("body", in: serialized))
        XCTAssertFalse(containsJSONKey("output", in: serialized))
        XCTAssertEqual(connectionProbeCallCount, 0, "Normal EventSource polling must never invoke lsof")
    }

    func testMissingEndpointIsOptionalUnavailableAndDoesNotEmitFailure() async {
        let transport = FakeAppServerTransport(responses: [], notifications: [])
        let source = AppServerSource(
            endpoint: nil,
            transport: transport,
            now: { self.fixedNow }
        )

        let optionalResult = await source.poll(since: nil)
        let independentHealthySource = SourcePollResult(health: SourceHealth(status: .healthy))
        let exchange = await transport.snapshot()

        XCTAssertEqual(optionalResult.health.status, .unavailable)
        XCTAssertTrue(optionalResult.events.isEmpty)
        XCTAssertFalse(optionalResult.events.contains { $0.kind == .failed })
        XCTAssertEqual(independentHealthySource.health.status, .healthy)
        XCTAssertEqual(exchange.requests.count, 0)
    }

    func testEveryResponseIDMustExactlyMatchItsRequest() async {
        for mismatch in [
            ([initializeResponse(id: 99), listResponse(id: 2)], 1),
            ([initializeResponse(id: 1), listResponse(id: 99)], 2),
        ] {
            let source = AppServerSource(
                endpoint: .unixWebSocket(
                    socketURL: URL(fileURLWithPath: "/tmp/scrubbed-app-server.sock"),
                    requestPath: "/"
                ),
                transport: FakeAppServerTransport(
                    responses: mismatch.0,
                    notifications: []
                ),
                now: { self.fixedNow }
            )

            let result = await source.poll(since: nil)

            XCTAssertEqual(result.health.status, .unavailable)
            XCTAssertEqual(result.health.issues, [.appServerProtocol(.responseIDMismatch)])
            XCTAssertTrue(result.events.isEmpty, "Mismatched response \(mismatch.1) must be rejected")
        }
    }

    func testUnsupportedProtocolVersionIsUnavailableWithTypedDoctorIssue() async {
        let source = AppServerSource(
            endpoint: .unixWebSocket(
                socketURL: URL(fileURLWithPath: "/tmp/scrubbed-app-server.sock"),
                requestPath: "/"
            ),
            transport: FakeAppServerTransport(
                responses: [initializeResponse(id: 1, version: "999.0")],
                notifications: []
            ),
            now: { self.fixedNow }
        )

        let result = await source.poll(since: nil)

        XCTAssertEqual(result.health.status, .unavailable)
        XCTAssertEqual(result.health.issues, [.appServerProtocol(.unsupportedVersion)])
        XCTAssertTrue(result.events.isEmpty)
    }

    func testReconnectBackoffIsDeterministicAndCapped() {
        let backoff = AppServerReconnectBackoff(
            baseDelayMilliseconds: 250,
            maximumDelayMilliseconds: 2_000
        )

        XCTAssertEqual(
            (0...6).map { backoff.delayMilliseconds(afterFailureCount: $0) },
            [0, 250, 500, 1_000, 2_000, 2_000, 2_000]
        )
    }
}

private actor FakeAppServerTransport: AppServerTransport {
    private var responses: [Data]
    private let scriptedNotifications: [Data]
    private var requests: [Data] = []
    private var sentNotifications: [Data] = []
    private var endpoints: [AppServerEndpoint] = []

    init(responses: [Data], notifications: [Data]) {
        self.responses = responses
        self.scriptedNotifications = notifications
    }

    func request(_ payload: Data, at endpoint: AppServerEndpoint) async throws -> Data {
        requests.append(payload)
        endpoints.append(endpoint)
        guard !responses.isEmpty else { throw FakeTransportError.noResponse }
        return responses.removeFirst()
    }

    func notify(_ payload: Data, at endpoint: AppServerEndpoint) async throws {
        sentNotifications.append(payload)
        endpoints.append(endpoint)
    }

    func drainNotifications(at endpoint: AppServerEndpoint) async throws -> [Data] {
        endpoints.append(endpoint)
        return scriptedNotifications
    }

    func snapshot() -> TransportSnapshot {
        TransportSnapshot(
            requests: requests,
            notifications: sentNotifications,
            endpoints: endpoints
        )
    }
}

private enum FakeTransportError: Error { case noResponse }

private struct TransportSnapshot: Sendable {
    let requests: [Data]
    let notifications: [Data]
    let endpoints: [AppServerEndpoint]
}

private struct WireCall: Equatable {
    let method: String
    let id: Int?
}

private func methodAndID(in data: Data) throws -> WireCall {
    let object = try jsonObject(data)
    return WireCall(method: try XCTUnwrap(object["method"] as? String), id: object["id"] as? Int)
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func initializeResponse(id: Int, version: String = "2026-07-01") -> Data {
    Data("{\"id\":\(id),\"result\":{\"protocolVersion\":\"\(version)\"}}".utf8)
}

private func listResponse(id: Int) -> Data {
    Data("{\"id\":\(id),\"result\":{\"data\":[],\"nextCursor\":null}}".utf8)
}

private func appServerFixtureFrames() throws -> [Data] {
    let url = try XCTUnwrap(
        Bundle.module.url(
            forResource: "app-server-events",
            withExtension: "jsonl",
            subdirectory: "Fixtures"
        ) ?? Bundle.module.url(forResource: "app-server-events", withExtension: "jsonl")
    )
    return try String(contentsOf: url, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .map { Data($0.utf8) }
}

private func containsJSONKey(_ key: String, in value: Any) -> Bool {
    if let object = value as? [String: Any] {
        return object.keys.contains(key) || object.values.contains { containsJSONKey(key, in: $0) }
    }
    if let array = value as? [Any] {
        return array.contains { containsJSONKey(key, in: $0) }
    }
    return false
}

private final class BoundUnixSocketFixture {
    let directoryURL: URL
    let socketURL: URL
    private let descriptor: Int32

    init() throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        directoryURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("csm-as-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        socketURL = directoryURL.appendingPathComponent("app-server.sock")
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENFILE) }

        var address = sockaddr_un()
        let pathBytes = Array(socketURL.path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        address.sun_len = UInt8(length)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destination in
                for (index, byte) in pathBytes.enumerated() { destination[index] = byte }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, length)
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
    }

    func remove() {
        Darwin.close(descriptor)
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
