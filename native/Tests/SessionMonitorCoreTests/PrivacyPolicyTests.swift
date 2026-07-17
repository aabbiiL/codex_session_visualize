import Foundation
import XCTest
@testable import SessionMonitorCore

final class PrivacyPolicyTests: XCTestCase {
    func testHiddenNamesUseShortSessionAndAnonymousWorkspaceLabels() {
        let hidden = PrivacyPolicy(
            overviewNamesVisible: false,
            notificationNamesVisible: false
        )
        let session = hidden.presentation(
            for: privateSession,
            workspaceHMACProvider: StubWorkspaceHMACProvider(number: 2)
        )

        XCTAssertEqual(hidden.overviewLabel(for: session), "019f…63f0 · Workspace 2")
        XCTAssertEqual(
            hidden.notificationBody(for: session, reason: .waitingForApproval),
            "A Codex session needs approval."
        )
    }

    func testDefaultVisibilityShowsOverviewNamesAndHidesNotificationNames() {
        let policy = PrivacyPolicy.defaults
        let session = policy.presentation(
            for: privateSession,
            workspaceHMACProvider: StubWorkspaceHMACProvider(number: 2)
        )

        XCTAssertTrue(policy.overviewNamesVisible)
        XCTAssertFalse(policy.notificationNamesVisible)
        XCTAssertEqual(policy.overviewLabel(for: session), "secret project · Workspace 2")
        XCTAssertEqual(
            policy.notificationBody(for: session, reason: .waitingForApproval),
            "A Codex session needs approval."
        )
    }

    func testDerivedRecordOmitsPresentationOnlyNamesAndWorkspacePaths() {
        let hidden = PrivacyPolicy(
            overviewNamesVisible: false,
            notificationNamesVisible: false
        )

        let json = hidden.derivedRecord(from: privatePosture).encodedJSON

        XCTAssertFalse(json.contains("secret project"))
        XCTAssertFalse(json.contains("/Users/example/secret project"))
        XCTAssertFalse(json.contains("\"title\""))
        XCTAssertFalse(json.contains("workspacePath"))
    }

    private var privateSession: SessionDescriptor {
        SessionDescriptor(
            id: "019f6a08-478b-7ca0-b37e-ada2372f63f0",
            title: "secret project",
            workspacePath: "/Users/example/secret project",
            lastActivityAt: base
        )
    }

    private var privatePosture: SessionPosture {
        SessionPosture(
            sessionID: privateSession.id,
            title: privateSession.title,
            workspacePath: privateSession.workspacePath,
            phase: .waitingForApproval,
            health: .actionRequired,
            lastActivityAt: base,
            phaseStartedAt: base,
            duration: 15,
            blocker: "Approval required",
            recommendation: "Open the session and review the request",
            evidenceGrade: .high,
            evidenceSources: [.appServer],
            planCompletion: nil
        )
    }
}

private struct StubWorkspaceHMACProvider: WorkspaceHMACProviding {
    let number: Int

    func anonymousWorkspaceNumber(forWorkspacePath _: String?) -> Int {
        number
    }
}
