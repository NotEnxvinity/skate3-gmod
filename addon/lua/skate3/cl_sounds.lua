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

-- Skate 3 rolls on one recording per surface that speeds up from a crawl to
-- flat out, playing the part that matches the board's speed. Setup cuts each
-- into ROLL_BANDS looping bands (setup/audio.py) and this crossfades between
-- them, the way HL2's vehicles blend engine loops by RPM. Source materials
-- map onto the surfaces here.
local ROLL_BANDS = 8
-- m/s the end of the recording stands for: flat out is about 10.
local ROLL_TOP = 11
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

local function Disc()
	return cv_pack:GetString() == "disc" and Sounds.HasDisc()
end

-- The surface under the board, checked a few times a second.
local function Ground(ent)
	if CurTime() >= nextTrace then
		nextTrace = CurTime() + 0.25
		local pos = ent:GetPos()
		local tr = util.TraceLine({ start = pos + Vector(0, 0, 8), endpos = pos - Vector(0, 0, 40), filter = ent })
		local name = tr.Hit and ROLL[tr.MatType] or ROLL_DEFAULT
		ground = file.Exists("sound/skate3/roll/" .. name .. "_0.wav", "GAME") and name or ROLL_DEFAULT
	end
	return ground
end

-- The sound to use for `name`, from the set the player picked.
local function Path(name, ent)
	return HL2[name]
end

local bands = {}

-- The disc's rolling: the two bands either side of the board's speed, blended
-- at equal power, quiet when barely moving.
local function RollBands(ent, rolling, speed, volume)
	local name = rolling and Ground(ent) or ground
	local position = math.Clamp(speed / ROLL_TOP, 0, 1) * (ROLL_BANDS - 1)
	local low = math.floor(position)
	local blend = position - low
	local level = rolling and math.Clamp(speed / 1.5, 0, 1) * 0.7 * volume or 0
	for k = 0, ROLL_BANDS - 1 do
		local want = 0
		if k == low then
			want = math.cos(blend * math.pi / 2) * level
		elseif k == low + 1 then
			want = math.sin(blend * math.pi / 2) * level
		end
		local path = "skate3/roll/" .. name .. "_" .. k .. ".wav"
		local s = bands[k]
		if want > 0.01 then
			if not s or s.ent ~= ent or s.path ~= path then
				if s then s.patch:Stop() end
				s = { patch = CreateSound(ent, path), ent = ent, path = path }
				bands[k] = s
			end
			if not s.on then
				s.patch:PlayEx(0, 100)
				s.on = true
			end
			s.patch:ChangeVolume(want, 0.1)
		elseif s and s.on then
			s.patch:FadeOut(0.2)
			s.on = false
		end
	end
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

-- A looping sound for `name`, swapped when its entity or sound changes.
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

-- HL2's rolling: one scrape loop, pitched and louder with speed.
local function RollClassic(ent, rolling, speed, volume)
	local roll = Loop("roll", ent)
	if rolling then
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

	if Disc() then
		RollBands(ent, kind == "ground" and speed > 0.3, speed, volume)
		if loops.roll and loops.roll.on then
			loops.roll.patch:Stop()
			loops.roll.on = false
		end
	else
		RollBands(ent, false, speed, volume)
		RollClassic(ent, kind == "ground" and speed > 0.3, speed, volume)
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
	for _, set in ipairs({ loops, bands }) do
		for _, s in pairs(set) do
			s.patch:Stop()
			s.on = false
		end
	end
	last = nil
end

return Sounds
