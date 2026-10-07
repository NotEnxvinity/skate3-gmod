-- Spawning Skate 3 park pieces, and keeping them frozen in place.

local Park = include("skate3/sh_park.lua")

-- Places one piece for a player, with undo and the props limit. Returns the
-- piece, or nil (after telling the player why).
function Park.Spawn(ply, id, pos, ang)
	local index = Park.Index()
	local info = index and index[id]
	if not info then
		ply:ChatPrint("[skate3] No park piece " .. tostring(id) .. ". Run the setup app to convert them from your disc.")
		return
	end
	if not ply:CheckLimit("props") then return end
	-- Whole parks are as big as maps, so only admins (and singleplayer) get them.
	if info.category == "Maps" and not ply:IsAdmin() then
		ply:ChatPrint("[skate3] Only admins can spawn whole parks.")
		return
	end
	local ent = ents.Create("skate3_piece")
	if not IsValid(ent) then return end
	ent:SetPieceId(id)
	ent:SetPos(pos)
	ent:SetAngles(ang)
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
	return ent
end

concommand.Add("skate3_spawn_piece", function(ply, _, args)
	if not IsValid(ply) then return end
	local tr = util.TraceLine({
		start = ply:EyePos(),
		endpos = ply:EyePos() + ply:GetAimVector() * 4096,
		filter = ply,
	})
	Park.Spawn(ply, args[1], tr.HitPos, Angle(0, math.Round(ply:EyeAngles().y / 15) * 15 + 180, 0))
end)

local INCHES = 39.3701

concommand.Add("skate3_spawn_preset", function(ply, _, args)
	if not IsValid(ply) then return end
	local preset = Park.Presets[args[1] or ""]
	local index = Park.Index()
	if not preset or not index then
		ply:ChatPrint("[skate3] No park pieces yet. Run the setup app to convert them from your disc.")
		return
	end
	for _, p in ipairs(preset.pieces) do
		if not index[p[1]] then
			ply:ChatPrint("[skate3] This preset needs a piece your converted data doesn't have; run the setup app again.")
			return
		end
	end
	-- It starts just ahead of the player and runs away from them, on the ground.
	local yaw = math.Round(ply:EyeAngles().y / 15) * 15
	local forward = Angle(0, yaw, 0):Forward()
	local start = ply:GetPos() + forward * 14 * INCHES
	local ground = util.TraceLine({ start = start + Vector(0, 0, 64), endpos = start - Vector(0, 0, 4096), filter = ply })
	local origin = ground.HitPos
	-- Pieces run along their own -x, so the preset faces the other way round.
	local rot = Angle(0, yaw + 180, 0)
	undo.Create("Skate 3 " .. preset.name)
	for _, p in ipairs(preset.pieces) do
		local ent = ents.Create("skate3_piece")
		if IsValid(ent) then
			ent:SetPieceId(p[1])
			local offset = Vector(p[2], p[3] + 6, p[4]) * INCHES
			offset:Rotate(rot)
			ent:SetPos(origin + offset)
			ent:SetAngles(rot)
			ent:Spawn()
			if IsValid(ent) then
				ent:SetCreator(ply)
				undo.AddEntity(ent)
				ply:AddCleanup("props", ent)
			end
		end
	end
	undo.SetPlayer(ply)
	undo.SetCustomUndoText("Undone " .. preset.name)
	undo.Finish()
end)

-- Saves and dupes bring pieces back with their piece and still frozen.
duplicator.RegisterEntityClass("skate3_piece", function(ply, data)
	local ent = ents.Create("skate3_piece")
	if not IsValid(ent) then return end
	duplicator.DoGeneric(ent, data)
	if data.DT then ent:RestoreNetworkVars(data.DT) end
	ent:Spawn()
	ent:Activate()
	if IsValid(ply) then ply:AddCleanup("props", ent) end
	return ent
end, "Data")

-- The physgun moves pieces, but letting go never leaves one loose.
hook.Add("OnPhysgunPickup", "skate3_park_freeze", function(_, ent)
	if IsValid(ent) and ent:GetClass() == "skate3_piece" then ent.held = true end
end)

hook.Add("PhysgunDrop", "skate3_park_freeze", function(_, ent)
	if IsValid(ent) and ent:GetClass() == "skate3_piece" then
		local phys = ent:GetPhysicsObject()
		if IsValid(phys) then
			phys:EnableMotion(false)
			phys:Sleep()
		end
		ent.held = nil
		ent.home = { ent:GetPos(), ent:GetAngles() }
	end
end)

hook.Add("GravGunPickupAllowed", "skate3_park_freeze", function(_, ent)
	if IsValid(ent) and ent:GetClass() == "skate3_piece" then return false end
end)

hook.Add("CanPlayerUnfreeze", "skate3_park_freeze", function(_, ent)
	if IsValid(ent) and ent:GetClass() == "skate3_piece" then return false end
end)
