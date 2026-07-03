/*
 * Ground-truth generator for player movement. The movement functions below
 * (ClipVelocity, SV_FlyMove, SV_AddGravity, SV_CheckStuck, SV_WalkMove,
 * SV_UserFriction, SV_Accelerate, SV_AirAccelerate, SV_AirMove,
 * SV_ClientThink, V_CalcRoll, AngleVectors + the hull tracing) are copied
 * verbatim from WinQuake sv_phys.c / sv_user.c / view.c / mathlib.c, with
 * a world-only SV_Move (no other entities). A scripted input sequence runs
 * at a fixed tick and the per-tick origin/velocity/flags stream is printed
 * for tests/test_movement.luau to compare.
 *
 * Build/run: cc -O2 -o /tmp/move_truth tools/move_truth.c -lm && /tmp/move_truth
 */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef float vec_t;
typedef float vec3_t[3];
typedef unsigned char byte;
typedef int qboolean;
#define true 1
#define false 0

#define CONTENTS_EMPTY -1
#define CONTENTS_SOLID -2
#define CONTENTS_WATER -3
#define DIST_EPSILON (0.03125)
#define M_PI_Q 3.14159265358979323846
#define PITCH 0
#define YAW 1
#define ROLL 2

#define FL_ONGROUND 512
#define FL_WATERJUMP 2048
#define MOVETYPE_WALK 3
#define SOLID_BSP 4

#define DotProduct(x, y) ((x)[0] * (y)[0] + (x)[1] * (y)[1] + (x)[2] * (y)[2])
#define VectorCopy(a, b) ((b)[0] = (a)[0], (b)[1] = (a)[1], (b)[2] = (a)[2])
#define VectorAdd(a, b, c) ((c)[0] = (a)[0] + (b)[0], (c)[1] = (a)[1] + (b)[1], (c)[2] = (a)[2] + (b)[2])
#define VectorSubtract(a, b, c) ((c)[0] = (a)[0] - (b)[0], (c)[1] = (a)[1] - (b)[1], (c)[2] = (a)[2] - (b)[2])
#define VectorScale(a, s, c) ((c)[0] = (a)[0] * (s), (c)[1] = (a)[1] * (s), (c)[2] = (a)[2] * (s))

static vec3_t vec3_origin = {0, 0, 0};

/* ==== cvars ==== */
static float sv_friction = 4, sv_stopspeed = 100, sv_gravity = 800;
static float sv_maxspeed = 320, sv_accelerate = 10, sv_edgefriction = 2;
static float sv_maxvelocity = 2000, sv_nostep = 0;

static float host_frametime;
static double sv_time;

/* ==== entity ==== */
typedef struct {
    vec3_t origin, oldorigin, velocity, angles, v_angle, punchangle;
    vec3_t mins, maxs;
    float flags, movetype, waterlevel, watertype, teleport_time, health, solid;
    vec3_t movedir;
    vec3_t view_ofs;
} entvars_t;

typedef struct {
    entvars_t v;
    int free;
} edict_t;

static edict_t player;
static edict_t *sv_player = &player;

/* ==== hull tracing (verbatim from world.c, as in trace_truth.c) ==== */

typedef struct {
    float normal[3];
    float dist;
    int type;
    int signbits;
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
    vec3_t clip_mins, clip_maxs;
} hull_t;

typedef struct {
    qboolean allsolid, startsolid, inopen, inwater;
    float fraction;
    vec3_t endpos;
    struct {
        vec3_t normal;
        float dist;
    } plane;
    edict_t *ent;
} trace_t;

static hull_t hulls[4];

int SV_HullPointContents(hull_t *hull, int num, vec3_t p)
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
        if (d < 0)
            num = node->children[1];
        else
            num = node->children[0];
    }
    return num;
}

