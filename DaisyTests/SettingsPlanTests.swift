//
//  SettingsPlanTests.swift
//  DaisyTests
//
//  Settings restructure S2 (Egor 24.10.2026): the processing plan the
//  cards show is always the one the settings match, the rows a plan
//  speaks for come from one table, and the rows that moved still have
//  exactly one anchor. Plain `ProcessingPreset.State` values — the tests
//  never touch the real prefs.
//

import Foundation
import Testing
@testable import Daisy

@MainActor
struct SettingsPlanTests {
    typealias Plan = ProcessingPreset
    typealias Setting = ProcessingPreset.Setting

    /// A fresh install: screenshots off, every minute when on.
    private let fresh = Plan.State(liveTranscript: .lite, diarizeRemoteSpeakers: true, diarizeMicrophone: false,
                                   transcriptSecondPass: true, screenshotsEnabled: false, screenshotIntervalSec: 60)

    /// Starting points that differ in everything a plan may touch.
    private var starts: [Plan.State] {
        let tiers = LiveTranscriptionTier.allCases
        var all: [Plan.State] = []
        for tier in tiers {
            for flags in 0..<8 {
                for (shots, interval) in [(false, 60), (true, 15), (true, 60), (true, 120)] {
                    all.append(Plan.State(liveTranscript: tier,
                                          diarizeRemoteSpeakers: flags & 1 != 0,
                                          diarizeMicrophone: flags & 2 != 0,
                                          transcriptSecondPass: flags & 4 != 0,
                                          screenshotsEnabled: shots, screenshotIntervalSec: interval))
                }
            }
        }
        return all
    }

    // MARK: - Matching

    @Test func eachPlanMatchesItsOwnValues() {
        #expect(Plan.matching(fresh) == .balanced, "a fresh install is Balanced")
        for plan in Plan.allCases {
            for start in starts {
                #expect(Plan.matching(plan.applied(to: start)) == plan, "\(plan) from \(start)")
            }
        }
    }

    @Test func oneValueOffAPlanIsCustom() {
        let maximum = Plan.maximum.applied(to: fresh)
        var live = maximum; live.liveTranscript = .lite
        var speakers = maximum; speakers.diarizeRemoteSpeakers = false
        var mic = maximum; mic.diarizeMicrophone = false
        var pass = maximum; pass.transcriptSecondPass = false
        for state in [live, speakers, mic, pass] {
            #expect(Plan.matching(state) == nil, "\(state)")
        }

        // Economy keeps captures off; turning them on by hand is «Свой».
        var economy = Plan.economy.applied(to: fresh)
        economy.screenshotsEnabled = true
        #expect(Plan.matching(economy) == nil)

        // Balanced allows captures, but no more often than every 2 min.
        var balanced = Plan.balanced.applied(to: fresh)
        balanced.screenshotsEnabled = true
        balanced.screenshotIntervalSec = 120
        #expect(Plan.matching(balanced) == .balanced)
        balanced.screenshotIntervalSec = 30
        #expect(Plan.matching(balanced) == nil)
    }

    @Test func maximumLeavesScreenshotsAlone() {
        for (shots, interval) in [(false, 60), (true, 15), (true, 120)] {
            var state = Plan.maximum.applied(to: fresh)
            state.screenshotsEnabled = shots
            state.screenshotIntervalSec = interval
            #expect(Plan.matching(state) == .maximum)
            #expect(Plan.maximum.applied(to: state) == state)
        }
    }

    /// Switching captures on under Balanced starts them at its pace, so
    /// the plan holds; under any other state the switch changes nothing else.
    @Test func capturesTurnedOnKeepBalanced() {
        var on = fresh
        on.screenshotsEnabled = true
        #expect(Plan.matching(on) == nil, "the 1-minute default alone would break Balanced")
        let kept = Plan.capturesTurnedOn(on)
        #expect(kept.screenshotIntervalSec == Plan.balancedScreenshotIntervalSec)
        #expect(Plan.matching(kept) == .balanced)

        var maximum = Plan.maximum.applied(to: fresh)
        maximum.screenshotsEnabled = true
        #expect(Plan.capturesTurnedOn(maximum) == maximum)
        #expect(Plan.capturesTurnedOn(fresh) == fresh, "captures off: nothing to do")
    }

