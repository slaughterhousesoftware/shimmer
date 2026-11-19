import AppKit
import Foundation
import Testing
@testable import Glimmer

/// PSN presence as Sony answers it (2026-11-18, TEKKEN 8 on a PS5).
private let tekkenPresence = Data("""
{"basicPresence": {"availability": "availableToPlay",
  "primaryPlatformInfo": {"onlineStatus": "online", "platform": "PS5", "lastOnlineDate": "2026-11-18T21:46:26.237Z"},
  "gameTitleInfoList": [{"npTitleId": "PPSA10595_00", "titleName": "TEKKEN\\u21228", "format": "PS5",
    "launchPlatform": "PS5",
    "conceptIconUrl": "https://image.api.playstation.com/vulcan/ap/rnd/202212/1621/rCvLik1PKDSoCaEvTIx42H3Q.png"}]}}
""".utf8)

private func presence(platform: String = "PS5", status: String = "online", games: String = "") -> Data {
    Data("""
    {"basicPresence": {"availability": "availableToPlay",
      "primaryPlatformInfo": {"onlineStatus": "\(status)", "platform": "\(platform)"}\(games)}}
    """.utf8)
}

struct PSNPresenceTests {
    @Test func aGameOnThePS5IsNamedWithItsArt() throws {
        let game = try #require(try PSNPresence.parse(tekkenPresence).ps5Game)
        #expect(game.titleID == "PPSA10595_00")
        #expect(game.name == "TEKKEN™8")
        #expect(game.artURL?.host == "image.api.playstation.com")
    }

    @Test func noGameOfflineOrAnotherConsoleIsNoGame() throws {
        #expect(try PSNPresence.parse(presence()).ps5Game == nil)
        let list = """
        , "gameTitleInfoList": [{"npTitleId": "CUSA00001_00", "titleName": "A Game", "launchPlatform": "PS4"}]
        """
        // Playing on a PS4, not the PS5.
        #expect(try PSNPresence.parse(presence(platform: "PS4", games: list)).ps5Game == nil)
        let onPS5 = """
        , "gameTitleInfoList": [{"npTitleId": "CUSA00001", "titleName": " A Game ", "format": "ps4", "launchPlatform": "PS5"}]
        """
        // A PS4 game running on the PS5 counts; its id takes the catalog's form.
        let game = try PSNPresence.parse(presence(games: onPS5)).ps5Game
        #expect(game?.titleID == "CUSA00001_00" && game?.name == "A Game" && game?.artURL == nil)
        #expect(try PSNPresence.parse(presence(status: "offline", games: onPS5)).ps5Game == nil)
        #expect(throws: (any Error).self) { try PSNPresence.parse(Data(#"{"error": {}}"#.utf8)) }
    }

    // On the PS5 with nothing running is its home screen; a game, another
    // console or offline is not.
    @Test func onThePS5WithNothingRunningIsTheHomeScreen() throws {
        #expect(try PSNPresence.parse(presence()).onPS5HomeScreen)
        #expect(try !PSNPresence.parse(tekkenPresence).onPS5HomeScreen)
        #expect(try !PSNPresence.parse(presence(platform: "PS4")).onPS5HomeScreen)
        #expect(try !PSNPresence.parse(presence(status: "offline")).onPS5HomeScreen)
    }

    @Test func theCatalogsMasterImageIsTheArtAndNotFoundIsNone() {
        let found = Data("""
        [{"id": 1, "media": {"images": [{"type": "BACKGROUND", "url": "https://image.api.playstation.com/bg.png"},
                                         {"type": "MASTER", "url": "https://image.api.playstation.com/master.png"}]}}]
        """.utf8)
        #expect(PSNCatalog.masterImageURL(from: found)?.lastPathComponent == "master.png")
        // The catalog's "not found" is an HTTP 200 with an errorCode.
        #expect(PSNCatalog.masterImageURL(from: Data(#"[{"errorCode": 3165958}]"#.utf8)) == nil)
        #expect(PSNCatalog.conceptsURL(titleID: "PPSA10595_00", country: "US", language: "en")?.absoluteString
            == "https://m.np.playstation.com/api/catalog/v2/titles/PPSA10595_00/concepts?country=US&language=en&age=99")
    }

    @Test func artComesOnlyFromSonysImageHostsSizedDown() throws {
        let art = try #require(URL(string: "https://image.api.playstation.com/vulcan/x.png"))
        #expect(PSNCatalog.isSonyImage(art))
        #expect(PSNCatalog.sized(art).query == "w=512")
        #expect(!PSNCatalog.isSonyImage(try #require(URL(string: "http://image.api.playstation.com/x.png"))))
        #expect(!PSNCatalog.isSonyImage(try #require(URL(string: "https://playstation.com.example.org/x.png"))))
    }

    @Test func aTitleIDIsAFileNameOrNothing() {
        #expect(PSNArtCache.fileName(for: "PPSA10595_00") == "PPSA10595_00.img")
        #expect(PSNArtCache.fileName(for: "../../etc/passwd") == nil)
        #expect(PSNArtCache.fileName(for: "") == nil)
    }
}

