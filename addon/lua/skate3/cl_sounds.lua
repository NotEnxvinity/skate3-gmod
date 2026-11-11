-- Skate sounds, driven by the skater's state each frame: rolling, grinding and
-- sliding loops that follow speed, one-shots for pops and landings, the
-- wheels spinning down, footsteps, bails, and the score multiplier's chime.
--
-- The classic set is Half-Life 2 sounds every Garry's Mod install has. The
-- disc set is Skate 3's own, which setup decodes from the player's disc into
-- sound/skate3; anything it hasn't mapped falls back to the classic one. Which
-- disc sound plays when follows retail's rules, as SK8-ENGINE's port of the
-- game's audio code spells them out (crates/skate-audio/src/player).

local Sounds = {}

local HL2 = {
	roll = "physics/concrete/concrete_scrape_smooth_loop1.wav",
	grind = "physics/metal/metal_grenade_scrape_rough_loop1.wav",
	pop = { "physics/wood/wood_plank_impact_hard1.wav", "physics/wood/wood_plank_impact_hard4.wav" },
	land = { "physics/wood/wood_box_impact_hard1.wav", "physics/wood/wood_box_impact_hard3.wav" },
	bail = { "physics/body/body_medium_impact_hard1.wav", "physics/body/body_medium_impact_hard4.wav" },
}
-- HL2's body hits for each bump of a bail, soft and hard.
local HL2_HITS = {
	soft = { "physics/body/body_medium_impact_soft1.wav", "physics/body/body_medium_impact_soft2.wav",
		"physics/body/body_medium_impact_soft3.wav", "physics/body/body_medium_impact_soft4.wav",
		"physics/body/body_medium_impact_soft5.wav", "physics/body/body_medium_impact_soft6.wav",
		"physics/body/body_medium_impact_soft7.wav" },
	hard = { "physics/body/body_medium_impact_hard1.wav", "physics/body/body_medium_impact_hard2.wav",
		"physics/body/body_medium_impact_hard3.wav", "physics/body/body_medium_impact_hard4.wav",
		"physics/body/body_medium_impact_hard5.wav", "physics/body/body_medium_impact_hard6.wav" },
}

-- HL2's bone breaks: a fracture (a dull crack) and a break (a snap, and the
-- wet one under it).
local HL2_BONES = {
	{ "physics/body/body_medium_break3.wav", "physics/body/body_medium_break4.wav" },
	{ "physics/body/body_medium_break2.wav", "physics/flesh/flesh_bloody_break.wav" },
}
-- Gets played when a score multiplier is reached and the disc has nothing for it.
local HL2_MULTIPLIER = "buttons/button14.wav"

local cv_volume = CreateClientConVar("skate3_volume", "1", true, false, "Skate sound volume, 0 to 1", 0, 1)
local cv_pack = CreateClientConVar("skate3_sounds", "disc", true, false,
	"Skate sounds: hl2 (the classic Half-Life 2 ones), disc (Skate 3's own, installed by setup) or off")
local cv_bails = CreateClientConVar("skate3_bail_sounds", "hl2", true, false,
	"Bail sounds with the disc set: disc (Skate 3's own body hits and slides) or hl2 (Half-Life 2's)")
local cv_bones = CreateClientConVar("skate3_bone_sounds", "auto", true, false,
	"Bone breaks in a bail: auto (the bail sounds' set), disc (Skate 3's Hall of Meat bank), hl2 or off")
local cv_mult = CreateClientConVar("skate3_multiplier_sounds", "1", true, false,
	"Play a sound when the score multiplier goes up (x2, x3...)")
local cv_steps = CreateClientConVar("skate3_footsteps", "hl2", true, false,
	"Footsteps with the disc set: disc (Skate 3's own) or hl2 (Garry's Mod's own for the ground underfoot)")
local cv_seams = CreateClientConVar("skate3_seam_sounds", "1", true, false,
	"Wheels click over the joints in the pavement (disc sounds)")
local cv_retail = CreateClientConVar("skate3_retail_audio", "1", true, false,
	"Play Skate 3's sounds with the port of its own audio engine, when setup prepared its cache (BETA, setup --audio-engine); 0 keeps this file's sounds")
local cv_3d = CreateClientConVar("skate3_audio_3d", "1", true, false,
	"Skate 3 sound engine: sounds from a board or body away from you get quieter, duller and come from their side", 0, 1)
local cv_reverb = CreateClientConVar("skate3_audio_reverb", "1", true, false,
	"Skate 3 sound engine: how much the room echoes (0 off, 1 normal, 2 a lot)", 0, 2)
local cv_debug = CreateClientConVar("skate3_debug_sounds", "0", false, false, "Print each footstep, wheel spin and bail hit")

-- Map units per metre: Source and the simulation are both inches.
local UNITS = 39.37
-- The simulation's step: speeds come from how far bones moved between ticks.
local TICK = 1 / 60

local function Debug(...)
	if cv_debug:GetBool() then print("[skate3] " .. string.format(...)) end
end

-- Skate 3 rolls on one recording per surface that speeds up from a crawl to
-- flat out, playing the part that matches the board's speed. Setup cuts each
-- into ROLL_BANDS looping bands (setup/audio.py) and this crossfades between
-- them, the way HL2's vehicles blend engine loops by RPM. Source materials
-- map onto the surfaces here.
local ROLL_BANDS = 8
-- m/s the end of the recording stands for: flat out is about 10.
local ROLL_TOP = 11
local ROLL_DEFAULT = "asphalt_smooth_hard"

-- Skate 3 sorts every surface into one of its materials (the rows of its
-- AudioSurfaceMap), and that row decides the rolling, the landing, the
-- footsteps and the collisions. Source's surfaces go onto the rows here, by
-- the surface property's name first (the first word found wins) and the
-- trace's material type after. Rows: 0 smooth asphalt, 2 smooth mineral
-- (concrete, tile), 3 rough mineral (brick, stone), 6 wood, 7 loose ground,
-- 8 metal, 9 vegetation, 47 plastic, 67 grille.
local PROP_ROWS = {
	{ "grate", 67 }, { "chain", 67 }, { "metal", 8 }, { "canister", 8 }, { "wood", 6 },
	{ "asphalt", 0 }, { "road", 0 },
	{ "concrete_block", 3 }, { "brick", 3 }, { "cobble", 3 }, { "rock", 3 }, { "boulder", 3 }, { "stone", 3 },
	{ "concrete", 2 }, { "tile", 2 }, { "ceramic", 2 }, { "glass", 2 }, { "plaster", 2 }, { "ice", 2 },
	{ "gravel", 7 }, { "dirt", 7 }, { "sand", 7 }, { "mud", 7 }, { "snow", 7 }, { "slime", 7 },
	{ "grass", 9 }, { "foliage", 9 }, { "plant", 9 },
	{ "plastic", 47 }, { "rubber", 47 }, { "carpet", 47 },
}
local MAT_ROWS = {
	[MAT_CONCRETE] = 2, [MAT_TILE] = 2, [MAT_GLASS] = 2, [MAT_WOOD] = 6,
	[MAT_METAL] = 8, [MAT_VENT] = 8, [MAT_GRATE] = 67,
	[MAT_DIRT] = 7, [MAT_SAND] = 7, [MAT_SNOW] = 7, [MAT_GRASS] = 9, [MAT_PLASTIC] = 47,
}
-- The recordings each rolling surface of the vault (AudioSurfaceMap word 1)
-- can use, the first installed one played; and, with no vault, each row's.
local ROLL_NUMBERS = {
	[1] = { "asphalt_rough_hard", "asphalt_rough_soft" },
	[2] = { "concrete_rough_hard", "concrete_rough_soft", "concrete_smooth_hard" },
	[3] = { "asphalt_smooth_hard", "asphalt_smooth_soft" },
	[4] = { "concrete_smooth_hard", "concrete_smooth_soft" },
	[5] = { "wood_ramp_hard", "wood_ramp_soft" },
	[6] = { "concrete_aggregate_hard", "concrete_rough_hard", "asphalt_rough_hard" },
	[9] = { "metal_smooth_hard", "metal_smooth_soft" },
}
local ROW_ROLL = {
	[6] = { "wood_ramp_hard" }, [8] = { "metal_smooth_hard" }, [67] = { "metal_smooth_hard" },
	[2] = { "concrete_smooth_hard" }, [3] = { "concrete_smooth_hard" },
	[7] = { "asphalt_rough_hard" }, [9] = { "asphalt_rough_hard" },
}
-- Asked a few times a frame, and a file.Exists looks through every mounted
-- addon (hundreds with a big Workshop collection): checked every few seconds.
local hasDisc, hasDiscAt = nil, -math.huge
function Sounds.HasDisc()
	local now = RealTime()
	if hasDisc == nil or now - hasDiscAt > 5 then
		hasDisc, hasDiscAt = file.Exists("sound/skate3/index.txt", "GAME"), now
	end
	return hasDisc
