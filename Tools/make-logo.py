"""make-logo.py: docs/logo.png (the owner's artwork) -> Media/Logo.tga (#97).

The icon is the eye alone: the minimap button draws it at about 20 px in a
round mask, where the lettering under it can't be read. The eye is squared on
the artwork's own background, each padded row copying the nearest background
row (the background is a vertical gradient: a flat fill would leave a seam).

Written as Buffy's Tools/ConvertLogo.ps1 writes its own: 256x256, uncompressed
32-bit BGRA, top-left origin, 8 alpha bits.

    python Tools/make-logo.py            (from the repo root; needs Pillow)
"""
import os
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "docs", "logo.png")
DST = os.path.join(ROOT, "Media", "Logo.tga")
SIZE = 256


def row_brightness(img, y):
    return max(sum(img.getpixel((x, y))) for x in range(0, img.width, 4))


def main():
    src = Image.open(SRC).convert("RGB")
    w, h = src.size
    # The background is dark (each channel under ~40); the eye and the
    # lettering glow. The eye is the first bright band, the lettering the next.
    lit = [row_brightness(src, y) > 300 for y in range(h)]
    top = lit.index(True)
    bottom = top
    while bottom + 1 < h and lit[bottom + 1]:
        bottom += 1
    gap_end = bottom + 1
    while gap_end < h and not lit[gap_end]:
        gap_end += 1
    cols = [x for x in range(w) if any(sum(src.getpixel((x, y))) > 300 for y in range(top, bottom + 1, 3))]
    left, right = cols[0], cols[-1]

    side = int((right - left + 1) * 1.04)          # a little air around the tips
    cx, cy = (left + right) // 2, (top + bottom) // 2
    x0, y0 = cx - side // 2, cy - side // 2
    # Background rows to copy from: above the eye and between it and the lettering.
    above, below = max(0, top - 20), min(h - 1, (bottom + gap_end) // 2)
    sq = Image.new("RGB", (side, side))
    for y in range(side):
        sy = y0 + y
        if sy < above:
            sy = above
        elif sy > below:
            sy = below
        row = src.crop((x0, sy, x0 + side, sy + 1))
        sq.paste(row, (0, y))
    icon = sq.resize((SIZE, SIZE), Image.LANCZOS).convert("RGBA")

    os.makedirs(os.path.dirname(DST), exist_ok=True)
    with open(DST, "wb") as f:
        f.write(bytes([0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, SIZE & 255, SIZE >> 8, SIZE & 255, SIZE >> 8, 32, 40]))
        px = icon.load()
        for y in range(SIZE):
            f.write(b"".join(bytes((px[x, y][2], px[x, y][1], px[x, y][0], px[x, y][3])) for x in range(SIZE)))
    print(f"eye rows {top}-{bottom}, columns {left}-{right}; square {side} -> {DST}")


if __name__ == "__main__":
    sys.exit(main())
