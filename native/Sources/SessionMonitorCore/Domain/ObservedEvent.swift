import Foundation

public enum LocalSurface: String, Codable, Hashable, Sendable {
    case desktop
    case cli
    case ide
    case subAgent
}

public struct SessionDescriptor: Codable, Hashable, Sendable {
    public let id: String
    public let title: String?
    public let workspacePath: String?
    public let lastActivityAt: Date
    public let surface: LocalSurface?
    public let rolloutPath: String?
    public let agentNickname: String?
    public let agentRole: String?

    public init(
        id: String,
        title: String?,
        workspacePath: String?,
        lastActivityAt: Date,
        surface: LocalSurface? = nil,
        rolloutPath: String? = nil,
        agentNickname: String? = nil,
        agentRole: String? = nil
    ) {
        self.id = id
        self.title = title
        self.workspacePath = workspacePath
        self.lastActivityAt = lastActivityAt
        self.surface = surface
        self.rolloutPath = rolloutPath
        self.agentNickname = agentNickname
        self.agentRole = agentRole
    }
}

public struct ObservedEvent: Codable, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case turnStarted
        case modelActivity
        case toolStarted(processID: Int32)
        case processAlive(Int32)
        case waitingForApproval
        case waitingForUser
        case contextCompaction
        case transportRetry
        case completed
        case failed
        case interrupted

        var isTerminal: Bool {
            switch self {
            case .completed, .failed, .interrupted:
                return true
            default:
                return false
            }
        }

        var isTransportRetry: Bool {
            self == .transportRetry
        }

        var isModelActivity: Bool {
            self == .modelActivity
        }
    }

    public let sessionID: String
    public let turnID: String?
    public let itemID: String?
    public let kind: Kind
    public let eventTime: Date
    public let observedAt: Date
    public let evidence: Evidence
    public let planCompletion: PlanCompletion?

    public init(
        sessionID: String,
        turnID: String?,
        itemID: String?,
        kind: Kind,
        eventTime: Date,
        observedAt: Date,
        evidence: Evidence,
        planCompletion: PlanCompletion? = nil
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.itemID = itemID
        self.kind = kind
        self.eventTime = eventTime
        self.observedAt = observedAt
        self.evidence = evidence
        self.planCompletion = planCompletion
    }
}
