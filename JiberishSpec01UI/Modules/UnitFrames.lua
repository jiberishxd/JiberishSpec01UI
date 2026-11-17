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

local module = UI:RegisterModule('unitframes', {})
local frames, ordered = {}, {}
-- The action bar console docks the player and target frames and both cast bars.
module.frames = frames
-- Every cast bar, docked or not (module.playerCast / targetCast are only the docked ones).
local casts = {}

local function IsSecret(value) return issecretvalue and issecretvalue(value) end

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
local function Plain(func, ...)
	if type(func) ~= 'function' then return nil end
	local ok, value = pcall(func, ...)
	if not ok or IsSecret(value) then return nil end
	return value
end

-- A color setting: {r, g, b} or {r =, g =, b =}.
local function RGB(color)
	if type(color) ~= 'table' then return nil end
	return color[1] or color.r, color[2] or color.g, color[3] or color.b
end

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
	elseif mode == 'accent' then
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

-- Avatars ---------------------------------------------------------------------------
-- SPEC-01's component 35 and its relatives, as portrait styles. The reference's
-- avatar is a small LED matrix behind a round black lens in a light bezel; each
-- person's glyph is worked out from their name (FNV-1a, mirrored, kept inside
-- the lens) so it never changes. Here a colored ring sits between bezel and
-- lens (reaction, class or key color) and a presence lamp sits on the rim:
-- green online, red in combat, amber away, unlit when dead or offline.
--   matrix:   the reference's LED glyph
--   monogram: the unit's initials in Plex Mono on the lens
--   ring:     the 2D portrait in the round lens
--   glyph:    the class icon in the round lens
--   key:      the 2D portrait on a rounded-square key
-- Names and GUIDs are used only when plain; a secret name falls back to the
-- class (matrix) or the class icon (monogram).
local AVATARS = {matrix = true, monogram = true, ring = true, glyph = true, key = true}
-- Events that can change the presence lamp.
local AVATAR_EVENTS = {UNIT_HEALTH = true, UNIT_CONNECTION = true, UNIT_FLAGS = true, PLAYER_FLAGS_CHANGED = true}
local IsAvatar, ShowAvatar, UpdateAvatar, AvatarStatus
do
local MATRIX = 7
local function Disc(parent, sublevel)
	local texture = parent:CreateTexture(nil, 'BORDER', nil, sublevel)
	texture:SetTexture(Kit.media..'mask-round.tga')
	return texture
end

local function Xor8(a, b)
	local result, place = 0, 1
	for _ = 1, 8 do
		local x, y = a % 2, b % 2
		if x ~= y then result = result + place end
		a, b, place = (a - x) / 2, (b - y) / 2, place * 2
	end
	return result
end

-- FNV-1a over the bytes, kept exact in doubles: the multiply by 16777619
-- (2^24 + 403) is split so no step passes 2^53.
local function Fnv(text)
	local hash = 2166136261
	for index = 1, #text do
		local low = hash % 256
		hash = hash - low + Xor8(low, text:byte(index))
		hash = ((hash % 256) * 16777216 + hash * 403) % 4294967296
	end
	return hash
end

local function Lit(hash, row, column)
	local half = column < 4 and column or MATRIX - 1 - column
	local shift = (row * 4 + half) % 31
	local bit = floor(hash / 2 ^ shift) % 2
	local inside = math.sqrt((row - 3) ^ 2 + (column - 3) ^ 2) <= 3.2
	return inside and (bit == 1 or (row == 3 and half == 3)), inside
end

local function Seed(unit)
	local name = UnitName(unit)
	if not IsSecret(name) and type(name) == 'string' and name ~= '' then return name end
	local guid = Plain(UnitGUID, unit)
	if type(guid) == 'string' then return guid end
	local _, class = UnitClass(unit)
	if not IsSecret(class) and class then return class end
	return 'SPEC-01'
end

local function Initials(unit)
	local name = UnitName(unit)
	if IsSecret(name) or type(name) ~= 'string' or name == '' then return nil end
	local letters = ''
	for word in name:gmatch('%S+') do
		local first = word:match('^[%z\1-\127\194-\244][\128-\191]*')
		if first then letters = letters..first end
		if #letters >= 2 then break end
	end
	return letters ~= '' and strupper(letters) or nil
end

