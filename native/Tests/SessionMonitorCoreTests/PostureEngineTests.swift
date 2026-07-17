import Foundation
import XCTest
@testable import SessionMonitorCore

final class PostureEngineTests: XCTestCase {
    func testModelBecomesSuspectedAtThreeMinutesAndBlockedAtTen() {
        let session = SessionDescriptor.fixture(lastActivityAge: 0)
        let event = ObservedEvent.fixture(kind: .modelActivity, at: base)
        XCTAssertEqual(engine.evaluate(session: session, events: [event], now: base.addingTimeInterval(179)).health, .normal)
        XCTAssertEqual(engine.evaluate(session: session, events: [event], now: base.addingTimeInterval(180)).health, .suspectedStall)
        XCTAssertEqual(engine.evaluate(session: session, events: [event], now: base.addingTimeInterval(600)).health, .blocked)
    }

    func testLiveToolIsLongRunningButNotFailed() {
        let event = ObservedEvent.fixture(kind: .toolStarted(processID: 42), at: base)
        let beforeThreshold = engine.evaluate(
            session: .fixture(),
            events: [event, .fixture(kind: .processAlive(42), at: base.addingTimeInterval(299))],
            now: base.addingTimeInterval(299)
        )
        XCTAssertEqual(beforeThreshold.phase, .toolExecuting)
        XCTAssertEqual(beforeThreshold.health, .normal)

        let atThreshold = engine.evaluate(
            session: .fixture(),
            events: [event, .fixture(kind: .processAlive(42), at: base.addingTimeInterval(300))],
            now: base.addingTimeInterval(300)
        )
        XCTAssertEqual(atThreshold.phase, .toolExecuting)
        XCTAssertEqual(atThreshold.health, .longRunning)

        let posture = engine.evaluate(session: .fixture(), events: [event, .fixture(kind: .processAlive(42), at: base.addingTimeInterval(301))], now: base.addingTimeInterval(301))
        XCTAssertEqual(posture.phase, .toolExecuting)
        XCTAssertEqual(posture.health, .longRunning)
    }

    func testLaterModelActivitySupersedesHistoricalToolEvidence() {
        let posture = engine.evaluate(
            session: .fixture(),
            events: [
                .fixture(kind: .toolStarted(processID: 42), at: base),
                .fixture(kind: .processAlive(42), at: base.addingTimeInterval(300)),
                .fixture(kind: .modelActivity, at: base.addingTimeInterval(301)),
            ],
            now: base.addingTimeInterval(301)
        )

        XCTAssertEqual(posture.phase, .modelProcessing)
        XCTAssertEqual(posture.health, .normal)
    }

    func testLaterContextCompactionSupersedesHistoricalToolEvidence() {
        let posture = engine.evaluate(
            session: .fixture(),
            events: [
                .fixture(kind: .toolStarted(processID: 42), at: base),
                .fixture(kind: .processAlive(42), at: base.addingTimeInterval(300)),
                .fixture(kind: .contextCompaction, at: base.addingTimeInterval(301)),
            ],
            now: base.addingTimeInterval(301)
        )

        XCTAssertEqual(posture.phase, .contextCompaction)
        XCTAssertEqual(posture.health, .normal)
    }

    func testStaleProcessAliveDoesNotMakeToolLongRunning() {
        let posture = engine.evaluate(
            session: .fixture(),
            events: [
                .fixture(kind: .toolStarted(processID: 42), at: base),
                .fixture(kind: .processAlive(42), at: base.addingTimeInterval(300)),
            ],
            now: base.addingTimeInterval(301)
        )

        XCTAssertEqual(posture.phase, .toolExecuting)
        XCTAssertEqual(posture.health, .normal)
    }

    func testInsufficientToolStartEvidenceOverridesHighCurrentLiveness() {
        let posture = engine.evaluate(
            session: .fixture(),
            events: [
                .fixture(
                    kind: .toolStarted(processID: 42),
                    at: base,
                    evidence: .fixture(grade: .unknown, sources: [])
                ),
                .fixture(kind: .processAlive(42), at: base.addingTimeInterval(300)),
            ],
            now: base.addingTimeInterval(300)
        )

        XCTAssertEqual(posture.phase, .unknown)
        XCTAssertEqual(posture.health, .unknown)
        XCTAssertEqual(posture.evidenceGrade, .unknown)
    }

