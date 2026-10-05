-- The trick score widget, after Skate 3's: a ring with the combo multiplier
-- inside and the line timer running down around it, the line's score beside
-- it, and the latest trick's name. When a line ends, what it was worth (or
-- that it was lost to a bail) shows for a moment. Three looks: that widget on
-- screen, the same floating in the world beside the skater, or Half-Life 2's
-- HUD panels.

local Score = {}

local cv_score = CreateClientConVar("skate3_score_hud", "1", true, false, "Show the trick score widget")
local cv_style = CreateClientConVar("skate3_score_style", "minimal", true, false,
	"Trick score look: minimal (on screen), world (beside the skater) or hl2")

-- How long a finished line stays on screen, and how long it fades.
local HOLD = 2.5
local FADE = 0.5

local WHITE = Color(255, 255, 255)
local GREEN = Color(130, 255, 150)
local RED = Color(255, 90, 80)
local RING = Color(255, 255, 255)
local RING_EMPTY = Color(255, 255, 255, 50)
local DISC = Color(0, 0, 0, 150)

local fontsFor
local function Fonts()
	local h = ScrH()
	if fontsFor == h then return end
	fontsFor = h
	local s = h / 1080
	surface.CreateFont("skate3_mult", { font = "Roboto", size = math.Round(30 * s), weight = 900, italic = true })
	surface.CreateFont("skate3_points", { font = "Roboto", size = math.Round(36 * s), weight = 800, italic = true })
	surface.CreateFont("skate3_trick", { font = "Roboto", size = math.Round(22 * s), weight = 700 })
end

-- The engine names tricks by localisation ID, such as
-- ID_TRICK_FLIP_NOLLIE_KICKFLIP, sometimes several with numbers between
-- ("ID_TRICK_AUTHENTIC_FS_CAB 360"). Setup copies the game's own names off the
-- disc into data/skate3/tricks.json; without them the IDs are spelled out.
-- Category words that lead an ID: ID_TRICK_FLIP_360_FLIP is a "360 Flip".
local CATEGORY = { TRICK = true, GROUND = true, AIR = true, GRIND = true, FLIP = true, GRAB = true,
	AUTHENTIC = true, METRICS = true }
local known
local function Known()
	if known then return known end
	local json = file.Read("skate3/tricks.json", "DATA")
	known = json and util.JSONToTable(json) or {}
	return known
end

