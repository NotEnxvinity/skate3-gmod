-- The trick score widget: the latest trick's name, the line's score and
-- multiplier while it builds, then what the line was worth once it lands
-- (or that it was lost to a bail), and the ride's total.

local Score = {}

local cv_score = CreateClientConVar("skate3_score_hud", "1", true, false, "Show the trick score widget")

-- How long a landed or bailed line stays on screen.
local HOLD = 2.5
local FADE = 0.5

local WHITE = Color(255, 255, 255)
local GOLD = Color(255, 210, 90)
local GREEN = Color(120, 255, 140)
local RED = Color(255, 90, 80)
local SHADE = Color(0, 0, 0, 170)

local fontsFor
local function Fonts()
	local h = ScrH()
	if fontsFor == h then return end
	fontsFor = h
	local s = h / 1080
	surface.CreateFont("skate3_trick", { font = "Roboto", size = math.Round(40 * s), weight = 800 })
	surface.CreateFont("skate3_line", { font = "Roboto", size = math.Round(30 * s), weight = 700 })
	surface.CreateFont("skate3_total", { font = "Roboto", size = math.Round(20 * s), weight = 600 })
end

local seen -- the module's settled-line count we last saw
local result -- { text, color, at, trick }
local lastBuilding

local function Text(text, font, x, y, color, alpha)
	color = ColorAlpha(color, color.a * alpha)
	draw.SimpleTextOutlined(text, font, x, y, color, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 2, ColorAlpha(color_black, 200 * alpha))
	local _, th = surface.GetTextSize(text)
	return th
end

local function Points(n)
	return string.Comma(math.floor(n + 0.5))
end

function Score.Draw(pose)
	if not cv_score:GetBool() or not pose or not pose.score then return end
	local sc = pose.score
	local now = RealTime()

	if seen == nil then seen = sc.settled end
	if sc.settled ~= seen then
		seen = sc.settled
		if sc.landed > 0 then
			result = { text = "+" .. Points(sc.landed), color = GREEN, at = now, trick = sc.trick }
		elseif lastBuilding then
			result = { text = "Bailed", color = RED, at = now, trick = sc.trick }
		end
	end
	lastBuilding = sc.building

	Fonts()
	local x, y = ScrW() * 0.5, ScrH() * 0.07

	if sc.building and sc.trick ~= "" then
		result = nil
		y = y + Text(sc.trick, "skate3_trick", x, y, WHITE, 1)
		local line = Points(sc.line)
		if sc.multiplier > 1 then
			line = line .. ("  x%g"):format(math.Round(sc.multiplier, 1))
		end
		y = y + Text(line, "skate3_line", x, y, GOLD, 1)
	elseif result then
		local age = now - result.at
		local alpha = math.Clamp((HOLD + FADE - age) / FADE, 0, 1)
		if alpha <= 0 then
			result = nil
		else
			y = y + Text(result.trick, "skate3_trick", x, y, WHITE, alpha)
			y = y + Text(result.text, "skate3_line", x, y, result.color, alpha)
		end
	end

	if sc.total > 0 then
		surface.SetFont("skate3_total")
		local text = "Total " .. Points(sc.total)
		local w, h = surface.GetTextSize(text)
		local pad = 8
		local bx, by = ScrW() - w - pad * 3, ScrH() * 0.05
		draw.RoundedBox(6, bx, by, w + pad * 2, h + pad, SHADE)
		draw.SimpleText(text, "skate3_total", bx + pad, by + pad * 0.5, WHITE)
	end
end

function Score.Reset()
	seen, result, lastBuilding = nil, nil, nil
end

return Score
