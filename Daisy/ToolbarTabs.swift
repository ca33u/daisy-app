//
//  ToolbarTabs.swift
//  Daisy
//
//  A page's tabs as the system's own toolbar tab control — Settings
//  (25.09) and Dictation (26.09).
//
//  SwiftUI puts a segmented `Picker` in the toolbar as a drawn view with
//  no menu of its own. When the window was too narrow, macOS moved it
//  into «>>», whose menu sometimes listed the six tabs, sometimes one
//  empty checked row, and sometimes the tabs vanished with no «>>» at
//  all — a user lost the Connections tab (webhooks).
//
//  AppKit has the control made for this, the one Mail and Finder use:
//  an `NSToolbarItemGroup` of titles, one selectable at a time. It wears
//  the system's glass, and with `.automatic` representation it folds
//  itself into a glass pop-up of all six tabs when space is tight — in
//  the toolbar, not in «>>». On macOS 27 it is also told it is tabs.
//
//  SwiftUI owns the window's toolbar and its delegate and has no API for
//  such an item, so the group is added beside SwiftUI's own items: for
//  the moment of insertion a proxy answers for our identifier and hands
//  every other question to SwiftUI's delegate, which is put back after.
//

import AppKit
import SwiftUI

@MainActor
final class ToolbarTabs: NSObject {
    let identifier: NSToolbarItem.Identifier
    private var titles: [String] = []
    private weak var window: NSWindow?

    init(identifier: String) {
        self.identifier = NSToolbarItem.Identifier(identifier)
    }

    /// Called with the index the person picked.
    var onSelect: ((Int) -> Void)?
    /// Called when the tabs left the toolbar without `uninstall()` and
    /// could not be put back after several tries — the caller shows its
    /// own tabs then, so no one is left without them. SwiftUI rebuilds a toolbar whose items
    /// change (Dictation's buttons follow its tab) and drops an item it
    /// does not know; that is answered by adding the tabs again first.
    var onLost: (() -> Void)?

    private var removalObserver: (any NSObjectProtocol)?

    private(set) var group: NSToolbarItemGroup?
    private weak var toolbar: NSToolbar?

    /// Delays between attempts, in seconds. Right after a page appears
    /// SwiftUI may not have built the window's toolbar yet, and right
    /// after it rebuilds one it may still be busy; one try at either
    /// moment used to leave the page on its old-style fallback tabs until
    /// you left it (Egor, 07.10.2026: «табы иногда в старом стиле»).
    private static let retryDelays: [Double] = [0.05, 0.15, 0.4, 1.0, 2.0]

    /// `install`, retried over a couple of seconds before giving up.
    /// `done(true)` once the tabs are in the toolbar; `done(false)` only
    /// after the last try failed. Stops quietly if `uninstall()` ran.
    func installRetrying(in window: NSWindow, titles: [String], selected: @escaping () -> Int,
                         done: @escaping (Bool) -> Void) {
        wanted = true
        // Kept for the re-adds after a drop: they report through the same
        // `done`, so a success there clears the page's fallback strip, and
        // they read the page's CURRENT tab, not the one at the drop.
        currentSelected = selected
        currentDone = done
        generation &+= 1
        attempt(window: window, titles: titles, selected: selected, delays: Self.retryDelays,
                generation: generation, done: done)
    }

    /// Bumped by every new chain of attempts; an older chain still
    /// waiting on a delay (the page left and came back) stops instead of
    /// reporting a stale failure over the new one.
    private var generation = 0
    private var currentSelected: (() -> Int)?
    private var currentDone: ((Bool) -> Void)?

    private func attempt(window: NSWindow, titles: [String], selected: @escaping () -> Int,
                         delays: [Double], generation: Int, done: @escaping (Bool) -> Void) {
        guard wanted, generation == self.generation else { return }
        if install(in: window, titles: titles, selected: selected()) {
            done(true)
            return
        }
        guard let delay = delays.first else {
            done(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                self.attempt(window: window, titles: titles, selected: selected,
                             delays: Array(delays.dropFirst()), generation: generation, done: done)
            }
        }
    }

