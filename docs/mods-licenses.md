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
- **Ship gate:** LOCAL/DEV USE ONLY for now. Before any published place
  includes Threewave content: (a) this is a commercial context (Robux), so
  Zoid's permission is required, or the mod must be excluded; (b) the CTF
  maps/models in the client paks are third-party art — same gate.

## Rocket Arena (investigation pending)

Status: not yet staged. Verify what exists (source? compiled progs?
license?) before downloading anything; record findings here first.
