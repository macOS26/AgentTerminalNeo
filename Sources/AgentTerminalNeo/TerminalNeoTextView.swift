import AppKit
import Combine
import SwiftUI

/// NSViewRepresentable that renders markdown with retro neo green terminal styling.
/// Uses Combine to push text updates directly to NSTextView, bypassing SwiftUI's layout cycle.
public struct TerminalNeoTextView: NSViewRepresentable {
    public let text: String
    public var onContentHeight: ((CGFloat) -> Void)?

    public init(text: String, onContentHeight: ((CGFloat) -> Void)? = nil) {
        self.text = text
        self.onContentHeight = onContentHeight
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public final class Coordinator: @unchecked Sendable {
        let textSubject = PassthroughSubject<String, Never>()
        var cancellable: AnyCancellable?
        var renderGeneration = 0
        weak var textView: NSTextView?
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.isRichText = true
        textView.allowsUndo = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        context.coordinator.textView = textView

        // Subscribe to text updates via Combine — debounce to 100ms to batch streaming chunks
        let coord = context.coordinator
        coord.cancellable = coord.textSubject
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.global(qos: .userInitiated))
            .sink { text in
                coord.renderGeneration += 1
                let gen = coord.renderGeneration
                let attributed = TerminalNeoRenderer.render(text)
                DispatchQueue.main.async { [weak coord] in
                    guard let coord, coord.renderGeneration == gen, let tv = coord.textView else { return }
                    tv.textStorage?.setAttributedString(attributed)
                }
            }

        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Push text through Combine — no work done here
        context.coordinator.textSubject.send(text)
    }
}
