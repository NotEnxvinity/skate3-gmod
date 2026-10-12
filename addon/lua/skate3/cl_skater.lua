-- Draws the skater: the Skate 3 board from the player's own converted data,
-- and their playermodel posed from the skater's skeleton.

local Skater = {}
local Body = include("skate3/cl_body.lua")
Skater.Body = Body
local Anim = include("skate3/cl_skater_anim.lua")
local Boards = include("skate3/cl_boards.lua")

-- For hunting a leak: parts of the per-frame work to switch off while riding,
-- as a list such as "board,bones". board, bones, model, score, sounds, pose,
-- step and net.
local cv_skip = CreateClientConVar("skate3_debug_skip", "", false, false,
	"Debug: per-frame work to skip, comma separated (board, bones, model, score, sounds, pose, step, net, view, anim)")
Skater.Skip = {}
local function ReadSkip()
	Skater.Skip = {}
	for word in cv_skip:GetString():gmatch("[%w_]+") do Skater.Skip[word:lower()] = true end
end
ReadSkip()
cvars.AddChangeCallback("skate3_debug_skip", ReadSkip, "skate3")

-- Rows of a 3x4 transform, as the module returns them.
local function Mat(t)
	return Matrix({
		{ t[1], t[2], t[3], t[4] },
		{ t[5], t[6], t[7], t[8] },
		{ t[9], t[10], t[11], t[12] },
		{ 0, 0, 0, 1 },
	})
end

local data -- skate3.GetSkater(): board parts and the skater's bind pose
local parts -- board meshes, built on first draw
local bind = {} -- Skate 3 bone name -> bind Matrix

