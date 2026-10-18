util.AddNetworkString("skate3_state")
util.AddNetworkString("skate3_move")
util.AddNetworkString("skate3_pose")
util.AddNetworkString("skate3_bail")
util.AddNetworkString("skate3_injury")
util.AddNetworkString("skate3_blood")
util.AddNetworkString("skate3_watched")
util.AddNetworkString("skate3_interact")

local Pose = include("skate3/sh_pose.lua")
local Interact = include("skate3/sh_interact.lua")

local cv_enabled = CreateConVar("skate3_enabled", "1", FCVAR_ARCHIVE + FCVAR_NOTIFY, "Allow players to use Skate 3 mode")

-- How far a skater may move between two position updates: MAX_STEP plus
-- MAX_SPEED for every second since the last one that was taken. A fixed
-- step (600) used to be the whole limit: bombing a hill (or mach 1, which
-- stays) outran it, or a hitch did, and from then on every update was
-- refused, so the player was left behind and their body vanished. The
-- allowance grows with time, so a skater always gets back in step.
local MAX_STEP = 600
local MAX_SPEED = 40000 -- units/s, about 3600 km/h: well past mach 1

local function Allowed(ply)
	local dt = math.min(CurTime() - (ply.skate3MoveAt or 0), 10)
	return MAX_STEP + dt * MAX_SPEED
end

local function SetSkating(ply, on)
	ply.Skate3 = on
	ply.skate3MoveAt = CurTime()
	ply:SetMoveType(on and MOVETYPE_NONE or MOVETYPE_WALK)
	-- Tells clients who is riding (their sounds and how they draw others).
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
	-- Not a number (NaN, inf) would break the player for good.
	if not (pos.x == pos.x and pos.y == pos.y and pos.z == pos.z) or pos:Length() > 1e7 then return end
	local allowed = Allowed(ply)
	if pos:DistToSqr(ply:GetPos()) > allowed * allowed then return end
	ply.skate3MoveAt = CurTime()
	ply:SetPos(pos)
end)

-- Using doors and buttons with the board out (sh_interact.lua): the skater's
-- game says where they stand and which way they face; the server finds what
-- is there itself and uses it as the use key would.
net.Receive("skate3_interact", function(_, ply)
	local origin, dir = net.ReadVector(), net.ReadNormal()
	if not ply.Skate3 or not ply:Alive() then return end
	local now = CurTime()
	if now - (ply.skate3UseAt or -10) < 0.3 then return end
	ply.skate3UseAt = now
	-- Chest height above where the server has the skater, within a step.
	if not (origin.x == origin.x and origin.y == origin.y and origin.z == origin.z) then return end
	if origin:DistToSqr(ply:GetPos()) > 200 * 200 then return end
	local ent = Interact.Find(origin, dir, ply)
	if not IsValid(ent) or ent:NearestPoint(origin):DistToSqr(origin) > (Interact.REACH + 40) ^ 2 then return end
	-- Other addons' say (prop protection, locked doors).
	if hook.Run("PlayerUse", ply, ent) == false then return end
	ent:Use(ply, ply, USE_TOGGLE, 1)
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
	-- The pose can arrive before the move it goes with.
	local allowed = Allowed(ply) + MAX_STEP
	if not f or f.origin:DistToSqr(ply:GetPos()) > allowed * allowed then return end
	local to = RecipientFilter()
	to:AddPVS(f.origin)
	to:RemovePlayer(ply)
	-- Nobody near enough to see them: their game sends far fewer poses
	-- until someone is, rather than 20 a second for nothing.
	local watched = to:GetCount() > 0
	if ply.skate3Watched ~= watched then
		ply.skate3Watched = watched
		net.Start("skate3_watched")
		net.WriteBool(watched)
		net.Send(ply)
	end
	if not watched then return end
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

-- Injuries (cl_hall_of_meat.lua) cost health too while bail damage is on: a
-- fracture a little, a break a lot, on top of the bail's own hit.
local cv_fracture = CreateConVar("skate3_bail_damage_fracture", "5", FCVAR_ARCHIVE,
	"With bail damage on: health a fractured bone costs (times the scale)", 0, 100)
local cv_break = CreateConVar("skate3_bail_damage_break", "15", FCVAR_ARCHIVE,
	"With bail damage on: health a broken bone costs (times the scale)", 0, 100)
-- One bail can't hurt more than every part of the body breaking once.
local MAX_INJURIES = 36

net.Receive("skate3_injury", function(_, ply)
	local part, level = net.ReadUInt(5), net.ReadUInt(2)
	if not cv_bail:GetBool() or not ply.Skate3 or not ply:Alive() then return end
	if part < 1 or part > 18 or level < 1 or level > 2 then return end
	local now = CurTime()
	if now - (ply.skate3InjuryAt or -10) > 5 then ply.skate3Injuries = 0 end
	ply.skate3InjuryAt = now
	ply.skate3Injuries = (ply.skate3Injuries or 0) + 1
	if ply.skate3Injuries > MAX_INJURIES then return end
	local scale = math.Clamp(cv_bailScale:GetFloat(), 0.1, 10)
	local amount = math.ceil((level == 2 and cv_break or cv_fracture):GetFloat() * scale)
	if amount <= 0 then return end
	local dmg = DamageInfo()
	dmg:SetDamage(amount)
	dmg:SetDamageType(DMG_FALL)
	dmg:SetAttacker(game.GetWorld())
	dmg:SetInflictor(game.GetWorld())
	ply:TakeDamageInfo(dmg)
end)

-- Blood where a bail's hard hits land, for everyone to see. Skate 3 never
-- bled, so the server can turn it off.
local cv_blood = GetConVar("skate3_blood")
-- How far from where the server has the skater a splat may be.
local BLOOD_REACH = 256

net.Receive("skate3_blood", function(_, ply)
	local pos, normal = net.ReadVector(), net.ReadNormal()
	if not cv_blood:GetBool() or not ply.Skate3 or not ply:Alive() then return end
	local now = CurTime()
	if now - (ply.skate3BloodAt or -10) < 0.1 then return end
	ply.skate3BloodAt = now
	if pos:DistToSqr(ply:GetPos()) > BLOOD_REACH * BLOOD_REACH then return end
	util.Decal("Blood", pos + normal * 4, pos - normal * 8, ply)
	local fx = EffectData()
	fx:SetOrigin(pos)
	fx:SetNormal(normal)
	util.Effect("BloodImpact", fx, true, true)
end)

hook.Add("PlayerDeath", "skate3_stop", ForceStop)
hook.Add("PlayerSpawn", "skate3_stop", ForceStop)
hook.Add("PlayerEnteredVehicle", "skate3_stop", ForceStop)

cvars.AddChangeCallback("skate3_enabled", function(_, _, new)
	if new ~= "0" then return end
	for _, ply in ipairs(player.GetAll()) do ForceStop(ply) end
end, "skate3")
