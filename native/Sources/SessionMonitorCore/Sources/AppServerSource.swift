import CryptoKit
import Darwin
import Foundation

public protocol AppServerTransport: Sendable {
    func request(_ payload: Data, at endpoint: AppServerEndpoint) async throws -> Data
    func notify(_ payload: Data, at endpoint: AppServerEndpoint) async throws
    func drainNotifications(at endpoint: AppServerEndpoint) async throws -> [Data]
}

public protocol UnixSocketByteStream: Sendable {
    func read(maxBytes: Int) async throws -> Data
    func write(_ data: Data) async throws
    func close() async
}

public protocol UnixSocketByteStreamFactory: Sendable {
    func open(socketURL: URL) async throws -> any UnixSocketByteStream
}

public enum AppServerTransportFailure: Error, Hashable, Sendable {
    case invalidEndpoint
    case socketUnavailable
    case ioFailure(Int32)
    case upgradeRejected
    case invalidUpgradeAccept
    case connectionClosed
    case malformedFrame
    case protocolViolation
    case messageTooLarge
}

public actor UnixWebSocketAppServerTransport: AppServerTransport {
    public static let maximumMessageBytes = 4_194_304
    public static let maximumDrainedNotifications = 64

    private let streamFactory: any UnixSocketByteStreamFactory
    private let webSocketKeyGenerator: @Sendable () -> String
    private let maskKeyGenerator: @Sendable () -> [UInt8]
    private var stream: (any UnixSocketByteStream)?
    private var connectedEndpoint: AppServerEndpoint?
    private var inbound = Data()

    public init(
        streamFactory: any UnixSocketByteStreamFactory = DarwinUnixSocketByteStreamFactory()
    ) {
        self.streamFactory = streamFactory
        self.webSocketKeyGenerator = Self.randomWebSocketKey
        self.maskKeyGenerator = Self.randomMaskKey
    }

    public init(
        streamFactory: any UnixSocketByteStreamFactory,
        webSocketKeyGenerator: @escaping @Sendable () -> String,
        maskKeyGenerator: @escaping @Sendable () -> [UInt8]
    ) {
        self.streamFactory = streamFactory
        self.webSocketKeyGenerator = webSocketKeyGenerator
        self.maskKeyGenerator = maskKeyGenerator
    }

    public func request(_ payload: Data, at endpoint: AppServerEndpoint) async throws -> Data {
        try await ensureConnected(to: endpoint)
        try await sendText(payload)
        guard let response = try await nextServerTextMessage(waitForData: true) else {
            throw AppServerTransportFailure.connectionClosed
        }
        return response
    }

    public func notify(_ payload: Data, at endpoint: AppServerEndpoint) async throws {
        try await ensureConnected(to: endpoint)
        try await sendText(payload)
    }

    public func drainNotifications(at endpoint: AppServerEndpoint) async throws -> [Data] {
        try await ensureConnected(to: endpoint)
        var messages: [Data] = []
        var totalBytes = 0
        while messages.count < Self.maximumDrainedNotifications {
            guard let message = try await nextServerTextMessage(waitForData: false) else {
                break
            }
            totalBytes += message.count
            guard totalBytes <= Self.maximumMessageBytes else {
                throw AppServerTransportFailure.messageTooLarge
            }
            messages.append(message)
        }
        return messages
    }

    private func ensureConnected(to endpoint: AppServerEndpoint) async throws {
        if stream != nil, connectedEndpoint == endpoint {
            return
        }
        if let stream {
            await stream.close()
        }
        stream = nil
        connectedEndpoint = nil
        inbound.removeAll(keepingCapacity: false)

        guard case let .unixWebSocket(socketURL, requestPath) = endpoint,
              requestPath.hasPrefix("/") else {
            throw AppServerTransportFailure.invalidEndpoint
        }
        let opened = try await streamFactory.open(socketURL: socketURL)
        stream = opened

        let key = webSocketKeyGenerator()
        let request = [
            "GET \(requestPath) HTTP/1.1\r\n",
            "Host: localhost\r\n",
            "Upgrade: websocket\r\n",
            "Connection: Upgrade\r\n",
            "Sec-WebSocket-Key: \(key)\r\n",
            "Sec-WebSocket-Version: 13\r\n",
            "\r\n",
        ].joined()
        try await opened.write(Data(request.utf8))
        try await validateUpgrade(on: opened, key: key)
        connectedEndpoint = endpoint
    }

    private func validateUpgrade(
        on stream: any UnixSocketByteStream,
        key: String
    ) async throws {
        let delimiter = Data("\r\n\r\n".utf8)
        var emptyReads = 0
        while inbound.range(of: delimiter) == nil {
            guard inbound.count <= 65_536 else {
                throw AppServerTransportFailure.upgradeRejected
            }
            let chunk = try await stream.read(maxBytes: 16_384)
            if chunk.isEmpty {
                emptyReads += 1
                if emptyReads >= 20 {
                    throw AppServerTransportFailure.connectionClosed
                }
            } else {
                emptyReads = 0
                inbound.append(chunk)
            }
        }

        guard let delimiterRange = inbound.range(of: delimiter) else {
            throw AppServerTransportFailure.upgradeRejected
        }
        let headerData = inbound[..<delimiterRange.lowerBound]
        inbound.removeSubrange(..<delimiterRange.upperBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw AppServerTransportFailure.upgradeRejected
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard lines.first?.contains(" 101 ") == true else {
            throw AppServerTransportFailure.upgradeRejected
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                headers[String(parts[0]).lowercased()] = parts[1]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard headers["upgrade"]?.lowercased() == "websocket",
              headers["connection"]?.lowercased().split(separator: ",").contains(
                where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }
              ) == true else {
            throw AppServerTransportFailure.upgradeRejected
        }
        guard headers["sec-websocket-accept"] == expectedAccept(for: key) else {
            throw AppServerTransportFailure.invalidUpgradeAccept
        }
    }

    private func sendText(_ payload: Data) async throws {
        guard payload.count <= Self.maximumMessageBytes else {
            throw AppServerTransportFailure.messageTooLarge
        }
        guard let stream else {
            throw AppServerTransportFailure.connectionClosed
        }
        let mask = maskKeyGenerator()
        guard mask.count == 4 else {
            throw AppServerTransportFailure.protocolViolation
        }

        var frame = Data([0x81])
        if payload.count < 126 {
            frame.append(UInt8(payload.count) | 0x80)
        } else if payload.count <= Int(UInt16.max) {
            frame.append(126 | 0x80)
            let length = UInt16(payload.count).bigEndian
            withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        } else {
            frame.append(127 | 0x80)
            let length = UInt64(payload.count).bigEndian
            withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        }
        frame.append(contentsOf: mask)
        for (index, byte) in payload.enumerated() {
            frame.append(byte ^ mask[index % 4])
        }
        try await stream.write(frame)
    }

    private func nextServerTextMessage(waitForData: Bool) async throws -> Data? {
        guard let stream else {
            throw AppServerTransportFailure.connectionClosed
        }
        var emptyReads = 0
        while true {
            if let message = try parseServerTextFrame() {
                return message
            }
            let chunk = try await stream.read(maxBytes: 65_536)
            if chunk.isEmpty {
                if !waitForData { return nil }
                emptyReads += 1
                if emptyReads >= 20 {
                    throw AppServerTransportFailure.connectionClosed
                }
            } else {
                emptyReads = 0
                inbound.append(chunk)
                guard inbound.count <= Self.maximumMessageBytes + 14 else {
                    throw AppServerTransportFailure.messageTooLarge
                }
            }
        }
    }

    private func parseServerTextFrame() throws -> Data? {
        guard inbound.count >= 2 else { return nil }
        let bytes = [UInt8](inbound)
        let first = bytes[0]
        let second = bytes[1]
        guard first & 0x80 != 0,
              first & 0x70 == 0,
              first & 0x0F == 0x01,
              second & 0x80 == 0 else {
            throw AppServerTransportFailure.protocolViolation
        }

        var headerLength = 2
        let shortLength = Int(second & 0x7F)
        let payloadLength: UInt64
        if shortLength < 126 {
            payloadLength = UInt64(shortLength)
        } else if shortLength == 126 {
            guard bytes.count >= 4 else { return nil }
            payloadLength = (UInt64(bytes[2]) << 8) | UInt64(bytes[3])
            headerLength = 4
        } else {
            guard bytes.count >= 10 else { return nil }
            guard bytes[2] & 0x80 == 0 else {
                throw AppServerTransportFailure.malformedFrame
            }
            payloadLength = bytes[2..<10].reduce(UInt64(0)) {
                ($0 << 8) | UInt64($1)
            }
            headerLength = 10
        }
        guard payloadLength <= UInt64(Self.maximumMessageBytes) else {
            throw AppServerTransportFailure.messageTooLarge
        }
        let totalLength = headerLength + Int(payloadLength)
        guard bytes.count >= totalLength else { return nil }
        let payload = Data(bytes[headerLength..<totalLength])
        inbound.removeFirst(totalLength)
        return payload
    }

    private func expectedAccept(for key: String) -> String {
        let value = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        return Data(Insecure.SHA1.hash(data: value)).base64EncodedString()
    }

    private static func randomWebSocketKey() -> String {
        Data((0..<16).map { _ in UInt8.random(in: UInt8.min ... UInt8.max) })
            .base64EncodedString()
    }

    private static func randomMaskKey() -> [UInt8] {
        (0..<4).map { _ in UInt8.random(in: UInt8.min ... UInt8.max) }
    }
}

public struct DarwinUnixSocketByteStreamFactory: UnixSocketByteStreamFactory, Sendable {
    public init() {}

    public func open(socketURL: URL) async throws -> any UnixSocketByteStream {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw AppServerTransportFailure.socketUnavailable
        }

        var address = sockaddr_un()
        let pathBytes = Array(socketURL.standardizedFileURL.path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor)
            throw AppServerTransportFailure.invalidEndpoint
        }
        address.sun_family = sa_family_t(AF_UNIX)
        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        address.sun_len = UInt8(length)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { target in
                for (index, byte) in pathBytes.enumerated() {
                    target[index] = byte
                }
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, length)
            }
        }
        guard connectResult == 0 else {
            let error = errno
            Darwin.close(descriptor)
            throw AppServerTransportFailure.ioFailure(error)
        }

        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_SNDTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        return DarwinUnixSocketByteStream(descriptor: descriptor)
    }
}

