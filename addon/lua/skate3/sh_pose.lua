-- The skater's pose as other players receive it: the skater's own game sends
-- it 20 times a second, the server passes it on to everyone nearby. It holds
-- the finished playermodel pose (each posed bone's turn and the hips'
-- offset), so whoever watches needs no Skate 3 data, only the playermodel.
--
-- A frame:
--   origin   Vector, where the skater stands
--   yaw      number, which way the body faces
--   state    string, the skate state ("PhysicsGround", "BipedGround", ...)
--   forward, up  Vector, the board's heading, for the stand-in board
--   bones    list of { i = bone index, q = { w, x, y, z } }, each posed
--            bone's world turn relative to the way the body faces (yaw)
--   pelvis   bone index or nil, with ppos where it goes: from origin, in
--            the facing's axes
--   board    list of { name = Skate 3 bone, pos = Vector from origin, q = quat }

local Pose = {}

local Q = 32767
local MAX_BONE = 1023
local POS_SCALE = 64 -- 1/64 of a unit, up to 512 units away

local function Round(x) return math.floor(x + 0.5) end
local function Clamp16(x) return math.Clamp(Round(x), -32767, 32767) end
local function Finite(x) return x == x and x > -1e7 and x < 1e7 end

local function WriteQuat(q)
	for k = 1, 4 do net.WriteInt(Clamp16(q[k] * Q), 16) end
end

local function ReadQuat()
	local q = {}
	for k = 1, 4 do q[k] = net.ReadInt(16) / Q end
	return q
end

local function WriteSmall(v, scale)
	net.WriteInt(Clamp16(v.x * scale), 16)
	net.WriteInt(Clamp16(v.y * scale), 16)
	net.WriteInt(Clamp16(v.z * scale), 16)
end

local function ReadSmall(scale)
	return Vector(net.ReadInt(16) / scale, net.ReadInt(16) / scale, net.ReadInt(16) / scale)
end

local function WriteDir(v)
	for _, c in ipairs({ v.x, v.y, v.z }) do net.WriteInt(math.Clamp(Round(c * 127), -127, 127), 8) end
end

local function ReadDir()
	return Vector(net.ReadInt(8) / 127, net.ReadInt(8) / 127, net.ReadInt(8) / 127)
end

function Pose.Write(f)
	net.WriteFloat(f.origin.x)
	net.WriteFloat(f.origin.y)
	net.WriteFloat(f.origin.z)
	net.WriteUInt(Round((f.yaw % 360) / 360 * 65535) % 65536, 16)
	net.WriteString(f.state or "")
	WriteDir(f.forward or Vector(1, 0, 0))
	WriteDir(f.up or Vector(0, 0, 1))
	local bones = f.bones or {}
	net.WriteUInt(math.min(#bones, 255), 8)
	for n = 1, math.min(#bones, 255) do
		net.WriteUInt(math.Clamp(bones[n].i, 0, MAX_BONE), 10)
		WriteQuat(bones[n].q)
	end
	net.WriteBool(f.pelvis ~= nil)
	if f.pelvis then
		net.WriteUInt(math.Clamp(f.pelvis, 0, MAX_BONE), 10)
		WriteSmall(f.ppos, POS_SCALE)
	end
	local board = f.board or {}
	net.WriteUInt(math.min(#board, 15), 4)
	for n = 1, math.min(#board, 15) do
		net.WriteString(board[n].name)
		WriteSmall(board[n].pos, POS_SCALE)
		WriteQuat(board[n].q)
	end
end

-- Nil when the frame is garbage (NaN or off the map).
function Pose.Read()
	local f = {}
	local x, y, z = net.ReadFloat(), net.ReadFloat(), net.ReadFloat()
	if not (Finite(x) and Finite(y) and Finite(z)) then return nil end
	f.origin = Vector(x, y, z)
	f.yaw = net.ReadUInt(16) / 65535 * 360
	f.state = net.ReadString()
	f.forward = ReadDir()
	f.up = ReadDir()
	f.bones = {}
	for n = 1, net.ReadUInt(8) do
		f.bones[n] = { i = net.ReadUInt(10), q = ReadQuat() }
	end
	if net.ReadBool() then
		f.pelvis = net.ReadUInt(10)
		f.ppos = ReadSmall(POS_SCALE)
	end
	f.board = {}
	for n = 1, net.ReadUInt(4) do
		f.board[n] = { name = net.ReadString(), pos = ReadSmall(POS_SCALE), q = ReadQuat() }
	end
	return f
end

return Pose
