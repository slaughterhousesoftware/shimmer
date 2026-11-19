//
//  MenuBarController.swift
//
//  The menu bar item and its dropdown, in AppKit: an NSStatusItem whose button
//  carries the label, and a real NSMenu rebuilt from the model every time it
//  opens. The dropdown moved here from a SwiftUI MenuBarExtra for one reason -
//  the header. Tailscale's menu opens on the app's name over its status, and
//  that row is inert: neither a disabled item (which would dim the title) nor
//  a button (which would highlight). An NSMenu can only do that as a custom
//  view on the item (`NSMenuItem.view`), which MenuBarExtra can't host. Same
//  shape as ergodriven-tempo-mac's StatusItemController; the rows themselves
//  are ordinary items, with the checkmarks, key equivalents and enabled states
//  the SwiftUI menu had to fake or forgo.
//
//  The label is native button content (image + title), re-applied whenever
//  the @Observable inputs change - a template image in the status bar tints
//  and highlights the way the system's own items do, which a hosted SwiftUI
//  view would not.
//

import AppKit
import SwiftUI

enum MenuBarPreferences {
    /// Settings used to have "Show status in the menu bar". The menu bar item
    /// carries the pad's battery, warnings and the playing app, so it is no
    /// longer optional (Kevin, 2026-11-18); a Mac that had it off gets it back.
    static let retiredVisibilityKey = "showMenuBarItem"

    static func forgetRetiredSwitch(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: retiredVisibilityKey)
    }
}

/// What the menu bar icon shows: warnings, loading, then the connected pad
/// and its battery, then the streamed or running app. With none of those
/// there is no menu bar icon - Shimmer has no icon of its own up there
/// (Kevin, 2026-11-18: the prism it used to fall back to looked bad) - and
/// the Dock is the way in.
struct MenuBarPresentation: Equatable {
    let glyph: LibraryApp.Glyph
    let title: String
    let assetHeight: CGFloat?
    /// Connecting, switching PCs or waking a PS5: a spinner in place of the
    /// glyph. Only a warning outranks it.
    let spinning: Bool

    /// `controller` is the connected pad's Steam glyph name and its battery,
    /// if it reports one; a pad without a battery reading still shows, as its
    /// plain glyph.
    init?(warning: Bool, busy: Bool = false, controller: (kind: String, battery: (percent: Int, charging: Bool)?)?,
          appGlyph: LibraryApp.Glyph?) {
        spinning = busy && !warning
        if warning {
            glyph = .symbol("exclamationmark.triangle.fill")
            title = ""
            assetHeight = nil
        } else if let controller {
            glyph = .asset(controller.battery.map {
                MenuBarBatteryGlyph.assetName(forPercent: $0.percent, charging: $0.charging,
                                              kind: controller.kind)
            } ?? MenuBarBatteryGlyph.glyphName(kind: controller.kind))
            title = ""
            assetHeight = nil
        } else if let appGlyph {
            glyph = appGlyph
            title = ""
            assetHeight = 15
        } else if spinning {
            // Loading with nothing else to show: the spinner alone (its first
            // frame stands for the glyph it covers).
            glyph = .asset(MenuBarSpinner.frameName(0))
            title = ""
            assetHeight = nil
        } else {
            return nil
        }
    }
}

extension AppModel {
    var menuBarPresentation: MenuBarPresentation? {
        // A saved launch target alone is not a currently running app - but a
        // PS5 is one thing, the console, so with one selected its mark shows
        // idle as well as streaming.
        let appGlyph: LibraryApp.Glyph? = if isStreaming {
            heroTargetApp?.glyph ?? .symbol("play.fill")
        } else if runningAppName != nil || selectedHost?.isPlayStation == true {
            heroTargetApp?.glyph
        } else {
            nil
        }
        return MenuBarPresentation(warning: menuBarShowsStreamError, busy: menuBarBusy,
                                   controller: menuBarControllerKind.map { ($0, menuBarControllerBattery) },
                                   appGlyph: appGlyph)
    }

    /// Shimmer is on its way somewhere and you are waiting for it:
    ///   - a stream connecting, from the click (asking the PC what it runs)
    ///     through finding or waking a PS5 to the connect - and reconnecting
    ///     after a drop or the Mac's sleep, which goes the same way;
    ///   - a Switch PC, through the old stream closing to the new one up;
    ///   - a PC power action (Wake, Wake & Connect up to its stream, Restart,
    ///     Shut Down, Sleep), ~10-40 s each.
    /// Not: a question waiting for an answer (taking over a running game),
    /// pairing (its own window shows that), or a stream that is live.
    var menuBarBusy: Bool {
        if case .connecting = streamPhase { return true }
        if streamCheckHostID != nil { return true }
        if powerWaitHostID != nil || !LunaPower.shared.actionInFlight.isEmpty { return true }
        return pendingHostSwitch != nil
    }

