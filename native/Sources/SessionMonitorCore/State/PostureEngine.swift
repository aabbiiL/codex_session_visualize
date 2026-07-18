import Foundation

public struct PostureEngine: Sendable {
    public let policy: ThresholdPolicy

    public init(policy: ThresholdPolicy) {
        self.policy = policy
    }

    public func evaluate(
        session: SessionDescriptor,
        events: [ObservedEvent],
        now: Date
    ) -> SessionPosture {
        guard let latest = latestEvent(in: events) else {
            return unknownPosture(
                session: session,
                evidence: Evidence(grade: .unknown, sources: []),
                lastActivityAt: session.lastActivityAt,
                phaseStartedAt: session.lastActivityAt,
                planCompletion: nil,
                now: now
            )
        }

        let planCompletion = latestPlanCompletion(in: events)
        if latest.kind.isTerminal {
            return terminalPosture(
                session: session,
                event: latest,
                planCompletion: planCompletion,
                now: now
            )
        }

        let evidence = latest.evidence
        if evidence.isConflicting || evidence.isInsufficient {
            return unknownPosture(
                session: session,
                evidence: evidence,
                lastActivityAt: latest.eventTime,
                phaseStartedAt: latest.eventTime,
                planCompletion: planCompletion,
                now: now
            )
        }

        if latest.kind == .waitingForApproval || latest.kind == .waitingForUser {
            return waitingPosture(
                session: session,
                event: latest,
                planCompletion: planCompletion,
                now: now
            )
        }

        if latest.kind.isTransportRetry {
            return transportPosture(
                session: session,
                event: latest,
                planCompletion: planCompletion,
                now: now
            )
        }

        if let activeTool = latestActiveTool(in: events) {
            return toolPosture(
                session: session,
                activeTool: activeTool,
                latest: latest,
                planCompletion: planCompletion,
                now: now
            )
        }

        if latest.kind.isModelActivity || latest.kind == .turnStarted {
            return modelPosture(
                session: session,
                event: latest,
                planCompletion: planCompletion,
                now: now
            )
        }

        return startingOrUnknownPosture(
            session: session,
            event: latest,
            planCompletion: planCompletion,
            now: now
        )
    }

    private func terminalPosture(
        session: SessionDescriptor,
        event: ObservedEvent,
        planCompletion: PlanCompletion?,
        now: Date
    ) -> SessionPosture {
        let phase: ExecutionPhase
        let health: PostureHealth
        let guidance: PostureGuidance?

        switch event.kind {
        case .completed:
            phase = .completed
            health = .normal
            guidance = nil
        case .failed:
            phase = .failed
            health = .failed
            guidance = .sessionFailed
        case .interrupted:
            phase = .interrupted
            health = .normal
            guidance = nil
        default:
            return unknownPosture(
                session: session,
                evidence: event.evidence,
                lastActivityAt: event.eventTime,
                phaseStartedAt: event.eventTime,
                planCompletion: planCompletion,
                now: now
            )
        }

        return posture(
            session: session,
            phase: phase,
            health: health,
            lastActivityAt: event.eventTime,
            phaseStartedAt: event.eventTime,
            evidence: event.evidence,
            planCompletion: planCompletion,
            guidance: guidance,
            now: now
        )
    }

    private func waitingPosture(
        session: SessionDescriptor,
        event: ObservedEvent,
        planCompletion: PlanCompletion?,
        now: Date
    ) -> SessionPosture {
        let duration = elapsed(since: event.eventTime, now: now)
        let health: PostureHealth = duration >= policy.waitingActionRequiredAfter ? .actionRequired : .normal
        let phase: ExecutionPhase
        let guidance: PostureGuidance

        if event.kind == .waitingForApproval {
            phase = .waitingForApproval
            guidance = .approvalRequired
        } else {
            phase = .waitingForUser
            guidance = .userInputRequired
        }

        return posture(
            session: session,
            phase: phase,
            health: health,
            lastActivityAt: event.eventTime,
            phaseStartedAt: event.eventTime,
            evidence: event.evidence,
            planCompletion: planCompletion,
            guidance: guidance,
            now: now
        )
    }

