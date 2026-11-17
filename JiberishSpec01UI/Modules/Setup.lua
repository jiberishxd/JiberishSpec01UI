-- The installer: an IN-1 device that walks a new player through the whole
-- interface, one part per step, the way ElvUI-style installers do. Every
-- choice is a card with a small live mock of what you'd get; picking one writes
-- the real setting at once (and repaints whatever can repaint live), and
-- choices that only take effect after a reload are collected and marked on the
-- finish step, which reloads into the finished interface.
--
-- It is also a showcase of SPEC-01's motion and sound: the device rises in and
-- its screens power on, the header and titles type on, the step lamps light in
-- turn, steps slide on a detent, cards press and latch, mocks animate when
-- chosen, primary keys shimmer, and the finish prints its summary line by line.
-- With reduced motion every state still changes, without movement.
--
-- It opens by itself on the first login (never in combat; a fight starting
-- collapses it to a pill until the fight ends), and again from /spec setup or
-- the hub's Setup page. Whether it has run is account-wide (UI:Account).
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown = CreateFrame, UIParent, InCombatLockdown
local floor, max, min, sin, pi = math.floor, math.max, math.min, math.sin, math.pi

local function Done() return UI:Account('setup').done end
local function Reduced() return Kit:Reduced() end
local function Read(path) return UI.ReadOption(path) end
local function IsSecret(value) return issecretvalue and issecretvalue(value) end

local guide, pill
local WIDTH, HEIGHT = 820, 568
local CONTENT_W, CONTENT_H = 780, 372
local pending = {} -- setting path -> true: changed here, takes effect after a reload

