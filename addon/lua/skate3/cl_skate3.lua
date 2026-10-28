-- The on-screen UI first: the score, the menu and the marker all use it.
include("skate3/cl_ui.lua")
include("skate3/cl_glyphs.lua")
local Marker = include("skate3/cl_marker.lua")
local Skater = include("skate3/cl_skater.lua")
local Sounds = include("skate3/cl_sounds.lua")
local Score = include("skate3/cl_score.lua")
local Menu = include("skate3/cl_contextmenu.lua")
-- Hall of Meat's X-ray skeleton is posed like the body the skater shows.
Score.Meat.Body = Skater.BodyEntity
Score.Meat.Skipped = function() return Skater.Skip.hom end
local Keyboard = include("skate3/cl_keyboard.lua")
include("skate3/cl_menu.lua")
include("skate3/cl_park.lua")
local Props = include("skate3/cl_props.lua")
local Perf = include("skate3/cl_perf.lua")
local LiveProps = include("skate3/cl_live_props.lua")(Props, Perf)
local Pose = include("skate3/sh_pose.lua")
local Others = include("skate3/cl_others.lua")(Skater, Perf)
local Players = include("skate3/cl_players.lua")(Skater, Others, Score)
include("skate3/cl_collision_report.lua")
local Surfaces = include("skate3/cl_surfaces.lua")
local Demo = include("skate3/cl_demo.lua")

local MODULE = (jit.os == "Windows" and "gmcl_skate3_win64.dll" or jit.os == "OSX" and "gmcl_skate3_osx64.dll" or "gmcl_skate3_linux64.dll")

local cv_path = CreateClientConVar("skate3_data_path", "", true, false, "Converted Skate 3 data folder (blank: garrysmod/data/skate3/assets)")
local cv_rails = CreateClientConVar("skate3_debug_rails", "0", false, false, "Draw the grind rails found in this map")
print("[skate3] lua build: v2.3.1-test-1")
local cv_hud = CreateClientConVar("skate3_hud", "0", true, false, "Show the skate status line")
local cv_input = CreateClientConVar("skate3_debug_input", "0", false, false, "Show the controller input the skate module receives")
local cv_stance = CreateClientConVar("skate3_stance", "goofy", true, false, "Skating stance, regular or goofy; applies the next time you get on")

-- Equipping this weapon starts skate mode on the board; Y gets off and on
-- again. Switching away ends it.
local BOARD_WEAPON = "weapon_skate3"

local loaded = false
local active = false
local boardHeld = false
local rideWhenReady = false
local lastRemount = -math.huge
local resumeAt -- where a glitched ride ended, or the marker, for hopping back on
local resumeYaw -- the heading to start at instead of the view's
local pose
local rails
local railsRevision -- the collision swap the rails above came from
local status = {}
local nextStatus = 0
local loadStage, loadStartedAt -- the collision build's current step, for the console
local nextSend = 0
-- Your pose goes out 20 times a second while another player can see you,
-- and only now and then while nobody can (the server says which).
local watched = true
local SEND_EVERY, SEND_UNWATCHED = 0.05, 0.5
local nextPoseSend = 0
-- The simulation's last tick and when it moved on, to tell a frozen skater
-- (the skate thread falling behind) from a slow frame.
local lastTick, tickAt = nil, 0
local stalls, longestStall = 0, 0
local playersFailed -- cl_players.lua threw: said once, then carried on

local function Say(...)
	chat.AddText(Color(120, 200, 255), "[skate3] ", color_white, ...)
end

-- Doors and buttons while skating (S3GM_Interact.Use / .Target).
include("skate3/cl_interact.lua")(function() return active and pose end, function()
	return Skater.Facing and Skater.Facing() or nil
end)

local function V(t)
	return Vector(t[1], t[2], t[3])
end

