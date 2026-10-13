-- Injuries, and Hall of Meat after Skate 3's. Each body part is watched
-- while the skater tumbles; a hard hit on something counts, and enough of
-- them fracture or break it. That always runs: the server's bail damage
-- (skate3_bail_damage) charges for injuries and its blood (skate3_blood)
-- splats where the hard hits land. With Hall of Meat on, bails also score,
-- in red, and the skeleton shows through the skater: fractures yellow and
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
	bail, last, track, lastTick, hipsAt, lastBones = nil, nil, {}, nil, nil, nil
end

-- Skate 3's X-ray: the skeleton drawn through the skater's body, each bone
-- white, yellow when fractured and red when broken, while the bail goes on
-- and while its score shows after.
local WHITE = Color(235, 235, 235)
local YELLOW = Color(255, 210, 40)
local RED = Color(255, 50, 40)
local OUTLINE = Color(0, 0, 0, 170)
local LEVEL_COLORS = { [0] = WHITE, YELLOW, RED }
local SHOW_AFTER, FADE = 2.5, 0.5 -- as the score's

-- Bones joined, and the body part each one belongs to.
local BONES = {
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
-- Joints drawn as knobs, with the part they show.
local KNOBS = {
	{ "HEAD", "skull", 4.5 }, { "LEFTHAND", "lhand", 1.6 }, { "RIGHTHAND", "rhand", 1.6 },
	{ "LEFTARM", "larm", 1.3 }, { "RIGHTARM", "rarm", 1.3 }, { "LEFTLEG", "lshin", 1.4 }, { "RIGHTLEG", "rshin", 1.4 },
}

local function LevelColor(level, alpha)
	local c = LEVEL_COLORS[level] or WHITE
	return ColorAlpha(c, c.a * alpha)
end

local function DrawXray(bones, parts, alpha)
	local at = {}
	for name, m in pairs(bones) do at[name] = Pos(m) end
	local shade = ColorAlpha(OUTLINE, OUTLINE.a * alpha)
	render.SetColorMaterial()
	-- Ribs: hoops across the chest, side to side between the shoulders.
	local side = at.LEFTSHOULDER and at.RIGHTSHOULDER and (at.LEFTSHOULDER - at.RIGHTSHOULDER):GetNormalized()
	local ribs = {}
	if side then
		for _, pair in ipairs({ { "SPINE1", 0.55 }, { "SPINE2", 0.8 }, { "SPINE2", 0.4 } }) do
			local c = at[pair[1]]
			if c then
				local half = side * (at.LEFTSHOULDER:Distance(at.RIGHTSHOULDER) * 0.5 * pair[2] + 2)
				ribs[#ribs + 1] = { c - half, c + half }
			end
		end
	end
	for pass = 1, 2 do
		local width = pass == 1 and 2.4 or 1.4
		for _, b in ipairs(BONES) do
			local a, z = at[b[1]], at[b[2]]
			if a and z then render.DrawBeam(a, z, width, 0, 1, pass == 1 and shade or LevelColor(parts[b[3]].level, alpha)) end
		end
		for _, r in ipairs(ribs) do
			render.DrawBeam(r[1], r[2], width * 0.8, 0, 1, pass == 1 and shade or LevelColor(parts.ribs.level, alpha))
		end
		for _, k in ipairs(KNOBS) do
			local p = at[k[1]]
			if p then render.DrawSphere(p, k[3] + (pass == 1 and 0.6 or 0), 10, 10, pass == 1 and shade or LevelColor(parts[k[2]].level, alpha)) end
		end
	end
end

-- Gmod's own skeleton model, posed bone for bone like the skater's body and
-- drawn once per injury level with every other bone shrunk away, so each
-- bone takes its own colour. The lines above stand in when it can't be.
local SKELETON = "models/player/skeleton.mdl"
local SKELETON_PARTS = {
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
local skeleton, skeletonFailed
local skel = { pass = nil, parts = nil, from = {}, part = {} } -- this draw's state
local GONE = Vector(0.001, 0.001, 0.001)

-- Each skeleton bone's part: its own, or the nearest parent's (fingers go
-- with the hand, toes with the foot).
local function SkeletonParts(e)
	local part = {}
	for i = 0, e:GetBoneCount() - 1 do
		local p = SKELETON_PARTS[e:GetBoneName(i)]
		local up = e:GetBoneParent(i)
		part[i] = p or (up >= 0 and part[up]) or "pelvis"
	end
	return part
end

local function Skeleton()
	if IsValid(skeleton) or skeletonFailed then return skeleton end
	if not util.IsValidModel(SKELETON) then skeletonFailed = true return nil end
	skeleton = ClientsideModel(SKELETON, RENDERGROUP_OPAQUE)
	if not IsValid(skeleton) then skeletonFailed = true return nil end
	skeleton:SetNoDraw(true)
	skeleton:SetLOD(0)
	skel.part = SkeletonParts(skeleton)
	skeleton:AddCallback("BuildBonePositions", function(e, count)
		for i = 0, count - 1 do
			local m = skel.from[i]
			if m then
				if skel.pass and skel.parts and skel.parts[skel.part[i]].level ~= skel.pass then
					m = Matrix(m)
					m:Scale(GONE)
				end
				e:SetBoneMatrix(i, m)
			end
		end
	end)
	return skeleton
end

-- Draws the skeleton in body's pose; false when it can't.
local function DrawSkeletonModel(body, parts, alpha)
	local e = Skeleton()
	if not IsValid(e) or not IsValid(body) then return false end
	-- Where each of the skeleton's bones is on the body right now.
	local from, any = {}, false
	for i = 0, e:GetBoneCount() - 1 do
		local b = body:LookupBone(e:GetBoneName(i))
		local m = b and body:GetBoneMatrix(b)
		if m then from[i], any = m, true end
	end
	if not any then return false end
	-- Bones the body doesn't have go with their parent, shrunk away.
	for i = 0, e:GetBoneCount() - 1 do
		if not from[i] then
			local up = e:GetBoneParent(i)
			if up >= 0 and from[up] then
				local m = Matrix(from[up])
				m:Scale(GONE)
				from[i] = m
			end
		end
	end
	skel.from, skel.parts = from, parts
	local levels = {}
	for _, state in pairs(parts) do levels[state.level] = true end
	e:SetPos(body:GetPos())
	-- Over everything, as an X-ray, but in front of and behind itself.
	render.ClearDepth()
	render.SetBlend(alpha)
	for level = 0, 2 do
		if levels[level] then
			local c = LEVEL_COLORS[level]
			skel.pass = level
			render.SetColorModulation(c.r / 255, c.g / 255, c.b / 255)
			e:InvalidateBoneCache()
			e:SetupBones()
			e:DrawModel()
		end
	end
	render.SetColorModulation(1, 1, 1)
	render.SetBlend(1)
	skel.pass, skel.from, skel.parts = nil, {}, nil
	return true
end

hook.Add("PostDrawTranslucentRenderables", "skate3_meat_xray", function(_, skybox)
	if skybox or not lastBones or not Meat.Enabled() then return end
	local b, going = bail, true
	if not b then b, going = last, false end
	if not b then return end
	local alpha = going and 1 or math.Clamp((SHOW_AFTER + FADE - (RealTime() - b.endedAt)) / FADE, 0, 1)
	if alpha <= 0 then return end
	if Meat.Body and DrawSkeletonModel(Meat.Body(), b.parts, alpha) then return end
	cam.IgnoreZ(true)
	DrawXray(lastBones, b.parts, alpha)
	cam.IgnoreZ(false)
end)

concommand.Add("skate3_hall_of_meat_toggle", function()
	RunConsoleCommand("skate3_hall_of_meat", Meat.Enabled() and "0" or "1")
	chat.AddText(Color(120, 200, 255), "[skate3] ", color_white,
		"Hall of Meat " .. (Meat.Enabled() and "off" or "on") .. (Meat.Enabled() and "" or ": bails score now. Both triggers and both sticks to bail on purpose."))
end, nil, "Turn Hall of Meat on or off")

return Meat
