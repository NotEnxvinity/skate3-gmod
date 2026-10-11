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

-- What "Reset these to defaults" puts back.
local DEFAULTS = { "skate3_stance", "skate3_camera", "skate3_sounds", "skate3_bail_sounds", "skate3_footsteps",
	"skate3_volume", "skate3_score_hud", "skate3_score_style", "skate3_hud" }

hook.Add("PopulateToolMenu", "skate3_menu", function()
	spawnmenu.AddToolMenuOption("Utilities", "Skate 3", "skate3_settings", "Settings", "", "", function(panel)
		panel:ClearControls()
		panel:Help("Equip the Skateboard weapon to skate. Y gets on and off the board, A pushes.")

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

		local reset = panel:Button("Reset these to defaults")
		reset.DoClick = function()
			for _, name in ipairs(DEFAULTS) do
				local cv = GetConVar(name)
				if cv then RunConsoleCommand(name, cv:GetDefault()) end
			end
		end
	end)
end)
