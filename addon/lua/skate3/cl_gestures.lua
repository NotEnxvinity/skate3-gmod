-- Skate 3's D-pad gestures. Tap a direction while skating (or on foot) and
-- the skater plays the gesture picked for it: air guitar, devil horns, a
-- shaka... These are retail's own animations from the player's disc, played
-- by the engine's own CharacterGesture (TU3 82BAA320): it uses whichever
-- hands are free, so grabbing with one hand gestures with the other, and
-- each gesture has an into / loop / out part (hold the direction to keep it
-- going). Nothing fires while L1 or R1 is down, as in retail, so the
-- contextual menu keeps the D-pad.
--
-- This file keeps the player's four picks (convars, saved with the other
-- settings) and hands them to the module. The phone menu's Settings and the
-- spawn menu both list them.

S3GM_Gestures = S3GM_Gestures or {}
local G = S3GM_Gestures

-- Skate 3's gesture catalog in table order (82F881D0, B_GSTR_* animation
-- prefixes): the module wants the 0-based index. Names are ours.
G.LIST = {
	{ "airguitar", "Air Guitar" },
	{ "airplane", "Airplane" },
	{ "boxing", "Boxing" },
	{ "bruce_lee", "Bruce Lee" },
	{ "checktime", "Check The Time" },
	{ "devil", "Devil Horns" },
	{ "dble_gun", "Finger Guns" },
	{ "dunno", "Dunno" },
	{ "fingerwag", "Finger Wag" },
	{ "fists", "Fists Up" },
	{ "bicepflex", "Bicep Flex" },
	{ "fliptable", "Flip The Table" },
	{ "fonz_eh", "The Fonz" },
	{ "freedom", "Freedom" },
	{ "fu_fist", "Up Yours" },
	{ "getaway", "Get Away" },
	{ "getouttahere", "Get Outta Here" },
	{ "handcuffs", "Handcuffs" },
	{ "highpump", "High Pump" },
	{ "lowpump", "Low Pump" },
	{ "prewind", "Rewind" },
	{ "peace", "Peace" },
	{ "point", "Point" },
	{ "raiseroof", "Raise The Roof" },
	{ "shaka", "Shaka" },
	{ "shrug", "Shrug" },
	{ "point_sky", "Point To The Sky" },
	{ "snap", "Snap" },
	{ "soularch", "Soul Arch" },
	{ "spock", "Spock" },
	{ "surfsup", "Surf's Up" },
	{ "swinghigh", "Swing High" },
	{ "swinglow", "Swing Low" },
	{ "throwarms", "Throw Arms" },
	{ "thmb_dwn", "Thumbs Down" },
	{ "wings", "Wings" },
	{ "yardsale", "Yard Sale" },
}
local BY_ID = {}
for i, g in ipairs(G.LIST) do BY_ID[g[1]] = i end

-- Up, Down, Left, Right, the order the module takes them in. Retail's
-- default (ResetGestureSet 824FA730) is the catalog's first four.
G.DIRECTIONS = {
	{ "up", "Up", "airguitar" },
	{ "down", "Down", "airplane" },
	{ "left", "Left", "boxing" },
	{ "right", "Right", "bruce_lee" },
}

local cv_on = CreateClientConVar("skate3_gestures", "1", true, false,
	"D-pad gestures while skating, Skate 3's own (1 on, 0 off: the D-pad does nothing without L1)")
G.CONVARS = { "skate3_gestures" }
local cvs = {}
for _, d in ipairs(G.DIRECTIONS) do
	local name = "skate3_gesture_" .. d[1]
	cvs[#cvs + 1] = CreateClientConVar(name, d[3], true, false,
		"The gesture on D-pad " .. d[2]:lower() .. ": one of skate3_gesture_list's names, or its number")
	G.CONVARS[#G.CONVARS + 1] = name
end

-- A convar's gesture, as a 1-based index into G.LIST (a name or a number).
local function Pick(cv, fallback)
	local v = string.lower(string.Trim(cv:GetString()))
	local n = tonumber(v)
	if n and G.LIST[math.floor(n) + 1] and n >= 0 then return math.floor(n) + 1 end
	return BY_ID[v] or BY_ID[fallback]
end

-- The four picks, 1-based.
function G.Picks()
	local out = {}
	for i, d in ipairs(G.DIRECTIONS) do out[i] = Pick(cvs[i], d[3]) end
	return out
end

function G.Name(index)
	local g = G.LIST[index]
	return g and g[2] or "?"
end

function G.Enabled()
	return cv_on:GetBool()
end

-- Hand shapes, made by the setup from the disc (setup/gestures.py): per
-- gesture id, { R = { thumb, index, middle, ring, pinky }, L = ... }, each
-- finger { j1, j2, j3 } in degrees towards the palm. Nil per gesture until
-- the setup has run; the hands stay relaxed then.
local HANDS = "skate3/assets/gestures/hands.json"
local shapes
function G.HandShape(index)
	if shapes == nil then
		local t = util.JSONToTable(file.Read(HANDS, "DATA") or "")
		shapes = istable(t) and istable(t.gestures) and t.gestures or false
		if not shapes then print("[skate3] no gesture hand shapes yet (run the S3GM setup again); hands stay relaxed") end
	end
	local g = shapes and G.LIST[index]
	return g and shapes[g[1]]
end

-- The module's copy. Kept across rides; sent again whenever a pick changes.
local warned = false
function G.Push()
	if not skate3 then return end
	if not skate3.SetGestures then
		if not warned then
			warned = true
			print("[skate3] this skate module has no D-pad gestures yet; run the S3GM setup again for the new one")
		end
		return
	end
	local p = G.Picks()
	skate3.SetGestures(p[1] - 1, p[2] - 1, p[3] - 1, p[4] - 1)
end

for _, name in ipairs(G.CONVARS) do
	cvars.AddChangeCallback(name, function() G.Push() end, "skate3_gestures")
end

concommand.Add("skate3_gesture_list", function()
	print("Skate 3 gestures (set with skate3_gesture_up/down/left/right <name>):")
	for i, g in ipairs(G.LIST) do print(string.format("  %2d  %-14s %s", i - 1, g[1], g[2])) end
	local p = G.Picks()
	print(string.format("Now: up %s, down %s, left %s, right %s%s", G.Name(p[1]), G.Name(p[2]),
		G.Name(p[3]), G.Name(p[4]), G.Enabled() and "" or " (gestures are off: skate3_gestures 1)"))
end)

return G
