import Foundation

public struct RawSourceEvent: Codable, Hashable, Sendable {
    public let sessionID: String
    public let turnID: String?
    public let itemID: String?
    public let kind: ObservedEvent.Kind
    public let eventTime: Date
    public let observedAt: Date
    public let source: EvidenceSource
    public let toolName: String?
    public let durationMilliseconds: Int?
    public let errorCode: String?
    public let structuredPlan: StructuredPlanPayload?

    public init(
        sessionID: String,
        turnID: String?,
        itemID: String?,
        kind: ObservedEvent.Kind,
        eventTime: Date,
        observedAt: Date,
        source: EvidenceSource,
        toolName: String? = nil,
        durationMilliseconds: Int? = nil,
        errorCode: String? = nil,
        structuredPlan: StructuredPlanPayload? = nil
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.itemID = itemID
        self.kind = kind
        self.eventTime = eventTime
        self.observedAt = observedAt
        self.source = source
        self.toolName = toolName
        self.durationMilliseconds = durationMilliseconds
        self.errorCode = errorCode
        self.structuredPlan = structuredPlan
    }
}

public struct EvidenceAssessment: Codable, Hashable, Sendable {
    public let grade: EvidenceGrade
    public let sources: [EvidenceSource]
    public let conflictingSources: [EvidenceSource]

    public init(
        grade: EvidenceGrade,
        sources: [EvidenceSource],
        conflictingSources: [EvidenceSource]
    ) {
        self.grade = grade
        self.sources = sources
        self.conflictingSources = conflictingSources
    }

    public var canTriggerBlockedNotification: Bool {
        conflictingSources.isEmpty && (grade == .high || grade == .medium)
    }
}

public struct EvidenceNormalizationResult: Codable, Hashable, Sendable {
    public let events: [ObservedEvent]
    public let assessment: EvidenceAssessment

    public init(events: [ObservedEvent], assessment: EvidenceAssessment) {
        self.events = events
        self.assessment = assessment
    }
}

public struct EvidenceNormalizer: Sendable {
    public init() {}

    public func normalize(_ rawEvents: [RawSourceEvent]) -> EvidenceNormalizationResult {
        let conflictsByIdentity = terminalConflicts(in: rawEvents)
        let grouped = Dictionary(grouping: rawEvents, by: DeduplicationKey.init)

        let events = grouped.values.map { group in
            normalize(group, conflictsByIdentity: conflictsByIdentity)
        }.sorted(by: eventPrecedes)

        let triggeringEvent = latestEvent(in: events)
        let sources = triggeringEvent?.evidence.sources ?? []
        let conflictingSources: [EvidenceSource] = triggeringEvent.flatMap {
            event -> [EvidenceSource]? in
            guard event.kind.isTerminal else {
                return nil
            }
            return conflictsByIdentity[EventIdentityKey(event)]
        } ?? []
        let grade = triggeringEvent?.evidence.grade ?? .unknown

        return EvidenceNormalizationResult(
            events: events,
            assessment: EvidenceAssessment(
                grade: grade,
                sources: sources,
                conflictingSources: conflictingSources
            )
        )
    }

    private func normalize(
        _ group: [RawSourceEvent],
        conflictsByIdentity: [EventIdentityKey: [EvidenceSource]]
    ) -> ObservedEvent {
        let canonical = canonicalEvent(in: group)
        let corroboratingSources = orderedSources(group.map(\.source))
        let identity = EventIdentityKey(canonical)
        let conflictingSources = canonical.kind.isTerminal
            ? conflictsByIdentity[identity]
            : nil
        let evidenceSources = conflictingSources ?? corroboratingSources
        let evidenceGrade: EvidenceGrade = conflictingSources == nil
            ? grade(for: corroboratingSources)
            : .unknown
        let planCompletion = canonical.structuredPlan.flatMap {
            PlanProgressExtractor().extract(from: .structured($0))
        }

        return ObservedEvent(
            sessionID: canonical.sessionID,
            turnID: canonical.turnID,
            itemID: canonical.itemID,
            kind: canonical.kind,
            eventTime: canonical.eventTime,
            observedAt: canonical.observedAt,
            evidence: Evidence(grade: evidenceGrade, sources: evidenceSources),
            planCompletion: planCompletion
        )
    }

    private func canonicalEvent(in group: [RawSourceEvent]) -> RawSourceEvent {
        group.enumerated().min { left, right in
            let leftRank = sourceTier(left.element.source)
            let rightRank = sourceTier(right.element.source)
            if leftRank != rightRank {
                return leftRank < rightRank
            }
            if left.element.observedAt != right.element.observedAt {
                return left.element.observedAt > right.element.observedAt
            }
            if left.element.eventTime != right.element.eventTime {
                return left.element.eventTime > right.element.eventTime
            }
            return left.offset < right.offset
        }!.element
    }

