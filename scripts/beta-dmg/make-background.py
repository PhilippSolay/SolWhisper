#!/usr/bin/env python3
"""Render the branded DMG welcome background for SolWhisper beta builds.

Emits two PNGs — a 1x (660x400) and a 2x (1320x800) — so the caller can fold
them into a HiDPI .tiff with `tiffutil -cathidpicheck`. Finder does NOT scale
DMG backgrounds, so the 1x must match the window point size exactly and the 2x
provides Retina crispness.

The layout leaves a clear zone on the right where create-dmg drops the
"Install SolWhisper" icon (Finder draws the filename label beneath it), and
puts branding + the one-time Gatekeeper note everywhere else.

Usage:
  make-background.py <logo.png> <out_1x.png> <out_2x.png> <version>
"""
import sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

WIN_W, WIN_H = 660, 400          # window content size in points

BG_TOP = (28, 28, 30)
BG_BOTTOM = (16, 16, 18)
ACCENT = (90, 160, 255)
TEXT = (240, 240, 245)
DIM = (150, 150, 158)
FAINT = (110, 110, 118)

# Where create-dmg places the installer icon (window points). Keep in sync
# with the --icon coord in make-beta-dmg.sh.
ICON_CENTER = (475, 165)
ICON_SIZE = 128


def load_font(size, bold=False):
    candidates = (
        ["/System/Library/Fonts/SFNS.ttf",
         "/System/Library/Fonts/HelveticaNeue.ttc",
         "/System/Library/Fonts/Helvetica.ttc"]
    )
    for path in candidates:
        try:
            return ImageFont.truetype(path, size)
        except Exception:
            continue
    return ImageFont.load_default()


def vertical_gradient(w, h, top, bottom):
    base = Image.new("RGB", (w, h), top)
    px = base.load()
    for y in range(h):
        t = y / max(h - 1, 1)
        px_row = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(w):
            px[x, y] = px_row
    return base


def render(logo_path, version, scale):
    W, H = WIN_W * scale, WIN_H * scale
    S = scale

    img = vertical_gradient(W, H, BG_TOP, BG_BOTTOM).convert("RGBA")

    # Accent glow behind the icon drop zone.
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    cx, cy = ICON_CENTER[0] * S, ICON_CENTER[1] * S
    rad = 150 * S
    gd.ellipse([cx - rad, cy - rad, cx + rad, cy + rad], fill=(90, 160, 255, 40))
    glow = glow.filter(ImageFilter.GaussianBlur(30 * S))
    img = Image.alpha_composite(img, glow)

    draw = ImageDraw.Draw(img)

    f_title = load_font(38 * S)
    f_sub = load_font(15 * S)
    f_tag = load_font(15 * S)
    f_step = load_font(17 * S)
    f_note_h = load_font(12 * S)
    f_note = load_font(12 * S)

    left = 52 * S

    # Logo mark.
    try:
        logo = Image.open(logo_path).convert("RGBA")
        mark = 72 * S
        logo.thumbnail((mark, mark), Image.LANCZOS)
        img.paste(logo, (left, 56 * S), logo)
        title_y = 56 * S + mark + 18 * S
    except Exception:
        title_y = 70 * S

    draw.text((left, title_y), "SolWhisper", font=f_title, fill=TEXT)
    meta_y = title_y + 50 * S
    draw.text((left, meta_y), f"Private Beta  ·  v{version}", font=f_sub, fill=ACCENT)
    draw.text((left, meta_y + 26 * S), "Local dictation & meeting transcription",
              font=f_tag, fill=DIM)

    # Callout above the icon drop zone.
    draw.text((362 * S, 86 * S), "Double-click to install", font=f_step, fill=TEXT)

    # Bottom note strip: the one-time Gatekeeper approval.
    strip_y = 320 * S
    draw.line([(left, strip_y), (W - 40 * S, strip_y)], fill=(255, 255, 255, 22),
              width=max(1, S))
    ny = strip_y + 14 * S
    draw.text((left, ny), "First launch:", font=f_note_h, fill=TEXT)
    draw.text((left, ny + 20 * S),
              "This is an unsigned beta. If macOS says it can't verify the app,",
              font=f_note, fill=FAINT)
    draw.text((left, ny + 38 * S),
              "open System Settings → Privacy & Security and click “Open Anyway”.",
              font=f_note, fill=FAINT)

    return img.convert("RGB")


def main():
    logo_path, out_1x, out_2x, version = sys.argv[1:5]
    render(logo_path, version, 1).save(out_1x, "PNG")
    render(logo_path, version, 2).save(out_2x, "PNG")
    print(f"wrote {out_1x} (660x400) and {out_2x} (1320x800)")


if __name__ == "__main__":
    main()