public final class DarwinUnixSocketByteStream: UnixSocketByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        closeDescriptor()
    }

    public func read(maxBytes: Int) async throws -> Data {
        guard maxBytes > 0 else { return Data() }
        return try lock.withLock {
            guard descriptor >= 0 else {
                throw AppServerTransportFailure.connectionClosed
            }
            var buffer = [UInt8](repeating: 0, count: maxBytes)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.recv(descriptor, $0.baseAddress, maxBytes, 0)
            }
            if count > 0 {
                return Data(buffer.prefix(count))
            }
            if count == 0 {
                throw AppServerTransportFailure.connectionClosed
            }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                return Data()
            }
            throw AppServerTransportFailure.ioFailure(errno)
        }
    }

    public func write(_ data: Data) async throws {
        try lock.withLock {
            guard descriptor >= 0 else {
                throw AppServerTransportFailure.connectionClosed
            }
            var written = 0
            try data.withUnsafeBytes { rawBuffer in
                while written < data.count {
                    let count = Darwin.send(
                        descriptor,
                        rawBuffer.baseAddress?.advanced(by: written),
                        data.count - written,
                        0
                    )
                    if count > 0 {
                        written += count
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        throw AppServerTransportFailure.ioFailure(errno)
                    }
                }
            }
        }
    }

    public func close() async {
        lock.withLock { closeDescriptor() }
    }

    private func closeDescriptor() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }
}

