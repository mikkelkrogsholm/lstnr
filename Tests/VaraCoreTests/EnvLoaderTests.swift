import XCTest
@testable import VaraCore

final class EnvLoaderTests: XCTestCase {
    func testParsesBasicPairs() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vara-env-\(UUID()).env")
        let body = """
        # comment
        FOO=bar
        BAZ="quoted value"
        EMPTY=
        SPACED = trimmed
        """
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let env = try EnvLoader.load(from: tmp)
        XCTAssertEqual(env["FOO"], "bar")
        XCTAssertEqual(env["BAZ"], "quoted value")
        XCTAssertEqual(env["EMPTY"], "")
        XCTAssertEqual(env["SPACED"], "trimmed")
        XCTAssertNil(env["comment"])
    }
}
