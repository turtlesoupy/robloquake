--!strict
-- The Quake console — drop-down conback with conchars text, an input line,
-- history, and command execution (local commands, cvar-style settings, and
-- everything else forwarded to the server like Cmd_ForwardToServer).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local engine = ReplicatedStorage:WaitForChild("Shared").engine
local vfslib = require(engine.common.vfs)
local wadlib = require(engine.gfx.wad)
local com = require(engine.common.com)

local confont = require(script.Parent.render.confont)
local textures = require(script.Parent.render.textures)

local console = {}

local SCALE = 2
local COLS = 64
local ROWS = 25 -- visible rows including the input line

export type Console = {
	gui: Frame,
	font: confont.Font,
	rows: { confont.TextRow },
	lines: { string }, -- scrollback
	inputText: string,
	history: { string },
	historyPos: number,
	open: boolean,
	-- called with a full command line when the user presses return
	onCommand: (line: string) -> (),
	-- CompleteCommand (keys.c): Tab completes against these (command
	-- names first, then cvar names), set by the boot
	completions: { string },
	-- Con_DPrintf gate: the developer cvar
	developer: number,
	-- Con_NotifyBox: true while a boxed warning waits for its keypress
	awaitingKey: boolean,
	blinkTime: number,
	slide: number,
	lastTime: number,
}

