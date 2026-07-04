local t = require("../../tests/testutil")
local vfslib = require("../../src/shared/engine/common/vfs")
local bsplib = require("../../src/shared/engine/bsp/bsp")
local pmovelib = require("../../src/shared/engine/qw/pmove")
local fsys = t.gameFs()
local buf = vfslib.loadFile(fsys, "maps/e1m1.bsp")
local world = bsplib.load("maps/e1m1.bsp", buf :: buffer)[1]
local movevars = pmovelib.defaultMoveVars()
local pm = {
	origin = vector.create(480, -352, 88), angles = vector.zero, velocity = vector.zero,
	oldbuttons = 0, waterjumptime = 0, dead = false, spectator = false,
	physents = { { model = world, origin = vector.zero } },
	cmd = { angles = vector.zero, forwardmove = 0, sidemove = 0, upmove = 0, buttons = 0, msec = 50 },
	numtouch = 0, touchindex = {}, onground = -1, waterlevel = 0, watertype = -1,
}
for tick = 1, 5 do
	pm.cmd = { angles = vector.create(0, 90, 0), forwardmove = 400, sidemove = 0, upmove = 0, buttons = 0, msec = 50 }
	pmovelib.playerMove(pm :: any, movevars)
	print(("%d %.6f %.6f %.6f | %.6f %.6f %.6f | og=%d wl=%d"):format(tick,
		pm.origin.x, pm.origin.y, pm.origin.z, pm.velocity.x, pm.velocity.y, pm.velocity.z, pm.onground, pm.waterlevel))
end
