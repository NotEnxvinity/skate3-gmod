-- Player fixes to this map's skate collision, made with the Skate 3 Surface
-- tool. Maps are built for walking, so a bumpy floor, a one-inch lip between
-- two brushes or a pipe with a crude hull can stop a board dead. A flag says
-- what the surface there should be:
--   flat    one plane (bumps and small steps pressed out)
--   smooth  one gentle curve (ramps, banks, pipes keep their shape)
--   ignore  pieces of collision inside the circle aren't solid for skating
--   grind   a rail drawn point by point
--   prop    a prop whose board collision follows its visible shape, not its
--           blocky physics one (applies on the next map load)
-- The flags are kept per map in data/skate3/surfaces/<map>.json. Send the
-- file to someone and they drop it in the same folder. Only this player's
-- skating changes: nothing on the server or in other players' games.

local Surf = {}
Skate3Surfaces = Surf

local DIR = "skate3/surfaces"
local KINDS = { flat = 1, smooth = 2, ignore = 3 }
local MAX_REGIONS, MAX_RAILS, MAX_POINTS = 4096, 1024, 64

Surf.COLORS = {
	flat = Color(80, 200, 255),
	smooth = Color(120, 255, 140),
	prop = Color(255, 150, 255),
	ignore = Color(255, 90, 90),
	grind = Color(255, 210, 60),
}

local regions = {} -- { k = "flat", p = Vector, n = Vector, r = radius, b = band }
local rails = {} -- { Vector, Vector, ... }
local propModels = {} -- model path (lower case) -> true: props to skate by their visible shape
local propOrder = {} -- those, in the order they were added
local history = {} -- "region", "rail" or "prop", in the order they were added
local pending = {} -- the rail being drawn

local function Path()
	return DIR .. "/" .. game.GetMap() .. ".json"
end

local function Say(...)
	chat.AddText(Color(120, 200, 255), "[skate3] ", color_white, ...)
end

local function Round(v)
	return Vector(math.Round(v.x, 1), math.Round(v.y, 1), math.Round(v.z, 1))
end

local function Arr(v)
	return { math.Round(v.x, 1), math.Round(v.y, 1), math.Round(v.z, 1) }
end

local function Vec(t)
	if type(t) ~= "table" then return nil end
	local x, y, z = tonumber(t[1]), tonumber(t[2]), tonumber(t[3])
	if not (x and y and z) then return nil end
	return Vector(x, y, z)
end

