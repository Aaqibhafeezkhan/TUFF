import Foundation
import Darwin
import TUFFAppCore
import TUFFInferenceTypes
import TUFFModelCatalog
import TUFFModelMetadata

struct QualificationError: Error, CustomStringConvertible { let description: String }
setbuf(stdout, nil)

Task {
    do {
        guard CommandLine.arguments.count >= 2 else { throw QualificationError(description: "usage: TUFFQualification <model.gturbo> [tools|thinking|arithmetic|calibration]") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let scenario = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "arithmetic"
        let summary = try ModelWeightLayoutSummary.read(directory: directory)
        guard let catalog = TUFFModelCatalog.model(manifestModelID: summary.modelID)
            ?? TUFFModelCatalog.all.first(where: { $0.architecture.id.rawValue == summary.architectureID }) else { throw QualificationError(description: "unknown model") }
        let descriptor = AppModelInstallDescriptor(catalog: catalog)
        guard let plan = AppAutomaticMemoryPlanner.plan(for: descriptor, on: .current(), profile: .speed, layoutSummary: summary) else { throw QualificationError(description: "no safe Auto plan") }
        let context = min(plan.contextTokens, 2_048)
        let options = AppRuntimeOptions(expertCacheSlots: plan.expertCacheSlots,
            prefillEnabled: plan.expertCacheSlots >= 16, prefillChunkTokens: plan.prefillChunkTokens,
            modelVerification: .trustedInstall, denseResidencyPolicy: plan.denseResidencyPolicy,
            retainedConversationBytes: plan.retainedConversationBytes)
        let client = DecodeServiceInferenceClient()
        try await client.ensureLoaded(modelDirectory: directory, maxContextTokens: context,
            options: options, forceLogitsHead: false, onState: { state in print("load: \(state)") })
        if scenario == "calibration" {
            guard let baseline = AppAutomaticMemoryPlanner.plan(for: descriptor, on: .current(),
                profile: .speed, layoutSummary: summary, modelDirectory: directory,
                contextTokens: context, engineIdentity: client.currentEngineIdentity) else {
                throw QualificationError(description: "no calibration baseline")
            }
            let started = Date()
            let selected = try await AppAutoCalibrator.run(client: client, lifecycle: client,
                directory: directory, descriptor: descriptor, device: .current(), summary: summary,
                baseline: baseline, options: options, forceLogitsHead: false)
            print("calibration: \(Date().timeIntervalSince(started)) s, \(selected.candidateID ?? "unknown"), \(selected.evidence)")
            await client.unload()
            print("PASS \(catalog.id.rawValue) calibration")
            exit(0)
        }
        let function = InferenceFunctionDefinition(name: "add", description: "Add two integers.",
            parameters: .object(["type": .string("object"), "properties": .object([
                "a": .object(["type": .string("integer")]), "b": .object(["type": .string("integer")])]),
                "required": .array([.string("a"), .string("b")]), "additionalProperties": .bool(false)]))
        let request = AppGenerationRequest(modelDirectory: directory,
            prompt: scenario == "tools" ? "Use the add function to add 2 and 3. Do not calculate it yourself."
                : "What is 2 plus 2? Reply briefly.",
            maxNewTokens: scenario == "thinking" ? 256 : scenario == "tools" ? 96
                : (scenario == "arithmetic" && (catalog.family == .gptOss || catalog.reasoningControl == .alwaysOn) ? 128 : 32),
            maxContextTokens: context,
            reasoning: scenario == "thinking" || catalog.reasoningControl == .alwaysOn ? .on : .off,
            temperature: 0, seed: 7, runtimeOptions: options,
            tools: scenario == "tools" ? [function] : [])
        var text = "", thinking = "", calls: [AppToolCall] = [], complete = false
        for try await event in client.generate(request) {
            switch event {
            case .token(let token): text += token.textDelta
            case .thinking(let token): thinking += token.textDelta
            case .toolCalls(let value): calls += value
            case .finished(let diagnostics):
                complete = true
                print("decode: \(diagnostics.generatedTokens) tokens, \(diagnostics.tokensPerSecond) tok/s")
            case .failed(let error, _): throw error
            case .cancelled: throw CancellationError()
            default: break
            }
        }
        print("text: \(text)")
        print("thinking: \(thinking)")
        print("calls: \(calls)")
        guard complete else { throw QualificationError(description: "no completion") }
        if scenario == "tools" {
            guard let call = calls.first(where: { $0.name == "add" && $0.arguments == .object(["a": .integer(2), "b": .integer(3)]) }) else {
                throw QualificationError(description: "expected parsed add(2, 3) call")
            }
            var followup = request
            followup.currentRounds = [.init(thinking: thinking.isEmpty ? nil : thinking, content: text,
                calls: [call], results: [.init(callID: call.id, name: call.name, status: .succeeded,
                    modelText: "5", summary: "2 + 3 = 5")])]
            followup.maxNewTokens = 64
            var answer = "", finished = false, repeatedCalls = false
            for try await event in client.generate(followup) {
                switch event {
                case .token(let token): answer += token.textDelta
                case .finished: finished = true
                case .toolCalls(let calls): repeatedCalls = !calls.isEmpty
                case .failed(let error, _): throw error
                case .cancelled: throw CancellationError()
                default: break
                }
            }
            print("tool result answer: \(answer)")
            guard finished, answer.contains("5"), !repeatedCalls else {
                throw QualificationError(description: "tool result did not produce the expected final answer")
            }
        } else if scenario == "arithmetic" {
            guard text.contains("4") else { throw QualificationError(description: "incorrect arithmetic response") }
        } else {
            guard !thinking.isEmpty, text.contains("4") else {
                throw QualificationError(description: "reasoning did not produce the expected visible answer")
            }
        }
        await client.unload()
        print("PASS \(catalog.id.rawValue) \(scenario)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("qualification failed: \(error)\n".utf8))
        exit(1)
    }
}
dispatchMain()
