//
//  ImprovementConsentRow.swift
//  Daisy
//
//  «Help make Daisy better» as a row (Egor, 21.10): on Home's «Finish
//  setting up» card for people who haven't answered or said «Not Now»,
//  and on onboarding's last step for a new person — instead of the modal
//  question two minutes after launch. Help turns the counts on; Not Now
//  asks once more later, then never; See What's Sent shows the report
//  word for word. Same promise as before: numbers only, no identifier.
//

import SwiftUI

struct ImprovementConsentRow: View {
    // Read through @AppStorage so the row goes the moment it's answered,
    // here or in Settings → Privacy.
    @AppStorage(ImprovementStats.modeKey) private var modeRaw = ImprovementStats.Mode.unasked.rawValue
    @AppStorage(ImprovementStats.notNowCountKey) private var notNowCount = 0
    @AppStorage(ImprovementStats.offByChoiceKey) private var offByChoice = false
    @AppStorage(ImprovementStats.notNowAtKey) private var notNowAt = 0.0

    private var offered: Bool {
        ImprovementStats.offersRow(mode: ImprovementStats.Mode(rawValue: modeRaw) ?? .unasked,
                                   notNowCount: notNowCount, offByChoice: offByChoice, notNowAt: notNowAt)
    }

    var body: some View {
        if offered {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "heart")
                    .font(.title3)
                    .foregroundStyle(Color.daisyHomeAccent)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Help make Daisy better")
                        .font(.callout.weight(.medium))
                    Text("Once a day, a short summary: how often recording, dictation and summaries ran, and where something went wrong. No text, titles, names or identifier — we won't know who you are.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button(String(localized: "Help")) { ImprovementStats.mode = .on }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button(String(localized: "Not Now")) { ImprovementStats.answerNotNow() }
                            .controlSize(.small)
                        Button(String(localized: "See What's Sent")) { ImprovementStats.showPreview() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}
