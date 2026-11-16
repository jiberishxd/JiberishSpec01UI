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
	-- The console's look: SPEC-01 hardware (keys in slots, printed banks, screws,
	-- page LCD) or the earlier classic look.
	look = 'hardware',
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
--   * modules have a screw in each corner and a model plate in the header;
--   * the console carries a page LCD (with unlit ghost digits) and page lamps,
--     and the meter along its base has a printed legend and an LCD percent.
-- 'Classic' keeps the earlier look. Everything here is in one table, so the
-- file's main chunk stays well under Lua's limit of 200 locals.
local HW = {}
function HW.On() return DB().look ~= 'classic' end

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

-- A screw in each corner of a module, as hardware.css draws them, and a
-- larger model plate in the header.
function HW.Decorate(device, radius)
	if not HW.On() then return end
	local dark = Surface() == 'dark'
	local inset = max(6, floor((radius or 12) * 0.5 + 0.5))
	device.screws = device.screws or {}
	for index, point in ipairs({'TOPLEFT', 'TOPRIGHT', 'BOTTOMLEFT', 'BOTTOMRIGHT'}) do
		local screw = device.screws[index]
		if not screw then
			screw = Kit:Texture(device, 'circle', 'BORDER', 1)
			screw.slot = device:CreateTexture(nil, 'BORDER', nil, 2)
			screw.slot:SetColorTexture(0, 0, 0, 1)
			screw.slot:SetPoint('CENTER', screw, 'CENTER')
			screw.slot:SetRotation(math.rad(index % 2 == 0 and 45 or -45))
			device.screws[index] = screw
		end
		screw:SetSize(5, 5)
		screw:ClearAllPoints()
		local sx = point:find('LEFT') and inset or -inset
		local sy = point:find('TOP') and -inset or inset
		screw:SetPoint('CENTER', device, point, sx, sy)
		if dark then screw:SetVertexColor(0.24, 0.24, 0.23, 1) else screw:SetVertexColor(0.725, 0.725, 0.70, 1) end
		screw.slot:SetSize(4, 1)
		screw.slot:SetAlpha(dark and 0.6 or 0.28)
	end
	HW.ShowDecor(device, DB().housing ~= false)
	-- The plate: the lamp moves clear of the corner screw and the model prints larger.
	if device.lamp and device.model then
		device.lamp:ClearAllPoints()
		device.lamp:SetPoint('TOPLEFT', inset + 9, -9)
		Kit:Font(device.model, 11, nil, false)
	end
end

function HW.ShowDecor(device, shown)
	for _, screw in ipairs(device and device.screws or {}) do
		screw:SetShown(shown)
		screw.slot:SetShown(shown)
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
	local device = Kit:Device(UIParent, {name = name, model = model, title = title, surface = Surface(), radius = opts.radius or 12,
		header = opts.header, template = opts.template})
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

