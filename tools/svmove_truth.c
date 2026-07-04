/* NQ sv_move.c ground truth: the monster chase family transcribed
   VERBATIM from WinQuake sv_move.c + PF_changeyaw (pr_cmds.c), run
   against e1m1's real hulls with a world-only SV_Move (no other solid
   entities) and the SAME msvcrt LCG the port uses (seed settable), so
   the rand()-gated SV_NewChaseDir decisions are bit-comparable.

   Scenario: a grunt-sized walker at (480,100,24) chases a goal at
   (480,480,24) across the open e1m1 lower hall; 200 SV_MoveToGoal
   calls at dist 8. Output per call: origin, yaw, ideal_yaw.
   Compared by tests/test_svmove.luau, which mirrors the setup on the
   port with every other solid entity unlinked and svr.randSeed reset.

   cc -O2 -o /tmp/svmove_truth tools/svmove_truth.c -lm
   /tmp/svmove_truth > tests/fixtures/svmove_truth.txt
*/
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef float vec3_t[3];
typedef int qboolean;
#define true 1
#define false 0
#define VectorCopy(a, b) ((b)[0] = (a)[0], (b)[1] = (a)[1], (b)[2] = (a)[2])
#define VectorAdd(a, b, c) ((c)[0] = (a)[0] + (b)[0], (c)[1] = (a)[1] + (b)[1], (c)[2] = (a)[2] + (b)[2])
#define VectorSubtract(a, b, c) ((c)[0] = (a)[0] - (b)[0], (c)[1] = (a)[1] - (b)[1], (c)[2] = (a)[2] - (b)[2])
#define DotProduct(a, b) ((a)[0] * (b)[0] + (a)[1] * (b)[1] + (a)[2] * (b)[2])
#define CONTENTS_EMPTY -1
#define CONTENTS_SOLID -2
#define FL_FLY 1
#define FL_SWIM 2
#define FL_ONGROUND 512
#define FL_PARTIALGROUND 1024
#define STEPSIZE 18
#define DIST_EPSILON 0.03125
#define M_PI 3.14159265358979323846
#define YAW 1

/* ==== the port's msvcrt LCG (sv.rand) ==== */
static unsigned int lcg_seed = 12345;
static int q_rand(void)
{
	lcg_seed = lcg_seed * 214013u + 2531011u;
	return (lcg_seed >> 16) & 0x7fff;
}
#define rand q_rand

/* ==== entity ==== */
typedef struct edict_s {
	struct {
		vec3_t origin, mins, maxs, absmin, absmax, angles;
		float ideal_yaw, yaw_speed, flags;
		struct edict_s *enemy, *goalentity;
	} v;
} edict_t;

static edict_t world_ed; /* stands in for sv.edicts */

static void link_ed(edict_t *e)
{
	VectorAdd(e->v.origin, e->v.mins, e->v.absmin);
	VectorAdd(e->v.origin, e->v.maxs, e->v.absmax);
	/* world.c: non-item abs boxes expand by 1 */
	e->v.absmin[0] -= 1; e->v.absmin[1] -= 1; e->v.absmin[2] -= 1;
	e->v.absmax[0] += 1; e->v.absmax[1] += 1; e->v.absmax[2] += 1;
}
#define SV_LinkEdict(e, t) link_ed(e)

/* ==== hulls (pattern of pmove_truth.c) ==== */
typedef unsigned char byte;
typedef struct { float normal[3]; float dist; int type; } mplane_t;
typedef struct { int planenum; short children[2]; } dclipnode_t;
typedef struct {
	dclipnode_t *clipnodes;
	mplane_t *planes;
	int firstclipnode, lastclipnode;
	vec3_t clip_mins, clip_maxs;
} hull_t;
typedef struct {
	qboolean allsolid, startsolid, inopen, inwater;
	float fraction;
	vec3_t endpos;
	struct { vec3_t normal; float dist; } plane;
	edict_t *ent;
} trace_t;

static hull_t hulls[3];

