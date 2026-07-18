import Darwin
import Foundation

public struct ConnectionProbeCommandResult: Hashable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String

    public init(exitCode: Int32, standardOutput: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
    }
}

public protocol ConnectionProbeCommandRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) async -> ConnectionProbeCommandResult
}

public enum ConnectionTransport: String, Codable, Hashable, Sendable {
    case tcp
    case udp
}

public enum ConnectionState: String, Codable, Hashable, Sendable {
    case established
    case listening
    case unknown
}

public struct ConnectionMetadata: Codable, Hashable, Sendable {
    public let transport: ConnectionTransport
    public let state: ConnectionState

    public init(transport: ConnectionTransport, state: ConnectionState) {
        self.transport = transport
        self.state = state
    }
}

public struct ConnectionProbeResult: Codable, Hashable, Sendable {
    public let processID: Int32
    public let connections: [ConnectionMetadata]

    public init(processID: Int32, connections: [ConnectionMetadata]) {
        self.processID = processID
        self.connections = connections
    }
}

public struct ConnectionProbe: Sendable {
    public static let maximumTimeoutSeconds: TimeInterval = 2

    private let runner: any ConnectionProbeCommandRunning

    public init(runner: any ConnectionProbeCommandRunning = ProcessConnectionProbeRunner()) {
        self.runner = runner
    }

    public func inspect(processID: Int32) async -> ConnectionProbeResult {
        let command = await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: [
                "-nP", "-a", "-p", String(processID), "-iTCP", "-iUDP",
            ],
            timeoutSeconds: Self.maximumTimeoutSeconds
        )
        return ConnectionProbeResult(
            processID: processID,
            connections: parseMetadata(command.standardOutput)
        )
    }

    private func parseMetadata(_ output: String) -> [ConnectionMetadata] {
        var seen = Set<ConnectionMetadata>()
        var result: [ConnectionMetadata] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            let transport: ConnectionTransport?
            if fields.contains(where: { $0 == "TCP" }) {
                transport = .tcp
            } else if fields.contains(where: { $0 == "UDP" }) {
                transport = .udp
            } else {
                transport = nil
            }
            guard let transport else { continue }

            let state: ConnectionState
            if fields.contains(where: { $0 == "(ESTABLISHED)" }) {
                state = .established
            } else if fields.contains(where: { $0 == "(LISTEN)" }) {
                state = .listening
            } else {
                state = .unknown
            }
            let metadata = ConnectionMetadata(transport: transport, state: state)
            if seen.insert(metadata).inserted {
                result.append(metadata)
            }
        }
        return result
    }
}

public struct ProcessConnectionProbeRunner: ConnectionProbeCommandRunning, Sendable {
    public init() {}

    public func run(
        executableURL: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) async -> ConnectionProbeCommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ConnectionProbeCommandResult(exitCode: -1, standardOutput: "")
        }

        let deadline = Date().addingTimeInterval(min(timeoutSeconds, 2))
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if process.isRunning {
            process.terminate()
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return ConnectionProbeCommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: data, as: UTF8.self)
        )
    }
}
