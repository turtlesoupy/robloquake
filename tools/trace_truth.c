/*
 * Ground-truth generator for hull traces. The collision functions below
 * (SV_HullPointContents, SV_RecursiveHullCheck, hull setup) are copied
 * verbatim from WinQuake world.c / model.c so their float behavior is the
 * real engine's. Loads maps/e1m1.bsp out of the shareware pak0.pak, runs a
 * deterministic set of point and line queries in hulls 0/1/2, and prints
 * results for tests/test_trace.luau to compare against.
 *
 * Build/run: cc -O2 -o /tmp/trace_truth tools/trace_truth.c && /tmp/trace_truth
 */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef float vec3_t[3];
typedef unsigned char byte;

#define CONTENTS_EMPTY -1
#define CONTENTS_SOLID -2
#define BSPVERSION 29
#define MAX_MAP_HULLS 4
#define DIST_EPSILON (0.03125)

#define DotProduct(x, y) ((x)[0] * (y)[0] + (x)[1] * (y)[1] + (x)[2] * (y)[2])
#define VectorCopy(a, b) ((b)[0] = (a)[0], (b)[1] = (a)[1], (b)[2] = (a)[2])
#define VectorSubtract(a, b, c) \
    ((c)[0] = (a)[0] - (b)[0], (c)[1] = (a)[1] - (b)[1], (c)[2] = (a)[2] - (b)[2])

typedef struct {
    float normal[3];
    float dist;
    int type;
    int signbits;
    int pad[2];
} mplane_t;

typedef struct {
    int planenum;
    short children[2];
} dclipnode_t;

typedef struct {
    dclipnode_t *clipnodes;
    mplane_t *planes;
    int firstclipnode;
    int lastclipnode;
    vec3_t clip_mins;
    vec3_t clip_maxs;
} hull_t;

typedef struct {
    int allsolid, startsolid, inopen, inwater;
    float fraction;
    vec3_t endpos;
    mplane_t plane;
} trace_t;

static hull_t hulls[4];

/* ==== verbatim from world.c ==== */

int SV_HullPointContents(hull_t *hull, int num, vec3_t p)
{
    float d;
    dclipnode_t *node;
    mplane_t *plane;

    while (num >= 0) {
        if (num < hull->firstclipnode || num > hull->lastclipnode) {
            fprintf(stderr, "SV_HullPointContents: bad node number\n");
            exit(1);
        }
        node = hull->clipnodes + num;
        plane = hull->planes + node->planenum;

        if (plane->type < 3)
            d = p[plane->type] - plane->dist;
        else
            d = DotProduct(plane->normal, p) - plane->dist;
        if (d < 0)
            num = node->children[1];
        else
            num = node->children[0];
    }
    return num;
}

