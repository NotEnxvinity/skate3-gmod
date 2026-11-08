-- A Skate 3 skateboard as a loose prop: spawn it from the Entities tab (Skate 3
-- section), push it about, pick it up with the physgun. It draws the same
-- board the skater rides, from the player's own converted data, in whatever
-- deck, trucks and wheel looks they picked in the settings. Without S3GM's
-- setup it shows a plain wooden stand-in instead. Skaters roll over it
-- rather than crash into it (cl_live_props.lua leaves it out).

AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Skate 3 Skateboard"
ENT.Category = "Skate 3"
ENT.Author = "S3GM"
ENT.Spawnable = true
ENT.RenderGroup = RENDERGROUP_OPAQUE

-- The board's size in Source units: 32 long, 8 wide, 4 tall with trucks and
-- wheels. `skate3_deck_info` prints what the real board measures.
local MINS, MAXS = Vector(-16, -4, -2), Vector(16, 4, 2)

function ENT:Initialize()
	-- Only so the engine treats it as a normal prop; it draws itself.
	self:SetModel("models/hunter/plates/plate.mdl")
	self:DrawShadow(false)
	self:PhysicsInitBox(MINS, MAXS)
	self:SetSolid(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_VPHYSICS)
	if SERVER then
		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:SetMass(3)
			phys:SetMaterial("wood")
			phys:Wake()
		end
	else
		self:SetRenderBounds(MINS - Vector(2, 2, 2), MAXS + Vector(2, 2, 2))
	end
end

if SERVER then
	-- Lands flat on whatever you look at, long way across your view.
	function ENT:SpawnFunction(ply, tr, class)
		if not tr.Hit then return end
		local ent = ents.Create(class)
		if not IsValid(ent) then return end
		ent:SetPos(tr.HitPos + tr.HitNormal * (-MINS.z + 1))
		ent:SetAngles(Angle(0, ply:EyeAngles().y + 90, 0))
		ent:Spawn()
		ent:Activate()
		return ent
	end

	return
end

function ENT:Draw()
	local Skater = S3GM_Skater
	if Skater and Skater.DrawRest and Skater.DrawRest(self:GetWorldTransformMatrix(), MINS.z) then return end
	render.SetColorMaterial()
	render.DrawBox(self:GetPos(), self:GetAngles(), MINS, MAXS, Color(150, 110, 70))
end
