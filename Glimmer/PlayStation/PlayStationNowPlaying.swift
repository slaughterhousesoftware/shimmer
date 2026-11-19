//
//  PlayStationNowPlaying.swift
//
//  The game running on the PS5, for the menu bar's Now Playing card: its
//  name and its square art in the card's tile, in place of "PlayStation 5"
//  and the PlayStation mark.
//
//  Where it comes from: the signed-in PSN account's presence
//  (PSNGameInfo.swift has the request and why the console itself can't be
//  asked). So it is that account's game on a PS5 - right for the account
//  Remote Play streams as, blank for a housemate playing under their own.
//
//  When it asks: when the menu opens, and every 45 s while a PS5 stream is
//  live so the card is already right the next time. Never otherwise - an
//  idle Shimmer makes no PSN requests. One request is ~1 KB; the art is
//  fetched once per game and kept on disk (PSNArtCache).
//
//  Signed out, offline, Sony down, no game: the card is what it was before
//  this file, with no error anywhere - the feature is an extra.
//

import AppKit
import Observation
import SwiftUI
import WebKit

@MainActor
@Observable
final class PlayStationNowPlaying {
    static let shared = PlayStationNowPlaying()

    struct Game: Equatable {
        var titleID: String
        var name: String
        /// The art as the card's tile; nil until it has arrived.
        var tile: NSImage?

        static func == (a: Game, b: Game) -> Bool {
            a.titleID == b.titleID && a.name == b.name && (a.tile == nil) == (b.tile == nil)
        }
    }

    /// The game on the PS5 as last asked, if the asking is recent.
    private(set) var game: Game?
    /// The PS5 shows its home screen (the account is on it, nothing running).
    private(set) var homeScreen = false
    /// For PlayStation settings: signed in, out, or ended by Sony.
    private(set) var status: PSNMobileSession.Status = .signedOut

    /// `game` changed (the open menu redraws its card).
    @ObservationIgnored var onChange: (() -> Void)?

    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, Int)

    @ObservationIgnored private let session: PSNMobileSession
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let cache: PSNArtCache
    @ObservationIgnored private var lastAsked: Date?
    @ObservationIgnored private var asking: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?

    nonisolated static let presenceURL = URL(string:
        "https://m.np.playstation.com/api/userProfile/v1/internal/users/me/basicPresences?type=primary")!
    /// While a PS5 stream is live.
    nonisolated static let pollInterval: TimeInterval = 45
    /// A game older than this is not shown without asking again.
    nonisolated static let staleAfter: TimeInterval = 90

    init(session: PSNMobileSession = .shared, cache: PSNArtCache = .shared, fetch: @escaping Fetch = PlayStationNowPlaying.network) {
        self.session = session
        self.cache = cache
        self.fetch = fetch
        Task { await self.loadStatus() }
    }

    /// No cookies, no cache on disk, 15 s at most.
    nonisolated static let network: Fetch = { request in
        let (data, response) = try await urlSession.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    nonisolated private static let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    // MARK: Asking

    /// The menu is opening: what's shown must be recent, and is asked again.
    func menuWillOpen() {
        if let lastAsked, Date().timeIntervalSince(lastAsked) > Self.staleAfter, timer == nil {
            setGame(nil)
            setHomeScreen(false)
        }
        ask(unlessAskedWithin: 5)
    }

    /// A PS5 stream went live, or ended.
    func setStreaming(_ streaming: Bool) {
        guard streaming != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard streaming else { return }
        ask(unlessAskedWithin: 5)
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ask(unlessAskedWithin: 5) }
        }
        // Also while a menu or a slider is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func ask(unlessAskedWithin seconds: TimeInterval) {
        if let lastAsked, Date().timeIntervalSince(lastAsked) < seconds { return }
        guard asking == nil else { return }
        lastAsked = Date()
        asking = Task { [weak self] in
            await self?.askNow()
            self?.asking = nil
        }
    }

    /// One presence request, and the art if the game is new. For tests too.
    func askNow() async {
        let presence: PSNPresence
        do {
            presence = try await self.presence()
        } catch PSNMobileSession.Failure.signedOut {
            await loadStatus()
            setGame(nil)
            setHomeScreen(false)
            return
        } catch {
            // Offline, or Sony having a moment: what's shown stays.
            return
        }
        setHomeScreen(presence.onPS5HomeScreen)
        guard let playing = presence.ps5Game else {
            setGame(nil)
            return
        }
        if game?.titleID == playing.titleID, game?.name == playing.name, game?.tile != nil { return }
        let cached = cache.data(for: playing.titleID).flatMap { PSNGameTile.image(from: $0) }
        setGame(Game(titleID: playing.titleID, name: playing.name, tile: cached))
        guard cached == nil, let art = await art(for: playing) else { return }
        cache.store(art, for: playing.titleID)
        // Still that game: a slow download mustn't overwrite a newer answer.
        guard game?.titleID == playing.titleID, let tile = PSNGameTile.image(from: art) else { return }
        setGame(Game(titleID: playing.titleID, name: playing.name, tile: tile))
    }

    private func presence() async throws -> PSNPresence {
        for attempt in 0..<2 {
            let token = try await session.accessToken()
            var request = URLRequest(url: Self.presenceURL)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, status) = try await fetch(request)
            if status == 401, attempt == 0 {
                await session.dropAccessToken()
                continue
            }
            guard status == 200 else { throw PSNMobileSession.Failure.unavailable }
            return try PSNPresence.parse(data)
        }
        throw PSNMobileSession.Failure.unavailable
    }

    /// Presence names the art; when it doesn't, the catalog does.
    private func art(for game: PSNGame) async -> Data? {
        var url = game.artURL
        if url == nil, let lookup = PSNCatalog.conceptsURL(titleID: game.titleID, country: "US", language: "en"),
           let (data, status) = try? await fetch(URLRequest(url: lookup)), status == 200 {
            url = PSNCatalog.masterImageURL(from: data)
        }
        guard let url, PSNCatalog.isSonyImage(url),
              let (data, status) = try? await fetch(URLRequest(url: PSNCatalog.sized(url))),
              status == 200, data.count < 4_000_000, NSImage(data: data)?.isValid == true
        else { return nil }
        return data
    }

    private func setGame(_ new: Game?) {
        guard new != game else { return }
        game = new
        onChange?()
    }

    private func setHomeScreen(_ new: Bool) {
        guard new != homeScreen else { return }
        homeScreen = new
        onChange?()
    }

    // MARK: Signing in and out

    func loadStatus() async {
        status = await session.status()
    }

    /// From the sign-in sheet: the PS App redirect's code, and the session
    /// cookie the sign-in left (it renews the tokens for ~60 days).
    func signIn(code: String, npsso: String?) async throws {
        let tokens = try await PSNMobileAuth.exchange(code: code)
        try await session.signIn(tokens: tokens, npsso: npsso)
        await loadStatus()
        lastAsked = nil
        ask(unlessAskedWithin: 0)
    }

    /// From the Remote Play sign-in (pairing a PS5): its session cookie is
    /// enough to sign this in too, with no second sheet. Best effort.
    func signIn(npsso: String) async {
        if case .signedIn = await session.status() { return }
        guard let code = try? await PSNMobileAuth.code(fromNPSSO: npsso) else { return }
        try? await signIn(code: code, npsso: npsso)
    }

    func signOut() async {
        await session.signOut()
        await loadStatus()
        setGame(nil)
    }
}

