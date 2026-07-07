/* QW view/refdef ground truth: the VERBATIM view-composition functions from
   the GPL QuakeWorld client (reference/quake-c/QW/client/view.c — V_CalcRoll,
   V_CalcBob, CalcGunAngle, V_CalcViewRoll, and the V_CalcRefdef body) run
   over a scripted 400-frame input tape. Output is compared per-frame by
   tests/test_view_truth.luau against view.calcRefdefQW.

   Scope: the refdef core only. V_DriftPitch is excluded (the port drives
   drift outside the core; it has its own test_view battery), V_AddIdle is
   inert at the default v_idlescale 0, intermission/chase are caller
   branches in both C (V_RenderView) and the port.

   cc -O2 -o /tmp/view_truth tools/view_truth.c -lm
   /tmp/view_truth > tests/fixtures/view_truth.txt
*/
#include <math.h>
#include <stdio.h>

#define M_PI_Q 3.14159265358979323846
typedef float vec_t;
typedef vec_t vec3_t[3];
#define PITCH 0
#define YAW 1
#define ROLL 2
#define DotProduct(x, y) (x[0] * y[0] + x[1] * y[1] + x[2] * y[2])
#define VectorCopy(a, b) \
	{ b[0] = a[0]; b[1] = a[1]; b[2] = a[2]; }

/* ==== engine shims (float cvar values, exactly as cvar_t stores them) ==== */
typedef struct { float value; } cvar_t;
static cvar_t cl_rollspeed = {200};
static cvar_t cl_rollangle = {2.0};
static cvar_t cl_bob = {0.02};
static cvar_t cl_bobcycle = {0.6};
static cvar_t cl_bobup = {0.5};
static cvar_t v_kicktime = {0.5};
static cvar_t v_idlescale = {0};
static cvar_t v_iyaw_cycle = {2}, v_iyaw_level = {0.3};
static cvar_t v_iroll_cycle = {0.5}, v_iroll_level = {0.1};
static cvar_t v_ipitch_cycle = {1}, v_ipitch_level = {0.3};
static cvar_t scr_viewsize = {100};

static struct {
	int spectator;
	vec3_t simorg, simvel, simangles;
	float punchangle;
	double time;
	struct { vec3_t angles, origin; int model; int frame; } viewent;
} cl;
static struct { vec3_t vieworg, viewangles; } r_refdef;
static struct { int flags; int onground; int weaponframe; } vmsg, *view_message = &vmsg;
static int onground; /* mirrors view_message->onground, like V_RenderView */
static double host_frametime;
static float v_dmg_time, v_dmg_roll, v_dmg_pitch;
#define PF_DEAD (1 << 5)  /* bothdefs.h */
#define PF_GIB (1 << 6)

/* mathlib.c AngleVectors, verbatim */
static void AngleVectors(vec3_t angles, vec3_t forward, vec3_t right, vec3_t up)
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

/* view.c V_CalcRoll, verbatim */
static float V_CalcRoll(vec3_t angles, vec3_t velocity)
{
	vec3_t forward, right, up;
	float sign, side, value;

	AngleVectors(angles, forward, right, up);
	side = DotProduct(velocity, right);
	sign = side < 0 ? -1 : 1;
	side = fabs(side);

	value = cl_rollangle.value;

	if (side < cl_rollspeed.value)
		side = side * value / cl_rollspeed.value;
	else
		side = value;

	return side * sign;
}

/* view.c V_CalcBob, verbatim (statics fresh per process, like a boot) */
static float V_CalcBob(void)
{
	static double bobtime;
	static float bob;
	float cycle;

	if (cl.spectator)
		return 0;

	if (onground == -1)
		return bob; /* just use old value */

	bobtime += host_frametime;
	cycle = bobtime - (int)(bobtime / cl_bobcycle.value) * cl_bobcycle.value;
	cycle /= cl_bobcycle.value;
	if (cycle < cl_bobup.value)
		cycle = M_PI_Q * cycle / cl_bobup.value;
	else
		cycle = M_PI_Q + M_PI_Q * (cycle - cl_bobup.value) / (1.0 - cl_bobup.value);

	bob = sqrt(cl.simvel[0] * cl.simvel[0] + cl.simvel[1] * cl.simvel[1]) * cl_bob.value;
	bob = bob * 0.3 + bob * 0.7 * sin(cycle);
	if (bob > 4)
		bob = 4;
	else if (bob < -7)
		bob = -7;
	return bob;
}

/* mathlib.c anglemod + view.c angledelta, verbatim */
static float anglemod(float a)
{
	a = (360.0 / 65536) * ((int)(a * (65536 / 360.0)) & 65535);
	return a;
}
static float angledelta(float a)
{
	a = anglemod(a);
	if (a > 180)
		a -= 360;
	return a;
}

