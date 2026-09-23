//
//  PseudonymSession.swift
//  DaisyCore
//
//  Moved from daisy-app/Daisy/SensitiveDataProtector.swift @ 1.0.8.2,
//  2026-09-23 (backlog 19 А-2а) so the Mac and the phone pseudonymize
//  with one piece of code. What it does is unchanged: names, companies,
//  emails, phones and links become reversible typed markers
//  (`[[DAISY_PERSON_001]]`); secrets, keys, tokens and card numbers are
//  cut out for good. The token → original dictionary lives in this value
//  for one provider request and is never encoded or stored.
//
//  New here: `knownPeople`. `NLTagger` finds almost no names in Russian
//  text, and a model that would is tens of megabytes. Daisy already
//  knows who was in the room — calendar attendees, speaker names, scanned
//  cards, the owner — so those names are replaced by dictionary, in every
//  case form Russian gives them («Влад», «Влада», «Владу», «Владом»).
//  Deterministic, reversible, and no bigger than the list.
//

import Foundation
import NaturalLanguage

public nonisolated enum SensitiveEntityKind: String, Sendable, CaseIterable {
    case person = "PERSON"
    case organization = "ORG"
    case email = "EMAIL"
    case phone = "PHONE"
    case url = "URL"
    case secret = "SECRET"
    case paymentCard = "PAYMENT_CARD"

    public var isReversible: Bool {
        self != .secret && self != .paymentCard
    }
}

public nonisolated struct SensitiveDataProtectionReport: Sendable, Equatable {
    public let distinctReplacements: Int
    public let redactedOccurrences: Int
    /// Distinct entities replaced, per kind — what the person is shown
    /// before sending: «7 names, 2 emails, 1 phone; removed: 1 key».
    public let replacementsByKind: [SensitiveEntityKind: Int]

    public init(distinctReplacements: Int, redactedOccurrences: Int,
                replacementsByKind: [SensitiveEntityKind: Int] = [:]) {
        self.distinctReplacements = distinctReplacements
        self.redactedOccurrences = redactedOccurrences
        self.replacementsByKind = replacementsByKind
    }
}

