#!/usr/bin/env python3
"""Package Quake pak files for Rojo syncing.

Splits each pak into base64 .txt chunks under assets/, which Rojo syncs as
StringValues into ReplicatedStorage.QuakeAssets.<game>.<pakname>.c###. The
runtime reassembles them into a single buffer and parses it with the ported
COM_LoadPackFile. Chunking exists only because instance string properties and
text files sync more reliably at a few MB each than one 25MB blob.

Usage: python3 tools/build_assets.py [--source PATH] [--game id1]
"""

import argparse
import base64
import pathlib
import shutil

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHUNK = 147_000  # per-chunk decoded size; base64 must stay under the 200k StringValue cap


def build(source: pathlib.Path, game: str) -> None:
    out_root = ROOT / "assets" / game
    if out_root.exists():
        shutil.rmtree(out_root)
    paks = sorted(source.glob("*.pak"))
    if not paks:
        raise SystemExit(f"no .pak files in {source}")
    for pakpath in paks:
        data = pakpath.read_bytes()
        pak_dir = out_root / pakpath.stem
        pak_dir.mkdir(parents=True)
        nchunks = (len(data) + CHUNK - 1) // CHUNK
        for i in range(nchunks):
            chunk = data[i * CHUNK : (i + 1) * CHUNK]
            (pak_dir / f"c{i:03d}.txt").write_text(base64.b64encode(chunk).decode())
        print(f"{pakpath} -> {pak_dir} ({len(data)} bytes, {nchunks} chunks)")


def build_file(path: pathlib.Path, game: str) -> None:
    """Chunk a single loose file (e.g. qwprogs.dat) under assets/<game>/<stem>/.

    Additive: only replaces that file's own chunk dir, so it can run after
    the pak build without wiping it. The runtime reassembles it with
    assetchunks.loadRaw (server) — used for engine=qw's qwprogs.dat, which
    ships outside the paks."""
    data = path.read_bytes()
    out_dir = ROOT / "assets" / game / path.stem
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True)
    nchunks = (len(data) + CHUNK - 1) // CHUNK
    for i in range(nchunks):
        chunk = data[i * CHUNK : (i + 1) * CHUNK]
        (out_dir / f"c{i:03d}.txt").write_text(base64.b64encode(chunk).decode())
    print(f"{path} -> {out_dir} ({len(data)} bytes, {nchunks} chunks)")


# per-game default pak source (mirrors tools/build_soundbank.py)
DEFAULT_SOURCES = {
    "id1": ROOT / "external_assets/quake106/extracted/id1",
    "lq1": ROOT / "external_assets/librequake/full/id1",
}

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--source",
        type=pathlib.Path,
        default=None,
        help="directory with pak0.pak, pak1.pak, ... (default: per --game)",
    )
    ap.add_argument("--game", default="id1", help="game directory name (id1 or lq1)")
    ap.add_argument(
        "--file",
        type=pathlib.Path,
        default=None,
        help="chunk one loose file (e.g. qwprogs.dat) instead of the paks",
    )
    args = ap.parse_args()
    if args.file is not None:
        build_file(args.file, args.game)
        raise SystemExit(0)
    source = args.source
    if source is None:
        source = DEFAULT_SOURCES.get(args.game)
        if source is None:
            raise SystemExit("unknown game; pass --source")
    build(source, args.game)