local function UpdateXP()
	if not xp then return end
	if not DB().xpbar then xp:Hide() return end
	local readout = console and console.readout
	local ok = pcall(function()
		local level = UnitLevel('player')
		local cap = (GetMaxLevelForPlayerExpansion and GetMaxLevelForPlayerExpansion()) or MAX_PLAYER_LEVEL or level
		local current, total = UnitXP('player'), UnitXPMax('player')
		local plain = not (IsSecret(level) or IsSecret(cap) or IsSecret(current) or IsSecret(total))
		if plain and level < cap and total and total > 0 and not (IsXPUserDisabled and IsXPUserDisabled()) then
			xp.bar:SetMinMaxValues(0, total)
			xp.bar:SetValue(current, Smooth())
			Kit:Tint(xp.bar, 'lamp')
			local rested = GetXPExhaustion and GetXPExhaustion()
			xp.tip = {format('Level %d  %d / %d (%.1f%%)', level, current, total, current / total * 100)}
			if not IsSecret(rested) and rested and rested > 0 then xp.tip[2] = format('Rested %d', rested) end
			if readout then readout:SetText(Readout(format('LV %d  %4.1f%%', level, current / total * 100))) end
			HW.MeterText(xp, 'XP', format('%4.1f%%', current / total * 100))
			xp:SetShown(DB().xpbar)
			return
		end
		local data = C_Reputation and C_Reputation.GetWatchedFactionData and C_Reputation.GetWatchedFactionData()
		local name, low, high, value
		if type(data) == 'table' then
			name, low, high, value = data.name, data.currentReactionThreshold, data.nextReactionThreshold, data.currentStanding
		elseif GetWatchedFactionInfo then
			local standing
			name, standing, low, high, value = GetWatchedFactionInfo()
		end
		if not IsSecret(name) and not IsSecret(low) and not IsSecret(high) and not IsSecret(value) and name and low and high and value then
			local span = max(high - low, 1)
			xp.bar:SetMinMaxValues(0, span)
			xp.bar:SetValue(min(max(value - low, 0), span), Smooth())
			Kit:Tint(xp.bar, 'green')
			xp.tip = {format('%s  %d / %d', name, value - low, span)}
			if readout then readout:SetText(Readout(format('LV %s  REP', plain and level or '??'))) end
			HW.MeterText(xp, 'Rep', format('%4.1f%%', min(max(value - low, 0), span) / span * 100))
			xp:SetShown(DB().xpbar)
			return
		end
		xp.tip = nil
		if readout then readout:SetText(Readout(plain and format('LV %d  MAX', level) or 'LV ??')) end
		HW.MeterText(xp, 'XP', 'MAX')
		xp.bar:SetMinMaxValues(0, 1)
		xp.bar:SetValue(1)
		Kit:Tint(xp.bar, 'dim')
	end)
	if not ok and readout then readout:SetText('') end
end

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
	frame:HookScript('OnHide', function() if frame.docked then slot:Show() end end)
end

-- The console ----------------------------------------------------------------------------
local function UnitParts()
	local unitframes = UI.modules.unitframes
	if not (Docking() and DB().dock and unitframes and unitframes.enabled and unitframes.frames) then return {} end
	return {player = unitframes.frames.player, target = unitframes.frames.target, playerCast = unitframes.playerCast,
		targetCast = unitframes.targetCast, module = unitframes}
end

-- Docked unit frames hide with the console in pet battles. Alpha only: they are
-- secure unit buttons, and alpha can change at any time.
local function HideDocked(hidden)
	for key, part in pairs(UnitParts()) do
		if key ~= 'module' and part and part.SetAlpha then part:SetAlpha(hidden and 0 or 1) end
	end
end

