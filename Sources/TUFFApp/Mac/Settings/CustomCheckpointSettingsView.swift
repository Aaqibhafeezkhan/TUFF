import AppKit
import TUFFAppCore
import TUFFModelCatalog
import SwiftUI

struct CustomCheckpointSettingsView: View {
    @Bindable var model: AppModel
    @State private var name = ""
    @State private var architecture = TUFFModelCatalog.default.id
    @State private var path = ""

    var body: some View {
        Section("Custom checkpoints") {
            DisclosureGroup("Add a custom checkpoint") {
                TextField("Name", text: $name)
                Picker("Supported architecture", selection: $architecture) {
                    ForEach(TUFFModelCatalog.all) { entry in
                        Text(entry.shortName).tag(entry.id)
                    }
                }
                HStack {
                    Text(path.isEmpty ? "Complete .gturbo folder" : URL(fileURLWithPath: path).lastPathComponent)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { chooseCheckpoint() }
                }
                Button(model.isImportingCustomCheckpoint ? "Verifying…" : "Verify and add") {
                    Task {
                        await model.importCustomCheckpoint(directory: URL(fileURLWithPath: path),
                            name: name, templateID: architecture)
                        if model.customCheckpointImportError == nil { name = ""; path = "" }
                    }
                }
                .disabled(path.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || model.isImportingCustomCheckpoint || model.isRunning || model.loadState.isLoading)
                Text("Text only. Requires a verified TUFF pack with matching architecture, tokenizer and quantization. The selected engine is reused. Raw weights need repacking first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            forEachCheckpoint
            if let error = model.customCheckpointImportError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    private var forEachCheckpoint: some View {
        ForEach(model.customCheckpointInstalls) { checkpoint in
            HStack {
                Text(checkpoint.descriptor.displayName)
                Spacer()
                Button("Remove entry") { model.removeCustomCheckpoint(checkpoint) }
                    .disabled(model.isImportingCustomCheckpoint)
            }
        }
    }

    private func chooseCheckpoint() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Choose checkpoint"
        panel.message = ""
        if panel.runModal() == .OK, let selected = panel.url {
            path = selected.path
            if name.isEmpty { name = selected.deletingPathExtension().lastPathComponent }
        }
    }
}
