import Foundation

/// Represents the action to take when a matching call occurs.
public enum CallAction: Hashable, Sendable {
    /// Completely silence and block the incoming call silently.
    case block

    /// Allow ringing but display an identification label on the incoming call screen (e.g. "诈骗电话", "高频推销").
    case identify(label: String)

    public var isBlocking: Bool {
        switch self {
        case .block: return true
        case .identify: return false
        }
    }

    public var label: String? {
        switch self {
        case .block: return nil
        case .identify(let text): return text
        }
    }
}

/// Represents the matching criteria for a phone number.
public enum NumberPattern: Hashable, Sendable {
    /// A single discrete E.164 phone number.
    case exact(PhoneNumber)

    /// A prefix range matching an exact total digit length (e.g., Chinese 95-prefix: 8695210000...8695219999).
    case range(start: PhoneNumber, end: PhoneNumber)

    /// A wildcard pattern with asterisks (e.g. "9521****").
    case wildcard(String)
}

/// Represents a user or system defined rule for spam call processing.
public struct CallRule: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var pattern: NumberPattern
    public var action: CallAction
    public var isEnabled: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        pattern: NumberPattern,
        action: CallAction,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.action = action
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

/// User-selectable action in the Dashboard UI.
public enum RuleActionType: String, CaseIterable, Identifiable, Codable, Sendable {
    case block = "🚫 自动挂断"
    case identify = "🏷️ 标记提醒"
    public var id: String { rawValue }
}

/// A persisted rule item for user-defined wildcard or exact number rules.
public struct ActiveRuleItem: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var pattern: String
    public var action: RuleActionType
    public var label: String?
    public var count: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        pattern: String,
        action: RuleActionType,
        label: String? = nil,
        count: Int = 1,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.pattern = pattern
        self.action = action
        self.label = label
        self.count = count
        self.createdAt = createdAt
    }
}

