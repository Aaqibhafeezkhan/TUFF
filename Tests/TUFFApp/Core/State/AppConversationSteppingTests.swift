import Foundation
import Testing
@testable import TUFFAppCore

struct AppConversationSteppingTests {
    private let chats = (0..<3).map { AppConversationRecord(title: "\($0)", modelID: "m") }

    @Test func stepsAndWrapsInSidebarOrder() {
        let step = { (from: Int, by: Int) in
            AppConversationStepping.target(in: chats, from: chats[from].id, offset: by)?.title
        }
        #expect(step(0, 1) == "1")
        #expect(step(2, 1) == "0")
        #expect(step(0, -1) == "2")
        #expect(step(1, -1) == "0")
    }

    @Test func withNoOpenChatForwardOpensTheFirstAndBackTheLast() {
        #expect(AppConversationStepping.target(in: chats, from: nil, offset: 1)?.title == "0")
        #expect(AppConversationStepping.target(in: chats, from: UUID(), offset: -1)?.title == "2")
        #expect(AppConversationStepping.target(in: [], from: nil, offset: 1) == nil)
    }
}