public struct AppServerReconnectBackoff: Hashable, Sendable {
    public let baseDelayMilliseconds: Int
    public let maximumDelayMilliseconds: Int

    public init(baseDelayMilliseconds: Int, maximumDelayMilliseconds: Int) {
        self.baseDelayMilliseconds = max(0, baseDelayMilliseconds)
        self.maximumDelayMilliseconds = max(0, maximumDelayMilliseconds)
    }

    public func delayMilliseconds(afterFailureCount failureCount: Int) -> Int {
        guard failureCount > 0 else { return 0 }
        var delay = min(baseDelayMilliseconds, maximumDelayMilliseconds)
        for _ in 1..<failureCount {
            if delay >= maximumDelayMilliseconds { return maximumDelayMilliseconds }
            let doubled = delay.multipliedReportingOverflow(by: 2)
            if doubled.overflow { return maximumDelayMilliseconds }
            delay = min(maximumDelayMilliseconds, doubled.partialValue)
        }
        return delay
    }
}

public struct AppServerSource: EventSource {
    public static let supportedProtocolVersion = "2026-07-01"

    public let id: EvidenceSource = .appServer
    private let endpoint: AppServerEndpoint?
    private let transport: any AppServerTransport
    private let diagnosticConnectionProbe: ConnectionProbe?
    private let now: @Sendable () -> Date

