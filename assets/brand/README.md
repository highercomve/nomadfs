# NomadFS Brand & Icon System

The NomadFS mark is a **Wayfinder Mesh** forming a geometric **`N`**. Two vertical pillars represent paired devices (Desktop & Mobile) linked across a Sahara Terracotta-to-Amber roaming stream, anchored at the center by a rotated **Oasis Teal Merkle DAG block** and bounded by orbital roaming arcs.

Regenerate all brand, desktop, tray, and Android launcher assets with:

```bash
python3 assets/brand/generate.py
```

Requires `fontTools`, `rsvg-convert` (`librsvg2-bin`), and `Pillow`. All files in `assets/brand/`, root `icon.png`, and `src/mobile/android/res/` (except `generate.py` and this `README.md`) are deterministically generated.

## Files

| File / Directory | Purpose |
|---|---|
| `nomadfs-mark.svg` / `nomadfs-mark-dark.svg` | Standalone symbol mark for light and dark backgrounds (`128×128`) |
| `nomadfs-mark-mono.svg` | Single-color silhouette mark for badges, embossing, and monochrome surfaces |
| `nomadfs-wordmark.svg` / `nomadfs-wordmark-dark.svg` | Full lockup: symbol mark + outlined `nomadfs` wordmark (light & dark variants) |
| `nomadfs-icon.svg`, `nomadfs-icon-{16…1024}.png` | Desktop & project application icon on a rounded Night Slate tile |
| `nomadfs.ico` | Multi-resolution Windows desktop icon (`16, 24, 32, 48, 64, 128, 256` px) |
| `/icon.png` | Root `1024×1024` application icon for Oriel window & desktop packaging |
| `nomadfs-tray.svg` / `nomadfs-tray-light.svg` | Simplified high-contrast system tray mark (`16–24` px legibility) + `64` px PNGs |
| `nomadfs-banner.svg` / `nomadfs-banner.png` | Project README header & OpenGraph social preview (`1280×640`) |
| `nomadfs-android-foreground.svg` / `monochrome.svg` | Master `108×108` dp Android adaptive icon layers (scaled to `66×66` dp safe zone) |
| `/src/mobile/android/res/mipmap-*` | Full Android Adaptive Icon suite (`mdpi` through `xxxhdpi`, `anydpi-v26` XML, round & themed monochrome) |

## Palette — Warm Nomad Desert & Night Sky

| Name | Hex | Role |
|---|---|---|
| **Night Slate** | `#12161F` | App icon tile, Android launcher background, dark surfaces |
| **Night Ring** | `#1E2533` | Subtle inner border on dark icon tiles |
| **Obsidian Ink** | `#181D27` | Primary mark pillars and wordmark on light surfaces |
| **Sand Cream** | `#F5EFE6` | Primary mark pillars and wordmark on dark surfaces |
| **Sahara Terracotta** | `#E8833A` | Primary brand warm accent, roaming stream gradient base |
| **Desert Sun Amber** | `#F6B042` | Roaming stream gradient top, `fs` accent on dark surfaces |
| **Oasis Teal** | `#2EC4B6` | Central Merkle block core & orbital roaming path |
| **Oasis Cyan Highlight** | `#5CE1E6` | Active core node pulse & tagline highlight |

## Typography

- **Wordmark:** **Inter Display Bold**, lowercase (`nomad` in primary surface contrast + `fs` in Terracotta/Amber), tracking `-2.2` at `84px`. All glyphs are converted to SVG `<path>` outlines so no font installation is required to render the SVGs.
- **Taglines & UI:** **Inter Regular**.

## Usage Guidelines

- Use `nomadfs-wordmark-dark.svg` on dark backgrounds and `nomadfs-wordmark.svg` on light backgrounds.
- For system trays or status bars at `16–24px`, use `nomadfs-tray.svg` / `nomadfs-tray-64.png`, which omits the fine dashed orbital arcs and thickens the pillars and nodes for crisp pixel alignment.
- For Android builds, `src/mobile/android/res` is wired into `src/mobile/android/library/build.gradle` and provides adaptive foreground, background (`#12161F`), and Android 13+ Material You monochrome layers.
