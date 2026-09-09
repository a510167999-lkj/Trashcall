import Foundation

/// Written by the Call Directory extension after each `beginRequest`.
/// The main app reads it to show whether the system actually ingested numbers.
public struct ExtensionRunReport: Codable, Sendable {
    public var at: TimeInterval
    public var incremental: Bool
    public var appGroupOK: Bool
    public var dbExists: Bool
    public var blockingFed: Int
    public var identificationFed: Int
    public var feedKind: String
    public var probedNumbers: [Int64]
    public var error: String?

    public static let defaultFileName = "extension_last_run.json"
    public static let identifyFileName = "extension_last_run_identify.json"
    public static let blockFileName = "extension_last_run_block.json"

    public init(
        at: TimeInterval = Date().timeIntervalSince1970,
        incremental: Bool,
        appGroupOK: Bool,
        dbExists: Bool,
        blockingFed: Int = 0,
        identificationFed: Int = 0,
        feedKind: String = CallDirectoryFeedKind.full.rawValue,
        probedNumbers: [Int64] = [],
        error: String? = nil
    ) {
        self.at = at
        self.incremental = incremental
        self.appGroupOK = appGroupOK
        self.dbExists = dbExists
        self.blockingFed = blockingFed
        self.identificationFed = identificationFed
        self.feedKind = feedKind
        self.probedNumbers = probedNumbers
        self.error = error
    }

    public static func fileURL(fileName: String = defaultFileName) -> URL? {
        DatabaseBootstrap.supportDirectory().appendingPathComponent(fileName)
    }

    public static func load(fileName: String = defaultFileName) -> ExtensionRunReport? {
        guard let url = fileURL(fileName: fileName), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ExtensionRunReport.self, from: data)
    }

    public func save(fileName: String = defaultFileName) {
        guard let url = Self.fileURL(fileName: fileName) else { return }
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
