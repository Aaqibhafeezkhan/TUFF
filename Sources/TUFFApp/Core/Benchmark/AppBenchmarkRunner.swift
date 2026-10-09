import Foundation
import TUFFEngine
import TUFFModelCatalog

/// An installed model the benchmark can run.
public struct AppBenchmarkModel: Equatable, Sendable, Identifiable {
    public let descriptor: TUFFModelDescriptor
    public let directory: URL

    public var id: String { descriptor.id.rawValue }

    public init(descriptor: TUFFModelDescriptor, directory: URL) {
        self.descriptor = descriptor
        self.directory = directory
    }

    /// Every catalog model with a complete install, in catalog order.
    public static func installed() -> [AppBenchmarkModel] {
        installed { AppModelLocation.defaultURL(descriptor: $0) }
    }

    static func installed(locate: (AppModelInstallDescriptor) -> URL) -> [AppBenchmarkModel] {
        TUFFModelCatalog.all.compactMap { descriptor in
            let install = AppModelInstallDescriptor(catalog: descriptor)
            let directory = locate(install)
            guard AppModelInstallationProbe.status(at: directory, descriptor: install) == .complete
            else { return nil }
            return AppBenchmarkModel(descriptor: descriptor, directory: directory)
        }
    }
}

/// What the runner is doing, for progress displays and the CLI's
/// `--progress-json` stream.
public struct AppBenchmarkProgress: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case modelStarted = "model-started"
        case loaded
        case stepStarted = "step-started"
        case stepFinished = "step-finished"
        case modelFinished = "model-finished"
    }

    public var kind: Kind
    public var modelIndex: Int
    public var modelCount: Int
    public var modelID: String
    public var modelName: String
    public var stepIndex: Int?
    public var stepCount: Int?
    public var workload: AppBenchmarkWorkload?
    public var trial: Int?
    public var status: AppBenchmarkResult.Status?
    public var message: String?
}

/// Runs the suite through the same inference client chat uses, one model at
/// a time. A model that fails is recorded and the next one starts.
public final class AppBenchmarkRunner: @unchecked Sendable {
    private let client: any AppModelLifecycleClient
    private let device: TUFFDeviceCapabilities
    private let machine: AppBenchmarkMachine
    private let appBuild: String
    private let now: @Sendable () -> Date
    private let clock = ContinuousClock()

    public init(client: any AppModelLifecycleClient,
                device: TUFFDeviceCapabilities = .current(),
                machine: AppBenchmarkMachine = .current(),
                appBuild: String = AppBenchmarkRunner.currentBuild(),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.client = client
        self.device = device
        self.machine = machine
        self.appBuild = appBuild
        self.now = now
    }

    /// "release" inside a packaged app, "source" otherwise.
    public static func currentBuild() -> String {
        Bundle.main.bundleURL.pathExtension == "app" ? "release" : "source"
    }

    public func run(models: [AppBenchmarkModel],
                    mode: AppBenchmarkMode,
                    progress: @escaping @Sendable (AppBenchmarkProgress) -> Void = { _ in }
    ) async -> AppBenchmarkResult {
        let started = now()
        var runs: [AppBenchmarkResult.ModelRun] = []
        for (index, model) in models.enumerated() {
            var base = AppBenchmarkProgress(
                kind: .modelStarted, modelIndex: index, modelCount: models.count,
                modelID: model.id, modelName: model.descriptor.displayName)
            if Task.isCancelled {
                runs.append(Self.emptyRun(model, status: .cancelled, error: nil))
                continue
            }
            progress(base)
            let run = await runModel(model, mode: mode) { step, index, count, finished in
                var event = base
                event.kind = finished ? .stepFinished : .stepStarted
                event.stepIndex = index
                event.stepCount = count
                event.workload = step.workload
                event.trial = step.trial
                progress(event)
            } loaded: {
                var event = base
                event.kind = .loaded
                progress(event)
            }
            runs.append(run)
            base.kind = .modelFinished
            base.status = run.status
            base.message = run.error
            progress(base)
        }
        return AppBenchmarkResult(
            id: UUID().uuidString.lowercased(),
            suite: .current(mode),
            app: .init(version: TUFFVersion.current, build: appBuild),
            machine: machine,
            startedAt: started,
            finishedAt: now(),
            runs: runs)
    }