int SV_RecursiveHullCheck(hull_t *hull, int num, float p1f, float p2f, vec3_t p1,
                          vec3_t p2, trace_t *trace)
{
    dclipnode_t *node;
    mplane_t *plane;
    float t1, t2;
    float frac;
    int i;
    vec3_t mid;
    int side;
    float midf;

    if (num < 0) {
        if (num != CONTENTS_SOLID) {
            trace->allsolid = 0;
            if (num == CONTENTS_EMPTY)
                trace->inopen = 1;
            else
                trace->inwater = 1;
        } else
            trace->startsolid = 1;
        return 1;
    }

    if (num < hull->firstclipnode || num > hull->lastclipnode) {
        fprintf(stderr, "SV_RecursiveHullCheck: bad node number\n");
        exit(1);
    }

    node = hull->clipnodes + num;
    plane = hull->planes + node->planenum;

    if (plane->type < 3) {
        t1 = p1[plane->type] - plane->dist;
        t2 = p2[plane->type] - plane->dist;
    } else {
        t1 = DotProduct(plane->normal, p1) - plane->dist;
        t2 = DotProduct(plane->normal, p2) - plane->dist;
    }

    if (t1 >= 0 && t2 >= 0)
        return SV_RecursiveHullCheck(hull, node->children[0], p1f, p2f, p1, p2, trace);
    if (t1 < 0 && t2 < 0)
        return SV_RecursiveHullCheck(hull, node->children[1], p1f, p2f, p1, p2, trace);

    if (t1 < 0)
        frac = (t1 + DIST_EPSILON) / (t1 - t2);
    else
        frac = (t1 - DIST_EPSILON) / (t1 - t2);
    if (frac < 0)
        frac = 0;
    if (frac > 1)
        frac = 1;

    midf = p1f + (p2f - p1f) * frac;
    for (i = 0; i < 3; i++)
        mid[i] = p1[i] + frac * (p2[i] - p1[i]);

    side = (t1 < 0);

    if (!SV_RecursiveHullCheck(hull, node->children[side], p1f, midf, p1, mid, trace))
        return 0;

    if (SV_HullPointContents(hull, node->children[side ^ 1], mid) != CONTENTS_SOLID)
        return SV_RecursiveHullCheck(hull, node->children[side ^ 1], midf, p2f, mid, p2,
                                     trace);

    if (trace->allsolid)
        return 0;

    if (!side) {
        VectorCopy(plane->normal, trace->plane.normal);
        trace->plane.dist = plane->dist;
    } else {
        vec3_t zero = {0, 0, 0};
        VectorSubtract(zero, plane->normal, trace->plane.normal);
        trace->plane.dist = -plane->dist;
    }

    while (SV_HullPointContents(hull, hull->firstclipnode, mid) == CONTENTS_SOLID) {
        frac -= 0.1;
        if (frac < 0) {
            trace->fraction = midf;
            VectorCopy(mid, trace->endpos);
            return 0;
        }
        midf = p1f + (p2f - p1f) * frac;
        for (i = 0; i < 3; i++)
            mid[i] = p1[i] + frac * (p2[i] - p1[i]);
    }

    trace->fraction = midf;
    VectorCopy(mid, trace->endpos);

    return 0;
}

/* ==== BSP loading (structure per Mod_LoadBrushModel) ==== */

static byte *bspdata;

static byte *pak_read(const char *pakpath, const char *name, int *lenOut)
{
    FILE *f = fopen(pakpath, "rb");
    if (!f) {
        fprintf(stderr, "cannot open %s\n", pakpath);
        exit(1);
    }
    char id[4];
    int dirofs, dirlen;
    fread(id, 1, 4, f);
    fread(&dirofs, 4, 1, f);
    fread(&dirlen, 4, 1, f);
    fseek(f, dirofs, SEEK_SET);
    for (int i = 0; i < dirlen / 64; i++) {
        char ename[56];
        int filepos, filelen;
        fread(ename, 1, 56, f);
        fread(&filepos, 4, 1, f);
        fread(&filelen, 4, 1, f);
        if (!strcmp(ename, name)) {
            byte *data = malloc(filelen);
            fseek(f, filepos, SEEK_SET);
            fread(data, 1, filelen, f);
            fclose(f);
            *lenOut = filelen;
            return data;
        }
    }
    fprintf(stderr, "%s not in pak\n", name);
    exit(1);
}

typedef struct {
    int fileofs, filelen;
} lump_t;

