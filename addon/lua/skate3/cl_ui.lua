-- The pieces S3GM's on-screen UI shares: which look is chosen, Skate 3's own
-- art and Futura fonts (made from the player's disc by setup, in
-- data/skate3/assets/ui), the font the "minimal" look uses, and the toast
-- line. Everything is laid out on Skate 3's 1280x720 canvas and scaled to
-- the screen (or onto a 3D2D plane for the in-world look).
--
-- Other modules reach this through S3GM_UI.

S3GM_UI = S3GM_UI or {}
local UI = S3GM_UI

local cv_style = CreateClientConVar("skate3_ui_style", "skate3", true, false,
	"On-screen look: skate3 (Skate 3's own, from your disc), minimal or hl2")
local cv_world = CreateClientConVar("skate3_ui_world", "0", true, false,
	"Draw the trick score beside the skater in the world instead of on screen (1 on, 0 off)")

local cv_crisp = CreateClientConVar("skate3_ui_crisp", "1", true, false,
	"Draw the Skate 3 look's text with the disc's Futura font where setup installed it (sharp at any resolution), not its bitmaps (1 on, 0 off)")

local ART = "skate3/assets/ui/"
-- Replacements for the disc's images with the same names (an upscaled set),
-- looked for first. Setup never touches this folder.
local HD = "skate3/ui-hd/"

---------------------------------------------------------------------------
-- Which look
---------------------------------------------------------------------------

local art, artTried, artReason

-- Garry's Mod's util.JSONToTable turns numeric string keys ("36") into
-- numbers, and the art is looked up by those strings, so put them back.
local function StringKeys(t)
	local out = {}
	for k, v in pairs(t) do out[tostring(k)] = v end
	return out
end

-- Skate 3's art, or nil when setup hasn't made it (or the data folder was
-- moved with skate3_data_path, which Garry's Mod can't load images from).
-- UI.ArtReason() says why not.
function UI.Art()
	if artTried then return art end
	artTried = true
	local path = GetConVar("skate3_data_path")
	if path and path:GetString() ~= "" then
		artReason = "skate3_data_path is set (" .. path:GetString() .. "); Garry's Mod can't load images from there. Clear it to use the Skate 3 look"
		return nil
	end
	local json = file.Read(ART .. "ui.json", "DATA")
	if not json then
		local failed = file.Read(ART .. "setup-error.txt", "DATA")
		artReason = failed and ("the S3GM setup couldn't make it: " .. failed)
			or ("garrysmod/data/" .. ART .. "ui.json isn't there: run the S3GM setup again with your Skate 3 disc")
		return nil
	end
	local parsed = util.JSONToTable(json)
	if not parsed or not parsed.shapes or not parsed.fonts then
		artReason = "garrysmod/data/" .. ART .. "ui.json is unreadable: run the S3GM setup again"
		return nil
	end
	parsed.shapes = StringKeys(parsed.shapes)
	for _, font in pairs(parsed.fonts) do font.chars = StringKeys(font.chars) end
	parsed.textures = StringKeys(parsed.textures or {})
	parsed.buttons = StringKeys(parsed.buttons or {})
	art = parsed
	return art
end

function UI.ArtReason() return artReason end

-- Looks for the art again (after running setup with the game open).
concommand.Add("skate3_ui_reload", function()
	artTried, art, artReason = false, nil, nil
	UI.mats = {}
	print("[skate3] ui art: " .. (UI.Art() and "found" or ("not available: " .. tostring(artReason))))
end, nil, "Reload Skate 3's on-screen art")

UI.mats = {}

local told = false
-- The look in use: what's chosen, unless that's Skate 3's and its art isn't
-- installed, which falls back to minimal.
function UI.Style()
	local style = cv_style:GetString()
	if style == "minimal" or style == "hl2" then return style end
	if UI.Art() then return "skate3" end
	if not told then
		told = true
		print("[skate3] the Skate 3 look needs its art from your disc: run the S3GM setup again. Showing the minimal look until then.")
	end
	return "minimal"
