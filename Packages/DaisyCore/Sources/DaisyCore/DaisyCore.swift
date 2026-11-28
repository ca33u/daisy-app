// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  DaisyCore.swift
//  DaisyCore
//
//  Module marker. The package's real contents live in Session/, Audio/,
//  Transcription/, Vocabulary/, Summary/.
//

import Foundation

public nonisolated enum DaisyCore {
    /// Logging subsystem shared by every DaisyCore logger.
    public static let logSubsystem = "app.essazanov.DaisyLite"
}
