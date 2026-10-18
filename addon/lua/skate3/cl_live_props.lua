-- Things that come and go or change place while the map runs, for the skate
-- collision: the props players spawn, the map's own physics and dynamic
-- props, its moving brush entities (doors, lifts), and, on a map with too
-- many props to hold at once, the static props around the skater. Static
-- props are built into the map's collision once at load when they fit
-- (cl_props.lua); these are watched and swapped into the module's collision
-- whenever they change, even mid-ride. A prop counts once it has stood still
-- for a moment, so one being carried or still falling isn't built over and
-- over. The server can switch the spawned props off with skate3_spawned_props.

-- Takes cl_props.lua's module, for its physics hull cache.
local Props
-- And cl_perf.lua's, to say when a swap landed in a slow frame.
local Perf

local Live = {}

local cv_server = GetConVar("skate3_spawned_props")

local CHECK_EVERY = 0.25
-- How long a prop must stay put before it's solid for skating.
local STILL_FOR = 0.5
-- At most one collision swap this often.
local SWAP_EVERY = 1
-- Grinds aren't interrupted by a swap for longer than this.
local GRIND_HOLD = 3
-- Nearest props first past this many triangles.
local MAX_TRIANGLES = 150000
-- On a map with too many props: how many triangles of the static ones around
-- the skater are solid at once, on top of the above.
local STREAM_BUDGET = 160000
-- The nearest static props are picked again once the skater has moved a
-- third of the way out to the farthest one picked, but at least this far
-- and at most that far (units).
local STREAM_MOVE_MIN, STREAM_MOVE_MAX = 400, 2000
-- Vertical distance counts double when picking the nearest: a bridge above
-- is further away than a bench beside you.
local STREAM_TALL = 2
-- How long building prop triangles may take in one frame (ms): riding, then not.
local BUILD_RIDING, BUILD_IDLE = 3, 12

-- Brush entities that change place while the map runs. Their brushes are
-- compiled where they start (a door closed), so the module takes them out of
-- the map and Lua says where they stand now (the module keeps the same list,
-- bsp.rs MOVERS).
local MOVERS = {
	func_door = true, func_door_rotating = true, func_movelinear = true, func_lookdoor = true,
	func_plat = true, func_platrot = true, func_train = true, func_tracktrain = true, func_rotating = true,
}

-- Collision groups players walk through: the board does too.
local PASSABLE = {
	[COLLISION_GROUP_DEBRIS] = true,
	[COLLISION_GROUP_DEBRIS_TRIGGER] = true,
	[COLLISION_GROUP_WORLD] = true, -- the context menu's "Collision" toggle
	[COLLISION_GROUP_IN_VEHICLE] = true,
	[COLLISION_GROUP_WEAPON] = true,
	[COLLISION_GROUP_PASSABLE_DOOR] = true,
}

local function Wanted(ent)
	if ent:EntIndex() <= 0 then return false end
	if ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() or ent:IsWeapon() or ent:IsRagdoll() then return false end
	local model = ent:GetModel()
	if not model or not model:find("%.mdl$") then return false end
	local solid = ent:GetSolid()
	if solid ~= SOLID_VPHYSICS and solid ~= SOLID_BBOX and solid ~= SOLID_OBB then return false end
	if not ent:IsSolid() or PASSABLE[ent:GetCollisionGroup()] then return false end
	-- Hats, carried things and the like.
	local parent = ent:GetParent()
	if IsValid(parent) and (parent:IsPlayer() or parent:IsNPC()) then return false end
	return true
end

-- Where it is, coarse enough that a resting prop's jitter doesn't count.
local function Place(ent)
	local p, a = ent:GetPos(), ent:GetAngles()
	return ("%s|%.0f %.0f %.0f|%.0f %.0f %.0f|%.2f"):format(ent:GetModel(), p.x * 2, p.y * 2, p.z * 2,
		a.p * 2, a.y * 2, a.r * 2, ent:GetModelScale() or 1)
end

-- The same for a brush entity, and whether it is solid.
local function BrushPlace(ent)
	local p, a = ent:GetPos(), ent:GetAngles()
	return ("%s|%d|%.0f %.0f %.0f|%.0f %.0f %.0f"):format(ent:GetModel(), ent:IsSolid() and 1 or 0,
		p.x * 2, p.y * 2, p.z * 2, a.p * 2, a.y * 2, a.r * 2)
