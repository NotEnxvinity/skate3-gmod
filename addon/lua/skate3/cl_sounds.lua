-- Skate sounds, driven by the skater's state each frame: rolling and grinding
-- loops that follow speed, and one-shots for pops, landings and bails.
--
-- These are Half-Life 2 sounds every Garry's Mod install already has, standing
-- in until real skate sounds replace them; swap paths in SOUNDS to change one.

local Sounds = {}

local SOUNDS = {
	roll = "physics/concrete/concrete_scrape_smooth_loop1.wav",
	grind = "physics/metal/metal_grenade_scrape_rough_loop1.wav",
	pop = { "physics/wood/wood_plank_impact_hard1.wav", "physics/wood/wood_plank_impact_hard4.wav" },
	land = { "physics/wood/wood_box_impact_hard1.wav", "physics/wood/wood_box_impact_hard3.wav" },
	bail = { "physics/body/body_medium_impact_hard1.wav", "physics/body/body_medium_impact_hard4.wav" },
}

local cv_volume = CreateClientConVar("skate3_volume", "1", true, false, "Skate sound volume, 0 to 1", 0, 1)
local cv_pack = CreateClientConVar("skate3_sounds", "hl2", true, false, "Skate sounds: hl2 (the classic Half-Life 2 ones) or off")

-- Which kind of contact a skater state is.
local function Kind(state)
	if not state then return end
	if state:find("^Grind") then return "grind" end
	if state:find("^Wipeout") then return "bail" end
	if state:find("^Biped") or state == "OffBoardPushing" then return "foot" end
	if state:find("Air") then return "air" end
	return "ground"
end

local loops = {}
local last

local function Loop(name, ent)
	local s = loops[name]
	if not s or s.ent ~= ent then
		if s then s.patch:Stop() end
		s = { patch = CreateSound(ent, SOUNDS[name]), ent = ent }
		loops[name] = s
	end
	return s.patch
end

local function Play(name, ent, level)
	local list = SOUNDS[name]
	ent:EmitSound(list[math.random(#list)], 75, math.random(95, 105), level * cv_volume:GetFloat())
end

-- Called every frame while skating, with the latest pose.
function Sounds.Update(ent, pose)
	if not IsValid(ent) or not pose or cv_pack:GetString() == "off" then return Sounds.Stop() end
	local kind = Kind(pose.state)
	local volume = cv_volume:GetFloat()
	-- m/s: a brisk push is about 4, flat out about 10.
	local speed = pose.speed or 0

	if last and kind ~= last then
		if kind == "air" and (last == "ground" or last == "grind") then
			Play("pop", ent, 0.8)
		elseif (kind == "ground" or kind == "grind") and last == "air" then
			Play("land", ent, math.Clamp(0.5 + speed / 20, 0.5, 1))
		elseif kind == "bail" then
			Play("bail", ent, 1)
		end
	end
	last = kind

	local roll = Loop("roll", ent)
	if kind == "ground" and speed > 0.3 then
		if not loops.roll.on then
			roll:PlayEx(0, 100)
			loops.roll.on = true
		end
		roll:ChangeVolume(math.Clamp(speed / 10, 0.05, 0.6) * volume, 0.1)
		roll:ChangePitch(math.Clamp(70 + speed * 6, 70, 130), 0.1)
	elseif loops.roll.on then
		roll:FadeOut(0.15)
		loops.roll.on = false
	end

	local grind = Loop("grind", ent)
	if kind == "grind" then
		if not loops.grind.on then
			grind:PlayEx(0.7 * volume, 100)
			loops.grind.on = true
		end
		grind:ChangePitch(math.Clamp(80 + speed * 4, 80, 130), 0.1)
	elseif loops.grind.on then
		grind:FadeOut(0.1)
		loops.grind.on = false
	end
end

function Sounds.Stop()
	for _, s in pairs(loops) do
		s.patch:Stop()
		s.on = false
	end
	last = nil
end

return Sounds
