-- Customize: the player's own look, from the L1 menu. D-pad right on the root
-- menu opens a short list (Playermodel, Board). Nothing here changes anything
-- by itself while you browse:
--
--   Playermodel  every model installed in Garry's Mod, with its icon. Up and
--                down only look; right on one asks "Switch to ...?" (No is
--                where the cursor starts) and Yes asks the server to change
--                it (sv_customize.lua), then sets cl_playermodel so the pick
--                survives a respawn and a restart.
--   Board        the deck, trucks and wheels from the player's own disc and a
--                colour for each (cl_boards.lua). Left and right change a row
--                and the board repaints at once, because you can see it right
--                there and it costs nothing to change back; "Reset" puts the
--                usual board back.
--
-- B goes back one level, from every list.

local Menu = S3GM_Menu
local UI = S3GM_UI
local Boards = include("skate3/cl_boards.lua")

---------------------------------------------------------------------------
-- Playermodel

-- "gman_high" -> "Gman High"
local function Pretty(name)
	return (tostring(name):gsub("[_%-]+", " "):gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end

local function Norm(path) return ((path or ""):lower():gsub("\\", "/")) end

-- Every installed playermodel, by name, with the one on now marked.
local function ModelRows()
	local me = IsValid(LocalPlayer()) and Norm(LocalPlayer():GetModel()) or ""
	local rows, sel = {}, 1
	for name, path in pairs(player_manager.AllValidModels()) do
		rows[#rows + 1] = { label = Pretty(name), model = path, name = name, key = name:lower() }
	end
	table.sort(rows, function(a, b) return a.key < b.key end)
	for i, r in ipairs(rows) do
		if Norm(player_manager.TranslatePlayerModel(r.name)) == me then
			r.tag = "Wearing"
			sel = i
		end
	end
	return rows, sel
end

local function CurrentName()
	local me = IsValid(LocalPlayer()) and Norm(LocalPlayer():GetModel()) or ""
	for name in pairs(player_manager.AllValidModels()) do
		if Norm(player_manager.TranslatePlayerModel(name)) == me then return Pretty(name) end
	end
	return "Unknown"
end

local asked -- the model name waiting for the server's answer
local shown = {} -- the rows of the playermodel list, so "Wearing" can move

local function Say(text)
	print("[skate3] playermodel: " .. text)
end

-- Asks the server to switch you to the registered model `name`. The server
-- answers either way (below); if nothing comes back the player is told so
-- rather than left guessing.
local function Switch(name)
	asked = name
	Say(("asking the server for %q (it is %s now)"):format(name, tostring(LocalPlayer():GetModel())))
	net.Start("skate3_playermodel")
	net.WriteString(name)
	net.SendToServer()
	timer.Create("skate3_playermodel_wait", 3, 1, function()
		if asked ~= name then return end
		asked = nil
		Say("the server never answered")
		UI.Toast("The server didn't answer: is S3GM installed on it?")
	end)
end

-- The server's answer: ok and the name it applied, or not ok and why.
net.Receive("skate3_playermodel", function()
	local ok, text = net.ReadBool(), net.ReadString()
	timer.Remove("skate3_playermodel_wait")
	asked = nil
	if not ok then
		Say("the server said no: " .. text)
		UI.Toast(text)
		return
	end
	Say("the server switched you to " .. text)
	-- Remember it for respawns and restarts (the sandbox applies these on spawn).
	RunConsoleCommand("cl_playermodel", text)
	RunConsoleCommand("cl_playerskin", "0")
	RunConsoleCommand("cl_playerbodygroups", "")
	for _, r in ipairs(shown) do r.tag = (r.name == text) and "Wearing" or nil end
	UI.Toast("Now skating as " .. Pretty(text))
	-- The model arrives with the next network update; say so if it never does.
	timer.Simple(2, function()
		local want = Norm(player_manager.TranslatePlayerModel(text))
		if IsValid(LocalPlayer()) and Norm(LocalPlayer():GetModel()) ~= want then
			Say(("still wearing %s after the switch to %s (%s)"):format(tostring(LocalPlayer():GetModel()), text, want))
		end
	end)
end)

-- From the console too, for trying a model without the menu: skate3_playermodel <name>
concommand.Add("skate3_playermodel", function(_, _, args, line)
	local name = (line or ""):Trim():gsub('^"(.*)"$', "%1")
	if name == "" then
		Say("usage: skate3_playermodel <name>  (a name from the playermodel list, e.g. alyx)")
		return
	end
	Switch(name)
end)

local function OpenModels()
	local rows, sel = ModelRows()
	shown = rows
	Menu.OpenList({
		title = "Playermodel",
		rows = rows,
		sel = sel,
		empty = "No playermodels found",
		onPick = function(row)
			if row.tag == "Wearing" then
				UI.Toast("You're already " .. row.label)
				return
			end
			-- Right on a model asks once; Yes is under the cursor, so right again
			-- does it, and left or B backs out.
			Menu.Prompt("Switch to " .. row.label .. "?", {
				{ label = "Yes", run = function() Switch(row.name) end },
				{ label = "No" },
			})
		end,
	})
end

---------------------------------------------------------------------------
-- Board

local function BoardChoices()
	local list = Boards.List()
	local out = {}
	for _, p in ipairs(Boards.PARTS) do
		local looks = list[p.slot] or {}
		if #looks > 1 then
			local choices = { { "Usual", "" } }
			for _, look in ipairs(looks) do
				if not look.default then
					choices[#choices + 1] = { look.name .. (look.worn and " (worn)" or ""), look.id }
				end
			end
			out[#out + 1] = { label = p.name, cv = p.look, choices = choices }
		end
		out[#out + 1] = { label = p.name .. " colour", cv = p.color, choices = Boards.COLORS }
	end
	return out
end

local function IndexOf(row)
	local now = GetConVar(row.cv):GetString()
	for i, c in ipairs(row.choices) do
		if c[2] == now then return i end
	end
	return 1
end

local function BoardRows()
	local rows = {}
	for _, def in ipairs(BoardChoices()) do
		rows[#rows + 1] = { label = def.label, tag = def.choices[IndexOf(def)][1], def = def }
	end
	rows[#rows + 1] = { label = "Usual board", tag = "Reset", reset = true, info = true }
	return rows
end

local function OpenBoard()
	Menu.OpenList({
		title = "Board",
		rows = BoardRows(),
		refresh = BoardRows,
		onAdjust = function(row, dir)
			if row.reset then
				if dir == 1 then
					for _, p in ipairs(Boards.PARTS) do
						RunConsoleCommand(p.look, "")
						RunConsoleCommand(p.color, "")
					end
					UI.Toast("Back to the usual board")
				end
				return
			end
			local n = #row.def.choices
			local i = (IndexOf(row.def) - 1 + dir) % n + 1
			RunConsoleCommand(row.def.cv, row.def.choices[i][2])
		end,
	})
end

---------------------------------------------------------------------------
-- The list the root menu's D-pad right opens

Menu.OnCustomize = function()
	Menu.OpenList({
		title = "Customize",
		rows = {
			{ label = "Playermodel", tag = CurrentName(), open = OpenModels },
			{ label = "Board", open = OpenBoard },
		},
		onPick = function(row) row.open() end,
	})
end
