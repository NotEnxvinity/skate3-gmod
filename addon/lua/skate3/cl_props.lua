-- The map's static props (railings, benches, planters, cars...) for the
-- skate collision. They live in the .bsp's game lump rather than its brushes,
-- so the module never sees them; their physics hulls are read here instead.

local Props = {}

local cv_props = CreateClientConVar("skate3_prop_collision", "1", true, false, "Let the board hit the map's props (railings, benches...); applies on the next map load")
local cv_shape = CreateClientConVar("skate3_ramp_shape", "1", true, false, "Ramps, bowls and rails use their smooth visible shape instead of their blocky physics one; applies on the next map load")

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

-- Ramps and bowls often get a physics hull of a few flat slabs with kinks
-- between them, which bounces the board and lets it slip through. These
-- models get their visible shape instead.
local SMOOTH = { "ramp", "skate", "bowl", "quarter", "pipe", "funbox", "kicker", "ledge", "rail", "stair", "curb" }
local MAX_SHAPE = 6000

local function Smooth(model)
	local name = model:lower():match("([^/]+)$") or ""
	for _, word in ipairs(SMOOTH) do
		if name:find(word, 1, true) then return true end
	end
	return false
end

local function Bounds(hs)
	local lo, hi = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
	for _, verts in ipairs(hs) do
		for _, v in ipairs(verts) do
			lo.x, lo.y, lo.z = math.min(lo.x, v.x), math.min(lo.y, v.y), math.min(lo.z, v.z)
			hi.x, hi.y, hi.z = math.max(hi.x, v.x), math.max(hi.y, v.y), math.max(hi.z, v.z)
		end
	end
	return lo, hi
end

local function OnBox(a, b, c, lo, hi)
	for _, k in ipairs({ "x", "y", "z" }) do
		for _, side in ipairs({ lo[k], hi[k] }) do
			if math.abs(a[k] - side) < 0.5 and math.abs(b[k] - side) < 0.5 and math.abs(c[k] - side) < 0.5 then return true end
		end
	end
	return false
end

