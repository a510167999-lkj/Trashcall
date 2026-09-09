import Foundation

#if canImport(CallKit) && os(iOS)
import CallKit

/// Production implementation of CXCallDirectoryProvider for the iOS Extension target.
/// Uses CallDirectoryStore and CallDirectoryFeeder with streaming SQLite reads to guarantee < 15MB RAM usage.
open class TrashcallCallDirectoryProvider: CXCallDirectoryProvider {

    /// Override this to return your shared App Group container identifier.
    /// Example: "group.com.yourcompany.trashcall"
    open var appGroupIdentifier: String {
        return "group.com.trashcall.shared"
    }

    open var databaseFileName: String {
        return "trashcall.sqlite"
    }

    open var feedKind: CallDirectoryFeedKind {
        return .identificationOnly
    }

    open var runReportFileName: String {
        return ExtensionRunReport.defaultFileName
    }

    open override func beginRequest(with context: CXCallDirectoryExtensionContext) {
        context.delegate = self

        var report = ExtensionRunReport(
            incremental: context.isIncremental,
            appGroupOK: false,
            dbExists: false,
            feedKind: feedKind.rawValue
        )

        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            let error = NSError(
                domain: "com.trashcall.error",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "无法获取 App Group 共享目录容器: \(appGroupIdentifier)"]
            )
            report.error = error.localizedDescription
            report.save(fileName: runReportFileName)
            context.cancelRequest(withError: error)
            return
        }
        report.appGroupOK = true

        let dbURL = DatabaseBootstrap.databaseURL()
        report.dbExists = FileManager.default.fileExists(atPath: dbURL.path)
        let store = CallDirectoryStore(databaseURL: dbURL)

        do {
            // Read-write so the extension can see WAL; do not create an empty DB here.
            try store.open(readOnly: false, createIfNeeded: false)
            try store.initializeSchema()
            report.blockingFed = 0
            report.identificationFed = store.countIdentification()

            let feeder = CallDirectoryFeeder()
            let contextAdapter = CXCallDirectoryContextAdapter(context: context)
            try feeder.feed(kind: feedKind, from: store, into: contextAdapter)
            report.save(fileName: runReportFileName)
        } catch {
            report.error = error.localizedDescription
            report.save(fileName: runReportFileName)
            context.cancelRequest(withError: error)
        }
    }
}

extension TrashcallCallDirectoryProvider: CXCallDirectoryExtensionContextDelegate {
    public func requestFailed(for extensionContext: CXCallDirectoryExtensionContext, withError error: Error) {
        var report = ExtensionRunReport.load(fileName: runReportFileName) ?? ExtensionRunReport(
            incremental: extensionContext.isIncremental,
            appGroupOK: false,
            dbExists: false,
            feedKind: feedKind.rawValue
        )
        report.error = error.localizedDescription
        report.save(fileName: runReportFileName)
    }
}

/// Adapter converting Apple's CXCallDirectoryExtensionContext to CallDirectoryContextProtocol.
final class CXCallDirectoryContextAdapter: CallDirectoryContextProtocol {
    private let context: CXCallDirectoryExtensionContext

    init(context: CXCallDirectoryExtensionContext) {
        self.context = context
    }

    var isIncrementalUpdate: Bool {
        return context.isIncremental
    }

    func addBlockingEntry(withNextSequentialPhoneNumber phoneNumber: Int64) {
        context.addBlockingEntry(withNextSequentialPhoneNumber: phoneNumber)
    }

    func removeBlockingEntry(withPhoneNumber phoneNumber: Int64) {
        context.removeBlockingEntry(withPhoneNumber: phoneNumber)
    }

    func removeAllBlockingEntries() {
        context.removeAllBlockingEntries()
    }

    func addIdentificationEntry(withNextSequentialPhoneNumber phoneNumber: Int64, label: String) {
        context.addIdentificationEntry(withNextSequentialPhoneNumber: phoneNumber, label: label)
    }

    func removeIdentificationEntry(withPhoneNumber phoneNumber: Int64) {
        context.removeIdentificationEntry(withPhoneNumber: phoneNumber)
    }

    func removeAllIdentificationEntries() {
        context.removeAllIdentificationEntries()
    }

    func completeRequest() {
        context.completeRequest()
    }
}
#endif
