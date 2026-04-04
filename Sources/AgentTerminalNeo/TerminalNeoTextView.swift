import AppKit
import SwiftUI

/// CRT scanline overlay — NSView that draws horizontal lines and passes clicks through
private class ScanlineOverlayView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.06).cgColor)
        var y: CGFloat = 0
        while y < bounds.height {
            ctx.fill(CGRect(x: 0, y: y, width: bounds.width, height: 2))
            y += 4
        }
    }
}

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
        /// Used by updateNSView to dedup
        var updateLastLength: Int = 0
        var onContentHeight: ((CGFloat) -> Void)?
        weak var textView: NSTextView?
        /// Terminal font for inline appends
        let termFont = NSFont.monospacedSystemFont(ofSize: 16.5, weight: .regular)
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

        // CRT scanline overlay — pinned above all content via zPosition
        let scanline = ScanlineOverlayView()
        scanline.wantsLayer = true
        scanline.layer?.zPosition = 999
        scanline.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(scanline)
        NSLayoutConstraint.activate([
            scanline.topAnchor.constraint(equalTo: scrollView.topAnchor),
            scanline.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            scanline.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            scanline.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
        ])

        context.coordinator.textView = textView
        context.coordinator.onContentHeight = onContentHeight
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coord = context.coordinator
        coord.onContentHeight = onContentHeight

        let len = (text as NSString).length
        guard len != coord.updateLastLength else { return }
        let prevLen = coord.updateLastLength
        coord.updateLastLength = len

        guard let tv = coord.textView, let storage = tv.textStorage else { return }

        // Incremental append — text grew, append new chars directly
        if len > prevLen && prevLen > 0 {
            let newPart = (text as NSString).substring(from: prevLen)
            let isDark = tv.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let color: NSColor = isDark
                ? NSColor(red: 0.2, green: 0.9, blue: 0.3, alpha: 1)
                : NSColor(red: 0.05, green: 0.35, blue: 0.1, alpha: 1)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: coord.termFont,
                .foregroundColor: color
            ]
            storage.beginEditing()
            storage.append(NSAttributedString(string: newPart, attributes: attrs))
            storage.endEditing()
            tv.scrollToEndOfDocument(nil)
        } else {
            // Non-incremental change (reset, tab switch) — full re-render
            let textCopy = text
            let attributed = TerminalNeoRenderer.render(textCopy)
            storage.setAttributedString(attributed)
        }

        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        let h = (tv.layoutManager?.usedRect(for: tv.textContainer!).height ?? 40) + tv.textContainerInset.height * 2
        coord.onContentHeight?(h)
    }
}
