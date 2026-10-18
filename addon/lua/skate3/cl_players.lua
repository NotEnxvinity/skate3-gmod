-- Other players: skaters crash into each other, and on foot with the board in
-- hand you can punch (B, F on a keyboard) or swing the board (R1, Ctrl).
--
-- Every skater's simulation runs on their own computer, so nobody else's
-- skater is in it: two skaters ride straight through each other. Each game
-- therefore checks its own skater against the others (their poses arrive for
-- drawing anyway; walking players are plain game entities) and bails itself
-- when it runs into someone hard enough, which is what a crash means in
-- Skate 3. Both skaters see the other coming, so both go down. A walking
-- player can't be bailed, so the server shoves them (and hurts them, if the
-- server wants that).
--
-- Punches and board swings are the same idea the other way round: the game
-- of whoever swings finds who got hit and tells the server, which checks it
-- and tells the one who was hit (a skater's game bails them; a walking
-- player is shoved by the server). The swing itself is drawn by the arm
-- animation in cl_skater_anim.lua, so everyone watching sees it.
--
-- The bail is the same one both triggers plus both stick clicks asks the
-- simulation for (WipeOutRequest), pressed for the skater.
--
-- Server settings (sv_skate3.lua): skate3_player_collision,
-- skate3_player_collision_speed, skate3_player_hits, skate3_hit_damage.

local cv_melee = CreateClientConVar("skate3_melee", "1", true, false,
	"Punch (B, F on a keyboard) and swing the board (R1, Ctrl) at other players while on foot with the board")
local cv_debug = CreateClientConVar("skate3_debug_players", "0", false, false,
	"Show how close other players are and how fast you'd crash into them")

local UNITS = 39.37 -- map units per metre
local PAD_B, PAD_R1, PAD_L1 = 0x2000, 0x0200, 0x0100
local PAD_L3, PAD_R3 = 0x0040, 0x0080

-- Two skaters touch when their roots are this close sideways and not more
-- than CRASH_HEIGHT apart (a jump over someone clears them).
local CRASH_REACH = 34
local CRASH_HEIGHT = 60
-- After a crash no new one for this long, so one meeting is one bail.
local CRASH_GAP = 1.5
-- How long the bail is held down for the simulation to see it.
local BAIL_HOLD = 0.25

-- Reach and arc of each hit, in map units. cone: the cosine of the widest
-- angle off the way the skater faces that still gets hit. count: how many
-- people one hit can reach.
local HITS = {
	[0] = { name = "punch", reach = 52, cone = 0.5, count = 1, gap = 0.4 },
	[1] = { name = "board", reach = 84, cone = 0.17, count = 3, gap = 0.8 },
}
local HIT_HEIGHT = 64

local SWING = { "npc/zombie/claw_miss1.wav", "npc/zombie/claw_miss2.wav" }
local CRASH = { "physics/body/body_medium_impact_hard1.wav", "physics/body/body_medium_impact_hard2.wav",
	"physics/body/body_medium_impact_hard3.wav", "physics/body/body_medium_impact_hard4.wav" }

local function V(t) return Vector(t[1], t[2], t[3]) end

local function Server(name, default)
	local cv = GetConVar(name)
	return cv and cv:GetFloat() or default
end

