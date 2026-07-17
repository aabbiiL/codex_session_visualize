import CryptoKit
import Foundation

public protocol WorkspaceHMACKeyProviding: Sendable {
    func workspaceHMACKey() throws -> Data
}

public protocol WorkspaceHMACProviding: Sendable {
    func anonymousWorkspaceNumber(forWorkspacePath path: String?) -> Int
}

public enum WorkspaceHMACProviderError: Error, Equatable, Sendable {
    case keyTooShort
}

public struct HMACWorkspaceNumberProvider: WorkspaceHMACProviding, Sendable {
    private let key: Data

    public init<KeyProvider: WorkspaceHMACKeyProviding>(
        keyProvider: KeyProvider
    ) throws {
        let key = try keyProvider.workspaceHMACKey()
        guard key.count >= 32 else {
            throw WorkspaceHMACProviderError.keyTooShort
        }
        self.key = key
    }

    public func anonymousWorkspaceNumber(forWorkspacePath path: String?) -> Int {
        let message = Data((path ?? "<workspace-unavailable>").utf8)
        let code = HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: key)
        )
        let value = code.prefix(8).reduce(UInt64.zero) { partial, byte in
            (partial << 8) | UInt64(byte)
        }
        return Int(value % 9_999) + 1
    }
}

public struct SessionPresentation: Hashable, Sendable {
    public let sessionID: String
    public let title: String?
    public let anonymousWorkspaceNumber: Int

    public init(
        sessionID: String,
        title: String?,
        anonymousWorkspaceNumber: Int
    ) {
        self.sessionID = sessionID
        self.title = title
        self.anonymousWorkspaceNumber = anonymousWorkspaceNumber
    }
}

public enum NotificationReason: String, Codable, Hashable, Sendable {
    case waitingForApproval
    case waitingForUser
    case failed
    case blocked
}

public struct DerivedSessionRecord: Codable, Hashable, Sendable {
    public let sessionID: String
    public let phase: ExecutionPhase
    public let health: PostureHealth
    public let lastActivityAt: Date
    public let phaseStartedAt: Date
    public let duration: TimeInterval
    public let evidenceGrade: EvidenceGrade
    public let evidenceSources: [EvidenceSource]
    public let planCompletion: PlanCompletion?

    public init(
        sessionID: String,
        phase: ExecutionPhase,
        health: PostureHealth,
        lastActivityAt: Date,
        phaseStartedAt: Date,
        duration: TimeInterval,
        evidenceGrade: EvidenceGrade,
        evidenceSources: [EvidenceSource],
        planCompletion: PlanCompletion?
    ) {
        self.sessionID = sessionID
        self.phase = phase
        self.health = health
        self.lastActivityAt = lastActivityAt
        self.phaseStartedAt = phaseStartedAt
        self.duration = duration
        self.evidenceGrade = evidenceGrade
        self.evidenceSources = evidenceSources
        self.planCompletion = planCompletion
    }

    public var encodedJSON: String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct PrivacyPolicy: Hashable, Sendable {
    public static let defaults = PrivacyPolicy(
        overviewNamesVisible: true,
        notificationNamesVisible: false
    )

    public let overviewNamesVisible: Bool
    public let notificationNamesVisible: Bool

    public init(
        overviewNamesVisible: Bool,
        notificationNamesVisible: Bool
    ) {
        self.overviewNamesVisible = overviewNamesVisible
        self.notificationNamesVisible = notificationNamesVisible
    }

    public func presentation<Provider: WorkspaceHMACProviding>(
        for session: SessionDescriptor,
        workspaceHMACProvider: Provider
    ) -> SessionPresentation {
        SessionPresentation(
            sessionID: session.id,
            title: session.title,
            anonymousWorkspaceNumber: workspaceHMACProvider
                .anonymousWorkspaceNumber(forWorkspacePath: session.workspacePath)
        )
    }

    public func overviewLabel(for session: SessionPresentation) -> String {
        let name = overviewNamesVisible
            ? visibleName(for: session)
            : shortenedSessionID(session.sessionID)
        return "\(name) · Workspace \(session.anonymousWorkspaceNumber)"
    }

    public func notificationBody(
        for session: SessionPresentation,
        reason: NotificationReason
    ) -> String {
        guard notificationNamesVisible else {
            return hiddenNotificationBody(for: reason)
        }

        let name = visibleName(for: session)
        switch reason {
        case .waitingForApproval:
            return "\(name) needs approval."
        case .waitingForUser:
            return "\(name) needs your response."
        case .failed:
            return "\(name) failed."
        case .blocked:
            return "\(name) may be blocked."
        }
    }

    public func derivedRecord(from posture: SessionPosture) -> DerivedSessionRecord {
        DerivedSessionRecord(
            sessionID: posture.sessionID,
            phase: posture.phase,
            health: posture.health,
            lastActivityAt: posture.lastActivityAt,
            phaseStartedAt: posture.phaseStartedAt,
            duration: posture.duration,
            evidenceGrade: posture.evidenceGrade,
            evidenceSources: posture.evidenceSources,
            planCompletion: posture.planCompletion
        )
    }

    private func visibleName(for session: SessionPresentation) -> String {
        guard let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return shortenedSessionID(session.sessionID)
        }
        return title
    }

    private func shortenedSessionID(_ sessionID: String) -> String {
        guard sessionID.count > 8 else {
            return sessionID
        }
        return "\(sessionID.prefix(4))…\(sessionID.suffix(4))"
    }

    private func hiddenNotificationBody(for reason: NotificationReason) -> String {
        switch reason {
        case .waitingForApproval:
            return "A Codex session needs approval."
        case .waitingForUser:
            return "A Codex session needs your response."
        case .failed:
            return "A Codex session failed."
        case .blocked:
            return "A Codex session may be blocked."
        }
    }
}
