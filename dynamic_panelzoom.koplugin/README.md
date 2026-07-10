# Advanced Panel Zoom Plugin

Automatic panel-by-panel reading for BD, comics, and manga in KOReader.

This plugin detects panels directly from the rendered page and opens them one at a time in a full-screen panel viewer. It is designed for comfortable comic reading on e-ink devices, especially colour Kobo devices.

## Tested Device

This plugin has been tested and optimized for:

- Kobo Clara Colour
- Kobo G2 colour profile

When active, the plugin applies these KOReader defaults:

- Rotation: landscape
- Page crop: none
- Page fit: full
- View mode: page
- Contrast: 2
- Dithering: on

Other KOReader devices may work, but the tuning and refresh behavior were built around the Kobo Clara Colour.

## Features

- Automatic panel detection, no external panel JSON required
- Full-screen panel-by-panel navigation
- Left-to-right and right-to-left reading direction
- Configurable next-panel tap zone
- Optional adjacent page content around panels
- Hold-to-zoom/free zoom mode
- Optional debug logs and analysis bitmap dumps into `crash.log`
- No separate debug sidecar files by default

## Installation

Copy the plugin folder to KOReader's plugin directory:

```text
.adds/koreader/plugins/dynamic_panelzoom.koplugin
```

The folder should contain at least:

```text
_meta.lua
main.lua
panel_detect.lua
panel_viewer.lua
```

Restart KOReader after copying the plugin.

## Basic Use

1. Open a comic, manga, BD, CBZ, PDF, or other page-based document.
2. Long-press a panel on the page to start panel selection.
3. Tap the forward side to show the next panel.
4. Tap the back side to show the previous panel.
5. After the last panel, tap forward to go to the next page.
6. Before the first panel, tap back to go to the previous page.
7. While viewing a selected panel, long-press to enter free zoom, if enabled.

If taps feel reversed, adjust **Reading direction** or **Next panel tap zone** in the plugin menu.

## KOReader Menu

The plugin is integrated into KOReader's panel zoom menu:

```text
Advanced Panel Zoom Plugin
```

Menu structure:

```text
Advanced Panel Zoom Plugin
+-- Activate Plugin
+-- How to use
+-- Advanced Options
    +-- Debug Logs
    +-- Reading direction
    +-- Next panel tap zone
    +-- Standard panel settings
    +-- Hold-to-zoom settings
    |   +-- Allow panel Zoom
    +-- Fall back to text selection
```

## Options

### Activate Plugin

Turns the plugin on or off. It is enabled by default.

### How to use

Shows short usage instructions directly inside the KOReader menu.

### Debug Logs

Off by default.

When enabled, this turns on both:

- verbose panel detection logs
- embedded analysis bitmap dumps

All debug output goes into KOReader's `crash.log`.

The plugin should not create separate files such as:

```text
panelzoom.log
panelzoom_dump.log
*.panels.json
```

### Reading direction

Controls panel order:

- Left-to-right
- Right-to-left

### Next panel tap zone

Controls which side of the screen advances to the next panel:

- Auto, based on reading direction
- Left side
- Right side

### Standard panel settings

Controls normal panel display behavior, including adjacent page content and padding around panels.

### Hold-to-zoom settings

Controls the optional free zoom mode entered by long-pressing while viewing a selected panel.

### Fall back to text selection

KOReader compatibility option. If enabled, failed panel zoom gestures may fall back to normal text selection.

For image-based comics, this is usually best left off.

## Testing

The local regression corpus used during tuning is not included in this public
repository because it contains private/commercial comic pages.

Before publishing a release, validate the plugin on-device with representative
CBZ/PDF pages.

## Debugging Device Issues

Enable:

```text
Advanced Panel Zoom Plugin > Advanced Options > Debug Logs
```

Then reproduce the issue on the device and collect KOReader's `crash.log`.

Debug output is intended for development and issue reports.

## Notes

- The plugin is intended for page-based documents.
- It is not tuned for scrolling EPUB-style documents.
- Some unusual page layouts may still require fallback behavior or manual reading.
- The detector favors stable panel reading over aggressive splitting.

## Credits & License

This project is a fork of the original dynamic panel zoom work by JorgeTheFox.

Thanks to JorgeTheFox for the original plugin foundation and idea.

Licensed under the MIT License, matching the upstream project. If you redistribute or modify this plugin, keep appropriate attribution.
