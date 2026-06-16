import XCTest
@testable import Vara
import VaraCore

/// The settings-wipe guard: VaraAppSettings must decode a blob persisted by an
/// OLDER build (one that predates this session's vocabulary / microphoneProfile
/// / realtimeLatency keys) without throwing, falling back to defaults for the
/// missing keys while preserving everything else. A regression here resets a
/// user's whole configuration on upgrade.
final class VaraAppSettingsCodableTests: XCTestCase {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func defaultsAsMutableJSON() throws -> [String: Any] {
        let data = try encoder.encode(VaraAppSettings.defaults)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decode(_ json: [String: Any]) throws -> VaraAppSettings {
        let data = try JSONSerialization.data(withJSONObject: json)
        return try decoder.decode(VaraAppSettings.self, from: data)
    }

    func testDecodingLegacyBlobMissingNewKeysFallsBackToDefaults() throws {
        var json = try defaultsAsMutableJSON()
        // Simulate a settings blob written before this session's keys existed.
        json.removeValue(forKey: "vocabulary")
        json.removeValue(forKey: "microphoneProfile")
        json.removeValue(forKey: "realtimeLatency")
        // And change an OLD field, to prove old settings survive the upgrade.
        json["pasteAutomatically"] = false

        let settings = try decode(json)

        XCTAssertEqual(settings.vocabulary, [])
        XCTAssertEqual(settings.microphoneProfile, .nearField)
        XCTAssertEqual(settings.realtimeLatency, .auto)
        XCTAssertFalse(settings.pasteAutomatically, "pre-existing settings must survive the upgrade")
    }

    func testFullRoundTripIsLossless() throws {
        var settings = VaraAppSettings.defaults
        settings.vocabulary = ["Vara", "Krogsholm"]
        settings.microphoneProfile = .farField
        settings.realtimeLatency = .high
        settings.pasteAutomatically = false

        let restored = try decoder.decode(VaraAppSettings.self, from: try encoder.encode(settings))
        XCTAssertEqual(restored, settings)
    }

    func testHistoryLimitDraftClampStaysWithinBounds() {
        var settings = VaraAppSettings.defaults
        settings.historyLimit = 100_000
        XCTAssertLessThanOrEqual(settings.draft.historyLimit, 200)
        settings.historyLimit = 1
        XCTAssertGreaterThanOrEqual(settings.draft.historyLimit, 10)
    }

    func testUnknownEnumRawValueFallsBackPerFieldNotWipingEverything() throws {
        var json = try defaultsAsMutableJSON()
        // A value an older/newer build doesn't recognise (removed engine, typo,
        // downgrade). Before hardening, decodeIfPresent THREW here and the store
        // reset ALL settings; now each bad field independently falls back.
        json["speechBackend"] = "totally-unknown-engine"
        json["microphoneProfile"] = "bogus"
        json["pasteAutomatically"] = false   // a valid pre-existing field that must survive

        let settings = try decode(json)

        XCTAssertEqual(settings.speechBackend, VaraAppSettings.defaults.speechBackend,
                       "an unknown engine must fall back to default, not throw")
        XCTAssertEqual(settings.microphoneProfile, .nearField)
        XCTAssertFalse(settings.pasteAutomatically,
                       "one bad enum value must NOT wipe the rest of the user's settings")
    }
}

/// The shortcut key mapping is a pure data table with the same silent-rot risk
/// as the ?model= bug: a swapped modifier would break the persisted hotkey.
final class VaraShortcutChoiceTests: XCTestCase {
    func testEveryShortcutChoiceRoundTripsThroughItsKeySet() {
        for choice in VaraShortcutChoice.allCases {
            let keys = choice.globalHotkeyShortcut.keys
            XCTAssertFalse(keys.isEmpty, "\(choice) produced an empty key set")
            XCTAssertEqual(VaraShortcutChoice(keys: keys), choice, "\(choice) did not round-trip through its key set")
        }
    }

    func testAllShortcutChoicesHaveDistinctKeySetsAndSymbols() {
        let cases = VaraShortcutChoice.allCases
        let keySets = cases.map { $0.globalHotkeyShortcut.keys }
        XCTAssertEqual(Set(keySets).count, cases.count, "shortcut choices must map to distinct key sets")
        XCTAssertTrue(cases.allSatisfy { !$0.symbol.isEmpty })
    }
}
