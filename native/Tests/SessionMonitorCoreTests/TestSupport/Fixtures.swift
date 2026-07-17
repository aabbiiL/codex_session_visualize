import Foundation
@testable import SessionMonitorCore

let base = Date(timeIntervalSince1970: 1_000_000)
let engine = PostureEngine(policy: .defaults)

extension SessionDescriptor {
    static func fixture(
        lastActivityAge: TimeInterval = 0,
        id: String = "session-1",
        title: String? = "Fixture session",
        workspacePath: String? = "/tmp/fixture-workspace"
    ) -> SessionDescriptor {
        SessionDescriptor(
            id: id,
            title: title,
            workspacePath: workspacePath,
            lastActivityAt: base.addingTimeInterval(-lastActivityAge)
        )
    }
}

extension Evidence {
    static func fixture(
        grade: EvidenceGrade = .high,
        sources: [EvidenceSource] = [.appServer]
    ) -> Evidence {
        Evidence(grade: grade, sources: sources)
    }
}

extension ObservedEvent {
    static func fixture(
        kind: ObservedEvent.Kind = .turnStarted,
        at: Date = base,
        sessionID: String = "session-1",
        turnID: String? = "turn-1",
        itemID: String? = nil,
        evidence: Evidence = .fixture(),
        planCompletion: PlanCompletion? = nil
    ) -> ObservedEvent {
        ObservedEvent(
            sessionID: sessionID,
            turnID: turnID,
            itemID: itemID,
            kind: kind,
            eventTime: at,
            observedAt: at,
            evidence: evidence,
            planCompletion: planCompletion
        )
    }
}
