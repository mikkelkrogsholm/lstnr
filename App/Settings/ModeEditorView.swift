import LstnrCore
import SwiftUI

/// Sheet for creating/editing a dictation mode: name, symbol, behavior,
/// system prompt and an optional pinned LLM.
struct ModeEditorView: View {
    @Binding var mode: DictationMode
    let customEndpoints: [CustomLLMEndpoint]
    let onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    private static let symbolChoices = [
        "sparkles", "briefcase", "waveform", "questionmark.bubble",
        "chevron.left.forwardslash.chevron.right", "envelope", "text.bubble",
        "list.bullet", "globe", "star", "pencil", "bolt",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    if mode.isBuiltIn {
                        LabeledContent {
                            Text(mode.displayTitle)
                        } label: {
                            Text("Name", comment: "Mode editor field")
                        }
                    } else {
                        TextField(text: $mode.name) {
                            Text("Name", comment: "Mode editor field")
                        }
                    }

                    Picker(selection: $mode.symbolName) {
                        ForEach(Self.symbolChoices, id: \.self) { symbol in
                            Image(systemName: symbol).tag(symbol)
                        }
                    } label: {
                        Text("Symbol", comment: "Mode editor field")
                    }

                    Picker(selection: $mode.behavior) {
                        Text("Insert raw transcript", comment: "Mode behavior option")
                            .tag(DictationMode.Behavior.insertRaw)
                        Text("Rewrite the transcript", comment: "Mode behavior option")
                            .tag(DictationMode.Behavior.rewrite)
                        Text("Answer the transcript", comment: "Mode behavior option")
                            .tag(DictationMode.Behavior.answer)
                    } label: {
                        Text("Behavior", comment: "Mode editor field")
                    }
                    .disabled(mode.isBuiltIn)
                }

                if mode.behavior != .insertRaw {
                    Section {
                        TextEditor(text: $mode.systemPrompt)
                            .font(.system(size: 12))
                            .frame(minHeight: 140)
                    } header: {
                        Text("Instructions to the LLM", comment: "Mode editor prompt section header")
                    } footer: {
                        Text("The transcript is sent as the user message; these instructions steer what comes back.", comment: "Mode editor prompt footer")
                    }

                    Section {
                        LLMSelectionPicker(
                            selection: $mode.llm,
                            customEndpoints: customEndpoints,
                            allowsDefault: true
                        )
                    } header: {
                        Text("Model", comment: "Mode editor LLM section header")
                    } footer: {
                        Text("“App default” uses the model chosen under Intelligence.", comment: "Mode editor LLM footer")
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if let onDelete, !mode.isBuiltIn {
                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: {
                        Text("Delete mode", comment: "Mode editor delete button")
                    }
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Text("Done", comment: "Mode editor done button")
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 480, height: mode.behavior == .insertRaw ? 280 : 560)
    }
}

/// Picker for an optional LLM selection (provider + model). With
/// `allowsDefault`, nil means "use the app default".
struct LLMSelectionPicker: View {
    @Binding var selection: LLMSelection?
    let customEndpoints: [CustomLLMEndpoint]
    var allowsDefault: Bool

    private enum ProviderTag: Hashable {
        case appDefault
        case provider(LLMProvider)
    }

    private var currentTag: ProviderTag {
        if let selection {
            return .provider(selection.provider)
        }
        return .appDefault
    }

    var body: some View {
        Picker(selection: providerBinding) {
            if allowsDefault {
                Text("App default", comment: "LLM picker option using the global default")
                    .tag(ProviderTag.appDefault)
            }
            Text(LLMProvider.anthropic.displayTitle).tag(ProviderTag.provider(.anthropic))
            Text(LLMProvider.openAI.displayTitle).tag(ProviderTag.provider(.openAI))
            Text(LLMProvider.groq.displayTitle).tag(ProviderTag.provider(.groq))
            Text(LLMProvider.ollama.displayTitle).tag(ProviderTag.provider(.ollama))
            ForEach(customEndpoints) { endpoint in
                Text(endpoint.name).tag(ProviderTag.provider(.custom(endpointID: endpoint.id)))
            }
        } label: {
            Text("Provider", comment: "LLM picker label")
        }

        if selection != nil {
            TextField(text: modelBinding, prompt: Text(verbatim: modelPlaceholder)) {
                Text("Model", comment: "LLM model field label")
            }
            .autocorrectionDisabled()
        }
    }

    private var providerBinding: Binding<ProviderTag> {
        Binding {
            currentTag
        } set: { newTag in
            switch newTag {
            case .appDefault:
                selection = nil
            case .provider(let provider):
                let keepModel = selection?.provider == provider
                selection = LLMSelection(
                    provider: provider,
                    model: keepModel ? (selection?.model ?? provider.defaultModel) : provider.defaultModel
                )
            }
        }
    }

    private var modelBinding: Binding<String> {
        Binding {
            selection?.model ?? ""
        } set: { newModel in
            if var current = selection {
                current.model = newModel
                selection = current
            }
        }
    }

    private var modelPlaceholder: String {
        selection?.provider.defaultModel ?? ""
    }
}
