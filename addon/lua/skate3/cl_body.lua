-- Posing a player's real body: theirs, not a copy. While someone skates, Gmod
-- keeps their playermodel frozen on one idle frame and we turn its bones with
-- ManipulateBoneAngles. Gmod applies those inside its own bone setup, so the
-- body's shadow, jiggle bones (hair, tails, capes), eyes, mirrors and every
-- other player's view all see the skating pose.
--
-- Used for your own skater (cl_skater.lua works out the pose) and for other
-- skaters (cl_others.lua, from the pose their game sends). The pose comes in
-- as each bone's world turn relative to the skater's facing; the turns that
-- get there are worked out here, against where the engine has the player
-- right now and how the body really holds its frozen frame.

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
function Body.FrozenLocals(ent, rest)
	-- The model's rest pose first (Body.RestOf comes from cl_skater.lua).
	if not rest and Body.RestOf then rest = Body.RestOf(ent) end
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
	-- Bones off the ValveBiped skeleton (Master Chief's real body bones,
	-- Maxine's toes, hair, tails) are carried along with their parent. On
	-- proportion-trick models the animation puts the ValveBiped bones at
	-- stock lengths and these bones make up the difference; our skeleton
	-- already has the model's own lengths, so carrying the engine's offset
	-- counted it twice (Chief's long neck). So the offset from the rest
	-- pose is used, plus whatever the engine moved them since the frozen
	-- frame (jiggle): carry[i] = rest local * frozen local ^-1.
	local carry = {}
	for i = 0, count - 1 do
		local p = parents[i]
		local name = ent:GetBoneName(i) or ""
		if p >= 0 and rest and rest[i] and rest[p] and locals[i]
			and not name:find("^ValveBiped%.Bip01_") then
			local rl = rest[p]:GetInverseTR() * rest[i]
			carry[i] = rl * locals[i]:GetInverseTR()
		end
	end
	-- Where the eyes sit on the head, for aiming them (see EyesAhead).
	local head = ent:LookupBone("ValveBiped.Bip01_Head1")
	local eyes
	local id = head and world[head] and ent.LookupAttachment and ent:LookupAttachment("eyes")
	local att = id and id > 0 and ent:GetAttachment(id)
	if att then
		local m = Matrix()
		m:SetAngles(att.Ang)
		m:SetTranslation(att.Pos)
		eyes = world[head]:GetInverse() * m
	end
	return { locals = locals, parents = parents, count = count, sequence = name, head = head, eyes = eyes, carry = carry }
end

-- The frozen frame of another player's model, from a stand-in of it (once
-- per model; a model that isn't ready is tried again a few seconds later).
local bases, baseRetry = {}, {}
function Body.BaseFor(ply)
	local name = ply:GetModel()
	if bases[name] then return bases[name] end
	if RealTime() < (baseRetry[name] or 0) then return nil end
	baseRetry[name] = RealTime() + 3
	local e = ClientsideModel(name, RENDERGROUP_OPAQUE)
	if not IsValid(e) then return nil end
	e:SetNoDraw(true)
	local b = Body.FrozenLocals(e)
	e:Remove()
	if next(b.locals) == nil then return nil end
	bases[name] = b
	return b
end

---------------------------------------------------------------------------
-- Players being posed. Per player:
--   base      the frozen frame of their model (Body.FrozenLocals)
--   measured  bone -> its local turn as their body really holds the frozen
--             frame, read off the body itself (nil until it's steady)
--   frame     the pose last asked for (see Body.Apply)
--   E         where the engine had the body when the turns were worked out
--   applied   bone -> the turn set on it

local posed = {}

-- The rotation part of m with clean axes (bone matrices can carry scale).
local function Ortho(m)
	local f, r, u = m:GetForward(), m:GetRight(), m:GetUp()
	f:Normalize() r:Normalize() u:Normalize()
	local o = Matrix({
		{ f.x, -r.x, u.x, 0 },
		{ f.y, -r.y, u.y, 0 },
		{ f.z, -r.z, u.z, 0 },
		{ 0, 0, 0, 1 },
	})
	return o
end

-- How far apart two turns are, in degrees.
local function TurnBetween(a, b)
	local t = (RotOnly(a):GetInverseTR() * RotOnly(b)):ToTable()
	local c = math.Clamp((t[1][1] + t[2][2] + t[3][3] - 1) / 2, -1, 1)
	return math.deg(math.acos(c))
end
Body.TurnBetween = TurnBetween

-- Where the engine puts the body this moment: the player's own position and
-- facing. The body isn't moved there by us any more (Gmod resets a player's
-- render angles every frame, and the position only updates 20 times a
-- second); instead the hips are shifted from wherever that is to the skater.
local function EngineE(ply)
	local ang = ply.GetRenderAngles and ply:GetRenderAngles() or ply:GetAngles()
	local E = Matrix()
	E:SetAngles(Angle(0, ang.y, 0))
	E:SetTranslation(ply:GetPos())
	return E
end
Body.EngineE = EngineE

local function SameE(a, b)
	return b and (a:GetTranslation() - b:GetTranslation()):LengthSqr() < 1e-4
		and (a:GetForward() - b:GetForward()):LengthSqr() < 1e-8
end

-- A bone's local matrix: the turn the body really holds once measured, the
-- frozen frame's until then; the offset from its parent is always the frozen
-- frame's.
local function Local(p, i)
	local L = p.base.locals[i]
	local m = L and p.measured and p.measured[i]
	if not m then return L end
	local r = Matrix(m)
	r:SetTranslation(L:GetTranslation())
	return r
end

-- Work out and set every turn and offset for the body placed at E.
local function Solve(ply, p, E)
	local f, base = p.frame, p.base
	local E0 = Matrix()
	E0:SetAngles(Angle(0, f.yaw, 0))
	E0:SetTranslation(f.origin)
	local face = RotOnly(E0)
	local F, turns, offsets = {}, {}, {}
	for i = 0, base.count - 1 do
		local par = base.parents[i]
		local L = p.needed[i] and Local(p, i)
		local Fp = par >= 0 and F[par] or (par < 0 and E) or nil
		if L and Fp then
			local want = f.rots[i] and face * f.rots[i]
			-- Bones at the top of the skeleton stay with the skater too,
			-- wherever the engine has the player.
			if par < 0 and not want then want = face * RotOnly(L) end
			local R
			if want then
				local lr = RotOnly(L)
				if conv.pre then
					R = RotOnly(Fp):GetInverseTR() * want * lr:GetInverseTR()
				else
					R = (RotOnly(Fp) * lr):GetInverseTR() * want
				end
				turns[i] = R
			end
			local Fi = Body.Chain(Fp, L, R)
			local at
			if i == f.hips and f.hipsAt then
				at = E0 * f.hipsAt
			elseif par < 0 then
				at = E0 * L:GetTranslation()
			end
			if at then
				offsets[i] = Body.OffsetAxes(Fp, L, Fi):GetInverseTR() * (at - Fi:GetTranslation())
				Fi:SetTranslation(at)
			end
			F[i] = Fi
		end
	end
	for i, R in pairs(turns) do ply:ManipulateBoneAngles(i, Body.AnglesFor(R)) end
	for i, v in pairs(offsets) do ply:ManipulateBonePosition(i, v) end
	-- Bones set last time but not this time go back to normal.
	for i in pairs(p.applied or {}) do
		if not turns[i] then ply:ManipulateBoneAngles(i, angle_zero) end
	end
	for i in pairs(p.moved or {}) do
		if not offsets[i] then ply:ManipulateBonePosition(i, vector_origin) end
	end
	p.applied, p.moved, p.E = turns, offsets, E
	p.want = F
end

-- Reads how the body really holds its frozen frame: each bone's turn from
-- its parent, as the engine set it up, minus the turn we put on it. Gmod can
-- hold a slightly different frame than the copy we measured (layers the
-- player animation adds, aim pose parameters), and every turn that's off
-- there shows up straight in the pose: arms bent back, say. Each bone's
-- reading is taken once it holds steady for a few frames, then kept for the
-- ride; a bone that never settles (the engine skipping it, say) keeps the
-- copy's.
local STEADY = 5
local GIVE_UP = 300

-- A bone matrix worth reading: real numbers, axes about unit length (a
-- bone the engine skipped can hold zeros or junk).
local function Sane(m)
	for _, v in ipairs({ m:GetForward(), m:GetUp(), m:GetRight() }) do
		local l = v:Length()
		if not (l > 0.5 and l < 2) then return false end
	end
	local t = m:GetTranslation()
	return t.x == t.x and math.abs(t.x) + math.abs(t.y) + math.abs(t.z) < 1e6
end

-- Forearms, hands and fingers aren't read: Gmod's own IK moves them after
-- our turns (pulling the hands to where a weapon would be held), and fingers
-- aren't set up every time on some models. The finishing step places them.
local function IsHand(name)
	return name:find("Forearm") ~= nil or name:find("_Hand$") ~= nil or name:find("Finger") ~= nil
end

local function SkipMeasure(ply, p, i)
	p.skipMeasure = p.skipMeasure or {}
	local skip = p.skipMeasure[i]
	if skip == nil then
		skip = IsHand(ply:GetBoneName(i) or "")
		p.skipMeasure[i] = skip
	end
	return skip
end

local function Measure(ply, p, get)
	if p.measureDone or not p.applied then return end
	p.tries = (p.tries or 0) + 1
	p.measured = p.measured or {}
	p.last = p.last or {}
	p.steady = p.steady or {}
	local parents, locals = p.base.parents, p.base.locals
	local open = 0
	for i in pairs(p.needed) do
		local par, L = parents[i], locals[i]
		if par and par >= 0 and L and not p.measured[i] and not SkipMeasure(ply, p, i) then
			local Fp, Fi = get[par], get[i]
			if Fp and Fi and Sane(Fp) and Sane(Fi) then
				local m = Ortho(Fp):GetInverseTR() * Ortho(Fi)
				local R = p.applied[i]
				if R then m = conv.pre and R:GetInverseTR() * m or m * R:GetInverseTR() end
				local was = p.last[i]
				p.steady[i] = (was and TurnBetween(was, m) < 1) and (p.steady[i] or 0) + 1 or 0
				p.last[i] = m
				if p.steady[i] >= STEADY then p.measured[i] = m end
			end
			if not p.measured[i] then open = open + 1 end
		end
	end
	if open > 0 and p.tries <= GIVE_UP then return end
	p.measureDone = true
	local worst, worstBone, count = 0, nil, 0
	for i, m in pairs(p.measured) do
		count = count + 1
		local d = locals[i] and TurnBetween(locals[i], m) or 0
		if d > worst then worst, worstBone = d, i end
	end
	p.measuredWorst, p.measuredBone, p.unsteady = worst, worstBone, open
	local who = ply == LocalPlayer() and "your" or ((ply.Nick and ply:Nick() or "a player") .. "'s")
	print(("[skate3] read how %s body really stands: %d bones%s, biggest difference from the copy %.0f degrees (%s)"):format(
		who, count, open > 0 and (", " .. open .. " never held still (kept the copy's)") or "",
		worst, worstBone and tostring(ply:GetBoneName(worstBone)) or "none"))
end

-- Where the engine really had the player when the body was last set up:
-- the top bone of the skeleton as it came out, less what we did to it (its
-- frozen local, our turn and shift). Gmod's own idea of which way a player
-- faces (GetRenderAngles) turned out not to be the one it poses with, so
-- this is read off the body every frame instead of trusted.
local function ReadE(p, get)
	if not (p.applied and p.needed) then return nil end
	for i = 0, p.base.count - 1 do
		local L = p.base.parents[i] < 0 and p.needed[i] and Local(p, i)
		local got = L and get[i]
		if got then
			local X = Body.Chain(Matrix(), L, p.applied[i])
			local off = p.moved and p.moved[i]
			if off then X:SetTranslation(X:GetTranslation() + Body.OffsetAxes(Matrix(), L, X) * off) end
			local G = Ortho(got)
			G:SetTranslation(got:GetTranslation())
			local E = G * X:GetInverseTR()
			-- Clean axes, or rounding builds up frame after frame.
			local clean = Ortho(E)
			clean:SetTranslation(E:GetTranslation())
			return clean
		end
	end
	return nil
end

-- The finishing step, run by the engine at the very end of each bone setup
-- (after its own IK, helper bones and jiggle bones). The turns above only
-- nudge the body, and Gmod changes things after them (it pulls the hands to
-- where a weapon would be held, works out wrist and elbow helpers from the
-- arms it had), so on their own they never quite gave the copy's pose. Here
-- the skeleton is set to exactly the copy's finished pose (frame.final), and
-- every other bone (hair, tails, capes, helpers) is carried along with its
-- parent, keeping whatever the engine made of it: jiggle bones keep
-- swinging, since the turns above already moved the body nearly there.
local cv_carry = CreateClientConVar("skate3_body_carry", "1", true, false,
	"Bones off the skeleton (toes, hair, armour) keep the model's own offsets (0 = the engine's, the older way)")

local function PlaceAll(ply, count)
	local p = posed[ply]
	if not (p and p.base) then return end
	local n = math.min(count, p.base.count)
	local old = {}
	for i = 0, n - 1 do old[i] = ply:GetBoneMatrix(i) end
	-- What the engine made of the body is read right here, from this very
	-- setup: where it really put the player, and how it holds its frame.
	-- (An extra setup of our own each frame to read it, as before, ran the
	-- jiggle bones once more at a slightly stale spot and made tails twitch.)
	local E = ReadE(p, old)
	-- Measured against where the player is right now, not where it was
	-- when the pose was worked out: a server update landing in between
	-- otherwise got folded into the fix, the next pose put the body that
	-- far off, and tails/capes/hair got yanked back every update.
	if E then p.fix = EngineE(ply):GetInverseTR() * E end
	if p.needed then Measure(ply, p, old) end
	local final, parents = p.final, p.base.parents
	if not final then return end
	local carry, carryOn = p.base.carry or {}, cv_carry:GetBool()
	local new = {}
	for i = 0, n - 1 do
		local was = old[i]
		if was then
			local m = final[i]
			if not m then
				local par = parents[i]
				if par and par >= 0 and new[par] and old[par] then
					-- A bone scaled to nothing has no inverse.
					local inv = old[par]:GetInverse() or old[par]:GetInverseTR()
					local k = carryOn and carry[i]
					m = k and new[par] * k * inv * was or new[par] * inv * was
				end
			end
			if m then
				new[i] = m
				ply:SetBoneMatrix(i, m)
			end
		end
	end
end

local function MarkNeeded(p)
	local needed, parents = {}, p.base.parents
	for i in pairs(p.frame.rots) do
		local j = i
		while j and j >= 0 and not needed[j] do
			needed[j] = true
			j = parents[j]
		end
	end
	if p.frame.hips then
		local j = p.frame.hips
		while j and j >= 0 and not needed[j] do
			needed[j] = true
			j = parents[j]
		end
	end
	for i = 0, p.base.count - 1 do
		if parents[i] < 0 then needed[i] = true end
	end
	p.needed = needed
end

function Body.IsPosed(ply)
	return posed[ply] ~= nil
end

local BIG_MIN, BIG_MAX = Vector(-160, -160, -80), Vector(160, 160, 200)

-- frame: { origin = Vector, yaw = number, rots = { [bone] = Matrix, each
-- bone's world turn relative to the facing yaw }, hips = bone index,
-- hipsAt = Vector (where the hips go, from origin, in the facing's axes),
-- final = { [bone] = Matrix, the finished world pose the skeleton is set to
-- at the end of each setup } }.
-- base: the model's frozen frame (Body.FrozenLocals).
-- The body is drawn at the skater, which can be a long way from where the
-- engine has the player (behind a fast skater, or on a laggy connection).
-- Gmod skips drawing anything whose box is off screen, and the box goes
-- with the player, so it's stretched to take in the skater too.
local function Reach(ply, p, at)
	if not at then return end
	local d = at - ply:GetPos()
	local key = math.floor(d.x / 64) .. "," .. math.floor(d.y / 64) .. "," .. math.floor(d.z / 64)
	if key == p.boundsKey then return end
	p.boundsKey = key
	-- Render bounds turn with the player's render angles; a box that's
	-- the same size every way round doesn't care which way that is.
	local r = d:Length() + 64
	local mins, maxs = Vector(-r, -r, -r), Vector(r, r, r)
	mins.x, mins.y, mins.z = math.min(mins.x, BIG_MIN.x), math.min(mins.y, BIG_MIN.y), math.min(mins.z, BIG_MIN.z)
	maxs.x, maxs.y, maxs.z = math.max(maxs.x, BIG_MAX.x), math.max(maxs.y, BIG_MAX.y), math.max(maxs.z, BIG_MAX.z)
	pcall(ply.SetRenderBounds, ply, mins, maxs)
end

function Body.Apply(ply, frame, base)
	if not IsValid(ply) or not conv or not base then return end
	local p = posed[ply]
	if p and p.base ~= base then
		-- A new model: its bones are numbered differently. Let go of
		-- everything the last one left (its bone turns and offsets, the
		-- correction measured on it) as getting off the board does, or a
		-- model that came out stretched kept every later one stretched.
		Body.Release(ply)
		p = nil
	end
	if not p then
		p = {}
		posed[ply] = p
		-- The body can be a little way from where the engine thinks the
		-- player is; don't let it vanish at the screen's edge.
		pcall(ply.SetRenderBounds, ply, BIG_MIN, BIG_MAX)
		-- Full detail: further away Gmod skips small bones (fingers), and
		-- they'd hold whatever they had last.
		pcall(ply.SetLOD, ply, 0)
		p.callback = ply:AddCallback("BuildBonePositions", PlaceAll)
	end
	if p.base ~= base then
		-- A new model: its bones are numbered differently, start over.
		p.base, p.needed, p.measured, p.last, p.steady, p.tries, p.measureDone = base, nil, nil, nil, nil, 0, false
		p.skipMeasure = nil
	end
	-- Pose parameters (aiming, mostly) bend the frozen frame: keep them flat.
	ply:ClearPoseParameters()
	local guess = EngineE(ply)
	p.frame = frame
	p.final = frame.final
	MarkNeeded(p)
	Solve(ply, p, p.fix and guess * p.fix or guess)
	p.guess = guess
	Reach(ply, p, frame.origin)
	ply:InvalidateBoneCache()
end

function Body.Release(ply)
	local p = posed[ply]
	posed[ply] = nil
	if not p or not IsValid(ply) then return end
	for i in pairs(p.applied or {}) do ply:ManipulateBoneAngles(i, angle_zero) end
	for i in pairs(p.moved or {}) do ply:ManipulateBonePosition(i, vector_origin) end
	pcall(ply.SetLOD, ply, -1)
	if p.callback then ply:RemoveCallback("BuildBonePositions", p.callback) end
	if ply.GetModelRenderBounds then
		local mins, maxs = ply:GetModelRenderBounds()
		if mins and maxs then pcall(ply.SetRenderBounds, ply, mins, maxs) end
	end
	ply:InvalidateBoneCache()
end

-- Right before the body is drawn: if the engine has moved or turned the
-- player since the turns were worked out (a position update from the
-- server, the camera turning the player), shift the top of the skeleton so
-- the body stays exactly on the skater.
-- The eyes look where the posed head faces. The player's own eye target is
-- a spot worked out from where the engine has them aiming, which has nothing
-- to do with the head we posed, so they stared off one way.
local function EyesAhead(ply, p)
	local b = p.base
	local head = b and b.eyes and p.final and p.final[b.head]
	if not head then return end
	local m = head * b.eyes
	ply:SetEyeTarget(m:GetTranslation() + m:GetForward() * 200)
end

local function Follow(ply)
	local p = posed[ply]
	if not p or not p.frame then return end
	EyesAhead(ply, p)
	local fresh = p.drawFrame ~= FrameNumber()
	p.drawFrame = FrameNumber()
	if fresh then ply:ClearPoseParameters() end
	local guess = EngineE(ply)
	if not SameE(guess, p.guess) then
		Solve(ply, p, p.fix and guess * p.fix or guess)
		p.guess = guess
		fresh = true
	end
	if fresh then ply:InvalidateBoneCache() end
end

-- What's known about a posed body, for skate3_body_report.
function Body.Report(ply)
	local p = posed[ply]
	if not p or not p.frame then return { "not posed right now" } end
	local lines = {}
	local E, f = EngineE(ply), p.frame
	local yawOff = math.AngleDifference(E:GetAngles().y, f.yaw)
	lines[#lines + 1] = ("engine has the player %.1f units from the skater, facing %.0f degrees off"):format(
		E:GetTranslation():Distance(f.origin), yawOff)
	if p.fix then
		lines[#lines + 1] = ("read off the body: it's really posed %.1f units and %.0f degrees from where Gmod says the player is"):format(
			p.fix:GetTranslation():Length(), TurnBetween(Matrix(), p.fix))
	end
	if p.measureDone then
		lines[#lines + 1] = ("frame read off the body: biggest difference from the copy %.1f degrees (%s), %d bones never held still"):format(
			p.measuredWorst or 0, tostring(p.measuredBone and ply:GetBoneName(p.measuredBone)), p.unsteady or 0)
		for i in pairs(p.needed or {}) do
			if p.base.parents[i] and p.base.parents[i] >= 0 and not (p.measured and p.measured[i]) then
				lines[#lines + 1] = "  never held still: " .. tostring(ply:GetBoneName(i))
			end
		end
	else
		lines[#lines + 1] = ("still reading the frame off the body (%d tries)"):format(p.tries or 0)
	end
	ply:SetupBones()
	local rows = {}
	for i, want in pairs(p.final or p.want or {}) do
		local got = ply:GetBoneMatrix(i)
		if got then
			rows[#rows + 1] = { i = i, turn = TurnBetween(Ortho(got), want), off = got:GetTranslation():Distance(want:GetTranslation()) }
		end
	end
	table.sort(rows, function(a, b) return a.turn > b.turn end)
	lines[#lines + 1] = "bone: how far off where it should be (turn in degrees, position in units), worst first"
	for n = 1, math.min(#rows, 12) do
		local r = rows[n]
		lines[#lines + 1] = ("  %-34s %6.1f  %6.1f"):format(tostring(ply:GetBoneName(r.i)), r.turn, r.off)
	end
	return lines
end

-- Gmod animates players every frame; while posed, the body holds the frozen
-- frame instead, with no gestures.
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
	return true
end)

hook.Add("DoAnimationEvent", "skate3_body", function(ply)
	if posed[ply] then return ACT_INVALID end
end)

hook.Add("PrePlayerDraw", "skate3_body", function(ply)
	if posed[ply] then Follow(ply) end
end)

-- And once at the very start of every rendered frame, once the engine has
-- moved everyone to where they are this frame: shadows and the like set the
-- body up before PrePlayerDraw ever runs, and with turns worked out for
-- last frame's position the tail/cape/hair physics got a body that jumped
-- away and back each frame the player moved.
hook.Add("PreRender", "skate3_body", function()
	for ply in pairs(posed) do
		if IsValid(ply) then Follow(ply) end
	end
end)

hook.Add("Think", "skate3_body_gone", function()
	for ply in pairs(posed) do
		if not IsValid(ply) then posed[ply] = nil end
	end
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
