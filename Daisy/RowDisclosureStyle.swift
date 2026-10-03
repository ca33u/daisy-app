//
//  RowDisclosureStyle.swift
//  Daisy
//
//  A disclosure group that opens by its whole row, not only by the small
//  chevron (Egor, 03.10.2026: «сделай аккордеоны разворачиваемыми по
//  строке»). Same look as the system one — chevron, then the label — with
//  the row's full width as the target.
//

import SwiftUI

struct RowDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    configuration.label
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? Text("Expanded") : Text("Collapsed"))
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

extension DisclosureGroupStyle where Self == RowDisclosureStyle {
    /// Opens and closes by a click anywhere on its row.
    static var row: RowDisclosureStyle { RowDisclosureStyle() }
}
