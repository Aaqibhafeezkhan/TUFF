import AppKit
import SwiftUI
import TUFFAppCore
import TUFFMacPresentation

/// Run TUFF's standard benchmark on installed models and share the result
/// in the Benchmarks discussions.
struct BenchmarksWorkspaceView: View {
    let model: AppModel
    @Bindable var controller: BenchmarkController
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                WorkspaceTitle(
                    title: "Benchmarks",
                    subtitle: "See how fast models run on this Mac, and share it with everyone else.")
                if controller.installed.isEmpty {
                    emptyCard
                } else {
                    setupCard
                    if controller.isRunning || !controller.states.isEmpty {
                        progressCard
                    }
                    if let error = controller.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .appFont(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let result = controller.result {
                        resultCard(result)
                    }
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { controller.refresh() }
    }

    // MARK: - Cards

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No models installed").appFont(.headline)
            Text("Install a model on the Models screen, then come back to benchmark it.")
                .appFont(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Models").appFont(.headline)
                Spacer()
                Button(allSelected ? "Select None" : "Select All") {
                    controller.selected = allSelected ? [] : Set(controller.installed.map(\.id))
                }
                .buttonStyle(.link)
                .disabled(controller.isRunning)
            }
            VStack(spacing: 0) {
                ForEach(Array(controller.installed.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider() }
                    modelRow(item)
                }
            }
            Divider()
            HStack(alignment: .center, spacing: 14) {
                Picker("Length", selection: $controller.mode) {
                    ForEach(AppBenchmarkMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(controller.isRunning)
                Text(controller.mode == .quick
                     ? "One trial of each test. Good for a first look."
                     : "Three trials of each test, for a median the leaderboard can trust.")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if controller.isRunning {
                    Button("Stop", role: .cancel) { controller.stop() }
                        .controlSize(.large)
                } else {
                    Button {
                        Task {
                            await controller.start { await releaseChatModel() }
                        }
                    } label: {
                        Label("Run Benchmark", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!controller.canStart || model.isRunning)
                }
            }
            Text("Models run one at a time with the settings chat uses. Chat's model is unloaded first. Keep other heavy apps closed, and avoid chatting while it runs; both change the numbers.")
                .appFont(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    private func modelRow(_ item: AppBenchmarkModel) -> some View {
        Toggle(isOn: Binding(
            get: { controller.selected.contains(item.id) },
            set: { isOn in
                if isOn { controller.selected.insert(item.id) } else { controller.selected.remove(item.id) }
            })) {
            HStack {
                Text(item.descriptor.displayName).appFont(.body)
                Spacer()
                if item.descriptor.source.installedBytes > 50_000_000_000 {
                    Text("Slow on most Macs")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(Self.gigabytes(item.descriptor.source.installedBytes))
                    .appFont(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .trailing)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(controller.isRunning)
        .padding(.vertical, 7)
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(controller.isRunning ? "Running" : "Last run").appFont(.headline)
                Spacer()
                if controller.isRunning {
                    Text("\(Int(controller.progress * 100))%")
                        .appFont(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if controller.isRunning {
                ProgressView(value: controller.progress)
            }
            ForEach(controller.installed.filter { controller.states[$0.id] != nil }) { item in
                HStack(spacing: 10) {
                    stateIcon(controller.states[item.id])
                        .frame(width: 18)
                    Text(item.descriptor.displayName).appFont(.body)
                    Spacer()
                    Text(stateText(controller.states[item.id]))
                        .appFont(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    private func resultCard(_ result: AppBenchmarkResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Results").appFont(.headline)
                Text(result.machine.shortDescription)
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow {
                    header("Model")
                    header("Writes").gridColumnAlignment(.trailing)
                    header("Reads prompt").gridColumnAlignment(.trailing)
                    header("First token").gridColumnAlignment(.trailing)
                    header("Follow-up").gridColumnAlignment(.trailing)
                    header("Check").gridColumnAlignment(.center)
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(result.runs, id: \.model.id) { run in
                    GridRow {
                        Text(run.model.name)
                            .appFont(.body)
                            .frame(minWidth: 190, alignment: .leading)
                        if run.status == .completed {
                            value(AppBenchmarkShare.rate(run.summary?.decodeTokensPerSecond?.median))
                            value(AppBenchmarkShare.rate(run.summary?.prefillTokensPerSecond?.median))
                            value(run.summary?.longTimeToFirstTokenSeconds.map { AppBenchmarkShare.seconds($0.median) } ?? "n/a")
                            value(run.summary?.followUpTimeToFirstTokenSeconds.map(AppBenchmarkShare.seconds) ?? "n/a")
                            checkSymbol(run.check)
                        } else {
                            Text(run.error ?? run.status.rawValue.capitalized)
                                .appFont(.callout)
                                .foregroundStyle(.secondary)
                                .gridCellColumns(5)
                        }
                    }
                }
            }
            Text("Writes is decode speed. Reads prompt is how fast a 1,500-token prompt is processed. First token is the wait for that prompt; Follow-up is the same wait when TUFF reuses the earlier conversation.")
                .appFont(.caption)
                .foregroundStyle(.secondary)
            Divider()
            HStack(spacing: 10) {
                Button {
                    controller.share()
                } label: {
                    Label("Share on GitHub", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(result.completedRuns.isEmpty)
                Button("Show File") { controller.revealResult() }
                Button("Leaderboard") { NSWorkspace.shared.open(AppBenchmarkShare.leaderboardURL) }
                Spacer()
            }
            Text(controller.shareNote ?? "Sharing posts this table in TUFF's Benchmarks discussions from your GitHub account. It includes your chip, memory, macOS version and these timings, and nothing else.")
                .appFont(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Pieces

    private var allSelected: Bool {
        controller.selected.count == controller.installed.count
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .appFont(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func checkSymbol(_ check: AppBenchmarkResult.Check?) -> some View {
        switch check?.passed {
        case true?:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(TUFFMacTheme.accentColor)
                .help("Answered the check question correctly")
                .accessibilityLabel("Check passed")
        case false?:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .help("Answered the check question wrongly: \(check?.answer ?? "")")
                .accessibilityLabel("Check failed")
        case nil:
            Text("n/a").foregroundStyle(.secondary)
        }
    }

    private func value(_ text: String) -> some View {
        Text(text).appFont(.body.monospacedDigit())
    }

    @ViewBuilder
    private func stateIcon(_ state: BenchmarkController.ModelState?) -> some View {
        switch state {
        case .running?:
            ProgressView().controlSize(.small)
        case .finished(.completed)?:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(TUFFMacTheme.accentColor)
        case .finished(.failed)?:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .finished?:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        default:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }

    private func stateText(_ state: BenchmarkController.ModelState?) -> String {
        switch state {
        case .running(let step)?: step
        case .finished(let status)?: status.rawValue.capitalized
        default: "Waiting"
        }
    }

    private func releaseChatModel() async {
        guard model.canUnloadModel else { return }
        model.unloadModel()
        for _ in 0..<100 where model.loadState != .notLoaded {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private var cardBackground: AnyShapeStyle {
        TUFFMacTheme.surfaceStyle(reduceTransparency: reduceTransparency)
    }

    static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1e9)
    }
}
