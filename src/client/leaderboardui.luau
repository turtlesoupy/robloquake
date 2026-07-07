--!strict
-- Leaderboard UI (PRODUCT layer, NOT engine): daily/weekly/all-time
-- kill boards, per mode and global, served by the server's stats
-- pipeline (src/server/statstore.luau). Plain Roblox UI in the
-- directorui style; deletable at any time (see the REMOVAL note in
-- src/server/stats.luau). Toggle: L key or the trophy button.

local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local leaderboardui = {}

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
	onUiToggle: ((open: boolean) -> ())?,
}

local PERIODS = { { key = "day", text = "TODAY" }, { key = "week", text = "THIS WEEK" }, { key = "all", text = "ALL-TIME" } }
local SCOPES =
	{ { key = "mode", text = "THIS MODE" }, { key = "global", text = "GLOBAL" }, { key = "friends", text = "FRIENDS" } }

function leaderboardui.attach(opts: Opts)
	task.spawn(function()
		local remote = opts.net:WaitForChild("Leaderboards", 30)
		if not remote or not remote:IsA("RemoteFunction") then
			return -- server-side stats pipeline removed: UI stays dormant
		end
		local rf = remote :: RemoteFunction

		local gui = Instance.new("ScreenGui")
		gui.Name = "QuakeLeaderboards"
		gui.ResetOnSpawn = false
		gui.DisplayOrder = 28 -- under the director admin menu (30)
		gui.IgnoreGuiInset = true
		gui.Parent = opts.playerGui

		-- trophy button (below the director gear, visible to everyone)
		local trophy = Instance.new("TextButton")
		trophy.AnchorPoint = Vector2.new(1, 0)
		trophy.Position = UDim2.new(1, -12, 0, 64)
		trophy.Size = UDim2.fromOffset(44, 44)
		trophy.BackgroundColor3 = BG
		trophy.BackgroundTransparency = 0.25
		trophy.Font = Enum.Font.GothamBold
		trophy.TextSize = 20
		trophy.TextColor3 = TEXT
		trophy.Text = "\u{1F3C6}"
		trophy.Parent = gui
		corner(trophy, 22)

		local panel = Instance.new("Frame")
		panel.AnchorPoint = Vector2.new(0.5, 0.5)
		panel.Position = UDim2.new(0.5, 0, 0.5, 0)
		panel.Size = UDim2.new(0, 420, 0.8, 0)
		panel.BackgroundColor3 = BG
		panel.BackgroundTransparency = 0.06
		panel.Visible = false
		panel.Parent = gui
		corner(panel, 12)
		stroke(panel, Color3.new(1, 1, 1), 0.85)
		local sizeC = Instance.new("UISizeConstraint")
		sizeC.MaxSize = Vector2.new(420, 640)
		sizeC.MinSize = Vector2.new(320, 320)
		sizeC.Parent = panel

		local title = label(panel, "LEADERBOARDS", 16, ACCENT, true)
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
		closeBtn.Parent = panel

		-- tab rows
		local period = "day"
		local scope = "mode"
		local tabButtons: { { btn: TextButton, group: string, key: string } } = {}

		local function tabRow(y: number, group: string, defs: { { key: string, text: string } }): ()
			local row = Instance.new("Frame")
			row.BackgroundTransparency = 1
			row.Position = UDim2.new(0, 12, 0, y)
			row.Size = UDim2.new(1, -24, 0, 36)
			row.Parent = panel
			local layout = Instance.new("UIListLayout")
			layout.FillDirection = Enum.FillDirection.Horizontal
			layout.Padding = UDim.new(0, 6)
			layout.Parent = row
			for _, d in defs do
				local b = Instance.new("TextButton")
				b.Size = UDim2.new(1 / #defs, -6, 1, 0)
				b.BackgroundColor3 = CARD
				b.Font = Enum.Font.GothamMedium
				b.TextSize = 13
				b.TextColor3 = TEXT
				b.Text = d.text
				b.AutoButtonColor = true
				b.Parent = row
				corner(b, 8)
				table.insert(tabButtons, { btn = b, group = group, key = d.key })
			end
		end
		tabRow(44, "period", PERIODS)
		tabRow(86, "scope", SCOPES)

		local function paintTabs()
			for _, t in tabButtons do
				local active = (t.group == "period" and t.key == period) or (t.group == "scope" and t.key == scope)
				t.btn.TextColor3 = if active then ACCENT else TEXT
				t.btn.BackgroundColor3 = if active then Color3.fromRGB(48, 44, 34) else CARD
			end
		end

		-- rows
		local scroll = Instance.new("ScrollingFrame")
		scroll.Position = UDim2.new(0, 12, 0, 132)
		scroll.Size = UDim2.new(1, -24, 1, -176)
		scroll.BackgroundTransparency = 1
		scroll.BorderSizePixel = 0
		scroll.ScrollBarThickness = 4
		scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
		scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
		scroll.Parent = panel
		local list = Instance.new("UIListLayout")
		list.Padding = UDim.new(0, 4)
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Parent = scroll

		local footer = label(panel, "", 12, DIM, false)
		footer.AnchorPoint = Vector2.new(0.5, 1)
		footer.Position = UDim2.new(0.5, 0, 1, -10)
		footer.Size = UDim2.new(1, -24, 0, 28)
		footer.TextWrapped = true

		local function clearRows()
			for _, ch in scroll:GetChildren() do
				if ch:IsA("Frame") then
					ch:Destroy()
				end
			end
		end

		local function addRow(order: number, rank: string, name: string, value: string, mine: boolean)
			local row = Instance.new("Frame")
			row.BackgroundColor3 = CARD
			row.BackgroundTransparency = if mine then 0.15 else 0.5
			row.Size = UDim2.new(1, 0, 0, 30)
			row.LayoutOrder = order
			row.Parent = scroll
			corner(row, 6)
			if mine then
				stroke(row, ACCENT, 0.4)
			end
			local rk = label(row, rank, 13, if mine then ACCENT else DIM, true)
			rk.Position = UDim2.new(0, 10, 0, 0)
			rk.Size = UDim2.new(0, 34, 1, 0)
			rk.TextXAlignment = Enum.TextXAlignment.Left
			local nm = label(row, name, 13, TEXT, mine)
			nm.Position = UDim2.new(0, 48, 0, 0)
			nm.Size = UDim2.new(1, -120, 1, 0)
			nm.TextXAlignment = Enum.TextXAlignment.Left
			nm.TextTruncate = Enum.TextTruncate.AtEnd
			local vl = label(row, value, 13, if mine then ACCENT else TEXT, true)
			vl.AnchorPoint = Vector2.new(1, 0)
			vl.Position = UDim2.new(1, -10, 0, 0)
			vl.Size = UDim2.new(0, 60, 1, 0)
			vl.TextXAlignment = Enum.TextXAlignment.Right
		end

		local fetchGen = 0
		local lastInvoke = -math.huge
		local function refresh()
			fetchGen += 1
			local gen = fetchGen
			footer.Text = "loading…"
			clearRows()
			task.spawn(function()
				-- pace to the server's per-player fetch cooldown; a newer
				-- request during the wait supersedes this one via gen
				local wait = 2.1 - (os.clock() - lastInvoke)
				if wait > 0 then
					task.wait(wait)
				end
				if gen ~= fetchGen then
					return
				end
				lastInvoke = os.clock()
				local ok, res = pcall(function()
					return rf:InvokeServer({ period = period, scope = scope })
				end)
				-- a tab change mid-flight supersedes this response
				if gen ~= fetchGen then
					return
				end
				if not ok or typeof(res) ~= "table" then
					footer.Text = "leaderboards unavailable — try again in a moment"
					return
				end
				if res.disabled then
					footer.Text = "stats are off in this session (no DataStore access)"
					return
				end
				local me = Players.LocalPlayer
				local entries = res.entries or {}
				if #entries == 0 then
					footer.Text = if scope == "friends"
						then "none of your friends are on this board yet — invite them"
						else "no entries yet — go get some frags"
					return
				end
				clearRows()
				local mineShown = false
				for i, e in entries :: { { userId: number, name: string, value: number } } do
					local mine = e.userId == me.UserId
					mineShown = mineShown or mine
					addRow(i, `#{i}`, e.name, tostring(e.value), mine)
				end
				footer.Text = if mineShown
					then `kills · {#entries} ranked`
					else `kills · {#entries} ranked · you're not on this board yet`
			end)
		end

		local open = false
		local function setOpen(o: boolean)
			if open == o then
				return
			end
			open = o
			panel.Visible = o
			if o then
				paintTabs()
				refresh()
			end
			if opts.onUiToggle then
				opts.onUiToggle(o)
			end
		end

		for _, t in tabButtons do
			t.btn.Activated:Connect(function()
				if t.group == "period" then
					period = t.key
				else
					scope = t.key
				end
				paintTabs()
				refresh()
			end)
		end

		trophy.Activated:Connect(function()
			setOpen(not open)
		end)
		closeBtn.Activated:Connect(function()
			setOpen(false)
		end)

		UserInputService.InputBegan:Connect(function(input, gameProcessed)
			if gameProcessed or opts.isTyping() then
				return
			end
			if input.KeyCode == Enum.KeyCode.L then
				setOpen(not open)
			end
		end)
	end)
end

return leaderboardui
