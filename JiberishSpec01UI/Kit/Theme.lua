-- Hardware kit: palette, fonts, sound, animation and the shared primitives every
-- control is assembled from. This is SPEC-01/HARDWARE by Shu Ding
-- (https://github.com/shuding/spec-01, MIT; see Media/Hardware/LICENSE-SPEC-01.txt)
-- brought to WoW: the control art in Media/Hardware/Skin is rendered from its
-- stylesheet by tools/capture-hardware-reference.py, and the sounds from its
-- sound recipe by tools/build-hardware-sounds.py.
local _, UI = ...
local Kit = {Util = UI.Util}
UI.Kit = Kit

local CreateFrame, UIParent, GetTime = CreateFrame, UIParent, GetTime
local floor, max, min = math.floor, math.max, math.min
local LSM = LibStub and LibStub('LibSharedMedia-3.0', true)

Kit.media = UI.MediaPath..[[Hardware\]]
Kit.sliceScale = 0.5 -- art is authored at twice its design size

local function Hex(value)
	return {tonumber(value:sub(1, 2), 16) / 255, tonumber(value:sub(3, 4), 16) / 255, tonumber(value:sub(5, 6), 16) / 255}
end

Kit.zoom = 0.75 -- reference design px to UI units; the art itself is twice design size

-- Paper is the reference look, value for value, from its soft-light skin
-- (hardware-field.css): an off-white face on a warm page, light keys with
-- warm hairlines, recessed wells, a gray LCD and a 3 px molded side wall
-- under each device. Graphite is this addon's dark variant: the same art
-- multiplied down by the skin* tints.
Kit.finishes = {
	paper = {
		name = 'Paper',
		page = Hex('eeeeec'), panel = Hex('fbfbfa'), hair = Hex('d3d1cb'), line = Hex('dad8d2'),
		ink = Hex('1d1d1c'), dim = Hex('8f8d87'),
		key = Hex('fcfcfa'), keyEdge = Hex('d3d1cb'), keyLip = Hex('dcdcd8'),
		well = Hex('ececea'), track = Hex('ececea'), ledOff = Hex('cfcdc7'),
		lcd = Hex('c2c3bd'), lcdInk = Hex('141413'), lcdDim = Hex('5c5d58'), lcdGhost = Hex('b6b7b1'),
		panelHi = Hex('f7f6f3'), recess = Hex('e9e8e3'), wall = Hex('d7d7d2'), legend = Hex('8f8e89'),
		rule = Hex('e2e0da'), shadowTint = Hex('534f46'),
		skinKey = {1, 1, 1}, skinPanel = {1, 1, 1}, skinWell = {1, 1, 1}, skinLcd = {1, 1, 1},
	},
	graphite = {
		name = 'Graphite',
		page = Hex('131312'), panel = Hex('1e1e1c'), hair = Hex('343431'), line = Hex('2b2b29'),
		ink = Hex('ecece8'), dim = Hex('8a8a84'),
		key = Hex('2c2c2a'), keyEdge = Hex('3d3d3a'), keyLip = Hex('0b0b0a'),
		well = Hex('0e0e0d'), track = Hex('171716'), ledOff = Hex('3a3a37'),
		lcd = Hex('23261f'), lcdInk = Hex('d9e4c8'), lcdDim = Hex('7f8a72'), lcdGhost = Hex('2e3229'),
		panelHi = Hex('252523'), recess = Hex('121211'), wall = Hex('0b0b0a'), legend = Hex('8a8a84'),
		rule = Hex('2b2b29'), shadowTint = Hex('000000'),
		skinKey = {0.25, 0.25, 0.24}, skinPanel = {0.13, 0.13, 0.125}, skinWell = {0.11, 0.11, 0.105}, skinLcd = {0.2, 0.22, 0.17},
	},
}
-- Dark glass, status colors and absolutes are the same on every finish.
Kit.shared = {
	-- Screens print in #f2f2ee and glow amber (#ffb347) where the reference's do;
	-- LED status colors are its badge lamps.
	dark = Hex('1b1b19'), darkEdge = Hex('2e2e2b'), darkLip = Hex('000000'), darkInk = Hex('f2f2ee'), darkDim = Hex('9a9a94'),
	glass = Hex('0d0d0c'), green = Hex('2f9e5f'), blue = Hex('4aa3ff'), amber = Hex('ffa800'), red = Hex('ff3b30'),
	screenAccent = Hex('ffb347'), ledGreen = Hex('2fbf6a'), ledBlue = Hex('4a8cff'),
	screenFill = {0, 0, 0}, -- the black of screens, apart from black itself so it can be retinted
	white = {1, 1, 1}, black = {0, 0, 0},
	screenInk = Hex('141413'), screenDim = Hex('5c5d58'), -- text on the always-gray toast glass
}
Kit.accents = {
	red = {name = 'Red', 0.94, 0.10, 0.08}, yellow = {name = 'Yellow', 1, 0.82, 0}, green = {name = 'Green', 0.10, 0.74, 0.26},
	blue = {name = 'Blue', 0.12, 0.36, 1}, purple = {name = 'Purple', 0.55, 0.22, 1}, ink = {name = 'Ink', 0.16, 0.16, 0.15},
}
Kit.accentOrder = {'red', 'yellow', 'green', 'blue', 'purple', 'ink'}
Kit.icons = {}
for index, name in ipairs({'chevron-right', 'chevron-left', 'chevron-up', 'chevron-down', 'plus', 'minus', 'close', 'check',
	'play', 'stop', 'pause', 'record', 'more', 'search', 'info', 'trash',
	'filter', 'align-left', 'align-center', 'align-right', 'warning', 'speaker', 'calendar', 'grip',
	'user', 'tri-up', 'tri-down', 'tri-left', 'tri-right', 'copy', 'mail', 'power'}) do
	Kit.icons[name] = index - 1
end

function Kit:DB()
	return UI.db
end

-- Appearance tokens (the Theme page). Modules/Appearance.lua declares the saved
-- defaults; these are the same values, for anything drawn before they load.
-- At these values the interface looks exactly as it did before the tokens.
local LOOK = {borderPx = 1, rounding = 1, shadowSize = 1, shadowOpacity = 1, textScale = 1, textOutline = 'none',
	textShadow = false, barBrightness = 1, softness = 0, smoothBars = true, motionScale = 1, ghostDigits = true}
Kit.LOOK_FALLBACK = LOOK
function Kit:Look(key)
	local look = UI.db and UI.db.appearance
	local value = look and look[key]
	if value == nil then return LOOK[key] end
	return value
end

-- Color softness: lamps and status colors blend toward their own gray.
local SOFT = {accent = true, lamp = true, green = true, blue = true, amber = true, red = true}
local function Soften(token, r, g, b)
	if not SOFT[token] then return r, g, b end
	local amount = Kit:Look('softness') or 0
	if amount <= 0 then return r, g, b end
	amount = min(amount, 1) * 0.7
	local gray = 0.299 * r + 0.587 * g + 0.114 * b
	return r + (gray - r) * amount, g + (gray - g) * amount, b + (gray - b) * amount
end

-- The six reference key colors come from Skin.lua (measured from the page);
-- a class or custom color derives the same roles.
function Kit:AccentRoles()
	local db = self:DB()
	local preset = db.accent ~= 'tint' and self.accentSkin and self.accentSkin[db.accent]
	if preset then return preset end
	local r, g, b
	-- A custom color may be saved as {r, g, b} or {r =, g =, b =}.
	local custom = db.customAccent
	if db.accent == 'custom' and type(custom) == 'table' then r, g, b = custom.r or custom[1], custom.g or custom[2], custom.b or custom[3]
	elseif db.accent == 'class' then
		local _, class = UnitClass('player')
		local color = class and (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)[class]
		if color then r, g, b = color.r, color.g, color.b end
	end
	if not r then r, g, b = 1, 0, 0 end
	local roles = self.customRoles or {}
	self.customRoles = roles
	local light = 0.299 * r + 0.587 * g + 0.114 * b > 0.62
	roles.key, roles.lamp, roles.edge = {r, g, b}, {r, g, b}, {r * 0.66, g * 0.66, b * 0.66}
	roles.ink = light and {0.11, 0.11, 0.1} or roles.key
	roles.on = light and {0.07, 0.07, 0.07} or {1, 1, 1}
	return roles
end

function Kit:Accent()
	local key = self:AccentRoles().key
	return key[1], key[2], key[3]
end

local ACCENT_TOKENS = {accent = 'key', accentInk = 'ink', lamp = 'lamp', onAccent = 'on', accentLip = 'edge'}

-- Interface colors (the Theme page's Colors card, saved under db.colors): each
-- override, while switched on, replaces these tokens on every finish.
local OVERRIDES = {panel = 'housing', dark = 'housing', glass = 'screen', screenFill = 'screen', lcd = 'lcd',
	lcdInk = 'lcdInk', lamp = 'lamp', ink = 'ink', dim = 'dim', darkInk = 'screenText', hair = 'edge', line = 'edge',
	edgeOverride = 'edge'}
Kit.COLOR_OVERRIDES = OVERRIDES

local function Override(token)
	local key = OVERRIDES[token]
	if not key then return nil end
	local db = UI.db and UI.db.colors
	if type(db) ~= 'table' or not db[key..'On'] then return nil end
	local color = db[key]
	if type(color) ~= 'table' then return nil end
	return color.r or color[1] or 1, color.g or color[2] or 1, color.b or color[3] or 1
end

-- Whether an interface color override is on (for parts that choose a token by it).
function Kit:Overridden(key)
	local db = UI.db and UI.db.colors
	return type(db) == 'table' and db[key..'On'] and type(db[key]) == 'table' or false
end

-- Resolve a palette token. Unknown tokens fall back to ink so a typo is visible.
function Kit:RGB(token)
	if type(token) == 'table' then return token[1], token[2], token[3] end
	local r, g, b = Override(token)
	if r then return Soften(token, r, g, b) end
	local role = ACCENT_TOKENS[token]
	if role then
		local color = self:AccentRoles()[role]
		return Soften(token, color[1], color[2], color[3])
	end
	local finish = self.finishes[self:DB().finish] or self.finishes.paper
	local color = finish[token] or self.shared[token] or finish.ink
	return Soften(token, color[1], color[2], color[3])
end

-- Every colored region and font string registers its token, so changing the
-- finish, accent or font repaints live widgets without rebuilding them.
local tinted = setmetatable({}, {__mode = 'k'})
local fonts = setmetatable({}, {__mode = 'k'})
local bars = setmetatable({}, {__mode = 'k'})    -- fill textures that follow bar brightness
local texts = setmetatable({}, {__mode = 'k'})   -- Kit:Text strings -> asked for a shadow
local ghosts = setmetatable({}, {__mode = 'k'})  -- LCD ghost digits
local accentSprites = setmetatable({}, {__mode = 'k'})
local listeners = {}

function Kit:Tint(region, token, alpha)
	local entry = tinted[region]
	if not entry then entry = {}; tinted[region] = entry end
	entry[1], entry[2] = token, alpha or 1
	local r, g, b = self:RGB(token)
	if region.SetTextColor then region:SetTextColor(r, g, b, entry[2]) return end
	local isBar = region.SetStatusBarColor or bars[region]
	if isBar then
		local bright = self:Look('barBrightness') or 1
		if bright ~= 1 then r, g, b = min(r * bright, 1), min(g * bright, 1), min(b * bright, 1) end
	end
	if region.SetStatusBarColor then region:SetStatusBarColor(r, g, b, entry[2])
	else region:SetVertexColor(r, g, b, entry[2]) end
end

-- A texture that draws a bar's fill (a dot cover, a pill) follows bar brightness too.
function Kit:MarkBar(region)
	bars[region] = true
	local entry = tinted[region]
	if entry then self:Tint(region, entry[1], entry[2]) end
end

-- The reference's typeface, IBM Plex Mono (SIL OFL 1.1, Media/Fonts/OFL.txt), ships
-- with the addon. Another LibSharedMedia font can replace it in the hub.
Kit.fonts = {regular = UI.MediaPath..[[Fonts\IBMPlexMono-Regular.ttf]], bold = UI.MediaPath..[[Fonts\IBMPlexMono-Bold.ttf]]}
-- Audiowide (SIL OFL 1.1, Media/Fonts/OFL-Audiowide.txt) ships too, under the
-- name other addons give it, so a profile naming it works with or without
-- LibSharedMedia.
Kit.bundledFonts = {['Audiowide-Regular'] = UI.MediaPath..[[Fonts\Audiowide-Regular.ttf]]}
if LSM then
	LSM:Register('font', 'IBM Plex Mono', Kit.fonts.regular)
	LSM:Register('font', 'IBM Plex Mono Bold', Kit.fonts.bold)
	for name, path in pairs(Kit.bundledFonts) do
		if not LSM:IsValid('font', name) then LSM:Register('font', name, path) end
	end
end

-- Font areas: each part of the interface may have its own typeface and size
-- (the Fonts page, saved under db.fonts). A string's area is, in order: the
-- role its caller gave Kit:Font, 'numbers' for LCD print, then the first frame
-- above it that belongs to an area (a frame given one with Kit:SetFontRole, or
-- one of the interface's named frames below).
Kit.FONT_AREAS = {'unitframes', 'nameplates', 'chat', 'keys', 'numbers', 'windows'}
local fontRoles = setmetatable({}, {__mode = 'k'}) -- frame -> area
local LCD_TOKENS = {lcdInk = true, lcdGhost = true, lcdDim = true}
local NAMED_ROLES = {
	{'^JiberishSpec01Player$', 'unitframes'}, {'^JiberishSpec01Target$', 'unitframes'}, {'^JiberishSpec01Targettarget$', 'unitframes'},
	{'^JiberishSpec01Focus$', 'unitframes'}, {'^JiberishSpec01Pet$', 'unitframes'}, {'^JiberishSpec01Party%d$', 'unitframes'},
	{'^JiberishSpec01PartyHeader$', 'unitframes'}, {'^JiberishSpec01%a+Cast$', 'unitframes'}, {'^JiberishSpec01Raid', 'unitframes'},
	{'^JiberishSpec01Boss', 'unitframes'}, {'^JiberishSpec01Arena', 'unitframes'},
	{'^JiberishSpec01Bar%d', 'keys'}, {'^JiberishSpec01BarDevice', 'keys'}, {'^JiberishSpec01Console$', 'keys'},
	{'^JiberishSpec01SideBars$', 'keys'}, {'^JiberishSpec01PetKeys$', 'keys'}, {'^JiberishSpec01StanceKey', 'keys'},
	{'^JiberishSpec01Menu$', 'keys'}, {'^JiberishSpec01ExtraHolder$', 'keys'}, {'^JiberishSpec01ZoneHolder$', 'keys'},
	{'^NamePlate%d', 'nameplates'},
	{'^ChatFrame%d', 'chat'}, {'^GeneralDockManager', 'chat'}, {'^ChatFrameMenuButton', 'chat'}, {'^ChatFrameChannelButton', 'chat'},
}

-- Give a frame (and everything on it) an area, or nil to take it away.
function Kit:SetFontRole(frame, role)
	if type(frame) == 'table' then fontRoles[frame] = role end
end

local function FontDB() return UI.db and UI.db.fonts end

-- Whether any area differs from the whole interface; while none does, no
-- string's area is looked up at all.
local overridden
local function AnyOverride()
	local db = FontDB()
	if type(db) ~= 'table' then return false end
	for _, area in ipairs(Kit.FONT_AREAS) do
		local face, scale = db[area], db[area..'Scale']
		if (face and face ~= '__inherit') or (type(scale) == 'number' and scale ~= 1) then return true end
	end
	return false
end

local specialFrames
local function IsWindow(name)
	if type(UIPanelWindows) == 'table' and UIPanelWindows[name] then return true end
	if not specialFrames and type(UISpecialFrames) == 'table' then
		specialFrames = {}
		for _, special in ipairs(UISpecialFrames) do specialFrames[special] = true end
	end
	return specialFrames and specialFrames[name] or false
end

local function RoleByAncestry(object)
	local node = object
	for _ = 1, 16 do
		if type(node) ~= 'table' then return nil end
		local role = fontRoles[node]
		if role then return role end
		local name = node.GetName and node:GetName()
		if type(name) == 'string' then
			for _, entry in ipairs(NAMED_ROLES) do
				if name:find(entry[1]) then return entry[2] end
			end
			if IsWindow(name) then return 'windows' end
		end
		if not node.GetParent then return nil end
		node = node:GetParent()
	end
	return nil
end

local function RoleOf(fontString, data)
	if data and data[4] then return data[4] end
	local entry = tinted[fontString]
	if entry and LCD_TOKENS[entry[1]] then return 'numbers' end
	local ok, role = pcall(RoleByAncestry, fontString)
	return ok and role or nil
end

local function FacePath(name, bold)
	if name == '__game' then return STANDARD_TEXT_FONT end
	if name == '__numbers' then return [[Fonts\ARIALN.TTF]] end
	if name and Kit.bundledFonts[name] then return Kit.bundledFonts[name] end
	if name and name ~= '__default' and LSM then
		local path = LSM:Fetch('font', name, true)
		if path then return path end
	end
	return bold and Kit.fonts.bold or Kit.fonts.regular
end

-- role: an area from Kit.FONT_AREAS, or nil for the interface's own typeface.
function Kit:FontPath(bold, role)
	local db = FontDB()
	local face = role and type(db) == 'table' and db[role]
	if face and face ~= '__inherit' then return FacePath(face, bold) end
	return FacePath(self:DB().font, bold)
end

-- An area's size multiplier, on top of the Theme's text scale.
function Kit:FontScale(role)
	local db = FontDB()
	local scale = role and type(db) == 'table' and db[role..'Scale']
	return type(scale) == 'number' and scale > 0 and scale or 1
end

-- The typefaces the Fonts page offers: the bundled one, the game's, and every
-- LibSharedMedia font. inherit: lead with "same as the interface".
function Kit:FontChoices(inherit)
	local items = {}
	if inherit then items[#items + 1] = {'__inherit', 'Same as interface'} end
	items[#items + 1] = {'__default', 'IBM Plex Mono'}
	items[#items + 1] = {'__game', 'Game font'}
	items[#items + 1] = {'__numbers', 'Game numbers (narrow)'}
	items[#items + 1] = {'Audiowide-Regular', 'Audiowide'}
	if LSM then
		for _, name in ipairs(LSM:List('font') or {}) do
			if name ~= 'IBM Plex Mono' and name ~= 'IBM Plex Mono Bold' and not Kit.bundledFonts[name] then items[#items + 1] = {name, name} end
		end
	end
	return items
end

-- The Theme page's outline applies to text that asked for none; a thick
-- outline thickens text that asked for one too.
local function FontFlags(flags)
	flags = flags or ''
	local style = Kit:Look('textOutline')
	if style == 'thick' then return flags:find('MONOCHROME') and 'THICKOUTLINE, MONOCHROME' or 'THICKOUTLINE' end
	if style == 'outline' and flags == '' then return 'OUTLINE' end
	return flags
end

local function ApplyFont(fontString, data)
	if overridden == nil then overridden = AnyOverride() end
	local role = (overridden or data[4]) and RoleOf(fontString, data) or nil
	local size = data[1] * (Kit:Look('textScale') or 1) * Kit:FontScale(role)
	local flags = FontFlags(data[2])
	-- A FontString reports failure with false; Font objects return nothing. On
	-- some of the game's own strings the answer is secret: never compare it.
	local applied = fontString:SetFont(Kit:FontPath(data[3], role), size, flags)
	if not (issecretvalue and issecretvalue(applied)) and applied == false then
		fontString:SetFont(STANDARD_TEXT_FONT, size, flags)
	end
end

-- flags: '' or 'OUTLINE'; bold: the heavier cut, for model codes and headings.
-- role (optional): the font area, from Kit.FONT_AREAS; without one the area is
-- worked out from where the string sits.
function Kit:Font(fontString, size, flags, bold, role)
	local data = {size or 11, flags or '', bold, role}
	fonts[fontString] = data
	ApplyFont(fontString, data)
end

local function ApplyShadow(fontString)
	if texts[fontString] or Kit:Look('textShadow') then
		fontString:SetShadowOffset(1, -1)
		fontString:SetShadowColor(0, 0, 0, 0.6)
	else
		fontString:SetShadowOffset(0, 0)
	end
end

-- LCD ghost digits (the unlit "888" under a readout) follow the Theme page.
function Kit:Ghost(fontString)
	ghosts[fontString] = true
	fontString:SetShown(self:Look('ghostDigits') and true or false)
	return fontString
end

-- The fill interpolation for StatusBar:SetValue, following "Smooth bars".
local INTERPOLATION = Enum and Enum.StatusBarInterpolation
function Kit:Smooth()
	if not INTERPOLATION then return nil end
	return self:Look('smoothBars') and INTERPOLATION.ExponentialEaseOut or INTERPOLATION.Immediate
end
Kit.SMOOTH = INTERPOLATION and INTERPOLATION.ExponentialEaseOut

function Kit:OnRefresh(callback) listeners[#listeners + 1] = callback end

-- Repaint everything. A slider drag asks many times a second; a repaint runs at
-- once, and any more asked for within 0.1 s become one more at its end.
local lastRefresh, refreshQueued = 0, false
local function RefreshNow()
	refreshQueued = false
	lastRefresh = GetTime()
	Kit.SMOOTH = Kit:Smooth()
	overridden, specialFrames = AnyOverride(), nil
	for fontString, data in pairs(fonts) do ApplyFont(fontString, data) end
	for fontString in pairs(texts) do ApplyShadow(fontString) end
	for fontString in pairs(ghosts) do fontString:SetShown(Kit:Look('ghostDigits') and true or false) end
	for region, entry in pairs(tinted) do Kit:Tint(region, entry[1], entry[2]) end
	for texture in pairs(accentSprites) do Kit:SetSprite(texture, texture.kitSprite) end
	for _, callback in ipairs(listeners) do callback() end
	Kit:RefitShells()
end

function Kit:Refresh()
	if GetTime() - lastRefresh >= 0.1 then return RefreshNow() end
	if refreshQueued then return end
	refreshQueued = true
	C_Timer.After(0.1, function()
		if refreshQueued then RefreshNow() end
	end)
end

-- A repaint right now, for callers that lay out against the new fonts next (Kit:Apply).
function Kit:RefreshNow() RefreshNow() end

-- Sounds ---------------------------------------------------------------
-- The fifteen SPEC-01 voices. Each has several recorded takes, because the
-- original varies pitch and level on every press; one is picked at random.
Kit.sounds = {'down', 'down-primary', 'up', 'latch-down', 'latch-up', 'tick', 'blip', 'type', 'type-space',
	'type-big', 'type-up', 'open', 'success', 'warning', 'error',
	-- This addon's own mechanisms, for the fade styles (tools/build-hardware-sounds.py).
	'power-down', 'power-up', 'relay', 'servo', 'shutter', 'iris', 'detent'}
Kit.soundTakes = 3
-- The same voice plays at most once per 0.1 s (a window and the game's own
-- click for it are heard once), and nothing plays closer than 20 ms apart.
-- Keys and typing may repeat quickly; one-shot voices (a window opening, an
-- outcome chime) are heard once even if two things ask for them together.
local ONE_SHOT = {open = true, success = true, warning = true, error = true, blip = true}
local lastSound, lastByName = 0, {}
function Kit:Play(name, force)
	local db = self:DB().sound
	if not db.enable or not (force or db.widgets) then return end
	local now = GetTime()
	if now - lastSound < 0.015 or (ONE_SHOT[name] and now - (lastByName[name] or 0) < 0.1) then return end
	lastSound, lastByName[name] = now, now
	local willPlay, handle = PlaySoundFile(self.media..[[Sounds\]]..name..'-'..math.random(1, self.soundTakes)..'.mp3', db.channel or 'Master')
	-- The Motion page's spectrum listens for sounds.
	if willPlay and self.OnPlayed then pcall(self.OnPlayed, name) end
	return willPlay, handle
end

-- /ji sound: say exactly what the client did with a sound, for troubleshooting.
function Kit:SoundReport()
	local db = self:DB().sound
	local path = self.media..[[Sounds\down-primary-1.mp3]]
	local willPlay, handle = PlaySoundFile(path, db.channel or 'Master')
	UI:Print(format('Hardware sounds: enabled %s, theme controls %s, channel %s. Played %s: %s (handle %s). Game sound is %s, master volume %s.',
		tostring(db.enable), tostring(db.widgets), tostring(db.channel or 'Master'), path, tostring(willPlay), tostring(handle),
		GetCVar and GetCVar('Sound_EnableAllSound') == '1' and 'on' or 'off', GetCVar and tostring(GetCVar('Sound_MasterVolume')) or '?'))
end

-- Animation --------------------------------------------------------------
-- SPEC-01's motion: mechanisms, not springs. `detent` is for anything that
-- snaps to a position (a lever, a latch, an indicator): a moment's resistance,
-- then a quick travel that stops dead. `settle` is for things that don't click
-- (screens, meters, pop-ups): a smooth ease-out with no bounce. Same cubic
-- Bezier curves as its tokens.css and toast transition.
local function Bezier(x1, y1, x2, y2)
	return function(progress)
		local low, high, t = 0, 1, progress
		for _ = 1, 14 do
			local x = 3 * (1 - t) ^ 2 * t * x1 + 3 * (1 - t) * t ^ 2 * x2 + t ^ 3
			if x < progress then low = t else high = t end
			t = (low + high) / 2
		end
		return 3 * (1 - t) ^ 2 * t * y1 + 3 * (1 - t) * t ^ 2 * y2 + t ^ 3
	end
end
Kit.ease = {detent = Bezier(0.45, 0, 0.15, 1), settle = Bezier(0.2, 0.8, 0.2, 1), toast = Bezier(0.2, 0.9, 0.2, 1),
	-- Fades use a sine (a cubic does most of a fade in the first frames and reads as a pop);
	-- movement uses a cubic ease-out (bursts, then settles).
	sine = function(t) return math.sin(t * math.pi / 2) end,
	cubic = function(t) return 1 - (1 - t) ^ 3 end,
	inout = function(t) return t < 0.5 and 2 * t * t or 1 - (-2 * t + 2) ^ 2 / 2 end,
	-- The reference's key travel (--lift): cubic-bezier(0.3, 0, 0.6, 1).
	lift = Bezier(0.3, 0, 0.6, 1)}

-- The only speeds anything moves at: one rhythm across the whole interface.
Kit.SPEED = {FAST = 0.12, NORMAL = 0.2, SLOW = 0.4, CLOSE = 0.3}
function Kit:Speed(speed) return type(speed) == 'number' and speed or self.SPEED[speed or 'NORMAL'] or 0.2 end

local animations, finished = {}, {}
local driver = CreateFrame('Frame')
driver:Hide()
local snapshot = {}
driver:SetScript('OnUpdate', function(_, elapsed)
	local busy
	-- A hitch never jumps an animation more than a tenth of a second.
	elapsed = min(elapsed, 0.1)
	-- Step a snapshot, so steps can start or end other animations safely.
	wipe(snapshot)
	for key, animation in pairs(animations) do snapshot[key] = animation end
	for key, animation in pairs(snapshot) do
		animation.time = animation.time + elapsed
		local progress = animation.time >= animation.duration and 1 or animation.time / animation.duration
		local eased = progress >= 1 and 1 or animation.ease(progress)
		-- A failing step ends its own animation instead of erroring every frame.
		local ok = pcall(animation.step, animation.from + (animation.to - animation.from) * eased, progress)
		if progress >= 1 or not ok then
			if animations[key] == animation then animations[key] = nil end
			if animation.done then finished[#finished + 1] = animation.done end
		else busy = true end
	end
	if not busy then driver:Hide() end
	for i = #finished, 1, -1 do
		local done = finished[i]
		finished[i] = nil
		done()
	end
end)

-- ease: 'settle' (default), 'detent', 'toast', 'sine', 'cubic' or 'inout'.
-- A new animation on the same key replaces the old one; duration 0 lands at once.
function Kit:Animate(key, duration, from, to, step, done, ease)
	if self:DB().reduceMotion or duration <= 0 or from == to then
		animations[key] = nil
		step(to, 1)
		if done then done() end
		return
	end
	duration = duration * min(max(self:Look('motionScale') or 1, 0.5), 1.5)
	animations[key] = {time = 0, duration = duration, from = from, to = to, step = step, done = done,
		ease = ease == 'linear' and function(t) return t end or self.ease[ease] or self.ease.settle}
	step(from, 0)
	driver:Show()
end

function Kit:Animating(key) return animations[key] ~= nil end

-- Ease a region's alpha from wherever it is. Speeds: 'FAST', 'NORMAL', 'SLOW', 'CLOSE' or seconds.
function Kit:FadeTo(region, alpha, speed, done)
	local from = region:GetAlpha()
	if issecretvalue and issecretvalue(from) then from = alpha end
	self:Animate(region, self:Speed(speed), from, alpha, function(value) region:SetAlpha(value) end, done, 'sine')
end

-- Our own windows open with a fade and an 8 px rise, and close with a fade and
-- a 4 px sink. Only ever used on this addon's own, unprotected frames.
local rests = setmetatable({}, {__mode = 'k'})
local function Rest(frame)
	local rest = rests[frame]
	if not rest then
		local point, relative, relativePoint, x, y = frame:GetPoint(1)
		rest = {point, relative, relativePoint, x or 0, y or 0}
		rests[frame] = rest
	end
	return rest
end

local function Offset(frame, dy)
	local rest = Rest(frame)
	frame:ClearAllPoints()
	frame:SetPoint(rest[1], rest[2], rest[3], rest[4], rest[5] + dy)
end

function Kit:Open(frame)
	-- Mid-animation the anchor still carries an offset; only a frame at rest
	-- (perhaps dragged somewhere new) gets its resting point read again.
	if not self:Animating(frame) then rests[frame] = nil end
	frame.kitClosing = nil
	Rest(frame)
	local from = frame:IsShown() and frame:GetAlpha() or 0
	frame:SetAlpha(from)
	frame:Show()
	self:Animate(frame, 0.22, 0, 1, function(progress)
		frame:SetAlpha(from + (1 - from) * self.ease.sine(progress))
		Offset(frame, -8 * (1 - self.ease.cubic(progress)))
	end, nil, 'linear')
end

-- Forget a frame's resting point, after the caller moved it somewhere new.
function Kit:ResetRest(frame) rests[frame] = nil end

function Kit:Close(frame, done)
	if not frame:IsShown() or frame.kitClosing then return end
	frame.kitClosing = true
	if not self:Animating(frame) then rests[frame] = nil end
	Rest(frame)
	local from = frame:GetAlpha()
	self:Animate(frame, 0.25, 0, 1, function(progress)
		frame:SetAlpha(from * (1 - self.ease.inout(progress)))
		Offset(frame, -4 * self.ease.cubic(progress))
	end, function()
		frame.kitClosing = nil
		frame:Hide()
		Offset(frame, 0)
		frame:SetAlpha(1)
		if done then done() end
	end, 'linear')
end

-- Primitives -------------------------------------------------------------
local SLICES = {['round-3'] = 7, ['round-6'] = 15, ['round-10'] = 24, ['ring-3'] = 7, ['ring-6'] = 15, ['ring-10'] = 24,
	shadow = 28, ['inset-3'] = 7, ['inset-6'] = 15}
local STRETCHED = Enum and Enum.UITextureSliceMode and Enum.UITextureSliceMode.Stretched

function Kit:Texture(parent, file, layer, sublevel)
	local texture = parent:CreateTexture(nil, layer or 'ARTWORK', nil, sublevel or 0)
	if not file then return texture end
	texture:SetTexture(self.media..file..'.tga')
	local margin = SLICES[file]
	if margin and texture.SetTextureSliceMargins then
		texture:SetTextureSliceMargins(margin, margin, margin, margin)
		if STRETCHED and texture.SetTextureSliceMode then texture:SetTextureSliceMode(STRETCHED) end
		if texture.SetScale then
			texture:SetScale(self.sliceScale)
			texture.kitScale = self.sliceScale
		end
	end
	return texture
end

-- Anchor a (possibly half-scale) texture around `anchor`; positive values grow outward.
function Kit:Place(texture, anchor, left, top, right, bottom)
	local scale = texture.kitScale or 1
	texture:ClearAllPoints()
	texture:SetPoint('TOPLEFT', anchor, 'TOPLEFT', -(left or 0) / scale, (top or 0) / scale)
	texture:SetPoint('BOTTOMRIGHT', anchor, 'BOTTOMRIGHT', (right or 0) / scale, -(bottom or 0) / scale)
end

-- Baked reference art -------------------------------------------------------
-- Kit.skin (Skin.lua) describes each capture: the control's own size, how far
-- its shadow and lip extend past it, and the corner kept unstretched.
function Kit:SpriteFile(name)
	local info = self.skin[name]
	if not info.accent then return name, 1, 1, 1 end
	local accent = self:DB().accent
	if accent ~= 'tint' and self.accentSkin[accent] then return name..'-'..accent, 1, 1, 1 end
	-- A class or custom color multiplies the near-white key.
	local r, g, b = self:Accent()
	local base = self.accentSkin.tint.key[1]
	return name..'-tint', min(r / base, 1), min(g / base, 1), min(b / base, 1)
end

function Kit:SetSprite(texture, name)
	local info = self.skin[name]
	local file, r, g, b = self:SpriteFile(name)
	texture:SetTexture(self.media..[[Skin\]]..file..'.tga')
	texture.kitSprite, texture.kitInfo = name, info
	if info.c and texture.SetTextureSliceMargins and texture.SetScale then
		texture:SetTextureSliceMargins((info.l + info.c) * 2, (info.t + info.c) * 2, (info.r + info.c) * 2, (info.b + info.c) * 2)
		if STRETCHED and texture.SetTextureSliceMode then texture:SetTextureSliceMode(STRETCHED) end
		texture.kitSliced = true
	elseif texture.kitSliced then
		if texture.ClearTextureSlice then texture:ClearTextureSlice() end
		texture:SetScale(1)
		texture.kitSliced, texture.kitScale = nil, nil
	end
	-- Each sprite brings its own coloring; drop whatever the previous one set.
	accentSprites[texture] = nil
	tinted[texture] = nil
	if info.accent then
		accentSprites[texture] = true
		texture:SetVertexColor(r, g, b, 1)
	elseif info.tint then self:Tint(texture, info.tint)
	else texture:SetVertexColor(1, 1, 1, 1) end
	-- Sprites differ in how far their shadow and lip reach; refit at the last size.
	if texture.kitFit then self:FitSprite(texture, texture.kitFit[1], texture.kitFit[2]) end
end

-- Size a sprite to a control of width x height. Nine-slice art keeps its
-- corners, shrinking them for controls smaller than the reference; fixed art
-- (round keys, thumbs, lamps) scales with the control.
function Kit:FitSprite(texture, width, height)
	local info = texture.kitInfo
	-- Sizes the client keeps secret (some tooltips, nameplates) cannot be compared.
	if issecretvalue and (issecretvalue(width) or issecretvalue(height)) then return end
	texture.kitFit = {width, height}
	if not width or width <= 0 or not height or height <= 0 then
		width, height = info.w * self.zoom, info.h * self.zoom
	end
	local kx, ky
	if texture.kitSliced then
		kx = min(self.zoom, width / (2 * info.c), height / (2 * info.c), (texture.kitMaxCorner or info.c) / info.c)
		ky = kx
		texture:SetScale(kx / 2)
		texture.kitScale = kx / 2
	else
		kx, ky = width / info.w, height / info.h
	end
	self:Place(texture, texture.kitOwner, info.l * kx, info.t * ky, info.r * kx, info.b * ky)
end

-- Draw a capture behind `frame` and keep it fitted as the frame is resized.
function Kit:Skin(frame, name, layer, sublevel)
	local texture = frame:CreateTexture(nil, layer or 'BACKGROUND', nil, sublevel or -6)
	texture.kitOwner = frame
	self:SetSprite(texture, name)
	frame:HookScript('OnSizeChanged', function(_, width, height) Kit:FitSprite(texture, width, height) end)
	self:FitSprite(texture, frame:GetWidth(), frame:GetHeight())
	return texture
end

function Kit:Solid(parent, token, layer, sublevel, alpha)
	local texture = parent:CreateTexture(nil, layer or 'ARTWORK', nil, sublevel or 0)
	texture:SetColorTexture(1, 1, 1, 1)
	self:Tint(texture, token or 'hair', alpha)
	return texture
end

function Kit:Icon(parent, name, size, token)
	local texture = self:Texture(parent, 'icons', 'OVERLAY')
	texture:SetSize(size or 16, size or 16)
	self:SetIcon(texture, name)
	self:Tint(texture, token or 'ink')
	return texture
end

function Kit:SetIcon(texture, name)
	local index = self.icons[name] or self.icons.info
	local column, row = index % 8, floor(index / 8)
	texture:SetTexCoord(column / 8, (column + 1) / 8, row / 8, (row + 1) / 8)
end

-- Text sizes by role, so every part of the interface shares one scale.
Kit.SIZE = {tiny = 8, label = 9, small = 10, body = 12, value = 13, head = 15, title = 18}

-- size: a number or a role from Kit.SIZE. shadow: a soft drop shadow, for
-- text that sits over the game world rather than on a housing.
function Kit:Text(parent, text, size, token, bold, shadow)
	local fontString = parent:CreateFontString(nil, 'OVERLAY')
	if type(size) == 'string' then size = self.SIZE[size] end
	-- Tinted first: LCD ink tells the font which area it belongs to.
	self:Tint(fontString, token or 'ink')
	self:Font(fontString, size or 11, nil, bold)
	texts[fontString] = shadow and true or false
	ApplyShadow(fontString)
	if text then fontString:SetText(text) end
	return fontString
end

-- Small uppercase captions, the kit's default voice.
function Kit:Label(parent, text, token, size, bold)
	return self:Text(parent, text and strupper(text), size or 9, token or 'ink', bold)
end

-- Shells -------------------------------------------------------------------
-- Every in-world SPEC-01 surface is drawn from code, in physical pixels: a
-- soft shadow, a crisp edge, a slightly translucent fill and a 1 px bevel
-- (lit along the top, shaded along the bottom). Nothing is a stretched
-- bitmap, so edges stay sharp at any size and UI scale.
local SHELL_ART_RADIUS, SHELL_SLICE = 24, 26
local SHADOW_ART_INSET, SHADOW_SLICE = 32, 56
local shells = setmetatable({}, {__mode = 'k'})

-- How each surface reads: fill and edge tokens, edge alpha and bevel strengths.
Kit.SURFACES = {
	-- Paper: a warm hairline (the reference's 1 px hsl(45 8% 30% / .13) ring),
	-- a white top edge, a faint shade at the foot, a side wall and warm shadows.
	paper = {fill = 'panel', edge = 'shadowTint', edgeAlpha = 0.2, lit = 1, shade = 0.05, wall = 'wall', warm = true},
	dark = {fill = 'dark', edge = 'black', edgeAlpha = 1, lit = 0.07, shade = 0.35},
	-- The gray LCD is recessed: shaded under its top edge, lit along its foot.
	lcd = {fill = 'lcd', edge = 'black', edgeAlpha = 0.28, lit = 0.22, shade = 0.75, recessed = true},
	glass = {fill = 'glass', edge = 'black', edgeAlpha = 1, lit = 0.08, shade = 0},
	screen = {fill = 'screenFill', edge = 'black', edgeAlpha = 1, lit = 0.05, shade = 0},
}

local function SlicedTexture(owner, file, layer, sublevel, margin)
	local texture = owner:CreateTexture(nil, layer, nil, sublevel)
	texture:SetTexture(Kit.media..file..'.tga', 'CLAMP', 'CLAMP')
	if texture.SetTextureSliceMargins then
		texture:SetTextureSliceMargins(margin, margin, margin, margin)
		if STRETCHED and texture.SetTextureSliceMode then texture:SetTextureSliceMode(STRETCHED) end
	end
	return texture
end

local function ScaleTo(texture, scale)
	if texture.SetScale then
		texture:SetScale(max(scale, 0.01))
		texture.kitScale = max(scale, 0.01)
	end
end

-- Housings: color, gradient and material per group --------------------------------------
-- Every housing belongs to a group: the console (CX-1), the unit frames, every
-- other device, and screens and LCDs. Each group may take its own color (a
-- preset shade, a key color full or muted, or the player's own), a two-stop
-- gradient and a material laid over the fill. Kit:Shell opts.group picks the
-- group; without one a housing is a 'device' and a screen or LCD a 'screen'.
Kit.HOUSING_GROUPS = {'console', 'unitframes', 'devices', 'screens'}

-- Materials: seamless detail drawn one texel per physical pixel over the fill
-- (tools/build-hardware-materials.py). gain: the strength at 100%.
Kit.MATERIALS = {
	{key = 'matte', name = 'Matte'},
	{key = 'machined', name = 'Machined', w = 1024, h = 256, gain = 0.55},
	{key = 'brushed', name = 'Brushed metal', w = 1024, h = 256, gain = 0.6},
	{key = 'etched', name = 'Etched', w = 256, h = 256, gain = 0.5},
	{key = 'worn', name = 'Worn metal', w = 1024, h = 512, gain = 0.65},
	{key = 'bead', name = 'Bead-blasted', w = 512, h = 512, gain = 0.4},
	{key = 'paper', name = 'Paper', w = 512, h = 512, gain = 0.45},
	{key = 'plastic', name = 'Molded plastic', w = 512, h = 512, gain = 0.45},
	{key = 'carbon', name = 'Carbon fibre', w = 128, h = 128, gain = 0.75},
}
Kit.MATERIAL = {}
for _, entry in ipairs(Kit.MATERIALS) do Kit.MATERIAL[entry.key] = entry end

-- Housing shades: studio whites through greys and metals to black, then every
-- key color, full and muted.
Kit.HOUSING_COLORS = {
	{'default', 'Finish'}, {'studio', 'Studio white', Hex('f4f4f1')}, {'offwhite', 'Off-white', Hex('fbfbfa')},
	{'bone', 'Bone', Hex('e8e2d4')}, {'warmgrey', 'Warm grey', Hex('b8b3a8')}, {'coolgrey', 'Cool grey', Hex('a9afb5')},
	{'aluminium', 'Aluminium', Hex('cfd1d2')}, {'steel', 'Steel', Hex('8d9399')}, {'gunmetal', 'Gunmetal', Hex('3b3e42')},
	{'graphite', 'Graphite', Hex('2c2c2a')}, {'carbon', 'Carbon', Hex('1c1d1f')}, {'black', 'Black', Hex('0b0b0b')},
}
for _, name in ipairs(Kit.accentOrder) do
	local accent = Kit.accents[name]
	local r, g, b = accent[1], accent[2], accent[3]
	local gray = 0.299 * r + 0.587 * g + 0.114 * b
	local list = Kit.HOUSING_COLORS
	list[#list + 1] = {name, accent.name, {r, g, b}, accent = name}
	list[#list + 1] = {'muted-'..name, accent.name..' (muted)', {(r + (gray - r) * 0.55) * 0.9, (g + (gray - g) * 0.55) * 0.9, (b + (gray - b) * 0.55) * 0.9}}
end
Kit.HOUSING_COLORS[#Kit.HOUSING_COLORS + 1] = {'custom', 'Custom'}
Kit.HOUSING_COLOR = {}
for _, entry in ipairs(Kit.HOUSING_COLORS) do Kit.HOUSING_COLOR[entry[1]] = entry end

local looks = {}
-- {color = {r, g, b} or nil, gradient = {from, to, dir} or nil, material = key, strength = 0..1}
function Kit:HousingLook(group)
	group = group or 'devices'
	local look = looks[group]
	if not look then look = {}; looks[group] = look end
	local db = UI.db and UI.db.housing
	local entry = type(db) == 'table' and db[group]
	look.color, look.gradient, look.material, look.strength = nil, nil, 'matte', 0
	if type(entry) ~= 'table' then return look end
	local shade = self.HOUSING_COLOR[entry.color]
	if entry.color == 'custom' and type(entry.custom) == 'table' then
		local c = entry.custom
		look.color = {c.r or c[1] or 1, c.g or c[2] or 1, c.b or c[3] or 1}
	elseif shade and shade.accent and self.accentSkin and self.accentSkin[shade.accent] then
		look.color = self.accentSkin[shade.accent].key
	elseif shade then
		look.color = shade[3]
	end
	local gradient = entry.gradient and entry.gradientColors
	if type(gradient) == 'table' and type(gradient.from) == 'table' and type(gradient.to) == 'table' then look.gradient = gradient end
	if self.MATERIAL[entry.material] then look.material = entry.material end
	look.strength = min(max(tonumber(entry.strength) or 0, 0), 1)
	return look
end

local SCREEN_SURFACES = {glass = true, screen = true, lcd = true}
local function GroupOf(opts, name)
	if opts.group then return opts.group end
	if SCREEN_SURFACES[name] then return 'screens' end
	if name == 'paper' or name == 'dark' then return 'devices' end
end

local function Parts(color)
	return color.r or color[1] or 1, color.g or color[2] or 1, color.b or color[3] or 1, color.a or color[4] or 1
end

-- A gradient over a housing: down, across, or corner to corner (two washes,
-- across and down at half strength, which together run diagonally).
local function Wash(shell, gradient, alpha)
	local fr, fg, fb, fa = Parts(gradient.from)
	local tr, tg, tb, ta = Parts(gradient.to)
	local from, to = CreateColor(fr, fg, fb, fa * alpha), CreateColor(tr, tg, tb, ta * alpha)
	shell.tint:SetVertexColor(1, 1, 1, 1)
	if gradient.dir == 'HORIZONTAL' or gradient.dir == 'DIAGONAL' then
		shell.tint:SetGradient('HORIZONTAL', from, to)
	else
		-- A vertical gradient's first color is its bottom.
		shell.tint:SetGradient('VERTICAL', to, from)
	end
	shell.tint:Show()
	if gradient.dir == 'DIAGONAL' then
		if not shell.tint2 then
			shell.tint2 = shell:CreateTexture(nil, 'BACKGROUND', nil, -4)
			shell.tint2:SetTexture(Kit.media..'shell.tga', 'CLAMP', 'CLAMP')
			if shell.tint2.SetTextureSliceMargins then
				shell.tint2:SetTextureSliceMargins(SHELL_SLICE, SHELL_SLICE, SHELL_SLICE, SHELL_SLICE)
				if STRETCHED and shell.tint2.SetTextureSliceMode then shell.tint2:SetTextureSliceMode(STRETCHED) end
			end
			shell.tint2.refit = true
		end
		shell.tint2:SetVertexColor(1, 1, 1, 1)
		shell.tint2:SetGradient('VERTICAL', CreateColor(tr, tg, tb, ta * alpha * 0.5), CreateColor(fr, fg, fb, fa * alpha * 0.5))
		shell.tint2:Show()
	elseif shell.tint2 then
		shell.tint2:Hide()
	end
end

-- Material pieces: the fill's area cut into a middle, a top and a bottom band
-- and four corners, each corner masked by a circle so the material keeps the
-- housing's rounded shape. All seven share one texture grid, so the pattern
-- runs on unbroken from piece to piece.
local function MaterialPieces(shell)
	if shell.material then return shell.material end
	local set = {masks = {}}
	for index = 1, 7 do set[index] = shell:CreateTexture(nil, 'BACKGROUND', nil, -4) end
	for index = 1, 4 do
		local mask = shell:CreateMaskTexture()
		mask:SetTexture(Kit.media..'circle.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
		set[3 + index]:AddMaskTexture(mask)
		set.masks[index] = mask
	end
	shell.material = set
	return set
end

local function PaintMaterial(shell, look, alpha)
	local entry = look and Kit.MATERIAL[look.material]
	if not (entry and entry.w) or look.strength <= 0 then
		if shell.material then for index = 1, 7 do shell.material[index]:Hide() end end
		local was = shell.materialKey
		shell.materialKey = nil
		return was ~= nil
	end
	local set = MaterialPieces(shell)
	local changed = shell.materialKey ~= entry.key
	shell.materialKey = entry.key
	for index = 1, 7 do
		local piece = set[index]
		if changed then piece:SetTexture(Kit.media..'Materials\\'..entry.key..'.tga', 'REPEAT', 'REPEAT', 'NEAREST') end
		piece:SetAlpha(min(1, entry.gain * look.strength) * alpha)
	end
	return changed
end

local CORNERS = {{'TOPLEFT', 1, -1}, {'TOPRIGHT', -1, -1}, {'BOTTOMLEFT', 1, 1}, {'BOTTOMRIGHT', -1, 1}}
-- b: the border, r: the fill's corner radius, px: one physical pixel (all in the owner's units).
local function FitMaterial(shell, width, height, b, r, px)
	local set, entry = shell.material, shell.materialKey and Kit.MATERIAL[shell.materialKey]
	if not (set and entry) then return end
	local owner = shell.owner
	local plain = width and height and not (issecretvalue and (issecretvalue(width) or issecretvalue(height)))
	if not plain or width <= 2 * (b + r) + px or height <= 2 * (b + r) + px then
		for index = 1, 7 do set[index]:Hide() end
		return
	end
	-- One texel per physical pixel: the texture's size in the owner's units.
	local tw, th = entry.w * px, entry.h * px
	local function Place(piece, x0, y0, x1, y1)
		piece:SetTexCoord(x0 / tw, x1 / tw, y0 / th, y1 / th)
		piece:Show()
	end
	local W, H, e = width, height, b + r
	local middle, top, bottom = set[1], set[2], set[3]
	middle:ClearAllPoints()
	middle:SetPoint('TOPLEFT', owner, 'TOPLEFT', b, -e)
	middle:SetPoint('BOTTOMRIGHT', owner, 'BOTTOMRIGHT', -b, e)
	Place(middle, b, e, W - b, H - e)
	top:ClearAllPoints()
	top:SetPoint('TOPLEFT', owner, 'TOPLEFT', e, -b)
	top:SetPoint('BOTTOMRIGHT', owner, 'TOPRIGHT', -e, -e)
	Place(top, e, b, W - e, e)
	bottom:ClearAllPoints()
	bottom:SetPoint('TOPLEFT', owner, 'BOTTOMLEFT', e, e)
	bottom:SetPoint('BOTTOMRIGHT', owner, 'BOTTOMRIGHT', -e, b)
	Place(bottom, e, H - e, W - e, H - b)
	for index, corner in ipairs(CORNERS) do
		local piece, mask = set[3 + index], set.masks[index]
		local point, sx, sy = corner[1], corner[2], corner[3]
		piece:ClearAllPoints()
		piece:SetSize(r, r)
		piece:SetPoint(point, owner, point, sx * b, sy * b)
		local x0 = sx > 0 and b or W - e
		local y0 = sy < 0 and b or H - e
		Place(piece, x0, y0, x0 + r, y0 + r)
		mask:ClearAllPoints()
		mask:SetSize(2 * r, 2 * r)
		mask:SetPoint('CENTER', owner, point, sx * e, sy * e)
	end
end

function Kit:FitShell(shell)
	local owner, opts = shell.owner, shell.opts
	local Pixel = UI.Pixel
	if not Pixel then return end
	local width, height = owner:GetSize()
	local px = Pixel.Px(shell, 1)
	local border = px * min(max(floor((self:Look('borderPx') or 1) + 0.5), 1), 3)
	local rounding = min(max(self:Look('rounding') or 1, 0.5), 1.5)
	local radius = Pixel.Snap(shell, (opts.radius or 8) * rounding * px)
	-- With a plain size, the radius is never larger than the shorter side allows,
	-- leaving room for the slice margins. A size that is secret or not laid out
	-- yet still gets the textures placed, so the shell shows.
	local secret = issecretvalue and (issecretvalue(width) or issecretvalue(height))
	if not secret and width and height and width > 0 and height > 0 then
		radius = min(radius, min(width, height) / 2 * SHELL_ART_RADIUS / SHELL_SLICE)
	end
	local inner = max(radius - border, px)
	ScaleTo(shell.edge, radius / SHELL_ART_RADIUS)
	self:Place(shell.edge, owner, 0, 0, 0, 0)
	ScaleTo(shell.fill, inner / SHELL_ART_RADIUS)
	self:Place(shell.fill, owner, -border, -border, -border, -border)
	for _, tint in ipairs({shell.tint, shell.tint2}) do
		ScaleTo(tint, inner / SHELL_ART_RADIUS)
		self:Place(tint, owner, -border, -border, -border, -border)
	end
	FitMaterial(shell, width, height, border, inner, px)
	-- A wall shows only on a paper housing; the shadow then starts under it.
	local wall = 0
	if shell.wall then
		wall = shell.wallShown and Pixel.Snap(shell, 2) or 0
		ScaleTo(shell.wall, radius / SHELL_ART_RADIUS)
		self:Place(shell.wall, owner, 0, -wall, 0, wall)
	end
	if shell.shadow then
		local scale = radius / SHELL_ART_RADIUS * min(max(self:Look('shadowSize') or 1, 0), 2.5)
		local spread = SHADOW_ART_INSET * scale
		ScaleTo(shell.shadow, scale)
		if shell.warm then
			-- One light above and to the left: soft shadows fall right and down, 1:2.
			local drop = Pixel.Snap(shell, spread * 0.3) + wall
			local shift = Pixel.Snap(shell, spread * 0.15)
			self:Place(shell.shadow, owner, spread - shift, spread - drop, spread + shift, spread + drop)
		else
			self:Place(shell.shadow, owner, spread, spread - px, spread, spread + px)
		end
	end
	shell.lit:ClearAllPoints()
	shell.lit:SetPoint('TOPLEFT', owner, 'TOPLEFT', radius, -px)
	shell.lit:SetPoint('TOPRIGHT', owner, 'TOPRIGHT', -radius, -px)
	shell.lit:SetHeight(px)
	shell.shade:ClearAllPoints()
	shell.shade:SetPoint('BOTTOMLEFT', owner, 'BOTTOMLEFT', radius, px)
	shell.shade:SetPoint('BOTTOMRIGHT', owner, 'BOTTOMRIGHT', -radius, px)
	shell.shade:SetHeight(px)
end

function Kit:PaintShell(shell)
	local opts = shell.opts
	local name = opts.surface or 'paper'
	-- On the Graphite finish a paper housing is the dark one.
	if name == 'paper' and self:DB().finish == 'graphite' then name = 'dark' end
	local surface = self.SURFACES[name] or self.SURFACES.paper
	local alpha = opts.alpha or (name == 'paper' or name == 'dark') and (self:DB().housingAlpha or 0.95) or 1
	local group = GroupOf(opts, name)
	local look = group and self:HousingLook(group)
	-- A group's own color (screens and housings; an LCD keeps its gray glass).
	if look and look.color and not opts.fill and name ~= 'lcd' then
		self:Tint(shell.fill, look.color, alpha)
	else
		self:Tint(shell.fill, opts.fill or surface.fill, alpha)
	end
	-- A device's printed header reads on its housing: light print on a dark color.
	local owner = shell.owner
	if owner.kitHeader and owner.model and owner.title then
		local ink = self.INK[owner.surface] or self.INK.paper
		if look and look.color and name ~= 'lcd' then
			local c = look.color
			ink = (0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3]) < 0.5 and self.INK.dark or self.INK.paper
		end
		self:Tint(owner.model, ink[1])
		self:Tint(owner.title, ink[2])
	end
	-- An edge color override recolors housing edges too (at least half strength, so it shows).
	local housing = name == 'paper' or name == 'dark'
	if not opts.edge and housing and self:Overridden('edge') then
		self:Tint(shell.edge, 'edgeOverride', max(surface.edgeAlpha, 0.5) * min(1, alpha + 0.05))
	else
		self:Tint(shell.edge, opts.edge or surface.edge, surface.edgeAlpha * min(1, alpha + 0.05))
	end
	-- A gradient over the fill: the group's own, else the interface gradient on housings.
	local gradient = look and look.gradient
	if not gradient and housing then
		local colors = UI.db and UI.db.colors
		local shared = type(colors) == 'table' and colors.gradient and colors.gradientColors
		if type(shared) == 'table' and type(shared.from) == 'table' and type(shared.to) == 'table' then gradient = shared end
	end
	local refitTint = false
	if gradient then
		Wash(shell, gradient, alpha)
		if shell.tint2 and shell.tint2.refit then shell.tint2.refit, refitTint = nil, true end
	else
		shell.tint:Hide()
		if shell.tint2 then shell.tint2:Hide() end
	end
	local refitMaterial = PaintMaterial(shell, look, alpha)
	if surface.recessed then
		-- Sunk into the panel: dark under the top edge, a white catch-light at the foot.
		shell.lit:SetColorTexture(0, 0, 0, surface.lit * alpha)
		shell.shade:SetColorTexture(1, 1, 1, surface.shade * alpha)
	else
		shell.lit:SetColorTexture(1, 1, 1, surface.lit * alpha)
		shell.shade:SetColorTexture(0, 0, 0, surface.shade * alpha)
	end
	local wallShown = shell.wall and surface.wall and true or false
	if shell.wall then
		if wallShown then self:Tint(shell.wall, surface.wall, alpha) end
		shell.wall:SetShown(wallShown)
	end
	local refit = shell.wallShown ~= wallShown or shell.warm ~= (surface.warm or nil) or refitTint or refitMaterial
	shell.wallShown, shell.warm = wallShown, surface.warm or nil
	if shell.shadow then
		local opacity = min((opts.shadowAlpha or 0.35) * (self:Look('shadowOpacity') or 1), 1) * alpha
		if surface.warm then
			-- Tinted with the panel's warm hue, not black, so it doesn't gray the page.
			local r, g, b = self:RGB('shadowTint')
			shell.shadow:SetVertexColor(r, g, b, min(opacity * 1.15, 1))
		else
			shell.shadow:SetVertexColor(0, 0, 0, opacity)
		end
		shell.shadow:SetShown((self:Look('shadowSize') or 1) > 0)
	end
	if refit and shell.fitted then self:FitShell(shell) end
end

-- opts: surface ('paper' | 'dark' | 'lcd' | 'glass' | 'screen'), radius (physical px), alpha,
--       fill / edge (token overrides), shadow (false to omit), shadowAlpha,
--       wall (true: a device's molded side wall, shown on paper housings),
--       group ('console' | 'unitframes' | 'devices' | 'screens': whose color,
--       gradient and material it wears; by default 'devices' for housings and
--       'screens' for screens and LCDs).
function Kit:Shell(owner, opts)
	opts = opts or {}
	local shell = CreateFrame('Frame', nil, owner)
	shell:SetAllPoints()
	-- Just below its owner, so anything the owner draws is always above it.
	shell:SetFrameLevel(max(owner:GetFrameLevel() - 1, 0))
	shell:EnableMouse(false)
	shell.owner, shell.opts = owner, opts
	if opts.shadow ~= false then shell.shadow = SlicedTexture(shell, 'shell-shadow', 'BACKGROUND', -8, SHADOW_SLICE) end
	-- The molded side wall: the housing's own shape, a few pixels lower, in the wall color.
	if opts.wall then shell.wall = SlicedTexture(shell, 'shell', 'BACKGROUND', -7, SHELL_SLICE) end
	shell.edge = SlicedTexture(shell, 'shell', 'BACKGROUND', -6, SHELL_SLICE)
	shell.fill = SlicedTexture(shell, 'shell', 'BACKGROUND', -5, SHELL_SLICE)
	-- The interface gradient (Theme → Colors), over the fill, in the fill's shape.
	shell.tint = SlicedTexture(shell, 'shell', 'BACKGROUND', -4, SHELL_SLICE)
	shell.tint:Hide()
	shell.lit = shell:CreateTexture(nil, 'BACKGROUND', nil, -3)
	shell.shade = shell:CreateTexture(nil, 'BACKGROUND', nil, -3)
	shells[shell] = true
	owner:HookScript('OnSizeChanged', function() Kit:FitShell(shell) end)
	self:PaintShell(shell)
	self:FitShell(shell)
	shell.fitted = true
	return shell
end

function Kit:SetSurface(shell, surface)
	shell.opts.surface = surface
	shell.opts.fill, shell.opts.edge = nil, nil
	self:PaintShell(shell)
end

-- Repaint every shell when the finish or opacity changes, and refit them when
-- the UI scale or resolution does.
listeners[#listeners + 1] = function()
	for shell in pairs(shells) do Kit:PaintShell(shell) end
end
function Kit:RefitShells()
	for shell in pairs(shells) do self:FitShell(shell) end
end

-- Devices ------------------------------------------------------------------
-- Every part of the UI is built as one of the reference's devices (its "MP-1
-- PLAYER", "TM-1 TIMER"): a housing with a printed header (status lamp, bold
-- model code, dim name) holding displays, LCDs, keys and meters.
-- opts: model ('UF-1'), title ('Player'), surface ('paper' | 'dark' | 'lcd'), radius,
--       name, frameType, template, width, height, header (false hides it),
--       group (the housing group whose color and material it wears; see Kit:Shell)
Kit.INK = {paper = {'ink', 'dim'}, dark = {'darkInk', 'darkDim'}, lcd = {'lcdInk', 'lcdDim'}, glass = {'darkInk', 'darkDim'}}

function Kit:Device(parent, opts)
	opts = opts or {}
	local device = CreateFrame(opts.frameType or 'Frame', opts.name, parent, opts.template)
	device:SetSize(opts.width or 200, opts.height or 100)
	device.surface = opts.surface or 'paper'
	device.shell = self:Shell(device, {surface = device.surface, radius = opts.radius or opts.corner or 10, wall = opts.wall ~= false,
		group = opts.group})
	device.housing = device.shell
	if self.devices then self.devices[device] = true end
	local ink = self.INK[device.surface] or self.INK.paper
	if opts.header ~= false then
		device.lamp = self:Led(device, 5, false)
		device.lamp:SetPoint('TOPLEFT', 10, -9)
		device.model = self:Label(device, opts.model or '', ink[1], 8, true)
		device.model:SetPoint('LEFT', device.lamp, 'RIGHT', 5, 0)
		device.title = self:Label(device, opts.title or '', ink[2], 8)
		device.title:SetPoint('LEFT', device.model, 'RIGHT', 5, 0)
		device.title:SetPoint('RIGHT', device, 'TOPRIGHT', -10, -11.5)
		device.title:SetJustifyH('LEFT')
		device.title:SetWordWrap(false)
		-- The header's print follows the housing's color (see PaintShell).
		device.kitHeader = true
		self:PaintShell(device.shell)
	end
	return device
end

-- A black display set in its bezel. The returned frame's .screen is the glass.
function Kit:Screen(parent, opts)
	opts = opts or {}
	local frame = CreateFrame(opts.frameType or 'Frame', opts.name, parent)
	local radius = opts.radius or opts.corner or 6
	frame.bezel = self:Shell(frame, {surface = 'glass', radius = radius, shadow = opts.shadow})
	frame.screen = CreateFrame('Frame', nil, frame)
	local inset = opts.inset or 3
	frame.screen:SetPoint('TOPLEFT', inset, -inset)
	frame.screen:SetPoint('BOTTOMRIGHT', -inset, inset)
	frame.screen.glass = self:Shell(frame.screen, {surface = 'screen', radius = max(radius - 2, 2), shadow = false})
	frame:HookScript('OnShow', function(self) if Kit.PowerOn then Kit:PowerOn(self.screen) end end)
	return frame
end

-- After moving a device or display to another frame level, bring its shells along.
function Kit:Relevel(frame)
	local level = frame:GetFrameLevel()
	local shell = frame.shell or frame.bezel
	if shell then shell:SetFrameLevel(max(level - 1, 0)) end
	if frame.bezel and frame.screen then
		frame.screen:SetFrameLevel(level + 1)
		if frame.screen.glass then frame.screen.glass:SetFrameLevel(level) end
	end
end

-- A gray LCD panel, as on the reference's readouts.
function Kit:LCDPanel(parent, opts)
	opts = opts or {}
	local frame = CreateFrame('Frame', nil, parent)
	frame.shell = self:Shell(frame, {surface = 'lcd', radius = opts.radius or 4, shadow = false})
	-- The glass sits slightly below the face: a soft shade under its top edge.
	frame.inner = frame:CreateTexture(nil, 'BACKGROUND', nil, -4)
	frame.inner:SetPoint('TOPLEFT', 2, -1)
	frame.inner:SetPoint('TOPRIGHT', -2, -1)
	frame.inner:SetHeight(3)
	frame.inner:SetColorTexture(1, 1, 1, 1)
	frame.inner:SetGradient('VERTICAL', CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0.16))
	return frame
end

function Kit:Led(parent, size, on)
	local led = self:Texture(parent, 'circle', 'OVERLAY', 2)
	led:SetSize(size or 5, size or 5)
	-- The lit lamp with its glow, as captured; shown only for the key color.
	led.glow = parent:CreateTexture(nil, 'OVERLAY', nil, 3)
	led.glow.kitOwner = led
	self:SetSprite(led.glow, 'led')
	self:FitSprite(led.glow, size or 5, size or 5)
	self:SetLed(led, on)
	return led
end

Kit.leds = setmetatable({}, {__mode = 'k'})
function Kit:SetLed(led, on, token)
	led.on = on and true or false
	self:Tint(led, on and (token or 'lamp') or 'ledOff')
	if led.glow then led.glow:SetShown(led.on and not token and led:IsShown()) end
	-- Living lamps (an extra): a lit lamp breathes slowly.
	if self.Breathe then
		self.leds[led] = true
		local breathe = led.on and self:Alive('livingLamps')
		local key = self.MotionTag('breathe', led)
		if breathe and not self:Looping(key) then
			self:Breathe(led, true, {period = 2.4, low = 1 - 0.4 * min(1.5, self:Intensity())})
		elseif not breathe and self:Looping(key) then
			self:Breathe(led, false)
		end
	end
end

-- Show or hide a lamp together with its glow.
function Kit:ShowLed(led, shown)
	led:SetShown(shown)
	if led.glow then led.glow:SetShown(shown and led.on and true or false) end
end

-- opts: sprite (a Kit.skin name; false for flat art), radius (3, 6 or 10), fill, border (false to omit),
--       shadow, name, frameType, template. Panels, dark glass and LCD glass use the baked art by default.
local PANEL_SPRITES = {panel = 'module', glass = 'glass', lcd = 'lcd'}
function Kit:Panel(parent, opts)
	opts = opts or {}
	local radius = opts.radius or 10
	local frame = CreateFrame(opts.frameType or 'Frame', opts.name, parent, opts.template)
	local sprite = opts.sprite
	if sprite == nil then sprite = PANEL_SPRITES[opts.fill or 'panel'] end
	if sprite then
		frame.skin = self:Skin(frame, sprite)
		return frame
	end
	if opts.shadow then
		frame.shadow = self:Texture(frame, 'shadow', 'BACKGROUND', -8)
		self:Place(frame.shadow, frame, 8, 5, 8, 11)
		frame.shadow:SetAlpha(opts.shadow == true and 0.5 or opts.shadow)
	end
	frame.fill = self:Texture(frame, 'round-'..radius, 'BACKGROUND', -6)
	frame.fill:SetAllPoints()
	self:Tint(frame.fill, opts.fill or 'panel')
	if opts.border ~= false then
		frame.ring = self:Texture(frame, 'ring-'..radius, 'BACKGROUND', -4)
		frame.ring:SetAllPoints()
		self:Tint(frame.ring, opts.border or 'hair')
	end
	return frame
end

-- A recessed track ('well', 'track') or dark glass ('glass'), from the baked art.
function Kit:Well(parent, _, token, frameType)
	local frame = CreateFrame(frameType or 'Frame', nil, parent)
	frame.skin = self:Skin(frame, token == 'glass' and 'glass' or 'well')
	return frame
end

function Kit:Grain(frame, alpha, inset)
	local texture = frame:CreateTexture(nil, 'BACKGROUND', nil, -5)
	texture:SetTexture(self.media..'grain.tga', 'REPEAT', 'REPEAT')
	texture:SetHorizTile(true); texture:SetVertTile(true)
	texture:SetPoint('TOPLEFT', inset or 0, -(inset or 0))
	texture:SetPoint('BOTTOMRIGHT', -(inset or 0), inset or 0)
	texture:SetAlpha(alpha or 0.5)
	return texture
end

-- Cursor position inside a frame, measured from its bottom-left corner.
function Kit:Cursor(frame)
	local scale = frame:GetEffectiveScale()
	local x, y = GetCursorPosition()
	return x / scale - (frame:GetLeft() or 0), y / scale - (frame:GetBottom() or 0)
end

function Kit:Drag(frame, onMove, onStart, onStop)
	local function Stop(self)
		if not self.kitDragging then return end
		self.kitDragging = nil
		self:SetScript('OnUpdate', nil)
		if onStop then onStop(self) end
	end
	frame:EnableMouse(true)
	frame:SetScript('OnMouseDown', function(self, button)
		if button ~= 'LeftButton' or self.kitDisabled then return end
		self.kitDragging = true
		if onStart then onStart(self) end
		onMove(self, Kit:Cursor(self))
		self:SetScript('OnUpdate', function(dragged) onMove(dragged, Kit:Cursor(dragged)) end)
	end)
	frame:SetScript('OnMouseUp', Stop)
	frame:SetScript('OnHide', Stop)
end

function Kit:Clamp(value, low, high) return max(low, min(high, value)) end

function Kit:Snap(value, low, high, step)
	step = step or 1
	return self:Clamp(floor((value - low) / step + 0.5) * step + low, low, high)
end

-- Key: the physical push button every pressable control is built on.
-- opts: width, height, tone ('default' | 'primary' | 'dark'), round, radius, lip,
--       text, icon, iconSize, led, toggle, checked, onClick(key, button), sound, textSize
-- Light, key-color and charcoal keys use the captured up and down art; a
-- charcoal toggle stays down while it is on, as the reference's keycaps do.
local TONES = {
	default = {fill = 'key', ring = 'keyEdge', lip = 'keyLip', ink = 'ink', up = 'key', down = 'key-down'},
	primary = {fill = 'accent', ring = 'accent', lip = 'accentLip', ink = 'onAccent', up = 'key-primary', down = 'key-primary-down'},
	dark = {fill = 'dark', ring = 'darkEdge', lip = 'darkLip', ink = 'darkInk', up = 'cap', down = 'cap-in'},
	round = {ink = 'ink', up = 'key-round', down = 'key-round-down'},
}

local function PlaceFace(key, offset)
	key.face:ClearAllPoints()
	key.face:SetPoint('TOPLEFT', key, 'TOPLEFT', 0, -offset)
	key.face:SetPoint('BOTTOMRIGHT', key, 'BOTTOMRIGHT', 0, (key.skin and 0 or key.lipSize) - offset)
end

local function KeyPaint(key)
	local down = key.kitDown or (key.kitLatch and key.checked) or false
	-- Down by the key's travel; hovered keys (the Hover lift extra) rise a little.
	local offset = (down and key.travel or 0) - (not down and key.kitLift or 0)
	local from = key.kitOffset or offset
	key.kitOffset = offset
	-- The reference's key travel: 90 ms on its --lift curve.
	local timed = from ~= offset and Kit.Faithful and Kit:Faithful('transitions')
	Kit:Animate(key.face, timed and 0.09 or 0, timed and from or offset, offset, function(value) PlaceFace(key, value) end, nil, 'lift')
	if key.skin then
		local colors = key.kitColors
		local name = down and colors.down or colors.up
		if key.skin.kitSprite ~= name then Kit:SetSprite(key.skin, name) end
	end
end

local function KeySetPressed(key, pressed)
	key.kitDown = pressed and true or false
	KeyPaint(key)
end

local function KeySetTone(key, tone)
	local colors = (key.kitRound and tone ~= 'dark' and TONES.round) or TONES[tone] or TONES.default
	key.tone, key.kitColors = tone, colors
	if key.skin then
		Kit:SetSprite(key.skin, colors.up)
		Kit:FitSprite(key.skin, key:GetWidth(), key:GetHeight())
		KeyPaint(key)
	else
		Kit:Tint(key.face.fill, colors.fill)
		Kit:Tint(key.face.ring, colors.ring)
		Kit:Tint(key.lip, colors.lip)
	end
	if key.text then Kit:Tint(key.text, colors.ink) end
	if key.icon then Kit:Tint(key.icon, colors.ink) end
	if Kit.Alive and (tone == 'primary' or key.kitShimmered) then
		key.kitShimmered = true
		Kit:KeyShimmer(key)
	end
end

local function KeySetChecked(key, checked)
	key.checked = checked and true or false
	if key.led then Kit:SetLed(key.led, key.checked) end
	KeyPaint(key)
end

local function KeySetText(key, text)
	if key.text then key.text:SetText(text and strupper(text) or '') end
end

local function KeySetEnabled(key, enabled)
	key.kitDisabled = not enabled
	key:SetAlpha(enabled and 1 or 0.45)
	if not enabled then KeySetPressed(key, false) end
end

-- Every key, so the Motion page can re-apply its extras (primary key shimmer).
Kit.keys = setmetatable({}, {__mode = 'k'})

-- The idle shimmer (an extra) runs on primary keys.
function Kit:KeyShimmer(key)
	if not self.Shimmer then return end
	self:Shimmer(key, key.tone == 'primary' and self:Alive('shimmer'), {gap = 4.4})
end

function Kit:Key(parent, opts)
	opts = opts or {}
	local tone = opts.tone or 'default'
	local baked = not (opts.round and tone == 'dark') -- the reference has no round charcoal key
	local lip = baked and 0 or (opts.lip or 2)
	local key = CreateFrame('Button', nil, parent)
	key:SetSize(opts.width or 64, (opts.height or 32) + lip)
	key.lipSize, key.opts, key.kitRound = lip, opts, opts.round
	key.travel = baked and 2 or lip
	key.kitLatch = opts.toggle and tone == 'dark'
	key.face = CreateFrame('Frame', nil, key)
	if baked then
		key.skin = self:Skin(key, (opts.round and TONES.round or TONES[tone] or TONES.default).up)
	else
		local shape, ringShape = 'circle', 'circle-ring'
		key.lip = self:Texture(key, shape, 'BACKGROUND', 0)
		self:Place(key.lip, key, 0, -lip, 0, 0)
		key.face.fill = self:Texture(key.face, shape, 'BORDER', 0)
		key.face.fill:SetAllPoints()
		key.face.ring = self:Texture(key.face, ringShape, 'BORDER', 1)
		key.face.ring:SetAllPoints()
	end
	if opts.icon then
		key.icon = self:Icon(key.face, opts.icon, opts.iconSize or 14)
		if opts.text then key.icon:SetPoint('LEFT', 10, 0) else key.icon:SetPoint('CENTER') end
	end
	if opts.text then
		key.text = self:Label(key.face, opts.text, nil, opts.textSize)
		if opts.icon then key.text:SetPoint('LEFT', key.icon, 'RIGHT', 6, 0) else key.text:SetPoint('CENTER') end
	end
	if opts.led or opts.toggle then
		key.led = self:Led(key.face, 5)
		key.led:SetPoint('TOPLEFT', 8, -8)
	end
	key.SetPressed, key.SetTone, key.SetChecked = KeySetPressed, KeySetTone, KeySetChecked
	key.SetKeyText, key.SetKeyEnabled = KeySetText, KeySetEnabled
	KeySetTone(key, tone)
	KeySetChecked(key, opts.checked)
	key:SetScript('OnMouseDown', function(self, button)
		if self.kitDisabled or button ~= 'LeftButton' then return end
		KeySetPressed(self, true)
		if opts.sound ~= false then
			-- As in the reference: a latch catches going down, and is only a light push coming up.
			if opts.toggle then Kit:Play(self.checked and 'up' or 'latch-down')
			else Kit:Play(opts.sound or (self.tone == 'primary' and 'down-primary' or 'down')) end
		end
	end)
	key:SetScript('OnMouseUp', function(self, button)
		if self.kitDisabled or button ~= 'LeftButton' then return end
		KeySetPressed(self, false)
		if opts.sound ~= false and not opts.toggle then Kit:Play('up') end
	end)
	-- Motion extras: hover lift with a soft lamp glow, and a flash on press.
	key:HookScript('OnEnter', function(self)
		if self.kitDisabled or not (Kit.Alive and Kit:Alive('hoverLift')) then return end
		self.kitLift = Kit:Intensity()
		if not self.kitGlow then
			self.kitGlow = Kit:Texture(self, 'glow', 'BACKGROUND', -1)
			self.kitGlow:SetAlpha(0)
			self.kitGlow:SetPoint('TOPLEFT', -8, 8)
			self.kitGlow:SetPoint('BOTTOMRIGHT', 8, -8)
		end
		Kit:Tint(self.kitGlow, 'lamp')
		Kit:FadeTo(self.kitGlow, 0.22 * min(1.5, Kit:Intensity()), 'FAST')
		KeyPaint(self)
	end)
	key:HookScript('OnLeave', function(self)
		if not self.kitLift and not self.kitGlow then return end
		self.kitLift = nil
		if self.kitGlow then Kit:FadeTo(self.kitGlow, 0, 'FAST') end
		KeyPaint(self)
	end)
	key:HookScript('OnMouseDown', function(self, button)
		if self.kitDisabled or button ~= 'LeftButton' or not Kit.MotionNotify then return end
		Kit:MotionNotify('press', self.face)
	end)
	Kit.keys[key] = true
	key:SetScript('OnHide', function(self) KeySetPressed(self, false) end)
	key:SetScript('OnClick', function(self, button)
		if self.kitDisabled then return end
		if opts.toggle then
			local wasOn = self.checked
			KeySetChecked(self, not self.checked)
			if wasOn and opts.sound ~= false then Kit:Play('latch-up') end
		end
		if self.onClick then self.onClick(self, button) end
	end)
	key.onClick = opts.onClick
	return key
end
