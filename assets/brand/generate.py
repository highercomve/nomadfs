#!/usr/bin/env python3
"""Generate the NomadFS brand assets: SVG masters, PNG renders, desktop icons,
system tray icons, and Android adaptive launcher icons.

    python3 assets/brand/generate.py

Needs: fontTools (wordmark outlines from Inter Display), rsvg-convert, Pillow.
Everything in this folder (and Android mipmap resources) except this script and
README.md is generated.
"""

import shutil
import subprocess
from pathlib import Path
from PIL import Image, ImageDraw

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTCollection

OUT = Path(__file__).resolve().parent
REPO_ROOT = OUT.parent.parent
ANDROID_RES = REPO_ROOT / "src" / "mobile" / "android" / "res"

# Palette: Warm Nomad Desert & Night Sky (see README.md)
NIGHT = "#12161F"       # Deep night slate (tile / banner / Android background)
NIGHT_RING = "#1E2533"  # Subtle inner border on dark tile
INK = "#181D27"         # Primary frame / text on light surfaces
SAND = "#F5EFE6"        # Warm sand cream (frame / text on dark surfaces)
TERRACOTTA = "#E8833A"  # Sahara terracotta (primary brand warm gradient bottom)
AMBER_SUN = "#F6B042"   # Desert sun amber (primary brand warm gradient top)
OASIS = "#2EC4B6"       # Oasis signal teal (roaming pulse / central core accent)
OASIS_HI = "#5CE1E6"    # Bright oasis cyan highlight


def mark(frame: str, prefix: str = "", monochrome: bool = False) -> str:
    """The NomadFS mark in a 128x128 box:
    A geometric wayfinder-mesh forming an 'N' from two vertical node pillars
    (Desktop & Mobile) and a diagonal roaming bridge (Terracotta-to-Amber),
    anchored by an Oasis Teal Merkle block core at the center (64,64) and
    subtle orbital roaming arcs connecting top-right and bottom-left.
    """
    if monochrome:
        return f"""
  <g fill="none" stroke="{frame}" stroke-linecap="round" stroke-linejoin="round">
    <path d="M 30 92 V 36 L 98 92 V 36" stroke-width="14"/>
  </g>
  <circle cx="30" cy="36" r="10" fill="{frame}"/>
  <circle cx="98" cy="92" r="10" fill="{frame}"/>
  <circle cx="30" cy="92" r="9" fill="{frame}"/>
  <circle cx="98" cy="36" r="9" fill="{frame}"/>
  <rect x="53" y="53" width="22" height="22" rx="5" transform="rotate(45 64 64)" fill="{frame}"/>"""

    return f"""
  <defs>
    <linearGradient id="{prefix}dune" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{AMBER_SUN}"/>
      <stop offset="1" stop-color="{TERRACOTTA}"/>
    </linearGradient>
    <linearGradient id="{prefix}oasis" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{OASIS_HI}"/>
      <stop offset="1" stop-color="{OASIS}"/>
    </linearGradient>
  </defs>
  <!-- Subtle orbital roaming paths -->
  <path d="M 30 36 Q 64 16 98 36" fill="none" stroke="{OASIS}" stroke-width="4.5" stroke-linecap="round" stroke-dasharray="6 8" opacity="0.85"/>
  <path d="M 30 92 Q 64 112 98 92" fill="none" stroke="{OASIS}" stroke-width="4.5" stroke-linecap="round" stroke-dasharray="6 8" opacity="0.85"/>
  <!-- Vertical device pillars (left & right) -->
  <g fill="none" stroke="{frame}" stroke-width="13" stroke-linecap="round" stroke-linejoin="round">
    <path d="M 30 92 V 36"/>
    <path d="M 98 92 V 36"/>
  </g>
  <!-- Diagonal roaming stream bridge -->
  <path d="M 30 36 L 98 92" fill="none" stroke="url(#{prefix}dune)" stroke-width="13" stroke-linecap="round"/>
  <!-- Corner device nodes -->
  <circle cx="30" cy="92" r="8.5" fill="{frame}"/>
  <circle cx="98" cy="36" r="8.5" fill="{frame}"/>
  <circle cx="30" cy="36" r="10.5" fill="url(#{prefix}dune)"/>
  <circle cx="98" cy="92" r="10.5" fill="url(#{prefix}dune)"/>
  <circle cx="30" cy="36" r="4" fill="{SAND}"/>
  <circle cx="98" cy="92" r="4" fill="{SAND}"/>
  <!-- Central Merkle DAG block / compass core -->
  <rect x="52" y="52" width="24" height="24" rx="6" transform="rotate(45 64 64)" fill="{NIGHT}" stroke="url(#{prefix}oasis)" stroke-width="5"/>
  <circle cx="64" cy="64" r="4.5" fill="{OASIS_HI}"/>"""


