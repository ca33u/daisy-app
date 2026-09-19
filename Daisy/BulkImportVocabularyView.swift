//
//  BulkImportVocabularyView.swift
//  Daisy
//
//  Bulk-add rows to the dictation vocabulary — paste a list or import a
//  .txt/.csv. One entry per line: a line with a separator (`=>`, `→`,
//  tab, or comma) becomes a correction `wrong → right`; a bare word/phrase
//  becomes a term (canonical spelling Daisy preserves/biases toward).
//

import SwiftUI
import UniformTypeIdentifiers

struct BulkImportVocabularyView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var showingFileImporter = false

    /// Live-parsed entries from the current text — drives the count + the
    /// Import button's enabled state.
    private var parsed: [DictationReplacement] {
        DictationDictionary.parseImport(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bulk import vocabulary")
                .font(.title3.weight(.semibold))

            Text("One per line. Add a separator for a correction; a bare word is a term.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .padding(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.gray.opacity(0.25), lineWidth: 0.5)
                )
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Acme\nClaude\nkubernetes => Kubernetes\nmy sql, MySQL")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 10) {
                Button {
                    showingFileImporter = true
                } label: {
                    Label("Import file…", systemImage: "doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Text(parsed.isEmpty ? " " : "\(parsed.count) to add")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Import") { runImport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.daisyPrimary)
                    .disabled(parsed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480, height: 440)
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.plainText, .commaSeparatedText, .text],
            allowsMultipleSelection: false
        ) { result in
            handleFile(result)
        }
    }

    private func runImport() {
        let added = DictationDictionary.shared.importEntries(parsed)
        ToastCenter.shared.show(
            added == 1
                ? String(localized: "Added 1 word to your vocabulary.")
                : String(localized: "Added \(added) words to your vocabulary."),
            style: .success
        )
        dismiss()
    }

    private func handleFile(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            ToastCenter.shared.show(String(localized: "Couldn't read that file."), style: .error)
            return
        }
        // Append (so the user can review/edit before importing) rather than
        // import straight from disk.
        text = text.isEmpty ? content : text + "\n" + content
    }
}
