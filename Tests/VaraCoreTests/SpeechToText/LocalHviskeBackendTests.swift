import Foundation
import XCTest
@testable import VaraCore

final class LocalHviskeBackendTests: XCTestCase {
    func testCapabilitiesDescribeLocalFileOnlyTranscription() {
        let backend = LocalHviskeBackend()

        XCTAssertEqual(backend.id, "local-hviske-v5.3")
        XCTAssertEqual(backend.displayName, "Local Hviske v5.3")
        XCTAssertTrue(backend.capabilities.supportsFileTranscription)
        XCTAssertFalse(backend.capabilities.supportsStreamingTranscription)
        XCTAssertTrue(backend.capabilities.supportsLanguageHints)
        XCTAssertFalse(backend.capabilities.supportsTimestamps)
        XCTAssertTrue(backend.capabilities.runsLocally)
        XCTAssertFalse(backend.capabilities.requiresNetwork)
        XCTAssertEqual(backend.capabilities.requiredCredentialKeys, [])
        XCTAssertEqual(backend.capabilities.supportedSampleRates, [16_000])
    }

    func testRuntimeStatusUsesPinnedHviskeSnapshotPath() {
        let status = LocalHviskeBackend.runtimeStatus()

        XCTAssertTrue(status.hfHomeURL.path.contains("vara"))
        XCTAssertTrue(status.modelSnapshotURL.path.contains("models--syvai--hviske-v5.3"))
        XCTAssertTrue(status.modelSnapshotURL.path.hasSuffix(LocalHviskeBackend.modelRevision))
        XCTAssertEqual(status.isReady, status.hasPythonRuntime && status.hasModelSnapshot)
    }

    // Locks the contract that scripts/setup-hviske.sh relies on: the out-of-app
    // Terminal installer writes the venv + model into these managed Application
    // Support paths, and detection here must keep pointing at them. The in-app
    // installer was removed (notarization), so detection is the only coupling.
    func testRuntimeStatusPointsAtManagedSupportPaths() {
        let status = LocalHviskeBackend.runtimeStatus()

        // Normally the managed HF home; a developer "spike" runtime is the only
        // other documented location runtimeStatus() may resolve to.
        XCTAssertTrue(status.hfHomeURL.path.contains("vara/models/huggingface")
            || status.hfHomeURL.path.contains("vara-hviske-spike"))
        if let pythonURL = status.pythonURL {
            XCTAssertTrue(pythonURL.path.contains("vara/hviske-venv")
                || pythonURL.path.contains("vara-hviske-spike"))
        }
    }
}
