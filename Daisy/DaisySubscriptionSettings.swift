// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  DaisySubscriptionSettings.swift
//  Daisy
//
//  Settings → AI → Provider «Подписка Daisy» (27.11, С-3): the account, the
//  subscription's state and the way to buy it on the website, and the
//  sign-in sheet. The same ways in, in the same order and words, as the
//  iPhone's SignInView: Apple, Google, an email code.
//
//  Never two purchases: with a live subscription — from the App Store on
//  the iPhone or from the website — there is no button to buy, only where
//  to manage it.
//

import AuthenticationServices
import SwiftUI

struct DaisySubscriptionRows: View {
    @Bindable private var store: DaisyAccountStore
    @State private var showSignIn = false
    @State private var askDisclosure = false
    @State private var confirmDelete = false
    @State private var error: String?
    @State private var busy = false
    /// Called when the account or the subscription changed, so readiness is asked again.
    let changed: @MainActor () async -> Void

    /// `store`: the app's own account, or a test's.
    init(store: DaisyAccountStore = .shared, changed: @escaping @MainActor () async -> Void) {
        self.store = store
        self.changed = changed
    }

    var body: some View {
        // The sheet, the alerts and the refresh hang on one row: on a
        // Group they would be applied to every row of it.
        accountRow
            .sheet(isPresented: $showSignIn) {
                DaisySignInSheet(store: store) {
                    showSignIn = false
                    Task { await changed() }
                }
            }
            // With this provider text goes through our server: said and
            // agreed to before the first sign-in. The sign-in sheet opens
            // only from here, after the yes.
            .alert("Send text through Daisy's server?", isPresented: $askDisclosure) {
                Button("Cancel", role: .cancel) {}
                Button("Continue") {
                    store.acknowledgeCloudDisclosure()
                    if !store.isSignedIn { showSignIn = true }
                    Task { await changed() }
                }
            } message: {
                Text("With the Daisy Subscription, the text Daisy's AI works on — meetings, dictations, Daisy key commands, briefs — goes through Daisy's server to Anthropic. The server keeps none of it. Names and contacts are replaced before sending only if “Protect sensitive data before cloud AI” is on")
            }
            .confirmationDialog("Delete your Daisy account?", isPresented: $confirmDelete) {
                Button("Delete account", role: .destructive) { run { try await store.deleteAccount() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your email and ways to sign in are deleted from Daisy's server. A paid subscription isn't cancelled by this: cancel it where you bought it. Recordings on this Mac stay")
            }
            .task(id: store.isSignedIn) {
                guard store.isSignedIn else { return }
                await store.refreshAccount()
                await store.refreshSubscription()
                await changed()
            }
        if store.isSignedIn, !store.hasAcknowledgedCloudDisclosure {
            // Signed in, the yes not given (a session kept from before the
            // question existed): nothing is sent until it is.
            LabeledContent("Sending text") {
                Button("Confirm sending text…") { askDisclosure = true }
                    .buttonStyle(.daisyPrimary)
            }
        }
        if store.isSignedIn { subscriptionRows }
        if let error {
            Text(error)
                .font(.caption)
                .foregroundStyle(Color.daisyWarning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Account

    @ViewBuilder
    private var accountRow: some View {
        if let account = store.account, store.isSignedIn {
            LabeledContent("Daisy account") {
                HStack(spacing: 10) {
                    // Keyed: «Вход выполнен», not the shared «Подключено».
                    Text(account.email ?? String(localized: "daisyAccount.signedIn", defaultValue: "Signed in"))
                    Menu {
                        Button("Sign out") {
                            store.signOut()
                            Task { await changed() }
                        }
                        Button("Delete account…", role: .destructive) { confirmDelete = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Account actions")
                }
            }
        } else {
            LabeledContent("Daisy account") {
                Button("Sign in") {
                    if store.hasAcknowledgedCloudDisclosure { showSignIn = true } else { askDisclosure = true }
                }
                .buttonStyle(.daisyPrimary)
            }
        }
    }

    // MARK: Subscription

    @ViewBuilder
    private var subscriptionRows: some View {
        if let status = store.subscription {
            if status.active {
                let source = status.primary
                LabeledContent("Subscription") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(source.map(Self.activeLine) ?? String(localized: "Active"))
                        if source?.kind == .appStore {
                            Text("Bought on iPhone, managed in the App Store")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let manage = source?.manageURL {
                    LabeledContent("") {
                        Button("Manage subscription") { NSWorkspace.shared.open(manage) }
                            .buttonStyle(.bordered)
                    }
                }
            } else {
                LabeledContent("Subscription") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Not subscribed")
                        Text(status.trialRemaining > 0
                             ? String(localized: "Free summaries left: \(status.trialRemaining) of 3")
                             : String(localized: "The free summaries are used"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if store.awaitingPayment {
                    // Never a dead end: the browser tab can be closed before
                    // paying, so the page opens again from here and the wait
                    // can be called off. After Cancel the store keeps asking
                    // quietly, so a payment that did go through still shows.
                    // No page to reopen once the return link came
                    // (`daisy://subscription`): that page was paid.
                    LabeledContent(String(localized: "daisySubscription.plan", defaultValue: "Plan")) {
                        VStack(alignment: .trailing, spacing: 8) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Waiting for the payment…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 8) {
                                if store.pendingCheckout != nil {
                                    Button("Open the payment page again") { store.reopenCheckout() }
                                        .buttonStyle(.bordered)
                                }
                                Button("Cancel") {
                                    Task {
                                        await store.cancelCheckout()
                                        await changed()
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                } else if store.hasAcknowledgedCloudDisclosure {
                    // Not before the yes to sending text: one thing to
                    // decide at a time, and it comes first.
                    // «Plan» is keyed: a noun like the rows above it
                    // («Тариф»). So is the button: in Russian it takes the
                    // verb of the row above («Не оформлена» → «Оформить
                    // подписку»), not the «Подключить» of connecting an
                    // account.
                    //
                    // A choice, then a button (Egor 27.11): as two price
                    // buttons the row read as a choice between plans, and
                    // a click went straight to the payment. Now the prices
                    // only choose, and one button, saying where it leads,
                    // opens the payment page.
                    LabeledContent(String(localized: "daisySubscription.plan", defaultValue: "Plan")) {
                        VStack(alignment: .trailing, spacing: 8) {
                            // The label is hidden, and still what VoiceOver reads.
                            // The plan picked is the store's (`chosenPlan`):
                            // «What's New» hands its choice over to this row.
                            Picker(String(localized: "daisySubscription.plan", defaultValue: "Plan"), selection: $store.chosenPlan) {
                                Text(DaisyAccountStore.Plan.month.priceLine).tag(DaisyAccountStore.Plan.month)
                                Text(DaisyAccountStore.Plan.year.priceLine).tag(DaisyAccountStore.Plan.year)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            HStack(spacing: 10) {
                                // One line: wrapped, it took the row's
                                // width and pushed the button off the
                                // trailing edge.
                                Text("The payment page opens in your browser")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .fixedSize()
                                Button(String(localized: "daisySubscription.subscribe", defaultValue: "Subscribe")) {
                                    // The plan as it stands at the click.
                                    let picked = store.chosenPlan
                                    run { try await store.checkout(picked) }
                                }
                                .buttonStyle(.daisyPrimary)
                                .accessibilityHint(Text("The payment page opens in your browser"))
                            }
                        }
                        .disabled(busy)
                    }
                }
            }
        } else if store.subscriptionCheckFailed {
            LabeledContent("Subscription") {
                HStack(spacing: 8) {
                    Text("Daisy's server can't be reached")
                        .font(.caption)
                        .foregroundStyle(Color.daisyWarning)
                    Button("Retry") { Task { await store.refreshSubscription(); await changed() } }
                        .buttonStyle(.bordered)
                }
            }
        } else {
            LabeledContent("Subscription") { ProgressView().controlSize(.small) }
        }
    }

    static func activeLine(_ source: DaisySubscriptionStatus.Source) -> String {
        guard let date = source.renewsAt?.formatted(date: .long, time: .omitted) else {
            return String(localized: "Active")
        }
        if source.willRenew == false { return String(localized: "Active until \(date), won't renew") }
        return String(localized: "Active, renews \(date)")
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        error = nil
        busy = true
        Task {
            defer { busy = false }
            do { try await work() } catch { self.error = error.localizedDescription }
            await changed()
        }
    }
}

#if DEBUG
extension DaisySubscriptionRows {
    /// The sign-in sheet's content, for looking at it outside the app.
    static func signInSheetForInspection(store: DaisyAccountStore) -> some View { DaisySignInSheet(store: store) {} }
}
#endif

// MARK: - Sign in

private struct DaisySignInSheet: View {
    /// The account being signed in to: the rows' own.
    let store: DaisyAccountStore
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var nonce = DaisyAccountStore.makeNonce()
    @State private var error: String?
    @State private var busy = false
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var work: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sign in to Daisy")
                    .font(.title2.weight(.semibold))
                Text("The Daisy Subscription belongs to your account, not to this Mac. Recording and transcription work without signing in")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Group {
                if codeSent { codeStep } else { ways }
            }
            .disabled(busy)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.daisyWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                // Never disabled: Google's page can be left open in the browser.
                Button("Cancel") {
                    work?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onDisappear { work?.cancel() }
    }

    @ViewBuilder
    private var ways: some View {
        VStack(spacing: 10) {
            if DaisyAccountStore.appleSignInAvailable {
                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.email]
                    request.nonce = DaisyAccountStore.sha256Hex(nonce)
                } onCompletion: { result in
                    apple(result)
                }
                .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
                .frame(height: 32)
            }
            Button {
                run { if try await store.signInWithGoogle() { onDone() } }
            } label: {
                Text("Continue with Google").frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            Divider().padding(.vertical, 4)

            // Verbatim: as a localized key the address turns into a link.
            TextField("Email", text: $email, prompt: Text(verbatim: "name@example.com"))
                .textFieldStyle(.roundedBorder)
                .textContentType(.emailAddress)
                .onSubmit(sendCode)
            Button(action: sendCode) {
                Text("Continue with email").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(!email.contains("@"))
        }
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("We sent a 6-digit code to \(email)")
                .fixedSize(horizontal: false, vertical: true)
            TextField("Code", text: $code, prompt: Text(verbatim: "123456"))
                .textFieldStyle(.roundedBorder)
                .textContentType(.oneTimeCode)
                .onSubmit(verify)
            HStack {
                Button("Use another email") {
                    codeSent = false
                    code = ""
                    error = nil
                }
                .buttonStyle(.link)
                Spacer()
                Button("Sign in", action: verify)
                    .buttonStyle(.daisyPrimary)
                    .disabled(code.filter(\.isNumber).count != 6)
            }
        }
    }

    private func sendCode() {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@") else { return }
        run {
            try await store.startEmail(address)
            email = address
            codeSent = true
        }
    }

    private func verify() {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { return }
        run {
            try await store.verifyEmail(email, code: digits)
            onDone()
        }
    }

    private func apple(_ result: Result<ASAuthorization, any Error>) {
        switch result {
        case .failure(let failure):
            if (failure as? ASAuthorizationError)?.code != .canceled {
                error = String(localized: "Couldn't sign in. Try again")
            }
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                error = String(localized: "Couldn't sign in. Try again")
                return
            }
            let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
            let raw = nonce
            run {
                try await store.signInWithApple(identityToken: token, authorizationCode: code, rawNonce: raw)
                onDone()
            }
            nonce = DaisyAccountStore.makeNonce()
        }
    }

    private func run(_ job: @escaping @MainActor () async throws -> Void) {
        error = nil
        busy = true
        work = Task {
            defer { busy = false }
            do { try await job() } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}
