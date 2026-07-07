--!strict
-- Match director UI (PRODUCT layer, NOT engine): the map vote panel
-- (intermission), the callvote wire protocol + yes/no banner (proposals
-- are made from the pause menu's CALL A VOTE page, see handle.cv and
-- pausemenu.luau), and the admin match-control menu. Deliberately built with
-- plain Roblox UI (ScreenGui) so the Quake renderer/HUD/console are
-- untouched and this file can be deleted at any time (see the REMOVAL
-- note in src/server/director.luau). Touch-first sizing: every control
-- is a 44px+ target and the panels scale down to phone widths.

local UserInputService = game:GetService("UserInputService")

local directorui = {}

local ACCENT = Color3.fromRGB(255, 178, 60)
local BG = Color3.fromRGB(16, 16, 20)
local CARD = Color3.fromRGB(34, 34, 40)
local TEXT = Color3.fromRGB(235, 235, 235)
local DIM = Color3.fromRGB(150, 150, 155)

local function corner(inst: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
end

local function stroke(inst: Instance, color: Color3, transparency: number): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Transparency = transparency
	s.Thickness = 1
	s.Parent = inst
	return s
end

local function label(parent: Instance, text: string, size: number, color: Color3, bold: boolean): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = if bold then Enum.Font.GothamBold else Enum.Font.GothamMedium
	l.TextSize = size
	l.TextColor3 = color
	l.Text = text
	l.Parent = parent
	return l
end

export type Opts = {
	playerGui: Instance,
	net: Instance,
	isTyping: () -> boolean,
	-- fired when the admin menu opens/closes, and while the vote panel
	-- awaits the local player's pick, so the boot can free the mouse
	onUiToggle: ((open: boolean) -> ())?,
}

-- live match state for the pause menu's CALL A VOTE page
export type CvState = {
	map: string,
	maplist: string,
	-- file name -> human-readable level name (worldspawn "message"); only
	-- maps whose BSP resolved a title appear, so the page falls back to the
	-- raw name for the rest
	maptitles: { [string]: string },
	rules: { [string]: number },
	avatars: boolean,
}

export type Handle = {
	-- callvote bridge for the pause menu's CALL A VOTE page (the top-right
	-- MAP plaque / M, pausemenu.luau): getState feeds the page (nil until
	-- the Director remote resolves and sends state), propose fires the
	-- proposal, and the server answers cvBegin (yes/no banner here) or
	-- cvDeny. hooks are assigned by pausemenu to hear those verdicts.
	cv: {
		getState: () -> CvState?,
		propose: (key: string, value: any) -> (),
		hooks: { onDeny: ((reason: string) -> ())?, onBegin: (() -> ())? },
	},
}

