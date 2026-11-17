//
//  LibraryWindow.swift
//
//  Saved PCs and nearby Bonjour discoveries share the sidebar. The detail
//  pane shows either a saved PC's apps and latency test, or the pairing flow
//  for a PC the user is adding. Saved routes refresh only after pinned TLS verification.
//

import AppKit
import SwiftUI
import Network

struct ComputersTab: View {
    @Environment(AppModel.self) private var model

    @Binding var pairingTarget: PCPairingTarget?
    @State private var discovered: [HostDiscovery.Discovered] = []
    @State private var nearbyPlayStations: [PlayStationDiscovery.Found] = []
    @State private var showManualAddress = false
    @State private var pendingManualAddress: String?
    @State private var setupAddress = ""
    @State private var setupError: String?
    @State private var appRefreshTask: Task<Void, Never>?
    @State private var refreshingApps = false
    @State private var appRefreshFailed = false
    @State private var copiedAgentPrompt = false
    @State private var sidebarProbes: [String: SidebarProbe] = [:]
    /// The app the Stream row will start (nil: the last one played).
    @State private var chosenAppName: String?

    private struct SidebarProbe {
        let reachable: Bool
        let capturedAt: Date
    }

    private struct SidebarProbeTarget: Hashable, Sendable {
        let id: String
        let addresses: [String]
        let port: Int
    }

    private var sidebarProbeTargets: [SidebarProbeTarget] {
        guard !model.pairingInFlight, !model.hostPollingPausedForSleep else { return [] }
        return model.hosts.filter {
            $0.id != model.selectedHost?.id && !(model.isStreaming && model.activeStreamHostID == $0.id)
        }.map { host in
            SidebarProbeTarget(id: host.id, addresses: AppModel.candidateAddresses(for: host),
                               port: model.nativeServerInfo(for: host).httpPort)
        }
    }

    private struct DiscoveryRouteScope: Hashable {
        let discoveries: [HostDiscovery.Discovered]
        let paused: Bool
    }



    private var nearby: [HostDiscovery.Discovered] {
        NearbyPCList.available(discovered, saved: model.hosts)
    }

    /// PS5s answering discovery on this network that aren't registered yet.
    private var unregisteredPlayStations: [PlayStationDiscovery.Found] {
        nearbyPlayStations.filter { !PlayStationStore.shared.isRegistered(hostID: $0.id, name: $0.name) }
    }

    private var apps: [LibraryApp] {
        guard let host = model.selectedHost else { return [] }
        return host.apps.filter { !$0.hidden }
    }

