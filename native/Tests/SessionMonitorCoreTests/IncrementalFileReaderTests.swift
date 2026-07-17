import Foundation
import XCTest
@testable import SessionMonitorCore

final class IncrementalFileReaderTests: XCTestCase {
    func testReadsOnlyCompleteLinesAndKeepsTrailingBytesInMemory() async throws {
        let fixture = try TemporaryIncrementalFile(contents: Data("alpha\npartial".utf8))
        defer { fixture.remove() }
        let reader = IncrementalFileReader()

        let first = await reader.readLines(at: fixture.fileURL, since: nil)

        XCTAssertEqual(decoded(first.lines), ["alpha"])
        XCTAssertEqual(first.cursor.offset, 6)
        XCTAssertEqual(first.bufferedByteCount, 7)
        XCTAssertEqual(first.bytesRead, 13)
        XCTAssertTrue(first.issues.isEmpty)

        try append(Data("-tail\n".utf8), to: fixture.fileURL)
        let second = await reader.readLines(at: fixture.fileURL, since: first.cursor)

        XCTAssertEqual(decoded(second.lines), ["partial-tail"])
        XCTAssertEqual(second.cursor.offset, 19)
        XCTAssertEqual(second.bufferedByteCount, 0)
        XCTAssertEqual(second.bytesRead, 6, "Buffered bytes must not be read from disk again")
        XCTAssertTrue(second.issues.isEmpty)
    }

    func testCompletedUnchangedFileIsNeverRescanned() async throws {
        let fixture = try TemporaryIncrementalFile(contents: Data("one\ntwo\n".utf8))
        defer { fixture.remove() }
        let reader = IncrementalFileReader()

        let first = await reader.readLines(at: fixture.fileURL, since: nil)
        let second = await reader.readLines(at: fixture.fileURL, since: first.cursor)

        XCTAssertEqual(decoded(first.lines), ["one", "two"])
        XCTAssertTrue(second.lines.isEmpty)
        XCTAssertEqual(second.bytesRead, 0)
        XCTAssertEqual(second.cursor, first.cursor)
        XCTAssertNil(second.rotation)
    }

