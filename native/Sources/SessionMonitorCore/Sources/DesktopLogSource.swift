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
            guard let record = structuralRecord(for: line) else {
                continue
            }
            if record.eventName == "renderer_unhandled_error" {
                issues.append(
                    .rendererError(
                        path: fileURL.path,
                        code: record.metadata["code"] ?? "unknown",
                        lineNumber: index + 1
                    )
                )
                continue
            }

            guard let mapping = eventMapping(for: record.eventName) else {
                continue
            }
            guard let timestamp = parseTimestamp(record.timestamp),
                  let sessionID = record.metadata["session_id"] else {
                issues.append(
                    .malformedLine(path: fileURL.path, lineNumber: index + 1)
                )
                continue
            }

            events.append(
                RawSourceEvent(
                    sessionID: sessionID,
                    turnID: record.metadata["turn_id"],
                    itemID: record.metadata["item_id"],
                    kind: mapping.kind,
                    eventTime: timestamp,
                    observedAt: observedAt,
                    source: id,
                    durationMilliseconds: record.metadata["duration_ms"]
                        .flatMap { Int($0) },
                    errorCode: mapping.includesErrorCode
                        ? record.metadata["error_code"]
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

    private func eventMapping(for eventName: String) -> DesktopEventMapping? {
        if eventName == "chatgpt_turn_started" {
            return DesktopEventMapping(kind: .turnStarted)
        }
        if eventName == "chatgpt_response_routed" {
            return DesktopEventMapping(kind: .modelActivity)
        }
        if eventName == "chatgpt_pubsub_transport_closed" {
            return DesktopEventMapping(kind: .transportRetry, includesErrorCode: true)
        }
        if eventName == "chatgpt_pubsub_transport_opened" {
            return DesktopEventMapping(kind: .transportRecovered)
        }
        if eventName == "chatgpt_item_completed" {
            return DesktopEventMapping(kind: .modelActivity)
        }
        return nil
    }

    private func structuralRecord(for line: String) -> DesktopStructuralRecord? {
        let tokens = line.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count >= 3 else {
            return nil
        }

        var metadata: [String: String] = [:]
        for token in tokens.dropFirst(3) {
            guard let separator = token.firstIndex(of: "=") else {
                break
            }
            let name = String(token[..<separator])
            guard DesktopStructuralRecord.allowedMetadataNames.contains(name) else {
                break
            }
            let valueStart = token.index(after: separator)
            metadata[name] = unquoted(String(token[valueStart...]))
        }

        return DesktopStructuralRecord(
            timestamp: String(tokens[0]),
            eventName: String(tokens[2]),
            metadata: metadata
        )
    }

    private func unquoted(_ token: String) -> String {
        var value = token
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

private struct DesktopStructuralRecord {
    static let allowedMetadataNames: Set<String> = [
        "session_id",
        "turn_id",
        "item_id",
        "duration_ms",
        "error_code",
        "code",
    ]

    let timestamp: String
    let eventName: String
    let metadata: [String: String]
}
