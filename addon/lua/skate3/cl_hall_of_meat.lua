-- Injuries, and Hall of Meat after Skate 3's. Each body part is watched
-- while the skater tumbles; a hard hit on something counts, and enough of
-- them fracture or break it. That always runs: the server's bail damage
-- (skate3_bail_damage) charges for injuries and its blood (skate3_blood)
-- splats where the hard hits land. With Hall of Meat on, bails also score,
-- in red, and the skeleton shows through the skater: fractures yellow and
-- breaks red. The engine has no injuries of its own, so the hits are read
-- off the bail's bones here; the numbers are our tuning.
-- Bail on purpose: both triggers and both sticks clicked.
--
-- Every hit is also announced to the rest of the mod with the hook
-- "Skate3BodyHit" (cl_sounds.lua plays the impacts and bone breaks from it, so
-- what you hear is exactly what scored): one table with
--   part      the body part's id ("skull", "lshin"...)
--   bone      the engine bone it's read from
--   severity  how hard it hit, m/s of speed lost in one step
--   pos       where it hit; normal, matType: what it hit
--   level     the part's injury after this hit: 0 sound, 1 fractured, 2 broken
--   injury    set to the new level (1 or 2) when this hit is what hurt it

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

-- Body parts and the bones they're read from.
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
local lastBones -- the skater's bones this frame, for the X-ray
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

local function Hit(index, part, state, severity, now, tr)
	state.damage = state.damage + severity
	bail.points = bail.points + severity * severity * HIT_POINTS
	local level, injury = state.level, nil
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
		injury = level
	end
	bail.hitAt = now
	hook.Run("Skate3BodyHit", {
		part = part.id, bone = part.bones[1], severity = severity, pos = tr.HitPos, normal = tr.HitNormal,
		matType = tr.MatType, level = state.level, injury = injury,
	})
end

local told -- the mode switch as the engine last heard it

-- Follows the skater every frame while riding.
function Meat.Update(pose, ply)
	local now = RealTime()
	lastBones = pose and pose.bones or nil
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
							Hit(index, part, bail.parts[part.id], change, now, tr)
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
	bail, last, track, lastTick, hipsAt, lastBones = nil, nil, {}, nil, nil, nil
end

-- Skate 3's X-ray: the skeleton drawn through the skater's body, while the
-- bail goes on and while its score shows after. Each bone looks like Gmod's
-- Edit Bones view, tinted white, yellow when fractured and red when broken.
local WHITE = Color(235, 235, 235)
local YELLOW = Color(255, 210, 40)
local RED = Color(255, 50, 40)
local LEVEL_COLORS = { [0] = WHITE, YELLOW, RED }
local SHOW_AFTER, FADE = 2.5, 0.5 -- as the score's
-- The bone pictures Edit Bones draws.
local BONE = Material("widgets/bone.png", "unlitsmooth")
local BONE_SMALL = Material("widgets/bone_small.png", "unlitsmooth")

local function LevelColor(level, alpha)
	local c = LEVEL_COLORS[level] or WHITE
	return ColorAlpha(c, 255 * alpha)
end

local function Bone(a, b, color)
	local length = a:Distance(b)
	if length < 0.5 then return end
	render.SetMaterial(length < 6 and BONE_SMALL or BONE)
	render.DrawBeam(a, b, math.Clamp(length * 0.3, 1, 5), 0, 1, color)
end

-- The playermodel's bones and the body part each belongs to: its own, or the
-- nearest parent's (fingers go with the hand, toes with the foot).
local BODY_PARTS = {
	["ValveBiped.Bip01_Pelvis"] = "pelvis", ["ValveBiped.Bip01_Spine"] = "spine",
	["ValveBiped.Bip01_Spine1"] = "ribs", ["ValveBiped.Bip01_Spine2"] = "ribs",
	["ValveBiped.Bip01_Spine4"] = "spine", ["ValveBiped.Bip01_Neck1"] = "spine",
	["ValveBiped.Bip01_Head1"] = "skull",
	["ValveBiped.Bip01_L_Clavicle"] = "lcollar", ["ValveBiped.Bip01_R_Clavicle"] = "rcollar",
	["ValveBiped.Bip01_L_UpperArm"] = "larm", ["ValveBiped.Bip01_R_UpperArm"] = "rarm",
	["ValveBiped.Bip01_L_Forearm"] = "lforearm", ["ValveBiped.Bip01_R_Forearm"] = "rforearm",
	["ValveBiped.Bip01_L_Hand"] = "lhand", ["ValveBiped.Bip01_R_Hand"] = "rhand",
	["ValveBiped.Bip01_L_Thigh"] = "lfemur", ["ValveBiped.Bip01_R_Thigh"] = "rfemur",
	["ValveBiped.Bip01_L_Calf"] = "lshin", ["ValveBiped.Bip01_R_Calf"] = "rshin",
	["ValveBiped.Bip01_L_Foot"] = "lfoot", ["ValveBiped.Bip01_R_Foot"] = "rfoot",
}
local skeletons = {} -- model -> { [bone] = { parent, part } }, ValveBiped bones only