/* view.c CalcGunAngle, verbatim (the lag terms are identically zero, but
   run the real code anyway — that IS the point of a truth harness) */
static void CalcGunAngle(void)
{
	float yaw, pitch, move;
	static float oldyaw = 0;
	static float oldpitch = 0;

	yaw = r_refdef.viewangles[YAW];
	pitch = -r_refdef.viewangles[PITCH];

	yaw = angledelta(yaw - r_refdef.viewangles[YAW]) * 0.4;
	if (yaw > 10)
		yaw = 10;
	if (yaw < -10)
		yaw = -10;
	pitch = angledelta(-pitch - r_refdef.viewangles[PITCH]) * 0.4;
	if (pitch > 10)
		pitch = 10;
	if (pitch < -10)
		pitch = -10;
	move = host_frametime * 20;
	if (yaw > oldyaw) {
		if (oldyaw + move < yaw)
			yaw = oldyaw + move;
	} else {
		if (oldyaw - move > yaw)
			yaw = oldyaw - move;
	}
	if (pitch > oldpitch) {
		if (oldpitch + move < pitch)
			pitch = oldpitch + move;
	} else {
		if (oldpitch - move > pitch)
			pitch = oldpitch - move;
	}
	oldyaw = yaw;
	oldpitch = pitch;

	cl.viewent.angles[YAW] = r_refdef.viewangles[YAW] + yaw;
	cl.viewent.angles[PITCH] = -(r_refdef.viewangles[PITCH] + pitch);
}

/* view.c V_AddIdle, verbatim */
static void V_AddIdle(void)
{
	r_refdef.viewangles[ROLL] += v_idlescale.value * sin(cl.time * v_iroll_cycle.value) * v_iroll_level.value;
	r_refdef.viewangles[PITCH] += v_idlescale.value * sin(cl.time * v_ipitch_cycle.value) * v_ipitch_level.value;
	r_refdef.viewangles[YAW] += v_idlescale.value * sin(cl.time * v_iyaw_cycle.value) * v_iyaw_level.value;

	cl.viewent.angles[ROLL] -= v_idlescale.value * sin(cl.time * v_iroll_cycle.value) * v_iroll_level.value;
	cl.viewent.angles[PITCH] -= v_idlescale.value * sin(cl.time * v_ipitch_cycle.value) * v_ipitch_level.value;
	cl.viewent.angles[YAW] -= v_idlescale.value * sin(cl.time * v_iyaw_cycle.value) * v_iyaw_level.value;
}

/* view.c V_CalcViewRoll, verbatim */
static void V_CalcViewRoll(void)
{
	float side;

	side = V_CalcRoll(cl.simangles, cl.simvel);
	r_refdef.viewangles[ROLL] += side;

	if (v_dmg_time > 0) {
		r_refdef.viewangles[ROLL] += v_dmg_time / v_kicktime.value * v_dmg_roll;
		r_refdef.viewangles[PITCH] += v_dmg_time / v_kicktime.value * v_dmg_pitch;
		v_dmg_time -= host_frametime;
	}
}

/* view.c V_CalcRefdef, verbatim body (V_DriftPitch call excluded — see
   header; view->model precache swap replaced by a visible flag) */
static int gun_visible;
static void V_CalcRefdef(void)
{
	int i;
	vec3_t forward, right, up;
	float bob;
	static float oldz = 0;

	bob = V_CalcBob();

	VectorCopy(cl.simorg, r_refdef.vieworg);

	r_refdef.vieworg[2] += bob;

	r_refdef.vieworg[0] += 1.0 / 16;
	r_refdef.vieworg[1] += 1.0 / 16;
	r_refdef.vieworg[2] += 1.0 / 16;

	VectorCopy(cl.simangles, r_refdef.viewangles);
	V_CalcViewRoll();
	V_AddIdle();

	if (view_message->flags & PF_GIB)
		r_refdef.vieworg[2] += 8; /* gib view height */
	else if (view_message->flags & PF_DEAD)
		r_refdef.vieworg[2] -= 16; /* corpse view height */
	else
		r_refdef.vieworg[2] += 22; /* view height */

	if (view_message->flags & PF_DEAD) /* PF_GIB will also set PF_DEAD */
		r_refdef.viewangles[ROLL] = 80; /* dead view angle */

	AngleVectors(cl.simangles, forward, right, up);

	VectorCopy(cl.simangles, cl.viewent.angles);
	CalcGunAngle();
	VectorCopy(cl.simorg, cl.viewent.origin);
	cl.viewent.origin[2] += 22;

	for (i = 0; i < 3; i++)
		cl.viewent.origin[i] += forward[i] * bob * 0.4;
	cl.viewent.origin[2] += bob;

	if (scr_viewsize.value == 110)
		cl.viewent.origin[2] += 1;
	else if (scr_viewsize.value == 100)
		cl.viewent.origin[2] += 2;
	else if (scr_viewsize.value == 90)
		cl.viewent.origin[2] += 1;
	else if (scr_viewsize.value == 80)
		cl.viewent.origin[2] += 0.5;

	gun_visible = !(view_message->flags & (PF_GIB | PF_DEAD));
	cl.viewent.frame = view_message->weaponframe;

	r_refdef.viewangles[PITCH] += cl.punchangle;

	if ((view_message->onground != -1) && (cl.simorg[2] - oldz > 0)) {
		float steptime;

		steptime = host_frametime;

		oldz += steptime * 80;
		if (oldz > cl.simorg[2])
			oldz = cl.simorg[2];
		if (cl.simorg[2] - oldz > 12)
			oldz = cl.simorg[2] - 12;
		r_refdef.vieworg[2] += oldz - cl.simorg[2];
		cl.viewent.origin[2] += oldz - cl.simorg[2];
	} else
		oldz = cl.simorg[2];
}

