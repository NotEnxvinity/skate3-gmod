-- Switching playermodels from the L1 menu (cl_customize.lua). The client asks
-- by name; the server only accepts a model that is installed (the same list
-- the sandbox's playermodel picker uses), not too often, and tells the client
-- how it went. skate3_allow_model_switch = 0 turns it off for a server.

util.AddNetworkString("skate3_playermodel")

local cv_allow = CreateConVar("skate3_allow_model_switch", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED + FCVAR_NOTIFY,
	"Players can switch playermodel from the S3GM menu (1 on, 0 off)")

local function Reply(ply, ok, text)
	net.Start("skate3_playermodel")
	net.WriteBool(ok)
	net.WriteString(text)
	net.Send(ply)
end

net.Receive("skate3_playermodel", function(_, ply)
	local name = net.ReadString()
	if not cv_allow:GetBool() then return Reply(ply, false, "This server doesn't allow switching playermodel") end
	if not ply:Alive() then return Reply(ply, false, "Not while you're down") end
	if (ply.skate3ModelAt or -math.huge) + 1 > CurTime() then return Reply(ply, false, "Easy, one switch at a time") end
	local path = player_manager.AllValidModels()[name]
	if not path then return Reply(ply, false, "That playermodel isn't installed here") end
	path = player_manager.TranslatePlayerModel(name)
	if not util.IsValidModel(path) then return Reply(ply, false, "That playermodel won't load") end
	ply.skate3ModelAt = CurTime()
	util.PrecacheModel(path)
	ply:SetModel(path)
	ply:SetSkin(0)
	for i = 0, ply:GetNumBodyGroups() - 1 do ply:SetBodygroup(i, 0) end
	if ply.SetupHands then ply:SetupHands() end
	Reply(ply, true, name)
end)
