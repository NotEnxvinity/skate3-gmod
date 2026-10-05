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

-- setup's sounds.json: the samples behind the game's sound ids, and which
-- of the disc's sounds loop.
local manifest

local function Manifest()
	if manifest == nil then
		local text = file.Read("sound/skate3/sounds.json", "GAME")
		manifest = text and util.JSONToTable(text) or false
	end
	return manifest or nil
end

local function Loops(folder)
	local m = Manifest()
	return m and m.loops and m.loops[folder] or {}
end

-- Plays one of the game's own sound ids from a bank: one alternative, and
-- one member from each of its groups, at the member's gain. False when setup
-- didn't install it.
-- Plays one take of a retail sound id. A record's groups are the same hit at
-- rising strength, so `strength` (0 to 1) picks one rather than stacking them
-- all, and sets how loud it is.
local function PlayId(folder, id, ent, strength)
	local m = Manifest()
	local ids = m and m.ids and m.ids[folder]
	-- util.JSONToTable turns numeric keys into numbers.
	local alternatives = ids and (ids[id] or ids[tostring(id)])
	if not alternatives or #alternatives == 0 then return false end
	local groups = {}
	for _, group in ipairs(alternatives[math.random(#alternatives)]) do
		if #group > 0 then groups[#groups + 1] = group end
	end
	if #groups == 0 then return false end
	strength = math.Clamp(strength, 0, 1)
	local group = groups[math.Clamp(math.floor(strength * #groups) + 1, 1, #groups)]
	local member = group[math.random(#group)]
	local path = string.format("skate3/%s/%04d.wav", folder, member[1])
	local level = math.Clamp(member[2], 0, 1) * (0.3 + 0.5 * strength) * cv_volume:GetFloat()
	ent:EmitSound(path, 70, math.random(97, 103), level)
	return true
end

local picks = {}

-- The sound to use for `name`, from the set the player picked: the disc's
-- loops where setup found some, else HL2's.
local function Path(name, ent)
	if Disc() and picks[name] then return picks[name] end
	return HL2[name]
end

-- A random looping sound from a disc folder for `name`, kept until the next pick.
local function Pick(name, folder)
	local list = Loops(folder)
	picks[name] = #list > 0 and string.format("skate3/%s/%s.wav", folder, list[math.random(#list)]) or nil
end

local function OnMetal(ent)
	return Ground(ent) == "metal_smooth_hard"
end

-- Skate 3's pop: soft, medium or hard by how fast you're going, from the
-- metal set on metal (retail picks it by the wheels' surface category).
local function Pop(ent, speed)
	local class = speed < 3 and 0 or speed < 6 and 1 or 2
	local base = OnMetal(ent) and 0x44F or 0x449
	return PlayId("collisions", base + class, ent, 0.2 + class * 0.25)
end

-- Under this long in the air it was a bump, not a jump: no landing.
local BUMP = 0.15

-- Skate 3's landing, by time in the air: a soft or hard layer (0.75 s splits
-- them), and the heavy impact on top only after real air.
local function Land(ent, air)
	if air < BUMP then return true end
	local strength = math.Clamp(air / 1.2, 0, 1)
	local layer = (OnMetal(ent) and 0x35E or 0x35C) + (air >= 0.75 and 1 or 0)
	local played = PlayId("collisions", layer, ent, strength)
	if air >= 0.5 then played = PlayId("collisions", 0x447, ent, strength * 0.8) or played end
	return played
end

-- A grind's hit, harder the faster you hit it or the further you dropped: the
-- board on the rail, plus the rail itself ringing when it's metal and it hit hard.
local function GrindHit(ent, speed, air)
	local strength = math.Clamp(math.max(speed / 10, (air or 0) / 1.2), 0.1, 1)
	local board = PlayId("collisions", 879, ent, strength)
	local rail = strength > 0.4 and OnMetal(ent) and PlayId("metal", 399, ent, strength * 0.7)
	return board or rail
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

local airStart
local landedAt = -math.huge

-- Keeps the loop for `name` playing at `level` while `on`, fading it out after.
local function Hold(name, ent, on, level)
	if on and level > 0.01 then
		local patch = Loop(name, ent)
		if not loops[name].on then
			patch:PlayEx(0, 100)
			loops[name].on = true
		end
		patch:ChangeVolume(level, 0.1)
		loops[name].volume = level
	elseif loops[name] and loops[name].on then
		loops[name].patch:FadeOut(0.2)
		loops[name].on = false
	end
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

	local disc = Disc()
	if last and kind ~= last then
		if kind == "air" and (last == "ground" or last == "grind") then
			-- Rough ground flickers in and out of the air; only a takeoff
			-- after a moment on the ground pops.
			if CurTime() - landedAt > BUMP * 2 and not (disc and Pop(ent, speed)) then Play("pop", ent, 0.8) end
			airStart = CurTime()
		elseif (kind == "ground" or kind == "grind") and last == "air" then
			landedAt = CurTime()
			local air = airStart and CurTime() - airStart or 0
			-- Dropping onto a rail is the grind's hit, not a landing.
			local hit = disc and (kind == "grind" and GrindHit(ent, speed, air) or kind == "ground" and Land(ent, air))
			if not hit and (kind == "grind" or air >= BUMP) then Play("land", ent, math.Clamp(0.5 + speed / 20, 0.5, 1)) end
		elseif kind == "grind" and disc then
			GrindHit(ent, speed)
		elseif kind == "bail" then
			Play("bail", ent, 1)
		end
		if kind == "grind" then Pick("grind", "grinds") end
	end
	last = kind

	if disc then
		RollBands(ent, kind == "ground" and speed > 0.3, speed, volume)
		if loops.roll and loops.roll.on then
			loops.roll.patch:Stop()
			loops.roll.on = false
		end
		-- The trucks' rattle rides on top of the surface, louder with speed.
		if not picks.rattle then Pick("rattle", "rattles") end
		if picks.rattle then
			Hold("rattle", ent, kind == "ground" and speed > 0.5, math.Clamp(speed / 12, 0, 0.45) * volume)
		end
		-- Wheels spinning free after the pop, winding down through the air.
		if picks.spin == nil then
			picks.spin = file.Exists("sound/skate3/spins/whls_spins_jump_1.wav", "GAME") and "skate3/spins/whls_spins_jump_1.wav" or false
		end
		local air = kind == "air" and airStart and CurTime() - airStart or 0
		if picks.spin then
			Hold("spin", ent, kind == "air", math.Clamp(1 - air / 2, 0, 1) * 0.35 * volume)
		end
	else
		RollBands(ent, false, speed, volume)
		RollClassic(ent, kind == "ground" and speed > 0.3, speed, volume)
		Hold("rattle", ent, false, 0)
		Hold("spin", ent, false, 0)
	end

	local grind = Loop("grind", ent)
	if kind == "grind" then
		if not loops.grind.on then
			grind:PlayEx(0.7 * volume, 100)
			loops.grind.on = true
		end
		if disc and picks.grind then
			grind:ChangePitch(math.Clamp(92 + speed * 1.5, 92, 110), 0.1)
		else
			grind:ChangePitch(math.Clamp(80 + speed * 4, 80, 130), 0.1)
		end
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