-- Triangles the .bsp's brushes don't cover: the map's props.
local function ExtraTriangles(bsp)
	local out = {}
	for _, list in ipairs({ Props.Triangles(bsp) }) do
		local n = #out
		for i = 1, #list do out[n + i] = list[i] end
	end
	return out
end

-- The map's brush entities as the game has them now, as the flat
-- {model, solid, x, y, z, pitch, yaw, roll, ...} list skate3.LoadMap takes:
-- the .bsp alone can't tell which ones the map switched off at the start or
-- where a door sits.
local function LiveBrushes()
	local out = {}
	for _, ent in ipairs(ents.GetAll()) do
		local n = tonumber((ent:GetModel() or ""):match("^%*(%d+)$"))
		if n then
			local pos, ang = ent:GetPos(), ent:GetAngles()
			for _, v in ipairs({ n, ent:IsSolid() and 1 or 0, pos.x, pos.y, pos.z, ang.p, ang.y, ang.r }) do
				out[#out + 1] = v
			end
		end
	end
	return out
end

-- Playing a demo: no ride and no map collision, only the board's look, so
-- your recorded skater is drawn with the real board (cl_demo.lua).
local demoBoardTried = false
local function LoadBoardForDemo()
	demoBoardTried = true
	if jit.arch ~= "x64" or not file.Exists("lua/bin/" .. MODULE, "MOD") then return end
	local ok = pcall(require, "skate3")
	if not ok or not skate3 then return end
	if not skate3.Init(cv_path:GetString()) then return end
	Skater.Load()
end

local function Load()
	-- A demo is a recording; there is nothing to ride in it.
	if Demo.Playing() then return end
	if jit.arch ~= "x64" then
		Say("Skate 3 mode needs 64-bit Garry's Mod (the x86-64 beta branch).")
		return
	end
	if not file.Exists("lua/bin/" .. MODULE, "MOD") then
		Say("S3GM needs its setup, run once with your own Skate 3 disc. The S3GM Workshop page links the download.")
		return
	end
	local ok, err = pcall(require, "skate3")
	if not ok or not skate3 then
		Say("Couldn't load the skate module: " .. tostring(err))
		return
	end
	local path, initErr = skate3.Init(cv_path:GetString())
	if not path then
		Say(initErr)
		return
	end
	local f = file.Open("maps/" .. game.GetMap() .. ".bsp", "rb", "GAME")
	local bsp = f and f:Read(f:Size())
	if f then f:Close() end
	if not bsp then
		Say("Couldn't read this map's .bsp.")
		return
	end
	-- The player's surface flags for this map go first, so the collision is
	-- built with them.
	Surfaces.Push()
	local started, loadErr = skate3.LoadMap(bsp, ExtraTriangles(bsp), LiveBrushes())
	if not started then
		Say(loadErr)
		return
	end
	loaded = true
	Skater.Load()
	print("[skate3] module " .. skate3.Version() .. ", data at " .. path .. "; building collision for " .. game.GetMap())
end
hook.Add("InitPostEntity", "skate3_load", Load)

-- Bails: the server can make them hurt (skate3_bail_damage, a server
-- setting, off unless it's turned on), so it's told how fast you were
-- going into each one. Measured from where the skater was over the last
-- moments rather than the speedometer, so drops count too.
local recent, wasBailing = {}, false
local UNITS = 39.37 -- map units per metre
local lastState = ""
local function WatchBail(now, p)
	if not p then return end
	recent[#recent + 1] = { t = now, pos = V(p.pos) }
	while #recent > 2 and now - recent[1].t > 0.4 do table.remove(recent, 1) end
	local bailing = p.state and p.state:find("^Wipeout") ~= nil
	if bailing and not wasBailing then
		-- Why, for the console (and console.log with -condebug): what the
		-- engine asked the wipeout for, where, and how fast.
		if p.bail and p.bail ~= "" then
			local at = V(p.pos)
			print(("[skate3] bail: %s | at %.0f %.0f %.0f, %.1f m/s"):format(p.bail, at.x, at.y, at.z, p.speed or 0))
		end
		-- Fastest over any stretch of at least 0.05 s, so one odd frame
		-- doesn't count.
		local fastest = 0
		for a = 1, #recent do
			for b = a + 1, #recent do
				local dt = recent[b].t - recent[a].t
				if dt >= 0.05 then
					fastest = math.max(fastest, recent[a].pos:Distance(recent[b].pos) / dt)
					break
				end
			end
		end
		net.Start("skate3_bail")
		net.WriteFloat(fastest / UNITS)
		net.SendToServer()
	end
	wasBailing = bailing
	-- Off the board by any road (a knock off that never counts as a bail).
	local state = p.state or ""
	if lastState:find("^Physics") and not state:find("^Physics") and not state:find("^Grind") then
		local at = V(p.pos)
		print(("[skate3] off the board: %s -> %s%s | at %.0f %.0f %.0f, %.1f m/s"):format(
			lastState, state, (p.bail and p.bail ~= "") and (" (last bail reason: " .. p.bail .. ")") or "", at.x, at.y, at.z, p.speed or 0))
	end
	lastState = state
end

local function SetActive(on)
	active = on
	Keyboard.active = on
	net.Start("skate3_state")
	net.WriteBool(on)
	net.SendToServer()
end

local function Stop()
	if not active then return end
	skate3.Suspend()
	if pose then
		net.Start("skate3_move")
		net.WriteVector(V(pose.pos))
		net.SendToServer()
	end
	SetActive(false)
	pose = nil
	lastTick = nil
	recent, wasBailing = {}, false
	Skater.HideModel()
	Sounds.Stop()
	Score.Reset()
	Players.Reset()
	Menu.Reset()
end

local function Start()
	local at, yaw = resumeAt, resumeYaw
	resumeAt, resumeYaw = nil, nil
	if not loaded then
		Say("Skate 3 mode isn't available; check the console for why.")
		return
	end
	local st = skate3.Status()
	if st.state == "loading" then
		Say("Still building this map's skate collision, give it a sec.")
		return
	elseif st.state ~= "ready" then
		Say("Skate collision failed: " .. tostring(st.error))
		return
	end
	if not st.pad then
		if Keyboard.Enabled() then
			Say("No controller found, so it's keyboard and mouse (early days!): WASD, Space pushes, E gets on and off, flick the mouse for tricks. A controller is still the best way to skate.")
		else
			Say("No controller found. Skate 3 needs one to push and flick.")
		end
	end
	local ply = LocalPlayer()
	if not ply:Alive() or ply:InVehicle() then return end
	local pos = at or ply:GetPos()
	local ok, err = skate3.Activate(pos.x, pos.y, pos.z, yaw or ply:EyeAngles().y, ScrW() / ScrH(),
		cv_stance:GetString() == "regular" and 0 or 1)
	if not ok then
		Say(err)
		return
	end
	SetActive(true)
	lastTick = nil
	-- A fresh ride: no Hall of Meat panel or skeleton from the last bail, and
	-- no half-finished score.
	Score.Reset()
	Skater.ShowModel(ply)
end

include("skate3/cl_perf_test.lua")(Skater, {
	active = function() return active end,
	where = function()
		if not pose then return nil end
		return V(pose.pos), pose.camera and V(pose.camera.forward):Angle().y or nil
	end,
	stop = function() Stop() end,
	restart = function(at, yaw)
		resumeAt, resumeYaw = at, yaw
		Start()
	end,
})

concommand.Add("skate3_toggle", function()
	if active then Stop() else Start() end
end, nil, "Get on or off the board")

concommand.Add("skate3_board_info", function()
	Skater.BoardInfo(active and pose or nil)
end, nil, "Print what the board is made of and where it is drawn")

net.Receive("skate3_state", function()
	if not net.ReadBool() and active then
		skate3.Suspend()
		active = false
		Keyboard.active = false
		pose = nil
		Skater.HideModel()
		Sounds.Stop()
		Players.Reset()
		Menu.Reset()
	end
end)

-- Rides while the board weapon is out.
local function FollowWeapon()
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local wep = ply:GetActiveWeapon()
	local held = IsValid(wep) and wep:GetClass() == BOARD_WEAPON
	if held ~= boardHeld then
		boardHeld = held
		rideWhenReady = held
		if not held then
			resumeAt = nil
			Stop()
		end
	end
	-- Equipped before the map's collision finished: start once it's ready.
	if rideWhenReady and not active and status.state ~= "loading" then
		rideWhenReady = false
		Start()
	end
end

-- A health line in the console every few seconds while the mod is loaded,
-- so a log of a crash shows what was growing in the hitches before it.
local HEALTH_EVERY = 5
local nextHealth = 0
local worstFrame, hitches = 0, 0
local lastProcess
local cv_skip = GetConVar("skate3_debug_skip")

local function Health(now)
	local dt = FrameTime()
	worstFrame = math.max(worstFrame, dt)
	if dt > 0.1 then hitches = hitches + 1 end
	if now < nextHealth then return end
	nextHealth = now + HEALTH_EVERY
	local sent, got = Perf.TakeNet()
	local process = skate3.Memory and skate3.Memory()
	local growth = ""
	if process and lastProcess then growth = (" (%+.1f MB/s)"):format((process - lastProcess) / HEALTH_EVERY) end
	lastProcess = process
	local skipping = cv_skip:GetString()
	print(("[skate3] health: game %s%s, lua %.1f MB, %d entities, worst frame %.3f s, %d hitches, skate sim stalls %d (longest %.2f s), skate net out %.1f KB/s in %.1f KB/s%s, %s%s"):format(
		process and ("%.0f MB"):format(process) or "?", growth, collectgarbage("count") / 1024, #ents.GetAll(),
		worstFrame, hitches, stalls, longestStall, sent / 1024 / HEALTH_EVERY, got / 1024 / HEALTH_EVERY,
		watched and "" or " (nobody watching)", active and (pose and pose.state or "riding") or "not riding",
		skipping ~= "" and ", skipping " .. skipping or ""))
	worstFrame, hitches, stalls, longestStall = 0, 0, 0, 0
end

-- Whether a climbing "lua" figure is a leak or garbage the collector hasn't
-- reached yet: a full collection frees garbage, and whatever stays is held.
concommand.Add("skate3_gc", function()
	local before = collectgarbage("count") / 1024
	collectgarbage("collect")
	local after = collectgarbage("count") / 1024
	print(("[skate3] lua %.1f MB before a full collection, %.1f MB after (%.1f MB was garbage)"):format(before, after, before - after))
end)

-- Session markers live in cl_marker.lua and the menu that drives them in
-- cl_contextmenu.lua. This is how they read the skater and take them back to
-- a marker (a fresh ride there, on the board).
Marker.Bind({
	pose = function() return pose end,
	teleport = function(at, yaw)
		Stop()
		resumeAt, resumeYaw = at, yaw
		Start()
	end,
})

net.Receive("skate3_watched", function()
	watched = net.ReadBool()
end)

-- Camera height presets, in units above (or below) the game's own camera.
local CAMERA_HEIGHTS = { low = -16, normal = 0, high = 32 }
local cv_camera = CreateClientConVar("skate3_camera", "low", true, false, "Skate camera height: low, normal or high")

-- Where the skate camera is: origin, forward, up and field of view.
local function ViewOf(pose)
	local c = pose.camera
	local origin, forward, up = V(c.pos), V(c.forward), V(c.up)
	local lift = CAMERA_HEIGHTS[cv_camera:GetString()] or 0
	if lift ~= 0 then
		-- Move the camera up or down and keep it aimed at the same spot by
		-- the skater, so the framing stays centred.
		local target = origin + forward * math.max(origin:Distance(V(pose.pos)), 32)
		-- Stop short of ceilings and floors.
		local tr = util.TraceLine({ start = origin, endpos = origin + Vector(0, 0, lift), mask = MASK_SOLID_BRUSHONLY })
		origin = tr.Hit and tr.HitPos + tr.HitNormal * 4 or tr.HitPos
		forward = (target - origin):GetNormalized()
		up = forward:Cross(up):Cross(forward)
		up:Normalize()
	end
	return origin, forward, up, c.fov
end

hook.Add("Think", "skate3_step", function()
	Perf.Frame()
	-- Playing a demo: the skater is drawn from what the recording holds
	-- (cl_others.lua, cl_demo.lua), never ridden live.
	if Demo.Playing() then
		if not demoBoardTried and IsValid(LocalPlayer()) then LoadBoardForDemo() end
		return
	end
	FollowWeapon()
	if not loaded then return end
	Demo.Watch(RealTime())
	local now = RealTime()
	Health(now)
	if now >= nextStatus then
		nextStatus = now + 0.25
		status = Perf.Time("status", skate3.Status)
		S3GM_UI.SetPad(status.pad)
		if status.stage ~= loadStage then
			-- Each step goes to the console as it starts, so if the game dies
			-- mid-load the log shows which one it was.
			loadStage = status.stage
			loadStartedAt = loadStartedAt or now
			local process = skate3.Memory and skate3.Memory()
			print(("[skate3] collision: %s (%.1f s in, game %s)"):format(loadStage or status.state, now - loadStartedAt,
				process and ("%.0f MB"):format(process) or "?"))
			if not loadStage then loadStartedAt = nil end
		end
		if status.state == "ready" and railsRevision == nil then
			print(("[skate3] collision ready: %d triangles, %d grind rails"):format(status.triangles, status.rails))
			railsRevision = false
		end
		if status.state == "ready" and cv_rails:GetBool() and status.revision ~= railsRevision then
			-- Again after each prop swap. Only while skate3_debug_rails is on:
			-- a big map has thousands of rails, and fetching them all after
			-- every prop swap stalled the game.
			rails, railsRevision = Perf.Time("rails fetch", skate3.GetRails), status.revision
			Perf.Note(("rails fetched: %d"):format(rails and #rails or 0))
		elseif active and (status.state == "failed" or status.error) then
			-- The full reason goes to the console; chat gets the gist.
			local why = tostring(status.error)
			print("[skate3] ride stopped: " .. why)
			-- Also kept in garrysmod/data/skate3/errors.txt, for reading outside the game.
			file.CreateDir("skate3")
			file.Append("skate3/errors.txt", os.date("%Y-%m-%d %H:%M:%S  ") .. why .. "\n\n")
			local endedAt = pose and V(pose.pos)
			Stop()
			-- Still holding the board: hop back on where the ride ended (on a
			-- fresh simulation, which takes a few seconds), unless it keeps failing.
			if boardHeld and status.state ~= "failed" and now - lastRemount > 10 then
				lastRemount = now
				rideWhenReady = true
				resumeAt = endedAt
				Say("Skate glitched, putting you back where you were. (details in console)")
			else
				Say("Skate stopped: " .. why:sub(1, 120) .. (#why > 120 and "... (full error in console)" or ""))
			end
		end
	end
	if status.state == "ready" and not Skater.Skip.props then Perf.Time("prop scan", LiveProps.Think, now, active and pose and pose.state) end
	if not active then return end
	local skip = Skater.Skip
	local keys, analog = Keyboard.Read(FrameTime())
	-- Crashes, punches and board swings (and the bails they ask for), which
	-- press buttons for the skater too.
	local held = skate3.GetInput and skate3.GetInput()
	local ok, more, moreAnalog = pcall(Players.Think, now, pose, bit.bor(held and held.buttons or 0, keys))
	if not ok then
		-- Never at the cost of the ride itself.
		if not playersFailed then print("[skate3] other players: " .. tostring(more)) end
		playersFailed, more, moreAnalog = true, 0, nil
	end
	if more ~= 0 then keys = bit.bor(keys, more) end
	if moreAnalog then
		analog = analog or { 0, 0, 0, 0, 0, 0 }
		for i = 1, 6 do analog[i] = math.max(analog[i] or 0, moreAnalog[i]) end
	end
	if not skip.step then Perf.Time("step", skate3.Step, FrameTime(), ScrW() / ScrH(), keys, analog) end
	-- The contextual menu reads the same buttons the simulation does (it never
	-- takes L1 from it, so mach 1 works as ever). It says when it took the
	-- skater to their marker, which restarts the ride.
	local input = skate3.GetInput and skate3.GetInput()
	if Menu.Update(now, pose, bit.bor(input and input.buttons or 0, Keyboard.buttons)) then return end
	if not skip.pose or not pose then pose = Perf.Time("get pose", skate3.GetPose) or pose end
	if pose and pose.tick ~= lastTick then
		local frozen = now - tickAt
		-- A slow frame holds the simulation up too; this is only the time it
		-- stood still beyond that.
		if lastTick and frozen > 0.15 and frozen > FrameTime() * 1.5 + 0.05 then
			stalls = stalls + 1
			longestStall = math.max(longestStall, frozen)
			Perf.Note(("skate sim was frozen %.2f s"):format(frozen))
		end
		lastTick, tickAt = pose.tick, now
	end
	Perf.Time("body", Skater.UpdateModel, pose)
	if not skip.net then WatchBail(now, pose) end
	if skip.sounds then Sounds.Stop() else Perf.Time("sounds", Sounds.Update, LocalPlayer(), pose, Skater.BoardPos(pose)) end
	if pose and now >= nextSend and not skip.net then
		Perf.Begin("net send")
		nextSend = now + 0.05
		net.Start("skate3_move")
		net.WriteVector(V(pose.pos))
		Perf.Sent(net.BytesWritten() or 0)
		net.SendToServer()
		-- Other players see your body posed from this.
		local frame = now >= nextPoseSend and Skater.NetFrame()
		if frame then
			nextPoseSend = now + (watched and SEND_EVERY or SEND_UNWATCHED)
			net.Start("skate3_pose", true)
			Pose.Write(frame)
			Perf.Sent(net.BytesWritten() or 0)
			net.SendToServer()
		end
		-- While a demo records, the camera goes the same way (the server sends
		-- it back into the demo).
		if Demo.Recording() and pose.camera then
			local origin, forward, up, fov = ViewOf(pose)
			Demo.SendCamera(origin, forward, up, fov)
		end
		Perf.End("net send")
	end
end)

hook.Add("CreateMove", "skate3_block", function(cmd)
	if not active then return end
	cmd:ClearMovement()
	cmd:ClearButtons()
end)

concommand.Add("skate3_camera_cycle", function()
	local order = { low = "normal", normal = "high", high = "low" }
	local next = order[cv_camera:GetString()] or "normal"
	RunConsoleCommand("skate3_camera", next)
	Say("Camera: " .. next)
end, nil, "Switch the skate camera between low, normal and high")

hook.Add("CalcView", "skate3_view", function()
	if not active or not pose or not pose.camera or Skater.Skip.view then return end
	-- Looking through something else, such as the camera tool's camera, so
	-- leave the view to it.
	if GetViewEntity() ~= LocalPlayer() then return end
	local origin, forward, up, fov = ViewOf(pose)
	return {
		origin = origin,
		angles = forward:AngleEx(up),
		fov = fov,
		-- Your own body is the skater (unless it's posed as a copy).
		drawviewer = Skater.RealBody(),
	}
end)

-- With skate3_body copy, the copy stands in for the player while skating;
-- the player's own model would otherwise show up in mirrors and portals.
hook.Add("PrePlayerDraw", "skate3_hide", function(ply)
	if active and ply == LocalPlayer() and (not Skater.RealBody() or Skater.Skip.model) then return true end
end)

-- The skate camera replaces the first-person view, so no hands or weapon.
hook.Add("PreDrawViewModel", "skate3_hide", function()
	if active then return true end
end)
hook.Add("PreDrawPlayerHands", "skate3_hide", function()
	if active then return true end
end)

-- Without the converted board (or before it loads), a stand-in: a wireframe
-- board and a line where the skater stands.
local BOARD_MIN, BOARD_MAX = Vector(-16, -4, 0), Vector(16, 4, 2)
local BOARD_COLOR, BODY_COLOR, RAIL_COLOR = Color(255, 200, 60), Color(120, 200, 255), Color(255, 60, 200)

hook.Add("PostDrawOpaqueRenderables", "skate3_board", function(_, skybox)
	if skybox or not active or not pose then return end
	-- The skater's model draws the board itself; this covers riding without one.
	if Skater.HasModel() and Skater.HasBoard() then return end
	if not Skater.DrawBoard(pose) then
		local pos = V(pose.pos)
		render.DrawWireframeBox(pos, V(pose.forward):AngleEx(V(pose.up)), BOARD_MIN, BOARD_MAX, BOARD_COLOR, true)
	end
	if not Skater.HasModel() then
		local pos = V(pose.pos)
		render.DrawLine(pos, pos + V(pose.up) * 64, BODY_COLOR, true)
	end
end)

hook.Add("PostDrawTranslucentRenderables", "skate3_score", function(_, skybox)
	if skybox or not active or not pose or Skater.Skip.score then return end
	Score.DrawWorld(V(pose.pos))
end)

hook.Add("PostDrawTranslucentRenderables", "skate3_rails", function(_, skybox)
	if skybox or not cv_rails:GetBool() or not rails then return end
	local eye = EyePos()
	for _, rail in ipairs(rails) do
		for i = 1, #rail - 1 do
			local a, b = V(rail[i]), V(rail[i + 1])
			if a:DistToSqr(eye) < 4e6 then
				render.DrawLine(a, b, RAIL_COLOR, false)
			end
		end
	end
end)

-- The score in its own hook, with nothing to do with the status line: it
-- has its own switch (skate3_score_hud), and the status line's
-- (skate3_hud) must never hide it.
hook.Add("HUDPaint", "skate3_score", function()
	if active and pose and not Skater.Skip.score then
		Score.Draw(pose)
		Menu.Draw(pose)
	end
end)

hook.Add("HUDPaint", "skate3_hud", function()
	if not loaded then return end
	local line
	if not cv_hud:GetBool() then
	elseif status.state == "loading" then
		line = "skate3: building collision (" .. (status.stage or "starting") .. ")..."
	elseif active and pose then
		local onFoot = pose.state and pose.state:find("^Biped")
		line = ("skate3: %s  %.0f km/h  %s   (Y: %s)"):format(pose.state, pose.speed * 3.6, status.pad or (Keyboard.Enabled() and "keyboard" or "no controller"),
			onFoot and "get on the board" or "step off")
	end
	if line then
		-- Under Half-Life 2's HUD row, which the HL2 score look sits in.
		draw.SimpleTextOutlined(line, "DermaDefaultBold", ScrW() * 0.5, ScrH() - 2, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM, 1, color_black)
	end
	if cv_input:GetBool() and skate3 then
		local i, err = skate3.GetInput()
		local text = i and ("pad: %s  buttons %04X  LT %d RT %d  L %d,%d  R %d,%d"):format(
			i.pad or "none", i.buttons, i.lt, i.rt, i.lx, i.ly, i.rx, i.ry) or ("pad: " .. tostring(err))
		draw.SimpleTextOutlined(text, "DermaDefaultBold", ScrW() * 0.5, ScrH() - 30, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM, 1, color_black)
	end
end)

hook.Add("ShutDown", "skate3_shutdown", function()
	if active then skate3.Suspend() end
end)
