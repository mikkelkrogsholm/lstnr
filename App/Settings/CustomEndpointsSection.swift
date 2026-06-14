// Manage user-defined OpenAI-compatible LLM endpoints.

import LstnrCore
import SwiftUI

/// Lists existing custom endpoints (with delete) and an inline add form. All
/// mutations go through the shared `draft.customEndpoints`.
struct CustomEndpointsSection: View {
    @Binding var draft: LstnrSettingsDraft

    @State private var isAddingEndpoint = false
    @State private var newEndpointName = ""
    @State private var newEndpointURL = ""

    var body: some View {
        Section {
            ForEach(draft.customEndpoints) { endpoint in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(endpoint.name)
                        Text(endpoint.baseURLString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button {
                        draft.customEndpoints.removeAll { $0.id == endpoint.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            if isAddingEndpoint {
                TextField(text: $newEndpointName, prompt: Text(verbatim: "DGX Spark")) {
                    Text("Name", comment: "Custom endpoint name field")
                }
                TextField(text: $newEndpointURL, prompt: Text(verbatim: "http://spark.local:11434/v1")) {
                    Text("Base URL", comment: "Custom endpoint URL field")
                }
                .autocorrectionDisabled()
                HStack {
                    Button {
                        let trimmedURL = newEndpointURL.trimmingCharacters(in: .whitespaces)
                        let trimmedName = newEndpointName.trimmingCharacters(in: .whitespaces)
                        guard !trimmedName.isEmpty, URL(string: trimmedURL) != nil else { return }
                        draft.customEndpoints.append(
                            CustomLLMEndpoint(name: trimmedName, baseURLString: trimmedURL)
                        )
                        newEndpointName = ""
                        newEndpointURL = ""
                        isAddingEndpoint = false
                    } label: {
                        Text("Add", comment: "Confirm adding custom endpoint")
                    }
                    Button {
                        isAddingEndpoint = false
                        newEndpointName = ""
                        newEndpointURL = ""
                    } label: {
                        Text("Cancel", comment: "Cancel adding custom endpoint")
                    }
                }
            } else {
                Button {
                    isAddingEndpoint = true
                } label: {
                    Label {
                        Text("Add OpenAI-compatible endpoint", comment: "Add custom endpoint button")
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
            }
        } header: {
            Text("Custom endpoints", comment: "Settings section header")
        } footer: {
            Text("Any OpenAI-compatible server: Ollama on another machine, LM Studio, vLLM …", comment: "Custom endpoints footer")
        }
    }
}
