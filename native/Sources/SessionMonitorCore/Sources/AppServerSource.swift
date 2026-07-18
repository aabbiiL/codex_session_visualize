import CryptoKit
import CoreFoundation
import Darwin
import Foundation

public protocol AppServerTransport: Sendable {
    func request(_ payload: Data, at endpoint: AppServerEndpoint) async throws -> Data
    func notify(_ payload: Data, at endpoint: AppServerEndpoint) async throws
    func drainNotifications(at endpoint: AppServerEndpoint) async throws -> [Data]
    func reset() async
}

public extension AppServerTransport {
    func reset() async {}
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
    private var fragmentedText: Data?
    private var queuedNotifications: [Data] = []
    private var queuedNotificationBytes = 0

    public init(
        streamFactory: any UnixSocketByteStreamFactory = DarwinUnixSocketByteStreamFactory()
    ) {
        self.streamFactory = streamFactory
        self.webSocketKeyGenerator = { @Sendable in Self.randomWebSocketKey() }
        self.maskKeyGenerator = { @Sendable in Self.randomMaskKey() }
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
        do {
            let requestID = try exactIntegerID(in: payload)
            try await ensureConnected(to: endpoint)
            try await sendText(payload)
            while true {
                guard let message = try await nextServerTextMessage(waitForData: true) else {
                    throw AppServerTransportFailure.connectionClosed
                }
                let envelope = try wireEnvelope(message)
                if envelope.method != nil, envelope.id == nil {
                    try enqueueNotification(message)
                    continue
                }
                guard envelope.id == requestID else {
                    throw AppServerTransportFailure.protocolViolation
                }
                return message
            }
        } catch {
            await resetConnection()
            throw error
        }
    }

    public func notify(_ payload: Data, at endpoint: AppServerEndpoint) async throws {
        do {
            try await ensureConnected(to: endpoint)
            try await sendText(payload)
        } catch {
            await resetConnection()
            throw error
        }
    }

    public func drainNotifications(at endpoint: AppServerEndpoint) async throws -> [Data] {
        do {
            try await ensureConnected(to: endpoint)
            var messages = queuedNotifications
            queuedNotifications.removeAll(keepingCapacity: true)
            queuedNotificationBytes = 0
            var totalBytes = messages.reduce(0) { $0 + $1.count }
            while messages.count < Self.maximumDrainedNotifications {
                guard let message = try await nextServerTextMessage(waitForData: false) else {
                    break
                }
                let envelope = try wireEnvelope(message)
                guard envelope.method != nil, envelope.id == nil else {
                    throw AppServerTransportFailure.protocolViolation
                }
                totalBytes += message.count
                guard totalBytes <= Self.maximumMessageBytes else {
                    throw AppServerTransportFailure.messageTooLarge
                }
                messages.append(message)
            }
            return messages
        } catch {
            await resetConnection()
            throw error
        }
    }

    public func reset() async {
        await resetConnection()
    }

    private func ensureConnected(to endpoint: AppServerEndpoint) async throws {
        if stream != nil, connectedEndpoint == endpoint {
            return
        }
        await resetConnection()

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
        try await sendFrame(opcode: 0x1, payload: payload)
    }

