-- The static going back to your marker, as in Skate 3: while you hold the way
-- back, black-and-white TV static fades in over the screen (under the HUD),
-- all of it static when you go, held for three frames, then gone. Let go
-- early and it's gone at once.
--
-- This is retail's own effect, as SK8-ENGINE ported it (crates/skate-game,
-- session_marker/effect.rs and noise.rs): the game's six-word generator
-- (0x82A8AF10) fills a 64x64 texture whose four channels are each a field of
-- black and white texels (0x827ED7E8); the postfx noise shader
-- (postfx_basictex_fisheye_noisePS) samples it twice, tiled 10 x 5.625 and
-- 11 x 6.625 across the screen, each with a random scroll every 1/60 s and
-- a slow cross-fade from one channel to the next, and the static is
-- clamp(2 (a + b) - 2, 0, 1): white where both samples are. The scene is
-- blended as scene (1 - p) + static p, p being the hold's progress.
--
-- Garry's Mod has no custom shaders, so the same sum is done with blend
-- modes in render targets: the first sample, minus one minus the second
-- (which a render target clamps at zero), doubled.

S3GM_Static = S3GM_Static or {}
local Static = S3GM_Static

local cv_static = CreateClientConVar("skate3_marker_static", "1", true, false,
	"Static over the screen while going back to your marker, as in Skate 3 (1 on, 0 off)")

local SIZE = 64        -- the noise texture, texels a side
local TICK = 1 / 60    -- retail steps the noise once a UI tick
local TAIL = 3 * TICK  -- full static after the teleport (state.rs `tail`)
local STALE = 0.1      -- s without word from the menu before the static goes

---------------------------------------------------------------------------
-- Retail's generator: six 32-bit words added into each other with carry,
-- then incremented as one 192-bit number. Lua's numbers hold these sums
-- exactly (below 2^34).
---------------------------------------------------------------------------

local TWO32 = 4294967296
local words = { 4063039062, 2284922601, 3324304687, 117621916, 2654289789, 1876900708 }

local function Next()
	local carry = 0
	for i = 5, 1, -1 do
		local sum = words[i] + words[i + 1] + carry
		if sum >= TWO32 then
			words[i], carry = sum - TWO32, 1
		else
			words[i], carry = sum, 0
		end
	end
	for i = 6, 1, -1 do
		words[i] = words[i] + 1
		if words[i] < TWO32 then break end
		words[i] = 0
	end
	return words[1]
end

-- The texture's bits, in retail's order (texel by texel, R G B A), so a lost
-- render target can be drawn again the same. bits[channel][texel] = true for
-- white.
local bits = { {}, {}, {}, {} }
for texel = 0, SIZE * SIZE - 1 do
	for c = 1, 4 do
		bits[c][texel] = math.floor(Next() / 256) % 256 > 128
	end
end

-- The two samples' channel phases (0 to 4) and the scroll, per tick.
local phases = { 0, 0 }
local scroll = { 0, 0, 0, 0 }
local function Advance()
	phases[1] = phases[1] + 0.045
	if phases[1] >= 4 then phases[1] = phases[1] - 4 end
	phases[2] = phases[2] + 0.06
	if phases[2] >= 4 then phases[2] = phases[2] - 4 end
	-- 0x827EE03C draws four and writes them fourth, third, second, first.
	local a, b, c, d = Next() % 65536, Next() % 65536, Next() % 65536, Next() % 65536
	scroll[1], scroll[2], scroll[3], scroll[4] = d / 65536, c / 65536, b / 65536, a / 65536
end

---------------------------------------------------------------------------
-- Render targets
---------------------------------------------------------------------------

local NOMIP = 256      -- TEXTUREFLAGS_NOMIP; no CLAMPS/CLAMPT, so it tiles
local WIDE, HIGH = 960, 540

local function Target(name, w, h)
	return GetRenderTargetEx(name, w, h, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, NOMIP, 0, IMAGE_FORMAT_RGBA8888)
end

