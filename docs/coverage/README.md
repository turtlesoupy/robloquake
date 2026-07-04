# Coverage manifest

Function-by-function accounting of the original Quake source against this
port. Every row was produced by reading the C and the Luau side by side —
no from-memory claims. Statuses:

- **VERIFIED** — an offline test or compiled-C ground-truth harness proves
  the behavior (evidence cited per row), or a recorded screenshot
  comparison confirms it. This is the only status that counts as done.
- **PENDING** — ported and structurally equivalent on reading, but no test
  or visual proof yet.
- **UNIMPLEMENTED** — no port counterpart exists.
- **SUBSTITUTED** — intentionally replaced by a platform mechanism; the row
  states what replaces it and why the platform requires it. A substitution
  without a stated justification is a defect.

Each manifest ends with a list of port-side additions that have no C
counterpart, each with its justification.

| Manifest | Rows | Verified | Pending | Unimplemented | Substituted |
|---|---|---|---|---|---|
| [nq-server.md](nq-server.md) — WinQuake sim/server/shared | 455 | 157 | 125 | 62 | 111 |
| [nq-client.md](nq-client.md) — WinQuake client/presentation | 264 | 59 | 73 | 65 | 67 |
| [qw-server.md](qw-server.md) — QuakeWorld server | 236 | 120 | 51 | 24 | 41 |
| [qw-client.md](qw-client.md) — QuakeWorld client | 226 | 53 | 56 | 69 | 48 |
| **Total** | **1181** | **389** | **305** | **220** | **267** |

Notes on reading the numbers: 13 of the nq-server UNIMPLEMENTED rows are
dead code in the original build (QUAKE2/#if 0/PF_Fixme slots); the
SUBSTITUTED columns are dominated by the software rasterizer (d_*.c,
r_* span/edge internals, gl_*), UDP/WinSock networking, and Win32/DOS
platform files, replaced wholesale by the Roblox renderer, remotes, and
runtime.

Maintenance rule: when a PENDING row gains a test or screenshot proof,
move it to VERIFIED and cite the evidence. When new port code is written,
it enters here in the same commit.