    var hasVisibleMenuBarItem: Bool {
        menuBarPresentation != nil
    }
}

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// The menu's width, and the width the hosted rows lay out at: the
    /// Sound menu's (308 pt, measured on macOS 27 at native 2x). A longer
    /// row still widens it.
    private static let menuWidth: CGFloat = 308

    private let model: AppModel
    private let item: NSStatusItem
    private let menu = NSMenu()

    /// The app's one controller, for `shimmerctl menu` (AgentControl).
    private(set) static weak var current: MenuBarController?

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = false
        super.init()
        Self.current = self
        menu.delegate = self
        menu.autoenablesItems = false
        menu.minimumWidth = Self.menuWidth
        // macOS 27: the menu is shown as Control Center shows its own - a
        // panel through the status item's expanded-interface session
        // (MenuBarPanel); the NSMenu only builds the rows. Earlier: the
        // NSMenu itself.
        if #available(macOS 27.0, *) {
            item.expandedInterfaceDelegate = self
        } else {
            item.menu = menu
        }
        observeLabel()
        observeFullScreenApps()
    }

    // MARK: - Opening over a full-screen app

    /// macOS 27.2 never shows a REGULAR app's status-item menu while another
    /// app is in full screen (measured 2026-11-16: the menu window is created
    /// but never on screen); an accessory app's opens normally. So the Dock
    /// policy follows what is in front (`AppDelegate.activationPolicy`): out
    /// of the Dock while another app's full screen is up - where the Dock is
    /// hidden anyway - and back when it isn't. The click itself stays macOS's
    /// own. (Intercepting it to switch per click made the menu close itself
    /// 0.3-0.8 s after opening: the real mouse-up landed on the re-click.)
    private var workspaceObservers: [NSObjectProtocol] = []

    private func observeFullScreenApps() {
        let nc = NSWorkspace.shared.notificationCenter
        let recheck: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated {
                AppDelegate.refreshActivationPolicy()
                // Windows settle after the space animation; look again.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    MainActor.assumeIsolated { AppDelegate.refreshActivationPolicy() }
                }
            }
        }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(nc.addObserver(forName: name, object: nil, queue: .main, using: recheck))
        }
    }

    /// Another app's full screen is the Space showing: an on-screen window of
    /// another app covers a whole screen. Not only the frontmost app's - with
    /// Shimmer's own window in front of it (a PiP return over a full-screen
    /// app), it is still that app's full-screen Space, and turning into a
    /// Dock app there would make macOS move the user to a desktop.
    static func frontmostAppIsFullScreen() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let screens = NSScreen.screens.map(\.frame.size)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.contains { info in
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner != me,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return false }
            return screens.contains { abs($0.width - bounds.width) < 1 && abs($0.height - bounds.height) < 1 }
        }
    }

    // MARK: - Label

    /// Re-run `applyLabel` whenever anything it read changes. The model's
    /// label properties touch their observable dependencies deliberately
    /// (see `menuBarControllerBattery`), so a pad connecting or draining, a
    /// stream starting, or an error all land here.
    private func observeLabel() {
        withObservationTracking {
            applyLabel()
        } onChange: {
            Task { @MainActor [weak self] in self?.observeLabel() }
        }
    }

    /// Precedence, worst news first:
    ///   error         -> the warning triangle alone (nothing else matters)
    ///   busy          -> a spinner: connecting, or switching PCs
    ///   pad connected -> the controller's own glyph + its battery percentage
    ///   streaming     -> the streamed app's own glyph (Steam mark for Big
    ///                    Picture, each app's symbol otherwise)
    ///   host running  -> that same app's glyph (a session on the PC waiting to
    ///                    resume - `runningAppName`, the host-truth the "X
    ///                    running" header and the tile badge use, so the menu
    ///                    bar and dropdown never disagree)
    ///   idle          -> no menu-bar item; the Dock remains available
    ///
    /// The pad outranks the app glyph: you're all but always holding the
    /// controller while a session is up, so its battery - the one thing the
    /// screen doesn't already show you - is what belongs there. A PlayStation
    /// pad gets the bundled DualSense mark with a STEAM-style battery baked in
    /// (MenuBarBatteryGlyph); anything else gets Apple's generic controller
    /// symbol and the number. The app glyph (streaming or host-running) shows
    /// only when NO pad is connected. Idle with none of these: no icon.
    private func applyLabel() {
        let presentation = model.menuBarPresentation
        // Loading just ended with nothing else to show: the spinner finishes
        // its half-second grace (updateSpinner) before the icon goes, so a
        // gap between two steps doesn't make it blink out and back.
        let holdingSpinner = presentation == nil && spinner.isRunning
        // Its own menu is open (a pick in Servers can leave nothing to show):
        // the icon stays until the menu closes, or the menu would vanish.
        let holdingForMenu = presentation == nil && menuIsOpen && item.isVisible
        let visible = presentation != nil || holdingSpinner || holdingForMenu
        // Establish the Dock fallback before an idle status item disappears.
        AppDelegate.refreshActivationPolicy()
        if item.isVisible != visible { item.isVisible = visible }
        guard visible, let button = item.button else { return }
        guard let presentation else {
            if holdingSpinner { updateSpinner(false, in: button) }
            return
        }
        button.setAccessibilityLabel("Shimmer")
        button.toolTip = "Shimmer"
        button.imagePosition = .imageLeading
        button.title = presentation.title
        switch presentation.glyph {
        case .symbol(let name): button.image = Self.symbol(name)
        case .asset(let name): button.image = Self.asset(name, height: presentation.assetHeight)
        }
        updateSpinner(presentation.spinning, in: button)
    }

    /// Spins while busy, and keeps spinning through a gap under half a second
    /// - switching PCs, the old stream closes a moment before the next one
    /// starts connecting, and the glyph flashing in between reads as done.
    private func updateSpinner(_ busy: Bool, in button: NSStatusBarButton) {
        if busy {
            spinnerOffWork?.cancel()
            spinnerOffWork = nil
            showSpinner(true, in: button)
            return
        }
        guard spinner.isRunning else { return }
        // Still turning through the grace period, over the glyph just set.
        spinner.run(in: button)
        guard spinnerOffWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.spinnerOffWork = nil
                guard self.model.menuBarPresentation?.spinning != true, let button = self.item.button else { return }
                self.showSpinner(false, in: button)
                self.applyLabel()
            }
        }
        spinnerOffWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private var spinnerOffWork: DispatchWorkItem?

    /// The approved pyramid spinner, as the button's own image in the glyph's
    /// place (MenuBarSpinner).
    private let spinner = MenuBarSpinner()

    private func showSpinner(_ show: Bool, in button: NSStatusBarButton) {
        if show {
            if !spinner.isRunning { Diag.info("menu bar spinner on", "MenuBar") }
            button.setAccessibilityLabel("Shimmer, connecting")
            spinner.run(in: button)
        } else if spinner.isRunning {
            spinner.stop()
            Diag.info("menu bar spinner off", "MenuBar")
        }
    }

    // MARK: - Menu

    /// Rebuilt from the model each time the menu opens, so every row reflects
    /// the moment of opening. While it is up, only the servers' status lines
    /// follow the model (observeServerStatuses), and the streaming server's
    /// numbers refresh once a second.
    func menuWillOpen(_ menu: NSMenu) {
        // Recorded for shimmerctl: if the icon "doesn't respond" and this
        // never fires, the click never reached Shimmer (status-item clicks
        // bypass the app's event stream, so they can't be observed directly).
        AgentControl.shared.menuBarEvent("open")
        Diag.info("menu bar menu opened", "MenuBar")
        menuIsOpen = true
        populate(menu)
        startStatsRefresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        // A failed attempt's error, shown on the card: said, and done with.
        if errorShownInMenu {
            errorShownInMenu = false
            if !model.isStreaming { model.dismissStreamError() }
        }
        statusRows = [:]
        hoveredRow = nil
        expandedHostID = nil
        serversList?.stopAnimating()
        serversList = nil
        statsTimer?.invalidate()
        statsTimer = nil
        applyLabel()
    }

    /// The server whose stream settings are open under it (its chevron),
    /// until the menu closes.
    private var expandedHostID: String?

    /// The Servers rows, one item's view so the opened settings can animate
    /// in place (MenuDisclosureList); kept to toggle it and to carry its
    /// motion across a rebuild of the open menu.
    private weak var serversList: MenuDisclosureList?

    /// The streaming server's row, its stats line refreshed once a second
    /// while the menu is open; the last numbers, so a reopen starts full.
    private weak var statsRow: MenuServerRow?
    private var statsTimer: Timer?
    private var lastStreamNumbers: (rttMs: Double?, mbps: Double?) = (nil, nil)

    /// The Servers rows draw their own highlight, and the menu doesn't
    /// redraw a custom row when the highlight leaves it - so the controller
    /// tells each row, for the pointer and the arrow keys alike.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        highlight(item?.view)
    }

    /// The row under the pointer or the keyboard, from the NSMenu or the panel.
    private func highlight(_ view: NSView?) {
        // The Servers list moves its own band among its rows.
        if !(view is MenuDisclosureList) { serversList?.clearHover() }
        let row = view as? MenuRowView
        guard row !== hoveredRow else { return }
        hoveredRow?.isHovered = false
        row?.isHovered = true
        hoveredRow = row
    }

    private weak var hoveredRow: MenuRowView?

    private var menuIsOpen = false

    /// Rebuild the menu while it stays open - after a pick in the Servers
    /// list, which (like the Sound menu's outputs) leaves the menu up: the
    /// header, the Stream rows and the blue disc all follow the new server.
    /// Run in event-tracking mode, the run loop's mode while a menu is open.
    private func rebuildOpenMenu() {
        RunLoop.main.perform(inModes: [.eventTracking, .default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.populate(self.menu)
                if #available(macOS 27.0, *), let panel = self.panel as? MenuBarPanel, panel.isVisible {
                    panel.reload(items: self.detachedItemViews(), minimumWidth: Self.menuWidth)
                }
            }
        }
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        hoveredRow = nil
        statusRows = [:]
        defer {
            if menuIsOpen {
                observeServerStatuses()
                observeCard()
            }
        }

        // The top: a Now Playing card for the stream - the app, where, and
        // its controls (MenuNowPlayingCard; Kevin's pick of five mock-ups).
        let card = NSMenuItem()
        let cardView = nowPlayingCard()
        cardSignature = cardView.signature
        card.view = cardView
        menu.addItem(card)

        // Stream audio, right under the card as the Sound menu's slider sits
        // under its title - the stream's own level, not the Mac's (quiet
        // speaker, slider, loud speaker; no number, no mute). Shown whether
        // or not a stream is live: the level persists for the next one.
        let volume = NSMenuItem()
        volume.view = MenuVolumeSlider(level: model.streamVolume) { [weak model] level in
            model?.setStreamVolume(level)
        }
        menu.addItem(volume)


        // The servers, listed the way Control Center lists Focus modes and
        // sound outputs: a round mark per machine - its Settings avatar, in
        // colour for the one in use, grey for the rest. Picking another
        // switches to it - a stream in progress closes and reopens there
        // (AppModel.switchHost). This replaced a "Switch PC" submenu.
        // Listed for a single server too: its row carries the stream's
        // stats and opens its settings.
        if !model.hosts.isEmpty {
            menu.addItem(separator())
            menu.addItem(header("Servers"))
            // The one in use: where a switch is headed, else what streams,
            // else the selection - so the disc moves the moment you pick.
            let current = model.pendingHostSwitch?.hostID
                ?? (model.isStreaming ? model.activeStreamHostID : model.selectedHost?.id)
            var rows: [MenuRowView] = []
            var inUseIndex: Int?
            for (index, host) in model.hosts.enumerated() {
                // A custom row, for a click that keeps the menu open, as the
                // Sound menu's outputs do (MenuServerRow).
                let mark = MenuHostMark.image(for: host, look: host.id == current ? .current : .off,
                                              appearance: menu.effectiveAppearance)
                // The one in use (once the selection has caught up with a
                // switch) carries the chevron to its stream settings, like
                // the AirPods in use in the Sound menu.
                let inUse = host.id == current && host.id == model.selectedHost?.id
                if inUse { inUseIndex = index }
                // The one streaming now shows the stream's numbers under its
                // name, as the AirPods show their batteries.
                let streamingHere = model.isStreaming && host.id == model.activeStreamHostID
                let row = MenuServerRow(title: host.displayName, mark: mark, hasDisclosure: inUse) {
                    [weak self] in self?.pickServer(host.id)
                }
                if streamingHere {
                    statsRow = row
                    row.stats = streamStats(rttMs: lastStreamNumbers.rttMs, mbps: lastStreamNumbers.mbps)
                } else {
                    // The rest show how they are - Online, Asleep, Trust
                    // needed - once that's known; nothing while it isn't.
                    row.stats = serverStatus(for: host.id)
                    statusRows[host.id] = row
                }
                row.sizeToContent()
                rows.append(row)
            }
            let settings = inUseIndex.map { (under: $0, view: streamSettingsWell(for: model.hosts[$0]) as NSView) }
            let expanded = inUseIndex.map { model.hosts[$0].id == expandedHostID } ?? false
            let list = MenuDisclosureList(rows: rows, well: settings, expanded: expanded, continuing: serversList)
            serversList = list
            let item = NSMenuItem()
            item.view = list
            menu.addItem(item)
        }

        // Controller battery is shown by the menu-bar icon itself (the battery
        // glyph on the status item), not repeated as a "N% battery" row here.

        // The window and Quit at the bottom - Tailscale's layout, where the
        // window is the exception, not the point. One row for the window - it
        // is Shimmer's settings - named as Control Center's "Focus Settings…"
        // and opening on Servers, as the app menu's Settings… does (Kevin
        // 2026-11-18: one row, and settings); no shortcuts shown, though ⌘, and ⌘Q
        // still work while the menu has the keyboard. The line above runs
        // nearly the menu's width, as the Sound menu's above its Settings row.
        menu.addItem(separator(footer: true))
        // Plain text at the left edge, like Tailscale's. macOS 26 decorates a
        // menu item with a gear of its own when its ACTION is named
        // `openSettings` (measured: the title, the ⌘, and the exact standard
        // title are all irrelevant - only that selector name draws one; the
        // 27 SDK adds `preferredImageVisibility`). So the selector is not
        // called that, and neither row carries an image - an empty image
        // would suppress the gear but reserve the image column and indent.
        menu.addItem(action("Shimmer Settings…", #selector(showSettings), key: ","))
        menu.addItem(separator())
        // No "Check for Updates…" here, by request. Sparkle still checks on
        // its own at launch, and the command stays in the app menu.
        menu.addItem(action("Quit Shimmer", #selector(quit), key: "q"))
    }

    // MARK: - Server status

    /// The servers' rows that show a status line (not the one streaming:
    /// its line is the stream's numbers), until the menu closes.
    private var statusRows: [String: MenuServerRow] = [:]
    private var statusObservation = 0

    /// A server's second line: its status (the sidebar's words), or nothing
    /// until a check has come back - never "Checking…".
    private func serverStatus(for hostID: String) -> [MenuServerRow.Stat] {
        // A failed stream's error is on the card; the server's line stays
        // what the machine is - Offline, not "interrupted".
        let text = model.sidebarStatusText(for: hostID, ignoringStreamError: true)
        return text == "Checking…" ? [] : [.init(symbol: nil, text: text)]
    }

    /// While the menu is open, a status that comes in (a switch's first
    /// check, a server going to sleep) lands on its row at once.
    private func observeServerStatuses() {
        statusObservation += 1
        let generation = statusObservation
        withObservationTracking {
            for id in statusRows.keys { _ = model.sidebarStatusText(for: id, ignoringStreamError: true) }
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.menuIsOpen, generation == self.statusObservation else { return }
                for (id, row) in self.statusRows { row.stats = self.serverStatus(for: id) }
                self.observeServerStatuses()
            }
        }
    }

    // MARK: - The Now Playing card

    /// The card's second line: where the stream is from. A lone PS5 is
    /// already "PlayStation 5" in the title, so it says what it is instead.
    private func cardPlace(_ host: Host) -> String {
        host.hasGenericPlayStationName ? "Remote Play" : host.displayName
    }

    /// What the open menu's card shows, and the watch on what it's made of:
    /// the stream coming up ("Connecting…" to live), ending
    /// or failing while the menu is open redraws it.
    private var cardSignature: String?
    /// The card showed a stream's error while the menu was open.
    private var errorShownInMenu = false
    private var cardObservation = 0

    private func observeCard() {
        cardObservation += 1
        let generation = cardObservation
        withObservationTracking {
            _ = nowPlayingCard().signature
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.menuIsOpen, generation == self.cardObservation else { return }
                // Many things the card reads change without changing it (a
                // status poll's timestamp): rebuild only for a real change.
                if self.nowPlayingCard().signature != self.cardSignature {
                    self.rebuildOpenMenu()
                } else {
                    self.observeCard()
                }
            }
        }
    }

    private func nowPlayingCard() -> MenuNowPlayingCard {
        typealias Control = MenuNowPlayingCard.Control
        guard let host = model.selectedHost else {
            return MenuNowPlayingCard(tile: MenuAppTile.image(.shimmer), title: "Shimmer", subtitle: "No PC paired",
                                      controls: [])
        }
        // A button's click: the menu closes, then the command runs - as a
        // plain item's does, so activation and focus behave the same.
        func run(_ selector: Selector) -> () -> Void {
            { [weak self] in
                guard let self else { return }
                self.closeMenu()
                DispatchQueue.main.async { NSApp.sendAction(selector, to: self, from: nil) }
            }
        }
        let streamHost = model.isStreaming ? (model.hosts.first { $0.id == model.activeStreamHostID } ?? host) : host
        let app = model.heroTargetApp
        // A PS5 is the console itself.
        let title = streamHost.isPlayStation ? "PlayStation 5" : (app?.name ?? model.defaultAppName)
        let tile = MenuAppTile.image(streamHost.isPlayStation ? .playStation : .app(app))
        let stop = Control(symbol: "stop.fill", label: "End Stream", action: run(#selector(endStream)))

        if model.isStreaming {
            let subtitle: String
            if case .streaming = model.streamPhase {
                // Just where it's from, as the card says it at rest: the stop
                // button and the server's stats line already say it's live.
                subtitle = cardPlace(streamHost)
            } else {
                subtitle = model.hostStatusLine(for: streamHost.id)
            }
            // In PiP the button takes it back to the window; otherwise into PiP.
            let pip = model.nativeStreamPictureInPicture
                ? Control(symbol: "pip.exit", label: "Exit Picture in Picture", action: run(#selector(resumeStream)))
                : Control(symbol: "pip.enter", label: "Picture in Picture", action: run(#selector(enterPictureInPicture)))
            // The card itself is the way back to a stream out of sight.
            let back = model.liveStreamRowTitle != nil ? run(#selector(resumeStream)) : nil
            return MenuNowPlayingCard(tile: tile, title: title, subtitle: subtitle, controls: [pip, stop], onOpen: back)
        }
        if model.streamCheckHostID != nil {
            // Asking the PC what it runs, before the connect: the way out.
            return MenuNowPlayingCard(tile: tile, title: title, subtitle: "Connecting to \(host.displayName)…",
                                      controls: [stop])
        }
        if LunaPower.shared.actionInFlight[host.id] == "on" || model.powerWaitHostID == host.id {
            let cancel = Control(symbol: "stop.fill", label: "Stop Waking \(host.displayName)",
                                 action: run(#selector(stopWaking)))
            return MenuNowPlayingCard(tile: tile, title: title, subtitle: "Waking \(host.displayName)…",
                                      controls: [cancel])
        }
        let label = host.isPlayStation ? "Stream PlayStation 5" : model.heroActionLabel
        // The last attempt failed: the card says so in two words (the whole
        // sentence is its tooltip) and its button tries again (Kevin's pick
        // of six mock-ups, 2026-11-18). Seen once, it goes when the menu
        // closes (menuDidClose).
        if let error = model.nativeStreamError, (model.streamErrorHostID ?? host.id) == host.id {
            errorShownInMenu = true
            return MenuNowPlayingCard(tile: tile, title: title, subtitle: StreamFailureCopy.headline(error), alert: error,
                                      controls: [
                Control(symbol: "pip.enter", label: "Try Again in Picture in Picture", action: run(#selector(streamHeroInPiP))),
                Control(symbol: "arrow.clockwise", label: "Try Again", prominent: true, action: run(#selector(streamHero))),
            ])
        }
        // Where it would stream. How that server is doing is its row's
        // second line in Servers, as the AirPods' batteries are theirs.
        return MenuNowPlayingCard(tile: tile, title: title, subtitle: cardPlace(host), controls: [
            Control(symbol: "pip.enter", label: "\(label) in Picture in Picture", action: run(#selector(streamHeroInPiP))),
            Control(symbol: "play.fill", label: label, prominent: true, action: run(#selector(streamHero))),
        ])
    }

    /// The streaming server's second line: the stream's size and rate and
    /// its bitrate, each after its solid glyph, as the AirPods' batteries
    /// are: two screens (`display.2`, Kevin's pick of ~40 symbols) and the
    /// bars. (Not the round trip - Kevin: "we don't need to know the latency
    /// over here".)
    private func streamStats(rttMs: Double?, mbps: Double?) -> [MenuServerRow.Stat] {
        var stats: [MenuServerRow.Stat] = []
        if let shorthand = model.activeStreamShorthand { stats.append(.init(symbol: "display.2", text: shorthand)) }
        if let mbps { stats.append(.init(symbol: "cellularbars", text: "\(Int(mbps.rounded())) Mbps")) }
        if stats.isEmpty, let id = model.activeStreamHostID {
            stats.append(.init(symbol: nil, text: model.hostStatusLine(for: id)))
        }
        return stats
    }

    private func startStatsRefresh() {
        statsTimer?.invalidate()
        statsTimer = nil
        guard model.isStreaming else { return }
        refreshStats()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStats() }
        }
        // The menu's run loop mode while it's open.
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    private func refreshStats() {
        Task { [weak self] in
            guard let self else { return }
            let numbers = await self.model.liveStreamNumbers()
            self.lastStreamNumbers = numbers
            self.statsRow?.stats = self.streamStats(rttMs: numbers.rttMs, mbps: numbers.mbps)
        }
    }

    // MARK: - Actions

    /// Straight into Picture in Picture: no activation - the app you're in
    /// stays in front, and Shimmer stays headless while the stream is in PiP.
    @objc private func streamHeroInPiP() {
        model.pictureInPictureLaunchRequestedAt = Date()
        model.streamDefaultApp()
    }

    @objc private func streamHero() {
        model.streamDefaultApp()
        // Claim activation NOW, while the app is still .accessory: this click
        // is the user-interaction grant cooperative activation needs, and it
        // is good for a moment, not the seconds a connect takes. The model
        // flips us to .regular a beat later (AppModel.isStreaming) - after
        // this has landed, because AppKit drops an activate() issued in the
        // same turn as a policy change. Active with no window yet is fine:
        // the stream window then arrives in the active app's stage, in front,
        // instead of behind whatever Stage Manager had up. (The menu's
        // header row makes macOS refuse a plain activate(): see
        // AppDelegate.activateFromMenuBar.)
        AppDelegate.activateFromMenuBar()
    }

    @objc private func resumeStream() {
        // Over another app's full screen Shimmer stays a menu-bar app: the
        // stream window joins that Space instead of macOS moving the user.
        if Self.frontmostAppIsFullScreen() {
            AppDelegate.activateFromMenuBar()
            model.resumeStreamWindow()
            return
        }
        // Claim activation inside this click: cooperative activation honours
        // a request made while handling the user's event, and Shimmer may be
        // headless (stream only in PiP) - by the time the session's async hop
        // asks, the grant has lapsed (measured 2026-11-16: never activated).
        // A bare app doing exactly this activates within ~80 ms; Shimmer's
        // menu needs the stronger call (AppDelegate.activateFromMenuBar).
        StreamWindow.becomeRegularApp()
        AppDelegate.activateFromMenuBar()
        model.resumeStreamWindow()
    }
    @objc private func enterPictureInPicture() { model.enterPictureInPicture() }
    @objc private func endStream() { model.endStream() }
    @objc private func stopWaking() {
        guard let host = model.selectedHost else { return }
        model.cancelWake(host)
    }

    /// A click in the Servers list: switch, and keep the menu open on the
    /// new server, the way picking a Sound output does.
    private func pickServer(_ id: String) {
        guard let host = model.hosts.first(where: { $0.id == id }) else { return }
        let current = model.pendingHostSwitch?.hostID
            ?? (model.isStreaming ? model.activeStreamHostID : model.selectedHost?.id)
        if host.id != current {
            expandedHostID = nil
            model.switchHost(to: host)
        } else if host.id == model.selectedHost?.id {
            // The one in use: open or close its settings, in place - the
            // list animates it; nothing else in the menu changes.
            expandedHostID = expandedHostID == host.id ? nil : host.id
            serversList?.setExpanded(expandedHostID == host.id)
            return
        }
        rebuildOpenMenu()
    }

    // MARK: - The server in use's stream settings

    /// Opened in place under the server in use (its chevron): Resolution,
    /// Frame Rate and HDR as segmented switchers, Bitrate as a slider - the
    /// same per-PC settings as the Settings window, applied to the next
    /// stream; the menu stays open. A PS5 offers its own: 720p or 1080p,
    /// 30 or 60, up to 100 Mbps. Kevin chose this layout from real
    /// mock-ups (design/menu-bar, 2026-11-18).
    private func streamSettingsWell(for host: Host) -> MenuDisclosureWell {
        var groups: [MenuDisclosureWell.Group] = []
        func section(_ title: String, _ view: NSView) { groups.append(.init(title: title, view: view)) }
        if host.isPlayStation {
            let settings = PlayStationSettings.forConsole(host.id)
            let heights = [720, 1080], rates = [30, 60]
            section("Resolution", MenuSegmentRow(labels: heights.map { "\($0)p" },
                                                 selected: heights.firstIndex(of: settings.height),
                                                 accessibilityTitle: "Resolution") { settings.height = heights[$0] })
            section("Frame Rate", MenuSegmentRow(labels: rates.map(String.init), selected: rates.firstIndex(of: settings.fps),
                                                 accessibilityTitle: "Frame rate") { settings.fps = rates[$0] })
            let stops = BitrateSlider.stopsMbps.filter { PlayStationSettings.bitrateRangeMbps.contains($0) }
            section("Bitrate", MenuBitrateRow(stops: stops, mbps: settings.bitrateAuto ? nil : settings.bitrateMbps,
                                              autoMbps: settings.height > 720 ? PlayStationSettings.presetBitrateMbps : nil) {
                if let mbps = $0 { settings.bitrateMbps = mbps; settings.bitrateAuto = false } else { settings.bitrateAuto = true }
            })
            section("HDR", MenuSegmentRow(labels: ["Off", "On"], selected: settings.hdr ? 1 : 0,
                                          accessibilityTitle: "HDR") { settings.hdr = $0 == 1 })
        } else {
            let model = model
            let sizes = CommonResolution.allCases
            let selectedSize = sizes.firstIndex { model.resolutionChoice == .standard($0) }
            section("Resolution", MenuSegmentRow(labels: sizes.map { $0 == .uhd4K ? "4K" : $0.shortLabel },
                                                 selected: selectedSize, accessibilityTitle: "Resolution") { [weak self] in
                model.apply(.standard(sizes[$0]))
                // Automatic's number follows the size.
                self?.rebuildOpenMenu()
            })
            // The rates a screen here can show (and the one set, if higher).
            let fastest = max(60, NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60)
            let rates = FrameRateChoice.standardRates.filter { $0 <= fastest || $0 == model.customFPS }
            section("Frame Rate", MenuSegmentRow(labels: rates.map(String.init), selected: rates.firstIndex(of: model.customFPS),
                                                 accessibilityTitle: "Frame rate") { [weak self] in
                model.apply(.fixed(rates[$0]))
                self?.rebuildOpenMenu()
            })
            section("Bitrate", MenuBitrateRow(stops: BitrateSlider.stopsMbps,
                                              mbps: model.bitrateAuto ? nil : model.manualBitrateMbps,
                                              autoMbps: model.recommendedBitrateMbpsNow) {
                if let mbps = $0 { model.manualBitrateMbps = mbps; model.bitrateAuto = false } else { model.bitrateAuto = true }
            })
            section("HDR", MenuSegmentRow(labels: ["Off", "On"], selected: model.customHDR ? 1 : 0,
                                          accessibilityTitle: "HDR") { model.customHDR = $0 == 1 })
        }
        if model.isStreaming, model.activeStreamHostID == host.id {
            groups.append(.init(title: nil, view: MenuNoteRow("Changes apply to the next stream.")))
        }
        // The mouse, live (a PlayStation has none): the menu's old
        // "Disable Mouse" row, moved here with the card taking the top.
        if !host.isPlayStation {
            let model = model
            groups.append(.init(title: "Mouse", view: MenuSegmentRow(labels: ["On", "Off"],
                                                                     selected: model.mouseInputDisabled ? 1 : 0,
                                                                     accessibilityTitle: "Mouse input") {
                model.mouseInputDisabled = $0 == 1
            }))
        }
        return MenuDisclosureWell(groups: groups)
    }

    @objc private func showSettings() {
        model.settingsTab = .computers
        AppDelegate.showMainWindow()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - The panel (macOS 27)

    /// The panel the menu shows in on macOS 27 (MenuBarPanel), made on
    /// first open.
    private var panel: NSPanel?

    /// The built menu's rows, taken off their items for the panel: an
    /// item keeps setting its view's frame (to the origin) while it holds it.
    private func detachedItemViews() -> [NSView] {
        menu.items.compactMap { item in
            let view = item.view
            item.view = nil
            return view
        }
    }

    /// Closes the menu, wherever it's showing.
    private func closeMenu() {
        if #available(macOS 27.0, *) {
            if let session = item.expandedInterfaceSession {
                session.cancel()
                return
            }
            // Opened by `shimmerctl menu`, with no session.
            if let panel = panel as? MenuBarPanel, panel.isVisible {
                panel.dismiss(animated: true)
                menuDidClose(menu)
                return
            }
        }
        menu.cancelTracking()
    }

    /// `shimmerctl menu`: the menu opened or closed, or the server in
    /// use's settings opened or closed in it - with no pointer, and without
    /// taking the keyboard from whoever is at the Mac. For looking at the
    /// menu, or recording it, from another machine.
    func agentMenu(_ action: String) -> String {
        switch action {
        case "open":
            guard !menuIsOpen else { return "already open" }
            guard item.isVisible, let button = item.button else { return "no menu bar item to open under" }
            if #available(macOS 27.0, *) {
                openPanel(under: button, takingKeyboard: false)
            } else {
                // An NSMenu tracks until it closes: after the answer.
                DispatchQueue.main.async { button.performClick(nil) }
            }
            return "ok"
        case "close":
            guard menuIsOpen else { return "not open" }
            closeMenu()
            return "ok"
        case "settings":
            guard menuIsOpen, serversList != nil, let host = model.selectedHost else {
                return "the menu is not open on a server"
            }
            pickServer(host.id)
            return expandedHostID == host.id ? "settings open" : "settings closed"
        default:
            return "action must be open, close or settings"
        }
    }

    /// A ⌘-shortcut while the panel has the keyboard: the item that carries
    /// it closes the menu and runs, as in an NSMenu.
    private func performKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased(),
              let match = menu.items.first(where: { !$0.keyEquivalent.isEmpty && $0.keyEquivalent == key }),
              let action = match.action else { return false }
        closeMenu()
        DispatchQueue.main.async { NSApp.sendAction(action, to: match.target, from: match) }
        return true
    }

    // MARK: - Item helpers

    /// A command row. Drawn by Shimmer (MenuActionRow) so its hover is the
    /// soft grey of Apple's own menu bar menus, not AppKit's accent-blue bar;
    /// the item keeps its action and shortcut for the keyboard, unshown. The image
    /// is for accessibility only - macOS 27 hides a status menu item's image
    /// unless asked, and the rows have always shown without one.
    private func action(_ title: String, _ selector: Selector, key: String = "", image: NSImage? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.image = image
        item.view = MenuActionRow(title: title) { [weak self, weak item] in
            // A plain item's click: the menu closes, then the action runs.
            guard let item else { return }
            self?.closeMenu()
            DispatchQueue.main.async { NSApp.sendAction(selector, to: self, from: item) }
        }
        return item
    }

    /// Control Center's separator, not NSMenu's: its line 14 pt in from
    /// each side (5 pt for the one above the footer), and its height.
    private func separator(footer: Bool = false) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = MenuSeparatorRow(inset: footer ? 5 : MenuRowView.contentInset)
        return item
    }

    /// Control Center's section header ("Output"), not NSMenu's.
    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = MenuSectionHeaderRow(title)
        return item
    }

    /// A library app's glyph as a menu image: an SF Symbol, or the bundled
    /// template art (Steam's mark) at the symbol's size.
    private func glyph(_ app: LibraryApp?) -> NSImage? {
        guard let app else { return nil }
        switch app.glyph {
        case .symbol(let name): return Self.symbol(name)
        case .asset(let name): return Self.asset(name, height: 12)
        }
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// Bundled template art; `height` scales it keeping its aspect (the
    /// DualSense mark is authored at the menu bar's 20x14).
    private static func asset(_ name: String, height: CGFloat? = nil) -> NSImage? {
        guard let image = NSImage(named: name)?.copy() as? NSImage else { return nil }
        image.isTemplate = true
        if let height, image.size.height > 0 {
            image.size = NSSize(width: image.size.width * height / image.size.height, height: height)
        }
        return image
    }
}

// MARK: - The expanded-interface session (macOS 27)

@available(macOS 27.0, *)
extension MenuBarController: @MainActor NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin expandedInterfaceSession: NSStatusItemExpandedInterfaceSession) {
        guard let button = statusItem.button else { expandedInterfaceSession.cancel(); return }
        openPanel(under: button, takingKeyboard: true)
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        Diag.info("menu bar menu closed (session ended, animated=\(animated))", "MenuBar")
        (panel as? MenuBarPanel)?.dismiss(animated: animated)
        menuDidClose(menu)
    }

    /// Builds the menu and shows it in the panel under the item.
    fileprivate func openPanel(under button: NSStatusBarButton, takingKeyboard: Bool) {
        let panel = (self.panel as? MenuBarPanel) ?? MenuBarPanel()
        self.panel = panel
        panel.onCancel = { [weak self] why in
            Diag.info("menu bar menu closing: \(why)", "MenuBar")
            self?.closeMenu()
        }
        panel.onKeyEquivalent = { [weak self] event in self?.performKeyEquivalent(event) ?? false }
        panel.onHover = { [weak self] view in self?.highlight(view) }
        menuWillOpen(menu)
        panel.show(items: detachedItemViews(), minimumWidth: Self.menuWidth, under: button,
                   takingKeyboard: takingKeyboard)
    }
}
