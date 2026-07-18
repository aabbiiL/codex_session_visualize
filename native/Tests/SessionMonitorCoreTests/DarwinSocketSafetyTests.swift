import Darwin
import Foundation
import XCTest
@testable import SessionMonitorCore

final class DarwinSocketSafetyTests: XCTestCase {
    func testFactorySetsNoSigPipeAndEPIPEBecomesReconnectableClosure() async throws {
        let syscalls = RecordingDarwinUnixSocketSyscalls(sendError: POSIXError(.EPIPE))
        let factory = DarwinUnixSocketByteStreamFactory(syscalls: syscalls)
        let stream = try await factory.open(
            socketURL: URL(fileURLWithPath: "/tmp/scrubbed-app-server.sock")
        )

        let options = syscalls.recordedOptions()
        XCTAssertTrue(options.contains(
            SocketOption(level: SOL_SOCKET, name: SO_NOSIGPIPE, value: 1)
        ))
        do {
            try await stream.write(Data("bounded".utf8))
            XCTFail("Expected disconnected peer write to be reconnectable")
        } catch {
            XCTAssertEqual(error as? AppServerTransportFailure, .connectionClosed)
        }
    }
}

private struct SocketOption: Hashable {
    let level: Int32
    let name: Int32
    let value: Int32
}

private final class RecordingDarwinUnixSocketSyscalls: DarwinUnixSocketSyscalls, @unchecked Sendable {
    private let lock = NSLock()
    private let sendError: Error
    private var options: [SocketOption] = []

    init(sendError: Error) { self.sendError = sendError }

    func openConnectedUnixSocket(path: String) throws -> Int32 { 42 }

    func setSocketOption(
        descriptor: Int32,
        level: Int32,
        name: Int32,
        value: Int32
    ) throws {
        lock.withLock { options.append(SocketOption(level: level, name: name, value: value)) }
    }

    func receive(descriptor: Int32, maxBytes: Int) throws -> Data { Data() }
    func send(descriptor: Int32, data: Data) throws -> Int { throw sendError }
    func close(descriptor: Int32) {}

    func recordedOptions() -> [SocketOption] { lock.withLock { options } }
}
