// Model picker + download flow for the on-device WhisperKit engine.

import VaraCore
import SwiftUI

/// Model picker shown only when the on-device WhisperKit engine is selected.
/// Selecting a model that isn't cached yet prompts to download it (with a
/// progress bar) up front, rather than stalling the first dictation.
struct WhisperKitModelSection: View {
    @Binding var draft: VaraSettingsDraft
    /// Live WhisperKit warm state from AppState; drives the post-download
    /// specialization progress / failed rows. `.notNeeded` when no AppState is
    /// injected (e.g. previews) — the rows simply don't show.
    var warmState: WhisperKitWarmState = .notNeeded
    /// Re-triggers prewarm from the `.failed` retry row.
    var onRetryPrewarm: () -> Void = {}

    // WhisperKit model download flow (confirm dialog + progress).
    @State private var whisperKitPendingModel: String?
    @State private var whisperKitDownloadingModel: String?
    @State private var whisperKitDownloadFraction: Double = 0
    @State private var whisperKitDownloadError: String?
    @State private var whisperKitDownloadTask: Task<Void, Never>?

    var body: some View {
        Section {
            Picker(selection: whisperKitModelBinding) {
                ForEach(WhisperKitBackend.availableModelIDs, id: \.self) { modelID in
                    Text(whisperKitModelLabel(modelID)).tag(modelID)
                }
            } label: {
                Text("Model", comment: "WhisperKit model picker label")
            }
            .disabled(whisperKitDownloadingModel != nil)

            whisperKitModelStatus
        } header: {
            Text("WhisperKit model", comment: "WhisperKit model section header")
        } footer: {
            Text("Models download once and are cached on this Mac, then run fully offline. Compressed Large v3 Turbo is the best balance for Danish; full Turbo is fastest; Small is a lightweight fallback.", comment: "WhisperKit model picker footer")
        }
        .alert(
            String(localized: "Download this model?", comment: "WhisperKit download confirm title"),
            isPresented: whisperKitConfirmPresented,
            presenting: whisperKitPendingModel
        ) { model in
            Button {
                startWhisperKitDownload(model)
            } label: {
                Text("Download", comment: "Confirm model download button")
            }
            Button(role: .cancel) {
                whisperKitPendingModel = nil
            } label: {
                Text("Cancel", comment: "Cancel model download button")
            }
        } message: { model in
            Text("\(whisperKitModelLabel(model)) (\(whisperKitModelApproxSize(model))) downloads to this Mac and then runs offline. It’s only downloaded once.", comment: "WhisperKit download confirm message")
        }
        .onAppear {
            // The section only mounts when WhisperKit is the selected backend.
            // Prompt to download the on-device model up front instead of stalling
            // the first dictation — only when its model isn't cached yet and no
            // download is already in flight. (Replaces the parent's former
            // .onChange(of: draft.speechBackend) coupling.)
            if whisperKitDownloadingModel == nil,
               !WhisperKitBackend.isModelDownloaded(draft.whisperKitModel) {
                whisperKitPendingModel = draft.whisperKitModel
            }
        }
    }

    /// Download progress / readiness row beneath the model picker.
    @ViewBuilder
    private var whisperKitModelStatus: some View {
        if let downloading = whisperKitDownloadingModel {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Downloading \(whisperKitModelLabel(downloading))…", comment: "WhisperKit downloading label")
                        .font(.caption)
                    Spacer()
                    Text(whisperKitDownloadFraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: whisperKitDownloadFraction)
                Button(role: .cancel) {
                    cancelWhisperKitDownload()
                } label: {
                    Text("Cancel", comment: "Cancel model download button")
                }
                .controlSize(.small)
            }
            .padding(.vertical, 2)
        } else if let error = whisperKitDownloadError {
            VStack(alignment: .leading, spacing: 4) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button {
                    startWhisperKitDownload(draft.whisperKitModel)
                } label: {
                    Text("Try again", comment: "Retry model download button")
                }
                .controlSize(.small)
            }
        } else if !WhisperKitBackend.isModelDownloaded(draft.whisperKitModel) {
            HStack {
                Label {
                    Text("Model not downloaded yet", comment: "WhisperKit model missing label")
                } icon: {
                    Image(systemName: "arrow.down.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    startWhisperKitDownload(draft.whisperKitModel)
                } label: {
                    Text("Download", comment: "Download model button")
                }
                .controlSize(.small)
            }
        } else {
            // Model is on disk; the warm state tells us whether the one-time ANE
            // specialization is still running (warming), failed, or done (warm).
            switch warmState {
            case .warming:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing the model for your Mac — one-time, may take a couple of minutes", comment: "WhisperKit specialization in-progress label")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            case .failed:
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text("Model preparation failed", comment: "WhisperKit specialization failed label")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    Button {
                        onRetryPrewarm()
                    } label: {
                        Text("Try again", comment: "Retry model download button")
                    }
                    .controlSize(.small)
                }
            case .warm, .notNeeded:
                Label {
                    Text("Downloaded — ready on this Mac", comment: "WhisperKit model ready label")
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Picker binding that intercepts selection: an already-cached model is applied
    /// immediately; a missing one defers application until the user confirms the
    /// download (`whisperKitPendingModel` drives the confirm dialog).
    private var whisperKitModelBinding: Binding<String> {
        Binding {
            draft.whisperKitModel
        } set: { newModel in
            guard newModel != draft.whisperKitModel else { return }
            if WhisperKitBackend.isModelDownloaded(newModel) {
                draft.whisperKitModel = newModel
            } else {
                whisperKitPendingModel = newModel
            }
        }
    }

    private var whisperKitConfirmPresented: Binding<Bool> {
        Binding {
            whisperKitPendingModel != nil
        } set: { presented in
            if !presented { whisperKitPendingModel = nil }
        }
    }

    /// Starts (or restarts) a model download, streaming progress into the UI and
    /// applying the model as active once it completes.
    private func startWhisperKitDownload(_ model: String) {
        whisperKitPendingModel = nil
        whisperKitDownloadError = nil
        whisperKitDownloadFraction = 0
        whisperKitDownloadingModel = model
        whisperKitDownloadTask?.cancel()
        whisperKitDownloadTask = Task { @MainActor in
            do {
                for try await fraction in WhisperKitBackend.downloadModel(model) {
                    whisperKitDownloadFraction = fraction
                }
                whisperKitDownloadingModel = nil
                // Apply only once the model is actually on disk; the draft change
                // persists settings and re-configures the backend.
                draft.whisperKitModel = model
            } catch is CancellationError {
                whisperKitDownloadingModel = nil
            } catch {
                whisperKitDownloadingModel = nil
                whisperKitDownloadError = "\(error)"
            }
        }
    }

    private func cancelWhisperKitDownload() {
        whisperKitDownloadTask?.cancel()
        whisperKitDownloadTask = nil
        whisperKitDownloadingModel = nil
    }

    /// Approximate on-disk download size, shown in the confirm dialog. These are
    /// ballpark figures (turbo measured; 626MB from the variant name; small rough).
    private func whisperKitModelApproxSize(_ model: String) -> String {
        switch model {
        case "large-v3-v20240930_turbo": "~1.5 GB"
        case "large-v3-v20240930_626MB": "~630 MB"
        case "small": "~0.5 GB"
        default: String(localized: "varies", comment: "Unknown model download size")
        }
    }
}
