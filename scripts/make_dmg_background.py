#!/usr/bin/env python3
"""Generate the DMG background image for MIKE (660x430, supersampled then downscaled).

Same canvas and text layout as TOM's generator so the two projects' disk
images read as a family; the palette and the bottom band are MIKE's own —
the band echoes the app icon's toolbox belt with its two latches, the way
TOM's band echoes its crystal icon.
"""

from PIL import Image, ImageDraw, ImageFont

SCALE = 3  # supersample for crisp text and edges
CANVAS_W, CANVAS_H = 660, 430  # matches create-dmg's --window-size
# Finder's own toolbar eats roughly 65pt off the top of the window, so only
# the first ~365pt of the background is ever on screen. Everything that has
# to be seen — title, icons, band — lives above this line; the rest is
# bleed, kept so the window never shows a bare edge.
VISIBLE_H = 365
W, H = CANVAS_W * SCALE, CANVAS_H * SCALE

# The website's own blues, so the disk image and the project page match.
BG_TOP = (63, 136, 207)      # --blue-500 #3f88cf
BG_BOTTOM = (27, 93, 166)    # --blue-700 #1b5da6
BAND = (19, 74, 134)         # --blue-900 #134a86
BAND_EDGE = (109, 177, 234)  # --blue-300 #6db1ea
LATCH_FILL = (222, 232, 240)
LATCH_EDGE = (150, 168, 182)
TEXT_COLOR = (255, 255, 255)
SUB_COLOR = (225, 235, 248)

img = Image.new("RGB", (W, H), BG_TOP)
draw = ImageDraw.Draw(img)

# Vertical gradient background
for y in range(H):
    t = y / H
    draw.line(
        [(0, y), (W, y)],
        fill=(
            int(BG_TOP[0] + (BG_BOTTOM[0] - BG_TOP[0]) * t),
            int(BG_TOP[1] + (BG_BOTTOM[1] - BG_TOP[1]) * t),
            int(BG_TOP[2] + (BG_BOTTOM[2] - BG_TOP[2]) * t),
        ),
    )

# ---- Band: the toolbox belt from the icon --------------------------------
# Starts well inside the visible area and bleeds off the bottom, so it reads
# as a band rather than a stripe pinned to an edge that may be clipped.
band_top = 300 * SCALE
draw.rectangle([0, band_top, W, H], fill=BAND)
draw.line([(0, band_top), (W, band_top)], fill=BAND_EDGE, width=max(1, SCALE // 2))

# Two latches, placed like the icon's, well clear of where the icons sit
latch_w, latch_h = 26 * SCALE, 30 * SCALE
latch_y = 315 * SCALE  # inside the visible strip of the band
for cx in (W * 0.18, W * 0.82):
    x0 = cx - latch_w / 2
    draw.rounded_rectangle(
        [x0, latch_y, x0 + latch_w, latch_y + latch_h],
        radius=6 * SCALE, fill=LATCH_FILL, outline=LATCH_EDGE, width=max(1, SCALE // 2),
    )
    inner_pad = 8 * SCALE
    draw.rounded_rectangle(
        [x0 + inner_pad, latch_y + inner_pad * 0.7,
         x0 + latch_w - inner_pad, latch_y + latch_h - inner_pad * 0.7],
        radius=4 * SCALE, outline=LATCH_EDGE, width=max(1, SCALE // 2),
    )

# ---- Title ---------------------------------------------------------------
def load_font(size, bold=False):
    path = "/System/Library/Fonts/HelveticaNeue.ttc"
    idx = 1 if bold else 0
    try:
        return ImageFont.truetype(path, size, index=idx)
    except Exception:
        return ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)


def center_text(text, font, cy, fill):
    bbox = draw.textbbox((0, 0), text, font=font)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    draw.text(((W - tw) / 2 - bbox[0], cy - th / 2 - bbox[1]), text, font=font, fill=fill)


center_text("MIKE", load_font(30 * SCALE, bold=True), 58 * SCALE, TEXT_COLOR)
center_text("Mike's Toolbox", load_font(14 * SCALE), 92 * SCALE, SUB_COLOR)

line_y = 112 * SCALE
draw.line(
    [(W / 2 - 40 * SCALE, line_y), (W / 2 + 40 * SCALE, line_y)],
    fill=(220, 232, 245), width=max(1, SCALE // 2),
)

out_path = "/Users/chris/Documents/Claude Code Projects/MIKE/scripts/dmg_background.png"
img.resize((CANVAS_W, CANVAS_H), Image.LANCZOS).save(out_path)
print("saved", out_path)
