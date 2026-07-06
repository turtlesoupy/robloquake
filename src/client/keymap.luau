--!strict
-- keys.c name tables shared by both boots: Key_KeynumToString /
-- Key_StringToKeynum over Roblox KeyCodes (quake key names).

local keymap = {}

local KEYNAMES: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.Space] = "space",
	[Enum.KeyCode.Return] = "enter",
	[Enum.KeyCode.KeypadEnter] = "enter",
	[Enum.KeyCode.Tab] = "tab",
	[Enum.KeyCode.Backspace] = "backspace",
	[Enum.KeyCode.Up] = "uparrow",
	[Enum.KeyCode.Down] = "downarrow",
	[Enum.KeyCode.Left] = "leftarrow",
	[Enum.KeyCode.Right] = "rightarrow",
	[Enum.KeyCode.LeftControl] = "ctrl",
	[Enum.KeyCode.RightControl] = "ctrl",
	[Enum.KeyCode.LeftShift] = "shift",
	[Enum.KeyCode.RightShift] = "shift",
	[Enum.KeyCode.LeftAlt] = "alt",
	[Enum.KeyCode.RightAlt] = "alt",
	[Enum.KeyCode.Insert] = "ins",
	[Enum.KeyCode.Delete] = "del",
	[Enum.KeyCode.PageDown] = "pgdn",
	[Enum.KeyCode.PageUp] = "pgup",
	[Enum.KeyCode.Home] = "home",
	[Enum.KeyCode.End] = "end",
	[Enum.KeyCode.Pause] = "pause",
	[Enum.KeyCode.Semicolon] = "semicolon",
	[Enum.KeyCode.Comma] = ",",
	[Enum.KeyCode.Period] = ".",
	[Enum.KeyCode.Slash] = "/",
	[Enum.KeyCode.Backquote] = "`",
	[Enum.KeyCode.Minus] = "-",
	[Enum.KeyCode.Equals] = "=",
	[Enum.KeyCode.LeftBracket] = "[",
	[Enum.KeyCode.RightBracket] = "]",
	[Enum.KeyCode.BackSlash] = "\\",
	[Enum.KeyCode.Quote] = "'",
}
for i = 0, 25 do
	KEYNAMES[(Enum.KeyCode :: any)[string.char(65 + i)]] = string.char(97 + i)
end
do
	local names = { "Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine" }
	for i = 0, 9 do
		KEYNAMES[(Enum.KeyCode :: any)[names[i + 1]]] = tostring(i)
	end
end
for i = 1, 12 do
	KEYNAMES[(Enum.KeyCode :: any)["F" .. i]] = "f" .. i
end

keymap.KEYNAMES = KEYNAMES

-- Key_StringToKeynum
local CODES: { [string]: Enum.KeyCode } = {}
for code, name in KEYNAMES do
	if not CODES[name] then
		CODES[name] = code
	end
end
keymap.CODES = CODES

-- Key_KeynumToString
function keymap.keyName(code: Enum.KeyCode): string?
	return KEYNAMES[code]
end

return keymap
