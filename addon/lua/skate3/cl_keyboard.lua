-- Keyboard and mouse (early): turns keys and the mouse into the Xbox pad
-- Skate 3 reads, so the simulation gets exactly the inputs a controller would
-- send. WASD is the left stick (walk on foot, steer on the board), the mouse
-- is the right stick (pull back to crouch, flick forward to ollie), the mouse
-- buttons are the triggers (grabs). Only while skating: off the board every
-- key does what it normally does. A controller still works alongside it.

S3GM_Keyboard = S3GM_Keyboard or { active = false, buttons = 0 }
local Keyboard = S3GM_Keyboard

local cv_on = CreateClientConVar("skate3_keyboard", "1", true, false, "Skate with keyboard and mouse (early; a controller is still best)")
local cv_mouse = CreateClientConVar("skate3_kb_mouse", "1", true, false, "How far moving the mouse pushes the trick stick")
local cv_return = CreateClientConVar("skate3_kb_mouse_return", "0.15", true, false, "Seconds the trick stick takes to settle back to the middle")

-- XInput's button bits, as the native module uses them.
local A, B, X, Y = 0x1000, 0x2000, 0x4000, 0x8000
local LB, RB, R3 = 0x0100, 0x0200, 0x0080
local UP, DOWN, LEFT, RIGHT = 0x0001, 0x0002, 0x0004, 0x0008

-- Each bind is a convar holding a key code, so it can be changed in
-- Utilities > Skate 3 > Settings. `stick`: { axis, direction }; `trigger`:
-- 1 left, 2 right; `button`: a pad button bit.
Keyboard.BINDS = {
	{ name = "Forward", convar = "skate3_kb_forward", key = KEY_W, stick = { 2, 1 } },
	{ name = "Back", convar = "skate3_kb_back", key = KEY_S, stick = { 2, -1 } },
	{ name = "Left", convar = "skate3_kb_left", key = KEY_A, stick = { 1, -1 } },
	{ name = "Right", convar = "skate3_kb_right", key = KEY_D, stick = { 1, 1 } },
	{ name = "Push (A)", convar = "skate3_kb_push", key = KEY_SPACE, button = A },
	{ name = "Get on / off the board (Y)", convar = "skate3_kb_board", key = KEY_E, button = Y },
	{ name = "Left grab (left trigger)", convar = "skate3_kb_grab_left", key = MOUSE_LEFT, trigger = 1 },
	{ name = "Right grab (right trigger)", convar = "skate3_kb_grab_right", key = MOUSE_RIGHT, trigger = 2 },
	{ name = "L1", convar = "skate3_kb_l1", key = KEY_LSHIFT, button = LB },
	{ name = "R1", convar = "skate3_kb_r1", key = KEY_LCONTROL, button = RB },
	{ name = "X", convar = "skate3_kb_x", key = KEY_LALT, button = X },
	{ name = "B", convar = "skate3_kb_b", key = KEY_F, button = B },
	{ name = "Right stick click", convar = "skate3_kb_r3", key = MOUSE_MIDDLE, button = R3 },
	{ name = "D-pad down (gesture; marker with L1)", convar = "skate3_kb_marker", key = KEY_DOWN, button = DOWN },
	{ name = "D-pad up (gesture; back to marker with L1)", convar = "skate3_kb_return", key = KEY_UP, button = UP },
	{ name = "D-pad left", convar = "skate3_kb_dpad_left", key = KEY_LEFT, button = LEFT },
	{ name = "D-pad right", convar = "skate3_kb_dpad_right", key = KEY_RIGHT, button = RIGHT },
}
for _, b in ipairs(Keyboard.BINDS) do
	b.cv = CreateClientConVar(b.convar, tostring(b.key), true, false, "Keyboard skating: " .. b.name)
end
Keyboard.CONVARS = { "skate3_keyboard", "skate3_kb_mouse", "skate3_kb_mouse_return" }
for _, b in ipairs(Keyboard.BINDS) do Keyboard.CONVARS[#Keyboard.CONVARS + 1] = b.convar end

function Keyboard.Enabled()
	return cv_on:GetBool()
end

-- Taking over keys only makes sense while skating and not typing or in a menu.
local function Listening()
	if not Keyboard.active or not cv_on:GetBool() then return false end
	if vgui.CursorVisible() or gui.IsGameUIVisible() or gui.IsConsoleVisible() then return false end
	-- Dead (clicking or Space respawns) or not spawned in yet: hands off.
	local ply = LocalPlayer()
	return IsValid(ply) and ply:Alive() and not ply:IsTyping()
end

local function Down(b)
	local code = b.cv:GetInt()
	return code > 0 and input.IsButtonDown(code)
end

-- The trick stick: mouse movement pushes it, and it eases back to the middle
-- when the mouse stops, the way a thumbstick springs back.
local mouseX, mouseY = 0, 0
local trickX, trickY = 0, 0

hook.Add("InputMouseApply", "skate3_keyboard", function(cmd, x, y)
	if not Listening() then return end
	mouseX, mouseY = mouseX + x, mouseY + y
	-- The skate camera follows the skater, so the view doesn't need the mouse.
	cmd:SetMouseX(0)
	cmd:SetMouseY(0)
	return true
end)

-- This frame's buttons and { lx, ly, rx, ry, lt, rt } for skate3.Step.
function Keyboard.Read(dt)
	if not Listening() then
		mouseX, mouseY, trickX, trickY = 0, 0, 0, 0
		Keyboard.buttons = 0
		return 0, nil
	end
	local buttons = 0
	local stick = { 0, 0 }
	local triggers = { 0, 0 }
	for _, b in ipairs(Keyboard.BINDS) do
		if Down(b) then
			if b.button then buttons = bit.bor(buttons, b.button) end
			if b.stick then stick[b.stick[1]] = stick[b.stick[1]] + b.stick[2] end
			if b.trigger then triggers[b.trigger] = 1 end
		end
	end
	-- Diagonals reach the edge of the stick, not past it.
	local len = math.sqrt(stick[1] ^ 2 + stick[2] ^ 2)
	if len > 1 then stick[1], stick[2] = stick[1] / len, stick[2] / len end

	-- About a fifth of a typical flick reaches the stick's edge; pulling the
	-- mouse back is the stick pulled down.
	local scale = cv_mouse:GetFloat() / 60
	local settle = math.exp(-dt * 3 / math.max(cv_return:GetFloat(), 0.01))
	trickX = trickX * settle + mouseX * scale
	trickY = trickY * settle - mouseY * scale
	mouseX, mouseY = 0, 0
	local trick = math.sqrt(trickX ^ 2 + trickY ^ 2)
	if trick > 1 then trickX, trickY = trickX / trick, trickY / trick end

	Keyboard.buttons = buttons
	return buttons, { stick[1], stick[2], trickX, trickY, triggers[1], triggers[2] }
end

-- While skating, keys used here don't also run their normal binds (so the
-- left mouse button grabs instead of firing). Picking a weapon from the
-- weapon switcher with a click still works.
local choosingUntil = 0
hook.Add("PlayerBindPress", "skate3_keyboard", function(_, bind, pressed, code)
	if not Listening() or not code then return end
	if bind:find("^slot%d") or bind == "invnext" or bind == "invprev" or bind == "lastinv" then
		choosingUntil = RealTime() + 3
		return
	end
	if bind:find("^%+attack") and RealTime() < choosingUntil then
		choosingUntil = 0
		return
	end
	for _, b in ipairs(Keyboard.BINDS) do
		if b.cv:GetInt() == code then return true end
	end
end)

return Keyboard
