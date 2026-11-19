//
//  ContentView+Menus.swift
//
//  The shared per-host menu (Rename / Remove): a sidebar row's right-click
//  and the pull-down beside "Add by Address…" on Servers. The
//  menu bar dropdown itself is AppKit - see MenuBarController.swift.
//

import AppKit
import SwiftUI

// MARK: - Shared per-host right-click menu

/// Shared PC actions for secondary click and the Servers bottom bar's pull-down.
/// A machine's codec is on its page.
/// Each presentation owns its rename and removal dialogs. Settings are keyed
/// by host ID so every menu reflects the same saved preferences.
private struct HostContextMenu: ViewModifier {
    let host: Host
    let showsButton: Bool
    let onRename: (() -> Void)?
    @Environment(AppModel.self) private var model
    @State private var showUnpairConfirm = false
    @State private var showRename = false
    @State private var draftName = ""

    init(host: Host, showsButton: Bool = false, onRename: (() -> Void)? = nil) {
        self.host = host
        self.showsButton = showsButton
        self.onRename = onRename
    }

    @ViewBuilder
    private var actions: some View {
        RenameButton()
            .renameAction {
                if let onRename {
                    onRename()
                } else {
                    draftName = host.customName ?? ""
                    showRename = true
                }
            }
        if !host.isPlayStation {
            // A game added in Sunshine after pairing only shows up once the
            // app list is fetched again; the only button for that sat behind
            // an empty list, so the way to get it was removing the PC.
            Button {
                Task {
                    do { try await model.refreshApps(for: host) } catch {
                        Diag.error("Refresh Apps failed for \(host.displayName, privacy: .private): "
                            + "\(error.localizedDescription, privacy: .private)", "Hosts")
                    }
                }
            } label: {
                Label("Refresh Apps", systemImage: "arrow.clockwise")
            }
            .disabled(model.isStreaming)
        }
        Divider()
        Button(role: .destructive) {
            showUnpairConfirm = true
        } label: {
            Label("Remove “\(host.displayName)”…", systemImage: "minus.circle")
        }
        .disabled(model.isStreaming && model.activeStreamHostID == host.id)
    }

    func body(content: Content) -> some View {
        Group {
            if showsButton {
                // The pull-down beside "Add by Address…", as in Tailscale's
                // Accounts window.
                Menu { actions } label: { content }
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .menuIndicator(.hidden)
                    .fixedSize()
            } else {
                content.contentShape(Rectangle()).contextMenu { actions }
            }
        }
            .alert("Rename \(host.displayName)", isPresented: $showRename) {
                TextField("Display name", text: $draftName)
                Button("Save") { model.renameHost(host, to: draftName) }
                // Not destructive - it just clears the custom name back to the
                // PC's own hostname, so no red styling.
                Button("Use default name") {
                    model.renameHost(host, to: "")
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(host.isPlayStation
                     ? "Shown in the menu bar and the server list. Leave it empty to use the console's own name."
                     : "Shown in the menu bar and the server list. Leave it empty to use the PC's own name.")
            }
            .confirmationDialog(
                "Remove \(host.displayName)?",
                isPresented: $showUnpairConfirm,
                titleVisibility: .visible
            ) {
                Button(host.isPlayStation ? "Remove Console" : "Remove PC", role: .destructive) { model.unpair(host) }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(host.isPlayStation
                     ? "Shimmer will forget this PS5. To stream it again, pair it with a new code from the console."
                     : "Shimmer will forget this PC. You can pair it again at any time.")
            }
    }
}

extension View {
    /// Attach the shared per-host right-click menu (Rename / Remove).
    func hostContextMenu(_ host: Host, onRename: (() -> Void)? = nil) -> some View {
        modifier(HostContextMenu(host: host, onRename: onRename))
    }

    /// `self` becomes the label of a bordered pull-down with the same actions.
    func hostOptionsMenu(_ host: Host, onRename: (() -> Void)? = nil) -> some View {
        modifier(HostContextMenu(host: host, showsButton: true, onRename: onRename))
    }
}
