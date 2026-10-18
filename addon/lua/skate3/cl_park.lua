-- The "Skate 3" spawn menu tab: Skate 3's park pieces and skateparks, from
-- the player's own disc. Picking a piece puts it on the tool gun; the
-- placed pieces' collision reaches the skate module through cl_live_props.

local Park = include("skate3/sh_park.lua")

local NAMES = {
	PreMade = "Premade", OTS = "OTS", DownTown = "Downtown",
	DMO_Ramps = "Props: Ramps", DMO_Rails = "Props: Rails", DMO_Boxes = "Props: Boxes",
	DMO_Barriers = "Props: Barriers", DMO_Tables = "Props: Tables", DMO_Bins = "Props: Bins",
	DMO_Misc = "Props: Misc",
}

CreateClientConVar("skate3_park_piece", "", true, true, "The park piece the Skate 3 Park tool places")

local materials = {}

-- Cutout textures (leaves, fences, grates) are alpha tested and drawn from
-- both sides, like Skate 3's foliage cards.
local function MaterialFor(guid, cut)
	if not guid then return Material("models/debug/debugwhite") end
	local key = guid .. (cut and "_cut" or "")
	if materials[key] then return materials[key] end
	local png = Material("skate3/park/" .. guid .. ".png", "smooth mips")
	local mat = CreateMaterial("skate3park_" .. key, "VertexLitGeneric", {
		["$basetexture"] = "models/debug/debugwhite",
		["$alphatest"] = cut and "1" or nil,
		["$alphatestreference"] = cut and "0.5" or nil,
		["$nocull"] = cut and "1" or nil,
	})
	if not png:IsError() then mat:SetTexture("$basetexture", png:GetTexture("$basetexture")) end
	materials[key] = mat
	return mat
end

-- IMeshes hold at most 65535 vertices; a group is cut into pieces of this
-- many triangles to stay well under.
local MAX_TRIS = 20000

