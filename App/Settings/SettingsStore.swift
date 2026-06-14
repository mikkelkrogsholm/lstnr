import Foundation

final class LstnrSettingsStore {
    private let defaults: UserDefaults
    private let key: String
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        defaults: UserDefaults = .standard,
        key: String = "dk.56n.lstnr.settings.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> LstnrAppSettings {
        guard let data = defaults.data(forKey: key) else {
            return .defaults
        }

        return (try? decoder.decode(LstnrAppSettings.self, from: data)) ?? .defaults
    }

    func save(_ settings: LstnrAppSettings) throws {
        let data = try encoder.encode(settings)
        defaults.set(data, forKey: key)
    }

    func reset() {
        defaults.removeObject(forKey: key)
    }
}
