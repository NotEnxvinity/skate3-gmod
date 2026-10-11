-- Skate sounds, driven by the skater's state each frame: rolling, grinding and
-- sliding loops that follow speed, one-shots for pops and landings, the
-- wheels spinning down, footsteps, and bails.
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

local cv_volume = CreateClientConVar("skate3_volume", "1", true, false, "Skate sound volume, 0 to 1", 0, 1)
local cv_pack = CreateClientConVar("skate3_sounds", "disc", true, false,
	"Skate sounds: hl2 (the classic Half-Life 2 ones), disc (Skate 3's own, installed by setup) or off")
local cv_bails = CreateClientConVar("skate3_bail_sounds", "hl2", true, false,
	"Bail sounds with the disc set: disc (Skate 3's own body hits and slides) or hl2 (Half-Life 2's)")
local cv_steps = CreateClientConVar("skate3_footsteps", "hl2", true, false,
	"Footsteps with the disc set: disc (Skate 3's own) or hl2 (Garry's Mod's own for the ground underfoot)")
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

-- The kind of ground each rolling recording stands for, as setup names the
-- disc's materials (audio_tuning.py ROLLING): picks a material's collision
-- and footstep sounds.
local GROUND = {
	wood_ramp_hard = "wood",
	metal_smooth_hard = "metal",
	concrete_smooth_hard = "concrete_smooth",
	concrete_smooth_soft = "concrete_smooth",
	asphalt_rough_hard = "asphalt_rough",
	asphalt_smooth_hard = "asphalt_smooth",
}

function Sounds.HasDisc()
	return file.Exists("sound/skate3/index.txt", "GAME")
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

-- The rolling recording for the surface under `pos`, and the trace.
local function Surface(pos, filter)
	local tr = util.TraceLine({ start = pos + Vector(0, 0, 8), endpos = pos - Vector(0, 0, 40), filter = filter })
	local name = tr.Hit and ROLL[tr.MatType] or ROLL_DEFAULT
	return Installed(name) and name or ROLL_DEFAULT, tr
end

local ground, nextTrace = ROLL_DEFAULT, 0

-- The surface under the board, checked a few times a second.
local function Ground(ent)
	if CurTime() >= nextTrace then
		nextTrace = CurTime() + 0.25
		ground = Surface(ent:GetPos(), ent)
	end
	return ground
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

-- One take of a retail sound id from a bank folder: one of its alternatives,
-- and in it one of the groups (a record's groups are the same hit at rising
-- strength, so `strength`, 0 to 1, picks one). Played at `pos` when given,
-- else on `ent`. False when setup didn't install it.
local function PlayId(folder, id, ent, strength, volume, pitch, pos)
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
	local level = math.Clamp(member[2], 0, 1) * (volume or (0.3 + 0.5 * strength)) * cv_volume:GetFloat()
	pitch = math.Clamp(math.floor((pitch or 1) * math.random(97, 103)), 30, 250)
	if pos then
		sound.Play(path, pos, 70, pitch, level)
	else
		ent:EmitSound(path, 70, pitch, level)
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

local airStart
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
	if not file.Exists("sound/" .. path, "GAME") then path = SPINS[spin.toggle and 1 or 2] end
	spin.toggle = not spin.toggle
	if not file.Exists("sound/" .. path, "GAME") then return end
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
local function GroundMaterial(name)
	local t = Tuning()
	return t and t.grounds and t.grounds[GROUND[name] or ""]
end

-- AudioSurfaceMap entry of a material, as setup exports it: { rolling,
-- footstep surface, collision class }; materials 94 and up share entry 94.
local function SurfaceEntry(m)
	local t = Tuning()
	local s = t and t.surfaces
	if not s or not m then return end
	return s[math.min(m, 94) + 1] or s[#s]
end

local function FootstepSurface(name)
	local e = SurfaceEntry(GroundMaterial(name))
	local s = e and e[2] or 1
	return (s >= 1 and s <= 7) and s or 1
end

local function Step(foot, pos, comSpeed, uneven, surfaceName)
	local run = comSpeed > RUN_SPEED and 2 or 1
	local surface = FootstepSurface(surfaceName)
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
			local name, tr = Surface(toe, LocalPlayer())
			local height = tr.Hit and toe.z - tr.HitPos.z or math.huge
			down = height < FOOT_GROUND and speed < FOOT_STILL
			if down and not state.down then
				-- Retail's step code: a foot planted more than 7 cm above the
				-- other's last plant is an uneven step.
				local other = feet[3 - i].plantZ
				local uneven = other and (toe.z - other) / UNITS > STEP_HEIGHT or false
				state.plantZ = toe.z
				if disc then
					Step(i, toe, comSpeed, uneven, name)
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
-- collision.rs). Each body region that hits something is a collision between
-- its material and the ground's: an impact sets a tier from the material's
-- bands, a level from its windows, and each side plays the sample its
-- AudioSurface record names for that tier and the other side's class. The
-- clothes and pads add their own contacts. While the body slides along the
-- ground, Bodyslide loops.
---------------------------------------------------------------------------

