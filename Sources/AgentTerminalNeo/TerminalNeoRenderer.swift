import AppKit

/// Renders markdown text as NSAttributedString with retro neo green terminal styling.
/// Supports: tables (NSTextTable), headers, bold, italic, inline code, code blocks, lists, horizontal rules.
public enum TerminalNeoRenderer: Sendable {

    public nonisolated(unsafe) static let font = NSFont.monospacedSystemFont(ofSize: 16.5, weight: .regular)
    public nonisolated(unsafe) static let boldFont = NSFont.monospacedSystemFont(ofSize: 16.5, weight: .bold)

    // MARK: - Regex patterns

    private static let boldItalicRx = try? NSRegularExpression(pattern: #"\*\*\*(.+?)\*\*\*"#)
    private static let boldRx = try? NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)
    private static let italicRx = try? NSRegularExpression(pattern: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#)
    private static let codeRx = try? NSRegularExpression(pattern: #"`([^`]+)`"#)
    private static let headerRx = try? NSRegularExpression(pattern: #"^(#{1,6})\s+(.+)$"#, options: .anchorsMatchLines)
    private static let bulletRx = try? NSRegularExpression(pattern: #"^(\s*)[-*+]\s+(.*)"#)
    private static let numListRx = try? NSRegularExpression(pattern: #"^(\s*)\d+\.\s+(.*)"#)
    private static let hrRx = try? NSRegularExpression(pattern: #"^\s*([-*_]\s*){3,}$"#)

    // MARK: - Public API

    /// Render markdown text to NSAttributedString with retro neo green terminal styling.
    public static func render(_ text: String) -> NSAttributedString {
        let lines = text.components(separatedBy: "\n")
        let result = NSMutableAttributedString()
        var i = 0
        var inCodeBlock = false
        var codeLines: [String] = []

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Code block fences
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    if result.length > 0 { result.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
                    let codeText = codeLines.joined(separator: "\n")
                    result.append(NSAttributedString(string: codeText, attributes: [
                        .font: font, .foregroundColor: TerminalNeoTheme.bright, .backgroundColor: TerminalNeoTheme.codeBg
                    ]))
                    codeLines = []
                    inCodeBlock = false
                } else {
                    inCodeBlock = true
                }
                i += 1
                continue
            }
            if inCodeBlock {
                codeLines.append(line)
                i += 1
                continue
            }

            // Table block
            if i + 2 < lines.count,
               trimmed.hasPrefix("|"),
               isTableSeparator(lines[i + 1]) {
                var tableEnd = i + 2
                while tableEnd < lines.count,
                      lines[tableEnd].trimmingCharacters(in: .whitespaces).hasPrefix("|"),
                      !isTableSeparator(lines[tableEnd]) {
                    tableEnd += 1
                }
                result.append(renderTable(lines: Array(lines[i..<tableEnd])))
                i = tableEnd
                continue
            }

            if i > 0 { result.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
            result.append(renderLine(line))
            i += 1
        }
        return result
    }

    // MARK: - Table

    public static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|") else { return false }
        var inner = t[t.index(after: t.startIndex)...]
        if inner.hasSuffix("|") { inner = inner.dropLast() }
        let cells = inner.split(separator: "|", omittingEmptySubsequences: false)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let s = cell.trimmingCharacters(in: .whitespaces)
            return !s.isEmpty && s.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    public static func parseTableRow(_ line: String) -> [String] {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|") else { return [] }
        var inner = t[t.index(after: t.startIndex)...]
        if inner.hasSuffix("|") { inner = inner.dropLast() }
        return inner.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Render markdown tables as plain monospaced box-drawing text (┌─┐│└┘├┤┬┴┼).
    /// IMPORTANT: We deliberately do NOT use NSTextTable here. NSTextView+NSTextTable
    /// performs internal layout reflow that auto-scrolls the document during streaming —
    /// fighting any user-scroll-respect logic we add at the wrapping layer. Plain
    /// box-drawing text has zero layout magic, so it scrolls predictably with the rest
    /// of the content.
    private static func renderTable(lines: [String]) -> NSAttributedString {
        let headerCells = parseTableRow(lines[0])
        var dataRows: [[String]] = []
        for r in 2..<lines.count {
            dataRows.append(parseTableRow(lines[r]))
        }
        let colCount = headerCells.count
        guard colCount > 0 else {
            return NSAttributedString(string: lines.joined(separator: "\n"), attributes: [.font: font, .foregroundColor: TerminalNeoTheme.text])
        }

        // Compute column widths (header width OR max data cell width per column)
        var widths = headerCells.map { $0.count }
        for row in dataRows {
            for (col, cell) in row.enumerated() where col < colCount {
                widths[col] = max(widths[col], cell.count)
            }
        }
        // Pad each column to at least 3 chars wide for readability
        widths = widths.map { max($0, 3) }

        func padCell(_ s: String, width: Int) -> String {
            s + String(repeating: " ", count: max(0, width - s.count))
        }
        func rowLine(_ cells: [String]) -> String {
            var parts: [String] = []
            for col in 0..<colCount {
                let cell = col < cells.count ? cells[col] : ""
                parts.append(" " + padCell(cell, width: widths[col]) + " ")
            }
            return "│" + parts.joined(separator: "│") + "│"
        }

        let topLine    = "┌" + widths.map { String(repeating: "─", count: $0 + 2) }.joined(separator: "┬") + "┐"
        let midLine    = "├" + widths.map { String(repeating: "─", count: $0 + 2) }.joined(separator: "┼") + "┤"
        let bottomLine = "└" + widths.map { String(repeating: "─", count: $0 + 2) }.joined(separator: "┴") + "┘"

        let result = NSMutableAttributedString()
        let dimAttr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: TerminalNeoTheme.dim]
        let cellAttr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: TerminalNeoTheme.cellFg]
        let headerAttr: [NSAttributedString.Key: Any] = [.font: boldFont, .foregroundColor: TerminalNeoTheme.bright]

        result.append(NSAttributedString(string: topLine + "\n", attributes: dimAttr))
        result.append(NSAttributedString(string: rowLine(headerCells) + "\n", attributes: headerAttr))
        result.append(NSAttributedString(string: midLine + "\n", attributes: dimAttr))
        for row in dataRows {
            result.append(NSAttributedString(string: rowLine(row) + "\n", attributes: cellAttr))
        }
        result.append(NSAttributedString(string: bottomLine, attributes: dimAttr))
        return result
    }

    // MARK: - Line rendering

    private static func renderLine(_ line: String) -> NSAttributedString {
        let ns = line as NSString
        let r = NSRange(location: 0, length: ns.length)

        if hrRx?.firstMatch(in: line, range: r) != nil {
            return NSAttributedString(string: String(repeating: "─", count: 40),
                                      attributes: [.font: font, .foregroundColor: TerminalNeoTheme.dim])
        }

        if let m = headerRx?.firstMatch(in: line, range: r) {
            let level = ns.substring(with: m.range(at: 1)).count
            let content = ns.substring(with: m.range(at: 2))
            let size = max(11, 18 - CGFloat(level) * 1.5)
            let hFont = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
            return applyInlineMarkdown(content, baseFont: hFont, baseColor: TerminalNeoTheme.bright)
        }

        if let m = bulletRx?.firstMatch(in: line, range: r) {
            let indent = ns.substring(with: m.range(at: 1))
            let content = ns.substring(with: m.range(at: 2))
            let bullet = NSMutableAttributedString(string: indent + "  \u{2022} ",
                                                    attributes: [.font: font, .foregroundColor: TerminalNeoTheme.dim])
            bullet.append(applyInlineMarkdown(content, baseFont: font, baseColor: TerminalNeoTheme.text))
            return bullet
        }

        if let m = numListRx?.firstMatch(in: line, range: r) {
            let indent = ns.substring(with: m.range(at: 1))
            let content = ns.substring(with: m.range(at: 2))
            let numEnd = line.firstIndex(of: ".")!
            let num = String(line[line.startIndex...numEnd])
            let prefix = NSMutableAttributedString(string: indent + num + " ",
                                                    attributes: [.font: font, .foregroundColor: TerminalNeoTheme.dim])
            prefix.append(applyInlineMarkdown(content, baseFont: font, baseColor: TerminalNeoTheme.text))
            return prefix
        }

        return applyInlineMarkdown(line, baseFont: font, baseColor: TerminalNeoTheme.text)
    }

    // MARK: - Inline markdown

    private static func applyInlineMarkdown(_ text: String, baseFont: NSFont, baseColor: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: baseFont, .foregroundColor: baseColor])
        let ns = text as NSString
        let r = NSRange(location: 0, length: ns.length)
        let bFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .bold)
        let iFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        let tinyFont = NSFont.monospacedSystemFont(ofSize: 1, weight: .regular)

        // Inline code
        codeRx?.enumerateMatches(in: text, range: r) { m, _, _ in
            guard let m else { return }
            result.addAttributes([.foregroundColor: TerminalNeoTheme.bright, .backgroundColor: TerminalNeoTheme.codeBg], range: m.range(at: 1))
            result.addAttributes([.foregroundColor: NSColor.clear, .font: tinyFont], range: NSRange(location: m.range.location, length: 1))
            result.addAttributes([.foregroundColor: NSColor.clear, .font: tinyFont], range: NSRange(location: m.range.location + m.range.length - 1, length: 1))
        }

        // Bold+Italic ***text***
        boldItalicRx?.enumerateMatches(in: text, range: r) { m, _, _ in
            guard let m else { return }
            let biFont = NSFontManager.shared.convert(bFont, toHaveTrait: .italicFontMask)
            result.addAttributes([.font: biFont, .foregroundColor: TerminalNeoTheme.bright], range: m.range(at: 1))
            for offset in [m.range.location, m.range.location + 1, m.range.location + 2,
                           m.range.location + m.range.length - 3, m.range.location + m.range.length - 2, m.range.location + m.range.length - 1] {
                result.addAttributes([.foregroundColor: NSColor.clear, .font: tinyFont], range: NSRange(location: offset, length: 1))
            }
        }

        // Bold **text**
        boldRx?.enumerateMatches(in: text, range: r) { m, _, _ in
            guard let m else { return }
            result.addAttributes([.font: bFont, .foregroundColor: TerminalNeoTheme.bright], range: m.range(at: 1))
            for offset in [m.range.location, m.range.location + 1,
                           m.range.location + m.range.length - 2, m.range.location + m.range.length - 1] {
                result.addAttributes([.foregroundColor: NSColor.clear, .font: tinyFont], range: NSRange(location: offset, length: 1))
            }
        }

        // Italic *text*
        italicRx?.enumerateMatches(in: text, range: r) { m, _, _ in
            guard let m else { return }
            result.addAttribute(.font, value: iFont, range: m.range(at: 1))
            result.addAttributes([.foregroundColor: NSColor.clear, .font: tinyFont], range: NSRange(location: m.range.location, length: 1))
            result.addAttributes([.foregroundColor: NSColor.clear, .font: tinyFont], range: NSRange(location: m.range.location + m.range.length - 1, length: 1))
        }

        return result
    }
}
