/* shim environment so the verbatim QW pmove.c/pmovetst.c compile alone */
#ifndef QW_SHIM_QUAKEDEF
#define QW_SHIM_QUAKEDEF
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned char byte;
typedef int qboolean;
#define false 0
#define true 1

typedef float vec_t;
typedef vec_t vec3_t[3];

#define CONTENTS_EMPTY -1
#define CONTENTS_SOLID -2
#define CONTENTS_WATER -3
#define CONTENTS_SLIME -4
#define CONTENTS_LAVA -5

/* QW mathlib.h forms exactly (block macros — pmove.c depends on it) */
#define DotProduct(x,y) (x[0]*y[0]+x[1]*y[1]+x[2]*y[2])
#define VectorSubtract(a,b,c) {c[0]=a[0]-b[0];c[1]=a[1]-b[1];c[2]=a[2]-b[2];}
#define VectorAdd(a,b,c) {c[0]=a[0]+b[0];c[1]=a[1]+b[1];c[2]=a[2]+b[2];}
#define VectorCopy(a,b) {b[0]=a[0];b[1]=a[1];b[2]=a[2];}
static void VectorScale(vec3_t in, vec_t scale, vec3_t out)
{ out[0]=in[0]*scale; out[1]=in[1]*scale; out[2]=in[2]*scale; }

extern vec3_t vec3_origin;

static void VectorMA(vec3_t veca, float scale, vec3_t vecb, vec3_t vecc)
{ vecc[0]=veca[0]+scale*vecb[0]; vecc[1]=veca[1]+scale*vecb[1]; vecc[2]=veca[2]+scale*vecb[2]; }
static void CrossProduct(vec3_t v1, vec3_t v2, vec3_t cross)
{ cross[0]=v1[1]*v2[2]-v1[2]*v2[1]; cross[1]=v1[2]*v2[0]-v1[0]*v2[2]; cross[2]=v1[0]*v2[1]-v1[1]*v2[0]; }
static float Length(vec3_t v)
{ return (float)sqrt(v[0]*v[0]+v[1]*v[1]+v[2]*v[2]); }
static float VectorNormalize(vec3_t v)
{
	float length = (float)sqrt(v[0]*v[0]+v[1]*v[1]+v[2]*v[2]);
	if (length) { float ilength = 1/length; v[0]*=ilength; v[1]*=ilength; v[2]*=ilength; }
	return length;
}
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
static void AngleVectors(vec3_t angles, vec3_t forward, vec3_t right, vec3_t up)
{
	float angle, sr, sp, sy, cr, cp, cy;
	angle = angles[1] * (M_PI*2 / 360);
	sy = sin(angle); cy = cos(angle);
	angle = angles[0] * (M_PI*2 / 360);
	sp = sin(angle); cp = cos(angle);
	angle = angles[2] * (M_PI*2 / 360);
	sr = sin(angle); cr = cos(angle);
	forward[0] = cp*cy; forward[1] = cp*sy; forward[2] = -sp;
	right[0] = (-1*sr*sp*cy+-1*cr*-sy); right[1] = (-1*sr*sp*sy+-1*cr*cy); right[2] = -1*sr*cp;
	up[0] = (cr*sp*cy+-sr*-sy); up[1] = (cr*sp*sy+-sr*cy); up[2] = cr*cp;
}

static void Sys_Error(const char *fmt, ...) { fprintf(stderr, "Sys_Error: %s\n", fmt); exit(1); }
#define Con_Printf(...) ((void)0)
#define Con_DPrintf(...) ((void)0)

typedef struct { float normal[3]; float dist; byte type; byte signbits; byte pad[2]; } mplane_t;
typedef struct { int planenum; short children[2]; } dclipnode_t;
typedef struct {
	dclipnode_t *clipnodes;
	mplane_t *planes;
	int firstclipnode;
	int lastclipnode;
	vec3_t clip_mins;
	vec3_t clip_maxs;
} hull_t;
typedef struct model_s { hull_t hulls[4]; } model_t;

typedef struct usercmd_s {
	byte msec;
	vec3_t angles;
	short forwardmove, sidemove, upmove;
	byte buttons;
	byte impulse;
} usercmd_t;

#include "../../reference/quake-c/QW/client/pmove.h"

#endif
