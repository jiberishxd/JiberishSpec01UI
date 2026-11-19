-- Unit frames: the settings page. Part of the unit frames (UnitFrames.lua).
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown, GetTime = CreateFrame, UIParent, InCombatLockdown, GetTime
local floor, max, min, sin, pi = math.floor, math.max, math.min, math.sin, math.pi
local P = UI.UnitFrameParts
local DB, Resolve = P.DB, P.Resolve

-- The settings page -------------------------------------------------------------------
local Int, Percent = UI.Util.Int, UI.Util.Percent

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
		{'screen', 'Screen amber'}, {'class', 'Class (creatures by reaction)'}, {'reaction', 'Reaction'}, {'gradient', 'By health'},
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