    private func transportPosture(
        session: SessionDescriptor,
        event: ObservedEvent,
        planCompletion: PlanCompletion?,
        now: Date
    ) -> SessionPosture {
        let duration = elapsed(since: event.eventTime, now: now)
        let health: PostureHealth
        let guidance: PostureGuidance?

        if duration >= policy.transportBlockedAfter {
            health = .blocked
            guidance = .connectionBlocked
        } else if duration >= policy.transportDegradedAfter {
            health = .connectionDegraded
            guidance = .connectionDegraded
        } else {
            health = .normal
            guidance = nil
        }

        return posture(
            session: session,
            phase: .transportRetry,
            health: health,
            lastActivityAt: event.eventTime,
            phaseStartedAt: event.eventTime,
            evidence: event.evidence,
            planCompletion: planCompletion,
            guidance: guidance,
            now: now
        )
    }

    private func toolPosture(
        session: SessionDescriptor,
        activeTool: ActiveTool,
        latest: ObservedEvent,
        planCompletion: PlanCompletion?,
        now: Date
    ) -> SessionPosture {
        let duration = elapsed(since: activeTool.started.eventTime, now: now)
        let currentLiveness = activeTool.liveness.flatMap { liveness in
            liveness.observedAt == now ? liveness : nil
        }
        let evidence = combinedToolEvidence(
            start: activeTool.started.evidence,
            currentLiveness: currentLiveness?.evidence
        )
        if evidence.isConflicting || evidence.isInsufficient {
            return unknownPosture(
                session: session,
                evidence: evidence,
                lastActivityAt: latest.eventTime,
                phaseStartedAt: activeTool.started.eventTime,
                planCompletion: planCompletion,
                now: now
            )
        }

        let isLongRunning = currentLiveness != nil && duration >= policy.toolLongRunningAfter

        return posture(
            session: session,
            phase: .toolExecuting,
            health: isLongRunning ? .longRunning : .normal,
            lastActivityAt: latest.eventTime,
            phaseStartedAt: activeTool.started.eventTime,
            evidence: evidence,
            planCompletion: planCompletion,
            guidance: isLongRunning ? .toolLongRunning : nil,
            now: now
        )
    }

    private func modelPosture(
        session: SessionDescriptor,
        event: ObservedEvent,
        planCompletion: PlanCompletion?,
        now: Date
    ) -> SessionPosture {
        let duration = elapsed(since: event.eventTime, now: now)
        let health: PostureHealth
        let guidance: PostureGuidance?

        if duration >= policy.modelBlockedAfter {
            health = .blocked
            guidance = .modelBlocked
        } else if duration >= policy.modelSuspectedStallAfter {
            health = .suspectedStall
            guidance = .modelSuspectedStall
        } else {
            health = .normal
            guidance = nil
        }

        return posture(
            session: session,
            phase: .modelProcessing,
            health: health,
            lastActivityAt: event.eventTime,
            phaseStartedAt: event.eventTime,
            evidence: event.evidence,
            planCompletion: planCompletion,
            guidance: guidance,
            now: now
        )
    }

    private func startingOrUnknownPosture(
        session: SessionDescriptor,
        event: ObservedEvent,
        planCompletion: PlanCompletion?,
        now: Date
    ) -> SessionPosture {
        if event.kind == .contextCompaction {
            return posture(
                session: session,
                phase: .contextCompaction,
                health: .normal,
                lastActivityAt: event.eventTime,
                phaseStartedAt: event.eventTime,
                evidence: event.evidence,
                planCompletion: planCompletion,
                guidance: nil,
                now: now
            )
        }

        return unknownPosture(
            session: session,
            evidence: event.evidence,
            lastActivityAt: event.eventTime,
            phaseStartedAt: event.eventTime,
            planCompletion: planCompletion,
            now: now
        )
    }

    private func unknownPosture(
        session: SessionDescriptor,
        evidence: Evidence,
        lastActivityAt: Date,
        phaseStartedAt: Date,
        planCompletion: PlanCompletion?,
        now: Date
    ) -> SessionPosture {
        posture(
            session: session,
            phase: .unknown,
            health: .unknown,
            lastActivityAt: lastActivityAt,
            phaseStartedAt: phaseStartedAt,
            evidence: evidence,
            planCompletion: planCompletion,
            guidance: nil,
            now: now
        )
    }

