//
//  StreamFailureCopy.swift
//
//  Every sentence the app shows when a stream doesn't start, in one place:
//  which failure it is decides what the user is told to do about it. A PC that
//  is asleep, a PC whose firewall drops the stream port, a PS5 that is busy
//  with another device and a PS5 that has forgotten this Mac are four
//  different problems with four different fixes; one "make sure it's awake"
//  for all of them sent people to the power button for the wrong three.
//
//  Pure functions of the error and the machine's name, so the whole table is
//  checkable without a host (StreamFailureCopyTests).
//

import Foundation

enum StreamFailureCopy {

    /// The sentence for a stream that never started.
    static func connect(_ error: Error, hostName: String) -> String {
        let unreachable = "Couldn't reach \(hostName). Make sure it's awake and on the same network."
        guard let streamError = error as? StreamError else {
            // Any non-StreamError on the start path is unexpected - the control
            // layer always throws StreamError - so treat it as a reach failure,
            // by far the most likely cause.
            return unreachable
        }
        switch streamError {
        case .hostUnreachable(let detail):
            // The network layer crafts user-facing guidance for the cases it
            // can prove (cert mismatch / not-paired disambiguation) - dropping
            // that for generic "is it awake" copy buries the real fix.
            // "Restart Sunshine" marks the wedged-HTTPS-listener verdict
            // (NetworkClient.classifyPairedPathFailure): the box is awake, so
            // the "is it awake" copy would send the user to the wrong fix.
            if detail.contains("cert") || detail.contains("Restart Sunshine") { return detail }
            return unreachable
        case .sessionFailed, .binaryNotFound, .truncatedRead:
            // Genuinely never reached the host / handshake aborted before
            // establishment (a truncated control read = the host dropped mid-
            // response) → asleep guidance is honest.
            return unreachable
        case .pairingFailed(let detail) where detail.contains("pair it again"):
            // The paired-path classification (NetworkClient.
            // classifyPairedPathFailure) - already the actionable, host-named
            // sentence (401 or a TLS-level rejection of our client cert).
            return detail
        case .pairingFailed, .pairingRejected:
            // The host answered but pairing failed - point the user at the
            // real fix, not at the power switch.
            return "\(hostName) doesn't recognise this Mac any more. Remove it and add it again to pair."
        case .launchFailed(let reason):
            return launch(reason: reason, hostName: hostName)
        case .decoderFailed:
            return "Couldn't start the video decoder for \(hostName)."
        case .audioFailed:
            // Audio is non-fatal to the visual stream, but if start() threw on
            // it the session never came up - keep the message about the host.
            return "Couldn't start audio for \(hostName)."
        case .crypto:
            return "A security error stopped the connection to \(hostName)."
        case .cancelled:
            // Never shown (the caller drops a cancelled start); worded anyway.
            return "The stream to \(hostName) was stopped before it started."
        case .connectFailed(let failure):
            return connect(failure, hostName: hostName)
        case .playStation(let failure):
            return playStation(failure, hostName: hostName)
        }
    }

    /// The PC answered its control port; a later leg of the connect didn't work.
    static func connect(_ failure: ConnectFailure, hostName: String) -> String {
        switch failure {
        case .streamPortUnreachable(let port):
            let which = port > 0 ? "its stream port (TCP \(port))" : "its stream port"
            return "\(hostName) answered, but \(which) didn't. A firewall on the PC may be blocking it."
        case .controlUnreachable:
            return "\(hostName) answered, but the stream's control connection (UDP) didn't get through. "
                + "A firewall or VPN may be blocking it."
        case .hostRefused(let step, let code):
            return "\(hostName) refused the stream (\(step) returned \(code)). Restart Sunshine on the PC and try again."
        case .hostWentQuiet:
            return "\(hostName) accepted the stream, then stopped answering. Try again; "
                + "if it keeps happening, restart Sunshine on the PC."
        case .unsupported:
            return "\(hostName) answered in a way Shimmer can't use. Update Sunshine on the PC."
        case .localSockets:
            return "This Mac couldn't open the stream's network connections. Check that a VPN or firewall isn't blocking Shimmer."
        case .timedOut:
            return "\(hostName) took too long to start the stream. Try again."
        }
    }

    /// /launch or /resume failed. Sunshine says why in its status message;
    /// when it does, the user gets that, since it names the real cause (the
    /// app's command failed, no encoder, a display it couldn't set up).
    static func launch(reason: String, hostName: String) -> String {
        if reason.hasPrefix("Launch cancelled") { return "The stream to \(hostName) was stopped before it started." }
        if reason.contains("didn't respond within") {
            return "\(hostName) took too long to start the app. Try again."
        }
        let hostSaid = hostStatusMessage(in: reason)
        if let hostSaid, !hostSaid.isEmpty {
            return "\(hostName) couldn't start the app: \(hostSaid)"
        }
        return "\(hostName) answered but couldn't start the app. It may already be in use."
    }