return function(Skater, Others, Score)
	local Anim = Skater.Anim

	local strike -- { kind, at, hit } while a punch or swing is under way
	local nextStrike = 0
	local lastButtons = 0
	local bailUntil = 0
	local nextCrash = 0
	local hurt = { at = -math.huge } -- the last hit taken, for the flash
	local pending -- a hit from the server waiting for the next frame
	local debugLines = {}

	local Players = {}

	local function Say(text)
		if Score and Score.Marker then Score.Marker(text) end
	end

	local function Riding(state)
		return state and not state:find("^Biped") and not state:find("^Wipeout")
	end

	local function Biped(state)
		return state and state:find("^Biped") ~= nil
	end

	-- Whether to treat ply as somebody to run into or hit, and where they are
	-- and how they move: a rider from their poses, anyone else from the game.
	local function Other(ply)
		if ply == LocalPlayer() or not IsValid(ply) or not ply:Alive() or ply:GetObserverMode() ~= OBS_MODE_NONE then return nil end
		if ply:GetNW2Bool("skate3_riding") then
			local info = Others and Others.Info(ply)
			-- Someone who has already come off isn't run into again.
			if info and not (info.state or ""):find("^Wipeout") then return info.pos, info.vel, info.state, true end
			return nil
		end
		if ply:IsDormant() then return nil end
		return ply:GetPos(), ply:GetVelocity(), nil, false
	end

	function Players.Bail(why)
		local now = RealTime()
		if now < bailUntil then return end
		bailUntil = now + BAIL_HOLD
		if cv_debug:GetBool() then print("[skate3] bail asked for: " .. tostring(why)) end
	end

	-- Crashes: this skater's root against everyone else's.
	local function Crash(now, pose)
		if now < nextCrash or Server("skate3_player_collision", 1) == 0 then return end
		if not Riding(pose.state) then return end
		local me, vel = V(pose.pos), V(pose.velocity or { 0, 0, 0 })
		local need = Server("skate3_player_collision_speed", 4)
		local worst
		for _, ply in ipairs(player.GetAll()) do
			local pos, other, state, rider = Other(ply)
			if pos then
				local away = pos - me
				local up = away.z
				away.z = 0
				local near = away:Length()
				if near < CRASH_REACH and math.abs(up) < CRASH_HEIGHT then
					-- How fast the two close in on each other, along the line
					-- between them. Side by side at the same speed is nothing.
					local toward = near > 1 and away / near or (vel - other):GetNormalized()
					local rel = vel - other
					rel.z = 0
					local closing = rel:Dot(toward) / UNITS
					if cv_debug:GetBool() then debugLines[#debugLines + 1] = ("%s: %.0f u away, closing %.1f m/s (crash at %.1f)"):format(ply:Nick(), near, closing, need) end
					if closing >= need and (not worst or closing > worst.closing) then
						worst = { ply = ply, closing = closing, rider = rider, pos = pos }
					end
				end
			end
		end
		if not worst then return end
		nextCrash = now + CRASH_GAP
		Players.Bail("crashed into " .. worst.ply:Nick())
		sound.Play(CRASH[math.random(#CRASH)], me, 75, math.random(95, 105), 1)
		Say("Crashed into " .. worst.ply:Nick())
		-- A rider bails themselves; anyone else needs the server to shove them.
		if not worst.rider then
			net.Start("skate3_hit")
			net.WriteUInt(2, 2)
			net.WriteEntity(worst.ply)
			net.WriteFloat(math.min(worst.closing, 60))
			net.SendToServer()
		end
	end

	-- Who a punch or swing from here reaches.
	local function Targets(def, pose)
		local me = V(pose.pos)
		local facing = V(pose.forward or { 1, 0, 0 })
		facing.z = 0
		if facing:LengthSqr() < 1e-4 then return {} end
		facing:Normalize()
		local found = {}
		for _, ply in ipairs(player.GetAll()) do
			local pos = Other(ply)
			if pos then
				local away = pos - me
				local up = away.z
				away.z = 0
				local dist = away:Length()
				if dist <= def.reach and math.abs(up) < HIT_HEIGHT and (dist < 8 or away:Dot(facing) / dist >= def.cone) then
					found[#found + 1] = { ply = ply, dist = dist }
				end
			end
		end
		table.sort(found, function(a, b) return a.dist < b.dist end)
		while #found > def.count do table.remove(found) end
		return found
	end

	local function Land(kind, pose)
		for _, t in ipairs(Targets(HITS[kind], pose)) do
			net.Start("skate3_hit")
			net.WriteUInt(kind, 2)
			net.WriteEntity(t.ply)
			net.WriteFloat(0)
			net.SendToServer()
			Say("Hit " .. t.ply:Nick())
		end
	end

	local function Strikes(now, pose, buttons)
		local pressed = bit.band(buttons, bit.bnot(lastButtons))
		lastButtons = buttons
		if strike then
			local def = Anim.STRIKES[strike.kind]
			local t = now - strike.at
			if not strike.hit and t >= def.hit then
				strike.hit = true
				-- Whoever's in reach at the moment the fist or board lands.
				Land(strike.kind, pose)
			end
			if t >= def.total then strike = nil end
			return
		end
		if now < nextStrike or not cv_melee:GetBool() or Server("skate3_player_hits", 1) == 0 then return end
		-- Not with the context menu's button down, and only standing on the ground.
		if bit.band(buttons, PAD_L1) ~= 0 then return end
		local state = pose.state
		if not Biped(state) or state:find("Air") then return end
		local kind = bit.band(pressed, PAD_B) ~= 0 and 0 or bit.band(pressed, PAD_R1) ~= 0 and 1 or nil
		if not kind then return end
		strike = { kind = kind, at = now }
		nextStrike = now + HITS[kind].gap
		Anim.Strike(kind, now)
		LocalPlayer():EmitSound(SWING[math.random(#SWING)], 60, kind == 1 and 80 or 110)
	end

	-- A hit from the server: skaters on a board come off it.
	net.Receive("skate3_hit", function()
		local from, kind = net.ReadEntity(), net.ReadUInt(2)
		pending = { from = from, kind = kind, at = RealTime() }
	end)

	local function Hurt(now, pose)
		if not pending then return end
		local hit = pending
		pending = nil
		if now - hit.at > 0.5 then return end
		hurt = { at = now, kind = hit.kind }
		Say("Hit by " .. (IsValid(hit.from) and hit.from:Nick() or "someone"))
		if Riding(pose.state) then Players.Bail("hit by " .. (IsValid(hit.from) and hit.from:Nick() or "someone")) end
	end

	-- Called every frame while skating, before the simulation steps. `buttons`
	-- is everything held (pad and keyboard). Returns the buttons and the
	-- { lx, ly, rx, ry, lt, rt } to press on top of the player's own.
	function Players.Think(now, pose, buttons)
		if cv_debug:GetBool() then debugLines = {} end
		if pose and pose.state then
			Hurt(now, pose)
			Crash(now, pose)
			Strikes(now, pose, buttons)
		end
		if now < bailUntil then
			return bit.bor(PAD_L3, PAD_R3), { 0, 0, 0, 0, 1, 1 }
		end
		return 0, nil
	end

	function Players.Reset()
		strike, pending, bailUntil, lastButtons = nil, nil, 0, 0
	end

	-- Red edges for a moment after being hit.
	hook.Add("HUDPaint", "skate3_players_hurt", function()
		local t = RealTime() - hurt.at
		if t > 0.5 then return end
		local a = (1 - t / 0.5) * 90
		surface.SetDrawColor(200, 0, 0, a)
		local w, h = ScrW(), ScrH()
		local edge = math.floor(math.min(w, h) * 0.12)
		surface.DrawRect(0, 0, w, edge)
		surface.DrawRect(0, h - edge, w, edge)
		surface.DrawRect(0, edge, edge, h - 2 * edge)
		surface.DrawRect(w - edge, edge, edge, h - 2 * edge)
	end)

	hook.Add("HUDPaint", "skate3_players_debug", function()
		if not cv_debug:GetBool() then return end
		local y = 200
		draw.SimpleTextOutlined("[skate3] players", "DermaDefaultBold", 16, y, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 1, color_black)
		y = y + 16
		for _, line in ipairs(debugLines) do
			draw.SimpleTextOutlined(line, "DermaDefaultBold", 16, y, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 1, color_black)
			y = y + 16
		end
		draw.SimpleTextOutlined(("collision %s, hits %s, melee %s, strike %s"):format(
			Server("skate3_player_collision", 1) ~= 0 and "on" or "off", Server("skate3_player_hits", 1) ~= 0 and "on" or "off",
			cv_melee:GetBool() and "on" or "off", strike and HITS[strike.kind].name or "none"),
			"DermaDefaultBold", 16, y, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 1, color_black)
	end)

	return Players
end