end

local function Disc()
	return cv_pack:GetString() == "disc" and Sounds.HasDisc()
end

local installed = {}

-- Whether setup installed the rolling recording `name` (asked once each).
local function Installed(name)
	if installed[name] == nil then
		installed[name] = file.Exists("sound/skate3/roll/" .. name .. "_0.wav", "GAME")
	end
	return installed[name]
end

-- setup's sounds.json: the samples behind the game's sound ids, which of the
-- disc's sounds loop, and the vault's collision tuning.
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

local function Tuning()
	local m = Manifest()
	return m and m.tuning
end

-- AudioSurfaceMap entry of a material, as setup exports it: { rolling,
-- footstep surface, collision class }; materials 94 and up share entry 94.
local function SurfaceEntry(m)
	local t = Tuning()
	local s = t and t.surfaces
	if not s or not m then return end
	return s[math.min(m, 94) + 1] or s[#s]
end

-- The same entry whole (18 words): 3 is set on a hard surface.
local function SurfaceWords(m)
	local t = Tuning()
	local s = t and t.rows
	if not s or not m then return end
	return s[math.min(m, 94) + 1] or s[#s]
end

local rowOfProp, rowNames = {}, {}
local lastProp = ""

-- Skate 3's material for the surface a trace hit.
local function RowOf(tr)
	if not tr or not tr.Hit then return 0 end
	local props = tr.SurfaceProps
	local row = rowOfProp[props]
	if row == nil then
		local name = util.GetSurfacePropName(props)
		name = isstring(name) and name:lower() or ""
		for _, p in ipairs(PROP_ROWS) do
			if name:find(p[1], 1, true) then
				row = p[2]
				break
			end
		end
		rowOfProp[props] = row or false
		row = row or false
		rowNames[props] = name
	end
	lastProp = rowNames[props] or ""
	return row or MAT_ROWS[tr.MatType] or 0
end

-- The rolling recording for a material.
local function RollFor(row)
	local e = SurfaceEntry(row)
	for _, name in ipairs(e and ROLL_NUMBERS[e[1]] or ROW_ROLL[row] or {}) do
		if Installed(name) then return name end
	end
	return ROLL_DEFAULT
end

-- The rolling recording and Skate 3 material under `pos`, and the trace.
local function Surface(pos, filter)
	local tr = util.TraceLine({ start = pos + Vector(0, 0, 8), endpos = pos - Vector(0, 0, 40), filter = filter })
	local row = RowOf(tr)
	return RollFor(row), tr, row
end

local ground, groundRow, nextTrace = ROLL_DEFAULT, 0, 0
-- The rolling surface (AudioSurfaceMap word 1) under the board: 3 smooth
-- asphalt, 4 smooth concrete, 5 wood, 7 grass, 8 loose ground...
local groundNumber = 0
local shownGround

-- The surface under the board, checked a few times a second.
local function Ground(ent)
	if CurTime() >= nextTrace then
		nextTrace = CurTime() + 0.25
		local name, _, row = Surface(ent:GetPos(), ent)
		ground, groundRow = name, row
		local e = SurfaceEntry(row)
		groundNumber = e and e[1] or 0
		if cv_debug:GetBool() and shownGround ~= row .. name .. lastProp then
			shownGround = row .. name .. lastProp
			Debug("ground: property '%s' -> Skate 3 material %d, rolls on surface %d (%s)", lastProp, row, groundNumber,
				name)
		end
	end
	return ground
end

-- Whether a material is hard underfoot, by the vault (metal and rock on the
-- disc's own say; before setup has run, by the row alone).
local function IsHard(row)
	local w = SurfaceWords(row)
	if w then return (w[3] or 0) ~= 0 end
	return row == 8 or row == 67 or row == 2 or row == 3
end

-- The disc plays metal's own landings and pops on rails and sheet metal.
local function IsMetal(row)
	local t = Tuning()
	local rec = t and t.materials and t.materials[row + 1]
	if rec then return rec.kind == 1 end
	return row == 8 or row == 67
end

-- One take of a retail sound id from a bank folder, played at `pos` when
-- given, else on `ent`. False when setup didn't install it.
--
-- A record is a list of groups and each group plays at once (retail's Splice
-- player starts one voice per group, a random member of each). Pops, landings
-- and grind hits predate knowing that and still play only one member of the
-- group `strength`, 0 to 1, picks; `layered` plays them the way retail does.
-- `level` is the sound level in dB (0 = heard everywhere, for the interface).
local function PlayId(folder, id, ent, strength, volume, pitch, pos, layered, level)
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
	if not layered then
		groups = { groups[math.Clamp(math.floor(strength * #groups) + 1, 1, #groups)] }
	end
	level = level or 70
	for _, group in ipairs(groups) do
		local member = group[math.random(#group)]
		local path = string.format("skate3/%s/%04d.wav", folder, member[1])
		local gain = math.Clamp(member[2], 0, 1) * (volume or (0.3 + 0.5 * strength)) * cv_volume:GetFloat()
		local rate = math.Clamp(math.floor((pitch or 1) * math.random(97, 103)), 30, 250)
		if pos then
			sound.Play(path, pos, level, rate, gain)
		else
			ent:EmitSound(path, level, rate, gain)
		end
	end
	return true
end

local picks = {}

-- The sound to use for `name`, from the set the player picked: the disc's
-- loops where setup found some, else HL2's.
local function Path(name)
	if Disc() and picks[name] then return picks[name] end
	return HL2[name]
end

-- A random looping sound from a disc folder for `name`, kept until the next
-- pick. Stays unset when the folder has none.
local function Pick(name, folder)
	local list = Loops(folder)
	picks[name] = #list > 0 and string.format("skate3/%s/%s.wav", folder, list[math.random(#list)]) or nil
end

local function OnMetal(ent)
	Ground(ent)
	return IsMetal(groundRow)
end

-- Skate 3's board foley tuning from the vault (setup/audio_tuning.py): the pop,
-- landing and whoosh sounds. Nil before setup has read it; the rules below
-- then play the ids the first version of this file knew.
local function Board()
	local t = Tuning()
	return t and t.board
end

-- How hard the last landing was, 0 to 1: retail's landing level, the size of
-- the velocity change in m/s over 2.65 (a drop of about 0.4 m is already full).
-- A pop is soft, medium or hard by it.
local landingLevel = 0
local LANDING_FULL = 2.65

-- The take-off whoosh by speed (the vault's thresholds, m/s, fastest first).
local function Whoosh(ent, speed)
	local b = Board()
	for _, w in ipairs(b and b.whooshes or {}) do
		if speed > w[1] then
			Debug("whoosh: %.1f m/s, id %d", speed, w[2])
			return PlayId("collisions", w[2], ent, 0.5, 0.35)
		end
	end
end

-- Skate 3's pop. Retail picks its table by the surface (hard or soft) and the
-- sound in it by how hard the last landing was; before the vault it was by
-- speed, soft, medium or hard, with the metal set on metal.
local function Pop(ent, speed)
	Ground(ent)
	local b = Board()
	local hard = IsHard(groundRow)
	local ids = b and b.pop and b.pop[hard and 2 or 1]
	if ids and #ids >= 3 then
		local levels = b.pop_levels
		local class = 0
		if levels then class = landingLevel > levels[1] and 2 or landingLevel > levels[2] and 1 or 0 end
		Debug("pop: %s surface, class %d (landing %.2f), id %d", hard and "hard" or "soft", class, landingLevel, ids[class + 1])
		local played = PlayId("collisions", ids[class + 1], ent, 0.2 + class * 0.25)
		Whoosh(ent, speed)
		return played
	end
	local class = speed < 3 and 0 or speed < 6 and 1 or 2
	local base = OnMetal(ent) and 0x44F or 0x449
	return PlayId("collisions", base + class, ent, 0.2 + class * 0.25)
end

-- Under this long in the air it was a bump, not a jump: no landing.
local BUMP = 0.15
-- Landing classes by time in the air: hard from here, and a heavy impact on
-- top from the second (retail's are by the wheels' air time and impact speed,
-- with tuning we haven't read; these are the first version's guesses).
local LAND_HARD, LAND_HEAVY = 0.75, 1.5

-- Skate 3's landing: the wheels' landing for the surface (a hard or a soft
-- one) and class, by time in the air, and a heavy layer over it after real
-- air.
local function Land(ent, air)
	if air < BUMP then return true end
	Ground(ent)
	local strength = math.Clamp(air / 1.2, 0, 1)
	local b = Board()
	local landing = b and b.landing
	local row = landing and landing[IsHard(groundRow) and 3 or 1]
	local class = air >= LAND_HARD and 1 or 0
	if row and row.ids and #row.ids >= 3 and row.ids[class + 1] and row.ids[class + 1] > 0 then
		local level = row.levels and row.levels[class + 1] or 1
		Debug("landing: %s surface, class %d, id %d, %.1f s in the air", IsHard(groundRow) and "hard" or "soft", class,
			row.ids[class + 1], air)
		local played = PlayId("collisions", row.ids[class + 1], ent, strength, math.Clamp(level, 0, 1) * (0.3 + 0.5 * strength))
		-- The heavy layer is the first table's third entry, whatever the surface.
		local heavy = air >= LAND_HEAVY and landing[1] and landing[1].ids and landing[1].ids[3]
		if heavy and heavy > 0 then played = PlayId("collisions", heavy, ent, strength) or played end
		return played
	end
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

-- Retail rolls on the grain recordings only on surfaces 1 to 6 and 9; on 7, 8
-- and 10 to 13 (grass, loose ground, manholes, grilles...) its sound scripts
-- play the PatchBank_Rolling_Surfaces loops instead, which setup installs as
-- sound/skate3/surfaces. Six loops for six surfaces: taken in that order.
-- Which loop is which is a guess until somebody hears them (the debug line
-- prints the one playing).
local AEMS_SURFACES = { 7, 8, 10, 11, 12, 13 }
local aemsRoll = {}

local function AemsRoll(ent, rolling, speed, volume)
	local want
	if rolling then
		local loops = Loops("surfaces")
		for k, n in ipairs(AEMS_SURFACES) do
			if n == groundNumber then want = loops[k] end
		end
	end
	local on = aemsRoll
	if on.patch and (not want or on.name ~= want or on.ent ~= ent) then
		on.patch:FadeOut(0.2)
		on.patch = nil
	end
	if not want then return false end
	if not on.patch then
		on.name, on.ent = want, ent
		on.patch = CreateSound(ent, string.format("skate3/surfaces/%s.wav", want))
		on.patch:PlayEx(0, 100)
		Debug("rolling on surface %d: loop surfaces/%s", groundNumber, want)
	end
	on.patch:ChangeVolume(math.Clamp(speed / 6, 0.1, 1) * 0.6 * volume, 0.1)
	on.patch:ChangePitch(math.Clamp(80 + speed * 4, 80, 125), 0.1)
	return true
end

-- Whether the ground is one of the surfaces the loops above cover.
local function AemsGround()
	for _, n in ipairs(AEMS_SURFACES) do
		if n == groundNumber then return #Loops("surfaces") > 0 end
	end
	return false
end

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
	local path = Path(name)
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
	local list = Path(name)
	if istable(list) then list = list[math.random(#list)] end
	ent:EmitSound(list, 75, math.random(95, 105), level * cv_volume:GetFloat())
end

local airStart, airVelocity
local landedAt = -math.huge

-- Keeps the loop for `name` playing at `level` while `on`, fading it out
-- after; `pitch` (100 = as recorded) follows when given.
local function Hold(name, ent, on, level, pitch)
	if on and level > 0.01 and Path(name) then
		local patch = Loop(name, ent)
		if not loops[name].on then
			patch:PlayEx(0, pitch or 100)
			loops[name].on = true
		end
		patch:ChangeVolume(level, 0.1)
		if pitch then patch:ChangePitch(pitch, 0.1) end
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

---------------------------------------------------------------------------
-- The wheels spinning free (retail SFXObj_Wheels, wheels.rs): a 14 s
-- spin-down recording, never looped, started part-way in so a fast board
-- starts near the full spin and a slow one near the end. It plays in the air
-- and with the board in your hands after stepping off, where only the end of
-- it plays (the start is capped at 26% of the way down). Two recordings,
-- used in turn, the manual one first.
---------------------------------------------------------------------------

local SPINS = { "skate3/spins/whls_spins_man_1.wav", "skate3/spins/whls_spins_jump_1.wav" }
local SPIN_LENGTH = 14
local SPIN_FULL = 50 -- km/h at which a spin starts at the very beginning
local SPIN_HAND_CAP = 0.26
local spin = { toggle = false }

local spinInstalled = {}
local function SpinInstalled(path)
	if spinInstalled[path] == nil then spinInstalled[path] = file.Exists("sound/" .. path, "GAME") end
	return spinInstalled[path]
end

local function SpinStop()
	spin.token = nil
	if IsValid(spin.channel) then spin.channel:Stop() end
	spin.channel = nil
end

-- Starts the next recording for a board going `speed` m/s; `hand` is the
-- board-in-hand slot.
local function SpinStart(speed, pos, level, hand)
	SpinStop()
	local path = SPINS[spin.toggle and 2 or 1]
	if not SpinInstalled(path) then path = SPINS[spin.toggle and 1 or 2] end
	spin.toggle = not spin.toggle
	if not SpinInstalled(path) then return end
	local x = math.Clamp(math.abs(speed) * 3.6 / SPIN_FULL, 0, 1)
	if hand then x = math.min(x, SPIN_HAND_CAP) end
	local seek = SPIN_LENGTH * (1 - x)
	Debug("wheels spin from %.1f s (%s, %.1f m/s)", seek, hand and "in hand" or "in the air", speed)
	local token = {}
	spin.token = token
	spin.level = level
	-- sound.PlayFile can start part-way in, which EmitSound can't.
	sound.PlayFile("sound/" .. path, "3d noplay", function(channel)
		if not IsValid(channel) then return end
		if spin.token ~= token then channel:Stop() return end
		if seek >= channel:GetLength() then channel:Stop() return end
		spin.channel = channel
		channel:SetPos(pos)
		channel:Set3DFadeDistance(300, 3000)
		channel:SetTime(seek)
		channel:SetVolume(spin.level * cv_volume:GetFloat())
		channel:Play()
	end)
end

-- Each frame: `trigger` is the slot that wants the wheels heard (nil, "air"
-- or "hand"); it starts on the trigger's rising edge, plays to its end and
-- stops when the trigger drops.
local function Spin(trigger, speed, pos, volume)
	local level = (trigger == "hand" and 0.3 or 0.4) * volume
	if trigger ~= spin.trigger then
		spin.trigger = trigger
		if trigger then SpinStart(speed, pos, level, trigger == "hand") else SpinStop() end
	end
	if IsValid(spin.channel) then
		spin.channel:SetPos(pos)
		spin.channel:SetVolume(level * cv_volume:GetFloat())
	end
end

---------------------------------------------------------------------------
-- Footsteps (retail SFXObj_OffBoard, footsteps.rs). Each time a foot comes
-- down: a step from sk8_foley by walk or run, an even or uneven step and the
-- footstep surface (1..7) of the material underfoot, plus a hard layer from
-- Skate_Collisions on surfaces 3 and 4, plus the clothes' walking foley by
-- body speed. Jumping on foot adds a take-off and an apex.
---------------------------------------------------------------------------

-- [walk, run][even, uneven][surface 1..7]
local STEP_IDS = {
	{ { 86, 82, 86, 91, 86, 78, 75 }, { 87, 83, 87, 91, 107, 79, 110 } },
	{ { 107, 102, 105, 105, 105, 99, 101 }, { 104, 103, 104, 106, 104, 100, 100 } },
}
-- [walk, run][even, uneven][surface 3, 4]
local STEP_IDS_HARD = { { { 963, 964 }, { 963, 964 } }, { { 963, 964 }, { 522, 523 } } }
local WALK_IDS = { 62, 63, 64 }
-- Retail's walk curve crosses its run threshold at about 5.9 m/s.
local RUN_SPEED = 5.9
local WALK_SPEEDS = { 2.5, 7.5 }
-- The step code's height between the feet's last plants, m.
local STEP_HEIGHT = 0.07
local JUMP_ID, APEX_ID = 65, 66

local FEET = {
	{ toe = "LEFTTOEBASE", ankle = "LEFTFOOT" },
	{ toe = "RIGHTTOEBASE", ankle = "RIGHTFOOT" },
}
-- A foot is down when its toe is this close to the ground (units) and
-- barely moving (m/s).
local FOOT_GROUND = 3
local FOOT_STILL = 0.6

local feet = { {}, {} }
local body = {}

local function BonePos(pose, name)
	local m = pose.bones and pose.bones[name]
	return m and Vector(m[4], m[8], m[12])
end

-- The disc material standing for a rolling recording's kind of ground, or nil.
local function FootstepSurface(row)
	local e = SurfaceEntry(row)
	local s = e and e[2] or 1
	return (s >= 1 and s <= 7) and s or 1
end

local function Step(foot, pos, comSpeed, uneven, row)
	local run = comSpeed > RUN_SPEED and 2 or 1
	local surface = FootstepSurface(row)
	local id = STEP_IDS[run][uneven and 2 or 1][surface]
	local played = PlayId("foley", id, LocalPlayer(), 0.5, 0.7, 1, pos)
	if surface == 3 or surface == 4 then
		PlayId("collisions", STEP_IDS_HARD[run][uneven and 2 or 1][surface - 2], LocalPlayer(), 0.5, 0.5, 1, pos)
	end
	local walk = comSpeed > WALK_SPEEDS[2] and 3 or comSpeed > WALK_SPEEDS[1] and 2 or 1
	PlayId("foley", WALK_IDS[walk], LocalPlayer(), 0.5, 0.5, 1, pos)
	Debug("step: foot %d, %s, surface %d, %s, foley %d%s", foot, run == 2 and "run" or "walk", surface,
		uneven and "uneven" or "even", id, played and "" or " (not installed)")
	return played
end

-- HL2's footstep: the one Garry's Mod plays for the surface underfoot.
local function StepClassic(pos, tr)
	local data = tr and tr.Hit and util.GetSurfaceData(tr.SurfaceProps)
	local name = data and (math.random(2) == 1 and data.stepLeftSound or data.stepRightSound)
	if name and name ~= "" then
		sound.Play(name, pos, 65, 100, 0.5 * cv_volume:GetFloat())
	end
end

-- Watches both feet for plants while on foot (or pushing on the board),
-- and the body for on-foot jumps.
local function Feet(pose, kind, dt, disc, volume)
	-- The jump foley goes with Skate 3's footsteps.
	disc = disc and cv_steps:GetString() == "disc"
	local hips = BonePos(pose, "HIPS")
	local comSpeed, comVz = 0, 0
	if hips then
		if body.hips and dt > 0 then
			local v = (hips - body.hips) / dt / UNITS
			comSpeed, comVz = v:Length(), v.z
		end
		body.hips = hips
	end
	-- Jumps on foot: the take-off as the feet leave the ground, the apex as
	-- the body starts falling.
	if disc and kind == "air" and body.kind == "foot" then
		body.jumping, body.rising = true, true
		PlayId("foley", JUMP_ID, LocalPlayer(), 0.5, 0.6, 1, hips)
		Debug("jump take-off")
	elseif body.jumping and kind == "air" and body.rising and comVz <= 0 then
		body.rising = false
		if disc then PlayId("foley", APEX_ID, LocalPlayer(), 0.5, 0.5, 1, hips) end
		Debug("jump apex")
	elseif kind ~= "air" then
		body.jumping = false
	end
	body.kind = kind

	local watching = kind == "foot" or kind == "ground"
	for i, f in ipairs(FEET) do
		local state = feet[i]
		local toe = BonePos(pose, f.toe) or BonePos(pose, f.ankle)
		local down = false
		if toe and watching then
			local speed = state.pos and dt > 0 and (toe - state.pos):Length() / dt / UNITS or math.huge
			local _, tr, row = Surface(toe, LocalPlayer())
			local height = tr.Hit and toe.z - tr.HitPos.z or math.huge
			down = height < FOOT_GROUND and speed < FOOT_STILL
			if down and not state.down then
				-- Retail's step code: a foot planted more than 7 cm above the
				-- other's last plant is an uneven step.
				local other = feet[3 - i].plantZ
				local uneven = other and (toe.z - other) / UNITS > STEP_HEIGHT or false
				state.plantZ = toe.z
				if disc then
					Step(i, toe, comSpeed, uneven, row)
				else
					StepClassic(toe, tr)
				end
			end
		end
		state.pos = toe
		state.down = down
	end
end

---------------------------------------------------------------------------
-- Bails (retail Contacts body poster and collision manager: contacts.rs,
-- collision.rs). Each body part that hits something is a collision between
-- its material and the ground's: an impact sets a tier from the material's
-- bands, a level from its windows, and each side plays the sample its
-- AudioSurface record names for that tier and the other side's class. The
-- clothes and pads add their own contacts. While the body slides along the
-- ground, Bodyslide loops.
--
-- The hits themselves come from Hall of Meat's tracking (cl_hall_of_meat.lua,
-- the "Skate3BodyHit" hook), which watches all 18 body parts on every bail,
-- Hall of Meat mode or not: a bone that breaks sounds like it scored.
---------------------------------------------------------------------------

local NO_MATERIAL = 143
-- Retail's body materials by part (contacts.rs body_materials): the material,
-- the cloth contact and the pad contact.
local HEAD = { material = 97, pad = 110 }
local TORSO = { material = 98, cloth = 109, pad = 110 }
local LEGS = { material = 99, cloth = 108, pad = 111 }
local ARMS = { material = 100, cloth = 107, pad = 111 }
local REGION_OF = {
	skull = HEAD,
	spine = TORSO, ribs = TORSO, pelvis = TORSO, lcollar = TORSO, rcollar = TORSO,
	larm = ARMS, rarm = ARMS, lforearm = ARMS, rforearm = ARMS, lhand = ARMS, rhand = ARMS,
	lfemur = LEGS, rfemur = LEGS, lshin = LEGS, rshin = LEGS, lfoot = LEGS, rfoot = LEGS,
}
-- Hall of Meat's own materials, kind 2: the body materials' HOM_Set_1 twins,
-- if retail numbers them in the same order. A guess; skate3_debug_sounds says
-- what plays so it can be checked by ear.
local HOM_OF = { [97] = 102, [98] = 103, [99] = 104, [100] = 105 }
-- How hard Hall of Meat's hits run, m/s of speed lost in a step: from the
-- weakest that counts to the one that breaks a bone (cl_hall_of_meat.lua).
local HIT_SOFT, HIT_HARD = 3.5, 10
-- The pad contacts' thresholds (contacts.rs ContactsTuning defaults): 110 on
-- the head and torso, 111 on the limbs.
local PAD_110 = { [97] = { 0.75, 1.25 }, [98] = { 0.7, 1.25 } }
local PAD_111 = { 0.65, 1.25 }
-- Collision class (0..2) of materials 95..113; false: AudioSurfaceMap entry 94.
local CLASS_95 = { 1, 2, 1, 0, 1, 1, 1, 1, 0, 1, 1, 1, 0, 0, 0, false, false, false, 1 }
local BANKS = { [0] = "collisions", [1] = "metal", [2] = "hom" }
-- Retail's collision manager has ten slots; a tumble can't start more than
-- that many sounds in one tick.
local VOICES = 10

local function Graph(g, v)
	local x, y = g[1], g[2]
	if v < x[1] then return y[1] end
	if v >= x[#x] then return y[#y] end
	for i = 2, #x do
		if v < x[i] then
			local dx = x[i] - x[i - 1]
			if dx > 0 then return y[i - 1] + (y[i] - y[i - 1]) / dx * (v - x[i - 1]) end
			return y[i]
		end
	end
	return y[1]
end

local function Material(m)
	local t = Tuning()
	return t and m and m >= 0 and t.materials and t.materials[m + 1]
end

local function Class(m)
	if m >= 95 and m <= 113 and CLASS_95[m - 94] then return CLASS_95[m - 94] end
	local e = SurfaceEntry(m < 94 and m or 94)
	return e and e[3] or 0
end

-- collision.rs impact_band: tier (0..2, 3 none) and its [low, high].
local function Band(m, impact)
	local rec = Material(m)
	local b = rec and rec.bands
	if not b or impact < b[4] then return 3, 0, 0 end
	if impact > b[1] then return 2, b[1], b[2] end
	if impact > b[3] then return 1, b[3], b[1] end
	return 0, b[4], b[3]
end

-- collision.rs contact_level: 0..32767 from the material's windows.
local WINDOW_AT = { [0] = 1, [4] = 2, [8] = 3, [12] = 4, [16] = 5, [20] = 6, [24] = 7, [28] = 8, [32] = 9,
	[36] = 10, [44] = 11, [48] = 12, [52] = 13, [56] = 14 }
local function Level(m, other, tier, low, high, value)
	if m < 0 or tier == 3 then return 0 end
	value = math.min(value, high)
	local rec = Material(m)
	local w = rec and rec.windows or {}
	local function W(off) return w[WINDOW_AT[off]] or 0 end
	local class = (m >= 97 or other == NO_MATERIAL) and 0 or Class(other)
	local lo, hi
	if tier == 0 then
		if class == 0 then lo, hi = W(8), W(12) elseif class == 1 then lo, hi = W(24), W(28) else lo, hi = W(52), W(56) end
	elseif tier == 1 then
		if class == 0 then lo, hi = W(0), W(4) elseif class == 1 then lo, hi = W(16), W(20) else lo, hi = W(44), W(48) end
	else
		lo, hi = W(32), W(36)
	end
	if high > low then return (hi - lo) / (high - low) * (value - low) + lo end
	return hi
end

-- collision.rs sample: plays `m`'s sound against `other` at `tier` and
-- `level`; true when one played.
local bail = { regions = {}, voices = 0, voicesAt = 0 }

local function Collide(m, other, tier, level, pos)
	if m < 0 or m >= NO_MATERIAL or tier == 3 or bail.voices >= VOICES then return false end
	local rec = Material(m)
	if not rec or not rec.ids or not BANKS[rec.kind] then return false end
	local class = other == NO_MATERIAL and 0 or Class(other)
	local id = tier == 2 and rec.ids[1] or tier == 0 and rec.ids[2 + class] or rec.ids[5 + class]
	if not id or id < 0 then return false end
	local volume = math.Clamp(level / 32767, 0, 1) * (rec.gain or 32767) / 32767
	if volume < 0.01 then return false end
	local played = PlayId(BANKS[rec.kind], id, LocalPlayer(), tier / 2, volume, (rec.pitch or 4096) / 4096, pos, true)
	if played then bail.voices = bail.voices + 1 end
	return played
end

-- One region's hit at `impact` against ground material `b`: retail's pair,
-- the second hit of a hard one, the clothes and the pad.
local function BodyHit(r, impact, b, pos, label)
	local a = r.material
	local ta, la_lo, la_hi = Band(a, impact)
	local tb, lb_lo, lb_hi = Band(b, impact)
	if ta == 3 and tb == 3 then return false end
	local la = Level(a, b, ta, la_lo, la_hi, impact)
	local lb = Level(b, a, tb, lb_lo, lb_hi, impact)
	local played = Collide(a, b, ta, la, pos)
	played = Collide(b, a, tb, lb, pos) or played
	if ta == 2 or tb == 2 then
		local ra, rb = Material(a), Material(b)
		if ta == 2 then Collide(a, b, 1, la * (ra and ra.scale or 1), pos) end
		if tb == 2 then Collide(b, a, 1, lb * (rb and rb.scale or 1), pos) end
	end
	if r.cloth then
		Collide(r.cloth, NO_MATERIAL, 0, Level(a, b, 0, la_lo, la_hi, impact), pos)
	end
	local th = r.pad == 110 and PAD_110[a] or r.pad == 111 and PAD_111
	if th and impact > th[1] and impact <= th[2] then
		Collide(r.pad, NO_MATERIAL, 1, Level(r.pad, b, 1, th[1], th[2], impact), pos)
	end
	Debug("bail hit: %s at %.2f, tiers %d/%d against material %d%s", label, impact, ta, tb, b,
		played and "" or " (no sound)")
	return played
end

-- The impact retail would read for a hit of `severity` (Hall of Meat's m/s):
-- spread over `m`'s own bands, from just above the quietest sound it makes
-- for the weakest hit that counts, to its hardest tier for one that breaks a
-- bone. Every hit Hall of Meat counts therefore makes a sound of its strength.
local function Impact(m, severity)
	local t = math.Clamp((severity - HIT_SOFT) / (HIT_HARD - HIT_SOFT), 0, 1)
	local rec = Material(m)
	local b = rec and rec.bands
	if not b then return t end
	local low, mid, top = b[4] * 1.02, b[3], b[2]
	if t < 0.5 then return low + (mid - low) * t * 2 end
	return mid + (top - mid) * (t - 0.5) * 2
end

-- HL2's version of a bail hit: a body impact, harder and louder the harder
-- the hit (`t`, 0 to 1).
local CLASSIC_HARD = 0.35
local function HitClassic(t, pos, label)
	local list = t > CLASSIC_HARD and HL2_HITS.hard or HL2_HITS.soft
	sound.Play(list[math.random(#list)], pos, 75, math.random(95, 105),
		math.Clamp(0.35 + t * 0.65, 0.35, 1) * cv_volume:GetFloat())
	Debug("bail hit (hl2): %s at %.2f", label, t)
	return true
end

-- Whether a bail plays Skate 3's own hits and slides (the setting, and the
-- tuning to do it with); HL2's otherwise.
local function DiscBails()
	return Disc() and cv_bails:GetString() ~= "hl2" and Tuning() ~= nil
end

local function BailReset()
	bail.regions = {}
	bail.hips = nil
	bail.quietUntil = nil
end

-- Hall of Meat's bone breaks: Skate 3's own HoM bank when it's there, else
-- HL2's cracks. `level` 1 is a fracture and 2 a break.
local function BoneBreak(region, level, pos, label)
	local mode = cv_bones:GetString()
	if mode == "off" then return end
	if mode == "auto" then mode = DiscBails() and "disc" or "hl2" end
	if mode == "disc" and Disc() then
		local m = HOM_OF[region.material]
		local rec = Material(m)
		local b = rec and rec.kind == 2 and rec.bands
		if b then
			local impact = level == 2 and b[2] or (b[3] + b[1]) / 2
			local tier, low, high = Band(m, impact)
			if tier ~= 3 and Collide(m, NO_MATERIAL, tier, Level(m, NO_MATERIAL, tier, low, high, impact), pos) then
				Debug("bone %s: %s, HoM material %d", level == 2 and "break" or "fracture", label, m)
				return
			end
		end
		Debug("bone %s: %s, no HoM sound installed, using HL2's", level == 2 and "break" or "fracture", label)
	end
	local list = HL2_BONES[level] or HL2_BONES[1]
	sound.Play(list[math.random(#list)], pos, 80, math.random(95, 105), (level == 2 and 1 or 0.7) * cv_volume:GetFloat())
end

-- The audio engine (native/skate-aems, a port of retail's): while it is up it
-- plays everything below, so this file goes quiet. Until it has loaded, and
-- when it can't start, this file's sounds play as before.
local retail = { tried = false, volume = nil, checkedAt = 0, cache = false, muted = false, row = nil, grind = nil, grindShown = nil }

local function Retail()
	if not skate3 or not skate3.AudioReady then return false end
	if not cv_retail:GetBool() then
		if retail.tried then
			skate3.AudioStop()
			retail.tried, retail.volume = false, nil
		end
		return false
	end
	if skate3.AudioReady() then
		local volume = cv_volume:GetFloat()
		if volume ~= retail.volume then
			retail.volume = volume
			skate3.AudioVolume(volume)
		end
		return true
	end
	if retail.tried then return false end
	-- Whether setup made the cache is a file lookup through every mounted
	-- addon: looked up every few seconds, not every frame.
	if CurTime() > retail.checkedAt then
		retail.checkedAt = CurTime() + 5
		retail.cache = file.Exists("skate3/audio-cache/manifest.json", "DATA")
	end
	if not retail.cache then
		if not retail.saidNoCache then
			retail.saidNoCache = true
			print("[skate3] retail audio: no cache at garrysmod/data/skate3/audio-cache (run setup again with the sound engine box ticked); using the mod's own sounds")
		end
		return false
	end
	retail.tried = true
	retail.volume = cv_volume:GetFloat()
	local ok, why = skate3.AudioStart("", retail.volume)
	if not ok then print("[skate3] retail audio: " .. tostring(why)) end
	return false
end


-- Where the sounds are, for the engine's placement and room. The speed sounds
-- ride on the listener; the board and the body are placed.
local DIRS_FLAT, DIRS_UP = {}, {}
for i = 0, 7 do
	local a = math.rad(i * 45)
	DIRS_FLAT[i + 1] = Vector(math.cos(a), math.sin(a), 0)
end
for i = 0, 3 do
	local a = math.rad(i * 90)
	DIRS_UP[i + 1] = Vector(math.cos(a) * 0.707, math.sin(a) * 0.707, 0.707)
end
local ROOM_REACH = 2000
local room = { at = 0, wet = 0, decay = 1, shownWet = 0 }

-- A guess at the room from a few traces: how closed in it is, and how far off
-- the walls are. Open ground comes to nothing, so outdoors sounds as it did.
local function RoomOf(origin)
	local far, count = 0, 0
	origin = origin + Vector(0, 0, 24)
	local function Ray(dir)
		local tr = util.TraceLine({ start = origin, endpos = origin + dir * ROOM_REACH, mask = MASK_SOLID_BRUSHONLY })
		if tr.Hit and not tr.HitSky then
			far = far + origin:Distance(tr.HitPos)
			count = count + 1
			return true
		end
		return false
	end
	local flat, up = 0, 0
	for _, d in ipairs(DIRS_FLAT) do if Ray(d) then flat = flat + 1 end end
	for _, d in ipairs(DIRS_UP) do if Ray(d) then up = up + 1 end end
	if Ray(Vector(0, 0, 1)) then up = up + 1 end
	-- Walls alone (a street) echo a little; a ceiling as well is a room.
	local closed = flat / #DIRS_FLAT * 0.4 + up / (#DIRS_UP + 1) * 0.6
	local mean = count > 0 and (far / count) / 39.37 or 30
	return closed * closed, math.Clamp(0.25 + mean * 0.12, 0.3, 3.5)
end

local function PlaceSounds(ent, pose, boardPos)
	if not skate3.AudioSpace then return end
	if not cv_3d:GetBool() then
		skate3.AudioSpace()
		skate3.AudioReverb(0, 1)
		return
	end
	local view = render and render.GetViewSetup and render.GetViewSetup()
	local origin = view and view.origin or EyePos()
	local right = (view and view.angles or EyeAngles()):Right()
	local board = boardPos or Vector(pose.pos[1], pose.pos[2], pose.pos[3])
	local body = Vector(pose.pos[1], pose.pos[2], pose.pos[3])
	skate3.AudioSpace(origin.x, origin.y, origin.z, right.x, right.y, right.z,
		board.x, board.y, board.z, body.x, body.y, body.z)
	local now = CurTime()
	if now >= room.at then
		room.at = now + 0.25
		room.targetWet, room.targetDecay = RoomOf(origin)
	end
	-- Ease toward the latest guess so walking through a door doesn't jump.
	local ease = math.min(1, FrameTime() * 3)
	room.wet = Lerp(ease, room.wet, room.targetWet or 0)
	room.decay = Lerp(ease, room.decay, room.targetDecay or 1)
	local scale = cv_reverb:GetFloat()
	skate3.AudioReverb(math.min(1, room.wet * 0.2 * scale), room.decay)
	if cv_debug:GetBool() and math.abs(room.wet - room.shownWet) > 0.1 then
		room.shownWet = room.wet
		Debug("room: closed %.2f, rings %.1f s; board %.1f m away", room.wet, room.decay, origin:Distance(board) / 39.37)
	end
end

concommand.Add("skate3_audio_status", function()
	if not skate3 or not skate3.AudioStatus then print("[skate3] no audio engine in this module") return end
	local status, sounding = skate3.AudioStatus()
	print("[skate3] retail audio: " .. status)
	print(string.format("[skate3] cache present: %s, skate3_retail_audio: %s, engine ready: %s",
		tostring(file.Exists("skate3/audio-cache/manifest.json", "DATA")), cv_retail:GetString(), tostring(skate3.AudioReady())))
	if sounding and sounding ~= "" then print(sounding) end
end)

concommand.Add("skate3_audio_restart", function()
	if not skate3 or not skate3.AudioStop then return end
	skate3.AudioStop()
	retail.tried, retail.volume, retail.checkedAt = false, nil, 0
end)

-- A body part hit something (the hook in cl_hall_of_meat.lua).
local function OnBodyHit(ev)
	if cv_pack:GetString() == "off" or not ev.pos then return end
	local region = REGION_OF[ev.part] or TORSO
	-- The audio engine plays the hits itself; the bone breaks are the mod's.
	if Retail() then
		if ev.injury then BoneBreak(region, ev.injury, ev.pos, ev.part) end
		return
	end
	if CurTime() ~= bail.voicesAt then
		bail.voicesAt, bail.voices = CurTime(), 0
	end
	local t = math.Clamp((ev.severity - HIT_SOFT) / (HIT_HARD - HIT_SOFT), 0, 1)
	-- The bail's opening thump already covers the first instant.
	local quiet = bail.quietUntil and CurTime() < bail.quietUntil
	if not quiet then
		local played
		if DiscBails() then
			-- What it hit, wall or floor, as the disc's material for it.
			local ground = MAT_ROWS[ev.matType] or 0
			played = BodyHit(region, Impact(region.material, ev.severity), ground, ev.pos, ev.part)
		end
		-- Nothing from the disc's side must not mean silence for a hit that scored.
		if not played and bail.voices < 4 then
			bail.voices = bail.voices + 1
			HitClassic(t, ev.pos, ev.part)
		end
	end
	if ev.injury then BoneBreak(region, ev.injury, ev.pos, ev.part) end
end

hook.Add("Skate3BodyHit", "skate3_sounds", OnBodyHit)

-- Each tick of a bail: the body sliding along the ground.
local function Bail(pose, dt, volume, ent, classic)
	local hips = BonePos(pose, "HIPS")
	local sliding = 0
	if hips and bail.hips and dt > 0 then
		local tr = util.TraceLine({ start = hips, endpos = hips - Vector(0, 0, 14), filter = ent, mask = MASK_SOLID })
		if tr.Hit then
			local v = (hips - bail.hips) / dt / UNITS
			sliding = Vector(v.x, v.y, 0):Length()
		end
	end
	bail.hips = hips
	if classic then return end
	if not picks.bodyslide then Pick("bodyslide", "bodyslide") end
	Hold("bodyslide", ent, sliding > 1, math.Clamp(sliding / 8, 0, 0.7) * volume, math.Clamp(85 + sliding * 3, 85, 120))
end

---------------------------------------------------------------------------
-- The score multiplier going up. Retail plays its interface sounds from the
-- front-end ("fe") records, each naming a sound in the sk8_menu bank; setup
-- installs the bank as sound/skate3/menu and the records' names, ids and
-- levels in sounds.json ("frontend": name -> { id, level }).
--
-- Retail's HUD posts the events "multiplyer_2" and "multiplyer_3" (sic) when
-- the multiplier it shows becomes 2 or 3 (setup finds their records by the
-- hash of the name). A record named like a multiplier is the fallback, and
-- skate3_menu_names and skate3_sound_scan menu list what's there.
---------------------------------------------------------------------------

-- [multiplier] = the front-end record that plays when it's reached; a record
-- for the highest one serves above it.
local MULTIPLIER = { [2] = "multiplyer_2", [3] = "multiplyer_3" }

local function Frontend()
	local m = Manifest()
	return m and m.frontend
end

-- Whether the record `name` looks like the chime for multiplier `n`: "mult"
-- in its name, and n as a number of its own in it.
local function Looks(name, n)
	name = name:lower()
	if not name:find("mult", 1, true) or name:find("player", 1, true) or name:find("online", 1, true) then return false end
	return (" " .. name:gsub("%D+", " ") .. " "):find(" " .. n .. " ", 1, true) ~= nil
end

local menuFor = {}
-- The record (name, id, level) for multiplier `n`; nil when there's none.
local function MenuRecord(n)
	local fe = Frontend()
	if not fe then return end
	if menuFor[n] == nil then
		local found = MULTIPLIER[n]
		if found and not fe[found] then found = nil end
		if not found then
			local names = table.GetKeys(fe)
			table.sort(names)
			for _, name in ipairs(names) do
				if Looks(name, n) then
					found = name
					break
				end
			end
		end
		menuFor[n] = found or false
	end
	local name = menuFor[n]
	local record = name and fe[name]
	if record then return name, record[1], record[2] end
end

local multiplierSeen = 1

local function MultiplierSound(n)
	if cv_mult:GetFloat() <= 0 then return end
	local ent = LocalPlayer()
	local volume = cv_volume:GetFloat()
	if Disc() then
		-- A record for the highest multiplier serves the ones above it.
		for k = n, 2, -1 do
			local name, id, level = MenuRecord(k)
			if name and PlayId("menu", id, ent, 0.5, math.Clamp(level or 1, 0, 1), 1, nil, true, 0) then
				Debug("multiplier x%d: %s", n, name)
				return
			end
		end
		Debug("multiplier x%d: no front-end record found, using HL2's", n)
	end
	ent:EmitSound(HL2_MULTIPLIER, 0, math.Clamp(100 + (n - 2) * 15, 60, 200), 0.6 * volume)
end

-- One of Skate 3's interface sounds by its front-end record's name (the
-- session marker's "cellphone_goto_marker", say). False when the disc's
-- sounds aren't in use or the record isn't installed, so the caller can play
-- something else. Sounds are off: true, nothing to play.
function Sounds.Frontend(name)
	if cv_pack:GetString() == "off" then return true end
	local ent = LocalPlayer()
	if not IsValid(ent) or not Disc() then return false end
	local fe = Frontend()
	local record = fe and fe[name]
	if not record then
		Debug("front-end record %s isn't installed", name)
		return false
	end
	if not PlayId("menu", record[1], ent, 0.5, math.Clamp(record[2] or 1, 0, 1), 1, nil, true, 0) then return false end
	Debug("front-end %s: menu id %d", name, record[1])
	return true
end

-- Each frame: a bigger multiplier than the last frame's is a chime. A line
-- over, or a bail, starts it again from x1.
local function Multiplier(pose, kind)
	local sc = pose.score
	local n = 1
	if sc and kind ~= "bail" and (sc.active or (sc.timer or 0) > 0) then
		n = math.floor((sc.multiplier or 1) + 0.001)
	end
	if n > multiplierSeen and n >= 2 then MultiplierSound(n) end
	multiplierSeen = n
end

---------------------------------------------------------------------------
-- Finding sounds by ear: the ids setup installed in a folder, for naming the
-- ones this file doesn't know yet.
---------------------------------------------------------------------------

local function InstalledIds(folder)
	local m = Manifest()
	local ids = m and m.ids and m.ids[folder]
	local out = {}
	for id in pairs(ids or {}) do out[#out + 1] = tonumber(id) end
	table.sort(out)
	return out
end

concommand.Add("skate3_sound_play", function(_, _, args)
	local folder, id = args[1], tonumber(args[2])
	if not folder or not id then return print("[skate3] skate3_sound_play <folder> <id>, e.g. skate3_sound_play menu 235") end
	local ent = LocalPlayer()
	print(PlayId(folder, id, ent, 0.5, 1, 1, nil, true, 0) and ("[skate3] played " .. folder .. " " .. id)
		or ("[skate3] " .. folder .. " has no sound " .. id))
end, nil, "Play a sound id installed in sound/skate3/<folder>")

-- Plays every id in a folder, one every two seconds, saying which as it goes.
concommand.Add("skate3_sound_scan", function(_, _, args)
	local folder = args[1]
	local ids = folder and InstalledIds(folder) or {}
	if #ids == 0 then return print("[skate3] skate3_sound_scan <folder> [from] [to]: nothing installed in " .. tostring(folder)) end
	local from, to = tonumber(args[2]) or ids[1], tonumber(args[3]) or ids[#ids]
	local list = {}
	for _, id in ipairs(ids) do
		if id >= from and id <= to then list[#list + 1] = id end
	end
	print(string.format("[skate3] playing %d sounds from %s, %s to %s", #list, folder, from, to))
	timer.Remove("skate3_sound_scan")
	local i = 0
	timer.Create("skate3_sound_scan", 2, #list, function()
		i = i + 1
		print(string.format("[skate3] %s %d", folder, list[i]))
		PlayId(folder, list[i], LocalPlayer(), 0.5, 1, 1, nil, true, 0)
	end)
end, nil, "Play the sound ids of a folder one by one")

concommand.Add("skate3_sound_scan_stop", function() timer.Remove("skate3_sound_scan") end)

concommand.Add("skate3_menu_names", function(_, _, args)
	local fe = Frontend()
	if not fe then return print("[skate3] no front-end records installed: run setup again with your disc") end
	local filter = args[1] and args[1]:lower()
	local names = table.GetKeys(fe)
	table.sort(names)
	local shown = 0
	for _, name in ipairs(names) do
		if not filter or name:lower():find(filter, 1, true) then
			print(string.format("[skate3] %-40s menu id %d  level %.2f", name, fe[name][1], fe[name][2]))
			shown = shown + 1
		end
	end
	print(string.format("[skate3] %d of %d front-end records", shown, #names))
end, nil, "List the front-end sound records, optionally only names containing a word")

---------------------------------------------------------------------------

local lastTick, wasDisc

---------------------------------------------------------------------------
-- Seams (retail Class_Seams, seams.rs): a wheel crossing a joint in the
-- ground clicks. Retail reads each surface's joint grid from the map (and
-- SK8V from the ground's own texture); Source maps have none, so the joints
-- here lie on a world grid whose spacing goes by the surface: slabs on
-- concrete, small units on brick and stone, planks on wood. Each of the four
-- wheels counts the cells it enters; two wheels at once is the louder click.
-- Which of Seams_Bank's sounds is which isn't written down, so any is taken.
---------------------------------------------------------------------------

-- Metres between joints, by Skate 3 material.
local SEAM_SPACING = { [2] = 1.4, [3] = 0.6, [6] = 0.3 }
-- The wheels' places on the board: m along its heading, m across.
local SEAM_WHEELS = { { 0.19, 0.07 }, { 0.19, -0.07 }, { -0.19, 0.07 }, { -0.19, -0.07 } }
local SEAM_GAP = 0.05 -- s between clicks
local seamCells, seamFiles, nextSeam = {}, nil, 0

local function Seams(ent, pose, kind, speed, volume)
	if not cv_seams:GetBool() or kind ~= "ground" or speed < 0.8 or not pose.pos or not pose.forward then
		seamCells = {}
		return
	end
	Ground(ent)
	local spacing = SEAM_SPACING[groundRow]
	if not spacing then
		seamCells = {}
		return
	end
	if seamFiles == nil then seamFiles = file.Find("sound/skate3/seams/*.wav", "GAME") or {} end
	if #seamFiles == 0 then return end
	spacing = spacing * UNITS
	local fx, fy = pose.forward[1], pose.forward[2]
	local length = math.sqrt(fx * fx + fy * fy)
	if length < 0.1 then return end
	fx, fy = fx / length, fy / length
	local crossed = 0
	for i, w in ipairs(SEAM_WHEELS) do
		local x = pose.pos[1] + (fx * w[1] + fy * w[2]) * UNITS
		local y = pose.pos[2] + (fy * w[1] - fx * w[2]) * UNITS
		local cx, cy = math.floor(x / spacing), math.floor(y / spacing)
		local cell = seamCells[i]
		if not cell then
			seamCells[i] = { cx, cy }
		else
			if cell[1] ~= cx or cell[2] ~= cy then crossed = crossed + 1 end
			cell[1], cell[2] = cx, cy
		end
	end
	if crossed == 0 or CurTime() < nextSeam then return end
	nextSeam = CurTime() + SEAM_GAP
	local gain = math.Clamp(speed / 8, 0.15, 1) * (crossed > 1 and 0.4 or 0.3) * volume
	ent:EmitSound("skate3/seams/" .. seamFiles[math.random(#seamFiles)], 65, math.random(95, 105), gain)
end

-- Called every frame while skating, with the latest pose.
function Sounds.Update(ent, pose, boardPos)
	if not IsValid(ent) or not pose or cv_pack:GetString() == "off" then return Sounds.Stop() end
	if Retail() then
		if not retail.muted then
			retail.muted = true
			Sounds.Stop()
		end
		PlaceSounds(ent, pose, boardPos)
		-- The material under the board, from Source's surface property.
		Ground(ent)
		if groundRow ~= retail.row then
			retail.row = groundRow
			skate3.AudioGround(groundRow)
		end
		-- What is being ground is what the board rests on, not the floor
		-- under it: a short trace down from the board finds the rail or ledge
		-- itself, every frame of the grind.
		local grindRow
		if Kind(pose.state) == "grind" then
			local pos = ent:GetPos()
			local tr = util.TraceLine({ start = pos + Vector(0, 0, 6), endpos = pos - Vector(0, 0, 14), filter = ent })
			if tr.Hit then grindRow = RowOf(tr) end
			if cv_debug:GetBool() and grindRow ~= retail.grindShown then
				Debug("grind: property '%s' -> Skate 3 material %s (ground %d)", lastProp, tostring(grindRow), groundRow)
			end
		end
		if grindRow ~= retail.grind then
			retail.grind = grindRow
			skate3.AudioGrind(grindRow or -1)
		end
		retail.grindShown = grindRow
		return
	end
	retail.muted = false
	local kind = Kind(pose.state)
	local volume = cv_volume:GetFloat()
	-- m/s: a brisk push is about 4, flat out about 10.
	local speed = pose.speed or 0
	local disc = Disc()
	if disc ~= wasDisc then
		-- Switching sets: let every loop pick its sound again.
		wasDisc = disc
		for _, s in pairs(loops) do s.patch:Stop() end
		loops, picks = {}, {}
	end
	local bails = disc and DiscBails()

	-- Bones move once per simulation tick; frames between ticks repeat them.
	local tick = pose.tick
	local dt = tick and lastTick and tick > lastTick and (tick - lastTick) * TICK or 0
	local newTick = not tick or tick ~= lastTick
	lastTick = tick

	if last and kind ~= last then
		if kind == "air" and (last == "ground" or last == "grind") then
			-- Rough ground flickers in and out of the air; only a takeoff
			-- after a moment on the ground pops. Retail doesn't pop when the
			-- jump is off a grind.
			if CurTime() - landedAt > BUMP * 2 then
				if not disc then
					Play("pop", ent, 0.8)
				elseif last == "ground" and not Pop(ent, speed) then
					Play("pop", ent, 0.8)
				end
			end
			airStart = CurTime()
		elseif (kind == "ground" or kind == "grind") and last == "air" then
			landedAt = CurTime()
			local air = airStart and CurTime() - airStart or 0
			if airVelocity and pose.velocity then
				local v = pose.velocity
				local dx, dy, dz = v[1] - airVelocity[1], v[2] - airVelocity[2], v[3] - airVelocity[3]
				landingLevel = math.Clamp(math.sqrt(dx * dx + dy * dy + dz * dz) / UNITS / LANDING_FULL, 0, 1)
			end
			-- Dropping onto a rail is the grind's hit, not a landing.
			local hit = disc and (kind == "grind" and GrindHit(ent, speed, air) or kind == "ground" and Land(ent, air))
			if not hit and (kind == "grind" or air >= BUMP) then Play("land", ent, math.Clamp(0.5 + speed / 20, 0.5, 1)) end
		elseif kind == "grind" and disc then
			GrindHit(ent, speed)
		elseif kind == "bail" then
			BailReset()
			-- With HL2's bails, the fall itself thumps, and the first hits
			-- are part of it; each bump after plays as the body hits things.
			if not bails then
				Play("bail", ent, 1)
				bail.quietUntil = CurTime() + 0.1
			end
		end
		if kind == "grind" then Pick("grind", "grinds") end
	end
	if kind ~= "air" then airStart = nil end
	-- The velocity going into a landing: the last frame in the air.
	if kind == "air" and pose.velocity then
		airVelocity = airVelocity or {}
		airVelocity[1], airVelocity[2], airVelocity[3] = pose.velocity[1], pose.velocity[2], pose.velocity[3]
	end
	last = kind

	local boardPos = pose.pos and Vector(pose.pos[1], pose.pos[2], pose.pos[3]) or ent:GetPos()
	local onBoard = kind == "ground" or kind == "grind" or kind == "air"
	local sliding = pose.state == "SlideGround" or pose.state == "RevertGround"

	if disc then
		Ground(ent)
		local aems = AemsGround()
		RollBands(ent, kind == "ground" and speed > 0.3 and not aems, speed, volume)
		AemsRoll(ent, kind == "ground" and speed > 0.3 and aems, speed, volume)
		Seams(ent, pose, kind, speed, volume)
		if loops.roll and loops.roll.on then
			loops.roll.patch:Stop()
			loops.roll.on = false
		end
		-- The trucks' rattle rides on top of the surface, louder with speed.
		if not picks.rattle then Pick("rattle", "rattles") end
		Hold("rattle", ent, kind == "ground" and speed > 0.5, math.Clamp(speed / 12, 0, 0.45) * volume)
		-- Powerslides and reverts: the wheels skidding.
		if not picks.skid then Pick("skid", "skids") end
		Hold("skid", ent, sliding and speed > 1, math.Clamp(speed / 8, 0, 0.6) * volume, math.Clamp(85 + speed * 3, 85, 120))
		-- The wind at speed (retail's sense of speed starts around 1 m/s and
		-- is full by flat out).
		if not picks.wind then Pick("wind", "wind") end
		Hold("wind", ent, onBoard and speed > 4, math.Clamp((speed - 4) / 8, 0, 0.35) * volume)
		-- The wheels spinning free: in the air on the board, or in your hands
		-- after stepping off it.
		local trigger
		if kind == "air" then
			trigger = "air"
		elseif kind == "foot" then
			trigger = "hand"
		end
		-- Keep the speed the board had when it left the ground or your feet.
		if onBoard then spin.speed = speed end
		Spin(trigger, spin.speed or speed, boardPos, volume)
	else
		RollBands(ent, false, speed, volume)
		RollClassic(ent, kind == "ground" and speed > 0.3, speed, volume)
		Hold("rattle", ent, false, 0)
		Hold("skid", ent, false, 0)
		Hold("wind", ent, false, 0)
		Spin(nil, 0, boardPos, volume)
	end

	if newTick and dt > 0 then
		Feet(pose, kind, dt, disc, volume)
		if kind == "bail" then
			Bail(pose, dt, volume, ent, not bails)
		end
	end
	if kind ~= "bail" or not bails then Hold("bodyslide", ent, false, 0) end
	Multiplier(pose, kind)

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
	if aemsRoll.patch then
		aemsRoll.patch:Stop()
		aemsRoll.patch = nil
	end
	spin.trigger = nil
	SpinStop()
	feet = { {}, {} }
	body = {}
	BailReset()
	multiplierSeen = 1
	last, lastTick = nil, nil
end

-- sounds.json is big (every sound id of the banks), and reading it was done in
-- the first frame of riding, a visible hitch the first time the board came
-- out. Read it a few seconds after the map is up instead, while nobody's
-- riding yet.
timer.Simple(8, function()
	if cv_pack:GetString() ~= "off" and Sounds.HasDisc() then Manifest() end
end)

-- Garry's Mod's own footsteps for a skater: the simulation moves them, so
-- the walk animation other players see would step in place. Ours play
-- instead (the server's copy of this hook is in sv_skate3.lua).
hook.Add("PlayerFootstep", "skate3_quiet", function(ply)
	if ply:GetNW2Bool("skate3_riding") then return true end
end)

return Sounds
