import XCTest
@testable import Vara
import VaraCore

/// The app-layer wording for failures + key validation. Guards that every known
/// reason gets a specific line, that `.other` stays generic (never echoes a raw
/// body), and that "no credit" reads differently from "bad key".
final class TranscriptionErrorMessageTests: XCTestCase {
    func testKnownReasonsGetSpecificActionableMessages() {
        let reasons: [APIFailureReason] = [.invalidKey, .insufficientQuota, .rateLimited, .noAccess, .network, .server]
        for reason in reasons {
            let message = DictationTranscriptionFailure.specificMessage(for: reason)
            XCTAssertNotNil(message, "reason \(reason) must map to a specific message")
            XCTAssertFalse(message?.isEmpty ?? true)
        }
    }

    func testOtherReasonStaysGeneric() {
        XCTAssertNil(
            DictationTranscriptionFailure.specificMessage(for: .other(status: 418, message: "I'm a teapot")),
            ".other must fall back to the generic message so we never echo a raw provider body"
        )
    }

    func testValidationStatusDistinguishesNoCreditFromBadKey() {
        let ok = VaraSettingsView.validationStatusText(nil)
        let badKey = VaraSettingsView.validationStatusText(.invalidKey)
        let noCredit = VaraSettingsView.validationStatusText(.insufficientQuota)
        XCTAssertFalse(ok.isEmpty)
        XCTAssertNotEqual(badKey, noCredit, "out-of-credit must not read as a rejected key")
        XCTAssertNotEqual(ok, badKey)
    }
}
