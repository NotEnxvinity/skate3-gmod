local Skater = include("skate3/cl_skater.lua")
local Sounds = include("skate3/cl_sounds.lua")
local Score = include("skate3/cl_score.lua")
local Keyboard = include("skate3/cl_keyboard.lua")
include("skate3/cl_menu.lua")
local Props = include("skate3/cl_props.lua")
local Pose = include("skate3/sh_pose.lua")
include("skate3/cl_others.lua")(Skater)

local MODULE = (jit.os == "Windows" and "gmcl_skate3_win64.dll" or jit.os == "OSX" and "gmcl_skate3_osx64.dll" or "gmcl_skate3_linux64.dll")

local cv_path = CreateClientConVar("skate3_data_path", "", true, false, "Converted Skate 3 data folder (blank: garrysmod/data/skate3/assets)")
local cv_rails = CreateClientConVar("skate3_debug_rails", "0", false, false, "Draw the grind rails found in this map")
print("[skate3] lua build: v2.0.2 early test build (test-8)")
local cv_hud = CreateClientConVar("skate3_hud", "0", true, false, "Show the skate status line")
local cv_input = CreateClientConVar("skate3_debug_input", "0", false, false, "Show the controller input the skate module receives")
local cv_stance = CreateClientConVar("skate3_stance", "goofy", true, false, "Skating stance, regular or goofy; applies the next time you get on")

-- Equipping this weapon starts skate mode standing with the board in hand,
-- the way Skate 3 does off the board; Y gets on and off. Switching away ends it.
local BOARD_WEAPON = "weapon_skate3"
local PAD_Y = 0x8000
-- How long to keep tapping Y to step off after equipping, before giving up.
local STEP_OFF_FOR = 3

local loaded = false
local active = false
local boardHeld = false
local rideWhenReady = false
local lastRemount = -math.huge
local resumeAt -- where a glitched ride ended, for hopping back on
local stepOffUntil -- tapping Y until then, to start off the board
local resumeOnFoot = false -- the glitched ride ended on foot
local resumeYaw -- the heading to start at instead of the view's
local stepOffFrame = 0
local pose
local rails
local status = {}
local nextStatus = 0
local loadStage, loadStartedAt -- the collision build's current step, for the console
local nextSend = 0

local function Say(...)
	chat.AddText(Color(120, 200, 255), "[skate3] ", color_white, ...)
end

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

