-- Spawning Skate 3 park pieces and skateparks, and keeping them frozen in
-- place.

local Park = include("skate3/sh_park.lua")

local INCHES = 39.3701

-- Makes one piece, or nothing if it can't be.
local function Create(id, pos, ang)
	local ent = ents.Create("skate3_piece")
	if not IsValid(ent) then return end
	ent:SetPieceId(id)
	ent:SetPos(pos)
	ent:SetAngles(ang)
	ent:Spawn()
	if not IsValid(ent) then return end
	return ent
end

-- Places one piece for a player, with undo and the props limit. Returns the
-- piece, or nil (after telling the player why).
function Park.Spawn(ply, id, pos, ang)
	local index = Park.Index()
	local info = index and index[id]
	if not info then
		ply:ChatPrint("[skate3] No park piece " .. tostring(id) .. ". Run the setup app to convert them from your disc.")
		return
	end
	if info.tiles then
		ply:ChatPrint("[skate3] " .. info.name .. " is a whole skatepark: use its Load or Build here button in the Skate 3 tab.")
		return
	end
	if not ply:CheckLimit("props") then return end
	local ent = Create(id, pos, ang)
	if not ent then return end
	ent:SetCreator(ply)
	undo.Create("Skate 3 park piece")
	undo.AddEntity(ent)
	undo.SetPlayer(ply)
	undo.SetCustomUndoText("Undone " .. info.name)
	undo.Finish()
	ply:AddCleanup("props", ent)
	ply:AddCount("props", ent)
	return ent
end

concommand.Add("skate3_spawn_piece", function(ply, _, args)
	if not IsValid(ply) then return end
	local tr = util.TraceLine({
		start = ply:EyePos(),
		endpos = ply:EyePos() + ply:GetAimVector() * 4096,
		filter = ply,
	})
	Park.Spawn(ply, args[1], tr.HitPos, Angle(0, math.Round(ply:EyeAngles().y / 15) * 15 + 180, 0))
end)

concommand.Add("skate3_spawn_preset", function(ply, _, args)
	if not IsValid(ply) then return end
	local preset = Park.Presets[args[1] or ""]
	local index = Park.Index()
	if not preset or not index then
		ply:ChatPrint("[skate3] No park pieces yet. Run the setup app to convert them from your disc.")
		return
	end
	for _, p in ipairs(preset.pieces) do
		if not index[p[1]] then
			ply:ChatPrint("[skate3] This preset needs a piece your converted data doesn't have; run the setup app again.")
			return
		end
	end
	-- It starts just ahead of the player and runs away from them, on the ground.
	local yaw = math.Round(ply:EyeAngles().y / 15) * 15
	local forward = Angle(0, yaw, 0):Forward()
	local start = ply:GetPos() + forward * 14 * INCHES
	local ground = util.TraceLine({ start = start + Vector(0, 0, 64), endpos = start - Vector(0, 0, 4096), filter = ply })
	local origin = ground.HitPos
	-- Pieces run along their own -x, so the preset faces the other way round.
	local rot = Angle(0, yaw + 180, 0)
	undo.Create("Skate 3 " .. preset.name)
	for _, p in ipairs(preset.pieces) do
		local offset = Vector(p[2], p[3] + 6, p[4]) * INCHES
		offset:Rotate(rot)
		local ent = Create(p[1], origin + offset, rot)
		if ent then
			ent:SetCreator(ply)
			undo.AddEntity(ent)
			ply:AddCleanup("props", ent)
		end
	end
	undo.SetPlayer(ply)
	undo.SetCustomUndoText("Undone " .. preset.name)
	undo.Finish()
end)

-- Saves and dupes bring pieces back with their piece and still frozen.
duplicator.RegisterEntityClass("skate3_piece", function(ply, data)
	local ent = ents.Create("skate3_piece")
	if not IsValid(ent) then return end
	duplicator.DoGeneric(ent, data)
	if data.DT then ent:RestoreNetworkVars(data.DT) end
	ent:Spawn()
	ent:Activate()
	if IsValid(ply) then ply:AddCleanup("props", ent) end
	return ent
end, "Data")

