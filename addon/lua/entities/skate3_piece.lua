-- One Skate 3 park piece, or one tile of a skatepark. It draws the piece's
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

local cv_physics = CreateConVar("skate3_park_physics", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED + FCVAR_NOTIFY,
	"Give park pieces Garry's Mod physics, so you can walk on them and aim at them (1 on, 0 off). The board rides them either way")

function ENT:SetupDataTables()
	self:NetworkVar("String", 0, "PieceId")
	self:NetworkVar("Bool", 0, "Locked")
end

-- Tiles make up a park: they go in and out as one and aren't moved alone.
function ENT:IsTile()
	return self:GetPieceId():find("_t%d+$") ~= nil
end

-- Without physics of its own a piece has none: the client would otherwise
-- keep the plain model's, a small loose body that falls and slides.
function ENT:NoPhysics()
	if CLIENT then self:PhysicsDestroy() end
end

function ENT:BuildPhysics(piece)
	if Park.Safe or not cv_physics:GetBool() then return self:NoPhysics() end
	local soup = Park.Soup(piece)
	local count = #soup / 3
	if count < 1 then return self:NoPhysics() end
	if count > Park.MAX_PHYSICS then
		print(("[skate3] %s has %d collision triangles, too many for Garry's Mod physics; the board still rides it"):format(piece.id or "a piece", count))
		return self:NoPhysics()
	end
	if self:PhysicsFromMesh(soup) == false then return self:NoPhysics() end
	self:SetSolid(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_VPHYSICS)
	self:EnableCustomCollisions(true)
	self:SetCustomCollisionCheck(true)
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
		-- The server never draws or rides it, and a tile is big.
		piece.soup = nil
		if self:IsTile() then Park.Forget(self:GetPieceId()) end
	else
		self:FreezeModelPhysics()
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
		self:NextThink(CurTime() + 0.25)
		return true
	end

	return
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

-- Building a piece's meshes and physics takes a moment; a park of many tiles
-- builds one tile per frame instead of all in one.
local builtFrame, builtCount = 0, 0

-- Until the piece's own physics is built, the client entity has the plain
-- model's: a loose body that falls and slides client side, and only a resync
-- (the physgun) puts it back. It never gets to move.
function ENT:FreezeModelPhysics()
	local phys = self:GetPhysicsObject()
	if IsValid(phys) and phys:IsMotionEnabled() then phys:EnableMotion(false) end
end

function ENT:Think()
	local id = self:GetPieceId()
	if id == "" then return end
	if self.loadedId ~= id then self:FreezeModelPhysics() end
	if self.loadedId == id then
		self:SyncPhysics()
		return
	end
	local frame = FrameNumber()
	if builtFrame ~= frame then builtFrame, builtCount = frame, 0 end
	if builtCount >= 1 then return end
	local piece = Park.Get(id)
	if not piece then return end
	builtCount = builtCount + 1
	self.loadedId = id
	self.meshes = Park.Meshes(id)
	local b = piece.bounds
	self.localCenter = Vector((b[1][1] + b[2][1]) / 2, (b[1][2] + b[2][2]) / 2, (b[1][3] + b[2][3]) / 2)
	self.localMins, self.localMaxs = Vector(b[1][1], b[1][2], b[1][3]), Vector(b[2][1], b[2][2], b[2][3])
	self:SetRenderBounds(self.localMins, self.localMaxs)
	-- The same physics client side, so walking on it predicts properly.
	self:BuildPhysics(piece)
	self:SyncPhysics()
	piece.soup = nil
	-- The tile's drawing is in its meshes now.
	if self:IsTile() then piece.groups = nil end
end

-- A removed skatepark lets its meshes go (a loose piece's are shared).
function ENT:OnRemove()
	if self.loadedId and self:IsTile() then Park.ReleaseMeshes(self.loadedId) end
end

-- Where the middle of the piece is, for sorting by distance.
function ENT:WorldCenter()
	if self.localCenter then return self:LocalToWorld(self.localCenter) end
	return self:GetPos()
end

-- How far (squared) `pos` is from the piece's box: zero inside it. A tile of
-- a park is big, and by its middle the one under you can look far away.
function ENT:DistanceSqrTo(pos)
	if not self.localMins then return self:GetPos():DistToSqr(pos) end
	local at = self:WorldToLocal(pos)
	local out = Vector(
		math.max(self.localMins.x - at.x, 0, at.x - self.localMaxs.x),
		math.max(self.localMins.y - at.y, 0, at.y - self.localMaxs.y),
		math.max(self.localMins.z - at.z, 0, at.z - self.localMaxs.z))
	return out:LengthSqr()
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
