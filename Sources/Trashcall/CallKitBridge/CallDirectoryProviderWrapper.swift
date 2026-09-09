import Foundation

#if canImport(CallKit)
import CallKit
#endif

/// Protocol abstraction of CallKit's CXCallDirectoryExtensionContext.
/// Allows unit testing and cross-platform verification of the streaming ingestion pipeline.
public protocol CallDirectoryContextProtocol: AnyObject {
    var isIncrementalUpdate: Bool { get }
    func addBlockingEntry(withNextSequentialPhoneNumber phoneNumber: Int64)
    func removeBlockingEntry(withPhoneNumber phoneNumber: Int64)
    func removeAllBlockingEntries()
    func addIdentificationEntry(withNextSequentialPhoneNumber phoneNumber: Int64, label: String)
    func removeIdentificationEntry(withPhoneNumber phoneNumber: Int64)
    func removeAllIdentificationEntries()
    func completeRequest()
}

/// Simulated context implementation for testing and non-iOS environments.
public final class MockCallDirectoryContext: CallDirectoryContextProtocol, @unchecked Sendable {
    public var isIncrementalUpdate: Bool
    public private(set) var addedBlocking: [Int64] = []
    public private(set) var removedBlocking: [Int64] = []
    public private(set) var addedIdentification: [IdentificationEntry] = []
    public private(set) var removedIdentification: [Int64] = []
    public private(set) var isCompleted: Bool = false

    private var lastBlockingPhone: Int64 = -1
    private var lastIdentificationPhone: Int64 = -1
    private var liveBlocking: Set<Int64> = []
    private var liveIdentification: Set<Int64> = []

    public init(isIncremental: Bool = false) {
        self.isIncrementalUpdate = isIncremental
    }

    public func addBlockingEntry(withNextSequentialPhoneNumber phoneNumber: Int64) {
        if isIncrementalUpdate && liveBlocking.contains(phoneNumber) {
            preconditionFailure(
                "CallKit duplicate blocking entry in incremental mode: \(phoneNumber)"
            )
        }
        precondition(
            phoneNumber > lastBlockingPhone,
            "CallKit Monotonic Invariant Violated: \(phoneNumber) is not strictly greater than previous \(lastBlockingPhone)"
        )
        lastBlockingPhone = phoneNumber
        liveBlocking.insert(phoneNumber)
        addedBlocking.append(phoneNumber)
    }

    public func removeBlockingEntry(withPhoneNumber phoneNumber: Int64) {
        liveBlocking.remove(phoneNumber)
        removedBlocking.append(phoneNumber)
    }

    public func removeAllBlockingEntries() {
        liveBlocking.removeAll()
        lastBlockingPhone = -1
        addedBlocking.removeAll()
        removedBlocking.removeAll()
    }

    public func addIdentificationEntry(withNextSequentialPhoneNumber phoneNumber: Int64, label: String) {
        if isIncrementalUpdate && liveIdentification.contains(phoneNumber) {
            preconditionFailure(
                "CallKit duplicate identification entry in incremental mode: \(phoneNumber)"
            )
        }
        precondition(
            phoneNumber > lastIdentificationPhone,
            "CallKit Monotonic Invariant Violated: \(phoneNumber) is not strictly greater than previous \(lastIdentificationPhone)"
        )
        lastIdentificationPhone = phoneNumber
        liveIdentification.insert(phoneNumber)
        addedIdentification.append(IdentificationEntry(phoneNumber: phoneNumber, label: label))
    }

    public func removeIdentificationEntry(withPhoneNumber phoneNumber: Int64) {
        liveIdentification.remove(phoneNumber)
        removedIdentification.append(phoneNumber)
    }

    public func removeAllIdentificationEntries() {
        liveIdentification.removeAll()
        lastIdentificationPhone = -1
        addedIdentification.removeAll()
        removedIdentification.removeAll()
    }

    public func completeRequest() {
        isCompleted = true
    }
}

/// What a Call Directory extension is allowed to inject.
/// iOS 26/27 ignores `addBlockingEntry` in an extension that also identifies callers.
public enum CallDirectoryFeedKind: String, Sendable {
    /// Bulk labels only. Also clears any blocking this extension previously registered.
    case identificationOnly
    /// User-requested hang-up numbers only. No identification entries.
    case userBlockingOnly
    /// Tests / legacy: both lists in one request.
    case full
}

/// Core pipeline that feeds entries from the store into the CallKit context.
/// Ensures strict adherence to memory limits and ascending order sorting.
public struct CallDirectoryFeeder: Sendable {
    public init() {}

    /// Feeds all data from the store into the context as a full reload.
    /// Incremental CallKit requests cannot re-add numbers that already exist, so this
    /// clears the system index first and then streams the current SQLite snapshot.
    public func feedFullData(from store: CallDirectoryStore, into context: CallDirectoryContextProtocol) throws {
        try feed(kind: .full, from: store, into: context)
    }

    public func feed(
        kind: CallDirectoryFeedKind,
        from store: CallDirectoryStore,
        into context: CallDirectoryContextProtocol
    ) throws {
        if context.isIncrementalUpdate {
            context.removeAllBlockingEntries()
            context.removeAllIdentificationEntries()
        }

        switch kind {
        case .identificationOnly:
            try store.streamIdentificationEntries { entry in
                context.addIdentificationEntry(
                    withNextSequentialPhoneNumber: entry.phoneNumber,
                    label: entry.label
                )
            }
        case .userBlockingOnly:
            try store.streamUserBlockingNumbers { phoneNumber in
                context.addBlockingEntry(withNextSequentialPhoneNumber: phoneNumber)
            }
        case .full:
            try store.streamBlockingNumbers { phoneNumber in
                context.addBlockingEntry(withNextSequentialPhoneNumber: phoneNumber)
            }
            try store.streamIdentificationEntries { entry in
                context.addIdentificationEntry(
                    withNextSequentialPhoneNumber: entry.phoneNumber,
                    label: entry.label
                )
            }
        }

        context.completeRequest()
    }

    /// Feeds an incremental delta package into the context.
    public func feedIncremental(delta: DeltaPackage, into context: CallDirectoryContextProtocol) {
        // Removals first (order does not strictly matter according to Apple docs, but removals must precede adds)
        for num in delta.removedBlocking {
            context.removeBlockingEntry(withPhoneNumber: num)
        }
        for num in delta.removedIdentification {
            context.removeIdentificationEntry(withPhoneNumber: num)
        }

        // Additions MUST be in strictly ascending order
        for num in delta.addedBlocking {
            context.addBlockingEntry(withNextSequentialPhoneNumber: num)
        }
        for entry in delta.addedIdentification {
            context.addIdentificationEntry(
                withNextSequentialPhoneNumber: entry.phoneNumber,
                label: entry.label
            )
        }

        context.completeRequest()
    }
}
