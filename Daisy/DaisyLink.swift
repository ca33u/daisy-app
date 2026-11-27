//
//  DaisyLink.swift
//  Daisy
//
//  Backlog 41: `daisy://session/<ID>` opens a meeting and
//  `daisy://project/<id>` a project in the Library — the URL templates
//  `.linked-source.json` gives readers such as Flow (LinkedSource.swift).
//  A session's ID is its directory name (session-format.md §1.1); a
//  project's is its stable id, `inbox` or `notes` (`SessionFolder.linkID`),
//  or — for a reader with no registry — its slug.
//
//  `daisy://subscription` (27.11): back from buying the Daisy Subscription
//  on mydaisy.io — opens the provider's Settings and asks the server.
//  `?status=failed` when the page said the payment wasn't completed.
//

import Foundation

nonisolated enum DaisyLink: Equatable, Sendable {
    case session(String)
    case project(String)
    /// `paymentFailed`: the page the person comes back from said the
    /// payment wasn't completed (mydaisy.io/buy/done adds `status=failed`).
    case subscription(paymentFailed: Bool)

    static let scheme = "daisy"

    static func isDaisyLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
    }

    /// Nil for anything else, an empty id, or one that would name a path
    /// (`/`, `..`) rather than a session.
    init?(_ url: URL) {
        guard Self.isDaisyLink(url), let kind = url.host?.lowercased() else { return nil }
        if kind == "subscription" {
            guard url.path.isEmpty || url.path == "/" else { return nil }
            let status = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "status" }?.value?.lowercased()
            self = .subscription(paymentFailed: status == "failed")
            return
        }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 1 else { return nil }
        let id = String(parts[0])
        guard !id.isEmpty, id != ".", id != ".." else { return nil }
        switch kind {
        case "session": self = .session(id)
        case "project": self = .project(id)
        default: return nil
        }
    }
}

@MainActor
enum DaisyLinkRouter {
    /// Opens what the link names in the main window's Library, or says
    /// why it can't. The caller has brought the main window up.
    static func open(_ url: URL) async {
        guard let link = DaisyLink(url) else {
            ToastCenter.shared.show(String(localized: "Daisy can’t open this link."), style: .warning)
            return
        }
        switch link {
        case .session(let id):
            let store = SessionStore.shared
            // Opened from another app, Daisy may have only just launched
            // and not read the library yet.
            if !store.sessions.contains(where: { $0.id == id }) {
                await store.refresh()
            }
            guard store.sessions.contains(where: { $0.id == id }) else {
                ToastCenter.shared.show(String(localized: "Daisy couldn’t find this meeting. It may have been deleted or moved."), style: .warning)
                return
            }
            AppNavigation.shared.openInLibrary(id)
        case .project(let id):
            let folders = FolderStore.shared
            guard let folder = folders.folder(linkID: id) ?? folders.existingFolder(slug: id) else {
                ToastCenter.shared.show(String(localized: "Daisy couldn’t find this project. It may have been deleted."), style: .warning)
                return
            }
            AppNavigation.shared.openProjectInLibrary(folder)
        case .subscription(let paymentFailed):
            ContextTips.openSettings(.ai, row: .daisySubscription)
            DaisyAccountStore.shared.handleReturnLink(paymentFailed: paymentFailed)
        }
    }
}
