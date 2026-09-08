#!/usr/bin/env python3
"""Generate Example brand assets (gold X mark) from geometry — no source PNG needed.

Outputs into each app's assets/branding/:
  logo_mark.png        transparent gold X (in-app logo / hosted logoUrl)
  icon.png             gold X on dark-green gradient (legacy + iOS launcher icon)
  icon_foreground.png  transparent, padded gold X (Android adaptive-icon foreground)

Re-run after tweaking geometry/colors. Replace with official artwork anytime —
the flutter_launcher_icons config just points at these files.
"""
import math
from PIL import Image, ImageDraw

SS = 4                      # supersample for crisp anti-aliased edges
BASE = 1024
N = BASE * SS
C = N / 2

# Gold gradient (light top-left → deep gold bottom-right), matching the mark.
GOLD_LIGHT = (238, 212, 140)
GOLD_DARK = (168, 124, 44)
# Dark-green icon background (subtle vertical gradient).
GREEN_TOP = (18, 84, 58)
GREEN_BOTTOM = (8, 48, 34)
GREEN_HEX = "#0E4D35"


def _lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def _diagonal_gradient(size, c0, c1):
    """Light→dark along the top-left→bottom-right diagonal. Built small, scaled up."""
    s = 256
    g = Image.new("RGB", (s, s))
    px = g.load()
    for y in range(s):
        for x in range(s):
            px[x, y] = _lerp(c0, c1, (x + y) / (2 * (s - 1)))
    return g.resize((size, size), Image.BILINEAR)


def _vertical_gradient(size, top, bottom):
    s = 256
    g = Image.new("RGB", (s, s))
    px = g.load()
    for y in range(s):
        row = _lerp(top, bottom, y / (s - 1))
        for x in range(s):
            px[x, y] = row
    return g.resize((size, size), Image.BILINEAR)


def _arm(ang, inner, outer, halfw):
    """One X arm: a rectangle along `ang`, from `inner`..`outer` of the center."""
    dx, dy = math.cos(ang), math.sin(ang)
    px, py = -dy, dx
    p0 = (C + dx * inner, C + dy * inner)
    p1 = (C + dx * outer, C + dy * outer)
    return [
        (p0[0] + px * halfw, p0[1] + py * halfw),
        (p1[0] + px * halfw, p1[1] + py * halfw),
        (p1[0] - px * halfw, p1[1] - py * halfw),
        (p0[0] - px * halfw, p0[1] - py * halfw),
    ]


def x_mask(scale=1.0):
    """White gold-shape mask (4 arms + center diamond) on black."""
    inner, outer, halfw, dd = 138 * SS, 600 * SS, 82 * SS, 96 * SS
    inner *= scale; outer *= scale; halfw *= scale; dd *= scale
    m = Image.new("L", (N, N), 0)
    d = ImageDraw.Draw(m)
    for ang in (math.pi * 1.25, math.pi * 1.75, math.pi * 0.75, math.pi * 0.25):  # TL TR BL BR
        d.polygon(_arm(ang, inner, outer, halfw), fill=255)
    d.polygon([(C, C - dd), (C + dd, C), (C, C + dd), (C - dd, C)], fill=255)  # center diamond
    return m


def gold_x(scale=1.0):
    """Transparent RGBA gold X at full resolution, downsampled to BASE."""
    mask = x_mask(scale)
    gold = _diagonal_gradient(N, GOLD_LIGHT, GOLD_DARK).convert("RGBA")
    out = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    out.paste(gold, (0, 0), mask)
    return out.resize((BASE, BASE), Image.LANCZOS)


def build(out_dir):
    import os
    os.makedirs(out_dir, exist_ok=True)

    mark = gold_x(scale=1.0)
    mark.save(os.path.join(out_dir, "logo_mark.png"))

    # Launcher icon: green gradient bg + X scaled to leave a margin.
    bg = _vertical_gradient(BASE, GREEN_TOP, GREEN_BOTTOM).convert("RGBA")
    x_on_bg = gold_x(scale=0.80)
    bg.alpha_composite(x_on_bg)
    bg.save(os.path.join(out_dir, "icon.png"))

    # Adaptive foreground: extra padding so it survives the ~66% safe-zone crop.
    fg = Image.new("RGBA", (BASE, BASE), (0, 0, 0, 0))
    fg.alpha_composite(gold_x(scale=0.62))
    fg.save(os.path.join(out_dir, "icon_foreground.png"))
    print(f"  wrote logo_mark.png, icon.png, icon_foreground.png → {out_dir}")


if __name__ == "__main__":
    import sys
    targets = sys.argv[1:] or [
        "apps/trader/assets/branding",
        "apps/admin/assets/branding",
    ]
    print(f"Example brand assets (green bg {GREEN_HEX}):")
    for t in targets:
        build(t)