local function LayoutConsole()
	if not console then return end
	if InCombatLockdown() then return UI:AfterCombat(LayoutConsole, 'ab.layout') end
	local size = KeySize()
	-- The keyboard: each bar one row, as wide as its shown keys, centered.
	local width, height = 0, 0
	local bank = HW.On() and HW.BANK_H or 0
	for _, bar in ipairs(console.bars) do
		LayoutBar(bar, size, Spacing(bar.id), Shown(bar.id), 12, false)
		width = max(width, bar.width)
		height = height + bar.height + bank
	end
	height = height + max(#console.bars - 1, 0) * GAP
	if width == 0 then width, height = 12 * size + 11 * GAP, size end
	local PAD = HPad()
	local parts = UnitParts()
	local scale = console:GetEffectiveScale()
	local function Measure(frame)
		if not frame then return 0, 0, 1 end
		local ratio = frame:GetEffectiveScale() / scale
		return frame:GetWidth() * ratio, frame:GetHeight() * ratio, ratio
	end
	local pw, ph = Measure(parts.player)
	local tw, th = Measure(parts.target)
	local column = max(pw, tw)
	local sideWidth = column > 0 and column + COL_GAP or 0
	local body = max(height, max(ph, th) > 0 and max(ph, th) + AUX or 0)
	local _, playerCastHeight = Measure(parts.playerCast)
	local _, targetCastHeight = Measure(parts.targetCast)
	local castHeight = max(playerCastHeight, targetCastHeight)
	local xpHeight = DB().xpbar and XPHeight() + ROW_GAP or 0
	console:SetSize(PAD * 2 + width + sideWidth * 2, HEAD + body + (castHeight > 0 and castHeight + ROW_GAP or 0) + xpHeight + PAD)
	local left = PAD + sideWidth

	-- Bar 1 is the bottom row, as on Blizzard's bars. In the Hardware look each
	-- bank has its printed legend and rule above it.
	local y = -HEAD
	for index = #console.bars, 1, -1 do
		local bar = console.bars[index]
		local x = left + (width - bar.width) / 2
		if bar.bank then HW.PlaceBank(bar.bank, console, x - 2, y, bar.width + 4, bank > 0) end
		y = y - bank
		bar.header:ClearAllPoints()
		bar.header:SetPoint('TOPLEFT', console, 'TOPLEFT', x, y)
		y = y - bar.height - GAP
	end

	-- Docked unit frames and cast bars, anchored in console units.
	-- An LCD-style frame keeps its own LCD face; paper and dark ones sit on the housing.
	local keepShell = UI:Style('unitframes') == 'lcd'
	local function Dock(frame, moverKey, point, x, y)
		if not frame then return end
		parts.module:SetDocked(frame, true, keepShell)
		UI:DockMover(moverKey, function(docked)
			local ratio = docked:GetEffectiveScale() / console:GetEffectiveScale()
			docked:SetPoint(point, console, point, x / ratio, y / ratio)
		end)
	end
	-- Each frame is centred on the keyboard's height when it is shorter (a bar or
	-- square shape), never so low that its class lamps or auras leave the body.
	local function Drop(frameHeight)
		if frameHeight <= 0 then return 0 end
		return max(0, min((height - frameHeight) / 2, body - frameHeight - AUX))
	end
	Dock(parts.player, 'uf.player', 'TOPLEFT', PAD + (column - pw) / 2, -HEAD - Drop(ph))
	Dock(parts.target, 'uf.target', 'TOPRIGHT', -PAD - (column - tw) / 2, -HEAD - Drop(th))
	if parts.target and console.targetSlot then
		console.targetSlot:SetSize(tw, th)
		console.targetSlot:ClearAllPoints()
		console.targetSlot:SetPoint('TOPRIGHT', console, 'TOPRIGHT', -PAD - (column - tw) / 2, -HEAD - Drop(th))
	end
	local castWidth = (width - 8) / 2
	local castY = -HEAD - body - ROW_GAP
	for index, cast in ipairs({parts.playerCast or false, parts.targetCast or false}) do
		if cast then
			local _, _, ratio = Measure(cast)
			cast:SetWidth(castWidth / ratio)
			local x = left + (index - 1) * (castWidth + 8)
			Dock(cast, index == 1 and 'cb.player' or 'cb.target', 'TOPLEFT', x, castY)
			local slot = console.castSlots[index]
			slot:SetSize(castWidth, castHeight)
			slot:ClearAllPoints()
			slot:SetPoint('TOPLEFT', console, 'TOPLEFT', x, castY)
		end
	end
	if xp then
		xp:SetShown(DB().xpbar and true or false)
		HW.PlaceMeter(xp, console, PAD, PAD, PAD, XPHeight())
	end
	if console.lcd then console.lcd:SetShown(DB().readout ~= 'off') end
	-- Pet and stance modules sit on the console's top edge, tucked under it.
	if stanceModule then
		stanceModule:ClearAllPoints()
		stanceModule:SetPoint('BOTTOMLEFT', console, 'TOPLEFT', left - 8, -8)
	end
	if petModule then
		petModule:ClearAllPoints()
		petModule:SetPoint('BOTTOMRIGHT', console, 'TOPRIGHT', -left + 8, -8)
	end
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
	local parts = UnitParts()
	if parts.target then
		console.targetSlot = Slot(console, 'No target')
		Follow(console.targetSlot, parts.target)
	end
	-- The cast slots only hold the space: a cast bar appears there when a cast
	-- starts, and nothing is printed while nothing is casting.
	console.castSlots = {Slot(console, ''), Slot(console, '')}
	for _, slot in ipairs(console.castSlots) do slot:Hide() end
	xp = BuildXP(console)
	if console.pager and BARS[1].header then HW.ShowPage(console.pager, BARS[1].header:GetAttribute('actionpage') or 1) end
	UI:RegisterMover(console, 'ab.console', 'Console', {'BOTTOM', 0, 12})
end

