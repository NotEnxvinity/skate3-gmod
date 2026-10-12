-- skate3_collision_report: what the skate collision has in front of you.
-- Aim at an invisible wall (or at something the board goes through) and run
-- it: it lists every brush of the map along your aim, with its contents,
-- texture and the entity that owns it, next to what Garry's Mod's own trace
-- hits there. Written to data/skate3/collision_report.txt too.

local REACH = 600

local function U16(s, at)
	local a, b = s:byte(at, at + 1)
	return a + b * 256
end

local function I16(s, at)
	local n = U16(s, at)
	return n >= 32768 and n - 65536 or n
end

local function I32(s, at)
	local a, b, c, d = s:byte(at, at + 3)
	local n = a + b * 256 + c * 65536 + d * 16777216
	return n >= 2147483648 and n - 4294967296 or n
end

local function F32(s, at)
	local a, b, c, d = s:byte(at, at + 3)
	local sign = d >= 128 and -1 or 1
	local exp = (d % 128) * 2 + math.floor(c / 128)
	local mant = (c % 128) * 65536 + b * 256 + a
	if exp == 0 then return sign * mant * 2 ^ -149 end
	if exp == 255 then return 0 end
	return sign * (1 + mant / 8388608) * 2 ^ (exp - 127)
end

local CONTENTS = {
	[0x1] = "solid", [0x2] = "window", [0x4] = "aux", [0x8] = "grate", [0x10] = "slime",
	[0x20] = "water", [0x40] = "blocklos", [0x80] = "opaque", [0x4000] = "ignore_nodraw_opaque",
	[0x8000] = "areaportal", [0x10000] = "playerclip", [0x20000] = "monsterclip",
	[0x4000000] = "debris", [0x8000000] = "detail", [0x10000000] = "translucent",
	[0x20000000] = "ladder", [0x40000000] = "hitbox", [0x2000000] = "monster",
}
local SKATE_SOLID = bit.bor(0x1, 0x2, 0x8, 0x10000)

