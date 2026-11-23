import Foundation

/// Reads the entitlements actually stamped into this process's
/// `embedded.mobileprovision`. Sideload resigners (全能签 and similar) rewrite
/// these values; code must not assume the source-tree entitlements file.
enum SignedEntitlements {
    static func values(for key: String) -> [String] {
        guard let entitlements = dictionary() else { return [] }
        if let values = entitlements[key] as? [String] {
            return values
        }
        if let string = entitlements[key] as? String {
            return [string]
        }
        return []
    }

    static func dictionary() -> [String: Any]? {
        let urls = [
            Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            Optional(Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision"))
        ]
        for url in urls {
            guard let url,
                  FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let plistData = provisioningPlistData(from: data),
                  let plist = try? PropertyListSerialization.propertyList(
                    from: plistData,
                    options: [],
                    format: nil
                  ) as? [String: Any],
                  let entitlements = plist["Entitlements"] as? [String: Any] else {
                continue
            }
            return entitlements
        }
        return nil
    }

    private static func provisioningPlistData(from data: Data) -> Data? {
        let startMarker = Data("<plist".utf8)
        let endMarker = Data("</plist>".utf8)
        guard let start = data.range(of: startMarker),
              let end = data.range(of: endMarker, in: start.lowerBound..<data.endIndex) else {
            return nil
        }
        return Data(data[start.lowerBound..<end.upperBound])
    }
}
