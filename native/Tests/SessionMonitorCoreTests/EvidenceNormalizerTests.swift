import Foundation
import XCTest
@testable import SessionMonitorCore

final class EvidenceNormalizerTests: XCTestCase {
    private let normalizer = EvidenceNormalizer()

    func testMatchingAppServerAndRolloutEventsCollapseWithHighCorroboratedEvidence() {
        let result = normalizer.normalize([
            .fixture(source: .rollout),
            .fixture(source: .appServer),
        ])

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.kind, .turnStarted)
        XCTAssertEqual(result.events.first?.evidence.grade, .high)
        XCTAssertEqual(result.events.first?.evidence.sources, [.appServer, .rollout])
        XCTAssertEqual(result.assessment.grade, .high)
        XCTAssertEqual(result.assessment.sources, [.appServer, .rollout])
    }

    func testContradictoryTerminalStatesReturnUnknownConflictWithEverySource() {
        let result = normalizer.normalize([
            .fixture(kind: .completed, source: .appServer),
            .fixture(kind: .failed, source: .stateDatabase),
        ])

        XCTAssertEqual(result.assessment.grade, .unknown)
        XCTAssertEqual(result.assessment.conflictingSources, [.appServer, .stateDatabase])
        XCTAssertFalse(result.assessment.canTriggerBlockedNotification)
        XCTAssertFalse(result.events.isEmpty)
        XCTAssertTrue(result.events.allSatisfy { $0.evidence.grade == .unknown })
    }

    func testProcessOnlyInferenceStaysLowAndCannotTriggerBlockedNotification() {
        let result = normalizer.normalize([
            .fixture(kind: .processAlive(42), source: .processProbe),
        ])

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.evidence.grade, .low)
        XCTAssertEqual(result.events.first?.evidence.sources, [.processProbe])
        XCTAssertEqual(result.assessment.grade, .low)
        XCTAssertFalse(result.assessment.canTriggerBlockedNotification)
    }
}

private extension RawSourceEvent {
    static func fixture(
        kind: ObservedEvent.Kind = .turnStarted,
        source: EvidenceSource,
        eventTime: Date = base
    ) -> RawSourceEvent {
        RawSourceEvent(
            sessionID: "session-1",
            turnID: "turn-1",
            itemID: "item-1",
            kind: kind,
            eventTime: eventTime,
            observedAt: eventTime,
            source: source,
            structuredPlan: nil
        )
    }
}
