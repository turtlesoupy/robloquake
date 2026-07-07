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
