//
//  ToastCenter.swift
//  Daisy
//
//  Tiny global feedback channel for the app. When a user clicks an
//  action that can't run (no transcript yet, missing API key, etc.),
//  the button shouldn't just sit there grayed — show a transient
//  message so the user understands why nothing happened.
//
//  Usage:
//      ToastCenter.shared.show("No transcript yet")
//      ToastCenter.shared.show("Notion token missing", style: .warning)
//
//  Apply once on the root view to get the bottom-anchored toast:
//      .modifier(ToastOverlay())
//

import SwiftUI

// MARK: - Center

@Observable
@MainActor
final class ToastCenter {
    static let shared = ToastCenter()

    var current: Toast?

    private var hideTask: Task<Void, Never>?

    func show(_ message: String, style: Toast.Style = .info, duration: Duration = .seconds(2.6)) {
        hideTask?.cancel()
        current = Toast(message: message, style: style, action: nil)
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.current = nil }
        }
    }

    /// Toast with a labelled action button. Tapping the action runs
    /// `perform()` and dismisses the toast. Tapping anywhere else on
    /// the toast just dismisses without running the action. Used for
    /// time-bounded "Daisy is about to do X — click to cancel"
    /// prompts (auto-stop on calendar end, etc.). Returns the toast's id
    /// so a caller can take down its own toast later — and only its own.
    @discardableResult
    func showAction(
        _ message: String,
        actionLabel: String,
        style: Toast.Style = .info,
        duration: Duration = .seconds(30),
        perform: @escaping @MainActor () -> Void
    ) -> UUID {
        hideTask?.cancel()
        let toastID = UUID()
        let action = Toast.Action(label: actionLabel) { [weak self] in
            perform()
            if self?.current?.id == toastID {
                self?.current = nil
            }
        }
        current = Toast(id: toastID, message: message, style: style, action: action)
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if self?.current?.id == toastID {
                    self?.current = nil
                }
            }
        }
        return toastID
    }

    func dismiss() {
        hideTask?.cancel()
        current = nil
    }

    /// Take down toast `id` if it is still the one on screen; a toast
    /// that has since replaced it stays.
    func dismiss(id: UUID) {
        guard current?.id == id else { return }
        dismiss()
    }

    private init() {}
}

// MARK: - Value

struct Toast: Identifiable {
    let id: UUID
    let message: String
    let style: Style
    let action: Action?

    init(id: UUID = UUID(), message: String, style: Style, action: Action? = nil) {
        self.id = id
        self.message = message
        self.style = style
        self.action = action
    }

    enum Style {
        case info       // default — daisyAccent
        case success    // sage
        case warning    // gold
        case error      // red
    }

    /// Inline action button. The closure runs on the main actor when
    /// the user taps the button; tapping anywhere else on the toast
    /// just dismisses (no `perform()` call).
    struct Action {
        let label: String
        let perform: @MainActor () -> Void
    }
}

extension Toast: Equatable {
    // Closures aren't Equatable; compare by id, which is enough for
    // SwiftUI animation key tracking (each toast emit gets a fresh id).
    static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
}

// MARK: - Overlay modifier

struct ToastOverlay: ViewModifier {
    @Bindable private var center = ToastCenter.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = center.current {
                ToastView(toast: toast)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: center.current)
    }
}

private struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.callout.weight(.medium))
                .foregroundStyle(iconColor)
            Text(toast.message)
                .font(.callout)
                .foregroundStyle(Color.daisyTextPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let action = toast.action {
                Button {
                    action.perform()
                } label: {
                    Text(action.label)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.daisyAccent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(Color.daisyBgElevated)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 4)
        .onTapGesture { ToastCenter.shared.dismiss() }
    }

    private var icon: String {
        switch toast.style {
        case .info:     return "info.circle.fill"
        case .success:  return "checkmark.circle.fill"
        case .warning:  return "exclamationmark.triangle.fill"
        case .error:    return "xmark.octagon.fill"
        }
    }

    private var iconColor: Color {
        switch toast.style {
        case .info:     return Color.daisyAccent
        case .success:  return Color.daisySuccess
        case .warning:  return Color.daisyWarning
        case .error:    return Color.daisyError
        }
    }
}