-- Free layout: every bar is its own device.
-- Free layout: every bar is its own device, sized to its keys.
local function LayoutFree()
	if InCombatLockdown() then return UI:AfterCombat(LayoutFree, 'ab.free') end
	for row = 1, Rows() do
		local bar, device = BARS[row], BARS[row].device
		if device then
			local width, height = LayoutBar(bar, BarSize(row, KeySize()), Spacing(row), Shown(row), PerRow(row), false)
			local extra = (row == 1 and xp and DB().xpbar) and XPHeight() + ROW_GAP or 0
			device:SetSize(width + PAD * 2, height + PAD * 2 + extra)
			if row == 1 and xp then
				xp:SetShown(DB().xpbar and true or false)
				HW.PlaceMeter(xp, device, PAD, PAD, PAD, XPHeight())
			end
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
				HW.PlaceMeter(xp, device, PAD, PAD, PAD, XPHeight())
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
	local size, spacing = petModule.keySize, Spacing('Pet')
	for index, button in pairs(petKeys) do
		if button:GetParent() ~= petModule then button:SetParent(petModule) end
		button:ClearAllPoints()
		button:SetPoint('LEFT', PAD + (index - 1) * (size + spacing), (Docking() and 4 or 0) - (HW.On() and HW.BANK_H / 2 or 0))
		button:Show()
	end
end

local function BuildPet()
	local size = BarSize('Pet', max(20, floor(KeySize() * 0.72)))
	local count = NUM_PET_ACTION_SLOTS or 10
	petModule = Device('JiberishSpec01PetKeys', 'PT-1', '', {header = false, template = 'SecureHandlerStateTemplate', radius = 9, level = 4})
	petModule:SetSize(PAD + count * size + (count - 1) * Spacing('Pet') + PAD, size + 16 + (HW.On() and HW.BANK_H or 0))
	petModule.keySize = size
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
	local size = stanceModule.size
	for index, button in ipairs(stanceKeys) do button:SetShown(index <= forms) end
	stanceModule:SetShown(forms > 0)
	if forms > 0 then stanceModule:SetWidth(PAD + forms * size + (forms - 1) * Spacing('Stance') + PAD) end
	UpdateStance()
end

local function BuildStance()
	local size = BarSize('Stance', max(20, floor(KeySize() * 0.72)))
	stanceModule = Device('JiberishSpec01StanceKeys', 'ST-1', '', {header = false, radius = 9, level = 4})
	stanceModule.size = size
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
-- Kept in a block of its own: the main chunk may hold at most 200 locals.
local RepaintMenu, LayoutMenu, BuildMenu
do
local MENU_ICONS = {'character', 'spellbook', 'talents', 'professions', 'achievements', 'legacy', 'quest', 'guild',
	'social', 'finder', 'journal', 'collections', 'menu', 'help', 'store', 'house',
	'map', 'pvp', 'backpack', 'bag', 'reagent', 'key'}
local MENU_INDEX = {}
for index, name in ipairs(MENU_ICONS) do MENU_INDEX[name] = index - 1 end
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
		local size = floor(min(button:GetWidth(), button:GetHeight()) * (isBag and 0.6 or 0.68) + 0.5)
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
function LayoutMenu()
	if not menu or laying then return end
	laying = true
	local ok, problem = pcall(function()
	local x, tallest = PAD, 0
	local function Place(button, size)
		if not button or Forbidden(button) then return end
		Guard(button)
		if button:GetParent() ~= menu then button:SetParent(menu) end
		if size then button:SetSize(size, size) end
		DressMenuButton(button)
		if not button:IsShown() then return end
		button:ClearAllPoints()
		button:SetPoint('BOTTOMLEFT', menu, 'BOTTOMLEFT', x, PAD)
		x = x + button:GetWidth() + 3
		tallest = max(tallest, button:GetHeight())
	end
	for _, name in ipairs(MICRO) do Place(_G[name]) end
	x = x + 8
	-- Bag slots match the menu keys: one size, one row.
	local keySize = tallest > 0 and tallest or 30
	for _, name in ipairs(BAGS) do
		local button = _G[name]
		if button then button:Show() end
		Place(button, keySize)
	end
	-- Clients with a key ring: placed only while the game shows it.
	Place(_G.KeyRingButton, keySize)
	menu:SetSize(x - 3 + PAD, HEAD + tallest + PAD)
	end)
	laying = nil
	if not ok then error(problem, 0) end
	-- The game re-sets its micro button art as it updates them; fade it again.
	RepaintMenu()
