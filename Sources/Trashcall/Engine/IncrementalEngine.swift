import Foundation

/// Engine to compute incremental diffs between existing CallKit state and updated database state.
public struct IncrementalEngine: Sendable {
    public init() {}

    /// Calculates diff between old and new blocking sets.
    /// - Parameters:
    ///   - oldSet: The numbers currently registered with CallKit.
    ///   - newSet: The target numbers to be registered.
    /// - Returns: (toRemove: [Int64], toAdd: [Int64]), both sorted strictly ascending.
    public static func computeBlockingDiff(
        oldSet: Set<Int64>,
        newSet: Set<Int64>
    ) -> (toRemove: [Int64], toAdd: [Int64]) {
        let toRemove = oldSet.subtracting(newSet).sorted()
        let toAdd = newSet.subtracting(oldSet).sorted()
        return (toRemove, toAdd)
    }

    /// Calculates diff between old and new identification mappings.
    /// - Parameters:
    ///   - oldMap: Existing phone number to label map.
    ///   - newMap: New phone number to label map.
    /// - Returns: (toRemove: [Int64], toAdd: [IdentificationEntry]), both sorted strictly ascending.
    public static func computeIdentificationDiff(
        oldMap: [Int64: String],
        newMap: [Int64: String]
    ) -> (toRemove: [Int64], toAdd: [IdentificationEntry]) {
        var toRemove: [Int64] = []
        var toAdd: [IdentificationEntry] = []

        // Numbers in old but not in new
        for (phone, _) in oldMap {
            if newMap[phone] == nil {
                toRemove.append(phone)
            }
        }

        // Numbers in new
        for (phone, newLabel) in newMap {
            if let oldLabel = oldMap[phone] {
                if oldLabel != newLabel {
                    // Label changed: must remove old and add new in CallKit
                    toRemove.append(phone)
                    toAdd.append(IdentificationEntry(phoneNumber: phone, label: newLabel))
                }
            } else {
                // Completely new entry
                toAdd.append(IdentificationEntry(phoneNumber: phone, label: newLabel))
            }
        }

        return (toRemove.sorted(), toAdd.sorted())
    }

    /// Computes a complete DeltaPackage between snapshots.
    public static func generateDelta(
        version: String,
        oldBlocking: Set<Int64>,
        newBlocking: Set<Int64>,
        oldIdentification: [Int64: String],
        newIdentification: [Int64: String]
    ) -> DeltaPackage {
        let (removedBlock, addedBlock) = computeBlockingDiff(oldSet: oldBlocking, newSet: newBlocking)
        let (removedIdent, addedIdent) = computeIdentificationDiff(oldMap: oldIdentification, newMap: newIdentification)

        return DeltaPackage(
            version: version,
            isFullSnapshot: false,
            removedBlocking: removedBlock,
            addedBlocking: addedBlock,
            removedIdentification: removedIdent,
            addedIdentification: addedIdent
        )
    }
}