-- The physgun moves pieces, but letting go never leaves one loose, and a
-- locked piece (physgun reload) stays put. A park's tiles belong together,
-- so they aren't picked up one by one.
hook.Add("PhysgunPickup", "skate3_park", function(_, ent)
	if IsValid(ent) and ent:GetClass() == "skate3_piece" and (ent:GetLocked() or ent:IsTile()) then return false end
end)

hook.Add("OnPhysgunPickup", "skate3_park_freeze", function(_, ent)
	if IsValid(ent) and ent:GetClass() == "skate3_piece" then ent.held = true end
end)

hook.Add("PhysgunDrop", "skate3_park_freeze", function(_, ent)
	if IsValid(ent) and ent:GetClass() == "skate3_piece" then
		local phys = ent:GetPhysicsObject()
		if IsValid(phys) then
			phys:EnableMotion(false)
			phys:Sleep()
		end
		ent.held = nil
		ent.home = { ent:GetPos(), ent:GetAngles() }
	end
end)

-- Physgun reload on a piece locks it in place, or lets it be moved again.
hook.Add("OnPhysgunReload", "skate3_park_lock", function(_, ply)
	local ent = ply:GetEyeTrace().Entity
	if not IsValid(ent) or ent:GetClass() ~= "skate3_piece" or ent:IsTile() then return end
	local creator = ent:GetCreator()
	if IsValid(creator) and creator ~= ply and not ply:IsAdmin() then return false end
	ent:SetLocked(not ent:GetLocked())
	ply:ChatPrint(ent:GetLocked() and "[skate3] Piece locked in place. Reload again to move it." or "[skate3] Piece unlocked.")
	ent:EmitSound(ent:GetLocked() and "buttons/button3.wav" or "buttons/button9.wav", 60)
	return false
end)

hook.Add("GravGunPickupAllowed", "skate3_park_freeze", function(_, ent)
	if IsValid(ent) and ent:GetClass() == "skate3_piece" then return false end
end)

hook.Add("CanPlayerUnfreeze", "skate3_park_freeze", function(_, ent)
	if IsValid(ent) and ent:GetClass() == "skate3_piece" then return false end
end)

-- Skateparks: picking one of the disc's skateparks loads an open map, builds
-- the park on it (as tiles, a few per tick) and drops everyone on it. Which
-- park to build survives the map change in a file.
local cv_base = CreateConVar("skate3_park_map", "gm_flatgrass", FCVAR_ARCHIVE + FCVAR_REPLICATED, "The open map skateparks are built on")
local PENDING = "skate3/pending_park.txt"
local TILES_PER_STEP = 1
local STEP_EVERY = 0.05
-- The note about a park being loaded is kept until it has stood this long.
local SETTLE = 10

local spawnAt, job

-- Removes every skatepark (not loose pieces).
function Park.Clear()
	if job then
		timer.Remove("skate3_park_build")
		job = nil
	end
	for _, ent in ipairs(ents.FindByClass("skate3_piece")) do
		if ent.skate3Park then ent:Remove() end
	end
	spawnAt = nil
end

local function Say(text)
	PrintMessage(HUD_PRINTTALK, "[skate3] " .. text)
end