    func testConflictingToolStartEvidenceOverridesHighCurrentLiveness() {
        let posture = engine.evaluate(
            session: .fixture(),
            events: [
                .fixture(
                    kind: .toolStarted(processID: 42),
                    at: base,
                    evidence: .fixture(grade: .unknown, sources: [.appServer, .rollout])
                ),
                .fixture(kind: .processAlive(42), at: base.addingTimeInterval(300)),
            ],
            now: base.addingTimeInterval(300)
        )

        XCTAssertEqual(posture.phase, .unknown)
        XCTAssertEqual(posture.health, .unknown)
        XCTAssertEqual(posture.evidenceGrade, .unknown)
    }

    func testApprovalWaitIsActionRequiredAfterFifteenSeconds() {
        let event = ObservedEvent.fixture(kind: .waitingForApproval, at: base)
        XCTAssertEqual(engine.evaluate(session: .fixture(), events: [event], now: base.addingTimeInterval(14)).health, .normal)

        let posture = engine.evaluate(session: .fixture(), events: [event], now: base.addingTimeInterval(15))
        XCTAssertEqual(posture.phase, .waitingForApproval)
        XCTAssertEqual(posture.health, .actionRequired)
        XCTAssertEqual(posture.blocker, "Approval required")
        XCTAssertEqual(posture.recommendation, "Open the session and review the request")
    }

    func testWaitingForUserIsActionRequiredAfterFifteenSeconds() {
        let event = ObservedEvent.fixture(kind: .waitingForUser, at: base)
        XCTAssertEqual(engine.evaluate(session: .fixture(), events: [event], now: base.addingTimeInterval(14)).health, .normal)

        let posture = engine.evaluate(session: .fixture(), events: [event], now: base.addingTimeInterval(15))
        XCTAssertEqual(posture.phase, .waitingForUser)
        XCTAssertEqual(posture.health, .actionRequired)
    }

    func testTransportRetryDegradesAtThirtySecondsAndBlocksAtTwoMinutes() {
        let event = ObservedEvent.fixture(kind: .transportRetry, at: base)
        let session = SessionDescriptor.fixture()

        let atTwentyNine = engine.evaluate(session: session, events: [event], now: base.addingTimeInterval(29))
        XCTAssertEqual(atTwentyNine.phase, .transportRetry)
        XCTAssertEqual(atTwentyNine.health, .normal)

        let atThirty = engine.evaluate(session: session, events: [event], now: base.addingTimeInterval(30))
        XCTAssertEqual(atThirty.phase, .transportRetry)
        XCTAssertEqual(atThirty.health, .connectionDegraded)

        let atOneTwenty = engine.evaluate(session: session, events: [event], now: base.addingTimeInterval(120))
        XCTAssertEqual(atOneTwenty.phase, .transportRetry)
        XCTAssertEqual(atOneTwenty.health, .blocked)
    }

    func testTerminalEventsProduceTerminalPostures() {
        let completed = engine.evaluate(
            session: .fixture(),
            events: [.fixture(kind: .completed, at: base)],
            now: base
        )
        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(completed.health, .normal)

        let failed = engine.evaluate(
            session: .fixture(),
            events: [.fixture(kind: .failed, at: base)],
            now: base
        )
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertEqual(failed.health, .failed)

        let interrupted = engine.evaluate(
            session: .fixture(),
            events: [.fixture(kind: .interrupted, at: base)],
            now: base
        )
        XCTAssertEqual(interrupted.phase, .interrupted)
        XCTAssertEqual(interrupted.health, .normal)
    }

    func testContextCompactionIsAHealthyObservablePhase() {
        let posture = engine.evaluate(
            session: .fixture(),
            events: [.fixture(kind: .contextCompaction, at: base)],
            now: base.addingTimeInterval(45)
        )

        XCTAssertEqual(posture.phase, .contextCompaction)
        XCTAssertEqual(posture.health, .normal)
        XCTAssertEqual(posture.lastActivityAt, base)
        XCTAssertEqual(posture.phaseStartedAt, base)
        XCTAssertEqual(posture.duration, 45)
        XCTAssertEqual(posture.title, "Fixture session")
        XCTAssertEqual(posture.workspacePath, "/tmp/fixture-workspace")
    }

