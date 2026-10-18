-- The skateboard as a weapon: equip it for skate mode.
-- The riding itself lives in skate3/cl_skate3.lua, which watches for it.

SWEP.PrintName = "Skateboard"
SWEP.Category = "Skate 3"
SWEP.Purpose = "Skate 3 mode: start on the board, Y to get off and on."
SWEP.Instructions = "Needs a controller. Y gets off and on the board, A pushes. Switch weapons to leave skate mode."
SWEP.Spawnable = true
SWEP.Slot = 5
SWEP.SlotPos = 1

-- A real (empty-handed) view model, never drawn: with none, Gmod's hands,
-- which follow the view model, spammed the console with "MOVETYPE_FOLLOW
-- entity (gmod_hands) is parented to entity (viewmodel) with no model".
SWEP.ViewModel = "models/weapons/c_arms.mdl"
SWEP.WorldModel = ""
SWEP.UseHands = false
SWEP.DrawAmmo = false
SWEP.DrawCrosshair = false

SWEP.Primary.ClipSize = -1
SWEP.Primary.DefaultClip = -1
SWEP.Primary.Automatic = false
SWEP.Primary.Ammo = "none"
SWEP.Secondary = SWEP.Primary

function SWEP:Initialize()
	self:SetHoldType("normal")
end

function SWEP:PrimaryAttack() end
function SWEP:SecondaryAttack() end

-- The skate mode draws the board under the skater.
function SWEP:DrawWorldModel() end

if CLIENT then
	function SWEP:PreDrawViewModel() return true end

	-- Nor the hands while the board is out.
	hook.Add("PreDrawPlayerHands", "skate3_no_hands", function(_, _, ply, weapon)
		if IsValid(weapon) and weapon:GetClass() == "weapon_skate3" then return true end
	end)

	-- The weapon switcher's picture: a board, in the HUD's colour like HL2's.
	-- The spawn menu's comes from materials/entities/weapon_skate3.png.
	local icon = Material("skate3/weapon_select.png", "smooth")

	function SWEP:DrawWeaponSelection(x, y, wide, tall, alpha)
		local w = math.min(wide, tall * 2) * 0.9
		local h = w / 2
		surface.SetMaterial(icon)
		surface.SetDrawColor(255, 220, 0, alpha)
		surface.DrawTexturedRect(x + (wide - w) / 2, y + (tall - h) / 2, w, h)
		self:PrintWeaponInfo(x + wide + 20, y + tall * 0.95, alpha)
	end
end
