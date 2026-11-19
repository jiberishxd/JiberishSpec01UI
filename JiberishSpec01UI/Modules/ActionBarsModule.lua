-- The action bars module (enable, refresh) and its settings page. Part of the
-- action bars (ActionBars.lua).
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown, GetTime = CreateFrame, UIParent, InCombatLockdown, GetTime
local floor, max, min = math.floor, math.max, math.min
local format, ipairs, pairs, pcall, tonumber = format, ipairs, pairs, pcall, tonumber
local P = UI.ActionBarParts
local ApplyCountdownCVar, ApplyCVars, ApplyLock, ApplyLook, BARS, Bind = P.ApplyCountdownCVar, P.ApplyCVars, P.ApplyLock, P.ApplyLook, P.BARS, P.Bind
local BuildConsole, BuildExtra, BuildFree, BuildMenu, BuildPet, BuildSide = P.BuildConsole, P.BuildExtra, P.BuildFree, P.BuildMenu, P.BuildPet, P.BuildSide
local BuildStance, DB, Deck, Docking, EVENTS, ForKeys = P.BuildStance, P.DB, P.Deck, P.Docking, P.EVENTS, P.ForKeys
local HW, keys, LayoutConsole, LayoutFree, LayoutMenu, LayoutSide = P.HW, P.keys, P.LayoutConsole, P.LayoutFree, P.LayoutMenu, P.LayoutSide
local LayoutStance, module, OnEvent, PlacePetKeys, RANGE_EVENTS, RetireBlizzard = P.LayoutStance, P.module, P.OnEvent, P.PlacePetKeys, P.RANGE_EVENTS, P.RetireBlizzard
local Sprites, UpdateFades, UpdateKey, UpdateLeave, UpdatePet, UpdateRange = P.Sprites, P.UpdateFades, P.UpdateKey, P.UpdateLeave, P.UpdatePet, P.UpdateRange
local UpdateXP = P.UpdateXP


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
	P.inCombat = InCombatLockdown() and true or false
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
	local devices = {{P.console, 'ab.console'}, {P.side, 'ab.side'}, {P.petModule, 'ab.pet'}, {P.stanceModule, 'ab.stance'}}
	for row = 1, 3 do devices[#devices + 1] = {BARS[row].device, 'ab.bar'..row} end
	for _, entry in ipairs(devices) do
		local device = entry[1]
		if device then
			UI:SetMoverBaseScale(entry[2], scale, device)
			if device.shell then device.shell:SetShown(DB().housing ~= false) end
			HW.ShowDecor(device, DB().housing ~= false)
		end
	end
	if P.menu then UI:Safe(LayoutMenu) end
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

local Percent = UI.Util.Percent
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
		{'segmented', 'Docked look', 'actionbars.dockLook', items = {{'embedded', 'Embedded'}, {'float', 'Floating'}}, since = '0.5.2',
			hidden = function() return not DB().dock end,
			note = 'Embedded: each docked frame sits in a bay cut into the console, its name printed over it like a bank\'s; empty bays show an unlit screen. Floating: the frames sit on the console in their own housings.'},
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
