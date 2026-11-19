//
//  PSNMobileSession.swift
//
//  A PSN sign-in for reading presence: the PlayStation App's OAuth client
//  (public; shipped in every copy of the PS App, used by PXPlay and psn-api),
//  whose scope can read what an account is playing. Separate from the Remote
//  Play sign-in (PlayStationAccount), which only yields the account id and
//  keeps no tokens.
//
//  Lifetimes, measured 2026-11-18: an access token lasts 1 h; the refresh
//  token 10 days from sign-in (refreshing returns the same token, its clock
//  still running); the npsso session cookie the sign-in leaves ~60 days. So
//  the npsso is kept too: once the refresh token runs out, it mints new
//  tokens without a sign-in, as PXPlay does. When both are spent the session
//  ends quietly and PlayStation settings offer "Sign In Again".
//
//  Both live in one private file (FilePSNCredentialStore - why not the
//  keychain is there), so a sign-in lasts across Shimmer's own updates.
//

import Foundation

enum PSNMobileAuth {
    static let clientID = "09515159-7237-4370-9b40-3806e67c0891"
    static let clientSecret = "ucPjka5tntB2KqsP"
    static let redirectScheme = "com.scee.psxandroid.scecompcall"
    static let redirectURI = "com.scee.psxandroid.scecompcall://redirect"
    static let scope = "psn:mobile.v2.core psn:clientapp"
    static let authorizeURL = URL(string: "https://ca.account.sony.com/api/authz/v3/oauth/authorize")!
    static let tokenURL = URL(string: "https://ca.account.sony.com/api/authz/v3/oauth/token")!

    /// Sony's sign-in, ending at the PS App's redirect with ?code=.
    static var signInURL: URL {
        var c = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
        ]
        return c.url!
    }

    /// The code in the PS App redirect ("com.scee.psxandroid.scecompcall://redirect/?code=…&cid=…").
    static func authorizationCode(in url: URL) -> String? {
        guard url.scheme?.lowercased() == redirectScheme else { return nil }
        let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "code" }?.value
        return code?.isEmpty == false ? code : nil
    }

    /// A token endpoint answer.
    struct Tokens: Sendable {
        var accessToken: String
        var expiresIn: TimeInterval
        var refreshToken: String?
        var refreshExpiresIn: TimeInterval?
        var onlineID: String?

        static func parse(_ data: Data) -> Tokens? {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String, !access.isEmpty else { return nil }
            let online = (json["id_token"] as? String).flatMap(PSNJWT.claims)?["online_id"] as? String
            return Tokens(accessToken: access, expiresIn: (json["expires_in"] as? Double) ?? 3600,
                          refreshToken: json["refresh_token"] as? String,
                          refreshExpiresIn: json["refresh_token_expires_in"] as? Double, onlineID: online)
        }
    }

    enum Failure: Error, Equatable {
        /// Sony refused the credential (invalid_grant, 400/401): it's spent.
        case rejected
        /// The network, or Sony having a moment: try again later.
        case unavailable
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    static func exchange(code: String) async throws -> Tokens {
        try await token(form: [("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI),
                               ("token_format", "jwt")])
    }

    static func refresh(_ refreshToken: String) async throws -> Tokens {
        try await token(form: [("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("scope", scope),
                               ("token_format", "jwt")])
    }

    /// The npsso cookie → an authorization code, without a web view.
    static func code(fromNPSSO npsso: String) async throws -> String {
        var request = URLRequest(url: signInURL)
        request.httpShouldHandleCookies = false
        request.setValue("npsso=\(npsso)", forHTTPHeaderField: "Cookie")
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request, delegate: NoRedirects())
        } catch {
            throw Failure.unavailable
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.unavailable }
        if (300..<400).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"),
           let url = URL(string: location) {
            if let code = authorizationCode(in: url) { return code }
            // A redirect to the sign-in page: the npsso is spent.
            throw Failure.rejected
        }
        throw http.statusCode >= 500 ? Failure.unavailable : Failure.rejected
    }

    private static func token(form: [(String, String)]) async throws -> Tokens {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        let basic = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.0, value: $0.1) }
        // "+" would read as a space in a form body.
        request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.unavailable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200, let tokens = Tokens.parse(data) { return tokens }
        throw (400..<500).contains(status) ? Failure.rejected : Failure.unavailable
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}

/// What's kept between launches.
struct PSNCredentials: Codable, Equatable, Sendable {
    var refreshToken: String
    var refreshExpiry: Date?
    var npsso: String?
    var onlineID: String?
}

protocol PSNCredentialStore: Sendable {
    /// nil when there's nothing - or nothing readable without a prompt.
    func load() -> PSNCredentials?
    @discardableResult func save(_ credentials: PSNCredentials) -> Bool
    func clear()
}

/// The sign-in as a private file beside the PS5 registrations
/// (consoles.json, which already holds Remote Play's keys the same way):
/// ~/Library/Application Support/Shimmer/PlayStation/psn-session.json, the
/// folder 0700 and the file 0600 from its first byte.
///
/// Not the keychain: Shimmer is signed with a local certificate, no Apple
/// team, and for such an app macOS ties a keychain item to the exact build
/// that saved it - the next build can't read it (-25293, measured
/// 2026-11-18 with two builds under the same certificate and identifier),
/// so every install signed PSN out. Changing an item's access needs the
/// Mac's login password, which an app doesn't have.
struct FilePSNCredentialStore: PSNCredentialStore {
    var file: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Shimmer/PlayStation/psn-session.json")

