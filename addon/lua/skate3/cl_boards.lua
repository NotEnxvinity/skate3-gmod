-- The board's looks: the deck, truck and wheel textures setup exported from
-- the player's own disc (setup/boards.py writes assets/boards), plus a colour
-- for each part. Picked in Utilities > Skate 3 > Settings.

S3GM_Boards = S3GM_Boards or { dir = "skate3/assets/boards" }
local Boards = S3GM_Boards

-- Part slot -> the convars that pick its look and colour.
Boards.PARTS = {
	{ slot = "SkateBoard", name = "Deck", look = "skate3_board_deck", color = "skate3_board_deck_color" },
	{ slot = "SkateTruck", name = "Trucks", look = "skate3_board_trucks", color = "skate3_board_trucks_color" },
	{ slot = "SkateWheel", name = "Wheels", look = "skate3_board_wheels", color = "skate3_board_wheels_color" },
}
for _, p in ipairs(Boards.PARTS) do
	CreateClientConVar(p.look, "", true, false, p.name .. " look: an id from boards.json, blank for the usual one")
	CreateClientConVar(p.color, "", true, false, p.name .. " colour as \"r g b\" (0-255), blank for none")
end

-- Colour presets for the menu (multiplied over the texture, so they show
-- best on light parts like wheels).
Boards.COLORS = {
	{ "None", "" },
	{ "Red", "230 50 50" }, { "Orange", "255 140 30" }, { "Yellow", "255 220 40" },
	{ "Green", "60 200 80" }, { "Teal", "40 200 190" }, { "Blue", "50 110 240" },
	{ "Purple", "150 80 230" }, { "Pink", "255 110 190" }, { "Black", "60 60 60" },
}

-- Where the textures are: next to the skater's own, once that has loaded.
function Boards.SetTextures(textures)
	local root = textures and textures:match("^(.*)/private/default_skater/textures/materials$")
	if root then Boards.dir = root .. "/boards" end
	Boards.list = nil
end

-- boards.json: { slots = { SkateBoard = { { id, name, worn, default }, ... } } }
function Boards.List()
	if Boards.list == nil then
		local text = file.Read(Boards.dir .. "/boards.json", "DATA")
		Boards.list = text and util.JSONToTable(text) or false
	end
	return Boards.list and Boards.list.slots or {}
end

-- The texture for `slot` the player picked, or nil for the usual one.
function Boards.Texture(slot)
	for _, p in ipairs(Boards.PARTS) do
		if p.slot == slot then
			local id = GetConVar(p.look):GetString()
			if id == "" then return end
			local png = Boards.dir .. "/" .. slot .. "/" .. id .. ".png"
			return file.Exists(png, "DATA") and png or nil
		end
	end
end

-- The picked colour for `slot` as 0-1 factors, or nil.
function Boards.Color(slot)
	for _, p in ipairs(Boards.PARTS) do
		if p.slot == slot then
			local r, g, b = GetConVar(p.color):GetString():match("^%s*(%d+)%s+(%d+)%s+(%d+)")
			if r then return Vector(r / 255, g / 255, b / 255) end
		end
	end
end

return Boards