    public init(
        endpoint: AppServerEndpoint?,
        transport: (any AppServerTransport)? = nil,
        diagnosticConnectionProbe: ConnectionProbe? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoint = endpoint
        self.transport = transport ?? UnixWebSocketAppServerTransport()
        self.diagnosticConnectionProbe = diagnosticConnectionProbe
        self.now = now
    }

    public func poll(since cursor: SourceCursor?) async -> SourcePollResult {
        guard let endpoint else {
            return SourcePollResult(health: SourceHealth(status: .unavailable))
        }
        do {
            let initialize = try wireMessage(
                method: "initialize",
                id: 1,
                params: [
                    "clientInfo": [
                        "name": "codex-session-monitor",
                        "version": "1.0",
                    ],
                ]
            )
            let initializeResponse = try await transport.request(initialize, at: endpoint)
            let initializeResult = try responseResult(initializeResponse, expectedID: 1)
            if let version = initializeResult["protocolVersion"],
               !(version is NSNull),
               (version as? String) != Self.supportedProtocolVersion {
                return unavailable(issue: .appServerProtocol(.unsupportedVersion))
            }

            try await transport.notify(
                wireMessage(method: "initialized", id: nil, params: [:]),
                at: endpoint
            )
            let listResponse = try await transport.request(
                wireMessage(method: "thread/list", id: 2, params: ["limit": 100]),
                at: endpoint
            )
            let listResult = try responseResult(listResponse, expectedID: 2)
            let observedAt = now()
            var events = eventsFromThreadList(listResult, observedAt: observedAt)
            var malformed = false
            for data in try await transport.drainNotifications(at: endpoint) {
                do {
                    if let event = try eventFromNotification(data, observedAt: observedAt) {
                        events.append(event)
                    }
                } catch {
                    malformed = true
                }
            }
            return SourcePollResult(
                events: events,
                health: SourceHealth(
                    status: malformed ? .degraded : .healthy,
                    issues: malformed ? [.appServerProtocol(.malformedMessage)] : []
                )
            )
        } catch AppServerSourceFailure.responseIDMismatch {
            return unavailable(issue: .appServerProtocol(.responseIDMismatch))
        } catch AppServerSourceFailure.malformedMessage {
            return unavailable(issue: .appServerProtocol(.malformedMessage))
        } catch {
            return unavailable(issue: .appServerProtocol(.transportViolation))
        }
    }

    private func unavailable(issue: SourceIssue) -> SourcePollResult {
        SourcePollResult(
            health: SourceHealth(status: .unavailable, issues: [issue])
        )
    }

