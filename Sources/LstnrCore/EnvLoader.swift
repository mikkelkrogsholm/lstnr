import Foundation

public enum EnvLoader {
    public static func load(from url: URL) throws -> [String: String] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var result: [String: String] = [:]
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    public static func findDotEnv(startingFrom: URL) -> URL? {
        var current = startingFrom.standardizedFileURL
        while current.path != "/" {
            let candidate = current.appendingPathComponent(".env")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            current.deleteLastPathComponent()
        }
        return nil
    }

    public static func resolve(_ key: String, startingFrom: URL? = nil) throws -> String {
        if let val = ProcessInfo.processInfo.environment[key], !val.isEmpty {
            return val
        }
        let cwd = startingFrom ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if let envFile = findDotEnv(startingFrom: cwd),
           let loaded = try? load(from: envFile),
           let val = loaded[key], !val.isEmpty {
            return val
        }
        throw EnvError.notSet(key)
    }

    /// Resolve for an .app bundle context: checks env, then `~/.lstnr/.env`,
    /// then `~/.config/lstnr/.env`. The working directory is irrelevant for bundles.
    public static func resolveForApp(_ key: String) throws -> String {
        if let val = ProcessInfo.processInfo.environment[key], !val.isEmpty {
            return val
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".lstnr/.env"),
            home.appendingPathComponent(".config/lstnr/.env"),
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path.path),
               let loaded = try? load(from: path),
               let val = loaded[key], !val.isEmpty {
                return val
            }
        }
        throw EnvError.notSet(key)
    }
}

public enum EnvError: Error, CustomStringConvertible {
    case notSet(String)
    public var description: String {
        switch self {
        case .notSet(let key): return "\(key) not set (checked environment and .env)"
        }
    }
}
