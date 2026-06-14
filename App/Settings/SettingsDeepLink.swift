import Foundation

extension Notification.Name {
    static let varaShowSettingsSection = Notification.Name("dk.56n.vara.showSettingsSection")
}

/// Lets any view open the Settings window at a specific section: call
/// `request(_:)` first, then the `openSettings` environment action. The
/// settings view consumes the pending section both on appear (fresh window)
/// and via notification (window already open).
enum SettingsDeepLink {
    private static let pendingSectionKey = "dk.56n.vara.settings.pendingSection"

    static func request(_ section: VaraSettingsSection) {
        UserDefaults.standard.set(section.rawValue, forKey: pendingSectionKey)
        NotificationCenter.default.post(name: .varaShowSettingsSection, object: nil)
    }

    static func consumePending() -> VaraSettingsSection? {
        guard let rawValue = UserDefaults.standard.string(forKey: pendingSectionKey) else {
            return nil
        }
        UserDefaults.standard.removeObject(forKey: pendingSectionKey)
        return VaraSettingsSection(rawValue: rawValue)
    }
}