function Skater.Load()
	local skater, err = skate3.GetSkater()
	if not skater then
		print("[skate3] no board or skater rig: " .. tostring(err))
		return
	end
	data = skater
	parts = nil
	Boards.SetTextures(skater.textures)
	bind = {}
	for name, m in pairs(skater.bind) do bind[name] = Mat(m) end
	print(("[skate3] board ready: %d parts"):format(#skater.parts))
end

---------------------------------------------------------------------------
-- The board

-- A source mesh can only hold so many triangles.
local MAX_TRIANGLES = 10000

-- A part's texture and colour: the look picked in the settings (see
-- cl_boards.lua), else the skater's own.
local function ApplyLook(mat, slot, tint)
	local png = Boards.Texture(slot)
		or data.textures and (data.textures .. "/" .. slot .. "_base_color.png")
	mat:SetTexture("$basetexture", "color/white")
	if png and file.Exists(png, "DATA") then
		local source = Material("../data/" .. png, "smooth mips")
		if not source:IsError() then
			mat:SetTexture("$basetexture", source:GetTexture("$basetexture"))
		end
	end
	local color = Boards.Color(slot) or Vector(1, 1, 1)
	mat:SetVector("$color2", Vector(tint[1] * color.x, tint[2] * color.y, tint[3] * color.z))
end

-- A fresh material name each time the board is built: Garry's Mod keeps
-- materials made with CreateMaterial across map changes, and reusing one from
-- the last map can leave it without the picked look.
local builds = 0

local function BoardMaterial(slot, tint)
	local mat = CreateMaterial("skate3_board_" .. slot .. "_" .. builds, "VertexLitGeneric", {
		["$basetexture"] = "color/white",
		["$model"] = 1,
		["$nocull"] = 1,
	})
	ApplyLook(mat, slot, tint)
	return mat
end

-- Picking a look in the settings repaints the board straight away.
for _, p in ipairs(Boards.PARTS) do
	for _, name in ipairs({ p.look, p.color }) do
		cvars.AddChangeCallback(name, function()
			if not parts or not data then return end
			for i, part in ipairs(parts) do
				local source = data.parts[i]
				if source and source.slot == p.slot then ApplyLook(part.material, source.slot, source.tint) end
			end
		end, "skate3_board_look")
	end
end

local function BuildMeshes(v)
	local meshes = {}
	local triangles = #v / 24
	local done = 0
	while done < triangles do
		local n = math.min(MAX_TRIANGLES, triangles - done)
		local m = Mesh()
		mesh.Begin(m, MATERIAL_TRIANGLES, n)
		for i = done * 3, (done + n) * 3 - 1 do
			local o = i * 8
			mesh.Position(Vector(v[o + 1], v[o + 2], v[o + 3]))
			mesh.Normal(Vector(v[o + 4], v[o + 5], v[o + 6]))
			mesh.TexCoord(0, v[o + 7], v[o + 8])
			mesh.AdvanceVertex()
		end
		mesh.End()
		meshes[#meshes + 1] = m
		done = done + n
	end
	return meshes
end

local function BuildBoard()
	builds = builds + 1
	parts = {}
	for _, p in ipairs(data.parts) do
		parts[#parts + 1] = {
			bone = p.bone,
			material = BoardMaterial(p.slot, p.tint),
			meshes = BuildMeshes(p.vertices),
		}
	end
end

local cv_xray = CreateClientConVar("skate3_debug_board", "0", false, false, "Draw the board through walls, with a box on each part")

-- Returns false when there's no board to draw.
function Skater.DrawBoard(pose)
	if not data or not pose.bones then return false end
	if not parts then BuildBoard() end
	local light = render.GetLightColor(Vector(pose.pos[1], pose.pos[2], pose.pos[3] + 8))
	render.SuppressEngineLighting(true)
	render.ResetModelLighting(light.x * 0.6 + 0.05, light.y * 0.6 + 0.05, light.z * 0.6 + 0.05)
	render.SetModelLighting(BOX_TOP, light.x, light.y, light.z)
	local xray = cv_xray:GetBool()
	if xray then cam.IgnoreZ(true) end
	local drawn = 0
	for _, part in ipairs(parts) do
		local m = pose.bones[part.bone]
		if m then
			render.SetMaterial(part.material)
			cam.PushModelMatrix(Mat(m))
			for _, piece in ipairs(part.meshes) do piece:Draw() end
			cam.PopModelMatrix()
			drawn = drawn + 1
		end
	end
	render.SuppressEngineLighting(false)
	-- X-ray: the board through walls and floors, plus a box on each part.
	if xray then
		for _, part in ipairs(parts) do
			local m = pose.bones[part.bone]
			if m then
				local at = Vector(m[4], m[8], m[12])
				render.DrawWireframeBox(at, angle_zero, Vector(-1, -1, -1), Vector(1, 1, 1), Color(255, 60, 200), false)
			end
		end
		cam.IgnoreZ(false)
	end
	-- None of the board's bones came through: show the stand-in instead.
	return drawn > 0
end

-- What the board is made of and where it is, for skate3_board_info.
function Skater.BoardInfo(pose)
	if not data then
		print("[skate3] no board data loaded (see the console line from when the map loaded)")
		return
	end
	print(("[skate3] board: %d parts, textures at %s"):format(#data.parts, tostring(data.textures)))
	if pose then
		local at = Vector(pose.pos[1], pose.pos[2], pose.pos[3])
		local floor = util.TraceLine({ start = at + Vector(0, 0, 48), endpos = at - Vector(0, 0, 256), mask = MASK_SOLID_BRUSHONLY })
		print(("[skate3] skater root at %s, floor below it at height %.1f"):format(tostring(at), floor.HitPos.z))
	end
	for i, p in ipairs(data.parts) do
		local png = data.textures and (data.textures .. "/" .. p.slot .. "_base_color.png")
		local m = pose and pose.bones and pose.bones[p.bone]
		local where = "bone missing from the pose"
		if not pose then
			where = "not riding"
		elseif m then
			local at = Vector(m[4], m[8], m[12])
			where = ("bone at %s, %.0f units from the skater"):format(tostring(at), at:Distance(Vector(pose.pos[1], pose.pos[2], pose.pos[3])))
		end
		print(("  %d. %s on %s: %d triangles, texture %s, %s"):format(
			i, p.slot, p.bone, #p.vertices / 24, png and file.Exists(png, "DATA") and "found" or "missing", where))
	end
end

---------------------------------------------------------------------------
-- The playermodel
--
-- Ported from chasmlol/2010-rust-rewrite-mashup (Apache-2.0) at f608f85,
-- crates/render_anim/src/skate/rig.rs: each ValveBiped bone's bind segment is
-- aligned onto the skater's, then follows that skater bone's motion. Unmapped
-- bones (fingers, hair, tails) ride their nearest mapped ancestor; the hands
-- are closed and the feet set on the board afterwards, in cl_skater_anim.lua.

-- ValveBiped bone, Skate 3 bone, and the child pair that aims the segment.
local MAP = {
	-- The pelvis isn't aimed at the spine: that segment is a few units long
	-- and leans every which way between rigs (41 degrees back on one suit
	-- model), so aiming it tipped the hips and pushed the belly out. It
	-- keeps its own upright rest and just follows the skater's hips.
	{ "Pelvis", "HIPS" },
	{ "Spine", "SPINE", "Spine1", "SPINE1" },
	{ "Spine1", "SPINE1", "Spine2", "SPINE2" },
	{ "Spine2", "SPINE2", "Spine4", "SPINE3" },
	-- Neck and head turn with the skater's rather than staying locked to the
	-- chest (skate3_pose_head 0 for the old way).
	{ "Spine4", "SPINE3", "Neck1", "NECK", head = true },
	{ "Neck1", "NECK", "Head1", "HEAD", head = true },
	{ "Head1", "HEAD", head = true },
	{ "L_Clavicle", "LEFTSHOULDER", "L_UpperArm", "LEFTARM" },
	{ "L_UpperArm", "LEFTARM", "L_Forearm", "LEFTFOREARM" },
	{ "L_Forearm", "LEFTFOREARM", "L_Hand", "LEFTHAND" },
	{ "L_Hand", "LEFTHAND" },
	{ "R_Clavicle", "RIGHTSHOULDER", "R_UpperArm", "RIGHTARM" },
	{ "R_UpperArm", "RIGHTARM", "R_Forearm", "RIGHTFOREARM" },
	{ "R_Forearm", "RIGHTFOREARM", "R_Hand", "RIGHTHAND" },
	{ "R_Hand", "RIGHTHAND" },
	{ "L_Thigh", "LEFTUPLEG", "L_Calf", "LEFTLEG" },
	{ "L_Calf", "LEFTLEG", "L_Foot", "LEFTFOOT" },
	{ "L_Foot", "LEFTFOOT", "L_Toe0", "LEFTTOEBASE", flat = true },
	{ "L_Toe0", "LEFTTOEBASE", flat = true },
	{ "R_Thigh", "RIGHTUPLEG", "R_Calf", "RIGHTLEG" },
	{ "R_Calf", "RIGHTLEG", "R_Foot", "RIGHTFOOT" },
	{ "R_Foot", "RIGHTFOOT", "R_Toe0", "RIGHTTOEBASE", flat = true },
	{ "R_Toe0", "RIGHTTOEBASE", flat = true },
}

-- Feet aren't aimed at the toe: where the toe bone sits differs between
-- models, and aiming at it stood some (Master Chief, TB3) on tiptoe. A flat
-- foot copies how the skater's foot turns from its rest instead, so a model
-- that stands flat at rest stands flat on the board (skate3_foot_mode aim
-- for the old way).
local cv_footMode = CreateClientConVar("skate3_foot_mode", "flat", true, false,
	"How the playermodel's feet follow the skater's: flat (default) or aim (the older way, aimed at the toe)")
local cv_footStand = CreateClientConVar("skate3_foot_stand", "1", true, false,
	"Feet sit on the board the way the playermodel's feet sit on the ground when it stands (0 = from its rest pose, the older way)")
local cv_head = CreateClientConVar("skate3_pose_head", "1", true, false,
	"Neck and head follow the skater's (0 = locked to the chest, the older way)")

-- Playermodels face +X at rest; the skater's bind faces -Y.
local FACING = Angle(0, -90, 0)

-- The rotation taking unit vector a onto unit vector b.
local function Arc(a, b)
	local axis = a:Cross(b)
	local s, c = axis:Length(), a:Dot(b)
	if s < 1e-6 then
		if c > 0 then return Matrix() end
		axis = a:Cross(math.abs(a.x) < 0.9 and Vector(1, 0, 0) or Vector(0, 1, 0))
		axis:Normalize()
		s, c = 0, -1
	else
		axis:Mul(1 / s)
	end
	local x, y, z, t = axis.x, axis.y, axis.z, 1 - c
	return Matrix({
		{ t * x * x + c, t * x * y - s * z, t * x * z + s * y, 0 },
		{ t * x * y + s * z, t * y * y + c, t * y * z - s * x, 0 },
		{ t * x * z - s * y, t * y * z + s * x, t * z * z + c, 0 },
		{ 0, 0, 0, 1 },
	})
end

local function Facing(v)
	v = Vector(v)
	v:Rotate(FACING)
	return v
end

local model -- the clientside copy of the local player's model (drawn only with skate3_body copy)
local frozen -- the model's frozen frame, from Body.FrozenLocals, when posing the real body
local pelvis -- the pelvis bone index, the one bone that's also shifted
local skeleton = {} -- bone index -> true for the model's ValveBiped bones
local rest = {} -- bone index -> the model's bind Matrix at the origin
-- Bones the engine sets up at all. Writing any other (unused helper bones on
-- some playermodels) logs "Bone is unwriteable" every frame.
local writable = {}
local USED = BONE_USED_BY_ANYTHING or 0x7FF00
local fits = {} -- bone index -> { skate = name, pre = Matrix }

-- The model's bind pose, the shape its mesh was built in, as bone -> model
-- matrices. Nil when the engine won't give it.
local function BindPose(ent, ragdoll)
	local ok, _, bones = pcall(util.GetModelMeshes, ent:GetModel(), 0, 0)
	if not ok or not bones then return nil end
	-- Bone indices start at 0; shift a table numbered from 1.
	if bones[0] == nil and bones[ent:GetBoneCount()] ~= nil then
		local shifted = {}
		for i, bone in pairs(bones) do shifted[i - 1] = bone end
		bones = shifted
	end
	-- Which way round the matrices come isn't documented, and reading them
	-- one way twisted every limb. So try each reading: the right one puts
	-- the pelvis near where the "ragdoll" sequence has it and turns the bones
	-- most like that sequence does (the trick models' proportions differ,
	-- their bones' turns barely do).
	local function Transposed(m)
		local t = m:ToTable()
		return Matrix({
			{ t[1][1], t[2][1], t[3][1], t[4][1] },
			{ t[1][2], t[2][2], t[3][2], t[4][2] },
			{ t[1][3], t[2][3], t[3][3], t[4][3] },
			{ t[1][4], t[2][4], t[3][4], t[4][4] },
		})
	end
	local function TurnFlipped(m)
		-- The rotation transposed, the position kept.
		local r = Transposed(m)
		r:SetTranslation(m:GetTranslation())
		r:SetField(4, 1, 0) r:SetField(4, 2, 0) r:SetField(4, 3, 0) r:SetField(4, 4, 1)
		return r
	end
	local readings = {
		{ "as is", function(m) return Matrix(m) end },
		{ "inverted", function(m) return m:GetInverse() end },
		{ "turn flipped", function(m) return TurnFlipped(m) end },
		{ "inverted, turn flipped", function(m) return TurnFlipped(m:GetInverse()) end },
		{ "transposed", function(m) return Transposed(m) end },
		{ "transposed, inverted", function(m) return Transposed(m):GetInverse() end },
	}
	-- The bind pose came out with every bone turned on every model, even
	-- with its positions right: either the whole pose sits in the space the
	-- model was authored in, or each bone's axes follow another convention.
	-- So each reading is also tried under the 24 right-angle turns, applied
	-- to the whole pose (positions turn too) or to each bone's own axes.
	local turns = {}
	local axes = { Vector(1, 0, 0), Vector(0, 1, 0), Vector(0, 0, 1) }
	for a = 1, 3 do
		for b = 1, 3 do
			if a ~= b then
				for _, sa in ipairs({ 1, -1 }) do
					for _, sb in ipairs({ 1, -1 }) do
						local x, y = axes[a] * sa, axes[b] * sb
						local z = x:Cross(y)
						turns[#turns + 1] = Matrix({
							{ x.x, y.x, z.x, 0 },
							{ x.y, y.y, z.y, 0 },
							{ x.z, y.z, z.z, 0 },
							{ 0, 0, 0, 1 },
						})
					end
				end
			end
		end
	end
	local pelvis = ent:LookupBone("ValveBiped.Bip01_Pelvis")
	if not (pelvis and ragdoll[pelvis]) then return nil end
	local want = ragdoll[pelvis]:GetTranslation()
	local best, bestScore
	for _, reading in ipairs(readings) do
		local read, ok2 = {}, true
		for i, bone in pairs(bones) do
			if bone.matrix then
				local good, m = pcall(reading[2], bone.matrix)
				if good and m then read[i] = m else ok2 = false break end
			end
		end
		for t = 1, ok2 and #turns * 2 or 0 do
			local whole = t <= #turns
			local turn = turns[whole and t or t - #turns]
			local function Apply(m) return whole and turn * m or m * turn end
			local p = read[pelvis] and Apply(read[pelvis])
			if p and p:GetTranslation():Distance(want) < 32 then
				local score, n = 0, 0
				for i, m in pairs(read) do
					local r = ragdoll[i]
					if r then
						m = Apply(m)
						score = score + (m:GetForward() - r:GetForward()):Length()
							+ (m:GetUp() - r:GetUp()):Length()
						n = n + 1
					end
				end
				score = n > 0 and score / n or math.huge
				if not bestScore or score < bestScore then
					best, bestScore = { read = read, apply = Apply, name = reading[1],
						turn = (whole and "whole " or "bone ") .. (whole and t or t - #turns) }, score
				end
			end
		end
	end
	if not best then return nil end
	-- No reading lines up: a twisted body is worse than the old way.
	if bestScore > 1 then
		return nil, ("%s, %s, mismatch %.2f"):format(best.name, best.turn, bestScore)
	end
	local out = {}
	for i, m in pairs(best.read) do out[i] = best.apply(m) end
	return out, ("%s, %s, mismatch %.2f"):format(best.name, best.turn, bestScore)
end

local cv_rest = CreateClientConVar("skate3_rest_pose", "bind", true, false,
	"What the playermodel's rest pose is read from: bind (default) or ragdoll (the older way). Takes effect on the next model change.")
local restFrom = "" -- what the rest pose was read from, for the bone report

-- The model's rest pose, read once with the entity at the origin.
-- The bind pose (or the "ragdoll" sequence when it won't line up) of ent,
-- set at the origin. Returns bindPose or nil, how it was read, ragdoll.
local function ReadRest(ent)
	ent:SetPos(vector_origin)
	ent:SetAngles(angle_zero)
	local seq = ent:LookupSequence("ragdoll")
	ent:ResetSequence(seq >= 0 and seq or 0)
	ent:SetCycle(0)
	ent:InvalidateBoneCache()
	ent:SetupBones()
	local ragdoll = {}
	for i = 0, ent:GetBoneCount() - 1 do ragdoll[i] = ent:GetBoneMatrix(i) end
	-- The bind pose rather than the "ragdoll" sequence: playermodels made
	-- with the proportion trick (Halo Infinite's Master Chief, Doom Guy) get
	-- the stock Valve skeleton in that sequence, with the neck down inside
	-- the chest, and their heads ended up there.
	local bindPose, how
	if cv_rest:GetString() ~= "ragdoll" then bindPose, how = BindPose(ent, ragdoll) end
	return bindPose, how, ragdoll
end

-- Other players' bodies need the same rest pose (see Body.FrozenLocals).
function Body.RestOf(ent)
	local bindPose, _, ragdoll = ReadRest(ent)
	return bindPose or ragdoll
end

local stand = {} -- bone index -> Matrix, the model standing in Gmod's idle, at the origin

local function CaptureRest(ent)
	ent:SetPos(vector_origin)
	ent:SetAngles(angle_zero)
	-- How the model stands in Gmod, for its feet: however its foot bones
	-- are set up, that's the way its feet sit flat on the ground.
	stand = {}
	for _, name in ipairs({ "idle_all_01", "idle_all_02", "idle_passive" }) do
		local s = ent:LookupSequence(name)
		if s and s >= 0 then
			ent:ResetSequence(s)
			ent:SetCycle(0)
			ent:InvalidateBoneCache()
			ent:SetupBones()
			for i = 0, ent:GetBoneCount() - 1 do stand[i] = ent:GetBoneMatrix(i) end
			break
		end
	end
	local bindPose, how, ragdoll = ReadRest(ent)
	restFrom = bindPose and ("bind pose (" .. how .. ")")
		or ("ragdoll sequence" .. (how and (" (bind pose didn't line up: " .. how .. ")") or ""))
	print("[skate3] rest pose from the " .. restFrom)
	rest = {}
	writable = {}
	for i = 0, ent:GetBoneCount() - 1 do
		-- A bone with no rest pose is left to the engine rather than guessed.
		rest[i] = bindPose and bindPose[i] or ragdoll[i]
		writable[i] = rest[i] ~= nil and ent:BoneHasFlag(i, USED)
	end
end

-- The turn (tilt only, no turning about the vertical) taking a bone from
-- its rest pose to how it is when the model stands. Nil if not known.
local function StandTilt(i)
	local r, s = rest[i], stand[i]
	if not (r and s) then return nil end
	local function Rot(m) local c = Matrix(m) c:SetTranslation(vector_origin) return c end
	local C = Rot(s) * Rot(r):GetInverse()
	-- Take out the part that turns about the vertical, from where C sends
	-- "ahead", leaving the tilt.
	local ahead = C * Vector(1, 0, 0)
	if ahead.x * ahead.x + ahead.y * ahead.y < 0.1 then return nil end
	local yaw = Matrix()
	yaw:Rotate(Angle(0, -math.deg(math.atan2(ahead.y, ahead.x)), 0))
	local tilt = yaw * C
	local up = tilt * Vector(0, 0, 1)
	return tilt, math.deg(math.acos(math.Clamp(up.z, -1, 1)))
end

local function Fit(ent)
	fits = {}
	local function Pos(name)
		local i = ent:LookupBone("ValveBiped.Bip01_" .. name)
		return i and rest[i] and rest[i]:GetTranslation(), i
	end
	local flat = cv_footMode:GetString() ~= "aim"
	for _, row in ipairs(MAP) do
		local from, index = Pos(row[1])
		local skate = bind[row[2]]
		if row.head and not cv_head:GetBool() then skate = nil end
		if from and skate then
			local to = skate:GetTranslation()
			local a, b
			local child = row[3] and Pos(row[3])
			local skateChild = row[4] and bind[row[4]]
			if row.flat and flat then
				-- No aiming: just the facing turn, below.
			elseif child and skateChild then
				a, b = Facing(child - from), skateChild:GetTranslation() - to
			else
				-- Ends of chains keep their parent's alignment.
				local parent = ent:GetBoneParent(index)
				local parentRow
				for _, r in ipairs(MAP) do
					if ent:LookupBone("ValveBiped.Bip01_" .. r[1]) == parent
						and not (r.head and not cv_head:GetBool()) then parentRow = r end
				end
				if parentRow and rest[parent] and bind[parentRow[2]] then
					a, b = Facing(from - rest[parent]:GetTranslation()), to - bind[parentRow[2]]:GetTranslation()
				end
			end
			local rot = Matrix()
			rot:Rotate(FACING)
			if row.flat and flat and cv_footStand:GetBool() then
				-- The rest pose (bind pose or the ragdoll sequence) has some
				-- models' feet pointing down (Maxine, Master Chief). Tilt the
				-- foot the way it's tilted when the model stands instead;
				-- only the tilt, so feet keep pointing along the board.
				local tilt, deg = StandTilt(index)
				if tilt then rot = rot * tilt end
				if deg and deg > 10 and row[1]:find("Foot") then
					print(("[skate3] %s tilted %.0f degrees to sit like it does standing"):format(row[1], deg))
				end
			end
			if a and b and a:LengthSqr() > 0 and b:LengthSqr() > 0 then
				rot = Arc(a:GetNormalized(), b:GetNormalized()) * rot
			end
			-- Rotate the bind segment into place, then move its root onto the skater's.
			local fit = Matrix(rot)
			fit:SetTranslation(to - rot * from)
			fits[index] = { skate = row[2], pre = skate:GetInverse() * fit }
		end
	end
end

-- The neck and head keep the model's own neck length: their turns come
-- from the skater, but each sits where the model has it from its parent.
-- Set at the skater's neck and head, a model whose proportions differ
-- from the skater's (Master Chief) got a stretched neck.
local cv_neck = CreateClientConVar("skate3_neck_keep", "1", true, false,
	"Neck and head keep the playermodel's own neck length (0 = placed at the skater's, the older way)")
-- The same goes for the spine and collarbones: placed at the skater's, a
-- model with a longer torso than the skater's (Gordon's HEV suit) got its
-- chest squashed up under its chin and its shoulders shrugged.
local cv_torso = CreateClientConVar("skate3_torso_keep", "1", true, false,
	"Spine and collarbones keep the playermodel's own lengths (0 = placed at the skater's, the older way)")
-- And the arms and legs: placed at the skater's joints, a model's own
-- calves, feet, forearms and hands were stretched or squashed to the
-- skater's lengths (Maxine's paws pushed up into her ankles, hands into
-- wrists). They keep their own lengths, and the leg and arm reach in
-- cl_skater_anim.lua puts the ankles and hands back where the skater's are.
local cv_limbs = CreateClientConVar("skate3_limbs_keep", "1", true, false,
	"Arms and legs keep the playermodel's own lengths (0 = stretched to the skater's, the older way)")
local LIMBS = {
	"L_UpperArm", "L_Forearm", "L_Hand", "R_UpperArm", "R_Forearm", "R_Hand",
	"L_Thigh", "L_Calf", "L_Foot", "L_Toe0", "R_Thigh", "R_Calf", "R_Foot", "R_Toe0",
}
-- Playermodels stand taller than the Skate 3 skater, so with their own leg
-- lengths and the hips at the skater's height they squatted. The hips are
-- lifted away from the ankles by how much longer the model's legs are, so
-- knees bend as much as the skater's do.
-- All the way up straightened the arms (they couldn't reach the board any
-- more), so by default the hips go part of the way.
local cv_height = CreateClientConVar("skate3_body_height", "0.6", true, false,
	"How far the hips lift towards the playermodel's own leg length: 0 = the skater's height (squats), 1 = all the way (straight arms)")
local legScale -- the model's hip-to-ankle height over the skater's
local neckChain = {} -- { { bone, its offset from its parent at rest, convar }, ... } parents first
local kids = {} -- bone -> its children
local TORSO = { "Spine", "Spine1", "Spine2", "Spine3", "Spine4", "L_Clavicle", "R_Clavicle" }

local function FindNeck(ent)
	neckChain, kids = {}, {}
	for i = 0, ent:GetBoneCount() - 1 do
		local p = ent:GetBoneParent(i)
		if p and p >= 0 then kids[p] = kids[p] or {} table.insert(kids[p], i) end
	end
	local function add(name, cv)
		local i = ent:LookupBone("ValveBiped.Bip01_" .. name)
		local p = i and ent:GetBoneParent(i)
		if i and p and p >= 0 and rest[i] and rest[p] then
			neckChain[#neckChain + 1] = { i, (rest[p]:GetInverseTR() * rest[i]):GetTranslation(), cv }
		end
	end
	for _, name in ipairs(TORSO) do add(name, cv_torso) end
	for _, name in ipairs({ "Neck1", "Head1" }) do add(name, cv_neck) end
	for _, name in ipairs(LIMBS) do add(name, cv_limbs) end
	legScale = nil
	local function Z(name)
		local i = ent:LookupBone("ValveBiped.Bip01_" .. name)
		return i and rest[i] and rest[i]:GetTranslation().z
	end
	local hip, la, ra = Z("Pelvis"), Z("L_Foot"), Z("R_Foot")
	local sh, sl, sr = bind.HIPS, bind.LEFTFOOT, bind.RIGHTFOOT
	if hip and la and ra and sh and sl and sr then
		local own = hip - (la + ra) / 2
		local skater = sh:GetTranslation().z - (sl:GetTranslation().z + sr:GetTranslation().z) / 2
		if own > 1 and skater > 1 then
			legScale = math.Clamp(own / skater, 0.75, 1.5)
			print(("[skate3] legs %.0f%% of the skater's, hips lifted to match"):format(legScale * 100))
		end
	end
end

local function Shift(world, i, by)
	local m = world[i]
	if m then
		m = Matrix(m)
		m:SetTranslation(m:GetTranslation() + by)
		world[i] = m
	end
	for _, k in ipairs(kids[i] or {}) do Shift(world, k, by) end
end

local function KeepNeck(ent, world)
	-- Here every foot is still at the skater's ankle.
	local hip = ent:LookupBone("ValveBiped.Bip01_Pelvis")
	local lf, rf = ent:LookupBone("ValveBiped.Bip01_L_Foot"), ent:LookupBone("ValveBiped.Bip01_R_Foot")
	local lift = math.Clamp(cv_height:GetFloat(), 0, 1)
	if legScale and lift > 0 and cv_limbs:GetBool() and hip and world[hip]
		and lf and rf and world[lf] and world[rf] then
		local ankles = (world[lf]:GetTranslation() + world[rf]:GetTranslation()) / 2
		local at = world[hip]:GetTranslation()
		Shift(world, hip, (at - ankles) * ((legScale - 1) * lift))
	end
	for _, link in ipairs(neckChain) do
		local i = link[1]
		local p = ent:GetBoneParent(i)
		if link[3]:GetBool() and world[i] and world[p] then
			local want = world[p] * link[2]
			Shift(world, i, want - world[i]:GetTranslation())
		end
	end
end

local pose
local cv_body = CreateClientConVar("skate3_body", "real", true, false,
	"Which body skates: real (your own playermodel, posed) or copy (the older way: a copy of it, posed; you're hidden)")
local lastWorld -- the last posed skeleton, for skate3_anim_report
local cv_bones = CreateClientConVar("skate3_bone_mode", "override", true, false,
	"With skate3_body copy, how the copy is posed: override (default) or callback")

local function BuildBones(ent, count)
	if not pose or not pose.bones then return end
	local skins = {}
	-- Root bones that come before the pelvis (a "root" or "Bip01" some ports
	-- add) ride it too, so find it first.
	local pelvis
	for i = 0, count - 1 do
		local fit = fits[i]
		local posed = fit and pose.bones[fit.skate]
		if posed then pelvis = Mat(posed) * fit.pre break end
	end
	local world = {}
	for i = 0, count - 1 do
		local fit = fits[i]
		local posed = fit and pose.bones[fit.skate]
		local skin
		if posed then
			skin = Mat(posed) * fit.pre
		else
			local parent = ent:GetBoneParent(i)
			skin = parent >= 0 and skins[parent] or pelvis
		end
		skins[i] = skin
		if skin and rest[i] then world[i] = skin * rest[i] end
	end
	-- Feet onto the board and hands around it.
	KeepNeck(ent, world)
	if not Skater.Skip.anim then Anim.PostPose(ent, world, pose) end
	lastWorld = world
	for i = 0, count - 1 do
		if world[i] and writable[i] then ent:SetBoneMatrix(i, world[i]) end
	end
end

-- Refit when the foot or head mode changes, no need to change models.
for _, name in ipairs({ "skate3_foot_mode", "skate3_pose_head", "skate3_foot_stand" }) do
	cvars.AddChangeCallback(name, function() if IsValid(model) then Fit(model) end end, "skate3_anim")
end

local owner
local pickedName, pickedPath -- the last cl_playermodel looked up

-- The model to ride as. Sandbox can spawn the first life as Kleiner before
-- the player's own pick arrives, so there the pick itself wins.
local function ModelFor(ply)
	-- Posing the real body: it's whatever model the player has.
	if cv_body:GetString() ~= "copy" then return ply:GetModel() end
	local pick = GetConVar("cl_playermodel")
	pick = pick and pick:GetString() or ""
	if GAMEMODE and GAMEMODE.IsSandboxDerived and pick ~= "" and pick ~= "none" then
		if pick ~= pickedName then
			pickedName = pick
			pickedPath = player_manager.TranslatePlayerModel(pick)
			if not (pickedPath and util.IsValidModel(pickedPath)) then pickedPath = nil end
		end
		if pickedPath then return pickedPath end
	end
	return ply:GetModel()
end

-- Rebuilding the stand-in creates an entity, and creating them every frame
-- crashes the game (CUtlRBTree overflow). So at most one rebuild a second,
-- and a model that can't be built isn't retried until the pick changes.
local function SameModel(a, b)
	local function Norm(m) return (m or ""):lower():gsub("\\", "/") end
	return Norm(a) == Norm(b)
end

local REBUILD_EVERY = 1
local lastBuild = -math.huge
local failedName

function Skater.ShowModel(ply)
	if not data then return end
	owner = ply
	local name = ModelFor(ply)
	if not IsValid(model) or model.skate3Name ~= name then
		if name == failedName or RealTime() - lastBuild < REBUILD_EVERY then return end
		lastBuild = RealTime()
		if IsValid(model) then model:Remove() end
		model = ClientsideModel(name, RENDERGROUP_OPAQUE)
		if not IsValid(model) then
			failedName = name
			print("[skate3] couldn't load playermodel " .. tostring(name))
			return
		end
		failedName = nil
		print("[skate3] riding as " .. name)
		-- What was asked for, not GetModel(): the two can differ in case or
		-- slashes, which would rebuild the model every frame.
		model.skate3Name = name
		-- Full detail, so every bone the retarget writes is in the skeleton.
		model:SetLOD(0)
		CaptureRest(model)
		Fit(model)
		FindNeck(model)
		local real, why = cv_body:GetString() ~= "copy", nil
		if real then real, why = Body.Ready(model) end
		if cv_body:GetString() ~= "copy" and not real then
			print("[skate3] can't pose your own body here (" .. tostring(why) .. "), using a copy of it instead")
		end
		model.skate3Real = real
		if real then
			-- This copy is only measured, never drawn: your own body skates.
			model:SetNoDraw(true)
			frozen = Body.FrozenLocals(model, rest)
			pelvis = model:LookupBone("ValveBiped.Bip01_Pelvis")
			skeleton = {}
			for i = 0, model:GetBoneCount() - 1 do
				skeleton[i] = (model:GetBoneName(i) or ""):find("^ValveBiped%.Bip01_") ~= nil
			end
			print(("[skate3] posing your own body, frozen on %s"):format(frozen.sequence))
		end
		local callback = not real and cv_bones:GetString() == "callback"
		-- The finishing touches work on whichever body is drawn.
		model.skate3AnimEnt = real and ply or model
		Anim.Setup(model.skate3AnimEnt, rest, data, stand)
		if callback then
			model:AddCallback("BuildBonePositions", BuildBones)
		end
		if not real then model.RenderOverride = function(self, flags)
			-- Pose the bones right before drawing, after setting up the whole
			-- skeleton. Inside the engine's own setup (the callback) other
			-- views like portals set up only part of it and refuse the rest.
			if not callback and pose and pose.bones and not Skater.Skip.bones then
				self:SetupBones()
				BuildBones(self, self:GetBoneCount())
			end
			if not Skater.Skip.model then self:DrawModel(flags) end
			-- The board draws with the skater rather than from a render hook:
			-- another addon's hook returning a value skips every hook after
			-- it, which hid the board on some maps.
			if pose and not Skater.Skip.board then Skater.DrawBoard(pose) end
		end end
		model:SetRenderBounds(Vector(-96, -96, -32), Vector(96, 96, 128))
	end
	-- Skin and bodygroups only carry over when the player really wears this
	-- model; another model's bodygroup numbers can switch off a helmet or head.
	if SameModel(ply:GetModel(), name) then
		model:SetSkin(ply:GetSkin())
		for i = 0, ply:GetNumBodyGroups() - 1 do
			model:SetBodygroup(i, ply:GetBodygroup(i))
		end
	end
	model.GetPlayerColor = function() return ply:GetPlayerColor() end
	if not model.skate3Real then model:SetNoDraw(false) end
end

-- What the retarget does with each of the playermodel's bones, for working
-- out why a model looks wrong. Prints to the console and saves
-- data/skate3/bone_report.txt.
concommand.Add("skate3_bone_report", function()
	if not IsValid(model) then print("[skate3] get on the board first, then run this") return end
	local ply = LocalPlayer()
	local lines = {
		"model " .. tostring(model.skate3Name) .. ", player wears " .. tostring(ply:GetModel()),
		("%d bones, %d bodygroups, rest pose from the %s"):format(model:GetBoneCount(),
			model:GetNumBodyGroups(), restFrom),
		model.skate3Real and ("posing your own body, frozen on %s"):format(frozen and frozen.sequence or "?")
			or "posing a copy (skate3_body copy, or your own body couldn't be posed)",
	}
	for i = 0, model:GetNumBodyGroups() - 1 do
		lines[#lines + 1] = ("bodygroup %d %s = %d (player %d)"):format(i, model:GetBodygroupName(i),
			model:GetBodygroup(i), ply:GetBodygroup(i))
	end
	for i = 0, model:GetBoneCount() - 1 do
		local parent = model:GetBoneParent(i)
		local how = fits[i] and ("follows " .. fits[i].skate) or "rides parent"
		if not rest[i] then how = "NO REST POSE"
		elseif not writable[i] then how = "not written" end
		local p = rest[i] and rest[i]:GetTranslation() or vector_origin
		lines[#lines + 1] = ("%3d %-36s parent %3d  %-20s rest %.1f %.1f %.1f"):format(i,
			model:GetBoneName(i), parent, how, p.x, p.y, p.z)
	end
	file.CreateDir("skate3")
	file.Write("skate3/bone_report.txt", table.concat(lines, "\n"))
	for _, l in ipairs(lines) do print("[skate3] " .. l) end
	print("[skate3] saved garrysmod/data/skate3/bone_report.txt")
end)

-- Where your hips should have ended up last frame, and how long they've been
-- somewhere else.
local lastFrame
local pelvisWant
local offFrames, offWarned = 0, false

-- Whether the engine put the body where we asked: the hips from last
-- frame's setup against where they were meant to go. Said once per ride in
-- the console when it's off for a second, since that means this Gmod
-- places players differently than expected (skate3_body_report says more).
local function CheckLanding()
	if not (pelvisWant and pelvis and IsValid(owner)) or offWarned then return end
	local got = owner:GetBoneMatrix(pelvis)
	if not got then return end
	local off = got:GetTranslation():Distance(pelvisWant:GetTranslation())
	local turn = (got:GetForward() - pelvisWant:GetForward()):Length() + (got:GetUp() - pelvisWant:GetUp()):Length()
	offFrames = (off > 6 or turn > 0.3) and offFrames + 1 or 0
	if offFrames > 60 then
		offWarned = true
		print(("[skate3] your body isn't landing on the skater: hips %.0f units away, turned off by %.2f. Run skate3_body_report and send the thread data/skate3/body_report.txt; skate3_body copy goes back to the old way."):format(off, turn))
	end
end

-- Your skater's pose p as a frame for Body.Apply (and, the same numbers, for
-- other players): each posed bone's world turn relative to the way the
-- skater faces, and where the hips go.
local function RealFrame(p)
	local origin = Vector(p.pos[1], p.pos[2], p.pos[3])
	local forward = Vector(p.forward[1], p.forward[2], p.forward[3])
	local up = Vector(p.up[1], p.up[2], p.up[3])
	local yaw = forward:Angle().y
	local E0 = Matrix()
	E0:SetAngles(Angle(0, yaw, 0))
	E0:SetTranslation(origin)
	local toFace = E0:GetInverseTR()
	-- The whole skeleton the way the copy gets it first, so the finishing
	-- touches (feet on the board, hands round it) can work on it.
	local world, skins, driven = {}, {}, {}
	local hips
	for i = 0, frozen.count - 1 do
		local fit = fits[i]
		local posed = fit and p.bones[fit.skate]
		if posed then hips = Mat(posed) * fit.pre break end
	end
	for i = 0, frozen.count - 1 do
		local fit = fits[i]
		local posed = fit and p.bones[fit.skate]
		local skin
		if posed then
			skin = Mat(posed) * fit.pre
			driven[i] = true
		else
			local par = frozen.parents[i]
			skin = par >= 0 and skins[par] or hips
		end
		skins[i] = skin
		if skin and rest[i] then world[i] = skin * rest[i] end
	end
	KeepNeck(model, world)
	if not Skater.Skip.anim then
		local before = {}
		for i, m in pairs(world) do before[i] = m end
		Anim.PostPose(owner, world, p)
		-- What it moved of the ValveBiped skeleton (fingers, legs) is turned
		-- too; hair, tails and capes below those stay the engine's, so they
		-- keep swinging.
		for i, m in pairs(world) do
			if before[i] ~= m and skeleton[i] then driven[i] = true end
		end
	end
	lastWorld = world
	-- The finished pose of every skeleton bone the copy would write, exactly
	-- as the copy gets it: your body is set to it at the end of each setup.
	local rots, final, sent = {}, {}, {}
	for i = 0, frozen.count - 1 do
		if world[i] and writable[i] and skeleton[i] and frozen.locals[i] then
			final[i] = world[i]
			local rel = toFace * world[i]
			local r = Body.RotOnly(rel)
			rots[i] = r
			sent[#sent + 1] = { i = i, q = Body.Quat(r), p = rel:GetTranslation() }
		end
	end
	local hipsAt = pelvis and world[pelvis] and toFace * world[pelvis]:GetTranslation()
	pelvisWant = pelvis and world[pelvis]
	local board = {}
	for _, part in ipairs(data and data.parts or {}) do
		local m = p.bones[part.bone]
		if m and not board[part.bone] then
			board[part.bone] = true
			local mm = Mat(m)
			board[#board + 1] = { name = part.bone, pos = mm:GetTranslation() - origin, q = Body.Quat(mm) }
		end
	end
	lastFrame = {
		origin = origin, yaw = yaw, state = p.state, forward = forward, up = up,
		bones = sent, pelvis = hipsAt and pelvis or nil, ppos = hipsAt, board = board,
	}
	return { origin = origin, yaw = yaw, rots = rots, final = final, hips = hipsAt and pelvis or nil, hipsAt = hipsAt },
		forward, up
end

-- The last frame of your own body, to send to other players; nil when your
-- body isn't the one skating.
function Skater.NetFrame()
	return IsValid(model) and model.skate3Real and pose and lastFrame or nil
end

function Skater.UpdateModel(p)
	pose = p
	-- The player's model can change mid-ride (or arrive late after spawning).
	if IsValid(owner) and IsValid(model) and model.skate3Name ~= ModelFor(owner) then
		Skater.ShowModel(owner)
	end
	if not (IsValid(model) and p) then return end
	model:SetPos(Vector(p.pos[1], p.pos[2], p.pos[3]))
	if model.skate3Real and frozen and IsValid(owner) and p.bones and not Skater.Skip.bones then
		CheckLanding()
		local frame, forward, up = RealFrame(p)
		Body.Apply(owner, frame, frozen)
		if not Skater.Skip.board then
			Body.ShowBoard(owner, { pos = p.pos, bones = p.bones, forward = forward, up = up }, Skater.DrawBoard)
		end
	end
end

-- Faces from a Think hook: flex weights are safe there, and nothing in a
-- render hook may touch the skeleton.
hook.Add("Think", "skate3_anim_face", function()
	if IsValid(model) and pose and (model.skate3Real or not model:GetNoDraw()) then
		Anim.Think(model.skate3AnimEnt or model, pose)
	end
end)

concommand.Add("skate3_anim_report", function()
	if not IsValid(model) then print("[skate3] get on the board first, then run this") return end
	local lines = Anim.Report(model.skate3AnimEnt or model, pose, lastWorld)
	file.CreateDir("skate3")
	file.Write("skate3/anim_report.txt", "model " .. tostring(model.skate3Name) .. "\n" .. table.concat(lines, "\n"))
	for _, l in ipairs(lines) do print("[skate3] " .. l) end
	print("[skate3] saved garrysmod/data/skate3/anim_report.txt")
end)

-- Where your posed body is against where it should be, for working out why
-- it looks wrong. Prints to the console and saves data/skate3/body_report.txt.
concommand.Add("skate3_body_report", function()
	local ply = LocalPlayer()
	local lines = { "model " .. tostring(ply:GetModel()) }
	local c = Body.Conv()
	lines[#lines + 1] = c and ("bone turns apply %s the animation, angles read %d%d%d%s, offsets in %s axes"):format(
		c.pre and "before" or "after", c.perm[1], c.perm[2], c.perm[3], c.inverse and " inverted" or "", c.space)
		or "bone turns not measured yet"
	lines[#lines + 1] = frozen and ("frozen on " .. tostring(frozen.sequence)) or "no frozen frame (not posing your own body)"
	for _, l in ipairs(Body.Report(ply)) do lines[#lines + 1] = l end
	file.CreateDir("skate3")
	file.Write("skate3/body_report.txt", table.concat(lines, "\n"))
	for _, l in ipairs(lines) do print("[skate3] " .. l) end
	print("[skate3] saved garrysmod/data/skate3/body_report.txt")
end)

function Skater.HideModel()
	if IsValid(model) and IsValid(model.skate3AnimEnt) then Anim.Clear(model.skate3AnimEnt) end
	pose = nil
	lastFrame = nil
	pelvisWant, offFrames, offWarned = nil, 0, false
	if IsValid(model) then model:SetNoDraw(true) end
	if IsValid(owner) then
		Body.Release(owner)
		Body.HideBoard(owner)
	end
end

-- Whether your own body is the one skating (so it must be drawn, not hidden).
function Skater.RealBody()
	return IsValid(model) and model.skate3Real == true and pose ~= nil
end

function Skater.HasBoard()
	return data ~= nil
end

function Skater.HasModel()
	return IsValid(model) and (model.skate3Real and pose ~= nil or not model:GetNoDraw())
end

return Skater
