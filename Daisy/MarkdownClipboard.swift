//
//  MarkdownClipboard.swift
//  Daisy
//
//  "The most convenient copy" (research pass 2026-06-13, approved by
//  Egor): every Copy button writes TWO representations of the same
//  content to the pasteboard —
//
//    public.html             our own semantic-HTML render of the text
//    public.utf8-plain-text  the raw markdown itself
//
//  Paste targets pick the richest flavor they understand. Slack,
//  Notion, Gmail, Apple Notes, Google Docs and friends read the HTML
//  and paste formatted text (real headings, nested bullets, bold,
//  checkbox glyphs — Notion even maps the tags back onto its native
//  blocks). Obsidian, Claude, Linear, code editors and terminals read
//  the plain-text flavor and get clean markdown. Craft and Bear ship
//  the same two-flavor pattern; before this, Daisy wrote markdown-only
//  plain text, so pasting a summary into Gmail showed literal `##`
//  and `- [ ]` markers.
//

import AppKit

// MARK: - Markdown subset → semantic HTML

/// Converter from OUR markdown subset to minimal semantic HTML for the
/// `public.html` pasteboard flavor. Deliberately NOT a CommonMark
/// engine — a line-by-line pass that understands exactly what Daisy's
/// own renderers emit (`MarkdownExporter.renderMarkdown`,
/// `SessionDetailView.assembledMarkdown`, `summaryMarkdown` below):
///
///   `#` / `##` / `###`   →  <h1> / <h2> / <h3>
///   `- ` bullets         →  nested <ul><li>. Indentation is tracked
///                           with a STACK of indent widths, so both the
///                           4-space nesting `summaryMarkdown` emits and
///                           the 2-space nesting in the full-document
///                           renderers nest correctly. The child <ul>
///                           opens INSIDE the parent's still-open <li>
///                           (the correct HTML nesting — Notion and
///                           Google Docs mis-map a <ul> that is a
///                           direct sibling). Capped at 3 levels.
///   `- [ ]` / `- [x]`    →  <li> with a ☐ / ☑ glyph prefix — NOT
///                           <input type=checkbox>: mail clients strip
///                           form elements, the glyph survives anywhere
///   `**bold**`           →  <strong> (evaluated per line, pairs only)
///   `> quote`            →  <blockquote>
///   blank line           →  paragraph boundary; any other line joins
///                           the current <p> (consecutive lines are
///                           separated with <br> so follow-up sign-offs
///                           and transcript rows keep their breaks)
///
/// Styling is the bare minimum, inline (no <head>/<style> — pasteboard
/// HTML is a fragment): block margins only, no colors, no fonts. The
/// paste TARGET applies its own typography; that neutrality is also
/// what lets Notion map elements onto native blocks instead of pasting
/// a styled foreign blob.
///
/// `&`, `<`, `>` are escaped BEFORE any tags are inserted — transcript
/// text is user speech and can contain anything.
nonisolated enum MarkdownHTML {

    private static let pStyle = " style=\"margin:0 0 8px;\""
    private static let ulStyle = " style=\"margin:0 0 8px;\""
    private static let hStyle = " style=\"margin:12px 0 6px;\""

    static func render(_ markdown: String) -> String {
        var html: [String] = []

        /// Pending <p> lines (already inline-rendered), joined with <br>.
        var paragraph: [String] = []
        /// Pending <blockquote> lines (already inline-rendered).
        var quote: [String] = []
        /// Open-list stack: leading-space width of each level + whether
        /// that level currently has an open <li>.
        var listStack: [(indent: Int, liOpen: Bool)] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            html.append("<p\(pStyle)>" + paragraph.joined(separator: "<br>") + "</p>")
            paragraph = []
        }

        func flushQuote() {
            guard !quote.isEmpty else { return }
            html.append("<blockquote>" + quote.joined(separator: "<br>") + "</blockquote>")
            quote = []
        }

        func closeLists() {
            while let frame = listStack.popLast() {
                if frame.liOpen { html.append("</li>") }
                html.append("</ul>")
            }
        }

        /// End whatever block is being accumulated — used at blank
        /// lines and before headings.
        func closeAllBlocks() {
            flushParagraph()
            flushQuote()
            closeLists()
        }

        /// One `- ` item with `indent` leading spaces. A deeper indent
        /// pushes a nested <ul> inside the parent's still-open <li>;
        /// a shallower one pops levels until it fits; an equal one
        /// closes the previous sibling <li>.
        func appendListItem(indent: Int, content: String) {
            if listStack.isEmpty {
                html.append("<ul\(ulStyle)>")
                listStack.append((indent: indent, liOpen: false))
            } else if indent > listStack[listStack.count - 1].indent {
                if listStack.count < 3 {
                    // Parent <li> stays open; the nested list lives
                    // inside it and the parent closes on dedent.
                    html.append("<ul\(ulStyle)>")
                    listStack.append((indent: indent, liOpen: false))
                }
                // At the 3-level cap: fall through and render as a
                // sibling of the deepest level instead of nesting on.
            } else if indent < listStack[listStack.count - 1].indent {
                while listStack.count > 1, indent < listStack[listStack.count - 1].indent {
                    let frame = listStack.removeLast()
                    if frame.liOpen { html.append("</li>") }
                    html.append("</ul>")
                }
            }
            if listStack[listStack.count - 1].liOpen {
                html.append("</li>")
            }
            html.append("<li>" + content)
            listStack[listStack.count - 1].liOpen = true
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                closeAllBlocks()
                continue
            }

            // Headings — our renderers emit them at column 0 only.
            // Longest prefix first so `###` never matches as `#`.
            if rawLine.hasPrefix("### ") {
                closeAllBlocks()
                html.append("<h3\(hStyle)>" + inline(String(rawLine.dropFirst(4))) + "</h3>")
                continue
            }
            if rawLine.hasPrefix("## ") {
                closeAllBlocks()
                html.append("<h2\(hStyle)>" + inline(String(rawLine.dropFirst(3))) + "</h2>")
                continue
            }
            if rawLine.hasPrefix("# ") {
                closeAllBlocks()
                html.append("<h1\(hStyle)>" + inline(String(rawLine.dropFirst(2))) + "</h1>")
                continue
            }

            // Block quote (the `> recorded …` metadata line).
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                closeLists()
                quote.append(trimmed == ">" ? "" : inline(String(trimmed.dropFirst(2))))
                continue
            }

            // Bullet / checkbox — `- ` after any run of leading spaces.
            let indent = rawLine.prefix(while: { $0 == " " }).count
            let rest = String(rawLine.dropFirst(indent))
            if rest.hasPrefix("- ") {
                flushParagraph()
                flushQuote()
                var item = String(rest.dropFirst(2))
                var marker = ""
                if item.hasPrefix("[ ] ") {
                    marker = "☐ "
                    item = String(item.dropFirst(4))
                } else if item.hasPrefix("[x] ") || item.hasPrefix("[X] ") {
                    marker = "☑ "
                    item = String(item.dropFirst(4))
                }
                appendListItem(indent: indent, content: marker + inline(item))
                continue
            }

            // Plain paragraph line.
            flushQuote()
            closeLists()
            paragraph.append(inline(trimmed))
        }

        closeAllBlocks()
        return html.joined(separator: "\n")
    }

    // MARK: Inline pieces

    /// Escape, then `**bold**` → <strong>. Bold is applied only when
    /// the `**` markers pair up within the line (our renderers emit
    /// balanced pairs per line — the same contract SelectableTextView's
    /// in-app renderer relies on); unpaired markers stay literal.
    private static func inline(_ text: String) -> String {
        let escaped = escape(text)
        let parts = escaped.components(separatedBy: "**")
        guard parts.count > 2, parts.count % 2 == 1 else { return escaped }
        var out = ""
        for (i, part) in parts.enumerated() {
            out += i.isMultiple(of: 2) ? part : "<strong>" + part + "</strong>"
        }
        return out
    }

    /// Minimal HTML entity escape — must run BEFORE any tag is added.
    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - MeetingSummary → markdown body

