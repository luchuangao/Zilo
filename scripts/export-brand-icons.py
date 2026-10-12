#!/usr/bin/env python3
"""Package the approved Zilo ribbon master for Apple and website icon formats."""
from pathlib import Path
import shutil
import subprocess
import tempfile

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
MASTER = ROOT / "Resources/Branding/zilo-icon-master.png"


def rounded_tile(image, size):
    tile = image.resize((size, size), Image.Resampling.LANCZOS).convert("RGBA")
    # Supersample only the platform corner mask; the approved artwork is unchanged.
    mask = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size * 4 - 1, size * 4 - 1), radius=size * 0.225 * 4, fill=255
    )
    tile.putalpha(mask.resize((size, size), Image.Resampling.LANCZOS))
    return tile


def main():
    image = Image.open(MASTER).convert("RGB")
    if image.width != image.height:
        raise ValueError("Icon master must be square")
    # iOS owns the corner mask and requires an opaque full-bleed 1024px image.
    ios = image.resize((1024, 1024), Image.Resampling.LANCZOS)
    ios.save(ROOT / "Mobile/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
    ios.save(ROOT / "Mobile/Assets.xcassets/ZiloLogo.imageset/logo.png")
    rounded_tile(image, 512).save(ROOT / "Resources/Branding/zilo-icon-web.png")
    # macOS icon canvases reserve an outer transparent margin for Dock alignment.
    mac = Image.new("RGBA", (1024, 1024))
    tile = rounded_tile(image, 824)
    mac.alpha_composite(tile, (100, 100))
    mac.save(ROOT / "Resources/Branding/zilo-icon-mac.png")
    with tempfile.TemporaryDirectory(prefix="zilo-brand-") as directory:
        iconset = Path(directory) / "Zilo.iconset"
        iconset.mkdir()
        for logical in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                suffix = "@2x" if scale == 2 else ""
                pixels = logical * scale
                mac.resize((pixels, pixels), Image.Resampling.LANCZOS).save(
                    iconset / f"icon_{logical}x{logical}{suffix}.png"
                )
        subprocess.run(
            ["iconutil", "-c", "icns", str(iconset), "-o", str(ROOT / "Resources/AppIcon-zhixing.icns")],
            check=True,
        )
    shutil.copy2(ROOT / "Resources/AppIcon-zhixing.icns", ROOT / "Resources/AppIcon.icns")
    print("Exported iOS, in-app, Mac ICNS and website icons from the approved master.")


if __name__ == "__main__":
    main()
