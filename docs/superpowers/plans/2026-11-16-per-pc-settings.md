# Per-PC settings on the Servers page — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each PC / PS5 keeps its own stream settings, shown on its page in the Servers tab (sidebar of plain system logos, Stream row first), with the Sunshine and PlayStation tabs removed.

**Architecture:** Sunshine settings stay as AppModel's live properties (the whole QualityCalculator machinery reads them) but become the *selected host's* copy: selecting a host loads its saved `HostStreamSettings`, every edit saves back to it. PS5 settings become one `PlayStationSettings` instance per console (key prefix per host). A small `HostSystemKind` detector picks the logo. The Servers detail view hosts the panes; the spike on branch `ui-mockups` is the visual reference.

**Tech Stack:** Swift 6, SwiftUI + AppKit, Swift Testing, UserDefaults. Build/test: `make test`; release + stage: scratchpad `rel-stage.sh`.

**Spec:** `docs/superpowers/specs/2026-11-16-per-pc-settings-design.md`

## Global Constraints

- Tabs: Servers, General, About only. A remembered tab of `stream` or `playStation` opens Servers.
- Window 780 pt wide on every tab.
- Existing machines start with today's values; machines added later start from defaults.
- Logos: plain monochrome marks in the text colour; no discs, tiles, avatars or icon picking. Bazzite shows Linux.
- Bitrate snap points exactly `[5, 10, 15, 20, 30, 40, 50, 75, 100, 150, 200, 300]` Mbps; PS5 capped at 100.
- Right side: no title, no big icon, no latency graph, no header bar.
- Spec deviation (builder's call, recorded): Mac detection uses the host name only (no Bonjour `_device-info`) — a Mac Sunshine host is rare; Windows by TTL.

## Review Focus

- Switch PC (any path) streams with the *target* PC's settings, not the previously selected PC's — test in Task 1 (`selectingAHostLoadsItsSettings`).
- Editing settings on PC A, selecting B, back to A: A's edits survive — Task 1 (`editsPersistPerHost`).
- First launch after upgrade: every existing host gets today's values; a host added afterwards gets defaults — Task 1 (`migrationSeedsExistingHostsOnly`), Task 2 (`existingConsoleKeepsGlobalValues`).
- "Quit the game when the stream ends" read at stop time uses the streaming host's value, not the selected one's — Task 1 (`quitSettingFollowsStreamingHost`).
- A host whose ping fails keeps its cached logo / falls back to Linux — Task 3 (`unreachableHostIsLinux`).

---

### Task 1: Sunshine settings per host

**Files:**
- Create: `Glimmer/Models/HostStreamSettings.swift`
- Modify: `Glimmer/AppModel.swift` (didSets of `qualityPreset`, `customWidth`, `customHeight`, `customFPS`, `bitrateAuto`, `manualBitrateMbps`, `customHDR`, `quitAppWhenStreamEnds`), `Glimmer/HostsStore.swift:371` (`selectHost`), `Glimmer/AppModel+Lifecycle.swift` (launch migration), `Glimmer/AppModel+Streaming.swift` (`quitAppOnStopProvider`)
- Test: `GlimmerTests/HostStreamSettingsTests.swift`

**Interfaces:**
- Produces: `struct HostStreamSettings: Codable, Equatable { qualityPreset: String; customWidth, customHeight, customFPS: Int; bitrateAuto: Bool; manualBitrateMbps: Int; customHDR, quitAppWhenStreamEnds: Bool; static let defaults; static func load(hostID:, defaults: UserDefaults = .standard) -> HostStreamSettings?; func save(hostID:, defaults:) }` (key `glimmer.streamSettings.<hostID>`, JSON).
- Produces on AppModel: `func currentHostStreamSettings() -> HostStreamSettings`, `func loadHostStreamSettings(_:)` (assigns under `isRestoringDefaults`, then `persistQualitySettings()`), `func streamSettings(for hostID: String) -> HostStreamSettings` (live copy if selected, else stored, else `.defaults`), `func migrateStreamSettingsToHosts()` (one-time flag `glimmer.streamSettingsMigrated`).

- [ ] Step 1: Tests — `selectingAHostLoadsItsSettings` (save A=1440p/120, B=1080p/60; `selectHost(B)` → `customFPS == 60`), `editsPersistPerHost`, `migrationSeedsExistingHostsOnly` (hosts present at migration get the current values; a host created after gets `.defaults` on first select), `quitSettingFollowsStreamingHost` (`streamSettings(for: A).quitAppWhenStreamEnds` independent of selection). Use a suite-scoped `UserDefaults(suiteName:)`.
- [ ] Step 2: `make test` → new tests fail.
- [ ] Step 3: Implement. Each listed didSet also calls `saveSelectedHostStreamSettings()` (no-op while `isRestoringDefaults` or no selection). `selectHost` loads (or seeds `.defaults` and saves). Lifecycle runs the migration once after hosts load. `quitAppOnStopProvider` captures `host.id` and reads `streamSettings(for:)`.
- [ ] Step 4: `make test` → all pass.
- [ ] Step 5: Commit "Stream settings per PC".

### Task 2: PS5 settings per console

**Files:**
- Modify: `Glimmer/PlayStation/PlayStationSettings.swift` (init takes `hostID`; keys `PS5.<hostID>.<name>`; `static func forConsole(_ hostID: String) -> PlayStationSettings` cache; migration copies global `PS5.<name>` values once per console), `Glimmer/PlayStation/AppModel+PlayStation.swift:55` (`playStationStreamOptions(for host: Host)`), its callers in `AppModel+Streaming.swift`, `Glimmer/PlayStation/PlayStationSettingsPane.swift` (`init(settings: PlayStationSettings)`)
- Test: `GlimmerTests/PlayStationSettingsTests.swift` (create or extend)

**Interfaces:**
- Produces: `PlayStationSettings.forConsole(_:)`; `AppModel.playStationStreamOptions(for: Host) -> PlayStationStreamOptions`.

- [ ] Step 1: Tests — `consolesKeepSeparateSettings`, `existingConsoleKeepsGlobalValues` (global `PS5.fps=30` before first `forConsole` → that console reads 30), `newConsoleAfterMigrationGetsDefaults`.
- [ ] Step 2: `make test` → fail.
- [ ] Step 3: Implement; remove `PlayStationSettings.shared` uses.
- [ ] Step 4: `make test` → pass.
- [ ] Step 5: Commit "PS5 settings per console".

### Task 3: System kind detection and logo

**Files:**
- Create: `Glimmer/Models/HostSystemKind.swift`, `Glimmer/HostSystemLogo.swift`
- Modify: `Glimmer/ContentView+Menus.swift` (remove the icon-choosing submenu), `Glimmer/LibraryWindow.swift` (drop `HostIdentityIcon` uses)
- Test: `GlimmerTests/HostSystemKindTests.swift`

**Interfaces:**
- Produces: `enum HostSystemKind: String { linux, windows, mac, playStation; static func resolve(isPlayStation: Bool, ttl: Int?, serverName: String) -> Self; static func cached(hostID:) -> Self?; static func detect(host: Host, address: String) async -> Self }` (cache key `glimmer.hostSystem.<id>`; TTL via `/sbin/ping -c 1 -t 2`, TTL > 64 → windows; name says Mac → mac); `struct HostSystemLogo: View { host: Host; size: CGFloat }` — PlayStation `playstation.logo`, Mac `apple.logo`, Windows `HostLogo-windows`, Linux `HostLogo-linux`, all template in `.primary`, optical scales 0.92 / 0.78 / 0.74 / 0.9 of `size` (spike values).

- [ ] Step 1: Tests — `ps5IsPlayStation`, `ttl128IsWindows`, `ttl64IsLinux`, `macNameIsMac`, `unreachableHostIsLinux` (ttl nil, name "bazzite" → linux).
- [ ] Step 2: `make test` → fail. Step 3: implement. Step 4: pass. Step 5: commit "Host system detected; plain logos".

### Task 4: Servers page layout, tabs, controls

**Files:**
- Modify: `Glimmer/SettingsChrome.swift` (tab filter → real `allCases` = computers, general, about; keep raw values decodable: `stream`/`playStation` map to `.computers`; `windowWidth = 780`; `BitrateSlider` with `stopsMbps`), `Glimmer/SettingsView.swift` (drop the two pages), `Glimmer/LibraryWindow.swift` (sidebar groups "PCs"/"Consoles", two-line rows with `HostSystemLogo` size 22 + status dot, "+" add button; detail = `ScrollView` of Stream row → panes, "…" overlay; remove latency section and the app list), `Glimmer/SettingsStreamPane.swift` + `Glimmer/SettingsVideoPane.swift` (Stream pane = Resolution, Frame rate, Bitrate, When the stream ends; `BitrateSlider`), `Glimmer/PlayStation/PlayStationSettingsPane.swift` (Frame rate / Codec / Presentation / Haptics popups, HDR checkbox needs HEVC, `BitrateSlider` max 100), `Glimmer/AppModel.swift` (`bitrateAuto` snap uses `BitrateSlider.stopsMbps`), `Glimmer/MenuBarController.swift:404`, `Glimmer/GlimmerApp.swift:173` (open `.computers` with the host selected)
- Test: `GlimmerTests/SettingsLayoutTests.swift`

**Interfaces:**
- Consumes: Task 1 `streamSettings(for:)`, Task 2 `PlayStationSettings.forConsole`, Task 3 `HostSystemLogo`.
- Produces: `BitrateSlider.nearestStopIndex(mbps: Int, maxMbps: Int) -> Int` (static, tested).

- [ ] Step 1: Tests — `onlyThreeTabs` (`SettingsTab.allCases.map(\.rawValue) == ["computers","general","about"]`), `removedTabsOpenServers` (`SettingsTab(persisted: "stream") == .computers`), `bitrateStops` (`nearestStopIndex(mbps: 100, maxMbps: 100) == 8`, `nearestStopIndex(mbps: 25, maxMbps: 300) == 3`).
- [ ] Step 2: `make test` → fail. Step 3: implement, porting the spike's look (branch `ui-mockups`: Stream row with game popup + borderedProminent Stream/Resume + Picture in Picture, disabled while streaming; equal popup widths via `.settingsControl()`). Step 4: pass.
- [ ] Step 5: Visual check: stage on the MacBook, `--debug-snap=bazzite` / `ps5` captures, compare with the spike captures.
- [ ] Step 6: Commit "Servers page holds each machine's settings".

### Task 5: Ship

- [ ] Remove `DebugMockups.swift`'s spike views (keep `--debug-snap`), `make test`, release build, install on the MacBook (`/Applications`, backup kept), capture both pages, commit.
