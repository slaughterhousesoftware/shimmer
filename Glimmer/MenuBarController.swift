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
    /// Width the hosted rows lay out at; the standard items pad out to match.
    private static let menuWidth: CGFloat = 250

    private let model: AppModel
    private let item: NSStatusItem
    private let menu = NSMenu()

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = false
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
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
    /// the moment of opening; nothing here is observed while the menu is up.
    func menuWillOpen(_ menu: NSMenu) {
        // Recorded for shimmerctl: if the icon "doesn't respond" and this
        // never fires, the click never reached Shimmer (status-item clicks
        // bypass the app's event stream, so they can't be observed directly).
        AgentControl.shared.menuBarEvent("open")
        Diag.info("menu bar menu opened", "MenuBar")
        menuIsOpen = true
        populate(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        applyLabel()
    }

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
            }
        }
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        // The header: the PC's name over its live status, inert.
        let title = model.selectedHost?.displayName ?? "Shimmer"
        let status = model.selectedHost == nil ? "No PC paired" : model.selectedHostStatusLine
        menu.addItem(hosted(MenuHeaderRow(title: title, status: status)))
        menu.addItem(.separator())

        if let error = model.nativeStreamError {
            menu.addItem(hosted(
                Text(error)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            ))
            menu.addItem(action("Dismiss", #selector(dismissWarning)))
            menu.addItem(.separator())
        }

        // A PC wake under way (the spinner is up): the way out of it, first.
        if let host = model.selectedHost,
           LunaPower.shared.actionInFlight[host.id] == "on" || model.powerWaitHostID == host.id {
            menu.addItem(action("Stop Waking \(host.displayName)", #selector(stopWaking)))
            menu.addItem(.separator())
        }

        if model.selectedHost != nil {
            if model.isStreaming {
                // The rows follow where the stream is: in PiP the way back is
                // "Exit Picture in Picture"; with the window hidden it is "Back
                // to X" plus Picture in Picture; with the window in front only
                // Picture in Picture. A PS5 has no mouse, so no mouse row.
                if let title = model.liveStreamRowTitle {
                    let inPiP = model.nativeStreamPictureInPicture
                    menu.addItem(action(title, #selector(resumeStream),
                                        image: inPiP ? Self.symbol("pip.exit")
                                            : glyph(model.heroTargetApp)
                                                ?? Self.symbol("arrow.up.left.and.arrow.down.right")))
                }
                if !model.nativeStreamPictureInPicture {
                    menu.addItem(action("Picture in Picture", #selector(enterPictureInPicture),
                                        image: Self.symbol("pip.enter")))
                }
                if !model.activeStreamIsPlayStation { menu.addItem(mouseInputRow()) }
                // End the stream, not Shimmer. A disconnect: the game stays up
                // on the PC unless Settings › "Quit the game on the PC" is on,
                // and "Back to X" is not offered again because the session is
                // gone - the hero row relaunches / resumes it.
                menu.addItem(action("End Stream", #selector(endStream),
                                    image: Self.symbol("stop.circle")))
            } else if model.streamCheckHostID != nil {
                // Still asking the PC what it runs, before the connect: the
                // stream is on its way, so the way out, not a second start.
                menu.addItem(action("End Stream", #selector(endStream),
                                    image: Self.symbol("stop.circle")))
            } else {
                // Named AND iconed off the app this actually launches - the one
                // you streamed here last, not a fixed "Desktop". If the PC still
                // has it up from an earlier disconnect, this resumes it.
                menu.addItem(action(model.heroActionLabel, #selector(streamHero),
                                    image: glyph(model.heroTargetApp) ?? Self.symbol("play.fill")))
                menu.addItem(action("\(model.heroActionLabel) in Picture in Picture", #selector(streamHeroInPiP),
                                    image: Self.symbol("pip.enter")))
                if !model.activeStreamIsPlayStation { menu.addItem(mouseInputRow()) }
            }
        }

        // The servers, listed the way the Sound menu lists its outputs: a
        // round mark per machine (PlayStation, Tux, Windows, Apple), the one in
        // use filled with the accent colour. Picking another switches to it - a
        // stream in progress closes and reopens there (AppModel.switchHost).
        // This replaced a "Switch PC" submenu.
        if model.hosts.count > 1 {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Servers"))
            // The one in use: where a switch is headed, else what streams,
            // else the selection - so the disc moves the moment you pick.
            let current = model.pendingHostSwitch?.hostID
                ?? (model.isStreaming ? model.activeStreamHostID : model.selectedHost?.id)
            for host in model.hosts {
                // A custom row, as the Sound menu's are: a grey hover, and a
                // click that keeps the menu open (MenuServerRow). The item's
                // own action is for the keyboard (arrow to it, Return).
                let row = action(host.displayName, #selector(switchHost))
                row.representedObject = host.id
                row.view = MenuServerRow(title: host.displayName,
                                         mark: MenuHostMark.image(for: host, current: host.id == current)) {
                    [weak self] in self?.pickServer(host.id)
                }
                menu.addItem(row)
            }
        }

        // Stream audio - the stream's own level, not the Mac's: the Sound
        // menu's slider, copied (quiet speaker, slider, loud speaker; no
        // number, no mute - silent is the slider at the left). Shown whether
        // or not a stream is live: the level persists, so it can be set
        // before the next stream too.
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Stream Audio"))
        let volume = NSMenuItem()
        volume.view = MenuVolumeSlider(level: model.streamVolume) { [weak model] level in
            model?.setStreamVolume(level)
        }
        menu.addItem(volume)

        // Controller battery is shown by the menu-bar icon itself (the battery
        // glyph on the status item), not repeated as a "N% battery" row here.

        // The window rows and Quit at the bottom - Tailscale's layout, where
        // the window is the exception, not the point. Both open the same
        // tabbed window: Settings on its tab, Open Shimmer on the last one.
        menu.addItem(.separator())
        // Plain text at the left edge, like Tailscale's. macOS 26 decorates a
        // menu item with a gear of its own when its ACTION is named
        // `openSettings` (measured: the title, the ⌘, and the exact standard
        // title are all irrelevant - only that selector name draws one; the
        // 27 SDK adds `preferredImageVisibility`). So the selector is not
        // called that, and neither row carries an image - an empty image
        // would suppress the gear but reserve the image column and indent.
        menu.addItem(action("Settings…", #selector(showSettingsPage), key: ","))
        menu.addItem(action("Open Shimmer", #selector(openWindow)))
        menu.addItem(.separator())
        // No "Check for Updates…" here, by request. Sparkle still checks on
        // its own at launch, and the command stays in the app menu.
        menu.addItem(action("Quit Shimmer", #selector(quit), key: "q"))
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
    @objc private func dismissWarning() { model.dismissStreamError() }
    @objc private func stopWaking() {
        guard let host = model.selectedHost else { return }
        model.cancelWake(host)
    }

    @objc private func switchHost(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let host = model.hosts.first(where: { $0.id == id }) else { return }
        model.switchHost(to: host)
    }

    /// A click in the Servers list: switch, and keep the menu open on the
    /// new server, the way picking a Sound output does.
    private func pickServer(_ id: String) {
        guard let host = model.hosts.first(where: { $0.id == id }) else { return }
        let current = model.pendingHostSwitch?.hostID
            ?? (model.isStreaming ? model.activeStreamHostID : model.selectedHost?.id)
        if host.id != current { model.switchHost(to: host) }
        rebuildOpenMenu()
    }

    /// A verb that flips with the state. Listed idle too: the choice persists,
    /// so it can be set before the next stream as well as during one.
    private func mouseInputRow() -> NSMenuItem {
        action(model.mouseInputDisabled ? "Enable Mouse" : "Disable Mouse",
               #selector(toggleMouseInput), image: Self.symbol("computermouse"))
    }

    @objc private func toggleMouseInput() { model.mouseInputDisabled.toggle() }

    @objc private func showSettingsPage() {
        model.settingsTab = .computers
        AppDelegate.showMainWindow()
    }

    @objc private func openWindow() {
        AppDelegate.showMainWindow()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Item helpers

    private func action(_ title: String, _ selector: Selector, key: String = "", image: NSImage? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.image = image
        return item
    }

    private func hosted<Content: View>(_ content: Content) -> NSMenuItem {
        let view = NSHostingView(rootView: content.frame(width: Self.menuWidth))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        let item = NSMenuItem()
        item.view = view
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

// MARK: - Hosted rows

/// The PC's name in the menu's own 13pt over its status in the 11pt small
/// size, secondary - Tailscale's header, as measured off it at 2x for
/// ergodriven-tempo-mac's MenuHeaderRow: regular weight (the size and the
/// colour do the work), no extra spacing, cap top 9pt below the panel's edge.
struct MenuHeaderRow: View {
    let title: String
    let status: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 13))
            Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 1)
        .padding(.bottom, 2)
    }
}
