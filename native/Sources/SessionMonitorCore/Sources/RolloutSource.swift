import Foundation

public struct RolloutSource: EventSource {
    public let id: EvidenceSource = .rollout

    private let session: SessionDescriptor
    private let reader: IncrementalFileReader
    private let contextStore: RolloutContextStore

    public init(
        session: SessionDescriptor,
        reader: IncrementalFileReader = IncrementalFileReader()
    ) {
        self.session = session
        self.reader = reader
        self.contextStore = RolloutContextStore(sessionID: session.id)
    }

    public func poll(since cursor: SourceCursor?) async -> SourcePollResult {
        guard let rolloutPath = session.rolloutPath else {
            return SourcePollResult.degraded(
                issue: .missingFile(path: "<missing-rollout-path>")
            )
        }

        let fileURL = URL(fileURLWithPath: rolloutPath)
        let fileCursor = cursor?.source == id ? cursor?.filePosition : nil
        let read = await reader.readLines(at: fileURL, since: fileCursor)
        var context = await contextStore.snapshot(
            reset: fileCursor == nil || read.rotation != nil
        )
        var events: [RawSourceEvent] = []
        var issues = sourceIssues(from: read.issues, path: fileURL.path)
        let observedAt = Date()

        for (index, line) in read.lines.enumerated() where !line.isEmpty {
            do {
                let record = try JSONDecoder().decode(RolloutOuterRecord.self, from: line)
                guard let eventTime = parseTimestamp(record.timestamp) else {
                    issues.append(
                        .malformedLine(path: fileURL.path, lineNumber: index + 1)
                    )
                    continue
                }
                if let event = map(
                    record,
                    eventTime: eventTime,
                    observedAt: observedAt,
                    context: &context
                ) {
                    events.append(event)
                }
            } catch {
                issues.append(
                    .malformedLine(path: fileURL.path, lineNumber: index + 1)
                )
            }
        }
        await contextStore.store(context)

        return SourcePollResult(
            events: events,
            health: SourceHealth(
                status: issues.isEmpty ? .healthy : .degraded,
                issues: issues
            ),
            cursor: SourceCursor(source: id, filePosition: read.cursor)
        )
    }

    private func map(
        _ record: RolloutOuterRecord,
        eventTime: Date,
        observedAt: Date,
        context: inout RolloutContext
    ) -> RawSourceEvent? {
        let payload = record.payload
        switch record.type {
        case "session_meta":
            context.sessionID = payload.id ?? payload.sessionID ?? context.sessionID
            return nil
        case "turn_context":
            context.sessionID = payload.sessionID ?? context.sessionID
            context.turnID = payload.turnID ?? context.turnID
            return nil
        case "event_msg":
            return mapEventMessage(
                payload,
                eventTime: eventTime,
                observedAt: observedAt,
                context: context
            )
        case "response_item":
            return mapResponseItem(
                payload,
                eventTime: eventTime,
                observedAt: observedAt,
                context: context
            )
        default:
            return nil
        }
    }

    private func mapEventMessage(
        _ payload: RolloutPayload,
        eventTime: Date,
        observedAt: Date,
        context: RolloutContext
    ) -> RawSourceEvent? {
        let kind: ObservedEvent.Kind
        let structuredPlan: StructuredPlanPayload?
        guard let payloadType = payload.type else {
            return nil
        }
        switch payloadType {
        case "task_started":
            kind = .turnStarted
            structuredPlan = nil
        case "agent_reasoning":
            kind = .modelActivity
            structuredPlan = nil
        case "plan_update":
            kind = .modelActivity
            structuredPlan = payload.plan.map { steps in
                StructuredPlanPayload(
                    steps: steps.map { StructuredPlanStep(status: $0.status) }
                )
            }
        case "task_complete":
            kind = .completed
            structuredPlan = nil
        default:
            return nil
        }

        return rawEvent(
            payload: payload,
            kind: kind,
            eventTime: eventTime,
            observedAt: observedAt,
            context: context,
            structuredPlan: structuredPlan
        )
    }

    private func mapResponseItem(
        _ payload: RolloutPayload,
        eventTime: Date,
        observedAt: Date,
        context: RolloutContext
    ) -> RawSourceEvent? {
        guard let payloadType = payload.type else {
            return nil
        }
        switch payloadType {
        case "function_call":
            return rawEvent(
                payload: payload,
                kind: .toolStarted(processID: payload.processID),
                eventTime: eventTime,
                observedAt: observedAt,
                context: context,
                toolName: payload.name
            )
        case "function_call_output":
            return rawEvent(
                payload: payload,
                kind: .modelActivity,
                eventTime: eventTime,
                observedAt: observedAt,
                context: context,
                durationMilliseconds: payload.durationMilliseconds
            )
        default:
            return nil
        }
    }

    private func rawEvent(
        payload: RolloutPayload,
        kind: ObservedEvent.Kind,
        eventTime: Date,
        observedAt: Date,
        context: RolloutContext,
        toolName: String? = nil,
        durationMilliseconds: Int? = nil,
        structuredPlan: StructuredPlanPayload? = nil
    ) -> RawSourceEvent {
        RawSourceEvent(
            sessionID: payload.sessionID ?? context.sessionID,
            turnID: payload.turnID ?? context.turnID,
            itemID: payload.itemID,
            kind: kind,
            eventTime: eventTime,
            observedAt: observedAt,
            source: id,
            toolName: toolName,
            durationMilliseconds: durationMilliseconds,
            structuredPlan: structuredPlan
        )
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

private struct RolloutContext: Sendable {
    var sessionID: String
    var turnID: String?
}

private actor RolloutContextStore {
    private let descriptorSessionID: String
    private var context: RolloutContext

    init(sessionID: String) {
        descriptorSessionID = sessionID
        context = RolloutContext(sessionID: sessionID, turnID: nil)
    }

    func snapshot(reset: Bool) -> RolloutContext {
        if reset {
            context = RolloutContext(sessionID: descriptorSessionID, turnID: nil)
        }
        return context
    }

    func store(_ context: RolloutContext) {
        self.context = context
    }
}

private struct RolloutOuterRecord: Decodable {
    let timestamp: String
    let type: String
    let payload: RolloutPayload
}

private struct RolloutPayload: Decodable {
    let id: String?
    let sessionID: String?
    let turnID: String?
    let itemID: String?
    let type: String?
    let name: String?
    let processID: Int32?
    let durationMilliseconds: Int?
    let plan: [RolloutPlanStep]?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case turnID = "turn_id"
        case itemID = "item_id"
        case type
        case name
        case processID = "process_id"
        case durationMilliseconds = "duration_ms"
        case plan
    }
}

private struct RolloutPlanStep: Decodable {
    let status: String

    enum CodingKeys: String, CodingKey {
        case status
    }
}
