import AppKit
import TUFFAppCore
import TUFFMacPresentation
import SwiftUI

/// The composer's Web and Files switches: small capsules beside the model
/// picker, tinted when on, so what the next message may use is visible
/// before it is sent.
struct ToolToggleControls: View {
    @Bindable var model: AppModel
    @State private var showingFolders = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.webSearchEnabled.toggle()
            } label: {
                pill(model.isWebSearchPaused ? "Web · Offline" : "Web", symbol: "globe", isOn: webOn)
            }
            .buttonStyle(.plain)
            .help(webHelp)
            .accessibilityLabel("Web search")
            .accessibilityValue(model.isWebSearchPaused ? "Paused while offline" : (webOn ? "On" : "Off"))

            Button {
                showingFolders.toggle()
            } label: {
                pill(filesLabel, symbol: "folder", isOn: filesOn)
            }
            .buttonStyle(.plain)
            .help(filesHelp)
            .accessibilityLabel("File search")
            .accessibilityValue(filesOn ? "On, \(model.toolStore.folders.count) folders" : "Off")
            .popover(isPresented: $showingFolders, arrowEdge: .bottom) {
                FolderAccessPanel(model: model)
                    .frame(width: 360)
                    .padding(14)
            }
        }
        .appFont(.callout)
        .disabled(!model.toolSupport.allowsTools || model.isRunning)
    }

    private var webOn: Bool { model.webSearchEnabled && !model.isWebSearchPaused && model.toolSupport.allowsTools }

    private var filesOn: Bool {
        model.fileSearchEnabled && model.toolSupport.allowsTools && !model.toolStore.folders.isEmpty
    }

    private var filesLabel: String {
        let count = model.toolStore.folders.count
        return filesOn && count > 0 ? "Files · \(count)" : "Files"
    }

    private var webHelp: String {
        if let note = unavailableNote { return note }
        if model.isWebSearchPaused { return "Web search is paused while offline. It will resume when your connection returns. Click to turn Web off." }
        return (webOn ? "Web search is on. " : "Web search is off. ")
            + model.searchProvider.privacyNote
            + (model.toolSupport.note.map { " " + $0 } ?? "")
    }

    private var filesHelp: String {
        if let note = unavailableNote { return note }
        return "Search folders you choose. Their contents stay on this Mac."
    }

    private var unavailableNote: String? {
        if case .unavailable(let reason) = model.toolSupport { return reason }
        return nil
    }

    private func pill(_ title: String, symbol: String, isOn: Bool) -> some View {
        Label(title, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(isOn ? AnyShapeStyle(TUFFMacTheme.accentColor) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background {
                Capsule()
                    .fill(isOn ? TUFFMacTheme.accentColor.opacity(0.14) : Color.primary.opacity(0.06))
                    .overlay {
                        Capsule().stroke(isOn ? TUFFMacTheme.accentColor.opacity(0.35)
                                         : Color.primary.opacity(0.08), lineWidth: 0.5)
                    }
            }
            .contentShape(Capsule())
            .fixedSize()
    }
}

/// The folders file search may read, their index state, and the controls to
/// add, remove or stop using them. Shared by the composer and Settings.
struct FolderAccessPanel: View {
    @Bindable var model: AppModel
    var showsToggle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsToggle {
                Toggle("Search these folders", isOn: $model.fileSearchEnabled)
                    .toggleStyle(.switch)
                    .disabled(model.toolStore.folders.isEmpty)
            }
            if model.toolStore.folders.isEmpty {
                Text("Choose folders for TUFF to search. Only the folders you add are read, and their contents stay on this Mac.")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.toolStore.folders) { folder in
                        folderRow(folder)
                    }
                }
            }
            HStack {
                Button("Add Folder…", action: addFolders)
                Spacer()
                if model.toolStore.isIndexing {
                    Button("Stop Indexing") { model.toolStore.stopIndexing() }
                } else if !model.toolStore.folders.isEmpty {
                    Button("Update Index") { model.toolStore.reindex() }
                }
            }
            if let error = model.toolStore.lastError {
                Text(error)
                    .appFont(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func folderRow(_ folder: AppSearchFolder) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.displayName)
                    .lineLimit(1)
                Text(status(folder))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .help((folder.path as NSString).abbreviatingWithTildeInPath)
            Spacer(minLength: 4)
            Button {
                model.toolStore.removeFolder(id: folder.id)
                if model.toolStore.folders.isEmpty { model.fileSearchEnabled = false }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.borderless)
            .help("Stop searching this folder and delete its index")
            .accessibilityLabel("Remove \(folder.displayName)")
        }
    }

    private func status(_ folder: AppSearchFolder) -> String {
        let indexing = model.toolStore.indexingFolderID == folder.id
        guard let status = model.toolStore.folderStatus[folder.id] else {
            return indexing ? "Indexing…" : "Not indexed yet"
        }
        if let error = status.lastError { return error }
        var parts: [String] = []
        if indexing, status.pendingFiles > 0 {
            parts.append("Indexing, \(status.pendingFiles) file\(status.pendingFiles == 1 ? "" : "s") left")
        }
        parts.append("\(status.indexedFiles) file\(status.indexedFiles == 1 ? "" : "s") indexed")
        if status.skippedFiles > 0 { parts.append("\(status.skippedFiles) skipped") }
        if status.reachedFileLimit { parts.append("file limit reached") }
        return parts.joined(separator: ", ")
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders for TUFF to search. Only these folders are read."
        guard panel.runModal() == .OK else { return }
        model.toolStore.addFolders(panel.urls)
        if !model.toolStore.folders.isEmpty { model.fileSearchEnabled = true }
    }
}
