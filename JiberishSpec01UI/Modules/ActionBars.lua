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
-- The action bars span several files (ActionBarsKeys.lua, Console.lua,
-- ActionBarsMenu.lua, ActionBarsEvents.lua, ActionBarsDeck.lua,
-- ActionBarsModule.lua, loaded in that order); what they share lives in this table.
local P = {}
UI.ActionBarParts = P

local module = UI:RegisterModule('actionbars', {})
local function DB() return UI.db.actionbars end
local IsSecret, Forbidden = UI.Util.IsSecret, UI.Util.Forbidden
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
	-- The stance keys folded away behind their latch (a click on it brings them back).
	stanceFolded = false,
	-- The menu keys and function keys set into the console: just their icons on the housing (no keycaps).
	consoleBare = true,
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
	-- Docked frames: 'embedded' in bays cut into the housing (Hardware look),
	-- or 'float' on the console at their own size, as before.
	dockLook = 'embedded',
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


-- Shared with the other action bar files.
P.API = API
P.AUX = AUX
P.BAGS = BAGS
P.BarDB = BarDB
P.BarEnabled = BarEnabled
P.BARS = BARS
P.BarSize = BarSize
P.C = C
P.COL_GAP = COL_GAP
P.ColorOf = ColorOf
P.DB = DB
P.Deck = Deck
P.Docking = Docking
P.Fade = Fade
P.Flag = Flag
P.GAP = GAP
P.GetActionInfo = GetActionInfo
P.GetActionText = GetActionText
P.GetActionTexture = GetActionTexture
P.HasAction = HasAction
P.HEAD = HEAD
P.HPad = HPad
P.HW = HW
P.IsActionInRange = IsActionInRange
P.IsAutoRepeatAction = IsAutoRepeatAction
P.IsConsumableAction = IsConsumableAction
P.IsCurrentAction = IsCurrentAction
P.IsEquippedAction = IsEquippedAction
P.IsOverlayed = IsOverlayed
P.IsStackableAction = IsStackableAction
P.IsUsableAction = IsUsableAction
P.KeySize = KeySize
P.Legend = Legend
P.LightCap = LightCap
P.MICRO = MICRO
P.MODERN_COOLDOWNS = MODERN_COOLDOWNS
P.module = module
P.PAD = PAD
P.PerRow = PerRow
P.RANGE_EVENTS = RANGE_EVENTS
P.RETIRED_BARS = RETIRED_BARS
P.RETIRED_BUTTONS = RETIRED_BUTTONS
P.ROW_GAP = ROW_GAP
P.Rows = Rows
P.Shown = Shown
P.Smooth = Smooth
P.Sound = Sound
P.Spacing = Spacing
P.Sprites = Sprites
P.Surface = Surface
P.XPHeight = XPHeight
