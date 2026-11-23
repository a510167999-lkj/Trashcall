import Foundation

#if canImport(CallKit) && os(iOS)
import CallKit

/// Production implementation of CXCallDirectoryProvider for the iOS Extension target.
/// Uses CallDirectoryStore and CallDirectoryFeeder with streaming SQLite reads to guarantee < 15MB RAM usage.
open class TrashcallCallDirectoryProvider: CXCallDirectoryProvider {

    /// Override this to return your shared App Group container identifier.
    /// Example: "group.com.yourcompany.trashcall"
    open var appGroupIdentifier: String {
        return DatabaseBootstrap.appGroupId
    }

    open var databaseFileName: String {
        return "trashcall.sqlite"
    }

    open var feedKind: CallDirectoryFeedKind {
        return .full
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

        let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
        report.appGroupOK = (groupURL != nil)

        let dbURL: URL
        let isReadOnly: Bool
        if groupURL != nil {
            dbURL = DatabaseBootstrap.databaseURL()
            isReadOnly = false
        } else if let seedURL = DatabaseBootstrap.bundledSeedURL() {
            // Sideload fallback: App Group is unavailable (e.g. free personal Apple ID).
            // Fall back to reading the bundled seed database directly so CallKit can still
            // protect calls with the 410,000+ offline spam database.
            dbURL = seedURL
            isReadOnly = true
        } else {
            let error = NSError(
                domain: "com.trashcall.error",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "无法获取数据库: App Group 未授权且未找到内置种子库"]
            )
            report.error = error.localizedDescription
            report.save(fileName: runReportFileName)
            context.cancelRequest(withError: error)
            return
        }

        report.dbExists = FileManager.default.fileExists(atPath: dbURL.path)
        let store = CallDirectoryStore(databaseURL: dbURL)

        do {
            // Read-write so the extension can see WAL when using App Group; read-only for seed fallback
            try store.open(readOnly: isReadOnly, createIfNeeded: false)
            if !isReadOnly {
                try store.initializeSchema()
            }
            try store.execute(sql: "BEGIN DEFERRED;")
            defer { try? store.execute(sql: "ROLLBACK;") }
            report.directoryRevision = try store.getMetadata(key: "directory_revision")
            switch feedKind {
            case .identificationOnly:
                report.blockingFed = 0
                report.identificationFed = store.countIdentification()
            case .userBlockingOnly:
                report.blockingFed = store.countUserBlocking()
                report.identificationFed = 0
            case .blockingOnly:
                report.blockingFed = store.countBlocking()
                report.identificationFed = 0
            case .full:
                report.blockingFed = store.countBlocking()
                report.identificationFed = store.countIdentification()
            }

            let feeder = CallDirectoryFeeder()
            let completedReport = report
            let reportFileName = runReportFileName
            let contextAdapter = CXCallDirectoryContextAdapter(context: context) {
                completedReport.save(fileName: reportFileName)
            }
            try feeder.feed(kind: feedKind, from: store, into: contextAdapter)
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

    private let reportSubmission: () -> Void

    init(context: CXCallDirectoryExtensionContext, reportSubmission: @escaping () -> Void) {
        self.context = context
        self.reportSubmission = reportSubmission
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
        reportSubmission()
        context.completeRequest()
    }
}
#endif
