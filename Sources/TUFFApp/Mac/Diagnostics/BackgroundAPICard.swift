import AppKit
import SwiftUI
import TUFFAppCore
import TUFFAppServer
import TUFFModelCatalog
import TUFFMacPresentation

struct BackgroundAPICard: View {
    let model: AppModel
    @Bindable var controller: AppBackgroundAPIController
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var portText = ""
    @FocusState private var portIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Background API", isOn: Binding(
                get: { controller.settings.enabled },
                set: { value in controller.update { $0.enabled = value } }))
                .appFont(.headline)
                .disabled(!controller.isAvailable || controller.isChanging || model.serverStore.isBusy)
            if controller.isAvailable {
                Text("Serve installed models while TUFF is closed. Each request selects a model; one model runs at a time.")
                    .appFont(.callout).foregroundStyle(.secondary)
                Picker("Default model", selection: Binding(
                    get: { controller.defaultModelID },
                    set: { value in controller.update { $0.defaultModel = value } })) {
                    ForEach(model.installs.filter { $0.isInstalled }) { install in
                        Text(install.descriptor.displayName).tag(install.descriptor.apiModelID)
                    }
                }
                Picker("Unload model", selection: Binding(
                    get: { controller.settings.unloadDelay },
                    set: { value in controller.update { $0.unloadDelay = value } })) {
                    ForEach(TUFFModelUnloadDelay.choices, id: \.self) { delay in
                        Text(delay.label).tag(delay)
                    }
                }
                HStack {
                    TextField("Port", text: $portText)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 150)
                        .focused($portIsFocused)
                        .onSubmit {
                            controller.updatePort(portText)
                            portIsFocused = false
                        }
                        .onChange(of: portIsFocused) { _, focused in
                            if !focused { controller.updatePort(portText) }
                        }
                        .onChange(of: controller.settings.port) { _, port in
                            if !portIsFocused { portText = String(port) }
                        }
                    Spacer()
                    Button("Copy URL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(controller.endpoint, forType: .string)
                    }
                }
                Text(controller.endpoint).appFont(.callout.monospaced()).textSelection(.enabled)
                if let status = controller.status {
                    Text("Listening · \(status.activeRequests) active · \(status.queuedRequests) queued")
                    Text(status.transition ?? status.residentModel.map { "Loaded: \($0)" } ?? "No model loaded")
                        .appFont(.caption).foregroundStyle(.secondary)
                } else {
                    Text(controller.settings.enabled ? "Waiting for the listener" : "Off")
                        .appFont(.caption).foregroundStyle(.secondary)
                }
                if controller.requiresApproval {
                    Button("Open Login Items", action: controller.openLoginItems)
                }
                if let message = controller.message {
                    Text(message).appFont(.caption).foregroundStyle(.secondary)
                }
                if model.serverStore.isBusy {
                    Text("Stop the local server before enabling the Background API.")
                        .appFont(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Available in the packaged TUFF app. Clone builds can use tuff serve --all-models.")
                    .appFont(.callout).foregroundStyle(.secondary)
            }
        }
        .disabled(controller.isChanging)
        .padding(18)
        .background(TUFFMacTheme.surfaceStyle(reduceTransparency: reduceTransparency),
                    in: RoundedRectangle(cornerRadius: 16))
        .task {
            portText = String(controller.settings.port)
            while !Task.isCancelled {
                await controller.refreshStatus()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}