    private func posture(
        session: SessionDescriptor,
        phase: ExecutionPhase,
        health: PostureHealth,
        lastActivityAt: Date,
        phaseStartedAt: Date,
        evidence: Evidence,
        planCompletion: PlanCompletion?,
        guidance: PostureGuidance?,
        now: Date
    ) -> SessionPosture {
        SessionPosture(
            sessionID: session.id,
            title: session.title,
            workspacePath: session.workspacePath,
            phase: phase,
            health: health,
            lastActivityAt: lastActivityAt,
            phaseStartedAt: phaseStartedAt,
            duration: elapsed(since: phaseStartedAt, now: now),
            blocker: guidance?.blocker,
            recommendation: guidance?.recommendation,
            evidenceGrade: evidence.grade,
            evidenceSources: evidence.sources,
            planCompletion: planCompletion
        )
    }

    private func latestEvent(in events: [ObservedEvent]) -> ObservedEvent? {
        indexedEvents(in: events)
            .max { eventPrecedes($0, $1) }?
            .event
    }

    private func latestPlanCompletion(in events: [ObservedEvent]) -> PlanCompletion? {
        indexedEvents(in: events)
            .filter { $0.event.planCompletion != nil }
            .max { eventPrecedes($0, $1) }?
            .event
            .planCompletion
    }

    private func latestActiveTool(in events: [ObservedEvent]) -> ActiveTool? {
        let orderedEvents = indexedEvents(in: events)
        let starts = orderedEvents.compactMap { indexedEvent -> (IndexedEvent, Int32)? in
            guard case let .toolStarted(processID) = indexedEvent.event.kind else {
                return nil
            }
            return (indexedEvent, processID)
        }
        guard let latestStart = starts.max(by: { eventPrecedes($0.0, $1.0) }) else {
            return nil
        }

        let wasSuperseded = orderedEvents.contains { indexedEvent in
            eventSupersedesTool(indexedEvent.event.kind)
                && eventOccursAfter(indexedEvent, latestStart.0)
        }
        if wasSuperseded {
            return nil
        }

        let liveness = orderedEvents.filter { indexedEvent in
            guard case let .processAlive(processID) = indexedEvent.event.kind else {
                return false
            }
            return processID == latestStart.1
                && eventOccursAfter(indexedEvent, latestStart.0)
        }.max { eventPrecedes($0, $1) }

        return ActiveTool(started: latestStart.0.event, liveness: liveness?.event)
    }

    private func eventSupersedesTool(_ kind: ObservedEvent.Kind) -> Bool {
        switch kind {
        case .turnStarted,
             .modelActivity,
             .waitingForApproval,
             .waitingForUser,
             .contextCompaction,
             .transportRetry,
             .transportRecovered,
             .completed,
             .failed,
             .interrupted:
            return true
        case .toolStarted, .processAlive:
            return false
        }
    }

    private func indexedEvents(in events: [ObservedEvent]) -> [IndexedEvent] {
        events.enumerated().map { offset, event in
            IndexedEvent(offset: offset, event: event)
        }
    }

    private func eventPrecedes(_ left: IndexedEvent, _ right: IndexedEvent) -> Bool {
        if left.event.eventTime != right.event.eventTime {
            return left.event.eventTime < right.event.eventTime
        }
        if left.event.observedAt != right.event.observedAt {
            return left.event.observedAt < right.event.observedAt
        }
        return left.offset < right.offset
    }

    private func eventOccursAfter(_ event: IndexedEvent, _ reference: IndexedEvent) -> Bool {
        eventPrecedes(reference, event)
    }

    private func combinedToolEvidence(
        start: Evidence,
        currentLiveness: Evidence?
    ) -> Evidence {
        let prerequisites = [start, currentLiveness].compactMap { $0 }
        let grade: EvidenceGrade
        if prerequisites.contains(where: { $0.grade == .unknown }) {
            grade = .unknown
        } else if prerequisites.contains(where: { $0.grade == .low }) {
            grade = .low
        } else if prerequisites.contains(where: { $0.grade == .medium }) {
            grade = .medium
        } else {
            grade = .high
        }

        var seenSources: Set<EvidenceSource> = []
        let sources = prerequisites.flatMap { $0.sources }.filter { source in
            seenSources.insert(source).inserted
        }
        return Evidence(grade: grade, sources: sources)
    }

    private func elapsed(since date: Date, now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(date))
    }
}

private struct ActiveTool {
    let started: ObservedEvent
    let liveness: ObservedEvent?
}

private struct IndexedEvent {
    let offset: Int
    let event: ObservedEvent
}
