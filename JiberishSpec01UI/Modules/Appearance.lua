-- The Theme page and the Fade module.
--
-- Theme: every appearance token the kit reads live (Kit:Look in Kit/Theme.lua):
-- border thickness, corner rounding, shadows, text scale, outline and shadow,
-- bar brightness, color softness, smooth bars, motion speed and the LCD's ghost
-- digits. A small sample device hangs under the hub while this page is open,
-- so a change shows on real SPEC-01 parts as the slider moves.
--
-- Fade: chosen parts of the interface rest at a low alpha (or out of sight)
-- whenever nothing calls for them: out of combat by default, or only when fully
-- idle, or always unless one of the chosen "show when" triggers holds. Alpha
-- only: protected frames may change alpha at any time, so nothing here waits
-- for combat to end.
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
	-- mode: 'combat' (faded whenever out of combat), 'idle' (also needs no target, no
	-- cast, full health) or 'always' (faded unless a trigger holds).
	fade = {enable = false, mode = 'combat', alpha = 0.3, delay = 2, fadeOut = 0.6, fadeIn = 0.15,
		mountedMore = false, mountedAlpha = 0.1, advanced = false,
		-- How parts change state (see STYLES), and the sounds they make doing it.
		style = 'smooth', sound = true, soundScope = 'console', dimSound = 'latch-up', wakeSound = 'latch-down',
		triggers = {combat = true, target = false, casting = false, health = false, power = false, mouseover = true,
			group = false, instance = false, resting = false},
		-- Each part: on, and its own faded opacity (-1: the global one; 0: out of sight).
		parts = {
			console = {on = true, alpha = -1, style = 'global'}, side = {on = true, alpha = -1, style = 'global'},
			menu = {on = true, alpha = -1, style = 'global'}, unitframes = {on = true, alpha = -1, style = 'global'},
			castbars = {on = false, alpha = -1, style = 'global'}, group = {on = false, alpha = -1, style = 'global'},
			minimap = {on = false, alpha = -1, style = 'global'}, chat = {on = true, alpha = -1, style = 'global'},
			objectives = {on = false, alpha = -1, style = 'global'}, buffs = {on = true, alpha = -1, style = 'global'},
			timeline = {on = false, alpha = -1, style = 'global'}, meters = {on = false, alpha = -1, style = 'global'},
			infopanel = {on = false, alpha = -1, style = 'global'},
		},
	},
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
-- Housings per group: a color ('default' keeps the finish's), a gradient, a material and its strength.
UI:RegisterDefaults('housing', {
	console = {color = 'default', custom = {r = 0.957, g = 0.957, b = 0.945}, gradient = false, material = 'matte', strength = 0.5,
		gradientColors = {from = {r = 1, g = 1, b = 1, a = 0.12}, to = {r = 0, g = 0, b = 0, a = 0.12}, dir = 'VERTICAL'}},
	unitframes = {color = 'default', custom = {r = 0.957, g = 0.957, b = 0.945}, gradient = false, material = 'matte', strength = 0.5,
		gradientColors = {from = {r = 1, g = 1, b = 1, a = 0.12}, to = {r = 0, g = 0, b = 0, a = 0.12}, dir = 'VERTICAL'}},
	devices = {color = 'default', custom = {r = 0.957, g = 0.957, b = 0.945}, gradient = false, material = 'matte', strength = 0.5,
		gradientColors = {from = {r = 1, g = 1, b = 1, a = 0.12}, to = {r = 0, g = 0, b = 0, a = 0.12}, dir = 'VERTICAL'}},
	screens = {color = 'default', custom = {r = 0, g = 0, b = 0}, gradient = false, material = 'matte', strength = 0.3,
		gradientColors = {from = {r = 1, g = 1, b = 1, a = 0.06}, to = {r = 0, g = 0, b = 0, a = 0}, dir = 'VERTICAL'}},
})
-- Per-area typefaces ('__inherit' follows the interface's) and size multipliers.
UI:RegisterDefaults('fonts', {
	unitframes = '__inherit', nameplates = '__inherit', chat = '__inherit', keys = '__inherit', numbers = '__inherit', windows = '__inherit',
	unitframesScale = 1, nameplatesScale = 1, chatScale = 1, keysScale = 1, numbersScale = 1, windowsScale = 1,
	-- Text the game draws in the world, read once as a character loads: names
	-- over characters and floating combat text ('__keep' leaves the game's).
	worldNames = '__keep', combatText = '__keep', combatTextScale = 1,
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

-- UI scale: rescaling the interface while a slider is dragged moves the
-- slider out from under the cursor, so presets apply at once and the fine
-- slider only picks a value until Apply.
local pendingScale
local function ApplyScale(value)
	pendingScale = nil
	if InCombatLockdown() then
		UI:Print('The UI scale changes once you leave combat.')
	end
	UI.Pixel.SetScale(value)
	Kit:Play('latch-down', true)
end

local function ScalePresets()
	local perfect = math.floor(UI.Pixel.PerfectScale() * 100 + 0.5) / 100
	return {{perfect, 'Pixel'}, {0.64, '0.64'}, {0.71, '0.71'}, {0.8, '0.80'}, {0.9, '0.90'}, {1, '1.00'}}
end

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
		{'segmented', 'UI scale', 'uiScale', items = ScalePresets, set = ApplyScale,
			note = 'Sets the scale at once. Pixel is one UI unit per screen pixel, the sharpest edges.'},
		{'slider', 'Fine scale', 'uiScale', 0.4, 1.15, 0.01, 'Pick a value, then press Apply below; the interface does not rescale while you drag.',
			format = function(v) return format('%.2f', v) end,
			get = function() return pendingScale or UI.db.uiScale or UIParent:GetScale() end,
			set = function(value) pendingScale = value end},
		{'button', 'Apply fine scale', 'Apply', function()
			if pendingScale then ApplyScale(pendingScale) end
		end, 'Sets the value chosen on the Fine scale slider.'},
		{'switch', 'Keep UI scale', 'uiScaleLocked', 'Put this scale back whenever the game changes it.'},
		{'slider', 'Hub scale', 'scale', 0.6, 1.4, 0.05, 'Size of this window.', format = Percent},
		{'button', 'Frame positions', 'Reset', function() UI:ResetMovers() end, 'Every frame back to its default spot.'},
	}},
	{title = 'Theme', rows = {
		{'button', 'Repaint', 'Apply', function() Kit:Apply() end, 'Repaint everything now. Changes apply as you make them.'},
		{'button', 'Appearance', 'Reset', ResetLook, 'Borders, corners, shadows, type, bars and motion back to the reference.'},
	}},
	{title = 'Fade', rows = {
		{'note', 'Fading parts of the interface out of combat has its own page: General > Fade.'},
		{'button', 'Fade settings', 'Open', function() UI:ToggleHub('fade', true) end, 'Mode, triggers, parts and timing.'},
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

-- The Housing page --------------------------------------------------------------
-- Color, gradient and material for each group of housings, a live preview of
-- all four, and presets that set them together.
local GROUPS = {
	{'console', 'Console', 'The CX-1 console along the bottom, and the bars and menu devices.'},
	{'unitframes', 'Unit frames', 'Player, target, party, raid, boss and arena devices.'},
	{'devices', 'Other devices', 'Every other housing: windows, the hub, bags, the minimap, meters, the info panel.'},
	{'screens', 'Screens and LCDs', 'Black glass displays (color and material) and the gray LCDs (material only).'},
}

local function ColorItems()
	local items = {}
	for _, entry in ipairs(Kit.HOUSING_COLORS) do items[#items + 1] = {entry[1], entry[2]} end
	return items
end
local function MaterialItems()
	local items = {}
	for _, entry in ipairs(Kit.MATERIALS) do items[#items + 1] = {entry.key, entry.name} end
	return items
end

local function Group(key) return UI.db.housing[key] end

local function ResetGroup(key)
	local defaults = UI.defaults and UI.defaults.housing and UI.defaults.housing[key]
	local entry = Group(key)
	entry.color, entry.gradient, entry.material = 'default', false, 'matte'
	entry.strength = defaults and defaults.strength or 0.5
	Kit:Apply()
end

-- Presets: a color and a material for the console, unit frames and devices
-- (screens keep theirs). Light presets suit Paper, dark ones Graphite.
local PRESETS = {
	{'Studio white', 'studio', 'plastic', 0.35, 'Clean molded white, as the reference.'},
	{'Graphite', 'graphite', 'bead', 0.45, 'Charcoal, bead-blasted.'},
	{'Brushed steel', 'steel', 'brushed', 0.7, 'Cool grey with a long brushed grain.'},
	{'Machined aluminium', 'aluminium', 'machined', 0.6, 'Bright metal with fine tool marks.'},
	{'Etched black', 'black', 'etched', 0.55, 'Black anodized with fine engraved hatching.'},
	{'Worn gunmetal', 'gunmetal', 'worn', 0.7, 'Dark brushed metal, scuffed and polished by use.'},
	{'Paper', 'bone', 'paper', 0.6, 'Warm bone white with a paper tooth.'},
	{'Carbon', 'carbon', 'carbon', 0.75, 'A 2 x 2 carbon fibre twill.'},
}

local function ApplyPreset(preset)
	for _, key in ipairs({'console', 'unitframes', 'devices'}) do
		local entry = Group(key)
		entry.color, entry.material, entry.strength, entry.gradient = preset[2], preset[3], preset[4], false
	end
	Kit:Apply()
	UI:Print(format('Housings: %s.', preset[1]))
end

local function ResetHousing()
	for _, group in ipairs(GROUPS) do ResetGroup(group[1]) end
	UI:Print('Housings back to the finish.')
end

-- The live preview: one small device per group, each wearing its group's look.
local preview
local function ShowPreview(area)
	local card
	for _, child in ipairs({area.content:GetChildren()}) do
		local title = child.title and child.title.GetText and child.title:GetText()
		if type(title) == 'string' and strupper(title) == 'PREVIEW' then card = child break end
	end
	if not card then return end
	if not preview then
		preview = CreateFrame('Frame', nil, card.body)
		preview.devices = {}
		for index, group in ipairs(GROUPS) do
			local surface = group[1] == 'screens' and 'dark' or 'paper'
			local device = Kit:Device(preview, {model = ({'CX-1', 'UF-1', 'DV-1', 'SC-1'})[index], title = group[2],
				width = 132, height = 70, radius = 12, group = group[1] ~= 'screens' and group[1] or nil, surface = surface})
			device:SetPoint('LEFT', (index - 1) * 142, 0)
			if group[1] == 'screens' then
				local glass = Kit:Screen(device, {inset = 3, radius = 6})
				glass:SetPoint('TOPLEFT', 10, -24)
				glass:SetPoint('BOTTOMRIGHT', -10, 10)
				local text = Kit:Text(glass.screen, '88:88', 12, 'darkInk', true)
				text:SetPoint('CENTER')
			else
				local key = Kit:Key(device, {text = 'Key', width = 44, height = 22, tone = index == 1 and 'primary' or nil})
				key:SetPoint('BOTTOMLEFT', 10, 10)
				local lcd = Kit:LCD(device, {ghost = '888', text = '042', size = 'sm', width = 56})
				lcd:SetPoint('BOTTOMRIGHT', -10, 8)
			end
			preview.devices[index] = device
		end
		preview:SetSize(142 * #GROUPS - 10, 76)
	end
	preview:SetParent(card.body)
	preview:ClearAllPoints()
	preview:SetPoint('TOP', card.body, 'TOP', 0, -6)
	preview:SetFrameLevel(card.body:GetFrameLevel() + 4)
	preview:Show()
end

local housingCards = {
	{title = 'Preview', rows = {
		{'note', 'Each group as it looks now. Changes show as you make them.\n \n \n \n \n '},
	}},
	{title = 'Presets', rows = {}},
}
for _, preset in ipairs(PRESETS) do
	local cards = housingCards[2].rows
	cards[#cards + 1] = {'button', preset[1], 'Apply', function() ApplyPreset(preset) end, preset[5], since = '0.5.1'}
end
housingCards[2].rows[#housingCards[2].rows + 1] = {'button', 'Every housing', 'Reset', ResetHousing, 'Back to the finish\'s own color, no gradient, matte.'}

for _, group in ipairs(GROUPS) do
	local key = group[1]
	local path = 'housing.'..key..'.'
	housingCards[#housingCards + 1] = {title = group[2], rows = {
		{'note', group[3]},
		{'dropdown', 'Color', path..'color', items = ColorItems, since = '0.5.1',
			note = 'Finish keeps the Paper or Graphite housing. Dark colors read best with the Graphite finish, light ones with Paper.'},
		{'color', 'Custom color', path..'custom', hidden = function() return Group(key).color ~= 'custom' end},
		{'switch', 'Gradient', path..'gradient', 'A two-stop wash over the housing: down, across or corner to corner. Alpha sets each end\'s strength.', since = '0.5.1'},
		{'color', 'Gradient colors', path..'gradientColors', hidden = function() return not Group(key).gradient end},
		{'dropdown', 'Material', path..'material', items = MaterialItems, since = '0.5.1',
			note = 'Surface detail drawn one texel per screen pixel, so it stays sharp at any size and UI scale.'},
		{'slider', 'Strength', path..'strength', 0, 1, 0.05, nil, format = Percent,
			hidden = function() return Group(key).material == 'matte' end},
		{'button', group[2], 'Reset', function() ResetGroup(key) end},
	}}
end

UI:RegisterPage('housing', {title = 'Housing', order = 2.07, since = '0.5.1',
	onShow = function(area) ShowPreview(area) end,
	onHide = function() if preview then preview:Hide() end end,
	cards = housingCards,
})

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

-- World text -----------------------------------------------------------------------
-- The game reads these fonts as a character loads, so they are set as early as
-- the saved settings exist, and a change shows after a relog.
local function WorldFontPath(choice)
	if choice == '__default' then return Kit.fonts.bold end
	if choice == '__numbers' then return [[Fonts\ARIALN.TTF]] end
	if choice and LibStub then
		local LSM = LibStub('LibSharedMedia-3.0', true)
		local path = LSM and LSM:Fetch('font', choice, true)
		if path then return path end
	end
	return nil
end

local function ApplyWorldFonts()
	local fonts = UI.db and UI.db.fonts
	if type(fonts) ~= 'table' then return end
	local names = fonts.worldNames ~= '__keep' and WorldFontPath(fonts.worldNames)
	if names then UNIT_NAME_FONT = names end
	local combat = fonts.combatText ~= '__keep' and WorldFontPath(fonts.combatText)
	if combat then DAMAGE_TEXT_FONT = combat end
end

local worldFonts = CreateFrame('Frame')
worldFonts:RegisterEvent('ADDON_LOADED')
worldFonts:RegisterEvent('PLAYER_LOGIN')
worldFonts:SetScript('OnEvent', function(self, event, name)
	if event == 'ADDON_LOADED' and name ~= UI.name then return end
	UI:Safe(ApplyWorldFonts)
	if event == 'PLAYER_LOGIN' then self:UnregisterAllEvents() end
end)

local function WorldItems()
	local items = {{'__keep', 'Game default'}}
	for _, item in ipairs(Kit:FontChoices(false)) do
		if item[1] ~= '__game' then items[#items + 1] = item end
	end
	return items
end

local function Relog() UI:Print('World text fonts change after a relog (log out to the character list and back in).') end

local worldRows = {
	{'dropdown', 'Names in the world', 'fonts.worldNames', items = WorldItems, since = '0.5.2',
		note = 'Names over characters and creatures. The game reads it as a character loads: relog to see a change.',
		set = function(value) UI.db.fonts.worldNames = value; Relog() end},
	{'dropdown', 'Combat text', 'fonts.combatText', items = WorldItems, since = '0.5.2',
		note = 'Floating damage and healing numbers. Read as a character loads: relog to see a change.',
		set = function(value) UI.db.fonts.combatText = value; Relog() end},
	{'slider', 'Combat text size', 'fonts.combatTextScale', 0.5, 2.5, 0.1, nil, format = Percent, since = '0.5.2',
		note = 'The game\'s world text scale. Applies at once.',
		set = function(value)
			UI.db.fonts.combatTextScale = value
			local set = (C_CVar and C_CVar.SetCVar) or SetCVar
			if set then pcall(set, 'WorldTextScale', value) end
		end},
}

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
	{title = 'World text', rows = worldRows},
	{title = 'Fonts', rows = {
		{'button', 'Fonts', 'Reset', ResetFonts, 'Every area back to IBM Plex Mono at its own size.'},
		{'note', 'Fonts from other addons (LibSharedMedia) appear here once those addons are loaded. Text the game itself draws, such as chat messages, follows the Chat page.'},
	}},
}})

-- Fade ---------------------------------------------------------------------------
local fade = UI:RegisterModule('fade', {always = true})
local GetTime = GetTime

-- The parts that fade. Our own frames are found by their mover keys (a key or
-- a key prefix), the game's by name; only frames sitting directly on UIParent
-- are faded, so a child is never dimmed twice, and a game frame our style has
-- replaced (parked off UIParent) is skipped by the same rule.
local CHAT = {'GeneralDockManager', 'ChatFrameMenuButton', 'ChatFrameChannelButton', 'QuickJoinToastButton'}
for index = 1, NUM_CHAT_WINDOWS or 10 do CHAT[#CHAT + 1] = 'ChatFrame'..index end
local PARTS = {
	{key = 'console', label = 'Console and bars', movers = {'ab.console', 'ab.bar', 'ab.pet', 'ab.stance', 'ab.extra', 'ab.zone'},
		names = {'MainActionBar', 'MainMenuBar', 'MultiBarBottomLeft', 'MultiBarBottomRight', 'MultiBar5', 'MultiBar6', 'MultiBar7',
			'StanceBar', 'PetActionBar', 'JiberishSpec01PetKeys', 'JiberishSpec01StanceKeys'}},
	{key = 'side', label = 'Side bars', movers = {'ab.side'}, names = {'MultiBarLeft', 'MultiBarRight'}},
	{key = 'menu', label = 'Menu and bags', movers = {'ab.menu', 'ab.bags'}, names = {'MicroMenuContainer', 'BagsBar'}},
	{key = 'unitframes', label = 'Unit frames', movers = {'uf.'},
		names = {'PlayerFrame', 'TargetFrame', 'FocusFrame', 'PetFrame', 'PartyFrame', 'JiberishSpec01PartyHeader'}},
	{key = 'castbars', label = 'Cast bars', movers = {'cb.'}, names = {'PlayerCastingBarFrame'}},
	{key = 'group', label = 'Raid, boss and arena', movers = {'group.'}, names = {'CompactRaidFrameContainer'}},
	{key = 'minimap', label = 'Minimap', names = {'MinimapCluster'}},
	{key = 'chat', label = 'Chat', names = CHAT, chat = true},
	{key = 'objectives', label = 'Objectives', names = {'ObjectiveTrackerFrame'}},
	{key = 'buffs', label = 'Buffs', names = {'BuffFrame', 'DebuffFrame'}},
	{key = 'timeline', label = 'Aura timeline', movers = {'tl.player'}},
	{key = 'meters', label = 'Damage meters', movers = {'dm.'}},
	{key = 'infopanel', label = 'Info panel and HUD', movers = {'ip.'}},
}
fade.parts = PARTS

-- The triggers that bring parts back, in the page's order. Modes force some on.
local TRIGGERS = {
	{'combat', 'In combat', 'A fight brings everything back.'},
	{'target', 'Have a target'},
	{'casting', 'Casting or channeling'},
	{'health', 'Below full health'},
	{'power', 'Below full power', 'Mana, energy, rage and the like not full (or above empty for rage and runic power).'},
	{'mouseover', 'Mouse over a part', 'A faded part comes back at once while the mouse is over it, even when out of sight.'},
	{'group', 'In a group or raid'},
	{'instance', 'In an instance', 'Dungeons, raids, battlegrounds, arenas and scenarios.'},
	{'resting', 'In a resting area', 'Cities and inns.'},
}
local FORCED = {combat = {combat = true}, idle = {combat = true, target = true, casting = true, health = true}, always = {}}

local function DB() return UI.db.appearance.fade end

-- Old saves: one switch per part, 'open world only', and the idle rule. Every
-- profile moves to the 'out of combat' rule once.
local function Migrate(db)
	if db.v2 then return end
	db.mode = 'combat'
	for _, part in ipairs(PARTS) do
		local old = db[part.key]
		if type(old) == 'boolean' and type(db.parts) == 'table' and type(db.parts[part.key]) == 'table' then
			db.parts[part.key].on = old
		end
		if type(old) == 'boolean' then db[part.key] = nil end
	end
	if db.openWorld and type(db.triggers) == 'table' then db.triggers.instance = true end
	db.openWorld = nil
	db.v2 = true
end

local function Usable(frame)
	if type(frame) ~= 'table' or not frame.SetAlpha or not frame.GetParent then return false end
	if frame.IsForbidden and frame:IsForbidden() then return false end
	return frame:GetParent() == UIParent
end

-- Each part's frames, gathered again every two seconds (frames come and go).
-- Frames found through a mover are our own (only those may Retract).
local cache, cachedAt = {}, 0
local ours = setmetatable({}, {__mode = 'k'})
local function Gather()
	cachedAt = GetTime()
	local movers = UI.GetMovers and UI:GetMovers() or {}
	for _, part in ipairs(PARTS) do
		local list, seen = cache[part.key] or {}, {}
		wipe(list)
		local function Add(frame)
			if not seen[frame] and Usable(frame) then seen[frame] = true; list[#list + 1] = frame end
		end
		for _, mover in ipairs(movers) do
			for _, prefix in ipairs(part.movers or {}) do
				if mover.key:sub(1, #prefix) == prefix and not mover.docked then
					ours[mover.frame] = true
					Add(mover.frame)
				end
			end
		end
		for _, name in ipairs(part.names or {}) do
			local frame = _G[name]
			if frame then Add(frame) end
		end
		cache[part.key] = list
	end
end

local function Frames(part)
	if GetTime() - cachedAt > 2 then Gather() end
	return cache[part.key] or {}
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

-- Hidden values count as "not full", so a part comes back rather than stays out.
-- Health and power the game hides (secret, around a fight) keep the last
-- answer read in the open, rather than holding every part up.
local healthLow, powerBusy = false, false
local function HealthLow()
	local dead = UnitIsDeadOrGhost and UnitIsDeadOrGhost('player')
	if not IsSecret(dead) and dead then healthLow = false return false end
	local current, most = UnitHealth('player'), UnitHealthMax('player')
	if not IsSecret(current) and not IsSecret(most) and type(current) == 'number' and type(most) == 'number' and most > 0 then
		healthLow = current < most
	end
	return healthLow
end

local EMPTYING = {RAGE = true, RUNIC_POWER = true, LUNAR_POWER = true, FURY = true, PAIN = true, INSANITY = true, MAELSTROM = true}
local function PowerSettled()
	local _, token = UnitPowerType('player')
	local current, most = UnitPower('player'), UnitPowerMax('player')
	if not IsSecret(token) and not IsSecret(current) and not IsSecret(most) and type(current) == 'number' and type(most) == 'number' then
		if token and EMPTYING[token] then powerBusy = current ~= 0
		else powerBusy = most > 0 and current < most end
	end
	return not powerBusy
end

local function On(db, trigger)
	return (FORCED[db.mode] or FORCED.combat)[trigger] or (type(db.triggers) == 'table' and db.triggers[trigger]) or false
end

-- Whether something calls every part back right now.
local function Wanted(db)
	if fighting or InCombatLockdown() then return On(db, 'combat') end
	if On(db, 'target') and UnitExists('target') then return true end
	if On(db, 'casting') and Casting() then return true end
	if On(db, 'health') and HealthLow() then return true end
	if On(db, 'power') and not PowerSettled() then return true end
	if On(db, 'group') and IsInGroup() then return true end
	if On(db, 'instance') then
		local inside, kind = IsInInstance()
		if inside and kind ~= 'none' then return true end
	end
	if On(db, 'resting') and IsResting() then return true end
	return false
end

local function Hovered(frames)
	for _, frame in ipairs(frames) do
		-- The cursor against the frame's rectangle; works for frames that
		-- take no mouse and for ones faded to nothing.
		if frame:IsVisible() and frame.IsMouseOver then
			local ok, over = pcall(frame.IsMouseOver, frame)
			if ok and not IsSecret(over) and over then return true end
		end
	end
	return false
end

local function MoverAlpha(frame) return UI.MoverAlphaFor and UI:MoverAlphaFor(frame) or 1 end

-- Each frame remembers the alpha this module last chose for it, so it only
-- animates on a change and puts back what someone else moved meanwhile.
local chosen = setmetatable({}, {__mode = 'k'})

-- Fade styles ---------------------------------------------------------------------------
-- Each style is SPEC-01 hardware changing state, both ways: going dim and
-- waking. Each takes the part's fade time; all of them only ever change the
-- part's alpha (Retract also moves our own, unprotected frames a few pixels),
-- and draw anything else on overlays of our own that follow the part, never
-- take the mouse, and go away when the animation ends or the part hides.
local STYLE_LIST = {
	{'smooth', 'Smooth', 'An eased fade.'},
	{'detent', 'Detent dimmer', 'Clicks through five steps, like a rotary dimmer.'},
	{'power', 'Power down', 'Flickers off like a screen; wakes with a flicker and a scan line.'},
	{'shutter', 'Shutter', 'Slats close over the part from their middles, and open on waking.'},
	{'scan', 'Scan wipe', 'A lit line wipes down as the part dims, and up as it wakes.'},
	{'retract', 'Retract', 'Slides a few pixels toward the nearest screen edge as it dims, and glides back.'},
	{'cascade', 'LED cascade', 'Its lamps go out one by one, then it dims; they light again one by one.'},
}
local STYLES = {}
local ease = Kit.ease
local floor, min, max = math.floor, math.min, math.max

local function Reduced() return UI.db.reduceMotion end
local function Lerp(a, b, t) return a + (b - a) * t end

-- One overlay per frame: a lit scan line, a dark strip and shutter slats, on
-- UIParent (so the part's alpha doesn't dim them), anchored over the part.
local overlays = setmetatable({}, {__mode = 'k'})
local SLATS = 6
local function Overlay(frame)
	local overlay = overlays[frame]
	if not overlay then
		overlay = CreateFrame('Frame', nil, UIParent)
		overlay:EnableMouse(false)
		overlay:Hide()
		overlay.line = overlay:CreateTexture(nil, 'OVERLAY', nil, 7)
		overlay.line:SetColorTexture(1, 1, 1, 1)
		overlay.line:SetBlendMode('ADD')
		overlay.strip = overlay:CreateTexture(nil, 'ARTWORK')
		overlay.strip:SetColorTexture(0, 0, 0, 1)
		overlay.slats = {}
		for index = 1, SLATS do
			local slat = {body = overlay:CreateTexture(nil, 'ARTWORK', nil, 1), lit = overlay:CreateTexture(nil, 'ARTWORK', nil, 2),
				dark = overlay:CreateTexture(nil, 'ARTWORK', nil, 2)}
			slat.body:SetColorTexture(0.05, 0.05, 0.05, 1)
			slat.lit:SetColorTexture(1, 1, 1, 0.16)
			slat.dark:SetColorTexture(0, 0, 0, 0.85)
			overlay.slats[index] = slat
		end
		overlays[frame] = overlay
	end
	overlay:ClearAllPoints()
	overlay:SetAllPoints(frame)
	overlay:SetFrameStrata(frame:GetFrameStrata())
	overlay:SetFrameLevel(min(frame:GetFrameLevel() + 30, 9000))
	overlay.line:Hide(); overlay.strip:Hide()
	for _, slat in ipairs(overlay.slats) do slat.body:Hide(); slat.lit:Hide(); slat.dark:Hide() end
	overlay:SetAlpha(1)
	overlay:Show()
	return overlay
end

local function HideOverlay(frame)
	local overlay = overlays[frame]
	if overlay then overlay:Hide() end
end

-- The part's height and width, when plain.
local function Size(frame)
	local width, height = frame:GetSize()
	if IsSecret(width) or IsSecret(height) or not width or not height or width <= 0 or height <= 0 then return nil end
	return width, height
end

-- Run an animation on the frame's own key (so a new one replaces it), with a
-- cleanup that always runs, and stopping the overlay if the part hides.
local function Drive(frame, seconds, step, finish)
	Kit:Animate(frame, seconds, 0, 1, function(_, progress)
		if not frame:IsVisible() then HideOverlay(frame) end
		step(progress)
	end, finish, 'linear')
end

function STYLES.smooth(frame, from, to, seconds)
	Kit:FadeTo(frame, to, seconds)
end

-- Five detents; the leading frame of a part clicks at each.
local DETENTS = 5
function STYLES.detent(frame, from, to, seconds, _, leader)
	local last = 0
	Drive(frame, seconds, function(progress)
		local step = min(DETENTS, floor(progress * DETENTS + 0.0001))
		if step ~= last then
			last = step
			frame:SetAlpha(Lerp(from, to, step / DETENTS))
			if leader then Kit:Play('tick', true) end
		end
	end, function() frame:SetAlpha(to) end)
end

-- Power down: two or three blips, then it settles dim. Power up: a flicker and
-- a thin scan line running down the part.
local POWER_DOWN = {1, 0.3, 0.95, 0.2, 0.7}
local POWER_UP = {0, 0.7, 0.15, 0.85, 0.4, 1}
function STYLES.power(frame, from, to, seconds, waking)
	local _, height = Size(frame)
	local overlay = waking and height and Overlay(frame)
	if overlay then overlay.line:Show() end
	Drive(frame, seconds, function(progress)
		if waking then
			frame:SetAlpha(Lerp(from, to, POWER_UP[min(#POWER_UP, floor(progress * #POWER_UP) + 1)]))
			if overlay then
				local line = overlay.line
				line:ClearAllPoints()
				line:SetPoint('TOPLEFT', overlay, 'TOPLEFT', 0, -height * progress)
				line:SetPoint('TOPRIGHT', overlay, 'TOPRIGHT', 0, -height * progress)
				line:SetHeight(max(1, UI.Pixel and UI.Pixel.Px(overlay, 2) or 1))
				line:SetAlpha(0.45 * (1 - progress))
			end
		elseif progress < 0.45 then
			-- 1 is the part fully up, 0 fully at its faded opacity.
			frame:SetAlpha(Lerp(to, from, POWER_DOWN[min(#POWER_DOWN, floor(progress / 0.45 * #POWER_DOWN) + 1)]))
		else
			frame:SetAlpha(Lerp(Lerp(to, from, 0.7), to, ease.sine((progress - 0.45) / 0.55)))
		end
	end, function()
		frame:SetAlpha(to)
		HideOverlay(frame)
	end)
end

-- Shutter: dark slats with a lit top hairline close from their middles over the
-- part as it dims, then let go; waking, they start closed and open.
function STYLES.shutter(frame, from, to, seconds, waking)
	local _, height = Size(frame)
	if not height then return STYLES.smooth(frame, from, to, seconds) end
	local overlay = Overlay(frame)
	local pitch = height / SLATS
	local px = UI.Pixel and UI.Pixel.Px(overlay, 1) or 1
	local function Close(amount)
		for index, slat in ipairs(overlay.slats) do
			local centre = -(index - 0.5) * pitch
			local half = max(0, pitch * amount / 2)
			local shown = half > 0.05
			for _, piece in pairs(slat) do piece:SetShown(shown) end
			if shown then
				slat.body:ClearAllPoints()
				slat.body:SetPoint('TOPLEFT', overlay, 'TOPLEFT', 0, centre + half)
				slat.body:SetPoint('BOTTOMRIGHT', overlay, 'TOPRIGHT', 0, centre - half)
				slat.lit:ClearAllPoints()
				slat.lit:SetPoint('TOPLEFT', slat.body, 'TOPLEFT')
				slat.lit:SetPoint('TOPRIGHT', slat.body, 'TOPRIGHT')
				slat.lit:SetHeight(px)
				slat.dark:ClearAllPoints()
				slat.dark:SetPoint('BOTTOMLEFT', slat.body, 'BOTTOMLEFT')
				slat.dark:SetPoint('BOTTOMRIGHT', slat.body, 'BOTTOMRIGHT')
				slat.dark:SetHeight(px)
			end
		end
	end
	overlay:SetAlpha(0.6)
	Drive(frame, seconds, function(progress)
		local eased = ease.detent(progress)
		frame:SetAlpha(Lerp(from, to, eased))
		if waking then
			Close(1 - eased)
		else
			-- Closes over the first 70%, then the slats let go as the part settles.
			Close(min(1, progress / 0.7))
			overlay:SetAlpha(progress < 0.7 and 0.6 or 0.6 * (1 - (progress - 0.7) / 0.3))
		end
	end, function()
		frame:SetAlpha(to)
		HideOverlay(frame)
	end)
end

-- Scan wipe: a lit line runs down and the part dims behind it; waking, it runs
-- up and uncovers the part.
function STYLES.scan(frame, from, to, seconds, waking)
	local _, height = Size(frame)
	if not height then return STYLES.smooth(frame, from, to, seconds) end
	local overlay = Overlay(frame)
	overlay.line:Show(); overlay.strip:Show()
	local px = UI.Pixel and UI.Pixel.Px(overlay, 2) or 1
	if waking then frame:SetAlpha(to) end
	local shade = waking and 0.5 or min(0.6, max(0.25, 1 - to / max(from, 0.01)))
	Drive(frame, seconds, function(progress)
		local eased = ease.inout(progress)
		local y = height * (waking and (1 - eased) or eased)
		overlay.strip:ClearAllPoints()
		overlay.strip:SetPoint('TOPLEFT', overlay, 'TOPLEFT')
		overlay.strip:SetPoint('TOPRIGHT', overlay, 'TOPRIGHT')
		overlay.strip:SetHeight(max(y, 0.01))
		overlay.strip:SetAlpha(shade)
		overlay.line:ClearAllPoints()
		overlay.line:SetPoint('TOPLEFT', overlay, 'TOPLEFT', 0, -y)
		overlay.line:SetPoint('TOPRIGHT', overlay, 'TOPRIGHT', 0, -y)
		overlay.line:SetHeight(px)
		overlay.line:SetAlpha(0.55 * math.sin(math.pi * progress) + 0.15)
	end, function()
		frame:SetAlpha(to)
		HideOverlay(frame)
	end)
end

-- Retract: our own frames (or a unit frame's inner face) slide toward the
-- nearest screen edge while they dim. Points are shifted, never re-anchored,
-- and a frame its module has placed again meanwhile is left where it is.
local RETRACT = 6
local retracted = setmetatable({}, {__mode = 'k'})   -- moved region -> {dx, dy, x, y}
local function Movable(frame)
	if not ours[frame] then return nil end
	if not frame.IsProtected or not frame:IsProtected() then return frame end
	local face = frame.face
	if type(face) == 'table' and face.AdjustPointsOffset and not (face.IsProtected and face:IsProtected()) then return face end
end

local function Edge(region)
	local x, y = region:GetCenter()
	if IsSecret(x) or IsSecret(y) or not x or not y then return 0, 0 end
	local width, height = UIParent:GetSize()
	local scale = region:GetEffectiveScale() / UIParent:GetEffectiveScale()
	x, y = x * scale, y * scale
	local left, right, bottom, top = x, width - x, y, height - y
	local nearest = min(left, right, bottom, top)
	if nearest == left then return -1, 0 elseif nearest == right then return 1, 0 elseif nearest == bottom then return 0, -1 end
	return 0, 1
end

local function Shift(region, dx, dy)
	local state = retracted[region]
	if not state then state = {0, 0}; retracted[region] = state end
	-- Placed again by its module since we last moved it: start from there.
	local _, _, _, x, y = region:GetPoint(1)
	if state.x and (x ~= state.x or y ~= state.y) then state[1], state[2] = 0, 0 end
	local moveX, moveY = dx - state[1], dy - state[2]
	if moveX ~= 0 or moveY ~= 0 then region:AdjustPointsOffset(moveX, moveY) end
	state[1], state[2] = dx, dy
	state.x, state.y = select(4, region:GetPoint(1))
end

function STYLES.retract(frame, from, to, seconds, waking, leader)
	local region = Movable(frame)
	if not (region and region.AdjustPointsOffset and region:GetNumPoints() > 0) then
		return STYLES.detent(frame, from, to, seconds, waking, leader)
	end
	local sx, sy = Edge(region)
	local state = retracted[region]
	local startX, startY = state and state[1] or 0, state and state[2] or 0
	local endX, endY = waking and 0 or sx * RETRACT, waking and 0 or sy * RETRACT
	Drive(frame, seconds, function(progress)
		local eased = ease.cubic(progress)
		frame:SetAlpha(Lerp(from, to, eased))
		Shift(region, Lerp(startX, endX, eased), Lerp(startY, endY, eased))
	end, function()
		frame:SetAlpha(to)
		Shift(region, endX, endY)
	end)
end

-- LED cascade: the lamps inside the part go out left to right before it dims;
-- waking, it brightens and they light again. Lamps keep their own state
-- (Kit:SetLed puts it back); only their look is borrowed.
local function LampsIn(frame)
	local lamps = {}
	for led in pairs(Kit.leds or {}) do
		local node = led.GetParent and led:GetParent()
		for _ = 1, 12 do
			if node == frame then lamps[#lamps + 1] = led break end
			if not node or not node.GetParent then break end
			node = node:GetParent()
		end
	end
	table.sort(lamps, function(a, b)
		local ax, bx = a:GetLeft(), b:GetLeft()
		if IsSecret(ax) or IsSecret(bx) or not ax or not bx then return false end
		return ax < bx
	end)
	return lamps
end

local darkened = setmetatable({}, {__mode = 'k'})   -- frame -> its lamps put out
local function Lamp(led, lit)
	if lit then Kit:SetLed(led, led.on) return end
	Kit:Tint(led, 'ledOff')
	if led.glow then led.glow:Hide() end
end

function STYLES.cascade(frame, from, to, seconds, waking)
	local lamps = LampsIn(frame)
	local count = #lamps
	if count == 0 then return STYLES.smooth(frame, from, to, seconds) end
	darkened[frame] = not waking and lamps or nil
	local done = 0
	Drive(frame, seconds, function(progress)
		if waking then
			frame:SetAlpha(Lerp(from, to, ease.sine(min(1, progress / 0.5))))
			local lit = progress < 0.5 and 0 or floor((progress - 0.5) / 0.5 * count + 0.0001)
			for index = done + 1, min(lit, count) do Lamp(lamps[index], true) end
			done = max(done, min(lit, count))
		else
			local dark = floor(min(1, progress / 0.5) * count + 0.0001)
			for index = done + 1, min(dark, count) do Lamp(lamps[index], false) end
			done = max(done, min(dark, count))
			if progress > 0.5 then frame:SetAlpha(Lerp(from, to, ease.sine((progress - 0.5) / 0.5))) end
		end
	end, function()
		frame:SetAlpha(to)
		-- Whatever the timing, the lamps end as their owners want them when awake.
		if waking then for _, led in ipairs(lamps) do Lamp(led, true) end end
	end)
end

-- Move one frame to an alpha in a style. Reduced motion, an instant change or a
-- hidden part: straight there.
-- Undo whatever a style left behind: an overlay, a shift, lamps put out.
local function Settle(frame, style)
	HideOverlay(frame)
	local region = style ~= 'retract' and Movable(frame)
	local state = region and retracted[region]
	if state and (state[1] ~= 0 or state[2] ~= 0) then Shift(region, 0, 0) end
	local lamps = style ~= 'cascade' and darkened[frame]
	if lamps then
		darkened[frame] = nil
		for _, led in ipairs(lamps) do Lamp(led, true) end
	end
end

local function Run(frame, to, seconds, style, waking, leader)
	Settle(frame, style)
	local from = frame:GetAlpha()
	if IsSecret(from) then from = waking and 0 or 1 end
	if Reduced() or seconds <= 0 or not frame:IsVisible() then
		Kit:Animate(frame, 0, from, to, function(value) frame:SetAlpha(value) end)
		HideOverlay(frame)
		if style == 'cascade' and waking then for _, led in ipairs(LampsIn(frame)) do Lamp(led, true) end end
		return
	end
	local run = STYLES[style] or STYLES.smooth
	run(frame, from, to, seconds, waking, leader)
end

local function StyleOf(db, settings)
	local own = db.advanced and settings and settings.style
	if own and own ~= 'global' and STYLES[own] then return own end
	return STYLES[db.style] and db.style or 'smooth'
end

-- Returns true when any frame of the part started to change.
local function SetPart(frames, alpha, seconds, style, waking)
	local changed, leader = false, true
	for _, frame in ipairs(frames) do
		local current = frame:GetAlpha()
		-- Unlock mode's opacity and Hide stay in force under the fade.
		local target = alpha * MoverAlpha(frame)
		if chosen[frame] ~= target or (not IsSecret(current) and abs(current - target) > 0.02 and not Kit:Animating(frame)) then
			chosen[frame] = target
			Run(frame, target, seconds, style, waking, leader)
			changed, leader = true, false
		end
	end
	return changed
end

-- One sound per transition, whichever parts take part, at most every 0.25 s.
local lastSound = {}
local function Sound(db, waking)
	if not db.sound then return end
	local now = GetTime()
	local kind = waking and 'wake' or 'dim'
	if now - (lastSound[kind] or 0) < 0.25 then return end
	lastSound[kind] = now
	Kit:Play(waking and (db.wakeSound or 'latch-down') or (db.dimSound or 'latch-up'), true)
end

local function Restore()
	for frame in pairs(chosen) do
		if Usable(frame) then
			Settle(frame, nil)
			Kit:FadeTo(frame, MoverAlpha(frame), 0.15)
		end
	end
	wipe(chosen)
end

-- A part's faded opacity: its own, else the global one; mounted can go lower.
local function FadedAlpha(db, settings)
	local alpha = settings and type(settings.alpha) == 'number' and settings.alpha >= 0 and settings.alpha or db.alpha or 0.3
	if db.mountedMore and (IsMounted() or (IsFlying and IsFlying())) then alpha = math.min(alpha, db.mountedAlpha or 0.1) end
	return alpha
end

local ticker, previewUntil, wakeUntil = nil, 0, 0
local awakeAt = {}       -- part key -> when it was last called back
local faded = {}         -- part key -> true while it rests faded

local function Tick()
	local db = DB()
	local previewing = GetTime() < previewUntil
	local previewWake = GetTime() < wakeUntil
	if not (db.enable or previewing or previewWake) then return end
	-- Pet battles hide the console and its frames themselves; unlock mode shows everything.
	if C_PetBattles and C_PetBattles.IsInBattle and C_PetBattles.IsInBattle() then return end
	local unlocked = UI.MoversUnlocked and UI:MoversUnlocked()
	local now = GetTime()
	local wanted = not previewing and (unlocked or now < wakeUntil or Wanted(db))
	local hover = not previewing and On(db, 'mouseover')
	local typing = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
	local dimmed, woke = false, false
	local everyPart = db.soundScope == 'all'
	for _, part in ipairs(PARTS) do
		local settings = type(db.parts) == 'table' and db.parts[part.key]
		local frames = Frames(part)
		local style = StyleOf(db, settings)
		local heard = everyPart or part.key == 'console'
		if settings and settings.on and (db.enable or previewing) then
			local awake = wanted or (part.chat and typing and not previewing)
			-- Mouse-over is looked for only while nothing else holds the part up (out of
			-- combat, faded or about to fade), and brings it back at once: the wake
			-- animation still plays, quickly.
			local hovered = not awake and hover and Hovered(frames)
			if awake or hovered then awakeAt[part.key] = now end
			local stay = not previewing and now - (awakeAt[part.key] or 0) < (db.delay or 2)
			if awake or hovered or stay then
				faded[part.key] = nil
				local seconds = hovered and min(db.fadeIn or 0.15, 0.12) or (db.fadeIn or 0.15)
				if SetPart(frames, 1, seconds, style, true) and heard then woke = true end
			else
				faded[part.key] = true
				if SetPart(frames, FadedAlpha(db, settings), db.fadeOut or 0.6, style, false) and heard then dimmed = true end
			end
		else
			faded[part.key] = nil
			-- The preview's wake plays the style even with fading off.
			if SetPart(frames, 1, db.fadeIn or 0.15, previewWake and style or 'smooth', true) and previewWake and heard then woke = true end
		end
	end
	if dimmed then Sound(db, false) end
	if woke then Sound(db, true) end
end

local function Update()
	local db = DB()
	Migrate(db)
	cachedAt = 0
	local on = db.enable or GetTime() < previewUntil or GetTime() < wakeUntil
	if on and not ticker then
		-- Ten times a second: triggers, the delay, and the mouse over faded parts.
		ticker = C_Timer.NewTicker(0.1, function() UI:Safe(Tick) end)
		Tick()
	elseif not on and ticker then
		ticker:Cancel()
		ticker = nil
		wipe(faded)
		Restore()
	elseif on then
		Tick()
	end
end

-- Fade every chosen part now, for three seconds, to show how it looks.
function fade:Preview()
	previewUntil = GetTime() + 3
	wipe(awakeAt)
	Update()
	-- Then everything wakes in the same style, and stays up a moment before the rule takes over.
	C_Timer.After(3.05, function()
		wakeUntil = GetTime() + 1.5
		UI:Safe(Update)
		C_Timer.After(1.6, function() UI:Safe(Update) end)
	end)
end

function fade:Enable()
	local driver = CreateFrame('Frame')
	for _, event in ipairs({'PLAYER_REGEN_DISABLED', 'PLAYER_REGEN_ENABLED', 'PLAYER_TARGET_CHANGED', 'GROUP_ROSTER_UPDATE',
		'PLAYER_UPDATE_RESTING', 'ZONE_CHANGED_NEW_AREA', 'PLAYER_MOUNT_DISPLAY_CHANGED'}) do
		pcall(driver.RegisterEvent, driver, event)
	end
	driver:SetScript('OnEvent', function(_, event)
		if event == 'PLAYER_REGEN_DISABLED' then fighting = true
		elseif event == 'PLAYER_REGEN_ENABLED' then fighting = false end
		if ticker then UI:Safe(Tick) end
	end)
	Update()
end

function fade:Refresh() Update() end

-- The Fade page ------------------------------------------------------------------------
local function Seconds(value) return format('%.1f s', value) end
local function PartAlpha(value) return value < 0 and 'Global' or value == 0 and 'Hidden' or Percent(value) end
local function Mode() return DB().mode end
local STYLE_ITEMS, PART_STYLE_ITEMS = {}, {{'global', 'Same as all'}}
for _, entry in ipairs(STYLE_LIST) do
	STYLE_ITEMS[#STYLE_ITEMS + 1] = {entry[1], entry[2]}
	PART_STYLE_ITEMS[#PART_STYLE_ITEMS + 1] = {entry[1], entry[2]}
end
local SOUND_ITEMS = {}
for _, name in ipairs({'latch-up', 'latch-down', 'tick', 'blip', 'open', 'down', 'up', 'success'}) do
	SOUND_ITEMS[#SOUND_ITEMS + 1] = {name, (name:gsub('^%l', string.upper):gsub('%-', ' '))}
end

local fadeRows = {
	{'switch', 'Fade', 'appearance.fade.enable', 'Chosen parts rest faded when nothing calls for them.'},
	{'segmented', 'Fade when', 'appearance.fade.mode', items = {{'combat', 'Out of combat'}, {'idle', 'Idle'}, {'always', 'Always'}},
		note = 'Out of combat: faded whenever you are not fighting. Idle: also needs no target, no cast and full health. Always: faded unless one of the triggers below holds.', since = '0.5.2'},
	{'slider', 'Faded opacity', 'appearance.fade.alpha', 0, 0.9, 0.05, '0% puts parts out of sight; the mouse still brings them back.', format = Percent},
	{'slider', 'Fade-out delay', 'appearance.fade.delay', 0, 10, 0.5, 'How long parts stay up after the last trigger ends.', format = Seconds, since = '0.5.2'},
	{'slider', 'Fade out over', 'appearance.fade.fadeOut', 0, 2, 0.05, nil, format = Seconds, since = '0.5.2'},
	{'slider', 'Fade in over', 'appearance.fade.fadeIn', 0, 1, 0.05, 'The mouse brings a part back at once.', format = Seconds, since = '0.5.2'},
	{'dropdown', 'Style', 'appearance.fade.style', items = STYLE_ITEMS, since = '0.5.2',
		note = 'How parts change state, both ways. Retract moves only our own unprotected frames (and a unit frame\'s face); anything else clicks through detents instead. Reduce motion makes every style an instant change.'},
	{'switch', 'Fade more when mounted', 'appearance.fade.mountedMore', 'Mounted or flying out of combat, parts go lower still.', since = '0.5.2'},
	{'slider', 'Mounted opacity', 'appearance.fade.mountedAlpha', 0, 0.9, 0.05, nil, format = Percent,
		hidden = function() return not DB().mountedMore end},
	{'button', 'Preview', 'Fade', function() fade:Preview() end, 'Every chosen part dims in its style, holds three seconds, then wakes.', since = '0.5.2'},
	{'header', 'Sound'},
	{'switch', 'Sound', 'appearance.fade.sound', 'One sound as parts go dim and one as they wake, however many change together. Follows the Sounds master switch.', since = '0.5.2'},
	{'dropdown', 'Going dim', 'appearance.fade.dimSound', items = SOUND_ITEMS, since = '0.5.2', disabled = function() return not DB().sound end},
	{'dropdown', 'Waking', 'appearance.fade.wakeSound', items = SOUND_ITEMS, since = '0.5.2', disabled = function() return not DB().sound end},
	{'segmented', 'Sound for', 'appearance.fade.soundScope', items = {{'console', 'Console only'}, {'all', 'Every part'}}, since = '0.5.2',
		disabled = function() return not DB().sound end},
}

local triggerRows = {}
for _, trigger in ipairs(TRIGGERS) do
	local key = trigger[1]
	triggerRows[#triggerRows + 1] = {'switch', trigger[2], 'appearance.fade.triggers.'..key, trigger[3], since = '0.5.2',
		get = function() return On(DB(), key) and true or false end,
		disabled = function() return (FORCED[Mode()] or FORCED.combat)[key] == true end}
end
triggerRows[#triggerRows + 1] = {'note', 'Triggers the mode needs are on and locked: out of combat always counts a fight, and idle also a target, a cast and lost health.'}

local partRows = {
	{'switch', 'Per-part settings', 'appearance.fade.advanced', 'Give each part its own faded opacity (or put it out of sight) and its own style.', since = '0.5.2'},
}
for _, part in ipairs(PARTS) do
	local path = 'appearance.fade.parts.'..part.key
	partRows[#partRows + 1] = {'switch', part.label, path..'.on', since = '0.5.2'}
	partRows[#partRows + 1] = {'slider', part.label..' opacity', path..'.alpha', -0.05, 0.9, 0.05, nil, format = PartAlpha,
		hidden = function() return not DB().advanced end,
		get = function()
			local settings = DB().parts[part.key]
			return settings and type(settings.alpha) == 'number' and math.max(settings.alpha, -0.05) or -0.05
		end,
		set = function(value) DB().parts[part.key].alpha = value < 0 and -1 or value end}
	partRows[#partRows + 1] = {'dropdown', part.label..' style', path..'.style', items = PART_STYLE_ITEMS,
		hidden = function() return not DB().advanced end}
end

UI:RegisterPage('fade', {title = 'Fade', order = 2.09, since = '0.5.2', cards = {
	{title = 'Fade', rows = fadeRows},
	{title = 'Show when', rows = triggerRows},
	{title = 'Parts', rows = partRows},
}})
