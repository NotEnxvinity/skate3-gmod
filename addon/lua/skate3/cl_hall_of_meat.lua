-- Injuries, and Hall of Meat after Skate 3's. Each body part is watched
-- while the skater tumbles; a hard hit on something counts, and enough of
-- them fracture or break it. That always runs: the server's bail damage
-- (skate3_bail_damage) charges for injuries and its blood (skate3_blood)
-- splats where the hard hits land. With Hall of Meat on, bails also score,
-- in red, with a skeleton beside the score showing fractures yellow and
-- breaks red. The engine has no injuries of its own, so the hits are read
-- off the bail's bones here; the numbers are our tuning.
-- Bail on purpose: both triggers and both sticks clicked.

local Meat = {}

local cv_meat = CreateClientConVar("skate3_hall_of_meat", "0", true, false,
	"Hall of Meat: bails score points and break bones (1 on, 0 off)")

function Meat.Enabled()
	return cv_meat:GetBool()
end

local UNITS = 39.37 -- map units per metre
local TICK = 1 / 60 -- the simulation's step
-- A part's speed changing this much in one step (m/s), against something
-- solid, is a hit.
local HIT = 3.5
-- A part is fractured, then broken, by one hit this hard or by this much
-- damage added up over the bail.
local FRACTURE_HIT, FRACTURE_TOTAL = 6, 9
local BREAK_HIT, BREAK_TOTAL = 10, 18
-- Points: each hit by how hard it was, more for each new injury, and the
-- distance tumbled.
local HIT_POINTS = 12 -- times the hit squared
local FRACTURE_POINTS, BREAK_POINTS = 750, 2000
local TUMBLE_POINTS = 25 -- per metre
-- One part counts one hit at a time while it scrapes along.
local COOLDOWN = 0.2
-- Hits at least this hard (m/s) bleed, when the server allows blood.
local BLOOD_HIT = 6
local BLOOD_GAP = 0.15
local lastBlood = -math.huge

