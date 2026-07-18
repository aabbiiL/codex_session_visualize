import Foundation
import XCTest
@testable import SessionMonitorCore

final class AppServerTransportTests: XCTestCase {
    func testUnixWebSocketTransportUpgradesFramesAndReusesOneConnectionForSourceHandshake() async throws {
        let initializeResponse = Data(
            "{\"id\":1,\"result\":{\"protocolVersion\":\"2026-07-01\"}}".utf8
        )
        let threadListResponse = Data(
            "{\"id\":3,\"result\":{\"data\":[],\"nextCursor\":null}}".utf8
        )
        let stream = ScriptedUnixSocketByteStream(reads: [
            Data(
                [
                    "HTTP/1.1 101 Switching Protocols\r\n",
                    "Upgrade: websocket\r\n",
                    "Connection: Upgrade\r\n",
                    "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n",
                    "\r\n",
                ].joined().utf8
            ),
            serverTextFrame(initializeResponse),
            serverTextFrame(Data("{\"id\":2,\"result\":{\"data\":[],\"nextCursor\":null}}".utf8)),
            serverTextFrame(threadListResponse),
            Data(),
        ])
        let factory = RecordingUnixSocketByteStreamFactory(stream: stream)
        let transport = UnixWebSocketAppServerTransport(
            streamFactory: factory,
            webSocketKeyGenerator: { "dGhlIHNhbXBsZSBub25jZQ==" },
            maskKeyGenerator: { [0x37, 0xFA, 0x21, 0x3D] }
        )
        let endpoint = AppServerEndpoint.unixWebSocket(
            socketURL: URL(fileURLWithPath: "/tmp/scrubbed-app-server.sock"),
            requestPath: "/codex-app-server"
        )
        let source = AppServerSource(
            endpoint: endpoint,
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_784_332_800) }
        )

        let result = await source.poll(since: nil)
        let connectionCount = await factory.connectionCount()
        let writes = await stream.recordedWrites()

        XCTAssertEqual(result.health, SourceHealth(status: .healthy))
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(connectionCount, 1, "One upgraded stream must serve the full source handshake")
        XCTAssertEqual(writes.count, 5, "Expected one HTTP upgrade and four WebSocket messages")

        let upgrade = String(decoding: writes[0], as: UTF8.self)
        XCTAssertTrue(upgrade.hasPrefix("GET /codex-app-server HTTP/1.1\r\n"))
        XCTAssertTrue(upgrade.contains("Upgrade: websocket\r\n"))
        XCTAssertTrue(upgrade.contains("Connection: Upgrade\r\n"))
        XCTAssertTrue(upgrade.contains("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"))
        XCTAssertTrue(upgrade.contains("Sec-WebSocket-Version: 13\r\n"))
        XCTAssertTrue(upgrade.hasSuffix("\r\n\r\n"))

        let clientMessages = try writes.dropFirst().map(decodeMaskedClientTextFrame)
        XCTAssertEqual(
            try wireMethodAndID(clientMessages[0]),
            WireMessage(method: "initialize", id: 1)
        )
        XCTAssertEqual(
            try wireMethodAndID(clientMessages[1]),
            WireMessage(method: "initialized", id: nil)
        )
        XCTAssertEqual(try wireMethodAndID(clientMessages[2]), WireMessage(method: "thread/loaded/list", id: 2))
        XCTAssertEqual(try wireMethodAndID(clientMessages[3]), WireMessage(method: "thread/list", id: 3))
        for message in clientMessages {
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: message) as? [String: Any]
            )
            XCTAssertNil(object["jsonrpc"], "Codex App Server omits jsonrpc on the wire")
        }
    }

    func testNotificationBeforeResponseIsQueuedWhileExactResponseIsReturned() async throws {
        let notification = Data(
            #"{"method":"thread/status/changed","params":{"threadId":"interleaved","status":{"type":"active","activeFlags":[]}}}"#.utf8
        )
        let response = Data(#"{"id":1,"result":{"ok":true}}"#.utf8)
        let stream = ScriptedUnixSocketByteStream(reads: [
            upgradeResponse(), serverTextFrame(notification), serverTextFrame(response), Data(),
        ])
        let transport = makeTransport(factory: RecordingUnixSocketByteStreamFactory(stream: stream))
        let endpoint = transportEndpoint()

        let returned = try await transport.request(
            Data(#"{"id":1,"method":"fixture/request","params":{}}"#.utf8),
            at: endpoint
        )
        let queued = try await transport.drainNotifications(at: endpoint)

        XCTAssertEqual(returned, response)
        XCTAssertEqual(queued, [notification])
    }

    func testDifferentIDServerRequestIsDiscardedWithoutPoisoningClientResponses() async throws {
        try await assertInterleavedServerRequestIsDiscarded(serverRequestID: 77)
    }

    func testCollidingIDServerRequestIsDiscardedWithoutBecomingClientResponse() async throws {
        try await assertInterleavedServerRequestIsDiscarded(serverRequestID: 1)
    }

    func testMatchingErrorResponseThrowsTypedContentFreeErrorWithoutResettingConnection() async throws {
        let secretMessage = "FIXTURE_ERR_SECRET"
        let secretData = "FIXTURE_ERR_DATA"
        let errorJSON = "{\"id\":1,\"error\":{\"code\":-32603,"
            + "\"message\":\"\(secretMessage)\",\"data\":\"\(secretData)\"}}"
        let errorResponse = Data(errorJSON.utf8)
        let secondResponse = Data(#"{"id":2,"result":{"ok":true}}"#.utf8)
        let stream = ScriptedUnixSocketByteStream(reads: [
            upgradeResponse(), serverTextFrame(errorResponse), serverTextFrame(secondResponse), Data(),
        ])
        let factory = RecordingUnixSocketByteStreamFactory(stream: stream)
        let transport = makeTransport(factory: factory)
        let endpoint = transportEndpoint()
        var caught: AppServerTransportFailure?

        do {
            _ = try await transport.request(
                Data(#"{"id":1,"method":"fixture/request","params":{}}"#.utf8),
                at: endpoint
            )
            XCTFail("A matching JSON-RPC error envelope must not be returned as a success response")
        } catch let error as AppServerTransportFailure {
            caught = error
        }

        let returned = try await transport.request(
            Data(#"{"id":2,"method":"fixture/request","params":{}}"#.utf8),
            at: endpoint
        )
        let retainedDescription = String(describing: caught)
        let connectionCount = await factory.connectionCount()

        XCTAssertEqual(caught, .serverError(code: -32603))
        XCTAssertEqual(returned, secondResponse)
        XCTAssertEqual(connectionCount, 1, "A server error is not a transport reset")
        XCTAssertFalse(retainedDescription.contains(secretMessage))
        XCTAssertFalse(retainedDescription.contains(secretData))
    }

    func testResponseIDsRejectBooleanFractionalAndStringLookalikes() async throws {
        for invalidID in ["true", "1.5", "\"1\""] {
            let stream = ScriptedUnixSocketByteStream(reads: [
                upgradeResponse(),
                serverTextFrame(Data("{\"id\":\(invalidID),\"result\":{}}".utf8)),
            ])
            let transport = makeTransport(
                factory: RecordingUnixSocketByteStreamFactory(stream: stream)
            )

            do {
                _ = try await transport.request(
                    Data(#"{"id":1,"method":"fixture/request","params":{}}"#.utf8),
                    at: transportEndpoint()
                )
                XCTFail("Expected exact integer response ID rejection for \(invalidID)")
            } catch {
                XCTAssertEqual(error as? AppServerTransportFailure, .protocolViolation)
            }
        }
    }

    func testPingBeforeResponseSendsMaskedPongAndFragmentedTextIsReassembled() async throws {
        let response = Data(#"{"id":1,"result":{"ok":true}}"#.utf8)
        let split = response.count / 2
        let stream = ScriptedUnixSocketByteStream(reads: [
            upgradeResponse(),
            serverFrame(opcode: 0x9, final: true, payload: Data("ping".utf8)),
            serverFrame(opcode: 0x1, final: false, payload: response.prefix(split)),
            serverFrame(opcode: 0x0, final: true, payload: response.dropFirst(split)),
        ])
        let transport = makeTransport(factory: RecordingUnixSocketByteStreamFactory(stream: stream))

        let returned = try await transport.request(
            Data(#"{"id":1,"method":"fixture/request","params":{}}"#.utf8),
            at: transportEndpoint()
        )
        let writes = await stream.recordedWrites()
        let pong = try decodeMaskedClientFrame(writes[2])

        XCTAssertEqual(returned, response)
        XCTAssertEqual(pong.opcode, 0xA)
        XCTAssertEqual(pong.payload, Data("ping".utf8))
    }

    func testCloseFrameInvalidatesStreamAndNextRequestReconnects() async throws {
        let first = ScriptedUnixSocketByteStream(reads: [
            upgradeResponse(), serverFrame(opcode: 0x8, final: true, payload: Data()),
        ])
        let expected = Data(#"{"id":2,"result":{"ok":true}}"#.utf8)
        let second = ScriptedUnixSocketByteStream(reads: [
            upgradeResponse(), serverTextFrame(expected),
        ])
        let factory = SequencedUnixSocketByteStreamFactory(streams: [first, second])
        let transport = makeTransport(factory: factory)

        do {
            _ = try await transport.request(
                Data(#"{"id":1,"method":"fixture/request","params":{}}"#.utf8),
                at: transportEndpoint()
            )
            XCTFail("Expected close frame to end the first connection")
        } catch {
            XCTAssertEqual(error as? AppServerTransportFailure, .connectionClosed)
        }
        let returned = try await transport.request(
            Data(#"{"id":2,"method":"fixture/request","params":{}}"#.utf8),
            at: transportEndpoint()
        )
        let connectionCount = await factory.connectionCount()

        XCTAssertEqual(returned, expected)
        XCTAssertEqual(connectionCount, 2)
    }


    private func assertInterleavedServerRequestIsDiscarded(serverRequestID: Int) async throws {
        let secret = "FIXTURE_REQ_SECRET"
        let serverRequestJSON = "{\"id\":\(serverRequestID),\"method\":\"server/request\","
            + "\"params\":{\"secret\":\"\(secret)\"}}"
        let serverRequest = Data(serverRequestJSON.utf8)
        let firstResponse = Data(#"{"id":1,"result":{"sequence":1}}"#.utf8)
        let secondResponse = Data(#"{"id":2,"result":{"sequence":2}}"#.utf8)
        let stream = ScriptedUnixSocketByteStream(reads: [
            upgradeResponse(), serverTextFrame(serverRequest),
            serverTextFrame(firstResponse), serverTextFrame(secondResponse), Data(),
        ])
        let factory = RecordingUnixSocketByteStreamFactory(stream: stream)
        let transport = makeTransport(factory: factory)
        let endpoint = transportEndpoint()

        let first = try await transport.request(
            Data(#"{"id":1,"method":"fixture/first","params":{}}"#.utf8),
            at: endpoint
        )
        let second = try await transport.request(
            Data(#"{"id":2,"method":"fixture/second","params":{}}"#.utf8),
            at: endpoint
        )
        let queued = try await transport.drainNotifications(at: endpoint)
        let connectionCount = await factory.connectionCount()
        var retained = Data()
        retained.append(first)
        retained.append(second)
        queued.forEach { retained.append($0) }
        let externallyRetained = String(decoding: retained, as: UTF8.self)

        XCTAssertEqual(first, firstResponse)
        XCTAssertEqual(second, secondResponse)
        XCTAssertTrue(queued.isEmpty, "Server requests must not enter the notification queue")
        XCTAssertEqual(connectionCount, 1)
        XCTAssertFalse(externallyRetained.contains(secret))
    }
}

private actor ScriptedUnixSocketByteStream: UnixSocketByteStream {
    private var reads: [Data]
    private var writes: [Data] = []

    init(reads: [Data]) {
        self.reads = reads
    }

    func read(maxBytes: Int) async throws -> Data {
        guard !reads.isEmpty else { return Data() }
        let next = reads.removeFirst()
        guard next.count > maxBytes else { return next }
        let prefix = next.prefix(maxBytes)
        reads.insert(Data(next.dropFirst(maxBytes)), at: 0)
        return Data(prefix)
    }

    func write(_ data: Data) async throws {
        writes.append(data)
    }

    func close() async {}

    func recordedWrites() -> [Data] { writes }
}

private actor RecordingUnixSocketByteStreamFactory: UnixSocketByteStreamFactory {
    private let stream: ScriptedUnixSocketByteStream
    private var openedSocketURLs: [URL] = []

    init(stream: ScriptedUnixSocketByteStream) {
        self.stream = stream
    }

    func open(socketURL: URL) async throws -> any UnixSocketByteStream {
        openedSocketURLs.append(socketURL)
        return stream
    }

    func connectionCount() -> Int { openedSocketURLs.count }
}

private actor SequencedUnixSocketByteStreamFactory: UnixSocketByteStreamFactory {
    private var streams: [ScriptedUnixSocketByteStream]
    private var connections = 0

    init(streams: [ScriptedUnixSocketByteStream]) { self.streams = streams }

    func open(socketURL: URL) async throws -> any UnixSocketByteStream {
        connections += 1
        return streams.removeFirst()
    }

    func connectionCount() -> Int { connections }
}

private struct WireMessage: Equatable {
    let method: String
    let id: Int?
}

private func wireMethodAndID(_ data: Data) throws -> WireMessage {
    let object = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    return WireMessage(
        method: try XCTUnwrap(object["method"] as? String),
        id: object["id"] as? Int
    )
}

private func serverTextFrame(_ payload: Data) -> Data {
    precondition(payload.count < 126)
    var frame = Data([0x81, UInt8(payload.count)])
    frame.append(payload)
    return frame
}

private func serverFrame<T: DataProtocol>(opcode: UInt8, final: Bool, payload: T) -> Data {
    let data = Data(payload)
    precondition(data.count < 126)
    var frame = Data([(final ? 0x80 : 0x00) | opcode, UInt8(data.count)])
    frame.append(data)
    return frame
}

private struct DecodedClientFrame {
    let opcode: UInt8
    let payload: Data
}

private func decodeMaskedClientFrame(_ frame: Data) throws -> DecodedClientFrame {
    let bytes = [UInt8](frame)
    XCTAssertGreaterThanOrEqual(bytes.count, 6)
    XCTAssertNotEqual(bytes[1] & 0x80, 0)
    let length = Int(bytes[1] & 0x7F)
    XCTAssertLessThan(length, 126)
    let mask = Array(bytes[2..<6])
    let payload = Data((0..<length).map { bytes[6 + $0] ^ mask[$0 % 4] })
    return DecodedClientFrame(opcode: bytes[0] & 0x0F, payload: payload)
}

private func upgradeResponse() -> Data {
    Data(
        [
            "HTTP/1.1 101 Switching Protocols\r\n",
            "Upgrade: websocket\r\n",
            "Connection: Upgrade\r\n",
            "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n",
            "\r\n",
        ].joined().utf8
    )
}

private func transportEndpoint() -> AppServerEndpoint {
    .unixWebSocket(
        socketURL: URL(fileURLWithPath: "/tmp/scrubbed-app-server.sock"),
        requestPath: "/"
    )
}

private func makeTransport(
    factory: any UnixSocketByteStreamFactory
) -> UnixWebSocketAppServerTransport {
    UnixWebSocketAppServerTransport(
        streamFactory: factory,
        webSocketKeyGenerator: { "dGhlIHNhbXBsZSBub25jZQ==" },
        maskKeyGenerator: { [0x37, 0xFA, 0x21, 0x3D] }
    )
}

private func decodeMaskedClientTextFrame(_ frame: Data) throws -> Data {
    let bytes = [UInt8](frame)
    XCTAssertGreaterThanOrEqual(bytes.count, 6)
    XCTAssertEqual(bytes[0], 0x81, "Client message must be a final text frame")
    XCTAssertNotEqual(bytes[1] & 0x80, 0, "RFC 6455 requires client frames to be masked")

    var cursor = 2
    let shortLength = Int(bytes[1] & 0x7F)
    let payloadLength: Int
    if shortLength == 126 {
        XCTAssertGreaterThanOrEqual(bytes.count, 8)
        payloadLength = (Int(bytes[2]) << 8) | Int(bytes[3])
        cursor = 4
    } else {
        XCTAssertLessThan(shortLength, 126)
        payloadLength = shortLength
    }
    let mask = Array(bytes[cursor..<(cursor + 4)])
    cursor += 4
    XCTAssertEqual(bytes.count, cursor + payloadLength)

    return Data((0..<payloadLength).map { index in
        bytes[cursor + index] ^ mask[index % 4]
    })
}
