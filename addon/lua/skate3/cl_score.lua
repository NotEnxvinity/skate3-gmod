-- The trick score widget, after Skate 3's: a ring with the combo multiplier
-- inside and the line timer running down around it, the line's score beside
-- it, and the latest trick's name. When a line ends, what it was worth (or
-- that it was lost to a bail) shows for a moment. Three looks (skate3_ui_style):
-- Skate 3's own art, from the player's disc (cl_score_skate3.lua), the
-- minimal widget in Helvetica Neue Bold, or Half-Life 2's HUD panels; and the
-- first two can sit on screen, bottom left, or float beside the skater
-- (skate3_ui_world).

local Score = {}
local Meat = include("skate3/cl_hall_of_meat.lua")
Score.Meat = Meat

local UI = S3GM_UI
local Skate3 = include("skate3/cl_score_skate3.lua")

local cv_score = CreateClientConVar("skate3_score_hud", "1", true, false, "Show the trick score widget")
-- Retired: the look is skate3_ui_style now (with skate3_ui_world for where).
CreateClientConVar("skate3_score_style", "world", true, false, "Old setting, no longer used")

-- How long a finished line stays on screen, and how long it fades.
local HOLD = 2.5
local FADE = 0.5

local WHITE = Color(255, 255, 255)
local GREEN = Color(130, 255, 150)
local RED = Color(255, 90, 80)
local RING = Color(255, 255, 255)
local RING_EMPTY = Color(255, 255, 255, 50)
local DISC = Color(0, 0, 0, 150)