local function Load()
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
	local started, loadErr = skate3.LoadMap(bsp, ExtraTriangles(bsp))
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
local function WatchBail(now, p)
	if not p then return end
	recent[#recent + 1] = { t = now, pos = V(p.pos) }
	while #recent > 2 and now - recent[1].t > 0.4 do table.remove(recent, 1) end
	local bailing = p.state and p.state:find("^Wipeout") ~= nil
	if bailing and not wasBailing then
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
	recent, wasBailing = {}, false
	Skater.HideModel()
	Sounds.Stop()
	Score.Reset()
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
	Skater.ShowModel(ply)
end

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
		stepOffUntil = nil
		if not held then
			resumeAt = nil
			Stop()
		end
	end
	-- Equipped before the map's collision finished: start once it's ready.
	if rideWhenReady and not active and status.state ~= "loading" then
		rideWhenReady = false
		-- A fresh equip starts on foot, and so does recovering from a glitch
		-- that happened on foot.
		local onFoot = resumeAt == nil or resumeOnFoot
		resumeOnFoot = false
		Start()
		if active and onFoot then
			stepOffUntil = RealTime() + STEP_OFF_FOR
			stepOffFrame = 0
		end
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
	local process = skate3.Memory and skate3.Memory()
	local growth = ""
	if process and lastProcess then growth = (" (%+.1f MB/s)"):format((process - lastProcess) / HEALTH_EVERY) end
	lastProcess = process
	local skipping = cv_skip:GetString()
	print(("[skate3] health: game %s%s, lua %.1f MB, %d entities, worst frame %.3f s, %d hitches, %s%s"):format(
		process and ("%.0f MB"):format(process) or "?", growth, collectgarbage("count") / 1024, #ents.GetAll(),
		worstFrame, hitches, active and (pose and pose.state or "riding") or "not riding",
		skipping ~= "" and ", skipping " .. skipping or ""))
	worstFrame, hitches = 0, 0
end

-- Whether a climbing "lua" figure is a leak or garbage the collector hasn't
-- reached yet: a full collection frees garbage, and whatever stays is held.
concommand.Add("skate3_gc", function()
	local before = collectgarbage("count") / 1024
	collectgarbage("collect")
	local after = collectgarbage("count") / 1024
	print(("[skate3] lua %.1f MB before a full collection, %.1f MB after (%.1f MB was garbage)"):format(before, after, before - after))
end)

-- Session markers, as in Skate 3: D-pad down drops one where the skater is
-- (rolling on four wheels or standing), and holding D-pad up goes back to it,
-- the hold taking longer the further away it is. Returns true when it just
-- took the skater back, which restarts the ride.
local PAD_DPAD_UP, PAD_DPAD_DOWN = 0x0001, 0x0002
local marker -- { pos, yaw, onFoot }
local lastButtons = 0
local holdingSince
local function SessionMarker(now)
	local input = skate3.GetInput and skate3.GetInput()
	local buttons = bit.bor(input and input.buttons or 0, Keyboard.buttons)
	local pressed = bit.band(buttons, bit.bnot(lastButtons))
	lastButtons = buttons
	if bit.band(pressed, PAD_DPAD_DOWN) ~= 0 and pose and pose.camera then
		local state = pose.state or ""
		if state == "PhysicsGround" or state:find("^Biped") then
			marker = { pos = V(pose.pos), yaw = V(pose.camera.forward):Angle().y, onFoot = state:find("^Biped") ~= nil }
			Score.Marker("Marker set")
		else
			Score.Marker("Can't set a marker here")
		end
	end
	if not marker or bit.band(buttons, PAD_DPAD_UP) == 0 or not pose then
		if holdingSince then Score.MarkerHold(0) end
		holdingSince = nil
		return false
	end
	-- Skate 3's timing: a fifth of a second up to 100 m away, a second past
	-- a kilometre, and nothing within half a metre.
	local metres = V(pose.pos):Distance(marker.pos) * 0.0254
	if metres < 0.5 then return false end
	holdingSince = holdingSince or now
	local duration = math.Clamp(0.2 + (metres - 100) * 0.8 / 900, 0.2, 1)
	local progress = math.min((now - holdingSince) / duration, 1)
	Score.MarkerHold(progress)
	if progress < 1 then return false end
	holdingSince = nil
	Stop()
	resumeAt, resumeYaw = marker.pos, marker.yaw
	Start()
	if active and marker.onFoot then
		stepOffUntil = RealTime() + STEP_OFF_FOR
		stepOffFrame = 0
	end
	Score.Marker("Back at marker")
	return true
end

hook.Add("Think", "skate3_step", function()
	FollowWeapon()
	if not loaded then return end
	local now = RealTime()
	Health(now)
	if now >= nextStatus then
		nextStatus = now + 0.25
		status = skate3.Status()
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
		if status.state == "ready" and not rails then
			rails = skate3.GetRails()
			print(("[skate3] collision ready: %d triangles, %d grind rails"):format(status.triangles, status.rails))
		elseif active and (status.state == "failed" or status.error) then
			-- The full reason goes to the console; chat gets the gist.
			local why = tostring(status.error)
			print("[skate3] ride stopped: " .. why)
			-- Also kept in garrysmod/data/skate3/errors.txt, for reading outside the game.
			file.CreateDir("skate3")
			file.Append("skate3/errors.txt", os.date("%Y-%m-%d %H:%M:%S  ") .. why .. "\n\n")
			local endedAt = pose and V(pose.pos)
			local endedOnFoot = pose and pose.state and pose.state:find("^Biped") ~= nil
			Stop()
			-- Still holding the board: hop back on where the ride ended (on a
			-- fresh simulation, which takes a few seconds), unless it keeps failing.
			if boardHeld and status.state ~= "failed" and now - lastRemount > 10 then
				lastRemount = now
				rideWhenReady = true
				resumeAt = endedAt
				resumeOnFoot = endedOnFoot or false
				Say("Skate glitched, putting you back where you were. (details in console)")
			else
				Say("Skate stopped: " .. why:sub(1, 120) .. (#why > 120 and "... (full error in console)" or ""))
			end
		end
	end
	if not active then return end
	-- The simulation always spawns on the board, so tap Y for the player
	-- until the skater is on foot.
	local press = 0
	if stepOffUntil then
		local onFoot = pose and pose.state and pose.state:find("^Biped")
		if onFoot or now > stepOffUntil then
			stepOffUntil = nil
		else
			stepOffFrame = stepOffFrame + 1
			if stepOffFrame % 20 >= 10 and stepOffFrame % 20 < 14 then press = PAD_Y end
		end
	end
	local skip = Skater.Skip
	local keys, analog = Keyboard.Read(FrameTime())
	if not skip.step then skate3.Step(FrameTime(), ScrW() / ScrH(), bit.bor(press, keys), analog) end
	if SessionMarker(now) then return end
	if not skip.pose or not pose then pose = skate3.GetPose() or pose end
	Skater.UpdateModel(pose)
	if not skip.net then WatchBail(now, pose) end
	if skip.sounds then Sounds.Stop() else Sounds.Update(LocalPlayer(), pose) end
	if pose and now >= nextSend and not skip.net then
		nextSend = now + 0.05
		net.Start("skate3_move")
		net.WriteVector(V(pose.pos))
		net.SendToServer()
		-- Other players see your body posed from this.
		local frame = Skater.NetFrame()
		if frame then
			net.Start("skate3_pose", true)
			Pose.Write(frame)
			net.SendToServer()
		end
	end
end)

hook.Add("CreateMove", "skate3_block", function(cmd)
	if not active then return end
	cmd:ClearMovement()
	cmd:ClearButtons()
end)

-- Camera height presets, in units above (or below) the game's own camera.
local CAMERA_HEIGHTS = { low = -16, normal = 0, high = 32 }
local cv_camera = CreateClientConVar("skate3_camera", "low", true, false, "Skate camera height: low, normal or high")

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
	return {
		origin = origin,
		angles = forward:AngleEx(up),
		fov = c.fov,
		-- Your own body is the skater (unless it's posed as a copy).
		drawviewer = Skater.RealBody(),
	}
end)

-- With skate3_body copy, the copy stands in for the player while skating;
-- the player's own model would otherwise show up in mirrors and portals.
hook.Add("PrePlayerDraw", "skate3_hide", function(ply)
	if active and ply == LocalPlayer() and not Skater.RealBody() then return true end
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
	if active and pose and not Skater.Skip.score then Score.Draw(pose) end
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
