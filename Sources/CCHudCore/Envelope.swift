import Foundation

public struct Envelope: Decodable, Sendable {
    public let kind: String            // "hook" | "status"
    public let claudePid: Int32?
    public let tty: String?
    public let termProgram: String?
    public let itermSessionId: String?
    public let payload: EnvelopePayload
}

public struct EnvelopePayload: Decodable, Sendable {
    public let hookEventName: String?
    public let sessionId: String?
    public let cwd: String?
    public let transcriptPath: String?
    public let toolName: String?
    public let toolInput: JSONValue?
    public let source: String?         // SessionStart: startup|resume|clear|compact
    public let trigger: String?        // PreCompact: manual|auto
    public let model: ModelInfo?
    public let contextWindow: ContextWindowInfo?
    public let rateLimits: RateLimitsInfo?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case cwd
        case transcriptPath = "transcript_path"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case source
        case trigger
        case model
        case contextWindow = "context_window"
        case rateLimits = "rate_limits"
    }
}

public struct ModelInfo: Decodable, Sendable {
    public let displayName: String?
    enum CodingKeys: String, CodingKey { case displayName = "display_name" }
}

public struct ContextWindowInfo: Decodable, Sendable {
    public let usedPercentage: Double?
    enum CodingKeys: String, CodingKey { case usedPercentage = "used_percentage" }
}

public struct RateLimitsInfo: Decodable, Sendable {
    public let fiveHour: RateWindow?
    public let sevenDay: RateWindow?
    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

public struct RateWindow: Decodable, Sendable {
    public let usedPercentage: Double?
    public let resetsAt: Double?       // epoch 秒
    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }
}
