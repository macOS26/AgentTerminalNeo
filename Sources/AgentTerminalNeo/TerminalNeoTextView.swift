import AppKit
import Combine
import SwiftUI

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
        var lastLength: Int = 0
        var onContentHeight: ((CGFloat) -> Void)?
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
        context.coordinator.onContentHeight = onContentHeight

        let coord = context.coordinator
        coord.cancellable = coord.textSubject
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak coord] text in
                guard let coord, let tv = coord.textView else { return }
                // Render on background, apply on main
                let textCopy = text
                DispatchQueue.global(qos: .userInitiated).async {
                    let attributed = TerminalNeoRenderer.render(textCopy)
                    DispatchQueue.main.async { [weak coord] in
                        guard let coord, let tv = coord.textView else { return }
                        tv.textStorage?.setAttributedString(attributed)
                        // Report content height for auto-sizing
                        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
                        let h = (tv.layoutManager?.usedRect(for: tv.textContainer!).height ?? 40) + tv.textContainerInset.height * 2
                        coord.onContentHeight?(h)
                    }
                }
            }

        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coord = context.coordinator
        let len = (text as NSString).length
        guard len != coord.lastLength else { return }
        coord.lastLength = len
        coord.textSubject.send(text)
    }
}
