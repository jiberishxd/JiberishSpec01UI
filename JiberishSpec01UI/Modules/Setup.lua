-- The setup guide: a SPEC-01 device that walks through the main choices once,
-- the first time the addon runs, and again whenever it is opened from the hub.
-- Each step changes the real setting and shows it live; styles that need a
-- reload are collected and applied with one reload at the end. There is also a
-- short tour of the hub window.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent = CreateFrame, UIParent
local max, min = math.max, math.min

-- Whether the guide has run is account-wide state (UI:Account), outside every profile.
local function Done() return UI:Account('setup').done end

local guide
local WIDTH, HEIGHT, RAIL = 640, 420, 176

local function Set(path, value, reload)
	Kit:SetOption(path, value)
	if reload then UI:NeedsReload() end
end

-- A segmented control bound to one setting. items: {{value, text}}
local function Choice(body, path, items, width, reload, onPick)
	local names, values, current = {}, {}, 1
	for index, item in ipairs(items) do
		values[index], names[index] = item[1], item[2]
		if item[1] == UI.ReadOption(path) then current = index end
	end
	local control = Kit:Segmented(body, {items = names, width = width or 300, value = current, onChange = function(index)
		Set(path, values[index], reload)
		if onPick then onPick(values[index]) end
	end})
	control.refresh = function()
		local value = UI.ReadOption(path)
		for index, item in ipairs(values) do
			if item == value then control:SetValue(index) end
		end
		if onPick then onPick(value) end
	end
	return control
end

local function Caption(body, text, anchor, x, y)
	local label = Kit:Label(body, text, 'dim', 8, true)
	label:SetPoint('TOPLEFT', anchor or body, anchor and 'BOTTOMLEFT' or 'TOPLEFT', x or 0, y or 0)
	return label
end

