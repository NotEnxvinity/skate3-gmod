-- Player fixes to this map's skate collision, made with the Skate 3 Surface
-- tool. Maps are built for walking, so a bumpy floor, a one-inch lip between
-- two brushes or a pipe with a crude hull can stop a board dead. A flag says
-- what the surface there should be:
--   flat    one plane (bumps and small steps pressed out)
--   smooth  one gentle curve (ramps, banks, pipes keep their shape)
--   ignore  pieces of collision inside the circle aren't solid for skating
--   grind   a rail drawn point by point
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
	ignore = Color(255, 90, 90),
	grind = Color(255, 210, 60),
}

local regions = {} -- { k = "flat", p = Vector, n = Vector, r = radius, b = band }
local rails = {} -- { Vector, Vector, ... }
local history = {} -- "region" or "rail", in the order they were added
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
	local raw = file.Read(Path(), "DATA") or file.Read("data_static/" .. Path(), "GAME")
	local data = raw and util.JSONToTable(raw)
	if type(data) ~= "table" then return end
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
	if #list == 0 and #lines == 0 then
		if file.Exists(Path(), "DATA") then file.Delete(Path()) end
		return
	end
	file.CreateDir("skate3")
	file.CreateDir(DIR)
	file.Write(Path(), util.TableToJSON({ version = 1, map = game.GetMap(), regions = list, rails = lines }, true))
end

-- Experimental and off by default: ramps laid at steps this many units tall or
-- less, such as where two brushes meet a unit or two out of line. Nothing is
-- cut away, so no floor can open up; it only adds a slope in front of the step.
local lip = CreateClientConVar("skate3_lip_forgive", "0", true, false,
	"Lay a small ramp at steps up to this many units tall so the board rolls over them (0 = off, 3 = small lips)", 0, 3.5)
cvars.AddChangeCallback("skate3_lip_forgive", function() Surf.Push() end, "skate3_surfaces")

-- What the skate module is told: two flat lists and the lip height (see skate3.SetSurfaces).
function Surf.Push()
	if not (skate3 and skate3.SetSurfaces) then return end
	local flat, lines = {}, {}
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
	skate3.SetSurfaces(flat, lines, lip:GetFloat())
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
	return #regions, #rails
end

-- A click with a flag mode: a circle at the aimed spot (flat, smooth,
-- ignore) or the next point of a rail (grind).
function Surf.Add(kind, pos, normal, radius, band)
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
function Surf.Secondary(pos)
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
	if last == "region" then table.remove(regions) else table.remove(rails) end
	Changed(false)
	Say("Last flag taken back.")
end

function Surf.Clear()
	regions, rails, history, pending = {}, {}, {}, {}
	Changed(false)
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
		if mode == "grind" then
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
		Surf.Add(kind, pos, normal, radius, band)
	elseif op == 2 then
		Surf.Secondary(net.ReadVector())
	elseif op == 3 then
		Surf.Undo()
	end
end)

concommand.Add("skate3_surface_list", function()
	local f, s = Surf.Count()
	print(("[skate3] %d surface flags and %d rails on %s (file data/%s)"):format(f, s, game.GetMap(), Path()))
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
	local f, s = Surf.Count()
	Say(("Read %d surface flags and %d rails for this map."):format(f, s))
end, nil, "Read this map's skate surface flags from their file again")

Surf.Load()

return Surf
