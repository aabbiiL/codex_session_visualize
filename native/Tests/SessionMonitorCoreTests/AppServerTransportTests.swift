import Foundation
import XCTest
@testable import SessionMonitorCore

final class AppServerTransportTests: XCTestCase {
    func testUnixWebSocketTransportUpgradesFramesAndReusesOneConnectionForSourceHandshake() async throws {
        let initializeResponse = Data(
            "{\"id\":1,\"result\":{\"protocolVersion\":\"2026-07-01\"}}".utf8
        )
        let threadListResponse = Data(
            "{\"id\":2,\"result\":{\"data\":[],\"nextCursor\":null}}".utf8
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
        XCTAssertEqual(writes.count, 4, "Expected one HTTP upgrade and three WebSocket messages")

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
        XCTAssertEqual(
            try wireMethodAndID(clientMessages[2]),
            WireMessage(method: "thread/list", id: 2)
        )
        for message in clientMessages {
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: message) as? [String: Any]
            )
            XCTAssertNil(object["jsonrpc"], "Codex App Server omits jsonrpc on the wire")
        }
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