-- Body parts: the bones they're read from, and where they sit on the
-- skeleton (facing you, so the skater's left is on the right).
local PARTS = {
	{ id = "skull", bones = { "HEAD" } },
	{ id = "spine", bones = { "SPINE2", "SPINE3", "NECK" } },
	{ id = "ribs", bones = { "SPINE1" } },
	{ id = "pelvis", bones = { "HIPS", "SPINE" } },
	{ id = "lcollar", bones = { "LEFTSHOULDER" } },
	{ id = "rcollar", bones = { "RIGHTSHOULDER" } },
	{ id = "larm", bones = { "LEFTARM" } },
	{ id = "rarm", bones = { "RIGHTARM" } },
	{ id = "lforearm", bones = { "LEFTFOREARM" } },
	{ id = "rforearm", bones = { "RIGHTFOREARM" } },
	{ id = "lhand", bones = { "LEFTHAND" } },
	{ id = "rhand", bones = { "RIGHTHAND" } },
	{ id = "lfemur", bones = { "LEFTUPLEG" } },
	{ id = "rfemur", bones = { "RIGHTUPLEG" } },
	{ id = "lshin", bones = { "LEFTLEG" } },
	{ id = "rshin", bones = { "RIGHTLEG" } },
	{ id = "lfoot", bones = { "LEFTFOOT", "LEFTTOEBASE" } },
	{ id = "rfoot", bones = { "RIGHTFOOT", "RIGHTTOEBASE" } },
}

local bail -- the bail being scored: { points, parts = { id -> state }, ... }
local last -- the last bail, kept while its score shows
local lastTick
local track = {} -- id -> { pos, vel, coolUntil }
local hipsAt

local function Pos(m)
	return Vector(m[4], m[8], m[12])
end

local function PartPos(bones, part)
	local sum, n = Vector(), 0
	for _, name in ipairs(part.bones) do
		local m = bones[name]
		if m then
			sum:Add(Pos(m))
			n = n + 1
		end
	end
	return n > 0 and sum / n or nil
end

local cv_blood = GetConVar("skate3_blood")

-- The server applies injury damage and draws blood for everyone.
local function Tell(index, level)
	net.Start("skate3_injury")
	net.WriteUInt(index, 5)
	net.WriteUInt(level, 2)
	net.SendToServer()
end

local function Bleed(tr, now)
	if not (cv_blood and cv_blood:GetBool()) or now - lastBlood < BLOOD_GAP then return end
	lastBlood = now
	net.Start("skate3_blood")
	net.WriteVector(tr.HitPos)
	net.WriteNormal(tr.HitNormal)
	net.SendToServer()
end

local function Hit(index, state, severity, now)
	state.damage = state.damage + severity
	bail.points = bail.points + severity * severity * HIT_POINTS
	local level = state.level
	if severity >= BREAK_HIT or state.damage >= BREAK_TOTAL then
		level = 2
	elseif severity >= FRACTURE_HIT or state.damage >= FRACTURE_TOTAL then
		level = math.max(level, 1)
	end
	if level > state.level then
		-- The engine's own broken-bone shot: slow motion and a shake.
		if level == 2 and Meat.Enabled() and skate3 and skate3.BrokenBone then skate3.BrokenBone(1) end
		Tell(index, level)
		bail.points = bail.points + (level == 2 and BREAK_POINTS or FRACTURE_POINTS)
			- (state.level == 1 and FRACTURE_POINTS or 0)
		state.level = level
	end
	bail.hitAt = now
end

local told -- the mode switch as the engine last heard it

-- Follows the skater every frame while riding.
function Meat.Update(pose, ply)
	local now = RealTime()
	-- The engine's Hall of Meat switch: it lets the camera do its broken-bone shot.
	if told ~= Meat.Enabled() and skate3 and skate3.SetHallOfMeat then
		told = Meat.Enabled()
		skate3.SetHallOfMeat(told and 1 or 0)
	end
	local bailing = pose and pose.state and pose.state:find("^Wipeout") ~= nil
	if not bailing or not pose.bones then
		if bail then
			last, bail = bail, nil
			last.endedAt = now
		end
		track, lastTick, hipsAt = {}, nil, nil
		return
	end
	if not bail then
		bail = { points = 0, parts = {}, startedAt = now, hitAt = now }
		for _, part in ipairs(PARTS) do bail.parts[part.id] = { damage = 0, level = 0 } end
		last = nil
	end
	-- Only new simulation steps say anything about how the body moved.
	local tick = pose.tick
	if tick == lastTick then return end
	local steps = lastTick and math.Clamp(tick - lastTick, 1, 10) or 1
	lastTick = tick
	local dt = steps * TICK
	local hips = pose.bones.HIPS and Pos(pose.bones.HIPS)
	if hips and hipsAt then
		bail.points = bail.points + hips:Distance(hipsAt) / UNITS * TUMBLE_POINTS
	end
	hipsAt = hips
	for index, part in ipairs(PARTS) do
		local pos = PartPos(pose.bones, part)
		if pos then
			local t = track[part.id]
			if not t then
				track[part.id] = { pos = pos, coolUntil = 0 }
			else
				local vel = (pos - t.pos) / dt
				if t.vel and now >= t.coolUntil then
					local change = (vel - t.vel):Length() / UNITS
					if change >= HIT then
						-- Against something solid, not just the body flailing.
						local reach = t.vel:GetNormalized() * (t.vel:Length() * dt + 6)
						local tr = util.TraceLine({ start = t.pos, endpos = t.pos + reach, mask = MASK_SOLID, filter = ply })
						if tr.Hit then
							Hit(index, bail.parts[part.id], change, now)
							if change >= BLOOD_HIT then Bleed(tr, now) end
							t.coolUntil = now + COOLDOWN
						end
					end
				end
				t.pos, t.vel = pos, vel
			end
		end
	end
end

-- The bail to show: the one going on, or the last one, with its points and
-- injuries; nil when there's none.
function Meat.Current()
	if not Meat.Enabled() then return nil end
	if bail then return bail, true end
	return last, false
end

function Meat.Reset()
	bail, last, track, lastTick, hipsAt = nil, nil, {}, nil, nil
end

-- The skeleton, facing you, in a box `size` tall centred on x, y.
local WHITE = Color(235, 235, 235)
local YELLOW = Color(255, 210, 40)
local RED = Color(255, 50, 40)
local OUTLINE = Color(0, 0, 0, 160)
local LEVEL_COLORS = { [0] = WHITE, YELLOW, RED }

-- Segments on a 100 x 200 grid: part, x1, y1, x2, y2.
local SEGMENTS = {
	{ "spine", 50, 30, 50, 62 },
	{ "ribs", 40, 46, 60, 46 }, { "ribs", 42, 54, 58, 54 },
	{ "spine", 50, 62, 50, 90 },
	{ "pelvis", 38, 92, 62, 92 }, { "pelvis", 38, 92, 50, 100 }, { "pelvis", 62, 92, 50, 100 },
	{ "rcollar", 50, 34, 30, 37 }, { "lcollar", 50, 34, 70, 37 },
	{ "rarm", 30, 37, 24, 70 }, { "larm", 70, 37, 76, 70 },
	{ "rforearm", 24, 70, 20, 100 }, { "lforearm", 76, 70, 80, 100 },
	{ "rhand", 20, 100, 18, 112 }, { "lhand", 80, 100, 82, 112 },
	{ "rfemur", 42, 98, 38, 142 }, { "lfemur", 58, 98, 62, 142 },
	{ "rshin", 38, 142, 37, 184 }, { "lshin", 62, 142, 63, 184 },
	{ "rfoot", 37, 184, 28, 194 }, { "lfoot", 63, 184, 72, 194 },
}

local function Line(x1, y1, x2, y2, w, color)
	local dx, dy = x2 - x1, y2 - y1
	local len = math.sqrt(dx * dx + dy * dy)
	if len <= 0 then return end
	local nx, ny = -dy / len * w / 2, dx / len * w / 2
	surface.SetDrawColor(color)
	draw.NoTexture()
	surface.DrawPoly({
		{ x = x1 + nx, y = y1 + ny }, { x = x2 + nx, y = y2 + ny },
		{ x = x2 - nx, y = y2 - ny }, { x = x1 - nx, y = y1 - ny },
	})
end

local function Circle(cx, cy, r, color)
	local poly = {}
	for i = 0, 19 do
		local a = i / 20 * math.pi * 2
		poly[#poly + 1] = { x = cx + math.cos(a) * r, y = cy + math.sin(a) * r }
	end
	surface.SetDrawColor(color)
	draw.NoTexture()
	surface.DrawPoly(poly)
end

function Meat.DrawSkeleton(x, y, size, alpha, parts)
	local k = size / 200
	local ox, oy = x - 50 * k, y - 100 * k
	local function C(level, a) local c = LEVEL_COLORS[level] or WHITE return ColorAlpha(c, c.a * a) end
	-- Outlines first, so they never cover a bone.
	for pass = 1, 2 do
		local w = (pass == 1 and 7 or 4) * k
		for _, s in ipairs(SEGMENTS) do
			local color = pass == 1 and ColorAlpha(OUTLINE, OUTLINE.a * alpha) or C(parts[s[1]].level, alpha)
			Line(ox + s[2] * k, oy + s[3] * k, ox + s[4] * k, oy + s[5] * k, w, color)
		end
		local skull = pass == 1 and ColorAlpha(OUTLINE, OUTLINE.a * alpha) or C(parts.skull.level, alpha)
		Circle(ox + 50 * k, oy + 16 * k, (pass == 1 and 13 or 11) * k, skull)
	end
end

concommand.Add("skate3_hall_of_meat_toggle", function()
	RunConsoleCommand("skate3_hall_of_meat", Meat.Enabled() and "0" or "1")
	chat.AddText(Color(120, 200, 255), "[skate3] ", color_white,
		"Hall of Meat " .. (Meat.Enabled() and "off" or "on") .. (Meat.Enabled() and "" or ": bails score now. Both triggers and both sticks to bail on purpose."))
end, nil, "Turn Hall of Meat on or off")

return Meat
