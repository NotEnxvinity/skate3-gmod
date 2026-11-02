-- Switching playermodels from the L1 menu (cl_customize.lua). The client asks
-- by name; the server only accepts a model that is registered here (the same
-- list the sandbox's playermodel picker uses), not too often, and tells the
-- client how it went. skate3_allow_model_switch = 0 turns it off for a server.
-- Every request and its outcome is printed to the server console.

util.AddNetworkString("skate3_playermodel")

local cv_allow = CreateConVar("skate3_allow_model_switch", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED + FCVAR_NOTIFY,
	"Players can switch playermodel from the S3GM menu (1 on, 0 off)")

local function Reply(ply, ok, text)
	print(("[skate3] playermodel for %s: %s (%s)"):format(ply:Nick(), ok and "switched" or "refused", text))
	net.Start("skate3_playermodel")
	net.WriteBool(ok)
	net.WriteString(text)
	net.Send(ply)
end

-- The registered name for what the client asked for: exact, else the same
-- name in another case.
local function Registered(name)
	local all = player_manager.AllValidModels()
	if all[name] then return name end
	local lower = name:lower()
	for k in pairs(all) do
		if k:lower() == lower then return k end
	end
end

net.Receive("skate3_playermodel", function(_, ply)
	local asked = net.ReadString()
	print(("[skate3] playermodel for %s: asked for %q"):format(ply:Nick(), asked))
	if not cv_allow:GetBool() then return Reply(ply, false, "This server doesn't allow switching playermodel") end
	if not ply:Alive() then return Reply(ply, false, "Not while you're down") end
	if (ply.skate3ModelAt or -math.huge) + 1 > CurTime() then return Reply(ply, false, "Easy, one switch at a time") end
	local name = Registered(asked)
	if not name then return Reply(ply, false, "That playermodel isn't registered on the server") end
	local path = player_manager.TranslatePlayerModel(name)
	if not (file.Exists(path, "GAME") or util.IsValidModel(path)) then return Reply(ply, false, "That playermodel's files aren't on the server") end
	ply.skate3ModelAt = CurTime()
	util.PrecacheModel(path)
	-- The entity's own SetModel, not the player's: addons like Enhanced
	-- PlayerModel Selector replace Player:SetModel with an "enforcer" that
	-- silently refuses every model but their own (Enx's test 4b did nothing).
	FindMetaTable("Entity").SetModel(ply, path)
	ply:SetSkin(0)
	for i = 0, ply:GetNumBodyGroups() - 1 do ply:SetBodygroup(i, 0) end
	-- The viewmodel hands follow the model; a gamemode that does this its own way
	-- must not stop the switch.
	if ply.SetupHands then
		local ok, err = pcall(ply.SetupHands, ply)
		if not ok then print("[skate3] playermodel: SetupHands failed: " .. tostring(err)) end
	end
	if ply:GetModel():lower() ~= path:lower() then
		return Reply(ply, false, "Another addon is holding your playermodel")
	end
	Reply(ply, true, name)
end)
