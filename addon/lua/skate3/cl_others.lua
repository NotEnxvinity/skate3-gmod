-- Other skaters: their game sends their pose (sh_pose.lua), and here their
-- real body is posed from it, drawn a tenth of a second behind, blended
-- between the two frames either side so it moves smoothly. No Skate 3 data is
-- needed for this; with it, they also get the real board.

local Pose = include("skate3/sh_pose.lua")

return function(Skater)
	local Body = Skater.Body

	local DELAY = 0.1 -- draw this far in the past, between two frames
	local STALE = 1 -- no frame for this long: let go of their body
	local KEEP = 4 -- frames kept per skater

	local others = {} -- ply -> { frames = { { t, f } } }

	net.Receive("skate3_pose", function()
		local ply = net.ReadEntity()
		local f = Pose.Read()
		if not f or not IsValid(ply) or ply == LocalPlayer() then return end
		local o = others[ply] or { frames = {} }
		others[ply] = o
		local frames = o.frames
		frames[#frames + 1] = { t = RealTime(), f = f }
		while #frames > KEEP do table.remove(frames, 1) end
	end)

	local function Let(ply)
		others[ply] = nil
		Body.Release(ply)
		Body.HideBoard(ply)
	end

	-- Frame a blended a fraction t of the way to frame b.
	local function Blend(a, b, t)
		local f = {
			origin = LerpVector(t, a.origin, b.origin),
			yaw = a.yaw + math.AngleDifference(b.yaw, a.yaw) * t,
			state = b.state, forward = LerpVector(t, a.forward, b.forward), up = LerpVector(t, a.up, b.up),
			bones = {}, board = {},
		}
		local from = {}
		for _, bone in ipairs(a.bones) do from[bone.i] = bone.q end
		local fromP = {}
		for _, bone in ipairs(a.bones) do fromP[bone.i] = bone.p end
		for n, bone in ipairs(b.bones) do
			local q, p = from[bone.i], fromP[bone.i]
			f.bones[n] = { i = bone.i, q = q and Body.Slerp(q, bone.q, t) or bone.q,
				p = p and LerpVector(t, p, bone.p) or bone.p }
		end
		if b.pelvis then
			f.pelvis = b.pelvis
			f.ppos = a.pelvis == b.pelvis and LerpVector(t, a.ppos, b.ppos) or b.ppos
		end
		local parts = {}
		for _, part in ipairs(a.board) do parts[part.name] = part end
		for n, part in ipairs(b.board) do
			local was = parts[part.name]
			f.board[n] = was and { name = part.name, pos = LerpVector(t, was.pos, part.pos), q = Body.Slerp(was.q, part.q, t) } or part
		end
		return f
	end

	local function FrameAt(frames, t)
		if t <= frames[1].t then return frames[1].f end
		for n = 1, #frames - 1 do
			local a, b = frames[n], frames[n + 1]
			if t <= b.t then return Blend(a.f, b.f, (t - a.t) / math.max(b.t - a.t, 1e-3)) end
		end
		return frames[#frames].f
	end

	local function Flat(m)
		local t = m:ToTable()
		return { t[1][1], t[1][2], t[1][3], t[1][4], t[2][1], t[2][2], t[2][3], t[2][4], t[3][1], t[3][2], t[3][3], t[3][4] }
	end

	hook.Add("Think", "skate3_others", function()
		local now = RealTime()
		for ply, o in pairs(others) do
			local frames = o.frames
			if not IsValid(ply) or not ply:Alive() or not ply:GetNW2Bool("skate3_riding")
				or now - frames[#frames].t > STALE then
				Let(ply)
			elseif Body.Ready(ply:GetModel()) then
				local base = Body.BaseFor(ply)
				local f = FrameAt(frames, now - DELAY)
				local E0 = Matrix()
				E0:SetAngles(Angle(0, f.yaw, 0))
				E0:SetTranslation(f.origin)
				local rots, final = {}, {}
				for _, bone in ipairs(f.bones) do
					local r = Body.QuatMatrix(bone.q)
					rots[bone.i] = r
					local m = Matrix(r)
					m:SetTranslation(bone.p)
					final[bone.i] = E0 * m
				end
				if base then
					Body.Apply(ply, { origin = f.origin, yaw = f.yaw, rots = rots, final = final,
						hips = f.pelvis, hipsAt = f.ppos }, base)
				end
				local bones = {}
				for _, part in ipairs(f.board) do
					local m = Body.QuatMatrix(part.q)
					m:SetTranslation(f.origin + part.pos)
					bones[part.name] = Flat(m)
				end
				Body.ShowBoard(ply, { pos = { f.origin.x, f.origin.y, f.origin.z }, bones = bones,
					forward = f.forward, up = f.up }, Skater.DrawBoard)
			end
		end
	end)
end
