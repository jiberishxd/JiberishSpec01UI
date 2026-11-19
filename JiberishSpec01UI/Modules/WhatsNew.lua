-- Two help pages for the hub: What's new (a card per highlight of each release,
-- each with a key to the page it is on) and Commands (every /spec command, read
-- from Core.lua's command table, so the list can't drift from what runs).
--
-- A release adds one entry at the top of RELEASES; nothing else changes. The
-- sidebar lights a lamp on What's new until it is opened in the version the
-- player is running (the hub's seen table), and the first login on a new
-- version says so once in a toast.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame = CreateFrame
local floor, max = math.floor, math.max

-- Releases, newest first. Each highlight: area (the card's printed title), title,
-- text (one line or two), page (the hub page Open goes to) or command (a /spec word).
local RELEASES = {
	{version = '0.6.1', date = '2026-11-18',
		summary = 'Movement keys work with the hub and editors open, the stance and pet keys slide along the console, and unit frames get portrait and text placement.',
		entries = {
			{area = 'Unit frames', title = 'Portrait size and side', page = 'unitframes',
				text = 'Each frame\'s portrait can be its own size, on the left or the right.'},
			{area = 'Unit frames', title = 'Place the name and digits', page = 'unitframes',
				text = 'Nudge the name and the digits anywhere on the frame, and set the digits left, centre or right in the LCD.'},
			{area = 'Console', title = 'Taller or shorter bays', command = 'console',
				text = 'Select a docked frame in the console editor and use HEIGHT - and HEIGHT +; the frame follows its bay.'},
			{area = 'Console', title = 'Stance and pet keys along the edge', command = 'console',
				text = 'Drag them anywhere along the console\'s top edge, or into the console where there is room.'},
		}},
	{version = '0.6.0', date = '2026-11-18',
		summary = 'Two layouts and a console you can edit block by block, a compass and map, new quest tracker, chat and away screen, and an easier settings hub.',
		entries = {
			{area = 'Settings', title = 'Quick setup, Undo and one reload lamp', page = 'quick',
				text = 'The eight choices that matter most on one page. Ctrl+Z undoes a change, Reset page puts a page back, one lamp lists what needs a reload.'},
			{area = 'Layouts', title = 'Jiberish main or Integrated console', page = 'layout',
				text = 'Two layouts, placed to fit your screen. Integrated docks the player, target, focus and pet inside the console.'},
			{area = 'Console', title = 'Edit the console block by block', command = 'console',
				text = 'Drag key banks, function keys, bays and the stance and pet bars on a pixel grid. They snap, and never overlap.'},
			{area = 'Console', title = 'Recessed bays and round function keys', page = 'actionbars',
				text = 'Docked unit frames sit in bays cut into the console; the micro bar moves into its header.'},
			{area = 'Navigation', title = 'NV-3 compass tape and NV-4 map', page = 'navigation',
				text = 'A heading tape with quests and services at their bearing, and a click-through local map (/spec map).'},
			{area = 'Navigation', title = 'Cities and town services', page = 'navigation',
				text = 'City maps never go blank, and repair, mail, inn and trainers are learned as you use them.'},
			{area = 'Quest tracker', title = 'OT-1 instrument panel', page = 'objectives',
				text = 'Quests on plates with status lamps, LCD counts, dot progress bars, and motion and sounds as they change.'},
			{area = 'Chat', title = 'CH-1 communications device', page = 'chat',
				text = 'A printed header with an unread LCD, tabs on a track, black glass, and a text field with a channel badge.'},
			{area = 'Away screen', title = 'AW-1 standby console', page = 'away',
				text = 'Your character over the dimmed world, a log of what happened while away and a mixer. Preview with /spec afk.'},
			{area = 'Unit frames', title = 'Class key color for every unit', page = 'unitframes',
				text = 'With the key color on Class, each unit shows its own class, creatures their reaction; lamps stay whole at any scale.'},
			{area = 'Nameplates', title = 'Compact strips, full plate on target', page = 'nameplates',
				text = 'Slim plates that open into a tight full plate on your target, with enemy levels in difficulty colors.'},
			{area = 'Fade', title = 'Out-of-combat fade in hardware styles', page = 'fade',
				text = 'Parts rest faded until a fight, a target or the mouse wakes them: CRT power down, relay, iris, roll-top and more.'},
			{area = 'Fonts and profile', title = 'Audiowide, and Jiberish\'s profile', page = 'fonts',
				text = 'Audiowide ships with the addon; new installs start from Jiberish\'s own setup at UI scale 0.64.'},
			{area = 'Windows', title = 'Character window and Blizzard windows', page = 'windows',
				text = 'A full SPEC-01 pass on both clients: keys for slots and tabs, black screens for lists, ornate art hidden.'},
			{area = 'Minimap', title = 'Working keys and an LCD strip', page = 'minimap',
				text = 'The header keys take clicks again; zone, coordinates and clock sit on one LCD strip.'},
			{area = 'Commands', title = 'Every /spec command, listed', page = 'commands',
				text = '/spec help lists them all; /spec followed by any other word searches the settings.'},
		}},
}
UI.releases = RELEASES

local CARD_H = 132

-- Open: a page in the hub, or a /spec command.
local function Opener(entry)
	if entry.command then
		return function() UI:ToggleHub(nil, false); UI:RunCommand(entry.command) end, UI:Command(entry.command) ~= nil
	end
	return function() UI:ToggleHub(entry.page, true) end, entry.page ~= nil and UI:GetPage(entry.page) ~= nil
end

local function HighlightCard(content, index, entry, current)
	local card = Kit.CardShell(content, index, strupper(entry.area or ''), Kit.COLUMN, CARD_H)
	local width = Kit.COLUMN - 24
	card.lamp = Kit:Led(card.body, 6, current)
	card.lamp:SetPoint('TOPLEFT', 1, -3)
	card.heading = Kit:Text(card.body, entry.title or '', 10, 'ink', true)
	card.heading:SetPoint('TOPLEFT', 12, 0)
	card.heading:SetWidth(width - 12)
	card.heading:SetJustifyH('LEFT')
	card.heading:SetWordWrap(true)
	if card.heading.SetMaxLines then card.heading:SetMaxLines(2) end
	card.text = Kit:Text(card.body, entry.text or '', 9, 'dim')
	card.text:SetPoint('TOPLEFT', card.heading, 'BOTTOMLEFT', -12, -5)
	card.text:SetWidth(width)
	card.text:SetJustifyH('LEFT')
	card.text:SetWordWrap(true)
	if card.text.SetMaxLines then card.text:SetMaxLines(3) end
	local open, available = Opener(entry)
	card.open = Kit:Key(card.body, {text = 'Open', icon = 'chevron-right', iconSize = 8, width = 70, height = 22, textSize = 8})
	card.open:SetPoint('BOTTOMRIGHT', 0, 0)
	card.open:SetKeyEnabled(available)
	card.open.onClick = open
	card.where = Kit:Label(card.body, entry.command and ('/spec '..entry.command) or '', 'dim', 7)
	card.where:SetPoint('BOTTOMLEFT', 0, 6)
	return card
end

local function ReleaseHeader(content, release, y, width, current)
	local lcd = Kit:LCDPanel(content, {radius = 3})
	lcd:SetSize(64, 20)
	lcd:SetPoint('TOPLEFT', Kit.PAD / 2 + 2, -y)
	local version = Kit:Text(lcd, release.version, 9, 'lcdInk', true)
	version:SetPoint('CENTER')
	Kit:Font(version, 9, nil, true, 'numbers')
	local lamp = Kit:Led(content, 6, current)
	lamp:SetPoint('LEFT', lcd, 'RIGHT', 10, 0)
	local stamp = Kit:Label(content, (current and 'This version' or 'Earlier')..'  /  '..(release.date or ''), 'dim', 8, true)
	stamp:SetPoint('LEFT', lamp, 'RIGHT', 6, 0)
	local rule = Kit:Solid(content, 'line')
	rule:SetHeight(1)
	rule:SetPoint('LEFT', stamp, 'RIGHT', 10, 0)
	rule:SetPoint('RIGHT', content, 'TOPLEFT', Kit.PAD / 2 + width, -y - 10)
	local summary = Kit:Text(content, release.summary or '', 9, 'ink')
	summary:SetPoint('TOPLEFT', lcd, 'BOTTOMLEFT', 0, -8)
	summary:SetWidth(width - 4)
	summary:SetJustifyH('LEFT')
	return 20 + 8 + max(summary:GetStringHeight(), 12) + 12
end

local function BuildWhatsNew(content, page)
	page.controls, page.cardFrames = {}, {}
	local width = 4 * Kit.COLUMN + 3 * Kit.GAP
	local y = 10
	for _, release in ipairs(RELEASES) do
		local current = release.version == UI.version
		y = y + ReleaseHeader(content, release, y, width, current)
		for index, entry in ipairs(release.entries or {}) do
			local card = HighlightCard(content, index, entry, current)
			local column, row = (index - 1) % 4, floor((index - 1) / 4)
			card:SetPoint('TOPLEFT', Kit.PAD / 2 + column * (Kit.COLUMN + Kit.GAP), -(y + row * (CARD_H + Kit.GAP)))
			page.cardFrames[#page.cardFrames + 1] = card
		end
		local rows = math.ceil(#(release.entries or {}) / 4)
		y = y + rows * (CARD_H + Kit.GAP) + 16
	end
	return y + 10
end

-- Search finds the highlights too.
local whatsNewSearch = {}
for _, release in ipairs(RELEASES) do
	for _, entry in ipairs(release.entries or {}) do
		whatsNewSearch[#whatsNewSearch + 1] = {entry.title, release.version..': '..(entry.text or '')}
	end
end

UI:RegisterPage('whatsnew', {title = 'What\'s new', order = 0.6, span = 4, code = 'WN',
	since = RELEASES[1] and RELEASES[1].version, build = BuildWhatsNew, search = whatsNewSearch})

-- Commands ------------------------------------------------------------------------
local ROW_H = 26

local function BuildCommands(content, page)
	page.controls = {}
	local width = 4 * Kit.COLUMN + 3 * Kit.GAP
	local lines = UI:CommandLines()
	local intro = 'Type these in chat. /spec01 and /jspec work the same as /spec. A dim lamp means that part of the addon did not load.'
	local height = 28 + 40 + #lines * ROW_H + 12
	local card = Kit.CardShell(content, 1, 'Slash commands', width, height)
	card:SetPoint('TOPLEFT', Kit.PAD / 2, -8)
	local note = Kit:Text(card.body, intro, 9, 'dim')
	note:SetPoint('TOPLEFT', 0, -2)
	note:SetWidth(width - 160)
	note:SetJustifyH('LEFT')
	local printKey = Kit:Key(card.body, {text = 'Print to chat', width = 112, height = 24, textSize = 8})
	printKey:SetPoint('TOPRIGHT', 0, 0)
	printKey.onClick = function() UI:PrintCommands() end
	page.lamps = {}
	for index, command in ipairs(UI.commands) do
		local y = -40 - (index - 1) * ROW_H
		if index > 1 then
			local rule = Kit:Solid(card.body, 'line')
			rule:SetHeight(1)
			rule:SetPoint('TOPLEFT', 0, y + 3)
			rule:SetPoint('TOPRIGHT', 0, y + 3)
			rule:SetAlpha(0.5)
		end
		local lamp = Kit:Led(card.body, 5, false)
		lamp:SetPoint('TOPLEFT', 2, y - 7)
		local usage = Kit:Text(card.body, lines[index].usage, 10, 'ink', true)
		usage:SetPoint('TOPLEFT', 14, y - 3)
		usage:SetWidth(280)
		usage:SetJustifyH('LEFT')
		usage:SetWordWrap(false)
		local text = Kit:Text(card.body, command.text or '', 9, 'dim')
		text:SetPoint('TOPLEFT', 300, y - 4)
		text:SetPoint('RIGHT', card.body, 'RIGHT', -80, 0)
		text:SetJustifyH('LEFT')
		text:SetWordWrap(false)
		if command.word then
			local run = Kit:Key(card.body, {text = 'Run', width = 64, height = 20, textSize = 7})
			run:SetPoint('TOPRIGHT', 0, y)
			run.onClick = function()
				if command.word ~= 'help' then UI:ToggleHub(nil, false) end
				UI:RunCommand(command.word)
			end
			page.lamps[#page.lamps + 1] = {lamp = lamp, key = run, command = command}
		else
			Kit:SetLed(lamp, true)
		end
	end
	page.refresh = function()
		for _, entry in ipairs(page.lamps) do
			local on = UI:CommandAvailable(entry.command)
			Kit:SetLed(entry.lamp, on, on and 'green' or nil)
			entry.key:SetKeyEnabled(on)
		end
	end
	page.refresh()
	page.cardFrames = {card}
	return height + 30
end

local commandSearch = {}
for _, command in ipairs(UI.commands or {}) do
	commandSearch[#commandSearch + 1] = {command.usage, command.text}
end

UI:RegisterPage('commands', {title = 'Commands', order = 98, span = 4, code = 'SC', since = '0.6.0',
	build = BuildCommands, search = commandSearch})

-- A new version says so once, a little after the first login on it.
local notice = CreateFrame('Frame')
notice:RegisterEvent('PLAYER_ENTERING_WORLD')
notice:SetScript('OnEvent', function(self)
	self:UnregisterAllEvents()
	local release = RELEASES[1]
	if not release or release.version ~= UI.version or UI.freshInstall then return end
	local hub = UI.db.hub
	if hub.told == release.version or (type(hub.seen) == 'table' and hub.seen.whatsnew == release.version) then return end
	C_Timer.After(8, function()
		UI:AfterCombat(function()
			hub.told = release.version
			if UI.db.toasts and UI.db.toasts.enable == false then return end
			Kit:Toast({title = 'SPEC-01 UI '..release.version, text = 'Updated. See what changed, or type /spec help for every command.',
				duration = 10, action = {text = 'See', onClick = function() UI:ToggleHub('whatsnew', true) end}})
		end, 'whatsnew.notice')
	end)
end)
