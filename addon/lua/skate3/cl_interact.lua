-- Using doors and buttons while skating. The Skate 3 contextual menu (hold
-- L1) calls S3GM_Interact.Use() for its "interact" option and
-- S3GM_Interact.Target() to know whether there's anything to interact with;
-- skate3_interact does the same from the console, so it can be bound to a key.

local Interact = include("skate3/sh_interact.lua")

S3GM_Interact = S3GM_Interact or {}

-- Chest height above the skater's position.
local CHEST = Vector(0, 0, 36)

local getPose

local function V(t)
	return Vector(t[1], t[2], t[3])
end

-- Where the search starts and which way it looks: the way the skater faces.
local function Aim()
	local pose = getPose and getPose()
	if not pose then return end
	local dir = V(pose.forward)
	dir.z = 0
	if dir:LengthSqr() < 1e-4 then return end
	dir:Normalize()
	return V(pose.pos) + CHEST, dir
end

-- The door, button or other usable thing the skater is facing, or nil.
function S3GM_Interact.Target()
	local origin, dir = Aim()
	if not origin then return end
	return Interact.Find(origin, dir, LocalPlayer())
end

-- Asks the server to use what the skater is facing. Returns the entity it
-- went for, or nil when there's nothing in reach.
function S3GM_Interact.Use()
	local origin, dir = Aim()
	if not origin then return end
	local ent = Interact.Find(origin, dir, LocalPlayer())
	if not IsValid(ent) then return end
	net.Start("skate3_interact")
	net.WriteVector(origin)
	net.WriteNormal(dir)
	net.SendToServer()
	return ent
end

concommand.Add("skate3_interact", function()
	S3GM_Interact.Use()
end)

-- cl_skate3.lua says where to find the skater's pose.
return function(poseGetter)
	getPose = poseGetter
	return S3GM_Interact
end
