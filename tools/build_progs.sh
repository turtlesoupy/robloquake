#!/bin/sh
# Compile a QuakeC source tree into a vanilla progs.dat/qwprogs.dat the
# engine runs unmodified — the offline QC toolchain step for source-only
# and in-house mods (third-party mods that ship compiled progs don't need
# this; NEVER recompile or edit a third-party mod's progs).
#
# Uses gmqcc in -std=qcc (vanilla) mode; the output keeps the standard
# progdefs header CRC (NQ 5927 / QW 54730) so the engine's ABI check
# passes. fteqcc with vanilla settings works too if you prefer it.
#
# Usage: tools/build_progs.sh <qc-source-dir> <output-dir> [base-dir]
#   e.g. tools/build_progs.sh reference/quake-c/qw-qc build/inhouse
#        tools/build_progs.sh mods/instagib build/instagib reference/quake-c/qw-qc
# With [base-dir], the source dir is an OVERLAY: base files are copied
# first, then the mod's files over them — in-house mods keep only their
# changed .qc files in the repo. progs.src (from the overlay if present,
# else the base) names the output file on line 1 (e.g. ./qwprogs.dat);
# that basename lands in <output-dir>.
#
# gmqcc is built on first use into build/gmqcc (shallow clone; the
# LDFLAGS override drops --gc-sections, which macOS ld rejects).
set -e
cd "$(dirname "$0")/.."

SRC="$1"
OUT="$2"
BASE="$3"
[ -n "$SRC" ] && [ -n "$OUT" ] || { echo "usage: tools/build_progs.sh <qc-source-dir> <output-dir> [base-dir]"; exit 2; }
if [ -n "$BASE" ]; then
    [ -f "$SRC/progs.src" ] || [ -f "$BASE/progs.src" ] || { echo "no progs.src in $SRC or $BASE"; exit 2; }
else
    [ -f "$SRC/progs.src" ] || { echo "no progs.src in $SRC"; exit 2; }
fi

GMQCC=build/gmqcc/gmqcc
if ! [ -x "$GMQCC" ]; then
    echo "building gmqcc (one-time)..."
    mkdir -p build
    [ -d build/gmqcc ] || git clone --depth 1 https://github.com/graphitemaster/gmqcc.git build/gmqcc
    make -C build/gmqcc LDFLAGS="" gmqcc
fi

# compile in a scratch copy: gmqcc's progs.src auto-mode writes the output
# name from line 1 into the CURRENT directory — never run it in a source
# tree you care about
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if [ -n "$BASE" ]; then
    cp "$BASE"/*.qc "$BASE"/*.src "$TMP"/ 2>/dev/null || true
fi
cp "$SRC"/*.qc "$SRC"/*.src "$TMP"/ 2>/dev/null || true
ROOT="$(pwd)"
(cd "$TMP" && "$ROOT/$GMQCC" -std=qcc)

mkdir -p "$OUT"
DAT="$(sed -n '1s/[[:space:]]*$//;1s|^\./||p' "$TMP/progs.src")"
cp "$TMP/$DAT" "$OUT/$DAT"
echo "$OUT/$DAT"