-- Writing settings ---------------------------------------------------------------------
-- A path whose parent table is missing (a module not loaded) is skipped.
local function Set(path, value, reload)
	local node = UI.db
	local keys = {strsplit('.', path)}
	for index = 1, #keys - 1 do
		node = type(node) == 'table' and node[keys[index]] or nil
	end
	if type(node) ~= 'table' then return end
	if node[keys[#keys]] == value then return end
	UI:Safe(Kit.SetOption, Kit, path, value)
	if reload then
		pending[path] = true
		UI:NeedsReload()
	end
end

local function Loaded(name)
	local loaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
	return loaded and loaded(name) and true or false
end

-- Motion helpers -----------------------------------------------------------------------
local tags = setmetatable({}, {__mode = 'k'})
local function Tag(kind, frame)
	local list = tags[frame]
	if not list then list = {}; tags[frame] = list end
	list[kind] = list[kind] or {}
	return list[kind]
end

-- Type a string on (LCDs and titles); instant with reduced motion.
local function TypeOn(fontString, text, delay)
	fontString:SetText(text)
	Kit:Print(fontString, {force = true, duration = 0.3, steps = 16, delay = delay})
end

-- A screen powering on: a short flicker.
local FLICKER = {0, 0.7, 0.15, 0.85, 0.4, 1}
local function PowerOn(frame, delay)
	if Reduced() then frame:SetAlpha(1) return end
	frame:SetAlpha(0)
	C_Timer.After(delay or 0, function()
		Kit:Animate(Tag('power', frame), 0.28, 0, 1, function(_, progress)
			frame:SetAlpha(FLICKER[min(#FLICKER, floor(progress * #FLICKER) + 1)])
		end, function() frame:SetAlpha(1) end, 'linear')
	end)
end

-- A refusal: the error sound and a short shake of the device.
local function Shake(frame)
	Kit:Play('error', true)
	if Reduced() or not frame then return end
	local point, relative, relativePoint, x, y = frame:GetPoint(1)
	if not point then return end
	Kit:Animate(Tag('shake', frame), 0.36, 0, 1, function(_, progress)
		frame:ClearAllPoints()
		frame:SetPoint(point, relative, relativePoint, x + sin(progress * pi * 6) * 6 * (1 - progress), y)
	end, function()
		frame:ClearAllPoints()
		frame:SetPoint(point, relative, relativePoint, x, y)
	end, 'linear')
end

-- A meter fill that glides to `fraction` of its track.
local function Glide(fill, width, fraction, delay)
	if Reduced() then fill:SetWidth(max(1, width * fraction)) return end
	fill:SetWidth(1)
	C_Timer.After(delay or 0, function()
		Kit:Animate(Tag('glide', fill), 0.45, 0, fraction, function(value) fill:SetWidth(max(1, width * value)) end, nil, 'settle')
	end)
end

-- Mock parts -----------------------------------------------------------------------------
-- Small drawings built from kit parts; each returns what its card animates.
local M = {}

function M.Box(parent, w, h, surface, radius)
	local box = CreateFrame('Frame', nil, parent)
	box:SetSize(w, h)
	box.shell = Kit:Shell(box, {surface = surface or 'paper', radius = radius or 4, shadow = false})
	return box
end

-- A meter: a black track and a lit fill; returns the track with :Play().
function M.Meter(parent, w, h, fraction, token)
	local track = M.Box(parent, w, h, 'screen', 2)
	local fill = track:CreateTexture(nil, 'ARTWORK')
	fill:SetPoint('TOPLEFT', 1, -1)
	fill:SetPoint('BOTTOMLEFT', 1, 1)
	fill:SetColorTexture(1, 1, 1, 1)
	Kit:Tint(fill, token or 'lamp')
	fill:SetWidth(max(1, (w - 2) * fraction))
	function track:Play(delay) Glide(fill, w - 2, fraction, delay) end
	return track
end

function M.Text(parent, text, size, token, bold)
	return Kit:Text(parent, text, size, token or 'ink', bold)
end

-- A tiny LCD readout with ghost digits.
function M.LCD(parent, w, h, text, size)
	local lcd = Kit:LCDPanel(parent, {radius = 2})
	lcd:SetSize(w, h)
	local ghost = Kit:Text(lcd, string.rep('8', #text), size or 9, 'lcdGhost', true)
	ghost:SetPoint('RIGHT', -3, 0)
	lcd.digits = Kit:Text(lcd, text, size or 9, 'lcdInk', true)
	lcd.digits:SetPoint('RIGHT', -3, 0)
	function lcd:Play(delay) TypeOn(self.digits, text, delay) end
	return lcd
end

-- Unit frame shapes, each about 124 x 46.
local SHAPE_MOCKS = {}
function SHAPE_MOCKS.device(stage)
	local frame = M.Box(stage, 124, 44, 'paper', 5)
	local portrait = M.Box(frame, 24, 24, 'screen', 3)
	portrait:SetPoint('BOTTOMLEFT', 4, 5)
	M.Text(frame, 'UF-1', 6, 'ink', true):SetPoint('TOPLEFT', 5, -4)
	local lcd = M.LCD(frame, 88, 12, '72', 8)
	lcd:SetPoint('TOPLEFT', portrait, 'TOPRIGHT', 4, 0)
	local meter = M.Meter(frame, 88, 7, 0.72)
	meter:SetPoint('TOPLEFT', lcd, 'BOTTOMLEFT', 0, -3)
	return frame, function() lcd:Play(); meter:Play(0.05) end
end
function SHAPE_MOCKS.bar(stage)
	local frame = M.Box(stage, 124, 22, 'paper', 4)
	local meter = M.Meter(frame, 118, 16, 0.72)
	meter:SetPoint('CENTER')
	M.Text(meter, 'PLAYER', 7, 'white', true):SetPoint('LEFT', 4, 0)
	return frame, function() meter:Play() end
end
function SHAPE_MOCKS.square(stage)
	local frame = M.Box(stage, 46, 46, 'paper', 5)
	local lcd = M.LCD(frame, 38, 22, '72', 14)
	lcd:SetPoint('TOP', 0, -5)
	local meter = M.Meter(frame, 38, 6, 0.72)
	meter:SetPoint('TOP', lcd, 'BOTTOM', 0, -4)
	return frame, function() lcd:Play(); meter:Play(0.05) end
end
function SHAPE_MOCKS.slim(stage)
	local frame = CreateFrame('Frame', nil, stage)
	frame:SetSize(124, 20)
	M.Text(frame, 'PLAYER', 7, 'ink', true):SetPoint('TOPLEFT')
	M.Text(frame, '72', 7, 'ink', true):SetPoint('TOPRIGHT')
	local meter = M.Meter(frame, 124, 5, 0.72)
	meter:SetPoint('BOTTOMLEFT')
	return frame, function() meter:Play() end
end
function SHAPE_MOCKS.lcdstrip(stage)
	local frame = M.Box(stage, 124, 26, 'lcd', 4)
	M.Text(frame, 'PLAYER', 7, 'lcdInk', true):SetPoint('TOPLEFT', 5, -4)
	local digits = M.Text(frame, '72', 8, 'lcdInk', true)
	digits:SetPoint('TOPRIGHT', -5, -3)
	local meter = M.Meter(frame, 114, 5, 0.72)
	meter:SetPoint('BOTTOMLEFT', 5, 4)
	return frame, function() TypeOn(digits, '72'); meter:Play(0.05) end
end
function SHAPE_MOCKS.console(stage)
	local frame = M.Box(stage, 124, 40, 'paper', 5)
	local lcd = M.LCD(frame, 36, 24, '72', 13)
	lcd:SetPoint('LEFT', 4, 2)
	local meter = M.Meter(frame, 76, 7, 0.72)
	meter:SetPoint('TOPLEFT', lcd, 'TOPRIGHT', 4, -2)
	local power = M.Meter(frame, 76, 5, 0.5, 'blue')
	power:SetPoint('TOPLEFT', meter, 'BOTTOMLEFT', 0, -3)
	local lamps = {}
	for index = 1, 5 do
		local lamp = Kit:Led(frame, 3, index < 3)
		lamp:SetPoint('BOTTOMLEFT', 44 + (index - 1) * 7, 4)
		lamps[index] = lamp
	end
	return frame, function()
		lcd:Play(); meter:Play(0.05); power:Play(0.1)
		if not Reduced() then Kit:Blink(lamps[1], 0.3, true); C_Timer.After(0.9, function() Kit:Blink(lamps[1], nil, false) end) end
	end
end
function SHAPE_MOCKS.gauge(stage)
	local frame = M.Box(stage, 124, 44, 'paper', 5)
	local dial = CreateFrame('Frame', nil, frame)
	dial:SetSize(36, 36)
	dial:SetPoint('LEFT', 4, 0)
	local bezel = Kit:Texture(dial, 'circle', 'ARTWORK')
	bezel:SetAllPoints()
	Kit:Tint(bezel, 'screenFill')
	local ring = Kit:Texture(dial, 'circle-ring', 'OVERLAY')
	ring:SetAllPoints()
	Kit:Tint(ring, 'lamp')
	local digits = M.Text(dial, '72', 9, 'lcdInk', true)
	digits:SetPoint('CENTER')
	local meter = M.Meter(frame, 76, 7, 0.72)
	meter:SetPoint('LEFT', dial, 'RIGHT', 4, 0)
	return frame, function() TypeOn(digits, '72'); meter:Play(0.05) end
end
function SHAPE_MOCKS.tape(stage)
	local frame = M.Box(stage, 124, 34, 'paper', 5)
	M.Text(frame, 'PLAYER', 6, 'ink', true):SetPoint('TOPLEFT', 5, -4)
	local meter = M.Meter(frame, 114, 8, 0.72)
	meter:SetPoint('TOPLEFT', 5, -13)
	for index = 0, 20 do
		local tick = Kit:Solid(frame, 'ink', 'ARTWORK')
		tick:SetSize(1, index % 5 == 0 and 4 or 2)
		tick:SetPoint('TOPLEFT', meter, 'BOTTOMLEFT', floor(index * 113 / 20), -2)
	end
	return frame, function() meter:Play() end
end
function SHAPE_MOCKS.printed(stage)
	local frame = M.Box(stage, 124, 38, 'paper', 5)
	M.Text(frame, 'PLAYER', 7, 'ink', true):SetPoint('TOPLEFT', 5, -4)
	local rule = Kit:Solid(frame, 'rule', 'ARTWORK')
	rule:SetHeight(1)
	rule:SetPoint('TOPLEFT', 5, -13)
	rule:SetPoint('TOPRIGHT', -5, -13)
	M.Text(frame, 'HP', 6, 'dim', true):SetPoint('TOPLEFT', 5, -17)
	local meter = M.Meter(frame, 96, 5, 0.72)
	meter:SetPoint('TOPLEFT', 22, -18)
	M.Text(frame, 'PWR', 6, 'dim', true):SetPoint('TOPLEFT', 5, -27)
	local power = M.Meter(frame, 96, 4, 0.5, 'blue')
	power:SetPoint('TOPLEFT', 22, -28)
	return frame, function() meter:Play(); power:Play(0.08) end
end

-- Portraits, each about 40 x 40.
local function PlayerInitials()
	local name = UnitName('player')
	if IsSecret(name) or type(name) ~= 'string' or name == '' then return 'SP' end
	return strupper(name:sub(1, 2))
end

local PORTRAIT_MOCKS = {}
local function RoundMask(parent, texture)
	local mask = parent:CreateMaskTexture()
	mask:SetTexture(Kit.media..'mask-round.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
	mask:SetAllPoints(texture)
	texture:AddMaskTexture(mask)
end
function PORTRAIT_MOCKS.model(stage)
	local screen = M.Box(stage, 38, 38, 'screen', 4)
	local icon = Kit:Icon(screen, 'user', 22, 'darkInk')
	icon:SetPoint('CENTER')
	return screen, function() PowerOn(screen) end
end
function PORTRAIT_MOCKS.texture(stage)
	local screen = M.Box(stage, 38, 38, 'screen', 4)
	local face = screen:CreateTexture(nil, 'ARTWORK')
	face:SetPoint('TOPLEFT', 2, -2)
	face:SetPoint('BOTTOMRIGHT', -2, 2)
	SetPortraitTexture(face, 'player')
	face:SetTexCoord(0.12, 0.88, 0.12, 0.88)
	return screen, function() PowerOn(screen) end
end
function PORTRAIT_MOCKS.class(stage)
	local screen = M.Box(stage, 38, 38, 'screen', 4)
	local icon = screen:CreateTexture(nil, 'ARTWORK')
	icon:SetPoint('TOPLEFT', 3, -3)
	icon:SetPoint('BOTTOMRIGHT', -3, 3)
	local _, class = UnitClass('player')
	local coords = not IsSecret(class) and class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
	if coords then
		icon:SetTexture([[Interface\TargetingFrame\UI-Classes-Circles]])
		icon:SetTexCoord(unpack(coords))
	end
	return screen, function() PowerOn(screen) end
end
function PORTRAIT_MOCKS.matrix(stage)
	local lens = CreateFrame('Frame', nil, stage)
	lens:SetSize(38, 38)
	local disc = Kit:Texture(lens, 'circle', 'BACKGROUND')
	disc:SetAllPoints()
	Kit:Tint(disc, 'screenFill')
	local dots = {}
	-- A fixed, mirrored 7x7 glyph.
	local pattern = {'0011100', '0111110', '1101011', '1111111', '0110110', '0101010', '0011100'}
	for row = 1, 7 do
		for col = 1, 7 do
			local dot = lens:CreateTexture(nil, 'ARTWORK')
			dot:SetSize(3, 3)
			dot:SetPoint('TOPLEFT', 6 + (col - 1) * 4, -6 - (row - 1) * 4)
			local on = pattern[row]:sub(col, col) == '1'
			dot:SetColorTexture(0.96, 0.96, 0.94, on and 1 or 0.08)
			dot.on = on
			dots[#dots + 1] = dot
		end
	end
	return lens, function()
		if Reduced() then return end
		for index, dot in ipairs(dots) do
			if dot.on then
				dot:SetAlpha(0)
				C_Timer.After(index * 0.006, function() dot:SetAlpha(1) end)
			end
		end
	end
end
function PORTRAIT_MOCKS.monogram(stage)
	local lens = CreateFrame('Frame', nil, stage)
	lens:SetSize(38, 38)
	local disc = Kit:Texture(lens, 'circle', 'BACKGROUND')
	disc:SetAllPoints()
	Kit:Tint(disc, 'screenFill')
	local ring = Kit:Texture(lens, 'circle-ring', 'ARTWORK')
	ring:SetAllPoints()
	Kit:Tint(ring, 'lamp')
	local initials = M.Text(lens, PlayerInitials(), 11, 'darkInk', true)
	initials:SetPoint('CENTER')
	return lens, function() TypeOn(initials, PlayerInitials()) end
end
function PORTRAIT_MOCKS.ring(stage)
	local lens = CreateFrame('Frame', nil, stage)
	lens:SetSize(38, 38)
	local face = lens:CreateTexture(nil, 'ARTWORK')
	face:SetPoint('TOPLEFT', 3, -3)
	face:SetPoint('BOTTOMRIGHT', -3, 3)
	SetPortraitTexture(face, 'player')
	RoundMask(lens, face)
	local ring = Kit:Texture(lens, 'circle-ring', 'OVERLAY')
	ring:SetAllPoints()
	Kit:Tint(ring, 'lamp')
	return lens, function() PowerOn(lens) end
end
function PORTRAIT_MOCKS.glyph(stage)
	local lens = CreateFrame('Frame', nil, stage)
	lens:SetSize(38, 38)
	local disc = Kit:Texture(lens, 'circle', 'BACKGROUND')
	disc:SetAllPoints()
	Kit:Tint(disc, 'screenFill')
	local icon = lens:CreateTexture(nil, 'ARTWORK')
	icon:SetPoint('TOPLEFT', 6, -6)
	icon:SetPoint('BOTTOMRIGHT', -6, 6)
	local _, class = UnitClass('player')
	local coords = not IsSecret(class) and class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
	if coords then
		icon:SetTexture([[Interface\TargetingFrame\UI-Classes-Circles]])
		icon:SetTexCoord(unpack(coords))
	end
	return lens, function() PowerOn(lens) end
end
function PORTRAIT_MOCKS.key(stage)
	local cap = M.Box(stage, 38, 38, 'paper', 6)
	local screen = M.Box(cap, 28, 28, 'screen', 3)
	screen:SetPoint('CENTER')
	local face = screen:CreateTexture(nil, 'ARTWORK')
	face:SetPoint('TOPLEFT', 2, -2)
	face:SetPoint('BOTTOMRIGHT', -2, 2)
	SetPortraitTexture(face, 'player')
	face:SetTexCoord(0.12, 0.88, 0.12, 0.88)
	return cap, function() PowerOn(screen) end
end
function PORTRAIT_MOCKS.off(stage)
	local frame = CreateFrame('Frame', nil, stage)
	frame:SetSize(38, 38)
	local label = M.Text(frame, 'NONE', 7, 'dim', true)
	label:SetPoint('CENTER')
	return frame, function() TypeOn(label, 'NONE') end
end

-- The console and free bar layouts.
local function MockKeys(parent, keys, rows, x, y, size, gap)
	local list = {}
	for row = 1, rows do
		for index = 1, keys do
			local key = Kit:Solid(parent, 'key', 'ARTWORK')
			key:SetSize(size, size)
			key:SetPoint('BOTTOMLEFT', x + (index - 1) * (size + gap), y + (row - 1) * (size + gap))
			list[#list + 1] = key
		end
	end
	return list
end
local function PressKeys(keys)
	if Reduced() then return end
	for index, key in ipairs(keys) do
		key:SetAlpha(0.2)
		C_Timer.After(index * 0.012, function() key:SetAlpha(1) end)
	end
end
local BAR_MOCKS = {}
function BAR_MOCKS.console(stage)
	local housing = M.Box(stage, 300, 60, 'paper', 6)
	for side = 1, 2 do
		local unit = M.Box(housing, 48, 32, 'screen', 3)
		unit:SetPoint(side == 1 and 'LEFT' or 'RIGHT', side == 1 and 6 or -6, 0)
	end
	local keys = MockKeys(housing, 12, 3, 60, 6, 13, 2)
	return housing, function() PressKeys(keys) end
end
function BAR_MOCKS.free(stage)
	local frame = CreateFrame('Frame', nil, stage)
	frame:SetSize(300, 60)
	local keys = {}
	for index, spot in ipairs({{0, 0}, {104, 0}, {52, 22}}) do
		local bar = M.Box(frame, 96, 18, 'paper', 4)
		bar:SetPoint('BOTTOMLEFT', spot[1], spot[2])
		for _, key in ipairs(MockKeys(bar, 6, 1, 4, 3, 12, 3)) do keys[#keys + 1] = key end
		if index == 3 then bar:SetFrameLevel(frame:GetFrameLevel() + 2) end
	end
	local side = M.Box(frame, 18, 58, 'paper', 4)
	side:SetPoint('BOTTOMRIGHT')
	return frame, function() PressKeys(keys) end
end

-- Layout presets drawn as screen maps: blocks as fractions {x, y, w, h} from bottom left.
local PRESET_BLOCKS = {
	console = {{0.28, 0.03, 0.44, 0.26}},
	classic = {{0.3, 0.03, 0.4, 0.07}, {0.3, 0.11, 0.4, 0.07}, {0.3, 0.19, 0.4, 0.07}, {0.12, 0.33, 0.16, 0.12}, {0.72, 0.33, 0.16, 0.12}},
	healer = {{0.3, 0.03, 0.4, 0.16}, {0.36, 0.24, 0.28, 0.2}, {0.06, 0.26, 0.16, 0.12}, {0.78, 0.26, 0.16, 0.12}},
	centre = {{0.3, 0.03, 0.4, 0.16}, {0.3, 0.32, 0.16, 0.12}, {0.54, 0.32, 0.16, 0.12}},
	minimal = {{0.3, 0.03, 0.4, 0.08}},
	wide = {{0.3, 0.03, 0.4, 0.2}, {0.14, 0.32, 0.14, 0.11}, {0.72, 0.32, 0.14, 0.11}},
}
local function PresetMock(stage, key)
	local screen = M.Box(stage, 150, 60, 'screen', 3)
	local blocks = {}
	if key == 'wide' or key == 'ultrawide' then
		for _, x in ipairs({0.11, 0.89}) do
			local band = Kit:Solid(screen, 'darkDim', 'ARTWORK', 0, 0.5)
			band:SetSize(1, 56)
			band:SetPoint('BOTTOMLEFT', floor(150 * x), 2)
		end
	end
	-- The layout solver's own map, so the card shows what applying will do.
	local specs = PRESET_BLOCKS[key] or {}
	local solved = UI.LayoutPresetMap and UI:LayoutPresetMap(key)
	if type(solved) == 'table' and #solved > 0 then
		specs = {}
		for _, rect in ipairs(solved) do specs[#specs + 1] = {rect.x, rect.y, rect.w, rect.h} end
	end
	for index, spec in ipairs(specs) do
		local block = Kit:Solid(screen, 'panel', 'ARTWORK', 1, 0.85)
		block:SetSize(max(2, floor(150 * spec[3])), max(2, floor(60 * spec[4])))
		block:SetPoint('BOTTOMLEFT', floor(150 * spec[1]), floor(60 * spec[2]))
		block.spec = spec
		blocks[index] = block
	end
	return screen, function()
		if Reduced() then return end
		for index, block in ipairs(blocks) do
			local spec = block.spec
			Kit:Animate(Tag('rise', block), 0.32 + index * 0.04, 8, 0, function(value)
				block:ClearAllPoints()
				block:SetPoint('BOTTOMLEFT', floor(150 * spec[1]), floor(60 * spec[2] - value))
			end, nil, 'settle')
		end
	end
end

-- Styles of housing.
local function SurfaceMock(stage, surface, lines)
	local box = M.Box(stage, 120, 50, surface, 6)
	local screen = M.Box(box, 104, 30, 'screen', 3)
	screen:SetPoint('BOTTOM', 0, 6)
	local rows = {}
	for index = 1, lines or 3 do
		local row = Kit:Solid(screen, 'darkDim', 'ARTWORK', 0, 0.6)
		row:SetSize(40 + (index * 17) % 50, 2)
		row:SetPoint('TOPLEFT', 6, -6 - (index - 1) * 7)
		rows[index] = row
	end
	return box, function()
		PowerOn(screen)
		for index, row in ipairs(rows) do
			row:SetAlpha(0)
			C_Timer.After(Reduced() and 0 or 0.1 + index * 0.08, function() row:SetAlpha(0.6) end)
		end
	end
end

-- Cards ----------------------------------------------------------------------------------
-- A keycap card: housing with a lamp and title, a stage for its mock and a
-- one-line description. It presses, lifts on hover and latches when chosen.
local function Lift(card, dy)
	card.face:ClearAllPoints()
	card.face:SetPoint('TOPLEFT', 0, dy)
	card.face:SetPoint('BOTTOMRIGHT', 0, dy)
end

local function Card(parent, def, w, h, onPick)
	local card = CreateFrame('Button', nil, parent)
	card:SetSize(w, h)
	card.def = def
	card.glow = Kit:Texture(card, 'glow', 'BACKGROUND', -8)
	card.glow:SetPoint('TOPLEFT', -10, 10)
	card.glow:SetPoint('BOTTOMRIGHT', 10, -10)
	Kit:Tint(card.glow, 'lamp')
	card.glow:SetAlpha(0)
	card.face = CreateFrame('Frame', nil, card)
	Lift(card, 0)
	card.face.shell = Kit:Shell(card.face, {surface = 'paper', radius = 8, shadowAlpha = 0.25})
	card.highlight = card.face:CreateTexture(nil, 'OVERLAY', nil, 6)
	card.highlight:SetPoint('TOPLEFT', 2, -2)
	card.highlight:SetPoint('BOTTOMRIGHT', -2, 2)
	card.highlight:SetColorTexture(1, 1, 1, 1)
	Kit:Tint(card.highlight, 'lamp', 0.12)
	card.highlight:Hide()
	card.led = Kit:Led(card.face, 5, false)
	card.led:SetPoint('TOPLEFT', 8, -8)
	card.title = Kit:Label(card.face, def.title, 'ink', 8, true)
	card.title:SetPoint('LEFT', card.led, 'RIGHT', 5, 0)
	card.title:SetPoint('RIGHT', card.face, 'RIGHT', -6, 0)
	card.title:SetJustifyH('LEFT')
	card.title:SetWordWrap(false)
	local bottom = 6
	if def.sub then
		card.sub = Kit:Text(card.face, def.sub, 8, 'dim')
		card.sub:SetPoint('BOTTOMLEFT', 8, 6)
		card.sub:SetWidth(w - 16)
		card.sub:SetJustifyH('LEFT')
		card.sub:SetWordWrap(false)
		bottom = 18
	end
	card.stage = CreateFrame('Frame', nil, card.face)
	card.stage:SetPoint('TOPLEFT', 6, -20)
	card.stage:SetPoint('BOTTOMRIGHT', -6, bottom)
	if def.mock then
		local ok, frame, animate = pcall(def.mock, card.stage)
		if ok and frame then
			frame:SetPoint('CENTER', card.stage, 'CENTER')
			card.animate = animate
		end
	end
	card:SetScript('OnEnter', function(self)
		Kit:FadeTo(self.glow, 0.22, 'FAST')
		if not Reduced() and not self.down then Lift(self, 1) end
	end)
	card:SetScript('OnLeave', function(self)
		Kit:FadeTo(self.glow, 0, 'FAST')
		if not self.down then Lift(self, 0) end
	end)
	card:SetScript('OnMouseDown', function(self, button)
		if button ~= 'LeftButton' then return end
		self.down = true
		if not Reduced() then Lift(self, -1) end
		Kit:Play('down')
	end)
	card:SetScript('OnMouseUp', function(self, button)
		if button ~= 'LeftButton' then return end
		self.down = nil
		Lift(self, self:IsMouseOver() and not Reduced() and 1 or 0)
		Kit:Play('up')
	end)
	card:SetScript('OnClick', function(self) onPick(self) end)
	return card
end

-- A group of cards bound to one choice. o: {get(), set(value), w, h, cols, gap, x, y}
local function Cards(body, defs, o)
	local group = {cards = {}}
	local cols, gap = o.cols or #defs, o.gap or 10
	for index, def in ipairs(defs) do
		local card = Card(body, def, o.w, o.h, function(card)
			if group.value == card.def.value then
				Kit:Flash(card.face)
				return
			end
			if o.combat and InCombatLockdown() then return Shake(guide) end
			UI:Safe(o.set, card.def.value)
			group:Paint(true)
		end)
		local col, row = (index - 1) % cols, floor((index - 1) / cols)
		card:SetPoint('TOPLEFT', body, 'TOPLEFT', (o.x or 0) + col * (o.w + gap), (o.y or 0) - row * (o.h + gap))
		group.cards[index] = card
	end
	group.height = (floor((#defs - 1) / cols) + 1) * (o.h + gap) - gap
	function group:Paint(animate)
		local value = o.get()
		self.value = value
		for _, card in ipairs(self.cards) do
			local on = card.def.value == value
			Kit:SetLed(card.led, on)
			card.title:SetAlpha(on and 1 or 0.8)
			if on and animate then
				Kit:Play('latch-down')
				Kit:Chosen(card, card.highlight, card.title, nil, 'ink', 'ink')
				if card.animate then UI:Safe(card.animate) end
			end
		end
	end
	return group
end

-- Small controls bound to settings ------------------------------------------------------
local function Caption(body, text, x, y)
	local label = Kit:Label(body, text, 'dim', 8, true)
	label:SetPoint('TOPLEFT', body, 'TOPLEFT', x, y)
	return label
end

-- A segmented picker. items: {{value, text}}; set(value).
local function Picker(body, items, get, set, width)
	local names = {}
	for index, item in ipairs(items) do names[index] = item[2] end
	local control = Kit:Segmented(body, {items = names, width = width or 220, value = 1, onChange = function(index)
		UI:Safe(set, items[index][1])
	end})
	function control:Refresh()
		local value = get()
		for index, item in ipairs(items) do
			if item[1] == value then self:SetValue(index) end
		end
	end
	return control
end

-- A switch row: label and a one-line description beside a SPEC-01 switch.
local function Toggle(body, label, text, get, set, x, y, width)
	local row = CreateFrame('Frame', nil, body)
	row:SetSize(width or 370, 38)
	row:SetPoint('TOPLEFT', body, 'TOPLEFT', x, y)
	row.switch = Kit:Switch(row, {labels = false, checked = get() and true or false, onChange = function(value)
		UI:Safe(set, value)
	end})
	row.switch:SetPoint('LEFT', 0, 0)
	row.label = Kit:Label(row, label, 'ink', 8, true)
	row.label:SetPoint('TOPLEFT', row.switch, 'TOPRIGHT', 10, -2)
	row.text = Kit:Text(row, text or '', 8, 'dim')
	row.text:SetPoint('TOPLEFT', row.label, 'BOTTOMLEFT', 0, -3)
	row.text:SetWidth((width or 370) - 72)
	row.text:SetJustifyH('LEFT')
	row.text:SetWordWrap(false)
	function row:Refresh() self.switch:SetValue(get() and true or false) end
	return row
end

local function Slider(body, label, low, high, step, get, set, format, width)
	local slider = Kit:Slider(body, {label = label, min = low, max = high, step = step, value = get() or low, width = width or 260,
		ticks = floor((high - low) / step + 0.5), format = format, onChange = function(value)
			Kit:Play('tick')
			UI:Safe(set, value)
		end})
	function slider:Refresh() local value = get(); if value then self:SetValue(value) end end
	return slider
end

local function Percent(value) return format('%d%%', value * 100 + 0.5) end
local function Whole(value) return format('%d', value + 0.5) end

-- Shapes and portraits as the unit frames module lists them.
local SHAPES = {{'device', 'Device'}, {'bar', 'Bar'}, {'square', 'Square'}, {'slim', 'Slim'}, {'lcdstrip', 'LCD strip'},
	{'console', 'Console'}, {'gauge', 'Gauge'}, {'tape', 'Tape'}, {'printed', 'Printed'}}
local PORTRAITS = {{'model', '3D'}, {'texture', '2D'}, {'class', 'Class'}, {'matrix', 'LED avatar'}, {'monogram', 'Monogram'},
	{'ring', 'Round'}, {'glyph', 'Class avatar'}, {'key', 'Key avatar'}, {'off', 'None'}}
local SIZES = {{'small', 'Small', 0.85}, {'medium', 'Medium', 1}, {'large', 'Large', 1.15}}

local function Portrait()
	local units = UI.db.unitframes and UI.db.unitframes.units
	local player = units and units.player and units.player.portrait
	if player == 'off' then return 'off' end
	return Read('unitframes.portrait')
end

local function SetPortrait(value)
	local units = UI.db.unitframes and UI.db.unitframes.units
	if value == 'off' then
		for _, key in ipairs({'player', 'target'}) do
			if units and units[key] then Set('unitframes.units.'..key..'.portrait', 'off') end
		end
	else
		for _, key in ipairs({'player', 'target'}) do
			if units and units[key] and units[key].portrait == 'off' then Set('unitframes.units.'..key..'.portrait', 'default') end
		end
		Set('unitframes.portrait', value)
	end
end

local function SizeOf()
	local scale = Read('unitframes.scale') or 1
	local best, gap = 'medium', 9
	for _, size in ipairs(SIZES) do
		if math.abs(size[3] - scale) < gap then best, gap = size[1], math.abs(size[3] - scale) end
	end
	return best
end

local function Name(list, value)
	for _, item in ipairs(list) do if item[1] == value then return item[2] end end
	return tostring(value or '-')
end

-- Steps ------------------------------------------------------------------------------------
-- build(body, step) makes the step once; refresh(step) reads the current
-- settings into it; summary() lists {label, value, paths} for the finish.
local STEPS = {}

STEPS[#STEPS + 1] = {key = 'welcome', title = 'Welcome', short = 'Start',
	text = 'This installer sets up the whole interface in a few minutes: the look, the layout, unit frames, action bars, meters, the minimap, chat and the extras. Every choice applies as you make it and can be changed later with /spec.',
	build = function(body, step)
		local lcd = Kit:LCDPanel(body, {radius = 4})
		lcd:SetSize(360, 96)
		lcd:SetPoint('TOPLEFT', 0, -4)
		local ghost = Kit:Text(lcd, '888-88', 40, 'lcdGhost', true)
		ghost:SetPoint('CENTER')
		step.logo = Kit:Text(lcd, 'SPEC-01', 40, 'lcdInk', true)
		step.logo:SetPoint('CENTER')
		step.lcd = lcd
		step.list = {}
		local parts = {'Look', 'Layout', 'Unit frames', 'Action bars', 'Damage meters', 'Minimap', 'Chat', 'Extras', 'Placement'}
		for index, part in ipairs(parts) do
			local lamp = Kit:Led(body, 5, false)
			lamp:SetPoint('TOPLEFT', body, 'TOPLEFT', 4 + floor((index - 1) / 5) * 180, -122 - ((index - 1) % 5) * 22)
			local label = Kit:Label(body, part, 'ink', 8, true)
			label:SetPoint('LEFT', lamp, 'RIGHT', 8, 0)
			step.list[index] = lamp
		end
		-- The screen: resolution, the current scale and the one recommended.
		local screen = M.Box(body, 380, 230, 'paper', 8)
		screen:SetPoint('TOPRIGHT', 0, -4)
		Kit:Label(screen, 'Screen', 'dim', 8, true):SetPoint('TOPLEFT', 12, -10)
		step.resolution = M.LCD(screen, 356, 30, '0000 x 0000', 16)
		step.resolution:SetPoint('TOPLEFT', 12, -26)
		Kit:Label(screen, 'UI scale now', 'dim', 8, true):SetPoint('TOPLEFT', 12, -70)
		step.scale = M.LCD(screen, 170, 30, '0.000', 16)
		step.scale:SetPoint('TOPLEFT', 12, -84)
		Kit:Label(screen, 'Recommended', 'dim', 8, true):SetPoint('TOPLEFT', 198, -70)
		step.recommended = M.LCD(screen, 170, 30, '0.000', 16)
		step.recommended:SetPoint('TOPLEFT', 198, -84)
		step.note = Kit:Text(screen, '', 8, 'dim')
		step.note:SetPoint('TOPLEFT', 12, -128)
		step.note:SetWidth(356)
		step.note:SetJustifyH('LEFT')
		step.apply = Kit:Key(screen, {width = 150, height = 30, tone = 'primary', text = 'Use recommended'})
		step.apply:SetPoint('BOTTOMLEFT', 12, 12)
		step.apply.onClick = function()
			if InCombatLockdown() then return Shake(guide) end
			Set('uiScale', step.best)
			Kit:Play('success')
			step.paint()
		end
		step.paint = function()
			local width, height = GetPhysicalScreenSize()
			local plain = not (IsSecret(width) or IsSecret(height)) and width and height
			local _, title, scale
			if UI.ScreenLayoutPlan then _, title, scale = UI:ScreenLayoutPlan('auto', 'comfortable') end
			step.best = scale or UI.Pixel.PerfectScale()
			step.resolution.digits:SetText(plain and format('%d x %d', width, height) or '----')
			step.scale.digits:SetText(format('%.3f', UI.db.uiScale or UIParent:GetScale()))
			step.recommended.digits:SetText(format('%.3f', step.best))
			step.note:SetText(format('Detected as %s. The recommended scale keeps the game\'s own art sharp on this screen; pixel perfect is %.3f.',
				title or 'your screen', UI.Pixel.PerfectScale()))
		end
	end,
	refresh = function(step, fresh)
		step.paint()
		if not fresh then return end
		TypeOn(step.logo, 'SPEC-01', 0.15)
		step.resolution:Play(0.2); step.scale:Play(0.3); step.recommended:Play(0.4)
		for index, lamp in ipairs(step.list) do
			Kit:SetLed(lamp, false)
			C_Timer.After(Reduced() and 0 or 0.35 + index * 0.11, function()
				Kit:SetLed(lamp, true)
				if not Reduced() then Kit:Play('blip') end
			end)
		end
	end,
	summary = function()
		return {{'UI scale', format('%.3f', UI.db.uiScale or UIParent:GetScale()), {'uiScale'}}}
	end}

STEPS[#STEPS + 1] = {key = 'look', title = 'Look', short = 'Look',
	text = 'Paper is the reference: off-white housings and black displays. Graphite darkens the same parts. The key color lights lamps, dots and primary keys. All of it repaints as you choose.',
	build = function(body, step)
		Caption(body, 'Finish', 0, 0)
		local function FinishMock(stage, rgb)
			local box = CreateFrame('Frame', nil, stage)
			box:SetSize(150, 56)
			local fill = box:CreateTexture(nil, 'BACKGROUND')
			fill:SetAllPoints()
			fill:SetColorTexture(rgb[1], rgb[2], rgb[3], 1)
			local screen = M.Box(box, 90, 34, 'screen', 3)
			screen:SetPoint('LEFT', 8, 0)
			local key = box:CreateTexture(nil, 'ARTWORK')
			key:SetSize(30, 16)
			key:SetPoint('RIGHT', -10, 0)
			key:SetColorTexture(rgb[1] * 0.85, rgb[2] * 0.85, rgb[3] * 0.85, 1)
			local lamp = Kit:Led(box, 5, true)
			lamp:SetPoint('TOPRIGHT', -8, -6)
			return box, function() PowerOn(screen) end
		end
		step.finish = Cards(body, {
			{value = 'paper', title = 'Paper', sub = 'The reference: light housings.', mock = function(s) return FinishMock(s, {0.93, 0.92, 0.9}) end},
			{value = 'graphite', title = 'Graphite', sub = 'The same parts, dark.', mock = function(s) return FinishMock(s, {0.17, 0.17, 0.16}) end},
		}, {w = 180, h = 104, cols = 2, x = 0, y = -14, get = function() return Read('finish') end,
			set = function(value) Set('finish', value) end})
		Caption(body, 'Key color', 0, -136)
		local swatches = {}
		for _, name in ipairs(Kit.accentOrder) do
			local accent = Kit.accents[name]
			swatches[#swatches + 1] = {value = name, title = accent.name, rgb = {accent[1], accent[2], accent[3]}}
		end
		local _, class = UnitClass('player')
		local classColor = not IsSecret(class) and class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
		swatches[#swatches + 1] = {value = 'class', title = 'Class', rgb = classColor and {classColor.r, classColor.g, classColor.b} or {1, 1, 1}}
		for _, swatch in ipairs(swatches) do
			local rgb = swatch.rgb
			swatch.mock = function(stage)
				local dot = CreateFrame('Frame', nil, stage)
				dot:SetSize(18, 18)
				local disc = Kit:Texture(dot, 'circle', 'ARTWORK')
				disc:SetAllPoints()
				disc:SetVertexColor(rgb[1], rgb[2], rgb[3])
				return dot, function() Kit:Flash(dot, {alpha = 0.4}) end
			end
		end
		step.accent = Cards(body, swatches, {w = 50, h = 56, gap = 4, cols = 7, x = 0, y = -150,
			get = function() return Read('accent') end, set = function(value) Set('accent', value) end})
		-- Typeface and text size.
		Caption(body, 'Typeface', 400, 0)
		local faces = {{'__default', 'IBM Plex Mono', Kit.fonts.bold}, {'__game', 'Game font', STANDARD_TEXT_FONT},
			{'__numbers', 'Game numbers', [[Fonts\ARIALN.TTF]]}}
		local defs = {}
		for index, face in ipairs(faces) do
			defs[index] = {value = face[1], title = face[2], mock = function(stage)
				local frame = CreateFrame('Frame', nil, stage)
				frame:SetSize(110, 30)
				local sample = frame:CreateFontString(nil, 'OVERLAY')
				sample:SetFont(face[3], 16, '')
				sample:SetText('Aa 0123')
				sample:SetPoint('CENTER')
				Kit:Tint(sample, 'ink')
				return frame, function() TypeOn(sample, 'Aa 0123') end
			end}
		end
		step.face = Cards(body, defs, {w = 124, h = 76, gap = 6, cols = 3, x = 400, y = -14,
			get = function() return Read('font') end, set = function(value) Set('font', value) end})
		step.textScale = Slider(body, 'Text size', 0.8, 1.3, 0.05, function() return Read('appearance.textScale') end,
			function(value) Set('appearance.textScale', value) end, Percent, 380)
		step.textScale:SetPoint('TOPLEFT', body, 'TOPLEFT', 400, -120)
		step.sample = Kit:Key(body, {width = 120, height = 30, tone = 'primary', text = 'Engage'})
		step.sample:SetPoint('TOPLEFT', body, 'TOPLEFT', 400, -200)
		local lamp = Kit:Led(body, 7, true)
		lamp:SetPoint('LEFT', step.sample, 'RIGHT', 16, 0)
		step.meter = Kit:Meter(body, {label = 'Level', width = 200, value = 0.62})
		step.meter:SetPoint('LEFT', lamp, 'RIGHT', 16, 4)
	end,
	refresh = function(step)
		step.finish:Paint(); step.accent:Paint(); step.face:Paint(); step.textScale:Refresh()
	end,
	summary = function()
		return {{'Finish', Name({{'paper', 'Paper'}, {'graphite', 'Graphite'}}, Read('finish')), {'finish'}},
			{'Key color', tostring(Read('accent')), {'accent'}},
			{'Typeface', Name({{'__default', 'IBM Plex Mono'}, {'__game', 'Game font'}, {'__numbers', 'Game numbers'}}, Read('font')), {'font'}}}
	end}

STEPS[#STEPS + 1] = {key = 'layout', title = 'Layout', short = 'Layout',
	text = 'Pick an arrangement for the whole screen, then the size class of your screen. Frames move at once; some arrangements also change the bars and finish on reload.',
	build = function(body, step)
		Caption(body, 'Arrangement', 0, 0)
		local defs = {}
		for index, preset in ipairs(UI.LayoutPresets and UI:LayoutPresets() or {}) do
			defs[index] = {value = preset.key, title = preset.title, sub = preset.note, mock = function(stage) return PresetMock(stage, preset.key) end}
		end
		step.preset = Cards(body, defs, {w = 252, h = 112, gap = 12, cols = 3, x = 0, y = -14, combat = true,
			get = function() return UI.db.layout and UI.db.layout.preset end,
			set = function(value)
				UI:ApplyLayoutPreset(value)
				-- A preset can switch the bar layout, which shows on reload.
				if UI.reloadPending then pending['layout.preset'] = true end
			end})
		Caption(body, 'Screen', 0, -268)
		step.size = Picker(body, {{'auto', 'Auto'}, {'1080', '1080p'}, {'1440', '1440p'}, {'2160', '4K'}},
			function() return UI.db.layout.resolution end, function(value) UI.db.layout.resolution = value end, 300)
		step.size:SetPoint('TOPLEFT', body, 'TOPLEFT', 0, -284)
		step.density = Picker(body, {{'compact', 'Compact'}, {'comfortable', 'Comfortable'}},
			function() return UI.db.layout.density end, function(value) UI.db.layout.density = value end, 220)
		step.density:SetPoint('LEFT', step.size, 'RIGHT', 16, 0)
		step.apply = Kit:Key(body, {width = 150, height = 30, text = 'Apply screen'})
		step.apply:SetPoint('LEFT', step.density, 'RIGHT', 16, 0)
		step.apply.onClick = function()
			if InCombatLockdown() then return Shake(guide) end
			UI:ApplyScreenLayout(UI.db.layout.resolution, UI.db.layout.density)
			if UI.reloadPending then pending['actionbars.keySize'] = true end
		end
	end,
	refresh = function(step) step.preset:Paint(); step.size:Refresh(); step.density:Refresh() end,
	summary = function()
		local preset = UI.db.layout and UI.db.layout.preset
		local title = preset
		for _, entry in ipairs(UI.LayoutPresets and UI:LayoutPresets() or {}) do if entry.key == preset then title = entry.title end end
		return {{'Arrangement', tostring(title or '-'), {'layout.preset'}},
			{'Screen', format('%s, %s', tostring(UI.db.layout.resolution), tostring(UI.db.layout.density)), {'actionbars.keySize'}}}
	end}

STEPS[#STEPS + 1] = {key = 'unitframes', title = 'Unit frames', short = 'Units',
	text = 'The player, target and the other frames: their shape, the portrait or avatar, the housing and the size. Shape and portrait change live; the housing and switches apply on reload.',
	build = function(body, step)
		Caption(body, 'Shape', 0, 0)
		local defs = {}
		for index, shape in ipairs(SHAPES) do
			defs[index] = {value = shape[1], title = shape[2], mock = function(stage) return SHAPE_MOCKS[shape[1]](stage) end}
		end
		step.shape = Cards(body, defs, {w = 148, h = 72, gap = 10, cols = 5, x = 0, y = -14,
			get = function() return Read('unitframes.shape') end,
			set = function(value)
				if UI.SetUnitFrameShape then UI:SetUnitFrameShape(value) end
				Kit:Apply()
			end})
		Caption(body, 'Portrait', 0, -184)
		defs = {}
		for index, portrait in ipairs(PORTRAITS) do
			defs[index] = {value = portrait[1], title = portrait[2], mock = function(stage) return PORTRAIT_MOCKS[portrait[1]](stage) end}
		end
		step.portrait = Cards(body, defs, {w = 82, h = 70, gap = 5, cols = 9, x = 0, y = -198, get = Portrait,
			set = function(value) SetPortrait(value); Kit:Apply() end})
		Caption(body, 'Housing', 0, -284)
		step.style = Picker(body, {{'paper', 'Paper'}, {'dark', 'Dark'}, {'lcd', 'LCD'}, {'blizzard', 'Blizzard'}},
			function() return Read('style.unitframes') end, function(value) Set('style.unitframes', value, true) end, 270)
		step.style:SetPoint('TOPLEFT', body, 'TOPLEFT', 0, -300)
		Caption(body, 'Size', 290, -284)
		step.size = Picker(body, {{'small', 'Small'}, {'medium', 'Medium'}, {'large', 'Large'}}, SizeOf, function(value)
			for _, size in ipairs(SIZES) do if size[1] == value then Set('unitframes.scale', size[3]) end end
		end, 210)
		step.size:SetPoint('TOPLEFT', body, 'TOPLEFT', 290, -300)
		step.party = Toggle(body, 'Party frames', 'Applies on reload.', function() return Read('unitframes.party') end,
			function(value) Set('unitframes.party', value, true) end, 520, -284, 130)
		step.cast = Toggle(body, 'Cast bars', 'Applies on reload.', function() return Read('unitframes.castbar') end,
			function(value) Set('unitframes.castbar', value, true) end, 650, -284, 130)
	end,
	refresh = function(step)
		step.shape:Paint(); step.portrait:Paint(); step.style:Refresh(); step.size:Refresh(); step.party:Refresh(); step.cast:Refresh()
	end,
	summary = function()
		return {{'Unit frame shape', Name(SHAPES, Read('unitframes.shape')), {}},
			{'Portrait', Name(PORTRAITS, Portrait()), {}},
			{'Unit frame housing', tostring(Read('style.unitframes')), {'style.unitframes'}},
			{'Unit frame size', Name({{'small', 'Small'}, {'medium', 'Medium'}, {'large', 'Large'}}, SizeOf()), {}},
			{'Party frames', Read('unitframes.party') and 'On' or 'Off', {'unitframes.party'}},
			{'Cast bars', Read('unitframes.castbar') and 'On' or 'Off', {'unitframes.castbar'}}}
	end}

STEPS[#STEPS + 1] = {key = 'actionbars', title = 'Action bars', short = 'Bars',
	text = 'Console puts your keys in one device along the bottom with the player and target docked into it. Free gives each bar a device of its own. Bar changes apply on reload.',
	build = function(body, step)
		Caption(body, 'Layout', 0, 0)
		step.layout = Cards(body, {
			{value = 'console', title = 'Console', sub = 'One device, frames docked.', mock = function(s) return BAR_MOCKS.console(s) end},
			{value = 'free', title = 'Free', sub = 'Every bar its own device.', mock = function(s) return BAR_MOCKS.free(s) end},
		}, {w = 330, h = 118, gap = 12, cols = 2, x = 0, y = -14, get = function() return Read('actionbars.layout') end,
			set = function(value) Set('actionbars.layout', value, true) end})
		Caption(body, 'Keys', 0, -150)
		local function KeyMock(stage, light)
			local key = M.Box(stage, 34, 34, light and 'paper' or 'dark', 6)
			local window = M.Box(key, 24, 18, 'screen', 2)
			window:SetPoint('BOTTOM', 0, 4)
			local lamp = Kit:Led(key, 3, true)
			lamp:SetPoint('TOPRIGHT', -4, -4)
			return key, function() PowerOn(window) end
		end
		step.look = Cards(body, {
			{value = 'hardware', title = 'Hardware', sub = 'Keycaps, slots, legends.', mock = function(s) return KeyMock(s, true) end},
			{value = 'classic', title = 'Classic', sub = 'Icons on dark squares.', mock = function(s) return KeyMock(s, false) end},
		}, {w = 160, h = 90, gap = 10, cols = 2, x = 0, y = -164, get = function() return Read('actionbars.look') end,
			set = function(value) Set('actionbars.look', value, true) end})
		Caption(body, 'Rows', 350, -150)
		step.rows = Picker(body, {{1, '1'}, {2, '2'}, {3, '3'}}, function() return Read('actionbars.rows') end,
			function(value) Set('actionbars.rows', value, true) end, 150)
		step.rows:SetPoint('TOPLEFT', body, 'TOPLEFT', 350, -166)
		-- Key size and console width are apart: with a fixed width, the key size
		-- moves only the keys (made just small enough to fit), and the width only the housing.
		local function ShowSize()
			if not step.size then return end
			local width, height, used = UI.ConsoleSize and UI:ConsoleSize()
			if not width then step.size:SetText('CX-1  applies on reload') return end
			local key = Read('actionbars.keySize')
			local note = (used and key and used ~= key) and format('   keys %d', used) or ''
			step.size:SetText(format('CX-1  %d × %d%s', width, height, note))
		end
		local function Later() C_Timer.After(0.15, function() UI:Safe(ShowSize) end) end
		step.keySize = Slider(body, 'Key size', 24, 48, 1, function() return Read('actionbars.keySize') end,
			function(value) Set('actionbars.keySize', value); Later() end, Whole, 260)
		step.keySize:SetPoint('TOPLEFT', body, 'TOPLEFT', 520, -150)
		step.width = Slider(body, 'Console width', 0, 2000, 40, function() return Read('actionbars.consoleWidth') or 0 end,
			function(value) Set('actionbars.consoleWidth', value); Later() end,
			function(value) return value == 0 and 'Auto' or format('%d', value) end, 220)
		step.width:SetPoint('TOPLEFT', body, 'TOPLEFT', 560, -280)
		step.size = Kit:Text(body, '', 8, 'dim', true)
		step.size:SetPoint('TOPLEFT', step.width, 'BOTTOMLEFT', 0, -4)
		step.ShowSize = ShowSize
		step.side = Toggle(body, 'Side bars', 'The right and left bars at the screen edge.', function() return Read('actionbars.side') end,
			function(value) Set('actionbars.side', value, true) end, 350, -226, 210)
		step.dock = Toggle(body, 'Dock frames', 'Player and target inside the console.', function() return Read('actionbars.dock') end,
			function(value) Set('actionbars.dock', value, true) end, 570, -226, 210)
		Caption(body, 'Empty keys (Classic look)', 350, -280)
		step.empty = Picker(body, {{0.35, 'Faint'}, {1, 'Solid'}}, function()
			local alpha = Read('actionbars.emptyAlpha') or 0.35
			return alpha >= 0.99 and 1 or 0.35
		end, function(value) Set('actionbars.emptyAlpha', value) end, 180)
		step.empty:SetPoint('TOPLEFT', body, 'TOPLEFT', 350, -296)
	end,
	refresh = function(step)
		step.layout:Paint(); step.look:Paint(); step.rows:Refresh(); step.keySize:Refresh(); step.side:Refresh(); step.dock:Refresh()
		step.empty:Refresh(); step.width:Refresh(); step.ShowSize()
	end,
	summary = function()
		return {{'Bar layout', Name({{'console', 'Console'}, {'free', 'Free'}}, Read('actionbars.layout')), {'actionbars.layout'}},
			{'Key look', Name({{'hardware', 'Hardware'}, {'classic', 'Classic'}}, Read('actionbars.look')), {'actionbars.look'}},
			{'Rows', tostring(Read('actionbars.rows')), {'actionbars.rows'}},
			{'Key size', tostring(Read('actionbars.keySize')), {'actionbars.keySize'}},
			{'Console width', (Read('actionbars.consoleWidth') or 0) == 0 and 'Auto' or tostring(Read('actionbars.consoleWidth')), {'actionbars.consoleWidth'}},
			{'Side bars', Read('actionbars.side') and 'On' or 'Off', {'actionbars.side'}}}
	end}

-- Damage meter choice: DM-1 replacing the game's meter, the game's meter skinned, or the game's own.
local function MeterMode()
	if Read('style.meters') == 'blizzard' then return 'blizzard' end
	if Read('meters.own') then return 'dm1' end
	return 'skin'
end
local function SetMeterMode(value)
	Set('style.meters', value == 'blizzard' and 'blizzard' or 'device', true)
	Set('meters.own', value == 'dm1', true)
	Set('meters.replaceGame', value == 'dm1', true)
end
local METER_SPOTS = {{'bottomright', 'Bottom right', {'BOTTOMRIGHT', -16, 260}}, {'right', 'Right', {'RIGHT', -16, 0}},
	{'left', 'Left', {'LEFT', 16, 0}}}

STEPS[#STEPS + 1] = {key = 'meters', title = 'Damage meters', short = 'Meters',
	text = 'DM-1 windows read the game\'s own combat data and take the place of its meter. Or keep the game\'s meter in SPEC-01 parts, or as it is. Applies on reload.',
	build = function(body, step)
		local function RowsMock(stage, dark)
			local box = M.Box(stage, 150, 58, dark and 'dark' or 'paper', 5)
			local meters = {}
			local colors = {'red', 'amber', 'blue', 'green'}
			for index = 1, 4 do
				local meter = M.Meter(box, 132 - index * 18, 8, 1, colors[index])
				meter:SetPoint('TOPLEFT', 8, -6 - (index - 1) * 12)
				meters[index] = meter
			end
			return box, function() for index, meter in ipairs(meters) do meter:Play(index * 0.06) end end
		end
		step.mode = Cards(body, {
			{value = 'dm1', title = 'DM-1 meter', sub = 'Replaces the game\'s meter.', mock = function(s) return RowsMock(s) end},
			{value = 'skin', title = 'Game meter, skinned', sub = 'The game\'s meter in SPEC-01 parts.', mock = function(s) return RowsMock(s, true) end},
			{value = 'blizzard', title = 'Game meter', sub = 'Left as the game draws it.', mock = function(s)
				local frame, animate = RowsMock(s, true)
				frame:SetAlpha(0.45)
				return frame, animate
			end},
		}, {w = 252, h = 118, gap = 12, cols = 3, x = 0, y = -14, get = MeterMode, set = SetMeterMode})
		Caption(body, 'Windows', 0, -150)
		step.count = Picker(body, {{1, '1'}, {2, '2'}, {3, '3'}}, function() return Read('meters.ownCount') end,
			function(value) Set('meters.ownCount', value, true) end, 150)
		step.count:SetPoint('TOPLEFT', body, 'TOPLEFT', 0, -166)
		Caption(body, 'Place', 180, -150)
		local spots = {}
		for index, spot in ipairs(METER_SPOTS) do spots[index] = {spot[1], spot[2]} end
		step.spot = Picker(body, spots, function() return step.spotValue end, function(value)
			step.spotValue = value
			for _, spot in ipairs(METER_SPOTS) do
				if spot[1] == value then UI:SetMoverPosition('dm.own', spot[3][1], spot[3][2], spot[3][3]) end
			end
		end, 300)
		step.spot:SetPoint('TOPLEFT', body, 'TOPLEFT', 180, -166)
		if Loaded('Details') then
			step.details = Toggle(body, 'Details! in SPEC-01', 'Its windows set through Details\' own skin settings.',
				function() return Read('meters.details') end, function(value) Set('meters.details', value, true) end, 0, -220, 400)
		else
			local note = Kit:Text(body, 'Details! isn\'t loaded, so there is nothing of it to skin.', 8, 'dim')
			note:SetPoint('TOPLEFT', body, 'TOPLEFT', 0, -226)
		end
	end,
	refresh = function(step)
		step.mode:Paint(); step.count:Refresh()
		local _, x = UI.GetMoverPosition and UI:GetMoverPosition('dm.own')
		step.spotValue = step.spotValue or 'bottomright'
		if x == nil then step.spotValue = 'bottomright' end
		step.spot:Refresh()
		if step.details then step.details:Refresh() end
	end,
	summary = function()
		return {{'Damage meter', Name({{'dm1', 'DM-1'}, {'skin', 'Game meter, skinned'}, {'blizzard', 'Game meter'}}, MeterMode()),
			{'style.meters', 'meters.own', 'meters.replaceGame'}},
			{'Meter windows', tostring(Read('meters.ownCount')), {'meters.ownCount'}}}
	end}

STEPS[#STEPS + 1] = {key = 'minimap', title = 'Minimap', short = 'Map',
	text = 'Device sets the map in a navigator with an LCD strip; Ring is a round map in a bezel; Blizzard leaves it alone. The style applies on reload, the size at once.',
	build = function(body, step)
		local function Navigator(stage)
			local box = M.Box(stage, 74, 74, 'paper', 6)
			local map = M.Box(box, 62, 50, 'screen', 3)
			map:SetPoint('TOP', 0, -6)
			local lcd = M.LCD(box, 62, 10, '12:00', 7)
			lcd:SetPoint('BOTTOM', 0, 5)
			return box, function() PowerOn(map); lcd:Play(0.15) end
		end
		local function Ring(stage, dim)
			local dial = CreateFrame('Frame', nil, stage)
			dial:SetSize(70, 70)
			local disc = Kit:Texture(dial, 'circle', 'ARTWORK')
			disc:SetAllPoints()
			Kit:Tint(disc, 'screenFill')
			local ring = Kit:Texture(dial, 'circle-ring', 'OVERLAY')
			ring:SetAllPoints()
			Kit:Tint(ring, dim and 'amber' or 'panel')
			dial:SetAlpha(dim and 0.5 or 1)
			return dial, function() if not dim then PowerOn(dial) end end
		end
		step.style = Cards(body, {
			{value = 'navigator', title = 'Device', sub = 'Navigator with an LCD strip.', mock = Navigator},
			{value = 'ring', title = 'Ring', sub = 'Round map in a bezel.', mock = function(s) return Ring(s) end},
			{value = 'blizzard', title = 'Blizzard', sub = 'Left as the game draws it.', mock = function(s) return Ring(s, true) end},
		}, {w = 252, h = 130, gap = 12, cols = 3, x = 0, y = 0, get = function() return Read('style.minimap') end,
			set = function(value) Set('style.minimap', value, true) end})
		step.size = Slider(body, 'Size', 0, 300, 10, function() return Read('minimap.size') end,
			function(value) Set('minimap.size', value) end, function(value) return value == 0 and 'Edit Mode' or Whole(value) end, 360)
		step.size:SetPoint('TOPLEFT', body, 'TOPLEFT', 0, -150)
		step.location = Toggle(body, 'Location strip', 'Ring style: zone, clock and keys on a glass strip.',
			function() return Read('minimap.location') end, function(value) Set('minimap.location', value) end, 400, -158, 380)
	end,
	refresh = function(step) step.style:Paint(); step.size:Refresh(); step.location:Refresh() end,
	summary = function()
		return {{'Minimap', Name({{'navigator', 'Device'}, {'ring', 'Ring'}, {'blizzard', 'Blizzard'}}, Read('style.minimap')), {'style.minimap'}}}
	end}

-- Chat: a housing choice that covers the style too.
local function ChatMode()
	if Read('style.chat') == 'blizzard' then return 'blizzard' end
	return Read('chat.housing') or 'device'
end
local function SetChatMode(value)
	if value == 'blizzard' then
		Set('style.chat', 'blizzard', true)
	else
		Set('style.chat', 'display', true)
		Set('chat.housing', value, true)
	end
end

STEPS[#STEPS + 1] = {key = 'chat', title = 'Chat', short = 'Chat',
	text = 'How chat is housed: a device with tabs in its header, dark glass, a hairline display, or the game\'s own. The housing applies on reload. The chat window\'s size and place stay with Edit Mode.',
	build = function(body, step)
		step.mode = Cards(body, {
			{value = 'device', title = 'Device', sub = 'Light housing, black display.', mock = function(s) return SurfaceMock(s, 'paper') end},
			{value = 'glass', title = 'Dark glass', sub = 'A dark housing.', mock = function(s) return SurfaceMock(s, 'dark') end},
			{value = 'hairline', title = 'Hairline', sub = 'Just the display.', mock = function(s) return SurfaceMock(s, 'glass') end},
			{value = 'blizzard', title = 'Blizzard', sub = 'The game\'s chat.', mock = function(s)
				local frame, animate = SurfaceMock(s, 'glass')
				frame:SetAlpha(0.45)
				return frame, animate
			end},
		}, {w = 186, h = 118, gap = 12, cols = 4, x = 0, y = 0, get = ChatMode, set = SetChatMode})
		step.fontSize = Slider(body, 'Text size', 9, 18, 1, function() return Read('chat.fontSize') end,
			function(value) Set('chat.fontSize', value) end, Whole, 360)
		step.fontSize:SetPoint('TOPLEFT', body, 'TOPLEFT', 0, -140)
		local note = Kit:Text(body, 'Size and place the chat window in Edit Mode (Esc, then Edit Mode): the housing follows it.', 8, 'dim')
		note:SetPoint('TOPLEFT', body, 'TOPLEFT', 400, -150)
		note:SetWidth(380)
		note:SetJustifyH('LEFT')
	end,
	refresh = function(step) step.mode:Paint(); step.fontSize:Refresh() end,
	summary = function()
		return {{'Chat', Name({{'device', 'Device'}, {'glass', 'Dark glass'}, {'hairline', 'Hairline'}, {'blizzard', 'Blizzard'}}, ChatMode()),
			{'style.chat', 'chat.housing'}}}
	end}

-- The extras: one switch each. reload marks the ones that only change on reload.
local EXTRAS = {
	{'Nameplates', 'SPEC-01 plates over units.', function() return Read('style.nameplates') ~= 'blizzard' end,
		function(on) Set('style.nameplates', on and 'dots' or 'blizzard', true) end, 'style.nameplates'},
	{'Nameplate nav tape', 'Ticks, distance and a marker over your target\'s plate.', function() return Read('navbar.enable') end,
		function(on) Set('navbar.enable', on); Kit:Apply() end},
	{'Aura timeline', 'Your abilities and cooldowns ride a line toward zero.', function() return Read('timeline.enable') end,
		function(on) Set('timeline.enable', on); Kit:Apply() end},
	{'Swing timer', 'The game\'s swing timers as SPEC-01 meters.', function() return Read('swingtimer.enable') end,
		function(on) Set('swingtimer.enable', on, true) end, 'swingtimer.enable'},
	{'Cooldown manager', 'The game\'s cooldown manager in SPEC-01 parts.', function() return Read('cooldowns.enable') end,
		function(on) Set('cooldowns.enable', on, true) end, 'cooldowns.enable'},
	{'Combat cues', 'A status device and arming ring as fights start and end.', function() return Read('combatcue.enable') end,
		function(on) Set('combatcue.enable', on, true) end, 'combatcue.enable'},
	{'Target link', 'A cable from your frame to your target\'s.', function() return Read('wiring.enable') end,
		function(on) Set('wiring.enable', on); Kit:Apply() end},
	{'Drawer and gadgets', 'Timer, volume, CPU meter and calendar in a pull-out drawer.', function() return Read('drawer.enable') end,
		function(on) Set('drawer.enable', on, true) end, 'drawer.enable'},
	{'Info panel', 'LCD readouts for time, latency, gold and more.', function() return Read('style.infopanel') ~= 'blizzard' end,
		function(on) Set('style.infopanel', on and 'device' or 'blizzard', true) end, 'style.infopanel'},
}

STEPS[#STEPS + 1] = {key = 'extras', title = 'Extras', short = 'Extras',
	text = 'Everything else, on or off. Each can be set up further on its own page in the hub.',
	build = function(body, step)
		step.rows = {}
		for index, extra in ipairs(EXTRAS) do
			local col, row = (index - 1) % 2, floor((index - 1) / 2)
			step.rows[index] = Toggle(body, extra[1], extra[2], extra[3], extra[4], col * 395, -row * 52, 380)
		end
		Caption(body, 'Info panel look', 395, -212)
		step.infoLook = Picker(body, {{'console', 'Console'}, {'lcd', 'LCD strip'}, {'minimal', 'Minimal'}},
			function() return Read('infopanel.style') end, function(value) Set('infopanel.style', value); Kit:Apply() end, 300)
		step.infoLook:SetPoint('TOPLEFT', body, 'TOPLEFT', 395, -228)
	end,
	refresh = function(step)
		for _, row in ipairs(step.rows) do row:Refresh() end
		step.infoLook:Refresh()
	end,
	summary = function()
		local list = {}
		for _, extra in ipairs(EXTRAS) do
			local ok, on = pcall(extra[3])
			list[#list + 1] = {extra[1], ok and on and 'On' or 'Off', extra[5] and {extra[5]} or {}}
		end
		return list
	end}

STEPS[#STEPS + 1] = {key = 'placement', title = 'Placement', short = 'Place',
	text = 'Put every frame exactly where you want it. Place frames hides this installer and unlocks the interface: drag frames, drag a corner grip to resize, use the wheel to scale. Press Done on the pill to come back.',
	build = function(body, step)
		local function PlaceMock(stage)
			local screen = M.Box(stage, 220, 80, 'screen', 4)
			local block = M.Box(screen, 50, 18, 'paper', 3)
			block:SetPoint('BOTTOMLEFT', 20, 10)
			return screen, function()
				if Reduced() then return end
				Kit:Animate(Tag('place', block), 0.7, 0, 1, function(value)
					block:ClearAllPoints()
					block:SetPoint('BOTTOMLEFT', 20 + 130 * value, 10 + 40 * value)
				end, nil, 'detent')
			end
		end
		local function KeepMock(stage)
			local screen, animate = PresetMock(stage, 'console')
			return screen, animate
		end
		step.mode = Cards(body, {
			{value = 'place', title = 'Place frames now', sub = 'Unlock and arrange everything.', mock = PlaceMock},
			{value = 'keep', title = 'Keep these positions', sub = 'The arrangement you chose.', mock = KeepMock},
		}, {w = 382, h = 150, gap = 16, cols = 2, x = 0, y = 0, combat = true,
			get = function() return step.choice end,
			set = function(value)
				step.choice = value
				if value == 'place' then C_Timer.After(Reduced() and 0 or 0.35, function() UI:Safe(UI.SetupPlace, UI) end) end
			end})
		local tips = Kit:Text(body, 'In unlock mode: drag a frame to move it, the corner grip resizes, the wheel scales and Ctrl+wheel sets opacity. Arrow keys nudge, Ctrl+Z undoes. The console at the top of the screen has grid, snap and reset.', 9, 'dim')
		tips:SetPoint('TOPLEFT', body, 'TOPLEFT', 0, -172)
		tips:SetWidth(CONTENT_W)
		tips:SetJustifyH('LEFT')
		tips:SetSpacing(3)
	end,
	refresh = function(step) step.mode:Paint() end,
	summary = function() return {{'Frame positions', 'Saved', {}}} end}

STEPS[#STEPS + 1] = {key = 'finish', title = 'Ready', short = 'Finish', final = true,
	text = 'Here is what you chose. Lamps marked amber take effect after the reload. Reload and play to start with everything in place.',
	build = function(body, step)
		step.screen = Kit:Screen(body, {inset = 3, radius = 6})
		step.screen:SetSize(CONTENT_W, 300)
		step.screen:SetPoint('TOPLEFT')
		step.rows = {}
		for index = 1, 30 do
			local col, row = floor((index - 1) / 15), (index - 1) % 15
			local entry = CreateFrame('Frame', nil, step.screen.screen)
			entry:SetSize(370, 18)
			entry:SetPoint('TOPLEFT', 10 + col * 382, -8 - row * 19)
			entry.led = Kit:Led(entry, 5, false)
			entry.led:SetPoint('LEFT', 0, 0)
			entry.label = Kit:Label(entry, '', 'darkDim', 8, true)
			entry.label:SetPoint('LEFT', 12, 0)
			entry.value = Kit:Text(entry, '', 9, 'darkInk', true)
			entry.value:SetPoint('RIGHT', -6, 0)
			entry:Hide()
			step.rows[index] = entry
		end
		step.reload = Kit:Key(body, {width = 220, height = 38, tone = 'primary', text = 'Reload and play'})
		step.reload:SetPoint('TOPRIGHT', body, 'TOPRIGHT', 0, -318)
		step.reload.onClick = function() UI:FinishSetup(true) end
		step.later = Kit:Key(body, {width = 220, height = 38, text = 'Finish without reloading'})
		step.later:SetPoint('RIGHT', step.reload, 'LEFT', -12, 0)
		step.later.onClick = function() UI:FinishSetup(false) end
	end,
	refresh = function(step)
		local lines = {}
		for _, other in ipairs(STEPS) do
			if other.summary then
				local ok, list = pcall(other.summary)
				if ok then for _, line in ipairs(list) do lines[#lines + 1] = line end end
			end
		end
		for index, entry in ipairs(step.rows) do
			local line = lines[index]
			entry:SetShown(line ~= nil)
			if line then
				local reload = false
				for _, path in ipairs(line[3] or {}) do if pending[path] then reload = true end end
				entry.label:SetText(strupper(line[1]))
				entry.value:SetText(line[2])
				Kit:SetLed(entry.led, false)
				local delay = Reduced() and 0 or 0.1 + index * 0.07
				entry:SetAlpha(Reduced() and 1 or 0)
				C_Timer.After(delay, function()
					entry:SetAlpha(1)
					Kit:SetLed(entry.led, true, reload and 'amber' or 'green')
					TypeOn(entry.value, line[2])
					if not Reduced() then Kit:Play('tick') end
				end)
			end
		end
		local total = Reduced() and 0 or 0.25 + #lines * 0.07
		C_Timer.After(total, function()
			Kit:Play('success')
			if not Reduced() then
				Kit:Shimmer(step.reload, true, {gap = 2.2})
				Kit:Flash(step.reload, {alpha = 0.5, duration = 0.6})
			end
		end)
	end}

-- The device -----------------------------------------------------------------------------
local ShowStep

local function PaintRail(index, cascade)
	for number, entry in ipairs(guide.rail) do
		local function Light()
			if number < index then
				Kit:SetLed(entry.led, true, 'green')
				entry.led:SetAlpha(0.55)
			elseif number == index then
				Kit:SetLed(entry.led, true)
				entry.led:SetAlpha(1)
			else
				Kit:SetLed(entry.led, false)
				entry.led:SetAlpha(1)
			end
			Kit:Tint(entry.label, number == index and 'ink' or 'dim')
		end
		if cascade and not Reduced() and number <= index then
			Kit:SetLed(entry.led, false)
			C_Timer.After(0.25 + number * 0.09, function()
				Light()
				Kit:Play('blip')
			end)
		else
			Light()
		end
	end
end

function ShowStep(index, direction, opening)
	index = Kit:Clamp(index, 1, #STEPS)
	local previous = guide.index
	guide.index = index
	local step = STEPS[index]
	PaintRail(index, opening)
	TypeOn(guide.count, format('%02d / %02d', index, #STEPS), opening and 0.2 or 0)
	TypeOn(guide.heading, strupper(step.title), opening and 0.3 or 0)
	guide.text:SetText(step.text)
	for number, other in ipairs(STEPS) do
		if other.body and number ~= index then other.body:Hide() end
	end
	local fresh = not step.body
	if fresh then
		step.body = CreateFrame('Frame', nil, guide.content)
		step.body:SetSize(CONTENT_W, CONTENT_H)
		UI:Safe(step.build, step.body, step)
	end
	local body = step.body
	body:ClearAllPoints()
	body:SetPoint('TOPLEFT', guide.content, 'TOPLEFT', 0, 0)
	body:Show()
	if step.refresh then UI:Safe(step.refresh, step, fresh or previous ~= index) end
	if not Reduced() and previous ~= index then
		local from = (direction or 1) * 40
		body:SetAlpha(0)
		Kit:Animate(Tag('slide', body), 0.3, from, 0, function(value, progress)
			body:ClearAllPoints()
			body:SetPoint('TOPLEFT', guide.content, 'TOPLEFT', value, 0)
			body:SetAlpha(min(1, progress * 1.6))
		end, function()
			body:ClearAllPoints()
			body:SetPoint('TOPLEFT', guide.content, 'TOPLEFT', 0, 0)
			body:SetAlpha(1)
		end, 'detent')
	else
		body:SetAlpha(1)
	end
	guide.back:SetKeyEnabled(index > 1)
	guide.skip:SetShown(not step.final)
	guide.next:SetShown(not step.final)
end

local function Go(index, direction)
	if guide.index == index then return end
	Kit:Play(direction and direction < 0 and 'latch-up' or 'latch-down')
	ShowStep(index, direction)
end

local function CloseGuide()
	UI:Account('setup').done = true
	if guide and guide:IsShown() then
		Kit:Play('latch-up')
		Kit:Close(guide)
	end
	if pill then pill:Hide() end
end

local function ConfirmClose()
	Kit:AlertDialog({title = 'Close the installer', confirm = 'Close',
		text = 'Everything you chose so far is kept. Some of it takes effect after a reload. Open the installer again any time with /spec setup.',
		onConfirm = CloseGuide})
end

local function Build()
	guide = Kit:Device(UIParent, {model = 'IN-1', title = 'Installer', width = WIDTH, height = HEIGHT, radius = 12,
		name = 'JiberishSpec01Setup'})
	guide:SetFrameStrata('FULLSCREEN_DIALOG')
	guide:SetFrameLevel(150)
	Kit:Relevel(guide)
	guide:SetPoint('CENTER', 0, 20)
	guide:EnableMouse(true)
	guide:SetMovable(true)
	guide:SetClampedToScreen(true)
	guide:RegisterForDrag('LeftButton')
	guide:SetScript('OnDragStart', guide.StartMoving)
	guide:SetScript('OnDragStop', function(self) self:StopMovingOrSizing(); Kit:ResetRest(self) end)
	-- Esc asks before closing; every other key goes on to the game.
	guide:EnableKeyboard(true)
	guide:SetScript('OnKeyDown', function(self, key)
		if InCombatLockdown() then return end
		if key == 'ESCAPE' then
			self:SetPropagateKeyboardInput(false)
			ConfirmClose()
		else
			self:SetPropagateKeyboardInput(true)
		end
	end)
	Kit:SetLed(guide.lamp, true)

	-- Header: the step counter LCD and the close key.
	guide.close = Kit:Key(guide, {round = true, width = 26, height = 26, icon = 'close', iconSize = 10})
	guide.close:SetPoint('TOPRIGHT', -10, -6)
	guide.close.onClick = ConfirmClose
	local lcd = Kit:LCDPanel(guide, {radius = 3})
	lcd:SetSize(150, 22)
	lcd:SetPoint('RIGHT', guide.close, 'LEFT', -10, 0)
	Kit:Label(lcd, 'Step', 'lcdDim', 7, true):SetPoint('LEFT', 8, 0)
	local ghost = Kit:Text(lcd, '88 / 88', 12, 'lcdGhost', true)
	ghost:SetPoint('RIGHT', -8, 0)
	guide.count = Kit:Text(lcd, '', 12, 'lcdInk', true)
	guide.count:SetPoint('RIGHT', -8, 0)
	guide.countPanel = lcd

	-- The step rail: one lamp per step across the top.
	guide.rail = {}
	local slot = floor((WIDTH - 40) / #STEPS)
	for index, step in ipairs(STEPS) do
		local entry = CreateFrame('Button', nil, guide)
		entry:SetSize(slot - 4, 30)
		entry:SetPoint('TOPLEFT', guide, 'TOPLEFT', 20 + (index - 1) * slot, -36)
		entry.led = Kit:Led(entry, 6, false)
		entry.led:SetPoint('TOP', 0, -2)
		entry.label = Kit:Label(entry, format('%02d %s', index, step.short or step.title), 'dim', 7, true)
		entry.label:SetPoint('TOP', entry.led, 'BOTTOM', 0, -5)
		entry.label:SetWordWrap(false)
		entry:SetScript('OnClick', function()
			if guide.index == index then return end
			Go(index, index < guide.index and -1 or 1)
		end)
		guide.rail[index] = entry
	end
	local rule = Kit:Solid(guide, 'rule')
	rule:SetHeight(1)
	rule:SetPoint('TOPLEFT', 20, -72)
	rule:SetPoint('TOPRIGHT', -20, -72)

	guide.heading = Kit:Text(guide, '', 16, 'ink', true)
	guide.heading:SetPoint('TOPLEFT', 20, -82)
	guide.text = Kit:Text(guide, '', 9, 'dim')
	guide.text:SetPoint('TOPLEFT', guide.heading, 'BOTTOMLEFT', 0, -6)
	guide.text:SetWidth(CONTENT_W)
	guide.text:SetJustifyH('LEFT')
	guide.text:SetSpacing(2)

	guide.content = CreateFrame('Frame', nil, guide)
	guide.content:SetPoint('TOPLEFT', 20, -136)
	guide.content:SetSize(CONTENT_W, CONTENT_H)
	guide.content:SetClipsChildren(true)

	local bottom = Kit:Solid(guide, 'rule')
	bottom:SetHeight(1)
	bottom:SetPoint('BOTTOMLEFT', 20, 56)
	bottom:SetPoint('BOTTOMRIGHT', -20, 56)
	guide.next = Kit:Key(guide, {width = 120, height = 32, tone = 'primary', text = 'Next'})
	guide.next:SetPoint('BOTTOMRIGHT', -20, 14)
	guide.next.onClick = function() Go(guide.index + 1, 1) end
	guide.skip = Kit:Key(guide, {width = 110, height = 32, text = 'Skip step'})
	guide.skip:SetPoint('RIGHT', guide.next, 'LEFT', -10, 0)
	guide.skip.onClick = function() Go(guide.index + 1, 1) end
	guide.back = Kit:Key(guide, {width = 96, height = 32, text = 'Back'})
	guide.back:SetPoint('BOTTOMLEFT', 20, 14)
	guide.back.onClick = function() if guide.index > 1 then Go(guide.index - 1, -1) end end
	guide:Hide()
end

-- The pill: what the installer folds into while you place frames (or while a
-- fight is on). Its lamp breathes; Done unfolds the installer again.
local function Pill()
	if pill then return pill end
	pill = Kit:Device(UIParent, {model = 'IN-1', title = '', width = 300, height = 46, radius = 23, header = false})
	pill:SetFrameStrata('FULLSCREEN_DIALOG')
	pill:SetPoint('TOP', UIParent, 'TOP', 0, -96)
	pill:EnableMouse(true)
	pill.led = Kit:Led(pill, 7, true)
	pill.led:SetPoint('LEFT', 16, 0)
	pill.label = Kit:Label(pill, '', 'ink', 9, true)
	pill.label:SetPoint('LEFT', pill.led, 'RIGHT', 10, 0)
	pill.done = Kit:Key(pill, {width = 76, height = 28, tone = 'primary', text = 'Done'})
	pill.done:SetPoint('RIGHT', -10, 0)
	pill.done.onClick = function() UI:SetupReturn() end
	pill:Hide()
	return pill
end

local function Fold(text, canFinish)
	local frame = Pill()
	frame.label:SetText(strupper(text))
	frame.done:SetShown(canFinish)
	if guide and guide:IsShown() then
		Kit:Play('latch-up')
		Kit:Close(guide)
	end
	frame:Show()
	if Reduced() then
		frame:SetAlpha(1)
	else
		frame:SetAlpha(0)
		Kit:Open(frame)
		Kit:Breathe(frame.led, true, {period = 1.6, low = 0.3})
		Kit:Shimmer(frame.done, true, {gap = 3})
	end
end

local function Unfold()
	if pill then
		Kit:Breathe(pill.led, false)
		Kit:Shimmer(pill.done, false)
		pill:Hide()
	end
	if not guide then return end
	Kit:Play('open')
	Kit:Open(guide)
	PowerOn(guide.content)
	if guide.index then ShowStep(guide.index) end
end

-- Placement: unlock the interface with the installer folded away.
function UI:SetupPlace()
	if InCombatLockdown() then return Shake(guide) end
	Fold('Placing frames', true)
	if UI.ToggleMovers and not UI:MoversUnlocked() then UI:ToggleMovers(false) end
end

function UI:SetupReturn()
	if InCombatLockdown() then return Shake(pill) end
	if UI.MoversUnlocked and UI:MoversUnlocked() then UI:ToggleMovers(true) end
	Unfold()
end

function UI:FinishSetup(reload)
	UI:Account('setup').done = true
	if reload then
		Kit:Play('down-primary', true)
		ReloadUI()
		return
	end
	Kit:Play('success')
	if guide then Kit:Close(guide) end
	if UI.reloadPending then
		Kit:Toast({title = 'Reload to finish', text = 'Some of your choices take effect after a reload.',
			action = {text = 'Reload', onClick = function() ReloadUI() end}})
	end
end

function UI:OpenSetup(index)
	if InCombatLockdown() then
		UI:Print('The installer opens once you leave combat.')
		return UI:AfterCombat(function() UI:OpenSetup(index) end, 'setup.open')
	end
	if not guide then Build() end
	if pill then pill:Hide() end
	local opening = not guide:IsShown() or guide.kitClosing
	ShowStep(index or guide.index or 1, nil, opening)
	if opening then
		Kit:Play('open')
		Kit:Open(guide)
		PowerOn(guide.content, 0.05)
		PowerOn(guide.countPanel, 0.1)
		TypeOn(guide.model, 'IN-1', 0.05)
		TypeOn(guide.title, 'INSTALLER', 0.12)
		if not Reduced() then Kit:Shimmer(guide.next, true, {gap = 4.4}) end
	end
end

-- A fight folds the installer away; it comes back when the fight ends.
local combat = CreateFrame('Frame')
combat:RegisterEvent('PLAYER_REGEN_DISABLED')
combat:RegisterEvent('PLAYER_REGEN_ENABLED')
combat:SetScript('OnEvent', function(_, event)
	if event == 'PLAYER_REGEN_DISABLED' then
		-- Let go of the keyboard while that's still allowed (lockdown starts
		-- after this event), so no key can be held back during the fight.
		if guide then
			guide:SetPropagateKeyboardInput(true)
			guide:EnableKeyboard(false)
		end
		if guide and guide:IsShown() then
			combat.paused = true
			Fold('Paused for combat', false)
		elseif pill and pill:IsShown() then
			combat.paused = true
			pill.label:SetText('PAUSED FOR COMBAT')
			pill.done:Hide()
		end
	elseif combat.paused or guide then
		if guide then guide:EnableKeyboard(true) end
		if not combat.paused then return end
		combat.paused = nil
		C_Timer.After(0.5, function()
			if InCombatLockdown() then return end
			Unfold()
		end)
	end
end)

-- The tour -------------------------------------------------------------------------------
-- A few stops around the hub window, each a popover pointing at one part of it.
local TOUR = {
	{'search', 'RIGHT', 'Search', 'Type any word to find a setting on every page at once.'},
	{'nav', 'RIGHT', 'Sections', 'Each part of the interface has a page. A red lamp beside one means it failed to start.'},
	{'finish', 'BOTTOM', 'Finish and key color', 'Change the look here, live, from any page.'},
	{'sound', 'BOTTOM', 'Sound key', 'Turns every SPEC-01 sound on or off.'},
	{'close', 'BOTTOM', 'Come back any time', 'Type /spec to open this window. The installer is on the Setup page.'},
}

local function TourStop(index)
	local hub = UI:HubFrame()
	local stop = TOUR[index]
	if not hub or not hub:IsShown() or not stop then return Kit:ClosePopover() end
	local anchor = stop[1] == 'nav' and hub.nav and hub.nav.overview or hub[stop[1]]
	if not anchor then return TourStop(index + 1) end
	local panel = Kit:Popover(anchor, {width = 250, height = 118, side = stop[2], cache = 'spec-tour', sound = false,
		build = function(frame)
			frame.step = Kit:Label(frame, '', 'dim', 8, true)
			frame.step:SetPoint('TOPLEFT', 14, -14)
			frame.heading = Kit:Label(frame, '', 'ink', 10, true)
			frame.heading:SetPoint('TOPLEFT', frame.step, 'BOTTOMLEFT', 0, -6)
			frame.text = Kit:Text(frame, '', 9, 'ink')
			frame.text:SetPoint('TOPLEFT', frame.heading, 'BOTTOMLEFT', 0, -6)
			frame.text:SetWidth(222)
			frame.text:SetJustifyH('LEFT')
			frame.next = Kit:Key(frame, {width = 70, height = 24, tone = 'primary', text = 'Next'})
			frame.next:SetPoint('BOTTOMRIGHT', -10, 10)
		end})
	panel.step:SetText(format('TOUR  %d/%d', index, #TOUR))
	panel.heading:SetText(strupper(stop[3]))
	panel.text:SetText(stop[4])
	panel.next:SetKeyText(index == #TOUR and 'Done' or 'Next')
	panel.next.onClick = function()
		if index == #TOUR then Kit:ClosePopover() else TourStop(index + 1) end
	end
	Kit:Play('blip')
end

function UI:StartTour()
	UI:ToggleHub('overview', true)
	C_Timer.After(0.3, function() TourStop(1) end)
end

-- First run -----------------------------------------------------------------------------
-- After the first loading screen settles, never in a fight.
local driver = CreateFrame('Frame')
driver:RegisterEvent('PLAYER_ENTERING_WORLD')
driver:SetScript('OnEvent', function(self)
	self:UnregisterAllEvents()
	if Done() then return end
	C_Timer.After(4, function()
		if Done() then return end
		UI:AfterCombat(function() UI:OpenSetup(1) end, 'setup.open')
	end)
end)

UI:RegisterPage('setup', {title = 'Setup', order = 3, since = '0.5.0', cards = {
	{title = 'Installer', rows = {
		{'note', 'Eleven steps through the whole interface: look, layout, unit frames, action bars, damage meters, minimap, chat, extras and placement, then one reload into the finished interface.'},
		{'button', 'Installer', 'Start', function() UI:ToggleHub(nil, false); UI:OpenSetup(1) end},
		{'button', 'Tour of this window', 'Start', function() UI:StartTour() end},
	}},
}})
