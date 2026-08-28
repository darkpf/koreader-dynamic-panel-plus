# Advanced Panel Zoom Plugin

Automatic panel-by-panel reading for western BD, comics, and manga in KOReader.

The plugin detects panels directly from the rendered page and displays them one
at a time in a full-screen viewer. It also provides a reliable four-view mode
for splash pages and layouts that cannot be segmented confidently.

Current version: `2.1.0`

## Difference From the Original

The original project by JorgeTheFox introduced the dynamic panel zoom
foundation. This fork keeps that idea while focusing on a Kobo Clara Colour
reading experience, especially for western BD and irregular comic layouts.

The main differences are:

- panel detection tuned against real Kobo Clara Colour render pixels
- fixes for high-DPI bitmap handling, colour dithering, and device rendering
- deterministic left-to-right and right-to-left panel ordering
- confidence validation that rejects invalid, duplicated, or unstable layouts
- automatic trimmed overview plus four detailed views when detection is not reliable
- manually selectable Basic 4 Panels Mode for complex pages
- bottom-left in-view shortcut for toggling Basic 4 Panels Mode
- screen-filling detail views with horizontal and vertical border trimming
- advanced e-ink ghosting/remanence cleanup during panel transitions
- guarded next-panel preloading that cannot be reused on the wrong page
- KOReader reading defaults applied automatically
- integrated help, activation, reading, zoom, and debug controls
- diagnostics written only to KOReader's `crash.log`

## Tested Device

The plugin has been tested and optimized for:

- Kobo Clara Colour
- Kobo G2 colour profile

When active, it applies these KOReader defaults:

- Rotation: landscape
- Page crop: none
- Page fit: full
- View mode: page
- Contrast: 2
- Dithering: on

Other KOReader devices may work, but panel tuning and refresh behavior were
built around the Kobo Clara Colour.

## Side Effects You Should Know About

The plugin changes two things outside its own feature set. Both are deliberate,
but neither is obvious from the menu.

### It writes KOReader's global defaults

The reading defaults listed above are written to KOReader's global settings the
first time a page-based document is opened with the plugin enabled, not only to
the current document. They therefore become the defaults for every document you
open afterwards, including ordinary text books.

The settings written globally are rotation mode, page crop, zoom mode genus and
type, page scroll and contrast, plus hardware or software dithering depending on
the device.

Disabling the plugin does not restore your previous values. If you want them
back, change them yourself in KOReader before or after using the plugin.

### It blocks OCR while active

While the plugin is enabled, KOReader's OCR text handler is replaced with a
no-op and the OCR menu entries are disabled. This prevents a long press from
starting OCR instead of panel viewing.

OCR is restored as soon as the plugin is deactivated from:

```text
Advanced Panel Zoom Plugin > Activate Plugin
```

## Features

- Dynamic panel detection without external panel JSON files
- Automatic fallback for uncertain or invalid layouts
- Optional Basic 4 Panels Mode for every page
- Full-screen panel-by-panel navigation
- Deterministic LTR and RTL reading order
- Configurable next-panel tap side
- Optional adjacent-page context and panel padding
- Hold-to-zoom using KOReader's native image viewer
- Guarded one-panel lookahead for faster transitions
- Full-screen e-ink cleanup to prevent ghosting and remanence
- Optional detector logs and exact analysis bitmap dumps in `crash.log`
- No diagnostic sidecar files

## Installation

Copy the plugin folder to KOReader's plugin directory:

```text
.adds/koreader/plugins/dynamic_panelzoom.koplugin
```

The folder must contain:

```text
_meta.lua
main.lua
panel_detect.lua
panel_viewer.lua
```

Restart KOReader after installing or updating the plugin.

## Basic Use

1. Open a CBZ, PDF, DjVu, or another page-based comic document.
2. Long-press a panel on the page to start panel viewing.
3. Tap the forward side to display the next panel.
4. Tap the back side to display the previous panel.
5. Tap forward after the last panel to move to the next page.
6. Tap back before the first panel to move to the previous page.
7. Tap the center of the screen to close panel viewing.
8. Long-press while viewing a panel to open free zoom, when enabled.

If taps feel reversed, adjust **Reading direction** or **Next panel tap zone**.

## Four-Panel Behavior