    func testInsufficientEvidenceReturnsUnknown() {
        let insufficient = Evidence.fixture(grade: .unknown, sources: [])
        let posture = engine.evaluate(
            session: .fixture(),
            events: [.fixture(kind: .modelActivity, at: base, evidence: insufficient)],
            now: base.addingTimeInterval(600)
        )

        XCTAssertEqual(posture.phase, .unknown)
        XCTAssertEqual(posture.health, .unknown)
        XCTAssertEqual(posture.evidenceGrade, .unknown)
        XCTAssertEqual(posture.evidenceSources, [])
    }

    func testWaitingStateTakesPrecedenceOverAnActiveTool() {
        let events: [ObservedEvent] = [
            .fixture(kind: .toolStarted(processID: 42), at: base),
            .fixture(kind: .processAlive(42), at: base.addingTimeInterval(10)),
            .fixture(kind: .waitingForApproval, at: base.addingTimeInterval(20)),
        ]

        let posture = engine.evaluate(
            session: .fixture(),
            events: events,
            now: base.addingTimeInterval(35)
        )
        XCTAssertEqual(posture.phase, .waitingForApproval)
        XCTAssertEqual(posture.health, .actionRequired)
    }

    func testTerminalStateTakesPrecedenceOverInsufficientEvidence() {
        let posture = engine.evaluate(
            session: .fixture(),
            events: [
                .fixture(kind: .modelActivity, at: base),
                .fixture(
                    kind: .completed,
                    at: base.addingTimeInterval(10),
                    evidence: .fixture(grade: .unknown, sources: [])
                ),
            ],
            now: base.addingTimeInterval(10)
        )

        XCTAssertEqual(posture.phase, .completed)
        XCTAssertEqual(posture.health, .normal)
    }

    func testPostureExposesEvidenceAndStructuredPlanCompletion() {
        let sources: [EvidenceSource] = [
            .appServer,
            .stateDatabase,
            .rollout,
            .desktopLog,
            .processProbe,
            .networkProbe,
        ]
        let plan = PlanCompletion(completed: 3, total: 7)
        let posture = engine.evaluate(
            session: .fixture(),
            events: [
                .fixture(
                    kind: .modelActivity,
                    at: base,
                    evidence: .fixture(grade: .high, sources: sources),
                    planCompletion: plan
                ),
            ],
            now: base
        )

        XCTAssertEqual(posture.evidenceGrade, .high)
        XCTAssertEqual(posture.evidenceSources, sources)
        XCTAssertEqual(posture.planCompletion, plan)
    }

    func testDomainValuesHaveStableValueSemantics() {
        requireStableValueType(SessionDescriptor.self)
        requireStableValueType(ObservedEvent.self)
        requireStableValueType(Evidence.self)
        requireStableValueType(SessionPosture.self)
        requireStableValueType(PostureTransition.self)
    }

    func testFixedEnumVocabularyIsAvailable() {
        let phases: Set<ExecutionPhase> = [
            .starting,
            .modelProcessing,
            .toolExecuting,
            .waitingForApproval,
            .waitingForUser,
            .contextCompaction,
            .transportRetry,
            .completed,
            .failed,
            .interrupted,
            .unknown,
        ]
        XCTAssertEqual(phases.count, 11)

        let healthValues: Set<PostureHealth> = [
            .normal,
            .actionRequired,
            .longRunning,
            .connectionDegraded,
            .suspectedStall,
            .blocked,
            .failed,
            .unknown,
        ]
        XCTAssertEqual(healthValues.count, 8)

        let grades: Set<EvidenceGrade> = [.high, .medium, .low, .unknown]
        XCTAssertEqual(grades.count, 4)
    }
}

private func requireStableValueType<Value: Codable & Hashable & Sendable>(_: Value.Type) {}