static void load_bsp(const char *pak, const char *map)
{
    int len;
    bspdata = pak_read(pak, map, &len);
    int version = *(int *)bspdata;
    if (version != BSPVERSION) {
        fprintf(stderr, "bad bsp version\n");
        exit(1);
    }
    lump_t *lumps = (lump_t *)(bspdata + 4);

    /* planes (lump 1) */
    struct dplane {
        float normal[3];
        float dist;
        int type;
    } *dplanes = (void *)(bspdata + lumps[1].fileofs);
    int numplanes = lumps[1].filelen / 20;
    mplane_t *planes = calloc(numplanes, sizeof(mplane_t));
    for (int i = 0; i < numplanes; i++) {
        int bits = 0;
        for (int j = 0; j < 3; j++) {
            planes[i].normal[j] = dplanes[i].normal[j];
            if (planes[i].normal[j] < 0)
                bits |= 1 << j;
        }
        planes[i].dist = dplanes[i].dist;
        planes[i].type = dplanes[i].type;
        planes[i].signbits = bits;
    }

    /* nodes (lump 5) -> hull 0 clipnodes (Mod_MakeHull0) */
    struct dnode {
        int planenum;
        short children[2];
        short mins[3], maxs[3];
        unsigned short firstface, numfaces;
    } *dnodes = (void *)(bspdata + lumps[5].fileofs);
    int numnodes = lumps[5].filelen / 24;

    /* leafs (lump 10) for contents lookup */
    struct dleaf {
        int contents;
        int visofs;
        short mins[3], maxs[3];
        unsigned short firstmark, nummark;
        byte ambient[4];
    } *dleafs = (void *)(bspdata + lumps[10].fileofs);

    dclipnode_t *h0 = calloc(numnodes, sizeof(dclipnode_t));
    for (int i = 0; i < numnodes; i++) {
        h0[i].planenum = dnodes[i].planenum;
        for (int j = 0; j < 2; j++) {
            short p = dnodes[i].children[j];
            if (p >= 0)
                h0[i].children[j] = p;
            else
                h0[i].children[j] = dleafs[-1 - p].contents;
        }
    }

    /* clipnodes (lump 9) */
    dclipnode_t *dclip = (void *)(bspdata + lumps[9].fileofs);
    int numclip = lumps[9].filelen / 8;

    /* models (lump 14) - use model 0 (world) headnodes */
    struct dmodel {
        float mins[3], maxs[3], origin[3];
        int headnode[4];
        int visleafs, firstface, numfaces;
    } *dmodels = (void *)(bspdata + lumps[14].fileofs);

    hulls[0].clipnodes = h0;
    hulls[0].planes = planes;
    hulls[0].firstclipnode = dmodels[0].headnode[0];
    hulls[0].lastclipnode = numnodes - 1;

    hulls[1].clipnodes = dclip;
    hulls[1].planes = planes;
    hulls[1].firstclipnode = dmodels[0].headnode[1];
    hulls[1].lastclipnode = numclip - 1;

    hulls[2].clipnodes = dclip;
    hulls[2].planes = planes;
    hulls[2].firstclipnode = dmodels[0].headnode[2];
    hulls[2].lastclipnode = numclip - 1;
}

/* deterministic PRNG shared with the Luau test */
static unsigned int seed = 12345;
static float frand(float lo, float hi)
{
    seed = seed * 1103515245 + 12345;
    unsigned int r = (seed >> 16) & 0x7fff;
    return lo + (hi - lo) * (r / 32767.0f);
}

int main(void)
{
    load_bsp("external_assets/quake106/extracted/id1/pak0.pak", "maps/e1m1.bsp");

    /* point contents grid */
    printf("POINTS\n");
    for (int i = 0; i < 200; i++) {
        vec3_t p = {frand(-608, 1520), frand(-432, 3072), frand(-608, 288)};
        for (int h = 0; h < 3; h++) {
            int c = SV_HullPointContents(&hulls[h], hulls[h].firstclipnode, p);
            printf("%d ", c);
        }
        printf("%.9g %.9g %.9g\n", p[0], p[1], p[2]);
    }

    /* line traces */
    printf("TRACES\n");
    for (int i = 0; i < 300; i++) {
        vec3_t p1 = {frand(-608, 1520), frand(-432, 3072), frand(-608, 288)};
        vec3_t p2 = {frand(-608, 1520), frand(-432, 3072), frand(-608, 288)};
        if (i < 50) {
            /* short drops from spawn-ish area, most representative of play */
            p1[0] = frand(400, 600);
            p1[1] = frand(-400, -200);
            p1[2] = frand(50, 150);
            p2[0] = p1[0];
            p2[1] = p1[1];
            p2[2] = p1[2] - 256;
        }
        for (int h = 0; h < 3; h++) {
            trace_t trace;
            memset(&trace, 0, sizeof(trace));
            trace.fraction = 1;
            trace.allsolid = 1;
            VectorCopy(p2, trace.endpos);
            SV_RecursiveHullCheck(&hulls[h], hulls[h].firstclipnode, 0, 1, p1, p2,
                                  &trace);
            printf("%d %d %d %d %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g\n",
                   trace.allsolid, trace.startsolid, trace.inopen, trace.inwater,
                   trace.fraction, trace.endpos[0], trace.endpos[1], trace.endpos[2],
                   trace.plane.normal[0], trace.plane.normal[1], trace.plane.normal[2],
                   trace.plane.dist);
        }
        printf("SEG %.9g %.9g %.9g %.9g %.9g %.9g\n", p1[0], p1[1], p1[2], p2[0], p2[1],
               p2[2]);
    }
    return 0;
}
