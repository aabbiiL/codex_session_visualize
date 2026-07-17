import Foundation

public struct ThresholdPolicy: Codable, Hashable, Sendable {
    public let waitingActionRequiredAfter: TimeInterval
    public let modelSuspectedStallAfter: TimeInterval
    public let modelBlockedAfter: TimeInterval
    public let toolLongRunningAfter: TimeInterval
    public let transportDegradedAfter: TimeInterval
    public let transportBlockedAfter: TimeInterval

    public init(
        waitingActionRequiredAfter: TimeInterval,
        modelSuspectedStallAfter: TimeInterval,
        modelBlockedAfter: TimeInterval,
        toolLongRunningAfter: TimeInterval,
        transportDegradedAfter: TimeInterval,
        transportBlockedAfter: TimeInterval
    ) {
        self.waitingActionRequiredAfter = waitingActionRequiredAfter
        self.modelSuspectedStallAfter = modelSuspectedStallAfter
        self.modelBlockedAfter = modelBlockedAfter
        self.toolLongRunningAfter = toolLongRunningAfter
        self.transportDegradedAfter = transportDegradedAfter
        self.transportBlockedAfter = transportBlockedAfter
    }

    public static let defaults = ThresholdPolicy(
        waitingActionRequiredAfter: 15,
        modelSuspectedStallAfter: 180,
        modelBlockedAfter: 600,
        toolLongRunningAfter: 300,
        transportDegradedAfter: 30,
        transportBlockedAfter: 120
    )
}
