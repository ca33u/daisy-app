//
//  SettingsTabsToolbar.swift
//  Daisy
//
//  The Settings tabs as the system's own toolbar tab control (25.09).
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

@MainActor
final class SettingsTabsToolbar: NSObject {
    static let identifier = NSToolbarItem.Identifier("app.essazanov.Daisy.settingsTabs")

    /// Called with the index the person picked.
    var onSelect: ((Int) -> Void)?
    /// Called when the tabs left the toolbar without `uninstall()` —
    /// SwiftUI rebuilt it and dropped an item it does not know. The
    /// caller shows its own tabs then, so no one is left without them.
    var onLost: (() -> Void)?

    private var removalObserver: (any NSObjectProtocol)?

    private(set) var group: NSToolbarItemGroup?
    private weak var toolbar: NSToolbar?

    /// Adds the tabs to `window`'s toolbar, centred. False when there is
    /// no toolbar to add to — the caller shows its own tabs instead.
    @discardableResult
    func install(in window: NSWindow, titles: [String], selected: Int) -> Bool {
        guard let toolbar = window.toolbar else { return false }
        if self.toolbar === toolbar, toolbar.items.contains(where: { $0.itemIdentifier == Self.identifier }) {
            select(selected)
            return true
        }
        let group = NSToolbarItemGroup(
            itemIdentifier: Self.identifier,
            titles: titles,
            selectionMode: .selectOne,
            labels: titles,
            target: self,
            action: #selector(picked(_:))
        )
        group.controlRepresentation = .automatic
        group.label = String(localized: "Settings")
        group.paletteLabel = group.label
        if #available(macOS 27.0, *) { group.role = .tabs }
        group.selectedIndex = selected
        self.group = group
        self.toolbar = toolbar

        let original = toolbar.delegate
        let proxy = DelegateProxy(original: original, item: group)
        toolbar.delegate = proxy
        toolbar.insertItem(withItemIdentifier: Self.identifier, at: toolbar.items.count)
        toolbar.delegate = original
        guard toolbar.items.contains(where: { $0.itemIdentifier == Self.identifier }) else { return false }
        toolbar.centeredItemIdentifiers = [Self.identifier]
        removalObserver = NotificationCenter.default.addObserver(
            forName: NSToolbar.didRemoveItemNotification, object: toolbar, queue: .main
        ) { [weak self] note in
            guard (note.userInfo?["item"] as? NSToolbarItem)?.itemIdentifier == Self.identifier else { return }
            MainActor.assumeIsolated {
                guard let self, self.group != nil else { return }
                self.stopObserving()
                self.group = nil
                self.toolbar = nil
                self.onLost?()
            }
        }
        return true
    }

    private func stopObserving() {
        if let removalObserver { NotificationCenter.default.removeObserver(removalObserver) }
        removalObserver = nil
    }

    func uninstall() {
        stopObserving()
        guard let toolbar else { return }
        if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == Self.identifier }) {
            toolbar.removeItem(at: index)
        }
        toolbar.centeredItemIdentifiers.remove(Self.identifier)
        self.toolbar = nil
        group = nil
    }

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