/// A keychain stand-in.
private final class MemoryStore: PSNCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: PSNCredentials?
    init(_ value: PSNCredentials? = nil) { self.value = value }
    func load() -> PSNCredentials? { lock.withLock { value } }
    func save(_ credentials: PSNCredentials) -> Bool { lock.withLock { value = credentials }; return true }
    func clear() { lock.withLock { value = nil } }
}

private func tokens(_ access: String, refresh: String? = nil) -> PSNMobileAuth.Tokens {
    PSNMobileAuth.Tokens(accessToken: access, expiresIn: 3600, refreshToken: refresh, refreshExpiresIn: 864_000, onlineID: nil)
}

private func scratchDefaults() -> UserDefaults {
    let name = "PSNTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

struct PSNMobileSessionTests {
    @Test func signedOutThereIsNoToken() async {
        let session = PSNMobileSession(store: MemoryStore(), defaults: scratchDefaults())
        #expect(await session.status() == .signedOut)
        await #expect(throws: PSNMobileSession.Failure.signedOut) { try await session.accessToken() }
    }

    @Test func theRefreshTokenMintsAnAccessTokenOnceAndItIsReused() async throws {
        let store = MemoryStore(PSNCredentials(refreshToken: "r1", refreshExpiry: nil, npsso: "n", onlineID: "kev"))
        let calls = Counter()
        let session = PSNMobileSession(store: store, refresh: { _ in calls.bump(); return tokens("a1") },
                                       mint: { _ in Issue.record("no need for the npsso"); return tokens("x") },
                                       defaults: scratchDefaults())
        #expect(try await session.accessToken() == "a1")
        #expect(try await session.accessToken() == "a1")
        #expect(calls.count == 1)
        #expect(await session.status() == .signedIn(onlineID: "kev"))
        // Sony refused it: the next one is new.
        await session.dropAccessToken()
        #expect(try await session.accessToken() == "a1")
        #expect(calls.count == 2)
    }

    @Test func aSpentRefreshTokenFallsBackToTheSessionCookieAndKeepsTheNewOne() async throws {
        let store = MemoryStore(PSNCredentials(refreshToken: "old", refreshExpiry: nil, npsso: "cookie", onlineID: nil))
        let session = PSNMobileSession(store: store, refresh: { _ in throw PSNMobileAuth.Failure.rejected },
                                       mint: { npsso in
                                           #expect(npsso == "cookie")
                                           return tokens("a2", refresh: "new")
                                       }, defaults: scratchDefaults())
        #expect(try await session.accessToken() == "a2")
        #expect(store.load()?.refreshToken == "new" && store.load()?.npsso == "cookie")
    }

    @Test func bothSpentItIsSignedOutAsExpired() async {
        let store = MemoryStore(PSNCredentials(refreshToken: "old", refreshExpiry: nil, npsso: "cookie", onlineID: nil))
        let session = PSNMobileSession(store: store, refresh: { _ in throw PSNMobileAuth.Failure.rejected },
                                       mint: { _ in throw PSNMobileAuth.Failure.rejected }, defaults: scratchDefaults())
        await #expect(throws: PSNMobileSession.Failure.signedOut) { try await session.accessToken() }
        #expect(store.load() == nil)
        #expect(await session.status() == .expired)
    }

    @Test func offlineKeepsTheSignIn() async {
        let store = MemoryStore(PSNCredentials(refreshToken: "r", refreshExpiry: nil, npsso: nil, onlineID: nil))
        let session = PSNMobileSession(store: store, refresh: { _ in throw PSNMobileAuth.Failure.unavailable },
                                       defaults: scratchDefaults())
        await #expect(throws: PSNMobileSession.Failure.unavailable) { try await session.accessToken() }
        #expect(store.load()?.refreshToken == "r")
    }

    @Test func theAppsRedirectCarriesTheCode() throws {
        let redirect = try #require(URL(string: "com.scee.psxandroid.scecompcall://redirect/?code=v3.abc&cid=1"))
        #expect(PSNMobileAuth.authorizationCode(in: redirect) == "v3.abc")
        #expect(PSNMobileAuth.authorizationCode(in: try #require(URL(string: "https://my.account.sony.com/?code=x"))) == nil)
        let ask = PSNMobileAuth.signInURL.absoluteString
        #expect(ask.hasPrefix("https://ca.account.sony.com/api/authz/v3/oauth/authorize?") && ask.contains("response_type=code"))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}

/// The card's game: one presence request, the art once, kept on disk.
@MainActor
struct PlayStationNowPlayingTests {
    private func art() -> Data {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    private func cache() -> PSNArtCache {
        PSNArtCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("psn-art-\(UUID().uuidString)"))
    }

    private func signedIn() -> PSNMobileSession {
        PSNMobileSession(store: MemoryStore(PSNCredentials(refreshToken: "r", refreshExpiry: nil, npsso: nil, onlineID: nil)),
                         refresh: { _ in tokens("token") }, defaults: scratchDefaults())
    }

    @Test func theGameArrivesWithItsNameThenItsArtFetchedOnce() async {
        let png = art(), requests = Counter(), store = cache()
        let fetch: PlayStationNowPlaying.Fetch = { request in
            if request.url == PlayStationNowPlaying.presenceURL {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
                return (tekkenPresence, 200)
            }
            // The art: no token goes to the image host.
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.url?.host == "image.api.playstation.com" && request.url?.query == "w=512")
            requests.bump()
            return (png, 200)
        }
        let nowPlaying = PlayStationNowPlaying(session: signedIn(), cache: store, fetch: fetch)
        var changes = 0
        nowPlaying.onChange = { changes += 1 }
        await nowPlaying.askNow()
        #expect(nowPlaying.game?.name == "TEKKEN™8" && nowPlaying.game?.tile?.size == NSSize(width: 42, height: 42))
        // Name first, then the art.
        #expect(changes == 2)
        await nowPlaying.askNow()
        #expect(requests.count == 1 && changes == 2)
        // Another launch: the art is on disk.
        let again = PlayStationNowPlaying(session: signedIn(), cache: store, fetch: { request in
            #expect(request.url == PlayStationNowPlaying.presenceURL)
            return (tekkenPresence, 200)
        })
        await again.askNow()
        #expect(again.game?.tile != nil)
    }

    @Test func noGameClearsItAndAFailureLeavesIt() async {
        let answer = Answer((tekkenPresence, 200))
        let nowPlaying = PlayStationNowPlaying(session: signedIn(), cache: cache(), fetch: { request in
            request.url == PlayStationNowPlaying.presenceURL ? answer.value : (Data(), 404)
        })
        await nowPlaying.askNow()
        #expect(nowPlaying.game?.name == "TEKKEN™8" && nowPlaying.game?.tile == nil)
        // Sony having a moment: what's shown stays.
        answer.value = (Data(), 503)
        await nowPlaying.askNow()
        #expect(nowPlaying.game != nil)
        answer.value = (presence(), 200)
        await nowPlaying.askNow()
        #expect(nowPlaying.game == nil)
    }

    @Test func aRefusedTokenIsReplacedOnce() async {
        let refreshes = Counter(), asked = Counter()
        let session = PSNMobileSession(store: MemoryStore(PSNCredentials(refreshToken: "r", refreshExpiry: nil, npsso: nil,
                                                                         onlineID: nil)),
                                       refresh: { _ in refreshes.bump(); return tokens("t\(refreshes.count)") },
                                       defaults: scratchDefaults())
        let nowPlaying = PlayStationNowPlaying(session: session, cache: cache(), fetch: { request in
            guard request.url == PlayStationNowPlaying.presenceURL else { return (Data(), 404) }
            asked.bump()
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer t1" ? (Data(), 401) : (tekkenPresence, 200)
        })
        await nowPlaying.askNow()
        #expect(nowPlaying.game != nil && asked.count == 2 && refreshes.count == 2)
    }

    @Test func signedOutThereIsNothingAndNothingIsAsked() async {
        let nowPlaying = PlayStationNowPlaying(session: PSNMobileSession(store: MemoryStore(), defaults: scratchDefaults()),
                                               cache: cache(), fetch: { _ in
            Issue.record("signed out: no request")
            return (Data(), 500)
        })
        await nowPlaying.askNow()
        #expect(nowPlaying.game == nil && nowPlaying.status == .signedOut)
    }
}

private final class Answer: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (Data, Int)
    init(_ value: (Data, Int)) { stored = value }
    var value: (Data, Int) {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