    /// A plan never turns screen capture on — that stays the person's
    /// privacy choice (Egor, 07.10.2026).
    @Test func noPlanTurnsCapturesOn() {
        for plan in Plan.allCases {
            for start in starts where !start.screenshotsEnabled {
                #expect(!plan.applied(to: start).screenshotsEnabled)
            }
        }
    }

    // MARK: - One table

    /// What a plan writes is exactly what it owns: applying it changes
    /// only owned settings, and every owned setting is changed by it
    /// from some start. So the badged rows can't drift from the writes.
    @Test func ownedSettingsAreTheOnesThePlansWrite() {
        var writtenByAny = Set<Setting>()
        for plan in Plan.allCases {
            var written = Set<Setting>()
            for start in starts {
                let after = plan.applied(to: start)
                for setting in Setting.allCases where setting.value(in: start) != setting.value(in: after) {
                    written.insert(setting)
                }
            }
            let owned = Set(Setting.allCases.filter(plan.owns))
            #expect(written == owned, "\(plan) writes \(written), owns \(owned)")
            writtenByAny.formUnion(written)
        }
        #expect(writtenByAny == Set(Setting.allCases))
    }

    /// Every field of the state is one `Setting` — a seventh value can't
    /// join the match without a row and a badge.
    @Test func stateHasOneFieldPerSetting() {
        #expect(Mirror(reflecting: fresh).children.count == Setting.allCases.count)
        // And each setting reads a different field: flipping one field
        // moves exactly one setting's value.
        var other = fresh
        other.liveTranscript = .full
        other.diarizeRemoteSpeakers.toggle()
        other.diarizeMicrophone.toggle()
        other.transcriptSecondPass.toggle()
        other.screenshotsEnabled.toggle()
        other.screenshotIntervalSec = 15
        for setting in Setting.allCases {
            #expect(setting.value(in: fresh) != setting.value(in: other), "\(setting)")
        }
    }

    @Test func ownedRowsAreDistinctAndWhereThePlanSaysTheyAre() {
        let rows = Setting.allCases.map(\.row)
        #expect(Set(rows).count == rows.count)
        #expect(rows.map(\.tab) == [.meetings, .meetings, .meetings, .ai, .meetings, .meetings])
    }

    // MARK: - The views

    private func appSource() throws -> String {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DaisyTests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Daisy")
        let files = try FileManager.default.contentsOfDirectory(at: appSources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "no sources at \(appSources.path)")
        return try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    /// Each owned row wears exactly one badge, for its own setting.
    @Test func everyOwnedRowHasOneBadge() throws {
        let source = try appSource()
        for setting in Setting.allCases {
            let badges = source.components(separatedBy: "PlanBadge(.\(setting), settings:").count - 1
            #expect(badges == 1, "\(setting) has \(badges) badges")
        }
    }

    @Test func movedRowsSitOnTheirNewTabs() {
        #expect(SettingsRow.summaryTiming.tab == .meetings)
        #expect(SettingsRow.summaryTiming.rawValue == "meetings.summaryTiming")
        #expect(SettingsRow.showSessionAfterStop.tab == .meetings)
        #expect(SettingsRow.daisyKeyCloudGrants.tab == .shortcuts)
        #expect(SettingsRow.screenshotInterval.tab == .meetings)
    }

    @Test func hiddenS2RowsLandOnTheirStandIns() {
        let off = SettingsRow.Switches(layoutFixEnabled: true, screenshotsEnabled: false, hasCloudGrants: false)
        let on = SettingsRow.Switches()
        #expect(SettingsRow.screenshotInterval.target(off) == .screenCapture)
        #expect(SettingsRow.daisyKeyCloudGrants.target(off) == .daisyKeyMeetingCommands)
        #expect(SettingsRow.screenshotInterval.target(on) == .screenshotInterval)
        #expect(SettingsRow.daisyKeyCloudGrants.target(on) == .daisyKeyCloudGrants)
    }
}
