//
//  AppModel+HostStreamSettings.swift
//
//  Stream settings per PC. AppModel's quality properties (qualityPreset,
//  custom size / fps, bitrate, HDR, quit-on-end) hold the SELECTED PC's
//  settings: selecting a PC loads its saved copy, and every edit saves back to
//  it. A PS5 has its own settings (PlayStationSettings.forConsole) and leaves
//  these alone.
//

import Foundation

extension AppModel {
    /// The live properties as a settings value.
    func currentHostStreamSettings() -> HostStreamSettings {
        HostStreamSettings(
            qualityPreset: qualityPreset.rawValue, customWidth: customWidth, customHeight: customHeight,
            customFPS: customFPS, bitrateAuto: bitrateAuto, manualBitrateMbps: manualBitrateMbps,
            customHDR: customHDR, quitAppWhenStreamEnds: quitAppWhenStreamEnds)
    }

    /// Put `settings` in the live properties without anything counting as a
    /// user edit, then recompute the effective stream values.
    func loadHostStreamSettings(_ settings: HostStreamSettings) {
        isRestoringDefaults = true
        qualityPreset = QualityPreset(rawValue: settings.qualityPreset) ?? .defaultPreset
        customWidth = settings.customWidth
        customHeight = settings.customHeight
        customFPS = settings.customFPS
        bitrateAuto = settings.bitrateAuto
        manualBitrateMbps = settings.manualBitrateMbps
        customHDR = settings.customHDR
        quitAppWhenStreamEnds = settings.quitAppWhenStreamEnds
        isRestoringDefaults = false
        persistQualitySettings()
    }

    /// An edit to the live properties: save it as the selected PC's.
    func saveSelectedHostStreamSettings() {
        guard !isRestoringDefaults, let host = selectedHost, !host.isPlayStation else { return }
        currentHostStreamSettings().save(hostID: host.id)
    }

    /// The selected PC became `host`: its own settings go live (a PC never
    /// seen before starts from the defaults).
    func applyStreamSettings(forSelected host: Host) {
        guard !host.isPlayStation else { return }
        let saved = HostStreamSettings.load(hostID: host.id)
        let display = smartDefaultsForCurrentDisplay(), hidpi = hidpiDefaultsForCurrentDisplay()
        // Resolution and frame rate offer standard values only: a PC saved on
        // a removed choice moves to the nearest one, and keeps it.
        let settings = (saved ?? .defaults).withStandardResolution(
            display: (display.width, display.height), hidpi: (hidpi.width, hidpi.height))
            .withStandardFrameRate()
        loadHostStreamSettings(settings)
        if settings != saved { settings.save(hostID: host.id) }
    }

    /// A stream is starting on `host`: make it the selected PC, so the live
    /// settings the stream config reads are its own (the user may have
    /// clicked another PC while this one's status was being checked).
    func selectForStream(_ host: Host) {
        guard !host.isPlayStation, selectedHost?.id != host.id,
              let known = hosts.first(where: { $0.id == host.id }) else { return }
        selectHost(known)
    }

    /// `hostID`'s settings, whether or not it is the selected PC.
    func streamSettings(for hostID: String) -> HostStreamSettings {
        if selectedHost?.id == hostID { return currentHostStreamSettings() }
        return HostStreamSettings.load(hostID: hostID) ?? .defaults
    }

    /// Once, when per-PC settings arrive: every PC already paired keeps the
    /// settings it streams with today.
    func migrateStreamSettingsToHosts(_ hosts: [Host], force: Bool = false) {
        let key = "glimmer.streamSettingsMigrated"
        guard force || !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let today = currentHostStreamSettings()
        for host in hosts where !host.isPlayStation && HostStreamSettings.load(hostID: host.id) == nil {
            today.save(hostID: host.id)
        }
    }
}