    var body: some View {
        Group {
            if model.hosts.isEmpty {
                if pairingTarget != nil {
                    detail
                } else {
                    FirstPCSetup(nearby: nearby, address: $setupAddress,
                                 connect: connectFirstPC, error: setupError)
                        .disabled(model.pairingInFlight)
                }
            } else {
                HStack(spacing: 0) {
                    sidebar.frame(width: SettingsMetrics.serversSidebarWidth)
                    Divider()
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: model.isStreaming) {
            // PS5s don't announce over Bonjour; scan with PlayStation discovery
            // every few seconds while the Servers tab is open (not mid-stream).
            guard !model.isStreaming else { return }
            while !Task.isCancelled {
                nearbyPlayStations = await PlayStationDiscovery.scan()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .task(id: model.pairingInFlight) {
            // Each task owns its browser. Cancelling an older task can never
            // stop the browser belonging to a newly opened Servers tab.
            guard !model.pairingInFlight else { return }
            let browser = HostDiscovery()
            for await results in await browser.start() {
                guard !Task.isCancelled else { break }
                discovered = results
            }
            await browser.stop()
        }
        .task(id: DiscoveryRouteScope(discoveries: discovered, paused: model.pairingInFlight || model.isStreaming)) {
            await model.refreshDiscoveredHostAddresses(discovered)
        }
        .task(id: model.selectedHostRouteAddress) {
            model.refreshHostRoute()
        }
        .task(id: sidebarProbeTargets) {
            let targets = sidebarProbeTargets
            guard !targets.isEmpty else { return }
            while !Task.isCancelled {
                await withTaskGroup(of: (String, Bool).self) { group in
                    for target in targets {
                        group.addTask {
                            for address in target.addresses {
                                guard !Task.isCancelled else { return (target.id, false) }
                                if case .reachable = await HostReachability.measureRTT(host: address, port: target.port) {
                                    return (target.id, true)
                                }
                            }
                            return (target.id, false)
                        }
                    }
                    for await (id, reachable) in group {
                        guard !Task.isCancelled else { continue }
                        sidebarProbes[id] = SidebarProbe(reachable: reachable, capturedAt: .now)
                    }
                }
                do { try await Task.sleep(for: .seconds(AppModel.hostStatusPollSeconds)) }
                catch { return }
            }
        }
        .onChange(of: setupAddress) { setupError = nil }
        .onChange(of: model.selectedHost?.id) {
            resetAppActions()
            chosenAppName = nil
        }
        .onDisappear {
            resetAppActions()
        }
    }

    private func connectFirstPC(address: String) {
        guard !model.pairingInFlight else { return }
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        setupError = nil
        setupAddress = address
        if let host = NearbyPCList.savedPC(at: address, in: model.hosts) {
            model.selectHost(host)
            pairingTarget = nil
            return
        }
        let name = nearby.first { $0.host == address }?.displayName ?? address
        pairingTarget = PCPairingTarget(name: name, address: address, startImmediately: true)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // One unlabelled list, as Tailscale lists accounts: PCs,
                    // then consoles.
                    ForEach([false, true], id: \.self) { consoles in
                        let group = model.hosts.filter { $0.isPlayStation == consoles }
                        if !group.isEmpty {
                        ForEach(group) { host in
                            Button {
                                guard !model.pairingInFlight else { return }
                                pairingTarget = nil
                                model.selectHost(host)
                            } label: {
                                HostRow(host: host, address: model.dialAddress(for: host), selected: pairingTarget == nil && host.id == model.selectedHost?.id,
                                        status: connectionIndicator(for: host), statusText: connectionStatusText(for: host))
                            }
                            .buttonStyle(.plain)
                            .disabled(model.pairingInFlight)
                            .accessibilityLabel("\(host.displayName), \(connectionStatusText(for: host)), \(model.dialAddress(for: host))")
                            .hostContextMenu(host)
                            .task(id: host.id) {
                                _ = await HostSystemKind.detect(host: host, address: model.dialAddress(for: host))
                            }
                        }
                        }
                    }
                    if !nearby.isEmpty || !unregisteredPlayStations.isEmpty {
                        sidebarHeading(unregisteredPlayStations.isEmpty ? "Nearby PCs" : "Nearby")
                            .padding(.top, model.hosts.isEmpty ? 0 : 10)
                        ForEach(nearby) { pc in
                            Button {
                                                pairingTarget = PCPairingTarget(name: pc.displayName, address: pc.host)
                            } label: {
                                NearbyPCRow(pc: pc, selected: pairingTarget?.address == pc.host)
                            }
                            .buttonStyle(.plain)
                            .disabled(model.pairingInFlight)
                            .help("Pair with \(pc.displayName) to add this PC")
                            .accessibilityLabel("\(pc.displayName), nearby PC, not added, \(pc.host)")
                        }
                        ForEach(unregisteredPlayStations) { ps in
                            Button {
                                                pairingTarget = PCPairingTarget(name: ps.name, address: ps.address,
                                                                isPlayStation: true)
                            } label: {
                                NearbyPlayStationRow(console: ps, selected: pairingTarget?.address == ps.address)
                            }
                            .buttonStyle(.plain)
                            .disabled(model.pairingInFlight)
                            .help("Register \(ps.name) to stream it")
                            .accessibilityLabel("\(ps.name), nearby PlayStation 5, not added, \(ps.address)")
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Tailscale's Accounts bar: add, and a pull-down for the
            // selected machine (Rename, Remove).
            Divider()
            HStack(spacing: 6) {
                addByAddressButton()
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 6))
                selectedHostMenu
            }
            .controlSize(.regular)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
        }
    }

    /// The selected machine's Rename / Remove, beside "Add by Address…".
    @ViewBuilder
    private var selectedHostMenu: some View {
        let chevron = Image(systemName: "chevron.down")
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 14, height: 16)
        if let host = model.selectedHost, pairingTarget == nil {
            chevron
                .hostOptionsMenu(host)
                .disabled(model.pairingInFlight)
                .help("\(host.displayName) options")
                .id(host.id)
        } else {
            Menu { } label: { chevron }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(true)
        }
    }

    private func addByAddressButton() -> some View {
        Button {
            showManualAddress = true
        } label: {
            Text("Add by Address…")
                .frame(maxWidth: .infinity)
                .frame(height: 16)
        }
        .disabled(model.pairingInFlight)
        .help("Add a PC using an IP address or hostname")
        .popover(isPresented: $showManualAddress,
                 attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            ManualAddressPopover(cancel: { showManualAddress = false }) { address in
                pendingManualAddress = address
                showManualAddress = false
            }
            .onDisappear {
                guard let address = pendingManualAddress else { return }
                pendingManualAddress = nil
                if let host = NearbyPCList.savedPC(at: address, in: model.hosts) {
                    pairingTarget = nil
                    model.selectHost(host)
                } else {
                    // A PS5 answers PlayStation discovery; anything else pairs as a PC.
                    Task {
                        if let ps5 = await PlayStationDiscovery.probe(address: address) {
                            pairingTarget = PCPairingTarget(name: ps5.hostName ?? "PS5", address: address,
                                                            isPlayStation: true)
                        } else {
                            pairingTarget = PCPairingTarget(name: "Add PC", address: address, startImmediately: true)
                        }
                    }
                }
            }
        }
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let target = pairingTarget, target.isPlayStation {
            PlayStationPairingPane(target: target) { id in
                if let host = model.hosts.first(where: { $0.id == id }) {
                    model.selectHost(host)
                    pairingTarget = nil
                }
            }
            .id(target.id)
        } else if let target = pairingTarget {
            PCPairingPane(target: target, failed: model.hosts.isEmpty ? { address, message in
                guard pairingTarget?.id == target.id else { return }
                setupAddress = address
                setupError = message
                pairingTarget = nil
            } : nil) { id in
                if let host = model.hosts.first(where: { $0.id == id }) {
                    model.selectHost(host)
                    pairingTarget = nil
                }
            }
            .id(target.id)
        } else if let host = model.selectedHost {
            machinePage(for: host)
                // Each machine's page has its own view state: a value
                // half-typed on one PC must not commit into the next.
                .id(host.id)
        } else {
            ContentUnavailableView("No PC selected",
                                   systemImage: "display",
                                   description: Text("Pick one on the left to see its apps."))
        }
    }


    /// A machine's page as System Settings lays one out: a grouped Form that
    /// opens on what Stream launches (the sidebar already names the machine
    /// and its status), then Video (and Controller on a PS5), and last what
    /// ending the stream does.
    private func machinePage(for host: Host) -> some View {
        let chosen = apps.first { $0.name == (chosenAppName ?? model.heroTargetAppName) } ?? apps.first
        return Form {
            Section {
                if !host.isPlayStation && apps.isEmpty {
                    noAppsNotice(for: host)
                } else {
                    StreamRow(host: host, apps: apps, app: chosen, choose: { chosenAppName = $0 })
                }
            }
            if host.isPlayStation {
                PlayStationSettingsPane(settings: .forConsole(host.id))
            } else {
                Section {
                    StreamPane()
                    VideoPane()
                } header: {
                    FormSectionHeader("Video")
                }
            }
            // What ending the stream does comes last, after the settings for
            // the stream itself.
            Section {
                endOfStreamToggle(for: host)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }

    /// What ending a stream does to the machine. Off, a PC's game keeps
    /// running for the next Resume ("Quit <app>" in the menu bar ends it).
    @ViewBuilder
    private func endOfStreamToggle(for host: Host) -> some View {
        if host.isPlayStation {
            let settings = PlayStationSettings.forConsole(host.id)
            Toggle(isOn: Binding(
                get: { settings.restWhenStreamEnds }, set: { settings.restWhenStreamEnds = $0 })) {
                Text("Rest the PS5 when the stream ends")
                Text("Puts the console in rest mode when you end the stream.")
            }
        } else {
            Toggle("Quit the game when the stream ends", isOn: Binding(
                get: { model.quitAppWhenStreamEnds }, set: { model.quitAppWhenStreamEnds = $0 }))
        }
    }

    /// A PC that published no apps: refresh, or hand the problem to an agent.
    private func noAppsNotice(for host: Host) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(appRefreshFailed ? "Couldn’t refresh the apps." : "No apps found.")
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(refreshingApps ? "Refreshing…" : "Refresh Apps") { refreshApps(for: host) }
                    .disabled(refreshingApps || model.isStreaming)
                Button(copiedAgentPrompt ? "Copied" : "Copy Agent Prompt") { copyAgentPrompt(for: host) }
                    .help("Copy troubleshooting instructions for Claude Code or another coding agent")
            }
            .controlSize(.small)
        }
    }




    private func connectionIndicator(for host: Host) -> HostStatusIndicator {
        if model.selectedHost?.id == host.id || (model.isStreaming && model.activeStreamHostID == host.id) {
            return model.hostStatusIndicator(for: host.id)
        }
        guard let probe = sidebarProbes[host.id], Date().timeIntervalSince(probe.capturedAt) <= HostLiveStatus.stale else { return .neutral }
        return probe.reachable ? .online : .offline
    }

    private func connectionStatusText(for host: Host) -> String {
        if model.selectedHost?.id == host.id || (model.isStreaming && model.activeStreamHostID == host.id) {
            return model.hostStatusLine(for: host.id)
        }
        guard let probe = sidebarProbes[host.id], Date().timeIntervalSince(probe.capturedAt) <= HostLiveStatus.stale else { return "Checking…" }
        return probe.reachable ? "Online" : "Asleep or offline"
    }




    private func resetAppActions() {
        appRefreshTask?.cancel()
        appRefreshTask = nil
        refreshingApps = false
        appRefreshFailed = false
        copiedAgentPrompt = false
    }

    private func refreshApps(for host: Host) {
        guard !refreshingApps, !model.isStreaming else { return }
        refreshingApps = true
        appRefreshFailed = false
        appRefreshTask = Task { @MainActor in
            do {
                try await model.refreshApps(for: host)
                guard !Task.isCancelled else { return }
            } catch {
                guard !Task.isCancelled else { return }
                appRefreshFailed = true
            }
            refreshingApps = false
            appRefreshTask = nil
        }
    }

    private func copyAgentPrompt(for host: Host) {
        let prompt = HostAppTroubleshootingPrompt.text(
            hostName: host.displayName,
            address: model.selectedHostRouteAddress ?? model.dialAddress(for: host))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        copiedAgentPrompt = pasteboard.setString(prompt, forType: .string)
    }







}

enum HostAppTroubleshootingPrompt {
    static func text(hostName: String, address: String) -> String {
        ShimmerCLIAgentInstructions.text(hostName: hostName, address: address)
    }
}




/// A readable zero-based scale for the measurements currently in view. Keep
/// clean tick values without imposing a 10 ms floor on fast connections.
struct LatencyGraphScale {
    let upperBound: Double
    var ticks: [Double] { [0, upperBound / 2, upperBound] }

