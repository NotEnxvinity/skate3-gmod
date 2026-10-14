-- Other skaters: their game sends their pose (sh_pose.lua), and here they're
-- drawn from it, a tenth of a second behind, blended between the two frames
-- either side so they move smoothly. No Skate 3 data is needed for this; with
-- it, they also get the real board (without, a plain deck).
--
-- Their body is drawn as a copy of their playermodel with every bone set
-- straight from the frame, and their own body is hidden meanwhile. The frame
-- holds finished world bones, so the copy lands on the skater wherever the
-- engine has the player, and needs nothing measured first. (Posing their real
-- body, skate3_others_body real, depends on measuring how this Gmod applies
-- bone turns; when that didn't work out, nothing was drawn at all and they
-- hung crouched in the air, Gmod's falling animation.)

local Pose = include("skate3/sh_pose.lua")

local cv_mode = CreateClientConVar("skate3_others_body", "copy", true, false,
	"How other skaters are drawn: copy (a posed copy of their playermodel, the default) or real (their own body, posed)")
local cv_debug = CreateClientConVar("skate3_debug_others", "0", false, false,
	"Show what arrives from other skaters and how they're drawn")

return function(Skater, Perf)
	local Body = Skater.Body

	local DELAY = 0.1 -- draw this far in the past, between two frames
	local STALE = 1 -- no frame for this long: let go of their body
	local KEEP = 4 -- frames kept per skater
	local REBUILD_EVERY = 2 -- at most one new copy per skater this often (each is an entity)

	local others = {} -- ply -> { frames = { { t, f } }, copy, ... }
	local arrived = {} -- ply -> { count, at }, for the debug overlay

	net.Receive("skate3_pose", function(len)
		Perf.Got(len / 8)
		local ply = net.ReadEntity()
		local f = Pose.Read()
		if not IsValid(ply) or ply == LocalPlayer() then return end
		local a = arrived[ply] or { count = 0 }
		arrived[ply] = a
		a.count, a.at, a.bad = a.count + 1, RealTime(), not f
		if not f then return end
		local o = others[ply] or { frames = {} }
		others[ply] = o
		local frames = o.frames
		frames[#frames + 1] = { t = RealTime(), f = f }
		while #frames > KEEP do table.remove(frames, 1) end
	end)

	local function DropCopy(o)
		if IsValid(o.copy) then o.copy:Remove() end
		o.copy = nil
	end

	local function Let(ply)
		local o = others[ply]
		others[ply] = nil
		if o then DropCopy(o) end
		if IsValid(ply) then
			if o and o.hidShadow then ply:DrawShadow(true) end
			Body.Release(ply)
		end
		Body.HideBoard(ply)
	end

	-- Frame a blended a fraction t of the way to frame b.
	local function Blend(a, b, t)
		local f = {
			origin = LerpVector(t, a.origin, b.origin),
			yaw = a.yaw + math.AngleDifference(b.yaw, a.yaw) * t,
			state = b.state, forward = LerpVector(t, a.forward, b.forward), up = LerpVector(t, a.up, b.up),
			bones = {}, board = {}, model = b.model,
		}
		-- Bone numbers only match within one model.
		local same = a.model == b.model
		local from, fromP = {}, {}
		if same then
			for _, bone in ipairs(a.bones) do from[bone.i], fromP[bone.i] = bone.q, bone.p end
		end
		for n, bone in ipairs(b.bones) do
			local q, p = from[bone.i], fromP[bone.i]
			f.bones[n] = { i = bone.i, q = q and Body.Slerp(q, bone.q, t) or bone.q,
				p = p and LerpVector(t, p, bone.p) or bone.p }
		end
		if b.pelvis then
			f.pelvis = b.pelvis
			f.ppos = same and a.pelvis == b.pelvis and LerpVector(t, a.ppos, b.ppos) or b.ppos
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

	-- The model the frame's bone numbers belong to.
	local function ModelOf(ply, f)
		if f.model and f.model ~= "" and util.IsValidModel(f.model) then return f.model end
		return ply:GetModel()
	end

	-- The copy of ply's playermodel `name` that stands in for them, made once
	-- (and again only when the model changes, at most every few seconds).
	local function CopyFor(ply, o, name)
		local e = o.copy
		if IsValid(e) and e.skate3Name == name then return e end
		local now = RealTime()
		if now < (o.builtAt or -math.huge) + REBUILD_EVERY then return IsValid(e) and e or nil end
		local base = Body.BaseForModel(name)
		if not base then return IsValid(e) and e or nil end
		o.builtAt = now
		DropCopy(o)
		e = ClientsideModel(name, RENDERGROUP_OPAQUE)
		if not IsValid(e) then
			o.why = "couldn't load " .. tostring(name)
			return nil
		end
		e.skate3Name, e.skate3Base = name, base
		e:SetNoDraw(true)
		e:DrawShadow(false)
		pcall(e.SetLOD, e, 0)
		e:SetRenderBounds(Vector(-96, -96, -64), Vector(96, 96, 128))
		e.RenderOverride = function(self, flags)
			local world = self.skate3World
			if world then
				self:SetupBones()
				for i = 0, math.min(self:GetBoneCount(), base.count) - 1 do
					if world[i] then self:SetBoneMatrix(i, world[i]) end
				end
			end
			self:DrawModel(flags)
		end
		o.copy = e
		return e
	end

	-- Every bone of the copy in the world: the frame's own, and the rest
	-- (hair, tails, helpers) carried by their parent with the model's offsets.
	local function CopyWorld(base, final, E0)
		local world = {}
		local parents, locals, carry = base.parents, base.locals, base.carry or {}
		for i = 0, base.count - 1 do
			local m = final[i]
			if not m then
				local L = locals[i]
				if L then
					if carry[i] then L = carry[i] * L end
					local par = parents[i]
					local pm = par >= 0 and world[par] or (par < 0 and E0) or nil
					if pm then m = pm * L end
				end
			end
			world[i] = m
		end
		return world
	end

	local function DrawCopy(ply, o, f, E0, final)
		local e = CopyFor(ply, o, ModelOf(ply, f))
		if not IsValid(e) then return false end
		e:SetPos(f.origin)
		e:SetAngles(Angle(0, f.yaw, 0))
		e.skate3World = CopyWorld(e.skate3Base, final, E0)
		-- Skin, bodygroups and colour from the player, when it's their model.
		if e:GetModel() and ply:GetModel() and e:GetModel():lower() == ply:GetModel():lower() then
			if e:GetSkin() ~= ply:GetSkin() then e:SetSkin(ply:GetSkin()) end
			for i = 0, ply:GetNumBodyGroups() - 1 do
				if e:GetBodygroup(i) ~= ply:GetBodygroup(i) then e:SetBodygroup(i, ply:GetBodygroup(i)) end
			end
		end
		e.GetPlayerColor = e.GetPlayerColor or function() return IsValid(ply) and ply:GetPlayerColor() or Vector(1, 1, 1) end
		e:SetNoDraw(false)
		if not o.hidShadow then
			ply:DrawShadow(false)
			o.hidShadow = true
		end
		return true
	end

	local function DrawReal(ply, o, f, rots, final)
		DropCopy(o)
		if o.hidShadow then
			ply:DrawShadow(true)
			o.hidShadow = false
		end
		local ready, why = Body.Ready(ply:GetModel())
		if not ready then
			o.why = "can't pose bodies here: " .. tostring(why)
			return false
		end
		local base = Body.BaseFor(ply)
		if not base then
			o.why = "their model isn't ready yet"
			return false
		end
		Body.Apply(ply, { origin = f.origin, yaw = f.yaw, rots = rots, final = final,
			hips = f.pelvis, hipsAt = f.ppos }, base)
		return true
	end

	hook.Add("Think", "skate3_others", function()
		if not next(others) then return end
		Perf.Begin("other skaters")
		local now = RealTime()
		for ply, o in pairs(others) do
			local frames = o.frames
			if not IsValid(ply) or not ply:Alive() or not ply:GetNW2Bool("skate3_riding")
				or now - frames[#frames].t > STALE then
				Let(ply)
			else
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
				o.why = nil
				if cv_mode:GetString() == "real" and ModelOf(ply, f) == ply:GetModel() then
					o.drawn = DrawReal(ply, o, f, rots, final) and "real" or nil
				else
					if Body.IsPosed(ply) then Body.Release(ply) end
					o.drawn = DrawCopy(ply, o, f, E0, final) and "copy" or nil
					if not o.drawn then o.why = o.why or "their model isn't ready yet" end
				end
				-- The board, whatever became of the body.
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
		Perf.End("other skaters")
		for ply in pairs(arrived) do
			if not IsValid(ply) then arrived[ply] = nil end
		end
	end)

	-- Their own body, frozen mid-fall, stays hidden while the copy stands in.
	hook.Add("PrePlayerDraw", "skate3_others_hide", function(ply)
		local o = others[ply]
		if o and o.drawn == "copy" and IsValid(o.copy) then return true end
	end)

	-- skate3_debug_others 1: each other player, whether their frames arrive,
	-- and how they're drawn.
	hook.Add("HUDPaint", "skate3_others_debug", function()
		if not cv_debug:GetBool() then return end
		local now = RealTime()
		local y = 80
		local function Line(text, color)
			draw.SimpleTextOutlined(text, "DermaDefaultBold", 16, y, color or color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 1, color_black)
			y = y + 16
		end
		Line(("[skate3] other skaters (drawn as: %s)"):format(cv_mode:GetString()))
		for _, ply in ipairs(player.GetAll()) do
			if ply ~= LocalPlayer() then
				local a, o = arrived[ply], others[ply]
				local riding = ply:GetNW2Bool("skate3_riding")
				local text = ("%s: %s, "):format(ply:Nick(), riding and "riding" or "not riding")
				if not a then
					text = text .. "no frames received"
				else
					text = text .. ("%d frames, last %.1f s ago%s"):format(a.count, now - a.at, a.bad and " (last one unreadable)" or "")
				end
				if o then
					local f = o.frames[#o.frames].f
					text = text .. ("; %d bones, %d board parts, model %s; drawn: %s"):format(#f.bones, #f.board,
						f.model ~= "" and f.model or "(theirs)", o.drawn or ("nothing (" .. tostring(o.why) .. ")"))
				end
				Line(text, (riding and not (o and o.drawn)) and Color(255, 120, 120) or nil)
			end
		end
	end)
end