local function MaterialOf(rt)
	return CreateMaterial(rt:GetName() .. "_mat", "UnlitGeneric", {
		["$basetexture"] = rt:GetName(),
		["$vertexcolor"] = 1,
		["$vertexalpha"] = 1,
		["$translucent"] = 1,
		["$ignorez"] = 1,
	})
end

local made, failed
local plain, inverse = {}, {} -- [channel] = material: the channel, and one minus it
local sumRT, sumMat, outRT, outMat

local function Make()
	if made or failed then return made end
	local ok, err = pcall(function()
		for c = 1, 4 do
			local rt = Target("s3gm_static_c" .. c, SIZE, SIZE)
			local inv = Target("s3gm_static_i" .. c, SIZE, SIZE)
			plain[c] = { rt = rt, mat = MaterialOf(rt) }
			inverse[c] = { rt = inv, mat = MaterialOf(inv) }
		end
		sumRT = Target("s3gm_static_sum", WIDE, HIGH)
		sumMat = MaterialOf(sumRT)
		outRT = Target("s3gm_static_out", WIDE, HIGH)
		outMat = MaterialOf(outRT)
	end)
	if not ok then
		failed = true
		print("[skate3] marker static unavailable: " .. tostring(err))
		return false
	end
	made = true
	return true
end

