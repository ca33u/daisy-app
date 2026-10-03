//
//  ProjectMemoryBridge.swift
//  Daisy
//
//  The Mac's side of `ProjectMemory` (DaisyCore): for the session in a
//  folder on disk, the block its summary is given — the project's notes
//  and the summaries of the earlier meetings of the same project and the
//  same tag, read from the Library that is already in memory.
//
//  The session's own project and tag are read from its transcript.md, not
//  from the Library: at the end of a recording the summary runs before
//  the Library has seen the new folder.
//

import DaisyCore
import Foundation

@MainActor
enum ProjectMemoryBridge {
    static func block(forSessionAt directory: URL) -> String? {
        let id = directory.lastPathComponent
        let stored = SessionStore.shared.sessions.first { $0.id == id }
        var folderSlug = stored?.folderSlug ?? SessionFolder.inbox.slug
        var tag = stored?.tag ?? ""
        var startedAt = stored?.startedAt ?? SessionID.parse(id) ?? Date()
        if let text = try? String(contentsOf: directory.appendingPathComponent("transcript.md"), encoding: .utf8) {
            let parsed = SessionDocument.parseFrontmatter(in: text)
            if let folder = parsed.folder, !folder.isEmpty { folderSlug = folder }
            if let t = parsed.tag { tag = t }
            if let started = SessionFrontmatter.parse(text)?.started { startedAt = started }
        }
        let project = FolderRegistryBridge.shared.project(for: folderSlug)
        let earlier = SessionStore.shared.sessions.compactMap { session -> ProjectMemory.Earlier? in
            guard let summary = session.summary, summary != .noSpeechCaptured else { return nil }
            return ProjectMemory.Earlier(
                id: session.id, title: session.title, startedAt: session.startedAt,
                folderSlug: session.folderSlug, tag: session.tag,
                summary: summary.summary, steps: summary.actionItems
            )
        }
        let related = ProjectMemory.related(
            toID: id, startedAt: startedAt, folderSlug: folderSlug, tag: tag,
            useProject: project?.usesMemory ?? true, among: earlier
        )
        let name = FolderStore.shared.allFolders.first { $0.slug == folderSlug.lowercased() }?.name
        return ProjectMemory.block(
            projectName: ProjectMemory.systemSlugs.contains(folderSlug.lowercased()) ? nil : name,
            notes: project?.notes, tag: tag.isEmpty ? nil : tag,
            project: related.project, tagged: related.tagged
        )
    }
}
