# instagib (in-house gamedir mod)

Overlay on id's GPL QuakeWorld QuakeC (reference/quake-c/qw-qc — GPLv2,
see reference/quake-c/gnu.txt): only the changed files live here. The
shotgun fires a single perfectly accurate 1000-damage slug and consumes no
ammo — every hit kills through any armor.

Build (output: build/instagib/qwprogs.dat):

    tools/build_progs.sh mods/instagib build/instagib reference/quake-c/qw-qc

This mod exists to prove the in-house half of docs/MODS.md: own QC ->
tools/build_progs.sh -> gamedir. It is GPL like its base.