local function BuildMeshes(piece)
	local built = {}
	for _, g in ipairs(piece.groups or {}) do
		local verts = {}
		local pos, uv, idx = g.pos, g.uv, g.idx
		for t = 1, #idx - 2, 3 do
			local corner = {}
			for k = 0, 2 do
				local i = idx[t + k]
				corner[k + 1] = {
					pos = Vector(pos[i * 3 + 1], pos[i * 3 + 2], pos[i * 3 + 3]),
					u = uv[i * 2 + 1] or 0,
					v = 1 - (uv[i * 2 + 2] or 0),
				}
			end
			-- Skate 3's winding, after the axis swap, faces out clockwise,
			-- like Source's.
			local normal = (corner[3].pos - corner[1].pos):Cross(corner[2].pos - corner[1].pos)
			normal:Normalize()
			for k = 1, 3 do
				corner[k].normal = normal
				verts[#verts + 1] = corner[k]
			end
			if #verts >= MAX_TRIS * 3 then
				local m = Mesh()
				m:BuildFromTriangles(verts)
				built[#built + 1] = { mesh = m, mat = MaterialFor(g.tex, g.cut) }
				verts = {}
			end
		end
		if #verts > 0 then
			local m = Mesh()
			m:BuildFromTriangles(verts)
			built[#built + 1] = { mesh = m, mat = MaterialFor(g.tex, g.cut) }
		end
	end
	return built
end

-- A piece's render meshes, built once and shared by every copy of it, so
-- spawning the same ramp twenty times costs one set of meshes.
local meshes = {}

function Park.Meshes(id)
	if meshes[id] == nil then
		local piece = Park.Get(id)
		meshes[id] = piece and BuildMeshes(piece) or false
	end
	return meshes[id] or nil
end

-- Lets a piece's meshes go once nothing uses them (a removed skatepark).
function Park.ReleaseMeshes(id)
	timer.Simple(1, function()
		for _, ent in ipairs(ents.FindByClass("skate3_piece")) do
			if ent:GetPieceId() == id then return end
		end
		for _, m in ipairs(meshes[id] or {}) do m.mesh:Destroy() end
		meshes[id] = nil
		Park.Forget(id)
	end)
end

-- After a crash while pieces loaded, they come up without Gmod physics (see
-- sh_park.lua). This says it's fine again.
concommand.Add("skate3_park_safe", function(_, _, args)
	Park.Safe = args[1] == "1"
	if not Park.Safe then Park.Note(false) end
	RunConsoleCommand("skate3_park_safe_sv", args[1] == "1" and "1" or "0")
	chat.AddText(Color(120, 200, 255), "[skate3] ", color_white, Park.Safe and "Park physics are off." or "Park physics are on again.")
end)

-- The load note: written while pieces are still being built, removed once
-- they've stood a while. A crash in between leaves it for the next start.
local settledAt
timer.Create("skate3_park_note", 1, 0, function()
	if Park.Safe then return end
	if Park.Pending() then
		if not Park.noted then
			Park.noted = true
			Park.Note(true)
		end
		settledAt = nil
	elseif Park.noted then
		settledAt = settledAt or CurTime()
		if CurTime() - settledAt > 10 then
			Park.noted, settledAt = nil, nil
			Park.Note(false)
		end
	end
end)

hook.Add("InitPostEntity", "skate3_park_safe", function()
	if not Park.Safe then return end
	timer.Simple(8, function()
		chat.AddText(Color(120, 200, 255), "[skate3] ", color_white,
			"The last skatepark load didn't finish, so park pieces come up without Gmod physics (the board still rides them). "
			.. "Type skate3_park_safe 0 in the console to turn them back on.")
	end)
end)

-- Whether any piece is still waiting to be built.
function Park.Pending()
	for _, ent in ipairs(ents.FindByClass("skate3_piece")) do
		if ent:GetPieceId() ~= "" and not ent.loadedId then return true end
	end
	return false
end

-- Hands the park pieces' collision to the skate module, for cl_live_props.
function Park.Collision(ent)
	if not ent.loadedId then return nil end
	return Park.WorldTriangles(ent, Park.Get(ent.loadedId))
end

-- Draws the picked piece turning slowly, for the tab's preview.
local previewBroken
local function DrawPreview(panel, w, h)
	local id = GetConVar("skate3_park_piece"):GetString()
	local index = Park.Index()
	local info = index and index[id]
	if not info or info.tiles or previewBroken then return end
	local list = Park.Meshes(id)
	if not list or #list == 0 then return end
	local lo, hi = Vector(info.bounds[1][1], info.bounds[1][2], info.bounds[1][3]), Vector(info.bounds[2][1], info.bounds[2][2], info.bounds[2][3])
	local centre = (lo + hi) / 2
	local radius = math.max((hi - lo):Length() / 2, 16)
	local ang = Angle(22, (RealTime() * 25) % 360, 0)
	local x, y = panel:LocalToScreen(0, 0)
	cam.Start3D(centre - ang:Forward() * radius * 2.3, ang, 40, x, y, w, h)
	render.ClearDepth()
	render.SuppressEngineLighting(true)
	render.ResetModelLighting(0.75, 0.75, 0.75)
	for _, m in ipairs(list) do
		render.SetMaterial(m.mat)
		m.mesh:Draw()
	end
	render.SuppressEngineLighting(false)
	cam.End3D()
end

local function Message(parent, text)
	local label = parent:Add("DLabel")
	label:Dock(TOP)
	label:DockMargin(16, 16, 16, 0)
	label:SetDark(true)
	label:SetWrap(true)
	label:SetAutoStretchVertical(true)
	label:SetText(text)
end

-- The piece goes on the tool gun, which is then equipped.
local function Pick(id)
	RunConsoleCommand("skate3_park_piece", id)
	RunConsoleCommand("gmod_tool", "skate3_park")
	RunConsoleCommand("use", "gmod_tool")
	surface.PlaySound("ui/buttonclickrelease.wav")
end

local function ParkMenu(p)
	local menu = DermaMenu()
	local base = GetConVar("skate3_park_map")
	menu:AddOption("Load on " .. (base and base:GetString() or "the open map") .. " (admins)", function()
		RunConsoleCommand("skate3_park_load", p.id)
	end):SetIcon("icon16/map_go.png")
	menu:AddOption("Build here, where I'm looking (admins)", function()
		RunConsoleCommand("skate3_park_build", p.id)
	end):SetIcon("icon16/building_go.png")
	menu:AddOption("Remove the skatepark", function()
		RunConsoleCommand("skate3_park_clear")
	end):SetIcon("icon16/delete.png")
	menu:Open()
end

local function Fill(scroll, filter)
	scroll:Clear()
	local index = Park.Index()
	if not index then
		Message(scroll, "No park pieces yet. Run the S3GM setup again with your Skate 3 disc, and it converts "
			.. "Skate 3's park pieces and skateparks for this tab.")
		return
	end
	local categories, order = { Presets = {} }, { "Presets" }
	for _, preset in ipairs(Park.Presets) do
		table.insert(categories.Presets, { preset = preset.id, name = preset.name, tip = preset.tip })
	end
	for _, p in ipairs(index) do
		if not categories[p.category] then
			categories[p.category] = {}
			order[#order + 1] = p.category
		end
		table.insert(categories[p.category], p)
	end
	filter = filter and filter:lower() or ""
	for _, name in ipairs(order) do
		local shown = {}
		for _, p in ipairs(categories[name]) do
			if filter == "" or p.name:lower():find(filter, 1, true) then shown[#shown + 1] = p end
		end
		if #shown > 0 then
			local cat = scroll:Add("DCollapsibleCategory")
			cat:Dock(TOP)
			cat:DockMargin(4, 4, 4, 0)
			cat:SetLabel(NAMES[name] or name)
			cat:SetExpanded(filter ~= "" or name == "Mega" or name == "Maps" or name == "Presets")
			local layout = vgui.Create("DIconLayout", cat)
			layout:SetSpaceX(4)
			layout:SetSpaceY(4)
			layout:DockPadding(4, 4, 4, 4)
			cat:SetContents(layout)
			for _, p in ipairs(shown) do
				local b = layout:Add("DButton")
				b:SetText(p.name)
				b:SetSize(150, 28)
				if p.preset then
					b:SetTooltip(p.tip)
					b.DoClick = function()
						RunConsoleCommand("skate3_spawn_preset", p.preset)
						surface.PlaySound("ui/buttonclickrelease.wav")
					end
				elseif p.tiles then
					b:SetTooltip(("%s: a whole skatepark (%.0f x %.0f m). Click for load options."):format(p.name,
						(p.bounds[2][1] - p.bounds[1][1]) / 39.3701, (p.bounds[2][2] - p.bounds[1][2]) / 39.3701))
					b.DoClick = function() ParkMenu(p) end
				else
					b:SetTooltip(("%s (%.0f x %.0f x %.0f in): click to put it on the tool gun, right click to spawn it where you look"):format(p.name,
						p.bounds[2][1] - p.bounds[1][1], p.bounds[2][2] - p.bounds[1][2], p.bounds[2][3] - p.bounds[1][3]))
					b.DoClick = function() Pick(p.id) end
					b.DoRightClick = function()
						RunConsoleCommand("skate3_spawn_piece", p.id)
						surface.PlaySound("ui/buttonclickrelease.wav")
					end
				end
			end
		end
	end
end

if spawnmenu and spawnmenu.AddCreationTab then spawnmenu.AddCreationTab("Skate 3", function()
	local root = vgui.Create("DPanel")
	root.Paint = nil

	local side = vgui.Create("DPanel", root)
	side:Dock(RIGHT)
	side:SetWide(280)
	side:DockPadding(6, 6, 6, 6)
	side.Paint = nil

	local help = vgui.Create("DLabel", side)
	help:Dock(TOP)
	help:SetDark(true)
	help:SetWrap(true)
	help:SetAutoStretchVertical(true)
	help:SetText("Click a piece to put it on the tool gun, then left click to place it. Right click the tool turns it. "
		.. "Move pieces with the physgun; its reload key locks one in place. Right click a piece here to spawn it where you look.")

	local view = vgui.Create("DPanel", side)
	view:Dock(FILL)
	view:DockMargin(0, 6, 0, 0)
	view.Paint = function(self, w, h)
		surface.SetDrawColor(30, 30, 34, 255)
		surface.DrawRect(0, 0, w, h)
		local ok, err = pcall(DrawPreview, self, w, h)
		if not ok then
			previewBroken = true
			print("[skate3] piece preview turned off: " .. tostring(err))
		end
	end

	local filter = vgui.Create("DTextEntry", root)
	filter:Dock(TOP)
	filter:DockMargin(4, 4, 4, 0)
	filter:SetPlaceholderText("Search pieces")

	local scroll = vgui.Create("DScrollPanel", root)
	scroll:Dock(FILL)
	filter.OnChange = function(self) Fill(scroll, self:GetValue()) end
	Fill(scroll)
	return root
end, "icon16/brick.png", 60, "Skate 3's park pieces and skateparks, from your own disc") end

return Park
