//
//  WidgetBubble.swift
//  Daisy
//
//  A small callout anchored to the floating daisy widget — the one UI
//  surface that floats over every other app, so it can carry a prompt
//  the user needs to see while working somewhere else.
//
//  WHY THIS EXISTS AGAIN. A custom widget callout lived here once (the
//  "Are we done?" silence prompt) and was retired 2026-05-18 for a
//  native notification, because Apple handles positioning, dismissal,
//  reduced-motion and Focus for free. That trade was right for the
//  silence prompt — it isn't time-critical and reads fine as a banner.
//  It is WRONG for the screenshot-note and dictation-landed-nowhere
//  prompts: those are contextual and live for ~12 s ("hold your key
//  NOW"), and a banner that auto-dismisses into Notification Center is
//  easy to miss in exactly that window. The widget is always on screen,
//  over every app — a callout from it is immediate and unmissable.
//
//  Positioning is kept deliberately dumb (the maths is what got the last
//  one retired): the bubble is a plain rounded card, no tail, placed
//  above the widget with right edges aligned, then clamped whole into
//  the widget's screen. No arrow that has to know which side it's on.
//
//  ROUTING. `WidgetBubbleCenter.present` shows the bubble when the widget
//  is visible; when the widget is off or hidden there's nothing to anchor
//  to, so it falls back to a notification. Callers don't choose — they
//  state the prompt and the center picks the surface.
//

import SwiftUI
import UserNotifications

/// One callout: a line of text and, optionally, one action button.
struct WidgetBubbleContent: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var actionTitle: String?
    /// SF Symbol name — when set, the action renders as an icon-only
    /// button (`actionTitle` becomes its tooltip / accessibility label)
    /// instead of a text button. Used by the auto-start ask, whose pill
    /// is deliberately word-light.
    var actionSymbol: String?
    /// How long the bubble lives before auto-dismissing; visualised by
    /// the countdown ring around the close button.
    var autoDismiss: TimeInterval = 12
    /// Optional stable tag naming WHICH prompt this is
    /// ("autostart-ask", "silence-ask", …). Lets a caller withdraw its
    /// own bubble when the prompt becomes moot (speech resumed, trigger
    /// consumed) without ever tearing down someone else's — see
    /// `WidgetBubbleCenter.dismiss(tag:)`.
    var tag: String?
    /// Closure isn't Equatable — identity is the `id`, and a given
    /// content value is never mutated, so comparing ids is sufficient
    /// for SwiftUI's diffing.
    var action: (@MainActor () -> Void)?
    /// Tooltip for the destructive control below. Its presence is what
    /// puts the control on the pill.
    var destructiveTitle: String?
    /// A THIRD meaning, for pills that announce something Daisy just
    /// created. The pill already says two things: the body accepts, and
    /// the ✕ dismisses — and dismissing leaves the thing alone, which is
    /// right for a prompt and useless when the answer is "I didn't want
    /// that at all". This throws the thing away. Drawn as a trash glyph
    /// in the error colour, so it can't be read as another ✕.
    ///
    /// Not carried by the notification fallback: a banner has one action
    /// at most, and the one that DELETES is not the one to guess at.
    var destructiveAction: (@MainActor () -> Void)?

    static func == (lhs: WidgetBubbleContent, rhs: WidgetBubbleContent) -> Bool {
        lhs.id == rhs.id
    }
}

/// Routes a prompt to the widget bubble when the widget is on screen,
/// else to a notification. A tiny shared holder so singletons
/// (`ScreenshotNoteCapture`, `DictationPaste`) can reach the panel
/// without owning a reference to it — `FloatingPanelController` registers
/// itself here on init.
@MainActor
final class WidgetBubbleCenter {
    static let shared = WidgetBubbleCenter()
    private init() {}

    /// Set by `FloatingPanelController.init`. Weak so the center never
    /// keeps a torn-down panel alive.
    weak var host: (any WidgetBubbleHosting)?

    /// Set by the widget's SwiftUI layer (which owns an
    /// `@Environment(\.openWindow)` action — the only reliable way to
    /// RECREATE the main window scene once it's been closed). Bubble
    /// actions that end in "open Daisy" (morning brief) call this;
    /// AppKit-side fallbacks can only surface an existing window.
    var openMainWindow: (@MainActor () -> Void)?

    /// Tag of the most recently shown bubble — used by `dismiss(tag:)`
    /// to withdraw a prompt only when it's still the one on screen.
    private var lastShownTag: String?

    /// Show `content` on the best available surface. Since 2026-08-21
    /// the bubble no longer requires the widget to be VISIBLE — the
    /// panel anchors to the bottom-right corner when the widget is
    /// hidden — so the notification path is purely the "no panel host
    /// at all" fallback. On that fallback the bubble's action button
    /// can't come along, so a caller whose bubble HAS an action must
    /// pass a `notificationBody` that still makes sense without a
    /// button — otherwise a banner would ask "Keep it?" with no way to
    /// answer. When the bubble has no action, `notificationBody`
    /// defaults to the bubble text.
    func present(
        _ content: WidgetBubbleContent,
        notificationTitle: String,
        notificationBody: String? = nil
    ) {
        if !show(content) {
            postNotification(title: notificationTitle, body: notificationBody ?? content.text)
        }
    }