end

local function QueueMenu() C_Timer.After(0, function() UI:Safe(LayoutMenu) end) end

function BuildMenu()
	menu = Device('JiberishSpec01Menu', 'MN-1', 'Menu', {radius = 12})
	HW.Decorate(menu, 12)
	menu:SetScale((DB().scale or 1) * 0.8)
	LayoutMenu()
	UI:RegisterMover(menu, 'ab.menu', 'Menu and bags', {'BOTTOMRIGHT', -12, 12})
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

end
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
		if event == 'PLAYER_ENTERING_WORLD' then Queue('pet'); Queue('stanceLayout'); Queue('xp'); Queue('leave'); Queue('menu') end
		if event == 'PLAYER_TARGET_CHANGED' then Queue('range') end
	end
end

function module:Enable()
	if InCombatLockdown() then
		UI:AfterCombat(function() self.enabled = UI:Safe(self.Enable, self) end, 'actionbars')
		return
	end
	local db = DB()
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
	if menu then
		UI:SetMoverBaseScale('ab.menu', scale * 0.8, menu)
		if menu.shell then menu.shell:SetShown(DB().housing ~= false) end
		HW.ShowDecor(menu, DB().housing ~= false)
		RepaintMenu()
	end
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
			since = '0.5.1', note = 'Hardware: keys set in slots in the housing, legends printed on the caps, printed banks, corner screws, a page LCD and a meter with its own LCD, as on SPEC-01\'s devices. Classic: the earlier look.'},
		{'segmented', 'Layout', 'actionbars.layout', items = {{'console', 'Console'}, {'free', 'Free'}}, reload = true,
			note = 'Console: one device with the player and target docked beside the keys. Free: every bar on its own.'},
		{'switch', 'Dock unit frames', 'actionbars.dock', 'Player and target frames and cast bars inside the console.', reload = true},
		{'switch', 'Housing', 'actionbars.housing', 'The device housings around the keys.'},
		{'slider', 'Rows', 'actionbars.rows', 1, 3, 1, 'Bars in the console: bar 1, then the bottom left and right bars.', reload = true},
		{'slider', 'Key size', 'actionbars.keySize', 24, 48, 1, 'Width of each key in the console.'},
		{'slider', 'Side padding', 'actionbars.padding', 0, 60, 2, 'Extra room at the console\'s sides.'},
		{'slider', 'Scale', 'actionbars.scale', 0.6, 1.6, 0.05, 'Size of every action bar device.', format = Percent},
		{'button', 'Placement', 'Move bars', function() UI:ToggleHub(nil, false); UI:ToggleMovers() end, 'Snaps to a grid and to other frames.'},
	}},
	{title = 'Meter and readout', rows = {
		{'switch', 'Experience meter', 'actionbars.xpbar', 'Experience, or the watched reputation, as lit dots along the base.', reload = true},
		{'slider', 'Meter height', 'actionbars.xpHeight', 4, 16, 1},
		{'segmented', 'Console LCD', 'actionbars.readout', items = {{'level', 'Level'}, {'clock', 'Clock'}, {'off', 'Off'}},
			note = 'Level and progress, the time, or no LCD.'},
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
	{title = 'Menu and bags', rows = {
		{'segmented', 'Icons', 'actionbars.menuIcons', items = {{'glyphs', 'SPEC-01'}, {'blizzard', 'Blizzard'}}, since = '0.5.1',
			note = 'Printed SPEC-01 glyphs on the menu and bag keys, with a lamp that lights while a window is open and breathes when the game asks for attention.'},
		{'segmented', 'Bag slots', 'actionbars.bagIcons', items = {{'items', 'Bag icons'}, {'glyphs', 'Glyphs'}}, since = '0.5.1',
			note = 'Each bag\'s own icon, with a glyph only in an empty slot, or a glyph in every slot.',
			hidden = function() return DB().menuIcons == 'blizzard' end},
	}},
}})
