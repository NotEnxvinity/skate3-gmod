local Skater = include("skate3/cl_skater.lua")

local MODULE = (jit.os == "Windows" and "gmcl_skate3_win64.dll" or "gmcl_skate3_linux64.dll")

local cv_path = CreateClientConVar("skate3_data_path", "", true, false, "Converted Skate 3 data folder (blank: garrysmod/data/skate3/assets)")
local cv_rails = CreateClientConVar("skate3_debug_rails", "0", false, false, "Draw the grind rails found in this map")
local cv_hud = CreateClientConVar("skate3_hud", "1", true, false, "Show the skate status line")
local cv_input = CreateClientConVar("skate3_debug_input", "0", false, false, "Show the controller input the skate module receives")

-- Equipping this weapon gets on the board; switching away gets off.
local BOARD_WEAPON = "weapon_skate3"

local loaded = false
local active = false
local boardHeld = false
local rideWhenReady = false
local lastRemount = -math.huge
local resumeAt -- where a glitched ride ended, for hopping back on
local pose
local rails
local status = {}
local nextStatus = 0
local nextSend = 0

local function Say(...)
	chat.AddText(Color(120, 200, 255), "[skate3] ", color_white, ...)
end

local function V(t)
	return Vector(t[1], t[2], t[3])
end

local function Load()
	if jit.arch ~= "x64" then
		Say("Skate 3 mode needs 64-bit Garry's Mod (the x86-64 beta branch).")
		return
	end
	if not file.Exists("lua/bin/" .. MODULE, "MOD") then
		Say("The skate module is missing: put " .. MODULE .. " in garrysmod/lua/bin.")
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
	local started, loadErr = skate3.LoadMap(bsp)
	if not started then
		Say(loadErr)
		return
	end
	loaded = true
	Skater.Load()
	print("[skate3] module " .. skate3.Version() .. ", data at " .. path .. "; building collision for " .. game.GetMap())
end
hook.Add("InitPostEntity", "skate3_load", Load)

local function SetActive(on)
	active = on
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
	Skater.HideModel()
end

local function Start()
	local at = resumeAt
	resumeAt = nil
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
		Say("No controller found. Skate 3 needs one to push and flick.")
	end
	local ply = LocalPlayer()
	if not ply:Alive() or ply:InVehicle() then return end
	local pos = at or ply:GetPos()
	local ok, err = skate3.Activate(pos.x, pos.y, pos.z, ply:EyeAngles().y, ScrW() / ScrH())
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

net.Receive("skate3_state", function()
	if not net.ReadBool() and active then
		skate3.Suspend()
		active = false
		pose = nil
		Skater.HideModel()
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
		if not held then Stop() end
	end
	-- Equipped before the map's collision finished: ride once it's ready.
	if rideWhenReady and not active and status.state ~= "loading" then
		rideWhenReady = false
		Start()
	end
end

hook.Add("Think", "skate3_step", function()
	FollowWeapon()
	if not loaded then return end
	local now = RealTime()
	if now >= nextStatus then
		nextStatus = now + 0.25
		status = skate3.Status()
		if status.state == "ready" and not rails then
			rails = skate3.GetRails()
			print(("[skate3] collision ready: %d triangles, %d grind rails"):format(status.triangles, status.rails))
		elseif active and (status.state == "failed" or status.error) then
			-- The full reason goes to the console; chat gets the gist.
			local why = tostring(status.error)
			print("[skate3] ride stopped: " .. why)
			local endedAt = pose and V(pose.pos)
			Stop()
			-- Still holding the board: hop back on where the ride ended, unless
			-- it keeps failing right away.
			if boardHeld and status.state ~= "failed" and now - lastRemount > 3 then
				lastRemount = now
				rideWhenReady = true
				resumeAt = endedAt
				Say("Skate glitched, hopping back on. (details in console)")
			else
				Say("Skate stopped: " .. why:sub(1, 120) .. (#why > 120 and "... (full error in console)" or ""))
			end
		end
	end
	if not active then return end
	skate3.Step(FrameTime(), ScrW() / ScrH())
	pose = skate3.GetPose() or pose
	Skater.UpdateModel(pose)
	if pose and now >= nextSend then
		nextSend = now + 0.05
		net.Start("skate3_move")
		net.WriteVector(V(pose.pos))
		net.SendToServer()
	end
end)

hook.Add("CreateMove", "skate3_block", function(cmd)
	if not active then return end
	cmd:ClearMovement()
	cmd:ClearButtons()
end)

hook.Add("CalcView", "skate3_view", function()
	if not active or not pose or not pose.camera then return end
	local c = pose.camera
	return {
		origin = V(c.pos),
		angles = V(c.forward):AngleEx(V(c.up)),
		fov = c.fov,
		drawviewer = false,
	}
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
	if not Skater.DrawBoard(pose) then
		local pos = V(pose.pos)
		render.DrawWireframeBox(pos, V(pose.forward):AngleEx(V(pose.up)), BOARD_MIN, BOARD_MAX, BOARD_COLOR, true)
	end
	if not Skater.HasModel() then
		local pos = V(pose.pos)
		render.DrawLine(pos, pos + V(pose.up) * 64, BODY_COLOR, true)
	end
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

hook.Add("HUDPaint", "skate3_hud", function()
	if not cv_hud:GetBool() or not loaded then return end
	local line
	if status.state == "loading" then
		line = "skate3: building collision..."
	elseif active and pose then
		line = ("skate3: %s  %.0f km/h  %s"):format(pose.state, pose.speed * 3.6, status.pad or "no controller")
	end
	if line then
		draw.SimpleTextOutlined(line, "DermaDefaultBold", ScrW() * 0.5, ScrH() - 48, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM, 1, color_black)
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
