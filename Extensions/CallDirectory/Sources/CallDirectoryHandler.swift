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

    override var feedKind: CallDirectoryFeedKind {
        return .identificationOnly
    }

    override var runReportFileName: String {
        return ExtensionRunReport.identifyFileName
    }
}
