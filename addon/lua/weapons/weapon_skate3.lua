-- The skateboard as a weapon: equip it for skate mode, board in hand.
-- The riding itself lives in skate3/cl_skate3.lua, which watches for it.

SWEP.PrintName = "Skateboard"
SWEP.Category = "Skate 3"
SWEP.Purpose = "Skate 3 mode: start on foot with your board, Y to get on."
SWEP.Instructions = "Needs a controller. Y gets on and off the board, A pushes. Switch weapons to leave skate mode."
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

-- The skate mode draws the board under the skater.
function SWEP:DrawWorldModel() end
