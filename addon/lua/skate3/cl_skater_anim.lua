-- The playermodel's finishing touches while skating: flat feet that sit on
-- the board, hands that close around the board, and a face that blinks and
-- winces on a bail. Skate 3's animation has no fingers or face, so those are
-- made here from what the skater is doing; any ValveBiped playermodel works.
--
-- The posing code calls, for the entity it poses (the real player, or the
-- stand-in model):
--   Anim.Setup(ent, rest, skater)   when the model or its rest pose changes
--   Anim.PostPose(ent, world, pose) after the whole skeleton's world matrices
--                                   are worked out, before they're applied
--                                   (as bone matrices or as manipulations)
--   Anim.Think(ent, pose)           once a frame from a Think hook (faces);
--                                   never from a render hook
--   Anim.Clear(ent)                 when skating stops (puts the face back)
--
-- `rest` and `world` are bone index -> Matrix, both in the same space as the
-- posing code: `rest` with the model at the origin, `world` in the world.
-- Nothing here calls SetupBones, GetAttachment or anything else that sets
-- the skeleton up again (that T-posed everyone in build 10).

local Anim = {}

local cv_fingers = CreateClientConVar("skate3_fingers", "1", true, false,
	"Hands close around the board while skating (0 = always open, as before)")
local cv_curl = CreateClientConVar("skate3_finger_curl", "1", true, false,
	"How far fingers curl, 1 = normal; a negative number bends them the other way, for a model whose fingers curl backwards")
local cv_ik = CreateClientConVar("skate3_foot_ik", "1", true, false,
	"Lift or lower the legs so the playermodel's soles sit where the skater's do (0 = off)")
local cv_soles = CreateClientConVar("skate3_foot_clear", "1", true, false,
	"Tip feet up so toes don't sink through the board (0 = off)")
local cv_face = CreateClientConVar("skate3_face", "1", true, false,
	"Blinking, and a hurt face on bails (0 = off)")

-- Rows of a 3x4 transform, as the module returns them.
local function Mat(t)
	return Matrix({
		{ t[1], t[2], t[3], t[4] },
		{ t[5], t[6], t[7], t[8] },
		{ t[9], t[10], t[11], t[12] },
		{ 0, 0, 0, 1 },
	})
end

-- The rotation of `angle` radians about unit vector `axis`.
local function AxisAngle(axis, angle)
	local x, y, z = axis.x, axis.y, axis.z
	local s, c = math.sin(angle), math.cos(angle)
	local t = 1 - c
	return Matrix({
		{ t * x * x + c, t * x * y - s * z, t * x * z + s * y, 0 },
		{ t * x * y + s * z, t * y * y + c, t * y * z - s * x, 0 },
		{ t * x * z - s * y, t * y * z + s * x, t * z * z + c, 0 },
		{ 0, 0, 0, 1 },
	})
end

-- The rotation taking unit vector a onto unit vector b.
local function Arc(a, b)
	local axis = a:Cross(b)
	local s = axis:Length()
	if s < 1e-6 then return Matrix() end
	axis:Mul(1 / s)
	return AxisAngle(axis, math.atan2(s, a:Dot(b)))
end

-- Just the turn of a matrix, without its position.
local function Turn(m)
	local r = Matrix(m)
	r:SetTranslation(vector_origin)
	return r
end

-- `m` turned by rotation `r` about the point `p`.
local function TurnAbout(m, r, p)
	local out = r * m
	out:SetTranslation(r * (m:GetTranslation() - p) + p)
	return out
end

local per = setmetatable({}, { __mode = "k" }) -- entity -> what Setup found

---------------------------------------------------------------------------
-- Setup

local function Bone(ent, name)
	local i = ent:LookupBone("ValveBiped.Bip01_" .. name)
	return i and i >= 0 and i or nil
end