/// Standalone markdown for the Summary block's Copy button. Mirrors
/// `summaryAttributedString(_:compact:)` (SelectableTextView.swift)
/// 1:1 in content and order — lede → topical sections → action items →
/// follow-up — so what the user copies is what the card shows:
///
///     <lede paragraph>
///
///     ## <section title>
///     - bullet
///         - sub-bullet          (4-space nesting — Gruber-classic,
///                                parses everywhere incl. Obsidian)
///
///     ## <labels.nextActions>
///     - [ ] action item
///
///     ## <labels.followUp>
///     <follow-up paragraphs>
///
/// No frontmatter and no `#` document title — this is a fragment the
/// user drops into a chat / note, not a vault file. Structural headers
/// come from `SummaryLabels`, localised to the summary's own language
/// by the caller (same content sniffing the card does). Empty blocks
/// are skipped exactly like in the card; legacy pre-1.0.2 summaries
/// (`sections == []`) degrade to the lede paragraph alone.
nonisolated func summaryMarkdown(_ summary: MeetingSummary, labels: SummaryLabels) -> String {
    var lines: [String] = []
    if !summary.summary.isEmpty {
        lines.append(summary.summary)
        lines.append("")
    }
    for section in summary.sections {
        lines.append("## \(section.title)")
        lines.append("")
        appendSummaryBullets(section.bullets, level: 0, into: &lines)
        lines.append("")
    }
    if !summary.actionItems.isEmpty {
        lines.append("## \(labels.nextActions)")
        lines.append("")
        for item in summary.actionItems {
            lines.append("- [ ] \(item)")
        }
        lines.append("")
    }
    if !summary.clientFollowUp.isEmpty {
        lines.append("## \(labels.followUp)")
        lines.append("")
        lines.append(summary.clientFollowUp)
    }
    while lines.last?.isEmpty == true {
        lines.removeLast()
    }
    return lines.joined(separator: "\n")
}