def tray_svg_body(color: str, accent: str) -> str:
    """Simplified high-contrast mark for 16-24px system tray icons."""
    return f"""
  <path d="M 28 96 V 32 L 100 96 V 32" fill="none" stroke="{color}" stroke-width="16" stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="28" cy="32" r="12" fill="{accent}"/>
  <circle cx="100" cy="96" r="12" fill="{accent}"/>
  <circle cx="28" cy="96" r="10" fill="{color}"/>
  <circle cx="100" cy="32" r="10" fill="{color}"/>
  <rect x="51" y="51" width="26" height="26" rx="6" transform="rotate(45 64 64)" fill="{OASIS}"/>"""


def svg(width: int, height: int, body: str, title: str = "NomadFS") -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" '
        f'width="{width}" height="{height}">\n  <title>{title}</title>{body}\n</svg>\n'
    )


def load_font(style: str = "Bold"):
    """Inter Display <style> from the system Inter collection."""
    path = subprocess.run(
        ["fc-match", "-f", "%{file}", f"Inter Display:{style.lower()}"],
        capture_output=True, text=True, check=True
    ).stdout.strip()
    for font in TTCollection(path).fonts:
        name = font["name"]
        family = name.getBestFamilyName() or ""
        sub = name.getBestSubFamilyName() or ""
        if family.startswith("Inter Display") and style in (family + " " + sub):
            return font
    raise SystemExit(f"Inter Display {style} not found in {path}")


def text_path(font, text: str, size: float, x: float, baseline: float, tracking: float = 0.0) -> str:
    """SVG path data for `text` (outlined, so no font is needed to render it)."""
    glyphs = font.getGlyphSet()
    cmap = font.getBestCmap()
    scale = size / font["head"].unitsPerEm
    pen = SVGPathPen(glyphs)
    cursor = x
    for ch in text:
        name = cmap[ord(ch)]
        glyph = glyphs[name]
        glyph.draw(TransformPen(pen, (scale, 0, 0, -scale, cursor, baseline)))
        cursor += glyph.width * scale + tracking
    return pen.getCommands()


def text_width(font, text: str, size: float, tracking: float = 0.0) -> float:
    glyphs = font.getGlyphSet()
    cmap = font.getBestCmap()
    scale = size / font["head"].unitsPerEm
    return sum(glyphs[cmap[ord(c)]].width * scale for c in text) + tracking * (len(text) - 1)


def write(name: str, content: str) -> Path:
    path = OUT / name
    path.write_text(content)
    return path


def render(svg_path: Path, png_path: Path, width: int, height: int | None = None) -> None:
    args = ["rsvg-convert", "-w", str(width)]
    if height:
        args += ["-h", str(height)]
    subprocess.run(args + [str(svg_path), "-o", str(png_path)], check=True)


