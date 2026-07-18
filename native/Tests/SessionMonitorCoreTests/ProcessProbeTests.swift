import Darwin
import Foundation
import XCTest
@testable import SessionMonitorCore

final class ProcessProbeTests: XCTestCase {
    func testDarwinProcessProbeReportsCurrentProcessAliveAndNonexistentPIDDead() {
        let probe = DarwinProcessProbe()

        XCTAssertTrue(probe.isAlive(pid: Int32(getpid())))
        XCTAssertFalse(probe.isAlive(pid: 2_000_000_000))
    }

    func testDarwinProcessProbeTreatsPermissionDeniedAsAlive() {
        let probe = DarwinProcessProbe(
            syscalls: StubProcessSyscalls(result: -1, errorNumber: EPERM)
        )

        XCTAssertTrue(probe.isAlive(pid: 42))
    }

    func testConnectionProbeRunsLsofOnlyOnExplicitInspectionWithTwoSecondCap() async throws {
        let localAddress = "127.0.0.1:58395"
        let remoteAddress = "203.0.113.7:443"
        let runner = RecordingConnectionRunner(
            output: "codex 123 user 12u IPv4 0 TCP \(localAddress)->\(remoteAddress) (ESTABLISHED)"
        )
        let probe = ConnectionProbe(runner: runner)

        let initialCallCount = await runner.callCount()
        XCTAssertEqual(initialCallCount, 0)
        let result = await probe.inspect(processID: 123)
        let calls = await runner.recordedCalls()

        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.executableURL.path, "/usr/sbin/lsof")
        XCTAssertEqual(call.arguments, ["-nP", "-a", "-p", "123", "-iTCP", "-iUDP"])
        XCTAssertLessThanOrEqual(call.timeoutSeconds, 2.0)
        XCTAssertEqual(
            result,
            ConnectionProbeResult(
                processID: 123,
                connections: [ConnectionMetadata(transport: .tcp, state: .established)]
            )
        )

        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(encoded.contains(localAddress), "Connection evidence must not persist local addresses")
        XCTAssertFalse(encoded.contains(remoteAddress), "Connection evidence must not persist remote addresses")
    }
}

private struct StubProcessSyscalls: DarwinProcessSyscalls {
    let result: Int32
    let errorNumber: Int32

    func kill(_ pid: Int32, _ signal: Int32) -> Int32 { result }
}

actor RecordingConnectionRunner: ConnectionProbeCommandRunning {
    struct Call: Sendable {
        let executableURL: URL
        let arguments: [String]
        let timeoutSeconds: TimeInterval
    }

    private let output: String
    private var calls: [Call] = []

    init(output: String) {
        self.output = output
    }

    func run(
        executableURL: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) async -> ConnectionProbeCommandResult {
        calls.append(
            Call(
                executableURL: executableURL,
                arguments: arguments,
                timeoutSeconds: timeoutSeconds
            )
        )
        return ConnectionProbeCommandResult(exitCode: 0, standardOutput: output)
    }

    func callCount() -> Int { calls.count }
    func recordedCalls() -> [Call] { calls }
}