    // MARK: - One model

    private func runModel(
        _ model: AppBenchmarkModel,
        mode: AppBenchmarkMode,
        stepProgress: (AppBenchmarkStep, Int, Int, Bool) -> Void,
        loaded: () -> Void
    ) async -> AppBenchmarkResult.ModelRun {
        let plan = Self.plan(for: model.descriptor, on: device)
        var run = Self.emptyRun(model, status: .completed, error: nil)
        run.settings = plan.settings

        let loadStarted = clock.now
        do {
            try await client.ensureLoaded(
                modelDirectory: model.directory,
                maxContextTokens: plan.settings.contextTokens,
                options: plan.options,
                forceLogitsHead: plan.settings.temperature != 0) { _ in }
            run.loadSeconds = seconds(since: loadStarted)
        } catch {
            await client.unload()
            run.status = Task.isCancelled ? .cancelled : .failed
            run.error = Task.isCancelled ? nil : "Could not load: \(error)"
            return run
        }
        loaded()

        let steps = AppBenchmarkSuite.steps(for: mode)
        var lastLong: (prompt: String, answer: String)?
        stepLoop: for (index, step) in steps.enumerated() {
            if Task.isCancelled {
                run.status = .cancelled
                break
            }
            // MiniMax always reasons, so a 96-token check is spent thinking
            // and would only measure that. Recorded as not run.
            if step.workload == .check, model.descriptor.reasoningControl == .alwaysOn {
                run.check = .init(passed: nil, answer: "")
                continue
            }
            stepProgress(step, index, steps.count, false)
            let prompt = AppBenchmarkSuite.prompt(for: step)
            var history: [AppChatTurn] = []
            if step.workload == .followUp {
                guard let lastLong else { continue }
                history = [AppChatTurn(prompt: lastLong.prompt, response: lastLong.answer)]
            }
            let request = plan.request(directory: model.directory, prompt: prompt,
                                       history: history, maxNewTokens: step.maxNewTokens,
                                       conversationKey: "benchmark-\(step.workload.rawValue)-\(step.trial)")
            do {
                let outcome = try await generate(request)
                run.trials.append(Self.trial(step, outcome.diagnostics))
                switch step.workload {
                case .check:
                    let answer = outcome.answer.trimmingCharacters(in: .whitespacesAndNewlines)
                    run.check = .init(
                        passed: answer.isEmpty ? nil
                            : answer.lowercased().contains(AppBenchmarkSuite.checkAnswer),
                        answer: String(answer.prefix(80)))
                case .long:
                    lastLong = (prompt, outcome.answer)
                default:
                    break
                }
            } catch is CancellationError {
                run.status = .cancelled
                break stepLoop
            } catch {
                run.status = Task.isCancelled ? .cancelled : .failed
                run.error = Task.isCancelled
                    ? nil : "\(step.workload.rawValue) trial \(step.trial): \(error)"
                break stepLoop
            }
            stepProgress(step, index, steps.count, true)
        }
        await client.unload()
        if run.status == .completed || !run.trials.isEmpty {
            run.summary = AppBenchmarkResult.ModelRun.summarize(run.trials)
        }
        return run
    }

    private struct Outcome {
        var answer: String
        var diagnostics: AppDiagnostics
    }

    private func generate(_ request: AppGenerationRequest) async throws -> Outcome {
        try await withTaskCancellationHandler {
            var answer = ""
            for try await event in client.generate(request) {
                switch event {
                case .token(let token):
                    answer += token.textDelta
                case .finished(let diagnostics):
                    return Outcome(answer: answer, diagnostics: diagnostics)
                case .cancelled:
                    throw CancellationError()
                case .failed(let error, _):
                    throw error
                default:
                    break
                }
            }
            throw AppInferenceError.invalidRequest("the generation ended without a result")
        } onCancel: { [client] in
            client.cancel()
        }
    }