    init(maximum: Double?) {
        guard let maximum, maximum.isFinite, maximum >= 0,
              maximum < Double(Int.max) else {
            upperBound = 10
            return
        }
        let value = max(1, maximum)
        let magnitude = pow(10, floor(log10(value)))
        let step = [1.0, 2, 5, 10].first { $0 * magnitude >= value } ?? 10
        upperBound = max(value, step * magnitude)
    }
}



/// Discovery is transient and untrusted. Match stable server IDs or exact
/// saved addresses; a friendly name alone must never hide another user's PC.
struct NearbyPCList {
    static func savedPC(at address: String, in saved: [Host]) -> Host? {
        let key = addressKey(address)
        return saved.first { host in
            [host.localAddress, host.manualAddress].compactMap { $0 }.contains { addressKey($0) == key }
        }
    }

    static func available(_ found: [HostDiscovery.Discovered], saved: [Host]) -> [HostDiscovery.Discovered] {
        let ids = Set(saved.map { $0.id.lowercased() })
        let addresses = Set(saved.flatMap { [$0.localAddress, $0.manualAddress].compactMap { $0 }.map(addressKey) })
        var seenIDs = Set<String>()
        var seenAddresses = Set<String>()
        return found.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            if order != .orderedSame { return order == .orderedAscending }
            if $0.host != $1.host { return $0.host < $1.host }
            return $0.id < $1.id
        }.filter { pc in
            let address = addressKey(pc.host)
            if let id = pc.serverID, ids.contains(id.lowercased()) { return false }
            guard !addresses.contains(address) else { return false }
            let endpoint = "\(address):\(pc.port)"
            let duplicateAddress = !seenAddresses.insert(endpoint).inserted
            let duplicateID = pc.serverID.map { !seenIDs.insert($0.lowercased()).inserted } ?? false
            return !duplicateAddress && !duplicateID
        }
    }

