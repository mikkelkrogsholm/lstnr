import Foundation

/// "When dictating into this app, use that mode" — resolved automatically at
/// dictation start. A 1–9 digit override still wins over a rule.
struct AppModeRule: Codable, Hashable, Identifiable {
    var id: UUID
    var bundleID: String
    var appName: String
    var modeID: UUID

    init(id: UUID = UUID(), bundleID: String, appName: String, modeID: UUID) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.modeID = modeID
    }
}
