import Foundation
import Security

/// One-time data migration from the old "lstnr" identity to the new "vara"
/// identity, run once when an existing user first launches the rebranded build.
///
/// The bundle-id flip (dk.56n.lstnr -> dk.56n.vara) changes every namespace that
/// the user's data lives under: `UserDefaults.standard` is keyed by bundle id (so
/// the new domain is empty), the Keychain service string changed, and the App
/// Support / dotfile folders are named after the old brand. Without this the user
/// would silently lose their settings, API keys, dictation history, onboarding
/// state, and — most expensively — the ~2GB of on-device WhisperKit models and
/// the Hviske venv would re-download.
///
/// This is the ONLY file in the codebase where the literal string "lstnr" is
/// allowed to remain: it exists solely to read the old locations.
///
/// IMPORTANT (call site / ordering): this MUST run before `AppState.init()`
/// loads settings or touches App Support. It is invoked as the very first
/// statement of `AppState.init()`. See `AppState.swift`.
enum VaraMigration {
    // New-domain (dk.56n.vara) idempotence gate. If set, the whole migration is
    // skipped. Set true only after every step has completed without throwing.
    private static let completionFlagKey = "dk.56n.vara.migration.lstnr.v1"

    // Old runtime-state identifiers (the only legitimate remaining "lstnr"s).
    private static let oldDefaultsSuiteName = "dk.56n.lstnr"
    private static let oldSettingsKey = "dk.56n.lstnr.settings.v1"
    private static let newSettingsKey = "dk.56n.vara.settings.v1"
    private static let oldOnboardingKey = "dk.56n.lstnr.onboarding.completed.v1"
    private static let newOnboardingKey = "dk.56n.vara.onboarding.completed.v1"
    private static let oldKeychainService = "dk.56n.lstnr.credentials"
    private static let newKeychainService = "dk.56n.vara.credentials"

