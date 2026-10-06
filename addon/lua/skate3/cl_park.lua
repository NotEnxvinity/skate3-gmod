-- The "Skate 3 Park" spawn menu tab, and the placed pieces' collision for
-- the skate module.

local Park = include("skate3/sh_park.lua")

local NAMES = {
	PreMade = "Premade", OTS = "OTS", DownTown = "Downtown",
	DMO_Ramps = "Props: Ramps", DMO_Rails = "Props: Rails", DMO_Boxes = "Props: Boxes",
	DMO_Barriers = "Props: Barriers", DMO_Tables = "Props: Tables", DMO_Bins = "Props: Bins",
	DMO_Misc = "Props: Misc",
}

spawnmenu.AddCreationTab("Skate 3 Park", function()
	local scroll = vgui.Create("DScrollPanel")
	local index = Park.Index()
	if not index then
		local label = scroll:Add("DLabel")
		label:Dock(TOP)
		label:DockMargin(16, 16, 16, 0)
		label:SetDark(true)
		label:SetWrap(true)
		label:SetAutoStretchVertical(true)
		label:SetText("No park pieces yet. Run the Skate 3 setup app again with your disc, and it converts "
			.. "Skate 3's create-a-park pieces and skateparks for this tab.")
		return scroll
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
	for _, name in ipairs(order) do
		local cat = scroll:Add("DCollapsibleCategory")
		cat:Dock(TOP)
		cat:DockMargin(4, 4, 4, 0)
		cat:SetLabel(NAMES[name] or name)
		cat:SetExpanded(name == "Mega" or name == "Maps" or name == "Presets")
		local layout = vgui.Create("DIconLayout", cat)
		layout:SetSpaceX(4)
		layout:SetSpaceY(4)
		layout:DockPadding(4, 4, 4, 4)
		cat:SetContents(layout)
		for _, p in ipairs(categories[name]) do
			local b = layout:Add("DButton")
			b:SetText(p.name)
			b:SetSize(150, 28)
			if p.preset then
				b:SetTooltip(p.tip)
			else
				b:SetTooltip(("%s (%.0f x %.0f x %.0f)"):format(p.name,
					p.bounds[2][1] - p.bounds[1][1], p.bounds[2][2] - p.bounds[1][2], p.bounds[2][3] - p.bounds[1][3]))
			end
			b.DoClick = function()
				if p.preset then
					RunConsoleCommand("skate3_spawn_preset", p.preset)
				else
					RunConsoleCommand("skate3_spawn_piece", p.id)
				end
				surface.PlaySound("ui/buttonclickrelease.wav")
			end
		end
	end
	return scroll
end, "icon16/brick.png", 60, "Skate 3's create-a-park pieces, from your own disc")

-- Every placed piece's Skate 3 collision, in world space, as the flat
-- {x1, y1, z1, x2, ...} list skate3.LoadMap takes for extra triangles.
function Park.Triangles()
	local out = {}
	local n = 0
	for _, ent in ipairs(ents.FindByClass("skate3_piece")) do
		local piece = ent.loadedId and Park.Get(ent.loadedId)
		if piece then
			for _, v in ipairs(Park.Soup(piece)) do
				local w = ent:LocalToWorld(v)
				out[n + 1], out[n + 2], out[n + 3] = w.x, w.y, w.z
				n = n + 3
			end
		end
	end
	return out
end

-- Where each piece sits, so a move with the physgun counts as a change.
local function Layout()
	local parts = {}
	for _, ent in ipairs(ents.FindByClass("skate3_piece")) do
		if ent.loadedId then
			local p, a = ent:GetPos(), ent:GetAngles()
			parts[#parts + 1] = ("%s@%.0f,%.0f,%.0f/%.0f,%.0f,%.0f"):format(ent.loadedId, p.x, p.y, p.z, a.p, a.y, a.r)
		end
	end
	table.sort(parts)
	return table.concat(parts, ";")
end

-- The skate collision is rebuilt once the pieces stop changing for a moment.
local SETTLE = 1
local lastLayout, changedAt = "", nil

hook.Add("Skate3ParkChanged", "skate3_park", function()
	changedAt = RealTime()
end)

timer.Create("skate3_park_watch", 0.5, 0, function()
	local layout = Layout()
	if layout ~= lastLayout then
		lastLayout = layout
		changedAt = RealTime()
	end
	if changedAt and RealTime() - changedAt >= SETTLE then
		changedAt = nil
		hook.Run("Skate3RebuildCollision")
	end
end)

return Park
