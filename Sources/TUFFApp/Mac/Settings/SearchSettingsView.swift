import TUFFAppCore
import TUFFMacPresentation
import SwiftUI

/// Where web searches go, the keys for providers that need one, and the
/// folders file search may read.
struct SearchSettingsView: View {
    @Bindable var model: AppModel
    @State private var keyDrafts: [AppSearchProviderKind: String] = [:]
    @State private var confirmingRemoval = false

    var body: some View {
        Form {
            Section("Web search") {
                Picker("Provider", selection: $model.searchProvider) {
                    ForEach(AppSearchProviderKind.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                Text(model.searchProvider.privacyNote)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.searchProvider.requiresKey {
                    keyRow(model.searchProvider)
                }
                Text("Web search sends only the model's search query. The contents of your files are never sent to a search provider, and a query that copies text from them is refused.")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Files") {
                FolderAccessPanel(model: model)
                if !model.toolStore.folders.isEmpty {
                    Button("Remove All Folders and Delete Index…", role: .destructive) {
                        confirmingRemoval = true
                    }
                }
            }
            Section("Limits") {
                let limits = AppToolLimits.standard
                Text("Each answer may use up to \(limits.maximumToolRounds) rounds of tools, \(limits.maximumWebRequests) web requests and \(limits.maximumFileSearches) file searches, within \(Int(limits.maximumToolSeconds)) seconds. Pages are read up to \(AppWebPageReader.maximumBytes / 1_048_576) MB. Results are shortened to fit the model's context.")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = model.toolSupport.note {
                    Label(note, systemImage: "info.circle")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.toolStore.refreshKeyPresence() }
        .confirmationDialog("Remove every folder and delete the search index?",
                            isPresented: $confirmingRemoval) {
            Button("Remove All", role: .destructive) {
                model.toolStore.removeAllFolders()
                model.fileSearchEnabled = false
            }
        } message: {
            Text("Your files are not touched. TUFF stops reading the folders and deletes its index of them.")
        }
    }

    private func keyRow(_ provider: AppSearchProviderKind) -> some View {
        let saved = model.toolStore.keyPresence[provider] == true
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField(saved ? "Replace the saved key" : "\(provider.displayName) API key",
                            text: Binding(get: { keyDrafts[provider] ?? "" },
                                          set: { keyDrafts[provider] = $0 }))
                    .textContentType(.password)
                Button("Save") {
                    model.toolStore.setKey(keyDrafts[provider] ?? "", for: provider)
                    keyDrafts[provider] = nil
                }
                .disabled((keyDrafts[provider] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                if saved {
                    Button("Remove", role: .destructive) {
                        model.toolStore.removeKey(for: provider)
                    }
                }
            }
            Text(saved
                 ? "A key is saved in your Keychain. It is used only for searches, and never shown to the model, saved in chats or written to logs."
                 : "No key is saved. Searches with \(provider.displayName) will fail until one is added.")
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