    /// Show the bubble if a panel host exists; `false` means the caller
    /// must surface its own fallback. For callers whose fallback is an
    /// ACTIONABLE banner (Record/Ignore, Stop & save/snooze) rather
    /// than `present`'s plain informational one.
    func show(_ content: WidgetBubbleContent) -> Bool {
        guard let host else { return false }
        lastShownTag = content.tag
        host.showBubble(content)
        return true
    }

    /// Withdraw a prompt that became moot (speech resumed, capture
    /// healthy again, trigger consumed) — but only if the bubble on
    /// screen is OURS. Tag-guarded so a stale cancel can never eat an
    /// unrelated prompt that replaced it.
    func dismiss(tag: String) {
        guard lastShownTag == tag else { return }
        lastShownTag = nil
        host?.hideBubble()
    }

    /// Freeze the countdown of OUR pill (tag-guarded, same contract as
    /// `dismiss`). Used while a dictation hold is answering the prompt.
    func pauseCountdown(tag: String) {
        guard lastShownTag == tag else { return }
        host?.pauseBubbleCountdown()
    }

    /// Restart the countdown of OUR pill from its full duration.
    func restartCountdown(tag: String) {
        guard lastShownTag == tag else { return }
        host?.restartBubbleCountdown()
    }

    // MARK: - Live dictation caption

    /// Wall-clock of the last caption push that reached the host — the
    /// throttle below is deliberately lossy (a dropped frame is replaced
    /// by the next result ~instantly; the pill is a preview, not a record).
    private var lastCaptionPush = Date.distantPast

    /// Stream the running dictation text onto the caption pill (a second,
    /// non-interactive panel one slot above the prompt bubble — the two
    /// never contend, see `FloatingPanelController.updateLiveCaption`).
    /// Unlike `present`, there is NO notification fallback: a stream of
    /// banners would be noise, and without a panel host there is simply
    /// no live preview — the dictation itself is unaffected.
    /// Throttled to ~10 Hz so a chatty engine can't spend the main
    /// thread on label layout.
    func updateLiveCaption(_ text: String) {
        guard let host else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCaptionPush) >= 0.1 else { return }
        lastCaptionPush = now
        host.updateLiveCaption(text)
    }

    /// Tear the caption down (dictation stopped, session discarded or
    /// failed). Idempotent — callers on every exit path may all fire.
    func hideLiveCaption() {
        lastCaptionPush = .distantPast
        host?.hideLiveCaption()
    }

    private func postNotification(title: String, body: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            Task { @MainActor in Self.addRequest(title: title, body: body) }
        }
    }

    /// Synchronous so the fire-and-forget `add` doesn't sit in an async
    /// context (which draws a "use the async alternative" warning) —
    /// matches the other notification posters.
    private static func addRequest(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Unique per post: these are distinct transient prompts (a
        // screenshot save, a dictation that landed nowhere) and one must
        // not replace another still sitting unread.
        let request = UNNotificationRequest(
            identifier: "app.essazanov.Daisy.widgetBubble." + UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

/// What the bubble center needs from the panel controller. A protocol so
/// `WidgetBubbleCenter` doesn't import the AppKit panel machinery and the
/// two can be reasoned about (and tested) apart.
@MainActor
protocol WidgetBubbleHosting: AnyObject {
    var isWidgetVisible: Bool { get }
    func showBubble(_ content: WidgetBubbleContent)
    func hideBubble()
    /// Freeze / restart the visible pill's countdown (ring + dismiss
    /// timer). Restart runs the FULL duration again, not the remainder.
    func pauseBubbleCountdown()
    func restartBubbleCountdown()
    /// Live dictation caption — a separate, non-interactive pill that
    /// updates in place as the person speaks. Distinct from the prompt
    /// bubble so a stream can never evict a prompt (or vice versa).
    func updateLiveCaption(_ text: String)
    func hideLiveCaption()
}

/// The bubble's content view. Mirrors `ToastView`'s look (elevated card,
/// hairline border, soft shadow) so the two feel like one design, but as
/// a rounded rect rather than a capsule since it wraps to two lines.
///
/// SUPERSEDED and unreferenced: `FloatingPanelController.showBubble` draws
/// the live pill in plain AppKit after this never painted inside a
/// borderless panel on macOS 27 (see that method's comment). Kept only as
/// the reference for what the pill is meant to look like — it does NOT
/// carry the destructive control, and anything added here reaches nobody.
struct WidgetBubbleView: View {
    let content: WidgetBubbleContent
    let onAction: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.daisyAccent)
            Text(content.text)
                .font(.callout)
                .foregroundStyle(Color.daisyTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            if let title = content.actionTitle {
                Button(action: onAction) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.daisyAccent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 300, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.daisyBgElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 14, x: 0, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // A tap anywhere that isn't the action button dismisses — same
        // affordance as the toast.
        .onTapGesture(perform: onDismiss)
    }
}
