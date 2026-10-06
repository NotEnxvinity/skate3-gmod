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

return Park
