import Foundation

enum MailboxQAConfigurationError: Error {
    case missingBundleIdentity
    case missingContainerIdentity
    case missingKeychainIdentity
    case missingOutboxRoot
    case identityMismatch
    case productionIdentityRejected
}

private struct MailboxQAIdentityProfile: Sendable {
    let bundleSuffix: String
    let outboxRoot: String
    let urlScheme: String
    let targetName: String

    static let hidden = Self(
        bundleSuffix: ".mailboxqa",
        outboxRoot: "HealthBridgeMailboxQA",
        urlScheme: "healthbridgeqa",
        targetName: "HealthBridgeCompanionMailboxQA"
    )
    static let publicDocuments = Self(
        bundleSuffix: ".publicdocuments.mailboxqa",
        outboxRoot: "HealthBridgeMailboxPublicDocumentsQA",
        urlScheme: "healthbridgeqa-public-documents",
        targetName: "HealthBridgeCompanionPublicDocumentsQA"
    )

    static func resolve(bundleIdentifier: String) throws -> Self {
        if bundleIdentifier.hasSuffix(publicDocuments.bundleSuffix) {
            return publicDocuments
        }
        if bundleIdentifier.hasSuffix(hidden.bundleSuffix) {
            return hidden
        }
        throw MailboxQAConfigurationError.missingBundleIdentity
    }
}

struct MailboxQAConfiguration {
    let bundleIdentifier: String
    let containerIdentifier: String
    let keychainService: String
    let outboxRoot: String
    let urlScheme: String
    let sourceCommit: String
    let schemeName: String
    let targetName: String

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let bundleIdentifier = bundle.bundleIdentifier else {
            throw MailboxQAConfigurationError.missingBundleIdentity
        }
        let profile = try MailboxQAIdentityProfile.resolve(
            bundleIdentifier: bundleIdentifier
        )
        guard let container = bundle.object(
            forInfoDictionaryKey: "HealthBridgeQAICloudContainerIdentifier"
        ) as? String, container.hasSuffix(".mailboxqa") else {
            throw MailboxQAConfigurationError.missingContainerIdentity
        }
        guard let keychain = bundle.object(
            forInfoDictionaryKey: "HealthBridgeQAKeychainService"
        ) as? String, keychain.hasSuffix(".mailboxqa") else {
            throw MailboxQAConfigurationError.missingKeychainIdentity
        }
        guard let outbox = bundle.object(
            forInfoDictionaryKey: "HealthBridgeQAOutboxRoot"
        ) as? String, outbox == profile.outboxRoot else {
            throw MailboxQAConfigurationError.missingOutboxRoot
        }
        guard container == "iCloud.\(bundleIdentifier)",
              keychain == "\(bundleIdentifier).mailboxqa"
        else {
            throw MailboxQAConfigurationError.identityMismatch
        }
        guard let schemeName = bundle.object(
            forInfoDictionaryKey: "HealthBridgeQASchemeName"
        ) as? String, schemeName == profile.targetName,
              let targetName = bundle.object(
                  forInfoDictionaryKey: "HealthBridgeQATargetName"
              ) as? String, targetName == profile.targetName
        else {
            throw MailboxQAConfigurationError.productionIdentityRejected
        }
        guard let sourceCommit = bundle.object(
            forInfoDictionaryKey: "HealthBridgeQASourceCommit"
        ) as? String,
              sourceCommit.count == 40,
              sourceCommit.utf8.allSatisfy({
                  (48 ... 57).contains($0) || (97 ... 102).contains($0)
              })
        else {
            throw MailboxQAConfigurationError.productionIdentityRejected
        }
        return Self(
            bundleIdentifier: bundleIdentifier,
            containerIdentifier: container,
            keychainService: keychain,
            outboxRoot: outbox,
            urlScheme: profile.urlScheme,
            sourceCommit: sourceCommit,
            schemeName: schemeName,
            targetName: targetName
        )
    }
}
