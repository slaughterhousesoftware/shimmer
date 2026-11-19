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
    let paired: (String) -> Void

    @State private var account = PlayStationStore.shared.account
    @State private var pin = ""
    @State private var isPairing = false
    @State private var error: String?
    @State private var showSignIn = false
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
            Button("Sign In to PlayStation Network…") { showSignIn = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var codeStep: some View {
        VStack(spacing: 16) {
            Text("On the PS5, open Settings › System › Remote Play › Pair Device, and enter the code it shows.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("12345678", text: $pin)
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
                    Text("Registering with the PS5…").foregroundStyle(.secondary)
                }
            } else {
                Button("Pair PS5", action: pair)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(digits.count != 8)
            }
            if let onlineID = account?.onlineID {
                Button("Signed in as \(onlineID) - use another account") {
                    account = nil
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
        .onAppear { pinFocused = true }
    }

    private func pair() {
        guard !isPairing, digits.count == 8, let account else { return }
        isPairing = true
        error = nil
        let address = target.address
        Task {
            do {
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
                if exchanging { ProgressView().controlSize(.small) }
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            PSNSignInWebView(url: PlayStationAccount.signInURL, code: PlayStationAccount.authorizationCode(in:)) { code, npsso in
                guard !exchanging else { return }
                exchanging = true
                // The same sign-in can show the PS5's game in the menu bar
                // (PlayStationNowPlaying): its session cookie is enough.
                if let npsso { Task { await PlayStationNowPlaying.shared.signIn(npsso: npsso) } }
                Task {
                    do {
                        signedIn(try await PlayStationAccount.identity(forCode: code))
                    } catch {
                        failed(error.localizedDescription)
                    }
                }
            }
        }
        .frame(width: 520, height: 680)
    }
}
