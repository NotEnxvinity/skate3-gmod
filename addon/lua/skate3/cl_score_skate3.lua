-- The trick score in Skate 3's own look: the multiplier disc with the line
-- timer running round it, the score in Futura beside it and the trick's name
-- above, all from the game's trickdisplay2 movie (art made from the player's
-- disc by setup). Laid out where the movie puts them, bottom left of a
-- 1280x720 canvas. The movie's intro and outro are not replayed (it fades in
-- and out instead); the rows, boxes, big number and the multiplier's glow and
-- flash at x2 and x3 use its timings.

local UI = S3GM_UI

local S3 = {}

-- Where the movie places the disc's centre, the score and the trick name.
local CX, CY = 164, 604
local SCORE_X, SCORE_Y, SCORE_H = 232, 564, 44
local TRICK_X, TRICK_Y, TRICK_H = 100, 517, 26.4

local WHITE = Color(255, 255, 255)
local LINE = Color(145, 199, 219) -- the movie's line-score blue
local OLDER = Color(205, 205, 200) -- earlier tricks of the line, greyer and smaller
-- The trick stack, newest at the bottom: top, height and opacity of each row
-- (measured off the retail game's 720p layout).
local STACK = { { 517, 26.4, 0.9 }, { 492, 21, 0.62 }, { 470, 18, 0.4 } }
local LINE_X, LINE_Y, LINE_H = 233, 617, 19
local TRICK = Color(255, 254, 236)
local RED = Color(255, 90, 80)
local CREAM = Color(243, 237, 210) -- the D-pad menu's text colour

-- Ring picture, by multiplier: x1, x2, x3.
local RINGS = { "36", "38", "40" }
local GLOWS = { nil, "61", "57" }
local GLOW_SCALE = { nil, 1.2, 0.86 } -- the movie sizes them 1.2x and 0.86x
local MULTIPLIER_ART = { nil, "72", "68" }

-- The movie's dark track quadrant (top left), mirrored to the other three.
local function Mirror(q, mx, my)
	local pts = {}
	for i = 1, 4 do pts[i] = { q[i][1] * mx, q[i][2] * my, q[i][3], q[i][4] } end
	if mx * my < 0 then pts[2], pts[4] = pts[4], pts[2] end
	return pts
end

local function Track(a)
	local art = UI.Art()
	local piece = art and art.shapes["43"] and art.shapes["43"][1]
	if not piece then return end
	for _, m in ipairs({ { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }) do
		UI.Quad(piece.tex, Mirror(piece.quad, m[1], m[2]), CX, CY, 1, 255, 255, 255, 255 * a)
	end
end

local function Multiplier(m)
	return (m == math.floor(m) and "x%d" or "x%.1f"):format(m)
end

-- The movie's own timings, in frames of 16 ms (read off the disc's trickdisplay2):
-- a trick name shifts to the next row over 9 frames, a distance box fades in
-- over 16 frames (from 40%) and the boxes above it move up over 5, the big
-- number fades in over 10 (from 80%). The ease is a quick start, slow finish.
local FRAME = 0.016
local SHIFT, BOX_IN, BOX_MOVE, SCORE_IN, POP = 9 * FRAME, 16 * FRAME, 5 * FRAME, 10 * FRAME, 10 * FRAME

local function Ease(t)
	t = math.Clamp(t, 0, 1)
	return 1 - (1 - t) * (1 - t)
end

local function Lerp(k, from, to) return from + (to - from) * k end

-- The stance labels' pictures (shapes 28 and 31 of the movie) and how long they take to fade in.
local STANCE_ART = { SWITCH = "28", FAKIE = "31" }
local STANCE_IN = 5 * FRAME
local stanceNow, stanceAt

-- What happens when the multiplier reaches x2 or x3 (the movie's multiplier
-- labels, counted in frames since the tier came in): the glow behind the disc
-- fades in over 19 frames, a white flash goes off (in three or four quick
-- steps up, then a straight fall), the x2 picture fades in over 4 frames and
-- the x3 one drops in from 1.5x, faint, over 23. Flashes: size, first
-- opacity, peak, frames to peak, frames to fall to nothing.
local GLOW_IN, X2_IN, X3_IN = 19, 4, 23
local FLASHES = {
	nil,
	{ { 7.5, 0.25, 0.6, 2, 14 } },
	{ { 12.5, 0.5, 1, 2, 20 }, { 10.75, 0, 1, 4, 20 } },
}

-- The glow and flash are kept well under the movie's own opacity: drawn at its
-- values the flash was a blown-out white disc (it's two stacked layers in the
-- movie, and the glow washed the number out), so they're a soft bloom here.
local GLOW_ALPHA, FLASH_ALPHA = 0.7, 0.35

-- The flash picture (shape 64) is four quadrants of a soft starburst, stacked
-- twice in the movie; one layer of it is plenty.
local function Bloom(k, a)
	if a <= 0 then return end
	local art = UI.Art()
	local shape = art and art.shapes["64"]
	if not shape then return end
	for i = 1, math.min(4, #shape) do
		UI.Quad(shape[i].tex, shape[i].quad, CX, CY, k, 255, 255, 255, a)
	end
end

local function Flash(f, first, peak, rise, fall)
	if f < 0 then return 0 end
	if f < rise then return Lerp(f / rise, first, peak) end
	return math.Clamp(peak * (1 - (f - rise) / fall), 0, 1)
end

-- The distance boxes ("Air Distance 30.2 ft") stacked above the trick stack,
-- newest at the bottom: dark translucent boxes with a thin light edge.
local BOX_X, BOX_BOTTOM, BOX_STEP, BOX_H, BOX_TEXT = 120, 420, 32, 25, 19
local function Readouts(rows, a, now)
	for i, row in ipairs(rows) do
		local text = row.text
		local y = BOX_BOTTOM - (#rows - i) * BOX_STEP - BOX_H / 2
		-- A new box fades in; the ones above it were a row lower a moment ago.
		local newer = rows[i + 1]
		if newer then y = y + (1 - Ease((now - newer.since) / BOX_MOVE)) * BOX_STEP end
		local a = a * Lerp(Ease((now - row.since) / BOX_IN), 0.4, 1)
		local w = UI.FuturaWidth(text, BOX_TEXT) + 22
		UI.Rounded(4, BOX_X, y, w, BOX_H, Color(120, 140, 175, 150 * a))
		UI.Rounded(3, BOX_X + 1, y + 1, w - 2, BOX_H - 2, Color(18, 28, 52, 205 * a))
		UI.Futura(text, BOX_X + 11, y + 2, BOX_TEXT, TRICK, a, TEXT_ALIGN_LEFT)
	end
end

-- Hall of Meat's score, as the retail game draws it: a frosted panel bottom
-- left (the disc's own, red-tinted) with the magazine's logo (from the disc) and the "Hall of Meat" caption
-- over the bail's score in cream.
local LOGO = { 78, 545 } -- the logo sprite's origin, so its lettering spans x 126..286
local LOGO_TINT = Color(180, 235, 250)
local function Meat(v)
	local a = v.alpha
	local _, panel = UI.Logo(LOGO[1], LOGO[2], 1, LOGO_TINT.r, LOGO_TINT.g, LOGO_TINT.b, 255 * a)
	-- The disc's own panel (red-tinted, from setup); a plain frosted one without it.
	if not panel then UI.Rounded(6, 104, 604, 203, 62, Color(235, 240, 255, 38 * a)) end
	UI.Futura("Hall of Meat", 208, 582, 17, CREAM, a, TEXT_ALIGN_CENTER)
	UI.Futura(v.points, 208, 604, 40, CREAM, a, TEXT_ALIGN_CENTER)
end

-- One frame of the widget. `v` is the score's view (cl_score.lua's Update).
function S3.Draw(v)
	local a = v.alpha
	local now = v.now or RealTime()
	if a <= 0 then return end
	if v.meat then return Meat(v) end
	local m = v.multiplier
	local tier = m >= 3 and 3 or m >= 2 and 2 or 1
	-- At x1 the retail game shows nothing at all: no disc, no ring, no label.
	if m >= 1.01 then
		local f = (now - (v.tierAt or -math.huge)) / FRAME -- frames since x2 or x3 came in

		-- The glow sits behind the disc (over it, it washed the number out).
		if tier > 1 then
			local glow = math.Clamp(f / GLOW_IN, 0, 1)
			UI.Shape(GLOWS[tier], CX, CY, GLOW_SCALE[tier], 255, 255, 255, 255 * a * glow * GLOW_ALPHA)
		end
		UI.Shape("51", CX, CY, 1, 255, 255, 255, 255 * a)
		Track(a)
		if v.live then
			UI.Sector(RINGS[tier], CX, CY, 0, math.Clamp(v.timer, 0, 1), 255, 255, 255, 255 * a)
		end
		if tier > 1 then
			if tier == 2 then
				UI.Shape(MULTIPLIER_ART[2], CX, CY, 1, 255, 255, 255, 255 * a * math.Clamp(f / X2_IN, 0, 1))
			else
				local k = math.Clamp(f / X3_IN, 0, 1)
				local drop = 1 - k * k
				UI.Shape(MULTIPLIER_ART[3], CX, CY, 1 + 0.5 * drop, 255, 255, 255, 255 * a * Lerp(k * k, 0.4, 1))
			end
			for _, spec in ipairs(FLASHES[tier]) do
				Bloom(spec[1], 255 * a * FLASH_ALPHA * Flash(f, spec[2], spec[3], spec[4], spec[5]))
			end
		else
			-- x1.5 and the like: the number pops when it goes up.
			local pop = 1 + 0.25 * (1 - Ease((now - (v.multAt or -math.huge)) / POP))
			UI.Futura(Multiplier(m), CX, CY - 14 * pop, 27 * pop, WHITE, a, TEXT_ALIGN_CENTER) -- ID_TRICKDISPLAY_15 is 27 high
		end
	end

	local color = v.live and WHITE or (v.good and LINE or RED)
	local big = v.live and v.sequence or v.banked or v.points
	local setAlpha = v.live and Lerp(Ease((now - (v.scoreAt or -math.huge)) / SCORE_IN), 0.8, 1) or 1
	UI.Futura(big or v.points, SCORE_X, SCORE_Y, SCORE_H, color, a * setAlpha, TEXT_ALIGN_LEFT)
	if v.live and v.line then
		UI.Futura("LINE: " .. v.line, LINE_X, LINE_Y, LINE_H, LINE, a * 0.9, TEXT_ALIGN_LEFT)
	end

	if v.readouts and #v.readouts > 0 then Readouts(v.readouts, a, now) end

	local stack = v.tricks
	if stack and #stack > 0 then
		for row = 1, math.min(#stack, #STACK) do
			local spec = STACK[row]
			local idx = #stack - row + 1
			local y, size, alpha = spec[1], spec[2], spec[3]
			local newer = v.trickAt and v.trickAt[idx + 1]
			if newer and STACK[row - 1] then
				-- It was a row nearer the disc until the next trick came in.
				local k, from = Ease((now - newer) / SHIFT), STACK[row - 1]
				y, size, alpha = Lerp(k, from[1], y), Lerp(k, from[2], size), Lerp(k, from[3], alpha)
			elseif row == 1 and v.trickAt and v.trickAt[idx] then
				-- The newest comes in a little bigger and fainter.
				local k = Ease((now - v.trickAt[idx]) / SHIFT)
				size, alpha = Lerp(k, size * 1.25, size), Lerp(k, alpha * 0.5, alpha)
			end
			UI.Futura(stack[idx], TRICK_X, y, size, row == 1 and TRICK or OLDER, a * alpha, TEXT_ALIGN_LEFT)
		end
	elseif v.trick and v.trick ~= "" then
		UI.Futura(v.trick, TRICK_X, TRICK_Y, TRICK_H, TRICK, a * 0.8, TEXT_ALIGN_LEFT)
	end

	-- FAKIE and SWITCH: the movie's curved labels on their dark arc left of
	-- the disc (the movie's stance clip sits 73 left and 34 above the disc's
	-- centre; the label fades in over 5 frames). Plain turned text without the art.
	if v.stance ~= stanceNow then stanceNow, stanceAt = v.stance, now end
	if v.stance then
		local art = UI.Art()
		local label = STANCE_ART[v.stance]
		if art and label and art.shapes[label] and art.shapes["26"] then
			local k = Ease((now - stanceAt) / STANCE_IN)
			UI.Shape("26", CX - 73, CY - 34, 1, 255, 255, 255, 255 * a)
			UI.Shape(label, CX - 73, CY - 34, 1, 255, 255, 255, 255 * a * k)
		else
			UI.Rotate(106, CY, -90)
			UI.Futura(v.stance, 106, CY - 9, 17, OLDER, a * 0.8, TEXT_ALIGN_CENTER)
			UI.Rotate()
		end
	end
end

-- The toast line (marker set, back at marker ...), over the score.
function S3.Toast(text, alpha)
	UI.Futura(text, SCORE_X, 528, 20, CREAM, alpha, TEXT_ALIGN_LEFT)
end

return S3
