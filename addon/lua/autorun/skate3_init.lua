-- Skate 3 mode: a native module runs the Skate 3 simulation on each skater's
-- own client (like G64's Mario); the server only keeps their position in sync.

if SERVER then
	AddCSLuaFile("skate3/cl_skate3.lua")
	AddCSLuaFile("skate3/cl_skater.lua")
	AddCSLuaFile("skate3/cl_sounds.lua")
	include("skate3/sv_skate3.lua")
else
	include("skate3/cl_skate3.lua")
end
