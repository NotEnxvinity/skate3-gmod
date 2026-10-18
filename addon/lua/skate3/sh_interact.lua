-- Using doors, buttons and the like with the board out. The use key does
-- nothing while skating, so the player's game works out what is in front of
-- the skater (this file, to tell the menu what's there) and the server uses
-- it for them (sv_skate3.lua, which runs the same search itself).

local Interact = {}

-- How far ahead of the skater's chest a door or button can be.
Interact.REACH = 130
-- How far off straight ahead it can be (cosine of the angle).
local CONE = 0.3

-- Map entities worth using; scripted ones count if they define Use.
local CLASSES = {
	func_door = true, func_door_rotating = true, prop_door_rotating = true,
	func_button = true, func_rot_button = true, momentary_rot_button = true,
	func_lookdoor = true,
}

function Interact.Usable(ent)
	if not IsValid(ent) or ent:IsWorld() then return false end
	if ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() or ent:IsWeapon() or ent:IsVehicle() or ent:IsRagdoll() then return false end
	local class = ent:GetClass()
	if CLASSES[class] then return true end
	-- Only what a script made: every entity has a Use, scripted or not.
	return scripted_ents.GetMember(class, "Use") ~= nil
end

-- What the skater at `origin` (chest height) heading `dir` (a unit vector)
-- would use: whatever is right in front first, then the nearest in reach
-- that's more or less ahead. `filter` is left out of the trace (the player).
function Interact.Find(origin, dir, filter)
	local reach = Interact.REACH
	local tr = util.TraceHull({
		start = origin, endpos = origin + dir * reach,
		mins = Vector(-14, -14, -20), maxs = Vector(14, 14, 20),
		filter = filter, mask = MASK_SOLID,
	})
	if Interact.Usable(tr.Entity) then return tr.Entity end
	local best, bestScore
	for _, ent in ipairs(ents.FindInSphere(origin + dir * (reach * 0.5), reach)) do
		if Interact.Usable(ent) then
			-- Wide doors: the nearest part counts, not the middle.
			local to = ent:NearestPoint(origin) - origin
			local dist = to:Length()
			local facing = dist > 1 and dir:Dot(to) / dist or 1
			if dist <= reach and facing >= CONE then
				local score = dist * (2 - facing)
				if not bestScore or score < bestScore then best, bestScore = ent, score end
			end
		end
	end
	return best
end

return Interact
