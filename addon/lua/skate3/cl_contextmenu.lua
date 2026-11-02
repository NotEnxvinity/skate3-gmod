-- The contextual menu, laid out like Skate 2's phone and drawn in Skate 3's
-- own look: hold L1 (Shift on a keyboard) and a menu appears top left, hiding
-- the score:
--
--   L1 Menu           (the header)
--   D-pad up          hold to go back to the session marker
--   D-pad down        place the session marker
--   D-pad left        interact with something off the board (doors, buttons)
--   ------------
--   Y                 the games list (a game of S.K.A.T.E. and the like)
--   X                 settings
--
-- Games and other modes plug in through S3GM_Menu: RegisterMode adds an entry
-- to the games list, OpenList shows a persistent list view (up and down pick,
-- right chooses, left goes back; a settings list sets onAdjust so left and
-- right change the row's value and B goes back), and RegisterInteract supplies the "left"
-- action. Nothing here touches L1 itself: the simulation still reads it, so
-- mach 1 (jump, L1, land on the board) works as ever. The menu only opens
-- once L1 has been down a moment and the skater is on the ground, so the L1
-- of a mach 1 jump never flashes it up. While it is open X and Y belong to the
-- menu: Menu.Mask() is what the simulation must not see.

S3GM_Menu = S3GM_Menu or {}
local Menu = S3GM_Menu
local UI = S3GM_UI
local Marker = S3GM_Marker

local cv_menu = CreateClientConVar("skate3_menu", "1", true, false, "Hold L1 for the contextual menu (marker, interact, games, settings)")

local UP, DOWN, LEFT, RIGHT, LB = 0x0001, 0x0002, 0x0004, 0x0008, 0x0100
local BTN_X, BTN_Y, BTN_B = 0x4000, 0x8000, 0x2000
local DPAD = bit.bor(UP, DOWN, LEFT, RIGHT)
local band, bor, bnot = bit.band, bit.bor, bit.bnot

local OPEN_AFTER = 0.2      -- L1 held this long before the menu shows
local REPEAT_FIRST, REPEAT_EVERY = 0.4, 0.12

local stack = {}            -- open list views, the top one shown
local lbSince               -- when L1 went down on the ground
local rootShown = false
local last = 0              -- last frame's buttons
local ignore = 0            -- D-pad directions held since a view opened; ignored until let go
local hold                  -- { bit, since } while up is held to go back to the marker
local repeatAt              -- when a held up/down repeats next

local modes = {}            -- registered modes, for the games list
local interacts = {}        -- registered "left" actions

---------------------------------------------------------------------------
-- API for modes
---------------------------------------------------------------------------

-- A mode's entry in the games list. def = { id, label, order, tag (right-aligned
-- text), enabled = function() -> bool, open = function(menu) }. open runs when
-- the entry is chosen, and usually calls Menu.OpenList.
function Menu.RegisterMode(def)
	for i, m in ipairs(modes) do
		if m.id == def.id then table.remove(modes, i) break end
	end
	modes[#modes + 1] = def
	table.sort(modes, function(a, b) return (a.order or 100) < (b.order or 100) end)
end

function Menu.UnregisterMode(id)
	for i, m in ipairs(modes) do
		if m.id == id then table.remove(modes, i) return end
	end
end

-- What D-pad left does. fn(pose) returns nil (nothing to interact with) or
-- { label = "Open Door", run = function() ... end }; the first one that
-- answers wins.
function Menu.RegisterInteract(id, fn)
	interacts[id] = fn
end

-- Shows a persistent list view. list = {
--   title = "Games", rows = { { label, tag, model, enabled, ... }, ... },
--   refresh = function() -> rows (optional, run every frame, for live lists),
--   onPick = function(row, index), onBack = function() (optional),
--   onAdjust = function(row, direction) (optional: left/right change the
--   selected row's value, -1 or 1, and B goes back instead of left) }.
-- A row's `tag` is short text on its right (the letters "S K A"); `model` a
-- playermodel path whose icon shows on its left. Holds the D-pad as a latch
-- so the press that opened it doesn't also choose.
function Menu.OpenList(list)
	list.sel = math.max(1, list.sel or 1)
	stack[#stack + 1] = list
	ignore = band(last, DPAD)
end

-- A list view of buttons with a question as its title, such as "Play at your
-- marker or set a new one here?". options = { { label, run = function() } }.
function Menu.Prompt(question, options)
	Menu.OpenList({
		title = question,
		rows = options,
		onPick = function(row)
			Menu.Back()
			if row.run then row.run() end
		end,
	})
end

function Menu.Back()
	local top = table.remove(stack)
	if top and top.onBack then top.onBack() end
end

function Menu.Close()
	stack = {}
end

-- True while any of the menu is on screen (the score hides then).
function Menu.Visible()
	return rootShown or #stack > 0
end

-- True while a list view has the D-pad, even with L1 let go.
function Menu.HasList()
	return #stack > 0
end

-- The buttons the simulation must not see right now: X and Y while the menu
-- is up (Y would step off the board). Read before the frame's step, so it
-- goes by the menu as the last frame left it.
function Menu.Mask()
	if #stack > 0 then return bor(BTN_X, BTN_Y, BTN_B) end
	if rootShown then return bor(BTN_X, BTN_Y) end
	return 0
end

-- Starts over: the skater stopped skating.
function Menu.Reset()
	stack, lbSince, rootShown, hold, repeatAt, ignore = {}, nil, false, nil, nil, 0
end

---------------------------------------------------------------------------
-- The logic
---------------------------------------------------------------------------

local function Interaction(pose)
	for _, fn in pairs(interacts) do
		local ok, found = pcall(fn, pose)
		if ok and found then return found end
	end
end

local function GamesRows()
	local rows = {}
	for _, m in ipairs(modes) do
		local enabled = true
		if m.enabled then enabled = m.enabled() end
		rows[#rows + 1] = { label = m.label, tag = m.tag, enabled = enabled, mode = m }
	end
	return rows
end

local function OpenGames()
	if #modes == 0 then
		UI.Toast("No games to play yet")
		return
	end
	Menu.OpenList({
		title = "Games",
		rows = GamesRows(),
		refresh = GamesRows,
		onPick = function(row)
			if row.mode.open then row.mode.open(Menu) end
		end,
	})
end

local ONOFF = { { "On", "1" }, { "Off", "0" } }
-- The settings list: label, convar, the values it cycles through (shown, set).
local SETTINGS = {
	{ "Stance", "skate3_stance", { { "Regular", "regular" }, { "Goofy", "goofy" } }, note = "Stance applies the next time you get on" },
	{ "Camera", "skate3_camera", { { "Low", "low" }, { "Normal", "normal" }, { "High", "high" } } },
	{ "Volume", "skate3_volume", { { "0%", "0" }, { "25%", "0.25" }, { "50%", "0.5" }, { "75%", "0.75" }, { "100%", "1" } }, number = true },
	{ "Trick score", "skate3_score_hud", ONOFF },
	{ "Look", "skate3_ui_style", { { "Skate 3", "skate3" }, { "Minimal", "minimal" }, { "Half-Life 2", "hl2" } } },
	{ "Button pictures", "skate3_ui_glyphs", { { "Automatic", "auto" }, { "Xbox", "xbox" }, { "PlayStation", "playstation" } } },
	{ "Score beside the skater", "skate3_ui_world", ONOFF },
	{ "Hall of Meat", "skate3_hall_of_meat", ONOFF },
	{ "Punch and smack", "skate3_melee", ONOFF },
}

-- Which of a setting's values the convar is on (the nearest, for numbers).
local function ValueIndex(def, cv)
	local now = cv:GetString()
	local best, bestGap = 1, math.huge
	for i, v in ipairs(def[3]) do
		if v[2] == now then return i end
		if def.number then
			local gap = math.abs((tonumber(v[2]) or 0) - (tonumber(now) or 0))
			if gap < bestGap then best, bestGap = i, gap end
		end
	end
	return best
end

local function SettingsRows()
	local rows = {}
	for _, def in ipairs(SETTINGS) do
		local cv = GetConVar(def[2])
		if cv then
			rows[#rows + 1] = { label = def[1], tag = def[3][ValueIndex(def, cv)][1], def = def, cv = cv }
		end
	end
	return rows
end

local function OpenSettings()
	Menu.OpenList({
		title = "Settings",
		rows = SettingsRows(),
		refresh = SettingsRows,
		onAdjust = function(row, dir)
			local def = row.def
			local n = #def[3]
			local i = ValueIndex(def, row.cv) + dir
			if def.number then i = math.Clamp(i, 1, n) else i = (i - 1) % n + 1 end
			RunConsoleCommand(def[2], def[3][i][2])
			if def.note then UI.Toast(def.note) end
		end,
	})
end

-- Per frame, while skating. `buttons` is the pad's and keyboard's buttons as
-- the simulation reads them. Returns true when it just took the skater to
-- their marker (the ride restarted, so the caller stops there for the frame).
function Menu.Update(now, pose, buttons)
	local state = pose and pose.state or ""
	-- Up whenever the skater isn't in the air or on a grind, a bail's wipeout
	-- included (Hall of Meat's bail lasts a while, and the way back to the
	-- marker is wanted most then).
	local onGround = pose and not state:find("Air") and not state:find("^Grind")
	local down = band(buttons, LB) ~= 0
	if cv_menu:GetBool() and down and onGround then
		lbSince = lbSince or now
	else
		lbSince = nil
	end
	rootShown = lbSince ~= nil and now - lbSince >= OPEN_AFTER

	local pressed = band(buttons, bnot(last))
	last = buttons
	ignore = band(ignore, buttons)
	local free = band(buttons, bnot(ignore))
	local freshly = band(pressed, bnot(ignore))

	if #stack > 0 then
		local list = stack[#stack]
		if list.refresh then list.rows = list.refresh() end
		local n = #list.rows
		list.sel = n > 0 and math.Clamp(list.sel, 1, n) or 1
		local step = 0
		if band(freshly, UP) ~= 0 then step = -1 repeatAt = now + REPEAT_FIRST
		elseif band(freshly, DOWN) ~= 0 then step = 1 repeatAt = now + REPEAT_FIRST
		elseif repeatAt and now >= repeatAt and band(free, bor(UP, DOWN)) ~= 0 then
			step = band(free, UP) ~= 0 and -1 or 1
			repeatAt = now + REPEAT_EVERY
		elseif band(free, bor(UP, DOWN)) == 0 then
			repeatAt = nil
		end
		if step ~= 0 and n > 0 then list.sel = (list.sel - 1 + step) % n + 1 end
		if list.onAdjust then
			-- A settings list: the D-pad changes the value, B goes back.
			local dir = band(freshly, RIGHT) ~= 0 and 1 or band(freshly, LEFT) ~= 0 and -1 or 0
			if dir ~= 0 and n > 0 then
				local row = list.rows[list.sel]
				if row.enabled ~= false then list.onAdjust(row, dir) end
			elseif band(freshly, BTN_B) ~= 0 then
				Menu.Back()
			end
		elseif band(freshly, RIGHT) ~= 0 and n > 0 then
			local row = list.rows[list.sel]
			if row.enabled ~= false and list.onPick then list.onPick(row, list.sel) end
		elseif band(freshly, LEFT) ~= 0 or band(freshly, BTN_B) ~= 0 then
			Menu.Back()
		end
		hold = nil
		return false
	end

	if not rootShown then
		hold = nil
		return false
	end

	if band(freshly, DOWN) ~= 0 then Marker.SetHere() end
	if band(freshly, LEFT) ~= 0 then
		local act = Interaction(pose)
		if act then
			if act.run then act.run() end
		else
			UI.Toast("Nothing to interact with")
		end
	end
	if band(freshly, BTN_Y) ~= 0 then OpenGames() end
	if band(freshly, BTN_X) ~= 0 then OpenSettings() end

	-- Up is a hold, as long as the way back is far.
	local want = band(free, UP) ~= 0 and UP or nil
	if want and (not hold or hold.bit ~= want) then hold = { bit = want, since = now } end
	if not want then hold = nil end
	if hold then
		local needed = Marker.HoldTime()
		if not needed then
			hold.progress = 0
		else
			hold.progress = math.min((now - hold.since) / needed, 1)
			if hold.progress >= 1 then
				hold = nil
				ignore = bor(ignore, UP)
				if Marker.GoTo() then return true end
			end
		end
	end
	return false
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local CREAM = Color(243, 237, 210)
local PITCH = 38 -- canvas pixels between rows, as the game's menu has them

-- How each look draws the pieces. Everything is in canvas units; UI.P turns
-- those into screen pixels.
local Looks = {}

-- Skate 3's own: its panel and button icons, Futura text.
Looks.skate3 = {
	Text = function(text, x, y, h, alpha, color)
		UI.Futura(text, x, y, h, color or CREAM, alpha, TEXT_ALIGN_LEFT)
	end,
	Width = function(text, h) return UI.FuturaWidth(text, h) end,
	Right = function(text, x, y, h, alpha)
		UI.Futura(text, x, y, h, CREAM, alpha, TEXT_ALIGN_RIGHT)
	end,
}

local function MidQuad(q, k)
	local out = {}
	for i = 1, 4 do out[i] = { q[i][1], 80 + (q[i][2] - 80) * k, q[i][3], q[i][4] } end
	return out
end

-- Skate 3's panel stretched to `rows` rows of the game's three.
function Looks.skate3.Strip(rows)
	local p = UI.Art().panel
	local extra = (rows - 3) * PITCH
	local k = (71 + extra) / 71
	local a = 255 * p.opacity
	for _, piece in ipairs(p.top) do UI.Quad(piece.tex, piece.quad, 0, 0, 1, 255, 255, 255, a) end
	for _, piece in ipairs(p.mid) do UI.Quad(piece.tex, MidQuad(piece.quad, k), 0, 0, 1, 255, 255, 255, a) end
	for _, piece in ipairs(p.bottom) do UI.Quad(piece.tex, piece.quad, 0, extra, 1, 255, 255, 255, a) end
end

function Looks.skate3.Icon(name, x, y, alpha)
	UI.Button(name, x, y, 255, 255, 255, 255 * alpha)
end

-- Skate 3's phone panel as the whole backdrop: its corners as they are, its
-- middle stretched sideways (the centre column, since the art is mirrored
-- about it) and down, over (x, y, w, h).
function Looks.skate3.Box(x, y, w, h, alpha)
	local p = UI.Art().panel
	local extra, mid = math.max(w - 64, 0), math.max(h - 64, 2)
	local ky, down = mid / 71, mid - 71
	local ox, oy = x - 91, y - 48
	local a = 255 * p.opacity * (alpha or 1)
	local function Place(part)
		for _, piece in ipairs(p[part]) do
			local q, right = {}, piece.quad[1][1] >= 123
			for i = 1, 4 do
				local c = piece.quad[i]
				local py = c[2]
				if part == "mid" then py = 80 + (py - 80) * ky elseif part == "bottom" then py = py + down end
				q[i] = { c[1] + (right and extra or 0), py, c[3], c[4] }
			end
			UI.Quad(piece.tex, q, ox, oy, 1, 255, 255, 255, a)
			-- The stretch between the halves: the left half's centre edge held out.
			if extra > 0 and not right then
				local m = { q[2], { q[2][1] + extra, q[2][2], q[2][3], q[2][4] }, { q[3][1] + extra, q[3][2], q[3][3], q[3][4] }, q[3] }
				UI.Quad(piece.tex, m, ox, oy, 1, 255, 255, 255, a)
			end
		end
	end
	Place("top") Place("mid") Place("bottom")
end

-- The selected row: the game's neon selector, a soft highlight without it.
function Looks.skate3.Select(x, y, w, h, alpha)
	if UI.HasWeb() then
		UI.NineSlice("web_selector", x, y, w, h, 10, 255, 255, 255, 255 * alpha)
	else
		UI.Rounded(6, x, y, w, h, Color(255, 255, 255, 38 * alpha))
	end
end

-- A value's chevrons (the game's blue ones), `dir` -1 left or 1 right, centred at (cx, cy).
function Looks.skate3.Chevron(dir, cx, cy, alpha)
	if UI.HasWeb() then
		UI.Quad(dir < 0 and "web_prev" or "web_next", { { cx - 9, cy - 9, 0, 0 }, { cx + 9, cy - 9, 1, 0 }, { cx + 9, cy + 9, 1, 1 }, { cx - 9, cy + 9, 0, 1 } }, 0, 0, 1, 255, 255, 255, 255 * alpha)
	else
		UI.Arrow(dir < 0 and "DPad_Left" or "DPad_Right", cx, cy, 5, Color(243, 237, 210, 255 * alpha))
	end
end

-- The minimal look: Helvetica Neue Bold, a dark translucent strip.
local WHITE = Color(255, 255, 255)
Looks.minimal = {
	Text = function(text, x, y, h, alpha, color)
		local font = UI.Font(h * 1.15 * UI.Scale())
		local X, Y = UI.P(x, y + h / 2)
		draw.SimpleText(text, font, X + 1, Y + 1, Color(0, 0, 0, 170 * alpha), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		local c = color or WHITE
		draw.SimpleText(text, font, X, Y, Color(c.r, c.g, c.b, 255 * alpha), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end,
	Width = function(text, h)
		surface.SetFont(UI.Font(h * 1.15 * UI.Scale()))
		return (surface.GetTextSize(text)) / UI.Scale()
	end,
	Right = function(text, x, y, h, alpha)
		local font = UI.Font(h * 1.15 * UI.Scale())
		local X, Y = UI.P(x, y + h / 2)
		draw.SimpleText(text, font, X, Y, Color(255, 255, 255, 255 * alpha), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	end,
}

-- A D-pad arrow as a small filled triangle pointing the way, centred at (x, y).
local ARROWS = {
	DPad_Up = { { 0, -1 }, { 1, 0.8 }, { -1, 0.8 } },
	DPad_Down = { { 0, 1 }, { -1, -0.8 }, { 1, -0.8 } },
	DPad_Left = { { -1, 0 }, { 0.8, -1 }, { 0.8, 1 } },
	DPad_Right = { { 1, 0 }, { -0.8, 1 }, { -0.8, -1 } },
}

-- The flat looks name the buttons that aren't a D-pad arrow in letters.
local LETTERS = { L_Bumper = "L1", X = "X", Y = "Y" }

function UI.Arrow(name, cx, cy, size, color)
	local shape = ARROWS[name]
	if not shape then
		local letters = LETTERS[name]
		if letters then
			local X, Y = UI.P(cx, cy)
			draw.SimpleText(letters, UI.Font(15 * UI.Scale()), X, Y, color, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
		return
	end
	local poly = {}
	for i, p in ipairs(shape) do
		local x, y = UI.P(cx + p[1] * size, cy + p[2] * size)
		poly[i] = { x = x, y = y }
	end
	draw.NoTexture()
	surface.SetDrawColor(color)
	surface.DrawPoly(poly)
end

function Looks.minimal.Strip(rows, width)
	UI.Rounded(10, 91, 48, width, rows * PITCH + 21, Color(0, 0, 0, 120))
end

function Looks.minimal.Icon(name, x, y, alpha)
	UI.Arrow(name, x + 24, y + 24, 7, Color(255, 255, 255, 255 * alpha))
end

function Looks.minimal.Box(x, y, w, h)
	UI.Rounded(10, x, y, w, h, Color(0, 0, 0, 150))
end

-- Half-Life 2's: its yellow on a dim box.
local HL2_FG = Color(255, 220, 0)
Looks.hl2 = {
	Text = function(text, x, y, h, alpha)
		local X, Y = UI.P(x, y + h / 2)
		draw.SimpleText(text:upper(), "HudSelectionText", X, Y, Color(HL2_FG.r, HL2_FG.g, HL2_FG.b, 230 * alpha), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end,
	Width = function(text, h)
		surface.SetFont("HudSelectionText")
		return (surface.GetTextSize(text:upper())) / UI.Scale()
	end,
	Right = function(text, x, y, h, alpha)
		local X, Y = UI.P(x, y + h / 2)
		draw.SimpleText(text:upper(), "HudSelectionText", X, Y, Color(255, 220, 0, 230 * alpha), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	end,
}

function Looks.hl2.Strip(rows, width)
	UI.Rounded(8, 91, 48, width, rows * PITCH + 21, Color(0, 0, 0, 76))
end

function Looks.hl2.Icon(name, x, y, alpha)
	UI.Arrow(name, x + 24, y + 24, 7, Color(255, 220, 0, 230 * alpha))
end

function Looks.hl2.Box(x, y, w, h)
	UI.Rounded(8, x, y, w, h, Color(0, 0, 0, 76))
end

-- The root menu, top to bottom: a header, the D-pad rows, a divider and the
-- face-button rows.
local function Rows(pose)
	local act = Interaction(pose)
	return {
		{ kind = "header", icon = "L_Bumper", label = "Menu" },
		{ icon = "DPad_Up", label = "Go To Marker", enabled = Marker.Has(), bit = UP },
		{ icon = "DPad_Down", label = "Place Marker", enabled = true },
		{ icon = "DPad_Left", label = act and act.label or "Interact", enabled = act ~= nil },
		{ kind = "divider" },
		{ icon = "Y", label = "Games", enabled = #modes > 0 },
		{ icon = "X", label = "Settings", enabled = true },
	}
end

local GAP = 12 -- a divider's height, canvas units

local function DrawRoot(look, pose, style)
	local rows = Rows(pose)
	local widest, height = 0, 0
	for _, r in ipairs(rows) do
		if r.kind == "divider" then
			height = height + GAP
		else
			height = height + PITCH
			widest = math.max(widest, look.Width(r.label, 20))
		end
	end
	if style == "skate3" then
		look.Box(91, 48, 67 + widest + 30, height + 21)
	else
		look.Strip(height / PITCH, 80 + widest + 24)
	end
	local top = 54
	for _, r in ipairs(rows) do
		if r.kind == "divider" then
			top = top + GAP
		else
			local alpha = (r.enabled == false) and 0.3 or 1
			look.Icon(r.icon, 99, top, alpha)
			look.Text(r.label, 158, top + 11, 20, alpha)
			if hold and r.bit == hold.bit and hold.progress and hold.progress > 0 then
				UI.Rect(158, top + 36, math.max(look.Width(r.label, 20), 20) * hold.progress, 2, CREAM, 0.9)
			end
			top = top + PITCH
		end
	end
end

local MAX_ROWS = 8
local function DrawList(look, style)
	local list = stack[#stack]
	local rows = list.rows
	local n = #rows
	local first = math.Clamp(list.sel - math.floor(MAX_ROWS / 2), 1, math.max(1, n - MAX_ROWS + 1))
	local last_ = math.min(n, first + MAX_ROWS - 1)
	local shown = last_ - first + 1

	local hint = list.onAdjust and "Up / Down  Select      Left / Right  Change      B  Back"
		or "Up / Down  Select      Right  Choose      Left  Back"
	local width = math.max(look.Width(list.title or "", 20) + 40, look.Width(hint, 16) + 40, 360)
	for i = first, last_ do
		local r = rows[i]
		width = math.max(width, 70 + look.Width(r.label or "", 20) + (r.tag and look.Width(r.tag, 20) + (list.onAdjust and 90 or 50) or 0))
	end
	local x, y = 91, 48
	local height = 52 + math.max(shown, 1) * PITCH + 46
	look.Box(x, y, width, height)
	if list.title then look.Text(list.title, x + 20, y + 14, 20, 0.7) end
	if n == 0 then look.Text(list.empty or "Nothing here yet", x + 20, y + 62, 20, 0.5) end
	for i = first, last_ do
		local r = rows[i]
		local top = y + 54 + (i - first) * PITCH
		local alpha = (r.enabled == false) and 0.3 or 1
		if i == list.sel then
			if look.Select then
				look.Select(x + 6, top - 2, width - 12, PITCH, 1)
			else
				UI.Rounded(6, x + 8, top, width - 16, PITCH - 4, Color(255, 255, 255, 38))
				UI.Arrow("DPad_Right", x + 24, top + 17, 6, Color(243, 237, 210, 255))
			end
		end
		local labelX = x + 46
		if r.model then
			local icon = Material("spawnicons/" .. string.gsub(r.model, "%.mdl$", "") .. ".png")
			local X, Y = UI.P(labelX, top + 3)
			local sz = (PITCH - 10) * UI.Scale()
			if icon and not icon:IsError() then
				surface.SetMaterial(icon)
				surface.SetDrawColor(255, 255, 255, 255 * alpha)
				surface.DrawTexturedRect(X, Y, sz, sz)
			else
				draw.RoundedBox(sz / 2, X, Y, sz, sz, Color(255, 255, 255, 60 * alpha))
			end
			labelX = labelX + PITCH
		end
		look.Text(r.label or "", labelX, top + 7, 20, alpha)
		if r.tag and list.onAdjust then
			-- A setting: its value between arrows, lit on the chosen row.
			local lit = i == list.sel and 1 or 0.35
			local right = x + width - 20
			look.Right(r.tag, right - 26, top + 7, 20, alpha)
			if look.Chevron then
				-- The game's chevrons sit on the chosen row only.
				if i == list.sel then
					look.Chevron(1, right - 8, top + 17, 1)
					-- (An info row, the update line, has nothing to change back: only right opens its page.)
					if not r.info then look.Chevron(-1, right - 26 - look.Width(r.tag, 20) - 16, top + 17, 1) end
				end
			else
				UI.Arrow("DPad_Right", right - 8, top + 17, 5, Color(243, 237, 210, 255 * lit))
				UI.Arrow("DPad_Left", right - 26 - look.Width(r.tag, 20) - 16, top + 17, 5, Color(243, 237, 210, 255 * lit))
			end
		elseif r.tag then
			look.Right(r.tag, x + width - 20, top + 7, 20, alpha)
		end
	end
	look.Text(hint, x + 20, y + height - 32, 16, 0.45)
end

-- Draws whatever of the menu is up. Call from HUDPaint.
function Menu.Draw(pose)
	if not Menu.Visible() then return end
	local style = UI.Style()
	local look = Looks[style]
	UI.BeginTopLeft()
	if #stack > 0 then
		DrawList(look, style)
	else
		DrawRoot(look, pose, style)
	end
end

-- Doors and buttons, from the collision module (cl_interact.lua), when it's there.
Menu.RegisterInteract("doors", function()
	local api = S3GM_Interact
	if not api then return end
	local ent = api.Target()
	if not IsValid(ent) then return end
	return { label = "Interact", run = function() api.Use() end }
end)

return Menu
