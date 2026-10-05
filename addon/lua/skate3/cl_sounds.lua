-- Skate sounds, driven by the skater's state each frame: rolling and grinding
-- loops that follow speed, and one-shots for pops, landings and bails.
--
-- The classic set is Half-Life 2 sounds every Garry's Mod install has. The
-- disc set is Skate 3's own, which setup decodes from the player's disc into
-- sound/skate3; anything it hasn't mapped yet falls back to the classic one.

local Sounds = {}

local HL2 = {
	roll = "physics/concrete/concrete_scrape_smooth_loop1.wav",
	grind = "physics/metal/metal_grenade_scrape_rough_loop1.wav",
	pop = { "physics/wood/wood_plank_impact_hard1.wav", "physics/wood/wood_plank_impact_hard4.wav" },
	land = { "physics/wood/wood_box_impact_hard1.wav", "physics/wood/wood_box_impact_hard3.wav" },
	bail = { "physics/body/body_medium_impact_hard1.wav", "physics/body/body_medium_impact_hard4.wav" },
}

local cv_volume = CreateClientConVar("skate3_volume", "1", true, false, "Skate sound volume, 0 to 1", 0, 1)
local cv_pack = CreateClientConVar("skate3_sounds", "hl2", true, false,
	"Skate sounds: hl2 (the classic Half-Life 2 ones), disc (Skate 3's own, installed by setup) or off")

-- Skate 3 rolls on recordings of each surface, looped; Source materials map
-- onto them here.
local ROLL = {
	[MAT_WOOD] = "wood_ramp_hard",
	[MAT_METAL] = "metal_smooth_hard",
	[MAT_GRATE] = "metal_smooth_hard",
	[MAT_VENT] = "metal_smooth_hard",
	[MAT_CONCRETE] = "concrete_smooth_hard",
	[MAT_TILE] = "concrete_smooth_soft",
	[MAT_DIRT] = "asphalt_rough_hard",
	[MAT_SAND] = "asphalt_rough_hard",
	[MAT_GRASS] = "asphalt_rough_hard",
	[MAT_SNOW] = "asphalt_rough_hard",
}
local ROLL_DEFAULT = "asphalt_smooth_hard"

function Sounds.HasDisc()
	return file.Exists("sound/skate3/index.txt", "GAME")
end

local ground, nextTrace = ROLL_DEFAULT, 0

-- The grain for what's under the board, checked a few times a second.
local function RollSound(ent)
	if CurTime() >= nextTrace then
		nextTrace = CurTime() + 0.25
		local pos = ent:GetPos()
		local tr = util.TraceLine({ start = pos + Vector(0, 0, 8), endpos = pos - Vector(0, 0, 40), filter = ent })
		local name = tr.Hit and ROLL[tr.MatType] or ROLL_DEFAULT
		ground = file.Exists("sound/skate3/roll/" .. name .. ".wav", "GAME") and name or ROLL_DEFAULT
	end
	return "skate3/roll/" .. ground .. ".wav"
end

-- The sound to use for `name`, from the set the player picked.
local function Path(name, ent)
	if cv_pack:GetString() == "disc" and Sounds.HasDisc() then
		if name == "roll" then return RollSound(ent) end
	end
	return HL2[name]
end

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

-- A looping sound for `name`, swapped when its entity or sound changes (the
-- disc's rolling sound follows the surface).
local function Loop(name, ent)
	local path = Path(name, ent)
	local s = loops[name]
	if not s or s.ent ~= ent or s.path ~= path then
		local volume = s and s.on and s.volume
		if s then s.patch:Stop() end
		s = { patch = CreateSound(ent, path), ent = ent, path = path }
		loops[name] = s
		if volume then
			s.patch:PlayEx(volume, 100)
			s.on, s.volume = true, volume
		end
	end
	return s.patch
end

local function Play(name, ent, level)
	local list = Path(name, ent)
	if istable(list) then list = list[math.random(#list)] end
	ent:EmitSound(list, 75, math.random(95, 105), level * cv_volume:GetFloat())
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
		loops.roll.volume = math.Clamp(speed / 10, 0.05, 0.6) * volume
		roll:ChangeVolume(loops.roll.volume, 0.1)
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
