// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  LayoutFixConflicts.swift
//  Daisy
//
//  Refuses to run the automatic layout fixer while ANOTHER layout
//  switcher is running.
//
//  Why this file exists. Two layout switchers on one keyboard is not
//  "both features work" — it is one word converted twice. Caramba (or
//  Punto) flips «ghbdtn» to «привет» as it is typed; our tap then sees a
//  word that is now perfectly good Russian and, on a bad day, judges it
//  the other way. The user gets garbage they never typed, from a feature
//  that is supposed to be conservative, and cannot tell which app did
//  it. Refusing is the only honest answer, and the person already has a
//  layout switcher they chose — theirs wins.
//
//  DETECTION IS DELIBERATELY NARROW. The generic way to find a rival is
//  `CGGetEventTapList`: every ACTIVE keyboard tap on the system, ours
//  included. But an active keyboard tap is also how text expanders,
//  launchers, and macro tools work — Raycast, Alfred, Keyboard Maestro,
//  TextExpander. Refusing on "somebody else taps the keyboard" would
//  turn the feature off for exactly the people who install this kind of
//  software, and they are our users. So the refusal list is the two
//  programs whose whole job is the same as this feature's, and the tap
//  list is only ever LOGGED — because "it does nothing" was the entire
//  content of the first bug report about this feature, and a rival tap
//  is a plausible cause that is otherwise invisible from a log.
//
//  Adding to the list is cheap; guessing is not. An app that gets this
//  wrong disables a feature the user turned on, silently. Every entry
//  here is a program that auto-converts mistyped words, verified by
//  bundle identifier.
//

import AppKit
import CoreGraphics
import os

@MainActor
enum LayoutFixConflicts {

    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "LayoutFix")

    /// Programs that do automatic layout conversion themselves.
    ///
    /// `tech.caramba.switcher` — Caramba Switcher, by the author of
    /// Punto Switcher; the one people actually run on macOS today.
    /// `ru.yandex.puntoswitcher` — Punto Switcher for Mac. Yandex
    /// stopped shipping it, but an installed copy still types.
    /// `nonisolated`: read from the launch observer's `@Sendable`
    /// closure, which runs on the main queue but isn't main-actor-
    /// isolated. It's immutable data — safe from anywhere.
    nonisolated private static let switcherBundleIDs: Set<String> = [
        "tech.caramba.switcher",
        "ru.yandex.puntoswitcher",
    ]

    /// The running layout switcher, if there is one — its display name,
    /// for a message that names the app instead of hinting at it.
    static func runningSwitcherName() -> String? {
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, switcherBundleIDs.contains(id) else { continue }
            return app.localizedName ?? id
        }
        return nil
    }

    /// True when this bundle id is one of the rivals. `nonisolated` so
    /// the launch observer can filter inside its `@Sendable` closure,
    /// passing only the Sendable `String` across the actor hop rather
    /// than the non-Sendable `NSRunningApplication`.
    nonisolated static func isSwitcher(bundleID: String) -> Bool {
        switcherBundleIDs.contains(bundleID)
    }

    /// Log every OTHER process holding an active keyboard tap. Purely
    /// diagnostic: these are not refused (see the note at the top), but
    /// when a user reports the fixer doing nothing in some app, this is
    /// the line that says somebody else is holding the keyboard.
    ///
    /// Names only, never events. `CGGetEventTapList` exposes what is
    /// tapped, not what is typed.
    ///
    /// WHY THESE NAMES ARE LOGGED WHEN THE EXCLUSION LIST'S ARE NOT.
    /// LayoutAutoFix refuses to log which app a fix was skipped in, and
    /// that rule is not being bent here. What it protects is where the
    /// user was TYPING at a moment in time — their password manager,
    /// their therapist's web app — written per word, into a file they
    /// may email us. This line is a once-per-start inventory of software
    /// that has installed a keyboard tap: a property of the machine, not
    /// of a moment, in the same register as the `Bundle:` and `Route:`
    /// lines the report already carries. Different fact, different
    /// answer — and without it "nothing happens" has no visible cause at
    /// all.
    static func logOtherKeyboardTaps() {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success else { return }

        let mine = ProcessInfo.processInfo.processIdentifier
        let keyDownMask = CGEventMask(1) << CGEventType.keyDown.rawValue
        var names: [String] = []
        for tap in taps.prefix(Int(count)) {
            guard tap.enabled,
                  tap.options == .defaultTap,           // active: it can rewrite events
                  tap.eventsOfInterest & keyDownMask != 0,
                  pid_t(tap.tappingProcess) != mine else { continue }
            let app = NSRunningApplication(processIdentifier: pid_t(tap.tappingProcess))
            names.append(app?.localizedName ?? app?.bundleIdentifier ?? "pid \(tap.tappingProcess)")
        }
        guard !names.isEmpty else { return }
        log.info("Other active keyboard taps present: \(names.joined(separator: ", "), privacy: .public)")
    }
}
