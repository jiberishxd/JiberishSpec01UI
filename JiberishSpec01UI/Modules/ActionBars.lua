-- Action bars as one SPEC-01 console: a single device along the bottom of the
-- screen with the keyboard in the middle, the player and target frames docked
-- on either side, both cast bars in slots under the keys and the experience
-- meter along its base. Pet and stance keys sit in small modules on its top
-- edge, side bars in their own device, the menu and bags in another.
--
-- The keys are our own secure action buttons, so nothing of Blizzard's action
-- bar code runs under them: bar 1 pages itself with a state driver (stances,
-- stealth, vehicles, override and possess bars, skyriding), every key is bound
-- through override bindings to the game's own binding commands, and cooldowns,
-- charges and loss of control come from the client's duration objects.
-- Nothing here compares or adds up a value that may be secret.
--
-- 'keys': light keys. 'caps': the charcoal keycaps from the reference's
-- checkboxes. Layout 'console' docks everything into one device; 'free'
-- gives each bar its own device and handle.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown, GetTime = CreateFrame, UIParent, InCombatLockdown, GetTime
local floor, max, min = math.floor, math.max, math.min
local format, ipairs, pairs, pcall, tonumber = format, ipairs, pairs, pcall, tonumber

local module = UI:RegisterModule('actionbars', {})
local function DB() return UI.db.actionbars end
local function IsSecret(value) return issecretvalue and issecretvalue(value) end
local function Forbidden(object) return not object or (object.IsForbidden and object:IsForbidden()) end
local function Fade(region)
	if region and region.SetAlpha and not Forbidden(region) then region:SetAlpha(0) end
end
-- A flag the client may keep secret reads as nil ("unknown") instead of erroring.
local function Flag(value)
	if IsSecret(value) then return nil end
	return value and true or false
end

-- Client functions, from C_ActionBar where it has them.
local C = C_ActionBar or {}
local function API(name) return C[name] or _G[name] end
local HasAction, GetActionTexture, GetActionText, GetActionInfo = API('HasAction'), API('GetActionTexture'), API('GetActionText'), API('GetActionInfo')
local IsUsableAction, IsCurrentAction, IsAutoRepeatAction = API('IsUsableAction'), API('IsCurrentAction'), API('IsAutoRepeatAction')
local IsEquippedAction, IsActionInRange = API('IsEquippedAction'), API('IsActionInRange')
local IsConsumableAction, IsStackableAction = API('IsConsumableAction'), API('IsStackableAction')
local IsOverlayed = (C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed) or _G.IsSpellOverlayed
local MODERN_COOLDOWNS = C.GetActionCooldown and C.GetActionCooldownDuration and true or false
local RANGE_EVENTS = C.EnableActionRangeCheck and true or false
-- The fill motion follows the Appearance page's Smooth bars.
local function Smooth() return Kit.Smooth and Kit:Smooth() or nil end

-- page: the fixed action page (bar 1 pages itself). command: the key binding it answers.
local BARS = {
	{id = 1, page = 1, command = 'ACTIONBUTTON', paging = true},
	{id = 2, page = 6, command = 'MULTIACTIONBAR1BUTTON'}, -- bottom left, slots 61-72
	{id = 3, page = 5, command = 'MULTIACTIONBAR2BUTTON'}, -- bottom right, 49-60
	{id = 4, page = 3, command = 'MULTIACTIONBAR3BUTTON'}, -- right, 25-36
	{id = 5, page = 4, command = 'MULTIACTIONBAR4BUTTON'}, -- left, 37-48
}
local MICRO = {'CharacterMicroButton', 'SpellbookMicroButton', 'PlayerSpellsMicroButton', 'ProfessionMicroButton', 'TalentMicroButton',
	'AchievementMicroButton', 'LegacyMicroButton', 'QuestLogMicroButton', 'GuildMicroButton', 'SocialsMicroButton', 'LFDMicroButton',
	'LFGMicroButton', 'EJMicroButton', 'CollectionsMicroButton', 'MainMenuMicroButton', 'HelpMicroButton', 'StoreMicroButton',
	'HousingMicroButton', 'WorldMapMicroButton', 'PVPMicroButton'}
local BAGS = {'MainMenuBarBackpackButton', 'CharacterBag0Slot', 'CharacterBag1Slot', 'CharacterBag2Slot', 'CharacterBag3Slot',
	'CharacterReagentBag0Slot'}
local RETIRED_BARS = {'MainActionBar', 'MainMenuBar', 'MultiBarBottomLeft', 'MultiBarBottomRight', 'MultiBarLeft', 'MultiBarRight',
	'MultiBar5', 'MultiBar6', 'MultiBar7', 'StanceBar', 'PetActionBar', 'PossessActionBar', 'OverrideActionBar',
	'MicroButtonAndBagsBar'}
local RETIRED_BUTTONS = {'ActionButton', 'MultiBarBottomLeftButton', 'MultiBarBottomRightButton', 'MultiBarLeftButton',
	'MultiBarRightButton', 'MultiBar5Button', 'MultiBar6Button', 'MultiBar7Button', 'StanceButton', 'PossessButton',
	'OverrideActionBarButton'}

-- Measures, in console units.
local PAD, HEAD, GAP, COL_GAP, ROW_GAP, AUX, XP_H = 10, 24, 5, 14, 6, 24, 8
local SPRITES = {keys = {'key', 'key-down'}, caps = {'cap', 'cap-in'}}
local function Sprites() return SPRITES[UI:Style('actionbars')] or SPRITES.keys end
-- Light caps print dark legends; charcoal caps (and Graphite keys) light ones.
local function LightCap()
	return UI:Style('actionbars') ~= 'caps' and Kit:DB().finish ~= 'graphite'
end
local function KeySize() return Kit:Clamp(floor(DB().keySize or 34), 24, 48) end
local function Rows() return Kit:Clamp(floor(DB().rows or 3), 1, 3) end
local function Docking() return DB().layout ~= 'free' end

-- defaults:begin
-- Per bar: bar1..bar5, barPet, barStance. keySize 0 follows the console's key size.
local function BarDefaults(spacing)
	return {enabled = true, keySize = 0, spacing = spacing, shown = 12, perRow = 12, grid = true, fade = false, fadeAlpha = 0.25,
		mouseover = false}
end
UI:RegisterDefaults('actionbars', {
	padding = 0, xpHeight = 8, readout = 'level', sideLayout = 'columns', lock = 'game',
	abbreviate = true, hotkeySize = 0, hotkeyPoint = 'TOPLEFT', countSize = 0, countPoint = 'BOTTOMRIGHT', macroSize = 7,
	cdNumbers = true, cdSize = 0, cdColor = {1, 1, 1}, cdMin = 2,
	rangeColor = {1, 0.38, 0.32}, manaColor = {0.45, 0.58, 1}, unusableColor = {0.5, 0.5, 0.48}, glow = 'pulse',
	-- The look of a key: the legend on a small chip of the cap's color, the count
	-- on an LCD chip, a state LED in the top-right corner, the icon window's inset
	-- (0 = auto) and how faint an empty key's cap is.
	legendChip = true, countChip = true, keyLed = true, iconInset = 0, emptyAlpha = 0.5,
	-- The menu and bag keys: SPEC-01 glyphs or the game's art; bag slots show
	-- the bag's own icon (a glyph only when empty) or always the glyph.
	menuIcons = 'glyphs', bagIcons = 'glyphs',
	-- The console's look: SPEC-01 hardware (keys in slots, printed banks,
	-- page LCD) or the earlier classic look.
	look = 'hardware',
	-- The console's size, apart from its keys: 0 is Auto (sized to its keys and
	-- frames). keyGap 0 keeps each bar's own spacing; banks sit centred, at the
	-- left, or spread across the width.
	consoleWidth = 0, consoleHeight = 0, keyGap = 0, bankAlign = 'center',
	-- The deck along the console's base: the meters' sources and style, the
	-- stats strip (six chosen readouts), the function keys (slots 1-4 left,
	-- 5-8 right) and the header panels.
	barSource = 'auto', barSecond = 'none', barStyle = 'slim', restedOverlay = true, questPreview = false,
	meterColors = 'theme', xpColor = {0.94, 0.25, 0.2}, restedColor = {0.3, 0.55, 1}, repColor = {0.2, 0.75, 0.35},
	honorColor = {0.95, 0.6, 0.15}, previewColor = {1, 0.8, 0.2},
	stats = true, statsStyle = 'text', statsSize = 'compact', stat1 = 'xph', stat2 = 'ttl', stat3 = 'levelTime', stat4 = 'session',
	stat5 = 'rested', stat6 = 'kills',
	fnKeys = true, fnSize = 22, fn1 = 'mount', fn2 = 'hearth', fn3 = 'map', fn4 = 'bags', fn5 = 'drawer', fn6 = 'move',
	fn7 = 'calendar', fn8 = 'menu', fnMacro = '',
	panelZone = false, panelGold = false, panelDurability = false, panelLatency = false,
	-- With no target, the console shows a dim plate where it appears ('plate') or nothing ('collapse').
	targetPlate = 'plate',
	-- Also docked with the player and target: the focus under the player, the
	-- target of target under the target, the pet at the cast row's left end.
	dockFocus = false, dockToT = false, dockPet = false,
	-- The console editor: each block's spot in console units from the console's
	-- top-left ({x, y}, a bank's columns, a cast bar's or the deck's width, off
	-- to take it out), empty for the automatic arrangement; the editor's grid in
	-- screen pixels.
	consoleLayout = {}, consoleGrid = 2,
	-- The menu (micro buttons) and bags: two small devices of their own.
	-- Layout: 'line', 'column', 'grid' (Columns across, a short last line
	-- centred), 'balanced' (the most even grid for the keys shown) or 'console'
	-- (set into the console, along its header or bottom: menuEdge).
	menuEnable = true, menuKeySize = 22, menuScale = 1, menuLayout = 'line', menuColumns = 6, menuSpacing = 3, menuGlyph = 0.68,
	menuHousing = true, menuFade = false, menuHide = {}, menuEdge = 'bottom',
	bagsEnable = true, bagsKeySize = 22, bagsScale = 1, bagsLayout = 'line', bagsColumns = 3, bagsSpacing = 3, bagsGlyph = 0.6,
	bagsHousing = true, bagsFade = false, bagsHide = {},
	bar1 = BarDefaults(5), bar2 = BarDefaults(5), bar3 = BarDefaults(5), bar4 = BarDefaults(5), bar5 = BarDefaults(5),
	barPet = BarDefaults(4), barStance = BarDefaults(4),
})
-- defaults:end

local function BarDB(id) return DB()['bar'..id] or {} end
local function BarEnabled(id) return BarDB(id).enabled ~= false end
local function BarSize(id, fallback)
	local size = tonumber(BarDB(id).keySize)
	if size and size > 0 then return Kit:Clamp(floor(size), 20, 56) end
	return fallback
end
local function Spacing(id)
	local spacing = tonumber(BarDB(id).spacing)
	return spacing and Kit:Clamp(floor(spacing), 0, 20) or GAP
end
local function Shown(id) return Kit:Clamp(floor(tonumber(BarDB(id).shown) or 12), 1, 12) end
local function PerRow(id) return Kit:Clamp(floor(tonumber(BarDB(id).perRow) or 12), 1, 12) end
local function XPHeight() return Kit:Clamp(floor(tonumber(DB().xpHeight) or XP_H), 4, 16) end
local function HPad() return PAD + Kit:Clamp(floor(tonumber(DB().padding) or 0), 0, 60) end

-- A color setting: {r, g, b} or {r = , g = , b = }.
local function ColorOf(value, r, g, b)
	if type(value) == 'table' then
		local cr = value[1] or value.r
		if type(cr) == 'number' then return cr, value[2] or value.g or 1, value[3] or value.b or 1 end
	end
	return r, g, b
end

local function Surface()
	local style = UI:ModuleEnabled('unitframes') and UI:Style('unitframes')
	return style == 'dark' and 'dark' or 'paper'
end

local function Sound(down)
	local db = UI.db.sound
	if db.enable and db.actionbars then Kit:Play(down and 'down' or 'up', true) end
end

-- The Hardware console look --------------------------------------------------------------
-- The default look builds the console the way SPEC-01 builds its devices
-- (devices.css, hardware.css, hardware-field.css in the reference):
--   * keys sit in holes in the housing: a 2 px dark slot round each cap, with a
--     lit line under it on light housings;
--   * the icon sits in a window in the cap, below a printed band that carries
--     the key's legend in small caps and its state lamp;
--   * the lamp reads the key's state: lit while active, green when equipped,
--     red out of range, blue short of power, dark when unusable;
--   * banks of keys carry a printed legend with a hairline rule after it;
--   * modules have a model plate in the header;
--   * the console carries a page LCD (with unlit ghost digits) and page lamps,
--     and the meter along its base has a printed legend and an LCD percent.
-- 'Classic' keeps the earlier look. Everything here is in one table, so the
-- file's main chunk stays well under Lua's limit of 200 locals.
local HW = {}
function HW.On() return DB().look ~= 'classic' end
-- The console's deck (stats strip, meters, function keys, header panels): one
-- table, filled in near the end of the file.
local Deck = {}

-- The slot color (--slot in the reference) and the lit line under it.
HW.SLOT = {0.149, 0.149, 0.141}

