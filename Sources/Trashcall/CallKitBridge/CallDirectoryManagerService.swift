import Foundation

#if canImport(CallKit)
import CallKit
#endif

public enum TrashcallExtensionID {
    public static let identificationFallback = "com.trashcall.app.CallDirectoryExtension"
    public static let blockingFallback = "com.trashcall.app.BlockDirectoryExtension"

    /// Identification extension bundle ID as installed. 全能签 may rewrite the
    /// source IDs; CallKit status/reload must use the live PlugIns identifiers.
    public static var identification: String {
        discoveredIdentifier(matching: .identification) ?? identificationFallback
    }

    /// Blocking extension bundle ID as installed.
    public static var blocking: String {
        discoveredIdentifier(matching: .blocking) ?? blockingFallback
    }

    public static var all: [String] { [identification, blocking] }

    public static var embeddedCallDirectoryCount: Int {
        callDirectoryPlugInBundles().count
    }

    private enum Kind {
        case identification
        case blocking
    }

    private static func callDirectoryPlugInBundles() -> [Bundle] {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: plugins,
            includingPropertiesForKeys: nil
        )) ?? []
        return urls.compactMap { Bundle(url: $0) }.filter { bundle in
            let ext = bundle.infoDictionary?["NSExtension"] as? [String: Any]
            return ext?["NSExtensionPointIdentifier"] as? String == "com.apple.callkit.call-directory"
        }
    }

    private static func discoveredIdentifier(matching kind: Kind) -> String? {
        let bundles = callDirectoryPlugInBundles()
        if let best = bundles.max(by: { score($0, kind) < score($1, kind) }),
           score(best, kind) > 0 {
            return best.bundleIdentifier
        }
        guard bundles.count >= 2 else { return nil }
        let sorted = bundles.sorted {
            ($0.bundleIdentifier ?? "") < ($1.bundleIdentifier ?? "")
        }
        switch kind {
        case .identification: return sorted[0].bundleIdentifier
        case .blocking: return sorted[1].bundleIdentifier
        }
    }

    private static func score(_ bundle: Bundle, _ kind: Kind) -> Int {
        let id = bundle.bundleIdentifier?.lowercased() ?? ""
        let name = ((bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "").lowercased()
        let exec = ((bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String) ?? "").lowercased()
        switch kind {
        case .identification:
            var value = 0
            if name.contains("识别") || name.contains("identify") { value += 10 }
            if exec.contains("calldirectory") && !exec.contains("block") { value += 8 }
            if id.contains("calldirectory") && !id.contains("block") { value += 8 }
            if name.contains("挂断") || exec.contains("block") || id.contains("block") { value -= 20 }
            return value
        case .blocking:
            var value = 0
            if name.contains("挂断") || name.contains("block") { value += 10 }
            if exec.contains("block") { value += 8 }
            if id.contains("block") { value += 8 }
            if name.contains("识别") { value -= 20 }
            return value
        }
    }
}

/// State of the CallKit extension in the system settings.
public enum ExtensionStatus: String, Sendable {
    case unknown = "未授权/未知"
    case disabled = "未在系统设置中开启"
    case enabled = "已开启"
}

public enum DirectoryActivationStatus: Equatable, Sendable {
    case settingsDisabled
    case settingsUnknown
    case unavailable
    case pending
    case loaded(count: Int)
    case failed(String)

    public static func resolve(
        extensionStatus: ExtensionStatus, appGroupReady: Bool, revision: String?,
        acceptedRevision: String?, report: ExtensionRunReport?, reloadError: String?
    ) -> Self {
        if extensionStatus == .disabled { return .settingsDisabled }
        if extensionStatus == .unknown { return .settingsUnknown }
        if !appGroupReady { return .unavailable }
        if let reloadError { return .failed(reloadError) }
        guard let revision, let report, report.directoryRevision == revision else { return .pending }
        if let error = report.error { return .failed(error) }
        guard acceptedRevision == revision else { return .pending }
        return .loaded(count: report.blockingFed + report.identificationFed)
    }

    public var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }

    public var message: String {
        switch self {
        case .settingsDisabled: "系统设置未开启"
        case .settingsUnknown: "等待获取系统状态"
        case .unavailable: "扩展无法读取当前本地规则"
        case .pending: "已保存，等待系统加载"
        case .loaded(let count): "系统已加载 \(count) 条"
        case .failed(let error): "加载失败：\(error)"
        }
    }
}

