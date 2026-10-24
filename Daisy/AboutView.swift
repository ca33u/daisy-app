//
//  AboutView.swift
//  Daisy
//
//  Standalone About page shown from the sidebar (Home / History /
//  Settings / About). Previously this lived as a tab inside
//  SettingsView; promoted out so users find studio / contact /
//  license info in one obvious place instead of buried five clicks
//  deep in preferences.
//
//  Content mirrors the in-app About tab that existed before — brand
//  block, links, studio note. 2026-06-13: rebuilt onto the SAME
//  grouped-Form surface the rest of Settings uses (DictationView /
//  SettingsView: `Form { Section … } .formStyle(.grouped)
//  .scrollContentBackground(.hidden) .background(.daisyBgPrimary)`).
//  The earlier ScrollView + custom RoundedRectangle(daisyBgSidebar)
//  cards diverged from every other detail pane — different card
//  colour, grid, and insets. Switching to Form makes About's section
//  cards, colours, and row rhythm identical to Settings/Dictation.
//  The brand block sits borderless ABOVE the Form (a title header,
//  not a boxed card) so the 56pt logo keeps room to breathe.
//
//  2026-10-24 (Settings restructure S3, Egor): About is only about the
//  app now — version, What's New, the tour, links, licenses, the studio.
//  Updates went to Settings → General; crash reports, «Help improve
//  Daisy» and the logs to Settings → Privacy. No switches live here.
//

import AppKit
import SwiftUI

struct AboutView: View {
    let settings: AppSettings

    var body: some View {
        Form {
            // Ko-fi sits above everything else (Egor, 2026-08-31): Daisy
            // is free and open source, and the donation link is the one
            // row we actually want a visitor of this page to notice.
            // Reuses the standard link-row idiom — no special styling, a
            // plain top-of-page section is emphasis enough.
            Section {
                aboutLinkRow(
                    icon: "cup.and.saucer",
                    title: "Buy me a coffee",
                    detail: "ko-fi.com/ca33u",
                    url: URL(string: "https://ko-fi.com/ca33u")
                )
            } header: {
                Text("Support Daisy")
            }

            // The version, what came with it, and the tour. The update
            // controls that sat here are on Settings → General (S3).
            Section {
                // Current version — name on the left, number + a copy button
                // on the right. Click it to copy "Daisy <version> (<build>)"
                // for support pastes.
                LabeledContent {
                    Button {
                        VersionInfo.copyToClipboardWithToast()
                    } label: {
                        HStack(spacing: 6) {
                            Text("\(VersionInfo.marketingVersion) (\(VersionInfo.buildNumber))")
                                .monospacedDigit()
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy version")
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle")
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        Text("Current version")
                    }
                }

                // «What's New» again (Egor 23.10): the window that opened
                // after the last update. Also on Settings → General → Updates.
                LabeledContent {
                    Button("Open") {
                        AppNavigation.shared.showsWhatsNew = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.daisyTextPrimary)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        Text("What’s New in Daisy")
                    }
                }

                // The first-run tour again, from step 1 (Onboarding 2.0).
                LabeledContent {
                    Button("Open") {
                        OnboardingTourController.shared.restart(settings: settings)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.daisyTextPrimary)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "figure.walk")
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        Text(OnboardingCopy.text(.again))
                    }
                }
            } header: {
                Text("Daisy")
            }

            Section {
                aboutLinkRow(
                    icon: "globe",
                    title: "Website",
                    detail: "mydaisy.io",
                    url: URL(string: "https://mydaisy.io")
                )
                aboutLinkRow(
                    icon: "lifepreserver",
                    title: "Support",
                    detail: "mydaisy.io/support",
                    url: URL(string: "https://mydaisy.io/support")
                )
                aboutLinkRow(
                    icon: "chevron.left.forwardslash.chevron.right",
                    title: "Source code",
                    detail: "github.com/ca33u/daisy-app",
                    url: URL(string: "https://github.com/ca33u/daisy-app")
                )
                aboutLinkRow(
                    icon: "bubble.left.and.bubble.right",
                    title: "Community",
                    detail: "Q&A, ideas, show-and-tell",
                    url: URL(string: "https://github.com/ca33u/daisy-app/discussions")
                )
                aboutLinkRow(
                    icon: "person.2.wave.2",
                    title: "Discord",
                    detail: "Chat with the community",
                    url: URL(string: "https://discord.gg/JYCZRZXy6j")
                )
                // Russian UI only: the announcements channel is in Russian
                // (Egor, 29.09). Keyed on the language the app is actually
                // shown in, not the system region.
                if Bundle.main.preferredLocalizations.first == "ru" {
                    aboutLinkRow(
                        icon: "paperplane",
                        title: "Telegram",
                        detail: "Анонсы — @daisyapp",
                        url: URL(string: "https://t.me/daisyapp")
                    )
                }
                aboutLinkRow(
                    icon: "doc.text",
                    title: "License",
                    detail: "Apache 2.0 — open source",
                    url: URL(string: "https://github.com/ca33u/daisy-app/blob/main/LICENSE")
                )
                aboutLinkRow(
                    icon: "lock.shield",
                    title: "Privacy",
                    detail: "mydaisy.io/privacy",
                    url: URL(string: "https://mydaisy.io/privacy")
                )
                aboutLinkRow(
                    icon: "envelope",
                    title: "Contact",
                    detail: "hello@mydaisy.io",
                    url: URL(string: "mailto:hello@mydaisy.io")
                )
                aboutLinkRow(
                    icon: "lifepreserver",
                    title: "Support",
                    detail: "support@mydaisy.io",
                    url: URL(string: "mailto:support@mydaisy.io")
                )
                // Who made the models Daisy downloads and on what terms lives on
                // the site (Egor 22.10). CC BY 4.0 allows the credit as a link to
                // where it's given (§3(a)(2)); the models' own license files
                // sit next to them on the mirror (models.mydaisy.io).
                aboutLinkRow(
                    icon: "doc.plaintext",
                    title: "Models and licenses",
                    detail: "mydaisy.io/licenses",
                    url: URL(string: "https://mydaisy.io/licenses#models")
                )
            } header: {
                Text("Links")
            }

            Section {
                aboutLinkRow(
                    icon: "building.2",
                    title: "Made by",
                    detail: "addicted",
                    url: URL(string: "https://addicted.sh")
                )
            } header: {
                Text("Studio")
            }
            // Bottom paragraph removed 2026-05-25 — merged into the
            // page-top brand header so the value-prop landed before the
            // user scrolled five rows of links instead of after.
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.daisyBgPrimary)
    }

    // MARK: - Pieces

    /// One link row in the Settings row idiom: a leading title label and
    /// a trailing button that opens the URL. Built on `LabeledContent`
    /// so it inherits the same grid/insets as every other Form row in
    /// Settings (which don't carry leading icons — so neither does this).
    @ViewBuilder
    private func aboutLinkRow(
        icon: String,
        title: LocalizedStringKey,
        detail: String,
        url: URL?
    ) -> some View {
        LabeledContent {
            if let url {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 4) {
                        Text(detail)
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                    }
                    .foregroundStyle(Color.daisyAccent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(title) + Text(verbatim: ": \(detail)"))
            } else {
                Text(detail).foregroundStyle(.secondary)
            }
        } label: {
            // Leading icon (secondary) + title — matches the icon rows in
            // Settings → Privacy (18pt icon column).
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(title)
            }
        }
    }
}

#Preview {
    AboutView(settings: AppSettings())
        .frame(width: 640, height: 720)
}
