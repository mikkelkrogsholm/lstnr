import XCTest
@testable import VaraCore

/// Coverage for EnvLoader.resolve — the "where does an API key come from" path
/// (env var precedence + nearest-.env-walking-up). Only the pure parser load()
/// was covered before; resolution is what the lstnr→vara purge broke once.
final class EnvLoaderResolveTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("envloader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func writeDotEnv(_ contents: String, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try contents.write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    }

    func testResolveReadsNearestDotEnvWalkingUp() throws {
        try writeDotEnv("MYKEY=parentval\n", in: tmp)
        let deep = tmp.appendingPathComponent("a/b/c", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        XCTAssertEqual(try EnvLoader.resolve("MYKEY", startingFrom: deep), "parentval")
    }

    func testResolveUsesNearestDotEnvAndDoesNotFallBackToFarther() throws {
        // Nearest .env (in child) lacks MYKEY; a farther one (parent) has it.
        // resolve uses the NEAREST .env only, so it must throw rather than reach
        // the parent value — pin this (arguably surprising) behavior.
        try writeDotEnv("MYKEY=parentval\n", in: tmp)
        let child = tmp.appendingPathComponent("child", isDirectory: true)
        try writeDotEnv("OTHERKEY=x\n", in: child)

        XCTAssertThrowsError(try EnvLoader.resolve("MYKEY", startingFrom: child))
    }

    func testResolveThrowsNotSetNamingTheKey() throws {
        let missingKey = "DEFINITELY_ABSENT_KEY_\(UUID().uuidString.prefix(8))"
        XCTAssertThrowsError(try EnvLoader.resolve(missingKey, startingFrom: tmp)) { error in
            XCTAssertTrue(String(describing: error).contains(missingKey))
        }
    }

    func testEnvironmentVariableBeatsDotEnv() throws {
        let key = "VARA_TEST_ENVWINS_\(UInt32.random(in: 0...999999))"
        setenv(key, "fromenv", 1)
        defer { unsetenv(key) }
        try writeDotEnv("\(key)=fromfile\n", in: tmp)

        XCTAssertEqual(try EnvLoader.resolve(key, startingFrom: tmp), "fromenv")
    }
}
