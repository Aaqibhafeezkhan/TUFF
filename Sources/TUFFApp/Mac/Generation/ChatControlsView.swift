import TUFFEngine
import TUFFAppCore
import TUFFMacPresentation
import SwiftUI

/// The composer's model and thinking controls, as quiet icons. The model's
/// name is already in the message placeholder, so the bar itself stays small;
/// thinking opens its choices in place and folds back once one is picked.
struct ChatControlsView: View {
    @Bindable var model: AppModel
    @State private var showsReasoningChoices = false

    var body: some View {
        HStack(spacing: 6) {
            modelMenu
            reasoningControl
        }
        .appFont(.callout)
        .disabled(model.isRunning || model.loadState.isLoading)
        .animation(.smooth(duration: 0.18), value: showsReasoningChoices)
    }

    // Only what is on this Mac. Offering the rest of the catalogue here meant
    // picking one replaced the conversation with the downloader; the Models
    // screen is where downloads live.
    private var modelMenu: some View {
        Menu {
            ForEach(model.installedInstalls) { install in
                Button {
                    model.selectModel(install)
                } label: {
                    if install.id == model.selectedModelID {
                        Label(install.descriptor.shortName, systemImage: "checkmark")
                    } else {
                        Text(install.descriptor.shortName)
                    }
                }
            }
        } label: {
            ComposerIcon(systemImage: "shippingbox", isOn: false)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Model: \(model.selectedDescriptor.shortName)")
        .accessibilityLabel("Chat model")
        .accessibilityValue(model.selectedDescriptor.shortName)
    }

    @ViewBuilder
    private var reasoningControl: some View {
        switch model.selectedDescriptor.reasoningControl {
        case .toggle, .toggleWithPreservation:
            brain(isOn: model.reasoning == .on, help: "Thinking: \(model.reasoning == .on ? "on" : "off")")
            if showsReasoningChoices {
                choices([("Off", ChatReasoning.off), ("On", ChatReasoning.on)],
                        selection: $model.reasoning)
            }
        case .graded:
            brain(isOn: true, help: "Reasoning: \(model.reasoningEffort.rawValue)")
            if showsReasoningChoices {
                choices([("Low", GPTOSSReasoningEffort.low), ("Medium", .medium), ("High", .high)],
                        selection: $model.reasoningEffort)
            }
        case .alwaysOn:
            ComposerIcon(systemImage: "brain", isOn: true)
                .help("This model always thinks before answering")
                .accessibilityLabel("Thinking always on")
        case nil:
            EmptyView()
        }
    }

    private func brain(isOn: Bool, help: String) -> some View {
        Button {
            showsReasoningChoices.toggle()
        } label: {
            ComposerIcon(systemImage: "brain", isOn: isOn)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("Thinking")
        .accessibilityValue(help)
    }

    private func choices<Value: Hashable>(_ options: [(String, Value)],
                                          selection: Binding<Value>) -> some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { title, value in
                let isSelected = selection.wrappedValue == value
                Button {
                    selection.wrappedValue = value
                    showsReasoningChoices = false
                } label: {
                    Text(title)
                        .foregroundStyle(isSelected
                                         ? AnyShapeStyle(TUFFMacTheme.accentColor)
                                         : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background {
                            if isSelected {
                                Capsule().fill(TUFFMacTheme.accentColor.opacity(0.14))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(ComposerIcon.background(isOn: false))
        .fixedSize()
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }
}

/// A round icon control for the composer, tinted while its option is on.
struct ComposerIcon: View {
    let systemImage: String
    let isOn: Bool
    var badge: Color?

    var body: some View {
        Image(systemName: systemImage)
            .appFont(.body)
            .foregroundStyle(isOn ? AnyShapeStyle(TUFFMacTheme.accentColor) : AnyShapeStyle(.secondary))
            .frame(width: 28, height: 28)
            .background(Self.background(isOn: isOn))
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Circle().fill(badge).frame(width: 7, height: 7).offset(x: -2, y: 2)
                }
            }
            .contentShape(Circle())
    }

    static func background(isOn: Bool) -> some View {
        Capsule()
            .fill(isOn ? TUFFMacTheme.accentColor.opacity(0.14) : Color.primary.opacity(0.06))
            .overlay {
                Capsule().stroke(isOn ? TUFFMacTheme.accentColor.opacity(0.35)
                                 : Color.primary.opacity(0.08), lineWidth: 0.5)
            }
    }
}
