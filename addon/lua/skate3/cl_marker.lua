-- The session marker, as in Skate 3: place one where you stand (on the board
-- or off it), and go back to it with a hold that takes longer the further away
-- it is. The contextual menu (cl_contextmenu.lua) drives it; other modes use it
-- too (a game of S.K.A.T.E. starts at the marker), through S3GM_Marker.
--
-- The server learns the marker as well (skate3_marker), so a mode that runs
-- there can read it with S3GM_GetMarker(ply).

S3GM_Marker = S3GM_Marker or {}
local Marker = S3GM_Marker

local Static = include("skate3/cl_marker_static.lua")

local marker -- { pos = Vector, yaw = number }
local host   -- what cl_skate3.lua gives us: pose(), teleport(pos, yaw), sound(name)

-- cl_skate3.lua says how to read the skater's pose, how to take them
-- somewhere (which restarts the ride there) and how to play one of Skate 3's
-- interface sounds by its record name (false when it couldn't).
function Marker.Bind(functions)
	host = functions
end

function Marker.Has()
	return marker ~= nil
end

-- { pos, yaw } of the marker, or nil. Copies, so callers can't move it.
function Marker.Get()
	if not marker then return nil end
	return { pos = Vector(marker.pos.x, marker.pos.y, marker.pos.z), yaw = marker.yaw }
end

-- Skate 3's own sounds for the marker (front-end events retail posts from
-- UpdateSessionMarker, SK8-ENGINE session_marker/mod.rs), and what plays
-- without the disc's. Placing one is silent: SK8-ENGINE posts
-- "cellphone_place_marker" there, but Skate 3 plays nothing (Enx, test 1).
local SOUNDS = {
	refused = { "cellphone_marker_error", "buttons/button10.wav" },
	go = { "cellphone_goto_marker", "s3gm_marker_static" },
}

-- Without the disc: a short burst of static, made here.
local generated
local function Generate()
	if generated ~= nil then return generated end
	generated = pcall(sound.Generate, "s3gm_marker_static", 22050, 0.3, function(t)
		local left = 1 - t / (22050 * 0.3)
		return (math.random() * 2 - 1) * 0.35 * left * left
	end)
	return generated
end

local function Sound(which)
	local s = SOUNDS[which]
	if host and host.sound and host.sound(s[1]) then return end
	local cv = GetConVar("skate3_volume")
	local volume = cv and cv:GetFloat() or 1
	local ply = LocalPlayer()
	if volume <= 0 or not IsValid(ply) then return end
	if s[2] == "s3gm_marker_static" and not Generate() then return end
	ply:EmitSound(s[2], 0, 100, math.Clamp(volume, 0, 1))
end

local function Tell(pos, yaw)
	net.Start("skate3_marker")
	net.WriteBool(pos ~= nil)
	if pos then
		net.WriteVector(pos)
		net.WriteFloat(yaw)
	end
	net.SendToServer()
end

-- Where the skater is now, if a marker can go there: on four wheels or
-- standing. Returns the position and heading, or nil and why not.
function Marker.Here()
	local pose = host and host.pose()
	if not pose or not pose.camera then return nil, "Can't set a marker here" end
	local state = pose.state or ""
	if state ~= "PhysicsGround" and not state:find("^Biped") then return nil, "Can't set a marker here" end
	local p, f = pose.pos, pose.camera.forward
	return Vector(p[1], p[2], p[3]), Vector(f[1], f[2], f[3]):Angle().y
end

-- Places the marker where the skater is. Returns true if it was placed.
function Marker.SetHere()
	local pos, yaw = Marker.Here()
	if not pos then
		Sound("refused")
		S3GM_UI.Toast(yaw)
		return false
	end
	marker = { pos = pos, yaw = yaw }
	Tell(pos, yaw)
	S3GM_UI.Toast("Marker set")
	return true
end

-- Metres from the skater to the marker, or nil.
function Marker.Distance()
	local pose = host and host.pose()
	if not marker or not pose then return nil end
	local p = pose.pos
	return Vector(p[1], p[2], p[3]):Distance(marker.pos) * 0.0254
end

-- Skate 3's timing for the hold: a fifth of a second up to 100 m away, a
-- second past a kilometre, and nothing within half a metre.
function Marker.HoldTime()
	local metres = Marker.Distance()
	if not metres or metres < 0.5 then return nil end
	return math.Clamp(0.2 + (metres - 100) * 0.8 / 900, 0.2, 1)
end

-- How far along the hold to go back is, 0 to 1, each frame the menu runs:
-- the static fades in with it (Skate 3 shows no bar).
function Marker.Hold(progress)
	Static.Hold(progress)
end

-- Takes the skater to the marker (a fresh ride there, on the board), in a
-- moment of full static with Skate 3's sound.
function Marker.GoTo()
	if not marker or not host then return false end
	Static.Flash()
	host.teleport(marker.pos, marker.yaw)
	Sound("go")
	return true
end

-- Forgets the marker (a new game or map).
function Marker.Clear()
	if marker then Tell(nil) end
	marker = nil
end

return Marker
