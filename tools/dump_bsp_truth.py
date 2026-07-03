#!/usr/bin/env python3
"""Independent BSP29 parse used to generate ground-truth values for
tests/test_bsp.luau. Reads e1m1.bsp out of the shareware pak0.pak with its
own struct-level parser (no shared code with the Luau port) and prints lump
counts plus spot-check values, including CalcSurfaceExtents reimplemented
from model.c.

Usage: python3 tools/dump_bsp_truth.py [maps/e1m1.bsp]
"""

import math
import struct
import sys
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
PAK0 = ROOT / "external_assets/quake106/extracted/id1/pak0.pak"


def pak_read(path: str) -> bytes:
    data = PAK0.read_bytes()
    ident, dirofs, dirlen = struct.unpack_from("<4sii", data, 0)
    assert ident == b"PACK"
    for i in range(dirlen // 64):
        name, filepos, filelen = struct.unpack_from("<56sii", data, dirofs + i * 64)
        name = name.split(b"\0")[0].decode()
        if name == path:
            return data[filepos : filepos + filelen]
    raise SystemExit(f"{path} not in pak0")


def main() -> None:
    mapname = sys.argv[1] if len(sys.argv) > 1 else "maps/e1m1.bsp"
    bsp = pak_read(mapname)
    version = struct.unpack_from("<i", bsp, 0)[0]
    assert version == 29
    lumps = [struct.unpack_from("<ii", bsp, 4 + i * 8) for i in range(15)]

    def lump(i):
        ofs, ln = lumps[i]
        return bsp[ofs : ofs + ln]

    ents, planes, tex, verts, vis, nodes, texinfo, faces, light, clip, leafs, marks, edges, surfedges, models = (
        lump(i) for i in range(15)
    )

    print(f"map {mapname}")
    print(f"planes {len(planes)//20}")
    print(f"vertexes {len(verts)//12}")
    print(f"nodes {len(nodes)//24}")
    print(f"texinfo {len(texinfo)//40}")
    print(f"faces {len(faces)//20}")
    print(f"clipnodes {len(clip)//8}")
    print(f"leafs {len(leafs)//28}")
    print(f"marksurfaces {len(marks)//2}")
    print(f"edges {len(edges)//4}")
    print(f"surfedges {len(surfedges)//4}")
    print(f"models {len(models)//64}")
    print(f"lightbytes {len(light)}")
    print(f"visbytes {len(vis)}")
    print(f"entchars {len(ents)}")

    nummiptex = struct.unpack_from("<i", tex, 0)[0]
    print(f"miptex {nummiptex}")
    # first and a middle texture
    for ti in (0, nummiptex // 2, nummiptex - 1):
        ofs = struct.unpack_from("<i", tex, 4 + 4 * ti)[0]
        if ofs == -1:
            print(f"tex{ti} MISSING")
            continue
        name, w, h = struct.unpack_from("<16sII", tex, ofs)
        name = name.split(b"\0")[0].decode()
        print(f"tex{ti} {name} {w}x{h}")

    # spot values
    n, d, t = struct.unpack_from("<3ffi", planes, 100 * 20)[0:3], *struct.unpack_from("<fi", planes, 100 * 20 + 12)
    print(f"plane100 {n[0]:.6g} {n[1]:.6g} {n[2]:.6g} {d:.6g} {t}")
    v = struct.unpack_from("<3f", verts, 500 * 12)
    print(f"vert500 {v[0]:.6g} {v[1]:.6g} {v[2]:.6g}")
    pn, c0, c1 = struct.unpack_from("<ihh", nodes, 200 * 24)
    print(f"node200 plane={pn} children={c0},{c1}")
    pn, c0, c1 = struct.unpack_from("<ihh", clip, 300 * 8)
    print(f"clipnode300 plane={pn} children={c0},{c1}")
    cont, visofs = struct.unpack_from("<ii", leafs, 100 * 28)
    print(f"leaf100 contents={cont} visofs={visofs}")

    # model 0 (world) header
    m = struct.unpack_from("<9f4i3i", models, 0)
    print(
        f"model0 mins={m[0]:.6g},{m[1]:.6g},{m[2]:.6g} maxs={m[3]:.6g},{m[4]:.6g},{m[5]:.6g} "
        f"headnode={m[9]},{m[10]},{m[11]},{m[12]} visleafs={m[13]} faces={m[14]},{m[15]}"
    )
    if len(models) > 64:
        m = struct.unpack_from("<9f4i3i", models, 64)
        print(f"model1 headnode={m[9]},{m[10]},{m[11]},{m[12]} faces={m[14]},{m[15]}")

    # CalcSurfaceExtents for spot faces, reimplemented from model.c
    def face_extents(fi):
        planenum, side, firstedge, numedges, ti = struct.unpack_from("<hhihh", faces, fi * 20)
        styles = struct.unpack_from("<4B", faces, fi * 20 + 12)
        lightofs = struct.unpack_from("<i", faces, fi * 20 + 16)[0]
        vecs = struct.unpack_from("<8f", texinfo, ti * 40)
        mins = [999999.0, 999999.0]
        maxs = [-99999.0, -99999.0]
        for i in range(numedges):
            e = struct.unpack_from("<i", surfedges, (firstedge + i) * 4)[0]
            if e >= 0:
                vi = struct.unpack_from("<HH", edges, e * 4)[0]
            else:
                vi = struct.unpack_from("<HH", edges, -e * 4)[1]
            p = struct.unpack_from("<3f", verts, vi * 12)
            for j in range(2):
                # match C float precision: accumulate in f32 like the engine
                val = p[0] * vecs[j * 4 + 0] + p[1] * vecs[j * 4 + 1] + p[2] * vecs[j * 4 + 2] + vecs[j * 4 + 3]
                mins[j] = min(mins[j], val)
                maxs[j] = max(maxs[j], val)
        tmins, exts = [], []
        for i in range(2):
            bmin = math.floor(mins[i] / 16)
            bmax = math.ceil(maxs[i] / 16)
            tmins.append(bmin * 16)
            exts.append((bmax - bmin) * 16)
        return planenum, side, numedges, ti, tmins, exts, styles, lightofs

    for fi in (0, 1000, 2000):
        planenum, side, numedges, ti, tmins, exts, styles, lightofs = face_extents(fi)
        print(
            f"face{fi} plane={planenum} side={side} edges={numedges} texinfo={ti} "
            f"tmins={tmins[0]},{tmins[1]} extents={exts[0]},{exts[1]} styles={list(styles)} lightofs={lightofs}"
        )

    # entities lump prefix
    ent_str = ents.split(b"\0")[0].decode("latin-1")
    print(f"entfirstline {ent_str.splitlines()[1]}")
    print(f"worldspawn_count {ent_str.count('worldspawn')}")


if __name__ == "__main__":
    main()