    private func sendFrame(opcode: UInt8, payload: Data) async throws {
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

        var frame = Data([0x80 | opcode])
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
            if let frame = try parseServerFrame() {
                switch frame.opcode {
                case 0x1:
                    guard fragmentedText == nil else {
                        throw AppServerTransportFailure.protocolViolation
                    }
                    if frame.final { return frame.payload }
                    fragmentedText = frame.payload
                case 0x0:
                    guard fragmentedText != nil else {
                        throw AppServerTransportFailure.protocolViolation
                    }
                    fragmentedText?.append(frame.payload)
                    guard (fragmentedText?.count ?? 0) <= Self.maximumMessageBytes else {
                        throw AppServerTransportFailure.messageTooLarge
                    }
                    if frame.final {
                        let message = fragmentedText
                        fragmentedText = nil
                        return message
                    }
                case 0x9:
                    try await sendFrame(opcode: 0xA, payload: frame.payload)
                case 0xA:
                    continue
                case 0x8:
                    await resetConnection()
                    throw AppServerTransportFailure.connectionClosed
                default:
                    throw AppServerTransportFailure.protocolViolation
                }
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

    private func parseServerFrame() throws -> WebSocketFrame? {
        guard inbound.count >= 2 else { return nil }
        let bytes = [UInt8](inbound)
        let first = bytes[0]
        let second = bytes[1]
        let final = first & 0x80 != 0
        let opcode = first & 0x0F
        guard first & 0x70 == 0, second & 0x80 == 0 else {
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
        if opcode >= 0x8, (!final || payloadLength > 125) {
            throw AppServerTransportFailure.protocolViolation
        }
        guard [0x0, 0x1, 0x8, 0x9, 0xA].contains(opcode) else {
            throw AppServerTransportFailure.protocolViolation
        }
        let totalLength = headerLength + Int(payloadLength)
        guard bytes.count >= totalLength else { return nil }
        let payload = Data(bytes[headerLength..<totalLength])
        inbound.removeFirst(totalLength)
        return WebSocketFrame(final: final, opcode: opcode, payload: payload)
    }

    private func exactIntegerID(in data: Data) throws -> Int {
        let envelope = try wireEnvelope(data)
        guard let id = envelope.id else {
            throw AppServerTransportFailure.protocolViolation
        }
        return id
    }

    private func wireEnvelope(_ data: Data) throws -> WireEnvelope {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppServerTransportFailure.protocolViolation
        }
        let method = object["method"] as? String
        let id: Int?
        if let rawID = object["id"] {
            guard let number = rawID as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !Self.isFloatingPointNumber(number),
                  number.int64Value >= Int64(Int.min),
                  number.int64Value <= Int64(Int.max) else {
                throw AppServerTransportFailure.protocolViolation
            }
            id = Int(number.int64Value)
        } else {
            id = nil
        }
        return WireEnvelope(method: method, id: id)
    }

    private static func isFloatingPointNumber(_ number: NSNumber) -> Bool {
        let type = String(cString: number.objCType)
        return type == "f" || type == "d"
    }

    private func enqueueNotification(_ data: Data) throws {
        guard queuedNotifications.count < Self.maximumDrainedNotifications,
              queuedNotificationBytes + data.count <= Self.maximumMessageBytes else {
            throw AppServerTransportFailure.messageTooLarge
        }
        queuedNotifications.append(data)
        queuedNotificationBytes += data.count
    }

    private func resetConnection() async {
        if let stream { await stream.close() }
        stream = nil
        connectedEndpoint = nil
        inbound.removeAll(keepingCapacity: false)
        fragmentedText = nil
        queuedNotifications.removeAll(keepingCapacity: false)
        queuedNotificationBytes = 0
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

private struct WebSocketFrame {
    let final: Bool
    let opcode: UInt8
    let payload: Data
}

private struct WireEnvelope {
    let method: String?
    let id: Int?
}

public protocol DarwinUnixSocketSyscalls: Sendable {
    func openConnectedUnixSocket(path: String) throws -> Int32
    func setSocketOption(
        descriptor: Int32,
        level: Int32,
        name: Int32,
        value: Int32
    ) throws
    func receive(descriptor: Int32, maxBytes: Int) throws -> Data
    func send(descriptor: Int32, data: Data) throws -> Int
    func close(descriptor: Int32)
}

public struct DarwinUnixSocketSystemCalls: DarwinUnixSocketSyscalls, Sendable {
    public init() {}

    public func openConnectedUnixSocket(path: String) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EMFILE) }
        do {
            try setSocketOption(
                descriptor: descriptor,
                level: SOL_SOCKET,
                name: SO_NOSIGPIPE,
                value: 1
            )
            var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
            guard Darwin.setsockopt(
                descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                socklen_t(MemoryLayout<timeval>.size)
            ) == 0,
            Darwin.setsockopt(
                descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                socklen_t(MemoryLayout<timeval>.size)
            ) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
            }

            var address = sockaddr_un()
            let pathBytes = Array(path.utf8CString)
            guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw POSIXError(.ENAMETOOLONG)
            }
            address.sun_family = sa_family_t(AF_UNIX)
            let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
            address.sun_len = UInt8(length)
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { target in
                    for (index, byte) in pathBytes.enumerated() { target[index] = byte }
                }
            }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, length)
                }
            }
            guard connected == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    public func setSocketOption(
        descriptor: Int32,
        level: Int32,
        name: Int32,
        value: Int32
    ) throws {
        var value = value
        guard Darwin.setsockopt(
            descriptor, level, name, &value, socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
    }

    public func receive(descriptor: Int32, maxBytes: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let count = buffer.withUnsafeMutableBytes {
            Darwin.recv(descriptor, $0.baseAddress, maxBytes, 0)
        }
        if count > 0 { return Data(buffer.prefix(count)) }
        if count == 0 { throw AppServerTransportFailure.connectionClosed }
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return Data() }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    public func send(descriptor: Int32, data: Data) throws -> Int {
        let count = data.withUnsafeBytes {
            Darwin.send(descriptor, $0.baseAddress, data.count, 0)
        }
        guard count >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return count
    }

    public func close(descriptor: Int32) { Darwin.close(descriptor) }
}

