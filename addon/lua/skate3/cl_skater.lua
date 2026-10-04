-- Draws the skater: the Skate 3 board from the player's own converted data,
-- and their playermodel posed from the skater's skeleton.

local Skater = {}

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
	held = nil
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

-- Returns false when there's no board to draw.
function Skater.DrawBoard(pose)
	if not data or not pose.bones then return false end
	if not parts then BuildBoard() end
	local light = render.GetLightColor(Vector(pose.pos[1], pose.pos[2], pose.pos[3] + 8))
	render.SuppressEngineLighting(true)
	render.ResetModelLighting(light.x * 0.6 + 0.05, light.y * 0.6 + 0.05, light.z * 0.6 + 0.05)
	render.SetModelLighting(BOX_TOP, light.x, light.y, light.z)
	for _, part in ipairs(parts) do
		local m = pose.bones[part.bone]
		if m then
			render.SetMaterial(part.material)
			cam.PushModelMatrix(Mat(m))
			for _, piece in ipairs(part.meshes) do piece:Draw() end
			cam.PopModelMatrix()
		end
	end
	render.SuppressEngineLighting(false)
	return true
end

---------------------------------------------------------------------------
-- The board in hand
--
-- Carried at the right side the way skaters do: deck on edge, grip toward the
-- leg, nose forward, the hand on the top edge.

local held -- part index -> Matrix taking the part into the board's own frame
local heldSize -- the board's length, width and thickness

-- The board's own frame: x along its length, z out of the grip, centred.
local function BuildHeld()
	local root = bind.SKATEBOARD_ROOT
	local into = root and root:GetInverse() or Matrix()
	local rel, lo, hi = {}, Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
	local sums = { deck = { Vector(), 0 }, wheels = { Vector(), 0 } }
	for i, p in ipairs(data.parts) do
		rel[i] = into * (bind[p.bone] or Matrix())
		local sum = p.slot == "SkateWheel" and sums.wheels or p.slot == "SkateBoard" and sums.deck
		local v = p.vertices
		for o = 0, #v - 1, 8 do
			local at = rel[i] * Vector(v[o + 1], v[o + 2], v[o + 3])
			for _, k in ipairs({ "x", "y", "z" }) do
				lo[k] = math.min(lo[k], at[k])
				hi[k] = math.max(hi[k], at[k])
			end
			if sum then
				sum[1]:Add(at)
				sum[2] = sum[2] + 1
			end
		end
	end
	if lo.x > hi.x then return end
	local size, center = hi - lo, (lo + hi) * 0.5
	local axes = { "x", "y", "z" }
	table.sort(axes, function(a, b) return size[a] > size[b] end)
	local unit = { x = Vector(1, 0, 0), y = Vector(0, 1, 0), z = Vector(0, 0, 1) }
	local x, z = unit[axes[1]], Vector(unit[axes[3]])
	-- The grip faces away from the wheels.
	local deck, wheels = sums.deck, sums.wheels
	if deck[2] > 0 and wheels[2] > 0 and (deck[1] / deck[2] - wheels[1] / wheels[2]):Dot(z) < 0 then
		z:Mul(-1)
	end
	local y = z:Cross(x)
	local align = Matrix({
		{ x.x, x.y, x.z, -x:Dot(center) },
		{ y.x, y.y, y.z, -y:Dot(center) },
		{ z.x, z.y, z.z, -z:Dot(center) },
		{ 0, 0, 0, 1 },
	})
	held = {}
	for i, m in ipairs(rel) do held[i] = align * m end
	heldSize = { size[axes[1]], size[axes[2]], size[axes[3]] }
end

-- Draws the board in ply's right hand, or at the bottom right of the view.
function Skater.DrawHeld(ply, firstPerson)
	if not data then return end
	if not parts then BuildBoard() end
	if not held then
		BuildHeld()
		if not held then return end
	end
	local width, thick = heldSize[2], heldSize[3]
	local pos, f, r, u
	if firstPerson then
		local ang = ply:EyeAngles()
		f, r, u = ang:Forward(), ang:Right(), ang:Up()
		pos = ply:EyePos() + f * 18 + r * 11 - u * 14
	else
		local ang = Angle(0, ply:GetAngles().y, 0)
		f, r, u = ang:Forward(), ang:Right(), ang:Up()
		local hand = ply:LookupBone("ValveBiped.Bip01_R_Hand")
		local at = hand and ply:GetBonePosition(hand)
		if not at or at == ply:GetPos() then at = ply:GetPos() + u * 34 + r * 9 end
		pos = at - u * (width * 0.5 - 1) + r * (thick * 0.5 + 1)
	end
	-- Board x along forward, grip (z) toward the body, so its width runs down.
	local x, y, z = f, -u, -r
	local hold = Matrix({
		{ x.x, y.x, z.x, pos.x },
		{ x.y, y.y, z.y, pos.y },
		{ x.z, y.z, z.z, pos.z },
		{ 0, 0, 0, 1 },
	})
	local light = render.GetLightColor(pos)
	render.SuppressEngineLighting(true)
	render.ResetModelLighting(light.x * 0.6 + 0.05, light.y * 0.6 + 0.05, light.z * 0.6 + 0.05)
	render.SetModelLighting(BOX_TOP, light.x, light.y, light.z)
	for i, part in ipairs(parts) do
		render.SetMaterial(part.material)
		cam.PushModelMatrix(hold * held[i])
		for _, piece in ipairs(part.meshes) do piece:Draw() end
		cam.PopModelMatrix()
	end
	render.SuppressEngineLighting(false)
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
	for i = 0, ent:GetBoneCount() - 1 do
		rest[i] = ent:GetBoneMatrix(i) or Matrix()
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

local function BuildBones(ent, count)
	if not pose or not pose.bones then return end
	local skins = {}
	local pelvis
	for i = 0, count - 1 do
		local fit = fits[i]
		local posed = fit and pose.bones[fit.skate]
		local skin
		if posed then
			skin = Mat(posed) * fit.pre
			pelvis = pelvis or skin
		else
			local parent = ent:GetBoneParent(i)
			skin = parent >= 0 and skins[parent] or pelvis
		end
		skins[i] = skin
		if skin and rest[i] then
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

function Skater.ShowModel(ply)
	if not data then return end
	owner = ply
	local name = ModelFor(ply)
	if not IsValid(model) or model:GetModel() ~= name then
		if IsValid(model) then model:Remove() end
		model = ClientsideModel(name, RENDERGROUP_OPAQUE)
		if not IsValid(model) then return end
		CaptureRest(model)
		Fit(model)
		model:AddCallback("BuildBonePositions", BuildBones)
		model:SetRenderBounds(Vector(-96, -96, -32), Vector(96, 96, 128))
	end
	model:SetSkin(ply:GetSkin())
	for i = 0, ply:GetNumBodyGroups() - 1 do
		model:SetBodygroup(i, ply:GetBodygroup(i))
	end
	model.GetPlayerColor = function() return ply:GetPlayerColor() end
	model:SetNoDraw(false)
end

function Skater.UpdateModel(p)
	pose = p
	-- The player's model can change mid-ride (or arrive late after spawning).
	if IsValid(owner) and IsValid(model) and model:GetModel() ~= ModelFor(owner) then
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

function Skater.HasModel()
	return IsValid(model) and not model:GetNoDraw()
end

return Skater