-- Each bone's descendants, so turning a bone takes everything below it along.
local function Below(ent)
	local kids = {}
	for i = 0, ent:GetBoneCount() - 1 do
		local p = ent:GetBoneParent(i)
		if p and p >= 0 then
			kids[p] = kids[p] or {}
			table.insert(kids[p], i)
		end
	end
	local below = {}
	local function Walk(i, list)
		list[#list + 1] = i
		for _, k in ipairs(kids[i] or {}) do Walk(k, list) end
		return list
	end
	return function(i)
		below[i] = below[i] or Walk(i, {})
		return below[i]
	end
end

local function Pos(rest, i)
	return i and rest[i] and rest[i]:GetTranslation()
end

-- A hand's fingers, and which side its palm faces, from the rest pose.
local function FindHand(ent, rest, side)
	local hand = Bone(ent, side .. "_Hand")
	if not hand or not rest[hand] then return nil, "no hand bone" end
	local fingers = {}
	for f = 0, 4 do
		local chain = {}
		for _, suffix in ipairs({ "", "1", "2" }) do
			local i = Bone(ent, side .. "_Finger" .. f .. suffix)
			if i and rest[i] then chain[#chain + 1] = i end
		end
		if #chain >= 2 then fingers[f] = chain end
	end
	local base1, base4 = fingers[1] or fingers[2], fingers[4] or fingers[3]
	if not (base1 and base4) or base1 == base4 then return nil, "no finger bones" end
	local handPos = Pos(rest, hand)
	local knuckles, n = Vector(0, 0, 0), 0
	for f = 1, 4 do
		if fingers[f] then knuckles = knuckles + Pos(rest, fingers[f][1]) n = n + 1 end
	end
	knuckles = knuckles / n
	local forward = (knuckles - handPos):GetNormalized()
	local across = (Pos(rest, base4[1]) - Pos(rest, base1[1])):GetNormalized()
	local normal = forward:Cross(across):GetNormalized()
	-- Which way is the palm? The thumb sits on the palm side, and most
	-- models rest their fingers a little curled towards it.
	local vote = 0
	if fingers[0] then
		local tip = Pos(rest, fingers[0][#fingers[0]])
		vote = vote + 2 * (tip - knuckles):GetNormalized():Dot(normal)
	end
	for f = 1, 4 do
		local c = fingers[f]
		if c and #c == 3 then
			local a, b, t = Pos(rest, c[1]), Pos(rest, c[2]), Pos(rest, c[3])
			local straight = (b - a):GetNormalized()
			local off = (t - a) - straight * (t - a):Dot(straight)
			vote = vote + off:Dot(normal) / math.max((t - a):Length(), 1)
		end
	end
	-- Tie-break: rest poses nearly always hold the palms downwards.
	vote = vote + 0.3 * normal:Dot(Vector(0, 0, -1))
	local palm = vote >= 0 and normal or -normal
	-- Curl axes in the hand bone's own frame, so they follow the hand.
	local toHand = Turn(rest[hand]):GetInverse()
	local axes = {}
	for f, c in pairs(fingers) do
		local dir = (Pos(rest, c[2]) - Pos(rest, c[1])):GetNormalized()
		local axis = dir:Cross(palm)
		if axis:Length() > 1e-3 then axes[f] = toHand * axis:GetNormalized() end
	end
	return { hand = hand, fingers = fingers, axes = axes, vote = vote,
		curl = { 0, 0 }, wanted = 0 }
end

-- One leg's chain and how high its ankle sits off the floor, for matching
-- the skater's sole height. Foot bones differ a lot between models (Enx's
-- bone views: Gordon, Daedric, TB3 and the suit angle the foot bone down to
-- the ball of the foot, Chief and Hornet run it flat along the ground, the
-- fox has extra toe bones, the plague doctor has no toe bone), so nothing
-- here uses the foot or toe bone's direction: playermodels stand with their
-- origin on the floor, so the ankle's rest height is its height off the floor.
local function FindLeg(ent, rest, side, skateBind, skateSide, skateFloor)
	local thigh, calf, foot, toe = Bone(ent, side .. "_Thigh"), Bone(ent, side .. "_Calf"),
		Bone(ent, side .. "_Foot"), Bone(ent, side .. "_Toe0")
	if not (thigh and calf and foot and rest[thigh] and rest[calf] and rest[foot]) then return nil end
	local leg = { thigh = thigh, calf = calf, foot = foot, toe = toe }
	local sFoot = skateBind[skateSide .. "FOOT"]
	if sFoot and skateFloor then
		leg.ankle = Pos(rest, foot).z
		leg.skateAnkle = sFoot:GetTranslation().z - skateFloor
		leg.skateFoot = skateSide .. "FOOT"
		leg.bindTurn = Turn(sFoot):GetInverse()
	end
	return leg
end

-- The board's deck as a line segment in its bone's frame, for telling
-- whether a hand is on it.
local function FindDeck(skater)
	for _, p in ipairs(skater and skater.parts or {}) do
		if p.slot:lower():find("board") and not p.slot:lower():find("wheel") then
			local v = p.vertices
			local lo = { math.huge, math.huge, math.huge }
			local hi = { -math.huge, -math.huge, -math.huge }
			for o = 0, #v - 8, 8 do
				for k = 1, 3 do
					local x = v[o + k]
					if x < lo[k] then lo[k] = x end
					if x > hi[k] then hi[k] = x end
				end
			end
			local long = 1
			for k = 2, 3 do if hi[k] - lo[k] > hi[long] - lo[long] then long = k end end
			local mid = { (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2, (lo[3] + hi[3]) / 2 }
			local a, b = Vector(mid[1], mid[2], mid[3]), Vector(mid[1], mid[2], mid[3])
			local half = (hi[long] - lo[long]) / 2
			if long == 1 then a.x, b.x = mid[1] - half, mid[1] + half
			elseif long == 2 then a.y, b.y = mid[2] - half, mid[2] + half
			else a.z, b.z = mid[3] - half, mid[3] + half end
			return { bone = p.bone, a = a, b = b }
		end
	end
end

-- Flex controllers by what they do. Names differ between models, so they're
-- matched loosely; HL2-style faces and most ports use the HL2 names.
local FACE = {
	lids = { "blink", "lid_closer", "eyes?_?clos", "clos[ei]n?g?_?eyes?" },
	grimace = { "stretcher", "wrinkler", "lowerer", "squint", "frown" },
	jaw = { "jaw_drop", "jaw_open", "mouth_open", "open_mouth" },
}

local function FindFace(ent)
	local face = {}
	local n = ent.GetFlexNum and ent:GetFlexNum() or 0
	for i = 0, n - 1 do
		local name = (ent:GetFlexName(i) or ""):lower()
		local lo, hi = 0, 1
		if ent.GetFlexBounds then lo, hi = ent:GetFlexBounds(i) end
		-- Two-way sliders (eyes left/right and the like) aren't ours to set.
		if lo and hi and lo >= 0 and hi > lo then
			for role, patterns in pairs(FACE) do
				for _, p in ipairs(patterns) do
					if name:find(p) then
						face[role] = face[role] or {}
						table.insert(face[role], { index = i, lo = lo, hi = hi, name = name })
						break
					end
				end
			end
		end
	end
	return face
end

-- Where the skater's floor is in its bind pose: at its origin if it stands
-- there, otherwise just under its lowest joint (the toes).
local function SkateFloor(bind)
	local low
	for _, m in pairs(bind) do
		local z = m:GetTranslation().z
		if not low or z < low then low = z end
	end
	if not low then return nil end
	if low >= -0.5 and low <= 4 then return 0 end
	return low - 1
end

-- stand: optional bone -> Matrix of the model standing (entity at the
-- origin), for how high off the floor each foot and toe bone sits.
function Anim.Setup(ent, rest, skater, stand)
	local bind = {}
	for name, m in pairs(skater and skater.bind or {}) do
		bind[name] = istable(m) and Mat(m) or m
	end
	local floor = SkateFloor(bind)
	local info = {
		below = Below(ent),
		hands = {},
		legs = {},
		deck = FindDeck(skater),
		face = FindFace(ent),
		blinkAt = RealTime() + math.Rand(1, 4),
		weights = {},
		rig = bind,
	}
	for _, side in ipairs({ "L", "R" }) do
		local hand, why = FindHand(ent, rest, side)
		info.hands[side] = hand or false
		info.handWhy = info.handWhy or why
		info.legs[side] = FindLeg(ent, rest, side, bind, side == "L" and "LEFT" or "RIGHT", floor) or false
	end
	info.skateFloor = floor
	-- How high each bone of the foot sits off the floor when the model
	-- stands: never lower than that above the board (toe bones included,
	-- Maxine's paws have several).
	for _, leg in pairs(info.legs) do
		if leg and stand then
			leg.clear = {}
			for _, i in ipairs(info.below(leg.foot)) do
				local m = stand[i]
				if m then leg.clear[i] = math.max(m:GetTranslation().z, 0.5) end
			end
		end
	end
	per[ent] = info
	return info
end

---------------------------------------------------------------------------
-- Pose: feet, then hands

-- Two-bone reach: turn thigh and calf so the ankle lands on `target`,
-- bending the knee the way it already bends, and keep the foot's own turn.
local function Reach(world, leg, target, below)
	local h, k, a = world[leg.thigh], world[leg.calf], world[leg.foot]
	if not (h and k and a) then return end
	h, k, a = h:GetTranslation(), k:GetTranslation(), a:GetTranslation()
	local l1, l2 = (k - h):Length(), (a - k):Length()
	if l1 < 1e-3 or l2 < 1e-3 then return end
	local footTurn = Turn(world[leg.foot])
	local reach = target - h
	local dist = reach:Length()
	if dist < 1e-3 then return end
	local dir = reach / dist
	dist = math.Clamp(dist, math.abs(l1 - l2) + 0.01, l1 + l2 - 0.01)
	-- The knee's side: the current knee, square to the hip-ankle line. A
	-- straight leg has no side yet, so it bends the way the foot points.
	local bend = (k - h) - dir * (k - h):Dot(dir)
	if bend:Length() < 0.15 * l1 and leg.toe and world[leg.toe] then
		local ahead = world[leg.toe]:GetTranslation() - a
		bend = bend + (ahead - dir * ahead:Dot(dir)):GetNormalized() * (0.15 * l1)
	end
	if bend:Length() < 1e-3 then return end
	bend:Normalize()
	local cosHip = math.Clamp((l1 * l1 + dist * dist - l2 * l2) / (2 * l1 * dist), -1, 1)
	local knee = h + dir * (l1 * cosHip) + bend * (l1 * math.sqrt(1 - cosHip * cosHip))
	local r1 = Arc((k - h):GetNormalized(), (knee - h):GetNormalized())
	for _, i in ipairs(below(leg.thigh)) do
		if world[i] then world[i] = TurnAbout(world[i], r1, h) end
	end
	local ankle = world[leg.foot]:GetTranslation()
	local r2 = Arc((ankle - knee):GetNormalized(), (h + dir * dist - knee):GetNormalized())
	for _, i in ipairs(below(leg.calf)) do
		if world[i] then world[i] = TurnAbout(world[i], r2, knee) end
	end
	-- The foot keeps the turn it had before the leg moved.
	local undo = footTurn * Turn(world[leg.foot]):GetInverse()
	local at = world[leg.foot]:GetTranslation()
	for _, i in ipairs(below(leg.foot)) do
		if world[i] then world[i] = TurnAbout(world[i], undo, at) end
	end
end

-- Tip the foot up about the ankle until no bone of it (toes included) is
-- closer to the board than it is to the floor when the model stands, so
-- toes don't sink through the deck. floor: a point on the board's top,
-- up: the board's up.
local function Clear(world, leg, floor, up, below)
	local ankle = world[leg.foot]:GetTranslation()
	local bones = below(leg.foot)
	local worst, deepest = 0.25, nil
	for _, i in ipairs(bones) do
		local need, m = leg.clear[i], world[i]
		if need and m then
			local short = need - (m:GetTranslation() - floor):Dot(up)
			if short > worst then worst, deepest = short, m:GetTranslation() end
		end
	end
	if not deepest then return end
	local axis = (deepest - ankle):Cross(up)
	if axis:Length() < 1e-3 then return end
	axis:Normalize()
	local function Short(r)
		local most = 0
		for _, i in ipairs(bones) do
			local need, m = leg.clear[i], world[i]
			if need and m then
				local p = r * (m:GetTranslation() - ankle) + ankle
				most = math.max(most, need - (p - floor):Dot(up))
			end
		end
		return most
	end
	local r
	for deg = 3, 60, 3 do
		r = AxisAngle(axis, math.rad(deg))
		if Short(r) <= 0.25 then break end
	end
	for _, i in ipairs(bones) do
		if world[i] then world[i] = TurnAbout(world[i], r, ankle) end
	end
end

local function Feet(info, world, pose)
	if not cv_ik:GetBool() then return end
	for _, leg in pairs(info.legs) do
		local skate = leg and leg.ankle and pose.bones[leg.skateFoot]
		local d = skate and (leg.ankle - leg.skateAnkle)
		if d and world[leg.foot] then
			-- The sole's "up" is the skater's foot up, so this works on the
			-- board, on the ground and upside down in a flip.
			-- Aimed from the skater's own ankle, so it also works when the
			-- body keeps its own leg lengths and the ankle lands elsewhere.
			local m = Mat(skate)
			local up = Turn(m) * leg.bindTurn * Vector(0, 0, 1)
			Reach(world, leg, m:GetTranslation() + up * d, info.below)
			if leg.clear and cv_soles:GetBool() then
				Clear(world, leg, m:GetTranslation() - up * leg.skateAnkle, up, info.below)
			end
		end
	end
end

-- Degrees per finger joint, base to tip: relaxed, and gripping the board.
local CURL = {
	finger = { relaxed = { 18, 25, 15 }, grip = { 70, 90, 55 } },
	thumb = { relaxed = { 5, 10, 10 }, grip = { 20, 35, 30 } },
}
local GRIP_DISTANCE = 9 -- a hand this close to the deck holds it

local function Closest(p, a, b)
	local ab = b - a
	local t = math.Clamp((p - a):Dot(ab) / math.max(ab:LengthSqr(), 1e-6), 0, 1)
	return a + ab * t
end

local function Hands(info, world, pose)
	local scale = cv_fingers:GetBool() and cv_curl:GetFloat() or 0
	local dt = math.min(FrameTime(), 0.1)
	local deck = info.deck and pose.bones[info.deck.bone]
	local deckA, deckB
	if deck then
		local m = Mat(deck)
		deckA, deckB = m * info.deck.a, m * info.deck.b
	end
	local bailing = pose.state and pose.state:find("^Wipeout") ~= nil
	for _, hand in pairs(info.hands) do
		local hm = hand and world[hand.hand]
		if hm then
			local p = hm:GetTranslation()
			local holding = deckA and p:Distance(Closest(p, deckA, deckB)) < GRIP_DISTANCE
			-- 0 open (flailing in a bail), 1 relaxed, 2 gripping.
			hand.wanted = holding and 2 or bailing and 0.3 or 1
			-- Ease towards it, once a frame (this runs for every view and
			-- shadow drawn): a grip closes fast, letting go is slower.
			if hand.frame ~= FrameNumber() then
				hand.frame = FrameNumber()
				local rate = hand.wanted > (hand.now or 1) and 18 or 8
				hand.now = Lerp(1 - math.exp(-rate * dt), hand.now or 1, hand.wanted)
			end
			if scale ~= 0 then
				local turn = Turn(hm)
				for f, chain in pairs(hand.fingers) do
					local axis = hand.axes[f] and turn * hand.axes[f]
					if axis then
						local set = f == 0 and CURL.thumb or CURL.finger
						for j, i in ipairs(chain) do
							local relaxed, grip = set.relaxed[j] or 0, set.grip[j] or 0
							local deg = hand.now <= 1 and relaxed * hand.now
								or Lerp(hand.now - 1, relaxed, grip)
							if world[i] and deg ~= 0 then
								local r = AxisAngle(axis, math.rad(deg * scale))
								local at = world[i]:GetTranslation()
								for _, k in ipairs(info.below(i)) do
									if world[k] then world[k] = TurnAbout(world[k], r, at) end
								end
							end
						end
					end
				end
			end
		end
	end
end

function Anim.PostPose(ent, world, pose)
	local info = per[ent]
	if not info or not pose or not pose.bones then return end
	Feet(info, world, pose)
	Hands(info, world, pose)
end

---------------------------------------------------------------------------
-- Face

local function SetRole(ent, info, role, t)
	for _, f in ipairs(info.face[role] or {}) do
		local w = f.lo + (f.hi - f.lo) * math.Clamp(t, 0, 1)
		if info.weights[f.index] ~= w then
			ent:SetFlexWeight(f.index, w)
			info.weights[f.index] = w
		end
	end
end

local BLINK = 0.16 -- seconds, closed and open again

function Anim.Think(ent, pose)
	local info = per[ent]
	if not info or not IsValid(ent) or not pose then return end
	if not cv_face:GetBool() then Anim.Clear(ent) return end
	local now, dt = RealTime(), math.min(FrameTime(), 0.1)
	local state = pose.state or ""
	local bailing = state:find("^Wipeout") ~= nil
	-- A hard landing after real air gets a short flinch.
	local air = state:find("Air") ~= nil
	if air and not info.airSince then info.airSince = now end
	if not air and info.airSince then
		if now - info.airSince > 0.8 and not bailing then info.flinchUntil = now + 0.3 end
		info.airSince = nil
	end
	local hurt = bailing and 1 or (info.flinchUntil and now < info.flinchUntil) and 0.5 or 0
	local rate = hurt > (info.hurt or 0) and 25 or 3
	info.hurt = Lerp(1 - math.exp(-rate * dt), info.hurt or 0, hurt)
	-- Blink every few seconds, not while the eyes are screwed shut anyway.
	local blink = 0
	if now >= info.blinkAt then
		local t = (now - info.blinkAt) / BLINK
		if t >= 1 then
			info.blinkAt = now + math.Rand(2.5, 6)
		else
			blink = 1 - math.abs(t * 2 - 1)
		end
	end
	SetRole(ent, info, "lids", math.max(blink, info.hurt * 0.9))
	SetRole(ent, info, "grimace", info.hurt)
	SetRole(ent, info, "jaw", info.hurt * 0.35)
	info.touched = true
end

function Anim.Clear(ent)
	local info = per[ent]
	if not info or not info.touched or not IsValid(ent) then return end
	for _, role in ipairs({ "lids", "grimace", "jaw" }) do SetRole(ent, info, role, 0) end
	info.touched, info.hurt = false, 0
end

---------------------------------------------------------------------------
-- Report

-- What the finishing touches found on a model, for skate3_anim_report.
function Anim.Report(ent, pose, world)
	local info = per[ent]
	local lines = {}
	if not info then return { "no model set up yet (get on the board first)" } end
	local names = {}
	for name in pairs(info.rig) do names[#names + 1] = name end
	table.sort(names)
	lines[#lines + 1] = ("Skate 3 rig: %d joints: %s"):format(#names, table.concat(names, " "))
	for side, hand in pairs(info.hands) do
		if hand then
			local found = {}
			for f = 0, 4 do found[#found + 1] = hand.fingers[f] and tostring(#hand.fingers[f]) or "-" end
			lines[#lines + 1] = ("%s hand: finger joints %s (thumb first), palm vote %.2f, grip %.2f")
				:format(side, table.concat(found, "/"), hand.vote, hand.now or 1)
		else
			lines[#lines + 1] = side .. " hand: no ValveBiped fingers, left as is (" .. tostring(info.handWhy) .. ")"
		end
	end
	for side, leg in pairs(info.legs) do
		if leg and leg.ankle then
			local line = ("%s foot: ankle %.1f off the floor at rest (Skate 3: %.1f, its floor at %.1f), lift %.1f%s")
				:format(side, leg.ankle, leg.skateAnkle, info.skateFloor or 0, leg.ankle - leg.skateAnkle,
					leg.toe and "" or ", no toe bone")
			if world and world[leg.foot] then
				local function Above(p)
					local tr = util.TraceLine({ start = p + Vector(0, 0, 4), endpos = p - Vector(0, 0, 64), mask = MASK_SOLID })
					return p.z - tr.HitPos.z
				end
				line = line .. (", now ankle %.1f above what's under it"):format(Above(world[leg.foot]:GetTranslation()))
				if leg.toe and world[leg.toe] then
					line = line .. (", toe %.1f"):format(Above(world[leg.toe]:GetTranslation()))
				end
			end
			lines[#lines + 1] = line
		else
			lines[#lines + 1] = side .. " foot: no ValveBiped leg bones, left as is"
		end
	end
	for _, role in ipairs({ "lids", "grimace", "jaw" }) do
		local found = {}
		for _, f in ipairs(info.face[role] or {}) do found[#found + 1] = f.name end
		lines[#lines + 1] = ("face %s: %s"):format(role, #found > 0 and table.concat(found, ", ") or "none")
	end
	lines[#lines + 1] = "deck: " .. (info.deck and info.deck.bone or "not found")
	return lines
end

return Anim
