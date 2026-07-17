import Foundation
import XCTest
@testable import SessionMonitorCore

final class StateDatabaseSourceTests: XCTestCase {
    private static let activeThreadsSQL = """
        SELECT id, rollout_path, created_at_ms, updated_at_ms, source,
               cwd, title, archived, agent_nickname, agent_role,
               thread_source, recency_at_ms
        FROM threads
        WHERE archived = 0;
        """

    private static let spawnEdgesSQL = """
        SELECT parent_thread_id, child_thread_id
        FROM thread_spawn_edges;
        """

    private static let goalsSQL = """
        SELECT thread_id, status, updated_at_ms
        FROM goals;
        """

    func testCodexDataRootUsesCODEXHomeOrFallsBackToOneDefaultRoot() {
        let custom = CodexDataRoot.resolve(
            environment: ["CODEX_HOME": "/tmp/custom-codex-home"],
            homeDirectory: URL(fileURLWithPath: "/Users/fixture")
        )
        let fallback = CodexDataRoot.resolve(
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/Users/fixture")
        )
        let emptyOverride = CodexDataRoot.resolve(
            environment: ["CODEX_HOME": ""],
            homeDirectory: URL(fileURLWithPath: "/Users/fixture")
        )

        XCTAssertEqual(custom.directory.path, "/tmp/custom-codex-home")
        XCTAssertEqual(fallback.directory.path, "/Users/fixture/.codex")
        XCTAssertEqual(emptyOverride.directory.path, "/Users/fixture/.codex")
    }

    func testSQLiteContractUsesOnlyRequiredReadOnlyFlagsURIAndBusyTimeout() {
        XCTAssertEqual(
            SQLiteReadOnly.openFlags,
            Int32(0x00000001 | 0x00000040 | 0x00008000),
            "Expected SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX"
        )
        XCTAssertEqual(SQLiteReadOnly.busyTimeoutMilliseconds, 100)
        XCTAssertEqual(
            SQLiteReadOnly.uri(for: URL(fileURLWithPath: "/tmp/state_5.sqlite")),
            "file:/tmp/state_5.sqlite?mode=ro"
        )
    }

    func testInventoryQueriesUseExactMinimalColumnsAndNeverSelectContentFields() {
        XCTAssertEqual(StateDatabaseSource.activeThreadsSQL, Self.activeThreadsSQL)
        XCTAssertEqual(StateDatabaseSource.spawnEdgesSQL, Self.spawnEdgesSQL)
        XCTAssertEqual(GoalDatabaseSource.goalsSQL, Self.goalsSQL)

        let allQueries = [
            StateDatabaseSource.activeThreadsSQL,
            StateDatabaseSource.spawnEdgesSQL,
            GoalDatabaseSource.goalsSQL,
        ].joined(separator: "\n").lowercased()

        XCTAssertFalse(allQueries.contains("select *"))
        XCTAssertFalse(allQueries.contains("first_user_message"))
        XCTAssertFalse(allQueries.contains("preview"))
        XCTAssertFalse(allQueries.contains("objective"))
        XCTAssertFalse(allQueries.contains("prompt"))
    }

