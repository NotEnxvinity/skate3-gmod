-- The Skate 3 Park tool: places the park piece picked in the "Skate 3 Park"
-- spawn tab where you aim, showing a ghost of it first. Right click turns it,
-- reload puts the turn back.

TOOL.Category = "Skate 3"
TOOL.Name = "#tool.skate3_park.name"
TOOL.ClientConVar = {
	piece = "",
	yaw = "0",
	grid = "0",
}
TOOL.Information = {
	{ name = "left" },
	{ name = "right" },
	{ name = "reload" },
}

local STEP = 45

-- Where the piece goes for this aim: on whatever the trace hit, facing back
-- at the player plus the tool's own turn, optionally snapped to a grid (in
-- metres) so pieces line up.
local function Placement(tool, tr)
	local ply = tool:GetOwner()
	local pos = tr.HitPos
	local grid = tool:GetClientNumber("grid", 0) * 39.3701
	if grid > 0 then
		pos = Vector(math.Round(pos.x / grid) * grid, math.Round(pos.y / grid) * grid, pos.z)
	end
	local yaw = math.Round(ply:EyeAngles().y / 15) * 15 + 180 + tool:GetClientNumber("yaw", 0)
	return pos, Angle(0, yaw, 0)
end

function TOOL:LeftClick(tr)
	if not tr.Hit then return false end
	if CLIENT then return true end
	local Park = Skate3Park
	local id = self:GetClientInfo("piece")
	if not Park or id == "" then
		self:GetOwner():ChatPrint("[skate3] Pick a piece in the Skate 3 Park tab of the spawn menu first.")
		return false
	end
	local pos, ang = Placement(self, tr)
	return IsValid(Park.Spawn(self:GetOwner(), id, pos, ang))
end

function TOOL:RightClick()
	if SERVER then
		local yaw = (self:GetClientNumber("yaw", 0) + STEP) % 360
		self:GetOwner():ConCommand("skate3_park_yaw " .. yaw)
	end
	return false
end

function TOOL:Reload()
	if SERVER then self:GetOwner():ConCommand("skate3_park_yaw 0") end
	return false
end

if SERVER then return end

language.Add("tool.skate3_park.name", "Skate 3 Park")
language.Add("tool.skate3_park.desc", "Place Skate 3's create-a-park pieces")
language.Add("tool.skate3_park.left", "Place the piece")
language.Add("tool.skate3_park.right", "Turn it " .. STEP .. " degrees")
language.Add("tool.skate3_park.reload", "Undo the turn")

-- The ghost: the piece's own meshes, drawn see-through where it would land.
local ghost = CreateMaterial("skate3park_ghost", "UnlitGeneric", {
	["$basetexture"] = "color/white",
	["$color"] = "[0.35 0.8 1]",
	["$alpha"] = "0.35",
	["$translucent"] = "1",
	["$nocull"] = "1",
})

hook.Add("PostDrawTranslucentRenderables", "skate3_park_ghost", function(depth, skybox)
	if depth or skybox then return end
	local ply = LocalPlayer()
	local wep = IsValid(ply) and ply:GetActiveWeapon()
	if not IsValid(wep) or wep:GetClass() ~= "gmod_tool" or wep:GetMode() ~= "skate3_park" then return end
	local tool = wep:GetToolObject()
	local Park = Skate3Park
	if not tool or not Park or not Park.Meshes then return end
	local meshes = Park.Meshes(tool:GetClientInfo("piece"))
	if not meshes then return end
	local tr = ply:GetEyeTrace()
	if not tr.Hit then return end
	local pos, ang = Placement(tool, tr)
	local m = Matrix()
	m:SetTranslation(pos)
	m:SetAngles(ang)
	cam.PushModelMatrix(m)
	render.SetMaterial(ghost)
	for _, part in ipairs(meshes) do part.mesh:Draw() end
	cam.PopModelMatrix()
end)

function TOOL:DrawHUD()
	local Park = Skate3Park
	local index = Park and Park.Index()
	local info = index and index[self:GetClientInfo("piece")]
	local text = info and info.name or "No piece picked: open the Skate 3 Park tab"
	draw.SimpleTextOutlined(text, "DermaLarge", ScrW() / 2, ScrH() * 0.62, color_white,
		TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 2, color_black)
end

function TOOL.BuildCPanel(panel)
	panel:Help("Pick a piece in the Skate 3 Park tab of the spawn menu (hold Q), then place it with the tool gun. "
		.. "Pieces stay frozen; move them with the physgun.")
	panel:NumSlider("Turn", "skate3_park_yaw", 0, 345, 0)
	panel:NumSlider("Grid snap (metres, 0 = off)", "skate3_park_grid", 0, 12, 0)
end
