//
//  FirstRunStepsTests.swift
//  DaisyTests
//
//  Regression locks for the onboarding step order — the one pure piece
//  of FirstRunView. The UI itself (rail clicks, the narrow-window
//  fallback, permission prompts) is device-QA territory; what CAN be
//  pinned down is which steps appear, for which setup path, and where
//  the layout-fixer step lands relative to the hotkeys step.
//

import Testing
@testable import Daisy

@Suite("First-run step order")
struct FirstRunStepsTests {

    typealias Step = FirstRunView.Step

    // MARK: - Exact orders (also proves folder/vocab are gone and the
    // rest of the order didn't move)

    @Test("Full path ends with model preparation")
    func fullPathSingleLayout() {
        #expect(FirstRunView.steps(for: .full, installedLayoutCount: 1) == [
            .purpose, .name, .permissions,
            .hotkeys, .calendar, .model, .preparation,
        ])
    }

    @Test("Dictation-only path also requires model preparation")
    func dictationPathSingleLayout() {
        #expect(FirstRunView.steps(for: .dictationOnly, installedLayoutCount: 1) == [
            .purpose, .permissions, .hotkeys, .preparation,
        ])
    }

    // MARK: - The layout step

    @Test("Layout step appears with 2+ installed layouts, right after hotkeys",
          arguments: [2, 3, 5])
    func layoutStepPresentWithManyLayouts(count: Int) {
        for path in [FirstRunView.SetupPath.full, .dictationOnly] {
            let steps = FirstRunView.steps(for: path, installedLayoutCount: count)
            let hotkeysIndex = steps.firstIndex(of: .hotkeys)
            #expect(hotkeysIndex != nil)
            if let hotkeysIndex {
                #expect(steps[hotkeysIndex + 1] == .layout)
            }
            // Exactly once, never duplicated.
            #expect(steps.filter { $0 == .layout }.count == 1)
        }
    }

    @Test("Layout step absent with a single installed layout")
    func layoutStepAbsentWithOneLayout() {
        for path in [FirstRunView.SetupPath.full, .dictationOnly] {
            let steps = FirstRunView.steps(for: path, installedLayoutCount: 1)
            #expect(!steps.contains(.layout))
        }
    }

    @Test("Adding the layout step changes nothing else about the order")
    func layoutStepIsPureInsertion() {
        for path in [FirstRunView.SetupPath.full, .dictationOnly] {
            let without = FirstRunView.steps(for: path, installedLayoutCount: 1)
            let with = FirstRunView.steps(for: path, installedLayoutCount: 2)
            #expect(with.filter { $0 != .layout } == without)
        }
    }

    // MARK: - Resuming after a relaunch
    //
    // Granting Screen Recording ends with macOS offering "Quit & Reopen",
    // so onboarding has to come back to where it was. The snapshot is a
    // raw string in UserDefaults; `resumeStep` is the pure part that
    // reconciles it with the steps this launch actually shows.

    @Test("A saved step still in the path is resumed exactly")
    func resumesSavedStep() {
        let steps = FirstRunView.steps(for: .full, installedLayoutCount: 1)
        for step in steps {
            #expect(FirstRunView.resumeStep(savedRaw: step.rawValue, in: steps) == step)
        }
    }

    @Test("Nothing saved yet starts at the beginning")
    func noSnapshotStartsAtPurpose() {
        let steps = FirstRunView.steps(for: .full, installedLayoutCount: 1)
        #expect(FirstRunView.resumeStep(savedRaw: nil, in: steps) == .purpose)
    }

    @Test("An unreadable snapshot starts at the beginning rather than trapping",
          arguments: ["", "0", "3", "vocabulary", "Permissions"])
    func unknownRawStartsAtPurpose(raw: String) {
        let steps = FirstRunView.steps(for: .full, installedLayoutCount: 1)
        #expect(FirstRunView.resumeStep(savedRaw: raw, in: steps) == .purpose)
    }

    @Test("A step that disappeared falls back to the nearest earlier one, not to the start")
    func vanishedStepFallsBackNotRestarts() {
        // Saved on the layout step, then a keyboard layout was removed.
        for path in [FirstRunView.SetupPath.full, .dictationOnly] {
            let steps = FirstRunView.steps(for: path, installedLayoutCount: 1)
            #expect(FirstRunView.resumeStep(savedRaw: Step.layout.rawValue, in: steps)
                    == .hotkeys)
        }
    }

    @Test("A step the current path never shows falls back to the nearest earlier one")
    func stepOutsidePathFallsBack() {
        let steps = FirstRunView.steps(for: .dictationOnly, installedLayoutCount: 1)
        // `.name` and the soft steps don't exist on the dictation-only
        // path; each resolves backwards to the last step that does.
        #expect(FirstRunView.resumeStep(savedRaw: Step.name.rawValue, in: steps) == .purpose)
        #expect(FirstRunView.resumeStep(savedRaw: Step.calendar.rawValue, in: steps) == .hotkeys)
        #expect(FirstRunView.resumeStep(savedRaw: Step.model.rawValue, in: steps) == .hotkeys)
    }

    @Test("Step raw values are stable names, not positions")
    func stepRawValuesAreNames() {
        // The snapshot outlives an app update, so reordering or
        // inserting a case must not silently move a resumed user.
        #expect(Step.purpose.rawValue == "purpose")
        #expect(Step.permissions.rawValue == "permissions")
        #expect(Step.model.rawValue == "model")
    }
}
