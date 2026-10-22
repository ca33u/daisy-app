//
//  DaisyResultCard.swift
//  Daisy
//
//  The card at the cursor (backlog 34 K-2, spec «Карточка результата»).
//  A Daisy-key result that can't go straight into a field — an answer
//  about the selection, a reply to a selected email, a result the field
//  moved away from — is shown here and copied to the clipboard. An edit
//  that went in is shown here too, as a proposal: «Вернуть» puts the
//  original back (⌘Z in that app, one step), «Показать изменения» shows
//  what changed.
//
//  While the card is open, holding the Daisy key and saying something
//  works on the card's text («переведи на английский», «короче»): the
//  result is a new version, the arrow goes back. For five minutes after
//  it closes, an edit said with nothing selected applies to the last
//  result and brings the card back.
//
//  The panel is non-activating: clicking it leaves the other app in
//  front, so «Вставить» inserts where the person is typing.
//

import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

@MainActor
@Observable
final class DaisyResultCard {
    static let shared = DaisyResultCard()

    /// Versions of the text, oldest first; `index` is the one shown.
    private(set) var versions: [String] = []
    private(set) var index = 0
    /// «Использовано: выделение · Mail».
    private(set) var usedLine = ""
    /// For an edit: the text it replaced.
    private(set) var original: String?
    /// The edit went into the field, so «Вернуть» is ⌘Z there.
    private(set) var editInserted = false
    var showsChanges = false
    /// The shape and voice the text was written for: a refinement keeps
    /// them (a mail reply stays a mail reply, a terminal line one line).
    private(set) var field: VoiceCommandContext.Field = .plain
    private(set) var voice: String?

    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var isShown = false
    @ObservationIgnored private var escape: EscapeWatch?
    @ObservationIgnored private var lastClosedAt: Date?
    /// The field an inserted edit went into: «Вернуть» acts only there.
    @ObservationIgnored private var insertedInto: AXElementBox?
    @ObservationIgnored private var appSwitch: NSObjectProtocol?

    /// How long after closing an edit said with nothing selected still
    /// means the last result (spec 21.10).
    nonisolated static let followUpWindow: TimeInterval = 5 * 60

    private init() {}

    var isOpen: Bool { isShown }
    var current: String { versions.indices.contains(index) ? versions[index] : "" }
    var canGoBack: Bool { index > 0 }

    /// Open, or within the follow-up window after closing.
    var canRefineLast: Bool {
        guard !versions.isEmpty else { return false }
        if isOpen { return true }
        guard let lastClosedAt else { return false }
        return Date().timeIntervalSince(lastClosedAt) <= Self.followUpWindow
    }

    /// `insertedInto`: the edit already went into this field — the card
    /// is its proposal (Вернуть, Показать изменения) and leaves the
    /// clipboard alone, which the insert just promised. Otherwise the
    /// text couldn't go anywhere and is copied.
    func show(_ text: String, used: String, original: String? = nil, insertedInto: AXElementBox? = nil,
              field: VoiceCommandContext.Field = .plain, voice: String? = nil) {
        versions = [text]
        index = 0
        usedLine = used
        self.original = original
        self.insertedInto = insertedInto
        editInserted = insertedInto != nil
        self.field = field
        self.voice = voice
        showsChanges = false
        if !editInserted { copyCurrent(announce: false) }
        present()
    }

    /// A refinement: a new version on top, shown and copied.
    func addVersion(_ text: String) {
        versions = Array(versions.prefix(index + 1)) + [text]
        index = versions.count - 1
        // A refined text is no longer the edit that went in: «Вернуть»
        // would undo something else.
        editInserted = false
        insertedInto = nil
        copyCurrent(announce: false)
        present()
    }

    func back() {
        guard canGoBack else { return }
        index -= 1
        copyCurrent(announce: false)
        refit()
    }

