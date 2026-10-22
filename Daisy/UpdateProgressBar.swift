//
//  UpdateProgressBar.swift
//  Daisy
//
//  Sparkle's update window draws its progress bar in the app's accent
//  colour, and Daisy's accent (Assets → AccentColor) is a near-white grey
//  that matches the sidebar selection — so the download bar was white on
//  light grey and nobody could see it move (Egor 22.10). Rather than
//  repaint every control in the app, an orange bar of Daisy's own is laid
//  over Sparkle's, bound to that window's progress.
//
//  Sparkle's window is found by its controller's class name and its
//  `progressValue` / `maxProgressValue` are read by key (both KVO
//  properties behind the window's bindings, Sparkle 2.9). If a later
//  Sparkle changes either, nothing is laid over and its own bar stays.
//

import AppKit
import SwiftUI

@MainActor
enum UpdateProgressBar {
    private static var observers: [NSObjectProtocol] = []
    private static let marker = NSUserInterfaceItemIdentifier("daisy.updateProgressBar")

    /// Watches for Sparkle's status window — shown for a check, a
    /// download, unpacking and «Ready to Install». Visible, not key: it
    /// can come up behind another app.
    static func install() {
        guard observers.isEmpty else { return }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { attach(to: window) }
            })
        }
    }

    static func attach(to window: NSWindow) {
        // Sparkle's status nib names its window «SUStatus». The class name
        // is the fallback, and only as a suffix: the nib's bindings make
        // KVO subclass the controller (`NSKVONotifying_SUStatusController`).
        guard let controller = window.windowController,
              window.identifier?.rawValue == "SUStatus"
                || NSStringFromClass(type(of: controller)).hasSuffix("SUStatusController"),
              controller.responds(to: NSSelectorFromString("progressValue")),
              controller.responds(to: NSSelectorFromString("maxProgressValue")),
              let bar = window.contentView.flatMap(progressIndicator(in:)),
              let container = bar.superview,
              !container.subviews.contains(where: { $0.identifier == marker }) else { return }
        let progress = SparkleProgress(controller: controller)
        let host = NSHostingView(rootView: OrangeProgressBar(progress: progress))
        host.identifier = marker
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host, positioned: .above, relativeTo: bar)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            host.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            host.heightAnchor.constraint(equalToConstant: 6),
        ])
        // Kept in place for layout and VoiceOver, just not drawn.
        bar.alphaValue = 0
    }

    private static func progressIndicator(in view: NSView) -> NSProgressIndicator? {
        if let bar = view as? NSProgressIndicator, bar.style == .bar { return bar }
        for sub in view.subviews { if let found = progressIndicator(in: sub) { return found } }
        return nil
    }
}

/// Sparkle's progress, observed by key. `maxProgressValue == 0` is
/// Sparkle's indeterminate state (checking, unpacking).
@Observable
@MainActor
final class SparkleProgress: NSObject {
    private(set) var value: Double = 0
    private(set) var max: Double = 0
    @ObservationIgnored private weak var controller: NSObject?
    private static let keys = ["progressValue", "maxProgressValue"]

    init(controller: NSObject) {
        self.controller = controller
        super.init()
        for key in Self.keys { controller.addObserver(self, forKeyPath: key, options: [.initial, .new], context: nil) }
    }

    isolated deinit {
        for key in Self.keys { controller?.removeObserver(self, forKeyPath: key) }
    }

    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        MainActor.assumeIsolated {
            guard let controller else { return }
            value = (controller.value(forKey: "progressValue") as? Double) ?? 0
            max = (controller.value(forKey: "maxProgressValue") as? Double) ?? 0
        }
    }

    var fraction: Double? { max > 0 ? Swift.min(1, Swift.max(0, value / max)) : nil }
}

private struct OrangeProgressBar: View {
    let progress: SparkleProgress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // A track that stands out from the window itself, which the
                // divider colour doesn't.
                Capsule().fill(Color.primary.opacity(0.12))
                if let fraction = progress.fraction {
                    Capsule()
                        .fill(Color.daisyUpdateAccent)
                        .frame(width: Swift.max(6, geo.size.width * fraction))
                        .animation(.easeOut(duration: 0.2), value: fraction)
                } else {
                    // Indeterminate: a segment running across, as Sparkle's own bar does.
                    // 30 fps is plenty; a feed without a size keeps this up for the whole download.
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                        let phase = reduceMotion ? 0.35 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                        let width = geo.size.width * 0.3
                        Capsule()
                            .fill(Color.daisyUpdateAccent)
                            .frame(width: width)
                            .offset(x: (geo.size.width + width) * phase - width)
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .accessibilityHidden(true)
    }
}
