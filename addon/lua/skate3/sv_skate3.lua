util.AddNetworkString("skate3_state")
util.AddNetworkString("skate3_move")

local cv_enabled = CreateConVar("skate3_enabled", "1", FCVAR_ARCHIVE + FCVAR_NOTIFY, "Allow players to use Skate 3 mode")

-- Farthest a skater may move between two position updates, in units. Skate 3
-- tops out around 800 units/s and clients update 20 times a second, so this
-- leaves room for hitches without allowing teleports.
local MAX_STEP = 600

local function SetSkating(ply, on)
	ply.Skate3 = on
	-- Everyone else stops drawing the board in this player's hands.
	ply:SetNWBool("skate3_riding", on)
	ply:SetMoveType(on and MOVETYPE_NONE or MOVETYPE_WALK)
end

local function ForceStop(ply)
	if not ply.Skate3 then return end
	SetSkating(ply, false)
	net.Start("skate3_state")
	net.WriteBool(false)
	net.Send(ply)
end

net.Receive("skate3_state", function(_, ply)
	local on = net.ReadBool()
	if on and (not cv_enabled:GetBool() or not ply:Alive() or ply:InVehicle()) then
		SetSkating(ply, false)
		net.Start("skate3_state")
		net.WriteBool(false)
		net.Send(ply)
		return
	end
	SetSkating(ply, on)
end)

net.Receive("skate3_move", function(_, ply)
	if not ply.Skate3 then return end
	local pos = net.ReadVector()
	if pos:DistToSqr(ply:GetPos()) > MAX_STEP * MAX_STEP then return end
	ply:SetPos(pos)
end)

hook.Add("PlayerDeath", "skate3_stop", ForceStop)
hook.Add("PlayerSpawn", "skate3_stop", ForceStop)
hook.Add("PlayerEnteredVehicle", "skate3_stop", ForceStop)

cvars.AddChangeCallback("skate3_enabled", function(_, _, new)
	if new ~= "0" then return end
	for _, ply in ipairs(player.GetAll()) do ForceStop(ply) end
end, "skate3")
