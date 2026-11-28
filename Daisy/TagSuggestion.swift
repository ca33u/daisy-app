// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  TagSuggestion.swift
//  Daisy
//
//  Best-effort inference of a tag for a meeting from its calendar
//  attendee email list. Pure function, no side effects — call once
//  at session start with the bound DaisyMeeting; result is either
//  a normalised tag name (`"Mediacube"`) or nil (no clear external
//  signal).
//
//  Renamed from ClientSuggestion in 1.0.5.2 — "tag" is the
//  user-facing label; the logic stays domain-based (drop free-mail,
//  pick most-frequent remaining domain, strip TLD, title-case).
//

import Foundation

enum TagSuggestion {

    /// Best-effort inference from an attendee email list. Returns
    /// nil when no usable signal (no attendees, only free-mail
    /// addresses, attendee list empty).
    static func suggest(from emails: [String]) -> String? {
        guard !emails.isEmpty else { return nil }

        var orderedDomains: [String] = []
        var counts: [String: Int] = [:]
        for raw in emails {
            guard let domain = extractDomain(from: raw) else { continue }
            guard !isFreeMailDomain(domain) else { continue }
            counts[domain, default: 0] += 1
            if !orderedDomains.contains(domain) {
                orderedDomains.append(domain)
            }
        }
        guard !counts.isEmpty else { return nil }

        let maxCount = counts.values.max() ?? 0
        guard let winningDomain = orderedDomains.first(where: { counts[$0] == maxCount }) else {
            return nil
        }

        return normalizeDisplayName(domain: winningDomain)
    }

    // MARK: - Internals

    static func extractDomain(from email: String) -> String? {
        let trimmed = email.lowercased().trimmingCharacters(in: .whitespaces)
        guard let atIdx = trimmed.firstIndex(of: "@") else { return nil }
        let domain = String(trimmed[trimmed.index(after: atIdx)...])
        guard !domain.isEmpty, domain.contains(".") else { return nil }
        return domain
    }

    static func isFreeMailDomain(_ domain: String) -> Bool {
        return freeMailDomains.contains(domain)
    }

    static func normalizeDisplayName(domain: String) -> String {
        var parts = domain.split(separator: ".").map(String.init)
        while let first = parts.first,
              subdomainsToStrip.contains(first),
              parts.count > 1 {
            parts.removeFirst()
        }
        guard let stem = parts.first, !stem.isEmpty else { return domain }
        return titleCase(stem)
    }

    private static func titleCase(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
    }

    private static let subdomainsToStrip: Set<String> = [
        "www", "mail", "calendar", "smtp", "imap", "email", "mx",
    ]

    private static let freeMailDomains: Set<String> = [
        "gmail.com", "googlemail.com",
        "outlook.com", "hotmail.com", "live.com", "msn.com",
        "yahoo.com", "yahoo.co.uk", "yahoo.co.jp", "ymail.com",
        "icloud.com", "me.com", "mac.com",
        "proton.me", "protonmail.com", "pm.me",
        "fastmail.com", "fastmail.fm",
        "aol.com",
        "yandex.ru", "yandex.com", "ya.ru",
        "mail.ru", "bk.ru", "inbox.ru", "list.ru",
        "qq.com", "163.com", "126.com",
        "tutanota.com", "tutanota.de",
        "gmx.com", "gmx.de",
        "zoho.com",
    ]
}
