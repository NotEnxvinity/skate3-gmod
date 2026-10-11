util.AddNetworkString("skate3_state")
util.AddNetworkString("skate3_move")
util.AddNetworkString("skate3_pose")
util.AddNetworkString("skate3_bail")

local Pose = include("skate3/sh_pose.lua")

local cv_enabled = CreateConVar("skate3_enabled", "1", FCVAR_ARCHIVE + FCVAR_NOTIFY, "Allow players to use Skate 3 mode")

-- Farthest a skater may move between two position updates, in units. Skate 3
-- tops out around 800 units/s and clients update 20 times a second, so this
-- leaves room for hitches without allowing teleports.
local MAX_STEP = 600

local function SetSkating(ply, on)
	ply.Skate3 = on
	ply:SetMoveType(on and MOVETYPE_NONE or MOVETYPE_WALK)
	-- Park pieces ignore a skater's Gmod body (see sh_park.lua).
	ply:SetNW2Bool("skate3_riding", on)
	ply:CollisionRulesChanged()
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

-- A skater's Garry's Mod body stands still or is moved by the simulation, so
-- its footsteps would sound in place; the skate sounds play the real ones.
hook.Add("PlayerFootstep", "skate3_quiet", function(ply)
	if ply.Skate3 then return true end
end)

-- A skater's pose, passed on to everyone near them (their game runs the
-- skating; the others pose that player's body from this).
local POSE_EVERY = 1 / 30
net.Receive("skate3_pose", function(len, ply)
	if not ply.Skate3 or len > 40000 then return end
	local now = SysTime()
	if now - (ply.skate3PoseAt or 0) < POSE_EVERY then return end
	ply.skate3PoseAt = now
	local f = Pose.Read()
	if not f or f.origin:DistToSqr(ply:GetPos()) > MAX_STEP * MAX_STEP then return end
	local to = RecipientFilter()
	to:AddPVS(f.origin)
	to:RemovePlayer(ply)
	if to:GetCount() == 0 then return end
	-- Unreliable: a late frame is useless, a newer one follows.
	net.Start("skate3_pose", true)
	net.WriteEntity(ply)
	Pose.Write(f)
	net.Send(to)
end)

-- Bail damage: a server setting, off unless the server turns it on. The
-- faster you were going into the bail, the more it hurts; small bails are
-- free. Your game says how fast you were going when you bail.
local cv_bail = CreateConVar("skate3_bail_damage", "0", FCVAR_ARCHIVE,
	"Bails hurt, by how fast you were going (0 = off, the default)", 0, 1)
local cv_bailGrace = CreateConVar("skate3_bail_damage_grace", "15", FCVAR_ARCHIVE,
	"Bails slower than this many km/h don't hurt", 0, 1000)
local cv_bailScale = CreateConVar("skate3_bail_damage_scale", "1", FCVAR_ARCHIVE,
	"How hard bails hit: 1 normal, 0.1 to 10; at 10 every bail past the grace kills", 0.1, 10)
-- At scale 1, each km/h past the grace is this much damage: a 40 km/h bail
-- with the default grace is 20 damage, 140 km/h kills from full health.
local DAMAGE_PER_KMH = 0.8

net.Receive("skate3_bail", function(_, ply)
	local speed = net.ReadFloat() -- metres a second
	if not cv_bail:GetBool() or not ply.Skate3 or not ply:Alive() then return end
	if not (speed == speed) or speed <= 0 then return end
	-- One bail is one hit, however the message arrives.
	local now = CurTime()
	if now - (ply.skate3BailAt or -10) < 1 then return end
	ply.skate3BailAt = now
	local over = math.min(speed * 3.6, 1e6) - cv_bailGrace:GetFloat()
	if over <= 0 then return end
	local scale = math.Clamp(cv_bailScale:GetFloat(), 0.1, 10)
	local amount = scale >= 10 and 1e6 or math.ceil(over * DAMAGE_PER_KMH * scale)
	local dmg = DamageInfo()
	dmg:SetDamage(amount)
	dmg:SetDamageType(DMG_FALL)
	dmg:SetAttacker(game.GetWorld())
	dmg:SetInflictor(game.GetWorld())
	ply:TakeDamageInfo(dmg)
end)

hook.Add("PlayerDeath", "skate3_stop", ForceStop)
hook.Add("PlayerSpawn", "skate3_stop", ForceStop)
hook.Add("PlayerEnteredVehicle", "skate3_stop", ForceStop)

cvars.AddChangeCallback("skate3_enabled", function(_, _, new)
	if new ~= "0" then return end
	for _, ply in ipairs(player.GetAll()) do ForceStop(ply) end
end, "skate3")
