# Mod licenses & provenance

Every third-party mod staged under `external_assets/<mod>/` gets an entry
here BEFORE it is used, recording where each file came from and what its
license permits. Staged mod content is gitignored and must never be
committed or included in a published place until the license row here says
it may be.

## Threewave CTF 4.21 (`external_assets/threewave/`)

- **Author:** Dave "Zoid" Kirsch (zoid@threewave.com), 1996–1997; 4.21d
  repack by Casey, Sept 2000.
- **Source URLs (downloaded 2026-07-04):**
  - `https://raw.githubusercontent.com/Jason2Brownlee/ThreeWaveCTF/main/bin/3wave421d.zip`
    — server 4.21d: compiled `progs.dat` (NetQuake) + `qwprogs.dat`
    (QuakeWorld), QC source trees (`src/`, `qwsrc/` — CTF core files not
    included), `maps/*.ent` patches for stock id1 maps, `server.txt`
    docs/license, configs. sha256 `15cbe4fa…dd4ab4`.
  - `https://raw.githubusercontent.com/Jason2Brownlee/ThreeWaveCTF/main/bin/3wctfc.zip`
    — client pack 4.00-updated: `pak0.pak` (CTF 3.x assets: maps ctf1–ctf8,
    flag/star/rune models, sounds, team skins), `pak1.pak` (CTF 4.0 assets:
    ctfstart + ctf2m1–ctf2m8, custom gfx.wad/conback, rune sounds).
    sha256 `5e10cb1f…23b087`.
  - Per-file provenance also recorded in the staged `SOURCES.txt`.
