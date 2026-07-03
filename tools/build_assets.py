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
CHUNK = 1_572_864  # 1.5MB decoded per chunk (2MB base64)


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


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--source",
        type=pathlib.Path,
        default=ROOT / "external_assets/quake106/extracted/id1",
        help="directory containing pak0.pak, pak1.pak, ...",
    )
    ap.add_argument("--game", default="id1", help="game directory name (id1 or a mod dir)")
    args = ap.parse_args()
    build(args.source, args.game)