public struct DarwinUnixSocketByteStreamFactory: UnixSocketByteStreamFactory, Sendable {
    private let syscalls: any DarwinUnixSocketSyscalls

    public init(syscalls: any DarwinUnixSocketSyscalls = DarwinUnixSocketSystemCalls()) {
        self.syscalls = syscalls
    }

    public func open(socketURL: URL) async throws -> any UnixSocketByteStream {
        let descriptor = try syscalls.openConnectedUnixSocket(
            path: socketURL.standardizedFileURL.path
        )
        do {
            try syscalls.setSocketOption(
                descriptor: descriptor,
                level: SOL_SOCKET,
                name: SO_NOSIGPIPE,
                value: 1
            )
            return DarwinUnixSocketByteStream(descriptor: descriptor, syscalls: syscalls)
        } catch {
            syscalls.close(descriptor: descriptor)
            throw error
        }
    }
}

public final class DarwinUnixSocketByteStream: UnixSocketByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private let syscalls: any DarwinUnixSocketSyscalls
    private var descriptor: Int32

    init(descriptor: Int32, syscalls: any DarwinUnixSocketSyscalls) {
        self.descriptor = descriptor
        self.syscalls = syscalls
    }

    deinit { closeDescriptor() }

    public func read(maxBytes: Int) async throws -> Data {
        guard maxBytes > 0 else { return Data() }
        return try lock.withLock {
            guard descriptor >= 0 else { throw AppServerTransportFailure.connectionClosed }
            do {
                return try syscalls.receive(descriptor: descriptor, maxBytes: maxBytes)
            } catch let error as POSIXError where Self.isDisconnected(error.code) {
                throw AppServerTransportFailure.connectionClosed
            }
        }
    }

    public func write(_ data: Data) async throws {
        try lock.withLock {
            guard descriptor >= 0 else { throw AppServerTransportFailure.connectionClosed }
            var remaining = data
            while !remaining.isEmpty {
                do {
                    let written = try syscalls.send(descriptor: descriptor, data: remaining)
                    guard written > 0, written <= remaining.count else {
                        throw AppServerTransportFailure.connectionClosed
                    }
                    remaining.removeFirst(written)
                } catch let error as POSIXError where Self.isDisconnected(error.code) {
                    throw AppServerTransportFailure.connectionClosed
                }
            }
        }
    }

    public func close() async { lock.withLock { closeDescriptor() } }

    private func closeDescriptor() {
        if descriptor >= 0 {
            syscalls.close(descriptor: descriptor)
            descriptor = -1
        }
    }

    private static func isDisconnected(_ code: POSIXErrorCode) -> Bool {
        code == .EPIPE || code == .ECONNRESET || code == .ENOTCONN
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

public actor AppServerSource: EventSource {
    public static let supportedProtocolVersion = "2026-07-01"

    public nonisolated let id: EvidenceSource = .appServer
    private let endpoint: AppServerEndpoint?
    private let transport: any AppServerTransport
    private let diagnosticConnectionProbe: ConnectionProbe?
    private let reconnectBackoff: AppServerReconnectBackoff
    private let reconnectSleeper: @Sendable (Int) async -> Void
    private let now: @Sendable () -> Date
    private var initialized = false
    private var nextRequestID = 1
    private var subscribedThreadIDs = Set<String>()
    private var structuralSnapshot: [String: ObservedEvent.Kind] = [:]
    private var consecutiveFailures = 0

    private static let allSourceKinds = [
        "cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview",
        "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown",
    ]

    public init(
        endpoint: AppServerEndpoint?,
        transport: (any AppServerTransport)? = nil,
        diagnosticConnectionProbe: ConnectionProbe? = nil,
        reconnectBackoff: AppServerReconnectBackoff = AppServerReconnectBackoff(
            baseDelayMilliseconds: 250,
            maximumDelayMilliseconds: 2_000
        ),
        reconnectSleeper: @escaping @Sendable (Int) async -> Void = { milliseconds in
            guard milliseconds > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoint = endpoint
        self.transport = transport ?? UnixWebSocketAppServerTransport()
        self.diagnosticConnectionProbe = diagnosticConnectionProbe
        self.reconnectBackoff = reconnectBackoff
        self.reconnectSleeper = reconnectSleeper
        self.now = now
    }

    public func poll(since cursor: SourceCursor?) async -> SourcePollResult {
        guard let endpoint else {
            return SourcePollResult(health: SourceHealth(status: .unavailable))
        }
        do {
            if consecutiveFailures > 0 {
                await reconnectSleeper(
                    reconnectBackoff.delayMilliseconds(
                        afterFailureCount: consecutiveFailures
                    )
                )
            }
            try await initializeIfNeeded(endpoint: endpoint)
            let loadedThreadIDs = try await loadedThreads(endpoint: endpoint)
            for threadID in loadedThreadIDs where !subscribedThreadIDs.contains(threadID) {
                _ = try await request(
                    method: "thread/resume",
                    params: ["threadId": threadID],
                    endpoint: endpoint
                )
                subscribedThreadIDs.insert(threadID)
            }

            let threads = try await listedThreads(endpoint: endpoint)
            let observedAt = now()
            let currentSnapshot = snapshotKinds(threads)
            var events = currentSnapshot.compactMap { sessionID, kind -> RawSourceEvent? in
                guard structuralSnapshot[sessionID] != kind else { return nil }
                return rawEvent(
                    sessionID: sessionID,
                    turnID: nil,
                    itemID: nil,
                    kind: kind,
                    observedAt: observedAt
                )
            }.sorted { $0.sessionID < $1.sessionID }
            structuralSnapshot = currentSnapshot
            var malformed = false
            for data in try await transport.drainNotifications(at: endpoint) {
                do {
                    if let event = try eventFromNotification(data, observedAt: observedAt) {
                        events.append(event)
                        if event.turnID == nil, event.itemID == nil {
                            structuralSnapshot[event.sessionID] = event.kind
                        }
                    }
                } catch {
                    malformed = true
                }
            }
            consecutiveFailures = 0
            return SourcePollResult(
                events: events,
                health: SourceHealth(
                    status: malformed ? .degraded : .healthy,
                    issues: malformed ? [.appServerProtocol(.malformedMessage)] : []
                )
            )
        } catch {
            await resetAfterFailure()
            if case AppServerSourceFailure.responseIDMismatch = error {
                return unavailable(issue: .appServerProtocol(.responseIDMismatch))
            }
            if case AppServerSourceFailure.unsupportedVersion = error {
                return unavailable(issue: .appServerProtocol(.unsupportedVersion))
            }
            if case AppServerSourceFailure.malformedMessage = error {
                return unavailable(issue: .appServerProtocol(.malformedMessage))
            }
            return unavailable(issue: .appServerProtocol(.transportViolation))
        }
    }

    private func initializeIfNeeded(endpoint: AppServerEndpoint) async throws {
        guard !initialized else { return }
        let result = try await request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "codex-session-monitor",
                    "version": "1.0",
                ],
            ],
            endpoint: endpoint
        )
        if let version = result["protocolVersion"],
           !(version is NSNull),
           (version as? String) != Self.supportedProtocolVersion {
            throw AppServerSourceFailure.unsupportedVersion
        }
        try await transport.notify(
            wireMessage(method: "initialized", id: nil, params: [:]),
            at: endpoint
        )
        initialized = true
    }

    private func loadedThreads(endpoint: AppServerEndpoint) async throws -> [String] {
        var cursor: String?
        var result: [String] = []
        repeat {
            var params: [String: Any] = ["limit": 100]
            if let cursor { params["cursor"] = cursor }
            let page = try await request(
                method: "thread/loaded/list",
                params: params,
                endpoint: endpoint
            )
            if let ids = page["data"] as? [String] { result.append(contentsOf: ids) }
            cursor = page["nextCursor"] as? String
        } while cursor != nil
        return result
    }

    private func listedThreads(endpoint: AppServerEndpoint) async throws -> [[String: Any]] {
        var cursor: String?
        var result: [[String: Any]] = []
        repeat {
            var params: [String: Any] = [
                "limit": 100,
                "sourceKinds": Self.allSourceKinds,
            ]
            if let cursor { params["cursor"] = cursor }
            let page = try await request(
                method: "thread/list",
                params: params,
                endpoint: endpoint
            )
            if let threads = page["data"] as? [[String: Any]] {
                result.append(contentsOf: threads)
            }
            cursor = page["nextCursor"] as? String
        } while cursor != nil
        return result
    }

    private func request(
        method: String,
        params: [String: Any],
        endpoint: AppServerEndpoint
    ) async throws -> [String: Any] {
        let requestID = nextRequestID
        nextRequestID += 1
        let response = try await transport.request(
            wireMessage(method: method, id: requestID, params: params),
            at: endpoint
        )
        return try responseResult(response, expectedID: requestID)
    }

    private func resetAfterFailure() async {
        await transport.reset()
        initialized = false
        nextRequestID = 1
        subscribedThreadIDs.removeAll(keepingCapacity: false)
        consecutiveFailures = min(consecutiveFailures + 1, 30)
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
              let number = object["id"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !Self.isFloatingPointNumber(number),
              number.int64Value >= Int64(Int.min),
              number.int64Value <= Int64(Int.max) else {
            throw AppServerSourceFailure.malformedMessage
        }
        let responseID = Int(number.int64Value)
        guard responseID == expectedID else {
            throw AppServerSourceFailure.responseIDMismatch
        }
        guard let result = object["result"] as? [String: Any] else {
            throw AppServerSourceFailure.malformedMessage
        }
        return result
    }

    private static func isFloatingPointNumber(_ number: NSNumber) -> Bool {
        let type = String(cString: number.objCType)
        return type == "f" || type == "d"
    }

    private func snapshotKinds(
        _ threads: [[String: Any]]
    ) -> [String: ObservedEvent.Kind] {
        Dictionary(uniqueKeysWithValues: threads.compactMap { thread in
            guard let sessionID = thread["id"] as? String,
                  let status = thread["status"] as? [String: Any],
                  let kind = kindFromThreadStatus(status) else {
                return nil
            }
            return (sessionID, kind)
        })
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
            let kind: ObservedEvent.Kind
            switch itemType {
            case "commandExecution", "mcpToolCall":
                kind = method == "item/started"
                    ? .toolStarted(processID: processID)
                    : .modelActivity
            case "agentMessage", "reasoning", "plan":
                kind = .modelActivity
            case "contextCompaction":
                kind = .contextCompaction
            default:
                return nil
            }
            return rawEvent(
                sessionID: sessionID,
                turnID: turnID,
                itemID: itemID,
                kind: kind,
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
    case unsupportedVersion
}
