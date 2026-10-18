-- Which controller's button pictures the UI shows: Xbox (the game's own, from
-- the player's disc) or PlayStation (drawn here, so nothing of EA's is
-- needed). "auto" goes by the pad's name, "xbox" and "playstation" force one.
--
-- Everything asks for a button by its Xbox name (A, B, X, Y, L_Bumper,
-- DPad_Up ...) through S3GM_UI.Button, which switches to the PlayStation
-- picture (Cross, Circle, Square, Triangle, L1, R1 ...) when that's the set.

local UI = S3GM_UI

local cv_glyphs = CreateClientConVar("skate3_ui_glyphs", "auto", true, false,
	"Button pictures: auto (by the pad's name), xbox or playstation")

---------------------------------------------------------------------------
-- Which set
---------------------------------------------------------------------------

local padName

-- The pad the simulation is reading (its name from the native module), nil
-- for none.
function UI.SetPad(name)
	padName = name
end

-- Names PlayStation pads go by (evdev, XInput-less SDL and Windows). Steam
-- Input can present any pad as an Xbox one, which can't be told from here:
-- that's what the setting is for.
local PLAYSTATION = { "dualsense", "dualshock", "ds4", "ds5", "playstation", "sony", "wireless controller", "ps3", "ps4", "ps5" }

function UI.IsPlayStationPad(name)
	name = string.lower(name or "")
	for _, word in ipairs(PLAYSTATION) do
		if string.find(name, word, 1, true) then return true end
	end
	return false
end

-- "xbox" or "playstation".
function UI.GlyphSet()
	local want = cv_glyphs:GetString()
	if want == "xbox" or want == "playstation" then return want end
	return UI.IsPlayStationPad(padName) and "playstation" or "xbox"
end

---------------------------------------------------------------------------
-- Drawing the PlayStation set
---------------------------------------------------------------------------

local SYMBOL = {
	A = { shape = "cross", color = Color(124, 178, 232) },
	B = { shape = "circle", color = Color(255, 102, 102) },
	X = { shape = "square", color = Color(255, 105, 248) },
	Y = { shape = "triangle", color = Color(64, 226, 160) },
}
local LABEL = {
	L_Bumper = "L1", R_Bumper = "R1", L_Trigger = "L2", R_Trigger = "R2",
	L3_Click = "L3", R3_Click = "R3", Stick_Left = "L", Stick_Right = "R",
	Start = "OPTIONS", Back = "SHARE",
}
-- The D-pad arm each direction lights.
local ARM = { DPad_Up = { 0, -1 }, DPad_Down = { 0, 1 }, DPad_Left = { -1, 0 }, DPad_Right = { 1, 0 } }