end

function UI.Chosen()
	local style = cv_style:GetString()
	return (style == "minimal" or style == "hl2") and style or "skate3"
end

function UI.World()
	return cv_world:GetBool() and UI.Style() ~= "hl2"
end

---------------------------------------------------------------------------
-- Drawing on the canvas
---------------------------------------------------------------------------

local T = { ox = 0, oy = 0, s = 1, world = false }

-- Canvas point (x, y) lands on the screen at ox + x * s, oy + y * s. `world`
-- when it's a 3D2D plane in the world, where text stays bitmap.
function UI.Begin(ox, oy, s, world)
	T.ox, T.oy, T.s, T.world = ox, oy, s, world or false
end

function UI.Scale() return T.s end

-- The canvas pinned to the screen's bottom left (the score) or top left (the menu).
function UI.BeginBottomLeft()
	local s = math.min(ScrH() / 720, ScrW() / 1280)
	UI.Begin(0, ScrH() - 720 * s, s)
	return s
end

function UI.BeginTopLeft()
	local s = math.min(ScrH() / 720, ScrW() / 1280)
	UI.Begin(0, 0, s)
	return s
end

function UI.P(x, y)
	return T.ox + x * T.s, T.oy + y * T.s
end

-- The score's soft glows and flash (blown up to hundreds of pixels): upscaling
-- them only smears their edges, and a wrapped (noclamp) texture blends each
-- quad's far edge back in, which drew thin lines along every quad's border and
-- through the middle of the flash. So they use the original art and clamp.
local SOFT = { hud56 = true, hud60 = true, hud63 = true }

local function Mat(name)
	local m = UI.mats[name]
	if m then return m end
	local path = ART .. name .. ".png"
	-- An upscaled copy from the optional HD pack, where ui.json says it would be.
	local info = art and art.textures and art.textures[name]
	if info and info.hd and not SOFT[name] and file.Exists(HD .. info.hd, "DATA") then path = HD .. info.hd end
	m = Material("../data/" .. path, SOFT[name] and "smooth" or "smooth noclamp")
	UI.mats[name] = m
	return m
end

-- The four corners DrawPoly is handed for a rectangle, reused every call.
local verts = { {}, {}, {}, {} }

-- One textured rectangle of the art: q is { {x, y, u, v} x 4 } on the canvas,
-- moved by (dx, dy) and scaled by k about the origin.
function UI.Quad(tex, q, dx, dy, k, r, g, b, a)
	k = k or 1
	for i = 1, 4 do
		local p = q[i]
		local x, y = UI.P((p[1] * k) + dx, (p[2] * k) + dy)
		local v = verts[i]
		v.x, v.y, v.u, v.v = x, y, p[3], p[4]
	end
	surface.SetMaterial(Mat(tex))
	surface.SetDrawColor(r, g, b, a)
	surface.DrawPoly(verts)
end

-- A shape of the score movie: every piece of it, with its origin at (dx, dy).
function UI.Shape(id, dx, dy, k, r, g, b, a)
	local shape = UI.Art() and art.shapes[id]
	if not shape then return end
	for _, piece in ipairs(shape) do
		UI.Quad(piece.tex, piece.quad, dx, dy, k, r, g, b, a * piece.color[4])
	end
end

-- The Hall of Meat panel's backdrop and magazine logo (the panel and a soft
-- black shadow as they are, then the lettering tinted r, g, b) with their
-- origin at (dx, dy). False if the disc art for it isn't there; the second
-- result says whether the backdrop was part of it (setups before test 10 only
-- exported the logo).
function UI.Logo(dx, dy, k, r, g, b, a)
	local pieces = UI.Art() and art.logo
	if not pieces then return false end
	local panel = false
	for _, piece in ipairs(pieces) do
		if piece.shadow then
			UI.Quad(piece.tex, piece.quad, dx, dy, k, 255, 255, 255, a)
			panel = panel or piece.tex == "hom1"
		else
			UI.Quad(piece.tex, piece.quad, dx, dy, k, r, g, b, a)
		end
	end
	return true, panel