    private func terminalConflicts(
        in rawEvents: [RawSourceEvent]
    ) -> [EventIdentityKey: [EvidenceSource]] {
        let terminalEvents = rawEvents.filter { $0.kind.isTerminal }
        let grouped = Dictionary(grouping: terminalEvents, by: EventIdentityKey.init)

        return grouped.reduce(into: [:]) { result, entry in
            let distinctKinds = Set(entry.value.map(\.kind))
            guard distinctKinds.count > 1 else {
                return
            }
            result[entry.key] = orderedSources(entry.value.map(\.source))
        }
    }

    private func grade(for sources: [EvidenceSource]) -> EvidenceGrade {
        guard let strongest = sources.min(by: { sourceTier($0) < sourceTier($1) }) else {
            return .unknown
        }

        switch strongest {
        case .appServer:
            return .high
        case .stateDatabase, .rollout, .desktopLog:
            return .medium
        case .processProbe, .networkProbe:
            return .low
        }
    }

    private func orderedSources(_ sources: [EvidenceSource]) -> [EvidenceSource] {
        Array(Set(sources)).sorted { left, right in
            sourceOrder(left) < sourceOrder(right)
        }
    }

    private func sourceTier(_ source: EvidenceSource) -> Int {
        switch source {
        case .appServer:
            return 0
        case .stateDatabase:
            return 1
        case .rollout, .desktopLog:
            return 2
        case .processProbe, .networkProbe:
            return 3
        }
    }

    private func sourceOrder(_ source: EvidenceSource) -> Int {
        switch source {
        case .appServer:
            return 0
        case .stateDatabase:
            return 1
        case .rollout:
            return 2
        case .desktopLog:
            return 3
        case .processProbe:
            return 4
        case .networkProbe:
            return 5
        }
    }

    private func eventPrecedes(_ left: ObservedEvent, _ right: ObservedEvent) -> Bool {
        if left.eventTime != right.eventTime {
            return left.eventTime < right.eventTime
        }
        if left.sessionID != right.sessionID {
            return left.sessionID < right.sessionID
        }
        if left.turnID != right.turnID {
            return optionalIdentifierPrecedes(left.turnID, right.turnID)
        }
        if left.itemID != right.itemID {
            return optionalIdentifierPrecedes(left.itemID, right.itemID)
        }
        return semanticKindRank(left.kind) < semanticKindRank(right.kind)
    }

    private func latestEvent(in events: [ObservedEvent]) -> ObservedEvent? {
        events.max { left, right in
            if left.eventTime != right.eventTime {
                return left.eventTime < right.eventTime
            }
            if left.observedAt != right.observedAt {
                return left.observedAt < right.observedAt
            }
            return eventPrecedes(left, right)
        }
    }

    private func optionalIdentifierPrecedes(_ left: String?, _ right: String?) -> Bool {
        switch (left, right) {
        case (nil, nil):
            return false
        case (nil, .some(_)):
            return true
        case (.some(_), nil):
            return false
        case let (.some(leftValue), .some(rightValue)):
            return leftValue < rightValue
        }
    }

    private func semanticKindRank(_ kind: ObservedEvent.Kind) -> String {
        switch kind {
        case .turnStarted:
            return "00"
        case .modelActivity:
            return "01"
        case let .toolStarted(processID):
            return "02-\(processID)"
        case let .processAlive(processID):
            return "03-\(processID)"
        case .waitingForApproval:
            return "04"
        case .waitingForUser:
            return "05"
        case .contextCompaction:
            return "06"
        case .transportRetry:
            return "07"
        case .transportRecovered:
            return "08"
        case .completed:
            return "09"
        case .failed:
            return "10"
        case .interrupted:
            return "11"
        }
    }
}

private struct DeduplicationKey: Hashable {
    let sessionID: String
    let turnID: String?
    let itemID: String?
    let semanticKind: ObservedEvent.Kind
    let roundedEventSecond: Int64

    init(_ event: RawSourceEvent) {
        sessionID = event.sessionID
        turnID = event.turnID
        itemID = event.itemID
        semanticKind = event.kind
        roundedEventSecond = Int64(event.eventTime.timeIntervalSince1970.rounded())
    }
}

private struct EventIdentityKey: Hashable {
    let sessionID: String
    let turnID: String?
    let itemID: String?
    let roundedEventSecond: Int64

    init(_ event: RawSourceEvent) {
        sessionID = event.sessionID
        turnID = event.turnID
        itemID = event.itemID
        roundedEventSecond = Int64(event.eventTime.timeIntervalSince1970.rounded())
    }

    init(_ event: ObservedEvent) {
        sessionID = event.sessionID
        turnID = event.turnID
        itemID = event.itemID
        roundedEventSecond = Int64(event.eventTime.timeIntervalSince1970.rounded())
    }
}
