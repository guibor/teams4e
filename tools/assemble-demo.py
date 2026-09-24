#!/usr/bin/env python3
"""Encode only real Emacs captures into a looping GIF; no UI reconstruction."""
import json
from pathlib import Path
import sys
from PIL import Image, ImageChops, ImageStat

directory = Path(sys.argv[1])
names = ["inbox.png", "thread.png", "reply.png", "meetings.png"]
frames = [Image.open(directory / name).convert("RGB") for name in names]
sizes = {image.size for image in frames}
if len(sizes) != 1:
    raise SystemExit(f"Frame sizes differ: {sizes}")
for name, image in zip(names, frames):
    if max(ImageStat.Stat(image).stddev) < 10:
        raise SystemExit(f"Blank or near-blank capture: {name}")
for previous, following in zip(frames, frames[1:]):
    if ImageChops.difference(previous, following).getbbox() is None:
        raise SystemExit("UI state did not change between captures")
frames[0].save(directory / "demo.gif", save_all=True, append_images=frames[1:],
               duration=[2500, 4000, 4500, 3500], loop=0, optimize=False)
print(json.dumps({"frames": names, "size": list(frames[0].size),
                  "gif_bytes": (directory / "demo.gif").stat().st_size}))
