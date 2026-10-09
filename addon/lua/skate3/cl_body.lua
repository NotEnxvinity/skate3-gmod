-- Posing a player's real body: theirs, not a copy. While someone skates, Gmod
-- keeps their playermodel frozen on one idle frame and we turn its bones with
-- ManipulateBoneAngles. Gmod applies those inside its own bone setup, so the
-- body's shadow, jiggle bones (hair, tails, capes), eyes, mirrors and every
-- other player's view all see the skating pose.
--
-- Used for your own skater (cl_skater.lua works out the turns) and for other
-- skaters (cl_others.lua, from the pose their game sends).

local Body = {}

---------------------------------------------------------------------------
-- Turns as quaternions, for sending and for blending between two frames.

-- The rotation part of m as { w, x, y, z }.
function Body.Quat(m)
	local t = m:ToTable()
	local m00, m01, m02 = t[1][1], t[1][2], t[1][3]
	local m10, m11, m12 = t[2][1], t[2][2], t[2][3]
	local m20, m21, m22 = t[3][1], t[3][2], t[3][3]
	local trace = m00 + m11 + m22
	local w, x, y, z
	if trace > 0 then
		local s = math.sqrt(trace + 1) * 2
		w, x, y, z = s / 4, (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s
	elseif m00 > m11 and m00 > m22 then
		local s = math.sqrt(1 + m00 - m11 - m22) * 2
		w, x, y, z = (m21 - m12) / s, s / 4, (m01 + m10) / s, (m02 + m20) / s
	elseif m11 > m22 then
		local s = math.sqrt(1 + m11 - m00 - m22) * 2
		w, x, y, z = (m02 - m20) / s, (m01 + m10) / s, s / 4, (m12 + m21) / s
	else
		local s = math.sqrt(1 + m22 - m00 - m11) * 2
		w, x, y, z = (m10 - m01) / s, (m02 + m20) / s, (m12 + m21) / s, s / 4
	end
	return { w, x, y, z }
end

-- A rotation Matrix from { w, x, y, z } (normalised first: it may have come
-- over the network).
function Body.QuatMatrix(q)
	local w, x, y, z = q[1], q[2], q[3], q[4]
	local n = math.sqrt(w * w + x * x + y * y + z * z)
	if n < 1e-6 then return Matrix() end
	w, x, y, z = w / n, x / n, y / n, z / n
	return Matrix({
		{ 1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y), 0 },
		{ 2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x), 0 },
		{ 2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y), 0 },
		{ 0, 0, 0, 1 },
	})
end

function Body.Slerp(a, b, t)
	local d = a[1] * b[1] + a[2] * b[2] + a[3] * b[3] + a[4] * b[4]
	local s = 1
	if d < 0 then d, s = -d, -1 end
	local wa, wb
	if d > 0.9995 then
		wa, wb = 1 - t, t
	else
		local th = math.acos(d)
		local sn = math.sin(th)
		wa, wb = math.sin((1 - t) * th) / sn, math.sin(t * th) / sn
	end
	wb = wb * s
	return { a[1] * wa + b[1] * wb, a[2] * wa + b[2] * wb, a[3] * wa + b[3] * wb, a[4] * wa + b[4] * wb }
end

local function RotOnly(m)
	local r = Matrix(m)
	r:SetTranslation(vector_origin)
	return r
end
Body.RotOnly = RotOnly

---------------------------------------------------------------------------
-- How Gmod applies a bone manipulation isn't documented: whether the turn
-- goes before or after the animation's own, how the angle's three numbers
-- map onto it, and which way the offset points. So it's measured once on a
-- stock model: turn one bone by a known angle, see what the engine made of
-- it, and keep whichever reading matches (the same trick that sorted out the
-- bind pose).

local conv -- { pre, perm, inverse, space } once measured
local convError -- why the last measurement failed

local PERMS = { { 1, 2, 3 }, { 1, 3, 2 }, { 2, 1, 3 }, { 2, 3, 1 }, { 3, 1, 2 }, { 3, 2, 1 } }

local function AngleMatrix(a)
	local m = Matrix()
	m:SetAngles(a)
	return m
end

-- The rotation the engine makes of manipulation angle a, under reading c.
local function ConvMatrix(c, a)
	local v = { a.p, a.y, a.r }
	local m = AngleMatrix(Angle(v[c.perm[1]], v[c.perm[2]], v[c.perm[3]]))
	return c.inverse and m:GetInverseTR() or m