-- Every blend below leaves the targets' alpha alone (all opaque from Clear),
-- so drawing the result on screen fades by vertex alpha only.
local function Blend(src, dst, func)
	render.OverrideBlend(true, src, dst, func, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
end

local function Normal()
	Blend(BLEND_SRC_ALPHA, BLEND_ONE_MINUS_SRC_ALPHA, BLENDFUNC_ADD)
end

-- Draws the texture's four channels (and their inverses) into their targets:
-- each white texel run of a row is one rectangle.
local function Paint()
	for c = 1, 4 do
		render.PushRenderTarget(plain[c].rt)
		render.Clear(0, 0, 0, 255)
		cam.Start2D()
		surface.SetDrawColor(255, 255, 255, 255)
		draw.NoTexture()
		local b = bits[c]
		for y = 0, SIZE - 1 do
			local row, x = y * SIZE, 0
			while x < SIZE do
				if b[row + x] then
					local from = x
					while x < SIZE and b[row + x] do x = x + 1 end
					surface.DrawRect(from, y, x - from, 1)
				else
					x = x + 1
				end
			end
		end
		cam.End2D()
		render.PopRenderTarget()

		-- One minus it: white, minus the channel.
		render.PushRenderTarget(inverse[c].rt)
		render.Clear(255, 255, 255, 255)
		cam.Start2D()
		Blend(BLEND_ONE, BLEND_ONE, BLENDFUNC_REVERSE_SUBTRACT)
		surface.SetMaterial(plain[c].mat)
		surface.SetDrawColor(255, 255, 255, 255)
		surface.DrawTexturedRect(0, 0, SIZE, SIZE)
		render.OverrideBlend(false)
		cam.End2D()
		render.PopRenderTarget()
	end
end

-- Retail's channel weights for a phase: two neighbouring channels, cross-faded.
local function Weights(phase)
	local i = math.floor(phase)
	local f = phase - i
	return i % 4 + 1, (i + 1) % 4 + 1, f
end

-- One sample across the whole target: channel `first` fully, `second` over it
-- at `f`. `subtract` takes it away from what's there instead.
local function Layer(set, first, second, f, u, v, tilesU, tilesV, subtract)
	local w, h = WIDE, HIGH
	if subtract then
		-- dst - src * alpha, twice: what a render target clamps at zero
		-- stays there, so the order doesn't matter.
		Blend(BLEND_SRC_ALPHA, BLEND_ONE, BLENDFUNC_REVERSE_SUBTRACT)
		surface.SetMaterial(set[first].mat)
		surface.SetDrawColor(255, 255, 255, math.Round((1 - f) * 255))
		surface.DrawTexturedRectUV(0, 0, w, h, u, v, u + tilesU, v + tilesV)
		surface.SetMaterial(set[second].mat)
		surface.SetDrawColor(255, 255, 255, math.Round(f * 255))
		surface.DrawTexturedRectUV(0, 0, w, h, u, v, u + tilesU, v + tilesV)
	else
		Normal()
		surface.SetMaterial(set[first].mat)
		surface.SetDrawColor(255, 255, 255, 255)
		surface.DrawTexturedRectUV(0, 0, w, h, u, v, u + tilesU, v + tilesV)
		surface.SetMaterial(set[second].mat)
		surface.SetDrawColor(255, 255, 255, math.Round(f * 255))
		surface.DrawTexturedRectUV(0, 0, w, h, u, v, u + tilesU, v + tilesV)
	end
end

-- This tick's static into outRT.
local function Compose()
	-- Square texels: 10 tiles across and as many down as the screen's shape
	-- gives (5.625 at 16:9); the second sample has one more each way.
	local tall = 10 * ScrH() / math.max(ScrW(), 1)
	local k1, k1n, f1 = Weights(phases[1])
	local k2, k2n, f2 = Weights(phases[2])

	render.PushRenderTarget(sumRT)
	render.Clear(0, 0, 0, 255)
	cam.Start2D()
	Layer(plain, k1, k1n, f1, scroll[1], scroll[2], 10, tall)
	Layer(inverse, k2, k2n, f2, scroll[3], scroll[4], 11, tall + 1, true)
	render.OverrideBlend(false)
	cam.End2D()
	render.PopRenderTarget()

	-- Doubled (and clamped at white).
	render.PushRenderTarget(outRT)
	render.Clear(0, 0, 0, 255)
	cam.Start2D()
	Blend(BLEND_ONE, BLEND_ONE, BLENDFUNC_ADD)
	surface.SetMaterial(sumMat)
	surface.SetDrawColor(255, 255, 255, 255)
	surface.DrawTexturedRect(0, 0, WIDE, HIGH)
	surface.DrawTexturedRect(0, 0, WIDE, HIGH)
	render.OverrideBlend(false)
	cam.End2D()
	render.PopRenderTarget()
end

---------------------------------------------------------------------------
-- What the marker says
---------------------------------------------------------------------------

local progress, saidAt = 0, -math.huge
local tailUntil, tailFrames = -math.huge, 0
local painted = false
local clock, lastFrame = 0, nil

-- The hold's progress, 0 to 1, every frame the menu runs.
function Static.Hold(p)
	progress, saidAt = math.Clamp(p or 0, 0, 1), RealTime()
end

-- The teleport: full static a moment longer (at least two drawn frames, so a
-- slow restart of the ride can't skip it).
function Static.Flash()
	tailUntil, tailFrames = RealTime() + TAIL, 2
	progress = 0
end

-- How much static there is now, 0 to 1.
function Static.Amount()
	local now = RealTime()
	if now < tailUntil or tailFrames > 0 then return 1 end
	if now - saidAt > STALE then return 0 end
	return progress
end

hook.Add("HUDPaintBackground", "skate3_marker_static", function()
	local now = RealTime()
	-- The noise runs on its 60 Hz clock whether it shows or not, as retail's.
	if lastFrame then clock = clock + math.min(now - lastFrame, 0.25) end
	lastFrame = now
	while clock >= TICK do
		clock = clock - TICK
		Advance()
	end

	local amount = Static.Amount()
	if tailFrames > 0 then tailFrames = tailFrames - 1 end
	if amount <= 0 then
		-- Painted again next time it shows: render targets can lose what was
		-- drawn in them (a resolution change, alt-tab).
		painted = false
		return
	end
	if not cv_static:GetBool() or not Make() then return end
	local ok, err = pcall(function()
		if not painted then
			Paint()
			painted = true
		end
		Compose()
	end)
	render.OverrideBlend(false)
	if not ok then
		failed = true
		print("[skate3] marker static failed: " .. tostring(err))
		return
	end
	surface.SetMaterial(outMat)
	surface.SetDrawColor(255, 255, 255, math.Round(amount * 255))
	surface.DrawTexturedRect(0, 0, ScrW(), ScrH())
end)

return Static
