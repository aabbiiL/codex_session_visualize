import Foundation

public struct StateDatabaseSource: EventSource {
    public let id: EvidenceSource = .stateDatabase

    static let activeThreadsSQL = """
        SELECT id, rollout_path, created_at_ms, updated_at_ms, source,
               cwd, title, archived, agent_nickname, agent_role,
               thread_source, recency_at_ms
        FROM threads
        WHERE archived = 0;
        """

    static let spawnEdgesSQL = """
        SELECT parent_thread_id, child_thread_id
        FROM thread_spawn_edges;
        """

    private static let requiredThreadColumns = [
        "id",
        "rollout_path",
        "created_at_ms",
        "updated_at_ms",
        "source",
        "cwd",
        "title",
        "archived",
        "agent_nickname",
        "agent_role",
        "thread_source",
        "recency_at_ms",
    ]

    private static let requiredSpawnEdgeColumns = [
        "parent_thread_id",
        "child_thread_id",
    ]

    private let dataRoot: CodexDataRoot

    public init(dataRoot: CodexDataRoot) {
        self.dataRoot = dataRoot
    }

    public func poll(since _: SourceCursor?) async -> SourcePollResult {
        let databaseURL = dataRoot.directory.appendingPathComponent("state_5.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return .degraded(issue: .missingFile(path: databaseURL.path))
        }

        do {
            let database = try SQLiteReadOnly(databaseURL: databaseURL)
            if let issue = try schemaIssue(in: database) {
                return .degraded(issue: issue)
            }

            let relationships = try loadSpawnRelationships(from: database)
            let childSessionIDs = Set(relationships.map(\.childSessionID))
            let sessions = try loadSessions(
                from: database,
                childSessionIDs: childSessionIDs
            )
            let sessionIDs = Set(sessions.map(\.id))
            let activeLocalRelationships = relationships.filter {
                sessionIDs.contains($0.parentSessionID)
                    && sessionIDs.contains($0.childSessionID)
            }
            let maximumRecency = sessions
                .map { Int64($0.lastActivityAt.timeIntervalSince1970 * 1_000) }
                .max() ?? 0

            return SourcePollResult(
                sessions: sessions,
                spawnRelationships: activeLocalRelationships,
                health: SourceHealth(status: .healthy),
                cursor: SourceCursor(
                    source: id,
                    opaqueValue: String(maximumRecency)
                )
            )
        } catch {
            return .degraded(
                issue: sourceIssue(for: error, databaseURL: databaseURL)
            )
        }
    }

    private func schemaIssue(in database: SQLiteReadOnly) throws -> SourceIssue? {
        let threadColumns = try database.columns(in: "threads")
        let missingThreadColumns = Self.requiredThreadColumns.filter {
            !threadColumns.contains($0)
        }
        if !missingThreadColumns.isEmpty {
            return .unsupportedSchema(
                table: "threads",
                missingColumns: missingThreadColumns
            )
        }

        let spawnEdgeColumns = try database.columns(in: "thread_spawn_edges")
        let missingSpawnEdgeColumns = Self.requiredSpawnEdgeColumns.filter {
            !spawnEdgeColumns.contains($0)
        }
        if !missingSpawnEdgeColumns.isEmpty {
            return .unsupportedSchema(
                table: "thread_spawn_edges",
                missingColumns: missingSpawnEdgeColumns
            )
        }

        return nil
    }

    private func loadSpawnRelationships(
        from database: SQLiteReadOnly
    ) throws -> [SpawnRelationship] {
        let statement = try database.prepare(Self.spawnEdgesSQL)
        var relationships = [SpawnRelationship]()

        while try statement.step() {
            guard
                let parentSessionID = statement.text(at: 0),
                let childSessionID = statement.text(at: 1)
            else {
                continue
            }

            relationships.append(
                SpawnRelationship(
                    parentSessionID: parentSessionID,
                    childSessionID: childSessionID
                )
            )
        }

        return relationships
    }

    private func loadSessions(
        from database: SQLiteReadOnly,
        childSessionIDs: Set<String>
    ) throws -> [SessionDescriptor] {
        let statement = try database.prepare(Self.activeThreadsSQL)
        var sessions = [SessionDescriptor]()

        while try statement.step() {
            guard
                let sessionID = statement.text(at: 0),
                let source = statement.text(at: 4),
                statement.int64(at: 7) == 0,
                let surface = surface(
                    sessionID: sessionID,
                    source: source,
                    threadSource: statement.text(at: 10),
                    childSessionIDs: childSessionIDs
                )
            else {
                continue
            }

            let activityMilliseconds = statement.int64(at: 11)
                ?? statement.int64(at: 3)
                ?? statement.int64(at: 2)
                ?? 0
            sessions.append(
                SessionDescriptor(
                    id: sessionID,
                    title: statement.text(at: 6),
                    workspacePath: statement.text(at: 5),
                    lastActivityAt: Date(
                        timeIntervalSince1970: TimeInterval(activityMilliseconds) / 1_000
                    ),
                    surface: surface,
                    rolloutPath: statement.text(at: 1),
                    agentNickname: statement.text(at: 8),
                    agentRole: statement.text(at: 9)
                )
            )
        }

        return sessions
    }

    private func surface(
        sessionID: String,
        source: String,
        threadSource: String?,
        childSessionIDs: Set<String>
    ) -> LocalSurface? {
        if childSessionIDs.contains(sessionID) {
            return .subAgent
        }

        switch threadSource?.lowercased() {
        case "sub_agent", "subagent":
            return .subAgent
        case "desktop":
            return .desktop
        case "vscode", "ide":
            return .ide
        case "cli":
            return .cli
        default:
            break
        }

        switch source.lowercased() {
        case "sub_agent", "subagent":
            return .subAgent
        case "app_server", "app", "desktop":
            return .desktop
        case "vscode", "ide":
            return .ide
        case "cli":
            return .cli
        default:
            return nil
        }
    }
}
