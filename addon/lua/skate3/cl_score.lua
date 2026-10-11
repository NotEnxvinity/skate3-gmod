-- The trick score widget, after Skate 3's: a ring with the combo multiplier
-- inside and the line timer running down around it, the line's score beside
-- it, and the latest trick's name. When a line ends, what it was worth (or
-- that it was lost to a bail) shows for a moment. Three looks: that widget on
-- screen, the same floating in the world beside the skater, or Half-Life 2's
-- HUD panels.

local Score = {}

local cv_score = CreateClientConVar("skate3_score_hud", "1", true, false, "Show the trick score widget")
local cv_style = CreateClientConVar("skate3_score_style", "world", true, false,
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
	local bare = id:gsub("^ID_", "")
	for word in bare:gmatch("[^_]+") do words[#words + 1] = word end
	-- Grinds come without a localisation ID (GRIND_BS_5_0): that's a
	-- "BS 5-0 Grind".
	local grind = bare:find("^GRIND_") ~= nil
	while #words > 1 and CATEGORY[words[1]] do table.remove(words, 1) end
	-- Numbers written in pieces: 5_0 is 5-0, 50_50 is 50-50.
	local joined = {}
	for _, word in ipairs(words) do
		local prev = joined[#joined]
		if prev and word:find("^%d+$") and prev:find("^%d[%d%-]*$") then
			joined[#joined] = prev .. "-" .. word
		else
			joined[#joined + 1] = word
		end
	end
	words = joined
	for i, word in ipairs(words) do
		if #word > 2 and not word:find("%d") then
			words[i] = word:sub(1, 1) .. word:sub(2):lower()
		end
	end
	local name = table.concat(words, " ")
	if grind and not name:lower():find("grind") and not name:lower():find("slide") then
		name = name .. " Grind"
	end
	return name
end

-- An engine label's name: the game's own text if setup found it (under
-- whichever ID it's filed), else spelled out from the label.
local function Lookup(part)
	local k = Known()
	local found = k[part] or k["ID_TRICK_" .. part] or k["ID_" .. part]
	if found then return found end
	-- Anything that looks like an ID (capitals and underscores) is spelled
	-- out rather than shown raw.
	if part:find("^ID_") or (part:find("_") and part:find("^[%u%d_]+$")) then return SpellOut(part) end
	return part
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
			parts[#parts + 1] = Lookup(part)
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
			flash = { text = "+" .. Points(sc.banked - last.banked), value = sc.banked - last.banked, good = true, at = now }
		elseif last.active and not sc.active then
			if bailing then
				flash = { text = "Bail", value = shown, good = false, at = now } -- the score lost
			elseif sc.line <= last.line + 0.5 and last.sequence > 0.5 then
				-- A trick on its own, not part of a line: it scores but never banks.
				flash = { text = "+" .. Points(last.sequence), value = last.sequence, good = true, at = now }
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
		-- The same as a bare number, for fonts with only digits.
		value = math.floor((showFlash and flash.value or shown) + 0.5),
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

-- Half-Life 2's HUD, laid out like its HEALTH panel on the same row: a dim
-- rounded box with the label low on the left and the big number beside it,
-- the multiplier above the label and the line timer as aux power segments
-- along the bottom. HudNumbers only has digits, so the number goes in bare and
-- everything else in the label font.
local HL2_FG = Color(255, 220, 0, 230)
local HL2_DIM = Color(255, 220, 0, 50)
local HL2_RED = Color(255, 0, 0, 230)
local HL2_BG = Color(0, 0, 0, 76)
local SEGMENTS = 10

local function HL2(v)
	local a = v.alpha
	local s = ScrH() / 480
	local fg = v.good and HL2_FG or HL2_RED
	local label = not v.good and "BAIL" or (v.trick ~= "" and v.trick:upper() or "SCORE")
	local mult = v.live and "x" .. Multiplier(v.multiplier):sub(1, -2) or ""
	local number = tostring(v.value)
	surface.SetFont("HudSelectionText")
	local labelW = math.max(surface.GetTextSize(label), surface.GetTextSize(mult))
	surface.SetFont("HudNumbers")
	local numW = surface.GetTextSize(number)
	local pad, gap = 8 * s, 10 * s
	-- HEALTH's box: 36 tall, its bottom 12 above the screen's at 480 lines.
	local w, h = math.max(pad + labelW + gap + numW + pad, 102 * s), 36 * s
	local x, y = math.floor(ScrW() * 0.5 - w * 0.5), math.floor(ScrH() - 12 * s - h)
	draw.RoundedBox(8, x, y, w, h, ColorAlpha(HL2_BG, HL2_BG.a * a))
	draw.SimpleText(mult, "HudSelectionText", x + pad, y + 6 * s, ColorAlpha(HL2_FG, HL2_FG.a * a))
	draw.SimpleText(label, "HudSelectionText", x + pad, y + 20 * s, ColorAlpha(fg, fg.a * a))
	draw.SimpleText(number, "HudNumbers", x + w - pad, y + 2 * s, ColorAlpha(fg, fg.a * a), TEXT_ALIGN_RIGHT)
	if not v.live then return end
	local segGap = 2 * s
	local segW = (w - 2 * pad - segGap * (SEGMENTS - 1)) / SEGMENTS
	for i = 1, SEGMENTS do
		local color = v.timer > (i - 1) / SEGMENTS and HL2_FG or HL2_DIM
		surface.SetDrawColor(ColorAlpha(color, color.a * a))
		surface.DrawRect(x + pad + (i - 1) * (segW + segGap), y + h - 4 * s, segW, 2 * s)
	end
end

-- The session marker's badge, over the score: a note when one is dropped or
-- reached, and a ring (a bar in the HL2 look) filling while the button is
-- held to go back. Kept apart from the score, which a return resets.
local badge = { text = nil, at = -math.huge, progress = 0 }

function Score.Marker(text)
	badge.text, badge.at, badge.progress = text, RealTime(), 0
end

function Score.MarkerHold(progress)
	badge.progress = progress
end

-- What the badge says and how opaque it is, or nil when it's gone.
local function Badge()
	if badge.progress > 0 then return "Back to marker", 1 end
	local alpha = math.Clamp((HOLD + FADE - (RealTime() - badge.at)) / FADE, 0, 1)
	if badge.text and alpha > 0 then return badge.text, alpha end
end

-- The Skate 3 look, left-aligned at x around y.
local function MinimalBadge(x, y, s)
	local text, alpha = Badge()
	if not text then return end
	Fonts()
	local r = 9 * s
	Disc(x + r, y, r, ColorAlpha(DISC, DISC.a * alpha))
	Arc(x + r, y, r - 3 * s, r, badge.progress > 0 and badge.progress or 1, ColorAlpha(RING, RING.a * alpha))
	Shadowed(text, "skate3_trick", x + 2 * r + 8 * s, y, WHITE, alpha, TEXT_ALIGN_LEFT)
end

-- The HL2 look, a small panel centred above the score's.
local function HL2Badge()
	local text, alpha = Badge()
	if not text then return end
	local s = ScrH() / 480
	text = text:upper()
	surface.SetFont("HudSelectionText")
	local w = surface.GetTextSize(text) + 16 * s
	local h = 16 * s
	local x, y = math.floor(ScrW() * 0.5 - w * 0.5), math.floor(ScrH() - 12 * s - 36 * s - 6 * s - h)
	draw.RoundedBox(4, x, y, w, h, ColorAlpha(HL2_BG, HL2_BG.a * alpha))
	draw.SimpleText(text, "HudSelectionText", x + 8 * s, y + 2 * s, ColorAlpha(HL2_FG, HL2_FG.a * alpha))
	if badge.progress > 0 then
		surface.SetDrawColor(ColorAlpha(HL2_FG, HL2_FG.a * alpha))
		surface.DrawRect(x + 8 * s, y + h - 3 * s, (w - 16 * s) * badge.progress, 2 * s)
	end
end

function Score.Draw(pose)
	Update(pose)
	local style = cv_style:GetString()
	if style == "hl2" then
		if view then HL2(view) end
		HL2Badge()
	elseif style ~= "world" then
		local s = ScrH() / 1080
		local cx, cy = ScrW() * 0.5 - 90 * s, ScrH() - 150 * s
		if view then Minimal(view, cx, cy, s) end
		MinimalBadge(cx - 34 * s, cy - 56 * s, s)
	end
end

-- Beside the skater, to the right as the camera sees them, upright and facing
-- the camera. The offset eases round as the camera swings, so it trails a little.
local worldOffset
function Score.DrawWorld(pos)
	if not (view or Badge()) or cv_style:GetString() ~= "world" then
		worldOffset = nil
		return
	end
	local yaw = EyeAngles().y
	local target = Angle(0, yaw, 0):Right() * 34 + Vector(0, 0, 52)
	worldOffset = worldOffset and LerpVector(math.min(FrameTime() * 8, 1), worldOffset, target) or target
	local s = ScrH() / 1080
	cam.IgnoreZ(true)
	cam.Start3D2D(pos + worldOffset, Angle(0, yaw - 90, 90), 0.15 / s)
	if view then Minimal(view, 0, 0, s) end
	MinimalBadge(-34 * s, -56 * s, s)
	cam.End3D2D()
	cam.IgnoreZ(false)
end

function Score.Reset()
	last, flash, shown, lastTrick, seenAt, view, worldOffset = nil, nil, 0, "", -math.huge, nil, nil
end

return Score