// MARK: - PlayStation settings

/// The PS5 page's "Now Playing" section: the PSN sign-in the menu bar's card
/// reads the running game through.
struct PlayStationNowPlayingSection: View {
    @State private var nowPlaying = PlayStationNowPlaying.shared
    @State private var failure: String?

    var body: some View {
        Section {
            SettingsRow("Game in the menu bar") {
                switch nowPlaying.status {
                case .signedIn(let onlineID):
                    Text(onlineID.map { "Signed in as \($0)" } ?? "Signed in").foregroundStyle(.secondary)
                    Button("Sign Out") { Task { await nowPlaying.signOut() } }
                case .expired:
                    Button("Sign In Again…") { signIn() }
                case .signedOut:
                    Button("Sign In…") { signIn() }
                }
            }
            .help("Shows the game running on the PS5, with its artwork, in the menu bar's card. "
                + "Shimmer asks PlayStation Network what your account is playing.")
            if let failure {
                Text(failure).font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            FormSectionHeader("Now Playing")
        }
        .task { await nowPlaying.loadStatus() }
    }

    private func signIn() {
        failure = nil
        PSNPresenceSignInSheet.present { failure = $0 }
    }
}

/// Sony's sign-in page in a web view, for the PlayStation App's client:
/// stops at the app's redirect and signs PlayStationNowPlaying in.
struct PSNPresenceSignInSheet: View {
    /// nil: signed in, or cancelled. Otherwise what went wrong.
    let finished: (String?) -> Void
    @State private var exchanging = false

    /// As an AppKit sheet on the settings window: it belongs to the window,
    /// not to a row of the page's Form, which SwiftUI may rebuild under it.
    @MainActor
    static func present(_ done: @escaping (String?) -> Void) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil else { return }
        var sheet: NSWindow?
        let view = PSNPresenceSignInSheet { failure in
            if let sheet { window.endSheet(sheet) }
            sheet = nil
            done(failure)
        }
        let host = NSHostingController(rootView: view)
        let panel = NSWindow(contentViewController: host)
        panel.setContentSize(NSSize(width: 520, height: 680))
        sheet = panel
        window.beginSheet(panel)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PlayStation Network").font(.system(size: 13, weight: .semibold))
                Spacer()
                if exchanging { ProgressView().controlSize(.small) }
                Button("Cancel") { finished(nil) }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            PSNSignInWebView(url: PSNMobileAuth.signInURL, code: PSNMobileAuth.authorizationCode(in:)) { code, npsso in
                guard !exchanging else { return }
                exchanging = true
                Task {
                    do {
                        try await PlayStationNowPlaying.shared.signIn(code: code, npsso: npsso)
                        finished(nil)
                    } catch {
                        finished("PlayStation Network sign-in didn't finish. Try again.")
                    }
                }
            }
        }
        .frame(width: 520, height: 680)
    }
}

/// A Sony sign-in in a fresh, non-persistent web view: reports the redirect's
/// authorization code, with the `npsso` session cookie the sign-in left.
struct PSNSignInWebView: NSViewRepresentable {
    let url: URL
    /// The code in a redirect URL, if this is the redirect.
    let code: (URL) -> String?
    let finished: (_ code: String, _ npsso: String?) -> Void

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
        let finished: (String, String?) -> Void

        init(code: @escaping (URL) -> String?, finished: @escaping (String, String?) -> Void) {
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
            let finished = finished
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let npsso = cookies.first { $0.name == "npsso" && $0.domain.hasSuffix("sony.com") }?.value
                finished(code, npsso?.isEmpty == false ? npsso : nil)
            }
        }
    }
}
