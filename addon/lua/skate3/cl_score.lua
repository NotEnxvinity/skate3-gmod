-- The trick score widget, after Skate 3's: a ring with the combo multiplier
-- inside and the line timer running down around it, the line's score beside
-- it, and the latest trick's name. When a line ends, what it was worth (or
-- that it was lost to a bail) shows for a moment.

local Score = {}

local cv_score = CreateClientConVar("skate3_score_hud", "1", true, false, "Show the trick score widget")

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
-- ID_TRICK_GROUND_TRICK_MANUAL; until names come from the disc, make the ID
-- readable: "Manual".
local SKIP = { ID = true, TRICK = true, GROUND = true, AIR = true, GRIND = true }
local names = {}
local function TrickName(id)
	if id == "" then return "" end
	local name = names[id]
	if name then return name end
	local words = {}
	for word in id:gmatch("[^_]+") do
		if not SKIP[word] then
			if #word <= 2 or word:find("%d") then
				words[#words + 1] = word
			else
				words[#words + 1] = word:sub(1, 1) .. word:sub(2):lower()
			end
		end
	end
	name = #words > 0 and table.concat(words, " ") or id
	names[id] = name
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

function Score.Draw(pose)
	if not cv_score:GetBool() or not pose or not pose.score then return end
	local sc = pose.score
	local now = RealTime()
	local bailing = pose.state and pose.state:find("^Wipeout") ~= nil

	if last then
		if sc.banked > last.banked + 0.5 then
			flash = { text = "+" .. Points(sc.banked - last.banked), color = GREEN, at = now }
		elseif last.active and not sc.active then
			if bailing then
				flash = { text = "Bail", color = RED, at = now }
			elseif sc.line <= last.line + 0.5 and last.sequence > 0.5 then
				-- A trick on its own, not part of a line: it scores but never banks.
				flash = { text = "+" .. Points(last.sequence), color = GREEN, at = now }
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

	Fonts()
	local s = ScrH() / 1080
	local r = 34 * s
	local cx, cy = ScrW() * 0.5 - 90 * s, ScrH() - 150 * s

	Disc(cx, cy, r, ColorAlpha(DISC, DISC.a * alpha))
	Arc(cx, cy, r - 5 * s, r, 1, ColorAlpha(RING_EMPTY, RING_EMPTY.a * alpha))
	Arc(cx, cy, r - 5 * s, r, live and sc.timer or 0, ColorAlpha(RING, RING.a * alpha))
	Shadowed(Multiplier(live and sc.multiplier or 1), "skate3_mult", cx, cy, WHITE, alpha, TEXT_ALIGN_CENTER)

	local x = cx + r + 14 * s
	if live or not flash then
		Shadowed(Points(shown), "skate3_points", x, cy - 8 * s, WHITE, alpha, TEXT_ALIGN_LEFT)
	else
		Shadowed(flash.text, "skate3_points", x, cy - 8 * s, flash.color, alpha, TEXT_ALIGN_LEFT)
	end
	Shadowed(TrickName(lastTrick), "skate3_trick", x, cy + 20 * s, WHITE, alpha, TEXT_ALIGN_LEFT)
end

function Score.Reset()
	last, flash, shown, lastTrick, seenAt = nil, nil, 0, "", -math.huge
end

return Score
