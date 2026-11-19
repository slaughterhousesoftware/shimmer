//
//  PlayStationPairingPane.swift
//
//  Servers tab: register a PS5 found nearby (or added by address). A one-time
//  PlayStation Network sign-in supplies the account id; the console's Pair
//  Device code does the rest. Laid out like PCPairingPane.
//

import SwiftUI
import WebKit

struct PlayStationPairingPane: View {
    @Environment(AppModel.self) private var model
    let target: PCPairingTarget
    /// Back to the welcome page, when there is no sidebar to leave by.
    var cancel: (() -> Void)? = nil
    let paired: (String) -> Void

    @State private var account = PlayStationStore.shared.account
    @State private var pin = ""
    @State private var isPairing = false
    @State private var error: String?
    @State private var showSignIn = false
    /// What the console says while the code step is up (checked every few
    /// seconds), so a resting PS5 is called out before a code is typed.
    @State private var consoleProblem: PlayStationRegistration.Failure?
    /// The error shown is the console's state (resting, silent), not the
    /// code: it goes once the console is ready.
    @State private var errorIsConsoleState = false
    @FocusState private var pinFocused: Bool

    private var digits: String { pin.filter(\.isNumber) }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Image(systemName: "playstation.logo")
                            .font(.system(size: 28, weight: .regular))
                            .foregroundStyle(.secondary)
                            .frame(width: 64, height: 64)
                            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                            .padding(.bottom, 4)
                            .accessibilityHidden(true)
                        Text(target.name)
                            .font(.system(size: 18, weight: .semibold))
                        Text(target.address).font(.system(size: 12)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if account == nil {
                        signInStep
                    } else {
                        codeStep
                    }
                    if let error {
                        PCConnectionErrorBanner(message: error)
                            .multilineTextAlignment(.leading)
                    }
                }
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .padding(24)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        // Which account the console is paired to, out of the way at the
        // foot of the pane (it sat between Pair and Cancel).
        .safeAreaInset(edge: .bottom) {
            if let onlineID = account?.onlineID {
                HStack(spacing: 4) {
                    Text("Signed in as \(onlineID).").foregroundStyle(.secondary)
                    Button("Use Another Account") { account = nil }
                        .buttonStyle(.link)
                        .disabled(isPairing)
                }
                .font(.system(size: 11))
                .padding(.bottom, 14)
            }
        }
        .sheet(isPresented: $showSignIn) {
            PlayStationSignInSheet { identity in
                PlayStationStore.shared.setAccount(identity)
                account = identity
                showSignIn = false
                error = nil
            } failed: { message in
                showSignIn = false
                error = message
            } cancel: {
                showSignIn = false
            }
        }
    }

    private var signInStep: some View {
        VStack(spacing: 16) {
            Text("Sign in to PlayStation Network once. The PS5 registers this Mac to your account.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            buttons {
                Button("Sign In to PlayStation Network…") { showSignIn = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var codeStep: some View {
        VStack(spacing: 16) {
            Text("On the PS5, open Settings › System › Remote Play › Pair Device, and enter the code it shows.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let consoleProblem, error == nil {
                Label(consoleProblem.localizedDescription, systemImage: "exclamationmark.circle.fill")
                    .labelStyle(ConsoleProblemLabelStyle())
            }
            // A word, not digits: "12345678" in grey read as a code already in.
            TextField("8-digit code", text: $pin)
                .font(.system(size: 28, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .focused($pinFocused)
                .disabled(isPairing)
                .onSubmit(pair)
                .onChange(of: pin) { _, value in
                    let clean = String(value.filter(\.isNumber).prefix(8))
                    if clean != value { pin = clean }
                }
                .accessibilityLabel("Pair Device code")
            if isPairing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Pairing with the PS5…").foregroundStyle(.secondary)
                }
            } else {
                buttons {
                    Button("Pair", action: pair)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(digits.count != 8)
                }
            }
        }
        .onAppear { pinFocused = true }
        .task(id: isPairing) {
            guard !isPairing else { return }
            while !Task.isCancelled {
                let status = await PlayStationDiscovery.probe(address: target.address)
                guard !Task.isCancelled else { return }
                consoleProblem = PlayStationRegistration.precheck(status)
                if consoleProblem == nil, errorIsConsoleState {
                    error = nil
                    errorIsConsoleState = false
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// The step's button, with Cancel to its left when there is somewhere
    /// to go back to (the welcome page), as a dialog's.
    private func buttons(@ViewBuilder _ primary: () -> some View) -> some View {
        HStack(spacing: 12) {
            if let cancel {
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
            primary()
        }
    }

    private func pair() {
        guard !isPairing, digits.count == 8, let account else { return }
        isPairing = true
        error = nil
        errorIsConsoleState = false
        let address = target.address
        Task {
            do {
                if let problem = PlayStationRegistration.precheck(await PlayStationDiscovery.probe(address: address)) {
                    consoleProblem = problem
                    isPairing = false
                    pin = ""
                    self.error = problem.localizedDescription
                    errorIsConsoleState = true
                    pinFocused = true
                    return
                }
                var console = try await PlayStationRegistration.register(
                    address: address, accountID: account.accountID, pin: digits)
                if let existing = PlayStationStore.shared.consoles.first(where: { $0.id == console.id }) {
                    console.lastStreamed = existing.lastStreamed
                }
                PlayStationStore.shared.upsert(console)
                Diag.notice("PS5: registered \(console.nickname)", "PlayStation")
                model.loadHosts()
                isPairing = false
                paired(console.hostID)
            } catch {
                isPairing = false
                pin = ""
                self.error = error.localizedDescription
                pinFocused = true
            }
        }
    }
}

/// Sony's sign-in page in a web view. Stops at the Remote Play redirect and
/// trades its code for the account id.
struct PlayStationSignInSheet: View {
    let signedIn: (PlayStationAccount.Identity) -> Void
    let failed: (String) -> Void
    let cancel: () -> Void
    @State private var exchanging = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PlayStation Network").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            PlayStationSignInWebView(url: PlayStationAccount.signInURL,
                                     code: PlayStationAccount.authorizationCode(in:)) { code in
                guard !exchanging else { return }
                exchanging = true
                Task {
                    do {
                        signedIn(try await PlayStationAccount.identity(forCode: code))
                    } catch {
                        failed(error.localizedDescription)
                    }
                }
            }
            // Sony's page stays put once it has handed over; say what's
            // happening instead of leaving it there to be clicked again.
            .overlay {
                if exchanging {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Signing in…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
                }
            }
        }
        .frame(width: 520, height: 680)
    }
}

/// Sony's sign-in page in a fresh, cookie-less session; the redirect's
/// authorization code is handed back and the page goes no further.
private struct PlayStationSignInWebView: NSViewRepresentable {
    let url: URL
    /// The code in a redirect URL, if this is the redirect.
    let code: (URL) -> String?
    let finished: (_ code: String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(code: code, finished: finished) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // A fresh session each time: no Sony cookies linger in the app.
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let code: (URL) -> String?
        let finished: (String) -> Void

        init(code: @escaping (URL) -> String?, finished: @escaping (String) -> Void) {
            self.code = code
            self.finished = finished
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, let code = code(url) else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            finished(code)
        }
    }
}

/// A short warning about the console, in the step's own type: an orange
/// mark before secondary text.
private struct ConsoleProblemLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.foregroundStyle(.orange)
            configuration.title.foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
