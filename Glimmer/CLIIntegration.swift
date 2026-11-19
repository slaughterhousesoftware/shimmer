// The coding-agent instructions Settings copies, and the copy button.
import AppKit
import SwiftUI

enum ShimmerCLIAgentInstructions {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    /// The prompt "Copy Instructions" puts on the clipboard: plain paragraphs
    /// (no line breaks inside a sentence, so it pastes cleanly into a chat
    /// box), the CLI's real commands, and the selected server as what it is.
    static func text(hostName: String? = nil, address: String? = nil, isPlayStation: Bool = false,
                     bundleURL: URL = Bundle.main.bundleURL) -> String {
        let executable = quote(bundleURL.appendingPathComponent("Contents/Resources/shimmerctl").path)
        let kind = isPlayStation ? "a PlayStation 5 (Remote Play)" : "a PC running Sunshine or Apollo"
        let server: String
        if let hostName, let address {
            server = "The server selected in Shimmer is \(hostName), \(kind), at \(address)."
        } else {
            server = "No server is selected in Shimmer. Ask me which PC or PS5 to look at before running checks that need one."
        }
        let pcDoctor = address.map { "`shimmerctl doctor --host \(quote($0))`" } ?? "`shimmerctl doctor --host <address>`"
        let serverChecks = isPlayStation
            ? "For a PS5, doctor asks the console the way Shimmer does; Remote Play must be on (PS5: Settings > System > Remote Play), and only one device can use it at a time."
            : "For a PC, \(pcDoctor) checks it directly. Doctor checks Sunshine's ports but not pairing or the app list: if no apps show up, check the paired /applist request, hidden apps and Sunshine's configuration."
        let paragraphs = [
            "Help me fix a problem with Shimmer, a Mac app that streams games from a gaming PC (Sunshine or Apollo) or a PlayStation 5.",
            "Shimmer comes with a command-line tool, shimmerctl, at \(executable) (`shimmerctl` below means that path). It needs Python 3; find an installed one, or tell me if there isn't one. Start by reading its --help and the CLI.md beside it.",
            server,
            "Start with `shimmerctl doctor`: it reports what the app is doing, anything stuck, permissions, its background helper, whether the server answers, and the commands that fix what it finds. `shimmerctl fix auto` applies every fix that needs no person and lists the rest. `shimmerctl state` shows the app's live state and `shimmerctl logs --last 10m` the detail. To find out why a stream misbehaves, `shimmerctl set recording on` records the next stream (one JSON object per second, in ~/Library/Logs/Shimmer); turn it off afterwards. If the app stops responding, `shimmerctl fix relaunch`.",
            serverChecks,
            "Ground rules: keep pairings and settings as they are unless I agree, never ask for private keys or passwords, and don't end a stream that's running. Diagnose first, then make targeted fixes, and check the result in Shimmer.",
        ]
        return paragraphs.joined(separator: "\n\n")
    }
}

struct CLICopyButton: View {
    let title: String
    let value: () -> String
    @State private var copied = false
    init(_ title: String, value: @escaping () -> String) {
        self.title = title
        self.value = value
    }
    var body: some View {
        Button {
            let board = NSPasteboard.general
            board.clearContents()
            copied = board.setString(value(), forType: .string)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "doc.on.doc")
                ZStack {
                    Text(title).hidden().accessibilityHidden(true)
                    Text(copied ? "Copied" : title)
                }
            }
        }
    }
}
