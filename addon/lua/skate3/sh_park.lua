-- Skate 3's create-a-park pieces (and its skateparks), converted from the
-- player's own disc by the setup app into data/skate3/park. Each piece has
-- its render mesh, its textures' names and its own Skate 3 collision, all in
-- Source units. A whole skatepark is cut into tiles that share its origin;
-- the index lists them under the park.

if Skate3Park then return Skate3Park end

local Park = {}
Skate3Park = Park
local cache = {}
local index

-- Garry's Mod builds one physics mesh reliably up to roughly this many
-- triangles; past about 65,000 it silently drops most of them. The setup app
-- cuts tiles well under it, and anything bigger gets no Gmod physics.
Park.MAX_PHYSICS = 30000

-- The loading of a park leaves a note in data/ until it has gone well, so a
-- crash is remembered: the next start builds parks without Gmod physics (the
-- piece collision the board rides is separate and stays) until the player
-- says it is fine. Server and client each keep their own note.
Park.NOTE = SERVER and "skate3/park_loading.txt" or "skate3/park_client.txt"

function Park.Note(on)
	if on then
		file.CreateDir("skate3")
		file.Write(Park.NOTE, tostring(os.time()))
	else
		file.Delete(Park.NOTE)
	end
end

-- Read once at startup: did the last park load on this side never finish?
Park.Safe = file.Exists(Park.NOTE, "DATA")

function Park.Index()
	if index == nil then
		local text = file.Read("skate3/park/index.json", "DATA")
		index = text and util.JSONToTable(text) or false
		if index then
			for _, p in ipairs(index) do index[p.id] = p end
		end
	end
	return index or nil
end

-- Forgets what was read (the setup app ran again).
function Park.Reload()
	index = nil
	cache = {}
end

-- Set pieces built from park pieces. Offsets are metres along the preset
-- (x runs back from where it starts, y across, z up); every piece keeps its
-- own Skate 3 collision, so they ride as one.
local PAD = "2c701707000304e5" -- Mega Park Filler Pad X Lrg, 12 x 12 x 6 m
Park.Presets = {
	{
		id = "megaramp",
		name = "Mega Ramp",
		tip = "A 12 m start deck and roll-in, a 6 m runway to a 9 m kicker, a 16 m gap, the landing and a 9 m quarter pipe. About 125 m long.",
		pieces = {
			{ PAD, 6, 0, 0 }, { PAD, 6, 0, 6 }, -- start deck
			{ PAD, -6, 0, 0 }, { "2c701707000303c5", 0, 0, 6 }, -- roll-in
			{ PAD, -18, 0, 0 }, { PAD, -30, 0, 0 }, { PAD, -42, 0, 0 }, -- runway
			{ "2c701707000303c4", -36, 0, 6 }, -- kicker
			{ "2c701707000303cf", -88, 0, 0 }, -- landing
			{ "2c701707000303ce", -100, 0, 0 }, -- quarter pipe
		},
	},
}
for _, p in ipairs(Park.Presets) do Park.Presets[p.id] = p end

-- The skateparks that ship a map of their own (addon/maps, made by
-- setup/bspmap.py): an open grass field that builds the park on it at load.
Park.Maps = {
	gm_skate3_megapark = "megapark_stadium",
	gm_skate3_maloof = "map_maloof",
	gm_skate3_blackbox = "map_blackbox",
	gm_skate3_downtown_park = "map_downtown_park",
	gm_skate3_industrial_park = "map_industrial_park",
	gm_skate3_skate_school = "map_skate_school",
	gm_skate3_start_park = "map_start_park",
}

-- The map that holds a park, when this install has it.
function Park.MapOf(id)
	for map, park in pairs(Park.Maps) do
		if park == id and file.Exists("maps/" .. map .. ".bsp", "GAME") then return map end
	end
end

-- A piece's whole data, read once. A park's tiles are big and only read by
-- whoever is building them, so callers let those go again (Park.Forget).
function Park.Get(id)
	if cache[id] == nil then
		local text = isstring(id) and id:match("^[%w_]+$") and file.Read("skate3/park/" .. id .. ".json", "DATA")
		cache[id] = text and util.JSONToTable(text) or false
	end
	return cache[id] or nil
end

function Park.Forget(id)
	cache[id] = nil
end

-- The piece's collision as a triangle soup of Vectors, local to the piece:
-- its Skate 3 collision, or the render mesh when it has none.
function Park.Soup(piece)
	if piece.soup then return piece.soup end
	local soup = {}
	local c = piece.collision
	if c and #c >= 9 then
		for i = 1, #c - 8, 3 do soup[#soup + 1] = Vector(c[i], c[i + 1], c[i + 2]) end
	else
		for _, g in ipairs(piece.groups or {}) do
			for _, k in ipairs(g.idx) do
				local at = k * 3
				soup[#soup + 1] = Vector(g.pos[at + 1], g.pos[at + 2], g.pos[at + 3])
			end
		end
	end
	piece.soup = soup
	return soup
end

-- A placed piece's Skate 3 collision in world space, as the flat
-- {x1, y1, z1, x2, ...} list the skate module takes for extra triangles, and
-- how many numbers that is. Skate 3's triangles face out clockwise once in
-- Source axes; the module wants them counterclockwise, or the board only
-- collides from inside and falls straight through, so each is turned over.
local ORDER = { 0, 6, 3 }

function Park.WorldTriangles(ent, piece)
	local c = piece and piece.collision
	if not c or #c < 9 then return {}, 0 end
	local pos, ang = ent:GetPos(), ent:GetAngles()
	local f, r, u = ang:Forward(), ang:Right(), ang:Up()
	local fx, fy, fz, rx, ry, rz, ux, uy, uz = f.x, f.y, f.z, r.x, r.y, r.z, u.x, u.y, u.z
	local px, py, pz = pos.x, pos.y, pos.z
	local out, n = {}, 0
	for t = 1, #c - 8, 9 do
		for k = 1, 3 do
			local at = t + ORDER[k]
			local x, y, z = c[at], c[at + 1], c[at + 2]
			-- Local y is the angle's left: Right() points the other way.
			out[n + 1] = px + fx * x - rx * y + ux * z
			out[n + 2] = py + fy * x - ry * y + uy * z
			out[n + 3] = pz + fz * x - rz * y + uz * z
			n = n + 3
		end
	end
	return out, n
end

-- The board rides a piece through the skate module's own copy of its
-- collision. The skater's Gmod body is moved into place each update, and
-- would otherwise shove the frozen piece, so the two never collide.
hook.Add("ShouldCollide", "skate3_park", function(a, b)
	if a:GetClass() ~= "skate3_piece" then a, b = b, a end
	if a:GetClass() == "skate3_piece" and b:IsPlayer() and b:GetNW2Bool("skate3_riding") then
		return false
	end
end)

return Park
