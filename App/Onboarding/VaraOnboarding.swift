import Foundation

enum VaraOnboarding {
    /// UserDefaults flag; false (or absent) shows the welcome flow.
    static let completedDefaultsKey = "dk.56n.lstnr.onboarding.completed.v1"

    static var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedDefaultsKey)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completedDefaultsKey)
    }
}