When only one large image is detected, or when dynamic detection is not
structurally reliable, the page is shown as:

1. one overview trimmed to the detected artwork bounds;
2. four screen-filling detailed views.

The detailed views use the detected artwork bounds on all four sides. Their
crop matches the Kobo screen aspect, removing outer white space horizontally
and vertically. Portrait pages are swept from top to bottom; wide pages are
swept horizontally in the configured reading direction.

Enable **Basic 4 Panels Mode** to force this sequence on every page and bypass
dynamic panel segmentation. This is useful when a complex layout interrupts
reading. It can also be toggled from the bottom-left icon while viewing a
panel. The option is off by default and is retained across restarts.

## KOReader Menu

The plugin replaces KOReader's panel zoom submenu with:

```text
Advanced Panel Zoom Plugin
+-- Activate Plugin
+-- Basic 4 Panels Mode
+-- How to use
+-- Advanced Options
    +-- Debug Logs
    +-- Reading direction
    +-- Next panel tap zone
    +-- Standard panel settings
    |   +-- Show adjacent page content
    |   +-- Padding around panel
    +-- Hold-to-zoom settings
    |   +-- Allow panel Zoom
    |   +-- Hold-to-Zoom padding
    |   +-- Initial zoom level
    +-- Fall back to text selection
```

## Options

### Activate Plugin

Turns dynamic panel handling on or off. It is enabled by default.

### Basic 4 Panels Mode

Bypasses dynamic segmentation and displays every page as a trimmed overview
followed by four screen-filling detailed views.

### How to use

Shows short navigation instructions and the recommended Kobo settings directly
inside the KOReader menu.

### Debug Logs

Off by default. When enabled, it turns on both:

- verbose detector diagnostics;
- base64-embedded analysis bitmap dumps.

All output goes to KOReader's `crash.log`. Bitmap dumping is intentionally
verbose and can make first-time page analysis noticeably slower.

The plugin does not create files such as:

```text
panelzoom.log
panelzoom_dump.log
*.panels.json
```

### Reading direction

Selects deterministic Left-to-Right or Right-to-Left panel order.

### Next panel tap zone

Selects Auto, Left side, or Right side as the forward navigation area.

### Standard panel settings

Controls adjacent-page context and padding around dynamically detected panels.

### Hold-to-zoom settings

Controls whether a long press opens free zoom, its padding, and its initial
zoom level.

### Fall back to text selection

KOReader compatibility option. When enabled, a failed panel-zoom gesture may
continue into normal text selection. It is normally unnecessary for
image-based comics.

## Detection and Performance

- Pages are analyzed the first time panel viewing is opened.
- Results are cached in memory for the current KOReader session.
- The next panel is rendered ahead when possible.
- Preloaded images are validated against the document, page, mode, direction,
  layout, panel index, and active viewer before use.
- Confident layouts use dynamic panels; stable large-panel layouts are kept;
  invalid or unstable layouts use the four-view fallback.
- E-ink cleanup prioritizes a ghost-free image and may produce a visible flash.

## Debugging Device Issues

Enable:

```text
Advanced Panel Zoom Plugin > Advanced Options > Debug Logs
```

Reproduce the issue, then collect KOReader's `crash.log`. Disable debug logging
for normal reading performance.

## Testing

The detector is regression-tested under LuaJIT against Kobo-like rendered
pixels, old and current fixture sets, deterministic LTR/RTL ordering, layout
confidence, and exact device bitmap captures.

The local image corpus is not included in the public repository because it
contains private or commercial comic pages. Releases should also be validated
on a physical Kobo with representative CBZ and PDF documents.

## Compatibility Notes

- Intended for page-based documents, including CBZ, PDF, and DjVu.
- Not intended for scrolling EPUB-style documents.
- Detection is deliberately conservative when layout confidence is low.
- Manual Basic 4 Panels Mode remains available for unsupported page designs.
- Refresh tuning is specific to e-ink and especially Kobo Clara Colour.

## Credits & License

This project is a fork of the original dynamic panel zoom work by JorgeTheFox.

Thanks to JorgeTheFox for the original plugin foundation and idea.

Licensed under the MIT License, matching the upstream project. Redistributed or
modified versions should retain appropriate attribution.