    func load() -> PSNCredentials? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(PSNCredentials.self, from: data)
    }

    func save(_ credentials: PSNCredentials) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials) else { return false }
        let fm = FileManager.default
        let folder = file.deletingLastPathComponent()
        let temp = folder.appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Private from the start, then moved into place in one step.
            guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            if rename(temp.path, file.path) != 0 { throw CocoaError(.fileWriteUnknown) }
            return true
        } catch {
            try? fm.removeItem(at: temp)
            Diag.warn("PSN sign-in not saved (\(error.localizedDescription))", "PlayStation")
            return false
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: file)
    }
}

/// Access tokens on demand, one refresh at a time.
actor PSNMobileSession {
    static let shared = PSNMobileSession(store: FilePSNCredentialStore())

    enum Failure: Error, Equatable {
        case signedOut
        case unavailable
    }

    private let store: PSNCredentialStore
    private let refresh: @Sendable (String) async throws -> PSNMobileAuth.Tokens
    private let mint: @Sendable (String) async throws -> PSNMobileAuth.Tokens
    private let now: @Sendable () -> Date

    private var loaded = false
    private var credentials: PSNCredentials?
    private var access: (token: String, expiry: Date)?
    private var inFlight: Task<String, Error>?

    /// Signed out by Sony rather than by hand, until the next sign-in - so
    /// settings say "Sign In Again" rather than "Sign In".
    private let defaults: UserDefaults
    static let expiredKey = "PSN.presenceSignInExpired"
    private(set) var expired: Bool {
        get { defaults.bool(forKey: Self.expiredKey) }
        set { defaults.set(newValue, forKey: Self.expiredKey) }
    }

    init(store: PSNCredentialStore,
         refresh: @escaping @Sendable (String) async throws -> PSNMobileAuth.Tokens = PSNMobileAuth.refresh,
         mint: @escaping @Sendable (String) async throws -> PSNMobileAuth.Tokens = {
             try await PSNMobileAuth.exchange(code: PSNMobileAuth.code(fromNPSSO: $0))
         },
         now: @escaping @Sendable () -> Date = Date.init,
         defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        self.refresh = refresh
        self.mint = mint
        self.now = now
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        credentials = store.load()
    }

    enum Status: Equatable, Sendable {
        case signedOut
        /// Sony ended it (both credentials spent): sign in again.
        case expired
        case signedIn(onlineID: String?)
    }

    func status() -> Status {
        loadIfNeeded()
        if let credentials { return .signedIn(onlineID: credentials.onlineID) }
        return expired ? .expired : .signedOut
    }

    /// A fresh sign-in: the web view's code (and npsso cookie, if it had one).
    func signIn(tokens: PSNMobileAuth.Tokens, npsso: String?) throws {
        guard let refreshToken = tokens.refreshToken else { throw Failure.unavailable }
        let fresh = PSNCredentials(refreshToken: refreshToken,
                                   refreshExpiry: tokens.refreshExpiresIn.map { now().addingTimeInterval($0) },
                                   npsso: npsso, onlineID: tokens.onlineID)
        guard store.save(fresh) else { throw Failure.unavailable }
        expired = false
        loaded = true
        credentials = fresh
        access = (tokens.accessToken, now().addingTimeInterval(tokens.expiresIn))
        inFlight = nil
    }

    func signOut() {
        expired = false
        store.clear()
        loaded = true
        credentials = nil
        access = nil
        inFlight?.cancel()
        inFlight = nil
    }

    /// Sony refused the access token (401): the next call mints another.
    func dropAccessToken() { access = nil }

    /// An access token good for at least a minute more.
    func accessToken() async throws -> String {
        loadIfNeeded()
        if let access, access.expiry.timeIntervalSince(now()) > 60 { return access.token }
        guard let credentials else { throw Failure.signedOut }
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.renew(credentials) }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    /// Refresh token first; once Sony refuses it (10 days on), the npsso.
    private func renew(_ current: PSNCredentials) async throws -> String {
        do {
            let tokens = try await refresh(current.refreshToken)
            adopt(tokens, from: current)
            return tokens.accessToken
        } catch PSNMobileAuth.Failure.rejected {
            // Spent: the npsso below, if there is one.
        } catch {
            // Offline or Sony's hiccup: keep everything, try next time.
            throw Failure.unavailable
        }
        guard let npsso = current.npsso else { return try expire(current) }
        do {
            let tokens = try await mint(npsso)
            adopt(tokens, from: current)
            Diag.info("PSN: new tokens from the saved session", "PlayStation")
            return tokens.accessToken
        } catch PSNMobileAuth.Failure.rejected {
            return try expire(current)
        } catch {
            throw Failure.unavailable
        }
    }

    private func adopt(_ tokens: PSNMobileAuth.Tokens, from current: PSNCredentials) {
        var next = current
        if let rotated = tokens.refreshToken, rotated != current.refreshToken {
            next.refreshToken = rotated
            next.refreshExpiry = tokens.refreshExpiresIn.map { now().addingTimeInterval($0) }
        }
        if let online = tokens.onlineID { next.onlineID = online }
        // A sign-out (or another sign-in) while this was in flight wins.
        guard credentials == current else { return }
        if next != current { store.save(next) }
        credentials = next
        access = (tokens.accessToken, now().addingTimeInterval(tokens.expiresIn))
    }

    private func expire(_ current: PSNCredentials) throws -> String {
        guard credentials == current else { throw Failure.unavailable }
        Diag.notice("PSN: sign-in expired - PlayStation settings offer Sign In Again", "PlayStation")
        expired = true
        store.clear()
        credentials = nil
        access = nil
        throw Failure.signedOut
    }
}