function directorui.attach(opts: Opts): Handle
	local handle: Handle = {
		cv = {
			getState = function()
				return nil :: CvState?
			end,
			propose = function() end,
			hooks = {},
		},
	}
	task.spawn(function()
		local remote = opts.net:WaitForChild("Director", 30)
		if not remote or not remote:IsA("RemoteEvent") then
			return -- server-side director removed: UI stays dormant
		end
		local re = remote :: RemoteEvent

		local gui = Instance.new("ScreenGui")
		gui.Name = "QuakeDirector"
		gui.ResetOnSpawn = false
		gui.DisplayOrder = 30
		gui.IgnoreGuiInset = true
		gui.Parent = opts.playerGui

		local state: any = { isAdmin = false, rules = {}, maplist = "", map = "" }

		------------------------------------------------------------------
		-- vote panel (bottom center). It frees the cursor like a menu
		-- until the local player votes; the boot's single ui-open flag is
		-- shared with the admin menu, hence the forward-declared push.
		local voteCursorHeld = false
		local pushUiState = function() end -- real one defined with the menu
		local votePanel = Instance.new("Frame")
		votePanel.AnchorPoint = Vector2.new(0.5, 1)
		votePanel.Position = UDim2.new(0.5, 0, 1, -18)
		votePanel.Size = UDim2.new(0.6, 0, 0, 128)
		votePanel.BackgroundColor3 = BG
		votePanel.BackgroundTransparency = 0.12
		votePanel.Visible = false
		votePanel.Parent = gui
		corner(votePanel, 10)
		stroke(votePanel, Color3.new(1, 1, 1), 0.85)
		local voteSize = Instance.new("UISizeConstraint")
		voteSize.MinSize = Vector2.new(330, 128)
		voteSize.MaxSize = Vector2.new(640, 128)
		voteSize.Parent = votePanel

		local voteTitle = label(votePanel, "VOTE NEXT MAP", 13, DIM, true)
		voteTitle.Position = UDim2.new(0, 14, 0, 8)
		voteTitle.Size = UDim2.new(0.6, 0, 0, 16)
		voteTitle.TextXAlignment = Enum.TextXAlignment.Left

		local voteClock = label(votePanel, "", 13, DIM, false)
		voteClock.AnchorPoint = Vector2.new(1, 0)
		voteClock.Position = UDim2.new(1, -14, 0, 8)
		voteClock.Size = UDim2.new(0.3, 0, 0, 16)
		voteClock.TextXAlignment = Enum.TextXAlignment.Right

		local cardRow = Instance.new("Frame")
		cardRow.BackgroundTransparency = 1
		cardRow.Position = UDim2.new(0, 10, 0, 28)
		cardRow.Size = UDim2.new(1, -20, 0, 66)
		cardRow.Parent = votePanel
		local rowLayout = Instance.new("UIListLayout")
		rowLayout.FillDirection = Enum.FillDirection.Horizontal
		rowLayout.Padding = UDim.new(0, 8)
		rowLayout.Parent = cardRow

		local voteHint = label(votePanel, "press 1-3 to vote  ·  fire to continue", 12, DIM, false)
		voteHint.AnchorPoint = Vector2.new(0.5, 1)
		voteHint.Position = UDim2.new(0.5, 0, 1, -6)
		voteHint.Size = UDim2.new(1, -20, 0, 14)

		local voteCards: { { btn: TextButton, count: TextLabel, strokeObj: UIStroke } } = {}
		local voteMaps: { string } = {}
		local myVote: number? = nil
		local voteEndsAt = 0

		local function sendVote(i: number)
			if votePanel.Visible and voteMaps[i] then
				myVote = i
				for k, card in voteCards do
					card.strokeObj.Color = if k == i then ACCENT else Color3.new(1, 1, 1)
					card.strokeObj.Transparency = if k == i then 0.1 else 0.8
				end
				re:FireServer({ t = "vote", i = i })
				voteCursorHeld = false -- voted: hand mouse/movement back
				pushUiState()
			end
		end

		local function beginVote(maps: { string }, secondsLeft: number)
			voteMaps = maps
			myVote = nil
			voteEndsAt = os.clock() + secondsLeft
			for _, card in voteCards do
				card.btn:Destroy()
			end
			table.clear(voteCards)
			for i, name in maps do
				local btn = Instance.new("TextButton")
				btn.Size = UDim2.new(1 / #maps, -6, 1, 0)
				btn.BackgroundColor3 = CARD
				btn.Text = ""
				btn.AutoButtonColor = true
				btn.Parent = cardRow
				corner(btn, 8)
				local st = stroke(btn, Color3.new(1, 1, 1), 0.8)
				local key = label(btn, `[{i}]`, 12, DIM, false)
				key.Position = UDim2.new(0, 8, 0, 6)
				key.Size = UDim2.new(0, 30, 0, 14)
				key.TextXAlignment = Enum.TextXAlignment.Left
				local nm = label(btn, name:upper(), 20, TEXT, true)
				nm.Position = UDim2.new(0, 0, 0, 18)
				nm.Size = UDim2.new(1, 0, 0, 24)
				local ct = label(btn, "0 votes", 12, DIM, false)
				ct.Position = UDim2.new(0, 0, 1, -20)
				ct.Size = UDim2.new(1, 0, 0, 14)
				btn.Activated:Connect(function()
					sendVote(i)
				end)
				voteCards[i] = { btn = btn, count = ct, strokeObj = st }
			end
			votePanel.Visible = true
			voteCursorHeld = true
			pushUiState()
			task.spawn(function()
				while votePanel.Visible and os.clock() < voteEndsAt do
					voteClock.Text = `auto {math.max(0, math.ceil(voteEndsAt - os.clock()))}s`
					task.wait(0.25)
				end
			end)
		end

		------------------------------------------------------------------
		-- admin menu (right side) + gear button
		local gear = Instance.new("TextButton")
		gear.AnchorPoint = Vector2.new(1, 0)
		gear.Position = UDim2.new(1, -12, 0, 12)
		gear.Size = UDim2.fromOffset(44, 44)
		gear.BackgroundColor3 = BG
		gear.BackgroundTransparency = 0.25
		gear.Font = Enum.Font.GothamBold
		gear.TextSize = 22
		gear.TextColor3 = TEXT
		gear.Text = "\u{2699}"
		gear.Visible = false
		gear.Parent = gui
		corner(gear, 22)

		local menu = Instance.new("Frame")
		menu.AnchorPoint = Vector2.new(1, 0.5)
		menu.Position = UDim2.new(1, -12, 0.5, 0)
		menu.Size = UDim2.new(0, 360, 0.86, 0)
		menu.BackgroundColor3 = BG
		menu.BackgroundTransparency = 0.06
		menu.Visible = false
		menu.Parent = gui
		local refreshMenuRef: () -> () = function() end
	local reportLabelRef: TextLabel? = nil
	local rebuildPlayersRef = function() end
		-- the admin menu and the map-vote panel (while it awaits the local
		-- player's pick) share the mouse-freeing toggle: input stays
		-- UI-mode while either is open
		pushUiState = function()
			if opts.onUiToggle then
				opts.onUiToggle(menu.Visible or voteCursorHeld)
			end
		end
		local function setMenuVisible(open: boolean)
			if menu.Visible == open then
				return
			end
			menu.Visible = open
			if open then
				refreshMenuRef()
			end
			pushUiState()
		end
		corner(menu, 12)
		stroke(menu, Color3.new(1, 1, 1), 0.85)
		local menuSize = Instance.new("UISizeConstraint")
		menuSize.MaxSize = Vector2.new(360, 720)
		menuSize.MinSize = Vector2.new(300, 320)
		menuSize.Parent = menu

		local title = label(menu, "MATCH CONTROL", 16, ACCENT, true)
		title.Position = UDim2.new(0, 16, 0, 12)
		title.Size = UDim2.new(1, -70, 0, 20)
		title.TextXAlignment = Enum.TextXAlignment.Left

		local closeBtn = Instance.new("TextButton")
		closeBtn.AnchorPoint = Vector2.new(1, 0)
		closeBtn.Position = UDim2.new(1, -8, 0, 8)
		closeBtn.Size = UDim2.fromOffset(32, 32)
		closeBtn.BackgroundTransparency = 1
		closeBtn.Font = Enum.Font.GothamBold
		closeBtn.TextSize = 18
		closeBtn.TextColor3 = DIM
		closeBtn.Text = "X"
		closeBtn.Parent = menu

		local scroll = Instance.new("ScrollingFrame")
		scroll.Position = UDim2.new(0, 12, 0, 44)
		scroll.Size = UDim2.new(1, -24, 1, -56)
		scroll.BackgroundTransparency = 1
		scroll.BorderSizePixel = 0
		scroll.ScrollBarThickness = 4
		scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
		scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
		scroll.Parent = menu
		local list = Instance.new("UIListLayout")
		list.Padding = UDim.new(0, 8)
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Parent = scroll

		local order = 0
		local function section(text: string): TextLabel
			order += 1
			local l = label(scroll, text, 12, DIM, true)
			l.Size = UDim2.new(1, 0, 0, 16)
			l.TextXAlignment = Enum.TextXAlignment.Left
			l.LayoutOrder = order
			return l
		end

		local function button(parent: Instance, text: string): TextButton
			local b = Instance.new("TextButton")
			b.BackgroundColor3 = CARD
			b.Font = Enum.Font.GothamMedium
			b.TextSize = 14
			b.TextColor3 = TEXT
			b.Text = text
			b.AutoButtonColor = true
			b.Parent = parent
			corner(b, 8)
			return b
		end

		-- current map + restart
		section("MAP")
		local mapNow = label(scroll, "", 14, TEXT, true)
		mapNow.Size = UDim2.new(1, 0, 0, 18)
		mapNow.TextXAlignment = Enum.TextXAlignment.Left
		order += 1
		mapNow.LayoutOrder = order

		local mapGrid = Instance.new("Frame")
		mapGrid.BackgroundTransparency = 1
		mapGrid.Size = UDim2.new(1, 0, 0, 44)
		mapGrid.AutomaticSize = Enum.AutomaticSize.Y
		order += 1
		mapGrid.LayoutOrder = order
		mapGrid.Parent = scroll
		local grid = Instance.new("UIGridLayout")
		grid.CellSize = UDim2.new(1 / 3, -6, 0, 44)
		grid.CellPadding = UDim2.new(0, 6, 0, 6)
		grid.Parent = mapGrid

		local goRow = Instance.new("Frame")
		goRow.BackgroundTransparency = 1
		goRow.Size = UDim2.new(1, 0, 0, 44)
		order += 1
		goRow.LayoutOrder = order
		goRow.Parent = scroll
		local goBox = Instance.new("TextBox")
		goBox.PlaceholderText = "map name…"
		goBox.Font = Enum.Font.GothamMedium
		goBox.TextSize = 14
		goBox.TextColor3 = TEXT
		goBox.BackgroundColor3 = CARD
		goBox.Size = UDim2.new(1, -96, 1, 0)
		goBox.Text = ""
		goBox.ClearTextOnFocus = false
		goBox.Parent = goRow
		corner(goBox, 8)
		local goBtn = button(goRow, "LOAD")
		goBtn.AnchorPoint = Vector2.new(1, 0)
		goBtn.Position = UDim2.new(1, 0, 0, 0)
		goBtn.Size = UDim2.fromOffset(88, 44)
		goBtn.TextColor3 = ACCENT
		goBtn.Activated:Connect(function()
			local name = goBox.Text:match("^%s*([%w_%-]+)%s*$")
			if name then
				re:FireServer({ t = "map", value = name })
				goBox.Text = ""
			end
		end)

		-- rules steppers
		section("RULES  (applied live)")
		local RULES: { { key: string, step: number, max: number } } = {
			{ key = "fraglimit", step = 5, max = 200 },
			{ key = "timelimit", step = 5, max = 120 },
			{ key = "skill", step = 1, max = 3 },
			{ key = "deathmatch", step = 1, max = 2 },
			{ key = "teamplay", step = 1, max = 2 },
			{ key = "coop", step = 1, max = 1 },
			{ key = "samelevel", step = 1, max = 1 },
			{ key = "noexit", step = 1, max = 1 },
		}
		local ruleValueLabels: { [string]: TextLabel } = {}
		for _, r in RULES do
			local row = Instance.new("Frame")
			row.BackgroundColor3 = CARD
			row.BackgroundTransparency = 0.4
			row.Size = UDim2.new(1, 0, 0, 44)
			order += 1
			row.LayoutOrder = order
			row.Parent = scroll
			corner(row, 8)
			local nm = label(row, r.key, 14, TEXT, false)
			nm.Position = UDim2.new(0, 12, 0, 0)
			nm.Size = UDim2.new(1, -140, 1, 0)
			nm.TextXAlignment = Enum.TextXAlignment.Left
			local minus = button(row, "–")
			minus.Size = UDim2.fromOffset(40, 36)
			minus.AnchorPoint = Vector2.new(1, 0.5)
			minus.Position = UDim2.new(1, -92, 0.5, 0)
			local val = label(row, "0", 14, ACCENT, true)
			val.AnchorPoint = Vector2.new(1, 0.5)
			val.Position = UDim2.new(1, -48, 0.5, 0)
			val.Size = UDim2.fromOffset(40, 36)
			ruleValueLabels[r.key] = val
			local plus = button(row, "+")
			plus.Size = UDim2.fromOffset(40, 36)
			plus.AnchorPoint = Vector2.new(1, 0.5)
			plus.Position = UDim2.new(1, -4, 0.5, 0)
			local function bump(dir: number)
				local cur = tonumber(val.Text) or 0
				local nxt = math.clamp(cur + dir * r.step, 0, r.max)
				re:FireServer({ t = "set", key = r.key, value = nxt })
			end
			minus.Activated:Connect(function()
				bump(-1)
			end)
			plus.Activated:Connect(function()
				bump(1)
			end)
		end

		-- rotation
		section("ROTATION  (maplist)")
		local rotRow = Instance.new("Frame")
		rotRow.BackgroundTransparency = 1
		rotRow.Size = UDim2.new(1, 0, 0, 44)
		order += 1
		rotRow.LayoutOrder = order
		rotRow.Parent = scroll
		local rotBox = Instance.new("TextBox")
		rotBox.PlaceholderText = "dm3 dm4 dm6…"
		rotBox.Font = Enum.Font.GothamMedium
		rotBox.TextSize = 14
		rotBox.TextColor3 = TEXT
		rotBox.BackgroundColor3 = CARD
		rotBox.Size = UDim2.new(1, -96, 1, 0)
		rotBox.Text = ""
		rotBox.ClearTextOnFocus = false
		rotBox.Parent = rotRow
		corner(rotBox, 8)
		local rotBtn = button(rotRow, "APPLY")
		rotBtn.AnchorPoint = Vector2.new(1, 0)
		rotBtn.Position = UDim2.new(1, 0, 0, 0)
		rotBtn.Size = UDim2.fromOffset(88, 44)
		rotBtn.TextColor3 = ACCENT
		rotBtn.Activated:Connect(function()
			re:FireServer({ t = "maplist", value = rotBox.Text })
		end)

		-- host admin tools: Host_Status_f / Host_Ping_f / Host_Kick_f
		section("PLAYERS")
		local playersFrame = Instance.new("Frame")
		playersFrame.BackgroundTransparency = 1
		playersFrame.Size = UDim2.new(1, 0, 0, 0)
		playersFrame.AutomaticSize = Enum.AutomaticSize.Y
		order += 1
		playersFrame.LayoutOrder = order
		playersFrame.Parent = scroll
		local playersList = Instance.new("UIListLayout")
		playersList.Padding = UDim.new(0, 4)
		playersList.SortOrder = Enum.SortOrder.LayoutOrder
		playersList.Parent = playersFrame

		local reportRow = Instance.new("Frame")
		reportRow.BackgroundTransparency = 1
		reportRow.Size = UDim2.new(1, 0, 0, 44)
		order += 1
		reportRow.LayoutOrder = order
		reportRow.Parent = scroll
		local statusBtn = button(reportRow, "STATUS")
		statusBtn.Size = UDim2.new(0.5, -4, 1, 0)
		statusBtn.Activated:Connect(function()
			re:FireServer({ t = "admin", cmd = "status" })
		end)
		local pingBtn = button(reportRow, "PING")
		pingBtn.AnchorPoint = Vector2.new(1, 0)
		pingBtn.Position = UDim2.new(1, 0, 0, 0)
		pingBtn.Size = UDim2.new(0.5, -4, 1, 0)
		pingBtn.Activated:Connect(function()
			re:FireServer({ t = "admin", cmd = "ping" })
		end)

		local reportLabel = label(scroll, "", 12, DIM, false)
		reportLabel.Size = UDim2.new(1, 0, 0, 0)
		reportLabel.AutomaticSize = Enum.AutomaticSize.Y
		reportLabel.TextXAlignment = Enum.TextXAlignment.Left
		reportLabel.TextYAlignment = Enum.TextYAlignment.Top
		reportLabel.Font = Enum.Font.Code
		reportLabel.TextWrapped = true
		order += 1
		reportLabel.LayoutOrder = order
		reportLabelRef = reportLabel

		local function rebuildPlayers()
			for _, ch in playersFrame:GetChildren() do
				if ch:IsA("Frame") then
					ch:Destroy()
				end
			end
			local me = game:GetService("Players").LocalPlayer
			for i, plr in game:GetService("Players"):GetPlayers() do
				local row = Instance.new("Frame")
				row.BackgroundTransparency = 1
				row.Size = UDim2.new(1, 0, 0, 32)
				row.LayoutOrder = i
				row.Parent = playersFrame
				local nameLbl = label(row, plr.Name, 14, TEXT, true)
				nameLbl.Size = UDim2.new(1, -80, 1, 0)
				nameLbl.TextXAlignment = Enum.TextXAlignment.Left
				if plr ~= me then
					local kickBtn = button(row, "KICK")
					kickBtn.AnchorPoint = Vector2.new(1, 0)
					kickBtn.Position = UDim2.new(1, 0, 0, 0)
					kickBtn.Size = UDim2.fromOffset(72, 32)
					kickBtn.TextColor3 = Color3.fromRGB(255, 120, 120)
					kickBtn.Activated:Connect(function()
						re:FireServer({ t = "admin", cmd = "kick", arg = plr.Name })
					end)
				end
			end
		end
		rebuildPlayersRef = rebuildPlayers

		-- toggles + read-only footer
		section("OPTIONS")
		local avatarsBtn = button(scroll, "")
		avatarsBtn.Size = UDim2.new(1, 0, 0, 44)
		order += 1
		avatarsBtn.LayoutOrder = order
		avatarsBtn.Activated:Connect(function()
			re:FireServer({ t = "avatars", value = not (state.avatars == true) })
		end)

		local footer = label(scroll, "", 12, DIM, false)
		footer.Size = UDim2.new(1, 0, 0, 30)
		footer.TextXAlignment = Enum.TextXAlignment.Left
		footer.TextWrapped = true
		order += 1
		footer.LayoutOrder = order

		local function rebuildMapGrid()
			for _, ch in mapGrid:GetChildren() do
				if ch:IsA("TextButton") then
					ch:Destroy()
				end
			end
			for name in tostring(state.maplist):gmatch("%S+") do
				local b = button(mapGrid, name:upper())
				b.Activated:Connect(function()
					re:FireServer({ t = "map", value = name })
				end)
			end
		end

		local function refreshMenu()
			mapNow.Text = `current: {tostring(state.map):upper()}`
			for key, l in ruleValueLabels do
				l.Text = tostring(state.rules and state.rules[key] or 0)
			end
			if not rotBox:IsFocused() then
				rotBox.Text = tostring(state.maplist or "")
			end
			avatarsBtn.Text = `Roblox avatars:  {if state.avatars then "ON" else "OFF"}`
			avatarsBtn.TextColor3 = if state.avatars then ACCENT else TEXT
			local modText = if state.mod ~= "" and state.mod ~= nil then tostring(state.mod) else "—"
			footer.Text = `engine {tostring(state.engine)}  ·  game {tostring(state.game)}  ·  mod {modText}  (restart to change)`
			rebuildMapGrid()
		end

		refreshMenuRef = refreshMenu
		local oldRefresh = refreshMenu
		refreshMenu = function()
			oldRefresh()
			rebuildPlayersRef()
		end
		refreshMenuRef = refreshMenu
		gear.Activated:Connect(function()
			setMenuVisible(not menu.Visible)
		end)
		closeBtn.Activated:Connect(function()
			setMenuVisible(false)
		end)

		------------------------------------------------------------------
		-- callvote: proposals come from the pause menu's CALL A VOTE page
		-- via handle.cv; this file keeps the wire protocol + yes/no banner
		local gotState = false
		handle.cv.getState = function(): CvState?
			if not gotState then
				return nil
			end
			return {
				map = tostring(state.map),
				maplist = tostring(state.maplist),
				maptitles = (state.maptitles or {}) :: { [string]: string },
				rules = (state.rules or {}) :: { [string]: number },
				avatars = state.avatars == true,
			}
		end
		handle.cv.propose = function(key: string, value: any)
			re:FireServer({ t = "callvote", key = key, value = value })
		end

		-- active-vote banner (bottom center): F1 yes / F2 no
		local cvBanner = Instance.new("Frame")
		cvBanner.AnchorPoint = Vector2.new(0.5, 1)
		cvBanner.Position = UDim2.new(0.5, 0, 1, -160)
		cvBanner.Size = UDim2.new(0, 420, 0, 96)
		cvBanner.BackgroundColor3 = BG
		cvBanner.BackgroundTransparency = 0.12
		cvBanner.Visible = false
		cvBanner.Parent = gui
		corner(cvBanner, 10)
		stroke(cvBanner, Color3.new(1, 1, 1), 0.85)

		local cvBy = label(cvBanner, "", 12, DIM, false)
		cvBy.Position = UDim2.new(0, 14, 0, 8)
		cvBy.Size = UDim2.new(0.7, 0, 0, 14)
		cvBy.TextXAlignment = Enum.TextXAlignment.Left
		local cvClock = label(cvBanner, "", 12, DIM, false)
		cvClock.AnchorPoint = Vector2.new(1, 0)
		cvClock.Position = UDim2.new(1, -14, 0, 8)
		cvClock.Size = UDim2.new(0.3, 0, 0, 14)
		cvClock.TextXAlignment = Enum.TextXAlignment.Right
		local cvDesc = label(cvBanner, "", 18, TEXT, true)
		cvDesc.Position = UDim2.new(0, 14, 0, 24)
		cvDesc.Size = UDim2.new(1, -28, 0, 22)
		cvDesc.TextXAlignment = Enum.TextXAlignment.Left

		local cvDeadline = 0
		local yesBtn = button(cvBanner, "[F1]  YES  0")
		yesBtn.Position = UDim2.new(0, 14, 1, -40)
		yesBtn.Size = UDim2.new(0.5, -20, 0, 32)
		yesBtn.TextColor3 = Color3.fromRGB(140, 235, 140)
		local noBtn = button(cvBanner, "[F2]  NO  0")
		noBtn.AnchorPoint = Vector2.new(1, 0)
		noBtn.Position = UDim2.new(1, -14, 1, -40)
		noBtn.Size = UDim2.new(0.5, -20, 0, 32)
		noBtn.TextColor3 = Color3.fromRGB(255, 130, 130)

		local function castVote(v: boolean)
			if cvBanner.Visible then
				re:FireServer({ t = "castvote", v = v })
			end
		end
		yesBtn.Activated:Connect(function()
			castVote(true)
		end)
		noBtn.Activated:Connect(function()
			castVote(false)
		end)

		------------------------------------------------------------------
		-- wire protocol
		re.OnClientEvent:Connect(function(msg: any)
			if typeof(msg) ~= "table" then
				return
			end
			if msg.t == "state" then
				state = msg
				gotState = true
				gear.Visible = state.isAdmin == true
				if not state.isAdmin then
					setMenuVisible(false)
				end
				if menu.Visible then
					refreshMenu()
				end
			elseif msg.t == "report" then
				local rl = reportLabelRef
				if rl then
					rl.Text = tostring(msg.text or "")
				end
			elseif msg.t == "voteBegin" then
				beginVote(msg.maps or {}, tonumber(msg.secondsLeft) or 30)
			elseif msg.t == "voteCounts" then
				for i, card in voteCards do
					local n = (msg.counts or {})[i] or 0
					card.count.Text = `{n} vote{if n == 1 then "" else "s"}`
				end
			elseif msg.t == "voteEnd" then
				votePanel.Visible = false
				voteCursorHeld = false
				pushUiState()
			elseif msg.t == "cvBegin" then
				local began = handle.cv.hooks.onBegin
				if began then
					began() -- pausemenu closes its CALL A VOTE page
				end
				cvBy.Text = `{tostring(msg.by)} called a vote`
				cvDesc.Text = tostring(msg.desc):upper()
				yesBtn.Text = "[F1]  YES  0"
				noBtn.Text = "[F2]  NO  0"
				cvDeadline = os.clock() + (tonumber(msg.secondsLeft) or 30)
				cvBanner.Visible = true
				task.spawn(function()
					while cvBanner.Visible and os.clock() < cvDeadline do
						cvClock.Text = `{math.max(0, math.ceil(cvDeadline - os.clock()))}s`
						task.wait(0.25)
					end
				end)
			elseif msg.t == "cvCounts" then
				yesBtn.Text = `[F1]  YES  {tonumber(msg.yes) or 0}`
				noBtn.Text = `[F2]  NO  {tonumber(msg.no) or 0}`
			elseif msg.t == "cvEnd" then
				cvBanner.Visible = false
			elseif msg.t == "cvDeny" then
				local deny = handle.cv.hooks.onDeny
				if deny then
					deny(tostring(msg.reason or "vote denied"))
				end
			end
		end)

		UserInputService.InputBegan:Connect(function(input, gameProcessed)
			if gameProcessed or opts.isTyping() then
				return
			end
			if votePanel.Visible then
				if input.KeyCode == Enum.KeyCode.One then
					sendVote(1)
				elseif input.KeyCode == Enum.KeyCode.Two then
					sendVote(2)
				elseif input.KeyCode == Enum.KeyCode.Three then
					sendVote(3)
				end
			end
			if input.KeyCode == Enum.KeyCode.P and state.isAdmin then
				setMenuVisible(not menu.Visible)
			end
			-- classic callvote keys
			if cvBanner.Visible then
				if input.KeyCode == Enum.KeyCode.F1 then
					castVote(true)
				elseif input.KeyCode == Enum.KeyCode.F2 then
					castVote(false)
				end
			end
		end)

		re:FireServer({ t = "hello" })
	end)
	return handle
end

return directorui
