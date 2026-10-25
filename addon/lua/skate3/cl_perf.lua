-- Where a hitch went: each frame, how long each part of the mod's own work
-- took. When a frame runs long, the console says which parts of it were ours
-- and how long they took, so a hitch the mod didn't cause shows up as one
-- whose time went elsewhere (the map, the game, another addon, the network).

local Perf = {}

local cv = CreateClientConVar("skate3_debug_hitches", "1", true, false,
	"Print what the mod was doing in each frame that hitched (longer than skate3_debug_hitch_ms)")
local cv_ms = CreateClientConVar("skate3_debug_hitch_ms", "30", true, false,
	"How long a frame must take, in ms, to count as a hitch for skate3_debug_hitches")

-- At most one hitch line this often, so a run of them doesn't flood the console.
local PRINT_EVERY = 1

local frame = {} -- part -> seconds spent this frame
local notes = {} -- what happened this frame, such as a prop swap
local last, lastNotes = {}, {}
local starts = {}
local nextPrint = 0
-- Lua's heap at the last frame: a drop since then means the collector ran in
-- the frame that just finished.
local lastKB = collectgarbage("count")

function Perf.Begin(part)
	starts[part] = SysTime()
end

function Perf.End(part)
	local s = starts[part]
	if not s then return end
	starts[part] = nil
	frame[part] = (frame[part] or 0) + SysTime() - s
end

-- Times fn(...) as `part`.
function Perf.Time(part, fn, ...)
	local s = SysTime()
	local a, b, c = fn(...)
	frame[part] = (frame[part] or 0) + SysTime() - s
	return a, b, c
end

function Perf.Note(text)
	notes[#notes + 1] = text
end

-- Start of each frame: FrameTime() is how long the frame just finished took,
-- so it's checked against what was timed in it.
function Perf.Frame()
	local dt = FrameTime()
	local kb = collectgarbage("count")
	local freed = lastKB - kb
	lastKB = kb
	last, lastNotes = frame, notes
	frame, notes = {}, {}
	if not cv:GetBool() or dt * 1000 < cv_ms:GetFloat() then return end
	local now = RealTime()
	if now < nextPrint then return end
	nextPrint = now + PRINT_EVERY
	local ours, parts = 0, {}
	for part, t in pairs(last) do
		ours = ours + t
		if t >= 0.001 then parts[#parts + 1] = { part, t } end
	end
	table.sort(parts, function(a, b) return a[2] > b[2] end)
	local list = {}
	for i, p in ipairs(parts) do
		if i > 5 then break end
		list[#list + 1] = ("%s %.0f ms"):format(p[1], p[2] * 1000)
	end
	-- Where the skater was and how fast, and whether Lua's collector ran.
	local me = LocalPlayer()
	local where = ""
	if IsValid(me) then
		local p = me:GetPos()
		where = (" at %.0f %.0f %.0f, %.0f u/s"):format(p.x, p.y, p.z, me:GetVelocity():Length())
	end
	print(("[skate3] hitch: frame took %.0f ms, the mod's own work %.0f ms%s%s%s%s"):format(dt * 1000, ours * 1000,
		#list > 0 and " (" .. table.concat(list, ", ") .. ")" or "",
		#lastNotes > 0 and "; " .. table.concat(lastNotes, "; ") or "",
		freed > 2048 and ("; lua collector freed %.0f MB"):format(freed / 1024) or "", where))
end

-- Bytes the mod sent and got, for the health line.
local sent, got = 0, 0
function Perf.Sent(bytes) sent = sent + bytes end
function Perf.Got(bytes) got = got + bytes end
function Perf.TakeNet()
	local s, g = sent, got
	sent, got = 0, 0
	return s, g
end

return Perf