end

-- A quadrant ring's first `frac` of the way round clockwise from the top
-- (frac 0..1), with the shape's origin at (dx, dy). The pieces are quadrants
-- of a ring (mirrored copies of one picture), so each is cut to the wedge it
-- is swept through, with the picture's own coordinates kept.
local QUADRANT_START = { ["1,-1"] = 0, ["1,1"] = 0.25, ["-1,1"] = 0.5, ["-1,-1"] = 0.75 }
local function Edge(angle, half)
	local c, s = math.cos(angle), math.sin(angle)
	local d = half / math.max(math.abs(c), math.abs(s))
	return c * d, s * d
end

function UI.Sector(id, dx, dy, from, to, r, g, b, a)
	local shape = UI.Art() and art.shapes[id]
	if not shape or to <= from then return end
	for _, piece in ipairs(shape) do
		local q = piece.quad
		local x0, y0, x1, y1 = q[1][1], q[1][2], q[3][1], q[3][2]
		local sx = (x0 + x1) > 0 and 1 or -1
		local sy = (y0 + y1) > 0 and 1 or -1
		local start = QUADRANT_START[sx .. "," .. sy]
		local a0, a1 = math.max(from, start), math.min(to, start + 0.25)
		if a1 > a0 then
			local half = math.max(math.abs(x0), math.abs(x1), math.abs(y0), math.abs(y1))
			local points = { { 0, 0 } }
			local function Add(frac)
				local ex, ey = Edge(-math.pi / 2 + frac * math.pi * 2, half)
				points[#points + 1] = { ex, ey }
			end
			Add(a0)
			-- The corner of the square, where the ray moves to its next edge.
			local corner = start + 0.125
			if corner > a0 and corner < a1 then Add(corner) end
			Add(a1)
			local ux, uy = q[2][3] - q[1][3], q[2][4] - q[1][4]
			local vx, vy = q[4][3] - q[1][3], q[4][4] - q[1][4]
			local poly = {}
			for i = 1, #points do
				local px, py = points[i][1], points[i][2]
				local fx, fy = (px - x0) / (x1 - x0), (py - y0) / (y1 - y0)
				local X, Y = UI.P(px + dx, py + dy)
				poly[i] = { x = X, y = Y, u = q[1][3] + fx * ux + fy * vx, v = q[1][4] + fx * uy + fy * vy }
			end
			surface.SetMaterial(Mat(piece.tex))
			surface.SetDrawColor(r, g, b, a * piece.color[4])
			surface.DrawPoly(poly)
		end
	end
end

-- A button icon of the game's own bank (A, B, X, Y, L_Bumper, DPad_Up ...),
-- its 64x64 picture with the top left at (x, y). `group` is "buttons" (Xbox,
-- from the Xbox disc) or "buttons_ps" (from a PS3 copy). False if there's
-- no such picture.
function UI.ArtButton(group, name, x, y, r, g, b, a)
	local tex = UI.Art() and art[group] and art[group][name]
	if not tex then return false end
	UI.Quad(tex, { { x, y, 0, 0 }, { x + 64, y, 1, 0 }, { x + 64, y + 64, 1, 1 }, { x, y + 64, 0, 1 } }, 0, 0, 1, r, g, b, a)
	return true
end

function UI.Button(name, x, y, r, g, b, a)
	UI.ArtButton("buttons", name, x, y, r, g, b, a)
end

-- A filled rounded rectangle on the canvas.
function UI.Rounded(radius, x, y, w, h, color)
	local s = UI.Scale()
	local X, Y = UI.P(x, y)
	draw.RoundedBox(radius * s, X, Y, w * s, h * s, color)
end

function UI.Rect(x, y, w, h, color, alpha)
	local X, Y = UI.P(x, y)
	local s = UI.Scale()
	surface.SetDrawColor(color.r, color.g, color.b, (color.a or 255) * alpha)
	surface.DrawRect(X, Y, w * s, h * s)
end

---------------------------------------------------------------------------
-- Skate 3's Futura bitmap text
---------------------------------------------------------------------------

local function Chars(key)
	return UI.Art() and art.fonts[key]
end

-- How wide `text` is at height h (the font's ascent, as the movies give it).
function UI.FuturaWidth(text, h, key)
	local font = Chars(key or "heavy")
	if not font then return 0 end
	local scale = h / font.ascent
	local pen = 0
	for _, cp in utf8.codes(text) do
		local c = font.chars[tostring(cp)]
		if c then pen = pen + c[9] * scale end
	end
	return pen
end

-- Text can be turned about a canvas point (the SWITCH/FAKIE label reads
-- bottom to top): UI.Rotate(cx, cy, degrees) until UI.Rotate().
local rot
function UI.Rotate(cx, cy, degrees)
	if not cx then rot = nil return end
	local a = math.rad(degrees)
	rot = { cx = cx, cy = cy, c = math.cos(a), s = math.sin(a) }
end

local function Corner(px, py)
	if rot then
		local dx, dy = px - rot.cx, py - rot.cy
		px, py = rot.cx + dx * rot.c - dy * rot.s, rot.cy + dx * rot.s + dy * rot.c
	end
	return UI.P(px, py)
end

local function Run(font, text, x, y, h, r, g, b, a)
	local scale = h / font.ascent
	local pen = 0
	surface.SetMaterial(Mat(font.tex))
	surface.SetDrawColor(r, g, b, a)
	for _, cp in utf8.codes(text) do
		local c = font.chars[tostring(cp)]
		if c then
			if c[5] > 0 and c[6] > 0 then
				local gx = x + pen + c[7] * scale
				local gy = y + h - c[8] * scale
				local w, hh = c[5] * scale, c[6] * scale
				local v = verts
				v[1].x, v[1].y = Corner(gx, gy)
				v[2].x, v[2].y = Corner(gx + w, gy)
				v[3].x, v[3].y = Corner(gx + w, gy + hh)
				v[4].x, v[4].y = Corner(gx, gy + hh)
				v[1].u, v[1].v, v[2].u, v[2].v = c[1], c[2], c[3], c[2]
				v[3].u, v[3].v, v[4].u, v[4].v = c[3], c[4], c[1], c[4]
				surface.DrawPoly(v)
			end
			pen = pen + c[9] * scale
		end
	end
end

-- The disc's own Futura as a real font (setup puts it in resource/fonts as
-- "S3GM Futura"), so text is sharp at any size. Whether it's installed is
-- found out once by measuring text in it against a font that doesn't exist.
local PROBE = "Wmiqjg0123 Skate"
local FAMILY = "S3GM Futura"
local CAP, ASCENT = 0.754, 0.825 -- the font's capital height and baseline, in ems
local crisp

local function CrispAvailable()
	if not cv_crisp:GetBool() then return false end
	if crisp == nil then
		surface.CreateFont("s3gm_futura_none", { font = "S3GM no such font", size = 40, weight = 700 })
		surface.SetFont("s3gm_futura_none")
		local none = surface.GetTextSize(PROBE)
		surface.CreateFont("s3gm_futura_probe", { font = FAMILY, size = 40, weight = 700 })
		surface.SetFont("s3gm_futura_probe")
		crisp = surface.GetTextSize(PROBE) ~= none
		print("[skate3] ui font: " .. (crisp and "the disc's Futura (sharp)" or "bitmap Futura (the disc's font isn't installed: run the S3GM setup again, then restart the game)"))
	end
	return crisp
end

local crispFonts = {}
local function CrispFont(px)
	px = math.max(8, math.Round(px))
	local name = "s3gm_futura_" .. px
	if not crispFonts[name] then
		crispFonts[name] = true
		surface.CreateFont(name, { font = FAMILY, size = px, weight = 700, extended = true, antialias = true })
	end
	return name, px
end

-- Text drawn glyph by glyph in the real font, on the bitmap font's pen
-- positions and baseline, so it sits exactly where the bitmap text would.
local function RunCrisp(font, text, x, y, h, r, g, b, a)
	local H = font.chars["72"]
	if not H then return false end
	local scale = h / font.ascent
	local cap = H[6] * scale
	local baseline = y + h - H[8] * scale + cap
	local name, px = CrispFont(cap * UI.Scale() / CAP)
	local _, top = UI.P(0, baseline)
	top = top - ASCENT * px
	local color = Color(r, g, b, a)
	local pen = 0
	for _, cp in utf8.codes(text) do
		local c = font.chars[tostring(cp)]
		if c then
			if c[5] > 0 and c[6] > 0 then
				local X = UI.P(x + pen, 0)
				draw.SimpleText(utf8.char(cp), name, X, top, color, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
			end
			pen = pen + c[9] * scale
		end
	end
	return true
end

function UI.Futura(text, x, y, h, color, alpha, align)
	local heavy, shadow = Chars("heavy"), Chars("shadow")
	if not heavy then return end
	if align == TEXT_ALIGN_CENTER then
		x = x - UI.FuturaWidth(text, h) / 2
	elseif align == TEXT_ALIGN_RIGHT then
		x = x - UI.FuturaWidth(text, h)
	end
	if shadow then Run(shadow, text, x, y, h, 0, 0, 0, 255 * alpha) end
	-- Turned text and the in-world plane stay bitmap.
	if not rot and not T.world and CrispAvailable() and
		RunCrisp(heavy, text, x + 1, y, h, color.r, color.g, color.b, (color.a or 255) * alpha) then
		return
	end
	Run(heavy, text, x + 1, y, h, color.r, color.g, color.b, (color.a or 255) * alpha)
end

---------------------------------------------------------------------------
-- The minimal look's font: Helvetica Neue Bold
---------------------------------------------------------------------------

-- Helvetica Neue is a commercial font (Macs and Adobe's apps carry it, but we
-- can't pass the file on), so it's used when the player has it. If not, the
-- free Inter Bold that ships with the addon (resource/fonts), then Arial and
-- Garry's Mod's own Roboto, whichever is first found installed.
local FACES = { "Helvetica Neue", "S3GM Sans Bold", "Arial", "Roboto" }
local face

function UI.Face()
	if face then return face end
	surface.CreateFont("s3gm_probe_none", { font = "S3GM no such font", size = 40, weight = 700 })
	surface.SetFont("s3gm_probe_none")
	local none = surface.GetTextSize(PROBE)
	for _, name in ipairs(FACES) do
		surface.CreateFont("s3gm_probe", { font = name, size = 40, weight = 700 })
		surface.SetFont("s3gm_probe")
		if surface.GetTextSize(PROBE) ~= none then
			face = name
			break
		end
	end
	face = face or "Roboto"
	print("[skate3] ui font: " .. face)
	return face
end

local made = {}
-- A bold font of the minimal look at this pixel size; returns its name.
function UI.Font(size, italic)
	size = math.max(8, math.Round(size))
	local name = ("s3gm_ui_%d%s"):format(size, italic and "i" or "")
	if not made[name] then
		made[name] = true
		surface.CreateFont(name, { font = UI.Face(), size = size, weight = 700, italic = italic or false, extended = true })
	end
	return name
end

---------------------------------------------------------------------------
-- The toast line (marker set, back at marker ...)
---------------------------------------------------------------------------

local HOLD, FADE = 2.5, 0.5
local toast = { text = nil, at = -math.huge }

function UI.Toast(text)
	toast.text, toast.at = text, RealTime()
end

-- What the toast says and how opaque it is, or nil when it's gone.
function UI.CurrentToast()
	local alpha = math.Clamp((HOLD + FADE - (RealTime() - toast.at)) / FADE, 0, 1)
	if toast.text and alpha > 0 then return toast.text, alpha end
end

return UI