-- Reads the map's file (or one an addon ships in data_static).
function Surf.Load()
	regions, rails, history, pending = {}, {}, {}, {}
	propModels, propOrder = {}, {}
	local raw = file.Read(Path(), "DATA") or file.Read("data_static/" .. Path(), "GAME")
	local data = raw and util.JSONToTable(raw)
	if type(data) ~= "table" then return end
	for _, m in ipairs(data.props or {}) do
		m = type(m) == "string" and m:lower() or ""
		if m ~= "" and not propModels[m] and #propOrder < MAX_REGIONS then
			propModels[m] = true
			propOrder[#propOrder + 1] = m
			history[#history + 1] = "prop"
		end
	end
	for _, r in ipairs(data.regions or {}) do
		local p, n = Vec(r.p), Vec(r.n)
		if p and n and KINDS[r.k] and #regions < MAX_REGIONS then
			regions[#regions + 1] = {
				k = r.k, p = p, n = n,
				r = math.Clamp(tonumber(r.r) or 64, 4, 2048),
				b = math.Clamp(tonumber(r.b) or 6, 0.5, 64),
			}
			history[#history + 1] = "region"
		end
	end
	for _, line in ipairs(data.rails or {}) do
		local out = {}
		for _, t in ipairs(line) do
			local v = Vec(t)
			if v and #out < 4 * MAX_POINTS then out[#out + 1] = v end
		end
		if #out >= 2 and #rails < MAX_RAILS then
			rails[#rails + 1] = out
			history[#history + 1] = "rail"
		end
	end
end

local function Save()
	local list = {}
	for _, r in ipairs(regions) do
		list[#list + 1] = { k = r.k, p = Arr(r.p), n = { math.Round(r.n.x, 3), math.Round(r.n.y, 3), math.Round(r.n.z, 3) }, r = r.r, b = r.b }
	end
	local lines = {}
	for _, line in ipairs(rails) do
		local out = {}
		for i, v in ipairs(line) do out[i] = Arr(v) end
		lines[#lines + 1] = out
	end
	if #list == 0 and #lines == 0 and #propOrder == 0 then
		if file.Exists(Path(), "DATA") then file.Delete(Path()) end
		return
	end
	file.CreateDir("skate3")
	file.CreateDir(DIR)
	file.Write(Path(), util.TableToJSON({ version = 1, map = game.GetMap(), regions = list, rails = lines, props = propOrder }, true))
end

-- Experimental and off by default: ramps laid at steps this many units tall or
-- less, such as where two brushes meet a unit or two out of line. Nothing is
-- cut away, so no floor can open up; it only adds a slope in front of the step.
local lip = CreateClientConVar("skate3_lip_forgive", "0", true, false,
	"Lay a small ramp at steps up to this many units tall so the board rolls over them (0 = off, 3 = small lips)", 0, 3.5)
cvars.AddChangeCallback("skate3_lip_forgive", function() Surf.Push() end, "skate3_surfaces")

-- Fixes that ship with the addon for maps whose own collision can't be
-- skated, added to whatever the player flagged (skate3_map_fixes 0 turns them
-- off). ignore = { x, y, z, radius }: collision lying wholly inside goes.
-- ramp = { axis (0 profile runs along x, 1 along y), lo, hi (span of the other
-- axis), base (floor the sides go down to), then position, height pairs }.
local FIXES = {
	-- gumballegal's small quarter pipe is three strips with different curves
	-- (8, 12 and 4 facets), so the strips stand up to 28 units off each other
	-- near the top and the board hits a wall crossing one. One smooth profile,
	-- never lower than any strip, over all three.
	gm_grasskate_gl_csm = {
		ignore = { { -4248, -1520, 8, 240 } },
		ramp = { { 0, -1712, -1328, -40, -4312, -40, -4308, -39.53, -4304, -38.94, -4300, -38.19, -4296, -37.33, -4292, -36.44, -4288, -35.53, -4284, -34.5, -4280, -33.28, -4276, -31.83, -4272, -30.19, -4268, -28.42, -4264, -26.5, -4260, -24.31, -4256, -21.72, -4252, -18.71, -4248, -15.33, -4244, -11.53, -4240, -7.25, -4236, -2.39, -4232, 3.63, -4228, 11.46, -4224, 21.13, -4220, 32, -4216, 56, -4184, 56 } },
	},
}
local cv_fixes = CreateClientConVar("skate3_map_fixes", "1", true, false, "Use the surface fixes that ship with the addon for some maps (0 = only the ones you flagged)", 0, 1)
cvars.AddChangeCallback("skate3_map_fixes", function() Surf.Push() end, "skate3_surfaces")

-- What the skate module is told: the flat lists and the lip height (see skate3.SetSurfaces).
function Surf.Push()
	if not (skate3 and skate3.SetSurfaces) then return end
	local flat, lines, ramps = {}, {}, {}
	for _, r in ipairs(regions) do
		for _, v in ipairs({ KINDS[r.k], r.p.x, r.p.y, r.p.z, r.n.x, r.n.y, r.n.z, r.r, r.b }) do
			flat[#flat + 1] = v
		end
	end
	for _, line in ipairs(rails) do
		lines[#lines + 1] = #line
		for _, v in ipairs(line) do
			lines[#lines + 1] = v.x
			lines[#lines + 1] = v.y
			lines[#lines + 1] = v.z
		end
	end
	local fixes = cv_fixes:GetBool() and FIXES[game.GetMap()]
	if fixes then
		-- After the player's own, so the newest flag keeps its place in the notes.
		for _, g in ipairs(fixes.ignore or {}) do
			for _, v in ipairs({ KINDS.ignore, g[1], g[2], g[3], 0, 0, 1, g[4], 6 }) do flat[#flat + 1] = v end
		end
		for _, ramp in ipairs(fixes.ramp or {}) do
			for i = 1, 4 do ramps[#ramps + 1] = ramp[i] end
			ramps[#ramps + 1] = (#ramp - 4) / 2
			for i = 5, #ramp do ramps[#ramps + 1] = ramp[i] end
		end
	end
	skate3.SetSurfaces(flat, lines, lip:GetFloat(), ramps)
end

-- Says what the module made of the newest flag once it has built it.
local function Report(expect, tries)
	if not (skate3 and skate3.SurfaceNotes) then return end
	local notes = skate3.SurfaceNotes()
	if #notes < expect then
		if tries < 20 then timer.Simple(0.5, function() Report(expect, tries + 1) end) end
		return
	end
	if notes[expect] then Say(notes[expect]) end
end

local function Changed(report)
	Save()
	Surf.Push()
	if report then Report(#regions, 0) end
end

function Surf.Count()
	return #regions, #rails, #propOrder
end

-- Whether a model is one of the props flagged to be skated by its visible
-- shape (cl_props.lua asks when it picks a prop's collision).
function Surf.PropShape(model)
	return propModels[(model or ""):lower()] == true
end

-- The model of the prop at a spot: the spawned one the tool gun aimed at, or
-- else the map's own static prop standing there.
local function PropAt(pos, model)
	if model and model ~= "" then return model:lower() end
	local Props = Skate3Props
	local found = Props and Props.StaticAt and Props.StaticAt(pos)
	return found and found:lower() or nil
end

local function PropsChanged()
	if Skate3Props and Skate3Props.Invalidate then Skate3Props.Invalidate() end
end

-- A click with a flag mode: a circle at the aimed spot (flat, smooth,
-- ignore) or the next point of a rail (grind).
function Surf.Add(kind, pos, normal, radius, band, model)
	if kind == "prop" then
		local m = PropAt(pos, model)
		if not m then
			Say("No prop there. Aim at the prop itself (a ramp, a pipe) and click.")
		elseif propModels[m] then
			Say(m .. " already uses its visible shape. Right click it to take that back.")
		else
			propModels[m] = true
			propOrder[#propOrder + 1] = m
			history[#history + 1] = "prop"
			Changed(false)
			PropsChanged()
			local usable = Skate3Props and Skate3Props.CanUseShape and Skate3Props.CanUseShape(m)
			if usable == false then
				Say(m .. ": can't use its visible shape (over 6000 triangles, or it doesn't line up with its physics model), so it keeps its physics hulls.")
			else
				Say(m .. " will be skated by its visible shape from the next time this map loads.")
			end
		end
		return
	end
	if kind == "grind" then
		if #pending >= MAX_POINTS then
			Say("That rail has enough points: right click to finish it.")
			return
		end
		pending[#pending + 1] = Round(pos)
		Say(("Rail point %d. Left click for the next, right click to finish."):format(#pending))
		return
	end
	if not KINDS[kind] then return end
	if #regions >= MAX_REGIONS then
		Say("This map has all the flags it can hold.")
		return
	end
	regions[#regions + 1] = {
		k = kind, p = Round(pos), n = normal:GetNormalized(),
		r = math.Clamp(radius, 4, 2048), b = math.Clamp(band, 0.5, 64),
	}
	history[#history + 1] = "region"
	Changed(true)
end

local function SegmentDistance(p, a, b)
	local ab = b - a
	local len2 = ab:LengthSqr()
	local t = len2 > 0 and math.Clamp((p - a):Dot(ab) / len2, 0, 1) or 0
	return p:Distance(a + ab * t)
end

-- Right click: finishes the rail being drawn, or takes away the flag at the
-- aimed spot.
function Surf.Secondary(pos, model)
	if #pending >= 2 then
		rails[#rails + 1] = pending
		history[#history + 1] = "rail"
		pending = {}
		Changed(false)
		Say("Rail added.")
		return
	elseif #pending == 1 then
		pending = {}
		Say("Rail cancelled.")
		return
	end
	local best, bestKind, bestAt = math.huge
	for i, r in ipairs(regions) do
		local d = r.p:Distance(pos)
		if d <= r.r and d < best then best, bestKind, bestAt = d, "region", i end
	end
	for i, line in ipairs(rails) do
		for j = 1, #line - 1 do
			local d = SegmentDistance(pos, line[j], line[j + 1])
			if d <= 24 and d < best then best, bestKind, bestAt = d, "rail", i end
		end
	end
	if not bestKind then
		local m = #propOrder > 0 and PropAt(pos, model)
		if m and propModels[m] then
			propModels[m] = nil
			for i = #propOrder, 1, -1 do
				if propOrder[i] == m then table.remove(propOrder, i) break end
			end
			for i = #history, 1, -1 do
				if history[i] == "prop" then table.remove(history, i) break end
			end
			Changed(false)
			PropsChanged()
			Say(m .. " goes back to its physics shape from the next map load.")
			return
		end
		Say("Nothing flagged there.")
		return
	end
	if bestKind == "region" then
		table.remove(regions, bestAt)
	else
		table.remove(rails, bestAt)
	end
	-- Which of the history entries it was doesn't matter, only how many of
	-- each kind are left: take away the last one of its kind.
	for i = #history, 1, -1 do
		if history[i] == bestKind then table.remove(history, i) break end
	end
	Changed(false)
	Say("Flag removed.")
end

-- Reload: takes back the last thing drawn.
function Surf.Undo()
	if #pending > 0 then
		table.remove(pending)
		Say(#pending > 0 and ("Rail point taken back, %d left."):format(#pending) or "Rail cancelled.")
		return
	end
	local last = table.remove(history)
	if not last then
		Say("Nothing to take back.")
		return
	end
	if last == "prop" then
		local m = table.remove(propOrder)
		if m then propModels[m] = nil end
		Changed(false)
		PropsChanged()
		Say("Last prop shape taken back, from the next map load.")
		return
	end
	if last == "region" then table.remove(regions) else table.remove(rails) end
	Changed(false)
	Say("Last flag taken back.")
end

function Surf.Clear()
	regions, rails, history, pending = {}, {}, {}, {}
	propModels, propOrder = {}, {}
	Changed(false)
	PropsChanged()
end

local function ToolHeld()
	local ply = LocalPlayer()
	local wep = IsValid(ply) and ply:GetActiveWeapon()
	if not IsValid(wep) or wep:GetClass() ~= "gmod_tool" or wep:GetMode() ~= "skate3_surface" then return nil end
	return wep:GetToolObject()
end

local show = CreateClientConVar("skate3_surface_show", "0", true, false,
	"Draw this map's skate surface flags all the time, not only with the Skate 3 Surface tool out")

-- The flags in the world: circles around flat, smooth and ignore spots, lines
-- for rails. Only while the tool is out (or skate3_surface_show 1).
local function Draw(tool, tr)
	local eye = LocalPlayer():EyePos()
	render.SetColorMaterial()
	for _, r in ipairs(regions) do
		if r.p:DistToSqr(eye) < 4000 * 4000 then
			local c = Surf.COLORS[r.k]
			render.DrawWireframeSphere(r.p, r.r, 14, 10, Color(c.r, c.g, c.b, 200), true)
			render.DrawLine(r.p, r.p + r.n * 24, c, true)
		end
	end
	local g = Surf.COLORS.grind
	for _, line in ipairs(rails) do
		for i = 1, #line - 1 do
			render.DrawLine(line[i], line[i + 1], g, true)
		end
		for _, v in ipairs(line) do render.DrawWireframeSphere(v, 2, 4, 4, g, true) end
	end
	for i, v in ipairs(pending) do
		if pending[i + 1] then render.DrawLine(v, pending[i + 1], g, true) end
		render.DrawWireframeSphere(v, 2.5, 4, 4, g, true)
	end
	if tool and tr and tr.Hit then
		local mode = tool:GetClientInfo("mode")
		local c = Surf.COLORS[mode] or color_white
		if mode == "prop" then
			render.DrawWireframeSphere(tr.HitPos, 6, 6, 6, c, true)
		elseif mode == "grind" then
			if #pending > 0 then render.DrawLine(pending[#pending], tr.HitPos, c, true) end
			render.DrawWireframeSphere(tr.HitPos, 2.5, 4, 4, c, true)
		else
			render.DrawWireframeSphere(tr.HitPos, math.Clamp(tool:GetClientNumber("radius", 64), 4, 2048), 14, 10,
				Color(c.r, c.g, c.b, 90), true)
			render.DrawLine(tr.HitPos, tr.HitPos + tr.HitNormal * 24, c, true)
		end
	end
end

hook.Add("PostDrawTranslucentRenderables", "skate3_surfaces", function(depth, skybox)
	if depth or skybox then return end
	local tool = ToolHeld()
	if not tool and not show:GetBool() then return end
	Draw(tool, tool and LocalPlayer():GetEyeTrace() or nil)
end)

-- What the tool gun's server side asks this client to do.
net.Receive("skate3_surface_do", function()
	local op = net.ReadUInt(3)
	if op == 1 then
		local kind = net.ReadString()
		local pos, normal = net.ReadVector(), net.ReadVector()
		local radius, band = net.ReadFloat(), net.ReadFloat()
		Surf.Add(kind, pos, normal, radius, band, net.ReadString())
	elseif op == 2 then
		local pos = net.ReadVector()
		Surf.Secondary(pos, net.ReadString())
	elseif op == 3 then
		Surf.Undo()
	end
end)

concommand.Add("skate3_surface_list", function()
	local f, s, p = Surf.Count()
	print(("[skate3] %d surface flags, %d rails and %d prop shapes on %s (file data/%s)"):format(f, s, p, game.GetMap(), Path()))
	for i, m in ipairs(propOrder) do print(("  prop shape %d: %s"):format(i, m)) end
	for i, r in ipairs(regions) do
		print(("  %d: %s at (%.0f %.0f %.0f), radius %.0f, band %.1f"):format(i, r.k, r.p.x, r.p.y, r.p.z, r.r, r.b))
	end
	for i, line in ipairs(rails) do print(("  rail %d: %d points"):format(i, #line)) end
	if skate3 and skate3.SurfaceNotes then
		for _, note in ipairs(skate3.SurfaceNotes()) do print("  module: " .. note) end
	end
end, nil, "List this map's skate surface flags and what the skate module made of each")

concommand.Add("skate3_surface_clear", function()
	Surf.Clear()
	Say("All of this map's surface flags are gone.")
end, nil, "Remove every skate surface flag on this map")

concommand.Add("skate3_surface_undo", function() Surf.Undo() end, nil, "Take back the last skate surface flag")

-- Re-reads the file after someone else's was dropped in.
concommand.Add("skate3_surface_reload", function()
	Surf.Load()
	Surf.Push()
	PropsChanged()
	local f, s, p = Surf.Count()
	Say(("Read %d surface flags, %d rails and %d prop shapes for this map."):format(f, s, p))
end, nil, "Read this map's skate surface flags from their file again")

Surf.Load()

return Surf
