#!/usr/bin/env python3
"""Generate the DMG background image for MIKE (660x430, supersampled then downscaled).

Same canvas and title layout as TOM's generator so the two disk images read
as a family. The scene is a stylised New Mexico desert — mesas under a wide
pale sky — which is where both apps get their names.

Two constraints drive the composition, both found by mounting the result and
looking at it rather than from the docs:

* Finder's toolbar hides roughly the bottom 65pt of the window, so only the
  first ~365pt is ever on screen. The horizon and everything below it has to
  sit above that line; the rest of the canvas is bleed.
* The two 160pt icons sit at x=175 and x=485 and occupy x 95..255 and
  405..565 once their labels are counted. The scenery therefore lives in the
  three free columns — 0..90, 258..402, 570..660 — so nothing tall ever ends
  up behind an icon or its label.
"""

import math
import random

from PIL import Image, ImageDraw, ImageFont

SCALE = 3  # supersample for crisp text and edges
CANVAS_W, CANVAS_H = 660, 430  # matches create-dmg's --window-size
W, H = CANVAS_W * SCALE, CANVAS_H * SCALE

HORIZON = 318 * SCALE  # ground starts here, comfortably inside the visible strip

SKY_TOP = (104, 172, 232)
SKY_HORIZON = (214, 238, 250)
FAR_RANGE = (150, 150, 178)
MESA_LIT = (186, 118, 88)
MESA_SHADE = (146, 84, 64)
MESA_TOP = (204, 140, 106)
GROUND_NEAR = (206, 158, 106)
GROUND_FAR = (226, 190, 144)
SCRUB = (128, 108, 74)
CACTUS = (74, 108, 74)
TITLE_COLOR = (18, 58, 100)
SUB_COLOR = (48, 92, 134)
RULE_COLOR = (110, 150, 186)

random.seed(11)

img = Image.new("RGB", (W, H), SKY_TOP)
draw = ImageDraw.Draw(img)

# ---- Sky: deeper overhead, hazy down at the horizon ----------------------
for y in range(HORIZON):
    t = y / HORIZON
    draw.line(
        [(0, y), (W, y)],
        fill=(
            int(SKY_TOP[0] + (SKY_HORIZON[0] - SKY_TOP[0]) * t),
            int(SKY_TOP[1] + (SKY_HORIZON[1] - SKY_TOP[1]) * t),
            int(SKY_TOP[2] + (SKY_HORIZON[2] - SKY_TOP[2]) * t),
        ),
    )

# ---- Distant range, hazed into the sky ----------------------------------
far = Image.new("RGBA", (W, H), (0, 0, 0, 0))
fdraw = ImageDraw.Draw(far)
pts = [(-20 * SCALE, HORIZON)]
x = -20 * SCALE
while x < W + 20 * SCALE:
    y = HORIZON - random.uniform(10, 26) * SCALE
    pts.append((x, y))
    x += random.uniform(30, 70) * SCALE
pts += [(W + 20 * SCALE, HORIZON)]
fdraw.polygon(pts, fill=FAR_RANGE + (120,))
img = Image.alpha_composite(img.convert("RGBA"), far).convert("RGB")
draw = ImageDraw.Draw(img)

