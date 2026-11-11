-- Skate 3 settings in the spawn menu: Utilities > Skate 3 > Settings.

hook.Add("AddToolMenuCategories", "skate3_menu", function()
	spawnmenu.AddToolCategory("Utilities", "Skate 3", "Skate 3")
end)

local function Choices(panel, label, convar, choices)
	local combo = panel:ComboBox(label, convar)
	for _, c in ipairs(choices) do
		combo:AddChoice(c[1], c[2])
	end
	return combo
end

local Boards = include("skate3/cl_boards.lua")
local Conflicts = include("skate3/cl_conflicts.lua")
local Keyboard = S3GM_Keyboard -- loaded just before this file

-- What "Reset these to defaults" puts back.
local DEFAULTS = { "skate3_stance", "skate3_camera", "skate3_retail_audio", "skate3_sounds", "skate3_bail_sounds", "skate3_footsteps",
	"skate3_volume", "skate3_score_hud", "skate3_score_style", "skate3_ui_style", "skate3_ui_crisp", "skate3_ui_glyphs", "skate3_ui_world", "skate3_menu", "skate3_hud", "skate3_melee", "skate3_update_notices", "skate3_hom_look", "skate3_ui_hd" }
for _, p in ipairs(Boards.PARTS) do
	DEFAULTS[#DEFAULTS + 1] = p.look
	DEFAULTS[#DEFAULTS + 1] = p.color
end
for _, name in ipairs(Keyboard.CONVARS) do DEFAULTS[#DEFAULTS + 1] = name end
for _, name in ipairs(S3GM_Gestures and S3GM_Gestures.CONVARS or {}) do DEFAULTS[#DEFAULTS + 1] = name end

-- The settings also live in data/skate3/settings.json, written on every
-- change. Garry's Mod only saves its own copy when the game closes normally,
-- so closing it from Steam (or a crash) used to lose a custom board.
local SAVED = "skate3/settings.json"
local loading = false
local function Save()
	if loading then return end
	local out = {}
	for _, name in ipairs(DEFAULTS) do
		local cv = GetConVar(name)
		if cv then out[name] = cv:GetString() end
	end
	file.CreateDir("skate3")
	file.Write(SAVED, util.TableToJSON(out, true))
end
-- Once every file has made its convars (stance and camera come later).
hook.Add("Initialize", "skate3_saved", function()
	local saved = util.JSONToTable(file.Read(SAVED, "DATA") or "") or {}
	loading = true
	for _, name in ipairs(DEFAULTS) do
		local cv, value = GetConVar(name), saved[name]
		if cv and isstring(value) and cv:GetString() ~= value then cv:SetString(value) end
	end
	loading = false
	for _, name in ipairs(DEFAULTS) do
		cvars.AddChangeCallback(name, Save, "skate3_saved")
	end
end)

-- What Skate 3's own sound engine (the port of retail's audio, in the skate
-- module) is doing, in a line the player can read.
local function EngineStatus()
	if not skate3 or not skate3.AudioReady then return "Not in this version of the skate module." end
	local cv = GetConVar("skate3_retail_audio")
	if cv and not cv:GetBool() then return "Off: the sounds chosen below play." end
	if skate3.AudioReady() then return "Running: everything plays as Skate 3's own sounds." end
	if not file.Exists("skate3/audio-cache/manifest.json", "DATA") then
		return "Not set up: run the S3GM setup again with the sound engine box ticked. The sounds chosen below play until then."
	end
	return "Starting, or unavailable: " .. tostring((skate3.AudioStatus())) .. ". The sounds chosen below play meanwhile."
end

-- Keyboard and mouse, still early: the switch, the mouse feel and every key.
local function KeyboardChoices(panel)
	panel:Help("Keyboard and mouse (early)")
	panel:CheckBox("Skate with keyboard and mouse", "skate3_keyboard")
	panel:ControlHelp("Still early: a controller is the best way to play. The keys below only do this while you're skating; the rest of the time they do what they normally do.")
	panel:NumSlider("Mouse flick strength", "skate3_kb_mouse", 0.2, 3, 2)
	panel:NumSlider("Trick stick return (seconds)", "skate3_kb_mouse_return", 0.05, 0.5, 2)
	panel:ControlHelp("The mouse is the right stick: pull it back to crouch, flick it forward to ollie.")
	for _, b in ipairs(Keyboard.BINDS) do
		local binder = vgui.Create("DBinder")
		binder:SetConVar(b.convar)
		binder:SetValue(b.cv:GetInt())
		panel:AddItem(Label(b.name), binder)
	end
end

-- The board's looks from the player's disc, and a colour for each part.
local function BoardChoices(panel)
	panel:Help("Your board")
	local list = Boards.List()
	local any = false
	for _, p in ipairs(Boards.PARTS) do
		local looks = list[p.slot] or {}
		if #looks > 1 then
			any = true
			local choices = { { "Usual", "" } }
			for _, look in ipairs(looks) do
				if not look.default then
					choices[#choices + 1] = { look.name .. (look.worn and " (worn)" or ""), look.id }
				end
			end
			Choices(panel, p.name, p.look, choices)
		end
		Choices(panel, p.name .. " colour", p.color, Boards.COLORS)
	end
	if not any then
		panel:ControlHelp("Run the S3GM setup again to get the decks, trucks and wheels from your disc.")
	end
end

hook.Add("PopulateToolMenu", "skate3_menu", function()
	spawnmenu.AddToolMenuOption("Utilities", "Skate 3", "skate3_settings", "Settings", "", "", function(panel)
		panel:ClearControls()
		panel:Help("Equip the Skateboard weapon to skate. Y gets on and off the board, A pushes. (Keyboard: E and Space.)")
		for _, c in ipairs(Conflicts.Found()) do
			local warn = panel:Help("Warning: \"" .. c.title .. "\" " .. c.why .. ". Disable it in the Addons menu.")
			warn:SetTextColor(Color(220, 120, 0))
		end

		Choices(panel, "Stance", "skate3_stance", {
			{ "Regular", "regular" },
			{ "Goofy", "goofy" },
		})
		panel:ControlHelp("Takes effect the next time you equip the board.")

		Choices(panel, "Camera", "skate3_camera", {
			{ "Low", "low" },
			{ "Normal", "normal" },
			{ "High", "high" },
		})

		panel:CheckBox("Skate 3's own sound engine (beta)", "skate3_retail_audio")
		local engine = panel:ControlHelp(EngineStatus())
		engine.Think = function(self)
			if CurTime() < (self.nextCheck or 0) then return end
			self.nextCheck = CurTime() + 1
			self:SetText(EngineStatus())
		end
		panel:ControlHelp("It plays every skate sound the way the game does. The choices below are for when it's off or isn't set up.")
		Choices(panel, "Sounds", "skate3_sounds", {
			{ "Skate 3 (from your disc)", "disc" },
			{ "Half-Life 2 (classic)", "hl2" },
			{ "Off", "off" },
		})
		panel:ControlHelp("Without the engine: Skate 3's own sounds come from your disc, run setup to install them.")
		Choices(panel, "Bail sounds", "skate3_bail_sounds", {
			{ "Skate 3 (from your disc)", "disc" },
			{ "Half-Life 2", "hl2" },
		})
		Choices(panel, "Footsteps", "skate3_footsteps", {
			{ "Garry's Mod", "hl2" },
			{ "Skate 3 (from your disc)", "disc" },
		})
		panel:ControlHelp("Without the engine, and with the Skate 3 sounds: whose bails and footsteps to play.")
		panel:NumSlider("Volume", "skate3_volume", 0, 1, 2)

		panel:CheckBox("Show the trick score", "skate3_score_hud")
		Choices(panel, "Interface look", "skate3_ui_style", {
			{ "Skate 3 (from your disc)", "skate3" },
			{ "Minimal", "minimal" },
			{ "Half-Life 2", "hl2" },
		})
		panel:ControlHelp("Skate 3's own look comes from your disc: run the S3GM setup again after updating if it isn't there yet (until then you get Minimal).")
		panel:CheckBox("HD UI images (only if you added the HD pack)", "skate3_ui_hd")
		panel:CheckBox("Sharp text (the disc's Futura font)", "skate3_ui_crisp")
		panel:ControlHelp("Setup installs the disc's Futura as a real font so the text stays sharp at any resolution. Restart the game after running setup.")
		Choices(panel, "Button pictures", "skate3_ui_glyphs", {
			{ "Automatic (by your controller)", "auto" },
			{ "Xbox", "xbox" },
			{ "PlayStation", "playstation" },
		})
		panel:ControlHelp("Automatic goes by your controller's name. Steam Input can make a PlayStation pad look like an Xbox one, so pick PlayStation here if it guesses wrong.")
		panel:CheckBox("Trick score beside the skater, not on screen", "skate3_ui_world")
		panel:CheckBox("Contextual menu (hold L1 or Shift)", "skate3_menu")
		panel:ControlHelp("Hold L1 for the menu: D-pad down places your marker, hold up goes back to it, left interacts, right customizes, Y opens games and X opens settings (up and down pick a row, left and right change a setting, B goes back).")
		local Gestures = S3GM_Gestures
		if Gestures then
			panel:CheckBox("D-pad gestures", "skate3_gestures")
			panel:ControlHelp("Tap the D-pad (no L1) while skating or on foot for one of Skate 3's 37 gestures; hold it to keep it going. They use whichever hand is free. Pick yours below, or in the L1 menu's Settings.")
			for _, d in ipairs(Gestures.DIRECTIONS) do
				local list = {}
				for _, g in ipairs(Gestures.LIST) do list[#list + 1] = { g[2], g[1] } end
				Choices(panel, "D-pad " .. d[2]:lower(), "skate3_gesture_" .. d[1], list)
			end
		end
		panel:CheckBox("Tell me about new releases", "skate3_update_notices")
		panel:ControlHelp("Looks at GitHub shortly after you join a game (about once every six hours) and, if S3GM has a newer release, shows a small card once and an \"Update available\" line in the menu's Settings. Off means no check at all. Console: skate3_update_check checks right now.")
		panel:CheckBox("Show the status line", "skate3_hud")
		panel:CheckBox("Hall of Meat", "skate3_hall_of_meat")
		panel:ControlHelp("Bails score points and break bones, shown in red, with the skeleton showing through your skater. Bail on purpose: hold both triggers and click both sticks.")
		Choices(panel, "Hall of Meat bones", "skate3_hom_look", {
			{ "Skeleton (Skate 3's own)", "skeleton" },
			{ "X-ray (plain bone lines)", "xray" },
		})
		panel:ControlHelp("The skeleton is Skate 3's own Hall of Meat model, made from your disc by the setup: run the S3GM setup again after updating if it isn't there yet (until then you get the X-ray lines).")

		panel:CheckBox("Punch and smack other players", "skate3_melee")
		panel:ControlHelp("On foot, B or R1 (F or Ctrl): punches, or a smack with the board when you hold it. Skaters who run into each other bail.")
		-- Server settings: the host's to change (a dedicated server sets them in its config).
		if game.SinglePlayer() or LocalPlayer():IsListenServerHost() then
			panel:CheckBox("Server: skaters crash into other players", "skate3_player_collision")
			panel:NumSlider("Server: crash speed (m/s)", "skate3_player_collision_speed", 0.5, 20, 1)
			panel:CheckBox("Server: punches and board swings", "skate3_player_hits")
			panel:NumSlider("Server: health a punch takes", "skate3_hit_damage", 0, 50, 0)
			panel:ControlHelp("0 health means hits don't hurt, they just knock people over.")
		end

		BoardChoices(panel)
		KeyboardChoices(panel)

		local reset = panel:Button("Reset these to defaults")
		reset.DoClick = function()
			for _, name in ipairs(DEFAULTS) do
				local cv = GetConVar(name)
				if cv then RunConsoleCommand(name, cv:GetDefault()) end
			end
		end
	end)
end)