local function SpellOut(id)
	local words = {}
	for word in id:gsub("^ID_", ""):gmatch("[^_]+") do words[#words + 1] = word end
	while #words > 1 and CATEGORY[words[1]] do table.remove(words, 1) end
	for i, word in ipairs(words) do
		if #word > 2 and not word:find("%d") then
			words[i] = word:sub(1, 1) .. word:sub(2):lower()
		end
	end
	return table.concat(words, " ")
end

local names = {}
local function TrickName(label)
	if label == "" then return "" end
	local name = names[label]
	if name then return name end
	if label:sub(1, 1) == "#" then
		name = label:sub(2)
	else
		local parts = {}
		for part in label:gmatch("%S+") do
			parts[#parts + 1] = Known()[part] or (part:find("^ID_") and SpellOut(part)) or part
		end
		name = table.concat(parts, " ")
	end
	names[label] = name
	return name
end

local function Points(n)
	return string.Comma(math.floor(n + 0.5))
end

local function Multiplier(m)
	return (m == math.floor(m) and "%dx" or "%.1fx"):format(m)
end

-- A ring from the top, clockwise, `frac` of the way round.
local function Arc(cx, cy, inner, outer, frac, color)
	if frac <= 0 then return end
	local segments = math.max(2, math.ceil(48 * frac))
	surface.SetDrawColor(color)
	draw.NoTexture()
	local step = frac * math.pi * 2 / segments
	for i = 0, segments - 1 do
		local a0, a1 = -math.pi / 2 + i * step, -math.pi / 2 + (i + 1) * step
		local c0, s0, c1, s1 = math.cos(a0), math.sin(a0), math.cos(a1), math.sin(a1)
		surface.DrawPoly({
			{ x = cx + c0 * outer, y = cy + s0 * outer },
			{ x = cx + c1 * outer, y = cy + s1 * outer },
			{ x = cx + c1 * inner, y = cy + s1 * inner },
			{ x = cx + c0 * inner, y = cy + s0 * inner },
		})
	end
end

local function Disc(cx, cy, r, color)
	local poly = {}
	for i = 0, 31 do
		local a = i / 32 * math.pi * 2
		poly[#poly + 1] = { x = cx + math.cos(a) * r, y = cy + math.sin(a) * r }
	end
	surface.SetDrawColor(color)
	draw.NoTexture()
	surface.DrawPoly(poly)
end

local function Shadowed(text, font, x, y, color, alpha, align)
	draw.SimpleText(text, font, x + 2, y + 2, Color(0, 0, 0, 180 * alpha), align, TEXT_ALIGN_CENTER)
	draw.SimpleText(text, font, x, y, ColorAlpha(color, color.a * alpha), align, TEXT_ALIGN_CENTER)
end

local last -- the score last frame
local flash -- { text, color, at }
local shown = 0 -- what the widget showed last, kept while it fades
local lastTrick = ""
local seenAt = -math.huge -- when the widget last had something live to show
local view -- what to draw this frame, or nil

-- Works out this frame's view from the engine's score.
local function Update(pose)
	view = nil
	if not cv_score:GetBool() or not pose or not pose.score then return end
	local sc = pose.score
	local now = RealTime()
	local bailing = pose.state and pose.state:find("^Wipeout") ~= nil

	if last then
		if sc.banked > last.banked + 0.5 then
			flash = { text = "+" .. Points(sc.banked - last.banked), good = true, at = now }
		elseif last.active and not sc.active then
			if bailing then
				flash = { text = "Bail", good = false, at = now }
			elseif sc.line <= last.line + 0.5 and last.sequence > 0.5 then
				-- A trick on its own, not part of a line: it scores but never banks.
				flash = { text = "+" .. Points(last.sequence), good = true, at = now }
			end
		end
	end
	last = { banked = sc.banked, active = sc.active, sequence = sc.sequence, line = sc.line }

	local live = sc.active or sc.timer > 0
	if live then
		seenAt = now
		shown = sc.line + (sc.active and sc.sequence or 0)
		if sc.trick ~= "" then lastTrick = sc.trick end
	end
	local age = now - math.max(seenAt, flash and flash.at or -math.huge)
	local alpha = math.Clamp((HOLD + FADE - age) / FADE, 0, 1)
	if alpha <= 0 then
		flash = nil
		return
	end
	local showFlash = flash and not live
	view = {
		alpha = alpha,
		live = live,
		timer = live and sc.timer or 0,
		multiplier = live and sc.multiplier or 1,
		points = showFlash and flash.text or Points(shown),
		good = not showFlash or flash.good,
		trick = TrickName(lastTrick),
	}
end

-- The Skate 3 widget with its ring centred on cx, cy, at scale s.
local function Minimal(v, cx, cy, s)
	Fonts()
	local alpha = v.alpha
	local r = 34 * s
	Disc(cx, cy, r, ColorAlpha(DISC, DISC.a * alpha))
	Arc(cx, cy, r - 5 * s, r, 1, ColorAlpha(RING_EMPTY, RING_EMPTY.a * alpha))
	Arc(cx, cy, r - 5 * s, r, v.timer, ColorAlpha(RING, RING.a * alpha))
	Shadowed(Multiplier(v.multiplier), "skate3_mult", cx, cy, WHITE, alpha, TEXT_ALIGN_CENTER)
	local x = cx + r + 14 * s
	local color = v.live and WHITE or (v.good and GREEN or RED)
	Shadowed(v.points, "skate3_points", x, cy - 8 * s, color, alpha, TEXT_ALIGN_LEFT)
	Shadowed(v.trick, "skate3_trick", x, cy + 20 * s, WHITE, alpha, TEXT_ALIGN_LEFT)
end

-- Half-Life 2's HUD: a dim rounded panel with the yellow label and numbers,
-- the line timer as the aux power bar's segments.
local HL2_FG = Color(255, 220, 0, 230)
local HL2_DIM = Color(255, 220, 0, 50)
local HL2_RED = Color(255, 0, 0, 230)
local HL2_BG = Color(0, 0, 0, 76)
local SEGMENTS = 10

local function HL2(v)
	local a = v.alpha
	local s = ScrH() / 480
	local fg = v.good and HL2_FG or HL2_RED
	local mult = Multiplier(v.multiplier)
	surface.SetFont("HudNumbers")
	local numW = surface.GetTextSize(v.points)
	surface.SetFont("HudNumbersSmall")
	local multW = surface.GetTextSize(mult)
	surface.SetFont("HudSelectionText")
	local trickW = surface.GetTextSize(v.trick:upper())
	local pad = 8 * s
	local w = math.max(numW + multW + 3 * pad, trickW + 2 * pad, 110 * s)
	local h = 56 * s
	local x, y = math.floor(ScrW() * 0.5 - w * 0.5), math.floor(ScrH() - 16 * s - h)
	draw.RoundedBox(8, x, y, w, h, ColorAlpha(HL2_BG, HL2_BG.a * a))
	draw.SimpleText(v.trick ~= "" and v.trick:upper() or "TRICK", "HudSelectionText", x + pad, y + 4 * s,
		ColorAlpha(HL2_FG, HL2_FG.a * a))
	draw.SimpleText(v.points, "HudNumbers", x + pad, y + 12 * s, ColorAlpha(fg, fg.a * a))
	draw.SimpleText(mult, "HudNumbersSmall", x + w - pad, y + 26 * s, ColorAlpha(HL2_FG, HL2_FG.a * a), TEXT_ALIGN_RIGHT)
	-- The line timer, as the aux power bar's segments along the bottom.
	local gap = 2 * s
	local segW = (w - 2 * pad - gap * (SEGMENTS - 1)) / SEGMENTS
	for i = 1, SEGMENTS do
		local color = v.timer > (i - 1) / SEGMENTS and HL2_FG or HL2_DIM
		surface.SetDrawColor(ColorAlpha(color, color.a * a))
		surface.DrawRect(x + pad + (i - 1) * (segW + gap), y + h - 8 * s, segW, 3 * s)
	end
end

function Score.Draw(pose)
	Update(pose)
	if not view then return end
	local style = cv_style:GetString()
	if style == "world" then return end
	if style == "hl2" then
		HL2(view)
	else
		local s = ScrH() / 1080
		Minimal(view, ScrW() * 0.5 - 90 * s, ScrH() - 150 * s, s)
	end
end

-- Beside the skater, to the right as the camera sees them, upright and facing
-- the camera. The offset eases round as the camera swings, so it trails a little.
local worldOffset
function Score.DrawWorld(pos)
	if not view or cv_style:GetString() ~= "world" then
		worldOffset = nil
		return
	end
	local yaw = EyeAngles().y
	local target = Angle(0, yaw, 0):Right() * 34 + Vector(0, 0, 52)
	worldOffset = worldOffset and LerpVector(math.min(FrameTime() * 8, 1), worldOffset, target) or target
	local s = ScrH() / 1080
	cam.IgnoreZ(true)
	cam.Start3D2D(pos + worldOffset, Angle(0, yaw - 90, 90), 0.15 / s)
	Minimal(view, 0, 0, s)
	cam.End3D2D()
	cam.IgnoreZ(false)
end

function Score.Reset()
	last, flash, shown, lastTrick, seenAt, view, worldOffset = nil, nil, 0, "", -math.huge, nil, nil
end

return Score