end

local function RotDiff(a, b)
	return (a:GetForward() - b:GetForward()):Length() + (a:GetUp() - b:GetUp()):Length()
		+ (a:GetRight() - b:GetRight()):Length()
end

-- Bones to try the test turn on, the first the model has (with a parent).
local TEST_BONES = { "ValveBiped.Bip01_Spine1", "ValveBiped.Bip01_Spine2", "ValveBiped.Bip01_Spine",
	"ValveBiped.Bip01_L_Forearm", "ValveBiped.Bip01_R_Forearm", "ValveBiped.Bip01_Head1" }

-- Measured on a model that's already loaded and set up fine: the player's
-- own (a stock model made on the spot wasn't always ready yet, and the test
-- then failed). source is that entity, or a model path for a stand-in.
local function Calibrate(source)
	local ent, made = source, false
	if isstring(source) then
		ent, made = ClientsideModel(source, RENDERGROUP_OPAQUE), true
		if not IsValid(ent) then return "couldn't load " .. source end
		ent:SetNoDraw(true)
	end
	if not IsValid(ent) then return "no model to measure on" end
	local function Done(why)
		if made then ent:Remove() end
		return why
	end
	ent:SetPos(vector_origin)
	ent:SetAngles(angle_zero)
	local seq = ent:LookupSequence("idle_all_01")
	ent:ResetSequence(seq and seq >= 0 and seq or 0)
	ent:SetCycle(0)
	ent:SetPlaybackRate(0)
	local bone, parent
	for _, name in ipairs(TEST_BONES) do
		local b = ent:LookupBone(name)
		local p = b and ent:GetBoneParent(b)
		if b and p and p >= 0 then bone, parent = b, p break end
	end
	if not bone then return Done("no spine or arm bones on " .. tostring(ent:GetModel())) end
	local function Read()
		ent:InvalidateBoneCache()
		ent:SetupBones()
		return ent:GetBoneMatrix(parent), ent:GetBoneMatrix(bone)
	end
	local oldAng, oldPos = ent:GetManipulateBoneAngles(bone), ent:GetManipulateBonePosition(bone)
	ent:ManipulateBoneAngles(bone, angle_zero)
	ent:ManipulateBonePosition(bone, vector_origin)
	local P0, B0 = Read()
	local TEST_ANG, TEST_POS = Angle(25, 40, -15), Vector(3, -2, 4)
	ent:ManipulateBoneAngles(bone, TEST_ANG)
	local P1, B1 = Read()
	ent:ManipulateBonePosition(bone, TEST_POS)
	local _, B2 = Read()
	ent:ManipulateBoneAngles(bone, oldAng or angle_zero)
	ent:ManipulateBonePosition(bone, oldPos or vector_origin)
	ent:InvalidateBoneCache()
	Done()
	if not (P0 and B0 and P1 and B1 and B2) then return "the test bone wasn't set up" end
	local L0 = RotOnly(P0):GetInverseTR() * RotOnly(B0) -- local turn, untouched
	local L1 = RotOnly(P1):GetInverseTR() * RotOnly(B1) -- local turn, manipulated
	local post = L0:GetInverseTR() * L1 -- if the manipulation comes after the animation
	local pre = L1 * L0:GetInverseTR() -- if before
	local best, bestErr
	for _, side in ipairs({ { false, post }, { true, pre } }) do
		for _, perm in ipairs(PERMS) do
			for _, inverse in ipairs({ false, true }) do
				local c = { pre = side[1], perm = perm, inverse = inverse }
				local err = RotDiff(ConvMatrix(c, TEST_ANG), side[2])
				if not bestErr or err < bestErr then best, bestErr = c, err end
			end
		end
	end
	if bestErr > 0.05 then
		return ("no reading of the test turn matched (closest off by %.2f)"):format(bestErr)
	end
	-- The offset: in the parent's axes, the bone's before its turn, or after.
	local moved = B2:GetTranslation() - B1:GetTranslation()
	local spaces = {
		parent = RotOnly(P1),
		bone = RotOnly(P1) * L0,
		posed = RotOnly(B1),
	}
	local bestSpace, spaceErr
	for name, m in pairs(spaces) do
		local err = (m * TEST_POS - moved):Length()
		if not spaceErr or err < spaceErr then bestSpace, spaceErr = name, err end
	end
	if spaceErr > 0.5 then
		return ("the test offset landed off by %.1f units"):format(spaceErr)
	end
	best.space = bestSpace
	conv = best
	local axes = { parent = "parent bone's", bone = "bone's own", posed = "turned bone's" }
	print(("[skate3] bone turns apply %s the animation, angles read %d%d%d%s, offsets along the %s axes"):format(
		best.pre and "before" or "after", best.perm[1], best.perm[2], best.perm[3],
		best.inverse and " inverted" or "", axes[bestSpace]))
