-- Unit frames as compact SPEC-01 devices, replacing Blizzard's player, target,
-- target of target, focus, pet and party frames, plus player and target cast bars.
--
-- Styles: 'paper' (the reference's light housing), 'dark' (charcoal housing),
-- 'lcd' (the whole frame is a gray LCD). Each frame: a printed header (combat
-- lamp, model code, name, level), the portrait on a black display, an LCD with
-- health digits over unlit segments, and LED-dot, pill or bar meters.
--
-- Shapes: 'device' (header, portrait, LCD and meters), 'bar' (a rectangle that
-- is all meter, name and health printed on it), 'square' (a tile with big LCD
-- digits), 'slim' (a thin line with the name above), 'lcdstrip' (a gray LCD
-- strip with a dot meter beneath). Only 'device' has a portrait. The page sets a
-- default shape; each frame can pick its own, live.
--
-- Every frame has its own settings (unitframes.units.<frame>): size, portrait,
-- header, readout formats, meters, colors, auras, range fade and motion. They
-- apply live through module:Refresh; only a frame's meter style and whether it
-- exists at all need a reload.
--
-- Frames are secure unit buttons: targeting, menus and visibility work in
-- combat, and their size and scale change only out of combat. The client does
-- every calculation that may involve a secret value: bars glide with its
-- interpolation, health text comes from UnitHealthPercent and the client's
-- number formatting, range fades come from its booleans, and cast bars run on
-- its duration objects. Nothing here compares, adds up or tests a secret value.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown, GetTime = CreateFrame, UIParent, InCombatLockdown, GetTime
local floor, max, min, sin, pi = math.floor, math.max, math.min, math.sin, math.pi
-- The unit frames span several files (UnitPortraits.lua, UnitAuras.lua,
-- UnitShapes.lua, UnitCastBars.lua, UnitFramesPage.lua, loaded in that order);
-- what they share lives in this table.
local P = {}
UI.UnitFrameParts = P

local module = UI:RegisterModule('unitframes', {})
local frames, ordered = {}, {}
-- The action bar console docks the player and target frames and both cast bars.
module.frames = frames
-- Every cast bar, docked or not (module.playerCast / targetCast are only the docked ones).
local casts = {}

local IsSecret = UI.Util.IsSecret

-- An aura update with nothing in it. Its fields can be secret in restricted
-- content; then it counts as a full update, never tested.
local function AuraUpdateEmpty(info)
	if type(info) ~= 'table' then return false end
	for _, field in ipairs({'isFullUpdate', 'addedAuras', 'updatedAuraInstanceIDs', 'removedAuraInstanceIDs'}) do
		local value = info[field]
		if IsSecret(value) or value then return false end
	end
	return true
end
local function DB() return UI.db.unitframes end
local function Style()
	local style = UI:Style('unitframes')
	return (style == 'dark' or style == 'lcd') and style or 'paper'
end

-- The first value of a call, or nil if it fails or is secret.
local Plain = UI.Util.PlainCall

-- A color setting: {r, g, b} or {r =, g =, b =}.
local RGB = UI.Util.RGB

local INTERPOLATION = Enum and Enum.StatusBarInterpolation
local IMMEDIATE = INTERPOLATION and INTERPOLATION.Immediate
local TIMER = Enum and Enum.StatusBarTimerDirection
-- The fill's glide, following the appearance page's "Smooth bars".
local function Smooth()
	if Kit.Smooth then return Kit:Smooth() end
	return INTERPOLATION and INTERPOLATION.ExponentialEaseOut
end
local function MarkBar(bar) if Kit.MarkBar then Kit:MarkBar(bar:GetStatusBarTexture()) end end

-- Raid frames can take over the party (group.partyAsRaid); then ours stay hidden.
local function PartyAsRaid() return UI.db.group and UI.db.group.partyAsRaid and true or false end
local function PartyVisibility() return PartyAsRaid() and 'hide' or '[group:raid] hide; [group:party] show; hide' end

-- Settings --------------------------------------------------------------------------
-- defaults:begin
-- One table per frame (party1-4 share 'party'). 'default' follows the page's global choice.
local FRAME_DEFAULTS = {
	enable = true, width = 176, height = 44, scale = 1,
	shape = 'default', -- 'default' | 'device' | 'bar' | 'square' | 'slim' | 'lcdstrip'
	portrait = 'default', -- 'default' | 'model' | 'texture' | 'class' | 'off'
	header = true, headerCode = true, headerLevel = true,
	lcdTag = 'class', -- 'class' | 'power' | 'name' | 'none' (large frames)
	healthText = 'percent', -- 'percent' | 'current' | 'both' | 'deficit' | 'none'
	powerText = 'percent', -- 'percent' | 'current' | 'both'
	shortNumbers = true,
	barStyle = 'default', -- 'default' | 'dots' | 'pill' | 'bar'
	-- Fill looks and the track behind them; 'default' follows the page.
	healthTexture = 'default', powerTexture = 'default', -- see FILL_ITEMS, or 'lsm:<name>'
	track = 'default', -- 'default' | 'screen' | 'dim' | 'clear'
	healthColor = 'default', -- 'default' | 'accent' | 'class' | 'gradient' | 'custom'
	healthCustom = {0.29, 0.64, 1},
	-- 'gradient2' on this frame: its own stops ('page' follows the page's).
	healthStops = 'page', healthStart = {0.10, 0.45, 0.28}, healthEnd = {0.47, 0.88, 0.45}, healthDirection = 'horizontal',
	healthHeight = 5, powerHeight = 3, nameSize = 10, digitsSize = 10,
	combatLamp = true, sweep = true, arrive = true, rangeFade = false, rangeAlpha = 0.45,
	auras = false, buffs = true, debuffs = true, onlyMine = false, bossOnly = false,
	auraSize = 22, auraMax = 8, auraPerRow = 8,
	auraGrow = 'right', -- 'right' | 'left'
	auraPosition = 'below', -- 'below' | 'above' | 'right' | 'left'
	auraTime = true, auraSwipe = true, stackSize = 10,
	auraTimeSize = 8, -- the countdown on each aura key, in the reference's mono numbers
	classPower = true, lampSize = 6,
	status = 'off', -- status glyph lamps (large frames): 'off' | 'lit' | 'panel'
}
local CAST_DEFAULTS = {width = 240, height = 30, icon = true, name = true, time = true,
	position = 'docked'} -- 'docked' (in the console, else its own spot) | 'under' (under its frame) | 'free'
local function Copy(source, changes)
	local copy = {}
	for key, value in pairs(source) do copy[key] = type(value) == 'table' and {unpack(value)} or value end
	for key, value in pairs(changes or {}) do copy[key] = value end
	return copy
end
UI:RegisterDefaults('unitframes', {
	shape = 'device',
	-- Power: motion on the fill ('off' | 'scan' | 'spark' | 'pulse'), a flash when
	-- it is full, and big digits beside the player's and target's power meter.
	powerMotion = 'spark',
	powerDigits = 'off', -- 'off' | 'current' | 'percent'
	powerDigitsSide = 'outer', -- 'outer' | 'inner'
	powerDigitsSize = 18,
	-- A thin timer line over each aura key.
	auraLines = true,
	-- Cast bars: 'bar' (the plate with a pill track) or 'slider' (the reference's slider).
	castStyle = 'bar',
	-- Fill looks: 'flat' | 'solid' | 'gloss' | 'gradient' | 'glass' | 'striped' | 'lsm:<name>'.
	healthTexture = 'flat', powerTexture = 'flat', castTexture = 'flat',
	-- The track behind the fill: 'default' (the housing) | 'screen' (black) | 'dim' | 'clear' | 'custom'.
	track = 'default', trackColor = {0.05, 0.05, 0.05}, trackAlpha = 0.9,
	-- Two-color health gradient (health color 'gradient2'): start and end, along the bar or up it.
	healthStart = {0.10, 0.45, 0.28}, healthEnd = {0.47, 0.88, 0.45}, healthDirection = 'horizontal',
	-- Power: 'blizzard' (the game's colors) | 'custom' (the table below) | 'key'; an optional gradient
	-- from a darker shade of the color to the color itself.
	powerMode = 'custom', powerGradient = false, powerDirection = 'horizontal',
	powerColors = {
		MANA = {0.29, 0.55, 1}, RAGE = {0.94, 0.23, 0.19}, ENERGY = {1, 0.82, 0.24}, FOCUS = {1, 0.58, 0.25},
		RUNIC_POWER = {0.2, 0.78, 0.95}, LUNAR_POWER = {0.36, 0.55, 1}, MAELSTROM = {0.1, 0.6, 1}, INSANITY = {0.62, 0.29, 0.95},
		FURY = {0.79, 0.26, 0.99}, PAIN = {1, 0.61, 0}, ESSENCE = {0.4, 0.8, 0.8}, OTHER = {0.6, 0.6, 0.58},
	},
	-- Cast bars: 'key' (the key color, gray when it can't be interrupted) or 'custom' (these).
	castMode = 'key',
	castColors = {cast = {1, 0.66, 0}, channel = {0.29, 0.64, 1}, locked = {0.55, 0.55, 0.52}, interrupted = {1, 0.23, 0.19}},
	-- Text and housing.
	nameColor = 'default', nameCustom = {1, 1, 1}, -- 'default' | 'class' | 'custom'
	textColor = 'default', textCustom = {0.85, 0.89, 0.78}, -- digits and level: 'default' | 'custom'
	housing = 'default', housingColor = {0.11, 0.11, 0.1}, housingAlpha = 0.95, -- 'default' | 'custom'
	-- Avatars (portrait styles): the ring's color and the presence lamp.
	avatarRing = 'reaction', -- 'reaction' | 'class' | 'key'
	avatarStatus = true,
	units = {
		player = Copy(FRAME_DEFAULTS, {width = 224, height = 70, healthHeight = 6, digitsSize = 13, status = 'lit'}),
		target = Copy(FRAME_DEFAULTS, {width = 224, height = 70, healthHeight = 6, digitsSize = 13, auras = true, rangeFade = true,
			status = 'lit'}),
		targettarget = Copy(FRAME_DEFAULTS, {width = 128, height = 30, healthHeight = 4, nameSize = 8, digitsSize = 9, portrait = 'off'}),
		focus = Copy(FRAME_DEFAULTS, {portrait = 'off', rangeFade = true, auras = true, onlyMine = true, auraSize = 18,
			auraMax = 6, auraPerRow = 6}),
		pet = Copy(FRAME_DEFAULTS, {width = 128, height = 30, healthHeight = 4, nameSize = 8, digitsSize = 9, portrait = 'off'}),
		party = Copy(FRAME_DEFAULTS, {portrait = 'off', rangeFade = true, auras = true, buffs = false, auraSize = 18, auraMax = 4,
			auraPerRow = 4, auraPosition = 'right'}),
	},
	cast = {player = Copy(CAST_DEFAULTS), target = Copy(CAST_DEFAULTS, {width = 224})},
	indicators = {role = true, leader = true, readyCheck = true, summon = true, resurrect = true, raidTarget = true,
		dispel = true, targetOutline = true, partyPets = false, partyTargets = false},
})
-- defaults:end
-- Core.lua declares combatSweep = true among the first defaults; it is off now.
if UI.defaults.unitframes then UI.defaults.unitframes.combatSweep = false end

local function Cfg(frame) return DB().units[frame.key] end
local function CastCfg(unit) return DB().cast[unit] end
local function Indicators() return DB().indicators end

-- Shapes -------------------------------------------------------------------------------
local SHAPES = {device = true, bar = true, square = true, slim = true, lcdstrip = true, console = true, gauge = true, tape = true,
	printed = true}
-- The frame size each shape is drawn for, by kind of frame. Device sizes are the defaults.
local KIND = {player = 'large', target = 'large', focus = 'medium', party = 'medium', targettarget = 'small', pet = 'small'}
local SHAPE_SIZES = {
	bar = {large = {224, 30}, medium = {176, 26}, small = {128, 22}},
	square = {large = {76, 76}, medium = {58, 58}, small = {46, 46}},
	slim = {large = {200, 26}, medium = {164, 24}, small = {124, 22}},
	lcdstrip = {large = {224, 40}, medium = {176, 34}, small = {128, 30}},
	console = {large = {224, 66}, medium = {176, 46}, small = {136, 36}},
	gauge = {large = {200, 56}, medium = {164, 46}, small = {124, 36}},
	tape = {large = {224, 46}, medium = {176, 40}, small = {128, 34}},
	printed = {large = {224, 50}, medium = {176, 44}, small = {136, 36}},
}

-- The shape a frame setting resolves to ('default' follows the page).
local function Resolve(shape)
	if shape == 'default' or not shape then shape = DB().shape end
	return SHAPES[shape] and shape or 'device'
end
local function ShapeOf(frame) return Resolve(Cfg(frame).shape) end

local function NaturalSize(key, shape)
	if shape == 'device' then
		local defaults = UI.defaults.unitframes and UI.defaults.unitframes.units[key]
		if defaults then return defaults.width, defaults.height end
		return 176, 44
	end
	local size = SHAPE_SIZES[shape][KIND[key] or 'medium']
	return size[1], size[2]
end

-- Picking a shape sets the frame to that shape's natural size (adjustable after).
local function FitShape(key)
	local unitCfg = DB().units[key]
	if not unitCfg then return end
	unitCfg.width, unitCfg.height = NaturalSize(key, Resolve(unitCfg.shape))
end

function UI:SetUnitFrameShape(shape, key)
	if key then
		DB().units[key].shape = shape
		FitShape(key)
	else
		DB().shape = SHAPES[shape] and shape or 'device'
		for unitKey, unitCfg in pairs(DB().units) do
			if unitCfg.shape == 'default' or not unitCfg.shape then FitShape(unitKey) end
		end
	end
end

-- size: 'large' (player, target), 'medium' (focus, party), 'small' (target of target, pet)
local LAYOUT = {
	{unit = 'player', key = 'player', model = 'UF-1', title = 'Player', size = 'large', at = {'BOTTOM', -228, 236}, power = true, classpower = true},
	{unit = 'target', key = 'target', model = 'UF-2', title = 'Target', size = 'large', at = {'BOTTOM', 228, 236}, power = true, mirror = true},
	{unit = 'targettarget', key = 'targettarget', model = 'UF-3', title = 'Target of target', size = 'small', at = {'BOTTOM', 422, 256}, poll = 0.2},
	{unit = 'focus', key = 'focus', model = 'UF-4', title = 'Focus', size = 'medium', at = {'LEFT', 300, 120}, power = true},
	{unit = 'pet', key = 'pet', model = 'UF-5', title = 'Pet', size = 'small', at = {'BOTTOM', -400, 196}, power = true},
}
for index = 1, 4 do
	LAYOUT[#LAYOUT + 1] = {unit = 'party'..index, key = 'party', model = 'PT-'..index, title = 'Party '..index, size = 'medium',
		power = true, party = true, at = {'LEFT', 24, 200 - (index - 1) * 62}}
end
-- Party pets and party targets ride beside their party frame, in the pet and
-- target of target looks.
local EXTRAS = {}
for index = 1, 4 do
	EXTRAS[#EXTRAS + 1] = {unit = 'partypet'..index, key = 'pet', model = 'PP-'..index, title = 'Party pet '..index, size = 'small',
		extra = 'partyPets', owner = 'party'..index, party = true}
	EXTRAS[#EXTRAS + 1] = {unit = 'party'..index..'target', key = 'targettarget', model = 'PX-'..index, title = 'Party target '..index,
		size = 'small', extra = 'partyTargets', owner = 'party'..index, party = true, poll = 0.2}
end

-- Colors -------------------------------------------------------------------
-- Kept in a block of its own: the main chunk may hold at most 200 locals.
local ClassColor, ReactionColor, PaintPower, CastColor, PaintHealth
do
local function Soften(r, g, b)
	-- A little toward gray, so frames sit calmly over the world.
	local gray = 0.299 * r + 0.587 * g + 0.114 * b
	return (r + (gray - r) * 0.15) * 0.95, (g + (gray - g) * 0.15) * 0.95, (b + (gray - b) * 0.15) * 0.95
end

function ClassColor(unit)
	local ok, r, g, b = pcall(function()
		if UnitIsPlayer(unit) then
			local _, class = UnitClass(unit)
			local color = not IsSecret(class) and class and (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)[class]
			if color then return color.r, color.g, color.b end
		elseif UnitIsTapDenied and UnitIsTapDenied(unit) then
			return 0.55, 0.55, 0.53
		else
			local reaction = UnitReaction(unit, 'player')
			local color = not IsSecret(reaction) and reaction and FACTION_BAR_COLORS and FACTION_BAR_COLORS[reaction]
			if color then return color.r, color.g, color.b end
		end
	end)
	if ok and not IsSecret(r) and not IsSecret(g) and not IsSecret(b) and r then return Soften(r, g, b) end
	return Kit:RGB('lamp')
end

local function PowerColor(unit)
	local db = DB()
	if db.powerMode == 'key' then return Kit:RGB('lamp') end
	if db.powerMode == 'custom' and type(db.powerColors) == 'table' then
		local okType, _, token = pcall(UnitPowerType, unit)
		local color = okType and not IsSecret(token) and token and db.powerColors[token] or db.powerColors.OTHER
		local cr, cg, cb = RGB(color)
		if cr then return cr, cg, cb end
	end
	local ok, r, g, b = pcall(function()
		local _, token = UnitPowerType(unit)
		local color = not IsSecret(token) and token and PowerBarColor and PowerBarColor[token]
		if color then return color.r, color.g, color.b end
	end)
	if ok and not IsSecret(r) and r then return r, g, b end
	return 0.29, 0.64, 1
end

-- Red to amber to green by health. The client looks the color up from the
-- curve, so a secret health still colors the bar.
local gradient
local function GradientCurve()
	if gradient ~= nil then return gradient or nil end
	gradient = false
	if not (C_CurveUtil and C_CurveUtil.CreateColorCurve and CreateColor) then return nil end
	local ok, curve = pcall(C_CurveUtil.CreateColorCurve)
	if not ok or not curve then return nil end
	if Enum and Enum.LuaCurveType and curve.SetType then pcall(curve.SetType, curve, Enum.LuaCurveType.Linear) end
	for _, stop in ipairs({{0, 'red'}, {0.5, 'amber'}, {1, 'green'}}) do
		local r, g, b = Kit:RGB(stop[2])
		curve:AddPoint(stop[1], CreateColor(r, g, b, 1))
	end
	gradient = curve
	return curve
end
Kit:OnRefresh(function() gradient = nil end)

local function HealthMode(frame)
	local mode = Cfg(frame).healthColor
	if mode == 'default' or not mode then mode = DB().healthColor end
	return mode
end

-- SPEC-01's own colors as health colors: its lamps and its six key swatches.
local TOKEN_COLORS = {ledGreen = 'ledGreen', ledBlue = 'ledBlue', amber = 'amber', screen = 'screenAccent', red = 'red'}

function ReactionColor(unit)
	local ok, r, g, b = pcall(function()
		if UnitIsTapDenied and UnitIsTapDenied(unit) then return 0.55, 0.55, 0.53 end
		local reaction = UnitReaction(unit, 'player')
		local color = not IsSecret(reaction) and reaction and FACTION_BAR_COLORS and FACTION_BAR_COLORS[reaction]
		if color then return color.r, color.g, color.b end
	end)
	if ok and not IsSecret(r) and not IsSecret(g) and not IsSecret(b) and r then return Soften(r, g, b) end
	return Kit:RGB('lamp')
end

-- Two colors across a fill texture: set straight on the texture (SetGradient),
-- so it rides the fill with no value read. 'vertical' runs bottom to top.
local function FillGradient(bar, direction, start, finish)
	local fill = bar and bar:GetStatusBarTexture()
	local r1, g1, b1 = RGB(start)
	local r2, g2, b2 = RGB(finish)
	if not (fill and fill.SetGradient and CreateColor and r1 and r2) then
		if r2 then bar:SetStatusBarColor(r2, g2, b2) end
		return
	end
	fill:SetGradient(direction == 'vertical' and 'VERTICAL' or 'HORIZONTAL', CreateColor(r1, g1, b1, 1), CreateColor(r2, g2, b2, 1))
	bar.gradientEnd = finish
end

local function HealthStops(frame)
	local cfg, db = Cfg(frame), DB()
	if cfg.healthColor == 'gradient2' and cfg.healthStops == 'own' then return cfg.healthDirection, cfg.healthStart, cfg.healthEnd end
	return db.healthDirection, db.healthStart, db.healthEnd
end

-- Power: its color, or a gradient from a darker shade of it to the color.
function PaintPower(bar, unit)
	local r, g, b = PowerColor(unit)
	local db = DB()
	if db.powerGradient then FillGradient(bar, db.powerDirection, {r * 0.45, g * 0.45, b * 0.45}, {r, g, b})
	else bar:SetStatusBarColor(r, g, b) end
end

-- Cast colors: kind is 'cast', 'channel', 'locked' (can't be interrupted) or 'interrupted'.
local KEY_CAST = {cast = 'lamp', channel = 'lamp', interrupted = 'red'}
function CastColor(kind)
	local db = DB()
	if db.castMode == 'custom' and type(db.castColors) == 'table' then
		local r, g, b = RGB(db.castColors[kind])
		if r then return r, g, b end
	end
	if kind == 'locked' then return 0.55, 0.55, 0.52 end
	return Kit:RGB(KEY_CAST[kind] or 'lamp')
end

-- Shared with the raid, boss and arena frames.
UI.UnitColors = {PowerColor = PowerColor, PaintPower = PaintPower, CastColor = CastColor, FillGradient = FillGradient}

function PaintHealth(frame)
	local bar, unit, mode = frame.health, frame.unit, HealthMode(frame)
	if mode == 'gradient2' then
		FillGradient(bar, HealthStops(frame))
		if frame.gauge then pcall(frame.gauge.bar.SetStatusBarColor, frame.gauge.bar, RGB(select(3, HealthStops(frame)))) end
		return
	end
	if mode == 'custom' then
		local r, g, b = RGB(Cfg(frame).healthCustom)
		if r then return bar:SetStatusBarColor(r, g, b) end
	elseif mode == 'accent' and Kit:DB().accent ~= 'class' then
		-- A key color set to Class means each unit's own class, not the player's.
		return bar:SetStatusBarColor(Kit:RGB('lamp'))
	elseif TOKEN_COLORS[mode] then
		return bar:SetStatusBarColor(Kit:RGB(TOKEN_COLORS[mode]))
	elseif type(mode) == 'string' and mode:sub(1, 7) == 'swatch:' then
		local swatch = Kit.accents and Kit.accents[mode:sub(8)]
		if swatch then return bar:SetStatusBarColor(swatch[1], swatch[2], swatch[3]) end
	elseif mode == 'reaction' then
		return bar:SetStatusBarColor(ReactionColor(unit))
	elseif mode == 'gradient' then
		local curve = GradientCurve()
		if curve and UnitHealthPercent then
			local ok, color = pcall(UnitHealthPercent, unit, true, curve)
			if ok and type(color) == 'table' and color.GetRGB and pcall(bar.SetStatusBarColor, bar, color:GetRGB()) then return end
		end
	end
	bar:SetStatusBarColor(ClassColor(unit))
end
end

-- Numbers -------------------------------------------------------------------------
-- The client's own number formatting takes secret values; ours is only used on
-- plain ones.
local function Short(value, short)
	if short and AbbreviateNumbers then
		local ok, text = pcall(AbbreviateNumbers, value)
		if ok then return text end
	elseif not short and BreakUpLargeNumbers then
		local ok, text = pcall(BreakUpLargeNumbers, value)
		if ok then return text end
	end
	if IsSecret(value) then return value end
	if short and value >= 1e6 then return format('%.1fm', value / 1e6) end
	if short and value >= 1e4 then return format('%.0fk', value / 1e3) end
	return format('%d', value)
end

local function HealthPercent(fontString, unit)
	if UnitHealthPercent and CurveConstants and CurveConstants.ScaleTo100 then
		fontString:SetFormattedText('%d', UnitHealthPercent(unit, true, CurveConstants.ScaleTo100))
		return
	end
	local health, maximum = UnitHealth(unit), UnitHealthMax(unit)
	if IsSecret(health) or IsSecret(maximum) then fontString:SetText('') return end
	fontString:SetFormattedText('%d', maximum > 0 and floor(health / maximum * 100 + 0.5) or 0)
end

local function SetHealthText(fontString, unit, kind, short)
	local ok = pcall(function()
		if kind == 'none' then fontString:SetText('') return end
		local dead, connected = UnitIsDeadOrGhost(unit), UnitIsConnected(unit)
		if not IsSecret(dead) and dead then fontString:SetText('DEAD') return end
		if not IsSecret(connected) and not connected then fontString:SetText('OFF') return end
		if kind == 'current' then
			fontString:SetFormattedText('%s', Short(UnitHealth(unit), short))
		elseif kind == 'both' then
			fontString:SetFormattedText('%s / %s', Short(UnitHealth(unit), short), Short(UnitHealthMax(unit), short))
		elseif kind == 'deficit' then
			local health, maximum = UnitHealth(unit), UnitHealthMax(unit)
			if not IsSecret(health) and not IsSecret(maximum) then
				local missing = maximum - health
				fontString:SetText(missing > 0 and '-'..Short(missing, short) or '')
			elseif UnitHealthMissing then
				fontString:SetFormattedText('-%s', Short(UnitHealthMissing(unit), short))
			else
				HealthPercent(fontString, unit)
			end
		else
			HealthPercent(fontString, unit)
		end
	end)
	if not ok then fontString:SetText('') end
end

local function SetPowerText(fontString, unit, kind, short)
	local ok = pcall(function()
		if kind == 'current' then
			fontString:SetFormattedText('%s', Short(UnitPower(unit), short))
		elseif kind == 'both' then
			fontString:SetFormattedText('%s / %s', Short(UnitPower(unit), short), Short(UnitPowerMax(unit), short))
		else
			if UnitPowerPercent and CurveConstants and CurveConstants.ScaleTo100 then
				local done = pcall(function()
					fontString:SetFormattedText('%d%%', UnitPowerPercent(unit, nil, false, CurveConstants.ScaleTo100))
				end)
				if done then return end
			end
			local power, maximum = UnitPower(unit), UnitPowerMax(unit)
			if IsSecret(power) or IsSecret(maximum) then fontString:SetText('') return end
			fontString:SetFormattedText('%d%%', maximum > 0 and floor(power / maximum * 100 + 0.5) or 0)
		end
	end)
	if not ok then fontString:SetText('') end
end

-- Class resources as lamps ---------------------------------------------------------
local ENUM = Enum and Enum.PowerType or {}
local CLASS_POWER = {
	ROGUE = ENUM.ComboPoints or 4, DRUID = ENUM.ComboPoints or 4, PALADIN = ENUM.HolyPower or 9,
	WARLOCK = ENUM.SoulShards or 7, MONK = ENUM.Chi or 12, MAGE = ENUM.ArcaneCharges or 16, EVOKER = ENUM.Essence or 19,
}

local function UpdateClassPower(frame)
	local lamps = frame.lamps
	if not lamps then return end
	local cfg = Cfg(frame)
	local _, class = UnitClass('player')
	local shown, lit = 0, 0
	if cfg.classPower then
		pcall(function()
			if class == 'DEATHKNIGHT' and GetRuneCooldown then
				shown = 6
				for rune = 1, 6 do
					local _, _, ready = GetRuneCooldown(rune)
					if not IsSecret(ready) and ready then lit = lit + 1 end
				end
				return
			end
			local power = CLASS_POWER[class]
			if not power then return end
			if class == 'DRUID' and Plain(UnitPowerType, 'player') ~= (ENUM.Energy or 3) then return end
			if class == 'MAGE' and GetSpecialization and Plain(GetSpecialization) ~= 1 then return end
			local maximum = UnitPowerMax('player', power)
			if IsSecret(maximum) or not maximum or maximum <= 0 then return end
			shown = min(maximum, #lamps)
			local current = UnitPower('player', power)
			lit = IsSecret(current) and 0 or current
		end)
	end
	for index, lamp in ipairs(lamps) do
		if index <= shown then Kit:SetLed(lamp, index <= lit) end
		Kit:ShowLed(lamp, index <= shown)
	end
	frame.lampRail:SetShown(shown > 0)
	if shown > 0 then frame.lampRail:SetWidth(shown * ((cfg.lampSize or 6) + 6) + 10) end
end

-- Updates -----------------------------------------------------------------------------
local function UpdateHealth(frame)
	local unit = frame.unit
	frame.health:SetMinMaxValues(0, UnitHealthMax(unit))
	-- The client eases the fill toward the new value, secret or not.
	frame.health:SetValue(UnitHealth(unit), Smooth())
	PaintHealth(frame)
	local cfg = Cfg(frame)
	if frame.digits then SetHealthText(frame.digits, unit, cfg.healthText, cfg.shortNumbers) end
end

local function UpdateTag(frame)
	local tag = frame.tag
	-- Only the device shape's large frames show the tag.
	if not tag or not tag:IsShown() then return end
	local cfg, unit = Cfg(frame), frame.unit
	local kind = cfg.lcdTag
	if kind == 'none' then tag:SetText('') return end
	if kind == 'power' then return SetPowerText(tag, unit, cfg.powerText, cfg.shortNumbers) end
	if kind == 'name' then
		local name = UnitName(unit)
		if IsSecret(name) then tag:SetText(name)
		elseif Kit.PrintText then Kit:PrintText(tag, name and strupper(name) or '')
		else tag:SetText(name and strupper(name) or '') end
		return
	end
	local ok = pcall(function()
		local classText = UnitIsPlayer(unit) and UnitClass(unit) or (UnitCreatureType and UnitCreatureType(unit)) or ''
		if IsSecret(classText) then tag:SetText(classText)
		elseif Kit.PrintText then Kit:PrintText(tag, strupper(classText or ''))
		else tag:SetText(strupper(classText or '')) end
	end)
	if not ok then tag:SetText('') end
end

-- Power motion ---------------------------------------------------------------------------
-- Three SPEC-01 ways for the power meter to feel alive. Each is an AnimationGroup
-- or hangs on the fill texture's edge, which the client moves with the (possibly
-- secret) value, so nothing about the value is read and no Lua runs per frame.
--   scan:  a crisp two-pixel hairline with a short fading trail sweeps the
--          filled part, then rests: calm for mana, quicker for energy, rage and
--          the like, and quicker again while the meter refills.
--   spark: a lit hairline rides the fill's edge, breathing gently, and flares
--          when power is gained (judged from plain values only).
--   pulse: the fill brightens and settles, a lamp on a slow heartbeat.
-- With reduced motion the spark stays, still; the others are off.
-- Kept in a block of its own: the main chunk may hold at most 200 locals.
local ApplyMotion, LayoutPowerDigits, PowerExtras
do
local QUICK_POWER = {ENERGY = true, RAGE = true, FOCUS = true, RUNIC_POWER = true, FURY = true, PAIN = true,
	MAELSTROM = true, INSANITY = true, LUNAR_POWER = true}
local FLARE_GAP = 1.1 -- seconds between flares, so steady regen reads as a slow beat

local function PowerMotion()
	local mode = DB().powerMotion or 'off'
	if Kit.Reduced and Kit:Reduced() then return mode == 'spark' and 'still' or 'off' end
	return mode
end

local function MotionPeriod(frame)
	local ok, _, token = pcall(UnitPowerType, frame.unit)
	local quick = ok and not IsSecret(token) and QUICK_POWER[token] or false
	local period = quick and 1.8 or 3.4
	if frame.power.motionFilling then period = period * 0.7 end
	return period
end

local MotionLayout
local function Hairline(parent, layer, sublevel)
	local texture = parent:CreateTexture(nil, layer or 'OVERLAY', nil, sublevel or 6)
	texture:SetColorTexture(1, 1, 1, 1)
	texture:SetBlendMode('ADD')
	return texture
end

local function MotionParts(bar)
	local m = bar.motion
	if m then return m end
	m = {}
	local fill = bar:GetStatusBarTexture()
	-- The filled part only: from the bar's left edge to the fill's right edge.
	m.clip = CreateFrame('Frame', nil, bar)
	m.clip:SetPoint('TOPLEFT', bar, 'TOPLEFT')
	m.clip:SetPoint('BOTTOMRIGHT', fill, 'BOTTOMRIGHT')
	m.clip:SetClipsChildren(true)
	m.clip:SetFrameLevel(bar:GetFrameLevel() + 1)
	m.clip:EnableMouse(false)
	-- Scan: the hairline and its trail on one band, moved by a translation.
	m.band = CreateFrame('Frame', nil, m.clip)
	m.band:EnableMouse(false)
	m.core = Hairline(m.band, 'OVERLAY', 6)
	m.trail = Hairline(m.band, 'OVERLAY', 5)
	if m.trail.SetGradient and CreateColor then
		m.trail:SetGradient('HORIZONTAL', CreateColor(1, 1, 1, 0), CreateColor(1, 1, 1, 0.4))
	else
		m.trail:SetAlpha(0.2)
	end
	m.scan = m.band:CreateAnimationGroup()
	m.scan:SetLooping('REPEAT')
	m.move = m.scan:CreateAnimation('Translation')
	-- Pulse: a wash over the filled part, up and down.
	m.wash = Hairline(m.clip, 'OVERLAY', 4)
	m.wash:SetAllPoints(m.clip)
	m.wash:SetAlpha(0)
	m.pulse = m.wash:CreateAnimationGroup()
	m.pulse:SetLooping('REPEAT')
	m.rise = m.pulse:CreateAnimation('Alpha')
	m.rise:SetFromAlpha(0); m.rise:SetToAlpha(0.22); m.rise:SetOrder(1); m.rise:SetSmoothing('IN_OUT')
	m.fall = m.pulse:CreateAnimation('Alpha')
	m.fall:SetFromAlpha(0.22); m.fall:SetToAlpha(0); m.fall:SetOrder(2); m.fall:SetSmoothing('IN_OUT')
	-- Spark: on the fill's edge, above everything on the meter.
	m.spark = CreateFrame('Frame', nil, bar)
	m.spark:SetFrameLevel(bar:GetFrameLevel() + 4)
	m.spark:EnableMouse(false)
	m.spark:SetPoint('TOP', fill, 'TOPRIGHT', 0, 1)
	m.spark:SetPoint('BOTTOM', fill, 'BOTTOMRIGHT', 0, -1)
	m.line = Hairline(m.spark, 'OVERLAY', 6)
	m.line:SetPoint('TOP')
	m.line:SetPoint('BOTTOM')
	m.halo = Kit:Texture(m.spark, 'glow', 'OVERLAY', 5)
	m.halo:SetBlendMode('ADD')
	m.halo:SetPoint('TOPLEFT', -5, 5)
	m.halo:SetPoint('BOTTOMRIGHT', 5, -5)
	m.halo:SetAlpha(0.35)
	m.breathe = m.spark:CreateAnimationGroup()
	m.breathe:SetLooping('BOUNCE')
	m.dim = m.breathe:CreateAnimation('Alpha')
	m.dim:SetFromAlpha(1); m.dim:SetToAlpha(0.55); m.dim:SetSmoothing('IN_OUT')
	m.flare = m.halo:CreateAnimationGroup()
	local burst = m.flare:CreateAnimation('Alpha')
	burst:SetFromAlpha(1); burst:SetToAlpha(0.35); burst:SetDuration(0.45); burst:SetSmoothing('OUT')
	local grow = m.flare:CreateAnimation('Scale')
	if grow.SetScaleFrom then
		grow:SetScaleFrom(1.7, 1.7); grow:SetScaleTo(1, 1)
	else
		grow:SetScale(0.6, 0.6)
	end
	grow:SetDuration(0.45); grow:SetSmoothing('OUT')
	bar.motion = m
	bar:HookScript('OnSizeChanged', function(self) if self.motion then UI:Safe(MotionLayout, self) end end)
	return m
end

-- Sizes from the bar's own width and height, which are never secret.
function MotionLayout(bar)
	local m = bar.motion
	if not m then return end
	local width, height = bar:GetWidth(), bar:GetHeight()
	if IsSecret(width) or IsSecret(height) or not width or width <= 0 or not height then return end
	local px = UI.Pixel.Px(bar, 1)
	local trail = max(8, min(width * 0.14, 26))
	m.band:SetSize(trail + 2 * px, height)
	m.band:ClearAllPoints()
	m.band:SetPoint('RIGHT', bar, 'LEFT', 0, 0)
	m.core:ClearAllPoints()
	m.core:SetPoint('TOPRIGHT')
	m.core:SetPoint('BOTTOMRIGHT')
	m.core:SetWidth(2 * px)
	m.trail:ClearAllPoints()
	m.trail:SetPoint('TOPLEFT')
	m.trail:SetPoint('BOTTOMRIGHT', m.core, 'BOTTOMLEFT')
	m.move:SetOffset(width + trail + 2 * px, 0)
	m.spark:SetWidth(2 * px)
	m.line:SetWidth(2 * px)
end

local function MotionPlay(frame)
	local bar = frame.power
	local m = bar and bar.motion
	if not m then return end
	local mode, empty = bar.motionMode, bar.motionEmpty
	local period = MotionPeriod(frame)
	local changed = m.period ~= period
	m.period = period
	if mode == 'scan' and not empty then
		if changed or not m.scan:IsPlaying() then
			local sweep = period * 0.42
			m.scan:Stop()
			m.move:SetDuration(sweep)
			if m.move.SetEndDelay then m.move:SetEndDelay(period - sweep) end
			m.scan:Play()
		end
		m.band:Show()
	else
		m.scan:Stop()
		m.band:Hide()
	end
	if mode == 'pulse' and not empty then
		if changed or not m.pulse:IsPlaying() then
			m.pulse:Stop()
			m.rise:SetDuration(period * 0.35)
			m.fall:SetDuration(period * 0.65)
			m.pulse:Play()
		end
		m.wash:Show()
	else
		m.pulse:Stop()
		m.wash:Hide()
	end
	if (mode == 'spark' or mode == 'still') and not empty then
		m.spark:Show()
		if mode == 'spark' then
			if changed or not m.breathe:IsPlaying() then
				m.breathe:Stop()
				m.dim:SetDuration(period * 0.5)
				m.breathe:Play()
			end
		else
			m.breathe:Stop()
		end
	else
		m.breathe:Stop()
		m.flare:Stop()
		m.spark:Hide()
	end
end

function ApplyMotion(frame)
	local bar = frame.power
	if not bar then return end
	local mode = PowerMotion()
	if mode == 'off' or not bar.track:IsShown() then
		bar.motionMode = 'off'
		local m = bar.motion
		if m then
			m.scan:Stop(); m.pulse:Stop(); m.breathe:Stop(); m.flare:Stop()
			m.band:Hide(); m.wash:Hide(); m.spark:Hide()
		end
		return
	end
	local m = MotionParts(bar)
	bar.motionMode = mode
	local intensity = min(1.5, Kit.Intensity and Kit:Intensity() or 1)
	m.band:SetAlpha(min(1, 0.7 * intensity))
	m.line:SetAlpha(min(1, 0.85 * intensity))
	MotionLayout(bar)
	MotionPlay(frame)
end

-- Big power digits beside the power meter, on the outer or inner side of the
-- frame (player and target only).
function LayoutPowerDigits(frame)
	local bar = frame.power
	local mode = DB().powerDigits
	local show = bar and mode and mode ~= 'off' and frame.layout.size == 'large' and bar.track:IsShown()
	if not show then
		if frame.powerDigits then frame.powerDigits:Hide() end
		return
	end
	local holder = frame.powerDigits
	if not holder then
		holder = CreateFrame('Frame', nil, frame.overlay or frame.face)
		holder:EnableMouse(false)
		holder.text = Kit:Text(holder, '', 'title', 'ink', true, true)
		frame.powerDigits = holder
	end
	local mirror = frame.layout.mirror
	-- Outer is away from the screen centre: left of the player, right of the target.
	local left = (DB().powerDigitsSide ~= 'inner') ~= (mirror and true or false)
	holder:ClearAllPoints()
	holder:SetPoint('TOP', bar.track, 'TOP', 0, 8)
	holder:SetPoint('BOTTOM', bar.track, 'BOTTOM', 0, -8)
	holder:SetWidth(80)
	if left then holder:SetPoint('RIGHT', frame.face, 'LEFT', -8, 0) else holder:SetPoint('LEFT', frame.face, 'RIGHT', 8, 0) end
	Kit:Font(holder.text, DB().powerDigitsSize or 18, nil, true)
	holder.text:ClearAllPoints()
	holder.text:SetPoint(left and 'RIGHT' or 'LEFT')
	holder.text:SetJustifyH(left and 'RIGHT' or 'LEFT')
	Kit:Tint(holder.text, Style() == 'dark' and 'darkInk' or 'ink')
	holder:Show()
end

-- After each power update: the motion's pace, the spark's flare on a gain, the
-- flash on reaching full, the digits. All judged from plain values only; a
-- secret value skips them.
function PowerExtras(frame)
	local bar, unit = frame.power, frame.unit
	if frame.powerDigits and frame.powerDigits:IsShown() then
		SetPowerText(frame.powerDigits.text, unit, DB().powerDigits == 'percent' and 'percent' or 'current', true)
	end
	local power, maximum = Plain(UnitPower, unit), Plain(UnitPowerMax, unit)
	if not (power and maximum and maximum > 0) then
		frame.powerFull, bar.motionEmpty, bar.motionFilling, bar.lastPower = nil, nil, nil, nil
		MotionPlay(frame)
		return
	end
	local full = power >= maximum
	bar.motionFilling = not full
	-- Nothing to shine on while the bar is plainly empty.
	bar.motionEmpty = power <= 0
	MotionPlay(frame)
	local m = bar.motion
	if m and bar.motionMode == 'spark' and bar.lastPower and power > bar.lastPower and m.spark:IsVisible()
		and GetTime() - (m.flared or 0) > FLARE_GAP then
		m.flared = GetTime()
		m.flare:Stop()
		m.flare:Play()
	end
	bar.lastPower = power
	if full and frame.powerFull == false and PowerMotion() ~= 'off' and Kit.Flash and bar.track:IsVisible() then
		Kit:Flash(bar.track, {token = 'lamp', alpha = 0.4, duration = 0.4})
	end
	frame.powerFull = full
end

end
local function UpdatePower(frame)
	if not frame.power then return end
	local unit = frame.unit
	frame.power:SetMinMaxValues(0, UnitPowerMax(unit))
	frame.power:SetValue(UnitPower(unit), Smooth())
	PaintPower(frame.power, unit)
	UI:Safe(PowerExtras, frame)
	if frame.layout.classpower then UpdateClassPower(frame) end
	if frame.tag and Cfg(frame).lcdTag == 'power' then UpdateTag(frame) end
end

local CLASS_ICONS = [[Interface\TargetingFrame\UI-Classes-Circles]]

-- The 3D portrait. A PlayerModel given its unit before it has a real size, or
-- while it is hidden, stays blank until something redraws it. So the unit is
-- set only once the model is shown and sized, it is set again (next frame)
-- whenever the model is shown, resized or rescaled, and a model that still
-- reports nothing loaded is retried a few times on a short timer.
local MODEL_TRIES = 6

local function DrawModel(frame)
	local model = frame.model
	if not (model and frame.portraitMode == 'model' and model:IsVisible()) then return false end
	local width, height = model:GetSize()
	if IsSecret(width) or IsSecret(height) or not width or not height or width < 2 or height < 2 then return false end
	local ok, exists = pcall(UnitExists, frame.unit)
	if not ok or (not IsSecret(exists) and not exists) then return false end
	-- Always above the screen's glass: re-levelling the frame moves the glass
	-- up, and a model left under it is drawn but never seen.
	local screen = model:GetParent()
	if screen then model:SetFrameLevel(screen:GetFrameLevel() + 3) end
	model:ClearModel()
	model:SetUnit(frame.unit)
	model:SetPortraitZoom(1)
	model:SetCamDistanceScale(1)
	model:SetPosition(0, 0, 0)
	return true
end

-- Whether the model has something loaded. Unknown or secret counts as yes.
local function HasModel(model)
	if not (model and model.GetModelFileID) then return true end
	local ok, id = pcall(model.GetModelFileID, model)
	if not ok or IsSecret(id) then return true end
	return id ~= nil and id ~= 0
end

-- While the 3D model is missing, the screen shows the 2D portrait (or the
-- class glyph for players) instead of an empty black box.
local function ModelFallback(frame, show)
	local screen = frame.portraitScreen and frame.portraitScreen.screen
	local fallback = frame.modelFallback
	if not show or not screen then
		if fallback then fallback:Hide() end
		return
	end
	if not fallback then
		fallback = screen:CreateTexture(nil, 'ARTWORK')
		fallback:SetAllPoints()
		frame.modelFallback = fallback
	end
	local unit = frame.unit
	local _, class = UnitClass(unit)
	local coords = not IsSecret(class) and class and Plain(UnitIsPlayer, unit) and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
	if coords then
		fallback:SetTexture(CLASS_ICONS)
		fallback:SetTexCoord(unpack(coords))
	else
		SetPortraitTexture(fallback, unit)
		fallback:SetTexCoord(0.12, 0.88, 0.12, 0.88)
	end
	fallback:Show()
end

local RefreshModel
-- After a draw, check the model arrived; if not, show the fallback and try again.
local function VerifyModel(frame, tries)
	local token = frame.modelToken
	C_Timer.After(0.2, function()
		if frame.modelToken ~= token or frame.portraitMode ~= 'model' then return end
		local loaded = HasModel(frame.model)
		UI:Safe(ModelFallback, frame, not loaded)
		if not loaded and tries < MODEL_TRIES then RefreshModel(frame, tries + 1) end
	end)
end

-- Redraw on the next frame (or after a short wait, when retrying). Calls made
-- in the meantime fold into one.
function RefreshModel(frame, tries)
	if not frame.model or frame.portraitMode ~= 'model' then return end
	tries = tries or 0
	frame.modelToken = (frame.modelToken or 0) + 1
	local token = frame.modelToken
	C_Timer.After(tries == 0 and 0 or min(0.15 * tries, 0.8), function()
		if frame.modelToken ~= token then return end
		local ok, drawn = pcall(DrawModel, frame)
		if ok and drawn then VerifyModel(frame, tries)
		elseif tries < MODEL_TRIES and frame:IsVisible() then RefreshModel(frame, tries + 1)
		elseif frame:IsVisible() then UI:Safe(ModelFallback, frame, true) end
	end)
end


-- Shared with the other action bar files.
P.ApplyMotion = ApplyMotion
P.AuraUpdateEmpty = AuraUpdateEmpty
P.CastCfg = CastCfg
P.CastColor = CastColor
P.casts = casts
P.Cfg = Cfg
P.CLASS_ICONS = CLASS_ICONS
P.ClassColor = ClassColor
P.DB = DB
P.DrawModel = DrawModel
P.EXTRAS = EXTRAS
P.frames = frames
P.IMMEDIATE = IMMEDIATE
P.Indicators = Indicators
P.LAYOUT = LAYOUT
P.LayoutPowerDigits = LayoutPowerDigits
P.MarkBar = MarkBar
P.ModelFallback = ModelFallback
P.module = module
P.ordered = ordered
P.PartyAsRaid = PartyAsRaid
P.PartyVisibility = PartyVisibility
P.ReactionColor = ReactionColor
P.RefreshModel = RefreshModel
P.Resolve = Resolve
P.ShapeOf = ShapeOf
P.Style = Style
P.TIMER = TIMER
P.UpdateHealth = UpdateHealth
P.UpdatePower = UpdatePower
P.UpdateTag = UpdateTag
P.VerifyModel = VerifyModel
