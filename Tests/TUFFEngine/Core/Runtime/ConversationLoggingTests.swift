import Testing
@testable import TUFFEngine

@Suite struct ConversationLoggingTests {
    @Test func acceptsCanonicalAndLegacyNames() {
        #expect(!conversationCacheLoggingEnabled(environment: [:]))
        #expect(conversationCacheLoggingEnabled(environment: ["TUFF_LOG_CACHE": "1"]))
        #expect(conversationCacheLoggingEnabled(environment: ["TFF_LOG_CACHE": "1"]))
        #expect(conversationCacheLoggingEnabled(environment: ["TUFF_LOG_CACHE": "", "TFF_LOG_CACHE": "1"]))
        #expect(!conversationCacheLoggingEnabled(environment: ["TUFF_OTHER": "1"]))
    }
}
