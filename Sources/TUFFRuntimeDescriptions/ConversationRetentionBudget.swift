import Foundation

public enum ConversationRetentionBudget {
    public static func budget(safeBudgetBytes: UInt64,
                              workingSetBytes: UInt64,
                              capBytes: UInt64 = defaultCapBytes,
                              environment: [String: String] = ProcessInfo.processInfo.environment)
        -> Int {
        guard safeBudgetBytes > workingSetBytes else { return 0 }
        var budget = min(capBytes, safeBudgetBytes - workingSetBytes)
        if let override = environment["TUFF_CONVERSATION_CACHE_MB"],
           let megabytes = UInt64(override.trimmingCharacters(in: .whitespaces)) {
            let requested = megabytes.multipliedReportingOverflow(by: 1 << 20)
            if !requested.overflow { budget = min(budget, requested.partialValue) }
        }
        return Int(clamping: budget)
    }

    /// 1 GiB. Three or four ordinary Gemma 26B conversations at a few
    /// thousand tokens, or several Flash Next ones, whose recurrent state is
    /// 119 MB at any length.
    public static let defaultCapBytes: UInt64 = 1 << 30
}