-- DrawPoly wants its corners clockwise on screen, whichever way round they
-- were given.
local function Poly(points, r, g, b, a)
	local poly, area = {}, 0
	for i, p in ipairs(points) do
		local x, y = UI.P(p[1], p[2])
		poly[i] = { x = x, y = y }
	end
	for i, p in ipairs(poly) do
		local q = poly[i % #poly + 1]
		area = area + p.x * q.y - q.x * p.y
	end
	if area < 0 then
		for i = 1, #poly / 2 do poly[i], poly[#poly + 1 - i] = poly[#poly + 1 - i], poly[i] end
	end
	draw.NoTexture()
	surface.SetDrawColor(r, g, b, a)
	surface.DrawPoly(poly)
end

-- A line of width w between two canvas points.
local function Segment(x1, y1, x2, y2, w, color, a)
	local dx, dy = x2 - x1, y2 - y1
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 0.001 then return end
	local nx, ny = -dy / len * w / 2, dx / len * w / 2
	Poly({ { x1 + nx, y1 + ny }, { x2 + nx, y2 + ny }, { x2 - nx, y2 - ny }, { x1 - nx, y1 - ny } },
		color.r, color.g, color.b, a)
end

local function Ring(cx, cy, radius, w, color, a)
	local steps = 28
	for i = 0, steps - 1 do
		local a1, a2 = i / steps * math.pi * 2, (i + 1) / steps * math.pi * 2
		-- a hair of overlap so the joins don't show
		Segment(cx + math.cos(a1) * radius, cy + math.sin(a1) * radius,
			cx + math.cos(a2 + 0.03) * radius, cy + math.sin(a2 + 0.03) * radius, w, color, a)
	end
end

local function Disc(cx, cy, radius, r, g, b, a)
	local points = {}
	for i = 0, 23 do
		local t = i / 24 * math.pi * 2
		points[#points + 1] = { cx + math.cos(t) * radius, cy + math.sin(t) * radius }
	end
	Poly(points, r, g, b, a)
end

local function Rect(x, y, w, h, r, g, b, a)
	Poly({ { x, y }, { x + w, y }, { x + w, y + h }, { x, y + h } }, r, g, b, a)
end

local function Symbol(shape, cx, cy, color, a)
	local s, w = 11, 3.6
	if shape == "cross" then
		Segment(cx - s, cy - s, cx + s, cy + s, w, color, a)
		Segment(cx - s, cy + s, cx + s, cy - s, w, color, a)
	elseif shape == "circle" then
		Ring(cx, cy, s + 0.5, w, color, a)
	elseif shape == "square" then
		Segment(cx - s, cy - s, cx + s, cy - s, w, color, a)
		Segment(cx + s, cy - s, cx + s, cy + s, w, color, a)
		Segment(cx + s, cy + s, cx - s, cy + s, w, color, a)
		Segment(cx - s, cy + s, cx - s, cy - s, w, color, a)
	else
		local top, left, right = { cx, cy - s - 1 }, { cx - s - 1, cy + s - 1 }, { cx + s + 1, cy + s - 1 }
		Segment(top[1], top[2], left[1], left[2], w, color, a)
		Segment(left[1], left[2], right[1], right[2], w, color, a)
		Segment(right[1], right[2], top[1], top[2], w, color, a)
	end
end

-- A pill with text in it, centred at (cx, cy).
local function Pill(text, cx, cy, a)
	local font = UI.Font(14 * UI.Scale())
	surface.SetFont(font)
	local tw = surface.GetTextSize(text) / UI.Scale()
	local w, h = math.max(32, tw + 14), 24
	local X, Y = UI.P(cx - w / 2, cy - h / 2)
	local s = UI.Scale()
	draw.RoundedBox(h / 2 * s, X, Y, w * s, h * s, Color(24, 30, 46, 215 * a / 255))
	local tx, ty = UI.P(cx, cy)
	draw.SimpleText(text, font, tx, ty, Color(236, 240, 250, a), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

local function DPad(name, cx, cy, a)
	local arm = ARM[name]
	local grey, lit = Color(150, 158, 178), Color(255, 255, 255)
	local len, thick = 15, 12
	Rect(cx - thick / 2, cy - len, thick, len * 2, grey.r, grey.g, grey.b, a * 0.8)
	Rect(cx - len, cy - thick / 2, len * 2, thick, grey.r, grey.g, grey.b, a * 0.8)
	if arm then
		local ax, ay = cx + arm[1] * (len - 5), cy + arm[2] * (len - 5)
		local w, h = arm[1] ~= 0 and 10 or thick, arm[2] ~= 0 and 10 or thick
		Rect(ax - w / 2, ay - h / 2, w, h, lit.r, lit.g, lit.b, a)
	end
end

-- A PlayStation picture for an Xbox button name, centred at (cx, cy) on the
-- canvas. False if there isn't one.
function UI.PlayStationGlyph(name, cx, cy, a)
	local symbol = SYMBOL[name]
	if symbol then
		Disc(cx, cy, 17, 20, 26, 42, a * 0.78)
		Symbol(symbol.shape, cx, cy, symbol.color, a)
		return true
	end
	if ARM[name] or name == "DPad" then
		DPad(name, cx, cy, a)
		return true
	end
	if LABEL[name] then
		Pill(LABEL[name], cx, cy, a)
		return true
	end
	return false
end

-- A button of the game's own bank (A, B, X, Y, L_Bumper, DPad_Up ...) with
-- its 64x64 picture's top left at (x, y), or its PlayStation twin when that's
-- the set in use.
local xboxButton = UI.Button
function UI.Button(name, x, y, r, g, b, a)
	if UI.GlyphSet() == "playstation" and UI.PlayStationGlyph(name, x + 24, y + 22, a) then return end
	return xboxButton(name, x, y, r, g, b, a)
end
