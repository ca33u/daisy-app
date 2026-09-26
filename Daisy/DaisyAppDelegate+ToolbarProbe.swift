//
//  DaisyAppDelegate+ToolbarProbe.swift
//  Daisy
//
//  DEBUG only. A check of the window toolbar and the Settings tabs that
//  needs neither the screen nor anyone's clicks (25.09): the app opens
//  Settings, sets its own window to several widths and writes what the
//  toolbar and the page's tab strip hold at each to /tmp/daisy-probe/.
//
//    -daisy.debugToolbarProbe 1
//

#if DEBUG
import AppKit

extension DaisyAppDelegate {
    /// `-daisy.debugToolbarProbe 1`: Settings at several window widths,
    /// with what the toolbar holds at each and a picture of the window —
    /// a check that needs neither the screen nor anyone's clicks.
    /// Output: /tmp/daisy-probe/.
    /// Our tab group: present, visible, which tab, how it is drawn, and
    /// whether the toolbar needed «>>».
    private func tabsState(_ window: NSWindow) -> String {
        guard let toolbar = window.toolbar else { return "TABS: no toolbar" }
        let visible = toolbar.visibleItems?.contains { $0.itemIdentifier == SettingsTabsToolbar.identifier } ?? false
        var clipped = false
        var groupViews: [String] = []
        func walk(_ v: NSView) {
            let name = String(describing: type(of: v))
            if name == "NSToolbarClippedItemsIndicator", !v.isHidden { clipped = true }
            if let control = v as? NSSegmentedControl, control.segmentCount == 6 {
                groupViews.append("segmented6 w=\(Int(v.frame.width)) shown=\(!v.isHiddenOrHasHiddenAncestor && v.window != nil && v.alphaValue > 0)")
            }
            if let popup = v as? NSPopUpButton, popup.numberOfItems >= 6 {
                groupViews.append("popup '\(popup.titleOfSelectedItem ?? "")' items=\(popup.numberOfItems) w=\(Int(v.frame.width)) shown=\(!v.isHiddenOrHasHiddenAncestor && v.alphaValue > 0)")
            }
            v.subviews.forEach(walk)
        }
        if let frame = window.contentView?.superview { walk(frame) }
        guard let group = toolbar.items.first(where: { $0.itemIdentifier == SettingsTabsToolbar.identifier }) as? NSToolbarItemGroup else {
            return "TABS: not in toolbar; clipped=\(clipped)"
        }
        return "TABS: in toolbar visible=\(visible) selected=\(group.selectedIndex) subitems=\(group.subitems.count) representation=\(group.controlRepresentation.rawValue) clipped=\(clipped) views=\(groupViews)"
    }