end

local BOX = {
	{ 1, 2, 4 }, { 1, 4, 3 }, { 5, 7, 8 }, { 5, 8, 6 }, { 1, 5, 6 }, { 1, 6, 2 },
	{ 3, 4, 8 }, { 3, 8, 7 }, { 1, 3, 7 }, { 1, 7, 5 }, { 2, 6, 8 }, { 2, 8, 4 },
}

-- The entity's collision box as a hull, for things without a physics model.
local function BoxHull(ent)
	local lo, hi = ent:OBBMins(), ent:OBBMaxs()
	if (hi - lo):LengthSqr() < 1 then return false end
	local c = {}
	for i = 0, 7 do
		c[i + 1] = Vector(bit.band(i, 4) ~= 0 and hi.x or lo.x, bit.band(i, 2) ~= 0 and hi.y or lo.y, bit.band(i, 1) ~= 0 and hi.z or lo.z)
	end
	local verts = {}
	for _, f in ipairs(BOX) do
		verts[#verts + 1], verts[#verts + 2], verts[#verts + 3] = c[f[1]], c[f[2]], c[f[3]]
	end
	return { verts }
end

local seen = {} -- ent -> { place, since }
local current = {} -- key -> place, as last sent
local dirty = false
local lastSwap = -math.huge
local grindingSince
-- What's wanted solid now: key -> place. A key is a prop entity or, for the
-- map's own static props on a big map, the record Props.Stream holds.
local wanted = {}
-- Each prop's triangles where it stands, kept until it moves: a swap only
-- works out the props that changed, not every prop again.
local built = {} -- key -> { place, tris (flat), count }

-- Brush entities, as last sent to the module.
local brushSeen = {} -- ent -> { place, since }
local brushWanted, brushCurrent = {}, {} -- ent -> place
local brushDirty = false
-- The module only moves entities it was told were live at load.
local brushesSent = false

local function BuildEntity(ent, place)
	local b = built[ent]
	if b and b.place == place then return b end
	local hs = ent:GetSolid() == SOLID_VPHYSICS and Props.Solid(ent:GetModel()) or BoxHull(ent)
	local tris, n = {}, 0
	if hs then
		local m = Matrix()
		m:Translate(ent:GetPos())
		m:Rotate(ent:GetAngles())
		local scale = ent:GetModelScale() or 1
		if scale ~= 1 and ent:GetSolid() == SOLID_VPHYSICS then m:Scale(Vector(scale, scale, scale)) end
		n = Props.AppendHulls(tris, 0, hs, m)
	end
	b = { place = place, tris = tris, count = n }
	built[ent] = b
	return b
end

-- A static prop of the map: it never moves, so it's built once.
local function BuildStatic(rec)
	local b = built[rec]
	if b then return b end
	local tris = {}
	local m = Matrix()
	m:Translate(rec.pos)
	m:Rotate(rec.ang)
	local n = Props.AppendHulls(tris, 0, rec.hulls, m)
	b = { place = "static", tris = tris, count = n }
	built[rec] = b
	return b
end

local function Build(key, place)
	if place == "static" then return BuildStatic(key) end
	return BuildEntity(key, place)
end

local function PosOf(key)
	return istable(key) and key.pos or key:GetPos()
end

local function Triangles(still)
	local list, total = {}, 0
	for key, place in pairs(still) do
		local b = Build(key, place)
		if b.count > 0 then
			list[#list + 1] = { key = key, b = b }
			total = total + b.count
		end
	end
	local cap = MAX_TRIANGLES + (Props.Stream and STREAM_BUDGET or 0)
	-- Too many: nearest props first.
	if total / 9 > cap then
		local me = LocalPlayer()
		local from = IsValid(me) and me:GetPos() or vector_origin
		for _, e in ipairs(list) do e.d = PosOf(e.key):DistToSqr(from) end
		table.sort(list, function(a, b) return a.d < b.d end)
	end
	local out, n = {}, 0
	for _, e in ipairs(list) do
		local tris = e.b.tris
		for i = 1, e.b.count do out[n + i] = tris[i] end
		n = n + e.b.count
		if n / 9 >= cap then
			print(("[skate3] spawned prop collision stopped at %d triangles"):format(cap))
			break
		end
	end
	return out, n / 9
end

-- The static props of a big map, in square cells so the nearest ones can be
-- found without sorting every prop each time.
local CELL = 1024
local grid, streamList
local streamAt, streamRadius, streamPicked = nil, 0, nil

local function Cells(list)
	local cells, keys = {}, {}
	for _, rec in ipairs(list) do
		local cx, cy = math.floor(rec.pos.x / CELL), math.floor(rec.pos.y / CELL)
		local k = cx * 65536 + cy
		local cell = cells[k]
		if not cell then
			cell = { x = (cx + 0.5) * CELL, y = (cy + 0.5) * CELL, tris = 0 }
			cells[k] = cell
			keys[#keys + 1] = cell
		end
		cell[#cell + 1] = rec
		cell.tris = cell.tris + rec.tris
	end
	return keys
end

-- The props nearest `from`, up to the triangle budget, as a set. Also sets
-- how far the skater may go before they're picked again.
local function PickStatic(from)
	local cells = grid
	for _, c in ipairs(cells) do
		local dx, dy = c.x - from.x, c.y - from.y
		c.d = dx * dx + dy * dy
	end
	table.sort(cells, function(a, b) return a.d < b.d end)
	-- Whole cells nearest first, until there's a good deal more than the
	-- budget to choose the very nearest from (a cell's centre is only
	-- roughly where its props are).
	local candidates, tris = {}, 0
	for _, c in ipairs(cells) do
		for _, rec in ipairs(c) do candidates[#candidates + 1] = rec end
		tris = tris + c.tris
		if tris >= STREAM_BUDGET * 1.5 then break end
	end
	for _, rec in ipairs(candidates) do
		local dx, dy, dz = rec.pos.x - from.x, rec.pos.y - from.y, (rec.pos.z - from.z) * STREAM_TALL
		rec.d = dx * dx + dy * dy + dz * dz
	end
	table.sort(candidates, function(a, b) return a.d < b.d end)
	local picked, used, far = {}, 0, 0
	for _, rec in ipairs(candidates) do
		if used + rec.tris <= STREAM_BUDGET then
			picked[rec] = true
			used = used + rec.tris
			far = rec.d
		end
		if used >= STREAM_BUDGET - 100 then break end
	end
	streamRadius = math.Clamp(math.sqrt(far) / 3, STREAM_MOVE_MIN, STREAM_MOVE_MAX)
	return picked
end

local nextCheck = 0

-- Looks at every entity: the props that are still, the stream of static props
-- around the skater and the brush entities. Sets `wanted` and `dirty`.
local function Scan(now)
	local on = not cv_server or cv_server:GetBool()
	local still, fresh = {}, {}
	if on then
		for _, ent in ipairs(ents.GetAll()) do
			if ent:IsDormant() then
				-- Out of sight in multiplayer, so the game stopped updating
				-- it: keep it where it was last seen rather than swapping
				-- the collision every time a prop leaves or comes back.
				local place = current[ent]
				if place then
					still[ent] = place
					fresh[ent] = seen[ent] or { place = place, since = now }
				end
			elseif Wanted(ent) then
				local place = Place(ent)
				local s = seen[ent]
				if not s or s.place ~= place then
					s = { place = place, since = now }
				elseif now - s.since >= STILL_FOR then
					still[ent] = place
				end
				fresh[ent] = s
			end
		end
	end
	-- Gone, or no longer wanted.
	seen = fresh

	-- The map's own props around the skater, when it has too many for all.
	local stream = Props.Stream
	if stream ~= streamList then
		streamList, grid, streamAt, streamPicked = stream, stream and Cells(stream) or nil, nil, nil
	end
	if stream then
		local me = LocalPlayer()
		if IsValid(me) then
			local from = me:GetPos()
			if not streamAt or from:DistToSqr(streamAt) > streamRadius * streamRadius then
				streamAt = from
				streamPicked = PickStatic(from)
			end
		end
		if streamPicked then
			for rec in pairs(streamPicked) do still[rec] = "static" end
		end
	end
	wanted = still

	if not dirty then
		for key, place in pairs(still) do
			if current[key] ~= place then dirty = true break end
		end
		if not dirty then
			for key in pairs(current) do
				if not still[key] then dirty = true break end
			end
		end
	end

	-- Doors and the like, where they stand once they've settled.
	if skate3.SetBrushes then
		local freshBrush, settled = {}, {}
		-- Nothing has been seen moving yet the first time round: they stand
		-- as they are.
		local first = not brushesSent
		for _, ent in ipairs(ents.GetAll()) do
			if MOVERS[ent:GetClass()] and not ent:IsDormant() and tonumber((ent:GetModel() or ""):match("^%*(%d+)$")) then
				local place = BrushPlace(ent)
				local s = brushSeen[ent]
				if not s or s.place ~= place then
					s = { place = place, since = first and now - STILL_FOR or now }
				end
				-- One switched off (or opened non-solid) isn't in the collision at all.
				if now - s.since >= STILL_FOR and ent:IsSolid() then settled[ent] = place end
				freshBrush[ent] = s
			elseif brushCurrent[ent] and ent:IsValid() and ent:IsDormant() then
				-- Out of sight: stays where it was.
				settled[ent] = brushCurrent[ent]
				freshBrush[ent] = brushSeen[ent]
			end
		end
		brushSeen, brushWanted = freshBrush, settled
		if not brushDirty then
			-- The first look always sends: the module took the doors out of
			-- the map when it loaded and waits to be told where they are.
			brushDirty = not brushesSent
			if not brushDirty then
				for ent, place in pairs(settled) do
					if brushCurrent[ent] ~= place then brushDirty = true break end
				end
			end
			if not brushDirty then
				for ent in pairs(brushCurrent) do
					if not settled[ent] then brushDirty = true break end
				end
			end
		end
	end
end

-- The brush entities in the flat list SetBrushes takes.
local function BrushList()
	local out, n = {}, 0
	for ent in pairs(brushWanted) do
		if IsValid(ent) then
			local num = tonumber((ent:GetModel() or ""):match("^%*(%d+)$"))
			if num then
				local pos, ang = ent:GetPos(), ent:GetAngles()
				for _, v in ipairs({ num, ent:IsSolid() and 1 or 0, pos.x, pos.y, pos.z, ang.p, ang.y, ang.r }) do
					n = n + 1
					out[n] = v
				end
			end
		end
	end
	return out
end

-- Called every frame once the map's collision is ready; `state` is the
-- skater's state while riding.
function Live.Think(now, state)
	if not skate3.SetProps then return end
	if now >= nextCheck then
		nextCheck = now + CHECK_EVERY
		Scan(now)
	end
	if (not dirty and not brushDirty) or now - lastSwap < SWAP_EVERY then return end
	-- Mid-grind, the rail could move under the board: wait for it to end.
	if state and state:find("^Grind") then
		grindingSince = grindingSince or now
		if now - grindingSince < GRIND_HOLD then return end
	end
	-- Building a prop's triangles takes a moment each: a few milliseconds a
	-- frame, so a big batch (the stream's first) doesn't stall the game.
	local started = SysTime()
	local deadline = started + (state and BUILD_RIDING or BUILD_IDLE) / 1000
	if dirty then
		for key, place in pairs(wanted) do
			local b = built[key]
			if not b or b.place ~= place then
				Build(key, place)
				if SysTime() > deadline then return end
			end
		end
	end
	grindingSince = nil
	if dirty then
		for key in pairs(built) do
			if not wanted[key] then built[key] = nil end
		end
		local props = table.Count(wanted)
		local tris, count = Triangles(wanted)
		skate3.SetProps(tris)
		current, dirty = wanted, false
		local ms = (SysTime() - started) * 1000
		Perf.Note(("prop swap: %d props, %d triangles, %.0f ms"):format(props, count, ms))
		print(("[skate3] props solid for skating: %d (%d triangles, last frame's share %.0f ms)"):format(props, count, ms))
	end
	if brushDirty then
		local list = BrushList()
		skate3.SetBrushes(list)
		brushCurrent, brushDirty, brushesSent = brushWanted, false, true
		print(("[skate3] moving map pieces solid for skating: %d"):format(#list / 8))
	end
	lastSwap = now
end

return function(props, perf)
	Props, Perf = props, perf
	return Live
end
