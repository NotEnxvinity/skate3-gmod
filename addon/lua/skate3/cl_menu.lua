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

-- What "Reset these to defaults" puts back.
local DEFAULTS = { "skate3_stance", "skate3_camera", "skate3_sounds", "skate3_bail_sounds", "skate3_footsteps",
	"skate3_volume", "skate3_score_hud", "skate3_score_style", "skate3_hud" }
for _, p in ipairs(Boards.PARTS) do
	DEFAULTS[#DEFAULTS + 1] = p.look
	DEFAULTS[#DEFAULTS + 1] = p.color
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
		panel:Help("Equip the Skateboard weapon to skate. Y gets on and off the board, A pushes.")
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

		Choices(panel, "Sounds", "skate3_sounds", {
			{ "Skate 3 (from your disc)", "disc" },
			{ "Half-Life 2 (classic)", "hl2" },
			{ "Off", "off" },
		})
		panel:ControlHelp("Skate 3's own sounds come from your disc: run setup to install them.")
		Choices(panel, "Bail sounds", "skate3_bail_sounds", {
			{ "Skate 3 (from your disc)", "disc" },
			{ "Half-Life 2", "hl2" },
		})
		Choices(panel, "Footsteps", "skate3_footsteps", {
			{ "Garry's Mod", "hl2" },
			{ "Skate 3 (from your disc)", "disc" },
		})
		panel:ControlHelp("With the Skate 3 sounds: whose bails and footsteps to play.")
		panel:NumSlider("Volume", "skate3_volume", 0, 1, 2)

		panel:CheckBox("Show the trick score", "skate3_score_hud")
		Choices(panel, "Score look", "skate3_score_style", {
			{ "Minimal, on screen", "minimal" },
			{ "Minimal, beside the skater", "world" },
			{ "Half-Life 2", "hl2" },
		})
		panel:CheckBox("Show the status line", "skate3_hud")

		BoardChoices(panel)

		local reset = panel:Button("Reset these to defaults")
		reset.DoClick = function()
			for _, name in ipairs(DEFAULTS) do
				local cv = GetConVar(name)
				if cv then RunConsoleCommand(name, cv:GetDefault()) end
			end
		end
	end)
end)
