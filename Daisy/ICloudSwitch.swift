//
//  ICloudSwitch.swift
//  Daisy
//
//  One switch for everything of the person's that Daisy puts in iCloud:
//  Settings → Sync, off by default (J-0, 2026-09-22).
//
//  Until 1.0.8.52 it stopped only the session sync. Three things ran
//  beside it, sync on or off (found 16.11 while the privacy page was
//  checked against the code): the project list and the vocabulary went
//  to iCloud's key-value store, every saved key and token was a
//  synchronizable keychain item, and the Mac listened on the local
//  network for the iPhone's recordings. Settings said «nothing leaves
//  this Mac until you turn it on». Now all of them read this switch:
//
//    • `SyncCoordinator` — sessions through CloudKit, as before;
//    • `FolderRegistryBridge`, `VocabularyBridge` — the key-value store;
//    • `KeychainStore` — where a secret is kept;
//    • `AudioHandoffServer` — the listener. The phone offers only the
//      audio of sessions whose text came through CloudKit, so with sync
//      off there was never anything for it to receive.
//
//  `nonisolated`, read from the defaults: the keychain is asked from any
//  thread, and at launch before `SyncCoordinator` exists.
//

import Foundation

nonisolated enum ICloudSwitch {
    static let key = "daisy.sync.enabled"
    /// `AppSettings.hasShownFirstRun`'s key: true once the person has been
    /// through the first run, on any version since 1.0.1.
    static let firstRunShownKey = "daisy.hasShownFirstRun"

    static var isOn: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? false
    }

    /// `VersionInfo`'s trail of the builds that have run on this Mac.
    static let versionTrailKey = "daisy.versionTrail"

    /// Daisy has run on this Mac before. Decides whether what an earlier
    /// version kept in iCloud is copied to this Mac when sync is off: an
    /// update keeps its keys and its projects' notes, a new install on a
    /// second Mac takes nothing from iCloud it was not asked to.
    ///
    /// Two signs, either is enough: the first run was finished, or an
    /// earlier launch left its build in the trail — the person who
    /// updates in the middle of the tour has only the second.
    ///
    /// Answered once per run, and `DaisyApp.init` asks before anything
    /// else: later in the same launch a new install has recorded its
    /// build, and may have finished the tour.
    static let isExistingInstall: Bool = {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: firstRunShownKey)
            || !(defaults.stringArray(forKey: versionTrailKey) ?? []).isEmpty
    }()

    /// The person flipped the switch, and the defaults already say `on`.
    @MainActor
    static func changed(to on: Bool) {
        KeychainStore.iCloudSwitchChanged(to: on)
        FolderRegistryBridge.shared.setUsesICloud(on)
        VocabularyBridge.shared.setUsesICloud(on)
        if on {
            AudioHandoffServer.shared.start()
            // Keys another device left in iCloud are readable from now.
            RecordingSession.current?.settings.reloadSecretsAfterSyncWentOn()
        } else {
            AudioHandoffServer.shared.stop()
        }
    }
}
