import Foundation

public enum SpeechToTextBackendRegistryError: Error, CustomStringConvertible {
    case duplicateBackendID(String)
    case unknownBackendID(String)

    public var description: String {
        switch self {
        case .duplicateBackendID(let id):
            return "Duplicate speech-to-text backend id: \(id)"
        case .unknownBackendID(let id):
            return "Unknown speech-to-text backend id: \(id)"
        }
    }
}
public struct SpeechToTextBackendRegistry: Sendable {
    private let backendsByID: [String: any SpeechToTextBackend]

    public init(backends: [any SpeechToTextBackend]) throws {
        var indexed: [String: any SpeechToTextBackend] = [:]
        for backend in backends {
            if indexed[backend.id] != nil {
                throw SpeechToTextBackendRegistryError.duplicateBackendID(backend.id)
            }
            indexed[backend.id] = backend
        }
        self.backendsByID = indexed
    }

    public var backends: [any SpeechToTextBackend] {
        backendsByID.values.sorted { $0.displayName < $1.displayName }
    }

    public func backend(id: String) throws -> any SpeechToTextBackend {
        guard let backend = backendsByID[id] else {
            throw SpeechToTextBackendRegistryError.unknownBackendID(id)
        }
        return backend
    }
}
