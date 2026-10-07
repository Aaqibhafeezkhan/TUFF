import AppKit
import SwiftUI

/// An `NSTextView` that has no scroll view of its own and reports the height it
/// needs instead.
///
/// The conversation is one scrollable surface. A message that carried its own
/// scroll view put a scroller inside a scroller — the wheel stopped at whichever
/// message the pointer happened to be over — so every message here sizes to its
/// content and lets the transcript do the scrolling.
final class MessageTextView: NSTextView {
    var onHeightChange: ((CGFloat) -> Void)?
    private var reportedHeight: CGFloat = -1
    private var measuredWidth: CGFloat = -1

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // A narrower window rewraps the text, and nothing else asks the view to
        // measure again: without this, resizing left every message at the
        // height its old width needed.
        guard abs(newSize.width - measuredWidth) > 0.5 else { return }
        measuredWidth = newSize.width
        reportHeight()
    }

    /// Measures and, when it changed, reports. The report is deferred because
    /// callers run inside SwiftUI's layout pass, where writing state directly is
    /// a "modifying state during view update" violation.
    func reportHeight() {
        guard let container = textContainer, let layoutManager else { return }
        layoutManager.ensureLayout(for: container)
        let measured = ceil(layoutManager.usedRect(for: container).height)
        guard measured > 0, abs(measured - reportedHeight) > 0.5 else { return }
        reportedHeight = measured
        let handler = onHeightChange
        DispatchQueue.main.async { handler?(measured) }
    }

    /// Applies the standard message text-view configuration.
    static func make() -> MessageTextView {
        let textView = MessageTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return textView
    }
}

/// A static, selectable attributed-text block that reports its own height.
///
/// Rendered responses carry math as `NSTextAttachment`, which SwiftUI's `Text`
/// cannot draw, so a completed message still needs a text view. This one holds
/// a single message: it lays out once and never streams, which is what lets the
/// transcript be a list of messages.
struct AttributedTextView: NSViewRepresentable {
    let attributed: NSAttributedString
    @Binding var height: CGFloat
    /// Handles a click on a link the renderer made clickable: only validated
    /// citations are. Nil leaves links inert.
    var onLink: ((URL) -> Void)?

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onLink: ((URL) -> Void)?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else {
                return true
            }
            onLink?(url)
            // Handled either way: nothing is passed on to open by default.
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MessageTextView {
        let textView = MessageTextView.make()
        textView.delegate = context.coordinator
        textView.onHeightChange = { measured in height = measured }
        return textView
    }

    func updateNSView(_ textView: MessageTextView, context: Context) {
        context.coordinator.onLink = onLink
        textView.onHeightChange = { measured in height = measured }
        if textView.textStorage?.isEqual(to: attributed) != true {
            textView.textStorage?.setAttributedString(attributed)
        }
        textView.reportHeight()
    }
}
