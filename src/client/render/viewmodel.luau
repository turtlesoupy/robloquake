--!strict
-- The view weapon renders through its OWN projection in GL-family
-- Quake (WebQuake R.js R_DrawViewModel: depthRange(0,0.3), vertical
-- fov = fov*0.82 regardless of window aspect, viewport = the vrect).
-- Roblox cameras cannot offset their projection center, so the gun
-- gets a real second camera: a ViewportFrame sized to the vrect (the
-- window minus the sbar strip) whose camera mirrors the world camera
-- with the gun fov. Drawing in a frame over the world is the
-- depthRange equivalent (the gun never clips into walls), and the
-- frame edge clips the gun at the strip top exactly like the C vrect.
--
-- Platform delta: ViewportFrame shading is Ambient-only — the gun is
-- already flat-lit via entrender.setLight, so Ambient is set to white
-- and the part color carries the R_DrawViewModel light level.

local viewmodel = {}

export type Vm = {
	gui: ScreenGui,
	frame: ViewportFrame,
	world: WorldModel,
	camera: Camera,
}

function viewmodel.new(parent: Instance): Vm
	local gui = Instance.new("ScreenGui")
	gui.Name = "QuakeViewmodel"
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 4 -- above the world, below cshift/HUD/console
	gui.ResetOnSpawn = false

	local frame = Instance.new("ViewportFrame")
	frame.BackgroundTransparency = 1
	-- silhouette edges antialias against BackgroundColor3 even when
	-- fully transparent (premultiplied compositing); the default gray
	-- rims the weapon with a visible halo — black kills the fringe
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BorderSizePixel = 0
	frame.Position = UDim2.new(0, 0, 0, 0)
	frame.Size = UDim2.new(1, 0, 1, 0)
	frame.Ambient = Color3.new(1, 1, 1)
	frame.LightColor = Color3.new(0, 0, 0)
	frame.Parent = gui

	local world = Instance.new("WorldModel")
	world.Parent = frame

	local camera = Instance.new("Camera")
	camera.Parent = frame
	frame.CurrentCamera = camera

	gui.Parent = parent
	return { gui = gui, frame = frame, world = world, camera = camera }
end

-- vrect layout: the frame covers the window above the sbar strip, and
-- the camera carries the gun projection (fov cvar * 0.82, vertical)
function viewmodel.setLayout(vm: Vm, fovCvar: number, stripPx: number)
	vm.frame.Size = UDim2.new(1, 0, 1, -stripPx)
	vm.camera.FieldOfView = math.clamp(fovCvar * 0.82, 1, 120)
end

-- mirror the world camera each frame: the gun is placed at its world
-- coordinates inside the frame's WorldModel, so identical view
-- geometry renders through the gun projection
function viewmodel.update(vm: Vm, worldCamera: Camera)
	vm.camera.CFrame = worldCamera.CFrame
end

return viewmodel
