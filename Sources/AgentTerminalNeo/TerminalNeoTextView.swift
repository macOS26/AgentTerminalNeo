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
        var updateLastLength: Int = 0
        var onContentHeight: ((CGFloat) -> Void)?
        weak var textView: NSTextView?
        let termFont = NSFont.monospacedSystemFont(ofSize: 16.5, weight: .regular)
        /// When true, next time text stops growing we do a full render for tables
        var needsTableRender: Bool = false
        var lastGrowTime: Date = Date()
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

        // Strip cursor char to get content-only text for change detection
        let contentText = text.hasSuffix("█") ? String(text.dropLast()) : (text.hasSuffix(" ") ? String(text.dropLast()) : text)
        let contentLen = contentText.count

        guard let tv = coord.textView, let storage = tv.textStorage else { return }

        // Only re-render when content changes (not cursor blink)
        if contentLen != coord.updateLastLength {
            if contentLen < coord.updateLastLength {
                // Text shrank (reset/tab switch) — full re-render with table support
                storage.setAttributedString(TerminalNeoRenderer.render(text))
                coord.needsTableRender = true
            } else if contentLen > coord.updateLastLength && coord.updateLastLength > 0 {
                // Check if text has a table
                let hasTable = contentText.contains("|\n") && contentText.contains("---")
                if hasTable { coord.needsTableRender = true }

                if coord.needsTableRender {
                    // Re-render with smooth scroll — no jump
                    storage.setAttributedString(TerminalNeoRenderer.render(text))
                    tv.layoutManager?.ensureLayout(for: tv.textContainer!)
                    // Scroll to bottom smoothly via clip view
                    if let scrollView = tv.enclosingScrollView {
                        let contentHeight = tv.layoutManager?.usedRect(for: tv.textContainer!).height ?? 0
                        let visibleHeight = scrollView.contentView.bounds.height
                        let bottomY = max(0, contentHeight - visibleHeight)
                        scrollView.contentView.scroll(to: NSPoint(x: 0, y: bottomY))
                        scrollView.reflectScrolledClipView(scrollView.contentView)
                    }
                } else {
                    // No table — fast incremental append
                    let prevAttrLen = storage.length
                    if prevAttrLen > 0 {
                        let lastChar = storage.string.suffix(1)
                        if lastChar == "█" || lastChar == " " {
                            storage.deleteCharacters(in: NSRange(location: prevAttrLen - 1, length: 1))
                        }
                    }
                    let startIdx = max(0, storage.length)
                    if startIdx < text.count {
                        let newPart = String(text[text.index(text.startIndex, offsetBy: startIdx)...])
                        let isDark = tv.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        let color: NSColor = isDark
                            ? NSColor(red: 0.2, green: 0.9, blue: 0.3, alpha: 1)
                            : NSColor(red: 0.05, green: 0.35, blue: 0.1, alpha: 1)
                        storage.beginEditing()
                        storage.append(NSAttributedString(string: newPart, attributes: [
                            .font: coord.termFont, .foregroundColor: color
                        ]))
                        storage.endEditing()
                    }
                }
            } else {
                storage.setAttributedString(TerminalNeoRenderer.render(text))
            }
            coord.updateLastLength = contentLen
            coord.lastGrowTime = Date()
            // Table mode: on while last non-empty line starts with |, off when text moves past table
            let lastNonEmpty = contentText.components(separatedBy: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
            if lastNonEmpty.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                coord.needsTableRender = true
            } else if coord.needsTableRender && !lastNonEmpty.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                // Table ended — final re-render, append \n to force scroll past table, scroll to end
                let rendered = TerminalNeoRenderer.render(text)
                let withNewline = NSMutableAttributedString(attributedString: rendered)
                withNewline.append(NSAttributedString(string: "\n"))
                storage.setAttributedString(withNewline)
                coord.needsTableRender = false
                tv.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
            }
            // Smooth scroll to bottom for all content
            if let scrollView = tv.enclosingScrollView {
                let contentHeight = tv.layoutManager?.usedRect(for: tv.textContainer!).height ?? 0
                let visibleHeight = scrollView.contentView.bounds.height
                let bottomY = max(0, contentHeight - visibleHeight)
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: bottomY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        } else {
            // Content unchanged — cursor blink handled by SwiftUI side
            // Just update the last char to match what SwiftUI sent
            let attrLen = storage.length
            if attrLen > 0 && text.count > 0 {
                let expected = String(text.suffix(1))
                let actual = String(storage.string.suffix(1))
                if expected != actual {
                    let isDark = tv.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    let color: NSColor = isDark
                        ? NSColor(red: 0.2, green: 0.9, blue: 0.3, alpha: 1)
                        : NSColor(red: 0.05, green: 0.35, blue: 0.1, alpha: 1)
                    storage.beginEditing()
                    storage.replaceCharacters(in: NSRange(location: attrLen - 1, length: 1),
                        with: NSAttributedString(string: expected, attributes: [
                            .font: coord.termFont, .foregroundColor: color
                        ]))
                    storage.endEditing()
                }
            }
        }

        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        let h = (tv.layoutManager?.usedRect(for: tv.textContainer!).height ?? 40) + tv.textContainerInset.height * 2
        let callback = coord.onContentHeight
        DispatchQueue.main.async { callback?(h) }
    }
}
