import Foundation

public struct DesktopLogSource: EventSource {
    public let id: EvidenceSource = .desktopLog

    private let logDirectory: URL
    private let reader: IncrementalFileReader

    public init(
        logDirectory: URL,
        reader: IncrementalFileReader = IncrementalFileReader()
    ) {
        self.logDirectory = logDirectory.standardizedFileURL
        self.reader = reader
    }

    public func poll(since cursor: SourceCursor?) async -> SourcePollResult {
        guard let fileURL = desktopLogFile() else {
            return SourcePollResult.degraded(
                issue: .missingFile(path: logDirectory.path)
            )
        }

        let fileCursor = cursor?.source == id ? cursor?.filePosition : nil
        let read = await reader.readLines(at: fileURL, since: fileCursor)
        var events: [RawSourceEvent] = []
        var issues = sourceIssues(from: read.issues, path: fileURL.path)
        let observedAt = Date()

        for (index, data) in read.lines.enumerated() where !data.isEmpty {
            let line = String(decoding: data, as: UTF8.self)
            if line.contains("renderer_unhandled_error") {
                issues.append(
                    .rendererError(
                        path: fileURL.path,
                        code: token(named: "code", in: line) ?? "unknown",
                        lineNumber: index + 1
                    )
                )
                continue
            }

            guard let mapping = eventMapping(for: line) else {
                continue
            }
            guard let timestamp = firstToken(in: line).flatMap(parseTimestamp),
                  let sessionID = token(named: "session_id", in: line) else {
                issues.append(
                    .malformedLine(path: fileURL.path, lineNumber: index + 1)
                )
                continue
            }

            events.append(
                RawSourceEvent(
                    sessionID: sessionID,
                    turnID: token(named: "turn_id", in: line),
                    itemID: token(named: "item_id", in: line),
                    kind: mapping.kind,
                    eventTime: timestamp,
                    observedAt: observedAt,
                    source: id,
                    durationMilliseconds: token(named: "duration_ms", in: line)
                        .flatMap { Int($0) },
                    errorCode: mapping.includesErrorCode
                        ? token(named: "error_code", in: line)
                        : nil
                )
            )
        }

        return SourcePollResult(
            events: events,
            health: SourceHealth(
                status: issues.isEmpty ? .healthy : .degraded,
                issues: issues
            ),
            cursor: SourceCursor(source: id, filePosition: read.cursor)
        )
    }

    private func desktopLogFile() -> URL? {
        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return candidates.filter { url in
            guard url.pathExtension == "log",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
                return false
            }
            return values.isRegularFile == true
        }.sorted { left, right in
            left.lastPathComponent < right.lastPathComponent
        }.last
    }

    private func eventMapping(for line: String) -> DesktopEventMapping? {
        if line.contains("chatgpt_turn_started") {
            return DesktopEventMapping(kind: .turnStarted)
        }
        if line.contains("chatgpt_response_routed") {
            return DesktopEventMapping(kind: .modelActivity)
        }
        if line.contains("chatgpt_pubsub_transport_closed") {
            return DesktopEventMapping(kind: .transportRetry, includesErrorCode: true)
        }
        if line.contains("chatgpt_pubsub_transport_opened") {
            return DesktopEventMapping(kind: .transportRecovered)
        }
        if line.contains("chatgpt_item_completed") {
            return DesktopEventMapping(kind: .modelActivity)
        }
        return nil
    }

    private func firstToken(in line: String) -> String? {
        guard let end = line.firstIndex(where: { $0.isWhitespace }) else {
            return line.isEmpty ? nil : line
        }
        return String(line[..<end])
    }

    private func token(named name: String, in line: String) -> String? {
        let marker = "\(name)="
        guard let markerRange = line.range(of: marker) else {
            return nil
        }
        let remainder = line[markerRange.upperBound...]
        let end = remainder.firstIndex(where: { $0.isWhitespace }) ?? remainder.endIndex
        var value = String(remainder[..<end])
        if value.first == "\"", value.last == "\"", value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }

    private func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private func sourceIssues(
        from issues: [IncrementalFileIssue],
        path: String
    ) -> [SourceIssue] {
        issues.map { issue in
            switch issue {
            case let .lineTooLong(limitBytes):
                return .lineTooLong(path: path, limitBytes: limitBytes)
            case let .pollLimitReached(limitBytes):
                return .pollLimitReached(path: path, limitBytes: limitBytes)
            case let .fileUnavailable(unavailablePath):
                return .missingFile(path: unavailablePath)
            }
        }
    }
}

private struct DesktopEventMapping {
    let kind: ObservedEvent.Kind
    let includesErrorCode: Bool

    init(kind: ObservedEvent.Kind, includesErrorCode: Bool = false) {
        self.kind = kind
        self.includesErrorCode = includesErrorCode
    }
}
