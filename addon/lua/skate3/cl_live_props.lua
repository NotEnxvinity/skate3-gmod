-- Props that come and go while the map runs (the ones players spawn, and the
-- map's own physics and dynamic props) for the skate collision. Static props
-- are built into the map's collision once at load (cl_props.lua); these are
-- watched and swapped into the module's collision whenever they change, even
-- mid-ride. A prop counts once it has stood still for a moment, so one being
-- carried or still falling isn't built over and over. The server can switch
-- this off with skate3_spawned_props.

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
local current = {} -- ent -> place, as last sent
local dirty = false
local lastSwap = -math.huge
local grindingSince
-- Each prop's triangles where it stands, kept until it moves: a swap only
-- works out the props that changed, not every prop again.
local built = {} -- ent -> { place, tris (flat), count }

local function Build(ent, place)
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

local function Triangles(still)
	local list, total = {}, 0
	for ent, place in pairs(still) do
		local b = Build(ent, place)
		if b.count > 0 then
			list[#list + 1] = { ent = ent, b = b }
			total = total + b.count
		end
	end
	-- Too many: nearest props first.
	if total / 9 > MAX_TRIANGLES then
		local me = LocalPlayer()
		local from = IsValid(me) and me:GetPos() or vector_origin
		for _, e in ipairs(list) do e.d = e.ent:GetPos():DistToSqr(from) end
		table.sort(list, function(a, b) return a.d < b.d end)
	end
	local out, n = {}, 0
	for _, e in ipairs(list) do
		local tris = e.b.tris
		for i = 1, e.b.count do out[n + i] = tris[i] end
		n = n + e.b.count
		if n / 9 >= MAX_TRIANGLES then
			print(("[skate3] spawned prop collision stopped at %d triangles"):format(MAX_TRIANGLES))
			break
		end
	end
	return out, n / 9
end

local nextCheck = 0

-- Called every frame once the map's collision is ready; `state` is the
-- skater's state while riding.
function Live.Think(now, state)
	if not skate3.SetProps or now < nextCheck then return end
	nextCheck = now + CHECK_EVERY
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
	if not dirty then
		for ent, place in pairs(still) do
			if current[ent] ~= place then dirty = true break end
		end
		if not dirty then
			for ent in pairs(current) do
				if not still[ent] then dirty = true break end
			end
		end
	end
	if not dirty or now - lastSwap < SWAP_EVERY then return end
	-- Mid-grind, the rail could move under the board: wait for it to end.
	if state and state:find("^Grind") then
		grindingSince = grindingSince or now
		if now - grindingSince < GRIND_HOLD then return end
	end
	grindingSince = nil
	local started = SysTime()
	for ent in pairs(built) do
		if not still[ent] then built[ent] = nil end
	end
	local props = table.Count(still)
	local tris, count = Triangles(still)
	skate3.SetProps(tris)
	current, dirty, lastSwap = still, false, now
	local ms = (SysTime() - started) * 1000
	Perf.Note(("prop swap: %d props, %d triangles, %.0f ms"):format(props, count, ms))
	print(("[skate3] spawned props solid for skating: %d (%d triangles, %.0f ms)"):format(props, count, ms))
end

return function(props, perf)
	Props, Perf = props, perf
	return Live
end
