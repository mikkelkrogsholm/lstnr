import Foundation

/// Thread-safe holder for a spawned `Process` so the task-cancellation handler
/// (running on a different thread) can terminate it. The `Process` itself is not
/// `Sendable`; this box is the controlled exception that keeps it reachable for
/// `terminate()` without leaking the process across the concurrency boundary.
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ process: Process) {
        lock.withLock {
            self.process = process
        }
    }

    func clear() {
        lock.withLock {
            process = nil
        }
    }

    func terminate() {
        lock.withLock {
            guard let process, process.isRunning else { return }
            process.terminate()
        }
    }
}

/// Runs an external process off the main actor and returns its captured output
/// and exit code. The non-`Sendable` `Process` stays entirely inside the
/// `Task.detached` body; the only thing that crosses the cancellation boundary
/// is the `@unchecked Sendable` `ProcessBox` used to terminate a hung child.
///
/// Unlike a per-caller helper, this NEVER throws on a non-zero exit — it returns
/// the exit code so each caller maps its own error (Hviske throws
/// `processFailed`, the CLI chat client throws `ChatClientError`). It still
/// throws `CancellationError` if the surrounding task was cancelled.
///
/// - Parameter currentDirectory: working directory for the child. `codex`
///   resets the shell cwd, so it must be spawned in an explicit temp dir.
func runSubprocess(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectory: URL? = nil,
    stdin: String? = nil
) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
    let processBox = ProcessBox()

    return try await withTaskCancellationHandler {
        try await Task.detached {
            try Task.checkCancellation()

            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            if let currentDirectory {
                process.currentDirectoryURL = currentDirectory
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdoutTask = Task.detached {
                stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let stderrTask = Task.detached {
                stderrPipe.fileHandleForReading.readDataToEndOfFile()
            }

            processBox.set(process)
            defer { processBox.clear() }

            if let stdin {
                let stdinPipe = Pipe()
                process.standardInput = stdinPipe
                try process.run()
                if let data = stdin.data(using: .utf8) {
                    try stdinPipe.fileHandleForWriting.write(contentsOf: data)
                }
                try stdinPipe.fileHandleForWriting.close()
            } else {
                try process.run()
            }

            process.waitUntilExit()
            let stdoutData = await stdoutTask.value
            let stderrData = await stderrTask.value
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""

            if Task.isCancelled {
                throw CancellationError()
            }

            return (stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
        }.value
    } onCancel: {
        processBox.terminate()
    }
}

/// Resolves an executable by name, searching the current `PATH` plus the common
/// directories a launched `.app` does NOT inherit (Homebrew, `~/.local/bin`,
/// `~/.bun/bin`, etc.). A GUI process starts with a minimal `PATH` — often just
/// `/usr/bin:/bin:/usr/sbin:/sbin` — so a bare lookup would miss CLIs the user
/// installed via Homebrew/npm/bun. The same resolver is used for both detection
/// and execution, so the UI never offers a tool that then fails to spawn.
///
/// An optional `VARA_CLI_PATH` env var (colon-separated) is searched first so a
/// user with a non-standard install location can point Vara at it.
func resolveExecutable(named name: String) -> URL? {
    let fileManager = FileManager.default
    let home = fileManager.homeDirectoryForCurrentUser.path

    var searchPaths: [String] = []

    if let override = ProcessInfo.processInfo.environment["VARA_CLI_PATH"], !override.isEmpty {
        searchPaths.append(contentsOf: override.split(separator: ":").map(String.init))
    }
    if let path = ProcessInfo.processInfo.environment["PATH"], !path.isEmpty {
        searchPaths.append(contentsOf: path.split(separator: ":").map(String.init))
    }
    // The GUI-app PATH gap: directories a Terminal shell has but a launched
    // .app usually does not. Order matters only for duplicates, which we de-dup.
    searchPaths.append(contentsOf: [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "\(home)/.local/bin",
        "\(home)/.bun/bin",
        "\(home)/.npm-global/bin",
        "/opt/homebrew/sbin",
        "/usr/bin",
        "/bin",
    ])

    var seen = Set<String>()
    for directory in searchPaths {
        guard seen.insert(directory).inserted else { continue }
        let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
        if fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}
