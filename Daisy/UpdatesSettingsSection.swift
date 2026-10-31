//
//  UpdatesSettingsSection.swift
//  Daisy
//
//  «Updates» on Settings → General: automatic update with a manual
//  check beside it, the beta channel, and «What's New in Daisy» again.
//  Moved from About in the Settings restructure (S3, Egor 24.10.2026) —
//  About keeps only what the app is, Settings what it does.
//

import SwiftUI

struct UpdatesSettingsSection: View {
    @Bindable private var updater = SparkleUpdater.shared

    var body: some View {
        Section {
            // The auto-check switch plus a manual "Check for Updates…"
            // (same action as the App menu).
            LabeledContent {
                HStack(spacing: 8) {
                    Button(updater.checkOrInstallTitle) {
                        updater.checkOrInstall()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.daisyTextPrimary)
                    .disabled(!updater.canCheckOrInstall)

                    Toggle("", isOn: $updater.automaticallyChecksForUpdates)
                        .labelsHidden()
                        // Nested in LabeledContent/HStack it loses the
                        // Form-row context and defaults to .checkbox —
                        // force .switch to match "Get beta updates" below.
                        .toggleStyle(.switch)
                }
            } label: {
                Text("Automatic update")
            }
            .settingsRow(.autoUpdate)

            Toggle("Get beta updates", isOn: $updater.receiveBetaUpdates)
                .settingsRow(.betaChannel)

            // The window that opened after the last update (Egor 23.10);
            // the sheet itself hangs off the main window (WhatsNew.swift),
            // which comes up over Settings to show it.
            LabeledContent("What’s New in Daisy") {
                Button("Open") {
                    AppNavigation.shared.showsWhatsNew = true
                    AppNavigation.shared.showMainWindow()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.daisyTextPrimary)
            }
            .settingsRow(.whatsNew)
        } header: {
            Text("Updates")
        }
    }
}
