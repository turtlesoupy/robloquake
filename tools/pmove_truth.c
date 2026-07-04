/* QW pmove ground truth: compiles the VERBATIM pmove.c/pmovetst.c from the
   GPL QuakeWorld source against a shim quakedef.h, loads e1m1's hulls, and
   runs a scripted movement sequence. Output is compared by
   tests/test_qw_pmove.luau.

   mkdir -p /tmp/qwsrc && cp reference/quake-c/QW/client/pmove*.c /tmp/qwsrc/
   cc -O2 -I tools/qw_shim -I /tmp/qwsrc -o /tmp/pmove_truth tools/pmove_truth.c -lm
   /tmp/pmove_truth > tests/fixtures/pmove_truth.txt
*/
#include "quakedef.h"

vec3_t vec3_origin = {0, 0, 0};

#include "pmove.c"
#include "pmovetst.c"

/* ==== BSP loading (pattern of move_truth.c) ==== */
static model_t worldmodel;
static model_t stairmodel; /* dm3 for the stair-climb course */

static byte *pak_read(const char *pakpath, const char *name, int *lenOut)
{
	FILE *f = fopen(pakpath, "rb");
	if (!f) { fprintf(stderr, "cannot open %s\n", pakpath); exit(1); }
	char id[4]; int dirofs, dirlen;
	fread(id, 1, 4, f); fread(&dirofs, 4, 1, f); fread(&dirlen, 4, 1, f);
	fseek(f, dirofs, SEEK_SET);
	for (int i = 0; i < dirlen / 64; i++) {
		char ename[56]; int filepos, filelen;
		fread(ename, 1, 56, f); fread(&filepos, 4, 1, f); fread(&filelen, 4, 1, f);
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

typedef struct { int fileofs, filelen; } lump_t;

static void load_bsp(model_t *model, const char *pak, const char *map)
{
	int len;
	byte *bspdata = pak_read(pak, map, &len);
	lump_t *lumps = (lump_t *)(bspdata + 4);

	struct dplane { float normal[3]; float dist; int type; } *dplanes =
		(void *)(bspdata + lumps[1].fileofs);
	int numplanes = lumps[1].filelen / 20;
	mplane_t *planes = calloc(numplanes, sizeof(mplane_t));
	for (int i = 0; i < numplanes; i++) {
		for (int j = 0; j < 3; j++) planes[i].normal[j] = dplanes[i].normal[j];
		planes[i].dist = dplanes[i].dist;
		planes[i].type = dplanes[i].type;
	}

	struct dnode { int planenum; short children[2]; short mins[3], maxs[3];
		unsigned short firstface, numfaces; } *dnodes = (void *)(bspdata + lumps[5].fileofs);
	int numnodes = lumps[5].filelen / 24;

	struct dleaf { int contents; int visofs; short mins[3], maxs[3];
		unsigned short firstmark, nummark; byte ambient[4]; } *dleafs =
		(void *)(bspdata + lumps[10].fileofs);

	dclipnode_t *h0 = calloc(numnodes, sizeof(dclipnode_t));
	for (int i = 0; i < numnodes; i++) {
		h0[i].planenum = dnodes[i].planenum;
		for (int j = 0; j < 2; j++) {
			short p = dnodes[i].children[j];
			h0[i].children[j] = p >= 0 ? p : dleafs[-1 - p].contents;
		}
	}

	dclipnode_t *dclip = (void *)(bspdata + lumps[9].fileofs);
	int numclip = lumps[9].filelen / 8;

	struct dmodel { float mins[3], maxs[3], origin[3]; int headnode[4];
		int visleafs, firstface, numfaces; } *dmodels = (void *)(bspdata + lumps[14].fileofs);

	model->hulls[0].clipnodes = h0;
	model->hulls[0].planes = planes;
	model->hulls[0].firstclipnode = dmodels[0].headnode[0];
	model->hulls[0].lastclipnode = numnodes - 1;

	model->hulls[1].clipnodes = dclip;
	model->hulls[1].planes = planes;
	model->hulls[1].firstclipnode = dmodels[0].headnode[1];
	model->hulls[1].lastclipnode = numclip - 1;
}

/* ==== the scripted run (mirrored in tests/test_qw_pmove.luau) ==== */
typedef struct { int untilTick; float fwd, side, upm; float yaw, pitch; int jump; } phase_t;
static phase_t script[] = {
	{40, 400, 0, 0, 90, 0, 0},     /* run north */
	{80, 400, 0, 0, 135, 0, 0},    /* veer north-west */
	{120, 200, 350, 0, 90, 0, 0},  /* strafe-run */
	{160, 400, 0, 0, 90, 0, 1},    /* bunny: run + jump held */
	{200, -200, 0, 0, 90, 0, 0},   /* backpedal */
	{240, 400, -350, 0, 45, 0, 1}, /* diagonal + jump */
	{300, 400, 0, 0, 180, 10, 0},  /* run west looking down */
};

/* stair-climb course on dm3's staircase at x=-64 (floor z 40, risers
   56/72/88/104 heading +y): up, back down, up again, jumping climb,
   diagonal climb — PM_GroundMove's step-up path under every approach.
   Mirrored in tests/test_qw_pmove.luau (ticks 301-460). */
static phase_t stairscript[] = {
	{30, 400, 0, 0, 90, 0, 0},    /* climb the stairs */
	{45, 400, 0, 0, 270, 0, 0},   /* turn, descend */
	{70, 400, 0, 0, 90, 0, 0},    /* climb again */
	{85, 400, 0, 0, 270, 0, 0},   /* back down */
	{105, 400, 0, 0, 90, 0, 1},   /* jumping climb */
	{120, 400, 0, 0, 270, 0, 0},  /* back down */
	{160, 400, 350, 0, 45, 0, 0}, /* diagonal approach into the rail/wall */
};

int main(void)
{
	load_bsp(&worldmodel, "external_assets/quake106/extracted/id1/pak0.pak", "maps/e1m1.bsp");
	load_bsp(&stairmodel, "external_assets/quake106/extracted/id1/pak1.pak", "maps/dm3.bsp");
	Pmove_Init();

	movevars.gravity = 800; movevars.stopspeed = 100; movevars.maxspeed = 320;
	movevars.spectatormaxspeed = 500; movevars.accelerate = 10;
	movevars.airaccelerate = 10; movevars.wateraccelerate = 10;
	movevars.friction = 4; movevars.waterfriction = 4; movevars.entgravity = 1;

	memset(&pmove, 0, sizeof(pmove));
	pmove.numphysent = 1;
	pmove.physents[0].model = &worldmodel;
	/* e1m1 player start */
	pmove.origin[0] = 480; pmove.origin[1] = -352; pmove.origin[2] = 88;

	for (int tick = 1; tick <= 300; tick++) {
		phase_t *ph = &script[0];
		for (int i = 0; i < (int)(sizeof(script)/sizeof(script[0])); i++)
			if (tick <= script[i].untilTick) { ph = &script[i]; break; }

		pmove.cmd.msec = 50;
		pmove.cmd.forwardmove = (short)ph->fwd;
		pmove.cmd.sidemove = (short)ph->side;
		pmove.cmd.upmove = (short)ph->upm;
		pmove.cmd.angles[0] = ph->pitch;
		pmove.cmd.angles[1] = ph->yaw;
		pmove.cmd.angles[2] = 0;
		pmove.cmd.buttons = ph->jump ? 2 : 0;

		PlayerMove();

		printf("%d %.6f %.6f %.6f %.6f %.6f %.6f %d %d\n", tick,
			pmove.origin[0], pmove.origin[1], pmove.origin[2],
			pmove.velocity[0], pmove.velocity[1], pmove.velocity[2],
			onground >= 0 ? 1 : 0, waterlevel);
	}

	/* course 2: dm3 stairs (ticks 301-460) */
	memset(&pmove, 0, sizeof(pmove));
	pmove.numphysent = 1;
	pmove.physents[0].model = &stairmodel;
	pmove.origin[0] = -64; pmove.origin[1] = 480; pmove.origin[2] = 44;

	for (int tick = 1; tick <= 160; tick++) {
		phase_t *ph = &stairscript[0];
		for (int i = 0; i < (int)(sizeof(stairscript)/sizeof(stairscript[0])); i++)
			if (tick <= stairscript[i].untilTick) { ph = &stairscript[i]; break; }

		pmove.cmd.msec = 50;
		pmove.cmd.forwardmove = (short)ph->fwd;
		pmove.cmd.sidemove = (short)ph->side;
		pmove.cmd.upmove = (short)ph->upm;
		pmove.cmd.angles[0] = ph->pitch;
		pmove.cmd.angles[1] = ph->yaw;
		pmove.cmd.angles[2] = 0;
		pmove.cmd.buttons = ph->jump ? 2 : 0;

		PlayerMove();

		printf("%d %.6f %.6f %.6f %.6f %.6f %.6f %d %d\n", 300 + tick,
			pmove.origin[0], pmove.origin[1], pmove.origin[2],
			pmove.velocity[0], pmove.velocity[1], pmove.velocity[2],
			onground >= 0 ? 1 : 0, waterlevel);
	}
	return 0;
}