local function SkeletonOf(ent)
	local model = ent:GetModel()
	if skeletons[model] then return skeletons[model] end
	local out, part = {}, {}
	for i = 0, ent:GetBoneCount() - 1 do
		local name = ent:GetBoneName(i) or ""
		local up = ent:GetBoneParent(i)
		part[i] = BODY_PARTS[name] or (up >= 0 and part[up]) or nil
		-- Only the body's own skeleton: hair, capes and tails aren't bones.
		if up >= 0 and part[i] and name:find("^ValveBiped%.Bip01_") then
			out[i] = { parent = up, part = part[i] }
		end
	end
	skeletons[model] = out
	return out
end

-- The body's own bones; false when it has none of the usual ones.
local function DrawBodyBones(body, parts, alpha)
	if not IsValid(body) then return false end
	local any = false
	for i, b in pairs(SkeletonOf(body)) do
		local m, pm = body:GetBoneMatrix(i), body:GetBoneMatrix(b.parent)
		if m and pm then
			Bone(pm:GetTranslation(), m:GetTranslation(), LevelColor(parts[b.part].level, alpha))
			any = true
		end
	end
	return any
end

-- Without a playermodel: the skater's own bones, the same way.
local ENGINE_BONES = {
	{ "HIPS", "SPINE", "pelvis" }, { "SPINE", "SPINE1", "ribs" }, { "SPINE1", "SPINE2", "ribs" },
	{ "SPINE2", "SPINE3", "spine" }, { "SPINE3", "NECK", "spine" }, { "NECK", "HEAD", "skull" },
	{ "SPINE3", "LEFTSHOULDER", "lcollar" }, { "LEFTSHOULDER", "LEFTARM", "lcollar" },
	{ "LEFTARM", "LEFTFOREARM", "larm" }, { "LEFTFOREARM", "LEFTHAND", "lforearm" },
	{ "SPINE3", "RIGHTSHOULDER", "rcollar" }, { "RIGHTSHOULDER", "RIGHTARM", "rcollar" },
	{ "RIGHTARM", "RIGHTFOREARM", "rarm" }, { "RIGHTFOREARM", "RIGHTHAND", "rforearm" },
	{ "HIPS", "LEFTUPLEG", "pelvis" }, { "LEFTUPLEG", "LEFTLEG", "lfemur" },
	{ "LEFTLEG", "LEFTFOOT", "lshin" }, { "LEFTFOOT", "LEFTTOEBASE", "lfoot" },
	{ "HIPS", "RIGHTUPLEG", "pelvis" }, { "RIGHTUPLEG", "RIGHTLEG", "rfemur" },
	{ "RIGHTLEG", "RIGHTFOOT", "rshin" }, { "RIGHTFOOT", "RIGHTTOEBASE", "rfoot" },
}

local function DrawEngineBones(bones, parts, alpha)
	for _, b in ipairs(ENGINE_BONES) do
		local m, n = bones[b[1]], bones[b[2]]
		if m and n then Bone(Pos(m), Pos(n), LevelColor(parts[b[3]].level, alpha)) end
	end
end

hook.Add("PostDrawTranslucentRenderables", "skate3_meat_xray", function(_, skybox)
	if skybox or not lastBones or not Meat.Enabled() or (Meat.Skipped and Meat.Skipped()) then return end
	local b, going = bail, true
	if not b then b, going = last, false end
	if not b then return end
	local alpha = going and 1 or math.Clamp((SHOW_AFTER + FADE - (RealTime() - b.endedAt)) / FADE, 0, 1)
	if alpha <= 0 then return end
	cam.IgnoreZ(true)
	if not (Meat.Body and DrawBodyBones(Meat.Body(), b.parts, alpha)) then
		DrawEngineBones(lastBones, b.parts, alpha)
	end
	cam.IgnoreZ(false)
end)

concommand.Add("skate3_hall_of_meat_toggle", function()
	RunConsoleCommand("skate3_hall_of_meat", Meat.Enabled() and "0" or "1")
	chat.AddText(Color(120, 200, 255), "[skate3] ", color_white,
		"Hall of Meat " .. (Meat.Enabled() and "off" or "on") .. (Meat.Enabled() and "" or ": bails score now. Both triggers and both sticks to bail on purpose."))
end, nil, "Turn Hall of Meat on or off")

return Meat