local NO_MATERIAL = 143
-- Region: bones, then retail's material, cloth contact and pad contact
-- (contacts.rs body_materials); `mass` is the region's share of the body,
-- which scales its impact as retail's part weights do.
local REGIONS = {
	{ bone = "HEAD", material = 97, pad = 110, mass = 0.08, reach = 6 },
	{ bone = "SPINE1", material = 98, cloth = 109, pad = 110, mass = 0.45, reach = 8 },
	{ bone = "LEFTFOREARM", material = 100, cloth = 107, pad = 111, mass = 0.05, reach = 4 },
	{ bone = "RIGHTFOREARM", material = 100, cloth = 107, pad = 111, mass = 0.05, reach = 4 },
	{ bone = "LEFTLEG", material = 99, cloth = 108, pad = 111, mass = 0.12, reach = 4 },
	{ bone = "RIGHTLEG", material = 99, cloth = 108, pad = 111, mass = 0.12, reach = 4 },
}
-- The pad contacts' thresholds (contacts.rs ContactsTuning defaults): 110 on
-- the head and torso, 111 on the limbs.
local PAD_110 = { [97] = { 0.75, 1.25 }, [98] = { 0.7, 1.25 } }
local PAD_111 = { 0.65, 1.25 }
-- The bridge's speed graph on the impacts: x m/s of the body, y the factor.
local BODY_SPEED = {
	{ 0, 0.3664, 0.4479, 0.5212, 0.5928, 0.7410, 0.8632, 0.9463 },
	{ 1.0, 1.2, 1.4857, 1.9143, 2.4286, 3.6, 4.5714, 5.0 },
}
-- Frames of retail's per-region cooldown.
local BODY_COOLDOWN = 15
-- Collision class (0..2) of materials 95..113; false: AudioSurfaceMap entry 94.
local CLASS_95 = { 1, 2, 1, 0, 1, 1, 1, 1, 0, 1, 1, 1, 0, 0, 0, false, false, false, 1 }
local BANKS = { [0] = "collisions", [1] = "metal" }
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
local bail = { regions = {}, voices = 0 }

local function Collide(m, other, tier, level, pos)
	if m < 0 or m >= NO_MATERIAL or tier == 3 or bail.voices >= VOICES then return false end
	local rec = Material(m)
	if not rec or not rec.ids or not BANKS[rec.kind] then return false end
	local class = other == NO_MATERIAL and 0 or Class(other)
	local id = tier == 2 and rec.ids[1] or tier == 0 and rec.ids[2 + class] or rec.ids[5 + class]
	if not id or id < 0 then return false end
	local volume = math.Clamp(level / 32767, 0, 1) * (rec.gain or 32767) / 32767
	if volume < 0.01 then return false end
	local played = PlayId(BANKS[rec.kind], id, LocalPlayer(), tier / 2, volume, (rec.pitch or 4096) / 4096, pos)
	if played then bail.voices = bail.voices + 1 end
	return played
end

-- One region's hit at `impact` against ground material `b`: retail's pair,
-- the second hit of a hard one, the clothes and the pad.
local function BodyHit(r, impact, b, pos)
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
	Debug("bail hit: %s at %.2f, tiers %d/%d against material %d%s", r.bone, impact, ta, tb, b,
		played and "" or " (no sound)")
	return played
end

