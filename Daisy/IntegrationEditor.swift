// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  IntegrationEditor.swift
//  Daisy
//
//  Modal editor for one MCPIntegration. Opened from Settings →
//  Auto-actions for both new and existing integrations.
//
//  Validates: name + URL + toolName all non-empty; URL parses to a
//  scheme-bearing URL; arguments template parses as JSON. Errors
//  surface inline next to the offending field rather than blocking
//  Save.
//

import SwiftUI

struct IntegrationEditor: View {
    let initial: MCPIntegration
    let onSave: (MCPIntegration) -> Void
    let onCancel: () -> Void

    @State private var draft: MCPIntegration
    @State private var templateError: String?

    init(initial: MCPIntegration, onSave: @escaping (MCPIntegration) -> Void, onCancel: @escaping () -> Void) {
        self.initial = initial
        self.onSave = onSave
        self.onCancel = onCancel
        self._draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header was a paperplane icon + "New integration / Push
            // finished sessions into an MCP-compatible service"
            // subhead — removed in 1.0.5.4. macOS sheets already
            // carry a visual frame and the form fields make their
            // purpose obvious; the header just ate vertical space.
            ScrollView {
                form
                    .padding(20)
            }
            Divider()
            footer
        }
        .background(Color.daisyBgPrimary)
        .onChange(of: draft.argumentsTemplate) { _, _ in
            validateTemplate()
        }
        .onAppear { validateTemplate() }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { onSave(draft) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
        }
        .padding(16)
    }

    // MARK: - Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            field(
                title: String(localized: "Name"),
                hint: String(localized: "Shown in the kebab menu as `Send to {Name}`."),
                control: TextField("Notion · Meeting notes", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            )

            field(
                title: String(localized: "Kind"),
                hint: draft.kind == .mcp
                    ? String(localized: "MCP — full JSON-RPC client, tool-name and arguments template required.")
                    : String(localized: "Webhook — Daisy POSTs the rendered template directly to the URL as JSON. No tool name needed."),
                // pickerStyle(.menu) instead of .segmented: macOS 26.2
                // ships an Apple-side UAF in the Swift concurrency ↔ AppKit
                // bridge that crashes any SwiftUI Picker(.segmented) on
                // layout (it routes through SystemSegmentedControl, an
                // NSSegmentedControl wrapper — same UAF family as the
                // NavigationSplitView sidebar toggle we removed in
                // build 33). 2 options fit the menu naturally in this
                // dense form row. Restore .segmented post-26.x once
                // Apple ships the fix.
                control: Picker("", selection: $draft.kind) {
                    ForEach(DestinationKind.allCases, id: \.self) { kind in
                        Text(kind == .mcp ? "MCP server" : "Webhook").tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            )

            field(
                title: draft.kind == .mcp ? String(localized: "Server URL") : String(localized: "Webhook URL"),
                hint: draft.kind == .mcp
                    ? String(localized: "HTTP+SSE base URL of your MCP server. Daisy appends `/sse` to open the stream.")
                    : String(localized: "Daisy POSTs the rendered template body to this URL (Slack-style incoming webhook works out of the box)."),
                control: TextField(
                    draft.kind == .mcp
                        ? "http://127.0.0.1:11436"
                        : "https://hooks.slack.com/services/…",
                    text: $draft.baseURL
                )
                    .textFieldStyle(.roundedBorder)
            )

            if draft.kind == .mcp {
                field(
                    title: String(localized: "Tool name"),
                    hint: String(localized: "Exact name of the tool to call. Check your server's `tools/list` output."),
                    control: TextField("create_page", text: $draft.toolName)
                        .textFieldStyle(.roundedBorder)
                )
            } else {
                // Webhook-only: Bearer token for APIs that need it
                // (Attio, Linear REST, most SaaS). Leave empty for
                // Slack / Discord / Mattermost incoming webhooks —
                // they treat the URL itself as the credential.
                field(
                    title: String(localized: "Bearer token (optional)"),
                    hint: String(localized: "If your endpoint needs Authorization. Leave blank for Slack-style webhooks where the URL is the secret."),
                    control: SecureField("", text: $draft.bearerToken, prompt: Text("token…"))
                        .textFieldStyle(.roundedBorder)
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(draft.kind == .mcp ? "Arguments template" : "Body template")
                    .font(.callout.weight(.medium))
                TextEditor(text: $draft.argumentsTemplate)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 200)
                    .padding(6)
                    .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(templateError == nil ? Color.daisyDivider : Color.daisyError, lineWidth: 0.5)
                    )
                if let err = templateError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(Color.daisyError)
                        .fixedSize(horizontal: false, vertical: true)
                }
                placeholdersHelp
            }

            HStack {
                Toggle("Enabled", isOn: $draft.enabled)
                    .toggleStyle(.switch)
                Spacer()
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Auto-send when session finishes", isOn: $draft.autoOnSave)
                        .toggleStyle(.switch)
                        .disabled(!draft.enabled)
                    Text("Every finished session fires this destination automatically — no kebab click required. Still appears in the manual Send-to menu either way.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            if draft.autoOnSave {
                // Folder allow-list — empty = every folder (simple
                // default). Non-empty restricts auto-send to just
                // those folders, so a "Notes"-folder voice memo
                // doesn't get pushed to a "Work" destination.
                folderAllowListPicker(
                    title: String(localized: "Only auto-send for projects"),
                    selection: $draft.allowedFolders
                )
            }
        }
    }

    @ViewBuilder
    private func folderAllowListPicker(
        title: String,
        selection: Binding<Set<String>>
    ) -> some View {
        let folders = FolderStore.shared.allFolders
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout.weight(.medium))
            Menu {
                Button {
                    selection.wrappedValue = []
                } label: {
                    if selection.wrappedValue.isEmpty {
                        Label("All folders", systemImage: "checkmark")
                    } else {
                        Text("All projects")
                    }
                }
                Divider()
                ForEach(folders) { folder in
                    Button {
                        var current = selection.wrappedValue
                        if current.contains(folder.slug) {
                            current.remove(folder.slug)
                        } else {
                            current.insert(folder.slug)
                        }
                        selection.wrappedValue = current
                    } label: {
                        if selection.wrappedValue.contains(folder.slug) {
                            Label(folder.name, systemImage: "checkmark")
                        } else {
                            Text(folder.name)
                        }
                    }
                }
            } label: {
                Text(folderSummary(selection.wrappedValue, allFolders: folders))
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            Text("Empty = fire for every folder. Pick specific ones to limit auto-send to those contexts (e.g. only \"Work\" recordings go to Linear).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func folderSummary(_ slugs: Set<String>, allFolders: [SessionFolder]) -> String {
        if slugs.isEmpty { return "All folders" }
        let names = allFolders.filter { slugs.contains($0.slug) }.map(\.name)
        if names.count <= 3 { return names.joined(separator: ", ") }
        return "\(names.count) folders"
    }

    private func field<Control: View>(
        title: String,
        hint: String,
        control: Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout.weight(.medium))
            control
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Inline reference of the placeholders MCPDispatcher knows
    /// about. The list is duplicated here in display form; the
    /// authoritative table lives in MCPDispatcher.makePlaceholders.
    private var placeholdersHelp: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Placeholders")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text("`{{title}}`, `{{date}}` (ISO-8601), `{{summary}}`, `{{actionItems}}` (joined with `; `), `{{actionItemsBullets}}` (one per line, leading `- `), `{{clientFollowUp}}`, `{{transcript}}`, `{{folder}}`, `{{locale}}`. All values are JSON-escaped before substitution.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Validation

    private var isValid: Bool {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty,
              URL(string: draft.baseURL)?.scheme != nil,
              templateError == nil
        else { return false }
        // Tool name is required only for MCP transport — webhooks
        // have no tool concept, the body goes straight to the URL.
        if draft.kind == .mcp {
            return !draft.toolName.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    /// Validate the template by running a placeholder substitution
    /// with empty strings and trying to JSON-parse the result. We
    /// don't substitute real values because users haven't sent a
    /// session through it yet — we just want syntax validity.
    private func validateTemplate() {
        let probe = Self.replaceAllPlaceholders(in: draft.argumentsTemplate, with: "")
        guard let data = probe.data(using: .utf8) else {
            templateError = String(localized: "Template isn't valid UTF-8.")
            return
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [])
            templateError = nil
        } catch {
            templateError = String(localized: "Template isn't valid JSON: \(error.localizedDescription)")
        }
    }

    private static let placeholderKeys = [
        "{{actionItemsBullets}}",
        "{{clientFollowUp}}",
        "{{actionItems}}",
        "{{transcript}}",
        "{{summary}}",
        "{{folder}}",
        "{{locale}}",
        "{{title}}",
        "{{date}}",
    ]

    private static func replaceAllPlaceholders(in template: String, with value: String) -> String {
        var t = template
        for key in placeholderKeys {
            t = t.replacingOccurrences(of: key, with: value)
        }
        return t
    }
}