    func runToolbarProbe() {
        let out = URL(fileURLWithPath: "/tmp/daisy-probe", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var report: [String] = []
        func note(_ line: String) {
            report.append(line)
            try? report.joined(separator: "\n").write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        }
        func describe(_ view: NSView, _ depth: Int, into lines: inout [String]) {
            let name = String(describing: type(of: view))
            if !view.isHidden, view.frame.width > 0 {
                var extra = ""
                if let control = view as? NSSegmentedControl { extra = " segments=\(control.segmentCount)" }
                if let popup = view as? NSPopUpButton { extra = " popup='\(popup.titleOfSelectedItem ?? "")' items=\(popup.numberOfItems)" }
                if name.contains("Toolbar") || name.contains("Segmented") || name.contains("PopUp") || name.contains("Overflow") || !extra.isEmpty {
                    lines.append(String(repeating: " ", count: depth) + name + " x=\(Int(view.frame.minX)) w=\(Int(view.frame.width))" + extra)
                }
            }
            for sub in view.subviews { describe(sub, depth + 1, into: &lines) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            AppNavigation.shared.section = .settings
            try? await Task.sleep(for: .seconds(2))
            note("windows: " + NSApp.windows.map { "\(type(of: $0)) main=\($0.canBecomeMain) visible=\($0.isVisible) w=\(Int($0.frame.width))" }.joined(separator: "; "))
            guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else { note("no main window"); return }
            if !window.isVisible { window.makeKeyAndOrderFront(nil) }
            for width in [1710.0, 1300, 1065, 994, 900, 860, 1300, 1065] {
                var frame = window.frame
                frame.size.width = width
                window.setFrame(frame, display: true)
                try? await Task.sleep(for: .seconds(1.5))
                var lines: [String] = []
                if let toolbarView = window.contentView?.superview { describe(toolbarView, 0, into: &lines) }
                // Every platter in full: what is actually drawn there.
                func platters(_ v: NSView) -> [NSView] {
                    String(describing: type(of: v)) == "NSToolbarPlatterView" ? [v] : v.subviews.flatMap(platters)
                }
                func full(_ v: NSView, _ depth: Int, into lines: inout [String]) {
                    let role = v.accessibilityRole()?.rawValue ?? ""
                    let label = [v.accessibilityTitle(), v.accessibilityLabel(), (v.accessibilityValue() as? String)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "|")
                    lines.append(String(repeating: " ", count: depth) + "\(type(of: v)) x=\(Int(v.frame.minX)) w=\(Int(v.frame.width)) hidden=\(v.isHidden) alpha=\(v.alphaValue) \(role) \(label)")
                    for sub in v.subviews { full(sub, depth + 1, into: &lines) }
                }
                func tabControls(_ v: NSView) -> [String] {
                    var found: [String] = []
                    let name = String(describing: type(of: v))
                    if name.contains("Popup") || name.contains("PopUp") || name.contains("Segmented") {
                        let value = (v.accessibilityValue() as? String) ?? ""
                        let title = v.accessibilityTitle() ?? ""
                        let children = (v.accessibilityChildren() ?? []).count
                        found.append("TAB? \(name) w=\(Int(v.frame.width)) value='\(value)' title='\(title)' children=\(children)")
                    }
                    return found + v.subviews.flatMap(tabControls)
                }
                if let content = window.contentView { lines += tabControls(content) }
                // What sits in the top band of the page, below the toolbar.
                func band(_ v: NSView) -> [String] {
                    var found: [String] = []
                    let r = v.convert(v.bounds, to: nil)
                    let fromTop = window.contentLayoutRect.maxY - r.maxY
                    if fromTop > -10, fromTop < 90, r.minX > 150, r.width > 20, r.width < 900, !v.isHidden {
                        found.append("BAND \(type(of: v)) x=\(Int(r.minX)) top=\(Int(fromTop)) w=\(Int(r.width)) h=\(Int(r.height)) \(v.accessibilityRole()?.rawValue ?? "")")
                    }
                    return found + v.subviews.flatMap(band)
                }
                if let content = window.contentView { lines += band(content) }
                if let frameView = window.contentView?.superview {
                    for platter in platters(frameView) {
                        lines.append("-- platter")
                        full(platter, 1, into: &lines)
                    }
                }
                let items = window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
                let visible = window.toolbar?.visibleItems?.map(\.itemIdentifier.rawValue) ?? []
                note("== width \(Int(window.frame.width))\nitems: \(items)\nvisible: \(visible)\n" + tabsState(window) + "\n" + lines.joined(separator: "\n"))
                if let frameView = window.contentView?.superview,
                   let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                    frameView.cacheDisplay(in: frameView.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("w\(Int(width))-\(report.count).png"))
                }
            }
            // Picking a tab in the toolbar control turns the page, both
            // in the segments (wide) and in the pop-up (narrow).
            func pageHasConnections() -> Bool {
                func find(_ v: NSView) -> Bool {
                    if let c = v as? NSSegmentedControl, c.segmentCount == 2, (0..<2).contains(where: { c.label(forSegment: $0) == String(localized: "MCP server") || c.label(forSegment: $0)?.contains("MCP") == true }) { return true }
                    return v.subviews.contains(where: find)
                }
                return window.contentView.map(find) ?? false
            }
            func shownTabControl() -> NSControl? {
                var found: NSControl?
                func walk(_ v: NSView) {
                    if found == nil, !v.isHiddenOrHasHiddenAncestor {
                        if let c = v as? NSSegmentedControl, c.segmentCount == 6 { found = c }
                        if let p = v as? NSPopUpButton, p.numberOfItems >= 6 { found = p }
                    }
                    v.subviews.forEach(walk)
                }
                if let frame = window.contentView?.superview { walk(frame) }
                return found
            }
            for width in [1300.0, 900] {
                var frame = window.frame
                frame.size.width = width
                window.setFrame(frame, display: true)
                try? await Task.sleep(for: .seconds(1.5))
                guard let control = shownTabControl() else { note("PICK \(Int(width)): no tab control shown"); continue }
                if let seg = control as? NSSegmentedControl {
                    seg.selectedSegment = 5
                } else if let pop = control as? NSPopUpButton {
                    pop.selectItem(at: 5)
                }
                control.sendAction(control.action, to: control.target)
                try? await Task.sleep(for: .seconds(1))
                let r = control.convert(control.bounds, to: nil)
                let centre = Int(r.midX), windowCentre = Int(window.frame.width / 2)
                note("PICK \(Int(width)) via \(type(of: control)): connections page=\(pageHasConnections()) \(tabsState(window)) centre=\(centre) windowCentre=\(windowCentre)")
                // Back to General through the model, as a deep link would.
                AppNavigation.shared.pendingSettingsTab = .general
                try? await Task.sleep(for: .seconds(1))
                note("DEEPLINK general: \(tabsState(window)) connections page=\(pageHasConnections())")
            }
            for section in [MainSection.home, .settings, .library, .settings] {
                AppNavigation.shared.section = section
                try? await Task.sleep(for: .seconds(2))
                let ids = window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
                note("== section \(section): tabs items=\(ids.filter { $0.contains("settingsTabs") }.count) \(tabsState(window))")
            }
            note("done")
        }
    }
}
#endif
