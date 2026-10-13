import AppKit
import SwiftUI
import Testing
@testable import TUFFMac
import TUFFMacPresentation

@Suite(.serialized) @MainActor struct MessageTextLayoutTests {
    @Test func completedMarkdownMeasuresBeforeTheFirstFrameAndRewraps() throws {
        let view = MessageTextView.make()
        let text = String(repeating: "A finished answer with **emphasis** and enough words to wrap.\n\n", count: 30)
        view.textStorage?.setAttributedString(ResponseMarkdownRenderer().render(text).attributedString)
        let wide = try #require(view.fittingHeight(width: 600))
        let narrow = try #require(view.fittingHeight(width: 240))
        let restored = try #require(view.fittingHeight(width: 600))
        #expect(wide > 300)
        #expect(narrow > wide)
        #expect(restored == wide)
        #expect(view.string.contains("A finished answer"))
        #expect(view.fittingHeight(width: 0) == nil)
        #expect(view.fittingHeight(width: .infinity) == nil)
    }

    @Test func finalizedStreamingTextHasAFullHeightImmediately() throws {
        let view = MessageTextView.make()
        let storage = try #require(view.textStorage)
        let controller = StreamingResponseDocumentController()
        let response = String(repeating: "This is a streamed paragraph with several words.\n\n", count: 25)
        _ = controller.synchronize(storage: storage, response: response,
                                   isTerminal: false, showsPrefillPlaceholder: false)
        let streamed = try #require(view.fittingHeight(width: 400))
        _ = controller.synchronize(storage: storage, response: response,
                                   isTerminal: true, showsPrefillPlaceholder: false)
        let completed = try #require(view.fittingHeight(width: 400))
        #expect(streamed > 300)
        #expect(completed > 300)
        #expect(view.string.contains("This is a streamed paragraph"))
    }

    @Test func swiftUILayoutGetsTheCompletedHeightWithoutDeferredState() {
        let renderer = ResponseMarkdownRenderer()
        let short = NSHostingView(rootView: AttributedTextView(
            attributed: renderer.render("Hello.").attributedString).frame(width: 400))
        let long = NSHostingView(rootView: AttributedTextView(
            attributed: renderer.render(String(repeating: "A paragraph with enough words to occupy the conversation.\n\n", count: 30)).attributedString).frame(width: 400))
        #expect(short.fittingSize.height > 1)
        #expect(long.fittingSize.height > short.fittingSize.height + 300)
    }
}