    /// Synchronous, idempotent, and never throws to the caller. Each step is
    /// individually guarded and wrapped so one failure (e.g. Keychain) does not
    /// block the others; the completion flag is only set once all steps run
    /// cleanly, so an interrupted run is safe to retry on the next launch.
    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: completionFlagKey) else { return }

        var allSucceeded = true

        do { try migrateAppSupportFolder() } catch { allSucceeded = false }
        do { try migrateSettingsBlob(defaults: defaults) } catch { allSucceeded = false }
        do { try migrateOnboardingFlag(defaults: defaults) } catch { allSucceeded = false }
        do { try migrateKeychain() } catch { allSucceeded = false }
        do { try migrateDotfiles() } catch { allSucceeded = false }
        // Step 6 is optional/low-risk (cache is re-created on demand); a failure
        // here should not gate completion of the user-visible migration.
        try? migrateHviskeCache()

        if allSucceeded {
            defaults.set(true, forKey: completionFlagKey)
        }
        // On any failure we deliberately leave the flag unset so the next launch
        // retries; each step's own guard makes already-done steps no-ops.
    }

    // MARK: - Step 1: App Support folder MOVE (preserves ~2GB models)

    /// Renames `~/Library/Application Support/lstnr` to `.../vara`. A move (rename
    /// on the same volume) is instant and preserves the WhisperKit models,
    /// dictation history, debug.log, and the Hviske venv/HF cache — never a copy.
    private static func migrateAppSupportFolder() throws {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let src = base.appendingPathComponent("lstnr", isDirectory: true)
        let dst = base.appendingPathComponent("vara", isDirectory: true)

        // Already migrated (or fresh vara install with data): leave both.
        if directoryExistsNonEmpty(dst) { return }
        // Nothing to migrate (fresh install).
        guard fm.fileExists(atPath: src.path) else { return }

        // An empty dst would make moveItem throw "already exists"; remove it first.
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        try fm.moveItem(at: src, to: dst)
    }

    // MARK: - Step 2: Settings blob (UserDefaults)

    /// Copies the encoded `VaraAppSettings` blob from the old bundle-id domain to
    /// `.standard` under the new key. The old data is unreadable from `.standard`
    /// after the bundle-id flip, so the old suite must be opened explicitly.
    private static func migrateSettingsBlob(defaults std: UserDefaults) throws {
        guard std.data(forKey: newSettingsKey) == nil else { return }
        guard let old = UserDefaults(suiteName: oldDefaultsSuiteName) else { return }
        guard let blob = old.data(forKey: oldSettingsKey) else { return }
        std.set(blob, forKey: newSettingsKey)
    }

    // MARK: - Step 3: Onboarding completed flag (UserDefaults)

    /// Carries over "onboarding completed" so an existing user is not shown the
    /// welcome flow again. Reads from the old suite (not `.standard`).
    private static func migrateOnboardingFlag(defaults std: UserDefaults) throws {
        guard std.object(forKey: newOnboardingKey) == nil else { return }
        guard let old = UserDefaults(suiteName: oldDefaultsSuiteName) else { return }
        guard old.object(forKey: oldOnboardingKey) != nil else { return }
        std.set(old.bool(forKey: oldOnboardingKey), forKey: newOnboardingKey)
    }

    // MARK: - Step 4: Keychain generic-password items

    /// Best-effort copy of every generic-password item from the old service to
    /// the new one. Enumerates ALL items (so per-endpoint
    /// `custom-endpoint.<uuid>.api-key` accounts come along), skips any account
    /// already present under the new service, and matches the existing store's
    /// accessibility class. Old items are left in place (copy, not move).
    ///
    /// CROSS-SIGNATURE CAVEAT: the old items were created under the previous code
    /// signature (dk.56n.lstnr). A differently-signed binary (dk.56n.vara)
    /// reading their *data* triggers a keychain ACL check, which would otherwise
    /// (a) pop an interactive authorization dialog on every launch and (b) return
    /// an error when run headlessly. We therefore suppress that UI
    /// (`kSecUseAuthenticationUIFail`) and treat an unreadable old store as
    /// "nothing to migrate" — returning cleanly rather than throwing. The keys
    /// are recoverable via the `~/.vara/.env` fallback or re-entry, so a
    /// cross-signature read failure must NEVER wedge the whole migration: if this
    /// step threw, `runIfNeeded`'s completion flag would never be set and the
    /// entire migration would re-run on every single launch.
    private static func migrateKeychain() throws {
        let copyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: oldKeychainService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            // Never block launch on a keychain prompt; fail the read instead.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(copyQuery as CFDictionary, &result)
        // errSecItemNotFound: no old items. errSecInteractionNotAllowed /
        // errSecAuthFailed: old items exist but are locked to the previous code
        // signature and cannot be read without UI. All of these mean "nothing we
        // can migrate" — return cleanly so the completion flag is allowed to set.
        guard status == errSecSuccess else { return }
        guard let items = result as? [[String: Any]] else { return }

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else {
                continue
            }
            // Idempotent: skip if the new service already has this account.
            if newServiceHasAccount(account) { continue }

            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: newKeychainService,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            // Tolerate a benign race where the item appeared between the check
            // and the add; surface anything else so the flag is not set.
            guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
                throw VaraKeychainError.unhandledStatus(addStatus)
            }
        }
    }

    private static func newServiceHasAccount(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: newKeychainService,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - Step 5: Dotfiles (~/.lstnr, ~/.config/lstnr)

    /// Moves `~/.lstnr` -> `~/.vara` and `~/.config/lstnr` -> `~/.config/vara`
    /// (each only if the old exists and the new does not). These hold just the
    /// `.env` API-key file, so a move is cheap and lossless.
    private static func migrateDotfiles() throws {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        try moveIfPossible(
            src: home.appendingPathComponent(".lstnr", isDirectory: true),
            dst: home.appendingPathComponent(".vara", isDirectory: true)
        )

        let configDir = home.appendingPathComponent(".config", isDirectory: true)
        let configSrc = configDir.appendingPathComponent("lstnr", isDirectory: true)
        if fm.fileExists(atPath: configSrc.path) {
            try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        }
        try moveIfPossible(
            src: configSrc,
            dst: configDir.appendingPathComponent("vara", isDirectory: true)
        )
    }

    // MARK: - Step 6: Hviske cache (optional, low-risk)

    /// Moves `~/.cache/lstnr-hviske-spike` -> `~/.cache/vara-hviske-spike` to
    /// avoid re-creating the venv / re-downloading HF weights. Safe to omit; the
    /// backend re-creates this on demand.
    private static func migrateHviskeCache() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cache = home.appendingPathComponent(".cache", isDirectory: true)
        try moveIfPossible(
            src: cache.appendingPathComponent("lstnr-hviske-spike", isDirectory: true),
            dst: cache.appendingPathComponent("vara-hviske-spike", isDirectory: true)
        )
    }

    // MARK: - Helpers

    /// Moves `src` to `dst` only when `src` exists and `dst` does not. No-op
    /// (idempotent) otherwise.
    private static func moveIfPossible(src: URL, dst: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { return }
        guard !fm.fileExists(atPath: dst.path) else { return }
        try fm.moveItem(at: src, to: dst)
    }

    private static func directoryExistsNonEmpty(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        let contents = try? fm.contentsOfDirectory(atPath: url.path)
        return (contents?.isEmpty == false)
    }
}
