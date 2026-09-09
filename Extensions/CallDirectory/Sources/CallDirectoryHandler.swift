import Foundation
import CallKit
#if canImport(TrashcallCore)
import TrashcallCore
#elseif canImport(Trashcall)
import Trashcall
#endif

@objc(CallDirectoryHandler)
final class CallDirectoryHandler: TrashcallCallDirectoryProvider {

    override var appGroupIdentifier: String {
        return "group.com.trashcall.shared"
    }

    override var databaseFileName: String {
        return "trashcall.sqlite"
    }

    /// Homogeneous identification-only request. Blocking entries are fed by the
    /// dedicated TrashcallBlockDirectory extension: iOS 26/27 drops blocking
    /// entries from mixed (blocking + identification) requests.
    override var feedKind: CallDirectoryFeedKind {
        return .identificationOnly
    }

    override var runReportFileName: String {
        return ExtensionRunReport.identifyFileName
    }
}
