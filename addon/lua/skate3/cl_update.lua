-- The update checker: shortly after the game starts, one request to GitHub's
-- "latest release" for S3GM, and if that is newer than this install:
--
--   * a small card, once per new version, top centre for a few seconds
--   * an "Update available" row at the top of the menu's Settings (hold L1, X)
--
-- It is quiet about everything else: no network, GitHub rate limiting us, no
-- release published yet (404), a reply we can't read, all just mean "nothing
-- to say". Nothing is installed or opened on its own; the Settings row opens
-- the releases page when you press right on it.
--
-- skate3_update_notices 0 turns it all off, and then no request is made at
-- all. The console command skate3_update_check checks right now and says what
-- it found in the console (it ignores the six-hour wait and the switch).

S3GM_Update = S3GM_Update or {}
local Update = S3GM_Update

local API = "https://api.github.com/repos/NotEnxvinity/skate3-gmod/releases/latest"
-- Where the Settings row sends you. Fixed here, never taken from the reply.
Update.PAGE = "https://github.com/NotEnxvinity/skate3-gmod/releases"

local WAIT_AFTER_START = 15     -- seconds after joining before the request, so loading isn't slowed
local RECHECK = 6 * 60 * 60     -- seconds between requests (60 an hour is all GitHub gives an address)
local RETRY_FAILED = 30 * 60    -- ... after a request that didn't get through
local RETRY_LIMITED = 60 * 60   -- ... after GitHub said we're asking too much, or there is no release yet
local CARD_FOR = 12             -- seconds the card stays up
local FADE_IN, FADE_OUT = 0.4, 0.6

---------------------------------------------------------------------------
-- Versions
---------------------------------------------------------------------------

-- "v2.3.1", "S3GM-v2.3.1", "v2.4.0-test-1" or "2.2.2-combined-test-9" -> { 2, 3, 1 }, true
-- for a test build (anything after the three numbers), or nil. Only the
-- numbers are kept, so nothing else in a reply can end up on screen.
function Update.Parse(text)
	if type(text) ~= "string" then return end
	-- (A tag can carry a name in front, like "S3GM-v2.3.1".)
	local a, b, c, rest = text:match("(%d+)%.(%d+)%.(%d+)(.*)$")
	if not a then return end
	rest = rest:gsub("%s+$", "")
	if rest ~= "" and not rest:find("^[%-%+]") then return end
	return { tonumber(a), tonumber(b), tonumber(c) }, rest ~= ""
end

function Update.Format(v)
	return ("v%d.%d.%d"):format(v[1], v[2], v[3])
end

-- Is the release `latest` newer than the build `installed`? A test build of a
-- version is older than that version's release (v2.4.0-test-1 < v2.4.0), and
-- newer than every release before it.
function Update.IsNewer(latest, installed)
	local l = Update.Parse(latest)
	local i, test = Update.Parse(installed)
	if not l or not i then return false end
	for n = 1, 3 do
		if l[n] ~= i[n] then return l[n] > i[n] end
	end
	return test and true or false
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local cv_notices = CreateClientConVar("skate3_update_notices", "1", true, false,
	"Tell me when a new S3GM release is out on GitHub: a small card once per version and a line in the menu's Settings (1 on, 0 off; off also stops the check)")
-- The newest version the card has already been shown for.
local cv_seen = CreateClientConVar("skate3_update_seen", "", true, false,
	"The last update the card was shown for (set by the game)")

local COOKIE_LATEST, COOKIE_NEXT = "s3gm_update_latest", "s3gm_update_next"

