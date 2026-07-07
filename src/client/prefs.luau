--!strict
-- Prefs bridge (PRODUCT layer): loads the player's persisted preferences
-- at boot — settings sliders + weapon skin picks — and pushes a debounced
-- full snapshot back whenever one changes. The boot wraps its settings
-- table and setWeaponSkin hook through attach() and hands the WRAPPED
-- versions to pausemenu/tweaksui, so the menus persist without knowing
-- about it. Server twin: src/server/prefstore.luau (see its REMOVAL note).

local prefs = {}

-- structurally identical to pausemenu.Settings (kept local so this module
-- doesn't require the menu it feeds)
export type Settings = {
	getSensitivity: () -> number,
	setSensitivity: (v: number) -> (),
	getInvertMouse: () -> boolean,
	setInvertMouse: (on: boolean) -> (),
	getAlwaysRun: () -> boolean,
	setAlwaysRun: (on: boolean) -> (),
	getVolume: () -> number,
	setVolume: (v: number) -> (),
}

export type Opts = {
	net: Instance,
	settings: Settings, -- raw setters: apply without persisting
	setWeaponSkin: (mdlName: string, spec: string?) -> (),
	validSpec: (spec: string) -> boolean, -- skinforge.parse gate on loaded specs
}

local PUSH_DEBOUNCE = 2 -- settle time before a changed snapshot is sent
local LOAD_TIMEOUT = 15 -- give up restoring after this (server may lack the store)

function prefs.attach(opts: Opts)
	local skins: { [string]: string } = {} -- mirror of every pick made/loaded
	local ready = false -- boot fetch finished (pushes hold until then)
	local pending = false

	local function snapshot()
		local s = opts.settings
		return {
			settings = {
				sensitivity = s.getSensitivity(),
				invertMouse = s.getInvertMouse(),
				alwaysRun = s.getAlwaysRun(),
				volume = s.getVolume(),
			},
			skins = skins,
		}
	end

	local function schedulePush()
		if pending then
			return
		end
		pending = true
		task.spawn(function()
			-- never push over the boot fetch: a snapshot sent before the
			-- saved skins are mirrored here would wipe them server-side
			while not ready do
				task.wait(0.2)
			end
			task.wait(PUSH_DEBOUNCE)
			pending = false
			local ev = opts.net:FindFirstChild("PrefsPush")
			if ev and ev:IsA("RemoteEvent") then
				ev:FireServer(snapshot())
			end
		end)
	end

	-- boot fetch: apply through the RAW setters (no push-back of values we
	-- just loaded), then open the push gate
	task.spawn(function()
		local rf = opts.net:WaitForChild("Prefs", LOAD_TIMEOUT)
		if rf and rf:IsA("RemoteFunction") then
			local ok, saved = pcall(function()
				return rf:InvokeServer()
			end)
			if ok and type(saved) == "table" then
				local s = (saved :: any).settings
				if type(s) == "table" then
					local raw = opts.settings
					if type(s.sensitivity) == "number" then
						raw.setSensitivity(math.clamp(s.sensitivity, 1, 11))
					end
					if type(s.invertMouse) == "boolean" then
						raw.setInvertMouse(s.invertMouse)
					end
					if type(s.alwaysRun) == "boolean" then
						raw.setAlwaysRun(s.alwaysRun)
					end
					if type(s.volume) == "number" then
						raw.setVolume(math.clamp(s.volume, 0, 1))
					end
				end
				local sk = (saved :: any).skins
				if type(sk) == "table" then
					for mdl, spec in sk do
						if type(mdl) == "string" and type(spec) == "string" and opts.validSpec(spec) then
							skins[mdl] = spec
							opts.setWeaponSkin(mdl, spec)
						end
					end
				end
			end
		end
		ready = true
	end)

	local raw = opts.settings
	local wrapped: Settings = {
		getSensitivity = raw.getSensitivity,
		setSensitivity = function(v: number)
			raw.setSensitivity(v)
			schedulePush()
		end,
		getInvertMouse = raw.getInvertMouse,
		setInvertMouse = function(on: boolean)
			raw.setInvertMouse(on)
			schedulePush()
		end,
		getAlwaysRun = raw.getAlwaysRun,
		setAlwaysRun = function(on: boolean)
			raw.setAlwaysRun(on)
			schedulePush()
		end,
		getVolume = raw.getVolume,
		setVolume = function(v: number)
			raw.setVolume(v)
			schedulePush()
		end,
	}

	return {
		settings = wrapped,
		setWeaponSkin = function(mdlName: string, spec: string?)
			skins[mdlName] = spec
			opts.setWeaponSkin(mdlName, spec)
			schedulePush()
		end,
		-- the mirror the menu reads to show the equipped skin (nil = authentic)
		getWeaponSkin = function(mdlName: string): string?
			return skins[mdlName]
		end,
	}
end

return prefs