-- The minimal look's fonts: Helvetica Neue Bold where the player has it
-- (cl_ui.lua says what stands in otherwise).
local FONT = {}
local fontsFor
local function Fonts()
	local h = ScrH()
	if fontsFor == h then return end
	fontsFor = h
	local s = h / 1080
	FONT.mult = UI.Font(30 * s)
	FONT.points = UI.Font(38 * s)
	FONT.trick = UI.Font(22 * s)
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
local tricks = {} -- this line's trick names, oldest first (the stack above the disc)
local trickAt = {} -- when each of those was added (the stack animates on it)
local scoreAt, multAt, lastMult = -math.huge, -math.huge, 1 -- when the big number last changed, when the multiplier last went up
local tierAt = -math.huge -- when the multiplier last reached x2 or x3
local lastLabel = ""
local lastSeq = 0 -- the last trick sequence's score, the big number in Skate 3's look
local wasLive = false
-- Distance readouts (Skate 3's "Air Distance 30.2 ft" boxes). They only show a
-- number: no score comes with them. Garry's Mod units are inches.
local readouts = {} -- { air = { feet, at }, manual = { feet, at } }
local airFrom, manualLast, manualFeet
-- How far a jump or a manual has to go before its box shows (feet).
local cv_air_min = CreateClientConVar("skate3_ui_air_min_feet", "100", true, false,
	"Show the Air Distance box once a jump goes at least this many feet")
local cv_manual_min = CreateClientConVar("skate3_ui_manual_min_feet", "50", true, false,
	"Show the Manual Distance box once a manual goes at least this many feet")

local function Flat(a, b)
	local dx, dy = a[1] - b[1], a[2] - b[2]
	return math.sqrt(dx * dx + dy * dy) / 12
end
local seenAt = -math.huge -- when the widget last had something live to show
local view -- what to draw this frame, or nil

-- Hall of Meat's score in the same widget, the points in red under a white
-- "Bailed": running while the bail
-- goes on, then held like a finished line (the skeleton shows on the
-- skater, cl_hall_of_meat.lua).
local function MeatView(now)
	local b, going = Meat.Current()
	if not b then return nil end
	local alpha = going and 1 or math.Clamp((HOLD + FADE - (now - b.endedAt)) / FADE, 0, 1)
	if alpha <= 0 then return nil end
	local points = math.floor(b.points + 0.5)
	return {
		alpha = alpha, live = false, timer = 0, multiplier = 1,
		points = Points(points), value = points, good = false,
		trick = "Bailed", meat = b.parts,
	}
end

-- Rolling backwards along the board on the ground (Skate 3 calls it FAKIE).
-- The engine doesn't say which stance the skater is in, so SWITCH isn't shown.
local function Fakie(pose)
	local v, f = pose.velocity, pose.forward
	if not v or not f or not pose.state or not pose.state:find("^Physics") or pose.state:find("Air") then return false end
	local horizontal = math.sqrt(v[1] * v[1] + v[2] * v[2])
	if horizontal < 40 then return false end
	return (v[1] * f[1] + v[2] * f[2]) < -0.6 * horizontal
end

-- Watches the jump and the manual for how far they went.
local function Distances(pose, sc, bailing, now)
	local pos, state = pose.pos, pose.state or ""
	if not pos then return end
	local air = state:find("Air") ~= nil
	if air and not airFrom then
		airFrom = { pos[1], pos[2], pos[3] }
	elseif not air and airFrom then
		local feet = Flat(pos, airFrom)
		airFrom = nil
		if not bailing and feet >= cv_air_min:GetFloat() then readouts.air = { feet = feet, at = now, since = now } end
	end

	local manual = sc.active and not air and (sc.trick or ""):upper():find("MANUAL") ~= nil
	if manual then
		if not manualLast then manualLast, manualFeet = { pos[1], pos[2], pos[3] }, 0 end
		manualFeet = manualFeet + Flat(pos, manualLast)
		manualLast = { pos[1], pos[2], pos[3] }
		if manualFeet >= cv_manual_min:GetFloat() then
			readouts.manual = { feet = manualFeet, at = now, since = readouts.manual and readouts.manual.since or now }
		end
	elseif manualLast then
		manualLast = nil
	end
end

local function ReadoutRows()
	local rows = {}
	for label, key in pairs({ ["Air Distance"] = "air", ["Manual Distance"] = "manual" }) do
		local r = readouts[key]
		if r then rows[#rows + 1] = { since = r.since, text = ("%s %.1f ft"):format(label, r.feet) } end
	end
	table.sort(rows, function(a, b) return a.since < b.since end)
	return rows
end

-- Works out this frame's view from the engine's score.
local function Update(pose)
	view = nil
	Meat.Update(pose, LocalPlayer())
	if not cv_score:GetBool() or not pose or not pose.score then return end
	local sc = pose.score
	local now = RealTime()
	local bailing = pose.state and pose.state:find("^Wipeout") ~= nil
	if Meat.Enabled() then
		view = MeatView(now)
		if view then
			-- The bail took the line with it; don't flash "Bailed" after.
			flash, last = nil, { banked = sc.banked, active = sc.active, sequence = sc.sequence, line = sc.line }
			return
		end
	end

	if last then
		if sc.banked > last.banked + 0.5 then
			flash = { text = "+" .. Points(sc.banked - last.banked), value = sc.banked - last.banked, good = true, at = now }
		elseif last.active and not sc.active then
			if bailing then
				flash = { text = "Bailed", value = shown, good = false, at = now } -- the score lost
			elseif sc.line <= last.line + 0.5 and last.sequence > 0.5 then
				-- A trick on its own, not part of a line: it scores but never banks.
				flash = { text = "+" .. Points(last.sequence), value = last.sequence, good = true, at = now }
			end
		end
	end
	last = { banked = sc.banked, active = sc.active, sequence = sc.sequence, line = sc.line }

	local live = sc.active or sc.timer > 0
	Distances(pose, sc, bailing, now)
	if live then
		if not wasLive then tricks, trickAt, lastLabel, lastSeq, readouts, lastMult, tierAt = {}, {}, "", 0, {}, 1, -math.huge end
		seenAt = now
		shown = sc.line + (sc.active and sc.sequence or 0)
		if sc.trick ~= "" then lastTrick = sc.trick end
		if sc.active and sc.sequence > 0 then
			if sc.sequence ~= lastSeq then scoreAt = now end
			lastSeq = sc.sequence
		end
		if sc.multiplier > lastMult + 0.01 then multAt = now end
		-- reaching x2 or x3 (not the half steps between) sets off the glow and flash
		if sc.multiplier >= 2 and math.floor(math.min(sc.multiplier, 3)) > math.floor(math.min(lastMult, 3)) then tierAt = now end
		lastMult = sc.multiplier
		if sc.trick ~= "" and sc.trick ~= lastLabel then
			lastLabel = sc.trick
			tricks[#tricks + 1] = TrickName(sc.trick)
			trickAt[#tricks] = now
			if #tricks > 3 then
				table.remove(tricks, 1)
				table.remove(trickAt, 1)
			end
		end
	end
	wasLive = live
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
		-- Skate 3's look shows what was banked as a plain number, no "+".
		banked = showFlash and flash.good and Points(flash.value) or nil,
		-- The same as a bare number, for fonts with only digits.
		value = math.floor((showFlash and flash.value or shown) + 0.5),
		good = not showFlash or flash.good,
		trick = TrickName(lastTrick),
		-- Skate 3's look: the stack of this line's tricks, the last trick
		-- sequence's score and the line's total, and "FAKIE" when rolling backwards.
		tricks = tricks,
		trickAt = trickAt,
		now = now,
		scoreAt = scoreAt,
		multAt = multAt,
		tierAt = tierAt,
		sequence = Points(lastSeq > 0 and lastSeq or shown),
		line = Points(shown),
		stance = Fakie(pose) and "FAKIE" or nil,
		readouts = ReadoutRows(),
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
	Shadowed(Multiplier(v.multiplier), FONT.mult, cx, cy, WHITE, alpha, TEXT_ALIGN_CENTER)
	local x = cx + r + 14 * s
	local color = v.live and WHITE or (v.good and GREEN or RED)
	Shadowed(v.points, FONT.points, x, cy - 8 * s, color, alpha, TEXT_ALIGN_LEFT)
	Shadowed(v.trick, FONT.trick, x, cy + 20 * s, WHITE, alpha, TEXT_ALIGN_LEFT)
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
	local label = v.meat and "BAILED" or not v.good and "BAILED" or (v.trick ~= "" and v.trick:upper() or "SCORE")
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

-- Short notes (marker set, back at marker) go through cl_ui.lua's toast; the
-- old names still work for anything that calls them.
function Score.Marker(text)
	UI.Toast(text)
end

function Score.MarkerHold() end

-- The Skate 3 and minimal looks put the toast over the score, the HL2 look in
-- a small panel above its health row.
local function MinimalToast(x, y, s)
	local text, alpha = UI.CurrentToast()
	if not text then return end
	Fonts()
	local r = 9 * s
	Disc(x + r, y, r, ColorAlpha(DISC, DISC.a * alpha))
	Arc(x + r, y, r - 3 * s, r, 1, ColorAlpha(RING, RING.a * alpha))
	Shadowed(text, FONT.trick, x + 2 * r + 8 * s, y, WHITE, alpha, TEXT_ALIGN_LEFT)
end

local function HL2Toast()
	local text, alpha = UI.CurrentToast()
	if not text then return end
	local s = ScrH() / 480
	text = text:upper()
	surface.SetFont("HudSelectionText")
	local w = surface.GetTextSize(text) + 16 * s
	local h = 16 * s
	local x, y = math.floor(ScrW() * 0.5 - w * 0.5), math.floor(ScrH() - 12 * s - 36 * s - 6 * s - h)
	draw.RoundedBox(4, x, y, w, h, ColorAlpha(HL2_BG, HL2_BG.a * alpha))
	draw.SimpleText(text, "HudSelectionText", x + 8 * s, y + 2 * s, ColorAlpha(HL2_FG, HL2_FG.a * alpha))
end

-- The menu hides the score while it's up (the toasts stay).
local function MenuUp()
	return S3GM_Menu and S3GM_Menu.Visible()
end

-- The Half-Life 2 health and ammo boxes sit over the score, so they step
-- aside while the skater is up (the HL2 look keeps them).
local drawnAt = 0
local HL2_HUD = { CHudHealth = true, CHudBattery = true, CHudAmmo = true, CHudSecondaryAmmo = true }
hook.Add("HUDShouldDraw", "skate3_hide_hl2_hud", function(name)
	if HL2_HUD[name] and CurTime() - drawnAt < 0.25 and UI.Style() ~= "hl2" then return false end
end)

-- What this frame's widget shows, or nil (for tests and other HUD code).
function Score.View() return view end

function Score.Draw(pose)
	drawnAt = CurTime()
	Update(pose)
	local style = UI.Style()
	local menu = MenuUp()
	if style == "hl2" then
		if view and not menu then HL2(view) end
		HL2Toast()
		return
	end
	if style == "skate3" then
		-- On screen the score sits bottom left; in the world it's drawn by DrawWorld.
		UI.BeginBottomLeft()
		if view and not menu and not UI.World() then Skate3.Draw(view) end
		local text, alpha = UI.CurrentToast()
		if text then Skate3.Toast(text, alpha) end
	else
		local s = ScrH() / 1080
		local cx, cy = 150 * s, ScrH() - 150 * s
		if view and not menu and not UI.World() then Minimal(view, cx, cy, s) end
		MinimalToast(cx - 34 * s, cy - 56 * s, s)
	end
end

-- Beside the skater, to the right as the camera sees them, upright and facing
-- the camera. The offset eases round as the camera swings, so it trails a little.
local worldOffset
function Score.DrawWorld(pos)
	if not view or MenuUp() or not UI.World() then
		worldOffset = nil
		return
	end
	local yaw = EyeAngles().y
	local target = Angle(0, yaw, 0):Right() * 34 + Vector(0, 0, 52)
	worldOffset = worldOffset and LerpVector(math.min(FrameTime() * 8, 1), worldOffset, target) or target
	cam.IgnoreZ(true)
	if UI.Style() == "skate3" then
		-- The disc's centre at the plane's origin.
		cam.Start3D2D(pos + worldOffset, Angle(0, yaw - 90, 90), 0.1)
		UI.Begin(-164, -604, 1, true)
		Skate3.Draw(view)
	else
		local s = ScrH() / 1080
		cam.Start3D2D(pos + worldOffset, Angle(0, yaw - 90, 90), 0.15 / s)
		Minimal(view, 0, 0, s)
	end
	cam.End3D2D()
	cam.IgnoreZ(false)
end

function Score.Reset()
	Meat.Reset()
	last, flash, shown, lastTrick, seenAt, view, worldOffset = nil, nil, 0, "", -math.huge, nil, nil
	tricks, trickAt, lastLabel, lastSeq, wasLive = {}, {}, "", 0, false
	scoreAt, multAt, lastMult, tierAt = -math.huge, -math.huge, 1, -math.huge
	readouts, airFrom, manualLast = {}, nil, nil
end

return Score
