import Foundation

public enum ExecutionPhase: String, Codable, Hashable, Sendable {
    case starting
    case modelProcessing
    case toolExecuting
    case waitingForApproval
    case waitingForUser
    case contextCompaction
    case transportRetry
    case completed
    case failed
    case interrupted
    case unknown
}

public enum PostureHealth: String, Codable, Hashable, Sendable {
    case normal
    case actionRequired
    case longRunning
    case connectionDegraded
    case suspectedStall
    case blocked
    case failed
    case unknown
}

public struct PlanCompletion: Codable, Hashable, Sendable {
    public let completed: Int
    public let total: Int

    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }
}

public struct SessionPosture: Codable, Hashable, Sendable {
    public let sessionID: String
    public let title: String?
    public let workspacePath: String?
    public let phase: ExecutionPhase
    public let health: PostureHealth
    public let lastActivityAt: Date
    public let phaseStartedAt: Date
    public let duration: TimeInterval
    public let blocker: String?
    public let recommendation: String?
    public let evidenceGrade: EvidenceGrade
    public let evidenceSources: [EvidenceSource]
    public let planCompletion: PlanCompletion?

    public init(
        sessionID: String,
        title: String?,
        workspacePath: String?,
        phase: ExecutionPhase,
        health: PostureHealth,
        lastActivityAt: Date,
        phaseStartedAt: Date,
        duration: TimeInterval,
        blocker: String?,
        recommendation: String?,
        evidenceGrade: EvidenceGrade,
        evidenceSources: [EvidenceSource],
        planCompletion: PlanCompletion?
    ) {
        self.sessionID = sessionID
        self.title = title
        self.workspacePath = workspacePath
        self.phase = phase
        self.health = health
        self.lastActivityAt = lastActivityAt
        self.phaseStartedAt = phaseStartedAt
        self.duration = duration
        self.blocker = blocker
        self.recommendation = recommendation
        self.evidenceGrade = evidenceGrade
        self.evidenceSources = evidenceSources
        self.planCompletion = planCompletion
    }
}

public struct PostureTransition: Codable, Hashable, Sendable {
    public let sessionID: String
    public let fromPhase: ExecutionPhase?
    public let fromHealth: PostureHealth?
    public let toPhase: ExecutionPhase
    public let toHealth: PostureHealth
    public let occurredAt: Date

    public init(
        sessionID: String,
        fromPhase: ExecutionPhase?,
        fromHealth: PostureHealth?,
        toPhase: ExecutionPhase,
        toHealth: PostureHealth,
        occurredAt: Date
    ) {
        self.sessionID = sessionID
        self.fromPhase = fromPhase
        self.fromHealth = fromHealth
        self.toPhase = toPhase
        self.toHealth = toHealth
        self.occurredAt = occurredAt
    }
}

enum PostureGuidance {
    case approvalRequired
    case userInputRequired
    case toolLongRunning
    case connectionDegraded
    case connectionBlocked
    case modelSuspectedStall
    case modelBlocked
    case sessionFailed

    var blocker: String {
        switch self {
        case .approvalRequired:
            return "Approval required"
        case .userInputRequired:
            return "User input required"
        case .toolLongRunning:
            return "Tool is still running"
        case .connectionDegraded:
            return "Connection is retrying"
        case .connectionBlocked:
            return "Connection retry timed out"
        case .modelSuspectedStall:
            return "Model activity may be stalled"
        case .modelBlocked:
            return "Model activity is blocked"
        case .sessionFailed:
            return "Session failed"
        }
    }

    var recommendation: String {
        switch self {
        case .approvalRequired:
            return "Open the session and review the request"
        case .userInputRequired:
            return "Open the session and respond"
        case .toolLongRunning:
            return "Open the session and review the running tool"
        case .connectionDegraded, .connectionBlocked:
            return "Open the session and review the connection"
        case .modelSuspectedStall, .modelBlocked:
            return "Open the session and inspect recent activity"
        case .sessionFailed:
            return "Open the session and review the failure"
        }
    }
}
