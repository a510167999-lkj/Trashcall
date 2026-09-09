import Foundation
import CallKit
#if canImport(TrashcallCore)
import TrashcallCore
#elseif canImport(Trashcall)
import Trashcall
#endif

/// Dedicated hang-up (blocking) Call Directory extension.
///
/// iOS 26/27 silently drops `addBlockingEntry` when the same request also carries
/// identification entries, which made every "自动挂断" number keep ringing. This
/// extension therefore feeds ONLY blocking numbers (`CallDirectoryFeedKind.blockingOnly`)
/// in a homogeneous request; labels are handled by the identification extension.
@objc(CallDirectoryBlockHandler)
final class CallDirectoryBlockHandler: TrashcallCallDirectoryProvider {

    override var appGroupIdentifier: String {
        return "group.com.trashcall.shared"
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
