//
//  ScriptDocument.swift
//  DaisyCore
//
//  Backlog 17 С-0: `script.md` in a rehearsal take (§3.7) — the text as it
//  was for this take, with the take's identity in its own frontmatter so
//  whoever renders `transcript.md` later (the phone's transcription
//  queue, hours after the recording) can mark the session without being
//  told anything else.
//

import Foundation

public nonisolated struct ScriptDocument: Sendable, Equatable {
    public static let fileName = "script.md"

    public var id: UUID
    public var title: String
    public var text: String
    /// Target length in whole seconds; nil when there is none.
    public var targetSeconds: Int?

    public init(id: UUID = UUID(), title: String, text: String, targetSeconds: Int? = nil) {
        self.id = id
        self.title = title
        self.text = text
        self.targetSeconds = targetSeconds
    }

    public func render() -> String {
        var lines = ["---", "title: \(SessionDocument.yamlQuote(title))", "daisy_script_id: \(id.uuidString)"]
        if let targetSeconds { lines.append("daisy_target_sec: \(targetSeconds)") }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n" + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    public static func parse(_ markdown: String) -> ScriptDocument? {
        let parsed = SessionDocument.parseFrontmatter(in: markdown)
        guard let raw = parsed["daisy_script_id"], let id = UUID(uuidString: raw) else { return nil }
        // The shared parser strips the quotes and, like the Mac's, stops
        // there (§3.1, a listed gap); a second reader undoes the escapes.
        let title = (parsed.title ?? "")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
        return ScriptDocument(id: id, title: title, text: parsed.body.trimmingCharacters(in: .whitespacesAndNewlines),
                              targetSeconds: parsed["daisy_target_sec"].flatMap { Int($0) })
    }

    public static func read(in directory: URL) -> ScriptDocument? {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(fileName), encoding: .utf8) else { return nil }
        return parse(text)
    }

    public func write(in directory: URL) throws {
        try render().write(to: directory.appendingPathComponent(Self.fileName), atomically: true, encoding: .utf8)
    }

    /// The keys a take's `transcript.md` carries (§3.7).
    public var frontmatterFields: [FrontmatterField] {
        var fields = [FrontmatterField(key: "daisy_script_id", value: id.uuidString)]
        if let targetSeconds { fields.append(FrontmatterField(key: "daisy_target_sec", value: String(targetSeconds))) }
        return fields
    }
}
