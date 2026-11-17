-- lua5.1 tools/lua-tests/spin-names.lua addon/lua/skate3/cl_score_spin.lua
local Spin = dofile(arg[1])
local n = 0
local function eq(got, want) n = n + 1; if got ~= want then error(("case %d: got %q want %q"):format(n, tostring(got), tostring(want)), 2) end end
local function o(t) t = t or {}; t.goofy = t.goofy or false; return t end
eq(Spin.Name("Kickflip", 0, o()), "Kickflip")
eq(Spin.Name("Kickflip", 2, o()), "Kickflip 360")
eq(Spin.Name("Kickflip", -1, o()), "Kickflip 180")
eq(Spin.Name("Melon", 3, o()), "Melon 540")
eq(Spin.Name(nil, 0, o()), nil)
eq(Spin.Name(nil, 2, o()), "FS 360")       -- regular, CCW = frontside
eq(Spin.Name(nil, -2, o()), "BS 360")
eq(Spin.Name(nil, 2, o{ goofy = true }), "BS 360")
eq(Spin.Name(nil, 2, o{ switch = true }), "BS 360")
eq(Spin.Name(nil, 2, o{ flip = true }), "BS 360")
-- off fakie: Half-Cab / Cab, direction mirrored
eq(Spin.Name("Kickflip", 1, o{ fakie = true }), "Kickflip BS Half-Cab")
eq(Spin.Name("Kickflip", -1, o{ fakie = true }), "Kickflip FS Half-Cab")
eq(Spin.Name("Heelflip", 2, o{ fakie = true }), "Heelflip BS Cab 360")
eq(Spin.Name("Kickflip", -3, o{ fakie = true }), "Kickflip FS Cab 540")
eq(Spin.Name(nil, -1, o{ fakie = true }), "FS Half-Cab")
eq(Spin.Name(nil, -2, o{ fakie = true }), "FS Cab 360")
-- fakie and switch: no Cab
eq(Spin.Name("Kickflip", 2, o{ fakie = true, switch = true }), "Kickflip 360")
-- trick already a fakie one
eq(Spin.Name("Fakie Kickflip", 1, o{ fakie = true }), "Fakie Kickflip 180")
-- disc names win
eq(Spin.Name(nil, 2, o{ name = function(id) return id == "ID_TRICK_AIR_FS_SPIN" and "Frontside" or nil end }), "Frontside 360")
eq(Spin.Name("Ollie", 4, o()), "Ollie 720")
print(n .. " spin naming cases pass")