-- Steps ------------------------------------------------------------------------------
local STEPS = {
	{title = 'Welcome', text = 'This guide sets up the interface in about a minute. Every choice here can be changed later in the hub: type /spec.',
		build = function(body, step)
			local lcd = Kit:LCDPanel(body)
			lcd:SetSize(260, 64)
			lcd:SetPoint('TOPLEFT', 0, -4)
			lcd.ghost = Kit:Text(lcd, '888-88', 30, 'lcdDim', true)
			lcd.ghost:SetPoint('CENTER')
			lcd.ghost:SetAlpha(0.18)
			lcd.digits = Kit:Text(lcd, 'SPEC-01', 30, 'lcdInk', true)
			lcd.digits:SetPoint('CENTER')
			step.meter = Kit:Meter(body, {label = 'Ready', width = 260})
			step.meter:SetPoint('TOPLEFT', lcd, 'BOTTOMLEFT', 0, -18)
			local note = Kit:Text(body, 'Next and Back move between steps. Skip closes the guide; it will not open by itself again.', 9, 'dim')
			note:SetPoint('TOPLEFT', step.meter, 'BOTTOMLEFT', 0, -18)
			note:SetWidth(400)
			note:SetJustifyH('LEFT')
		end,
		refresh = function(_, step)
			step.meter:SetValue(0)
			step.meter:SetValue(1, true)
		end},

	{title = 'Finish and key color', text = 'Paper is the reference: light housings and black displays. Graphite darkens the same parts. The key color lights lamps, dots and primary keys.',
		build = function(body, step)
			local finish = Caption(body, 'Finish')
			step.finish = Choice(body, 'finish', {{'paper', 'Paper'}, {'graphite', 'Graphite'}}, 220)
			step.finish:SetPoint('TOPLEFT', finish, 'BOTTOMLEFT', 0, -6)
			local accent = Caption(body, 'Key color', step.finish, 0, -16)
			step.swatches = {}
			for index, name in ipairs(Kit.accentOrder) do
				local swatch = CreateFrame('Button', nil, body)
				swatch:SetSize(20, 20)
				swatch:SetPoint('TOPLEFT', accent, 'BOTTOMLEFT', 3 + (index - 1) * 30, -9)
				swatch.ring = Kit:Texture(swatch, 'circle-ring', 'BACKGROUND')
				swatch.ring:SetPoint('TOPLEFT', -3, 3)
				swatch.ring:SetPoint('BOTTOMRIGHT', 3, -3)
				Kit:Tint(swatch.ring, 'ink')
				swatch.dot = Kit:Texture(swatch, 'circle', 'ARTWORK')
				swatch.dot:SetAllPoints()
				Kit:Tint(swatch.dot, Kit.accentSkin[name].key)
				swatch:SetScript('OnClick', function()
					Kit:Play('down')
					Set('accent', name)
				end)
				step.swatches[name] = swatch
			end
			-- Live preview: a primary key, a switch, a meter and a lamp.
			local preview = Caption(body, 'Preview', accent, 0, -44)
			local key = Kit:Key(body, {width = 96, height = 30, tone = 'primary', text = 'Engage'})
			key:SetPoint('TOPLEFT', preview, 'BOTTOMLEFT', 0, -8)
			local switch = Kit:Switch(body, {labels = false, checked = true})
			switch:SetPoint('LEFT', key, 'RIGHT', 16, 0)
			local lamp = Kit:Led(body, 7, true)
			lamp:SetPoint('LEFT', switch, 'RIGHT', 16, 0)
			step.meter = Kit:Meter(body, {label = 'Level', width = 180, value = 0.62})
			step.meter:SetPoint('LEFT', lamp, 'RIGHT', 16, 4)
		end,
		refresh = function(_, step)
			step.finish.refresh()
			for name, swatch in pairs(step.swatches) do swatch.ring:SetShown(UI.db.accent == name) end
		end},

	{title = 'Interface scale', text = 'The size of the whole interface. Pixel perfect makes one interface unit one screen pixel, for the sharpest edges; it can be small on large screens.',
		build = function(body, step)
			step.slider = Kit:Slider(body, {label = 'UI scale', min = 0.4, max = 1.15, step = 0.01, value = UI.db.uiScale or UIParent:GetScale(),
				width = 300, ticks = 10, format = function(value) return format('%.2f', value) end,
				onChange = function(value) Set('uiScale', value) end})
			step.slider:SetPoint('TOPLEFT', 0, -4)
			step.perfect = Kit:Key(body, {width = 120, height = 28, text = 'Pixel perfect'})
			step.perfect:SetPoint('TOPLEFT', step.slider, 'BOTTOMLEFT', 0, -12)
			step.perfect.onClick = function()
				local scale = UI.Pixel.PerfectScale()
				Set('uiScale', scale)
				step.slider:SetValue(scale)
				step.paint()
			end
			local lcd = Kit:LCDPanel(body)
			lcd:SetSize(220, 52)
			lcd:SetPoint('TOPLEFT', step.perfect, 'BOTTOMLEFT', 0, -16)
			lcd.ghost = Kit:Text(lcd, '8.88', 22, 'lcdDim', true)
			lcd.ghost:SetPoint('LEFT', 12, 0)
			lcd.ghost:SetAlpha(0.18)
			lcd.digits = Kit:Text(lcd, '', 22, 'lcdInk', true)
			lcd.digits:SetPoint('LEFT', 12, 0)
			lcd.screen = Kit:Label(lcd, '', 'lcdDim', 8)
			lcd.screen:SetPoint('RIGHT', -12, 0)
			step.paint = function()
				local width, height = GetPhysicalScreenSize()
				lcd.digits:SetText(format('%.2f', UI.db.uiScale or UIParent:GetScale()))
				lcd.screen:SetText(format('%d x %d', width or 0, height or 0))
			end
		end,
		refresh = function(_, step)
			step.slider:SetValue(UI.db.uiScale or UIParent:GetScale())
			step.paint()
		end},

	{title = 'Action bars', text = 'Console puts your keys in one device along the bottom, with the player and target frames built into it. Free gives each bar a device of its own to place anywhere.',
		build = function(body, step)
			local function Mini(parent, keys, rows, width)
				local device = CreateFrame('Frame', nil, parent)
				device:SetSize(width, rows * 12 + 18)
				device.shell = Kit:Shell(device, {surface = 'paper', radius = 6, shadow = false})
				for row = 1, rows do
					for index = 1, keys do
						local key = Kit:Solid(device, 'key', 'ARTWORK')
						key:SetSize(8, 8)
						key:SetPoint('BOTTOMLEFT', 8 + (index - 1) * 10, 6 + (row - 1) * 12)
					end
				end
				return device
			end
			step.choice = Choice(body, 'actionbars.layout', {{'console', 'Console'}, {'free', 'Free'}}, 220, true, function(value)
				if step.console then
					step.console:SetShown(value ~= 'free')
					step.free:SetShown(value == 'free')
				end
			end)
			step.choice:SetPoint('TOPLEFT', 0, -4)
			step.console = CreateFrame('Frame', nil, body)
			step.console:SetSize(420, 90)
			step.console:SetPoint('TOPLEFT', step.choice, 'BOTTOMLEFT', 0, -20)
			local housing = CreateFrame('Frame', nil, step.console)
			housing:SetSize(400, 70)
			housing:SetPoint('TOPLEFT')
			housing.shell = Kit:Shell(housing, {surface = 'paper', radius = 8, shadow = false})
			for side = 1, 2 do
				local unit = CreateFrame('Frame', nil, housing)
				unit:SetSize(74, 46)
				unit:SetPoint(side == 1 and 'LEFT' or 'RIGHT', side == 1 and 10 or -10, 0)
				unit.shell = Kit:Shell(unit, {surface = 'screen', radius = 4, shadow = false})
			end
			for row = 1, 3 do
				for index = 1, 12 do
					local key = Kit:Solid(housing, 'key', 'ARTWORK')
					key:SetSize(14, 14)
					key:SetPoint('BOTTOMLEFT', 96 + (index - 1) * 17, 6 + (row - 1) * 18)
				end
			end
			step.free = CreateFrame('Frame', nil, body)
			step.free:SetSize(420, 90)
			step.free:SetPoint('TOPLEFT', step.choice, 'BOTTOMLEFT', 0, -20)
			Mini(step.free, 12, 1, 132):SetPoint('BOTTOMLEFT', 0, 0)
			Mini(step.free, 12, 1, 132):SetPoint('BOTTOMLEFT', 140, 0)
			Mini(step.free, 12, 1, 132):SetPoint('BOTTOMLEFT', 70, 34)
			Mini(step.free, 1, 6, 26):SetPoint('BOTTOMLEFT', 300, 0)
		end,
		refresh = function(_, step) step.choice.refresh() end},

	{title = 'Unit frames', text = 'The shape of the player, target and other frames. Device has a header, a portrait and an LCD. Bar is a rectangle that is all meter. Square is a tile with big digits. Slim is a thin line. LCD strip is a gray readout. Each frame can pick its own later.',
		build = function(body, step)
			local shapes = {{'device', 'Device'}, {'bar', 'Bar'}, {'square', 'Square'}, {'slim', 'Slim'}, {'lcdstrip', 'LCD strip'}}
			local names = {}
			for index, item in ipairs(shapes) do names[index] = item[2] end
			-- A small drawing of each shape, built from the same parts.
			local function Meter(parent, width, height)
				local track = CreateFrame('Frame', nil, parent)
				track:SetSize(width, height)
				track.shell = Kit:Shell(track, {surface = 'lcd', radius = 99, shadow = false, fill = 'track'})
				local fill = track:CreateTexture(nil, 'ARTWORK')
				fill:SetPoint('TOPLEFT', 2, -2)
				fill:SetPoint('BOTTOMLEFT', 2, 2)
				fill:SetWidth((width - 4) * 0.72)
				fill:SetColorTexture(1, 1, 1, 1)
				Kit:Tint(fill, 'lamp')
				return track
			end
			local previews = {}
			local function Preview(shape)
				local frame = CreateFrame('Frame', nil, body)
				if shape == 'device' then
					frame:SetSize(224, 70)
					frame.shell = Kit:Shell(frame, {surface = 'paper', radius = 8, shadow = false})
					local portrait = Kit:Screen(frame, {inset = 2, radius = 5, shadow = false})
					portrait:SetSize(42, 42)
					portrait:SetPoint('TOPLEFT', 7, -21)
					Kit:Label(frame, 'UF-1  Player', 'ink', 8, true):SetPoint('TOPLEFT', 7, -6)
					local lcd = Kit:LCDPanel(frame)
					lcd:SetSize(162, 20)
					lcd:SetPoint('TOPLEFT', portrait, 'TOPRIGHT', 6, 0)
					Kit:Text(lcd, '72', 13, 'lcdInk'):SetPoint('RIGHT', -6, 0)
					Meter(frame, 162, 10):SetPoint('TOPLEFT', lcd, 'BOTTOMLEFT', 0, -3)
				elseif shape == 'bar' then
					frame:SetSize(224, 30)
					frame.shell = Kit:Shell(frame, {surface = 'paper', radius = 6, shadow = false})
					local meter = Meter(frame, 218, 24)
					meter:SetPoint('CENTER')
					local name = Kit:Text(meter, 'PLAYER', 10, 'white', true)
					name:SetPoint('LEFT', 8, 0)
					local digits = Kit:Text(meter, '72', 10, 'white', true)
					digits:SetPoint('RIGHT', -8, 0)
				elseif shape == 'square' then
					frame:SetSize(76, 76)
					frame.shell = Kit:Shell(frame, {surface = 'paper', radius = 8, shadow = false})
					Kit:Label(frame, 'Player', 'ink', 8, true):SetPoint('TOPLEFT', 5, -5)
					local lcd = Kit:LCDPanel(frame)
					lcd:SetSize(66, 40)
					lcd:SetPoint('TOPLEFT', 5, -17)
					Kit:Text(lcd, '72', 22, 'lcdInk'):SetPoint('CENTER')
					Meter(frame, 66, 8):SetPoint('TOPLEFT', lcd, 'BOTTOMLEFT', 0, -3)
				elseif shape == 'slim' then
					frame:SetSize(200, 26)
					Kit:Text(frame, 'PLAYER', 9, 'ink', true):SetPoint('TOPLEFT', 0, 0)
					Kit:Text(frame, '72', 9, 'ink', true):SetPoint('TOPRIGHT', 0, 0)
					Meter(frame, 200, 8):SetPoint('BOTTOMLEFT')
				else
					frame:SetSize(224, 40)
					frame.shell = Kit:Shell(frame, {surface = 'lcd', radius = 6, shadow = false})
					Kit:Text(frame, 'PLAYER', 9, 'lcdInk', true):SetPoint('TOPLEFT', 6, -5)
					Kit:Text(frame, '72', 11, 'lcdInk'):SetPoint('TOPRIGHT', -6, -4)
					Meter(frame, 212, 8):SetPoint('BOTTOMLEFT', 6, 6)
				end
				frame:Hide()
				return frame
			end
			local function Show(value)
				for shape, preview in pairs(previews) do preview:SetShown(shape == value) end
			end
			local function Current()
				local value = UI.ReadOption('unitframes.shape')
				for index, item in ipairs(shapes) do if item[1] == value then return index end end
				return 1
			end
			step.choice = Kit:Segmented(body, {items = names, width = 400, value = Current(), onChange = function(index)
				if UI.SetUnitFrameShape then UI:SetUnitFrameShape(shapes[index][1]) end
				Kit:Apply()
				Show(shapes[index][1])
			end})
			step.choice:SetPoint('TOPLEFT', 0, -4)
			for _, item in ipairs(shapes) do
				previews[item[1]] = Preview(item[1])
				previews[item[1]]:SetPoint('TOPLEFT', step.choice, 'BOTTOMLEFT', 0, -22)
			end
			step.choice.refresh = function()
				step.choice:SetValue(Current())
				Show(shapes[Current()][1])
			end
		end,
		refresh = function(_, step) step.choice.refresh() end},

	{title = 'Chat', text = 'Device sets messages on a black display in a housing, with the tabs in its header and a glass field for typing.',
		build = function(body, step)
			step.choice = Choice(body, 'style.chat', {{'display', 'Device'}, {'blizzard', 'Blizzard'}}, 220, true)
			step.choice:SetPoint('TOPLEFT', 0, -4)
			local screen = Kit:Screen(body, {inset = 3, radius = 6})
			screen:SetSize(400, 104)
			screen:SetPoint('TOPLEFT', step.choice, 'BOTTOMLEFT', 0, -18)
			local lines = {
				{'|cff9a9a94[1. General]|r Anyone up for the world boss?'},
				{'|cff40ff40[Guild] Ari:|r pulling in five, ready up'},
				{'|cffff80ff[Whisper] Bram:|r invite when you can'},
				{'|cffffff00You receive loot: Spare Cog x3|r'},
			}
			for index, line in ipairs(lines) do
				local text = Kit:Text(screen.screen, line[1], 10, 'darkInk')
				text:SetPoint('TOPLEFT', 10, -8 - (index - 1) * 16)
			end
			local field = CreateFrame('Frame', nil, body)
			field:SetSize(400, 24)
			field:SetPoint('TOPLEFT', screen, 'BOTTOMLEFT', 0, -6)
			field.shell = Kit:Shell(field, {surface = 'glass', radius = 4, shadow = false})
			local hint = Kit:Label(field, 'Press Enter to chat', 'darkDim', 8)
			hint:SetPoint('LEFT', 10, 0)
		end,
		refresh = function(_, step) step.choice.refresh() end},

	{title = 'Nameplates', text = 'Plates over enemies and friends: a dark glass strip with the level, name and health. Dots matches the unit frames; Pill and Bar are smooth.',
		build = function(body, step)
			local plate = CreateFrame('Frame', nil, body)
			step.choice = Choice(body, 'style.nameplates', {{'dots', 'Dots'}, {'pill', 'Pill'}, {'bar', 'Bar'}, {'blizzard', 'Blizzard'}}, 320, true,
				function(value)
					if not step.bar then return end
					if value == 'dots' then Kit:Perforate(step.bar, 'glass', 'darkEdge') else Kit:Unperforate(step.bar) end
					plate:SetAlpha(value == 'blizzard' and 0.35 or 1)
				end)
			step.choice:SetPoint('TOPLEFT', 0, -4)
			plate:SetSize(220, 40)
			plate:SetPoint('TOPLEFT', step.choice, 'BOTTOMLEFT', 40, -34)
			plate.shell = Kit:Shell(plate, {surface = 'glass', radius = 4, shadow = false})
			local lamp = Kit:Led(plate, 5, true)
			lamp:SetPoint('TOPLEFT', 8, -8)
			local chip = Kit:LCDPanel(plate)
			chip:SetSize(26, 13)
			chip:SetPoint('LEFT', lamp, 'RIGHT', 6, 0)
			local level = Kit:Text(chip, '62', 8, 'lcdInk', true)
			level:SetPoint('CENTER')
			local name = Kit:Label(plate, 'Training dummy', 'darkInk', 8, true)
			name:SetPoint('LEFT', chip, 'RIGHT', 6, 0)
			local percent = Kit:Label(plate, '64%', 'darkDim', 8)
			percent:SetPoint('TOPRIGHT', -8, -8)
			local track = CreateFrame('Frame', nil, plate)
			track:SetPoint('BOTTOMLEFT', 8, 7)
			track:SetPoint('BOTTOMRIGHT', -8, 7)
			track:SetHeight(8)
			track.shell = Kit:Shell(track, {surface = 'screen', radius = 2, shadow = false})
			step.bar = CreateFrame('StatusBar', nil, track)
			step.bar:SetPoint('TOPLEFT', 1, -1)
			step.bar:SetPoint('BOTTOMRIGHT', -1, 1)
			step.bar:SetStatusBarTexture([[Interface\Buttons\WHITE8X8]])
			step.bar:SetMinMaxValues(0, 1)
			step.bar:SetValue(0.64)
			Kit:Tint(step.bar, 'accent')
		end,
		refresh = function(_, step) step.choice.refresh() end},

	{title = 'Sounds', text = 'SPEC-01 sounds for keys, switches, windows and notifications. They play on the channel set in the hub and follow the game\'s volume.',
		build = function(body, step)
			local all = Caption(body, 'All sounds')
			step.all = Kit:Switch(body, {checked = UI.db.sound.enable, onChange = function(value) Set('sound.enable', value) end})
			step.all:SetPoint('TOPLEFT', all, 'BOTTOMLEFT', 26, -6)
			local interface = Caption(body, 'Windows, tabs and checkboxes', all, 0, -48)
			step.interface = Kit:Switch(body, {checked = UI.db.sound.interface, onChange = function(value) Set('sound.interface', value) end})
			step.interface:SetPoint('TOPLEFT', interface, 'BOTTOMLEFT', 26, -6)
			local test = Kit:Key(body, {width = 110, height = 30, tone = 'primary', text = 'Test sound', sound = false})
			test:SetPoint('TOPLEFT', interface, 'BOTTOMLEFT', 0, -50)
			test.onClick = function()
				Kit:Play('down-primary', true)
				C_Timer.After(0.25, function() Kit:Play('success', true) end)
			end
		end,
		refresh = function(_, step)
			step.all:SetValue(UI.db.sound.enable)
			step.interface:SetValue(UI.db.sound.interface)
		end},

	{title = 'Done', text = '',
		build = function(body, step)
			step.summary = Kit:Text(body, '', 10, 'ink')
			step.summary:SetPoint('TOPLEFT', 0, -4)
			step.summary:SetWidth(420)
			step.summary:SetJustifyH('LEFT')
			step.summary:SetSpacing(5)
		end,
		refresh = function(_, step)
			local function Name(path, names)
				local value = UI.ReadOption(path)
				return names[value] or tostring(value)
			end
			local lines = {
				'Finish: '..Name('finish', {paper = 'Paper', graphite = 'Graphite'}),
				'UI scale: '..format('%.2f', UI.db.uiScale or UIParent:GetScale()),
				'Action bars: '..Name('actionbars.layout', {console = 'Console', free = 'Free'}),
				'Chat: '..Name('style.chat', {display = 'Device', blizzard = 'Blizzard'}),
				'Nameplates: '..Name('style.nameplates', {dots = 'Dots', pill = 'Pill', bar = 'Bar', blizzard = 'Blizzard'}),
				'Sounds: '..(UI.db.sound.enable and 'On' or 'Off'),
				'',
				UI.reloadPending and 'Some of these take effect after a reload. Finish reloads the interface now.'
					or 'Everything is already in place. Open the hub any time with /spec.',
			}
			step.summary:SetText(table.concat(lines, '\n'))
		end},
}

