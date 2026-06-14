// Detect-and-guide section for the on-device Hviske runtime.

import AppKit
import VaraCore
import SwiftUI

/// Detect-and-guide for on-device Hviske. The shipped, notarized app never
/// downloads or runs a Python installer — the user runs scripts/setup-hviske.sh
/// in Terminal (which writes to the exact paths runtimeStatus() detects), and
/// Vara just reports what it finds and links to the instructions.
struct LocalHviskeSection: View {
    @State private var localHviskeStatus = LocalHviskeBackend.runtimeStatus()

    var body: some View {
        Section {
            LabeledContent {
                Label(
                    localHviskeStatus.hasPythonRuntime
                        ? String(localized: "Detected", comment: "Hviske runtime status")
                        : String(localized: "Not set up", comment: "Hviske runtime status"),
                    systemImage: localHviskeStatus.hasPythonRuntime ? "checkmark.circle" : "circle.dashed"
                )
                .foregroundStyle(localHviskeStatus.hasPythonRuntime ? .green : .secondary)
            } label: {
                Text("Runtime", comment: "Hviske status row label")
            }

            LabeledContent {
                Label(
                    localHviskeStatus.hasModelSnapshot
                        ? String(localized: "Detected", comment: "Hviske model status")
                        : String(localized: "Not set up", comment: "Hviske model status"),
                    systemImage: localHviskeStatus.hasModelSnapshot ? "checkmark.circle" : "circle.dashed"
                )
                .foregroundStyle(localHviskeStatus.hasModelSnapshot ? .green : .secondary)
            } label: {
                Text("Model", comment: "Hviske status row label")
            }

            LabeledContent {
                Text(verbatim: localHviskeStatus.pythonURL?.path ?? localHviskeExpectedPythonPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } label: {
                Text("Runtime path", comment: "Hviske detected runtime path label")
            }

            LabeledContent {
                Text(verbatim: localHviskeStatus.hfHomeURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } label: {
                Text("Model path", comment: "Hviske detected model path label")
            }

            HStack {
                Button {
                    refreshLocalHviskeStatus()
                } label: {
                    Text("Re-check", comment: "Hviske re-check status button")
                }

                Button {
                    copyHviskeSetupCommand()
                } label: {
                    Text("Copy setup command", comment: "Hviske copy setup command button")
                }

                Spacer()

                Link(destination: hviskeSetupGuideURL) {
                    Text("How to set up Hviske", comment: "Hviske setup guide link")
                }
            }
        } header: {
            Text("Hviske on this Mac", comment: "Hviske section header")
        } footer: {
            Text("Hviske runs Danish speech entirely on this Mac. Set it up once in Terminal, then Vara detects it here.", comment: "Hviske detect-and-guide footer")
        }
        .onAppear {
            // Re-detect on mount so a freshly-opened Advanced tab shows current
            // status. (Replaces the parent's former .onAppear refresh call.)
            refreshLocalHviskeStatus()
        }
    }

    /// The managed venv python path the setup script writes to — shown when no
    /// runtime is detected yet so the user knows where Vara is looking.
    private var localHviskeExpectedPythonPath: String {
        localHviskeStatus.hfHomeURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("hviske-venv/bin/python")
            .path
    }

    /// Terminal command that runs the out-of-app Hviske setup script.
    private var hviskeSetupCommand: String {
        "bash scripts/setup-hviske.sh"
    }

    private var hviskeSetupGuideURL: URL {
        URL(string: "https://brokk-sindre.dk/vara/hviske")!
    }

    private func copyHviskeSetupCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hviskeSetupCommand, forType: .string)
    }

    private func refreshLocalHviskeStatus() {
        localHviskeStatus = LocalHviskeBackend.runtimeStatus()
    }
}
