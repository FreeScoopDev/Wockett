#!/usr/bin/env python3
"""Wockett App Store screenshot compositor.
Takes raw simulator captures + a caption map, produces 1320x2868 framed,
captioned App Store screenshots in the Wockett palette."""
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps
import os

W, H = 1320, 2868
CREAM_BG   = (245, 244, 242)   # earthBg light
GREEN      = (46, 120, 51)     # earthGreen light
DARK_GREEN = (26, 77, 33)
CREAM_TXT  = (242, 235, 216)   # earthCream dark-mode (cream)
MUTED      = (110, 114, 107)
FONT_BOLD  = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

SRC = "/mnt/user-data/uploads/Desktop"
SHOTS = [
    ("Simulator Screenshot - iPhone 17 Pro Max - 2026-08-31 at 09.44.39.png", "Walking routes from\nyour front door"),
    ("Simulator Screenshot - iPhone 17 Pro Max - 2026-08-31 at 09.46.52.png", "Track walks, runs & rides —\nwith your dogs"),
    ("Simulator Screenshot - iPhone 17 Pro Max - 2026-08-31 at 09.59.46.png", "Every activity counted —\ncrew included"),
    ("Simulator Screenshot - iPhone 17 Pro Max - 2026-08-31 at 10.03.06.png", "Control it all from\nthe Lock Screen"),
    ("Simulator Screenshot - iPhone 17 Pro Max - 2026-08-31 at 10.38.39.png", "Every pet gets their\nown step count"),
    ("Simulator Screenshot - iPhone 17 Pro Max - 2026-08-31 at 10.48.15.png", "Earn badges.\nBuild streaks."),
    ("Simulator Screenshot - iPhone 17 Pro Max - 2026-08-31 at 09.42.43.png", "Celebrate every\nmilestone together"),
    ("Simulator Screenshot - iPhone 17 Pro Max - 2026-08-31 at 10.49.16.png", "Find parks, cafés &\ndog parks nearby"),
    ("Simulator Screenshot - iPhone 17 Pro Max - 2026-08-31 at 10.49.29.png", "Turn any place\ninto a walk"),
]

def rounded(im, rad):
    mask = Image.new("L", im.size, 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, im.width - 1, im.height - 1], rad, fill=255)
    out = Image.new("RGBA", im.size)
    out.paste(im, (0, 0), mask)
    return out

def compose(src_path, caption, out_path):
    canvas = Image.new("RGB", (W, H), CREAM_BG)
    # subtle green wash at the bottom for depth
    wash = Image.new("L", (W, H), 0)
    dw = ImageDraw.Draw(wash)
    dw.ellipse([-500, H - 900, W + 500, H + 900], fill=26)
    canvas.paste(Image.new("RGB", (W, H), GREEN), (0, 0), wash)

    d = ImageDraw.Draw(canvas)
    # caption — auto-fit: shrink until the widest line fits inside margins
    lines = caption.split("\n")
    size = 96
    while size > 56:
        font = ImageFont.truetype(FONT_BOLD, size)
        widest = max(d.textbbox((0, 0), l, font=font)[2] for l in lines)
        if widest <= W - 180:
            break
        size -= 4
    y = 150
    for line in lines:
        bbox = d.textbbox((0, 0), line, font=font)
        d.text(((W - (bbox[2] - bbox[0])) / 2, y), line, font=font, fill=DARK_GREEN)
        y += int(size * 1.28)
    # drawn accent bar under caption
    d.rounded_rectangle([W/2 - 70, y + 18, W/2 + 70, y + 30], 6, fill=GREEN)

    # device image
    shot = Image.open(src_path).convert("RGB")
    target_w = 1000
    shot = shot.resize((target_w, int(shot.height * target_w / shot.width)), Image.LANCZOS)
    rad = 118
    framed = rounded(shot, rad)
    # bezel
    bez = 16
    bezel = Image.new("RGBA", (framed.width + 2 * bez, framed.height + 2 * bez), (0, 0, 0, 0))
    db = ImageDraw.Draw(bezel)
    db.rounded_rectangle([0, 0, bezel.width - 1, bezel.height - 1], rad + bez, fill=(28, 30, 28, 255))
    bezel.paste(framed, (bez, bez), framed)
    # shadow
    sh = Image.new("RGBA", (bezel.width + 160, bezel.height + 160), (0, 0, 0, 0))
    ds = ImageDraw.Draw(sh)
    ds.rounded_rectangle([80, 96, 80 + bezel.width, 96 + bezel.height], rad + bez, fill=(20, 40, 22, 90))
    sh = sh.filter(ImageFilter.GaussianBlur(34))
    px = (W - sh.width) // 2
    py = 470
    canvas.paste(sh, (px, py), sh)
    canvas.paste(bezel, (px + 80, py + 80), bezel)
    canvas.save(out_path, "PNG")

def privacy_slide(out_path):
    canvas = Image.new("RGB", (W, H), DARK_GREEN)
    d = ImageDraw.Draw(canvas)
    big = ImageFont.truetype(FONT_BOLD, 118)
    med = ImageFont.truetype(FONT_BOLD, 66)
    lines_big = ["No account.", "No tracking.", "Your data", "stays yours."]
    y = 660
    for line in lines_big:
        bbox = d.textbbox((0, 0), line, font=big)
        d.text(((W - (bbox[2] - bbox[0])) / 2, y), line, font=big, fill=CREAM_TXT)
        y += 190
    y += 130
    body = ["Walks live on your device", "and your own iCloud —", "never on our servers.", "", "Health data stays in Apple Health.", "Sharing is always your choice."]
    med = ImageFont.truetype(FONT_BOLD, 58)
    for line in body:
        bbox = d.textbbox((0, 0), line, font=med)
        d.text(((W - (bbox[2] - bbox[0])) / 2, y), line, font=med, fill=(178, 199, 172))
        y += 88
    # drawn shield accent
    cx, cy = W/2, 470
    d.rounded_rectangle([cx-60, cy-70, cx+60, cy+30], 28, outline=CREAM_TXT, width=10)
    d.polygon([(cx-60, cy+10), (cx, cy+90), (cx+60, cy+10)], fill=DARK_GREEN, outline=None)
    d.line([(cx-60, cy+10), (cx, cy+88), (cx+60, cy+10)], fill=CREAM_TXT, width=10)
    d.line([(cx-24, cy-16), (cx-4, cy+6), (cx+30, cy-34)], fill=CREAM_TXT, width=12, joint="curve")
    canvas.save(out_path, "PNG")

os.makedirs("out", exist_ok=True)
for i, (fname, caption) in enumerate(SHOTS, 1):
    compose(os.path.join(SRC, fname), caption, f"out/{i:02d}-wockett.png")
    print(f"{i:02d} done: {caption.splitlines()[0]}")
privacy_slide("out/10-wockett.png")
print("10 done: privacy slide")
