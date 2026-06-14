import LstnrCore
import SwiftUI

/// Developer diagnostics — the debug log lives here, out of the main window.
struct DiagnosticsView: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label {
                    Text("Diagnostics", comment: "Diagnostics window title label")
                } icon: {
                    Image(systemName: "stethoscope")
                }
                .font(BSTheme.display(15, weight: .semibold))
                .foregroundStyle(BSTheme.textPrimary)

                Spacer()

                Button {
                    state.copyDebugLog()
                } label: {
                    Label {
                        Text("Copy", comment: "Copy debug log button")
                    } icon: {
                        Image(systemName: "doc.on.doc")
                    }
                }

                Button {
                    state.clearDebugLog()
                } label: {
                    Label {
                        Text("Clear", comment: "Clear debug log button")
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
            }

            Text(state.debugLogFilePath)
                .font(BSTheme.mono(10))
                .foregroundStyle(BSTheme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if state.debugLogEntries.isEmpty {
                ContentUnavailableView(
                    String(localized: "No events yet", comment: "Empty diagnostics log"),
                    systemImage: "text.alignleft"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(state.debugLogEntries) { entry in
                            Text(entry.line)
                                .font(BSTheme.mono(10))
                                .foregroundStyle(BSTheme.textMuted)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 380)
        .background(BSTheme.background)
    }
}