    private static func addressKey(_ input: String) -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        let pieces = value.split(separator: "%", maxSplits: 1)
        let plain = pieces.first.map(String.init) ?? value
        if let ip = IPv4Address(plain) { return "v4:" + ip.rawValue.base64EncodedString() }
        if let ip = IPv6Address(plain) {
            let bytes = Array(ip.rawValue)
            let zone = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 && pieces.count == 2 ? "%" + pieces[1] : ""
            return "v6:" + ip.rawValue.base64EncodedString() + zone
        }
        return value.hasSuffix(".") ? String(value.dropLast()) : value
    }
}

private struct NearbyPlayStationRow: View {
    let console: PlayStationDiscovery.Found
    let selected: Bool
    var body: some View {
        HStack(spacing: 8) {
            HostSystemLogo(kind: .playStation, size: 22)
                .frame(width: SettingsMetrics.sidebarIconSize, height: SettingsMetrics.sidebarIconSize)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(console.name).font(.system(size: 13)).lineLimit(1)
                Text(console.address).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(minHeight: SettingsMetrics.sidebarRowHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.primary.opacity(0.13) : .clear))
        .contentShape(Rectangle())
    }
}

private struct NearbyPCRow: View {
    let pc: HostDiscovery.Discovered
    let selected: Bool
    var body: some View {
        HStack(spacing: 8) {
            HostSystemLogo(kind: HostSystemKind.resolve(isPlayStation: false, ttl: nil, serverName: pc.displayName),
                           size: 22)
                .frame(width: SettingsMetrics.sidebarIconSize, height: SettingsMetrics.sidebarIconSize)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(pc.displayName).font(.system(size: 13)).lineLimit(1)
                Text(pc.host).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(minHeight: SettingsMetrics.sidebarRowHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.primary.opacity(0.13) : .clear))
        .contentShape(Rectangle())
    }
}

