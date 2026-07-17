import Foundation
import XCTest
@testable import SessionMonitorCore

final class RolloutSourceTests: XCTestCase {
    func testRolloutMapsOuterRecordsToSemanticEventsAndExactTimestamps() async throws {
        let fixture = try TemporaryRolloutFixture.materialized()
        defer { fixture.remove() }
        let source = RolloutSource(session: fixture.session)

        let result = await source.poll(since: nil)

        XCTAssertEqual(source.id, .rollout)
        XCTAssertEqual(
            result.events.map(\.kind),
            [
                .turnStarted,
                .modelActivity,
                .toolStarted(processID: 4242),
                .modelActivity,
                .modelActivity,
                .completed,
            ]
        )
        XCTAssertEqual(
            result.events.map(\.eventTime),
            (2...7).map { Date(timeIntervalSince1970: 1_784_246_400 + TimeInterval($0)) }
        )
        XCTAssertTrue(result.events.allSatisfy { $0.source == .rollout })
        XCTAssertTrue(result.events.allSatisfy { $0.sessionID == "session-rollout-1" })
        XCTAssertTrue(result.events.allSatisfy { $0.turnID == "turn-rollout-1" })

        let toolStart = try XCTUnwrap(
            result.events.first { $0.itemID == "tool-call-1" }
        )
        XCTAssertEqual(toolStart.toolName, "exec_command")
        XCTAssertEqual(toolStart.kind, .toolStarted(processID: 4242))

        let toolOutput = try XCTUnwrap(
            result.events.first { $0.itemID == "tool-output-1" }
        )
        XCTAssertEqual(toolOutput.durationMilliseconds, 1_250)
        XCTAssertNil(toolOutput.toolName)
        XCTAssertNil(toolOutput.errorCode)
    }

    func testMalformedCompleteLineDegradesButTruncatedTrailingLineStaysBuffered() async throws {
        let fixture = try TemporaryRolloutFixture.materialized()
        defer { fixture.remove() }

        let result = await RolloutSource(session: fixture.session).poll(since: nil)
        let sourcePosition = try XCTUnwrap(result.cursor?.filePosition)
        let fixtureData = try Data(contentsOf: fixture.fileURL)
        let finalCompleteLineEnd = try XCTUnwrap(fixtureData.lastIndex(of: 0x0A)) + 1

        XCTAssertEqual(result.health.status, .degraded)
        XCTAssertEqual(
            result.health.issues,
            [.malformedLine(path: fixture.fileURL.path, lineNumber: 9)]
        )
        XCTAssertEqual(sourcePosition.offset, UInt64(finalCompleteLineEnd))
        XCTAssertLessThan(sourcePosition.offset, UInt64(fixtureData.count))
        XCTAssertEqual(result.events.last?.kind, .completed)
        XCTAssertFalse(result.events.contains { event in
            event.eventTime == Date(timeIntervalSince1970: 1_784_246_409)
        })
    }

    func testStructuredPlanOnlyProducesCompletionAndPlanProseIsDiscarded() async throws {
        let fixture = try TemporaryRolloutFixture.materialized()
        defer { fixture.remove() }

        let result = await RolloutSource(session: fixture.session).poll(since: nil)
        let planEvent = try XCTUnwrap(
            result.events.first { $0.itemID == "plan-1" }
        )
        let normalized = EvidenceNormalizer().normalize([planEvent])

        XCTAssertEqual(
            planEvent.structuredPlan,
            StructuredPlanPayload(steps: [
                StructuredPlanStep(status: "completed"),
                StructuredPlanStep(status: "in_progress"),
                StructuredPlanStep(status: "pending"),
            ])
        )
        XCTAssertEqual(
            normalized.events.first?.planCompletion,
            PlanCompletion(completed: 1, total: 3)
        )
    }

    func testPollResultSerializationNeverRetainsForbiddenRolloutContent() async throws {
        let fixture = try TemporaryRolloutFixture.materialized()
        defer { fixture.remove() }

        let result = await RolloutSource(session: fixture.session).poll(since: nil)
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        let forbidden = [
            "FIXTURE_PROMPT_SHOULD_BE_DROPPED",
            "FIXTURE_TURN_CONTEXT_SHOULD_BE_DROPPED",
            "FIXTURE_REASONING_SHOULD_BE_DROPPED",
            "FIXTURE_FILE_CONTENT_SHOULD_BE_DROPPED",
            "FIXTURE_TOOL_OUTPUT_SHOULD_BE_DROPPED",
            "FIXTURE_PLAN_PROSE_SHOULD_BE_DROPPED",
            "payload.message",
            "arguments",
            "output",
            "prompt",
        ]

        for value in forbidden {
            XCTAssertFalse(encoded.contains(value), "Retained forbidden rollout value: \(value)")
        }
    }

    func testRestoredFileCursorDoesNotRescanCompletedUnchangedRollout() async throws {
        let fixture = try TemporaryRolloutFixture.completeSingleEvent()
        defer { fixture.remove() }
        let firstSource = RolloutSource(session: fixture.session)
        let first = await firstSource.poll(since: nil)
        let persistedCursor = try XCTUnwrap(first.cursor)

        let secondSource = RolloutSource(session: fixture.session)
        let second = await secondSource.poll(since: persistedCursor)

        XCTAssertEqual(first.events.map(\.kind), [.turnStarted])
        XCTAssertTrue(second.events.isEmpty)
        XCTAssertEqual(second.cursor, persistedCursor)
        XCTAssertEqual(second.health.status, .healthy)
        XCTAssertTrue(second.health.issues.isEmpty)
    }
}

private struct TemporaryRolloutFixture {
    let directoryURL: URL
    let fileURL: URL
    let session: SessionDescriptor

    static func materialized() throws -> TemporaryRolloutFixture {
        let resourceURL = try fixtureResourceURL(named: "rollout-v1", extension: "jsonl")
        var data = try Data(contentsOf: resourceURL)
        XCTAssertEqual(data.last, 0x0A, "SwiftPM may package the source fixture with a delimiter")
        data.removeLast()
        XCTAssertNotEqual(data.last, 0x0A, "The materialized final JSON record must stay incomplete")
        return try make(contents: data)
    }

    static func completeSingleEvent() throws -> TemporaryRolloutFixture {
        let line = """
            {"timestamp":"2026-07-17T00:00:02.000Z","type":"event_msg","payload":{"type":"task_started","session_id":"session-rollout-1","turn_id":"turn-rollout-1"}}
            """ + "\n"
        return try make(contents: Data(line.utf8))
    }

    private static func make(contents: Data) throws -> TemporaryRolloutFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RolloutSourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let fileURL = directoryURL.appendingPathComponent("session-rollout-1.jsonl")
        try contents.write(to: fileURL)
        let session = SessionDescriptor(
            id: "session-rollout-1",
            title: "scrubbed rollout",
            workspacePath: "/fixture/workspace",
            lastActivityAt: Date(timeIntervalSince1970: 1_784_246_407),
            surface: .cli,
            rolloutPath: fileURL.path
        )
        return TemporaryRolloutFixture(
            directoryURL: directoryURL,
            fileURL: fileURL,
            session: session
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func fixtureResourceURL(named name: String, extension fileExtension: String) throws -> URL {
    try XCTUnwrap(
        Bundle.module.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: "Fixtures"
        ) ?? Bundle.module.url(forResource: name, withExtension: fileExtension)
    )
}
