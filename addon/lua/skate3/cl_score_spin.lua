-- Spin degrees in trick names, by Skate 3's own rules. Read off the retail
-- game's trick-name builder (the 360 executable's function at 825CC880 in
-- memory): the HUD's trick name is "#%s %d", the trick's
-- name and the jump's spin in degrees, or "#%s" with no spin.
--
--   * A trick with a spin: its own name, then the degrees. No frontside or
--     backside: "Kickflip 360", "Melon 540".
--   * Left the ground riding fakie: the trick gets the Half-Cab or Cab named
--     after it, frontside or backside. A half turn is the Half-Cab alone (it
--     is the 180), more says the degrees too: "Kickflip FS Half-Cab",
--     "Heelflip BS Cab 360", "Kickflip FS Cab 540". Not when riding switch as
--     well, and not for a trick whose own name is already a fakie one.
--   * A spin with no trick: the frontside or backside spin's name and the
--     degrees ("FS 360"), or the Half-Cab / Cab alone off fakie.
--
-- The names themselves are the disc's (tricks.json, through `lookup`), with
-- English stand-ins when setup didn't copy them.

local Spin = {}

local FALLBACK = {
	ID_TRICK_AIR_FS_SPIN = "FS",
	ID_TRICK_AIR_BS_SPIN = "BS",
	ID_TRICK_AUTHENTIC_FS_HALFCAB = "FS Half-Cab",
	ID_TRICK_AUTHENTIC_BS_HALFCAB = "BS Half-Cab",
	ID_TRICK_AUTHENTIC_FS_CAB = "FS Cab",
	ID_TRICK_AUTHENTIC_BS_CAB = "BS Cab",
}

-- Trick names that already say the trick left fakie, so no Cab goes after them.
local function AlreadyFakie(name)
	local lower = name:lower()
	return lower:find("fakie", 1, true) or lower:find("cab", 1, true)
end

-- Frontside: the skater's chest turns towards where they're going first.
-- Riding forward in regular stance, the skater faces the board's right
-- (looking along the nose), so frontside turns the board counter-clockwise
-- seen from above: a positive spin. Goofy, fakie and switch each mirror that.
function Spin.Frontside(spin, goofy, fakie, switch)
	local fs = spin > 0
	if goofy then fs = not fs end
	if fakie then fs = not fs end
	if switch then fs = not fs end
	return fs
end

-- `base` is the trick's name, or nil for a spin with no trick. `spin` is in
-- whole half turns, signed counter-clockwise from above. opts: `name(id)`
-- returns the disc's text for a label or nil; `goofy` is the natural stance;
-- `fakie` and `switch` are how the jump left the ground; `flip` inverts frontside and backside
-- (skate3_spin_flip), in case the engine's heading turns out the other way.
-- Returns nil when there is nothing to name.
function Spin.Name(base, spin, opts)
	opts = opts or {}
	local name = opts.name or function() return nil end
	local function Text(id) return name(id) or FALLBACK[id] end
	spin = spin or 0
	local turns = math.abs(spin)
	if turns == 0 then return base end
	local fs = Spin.Frontside(spin, opts.goofy, opts.fakie, opts.switch)
	if opts.flip then fs = not fs end
	local side = fs and "FS" or "BS"
	local cab = opts.fakie and not opts.switch and not (base and AlreadyFakie(base))
	local text = base
	if cab then
		local id = "ID_TRICK_AUTHENTIC_" .. side .. (turns == 1 and "_HALFCAB" or "_CAB")
		text = base and (base .. " " .. Text(id)) or Text(id)
	elseif not base then
		text = Text("ID_TRICK_AIR_" .. side .. "_SPIN")
	end
	-- The Half-Cab is the 180 itself; everything else says its degrees.
	if not (cab and turns == 1) then
		text = text .. " " .. (turns * 180)
	end
	return text
end

return Spin