    func testPersistedCursorContainsOnlyDeviceInodeAndOffset() async throws {
        let fixture = try TemporaryIncrementalFile(contents: Data("one\n".utf8))
        defer { fixture.remove() }

        let result = await IncrementalFileReader().readLines(at: fixture.fileURL, since: nil)
        let encoded = try JSONEncoder().encode(result.cursor)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), ["device", "inode", "offset"])
        XCTAssertGreaterThan(result.cursor.device, 0)
        XCTAssertGreaterThan(result.cursor.inode, 0)
        XCTAssertEqual(result.cursor.offset, 4)
    }

    func testInodeReplacementStartsAtZeroAndEmitsRotationEvidence() async throws {
        let fixture = try TemporaryIncrementalFile(contents: Data("old-line\n".utf8))
        defer { fixture.remove() }
        let reader = IncrementalFileReader()
        let first = await reader.readLines(at: fixture.fileURL, since: nil)
        let oldInode = try inode(of: fixture.fileURL)

        let replacementURL = fixture.directoryURL.appendingPathComponent("replacement.log")
        try Data("rotated-line\n".utf8).write(to: replacementURL)
        let replacementInode = try inode(of: replacementURL)
        XCTAssertNotEqual(oldInode, replacementInode, "The fixture must exercise inode rotation")
        try FileManager.default.removeItem(at: fixture.fileURL)
        try FileManager.default.moveItem(at: replacementURL, to: fixture.fileURL)

        let second = await reader.readLines(at: fixture.fileURL, since: first.cursor)

        XCTAssertEqual(second.rotation, .inodeChanged)
        XCTAssertEqual(decoded(second.lines), ["rotated-line"])
        XCTAssertEqual(second.cursor.inode, replacementInode)
        XCTAssertEqual(second.cursor.offset, UInt64(Data("rotated-line\n".utf8).count))
    }

    func testTruncationBelowCursorResetsSameInodeAndEmitsRotationEvidence() async throws {
        let fixture = try TemporaryIncrementalFile(
            contents: Data("original-one\noriginal-two\n".utf8)
        )
        defer { fixture.remove() }
        let reader = IncrementalFileReader()
        let first = await reader.readLines(at: fixture.fileURL, since: nil)
        let originalInode = try inode(of: fixture.fileURL)

        let handle = try FileHandle(forWritingTo: fixture.fileURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("new\n".utf8))
        try handle.close()
        XCTAssertEqual(try inode(of: fixture.fileURL), originalInode)
        XCTAssertLessThan(4, first.cursor.offset)

        let second = await reader.readLines(at: fixture.fileURL, since: first.cursor)

        XCTAssertEqual(second.rotation, .truncated)
        XCTAssertEqual(decoded(second.lines), ["new"])
        XCTAssertEqual(second.cursor.inode, originalInode)
        XCTAssertEqual(second.cursor.offset, 4)
    }

    func testLineLargerThanOneMiBIsDiscardedWithoutRetainingItsContent() async throws {
        let limit = IncrementalFileReader.maximumLineBytes
        var oversized = Data(repeating: 0x61, count: limit + 1)
        oversized.append(0x0A)
        let fixture = try TemporaryIncrementalFile(contents: oversized)
        defer { fixture.remove() }

        let result = await IncrementalFileReader().readLines(at: fixture.fileURL, since: nil)

        XCTAssertEqual(limit, 1_048_576)
        XCTAssertTrue(result.lines.isEmpty)
        XCTAssertEqual(result.bufferedByteCount, 0)
        XCTAssertEqual(result.issues, [.lineTooLong(limitBytes: limit)])
    }

    func testPollReadsAtMostFourMiBAndContinuesFromReturnedCursor() async throws {
        let lineBytes = IncrementalFileReader.maximumLineBytes
        var line = Data(repeating: 0x61, count: lineBytes - 1)
        line.append(0x0A)
        var fiveLines = Data()
        for _ in 0..<5 {
            fiveLines.append(line)
        }
        let fixture = try TemporaryIncrementalFile(contents: fiveLines)
        defer { fixture.remove() }
        let reader = IncrementalFileReader()

        let first = await reader.readLines(at: fixture.fileURL, since: nil)

        XCTAssertEqual(IncrementalFileReader.maximumPollBytes, 4_194_304)
        XCTAssertEqual(first.bytesRead, IncrementalFileReader.maximumPollBytes)
        XCTAssertEqual(first.lines.count, 4)
        XCTAssertEqual(first.cursor.offset, UInt64(IncrementalFileReader.maximumPollBytes))
        XCTAssertEqual(
            first.issues,
            [.pollLimitReached(limitBytes: IncrementalFileReader.maximumPollBytes)]
        )

        let second = await reader.readLines(at: fixture.fileURL, since: first.cursor)

        XCTAssertEqual(second.lines.count, 1)
        XCTAssertEqual(second.bytesRead, lineBytes)
        XCTAssertEqual(second.cursor.offset, UInt64(fiveLines.count))
        XCTAssertTrue(second.issues.isEmpty)
    }

    private func decoded(_ lines: [Data]) -> [String] {
        lines.map { String(decoding: $0, as: UTF8.self) }
    }

    private func append(_ data: Data, to fileURL: URL) throws {
        let handle = try FileHandle(forWritingTo: fileURL)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    private func inode(of fileURL: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        return try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value
    }
}

private struct TemporaryIncrementalFile {
    let directoryURL: URL
    let fileURL: URL

    init(contents: Data) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncrementalFileReaderTests-\(UUID().uuidString)")
        fileURL = directoryURL.appendingPathComponent("activity.log")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try contents.write(to: fileURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