// MARK: - Sidebar row

/// One machine: its icon, the name, and a word or two of status beneath, as
/// Rex's sidebar says "Server / Running". The address and the full status
/// are in the row's tooltip.
private struct HostRow: View {
    let host: Host
    let address: String
    let selected: Bool
    let status: HostStatusIndicator
    let statusText: String

    var body: some View {
        HStack(spacing: 8) {
            HostAvatar(host: host)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(Self.shortStatus(statusText))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(minHeight: SettingsMetrics.sidebarRowHeight)
        .help("\(statusText)\n\(address)")
        // Tailscale's selected account: a flat grey plate (68,68,68 on its
        // dark sidebar) - the unemphasised selection colour.
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : Color.clear))
    }

    /// The sidebar's short form: "Streaming" rather than "Streaming at
    /// 1080p60 HDR", "Online" rather than "Online · status unavailable".
    static func shortStatus(_ text: String) -> String {
        if text.hasPrefix("Streaming") { return "Streaming" }
        return text.components(separatedBy: " · ").first ?? text
    }
}

// MARK: - App glyph

/// An app's icon: a system symbol, or a bundled template mark for the few
/// things SF Symbols has no glyph for. Sized to sit on a button's text line.
///
/// Shared with the menu-bar dropdown, which names the same app on its stream
/// button - the two surfaces have to agree, or the menu says "Stream Steam"
/// beside a gamepad while the library shows the Valve mark.
struct AppGlyphIcon: View {
    let app: LibraryApp
    /// Cap height to match the symbols beside it. The library's rows are
    /// roomier than an NSMenu's, so the dropdown asks for a smaller one.
    var size: CGFloat = 14

    var body: some View {
        switch app.glyph {
        case .symbol(let name):
            Image(systemName: name)
                .symbolRenderingMode(.monochrome)
        case .asset(let name):
            Image(name)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                // Matched to the cap height of the symbols beside it, so a
                // bundled mark and an SF Symbol sit on the same line.
                .frame(width: size, height: size)
        }
    }
}
