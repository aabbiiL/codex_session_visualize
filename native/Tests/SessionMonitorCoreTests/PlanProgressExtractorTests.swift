import XCTest
@testable import SessionMonitorCore

final class PlanProgressExtractorTests: XCTestCase {
    private let extractor = PlanProgressExtractor()

    func testStructuredStatusesProduceCompletedOverTotalCount() {
        let payload = StructuredPlanPayload(steps: [
            StructuredPlanStep(status: "completed"),
            StructuredPlanStep(status: "pending"),
            StructuredPlanStep(status: "completed"),
            StructuredPlanStep(status: "in_progress"),
            StructuredPlanStep(status: "pending"),
            StructuredPlanStep(status: "completed"),
            StructuredPlanStep(status: "in_progress"),
        ])

        XCTAssertEqual(
            extractor.extract(from: .structured(payload)),
            PlanCompletion(completed: 3, total: 7)
        )
    }

    func testInvalidStructuredStatusReturnsNil() {
        let payload = StructuredPlanPayload(steps: [
            StructuredPlanStep(status: "completed"),
            StructuredPlanStep(status: "done"),
        ])

        XCTAssertNil(extractor.extract(from: .structured(payload)))
    }

    func testEmptyStructuredPlanReturnsNil() {
        XCTAssertNil(
            extractor.extract(from: .structured(StructuredPlanPayload(steps: [])))
        )
    }

    func testChecklistLikeProseDoesNotProducePlanCompletion() {
        let prose = """
        Plan:
        - [x] inspect the session
        - [ ] estimate 50% complete with an ETA of ten minutes
        """

        XCTAssertNil(extractor.extract(from: .prose(prose)))
    }
}
