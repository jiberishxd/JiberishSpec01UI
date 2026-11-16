-- The Theme page and the Fade module.
--
-- Theme: every appearance token the kit reads live (Kit:Look in Kit/Theme.lua):
-- border thickness, corner rounding, shadows, text scale, outline and shadow,
-- bar brightness, color softness, smooth bars, motion speed and the LCD's ghost
-- digits. A small sample device hangs under the hub while this page is open,
-- so a change shows on real SPEC-01 parts as the slider moves.
--
-- Fade: chosen parts of the interface rest at a low alpha while nothing is
-- happening (out of combat, full health, no target, not casting) and come back
-- for a fight, a target, a cast or the mouse. Alpha only: protected frames may
-- change alpha at any time, so nothing here waits for combat to end.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown = CreateFrame, UIParent, InCombatLockdown
local abs = math.abs

local function IsSecret(value) return issecretvalue and issecretvalue(value) end

-- defaults:begin
UI:RegisterDefaults('appearance', {
	borderPx = 1, rounding = 1, shadowSize = 1, shadowOpacity = 1,
	textScale = 1, textOutline = 'none', textShadow = false, ghostDigits = true,
	barBrightness = 1, softness = 0, smoothBars = true, motionScale = 1,
	fade = {enable = false, alpha = 0.25, openWorld = false,
		console = true, unitframes = true, minimap = false, chat = true, objectives = false, buffs = true},
})
-- Interface colors: each override replaces its tokens while its switch is on
-- (Kit:RGB). The colors saved here are the reference's own, a starting point.
UI:RegisterDefaults('colors', {
	housingOn = false, housing = {r = 0.984, g = 0.984, b = 0.98},
	screenOn = false, screen = {r = 0, g = 0, b = 0},
	lcdOn = false, lcd = {r = 0.761, g = 0.765, b = 0.741},
	lcdInkOn = false, lcdInk = {r = 0.078, g = 0.078, b = 0.075},
	lampOn = false, lamp = {r = 1, g = 0.702, b = 0.278},
	inkOn = false, ink = {r = 0.114, g = 0.114, b = 0.110},
	dimOn = false, dim = {r = 0.561, g = 0.553, b = 0.529},
	screenTextOn = false, screenText = {r = 0.949, g = 0.949, b = 0.933},
	edgeOn = false, edge = {r = 0.326, g = 0.310, b = 0.275},
	gradient = false,
	gradientColors = {from = {r = 1, g = 1, b = 1, a = 0.10}, to = {r = 0.33, g = 0.31, b = 0.27, a = 0.10}, dir = 'VERTICAL'},
})
-- Per-area typefaces ('__inherit' follows the interface's) and size multipliers.
UI:RegisterDefaults('fonts', {
	unitframes = '__inherit', nameplates = '__inherit', chat = '__inherit', keys = '__inherit', numbers = '__inherit', windows = '__inherit',
	unitframesScale = 1, nameplatesScale = 1, chatScale = 1, keysScale = 1, numbersScale = 1, windowsScale = 1,
})
-- defaults:end

-- The appearance tokens at their defaults, for the Reset button.
local TOKENS = {'borderPx', 'rounding', 'shadowSize', 'shadowOpacity', 'textScale', 'textOutline', 'textShadow', 'ghostDigits',
	'barBrightness', 'softness', 'smoothBars', 'motionScale'}

local function Percent(value) return format('%d%%', value * 100 + 0.5) end
local function Times(value) return format('%.2fx', value) end

-- Sample strip ---------------------------------------------------------------
-- A TS-1 device under the hub with one of each part the tokens touch. Its
-- parts are ordinary kit widgets, so Kit:Refresh repaints them with everything else.
local sample
local function Sample(hub)
	if sample then return sample end
	sample = Kit:Device(hub, {model = 'TS-1', title = 'Sample', width = 560, height = 96, radius = 12})
	sample:EnableMouse(true)
	local key = Kit:Key(sample, {tone = 'primary', text = 'Key', width = 72, height = 30})
	key:SetPoint('BOTTOMLEFT', 14, 16)
	local plain = Kit:Key(sample, {text = 'Cap', tone = 'dark', toggle = true, width = 72, height = 30})
	plain:SetPoint('LEFT', key, 'RIGHT', 10, 0)
	local switch = Kit:Switch(sample, {labels = false, checked = true})
	switch:SetPoint('LEFT', plain, 'RIGHT', 14, 0)
	local meter = Kit:Meter(sample, {label = 'Meter', width = 150, value = 0.64})
	meter:SetPoint('LEFT', switch, 'RIGHT', 16, -4)
	local lcd = Kit:LCD(sample, {tag = 'LCD', ghost = '888', text = '042', width = 70})
	lcd:SetPoint('LEFT', meter, 'RIGHT', 16, 4)
	Kit:Ghost(lcd.ghost)
	local glass = Kit:Screen(sample, {inset = 3, radius = 6})
	glass:SetSize(80, 34)
	glass:SetPoint('LEFT', lcd, 'RIGHT', 14, 0)
	local lamp = Kit:Led(glass.screen, 6, true)
	lamp:SetPoint('LEFT', 10, 0)
	local text = Kit:Label(glass.screen, 'Glass', 'darkInk', 9, true)
	text:SetPoint('LEFT', lamp, 'RIGHT', 6, 0)
	Kit:SetLed(sample.lamp, true)
	sample:Hide()
	return sample
end

-- The Theme page ---------------------------------------------------------------
local function ResetLook()
	local look = UI.db.appearance
	for _, key in ipairs(TOKENS) do look[key] = Kit.LOOK_FALLBACK[key] end
	Kit:Apply()
	UI:Print('Appearance reset to the reference look.')
end

local ACCENTS = {{'red', 'Red'}, {'yellow', 'Yellow'}, {'green', 'Green'}, {'blue', 'Blue'}, {'purple', 'Purple'}, {'ink', 'Ink'},
	{'class', 'Class color'}, {'custom', 'Custom'}}

UI:RegisterPage('theme', {title = 'Theme', order = 2,
	onShow = function(area)
		local hub = area:GetParent()
		local strip = Sample(hub)
		strip:ClearAllPoints()
		strip:SetPoint('TOP', hub, 'BOTTOM', 0, -6)
		strip:SetWidth(hub:GetWidth() * 0.7)
		Kit:ResetRest(strip)
		Kit:Open(strip)
	end,
	onHide = function()
		if sample and sample:IsShown() then Kit:Close(sample) end
	end,
	cards = {
	{title = 'Look', rows = {
		{'segmented', 'Finish', 'finish', items = {{'paper', 'Paper'}, {'graphite', 'Graphite'}}, note = 'Paper is the reference: off-white housings with warm hairlines, a molded side wall and soft shadows. Graphite darkens the same art.'},
		{'note', 'Typefaces, text size, outline and shadow are on the Fonts page.'},
		{'dropdown', 'Accent', 'accent', items = ACCENTS, note = 'The key color: primary keys, lamps and lit dots.'},
		{'color', 'Custom accent', 'customAccent', 'Used when the accent is Custom.',
			hidden = function() return UI.db.accent ~= 'custom' end},
		{'slider', 'Color softness', 'appearance.softness', 0, 1, 0.05, 'Lamps and status colors blend toward gray.', format = Percent},
		{'slider', 'Bar brightness', 'appearance.barBrightness', 0.6, 1.4, 0.05, 'How bright bar fills and lit dots are.', format = Percent},
	}},
	{title = 'Surfaces', rows = {
		{'slider', 'Housing opacity', 'housingAlpha', 0.6, 1, 0.01, 'How much of the world shows through housings.', format = Percent},
		{'slider', 'Border thickness', 'appearance.borderPx', 1, 3, 1, 'In screen pixels, so edges stay sharp.', format = function(v) return v..' px' end},
		{'slider', 'Corner rounding', 'appearance.rounding', 0.5, 1.5, 0.05, 'Scales every housing and display corner.', format = Times},
		{'slider', 'Shadow size', 'appearance.shadowSize', 0, 2, 0.05, 'How far housings cast their shadow. 0 turns shadows off.', format = Times},
		{'slider', 'Shadow opacity', 'appearance.shadowOpacity', 0, 2, 0.05, nil, format = Percent},
	}},
	{title = 'Motion', rows = {
		{'switch', 'Reduce motion', 'reduceMotion', 'Controls snap to place instead of animating.'},
		{'slider', 'Motion speed', 'appearance.motionScale', 0.5, 1.5, 0.05, 'Below 100% is quicker, above is slower.', format = Percent},
		{'switch', 'Smooth bars', 'appearance.smoothBars', 'Health and power bars glide to new values.'},
	}},
	{title = 'Screen', rows = {
		{'slider', 'UI scale', 'uiScale', 0.4, 1.15, 0.01, 'Kept even if the game or a resolution change moves it.', format = function(v) return format('%.2f', v) end},
		{'button', 'Pixel perfect', 'Set', function() UI.db.uiScale = UI.Pixel.PerfectScale(); Kit:Apply() end, 'One UI unit per screen pixel: the sharpest edges.'},
		{'switch', 'Keep UI scale', 'uiScaleLocked', 'Put this scale back whenever the game changes it.'},
		{'slider', 'Hub scale', 'scale', 0.6, 1.4, 0.05, 'Size of this window.', format = Percent},
		{'button', 'Frame positions', 'Reset', function() UI:ResetMovers() end, 'Every frame back to its default spot.'},
	}},
	{title = 'Theme', rows = {
		{'button', 'Repaint', 'Apply', function() Kit:Apply() end, 'Repaint everything now. Changes apply as you make them.'},
		{'button', 'Appearance', 'Reset', ResetLook, 'Borders, corners, shadows, type, bars and motion back to the reference.'},
	}},
	{title = 'Fade', rows = {
		{'switch', 'Fade when idle', 'appearance.fade.enable', 'Parts rest dim out of combat, at full health, with no target and no cast. The mouse, a target or a fight brings them back.'},
		{'slider', 'Resting opacity', 'appearance.fade.alpha', 0, 0.9, 0.05, nil, format = Percent},
		{'switch', 'Open world only', 'appearance.fade.openWorld', 'Keep everything up in dungeons, raids, battlegrounds and arenas.'},
		{'switch', 'Console and bars', 'appearance.fade.console'},
		{'switch', 'Unit frames', 'appearance.fade.unitframes'},
		{'switch', 'Minimap', 'appearance.fade.minimap'},
		{'switch', 'Chat', 'appearance.fade.chat'},
		{'switch', 'Objectives', 'appearance.fade.objectives'},
		{'switch', 'Buffs', 'appearance.fade.buffs'},
	}},
}})

-- The Colors page ---------------------------------------------------------------
-- The key color and every interface color, each set on the CX-1 color instrument.
local OVERRIDE_ROWS = {
	{'housing', 'Housing', 'The body of every device: Paper\'s off-white or Graphite\'s charcoal.'},
	{'edge', 'Edges', 'Housing outlines and printed hairlines.'},
	{'screen', 'Screens', 'The black glass behind displays and dark panels.'},
	{'screenText', 'Screen text', 'Text and readouts on black glass.'},
	{'lcd', 'LCD glass', 'The gray reflective LCD windows.'},
	{'lcdInk', 'LCD print', 'Digits and text on LCDs.'},
	{'lamp', 'Lamps', 'Lit LEDs, pointers and lamps (otherwise the key color).'},
	{'ink', 'Text', 'Printed text on housings.'},
	{'dim', 'Dim text', 'Legends, captions and secondary labels.'},
}

local colorRows = {
	{'dropdown', 'Key color', 'accent', items = ACCENTS, note = 'Primary keys, lamps and lit dots. The six are the reference\'s.'},
	{'color', 'Custom key', 'customAccent', 'Used when the key color is Custom.',
		hidden = function() return UI.db.accent ~= 'custom' end},
}
for _, entry in ipairs(OVERRIDE_ROWS) do
	local key = entry[1]
	colorRows[#colorRows + 1] = {'switch', entry[2], 'colors.'..key..'On', entry[3], since = '0.5.1'}
	colorRows[#colorRows + 1] = {'color', entry[2]..' color', 'colors.'..key,
		hidden = function() return not UI.db.colors[key..'On'] end}
end

local function ResetColors()
	for _, entry in ipairs(OVERRIDE_ROWS) do UI.db.colors[entry[1]..'On'] = false end
	UI.db.colors.gradient = false
	Kit:Apply()
	UI:Print('Interface colors back to the finish\'s own.')
end

UI:RegisterPage('colors', {title = 'Colors', order = 2.05, since = '0.5.1', cards = {
	{title = 'Interface colors', rows = colorRows},
	{title = 'Gradient', rows = {
		{'switch', 'Housing gradient', 'colors.gradient', 'A soft wash over every housing, lighter at the top and darker at the foot by default.', since = '0.5.1'},
		{'color', 'Gradient', 'colors.gradientColors', 'Two stops and a direction. Alpha sets how strong each end is.',
			hidden = function() return not UI.db.colors.gradient end},
	}},
	{title = 'Colors', rows = {
		{'button', 'Interface colors', 'Reset', ResetColors, 'Every override off; the finish\'s own colors return.'},
		{'note', 'Every color opens the CX-1 color instrument: turn the hue ring, set lightness, chroma and hue (or red, green and blue) on the encoders, type a hex code on the LCD, or pick a key, class or recent color. Changes show as you make them; Cancel puts the old color back.'},
	}},
}})

-- The Fonts page ----------------------------------------------------------------
-- One typeface for the whole interface, and per area a typeface and size of its
-- own. Changes repaint live: every string the kit made follows them.
local AREAS = {
	{'unitframes', 'Unit frames', 'Player, target, party, raid, boss and arena frames, and cast bars.'},
	{'nameplates', 'Nameplates', 'Names, levels and casts over units in the world.'},
	{'chat', 'Chat', 'SPEC-01 text on the chat windows and their tabs.'},
	{'keys', 'Action keys', 'Key bindings, counts and labels on the console and bars.'},
	{'numbers', 'Numbers and LCDs', 'Every LCD readout: health, timers, data texts, the HUD.'},
	{'windows', 'Windows', 'Text the kit draws on game windows and this hub.'},
}

local function FontItems() return Kit:FontChoices(false) end
local function AreaItems() return Kit:FontChoices(true) end

local fontRows = {
	{'dropdown', 'Typeface', 'font', items = FontItems,
		note = 'IBM Plex Mono is the reference\'s typeface and ships with the addon. Every LibSharedMedia font installed is listed too.'},
	{'slider', 'Text scale', 'appearance.textScale', 0.8, 1.3, 0.05, 'Every SPEC-01 label, readout and window text.', format = Percent},
	{'segmented', 'Outline', 'appearance.textOutline', items = {{'none', 'None'}, {'outline', 'Thin'}, {'thick', 'Thick'}},
		note = 'An outline helps text over the game world.'},
	{'switch', 'Text shadow', 'appearance.textShadow', 'A soft drop shadow under all text.'},
	{'switch', 'Ghost digits', 'appearance.ghostDigits', 'The unlit "888" segments behind LCD readouts.'},
}

local areaRows = {}
for _, area in ipairs(AREAS) do
	local key = area[1]
	areaRows[#areaRows + 1] = {'header', area[2]}
	areaRows[#areaRows + 1] = {'dropdown', 'Typeface', 'fonts.'..key, items = AreaItems, note = area[3], since = '0.5.1'}
	areaRows[#areaRows + 1] = {'slider', 'Size', 'fonts.'..key..'Scale', 0.7, 1.5, 0.05, nil, format = Percent, since = '0.5.1'}
end

local function ResetFonts()
	local fonts = UI.db.fonts
	for _, area in ipairs(AREAS) do
		fonts[area[1]] = '__inherit'
		fonts[area[1]..'Scale'] = 1
	end
	UI.db.font = '__default'
	local look = UI.db.appearance
	for _, key in ipairs({'textScale', 'textOutline', 'textShadow', 'ghostDigits'}) do look[key] = Kit.LOOK_FALLBACK[key] end
	Kit:Apply()
	UI:Print('Fonts reset to IBM Plex Mono.')
end

UI:RegisterPage('fonts', {title = 'Fonts', order = 2.1, since = '0.5.1', cards = {
	{title = 'Interface', rows = fontRows},
	{title = 'By area', rows = areaRows},
	{title = 'Fonts', rows = {
		{'button', 'Fonts', 'Reset', ResetFonts, 'Every area back to IBM Plex Mono at its own size.'},
		{'note', 'Fonts from other addons (LibSharedMedia) appear here once those addons are loaded. Text the game itself draws, such as chat messages, follows the Chat page.'},
	}},
}})

-- Fade ---------------------------------------------------------------------------
local fade = UI:RegisterModule('fade', {always = true})

local CONSOLE = {'JiberishSpec01Console', 'JiberishSpec01SideBars', 'JiberishSpec01PetKeys', 'JiberishSpec01StanceKeys',
	'JiberishSpec01Menu', 'JiberishSpec01ExtraHolder', 'JiberishSpec01ZoneHolder', 'MainActionBar', 'MainMenuBar',
	'MultiBarBottomLeft', 'MultiBarBottomRight', 'MultiBarLeft', 'MultiBarRight', 'StanceBar', 'PetActionBar', 'MicroMenuContainer',
	'BagsBar'}
for index = 1, 5 do CONSOLE[#CONSOLE + 1] = 'JiberishSpec01Bar'..index end

-- Each part: the top-level frames it covers right now. Only frames sitting
-- directly on UIParent are faded, so a child is never dimmed twice.
local PARTS = {
	console = function(list)
		for _, name in ipairs(CONSOLE) do list[#list + 1] = _G[name] end
	end,
	unitframes = function(list)
		local unitframes = UI.modules.unitframes
		if unitframes and unitframes.enabled and unitframes.frames then
			for _, frame in pairs(unitframes.frames) do list[#list + 1] = frame end
			list[#list + 1] = unitframes.playerCast
			list[#list + 1] = unitframes.targetCast
			list[#list + 1] = unitframes.partyHeader
		else
			for _, name in ipairs({'PlayerFrame', 'TargetFrame', 'FocusFrame', 'PetFrame', 'PartyFrame'}) do list[#list + 1] = _G[name] end
		end
	end,
	minimap = function(list) list[#list + 1] = _G.MinimapCluster end,
	chat = function(list)
		for index = 1, NUM_CHAT_WINDOWS or 10 do list[#list + 1] = _G['ChatFrame'..index] end
		list[#list + 1] = _G.GeneralDockManager
		list[#list + 1] = _G.ChatFrameMenuButton
		list[#list + 1] = _G.ChatFrameChannelButton
		list[#list + 1] = _G.QuickJoinToastButton
	end,
	objectives = function(list) list[#list + 1] = _G.ObjectiveTrackerFrame end,
	buffs = function(list)
		list[#list + 1] = _G.BuffFrame
		list[#list + 1] = _G.DebuffFrame
	end,
}
local PART_ORDER = {'console', 'unitframes', 'minimap', 'chat', 'objectives', 'buffs'}

local function DB() return UI.db.appearance.fade end

local function Usable(frame)
	if type(frame) ~= 'table' or not frame.SetAlpha or not frame.GetParent then return false end
	if frame.IsForbidden and frame:IsForbidden() then return false end
	return frame:GetParent() == UIParent
end

local function Frames(part)
	local list = {}
	PARTS[part](list)
	local usable = {}
	for _, frame in ipairs(list) do
		if Usable(frame) then usable[#usable + 1] = frame end
	end
	return usable
end

-- Lockdown starts after PLAYER_REGEN_DISABLED fires, so the event says it first.
local fighting = false

local function Casting()
	local duration = (UnitCastingDuration and UnitCastingDuration('player')) or (UnitChannelDuration and UnitChannelDuration('player'))
	if duration then return true end
	if UnitCastingDuration then return false end
	local name = UnitCastingInfo('player') or UnitChannelInfo('player')
	return IsSecret(name) or name ~= nil
end

local function FullHealth()
	local health, most = UnitHealth('player'), UnitHealthMax('player')
	if IsSecret(health) or IsSecret(most) then return false end
	return health >= most
end

-- Something is happening that every part should be up for.
local function Busy()
	if fighting or InCombatLockdown() then return true end
	if DB().openWorld and IsInInstance() then return true end
	if UnitExists('target') then return true end
	if Casting() or not FullHealth() then return true end
	local box = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
	if box then return true end
	return false
end

local function Hovered(frames)
	for _, frame in ipairs(frames) do
		if frame:IsVisible() and MouseIsOver(frame) then return true end
	end
	return false
end

-- Each frame remembers the alpha this module last chose for it, so it only
-- animates on a change and puts back what someone else moved meanwhile.
local chosen = setmetatable({}, {__mode = 'k'})

local function SetPart(frames, alpha, speed)
	for _, frame in ipairs(frames) do
		local current = frame:GetAlpha()
		-- Unlock mode's opacity and Hide stay in force under the fade.
		local alpha = alpha * (UI.MoverAlphaFor and UI:MoverAlphaFor(frame) or 1)
		if chosen[frame] ~= alpha or (not IsSecret(current) and abs(current - alpha) > 0.02 and not Kit:Animating(frame)) then
			chosen[frame] = alpha
			Kit:FadeTo(frame, alpha, speed)
		end
	end
end

local ticker
local function Restore()
	for frame in pairs(chosen) do
		if Usable(frame) then Kit:FadeTo(frame, UI.MoverAlphaFor and UI:MoverAlphaFor(frame) or 1, 'FAST') end
	end
	wipe(chosen)
end

local function Tick()
	local db = DB()
	if not db.enable then return end
	-- Pet battles hide the console and its frames themselves.
	if C_PetBattles and C_PetBattles.IsInBattle and C_PetBattles.IsInBattle() then return end
	local busy = Busy()
	for _, part in ipairs(PART_ORDER) do
		local frames = Frames(part)
		if db[part] then
			local awake = busy or Hovered(frames)
			SetPart(frames, awake and 1 or db.alpha, awake and 'FAST' or 'SLOW')
		else
			SetPart(frames, 1, 'FAST')
		end
	end
end

local function Update()
	local on = DB().enable
	if on and not ticker then
		ticker = C_Timer.NewTicker(0.15, function() UI:Safe(Tick) end)
		Tick()
	elseif not on and ticker then
		ticker:Cancel()
		ticker = nil
		Restore()
	end
end

function fade:Enable()
	local driver = CreateFrame('Frame')
	driver:RegisterEvent('PLAYER_REGEN_DISABLED')
	driver:RegisterEvent('PLAYER_REGEN_ENABLED')
	driver:RegisterEvent('PLAYER_TARGET_CHANGED')
	driver:SetScript('OnEvent', function(_, event)
		if event == 'PLAYER_REGEN_DISABLED' then fighting = true
		elseif event == 'PLAYER_REGEN_ENABLED' then fighting = false end
		if ticker then UI:Safe(Tick) end
	end)
	Update()
end

function fade:Refresh() Update() end
