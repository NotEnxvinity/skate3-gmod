-- Skate 3's create-a-park pieces (and the Mega Park stadium), converted from
-- the player's own disc by the setup app into data/skate3/park. Each piece
-- has its render mesh, its textures' names and its own Skate 3 collision,
-- all in Source units.

if Skate3Park then return Skate3Park end

local Park = {}
Skate3Park = Park
local cache = {}
local index

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

-- A piece's whole data, read once.
function Park.Get(id)
	if cache[id] == nil then
		local text = isstring(id) and id:match("^[%w_]+$") and file.Read("skate3/park/" .. id .. ".json", "DATA")
		cache[id] = text and util.JSONToTable(text) or false
	end
	return cache[id] or nil
end

-- The piece's collision as a triangle soup of Vectors, local to the piece:
-- its Skate 3 collision, or the render mesh when it has none.
function Park.Soup(piece)
	if piece.soup then return piece.soup end
	local soup = {}
	local c = piece.collision
	if c and #c >= 9 then
		for i = 1, #c, 3 do soup[#soup + 1] = Vector(c[i], c[i + 1], c[i + 2]) end
	else
		for _, g in ipairs(piece.groups) do
			for _, k in ipairs(g.idx) do
				local at = k * 3
				soup[#soup + 1] = Vector(g.pos[at + 1], g.pos[at + 2], g.pos[at + 3])
			end
		end
	end
	piece.soup = soup
	return soup
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