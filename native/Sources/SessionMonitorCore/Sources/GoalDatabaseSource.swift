import Foundation

public struct GoalDatabaseSource: EventSource {
    public let id: EvidenceSource = .stateDatabase

    static let goalsSQL = """
        SELECT thread_id, status, updated_at_ms
        FROM goals;
        """

    private static let requiredGoalColumns = [
        "thread_id",
        "status",
        "updated_at_ms",
    ]

    private let dataRoot: CodexDataRoot

    public init(dataRoot: CodexDataRoot) {
        self.dataRoot = dataRoot
    }

    public func poll(since _: SourceCursor?) async -> SourcePollResult {
        let databaseURL = dataRoot.directory.appendingPathComponent("goals_1.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return .degraded(issue: .missingFile(path: databaseURL.path))
        }

        do {
            let database = try SQLiteReadOnly(databaseURL: databaseURL)
            if let issue = try schemaIssue(in: database) {
                return .degraded(issue: issue)
            }

            let goals = try loadGoals(from: database)
            let maximumUpdate = goals
                .map { Int64($0.updatedAt.timeIntervalSince1970 * 1_000) }
                .max() ?? 0

            return SourcePollResult(
                goals: goals,
                health: SourceHealth(status: .healthy),
                cursor: SourceCursor(
                    source: id,
                    opaqueValue: String(maximumUpdate)
                )
            )
        } catch {
            return .degraded(
                issue: sourceIssue(for: error, databaseURL: databaseURL)
            )
        }
    }

    private func schemaIssue(in database: SQLiteReadOnly) throws -> SourceIssue? {
        let columns = try database.columns(in: "goals")
        let missingColumns = Self.requiredGoalColumns.filter {
            !columns.contains($0)
        }
        guard !missingColumns.isEmpty else { return nil }

        return .unsupportedSchema(
            table: "goals",
            missingColumns: missingColumns
        )
    }

    private func loadGoals(
        from database: SQLiteReadOnly
    ) throws -> [StructuredGoalStatus] {
        let statement = try database.prepare(Self.goalsSQL)
        var goals = [StructuredGoalStatus]()

        while try statement.step() {
            guard
                let sessionID = statement.text(at: 0),
                let rawStatus = statement.text(at: 1),
                let status = GoalStatus(rawValue: rawStatus),
                let updatedAtMilliseconds = statement.int64(at: 2)
            else {
                continue
            }

            goals.append(
                StructuredGoalStatus(
                    sessionID: sessionID,
                    status: status,
                    updatedAt: Date(
                        timeIntervalSince1970: TimeInterval(updatedAtMilliseconds) / 1_000
                    )
                )
            )
        }

        return goals
    }
}