    /// The host's own words out of a launch failure's detail, if it sent any
    /// worth showing. NetworkClient.verifyStatus throws "<status_message>
    /// (code N)"; everything else on that path is our own description of a
    /// broken reply (an HTTP status, malformed XML), which is not for the user.
    static func hostStatusMessage(in reason: String) -> String? {
        guard let codeStart = reason.range(of: " (code ", options: .backwards), reason.hasSuffix(")") else { return nil }
        let message = String(reason[..<codeStart.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'."))
        // "Status N" is verifyStatus's own stand-in for a reply with no message.
        guard message.count >= 4, message.count <= 160, !message.contains("<"), !message.hasPrefix("Status "),
              message.rangeOfCharacter(from: .letters) != nil else { return nil }
        return message.last.map { "?!".contains($0) } == true ? message : message + "."
    }

    /// Two or three words for the menu's card, where the whole sentence
    /// doesn't fit (the sentence is its tooltip): what went wrong, matched
    /// from the sentences above, most specific first.
    static func headline(_ message: String) -> String {
        let text = message.lowercased()
        let table: [(String, String)] = [
            ("isn't answering", "Not answering"),
            ("ended remote play", "Remote Play ended"),
            ("in use by another device", "In use elsewhere"),
            ("didn't wake up", "Didn't wake up"),
            ("is on but didn't answer", "Remote Play is off"),
            ("passcode", "Passcode needed"),
            ("doesn't recognise the playstation account", "Wrong account"),
            ("doesn't recognise this mac", "Pair it again"),
            ("no longer accepts this mac", "Pair it again"),
            ("remote play version", "Update Shimmer"),
            ("stopped working", "Restart the PS5"),
            ("trust", "Trust needed"),
            ("cert", "Trust needed"),
            ("restart sunshine", "Restart Sunshine"),
            ("update sunshine", "Update Sunshine"),
            ("vpn or firewall", "Network blocked"),
            ("firewall", "Blocked by a firewall"),
            ("video decoder", "Decoder failed"),
            ("start audio", "Audio failed"),
            ("security error", "Security error"),
            ("stopped before it started", "Stopped"),
            ("stopped answering", "Stopped answering"),
            ("took too long", "Took too long"),
            ("couldn't start the app", "App didn't start"),
            ("ended unexpectedly", "Stream ended"),
            ("was interrupted", "Connection lost"),
            ("couldn't reach", "Couldn't connect"),
        ]
        return table.first { text.contains($0.0) }?.1 ?? "Couldn't stream"
    }

    /// A PS5 ended a live stream while no controller was connected to this
    /// Mac: most likely the controller is connected to the console itself
    /// and signed in there as the account Remote Play uses.
    static func playStationEndedForLocalController(hostName: String) -> String {
        "\(hostName) ended Remote Play. It does that when the Remote Play account signs in on the console "
            + "with a controller connected to the PS5. Connect the controller to this Mac instead: hold Create "
            + "and the PS button until its light flashes, then choose it in System Settings › Bluetooth."
    }

    static func playStation(_ failure: PlayStationFailure, hostName: String) -> String {
        switch failure {
        case .inUse:
            return "Remote Play on \(hostName) is in use by another device. End it there, then try again."
        case .registrationRejected:
            return "\(hostName) no longer accepts this Mac. Remove it and add it again "
                + "(on the PS5: Settings › System › Remote Play › Pair Device)."
        case .accountNotRecognised:
            return "\(hostName) doesn't recognise the PlayStation account it was added with. "
                + "Sign in to that account on the PS5, or remove the PS5 and add it again."
        case .passcodeRequired:
            return "\(hostName) asks for its login passcode, which Shimmer can't enter yet. "
                + "Sign in on the console first, or turn the passcode off "
                + "(Settings › Users and Accounts › Login Settings)."
        case .remotePlayCrashed:
            return "Remote Play on \(hostName) stopped working. Restart the PS5 and try again."
        case .versionMismatch:
            return "\(hostName) runs a Remote Play version this Shimmer doesn't speak. Update Shimmer."
        case .didNotWake:
            return "\(hostName) didn't wake up. Turn it on, and allow waking it over the network "
                + "(Settings › System › Power Saving › Features Available in Rest Mode)."
        case .noAnswer:
            return "\(hostName) is on but didn't answer. Check that Remote Play is enabled on it "
                + "(Settings › System › Remote Play), then try again."
        case .unreachable:
            return "\(hostName) isn't answering. It's turned off or not on this network. "
                + "Turn it on or put it in rest mode, then try again."
        }
    }

    /// Failures that fix themselves or only need another try (the network
    /// dropped, the machine is asleep, a busy console) against those that
    /// need the user to do something first (pair again, a certificate, a
    /// firewall, the decoder). Only the second kind raises the menu bar's
    /// warning triangle.
    static func isTransient(_ error: Error) -> Bool {
        if let streamError = error as? StreamError {
            switch streamError {
            case .hostUnreachable(let detail):
                let message = detail.lowercased()
                return !message.contains("cert") && !message.contains("mitm")
                    && !message.contains("restart sunshine")
            case .sessionFailed, .truncatedRead, .cancelled: return true
            case .connectFailed(let failure):
                switch failure {
                case .hostWentQuiet, .timedOut: return true
                default: return false
                }
            case .playStation(let failure):
                switch failure {
                case .inUse, .didNotWake, .noAnswer, .unreachable: return true
                default: return false
                }
            default: return false
            }
        }
        // Anything else on the start path (NWError, POSIX) is a reach failure -
        // connect() words it that way too.
        guard let urlError = error as? URLError else { return true }
        return [.networkConnectionLost, .notConnectedToInternet, .timedOut,
                .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(urlError.code)
    }
}