    /// Adds the tabs to `window`'s toolbar, centred. False when there is
    /// no toolbar to add to — the caller shows its own tabs instead.
    @discardableResult
    func install(in window: NSWindow, titles: [String], selected: Int) -> Bool {
        guard let toolbar = window.toolbar else { return false }
        wanted = true
        if self.toolbar === toolbar, toolbar.items.contains(where: { $0.itemIdentifier == identifier }) {
            select(selected)
            return true
        }
        // The toolbar may already hold an item with our identifier that is
        // not this object's — another instance's (the page was rebuilt), or
        // one put back while a re-install was waiting. AppKit asserts on a
        // duplicate identifier and the assertion ends the app (crash
        // 03.10.2026, 1.0.8.18: NSToolbar _insertNewItemWithItemIdentifier).
        // The old one goes first; its owner sees ours and stands down.
        while let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == identifier }) {
            toolbar.removeItem(at: index)
        }
        self.titles = titles
        self.window = window
        let group = NSToolbarItemGroup(
            itemIdentifier: identifier,
            titles: titles,
            selectionMode: .selectOne,
            labels: titles,
            target: self,
            action: #selector(picked(_:))
        )
        group.controlRepresentation = .automatic
        // The page's tabs are the last thing to hide: when the toolbar is
        // tight, buttons beside them go to «>>» first and the tabs fold
        // into their pop-up (Dictation's wide text buttons took their room
        // at 900 pt and sent them to «>>», 26.09).
        group.visibilityPriority = .high
        group.label = titles.joined(separator: " / ")
        group.paletteLabel = group.label
        if #available(macOS 27.0, *) { group.role = .tabs }
        group.selectedIndex = selected
        self.group = group
        self.toolbar = toolbar

        insertGroup(into: toolbar)
        guard toolbar.items.contains(where: { $0.itemIdentifier == identifier }) else { return false }
        toolbar.centeredItemIdentifiers = [identifier]
        stopObserving()
        let id = identifier
        removalObserver = NotificationCenter.default.addObserver(
            forName: NSToolbar.didRemoveItemNotification, object: toolbar, queue: .main
        ) { [weak self] note in
            guard (note.userInfo?["item"] as? NSToolbarItem)?.itemIdentifier == id else { return }
            MainActor.assumeIsolated { self?.dropped() }
        }
        return true
    }

    /// The toolbar let go of the tabs behind our back: add them again
    /// once SwiftUI has finished rebuilding; give up only if that fails.
    private func dropped() {
        guard let group else { return }
        let selected = group.selectedIndex
        stopObserving()
        self.group = nil
        self.toolbar = nil
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.wanted else { return }
                // Somebody else's tabs are there now (see `install`): this
                // object is no longer the one on screen, and putting its
                // own back would only start a tug of war.
                if let toolbar = self.window?.toolbar, self.group == nil,
                   toolbar.items.contains(where: { $0.itemIdentifier == self.identifier }) {
                    return
                }
                guard let window = self.window else {
                    self.onLost?()
                    return
                }
                // A rebuild can still be settling: try again for a moment
                // before showing the fallback.
                self.generation &+= 1
                let done = self.currentDone
                self.attempt(window: window, titles: self.titles,
                             selected: self.currentSelected ?? { selected },
                             delays: Self.retryDelays, generation: self.generation) { [weak self] ok in
                    if let done { done(ok) } else if !ok { self?.onLost?() }
                }
            }
        }
    }

    /// Where the tabs go: after the sidebar's tracking separator and the
    /// first item of the content area — the «Daisy» pill every page has —
    /// so the page's own buttons come after them. AppKit centres an item
    /// (`centeredItemIdentifiers`) between what is before it and what is
    /// after: appended at the end, after Dictation's three buttons, the
    /// tabs sat at the right edge (Egor, 06.10.2026); after the leading
    /// flexible space (1.0.8.21, 1.0.8.22) they went into the sidebar's
    /// part. Read from the items themselves in a debug build: SwiftUI's
    /// separator is an `NSTrackingSeparatorToolbarItem` with its own
    /// identifier, not `.sidebarTrackingSeparator`.
    private func insertGroup(into toolbar: NSToolbar) {
        guard let group else { return }
        let original = toolbar.delegate
        // Held here: the toolbar's delegate is weak, and a proxy nobody
        // holds is gone before the insert asks it for the item.
        let proxy = DelegateProxy(original: original, item: group)
        toolbar.delegate = proxy
        toolbar.insertItem(withItemIdentifier: identifier, at: Self.contentStart(in: toolbar))
        toolbar.delegate = original
        withExtendedLifetime(proxy) {}
    }

    private static func contentStart(in toolbar: NSToolbar) -> Int {
        let items = toolbar.items
        guard let separator = items.firstIndex(where: {
            $0 is NSTrackingSeparatorToolbarItem || $0.itemIdentifier == .sidebarTrackingSeparator
        }) else { return items.count }
        // Past the pill, when there is one.
        return min(items.count, separator + 2)
    }

    private func stopObserving() {
        if let removalObserver { NotificationCenter.default.removeObserver(removalObserver) }
        removalObserver = nil
    }

    func uninstall() {
        stopObserving()
        // The page is gone, whatever state the tabs were in. When SwiftUI
        // rebuilt the toolbar first, `dropped()` had already cleared
        // `toolbar` and queued a re-install — and this used to return
        // before forgetting the window, so the re-install put Settings'
        // tabs into the Library's toolbar (seen 04.10.2026 in 1.0.8.19,
        // and «Словарь / История» there the day before).
        wanted = false
        generation &+= 1
        currentSelected = nil
        currentDone = nil
        let toolbar = self.toolbar ?? window?.toolbar
        self.toolbar = nil
        window = nil
        group = nil
        guard let toolbar else { return }
        while let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == identifier }) {
            toolbar.removeItem(at: index)
        }
        toolbar.centeredItemIdentifiers.remove(identifier)
    }

    /// True between `install` and `uninstall`: the page that owns these
    /// tabs is on screen. A re-install after a drop happens only then.
    private var wanted = false

    func select(_ index: Int) {
        guard let group, group.selectedIndex != index else { return }
        group.selectedIndex = index
    }

    @objc private func picked(_ sender: NSToolbarItemGroup) {
        onSelect?(sender.selectedIndex)
    }
}

/// Answers for the tabs item and passes everything else to the
/// delegate SwiftUI installed.
private final class DelegateProxy: NSObject, NSToolbarDelegate {
    private weak var original: (any NSToolbarDelegate)?
    private let item: NSToolbarItem

    init(original: (any NSToolbarDelegate)?, item: NSToolbarItem) {
        self.original = original
        self.item = item
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == item.itemIdentifier { return item }
        return original?.toolbar?(toolbar, itemForItemIdentifier: itemIdentifier, willBeInsertedIntoToolbar: flag)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        original?.toolbarDefaultItemIdentifiers?(toolbar) ?? []
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        (original?.toolbarAllowedItemIdentifiers?(toolbar) ?? []) + [item.itemIdentifier]
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original
    }
}

/// Hands over the window a view lands in (nil when it leaves one) —
/// after SwiftUI has put its own toolbar items in place.
struct WindowFinder: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { Probe(found: found) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        let found: (NSWindow?) -> Void
        init(found: @escaping (NSWindow?) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            DispatchQueue.main.async { self.found(window) }
        }
    }
}
