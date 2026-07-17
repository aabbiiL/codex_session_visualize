public struct StructuredPlanStep: Codable, Hashable, Sendable {
    public let status: String

    public init(status: String) {
        self.status = status
    }
}

public struct StructuredPlanPayload: Codable, Hashable, Sendable {
    public let steps: [StructuredPlanStep]

    public init(steps: [StructuredPlanStep]) {
        self.steps = steps
    }
}

public enum PlanProgressInput: Hashable, Sendable {
    case structured(StructuredPlanPayload)
    case prose(String)
}

public struct PlanProgressExtractor: Sendable {
    public init() {}

    public func extract(from input: PlanProgressInput) -> PlanCompletion? {
        guard case let .structured(payload) = input, !payload.steps.isEmpty else {
            return nil
        }

        var completed = 0
        for step in payload.steps {
            switch step.status {
            case "pending", "in_progress":
                break
            case "completed":
                completed += 1
            default:
                return nil
            }
        }

        return PlanCompletion(completed: completed, total: payload.steps.count)
    }
}
