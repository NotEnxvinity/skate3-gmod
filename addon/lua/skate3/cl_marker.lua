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

-- The hiss under the static: TV static that rises as you hold the way back
-- and ends with it. No recording of it is on the disc (every bank and archive
-- was listened through, and retail's marker code posts no sound while you
-- hold), so it's made here, like the picture's noise, and follows the
-- picture's amount: louder as the hold goes on, full for the teleport's
-- three frames, gone the moment you let go.
local cv_hiss = CreateClientConVar("skate3_marker_static_sound", "1", true, false,
	"TV static sound while going back to your marker (1 on, 0 off)")
local HISS = "s3gm_marker_hiss"
local HISS_RATE, HISS_LENGTH = 22050, 2
local HISS_LEVEL = 0.45
local hiss = { made = nil, patch = nil, volume = 0 }

-- Two seconds of looping static: white noise, a touch of low-pass so it hisses
-- rather than whistles, a slow wobble in level, and the odd crackle.
local function MakeHiss()
	if hiss.made ~= nil then return hiss.made end
	local total = HISS_RATE * HISS_LENGTH
	local low, crackle = 0, 0
	local ok = pcall(sound.Generate, HISS, HISS_RATE, HISS_LENGTH, function(t)
		local white = math.random() * 2 - 1
		low = low + (white - low) * 0.55
		if crackle <= 0 and math.random() < 0.0015 then crackle = math.random(20, 90) end
		local pop = 0
		if crackle > 0 then
			crackle = crackle - 1
			pop = (math.random() * 2 - 1) * 0.6
		end
		-- The wobble ends where it starts, so the loop doesn't jump.
		local wobble = 0.85 + 0.15 * math.sin(t / total * math.pi * 2 * 6)
		-- Fade the first and last few ms into each other for a seamless loop.
		local edge = math.min(1, t / 64, (total - 1 - t) / 64)
		return math.Clamp((low * 0.8 * wobble + pop) * (0.6 + 0.4 * edge), -1, 1)
	end, 0)
	hiss.made = ok
	if not ok then print("[skate3] marker static sound unavailable") end
	return ok
end

local function HissStop()
	if hiss.patch then hiss.patch:Stop() end
	hiss.patch, hiss.volume = nil, 0
end

hook.Add("Think", "skate3_marker_hiss", function()
	local amount = Static.Amount and Static.Amount() or 0
	local cv = GetConVar("skate3_volume")
	local volume = cv and cv:GetFloat() or 1
	local sounds = GetConVar("skate3_sounds")
	if amount <= 0 or not cv_hiss:GetBool() or volume <= 0 or (sounds and sounds:GetString() == "off") then
		if hiss.patch then HissStop() end
		return
	end
	local ply = LocalPlayer()
	if not IsValid(ply) or not MakeHiss() then return end
	if not hiss.patch then
		local ok, patch = pcall(CreateSound, ply, HISS)
		if not ok or not patch then return end
		hiss.patch = patch
		patch:SetSoundLevel(0)
		patch:PlayEx(0, 100)
	end
	local target = math.Clamp(amount * HISS_LEVEL * volume, 0, 1)
	if math.abs(target - hiss.volume) > 0.005 then
		hiss.volume = target
		hiss.patch:ChangeVolume(target, 0.03)
	end
end)

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
