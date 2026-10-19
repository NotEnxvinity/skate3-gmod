-- Demos (record / playdemo). The skater lives on your own computer: the
-- simulation, the posed body, the board and the camera are all client-side,
-- and a demo only holds what the server sent you. Played back, the demo had
-- your player standing wherever the server last had it, and your own
-- controller was still driving a live ride over the top of it.
--
-- So while a demo records, the server sends your own pose and camera back to
-- you (they go into the demo like any other message), and in playback the
-- live ride is off: your skater is drawn from those, the way other players'
-- skaters are drawn.

local Demo = {}

function Demo.Playing()
	return engine.IsPlayingDemo ~= nil and engine.IsPlayingDemo() == true
end

function Demo.Recording()
	return engine.IsRecordingDemo ~= nil and engine.IsRecordingDemo() == true
end

-- The clock frames are timed by: a demo's own time, which stops when it is
-- paused and runs at its playback speed. (RealTime would keep going.)
function Demo.Clock()
	return Demo.Playing() and CurTime() or RealTime()
end

-- Recording: the server is told when it starts and stops, so it only sends
-- you your own pose while there's a demo to put it in.
local recording
local nextCheck = 0

function Demo.Watch(now)
	if now < nextCheck then return end
	nextCheck = now + 0.5
	local rec = Demo.Recording()
	if rec == recording then return end
	recording = rec
	net.Start("skate3_demo")
	net.WriteBool(rec)
	net.SendToServer()
end

-- Recording: your camera as the skater sees it, for the server to send back.
function Demo.SendCamera(origin, forward, up, fov)
	net.Start("skate3_cam", true)
	net.WriteVector(origin)
	net.WriteNormal(forward)
	net.WriteNormal(up)
	net.WriteFloat(fov or 90)
	net.SendToServer()
end

-- Playback: the camera frames that came back.
local DELAY = 0.1 -- the same lag the skater is drawn with (cl_others.lua)
local KEEP = 4
local STALE = 1
local cams = {}
local count = 0

net.Receive("skate3_cam", function()
	local f = { t = Demo.Clock(), pos = net.ReadVector(), fwd = net.ReadNormal(), up = net.ReadNormal(), fov = net.ReadFloat() }
	if not Demo.Playing() then return end
	if not (f.pos.x == f.pos.x and f.fov == f.fov) then return end
	-- A skip back in the demo: the older frames are from the future.
	if cams[#cams] and f.t < cams[#cams].t then cams = {} end
	cams[#cams + 1] = f
	count = count + 1
	while #cams > KEEP do table.remove(cams, 1) end
end)

local function CameraAt(t)
	if #cams == 0 then return nil end
	if t <= cams[1].t then return cams[1] end
	for n = 1, #cams - 1 do
		local a, b = cams[n], cams[n + 1]
		if t <= b.t then
			local k = (t - a.t) / math.max(b.t - a.t, 1e-3)
			local fwd, up = LerpVector(k, a.fwd, b.fwd), LerpVector(k, a.up, b.up)
			fwd:Normalize()
			up:Normalize()
			return { pos = LerpVector(k, a.pos, b.pos), fwd = fwd, up = up, fov = Lerp(k, a.fov, b.fov) }
		end
	end
	return cams[#cams]
end

-- Whether the demo is showing the skate camera right now.
local function Following()
	return Demo.Playing() and #cams > 0 and Demo.Clock() - cams[#cams].t <= STALE
end

hook.Add("CalcView", "skate3_demo_view", function()
	-- Nothing recent (the demo's skater wasn't riding): the demo's own view.
	if not Following() then return end
	local now = Demo.Clock()
	if GetViewEntity() ~= LocalPlayer() then return end
	local c = CameraAt(now - DELAY)
	if not c then return end
	return { origin = c.pos, angles = c.fwd:AngleEx(c.up), fov = c.fov, drawviewer = true }
end)

-- No hands or weapon in the skate camera, as when riding.
hook.Add("PreDrawViewModel", "skate3_demo_hide", function()
	if Following() then return true end
end)
hook.Add("PreDrawPlayerHands", "skate3_demo_hide", function()
	if Following() then return true end
end)

-- skate3_demo_info: what a demo is giving the skater, for when a recording
-- doesn't show one.
concommand.Add("skate3_demo_info", function()
	print(("[skate3] demo: playing %s, recording %s; camera frames received %d"):format(
		tostring(Demo.Playing()), tostring(Demo.Recording()), count))
	if Demo.Playing() and count == 0 then
		print("[skate3] no skate frames in this demo: it was recorded with a version without demo support, or the skater wasn't riding")
	end
end)

return Demo