-- Where to stand on a finished park: its floor in the middle, or above it.
local function StandingSpot(id, info, origin)
	local lo, hi = info.bounds[1], info.bounds[2]
	local mid = origin + Vector((lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2, 0)
	-- From above the park down to a little below its ground; its lowest
	-- point can be far below, past what a trace reaches.
	local top = hi[3] + 64
	local bottom = math.max(lo[3], (info.floor or 0) - 512) - 64
	local spot = util.TraceLine({
		start = mid + Vector(0, 0, top),
		endpos = mid + Vector(0, 0, math.max(bottom, top - 16000)),
		ignoreworld = true,
		filter = function(e) return e:GetClass() == "skate3_piece" and e.skate3Park == id end,
	})
	if spot.Hit then return spot.HitPos + Vector(0, 0, 8) end
	return mid + Vector(0, 0, math.max(hi[3], 0) + 64)
end

local function Finished()
	local j = job
	job = nil
	timer.Remove("skate3_park_build")
	spawnAt = StandingSpot(j.id, j.info, j.origin)
	for _, p in ipairs(player.GetAll()) do
		if j.drop then
			p:SetPos(spawnAt)
			p:SetVelocity(-p:GetVelocity())
		end
	end
	Say(j.info.name .. " is ready.")
	-- A crash in the next moments still counts against the park.
	timer.Simple(SETTLE, function() if not job and not Park.Safe then Park.Note(false) end end)
end

local function Step()
	local j = job
	if not j then return end
	for _ = 1, TILES_PER_STEP do
		j.i = j.i + 1
		local id = j.info.tiles[j.i]
		if not id then return Finished() end
		local ent = Create(id, j.origin, angle_zero)
		if ent then
			ent.skate3Park = j.id
			ent:SetCreator(j.owner or NULL)
		end
		local percent = math.floor(j.i / #j.info.tiles * 4)
		if percent > j.reported then
			j.reported = percent
			if percent < 4 then Say(("Building %s: %d%%"):format(j.info.name, percent * 25)) end
		end
	end
end

-- Starts building a park with its origin at `origin`. `drop` also moves
-- everyone onto it when it's done.
function Park.Build(id, origin, owner, drop)
	local index = Park.Index()
	local info = index and index[id]
	if not info or not info.tiles then return false end
	if job then
		Say("A skatepark is still being built.")
		return false
	end
	Park.Clear()
	-- The note stays until the park has loaded and stood a while, so a crash
	-- while it builds is remembered (see sh_park.lua).
	Park.Note(true)
	job = { id = id, info = info, origin = origin, owner = owner, drop = drop, i = 0, reported = 0 }
	Say(("Building %s (%d tiles)..."):format(info.name, #info.tiles))
	print(("[skate3] park %s: origin %s, floor %s, bounds %s to %s"):format(id, tostring(origin), tostring(info.floor),
		tostring(Vector(info.bounds[1][1], info.bounds[1][2], info.bounds[1][3])),
		tostring(Vector(info.bounds[2][1], info.bounds[2][2], info.bounds[2][3]))))
	timer.Create("skate3_park_build", STEP_EVERY, 0, Step)
	return true
end

-- The park's origin so its ground (info.floor, found by setup) sits just
-- over the ground at `at`. Its lowest point can't be used: a park's models
-- reach far below it. Without a floor the park's own zero is its ground.
local function OriginOver(info, at)
	local ground = util.TraceLine({ start = at + Vector(0, 0, 64), endpos = at - Vector(0, 0, 32768), mask = MASK_SOLID_BRUSHONLY })
	return Vector(at.x, at.y, ground.HitPos.z - (info.floor or 0) + 4)
end

local function BuildOnBaseMap(id)
	local index = Park.Index()
	local info = index and index[id]
	if not info then return end
	-- Centred on the map's player spawn, which is always inside the map.
	local start = ents.FindByClass("info_player_start")[1]
	local at = IsValid(start) and start:GetPos() or vector_origin
	return Park.Build(id, OriginOver(info, at), nil, true)
end

local function AdminOnly(ply, what)
	if IsValid(ply) and not ply:IsAdmin() then
		ply:ChatPrint("[skate3] Only admins can " .. what .. ".")
		return true
	end
end

concommand.Add("skate3_park_load", function(ply, _, args)
	if AdminOnly(ply, "load a skatepark") then return end
	local id = args[1] or ""
	local index = Park.Index()
	local info = index and index[id]
	if not info or not info.tiles then
		if IsValid(ply) then ply:ChatPrint("[skate3] No skatepark " .. id .. ". Run the setup app to convert them from your disc.") end
		return
	end
	-- A park with a map of its own loads as that map; the others go on the
	-- open base map.
	local map = Park.MapOf(id) or cv_base:GetString()
	if game.GetMap() == map then
		if Park.Maps[map] then
			Say("You're already in " .. info.name .. ".")
		else
			BuildOnBaseMap(id)
		end
		return
	end
	file.CreateDir("skate3")
	file.Write(PENDING, id)
	Say("Loading " .. info.name .. "...")
	timer.Simple(0.5, function() RunConsoleCommand("changelevel", map) end)
end)

-- Builds a park right here, on whatever map this is: its middle goes where
-- the admin is looking.
concommand.Add("skate3_park_build", function(ply, _, args)
	if not IsValid(ply) or AdminOnly(ply, "build a skatepark") then return end
	local index = Park.Index()
	local info = index and index[args[1] or ""]
	if not info or not info.tiles then
		ply:ChatPrint("[skate3] No skatepark " .. tostring(args[1]) .. ". Run the setup app to convert them from your disc.")
		return
	end
	local tr = util.TraceLine({ start = ply:EyePos(), endpos = ply:EyePos() + ply:GetAimVector() * 16384, filter = ply, mask = MASK_SOLID_BRUSHONLY })
	Park.Build(args[1], OriginOver(info, tr.HitPos), ply, false)
end)

concommand.Add("skate3_park_clear", function(ply)
	if AdminOnly(ply, "remove a skatepark") then return end
	Park.Clear()
	Say("Skatepark removed.")
end)

-- After a crash while a park loaded, parks come up without Gmod physics
-- until this says it's fine (see sh_park.lua).
concommand.Add("skate3_park_safe_sv", function(ply, _, args)
	if AdminOnly(ply, "change park safety") then return end
	Park.Safe = args[1] == "1"
	if not Park.Safe then Park.Note(false) end
	Say(Park.Safe and "Park physics are off." or "Park physics are on again.")
end)

hook.Add("InitPostEntity", "skate3_park_load", function()
	local id = file.Read(PENDING, "DATA")
	if id then file.Delete(PENDING) end
	-- A park's own map builds that park however it was started (the map
	-- list, the console, the spawn tab).
	local own = Park.Maps[game.GetMap()]
	if own then
		id = own
	elseif game.GetMap() ~= cv_base:GetString() then
		return
	end
	if not id or not Park.Index() then return end
	-- Let the map settle before a hundred tiles go in.
	timer.Simple(1, function() BuildOnBaseMap(id) end)
end)

-- Everyone arriving, or respawning, starts on a park that was loaded as a map.
hook.Add("PlayerSpawn", "skate3_park_load", function(ply)
	if spawnAt then
		timer.Simple(0, function()
			if IsValid(ply) and spawnAt then
				ply:SetPos(spawnAt)
				ply:SetVelocity(-ply:GetVelocity())
			end
		end)
	end
end)

hook.Add("PlayerInitialSpawn", "skate3_park_missing", function(ply)
	if not Park.Maps[game.GetMap()] or Park.Index() then return end
	timer.Simple(8, function()
		if IsValid(ply) then
			ply:ChatPrint("[skate3] This map is an empty field until the park is converted from your Skate 3 disc: run the S3GM setup again.")
		end
	end)
end)

hook.Add("PlayerInitialSpawn", "skate3_park_safe", function(ply)
	if not Park.Safe then return end
	timer.Simple(8, function()
		if IsValid(ply) and ply:IsAdmin() then
			ply:ChatPrint("[skate3] The last skatepark load didn't finish, so parks come up without Gmod physics (the board still rides them). "
				.. "Type skate3_park_safe 0 in the console to turn them back on.")
		end
	end)
end)

-- The server's half of skate3_park_info.
concommand.Add("skate3_park_info_sv", function(ply)
	local total, physics, moving, tiles = 0, 0, 0, 0
	for _, e in ipairs(ents.FindByClass("skate3_piece")) do
		total = total + 1
		if e:IsTile() then tiles = tiles + 1 end
		local phys = e:GetPhysicsObject()
		if IsValid(phys) then
			physics = physics + 1
			if phys:IsMotionEnabled() then moving = moving + 1 end
		end
	end
	local text = {
		"[skate3] park info (server)",
		("  map %s, safe mode %s, a park is being built: %s"):format(game.GetMap(), tostring(Park.Safe), tostring(job ~= nil)),
		("  pieces %d (tiles %d), with physics %d, not frozen %d"):format(total, tiles, physics, moving),
	}
	for _, line in ipairs(text) do
		print(line)
		if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, line) end
	end
end)
