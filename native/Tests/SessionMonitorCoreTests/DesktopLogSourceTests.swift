import Foundation
import XCTest
@testable import SessionMonitorCore

final class DesktopLogSourceTests: XCTestCase {
    func testDesktopLogMapsPhaseTransportAndItemEventsWithExactTimestamps() async throws {
        let fixture = try TemporaryDesktopLogFixture.materialized()
        defer { fixture.remove() }
        let source = DesktopLogSource(logDirectory: fixture.directoryURL)

        let result = await source.poll(since: nil)

        XCTAssertEqual(source.id, .desktopLog)
        XCTAssertEqual(
            result.events.map(\.kind),
            [
                .turnStarted,
                .modelActivity,
                .transportRetry,
                .transportRecovered,
                .modelActivity,
            ]
        )
        XCTAssertEqual(
            result.events.map(\.eventTime),
            (0...4).map { Date(timeIntervalSince1970: 1_784_250_000 + TimeInterval($0)) }
        )
        XCTAssertTrue(result.events.allSatisfy { $0.source == .desktopLog })
        XCTAssertTrue(result.events.allSatisfy { $0.sessionID == "session-desktop-1" })
        XCTAssertTrue(result.events.allSatisfy { $0.turnID == "turn-desktop-1" })

        let closed = try XCTUnwrap(
            result.events.first { $0.kind == .transportRetry }
        )
        XCTAssertEqual(closed.errorCode, "PUBSUB_1006")
        let reopened = try XCTUnwrap(
            result.events.first { $0.kind == .transportRecovered }
        )
        XCTAssertNil(reopened.errorCode)

        let completedItem = try XCTUnwrap(
            result.events.first { $0.itemID == "response-1" && $0.durationMilliseconds == 875 }
        )
        XCTAssertEqual(completedItem.kind, .modelActivity)
        XCTAssertEqual(completedItem.durationMilliseconds, 875)
    }

    func testRendererOnlyErrorDegradesObserverSourceWithoutFailingSession() async throws {
        let fixture = try TemporaryDesktopLogFixture.materialized()
        defer { fixture.remove() }

        let result = await DesktopLogSource(logDirectory: fixture.directoryURL).poll(since: nil)

        XCTAssertEqual(result.health.status, .degraded)
        XCTAssertEqual(
            result.health.issues,
            [
                .rendererError(
                    path: fixture.fileURL.resolvingSymlinksInPath().path,
                    code: "RENDERER_ONLY_42",
                    lineNumber: 6
                ),
            ]
        )
        XCTAssertFalse(result.events.contains { $0.kind == .failed })
        XCTAssertEqual(result.events.count, 5, "Renderer diagnostics must not become session events")
    }

    func testDesktopPollResultNeverRetainsPromptReplyCommandOutputOrFileContent() async throws {
        let fixture = try TemporaryDesktopLogFixture.materialized()
        defer { fixture.remove() }

        let result = await DesktopLogSource(logDirectory: fixture.directoryURL).poll(since: nil)
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        let forbidden = [
            "FIXTURE_DESKTOP_PROMPT_SHOULD_BE_DROPPED",
            "FIXTURE_DESKTOP_REPLY_SHOULD_BE_DROPPED",
            "FIXTURE_DESKTOP_COMMAND_OUTPUT_SHOULD_BE_DROPPED",
            "FIXTURE_DESKTOP_FILE_CONTENT_SHOULD_BE_DROPPED",
            "payload.message",
            "command_output",
            "file_content",
        ]

        for value in forbidden {
            XCTAssertFalse(encoded.contains(value), "Retained forbidden Desktop value: \(value)")
        }
    }

    func testDesktopSourceReturnsPersistableFilePositionCursor() async throws {
        let fixture = try TemporaryDesktopLogFixture.materialized()
        defer { fixture.remove() }

        let first = await DesktopLogSource(logDirectory: fixture.directoryURL).poll(since: nil)
        let position = try XCTUnwrap(first.cursor?.filePosition)
        let second = await DesktopLogSource(logDirectory: fixture.directoryURL).poll(
            since: first.cursor
        )

        XCTAssertGreaterThan(position.device, 0)
        XCTAssertGreaterThan(position.inode, 0)
        XCTAssertEqual(position.offset, UInt64(try Data(contentsOf: fixture.fileURL).count))
        XCTAssertTrue(second.events.isEmpty)
        XCTAssertEqual(second.cursor, first.cursor)
        XCTAssertEqual(second.health.status, .healthy)
        XCTAssertTrue(second.health.issues.isEmpty)
    }
}

private struct TemporaryDesktopLogFixture {
    let directoryURL: URL
    let fileURL: URL

    static func materialized() throws -> TemporaryDesktopLogFixture {
        let resourceURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "desktop-log-v1",
                withExtension: "log",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(forResource: "desktop-log-v1", withExtension: "log")
        )
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesktopLogSourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let fileURL = directoryURL.appendingPathComponent("desktop.log")
        try Data(contentsOf: resourceURL).write(to: fileURL)
        return TemporaryDesktopLogFixture(directoryURL: directoryURL, fileURL: fileURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
