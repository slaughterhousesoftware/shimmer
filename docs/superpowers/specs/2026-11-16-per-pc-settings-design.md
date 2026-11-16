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
  "+" at the bottom adds by address (the existing popover). Right-click keeps the existing
  host actions.
- **System logo, detected automatically, never picked:** Linux (Tux), Windows, Mac (Apple),
  PlayStation — plain monochrome marks in the text colour (set 1). PS5 = PlayStation;
  otherwise Windows when the host answers ping with TTL > 64, Mac when it advertises a Mac
  model over Bonjour (`_device-info._tcp`) or its name says so, else Linux. Cached per host.
- **Right side:** no title, no big icon, no latency graph. The selected machine's settings in
  the existing gutter style, starting with a **Stream** row (game popup for a PC, then a
  blue Stream/Resume button and a Picture in Picture button); "…" menu top-right.
  - PC: Stream, Resolution, Frame rate, Bitrate, When the stream ends, Codec, HDR.
  - PS5: Stream, Resolution, Frame rate (popup), Bitrate, Codec (popup HEVC / H.264),
    HDR (checkbox, needs HEVC), Presentation (popup), Haptics (popup), Controller,
    When the stream ends.
  - All choices are popups with the same width; one shared bitrate slider with 12 snap
    points / even ticks (5 10 15 20 30 40 50 75 100 150 200 300 Mbps; PS5 up to 100).
- **Settings per machine (approach A):** every PC and PS5 has its own complete settings.
  Existing machines start with today's values; new ones start from the defaults. Every
  stream uses its machine's settings — including Switch PC, launch-into-PiP and the PiP
  switch.
- **Stays in General:** shortcuts, controller, login item, diagnostics, and the stream
  window options (window / full screen, PiP, audio, keep awake, Game Mode, Wi-Fi).
- **Window:** wider (780 pt) on every tab; sidebar narrower than today's 200 pt is the
  builder's call.

## Approaches considered

- **A. Full settings per machine (chosen):** what a page shows is exactly what that machine
  uses; no hidden default layer.
- B. Shared defaults per kind + per-machine overrides: less storage, but needs a defaults
  page again and a default change silently changes several machines. Rejected.

## Non-goals / anti-goals

- No avatars, no colour tiles, no per-distro logos (Bazzite shows Linux).
- No header bar on the right side; no latency graph.
- No change to pairing, the menu bar, streaming internals beyond reading per-machine settings.

## Left to the builder

Storage format and migration, how stream config reads per-host settings, OS-detection
plumbing and caching, the exact sidebar width, what the Stream row shows mid-stream.
