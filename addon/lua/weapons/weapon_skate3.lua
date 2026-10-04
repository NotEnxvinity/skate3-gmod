-- The skateboard as a weapon: equip it to carry the board, then drop it to
-- ride. The riding itself lives in skate3/cl_skate3.lua, which watches for it.

SWEP.PrintName = "Skateboard"
SWEP.Category = "Skate 3"
SWEP.Purpose = "Carry your board; drop it to ride."
SWEP.Instructions = "Y on your controller or left click: drop the board and ride. Y again: pick it up. Needs a controller to skate."
SWEP.Spawnable = true
SWEP.Slot = 5
SWEP.SlotPos = 1

SWEP.ViewModel = ""
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

-- The skate mode draws the board, in hand or under the skater.
function SWEP:DrawWorldModel() end