local function Build(frame)
	local avatar = frame.avatar
	if avatar then return avatar end
	avatar = CreateFrame('Frame', nil, frame.portraitHolder)
	avatar:SetAllPoints(frame.portraitHolder)
	avatar:EnableMouse(false)
	-- Round: an outline, the light bezel, the colored ring, the black lens.
	avatar.outline = Disc(avatar, -4)
	avatar.outline:SetVertexColor(0, 0, 0, 0.18)
	avatar.bezel = Disc(avatar, -3)
	if avatar.bezel.SetGradient and CreateColor then
		avatar.bezel:SetGradient('VERTICAL', CreateColor(0.9, 0.9, 0.89, 1), CreateColor(1, 1, 1, 1))
	end
	avatar.ring = Disc(avatar, -2)
	avatar.lens = Disc(avatar, -1)
	if avatar.lens.SetGradient and CreateColor then
		avatar.lens:SetGradient('VERTICAL', CreateColor(0.04, 0.04, 0.04, 1), CreateColor(0.11, 0.11, 0.11, 1))
	end
	avatar.roundMask = avatar:CreateMaskTexture()
	avatar.roundMask:SetTexture(Kit.media..'mask-round.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
	avatar.roundMask:SetAllPoints(avatar.lens)
	-- Square key: a light key with a recessed screen.
	avatar.keyFrame = CreateFrame('Frame', nil, avatar)
	avatar.keyFrame:SetAllPoints()
	avatar.keyFrame.shell = Kit:Shell(avatar.keyFrame, {surface = 'paper', radius = 6, shadowAlpha = 0.25})
	avatar.keyScreen = CreateFrame('Frame', nil, avatar.keyFrame)
	avatar.keyScreen.shell = Kit:Shell(avatar.keyScreen, {surface = 'screen', radius = 4, shadow = false})
	avatar.keyMask = avatar:CreateMaskTexture()
	avatar.keyMask:SetTexture(Kit.media..'mask-icon.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
	avatar.keyMask:SetAllPoints(avatar.keyScreen)
	-- Content.
	avatar.content = CreateFrame('Frame', nil, avatar)
	avatar.content:SetAllPoints()
	avatar.content:SetFrameLevel(avatar.keyScreen:GetFrameLevel() + 2)
	avatar.picture = avatar.content:CreateTexture(nil, 'ARTWORK')
	avatar.initials = Kit:Text(avatar.content, '', 12, 'darkInk', true)
	avatar.initials:SetPoint('CENTER', avatar.lens, 'CENTER', 0, 0)
	avatar.dots = {}
	for index = 1, MATRIX * MATRIX do
		local dot = avatar.content:CreateTexture(nil, 'ARTWORK', nil, 1)
		dot:SetColorTexture(1, 1, 1, 1)
		avatar.dots[index] = dot
	end
	-- Presence lamp on the rim, in a collar of the panel's color.
	avatar.collar = Disc(avatar.content, 2)
	avatar.collar:SetDrawLayer('OVERLAY', 1)
	avatar.led = Kit:Led(avatar.content, 6, true)
	avatar:HookScript('OnSizeChanged', function() if frame.avatarStyle then UI:Safe(UpdateAvatar, frame) end end)
	frame.avatar = avatar
	return avatar
end

local function Around(texture, avatar, inset)
	texture:ClearAllPoints()
	texture:SetPoint('TOPLEFT', avatar, 'TOPLEFT', inset, -inset)
	texture:SetPoint('BOTTOMRIGHT', avatar, 'BOTTOMRIGHT', -inset, inset)
end

local function RingColor(frame)
	local mode = DB().avatarRing
	if mode == 'class' then return ClassColor(frame.unit) end
	if mode == 'key' then return Kit:RGB('lamp') end
	return ReactionColor(frame.unit)
end

function IsAvatar(mode) return AVATARS[mode] and true or false end

-- Show or hide the avatar parts for a portrait mode; returns true when one shows.
function ShowAvatar(frame, mode)
	if not AVATARS[mode] then
		if frame.avatar then frame.avatar:Hide() end
		frame.avatarStyle = nil
		return false
	end
	local avatar = Build(frame)
	frame.avatarStyle = mode
	avatar:Show()
	return true
end

function AvatarStatus(frame)
	local avatar = frame.avatar
	if not (avatar and avatar:IsShown()) then return end
	local show = DB().avatarStatus and true or false
	avatar.collar:SetShown(show)
	Kit:ShowLed(avatar.led, show)
	if not show then return end
	local unit = frame.unit
	local connected, dead = Plain(UnitIsConnected, unit), Plain(UnitIsDeadOrGhost, unit)
	if connected == false or dead == true then return Kit:SetLed(avatar.led, false) end
	local fighting = Plain(UnitAffectingCombat, unit)
	if unit == 'player' and frame.combatEvent ~= nil then fighting = frame.combatEvent end
	if fighting == true then return Kit:SetLed(avatar.led, true, 'red') end
	if Plain(UnitIsAFK, unit) == true then return Kit:SetLed(avatar.led, true, 'amber') end
	Kit:SetLed(avatar.led, true, 'ledGreen')
end

function UpdateAvatar(frame)
	local avatar, style = frame.avatar, frame.avatarStyle
	if not (avatar and style) then return end
	local unit = frame.unit
	local Px = UI.Pixel.Px
	local size = avatar:GetWidth()
	if IsSecret(size) or not size or size <= 2 then return end
	local px = Px(avatar, 1)
	local round = style ~= 'key'
	for _, part in ipairs({avatar.outline, avatar.bezel, avatar.ring, avatar.lens}) do part:SetShown(round) end
	avatar.keyFrame:SetShown(not round)
	-- Geometry.
	Around(avatar.outline, avatar, -px)
	Around(avatar.bezel, avatar, 0)
	local bezel = UI.Pixel.Snap(avatar, max(2 * px, size * 0.07))
	local ring = UI.Pixel.Snap(avatar, max(px, size * 0.045))
	Around(avatar.ring, avatar, bezel)
	Around(avatar.lens, avatar, bezel + ring)
	Kit:Tint(avatar.ring, {RingColor(frame)})
	avatar.keyScreen:ClearAllPoints()
	avatar.keyScreen:SetPoint('TOPLEFT', bezel, -bezel)
	avatar.keyScreen:SetPoint('BOTTOMRIGHT', -bezel, bezel)
	avatar.keyScreen.shell.opts.edge = {RingColor(frame)}
	Kit:PaintShell(avatar.keyScreen.shell)
	-- Content.
	local picture, initials = avatar.picture, avatar.initials
	picture:Hide()
	initials:Hide()
	for _, dot in ipairs(avatar.dots) do dot:Hide() end
	picture:RemoveMaskTexture(avatar.roundMask)
	picture:RemoveMaskTexture(avatar.keyMask)
	local mode = style
	local _, class = UnitClass(unit)
	local coords = not IsSecret(class) and class and Plain(UnitIsPlayer, unit) and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
	local letters = mode == 'monogram' and Initials(unit)
	if mode == 'monogram' and not letters then mode = coords and 'glyph' or 'ring' end
	if mode == 'glyph' and not coords then mode = 'ring' end
	if mode == 'matrix' then
		local hash = Fnv(Seed(unit))
		local lens = size - 2 * (bezel + ring)
		local pitch = max(2 * px, UI.Pixel.Snap(avatar, lens * 0.8 / MATRIX))
		local dotSize = max(px, UI.Pixel.Snap(avatar, pitch * 0.62))
		for row = 0, MATRIX - 1 do
			for column = 0, MATRIX - 1 do
				local on, inside = Lit(hash, row, column)
				local dot = avatar.dots[row * MATRIX + column + 1]
				if inside then
					dot:ClearAllPoints()
					dot:SetSize(dotSize, dotSize)
					dot:SetPoint('CENTER', avatar, 'CENTER', (column - 3) * pitch, (3 - row) * pitch)
					dot:SetVertexColor(0.957, 0.957, 0.941, on and 1 or 0.08)
					dot:Show()
				end
			end
		end
	elseif mode == 'monogram' then
		Kit:Font(initials, max(7, floor((size - 2 * (bezel + ring)) * 0.42)), nil, true)
		initials:SetText(letters)
		Kit:Tint(initials, {RingColor(frame)})
		initials:Show()
	else
		local target = round and avatar.lens or avatar.keyScreen
		picture:ClearAllPoints()
		picture:SetAllPoints(target)
		if mode == 'glyph' then
			picture:SetTexture(CLASS_ICONS)
			picture:SetTexCoord(unpack(coords))
		else
			SetPortraitTexture(picture, unit)
			picture:SetTexCoord(0.1, 0.9, 0.1, 0.9)
		end
		picture:AddMaskTexture(round and avatar.roundMask or avatar.keyMask)
		picture:Show()
	end
	-- The presence lamp on the lower rim.
	local led = max(5, floor(size * 0.18))
	avatar.led:SetSize(led, led)
	if avatar.led.glow then Kit:FitSprite(avatar.led.glow, led, led) end
	avatar.led:ClearAllPoints()
	avatar.led:SetPoint('CENTER', avatar, 'BOTTOMRIGHT', -size * 0.15, size * 0.15)
	avatar.collar:ClearAllPoints()
	avatar.collar:SetPoint('TOPLEFT', avatar.led, 'TOPLEFT', -2 * px, 2 * px)
	avatar.collar:SetPoint('BOTTOMRIGHT', avatar.led, 'BOTTOMRIGHT', 2 * px, -2 * px)
	Kit:Tint(avatar.collar, 'panel')
	AvatarStatus(frame)
end
end

local function UpdatePortrait(frame)
	local unit, mode = frame.unit, frame.portraitMode
	if IsAvatar(mode) then
		UpdateAvatar(frame)
	elseif mode == 'model' and frame.model then
		-- Draw now when we can, so a new target shows at once; else when it can.
		frame.modelToken = (frame.modelToken or 0) + 1
		if DrawModel(frame) then VerifyModel(frame, 0) else RefreshModel(frame, 1) end
	elseif mode == 'class' and frame.portrait then
		local _, class = UnitClass(unit)
		local coords = not IsSecret(class) and class and Plain(UnitIsPlayer, unit) and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
		if coords then
			frame.portrait:SetTexture(CLASS_ICONS)
			frame.portrait:SetTexCoord(unpack(coords))
		else
			SetPortraitTexture(frame.portrait, unit)
			frame.portrait:SetTexCoord(0.12, 0.88, 0.12, 0.88)
		end
	elseif mode == 'texture' and frame.portrait then
		SetPortraitTexture(frame.portrait, unit)
		frame.portrait:SetTexCoord(0.12, 0.88, 0.12, 0.88)
	end
end

-- polled: a timer refresh (target of target); the portrait is redrawn only
-- when the unit behind the frame changed, told by a plain GUID.
local function UpdateName(frame, polled)
	local unit = frame.unit
	local name = UnitName(unit)
	if IsSecret(name) then frame.nameText:SetText(name)
	else frame.nameText:SetText(name and strupper(name) or strupper(frame.layout.title)) end
	if DB().nameColor == 'class' then Kit:Tint(frame.nameText, {ClassColor(unit)}) end
	if frame.levelText then
		local ok = pcall(function()
			local level = UnitLevel(unit)
			if IsSecret(level) then frame.levelText:SetFormattedText('LV %d', level) return end
			frame.levelText:SetText((level and level > 0) and ('LV '..level) or 'LV ??')
		end)
		if not ok then frame.levelText:SetText('') end
	end
	UpdateTag(frame)
	local guid = Plain(UnitGUID, unit)
	if polled and (guid == nil or guid == frame.portraitGUID) then return end
	frame.portraitGUID = guid
	UpdatePortrait(frame)
end

local function UpdateCombat(frame, event)
	if not frame.lamp then return end
	local ok, inCombat = pcall(UnitAffectingCombat, frame.unit)
	-- Lockdown starts after PLAYER_REGEN_DISABLED fires, so trust the event first.
	if event == 'PLAYER_REGEN_DISABLED' and frame.unit == 'player' then ok, inCombat = true, true end
	if event == 'PLAYER_REGEN_ENABLED' and frame.unit == 'player' then ok, inCombat = true, false end
	Kit:SetLed(frame.lamp, ok and not IsSecret(inCombat) and inCombat or false)
	if frame.unit == 'player' then
		if event == 'PLAYER_REGEN_DISABLED' then frame.combatEvent = true
		elseif event == 'PLAYER_REGEN_ENABLED' then frame.combatEvent = false end
	end
	if frame.avatarStyle then AvatarStatus(frame) end
end

-- Indicators ------------------------------------------------------------------------
local ROLE_TEXT = {TANK = 'TNK', HEALER = 'HLR', DAMAGER = 'DPS'}

local function Chip(face, width)
	local chip = Kit:LCDPanel(face, {radius = 2})
	chip:SetSize(width, 10)
	chip.text = Kit:Text(chip, '', 6, 'lcdInk', true)
	chip.text:SetPoint('CENTER', 0.5, 0)
	chip:Hide()
	return chip
end

local function SetChip(chip, text, token)
	if not text then chip:Hide() return end
	chip.text:SetText(text)
	Kit:Tint(chip.text, token or 'lcdInk')
	chip:Show()
end

local function UpdateIndicators(frame)
	local ind, unit = Indicators(), frame.unit
	if frame.raidIcon then
		local index = ind.raidTarget and Plain(GetRaidTargetIndex, unit)
		if index and SetRaidTargetIconTexture then
			SetRaidTargetIconTexture(frame.raidIcon, index)
			frame.raidIcon:Show()
		else
			frame.raidIcon:Hide()
		end
	end
	if not frame.roleChip then return end
	local role = ind.role and Plain(UnitGroupRolesAssigned, unit)
	SetChip(frame.roleChip, role and ROLE_TEXT[role])
	SetChip(frame.leadChip, ind.leader and Plain(UnitIsGroupLeader, unit) == true and 'LD' or nil)
	-- One status chip: a ready check answer, then a summon, then a resurrection.
	local status, token
	if ind.readyCheck and (frame.readyShown or 0) > GetTime() then
		local answer = Plain(GetReadyCheckStatus, unit)
		if answer == 'ready' then status, token = 'RDY', 'green'
		elseif answer == 'notready' then status, token = 'NO', 'red'
		elseif answer == 'waiting' then status, token = '...', 'amber' end
	end
	if not status and ind.summon and C_IncomingSummon and Plain(C_IncomingSummon.HasIncomingSummon, unit) == true then
		local state = Plain(C_IncomingSummon.IncomingSummonStatus, unit)
		local enum = Enum and Enum.SummonStatus
		if enum and state == enum.Accepted then status, token = 'SUM', 'green'
		elseif enum and state == enum.Declined then status, token = 'SUM', 'red'
		else status, token = 'SUM', 'blue' end
	end
	if not status and ind.resurrect and Plain(UnitHasIncomingResurrection, unit) == true then status, token = 'RES', 'green' end
	SetChip(frame.statusChip, status, token)
	-- The chips line up along the top edge, left to right.
	local previous
	for _, chip in ipairs({frame.roleChip, frame.leadChip, frame.statusChip}) do
		chip:ClearAllPoints()
		if previous then chip:SetPoint('LEFT', previous, 'RIGHT', 3, 0)
		else chip:SetPoint('CENTER', frame.face, 'TOPLEFT', 7 + chip:GetWidth() / 2, 0) end
		if chip:IsShown() then previous = chip end
	end
	if frame.outline then
		local target = ind.targetOutline and Plain(UnitIsUnit, unit, 'target') == true
		frame.outline:SetShown(target and true or false)
	end
end

-- Status lamps -------------------------------------------------------------------------
-- SPEC-01 glyphs for the unit's state, lit in their color while it holds:
-- combat, resting (you only), group leader, role and PvP. 'lit' shows only the
-- lit ones; 'panel' prints every glyph and leaves the idle ones unlit, like a
-- device's status row. Combat may be secret: its glyph is then lit straight
-- from the answer (SetAlphaFromBoolean), never tested.
-- Kept in a block of its own: the main chunk may hold at most 200 locals.
local STATUS_EVENTS, StatusMode, UpdateStatus, PlaceStatus
do
local STATUS = {
	{key = 'combat', icon = 'warning', token = 'red'},
	{key = 'rest', icon = 'pause', token = 'ledGreen', player = true},
	{key = 'lead', icon = 'tri-up', token = 'amber'},
	{key = 'role', icon = 'user', token = 'ledBlue'},
	{key = 'pvp', icon = 'power', token = 'red'},
}
local ROLE_TOKENS = {TANK = 'ledBlue', HEALER = 'ledGreen', DAMAGER = 'red'}
STATUS_EVENTS = {UNIT_FLAGS = true, UNIT_FACTION = true, PLAYER_UPDATE_RESTING = true, PLAYER_FLAGS_CHANGED = true,
	PARTY_LEADER_CHANGED = true, PLAYER_ROLES_ASSIGNED = true, GROUP_ROSTER_UPDATE = true,
	PLAYER_REGEN_DISABLED = true, PLAYER_REGEN_ENABLED = true}

function StatusMode(frame)
	if frame.layout.size ~= 'large' then return 'off' end
	if frame.shapeName == 'console' then return 'panel' end
	return Cfg(frame).status or 'off'
end

local function StatusRow(frame)
	local row = frame.status
	if row then return row end
	row = CreateFrame('Frame', nil, frame.overlay)
	row:EnableMouse(false)
	row:SetSize(64, 9)
	row.size, row.grow, row.icons = 9, 'RIGHT', {}
	for _, info in ipairs(STATUS) do
		if not info.player or frame.unit == 'player' then
			local icon = Kit:Icon(row, info.icon, 9, 'ledOff')
			row.icons[#row.icons + 1] = {texture = icon, info = info}
		end
	end
	frame.status = row
	return row
end

-- A plain true/false, or a secret (combat only); role also returns the role.
local function StatusValue(frame, key)
	local unit = frame.unit
	if key == 'combat' then
		if unit == 'player' and frame.combatEvent ~= nil then return frame.combatEvent end
		local ok, value = pcall(UnitAffectingCombat, unit)
		if not ok then return false end
		return value
	elseif key == 'rest' then
		return Plain(IsResting) == true
	elseif key == 'lead' then
		return Plain(UnitIsGroupLeader, unit) == true
	elseif key == 'role' then
		local role = Plain(UnitGroupRolesAssigned, unit)
		return (role and ROLE_TOKENS[role]) and true or false, role
	elseif key == 'pvp' then
		return Plain(UnitIsPVP, unit) == true or Plain(UnitIsPVPFreeForAll, unit) == true
	end
	return false
end

function UpdateStatus(frame)
	local mode = StatusMode(frame)
	local row = frame.status
	if mode == 'off' then
		if row then row:Hide() end
		return
	end
	row = StatusRow(frame)
	row:Show()
	local size, gap, grow = row.size, 3, row.grow
	local from, to = grow == 'LEFT' and 'RIGHT' or 'LEFT', grow == 'LEFT' and 'LEFT' or 'RIGHT'
	local previous
	for _, entry in ipairs(row.icons) do
		local icon, info = entry.texture, entry.info
		local value, role = StatusValue(frame, info.key)
		local token = (info.key == 'role' and role and ROLE_TOKENS[role]) or info.token
		local shown
		if IsSecret(value) then
			Kit:Tint(icon, token)
			if icon.SetAlphaFromBoolean then icon:SetAlphaFromBoolean(value, 1, mode == 'panel' and 0.3 or 0) end
			shown = true
		else
			local lit = value == true
			Kit:Tint(icon, lit and token or 'ledOff')
			icon:SetAlpha(lit and 1 or 0.75)
			shown = lit or mode == 'panel'
		end
		icon:ClearAllPoints()
		icon:SetShown(shown)
		if shown then
			icon:SetSize(size, size)
			if previous then icon:SetPoint(from, previous, to, grow == 'LEFT' and -gap or gap, 0)
			else icon:SetPoint(from, row, from, 0, 0) end
			previous = icon
		end
	end
end

-- Where the row sits: point on the row, the region and its point, and which way it grows.
function PlaceStatus(frame, point, region, relative, x, y, grow, size)
	if StatusMode(frame) == 'off' then
		if frame.status then frame.status:Hide() end
		return
	end
	local row = StatusRow(frame)
	row.size, row.grow = size or 9, grow or 'RIGHT'
	row:SetSize(5 * ((size or 9) + 3), size or 9)
	row:ClearAllPoints()
	row:SetPoint(point, region, relative, x or 0, y or 0)
	row:SetFrameLevel(frame.overlay:GetFrameLevel() + 2)
	UpdateStatus(frame)
end

end
-- Auras --------------------------------------------------------------------------------
-- Aura fields may be secret: only the data table itself is tested, the icon goes
-- straight to SetTexture, a secret stack count is formatted by the client, and
-- the timer runs from the client's duration object.
local function AuraCount(unit, data)
	local count = data.applications
	if IsSecret(count) then
		if C_UnitAuras.GetAuraApplicationDisplayCount and not IsSecret(data.auraInstanceID) then
			return C_UnitAuras.GetAuraApplicationDisplayCount(unit, data.auraInstanceID, 2, 99)
		end
		return ''
	end
	return count and count > 1 and count or ''
end

-- The timer line over a key runs on the same duration object (the client moves
-- it); without one, a plain expiry drives it at 10 Hz. An aura known to last
-- forever has no line; a secret length keeps it.
local function AuraTimer(icon, unit, data)
	local cooldown, line = icon.cooldown, icon.line
	local lines = DB().auraLines
	local id = data.auraInstanceID
	local length = data.duration
	local permanent = not IsSecret(length) and (not length or length <= 0)
	line:SetScript('OnUpdate', nil)
	if C_UnitAuras.GetAuraDuration and cooldown.SetCooldownFromDurationObject and not IsSecret(id) then
		local ok, duration = pcall(C_UnitAuras.GetAuraDuration, unit, id)
		if ok and duration then
			cooldown:SetCooldownFromDurationObject(duration)
			if lines and not permanent and line.SetTimerDuration and TIMER then
				line:SetTimerDuration(duration, IMMEDIATE, TIMER.RemainingTime)
				line:SetAlpha(1)
				-- A secret length may still be an aura that lasts forever: the
				-- duration says so itself, and that answer only reaches alpha.
				if IsSecret(length) and duration.IsZero and line.SetAlphaFromBoolean then
					local okZero, zero = pcall(duration.IsZero, duration)
					if okZero then
						if IsSecret(zero) then line:SetAlphaFromBoolean(zero, 0, 1)
						elseif zero then line:SetAlpha(0) end
					end
				end
				line:Show()
			else
				line:Hide()
			end
			return
		end
	end
	local expires = data.expirationTime
	if IsSecret(expires) or IsSecret(length) or not expires or not length or length <= 0 then
		cooldown:Clear()
		line:Hide()
		return
	end
	cooldown:SetCooldown(expires - length, length)
	if not lines then line:Hide() return end
	line:SetMinMaxValues(0, length)
	local wait = 1
	line:SetScript('OnUpdate', function(self, elapsed)
		wait = wait + elapsed
		if wait < 0.1 then return end
		wait = 0
		self:SetValue(max(expires - GetTime(), 0))
	end)
	line:Show()
end

-- The line's color: the debuff's type, a plain red for other harm, green for help.
local function PaintAuraLine(icon, data, harmful)
	if not harmful then icon.line:SetStatusBarColor(Kit:RGB('green')) return end
	local kind = data.dispelName
	local color = not IsSecret(kind) and kind and DebuffTypeColor and DebuffTypeColor[kind]
	if color then icon.line:SetStatusBarColor(color.r, color.g, color.b)
	else icon.line:SetStatusBarColor(Kit:RGB('red')) end
end

local function AuraKey(frame, index)
	local icon = CreateFrame('Frame', nil, frame.face)
	icon.shell = Kit:Shell(icon, {surface = 'glass', radius = 4, shadowAlpha = 0.25})
	icon.texture = icon:CreateTexture(nil, 'ARTWORK')
	icon.texture:SetPoint('TOPLEFT', 2, -2)
	icon.texture:SetPoint('BOTTOMRIGHT', -2, 2)
	icon.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	icon.mask = icon:CreateMaskTexture()
	icon.mask:SetTexture(Kit.media..'mask-icon.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
	icon.mask:SetAllPoints(icon.texture)
	icon.texture:AddMaskTexture(icon.mask)
	icon.cooldown = CreateFrame('Cooldown', nil, icon, 'CooldownFrameTemplate')
	icon.cooldown:SetAllPoints(icon.texture)
	if icon.cooldown.SetDrawEdge then icon.cooldown:SetDrawEdge(false) end
	if icon.cooldown.SetSwipeTexture then icon.cooldown:SetSwipeTexture(Kit.media..'mask-icon.tga', 0, 0, 0, 0.7) end
	icon.count = Kit:Text(icon, '', 'small', 'white', true, true)
	icon.count:SetPoint('BOTTOMRIGHT', 2, -1)
	icon.count:SetDrawLayer('OVERLAY', 7)
	-- The timer line riding just above the key.
	icon.line = CreateFrame('StatusBar', nil, icon)
	icon.line:SetPoint('BOTTOMLEFT', icon, 'TOPLEFT', 2, 1)
	icon.line:SetPoint('BOTTOMRIGHT', icon, 'TOPRIGHT', -2, 1)
	icon.line:SetHeight(2)
	icon.line:SetStatusBarTexture([[Interface\Buttons\WHITE8X8]])
	icon.line:SetMinMaxValues(0, 1)
	icon.line.back = icon.line:CreateTexture(nil, 'BACKGROUND')
	icon.line.back:SetAllPoints()
	icon.line.back:SetColorTexture(0, 0, 0, 0.45)
	icon.line:Hide()
	icon:Hide()
	frame.auras[index] = icon
	return icon
end

-- How far below the frame its auras start: past a cast bar placed under it and
-- the class resource rail.
local function BelowOffset(frame)
	local offset = 6
	local castCfg = DB().cast[frame.unit]
	if casts[frame.unit] and castCfg and castCfg.position == 'under' then offset = offset + (castCfg.height or 30) + 6 end
	if frame.lampRail and Cfg(frame).classPower then offset = offset + (Cfg(frame).lampSize or 6) + 12 end
	return offset
end

-- The cooldown's own countdown, small and fitted: mono numbers with an
-- outline, along the key's foot so a long time ("49m", "1h") stays inside.
-- The client may re-apply the cooldown's countdown font object, so that object
-- is ours too: one per size, in the reference's bold mono with an outline.
local clockFonts = {}
local function AuraClock(icon, cfg, size)
	local cooldown = icon.cooldown
	local fontSize = min(cfg.auraTimeSize or 8, max(6, floor(size * 0.5)))
	if cooldown.SetCountdownFont and CreateFont then
		local name = 'JiberishSpec01AuraClock'..fontSize
		local font = clockFonts[fontSize] or _G[name] or CreateFont(name)
		font:SetFont(Kit:FontPath(true), fontSize, 'OUTLINE')
		clockFonts[fontSize] = font
		pcall(cooldown.SetCountdownFont, cooldown, name)
	end
	local text = cooldown.GetCountdownFontString and cooldown:GetCountdownFontString()
	if not text then return end
	Kit:Font(text, fontSize, 'OUTLINE', true)
	text:SetShadowOffset(0, 0)
	text:ClearAllPoints()
	text:SetPoint('BOTTOM', icon, 'BOTTOM', 0, 1)
	text:SetJustifyH('CENTER')
	text:SetTextColor(1, 1, 1)
end

local function LayoutAuras(frame)
	local cfg = Cfg(frame)
	local count = (DB().auras and cfg.auras) and max(0, min(cfg.auraMax or 8, 40)) or 0
	frame.auras = frame.auras or {}
	for index = #frame.auras + 1, count do AuraKey(frame, index) end
	local size, gap = cfg.auraSize or 22, 4
	local perRow = max(1, cfg.auraPerRow or 8)
	local position, leftward = cfg.auraPosition or 'below', cfg.auraGrow == 'left'
	local below = BelowOffset(frame)
	for index, icon in ipairs(frame.auras) do
		icon:SetSize(size, size)
		Kit:Font(icon.count, cfg.stackSize or 10, nil, true)
		if icon.cooldown.SetHideCountdownNumbers then icon.cooldown:SetHideCountdownNumbers(not cfg.auraTime) end
		AuraClock(icon, cfg, size)
		if icon.cooldown.SetDrawSwipe then icon.cooldown:SetDrawSwipe(cfg.auraSwipe and true or false) end
		local column, row = (index - 1) % perRow, floor((index - 1) / perRow)
		local x, y = column * (size + gap), row * (size + gap)
		icon:ClearAllPoints()
		if position == 'above' then
			if leftward then icon:SetPoint('BOTTOMRIGHT', frame.face, 'TOPRIGHT', -x, 6 + y)
			else icon:SetPoint('BOTTOMLEFT', frame.face, 'TOPLEFT', x, 6 + y) end
		elseif position == 'right' then
			icon:SetPoint('TOPLEFT', frame.face, 'TOPRIGHT', 6 + x, -y)
		elseif position == 'left' then
			icon:SetPoint('TOPRIGHT', frame.face, 'TOPLEFT', -6 - x, -y)
		else
			if leftward then icon:SetPoint('TOPRIGHT', frame.face, 'BOTTOMRIGHT', -x, -below - y)
			else icon:SetPoint('TOPLEFT', frame.face, 'BOTTOMLEFT', x, -below - y) end
		end
		if index > count then icon:Hide() end
	end
	frame.auraCount = count
end

local function UpdateDispel(frame)
	if not frame.dispel then return end
	if not Indicators().dispel or not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then frame.dispel:Hide() return end
	local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, frame.unit, 1, 'HARMFUL|RAID')
	if not ok or type(data) ~= 'table' then frame.dispel:Hide() return end
	local kind = data.dispelName
	local color = not IsSecret(kind) and kind and DebuffTypeColor and DebuffTypeColor[kind]
	if color then frame.dispel:SetVertexColor(color.r, color.g, color.b, 0.95)
	else frame.dispel:SetVertexColor(0.64, 0.19, 0.79, 0.95) end
	frame.dispel:Show()
end

local function UpdateAuras(frame)
	UpdateDispel(frame)
	if not frame.auras or not C_UnitAuras or not C_UnitAuras.GetAuraDataByIndex then return end
	local cfg = Cfg(frame)
	local count = frame.auraCount or 0
	local slot = 1
	local filters = {}
	if cfg.debuffs then filters[#filters + 1] = cfg.onlyMine and 'HARMFUL|PLAYER' or 'HARMFUL' end
	if cfg.buffs then filters[#filters + 1] = cfg.onlyMine and 'HELPFUL|PLAYER' or 'HELPFUL' end
	for _, filter in ipairs(filters) do
		for index = 1, 40 do
			if slot > count then break end
			local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, frame.unit, index, filter)
			if not ok or type(data) ~= 'table' then break end
			-- Boss auras only: a secret answer counts as no.
			local boss = data.isBossAura
			if not cfg.bossOnly or (not IsSecret(boss) and boss) then
				local icon = frame.auras[slot]
				icon.texture:SetTexture(data.icon)
				local countOk, stack = pcall(AuraCount, frame.unit, data)
				if countOk then icon.count:SetText(stack) else icon.count:SetText('') end
				if not pcall(AuraTimer, icon, frame.unit, data) then icon.cooldown:Clear(); icon.line:Hide() end
				local harmful = filter:find('HARMFUL') and true or false
				pcall(PaintAuraLine, icon, data, harmful)
				local surface = harmful and 'glass' or 'paper'
				if icon.surface ~= surface then
					icon.surface = surface
					Kit:SetSurface(icon.shell, surface)
				end
				icon:Show()
				slot = slot + 1
			end
		end
	end
	for index = slot, #frame.auras do frame.auras[index]:Hide() end
end

local function UpdateAll(frame, polled)
	if not UnitExists(frame.unit) then return end
	UpdateName(frame, polled)
	UpdateHealth(frame)
	UpdatePower(frame)
	UpdateAuras(frame)
	UpdateCombat(frame)
	UpdateIndicators(frame)
	if frame.status then UpdateStatus(frame) end
end

-- Range ---------------------------------------------------------------------------------
-- Group members: the client's range answer, straight into the alpha. Hostile
-- units: a known ranged spell of the class. Others stay at full alpha.
-- Kept in a block of its own: the main chunk may hold at most 200 locals.
local FindRangeSpell, UpdateRangeDriver
do
local RANGE_SPELLS = {
	DEATHKNIGHT = {47541, 49576}, DEMONHUNTER = {185123}, DRUID = {8921, 5176}, EVOKER = {361469}, HUNTER = {185358, 75},
	MAGE = {116, 133, 30451}, MONK = {117952, 115546}, PALADIN = {20271, 62124}, PRIEST = {589, 585}, ROGUE = {185763, 114014},
	SHAMAN = {188196, 403}, WARLOCK = {686, 232670}, WARRIOR = {355, 57755},
}
local rangeSpell
function FindRangeSpell()
	rangeSpell = nil
	local _, class = UnitClass('player')
	for _, id in ipairs(RANGE_SPELLS[class] or {}) do
		local known = (C_SpellBook and Plain(C_SpellBook.IsSpellKnown, id)) or Plain(IsSpellKnown, id)
		if known then rangeSpell = id return end
	end
end

local function Fade(frame, inRange, alpha)
	frame.ranged = true
	if IsSecret(inRange) then
		if frame.SetAlphaFromBoolean then pcall(frame.SetAlphaFromBoolean, frame, inRange, 1, alpha) end
		return
	end
	frame:SetAlpha(inRange and 1 or alpha)
end

local function ApplyRange(frame)
	local unit, alpha = frame.unit, Cfg(frame).rangeAlpha or 0.45
	-- The console hides docked frames in pet battles by alpha; leave them be.
	if C_PetBattles and Plain(C_PetBattles.IsInBattle) then return end
	if Plain(UnitExists, unit) ~= true then return end
	local grouped = frame.layout.party or Plain(UnitInParty, unit) or Plain(UnitInRaid, unit)
	if grouped and UnitInRange then
		local inRange, checked = UnitInRange(unit)
		if not IsSecret(checked) and not checked then return Fade(frame, true, alpha) end
		return Fade(frame, inRange, alpha)
	end
	if rangeSpell and C_Spell and C_Spell.IsSpellInRange and Plain(UnitCanAttack, 'player', unit) then
		local ok, inRange = pcall(C_Spell.IsSpellInRange, rangeSpell, unit)
		if ok and (IsSecret(inRange) or inRange ~= nil) then return Fade(frame, inRange, alpha) end
	end
	Fade(frame, true, alpha)
end

local rangeDriver = CreateFrame('Frame')
local rangeElapsed = 0
local function RangeTick(_, delta)
	rangeElapsed = rangeElapsed + delta
	if rangeElapsed < 0.2 then return end
	rangeElapsed = 0
	for _, frame in ipairs(ordered) do
		if Cfg(frame).rangeFade then
			if frame:IsVisible() then UI:Safe(ApplyRange, frame) end
		elseif frame.ranged then
			frame.ranged = nil
			frame:SetAlpha(1)
		end
	end
end

function UpdateRangeDriver()
	local any = false
	for _, frame in ipairs(ordered) do
		if Cfg(frame).rangeFade or frame.ranged then any = true break end
	end
	rangeDriver:SetScript('OnUpdate', any and RangeTick or nil)
end
end

-- Motion -------------------------------------------------------------------------------
-- A target arriving from nothing (never on a swap): the frame fades in, its bars
-- glide up from zero, and the portrait swells about 10% past full and settles.
-- Only this addon's own inner pieces move, so it is safe in combat.
local function Arrive(frame)
	if not DB().arrive or not Cfg(frame).arrive or Kit:DB().reduceMotion then return end
	frame.face:SetAlpha(0)
	Kit:FadeTo(frame.face, 1, 'NORMAL')
	frame.health:SetValue(0, IMMEDIATE)
	if frame.power then frame.power:SetValue(0, IMMEDIATE) end
	C_Timer.After(0, function() UI:Safe(UpdateHealth, frame); UI:Safe(UpdatePower, frame) end)
	-- The pop scales the portrait; a 3D model drawn mid-scale renders off-centre,
	-- so a model only fades in (the face fade above) and is drawn at full size.
	if frame.portraitHolder and frame.portraitSlot:IsShown() and frame.portraitMode ~= 'model' then
		local holder = frame.portraitHolder
		Kit:Animate(holder, 0.4, 0, 1, function(e)
			holder:SetScale(max(0.6 + 0.4 * (e + 0.1 * sin(pi * e)), 0.01))
		end, function() holder:SetScale(1) end, 'linear')
	end
end

-- A light runs along the top edge of each frame as combat starts (key color,
-- quick) and ends (amber, slower), one frame after another.
local function Sweep(frame, token, duration, peak)
	local light = frame.sweep
	if not light or not frame:IsVisible() or not Cfg(frame).sweep then return end
	local width = frame:GetWidth()
	Kit:Tint(light, token)
	Kit:Animate(light, duration, 0, 1, function(t)
		light:ClearAllPoints()
		light:SetPoint('CENTER', frame.face, 'TOPLEFT', -20 + (width + 40) * Kit.ease.cubic(t), -1)
		local alpha = t < 0.15 and t / 0.15 or t > 0.75 and (1 - t) / 0.25 or 1
		light:SetAlpha(alpha * peak)
	end, function() light:SetAlpha(0) end, 'linear')
end

-- The combat cue module marks combat itself; while it is on, this light stands down.
local function CueTraces()
	local cue = UI.db.combatcue
	return type(cue) == 'table' and cue.enable and true or false
end

local function SweepAll(token, duration, peak)
	if not DB().combatSweep or Kit:DB().reduceMotion or CueTraces() then return end
	for index, frame in ipairs(ordered) do
		C_Timer.After(min((index - 1) * 0.035, 0.5), function() Sweep(frame, token, duration, peak) end)
	end
end

-- Construction ----------------------------------------------------------------------------
-- Health and power meters: the reference's LED meter, its slider's pill, or a
-- flat bar on a charcoal plate. Each is a native StatusBar.
-- Kept in a block of its own: the main chunk may hold at most 200 locals.
local MaskFill, Gradient, ApplyFill, ApplyTrack, ApplyLooks
do
local STRETCHED = Enum and Enum.UITextureSliceMode and Enum.UITextureSliceMode.Stretched

function MaskFill(bar, file, margin)
	local mask = bar:CreateMaskTexture()
	mask:SetTexture(Kit.media..file..'.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
	if mask.SetTextureSliceMargins then
		mask:SetTextureSliceMargins(margin, margin, margin, margin)
		if STRETCHED and mask.SetTextureSliceMode then mask:SetTextureSliceMode(STRETCHED) end
	end
	mask:SetAllPoints(bar)
	bar:GetStatusBarTexture():AddMaskTexture(mask)
	bar.fillMask = mask -- the fill looks below share it
	if mask.SetScale then
		local function Fit(_, _, height)
			-- Check for a secret first: comparing one is an error.
			if IsSecret(height) or not height or height <= 0 then return end
			mask:SetScale(file == 'mask-pill' and height / (2 * margin) or 2 / margin)
		end
		bar:HookScript('OnSizeChanged', Fit)
		Fit(nil, nil, bar:GetHeight())
	end
end

-- Fill looks ----------------------------------------------------------------------
-- A meter's fill can be flat, solid, glossed, shaded, glassy or segmented, or
-- any LibSharedMedia status bar texture. The light and shade are textures
-- anchored to the fill texture itself, so the client carries them with the
-- fill and no value is ever read. Pill and bar meters clip them with the
-- fill's own mask. The track behind can be the meter's housing, a black
-- screen, a dim wash of the fill's color, or nothing. Shared with the raid,
-- boss and arena frames through UI.BarLooks.
local LSM = LibStub and LibStub('LibSharedMedia-3.0', true)
local SOLID = [[Interface\Buttons\WHITE8X8]]
local FILL_ITEMS = {{'flat', 'Flat'}, {'solid', 'Solid'}, {'gloss', 'Gloss'}, {'gradient', 'Gradient'}, {'glass', 'Glass'},
	{'striped', 'Segmented'}}
local TRACK_ITEMS = {{'default', 'Housing'}, {'screen', 'Black'}, {'dim', 'Dim fill'}, {'custom', 'Custom'}, {'clear', 'None'}}

local function FillItems(withDefault)
	local items = {}
	if withDefault then items[1] = {'default', 'Page default'} end
	for _, item in ipairs(FILL_ITEMS) do items[#items + 1] = item end
	if LSM and LSM.List then
		local ok, names = pcall(LSM.List, LSM, 'statusbar')
		if ok and type(names) == 'table' then
			for _, name in ipairs(names) do items[#items + 1] = {'lsm:'..name, name} end
		end
	end
	return items
end

local function FillFile(look)
	if look == 'solid' then return SOLID end
	if type(look) == 'string' and look:sub(1, 4) == 'lsm:' and LSM and LSM.Fetch then
		local ok, path = pcall(LSM.Fetch, LSM, 'statusbar', look:sub(5), true)
		if ok and type(path) == 'string' then return path end
	end
	return Kit.media..'bar-flat.tga'
end

-- A light or shade texture over the fill, clipped like the fill.
local function LookPart(bar, name, sublevel)
	local parts = bar.lookParts
	if not parts then parts = {}; bar.lookParts = parts end
	local part = parts[name]
	if not part then
		part = bar:CreateTexture(nil, 'ARTWORK', nil, sublevel or 2)
		part:SetColorTexture(1, 1, 1, 1)
		if bar.fillMask then part:AddMaskTexture(bar.fillMask) end
		parts[name] = part
	end
	part:ClearAllPoints()
	part:Show()
	return part
end

function Gradient(texture, orientation, r1, g1, b1, a1, r2, g2, b2, a2)
	texture:SetColorTexture(1, 1, 1, 1)
	if texture.SetGradient and CreateColor then
		texture:SetGradient(orientation, CreateColor(r1, g1, b1, a1), CreateColor(r2, g2, b2, a2))
	else
		texture:SetColorTexture(r2, g2, b2, (a1 + a2) / 2)
	end
end

-- Segment gaps: hairlines across the whole meter in the track's black, every
-- few units, so the fill reads as a row of cells.
local function Segment(bar)
	local lines = bar.lookLines
	if not lines then lines = {}; bar.lookLines = lines end
	local count = 0
	local width = bar:GetWidth()
	if bar.look == 'striped' and not bar.kitPerforated and not IsSecret(width) and width and width > 0 then
		local px = UI.Pixel.Px(bar, 1)
		local step = max(UI.Pixel.Snap(bar, 6), 3 * px)
		count = min(floor(width / step), 96)
		for index = 1, count do
			local line = lines[index]
			if not line then
				line = bar:CreateTexture(nil, 'ARTWORK', nil, 4)
				line:SetColorTexture(0, 0, 0, 0.8)
				lines[index] = line
			end
			line:ClearAllPoints()
			line:SetWidth(px)
			line:SetPoint('TOPLEFT', bar, 'TOPLEFT', index * step, 0)
			line:SetPoint('BOTTOMLEFT', bar, 'BOTTOMLEFT', index * step, 0)
			line:Show()
		end
	end
	for index = count + 1, #lines do lines[index]:Hide() end
end

function ApplyFill(bar, look)
	if not bar then return end
	look = look or 'flat'
	bar.look = look
	local fill = bar:GetStatusBarTexture()
	if not fill then return end
	-- A dot meter keeps its plain fill: the dots are its look.
	if not bar.kitPerforated then
		local file = FillFile(look)
		if bar.lookFile ~= file then
			bar.lookFile = file
			fill:SetTexture(file)
		end
	end
	local px = UI.Pixel.Px(bar, 1)
	local used = {}
	if look == 'gloss' then
		local high = LookPart(bar, 'high')
		high:SetPoint('TOPLEFT', fill, 'TOPLEFT')
		high:SetPoint('BOTTOMRIGHT', fill, 'RIGHT')
		Gradient(high, 'VERTICAL', 1, 1, 1, 0.03, 1, 1, 1, 0.36)
		used.high = true
	elseif look == 'gradient' then
		local shade = LookPart(bar, 'shade')
		shade:SetAllPoints(fill)
		Gradient(shade, 'HORIZONTAL', 0, 0, 0, 0.55, 0, 0, 0, 0)
		used.shade = true
	elseif look == 'glass' then
		local sheen = LookPart(bar, 'sheen')
		sheen:SetPoint('TOPLEFT', fill, 'TOPLEFT')
		sheen:SetPoint('BOTTOMRIGHT', fill, 'RIGHT')
		sheen:SetColorTexture(1, 1, 1, 0.12)
		local lit = LookPart(bar, 'lit', 3)
		lit:SetPoint('TOPLEFT', fill, 'TOPLEFT')
		lit:SetPoint('TOPRIGHT', fill, 'TOPRIGHT')
		lit:SetHeight(px)
		lit:SetColorTexture(1, 1, 1, 0.5)
		local low = LookPart(bar, 'low', 3)
		low:SetPoint('BOTTOMLEFT', fill, 'BOTTOMLEFT')
		low:SetPoint('BOTTOMRIGHT', fill, 'BOTTOMRIGHT')
		low:SetHeight(px)
		low:SetColorTexture(0, 0, 0, 0.4)
		used.sheen, used.lit, used.low = true, true, true
	end
	for name, part in pairs(bar.lookParts or {}) do
		if not used[name] then part:Hide() end
	end
	if not bar.lookHooked then
		bar.lookHooked = true
		bar:HookScript('OnSizeChanged', function(self) UI:Safe(Segment, self) end)
	end
	Segment(bar)
end

-- The dim wash follows the fill's color; the color may be secret, so it is
-- handed straight to the setter.
local function FollowColor(bar, r, g, b)
	local dim = bar.lookDim
	if dim and dim:IsShown() then pcall(dim.SetVertexColor, dim, r, g, b) end
end

function ApplyTrack(bar, track)
	local shell = bar and bar.track and bar.track.shell
	if not shell then return end
	local base = bar.trackBase
	if not base then
		base = {surface = shell.opts.surface, fill = shell.opts.fill}
		bar.trackBase = base
	end
	track = track or 'default'
	-- A dot meter needs its housing color between the dots.
	if bar.kitPerforated and track == 'clear' then track = 'default' end
	local black = track == 'screen' or track == 'dim'
	local custom = track == 'custom'
	if black then shell.opts.surface, shell.opts.fill, shell.opts.alpha = 'screen', nil, nil
	elseif custom then
		-- Your own color and opacity, on a screen-style track.
		local color = DB().trackColor
		shell.opts.surface = 'screen'
		shell.opts.fill = type(color) == 'table' and {RGB(color)} or nil
		shell.opts.alpha = DB().trackAlpha or 1
	else shell.opts.surface, shell.opts.fill, shell.opts.alpha = base.surface, base.fill, nil end
	Kit:PaintShell(shell)
	shell:SetAlpha(track == 'clear' and 0 or 1)
	if bar.kitCover and bar.coverToken then
		Kit:Tint(bar.kitCover, (black and 'black') or (custom and shell.opts.fill) or bar.coverToken)
	end
	local dim = bar.lookDim
	if track == 'dim' then
		if not dim then
			dim = bar:CreateTexture(nil, 'BACKGROUND', nil, 2)
			dim:SetAllPoints(bar)
			dim:SetColorTexture(1, 1, 1, 1)
			if bar.fillMask then dim:AddMaskTexture(bar.fillMask) end
			bar.lookDim = dim
			hooksecurefunc(bar, 'SetStatusBarColor', FollowColor)
		end
		dim:SetAlpha(0.22)
		dim:Show()
		FollowColor(bar, bar:GetStatusBarColor())
	elseif dim then
		dim:Hide()
	end
end

UI.BarLooks = {FillItems = FillItems, TrackItems = TRACK_ITEMS, ApplyFill = ApplyFill, ApplyTrack = ApplyTrack}

-- A frame's own choice, else the page's.
local function LookOf(frame, field)
	local value = Cfg(frame)[field]
	if value == 'default' or not value then value = DB()[field] end
	return value
end

function ApplyLooks(frame)
	local track = LookOf(frame, 'track')
	ApplyFill(frame.health, LookOf(frame, 'healthTexture'))
	ApplyTrack(frame.health, track)
	if frame.power then
		local look = LookOf(frame, 'powerTexture')
		-- The console faceplate lights its power as segments unless told otherwise.
		if frame.shapeName == 'console' and look == 'flat' then look = 'striped' end
		ApplyFill(frame.power, look)
		ApplyTrack(frame.power, track)
	end
end

end
local function BarStyle(layout)
	local style = DB().units[layout.key].barStyle
	if style == 'default' or not style then style = DB().barStyle or 'dots' end
	return style
end

local function Meter(parent, height, onDark, style)
	local track = CreateFrame('Frame', nil, parent)
	local inset = style == 'bar' and 1 or 2
	track:SetHeight(height + inset * 2)
	track.shell = Kit:Shell(track, {surface = (style == 'bar' or onDark) and 'glass' or 'lcd', radius = style == 'bar' and 2 or 99,
		shadow = false, fill = (style ~= 'bar' and not onDark) and 'track' or nil})
	local bar = CreateFrame('StatusBar', nil, track)
	bar:SetPoint('TOPLEFT', style == 'dots' and 3 or inset, -inset)
	bar:SetPoint('BOTTOMRIGHT', style == 'dots' and -3 or -inset, inset)
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(1)
	if style == 'dots' then
		bar:SetStatusBarTexture([[Interface\Buttons\WHITE8X8]])
		bar.coverToken = (onDark and 'glass') or 'track'
		Kit:Perforate(bar, bar.coverToken, onDark and 'darkEdge' or nil)
	else
		bar:SetStatusBarTexture(Kit.media..'bar-flat.tga')
		MaskFill(bar, style == 'pill' and 'mask-pill' or 'mask-bar', style == 'pill' and 15 or 5)
	end
	MarkBar(bar)
	bar.track, bar.inset = track, inset
	return bar
end

-- The portrait: a black display holding a 3D model or a 2D face (made when first
-- chosen), in a holder that scales about its centre for the arrival pop.
local function Portrait(frame, parent)
	-- A fixed slot holds the layout; the holder inside it scales about its centre.
	local slot = CreateFrame('Frame', nil, parent)
	slot:SetSize(34, 34)
	local holder = CreateFrame('Frame', nil, slot)
	holder:SetAllPoints(slot)
	local screen = Kit:Screen(holder, {inset = 2, radius = 5, shadow = false})
	screen:SetAllPoints(holder)
	frame.portraitSlot, frame.portraitHolder, frame.portraitScreen = slot, holder, screen
	return slot
end

local function PortraitMode(frame)
	local mode = Cfg(frame).portrait
	if mode == 'default' or not mode then
		local page = DB().portrait
		local valid = page == 'model' or page == 'texture' or page == 'class' or IsAvatar(page)
		mode = frame.layout.size == 'large' and (valid and page or 'texture') or 'off'
	end
	return mode
end

-- Shows the chosen portrait; false when it's off.
local function ApplyPortrait(frame)
	local mode = PortraitMode(frame)
	local changed = frame.portraitMode ~= mode
	frame.portraitMode = mode
	if mode == 'off' then frame.portraitSlot:Hide() return false end
	frame.portraitSlot:Show()
	local screen = frame.portraitScreen.screen
	-- An avatar replaces the black display entirely.
	local avatar = ShowAvatar(frame, mode)
	frame.portraitScreen:SetShown(not avatar)
	if avatar then
		ModelFallback(frame, false)
		if frame.model then frame.model:Hide() end
		if frame.portrait then frame.portrait:Hide() end
		if UnitExists(frame.unit) then UI:Safe(UpdatePortrait, frame) end
		return true
	end
	if mode == 'model' then
		if not frame.model then
			frame.model = CreateFrame('PlayerModel', nil, screen)
			frame.model:SetAllPoints()
			frame.model:HookScript('OnShow', function() RefreshModel(frame) end)
			frame.model:HookScript('OnSizeChanged', function() RefreshModel(frame) end)
		end
		frame.model:SetFrameLevel(screen:GetFrameLevel() + 3)
		frame.model:Show()
		if frame.portrait then frame.portrait:Hide() end
	else
		ModelFallback(frame, false)
		if not frame.portrait then
			frame.portrait = screen:CreateTexture(nil, 'ARTWORK')
			frame.portrait:SetAllPoints()
		end
		frame.portrait:Show()
		if frame.model then frame.model:Hide() end
	end
	if changed and UnitExists(frame.unit) then UI:Safe(UpdatePortrait, frame) end
	return true
end

-- Secure frames change size and scale only out of combat.
local function Resize(frame, cfg)
	if InCombatLockdown() then
		return UI:AfterCombat(function() Resize(frame, Cfg(frame)) end, 'uf.size.'..frame.unit)
	end
	frame:SetSize(cfg.width, cfg.height)
	local scale = (DB().scale or 1) * (cfg.scale or 1)
	-- The Layout page's per-frame scale multiplies this one.
	if frame.layout.owner then
		if frame:GetScale() ~= scale then frame:SetScale(scale) end
	else
		UI:SetMoverBaseScale('uf.'..frame.unit, scale, frame)
	end
	-- A model drawn at the old size can go blank: redraw it at the new one.
	RefreshModel(frame)
end

-- The LCD's unlit '888' is shown or hidden by the appearance setting
-- (Kit:Ghost); it is only printed behind a percentage, where it reads right.
-- Kept in a block of its own: the main chunk may hold at most 200 locals.
local LayoutLarge, LayoutCompact, NoPortrait, Gauge, ApplyShell, ResetParts, SHAPE_LAYOUTS, SyncGhost
do
local function ShowGhost(frame, cfg)
	if not frame.ghost then return end
	frame.ghost:SetText('') -- see SyncGhost: no unlit digits behind health readouts
	if not Kit.Ghost then frame.ghost:Show() end
end

-- After every layout: the unlit '888' sits exactly behind the readout, in the
-- same face and size, right-aligned on the value's own right edge, and never
-- outlined or shadowed (an outlined ghost reads as garbled digits). It shows
-- only behind a percentage (three digits at most) set in the monospaced IBM
-- Plex Mono, where each digit lands on an unlit one; otherwise it is blank.
function SyncGhost(frame)
	-- Unlit digits behind a live, variable-width health readout kept showing
	-- through it in game (a dark first digit), so health readouts go without
	-- them; fixed readouts (clocks, timers) keep theirs.
	if frame.ghost then frame.ghost:SetText('') end
end

-- A theme repaint re-applies every registered font, ghosts included: put the
-- ghosts back behind their readouts once it has run.
Kit:OnRefresh(function()
	C_Timer.After(0, function()
		for _, frame in ipairs(ordered) do
			if frame.ghost then UI:Safe(SyncGhost, frame, Cfg(frame)) end
		end
	end)
end)

-- Moving a text or lamp between the face, the LCD and the overlay above the
-- meters. Only this addon's own regions move.
local function Put(region, parent)
	if region and region:GetParent() ~= parent then region:SetParent(parent) end
end
local function PutLamp(frame, parent)
	Put(frame.lamp, parent)
	Put(frame.lamp.glow, parent)
end

local function Ink(frame) return Kit.INK[Style()] or Kit.INK.paper end

-- Large frames (player, target): header row, portrait, LCD readout, meters.
function LayoutLarge(frame, cfg)
	local ink = Ink(frame)
	PutLamp(frame, frame.face)
	Put(frame.nameText, frame.face)
	Put(frame.levelText, frame.face)
	Put(frame.digits, frame.lcd)
	Put(frame.ghost, frame.lcd)
	Kit:Tint(frame.nameText, ink[1])
	Kit:Tint(frame.code, ink[1])
	Kit:Tint(frame.levelText, ink[2])
	Kit:Tint(frame.digits, 'lcdInk')
	Kit:Font(frame.levelText, Kit.SIZE.tiny, nil, false)
	local width = cfg.width
	local mirror, pad = frame.layout.mirror, 7
	local near, far = mirror and 'RIGHT' or 'LEFT', mirror and 'LEFT' or 'RIGHT'
	local sign = mirror and -1 or 1
	local header = cfg.header
	-- Header: lamp, model code and name in a row from the near side; level on the far side.
	local row = frame.headerRow
	row:ClearAllPoints()
	row:SetPoint('TOPLEFT', pad, -4)
	row:SetPoint('TOPRIGHT', -pad, -4)
	row:SetHeight(13)
	local previous
	local function Next(region, shown, gap)
		region:ClearAllPoints()
		if region.glow then Kit:ShowLed(region, shown) else region:SetShown(shown) end
		if not shown then return end
		if previous then region:SetPoint(near, previous, far, sign * gap, 0)
		else region:SetPoint(near, row, near, sign * 1, 0) end
		previous = region
	end
	Next(frame.lamp, header and cfg.combatLamp, 4)
	Next(frame.code, header and cfg.headerCode, 4)
	Next(frame.nameText, header, 6)
	frame.levelText:ClearAllPoints()
	frame.levelText:SetPoint(far, row, far, 0, 0)
	frame.levelText:SetShown(header and cfg.headerLevel)
	Kit:Font(frame.nameText, cfg.nameSize or 10, nil, true)
	-- Status lamps sit in the header, between the name and the level.
	local status = header and StatusMode(frame) ~= 'off'
	if status then
		local leveled = cfg.headerLevel and true or false
		local anchor = leveled and frame.levelText or row
		PlaceStatus(frame, far, anchor, leveled and near or far, leveled and -sign * 6 or 0, 0, mirror and 'RIGHT' or 'LEFT')
	end
	frame.nameText:SetWidth(max(width - 110 - (status and 56 or 0), 30))
	frame.nameText:SetJustifyH(mirror and 'RIGHT' or 'LEFT')

	-- Body: portrait, then the LCD and meters in a column beside it.
	local top = header and 21 or 7
	local lcdHeight = max(14, (cfg.digitsSize or 13) + 7)
	local healthTrack = (cfg.healthHeight or 6) + frame.health.inset * 2
	local powerTrack = frame.power and (cfg.powerHeight or 3) + frame.power.inset * 2 or 0
	local body = lcdHeight + 3 + healthTrack + (frame.power and 2 + powerTrack or 0)
	local hasPortrait = ApplyPortrait(frame)
	local portraitSize = hasPortrait and max(16, min(body, cfg.height - top - 4)) or 0
	local slot = frame.portraitSlot
	slot:ClearAllPoints()
	slot:SetSize(max(portraitSize, 1), max(portraitSize, 1))
	slot:SetPoint('TOP'..near, sign * pad, -top)
	local column = max(width - pad * 2 - (hasPortrait and portraitSize + 6 or 0), 20)
	local lcd = frame.lcd
	lcd:Show()
	lcd:ClearAllPoints()
	lcd:SetSize(column, lcdHeight)
	if hasPortrait then lcd:SetPoint('TOP'..near, slot, 'TOP'..far, sign * 6, 0)
	else lcd:SetPoint('TOP'..near, sign * pad, -top) end
	frame.tag:SetWidth(max(column - 50, 10))
	frame.tag:SetShown(cfg.lcdTag ~= 'none')
	Kit:Font(frame.digits, cfg.digitsSize or 13, nil, false)
	Kit:Font(frame.ghost, cfg.digitsSize or 13, nil, false)
	frame.digits:ClearAllPoints()
	frame.digits:SetPoint('RIGHT', lcd, 'RIGHT', -6, 0)
	frame.digits:SetJustifyH('RIGHT')
	frame.ghost:ClearAllPoints()
	frame.ghost:SetPoint('RIGHT', lcd, 'RIGHT', -6, 0)
	frame.ghost:SetJustifyH('RIGHT')
	ShowGhost(frame, cfg)
	frame.health.track:ClearAllPoints()
	frame.health.track:SetSize(column, healthTrack)
	frame.health.track:SetPoint('TOPLEFT', lcd, 'BOTTOMLEFT', 0, -3)
	if frame.power then
		frame.power.track:ClearAllPoints()
		frame.power.track:SetSize(column, powerTrack)
		frame.power.track:SetPoint('TOPLEFT', frame.health.track, 'BOTTOMLEFT', 0, -2)
	end
end

-- Compact frames (focus, party, target of target, pet): name row, digits, meters.
function LayoutCompact(frame, cfg)
	local width, height = cfg.width, cfg.height
	local small = frame.layout.size == 'small'
	local ink = Ink(frame)
	PutLamp(frame, frame.face)
	Put(frame.nameText, frame.face)
	Put(frame.digits, frame.face)
	Kit:Tint(frame.nameText, ink[1])
	Kit:Tint(frame.digits, ink[1])
	frame.digits:SetJustifyH('RIGHT')
	-- Small device frames carry health only.
	if frame.power then frame.power.track:SetShown(not small) end
	local pad, top = 7, small and 5 or 6
	local hasPortrait = ApplyPortrait(frame)
	local left = pad
	local slot = frame.portraitSlot
	slot:ClearAllPoints()
	if hasPortrait then
		local size = max(12, height - 8)
		slot:SetSize(size, size)
		slot:SetPoint('LEFT', 4, 0)
		left = 4 + size + 5
	end
	local header = cfg.header
	Kit:ShowLed(frame.lamp, header and cfg.combatLamp)
	frame.lamp:ClearAllPoints()
	frame.lamp:SetPoint('TOPLEFT', left, -top - 3)
	frame.nameText:ClearAllPoints()
	if cfg.combatLamp then frame.nameText:SetPoint('LEFT', frame.lamp, 'RIGHT', 4, 0)
	else frame.nameText:SetPoint('TOPLEFT', left, -top - 1) end
	frame.nameText:SetShown(header)
	frame.nameText:SetWidth(max(width - left - pad - 40, 20))
	Kit:Font(frame.nameText, cfg.nameSize or (small and 8 or 9), nil, true)
	Kit:Font(frame.digits, cfg.digitsSize or (small and 9 or 10), nil, true)
	frame.digits:ClearAllPoints()
	frame.digits:SetPoint('TOPRIGHT', -pad, -top)
	local healthTrack = (cfg.healthHeight or 5) + frame.health.inset * 2
	frame.health.track:ClearAllPoints()
	frame.health.track:SetSize(max(width - left - pad, 20), healthTrack)
	frame.health.track:SetPoint('TOPLEFT', left, header and -(top + 13) or -top)
	if frame.power and not small then
		frame.power.track:ClearAllPoints()
		frame.power.track:SetSize(max(width - left - pad, 20), (cfg.powerHeight or 3) + frame.power.inset * 2)
		frame.power.track:SetPoint('TOPLEFT', frame.health.track, 'BOTTOMLEFT', 0, -2)
	end
end

-- The portrait belongs to the device shape only.
function NoPortrait(frame)
	frame.portraitSlot:Hide()
	frame.portraitMode = 'off'
end

-- A meter's track height for a thickness setting.
local function TrackHeight(meter, thickness) return thickness + meter.inset * 2 end

-- Bar: the frame is one wide meter, with the name and health printed on it.
local function LayoutBar(frame, cfg)
	local width, height = cfg.width, cfg.height
	local pad = 3
	local inner = max(width - pad * 2, 20)
	local powerTrack = frame.power and TrackHeight(frame.power, 2) or 0
	local healthTrack = max(8, height - pad * 2 - (frame.power and powerTrack + 1 or 0))
	local track = frame.health.track
	track:ClearAllPoints()
	track:SetSize(inner, healthTrack)
	track:SetPoint('TOPLEFT', pad, -pad)
	if frame.power then
		frame.power.track:ClearAllPoints()
		frame.power.track:SetSize(inner, powerTrack)
		frame.power.track:SetPoint('TOPLEFT', track, 'BOTTOMLEFT', 0, -1)
	end
	-- The words sit above the meter's fill, outlined to read over any color.
	local over = frame.overlay
	over:SetFrameLevel(track:GetFrameLevel() + 6)
	PutLamp(frame, over)
	Put(frame.nameText, over)
	Put(frame.levelText, over)
	Put(frame.digits, over)
	local nameSize = min(cfg.nameSize or 10, max(healthTrack - 1, 7))
	Kit:Font(frame.nameText, nameSize, 'OUTLINE', true)
	Kit:Font(frame.levelText, max(nameSize - 2, 6), 'OUTLINE', false)
	Kit:Font(frame.digits, min(cfg.digitsSize or 10, max(healthTrack - 1, 7)), 'OUTLINE', true)
	for _, text in ipairs({frame.nameText, frame.levelText, frame.digits}) do Kit:Tint(text, 'white') end
	local x = 6
	frame.lamp:ClearAllPoints()
	Kit:ShowLed(frame.lamp, cfg.combatLamp and true or false)
	if cfg.combatLamp then
		frame.lamp:SetPoint('LEFT', track, 'LEFT', 6, 0)
		x = 15
	end
	frame.nameText:ClearAllPoints()
	frame.nameText:SetPoint('LEFT', track, 'LEFT', x, 0)
	frame.nameText:SetWidth(max(inner - x - 70, 20))
	frame.nameText:SetJustifyH('LEFT')
	frame.nameText:SetShown(cfg.header and true or false)
	frame.digits:ClearAllPoints()
	frame.digits:SetPoint('RIGHT', track, 'RIGHT', -6, 0)
	frame.digits:SetJustifyH('RIGHT')
	frame.levelText:ClearAllPoints()
	frame.levelText:SetPoint('RIGHT', frame.digits, 'LEFT', -5, 0)
	frame.levelText:SetShown(cfg.header and cfg.headerLevel and frame.layout.size == 'large' or false)
end

-- Square: a tile with the name across the top, big LCD digits in the middle and
-- the meters along the bottom.
local function LayoutSquare(frame, cfg)
	local width, height = cfg.width, cfg.height
	local pad = 5
	local ink = Ink(frame)
	PutLamp(frame, frame.face)
	Put(frame.nameText, frame.face)
	Put(frame.digits, frame.lcd)
	Put(frame.ghost, frame.lcd)
	local nameSize = min(cfg.nameSize or 9, 10)
	Kit:Font(frame.nameText, nameSize, nil, true)
	Kit:Tint(frame.nameText, ink[1])
	frame.nameText:ClearAllPoints()
	frame.nameText:SetPoint('TOPLEFT', pad, -pad)
	frame.nameText:SetWidth(max(width - pad * 2 - 9, 10))
	frame.nameText:SetJustifyH('LEFT')
	frame.nameText:SetShown(cfg.header and true or false)
	Kit:ShowLed(frame.lamp, cfg.combatLamp and true or false)
	frame.lamp:ClearAllPoints()
	frame.lamp:SetPoint('TOPRIGHT', -pad, -pad - 1)
	local top = pad + ((cfg.header or cfg.combatLamp) and nameSize + 4 or 0)
	local healthTrack = TrackHeight(frame.health, cfg.healthHeight or 4)
	local powerTrack = frame.power and TrackHeight(frame.power, min(cfg.powerHeight or 2, 3)) or 0
	local meters = healthTrack + (frame.power and powerTrack + 2 or 0)
	local lcd = frame.lcd
	local lcdWidth = max(width - pad * 2, 10)
	local lcdHeight = max(12, height - top - meters - pad - 3)
	lcd:Show()
	lcd:ClearAllPoints()
	lcd:SetPoint('TOPLEFT', pad, -top)
	lcd:SetSize(lcdWidth, lcdHeight)
	-- Big digits, as large as the tile allows for three characters.
	local size = max(8, min(floor(lcdHeight * 0.62), floor((lcdWidth - 8) / 1.9), 30))
	Kit:Font(frame.digits, size, nil, false)
	Kit:Font(frame.ghost, size, nil, false)
	Kit:Tint(frame.digits, 'lcdInk')
	ShowGhost(frame, cfg)
	-- A percentage lines up digit for digit over the unlit '888', centred.
	local half = cfg.healthText == 'percent' and frame.ghost:GetStringWidth() / 2 or 0
	for _, text in ipairs({frame.digits, frame.ghost}) do
		text:ClearAllPoints()
		if half > 0 then
			text:SetPoint('RIGHT', lcd, 'CENTER', half, 0)
			text:SetJustifyH('RIGHT')
		else
			text:SetPoint('CENTER', lcd, 'CENTER', 0, 0)
			text:SetJustifyH('CENTER')
		end
	end
	frame.health.track:ClearAllPoints()
	frame.health.track:SetSize(lcdWidth, healthTrack)
	frame.health.track:SetPoint('TOPLEFT', lcd, 'BOTTOMLEFT', 0, -3)
	if frame.power then
		frame.power.track:ClearAllPoints()
		frame.power.track:SetSize(lcdWidth, powerTrack)
		frame.power.track:SetPoint('TOPLEFT', frame.health.track, 'BOTTOMLEFT', 0, -2)
	end
end

-- Slim: a thin line meter with the name above it and the health at its right end.
local function LayoutSlim(frame, cfg)
	local width = cfg.width
	PutLamp(frame, frame.face)
	Put(frame.nameText, frame.face)
	Put(frame.levelText, frame.face)
	Put(frame.digits, frame.face)
	local nameSize = cfg.nameSize or 9
	Kit:Font(frame.nameText, nameSize, 'OUTLINE', true)
	Kit:Font(frame.levelText, max(nameSize - 2, 6), 'OUTLINE', false)
	Kit:Font(frame.digits, cfg.digitsSize or 9, 'OUTLINE', true)
	for _, text in ipairs({frame.nameText, frame.levelText, frame.digits}) do Kit:Tint(text, 'white') end
	local healthTrack = TrackHeight(frame.health, cfg.healthHeight or 4)
	local health = frame.health.track
	health:ClearAllPoints()
	health:SetSize(width, healthTrack)
	if frame.power then
		local power = frame.power.track
		power:ClearAllPoints()
		power:SetSize(width, TrackHeight(frame.power, min(cfg.powerHeight or 2, 2)))
		power:SetPoint('BOTTOMLEFT', 0, 0)
		health:SetPoint('BOTTOMLEFT', power, 'TOPLEFT', 0, 1)
	else
		health:SetPoint('BOTTOMLEFT', 0, 0)
	end
	local x = 0
	frame.lamp:ClearAllPoints()
	Kit:ShowLed(frame.lamp, cfg.combatLamp and true or false)
	if cfg.combatLamp then
		frame.lamp:SetPoint('BOTTOMLEFT', health, 'TOPLEFT', 1, 4)
		x = 8
	end
	frame.nameText:ClearAllPoints()
	frame.nameText:SetPoint('BOTTOMLEFT', health, 'TOPLEFT', x, 2)
	frame.nameText:SetWidth(max(width - x - 60, 20))
	frame.nameText:SetJustifyH('LEFT')
	frame.nameText:SetShown(cfg.header and true or false)
	frame.digits:ClearAllPoints()
	frame.digits:SetPoint('BOTTOMRIGHT', health, 'TOPRIGHT', 0, 2)
	frame.digits:SetJustifyH('RIGHT')
	frame.levelText:ClearAllPoints()
	frame.levelText:SetPoint('RIGHT', frame.digits, 'LEFT', -5, 0)
	frame.levelText:SetShown(cfg.header and cfg.headerLevel and frame.layout.size == 'large' or false)
end

-- LCD strip: the whole frame is a gray LCD, name and digits printed on it and a
-- dot meter along its bottom.
local function LayoutStrip(frame, cfg)
	local width = cfg.width
	local pad = 5
	PutLamp(frame, frame.face)
	Put(frame.nameText, frame.face)
	Put(frame.levelText, frame.face)
	Put(frame.digits, frame.face)
	Put(frame.ghost, frame.face)
	local nameSize = cfg.nameSize or 9
	Kit:Font(frame.nameText, nameSize, nil, true)
	Kit:Font(frame.levelText, max(nameSize - 2, 6), nil, false)
	Kit:Font(frame.digits, cfg.digitsSize or 11, nil, false)
	Kit:Font(frame.ghost, cfg.digitsSize or 11, nil, false)
	Kit:Tint(frame.nameText, 'lcdInk')
	Kit:Tint(frame.levelText, 'lcdDim')
	Kit:Tint(frame.digits, 'lcdInk')
	ShowGhost(frame, cfg)
	local x = pad
	frame.lamp:ClearAllPoints()
	Kit:ShowLed(frame.lamp, cfg.combatLamp and true or false)
	if cfg.combatLamp then
		frame.lamp:SetPoint('TOPLEFT', pad, -pad - 2)
		x = pad + 9
	end
	frame.nameText:ClearAllPoints()
	frame.nameText:SetPoint('TOPLEFT', x, -pad)
	frame.nameText:SetWidth(max(width - x - pad - 70, 20))
	frame.nameText:SetJustifyH('LEFT')
	frame.nameText:SetShown(cfg.header and true or false)
	for _, text in ipairs({frame.digits, frame.ghost}) do
		text:ClearAllPoints()
		text:SetPoint('TOPRIGHT', -pad, -pad + 1)
		text:SetJustifyH('RIGHT')
	end
	frame.levelText:ClearAllPoints()
	frame.levelText:SetPoint('RIGHT', frame.digits, 'LEFT', -6, 0)
	frame.levelText:SetShown(cfg.header and cfg.headerLevel and frame.layout.size ~= 'small' or false)
	local inner = max(width - pad * 2, 20)
	local bottom = pad
	if frame.power then
		local powerTrack = TrackHeight(frame.power, min(cfg.powerHeight or 2, 3))
		frame.power.track:ClearAllPoints()
		frame.power.track:SetSize(inner, powerTrack)
		frame.power.track:SetPoint('BOTTOMLEFT', pad, pad)
		bottom = pad + powerTrack + 2
	end
	frame.health.track:ClearAllPoints()
	frame.health.track:SetSize(inner, TrackHeight(frame.health, cfg.healthHeight or 4))
	frame.health.track:SetPoint('BOTTOMLEFT', pad, bottom)
end

-- The printed header the new faceplates share: combat lamp, model code and name
-- from the near side, level on the far side.
local function PrintHeader(frame, cfg, pad, y, width)
	local ink = Ink(frame)
	PutLamp(frame, frame.face)
	Put(frame.nameText, frame.face)
	Put(frame.levelText, frame.face)
	Kit:Tint(frame.nameText, ink[1])
	Kit:Tint(frame.code, ink[1])
	Kit:Tint(frame.levelText, ink[2])
	local mirror = frame.layout.mirror
	local near, far, sign = mirror and 'RIGHT' or 'LEFT', mirror and 'LEFT' or 'RIGHT', mirror and -1 or 1
	local header, large = cfg.header, frame.layout.size == 'large'
	local x = pad
	Kit:ShowLed(frame.lamp, header and cfg.combatLamp and true or false)
	frame.lamp:ClearAllPoints()
	if header and cfg.combatLamp then
		frame.lamp:SetPoint(near, frame.face, 'TOP'..near, sign * (x + 2), y - 6)
		x = x + 9
	end
	frame.code:ClearAllPoints()
	frame.code:SetShown(header and large and cfg.headerCode and true or false)
	if frame.code:IsShown() then
		frame.code:SetPoint('TOP'..near, frame.face, 'TOP'..near, sign * x, y - 2)
		x = x + frame.code:GetStringWidth() + 5
	end
	Kit:Font(frame.nameText, cfg.nameSize or (large and 10 or 9), nil, true)
	frame.nameText:ClearAllPoints()
	frame.nameText:SetPoint('TOP'..near, frame.face, 'TOP'..near, sign * x, y - 1)
	frame.nameText:SetJustifyH(mirror and 'RIGHT' or 'LEFT')
	frame.nameText:SetWidth(max(width - x - pad - 40, 20))
	frame.nameText:SetShown(header and true or false)
	Kit:Font(frame.levelText, Kit.SIZE.tiny, nil, false)
	frame.levelText:ClearAllPoints()
	frame.levelText:SetPoint('TOP'..far, frame.face, 'TOP'..far, -sign * pad, y - 2)
	frame.levelText:SetShown(header and cfg.headerLevel and large or false)
	return near, far, sign
end

-- Console: a printed header, an LCD readout on the near side, the meters beside
-- it (power as lit segments) and, on the player and target, a row of status
-- glyph lamps under them. Medium and small consoles drop the code, level and
-- lamps and give the readout and meters the room.
local function LayoutConsole(frame, cfg)
	local width, height = cfg.width, cfg.height
	local size = frame.layout.size
	local large = size == 'large'
	local pad = large and 7 or 5
	local near, far, sign = PrintHeader(frame, cfg, pad, large and -4 or -3, width)
	local nameSize = cfg.nameSize or (large and 10 or 9)
	local top = cfg.header and (large and 19 or nameSize + 7) or pad
	local statusRow = large and 9 or 0
	local bottom = large and statusRow + 9 or pad
	local bodyHeight = max(12, height - top - bottom)
	local lcd = frame.lcd
	Put(frame.digits, lcd)
	lcd:Show()
	lcd:ClearAllPoints()
	-- Wide enough for four digits at the chosen size, and no more than 40% of the frame.
	local digits = max(9, min(floor(bodyHeight * (large and 0.62 or 0.7)), cfg.digitsSize and cfg.digitsSize + (large and 8 or 2) or 22))
	local lcdWidth = min(max(floor(digits * 2.6) + 12, 34), floor(width * 0.4))
	digits = min(digits, floor((lcdWidth - 10) / 2.4))
	lcd:SetSize(lcdWidth, bodyHeight)
	lcd:SetPoint('TOP'..near, frame.face, 'TOP'..near, sign * pad, -top)
	Kit:Font(frame.digits, digits, nil, false)
	Kit:Tint(frame.digits, 'lcdInk')
	frame.digits:ClearAllPoints()
	frame.digits:SetPoint('RIGHT', lcd, 'RIGHT', -5, 0)
	frame.digits:SetJustifyH('RIGHT')
	frame.digits:SetWidth(0)
	local column = max(width - pad * 2 - lcdWidth - 6, 20)
	local healthHeight = cfg.healthHeight or (large and 6 or 5)
	local powerHeight = frame.power and max(cfg.powerHeight or 3, large and 4 or 3) or 0
	-- Meters centred on the readout's height.
	local meters = TrackHeight(frame.health, healthHeight) + (frame.power and TrackHeight(frame.power, powerHeight) + 3 or 0)
	local offset = max(0, floor((bodyHeight - meters) / 2))
	frame.health.track:ClearAllPoints()
	frame.health.track:SetSize(column, TrackHeight(frame.health, healthHeight))
	frame.health.track:SetPoint('TOP'..near, lcd, 'TOP'..far, sign * 6, -offset)
	if frame.power then
		frame.power.track:ClearAllPoints()
		frame.power.track:SetSize(column, TrackHeight(frame.power, powerHeight))
		frame.power.track:SetPoint('TOPLEFT', frame.health.track, 'BOTTOMLEFT', 0, -3)
	end
	if large then
		PlaceStatus(frame, 'BOTTOM'..near, frame.face, 'BOTTOM'..near, sign * pad, 5, frame.layout.mirror and 'LEFT' or 'RIGHT', statusRow)
	end
end

-- Gauge: a round instrument on the near side, built like the minimap's ring
-- from the 512 px round art so it stays smooth at any size: a black outline, a
-- charcoal bezel band and a lit inner edge around a dark recessed screen. Health
-- rises inside it as a dim liquid with a lit surface line; it is a native
-- vertical StatusBar under the round mask that copies the health meter's own
-- values, so the client fills it, secret or not. A ring of hairline ticks is
-- drawn in code in physical pixels (long ones at the quarters), and the
-- health figure sits in the centre.
local GAUGE_TICKS, GAUGE_RING = 24, 3

local function Round(parent, layer, sublevel)
	local texture = parent:CreateTexture(nil, layer or 'BACKGROUND', nil, sublevel or 0)
	texture:SetTexture(Kit.media..'mask-round.tga')
	return texture
end

function Gauge(frame)
	local gauge = frame.gauge
	if gauge then return gauge end
	gauge = CreateFrame('Frame', nil, frame.face)
	gauge:EnableMouse(false)
	gauge.outline = Round(gauge, 'BACKGROUND', -6)
	gauge.outline:SetVertexColor(0, 0, 0, 0.85)
	gauge.band = Round(gauge, 'BACKGROUND', -5)
	gauge.lit = Round(gauge, 'BACKGROUND', -4)
	gauge.lit:SetVertexColor(1, 1, 1, 0.14)
	gauge.well = Round(gauge, 'BACKGROUND', -3)
	gauge.ticks = {}
	for index = 1, GAUGE_TICKS do
		local tick = gauge:CreateTexture(nil, 'BACKGROUND', nil, -7)
		tick:SetColorTexture(1, 1, 1, 1)
		gauge.ticks[index] = tick
	end
	gauge.bar = CreateFrame('StatusBar', nil, gauge)
	gauge.bar:SetAllPoints(gauge)
	gauge.bar:SetOrientation('VERTICAL')
	gauge.bar:SetStatusBarTexture([[Interface\Buttons\WHITE8X8]])
	gauge.bar:SetMinMaxValues(0, 1)
	gauge.bar:SetValue(1)
	gauge.bar:SetAlpha(0.45)
	local mask = gauge.bar:CreateMaskTexture()
	mask:SetTexture(Kit.media..'mask-round.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
	mask:SetAllPoints(gauge)
	local fill = gauge.bar:GetStatusBarTexture()
	fill:AddMaskTexture(mask)
	-- The liquid's surface: a lit hairline on the fill's top edge, inside the mask.
	gauge.surface = gauge.bar:CreateTexture(nil, 'OVERLAY')
	gauge.surface:SetColorTexture(1, 1, 1, 1)
	gauge.surface:SetPoint('TOPLEFT', fill, 'TOPLEFT')
	gauge.surface:SetPoint('TOPRIGHT', fill, 'TOPRIGHT')
	gauge.surface:AddMaskTexture(mask)
	gauge.front = CreateFrame('Frame', nil, gauge)
	gauge.front:SetAllPoints()
	gauge.front:SetFrameLevel(gauge.bar:GetFrameLevel() + 2)
	gauge.front:EnableMouse(false)
	gauge.shade = Kit:Texture(gauge.front, 'bezel-shade', 'OVERLAY', 0)
	gauge.shade:SetAllPoints(gauge)
	gauge.shade:SetAlpha(0.5)
	gauge.ring = Kit:Texture(gauge.front, 'bezel-ring', 'OVERLAY', 1)
	gauge.ring:SetVertexColor(1, 1, 1, 0.08)
	-- Follow the health meter: every value goes straight from setter to setter.
	local health, bar = frame.health, gauge.bar
	hooksecurefunc(health, 'SetMinMaxValues', function(_, low, high) pcall(bar.SetMinMaxValues, bar, low, high) end)
	hooksecurefunc(health, 'SetValue', function(_, value, interpolation) pcall(bar.SetValue, bar, value, interpolation) end)
	hooksecurefunc(health, 'SetStatusBarColor', function(_, r, g, b) pcall(bar.SetStatusBarColor, bar, r, g, b) end)
	frame.gauge = gauge
	return gauge
end

-- Sizes in physical pixels around a disc of `size` units.
local function FitGauge(frame, gauge)
	local Px = UI.Pixel.Px
	local function Around(texture, n)
		local inset = Px(gauge, n)
		texture:ClearAllPoints()
		texture:SetPoint('TOPLEFT', gauge, 'TOPLEFT', -inset, inset)
		texture:SetPoint('BOTTOMRIGHT', gauge, 'BOTTOMRIGHT', inset, -inset)
	end
	Around(gauge.outline, GAUGE_RING + 1)
	Around(gauge.band, GAUGE_RING)
	Around(gauge.lit, 1)
	Around(gauge.ring, GAUGE_RING)
	gauge.well:ClearAllPoints()
	gauge.well:SetAllPoints(gauge)
	Kit:Tint(gauge.band, 'dark')
	Kit:Tint(gauge.well, 'glass')
	gauge.surface:SetHeight(Px(gauge, 1))
	-- The tick ring, just outside the bezel.
	local ink = Ink(frame)
	local px = Px(gauge, 1)
	local radius = gauge:GetWidth() / 2
	for index, tick in ipairs(gauge.ticks) do
		local major = (index - 1) % (GAUGE_TICKS / 4) == 0
		local length = (major and 4 or 2) * px
		local angle = pi / 2 - (index - 1) / GAUGE_TICKS * 2 * pi
		local reach = radius + (GAUGE_RING + 3) * px + length / 2
		local x = UI.Pixel.Snap(gauge, math.cos(angle) * reach)
		local y = UI.Pixel.Snap(gauge, sin(angle) * reach)
		tick:ClearAllPoints()
		tick:SetSize(px, length)
		tick:SetPoint('CENTER', gauge, 'CENTER', x, y)
		if tick.SetRotation then tick:SetRotation(angle - pi / 2) end
		Kit:Tint(tick, major and ink[1] or ink[2], major and 0.9 or 0.55)
	end
end

local function LayoutGauge(frame, cfg)
	local width, height = cfg.width, cfg.height
	local pad = 6
	local mirror = frame.layout.mirror
	local near, far, sign = mirror and 'RIGHT' or 'LEFT', mirror and 'LEFT' or 'RIGHT', mirror and -1 or 1
	local gauge = Gauge(frame)
	-- Room around the disc for the bezel and the tick ring.
	local around = UI.Pixel.Px(frame.face, GAUGE_RING + 3 + 4) + 1
	local size = UI.Pixel.Snap(frame.face, max(16, height - 2 * pad - 2 * around))
	gauge:Show()
	gauge:ClearAllPoints()
	gauge:SetSize(size, size)
	gauge:SetPoint(near, frame.face, near, sign * (pad + around), 0)
	FitGauge(frame, gauge)
	Put(frame.digits, gauge.front)
	Kit:Font(frame.digits, max(7, min(floor(size * 0.32), cfg.digitsSize or 13)), 'OUTLINE', true)
	Kit:Tint(frame.digits, 'darkInk')
	frame.digits:ClearAllPoints()
	frame.digits:SetPoint('CENTER', gauge, 'CENTER', 0, 0)
	frame.digits:SetJustifyH('CENTER')
	-- The rest beside it: header, then the meters.
	local left = pad + size + 2 * around + 6
	local column = max(width - left - pad, 20)
	PutLamp(frame, frame.face)
	Put(frame.nameText, frame.face)
	Put(frame.levelText, frame.face)
	local ink = Ink(frame)
	Kit:Tint(frame.nameText, ink[1])
	Kit:Tint(frame.levelText, ink[2])
	Kit:Font(frame.nameText, cfg.nameSize or 10, nil, true)
	Kit:Font(frame.levelText, Kit.SIZE.tiny, nil, false)
	local header = cfg.header
	local x = left
	Kit:ShowLed(frame.lamp, header and cfg.combatLamp and true or false)
	frame.lamp:ClearAllPoints()
	if header and cfg.combatLamp then
		frame.lamp:SetPoint(near, frame.face, 'TOP'..near, sign * (x + 2), -pad - 5)
		x = x + 9
	end
	frame.nameText:ClearAllPoints()
	frame.nameText:SetPoint('TOP'..near, frame.face, 'TOP'..near, sign * x, -pad)
	frame.nameText:SetWidth(max(column - (x - left) - 36, 20))
	frame.nameText:SetJustifyH(mirror and 'RIGHT' or 'LEFT')
	frame.nameText:SetShown(header and true or false)
	frame.levelText:ClearAllPoints()
	frame.levelText:SetPoint('TOP'..far, frame.face, 'TOP'..far, -sign * pad, -pad - 1)
	frame.levelText:SetShown(header and cfg.headerLevel and frame.layout.size == 'large' or false)
	local top = header and pad + (cfg.nameSize or 10) + 5 or pad
	frame.health.track:ClearAllPoints()
	frame.health.track:SetSize(column, TrackHeight(frame.health, cfg.healthHeight or 5))
	frame.health.track:SetPoint('TOP'..near, frame.face, 'TOP'..near, sign * left, -top)
	if frame.power then
		frame.power.track:ClearAllPoints()
		frame.power.track:SetSize(column, TrackHeight(frame.power, cfg.powerHeight or 3))
		frame.power.track:SetPoint('TOPLEFT', frame.health.track, 'BOTTOMLEFT', 0, -2)
	end
	PlaceStatus(frame, 'BOTTOM'..far, frame.face, 'BOTTOM'..far, -sign * pad, pad - 1, mirror and 'RIGHT' or 'LEFT')
end

-- Tape: the name and health over a meter with a tick scale under it, every 5%
-- with long ticks at the quarters, like the scale under SPEC-01's slider.
local TAPE_TICKS = 21
local function LayoutTape(frame, cfg)
	local width = cfg.width
	local pad = 6
	local inner = max(width - pad * 2, 20)
	local near, far, sign = PrintHeader(frame, cfg, pad, -pad + 2, width)
	Put(frame.digits, frame.face)
	Kit:Font(frame.digits, cfg.digitsSize or 10, nil, true)
	Kit:Tint(frame.digits, Ink(frame)[1])
	frame.digits:ClearAllPoints()
	frame.digits:SetPoint('TOP'..far, frame.face, 'TOP'..far, -sign * pad, -pad + 1)
	frame.digits:SetJustifyH(far == 'RIGHT' and 'RIGHT' or 'LEFT')
	-- The level moves beside the digits.
	frame.levelText:ClearAllPoints()
	frame.levelText:SetPoint(far, frame.digits, near, -sign * 6, 0)
	local top = cfg.header and pad + (cfg.nameSize or 10) + 4 or pad
	local healthTrack = TrackHeight(frame.health, cfg.healthHeight or 5)
	local track = frame.health.track
	track:ClearAllPoints()
	track:SetSize(inner, healthTrack)
	track:SetPoint('TOPLEFT', frame.face, 'TOPLEFT', pad, -top)
	-- The scale.
	local ticks = frame.tapeTicks
	if not ticks then
		ticks = {}
		for index = 1, TAPE_TICKS do
			local tick = frame.face:CreateTexture(nil, 'ARTWORK', nil, 2)
			tick:SetColorTexture(1, 1, 1, 1)
			ticks[index] = tick
		end
		frame.tapeTicks = ticks
	end
	local px = UI.Pixel.Px(frame.face, 1)
	local ink = Ink(frame)
	for index, tick in ipairs(ticks) do
		local major = (index - 1) % 5 == 0
		local x = UI.Pixel.Snap(frame.face, (index - 1) / (TAPE_TICKS - 1) * (inner - px))
		Kit:Tint(tick, major and ink[1] or ink[2], major and 0.9 or 0.6)
		tick:ClearAllPoints()
		tick:SetSize(px, (major and 4 or 2) * px)
		tick:SetPoint('TOPLEFT', track, 'BOTTOMLEFT', x, -2 * px)
		tick:Show()
	end
	if frame.power then
		frame.power.track:ClearAllPoints()
		frame.power.track:SetSize(inner, TrackHeight(frame.power, cfg.powerHeight or 3))
		frame.power.track:SetPoint('TOPLEFT', track, 'BOTTOMLEFT', 0, -(6 * px + 2))
	end
	PlaceStatus(frame, 'BOTTOM'..far, frame.face, 'TOP'..far, -sign * 2, 3, frame.layout.mirror and 'RIGHT' or 'LEFT')
end

-- Printed: a spec sheet. The name over a hairline rule, then each meter on its
-- own row behind a printed legend (HP, PWR) in the reference's small caps, the
-- health figure at the end of its row.
local function Legend(frame, key, text)
	frame.legends = frame.legends or {}
	local legend = frame.legends[key]
	if not legend then
		legend = Kit:Label(frame.face, text, 'legend', 7, true)
		frame.legends[key] = legend
	end
	Kit:Tint(legend, 'legend')
	legend:Show()
	return legend
end

local function LayoutPrinted(frame, cfg)
	local width = cfg.width
	local pad = 7
	local near, far, sign = PrintHeader(frame, cfg, pad, -pad + 2, width)
	local top = cfg.header and pad + (cfg.nameSize or 10) + 4 or pad
	-- The rule under the header.
	local rule = frame.printRule
	if not rule then
		rule = frame.face:CreateTexture(nil, 'ARTWORK', nil, 1)
		rule:SetColorTexture(1, 1, 1, 1)
		frame.printRule = rule
	end
	Kit:Tint(rule, 'rule')
	rule:ClearAllPoints()
	rule:SetHeight(UI.Pixel.Px(frame.face, 1))
	rule:SetPoint('TOPLEFT', frame.face, 'TOPLEFT', pad, -top + 2)
	rule:SetPoint('TOPRIGHT', frame.face, 'TOPRIGHT', -pad, -top + 2)
	rule:SetShown(cfg.header and true or false)
	local legendWidth = 22
	local digitsWidth = 34
	local column = max(width - pad * 2 - legendWidth - digitsWidth, 20)
	local healthTrack = TrackHeight(frame.health, cfg.healthHeight or 5)
	local hp = Legend(frame, 'hp', 'HP')
	frame.health.track:ClearAllPoints()
	frame.health.track:SetSize(column, healthTrack)
	frame.health.track:SetPoint('TOPLEFT', frame.face, 'TOPLEFT', pad + legendWidth, -top - 2)
	hp:ClearAllPoints()
	hp:SetPoint('LEFT', frame.face, 'LEFT', pad, 0)
	hp:SetPoint('TOP', frame.health.track, 'TOP', 0, 0)
	hp:SetPoint('BOTTOM', frame.health.track, 'BOTTOM', 0, 0)
	Put(frame.digits, frame.face)
	Kit:Font(frame.digits, cfg.digitsSize or 10, nil, true)
	Kit:Tint(frame.digits, Ink(frame)[1])
	frame.digits:ClearAllPoints()
	frame.digits:SetPoint('RIGHT', frame.face, 'RIGHT', -pad, 0)
	frame.digits:SetPoint('TOP', frame.health.track, 'TOP', 0, 2)
	frame.digits:SetPoint('BOTTOM', frame.health.track, 'BOTTOM', 0, -2)
	frame.digits:SetJustifyH('RIGHT')
	if frame.power then
		local pwr = Legend(frame, 'pwr', 'PWR')
		frame.power.track:ClearAllPoints()
		frame.power.track:SetSize(column, TrackHeight(frame.power, cfg.powerHeight or 3))
		frame.power.track:SetPoint('TOPLEFT', frame.health.track, 'BOTTOMLEFT', 0, -4)
		pwr:ClearAllPoints()
		pwr:SetPoint('LEFT', frame.face, 'LEFT', pad, 0)
		pwr:SetPoint('TOP', frame.power.track, 'TOP', 0, 2)
		pwr:SetPoint('BOTTOM', frame.power.track, 'BOTTOM', 0, -2)
	end
	PlaceStatus(frame, 'BOTTOM'..far, frame.face, 'TOP'..far, -sign * 2, 3, frame.layout.mirror and 'RIGHT' or 'LEFT')
end

-- The frame's own housing for its shape. Docked in the console, a device frame
-- sits on the console's housing (an LCD-style one keeps its face); the other
-- shapes keep theirs, since the housing is their body. Slim has none.
function ApplyShell(frame, shape)
	local shell = frame.shell
	local surface = shape == 'lcdstrip' and 'lcd' or Style()
	if shell.opts.surface ~= surface then Kit:SetSurface(shell, surface) end
	local radius = shape == 'device' and (frame.layout.size == 'small' and 6 or 8)
		or ((shape == 'square' or shape == 'console' or shape == 'gauge') and 8 or 6)
	if shell.opts.radius ~= radius then
		shell.opts.radius = radius
		Kit:FitShell(shell)
	end
	local shown = shape ~= 'slim'
	if frame.docked and shape == 'device' then shown = frame.keepShell and true or false end
	shell:SetShown(shown)
end

-- Everything a shape may not use starts hidden; each layout shows its own.
function ResetParts(frame)
	frame.code:Hide()
	frame.levelText:Hide()
	frame.lcd:Hide()
	frame.tag:Hide()
	frame.ghost:SetText('')
	frame.health.track:Show()
	if frame.power then frame.power.track:Show() end
	if frame.gauge then frame.gauge:Hide() end
	if frame.printRule then frame.printRule:Hide() end
	for _, legend in pairs(frame.legends or {}) do legend:Hide() end
	for _, tick in ipairs(frame.tapeTicks or {}) do tick:Hide() end
	if frame.status then frame.status:Hide() end
end

SHAPE_LAYOUTS = {bar = LayoutBar, square = LayoutSquare, slim = LayoutSlim, lcdstrip = LayoutStrip,
	console = LayoutConsole, gauge = LayoutGauge, tape = LayoutTape, printed = LayoutPrinted}
end

local function LayoutLamps(frame, cfg)
	if not frame.lamps then return end
	local size = cfg.lampSize or 6
	frame.lampRail:SetHeight(size + 8)
	for index, lamp in ipairs(frame.lamps) do
		lamp:SetSize(size, size)
		if lamp.glow then Kit:FitSprite(lamp.glow, size, size) end
		lamp:ClearAllPoints()
		lamp:SetPoint('LEFT', 8 + (index - 1) * (size + 6), 0)
	end
end

-- Your own colors over each layout's: the housing tint, the name, the digits and level.
local function ApplyColors(frame)
	local db, shell = DB(), frame.shell
	if shell then
		if db.housing == 'custom' then
			shell.opts.fill, shell.opts.alpha = {RGB(db.housingColor)}, db.housingAlpha or 0.95
			shell.customTint = true
			Kit:PaintShell(shell)
		elseif shell.customTint then
			shell.opts.fill, shell.opts.alpha, shell.customTint = nil, nil, nil
			Kit:PaintShell(shell)
		end
	end
	if db.nameColor == 'custom' then Kit:Tint(frame.nameText, {RGB(db.nameCustom)})
	elseif db.nameColor == 'class' then Kit:Tint(frame.nameText, {ClassColor(frame.unit)}) end
	if db.textColor == 'custom' then
		local color = {RGB(db.textCustom)}
		Kit:Tint(frame.digits, color)
		Kit:Tint(frame.levelText, color)
	end
end

local function Layout(frame)
	local cfg = Cfg(frame)
	Resize(frame, cfg)
	local shape = ShapeOf(frame)
	frame.shapeName = shape
	ApplyShell(frame, shape)
	ResetParts(frame)
	if shape == 'device' then
		if frame.layout.size == 'large' then LayoutLarge(frame, cfg) else LayoutCompact(frame, cfg) end
	else
		NoPortrait(frame)
		SHAPE_LAYOUTS[shape](frame, cfg)
	end
	-- Shapes without a place of their own carry the status lamps over their far corner.
	if not (frame.status and frame.status:IsShown()) and StatusMode(frame) ~= 'off' then
		local mirror = frame.layout.mirror
		PlaceStatus(frame, mirror and 'BOTTOMLEFT' or 'BOTTOMRIGHT', frame.face, mirror and 'TOPLEFT' or 'TOPRIGHT',
			mirror and 2 or -2, 3, mirror and 'RIGHT' or 'LEFT')
	end
	SyncGhost(frame, cfg)
	ApplyColors(frame)
	LayoutLamps(frame, cfg)
	LayoutAuras(frame)
	LayoutPowerDigits(frame)
	ApplyLooks(frame)
	ApplyMotion(frame)
	if frame.raidIcon then
		frame.raidIcon:ClearAllPoints()
		frame.raidIcon:SetPoint('CENTER', frame.face, 'TOP', 0, 2)
	end
end

local HANDLERS = {
	UNIT_HEALTH = UpdateHealth, UNIT_MAXHEALTH = UpdateHealth, UNIT_CONNECTION = UpdateHealth, UNIT_FACTION = UpdateHealth,
	UNIT_POWER_UPDATE = UpdatePower, UNIT_POWER_FREQUENT = UpdatePower, UNIT_MAXPOWER = UpdatePower, UNIT_DISPLAYPOWER = UpdatePower,
	RUNE_POWER_UPDATE = UpdatePower, UPDATE_SHAPESHIFT_FORM = UpdatePower,
	UNIT_NAME_UPDATE = UpdateName, UNIT_LEVEL = UpdateName, UNIT_PORTRAIT_UPDATE = UpdateName, UNIT_MODEL_CHANGED = UpdateName,
	UNIT_AURA = UpdateAuras, UNIT_FLAGS = UpdateCombat,
	RAID_TARGET_UPDATE = UpdateIndicators, PARTY_LEADER_CHANGED = UpdateIndicators, PLAYER_ROLES_ASSIGNED = UpdateIndicators,
	INCOMING_SUMMON_CHANGED = UpdateIndicators, INCOMING_RESURRECT_CHANGED = UpdateIndicators, READY_CHECK_CONFIRM = UpdateIndicators,
}
-- Group events party frames listen to besides their unit events.
local INDICATOR_EVENTS = {'PARTY_LEADER_CHANGED', 'PLAYER_ROLES_ASSIGNED', 'INCOMING_SUMMON_CHANGED', 'INCOMING_RESURRECT_CHANGED',
	'READY_CHECK', 'READY_CHECK_CONFIRM', 'READY_CHECK_FINISHED'}

-- Unit watch shows a frame while its unit exists. Party frames skip it while
-- the raid frames show the party: their header stays hidden then.
local function Watch(frame)
	if frame.layout.party and PartyAsRaid() then
		UnregisterUnitWatch(frame)
		frame:Hide()
		return
	end
	RegisterUnitWatch(frame)
end

local function Build(layout)
	local unit, size = layout.unit, layout.size
	local style = Style()
	local parent = layout.party and module.partyHeader or UIParent
	local frame = CreateFrame('Button', 'JiberishSpec01'..unit:gsub('^%l', strupper), parent, 'SecureUnitButtonTemplate')
	frame.unit, frame.layout, frame.key = unit, layout, layout.key
	-- Click-casting addons (Clique and the like) bind the frames listed here.
	local clickCast = _G.ClickCastFrames or {}
	_G.ClickCastFrames = clickCast
	clickCast[frame] = true
	local cfg = Cfg(frame)
	frame:SetSize(cfg.width, cfg.height)
	frame:SetScale((DB().scale or 1) * (cfg.scale or 1))
	if frame.SetDontSavePosition then frame:SetDontSavePosition(true) end
	frame:SetAttribute('unit', unit)
	frame:SetAttribute('*type1', 'target')
	frame:SetAttribute('*type2', 'togglemenu')
	frame:RegisterForClicks('AnyUp')
	frame:SetScript('OnEnter', function(self) if UnitFrame_OnEnter then UnitFrame_OnEnter(self) end end)
	frame:SetScript('OnLeave', function(self) if UnitFrame_OnLeave then UnitFrame_OnLeave(self) end end)

	-- Everything drawn sits on 'face', our own child: it can fade and move in
	-- combat without touching the secure button.
	local face = CreateFrame('Frame', nil, frame)
	face:SetAllPoints()
	face:EnableMouse(false)
	frame.face = face
	frame.shell = Kit:Shell(face, {surface = style, radius = size == 'small' and 6 or 8})
	local ink = Kit.INK[style]
	local barStyle = BarStyle(layout)
	Portrait(frame, face)

	-- Every frame carries the parts of every shape; its layout shows the ones its
	-- shape uses and moves texts between the face, the LCD and the overlay.
	local large = size == 'large'
	frame.headerRow = CreateFrame('Frame', nil, face)
	frame.lamp = Kit:Led(face, large and 5 or 4, false)
	frame.code = Kit:Label(face, layout.model, ink[1], 'tiny', true)
	frame.nameText = Kit:Label(face, '', ink[1], large and 'small' or (size == 'small' and 'tiny' or 'label'), true)
	frame.nameText:SetJustifyH('LEFT')
	frame.nameText:SetWordWrap(false)
	frame.levelText = Kit:Label(face, '', ink[2], 'tiny')
	frame.lcd = Kit:LCDPanel(face)
	frame.tag = Kit:Label(frame.lcd, '', 'lcdDim', 'tiny')
	frame.tag:SetPoint('LEFT', 6, 0)
	frame.tag:SetJustifyH('LEFT')
	frame.tag:SetWordWrap(false)
	frame.ghost = Kit:Text(frame.lcd, '888', 'value', 'lcdGhost')
	frame.ghost:SetPoint('RIGHT', -6, 0)
	if Kit.Ghost then Kit:Ghost(frame.ghost) end
	frame.digits = Kit:Text(frame.lcd, '', 'value', 'lcdInk')
	frame.digits:SetPoint('RIGHT', -6, 0)
	frame.digits:SetJustifyH('RIGHT')
	frame.health = Meter(face, cfg.healthHeight or (large and 6 or 5), style == 'dark', barStyle)
	if layout.power then frame.power = Meter(face, cfg.powerHeight or 3, style == 'dark', barStyle) end
	-- Above the meters: where the bar shape prints its words.
	frame.overlay = CreateFrame('Frame', nil, face)
	frame.overlay:SetAllPoints(face)
	frame.overlay:EnableMouse(false)

	-- The light that sweeps the top edge when combat starts and ends.
	frame.sweep = face:CreateTexture(nil, 'OVERLAY', nil, 6)
	frame.sweep:SetTexture(Kit.media..'sweep.tga')
	frame.sweep:SetBlendMode('ADD')
	frame.sweep:SetSize(64, 6)
	frame.sweep:SetAlpha(0)

	-- Raid target marker, centred on the top edge.
	frame.raidIcon = face:CreateTexture(nil, 'OVERLAY', nil, 7)
	frame.raidIcon:SetTexture([[Interface\TargetingFrame\UI-RaidTargetingIcons]])
	frame.raidIcon:SetSize(14, 14)
	frame.raidIcon:Hide()

	-- A ring in the debuff's color when there is one you can dispel.
	frame.dispel = Kit:Texture(face, 'ring-6', 'OVERLAY', 4)
	Kit:Place(frame.dispel, face, 2, 2, 2, 2)
	frame.dispel:Hide()

	if layout.party then
		-- Role, leader and status chips on the top edge; a lamp-colored outline on your target.
		frame.roleChip, frame.leadChip, frame.statusChip = Chip(face, 22), Chip(face, 14), Chip(face, 20)
		frame.outline = Kit:Texture(face, 'ring-6', 'OVERLAY', 3)
		Kit:Place(frame.outline, face, 1, 1, 1, 1)
		Kit:Tint(frame.outline, 'lamp')
		frame.outline:Hide()
	end

	if layout.classpower then
		-- Combo points, holy power and the like: lamps on a charcoal rail under the frame.
		frame.lampRail = CreateFrame('Frame', nil, face)
		frame.lampRail:SetPoint('TOP', face, 'BOTTOM', 0, -3)
		frame.lampRail.shell = Kit:Shell(frame.lampRail, {surface = 'glass', radius = 99, shadowAlpha = 0.25})
		frame.lamps = {}
		for index = 1, 10 do frame.lamps[index] = Kit:Led(frame.lampRail, 6, false) end
		frame.lampRail:Hide()
	end

	-- Placement: through the shared movers, or beside its party frame.
	if not layout.owner then UI:RegisterMover(frame, 'uf.'..unit, layout.title, layout.at) end
	function frame:SetPreview(on)
		if InCombatLockdown() then
			-- Movers lock when a fight starts: put the frame back once it ends.
			if not on then UI:AfterCombat(function() self:SetPreview(false) end, 'preview.uf.'..unit) end
			return
		end
		local header = layout.party and module.partyHeader
		if on then
			UnregisterUnitWatch(self)
			self:Show()
			-- Party frames live under a header hidden when solo or in a raid.
			if header then UnregisterStateDriver(header, 'visibility'); header:Show() end
		else
			Watch(self)
			if header then RegisterStateDriver(header, 'visibility', PartyVisibility()) end
		end
	end

	for event in pairs(HANDLERS) do
		if event:find('^UNIT_') then pcall(frame.RegisterUnitEvent, frame, event, unit) end
	end
	frame:RegisterEvent('PLAYER_ENTERING_WORLD')
	frame:RegisterEvent('PLAYER_REGEN_DISABLED')
	frame:RegisterEvent('PLAYER_REGEN_ENABLED')
	frame:RegisterEvent('RAID_TARGET_UPDATE')
	if unit == 'target' or unit == 'targettarget' or layout.party then frame:RegisterEvent('PLAYER_TARGET_CHANGED') end
	if unit == 'focus' then pcall(frame.RegisterEvent, frame, 'PLAYER_FOCUS_CHANGED') end
	if unit == 'pet' or unit:find('^partypet') then frame:RegisterEvent('UNIT_PET') end
	if layout.party then
		frame:RegisterEvent('GROUP_ROSTER_UPDATE')
		for _, event in ipairs(INDICATOR_EVENTS) do pcall(frame.RegisterEvent, frame, event) end
	end
	if layout.size == 'large' then
		-- The status lamps' events (party frames already listen to the group ones).
		for _, event in ipairs({'PLAYER_FLAGS_CHANGED', 'PARTY_LEADER_CHANGED', 'PLAYER_ROLES_ASSIGNED', 'GROUP_ROSTER_UPDATE'}) do
			pcall(frame.RegisterEvent, frame, event)
		end
		if unit == 'player' then pcall(frame.RegisterEvent, frame, 'PLAYER_UPDATE_RESTING') end
	end
	if layout.classpower then
		pcall(frame.RegisterEvent, frame, 'RUNE_POWER_UPDATE')
		pcall(frame.RegisterEvent, frame, 'UPDATE_SHAPESHIFT_FORM')
		pcall(frame.RegisterEvent, frame, 'PLAYER_SPECIALIZATION_CHANGED')
	end
	frame:SetScript('OnEvent', function(self, event, _, info)
		-- An aura event that changed nothing: no added, updated or removed auras.
		if event == 'UNIT_AURA' and AuraUpdateEmpty(info) then return end
		if event == 'PLAYER_REGEN_DISABLED' or event == 'PLAYER_REGEN_ENABLED' then
			UI:Safe(UpdateCombat, self, event)
			if self.status then UI:Safe(UpdateStatus, self) end
			return
		end
		if event == 'READY_CHECK' then self.readyShown = GetTime() + 3600
		elseif event == 'READY_CHECK_FINISHED' then
			-- Answers stay up a few seconds after the check ends.
			self.readyShown = GetTime() + 6
			C_Timer.After(6.1, function() UI:Safe(UpdateIndicators, self) end)
		end
		if event == 'PLAYER_TARGET_CHANGED' and unit == 'target' then
			local exists = UnitExists('target')
			if exists and not self.hadUnit then UI:Safe(Arrive, self) end
			self.hadUnit = exists
		end
		if event == 'PLAYER_TARGET_CHANGED' and layout.party then return UI:Safe(UpdateIndicators, self) end
		local handler = HANDLERS[event]
		if handler then UI:Safe(handler, self) else UI:Safe(UpdateAll, self) end
		if handler and self.status and STATUS_EVENTS[event] then UI:Safe(UpdateStatus, self) end
		if self.avatarStyle and AVATAR_EVENTS[event] then UI:Safe(AvatarStatus, self) end
		-- Loading screens leave models blank: draw again once the world is up.
		if event == 'PLAYER_ENTERING_WORLD' then RefreshModel(self) end
	end)
	frame:HookScript('OnShow', function(self) UI:Safe(UpdateAll, self) end)
	if layout.poll then
		-- A unit with no events of its own (target of target) is refreshed on a timer, only while shown.
		local elapsed = 0
		frame:HookScript('OnUpdate', function(self, delta)
			elapsed = elapsed + delta
			if elapsed < layout.poll then return end
			elapsed = 0
			UI:Safe(UpdateAll, self, true)
		end)
	end
	Layout(frame)
	Watch(frame)
	return frame
end

-- Party pets and targets sit right of their party frame (past its auras when
-- those are on the right), pets first. Out of combat only: the frames are secure.
local function PlaceExtras()
	if InCombatLockdown() then return UI:AfterCombat(PlaceExtras, 'uf.extras') end
	for index = 1, 4 do
		local owner = frames['party'..index]
		if owner then
			local cfg = Cfg(owner)
			local x = 6
			if DB().auras and cfg.auras and cfg.auraPosition == 'right' then
				x = x + min(cfg.auraMax or 4, cfg.auraPerRow or 4) * ((cfg.auraSize or 18) + 4) + 2
			end
			local previous
			for _, unit in ipairs({'partypet'..index, 'party'..index..'target'}) do
				local frame = frames[unit]
				if frame then
					frame:ClearAllPoints()
					if previous then frame:SetPoint('TOPLEFT', previous, 'TOPRIGHT', 6, 0)
					else frame:SetPoint('TOPLEFT', owner, 'TOPRIGHT', x, 0) end
					previous = frame
				end
			end
		end
	end
end

-- Cast bars -------------------------------------------------------------------------------
-- The client runs the bar from its duration object (no timing is read or
-- computed here), and every cast event simply asks again what is being cast.
-- The 'slider' cast style is the reference's slider: a thin track with the lit
-- fill, a round thumb with a hairline needle riding the fill's leading edge (it
-- is anchored to the fill texture, so the client moves it), a tick scale under
-- it, the spell name above on the left and the time on the right.
local function CastSliderParts(cast)
	local parts = cast.slider
	if parts then return parts end
	local track = cast.bar:GetParent()
	parts = {}
	parts.rail = CreateFrame('Frame', nil, track)
	parts.rail:SetAllPoints(track)
	parts.rail:SetFrameLevel(max(cast.bar:GetFrameLevel() - 1, 0))
	parts.rail.skin = Kit:Skin(parts.rail, 'slider-track', 'BACKGROUND', 0)
	parts.thumb = CreateFrame('Frame', nil, cast.bar)
	parts.thumb:SetFrameLevel(cast.bar:GetFrameLevel() + 3)
	parts.thumb:SetPoint('CENTER', cast.bar:GetStatusBarTexture(), 'RIGHT', 0, 0)
	parts.thumb.skin = Kit:Skin(parts.thumb, 'slider-thumb', 'ARTWORK', 0)
	for _, side in ipairs({'TOP', 'BOTTOM'}) do
		local needle = parts.thumb:CreateTexture(nil, 'OVERLAY')
		needle:SetColorTexture(1, 1, 1, 1)
		Kit:Tint(needle, 'ink')
		needle:SetWidth(1)
		needle:SetHeight(4)
		if side == 'TOP' then needle:SetPoint('BOTTOM', parts.thumb, 'TOP', 0, -2)
		else needle:SetPoint('TOP', parts.thumb, 'BOTTOM', 0, 2) end
		parts[side] = needle
	end
	-- The tick scale: tall every fifth, laid out against the scale's own width.
	parts.ticks = CreateFrame('Frame', nil, cast)
	parts.ticks:EnableMouse(false)
	parts.ticks.marks = {}
	for index = 0, 20 do
		local tick = parts.ticks:CreateTexture(nil, 'ARTWORK')
		tick:SetColorTexture(1, 1, 1, 1)
		parts.ticks.marks[index] = tick
	end
	parts.ticks:SetScript('OnSizeChanged', function(self, width)
		if IsSecret(width) or not width or width <= 0 then return end
		local px = UI.Pixel and UI.Pixel.Px(self, 1) or 1
		for index, tick in pairs(self.marks) do
			tick:SetSize(px, index % 5 == 0 and 5 or 3)
			tick:ClearAllPoints()
			tick:SetPoint('TOP', self, 'TOPLEFT', width * index / 20, 0)
		end
	end)
	cast.slider = parts
	return parts
end

local LayoutCastPlate
local function LayoutCastSlider(cast, cfg, height)
	local parts = CastSliderParts(cast)
	local track = cast.bar:GetParent()
	local onDark = Style() == 'dark'
	cast.shell:Hide()
	track.shell:Hide()
	parts.rail:Show(); parts.thumb:Show(); parts.ticks:Show()
	local thumbHeight = min(22, max(14, height * 0.6))
	parts.thumb:SetSize(thumbHeight * 30 / 46, thumbHeight)
	Kit:FitSprite(parts.thumb.skin, thumbHeight * 30 / 46, thumbHeight)
	for _, tick in pairs(parts.ticks.marks) do Kit:Tint(tick, onDark and 'darkDim' or 'dim') end
	Kit:Tint(parts.TOP, onDark and 'darkInk' or 'ink')
	Kit:Tint(parts.BOTTOM, onDark and 'darkInk' or 'ink')
	-- Name and time above, the track in the middle, the scale under it.
	cast.icon:SetSize(12, 12)
	cast.icon:ClearAllPoints()
	cast.icon:SetPoint('TOPLEFT', cast, 'TOPLEFT', 0, 0)
	cast.icon:SetShown(cfg.icon and true or false)
	cast.label:ClearAllPoints()
	if cfg.icon then cast.label:SetPoint('LEFT', cast.icon, 'RIGHT', 5, 0) else cast.label:SetPoint('TOPLEFT', cast, 'TOPLEFT', 0, -1) end
	cast.label:SetPoint('RIGHT', cast.time, 'LEFT', -4, 0)
	cast.label:SetShown(cfg.name and true or false)
	cast.time:ClearAllPoints()
	cast.time:SetPoint('TOPRIGHT', cast, 'TOPRIGHT', 0, -1)
	cast.time:SetShown(cfg.time and true or false)
	track:ClearAllPoints()
	track:SetHeight(8)
	track:SetPoint('LEFT', cast, 'LEFT', thumbHeight * 0.4, -2)
	track:SetPoint('RIGHT', cast, 'RIGHT', -thumbHeight * 0.4, -2)
	parts.ticks:ClearAllPoints()
	parts.ticks:SetPoint('TOPLEFT', track, 'BOTTOMLEFT', 0, -thumbHeight * 0.5 + 2)
	parts.ticks:SetPoint('TOPRIGHT', track, 'BOTTOMRIGHT', 0, -thumbHeight * 0.5 + 2)
	parts.ticks:SetHeight(5)
	parts.ticks:SetShown(height >= 26)
end

local function LayoutCast(cast)
	local cfg = CastCfg(cast.unit)
	if not cfg then return end
	if not cast.docked then cast:SetSize(cfg.width or 240, cfg.height or 30) end
	local height = cast.docked and cast:GetHeight() or (cfg.height or 30)
	if DB().castStyle == 'slider' then
		LayoutCastSlider(cast, cfg, height)
	else
		LayoutCastPlate(cast, cfg, height)
	end
	-- Under its frame: anchored there, and no spot of its own.
	if cfg.position == 'under' and frames[cast.unit] then
		local owner = frames[cast.unit]
		cast:ClearAllPoints()
		local lamps = owner.lampRail and Cfg(owner).classPower and (Cfg(owner).lampSize or 6) + 12 or 0
		cast:SetPoint('TOP', owner, 'BOTTOM', 0, -6 - lamps)
	end
end

function LayoutCastPlate(cast, cfg, height)
	-- The plate style: its housing and pill track (and none of the slider's parts).
	if cast.slider then cast.slider.rail:Hide(); cast.slider.thumb:Hide(); cast.slider.ticks:Hide() end
	-- Docked, the console decides (SetDocked's keepShell).
	cast.shell:SetShown(not cast.docked or cast.keepShell and true or false)
	cast.bar:GetParent().shell:Show()
	cast.bar:GetParent():SetHeight(8)
	cast.time:ClearAllPoints()
	cast.time:SetPoint('TOPRIGHT', -6, -5)
	local iconSize = max(8, height - 10)
	cast.icon:ClearAllPoints()
	cast.icon:SetPoint('LEFT', 6, 0)
	cast.icon:SetSize(iconSize, iconSize)
	cast.icon:SetShown(cfg.icon and true or false)
	local leftOf = cfg.icon and cast.icon or nil
	cast.label:ClearAllPoints()
	if leftOf then cast.label:SetPoint('TOPLEFT', leftOf, 'TOPRIGHT', 6, 0) else cast.label:SetPoint('TOPLEFT', 6, -5) end
	cast.label:SetPoint('RIGHT', cast.time, 'LEFT', -4, 0)
	cast.label:SetShown(cfg.name and true or false)
	cast.time:SetShown(cfg.time and true or false)
	local track = cast.bar:GetParent()
	track:ClearAllPoints()
	if leftOf then track:SetPoint('BOTTOMLEFT', leftOf, 'BOTTOMRIGHT', 6, 0)
	else track:SetPoint('BOTTOMLEFT', cast, 'BOTTOMLEFT', 6, 6) end
	track:SetPoint('BOTTOMRIGHT', cast, 'BOTTOMRIGHT', -6, 6)
end

local function BuildCastBar(unit, title, at)
	local style = Style()
	local ink = Kit.INK[style]
	local cfg = CastCfg(unit)
	local cast = CreateFrame('Frame', 'JiberishSpec01'..unit:gsub('^%l', strupper)..'Cast', UIParent)
	cast:SetSize(cfg.width or 240, cfg.height or 30)
	cast:SetScale(DB().scale or 1)
	cast.shell = Kit:Shell(cast, {surface = style, radius = 7})
	cast.icon = cast:CreateTexture(nil, 'ARTWORK')
	cast.icon:SetSize(20, 20)
	cast.icon:SetPoint('LEFT', 6, 0)
	cast.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	cast.iconMask = cast:CreateMaskTexture()
	cast.iconMask:SetTexture(Kit.media..'mask-icon.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
	cast.iconMask:SetAllPoints(cast.icon)
	cast.icon:AddMaskTexture(cast.iconMask)
	cast.time = Kit:Text(cast, '', 'tiny', ink[2], true)
	cast.time:SetPoint('TOPRIGHT', -6, -5)
	cast.time:SetJustifyH('RIGHT')
	cast.label = Kit:Label(cast, '', ink[1], 'tiny', true)
	cast.label:SetJustifyH('LEFT')
	cast.label:SetWordWrap(false)
	local track = CreateFrame('Frame', nil, cast)
	track:SetHeight(8)
	track.shell = Kit:Shell(track, {surface = style == 'dark' and 'glass' or 'lcd', radius = 99, shadow = false,
		fill = style ~= 'dark' and 'track' or nil})
	local bar = CreateFrame('StatusBar', nil, track)
	bar:SetPoint('TOPLEFT', 2, -2)
	bar:SetPoint('BOTTOMRIGHT', -2, 2)
	bar:SetStatusBarTexture(Kit.media..'bar-flat.tga')
	MaskFill(bar, 'mask-pill', 15)
	MarkBar(bar)
	bar:SetMinMaxValues(0, 1)
	bar.track = track
	cast.bar = bar
	ApplyFill(bar, DB().castTexture)
	ApplyTrack(bar, DB().track)
	cast:SetAlpha(0)
	cast:Hide()
	cast.unit = unit
	-- The time left, from the client's duration object while a cast runs.
	cast.clock = CreateFrame('Frame', nil, cast)

	-- The lock wash: the "can't interrupt" color over the fill, shown straight
	-- from the flag, which may be secret and is then never tested.
	local wash = bar:CreateTexture(nil, 'ARTWORK', nil, 3)
	wash:SetAllPoints(bar:GetStatusBarTexture())
	wash:SetColorTexture(1, 1, 1, 1)
	if bar.fillMask then wash:AddMaskTexture(bar.fillMask) end
	wash:Hide()
	cast.wash = wash

	local function Paint(channel, locked)
		bar:SetStatusBarColor(CastColor(channel and 'channel' or 'cast'))
		wash:SetVertexColor(CastColor('locked'))
		if IsSecret(locked) then
			if wash.SetAlphaFromBoolean then
				wash:Show()
				wash:SetAlphaFromBoolean(locked, 1, 0)
			else
				wash:Hide()
			end
		else
			wash:SetAlpha(1)
			wash:SetShown(locked and true or false)
		end
	end

	-- Is anything being cast? Asked through the duration objects, which are
	-- never secret; names and flags may be, so they are never tested.
	local function Casting()
		if UnitCastingDuration then
			local duration = UnitCastingDuration(unit)
			if duration then return duration, false, false end
			if UnitEmpoweredChannelDuration then
				duration = UnitEmpoweredChannelDuration(unit, true)
				if duration then return duration, true, true end
			end
			if UnitChannelDuration then
				duration = UnitChannelDuration(unit)
				if duration then return duration, true, false end
			end
			return nil
		end
		-- Older clients without duration objects have no secret values either.
		if UnitCastingInfo(unit) ~= nil then return true, false, false end
		if UnitChannelInfo(unit) ~= nil then return true, true, false end
		return nil
	end

	-- duration: the client's duration object, or true with plain start and end times.
	local function StartClock(duration, endTime)
		cast.time:SetText('')
		if not CastCfg(unit).time then cast.clock:SetScript('OnUpdate', nil) return end
		local elapsed = 1
		cast.clock:SetScript('OnUpdate', function(_, delta)
			elapsed = elapsed + delta
			if elapsed < 0.05 then return end
			elapsed = 0
			if duration ~= true and duration.GetRemainingDuration then
				if not pcall(function() cast.time:SetFormattedText('%.1f', duration:GetRemainingDuration()) end) then cast.time:SetText('') end
			elseif endTime then
				cast.time:SetFormattedText('%.1f', max(endTime / 1000 - GetTime(), 0))
			end
		end)
	end

	-- Shows whatever the unit is casting right now; false if nothing.
	local function Start()
		local duration, channel, empowering = Casting()
		if not duration then return false end
		local name, texture, notInterruptible
		if channel then name, _, texture, _, _, _, notInterruptible = UnitChannelInfo(unit)
		else name, _, texture, _, _, _, _, notInterruptible = UnitCastingInfo(unit) end
		cast.label:SetText(name)
		cast.icon:SetTexture(texture)
		Paint(channel, notInterruptible)
		if duration ~= true and bar.SetTimerDuration and TIMER then
			-- An empowered cast charges up; a channel drains.
			bar:SetTimerDuration(duration, IMMEDIATE, (channel and not empowering) and TIMER.RemainingTime or TIMER.ElapsedTime)
			cast:SetScript('OnUpdate', nil)
			StartClock(duration)
		else
			local _, _, _, startTime, endTime = (channel and UnitChannelInfo or UnitCastingInfo)(unit)
			if IsSecret(startTime) or IsSecret(endTime) or not startTime then return false end
			bar:SetMinMaxValues(startTime / 1000, endTime / 1000)
			cast:SetScript('OnUpdate', function()
				local now = GetTime()
				bar:SetValue(channel and (endTime / 1000 - (now - startTime / 1000)) or now)
			end)
			StartClock(true, endTime)
		end
		cast.stopping = nil
		cast:Show()
		Kit:FadeTo(cast, 1, 'FAST')
		return true
	end

	local function Stop(failed)
		if cast.stopping or not cast:IsShown() then return end
		cast.stopping = true
		cast:SetScript('OnUpdate', nil)
		cast.clock:SetScript('OnUpdate', nil)
		cast.time:SetText('')
		local function Out()
			if cast.stopping then Kit:FadeTo(cast, 0, 'FAST', function() if cast.stopping then cast:Hide() end end) end
		end
		if failed then
			-- An interrupted cast holds a moment in red so the eye catches it.
			wash:Hide()
			bar:SetStatusBarColor(CastColor('interrupted'))
			cast.label:SetText(failed)
			C_Timer.After(0.6, Out)
		else
			Out()
		end
	end

	local function Refresh()
		local ok, started = pcall(Start)
		if not (ok and started) then Stop() end
	end

	cast:SetScript('OnEvent', function(_, event)
		if UI:MoversUnlocked() then return end
		if event == 'UNIT_SPELLCAST_INTERRUPTED' or event == 'UNIT_SPELLCAST_FAILED' then
			-- A rejected key press during a cast also fires FAILED: only stop if
			-- nothing is being cast any more.
			local ok, casting = pcall(Casting)
			if ok and casting then Refresh()
			else Stop(event == 'UNIT_SPELLCAST_INTERRUPTED' and 'INTERRUPTED' or 'FAILED') end
		elseif event == 'PLAYER_TARGET_CHANGED' then
			cast.stopping = true
			cast:Hide()
			Refresh()
		else
			-- Starts, stops, delays and updates all just ask the client again.
			Refresh()
		end
	end)
	for _, event in ipairs({'UNIT_SPELLCAST_START', 'UNIT_SPELLCAST_STOP', 'UNIT_SPELLCAST_FAILED', 'UNIT_SPELLCAST_INTERRUPTED',
		'UNIT_SPELLCAST_DELAYED', 'UNIT_SPELLCAST_CHANNEL_START', 'UNIT_SPELLCAST_CHANNEL_UPDATE', 'UNIT_SPELLCAST_CHANNEL_STOP',
		'UNIT_SPELLCAST_INTERRUPTIBLE', 'UNIT_SPELLCAST_NOT_INTERRUPTIBLE', 'UNIT_SPELLCAST_EMPOWER_START',
		'UNIT_SPELLCAST_EMPOWER_UPDATE', 'UNIT_SPELLCAST_EMPOWER_STOP'}) do
		pcall(cast.RegisterUnitEvent, cast, event, unit)
	end
	if unit == 'target' then cast:RegisterEvent('PLAYER_TARGET_CHANGED') end
	-- 'under' rides under its frame; 'docked' and 'free' have their own spot
	-- (a docked bar uses it when the console isn't docking).
	if cfg.position ~= 'under' or not frames[unit] then UI:RegisterMover(cast, 'cb.'..unit, title, at) end
	function cast:SetPreview(on)
		if on then
			self.stopping = nil
			self:SetScript('OnUpdate', nil)
			self.clock:SetScript('OnUpdate', nil)
			self.label:SetText(strupper(title))
			self.time:SetText('1.5')
			self.bar:SetMinMaxValues(0, 1)
			self.bar:SetValue(0.6)
			Paint(true)
			self:Show()
			self:SetAlpha(1)
		else
			self.stopping = true
			self:SetAlpha(0)
			self:Hide()
			-- Pick up a cast that started while placing.
			Refresh()
		end
	end
	casts[unit] = cast
	LayoutCast(cast)
	return cast
end

-- Blizzard frames this replaces. Boss and raid frames stay Blizzard's.
local function RetireBlizzard(layout)
	local unit = layout.unit
	if unit == 'player' then UI:Retire(_G.PlayerFrame)
	elseif unit == 'target' then UI:Retire(_G.TargetFrame); UI:Retire(_G.ComboFrame)
	elseif unit == 'focus' then UI:Retire(_G.FocusFrame)
	elseif unit == 'pet' then UI:Retire(_G.PetFrame)
	elseif unit == 'party1' then
		-- Members live in a pool inside PartyFrame; hiding the parent hides them.
		UI:Retire(_G.PartyFrame)
		for index = 1, 4 do UI:Retire(_G['PartyMemberFrame'..index]) end
		-- Edit Mode's "raid-style party frames" would show beside ours.
		UI:Retire(_G.CompactPartyFrame)
	end
end

local function HideBlizzardCastBar()
	for _, name in ipairs({'PlayerCastingBarFrame', 'CastingBarFrame'}) do
		local bar = _G[name]
		if bar and not (bar.IsForbidden and bar:IsForbidden()) then UI:Retire(bar) end
	end
end

local function Add(layout)
	local frame = Build(layout)
	frames[layout.unit] = frame
	ordered[#ordered + 1] = frame
	return frame
end

-- A frame (or the console holding it) rescaled from the Layout page or a
-- handle: redraw its model at the new scale. Moves alone don't redraw.
if UI.OnMoversChanged then
	UI:OnMoversChanged(function(key)
		if key == '__select' or key == '__lock' then return end
		for _, frame in ipairs(ordered) do
			if frame.model and frame.portraitMode == 'model' then
				local scale = frame:GetEffectiveScale()
				if frame.modelScale ~= scale then
					frame.modelScale = scale
					RefreshModel(frame)
				end
			end
		end
	end)
end

-- A model drawn before the interface's scale settles (login, a UI scale
-- change) renders off-centre or out of its box: redraw every model after.
UI.Pixel.OnChange(function()
	for _, frame in pairs(frames) do
		if frame.model and frame.portraitMode == 'model' then RefreshModel(frame) end
	end
end)

-- 0.5.1: the combat cue took over marking combat, so the sweep is off by
-- default, and switched off once in profiles saved before.
local function MoveSweep()
	if DB().sweepMoved then return end
	DB().combatSweep = false
	DB().sweepMoved = true
end

function module:Enable()
	MoveSweep()
	-- 0.5.0's gloss switch: off carries over as no motion.
	if DB().powerGloss == false then DB().powerMotion = 'off' end
	DB().powerGloss = nil
	if InCombatLockdown() then
		UI:AfterCombat(function()
			self.enabled = UI:Safe(self.Enable, self)
			-- The console docked nothing while these were missing: let it look again.
			local bars = UI.modules.actionbars
			if self.enabled and bars and bars.enabled and bars.Refresh then UI:Safe(bars.Refresh, bars) end
		end, 'unitframes')
		return
	end
	-- Party frames sit under one parent that hides them in raids, where the raid
	-- frames take over, and when solo (and always while raid frames show the party).
	module.partyHeader = CreateFrame('Frame', 'JiberishSpec01PartyHeader', UIParent, 'SecureHandlerStateTemplate')
	module.partyHeader:SetAllPoints()
	RegisterStateDriver(module.partyHeader, 'visibility', PartyVisibility())
	local units = DB().units
	for _, layout in ipairs(LAYOUT) do
		local skip = not units[layout.key].enable or (layout.party and not DB().party) or (layout.unit == 'focus' and not _G.FocusFrame)
		if not skip then
			Add(layout)
			RetireBlizzard(layout)
		end
	end
	for _, layout in ipairs(EXTRAS) do
		if Indicators()[layout.extra] and frames[layout.owner] then Add(layout) end
	end
	PlaceExtras()
	if DB().castbar then
		local playerCast = BuildCastBar('player', 'Player cast', {'BOTTOM', 0, 196})
		local targetCast = BuildCastBar('target', 'Target cast', {'BOTTOM', 228, 166})
		-- Only cast bars set to 'docked' are handed to the console.
		if CastCfg('player').position == 'docked' then module.playerCast = playerCast end
		if CastCfg('target').position == 'docked' then module.targetCast = targetCast end
		HideBlizzardCastBar()
		-- Auras below a frame make room for a cast bar placed under it.
		for unit in pairs(casts) do if frames[unit] then UI:Safe(LayoutAuras, frames[unit]) end end
	end
	FindRangeSpell()
	UpdateRangeDriver()
	local driver = CreateFrame('Frame')
	driver:RegisterEvent('PLAYER_REGEN_DISABLED')
	driver:RegisterEvent('PLAYER_REGEN_ENABLED')
	driver:RegisterEvent('SPELLS_CHANGED')
	driver:SetScript('OnEvent', function(_, event)
		if event == 'SPELLS_CHANGED' then return FindRangeSpell() end
		if event == 'PLAYER_REGEN_DISABLED' then SweepAll('lamp', 0.5, 0.9)
		else SweepAll('amber', 0.9, 0.55) end
	end)
end

-- Docked inside the console, a frame or cast bar sits on the console's own
-- housing, so it drops its shell; undocked it gets it back.
-- keepShell: an LCD-style frame keeps its own LCD face inside the console.
function module:SetDocked(object, docked, keepShell)
	object.docked = docked and true or nil
	object.keepShell = keepShell and true or nil
	if object.shapeName then ApplyShell(object, object.shapeName)
	elseif object.shell then object.shell:SetShown(not docked or keepShell and true or false) end
	-- A cast bar's width changes with its slot; its parts follow.
	if object.label and object.bar then LayoutCast(object) end
end

local lastPartyAsRaid
function module:Refresh()
	MoveSweep()
	for _, frame in ipairs(ordered) do
		UI:Safe(Layout, frame)
		if frame:IsShown() then UI:Safe(UpdateAll, frame) end
	end
	PlaceExtras()
	for key, cast in pairs(casts) do
		UI:Safe(LayoutCast, cast)
		UI:Safe(ApplyFill, cast.bar, DB().castTexture)
		UI:Safe(ApplyTrack, cast.bar, DB().track)
		if not InCombatLockdown() and not cast.docked then
			UI:SetMoverBaseScale('cb.'..key, DB().scale or 1, cast, CastCfg(key).position == 'under')
		end
	end
	-- The raid frames took over (or gave back) the party.
	local asRaid = PartyAsRaid()
	if module.partyHeader and asRaid ~= lastPartyAsRaid and not UI:MoversUnlocked() then
		lastPartyAsRaid = asRaid
		UI:AfterCombat(function()
			RegisterStateDriver(module.partyHeader, 'visibility', PartyVisibility())
			for _, frame in ipairs(ordered) do if frame.layout.party then Watch(frame) end end
		end, 'uf.partyAsRaid')
	end
	UpdateRangeDriver()
	-- A scale change doesn't resize, so physical-pixel edges are refit here.
	Kit:RefitShells()
end

-- The settings page -------------------------------------------------------------------
local function Int(value) return format('%d', value + 0.5) end
local function Percent(value) return format('%d%%', value * 100 + 0.5) end

-- What each frame's cards offer.
local PAGE_FRAMES = {
	{key = 'player', title = 'Player', large = true, power = true, classpower = true, auras = true},
	{key = 'target', title = 'Target', large = true, power = true, auras = true, range = true, arrive = true},
	{key = 'targettarget', title = 'Target of target'},
	{key = 'focus', title = 'Focus', power = true, auras = true, range = true},
	{key = 'pet', title = 'Pet', auras = true},
	{key = 'party', title = 'Party', power = true, auras = true, range = true},
}
local SHAPE_ITEMS = {{'device', 'Device'}, {'console', 'Console'}, {'gauge', 'Gauge'}, {'tape', 'Tape'}, {'printed', 'Printed'},
	{'bar', 'Bar'}, {'square', 'Square'}, {'slim', 'Slim'}, {'lcdstrip', 'LCD strip'}}
local FRAME_SHAPES = {{'default', 'Page default'}}
for _, item in ipairs(SHAPE_ITEMS) do FRAME_SHAPES[#FRAME_SHAPES + 1] = item end
local SHAPE_NOTE = 'Device: header, portrait, LCD and meters. Bar: a rectangle that is all meter, name and health printed on it. '..
	'Square: a tile with big LCD digits. Slim: a thin line with the name above. LCD strip: a gray readout with a dot meter. '..
	'Console: a big LCD readout, meters with segmented power and a row of status lamps. Gauge: a round bezel that fills with health. '..
	'Tape: a meter over a tick scale. Printed: a spec sheet with HP and PWR legends. '..
	'Only Device has a portrait. Picking a shape sets the frame to its natural size.'
local PORTRAITS = {{'default', 'Default'}, {'model', '3D'}, {'texture', '2D'}, {'class', 'Class'}, {'matrix', 'LED avatar'},
	{'monogram', 'Monogram'}, {'ring', 'Round avatar'}, {'glyph', 'Class avatar'}, {'key', 'Key avatar'}, {'off', 'None'}}
local METERS = {{'default', 'Default'}, {'dots', 'Dots'}, {'pill', 'Pill'}, {'bar', 'Bar'}}
local TRACK_FRAME = {{'default', 'Page default'}, {'housing', 'Housing'}, {'screen', 'Black'}, {'dim', 'Dim fill'}, {'custom', 'Custom'},
	{'clear', 'None'}}
-- Health colors: the key color, SPEC-01's lamps and swatches, class, reaction, by health, custom.
local function HealthColors(withDefault)
	local items = {}
	if withDefault then items[1] = {'default', 'Page default'} end
	for _, item in ipairs({{'accent', 'Key color'}, {'ledGreen', 'Lamp green'}, {'ledBlue', 'Lamp blue'}, {'amber', 'Amber'},
		{'screen', 'Screen amber'}, {'class', 'Class and reaction'}, {'reaction', 'Reaction'}, {'gradient', 'By health'},
		{'gradient2', 'Two-color gradient'}}) do
		items[#items + 1] = item
	end
	for _, name in ipairs(Kit.accentOrder or {}) do
		local swatch = Kit.accents[name]
		if swatch then items[#items + 1] = {'swatch:'..name, (swatch.name or name)..' swatch'} end
	end
	if withDefault then items[#items + 1] = {'custom', 'Custom'} end
	return items
end
local COLORS = HealthColors(true)
local HEALTH_TEXT = {{'percent', 'Percent'}, {'current', 'Current'}, {'both', 'Current / max'}, {'deficit', 'Missing'}, {'none', 'None'}}
local POWER_TEXT = {{'percent', 'Percent'}, {'current', 'Current'}, {'both', 'Current / max'}}
local TAGS = {{'class', 'Class or type'}, {'power', 'Power'}, {'name', 'Name'}, {'none', 'Nothing'}}

local function FrameCards(info)
	local key = info.key
	local function P(leaf) return 'unitframes.units.'..key..'.'..leaf end
	local function Get(leaf) return UI.db.unitframes.units[key][leaf] end
	local function NotDevice() return Resolve(Get('shape')) ~= 'device' end
	local look = {
		{'switch', 'Show', P('enable'), 'Off: Blizzard\'s own frame stays.', reload = true},
		{'dropdown', 'Shape', P('shape'), items = FRAME_SHAPES, note = 'Page default follows the Style card.',
			set = function(value) UI:SetUnitFrameShape(value, key) end},
		{'slider', 'Width', P('width'), 32, 320, 2, nil, format = Int},
		{'slider', 'Height', P('height'), 12, 110, 1, nil, format = Int},
		{'slider', 'Scale', P('scale'), 0.5, 2, 0.05, 'On top of the page\'s scale.', format = Percent},
		{'dropdown', 'Portrait', P('portrait'), items = PORTRAITS, disabled = NotDevice,
			note = 'LED avatar: SPEC-01\'s avatar, a glyph lit from the name behind a round lens. Monogram: initials on the lens. '..
			'Round, class and key avatars: the portrait or class icon in a ringed lens or on a key. None collapses the box.'},
		{'segmented', 'Meters', P('barStyle'), items = METERS, reload = true},
		{'dropdown', 'Health texture', P('healthTexture'), items = function() return UI.BarLooks.FillItems(true) end, since = '0.5.1'},
		{'dropdown', 'Health color', P('healthColor'), items = COLORS},
		{'color', 'Custom health color', P('healthCustom'), hidden = function() return Get('healthColor') ~= 'custom' end},
		{'segmented', 'Gradient colors', P('healthStops'), items = {{'page', 'Page\'s'}, {'own', 'This frame\'s'}}, since = '0.5.1',
			hidden = function() return Get('healthColor') ~= 'gradient2' end},
		{'color', 'Gradient start', P('healthStart'), since = '0.5.1',
			hidden = function() return Get('healthColor') ~= 'gradient2' or Get('healthStops') ~= 'own' end},
		{'color', 'Gradient end', P('healthEnd'), since = '0.5.1',
			hidden = function() return Get('healthColor') ~= 'gradient2' or Get('healthStops') ~= 'own' end},
		{'segmented', 'Gradient direction', P('healthDirection'), items = {{'horizontal', 'Along'}, {'vertical', 'Up'}}, since = '0.5.1',
			hidden = function() return Get('healthColor') ~= 'gradient2' or Get('healthStops') ~= 'own' end},
		{'slider', 'Health meter height', P('healthHeight'), 2, 16, 1, nil, format = Int},
	}
	if info.power then
		look[#look + 1] = {'slider', 'Power meter height', P('powerHeight'), 1, 10, 1, nil, format = Int}
		look[#look + 1] = {'dropdown', 'Power texture', P('powerTexture'), items = function() return UI.BarLooks.FillItems(true) end,
			since = '0.5.1'}
	end
	look[#look + 1] = {'dropdown', 'Track', P('track'), items = TRACK_FRAME, since = '0.5.1',
		note = 'Behind the fill. Page default follows the Textures card.'}
	look[#look + 1] = {'switch', 'Header', P('header'), info.large and 'The printed row: lamp, model code, name and level.' or 'The name row.'}
	if info.large then
		look[#look + 1] = {'switch', 'Model code', P('headerCode'), nil, disabled = function() return not Get('header') end}
		look[#look + 1] = {'switch', 'Level', P('headerLevel'), nil, disabled = function() return not Get('header') end}
	end
	look[#look + 1] = {'switch', 'Combat lamp', P('combatLamp'), 'Lit while the unit is in combat.'}
	if info.large then
		look[#look + 1] = {'segmented', 'Status lamps', P('status'), items = {{'off', 'Off'}, {'lit', 'Lit only'}, {'panel', 'Panel'}},
			since = '0.5.1', note = 'SPEC-01 glyphs for combat, resting, group leader, role and PvP. Lit only: just the ones that hold. '..
			'Panel: every glyph printed, the idle ones unlit. The Console shape always shows the panel.'}
	end
	look[#look + 1] = {'switch', 'Combat sweep', P('sweep'), 'Its light as combat starts and ends.'}
	if info.arrive then look[#look + 1] = {'switch', 'Arrival', P('arrive'), 'A new target fades in and its bars glide up.'} end
	if info.range then
		look[#look + 1] = {'switch', 'Fade out of range', P('rangeFade'), 'The client\'s own range answer, so it works in combat.'}
		look[#look + 1] = {'slider', 'Out of range opacity', P('rangeAlpha'), 0.1, 1, 0.05, nil, format = Percent,
			disabled = function() return not Get('rangeFade') end}
	end
	if info.classpower then
		look[#look + 1] = {'switch', 'Class resource lamps', P('classPower'), 'Combo points, holy power, runes and the like.'}
		look[#look + 1] = {'slider', 'Lamp size', P('lampSize'), 4, 12, 1, nil, format = Int,
			disabled = function() return not Get('classPower') end}
	end

	local text = {}
	if info.large then text[#text + 1] = {'dropdown', 'LCD label', P('lcdTag'), items = TAGS, note = 'The small print left of the digits.'} end
	text[#text + 1] = {'dropdown', 'Health text', P('healthText'), items = HEALTH_TEXT}
	if info.large and info.power then
		text[#text + 1] = {'dropdown', 'Power text', P('powerText'), items = POWER_TEXT,
			hidden = function() return Get('lcdTag') ~= 'power' end, note = 'Shown when the LCD label is Power.'}
	end
	text[#text + 1] = {'switch', 'Short numbers', P('shortNumbers'), '12.4k rather than 12,400.'}
	text[#text + 1] = {'slider', 'Name size', P('nameSize'), 6, 16, 1, nil, format = Int}
	text[#text + 1] = {'slider', 'Digits size', P('digitsSize'), 6, 22, 1, nil, format = Int}

	local cards = {{title = info.title, rows = look}, {title = info.title..' text', rows = text}}
	if info.auras then
		local function Off() return not Get('auras') end
		cards[#cards + 1] = {title = info.title..' auras', rows = {
			{'switch', 'Auras', P('auras'), 'Debuffs on charcoal keys, buffs on light ones.', disabled = function() return not UI.db.unitframes.auras end},
			{'switch', 'Debuffs', P('debuffs'), nil, disabled = Off},
			{'switch', 'Buffs', P('buffs'), nil, disabled = Off},
			{'switch', 'Only mine', P('onlyMine'), 'Only auras you cast.', disabled = Off},
			{'switch', 'Boss auras only', P('bossOnly'), nil, disabled = Off},
			{'slider', 'Size', P('auraSize'), 12, 40, 1, nil, format = Int, disabled = Off},
			{'slider', 'Most shown', P('auraMax'), 1, 24, 1, nil, format = Int, disabled = Off},
			{'slider', 'Per row', P('auraPerRow'), 1, 12, 1, nil, format = Int, disabled = Off},
			{'segmented', 'Position', P('auraPosition'), items = {{'below', 'Below'}, {'above', 'Above'}, {'right', 'Right'}, {'left', 'Left'}}},
			{'segmented', 'Grow', P('auraGrow'), items = {{'right', 'Rightward'}, {'left', 'Leftward'}},
				hidden = function() local position = Get('auraPosition') return position == 'right' or position == 'left' end},
			{'switch', 'Time left', P('auraTime'), 'The client\'s countdown on each key.', disabled = Off},
			{'slider', 'Time size', P('auraTimeSize'), 6, 14, 1, 'The countdown\'s size; it never grows past half the key.', format = Int,
				disabled = function() return Off() or not Get('auraTime') end, since = '0.5.1'},
			{'switch', 'Cooldown swipe', P('auraSwipe'), nil, disabled = Off},
			{'slider', 'Stack count size', P('stackSize'), 6, 16, 1, nil, format = Int, disabled = Off},
		}}
	end
	return cards
end

local function CastCard(unit, title)
	local function P(leaf) return 'unitframes.cast.'..unit..'.'..leaf end
	return {title = title, rows = {
		{'dropdown', 'Look', 'unitframes.castStyle', items = {{'bar', 'Plate'}, {'slider', 'Slider'}}, since = '0.5.0',
			note = 'Plate: a housing with a pill track. Slider: the reference\'s slider, a thumb riding the fill over a tick scale. Both bars use it.'},
		{'segmented', 'Position', P('position'), items = {{'docked', 'Console'}, {'under', 'Under frame'}, {'free', 'Free'}}, reload = true,
			note = 'Console: in the action bar console when it docks frames, else its own spot.'},
		{'slider', 'Width', P('width'), 120, 400, 2, 'Inside the console the slot sets the width.', format = Int},
		{'slider', 'Height', P('height'), 16, 48, 1, nil, format = Int},
		{'switch', 'Icon', P('icon')},
		{'switch', 'Spell name', P('name')},
		{'switch', 'Time left', P('time')},
	}}
end

local cards = {
	{title = 'Style', rows = {
		{'dropdown', 'Shape', 'unitframes.shape', items = SHAPE_ITEMS, note = SHAPE_NOTE, since = '0.5.0',
			set = function(value) UI:SetUnitFrameShape(value) end},
		{'segmented', 'Style', 'style.unitframes', items = {{'paper', 'Paper'}, {'dark', 'Dark'}, {'lcd', 'LCD'}, {'blizzard', 'Blizzard'}}, reload = true,
			note = 'Paper: the reference\'s light housing. Dark: charcoal. LCD: the whole frame is a readout.'},
		{'segmented', 'Meters', 'unitframes.barStyle', items = {{'dots', 'Dots'}, {'pill', 'Pill'}, {'bar', 'Bar'}}, reload = true,
			note = 'Dots: LED meter. Pill: the slider\'s rounded fill. Bar: a flat fill on a charcoal plate. Each frame can choose its own.'},
		{'slider', 'Scale', 'unitframes.scale', 0.6, 1.6, 0.05, 'Size of every unit frame and cast bar.', format = Percent},
		{'button', 'Placement', 'Move frames', function() UI:ToggleHub(nil, false); UI:ToggleMovers() end, 'Snaps to a grid and to other frames.'},
	}},
	{title = 'Textures', rows = {
		{'dropdown', 'Health', 'unitframes.healthTexture', items = function() return UI.BarLooks.FillItems() end, since = '0.5.1',
			note = 'Flat: the reference\'s fill. Solid: one plain color. Gloss: a lit upper half. Gradient: dark to bright toward the end. '..
				'Glass: a sheen with a lit top edge. Segmented: cells divided by hairlines. Status bar textures from other addons are listed too. '..
				'Dot meters keep their dots and take the light only.'},
		{'dropdown', 'Power', 'unitframes.powerTexture', items = function() return UI.BarLooks.FillItems() end, since = '0.5.1'},
		{'dropdown', 'Cast bars', 'unitframes.castTexture', items = function() return UI.BarLooks.FillItems() end, since = '0.5.1',
			note = 'Player and target cast bars.'},
		{'segmented', 'Track', 'unitframes.track', items = UI.BarLooks.TrackItems, since = '0.5.1',
			note = 'Behind the fill: the meter\'s housing, a black screen, a dim wash of the fill\'s color, or nothing. Dot meters keep a housing.'},
		{'note', 'Each frame can choose its own textures and track in its card below. Health can also be colored by health in Defaults.'},
	}},
	{title = 'Defaults', rows = {
		{'dropdown', 'Health color', 'unitframes.healthColor', items = HealthColors(false),
			note = 'For frames left on Page default. Lamp green, lamp blue and amber are SPEC-01\'s own lamps; the swatches are its six key colors.'},
		{'dropdown', 'Portrait', 'unitframes.portrait', items = {{'model', '3D'}, {'texture', '2D'}, {'class', 'Class'}, {'matrix', 'LED avatar'},
			{'monogram', 'Monogram'}, {'ring', 'Round avatar'}, {'glyph', 'Class avatar'}, {'key', 'Key avatar'}},
			note = 'For player and target left on Default.'},
		{'segmented', 'Avatar ring', 'unitframes.avatarRing', items = {{'reaction', 'Reaction'}, {'class', 'Class'}, {'key', 'Key color'}},
			since = '0.5.1', note = 'The colored ring between an avatar\'s bezel and its lens.'},
		{'switch', 'Presence lamp', 'unitframes.avatarStatus', 'On an avatar\'s rim: green online, red in combat, amber away, unlit when dead or offline.',
			since = '0.5.1'},
		{'switch', 'Cast bars', 'unitframes.castbar', 'Player and target, on the client\'s own timing.', reload = true},
		{'switch', 'Auras', 'unitframes.auras', 'Every frame\'s auras at once; each frame has its own below.'},
		{'switch', 'Party frames', 'unitframes.party', 'Compact devices for party members.', reload = true},
		{'switch', 'Target arrival', 'unitframes.arrive', 'A new target fades in, its bars glide up and the portrait settles.'},
		{'switch', 'Combat sweep', 'unitframes.combatSweep', 'A light along each frame as combat starts and ends; off while the combat cue is on.'},
		{'switch', 'Aura timer lines', 'unitframes.auraLines', 'A thin line over each aura key runs down with its time left.', since = '0.5.0'},
	}},
	{title = 'Colors', rows = {
		{'note', 'Health color modes, including the two-color gradient, are under Defaults and on each frame. These are the colors those modes and the rest of the frame use.'},
		{'header', 'Health gradient'},
		{'color', 'Start', 'unitframes.healthStart', 'Where the fill begins (left, or the bottom).', since = '0.5.1'},
		{'color', 'End', 'unitframes.healthEnd', 'Where the fill ends (its edge, or the top).', since = '0.5.1'},
		{'segmented', 'Direction', 'unitframes.healthDirection', items = {{'horizontal', 'Along the bar'}, {'vertical', 'Up the bar'}}, since = '0.5.1'},
		{'header', 'Power'},
		{'segmented', 'Power colors', 'unitframes.powerMode', items = {{'custom', 'Per type'}, {'blizzard', 'Game'}, {'key', 'Key color'}},
			since = '0.5.1', note = 'Per type: the colors below, one for each kind of power.'},
		{'color', 'Mana', 'unitframes.powerColors.MANA', since = '0.5.1', hidden = function() return DB().powerMode ~= 'custom' end},
		{'color', 'Rage', 'unitframes.powerColors.RAGE', since = '0.5.1', hidden = function() return DB().powerMode ~= 'custom' end},
		{'color', 'Energy', 'unitframes.powerColors.ENERGY', since = '0.5.1', hidden = function() return DB().powerMode ~= 'custom' end},
		{'color', 'Focus', 'unitframes.powerColors.FOCUS', since = '0.5.1', hidden = function() return DB().powerMode ~= 'custom' end},
		{'color', 'Runic power', 'unitframes.powerColors.RUNIC_POWER', since = '0.5.1', hidden = function() return DB().powerMode ~= 'custom' end},
		{'color', 'Astral power', 'unitframes.powerColors.LUNAR_POWER', since = '0.5.1', hidden = function() return DB().powerMode ~= 'custom' end},
		{'color', 'Maelstrom', 'unitframes.powerColors.MAELSTROM', since = '0.5.1', hidden = function() return DB().powerMode ~= 'custom' end},
		{'color', 'Insanity', 'unitframes.powerColors.INSANITY', since = '0.5.1', hidden = function() return DB().powerMode ~= 'custom' end},
		{'color', 'Fury', 'unitframes.powerColors.FURY', since = '0.5.1', hidden = function() return DB().powerMode ~= 'custom' end},
		{'color', 'Pain', 'unitframes.powerColors.PAIN', since = '0.5.1', hidden = function() return DB().powerMode ~= 'custom' end},
		{'color', 'Essence', 'unitframes.powerColors.ESSENCE', since = '0.5.1', hidden = function() return DB().powerMode ~= 'custom' end},
		{'color', 'Other', 'unitframes.powerColors.OTHER', 'Any other kind of power.', since = '0.5.1',
			hidden = function() return DB().powerMode ~= 'custom' end},
		{'switch', 'Power gradient', 'unitframes.powerGradient', 'From a darker shade of the color to the color itself.', since = '0.5.1'},
		{'segmented', 'Power direction', 'unitframes.powerDirection', items = {{'horizontal', 'Along the bar'}, {'vertical', 'Up the bar'}},
			since = '0.5.1', hidden = function() return not DB().powerGradient end},
		{'header', 'Cast bars'},
		{'segmented', 'Cast colors', 'unitframes.castMode', items = {{'key', 'Key color'}, {'custom', 'Custom'}}, since = '0.5.1',
			note = 'Also used by the boss and arena cast bars.'},
		{'color', 'Casting', 'unitframes.castColors.cast', since = '0.5.1', hidden = function() return DB().castMode ~= 'custom' end},
		{'color', 'Channeling', 'unitframes.castColors.channel', since = '0.5.1', hidden = function() return DB().castMode ~= 'custom' end},
		{'color', 'Can\'t interrupt', 'unitframes.castColors.locked', since = '0.5.1', hidden = function() return DB().castMode ~= 'custom' end},
		{'color', 'Interrupted', 'unitframes.castColors.interrupted', since = '0.5.1', hidden = function() return DB().castMode ~= 'custom' end},
		{'header', 'Track'},
		{'color', 'Track color', 'unitframes.trackColor', 'Used when the Textures card\'s track is Custom.', since = '0.5.1'},
		{'slider', 'Track opacity', 'unitframes.trackAlpha', 0, 1, 0.05, nil, format = Percent, since = '0.5.1'},
		{'header', 'Text and housing'},
		{'segmented', 'Name color', 'unitframes.nameColor', items = {{'default', 'Default'}, {'class', 'Class'}, {'custom', 'Custom'}}, since = '0.5.1'},
		{'color', 'Custom name color', 'unitframes.nameCustom', since = '0.5.1', hidden = function() return DB().nameColor ~= 'custom' end},
		{'segmented', 'Digits and level', 'unitframes.textColor', items = {{'default', 'Default'}, {'custom', 'Custom'}}, since = '0.5.1'},
		{'color', 'Custom text color', 'unitframes.textCustom', since = '0.5.1', hidden = function() return DB().textColor ~= 'custom' end},
		{'segmented', 'Housing', 'unitframes.housing', items = {{'default', 'Theme'}, {'custom', 'Custom tint'}}, since = '0.5.1',
			note = 'The unit frames\' own housing color, over the theme\'s finish.'},
		{'color', 'Housing color', 'unitframes.housingColor', since = '0.5.1', hidden = function() return DB().housing ~= 'custom' end},
		{'slider', 'Housing opacity', 'unitframes.housingAlpha', 0.2, 1, 0.05, nil, format = Percent, since = '0.5.1',
			hidden = function() return DB().housing ~= 'custom' end},
	}},
	{title = 'Power', rows = {
		{'segmented', 'Motion', 'unitframes.powerMotion', items = {{'off', 'Off'}, {'scan', 'Scan line'}, {'spark', 'Spark'}, {'pulse', 'Pulse'}},
			since = '0.5.1', note = 'Scan line: a crisp hairline sweeps the fill, calm for mana, quicker for energy and rage. '..
			'Spark: a lit edge rides the fill and flares as power comes back. Pulse: the fill brightens and settles. The meter flashes when full.'},
		{'dropdown', 'Big digits', 'unitframes.powerDigits', items = {{'off', 'Off'}, {'current', 'Amount'}, {'percent', 'Percent'}},
			note = 'Large figures beside the player\'s and target\'s power meter.', since = '0.5.0'},
		{'segmented', 'Digits side', 'unitframes.powerDigitsSide', items = {{'outer', 'Outer'}, {'inner', 'Inner'}},
			note = 'Outer is away from the screen centre.', hidden = function() return UI.db.unitframes.powerDigits == 'off' end},
		{'slider', 'Digits size', 'unitframes.powerDigitsSize', 12, 32, 1, nil, format = function(v) return tostring(v) end,
			hidden = function() return UI.db.unitframes.powerDigits == 'off' end},
	}},
}
for _, info in ipairs(PAGE_FRAMES) do
	for _, card in ipairs(FrameCards(info)) do cards[#cards + 1] = card end
end
cards[#cards + 1] = {title = 'Party indicators', rows = {
	{'switch', 'Role', 'unitframes.indicators.role', 'TNK, HLR or DPS on a chip.'},
	{'switch', 'Leader', 'unitframes.indicators.leader'},
	{'switch', 'Ready check', 'unitframes.indicators.readyCheck', 'Each answer, kept a few seconds after the check.'},
	{'switch', 'Summons', 'unitframes.indicators.summon'},
	{'switch', 'Resurrections', 'unitframes.indicators.resurrect'},
	{'switch', 'Raid markers', 'unitframes.indicators.raidTarget', 'On every frame.'},
	{'switch', 'Dispellable debuffs', 'unitframes.indicators.dispel', 'A ring in the debuff\'s color when you can remove it.'},
	{'switch', 'Target outline', 'unitframes.indicators.targetOutline', 'A lit ring on the party member you target.'},
	{'switch', 'Party pets', 'unitframes.indicators.partyPets', nil, reload = true},
	{'switch', 'Party targets', 'unitframes.indicators.partyTargets', nil, reload = true},
}}
cards[#cards + 1] = CastCard('player', 'Player cast bar')
cards[#cards + 1] = CastCard('target', 'Target cast bar')

UI:RegisterPage('unitframes', {title = 'Unit frames', order = 10, cards = cards})
