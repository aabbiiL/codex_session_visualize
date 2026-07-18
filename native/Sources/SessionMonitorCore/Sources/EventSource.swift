import Foundation

public protocol EventSource: Sendable {
    var id: EvidenceSource { get }
    func poll(since cursor: SourceCursor?) async -> SourcePollResult
}

public struct CodexDataRoot: Hashable, Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CodexDataRoot {
        if let configuredPath = environment["CODEX_HOME"], !configuredPath.isEmpty {
            return CodexDataRoot(
                directory: URL(fileURLWithPath: configuredPath, isDirectory: true)
            )
        }

        return CodexDataRoot(
            directory: homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        )
    }
}

public struct SourceCursor: Codable, Hashable, Sendable {
    public let source: EvidenceSource
    public let opaqueValue: String

    public init(source: EvidenceSource, opaqueValue: String) {
        self.source = source
        self.opaqueValue = opaqueValue
    }

    public init(source: EvidenceSource, filePosition: FileCursor) {
        self.init(
            source: source,
            opaqueValue: "\(filePosition.device):\(filePosition.inode):\(filePosition.offset)"
        )
    }

    public var filePosition: FileCursor? {
        let components = opaqueValue.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 3,
              let device = UInt64(String(components[0])),
              let inode = UInt64(String(components[1])),
              let offset = UInt64(String(components[2])) else {
            return nil
        }
        return FileCursor(device: device, inode: inode, offset: offset)
    }
}

public struct SourceHealth: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case healthy
        case degraded
        case unavailable
    }

    public let status: Status
    public let issues: [SourceIssue]

    public init(status: Status, issues: [SourceIssue] = []) {
        self.status = status
        self.issues = issues
    }
}

public enum SourceIssue: Codable, Hashable, Sendable {
    case missingFile(path: String)
    case lockedDatabase(path: String)
    case unsupportedSchema(table: String, missingColumns: [String])
    case databaseError(path: String, code: Int32)
    case malformedLine(path: String, lineNumber: Int)
    case rendererError(path: String, code: String, lineNumber: Int)
    case lineTooLong(path: String, limitBytes: Int)
    case pollLimitReached(path: String, limitBytes: Int)
}

public struct SpawnRelationship: Codable, Hashable, Sendable {
    public let parentSessionID: String
    public let childSessionID: String

    public init(parentSessionID: String, childSessionID: String) {
        self.parentSessionID = parentSessionID
        self.childSessionID = childSessionID
    }
}

public enum GoalStatus: String, Codable, Hashable, Sendable {
    case active
    case complete
}

public struct StructuredGoalStatus: Codable, Hashable, Sendable {
    public let sessionID: String
    public let status: GoalStatus
    public let updatedAt: Date

    public init(sessionID: String, status: GoalStatus, updatedAt: Date) {
        self.sessionID = sessionID
        self.status = status
        self.updatedAt = updatedAt
    }
}

public struct SourcePollResult: Codable, Hashable, Sendable {
    public let sessions: [SessionDescriptor]
    public let spawnRelationships: [SpawnRelationship]
    public let goals: [StructuredGoalStatus]
    public let events: [RawSourceEvent]
    public let health: SourceHealth
    public let cursor: SourceCursor?

    public init(
        sessions: [SessionDescriptor] = [],
        spawnRelationships: [SpawnRelationship] = [],
        goals: [StructuredGoalStatus] = [],
        events: [RawSourceEvent] = [],
        health: SourceHealth,
        cursor: SourceCursor? = nil
    ) {
        self.sessions = sessions
        self.spawnRelationships = spawnRelationships
        self.goals = goals
        self.events = events
        self.health = health
        self.cursor = cursor
    }

    static func degraded(issue: SourceIssue) -> SourcePollResult {
        SourcePollResult(
            health: SourceHealth(status: .degraded, issues: [issue])
        )
    }
}