- **License (verbatim, from `server.txt`, "Copyright and Distribution
  Permissions"):**
  > Authors MAY use these modifications as a basis for other publically
  > available work.
  >
  > Use this in a commercial endevour and become a friend of Satan. Talk to
  > me first, ok?
- **Reading:** free use as a basis for publicly available work is expressly
  permitted; **commercial use requires permission from Zoid** ("talk to me
  first"). The client pack's 4.00 readme carries only the disclaimer, no
  added restrictions. Note: the readme.txt *inside* pak0.pak is the stale
  3.01 beta readme with beta-only restrictions the later releases dropped.
- **Stock-map .ent patches:** distributing the `.ent` files was cleared by
  id (Jay Wilbur, quoted in server.txt); redistributing *modified bsps* was
  not. The `.ent` workflow targets **registered** Quake maps (episodes 2–4,
  dm1–dm6) — dev-only here, never shipped.
- **Ship gate: CLEARED (2026-07-07).** Zoid's permission for commercial use
  has been obtained (recorded by project owner, tdimson — archive the
  permission correspondence alongside this repo). Threewave content may now
  ship in published places; the supported publish shape is the `lq-ctf`
  preset (LibreQuake base + threewave gamedir — no id1 content involved).
  History: the gate previously read LOCAL/DEV ONLY because (a) Robux is a
  commercial context requiring Zoid's ok, and (b) the CTF maps/models in
  the client paks are third-party art. If the obtained permission does not
  cover the third-party map art in the client paks, re-verify (b) before
  shipping the ctf2m* series.

## Team Fortress 2.8/2.9 (QWTF) (`external_assets/fortress/`)

- **Authors:** TeamFortress Software — Robin Walker, John Cook, Ian
  Caughley, 1996–1998. TF Software was acquired by Valve in 1998; the
  Team Fortress IP (including this QuakeC mod) is Valve's today.
- **Source URLs (downloaded 2026-07-08, archive.org item
  `quaketf-archive` "Quake Team Fortress Archive"; sha1s match the item's
  own metadata, sha256 in staged `SOURCES-sha256.txt`):**
  - `https://archive.org/download/quaketf-archive/2-8/tf28.zip` — TF 2.8
    full zip: `FORTRESS/` gamedir with `PAK0.PAK` (models, sounds, skins,
    gfx, introseq map), compiled `progs.dat` (NetQuake) + `qwprogs.dat`
    (QuakeWorld), server configs, map-cycle configs, docs. sha1
    `06fead6261a38cdbec4ef16d509b3e05e8bfdd69`.
  - `https://archive.org/download/quaketf-archive/2-9/tf29qw.zip` — TF 2.9
    QW server upgrade (the final official release): `qwprogs.dat`
    (+ `ALTPROGS/qwprogs.dat` LAN variant, not staged), updated docs
    (`tfentref.txt`, `qwserver.txt`). sha1
    `28c46bf2010c8aec8197ee04ee05ee22b96ee08b`.
  - `https://archive.org/download/quaketf-archive/Maps/2fort5.zip` —
    2fort5.bsp by John 'Jojie' Cook & Devin 'Network' Jenson (Nov 1997),
    the canonical TF map ("designed specifically for the TeamFortress
    quakec patch"; readme has no added restrictions). sha1
    `7de30057e0c93c1443558fc9a00260b5265587ab`.
  - QC source for impulse/ABI reference only (never compiled or staged):
    `https://archive.org/download/tf_29src/tf_29src.zip`.
- **License (verbatim, `README.TXT` §"Copyright and Distribution", same
  text in 2.8 and 2.9):**
  > Authors may use this code for the basis of other freeware quakec
  > code, but not for any for-profit code, such as modification of this
  > patch for the purpose of running it on a commercial Quake Server,
  > without an agreement of some kind with TeamFortress Software.
  >
  > You may distribute this patch in any electronic format as long as this
  > textfile remains unmodified and all of the files in the archive are
  > present, and as long as no charge is made for it.
  > You may _not_ include this patch on any Quake compilation CD.
  >
  > Non-Commercial Quake Servers are free to run this patch.
- **Reading:** non-commercial servers are expressly free to run the
  unmodified patch; any commercial context needs an agreement with
  TeamFortress Software — i.e. with Valve now, which realistically means
  never. A Robux-monetized place is a commercial context.
- **Ship gate: LOCAL/DEV ONLY — permanent.** This staging exists for a
  demo video/tweet and mod-pipeline validation
  (tests/test_scenario_tf.luau), never for a published place. Valve owns
  the IP and actively uses the Team Fortress name; do not ship, do not
  upload the sounds, do not include in any assets bundle that leaves dev.

## Rocket Arena "Final Arena" 1.20 (`external_assets/rocketarena/`)

- **Author:** David "crt" Wright (wrightd@stanford.edu — address long dead;
  Wright went on to co-found GameSpy). Copyright nominally "PlanetQuake
  1997" (PlanetQuake → GameSpy → IGN → Ziff Davis: the ownership chain is
  murky).
- **Source URLs (downloaded 2026-07-05, quaddicted.com mirror of
  ftp.telefragged.com; sha256 in staged `SOURCES-sha256.txt`):**
  - `https://www.quaddicted.com/files/mirrors/ftp.telefragged.com/quake/rocketarena/fasrv12.zip`
    — server: compiled `qwprogs.dat` (QW, header CRC 54730, builtins ≤ #82
    — the stock vanilla set) + `progs.dat` (NQ, CRC 5927), QuakeC source
    zips, `raserver.txt`, rotation configs.
  - `https://www.quaddicted.com/files/mirrors/ftp.telefragged.com/quake/rocketarena/farena12.zip`
    — client: `pak0.pak` (46 arena maps + sounds), readme.
- **License (verbatim, `raserver.txt`):**
  > This patch is freely distributable provided that this readme is
  > distributed as well and is unchanged. All code is copyright
  > PlanetQuake 1997. Commercial code licensing is available by contacting
  > wrightd@stanford.edu
  Source-code terms additionally: no selling/licensing the source, no
  derivative works (except MOTD/rotation tweaks), individual routines
  reusable with credit.
- **Reading:** running the UNMODIFIED shipped progs with readmes intact is
  expressly permitted; commercial use requires a license from an
  unreachable rights-holder, and the 46 client-pak maps are by ~30
  third-party authors whose rights the readme itself admits were never
  fully cleared.
- **Ship gate:** LOCAL/DEV USE ONLY — this is a fidelity/stress target for
  the mod pipeline (tests/test_scenario_ra.luau), not shippable content.
  For a shippable arena mode, build in-house on the GPLv2 id QW QuakeC
  (reference/quake-c/qw-qc) via tools/build_progs.sh; RA routines may be
  referenced with credit per its own terms.