/// Service running in the Main App to coordinate extension status and trigger reloads.
public final class CallDirectoryManagerService: Sendable {
    public let extensionBundleIdentifier: String

    public init(extensionBundleIdentifier: String) {
        self.extensionBundleIdentifier = extensionBundleIdentifier
    }

    public static func acceptedRevisionKey(_ extensionID: String) -> String {
        "call_directory_accepted_revision:" + extensionID
    }

    /// Checks whether the user has enabled the extension in iOS Settings -> Phone -> Call Blocking & Identification.
    public func checkStatus() async -> ExtensionStatus {
        #if canImport(CallKit) && (os(iOS) || targetEnvironment(macCatalyst))
        return await withCheckedContinuation { continuation in
            CXCallDirectoryManager.sharedInstance.getEnabledStatusForExtension(
                withIdentifier: extensionBundleIdentifier
            ) { status, error in
                if let _ = error {
                    continuation.resume(returning: .unknown)
                    return
                }
                switch status {
                case .enabled:
                    continuation.resume(returning: .enabled)
                case .disabled:
                    continuation.resume(returning: .disabled)
                case .unknown:
                    continuation.resume(returning: .unknown)
                @unknown default:
                    continuation.resume(returning: .unknown)
                }
            }
        }
        #else
        return .enabled
        #endif
    }

    /// Opens the system Call Blocking & Identification settings page (not the App's own settings).
    public func openCallDirectorySettings() async {
        #if canImport(CallKit) && (os(iOS) || targetEnvironment(macCatalyst))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            CXCallDirectoryManager.sharedInstance.openSettings { _ in
                continuation.resume()
            }
        }
        #endif
    }

    /// Triggers CallKit to reload the extension, ingesting new or updated data.
    ///
    /// On device, feeding hundreds of thousands of entries can keep the system busy
    /// well beyond ten seconds. While a reload is in flight, further reload attempts
    /// fail transiently with `CurrentlyLoading` (7) or `LoadingInterrupted` (2), so we
    /// retry with exponential backoff (0.6s → 1.2s → 2.4s → 4s capped) for up to
    /// ~40s before giving up. This prevents transient "策略设置失败" errors when the
    /// user toggles a strategy while another reload is still streaming.
    public func reloadExtension(maxAttempts: Int = 10) async throws {
        #if canImport(CallKit) && (os(iOS) || targetEnvironment(macCatalyst))
        var attempt = 0
        while true {
            do {
                let startedAt = Date().timeIntervalSince1970
                try await performReload()
                try recordAcceptedRevision(startedAt: startedAt)
                return
            } catch {
                attempt += 1
                if isTransientLoadingError(error) && attempt < maxAttempts {
                    let delayMs = min(600 * (1 << (attempt - 1)), 4000)
                    try await Task.sleep(for: .milliseconds(delayMs))
                    continue
                }
                throw error
            }
        }
        #endif
    }

    #if canImport(CallKit) && (os(iOS) || targetEnvironment(macCatalyst))
    private func recordAcceptedRevision(startedAt: TimeInterval) throws {
        let reportFile: String
        switch extensionBundleIdentifier {
        case TrashcallExtensionID.identification: reportFile = ExtensionRunReport.identifyFileName
        case TrashcallExtensionID.blocking: reportFile = ExtensionRunReport.blockFileName
        default: return
        }
        guard let report = ExtensionRunReport.load(fileName: reportFile),
              report.at >= startedAt, report.error == nil, let revision = report.directoryRevision else { return }
        let store = CallDirectoryStore(databaseURL: DatabaseBootstrap.databaseURL())
        try store.open(createIfNeeded: false)
        try store.setMetadata(key: Self.acceptedRevisionKey(extensionBundleIdentifier), value: revision)
    }

    private func performReload() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            CXCallDirectoryManager.sharedInstance.reloadExtension(
                withIdentifier: extensionBundleIdentifier
            ) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    /// Whether the error is a transient "system is busy loading" condition that is
    /// safe to retry. Covers both `CurrentlyLoading` (7) and `LoadingInterrupted` (2).
    public func isTransientLoadingError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let domain = nsError.domain.lowercased()
        guard domain.contains("calldirectory") || domain.contains("callkit") else { return false }
        return nsError.code == 2 || nsError.code == 7
    }

    /// Backwards-compatible alias for `isTransientLoadingError`.
    public func isCurrentlyLoading(_ error: Error) -> Bool {
        return isTransientLoadingError(error)
    }
    #else
    public func isCurrentlyLoading(_ error: Error) -> Bool {
        return false
    }
    #endif
}
