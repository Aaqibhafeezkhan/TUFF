import CryptoKit
import Foundation

/// How much of the suite to run.
public enum AppBenchmarkMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// One trial of each workload. A few minutes on most models.
    case quick
    /// Three trials of each timed workload, which gives a median and a spread.
    case standard

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .quick: "Quick"
        case .standard: "Standard"
        }
    }

    var timedTrials: Int {
        switch self {
        case .quick: 1
        case .standard: 3
        }
    }
}

/// One kind of request the suite makes.
public enum AppBenchmarkWorkload: String, Codable, Sendable, CaseIterable {
    /// A one-word factual answer, to catch a model that runs but is broken.
    case check
    /// A short prompt and a long answer. Measures decode speed.
    case short
    /// A ~1,500-token document. Measures prompt processing.
    case long
    /// A question about the long answer in the same conversation. Measures
    /// how much prompt reuse saves.
    case followUp = "follow-up"
}

/// One request in a run.
public struct AppBenchmarkStep: Equatable, Sendable {
    public let workload: AppBenchmarkWorkload
    /// 1-based, within its workload.
    public let trial: Int
    public let maxNewTokens: Int
}

/// The fixed, versioned workload. Every Mac runs exactly these prompts, so
/// results are comparable. Changing any prompt or limit changes
/// `workloadSHA256`, and must come with a new `version`.
public enum AppBenchmarkSuite {
    public static let name = "tuff-bench"
    public static let version = 1
    /// Fixed so that sampling models produce repeatable text on one Mac.
    public static let seed: UInt64 = 20_260_721

    public static let checkPrompt = "What is the capital of France? Answer with one word."
    public static let checkAnswer = "paris"

    public static let shortPrompt = """
        Explain how a refrigerator keeps food cold. Cover the compressor, the \
        condenser, the expansion valve and the evaporator, one paragraph each, \
        in plain language.
        """

    public static let longQuestion = "Summarize the report above in five short bullet points."

    public static let followUpPrompt = """
        Which of those points matters most for a team of three engineers, and \
        why? Answer in two sentences.
        """

    /// A made-up engineering report, about 1,100 words. Built from fixed text
    /// so it is identical everywhere and needs no file.
    public static let longDocument: String = {
        let subjects = [
            "the build pipeline", "the release checklist", "the crash reporter",
            "the model downloader", "the settings screen", "the local server",
            "the memory planner", "the update feed", "the test suite",
            "the documentation", "the chat archive", "the search index",
        ]
        let findings = [
            "took longer than planned because two steps depended on each other in ways nobody had written down",
            "worked well once the team agreed on a single owner and a short weekly review",
            "failed twice in the first month, both times because a default changed without a note in the changelog",
            "became much easier to maintain after the oldest code path was removed instead of patched again",
        ]
        let actions = [
            "Next quarter the team will measure it on more than one machine before changing anything.",
            "The team agreed to write the reason for every change next to the change itself.",
            "A small checklist now runs before each release, and it has already caught one mistake.",
            "Nobody wants another rewrite, so the plan is to keep the current design and fix the rough edges.",
        ]
        var paragraphs = ["Quarterly engineering report. This report covers twelve areas of work."]
        for (index, subject) in subjects.enumerated() {
            let finding = findings[index % findings.count]
            let action = actions[(index + 1) % actions.count]
            paragraphs.append(
                "Section \(index + 1). This quarter, work on \(subject) \(finding). "
                    + "The people closest to \(subject) said the biggest cost was waiting: "
                    + "waiting for a review, waiting for a slow machine, or waiting for an answer "
                    + "from someone who had moved to other work. Measured over twelve weeks, "
                    + "about a third of the time spent on \(subject) went into that waiting. \(action)")
        }
        paragraphs.append("End of report.")
        return paragraphs.joined(separator: "\n\n")
    }()

    /// The requests a model runs, in order. The follow-up comes straight
    /// after the last long trial, because it continues that conversation.
    public static func steps(for mode: AppBenchmarkMode) -> [AppBenchmarkStep] {
        let trials = mode.timedTrials
        var steps = [AppBenchmarkStep(workload: .check, trial: 1, maxNewTokens: checkMaxNewTokens)]
        steps += (1...trials).map {
            AppBenchmarkStep(workload: .short, trial: $0, maxNewTokens: shortMaxNewTokens)
        }
        steps += (1...trials).map {
            AppBenchmarkStep(workload: .long, trial: $0, maxNewTokens: longMaxNewTokens)
        }
        steps.append(AppBenchmarkStep(workload: .followUp, trial: 1, maxNewTokens: followUpMaxNewTokens))
        return steps
    }

    public static let checkMaxNewTokens = 96
    public static let shortMaxNewTokens = 128
    public static let longMaxNewTokens = 48
    public static let followUpMaxNewTokens = 48

    /// The user message for a step. Each timed trial starts with its own
    /// label so that prompt reuse cannot carry one trial's work into the next.
    public static func prompt(for step: AppBenchmarkStep) -> String {
        switch step.workload {
        case .check:
            checkPrompt
        case .short:
            "Benchmark trial \(step.trial).\n\n" + shortPrompt
        case .long:
            "Benchmark trial \(step.trial).\n\n" + longDocument + "\n\n" + longQuestion
        case .followUp:
            followUpPrompt
        }
    }

    /// Identifies the exact prompts and limits. The leaderboard only accepts
    /// hashes it knows.
    public static var workloadSHA256: String {
        var canonical = "\(name)/\(version)\n"
        for mode in AppBenchmarkMode.allCases {
            for step in steps(for: mode) {
                canonical += "\(mode.rawValue)|\(step.workload.rawValue)|\(step.trial)|"
                    + "\(step.maxNewTokens)|\(prompt(for: step))\n"
            }
        }
        canonical += "seed=\(seed)\n"
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