    private func wireMessage(
        method: String,
        id: Int?,
        params: [String: Any]
    ) throws -> Data {
        var object: [String: Any] = ["method": method, "params": params]
        if let id { object["id"] = id }
        guard JSONSerialization.isValidJSONObject(object) else {
            throw AppServerSourceFailure.malformedMessage
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func responseResult(_ data: Data, expectedID: Int) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseID = (object["id"] as? NSNumber)?.intValue else {
            throw AppServerSourceFailure.malformedMessage
        }
        guard responseID == expectedID else {
            throw AppServerSourceFailure.responseIDMismatch
        }
        guard let result = object["result"] as? [String: Any] else {
            throw AppServerSourceFailure.malformedMessage
        }
        return result
    }

    private func eventsFromThreadList(
        _ result: [String: Any],
        observedAt: Date
    ) -> [RawSourceEvent] {
        guard let threads = result["data"] as? [[String: Any]] else { return [] }
        return threads.compactMap { thread in
            guard let sessionID = thread["id"] as? String,
                  let status = thread["status"] as? [String: Any],
                  let kind = kindFromThreadStatus(status) else {
                return nil
            }
            return rawEvent(
                sessionID: sessionID,
                turnID: nil,
                itemID: nil,
                kind: kind,
                observedAt: observedAt
            )
        }
    }

    private func eventFromNotification(
        _ data: Data,
        observedAt: Date
    ) throws -> RawSourceEvent? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String,
              let params = object["params"] as? [String: Any] else {
            throw AppServerSourceFailure.malformedMessage
        }

        switch method {
        case "thread/status/changed":
            guard let sessionID = params["threadId"] as? String,
                  let status = params["status"] as? [String: Any],
                  let kind = kindFromThreadStatus(status) else {
                throw AppServerSourceFailure.malformedMessage
            }
            return rawEvent(
                sessionID: sessionID,
                turnID: nil,
                itemID: nil,
                kind: kind,
                observedAt: observedAt
            )
        case "turn/started":
            guard let sessionID = params["threadId"] as? String,
                  let turn = params["turn"] as? [String: Any],
                  let turnID = turn["id"] as? String else {
                throw AppServerSourceFailure.malformedMessage
            }
            return rawEvent(
                sessionID: sessionID,
                turnID: turnID,
                itemID: nil,
                kind: .turnStarted,
                observedAt: observedAt
            )
        case "turn/completed":
            guard let sessionID = params["threadId"] as? String,
                  let turn = params["turn"] as? [String: Any],
                  let turnID = turn["id"] as? String,
                  let status = turn["status"] as? String,
                  let kind = terminalKind(status) else {
                throw AppServerSourceFailure.malformedMessage
            }
            return rawEvent(
                sessionID: sessionID,
                turnID: turnID,
                itemID: nil,
                kind: kind,
                observedAt: observedAt
            )
        case "item/started", "item/completed":
            guard let sessionID = params["threadId"] as? String,
                  let turnID = params["turnId"] as? String,
                  let item = params["item"] as? [String: Any],
                  let itemID = item["id"] as? String,
                  let itemType = item["type"] as? String else {
                throw AppServerSourceFailure.malformedMessage
            }
            let processID = (item["processId"] as? NSNumber).flatMap { value -> Int32? in
                let processID = value.int64Value
                guard processID >= Int64(Int32.min), processID <= Int64(Int32.max) else {
                    return nil
                }
                return Int32(processID)
            }
            let duration = (item["durationMs"] as? NSNumber)?.intValue
            return rawEvent(
                sessionID: sessionID,
                turnID: turnID,
                itemID: itemID,
                kind: method == "item/started"
                    ? .toolStarted(processID: processID)
                    : .modelActivity,
                observedAt: observedAt,
                toolName: whitelistedToolType(itemType),
                durationMilliseconds: duration
            )
        default:
            return nil
        }
    }

    private func kindFromThreadStatus(_ status: [String: Any]) -> ObservedEvent.Kind? {
        guard status["type"] as? String == "active" else { return nil }
        let flags = Set(status["activeFlags"] as? [String] ?? [])
        if flags.contains("waitingOnApproval")
            || (status["waitingOnApproval"] as? Bool) == true {
            return .waitingForApproval
        }
        if flags.contains("waitingOnUserInput")
            || (status["waitingOnUserInput"] as? Bool) == true {
            return .waitingForUser
        }
        return .modelActivity
    }

    private func terminalKind(_ status: String) -> ObservedEvent.Kind? {
        switch status {
        case "completed": return .completed
        case "interrupted": return .interrupted
        case "failed": return .failed
        default: return nil
        }
    }

    private func whitelistedToolType(_ type: String) -> String? {
        switch type {
        case "commandExecution", "mcpToolCall": return type
        default: return nil
        }
    }

    private func rawEvent(
        sessionID: String,
        turnID: String?,
        itemID: String?,
        kind: ObservedEvent.Kind,
        observedAt: Date,
        toolName: String? = nil,
        durationMilliseconds: Int? = nil
    ) -> RawSourceEvent {
        RawSourceEvent(
            sessionID: sessionID,
            turnID: turnID,
            itemID: itemID,
            kind: kind,
            eventTime: observedAt,
            observedAt: observedAt,
            source: .appServer,
            toolName: toolName,
            durationMilliseconds: durationMilliseconds
        )
    }
}

private enum AppServerSourceFailure: Error {
    case responseIDMismatch
    case malformedMessage
}