end

-- Whether real-body posing works here; the reason when it doesn't. The
-- first call measures it, on source (an entity of a loaded model, or a model
-- path); a failed measurement is retried with the next model, at most every
-- few seconds. Without source it only reports.
local retryAt = 0
function Body.Ready(source)
	if conv then return true end
	if source and RealTime() >= retryAt then
		local why = Calibrate(source)
		if why then
			convError = why
			retryAt = RealTime() + 5
			print("[skate3] couldn't measure how bone turns apply: " .. why)
		end
	end
	return conv and true or false, convError
end

function Body.Conv()
	return conv
end

-- The manipulation angle that makes the engine turn a bone by R.
function Body.AnglesFor(R)
	local m = conv.inverse and R:GetInverseTR() or R
	local q = m:GetAngles()
	local qv = { q.p, q.y, q.r }
	local a = {}
	for k = 1, 3 do a[conv.perm[k]] = qv[k] end
	return Angle(a[1], a[2], a[3])
end

-- A bone's world matrix from its parent's, its local in the frozen frame,
-- and our turn R (nil for none).
function Body.Chain(Fp, L, R)
	if not R then return Fp * L end
	if conv.pre then return Fp * R * L end
	return Fp * L * R
end

-- The axes an offset is measured in, for a bone whose parent is at Fp, with
-- local L and world result F.
function Body.OffsetAxes(Fp, L, F)
	if conv.space == "parent" then return RotOnly(Fp) end
	if conv.space == "bone" then return RotOnly(Fp * L) end
	return RotOnly(F)
end

---------------------------------------------------------------------------
-- The frozen frame: the first of these the model has, at its first frame.
local FROZEN = { "idle_all_01", "idle_all_02", "idle_passive", "ragdoll" }

function Body.FrozenSequence(ent)
	for _, name in ipairs(FROZEN) do
		local seq = ent:LookupSequence(name)
		if seq and seq >= 0 then return seq, name end
	end
	return 0, "sequence 0"
end

-- Each bone's local matrix (relative to its parent; the root's relative to
-- the entity) in the frozen frame, read from a stand-in of the same model at
-- the map's origin.
function Body.FrozenLocals(ent)
	ent:SetPos(vector_origin)
	ent:SetAngles(angle_zero)
	local seq, name = Body.FrozenSequence(ent)
	ent:ResetSequence(seq)
	ent:SetCycle(0)
	ent:SetPlaybackRate(0)
	ent:ClearPoseParameters()
	ent:InvalidateBoneCache()
	ent:SetupBones()
	local world, locals, parents = {}, {}, {}
	local count = ent:GetBoneCount()
	for i = 0, count - 1 do world[i] = ent:GetBoneMatrix(i) end
	for i = 0, count - 1 do
		local p = ent:GetBoneParent(i)
		parents[i] = p
		local w = world[i]
		if w then
			local pw = p >= 0 and world[p]
			locals[i] = pw and pw:GetInverse() * w or (p < 0 and Matrix(w)) or nil
		end
	end
	return { locals = locals, parents = parents, count = count, sequence = name }
end

---------------------------------------------------------------------------
-- Players being posed: ply -> { origin, yaw, touched = { [bone] = true } }

local posed = {}

function Body.IsPosed(ply)
	return posed[ply] ~= nil
end

