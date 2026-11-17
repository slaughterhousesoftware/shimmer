# Per-PC settings on the Servers page — design

Approved by Kevin 2026-11-16 ("build this"), after real-app mockups on the MacBook
(scratch branch `ui-mockups`, captures in the session scratchpad).

## Why

Settings live next to what they affect: a PC's or console's stream settings are on that
machine's page, not in separate Sunshine / PlayStation tabs. The page is not an "account"
screen: machines are shown by the system they run.

## What

- **Tabs:** Servers, General, About. Sunshine and PlayStation tabs are removed.
- **Sidebar (Servers):** a macOS source list grouped under "PCs" and "Consoles". Each row:
  plain system logo, name, address on a second line, status dot at the trailing edge.
  Tailscale's bottom bar: "Add by Address…" (the existing popover) and a pull-down for the
  selected machine (Rename, Remove). Right-click has the same two actions.
  (Revised 2026-11-16 at Kevin's request: the "+" and the "…" menu are gone.)
- **System logo, detected automatically, never picked:** Linux (Tux), Windows, Mac (Apple),
  PlayStation — plain monochrome marks in the text colour (set 1). PS5 = PlayStation;
  otherwise Windows when the host answers ping with TTL > 64, Mac when it advertises a Mac
  model over Bonjour (`_device-info._tcp`) or its name says so, else Linux. Cached per host.
- **Right side:** a grouped Form laid out like System Settings (`.formStyle(.grouped)`,
  switches, label left / control right). The first box is the machine, headed like the
  Bluetooth pane: avatar, name, "address · status", then a Picture in Picture button and
  Stream/Resume (mid-stream: status in green, PiP or back to the window, End Stream). Under
  it the game popup (a PC with several apps) and the end-of-stream switch.
  - PC: Video - Resolution, Frame rate, Bitrate, Codec, HDR.
  - PS5: Video - Resolution, Frame rate, Bitrate, Codec, HDR (needs HEVC), Presentation;
    Controller - Vibration, Adaptive triggers, Light bar colours. The PS5 page scrolls.
  - Bitrate is one popup: Automatic (n Mbps), then the 12 snap points.
  - Snap points: 5 10 15 20 30 40 50 75 100 150 200 300 Mbps (PS5 up to 100). Help only
    as tooltips.
- **Settings per machine (approach A):** every PC and PS5 has its own complete settings.
  Existing machines start with today's values; new ones start from the defaults. Every
  stream uses its machine's settings — including Switch PC, launch-into-PiP and the PiP
  switch.
- **Stays in General:** shortcuts, controller, login item, diagnostics, and the stream
  window options (window / full screen, PiP, audio, keep awake, Game Mode, Wi-Fi).
- **Window:** Tailscale's size, 600 pt wide (528 tall on Servers), as before this change.
  A machine's page uses a narrower gutter and control width to fit beside the 190 pt
  sidebar. (Revised 2026-11-16: 780 pt read as blown up.)

## Approaches considered

- **A. Full settings per machine (chosen):** what a page shows is exactly what that machine
  uses; no hidden default layer.
- B. Shared defaults per kind + per-machine overrides: less storage, but needs a defaults
  page again and a default change silently changes several machines. Rejected.

## Non-goals / anti-goals

- (Revised 2026-11-16: Kevin asked for the round avatars and the name/address title back.
  Avatars are picked automatically - distro by name, else the detected system - never chosen.)
- No header bar on the right side; no latency graph.
- No change to pairing, the menu bar, streaming internals beyond reading per-machine settings.

## Left to the builder

Storage format and migration, how stream config reads per-host settings, OS-detection
plumbing and caching, the exact sidebar width, what the stream card shows mid-stream.
