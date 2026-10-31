//
//  DaisyAppDelegate+ToolbarProbe.swift
//  Daisy
//
//  DEBUG only. A check of the window toolbar that needs neither the
//  screen nor anyone's clicks (25.09): the app opens Dictation, sets its
//  own window to several widths and writes what the toolbar holds at
//  each to /tmp/daisy-probe/. (The Settings half of it went with the
//  Settings tabs, which left the toolbar for the Settings window's
//  sidebar on 31.10.2026.)
//
//    -daisy.debugToolbarProbe 1
//

#if DEBUG
import AppKit

extension DaisyAppDelegate {
    /// `-daisy.debugToolbarProbe 1`: Dictation's toolbar tabs at several
    /// window widths and across tab picks. Output: /tmp/daisy-probe/.
    func runToolbarProbe() {
        let out = URL(fileURLWithPath: "/tmp/daisy-probe", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var report: [String] = []
        func note(_ line: String) {
            report.append(line)
            try? report.joined(separator: "\n").write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            // Dictation: its own buttons follow its tab, so SwiftUI rebuilds
            // the toolbar on every switch — the tabs must stay.
            AppNavigation.shared.section = .dictation
            try? await Task.sleep(for: .seconds(2))
            guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else { note("no main window"); return }
            if !window.isVisible { window.makeKeyAndOrderFront(nil) }
            for width in [1300.0, 900] {
                var frame = window.frame
                frame.size.width = width
                window.setFrame(frame, display: true)
                try? await Task.sleep(for: .seconds(1.5))
                let visible = window.toolbar?.visibleItems?.contains { $0.itemIdentifier.rawValue == "app.essazanov.Daisy.dictationTabs" } ?? false
                var kinds: [String] = []
                @MainActor func walk(_ v: NSView, inToolbar: Bool) {
                    let here = inToolbar || String(describing: type(of: v)) == "NSToolbarView"
                    if here, !v.isHiddenOrHasHiddenAncestor {
                        let name = String(describing: type(of: v))
                        if v is NSSegmentedControl || v is NSPopUpButton || name.contains("ItemGroup") || name.contains("Clipped") {
                            kinds.append("\(name)\((v as? NSSegmentedControl).map { " seg=\($0.segmentCount)" } ?? "")\((v as? NSPopUpButton).map { " items=\($0.numberOfItems)" } ?? "") w=\(Int(v.frame.width))")
                        }
                    }
                    v.subviews.forEach { walk($0, inToolbar: here) }
                }
                if let root = window.contentView?.superview { walk(root, inToolbar: false) }
                note("DICTATION at \(Int(window.frame.width)): visible=\(visible) toolbar controls=\(kinds)")
            }
            var dictationWide = window.frame
            dictationWide.size.width = 1300
            window.setFrame(dictationWide, display: true)
            try? await Task.sleep(for: .seconds(1.5))
            @MainActor func dictationTabs() -> NSToolbarItemGroup? {
                window.toolbar?.items.first { $0.itemIdentifier.rawValue == "app.essazanov.Daisy.dictationTabs" } as? NSToolbarItemGroup
            }
            @MainActor func others() -> [String] {
                (window.toolbar?.items ?? []).compactMap { item in
                    guard !item.itemIdentifier.rawValue.hasPrefix("NSToolbar"), !item.itemIdentifier.rawValue.hasPrefix("com.apple"),
                          !item.itemIdentifier.rawValue.hasPrefix("app.essazanov") else { return nil }
                    return item.itemIdentifier.rawValue.prefix(8) + ""
                }
            }
            note("DICTATION start: tabs=\(dictationTabs().map { "selected \($0.selectedIndex)" } ?? "missing") other items=\(others().count)")
            for index in [1, 0, 1, 0] {
                // The two-tab control, looked for in the toolbar only.
                var control: NSControl?
                @MainActor func walk(_ v: NSView, inToolbar: Bool) {
                    let here = inToolbar || String(describing: type(of: v)) == "NSToolbarView"
                    if here, control == nil, !v.isHiddenOrHasHiddenAncestor {
                        if let c = v as? NSSegmentedControl, c.segmentCount == 2 { control = c }
                        if let p = v as? NSPopUpButton, p.numberOfItems == 2 { control = p }
                    }
                    v.subviews.forEach { walk($0, inToolbar: here) }
                }
                if let frame = window.contentView?.superview { walk(frame, inToolbar: false) }
                if let seg = control as? NSSegmentedControl { seg.selectedSegment = index } else if let pop = control as? NSPopUpButton { pop.selectItem(at: index) }
                if let control { control.sendAction(control.action, to: control.target) }
                try? await Task.sleep(for: .seconds(1.5))
                note("DICTATION pick \(index) via \(control.map { String(describing: type(of: $0)) } ?? "nothing"): tabs=\(dictationTabs().map { "selected \($0.selectedIndex)" } ?? "missing") other items=\(others().count)")
            }
            AppNavigation.shared.section = .home
            try? await Task.sleep(for: .seconds(2))
            note("DICTATION left: dictation tabs=\(dictationTabs() == nil ? "gone" : "still there")")
            note("done")
        }
    }
}
#endif