/* view.c DropPunchAngle, verbatim */
static void DropPunchAngle(void)
{
	cl.punchangle -= 10 * host_frametime;
	if (cl.punchangle < 0)
		cl.punchangle = 0;
}

/* ==== the tape: mirrored EXACTLY in tests/test_view_truth.luau ==== */
/* dt = 1/64 (exactly representable); all inputs derived from the frame
   number with float-exact arithmetic so both sides feed identical bits. */
int main(void)
{
	int f;
	host_frametime = 1.0 / 64;
	for (f = 1; f <= 400; f++) {
		/* segment script */
		int seg_air = (f > 120 && f <= 160);
		int seg_dead = (f > 200 && f <= 230);
		int seg_gib = (f > 230 && f <= 260);
		int seg_spec = (f > 260 && f <= 300);

		cl.spectator = seg_spec;
		vmsg.flags = 0;
		if (seg_dead || seg_gib)
			vmsg.flags |= PF_DEAD;
		if (seg_gib)
			vmsg.flags |= PF_GIB;
		vmsg.onground = seg_air ? -1 : 0;
		vmsg.weaponframe = f % 7;
		onground = vmsg.onground;

		/* velocity: forward ramp, then strafe, then flight/decay */
		float vx = f * 4;
		if (vx > 320)
			vx = 320;
		float vy = (f > 80 && f <= 120) ? 200 : 0;
		float vz = 0;
		if (seg_air) {
			vz = 270 - (f - 120) * 800 / 64.0f;
		}
		if (seg_dead || seg_gib) {
			vx = 0;
			vy = 0;
		}
		if (seg_spec) {
			vx = 400;
			vy = 300;
			vz = 100;
		}
		cl.simvel[0] = vx;
		cl.simvel[1] = vy;
		cl.simvel[2] = vz;

		/* origin: x advances with vx; stairs +8 every 10 frames in
		   171..200; z otherwise 24 */
		cl.simorg[0] = f * 2;
		cl.simorg[1] = (f % 50) * 1;
		cl.simorg[2] = 24;
		if (f > 170 && f <= 200)
			cl.simorg[2] = 24 + ((f - 170) / 10 + 1) * 8;

		/* angles: integer-ish, float-exact */
		cl.simangles[PITCH] = ((f % 41) - 20) * 0.5f;
		cl.simangles[YAW] = (float)((f * 7) % 360);
		cl.simangles[ROLL] = 0;

		/* events */
		if (f == 161) { /* V_ParseDamage-shaped kick */
			v_dmg_time = v_kicktime.value;
			v_dmg_roll = 6;
			v_dmg_pitch = 4;
		}
		if (f == 165)
			cl.punchangle = 2; /* svc_smallkick magnitude, held sign-positive for visibility */

		cl.time += host_frametime;
		DropPunchAngle();
		V_CalcRefdef();

		printf("%d %.6f %.6f %.6f %.6f %.6f %.6f %.6f %.6f %.6f %.6f %.6f %.6f %d\n",
			f,
			r_refdef.vieworg[0], r_refdef.vieworg[1], r_refdef.vieworg[2],
			r_refdef.viewangles[0], r_refdef.viewangles[1], r_refdef.viewangles[2],
			cl.viewent.origin[0], cl.viewent.origin[1], cl.viewent.origin[2],
			cl.viewent.angles[0], cl.viewent.angles[1], cl.viewent.angles[2],
			gun_visible);
	}
	return 0;
}
