-- Skate 3 mode: a native module runs the Skate 3 simulation on each skater's
-- own client (like G64's Mario); the server only keeps their position in sync.

-- Shared so every client sees the server's choice.
CreateConVar("skate3_spawned_props", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED + FCVAR_NOTIFY,
	"Let skaters ride and grind props players spawn and the map's movable props (1 on, 0 off)")

CreateConVar("skate3_blood", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED + FCVAR_NOTIFY,
	"Blood splats where bails hit hard (1 on, 0 off)")

-- Other players: crashes between skaters, and punches and board swings. All
-- of them can be turned off by the server.
CreateConVar("skate3_player_collision", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED + FCVAR_NOTIFY,
	"Skaters crash into other players: a hard enough hit bails them (1 on, 0 off)")
CreateConVar("skate3_player_collision_speed", "4", FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"How fast two players must close in on each other to crash, in metres a second (about 3.6 km/h each)", 0.5, 50)
CreateConVar("skate3_player_hits", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED + FCVAR_NOTIFY,
	"Players on foot with the board can punch and swing it at other players (1 on, 0 off)")
CreateConVar("skate3_hit_damage", "0", FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"Health a punch takes; a board swing takes twice and a crash with a walking player the same (0 = hits don't hurt, the default)", 0, 100)

if SERVER then
	AddCSLuaFile("skate3/cl_skate3.lua")
	AddCSLuaFile("skate3/cl_players.lua")
	AddCSLuaFile("skate3/cl_live_props.lua")
	AddCSLuaFile("skate3/cl_hall_of_meat.lua")
	AddCSLuaFile("skate3/cl_skater.lua")
	AddCSLuaFile("skate3/cl_body.lua")
	AddCSLuaFile("skate3/cl_others.lua")
	AddCSLuaFile("skate3/sh_pose.lua")
	AddCSLuaFile("skate3/sh_interact.lua")
	AddCSLuaFile("skate3/cl_interact.lua")
	AddCSLuaFile("skate3/cl_skater_anim.lua")
	AddCSLuaFile("skate3/cl_sounds.lua")
	AddCSLuaFile("skate3/cl_ui.lua")
	AddCSLuaFile("skate3/cl_glyphs.lua")
	AddCSLuaFile("skate3/cl_marker.lua")
	AddCSLuaFile("skate3/cl_marker_static.lua")
	AddCSLuaFile("skate3/cl_contextmenu.lua")
	AddCSLuaFile("skate3/cl_customize.lua")
	AddCSLuaFile("skate3/cl_score.lua")
	AddCSLuaFile("skate3/cl_score_skate3.lua")
	AddCSLuaFile("skate3/cl_update.lua")
	AddCSLuaFile("skate3/cl_menu.lua")
	AddCSLuaFile("skate3/cl_props.lua")
	AddCSLuaFile("skate3/cl_park.lua")
	AddCSLuaFile("skate3/sh_park.lua")
	AddCSLuaFile("skate3/cl_boards.lua")
	AddCSLuaFile("skate3/cl_conflicts.lua")
	AddCSLuaFile("skate3/cl_keyboard.lua")
	AddCSLuaFile("skate3/cl_collision_report.lua")
	AddCSLuaFile("skate3/cl_surfaces.lua")
	AddCSLuaFile("skate3/cl_perf.lua")
	AddCSLuaFile("skate3/cl_perf_test.lua")
	AddCSLuaFile("skate3/cl_demo.lua")
	include("skate3/sv_skate3.lua")
	include("skate3/sv_park.lua")
	include("skate3/sv_customize.lua")
else
	include("skate3/cl_skate3.lua")
end