def generate_android_icons(fg_svg: Path, mono_svg: Path) -> None:
    """Generate Android Adaptive Icon resources (API 26+) + legacy launcher icons."""
    ANDROID_RES.mkdir(parents=True, exist_ok=True)

    # 1. Adaptive icon XML in mipmap-anydpi-v26
    anydpi_dir = ANDROID_RES / "mipmap-anydpi-v26"
    anydpi_dir.mkdir(parents=True, exist_ok=True)
    ic_launcher_xml = """<?xml version="1.0" encoding="utf-8"?>
<!-- NomadFS adaptive icon (generated by assets/brand/generate.py). -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>
</adaptive-icon>
"""
    (anydpi_dir / "ic_launcher.xml").write_text(ic_launcher_xml)
    (anydpi_dir / "ic_launcher_round.xml").write_text(ic_launcher_xml)

    # 2. Background color value
    values_dir = ANDROID_RES / "values"
    values_dir.mkdir(parents=True, exist_ok=True)
    bg_xml = f"""<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- Deep Night Slate (assets/brand/README.md) -->
    <color name="ic_launcher_background">{NIGHT}</color>
</resources>
"""
    (values_dir / "ic_launcher_background.xml").write_text(bg_xml)

    # 3. Render foreground (108dp canvas) and legacy launcher icons (48dp canvas) across densities
    densities = [
        ("mdpi", 108, 48),
        ("hdpi", 162, 72),
        ("xhdpi", 216, 96),
        ("xxhdpi", 324, 144),
        ("xxxhdpi", 432, 192),
    ]
    icon_svg = OUT / "nomadfs-icon.svg"
    for name, adaptive_px, legacy_px in densities:
        d = ANDROID_RES / f"mipmap-{name}"
        d.mkdir(parents=True, exist_ok=True)
        render(fg_svg, d / "ic_launcher_foreground.png", adaptive_px)
        render(mono_svg, d / "ic_launcher_monochrome.png", adaptive_px)
        render(icon_svg, d / "ic_launcher.png", legacy_px)

        # Round legacy icon (circle-masked)
        full = Image.new("RGBA", (adaptive_px, adaptive_px), (18, 22, 31, 255))
        fg_img = Image.open(d / "ic_launcher_foreground.png").convert("RGBA")
        full.alpha_composite(fg_img)
        crop_margin = int(adaptive_px * 18 / 108)
        vis = full.crop((crop_margin, crop_margin, adaptive_px - crop_margin, adaptive_px - crop_margin))
        vis = vis.resize((legacy_px, legacy_px), Image.LANCZOS)
        mask = Image.new("L", (legacy_px, legacy_px), 0)
        ImageDraw.Draw(mask).ellipse((0, 0, legacy_px - 1, legacy_px - 1), fill=255)
        round_ic = Image.new("RGBA", (legacy_px, legacy_px), (0, 0, 0, 0))
        round_ic.paste(vis, (0, 0), mask)
        round_ic.save(d / "ic_launcher_round.png", optimize=True)


