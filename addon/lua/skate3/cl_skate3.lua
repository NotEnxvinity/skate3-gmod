local MODULE = (jit.os == "Windows" and "gmcl_skate3_win64.dll" or "gmcl_skate3_linux64.dll")

local cv_path = CreateClientConVar("skate3_data_path", "", true, false, "Converted Skate 3 data folder (blank: garrysmod/data/skate3/assets)")
local cv_rails = CreateClientConVar("skate3_debug_rails", "0", false, false, "Draw the grind rails found in this map")
local cv_hud = CreateClientConVar("skate3_hud", "1", true, false, "Show the skate status line")

local loaded = false
local active = false
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
end

local function Start()
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
	local pos = ply:GetPos()
	local ok, err = skate3.Activate(pos.x, pos.y, pos.z, ply:EyeAngles().y, ScrW() / ScrH())
	if not ok then
		Say(err)
		return
	end
	SetActive(true)
end

concommand.Add("skate3_toggle", function()
	if active then Stop() else Start() end
end, nil, "Get on or off the board")

net.Receive("skate3_state", function()
	if not net.ReadBool() and active then
		skate3.Suspend()
		active = false
		pose = nil
	end
end)

hook.Add("Think", "skate3_step", function()
	if not loaded then return end
	local now = RealTime()
	if now >= nextStatus then
		nextStatus = now + 0.25
		status = skate3.Status()
		if status.state == "ready" and not rails then
			rails = skate3.GetRails()
			print(("[skate3] collision ready: %d triangles, %d grind rails"):format(status.triangles, status.rails))
		elseif status.state == "failed" and active then
			Say("Skate stopped: " .. tostring(status.error))
			Stop()
		end
	end
	if not active then return end
	skate3.Step(FrameTime(), ScrW() / ScrH())
	pose = skate3.GetPose() or pose
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

-- Until the skater is retargeted onto the playermodel, draw a stand-in: the
-- board and a line where the skater stands.
local BOARD_MIN, BOARD_MAX = Vector(-16, -4, 0), Vector(16, 4, 2)
local BOARD_COLOR, BODY_COLOR, RAIL_COLOR = Color(255, 200, 60), Color(120, 200, 255), Color(255, 60, 200)

hook.Add("PostDrawTranslucentRenderables", "skate3_draw", function(_, skybox)
	if skybox then return end
	if active and pose then
		local pos = V(pose.pos)
		local ang = V(pose.forward):AngleEx(V(pose.up))
		render.DrawWireframeBox(pos, ang, BOARD_MIN, BOARD_MAX, BOARD_COLOR, true)
		render.DrawLine(pos, pos + V(pose.up) * 64, BODY_COLOR, true)
	end
	if cv_rails:GetBool() and rails then
		local eye = EyePos()
		for _, rail in ipairs(rails) do
			for i = 1, #rail - 1 do
				local a, b = V(rail[i]), V(rail[i + 1])
				if a:DistToSqr(eye) < 4e6 then
					render.DrawLine(a, b, RAIL_COLOR, false)
				end
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
	if not line then return end
	draw.SimpleTextOutlined(line, "DermaDefaultBold", ScrW() * 0.5, ScrH() - 48, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM, 1, color_black)
end)

hook.Add("ShutDown", "skate3_shutdown", function()
	if active then skate3.Suspend() end
end)
