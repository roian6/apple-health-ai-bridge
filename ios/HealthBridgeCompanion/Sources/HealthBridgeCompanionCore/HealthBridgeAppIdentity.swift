import Foundation

public enum HealthBridgeAppIdentity {
    public static let fallbackBundleIdentifier = "com.example.HealthBridgeCompanion"

    public static var bundleIdentifier: String {
        bundleIdentifier(from: .main)
    }

    public static func bundleIdentifier(from bundle: Bundle) -> String {
        normalizedBundleIdentifier(bundle.bundleIdentifier)
    }

    public static func normalizedBundleIdentifier(_ rawIdentifier: String?) -> String {
        let candidate = rawIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate, !candidate.isEmpty else {
            return fallbackBundleIdentifier
        }
        return candidate
    }

    public static var appRefreshIdentifier: String {
        "\(bundleIdentifier).refresh"
    }

    public static var backgroundUploadSessionIdentifier: String {
        "\(bundleIdentifier).background-upload.v2"
    }

    public static var legacyBackgroundUploadSessionIdentifiers: [String] {
        ["\(bundleIdentifier).background-upload"]
    }

    public static var keychainServiceName: String {
        "\(bundleIdentifier).receiver"
    }
}
