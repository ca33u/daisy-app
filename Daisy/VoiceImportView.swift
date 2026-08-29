//
//  VoiceImportView.swift
//  Daisy
//
//  Seed the Voice Profile without waiting for the dictation corpus to
//  fill — for users arriving from another dictation app or who simply
//  have their own writing at hand. Two modes:
//    • Writing samples — paste / import .txt/.md of the user's OWN text;
//      feeds the same corpus the unlock bar tracks (may unlock at once).
//    • Style prompt — paste a ready-made style instruction (e.g. carried
//      over from another tool); installs the profile immediately.
//

import SwiftUI
import UniformTypeIdentifiers

struct VoiceImportView: View {
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case samples
        case instruction
        var id: String { rawValue }
    }

    @State private var mode: Mode
    // Each tab keeps its OWN text: pasting writing samples must not bleed
    // into the style-prompt field (or vice versa) — they're different
    // inputs (Egor 2026-07-22). Was a single shared `text`, which made
    // both tabs show the same content.
    @State private var samplesText: String
    @State private var instructionText: String
    @State private var showingFileImporter = false

    /// Which language bucket this import belongs to. Empty string = let
    /// the classifier decide for samples, or "no language of its own"
    /// for a style prompt — which is what a prompt carried over from
    /// another app actually is, so it becomes the universal profile.
    @State private var languageCode: String

    /// `initialText` pre-fills the editor (e.g. the current profile's style
    /// instruction, for editing/replacing); `startInStylePrompt` opens
    /// straight in the "Style prompt" tab and seeds THAT tab. Both default
    /// to fresh-import (empty). `initialLanguage` preselects the language
    /// (the Voice screen passes the language card the user came from).
    init(initialText: String = "", startInStylePrompt: Bool = false, initialLanguage: String? = nil) {
        _mode = State(initialValue: startInStylePrompt ? .instruction : .samples)
        _instructionText = State(initialValue: startInStylePrompt ? initialText : "")
        _samplesText = State(initialValue: startInStylePrompt ? "" : initialText)
        _languageCode = State(initialValue: initialLanguage ?? "")
    }

    /// The text field for the currently-selected tab.
    private var activeText: Binding<String> {
        mode == .samples ? $samplesText : $instructionText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up your Voice Profile")
                .font(.title3.weight(.semibold))

            // Same glass tab strip as the rest of the app (Dictation /
            // Connections / Settings) — a plain View, so it works inline in
            // this sheet too, not just in a window toolbar.
            GlassSegmentedControl(
                selection: $mode,
                segments: [
                    .init(value: .samples, title: String(localized: "My writing")),
                    .init(value: .instruction, title: String(localized: "Style prompt")),
                ]
            )

            Text(mode == .samples
                 ? "Paste your own writing — emails, posts, notes, or an export from another dictation app. Daisy learns your voice from it, same as from dictation."
                 : "Already have a style instruction from another tool? Paste it — Daisy will use it as your profile right away.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Which language this lands in. Nothing about a paste tells
            // us reliably on its own — an English signature at the end
            // of a Russian letter is enough to tip a detector — and this
            // is the one moment the user is here to say so.
            Picker(selection: $languageCode) {
                Text(mode == .samples ? "Detect automatically" : "Any language")
                    .tag("")
                ForEach(Transcriber.availableLocales.filter { $0.id != "auto" }, id: \.id) { locale in
                    Text(locale.label).tag(locale.id)
                }
            } label: {
                Text("Language")
            }
            .pickerStyle(.menu)
            .fixedSize()

            TextEditor(text: activeText)
                .font(.body)
                .frame(minHeight: 180)
                .padding(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.gray.opacity(0.25), lineWidth: 0.5)
                )

            HStack(spacing: 10) {
                if mode == .samples {
                    Button {
                        showingFileImporter = true
                    } label: {
                        Label("Import file…", systemImage: "doc")
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.daisyTextPrimary)
                    .controlSize(.small)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    // Neutral grey label (was the app's orange accent tint).
                    .tint(Color.daisyTextSecondary)
                Button(mode == .samples ? "Add to profile" : "Use as profile") {
                    apply()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                // Neutral prominent (was orange accent).
                .tint(Color.daisyTextPrimary)
                .disabled(activeText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        // 40pt taller than before to make room for the language row
        // without squeezing the editor.
        .frame(width: 480, height: 440)
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                ToastCenter.shared.show(String(localized: "Couldn't read that file."), style: .error)
                return
            }
            // Import only appears in the "My writing" tab → append there.
            samplesText = samplesText.isEmpty ? content : samplesText + "\n\n" + content
        }
    }

    private var saveFailedMessage: String {
        String(localized: "Daisy couldn’t save that to disk — check there’s free space and try again.")
    }

    private func apply() {
        let store = VoiceProfileStore.shared
        let chosen = languageCode.isEmpty ? nil : languageCode
        switch mode {
        case .samples:
            let result = store.importSamples(samplesText, language: chosen)
            if result.language == VoiceLanguage.undetermined {
                // The `und` bucket never generates a profile, so
                // "added 4 200 words" would be a promise we can't keep.
                // Say what actually happened and what to do about it.
                ToastCenter.shared.show(
                    String(localized: "Daisy couldn’t tell which language that is — pick one from the Language menu and add it again."),
                    style: .warning,
                    duration: .seconds(6)
                )
            } else if !result.persisted {
                ToastCenter.shared.show(saveFailedMessage, style: .error, duration: .seconds(6))
            } else if store.canGenerate(for: result.language) {
                // Per LANGUAGE: 60 Spanish words don't become "ready to
                // generate" just because Russian passed 300 long ago.
                ToastCenter.shared.show(
                    String(localized: "Added \(result.words) words — your Voice Profile is ready to generate."),
                    style: .success
                )
            } else {
                ToastCenter.shared.show(
                    String(localized: "Added \(result.words) words toward your Voice Profile."),
                    style: .success
                )
            }
        case .instruction:
            // Only claim it was installed if it reached disk — an empty
            // box, or a failed write, used to toast success anyway.
            if store.setCustomInstruction(instructionText, language: chosen) {
                ToastCenter.shared.show(
                    String(localized: "Style prompt installed — Daisy will polish in this voice."),
                    style: .success
                )
            } else if !instructionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ToastCenter.shared.show(saveFailedMessage, style: .error, duration: .seconds(6))
            }
        }
        dismiss()
    }
}
