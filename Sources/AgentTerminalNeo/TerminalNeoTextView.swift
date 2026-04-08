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
        var lastReportedHeight: CGFloat = 0
    }

    public func makeNSView(context: Context) -> NSView {
        // Plain NSView container holding an NSTextView. NO NSScrollView wrapper —
        // there is zero scroll machinery anywhere in this view. Caller is responsible
        // for any scroll behavior they want by wrapping this view as needed.
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView()
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
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(textView)

        // CRT scanline overlay — pinned above the text via zPosition
        let scanline = ScanlineOverlayView()
        scanline.wantsLayer = true
        scanline.layer?.zPosition = 999
        scanline.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scanline)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: container.topAnchor),
            textView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scanline.topAnchor.constraint(equalTo: container.topAnchor),
            scanline.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scanline.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scanline.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        context.coordinator.textView = textView
        context.coordinator.onContentHeight = onContentHeight
        return container
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
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
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    storage.setAttributedString(TerminalNeoRenderer.render(text))
                    if let lm = tv.layoutManager, let container = tv.textContainer {
                        lm.ensureLayout(for: container)
                    }
                    CATransaction.commit()
                } else {
                    // No table — fast incremental append
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
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
                    CATransaction.commit()
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
            }
            // No auto-scroll — caller (LLMOutputTextView or other wrapper) owns scroll behavior.
        } else {
            // Cursor blink — skip entirely during table render
            guard !coord.needsTableRender else { return }
            let attrLen = storage.length
            if attrLen > 0 {
                let cursorChar = text.hasSuffix("█") ? "█" : " "
                let lastChar = storage.string.suffix(1)
                if String(lastChar) != cursorChar {
                    let isDark = tv.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    let color: NSColor = isDark
                        ? NSColor(red: 0.2, green: 0.9, blue: 0.3, alpha: 1)
                        : NSColor(red: 0.05, green: 0.35, blue: 0.1, alpha: 1)
                    storage.beginEditing()
                    storage.replaceCharacters(in: NSRange(location: attrLen - 1, length: 1),
                        with: NSAttributedString(string: cursorChar, attributes: [
                            .font: coord.termFont, .foregroundColor: color
                        ]))
                    storage.endEditing()
                }
            }
        }

        // Only report height when content changed — skip cursor blink
        let h: CGFloat
        if let lm = tv.layoutManager, let container = tv.textContainer {
            h = lm.usedRect(for: container).height + tv.textContainerInset.height * 2
        } else {
            h = 40 + tv.textContainerInset.height * 2
        }
        if abs(h - coord.lastReportedHeight) > 1 {
            coord.lastReportedHeight = h
            let callback = coord.onContentHeight
            DispatchQueue.main.async { callback?(h) }
        }
    }
}
