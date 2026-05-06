import Foundation
import XCTest
@testable import LstnrCore

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

        XCTAssertTrue(status.hfHomeURL.path.contains("lstnr"))
        XCTAssertTrue(status.modelSnapshotURL.path.contains("models--syvai--hviske-v5.3"))
        XCTAssertTrue(status.modelSnapshotURL.path.hasSuffix(LocalHviskeBackend.modelRevision))
        XCTAssertEqual(status.isReady, status.hasPythonRuntime && status.hasModelSnapshot)
    }
}
