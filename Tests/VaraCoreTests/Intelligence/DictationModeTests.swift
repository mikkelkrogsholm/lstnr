import XCTest
@testable import VaraCore

/// Coverage for the built-in dictation modes: the behavior map (which mode does
/// raw/rewrite/answer) and the prompt-injection hardening of every LLM-backed
/// mode's system prompt. A regression here either changes what a mode does or
/// drops the guard that stops a dictated transcript from hijacking the LLM.
final class DictationModeTests: XCTestCase {
    private func builtIn(_ id: UUID) -> DictationMode {
        DictationMode.builtInModes().first { $0.id == id }!
    }

    func testBuiltInBehaviorMap() {
        XCTAssertEqual(builtIn(DictationMode.rawModeID).behavior, .insertRaw)
        XCTAssertEqual(builtIn(DictationMode.cleanModeID).behavior, .rewrite)
        XCTAssertEqual(builtIn(DictationMode.professionalModeID).behavior, .rewrite)
        XCTAssertEqual(builtIn(DictationMode.vibeCodeModeID).behavior, .rewrite)
        XCTAssertEqual(builtIn(DictationMode.askAIModeID).behavior, .answer)
    }

    func testRawModeHasNoSystemPrompt() {
        XCTAssertEqual(builtIn(DictationMode.rawModeID).systemPrompt, "")
    }

    func testLLMModesArePromptInjectionHardened() {
        let hardened = [
            DictationMode.cleanModeID,
            DictationMode.professionalModeID,
            DictationMode.vibeCodeModeID,
            DictationMode.askAIModeID,
        ]
        for id in hardened {
            let mode = builtIn(id)
            let prompt = mode.systemPrompt.lowercased()
            XCTAssertTrue(
                prompt.contains("never as instructions")
                    || prompt.contains("strictly as")
                    || prompt.contains("cannot change")
                    || prompt.contains("cannot make you"),
                "\(mode.name)'s system prompt must harden against transcript-borne prompt injection"
            )
        }
    }

    func testBuiltInModesAreMarkedBuiltInWithDistinctStableIDs() {
        let modes = DictationMode.builtInModes()
        XCTAssertEqual(modes.count, 5)
        XCTAssertTrue(modes.allSatisfy(\.isBuiltIn))
        XCTAssertEqual(Set(modes.map(\.id)).count, modes.count, "built-in mode IDs must be unique + stable")
    }
}
