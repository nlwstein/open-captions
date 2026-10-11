# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow==11.3.0"]
# ///
"""Draws the placeholder app icon: a speech bubble holding three lines of caption.

    uv run Scripts/make-placeholder-icon.py

Writes App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png, 1024x1024 with no
transparency, as the App Store requires. A stand-in until there is real artwork; replace the PNG
and delete this script then.
"""
from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024
SCALE = 4  # drawn large and scaled down, for smooth edges
OUT = Path(__file__).resolve().parent.parent / "App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"


def main():
    s = SIZE * SCALE
    image = Image.new("RGB", (s, s))
    draw = ImageDraw.Draw(image)
    # Deep blue, lighter at the top.
    top, bottom = (40, 96, 214), (18, 44, 128)
    for y in range(s):
        t = y / (s - 1)
        draw.line([(0, y), (s, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))

    def box(x0, y0, x1, y1):
        return [round(v * s) for v in (x0, y0, x1, y1)]

    # The bubble, with its tail at the lower left.
    draw.rounded_rectangle(box(0.16, 0.22, 0.84, 0.70), radius=round(0.11 * s), fill="white")
    draw.polygon([(round(0.27 * s), round(0.66 * s)), (round(0.25 * s), round(0.83 * s)),
                  (round(0.43 * s), round(0.68 * s))], fill="white")
    # Three caption lines, the newest highlighted the way the app marks a speaker.
    for i, (width, colour) in enumerate([(0.50, (60, 70, 90)), (0.40, (60, 70, 90)),
                                         (0.30, (240, 170, 20))]):
        y = 0.33 + i * 0.11
        draw.rounded_rectangle(box(0.26, y, 0.26 + width, y + 0.055), radius=round(0.0275 * s),
                               fill=colour)
    image.resize((SIZE, SIZE), Image.LANCZOS).save(OUT)
    print("saved", OUT)


if __name__ == "__main__":
    main()