    func testStateInventoryExcludesArchivedAndMapsEveryLocalSurfaceAndSpawnEdge() async throws {
        let fixture = try makeDataRoot()
        defer { fixture.remove() }
        try materializeFixture(named: "state-v5", at: fixture.stateDatabaseURL)

        let source = StateDatabaseSource(dataRoot: fixture.root)
        let result = await source.poll(since: nil)
        let sessionsByID = Dictionary(uniqueKeysWithValues: result.sessions.map { ($0.id, $0) })

        XCTAssertEqual(source.id, .stateDatabase)
        XCTAssertEqual(Set(sessionsByID.keys), ["desktop-1", "cli-1", "ide-1", "subagent-1"])
        XCTAssertNil(sessionsByID["archived-1"])
        XCTAssertNil(sessionsByID["nonlocal-1"])
        XCTAssertEqual(sessionsByID["desktop-1"]?.surface, .desktop)
        XCTAssertEqual(sessionsByID["cli-1"]?.surface, .cli)
        XCTAssertEqual(sessionsByID["ide-1"]?.surface, .ide)
        XCTAssertEqual(sessionsByID["subagent-1"]?.surface, .subAgent)
        XCTAssertEqual(
            sessionsByID["desktop-1"]?.rolloutPath,
            "/tmp/codex-fixture/rollouts/desktop-1.jsonl"
        )
        XCTAssertEqual(sessionsByID["subagent-1"]?.agentNickname, "fixture-agent")
        XCTAssertEqual(sessionsByID["subagent-1"]?.agentRole, "worker")
        XCTAssertEqual(result.spawnRelationships.count, 1)
        XCTAssertEqual(result.spawnRelationships.first?.parentSessionID, "cli-1")
        XCTAssertEqual(result.spawnRelationships.first?.childSessionID, "subagent-1")
        XCTAssertTrue(
            result.spawnRelationships.allSatisfy {
                sessionsByID[$0.parentSessionID] != nil
                    && sessionsByID[$0.childSessionID] != nil
            }
        )
        XCTAssertEqual(result.health.status, .healthy)
        XCTAssertTrue(result.health.issues.isEmpty)
        XCTAssertNotNil(result.cursor)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stateDatabaseURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stateDatabaseURL.path + "-shm"))
    }

    func testGoalInventoryMapsActiveAndCompleteStructuredStatusesWithoutGoalContent() async throws {
        let fixture = try makeDataRoot()
        defer { fixture.remove() }
        try materializeFixture(named: "goals-v1", at: fixture.goalDatabaseURL)

        let source = GoalDatabaseSource(dataRoot: fixture.root)
        let result = await source.poll(since: nil)
        let goalsBySession = Dictionary(
            uniqueKeysWithValues: result.goals.map { ($0.sessionID, $0) }
        )

        XCTAssertEqual(source.id, .stateDatabase)
        XCTAssertEqual(Set(goalsBySession.keys), ["cli-1", "desktop-1"])
        XCTAssertEqual(goalsBySession["cli-1"]?.status, .active)
        XCTAssertEqual(goalsBySession["desktop-1"]?.status, .complete)
        XCTAssertEqual(
            goalsBySession["cli-1"]?.updatedAt,
            Date(timeIntervalSince1970: 1_700_000_010)
        )
        XCTAssertEqual(result.health.status, .healthy)
        XCTAssertTrue(result.health.issues.isEmpty)
        XCTAssertNotNil(result.cursor)
    }

    func testMissingRequiredThreadColumnReturnsNamedUnsupportedSchemaIssue() async throws {
        let fixture = try makeDataRoot()
        defer { fixture.remove() }
        try materialize(
            sql: Self.stateSchemaMissingRecencyColumn,
            at: fixture.stateDatabaseURL
        )

        let result = await StateDatabaseSource(dataRoot: fixture.root).poll(since: nil)

        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertEqual(result.health.status, .degraded)
        XCTAssertEqual(
            result.health.issues,
            [.unsupportedSchema(table: "threads", missingColumns: ["recency_at_ms"])]
        )
    }

    func testMissingRequiredSpawnEdgeColumnReturnsNamedUnsupportedSchemaIssue() async throws {
        let fixture = try makeDataRoot()
        defer { fixture.remove() }
        try materialize(
            sql: Self.stateSchemaMissingChildEdgeColumn,
            at: fixture.stateDatabaseURL
        )

        let result = await StateDatabaseSource(dataRoot: fixture.root).poll(since: nil)

        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertTrue(result.spawnRelationships.isEmpty)
        XCTAssertEqual(result.health.status, .degraded)
        XCTAssertEqual(
            result.health.issues,
            [
                .unsupportedSchema(
                    table: "thread_spawn_edges",
                    missingColumns: ["child_thread_id"]
                ),
            ]
        )
    }

    func testMissingRequiredGoalStatusColumnReturnsNamedUnsupportedSchemaIssue() async throws {
        let fixture = try makeDataRoot()
        defer { fixture.remove() }
        try materialize(
            sql: "CREATE TABLE goals (thread_id TEXT, updated_at_ms INTEGER);",
            at: fixture.goalDatabaseURL
        )

        let result = await GoalDatabaseSource(dataRoot: fixture.root).poll(since: nil)

        XCTAssertTrue(result.goals.isEmpty)
        XCTAssertEqual(result.health.status, .degraded)
        XCTAssertEqual(
            result.health.issues,
            [.unsupportedSchema(table: "goals", missingColumns: ["status"])]
        )
    }

    func testMissingStateDatabaseReturnsTypedIssueInsteadOfThrowingOrCrashing() async throws {
        let fixture = try makeDataRoot()
        defer { fixture.remove() }

        let result = await StateDatabaseSource(dataRoot: fixture.root).poll(since: nil)

        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertEqual(result.health.status, .degraded)
        XCTAssertEqual(
            result.health.issues,
            [.missingFile(path: fixture.stateDatabaseURL.path)]
        )
    }

    func testMissingGoalDatabaseReturnsTypedIssueInsteadOfThrowingOrCrashing() async throws {
        let fixture = try makeDataRoot()
        defer { fixture.remove() }

        let result = await GoalDatabaseSource(dataRoot: fixture.root).poll(since: nil)

        XCTAssertTrue(result.goals.isEmpty)
        XCTAssertEqual(result.health.status, .degraded)
        XCTAssertEqual(
            result.health.issues,
            [.missingFile(path: fixture.goalDatabaseURL.path)]
        )
    }

    func testLockedStateDatabaseReturnsTypedIssueInsteadOfThrowingOrCrashing() async throws {
        let fixture = try makeDataRoot()
        defer { fixture.remove() }
        try materializeFixture(named: "state-v5", at: fixture.stateDatabaseURL)
        let lock = try SQLiteExclusiveLock(databaseURL: fixture.stateDatabaseURL)
        defer { lock.release() }

        let result = await StateDatabaseSource(dataRoot: fixture.root).poll(since: nil)

        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertEqual(result.health.status, .degraded)
        XCTAssertEqual(
            result.health.issues,
            [.lockedDatabase(path: fixture.stateDatabaseURL.path)]
        )
    }

    func testLockedGoalDatabaseReturnsTypedIssueInsteadOfThrowingOrCrashing() async throws {
        let fixture = try makeDataRoot()
        defer { fixture.remove() }
        try materializeFixture(named: "goals-v1", at: fixture.goalDatabaseURL)
        let lock = try SQLiteExclusiveLock(databaseURL: fixture.goalDatabaseURL)
        defer { lock.release() }

        let result = await GoalDatabaseSource(dataRoot: fixture.root).poll(since: nil)

        XCTAssertTrue(result.goals.isEmpty)
        XCTAssertEqual(result.health.status, .degraded)
        XCTAssertEqual(
            result.health.issues,
            [.lockedDatabase(path: fixture.goalDatabaseURL.path)]
        )
    }

    private func makeDataRoot() throws -> TemporaryDataRoot {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StateDatabaseSourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return TemporaryDataRoot(directory: directory)
    }

    private func materializeFixture(named name: String, at databaseURL: URL) throws {
        let resourceURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: name,
                withExtension: "sql",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(forResource: name, withExtension: "sql")
        )
        try materialize(
            sql: String(contentsOf: resourceURL, encoding: .utf8),
            at: databaseURL
        )
    }

    private func materialize(sql: String, at databaseURL: URL) throws {
        let process = Process()
        let standardInput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databaseURL.path]
        process.standardInput = standardInput
        process.standardError = standardError

        try process.run()
        standardInput.fileHandleForWriting.write(Data(sql.utf8))
        standardInput.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "sqlite3 fixture creation failed"
            throw NSError(
                domain: "StateDatabaseSourceTests.SQLiteFixture",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private static let stateSchemaMissingRecencyColumn = """
        CREATE TABLE threads (
            id TEXT, rollout_path TEXT, created_at_ms INTEGER, updated_at_ms INTEGER,
            source TEXT, cwd TEXT, title TEXT, archived INTEGER,
            agent_nickname TEXT, agent_role TEXT, thread_source TEXT
        );
        CREATE TABLE thread_spawn_edges (
            parent_thread_id TEXT, child_thread_id TEXT
        );
        """

    private static let stateSchemaMissingChildEdgeColumn = """
        CREATE TABLE threads (
            id TEXT, rollout_path TEXT, created_at_ms INTEGER, updated_at_ms INTEGER,
            source TEXT, cwd TEXT, title TEXT, archived INTEGER,
            agent_nickname TEXT, agent_role TEXT, thread_source TEXT, recency_at_ms INTEGER
        );
        CREATE TABLE thread_spawn_edges (parent_thread_id TEXT);
        """
}

private struct TemporaryDataRoot {
    let directory: URL

    var root: CodexDataRoot {
        CodexDataRoot(directory: directory)
    }

    var stateDatabaseURL: URL {
        directory.appendingPathComponent("state_5.sqlite")
    }

    var goalDatabaseURL: URL {
        directory.appendingPathComponent("goals_1.sqlite")
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class SQLiteExclusiveLock {
    private let process = Process()
    private let standardInput = Pipe()
    private var isReleased = false

    init(databaseURL: URL) throws {
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databaseURL.path]
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        standardInput.fileHandleForWriting.write(
            Data("BEGIN EXCLUSIVE;\n.print LOCKED\n".utf8)
        )
        let marker = standardOutput.fileHandleForReading.availableData
        guard String(data: marker, encoding: .utf8)?.contains("LOCKED") == true else {
            release()
            let message = String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "sqlite3 did not acquire the fixture lock"
            throw NSError(
                domain: "StateDatabaseSourceTests.SQLiteLock",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        standardInput.fileHandleForWriting.write(Data("ROLLBACK;\n.quit\n".utf8))
        standardInput.fileHandleForWriting.closeFile()
        process.waitUntilExit()
    }

    deinit {
        release()
    }
}
