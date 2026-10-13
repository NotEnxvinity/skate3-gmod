-- Skate 3 mode: a native module runs the Skate 3 simulation on each skater's
-- own client (like G64's Mario); the server only keeps their position in sync.

-- Shared so every client sees the server's choice.
CreateConVar("skate3_spawned_props", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED + FCVAR_NOTIFY,
	"Let skaters ride and grind props players spawn and the map's movable props (1 on, 0 off)")

if SERVER then
	AddCSLuaFile("skate3/cl_skate3.lua")
	AddCSLuaFile("skate3/cl_live_props.lua")
	AddCSLuaFile("skate3/cl_skater.lua")
	AddCSLuaFile("skate3/cl_body.lua")
	AddCSLuaFile("skate3/cl_others.lua")
	AddCSLuaFile("skate3/sh_pose.lua")
	AddCSLuaFile("skate3/cl_skater_anim.lua")
	AddCSLuaFile("skate3/cl_sounds.lua")
	AddCSLuaFile("skate3/cl_score.lua")
	AddCSLuaFile("skate3/cl_menu.lua")
	AddCSLuaFile("skate3/cl_props.lua")
	AddCSLuaFile("skate3/cl_boards.lua")
	AddCSLuaFile("skate3/cl_conflicts.lua")
	AddCSLuaFile("skate3/cl_keyboard.lua")
	AddCSLuaFile("skate3/cl_collision_report.lua")
	include("skate3/sv_skate3.lua")
else
	include("skate3/cl_skate3.lua")
end
