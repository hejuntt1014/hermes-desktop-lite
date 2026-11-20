# Hermes Desktop Lite theme packages

A `.hermes-theme` file is a ZIP with `theme.json` at the root and an optional image entry named `background`. Export a theme from **Settings → Appearance** to get a package you can edit and import.

```json
{
  "schema_version": 1,
  "id": "rose-paper",
  "name": "Rose Paper",
  "author": "Example author",
  "appearance": "light",
  "colors": {
    "canvas": "#FDF4F8",
    "surface": "#FFF8FB",
    "chrome": "#F5DEE8",
    "line": "#E7BFCE",
    "selection": "#F3DCE7",
    "message": "#F9E7F0",
    "accent": "#C45C8C",
    "primary": "#9B3864",
    "foreground": "#513441",
    "muted": "#795464",
    "link": "#9B3864",
    "positive": "#248365",
    "warning": "#95611F",
    "danger": "#9D3C32"
  },
  "fonts": { "interface": "Segoe UI", "code": "Consolas" },
  "background": { "opacity": 15 },
  "window_transparency": 0
}
```

| Field | Meaning |
| --- | --- |
| `schema_version` | Format version. The current value is `1`. |
| `id` | Stable identifier of 1–64 lowercase ASCII letters, digits, or hyphens. Start with a letter or digit. The client reserves `default`, `pink`, `paper`, and `terminal`. |
| `name`, `author` | Display name and optional author. Each supports up to 100 characters. |
| `appearance` | `light` or `dark`. Sets the base appearance for native components. |
| `colors` | Required `#RRGGBB` values. `canvas`, `surface`, and `chrome` style the main content, overlays, and window bars. `line`, `selection`, and `message` style borders, selection, and user messages. `accent`, `primary`, and `link` style focus, actions, and links. `foreground` and `muted` style text. `positive`, `warning`, and `danger` style states. Optional `sidebar`, `composer`, and `code` colors override their shared surfaces. |
| `fonts` | Optional `interface` and `code` font family names. The platform defaults apply when a family is unavailable. |
| `background` | Optional. Include the `background` image entry and set `opacity` from 0 to 100. The entry accepts the same image formats as the app's background picker, up to 16 MiB. |
| `window_transparency` | Optional, from 0 to 60. Defaults to 0. |

The manifest is limited to 64 KiB. Installation uses the manifest ID and rejects an ID already installed. Change the ID when publishing a separate variant. Local appearance settings retain overrides for each imported theme. The local wallpaper gallery stores file paths. Export resolves the selected theme's current wallpaper and slider values into a portable package.