-- HL2's version of a bail hit: a body impact, harder and louder the harder
-- the region hit, each region on its own cooldown so every bump sounds. Hits
-- closer together than CLASSIC_GAP play as one.
local CLASSIC_MIN = 0.03
local CLASSIC_GAP = 0.12
local function HitClassic(r, impact, pos)
	if impact < CLASSIC_MIN or CurTime() - (bail.lastClassic or 0) < CLASSIC_GAP then return false end
	bail.lastClassic = CurTime()
	local list = impact > 0.25 and HL2_HITS.hard or HL2_HITS.soft
	sound.Play(list[math.random(#list)], pos, 75, math.random(95, 105),
		math.Clamp(0.35 + impact, 0.35, 1) * cv_volume:GetFloat())
	Debug("bail hit (hl2): %s at %.2f", r.bone, impact)
	return true
end

local function BailReset()
	bail.regions = {}
	bail.comSpeed = 0
end

-- Each tick of a bail: a region whose velocity into a surface it is touching
-- dropped is a hit, its impact retail's clamp01(dv . n x weight x 10) scaled
-- by the speed graph at the body's speed.
local function Bail(pose, dt, volume, ent, classic)
	local t = not classic and Tuning()
	local cooldown = t and t.body_cooldown or BODY_COOLDOWN
	local graph = t and t.body_speed or BODY_SPEED
	local hips = BonePos(pose, "HIPS")
	local scale = Graph(graph, bail.comSpeed or 0)
	local hits = 0
	bail.voices = 0
	for i, r in ipairs(REGIONS) do
		local s = bail.regions[i] or {}
		bail.regions[i] = s
		local pos = BonePos(pose, r.bone)
		if pos and s.pos and dt > 0 then
			local v = (pos - s.pos) / dt / UNITS
			if s.v and (s.cooldown or 0) <= 0 then
				-- Touching something in the direction it was moving?
				local dir = s.v:GetNormalized()
				local tr = util.TraceLine({ start = s.pos, endpos = pos + dir * r.reach, filter = ent, mask = MASK_SOLID })
				if tr.Hit then
					local n = tr.HitNormal
					local into = math.max(0, -s.v:Dot(n)) - math.max(0, -v:Dot(n))
					local impact = math.Clamp(into * r.mass * 10, 0, 1) * scale
					if impact > 0.001 then
						local played
						if classic then
							played = HitClassic(r, impact, tr.HitPos)
						else
							-- What it hit, wall or floor, as the disc's material for it.
							local b = GroundMaterial(ROLL[tr.MatType] or ROLL_DEFAULT) or NO_MATERIAL
							played = BodyHit(r, impact, b, tr.HitPos)
						end
						if played then
							s.cooldown = cooldown
							hits = hits + 1
						end
					end
				end
			end
			s.v = v
		end
		s.pos = pos
		if s.cooldown and s.cooldown > 0 then s.cooldown = s.cooldown - 1 end
	end
	if hips and bail.hips and dt > 0 then
		bail.comSpeed = (hips - bail.hips):Length() / dt / UNITS
	end
	-- The body sliding along the ground.
	local sliding = 0
	if hips and bail.hips and dt > 0 then
		local tr = util.TraceLine({ start = hips, endpos = hips - Vector(0, 0, 14), filter = ent, mask = MASK_SOLID })
		if tr.Hit then
			local v = (hips - bail.hips) / dt / UNITS
			sliding = Vector(v.x, v.y, 0):Length()
		end
	end
	bail.hips = hips
	if classic then return hits end
	if not picks.bodyslide then Pick("bodyslide", "bodyslide") end
	Hold("bodyslide", ent, sliding > 1, math.Clamp(sliding / 8, 0, 0.7) * volume, math.Clamp(85 + sliding * 3, 85, 120))
	return hits
end

---------------------------------------------------------------------------

local lastTick, wasDisc

-- Called every frame while skating, with the latest pose.
function Sounds.Update(ent, pose)
	if not IsValid(ent) or not pose or cv_pack:GetString() == "off" then return Sounds.Stop() end
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
	local bails = disc and cv_bails:GetString() ~= "hl2" and Tuning() ~= nil

	-- Bones move once per simulation tick; frames between ticks repeat them.
	local tick = pose.tick
	local dt = tick and lastTick and tick > lastTick and (tick - lastTick) * TICK or 0
	local newTick = not tick or tick ~= lastTick
	lastTick = tick

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
			BailReset()
			-- With HL2's bails, the fall itself thumps; each bump after it
			-- plays as the body hits things.
			if not bails then
				Play("bail", ent, 1)
				bail.lastClassic = CurTime()
			end
		end
		if kind == "grind" then Pick("grind", "grinds") end
	end
	if kind ~= "air" then airStart = nil end
	last = kind

	local boardPos = pose.pos and Vector(pose.pos[1], pose.pos[2], pose.pos[3]) or ent:GetPos()
	local onBoard = kind == "ground" or kind == "grind" or kind == "air"
	local sliding = pose.state == "SlideGround" or pose.state == "RevertGround"

	if disc then
		RollBands(ent, kind == "ground" and speed > 0.3, speed, volume)
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
	spin.trigger = nil
	SpinStop()
	feet = { {}, {} }
	body = {}
	BailReset()
	last, lastTick = nil, nil
end

-- Garry's Mod's own footsteps for a skater: the simulation moves them, so
-- the walk animation other players see would step in place. Ours play
-- instead (the server's copy of this hook is in sv_skate3.lua).
hook.Add("PlayerFootstep", "skate3_quiet", function(ply)
	if ply:GetNW2Bool("skate3_riding") then return true end
end)

return Sounds