/// One request's worth of pseudonyms. Protect every string that goes to
/// the provider through the SAME session — the title, the transcript,
/// any context — so one person gets one marker everywhere; then
/// `restore` whatever comes back.
public nonisolated struct PseudonymSession: Sendable {
    public let detectNamedEntities: Bool
    /// Every entity gets a reversible marker, including the kinds that
    /// are normally cut out. For tasks whose output is the person's own
    /// text handed back to them, an unrestorable placeholder is data
    /// loss, not privacy.
    public let reversibleOnly: Bool

    private var tokenByEntity: [String: String] = [:]
    private var originalsByToken: [String: String] = [:]
    private var counters: [SensitiveEntityKind: Int] = [:]
    private var personAliases: [String: String] = [:]
    private var ambiguousPersonAliases: Set<String> = []
    private var redactedOccurrences = 0
    /// Dictionary matchers for `knownPeople`, longest first.
    private var knownPatterns: [(regex: NSRegularExpression, token: String)] = []

    public init(detectNamedEntities: Bool = true, reversibleOnly: Bool = false, knownPeople: [String] = []) {
        self.detectNamedEntities = detectNamedEntities
        self.reversibleOnly = reversibleOnly
        seed(knownPeople)
    }

    public var report: SensitiveDataProtectionReport {
        var byKind: [SensitiveEntityKind: Int] = [:]
        for token in originalsByToken.keys {
            for kind in SensitiveEntityKind.allCases where token.hasPrefix("[[DAISY_\(kind.rawValue)_") {
                byKind[kind, default: 0] += 1
            }
        }
        return SensitiveDataProtectionReport(
            distinctReplacements: originalsByToken.count,
            redactedOccurrences: redactedOccurrences,
            replacementsByKind: byKind)
    }

    /// Put the originals back into model output.
    public func restore(_ text: String) -> String {
        PseudonymSession.restore(text, using: originalsByToken)
    }

    public func restore(_ summary: MeetingSummary) -> MeetingSummary {
        func bullet(_ b: SummaryBullet) -> SummaryBullet {
            SummaryBullet(text: restore(b.text), children: b.children.map(bullet))
        }
        return MeetingSummary(
            summary: restore(summary.summary),
            sections: summary.sections.map { SummarySection(title: restore($0.title), bullets: $0.bullets.map(bullet)) },
            actionItems: summary.actionItems.map { restore($0) },
            clientFollowUp: restore(summary.clientFollowUp))
    }

    // MARK: - Protect

    public mutating func protect(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let source = text as NSString
        var candidates = structuredCandidates(in: text)
        candidates += knownPeopleCandidates(in: text)
        if detectNamedEntities {
            candidates += namedEntityCandidates(in: text)
        }
        let selected = Self.nonOverlapping(candidates).sorted { $0.range.location > $1.range.location }
        guard !selected.isEmpty else { return text }

        let result = NSMutableString(string: text)
        for candidate in selected {
            let original = source.substring(with: candidate.range)
            let replacement: String
            if let known = candidate.token {
                replacement = known
            } else if candidate.kind.isReversible || reversibleOnly {
                replacement = token(for: candidate.kind, original: original)
            } else {
                redactedOccurrences += 1
                replacement = "[[REDACTED_\(candidate.kind.rawValue)]]"
            }
            result.replaceCharacters(in: candidate.range, with: replacement)
        }
        return result as String
    }

    // MARK: - Tokens

    private mutating func token(for kind: SensitiveEntityKind, original: String) -> String {
        let normalized = Self.normalize(original)
        let key = "\(kind.rawValue)|\(normalized)"
        if let existing = tokenByEntity[key] { return existing }
        if kind == .person, !ambiguousPersonAliases.contains(normalized), let alias = personAliases[normalized] {
            tokenByEntity[key] = alias
            return alias
        }
        let next = (counters[kind] ?? 0) + 1
        counters[kind] = next
        let token = String(format: "[[DAISY_%@_%03d]]", kind.rawValue, next)
        tokenByEntity[key] = token
        originalsByToken[token] = original
        if kind == .person { registerPersonAliases(original: original, token: token) }
        return token
    }

    private mutating func registerPersonAliases(original: String, token: String) {
        let pieces = original.split { !$0.isLetter && !$0.isNumber }
            .map { Self.normalize(String($0)) }
            .filter { $0.count >= 3 }
        guard pieces.count > 1 else { return }
        for alias in pieces {
            if let existing = personAliases[alias], existing != token {
                personAliases.removeValue(forKey: alias)
                ambiguousPersonAliases.insert(alias)
            } else if !ambiguousPersonAliases.contains(alias) {
                personAliases[alias] = token
            }
        }
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Known people

    private mutating func seed(_ people: [String]) {
        var forms: [(form: String, token: String)] = []
        for raw in people {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // An email is not a name; the email recognizer has it.
            guard name.count >= 3, !name.contains("@") else { continue }
            let token = token(for: .person, original: name)
            forms.append((name, token))
            let pieces = name.split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 }
            if pieces.count > 1 {
                for piece in pieces { forms.append((piece, token)) }
            }
        }
        // A piece shared by two people («Анна» in two full names) names
        // neither of them; leave it to the full forms.
        var tokensByPiece: [String: Set<String>] = [:]
        for f in forms { tokensByPiece[Self.normalize(f.form), default: []].insert(f.token) }
        var seen: Set<String> = []
        for f in forms.sorted(by: { $0.form.count > $1.form.count }) {
            let key = Self.normalize(f.form)
            guard tokensByPiece[key]?.count == 1, seen.insert(key).inserted,
                  let regex = Self.declinedNameRegex(f.form) else { continue }
            knownPatterns.append((regex, f.token))
        }
    }

    /// The name and, for Cyrillic, the case forms Russian gives it.
    private static func declinedNameRegex(_ name: String) -> NSRegularExpression? {
        let words = name.split(separator: " ").map(String.init)
        let parts = words.map { word -> String in
            let isCyrillic = word.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
            guard isCyrillic, word.count >= 3 else {
                return NSRegularExpression.escapedPattern(for: word) + "(?:'s)?"
            }
            let last = word.last.map { String($0).lowercased() } ?? ""
            let stem: String
            let endings: [String]
            switch last {
            case "а", "я":
                stem = String(word.dropLast())
                endings = ["а", "я", "ы", "и", "е", "у", "ю", "ой", "ей", "ою", "ею"]
            case "й", "ь":
                stem = String(word.dropLast())
                endings = ["й", "ь", "я", "ю", "ем", "ём", "е", "и"]
            default:
                stem = word
                endings = ["", "а", "у", "ом", "е", "ы", "ов", "ам", "ами", "ах", "ым", "ой", "ую", "ого", "ому"]
            }
            let alternatives = endings.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            return NSRegularExpression.escapedPattern(for: stem) + "(?:\(alternatives))"
        }
        let pattern = "(?<![\\p{L}\\d])" + parts.joined(separator: "\\s+") + "(?![\\p{L}\\d])"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private func knownPeopleCandidates(in text: String) -> [Candidate] {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return knownPatterns.flatMap { entry in
            entry.regex.matches(in: text, range: range).map {
                Candidate(range: $0.range, kind: .person, priority: 60, token: entry.token)
            }
        }
    }

    // MARK: - Detection

    private struct Candidate {
        let range: NSRange
        let kind: SensitiveEntityKind
        let priority: Int
        var token: String? = nil
    }

    private func structuredCandidates(in text: String) -> [Candidate] {
        var result: [Candidate] = []
        result += Self.matches(Self.secretURLRegex, in: text, kind: .secret, priority: 120)
        result += Self.matches(Self.privateKeyRegex, in: text, kind: .secret, priority: 115)
        result += Self.matches(Self.credentialRegex, in: text, kind: .secret, priority: 110)
        result += Self.matches(Self.openAIKeyRegex, in: text, kind: .secret, priority: 108)
        result += Self.matches(Self.githubTokenRegex, in: text, kind: .secret, priority: 108)
        result += Self.matches(Self.jwtRegex, in: text, kind: .secret, priority: 108)
        let ns = text as NSString
        for match in Self.paymentCardRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let digits = ns.substring(with: match.range).filter(\.isNumber)
            if (13...19).contains(digits.count), Self.passesLuhn(digits) {
                result.append(Candidate(range: match.range, kind: .paymentCard, priority: 100))
            }
        }
        result += Self.matches(Self.emailRegex, in: text, kind: .email, priority: 90)
        result += Self.matches(Self.urlRegex, in: text, kind: .url, priority: 85)
        result += Self.matches(Self.phoneRegex, in: text, kind: .phone, priority: 80)
        return result
    }

    private func namedEntityCandidates(in text: String) -> [Candidate] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var result: [Candidate] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            let kind: SensitiveEntityKind? = switch tag {
            case .personalName: .person
            case .organizationName: .organization
            default: nil
            }
            if let kind {
                let nsRange = NSRange(range, in: text)
                if nsRange.length >= 2 {
                    result.append(Candidate(range: nsRange, kind: kind, priority: kind == .person ? 55 : 50))
                }
            }
            return true
        }
        return result
    }

    private static func matches(_ regex: NSRegularExpression, in text: String,
                                kind: SensitiveEntityKind, priority: Int) -> [Candidate] {
        regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            .map { Candidate(range: $0.range, kind: kind, priority: priority) }
    }

    private static func nonOverlapping(_ candidates: [Candidate]) -> [Candidate] {
        let ranked = candidates.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            return $0.range.location < $1.range.location
        }
        var selected: [Candidate] = []
        for candidate in ranked where candidate.range.length > 0 {
            guard !selected.contains(where: { NSIntersectionRange($0.range, candidate.range).length > 0 }) else { continue }
            selected.append(candidate)
        }
        return selected
    }

    // MARK: - Recognizers

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Compile-time constants covered by unit tests.
        try! NSRegularExpression(pattern: pattern)
    }

    private static let secretURLRegex = regex(
        #"(?i)https?://[^\s<>()]*(?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password)=[^\s<>()&]+[^\s<>()]*"#)
    private static let privateKeyRegex = regex(
        #"-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----[\s\S]*?-----END(?: [A-Z0-9]+)? PRIVATE KEY-----"#)
    private static let credentialRegex = regex(
        #"(?i)\b(?:api[_ -]?key|access[_ -]?token|refresh[_ -]?token|password|passwd|client[_ -]?secret)\b\s*[:=]\s*[\"']?[^\s,;\"']{8,}"#)
    private static let openAIKeyRegex = regex(#"\bsk-[A-Za-z0-9_-]{20,}\b"#)
    private static let githubTokenRegex = regex(#"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#)
    private static let jwtRegex = regex(#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#)
    private static let paymentCardRegex = regex(#"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)"#)
    private static let emailRegex = regex(
        #"(?i)(?<![A-Z0-9._%+-])[A-Z0-9._%+-]+@[A-Z0-9-]+(?:\.[A-Z0-9-]+)+(?=$|[^A-Z0-9-])"#)
    private static let urlRegex = regex(#"(?i)https?://[^\s<>()]+"#)
    private static let phoneRegex = regex(#"(?<![\p{L}\d])\+?\d[\d ()-]{6,}\d(?![\p{L}\d])"#)

    private static func passesLuhn(_ digits: String) -> Bool {
        let values = digits.compactMap(\.wholeNumberValue)
        guard values.count == digits.count else { return false }
        let sum = values.reversed().enumerated().reduce(0) { total, item in
            let (offset, digit) = item
            guard !offset.isMultiple(of: 2) else { return total + digit }
            let doubled = digit * 2
            return total + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum.isMultiple(of: 10)
    }

    // MARK: - Restore (tolerant)

    /// Tolerant on purpose. Models don't always echo the markers byte
    /// for byte: they lowercase them, put spaces inside the brackets, or
    /// decline them in Russian as if they were words. Every such near-miss
    /// used to leave `[[DAISY_PERSON_001]]` in the output (Mac audit
    /// 2026-09-01). So: match the marker shape, case-insensitively, with
    /// whitespace allowed anywhere inside the brackets.
    public static func restore(_ text: String, using originals: [String: String]) -> String {
        guard !originals.isEmpty, text.contains("[") else { return text }
        var result = text
        for (token, original) in originals {
            let inner = token.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
            let spaced = inner.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s*")
            let pattern = "\\[\\s*\\[\\s*\(spaced)\\s*\\]\\s*\\]"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                result = result.replacingOccurrences(of: token, with: original)
                continue
            }
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: original))
        }
        return result
    }

    /// True when any pseudonym or redaction marker survived `restore`.
    /// Output shown to a person must be refused rather than shipped with
    /// a placeholder in it.
    public static func containsUnrestoredMarker(_ text: String) -> Bool {
        text.range(of: "\\[\\s*\\[\\s*(DAISY|REDACTED)_", options: [.regularExpression, .caseInsensitive]) != nil
    }
}
