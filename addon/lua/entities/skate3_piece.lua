-- One Skate 3 park piece (or the Mega Park stadium). It draws the piece's
-- own mesh and textures, collides with its own Skate 3 collision, and stays
-- frozen so riding on it can't shove it around. The skate module gets the
-- same collision, so the board rides exactly what Skate 3 rides.

AddCSLuaFile()

local Park = include("skate3/sh_park.lua")

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Skate 3 park piece"
ENT.Spawnable = false
ENT.RenderGroup = RENDERGROUP_OPAQUE

function ENT:SetupDataTables()
	self:NetworkVar("String", 0, "PieceId")
end

function ENT:BuildPhysics(piece)
	self:PhysicsFromMesh(Park.Soup(piece))
	self:SetSolid(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_VPHYSICS)
	self:EnableCustomCollisions(true)
	local phys = self:GetPhysicsObject()
	if IsValid(phys) then
		phys:EnableMotion(false)
		phys:SetMaterial("concrete")
	end
end

function ENT:Initialize()
	-- Only so the engine treats it as a normal prop; the piece draws itself.
	self:SetModel("models/hunter/plates/plate.mdl")
	self:DrawShadow(false)
	if SERVER then
		local piece = Park.Get(self:GetPieceId())
		if not piece then
			self:Remove()
			return
		end
		self:BuildPhysics(piece)
		self.home = { self:GetPos(), self:GetAngles() }
	end
end

if SERVER then
	-- Riding on a piece must never move it. Whatever knocks it loose, it's
	-- frozen again and put back where it was placed; only the physgun moves
	-- it, and where it's dropped becomes its new place.
	function ENT:Think()
		local phys = self:GetPhysicsObject()
		if IsValid(phys) and self.home and not self.held then
			local moved = self:GetPos():DistToSqr(self.home[1]) > 0.01
				or math.abs(math.AngleDifference(self:GetAngles().y, self.home[2].y)) > 0.01
				or math.abs(math.AngleDifference(self:GetAngles().p, self.home[2].p)) > 0.01
				or math.abs(math.AngleDifference(self:GetAngles().r, self.home[2].r)) > 0.01
			if phys:IsMotionEnabled() or moved then
				if not self.warned then
					self.warned = true
					print("[skate3] a park piece got knocked loose; pinned it back")
				end
				phys:EnableMotion(false)
				phys:SetVelocityInstantaneous(vector_origin)
				self:SetPos(self.home[1])
				self:SetAngles(self.home[2])
				phys:SetPos(self.home[1])
				phys:SetAngles(self.home[2])
			end
		end
		self:NextThink(CurTime())
		return true
	end

	return
end

local materials = {}

local function MaterialFor(guid)
	if not guid then return Material("models/debug/debugwhite") end
	if materials[guid] then return materials[guid] end
	local png = Material("skate3/park/" .. guid .. ".png", "smooth mips")
	local mat = CreateMaterial("skate3park_" .. guid, "VertexLitGeneric", {
		["$basetexture"] = "models/debug/debugwhite",
	})
	if not png:IsError() then mat:SetTexture("$basetexture", png:GetTexture("$basetexture")) end
	materials[guid] = mat
	return mat
end

-- IMeshes hold at most 65535 vertices; the stadium's groups stay well under,
-- but a group is still cut into pieces of this many triangles to be safe.
local MAX_TRIS = 20000

local function BuildMeshes(piece)
	local built = {}
	for _, g in ipairs(piece.groups) do
		local verts = {}
		local pos, uv, idx = g.pos, g.uv, g.idx
		for t = 1, #idx, 3 do
			local corner = {}
			for k = 0, 2 do
				local i = idx[t + k]
				corner[k + 1] = {
					pos = Vector(pos[i * 3 + 1], pos[i * 3 + 2], pos[i * 3 + 3]),
					u = uv[i * 2 + 1] or 0,
					v = 1 - (uv[i * 2 + 2] or 0),
				}
			end
			-- Skate 3's winding, after the axis swap, faces out clockwise,
			-- like Source's.
			local normal = (corner[3].pos - corner[1].pos):Cross(corner[2].pos - corner[1].pos)
			normal:Normalize()
			for k = 1, 3 do
				corner[k].normal = normal
				verts[#verts + 1] = corner[k]
			end
			if #verts >= MAX_TRIS * 3 then
				local m = Mesh()
				m:BuildFromTriangles(verts)
				built[#built + 1] = { mesh = m, mat = MaterialFor(g.tex) }
				verts = {}
			end
		end
		if #verts > 0 then
			local m = Mesh()
			m:BuildFromTriangles(verts)
			built[#built + 1] = { mesh = m, mat = MaterialFor(g.tex) }
		end
	end
	return built
end

-- The client's copy of the physics doesn't follow the entity by itself; left
-- at the world origin, player movement prediction disagrees with the server
-- and the player sticks to the piece. Keep it where the piece is.
function ENT:SyncPhysics()
	local phys = self:GetPhysicsObject()
	if not IsValid(phys) then return end
	local pos, ang = self:GetPos(), self:GetAngles()
	if phys:GetPos() ~= pos or phys:GetAngles() ~= ang then
		phys:EnableMotion(false)
		phys:SetPos(pos)
		phys:SetAngles(ang)
	end
end

function ENT:Think()
	local id = self:GetPieceId()
	if id == "" or self.loadedId == id then
		if self.loadedId then self:SyncPhysics() end
		return
	end
	local piece = Park.Get(id)
	if not piece then return end
	self.loadedId = id
	self.meshes = BuildMeshes(piece)
	local b = piece.bounds
	self:SetRenderBounds(Vector(b[1][1], b[1][2], b[1][3]), Vector(b[2][1], b[2][2], b[2][3]))
	-- The same physics client side, so walking on it predicts properly.
	self:BuildPhysics(piece)
	self:SyncPhysics()
	hook.Run("Skate3ParkChanged")
end

function ENT:OnRemove()
	if self.meshes then
		for _, m in ipairs(self.meshes) do m.mesh:Destroy() end
		self.meshes = nil
	end
	hook.Run("Skate3ParkChanged")
end

function ENT:Draw()
	if not self.meshes then return end
	cam.PushModelMatrix(self:GetWorldTransformMatrix())
	for _, m in ipairs(self.meshes) do
		render.SetMaterial(m.mat)
		m.mesh:Draw()
	end
	cam.PopModelMatrix()
end
