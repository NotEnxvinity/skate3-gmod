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

-- One frame of the widget. `v` is the score's view (cl_score.lua's Update).
function S3.Draw(v)
	local a = v.alpha
	if a <= 0 then return end
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
	UI.Futura(v.points, SCORE_X, SCORE_Y, SCORE_H, color, a, TEXT_ALIGN_LEFT)
	if v.trick and v.trick ~= "" then
		UI.Futura(v.trick, TRICK_X, TRICK_Y, TRICK_H, TRICK, a * 0.8, TEXT_ALIGN_LEFT)
	end
end

-- The toast line (marker set, back at marker ...), over the score.
function S3.Toast(text, alpha)
	UI.Futura(text, SCORE_X, 528, 20, CREAM, alpha, TEXT_ALIGN_LEFT)
end

return S3