static byte *pak_read(const char *pakpath, const char *name, int *lenOut)
{
	FILE *f = fopen(pakpath, "rb");
	if (!f) { fprintf(stderr, "cannot open %s\n", pakpath); exit(1); }
	char id[4]; int dirofs, dirlen;
	fread(id, 1, 4, f); fread(&dirofs, 4, 1, f); fread(&dirlen, 4, 1, f);
	fseek(f, dirofs, 0);
	for (int i = 0; i < dirlen / 64; i++) {
		char ename[56]; int filepos, filelen;
		fread(ename, 1, 56, f); fread(&filepos, 4, 1, f); fread(&filelen, 4, 1, f);
		if (!strcmp(ename, name)) {
			byte *data = malloc(filelen);
			fseek(f, filepos, 0);
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

static void load_bsp(const char *pak, const char *map)
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

	hulls[0].clipnodes = h0;
	hulls[0].planes = planes;
	hulls[0].firstclipnode = dmodels[0].headnode[0];
	hulls[0].lastclipnode = numnodes - 1;
	/* hull 1: -16..16 box hull, clip_mins/maxs per world.c */
	hulls[1].clipnodes = dclip;
	hulls[1].planes = planes;
	hulls[1].firstclipnode = dmodels[0].headnode[1];
	hulls[1].lastclipnode = numclip - 1;
	hulls[1].clip_mins[0] = -16; hulls[1].clip_mins[1] = -16; hulls[1].clip_mins[2] = -24;
	hulls[1].clip_maxs[0] = 16; hulls[1].clip_maxs[1] = 16; hulls[1].clip_maxs[2] = 32;
}

/* ==== hull tracing, verbatim world.c ==== */
static int SV_HullPointContents(hull_t *hull, int num, vec3_t p)
{
	float d;
	dclipnode_t *node;
	mplane_t *plane;
	while (num >= 0) {
		node = hull->clipnodes + num;
		plane = hull->planes + node->planenum;
		if (plane->type < 3)
			d = p[plane->type] - plane->dist;
		else
			d = DotProduct(plane->normal, p) - plane->dist;
		num = d < 0 ? node->children[1] : node->children[0];
	}
	return num;
}

static int SV_PointContents(vec3_t p)
{
	return SV_HullPointContents(&hulls[0], hulls[0].firstclipnode, p);
}

static qboolean SV_RecursiveHullCheck(hull_t *hull, int num, float p1f, float p2f,
	vec3_t p1, vec3_t p2, trace_t *trace)
{
	dclipnode_t *node;
	mplane_t *plane;
	float t1, t2, frac, midf;
	vec3_t mid;
	int i, side;

	if (num < 0) {
		if (num != CONTENTS_SOLID) {
			trace->allsolid = false;
			if (num == CONTENTS_EMPTY)
				trace->inopen = true;
			else
				trace->inwater = true;
		} else
			trace->startsolid = true;
		return true;
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
	if (frac < 0) frac = 0;
	if (frac > 1) frac = 1;
	midf = p1f + (p2f - p1f) * frac;
	for (i = 0; i < 3; i++)
		mid[i] = p1[i] + frac * (p2[i] - p1[i]);
	side = (t1 < 0);
	if (!SV_RecursiveHullCheck(hull, node->children[side], p1f, midf, p1, mid, trace))
		return false;
	if (SV_HullPointContents(hull, node->children[side ^ 1], mid) != CONTENTS_SOLID)
		return SV_RecursiveHullCheck(hull, node->children[side ^ 1], midf, p2f, mid, p2, trace);
	if (trace->allsolid)
		return false;
	if (!side) {
		VectorCopy(plane->normal, trace->plane.normal);
		trace->plane.dist = plane->dist;
	} else {
		for (i = 0; i < 3; i++) trace->plane.normal[i] = -plane->normal[i];
		trace->plane.dist = -plane->dist;
	}
	while (SV_HullPointContents(hull, hull->firstclipnode, mid) == CONTENTS_SOLID) {
		frac -= 0.1;
		if (frac < 0) {
			trace->fraction = midf;
			VectorCopy(mid, trace->endpos);
			return false;
		}
		midf = p1f + (p2f - p1f) * frac;
		for (i = 0; i < 3; i++)
			mid[i] = p1[i] + frac * (p2[i] - p1[i]);
	}
	trace->fraction = midf;
	VectorCopy(mid, trace->endpos);
	return false;
}

/* world-only SV_Move (hull by size, per SV_HullForEntity) */
static trace_t SV_Move(vec3_t start, vec3_t mins, vec3_t maxs, vec3_t end, int type,
	edict_t *passedict)
{
	trace_t trace;
	vec3_t size, start_l, end_l, offset;
	hull_t *hull;

	memset(&trace, 0, sizeof(trace));
	trace.fraction = 1;
	trace.allsolid = true;
	VectorCopy(end, trace.endpos);

	VectorSubtract(maxs, mins, size);
	if (size[0] < 3)
		hull = &hulls[0];
	else
		hull = &hulls[1];
	VectorSubtract(hull->clip_mins, mins, offset);
	VectorSubtract(start, offset, start_l);
	VectorSubtract(end, offset, end_l);
	/* world origin 0: offset addition per SV_ClipMoveToEntity */
	for (int i = 0; i < 3; i++) { start_l[i] = start[i] + offset[i] * 0; }
	/* C: offset = hull->clip_mins - mins + ent->origin; start_l = start - offset */
	VectorSubtract(hull->clip_mins, mins, offset);
	VectorSubtract(start, offset, start_l);
	VectorSubtract(end, offset, end_l);
	SV_RecursiveHullCheck(hull, hull->firstclipnode, 0, 1, start_l, end_l, &trace);
	if (trace.fraction != 1)
		VectorAdd(trace.endpos, offset, trace.endpos);
	if (trace.fraction < 1 || trace.startsolid)
		trace.ent = &world_ed;
	(void)type; (void)passedict;
	return trace;
}

/* ==== anglemod + PF_changeyaw (pr_cmds.c / mathlib.c, verbatim) ==== */
static float anglemod(float a)
{
	a = (360.0 / 65536) * ((int)(a * (65536 / 360.0)) & 65535);
	return a;
}

static edict_t *self_ed; /* PROG_TO_EDICT(self) stand-in */
static void PF_changeyaw(void)
{
	edict_t *ent = self_ed;
	float ideal, current, move, speed;
	current = anglemod(ent->v.angles[YAW]);
	ideal = ent->v.ideal_yaw;
	speed = ent->v.yaw_speed;
	if (current == ideal)
		return;
	move = ideal - current;
	if (ideal > current) {
		if (move >= 180) move = move - 360;
	} else {
		if (move <= -180) move = move + 360;
	}
	if (move > 0) {
		if (move > speed) move = speed;
	} else {
		if (move < -speed) move = -speed;
	}
	ent->v.angles[YAW] = anglemod(current + move);
}

/* ==== sv_move.c, verbatim (flying branch kept for fidelity) ==== */
static qboolean SV_CheckBottom(edict_t *ent)
{
	vec3_t mins, maxs, start, stop;
	trace_t trace;
	int x, y;
	float mid, bottom;

	VectorAdd(ent->v.origin, ent->v.mins, mins);
	VectorAdd(ent->v.origin, ent->v.maxs, maxs);
	start[2] = mins[2] - 1;
	for (x = 0; x <= 1; x++)
		for (y = 0; y <= 1; y++) {
			start[0] = x ? maxs[0] : mins[0];
			start[1] = y ? maxs[1] : mins[1];
			if (SV_PointContents(start) != CONTENTS_SOLID)
				goto realcheck;
		}
	return true;
realcheck:
	start[2] = mins[2];
	start[0] = stop[0] = (mins[0] + maxs[0]) * 0.5;
	start[1] = stop[1] = (mins[1] + maxs[1]) * 0.5;
	stop[2] = start[2] - 2 * STEPSIZE;
	{
		vec3_t zero = {0, 0, 0};
		trace = SV_Move(start, zero, zero, stop, true, ent);
	}
	if (trace.fraction == 1.0)
		return false;
	mid = bottom = trace.endpos[2];
	for (x = 0; x <= 1; x++)
		for (y = 0; y <= 1; y++) {
			start[0] = stop[0] = x ? maxs[0] : mins[0];
			start[1] = stop[1] = y ? maxs[1] : mins[1];
			{
				vec3_t zero = {0, 0, 0};
				trace = SV_Move(start, zero, zero, stop, true, ent);
			}
			if (trace.fraction != 1.0 && trace.endpos[2] > bottom)
				bottom = trace.endpos[2];
			if (trace.fraction == 1.0 || mid - trace.endpos[2] > STEPSIZE)
				return false;
		}
	return true;
}

static qboolean SV_movestep(edict_t *ent, vec3_t move, qboolean relink)
{
	float dz;
	vec3_t oldorg, neworg, end;
	trace_t trace;
	int i;
	edict_t *enemy;

	VectorCopy(ent->v.origin, oldorg);
	VectorAdd(ent->v.origin, move, neworg);

	if ((int)ent->v.flags & (FL_SWIM | FL_FLY)) {
		for (i = 0; i < 2; i++) {
			VectorAdd(ent->v.origin, move, neworg);
			enemy = ent->v.enemy;
			if (i == 0 && enemy != &world_ed) {
				dz = ent->v.origin[2] - ent->v.enemy->v.origin[2];
				if (dz > 40) neworg[2] -= 8;
				if (dz < 30) neworg[2] += 8;
			}
			trace = SV_Move(ent->v.origin, ent->v.mins, ent->v.maxs, neworg, false, ent);
			if (trace.fraction == 1) {
				if (((int)ent->v.flags & FL_SWIM) && SV_PointContents(trace.endpos) == CONTENTS_EMPTY)
					return false;
				VectorCopy(trace.endpos, ent->v.origin);
				if (relink)
					SV_LinkEdict(ent, true);
				return true;
			}
			if (enemy == &world_ed)
				break;
		}
		return false;
	}

	neworg[2] += STEPSIZE;
	VectorCopy(neworg, end);
	end[2] -= STEPSIZE * 2;

	trace = SV_Move(neworg, ent->v.mins, ent->v.maxs, end, false, ent);
	if (trace.allsolid)
		return false;
	if (trace.startsolid) {
		neworg[2] -= STEPSIZE;
		trace = SV_Move(neworg, ent->v.mins, ent->v.maxs, end, false, ent);
		if (trace.allsolid || trace.startsolid)
			return false;
	}
	if (trace.fraction == 1) {
		if ((int)ent->v.flags & FL_PARTIALGROUND) {
			VectorAdd(ent->v.origin, move, ent->v.origin);
			if (relink)
				SV_LinkEdict(ent, true);
			ent->v.flags = (int)ent->v.flags & ~FL_ONGROUND;
			return true;
		}
		return false;
	}
	VectorCopy(trace.endpos, ent->v.origin);
	if (!SV_CheckBottom(ent)) {
		if ((int)ent->v.flags & FL_PARTIALGROUND) {
			if (relink)
				SV_LinkEdict(ent, true);
			return true;
		}
		VectorCopy(oldorg, ent->v.origin);
		return false;
	}
	if ((int)ent->v.flags & FL_PARTIALGROUND)
		ent->v.flags = (int)ent->v.flags & ~FL_PARTIALGROUND;
	/* groundentity write skipped: no edict numbering in the harness */
	if (relink)
		SV_LinkEdict(ent, true);
	return true;
}

static qboolean SV_StepDirection(edict_t *ent, float yaw, float dist)
{
	vec3_t move, oldorigin;
	float delta;

	ent->v.ideal_yaw = yaw;
	self_ed = ent;
	PF_changeyaw();

	yaw = yaw * M_PI * 2 / 360;
	move[0] = cos(yaw) * dist;
	move[1] = sin(yaw) * dist;
	move[2] = 0;

	VectorCopy(ent->v.origin, oldorigin);
	if (SV_movestep(ent, move, false)) {
		delta = ent->v.angles[YAW] - ent->v.ideal_yaw;
		if (delta > 45 && delta < 315)
			VectorCopy(oldorigin, ent->v.origin);
		SV_LinkEdict(ent, true);
		return true;
	}
	SV_LinkEdict(ent, true);
	return false;
}

static void SV_FixCheckBottom(edict_t *ent)
{
	ent->v.flags = (int)ent->v.flags | FL_PARTIALGROUND;
}

#define DI_NODIR -1
static void SV_NewChaseDir(edict_t *actor, edict_t *enemy, float dist)
{
	float deltax, deltay;
	float d[3];
	float tdir, olddir, turnaround;

	olddir = anglemod((int)(actor->v.ideal_yaw / 45) * 45);
	turnaround = anglemod(olddir - 180);

	deltax = enemy->v.origin[0] - actor->v.origin[0];
	deltay = enemy->v.origin[1] - actor->v.origin[1];
	if (deltax > 10) d[1] = 0;
	else if (deltax < -10) d[1] = 180;
	else d[1] = DI_NODIR;
	if (deltay < -10) d[2] = 270;
	else if (deltay > 10) d[2] = 90;
	else d[2] = DI_NODIR;

	if (d[1] != DI_NODIR && d[2] != DI_NODIR) {
		if (d[1] == 0)
			tdir = d[2] == 90 ? 45 : 315;
		else
			tdir = d[2] == 90 ? 135 : 215;
		if (tdir != turnaround && SV_StepDirection(actor, tdir, dist))
			return;
	}
	if (((rand() & 3) & 1) || fabs(deltay) > fabs(deltax)) {
		tdir = d[1];
		d[1] = d[2];
		d[2] = tdir;
	}
	if (d[1] != DI_NODIR && d[1] != turnaround && SV_StepDirection(actor, d[1], dist))
		return;
	if (d[2] != DI_NODIR && d[2] != turnaround && SV_StepDirection(actor, d[2], dist))
		return;
	if (olddir != DI_NODIR && SV_StepDirection(actor, olddir, dist))
		return;
	if (rand() & 1) {
		for (tdir = 0; tdir <= 315; tdir += 45)
			if (tdir != turnaround && SV_StepDirection(actor, tdir, dist))
				return;
	} else {
		for (tdir = 315; tdir >= 0; tdir -= 45)
			if (tdir != turnaround && SV_StepDirection(actor, tdir, dist))
				return;
	}
	if (turnaround != DI_NODIR && SV_StepDirection(actor, turnaround, dist))
		return;
	actor->v.ideal_yaw = olddir;
	if (!SV_CheckBottom(actor))
		SV_FixCheckBottom(actor);
}

static qboolean SV_CloseEnough(edict_t *ent, edict_t *goal, float dist)
{
	int i;
	for (i = 0; i < 3; i++) {
		if (goal->v.absmin[i] > ent->v.absmax[i] + dist)
			return false;
		if (goal->v.absmax[i] < ent->v.absmin[i] - dist)
			return false;
	}
	return true;
}

static void SV_MoveToGoal(edict_t *ent, float dist)
{
	edict_t *goal = ent->v.goalentity;
	if (!((int)ent->v.flags & (FL_ONGROUND | FL_FLY | FL_SWIM)))
		return;
	if (ent->v.enemy != &world_ed && SV_CloseEnough(ent, goal, dist))
		return;
	if ((rand() & 3) == 1 || !SV_StepDirection(ent, ent->v.ideal_yaw, dist))
		SV_NewChaseDir(ent, goal, dist);
}

int main(void)
{
	load_bsp("external_assets/quake106/extracted/id1/pak0.pak", "maps/e1m1.bsp");

	edict_t monster, goal;
	memset(&monster, 0, sizeof(monster));
	memset(&goal, 0, sizeof(goal));
	monster.v.origin[0] = 480; monster.v.origin[1] = 100; monster.v.origin[2] = 24;
	monster.v.mins[0] = -16; monster.v.mins[1] = -16; monster.v.mins[2] = -24;
	monster.v.maxs[0] = 16; monster.v.maxs[1] = 16; monster.v.maxs[2] = 24;
	monster.v.flags = FL_ONGROUND;
	monster.v.yaw_speed = 20;
	monster.v.ideal_yaw = 0;
	monster.v.enemy = &goal;
	monster.v.goalentity = &goal;
	link_ed(&monster);

	goal.v.origin[0] = 480; goal.v.origin[1] = 480; goal.v.origin[2] = 24;
	link_ed(&goal);

	lcg_seed = 12345;
	for (int i = 1; i <= 200; i++) {
		SV_MoveToGoal(&monster, 8);
		printf("%d %.6f %.6f %.6f %.6f %.6f\n", i,
			monster.v.origin[0], monster.v.origin[1], monster.v.origin[2],
			monster.v.angles[YAW], monster.v.ideal_yaw);
	}
	return 0;
}
