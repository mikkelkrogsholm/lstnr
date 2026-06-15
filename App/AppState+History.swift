import Foundation
import VaraCore

// Dictation history (reload/delete/clear), transcript copy/reinsert, debug-log
// management, and the onboarding settings/credential mutations.
extension AppState {
    func copyTranscript(_ item: DictationHistoryItem) {
        ClipboardPaster.copyToClipboard(text: item.displayTranscript)
    }

    func reinsertTranscript(_ item: DictationHistoryItem) {
        ClipboardPaster.pasteAtCursor(text: item.displayTranscript)
        lastTranscript = item.displayTranscript
        statusMessage = String(localized: "Reinserted from history", comment: "Status message")
    }

    func deleteHistoryItem(_ item: DictationHistoryItem) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await historyStore.delete(id: item.id)
                await reloadHistory()
            } catch {
                lastError = "\(error)"
            }
        }
    }

    func clearHistory() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await historyStore.clear()
                await reloadHistory()
            } catch {
                lastError = "\(error)"
            }
        }
    }

    func savePendingHistory(insertionStatus: DictationInsertionStatus, generation: Int) async {
        guard let pendingEntry = await pendingHistory.take(matching: generation) else { return }
        do {
            _ = try await historyStore.add(
                rawTranscript: pendingEntry.rawResult.text,
                cleanedTranscript: pendingEntry.cleanedTranscriptForHistory,
                backend: pendingEntry.rawResult.backend,
                modeName: pendingEntry.modeName,
                targetAppName: pendingEntry.targetAppName,
                detectedLanguage: pendingEntry.rawResult.detectedLanguage,
                requestedLanguage: pendingEntry.requestedLanguage,
                audioDurationSeconds: pendingEntry.rawResult.audioDurationSeconds,
                elapsedTranscriptionSeconds: pendingEntry.rawResult.elapsedSeconds,
                insertionStatus: insertionStatus
            )
            await reloadHistory()
            log("History saved. insertionStatus=\(insertionStatus.rawValue)")
        } catch {
            lastError = "\(error)"
            log("History save failed: \(error)")
        }
    }

    func reloadHistory() async {
        do {
            historyItems = try await historyStore.listRecent()
            log("History loaded. itemCount=\(historyItems.count)")
        } catch {
            lastError = "\(error)"
            log("History load failed: \(error)")
        }
    }

    func copyDebugLog() {
        let text = debugLogEntries
            .reversed()
            .map(\.line)
            .joined(separator: "\n")
        ClipboardPaster.copyToClipboard(text: text)
        log("Debug log copied to clipboard")
    }

    func clearDebugLog() {
        debugLogEntries.removeAll()
        try? FileManager.default.removeItem(at: Self.debugLogFileURL())
        log("Debug log cleared")
    }

    /// Mutates, persists and broadcasts settings — used by onboarding.
    func updateSettings(_ mutate: (inout VaraAppSettings) -> Void) {
        var updated = settings
        mutate(&updated)
        settings = updated
        try? settingsStore.save(updated)
        NotificationCenter.default.post(name: .varaSettingsDidChange, object: nil)
    }

    /// Saves an API key from onboarding and reloads configuration.
    func saveCredential(_ key: String, for provider: VaraCredentialProvider) {
        try? credentialStore.saveCredential(
            key.trimmingCharacters(in: .whitespacesAndNewlines),
            for: provider
        )
        NotificationCenter.default.post(name: .varaCredentialsDidChange, object: nil)
    }

    func savedCredential(for provider: VaraCredentialProvider) -> String {
        (try? credentialStore.credential(for: provider)) ?? ""
    }
}