# ---- Mesas ---------------------------------------------------------------
def mesa(cx, top_w, height, base_extra=0.55):
    """A flat-topped butte: lit face, shaded face, and a caprock line."""
    top = HORIZON - height
    half_top = top_w / 2
    half_base = half_top * (1 + base_extra)
    left_base, right_base = cx - half_base, cx + half_base
    left_top, right_top = cx - half_top, cx + half_top

    draw.polygon(
        [(left_base, HORIZON), (left_top, top), (right_top, top), (right_base, HORIZON)],
        fill=MESA_LIT,
    )
    # shaded right flank — the sloped face only, so the rock keeps its form
    draw.polygon(
        [(right_top - half_top * 0.30, top), (right_top, top),
         (right_base, HORIZON), (right_base - half_base * 0.30, HORIZON)],
        fill=MESA_SHADE,
    )
    # caprock
    draw.line([(left_top, top), (right_top, top)], fill=MESA_TOP, width=max(1, int(2.5 * SCALE)))
    # a couple of erosion gullies
    for _ in range(2):
        gx = random.uniform(left_top + half_top * 0.2, right_top - half_top * 0.2)
        draw.line(
            [(gx, top + 3 * SCALE), (gx + random.uniform(-6, 6) * SCALE, HORIZON)],
            fill=MESA_SHADE, width=max(1, SCALE // 2),
        )


# The centre column (x 258..402) carries the tall group; the outer mesas run
# off the canvas edges. Widths are chosen so each base stays inside its column.
mesa(cx=330 * SCALE, top_w=52 * SCALE, height=84 * SCALE)
mesa(cx=286 * SCALE, top_w=26 * SCALE, height=52 * SCALE)
mesa(cx=377 * SCALE, top_w=30 * SCALE, height=62 * SCALE)
mesa(cx=-6 * SCALE, top_w=58 * SCALE, height=70 * SCALE)
mesa(cx=W + 8 * SCALE, top_w=62 * SCALE, height=76 * SCALE)

# ---- Desert floor --------------------------------------------------------
for y in range(HORIZON, H):
    t = (y - HORIZON) / max(1, H - HORIZON)
    draw.line(
        [(0, y), (W, y)],
        fill=(
            int(GROUND_FAR[0] + (GROUND_NEAR[0] - GROUND_FAR[0]) * t),
            int(GROUND_FAR[1] + (GROUND_NEAR[1] - GROUND_FAR[1]) * t),
            int(GROUND_FAR[2] + (GROUND_NEAR[2] - GROUND_FAR[2]) * t),
        ),
    )

# Sparse scrub, thinning towards the horizon. Drawn through an alpha layer so
# it settles into the sand instead of reading as scattered gravel.
scrub_layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
sdraw = ImageDraw.Draw(scrub_layer)
for _ in range(70):
    t = random.random() ** 0.7
    y = HORIZON + t * (H - HORIZON)
    x = random.uniform(0, W)
    r = (0.9 + 1.6 * t) * SCALE
    sdraw.ellipse([x - r, y - r * 0.55, x + r, y + r * 0.55], fill=SCRUB + (90,))
img = Image.alpha_composite(img.convert("RGBA"), scrub_layer).convert("RGB")
draw = ImageDraw.Draw(img)


def cactus(cx, base_y, height, arm=True):
    """A stylised saguaro: trunk plus one or two raised arms."""
    tw = height * 0.17
    draw.rounded_rectangle(
        [cx - tw / 2, base_y - height, cx + tw / 2, base_y],
        radius=tw / 2, fill=CACTUS,
    )
    if arm:
        aw = tw * 0.8
        ay = base_y - height * 0.58
        draw.rounded_rectangle([cx - tw * 1.6, ay, cx - tw * 0.4, ay + aw], radius=aw / 2, fill=CACTUS)
        draw.rounded_rectangle(
            [cx - tw * 1.6, ay - height * 0.24, cx - tw * 1.6 + aw, ay + aw], radius=aw / 2, fill=CACTUS
        )
        ay2 = base_y - height * 0.44
        draw.rounded_rectangle([cx + tw * 0.4, ay2, cx + tw * 1.5, ay2 + aw], radius=aw / 2, fill=CACTUS)
        draw.rounded_rectangle(
            [cx + tw * 1.5 - aw, ay2 - height * 0.2, cx + tw * 1.5, ay2 + aw], radius=aw / 2, fill=CACTUS
        )


# Kept to the outer thirds so they never crowd the icons
cactus(56 * SCALE, HORIZON + 32 * SCALE, 62 * SCALE)
cactus(608 * SCALE, HORIZON + 22 * SCALE, 48 * SCALE, arm=True)

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


# Dark on a pale sky, unlike TOM's white-on-blue — same layout, readable palette
center_text("MIKE", load_font(30 * SCALE, bold=True), 50 * SCALE, TITLE_COLOR)
center_text("Mike's Toolbox", load_font(14 * SCALE), 82 * SCALE, SUB_COLOR)

line_y = 100 * SCALE
draw.line(
    [(W / 2 - 40 * SCALE, line_y), (W / 2 + 40 * SCALE, line_y)],
    fill=RULE_COLOR, width=max(1, SCALE // 2),
)

out_path = "/Users/chris/Documents/Claude Code Projects/MIKE/scripts/dmg_background.png"
img.resize((CANVAS_W, CANVAS_H), Image.LANCZOS).save(out_path)
print("saved", out_path)
