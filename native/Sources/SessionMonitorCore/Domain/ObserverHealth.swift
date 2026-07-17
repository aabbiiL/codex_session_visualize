public enum ObserverHealth: String, Codable, Hashable, Sendable {
    case normal
    case degraded
    case blind
}

public enum EvidenceSource: String, Codable, Hashable, Sendable {
    case appServer
    case stateDatabase
    case rollout
    case desktopLog
    case processProbe
    case networkProbe
}

public enum EvidenceGrade: String, Codable, Hashable, Sendable {
    case high
    case medium
    case low
    case unknown
}

public struct Evidence: Codable, Hashable, Sendable {
    public let grade: EvidenceGrade
    public let sources: [EvidenceSource]

    public init(grade: EvidenceGrade, sources: [EvidenceSource]) {
        self.grade = grade
        self.sources = sources
    }

    var isConflicting: Bool {
        grade == .unknown && !sources.isEmpty
    }

    var isInsufficient: Bool {
        grade == .unknown && sources.isEmpty
    }
}
