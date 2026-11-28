//
//  AboutView.swift
//  Daisy
//
//  About page. Previously a tab inside SettingsView, then a page of the
//  main window's sidebar so users find studio / contact / license info
//  in one obvious place; a page of the Settings window's sidebar for a
//  day (31.10.2026); since 01.11 a sheet of its own on the main window,
//  no sidebar (AboutPanel, SettingsPanel.swift), opened by «About Daisy»
//  and the main sidebar's About row.
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
//  2026-11-01 (Egor): two of them are back as copies, since this is where
//  people look — «Get beta updates» and «Report a bug». Their home rows
//  (General → Updates, Privacy → Logs) keep the search and deep links.
//  2026-11-28: Daisy is under AGPL-3.0-only, and this page is where it shows
//  its legal notices — the last section, «Legal notices» (LegalNotices,
//  AboutLegalSection). «Source code» and «License» moved there from Links.
//

import AppKit
import SwiftUI

struct AboutView: View {
    let settings: AppSettings
    @Bindable private var updater = SparkleUpdater.shared

    var body: some View {
        Form {
            // The support link sits above everything else (Egor,
            // 2026-08-31): Daisy is free and open source, and this is the
            // one row we actually want a visitor of this page to notice.
            // Reuses the standard link-row idiom — no special styling, a
            // plain top-of-page section is emphasis enough.
            // Since 27.11 it is «support», not «a coffee» or «a donation»
            // (Egor), and it opens mydaisy.io/support-daisy: the site sends
            // that on to the payment page (Whop, in place of Ko-fi), so the
            // page can change without a release. The Ko-fi address was
            // written in here, and every older Daisy still opens it.
            Section {
                aboutLinkRow(
                    icon: "heart",
                    title: "Help Daisy stay independent",
                    detail: "mydaisy.io/support-daisy",
                    url: URL(string: "https://mydaisy.io/support-daisy")
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
                        // One sheet at a time: this one steps aside for
                        // What's New (AppNavigation.showsWhatsNew).
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
                        // The tour takes the main window, without this sheet.
                        AppNavigation.shared.closePanel()
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

                // Back where people look for them (Egor 01.11): the
                // restructure moved them to General → Updates and Privacy →
                // Logs, which stay their home for search and deep links.
                Toggle(isOn: $updater.receiveBetaUpdates) {
                    HStack(spacing: 10) {
                        Image(systemName: "testtube.2")
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        Text("Get beta updates")
                    }
                }
                .toggleStyle(.switch)

                LabeledContent {
                    Button {
                        LogReporter.sendReport(settings: settings)
                    } label: {
                        HStack(spacing: 4) {
                            Text("Send Log Report…")
                            Image(systemName: "envelope")
                                .font(.caption)
                        }
                        .foregroundStyle(Color.daisyAccent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Report a bug: send a log report")
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "ladybug")
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        Text("Report a bug")
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

            // Last on the page, with the small print under it.
            AboutLegalSection()
            // Bottom paragraph removed 2026-05-25 — merged into the
            // page-top brand header so the value-prop landed before the
            // user scrolled five rows of links instead of after.
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.daisyBgPrimary)
    }

    // MARK: - Pieces

    private func aboutLinkRow(
        icon: String,
        title: LocalizedStringKey,
        detail: String,
        url: URL?
    ) -> some View {
        AboutLinkRow(icon: icon, title: title, detail: detail, url: url)
    }
}

/// One link row in the Settings row idiom: a leading title label and
/// a trailing button that opens the URL. Built on `LabeledContent`
/// so it inherits the same grid/insets as every other Form row in
/// Settings.
struct AboutLinkRow: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: String
    let url: URL?

    var body: some View {
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

// MARK: - Legal notices

/// What Daisy states about its authorship and license. NOTICE.md at the
/// repository root is the source of truth: its term 1 (attribution, AGPL
/// section 7(b)) quotes `attribution` word for word and names the About
/// window as the place it is shown, with the link to the source code.
/// AboutLegalTests holds the two together. The proper names are not
/// translated.
nonisolated enum LegalNotices {
    static let attribution = "Daisy (https://mydaisy.io) by Egor Sazanov, addicted"
    /// Also Info.plist's NSHumanReadableCopyright.
    static let copyright = "Copyright © 2026 Egor Sazanov, addicted"
    /// The row's name for the license; the notice under the rows gives the
    /// SPDX identifier in full, AGPL-3.0-only.
    static let licenseName = "AGPL-3.0"

    static let website = "https://mydaisy.io"
    static let sourceCode = "https://github.com/ca33u/daisy-app"
    static let licenseText = "https://github.com/ca33u/daisy-app/blob/main/LICENSE"
    static let notice = "https://github.com/ca33u/daisy-app/blob/main/NOTICE.md"
}

/// The «Appropriate Legal Notices» of AGPL section 0, in the page's own
/// rows: who wrote Daisy and where its source is, the license and the
/// additional terms, and under them the copyright line, that there is no
/// warranty, and that Daisy may be passed on under the license. The same
/// LICENSE and NOTICE.md ship inside the app (Contents/Resources); the
/// rows open the ones on GitHub.
struct AboutLegalSection: View {
    var body: some View {
        Section {
            AboutLinkRow(
                icon: "person",
                title: "Author",
                detail: LegalNotices.attribution,
                url: URL(string: LegalNotices.website)
            )
            AboutLinkRow(
                icon: "chevron.left.forwardslash.chevron.right",
                title: "Source code",
                detail: "github.com/ca33u/daisy-app",
                url: URL(string: LegalNotices.sourceCode)
            )
            AboutLinkRow(
                icon: "doc.text",
                title: "License",
                detail: LegalNotices.licenseName,
                url: URL(string: LegalNotices.licenseText)
            )
            AboutLinkRow(
                icon: "doc.append",
                title: "Additional terms",
                detail: "NOTICE.md",
                url: URL(string: LegalNotices.notice)
            )
        } header: {
            Text("Legal notices")
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: LegalNotices.copyright)
                Text("Daisy is free software under AGPL-3.0-only. It comes with no warranty. You may redistribute it under that license")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    AboutView(settings: AppSettings())
        .frame(width: 640, height: 720)
}