local function ContentNames(c)
	local out = {}
	for flag, name in SortedPairs(CONTENTS) do
		if bit.band(c, flag) ~= 0 then out[#out + 1] = name end
	end
	return #out > 0 and table.concat(out, "+") or "empty"
end

local function Lump(bsp, i)
	local at = 9 + i * 16
	return I32(bsp, at) + 1, I32(bsp, at + 4)
end

local function Report()
	local ply = LocalPlayer()
	local f = file.Open("maps/" .. game.GetMap() .. ".bsp", "rb", "GAME")
	local bsp = f and f:Read(f:Size())
	if f then f:Close() end
	if not bsp or bsp:sub(1, 4) ~= "VBSP" then print("[skate3] couldn't read this map's .bsp") return end
	local version = I32(bsp, 5)
	local lines = {}
	local function Say(s) lines[#lines + 1] = s print("[skate3] " .. s) end

	local origin, dir = ply:EyePos(), ply:GetAimVector()
	Say(("map %s (bsp v%d), looking from %s along %s"):format(game.GetMap(), version, tostring(origin), tostring(dir)))

	-- Entities: which brush model belongs to which entity.
	local eo, el = Lump(bsp, 0)
	local owners = {}
	for block in bsp:sub(eo, eo + el - 1):gmatch("{(.-)}") do
		local kv = {}
		for k, v in block:gmatch('"([^"]*)"%s*"([^"]*)"') do kv[k:lower()] = v end
		local n = kv.model and tonumber(kv.model:match("^%*(%d+)$"))
		if n then
			owners[n] = ("%s%s (spawnflags %s%s%s)"):format(kv.classname or "?",
				kv.targetname and (" '" .. kv.targetname .. "'") or "", kv.spawnflags or "0",
				kv.solidity and (", solidity " .. kv.solidity) or "",
				kv.startdisabled and (", startdisabled " .. kv.startdisabled) or "")
		end
	end

	-- Which model owns each brush, from each model's tree.
	local mo = Lump(bsp, 14)
	local no = Lump(bsp, 5)
	local lo = Lump(bsp, 10)
	local lbo = Lump(bsp, 17)
	local _, ml = Lump(bsp, 14)
	local stride = version == 19 and 56 or 32
	local brushModel = {}
	for m = 0, ml / 48 - 1 do
		local stack, seen = { I32(bsp, mo + m * 48 + 36) }, {}
		while #stack > 0 do
			local child = table.remove(stack)
			if child >= 0 then
				if not seen[child] then
					seen[child] = true
					stack[#stack + 1] = I32(bsp, no + child * 32 + 4)
					stack[#stack + 1] = I32(bsp, no + child * 32 + 8)
				end
			else
				local leaf = lo + (-1 - child) * stride
				local first, count = U16(bsp, leaf + 24), U16(bsp, leaf + 26)
				for i = first, first + count - 1 do
					local b = U16(bsp, lbo + i * 2)
					if brushModel[b] == nil then brushModel[b] = m end
				end
			end
		end
	end

	-- Texture names, per texinfo.
	local tio = Lump(bsp, 6)
	local tdo = Lump(bsp, 2)
	local sto = Lump(bsp, 44)
	local sdo = Lump(bsp, 43)
	local function Texture(texinfo)
		if texinfo < 0 then return "(none)" end
		local td = I32(bsp, tio + texinfo * 72 + 68)
		local id = I32(bsp, tdo + td * 32 + 12)
		local at = sdo + I32(bsp, sto + id * 4)
		return bsp:sub(at, at + 127):match("^[^%z]*")
	end

	-- Every brush the aim line passes through.
	local po = Lump(bsp, 1)
	local bo, bl = Lump(bsp, 18)
	local so = Lump(bsp, 19)
	local hits = {}
	for b = 0, bl / 12 - 1 do
		local first, count, contents = I32(bsp, bo + b * 12), I32(bsp, bo + b * 12 + 4), I32(bsp, bo + b * 12 + 8)
		local tmin, tmax, face = 0, REACH, nil
		for s = first, first + count - 1 do
			local side = so + s * 8
			local p = po + U16(bsp, side) * 20
			local n = Vector(F32(bsp, p), F32(bsp, p + 4), F32(bsp, p + 8))
			local d = F32(bsp, p + 12)
			local denom, dist = n:Dot(dir), d - n:Dot(origin)
			if math.abs(denom) < 1e-6 then
				if dist < 0 then tmin = math.huge break end
			else
				local t = dist / denom
				if denom > 0 then tmax = math.min(tmax, t)
				elseif t > tmin then tmin, face = t, side end
			end
			if tmin > tmax then break end
		end
		if tmin <= tmax then
			hits[#hits + 1] = { t = tmin, brush = b, contents = contents, face = face }
		end
	end
	table.sort(hits, function(a, b) return a.t < b.t end)

	local tr = util.TraceLine({ start = origin, endpos = origin + dir * REACH, mask = MASK_PLAYERSOLID, filter = ply })
	if tr.Hit then
		local e = tr.Entity
		Say(("Gmod's own trace hits at %.0f units: %s"):format(tr.Fraction * REACH,
			IsValid(e) and (e:GetClass() .. " " .. tostring(e:GetModel())) or tr.HitWorld and ("the world, texture " .. tostring(tr.HitTexture)) or "?"))
	else
		Say("Gmod's own trace hits nothing within " .. REACH .. " units")
	end
	Say(#hits .. " map brushes along the aim:")
	for i, h in ipairs(hits) do
		if i > 25 then Say("  ...") break end
		local m = brushModel[h.brush]
		local who = m == nil and "no model" or m == 0 and "world" or ("*" .. m .. " " .. (owners[m] or "no entity"))
		Say(("  %.0f units: brush %d, %s, texture %s, %s%s"):format(h.t, h.brush, ContentNames(h.contents),
			h.face and Texture(I16(bsp, h.face + 2)) or "(inside it)", who,
			bit.band(h.contents, SKATE_SOLID) == 0 and " (skate ignores: not solid)"
				or m and m > 0 and not (owners[m] or ""):find("^func_") and " (skate ignores: not a func_ entity)" or ""))
	end
	file.CreateDir("skate3")
	file.Write("skate3/collision_report.txt", table.concat(lines, "\n"))
	Say("saved to garrysmod/data/skate3/collision_report.txt")
end

concommand.Add("skate3_collision_report", Report)