    private func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: clock.now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    static func trial(_ step: AppBenchmarkStep, _ diagnostics: AppDiagnostics)
        -> AppBenchmarkResult.Trial {
        // Dense models never look up an expert; leave the counts out rather
        // than report a misleading zero.
        let experts = diagnostics.runner?.expertReads.flatMap { $0.demandRequests > 0 ? $0 : nil }
        return AppBenchmarkResult.Trial(
            workload: step.workload,
            trial: step.trial,
            promptTokens: diagnostics.promptTokenCount ?? 0,
            cachedTokens: diagnostics.cachedPromptTokens ?? 0,
            prefillSeconds: diagnostics.prefillSeconds ?? 0,
            timeToFirstTokenSeconds: diagnostics.requestStartTimeToFirstTokenSeconds,
            generatedTokens: diagnostics.generatedTokens,
            decodeSeconds: diagnostics.decodeSeconds,
            stopReason: diagnostics.stopReason.rawValue,
            peakMemoryBytes: diagnostics.peakMemoryBytes,
            expertRequests: experts?.demandRequests,
            expertReads: experts?.demandReads)
    }

    static func emptyRun(_ model: AppBenchmarkModel,
                         status: AppBenchmarkResult.Status,
                         error: String?) -> AppBenchmarkResult.ModelRun {
        let descriptor = model.descriptor
        return AppBenchmarkResult.ModelRun(
            model: .init(id: descriptor.id.rawValue,
                         name: descriptor.displayName,
                         revision: descriptor.source.revision,
                         weights: descriptor.architecture.weightLayout.rawValue,
                         installedBytes: descriptor.source.installedBytes),
            settings: nil, status: status, error: error,
            loadSeconds: nil, check: nil, trials: [], summary: nil)
    }

    // MARK: - Settings

    /// The settings a fresh install of TUFF uses for this model on this Mac:
    /// the catalog defaults resolved by Auto. Sampling uses the model's own
    /// defaults with a fixed seed, as chat does.
    struct Plan {
        var settings: AppBenchmarkResult.Settings
        var options: AppRuntimeOptions
        var reasoning: ChatReasoning
        var reasoningEffort: GPTOSSReasoningEffort?

        func request(directory: URL, prompt: String, history: [AppChatTurn],
                     maxNewTokens: Int, conversationKey: String) -> AppGenerationRequest {
            AppGenerationRequest(
                modelDirectory: directory,
                prompt: prompt,
                history: history,
                maxNewTokens: maxNewTokens,
                maxContextTokens: settings.contextTokens,
                reasoning: reasoning,
                reasoningEffort: reasoningEffort,
                temperature: Float(settings.temperature),
                topK: settings.topK,
                topP: settings.topP.map(Float.init),
                seed: AppBenchmarkSuite.seed,
                runtimeOptions: options,
                conversationKey: conversationKey)
        }
    }

    static func plan(for descriptor: TUFFModelDescriptor,
                     on device: TUFFDeviceCapabilities) -> Plan {
        let install = AppModelInstallDescriptor(catalog: descriptor)
        let profile = AppAutomaticMemoryPlanner.applying(
            AppModelSettingsProfile.defaults(for: descriptor.id.rawValue),
            for: install, on: device)
        let chunk = descriptor.recommendedPrefillChunkTokens(on: device)
        let options = AppRuntimeOptions(
            expertCacheSlots: profile.expertCacheSlots,
            prefillEnabled: profile.prefillEnabled,
            prefillChunkTokens: chunk,
            rdadvisePolicy: profile.rdadvisePolicy,
            visionResidencyPolicy: .onDemand)
        // Thinking off wherever the model allows it, so every model spends
        // its tokens on the answer. GPT-OSS uses its lowest effort.
        let reasoning: ChatReasoning = descriptor.reasoningControl == .alwaysOn ? .on : .off
        let effort: GPTOSSReasoningEffort? = descriptor.reasoningControl == .graded ? .low : nil
        let reasoningLabel = effort.map { "effort-\($0.rawValue)" } ?? reasoning.rawValue
        return Plan(
            settings: .init(
                contextTokens: profile.contextTokens,
                expertCacheSlots: profile.expertCacheSlots,
                prefillChunkTokens: chunk,
                batchedPrefill: profile.prefillEnabled,
                reasoning: reasoningLabel,
                temperature: profile.temperature,
                topK: profile.topKEnabled ? profile.topK : nil,
                topP: profile.topPEnabled ? profile.topP : nil),
            options: options,
            reasoning: reasoning,
            reasoningEffort: effort)
    }
}
