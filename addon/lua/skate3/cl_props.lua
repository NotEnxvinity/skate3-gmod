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

-- Every solid static prop as {model, pos, ang}, or nil and why not.
function Props.Parse(bsp)
	if #bsp < 8 + 64 * 16 or bsp:sub(1, 4) ~= "VBSP" then return nil, "not a Source map" end
	local lump = 9 + LUMP_GAME * 16
	local ofs, len = I32(bsp, lump), I32(bsp, lump + 4)
	if len < 4 or ofs + len > #bsp then return nil, "no game lump" end
	local base = ofs + 1
	local count = I32(bsp, base)
	for i = 0, count - 1 do
		local e = base + 4 + i * 16
		if bsp:sub(e, e + 3) == "prps" then -- 'sprp', little endian
			if U16(bsp, e + 4) % 2 == 1 then return nil, "the map's props are compressed" end
			local p = I32(bsp, e + 8) + 1
			local stop = p + I32(bsp, e + 12)
			local names = {}
			local n = I32(bsp, p)
			p = p + 4
			for k = 1, n do
				names[k - 1] = bsp:sub(p, p + 127):match("^[^%z]*")
				p = p + 128
			end
			p = p + 4 + I32(bsp, p) * 2 -- the props' leaves
			local props = {}
			local total = I32(bsp, p)
			p = p + 4
			if total <= 0 then return props end
			-- The entry size changes with the lump version; the entries fill
			-- the rest of the lump either way.
			local stride = math.floor((stop - p) / total)
			if stride < 32 then return nil, "unknown prop format" end
			for k = 0, total - 1 do
				local q = p + k * stride
				local solid = bsp:byte(q + 30)
				local model = names[U16(bsp, q + 24)]
				if solid ~= 0 and model and model ~= "" then
					props[#props + 1] = {
						model = model,
						pos = Vector(F32(bsp, q), F32(bsp, q + 4), F32(bsp, q + 8)),
						ang = Angle(F32(bsp, q + 12), F32(bsp, q + 16), F32(bsp, q + 20)),
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
			-- Visible shapes come facing out already.
			if not verts.facing and (b - a):Cross(c - a):Dot(a - centre) < 0 then b, c = c, b end
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
	local out, n, used, smooth = cache.tris, 0, 0, 0
	for _, prop in ipairs(props) do
		local hs, visible = Props.Solid(prop.model)
		if hs then
			if visible then smooth = smooth + 1 end
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
	print(("[skate3] %d of %d props solid for skating (%d triangles, %d ramps use their visible shape)"):format(used, #props, n / 9, smooth))
	return out
end

return Props