def main() -> None:
    bold = load_font("Bold")
    regular = load_font("Regular")

    # 1. Standalone Mark: light backgrounds, dark backgrounds, monochrome
    mark_light = write("nomadfs-mark.svg", svg(128, 128, mark(INK, "l-")))
    mark_dark = write("nomadfs-mark-dark.svg", svg(128, 128, mark(SAND, "d-")))
    mark_mono = write("nomadfs-mark-mono.svg", svg(128, 128, mark("#FFFFFF", "m-", monochrome=True)))

    # 2. Desktop / Project App Icon: mark on a rounded night tile (512x512 viewBox)
    icon = write(
        "nomadfs-icon.svg",
        svg(
            512,
            512,
            f'\n  <rect x="16" y="16" width="480" height="480" rx="108" fill="{NIGHT}"/>'
            f'\n  <rect x="20" y="20" width="472" height="472" rx="104" fill="none" stroke="{NIGHT_RING}" stroke-width="4"/>'
            f'\n  <g transform="translate(64 64) scale(3)">{mark(SAND, "i-")}\n  </g>',
        ),
    )

    # 3. Android Adaptive Foreground & Monochrome SVGs (108x108 viewBox, safe zone = center 66x66)
    # Scale 128x128 mark by 0.52 -> 66.56x66.56, centered at (108 - 66.56)/2 = 20.72
    android_fg = write(
        "nomadfs-android-foreground.svg",
        svg(
            108,
            108,
            f'\n  <g transform="translate(20.72 20.72) scale(0.52)">{mark(SAND, "af-")}\n  </g>',
            title="NomadFS Android Foreground",
        ),
    )
    android_mono = write(
        "nomadfs-android-monochrome.svg",
        svg(
            108,
            108,
            f'\n  <g transform="translate(20.72 20.72) scale(0.52)">{mark("#FFFFFF", "am-", monochrome=True)}\n  </g>',
            title="NomadFS Android Monochrome",
        ),
    )

    # 4. System Tray Icons (light and dark panel variants)
    tray_dark = write("nomadfs-tray.svg", svg(128, 128, tray_svg_body(SAND, AMBER_SUN), title="NomadFS Tray"))
    tray_light = write("nomadfs-tray-light.svg", svg(128, 128, tray_svg_body(INK, TERRACOTTA), title="NomadFS Tray Light"))

    # 5. Wordmark: mark + "nomad" (INK/SAND) + "fs" (TERRACOTTA/AMBER_SUN)
    size, tracking = 84, -2.2
    nomad_w = text_width(bold, "nomad", size, tracking)
    fs_w = text_width(bold, "fs", size, tracking)
    width = int(128 + 20 + nomad_w + 4 + fs_w + 12)
    for suffix, color, fs_color, prefix in (
        ("", INK, TERRACOTTA, "w-"),
        ("-dark", SAND, AMBER_SUN, "wd-"),
    ):
        nomad_path = text_path(bold, "nomad", size, 148, 94, tracking)
        fs_path = text_path(bold, "fs", size, 148 + nomad_w + 2, 94, tracking)
        write(
            f"nomadfs-wordmark{suffix}.svg",
            svg(
                width,
                128,
                f"{mark(color, prefix)}"
                f'\n  <path d="{nomad_path}" fill="{color}"/>'
                f'\n  <path d="{fs_path}" fill="{fs_color}"/>',
            ),
        )

    # 6. Banner for README / social preview (1280x640)
    tag = "Personal device mesh & virtual filesystem for roaming devices"
    tag_size = 30
    tag_w = text_width(regular, tag, tag_size)
    b_size, b_track = 136, -3.5
    b_nomad_w = text_width(bold, "nomad", b_size, b_track)
    b_fs_w = text_width(bold, "fs", b_size, b_track)
    title_w = b_nomad_w + 4 + b_fs_w
    group_w = 210 + 36 + title_w
    gx = (1280 - group_w) / 2
    banner = write(
        "nomadfs-banner.svg",
        svg(
            1280,
            640,
            f'\n  <defs>'
            f'\n    <radialGradient id="b-glow" cx="50%" cy="45%" r="60%">'
            f'\n      <stop offset="0%" stop-color="#1E293B"/>'
            f'\n      <stop offset="100%" stop-color="{NIGHT}"/>'
            f'\n    </radialGradient>'
            f'\n  </defs>'
            f'\n  <rect width="1280" height="640" fill="url(#b-glow)"/>'
            f'\n  <g transform="translate({gx:.1f} 165) scale(1.65)">{mark(SAND, "b-")}\n  </g>'
            f'\n  <path d="{text_path(bold, "nomad", b_size, gx + 246, 325, b_track)}" fill="{SAND}"/>'
            f'\n  <path d="{text_path(bold, "fs", b_size, gx + 246 + b_nomad_w + 3, 325, b_track)}" fill="{AMBER_SUN}"/>'
            f'\n  <path d="{text_path(regular, tag, tag_size, (1280 - tag_w) / 2, 470)}" fill="{OASIS_HI}"/>',
        ),
    )

    # 7. Render PNGs
    for px in (16, 24, 32, 48, 64, 128, 256, 512, 1024):
        render(icon, OUT / f"nomadfs-icon-{px}.png", px)

    # Multi-resolution .ico for Windows desktop builds
    ico_sizes = [16, 24, 32, 48, 64, 128, 256]
    ico_imgs = [Image.open(OUT / f"nomadfs-icon-{s}.png").convert("RGBA") for s in ico_sizes]
    ico_imgs[-1].save(
        OUT / "nomadfs.ico",
        format="ICO",
        sizes=[(s, s) for s in ico_sizes],
        append_images=ico_imgs[:-1],
    )

    # Root icon.png (1024x1024) for desktop packaging & Oriel window icon convention
    shutil.copyfile(OUT / "nomadfs-icon-1024.png", REPO_ROOT / "icon.png")

    render(mark_light, OUT / "nomadfs-mark-512.png", 512)
    render(mark_dark, OUT / "nomadfs-mark-dark-512.png", 512)
    render(tray_dark, OUT / "nomadfs-tray-64.png", 64)
    render(tray_light, OUT / "nomadfs-tray-light-64.png", 64)
    render(OUT / "nomadfs-wordmark.svg", OUT / "nomadfs-wordmark.png", width * 3)
    render(OUT / "nomadfs-wordmark-dark.svg", OUT / "nomadfs-wordmark-dark.png", width * 3)
    render(banner, OUT / "nomadfs-banner.png", 1280)

    # 8. Generate Android Adaptive Icon suite
    generate_android_icons(android_fg, android_mono)
    print(f"Generated brand assets in {OUT} and Android resources in {ANDROID_RES}")


if __name__ == "__main__":
    main()