qboolean SV_RecursiveHullCheck(hull_t *hull, int num, float p1f, float p2f, vec3_t p1,
                               vec3_t p2, trace_t *trace)
{
    dclipnode_t *node;
    mplane_t *plane;
    float t1, t2, frac;
    int i, side;
    vec3_t mid;
    float midf;

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
    if (frac < 0)
        frac = 0;
    if (frac > 1)
        frac = 1;

    midf = p1f + (p2f - p1f) * frac;
    for (i = 0; i < 3; i++)
        mid[i] = p1[i] + frac * (p2[i] - p1[i]);

    side = (t1 < 0);

    if (!SV_RecursiveHullCheck(hull, node->children[side], p1f, midf, p1, mid, trace))
        return false;

    if (SV_HullPointContents(hull, node->children[side ^ 1], mid) != CONTENTS_SOLID)
        return SV_RecursiveHullCheck(hull, node->children[side ^ 1], midf, p2f, mid, p2,
                                     trace);

    if (trace->allsolid)
        return false;

    if (!side) {
        VectorCopy(plane->normal, trace->plane.normal);
        trace->plane.dist = plane->dist;
    } else {
        VectorSubtract(vec3_origin, plane->normal, trace->plane.normal);
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

/* SV_Move against the world only (hull by size, per SV_HullForEntity) */
trace_t SV_Move(vec3_t start, vec3_t mins, vec3_t maxs, vec3_t end, int type,
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
    else if (size[0] <= 32)
        hull = &hulls[1];
    else
        hull = &hulls[2];

    VectorSubtract(hull->clip_mins, mins, offset);

    VectorSubtract(start, offset, start_l);
    VectorSubtract(end, offset, end_l);
    /* world's origin is 0, so offset is just the hull adjust */
    VectorSubtract(start, offset, start_l);
    VectorSubtract(end, offset, end_l);
    /* NOTE: hull offset ADDs to origin in C (offset = clip_mins - mins + org);
       world org = 0, and trace runs in hull space start-offset */
    SV_RecursiveHullCheck(hull, hull->firstclipnode, 0, 1, start_l, end_l, &trace);

    if (trace.fraction != 1)
        VectorAdd(trace.endpos, offset, trace.endpos);
    if (trace.fraction < 1 || trace.startsolid)
        trace.ent = (edict_t *)1; /* the world */

    (void)type;
    (void)passedict;
    return trace;
}

edict_t *SV_TestEntityPosition(edict_t *ent)
{
    trace_t trace = SV_Move(ent->v.origin, ent->v.mins, ent->v.maxs, ent->v.origin, 0, ent);
    if (trace.startsolid)
        return (edict_t *)1;
    return NULL;
}

/* ==== mathlib.c ==== */
void AngleVectors(vec3_t angles, vec3_t forward, vec3_t right, vec3_t up)
{
    float angle, sr, sp, sy, cr, cp, cy;

    angle = angles[YAW] * (M_PI_Q * 2 / 360);
    sy = sin(angle);
    cy = cos(angle);
    angle = angles[PITCH] * (M_PI_Q * 2 / 360);
    sp = sin(angle);
    cp = cos(angle);
    angle = angles[ROLL] * (M_PI_Q * 2 / 360);
    sr = sin(angle);
    cr = cos(angle);

    forward[0] = cp * cy;
    forward[1] = cp * sy;
    forward[2] = -sp;
    right[0] = (-1 * sr * sp * cy + -1 * cr * -sy);
    right[1] = (-1 * sr * sp * sy + -1 * cr * cy);
    right[2] = -1 * sr * cp;
    up[0] = (cr * sp * cy + -sr * -sy);
    up[1] = (cr * sp * sy + -sr * cy);
    up[2] = cr * cp;
}

float VectorNormalize(vec3_t v)
{
    float length, ilength;
    length = v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
    length = sqrt(length);
    if (length) {
        ilength = 1 / length;
        v[0] *= ilength;
        v[1] *= ilength;
        v[2] *= ilength;
    }
    return length;
}

float Length(vec3_t v)
{
    return sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
}

/* ==== view.c ==== */
float V_CalcRoll(vec3_t angles, vec3_t velocity)
{
    vec3_t forward, right, up;
    float sign, side, value;

    AngleVectors(angles, forward, right, up);
    side = DotProduct(velocity, right);
    sign = side < 0 ? -1 : 1;
    side = fabs(side);
    value = 2.0; /* cl_rollangle */
    if (side < 200) /* cl_rollspeed */
        side = side * value / 200;
    else
        side = value;
    return side * sign;
}

/* ==== sv_phys.c ==== */
#define STOP_EPSILON 0.1

int ClipVelocity(vec3_t in, vec3_t normal, vec3_t out, float overbounce)
{
    float backoff, change;
    int i, blocked;

    blocked = 0;
    if (normal[2] > 0)
        blocked |= 1;
    if (!normal[2])
        blocked |= 2;

    backoff = DotProduct(in, normal) * overbounce;

    for (i = 0; i < 3; i++) {
        change = normal[i] * backoff;
        out[i] = in[i] - change;
        if (out[i] > -STOP_EPSILON && out[i] < STOP_EPSILON)
            out[i] = 0;
    }
    return blocked;
}

void SV_CheckVelocity(edict_t *ent)
{
    int i;
    for (i = 0; i < 3; i++) {
        if (ent->v.velocity[i] > sv_maxvelocity)
            ent->v.velocity[i] = sv_maxvelocity;
        else if (ent->v.velocity[i] < -sv_maxvelocity)
            ent->v.velocity[i] = -sv_maxvelocity;
    }
}

#define MAX_CLIP_PLANES 5
int SV_FlyMove(edict_t *ent, float time, trace_t *steptrace)
{
    int bumpcount, numbumps;
    vec3_t dir;
    float d;
    int numplanes;
    vec3_t planes[MAX_CLIP_PLANES];
    vec3_t primal_velocity, original_velocity, new_velocity;
    int i, j;
    trace_t trace;
    vec3_t end;
    float time_left;
    int blocked;

    numbumps = 4;
    blocked = 0;
    VectorCopy(ent->v.velocity, original_velocity);
    VectorCopy(ent->v.velocity, primal_velocity);
    numplanes = 0;
    time_left = time;

    for (bumpcount = 0; bumpcount < numbumps; bumpcount++) {
        if (!ent->v.velocity[0] && !ent->v.velocity[1] && !ent->v.velocity[2])
            break;

        for (i = 0; i < 3; i++)
            end[i] = ent->v.origin[i] + time_left * ent->v.velocity[i];

        trace = SV_Move(ent->v.origin, ent->v.mins, ent->v.maxs, end, 0, ent);

        if (trace.allsolid) {
            VectorCopy(vec3_origin, ent->v.velocity);
            return 3;
        }

        if (trace.fraction > 0) {
            VectorCopy(trace.endpos, ent->v.origin);
            VectorCopy(ent->v.velocity, original_velocity);
            numplanes = 0;
        }

        if (trace.fraction == 1)
            break;

        if (trace.plane.normal[2] > 0.7) {
            blocked |= 1;
            ent->v.flags = (int)ent->v.flags | FL_ONGROUND;
        }
        if (!trace.plane.normal[2]) {
            blocked |= 2;
            if (steptrace)
                *steptrace = trace;
        }

        /* SV_Impact would run touch functions here (none in world-only) */

        time_left -= time_left * trace.fraction;

        if (numplanes >= MAX_CLIP_PLANES) {
            VectorCopy(vec3_origin, ent->v.velocity);
            return 3;
        }

        VectorCopy(trace.plane.normal, planes[numplanes]);
        numplanes++;

        for (i = 0; i < numplanes; i++) {
            ClipVelocity(original_velocity, planes[i], new_velocity, 1);
            for (j = 0; j < numplanes; j++)
                if (j != i) {
                    if (DotProduct(new_velocity, planes[j]) < 0)
                        break;
                }
            if (j == numplanes)
                break;
        }

        if (i != numplanes) {
            VectorCopy(new_velocity, ent->v.velocity);
        } else {
            if (numplanes != 2) {
                VectorCopy(vec3_origin, ent->v.velocity);
                return 7;
            }
            dir[0] = planes[0][1] * planes[1][2] - planes[0][2] * planes[1][1];
            dir[1] = planes[0][2] * planes[1][0] - planes[0][0] * planes[1][2];
            dir[2] = planes[0][0] * planes[1][1] - planes[0][1] * planes[1][0];
            d = DotProduct(dir, ent->v.velocity);
            VectorScale(dir, d, ent->v.velocity);
        }

        if (DotProduct(ent->v.velocity, primal_velocity) <= 0) {
            VectorCopy(vec3_origin, ent->v.velocity);
            return blocked;
        }
    }

    return blocked;
}

void SV_AddGravity(edict_t *ent)
{
    ent->v.velocity[2] -= 1.0 * sv_gravity * host_frametime;
}

trace_t SV_PushEntity(edict_t *ent, vec3_t push)
{
    trace_t trace;
    vec3_t end;

    VectorAdd(ent->v.origin, push, end);
    trace = SV_Move(ent->v.origin, ent->v.mins, ent->v.maxs, end, 0, ent);
    VectorCopy(trace.endpos, ent->v.origin);
    return trace;
}

void SV_CheckStuck(edict_t *ent)
{
    int i, j, z;
    vec3_t org;

    if (!SV_TestEntityPosition(ent)) {
        VectorCopy(ent->v.origin, ent->v.oldorigin);
        return;
    }

    VectorCopy(ent->v.origin, org);
    VectorCopy(ent->v.oldorigin, ent->v.origin);
    if (!SV_TestEntityPosition(ent)) {
        return;
    }

    for (z = 0; z < 18; z++)
        for (i = -1; i <= 1; i++)
            for (j = -1; j <= 1; j++) {
                ent->v.origin[0] = org[0] + i;
                ent->v.origin[1] = org[1] + j;
                ent->v.origin[2] = org[2] + z;
                if (!SV_TestEntityPosition(ent)) {
                    return;
                }
            }

    VectorCopy(org, ent->v.origin);
}

qboolean SV_CheckWater(edict_t *ent)
{
    vec3_t point;
    int cont;

    point[0] = ent->v.origin[0];
    point[1] = ent->v.origin[1];
    point[2] = ent->v.origin[2] + ent->v.mins[2] + 1;

    ent->v.waterlevel = 0;
    ent->v.watertype = CONTENTS_EMPTY;
    cont = SV_HullPointContents(&hulls[0], hulls[0].firstclipnode, point);
    if (cont <= CONTENTS_WATER) {
        ent->v.watertype = cont;
        ent->v.waterlevel = 1;
        point[2] = ent->v.origin[2] + (ent->v.mins[2] + ent->v.maxs[2]) * 0.5;
        cont = SV_HullPointContents(&hulls[0], hulls[0].firstclipnode, point);
        if (cont <= CONTENTS_WATER) {
            ent->v.waterlevel = 2;
            point[2] = ent->v.origin[2] + ent->v.view_ofs[2];
            cont = SV_HullPointContents(&hulls[0], hulls[0].firstclipnode, point);
            if (cont <= CONTENTS_WATER)
                ent->v.waterlevel = 3;
        }
    }

    return ent->v.waterlevel > 1;
}

void SV_WallFriction(edict_t *ent, trace_t *trace)
{
    vec3_t forward, right, up;
    float d, i;
    vec3_t into, side;

    AngleVectors(ent->v.v_angle, forward, right, up);
    d = DotProduct(trace->plane.normal, forward);

    d += 0.5;
    if (d >= 0)
        return;

    i = DotProduct(trace->plane.normal, ent->v.velocity);
    VectorScale(trace->plane.normal, i, into);
    VectorSubtract(ent->v.velocity, into, side);

    ent->v.velocity[0] = side[0] * (1 + d);
    ent->v.velocity[1] = side[1] * (1 + d);
}

int SV_TryUnstick(edict_t *ent, vec3_t oldvel)
{
    int i;
    vec3_t oldorg;
    vec3_t dir;
    int clip;
    trace_t steptrace;

    VectorCopy(ent->v.origin, oldorg);
    VectorCopy(vec3_origin, dir);

    for (i = 0; i < 8; i++) {
        switch (i) {
        case 0: dir[0] = 2; dir[1] = 0; break;
        case 1: dir[0] = 0; dir[1] = 2; break;
        case 2: dir[0] = -2; dir[1] = 0; break;
        case 3: dir[0] = 0; dir[1] = -2; break;
        case 4: dir[0] = 2; dir[1] = 2; break;
        case 5: dir[0] = -2; dir[1] = 2; break;
        case 6: dir[0] = 2; dir[1] = -2; break;
        case 7: dir[0] = -2; dir[1] = -2; break;
        }

        SV_PushEntity(ent, dir);

        ent->v.velocity[0] = oldvel[0];
        ent->v.velocity[1] = oldvel[1];
        ent->v.velocity[2] = 0;
        clip = SV_FlyMove(ent, 0.1, &steptrace);

        if (fabs(oldorg[1] - ent->v.origin[1]) > 4 || fabs(oldorg[0] - ent->v.origin[0]) > 4) {
            return clip;
        }

        VectorCopy(oldorg, ent->v.origin);
    }

    VectorCopy(vec3_origin, ent->v.velocity);
    return 7;
}

#define STEPSIZE 18
void SV_WalkMove(edict_t *ent)
{
    vec3_t upmove, downmove;
    vec3_t oldorg, oldvel;
    vec3_t nosteporg, nostepvel;
    int clip;
    int oldonground;
    trace_t steptrace, downtrace;

    oldonground = (int)ent->v.flags & FL_ONGROUND;
    ent->v.flags = (int)ent->v.flags & ~FL_ONGROUND;

    VectorCopy(ent->v.origin, oldorg);
    VectorCopy(ent->v.velocity, oldvel);

    clip = SV_FlyMove(ent, host_frametime, &steptrace);

    if (!(clip & 2))
        return;

    if (!oldonground && ent->v.waterlevel == 0)
        return;

    if (ent->v.movetype != MOVETYPE_WALK)
        return;

    if (sv_nostep)
        return;

    if ((int)sv_player->v.flags & FL_WATERJUMP)
        return;

    VectorCopy(ent->v.origin, nosteporg);
    VectorCopy(ent->v.velocity, nostepvel);

    VectorCopy(oldorg, ent->v.origin);

    VectorCopy(vec3_origin, upmove);
    VectorCopy(vec3_origin, downmove);
    upmove[2] = STEPSIZE;
    downmove[2] = -STEPSIZE + oldvel[2] * host_frametime;

    SV_PushEntity(ent, upmove);

    ent->v.velocity[0] = oldvel[0];
    ent->v.velocity[1] = oldvel[1];
    ent->v.velocity[2] = 0;
    clip = SV_FlyMove(ent, host_frametime, &steptrace);

    if (clip) {
        if (fabs(oldorg[1] - ent->v.origin[1]) < 0.03125 && fabs(oldorg[0] - ent->v.origin[0]) < 0.03125) {
            clip = SV_TryUnstick(ent, oldvel);
        }
    }

    if (clip & 2)
        SV_WallFriction(ent, &steptrace);

    downtrace = SV_PushEntity(ent, downmove);

    if (downtrace.plane.normal[2] > 0.7) {
        if (ent->v.solid == SOLID_BSP) {
            ent->v.flags = (int)ent->v.flags | FL_ONGROUND;
        }
    } else {
        VectorCopy(nosteporg, ent->v.origin);
        VectorCopy(nostepvel, ent->v.velocity);
    }
}

/* ==== sv_user.c ==== */
static vec3_t forward, right, up;
static vec3_t wishdir;
static float wishspeed;
static float *velocity;
static float *origin;
static float *angles;
static qboolean onground;

typedef struct {
    float forwardmove, sidemove, upmove;
} usercmd_t;
static usercmd_t cmd;

void SV_UserFriction(void)
{
    float *vel;
    float speed, newspeed, control;
    vec3_t start, stop;
    float friction;
    trace_t trace;

    vel = velocity;

    speed = sqrt(vel[0] * vel[0] + vel[1] * vel[1]);
    if (!speed)
        return;

    start[0] = stop[0] = origin[0] + vel[0] / speed * 16;
    start[1] = stop[1] = origin[1] + vel[1] / speed * 16;
    start[2] = origin[2] + sv_player->v.mins[2];
    stop[2] = start[2] - 34;

    trace = SV_Move(start, vec3_origin, vec3_origin, stop, 1, sv_player);

    if (trace.fraction == 1.0)
        friction = sv_friction * sv_edgefriction;
    else
        friction = sv_friction;

    control = speed < sv_stopspeed ? sv_stopspeed : speed;
    newspeed = speed - host_frametime * control * friction;

    if (newspeed < 0)
        newspeed = 0;
    newspeed /= speed;

    vel[0] = vel[0] * newspeed;
    vel[1] = vel[1] * newspeed;
    vel[2] = vel[2] * newspeed;
}

void SV_Accelerate(void)
{
    int i;
    float addspeed, accelspeed, currentspeed;

    currentspeed = DotProduct(velocity, wishdir);
    addspeed = wishspeed - currentspeed;
    if (addspeed <= 0)
        return;
    accelspeed = sv_accelerate * host_frametime * wishspeed;
    if (accelspeed > addspeed)
        accelspeed = addspeed;

    for (i = 0; i < 3; i++)
        velocity[i] += accelspeed * wishdir[i];
}

void SV_AirAccelerate(vec3_t wishveloc)
{
    int i;
    float addspeed, wishspd, accelspeed, currentspeed;

    wishspd = VectorNormalize(wishveloc);
    if (wishspd > 30)
        wishspd = 30;
    currentspeed = DotProduct(velocity, wishveloc);
    addspeed = wishspd - currentspeed;
    if (addspeed <= 0)
        return;
    accelspeed = sv_accelerate * wishspeed * host_frametime;
    if (accelspeed > addspeed)
        accelspeed = addspeed;

    for (i = 0; i < 3; i++)
        velocity[i] += accelspeed * wishveloc[i];
}

void DropPunchAngle(void)
{
    float len;

    len = VectorNormalize(sv_player->v.punchangle);
    len -= 10 * host_frametime;
    if (len < 0)
        len = 0;
    VectorScale(sv_player->v.punchangle, len, sv_player->v.punchangle);
}

void SV_AirMove(void)
{
    int i;
    vec3_t wishvel;
    float fmove, smove;

    AngleVectors(sv_player->v.angles, forward, right, up);

    fmove = cmd.forwardmove;
    smove = cmd.sidemove;

    if (sv_time < sv_player->v.teleport_time && fmove < 0)
        fmove = 0;

    for (i = 0; i < 3; i++)
        wishvel[i] = forward[i] * fmove + right[i] * smove;

    if ((int)sv_player->v.movetype != MOVETYPE_WALK)
        wishvel[2] = cmd.upmove;
    else
        wishvel[2] = 0;

    VectorCopy(wishvel, wishdir);
    wishspeed = VectorNormalize(wishdir);
    if (wishspeed > sv_maxspeed) {
        VectorScale(wishvel, sv_maxspeed / wishspeed, wishvel);
        wishspeed = sv_maxspeed;
    }

    if (onground) {
        SV_UserFriction();
        SV_Accelerate();
    } else {
        SV_AirAccelerate(wishvel);
    }
}

void SV_WaterMove(void)
{
    int i;
    vec3_t wishvel;
    float speed, newspeed, wishspeed_l, addspeed, accelspeed;

    AngleVectors(sv_player->v.v_angle, forward, right, up);

    for (i = 0; i < 3; i++)
        wishvel[i] = forward[i] * cmd.forwardmove + right[i] * cmd.sidemove;

    if (!cmd.forwardmove && !cmd.sidemove && !cmd.upmove)
        wishvel[2] -= 60;
    else
        wishvel[2] += cmd.upmove;

    wishspeed_l = Length(wishvel);
    if (wishspeed_l > sv_maxspeed) {
        VectorScale(wishvel, sv_maxspeed / wishspeed_l, wishvel);
        wishspeed_l = sv_maxspeed;
    }
    wishspeed_l *= 0.7;

    speed = Length(velocity);
    if (speed) {
        newspeed = speed - host_frametime * speed * sv_friction;
        if (newspeed < 0)
            newspeed = 0;
        VectorScale(velocity, newspeed / speed, velocity);
    } else
        newspeed = 0;

    if (!wishspeed_l)
        return;

    addspeed = wishspeed_l - newspeed;
    if (addspeed <= 0)
        return;

    VectorNormalize(wishvel);
    accelspeed = sv_accelerate * wishspeed_l * host_frametime;
    if (accelspeed > addspeed)
        accelspeed = addspeed;

    for (i = 0; i < 3; i++)
        velocity[i] += accelspeed * wishvel[i];
}

void SV_ClientThink(void)
{
    vec3_t v_angle;

    onground = (int)sv_player->v.flags & FL_ONGROUND;

    origin = sv_player->v.origin;
    velocity = sv_player->v.velocity;

    DropPunchAngle();

    if (sv_player->v.health <= 0)
        return;

    angles = sv_player->v.angles;

    VectorAdd(sv_player->v.v_angle, sv_player->v.punchangle, v_angle);
    angles[ROLL] = V_CalcRoll(sv_player->v.angles, sv_player->v.velocity) * 4;
    angles[PITCH] = -v_angle[PITCH] / 3;
    angles[YAW] = v_angle[YAW];

    if ((int)sv_player->v.flags & FL_WATERJUMP)
        return; /* SV_WaterJump not needed on this path */

    if (sv_player->v.waterlevel >= 2) {
        SV_WaterMove();
        return;
    }

    SV_AirMove();
}

/* ==== BSP loading (as in trace_truth.c) ==== */

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
    byte *bspdata = pak_read(pak, map, &len);
    lump_t *lumps = (lump_t *)(bspdata + 4);

    struct dplane {
        float normal[3];
        float dist;
        int type;
    } *dplanes = (void *)(bspdata + lumps[1].fileofs);
    int numplanes = lumps[1].filelen / 20;
    mplane_t *planes = calloc(numplanes, sizeof(mplane_t));
    for (int i = 0; i < numplanes; i++) {
        for (int j = 0; j < 3; j++)
            planes[i].normal[j] = dplanes[i].normal[j];
        planes[i].dist = dplanes[i].dist;
        planes[i].type = dplanes[i].type;
    }

    struct dnode {
        int planenum;
        short children[2];
        short mins[3], maxs[3];
        unsigned short firstface, numfaces;
    } *dnodes = (void *)(bspdata + lumps[5].fileofs);
    int numnodes = lumps[5].filelen / 24;

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

    dclipnode_t *dclip = (void *)(bspdata + lumps[9].fileofs);
    int numclip = lumps[9].filelen / 8;

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
    hulls[1].clip_mins[0] = -16; hulls[1].clip_mins[1] = -16; hulls[1].clip_mins[2] = -24;
    hulls[1].clip_maxs[0] = 16; hulls[1].clip_maxs[1] = 16; hulls[1].clip_maxs[2] = 32;

    hulls[2].clipnodes = dclip;
    hulls[2].planes = planes;
    hulls[2].firstclipnode = dmodels[0].headnode[2];
    hulls[2].lastclipnode = numclip - 1;
    hulls[2].clip_mins[0] = -32; hulls[2].clip_mins[1] = -32; hulls[2].clip_mins[2] = -24;
    hulls[2].clip_maxs[0] = 32; hulls[2].clip_maxs[1] = 32; hulls[2].clip_maxs[2] = 64;
}

/* ==== the scripted run ==== */

typedef struct {
    int untilTick;
    float fwd, side, upm;
    float yaw, pitch;
    int jump;
} phase_t;

/* mirrored exactly in tests/test_movement.luau */
static phase_t script[] = {
    {40, 400, 0, 0, 90, 0, 0},    /* run north */
    {80, 400, 0, 0, 135, 0, 0},   /* veer north-west */
    {120, 200, 350, 0, 90, 0, 0}, /* strafe-run */
    {160, 400, 0, 0, 90, 0, 1},   /* run + jump held */
    {200, -200, 0, 0, 90, 0, 0},  /* backpedal */
    {240, 400, -350, 0, 45, 0, 1},/* diagonal + jump */
    {300, 400, 0, 0, 180, 10, 0}, /* run west looking down a bit */
};

int main(void)
{
    load_bsp("external_assets/quake106/extracted/id1/pak0.pak", "maps/e1m1.bsp");

    memset(&player, 0, sizeof(player));
    player.v.origin[0] = 480; player.v.origin[1] = -352; player.v.origin[2] = 88;
    VectorCopy(player.v.origin, player.v.oldorigin);
    player.v.mins[0] = -16; player.v.mins[1] = -16; player.v.mins[2] = -24;
    player.v.maxs[0] = 16; player.v.maxs[1] = 16; player.v.maxs[2] = 32;
    player.v.view_ofs[2] = 22;
    player.v.movetype = MOVETYPE_WALK;
    player.v.solid = SOLID_BSP; /* so WalkMove sets onground (matches port) */
    player.v.health = 100;

    host_frametime = 0.05;
    sv_time = 1.0;

    int nphases = sizeof(script) / sizeof(script[0]);
    int tick = 0;
    for (int ph = 0; ph < nphases; ph++) {
        for (; tick < script[ph].untilTick; tick++) {
            cmd.forwardmove = script[ph].fwd;
            cmd.sidemove = script[ph].side;
            cmd.upmove = script[ph].upm;
            player.v.v_angle[YAW] = script[ph].yaw;
            player.v.v_angle[PITCH] = script[ph].pitch;

            /* jump emulation (PlayerJump essentials) */
            if (script[ph].jump && ((int)player.v.flags & FL_ONGROUND)) {
                player.v.flags = (int)player.v.flags & ~FL_ONGROUND;
                player.v.velocity[2] += 270;
            }

            SV_ClientThink();

            /* SV_Physics_Client, MOVETYPE_WALK path (no QC thinks) */
            SV_CheckVelocity(&player);
            if (!SV_CheckWater(&player) && !((int)player.v.flags & FL_WATERJUMP))
                SV_AddGravity(&player);
            SV_CheckStuck(&player);
            SV_WalkMove(&player);

            sv_time += host_frametime;

            printf("%d %.9g %.9g %.9g %.9g %.9g %.9g %d\n", tick,
                   player.v.origin[0], player.v.origin[1], player.v.origin[2],
                   player.v.velocity[0], player.v.velocity[1], player.v.velocity[2],
                   ((int)player.v.flags & FL_ONGROUND) ? 1 : 0);
        }
    }
    return 0;
}