-- A model's visible triangles in its own space, each already facing out
-- (by the mesh's own normals), as one hull marked `facing`; false when
-- the model isn't ramp-like or its mesh can't be used.
local shapes = {}
local function Shape(model)
	if shapes[model] ~= nil then return shapes[model] end
	shapes[model] = false
	if not Smooth(model) then return false end
	local meshes = util.GetModelMeshes(model, 0, 0)
	if not meshes then return false end
	local verts = { facing = true }
	for _, part in ipairs(meshes) do
		local tris = part.triangles or {}
		for t = 1, #tris - 2, 3 do
			local a, b, c = tris[t], tris[t + 1], tris[t + 2]
			local face = (b.pos - a.pos):Cross(c.pos - a.pos)
			if face:LengthSqr() > 1e-6 then
				local normal = (a.normal or vector_origin) + (b.normal or vector_origin) + (c.normal or vector_origin)
				local pa, pb, pc = a.pos, b.pos, c.pos
				if face:Dot(normal) < 0 then pb, pc = pc, pb end
				verts[#verts + 1], verts[#verts + 2], verts[#verts + 3] = pa, pb, pc
			end
		end
		if #verts / 3 > MAX_SHAPE then return false end
	end
	if #verts < 3 then return false end
	-- A mesh that doesn't sit where the physics does (odd bone setup) would
	-- put the ramp in the wrong place; keep the hulls then.
	local hs = Hulls(model)
	if hs then
		local lo, hi = Bounds({ verts })
		local hlo, hhi = Bounds(hs)
		if lo:DistToSqr(hlo) > 24 * 24 or hi:DistToSqr(hhi) > 24 * 24 then return false end
		-- Some ramps only model the faces you can see; the hull's outer
		-- walls (the faces lying on its box) keep their back and sides solid.
		for _, hull in ipairs(hs) do
			local centre = Vector()
			for _, v in ipairs(hull) do centre:Add(v) end
			centre:Div(#hull)
			for t = 1, #hull - 2, 3 do
				local a, b, c = hull[t], hull[t + 1], hull[t + 2]
				if OnBox(a, b, c, hlo, hhi) then
					if (b - a):Cross(c - a):Dot(a - centre) < 0 then b, c = c, b end
					verts[#verts + 1], verts[#verts + 2], verts[#verts + 3] = a, b, c
				end
			end
		end
	end
	shapes[model] = { verts }
	return shapes[model]
end

-- What the board collides with for a model: its visible shape for ramps,
-- otherwise its physics hulls. Second result is true for a visible shape.
function Props.Solid(model)
	local shape = cv_shape:GetBool() and Shape(model)
	if shape then return shape, true end
	return Hulls(model), false
end

-- A model's hull triangles as Vectors in threes, each wound counterclockwise
-- seen from outside its hull: the module only collides with a triangle's
-- front. Visible shapes come facing out already. Worked out once per shape,
-- not for every prop that stands on it.
local ordered = setmetatable({}, { __mode = "k" })

local function Ordered(hs)
	local out = ordered[hs]
	if out then return out end
	out = {}
	for _, verts in ipairs(hs) do
		local centre = Vector()
		for _, v in ipairs(verts) do centre:Add(v) end
		centre:Div(#verts)
		for t = 1, #verts - 2, 3 do
			local a, b, c = verts[t], verts[t + 1], verts[t + 2]
			if not verts.facing and (b - a):Cross(c - a):Dot(a - centre) < 0 then b, c = c, b end
			out[#out + 1], out[#out + 2], out[#out + 3] = a, b, c
		end
	end
	ordered[hs] = out
	return out
end

-- Appends a model's hull triangles, placed by matrix `m`, to the flat list
-- `out` holding `n` numbers. Returns the new count.
function Props.AppendHulls(out, n, hs, m)
	local tris = Ordered(hs)
	for i = 1, #tris do
		local w = m * tris[i]
		out[n + 1], out[n + 2], out[n + 3] = w.x, w.y, w.z
		n = n + 3
	end
	return n
end

local cache = { map = nil, tris = {}, stream = nil }

-- A map with more props than this many triangles can't have them all in the
-- collision at once (the game stalls building it), so the module is handed
-- the ones around the skater instead and cl_live_props.lua swaps them as the
-- skater moves. Before that, the first ones in the map's list were taken and
-- the rest silently left out: gm_infinity_pools lost every bench, bridge and
-- half its railings that way.
Props.Stream = nil

-- Every solid static prop's hull triangles in world space, as the flat
-- {x1, y1, z1, x2, ...} list skate3.LoadMap takes. Built once per map. A map
-- with too many props to hold at once gets none here and Props.Stream set
-- to its props instead ({model, pos, ang, hulls, tris} each).
function Props.Triangles(bsp)
	if not cv_props:GetBool() then
		Props.Stream = nil
		return {}
	end
	if cache.map == game.GetMap() then
		Props.Stream = cache.stream
		return cache.tris
	end
	cache.map, cache.tris, cache.stream = game.GetMap(), {}, nil
	Props.Stream = nil
	local props, err = Props.Parse(bsp)
	if not props then
		print("[skate3] skipping prop collision: " .. err)
		return cache.tris
	end
	-- Each prop's shape and size first, to see whether they all fit.
	local list, total, smooth = {}, 0, 0
	for _, prop in ipairs(props) do
		local hs, visible = Props.Solid(prop.model)
		if hs then
			local size = 0
			for _, verts in ipairs(hs) do size = size + math.floor(#verts / 3) end
			if size > 0 then
				if visible then smooth = smooth + 1 end
				prop.hulls, prop.tris = hs, size
				list[#list + 1] = prop
				total = total + size
			end
		end
	end
	if total > MAX_TRIANGLES then
		cache.stream = list
		Props.Stream = list
		print(("[skate3] %d of %d props solid for skating (%d triangles, too many for one go: the ones around you are swapped in as you move)"):format(#list, #props, total))
		return cache.tris
	end
	local out, n = cache.tris, 0
	for _, prop in ipairs(list) do
		local m = Matrix()
		m:Translate(prop.pos)
		m:Rotate(prop.ang)
		n = Props.AppendHulls(out, n, prop.hulls, m)
	end
	print(("[skate3] %d of %d props solid for skating (%d triangles, %d ramps use their visible shape)"):format(#list, #props, n / 9, smooth))
	return out
end

return Props
