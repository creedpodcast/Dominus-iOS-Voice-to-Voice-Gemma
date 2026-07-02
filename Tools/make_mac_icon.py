#!/usr/bin/env python3
"""
Regenerate the macOS (Mac Catalyst) app-icon tiles for Dominus.

HOW TO USE
----------
1. Change MAC_FILL below (0.0–1.0) to make the D bigger or smaller.
2. In Terminal:   python3 Tools/make_mac_icon.py
3. In Xcode: select "My Mac (Mac Catalyst)" -> Clean Build Folder (Shift-Cmd-K) -> Run.

ONLY this one number normally matters:
"""

MAC_FILL = 0.75      # <-- how much of the icon the D fills. 0.75 = 75%. Try 0.70, 0.82, etc.

import os, sys, subprocess

# Locate this script + the asset catalog (works no matter where you run it from)
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
ICONSET = os.path.join(REPO, "Dominus17ProMax/Assets.xcassets/AppIcon.appiconset")
LOGO = os.path.join(REPO, "Dominus17ProMax/Assets.xcassets/DominusLogo.imageset/DominusLogo.png")

# Make sure Pillow is available; install to a stable per-user folder if not.
LIBS = os.path.expanduser("~/.dominus-tools/pylibs")
sys.path.insert(0, LIBS)
try:
    from PIL import Image, ImageDraw
except ImportError:
    print("Installing Pillow (one-time)…")
    os.makedirs(LIBS, exist_ok=True)
    subprocess.check_call([sys.executable, "-m", "pip", "install", "--quiet",
                           "--target", LIBS, "Pillow"])
    import importlib
    importlib.invalidate_caches()   # folder was created after startup; refresh finder cache
    from PIL import Image, ImageDraw

def build():
    logo = Image.open(LOGO).convert("RGBA")
    S = 1024
    # Full-bleed OPAQUE black, no transparency. Mac Catalyst rounds the icon
    # automatically (like iOS). Transparency is what makes macOS draw a light/white
    # tile behind the icon, so we keep it fully opaque to avoid that.
    master = Image.new("RGBA", (S, S), (0, 0, 0, 255))

    # Scale the D to MAC_FILL of the icon (by its longest side) and center it.
    bbox = logo.getbbox()
    longest = max(bbox[2] - bbox[0], bbox[3] - bbox[1])
    scale = (S * MAC_FILL) / longest
    d = logo.resize((int(logo.width * scale), int(logo.height * scale)), Image.LANCZOS)
    db = d.getbbox()
    ox = int(S / 2 - (db[0] + db[2]) / 2)
    oy = int(S / 2 - (db[1] + db[3]) / 2)
    master.alpha_composite(d, (ox, oy))
    master = master.convert("RGB")   # strip alpha — fully opaque, no white tile

    sizes = {
        "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
    }
    for name, px in sizes.items():
        master.resize((px, px), Image.LANCZOS).save(os.path.join(ICONSET, name), "PNG")

    print(f"Done. D fills {int(MAC_FILL*100)}% of the tile. {len(sizes)} icon files written to:")
    print(f"  {ICONSET}")
    print("Next: Clean Build Folder (Shift-Cmd-K) and Run in Xcode (Mac Catalyst).")

if __name__ == "__main__":
    # Optional: pass the fill as an argument, e.g.  python3 Tools/make_mac_icon.py 0.85
    if len(sys.argv) > 1:
        try:
            MAC_FILL = float(sys.argv[1])
        except ValueError:
            print(f"Ignoring bad fill value '{sys.argv[1]}', using {MAC_FILL}.")
    MAC_FILL = max(0.30, min(1.0, MAC_FILL))
    build()
