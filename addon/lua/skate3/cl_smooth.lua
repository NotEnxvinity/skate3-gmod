-- Your skater drawn between the simulation's steps.
--
-- The Skate 3 simulation runs at a fixed 60 steps a second, on its own
-- thread, and the game reads whichever step it finished last. Gmod draws at
-- whatever rate it likes (fps_max 300 on the Steam Machine), so drawn
-- straight from the newest step the skater would hold one pose for two or
-- three frames, then skip one, in an uneven rhythm that never lines up
-- with the screen: the body, board and camera stuttered, worst on anything
-- moving fast against the camera (a gesture's arms, a flip, a spin). It read
-- as the playermodel bouncing. Other players' skaters never did it: they're
-- drawn a little in the past, between two of their frames (cl_others.lua).
--
-- This does the same for your own: a clock of its own runs smoothly at the
-- simulation's rate about one step behind the newest, and the pose drawn
-- is the two steps around it blended (bones turned, not stretched). It
-- costs a sixtieth of a second or so of delay on what you see; the
-- simulation, its inputs, speed and every timing in it don't change.

local Smooth = {}

local cv = CreateClientConVar("skate3_smooth", "1", true, false,
	"Draw your skater and camera between the simulation's 60 steps a second, so they move smoothly at any frame rate (0 = straight from the newest step, the older way)")

local STEP = 1 / 60 -- the simulation's step
local BEHIND = 1 -- steps behind the newest the clock aims for
local SETTLE = 3 -- per second: how fast the clock eases back to that
local KEEP = 4 -- steps kept to blend between
-- Further apart than this between two steps (in units, or in steps) is a
-- teleport, a respawn or a new ride: never blended across.
local JUMP = 256
local GAP = 10

local steps = {} -- poses by tick, oldest first
local clock -- the tick being drawn (fractional), nil until the first pose

function Smooth.Reset()
	steps, clock = {}, nil
end

function Smooth.Enabled()
	return cv:GetBool()
end

local function LerpN(t, a, b)
	return a + (b - a) * t
end

local function LerpV(t, a, b)
	return { LerpN(t, a[1], b[1]), LerpN(t, a[2], b[2]), LerpN(t, a[3], b[3]) }
end

-- Blended and set back to unit length (a direction).
local function LerpDir(t, a, b)
	local x, y, z = LerpN(t, a[1], b[1]), LerpN(t, a[2], b[2]), LerpN(t, a[3], b[3])
	local l = math.sqrt(x * x + y * y + z * z)
	if l < 1e-6 then return { b[1], b[2], b[3] } end
	return { x / l, y / l, z / l }
end

local function Far(a, b)
	local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
	return dx * dx + dy * dy + dz * dz > JUMP * JUMP
end

-- Bones come as the rows of a 3x4 transform, { r1 (4), r2 (4), r3 (4) }: the
-- turn's columns are the bone's axes and the 4th, 8th and 12th numbers its
-- position. Blending the numbers straight would shrink a bone mid-turn, so
-- the turn is blended as a quaternion and each axis keeps its own length.

-- Unit quaternion { w, x, y, z } of the turn r (row-major 3x3 as 9 numbers).
local function ToQuat(m00, m01, m02, m10, m11, m12, m20, m21, m22)
	local trace = m00 + m11 + m22
	if trace > 0 then
		local s = math.sqrt(trace + 1) * 2
		return s / 4, (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s
	elseif m00 > m11 and m00 > m22 then
		local s = math.sqrt(1 + m00 - m11 - m22) * 2
		return (m21 - m12) / s, s / 4, (m01 + m10) / s, (m02 + m20) / s
	elseif m11 > m22 then
		local s = math.sqrt(1 + m11 - m00 - m22) * 2
		return (m02 - m20) / s, (m01 + m10) / s, s / 4, (m12 + m21) / s
	end
	local s = math.sqrt(1 + m22 - m00 - m11) * 2
	return (m10 - m01) / s, (m02 + m20) / s, (m12 + m21) / s, s / 4
end

local function Finite(x)
	return x == x and x > -1e9 and x < 1e9
end

local function Lengths(m)
	return math.sqrt(m[1] * m[1] + m[5] * m[5] + m[9] * m[9]),
		math.sqrt(m[2] * m[2] + m[6] * m[6] + m[10] * m[10]),
		math.sqrt(m[3] * m[3] + m[7] * m[7] + m[11] * m[11])
end

local function Det(m)
	return m[1] * (m[6] * m[11] - m[7] * m[10]) - m[2] * (m[5] * m[11] - m[7] * m[9]) + m[3] * (m[5] * m[10] - m[6] * m[9])
end

local function Straight(t, a, b)
	local out = {}
	for i = 1, 12 do out[i] = LerpN(t, a[i], b[i]) end
	return out
end

local function BlendBone(t, a, b)
	local ax, ay, az = Lengths(a)
	local bx, by, bz = Lengths(b)
	-- A bone scaled to nothing, mirrored or full of junk: numbers straight.
	if not (ax > 1e-4 and ay > 1e-4 and az > 1e-4 and bx > 1e-4 and by > 1e-4 and bz > 1e-4)
		or not (Finite(ax + ay + az + bx + by + bz)) or Det(a) <= 0 or Det(b) <= 0 then
		return Straight(t, a, b)
	end
	local aw, aqx, aqy, aqz = ToQuat(a[1] / ax, a[2] / ay, a[3] / az, a[5] / ax, a[6] / ay, a[7] / az, a[9] / ax, a[10] / ay, a[11] / az)
	local bw, bqx, bqy, bqz = ToQuat(b[1] / bx, b[2] / by, b[3] / bz, b[5] / bx, b[6] / by, b[7] / bz, b[9] / bx, b[10] / by, b[11] / bz)
	local d = aw * bw + aqx * bqx + aqy * bqy + aqz * bqz
	if d < 0 then d, bw, bqx, bqy, bqz = -d, -bw, -bqx, -bqy, -bqz end
	local wa, wb
	if d > 0.9995 then
		wa, wb = 1 - t, t
	else
		local th = math.acos(math.min(d, 1))
		local sn = math.sin(th)
		wa, wb = math.sin((1 - t) * th) / sn, math.sin(t * th) / sn
	end
	local w, x, y, z = aw * wa + bw * wb, aqx * wa + bqx * wb, aqy * wa + bqy * wb, aqz * wa + bqz * wb
	local n = math.sqrt(w * w + x * x + y * y + z * z)
	if not (n > 1e-6) then return Straight(t, a, b) end
	w, x, y, z = w / n, x / n, y / n, z / n
	local sx, sy, sz = LerpN(t, ax, bx), LerpN(t, ay, by), LerpN(t, az, bz)
	return {
		(1 - 2 * (y * y + z * z)) * sx, (2 * (x * y - w * z)) * sy, (2 * (x * z + w * y)) * sz, LerpN(t, a[4], b[4]),
		(2 * (x * y + w * z)) * sx, (1 - 2 * (x * x + z * z)) * sy, (2 * (y * z - w * x)) * sz, LerpN(t, a[8], b[8]),
		(2 * (x * z - w * y)) * sx, (2 * (y * z + w * x)) * sy, (1 - 2 * (x * x + y * y)) * sz, LerpN(t, a[12], b[12]),
	}
end

-- The pose a fraction t of the way from step a to step b. Everything that
-- isn't a place or a turn (state, score, gesture, invincibility) is b's.
local function Blend(a, b, t)
	local out = {}
	for k, v in pairs(b) do out[k] = v end
	out.pos = LerpV(t, a.pos, b.pos)
	out.forward = LerpDir(t, a.forward, b.forward)
	out.up = LerpDir(t, a.up, b.up)
	if a.bones and b.bones then
		local bones = {}
		for name, m in pairs(b.bones) do
			local was = a.bones[name]
			bones[name] = was and BlendBone(t, was, m) or m
		end
		out.bones = bones
	end
	local ca, cb = a.camera, b.camera
	if ca and cb then
		out.camera = {
			pos = LerpV(t, ca.pos, cb.pos),
			forward = LerpDir(t, ca.forward, cb.forward),
			up = LerpDir(t, ca.up, cb.up),
			fov = LerpN(t, ca.fov or cb.fov, cb.fov),
		}
	end
	return out
end

-- How far behind the newest step the clock sits, for skate3_smooth_report.
local behindSum, behindCount, heldCount = 0, 0, 0

-- The pose to draw this frame, given the newest one the simulation gave
-- (raw) and this frame's length. Raw itself when smoothing is off.
function Smooth.Drawn(raw, dt)
	if not raw or not raw.tick or not cv:GetBool() then
		Smooth.Reset()
		return raw
	end
	local newest = steps[#steps]
	-- A new ride or a respawn starts the count again (or skips far ahead).
	if newest and (raw.tick < newest.tick or raw.tick > newest.tick + GAP) then
		Smooth.Reset()
		newest = nil
	end
	if not newest or raw.tick > newest.tick then
		steps[#steps + 1] = raw
		if #steps > KEEP then table.remove(steps, 1) end
	else
		-- The same step read again: a fresh copy of the same numbers.
		steps[#steps] = raw
	end
	local top = raw.tick
	dt = math.Clamp(dt or 0, 0, 0.25)
	if not clock then clock = top - BEHIND end
	clock = clock + dt / STEP
	clock = clock + (top - BEHIND - clock) * (1 - math.exp(-SETTLE * dt))
	if clock > top then
		clock = top
		heldCount = heldCount + 1
	end
	clock = math.max(clock, top - 2, steps[1].tick)
	behindSum, behindCount = behindSum + (top - clock), behindCount + 1
	-- The two steps either side of the clock.
	local a, b
	for i = #steps, 1, -1 do
		if steps[i].tick <= clock then
			a, b = steps[i], steps[i + 1]
			break
		end
	end
	if not a then return raw end
	if not b then return a end
	if b.tick - a.tick > GAP or Far(a.pos, b.pos) or (b.state or ""):find("^Teleport") then return b end
	local t = (clock - a.tick) / (b.tick - a.tick)
	if t <= 0 then return a end
	if t >= 1 then return b end
	return Blend(a, b, t)
end

concommand.Add("skate3_smooth_report", function()
	if behindCount == 0 then
		print("[skate3] smoothing: nothing drawn yet (ride first; skate3_smooth is " .. cv:GetString() .. ")")
		return
	end
	print(("[skate3] smoothing %s: drawn %.2f steps behind the newest on average, held on the newest %.1f%% of frames (%d frames)"):format(
		cv:GetBool() and "on" or "off", behindSum / behindCount, heldCount / behindCount * 100, behindCount))
	behindSum, behindCount, heldCount = 0, 0, 0
end, nil, "How far behind the simulation your skater is drawn, and how often it had to wait for a step")

return Smooth
