-- The trick score in Skate 3's own look: the multiplier disc with the line
-- timer running round it, the score in Futura beside it and the trick's name
-- above, all from the game's trickdisplay2 movie (art made from the player's
-- disc by setup). Laid out where the movie puts them, bottom left of a
-- 1280x720 canvas. The movie's own animations (intro, outro, flicker) are
-- not replayed: it fades in and out instead.

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

-- The distance boxes ("Air Distance 30.2 ft") stacked above the trick stack,
-- newest at the bottom: dark translucent boxes with a thin light edge.
local BOX_X, BOX_BOTTOM, BOX_STEP, BOX_H, BOX_TEXT = 120, 420, 32, 25, 19
local function Readouts(rows, a)
	for i, text in ipairs(rows) do
		local y = BOX_BOTTOM - (#rows - i) * BOX_STEP - BOX_H / 2
		local w = UI.FuturaWidth(text, BOX_TEXT) + 22
		UI.Rounded(4, BOX_X, y, w, BOX_H, Color(120, 140, 175, 150 * a))
		UI.Rounded(3, BOX_X + 1, y + 1, w - 2, BOX_H - 2, Color(18, 28, 52, 205 * a))
		UI.Futura(text, BOX_X + 11, y + 2, BOX_TEXT, TRICK, a, TEXT_ALIGN_LEFT)
	end
end

-- Hall of Meat's score, as the retail game draws it: a frosted panel bottom
-- left with the magazine's logo (from the disc) and the "Hall of Meat" caption
-- over the bail's score in cream.
local LOGO = { 78, 545 } -- the logo sprite's origin, so its lettering spans x 126..286
local LOGO_TINT = Color(180, 235, 250)
local function Meat(v)
	local a = v.alpha
	UI.Logo(LOGO[1], LOGO[2], 1, LOGO_TINT.r, LOGO_TINT.g, LOGO_TINT.b, 255 * a)
	UI.Rounded(6, 104, 604, 203, 62, Color(235, 240, 255, 38 * a))
	UI.Futura("Hall of Meat", 208, 582, 17, CREAM, a, TEXT_ALIGN_CENTER)
	UI.Futura(v.points, 208, 604, 40, CREAM, a, TEXT_ALIGN_CENTER)
end

-- One frame of the widget. `v` is the score's view (cl_score.lua's Update).
function S3.Draw(v)
	local a = v.alpha
	if a <= 0 then return end
	if v.meat then return Meat(v) end
	local m = v.multiplier
	local tier = m >= 3 and 3 or m >= 2 and 2 or 1

	if GLOWS[tier] then UI.Shape(GLOWS[tier], CX, CY, 1, 255, 255, 255, 255 * a * 0.7) end
	UI.Shape("51", CX, CY, 1, 255, 255, 255, 255 * a)
	Track(a)
	if v.live then
		UI.Sector(RINGS[tier], CX, CY, 0, math.Clamp(v.timer, 0, 1), 255, 255, 255, 255 * a)
	end
	if MULTIPLIER_ART[tier] and v.live then
		UI.Shape(MULTIPLIER_ART[tier], CX, CY, 1, 255, 255, 255, 255 * a)
	else
		UI.Futura(Multiplier(m), CX, CY - 14, 27, WHITE, a, TEXT_ALIGN_CENTER) -- ID_TRICKDISPLAY_15 is 27 high
	end

	local color = v.live and WHITE or (v.good and LINE or RED)
	local big = v.live and v.sequence or v.points
	UI.Futura(big or v.points, SCORE_X, SCORE_Y, SCORE_H, color, a, TEXT_ALIGN_LEFT)
	if v.live and v.line then
		UI.Futura("LINE: " .. v.line, LINE_X, LINE_Y, LINE_H, LINE, a * 0.9, TEXT_ALIGN_LEFT)
	end

	if v.readouts and #v.readouts > 0 then Readouts(v.readouts, a) end

	local stack = v.tricks
	if stack and #stack > 0 then
		for row = 1, math.min(#stack, #STACK) do
			local spec = STACK[row]
			UI.Futura(stack[#stack - row + 1], TRICK_X, spec[1], spec[2], row == 1 and TRICK or OLDER, a * spec[3], TEXT_ALIGN_LEFT)
		end
	elseif v.trick and v.trick ~= "" then
		UI.Futura(v.trick, TRICK_X, TRICK_Y, TRICK_H, TRICK, a * 0.8, TEXT_ALIGN_LEFT)
	end

	-- FAKIE reads bottom to top beside the disc.
	if v.stance then
		UI.Rotate(106, CY, -90)
		UI.Futura(v.stance, 106, CY - 9, 17, OLDER, a * 0.8, TEXT_ALIGN_CENTER)
		UI.Rotate()
	end
end

-- The toast line (marker set, back at marker ...), over the score.
function S3.Toast(text, alpha)
	UI.Futura(text, SCORE_X, 528, 20, CREAM, alpha, TEXT_ALIGN_LEFT)
end

return S3
