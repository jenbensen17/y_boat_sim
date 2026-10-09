#!/usr/bin/env python3
"""Is Gazebo's 3D view actually drawing, or is it black?

Some GPU drivers accept d3d12 rendering but produce black frames (seen on an AMD
Radeon 880M), so sim.py checks the real output: it grabs the virtual screen with xwd
and measures how much of the 3D viewport area is near-black. A normal scene (sky and
water) is almost none.

Prints the black fraction; exits 0 if the view looks rendered, 1 if black, 2 if the
screen couldn't be read.
"""
import struct
import subprocess
import sys

try:
    raw = subprocess.run(["xwd", "-root", "-silent", "-display", ":1"],
                         capture_output=True, check=True, timeout=20).stdout
except (OSError, subprocess.SubprocessError):
    print("unreadable")
    sys.exit(2)

# XWD header: 25 big-endian uint32 fields, then the window name; colormap follows.
fields = struct.unpack(">25I", raw[:100])
header_size, width, height = fields[0], fields[4], fields[5]
bytes_per_line, ncolors = fields[12], fields[19]
# The header's bits_per_pixel can say 24 while rows are stored 4 bytes per pixel,
# so go by the row stride. Pixels are little-endian: B, G, R(, X).
bpp = bytes_per_line // width if width else 0
if bpp not in (3, 4):
    print("unreadable")
    sys.exit(2)
pixels = raw[header_size + ncolors * 12:]

# The 3D viewport: Gazebo fills the screen, with its side panel on the right ~22%
# and toolbars at the top. Sample a grid inside the middle of the scene.
dark = total = 0
for y in range(int(height * 0.25), int(height * 0.9), 8):
    row = y * bytes_per_line
    for x in range(int(width * 0.05), int(width * 0.7), 8):
        i = row + bpp * x
        b, g, r = pixels[i], pixels[i + 1], pixels[i + 2]
        total += 1
        dark += (r + g + b) < 30
fraction = dark / total if total else 1.0
print(f"{fraction:.2f}")
sys.exit(1 if fraction > 0.9 else 0)
