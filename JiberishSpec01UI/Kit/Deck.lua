-- The component deck: one window that shows every Hardware kit element working,
-- numbered like the reference sheet. Open it with /spec deck.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent = CreateFrame, UIParent
local floor, max, min, random = math.floor, math.max, math.min, math.random

local COLUMN, GAP, PAD = 200, 12, 16
local deck, tickers = nil, {}

local function Toast(title, text, tone) Kit:Toast({title = title, text = text, tone = tone}) end

local function Caption(body, text)
	local label = Kit:Label(body, text, 'ink', 8)
	label:SetPoint('TOPLEFT')
	return label
end

-- {number, title, column span, build(body), height}
local modules = {
	{1, 'Button', 1, function(body)
		Kit:Button(body, {text = 'Play', tone = 'primary', width = 56}):SetPoint('CENTER', -54, 4)
		Kit:Button(body, {text = 'Stop', width = 56}):SetPoint('CENTER', 8, 4)
		local record = Kit:Button(body, {round = true, icon = 'record', width = 36, height = 36})
		record:SetPoint('CENTER', 62, 4)
		Kit:Tint(record.icon, 'accent')
	end},
	{2, 'Switch', 1, function(body)
		Kit:Label(body, 'Power', 'ink', 8):SetPoint('CENTER', 0, 24)
		Kit:Switch(body, {checked = true}):SetPoint('CENTER', 0, 0)
	end},
	{3, 'Checkbox', 1, function(body)
		for index, text in ipairs({'Sync', 'Loop', 'Metro'}) do
			Kit:Checkbox(body, {text = text, checked = index == 2}):SetPoint('CENTER', (index - 2) * 56, 0)
		end
	end},
	{4, 'Segmented control', 1, function(body)
		Caption(body, 'Pattern')
		Kit:Segmented(body, {items = {'1', '2', '3', '4'}, width = 176}):SetPoint('CENTER', 0, -4)
	end},
	{5, 'Slider', 2, function(body)
		Kit:Slider(body, {label = 'Volume', value = 64, width = 380}):SetPoint('CENTER', 0, 0)
	end},
	{6, 'Flat knob', 2, function(body)
		for index, data in ipairs({{'Tone', 30}, {'Drive', 72}, {'Space', 50}, {'Mix', 18}}) do
			Kit:Knob(body, {label = data[1], value = data[2]}):SetPoint('CENTER', (index - 2.5) * 90, 0)
		end
	end},
	{7, 'Text field', 1, function(body)
		Kit:TextField(body, {label = 'Project', value = 'untitled_04', width = 176}):SetPoint('CENTER')
	end},
	{8, 'Select', 1, function(body)
		Kit:Select(body, {label = 'Sample rate', width = 176, value = 5,
			items = {'22.05 kHz', '32 kHz', '44.1 kHz', '47.25 kHz', '48 kHz', '50 kHz', '88.2 kHz', '96 kHz', '192 kHz'}}):SetPoint('CENTER')
	end},
	{9, 'Meter', 1, function(body)
		Kit:Meter(body, {label = 'CPU', value = 0.68, width = 176}):SetPoint('CENTER')
	end},
	{10, 'Menu', 1, function(body)
		local key = Kit:Button(body, {round = true, icon = 'more'})
		key:SetPoint('CENTER')
		key.onClick = function(self)
			Kit:Menu(self, {'Rename', 'Duplicate', {separator = true}, {text = 'Delete', icon = 'trash'}},
				function(_, item) Toast(item.text) end, {width = 150, indent = true})
		end
	end},
	{11, 'Dialog', 1, function(body)
		local key = Kit:Button(body, {text = 'Delete', width = 72})
		key:SetPoint('CENTER')
		key.onClick = function()
			Kit:Dialog({title = 'Delete pattern?', text = 'Pattern 3 and its automation will be removed from this project.',
				actions = {{text = 'Cancel'}, {text = 'Delete', tone = 'primary', onClick = function() Toast('Pattern deleted', nil, 'success') end}}})
		end
	end},
	{12, 'Tabs', 2, function(body)
		Kit:Tabs(body, {width = 380, items = {
			{text = 'Mix', body = 'Levels, pan and sends for every track on the current pattern.'},
			{text = 'Edit', body = 'Step, length and swing for the selected track.'},
			{text = 'FX', body = 'Two send effects and a master compressor.'}}}):SetPoint('CENTER', 0, -4)
	end},
	{13, 'Calendar', 2, function(body)
		Kit:Calendar(body, {onSet = function(value)
			Toast('Date set', format('%04d-%02d-%02d', value.year, value.month, value.day), 'success')
		end}):SetPoint('CENTER')
	end},
	{14, 'Radio group', 1, function(body)
		Caption(body, 'Sync source')
		Kit:RadioGroup(body, {items = {'Internal', 'MIDI', 'USB'}, keyWidth = 56, gap = 4, value = 1}):SetPoint('CENTER', 0, -4)
	end},
	{15, 'Number stepper', 1, function(body)
		Caption(body, 'Tempo')
		Kit:Stepper(body, {value = 120, min = 40, max = 240}):SetPoint('CENTER', 0, -4)
	end},
	{16, 'Accordion', 2, function(body)
		Kit:Accordion(body, {width = 380, open = 1, items = {
			{title = 'Storage', body = '64 GB internal. Projects back up to your computer over USB-C.'},
			{title = 'Battery', body = 'About nine hours of playback on a full charge.'},
			{title = 'Updates', body = 'Firmware 2.14 is installed. You are up to date.'}}}):SetPoint('TOP')
	end, 190},
	{17, 'Toolbar', 1, function(body)
		Kit:Toolbar(body, {items = {{text = 'B', toggle = true, checked = true, tooltip = 'Bold'},
			{text = 'I', toggle = true, tooltip = 'Italic'}, {text = 'U', toggle = true, tooltip = 'Underline'},
			'separator', {icon = 'trash', tooltip = 'Clear'}}}):SetPoint('CENTER')
	end, 190},
	{18, 'Pagination', 2, function(body)
		Kit:Pagination(body, {width = 380, pages = 9, value = 3}):SetPoint('CENTER')
	end},
	{19, 'Tooltip', 1, function(body)
		local key = Kit:Button(body, {round = true, icon = 'info'})
		key:SetPoint('CENTER')
		Kit:AttachTooltip(key, 'Quantize to the grid')
	end},
	{20, 'Popover', 1, function(body)
		local key = Kit:Button(body, {text = 'Share', width = 72})
		key:SetPoint('CENTER')
		key.onClick = function(self)
			Kit:Popover(self, {width = 220, height = 96, build = function(panel)
				local field = Kit:TextField(panel, {label = 'Share link', value = 'jiberish.ui/deck', width = 196})
				field:SetPoint('TOP', 0, -10)
				local copy = Kit:Button(panel, {text = 'Copy', tone = 'primary', width = 64, height = 24})
				copy:SetPoint('BOTTOMRIGHT', -12, 8)
				copy.onClick = function() Kit:ClosePopover(); Toast('Link copied', nil, 'success') end
			end})
		end
	end},
	{21, 'Toast', 1, function(body)
		local key = Kit:Button(body, {text = 'Save', tone = 'primary', width = 72})
		key:SetPoint('CENTER')
		key.onClick = function()
			Kit:Toast({title = 'Project saved', text = 'untitled_04, just now', tone = 'success', action = {text = 'Undo'}})
		end
	end},
	{22, 'Combobox', 1, function(body)
		Kit:Combobox(body, {label = 'Framework', placeholder = 'Search...', width = 176,
			items = {'Unit frames', 'Action bars', 'Chat', 'Tooltips', 'Windows', 'Sounds'}}):SetPoint('CENTER')
	end},
	{23, 'Date picker', 1, function(body)
		Kit:DatePicker(body, {label = 'Release date', width = 176}):SetPoint('CENTER')
	end},
	{24, 'Textarea', 1, function(body)
		Kit:TextArea(body, {label = 'Notes', placeholder = 'What changed in this release?', width = 176, height = 84}):SetPoint('CENTER')
	end},
	{25, 'OTP input', 2, function(body)
		Kit:Label(body, 'Verification code', 'ink', 8):SetPoint('CENTER', 0, 30)
		Kit:OTP(body, {onComplete = function(code) Toast('Code accepted', code, 'success') end}):SetPoint('CENTER', 0, 0)
	end},
	{26, 'Toggle group', 1, function(body)
		Kit:ToggleGroup(body, {items = {{icon = 'align-left'}, {icon = 'align-center'}, {icon = 'align-right'}},
			multiple = false, value = 1}):SetPoint('CENTER')
	end},
	{27, 'Menubar', 2, function(body)
		Kit:Menubar(body, {menus = {
			{text = 'File', items = {'New', 'Open', 'Save', {separator = true}, 'Export'}},
			{text = 'View', items = {{text = 'Grid', checked = true}, 'Zoom in', 'Zoom out'}},
			{text = 'Help', items = {'Manual', 'Shortcuts', 'About'}}},
			onSelect = function(_, _, item) Toast(item.text) end}):SetPoint('CENTER')
	end},
	{28, 'Context menu', 1, function(body)
		local area = Kit:Panel(body, {radius = 6, fill = 'page', border = 'hair'})
		area:SetSize(176, 84)
		area:SetPoint('CENTER')
		Kit:Text(area, 'Right-click', 11, 'dim'):SetPoint('CENTER')
		Kit:ContextMenu(area, {'Cut', 'Copy', 'Paste', {separator = true}, 'Inspect'}, function(_, item) Toast(item.text) end)
	end},
	{29, 'Command', 1, function(body)
		Kit:Command(body, {width = 176, items = {
			{text = 'Send test toast', hint = 'T', onClick = function() Toast('Hello from the deck', nil, 'info') end},
			{text = 'Paper finish', icon = 'power', onClick = function() Kit:SetOption('finish', 'paper') end},
			{text = 'Graphite finish', icon = 'power', onClick = function() Kit:SetOption('finish', 'graphite') end},
			{text = 'Close deck', icon = 'close', onClick = function() Kit:ToggleDeck(false) end}}}):SetPoint('CENTER')
	end},
	{30, 'Alert dialog', 1, function(body)
		local key = Kit:Button(body, {text = 'Delete project', icon = 'trash', width = 150})
		key:SetPoint('CENTER')
		key.onClick = function()
			Kit:AlertDialog({title = 'Delete project?', text = 'This removes untitled_04 and every pattern in it. This cannot be undone.',
				confirm = 'Delete', onConfirm = function() Toast('Project deleted', nil, 'error') end})
		end
	end},
	{31, 'Drawer', 1, function(body)
		local key = Kit:Button(body, {text = 'Filters', icon = 'filter', width = 100})
		key:SetPoint('CENTER')
		key.onClick = function()
			Kit:Drawer({key = 'deck-filters', title = 'Filters', width = 440, height = 190, build = function(content)
				Kit:Label(content, 'Only my tracks', 'ink', 8):SetPoint('TOPLEFT', 0, -6)
				Kit:Switch(content, {labels = false}):SetPoint('TOPLEFT', 120, 0)
				Kit:Label(content, 'Muted tracks', 'ink', 8):SetPoint('TOPLEFT', 0, -40)
				Kit:Switch(content, {labels = false, checked = true}):SetPoint('TOPLEFT', 120, -34)
				Kit:Slider(content, {label = 'Minimum length', value = 4, min = 1, max = 16, width = 200, ticks = 15}):SetPoint('TOPRIGHT', 0, 0)
			end})
		end
	end},
	{32, 'Hover card', 1, function(body)
		local link = CreateFrame('Button', nil, body)
		link.label = Kit:Label(link, '@'..(UnitName('player') or 'you'), 'ink')
		link.label:SetPoint('CENTER')
		link:SetSize(link.label:GetStringWidth() + 8, 18)
		link:SetPoint('CENTER')
		local underline = Kit:Solid(link, 'accent')
		underline:SetHeight(1)
		underline:SetPoint('BOTTOMLEFT', 4, 1); underline:SetPoint('BOTTOMRIGHT', -4, 1)
		Kit:HoverCard(link, {width = 190, height = 60, build = function(card)
			Kit:Avatar(card, {unit = 'player', size = 38}):SetPoint('LEFT', 10, 0)
			Kit:Label(card, UnitName('player') or 'Player', 'lcdInk', 10):SetPoint('TOPLEFT', 58, -16)
			Kit:Label(card, 'Online', 'lcdDim', 8):SetPoint('TOPLEFT', 58, -34)
		end})
	end},
	{33, 'Alert', 2, function(body)
		Kit:Alert(body, {title = 'Durability at 18%', text = 'Repair before the next pull, or your gear will break in about four fights.', width = 380}):SetPoint('CENTER')
	end},
	{34, 'Badge', 1, function(body)
		local badges = {{'Ready', 'green'}, {'Building', 'blue'}, {'Degraded', 'amber'}, {'Error', 'red'}, {'Queued', 'dim'}}
		local x, y = 0, 0
		for _, data in ipairs(badges) do
			local badge = Kit:Badge(body, {text = data[1], tone = data[2]})
			if x + badge:GetWidth() > 176 then x, y = 0, y + 26 end
			badge:SetPoint('TOPLEFT', x + 4, -24 - y)
			x = x + badge:GetWidth() + 6
		end
	end},
	{35, 'Avatar', 1, function(body)
		Kit:Avatar(body, {unit = 'player', size = 44}):SetPoint('CENTER', -52, 0)
		Kit:Avatar(body, {name = UnitName('player'), size = 40}):SetPoint('CENTER', 2, 0)
		Kit:Avatar(body, {name = 'Jiberish Spec', size = 30}):SetPoint('CENTER', 48, 0)
	end},
	{36, 'Breadcrumb', 1, function(body)
		Kit:Breadcrumb(body, {items = {'Azeroth', 'Dornogal', 'Bank'}}):SetPoint('CENTER')
	end},
	{37, 'Progress', 1, function(body)
		local progress = Kit:Progress(body, {label = 'Uploading', value = 0.42, width = 176})
		progress:SetPoint('CENTER')
		tickers[#tickers + 1] = {2.5, function() progress:SetValue(random(10, 100) / 100, true) end}
	end},
	{38, 'Collapsible', 1, function(body)
		Kit:Collapsible(body, {title = 'Advanced', body = 'Swing, humanize and per-step probability.', width = 176}):SetPoint('TOP', 0, -20)
	end},
	{39, 'Carousel', 2, function(body)
		Kit:Carousel(body, {items = {'Tank', 'Healer', 'Damage', 'Support'}, width = 380}):SetPoint('CENTER')
	end},
	{40, 'Resizable', 2, function(body)
		Kit:Resizable(body, {labels = {'Files', 'Editor'}, width = 380, height = 96, split = 0.35}):SetPoint('CENTER')
	end},
	{41, 'Scroll area', 1, function(body)
		local area = Kit:ScrollArea(body, {width = 176, height = 120, step = 24})
		area:SetPoint('CENTER')
		local versions = {'1.7.0', '1.6.2', '1.6.1', '1.6.0', '1.5.0', '1.4.9', '1.4.8', '1.4.7', '1.4.6', '1.4.5', '1.4.0', '1.3.0'}
		for index, version in ipairs(versions) do
			local row = Kit:Label(area.content, 'v'..version, 'ink', 9)
			row:SetPoint('TOPLEFT', 8, -8 - (index - 1) * 24)
			local rule = Kit:Solid(area.content, 'line')
			rule:SetHeight(1)
			rule:SetPoint('TOPLEFT', 0, -index * 24); rule:SetPoint('TOPRIGHT', 0, -index * 24)
		end
		area.content:SetHeight(#versions * 24)
		area:Refresh()
	end},
	{43, 'Separator', 1, function(body)
		Kit:Separator(body, 176):SetPoint('CENTER')
	end},
	{44, 'Bar graph', 1, function(body)
		local graph = Kit:BarGraph(body, {columns = 16, rows = 8})
		graph:SetPoint('CENTER')
		local values = {}
		for column = 1, 16 do values[column] = random() end
		tickers[#tickers + 1] = {0.12, function()
			for column = 1, 16 do values[column] = Kit:Clamp(values[column] + (random() - 0.5) * 0.45, 0.05, 1) end
			graph:SetValues(values)
		end}
	end},
	{45, 'Display', 2, function(body)
		Kit:Display(body, {unit = 'player', width = 380, height = 110, label = UnitName('player')}):SetPoint('CENTER')
	end},
	{50, 'Code block', 2, function(body)
		Kit:CodeBlock(body, {title = 'Lua', width = 380, lines = {
			'|cffc792ealocal|r Kit = JiberishSpec01UI.Kit',
			'|cff7f8c8d-- A fader that snaps to whole steps.|r',
			'|cffc792ealocal|r fader = Kit:Slider(parent, {',
			'  min = |cfff78c6c0|r, max = |cfff78c6c127|r, step = |cfff78c6c1|r,',
			'  onChange = |cffc792eafunction|r(value) Send(value) |cffc792eaend|r,',
			'})'}}):SetPoint('CENTER')
	end},
	{51, 'Item list', 2, function(body)
		Kit:ItemList(body, {width = 380, columns = {{'ID', 44}, {'Project', 110}, {'Branch', 100}, {'Status', 70}, {'Age', 40}},
			rows = {{'d41', 'web', 'main', 'Ready', '2m'}, {'d40', 'api', 'main', 'Ready', '18m'},
				{'d39', 'web', 'fix/nav', 'Error', '1h'}, {'d38', 'docs', 'main', 'Ready', '3h'}}}):SetPoint('CENTER')
	end},
	{52, 'D-pad', 1, function(body)
		Kit:DPad(body, {size = 100}):SetPoint('CENTER')
	end},
	{53, 'Mode dial', 2, function(body)
		Kit:ModeDial(body, {label = 'Effort', items = {'Low', 'Medium', 'High', 'XHigh', 'Max'}, value = 3}):SetPoint('CENTER', -100, 0)
		Kit:ModeDial(body, {label = 'Bank', items = {'1', '2', '3', '4', '5'}, value = 3}):SetPoint('CENTER', 100, 0)
	end},
	{54, 'Button group', 1, function(body)
		Kit:ButtonGroup(body, {keyWidth = 30, items = {{icon = 'minus'}, {icon = 'plus'}}}):SetPoint('CENTER', -50, 0)
		Kit:ButtonGroup(body, {keyWidth = 30, tone = 'dark', items = {{icon = 'chevron-left'}, {icon = 'play'}, {icon = 'chevron-right'}}}):SetPoint('CENTER', 36, 0)
	end},
	{55, 'Navbar', 2, function(body)
		Kit:Navbar(body, {items = {'Layout', 'Routing', 'Export'}, width = 300}):SetPoint('CENTER')
	end},
	{56, 'LCD', 2, function(body)
		local fps = Kit:LCD(body, {tag = 'FPS', ghost = '888', text = '0', width = 84})
		fps:SetPoint('TOPLEFT', 8, -4)
		local latency = Kit:LCD(body, {tag = 'Home ms', ghost = '8888', text = '0', size = 'sm', width = 70})
		latency:SetPoint('TOPLEFT', 104, -4)
		local zone = Kit:LCD(body, {tag = 'Status', text = 'Standing by', size = 'sm', width = 190})
		zone:SetPoint('TOPLEFT', 184, -4)
		local clock = Kit:LCD(body, {tag = 'Time', ghost = '88:88', text = '00:00', size = 'lg', width = 150})
		clock:SetPoint('BOTTOM', 0, 0)
		tickers[#tickers + 1] = {1, function()
			local _, _, home = GetNetStats()
			fps:SetText(tostring(floor(GetFramerate() + 0.5)))
			latency:SetText(tostring(home or 0))
			zone:SetText(InCombatLockdown() and 'In combat' or (GetMinimapZoneText() or 'Standing by'))
			clock:SetText(date('%H:%M'))
		end}
	end},
	{57, 'Slide switch', 2, function(body)
		Kit:SlideSwitch(body, {label = 'Output', items = {'Main', 'Cue', 'Both'}, vertical = true, value = 2}):SetPoint('CENTER', -130, 0)
		Kit:SlideSwitch(body, {label = 'Quality', items = {'Lo', 'Mid', 'Hi'}, value = 2, length = 90}):SetPoint('CENTER', 0, 0)
		Kit:SlideSwitch(body, {label = 'Input', items = {'Line', 'Mic', 'USB'}, vertical = true}):SetPoint('CENTER', 130, 0)
	end},
}
Kit.deckModules = modules

-- Cards: the reference's numbered module, "01 BUTTON" with a hairline rule.
local function CardShell(content, number, title, width, height)
	local card = Kit:Panel(content, {radius = 10, fill = 'panel', border = 'hair', shadow = 0.3})
	card:SetSize(width, height)
	card.number = Kit:Label(card, number and format('%02d', number) or '', 'accentInk', 8)
	card.number:SetPoint('TOPLEFT', 12, -11)
	card.title = Kit:Label(card, title, 'dim', 8)
	card.title:SetPoint('LEFT', card.number, 'RIGHT', number and 6 or 0, 0)
	card.rule = Kit:Solid(card, 'line')
	card.rule:SetHeight(1)
	card.rule:SetPoint('LEFT', card.title, 'RIGHT', 8, 0)
	card.rule:SetWidth(max(width - 50 - card.number:GetStringWidth() - card.title:GetStringWidth(), 1))
	card.body = CreateFrame('Frame', nil, card)
	card.body:SetPoint('TOPLEFT', 12, -28)
	card.body:SetPoint('BOTTOMRIGHT', -12, 12)
	return card
end
Kit.CardShell = CardShell

local function Card(content, module)
	local span = module[3]
	local card = CardShell(content, module[1], module[2], span * COLUMN + (span - 1) * GAP, module[5] or 170)
	-- A component that fails to build reports itself instead of breaking the page.
	local ok, problem = pcall(module[4], card.body)
	if not ok then
		local message = Kit:Text(card.body, tostring(problem), 9, 'red')
		message:SetPoint('TOPLEFT'); message:SetPoint('BOTTOMRIGHT')
		message:SetJustifyH('LEFT')
		card.failed = problem
	end
	return card
end

-- Lay cards into a grid of COLUMN-wide columns; returns the content height.
function Kit:FlowCards(content, cards, columns)
	local column, y, rowHeight = 0, 0, 0
	for _, card in ipairs(cards) do
		local span = card.span or 1
		if column + span > columns then
			y, column, rowHeight = y + rowHeight + GAP, 0, 0
		end
		card:ClearAllPoints()
		card:SetPoint('TOPLEFT', content, 'TOPLEFT', PAD / 2 + column * (COLUMN + GAP), -(8 + y))
		column, rowHeight = column + span, max(rowHeight, card:GetHeight())
	end
	return 8 + y + rowHeight + 24
end

-- The component gallery: every SPEC-01 element, live. Shown on the hub's Components page.
function Kit:BuildGallery(content)
	local cards = {}
	for _, module in ipairs(modules) do
		local card = Card(content, module)
		card.span = module[3]
		cards[#cards + 1] = card
	end
	return self:FlowCards(content, cards, 4)
end

-- Live demos (meters, LCD clock) only tick while their page is visible.
function Kit:StartGalleryTickers(owner)
	self:StopGalleryTickers(owner)
	owner.running = {}
	for index, ticker in ipairs(tickers) do
		owner.running[index] = C_Timer.NewTicker(ticker[1], function()
			if not pcall(ticker[2]) then owner.running[index]:Cancel() end
		end)
		pcall(ticker[2])
	end
end

function Kit:StopGalleryTickers(owner)
	for _, ticker in pairs(owner.running or {}) do ticker:Cancel() end
	owner.running = nil
end

Kit.COLUMN, Kit.GAP, Kit.PAD = COLUMN, GAP, PAD

-- The deck now opens the hub at its Components page.
function Kit:ToggleDeck(show)
	if UI.ToggleHub then UI:ToggleHub('components', show) end
end
function Kit:UpdateDeck() if UI.UpdateHub then UI:UpdateHub() end end
