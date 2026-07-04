--!strict
-- NQ real-key input + menu battery (evidence:
-- docs/coverage/evidence/nq-input-menu-battery.txt). Not a lune test:
-- runs inside Roblox Studio. Keyboard steps use the Studio MCP
-- user_keyboard_input tool so REAL UserInputService events drive
-- Key_Event -> binds -> +commands -> CL_BaseMove -> CL_SendCmd; the
-- RQ_Force* attribute harness is deliberately NOT used here.
--
-- Procedure (NQ boot in Play, signed on — RQ_Signon == 4):
--  1. CLIENT execute: run measureMove() below, then send W keyDown /
--     wait 1000ms / keyUp via user_keyboard_input, then measureMove()
--     again — origin must advance ~200 u/s while held and stop after.
--  2. Same with Left arrow held 500ms: RQ_Yaw must advance ~70 degrees
--     (cl_yawspeed 140).
--  3. Bonus flash: run bonusProbe() — asserts the 50 -> 0 decay at
--     ~100/s after exec "bf" (V_BonusFlash_f as a console command).
--  4. Menu: key M, Down x3 (cursor on HELP/ORDERING -> capture),
--     Return (help page 1 of 6 -> capture), Right (page 2 -> capture),
--     M to close. Commit captures as nq-menu-cursor-help.jpg /
--     nq-help-page1.jpg / nq-help-page2.jpg.
-- Platform notes: number keys are CoreGUI-bound (VirtualInput refuses
-- them) — exercise IN_Impulse via console `impulse N`. Escape is
-- platform-reserved; the menu key is M.

local function measureMove(): string
	return string.format(
		"origin=%s yaw=%s",
		tostring(workspace:GetAttribute("RQ_Origin")),
		tostring(workspace:GetAttribute("RQ_Yaw"))
	)
end

local function bonusProbe(): string
	local con = workspace:FindFirstChild("RQDBG_Console") :: BindableFunction
	local RunService = game:GetService("RunService")
	con:Invoke("exec", "bf")
	local samples = {}
	local t0 = os.clock()
	for _ = 1, 90 do
		RunService.RenderStepped:Wait()
		local v = workspace:GetAttribute("RQ_CshiftBonus") :: number
		if v > 0 or #samples > 0 then
			table.insert(samples, string.format("%.2fs=%.1f", os.clock() - t0, v))
		end
		if #samples >= 12 then
			break
		end
	end
	return "bf decay: " .. (if #samples > 0 then table.concat(samples, " ") else "FAIL: never fired")
end

print(measureMove())
print(bonusProbe())
