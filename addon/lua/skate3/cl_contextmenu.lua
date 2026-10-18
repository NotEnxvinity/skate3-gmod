-- The contextual menu, after Skate 3's D-pad menu: hold L1 (Shift on a
-- keyboard) and a small menu appears top left, hiding the score:
--
--   D-pad down   place the session marker
--   D-pad up     hold to go back to it
--   D-pad left   interact with something off the board (doors, buttons)
--   D-pad right  hold for the games list (a game of S.K.A.T.E. and the like)
--
-- Games and other modes plug in through S3GM_Menu: RegisterMode adds an entry
-- to the games list, OpenList shows a persistent list view (up and down pick,
-- right chooses, left goes back), and RegisterInteract supplies the "left"
-- action. Nothing here touches L1 itself: the simulation still reads it, so
-- mach 1 (jump, L1, land on the board) works as ever. The menu only opens
-- once L1 has been down a moment and the skater is on the ground, so the L1
-- of a mach 1 jump never flashes it up.

S3GM_Menu = S3GM_Menu or {}
local Menu = S3GM_Menu
local UI = S3GM_UI
local Marker = S3GM_Marker

local cv_menu = CreateClientConVar("skate3_menu", "1", true, false, "Hold L1 for the contextual menu (marker, interact, games)")

local UP, DOWN, LEFT, RIGHT, LB = 0x0001, 0x0002, 0x0004, 0x0008, 0x0100
local DPAD = bit.bor(UP, DOWN, LEFT, RIGHT)
local band, bor, bnot = bit.band, bit.bor, bit.bnot

local OPEN_AFTER = 0.2      -- L1 held this long before the menu shows
local GAMES_HOLD = 0.45     -- hold right this long for the games list
local REPEAT_FIRST, REPEAT_EVERY = 0.4, 0.12

local stack = {}            -- open list views, the top one shown
local lbSince               -- when L1 went down on the ground
local rootShown = false
local last = 0              -- last frame's buttons
local ignore = 0            -- D-pad directions held since a view opened; ignored until let go
local hold                  -- { bit, since } while up or right is held for its action
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
--   onPick = function(row, index), onBack = function() (optional) }.
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

-- Per frame, while skating. `buttons` is the pad's and keyboard's buttons as
-- the simulation reads them. Returns true when it just took the skater to
-- their marker (the ride restarted, so the caller stops there for the frame).
function Menu.Update(now, pose, buttons)
	local state = pose and pose.state or ""
	local onGround = pose and not state:find("Air") and not state:find("^Wipeout") and not state:find("^Grind")
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
		if band(freshly, RIGHT) ~= 0 and n > 0 then
			local row = list.rows[list.sel]
			if row.enabled ~= false and list.onPick then list.onPick(row, list.sel) end
		elseif band(freshly, LEFT) ~= 0 then
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

	-- Up and right are holds.
	local want = band(free, UP) ~= 0 and UP or band(free, RIGHT) ~= 0 and RIGHT or nil
	if want and (not hold or hold.bit ~= want) then hold = { bit = want, since = now } end
	if not want then hold = nil end
	if hold then
		local needed = hold.bit == UP and Marker.HoldTime() or GAMES_HOLD
		if not needed then
			hold.progress = 0
		else
			hold.progress = math.min((now - hold.since) / needed, 1)
			if hold.progress >= 1 then
				local bit_ = hold.bit
				hold = nil
				ignore = bor(ignore, bit_)
				if bit_ == UP then
					if Marker.GoTo() then return true end
				else
					OpenGames()
				end
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

function Looks.skate3.Box(x, y, w, h)
	UI.Rounded(6, x, y, w, h, Color(60, 78, 112, 175))
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

function UI.Arrow(name, cx, cy, size, color)
	local shape = ARROWS[name]
	if not shape then return end
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

-- A filled rounded rectangle on the canvas.
function UI.Rounded(radius, x, y, w, h, color)
	local s = UI.Scale()
	local X, Y = UI.P(x, y)
	draw.RoundedBox(radius * s, X, Y, w * s, h * s, color)
end

function UI.Rect(x, y, w, h, color, alpha)
	local X, Y = UI.P(x, y)
	local s = UI.Scale()
	surface.SetDrawColor(color.r, color.g, color.b, (color.a or 255) * alpha)
	surface.DrawRect(X, Y, w * s, h * s)
end

local function Rows(pose)
	local act = Interaction(pose)
	return {
		{ dir = "DPad_Up", label = "Go To Marker", enabled = Marker.Has(), bit = UP },
		{ dir = "DPad_Down", label = "Place Marker", enabled = true },
		{ dir = "DPad_Left", label = act and act.label or "Interact", enabled = act ~= nil },
		{ dir = "DPad_Right", label = "Games", enabled = #modes > 0, bit = RIGHT },
	}
end

local function DrawRoot(look, pose, style)
	local rows = Rows(pose)
	local widest = 0
	for _, r in ipairs(rows) do widest = math.max(widest, look.Width(r.label, 20)) end
	if style == "skate3" then
		look.Strip(#rows)
	else
		look.Strip(#rows, 80 + widest + 24)
	end
	for i, r in ipairs(rows) do
		local top = 54 + (i - 1) * PITCH
		local alpha = r.enabled and 1 or 0.3
		look.Icon(r.dir, 99, top, alpha)
		look.Text(r.label, 158, top + 11, 20, alpha)
		if hold and r.bit == hold.bit and hold.progress and hold.progress > 0 then
			UI.Rect(158, top + 36, math.max(look.Width(r.label, 20), 20) * hold.progress, 2, CREAM, 0.9)
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

	local width = math.max(look.Width(list.title or "", 20) + 40, 360)
	for i = first, last_ do
		local r = rows[i]
		width = math.max(width, 70 + look.Width(r.label or "", 20) + (r.tag and look.Width(r.tag, 20) + 50 or 0))
	end
	local x, y = 91, 48
	local height = 52 + math.max(shown, 1) * PITCH + 46
	look.Box(x, y, width, height)
	if list.title then look.Text(list.title, x + 20, y + 14, 20, 0.7) end
	UI.Rect(x + 16, y + 48, width - 32, 1, CREAM, 0.25)
	if n == 0 then look.Text(list.empty or "Nothing here yet", x + 20, y + 62, 20, 0.5) end
	for i = first, last_ do
		local r = rows[i]
		local top = y + 54 + (i - first) * PITCH
		local alpha = (r.enabled == false) and 0.3 or 1
		if i == list.sel then
			UI.Rounded(6, x + 8, top, width - 16, PITCH - 4, Color(255, 255, 255, 38))
			UI.Arrow("DPad_Right", x + 24, top + 17, 6, Color(243, 237, 210, 255))
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
		if r.tag then look.Right(r.tag, x + width - 20, top + 7, 20, alpha) end
	end
	look.Text("Up / Down  Select      Right  Choose      Left  Back", x + 20, y + height - 32, 16, 0.45)
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
