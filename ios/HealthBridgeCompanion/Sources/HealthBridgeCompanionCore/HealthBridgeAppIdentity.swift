import Foundation

public enum HealthBridgeAppIdentity {
    public static let fallbackBundleIdentifier = "com.example.HealthBridgeCompanion"
    public static let sourceCommitInfoKey = "HealthBridgeSourceCommit"

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

    public static var mailboxKeychainServiceName: String {
        "\(bundleIdentifier).mailbox"
    }

    public static var ubiquityContainerIdentifier: String {
        "iCloud.\(bundleIdentifier)"
    }

    public static var embeddedSourceCommit: String? {
        embeddedSourceCommit(from: .main)
    }

    public static func embeddedSourceCommit(from bundle: Bundle) -> String? {
        guard let candidate = bundle.object(
            forInfoDictionaryKey: sourceCommitInfoKey
        ) as? String,
            candidate.count == 40,
            candidate.utf8.allSatisfy({ byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            })
        else {
            return nil
        }
        return candidate
    }
}
