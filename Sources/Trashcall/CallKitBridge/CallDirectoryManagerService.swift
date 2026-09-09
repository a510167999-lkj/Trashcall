import Foundation

#if canImport(CallKit)
import CallKit
#endif

public enum TrashcallExtensionID {
    public static let identification = "com.trashcall.app.CallDirectoryExtension"
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
    public func reloadExtension(maxRetries: Int = 3) async throws {
        #if canImport(CallKit) && (os(iOS) || targetEnvironment(macCatalyst))
        var attempt = 0
        while true {
            do {
                try await performReload()
                return
            } catch {
                attempt += 1
                if isCurrentlyLoading(error) && attempt <= maxRetries {
                    try await Task.sleep(for: .milliseconds(800 * attempt))
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

    public func isCurrentlyLoading(_ error: Error) -> Bool {
        let nsError = error as NSError
        // CXErrorCodeCallDirectoryManagerError.currentlyLoading == 7
        // Apple's domain is "com.apple.CallKit.error.calldirectorymanager" (lowercase)
        return (nsError.domain.lowercased().contains("calldirectory") || nsError.domain.lowercased().contains("callkit")) && nsError.code == 7
    }
    #else
    public func isCurrentlyLoading(_ error: Error) -> Bool {
        return false
    }
    #endif
}
