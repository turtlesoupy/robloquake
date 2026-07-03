#!/usr/bin/env python3
"""Build a single soundbank audio file + region map from Quake paks.

Roblox cannot play raw PCM, so the pak wavs are concatenated into ONE
uploadable .wav; the client slices it at runtime with Sound.PlaybackRegion.
Loop points come from the wav "cue " chunk, exactly where snd_mem.c's
GetWavinfo reads loopstart.

Outputs:
  assets/<game>/soundbank.wav   -- upload this one file to Roblox (drag into
                                   Studio's Asset Manager or Creator Hub)
  assets/<game>/soundmap.txt    -- StringValue JSON synced to Studio:
                                   { assetId, regions = { name -> {s,l,ls?} } }
                                   assetId starts empty; paste the uploaded
                                   asset id into this file (rebuilds keep it).

Usage: python3 tools/build_soundbank.py [--source PATH] [--game id1]
"""

import argparse
import json
import pathlib
import struct

ROOT = pathlib.Path(__file__).resolve().parent.parent
RATE = 22050  # bank sample rate; quake wavs are 11025 or 22050
GAP = 0.15  # silence between entries, absorbs region-boundary imprecision


def pak_entries(pakpath: pathlib.Path):
    data = pakpath.read_bytes()
    if data[:4] != b"PACK":
        raise SystemExit(f"{pakpath} is not a pak")
    diroff, dirlen = struct.unpack("<ii", data[4:12])
    for i in range(diroff, diroff + dirlen, 64):
        name = data[i : i + 56].split(b"\0")[0].decode()
        off, ln = struct.unpack("<ii", data[i + 56 : i + 64])
        yield name, data[off : off + ln]


def parse_wav(blob: bytes):
    """Minimal RIFF parse: fmt, data, and the cue loopstart GetWavinfo uses."""
    if blob[:4] != b"RIFF" or blob[8:12] != b"WAVE":
        return None
    pos = 12
    fmt = None
    pcm = None
    loopstart = -1
    while pos + 8 <= len(blob):
        cid = blob[pos : pos + 4]
        (clen,) = struct.unpack("<i", blob[pos + 4 : pos + 8])
        if clen < 0:
            break
        body = blob[pos + 8 : pos + 8 + clen]
        if cid == b"fmt ":
            tag, channels, rate = struct.unpack("<hhi", body[:8])
            bits = struct.unpack("<h", body[14:16])[0]
            fmt = (tag, channels, rate, bits)
        elif cid == b"data":
            pcm = body
        elif cid == b"cue ":
            # snd_mem.c: data_p += 32 past the chunk start, then loopstart;
            # relative to the chunk body that's offset 24 (32 - 8 header)
            if clen >= 28:
                (loopstart,) = struct.unpack("<i", body[24:28])
        pos += 8 + clen + (clen & 1)
    if not fmt or pcm is None:
        return None
    tag, channels, rate, bits = fmt
    if tag != 1 or channels != 1 or bits not in (8, 16):
        return None  # quake shipped mono pcm only
    # to 16-bit signed samples
    if bits == 8:
        samples = [(b - 128) << 8 for b in pcm]
    else:
        n = len(pcm) // 2
        samples = list(struct.unpack(f"<{n}h", pcm[: n * 2]))
    # to the bank rate
    if rate == RATE:
        pass
    elif RATE % rate == 0:
        k = RATE // rate
        samples = [s for s in samples for _ in range(k)]
        loopstart = loopstart * k if loopstart >= 0 else -1
    elif rate % RATE == 0:
        k = rate // RATE
        samples = samples[::k]
        loopstart = loopstart // k if loopstart >= 0 else -1
    else:
        return None
    return samples, loopstart


def build(source: pathlib.Path, game: str) -> None:
    out_dir = ROOT / "assets" / game
    out_dir.mkdir(parents=True, exist_ok=True)

    entries = {}
    for pakpath in sorted(source.glob("*.pak")):
        for name, blob in pak_entries(pakpath):
            if name.startswith("sound/") and name.endswith(".wav"):
                entries[name] = blob  # later paks override earlier

    bank = []
    regions = {}
    gap = [0] * int(GAP * RATE)
    skipped = []
    for name in sorted(entries):
        parsed = parse_wav(entries[name])
        if not parsed:
            skipped.append(name)
            continue
        samples, loopstart = parsed
        start = len(bank)
        bank.extend(samples)
        bank.extend(gap)
        # region names drop the sound/ prefix: the engine's precache names
        # ("weapons/guncock.wav") are relative to sound/
        key = name[len("sound/") :]
        region = {"s": round(start / RATE, 6), "l": round(len(samples) / RATE, 6)}
        if 0 <= loopstart < len(samples):
            region["ls"] = round(loopstart / RATE, 6)
        regions[key] = region

    wav_path = out_dir / "soundbank.wav"
    pcm = struct.pack(f"<{len(bank)}h", *bank)
    hdr = struct.pack(
        "<4si4s4sihhiihh4si",
        b"RIFF", 36 + len(pcm), b"WAVE", b"fmt ", 16, 1, 1,
        RATE, RATE * 2, 2, 16, b"data", len(pcm),
    )
    wav_path.write_bytes(hdr + pcm)

    map_path = out_dir / "soundmap.txt"
    old_asset = ""
    if map_path.exists():
        try:
            old_asset = json.loads(map_path.read_text()).get("assetId", "")
        except (json.JSONDecodeError, AttributeError):
            pass
    map_path.write_text(json.dumps({"assetId": old_asset, "rate": RATE, "regions": regions}))

    dur = len(bank) / RATE
    print(f"{wav_path}: {len(regions)} sounds, {dur/60:.1f} min, {len(pcm)/1e6:.1f} MB")
    if skipped:
        print(f"skipped (unsupported format): {', '.join(skipped)}")
    if dur > 420:
        print("WARNING: over Roblox's ~7 minute audio limit — split needed")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--source",
        type=pathlib.Path,
        default=None,
        help="directory containing pak0.pak, pak1.pak, ... (default: per --game)",
    )
    ap.add_argument("--game", default="id1", help="game directory name (id1 or lq1)")
    args = ap.parse_args()
    source = args.source
    if source is None:
        source = {
            "id1": ROOT / "external_assets/quake106/extracted/id1",
            "lq1": ROOT / "external_assets/librequake/full/id1",
        }.get(args.game)
        if source is None:
            raise SystemExit("unknown game; pass --source")
    build(source, args.game)
