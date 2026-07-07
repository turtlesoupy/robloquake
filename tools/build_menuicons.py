#!/usr/bin/env python3
"""Bake the product-menu PNG icons into a committed Luau data module.

The client renders every image as an EditableImage from raw pixels (no
rbxassetid), so menu icons follow suit: this decodes the source PNGs with
the stdlib only (zlib), box-downsamples them to a small square, and emits
src/client/menuicons.luau holding base64 RGBA that pausemenu.luau decodes at
runtime.

Source PNGs are committed under art/menuicons/; re-run this if they
change:

    python3 tools/build_menuicons.py [--src art/menuicons] [--size 128]
"""

import argparse
import base64
import os
import struct
import zlib

ICONS = ["gamemodes", "friends", "settings", "leaderboard", "ffa-gamemode", "ctf-gamemode"]


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def decode_png(data):
    """Decode an 8-bit RGBA (or RGB), non-interlaced PNG -> (w, h, rgba bytes)."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos = 8
    width = height = bit_depth = color_type = None
    idat = bytearray()
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos : pos + 4])
        ctype = data[pos + 4 : pos + 8]
        chunk = data[pos + 8 : pos + 8 + length]
        pos += 12 + length  # length + type + data + crc
        if ctype == b"IHDR":
            width, height, bit_depth, color_type, comp, filt, interlace = struct.unpack(
                ">IIBBBBB", chunk
            )
            if bit_depth != 8 or interlace != 0 or color_type not in (2, 6):
                raise ValueError(
                    f"unsupported PNG (depth={bit_depth} color={color_type} interlace={interlace})"
                )
        elif ctype == b"IDAT":
            idat += chunk
        elif ctype == b"IEND":
            break

    channels = 4 if color_type == 6 else 3
    stride = width * channels
    raw = zlib.decompress(bytes(idat))

    # unfilter scanlines into a flat RGB(A) byte array
    out = bytearray(stride * height)
    prev = bytearray(stride)
    p = 0
    for y in range(height):
        ftype = raw[p]
        p += 1
        line = bytearray(raw[p : p + stride])
        p += stride
        if ftype == 1:  # Sub
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif ftype == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:  # Average
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:  # Paeth
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                c = prev[i - channels] if i >= channels else 0
                line[i] = (line[i] + _paeth(a, prev[i], c)) & 0xFF
        elif ftype != 0:
            raise ValueError(f"bad filter type {ftype}")
        out[y * stride : (y + 1) * stride] = line
        prev = line

    # promote RGB -> RGBA
    if channels == 3:
        rgba = bytearray(width * height * 4)
        for i in range(width * height):
            rgba[i * 4 : i * 4 + 3] = out[i * 3 : i * 3 + 3]
            rgba[i * 4 + 3] = 255
        out = rgba
    return width, height, bytes(out)


def downsample(w, h, rgba, size):
    """Box-average RGBA down to size x size (premultiply so transparent
    pixels don't drag dark fringes into the average)."""
    out = bytearray(size * size * 4)
    for oy in range(size):
        y0 = oy * h // size
        y1 = max(y0 + 1, (oy + 1) * h // size)
        for ox in range(size):
            x0 = ox * w // size
            x1 = max(x0 + 1, (ox + 1) * w // size)
            r = g = b = a = n = 0
            for yy in range(y0, y1):
                base = yy * w * 4
                for xx in range(x0, x1):
                    i = base + xx * 4
                    av = rgba[i + 3]
                    r += rgba[i] * av
                    g += rgba[i + 1] * av
                    b += rgba[i + 2] * av
                    a += av
                    n += 1
            o = (oy * size + ox) * 4
            if a > 0:
                out[o] = min(255, r // a)
                out[o + 1] = min(255, g // a)
                out[o + 2] = min(255, b // a)
            out[o + 3] = a // n if n else 0
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=os.path.join(os.path.dirname(__file__), "..", "art", "menuicons"))
    ap.add_argument("--size", type=int, default=128)
    ap.add_argument(
        "--out",
        default=os.path.join(os.path.dirname(__file__), "..", "src", "client", "menuicons.luau"),
    )
    args = ap.parse_args()

    entries = []
    for name in ICONS:
        path = os.path.join(args.src, f"{name}.png")
        with open(path, "rb") as f:
            w, h, rgba = decode_png(f.read())
        small = downsample(w, h, rgba, args.size)
        b64 = base64.b64encode(small).decode("ascii")
        entries.append((name, b64))
        print(f"  {name}: {w}x{h} -> {args.size}x{args.size} ({len(b64)} b64 chars)")

    lines = [
        "--!strict",
        "-- GENERATED by tools/build_menuicons.py — do not edit by hand.",
        "-- base64 RGBA8 icon atlases (square, SIZE x SIZE); pausemenu decodes",
        "-- them to EditableImages. Source PNGs live in art/menuicons/.",
        "",
        "return {",
        f"\tsize = {args.size},",
        "\tdata = {",
    ]
    for name, b64 in entries:
        lines.append(f'\t\t["{name}"] = "{b64}",')
    # indexer cast so strict-mode consumers can iterate data generically
    lines.append("\t} :: { [string]: string },")
    lines.append("}")
    out_path = os.path.abspath(args.out)
    with open(out_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
