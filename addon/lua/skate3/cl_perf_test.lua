-- skate3_perf_test: what riding costs in frame rate, part by part. While
-- you're on the board, it measures the frame rate as is, then switches off
-- one part of the mod at a time (the same switches as skate3_debug_skip) for
-- a few seconds each, and ranks the parts by how much frame rate each one
-- gave back. Last, it gets off the board for a moment to measure the game
-- without the mod riding, and puts you back on. The ranking goes to the
-- console, to chat, and to garrysmod/data/skate3/perf_report.txt.

local SETTLE = 1.5 -- seconds after each switch before measuring
local MEASURE = 4 -- seconds measured per part

-- { switches (skate3_debug_skip words), what it is }
local PARTS = {
	{ nil, "everything on (start)" },
	{ "props", "spawned prop scan" },
	{ "bones", "posing your playermodel" },
	{ "anim", "face and finger animation" },
	{ "model", "drawing your playermodel" },
	{ "board", "drawing the board" },
	{ "score", "score display" },
	{ "hom", "Hall of Meat X-ray" },
	{ "sounds", "skate sounds" },
	{ "net", "sending your ride to the server" },
	{ "view", "skate camera" },
	{ "others", "other skaters" },
	{ "step,pose", "skate simulation" },
	{ "props,bones,anim,model,board,score,hom,sounds,net,others,step,pose", "all of the above at once" },
	{ nil, "everything on (end)" },
	{ "off", "off the board (board still out)" },
}

return function(Skater, ride)
	local test -- the run in progress

	local function SetSkip(words)
		local skip = {}
		for word in (words or ""):gmatch("[%w_]+") do skip[word] = true end
		Skater.Skip = skip
	end

	local function Finish(aborted)
		local t = test
		test = nil
		hook.Remove("Think", "skate3_perf_test")
		-- Back to whatever skate3_debug_skip says.
		local cv = GetConVar("skate3_debug_skip")
		SetSkip(cv and cv:GetString() or "")
		if t.wasOff and not ride.active() then ride.restart(t.at, t.yaw) end
		if aborted then
			chat.AddText(Color(120, 200, 255), "[skate3] ", color_white, "Speed test stopped: " .. aborted)
			return
		end
		local base = {}
		for _, r in ipairs(t.results) do
			if r.part[1] == nil then base[#base + 1] = r.ms end
		end
		local baseMs = (base[1] + base[2]) / 2
		local lines = {}
		local function Add(s) lines[#lines + 1] = s end
		Add(("S3GM speed test, %s, map %s, playermodel %s"):format(os.date("%Y-%m-%d %H:%M"), game.GetMap(),
			tostring(LocalPlayer():GetModel())))
		Add(("riding with everything on: %.0f fps (%.1f ms a frame; start %.0f fps, end %.0f fps)"):format(
			1000 / baseMs, baseMs, 1000 / base[1], 1000 / base[2]))
		Add(("the start and end runs differ by %.1f ms, so gains smaller than that are noise"):format(math.abs(base[1] - base[2])))
		local ranked = {}
		for _, r in ipairs(t.results) do
			if r.part[1] ~= nil then ranked[#ranked + 1] = r end
		end
		table.sort(ranked, function(a, b) return a.ms < b.ms end)
		Add("frame rate with each part switched off, biggest gain first:")
		for n, r in ipairs(ranked) do
			Add(("%2d. %-36s %4.0f fps (%+5.0f fps, %+5.1f ms a frame)"):format(n, r.part[2], 1000 / r.ms,
				1000 / r.ms - 1000 / baseMs, baseMs - r.ms))
		end
		file.CreateDir("skate3")
		file.Write("skate3/perf_report.txt", table.concat(lines, "\n") .. "\n")
		for _, l in ipairs(lines) do print("[skate3] " .. l) end
		print("[skate3] saved garrysmod/data/skate3/perf_report.txt")
		local top = ranked[1]
		chat.AddText(Color(120, 200, 255), "[skate3] ", color_white,
			("Speed test done: %.0f fps riding. Biggest gain: %s (%+.0f fps). Full list in the console and data/skate3/perf_report.txt"):format(
				1000 / baseMs, top.part[2], 1000 / top.ms - 1000 / baseMs))
	end

	local function Begin(n)
		local t = test
		t.n, t.since, t.sum, t.frames = n, SysTime(), 0, 0
		local part = PARTS[n]
		if part[1] == "off" then
			t.wasOff = true
			ride.stop()
			SetSkip(nil)
		else
			SetSkip(part[1])
		end
		print(("[skate3] speed test %d/%d: %s"):format(n, #PARTS, part[2]))
	end

	concommand.Add("skate3_perf_test", function()
		if test then Finish("you ran it again") return end
		if not ride.active() then
			chat.AddText(Color(120, 200, 255), "[skate3] ", color_white, "Get on the board first, then run skate3_perf_test.")
			return
		end
		local at, yaw = ride.where()
		test = { results = {}, last = SysTime(), at = at, yaw = yaw }
		chat.AddText(Color(120, 200, 255), "[skate3] ", color_white,
			("Speed test: about %d seconds. Stand still on the board and don't touch anything. Your body and board will flicker, that's the test."):format(
				math.ceil(#PARTS * (SETTLE + MEASURE))))
		Begin(1)
		hook.Add("Think", "skate3_perf_test", function()
			local t = test
			local now = SysTime()
			local dt = now - t.last
			t.last = now
			local part = PARTS[t.n]
			if part[1] ~= "off" and not ride.active() then Finish("you got off the board") return end
			if now - t.since < SETTLE then return end
			t.sum, t.frames = t.sum + dt, t.frames + 1
			if now - t.since < SETTLE + MEASURE then return end
			t.results[#t.results + 1] = { part = part, ms = t.sum / t.frames * 1000 }
			if t.n == #PARTS then Finish() else Begin(t.n + 1) end
		end)
	end, nil, "Measure what each part of riding costs in frame rate (stand still on the board)")
end
