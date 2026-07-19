#if canImport(HealthKit)
import HealthKit
import XCTest
@testable import HealthBridgeCompanionCore

final class HealthKitAnchorCursorCodecTests: XCTestCase {
    func testRoundTripsHealthKitQueryAnchorAsBase64CursorValue() throws {
        let anchor = HKQueryAnchor(fromValue: 42)

        let cursorValue = try HealthKitAnchorCursorCodec.encode(anchor)
        let decodedAnchor = try HealthKitAnchorCursorCodec.decode(cursorValue)

        XCTAssertFalse(cursorValue.isEmpty)
        XCTAssertNotNil(decodedAnchor)
    }

    func testDecodeRejectsMalformedAnchorCursorValue() {
        XCTAssertThrowsError(try HealthKitAnchorCursorCodec.decode("not base64")) { error in
            XCTAssertEqual(error as? HealthKitAnchorCursorCodecError, .invalidBase64)
        }
    }

    func testDecodeRejectsBase64ThatIsNotArchivedHealthKitAnchor() {
        let cursorValue = Data("not an archived HealthKit anchor".utf8).base64EncodedString()

        XCTAssertThrowsError(try HealthKitAnchorCursorCodec.decode(cursorValue)) { error in
            XCTAssertEqual(error as? HealthKitAnchorCursorCodecError, .decodeFailed)
        }
    }
}
#endif
