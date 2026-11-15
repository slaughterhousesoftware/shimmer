//
//  PlayStationAccount.swift
//
//  The PSN account a PS5 registration is made for. Registration needs only the
//  account's numeric ID (8 bytes, sent base64), which a one-time PSN sign-in
//  provides: Sony's own Remote Play OAuth page, the same client chiaki-ng uses.
//  Shimmer keeps the ID, not the tokens - nothing else needs them.
//

import Foundation

enum PlayStationAccount {
    // Sony's Remote Play client (public; shipped in every Remote Play client).
    static let clientID = "ba495a24-818c-472b-b12d-ff231c1b5745"
    static let clientSecret = "mvaiZkRsAsI1IBkY"
    static let redirectURI = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
    static let scope = "psn:clientapp referenceDataService:countryConfig.read "
        + "pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update"
    static let tokenURL = URL(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token")!

    static var signInURL: URL {
        var c = URLComponents(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize")!
        c.queryItems = [
            URLQueryItem(name: "service_entity", value: "urn:service-entity:psn"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "request_locale", value: "en_US"),
            URLQueryItem(name: "ui", value: "pr"),
            URLQueryItem(name: "service_logo", value: "ps"),
            URLQueryItem(name: "layout_type", value: "popup"),
            URLQueryItem(name: "smcid", value: "remoteplay"),
            URLQueryItem(name: "prompt", value: "always"),
            URLQueryItem(name: "PlatformPrivacyWs1", value: "minimal"),
        ]
        return c.url!
    }

    /// The authorization code in a redirect URL, if this is the redirect.
    static func authorizationCode(in url: URL) -> String? {
        guard url.absoluteString.hasPrefix(redirectURI) else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "code" }?.value
    }

    struct Identity: Codable, Equatable, Sendable {
        /// base64 of the 8-byte little-endian numeric account id.
        var accountID: String
        var onlineID: String?
    }

    enum Failure: LocalizedError {
        case exchange(String)
        var errorDescription: String? {
            switch self {
            case .exchange(let detail): return "PlayStation Network sign-in didn't finish: \(detail)"
            }
        }
    }

    /// Code → access token → account id. The token is dropped afterwards.
    static func identity(forCode code: String) async throws -> Identity {
        let basic = "Basic " + Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue(basic, forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (tokenData, _) = try await URLSession.shared.data(for: request)
        guard let token = (try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any])?["access_token"] as? String
        else {
            throw Failure.exchange("Sony didn't return a token")
        }
        var infoRequest = URLRequest(url: tokenURL.appendingPathComponent(token))
        infoRequest.setValue(basic, forHTTPHeaderField: "Authorization")
        let (infoData, _) = try await URLSession.shared.data(for: infoRequest)
        guard let info = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any],
              let userID = (info["user_id"] as? String).flatMap(UInt64.init)
        else {
            throw Failure.exchange("Sony didn't return the account id")
        }
        return Identity(accountID: accountIDBase64(userID), onlineID: info["online_id"] as? String)
    }

    static func accountIDBase64(_ userID: UInt64) -> String {
        withUnsafeBytes(of: userID.littleEndian) { Data($0) }.base64EncodedString()
    }
}
