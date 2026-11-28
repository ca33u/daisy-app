// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  StatusBadge.swift
//  Daisy
//
//  Shared visual language for status rows across Settings: Whisper
//  model state, Summarizer availability, MCP server bind state,
//  Notion / summary test outcomes. Before this everyone painted
//  their own icon + colour combo and the four status surfaces felt
//  like four different apps.
//
//  Usage:
//      StatusBadge(state: .running, message: "Listening on 127.0.0.1:54321")
//

import SwiftUI

struct StatusBadge: View {
    enum State {
        /// Nothing to report. Renders as an empty view so callers
        /// can pass `.idle` without conditional unwrapping.
        case idle
        /// In-flight: shows a small spinner instead of an icon.
        case busy
        /// Success: green check.
        case ok
        /// Soft alert: amber triangle.
        case warn
        /// Failure: red exclamation.
        case err
    }

    let state: State
    let message: String?

    init(state: State, message: String? = nil) {
        self.state = state
        self.message = message
    }

    var body: some View {
        if case .idle = state {
            EmptyView()
        } else {
            HStack(spacing: 6) {
                icon
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .idle:
            EmptyView()
        case .busy:
            ProgressView().controlSize(.small)
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.daisySuccess)
                .font(.callout)
        case .warn:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.daisyWarning)
                .font(.callout)
        case .err:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(Color.daisyError)
                .font(.callout)
        }
    }
}
