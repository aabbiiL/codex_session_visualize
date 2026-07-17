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

    func testAssessmentEligibilityUsesLatestNormalizedEventInsteadOfOlderStrongestSource() {
        let result = normalizer.normalize([
            .fixture(
                kind: .modelActivity,
                source: .appServer,
                eventTime: base
            ),
            .fixture(
                kind: .processAlive(42),
                source: .processProbe,
                eventTime: base.addingTimeInterval(2)
            ),
        ])

        XCTAssertEqual(result.events.count, 2)
        XCTAssertEqual(result.events.last?.evidence.grade, .low)
        XCTAssertEqual(result.assessment.grade, .low)
        XCTAssertFalse(result.assessment.canTriggerBlockedNotification)
    }

    func testEveryDeduplicationIdentityComponentKeepsEventsDistinct() {
        let cases: [(String, RawSourceEvent, RawSourceEvent)] = [
            (
                "sessionID",
                .fixture(source: .appServer, sessionID: "session-a"),
                .fixture(source: .rollout, sessionID: "session-b")
            ),
            (
                "turnID",
                .fixture(source: .appServer, turnID: "turn-a"),
                .fixture(source: .rollout, turnID: "turn-b")
            ),
            (
                "itemID",
                .fixture(source: .appServer, itemID: "item-a"),
                .fixture(source: .rollout, itemID: "item-b")
            ),
            (
                "semanticKind",
                .fixture(kind: .turnStarted, source: .appServer),
                .fixture(kind: .modelActivity, source: .rollout)
            ),
        ]

        for (component, first, second) in cases {
            XCTAssertEqual(
                normalizer.normalize([first, second]).events.count,
                2,
                "Expected distinct \(component) values to prevent deduplication"
            )
        }
    }

    func testEventTimesWithinSameRoundedSecondDeduplicate() {
        let result = normalizer.normalize([
            .fixture(
                source: .appServer,
                eventTime: base.addingTimeInterval(0.01)
            ),
            .fixture(
                source: .rollout,
                eventTime: base.addingTimeInterval(0.49)
            ),
        ])

        XCTAssertEqual(result.events.count, 1)
    }

    func testEventTimesAcrossRoundedSecondBoundaryStayDistinct() {
        let result = normalizer.normalize([
            .fixture(
                source: .appServer,
                eventTime: base.addingTimeInterval(0.49)
            ),
            .fixture(
                source: .rollout,
                eventTime: base.addingTimeInterval(0.51)
            ),
        ])

        XCTAssertEqual(result.events.count, 2)
    }

    func testEverySourceMapsToItsRequiredEvidenceTier() {
        let cases: [(EvidenceSource, EvidenceGrade)] = [
            (.appServer, .high),
            (.stateDatabase, .medium),
            (.rollout, .medium),
            (.desktopLog, .medium),
            (.processProbe, .low),
            (.networkProbe, .low),
        ]

        for (source, expectedGrade) in cases {
            let result = normalizer.normalize([.fixture(source: source)])
            XCTAssertEqual(
                result.events.first?.evidence.grade,
                expectedGrade,
                "Unexpected evidence grade for \(source)"
            )
        }
    }

    func testEveryHigherPrecedenceTierKeepsCanonicalFieldsAgainstNewerLowerTierSource() {
        let precedencePairs: [(EvidenceSource, EvidenceSource)] = [
            (.appServer, .stateDatabase),
            (.stateDatabase, .rollout),
            (.stateDatabase, .desktopLog),
            (.rollout, .processProbe),
            (.rollout, .networkProbe),
            (.desktopLog, .processProbe),
            (.desktopLog, .networkProbe),
        ]
        let higherEventTime = base.addingTimeInterval(0.10)
        let higherObservedAt = base.addingTimeInterval(1)
        let lowerEventTime = base.addingTimeInterval(0.20)
        let lowerObservedAt = base.addingTimeInterval(100)

        for (higher, lower) in precedencePairs {
            let result = normalizer.normalize([
                .fixture(
                    source: higher,
                    eventTime: higherEventTime,
                    observedAt: higherObservedAt
                ),
                .fixture(
                    source: lower,
                    eventTime: lowerEventTime,
                    observedAt: lowerObservedAt
                ),
            ])

            XCTAssertEqual(result.events.count, 1)
            XCTAssertEqual(
                result.events.first?.eventTime,
                higherEventTime,
                "Lower-tier \(lower) replaced canonical \(higher) event time"
            )
            XCTAssertEqual(
                result.events.first?.observedAt,
                higherObservedAt,
                "Lower-tier \(lower) replaced canonical \(higher) observation time"
            )
        }
    }

    func testEqualPrecedenceSourcesUseTheNewerObservationAsCanonical() {
        let cases: [(EvidenceSource, EvidenceSource)] = [
            (.rollout, .desktopLog),
            (.processProbe, .networkProbe),
        ]
        let olderEventTime = base.addingTimeInterval(0.10)
        let newerEventTime = base.addingTimeInterval(0.20)

        for (olderSource, newerSource) in cases {
            let result = normalizer.normalize([
                .fixture(
                    source: olderSource,
                    eventTime: olderEventTime,
                    observedAt: base.addingTimeInterval(1)
                ),
                .fixture(
                    source: newerSource,
                    eventTime: newerEventTime,
                    observedAt: base.addingTimeInterval(2)
                ),
            ])

            XCTAssertEqual(result.events.count, 1)
            XCTAssertEqual(result.events.first?.eventTime, newerEventTime)
            XCTAssertEqual(
                result.events.first?.observedAt,
                base.addingTimeInterval(2)
            )
        }
    }
}

private extension RawSourceEvent {
    static func fixture(
        kind: ObservedEvent.Kind = .turnStarted,
        source: EvidenceSource,
        eventTime: Date = base,
        observedAt: Date? = nil,
        sessionID: String = "session-1",
        turnID: String? = "turn-1",
        itemID: String? = "item-1"
    ) -> RawSourceEvent {
        RawSourceEvent(
            sessionID: sessionID,
            turnID: turnID,
            itemID: itemID,
            kind: kind,
            eventTime: eventTime,
            observedAt: observedAt ?? eventTime,
            source: source,
            structuredPlan: nil
        )
    }
}