/// Recursive bullet writer for `summaryMarkdown` — 4 spaces per
/// nesting level (the step `MarkdownHTML`'s stack parser nests on).
nonisolated private func appendSummaryBullets(
    _ bullets: [SummaryBullet],
    level: Int,
    into lines: inout [String]
) {
    let indent = String(repeating: "    ", count: level)
    for bullet in bullets {
        lines.append("\(indent)- \(bullet.text)")
        if !bullet.children.isEmpty {
            appendSummaryBullets(bullet.children, level: level + 1, into: &lines)
        }
    }
}

// MARK: - Pasteboard writer

/// The clipboard writer every Copy button routes through.
///
/// `copy(markdown:)` writes ONE NSPasteboardItem carrying three
/// representations of the same content:
///
///   1. `public.html`                 — MarkdownHTML render (rich)
///   2. `public.utf8-plain-text`      — the raw markdown
///   3. `net.daringfireball.markdown` — the raw markdown again, under
///      the UTI markdown-native editors look for first
///
/// Declaration order matters: NSPasteboard wants types "ordered
/// according to the preference of the source application" and readers
/// walk that list front-to-back — richest first is the Craft/Bear
/// two-flavor convention this mirrors (2026-06-13 research).
///
/// `copyPlain(markdown:)` is the explicit raw-markdown escape hatch
/// ("Copy as Markdown" / "Copy for Obsidian" in the session kebab):
/// plain-text flavor ONLY, so even targets that prefer HTML (mail
/// composers, Notion) receive the literal markdown source.
@MainActor
enum RichClipboard {

    /// UTI for raw markdown source — Bear, iA Writer, Ulysses and
    /// other markdown-native apps read this flavor ahead of plain text.
    static let markdownType = NSPasteboard.PasteboardType("net.daringfireball.markdown")

    /// Two-flavor write: semantic HTML for rich paste targets
    /// (Slack / Notion / Gmail / Apple Notes / Google Docs), raw
    /// markdown for plain-text ones (Obsidian / Claude / editors).
    static func copy(markdown: String) {
        let item = NSPasteboardItem()
        // Richest type FIRST — see the type-ordering note above.
        // The charset declaration comes first: without it TextEdit, Word
        // and Pages read the fragment as Latin-1 and Cyrillic pastes as
        // mojibake (bug report, 2026-10-09).
        item.setString("<meta charset=\"utf-8\">" + MarkdownHTML.render(markdown), forType: .html)
        item.setString(markdown, forType: .string)
        item.setString(markdown, forType: markdownType)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
    }

    /// Plain-text-only write — raw markdown, no HTML flavor.
    static func copyPlain(markdown: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(markdown, forType: .string)
    }
}