-- frame: { origin = Vector, yaw = number, turns = { [bone] = Matrix },
-- offsets = { [bone] = Vector } }
function Body.Apply(ply, frame)
	if not IsValid(ply) or not conv then return end
	local p = posed[ply]
	if not p then
		p = { touched = {} }
		posed[ply] = p
	end
	p.origin, p.yaw = frame.origin, frame.yaw
	local now = {}
	for i, R in pairs(frame.turns) do
		ply:ManipulateBoneAngles(i, Body.AnglesFor(R))
		now[i] = true
	end
	for i, v in pairs(frame.offsets or {}) do
		ply:ManipulateBonePosition(i, v)
		now[i] = true
	end
	-- Bones turned last frame but not this one go back to normal.
	for i in pairs(p.touched) do
		if not now[i] then
			ply:ManipulateBoneAngles(i, angle_zero)
			ply:ManipulateBonePosition(i, vector_origin)
		end
	end
	p.touched = now
	ply:InvalidateBoneCache()
end

function Body.Release(ply)
	local p = posed[ply]
	posed[ply] = nil
	if not p or not IsValid(ply) then return end
	-- Back to where the engine puts it.
	pcall(ply.SetRenderOrigin, ply)
	pcall(ply.SetRenderAngles, ply)
	for i in pairs(p.touched) do
		ply:ManipulateBoneAngles(i, angle_zero)
		ply:ManipulateBonePosition(i, vector_origin)
	end
	ply:InvalidateBoneCache()
end

local function Place(ply)
	local p = posed[ply]
	if not p or not p.origin then return end
	ply:SetRenderOrigin(p.origin)
	ply:SetRenderAngles(Angle(0, p.yaw, 0))
end

-- Gmod animates players every frame; while posed, the body holds the frozen
-- frame instead, with no gestures, and sits where the skater is (moved every
-- frame on this screen, not 20 times a second as the server sees it).
hook.Add("CalcMainActivity", "skate3_body", function(ply)
	if not posed[ply] then return end
	ply:SetCycle(0)
	return ACT_MP_STAND_IDLE, (Body.FrozenSequence(ply))
end)

hook.Add("UpdateAnimation", "skate3_body", function(ply)
	if not posed[ply] then return end
	ply:SetPlaybackRate(0)
	ply:SetCycle(0)
	ply:ClearPoseParameters()
	Place(ply)
	return true
end)

hook.Add("DoAnimationEvent", "skate3_body", function(ply)
	if posed[ply] then return ACT_INVALID end
end)

hook.Add("PreRender", "skate3_body", function()
	for ply in pairs(posed) do
		if IsValid(ply) then Place(ply) else posed[ply] = nil end
	end
end)

hook.Add("PrePlayerDraw", "skate3_body", function(ply)
	if posed[ply] then Place(ply) end
end)

---------------------------------------------------------------------------
-- The board, drawn by a small entity of its own per skater (a render hook can
-- be skipped by another addon's hook returning a value; an entity can't).

local boards = {} -- ply -> clientside entity
local BOARD_MIN, BOARD_MAX = Vector(-16, -4, 0), Vector(16, 4, 1.5)
local BOARD_COLOR = Color(70, 60, 50)

-- pose: { pos = { x, y, z }, bones = { name = 12 numbers }, forward, up }.
-- draw(pose) draws the real board and returns false when it can't.
function Body.ShowBoard(ply, pose, draw)
	local e = boards[ply]
	if not IsValid(e) then
		e = ClientsideModel("models/props_junk/PopCan01a.mdl", RENDERGROUP_OPAQUE)
		if not IsValid(e) then return end
		e:SetRenderBounds(Vector(-96, -96, -64), Vector(96, 96, 128))
		e.RenderOverride = function(self)
			local p = self.skate3Pose
			if not p then return end
			if not self.skate3Draw(p) and p.forward and p.up then
				-- No Skate 3 data on this computer: a plain deck instead.
				render.SetColorMaterial()
				render.DrawBox(Vector(p.pos[1], p.pos[2], p.pos[3]), p.forward:AngleEx(p.up),
					BOARD_MIN, BOARD_MAX, BOARD_COLOR, true)
			end
		end
		e:DrawShadow(false)
		boards[ply] = e
	end
	e.skate3Pose, e.skate3Draw = pose, draw
	e:SetPos(Vector(pose.pos[1], pose.pos[2], pose.pos[3]))
	e:SetNoDraw(false)
end

function Body.HideBoard(ply)
	local e = boards[ply]
	if IsValid(e) then e:Remove() end
	boards[ply] = nil
end

return Body