-- Insets of the icon window from the cap's edges: left, top, right, bottom.
-- Hardware leaves a printed band across the top for the legend and the lamp;
-- Classic insets all four sides by `even` (the cap's face inset).
function HW.Window(size, even)
	if not HW.On() then return even, even, even, even end
	local inset = tonumber(DB().iconInset)
	-- Small keys (pet, stance, side bars) keep a thinner rim and band, so the
	-- icon window does not shrink to nothing.
	local small = size < 32
	local side = (inset and inset > 0) and Kit:Clamp(floor(inset), 2, floor(size / 3))
		or (small and max(3, floor(size * 0.13 + 0.5)) or max(4, floor(size * 0.15 + 0.5)))
	local band = small and max(7, floor(size * 0.27 + 0.5)) or max(8, floor(size * 0.27 + 0.5))
	return side, band, side, max(3, floor(size * 0.12 + 0.5))
end

-- The icon's texture coordinates, cropped so a window that is not square
-- shows the middle of the icon without squashing it.
function HW.Crop(icon, width, height)
	local low, high = 0.07, 0.93
	if not (width and height) or width <= 0 or height <= 0 then return icon:SetTexCoord(low, high, low, high) end
	local span = high - low
	if width > height then
		local cut = span * (1 - height / width) / 2
		icon:SetTexCoord(low, high, low + cut, high - cut)
	else
		local cut = span * (1 - width / height) / 2
		icon:SetTexCoord(low + cut, high - cut, low, high)
	end
end

-- The slot round a key: a dark ring 2 px outside the cap, the cap's own shadow
-- inside it. Drawn on `owner` (the key's back frame), around `around`; round
-- for a round key.
function HW.Slot(owner, around, round)
	local file = round and 'circle' or 'round-6'
	local slot = Kit:Texture(owner, file, 'BACKGROUND', -7)
	slot:SetVertexColor(HW.SLOT[1], HW.SLOT[2], HW.SLOT[3], 1)
	Kit:Place(slot, around, 2, 2, 2, 3)
	local shine = Kit:Texture(owner, file, 'BACKGROUND', -8)
	shine:SetVertexColor(1, 1, 1, 0.7)
	Kit:Place(shine, around, 2, 2, 2, 4)
	slot.shine = shine
	return slot
end

function HW.ShowSlot(slot, shown)
	if not slot then return end
	slot:SetShown(shown)
	-- The lit line under the slot only reads on a light housing.
	slot.shine:SetShown(shown and Surface() ~= 'dark')
end

-- The key's lamp from its state. Hardware shows the lamp always (unlit when
-- there is nothing to say); Classic only while active or equipped.
function HW.Lamp(key)
	local lamp = key.lamp
	if not lamp then return end
	local show = DB().keyLed ~= false
	if not HW.On() then
		if key.on then Kit:SetLed(lamp, true)
		elseif key.equipped then Kit:SetLed(lamp, true, 'green')
		else Kit:SetLed(lamp, false) end
		Kit:ShowLed(lamp, (key.on or key.equipped) and show and true or false)
		return
	end
	if not key.has then
		Kit:SetLed(lamp, false)
	elseif key.on then Kit:SetLed(lamp, true)
	elseif key.outOfRange then Kit:SetLed(lamp, true, 'red')
	elseif key.usable == false and key.noMana then Kit:SetLed(lamp, true, 'blue')
	elseif key.equipped then Kit:SetLed(lamp, true, 'green')
	else Kit:SetLed(lamp, false) end
	Kit:ShowLed(lamp, show and key.has and true or false)
end

-- A printed legend with a hairline rule running from it to `width`, as the
-- reference prints the name over a group of controls.
function HW.Bank(parent, text)
	local bank = {}
	local dark = Surface() == 'dark'
	bank.label = Kit:Label(parent, text, dark and 'darkDim' or 'dim', 7, true)
	bank.rule = parent:CreateTexture(nil, 'ARTWORK')
	bank.rule:SetColorTexture(dark and 1 or 0, dark and 1 or 0, dark and 1 or 0, dark and 0.08 or 0.09)
	bank.shine = parent:CreateTexture(nil, 'ARTWORK')
	bank.shine:SetColorTexture(dark and 0 or 1, dark and 0 or 1, dark and 0 or 1, dark and 0.35 or 0.9)
	return bank
end

-- Place a bank legend with its top-left at x, y in `parent`, its rule running `width` across.
function HW.PlaceBank(bank, parent, x, y, width, shown)
	for _, part in pairs(bank) do part:SetShown(shown and true or false) end
	if not shown then return end
	local px = UI.Pixel and UI.Pixel.Px(parent, 1) or 1
	bank.label:ClearAllPoints()
	bank.label:SetPoint('TOPLEFT', parent, 'TOPLEFT', x, y)
	local ruleWidth = max(width - bank.label:GetStringWidth() - 6, 0)
	bank.rule:ClearAllPoints()
	bank.rule:SetSize(ruleWidth, px)
	bank.rule:SetPoint('LEFT', bank.label, 'RIGHT', 6, 0)
	bank.shine:ClearAllPoints()
	bank.shine:SetSize(ruleWidth, px)
	bank.shine:SetPoint('TOPLEFT', bank.rule, 'BOTTOMLEFT', 0, 0)
end
HW.BANK_H = 11 -- room a bank legend takes above its keys

-- Legends on small keys ----------------------------------------------------------------
HW.LEGEND_MIN = 6 -- the smallest legend size that still reads
-- The legend's size for a band: about two thirds of its height.
function HW.LegendSize(band) return max(HW.LEGEND_MIN, floor(band * 0.68)) end

-- A bound key printed shorter still: the modifier's letter and the key's
-- number ("CF1" -> "C1"), else its first two letters.
function HW.Shorter(text)
	local digits = text:match('(%d+)$')
	if digits and #text > #digits + 1 then return text:sub(1, 1)..digits end
	return text:sub(1, 2)
end

-- Print `text` into `label`, kept inside `width`: the size steps down to the
-- minimum, then the shorter legend is tried, then the line is cut at the
-- box's edge (it never wraps or spills onto the next key). Too narrow a box
-- prints nothing.
function HW.FitLegend(label, text, width, size)
	text = text or ''
	label:SetWidth(max(width, 1))
	label:SetWordWrap(false)
	if label.SetMaxLines then label:SetMaxLines(1) end
	if width < HW.LEGEND_MIN then label:SetText('') return end
	local function Measure(value, fontSize)
		Kit:Font(label, fontSize, '', true)
		label:SetText(value)
		return label.GetUnboundedStringWidth and label:GetUnboundedStringWidth() or label:GetStringWidth()
	end
	if text == '' then Measure('', size) return end
	for fontSize = size, HW.LEGEND_MIN, -1 do
		if Measure(text, fontSize) <= width then return end
	end
	local short = HW.Shorter(text)
	if short ~= text and Measure(short, HW.LEGEND_MIN) <= width then return end
	-- Still too wide: the shorter legend, cut at the box's edge.
	Measure(short, HW.LEGEND_MIN)
end

-- A small device's printed name, top left, with its rule (pet and stance strips).
function HW.MiniLegend(device, text)
	if not HW.On() then return end
	device.bank = HW.Bank(device, text)
	local function Place() HW.PlaceBank(device.bank, device, PAD - 2, -5, device:GetWidth() - 2 * PAD + 4, true) end
	device:HookScript('OnSizeChanged', function() UI:Safe(Place) end)
	Place()
end

-- A larger model plate in the header. (Modules carry no corner screws: the
-- user asked for none anywhere.)
function HW.Decorate(device, radius)
	if not HW.On() then return end
	local inset = max(6, floor((radius or 12) * 0.5 + 0.5))
	HW.ShowDecor(device, DB().housing ~= false)
	-- The plate: the lamp sits in from the corner and the model prints larger.
	if device.lamp and device.model then
		device.lamp:ClearAllPoints()
		device.lamp:SetPoint('TOPLEFT', inset + 9, -9)
		Kit:Font(device.model, 11, nil, false)
	end
end

function HW.ShowDecor(device, shown) -- luacheck: ignore shown
	-- Screws from earlier builds stay hidden.
	for _, screw in ipairs(device and device.screws or {}) do
		screw:Hide()
		if screw.slot then screw.slot:Hide() end
	end
end

-- The page LCD (two digits over unlit '88') and six page lamps, in the
-- console's header. Paging stays with the secure state driver; this only shows it.
function HW.BuildPager(console)
	local pager = CreateFrame('Frame', nil, console)
	pager:SetSize(90, 14)
	pager.lcd = Kit:LCDPanel(pager, {radius = 3})
	pager.lcd:SetSize(26, 14)
	pager.lcd:SetPoint('RIGHT')
	pager.ghost = Kit:Text(pager.lcd, '88', 'tiny', 'lcdGhost', true)
	pager.ghost:SetPoint('RIGHT', -5, 0)
	pager.digits = Kit:Text(pager.lcd, '01', 'tiny', 'lcdInk', true)
	pager.digits:SetPoint('RIGHT', -5, 0)
	pager.lamps = {}
	for index = 6, 1, -1 do
		local lamp = Kit:Led(pager, 4, false)
		lamp:SetPoint('RIGHT', pager.lcd, 'LEFT', -6 - (6 - index) * 7, 0)
		pager.lamps[index] = lamp
	end
	local dark = Surface() == 'dark'
	pager.label = Kit:Label(pager, 'Page', dark and 'darkDim' or 'dim', 7, true)
	pager.label:SetPoint('RIGHT', pager.lamps[1], 'LEFT', -5, 0)
	pager:SetWidth(26 + 6 + 6 * 7 + 5 + pager.label:GetStringWidth())
	return pager
end

-- Show a page: 1-6 light their lamp; bonus, vehicle and override pages show
-- their number on the LCD alone.
function HW.ShowPage(pager, page)
	if not pager then return end
	page = tonumber(page) or 1
	pager.digits:SetText(format('%02d', page))
	for index, lamp in ipairs(pager.lamps) do
		Kit:SetLed(lamp, index == page, page > 6 and 'amber' or nil)
	end
	if page > 6 then Kit:SetLed(pager.lamps[1], true, 'amber') end
end

-- The meter's legend and LCD percent, beside the dots.
function HW.MeterParts(parent, track)
	local dark = Surface() == 'dark'
	track.legend = Kit:Label(parent, 'XP', dark and 'darkDim' or 'dim', 7, true)
	track.lcd = Kit:LCDPanel(parent, {radius = 3})
	track.lcd:SetSize(40, 12)
	track.percent = Kit:Text(track.lcd, '', 'tiny', 'lcdInk', true)
	track.percent:SetPoint('RIGHT', -4, 0)
end

-- Place the meter along a device's base: from `left` to `right` (insets), the
-- legend and LCD outside the dots in the Hardware look.
function HW.PlaceMeter(track, parent, left, right, bottom, height)
	local hardware = HW.On() and track.legend ~= nil
	local legendWidth = hardware and 24 or 0
	local lcdWidth = hardware and 46 or 0
	track:ClearAllPoints()
	track:SetPoint('BOTTOMLEFT', parent, 'BOTTOMLEFT', left + legendWidth, bottom)
	track:SetPoint('BOTTOMRIGHT', parent, 'BOTTOMRIGHT', -right - lcdWidth, bottom)
	track:SetHeight(height)
	if track.legend then
		local shown = hardware and track:IsShown()
		track.legend:SetShown(shown)
		track.lcd:SetShown(shown)
		track.legend:ClearAllPoints()
		track.legend:SetPoint('LEFT', parent, 'BOTTOMLEFT', left, bottom + height / 2)
		track.lcd:ClearAllPoints()
		track.lcd:SetPoint('RIGHT', parent, 'BOTTOMRIGHT', -right, bottom + height / 2)
	end
end

function HW.MeterText(track, legend, percent)
	if not track.legend then return end
	track.legend:SetText(legend:upper())
	track.percent:SetText(percent or '')
end

-- Key legends -----------------------------------------------------------------------
-- A bound key printed short, the way a keyboard's legends are.
local Legend
do
local SHORT = {{'ALT%-', 'A'}, {'CTRL%-', 'C'}, {'SHIFT%-', 'S'}, {'META%-', 'M'}, {'MOUSEWHEELUP', 'WU'}, {'MOUSEWHEELDOWN', 'WD'},
	{'MIDDLEMOUSE', 'M3'}, {'BUTTON', 'M'}, {'NUMPADPLUS', 'N+'}, {'NUMPADMINUS', 'N-'}, {'NUMPADMULTIPLY', 'N*'},
	{'NUMPADDIVIDE', 'N/'}, {'NUMPADDECIMAL', 'N.'}, {'NUMPAD', 'N'}, {'PAGEUP', 'PU'}, {'PAGEDOWN', 'PD'}, {'SPACE', 'SP'},
	{'INSERT', 'IN'}, {'DELETE', 'DE'}, {'HOME', 'HO'}, {'CAPSLOCK', 'CL'}, {'BACKSPACE', 'BS'}, {'ENTER', 'EN'}, {'TAB', 'TB'}}
function Legend(binding)
	if not binding or binding == '' then return '' end
	if DB().abbreviate == false then return binding end
	for _, pair in ipairs(SHORT) do binding = binding:gsub(pair[1], pair[2]) end
	return binding
end
end

-- Our action keys ---------------------------------------------------------------------
local keys, keyOf, bySlot = {}, {}, {}

local function Press(key, down)
	if key.down == down then return end
	key.down = down
	if down and Kit.MotionNotify then Kit:MotionNotify('press', key) end
	Kit:SetSprite(key.skin, Sprites()[down and 2 or 1])
	-- The legend travels with the cap.
	local travel = down and max(1, floor(key.size / 22)) or 0
	key.face:ClearAllPoints()
	key.face:SetPoint('TOPLEFT', 0, -travel)
	key.face:SetPoint('BOTTOMRIGHT', 0, -travel)
	Sound(down)
end

local function Tint(key)
	local icon = key.icon
	local db = DB()
	if key.outOfRange then icon:SetVertexColor(ColorOf(db.rangeColor, 1, 0.38, 0.32)); icon:SetDesaturated(false)
	elseif key.usable == false and key.noMana then icon:SetVertexColor(ColorOf(db.manaColor, 0.45, 0.58, 1)); icon:SetDesaturated(false)
	elseif key.usable == false then icon:SetVertexColor(ColorOf(db.unusableColor, 0.5, 0.5, 0.48)); icon:SetDesaturated(true)
	else icon:SetVertexColor(1, 1, 1); icon:SetDesaturated(false) end
	HW.Lamp(key)
end

local function UpdateUsable(key, usable, noMana)
	if usable == nil and key.slot then usable, noMana = IsUsableAction(key.slot) end
	-- A secret answer counts as usable: the key is never wrongly dimmed.
	key.usable, key.noMana = Flag(usable), Flag(noMana)
	if key.usable == nil then key.usable = true end
	Tint(key)
end

local function UpdateRange(key, inRange, checksRange)
	if inRange == nil and checksRange == nil then
		local answer = key.slot and IsActionInRange(key.slot)
		key.outOfRange = not IsSecret(answer) and answer == false
	else
		key.outOfRange = Flag(checksRange) == true and Flag(inRange) == false
	end
	Tint(key)
end

local function UpdateState(key)
	local slot = key.slot
	key.on = slot and key.has and (Flag(IsCurrentAction(slot)) or Flag(IsAutoRepeatAction(slot))) or false
	key.equipped = slot and key.has and Flag(IsEquippedAction(slot)) or false
	HW.Lamp(key)
end

-- A proc: 'pulse' is a lit ring and a slow pulse of the key color, 'ring' the
-- ring alone, 'off' nothing.
local function SetGlow(key, on)
	local style = DB().glow or 'pulse'
	if on == key.glowing and style == key.glowStyle then return end
	key.glowing, key.glowStyle = on, style
	key.pulse:Stop(); key.glow:Hide(); key.ring:Hide()
	if on and style ~= 'off' then
		key.ring:Show()
		if style == 'pulse' then key.glow:Show(); key.pulse:Play() end
	end
end

local function UpdateGlow(key)
	SetGlow(key, key.spell and IsOverlayed and Flag(IsOverlayed(key.spell)) or false)
end

-- Cooldowns run on the client's duration objects; nothing is timed here.
-- The motion layer hears about each change ('cooldown ready' flashes).
local function Notify(kind, cooldown)
	local key = cooldown.kitKey
	if key and Kit.MotionNotify then Kit:MotionNotify(kind, key) end
end

local function ShowCooldown(cooldown, active, duration)
	if IsSecret(active) or active then
		if duration then
			cooldown:SetCooldownFromDurationObject(duration)
			Notify('cooldown-start', cooldown)
		else cooldown:Clear() end
	else
		cooldown:Clear()
		Notify('cooldown-clear', cooldown)
	end
end

local function UpdateCooldown(key)
	local slot = key.slot
	if not slot or not key.has then
		key.cooldown:Clear(); key.charge:Clear(); key.loc:Clear()
		return
	end
	if MODERN_COOLDOWNS then
		local info = C.GetActionCooldown(slot)
		local charges = C.GetActionCharges and C.GetActionCharges(slot)
		local loc = C.GetActionLossOfControlCooldownInfo and C.GetActionLossOfControlCooldownInfo(slot)
		local locActive = loc and loc.isActive
		local replace = loc and Flag(loc.shouldReplaceNormalCooldown)
		ShowCooldown(key.loc, locActive, (IsSecret(locActive) or locActive) and C.GetActionLossOfControlCooldownDuration
			and C.GetActionLossOfControlCooldownDuration(slot))
		if replace then
			key.cooldown:Clear(); key.charge:Clear()
			return
		end
		local active = info and info.isActive
		ShowCooldown(key.cooldown, active, (IsSecret(active) or active) and C.GetActionCooldownDuration(slot))
		local chargeActive = charges and charges.isActive
		ShowCooldown(key.charge, chargeActive, (IsSecret(chargeActive) or chargeActive) and C.GetActionChargeDuration
			and C.GetActionChargeDuration(slot))
		return
	end
	-- Clients without duration objects have no secret cooldowns either.
	local start, duration, enable = GetActionCooldown(slot)
	if IsSecret(start) or IsSecret(duration) then return end
	if start and duration and duration > 0 and enable ~= 0 and enable ~= false then key.cooldown:SetCooldown(start, duration)
	else key.cooldown:Clear() end
end

local function Count(slot)
	if C.GetActionDisplayCount then return C.GetActionDisplayCount(slot) end
	if not (IsConsumableAction(slot) or IsStackableAction(slot)) then return '' end
	local count = GetActionCount(slot)
	if IsSecret(count) then return count end
	return (count and count > 0) and count or ''
end

local function SpellOf(slot)
	local actionType, id, subType = GetActionInfo(slot)
	if IsSecret(actionType) or IsSecret(id) then return nil end
	if actionType == 'spell' then return id end
	if actionType == 'macro' and not IsSecret(subType) and subType == 'spell' then return id end
	return nil
end

-- Spells held down to charge (empowered casts) cast on release. Only out of combat;
-- bar 1 sets this in its paging snippet too.
local function UpdateRelease(key)
	if not (C_Spell and C_Spell.IsPressHoldReleaseSpell) or InCombatLockdown() then return end
	local button = key.button
	local hold = key.spell and C_Spell.IsPressHoldReleaseSpell(key.spell)
	if Flag(hold) then
		button:SetAttribute('pressAndHoldAction', true)
		button:SetAttribute('typerelease', 'actionrelease')
	elseif button:GetAttribute('typerelease') then
		button:SetAttribute('typerelease', nil)
	end
end

local function UpdateLegend(key)
	local db = DB()
	local text = db.hotkeys and key.binding or ''
	local light = LightCap()
	if HW.On() then
		-- Printed on the cap's band, above the icon window: ink on the cap, fitted to the band.
		if key.legendWidth then HW.FitLegend(key.hotkey, text, key.legendWidth, key.legendSize)
		else key.hotkey:SetText(text) end
		key.hotkeyChip:Hide()
		Kit:Tint(key.hotkey, light and (key.has and 'ink' or 'dim') or (key.has and 'darkInk' or 'darkDim'))
		key.hotkey:SetShadowOffset(0, 0)
		return
	end
	key.hotkey:SetText(text)
	local chip = key.has and db.legendChip ~= false and text ~= ''
	key.hotkeyChip:SetShown(chip)
	if chip then
		-- A tiny label of the cap's own color, as the reference prints its legends.
		Kit:Tint(key.hotkeyChip, light and 'key' or 'dark', 0.92)
		Kit:Tint(key.hotkey, light and 'ink' or 'darkInk')
		key.hotkey:SetShadowOffset(0, 0)
	elseif key.has then
		Kit:Tint(key.hotkey, 'white')
		key.hotkey:SetShadowOffset(1, -1)
	else
		-- On an empty cap the legend is printed straight on it.
		Kit:Tint(key.hotkey, light and 'dim' or 'darkDim')
		key.hotkey:SetShadowOffset(0, 0)
	end
end

-- The count on a small gray LCD chip. A secret count is printed and the chip
-- shown, never tested; a plain one hides the chip when there is nothing.
local function UpdateCount(key, count)
	-- A secret count is handed straight on and never tested.
	local secret = IsSecret(count)
	if secret then key.count:SetText(count) else key.count:SetText(count or '') end
	local chip = DB().countChip ~= false
	local shown = secret or (count ~= nil and count ~= '')
	key.countChip:SetShown(chip and shown and true or false)
	if chip then
		Kit:Tint(key.count, 'lcdInk')
		key.count:SetShadowOffset(0, 0)
	else
		Kit:Tint(key.count, 'white')
		key.count:SetShadowOffset(1, -1)
	end
end

-- While something is on the cursor every key shows, so it can be dropped.
local dragging = false
local function UpdateGrid(key)
	local show = key.has or dragging or BarDB(key.bar.id).grid ~= false
	key.button:SetAlpha(show and 1 or 0)
end

local function UpdateKey(key)
	local slot = key.slot
	local has = slot and HasAction(slot)
	key.has = Flag(has) ~= false and slot ~= nil
	if key.has then
		key.icon:SetTexture(GetActionTexture(slot))
		key.icon:Show()
		key.spell = SpellOf(slot)
		UpdateCount(key, Count(slot))
		if DB().macros then key.macro:SetText(GetActionText(slot)) else key.macro:SetText('') end
	else
		key.icon:Hide()
		key.spell = nil
		UpdateCount(key, '')
		key.macro:SetText('')
	end
	-- An empty key is a blank keycap: fainter, no icon window, its legend only.
	-- Hardware: a blank cap in its slot, as solid as any other.
	local empty = HW.On() and 1 or Kit:Clamp(tonumber(DB().emptyAlpha) or 0.5, 0.15, 1)
	key.skin:SetAlpha(key.has and 1 or empty)
	key.window:SetShown(key.has and true or false)
	UpdateLegend(key)
	UpdateGrid(key)
	UpdateCooldown(key)
	UpdateUsable(key)
	UpdateRange(key)
	UpdateState(key)
	UpdateGlow(key)
	UpdateRelease(key)
end

-- Range checks are switched on per slot, so the client only reports slots in view.
local watched = {}
local function WatchSlot(key, slot)
	if key.slot == slot then return end
	local old = key.slot
	if old then
		if bySlot[old] then bySlot[old][key] = nil end
		if RANGE_EVENTS then
			watched[old] = (watched[old] or 1) - 1
			if watched[old] <= 0 then watched[old] = nil; C.EnableActionRangeCheck(old, false) end
		end
	end
	key.slot = slot
	if slot then
		bySlot[slot] = bySlot[slot] or {}
		bySlot[slot][key] = true
		if RANGE_EVENTS then
			watched[slot] = (watched[slot] or 0) + 1
			if watched[slot] == 1 then C.EnableActionRangeCheck(slot, true) end
		end
	end
end

local function ForKeys(func) for _, key in ipairs(keys) do UI:Safe(func, key) end end

-- Bar 1's page, as Blizzard picks it: vehicle, override and possess bars first,
-- then a temporary shapeshift bar, the bar pages, then a bonus bar (stances,
-- stealth, forms, skyriding), else page 1.
local function PageConditions()
	local function Index(name)
		local func = API(name)
		if not func then return nil end
		local ok, index = pcall(func)
		return ok and type(index) == 'number' and index or nil
	end
	local parts = {}
	local override, vehicle, temp = Index('GetOverrideBarIndex'), Index('GetVehicleBarIndex'), Index('GetTempShapeshiftBarIndex')
	if override then parts[#parts + 1] = format('[overridebar] %d;', override) end
	if vehicle then parts[#parts + 1] = format('[vehicleui][possessbar] %d;', vehicle) end
	if temp then parts[#parts + 1] = format('[shapeshift] %d;', temp) end
	parts[#parts + 1] = '[bar:2] 2; [bar:3] 3; [bar:4] 4; [bar:5] 5; [bar:6] 6; '..
		-- One token per bonus bar: the driver only re-pages when the token changes.
		'[bonusbar:1,stealth] bonus1s; [bonusbar:1] bonus1; [bonusbar:2] bonus2; [bonusbar:3] bonus3; [bonusbar:4] bonus4; [bonusbar:5] bonus5; 1'
	return table.concat(parts, ' ')
end

local RELEASE_SNIPPET = [[
	local actionType, id, subType = GetActionInfo(self:GetAttribute('action'))
	local spell = (actionType == 'spell' or (actionType == 'macro' and subType == 'spell')) and id
	if spell and IsPressHoldReleaseSpell and IsPressHoldReleaseSpell(spell) then
		self:SetAttribute('pressAndHoldAction', true)
		self:SetAttribute('typerelease', 'actionrelease')
	elseif self:GetAttribute('typerelease') then
		self:SetAttribute('typerelease', nil)
	end
]]

local function FaceInset(size)
	local inset = tonumber(DB().iconInset)
	if inset and inset > 0 then return Kit:Clamp(floor(inset), 2, floor(size / 3)) end
	return max(4, floor(size * 0.16 + 0.5))
end


-- Where a legend sits on the key, as an offset direction from that corner.
local Corner
do
local CORNERS = {TOPLEFT = {1, -1}, TOP = {0, -1}, TOPRIGHT = {-1, -1}, BOTTOMLEFT = {1, 1}, BOTTOM = {0, 1}, BOTTOMRIGHT = {-1, 1}}
function Corner(text, point, inset)
	local sign = CORNERS[point] or CORNERS.TOPLEFT
	text:ClearAllPoints()
	text:SetPoint(CORNERS[point] and point or 'TOPLEFT', sign[1] * (inset + 1), sign[2] * (inset + 1))
end
end

local function Sized(value, auto)
	value = tonumber(value)
	return (value and value > 0) and floor(value) or auto
end

-- Everything on a key that follows the settings: legends, countdown numbers.
local function ApplyLook(key)
	local db, size = DB(), key.size
	local inset = FaceInset(size)
	if HW.On() then
		-- The legend is printed in the cap's band; the lamp sits at its other end.
		local side, band = HW.Window(size, inset)
		local point = db.hotkeyPoint or 'TOPLEFT'
		local align = point:find('RIGHT') and 'RIGHT' or ((point == 'TOP' or point == 'BOTTOM') and 'CENTER' or 'LEFT')
		-- The legend's box: the band between the cap's sides, less the lamp's room.
		key.legendSize = Sized(db.hotkeySize, HW.LegendSize(band))
		key.legendWidth = size - 2 * side - (align == 'CENTER' and 12 or 7)
		key.hotkey:SetJustifyH(align)
		key.hotkey:ClearAllPoints()
		local y = -band / 2
		if align == 'RIGHT' then key.hotkey:SetPoint('RIGHT', key.face, 'TOPRIGHT', -side, y)
		elseif align == 'CENTER' then key.hotkey:SetPoint('CENTER', key.face, 'TOP', 0, y)
		else key.hotkey:SetPoint('LEFT', key.face, 'TOPLEFT', side, y) end
		key.lamp:ClearAllPoints()
		if align == 'RIGHT' then key.lamp:SetPoint('CENTER', key.face, 'TOPLEFT', side + 2, y)
		else key.lamp:SetPoint('CENTER', key.face, 'TOPRIGHT', -side - 2, y) end
		-- Counts on their LCD chip over the window's corner; macro names along its foot.
		Kit:Font(key.count, Sized(db.countSize, max(7, floor(size * 0.22))), '', true)
		local countPoint = db.countPoint or 'BOTTOMRIGHT'
		key.count:ClearAllPoints()
		key.count:SetPoint(countPoint, key.icon, countPoint, countPoint:find('LEFT') and 2 or (countPoint:find('RIGHT') and -2 or 0), 2)
		Kit:Font(key.macro, Sized(db.macroSize, 7), '', false)
		key.macro:ClearAllPoints()
		key.macro:SetPoint('BOTTOMLEFT', key.icon, 'BOTTOMLEFT', 1, 1)
		key.macro:SetPoint('BOTTOMRIGHT', key.icon, 'BOTTOMRIGHT', -1, 1)
		UpdateLegend(key)
	else
		Kit:Font(key.hotkey, Sized(db.hotkeySize, max(7, floor(size * 0.22))), '', true)
		Corner(key.hotkey, db.hotkeyPoint, inset + 1)
		Kit:Font(key.count, Sized(db.countSize, max(7, floor(size * 0.24))), '', true)
		Corner(key.count, db.countPoint or 'BOTTOMRIGHT', inset + 1)
		Kit:Font(key.macro, Sized(db.macroSize, 7), '', false)
		key.macro:ClearAllPoints()
		key.macro:SetPoint('BOTTOMLEFT', inset, inset)
		key.macro:SetPoint('BOTTOMRIGHT', -inset, inset)
	end
	local cooldown = key.cooldown
	if cooldown.SetHideCountdownNumbers then cooldown:SetHideCountdownNumbers(db.cdNumbers == false) end
	-- Short cooldowns (the global cooldown) show no numbers.
	if cooldown.SetMinimumCountdownDuration then
		cooldown:SetMinimumCountdownDuration(floor((tonumber(db.cdMin) or 0) * 1000))
	end
	if key.numbers then
		Kit:Font(key.numbers, Sized(db.cdSize, max(9, floor(size * 0.36))), 'OUTLINE', true)
		key.numbers:SetTextColor(ColorOf(db.cdColor, 1, 1, 1))
	end
end

-- A key at a new size: its cap, icon window, glow and lamp. Out of combat only.
local function SizeKey(key, size)
	key.size = size
	key.button:SetSize(size, size)
	key.skin.kitMaxCorner = max(6, floor(size * 0.27))
	Kit:FitSprite(key.skin, size, size)
	local inset = FaceInset(size)
	local left, top, right, bottom = HW.Window(size, inset)
	key.icon:ClearAllPoints()
	key.icon:SetPoint('TOPLEFT', left, -top)
	key.icon:SetPoint('BOTTOMRIGHT', -right, bottom)
	HW.Crop(key.icon, size - left - right, size - top - bottom)
	key.glow:ClearAllPoints()
	key.glow:SetPoint('TOPLEFT', -size * 0.28, size * 0.28)
	key.glow:SetPoint('BOTTOMRIGHT', size * 0.28, -size * 0.28)
	Kit:Place(key.window, key.icon, 0, 0, 0, 0)
	key.lamp:ClearAllPoints()
	key.lamp:SetPoint('TOPRIGHT', -max(2, floor(inset / 2)), -max(2, floor(inset / 2)))
	HW.ShowSlot(key.slotRing, HW.On())
	ApplyLook(key)
end

local function CreateKey(bar, index, header, size)
	local name = format('JiberishSpec01Bar%dKey%d', bar.id, index)
	local button = CreateFrame('CheckButton', name, header, 'SecureActionButtonTemplate')
	button:SetSize(size, size)
	-- The ID stays 0: with an ID, Blizzard's secure click code works out the
	-- slot from the bar page and ignores the 'action' attribute.
	button:SetAttribute('index', index)
	button:RegisterForClicks('AnyDown', 'AnyUp')
	button:RegisterForDrag('LeftButton', 'RightButton')
	button:SetAttribute('type', 'action')
	button:SetAttribute('action', (bar.page - 1) * 12 + index)
	button:SetAttribute('flyoutDirection', 'UP')
	button:SetAttribute('checkselfcast', true)
	button:SetAttribute('checkfocuscast', true)
	button:SetAttribute('checkmouseovercast', true)
	if bar.paging then
		button:SetAttribute('_childupdate-page', [[
			local page = tonumber(message) or 1
			self:SetAttribute('action', (page - 1) * 12 + self:GetAttribute('index'))
		]]..(C_Spell and C_Spell.IsPressHoldReleaseSpell and RELEASE_SNIPPET or ''))
	end
	-- Drag a spell off (only with the pickup modifier while bars are locked)
	-- or onto a key, in combat too.
	header:WrapScript(button, 'OnDragStart', [[
		if self:GetAttribute('buttonlock') and not IsModifiedClick('PICKUPACTION') then return false end
		return 'action', self:GetAttribute('action')
	]])
	header:WrapScript(button, 'OnReceiveDrag', [[
		return 'action', self:GetAttribute('action')
	]])

	-- The keycap, the legend that travels with it, and lamps above everything.
	local key = CreateFrame('Frame', nil, button)
	key:SetAllPoints()
	key:EnableMouse(false)
	key.button, key.size, key.bar, key.index = button, size, bar, index
	key.command = bar.command..index
	key.skin = Kit:Skin(key, Sprites()[1], 'BACKGROUND', 0)
	key.skin.kitMaxCorner = max(6, floor(size * 0.27))
	Kit:FitSprite(key.skin, size, size)
	-- The hole in the housing the cap sits in (Hardware look).
	key.slotRing = HW.Slot(key, key)
	local face = CreateFrame('Frame', nil, key)
	face:SetPoint('TOPLEFT')
	face:SetPoint('BOTTOMRIGHT')
	key.face = face
	local inset = FaceInset(size)
	key.icon = face:CreateTexture(nil, 'ARTWORK')
	key.icon:SetPoint('TOPLEFT', inset, -inset)
	key.icon:SetPoint('BOTTOMRIGHT', -inset, inset)
	key.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	local mask = face:CreateMaskTexture()
	mask:SetTexture(Kit.media..'mask-icon.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
	mask:SetAllPoints(key.icon)
	key.icon:AddMaskTexture(mask)
	-- The icon sits in a window cut into the cap: a soft inner shadow at its edge.
	key.window = Kit:Texture(face, 'inset-6', 'ARTWORK', 2)
	Kit:Place(key.window, key.icon, 0, 0, 0, 0)
	key.window:SetVertexColor(0, 0, 0, 0.6)
	key.hover = face:CreateTexture(nil, 'OVERLAY', nil, 1)
	key.hover:SetAllPoints(key.icon)
	key.hover:SetColorTexture(1, 1, 1, 0.14)
	key.hover:AddMaskTexture(mask)
	key.hover:Hide()

	local function Cooldown(swipe, drawSwipe)
		local cooldown = CreateFrame('Cooldown', nil, face, 'CooldownFrameTemplate')
		cooldown:SetAllPoints(key.icon)
		cooldown:SetDrawEdge(not drawSwipe)
		cooldown:SetDrawSwipe(drawSwipe)
		cooldown:SetDrawBling(false)
		if drawSwipe and cooldown.SetSwipeTexture then cooldown:SetSwipeTexture(Kit.media..'mask-icon.tga', swipe[1], swipe[2], swipe[3], swipe[4]) end
		return cooldown
	end
	key.cooldown = Cooldown({0, 0, 0, 0.72}, true)
	if HW.On() then
		-- The reference's sweep: a lighter shade with a lit edge riding it.
		key.cooldown:SetSwipeColor(0, 0, 0, 0.62)
		key.cooldown:SetDrawEdge(true)
		local r, g, b = Kit:RGB('lamp')
		if key.cooldown.SetEdgeTexture then pcall(key.cooldown.SetEdgeTexture, key.cooldown, [[Interface\Cooldown\edge]], r, g, b, 1) end
	end
	-- Our own cooldown frame, so this field and hook touch nothing of Blizzard's.
	key.cooldown.kitKey = key
	key.cooldown:HookScript('OnCooldownDone', function() if Kit.MotionNotify then Kit:MotionNotify('cooldown-done', key) end end)
	key.charge = Cooldown(nil, false)
	key.charge:SetHideCountdownNumbers(true)
	key.loc = Cooldown({0.6, 0.05, 0.03, 0.6}, true)
	key.numbers = key.cooldown.GetCountdownFontString and key.cooldown:GetCountdownFontString()

	local top = CreateFrame('Frame', nil, face)
	top:SetAllPoints()
	top:SetFrameLevel(face:GetFrameLevel() + 4)
	-- Hardware prints the legend on the cap, with no shadow; Classic over the icon.
	key.hotkey = Kit:Text(top, '', max(7, floor(size * 0.24)), 'white', true, not HW.On())
	key.hotkey:SetPoint('TOPLEFT', inset + 1, -inset - 1)
	key.hotkeyChip = Kit:Texture(top, 'round-3', 'ARTWORK', 0)
	Kit:Place(key.hotkeyChip, key.hotkey, 2, 1, 2, 1)
	key.hotkeyChip:Hide()
	key.count = Kit:Text(top, '', max(7, floor(size * 0.24)), 'lcdInk', true, false)
	key.count:SetPoint('BOTTOMRIGHT', -inset, inset)
	key.countChip = Kit:Texture(top, 'round-3', 'ARTWORK', 0)
	Kit:Place(key.countChip, key.count, 2, 1, 2, 1)
	Kit:Tint(key.countChip, 'lcd', 0.95)
	key.countChip:Hide()
	key.macro = Kit:Text(top, '', 7, 'white', false, true)
	key.macro:SetPoint('BOTTOMLEFT', inset, inset)
	key.macro:SetPoint('BOTTOMRIGHT', -inset, inset)
	key.macro:SetWordWrap(false)
	key.lamp = Kit:Led(top, 4, false)
	key.lamp:SetPoint('TOPRIGHT', -max(2, floor(inset / 2)), -max(2, floor(inset / 2)))
	Kit:ShowLed(key.lamp, false)
	-- A proc: a lit ring round the legend and a slow pulse of the key color.
	key.ring = Kit:Texture(top, 'ring-6', 'OVERLAY', 3)
	Kit:Place(key.ring, key.icon, 1, 1, 1, 1)
	Kit:Tint(key.ring, 'lamp')
	key.ring:Hide()
	key.glow = top:CreateTexture(nil, 'OVERLAY', nil, 2)
	key.glow:SetTexture(Kit.media..'glow.tga')
	key.glow:SetBlendMode('ADD')
	key.glow:SetPoint('TOPLEFT', -size * 0.28, size * 0.28)
	key.glow:SetPoint('BOTTOMRIGHT', size * 0.28, -size * 0.28)
	Kit:Tint(key.glow, 'lamp', 0.8)
	key.glow:Hide()
	key.pulse = key.glow:CreateAnimationGroup()
	key.pulse:SetLooping('BOUNCE')
	local fade = key.pulse:CreateAnimation('Alpha')
	fade:SetFromAlpha(0.25)
	fade:SetToAlpha(1)
	fade:SetDuration(0.4)
	fade:SetSmoothing('IN_OUT')

	keyOf[button] = key
	keys[#keys + 1] = key
	SizeKey(key, size)

	-- Clicks come down and up (key binds too), so the cap goes down with them.
	button:SetScript('PostClick', function(self, _, down)
		local pressed = keyOf[self]
		if down == nil then
			Press(pressed, true)
			C_Timer.After(0.08, function() Press(pressed, false) end)
		else
			Press(pressed, down and true or false)
		end
	end)
	button:HookScript('OnMouseUp', function(self) Press(keyOf[self], false) end)
	button:HookScript('OnHide', function(self) Press(keyOf[self], false) end)
	button:SetScript('OnEnter', function(self)
		local hovered = keyOf[self]
		hovered.hover:Show()
		if not hovered.has then return end
		if GameTooltip_SetDefaultAnchor then GameTooltip_SetDefaultAnchor(GameTooltip, self)
		else GameTooltip:SetOwner(self, 'ANCHOR_RIGHT') end
		GameTooltip:SetAction(hovered.slot)
		GameTooltip:Show()
	end)
	button:SetScript('OnLeave', function(self)
		keyOf[self].hover:Hide()
		GameTooltip:Hide()
	end)
	-- Paging (and drags) change the action; the key follows.
	button:SetScript('OnAttributeChanged', function(self, attribute, value)
		if attribute ~= 'action' then return end
		local changed = keyOf[self]
		WatchSlot(changed, tonumber(value))
		UI:Safe(UpdateKey, changed)
	end)
	WatchSlot(key, button:GetAttribute('action'))
	return button
end

-- Countdown numbers only show while the game's countdownForCooldowns setting
-- is on. With our switch on, it is turned on (the player's own value saved
-- once); switched off, their value comes back.
local function ApplyCountdownCVar()
	if InCombatLockdown() then return UI:AfterCombat(ApplyCountdownCVar, 'ab.countdown') end
	local get = (C_CVar and C_CVar.GetCVar) or GetCVar
	local set = (C_CVar and C_CVar.SetCVar) or SetCVar
	if not (get and set and UI.Account) then return end
	local saved = UI:Account('cvars')
	if DB().cdNumbers ~= false then
		local ok, current = pcall(get, 'countdownForCooldowns')
		if ok and current ~= nil and tostring(current) ~= '1' then
			if saved.countdownForCooldowns == nil then saved.countdownForCooldowns = tostring(current) end
			pcall(set, 'countdownForCooldowns', '1')
		end
	elseif saved.countdownForCooldowns ~= nil then
		pcall(set, 'countdownForCooldowns', saved.countdownForCooldowns)
		saved.countdownForCooldowns = nil
	end
end

-- Lock bars: follow the game's own setting, or force it either way.
local function ApplyLock()
	local lock = DB().lock
	if lock ~= 'on' and lock ~= 'off' then return end
	if InCombatLockdown() then return UI:AfterCombat(ApplyLock, 'ab.lock') end
	local set = (C_CVar and C_CVar.SetCVar) or SetCVar
	if set then pcall(set, 'lockActionBars', lock == 'on' and '1' or '0') end
end

-- Attributes read from settings that may only change out of combat.
local function ApplyCVars()
	if InCombatLockdown() then return UI:AfterCombat(ApplyCVars, 'ab.cvars') end
	local onDown = GetCVarBool and GetCVarBool('ActionButtonUseKeyDown')
	local locked = GetCVarBool and GetCVarBool('lockActionBars')
	for _, key in ipairs(keys) do
		key.button:SetAttribute('useOnKeyDown', onDown and true or false)
		key.button:SetAttribute('buttonlock', locked and true or false)
	end
end

-- Key binds -------------------------------------------------------------------------
-- Each key answers the game's own binding command (ACTIONBUTTON1, MULTIACTIONBAR1BUTTON1, ...),
-- so the binding window keeps working.
local binder = CreateFrame('Frame')
local extraKeys = {} -- {button, command, legend fontstring} for pet and stance keys
local dressed = {} -- Blizzard pet, stance and ability buttons -> our key parts

local function Bind()
	if InCombatLockdown() then return UI:AfterCombat(Bind, 'ab.bind') end
	ClearOverrideBindings(binder)
	local function BindCommand(command, buttonName)
		local first
		for _, binding in ipairs({GetBindingKey(command)}) do
			SetOverrideBindingClick(binder, false, binding, buttonName, 'LeftButton')
			first = first or binding
		end
		return first
	end
	for _, key in ipairs(keys) do
		local shown = key.index <= Shown(key.bar.id)
		key.binding = shown and Legend(BindCommand(key.command, key.button:GetName())) or ''
		UpdateLegend(key)
	end
	for _, extra in ipairs(extraKeys) do
		local legend = Legend(BindCommand(extra.command, extra.button:GetName()))
		if extra.hotkey then
			local text = DB().hotkeys and legend or ''
			local key = dressed[extra.button]
			if HW.On() and key and key.legendWidth then HW.FitLegend(extra.hotkey, text, key.legendWidth, key.legendSize)
			else extra.hotkey:SetText(text) end
		end
	end
end

-- Pet and stance keys: the game's own buttons, dressed as keys ----------------------
-- Pet keys are Blizzard's PetActionButtons moved into our module, as ElvUI does;
-- stance keys are new StanceButtonTemplate buttons. They keep the game's own
-- click and autocast handling; this only paints them.
-- Nothing runs every frame: the cap goes down from the button's own mouse and
-- click scripts (key binds click too), and the lamp follows the pet, stance
-- and action state events.
local function DressedPress(key, down)
	if not key or key.down == down then return end
	key.down = down
	Kit:SetSprite(key.skin, (key.sprites or Sprites())[down and 2 or 1])
	Sound(down)
end

local function DressedChecked(key)
	local okChecked, checked = pcall(key.button.GetChecked, key.button)
	checked = okChecked and Flag(checked) or false
	if checked ~= key.checked then
		key.checked = checked
		Kit:SetLed(key.lamp, checked)
		Kit:ShowLed(key.lamp, checked)
	end
end

local function RefreshDressed()
	for _, key in pairs(dressed) do UI:Safe(DressedChecked, key) end
end

local function WatchPress(button)
	button:HookScript('OnMouseDown', function(self)
		local key = dressed[self]
		if key then key.held = true end
		DressedPress(key, true)
	end)
	button:HookScript('OnMouseUp', function(self)
		local key = dressed[self]
		if key then key.held = nil end
		DressedPress(key, false)
	end)
	button:HookScript('OnHide', function(self) DressedPress(dressed[self], false) end)
	-- A key bind: a short press, and the lamp checked once the game has answered.
	button:HookScript('PostClick', function(self)
		local key = dressed[self]
		if not key then return end
		if not key.held then
			DressedPress(key, true)
			C_Timer.After(0.08, function() if not key.held then DressedPress(key, false) end end)
		end
		C_Timer.After(0, function() UI:Safe(DressedChecked, key) end)
	end)
end

-- round: a big round key (the extra and zone abilities, Hardware look).
local function Dress(button, size, round)
	if dressed[button] then return dressed[button] end
	local name = button:GetName() or ''
	local hardware = HW.On()
	round = round and hardware
	button:SetSize(size, size)
	for _, part in ipairs({'SlotArt', 'SlotBackground', 'RightDivider', 'BottomDivider', 'FlyoutBorderShadow', 'Border', 'NormalTexture2'}) do
		Fade(button[part])
	end
	Fade(_G[name..'NormalTexture'])
	if button.GetNormalTexture then Fade(button:GetNormalTexture()) end
	if button.GetPushedTexture then Fade(button:GetPushedTexture()) end
	if button.GetCheckedTexture then Fade(button:GetCheckedTexture()) end
	local inset = FaceInset(size)
	local left, top, right, bottom = HW.Window(size, inset)
	if round then left, top, right, bottom = inset + 2, inset + 2, inset + 2, inset + 2 end
	local icon = button.icon or button.Icon or _G[name..'Icon']
	local maskFile = round and 'circle' or 'mask-icon'
	if icon then
		icon:ClearAllPoints()
		icon:SetPoint('TOPLEFT', left, -top)
		icon:SetPoint('BOTTOMRIGHT', -right, bottom)
		HW.Crop(icon, size - left - right, size - top - bottom)
		local mask = button.IconMask
		if mask and mask.SetTexture then
			mask:SetTexture(Kit.media..maskFile..'.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
			mask:ClearAllPoints()
			mask:SetAllPoints(icon)
		end
		local cooldown = button.cooldown or _G[name..'Cooldown']
		if cooldown and not Forbidden(cooldown) then
			cooldown:ClearAllPoints()
			cooldown:SetAllPoints(icon)
			if cooldown.SetSwipeTexture then cooldown:SetSwipeTexture(Kit.media..maskFile..'.tga', 0, 0, 0, 0.72) end
		end
		local highlight = button.GetHighlightTexture and button:GetHighlightTexture()
		if highlight then highlight:ClearAllPoints(); highlight:SetAllPoints(icon); highlight:SetAlpha(0.2) end
	end
	local hotkey = button.HotKey or _G[name..'HotKey']
	if hotkey then
		hotkey:ClearAllPoints()
		if hardware and not round then
			-- Printed on the cap's band, in ink, like the action keys, in a box
			-- that ends short of the lamp (the game's own box is wider and right-aligned).
			Kit:Font(hotkey, HW.LegendSize(top), '', true)
			hotkey:SetJustifyH('LEFT')
			hotkey:SetPoint('LEFT', button, 'TOPLEFT', left, -top / 2)
			hotkey:SetWidth(max(size - left - right - 7, 1))
			hotkey:SetWordWrap(false)
			hotkey:SetShadowOffset(0, 0)
			local r, g, b = Kit:RGB(LightCap() and 'ink' or 'darkInk')
			hotkey:SetTextColor(r, g, b)
		else
			Kit:Font(hotkey, max(7, floor(size * 0.26)), 'OUTLINE', true)
			hotkey:SetPoint('TOPLEFT', inset, -inset)
		end
	end
	local count = button.Count or _G[name..'Count']
	if count then Kit:Font(count, max(8, floor(size * 0.3)), 'OUTLINE', true) end
	local key = CreateFrame('Frame', nil, button)
	key.button = button
	key:SetAllPoints()
	key:SetFrameLevel(max(button:GetFrameLevel() - 1, 0))
	key:EnableMouse(false)
	key.sprites = round and {'key-round', 'key-round-down'} or nil
	key.skin = Kit:Skin(key, (key.sprites or Sprites())[1], 'BACKGROUND', 0)
	key.skin.kitMaxCorner = max(5, floor(size * 0.27))
	Kit:FitSprite(key.skin, size, size)
	if hardware then
		key.slotRing = HW.Slot(key, key, round)
		HW.ShowSlot(key.slotRing, true)
	end
	local lid = CreateFrame('Frame', nil, button)
	lid:SetAllPoints()
	lid:SetFrameLevel(button:GetFrameLevel() + 3)
	lid:EnableMouse(false)
	if icon then
		if round then
			key.window = Kit:Texture(lid, 'circle-ring', 'ARTWORK', 0)
			Kit:Place(key.window, icon, 1, 1, 1, 1)
			key.window:SetVertexColor(0, 0, 0, 0.45)
		else
			key.window = Kit:Texture(lid, 'inset-6', 'ARTWORK', 0)
			Kit:Place(key.window, icon, 0, 0, 0, 0)
			key.window:SetVertexColor(0, 0, 0, 0.6)
		end
	end
	key.lamp = Kit:Led(lid, 4, false)
	if hardware and not round then key.lamp:SetPoint('CENTER', button, 'TOPRIGHT', -right - 2, -top / 2)
	else key.lamp:SetPoint('TOPRIGHT', -2, -2) end
	Kit:ShowLed(key.lamp, false)
	key.hotkey = hotkey
	key.legendWidth, key.legendSize = size - left - right - 7, HW.LegendSize(top)
	dressed[button] = key
	WatchPress(button)
	DressedChecked(key)
	return key
end

local petKeys, stanceKeys = {}, {}

local function UpdatePet()
	C_Timer.After(0, RefreshDressed)
	for index, button in ipairs(petKeys) do
		local ok, name, texture, isToken, isActive, autoCastAllowed, autoCastEnabled = pcall(GetPetActionInfo, index)
		if ok then
			local icon = button.icon or _G[button:GetName()..'Icon']
			if icon then
				if texture then
					icon:SetTexture(isToken and _G[texture] or texture)
					icon:Show()
				else
					icon:Hide()
				end
			end
			local follow = not IsSecret(name) and name == 'PET_ACTION_FOLLOW'
			button:SetChecked(Flag(isActive) and not follow or false)
			local overlay = button.AutoCastOverlay
			if overlay then
				overlay:SetShown(Flag(autoCastAllowed) or false)
				if overlay.ShowAutoCastEnabled then overlay:ShowAutoCastEnabled(Flag(autoCastEnabled) or false) end
			elseif button.AutoCastable then
				button.AutoCastable:SetShown(Flag(autoCastAllowed) or false)
				local shine = button.AutoCastShine
				if shine and AutoCastShine_AutoCastStart then
					if Flag(autoCastEnabled) then AutoCastShine_AutoCastStart(shine) else AutoCastShine_AutoCastStop(shine) end
				end
			end
			if icon then
				local usable = GetPetActionSlotUsable and GetPetActionSlotUsable(index)
				local dim = texture and (not (PetHasActionBar and PetHasActionBar()) or Flag(usable) == false)
				icon:SetDesaturated(dim and true or false)
				icon:SetVertexColor(dim and 0.5 or 1, dim and 0.5 or 1, dim and 0.48 or 1)
			end
			local cooldown = button.cooldown or _G[button:GetName()..'Cooldown']
			if cooldown and CooldownFrame_Set and GetPetActionCooldown then
				pcall(function() CooldownFrame_Set(cooldown, GetPetActionCooldown(index)) end)
			end
		end
	end
end

local function UpdateStance()
	C_Timer.After(0, RefreshDressed)
	local forms = GetNumShapeshiftForms and GetNumShapeshiftForms() or 0
	for index, button in ipairs(stanceKeys) do
		if index <= forms then
			local ok, texture, isActive, isCastable = pcall(GetShapeshiftFormInfo, index)
			if ok then
				local icon = button.icon or _G[button:GetName()..'Icon']
				if icon then
					icon:SetTexture(texture)
					icon:SetDesaturated(Flag(isCastable) == false)
				end
				button:SetChecked(Flag(isActive) or false)
				local cooldown = button.cooldown or _G[button:GetName()..'Cooldown']
				if cooldown and CooldownFrame_Set and GetShapeshiftFormCooldown then
					pcall(function() CooldownFrame_Set(cooldown, GetShapeshiftFormCooldown(index)) end)
				end
			end
		end
	end
end

-- Fading -------------------------------------------------------------------------------
-- A bar may fade out of combat, show only under the mouse, or both (then it
-- shows in a fight or under the mouse). Alpha only, so it works in combat.
local inCombat = false
local UpdateFades, WatchFade
do
local faders = {} -- frame -> {id, hovered, alpha}

local function FadeTarget(id, hovered)
	local db = BarDB(id)
	if not (db.fade or db.mouseover) then return 1 end
	if db.fade and inCombat then return 1 end
	if db.mouseover and hovered then return 1 end
	return Kit:Clamp(tonumber(db.fadeAlpha) or 0.25, 0, 1)
end

local function UpdateFade(frame)
	local fader = faders[frame]
	if not fader then return end
	local alpha = FadeTarget(fader.id, fader.hovered)
	if fader.alpha == alpha then return end
	fader.alpha = alpha
	Kit:FadeTo(frame, alpha, 'FAST')
end

-- reset: forget the alphas set, so every frame is faded again (after a settings change).
function UpdateFades(reset)
	for frame, fader in pairs(faders) do
		if reset then fader.alpha = nil end
		UpdateFade(frame)
	end
end

local function Hover(frame, on)
	local fader = faders[frame]
	if not fader then return end
	if on then
		fader.hovered = true
		return UpdateFade(frame)
	end
	-- Moving from key to key leaves one before entering the next.
	C_Timer.After(0.15, function()
		fader.hovered = frame:IsMouseOver() and true or false
		UpdateFade(frame)
	end)
end

function WatchFade(frame, id, buttons)
	faders[frame] = faders[frame] or {id = id}
	for _, button in ipairs(buttons) do
		button:HookScript('OnEnter', function() Hover(frame, true) end)
		button:HookScript('OnLeave', function() Hover(frame, false) end)
	end
	UpdateFade(frame)
end
end

-- Devices --------------------------------------------------------------------------------
local console, side, menu, petModule, stanceModule, xp, leave
local bars = {} -- id -> {header, buttons, device}

local function Device(name, model, title, opts)
	opts = opts or {}
	-- group: the Housing page's Console look (color and material) for every action bar device.
	local device = Kit:Device(UIParent, {name = name, model = model, title = title, surface = Surface(), radius = opts.radius or 12,
		header = opts.header, template = opts.template, ['group'] = 'console'})
	device:SetFrameStrata('LOW')
	device:SetFrameLevel(opts.level or 10)
	Kit:Relevel(device)
	device:SetScale(DB().scale or 1)
	if device.shell then device.shell:SetShown(DB().housing ~= false) end
	return device
end

-- One bar's keys: the first `shown` of them, in lines of `perRow`; vertical
-- lines run top to bottom. Out of combat only (they are secure buttons).
local function LayoutBar(bar, size, spacing, shown, perRow, vertical)
	shown = Kit:Clamp(floor(shown or 12), 1, 12)
	local across = min(Kit:Clamp(floor(perRow or 12), 1, 12), shown)
	local lines = math.ceil(shown / across)
	for index, button in ipairs(bar.buttons) do
		local key = keyOf[button]
		if key.size ~= size then SizeKey(key, size) end
		button:ClearAllPoints()
		if index <= shown then
			local line, place = floor((index - 1) / across), (index - 1) % across
			if vertical then button:SetPoint('TOPLEFT', line * (size + spacing), -place * (size + spacing))
			else button:SetPoint('TOPLEFT', place * (size + spacing), -line * (size + spacing)) end
			button:Show()
		else
			button:Hide()
		end
	end
	local long, short = across * size + (across - 1) * spacing, lines * size + (lines - 1) * spacing
	bar.width, bar.height = vertical and short or long, vertical and long or short
	bar.header:SetSize(bar.width, bar.height)
	return bar.width, bar.height
end

local function BuildBar(bar, parent, size, vertical)
	local header = CreateFrame('Frame', format('JiberishSpec01Bar%d', bar.id), parent, 'SecureHandlerStateTemplate')
	bar.header, bar.buttons, bar.vertical = header, {}, vertical
	for index = 1, 12 do
		bar.buttons[index] = CreateKey(bar, index, header, size)
	end
	LayoutBar(bar, size, Spacing(bar.id), Shown(bar.id), vertical and PerRow(bar.id) or 12, vertical)
	if bar.paging then
		header:SetAttribute('_onstate-page', [[
			if strsub(newstate, 1, 5) == 'bonus' then newstate = HasBonusActionBar() and GetBonusBarIndex() or 1 end
			newstate = tonumber(newstate) or 1
			self:SetAttribute('actionpage', newstate)
			control:ChildUpdate('page', newstate)
		]])
		RegisterStateDriver(header, 'page', PageConditions())
		-- The console's page LCD and lamps follow the page the secure snippet picked.
		header:HookScript('OnAttributeChanged', function(_, name, value)
			if name == 'actionpage' and console and console.pager then UI:Safe(HW.ShowPage, console.pager, value) end
		end)
	end
	bars[bar.id] = bar
	return header
end

-- The experience meter: LED dots in a track along the console's base. At the
-- level cap it shows the watched reputation instead.
local function BuildXP(parent)
	local onDark = Surface() == 'dark'
	local track = CreateFrame('Frame', nil, parent)
	track:SetHeight(XPHeight())
	track.shell = Kit:Shell(track, {surface = onDark and 'glass' or 'lcd', radius = 99, shadow = false, fill = not onDark and 'track' or nil})
	local bar = CreateFrame('StatusBar', nil, track)
	bar:SetPoint('TOPLEFT', 3, -2)
	bar:SetPoint('BOTTOMRIGHT', -3, 2)
	bar:SetStatusBarTexture([[Interface\Buttons\WHITE8X8]])
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)
	Kit:Perforate(bar, onDark and 'glass' or 'track', onDark and 'darkEdge' or nil)
	if Kit.MarkBar then Kit:MarkBar(bar) end
	track.bar = bar
	if HW.On() then HW.MeterParts(parent, track) end
	track:EnableMouse(true)
	track:SetScript('OnEnter', function(self)
		GameTooltip:SetOwner(self, 'ANCHOR_TOP')
		if self.tip then for _, line in ipairs(self.tip) do GameTooltip:AddLine(line, 1, 1, 1) end end
		GameTooltip:Show()
	end)
	track:SetScript('OnLeave', function() GameTooltip:Hide() end)
	return track
end

-- The console's LCD: level and progress, the time, or nothing.
local function Readout(text)
	local mode = DB().readout or 'level'
	if mode == 'off' then return '' end
	if mode == 'clock' then return date('%H:%M') end
	return text
end

-- Experience, reputation or honor along the base, and the console's LCD: the deck does it.
local function UpdateXP() Deck.UpdateMeters() end

-- The leave key: vehicles and flight paths.
local function UpdateLeave()
	if not leave then return end
	local can = (CanExitVehicle and CanExitVehicle()) or (UnitOnTaxi and UnitOnTaxi('player'))
	leave:SetShown(Flag(can) or false)
end

local function BuildLeave(parent)
	leave = Kit:Key(parent, {width = 50, height = 14, text = 'Leave', tone = 'primary', textSize = 7})
	leave.onClick = function()
		if UnitOnTaxi and UnitOnTaxi('player') then TaxiRequestEarlyLanding()
		elseif VehicleExit then VehicleExit() end
	end
	leave:Hide()
	return leave
end

-- Empty slots in the console: an unlit panel where a docked frame shows up.
local function Slot(parent, text)
	local slot = CreateFrame('Frame', nil, parent)
	slot:EnableMouse(false)
	slot.shell = Kit:Shell(slot, {surface = Surface() == 'dark' and 'glass' or 'lcd', radius = 6, shadow = false, alpha = 0.55})
	slot.text = Kit:Label(slot, text, Surface() == 'dark' and 'darkDim' or 'lcdDim', 8)
	slot.text:SetPoint('CENTER')
	return slot
end

local function Follow(slot, frame)
	if not frame then return end
	slot:SetShown(not frame:IsShown())
	frame:HookScript('OnShow', function() slot:Hide() end)
	frame:HookScript('OnHide', function() if frame.docked and slot.enabled ~= false then slot:Show() end end)
end

-- The console ----------------------------------------------------------------------------
local function UnitParts()
	local unitframes = UI.modules.unitframes
	if not (Docking() and DB().dock and unitframes and unitframes.enabled and unitframes.frames) then return {} end
	local frames, db = unitframes.frames, DB()
	-- A frame the console editor took out stays out.
	local custom = Deck.CustomLayout()
	local function In(key, frame)
		local spot = custom and custom[key]
		if type(spot) == 'table' and spot.off then return nil end
		return frame
	end
	return {player = In('uf.player', frames.player), target = In('uf.target', frames.target),
		playerCast = In('cb.player', unitframes.playerCast), targetCast = In('cb.target', unitframes.targetCast), module = unitframes,
		-- The small frames dock only when asked (each frame may not exist on every client).
		focus = db.dockFocus and frames.focus or nil, tot = db.dockToT and frames.targettarget or nil,
		pet = db.dockPet and frames.pet or nil}
end

-- The console editor's arrangement, or nil while the console arranges itself.
function Deck.CustomLayout()
	local layout = DB().consoleLayout
	if type(layout) == 'table' and next(layout) ~= nil then return layout end
end

-- The dim plates where docked frames show up (made when a frame first docks).
function Deck.Plates(parent, parts)
	for _, spec in ipairs({{'targetSlot', parts.target, 'No target'}, {'focusSlot', parts.focus, 'No focus'},
		{'totSlot', parts.tot, 'No ToT'}}) do
		if spec[2] and not parent[spec[1]] then
			local plate = Slot(parent, spec[3])
			-- A dim plate, not a box: it only marks where the frame appears.
			plate:SetAlpha(0.5)
			Kit:Font(plate.text, 7, nil, true)
			Follow(plate, spec[2])
			parent[spec[1]] = plate
		end
	end
end

-- Docked unit frames hide with the console in pet battles. Alpha only: they are
-- secure unit buttons, and alpha can change at any time.
local function HideDocked(hidden)
	for key, part in pairs(UnitParts()) do
		if key ~= 'module' and part and part.SetAlpha then part:SetAlpha(hidden and 0 or 1) end
	end
end

-- The console's own size: 0 is Auto (sized to what it holds); a fixed size is
-- kept, and the keys are fitted inside it.
local function FixedSize(value, least)
	value = tonumber(value)
	if not value or value <= 0 then return nil end
	return max(floor(value), least)
end

-- Docked frames: the console scales them down a little (to 0.8) only when a
-- fixed width is too narrow for them. Their own scale is kept as the base; a
-- change the unit frame module makes is taken as the new base.
local dockScaled = setmetatable({}, {__mode = 'k'})
local function DockScale(frame, factor)
	if not frame then return end
	local entry, current = dockScaled[frame], frame:GetScale()
	if not entry or math.abs(current - entry.set) > 0.001 then entry = {base = current}; dockScaled[frame] = entry end
	entry.set = entry.base * factor
	if math.abs(current - entry.set) > 0.001 then frame:SetScale(entry.set) end
end

-- A docked frame that changes size or scale later (another layout, a preset)
-- lays the console out again, so nothing ever overlaps.
local dockWatched = setmetatable({}, {__mode = 'k'})
local queuedLayout = false
local function WatchDocked(frame, relayout)
	if not frame or dockWatched[frame] then return end
	dockWatched[frame] = true
	local function Again()
		if (console and console.laying) or queuedLayout then return end
		queuedLayout = true
		C_Timer.After(0, function() queuedLayout = false; UI:Safe(relayout) end)
	end
	frame:HookScript('OnSizeChanged', Again)
	frame:HookScript('OnShow', Again)
	hooksecurefunc(frame, 'SetScale', Again)
end

local LayoutConsole
local function LayoutConsoleNow()
	local db = DB()
	local PAD = HPad()
	local parts = UnitParts()
	local scale = console:GetEffectiveScale()
	local function Measure(frame)
		if not frame then return 0, 0, 1 end
		local ratio = frame:GetEffectiveScale() / scale
		return frame:GetWidth() * ratio, frame:GetHeight() * ratio, ratio
	end
	local function Gap(bar)
		local gap = tonumber(db.keyGap)
		return (gap and gap > 0) and floor(gap) or Spacing(bar.id)
	end
	-- The widest bank at a key size.
	local function Banks(keySize)
		local widest = 0
		for _, bar in ipairs(console.bars) do
			local count = Shown(bar.id)
			widest = max(widest, count * keySize + (count - 1) * Gap(bar))
		end
		return widest
	end
	local fixedW, fixedH = FixedSize(db.consoleWidth, 300), FixedSize(db.consoleHeight, 80)
	-- Console units snapped to whole screen pixels (or up to the next one):
	-- every docked edge lands on one.
	local function Snap(value) return UI.Pixel.Snap(console, value) end
	local function SnapUp(value)
		local px = UI.Pixel.Px(console, 1)
		return math.ceil(value / px - 0.001) * px
	end
	-- Each side, from the edge in: the function keys, the docked frames' column
	-- (the player or target, a small frame under it: the focus under the player,
	-- the target of target under the target; the pet in the cast row's left end
	-- cell), then the banks. Both columns are as wide as the widest docked frame.
	local COLUMN = {'player', 'target', 'focus', 'tot', 'pet'}
	for _, key in ipairs(COLUMN) do WatchDocked(parts[key], LayoutConsole) end
	local function Widest()
		local widest = 0
		for _, key in ipairs(COLUMN) do widest = max(widest, (Measure(parts[key]))) end
		return widest
	end
	local fnW, fnH = Deck.FnBlock()
	local column = Widest()
	local function Side(frameWidth, stacked)
		local frame = frameWidth > 0 and frameWidth + COL_GAP or 0
		local keys = (fnW > 0 and not (stacked and frameWidth > 0)) and fnW + COL_GAP or 0
		if stacked and frameWidth > 0 then frame = max(frameWidth, fnW) + COL_GAP end
		return frame + keys
	end
	-- A fixed width too narrow even for the smallest keys: the docked frames
	-- scale down (not under 0.8), then the function keys go under them.
	local factor, stacked = 1, false
	if fixedW and column > 0 then
		local inner = fixedW - PAD * 2
		local least = Banks(16)
		if inner - 2 * Side(column) < least then
			local keys = fnW > 0 and fnW + COL_GAP or 0
			factor = Kit:Clamp(((inner - least) / 2 - keys - COL_GAP) / column, 0.8, 1)
			if inner - 2 * Side(column * factor) < least and fnW > 0 then stacked = true end
		end
	end
	for _, key in ipairs(COLUMN) do DockScale(parts[key], factor) end
	column = Widest()
	local pw, ph = Measure(parts.player)
	local tw, th = Measure(parts.target)
	local fw, fh = Measure(parts.focus)
	local ow, oh = Measure(parts.tot)
	local qw, qh = Measure(parts.pet)
	local sideWidth = Side(column, stacked)
	local fnPart = (fnW > 0 and not (stacked and column > 0)) and fnW + COL_GAP or 0
	local _, playerCastHeight = Measure(parts.playerCast)
	local _, targetCastHeight = Measure(parts.targetCast)
	local castHeight = max(playerCastHeight, targetCastHeight)
	-- The cast row: the cast bars over the banks' width and the pet in its
	-- left end cell, centred on one line.
	local lowHeight = max(castHeight, qh)
	local castRow = lowHeight > 0 and lowHeight + ROW_GAP or 0
	local xpHeight = Deck.BottomHeight()
	local bank = HW.On() and HW.BANK_H or 0
	local rows = #console.bars
	-- Menu and bag keys set into the console: a strip in the header (centred
	-- between the name and the readouts, when it fits), along the bottom over
	-- the stats, or anywhere in the body (placed in the console editor, in
	-- its own columns and key size).
	local menuSpot = Deck.CustomLayout() and Deck.CustomLayout().menu
	if type(menuSpot) ~= 'table' then menuSpot = nil end
	local inBody = menuSpot and tonumber(menuSpot.x) and tonumber(menuSpot.y) and true or false
	local stripKey = max(16, floor(KeySize() * 0.6))
	local edge = inBody and 'body' or (Deck.MenuEdge and Deck.MenuEdge() or 'bottom')
	if edge ~= 'header' and menuSpot and tonumber(menuSpot.keys) then stripKey = Kit:Clamp(floor(tonumber(menuSpot.keys)), 16, 40) end
	if edge == 'header' then stripKey = min(stripKey, HEAD - 6) end
	local stripColumns = edge == 'body' and menuSpot and tonumber(menuSpot.columns) or nil
	local stripW, stripH, stripCount = 0, 0, 0
	if Deck.MenuStrip and console.menuStrip then stripW, stripH, stripCount = Deck.MenuStrip(stripKey, stripColumns) end
	if edge == 'header' and stripCount > 0 then
		local right = PAD + (db.readout ~= 'off' and console.lcd:GetWidth() or 0) + (console.pager and console.pager:GetWidth() + 10 or 0)
		for _, panel in ipairs(console.panels or {}) do
			if db[panel.def.field] ~= false then right = right + panel:GetWidth() + 6 end
		end
		local estimate = fixedW or (PAD * 2 + Banks(KeySize()) + sideWidth * 2)
		if estimate - right - PAD - 160 < stripW + 12 then
			-- No room in the header: the strip goes to the bottom, at the bottom's size.
			edge = 'bottom'
			stripKey = max(16, floor(KeySize() * 0.6))
			stripW, stripH, stripCount = Deck.MenuStrip(stripKey)
		end
	end
	console.menuStripKey, console.menuStripCount, console.menuStripEdge, console.menuStripColumns = stripKey, stripCount, edge, stripColumns
	if edge == 'bottom' and stripCount > 0 then xpHeight = xpHeight + stripH + ROW_GAP end

	-- The key size: the one asked for, made just small enough to fit a fixed
	-- console (the console is never resized for the keys).
	local size = KeySize()
	local area = fixedW and (fixedW - PAD * 2 - sideWidth * 2)
	if area then
		for _, bar in ipairs(console.bars) do
			local count = Shown(bar.id)
			if count * size + (count - 1) * Gap(bar) > area then size = min(size, floor((area - (count - 1) * Gap(bar)) / count)) end
		end
	end
	if fixedH and rows > 0 then
		local room = fixedH - HEAD - castRow - xpHeight - PAD - rows * bank - (rows - 1) * GAP
		size = min(size, floor(room / rows))
	end
	size = max(size, 16)
	console.keySize = size

	-- The user's own arrangement (the console editor), or nil for the automatic one.
	local custom = Deck.CustomLayout()
	local function Saved(key) return custom and custom[key] or nil end
	-- The keyboard: each bar one row (or the columns its bank was given), as wide as its shown keys.
	local width, height = 0, 0
	for _, bar in ipairs(console.bars) do
		local shape = Saved('bank'..bar.id)
		LayoutBar(bar, size, Gap(bar), Shown(bar.id), shape and tonumber(shape.columns) or 12, false)
		width = max(width, bar.width)
		height = height + bar.height + bank
	end
	height = height + max(rows - 1, 0) * GAP
	if width == 0 then width, height = 12 * size + 11 * GAP, size end
	area = area or width
	local align = db.bankAlign or 'center'
	-- Spread: the keys share out the whole width with even gaps.
	if align == 'spread' and fixedW and not custom then
		for _, bar in ipairs(console.bars) do
			local count = Shown(bar.id)
			if count > 1 then LayoutBar(bar, size, max(Gap(bar), (area - count * size) / (count - 1)), count, 12, false) end
		end
	end
	-- The body: as tall as the tallest of the banks, the docked columns (the
	-- player and target with the room for their lamps and auras, then a row for
	-- the small frames under them; the function keys under them when stacked)
	-- and the function keys.
	local mainHeight = max(ph, th)
	local underMain = mainHeight > 0 and mainHeight + AUX or 0
	local smallRow = max(fh, oh)
	local frames = max(mainHeight, smallRow > 0 and underMain + smallRow or 0)
	local stackHeight = (stacked and fnH > 0) and fnH + 8 or 0
	local body = max(height, frames > 0 and frames + AUX + stackHeight or 0, fnH)
	if fixedH then body = max(fixedH - HEAD - castRow - xpHeight - PAD, 0) end
	-- An even number of pixels wide, so a centred console's edges land on pixels too.
	local consoleWidth = Snap((fixedW or (PAD * 2 + width + sideWidth * 2)) / 2) * 2
	-- The cast row starts on a pixel; the deck along the base is measured from the bottom.
	local castY = SnapUp(HEAD + body + ROW_GAP)
	local consoleHeight = fixedH and Snap(fixedH) or SnapUp((castRow > 0 and castY + lowHeight or HEAD + body) + xpHeight + PAD)
	local left = PAD + sideWidth
	-- The cast bars below share the banks' whole area.
	width = area

	-- Every element of the console is a block: a rect in console units from its
	-- top-left (x right, y down), on whole pixels. They are worked out here (the
	-- automatic arrangement, then the user's own over it), checked so none
	-- covers another or leaves the body, and then placed from the list.
	local blocks, bySlot = {}, {}
	local function Put(key, kind, frame, x, y, w, h)
		if w <= 0 or h <= 0 or (Saved(key) and Saved(key).off) then return end
		local block = {key = key, kind = kind, frame = frame, x = Snap(x), y = SnapUp(y), w = w, h = h}
		blocks[#blocks + 1] = block
		bySlot[key] = block
	end
	-- The banks, top row first (bar 1 is the bottom row, as on Blizzard's
	-- bars). In the Hardware look each has its printed legend above its keys.
	local bankY = HEAD + max(0, floor((body - height) / 2))
	for index = #console.bars, 1, -1 do
		local bar = console.bars[index]
		local x = align == 'left' and left or left + (area - bar.width) / 2
		Put('bank'..bar.id, 'bank', bar, x - 2, bankY, bar.width + 4, bank + bar.height)
		bankY = bankY + bank + bar.height + GAP
	end
	-- The columns sit centred on the body (the keys under them when stacked),
	-- never so low that the lamps or auras under the last frame leave it.
	local top = HEAD + (frames > 0 and max(0, floor(min((body - frames - stackHeight) / 2, body - frames - stackHeight - AUX))) or 0)
	local leftX, rightX = PAD + fnPart, consoleWidth - PAD - fnPart - column
	local function Centre(x, frameWidth) return x + (column - frameWidth) / 2 end
	Put('uf.player', 'unit', parts.player, Centre(leftX, pw), top + (mainHeight - ph) / 2, pw, ph)
	Put('uf.target', 'unit', parts.target, Centre(rightX, tw), top + (mainHeight - th) / 2, tw, th)
	Put('uf.focus', 'unit', parts.focus, Centre(leftX, fw), top + underMain + (smallRow - fh) / 2, fw, fh)
	Put('uf.targettarget', 'unit', parts.tot, Centre(rightX, ow), top + underMain + (smallRow - oh) / 2, ow, oh)
	-- The cast row, under the body.
	local castWidth = Snap((width - 8) / 2)
	for index, cast in ipairs({parts.playerCast or false, parts.targetCast or false}) do
		if cast then
			local _, castH = Measure(cast)
			Put(index == 1 and 'cb.player' or 'cb.target', 'cast', cast, left + (index - 1) * (castWidth + 8),
				castY + floor((lowHeight - castHeight) / 2), castWidth, castH)
		end
	end
	Put('uf.pet', 'unit', parts.pet, Centre(leftX, qw), castY + floor((lowHeight - qh) / 2), qw, qh)
	-- The function keys, each side its own cluster: at the outer edges, or under the docked frames.
	local lw, lh, rw, rh = Deck.FnSides()
	if stacked then
		local fnY = top + frames + 8
		Put('fnL', 'fn', 1, PAD + (column - lw) / 2, fnY, lw, lh)
		Put('fnR', 'fn', 2, consoleWidth - PAD - (column + rw) / 2, fnY, rw, rh)
	else
		Put('fnL', 'fn', 1, PAD, HEAD + max(0, floor((body - lh) / 2)), lw, lh)
		Put('fnR', 'fn', 2, consoleWidth - PAD - rw, HEAD + max(0, floor((body - rh) / 2)), rw, rh)
	end
	for side, key in ipairs({'fnL', 'fnR'}) do
		if bySlot[key] then bySlot[key].count = #select(3, Deck.FnCluster(side)) end
	end
	-- The meters and stats strip along the base, and the menu keys over them.
	local deckHeight = max(Deck.BottomHeight() - ROW_GAP, 0)
	Put('deck', 'deck', false, PAD, consoleHeight - PAD - deckHeight, consoleWidth - PAD * 2, deckHeight)
	local strip = console.menuStrip
	if strip and stripCount > 0 and edge == 'bottom' then
		Put('menu', 'menu', strip, (consoleWidth - stripW) / 2, consoleHeight - PAD - Deck.BottomHeight() - stripH, stripW, stripH)
	elseif strip and stripCount > 0 and edge == 'body' then
		Put('menu', 'menu', strip, 0, 0, stripW, stripH)
	end
	if bySlot.menu then bySlot.menu.count, bySlot.menu.keySize = stripCount, stripKey end
	-- The stance and pet keys: tucked on the console's top edge, out on their
	-- own spot (taken out), or set into the body like a bank (a saved spot).
	-- Stance keys with no stances for this character take no room.
	local minis = Deck.Minis()
	for _, mini in ipairs(minis) do
		local spot = Saved(mini.key)
		mini.columns = spot and tonumber(spot.columns) or nil
		mini.keys = spot and tonumber(spot.keys) or nil
		Deck.ShapeMini(mini)
		if spot and spot.off then
			mini.state = 'out'
		elseif spot and tonumber(spot.x) and tonumber(spot.y) then
			mini.state = 'in'
			if mini.count > 0 then
				local w, h = Measure(mini.module)
				Put(mini.key, 'mini', mini, 0, 0, w, h)
			end
		else
			mini.state = 'tucked'
		end
	end

	-- The user's arrangement: each saved block at its spot (a cast bar or the
	-- deck at its width). Nothing may cover another block or leave the body,
	-- so a block that would (another grew, a new one docked) moves to the
	-- nearest free spot; the saved ones keep theirs first. The console then
	-- fits its blocks; a fixed size is kept when they fit inside it.
	local px = UI.Pixel.Px(console, 1)
	local bounds = {left = SnapUp(PAD), top = SnapUp(HEAD), right = fixedW and floor((consoleWidth - PAD) / px) * px or nil,
		bottom = fixedH and floor((consoleHeight - PAD) / px) * px or nil}
	if custom then
		for _, block in ipairs(blocks) do
			local spot = custom[block.key]
			if type(spot) == 'table' and tonumber(spot.x) and tonumber(spot.y) then
				if (block.kind == 'cast' or block.kind == 'deck') and tonumber(spot.w) then block.w = Snap(max(tonumber(spot.w), 40)) end
				block.x, block.y, block.saved, block.rank = Snap(tonumber(spot.x)), SnapUp(tonumber(spot.y)), true, tonumber(spot.rank)
			end
		end
		local grid = UI.ConsoleGrid
		if grid then grid.Resolve(blocks, bounds, px * 2, px) end
		local right, bottom = 300 - PAD, HEAD
		for _, block in ipairs(blocks) do right, bottom = max(right, block.x + block.w), max(bottom, block.y + block.h) end
		consoleWidth = max(fixedW and consoleWidth or 0, Snap((right + PAD) / 2) * 2)
		consoleHeight = max(fixedH and consoleHeight or 0, SnapUp(bottom + PAD))
		-- The stance and pet keys tuck in over the first bank's ends.
		local first = bySlot['bank'..(console.bars[1] and console.bars[1].id or 1)]
		if first then left = first.x + 2 end
	end
	console:SetSize(consoleWidth, consoleHeight)
	console.blocks, console.slots, console.bounds = blocks, blocks, bounds
	if Deck.AdjustSlots then UI:Safe(Deck.AdjustSlots, blocks, console) end

	-- Place them. An LCD-style frame keeps its own LCD face; paper and dark ones
	-- sit on the housing. A cast bar takes its block's width.
	local keepShell = UI:Style('unitframes') == 'lcd'
	local docked = {}
	for _, block in ipairs(blocks) do
		local kind, frame, x, y = block.kind, block.frame, block.x, block.y
		if kind == 'bank' then
			if frame.bank then HW.PlaceBank(frame.bank, console, x, -y, block.w, bank > 0) end
			frame.header:ClearAllPoints()
			frame.header:SetPoint('TOPLEFT', console, 'TOPLEFT', x + 2, -(y + bank))
		elseif kind == 'fn' then
			Deck.PlaceFnAt(console, frame, x, y)
		elseif kind == 'menu' then
			frame:ClearAllPoints()
			frame:SetPoint('TOPLEFT', console, 'TOPLEFT', x, -y)
		elseif kind == 'mini' then
			Deck.PlaceMini(frame, console, x, y)
		elseif (kind == 'unit' or kind == 'cast') and frame then
			docked[block.key] = frame
			local ratio = select(3, Measure(frame))
			if kind == 'cast' then frame:SetWidth(block.w / ratio) end
			parts.module:SetDocked(frame, true, keepShell)
			UI:DockMover(block.key, function(target)
				local now = target:GetEffectiveScale() / console:GetEffectiveScale()
				target:SetPoint('TOPLEFT', console, 'TOPLEFT', x / now, -y / now)
			end)
		end
	end
	-- Frames taken out of the console get their own spot back.
	for key, frame in pairs(console.docked or {}) do
		if not docked[key] then
			UI:DockMover(key, nil)
			local unitframes = UI.modules.unitframes
			if unitframes and unitframes.SetDocked then unitframes:SetDocked(frame, false) end
			DockScale(frame, 1)
		end
	end
	console.docked = docked
	for index = 1, 2 do
		if not bySlot[index == 1 and 'fnL' or 'fnR'] then Deck.PlaceFnAt(console, index, nil) end
	end
	-- Plates where a docked frame shows up when it has no unit: dim, the frame's
	-- size (the target's is the player's), or nothing.
	Deck.Plates(console, parts)
	local plateOn = db.targetPlate ~= 'collapse'
	local function Plate(plate, frame, rect, w, h)
		if not plate then return end
		plate.enabled = plateOn and frame ~= nil and rect ~= nil
		if not plate.enabled then plate:Hide() return end
		plate:SetSize(w or rect.w, h or rect.h)
		plate:ClearAllPoints()
		plate:SetPoint('TOPLEFT', console, 'TOPLEFT', rect.x + (rect.w - (w or rect.w)) / 2, -rect.y)
		plate:SetShown(not frame:IsShown())
	end
	Plate(console.targetSlot, parts.target, bySlot['uf.target'], pw > 0 and pw or tw, ph > 0 and ph or th)
	Plate(console.focusSlot, parts.focus, bySlot['uf.focus'])
	Plate(console.totSlot, parts.tot, bySlot['uf.targettarget'])
	for index, key in ipairs({'cb.player', 'cb.target'}) do
		local rect, slot = bySlot[key], console.castSlots[index]
		if rect then
			slot:SetSize(rect.w, castHeight)
			slot:ClearAllPoints()
			slot:SetPoint('TOPLEFT', console, 'TOPLEFT', rect.x, -rect.y)
		end
	end
	local deck = bySlot.deck
	if deck then
		Deck.PlaceBottom(console, deck.x, consoleWidth - deck.x - deck.w, consoleHeight - deck.y - deck.h)
	else
		Deck.PlaceBottom(console, PAD, PAD, PAD, true)
	end
	if console.lcd then console.lcd:SetShown(DB().readout ~= 'off') end
	-- Header panels, leftward from the page lamps (or the LCD) while they fit.
	local headerStrip = strip and stripCount > 0 and edge == 'header'
	if console.panels then
		local anchor = console.pager or console.lcd
		local used = PAD + (console.lcd:IsShown() and console.lcd:GetWidth() or 0) + (console.pager and console.pager:GetWidth() + 10 or 0) + 8
		if headerStrip then used = used + stripW + 12 end
		local last = Deck.PlacePanels(console, anchor, used)
		-- The header strip sits centred between the name and the readouts
		-- (against the readouts when the name is long); the name ends before it.
		if headerStrip then
			strip:ClearAllPoints()
			local x = Deck.HeaderStripX(console, last, stripW)
			if x then
				strip:SetPoint('LEFT', console, 'TOPLEFT', x, -HEAD / 2)
				console.headerStripX = x
			else
				strip:SetPoint('RIGHT', last, 'LEFT', -12, 0)
				console.headerStripX = nil
			end
			last = strip
		end
		console.title:SetPoint('RIGHT', last, 'LEFT', -8, 0)
		if leave then
			leave:ClearAllPoints()
			leave:SetPoint('RIGHT', last, 'LEFT', -8, 0)
		end
	end
	if strip then
		strip:SetSize(max(stripW, 1), max(stripH, 1))
		strip:SetShown(stripCount > 0)
		-- Put the menu and bag keys into it (or back on their own devices).
		if Deck.LayoutMenu then Deck.LayoutMenu() end
	end
	-- Tucked pet and stance keys sit on the console's top edge, under it;
	-- taken-out ones go back to their own spot. The editor sees the tucked
	-- ones too (outside the body, so they hold no room in it).
	local tucked = {}
	local stanceRect
	for _, mini in ipairs(minis) do
		if mini.state == 'out' then
			Deck.FreeMini(mini)
		elseif mini.state == 'tucked' then
			local w, h = Measure(mini.module)
			local x = mini.key == 'stance' and left - 8 or consoleWidth - left + 8 - w
			local y = 8 - h
			-- Never over the other one: the pet keys go above the stance keys if they would meet.
			if stanceRect and mini.count > 0 and x < stanceRect.x + stanceRect.w + 4 and stanceRect.x < x + w + 4 then
				y = stanceRect.y - h - 4
			end
			Deck.PlaceMini(mini, console, x, y, true)
			if mini.count > 0 then
				local rect = {key = mini.key, kind = 'mini', x = x, y = y, w = w, h = h, tucked = true, count = mini.count, keySize = mini.size}
				tucked[#tucked + 1] = rect
				if mini.key == 'stance' then stanceRect = rect end
			end
		end
	end
	-- The menu strip in the header, as the editor sees it (outside the body).
	if strip and stripCount > 0 and edge == 'header' and console.headerStripX then
		tucked[#tucked + 1] = {key = 'menu', kind = 'menu', x = console.headerStripX, y = (HEAD - stripH) / 2, w = stripW, h = stripH,
			tucked = true, header = true, count = stripCount, keySize = stripKey}
	end
	console.tucked = tucked
end

function LayoutConsole()
	if not console then return end
	if InCombatLockdown() then return UI:AfterCombat(LayoutConsole, 'ab.layout') end
	console.laying = true
	local ok, problem = pcall(LayoutConsoleNow)
	console.laying = nil
	if not ok then error(problem, 0) end
end

local function BuildConsole()
	console = Device('JiberishSpec01Console', 'CX-1', 'Console', {template = 'SecureHandlerStateTemplate', radius = 14})
	-- The whole console steps aside in pet battles.
	RegisterStateDriver(console, 'visibility', '[petbattle] hide; show')
	console.lcd = Kit:LCDPanel(console, {radius = 3})
	console.lcd:SetSize(104, 14)
	console.lcd:SetPoint('TOPRIGHT', -PAD, -5)
	console.readout = Kit:Text(console.lcd, '', 'tiny', 'lcdInk', true)
	console.readout:SetPoint('RIGHT', -5, 0)
	BuildLeave(console)
	if HW.On() then
		HW.Decorate(console, 14)
		console.pager = HW.BuildPager(console)
		console.pager:SetPoint('RIGHT', console.lcd, 'LEFT', -10, 0)
		console.title:SetPoint('RIGHT', console.pager, 'LEFT', -8, 0)
		leave:SetPoint('RIGHT', console.pager, 'LEFT', -8, 0)
	else
		console.title:SetPoint('RIGHT', console.lcd, 'LEFT', -8, 0)
		leave:SetPoint('RIGHT', console.lcd, 'LEFT', -6, 0)
	end
	local size = KeySize()
	console.bars = {}
	for row = 1, Rows() do
		if BarEnabled(row) then
			BuildBar(BARS[row], console, size)
			console.bars[#console.bars + 1] = BARS[row]
			WatchFade(BARS[row].header, row, BARS[row].buttons)
			if HW.On() then BARS[row].bank = HW.Bank(console, 'Bank '..strsub('ABC', row, row)..(row == 1 and '  Main' or '')) end
		end
	end
	Deck.Plates(console, UnitParts())
	-- The cast slots only hold the space: a cast bar appears there when a cast
	-- starts, and nothing is printed while nothing is casting.
	console.castSlots = {Slot(console, ''), Slot(console, '')}
	for _, slot in ipairs(console.castSlots) do slot:Hide() end
	xp = BuildXP(console)
	-- Where the menu and bag keys go when they are set into the console.
	console.menuStrip = CreateFrame('Frame', nil, console)
	console.menuStrip:SetFrameLevel(console:GetFrameLevel() + 4)
	console.menuStrip:Hide()
	Deck.BuildBottom(console)
	Deck.BuildFn(console)
	Deck.BuildPanels(console)
	if console.pager and BARS[1].header then HW.ShowPage(console.pager, BARS[1].header:GetAttribute('actionpage') or 1) end
	UI:RegisterMover(console, 'ab.console', 'Console', {'BOTTOM', 0, 12})
end

-- The console's width and height and the key size in use (nil without a console).
function UI:ConsoleSize()
	if not console then return nil end
	return floor(console:GetWidth() + 0.5), floor(console:GetHeight() + 0.5), console.keySize
end

-- The console's blocks as it last laid them out: a list of {key, kind, x, y,
-- w, h} in console units from its top-left corner (y down); kind is 'bank',
-- 'unit', 'cast', 'fn', 'deck' or 'menu'. Also its body's bounds.
function UI:ConsoleSlots()
	local list = {}
	for _, slot in ipairs(console and console.slots or {}) do
		local mini = slot.kind == 'mini' and slot.frame or nil
		list[#list + 1] = {key = slot.key, kind = slot.kind, x = slot.x, y = slot.y, w = slot.w, h = slot.h, saved = slot.saved,
			count = mini and mini.count or slot.count, keySize = mini and mini.size or slot.keySize}
	end
	-- Pet and stance keys tucked on the top edge (outside the body).
	for _, slot in ipairs(console and console.tucked or {}) do list[#list + 1] = slot end
	return list, console and console.bounds
end
UI.ConsoleBlocks = UI.ConsoleSlots

-- The console device (nil in the free layout), and laying it out again now.
function UI:ConsoleFrame() return console end
function UI:RelayoutConsole() if console then LayoutConsole() end end

-- Free layout: every bar is its own device, sized to its keys.
local function LayoutFree()
	if InCombatLockdown() then return UI:AfterCombat(LayoutFree, 'ab.free') end
	for row = 1, Rows() do
		local bar, device = BARS[row], BARS[row].device
		if device then
			local width, height = LayoutBar(bar, BarSize(row, KeySize()), Spacing(row), Shown(row), PerRow(row), false)
			local extra = (row == 1 and xp) and Deck.BottomHeight() or 0
			device:SetSize(width + PAD * 2, height + PAD * 2 + extra)
			if row == 1 and xp then Deck.PlaceBottom(device, PAD) end
		end
	end
end

local function BuildFree()
	local size = KeySize()
	for row = 1, Rows() do
		if BarEnabled(row) then
			local device = Device(format('JiberishSpec01BarDevice%d', row), 'AB-'..row, '', {header = false,
				template = 'SecureHandlerStateTemplate', radius = 10})
			RegisterStateDriver(device, 'visibility', '[petbattle] hide; show')
			local header = BuildBar(BARS[row], device, BarSize(row, size))
			header:SetPoint('TOPLEFT', PAD, -PAD)
			BARS[row].device = device
			HW.Decorate(device, 10)
			if row == 1 then
				xp = BuildXP(device)
				Deck.BuildBottom(device)
				Deck.PlaceBottom(device, PAD)
				BuildLeave(device)
				leave:SetPoint('BOTTOMRIGHT', device, 'TOPRIGHT', -PAD, 4)
			end
			WatchFade(device, row, BARS[row].buttons)
		end
	end
	LayoutFree()
	for row = 1, Rows() do
		local device = BARS[row].device
		if device then
			UI:RegisterMover(device, 'ab.bar'..row, 'Bar '..row, {'BOTTOM', 0, 12 + (row - 1) * (device:GetHeight() + 6)})
		end
	end
end

-- Side bars: bar 5 and bar 4 in one device, as two columns at the screen edge
-- or as two rows. Blizzard's left bar comes first.
local function SideSize(id) return BarSize(id, max(24, floor(KeySize() * 0.9))) end

local function LayoutSide()
	if not side then return end
	if InCombatLockdown() then return UI:AfterCombat(LayoutSide, 'ab.side') end
	local vertical = DB().sideLayout ~= 'rows'
	local x, y, width, height = PAD, -HEAD, 0, 0
	for _, id in ipairs({5, 4}) do
		local bar = BARS[id]
		if bar.header then
			local w, h = LayoutBar(bar, SideSize(id), Spacing(id), Shown(id), PerRow(id), vertical)
			bar.header:ClearAllPoints()
			bar.header:SetPoint('TOPLEFT', side, 'TOPLEFT', x, y)
			if vertical then
				x = x + w + GAP
				width, height = width + w + GAP, max(height, h)
			else
				y = y - h - GAP
				width, height = max(width, w), height + h + GAP
			end
		end
	end
	if vertical then width = width - GAP else height = height - GAP end
	side:SetSize(PAD * 2 + max(width, 20), HEAD + max(height, 20) + PAD)
end

local function BuildSide()
	if not (BarEnabled(4) or BarEnabled(5)) then return end
	side = Device('JiberishSpec01SideBars', 'SX-1', 'Side', {template = 'SecureHandlerStateTemplate', radius = 12})
	HW.Decorate(side, 12)
	RegisterStateDriver(side, 'visibility', '[petbattle] hide; show')
	local vertical = DB().sideLayout ~= 'rows'
	for _, id in ipairs({5, 4}) do
		if BarEnabled(id) then
			BuildBar(BARS[id], side, SideSize(id), vertical)
			WatchFade(BARS[id].header, id, BARS[id].buttons)
		end
	end
	LayoutSide()
	UI:RegisterMover(side, 'ab.side', 'Side bars', {'RIGHT', -8, 0})
end

-- Blizzard's pet buttons, anchored in our strip; out of combat only.
local function PlacePetKeys()
	if not petModule then return end
	if InCombatLockdown() then return UI:AfterCombat(PlacePetKeys, 'ab.petkeys') end
	for _, button in pairs(petKeys) do
		if button:GetParent() ~= petModule then button:SetParent(petModule) end
		button:Show()
	end
	local spot = Deck.CustomLayout() and Deck.CustomLayout().petbar
	Deck.LayoutMini(petModule, petKeys, NUM_PET_ACTION_SLOTS or 10, type(spot) == 'table' and tonumber(spot.columns) or nil)
end

local function BuildPet()
	local size = BarSize('Pet', max(20, floor(KeySize() * 0.72)))
	local count = NUM_PET_ACTION_SLOTS or 10
	petModule = Device('JiberishSpec01PetKeys', 'PT-1', '', {header = false, template = 'SecureHandlerStateTemplate', radius = 9, level = 4})
	petModule:SetSize(PAD + count * size + (count - 1) * Spacing('Pet') + PAD, size + 16 + (HW.On() and HW.BANK_H or 0))
	petModule.keySize, petModule.spacingId = size, 'Pet'
	HW.MiniLegend(petModule, 'Pet')
	RegisterStateDriver(petModule, 'visibility', '[petbattle][vehicleui][overridebar][possessbar] hide; [@pet,exists] show; hide')
	for index = 1, count do
		local button = _G['PetActionButton'..index]
		if button and not Forbidden(button) then
			Dress(button, size)
			petKeys[index] = button
			extraKeys[#extraKeys + 1] = {button = button, command = 'BONUSACTIONBUTTON'..index, hotkey = button.HotKey}
		end
	end
	PlacePetKeys()
	local buttons = {}
	for _, button in pairs(petKeys) do buttons[#buttons + 1] = button end
	WatchFade(petModule, 'Pet', buttons)
	-- Edit Mode lays the pet bar out again later; take the keys back each time.
	local bar = _G.PetActionBar
	if bar and type(bar.UpdateGridLayout) == 'function' then
		hooksecurefunc(bar, 'UpdateGridLayout', function() C_Timer.After(0, PlacePetKeys) end)
	end
	if not Docking() then UI:RegisterMover(petModule, 'ab.pet', 'Pet keys', {'BOTTOM', 200, 150}) end
end

local function LayoutStance()
	if not stanceModule then return end
	if InCombatLockdown() then return UI:AfterCombat(LayoutStance, 'ab.stance') end
	local forms = GetNumShapeshiftForms and GetNumShapeshiftForms() or 0
	for index, button in ipairs(stanceKeys) do button:SetShown(index <= forms) end
	stanceModule:SetShown(forms > 0)
	local spot = Deck.CustomLayout() and Deck.CustomLayout().stance
	if forms > 0 then Deck.LayoutMini(stanceModule, stanceKeys, forms, type(spot) == 'table' and tonumber(spot.columns) or nil) end
	UpdateStance()
	-- Set into the console, the stance keys take room only while there are stances.
	if console and stanceModule.forms ~= nil and (stanceModule.forms > 0) ~= (forms > 0) then LayoutConsole() end
	stanceModule.forms = forms
end

local function BuildStance()
	local size = BarSize('Stance', max(20, floor(KeySize() * 0.72)))
	stanceModule = Device('JiberishSpec01StanceKeys', 'ST-1', '', {header = false, radius = 9, level = 4})
	stanceModule.size, stanceModule.keySize, stanceModule.spacingId = size, size, 'Stance'
	stanceModule:SetHeight(size + 16 + (HW.On() and HW.BANK_H or 0))
	HW.MiniLegend(stanceModule, 'Stance')
	for index = 1, (NUM_STANCE_SLOTS or 10) do
		local button = CreateFrame('CheckButton', 'JiberishSpec01StanceKey'..index, stanceModule, 'StanceButtonTemplate')
		button:SetID(index)
		button:SetPoint('LEFT', PAD + (index - 1) * (size + Spacing('Stance')), (Docking() and 4 or 0) - (HW.On() and HW.BANK_H / 2 or 0))
		Dress(button, size)
		stanceKeys[index] = button
		extraKeys[#extraKeys + 1] = {button = button, command = 'SHAPESHIFTBUTTON'..index, hotkey = button.HotKey}
	end
	WatchFade(stanceModule, 'Stance', stanceKeys)
	if not Docking() then UI:RegisterMover(stanceModule, 'ab.stance', 'Stance keys', {'BOTTOM', -200, 150}) end
end

-- The pet and stance keys as console blocks -------------------------------------------------
-- Keys in lines of `columns` (all in one line by default), evenly spaced, the
-- device sized round them. Out of combat only (secure buttons).
function Deck.LayoutMini(module, keys, count, columns)
	if not module or InCombatLockdown() then return end
	count = max(floor(count or 1), 1)
	local size, spacing = module.keySize or 24, Spacing(module.spacingId or 'Stance')
	local across = Kit:Clamp(floor(columns or count), 1, count)
	local lines = math.ceil(count / across)
	local keysW, keysH = across * size + (across - 1) * spacing, lines * size + (lines - 1) * spacing
	local height = keysH + 16 + (HW.On() and HW.BANK_H or 0)
	local top = (height - keysH) / 2 - ((Docking() and 4 or 0) - (HW.On() and HW.BANK_H / 2 or 0))
	module:SetSize(PAD * 2 + keysW, height)
	for index = 1, count do
		local button = keys[index]
		if button then
			local line, place = floor((index - 1) / across), (index - 1) % across
			button:ClearAllPoints()
			button:SetPoint('TOPLEFT', module, 'TOPLEFT', PAD + place * (size + spacing), -(top + line * (size + spacing)))
		end
	end
end

-- The two as the console sees them: {key, module, mover, count, size}. The
-- pet keys always hold their room (a pet can come in combat); the stance keys
-- only while this character has stances.
function Deck.Minis()
	local list = {}
	if stanceModule then
		list[#list + 1] = {key = 'stance', module = stanceModule, mover = 'ab.stance', label = 'Stance keys', at = {'BOTTOM', -200, 150},
			count = GetNumShapeshiftForms and GetNumShapeshiftForms() or 0, size = stanceModule.keySize, keysList = stanceKeys}
	end
	if petModule then
		list[#list + 1] = {key = 'petbar', module = petModule, mover = 'ab.pet', label = 'Pet keys', at = {'BOTTOM', 200, 150},
			count = NUM_PET_ACTION_SLOTS or 10, size = petModule.keySize, keysList = petKeys}
	end
	return list
end

-- Its shape (columns) and key size (a scale on the device) for where it is.
function Deck.ShapeMini(mini)
	local module = mini.module
	if mini.count > 0 then Deck.LayoutMini(module, mini.keysList, mini.count, mini.columns) end
	local base = DB().scale or 1
	local scale = mini.keys and base * Kit:Clamp(mini.keys, 16, 48) / max(mini.size or 24, 1) or base
	if math.abs(module:GetScale() - scale) > 0.001 then module:SetScale(scale) end
end

-- Anchor it inside the console (or, tucked, on its top edge and under it) at
-- x, y in console units from the top-left. With a mover of its own (it was
-- taken out once), the mover holds it there.
function Deck.PlaceMini(mini, parent, x, y, tucked)
	local module = mini.module
	local function Place(frame)
		local ratio = frame:GetEffectiveScale() / parent:GetEffectiveScale()
		frame:SetPoint('TOPLEFT', parent, 'TOPLEFT', x / ratio, -y / ratio)
	end
	-- Inside, it sits on the console's housing, above it; tucked, under its edge.
	module:SetFrameLevel(tucked and 4 or parent:GetFrameLevel() + 3)
	Kit:Relevel(module)
	if module.shell then module.shell:SetShown(tucked and DB().housing ~= false or false) end
	if UI:HasMover(mini.mover) then
		UI:DockMover(mini.mover, Place)
	else
		module:ClearAllPoints()
		Place(module)
	end
end

-- Taken out of the console: its own spot (a mover, made the first time).
function Deck.FreeMini(mini)
	local module = mini.module
	module:SetFrameLevel(4)
	Kit:Relevel(module)
	if module.shell then module.shell:SetShown(DB().housing ~= false) end
	if UI:HasMover(mini.mover) then
		UI:DockMover(mini.mover, nil)
	else
		UI:RegisterMover(module, mini.mover, mini.label, mini.at)
	end
end

-- Menu and bags -----------------------------------------------------------------------------
-- Blizzard's micro buttons and bag slots move into the MN-1 device; they are
-- plain buttons, so this is safe at any time.
--
-- With SPEC-01 glyphs (the default), every micro button and bag slot shows a
-- printed glyph on its key instead of the game's art: the game's own textures
-- are only faded (never taken away), so the buttons keep working and the art
-- comes back with the Blizzard setting. A small lamp on the key lights while
-- its window is open and breathes amber when the game flashes the button
-- (talent points to spend, an unread guild or friend notice).
-- Glyphs in atlas order: the same list as MENU_ICONS in tools/build-hardware-art.py.
-- Kept in a function of its own: the main chunk may hold at most 200 locals.
local RepaintMenu, LayoutMenu, BuildMenu
;(function()
local MENU_ICONS = {'character', 'spellbook', 'talents', 'professions', 'achievements', 'legacy', 'quest', 'guild',
	'social', 'finder', 'journal', 'collections', 'menu', 'help', 'store', 'house',
	'map', 'pvp', 'backpack', 'bag', 'reagent', 'key', 'mount', 'hearth',
	'drawer', 'move', 'calendar', 'meter', 'lock', 'reload', 'macro'}
local MENU_INDEX = {}
for index, name in ipairs(MENU_ICONS) do MENU_INDEX[name] = index - 1 end
Deck.MENU_INDEX = MENU_INDEX -- the console's function keys use the same glyphs
local GLYPH_OF = {
	CharacterMicroButton = 'character', SpellbookMicroButton = 'spellbook', PlayerSpellsMicroButton = 'talents',
	ProfessionMicroButton = 'professions', TalentMicroButton = 'talents', AchievementMicroButton = 'achievements',
	LegacyMicroButton = 'legacy', QuestLogMicroButton = 'quest', GuildMicroButton = 'guild', SocialsMicroButton = 'social',
	LFDMicroButton = 'finder', LFGMicroButton = 'finder', EJMicroButton = 'journal', CollectionsMicroButton = 'collections',
	MainMenuMicroButton = 'menu', HelpMicroButton = 'help', StoreMicroButton = 'store', HousingMicroButton = 'house',
	WorldMapMicroButton = 'map', PVPMicroButton = 'pvp',
	MainMenuBarBackpackButton = 'backpack', CharacterBag0Slot = 'bag', CharacterBag1Slot = 'bag', CharacterBag2Slot = 'bag',
	CharacterBag3Slot = 'bag', CharacterReagentBag0Slot = 'reagent', KeyRingButton = 'key',
}
-- Bag slots and the container each shows, to tell an empty slot from a full one.
local BAG_ID = {MainMenuBarBackpackButton = 0, CharacterBag0Slot = 1, CharacterBag1Slot = 2, CharacterBag2Slot = 3,
	CharacterBag3Slot = 4, CharacterReagentBag0Slot = 5}

local menuKeys = {}   -- button -> our key frame (and its glyph and lamp)
local faded = {}      -- button -> {region = true}: the game's art we faded for glyphs
local alerting = {}   -- button -> true while the game flashes it

local function GlyphsOn() return DB().menuIcons ~= 'blizzard' end

local function BagIcon(button)
	return button.icon or button.Icon or _G[(button:GetName() or '')..'IconTexture']
end

-- A bag slot with nothing in it (the backpack is never empty).
local function EmptyBag(name)
	local bag = BAG_ID[name]
	if not bag or bag == 0 then return false end
	local toInventory = C_Container and C_Container.ContainerIDToInventoryID or _G.ContainerIDToInventoryID
	if not toInventory then return false end
	local ok, slot = pcall(toInventory, bag)
	if not ok or IsSecret(slot) or not slot then return false end
	local texture = GetInventoryItemTexture('player', slot)
	if IsSecret(texture) then return false end
	return texture == nil
end

-- The game's art on a micro button: every texture region but our own.
local function FadeArt(button, on)
	local list = faded[button]
	if on then
		if not list then list = {}; faded[button] = list end
		for _, region in ipairs({button:GetRegions()}) do
			if region.IsObjectType and region:IsObjectType('Texture') then
				list[region] = true
				region:SetAlpha(0)
			end
		end
		for _, getter in ipairs({'GetNormalTexture', 'GetPushedTexture', 'GetDisabledTexture', 'GetHighlightTexture'}) do
			local region = button[getter] and button[getter](button)
			if region then list[region] = true; region:SetAlpha(0) end
		end
		local overlay = button.NotificationOverlay
		if type(overlay) == 'table' and overlay.SetAlpha then list[overlay] = true; overlay:SetAlpha(0) end
	elseif list then
		for region in pairs(list) do region:SetAlpha(1) end
		faded[button] = nil
	end
end

local function PaintMenuButton(button)
	local key = menuKeys[button]
	if not key or not key.glyph then return end
	local name = button:GetName()
	local glyphs = GlyphsOn()
	local isBag = BAG_ID[name] ~= nil or name == 'KeyRingButton'
	local showGlyph = glyphs
	if isBag then
		local icon = BagIcon(button)
		local items = DB().bagIcons ~= 'glyphs'
		-- Bag icons: the item's own icon, the glyph only in an empty slot.
		if glyphs and items then showGlyph = EmptyBag(name) end
		-- The slot's own art (frame, quality ring, highlights) always goes with
		-- SPEC-01 keys; the bag's icon comes back, set in a black window on the key.
		FadeArt(button, glyphs)
		local window = glyphs and not showGlyph and icon ~= nil
		if icon then icon:SetAlpha((window or not glyphs) and 1 or 0) end
		if key.window then key.window:SetShown(window) end
	else
		FadeArt(button, glyphs)
	end
	key.glyph:SetShown(showGlyph)
	if showGlyph then
		local share = tonumber(DB()[isBag and 'bagsGlyph' or 'menuGlyph']) or (isBag and 0.6 or 0.68)
		local size = floor(min(button:GetWidth(), button:GetHeight()) * share + 0.5)
		key.glyph:SetSize(size, size)
		local enabled = not button.IsEnabled or button:IsEnabled()
		local hovered = button.IsMouseOver and button:IsMouseOver()
		Kit:Tint(key.glyph, LightCap() and 'ink' or 'darkInk', not enabled and 0.3 or ((hovered and 1) or 0.82))
	end
	-- The lamp: amber and breathing on an alert, lit while the window is open.
	local alert = alerting[button]
	if not alert and type(button.NotificationOverlay) == 'table' and button.NotificationOverlay.IsShown then
		alert = button.NotificationOverlay:IsShown()
	end
	if not alert and button.FlashBorder and button.FlashBorder.IsShown then alert = button.FlashBorder:IsShown() end
	local open = not isBag and button.GetButtonState and button:GetButtonState() == 'PUSHED'
	local lit = glyphs and not isBag and (alert or open) and true or false
	Kit:SetLed(key.lamp, lit, alert and 'amber' or nil)
	Kit:ShowLed(key.lamp, lit)
	if Kit.Breathe then
		if lit and alert and not key.breathing then
			key.breathing = true
			Kit:Breathe(key.lamp, true, {period = 1.4, low = 0.25})
		elseif key.breathing and not (lit and alert) then
			key.breathing = nil
			Kit:Breathe(key.lamp, false)
		end
	end
end

function RepaintMenu()
	for button in pairs(menuKeys) do UI:Safe(PaintMenuButton, button) end
end

local function DressMenuButton(button)
	if menuKeys[button] then return end
	local key = CreateFrame('Frame', nil, button)
	key:SetPoint('TOPLEFT', -1, 1)
	key:SetPoint('BOTTOMRIGHT', 1, -1)
	key:SetFrameLevel(max(button:GetFrameLevel() - 1, 0))
	key:EnableMouse(false)
	key.skin = Kit:Skin(key, Sprites()[1], 'BACKGROUND', 0)
	key.skin.kitMaxCorner = 6
	if HW.On() then
		key.slotRing = HW.Slot(key, key)
		HW.ShowSlot(key.slotRing, true)
	end
	menuKeys[button] = key
	local glyph = GLYPH_OF[button:GetName() or '']
	if glyph then
		local index = MENU_INDEX[glyph]
		local column, row = index % 8, floor(index / 8)
		-- The glyph sits above the game's (faded) art, so it goes on a level of its own.
		key.top = CreateFrame('Frame', nil, button)
		key.top:SetAllPoints(key)
		key.top:SetFrameLevel(button:GetFrameLevel() + 2)
		key.top:EnableMouse(false)
		key.glyph = key.top:CreateTexture(nil, 'OVERLAY', nil, 1)
		key.glyph:SetTexture(Kit.media..'icons-menu.tga')
		key.glyph:SetTexCoord(column / 8, (column + 1) / 8, row / 4, (row + 1) / 4)
		key.glyph:SetPoint('CENTER', key, 'CENTER', 0, 0)
		key.lamp = Kit:Led(key.top, 4, false)
		key.lamp:SetPoint('TOPRIGHT', key, 'TOPRIGHT', -3, -3)
		Kit:ShowLed(key.lamp, false)
		button:HookScript('OnEnter', function(self) UI:Safe(PaintMenuButton, self) end)
		button:HookScript('OnLeave', function(self) UI:Safe(PaintMenuButton, self) end)
		button:HookScript('OnEnable', function(self) UI:Safe(PaintMenuButton, self) end)
		button:HookScript('OnDisable', function(self) UI:Safe(PaintMenuButton, self) end)
		if button.SetButtonState then
			hooksecurefunc(button, 'SetButtonState', function(self) UI:Safe(PaintMenuButton, self) end)
		end
		local overlay = button.NotificationOverlay
		if type(overlay) == 'table' and overlay.HookScript then
			overlay:HookScript('OnShow', function() UI:Safe(PaintMenuButton, button) end)
			overlay:HookScript('OnHide', function() UI:Safe(PaintMenuButton, button) end)
		end
	end
	local bagName = button:GetName()
	if bagName and (BAG_ID[bagName] ~= nil or bagName == 'KeyRingButton') then
		-- Bag slots: the bag's icon sits in a black window inset on the key,
		-- cropped, like an action key's.
		local icon = BagIcon(button)
		key.window = key:CreateTexture(nil, 'ARTWORK', nil, 1)
		key.window:SetColorTexture(0, 0, 0, 0.9)
		key.window:SetPoint('TOPLEFT', key, 'TOPLEFT', 4, -4)
		key.window:SetPoint('BOTTOMRIGHT', key, 'BOTTOMRIGHT', -4, 4)
		key.window:Hide()
		if icon then
			icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
			icon:ClearAllPoints()
			icon:SetPoint('TOPLEFT', key.window, 'TOPLEFT', 1, -1)
			icon:SetPoint('BOTTOMRIGHT', key.window, 'BOTTOMRIGHT', -1, 1)
		end
	end
	UI:Safe(PaintMenuButton, button)
end

-- The game flashes a micro button to ask for attention.
local function WatchAlerts()
	local clickHooked = setmetatable({}, {__mode = 'k'})
	local function Set(button, on)
		if not menuKeys[button] then return end
		-- A pulse on a disabled button never flashes; one that times out never
		-- calls Stop, so a click on the button also clears it.
		if on and button.IsEnabled and not button:IsEnabled() then on = false end
		alerting[button] = on or nil
		if on and not clickHooked[button] and button.HasScript and button:HasScript('OnClick') then
			clickHooked[button] = true
			button:HookScript('OnClick', function(self)
				if alerting[self] then alerting[self] = nil; UI:Safe(PaintMenuButton, self) end
			end)
		end
		UI:Safe(PaintMenuButton, button)
	end
	if type(_G.MicroButtonPulse) == 'function' then
		hooksecurefunc('MicroButtonPulse', function(button) Set(button, true) end)
	end
	if type(_G.MicroButtonPulseStop) == 'function' then
		hooksecurefunc('MicroButtonPulseStop', function(button) Set(button, false) end)
	end
end

local laying
-- The game's own bag bar and micro menu code re-anchors these buttons now and
-- then (after a bag change, a layout pass); whenever one is moved off our
-- device or handed another parent, put the menu back together a frame later.
local guarded, pendingLayout = setmetatable({}, {__mode = 'k'}), false
local function Relayout()
	if pendingLayout then return end
	pendingLayout = true
	C_Timer.After(0, function()
		pendingLayout = false
		UI:Safe(LayoutMenu)
	end)
end
local function Guard(button)
	if guarded[button] then return end
	guarded[button] = true
	hooksecurefunc(button, 'SetPoint', function(self)
		if laying then return end
		local _, relative = self:GetPoint(1)
		if relative ~= menu then Relayout() end
	end)
	hooksecurefunc(button, 'SetParent', function(_, parent)
		if not laying and parent ~= menu then Relayout() end
	end)
end
-- Two small devices: the menu (micro buttons) and the bags (bag slots), each
-- with its own mover, key size, scale, orientation, columns, glyph size,
-- housing, mouseover fade and buttons to leave out. A button left out is
-- faded and loses the mouse (the game may show it again; it stays invisible).
local MENU_PAD, MENU_GAP = 6, 3
local bagsDevice
local hoverHooked = setmetatable({}, {__mode = 'k'})
local GROUPS = {menu = MICRO, bags = BAGS}

local function Opt(group, field) return DB()[group..field] end
-- Spellbook and talents come as one combined key (Retail) or two separate ones
-- (Forever), and the client builds all three. Only the ones its own micro menu
-- lays out belong on ours; asked of the menu once, after it has loaded.
local Unlisted
do
local SPELL_KEYS = {PlayerSpellsMicroButton = true, SpellbookMicroButton = true, TalentMicroButton = true}
local spellKeysListed
function Unlisted(name)
	if not SPELL_KEYS[name] then return false end
	if spellKeysListed == nil then
		local micro = _G.MicroMenu
		if type(micro) ~= 'table' or Forbidden(micro) or type(micro.GenerateButtonInfos) ~= 'function' then return false end
		spellKeysListed = false
		local ok, infos = pcall(micro.GenerateButtonInfos, micro)
		if ok and type(infos) == 'table' then
			local listed = {}
			for _, info in ipairs(infos) do
				local button = type(info) == 'table' and info.button
				local buttonName = type(button) == 'table' and button.GetName and button:GetName()
				if type(buttonName) == 'string' then listed[buttonName] = true end
			end
			if next(listed) then spellKeysListed = listed end
		end
	end
	return spellKeysListed and not spellKeysListed[name] or false
end
end
Deck.MenuUnlisted = Unlisted

local function LeftOut(group, name)
	if group == 'menu' and Unlisted(name) then return true end
	local list = Opt(group, 'Hide')
	return type(list) == 'table' and list[name] and true or false
end

-- Mouseover fade: the device shows while the mouse is over it or a key on it.
local function FadeDevice(device)
	if not device then return end
	local group = device.group
	local target = 1
	if Opt(group, 'Fade') and not device.hovered then target = 0.15 end
	if device.faded ~= target then
		device.faded = target
		Kit:FadeTo(device, target, 'FAST')
	end
end

local function Hover(device, on)
	if on then device.hovered = true; return FadeDevice(device) end
	C_Timer.After(0.15, function()
		device.hovered = device:IsMouseOver() and true or false
		FadeDevice(device)
	end)
end

local function HookHover(button, device)
	if hoverHooked[button] then return end
	hoverHooked[button] = true
	button:HookScript('OnEnter', function() Hover(device, true) end)
	button:HookScript('OnLeave', function() Hover(device, false) end)
end

-- A group's buttons, in order: the known names, then any other micro button
-- this client adds to its micro menu, then `extra` (the key ring).
local function Names(group, extra)
	local list, seen = {}, {}
	for _, name in ipairs(GROUPS[group]) do list[#list + 1] = name; seen[name] = true end
	local micro = _G.MicroMenu
	if group == 'menu' and type(micro) == 'table' and micro.GetChildren and not Forbidden(micro) then
		for _, child in ipairs({micro:GetChildren()}) do
			local name = child.GetName and child:GetName()
			if name and not seen[name] and name:find('MicroButton$') and child.IsObjectType and child:IsObjectType('Button') then
				list[#list + 1] = name
				seen[name] = true
			end
		end
	end
	if extra then list[#list + 1] = extra end
	return list
end

-- The layout a group uses: 'line', 'column', 'grid', 'balanced' or 'console'
-- (inside the console; only while there is one).
local function LayoutOf(group)
	local layout = Opt(group, 'Layout') or 'line'
	if layout == 'console' and not console then layout = 'line' end
	return layout
end
Deck.MenuLayoutOf = LayoutOf

-- Across and down for `count` keys. Balanced picks the most square grid whose
-- lines are all full (wider than tall); with none (a prime count), the most
-- square grid, its last line centred.
local function Shape(group, count)
	local layout = LayoutOf(group)
	if count <= 0 then return 1, 1 end
	if layout == 'column' then return 1, count end
	if layout == 'grid' then
		local columns = floor(tonumber(Opt(group, 'Columns')) or 0)
		local across = columns > 0 and min(columns, count) or count
		return across, math.ceil(count / across)
	end
	if layout == 'balanced' then
		local best
		for across = 2, count - 1 do
			local lines = count / across
			if lines == floor(lines) and across >= lines and across / lines <= 4 then
				if not best or math.abs(across - lines) < math.abs(best - count / best) then best = across end
			end
		end
		if not best then best = math.ceil(math.sqrt(count * 2)) end
		best = min(best, count)
		return best, math.ceil(count / best)
	end
	return count, 1
end

-- Bring a group's buttons onto `parent` at `size`; returns the ones to show.
local function Collect(group, extra, parent, size, device)
	local shown = {}
	local names = Names(group, extra)
	-- Blizzard's micro menu lays itself out again whenever a shown button leaves
	-- it, and then reads its first and last buttons' centres. A hidden button it
	-- never placed (Forever's Help key) has no centre and its code errors. Such
	-- buttons go first: a hidden button changing parent fires no OnShow/OnHide,
	-- so no layout runs, and by the time a shown one leaves they are gone.
	if group == 'menu' then
		for _, name in ipairs(names) do
			local button = _G[name]
			if button and not Forbidden(button) and button:GetParent() ~= parent
				and (not button:IsShown() or button:GetCenter() == nil) then
				button:SetParent(parent)
			end
		end
	end
	for _, name in ipairs(names) do
		local button = _G[name]
		if button and not Forbidden(button) then
			Guard(button)
			if button:GetParent() ~= parent then button:SetParent(parent) end
			button:SetSize(size, size)
			DressMenuButton(button)
			if device then HookHover(button, device) end
			if group == 'bags' and name ~= 'KeyRingButton' then button:Show() end
			if LeftOut(group, name) then
				-- Left out: faded, no mouse, and no gap where it was.
				button:SetAlpha(0)
				button:EnableMouse(false)
				button:ClearAllPoints()
				button:SetPoint('CENTER', parent, 'CENTER')
			else
				button:SetAlpha(1)
				button:EnableMouse(true)
				if button:IsShown() then shown[#shown + 1] = button end
			end
		end
	end
	return shown
end

-- Keys in a grid from (x, y), `across` to a line; a short last line is centred.
local function Place(shown, parent, x, y, size, gap, across, vertical)
	local count = #shown
	local lines = math.ceil(count / max(across, 1))
	for index, button in ipairs(shown) do
		local line, place = floor((index - 1) / across), (index - 1) % across
		local inLine = (line == lines - 1) and (count - line * across) or across
		local shift = (across - inLine) * (size + gap) / 2
		local px, py
		if vertical then px, py = line * (size + gap), place * (size + gap) + shift
		else px, py = place * (size + gap) + shift, line * (size + gap) end
		button:ClearAllPoints()
		button:SetPoint('TOPLEFT', parent, 'TOPLEFT', x + px, -(y + py))
	end
end

local function GroupSpacing(group) return Kit:Clamp(floor(tonumber(Opt(group, 'Spacing')) or MENU_GAP), 0, 12) end

-- Lay one group on its own device.
local function Lay(device, group, extra)
	local integrated = LayoutOf(group) == 'console'
	local enabled = Opt(group, 'Enable') ~= false
	if integrated then
		device:Hide()
		return
	end
	local size = Kit:Clamp(floor(tonumber(Opt(group, 'KeySize')) or 22), 16, 40)
	local gap = GroupSpacing(group)
	local shown = Collect(group, extra, device, size, device)
	local layout = LayoutOf(group)
	local across, lines = Shape(group, #shown)
	local vertical = layout == 'column'
	if vertical then across, lines = 1, max(#shown, 1) end
	if vertical then
		-- One column: the keys run down it.
		for index, button in ipairs(shown) do
			button:ClearAllPoints()
			button:SetPoint('TOPLEFT', device, 'TOPLEFT', MENU_PAD, -MENU_PAD - (index - 1) * (size + gap))
		end
	else
		Place(shown, device, MENU_PAD, MENU_PAD, size, gap, across, false)
	end
	device:SetSize(MENU_PAD * 2 + max(across, 1) * size + max(across - 1, 0) * gap,
		MENU_PAD * 2 + max(lines, 1) * size + max(lines - 1, 0) * gap)
	local housing = Opt(group, 'Housing') ~= false and DB().housing ~= false
	if device.shell then device.shell:SetShown(housing) end
	device:SetShown(enabled)
	-- Only a new scale re-places the device (its mover keeps the spot).
	local scale = Kit:Clamp(tonumber(Opt(group, 'Scale')) or 1, 0.5, 1.5)
	if device.baseScale ~= scale then
		device.baseScale = scale
		UI:SetMoverBaseScale(device.moverKey, scale, device)
	end
	FadeDevice(device)
end

-- The console strip: the groups set to 'console', in one line, menu then bags.
local STRIP_GROUP_GAP = 10
local function Integrated()
	local groups = {}
	for _, group in ipairs({'menu', 'bags'}) do
		if Opt(group, 'Enable') ~= false and LayoutOf(group) == 'console' then groups[#groups + 1] = group end
	end
	return groups
end

-- How many keys the strip will hold (for the console's layout, before placing).
local function StripCount(group, extra)
	local count = 0
	for _, name in ipairs(Names(group, extra)) do
		local button = _G[name]
		if button and not Forbidden(button) and not LeftOut(group, name)
			and ((group == 'bags' and name ~= 'KeyRingButton') or button:IsShown()) then count = count + 1 end
	end
	return count
end

-- The strip's width and height at `size` keys (0, 0 without one): one line,
-- or with `columns` a grid of every key (menu then bags), evenly spaced.
function Deck.MenuStrip(size, columns)
	if columns then
		local total = 0
		for _, group in ipairs(Integrated()) do total = total + StripCount(group, group == 'bags' and 'KeyRingButton' or nil) end
		if total == 0 then return 0, 0, 0 end
		local gap = GroupSpacing('menu')
		local across = Kit:Clamp(floor(columns), 1, total)
		local lines = math.ceil(total / across)
		return across * size + (across - 1) * gap, lines * size + (lines - 1) * gap, total
	end
	local width, total = 0, 0
	for index, group in ipairs(Integrated()) do
		local count = StripCount(group, group == 'bags' and 'KeyRingButton' or nil)
		if count > 0 then
			if total > 0 then width = width + STRIP_GROUP_GAP end
			width = width + count * size + (count - 1) * GroupSpacing(group)
			total = total + count
		end
	end
	if total == 0 then return 0, 0, 0 end
	return width, size, total
end

-- Edge of the console the strip runs along: 'header' or 'bottom'.
function Deck.MenuEdge() return DB().menuEdge == 'header' and 'header' or 'bottom' end

-- Where the header strip starts: centred between the console's name and its
-- readouts (`last`, the leftmost of them), or nil when it doesn't fit there.
function Deck.HeaderStripX(parent, last, width)
	local left, title = parent:GetLeft(), parent.title
	if not (left and title and last and last.GetLeft) then return nil end
	local titleLeft, readLeft = title:GetLeft(), last:GetLeft()
	if not titleLeft or not readLeft then return nil end
	local name = title.GetUnboundedStringWidth and title:GetUnboundedStringWidth() or title:GetStringWidth()
	local from, to = titleLeft - left + (name or 0) + 12, readLeft - left - 12
	if to - from < width then return nil end
	return UI.Pixel.Snap(parent, (from + to) / 2 - width / 2)
end

local function LayStrip()
	local strip = console and console.menuStrip
	if not strip then return 0 end
	local size = console.menuStripKey or 18
	local x, total = 0, 0
	-- A grid (set in the body by the console editor): every key in order, evenly spaced.
	local columns = console.menuStripColumns
	if columns then
		local all = {}
		for _, group in ipairs(Integrated()) do
			for _, button in ipairs(Collect(group, group == 'bags' and 'KeyRingButton' or nil, strip, size)) do all[#all + 1] = button end
		end
		Place(all, strip, 0, 0, size, GroupSpacing('menu'), Kit:Clamp(floor(columns), 1, max(#all, 1)), false)
		return #all
	end
	for _, group in ipairs(Integrated()) do
		local shown = Collect(group, group == 'bags' and 'KeyRingButton' or nil, strip, size)
		if #shown > 0 then
			if total > 0 then x = x + STRIP_GROUP_GAP end
			local gap = GroupSpacing(group)
			for index, button in ipairs(shown) do
				button:ClearAllPoints()
				button:SetPoint('LEFT', strip, 'LEFT', x + (index - 1) * (size + gap), 0)
			end
			x = x + #shown * size + (#shown - 1) * gap
			total = total + #shown
		end
	end
	return total
end

function LayoutMenu()
	if not menu or laying then return end
	laying = true
	local total
	local ok, problem = pcall(function()
		Lay(menu, 'menu')
		if bagsDevice then Lay(bagsDevice, 'bags', 'KeyRingButton') end
		total = LayStrip()
	end)
	laying = nil
	if not ok then error(problem, 0) end
	-- The strip holds more or fewer keys than the console made room for: lay it out again.
	if console and console.menuStrip and not console.laying and total ~= (console.menuStripCount or 0) then
		UI:Safe(LayoutConsole)
	end
	-- The game re-sets its micro button art as it updates them; fade it again.
	RepaintMenu()
end
Deck.LayoutMenu = function() if menu then UI:Safe(LayoutMenu) end end

local function QueueMenu() C_Timer.After(0, function() UI:Safe(LayoutMenu) end) end

local function MenuDevice(name, group, moverKey)
	local device = Device(name, '', '', {header = false, radius = 8, level = 6})
	device.group, device.moverKey = group, moverKey
	device:EnableMouse(true)
	device:SetScript('OnEnter', function(self) Hover(self, true) end)
	device:SetScript('OnLeave', function(self) Hover(self, false) end)
	device:SetScale(1)
	return device
end

function BuildMenu()
	menu = MenuDevice('JiberishSpec01Menu', 'menu', 'ab.menu')
	bagsDevice = MenuDevice('JiberishSpec01Bags', 'bags', 'ab.bags')
	LayoutMenu()
	-- The menu in the bottom-right corner, the bags just above it: out of the
	-- console's way on every screen.
	local menuHeight = menu:GetHeight() * menu:GetScale()
	UI:RegisterMover(menu, 'ab.menu', 'Menu', {'BOTTOMRIGHT', -12, 12})
	UI:RegisterMover(bagsDevice, 'ab.bags', 'Bags', {'BOTTOMRIGHT', -12, 12 + floor(menuHeight + 6)})
	-- Blizzard re-lays its micro menu and bag bar now and then; take the buttons back each time.
	if _G.UpdateMicroButtons then hooksecurefunc('UpdateMicroButtons', QueueMenu) end
	for _, owner in ipairs({_G.MicroMenu, _G.BagsBar}) do
		if owner and owner.Layout then hooksecurefunc(owner, 'Layout', QueueMenu) end
	end
	-- The micro menu's container is an Edit Mode system: it keeps its parent and
	-- is only faded (its buttons live in our device now). The bag bar is parked,
	-- as ElvUI does.
	local container = _G.MicroMenuContainer
	if container and not Forbidden(container) then container:SetAlpha(0) end
	UI:Retire(_G.BagsBar, true)
	local performance = _G.MainMenuMicroButton and (_G.MainMenuMicroButton.PerformanceIndicator or _G.MainMenuMicroButton.MainMenuBarPerformanceBar)
	Fade(performance)
	local micro = _G.MicroMenu
	if micro then Fade(micro.BorderArt); Fade(micro.BackgroundArt) end
	-- Glyph lamps and empty bag slots.
	WatchAlerts()
	local bagEvents = CreateFrame('Frame')
	for _, event in ipairs({'BAG_CONTAINER_UPDATE', 'PLAYER_EQUIPMENT_CHANGED', 'BAG_UPDATE_DELAYED'}) do
		pcall(bagEvents.RegisterEvent, bagEvents, event)
	end
	bagEvents:SetScript('OnEvent', function()
		for name in pairs(BAG_ID) do
			local button = _G[name]
			if button and menuKeys[button] then UI:Safe(PaintMenuButton, button) end
		end
	end)
end

-- The hub's rows to leave buttons out, one per button this client has.
local LABELS = {CharacterMicroButton = 'Character', SpellbookMicroButton = 'Spellbook', PlayerSpellsMicroButton = 'Talents and spells',
	ProfessionMicroButton = 'Professions', TalentMicroButton = 'Talents', AchievementMicroButton = 'Achievements',
	LegacyMicroButton = 'Legacy', QuestLogMicroButton = 'Quest log', GuildMicroButton = 'Guild', SocialsMicroButton = 'Social',
	LFDMicroButton = 'Group finder', LFGMicroButton = 'Group finder', EJMicroButton = 'Adventure guide',
	CollectionsMicroButton = 'Collections', MainMenuMicroButton = 'Game menu', HelpMicroButton = 'Help', StoreMicroButton = 'Shop',
	HousingMicroButton = 'Housing', WorldMapMicroButton = 'World map', PVPMicroButton = 'PvP',
	MainMenuBarBackpackButton = 'Backpack', CharacterBag0Slot = 'Bag 1', CharacterBag1Slot = 'Bag 2', CharacterBag2Slot = 'Bag 3',
	CharacterBag3Slot = 'Bag 4', CharacterReagentBag0Slot = 'Reagent bag', KeyRingButton = 'Key ring'}
function Deck.ButtonRows(group)
	local rows = {}
	local names = {}
	for _, name in ipairs(GROUPS[group]) do names[#names + 1] = name end
	if group == 'bags' then names[#names + 1] = 'KeyRingButton' end
	for _, name in ipairs(names) do
		rows[#rows + 1] = {'switch', LABELS[name] or name, 'actionbars.'..group..'Hide', since = '0.5.1',
			get = function() return not LeftOut(group, name) end,
			set = function(value)
				local list = DB()[group..'Hide']
				if type(list) ~= 'table' then list = {}; DB()[group..'Hide'] = list end
				list[name] = (not value) or nil
			end,
			hidden = function() return _G[name] == nil or (group == 'menu' and Unlisted(name)) end}
	end
	return rows
end

end)()
-- Extra ability and zone ability ------------------------------------------------------------
-- Blizzard's own buttons keep working; their style frames go, they sit on a key,
-- and our holder (a mover) carries them.
local function BuildExtra()
	local holder = CreateFrame('Frame', 'JiberishSpec01ExtraHolder', UIParent)
	holder:SetSize(60, 60)
	UI:RegisterMover(holder, 'ab.extra', 'Extra ability', {'BOTTOM', 0, 300})
	local zoneHolder = CreateFrame('Frame', 'JiberishSpec01ZoneHolder', UIParent)
	zoneHolder:SetSize(60, 60)
	UI:RegisterMover(zoneHolder, 'ab.zone', 'Zone ability', {'BOTTOM', -90, 300})
	local function Carry(frame, target)
		if not frame or Forbidden(frame) then return end
		local function Place()
			if InCombatLockdown() then return UI:AfterCombat(Place, 'ab.carry.'..(frame:GetName() or '')) end
			if frame:GetParent() ~= target then frame:SetParent(target) end
			local _, relative = frame:GetPoint(1)
			if relative ~= target then
				frame:ClearAllPoints()
				frame:SetPoint('CENTER', target, 'CENTER')
			end
		end
		Place()
		-- Its container re-lays it from time to time; put it back a frame later.
		local function Queue() C_Timer.After(0, function() UI:Safe(Place) end) end
		hooksecurefunc(frame, 'SetPoint', function(self)
			local _, relative = self:GetPoint(1)
			if relative ~= target then Queue() end
		end)
		hooksecurefunc(frame, 'SetParent', function(self, parent) if parent ~= target then Queue() end end)
	end
	Carry(_G.ExtraActionBarFrame, holder)
	Carry(_G.ZoneAbilityFrame, zoneHolder)
	local extra = _G.ExtraActionButton1
	if extra and not Forbidden(extra) then
		Fade(extra.style)
		-- Hardware: a big round key in a round hole.
		Dress(extra, HW.On() and 52 or 48, true)
	end
	local zone = _G.ZoneAbilityFrame
	if zone then
		Fade(zone.Style)
		-- Zone abilities come and go from a pool; dress each one as it shows,
		-- out of combat (they are sized here).
		local container = zone.SpellButtonContainer
		local function DressZone()
			if not HW.On() or not (container and container.EnumerateActive) then return end
			if InCombatLockdown() then return UI:AfterCombat(DressZone, 'ab.zonekeys') end
			for button in container:EnumerateActive() do
				if not Forbidden(button) and not dressed[button] then Dress(button, 52, true) end
			end
		end
		if type(zone.UpdateDisplayedZoneAbilities) == 'function' then
			hooksecurefunc(zone, 'UpdateDisplayedZoneAbilities', function() C_Timer.After(0, function() UI:Safe(DressZone) end) end)
		end
		UI:Safe(DressZone)
	end
end

-- Blizzard's bars ----------------------------------------------------------------------
local function RetireBlizzard()
	-- Keep only what the extra action button needs from the bar controllers, as ElvUI does.
	local controller = _G.ActionBarController
	if controller and not Forbidden(controller) then
		controller:UnregisterAllEvents()
		controller:RegisterEvent('SETTINGS_LOADED')
		pcall(controller.RegisterEvent, controller, 'UPDATE_EXTRA_ACTIONBAR')
	end
	local actionEvents = _G.ActionBarActionEventsFrame
	if actionEvents and not Forbidden(actionEvents) then actionEvents:UnregisterAllEvents() end
	local events = _G.ActionBarButtonEventsFrame
	if events and not Forbidden(events) then
		events:UnregisterAllEvents()
		events:RegisterEvent('ACTIONBAR_SLOT_CHANGED')
		events:RegisterEvent('ACTIONBAR_UPDATE_COOLDOWN')
		if WOW_PROJECT_ID and WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE then pcall(events.RegisterEvent, events, 'PLAYER_ENTERING_WORLD') end
	end
	for _, prefix in ipairs(RETIRED_BUTTONS) do
		for index = 1, 12 do
			local button = _G[prefix..index]
			if button and not Forbidden(button) then
				button:UnregisterAllEvents()
				button:SetAttribute('statehidden', true)
				button:Hide()
			end
		end
	end
	for _, name in ipairs(RETIRED_BARS) do UI:Retire(_G[name]) end
	-- The vehicle leave button is an Edit Mode system: never reparented, only
	-- silenced and hidden (the console has its own Leave key).
	local leave = _G.MainMenuBarVehicleLeaveButton
	if leave and not Forbidden(leave) then
		leave:UnregisterAllEvents()
		leave:Hide()
		leave:SetAlpha(0)
	end
	-- Experience and reputation are the console's own meter now.
	if DB().xpbar then
		-- Only the manager: the two bar containers are Edit Mode systems that call
		-- their parent's methods, so they must stay its children (as ElvUI does).
		UI:Retire(_G.StatusTrackingBarManager)
	end
end

-- Events ---------------------------------------------------------------------------------
local dirty, queued = {}, false
local function Flush()
	queued = false
	local work = dirty
	dirty = {}
	if work.all then ForKeys(UpdateKey); RefreshDressed()
	else
		if work.cooldown then ForKeys(UpdateCooldown) end
		if work.state then ForKeys(UpdateState); RefreshDressed() end
		if work.usable then ForKeys(UpdateUsable) end
		if work.range then ForKeys(UpdateRange) end
	end
	if work.pet then UI:Safe(UpdatePet); UI:Safe(PlacePetKeys) end
	if work.stance then UI:Safe(UpdateStance) end
	if work.stanceLayout then UI:Safe(LayoutStance) end
	if work.xp then UI:Safe(UpdateXP) end
	if work.leave then UI:Safe(UpdateLeave) end
	if work.cvars then UI:Safe(ApplyCVars) end
	if work.menu then UI:Safe(LayoutMenu) end
	if work.layout then UI:Safe(LayoutConsole) end
end
local function Queue(what)
	dirty[what] = true
	if queued then return end
	queued = true
	C_Timer.After(0, Flush)
end

local EVENTS = {
	ACTIONBAR_UPDATE_COOLDOWN = 'cooldown', LOSS_OF_CONTROL_ADDED = 'cooldown', LOSS_OF_CONTROL_UPDATE = 'cooldown',
	SPELL_UPDATE_CHARGES = 'cooldown', SPELL_UPDATE_COOLDOWN = 'cooldown',
	ACTIONBAR_UPDATE_STATE = 'state', START_AUTOREPEAT_SPELL = 'state', STOP_AUTOREPEAT_SPELL = 'state', PLAYER_ENTER_COMBAT = 'state',
	PLAYER_LEAVE_COMBAT = 'state', TRADE_SKILL_SHOW = 'state', TRADE_SKILL_CLOSE = 'state', ARCHAEOLOGY_CLOSED = 'state',
	ACTIONBAR_UPDATE_USABLE = 'usable', SPELL_UPDATE_USABLE = 'usable',
	PLAYER_ENTERING_WORLD = 'all', SPELLS_CHANGED = 'all', UPDATE_BONUS_ACTIONBAR = 'all',
	UPDATE_VEHICLE_ACTIONBAR = 'all', UPDATE_OVERRIDE_ACTIONBAR = 'all', ACTIONBAR_PAGE_CHANGED = 'all', SPELL_UPDATE_ICON = 'all',
	BAG_UPDATE_DELAYED = 'all', UPDATE_MACROS = 'all', PLAYER_MOUNT_DISPLAY_CHANGED = 'all', LEARNED_SPELL_IN_SKILL_LINE = 'all',
	PET_BAR_UPDATE = 'pet', PET_BAR_UPDATE_COOLDOWN = 'pet', PET_UI_UPDATE = 'pet', PLAYER_FARSIGHT_FOCUS_CHANGED = 'pet',
	UPDATE_SHAPESHIFT_USABLE = 'stance', UPDATE_SHAPESHIFT_COOLDOWN = 'stance', UPDATE_SHAPESHIFT_FORMS = 'stanceLayout',
	PLAYER_XP_UPDATE = 'xp', PLAYER_LEVEL_UP = 'xp', UPDATE_EXHAUSTION = 'xp', UPDATE_FACTION = 'xp', ENABLE_XP_GAIN = 'xp',
	DISABLE_XP_GAIN = 'xp',
	UPDATE_MULTI_CAST_ACTIONBAR = 'leave', VEHICLE_UPDATE = 'leave', UPDATE_POSSESS_BAR = 'leave', TAXIMAP_CLOSED = 'leave',
	CVAR_UPDATE = 'cvars', PLAYER_TARGET_CHANGED = 'usable',
}

local function OnEvent(_, event, ...)
	if event == 'ACTIONBAR_SLOT_CHANGED' then
		local slot = ...
		if not slot or slot == 0 or not bySlot[slot] then return Queue('all') end
		for key in pairs(bySlot[slot]) do UI:Safe(UpdateKey, key) end
	elseif event == 'ACTION_USABLE_CHANGED' then
		local changes = ...
		if type(changes) ~= 'table' then return Queue('usable') end
		for _, change in ipairs(changes) do
			local slotKeys = type(change) == 'table' and bySlot[change.slot]
			if slotKeys then for key in pairs(slotKeys) do UpdateUsable(key, change.usable, change.noMana) end end
		end
	elseif event == 'ACTION_RANGE_CHECK_UPDATE' then
		local slot, inRange, checksRange = ...
		local slotKeys = bySlot[slot]
		if slotKeys then for key in pairs(slotKeys) do UpdateRange(key, inRange, checksRange) end end
	elseif event == 'SPELL_ACTIVATION_OVERLAY_GLOW_SHOW' or event == 'SPELL_ACTIVATION_OVERLAY_GLOW_HIDE' then
		local spell = ...
		local on = event == 'SPELL_ACTIVATION_OVERLAY_GLOW_SHOW'
		for _, key in ipairs(keys) do
			if IsSecret(spell) then UpdateGlow(key) elseif key.spell == spell then SetGlow(key, on) end
		end
	elseif event == 'UPDATE_BINDINGS' then
		Bind()
	elseif event == 'PLAYER_REGEN_DISABLED' or event == 'PLAYER_REGEN_ENABLED' then
		-- The fight starts before lockdown does, so trust the event.
		inCombat = event == 'PLAYER_REGEN_DISABLED'
		if console and console.lamp then Kit:SetLed(console.lamp, inCombat) end
		UpdateFades()
	elseif event == 'ACTIONBAR_SHOWGRID' or event == 'ACTIONBAR_HIDEGRID' then
		dragging = event == 'ACTIONBAR_SHOWGRID'
		ForKeys(UpdateGrid)
	elseif event == 'UNIT_PET' or event == 'UNIT_FLAGS' then
		Queue('pet')
	elseif event == 'UPDATE_SHAPESHIFT_FORM' then
		Queue('all'); Queue('stance')
	elseif event == 'PLAYER_CONTROL_LOST' or event == 'PLAYER_CONTROL_GAINED' then
		Queue('pet'); Queue('leave')
	elseif event == 'PET_BATTLE_OPENING_START' then
		-- Pet battle abilities answer the number keys while a battle is on.
		if not InCombatLockdown() then ClearOverrideBindings(binder) end
		HideDocked(true)
	elseif event == 'PET_BATTLE_CLOSE' then
		Bind()
		HideDocked(false)
	elseif event == 'UNIT_ENTERED_VEHICLE' or event == 'UNIT_EXITED_VEHICLE' then
		Queue('leave'); Queue('state')
	elseif event == 'UNIT_INVENTORY_CHANGED' then
		Queue('all')
	elseif EVENTS[event] then
		Queue(EVENTS[event])
		-- The unit frames may have been built (or resized) after the console: lay it out again.
		if event == 'PLAYER_ENTERING_WORLD' then Queue('pet'); Queue('stanceLayout'); Queue('xp'); Queue('leave'); Queue('menu'); Queue('layout') end
		if event == 'PLAYER_TARGET_CHANGED' then Queue('range') end
	end
end

-- The console's deck --------------------------------------------------------------------
-- Everything around the keys that is read rather than pressed, and the keys
-- that open things:
--   * Meters along the base: experience, reputation or honor (or Auto: XP
--     while levelling, reputation at the cap), one or two stacked, as LED
--     dots, a flat bar with a lit edge, segments or a slim hairline, with
--     rested XP (and optionally the XP of quests ready to hand in) as lighter
--     overlays. Click to cycle the source, right-click for reputations.
--   * A stats strip above them: up to six small LCD readouts the player picks
--     (XP per hour, time to level, time played, session, rested, kills to
--     level, gold per hour, reputation, honor, ...).
--   * Function keys at the top of the side columns: mount, hearthstone, map,
--     spellbook, bags, drawer, move UI, calendar, ..., or a macro by name.
--     They are our own secure buttons, set up out of combat only.
--   * Small LCD panels in the header: zone and coordinates, gold, durability
--     and latency.
-- All values read here are plain or skipped: nothing secret is compared.
-- The deck runs inside a function of its own: its locals count against that
-- function's limit, not the main chunk's.
;(function()
local GetMoney, GetXPExhaustion, UnitXP, UnitXPMax, UnitLevel = GetMoney, GetXPExhaustion, UnitXP, UnitXPMax, UnitLevel
local ceil = math.ceil

local function Plain(value) if IsSecret(value) then return nil end return value end
local function Call(func, ...)
	if type(func) ~= 'function' then return nil end
	local ok, a, b, c, d, e = pcall(func, ...)
	if not ok then return nil end
	return Plain(a), Plain(b), Plain(c), Plain(d), Plain(e)
end

-- Formatting ------------------------------------------------------------------------------
local function Short(value)
	if not value then return '--' end
	if value >= 1e6 then return format('%.1fM', value / 1e6) end
	if value >= 1e4 then return format('%.0fK', value / 1e3) end
	if value >= 1e3 then return format('%.1fK', value / 1e3) end
	return format('%d', value)
end

local function Duration(seconds)
	if not seconds or seconds ~= seconds or seconds == math.huge or seconds < 0 then return '--' end
	seconds = floor(seconds)
	if seconds >= 86400 then return format('%dD %02dH', floor(seconds / 86400), floor(seconds % 86400 / 3600)) end
	if seconds >= 3600 then return format('%dH %02dM', floor(seconds / 3600), floor(seconds % 3600 / 60)) end
	if seconds >= 60 then return format('%dM %02dS', floor(seconds / 60), seconds % 60) end
	return format('%dS', seconds)
end

local function Gold(copper)
	if not copper then return '--' end
	local sign = copper < 0 and '-' or ''
	copper = math.abs(copper)
	local gold = floor(copper / 10000)
	if gold >= 1e6 then return format('%s%.1fMG', sign, gold / 1e6) end
	if gold >= 1e4 then return format('%s%.0fKG', sign, gold / 1e3) end
	if gold > 0 then return format('%s%dG', sign, gold) end
	return format('%s%dS', sign, floor(copper / 100))
end

-- Session numbers ---------------------------------------------------------------------------
local session = {start = GetTime(), xp = 0, questXP = 0, kills = 0}
local last = {}
local played = {}
local questUntil = 0

local function Level()
	local level = Plain(UnitLevel('player'))
	local cap = Call(GetMaxLevelForPlayerExpansion) or Plain(MAX_PLAYER_LEVEL) or level
	return level, cap
end

local function XP()
	local current, total = Plain(UnitXP('player')), Plain(UnitXPMax('player'))
	local disabled = Call(IsXPUserDisabled)
	local level, cap = Level()
	if not (current and total and level and cap) or total <= 0 then return nil end
	if level >= cap or disabled then return nil end
	return current, total, level
end

local function TrackXP()
	local current, total = Plain(UnitXP('player')), Plain(UnitXPMax('player'))
	local level = Plain(UnitLevel('player'))
	if not (current and total and level) then return end
	if last.xp and last.level then
		local gained
		if level == last.level then gained = current - last.xp
		elseif level > last.level then
			gained = (last.max - last.xp) + current
			-- A new level: its played time starts now.
			played.level, played.at = 0, GetTime()
		end
		if gained and gained > 0 then session.xp = session.xp + gained end
	end
	last.xp, last.max, last.level = current, total, level
end

local function Hours() return max((GetTime() - session.start) / 3600, 1 / 3600) end
local function Rate() return session.xp > 0 and session.xp / Hours() or nil end
local function Remaining()
	local current, total = XP()
	return current and (total - current) or nil
end
local function KillXP()
	local other = session.xp - session.questXP
	if session.kills <= 0 or other <= 0 then return nil end
	return other / session.kills
end

-- Time played: asked once, quietly. The chat frames are taken off the answer
-- while our request is out, so it prints nowhere; they get it back right after.
local quieted = {}
local function Quiet(on)
	if on then
		for index = 1, (NUM_CHAT_WINDOWS or 10) do
			local frame = _G['ChatFrame'..index]
			if frame and frame.IsEventRegistered and frame:IsEventRegistered('TIME_PLAYED_MSG') then
				frame:UnregisterEvent('TIME_PLAYED_MSG')
				quieted[#quieted + 1] = frame
			end
		end
	else
		for index, frame in ipairs(quieted) do
			frame:RegisterEvent('TIME_PLAYED_MSG')
			quieted[index] = nil
		end
	end
end

local function AskPlayed()
	if played.asked or not RequestTimePlayed then return end
	played.asked = true
	Quiet(true)
	pcall(RequestTimePlayed)
	-- Never hold the chat frames for long, answered or not.
	C_Timer.After(5, function() Quiet(false) end)
end

local function Played()
	if not played.total then return nil, nil end
	local since = GetTime() - played.at
	return played.total + since, played.level + since
end

-- Reputation and honor ------------------------------------------------------------------------
local function Reputation()
	local name, low, high, value, reaction, factionID
	local data = C_Reputation and C_Reputation.GetWatchedFactionData and Call(C_Reputation.GetWatchedFactionData)
	if type(data) == 'table' then
		name, reaction, factionID = Plain(data.name), Plain(data.reaction), Plain(data.factionID)
		low, high, value = Plain(data.currentReactionThreshold), Plain(data.nextReactionThreshold), Plain(data.currentStanding)
	elseif GetWatchedFactionInfo then
		name, reaction, low, high, value = Call(GetWatchedFactionInfo)
	end
	if not (name and low and high and value) then return nil end
	local standing = reaction and _G['FACTION_STANDING_LABEL'..reaction]
	-- Renown factions read their renown level and progress to the next one.
	if factionID and C_Reputation.IsMajorFaction and Call(C_Reputation.IsMajorFaction, factionID) and C_MajorFactions then
		local major = Call(C_MajorFactions.GetMajorFactionData, factionID)
		if type(major) == 'table' and Plain(major.renownLevelThreshold) and Plain(major.renownReputationEarned) then
			return {name = name, value = major.renownReputationEarned, max = max(major.renownLevelThreshold, 1),
				standing = format('Renown %d', Plain(major.renownLevel) or 0)}
		end
	end
	return {name = name, value = min(max(value - low, 0), max(high - low, 1)), max = max(high - low, 1),
		standing = type(standing) == 'string' and standing or ''}
end

local function Honor()
	if not (UnitHonor and UnitHonorMax) then return nil end
	local value, total, level = Call(UnitHonor, 'player'), Call(UnitHonorMax, 'player'), Call(UnitHonorLevel, 'player')
	if not (value and total) or total <= 0 then return nil end
	return {value = value, max = total, level = level}
end

-- The XP of quests in the log that are ready to hand in.
local function QuestPreview()
	if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and GetQuestLogRewardXP) then return 0 end
	local total = 0
	local count = Call(C_QuestLog.GetNumQuestLogEntries) or 0
	for index = 1, count do
		local info = Call(C_QuestLog.GetInfo, index)
		local id = type(info) == 'table' and not info.isHeader and Plain(info.questID)
		if id and Call(C_QuestLog.ReadyForTurnIn, id) then total = total + (Call(GetQuestLogRewardXP, id) or 0) end
	end
	return total
end

-- Stats readouts ------------------------------------------------------------------------------
-- Each: a printed label and a reader returning the LCD text and, when it has
-- something to say, the lamp's color.
local STATS = {
	level = {'Level', function()
		local current, total, level = XP()
		if current then return format('%d  %.1f%%', level, current / total * 100), 'lamp' end
		local plain = Level()
		return plain and format('%d  MAX', plain) or '--'
	end},
	xph = {'XP/hr', function()
		if not XP() then return 'MAX' end
		local rate = Rate()
		return rate and Short(rate) or '--', rate and 'green' or nil
	end},
	ttl = {'To level', function()
		local left, rate = Remaining(), Rate()
		if not left then return 'MAX' end
		return rate and Duration(left / rate * 3600) or '--', rate and 'lamp' or nil
	end},
	left = {'XP left', function()
		local left = Remaining()
		return left and Short(left) or 'MAX'
	end},
	kills = {'Kills to lv', function()
		local left, each = Remaining(), KillXP()
		if not left then return 'MAX' end
		return each and format('%d', ceil(left / each)) or '--', each and 'amber' or nil
	end},
	rested = {'Rested', function()
		local current, total = XP()
		local rested = Plain(Call(GetXPExhaustion))
		if not (current and rested) or rested <= 0 then return '0%' end
		return format('%d%%', floor(rested / total * 100 + 0.5)), 'blue'
	end},
	quests = {'Quest XP', function()
		if session.xp <= 0 then return '--' end
		return format('%d%%', floor(session.questXP / session.xp * 100 + 0.5)), 'green'
	end},
	played = {'Played', function()
		local total = Played()
		return Duration(total)
	end},
	levelTime = {'This level', function()
		local _, level = Played()
		return Duration(level)
	end},
	session = {'Session', function() return Duration(GetTime() - session.start), 'green' end},
	goldph = {'Gold/hr', function()
		local now = Plain(GetMoney())
		if not (now and session.money) then return '--' end
		local gained = now - session.money
		return Gold(gained / Hours()), gained > 0 and 'amber' or nil
	end},
	gold = {'Gold', function() return Gold(Plain(GetMoney())) end},
	rep = {'Rep', function()
		local rep = Reputation()
		if not rep then return '--' end
		return format('%s %d%%', strupper(strsub(rep.standing, 1, 8)), floor(rep.value / rep.max * 100)), 'green'
	end},
	honor = {'Honor', function()
		local honor = Honor()
		if not honor then return '--' end
		return format('%s %d%%', honor.level and tostring(honor.level) or '', floor(honor.value / honor.max * 100)), 'red'
	end},
	fps = {'FPS', function() return format('%d', floor((Call(GetFramerate) or 0) + 0.5)) end},
	clock = {'Clock', function() return date('%H:%M') end},
}
Deck.STAT_ITEMS = {{'none', 'None'}, {'xph', 'XP per hour'}, {'ttl', 'Time to level'}, {'left', 'XP left'},
	{'kills', 'Kills to level'}, {'rested', 'Rested XP'}, {'level', 'Level and %'}, {'quests', 'Quest share of XP'},
	{'levelTime', 'Played this level'}, {'played', 'Played in total'}, {'session', 'Session time'},
	{'goldph', 'Gold per hour'}, {'gold', 'Gold'}, {'rep', 'Reputation'}, {'honor', 'Honor'}, {'fps', 'Frame rate'},
	{'clock', 'Clock'}}
local STAT_SLOTS = 6

local function StatsWanted()
	local db = DB()
	if db.stats == false or db.statsStyle == 'hidden' then return false end
	for index = 1, STAT_SLOTS do
		local id = db['stat'..index]
		if id and STATS[id] then return true end
	end
	return false
end

-- Meters ------------------------------------------------------------------------------------
local SOURCES = {'auto', 'xp', 'rep', 'honor'}
Deck.SOURCE_ITEMS = {{'auto', 'Auto'}, {'xp', 'Experience'}, {'rep', 'Reputation'}, {'honor', 'Honor'}}
local DEFAULT_COLOR = {xp = 'lamp', rested = 'blue', rep = 'green', honor = 'red', preview = 'amber'}

local function MeterRGB(kind)
	local db = DB()
	if db.meterColors == 'custom' then
		local value = db[kind..'Color']
		if type(value) == 'table' then return ColorOf(value, 1, 1, 1) end
	end
	return Kit:RGB(DEFAULT_COLOR[kind] or 'lamp')
end

-- What a meter shows: the source asked for, resolved.
local function Resolve(source)
	if source == 'auto' or not source then
		if XP() then return 'xp' end
		if Reputation() then return 'rep' end
		if Honor() then return 'honor' end
		return 'xp'
	end
	return source
end

-- A meter's reading: value, max, legend, LCD text, color kind, tooltip lines,
-- rested and preview amounts (XP only).
local function Read(source)
	source = Resolve(source)
	if source == 'xp' then
		local current, total, level = XP()
		if not current then
			local plain = Level()
			return {value = 1, max = 1, legend = 'XP', text = 'MAX', kind = 'xp', dim = true,
				tip = {plain and format('Level %d (max)', plain) or 'Level max'}}
		end
		local rested = Plain(Call(GetXPExhaustion)) or 0
		local reading = {value = current, max = total, legend = 'XP', text = format('%4.1f%%', current / total * 100),
			kind = 'xp', rested = rested, level = level}
		reading.tip = {format('Level %d  %s / %s  (%.1f%%)', level, Short(current), Short(total), current / total * 100),
			format('%s to level', Short(total - current))}
		if rested > 0 then reading.tip[#reading.tip + 1] = format('Rested %s (%d%% of the level)', Short(rested), floor(rested / total * 100)) end
		local rate = Rate()
		if rate then reading.tip[#reading.tip + 1] = format('%s XP per hour, level in %s', Short(rate), Duration((total - current) / rate * 3600)) end
		if DB().questPreview then
			reading.preview = QuestPreview()
			if reading.preview > 0 then reading.tip[#reading.tip + 1] = format('Quests ready to hand in: %s XP', Short(reading.preview)) end
		end
		return reading
	elseif source == 'rep' then
		local rep = Reputation()
		if not rep then return {value = 0, max = 1, legend = 'Rep', text = '--', kind = 'rep', dim = true, tip = {'No reputation watched'}} end
		return {value = rep.value, max = rep.max, legend = 'Rep', text = format('%4.1f%%', rep.value / rep.max * 100), kind = 'rep',
			tip = {rep.name, format('%s  %s / %s', rep.standing, Short(rep.value), Short(rep.max))}}
	else
		local honor = Honor()
		if not honor then return {value = 0, max = 1, legend = 'Hon', text = '--', kind = 'honor', dim = true, tip = {'No honor'}} end
		return {value = honor.value, max = honor.max, legend = 'Hon', text = format('%4.1f%%', honor.value / honor.max * 100),
			kind = 'honor', tip = {format('Honor level %s', honor.level or '?'), format('%s / %s', Short(honor.value), Short(honor.max))}}
	end
end
Deck.Read = Read

local function MeterHeight()
	return DB().barStyle == 'slim' and 3 or XPHeight()
end

-- A style on a meter's bar: dots (perforated), flat with a lit edge,
-- segments, or a slim hairline.
local function Style(meter)
	local style = DB().barStyle or 'dots'
	local bar = meter.bar
	local onDark = Surface() == 'dark'
	if style == 'dots' then
		Kit:Perforate(bar, onDark and 'glass' or 'track', onDark and 'darkEdge' or nil)
		bar:SetStatusBarTexture([[Interface\Buttons\WHITE8X8]])
	else
		if bar.kitCover then bar.kitPerforated = false; bar.kitCover:Hide(); bar.kitUnder:Hide() end
		bar:SetStatusBarTexture(Kit.media..'bar-flat.tga')
	end
	local fill = bar:GetStatusBarTexture()
	if not meter.edge then
		meter.edge = bar:CreateTexture(nil, 'OVERLAY', nil, 2)
		meter.edge:SetColorTexture(1, 1, 1, 0.9)
		meter.edge:SetBlendMode('ADD')
		meter.seams = {}
	end
	meter.edge:ClearAllPoints()
	meter.edge:SetWidth(UI.Pixel and UI.Pixel.Px(bar, 1) or 1)
	meter.edge:SetPoint('TOP', fill, 'TOPRIGHT', 0, 0)
	meter.edge:SetPoint('BOTTOM', fill, 'BOTTOMRIGHT', 0, 0)
	meter.edge:SetShown(style == 'flat' or style == 'slim')
	-- Segments: hairline seams in the track's color across the fill.
	local width = bar:GetWidth()
	local count = (style == 'segments' and not IsSecret(width) and width and width > 0) and floor(width / 7) or 0
	local tr, tg, tb = Kit:RGB(onDark and 'glass' or 'track')
	for index = 1, max(count, #meter.seams) do
		local seam = meter.seams[index]
		if index <= count then
			if not seam then
				seam = bar:CreateTexture(nil, 'OVERLAY', nil, 1)
				meter.seams[index] = seam
			end
			seam:SetColorTexture(tr, tg, tb, 1)
			seam:ClearAllPoints()
			seam:SetSize(1, 1)
			seam:SetPoint('TOP', bar, 'TOPLEFT', index * width / (count + 1), 0)
			seam:SetPoint('BOTTOM', bar, 'BOTTOMLEFT', index * width / (count + 1), 0)
			seam:Show()
		elseif seam then
			seam:Hide()
		end
	end
	meter.shell:SetAlpha(style == 'slim' and 0.6 or 1)
	-- Slim: the fill takes the whole hairline, and the percent is printed in the
	-- numbers face at the end, with no LCD box round it.
	bar:ClearAllPoints()
	if style == 'slim' then
		bar:SetPoint('TOPLEFT', 0, 0)
		bar:SetPoint('BOTTOMRIGHT', 0, 0)
	else
		bar:SetPoint('TOPLEFT', 3, -2)
		bar:SetPoint('BOTTOMRIGHT', -3, 2)
	end
	local lcd = meter.lcd
	if lcd then
		local boxed = style ~= 'slim'
		if lcd.shell then lcd.shell:SetShown(boxed) end
		if lcd.inner then lcd.inner:SetShown(boxed) end
		Kit:Font(meter.percent, 8, nil, true, not boxed and 'numbers' or nil)
		Kit:Tint(meter.percent, boxed and 'lcdInk' or (onDark and 'darkInk' or 'ink'))
	end
end

-- Overlays from the fill's end: rested XP, quests ready.
local function Overlay(meter, key, from, amount, kind, alpha)
	local texture = meter[key]
	if not texture then
		texture = meter.bar:CreateTexture(nil, 'BACKGROUND', nil, key == 'restedFill' and 3 or 4)
		texture:SetColorTexture(1, 1, 1, 1)
		meter[key] = texture
	end
	local width = meter.bar:GetWidth()
	if not amount or amount <= 0 or IsSecret(width) or not width or width <= 0 then texture:Hide() return from end
	local to = min(from + amount, 1)
	if to <= from then texture:Hide() return from end
	local r, g, b = MeterRGB(kind)
	texture:SetVertexColor(r, g, b, alpha)
	texture:ClearAllPoints()
	texture:SetPoint('TOPLEFT', meter.bar, 'TOPLEFT', width * from, 0)
	texture:SetPoint('BOTTOMLEFT', meter.bar, 'BOTTOMLEFT', width * from, 0)
	texture:SetWidth(max(width * (to - from), 1))
	texture:Show()
	return to
end

-- Paint one meter from its source.
local function Paint(meter, source)
	local reading = Read(source)
	meter.reading = reading
	local bar = meter.bar
	bar:SetMinMaxValues(0, reading.max)
	bar:SetValue(reading.value, Smooth())
	local r, g, b = MeterRGB(reading.kind)
	if reading.dim then r, g, b = Kit:RGB('dim') end
	bar:SetStatusBarColor(r, g, b, 1)
	if meter.edge then meter.edge:SetVertexColor(min(r + 0.4, 1), min(g + 0.4, 1), min(b + 0.4, 1), 1) end
	local at = reading.max > 0 and reading.value / reading.max or 0
	local db = DB()
	at = Overlay(meter, 'restedFill', at, db.restedOverlay ~= false and reading.rested and reading.rested / reading.max, 'rested', 0.45)
	Overlay(meter, 'previewFill', at, reading.preview and reading.preview / reading.max, 'preview', 0.55)
	meter.tip = reading.tip
	HW.MeterText(meter, reading.legend, reading.text)
	return reading
end

-- Clicks: left cycles the source, right opens reputations.
local function Clicked(meter, button)
	if button == 'RightButton' then
		if ToggleCharacter then pcall(ToggleCharacter, 'ReputationFrame') end
		return
	end
	local field = meter.second and 'barSecond' or 'barSource'
	local current = DB()[field] or 'auto'
	local nextSource = SOURCES[1]
	for index, id in ipairs(SOURCES) do
		if id == current then nextSource = SOURCES[index % #SOURCES + 1] break end
	end
	DB()[field] = nextSource
	Kit:Play('tick', true)
	Deck.UpdateMeters()
	if GameTooltip:IsOwned(meter) and meter:GetScript('OnEnter') then meter:GetScript('OnEnter')(meter) end
end

-- Dress a meter track (BuildXP's) with clicks, the tooltip and its style.
function Deck.DressMeter(meter, second)
	meter.second = second
	meter:SetScript('OnEnter', function(self)
		GameTooltip:SetOwner(self, 'ANCHOR_TOP')
		local reading = self.reading
		GameTooltip:AddLine(reading and (reading.kind == 'xp' and 'Experience' or reading.kind == 'rep' and 'Reputation' or 'Honor') or 'Meter', 1, 1, 1)
		if self.tip then for _, line in ipairs(self.tip) do GameTooltip:AddLine(line, 0.85, 0.85, 0.82) end end
		GameTooltip:AddLine('Click: next source   Right-click: reputations', 0.55, 0.55, 0.52)
		GameTooltip:Show()
	end)
	meter:SetScript('OnMouseUp', function(self, button) UI:Safe(Clicked, self, button) end)
	meter.bar:HookScript('OnSizeChanged', function() UI:Safe(Style, meter) end)
	Style(meter)
end

-- Readout, meters and strip -----------------------------------------------------------------
local strips = {}

function Deck.UpdateMeters()
	if not xp then return end
	local db = DB()
	local readout = console and console.readout
	local reading
	if db.xpbar then
		reading = Paint(xp, db.barSource)
		xp:SetShown(true)
		if xp.secondMeter then
			local wanted = db.barSecond and db.barSecond ~= 'none'
			xp.secondMeter:SetShown(wanted and true or false)
			if wanted then Paint(xp.secondMeter, db.barSecond) end
		end
	else
		xp:Hide()
		if xp.secondMeter then xp.secondMeter:Hide() end
		reading = Read('xp')
	end
	if readout then
		local level = Level()
		local text
		if reading.kind == 'xp' and reading.level then text = format('LV %d  %4.1f%%', reading.level, reading.value / reading.max * 100)
		elseif reading.kind == 'rep' then text = format('LV %s  REP', level or '??')
		elseif reading.kind == 'honor' then text = format('LV %s  HON', level or '??')
		else text = level and format('LV %d  MAX', level) or 'LV ??' end
		readout:SetText(Readout(text))
	end
end

local function BuildStrip(parent)
	local strip = CreateFrame('Frame', nil, parent)
	strip.cells = {}
	local dark = Surface() == 'dark'
	for index = 1, STAT_SLOTS do
		local cell = CreateFrame('Frame', nil, strip)
		cell.led = Kit:Led(cell, 4, false)
		cell.legend = Kit:Label(cell, '', dark and 'darkDim' or 'dim', 7, true)
		cell.legend:SetWordWrap(false)
		cell.lcd = Kit:LCDPanel(cell, {radius = 3})
		cell.value = Kit:Text(cell.lcd, '', 'tiny', 'lcdInk', true)
		cell.value:SetPoint('RIGHT', -4, 0)
		cell.value:SetJustifyH('RIGHT')
		cell.value:SetWordWrap(false)
		-- Minimal text: the value printed in the numbers face, a hairline dot
		-- between readouts, no boxes.
		cell.plain = Kit:Text(cell, '', 8, dark and 'darkInk' or 'ink', true)
		Kit:Font(cell.plain, 8, nil, true, 'numbers')
		cell.plain:SetWordWrap(false)
		cell.dot = cell:CreateTexture(nil, 'ARTWORK')
		cell.dot:SetColorTexture(1, 1, 1, 1)
		cell.dot:SetSize(2, 2)
		Kit:Tint(cell.dot, dark and 'darkDim' or 'dim', 0.6)
		strip.cells[index] = cell
	end
	strips[#strips + 1] = strip
	return strip
end

local function TextStrip() return (DB().statsStyle or 'text') == 'text' end

function Deck.StripHeight()
	if not StatsWanted() then return 0 end
	if TextStrip() then return 10 end
	return DB().statsSize == 'comfortable' and 25 or 14
end

local function LayoutStrip(strip, width)
	local db = DB()
	local ids = {}
	for index = 1, STAT_SLOTS do
		local id = db['stat'..index]
		if id and STATS[id] then ids[#ids + 1] = id end
	end
	strip.ids = ids
	local count = #ids
	local text = TextStrip()
	local comfortable = not text and db.statsSize == 'comfortable'
	local height = text and 10 or (comfortable and 25 or 14)
	strip:SetHeight(height)
	local gap = 8
	local cellWidth = count > 0 and (width - gap * (count - 1)) / count or 0
	for index, cell in ipairs(strip.cells) do
		local id = ids[index]
		cell:SetShown(id ~= nil)
		if id then
			cell:ClearAllPoints()
			cell:SetPoint('TOPLEFT', strip, 'TOPLEFT', (index - 1) * (cellWidth + gap), 0)
			cell:SetSize(cellWidth, height)
			cell.legend:SetText(strupper(STATS[id][1]))
			cell.led:ClearAllPoints()
			cell.legend:ClearAllPoints()
			cell.lcd:ClearAllPoints()
			cell.plain:ClearAllPoints()
			cell.dot:ClearAllPoints()
			cell.led:SetShown(not text)
			cell.lcd:SetShown(not text)
			cell.plain:SetShown(text)
			cell.dot:SetShown(text and index > 1)
			if text then
				-- Legend and value meet at the cell's middle; a dot marks the cell's start.
				cell.legend:SetWidth(0)
				cell.legend:SetJustifyH('RIGHT')
				cell.legend:SetPoint('RIGHT', cell, 'CENTER', -3, 0)
				cell.plain:SetPoint('LEFT', cell, 'CENTER', 3, 0)
				cell.plain:SetJustifyH('LEFT')
				cell.dot:SetPoint('CENTER', cell, 'LEFT', -gap / 2, 0)
			elseif comfortable then
				-- Lamp and legend on a printed line, the LCD under them.
				cell.led:SetPoint('TOPLEFT', 1, -2)
				cell.legend:SetPoint('LEFT', cell.led, 'RIGHT', 4, 0)
				cell.legend:SetPoint('RIGHT', cell, 'RIGHT', 0, 0)
				cell.legend:SetJustifyH('LEFT')
				cell.lcd:SetPoint('BOTTOMLEFT')
				cell.lcd:SetPoint('BOTTOMRIGHT')
				cell.lcd:SetHeight(14)
			else
				-- One line: lamp, legend, LCD.
				cell.led:SetPoint('LEFT', 1, 0)
				cell.legend:SetPoint('LEFT', cell.led, 'RIGHT', 4, 0)
				local legendWidth = min(56, cellWidth * 0.45)
				cell.legend:SetWidth(legendWidth)
				cell.legend:SetJustifyH('LEFT')
				cell.lcd:SetPoint('TOPRIGHT')
				cell.lcd:SetPoint('BOTTOMRIGHT')
				cell.lcd:SetWidth(max(cellWidth - legendWidth - 13, 10))
			end
		end
	end
end

local function UpdateStrip(strip)
	if not (strip:IsVisible() and strip.ids) then return end
	for index, id in ipairs(strip.ids) do
		local cell = strip.cells[index]
		local ok, text, lamp = pcall(STATS[id][2])
		if not ok then text, lamp = '--', nil end
		if cell.text ~= text then cell.text = text; cell.value:SetText(text or ''); cell.plain:SetText(text or '') end
		if cell.lamp ~= lamp then
			cell.lamp = lamp
			Kit:SetLed(cell.led, lamp ~= nil, lamp)
		end
	end
end

-- The bottom of a device: the second meter, and the strip above the meters.
function Deck.BuildBottom(parent)
	if not xp then return end
	-- A second meter above the first, built like it.
	local second = BuildXP(parent)
	second.second = true
	xp.secondMeter = second
	Deck.DressMeter(xp, false)
	Deck.DressMeter(second, true)
	xp.strip = BuildStrip(parent)
end

local function SecondShown()
	local db = DB()
	return db.xpbar and db.barSecond and db.barSecond ~= 'none'
end

-- Height of everything along the base, with the gap above it.
function Deck.BottomHeight()
	local db = DB()
	local height = 0
	if db.xpbar then height = height + MeterHeight() + ROW_GAP end
	if SecondShown() then height = height + MeterHeight() + 4 end
	local strip = Deck.StripHeight()
	if strip > 0 then height = height + strip + ROW_GAP end
	return height
end

-- Place the meters and the strip along `parent`'s base, `inset` in from its edges.
-- right and bottom: the insets from those edges (the left one's by default);
-- hidden: the console editor took the deck out.
function Deck.PlaceBottom(parent, inset, right, bottom, hidden)
	if not xp then return end
	local db = DB()
	right = right or inset
	local y = bottom or inset
	if hidden then
		xp:Hide()
		if xp.secondMeter then xp.secondMeter:Hide() end
		if xp.strip then xp.strip:Hide() end
		return
	end
	xp:SetShown(db.xpbar and true or false)
	HW.PlaceMeter(xp, parent, inset, right, y, MeterHeight())
	if db.xpbar then y = y + MeterHeight() end
	local second = xp.secondMeter
	if second then
		second:SetShown(SecondShown() and true or false)
		if second:IsShown() then
			y = y + 4
			HW.PlaceMeter(second, parent, inset, right, y, MeterHeight())
			y = y + MeterHeight()
		else
			HW.PlaceMeter(second, parent, inset, right, y, MeterHeight())
		end
	end
	local strip = xp.strip
	if strip then
		local height = Deck.StripHeight()
		strip:SetShown(height > 0)
		if height > 0 then
			if db.xpbar or SecondShown() then y = y + ROW_GAP end
			strip:ClearAllPoints()
			strip:SetPoint('BOTTOMLEFT', parent, 'BOTTOMLEFT', inset, y)
			strip:SetPoint('BOTTOMRIGHT', parent, 'BOTTOMRIGHT', -right, y)
			LayoutStrip(strip, parent:GetWidth() - inset - right)
			UpdateStrip(strip)
		end
	end
	Deck.UpdateMeters()
end

-- Function keys -------------------------------------------------------------------------------
-- secure: attributes for our secure button; click: Blizzard buttons the key
-- clicks (the first that exists), securely; func: plain Lua run on click.
-- names: Blizzard button names separated by spaces; the first that exists.
local function FirstButton(names)
	for name in names:gmatch('%S+') do
		local button = _G[name]
		if button and not Forbidden(button) then return button end
	end
end

local function ShownFrame(...)
	for index = 1, select('#', ...) do
		local frame = _G[select(index, ...)]
		if type(frame) == 'table' and frame.IsShown and frame:IsShown() then return true end
	end
	return false
end

local function BarsLocked()
	local get = (C_CVar and C_CVar.GetCVarBool) or GetCVarBool
	return get and get('lockActionBars') and true or false
end

local HEARTH = 6948
local function HearthCooldown()
	local get = (C_Container and C_Container.GetItemCooldown) or _G.GetItemCooldown
	local start, duration = Call(get, HEARTH)
	if start and duration and start > 0 and duration > 1.5 then return start, duration end
end

local FN = {
	mount = {glyph = 'mount', legend = 'Mount', tip = 'Summon a random favorite mount.',
		secure = {type = 'macro', macrotext = '/run if C_MountJournal then C_MountJournal.SummonByID(0) end'},
		lamp = function() return Call(IsMounted) and 'green' or nil end},
	hearth = {glyph = 'hearth', legend = 'Hearth', tip = 'Use your hearthstone.', secure = {type = 'item', item = 'item:'..HEARTH},
		cooldown = HearthCooldown, lamp = function() return HearthCooldown() and 'amber' or nil end},
	map = {glyph = 'map', legend = 'Map', tip = 'Open the world map.', func = function() if ToggleWorldMap then ToggleWorldMap() end end,
		lamp = function() return ShownFrame('WorldMapFrame') and 'lamp' or nil end},
	spellbook = {glyph = 'spellbook', legend = 'Spells', tip = 'Open your spellbook.',
		click = 'SpellbookMicroButton', func = function()
			if PlayerSpellsUtil and PlayerSpellsUtil.ToggleSpellBookFrame then PlayerSpellsUtil.ToggleSpellBookFrame() end
		end, lamp = function() return ShownFrame('PlayerSpellsFrame', 'SpellBookFrame') and 'lamp' or nil end},
	talents = {glyph = 'talents', legend = 'Talent', tip = 'Open your talents.', click = 'PlayerSpellsMicroButton TalentMicroButton',
		lamp = function() return ShownFrame('PlayerSpellsFrame', 'PlayerTalentFrame', 'TalentFrame') and 'lamp' or nil end},
	character = {glyph = 'character', legend = 'Char', tip = 'Open your character.', click = 'CharacterMicroButton',
		lamp = function() return ShownFrame('CharacterFrame') and 'lamp' or nil end},
	collections = {glyph = 'collections', legend = 'Coll', tip = 'Open your collections.', click = 'CollectionsMicroButton',
		lamp = function() return ShownFrame('CollectionsJournal') and 'lamp' or nil end},
	journal = {glyph = 'journal', legend = 'Guide', tip = 'Open the adventure guide.', click = 'EJMicroButton',
		lamp = function() return ShownFrame('EncounterJournal') and 'lamp' or nil end},
	finder = {glyph = 'finder', legend = 'Group', tip = 'Open the group finder.', click = 'LFDMicroButton LFGMicroButton',
		lamp = function() return ShownFrame('PVEFrame', 'LFGParentFrame') and 'lamp' or nil end},
	quests = {glyph = 'quest', legend = 'Quest', tip = 'Open your quest log.', click = 'QuestLogMicroButton',
		lamp = function() return ShownFrame('QuestLogFrame') and 'lamp' or nil end},
	bags = {glyph = 'backpack', legend = 'Bags', tip = 'Open your bags.', func = function() if ToggleAllBags then ToggleAllBags() end end,
		lamp = function() return ShownFrame('ContainerFrameCombinedBags', 'ContainerFrame1') and 'lamp' or nil end},
	drawer = {glyph = 'drawer', legend = 'Drawer', tip = 'Open the gadget drawer.', func = function() if UI.ToggleDrawer then UI:ToggleDrawer() end end,
		lamp = function() return UI.DrawerOpen and UI:DrawerOpen() and 'lamp' or nil end},
	move = {glyph = 'move', legend = 'Move', tip = 'Move and size the interface.', func = function() if UI.ToggleMovers then UI:ToggleMovers() end end,
		lamp = function() return UI.MoversUnlocked and UI:MoversUnlocked() and 'amber' or nil end},
	calendar = {glyph = 'calendar', legend = 'Cal', tip = 'Open the calendar.', func = function()
			if UI.OpenCalendar then UI:OpenCalendar() elseif ToggleCalendar then ToggleCalendar() end
		end},
	meter = {glyph = 'meter', legend = 'Meter', tip = 'Show or hide the damage meters.', func = function()
			local shown
			for _, entry in ipairs(UI.GetMovers and UI:GetMovers() or {}) do
				if entry.key:find('^dm%.') and entry.frame and not entry.frame:IsProtected() then
					if shown == nil then shown = not entry.frame:IsShown() end
					entry.frame:SetShown(shown)
				end
			end
			local details = _G.Details
			if type(details) == 'table' and type(details.ToggleWindows) == 'function' then pcall(details.ToggleWindows, details) end
		end},
	lock = {glyph = 'lock', legend = 'Lock', tip = 'Lock or unlock the action bars.', func = function()
			if InCombatLockdown() then return end
			DB().lock = BarsLocked() and 'off' or 'on'
			ApplyLock()
		end, lamp = function() return not BarsLocked() and 'amber' or nil end},
	reload = {glyph = 'reload', legend = 'Reload', tip = 'Reload the interface.', func = function()
			Kit:AlertDialog({title = 'Reload UI', text = 'Reload the interface now?', confirm = 'Reload', onConfirm = ReloadUI, reload = true})
		end},
	menu = {glyph = 'menu', legend = 'Menu', tip = 'Open the game menu.', click = 'MainMenuMicroButton',
		lamp = function() return ShownFrame('GameMenuFrame') and 'lamp' or nil end},
	macro = {glyph = 'macro', legend = 'Macro', tip = 'Run your chosen macro.', macro = true},
}
Deck.FN_ITEMS = {{'none', 'None'}, {'mount', 'Mount'}, {'hearth', 'Hearthstone'}, {'map', 'Map'}, {'spellbook', 'Spellbook'},
	{'talents', 'Talents'}, {'character', 'Character'}, {'bags', 'Bags'}, {'collections', 'Collections'},
	{'journal', 'Adventure guide'}, {'finder', 'Group finder'}, {'quests', 'Quest log'}, {'drawer', 'Drawer'},
	{'move', 'Move UI'}, {'calendar', 'Calendar'}, {'meter', 'Damage meters'}, {'lock', 'Lock bars'},
	{'reload', 'Reload UI'}, {'menu', 'Game menu'}, {'macro', 'Custom macro'}}
local FN_SLOTS = 8
local fnKeys = {}

local function FnSize() return Kit:Clamp(floor(tonumber(DB().fnSize) or 22), 18, 32) end

-- How many keys each side carries (slots 1-4 left, 5-8 right).
local function FnCounts()
	local db = DB()
	if db.fnKeys == false then return 0, 0 end
	local left, right = 0, 0
	for index = 1, FN_SLOTS do
		local id = db['fn'..index]
		if id and FN[id] then
			if index <= FN_SLOTS / 2 then left = left + 1 else right = right + 1 end
		end
	end
	return left, right
end

-- Round glyph keycaps (the reference's round key) on the light keys; the
-- charcoal caps keep their own shape. No slot or well behind them.
function Deck.FnSprite(down)
	if LightCap() then return down and 'key-round-down' or 'key-round' end
	return Sprites()[down and 2 or 1]
end

-- The face: pressed one unit down, lifted one unit while the mouse is over it.
local function FnFace(key)
	local offset = key.down and -1 or (key.hover and 1 or 0)
	key.face:ClearAllPoints()
	key.face:SetPoint('TOPLEFT', 0, offset)
	key.face:SetPoint('BOTTOMRIGHT', 0, offset)
end

local function FnPress(key, down)
	if key.down == down then return end
	key.down = down
	Kit:SetSprite(key.skin, Deck.FnSprite(down))
	FnFace(key)
	Sound(down)
end

local function FnKey(parent, index)
	local button = CreateFrame('Button', 'JiberishSpec01FnKey'..index, parent, 'SecureActionButtonTemplate')
	button:RegisterForClicks('AnyUp')
	local key = {button = button, index = index}
	local back = CreateFrame('Frame', nil, button)
	back:SetAllPoints()
	back:EnableMouse(false)
	back:SetFrameLevel(max(button:GetFrameLevel() - 1, 0))
	key.back = back
	key.skin = Kit:Skin(back, Deck.FnSprite(false), 'BACKGROUND', 0)
	key.skin.kitMaxCorner = 6
	key.face = CreateFrame('Frame', nil, button)
	key.face:SetAllPoints()
	key.face:EnableMouse(false)
	key.glyph = key.face:CreateTexture(nil, 'ARTWORK')
	key.glyph:SetTexture(Kit.media..'icons-menu.tga')
	key.glyph:SetPoint('CENTER')
	key.cooldown = CreateFrame('Cooldown', nil, key.face, 'CooldownFrameTemplate')
	key.cooldown:SetAllPoints()
	key.cooldown:SetDrawEdge(false)
	key.cooldown:SetHideCountdownNumbers(true)
	if key.cooldown.SetSwipeTexture then key.cooldown:SetSwipeTexture(Kit.media..'mask-icon.tga', 0, 0, 0, 0.45) end
	-- The lamp inside the cap's top, clear of a round cap's edge.
	key.lamp = Kit:Led(key.face, 3, false)
	key.lamp:SetPoint('TOP', 0, -2)
	-- The legend is printed beside or under the key (see Deck.PlaceFnAt).
	key.legend = Kit:Label(parent, '', Surface() == 'dark' and 'darkDim' or 'dim', 6, true)
	key.legend:SetWordWrap(false)
	button:HookScript('OnMouseDown', function() FnPress(key, true) end)
	button:HookScript('OnMouseUp', function() FnPress(key, false) end)
	button:HookScript('OnHide', function() FnPress(key, false) end)
	button:HookScript('OnClick', function()
		local def = key.def
		-- Plain functions run here; secure actions were done by the button itself.
		if def and def.func and not key.secure then UI:Safe(def.func) end
		C_Timer.After(0.1, function() UI:Safe(Deck.FnLamps) end)
	end)
	button:SetScript('OnEnter', function(self)
		local def = key.def
		if not def then return end
		key.hover = true
		FnFace(key)
		Kit:Play('tick')
		GameTooltip:SetOwner(self, 'ANCHOR_TOP')
		GameTooltip:AddLine(def.name or def.legend, 1, 1, 1)
		GameTooltip:AddLine(def.tip, 0.85, 0.85, 0.82, true)
		GameTooltip:Show()
	end)
	button:SetScript('OnLeave', function()
		key.hover = nil
		FnFace(key)
		GameTooltip:Hide()
	end)
	fnKeys[index] = key
	return key
end

-- Set up each key for its slot. Out of combat only (secure attributes).
function Deck.ConfigureFn()
	if #fnKeys == 0 then return end
	if InCombatLockdown() then return UI:AfterCombat(Deck.ConfigureFn, 'ab.fnkeys') end
	local db = DB()
	local size = FnSize()
	for index, key in ipairs(fnKeys) do
		local id = db.fnKeys ~= false and db['fn'..index]
		local def = id and FN[id]
		local button = key.button
		for _, attribute in ipairs({'type', 'macrotext', 'item', 'clickbutton', 'macro'}) do button:SetAttribute(attribute, nil) end
		key.def, key.secure = def, nil
		if def then
			if def.secure then
				for attribute, value in pairs(def.secure) do button:SetAttribute(attribute, value) end
				key.secure = true
			elseif def.macro then
				local name = strtrim(db.fnMacro or '')
				if name ~= '' then button:SetAttribute('type', 'macro'); button:SetAttribute('macro', name); key.secure = true end
			elseif def.click then
				local target = FirstButton(def.click)
				if target then button:SetAttribute('type', 'click'); button:SetAttribute('clickbutton', target); key.secure = true end
			end
			local index0 = Deck.MENU_INDEX and Deck.MENU_INDEX[def.glyph] or 0
			local column, row = index0 % 8, floor(index0 / 8)
			key.glyph:SetTexCoord(column / 8, (column + 1) / 8, row / 4, (row + 1) / 4)
			key.glyph:SetSize(floor(size * 0.62 + 0.5), floor(size * 0.62 + 0.5))
			Kit:Tint(key.glyph, LightCap() and 'ink' or 'darkInk', 0.85)
			local legend = def.legend
			if def.macro and strtrim(db.fnMacro or '') ~= '' then legend = strsub(strtrim(db.fnMacro), 1, 6) end
			key.legend:SetText(strupper(legend))
			button:SetSize(size, size)
			Kit:SetSprite(key.skin, Deck.FnSprite(key.down))
			Kit:FitSprite(key.skin, size, size)
			if key.cooldown.SetSwipeTexture then
				key.cooldown:SetSwipeTexture(Kit.media..(LightCap() and 'circle' or 'mask-icon')..'.tga', 0, 0, 0, 0.45)
			end
			button:Show()
		else
			button:Hide()
		end
		key.legend:SetShown(def ~= nil)
	end
	Deck.FnLamps()
end

function Deck.FnLamps()
	for _, key in ipairs(fnKeys) do
		local def = key.def
		if def and key.button:IsVisible() then
			local ok, lamp = pcall(def.lamp or function() end)
			lamp = ok and lamp or nil
			if key.lit ~= lamp then
				key.lit = lamp
				Kit:SetLed(key.lamp, lamp ~= nil, lamp)
			end
			if def.cooldown then
				local start, duration = def.cooldown()
				if start then key.cooldown:SetCooldown(start, duration) else key.cooldown:Clear() end
			end
		end
	end
end

function Deck.BuildFn(parent)
	if #fnKeys > 0 then return end
	parent.fnLeft = CreateFrame('Frame', nil, parent)
	parent.fnRight = CreateFrame('Frame', nil, parent)
	for index = 1, FN_SLOTS do FnKey(index <= FN_SLOTS / 2 and parent.fnLeft or parent.fnRight, index) end
	Deck.ConfigureFn()
end

-- The function keys' clusters. Each side's keys run in `columns` (from the
-- console editor; one column by default) with their legends printed beside
-- them, facing the banks; in two or more columns the legends go under each
-- key and the keys space out to fit them. Legends are measured, never overlap.
-- Gap between keys, between a key and its legend, and the widest legend.
-- (A column's keys sit closer: 4 keys of 22 stay inside a 2-row console.)
Deck.FN_GAP, Deck.FN_LEGEND_GAP, Deck.FN_LEGEND_MAX, Deck.FN_COLUMN_GAP = 6, 5, 44, 4
function Deck.FnColumns(side)
	local custom = Deck.CustomLayout()
	local spot = custom and custom[side == 1 and 'fnL' or 'fnR']
	return Kit:Clamp(floor(type(spot) == 'table' and tonumber(spot.columns) or 1), 1, FN_SLOTS / 2)
end

-- A side's shown keys, the widest legend among them, and its size: width,
-- height, keys, legend width, columns.
function Deck.FnCluster(side)
	local FN_GAP, FN_LEGEND_GAP, FN_LEGEND_MAX = Deck.FN_GAP, Deck.FN_LEGEND_GAP, Deck.FN_LEGEND_MAX
	local list, legend = {}, 0
	if #fnKeys == 0 or DB().fnKeys == false then return 0, 0, list, 0, 1 end
	local first = side == 1 and 1 or FN_SLOTS / 2 + 1
	for index = first, first + FN_SLOTS / 2 - 1 do
		local key = fnKeys[index]
		if key and key.def then
			list[#list + 1] = key
			local text = key.legend
			local width = text.GetUnboundedStringWidth and text:GetUnboundedStringWidth() or text:GetStringWidth()
			legend = max(legend, width or 0)
		end
	end
	if #list == 0 then return 0, 0, list, 0, 1 end
	legend = min(math.ceil(legend), FN_LEGEND_MAX)
	local size, columns = FnSize(), Deck.FnColumns(side)
	local across = min(columns, #list)
	local lines = math.ceil(#list / across)
	if across == 1 then
		return size + FN_LEGEND_GAP + legend, lines * size + (lines - 1) * Deck.FN_COLUMN_GAP, list, legend, 1
	end
	local pitch = max(size, legend) + FN_GAP
	return across * pitch - FN_GAP, lines * (size + 12) - 4, list, legend, across
end

-- The larger side's size (for the console's side columns and body).
function Deck.FnBlock()
	local lw, lh = Deck.FnCluster(1)
	local rw, rh = Deck.FnCluster(2)
	if lw == 0 and rw == 0 then return 0, 0, 1 end
	return max(lw, rw), max(lh, rh), 1
end

-- Each cluster's size: left width, height, right width, height.
function Deck.FnSides()
	local lw, lh = Deck.FnCluster(1)
	local rw, rh = Deck.FnCluster(2)
	return lw, lh, rw, rh
end

-- One cluster (side 1 left, 2 right) with its top-left at x, y in the parent
-- (y down); no x hides it.
function Deck.PlaceFnAt(parent, side, x, y)
	if #fnKeys == 0 or not parent.fnLeft then return end
	if InCombatLockdown() then return UI:AfterCombat(function() Deck.PlaceFnAt(parent, side, x, y) end, 'ab.fnplace'..side) end
	local cluster = side == 1 and parent.fnLeft or parent.fnRight
	if not x then cluster:Hide() return end
	local FN_GAP, FN_LEGEND_GAP = Deck.FN_GAP, Deck.FN_LEGEND_GAP
	local width, height, list, legend, across = Deck.FnCluster(side)
	local size = FnSize()
	local pitch = max(size, legend) + FN_GAP
	for index, key in ipairs(list) do
		local line, place = floor((index - 1) / across), (index - 1) % across
		local button, text = key.button, key.legend
		button:ClearAllPoints()
		text:ClearAllPoints()
		text:SetWidth(across == 1 and legend or pitch - 2)
		if across == 1 then
			-- One column, the legend beside each key, facing the banks.
			local top = -(index - 1) * (size + Deck.FN_COLUMN_GAP)
			if side == 1 then
				button:SetPoint('TOPLEFT', cluster, 'TOPLEFT', 0, top)
				text:SetPoint('LEFT', button, 'RIGHT', FN_LEGEND_GAP, 0)
				text:SetJustifyH('LEFT')
			else
				button:SetPoint('TOPRIGHT', cluster, 'TOPRIGHT', 0, top)
				text:SetPoint('RIGHT', button, 'LEFT', -FN_LEGEND_GAP, 0)
				text:SetJustifyH('RIGHT')
			end
		else
			button:SetPoint('TOPLEFT', cluster, 'TOPLEFT', place * pitch + (pitch - FN_GAP - size) / 2, -line * (size + 12))
			text:SetPoint('TOP', button, 'BOTTOM', 0, -3)
			text:SetJustifyH('CENTER')
		end
	end
	cluster:SetSize(max(width, 1), max(height, 1))
	cluster:ClearAllPoints()
	cluster:SetPoint('TOPLEFT', parent, 'TOPLEFT', x, -y)
	cluster:SetShown(#list > 0)
end

-- Header panels -------------------------------------------------------------------------------
local PANELS = {
	{id = 'zone', field = 'panelZone', width = 128, read = function()
		local zone = Call(GetMinimapZoneText) or Call(GetZoneText) or ''
		local map = C_Map and Call(C_Map.GetBestMapForUnit, 'player')
		local position = map and C_Map.GetPlayerMapPosition and Call(C_Map.GetPlayerMapPosition, map, 'player')
		local x, y
		if position and position.GetXY then x, y = Call(position.GetXY, position) end
		zone = strupper(strsub(zone, 1, 12))
		if x and y then return format('%s %.1f %.1f', zone, x * 100, y * 100) end
		return zone
	end},
	{id = 'gold', field = 'panelGold', width = 64, read = function() return Gold(Plain(GetMoney())) end},
	{id = 'durability', field = 'panelDurability', width = 58, led = true, read = function()
		local lowest
		for slot = 1, 19 do
			local current, maximum = Call(GetInventoryItemDurability, slot)
			if current and maximum and maximum > 0 then lowest = min(lowest or 1, current / maximum) end
		end
		if not lowest then return 'DUR --' end
		return format('DUR %d%%', floor(lowest * 100 + 0.5)), lowest < 0.2 and 'red' or lowest < 0.5 and 'amber' or 'green'
	end},
	{id = 'latency', field = 'panelLatency', width = 58, led = true, read = function()
		local _, _, home, world = Call(GetNetStats)
		local ms = max(home or 0, world or 0)
		return format('%dMS', ms), ms > 300 and 'red' or ms > 150 and 'amber' or 'green'
	end},
}

function Deck.BuildPanels(device)
	device.panels = {}
	for _, def in ipairs(PANELS) do
		local panel = Kit:LCDPanel(device, {radius = 3})
		panel:SetSize(def.width, 14)
		panel.def = def
		panel.text = Kit:Text(panel, '', 'tiny', 'lcdInk', true)
		panel.text:SetPoint('RIGHT', -5, 0)
		panel.text:SetWordWrap(false)
		if def.led then
			panel.led = Kit:Led(panel, 4, false)
			panel.led:SetPoint('LEFT', 5, 0)
		end
		panel:Hide()
		device.panels[#device.panels + 1] = panel
	end
end

-- Lay the panels out leftward from `anchor` while they fit beside the title,
-- and return the frame the title should end at.
function Deck.PlacePanels(device, anchor, used)
	if not device.panels then return anchor end
	local db = DB()
	local room = device:GetWidth() - used - 170 -- the model plate and title keep their room
	local at = anchor
	for _, panel in ipairs(device.panels) do
		local wanted = db[panel.def.field] ~= false
		if wanted and room >= panel:GetWidth() + 6 then
			room = room - panel:GetWidth() - 6
			panel:ClearAllPoints()
			panel:SetPoint('RIGHT', at, 'LEFT', -6, 0)
			panel:Show()
			at = panel
		else
			panel:Hide()
		end
	end
	Deck.UpdatePanels(device)
	return at
end

function Deck.UpdatePanels(device)
	for _, panel in ipairs(device and device.panels or {}) do
		if panel:IsShown() then
			local ok, text, lamp = pcall(panel.def.read)
			if ok then
				panel.text:SetText(text or '')
				if panel.led then Kit:SetLed(panel.led, lamp ~= nil, lamp) end
			end
		end
	end
end

-- Events and the ticker ------------------------------------------------------------------------
local events = CreateFrame('Frame')
for _, event in ipairs({'PLAYER_ENTERING_WORLD', 'PLAYER_XP_UPDATE', 'PLAYER_LEVEL_UP', 'QUEST_TURNED_IN',
	'CHAT_MSG_COMBAT_XP_GAIN', 'TIME_PLAYED_MSG', 'PLAYER_MONEY', 'UPDATE_INVENTORY_DURABILITY', 'BAG_UPDATE_COOLDOWN',
	'PLAYER_MOUNT_DISPLAY_CHANGED', 'CVAR_UPDATE', 'HONOR_XP_UPDATE', 'HONOR_LEVEL_UPDATE', 'QUEST_LOG_UPDATE'}) do
	pcall(events.RegisterEvent, events, event)
end
events:SetScript('OnEvent', function(_, event, ...)
	if event == 'PLAYER_ENTERING_WORLD' then
		if not session.money then session.money = Plain(GetMoney()) end
		TrackXP()
		local db = DB()
		local wantsPlayed = false
		for index = 1, STAT_SLOTS do
			local id = db['stat'..index]
			if id == 'played' or id == 'levelTime' then wantsPlayed = true end
		end
		if wantsPlayed and StatsWanted() and xp then C_Timer.After(2, AskPlayed) end
	elseif event == 'PLAYER_XP_UPDATE' or event == 'PLAYER_LEVEL_UP' then
		TrackXP()
	elseif event == 'QUEST_TURNED_IN' then
		local _, xpReward = ...
		xpReward = Plain(xpReward)
		if type(xpReward) == 'number' and xpReward > 0 then session.questXP = session.questXP + xpReward end
		questUntil = GetTime() + 1
	elseif event == 'CHAT_MSG_COMBAT_XP_GAIN' then
		-- Only counted, never read: a kill's XP message (quest XP arrives with a turn-in).
		if GetTime() > questUntil then session.kills = session.kills + 1 end
	elseif event == 'TIME_PLAYED_MSG' then
		local total, level = ...
		total, level = Plain(total), Plain(level)
		if type(total) == 'number' then played.total, played.level, played.at = total, level or 0, GetTime() end
		C_Timer.After(0, function() Quiet(false) end)
	elseif event == 'QUEST_LOG_UPDATE' then
		if DB().questPreview then UI:Safe(Deck.UpdateMeters) end
		return
	end
	if event == 'HONOR_XP_UPDATE' or event == 'HONOR_LEVEL_UPDATE' then UI:Safe(Deck.UpdateMeters) end
	UI:Safe(Deck.FnLamps)
end)

-- Once a second, while a console is shown: the strip, the panels and the key lamps.
C_Timer.NewTicker(1, function()
	if not (xp and xp:GetParent() and xp:GetParent():IsVisible()) then return end
	for _, strip in ipairs(strips) do UI:Safe(UpdateStrip, strip) end
	if console then UI:Safe(Deck.UpdatePanels, console) end
	UI:Safe(Deck.FnLamps)
end)
end)()

function module:Enable()
	if InCombatLockdown() then
		UI:AfterCombat(function() self.enabled = UI:Safe(self.Enable, self) end, 'actionbars')
		return
	end
	local db = DB()
	-- Once: the micro menu moves into the console's header (where the console
	-- has one); its own device stays an option (Layout: One line).
	if not db.menuInConsole then
		db.menuInConsole = true
		if db.layout ~= 'free' then db.menuLayout, db.menuEdge = 'console', 'header' end
	end
	-- Once: earlier saves move to the minimal deck (text stats, slim meter, a
	-- quiet header). A flag outside the defaults marks it done.
	if not db.minimalDeck then
		db.minimalDeck = true
		db.statsStyle, db.barStyle = 'text', 'slim'
		db.panelZone, db.panelGold, db.panelDurability, db.panelLatency = false, false, false, false
	end
	-- Once: the menu and bags move from the old grid to one line.
	if not db.menuLine then
		db.menuLine = true
		db.menuLayout, db.bagsLayout = 'line', 'line'
	end
	if Docking() then BuildConsole() else BuildFree() end
	if db.side then BuildSide() end
	if db.stance then BuildStance() end
	if db.pet then BuildPet() end
	BuildMenu()
	UI:Safe(BuildExtra)
	RetireBlizzard()
	inCombat = InCombatLockdown() and true or false
	LayoutConsole()
	LayoutStance()
	ApplyLock()
	ApplyCountdownCVar()
	ApplyCVars()
	Bind()
	UpdateFades()
	ForKeys(UpdateKey)
	UI:Safe(UpdatePet)
	UI:Safe(UpdateXP)
	UI:Safe(UpdateLeave)
	-- Devices were registered before their final size; default spots depend on it.
	UI:PlaceAllMovers()

	local driver = CreateFrame('Frame')
	for event in pairs(EVENTS) do pcall(driver.RegisterEvent, driver, event) end
	for _, event in ipairs({'UPDATE_SHAPESHIFT_FORM', 'PLAYER_CONTROL_LOST', 'PLAYER_CONTROL_GAINED', 'PET_BATTLE_OPENING_START',
		'PET_BATTLE_CLOSE', 'ACTIONBAR_SLOT_CHANGED', 'ACTION_USABLE_CHANGED', 'ACTION_RANGE_CHECK_UPDATE', 'UPDATE_BINDINGS',
		'SPELL_ACTIVATION_OVERLAY_GLOW_SHOW', 'SPELL_ACTIVATION_OVERLAY_GLOW_HIDE', 'PLAYER_REGEN_DISABLED', 'PLAYER_REGEN_ENABLED',
		'ACTIONBAR_SHOWGRID', 'ACTIONBAR_HIDEGRID'}) do
		pcall(driver.RegisterEvent, driver, event)
	end
	pcall(driver.RegisterUnitEvent, driver, 'UNIT_PET', 'player')
	pcall(driver.RegisterUnitEvent, driver, 'UNIT_FLAGS', 'pet')
	pcall(driver.RegisterUnitEvent, driver, 'UNIT_INVENTORY_CHANGED', 'player')
	pcall(driver.RegisterUnitEvent, driver, 'UNIT_ENTERED_VEHICLE', 'player')
	pcall(driver.RegisterUnitEvent, driver, 'UNIT_EXITED_VEHICLE', 'player')
	driver:SetScript('OnEvent', OnEvent)
	-- The clock readout ticks over each minute.
	C_Timer.NewTicker(15, function() if DB().readout == 'clock' then UI:Safe(UpdateXP) end end)
	-- Clients without range events are asked a few times a second.
	if not RANGE_EVENTS then C_Timer.NewTicker(0.25, function() ForKeys(UpdateRange) end) end
end

function module:Refresh()
	if InCombatLockdown() then return UI:AfterCombat(function() UI:Safe(self.Refresh, self) end, 'ab.refresh') end
	local scale = DB().scale or 1
	local devices = {{console, 'ab.console'}, {side, 'ab.side'}, {petModule, 'ab.pet'}, {stanceModule, 'ab.stance'}}
	for row = 1, 3 do devices[#devices + 1] = {BARS[row].device, 'ab.bar'..row} end
	for _, entry in ipairs(devices) do
		local device = entry[1]
		if device then
			UI:SetMoverBaseScale(entry[2], scale, device)
			if device.shell then device.shell:SetShown(DB().housing ~= false) end
			HW.ShowDecor(device, DB().housing ~= false)
		end
	end
	if menu then UI:Safe(LayoutMenu) end
	Deck.ConfigureFn()
	LayoutConsole()
	LayoutFree()
	LayoutSide()
	PlacePetKeys()
	LayoutStance()
	UI:PlaceAllMovers()
	for _, key in ipairs(keys) do
		key.down, key.glowing = nil, nil
		Kit:SetSprite(key.skin, Sprites()[1])
		UI:Safe(ApplyLook, key)
		UI:Safe(UpdateKey, key)
	end
	UpdateFades(true)
	UI:Safe(UpdateXP)
	ApplyLock()
	ApplyCountdownCVar()
	Bind()
	Kit:RefitShells()
end

local function Percent(v) return format('%d%%', v * 100 + 0.5) end
-- A Menu or Bags card: its device's options, `extra`, then a switch per button.
local function MenuRows(group, extra)
	local path = 'actionbars.'..group
	local rows = {
		{'switch', group == 'menu' and 'Menu' or 'Bags', path..'Enable', group == 'menu' and 'The micro buttons on a small device of their own.'
			or 'The bag slots on a small device of their own.', since = '0.5.1'},
		{'slider', 'Key size', path..'KeySize', 16, 40, 1, since = '0.5.1'},
		{'slider', 'Scale', path..'Scale', 0.5, 1.5, 0.05, format = Percent, since = '0.5.1'},
		{'dropdown', 'Layout', path..'Layout', items = {{'line', 'One line'}, {'column', 'One column'}, {'grid', 'Grid'},
			{'balanced', 'Balanced grid'}, {'console', 'In the console'}}, since = '0.5.1',
			note = 'Grid: a set number across, a short last line centred. Balanced: the most even grid for the keys shown. In the console: a slim strip inside CX-1.'},
		{'slider', 'Keys per line', path..'Columns', 1, 12, 1, 'Grid only: keys across before a new line starts.',
			hidden = function() return DB()[group..'Layout'] ~= 'grid' end, since = '0.5.1'},
		{'segmented', 'Console edge', 'actionbars.menuEdge', items = {{'bottom', 'Bottom'}, {'header', 'Header'}}, since = '0.5.1',
			note = 'Where the strip runs in the console. The header is used while it fits beside the console\'s name and readouts.',
			hidden = function() return DB()[group..'Layout'] ~= 'console' end},
		{'slider', 'Spacing', path..'Spacing', 0, 12, 1, 'Space between keys.', since = '0.5.1'},
		{'slider', 'Glyph size', path..'Glyph', 0.4, 0.9, 0.02, format = Percent, since = '0.5.1'},
		{'switch', 'Housing', path..'Housing', 'The device housing round the keys.', since = '0.5.1'},
		{'switch', 'Show on mouseover', path..'Fade', 'Faint until the mouse is over it.', since = '0.5.1'},
	}
	for _, row in ipairs(extra or {}) do rows[#rows + 1] = row end
	rows[#rows + 1] = {'note', 'Buttons on this device:'}
	for _, row in ipairs(Deck.ButtonRows(group)) do rows[#rows + 1] = row end
	return rows
end
local function Auto(v) return v == 0 and 'Auto' or tostring(v) end
local function Seconds(v) return v == 0 and 'All' or (v..' s') end
local POSITIONS = {{'TOPLEFT', 'Top left'}, {'TOP', 'Top'}, {'TOPRIGHT', 'Top right'}}
local LOW_POSITIONS = {{'BOTTOMLEFT', 'Bottom left'}, {'BOTTOM', 'Bottom'}, {'BOTTOMRIGHT', 'Bottom right'}}

-- One card per bar.
local function BarCard(id, title, note, sized)
	local path = 'actionbars.bar'..id..'.'
	local rows = {
		{'switch', 'Show this bar', path..'enabled', note, reload = true},
		{'slider', 'Keys shown', path..'shown', 1, 12, 1, 'The first keys of the bar; the rest hide and answer no key bind.'},
		{'slider', 'Spacing', path..'spacing', 0, 20, 1, 'Room between keys.'},
	}
	if sized then
		rows[#rows + 1] = {'slider', 'Key size', path..'keySize', 0, 56, 1, 'Free layout and side bars. Auto follows the console\'s key size; in the console every bar uses it.', format = Auto}
		rows[#rows + 1] = {'slider', 'Keys per row', path..'perRow', 1, 12, 1, 'Wraps the bar into a block; in the console every bar is one row.'}
	end
	rows[#rows + 1] = {'switch', 'Empty keys', path..'grid', 'Keys with nothing on them show. Off: they appear only while you drag a spell.'}
	rows[#rows + 1] = {'switch', 'Fade out of combat', path..'fade', 'The bar dims until a fight starts.'}
	rows[#rows + 1] = {'switch', 'Show on mouseover', path..'mouseover', 'The bar dims until the mouse is over it.'}
	rows[#rows + 1] = {'slider', 'Faded opacity', path..'fadeAlpha', 0, 1, 0.05, nil, format = Percent}
	return {title = title, rows = rows}
end

UI:RegisterPage('actionbars', {title = 'Action bars', order = 11, cards = {
	{title = 'Console', rows = {
		{'segmented', 'Keys', 'style.actionbars', items = {{'keys', 'Keys'}, {'caps', 'Caps'}, {'blizzard', 'Blizzard'}}, reload = true,
			note = 'Keys: the reference\'s light keys. Caps: its charcoal keycaps. Blizzard: the game\'s own bars.'},
		{'segmented', 'Console look', 'actionbars.look', items = {{'hardware', 'Hardware'}, {'classic', 'Classic'}}, reload = true,
			since = '0.5.1', note = 'Hardware: keys set in slots in the housing, legends printed on the caps, printed banks, a page LCD and a meter with its own LCD, as on SPEC-01\'s devices. Classic: the earlier look.'},
		{'segmented', 'Layout', 'actionbars.layout', items = {{'console', 'Console'}, {'free', 'Free'}}, reload = true,
			note = 'Console: one device with the player and target docked beside the keys. Free: every bar on its own.'},
		{'switch', 'Dock unit frames', 'actionbars.dock', 'Player and target frames and cast bars inside the console.', reload = true},
		{'switch', 'Dock focus', 'actionbars.dockFocus', 'The focus frame inside the console too, under the player.',
			since = '0.5.2', hidden = function() return not DB().dock end},
		{'switch', 'Dock target of target', 'actionbars.dockToT', 'The target of target inside the console too, under the target.',
			since = '0.5.2', hidden = function() return not DB().dock end},
		{'switch', 'Dock pet', 'actionbars.dockPet', 'The pet frame inside the console, in the cast row under the player.',
			since = '0.5.2', hidden = function() return not DB().dock end},
		{'button', 'Arrangement', 'Edit console', function()
			UI:ToggleHub(nil, false)
			if UI.EditConsole then UI:EditConsole(true) end
		end, 'Move each key bank, unit frame, cast bar, the function keys and the meters anywhere inside the console, on a pixel grid. Also /spec console.', since = '0.5.2'},
		{'switch', 'Housing', 'actionbars.housing', 'The device housings around the keys.'},
		{'slider', 'Rows', 'actionbars.rows', 1, 3, 1, 'Bars in the console: bar 1, then the bottom left and right bars.', reload = true},
		{'slider', 'Key size', 'actionbars.keySize', 24, 48, 1, 'Width of each key. In a fixed-size console the keys shrink just enough to fit; the readout shows the size in use.',
			format = function(v)
				local _, _, used = UI:ConsoleSize()
				if used and used ~= floor(v + 0.5) then return format('%d (%d)', v, used) end
				return tostring(v)
			end},
		{'slider', 'Key gap', 'actionbars.keyGap', 0, 20, 1, 'Space between keys. Auto keeps each bar\'s own spacing.', format = Auto, since = '0.5.1'},
		{'slider', 'Console width', 'actionbars.consoleWidth', 0, 2400, 10, 'Auto sizes the console to its keys and docked frames. A fixed width is kept: changing the key size moves only the keys.',
			format = function(v)
				local width = UI:ConsoleSize()
				if v == 0 then return width and format('Auto (%d)', width) or 'Auto' end
				return tostring(v)
			end, since = '0.5.1'},
		{'slider', 'Console height', 'actionbars.consoleHeight', 0, 600, 2, 'Auto sizes it to what it holds. A fixed height is kept; the banks sit in the middle.',
			format = function(v)
				local _, height = UI:ConsoleSize()
				if v == 0 then return height and format('Auto (%d)', height) or 'Auto' end
				return tostring(v)
			end, since = '0.5.1'},
		{'segmented', 'No target', 'actionbars.targetPlate', items = {{'plate', 'Dim plate'}, {'collapse', 'Nothing'}}, since = '0.5.1',
			note = 'With no target, a dim plate the player frame\'s size marks where it appears, or the space stays empty.'},
		{'segmented', 'Banks', 'actionbars.bankAlign', items = {{'center', 'Centre'}, {'left', 'Left'}, {'spread', 'Spread'}}, since = '0.5.1',
			note = 'Where the key banks sit in the console. Spread shares a fixed width out between the keys.'},
		{'slider', 'Side padding', 'actionbars.padding', 0, 60, 2, 'Extra room at the console\'s sides.'},
		{'slider', 'Scale', 'actionbars.scale', 0.6, 1.6, 0.05, 'Size of every action bar device.', format = Percent},
		{'button', 'Placement', 'Move bars', function() UI:ToggleHub(nil, false); UI:ToggleMovers() end, 'Snaps to a grid and to other frames.'},
	}},
	{title = 'Meter and readout', rows = {
		{'switch', 'Meter', 'actionbars.xpbar', 'Experience, reputation or honor along the console\'s base. Click it for the next source; right-click for reputations.', reload = true},
		{'dropdown', 'Shows', 'actionbars.barSource', items = Deck.SOURCE_ITEMS, since = '0.5.1',
			note = 'Auto: experience while levelling, the watched reputation at the level cap (honor if there is none).'},
		{'dropdown', 'Second meter', 'actionbars.barSecond', items = {{'none', 'None'}, {'auto', 'Auto'}, {'xp', 'Experience'},
			{'rep', 'Reputation'}, {'honor', 'Honor'}}, since = '0.5.1', note = 'A second meter stacked above the first, e.g. reputation while levelling.'},
		{'segmented', 'Style', 'actionbars.barStyle', items = {{'slim', 'Slim'}, {'flat', 'Flat'}, {'dots', 'LED dots'}, {'segments', 'Segments'}},
			since = '0.5.1', note = 'Slim: a hairline meter with a lit edge and the percent printed at its end. Flat, LED dots or segments in a track with an LCD.'},
		{'slider', 'Meter height', 'actionbars.xpHeight', 4, 16, 1},
		{'switch', 'Rested XP', 'actionbars.restedOverlay', 'Rested experience as a lighter stretch past the fill.', since = '0.5.1'},
		{'switch', 'Quests ready', 'actionbars.questPreview', 'The XP of quests ready to hand in, as a second stretch.', since = '0.5.1'},
		{'segmented', 'Colors', 'actionbars.meterColors', items = {{'theme', 'Theme'}, {'custom', 'Custom'}}, since = '0.5.1'},
		{'color', 'Experience', 'actionbars.xpColor', hidden = function() return DB().meterColors ~= 'custom' end},
		{'color', 'Rested', 'actionbars.restedColor', hidden = function() return DB().meterColors ~= 'custom' end},
		{'color', 'Reputation', 'actionbars.repColor', hidden = function() return DB().meterColors ~= 'custom' end},
		{'color', 'Honor', 'actionbars.honorColor', hidden = function() return DB().meterColors ~= 'custom' end},
		{'color', 'Quests ready', 'actionbars.previewColor', hidden = function() return DB().meterColors ~= 'custom' end},
		{'segmented', 'Console LCD', 'actionbars.readout', items = {{'level', 'Level'}, {'clock', 'Clock'}, {'off', 'Off'}},
			note = 'Level and progress, the time, or no LCD.'},
	}},
	{title = 'Stats strip', rows = {
		{'switch', 'Stats strip', 'actionbars.stats', 'A line of readouts above the meter.', since = '0.5.1'},
		{'segmented', 'Style', 'actionbars.statsStyle', items = {{'text', 'Minimal text'}, {'chips', 'LCD chips'}, {'hidden', 'Hidden'}}, since = '0.5.1',
			note = 'Minimal text: printed legends and values separated by dots. LCD chips: each readout on a small LCD with a lamp.'},
		{'segmented', 'Chip size', 'actionbars.statsSize', items = {{'compact', 'Compact'}, {'comfortable', 'Comfortable'}}, since = '0.5.1',
			hidden = function() return (DB().statsStyle or 'text') ~= 'chips' end,
			note = 'Compact: legend and LCD on one line. Comfortable: the legend printed over the LCD.'},
		{'dropdown', 'Slot 1', 'actionbars.stat1', items = Deck.STAT_ITEMS, since = '0.5.1'},
		{'dropdown', 'Slot 2', 'actionbars.stat2', items = Deck.STAT_ITEMS, since = '0.5.1'},
		{'dropdown', 'Slot 3', 'actionbars.stat3', items = Deck.STAT_ITEMS, since = '0.5.1'},
		{'dropdown', 'Slot 4', 'actionbars.stat4', items = Deck.STAT_ITEMS, since = '0.5.1'},
		{'dropdown', 'Slot 5', 'actionbars.stat5', items = Deck.STAT_ITEMS, since = '0.5.1'},
		{'dropdown', 'Slot 6', 'actionbars.stat6', items = Deck.STAT_ITEMS, since = '0.5.1'},
		{'note', 'Rates count from when you logged in. Time played is asked of the game once, quietly. Kills are counted from the XP messages, not read.'},
	}},
	{title = 'Function keys', rows = {
		{'switch', 'Function keys', 'actionbars.fnKeys', 'Small keys at the top of the console\'s side columns: mount, hearthstone, map and more.', since = '0.5.1'},
		{'slider', 'Key size', 'actionbars.fnSize', 18, 32, 1, nil, since = '0.5.1'},
		{'dropdown', 'Left 1', 'actionbars.fn1', items = Deck.FN_ITEMS, since = '0.5.1'},
		{'dropdown', 'Left 2', 'actionbars.fn2', items = Deck.FN_ITEMS, since = '0.5.1'},
		{'dropdown', 'Left 3', 'actionbars.fn3', items = Deck.FN_ITEMS, since = '0.5.1'},
		{'dropdown', 'Left 4', 'actionbars.fn4', items = Deck.FN_ITEMS, since = '0.5.1'},
		{'dropdown', 'Right 1', 'actionbars.fn5', items = Deck.FN_ITEMS, since = '0.5.1'},
		{'dropdown', 'Right 2', 'actionbars.fn6', items = Deck.FN_ITEMS, since = '0.5.1'},
		{'dropdown', 'Right 3', 'actionbars.fn7', items = Deck.FN_ITEMS, since = '0.5.1'},
		{'dropdown', 'Right 4', 'actionbars.fn8', items = Deck.FN_ITEMS, since = '0.5.1'},
		{'input', 'Custom macro', 'actionbars.fnMacro', 'The name of a macro for the Custom macro key.', since = '0.5.1'},
		{'note', 'Keys are set up out of combat; a change made in a fight applies when it ends.'},
	}},
	{title = 'Header panels', rows = {
		{'switch', 'Zone and coordinates', 'actionbars.panelZone', since = '0.5.1'},
		{'switch', 'Gold', 'actionbars.panelGold', since = '0.5.1'},
		{'switch', 'Durability', 'actionbars.panelDurability', 'Your most worn item, with a lamp: green, amber, red.', since = '0.5.1'},
		{'switch', 'Latency', 'actionbars.panelLatency', since = '0.5.1'},
		{'note', 'Panels sit in the console\'s header while they fit beside its name.'},
	}},
	{title = 'Legends', rows = {
		{'switch', 'Keybinds', 'actionbars.hotkeys', 'The bound key printed on each key.'},
		{'switch', 'Short keybinds', 'actionbars.abbreviate', 'SHIFT-1 prints as S1, MOUSEWHEELUP as WU.'},
		{'slider', 'Keybind size', 'actionbars.hotkeySize', 0, 16, 1, nil, format = Auto},
		{'segmented', 'Keybind spot', 'actionbars.hotkeyPoint', items = POSITIONS},
		{'slider', 'Count size', 'actionbars.countSize', 0, 18, 1, 'Charges and item counts.', format = Auto},
		{'segmented', 'Count spot', 'actionbars.countPoint', items = LOW_POSITIONS},
		{'switch', 'Macro names', 'actionbars.macros'},
		{'slider', 'Macro name size', 'actionbars.macroSize', 6, 12, 1},
	}},
	{title = 'Look', rows = {
		{'switch', 'Legend chip', 'actionbars.legendChip', 'Classic look: the keybind on a small label of the cap\'s own color.', since = '0.5.0',
			hidden = function() return HW.On() end},
		{'switch', 'Count chip', 'actionbars.countChip', 'Charges and item counts on a small gray LCD chip.', since = '0.5.0'},
		{'switch', 'State LED', 'actionbars.keyLed', 'A lamp on each key: lit while active, green when equipped; in the Hardware look also red out of range and blue short of power.', since = '0.5.0'},
		{'slider', 'Icon window inset', 'actionbars.iconInset', 0, 12, 1, 'How much of the cap shows around the icon.', format = Auto, since = '0.5.0'},
		{'slider', 'Empty key opacity', 'actionbars.emptyAlpha', 0.15, 1, 0.05, 'Classic look: keys with nothing on them are blank caps this faint.',
			hidden = function() return HW.On() end,
			format = function(v) return floor(v * 100 + 0.5)..'%' end, since = '0.5.0'},
	}},
	{title = 'Cooldowns', rows = {
		{'switch', 'Countdown numbers', 'actionbars.cdNumbers', 'Time left printed on the key, in the reference\'s typeface.'},
		{'slider', 'Number size', 'actionbars.cdSize', 0, 24, 1, nil, format = Auto},
		{'color', 'Number color', 'actionbars.cdColor'},
		{'slider', 'Hide below', 'actionbars.cdMin', 0, 10, 0.5, 'Shorter cooldowns (the global cooldown) show no numbers.', format = Seconds},
	}},
	{title = 'Feedback', rows = {
		{'color', 'Out of range', 'actionbars.rangeColor', 'The legend\'s tint when the target is too far.'},
		{'color', 'Out of power', 'actionbars.manaColor', 'The tint when there is not enough mana, energy or rage.'},
		{'color', 'Unusable', 'actionbars.unusableColor'},
		{'segmented', 'Proc glow', 'actionbars.glow', items = {{'pulse', 'Pulse'}, {'ring', 'Ring'}, {'off', 'Off'}},
			note = 'When a spell lights up: a lit ring with a slow pulse, the ring alone, or nothing.'},
		{'switch', 'Key sounds', 'sound.actionbars', 'A key press and release for every action.'},
		{'segmented', 'Lock bars', 'actionbars.lock', items = {{'game', 'Game'}, {'on', 'Locked'}, {'off', 'Free'}},
			note = 'Locked: drag spells off only with the pickup modifier. Game follows its own setting.'},
	}},
	{title = 'Side bars', rows = {
		{'switch', 'Side bars', 'actionbars.side', 'The right and left bars in their own device at the screen edge.', reload = true},
		{'segmented', 'Shape', 'actionbars.sideLayout', items = {{'columns', 'Columns'}, {'rows', 'Rows'}},
			note = 'Two columns down the edge, or two rows across.'},
	}},
	BarCard(1, 'Bar 1', 'The main bar; it pages with stances, forms and vehicles.', true),
	BarCard(2, 'Bar 2', 'Bottom left bar, in the console\'s second row.', true),
	BarCard(3, 'Bar 3', 'Bottom right bar, in the console\'s third row.', true),
	BarCard(4, 'Bar 4', 'Right bar, in the side device.', true),
	BarCard(5, 'Bar 5', 'Left bar, in the side device.', true),
	{title = 'Pet keys', rows = {
		{'switch', 'Pet keys', 'actionbars.pet', 'Pet actions on the console\'s top edge.', reload = true},
		{'slider', 'Key size', 'actionbars.barPet.keySize', 0, 40, 1, nil, format = Auto, reload = true},
		{'slider', 'Spacing', 'actionbars.barPet.spacing', 0, 12, 1, nil, reload = true},
		{'switch', 'Fade out of combat', 'actionbars.barPet.fade'},
		{'switch', 'Show on mouseover', 'actionbars.barPet.mouseover'},
		{'slider', 'Faded opacity', 'actionbars.barPet.fadeAlpha', 0, 1, 0.05, nil, format = Percent},
	}},
	{title = 'Stance keys', rows = {
		{'switch', 'Stance keys', 'actionbars.stance', 'Stances and forms on the console\'s top edge.', reload = true},
		{'slider', 'Key size', 'actionbars.barStance.keySize', 0, 40, 1, nil, format = Auto, reload = true},
		{'slider', 'Spacing', 'actionbars.barStance.spacing', 0, 12, 1, nil, reload = true},
		{'switch', 'Fade out of combat', 'actionbars.barStance.fade'},
		{'switch', 'Show on mouseover', 'actionbars.barStance.mouseover'},
		{'slider', 'Faded opacity', 'actionbars.barStance.fadeAlpha', 0, 1, 0.05, nil, format = Percent},
	}},
	{title = 'Menu', rows = MenuRows('menu', {
		{'segmented', 'Icons', 'actionbars.menuIcons', items = {{'glyphs', 'SPEC-01'}, {'blizzard', 'Blizzard'}}, since = '0.5.1',
			note = 'Printed SPEC-01 glyphs on the menu and bag keys, with a lamp that lights while a window is open and breathes when the game asks for attention.'},
	})},
	{title = 'Bags', rows = MenuRows('bags', {
		{'segmented', 'Bag slots', 'actionbars.bagIcons', items = {{'items', 'Bag icons'}, {'glyphs', 'Glyphs'}}, since = '0.5.1',
			note = 'Each bag\'s own icon, with a glyph only in an empty slot, or a glyph in every slot.',
			hidden = function() return DB().menuIcons == 'blizzard' end},
	})},
}})