function console.create(fs: vfslib.Vfs, pal: textures.Palette, parent: Instance): Console
	local gui = Instance.new("Frame")
	gui.Name = "QuakeConsole"
	gui.BackgroundTransparency = 1
	gui.AnchorPoint = Vector2.new(0.5, 0)
	gui.Position = UDim2.new(0.5, 0, 0, 0)
	gui.Size = UDim2.fromOffset(COLS * 8 * SCALE, (ROWS + 1) * 8 * SCALE + 16)
	gui.Visible = false
	gui.ZIndex = 20

	local wadbuf = vfslib.loadFile(fs, "gfx.wad")
	assert(wadbuf)
	local w = wadlib.load(wadbuf)
	local conchars = wadlib.getRaw(w, "conchars")

	-- conback background (Draw_ConsoleBackground) with the version string
	-- stamped into the pixels bottom-right (Con_Init's Draw_CharToConback)
	local backbuf = vfslib.loadFile(fs, "gfx/conback.lmp")
	if backbuf then
		local pic = wadlib.parseQPic(backbuf)
		local ver = "(robloquake) 1.09"
		local destX = pic.width - 11 - 8 * #ver
		local destY = 186
		for ci = 1, #ver do
			local code = ver:byte(ci)
			local row = code // 16
			local col = code % 16
			for y = 0, 7 do
				for x = 0, 7 do
					local px = buffer.readu8(conchars, (row * 8 + y) * 128 + col * 8 + x)
					if px ~= 0 then -- 0 is transparent in conchars
						buffer.writeu8(pic.pixels, (destY + y) * pic.width + destX + (ci - 1) * 8 + x, px)
					end
				end
			end
		end
		local img = textures.createImage(pic.pixels, pic.width, pic.height, pal, false)
		if img then
			local back = Instance.new("ImageLabel")
			back.BackgroundTransparency = 1
			back.ImageContent = Content.fromObject(img)
			back.ResampleMode = Enum.ResamplerMode.Pixelated
			back.Size = UDim2.new(1, 0, 1, 0)
			back.Parent = gui
		end
	end

	local c = {} :: Console
	c.gui = gui
	c.font = confont.new(conchars, pal)
	c.rows = {}
	for r = 1, ROWS do
		local holder = Instance.new("Frame")
		holder.BackgroundTransparency = 1
		holder.Position = UDim2.fromOffset(8, (r - 1) * 8 * SCALE + 8)
		holder.Size = UDim2.fromOffset(COLS * 8 * SCALE, 8 * SCALE)
		holder.Parent = gui
		c.rows[r] = confont.newRow(holder, COLS, SCALE)
	end
	c.lines = {}
	c.inputText = ""
	c.completions = {}
	c.developer = 0
	c.awaitingKey = false
	c.history = {}
	c.historyPos = 0
	c.open = false
	c.onCommand = function(_line: string) end
	c.blinkTime = 0
	c.slide = 0 -- scr_con_current in [0,1] of the console height
	c.lastTime = 0

	gui.Parent = parent
	return c
end

function console.print(c: Console, s: string)
	for line in s:gmatch("[^\n]+") do
		-- wrap long lines at the console width
		while #line > COLS do
			table.insert(c.lines, line:sub(1, COLS))
			line = line:sub(COLS + 1)
		end
		table.insert(c.lines, line)
	end
	while #c.lines > 200 do
		table.remove(c.lines, 1)
	end
end

-- Con_DPrintf: only prints when the developer cvar is set
function console.dprint(c: Console, text: string)
	if c.developer ~= 0 then
		console.print(c, text)
	end
end

-- Con_SafePrintf: C temporarily disables screen updates to print during
-- video re-init; a retained GUI has nothing to disable, so this is
-- Con_Printf with the guard collapsed
function console.safePrint(c: Console, text: string)
	console.print(c, text)
end

-- Con_NotifyBox: a boxed startup warning ("during startup for sound /
-- cd warnings") that raises the console and holds until a keypress
function console.notifyBox(c: Console, text: string)
	local bar = "\29" .. string.rep("\30", 36) .. "\31"
	console.print(c, "\n\n" .. bar)
	console.print(c, text)
	console.print(c, "Press a key.")
	console.print(c, bar)
	c.awaitingKey = true
	if not c.open then
		console.toggle(c)
	end
end

function console.toggle(c: Console)
	c.open = not c.open
	-- visibility follows the slide animation in update (scr_conspeed)
	UserInputService.MouseBehavior = if c.open then Enum.MouseBehavior.Default else Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = c.open
end

-- key handling while open; returns true if the key was consumed
function console.handleKey(c: Console, input: InputObject): boolean
	if not c.open then
		return false
	end
	-- Con_NotifyBox's key_count wait: any key dismisses the box and
	-- hands focus back to the game (key_dest = key_game)
	if c.awaitingKey then
		c.awaitingKey = false
		console.print(c, "")
		console.toggle(c)
		return true
	end
	local key = input.KeyCode

	if key == Enum.KeyCode.Return or key == Enum.KeyCode.KeypadEnter then
		local line = c.inputText
		console.print(c, "]" .. line)
		c.inputText = ""
		if line ~= "" then
			table.insert(c.history, line)
			c.historyPos = #c.history + 1
			-- Cbuf_Execute: semicolons separate commands on one line
			for cmd in line:gmatch("[^;]+") do
				cmd = cmd:match("^%s*(.-)%s*$")
				if cmd ~= "" then
					c.onCommand(cmd)
				end
			end
		end
	elseif key == Enum.KeyCode.Tab then
		-- CompleteCommand (keys.c): complete the partial into a full
		-- command; the C console puts a trailing space after the match
		local partial = c.inputText:match("^%s*(%S*)$")
		if partial and partial ~= "" then
			local match = com.completePrefix(c.completions, partial)
			if match then
				c.inputText = match .. " "
			end
		end
	elseif key == Enum.KeyCode.Backspace then
		c.inputText = c.inputText:sub(1, -2)
	elseif key == Enum.KeyCode.Up then
		if c.historyPos > 1 then
			c.historyPos -= 1
			c.inputText = c.history[c.historyPos] or ""
		end
	elseif key == Enum.KeyCode.Down then
		if c.historyPos <= #c.history then
			c.historyPos += 1
			c.inputText = c.history[c.historyPos] or ""
		end
	end
	return true
end

function console.handleText(c: Console, text: string)
	if not c.open then
		return
	end
	-- printable ASCII only; the tilde that opened us is filtered by caller
	for i = 1, #text do
		local b = text:byte(i)
		if b >= 32 and b < 127 then
			c.inputText ..= string.char(b)
		end
	end
end

function console.update(c: Console, time: number)
	-- SCR_SetUpToDrawConsole: slide at scr_conspeed (300 lines/sec on the
	-- 200-line virtual screen = 1.5 console-heights/sec here)
	local dt = math.clamp(time - c.lastTime, 0, 0.1)
	c.lastTime = time
	local target = if c.open then 1 else 0
	if c.slide < target then
		c.slide = math.min(c.slide + dt * 1.5, target)
	elseif c.slide > target then
		c.slide = math.max(c.slide - dt * 1.5, target)
	end
	local height = (ROWS + 1) * 8 * SCALE + 16
	c.gui.Visible = c.slide > 0
	c.gui.Position = UDim2.new(0.5, 0, 0, -height * (1 - c.slide))
	if not c.gui.Visible then
		return
	end
	-- scrollback fills rows 1..ROWS-1, input line at the bottom
	local textRows = ROWS - 1
	local start = math.max(0, #c.lines - textRows)
	for r = 1, textRows do
		confont.setRow(c.font, c.rows[r], c.lines[start + r] or "")
	end
	local cursor = if math.floor(time * 4) % 2 == 0 then string.char(11) else " "
	confont.setRow(c.font, c.rows[ROWS], "]" .. c.inputText .. cursor)
end

return console
