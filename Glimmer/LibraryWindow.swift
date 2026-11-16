//
//  LibraryWindow.swift
//
//  Saved PCs and nearby Bonjour discoveries share the sidebar. The detail
//  pane shows either a saved PC's apps and latency test, or the pairing flow
//  for a PC the user is adding. Saved routes refresh only after pinned TLS verification.
//

import AppKit
import SwiftUI
import Charts
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
                    sidebar.frame(width: 190)
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
                    ForEach([false, true], id: \.self) { consoles in
                        let group = model.hosts.filter { $0.isPlayStation == consoles }
                        if !group.isEmpty {
                        sidebarHeading(consoles ? "Consoles" : "PCs")
                            .padding(.top, consoles ? 8 : 0)
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
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 0) {
                addByAddressButton(plus: true)
                    .buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }

    private func addByAddressButton(expanded: Bool = false, plus: Bool = false) -> some View {
        Button {
            showManualAddress = true
        } label: {
            if plus {
                Image(systemName: "plus").font(.system(size: 13, weight: .medium)).frame(width: 20, height: 18)
            } else {
                Text("Add by Address…")
                    .frame(maxWidth: expanded ? .infinity : nil)
                    .frame(height: 16)
            }
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
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 22) {
                        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                            streamRow(for: host)
                            if host.isPlayStation {
                                PlayStationSettingsPane(settings: .forConsole(host.id))
                            } else {
                                StreamPane()
                                VideoPane()
                            }
                        }
                        .padding(.trailing, 20)
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .hostOptionsMenu(host)
                    .help("PC options")
                    .padding(.trailing, 11)
                    .padding(.top, 12)
            }
        } else {
            ContentUnavailableView("No PC selected",
                                   systemImage: "display",
                                   description: Text("Pick one on the left to see its apps."))
        }
    }


    /// Streaming, as the page's first row: what to stream (a PC's apps; a PS5
    /// is just the console), then Stream / Resume and Picture in Picture. While
    /// this machine is streaming the row shows that stream's controls instead.
    private func streamRow(for host: Host) -> some View {
        let chosen = apps.first { $0.name == (chosenAppName ?? model.heroTargetAppName) } ?? apps.first
        let resumes = chosen.map { model.runningAppName == $0.name } ?? false
        let streamingHere = model.isStreaming && model.activeStreamHostID == host.id
        return SettingsField("Stream") {
            if apps.isEmpty {
                noAppsNotice(for: host)
            } else if apps.count > 1 {
                Picker("", selection: Binding(get: { chosen?.name ?? "" }, set: { chosenAppName = $0 })) {
                    ForEach(apps) { app in
                        Label { Text(app.name) } icon: { AppGlyphIcon(app: app) }.tag(app.name)
                    }
                }
                .labelsHidden()
                .settingsPopup()
                .disabled(model.isStreaming)
            }
            HStack(spacing: 8) {
                if streamingHere, case .connecting(let stage) = model.streamPhase {
                    ProgressView().controlSize(.small).help(stage)
                    Button("Cancel") { model.cancelConnect() }
                } else if streamingHere {
                    Button { model.resumeStreamWindow() } label: {
                        Label("Show Stream", systemImage: "pip.exit")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.activeStreamHasVideo)
                    Button("End Stream") { model.endStream() }
                } else {
                    Button {
                        guard let chosen else { return }
                        model.requestStream(app: chosen, on: host)
                    } label: {
                        Label(resumes ? "Resume" : "Stream", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        guard let chosen else { return }
                        model.pictureInPictureLaunchRequestedAt = Date()
                        model.requestStream(app: chosen, on: host)
                    } label: {
                        Label("Picture in Picture", systemImage: "pip.enter")
                    }
                }
            }
            .disabled(chosen == nil || (model.isStreaming && !streamingHere))
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
        HStack(spacing: 9) {
            HostSystemLogo(kind: .playStation, size: 22)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(console.name).font(.system(size: 13)).lineLimit(1)
                Text(console.address).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.primary.opacity(0.13) : .clear))
        .contentShape(Rectangle())
    }
}

private struct NearbyPCRow: View {
    let pc: HostDiscovery.Discovered
    let selected: Bool
    var body: some View {
        HStack(spacing: 9) {
            HostSystemLogo(kind: HostSystemKind.resolve(isPlayStation: false, ttl: nil, serverName: pc.displayName),
                           size: 22)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(pc.displayName).font(.system(size: 13)).lineLimit(1)
                Text(pc.host).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.primary.opacity(0.13) : .clear))
        .contentShape(Rectangle())
    }
}

// MARK: - Sidebar row

/// One PC: a round glyph, the name, and the address beneath -
/// the shape of the reference app's account rows (48pt plate, 6pt inset).
private struct HostRow: View {
    let host: Host
    let address: String
    let selected: Bool
    let status: HostStatusIndicator
    let statusText: String

    var body: some View {
        HStack(spacing: 9) {
            HostSystemLogo(host: host, size: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.displayName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(address)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            HostStatusDot(status: status)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.13) : Color.clear))
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
