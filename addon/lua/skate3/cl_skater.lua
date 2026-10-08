-- Draws the skater: the Skate 3 board from the player's own converted data,
-- and their playermodel posed from the skater's skeleton.

local Skater = {}

-- For hunting a leak: parts of the per-frame work to switch off while riding,
-- as a list such as "board,bones". board, bones, model, score, sounds, pose,
-- step and net.
local cv_skip = CreateClientConVar("skate3_debug_skip", "", false, false,
	"Debug: per-frame work to skip, comma separated (board, bones, model, score, sounds, pose, step, net, view)")
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
	bind = {}
	for name, m in pairs(skater.bind) do bind[name] = Mat(m) end
	print(("[skate3] board ready: %d parts"):format(#skater.parts))
end

---------------------------------------------------------------------------
-- The board

-- A source mesh can only hold so many triangles.
local MAX_TRIANGLES = 10000

local function BoardMaterial(slot, tint)
	local mat = CreateMaterial("skate3_board_" .. slot, "VertexLitGeneric", {
		["$basetexture"] = "color/white",
		["$model"] = 1,
		["$nocull"] = 1,
	})
	local png = data.textures and (data.textures .. "/" .. slot .. "_base_color.png")
	if png and file.Exists(png, "DATA") then
		local source = Material("../data/" .. png, "smooth mips")
		if not source:IsError() then
			mat:SetTexture("$basetexture", source:GetTexture("$basetexture"))
		end
	end
	mat:SetVector("$color2", Vector(tint[1], tint[2], tint[3]))
	return mat
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
-- bones (fingers, neck, head) ride their nearest mapped ancestor.

-- ValveBiped bone, Skate 3 bone, and the child pair that aims the segment.
local MAP = {
	{ "Pelvis", "HIPS", "Spine", "SPINE" },
	{ "Spine", "SPINE", "Spine1", "SPINE1" },
	{ "Spine1", "SPINE1", "Spine2", "SPINE2" },
	{ "Spine2", "SPINE2", "Spine4", "SPINE3" },
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
	{ "L_Foot", "LEFTFOOT", "L_Toe0", "LEFTTOEBASE" },
	{ "L_Toe0", "LEFTTOEBASE" },
	{ "R_Thigh", "RIGHTUPLEG", "R_Calf", "RIGHTLEG" },
	{ "R_Calf", "RIGHTLEG", "R_Foot", "RIGHTFOOT" },
	{ "R_Foot", "RIGHTFOOT", "R_Toe0", "RIGHTTOEBASE" },
	{ "R_Toe0", "RIGHTTOEBASE" },
}

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

local model -- the clientside stand-in for the local player
local rest = {} -- bone index -> the model's bind Matrix at the origin
-- Bones the engine sets up at all. Writing any other (unused helper bones on
-- some playermodels) logs "Bone is unwriteable" every frame.
local writable = {}
local USED = BONE_USED_BY_ANYTHING or 0x7FF00
local fits = {} -- bone index -> { skate = name, pre = Matrix }

-- The model's rest pose, read once with the entity at the origin.
local function CaptureRest(ent)
	ent:SetPos(vector_origin)
	ent:SetAngles(angle_zero)
	local seq = ent:LookupSequence("ragdoll")
	ent:ResetSequence(seq >= 0 and seq or 0)
	ent:SetCycle(0)
	ent:InvalidateBoneCache()
	ent:SetupBones()
	rest = {}
	writable = {}
	for i = 0, ent:GetBoneCount() - 1 do
		-- A bone the engine didn't set up has no rest pose. Guessing one (the
		-- identity) dropped everything weighted to it by its own height, which
		-- sank some playermodels' heads into their chests, so it's left alone.
		rest[i] = ent:GetBoneMatrix(i)
		writable[i] = rest[i] ~= nil and ent:BoneHasFlag(i, USED)
	end
end

local function Fit(ent)
	fits = {}
	local function Pos(name)
		local i = ent:LookupBone("ValveBiped.Bip01_" .. name)
		return i and rest[i] and rest[i]:GetTranslation(), i
	end
	for _, row in ipairs(MAP) do
		local from, index = Pos(row[1])
		local skate = bind[row[2]]
		if from and skate then
			local to = skate:GetTranslation()
			local a, b
			local child = row[3] and Pos(row[3])
			local skateChild = row[4] and bind[row[4]]
			if child and skateChild then
				a, b = Facing(child - from), skateChild:GetTranslation() - to
			else
				-- Ends of chains keep their parent's alignment.
				local parent = ent:GetBoneParent(index)
				local parentRow
				for _, r in ipairs(MAP) do
					if ent:LookupBone("ValveBiped.Bip01_" .. r[1]) == parent then parentRow = r end
				end
				if parentRow and rest[parent] and bind[parentRow[2]] then
					a, b = Facing(from - rest[parent]:GetTranslation()), to - bind[parentRow[2]]:GetTranslation()
				end
			end
			local rot = Matrix()
			rot:Rotate(FACING)
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

local pose
local cv_bones = CreateClientConVar("skate3_bone_mode", "override", true, false,
	"How the playermodel is posed: override (default) or callback (the older way)")

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
		if skin and rest[i] and writable[i] then
			ent:SetBoneMatrix(i, skin * rest[i])
		end
	end
end

local owner
local pickedName, pickedPath -- the last cl_playermodel looked up

-- The model to ride as. Sandbox can spawn the first life as Kleiner before
-- the player's own pick arrives, so there the pick itself wins.
local function ModelFor(ply)
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
		local callback = cv_bones:GetString() == "callback"
		if callback then
			model:AddCallback("BuildBonePositions", BuildBones)
		end
		model.RenderOverride = function(self, flags)
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
		end
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
	model:SetNoDraw(false)
end

-- What the retarget does with each of the playermodel's bones, for working
-- out why a model looks wrong. Prints to the console and saves
-- data/skate3/bone_report.txt.
concommand.Add("skate3_bone_report", function()
	if not IsValid(model) then print("[skate3] get on the board first, then run this") return end
	local ply = LocalPlayer()
	local lines = {
		"model " .. tostring(model.skate3Name) .. ", player wears " .. tostring(ply:GetModel()),
		("%d bones, %d bodygroups"):format(model:GetBoneCount(), model:GetNumBodyGroups()),
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

function Skater.UpdateModel(p)
	pose = p
	-- The player's model can change mid-ride (or arrive late after spawning).
	if IsValid(owner) and IsValid(model) and model.skate3Name ~= ModelFor(owner) then
		Skater.ShowModel(owner)
	end
	if IsValid(model) and p then
		model:SetPos(Vector(p.pos[1], p.pos[2], p.pos[3]))
	end
end

function Skater.HideModel()
	pose = nil
	if IsValid(model) then model:SetNoDraw(true) end
end

function Skater.HasBoard()
	return data ~= nil
end

function Skater.HasModel()
	return IsValid(model) and not model:GetNoDraw()
end

return Skater
