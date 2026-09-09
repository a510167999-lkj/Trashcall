import Foundation

#if canImport(CallKit)
import CallKit
#endif

public enum TrashcallExtensionID {
    /// Bulk identification (labels) extension. Feeds identification numbers only.
    public static let identification = "com.trashcall.app.CallDirectoryExtension"
    /// Dedicated hang-up (blocking) extension. Feeds blocking numbers only.
    /// Required because iOS 26/27 drops blocking entries from mixed requests.
    public static let blocking = "com.trashcall.app.BlockDirectoryExtension"

    /// Both extensions, in reload order (identification first: cheaper failure surface).
    public static let all: [String] = [identification, blocking]
}

/// State of the CallKit extension in the system settings.
public enum ExtensionStatus: String, Sendable {
    case unknown = "未授权/未知"
    case disabled = "未在系统设置中开启"
    case enabled = "已开启并在保护中"
}

/// Service running in the Main App to coordinate extension status and trigger reloads.
public final class CallDirectoryManagerService: Sendable {
    public let extensionBundleIdentifier: String

    public init(extensionBundleIdentifier: String) {
        self.extensionBundleIdentifier = extensionBundleIdentifier
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
                try await performReload()
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
