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
			{ "Half-Life 2 (classic)", "hl2" },
			{ "Skate 3 (from your disc)", "disc" },
			{ "Off", "off" },
		})
		panel:ControlHelp("Skate 3's own sounds come from your disc: run setup to install them. Rolling is in so far (it follows the surface and your speed); the rest still use Half-Life 2.")
		panel:NumSlider("Volume", "skate3_volume", 0, 1, 2)

		panel:CheckBox("Show the trick score", "skate3_score_hud")
		panel:CheckBox("Show the status line", "skate3_hud")
	end)
end)