local latest              -- the newest release we know of, "v2.4.0" (from this session's check or the last one)
local cardAt              -- seconds the card has been up, nil while it hasn't started
local cardDone = false
local inFlight = false
local lastFrame

local function Installed()
	return S3GM_BUILD or ""
end

local function Remember(tag)
	latest = tag
	cookie.Set(COOKIE_LATEST, tag)
end

-- The newer version to tell about, or nil.
function Update.Latest()
	if not cv_notices:GetBool() then return end
	if latest and Update.IsNewer(latest, Installed()) then return latest end
end

---------------------------------------------------------------------------
-- The request
---------------------------------------------------------------------------

-- No request before this time (seconds since 1970), whatever starts it but the console command.
local function Later(seconds)
	cookie.Set(COOKIE_NEXT, tostring(os.time() + seconds))
end

-- result("newer" | "current" | "none" | "failed", detail) is for the console command.
local function Check(result)
	if inFlight then return end
	if not HTTP then if result then result("failed", "HTTP isn't available") end return end
	inFlight = true
	Later(RECHECK) -- also what a crash or a hang leaves behind
	local ok = pcall(HTTP, {
		url = API,
		method = "GET",
		headers = { ["Accept"] = "application/vnd.github+json", ["User-Agent"] = "S3GM-update-check" },
		timeout = 15,
		success = function(code, body)
			inFlight = false
			local done = "failed"
			local detail = "GitHub answered " .. tostring(code)
			if code == 200 then
				local okJson, data = pcall(util.JSONToTable, body or "")
				local v = okJson and type(data) == "table" and Update.Parse(data.tag_name)
				if v then
					Remember(Update.Format(v))
					done = Update.IsNewer(latest, Installed()) and "newer" or "current"
					detail = latest
				else
					detail = "the reply had no usable version"
				end
			elseif code == 404 then
				done, detail = "none", "no release is published yet"
				Later(RETRY_LIMITED)
			elseif code == 403 or code == 429 then
				detail = "GitHub is rate limiting this address, try later"
				Later(RETRY_LIMITED)
			else
				Later(RETRY_FAILED)
			end
			if result then result(done, detail) end
		end,
		failed = function(reason)
			inFlight = false
			Later(RETRY_FAILED)
			if result then result("failed", tostring(reason)) end
		end,
	})
	if not ok then
		inFlight = false
		if result then result("failed", "the request couldn't be made") end
	end
end

local function Startup()
	-- Last time's answer first, so the line is there even offline.
	local old = cookie.GetString(COOKIE_LATEST, "")
	local v = Update.Parse(old)
	if v then latest = Update.Format(v) end

	if not cv_notices:GetBool() then return end
	local next_ = tonumber(cookie.GetNumber(COOKIE_NEXT, 0)) or 0
	local now = os.time()
	-- (A next time further off than a check ever sets means the clock moved.)
	if now < next_ and next_ - now <= RECHECK then return end
	timer.Simple(WAIT_AFTER_START, function()
		-- Re-read the switch: it may have been turned off while loading.
		if cv_notices:GetBool() then Check() end
	end)
end

hook.Add("InitPostEntity", "skate3_update_check", function()
	local ok = pcall(Startup)
	if not ok then latest = nil end
end)

concommand.Add("skate3_update_check", function()
	print("[skate3] this is " .. (Installed() ~= "" and Installed() or "an unknown build") .. ", checking GitHub...")
	Check(function(result, detail)
		if result == "newer" then
			print("[skate3] update available: " .. detail .. " (" .. Update.PAGE .. ")")
		elseif result == "current" then
			print("[skate3] up to date (latest release is " .. detail .. ")")
		else
			print("[skate3] couldn't check: " .. detail)
		end
	end)
end, nil, "Check GitHub for a newer S3GM release right now")

---------------------------------------------------------------------------
-- The card
---------------------------------------------------------------------------

-- The menu's Settings list calls this when it opens: seeing the line there
-- is as good as seeing the card.
function Update.Acknowledge()
	local v = Update.Latest()
	if v and cv_seen:GetString() ~= v then RunConsoleCommand("skate3_update_seen", v) end
	cardDone = true
end

function Update.Open()
	gui.OpenURL(Update.PAGE)
end

local function CardAlpha(t)
	if t < FADE_IN then return t / FADE_IN end
	if t > CARD_FOR - FADE_OUT then return math.max(0, (CARD_FOR - t) / FADE_OUT) end
	return 1
end

hook.Add("HUDPaint", "skate3_update_card", function()
	if cardDone then return end
	local v = Update.Latest()
	if not v or cv_seen:GetString() == v then return end
	local UI, Menu = S3GM_UI, S3GM_Menu
	if not UI or not Menu or not Menu.Looks then return end
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then lastFrame = nil return end

	-- Time counts only while the card is actually up on a running game, and
	-- stands still while the menu has the corner.
	local now = RealTime()
	local dt = lastFrame and math.Clamp(now - lastFrame, 0, 0.1) or 0
	lastFrame = now
	if Menu.Visible() then return end
	cardAt = (cardAt or 0) + dt
	if cardAt >= CARD_FOR then
		cardDone = true
		RunConsoleCommand("skate3_update_seen", v)
		return
	end

	local style = UI.Style()
	local look = Menu.Looks[style]
	if not look then return end
	local alpha = CardAlpha(cardAt)
	local title = "Update available: " .. v
	local hint = "Hold L1 (Shift), then X: Settings"
	local width = math.max(look.Width(title, 20), look.Width(hint, 16)) + 40
	local s = math.min(ScrH() / 720, ScrW() / 1280)
	-- Canvas x runs from the screen's centre, so the card sits in the middle.
	UI.Begin(ScrW() / 2, 0, s)
	local x, y = -width / 2, 24
	look.Box(x, y, width, 78, alpha)
	look.Text(title, x + 20, y + 12, 20, alpha)
	look.Text(hint, x + 20, y + 46, 16, 0.55 * alpha)
end)

return Update
