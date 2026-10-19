-- The Skate 3 Surface tool: tells the skate collision what a surface should
-- be where the map's own collision gets in a board's way. Left click flags
-- the spot you aim at in the chosen mode, right click takes a flag away (or
-- finishes a rail), reload takes back the last one. The flags are kept per
-- map in data/skate3/surfaces and only change your own skating.

TOOL.Category = "Skate 3"
TOOL.Name = "#tool.skate3_surface.name"
TOOL.ClientConVar = {
	mode = "flat",
	radius = "64",
	band = "6",
}
TOOL.Information = {
	{ name = "left" },
	{ name = "right" },
	{ name = "reload" },
}

local MODES = { flat = true, smooth = true, ignore = true, grind = true }

-- Asks the player's own client to do it: the flags and the skate module live
-- there.
local function Tell(ply, op, write)
	net.Start("skate3_surface_do")
	net.WriteUInt(op, 3)
	if write then write() end
	net.Send(ply)
end

function TOOL:LeftClick(tr)
	if not tr.Hit then return false end
	if CLIENT then return true end
	local mode = self:GetClientInfo("mode")
	if not MODES[mode] then mode = "flat" end
	local radius = math.Clamp(self:GetClientNumber("radius", 64), 4, 2048)
	local band = math.Clamp(self:GetClientNumber("band", 6), 0.5, 64)
	Tell(self:GetOwner(), 1, function()
		net.WriteString(mode)
		net.WriteVector(tr.HitPos)
		net.WriteVector(tr.HitNormal)
		net.WriteFloat(radius)
		net.WriteFloat(band)
	end)
	return true
end

function TOOL:RightClick(tr)
	if CLIENT then return true end
	Tell(self:GetOwner(), 2, function() net.WriteVector(tr.HitPos) end)
	return true
end

function TOOL:Reload()
	if CLIENT then return true end
	Tell(self:GetOwner(), 3)
	return true
end

if SERVER then return end

language.Add("tool.skate3_surface.name", "Skate 3 Surface")
language.Add("tool.skate3_surface.desc", "Fix a map's collision for skating: flatten a bumpy floor, smooth a ramp, ignore clutter, draw a rail")
language.Add("tool.skate3_surface.left", "Flag the spot (grind mode: add a rail point)")
language.Add("tool.skate3_surface.right", "Take a flag away (grind mode: finish the rail)")
language.Add("tool.skate3_surface.reload", "Take back the last flag")

local HINTS = {
	flat = "Flat: bumps and small steps in the circle are pressed onto one plane.",
	smooth = "Smooth: the circle's surface keeps its curve and loses its bumps.",
	ignore = "Ignore: pieces of collision inside the circle aren't solid for skating.",
	grind = "Grind: click along an edge, right click to finish the rail.",
}

function TOOL:DrawHUD()
	local mode = self:GetClientInfo("mode")
	local Surf = Skate3Surfaces
	local flags, rails = 0, 0
	if Surf then flags, rails = Surf.Count() end
	local c = Surf and Surf.COLORS[mode] or color_white
	draw.SimpleTextOutlined(HINTS[mode] or "", "DermaDefaultBold", ScrW() / 2, ScrH() * 0.62, c,
		TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 2, color_black)
	draw.SimpleTextOutlined(("%d flags, %d rails on this map"):format(flags, rails), "DermaDefault", ScrW() / 2,
		ScrH() * 0.62 + 18, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
end

function TOOL.BuildCPanel(panel)
	panel:Help("Some maps are nearly impossible to do tricks on because of how the map's collision is built. "
		.. "Aim at the spot, pick what it should be, and click. The skate collision for this map is rebuilt with it. "
		.. "Only your own skating changes.")
	local combo = panel:ComboBox("What the spot is", "skate3_surface_mode")
	combo:AddChoice("Flat (bumps and small steps)", "flat")
	combo:AddChoice("Smooth ramp (keeps the curve)", "smooth")
	combo:AddChoice("Ignore (not solid for skating)", "ignore")
	combo:AddChoice("Grind rail (click along an edge)", "grind")
	panel:NumSlider("Circle size", "skate3_surface_radius", 16, 512, 0)
	panel:NumSlider("Reach (keep under the floor's thickness)", "skate3_surface_band", 1, 24, 1)
	panel:CheckBox("Show this map's flags all the time", "skate3_surface_show")
	panel:Button("List this map's flags", "skate3_surface_list")
	panel:Button("Read the flags file again", "skate3_surface_reload")
	panel:Button("Remove every flag on this map", "skate3_surface_clear")
	panel:Help("The flags live in garrysmod/data/skate3/surfaces/<map>.json. Send that file to share them; "
		.. "whoever gets it drops it in the same folder and runs skate3_surface_reload.")
end