    func copyCurrent(announce: Bool = true) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(current, forType: .string)
        if announce { ToastCenter.shared.show(String(localized: "Copied"), style: .success) }
    }

    /// Into the field in front now — the panel never took the focus.
    func insert() {
        let text = current
        close()
        DictationPaste.shared.insert(text)
    }

    /// The inserted edit, undone with ⌘Z — only while the focus is still
    /// in the field it went into; anywhere else ⌘Z would undo something
    /// the person did, or land in another app.
    func revert() {
        guard editInserted, let insertedInto else { return }
        guard DaisyKeyContext.focusedElement() == insertedInto else {
            ToastCenter.shared.show(String(localized: "Click back into that field and press ⌘Z there"), style: .info)
            WidgetBubbleCenter.shared.present(
                WidgetBubbleContent(text: String(localized: "Click back into that field and press ⌘Z there")),
                notificationTitle: "Daisy")
            return
        }
        close()
        PasteboardProxy.shared.postCommandKeystroke(CGKeyCode(kVK_ANSI_Z))
        ImprovementStats.record(.daisyKeyUndone)
    }

    func close() {
        guard isShown else { return }
        isShown = false
        // Ordered out, not released: this can run inside the panel's own
        // button action.
        panel?.orderOut(nil)
        escape?.stop()
        escape = nil
        if let appSwitch { NSWorkspace.shared.notificationCenter.removeObserver(appSwitch) }
        appSwitch = nil
        lastClosedAt = Date()
    }

    // MARK: Panel

    private func present() {
        if isShown {
            refit()
            installAppSwitchWatchIfNeeded()
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        isShown = true
        fit(panel)
        panel.orderFrontRegardless()
        refit()
        escape = EscapeWatch { [weak self] in
            // Esc while a refinement is being written stops that; the next
            // one closes the card.
            guard !DaisyKeyController.shared.isBusy else { return }
            self?.close()
        }
        installAppSwitchWatchIfNeeded()
    }

    /// An inserted edit's proposal is about that field: moving to another
    /// app ends it, so it can't catch a later command there.
    private func installAppSwitchWatchIfNeeded() {
        if editInserted, appSwitch == nil {
            appSwitch = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.editInserted else { return }
                    self.close()
                }
            }
        }
    }

    /// Sized again after SwiftUI has laid out the new content.
    private func refit() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isShown, let panel = self.panel else { return }
            self.fit(panel)
        }
    }

    private func makePanel() -> NSPanel {
        let host = FirstClickHostingView(rootView: DaisyResultCardView(card: self))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Dark like the widget and its pill, whatever the system theme.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = host
        return panel
    }

    /// Sized to its content, next to the widget (Egor 22.10: not wherever
    /// the mouse happened to be) — above it, right edges together, or
    /// below when there's no room above; where the widget would be, in the
    /// bottom-right corner, when it's hidden. Inside the screen.
    private func fit(_ panel: NSPanel) {
        guard let host = panel.contentView else { return }
        let size = host.fittingSize
        let widget = WidgetBubbleCenter.shared.host?.widgetFrame
        let screen = widget.flatMap { frame in NSScreen.screens.first { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) } }
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = Self.origin(for: size, beside: widget, in: visible)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    nonisolated static func origin(for size: NSSize, beside widget: NSRect?, in visible: NSRect) -> NSPoint {
        let gap: CGFloat = 10
        let anchor = widget ?? NSRect(x: visible.maxX - 24 - 58, y: visible.minY + 24, width: 58, height: 58)
        var origin = NSPoint(x: anchor.maxX - size.width, y: anchor.maxY + gap)
        if origin.y + size.height > visible.maxY - 8 { origin.y = anchor.minY - gap - size.height }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        return origin
    }
}

/// A hosting view whose first click counts: the panel is never key, and
/// a click that only "activated" it would make every button need two.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Word-level changes between two texts, for «Показать изменения».
nonisolated enum DaisyTextChanges {
    enum Piece: Equatable, Sendable {
        case same(String)
        case removed(String)
        case added(String)
    }

    static func pieces(from old: String, to new: String) -> [Piece] {
        let a = old.split(whereSeparator: \.isWhitespace).map(String.init)
        let b = new.split(whereSeparator: \.isWhitespace).map(String.init)
        let diff = b.difference(from: a)
        var removed = Set<Int>(), added = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        var pieces: [Piece] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { pieces.append(.removed(a[i])); i += 1; continue }
            if j < b.count, added.contains(j) { pieces.append(.added(b[j])); j += 1; continue }
            if i < a.count, j < b.count { pieces.append(.same(b[j])); i += 1; j += 1; continue }
            break
        }
        return pieces
    }
}

private struct DaisyResultCardView: View {
    @Bindable var card: DaisyResultCard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(card.usedLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if card.versions.count > 1 {
                    Text(verbatim: "\(card.index + 1)/\(card.versions.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Button { card.close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close (Esc)")
            }
            ScrollView {
                Group {
                    if card.showsChanges, let original = card.original {
                        changes(from: original, to: card.current)
                    } else {
                        Text(card.current)
                    }
                }
                .font(.callout)
                .foregroundStyle(Color.daisyTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 260)
            Text("Hold the Daisy key to change this text — “in English”, “shorter”")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                if card.canGoBack {
                    Button { card.back() } label: { Image(systemName: "chevron.left") }
                        .help("Previous version")
                }
                Button("Copy") { card.copyCurrent() }
                // An edit already in the field would be inserted twice.
                if !card.editInserted {
                    Button("Insert") { card.insert() }
                        .buttonStyle(.daisyPrimary)
                }
                Spacer(minLength: 8)
                if card.original != nil {
                    Toggle("Show changes", isOn: $card.showsChanges)
                        .toggleStyle(.button)
                }
                if card.editInserted {
                    Button("Undo") { card.revert() }
                        .help("Puts the original text back")
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 400, alignment: .leading)
        // The widget's and the pill's warm near-black, always (Egor 22.10).
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(red: 28 / 255, green: 26 / 255, blue: 23 / 255)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }

    private func changes(from old: String, to new: String) -> Text {
        DaisyTextChanges.pieces(from: old, to: new).reduce(Text(verbatim: "")) { text, piece in
            switch piece {
            case .same(let word):
                return text + Text(verbatim: word + " ")
            case .removed(let word):
                return text + Text(verbatim: word).strikethrough().foregroundColor(.red) + Text(verbatim: " ")
            case .added(let word):
                return text + Text(verbatim: word).foregroundColor(.green) + Text(verbatim: " ")
            }
        }
    }
}
