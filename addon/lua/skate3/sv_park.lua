-- Spawning Skate 3 park pieces, and keeping them frozen in place.

local Park = include("skate3/sh_park.lua")

concommand.Add("skate3_spawn_piece", function(ply, _, args)
	if not IsValid(ply) then return end
	local id = args[1]
	local index = Park.Index()
	local info = index and index[id]
	if not info then
		ply:ChatPrint("[skate3] No park piece " .. tostring(id) .. ". Run the setup app to convert them from your disc.")
		return
	end
	if not ply:CheckLimit("props") then return end
	-- The stadium is as big as a map, so only admins (and singleplayer) get it.
	if id == "megapark_stadium" and not ply:IsAdmin() then
		ply:ChatPrint("[skate3] Only admins can spawn the whole stadium.")
		return
	end
	local tr = util.TraceLine({
		start = ply:EyePos(),
		endpos = ply:EyePos() + ply:GetAimVector() * 4096,
		filter = ply,
	})
	local ent = ents.Create("skate3_piece")
	if not IsValid(ent) then return end
	ent:SetPieceId(id)
	ent:SetPos(tr.HitPos)
	ent:SetAngles(Angle(0, math.Round(ply:EyeAngles().y / 15) * 15 + 180, 0))
	ent:Spawn()
	if not IsValid(ent) then return end
	ent:SetCreator(ply)
	undo.Create("Skate 3 park piece")
	undo.AddEntity(ent)
	undo.SetPlayer(ply)
	undo.SetCustomUndoText("Undone " .. info.name)
	undo.Finish()
	ply:AddCleanup("props", ent)
	ply:AddCount("props", ent)
end)

-- The physgun moves pieces, but letting go never leaves one loose.
hook.Add("PhysgunDrop", "skate3_park_freeze", function(_, ent)
	if IsValid(ent) and ent:GetClass() == "skate3_piece" then
		local phys = ent:GetPhysicsObject()
		if IsValid(phys) then
			phys:EnableMotion(false)
			phys:Sleep()
		end
	end
end)

hook.Add("GravGunPickupAllowed", "skate3_park_freeze", function(_, ent)
	if IsValid(ent) and ent:GetClass() == "skate3_piece" then return false end
end)

hook.Add("CanPlayerUnfreeze", "skate3_park_freeze", function(_, ent)
	if IsValid(ent) and ent:GetClass() == "skate3_piece" then return false end
end)
