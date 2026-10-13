-- The map's static props (railings, benches, planters, cars...) for the
-- skate collision. They live in the .bsp's game lump rather than its brushes,
-- so the module never sees them; their physics hulls are read here instead.

local Props = {}

local cv_props = CreateClientConVar("skate3_prop_collision", "1", true, false, "Let the board hit the map's props (railings, benches...); applies on the next map load")

-- Keeps one map's worth of triangles from making the collision build crawl.
local MAX_TRIANGLES = 300000
local LUMP_GAME = 35

local function U16(s, at)
	local a, b = s:byte(at, at + 1)
	return a + b * 256
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
	if exp == 0 then
		return sign * mant * 2 ^ -149
	elseif exp == 255 then
		return 0
	end
	return sign * (1 + mant / 8388608) * 2 ^ (exp - 127)
end

-- Unpacks the LZMA block starting at `at` in `s` (Workshop maps are often
-- packed with bspzip -compress), or nil and why not.
local function Unpack(s, at)
	if not (skate3 and skate3.Unlzma) then return nil, "it's compressed and this S3GM module is too old to unpack it (rerun the setup)" end
	if s:sub(at, at + 3) ~= "LZMA" or at + 16 > #s then return nil, "it's not a valid compressed block" end
	local out, err = skate3.Unlzma(s:sub(at, at + 16 + I32(s, at + 8)))
	if not out then return nil, err end
	return out
end
Props.Unpack = Unpack

-- Every solid static prop as {model, pos, ang}, or nil and why not.
function Props.Parse(bsp)
	if #bsp < 8 + 64 * 16 or bsp:sub(1, 4) ~= "VBSP" then return nil, "not a Source map" end
	local lump = 9 + LUMP_GAME * 16
	local ofs, len = I32(bsp, lump), I32(bsp, lump + 4)
	if len < 4 or ofs + len > #bsp then return nil, "no game lump" end
	-- The game lump's directory; its entries still point into the file.
	local dir, base = bsp, ofs + 1
	if bsp:sub(base, base + 3) == "LZMA" then
		local err
		dir, err = Unpack(bsp, base)
		if not dir then return nil, "can't read the map's game lump: " .. err end
		base = 1
	end
	local count = I32(dir, base)
	for i = 0, count - 1 do
		local e = base + 4 + i * 16
		if dir:sub(e, e + 3) == "prps" then -- 'sprp', little endian
			local s, p, stop = bsp, I32(dir, e + 8) + 1, nil
			stop = p + I32(dir, e + 12)
			if U16(dir, e + 4) % 2 == 1 or bsp:sub(p, p + 3) == "LZMA" then
				local err
				s, err = Unpack(bsp, p)
				if not s then return nil, "can't read the map's props: " .. err end
				p, stop = 1, #s + 1
			end
			local names = {}
			local n = I32(s, p)
			p = p + 4
			for k = 1, n do
				names[k - 1] = s:sub(p, p + 127):match("^[^%z]*")
				p = p + 128
			end
			p = p + 4 + I32(s, p) * 2 -- the props' leaves
			local props = {}
			local total = I32(s, p)
			p = p + 4
			if total <= 0 then return props end
			-- The entry size changes with the lump version; the entries fill
			-- the rest of the lump either way.
			local stride = math.floor((stop - p) / total)
			if stride < 32 then return nil, "unknown prop format" end
			for k = 0, total - 1 do
				local q = p + k * stride
				local solid = s:byte(q + 30)
				local model = names[U16(s, q + 24)]
				if solid ~= 0 and model and model ~= "" then
					props[#props + 1] = {
						model = model,
						pos = Vector(F32(s, q), F32(s, q + 4), F32(s, q + 8)),
						ang = Angle(F32(s, q + 12), F32(s, q + 16), F32(s, q + 20)),
					}
				end
			end
			return props
		end
	end
	return {}
end

-- A model's physics hulls in its own space, as convex vertex lists
-- ({Vector, ...} in threes), or false when it has none.
local hulls = {}
local function Hulls(model)
	if hulls[model] ~= nil then return hulls[model] end
	hulls[model] = false
	local ent = ClientsideModel(model, RENDERGROUP_OTHER)
	if not IsValid(ent) then return false end
	ent:SetNoDraw(true)
	ent:PhysicsInit(SOLID_VPHYSICS)
	local phys = ent:GetPhysicsObject()
	local convexes = IsValid(phys) and phys:GetMeshConvexes()
	ent:Remove()
	if not convexes or #convexes == 0 then return false end
	local out = {}
	for _, convex in ipairs(convexes) do
		local verts = {}
		for i, v in ipairs(convex) do verts[i] = v.pos end
		out[#out + 1] = verts
	end
	hulls[model] = out
	return out
end

Props.Hulls = Hulls

-- Appends a model's hull triangles, placed by matrix `m`, to the flat list
-- `out` holding `n` numbers. Returns the new count.
function Props.AppendHulls(out, n, hs, m)
	for _, verts in ipairs(hs) do
		local centre = Vector()
		for _, v in ipairs(verts) do centre:Add(v) end
		centre:Div(#verts)
		for t = 1, #verts - 2, 3 do
			local a, b, c = verts[t], verts[t + 1], verts[t + 2]
			-- The module only collides with a triangle's front, so
			-- each one faces out of its hull, counterclockwise.
			if (b - a):Cross(c - a):Dot(a - centre) < 0 then b, c = c, b end
			for _, v in ipairs({ a, b, c }) do
				local w = m * v
				out[n + 1], out[n + 2], out[n + 3] = w.x, w.y, w.z
				n = n + 3
			end
		end
	end
	return n
end

local cache = { map = nil, tris = {} }

-- Every solid static prop's hull triangles in world space, as the flat
-- {x1, y1, z1, x2, ...} list skate3.LoadMap takes. Built once per map.
function Props.Triangles(bsp)
	if not cv_props:GetBool() then return {} end
	if cache.map == game.GetMap() then return cache.tris end
	cache.map, cache.tris = game.GetMap(), {}
	local props, err = Props.Parse(bsp)
	if not props then
		print("[skate3] skipping prop collision: " .. err)
		return cache.tris
	end
	local out, n, used = cache.tris, 0, 0
	for _, prop in ipairs(props) do
		local hs = Hulls(prop.model)
		if hs then
			local m = Matrix()
			m:Translate(prop.pos)
			m:Rotate(prop.ang)
			n = Props.AppendHulls(out, n, hs, m)
			used = used + 1
			if n / 9 >= MAX_TRIANGLES then
				print(("[skate3] prop collision stopped at %d triangles"):format(MAX_TRIANGLES))
				break
			end
		end
	end
	print(("[skate3] %d of %d props solid for skating (%d triangles)"):format(used, #props, n / 9))
	return out
end

return Props
