import Foundation

/// Represents an identification entry to be added to CallKit.
public struct IdentificationEntry: Hashable, Comparable, Sendable {
    public let phoneNumber: Int64
    public let label: String

    public init(phoneNumber: Int64, label: String) {
        self.phoneNumber = phoneNumber
        self.label = label
    }

    public static func < (lhs: IdentificationEntry, rhs: IdentificationEntry) -> Bool {
        return lhs.phoneNumber < rhs.phoneNumber
    }
}

/// Represents a delta package containing changes to apply to CallKit.
public struct DeltaPackage: Sendable {
    public let version: String
    public let isFullSnapshot: Bool

    /// Phone numbers to remove from the blocking list.
    public let removedBlocking: [Int64]

    /// Phone numbers to add to the blocking list (MUST be strictly monotonically ascending).
    public let addedBlocking: [Int64]

    /// Phone numbers to remove from the identification list.
    public let removedIdentification: [Int64]

    /// Identification entries to add to CallKit (MUST be strictly monotonically ascending).
    public let addedIdentification: [IdentificationEntry]

    public init(
        version: String,
        isFullSnapshot: Bool = false,
        removedBlocking: [Int64] = [],
        addedBlocking: [Int64] = [],
        removedIdentification: [Int64] = [],
        addedIdentification: [IdentificationEntry] = []
    ) {
        self.version = version
        self.isFullSnapshot = isFullSnapshot
        self.removedBlocking = removedBlocking.sorted()
        self.addedBlocking = addedBlocking.sorted()
        self.removedIdentification = removedIdentification.sorted()
        self.addedIdentification = addedIdentification.sorted()
    }
}
