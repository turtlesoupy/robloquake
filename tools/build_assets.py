#!/usr/bin/env python3
"""Package Quake game/mod directories for Rojo syncing.

Splits each pak into base64 .txt chunks under assets/, which Rojo syncs as
StringValues into ServerStorage.QuakeAssets.<game>.<pakname>.c###. The
runtime reassembles them into a single buffer and parses it with the ported
COM_LoadPackFile. Chunking exists only because instance string properties and
text files sync more reliably at a few MB each than one 25MB blob.

Loose files in the source directory (a mod gamedir's progs.dat, maps/,
sound/, ... shipped outside any pak) are packed into one synthetic pak
appended after the shipped paks, so the runtime deals only in paks. Names
are lowercased and slash-normalized: DOS-era mods shipped mixed-case trees
that a case-insensitive filesystem resolved; our pak lookups are
case-sensitive like Q_strcmp, and QuakeC precaches use lowercase paths.

Usage: python3 tools/build_assets.py [--source PATH] [--game id1]
       python3 tools/build_assets.py --game <mod> --source external_assets/<mod>
"""

import argparse
import base64
import pathlib
import shutil
import struct

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHUNK = 147_000  # per-chunk decoded size; base64 must stay under the 200k StringValue cap

# loose-file extensions that are documentation/tooling/source, never
# runtime game data (mods ship readmes, batch files, and QuakeC source
# alongside their compiled progs)
DOC_EXTENSIONS = {
    ".txt", ".doc", ".htm", ".html", ".pdf", ".md",
    ".exe", ".bat", ".sh", ".com", ".dll", ".ico", ".diz", ".nfo",
    ".zip", ".rar", ".qc", ".src",
}


def write_pak(files: list[tuple[str, bytes]]) -> bytes:
    """Build a pak blob (COM_LoadPackFile layout: 'PACK' header, file data,
    then a directory of 56-byte names + i32 pos/len)."""
    header_len = 12
    blobs = []
    directory = b""
    pos = header_len
    for name, data in files:
        encoded = name.encode("ascii")
        if len(encoded) > 55:
            raise SystemExit(f"pak entry name too long (>55 chars): {name}")
        directory += struct.pack("<56sii", encoded, pos, len(data))
        blobs.append(data)
        pos += len(data)
    return (
        struct.pack("<4sii", b"PACK", pos, len(directory))
        + b"".join(blobs)
        + directory
    )


def collect_loose_files(source: pathlib.Path) -> list[tuple[str, bytes]]:
    """Game files shipped outside paks, as (pak-name, bytes), name-normalized."""
    files = []
    for path in sorted(source.rglob("*")):
        if not path.is_file():
            continue
        if path.suffix.lower() in DOC_EXTENSIONS or path.suffix.lower() == ".pak":
            continue
        if path.name.lower() == "files.dat":  # id qcc's source list, like progs.src
            continue
        if any(part.startswith(".") for part in path.relative_to(source).parts):
            continue
        name = path.relative_to(source).as_posix().lower()
        files.append((name, path.read_bytes()))
    return files


def chunk_blob(data: bytes, out_dir: pathlib.Path, label: str) -> None:
    out_dir.mkdir(parents=True)
    nchunks = (len(data) + CHUNK - 1) // CHUNK
    for i in range(nchunks):
        chunk = data[i * CHUNK : (i + 1) * CHUNK]
        (out_dir / f"c{i:03d}.txt").write_text(base64.b64encode(chunk).decode())
    print(f"{label} -> {out_dir} ({len(data)} bytes, {nchunks} chunks)")


def build(source: pathlib.Path, game: str) -> None:
    out_root = ROOT / "assets" / game
    if out_root.exists():
        shutil.rmtree(out_root)
    paks = sorted(source.glob("*.pak"))
    loose = collect_loose_files(source)
    if not paks and not loose:
        raise SystemExit(f"no .pak files or game files in {source}")
    next_index = 0
    for pakpath in paks:
        chunk_blob(pakpath.read_bytes(), out_root / pakpath.stem, str(pakpath))
        stem_index = pakpath.stem.replace("pak", "")
        if stem_index.isdigit():
            next_index = max(next_index, int(stem_index) + 1)
    if loose:
        blob = write_pak(loose)
        chunk_blob(blob, out_root / f"pak{next_index}", f"{source} ({len(loose)} loose files)")


def build_file(path: pathlib.Path, game: str) -> None:
    """Chunk a single loose file (e.g. qwprogs.dat) under assets/<game>/<stem>/.

    Additive: only replaces that file's own chunk dir, so it can run after
    the pak build without wiping it. The runtime reassembles it with
    assetchunks.loadRaw (server) — used for engine=qw's qwprogs.dat, which
    ships outside the paks."""
    out_dir = ROOT / "assets" / game / path.stem
    if out_dir.exists():
        shutil.rmtree(out_dir)
    chunk_blob(path.read_bytes(), out_dir, str(path))


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
    ap.add_argument(
        "--game",
        default="id1",
        help="game/mod directory name (id1, lq1, or a mod gamedir like threewave)",
    )
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