-- The device --------------------------------------------------------------------------
local function ShowStep(index)
	index = Kit:Clamp(index, 1, #STEPS)
	guide.index = index
	local step = STEPS[index]
	for number, entry in ipairs(guide.rail) do
		Kit:SetLed(entry.led, number <= index, number < index and 'green' or nil)
		Kit:Tint(entry.label, number == index and 'ink' or 'dim')
	end
	guide.count:SetText(format('%02d/%02d', index, #STEPS))
	guide.heading:SetText(strupper(step.title))
	guide.text:SetText(step.text)
	for number, other in ipairs(STEPS) do
		if other.body and number ~= index then other.body:Hide() end
	end
	if not step.body then
		step.body = CreateFrame('Frame', nil, guide)
		step.body:SetPoint('TOPLEFT', guide.text, 'BOTTOMLEFT', 0, -16)
		step.body:SetSize(WIDTH - RAIL - 40, 210)
		UI:Safe(step.build, step.body, step)
	end
	step.body:SetAlpha(0)
	step.body:Show()
	Kit:FadeTo(step.body, 1, 'NORMAL')
	if step.refresh then UI:Safe(step.refresh, step.body, step) end
	guide.back:SetKeyEnabled(index > 1)
	guide.next:SetKeyText(index == #STEPS and (UI.reloadPending and 'Reload' or 'Finish') or 'Next')
end

local function Finish(reload)
	UI:Account('setup').done = true
	Kit:Close(guide)
	if reload and UI.reloadPending then ReloadUI() end
end

local function Build()
	guide = Kit:Device(UIParent, {model = 'SG-1', title = 'Setup guide', width = WIDTH, height = HEIGHT, name = 'JiberishSpec01Setup'})
	guide:SetFrameStrata('FULLSCREEN_DIALOG')
	guide:SetFrameLevel(150)
	Kit:Relevel(guide)
	guide:SetPoint('CENTER', 0, 30)
	guide:EnableMouse(true)
	guide:SetMovable(true)
	guide:SetClampedToScreen(true)
	guide:RegisterForDrag('LeftButton')
	guide:SetScript('OnDragStart', guide.StartMoving)
	guide:SetScript('OnDragStop', guide.StopMovingOrSizing)
	tinsert(UISpecialFrames, 'JiberishSpec01Setup')
	Kit:SetLed(guide.lamp, true)

	-- The step rail: an LCD count over a column of lamps, one per step.
	local lcd = Kit:LCDPanel(guide)
	lcd:SetSize(RAIL - 28, 40)
	lcd:SetPoint('TOPLEFT', 14, -32)
	local ghost = Kit:Text(lcd, '88/88', 20, 'lcdDim', true)
	ghost:SetPoint('CENTER')
	ghost:SetAlpha(0.18)
	guide.count = Kit:Text(lcd, '', 20, 'lcdInk', true)
	guide.count:SetPoint('CENTER')
	guide.rail = {}
	for index, step in ipairs(STEPS) do
		local entry = CreateFrame('Button', nil, guide)
		entry:SetSize(RAIL - 28, 26)
		entry:SetPoint('TOPLEFT', lcd, 'BOTTOMLEFT', 0, -10 - (index - 1) * 30)
		entry.led = Kit:Led(entry, 6, false)
		entry.led:SetPoint('LEFT', 4, 0)
		entry.number = Kit:Label(entry, format('%02d', index), 'dim', 8, true)
		entry.number:SetPoint('LEFT', 16, 0)
		entry.label = Kit:Label(entry, step.title, 'dim', 8)
		entry.label:SetPoint('LEFT', 38, 0)
		entry.label:SetPoint('RIGHT', -2, 0)
		entry.label:SetJustifyH('LEFT')
		entry.label:SetWordWrap(false)
		entry:SetScript('OnClick', function()
			if guide.index == index then return end
			Kit:Play('tick')
			ShowStep(index)
		end)
		guide.rail[index] = entry
	end
	local rule = Kit:Solid(guide, 'line')
	rule:SetWidth(1)
	rule:SetPoint('TOPLEFT', RAIL - 4, -32)
	rule:SetPoint('BOTTOMLEFT', RAIL - 4, 56)

	guide.heading = Kit:Text(guide, '', 15, 'ink', true)
	guide.heading:SetPoint('TOPLEFT', RAIL + 10, -34)
	guide.text = Kit:Text(guide, '', 10, 'dim')
	guide.text:SetPoint('TOPLEFT', guide.heading, 'BOTTOMLEFT', 0, -8)
	guide.text:SetWidth(WIDTH - RAIL - 40)
	guide.text:SetJustifyH('LEFT')
	guide.text:SetSpacing(3)

	guide.skip = Kit:Key(guide, {width = 84, height = 28, text = 'Skip'})
	guide.skip:SetPoint('BOTTOMLEFT', 14, 14)
	guide.skip.onClick = function() Finish(false) end
	guide.next = Kit:Key(guide, {width = 96, height = 28, tone = 'primary', text = 'Next'})
	guide.next:SetPoint('BOTTOMRIGHT', -14, 14)
	guide.next.onClick = function()
		if guide.index >= #STEPS then return Finish(true) end
		ShowStep(guide.index + 1)
	end
	guide.back = Kit:Key(guide, {width = 84, height = 28, text = 'Back'})
	guide.back:SetPoint('RIGHT', guide.next, 'LEFT', -8, 0)
	guide.back.onClick = function()
		if guide.index > 1 then ShowStep(guide.index - 1) end
	end
	guide:Hide()
end

function UI:OpenSetup(index)
	if not guide then Build() end
	ShowStep(index or 1)
	if not guide:IsShown() or guide.kitClosing then
		Kit:Play('open')
		Kit:Open(guide)
	end
end

-- The tour -------------------------------------------------------------------------------
-- A few stops around the hub window, each a popover pointing at one part of it.
local TOUR = {
	{'search', 'RIGHT', 'Search', 'Type any word to find a setting on every page at once.'},
	{'nav', 'RIGHT', 'Sections', 'Each part of the interface has a page. A red lamp beside one means it failed to start.'},
	{'finish', 'BOTTOM', 'Finish and key color', 'Change the look here, live, from any page.'},
	{'sound', 'BOTTOM', 'Sound key', 'Turns every SPEC-01 sound on or off.'},
	{'close', 'BOTTOM', 'Come back any time', 'Type /spec to open this window. The setup guide is on the Setup page.'},
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
local driver = CreateFrame('Frame')
driver:RegisterEvent('PLAYER_LOGIN')
driver:SetScript('OnEvent', function()
	if Done() then return end
	C_Timer.After(5, function()
		if Done() then return end
		UI:AfterCombat(function() UI:OpenSetup(1) end, 'setup.open')
	end)
end)

UI:RegisterPage('setup', {title = 'Setup', order = 3, since = '0.5.0', cards = {
	{title = 'Setup guide', rows = {
		{'note', 'Eight short steps through the main choices: finish and key color, scale, action bars, chat, nameplates and sounds. Each one changes the real setting as you go.'},
		{'button', 'Setup guide', 'Start', function() UI:OpenSetup(1) end},
		{'button', 'Tour of this window', 'Start', function() UI:StartTour() end},
	}},
}})
