import Foundation
import CallKit
#if canImport(TrashcallCore)
import TrashcallCore
#elseif canImport(Trashcall)
import Trashcall
#endif
@objc(CallDirectoryBlockHandler)
final class CallDirectoryBlockHandler: TrashcallCallDirectoryProvider {

    override var appGroupIdentifier: String {
        return DatabaseBootstrap.appGroupId
    }

    override var databaseFileName: String {
        return "trashcall.sqlite"
    }

    override var feedKind: CallDirectoryFeedKind {
        return .blockingOnly
    }

    override var runReportFileName: String {
        return ExtensionRunReport.blockFileName
    }
}
