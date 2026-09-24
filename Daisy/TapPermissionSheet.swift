//
//  TapPermissionSheet.swift
//  Daisy
//
//  Review 24.09: macOS asks for "System Audio Recording Only" the first
//  time a process tap starts. Asked here, once, before any call — not by
//  a system dialog in the middle of the first meeting after the update.
//

import SwiftUI

struct TapPermissionSheet: View {
    @Environment(\.dismiss) private var dismiss

    private enum Step { case explain, asking, granted, denied }
    @State private var step: Step = .explain
    @State private var answered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Daisy now asks for sound only")
                .font(.title2.bold())
            switch step {
            case .explain:
                Text("To hear the other side of a call, Daisy will use System Audio Recording — sound only, without the screen. It also keeps working when you listen in Bluetooth headphones.")
                Text("macOS asks once. Answer now, so the question doesn’t come up in the middle of your next call.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Not now") { dismiss() }
                    Spacer()
                    Button("Continue") { Task { await ask() } }
                        .keyboardShortcut(.defaultAction)
                }
            case .asking:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Answer the macOS dialog…")
                }
                HStack {
                    Spacer()
                    Button("I’ve answered") { answered = true }
                }
            case .granted:
                Label("Allowed. Daisy will hear the other side through sound alone.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.daisySuccess)
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            case .denied:
                Text("Not allowed — Daisy keeps using Screen Recording, as before. You can allow it later in System Settings → Privacy & Security → System Audio Recording.")
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(24)
        .frame(width: 440)
        .interactiveDismissDisabled(step == .asking)
    }

    private func ask() async {
        step = .asking
        answered = false
        // Listen until the tone comes through (allowed) or the person says
        // they answered; a refusal never makes a sound to wait for.
        let result = await ProcessTapPermission.probe(timeout: .seconds(90)) {
            answered
        }
        // "I've answered" may land a moment before the first buffers do.
        let final: ProcessTapPermission.Outcome
        if result == .denied, answered {
            final = await ProcessTapPermission.probe(timeout: .seconds(1.5))
        } else {
            final = result
        }
        ProcessTapPermission.record(final)
        step = final == .granted ? .granted : .denied
    }
}
