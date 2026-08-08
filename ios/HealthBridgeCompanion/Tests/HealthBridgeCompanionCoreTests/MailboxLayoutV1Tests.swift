import Foundation
import Testing
@testable import HealthBridgeCompanionCore

private let mailboxLayoutOpaque = "0123456789abcdef0123456789abcdef"

@Suite("Mailbox V1 lane grammar")
struct MailboxLayoutV1Tests {
    private let opaque = mailboxLayoutOpaque

    @Test("accepts only the exact final name for its lane")
    func finalNameWhenLaneMatches() throws {
        let name = try MailboxLayoutV1.finalFileName(
            identifier: opaque,
            kind: .delivery
        )

        let disposition = try MailboxLayoutV1.classify(
            fileName: name,
            in: .deliveries,
            byteCount: 2_097_152
        )

        #expect(disposition == .final(kind: .delivery, identifier: opaque))
    }

    @Test("ignores only a closed temporary suffix")
    func temporaryNameWhenSuffixIsExact() throws {
        let name = "\(opaque).hbd.fedcba9876543210fedcba9876543210.tmp"

        let disposition = try MailboxLayoutV1.classify(
            fileName: name,
            in: .deliveries,
            byteCount: 100
        )

        #expect(disposition == .temporary)
    }

    @Test(
        "rejects traversal, partial, wrong-lane, extension, and oversize inputs",
        arguments: [
            ("../\(mailboxLayoutOpaque).hbd", MailboxLaneV1.deliveries, Int64(1)),
            ("\(mailboxLayoutOpaque).hbd.partial", .deliveries, 1),
            ("\(mailboxLayoutOpaque).hba", .deliveries, 1),
            ("\(mailboxLayoutOpaque).unknown", .deliveries, 1),
            ("\(mailboxLayoutOpaque).hbd", .deliveries, 2_097_153),
        ]
    )
    func invalidNameWhenBoundaryIsUntrusted(
        fileName: String,
        lane: MailboxLaneV1,
        byteCount: Int64
    ) {
        #expect(throws: MailboxLayoutError.self) {
            try MailboxLayoutV1.classify(
                fileName: fileName,
                in: lane,
                byteCount: byteCount
            )
        }
    }

    @Test("rejects noncanonical opaque path components")
    func componentWhenNotLowerHex() {
        for value in ["..", "a/b", "A123456789abcdef0123456789abcdef", "abc"] {
            #expect(throws: MailboxLayoutError.self) {
                try MailboxLayoutV1.opaqueComponent(value)
            }
        }
    }
}
