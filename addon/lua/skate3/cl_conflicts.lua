-- Addons known to break S3GM. When one is mounted, the player gets one chat
-- warning after joining, and the settings list it. To add one: a lower-case
-- piece of its Workshop title (and its Workshop id when known) plus what goes
-- wrong.

local KNOWN = {
	{ title = "better'er grab", why = "turns your skateboard into a can" },
}

local Conflicts = {}

-- The known-bad addons that are mounted right now: { { title, why }, ... }.
function Conflicts.Found()
	local found = {}
	for _, addon in ipairs(engine.GetAddons()) do
		if addon.mounted then
			local title = string.lower(addon.title or "")
			for _, k in ipairs(KNOWN) do
				if (k.wsid and tostring(addon.wsid) == k.wsid) or (k.title and title:find(k.title, 1, true)) then
					found[#found + 1] = { title = addon.title, why = k.why }
				end
			end
		end
	end
	return found
end

hook.Add("InitPostEntity", "skate3_conflicts", function()
	timer.Simple(5, function()
		for _, c in ipairs(Conflicts.Found()) do
			chat.AddText(Color(255, 180, 0), "[S3GM] ", color_white, "\"" .. c.title .. "\" " .. c.why ..
				". Disable it in the Addons menu to skate properly.")
			print(("[skate3] conflicting addon mounted: %s (%s)"):format(c.title, c.why))
		end
	end)
end)

return Conflicts
