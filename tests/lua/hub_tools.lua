-- Offline test of the hub's pure parts, run by tests/test_hub_tools.py through
-- tools/lua/minilua.py: Core.lua's slash command table and dispatcher, and
-- Modules/HubHistory.lua (Undo history, the reload list, page resets, NEW marks).
-- usage: minilua.py tests/lua/hub_tools.lua JiberishSpec01UI/Core.lua JiberishSpec01UI/Modules/HubHistory.lua
local corePath, historyPath = ...
local failures = 0
local function check(label, got, want)
	if got ~= want then
		failures = failures + 1
		print('FAIL '..label..': got '..tostring(got)..', want '..tostring(want))
	end
end

-- Just enough of the game for Core.lua's main chunk.
local function Frame()
	local frame = {}
	return setmetatable(frame, {__index = function() return function() end end})
end
CreateFrame = function() return Frame() end
UIParent = Frame()
hooksecurefunc = function() end
InCombatLockdown = function() return false end
SlashCmdList = {}
DEFAULT_CHAT_FRAME = {AddMessage = function(_, text) printed[#printed + 1] = text end}
printed = {}
strlower, strupper = string.lower, string.upper
strtrim = function(text) return (tostring(text):gsub('^%s+', ''):gsub('%s+$', '')) end
strjoin = function(sep, ...) return table.concat({...}, sep) end
tostringall = function(...)
	local out = {}
	for index = 1, select('#', ...) do out[index] = tostring((select(index, ...))) end
	return unpack(out)
end
wipe = function(t) for key in pairs(t) do t[key] = nil end return t end

local UI = {}
assert(loadfile(corePath))('JiberishSpec01UI', UI)

-- Slash commands --------------------------------------------------------------------
local calls = {}
local function Log(name) return function(_, ...) calls[#calls + 1] = {name, ...} end end
local function Last() return calls[#calls] or {} end
local pages = {fonts = true, calendar = true, commands = true, whatsnew = true, quick = true, components = true}
UI.ToggleHub = Log('ToggleHub')
UI.SearchHub = Log('SearchHub')
UI.GetPage = function(_, key) return pages[key] end
UI.ToggleMovers = Log('ToggleMovers')
UI.OpenSetup = Log('OpenSetup')
UI.Kit = {SoundReport = Log('SoundReport'), Toast = Log('Toast')}

check('slash handler installed', type(SlashCmdList.JIBERISHSPEC), 'function')
check('/spec is the first slash', SLASH_JIBERISHSPEC1, '/spec')

check('bare /spec opens the hub', UI:RunCommand(''), 'hub')
check('bare /spec toggles', Last()[1], 'ToggleHub')
check('bare /spec has no page', Last()[2], nil)

check('help is a command', UI:RunCommand('help'), 'command')
check('help opens Commands', Last()[2], 'commands')
check('help forces the hub open', Last()[3], true)
check('help is case blind', UI:RunCommand('  HELP  '), 'command')
check('? is help', (UI:RunCommand('?') and Last()[2]), 'commands')
check('whatsnew opens its page', (UI:RunCommand('whatsnew') and Last()[2]), 'whatsnew')

check('a page name opens it', UI:RunCommand('fonts'), 'page')
check('the page', Last()[2], 'fonts')
check('another word searches', UI:RunCommand('key color'), 'search')
check('the search keeps the whole line', Last()[2], 'key color')
check('an unknown single word searches', UI:RunCommand('Nameplate'), 'search')
check('the search keeps its case', Last()[2], 'Nameplate')

-- A command whose module is missing falls through to its page.
check('calendar without its module opens the page', UI:RunCommand('calendar'), 'page')
UI.OpenCalendar = Log('OpenCalendar')
check('calendar with its module runs it', UI:RunCommand('calendar'), 'command')
check('calendar ran', Last()[1], 'OpenCalendar')

-- Edit mode: UI:EditMode when it exists, else unlock mode.
UI:RunCommand('edit')
check('edit falls back to unlocking', Last()[1], 'ToggleMovers')
check('edit unlocks', Last()[2], false)
UI.EditMode = Log('EditMode')
UI:RunCommand('edit')
check('edit uses EditMode', Last()[1], 'EditMode')
UI:RunCommand('unlock')
check('unlock unlocks', Last()[2], false)
UI:RunCommand('lock')
check('lock locks', Last()[2], true)
local before = #calls
UI:RunCommand('move')
check('move toggles', #calls, before + 1)
check('move passes nothing', Last()[2], nil)
UI:RunCommand('toast hello there')
check('toast passes the rest', Last()[2] and Last()[2].title, 'hello there')

-- The help lists every entry; no word is taken twice; every entry explains itself.
local words, lines = {}, UI:CommandLines()
check('help has a line per command', #lines, #UI.commands)
for index, command in ipairs(UI.commands) do
	check('command '..index..' has text', type(command.text), 'string')
	check('command '..index..' has usage', type(command.usage), 'string')
	for _, word in ipairs(command.word and {command.word, unpack(command.aliases or {})} or {}) do
		check('word '..word..' used once', words[word], nil)
		words[word] = true
		check('word '..word..' found', UI:Command(word), command)
	end
end
for _, word in ipairs({'help', 'whatsnew', 'edit', 'setup', 'move', 'unlock', 'lock', 'reset', 'console', 'drawer', 'timer',
	'volume', 'cpu', 'calendar', 'map', 'afk', 'deck', 'sound', 'toast'}) do
	check('/spec '..word..' is listed', words[word], true)
end
UI:PrintCommands()
check('print writes every line', #printed, #UI.commands)

-- History --------------------------------------------------------------------------
assert(loadfile(historyPath))('JiberishSpec01UI', UI)
local H = UI.HubHistory
check('history exposed', type(H), 'table')

-- Paths
local db = {sound = {enable = true}, font = 'a', fade = {style = 'smooth'}}
check('read', H.Read(db, 'sound.enable'), true)
check('read missing', H.Read(db, 'nope.deeper'), nil)
check('write', H.Write(db, 'sound.enable', false), true)
check('written', db.sound.enable, false)
check('write skips a missing parent', H.Write(db, 'nope.deeper', 1), false)
local color = {r = 1, g = 0, b = 0}
H.Write(db, 'tint', color)
color.r = 0
check('writes copies of tables', db.tint.r, 1)

-- Private paths
check('ui scale is private', H.IsPrivate('uiScale'), true)
check('hub state is private', H.IsPrivate('hub.page'), true)
check('chat log is private', H.IsPrivate('chat.log'), true)
check('chat settings are not', H.IsPrivate('chat.logSize'), false)
check('account keys are private', H.IsPrivate('__account.x'), true)
check('a normal path is not', H.IsPrivate('appearance.fade.style'), false)

-- Undo: a drag is one step, a change back is none, a batch is one.
H.Clear()
check('push', H.Push({key = 'font', path = 'font', label = 'Typeface', old = 'a', new = 'b'}, 10) ~= nil, true)
H.Push({key = 'font', path = 'font', label = 'Typeface', old = 'b', new = 'c'}, 10.5)
check('a quick run of one setting is one step', H.Count(), 1)
check('it keeps the first old value', H.Peek().old, 'a')
check('and the last new one', H.Peek().new, 'c')
H.Push({key = 'font', path = 'font', old = 'c', new = 'a'}, 11)
check('ending where it started leaves nothing', H.Count(), 0)
H.Push({key = 'font', path = 'font', old = 'a', new = 'b'}, 20)
H.Push({key = 'font', path = 'font', old = 'b', new = 'c'}, 25)
check('changes far apart are two steps', H.Count(), 2)
H.Push({key = 'x', path = 'x', old = 1, new = 1}, 26)
check('a non-change is not recorded', H.Count(), 2)
local entry = H.Pop()
check('pop gives the newest', entry.new, 'c')
check('pop gives its old value', entry.old, 'b')
H.Clear()
for index = 1, H.LIMIT + 5 do H.Push({key = 'k'..index, path = 'k'..index, old = 0, new = index}, index * 10) end
check('history is capped', H.Count(), H.LIMIT)
check('the oldest go first', H.Changes(H.Peek())[1].new, H.LIMIT + 5)
H.Clear()
H.Push({label = 'Fonts reset', changes = {{path = 'a', old = 1, new = 2}, {path = 'b', old = 3, new = 4}}}, 1)
H.Push({key = 'c', path = 'c', old = 5, new = 6}, 1.1)
check('a batch does not merge', H.Count(), 2)
H.Pop()
local batch = H.Changes(H.Pop())
check('a batch unwinds newest first', batch[1].path, 'b')
check('a batch has every change', #batch, 2)

-- Reload list
H.ClearReload()
H.FlagReload('style.chat', 'Chat style', 'display')
check('a flagged setting waits', H.ReloadCount(), 1)
H.FlagReload('style.chat', 'Chat style', 'blizzard')
check('flagging again keeps one', H.ReloadCount(), 1)
check('a different value still waits', H.SettleReload('style.chat', 'blizzard'), false)
check('back where it started settles', H.SettleReload('style.chat', 'display'), true)
check('and the lamp goes out', H.ReloadCount(), 0)
H.FlagReload(nil, 'Layout page')
H.FlagReload(nil, 'Layout page')
H.FlagReload('actionbars.rows', 'Rows', 3)
check('untracked reasons are listed once', H.ReloadCount(), 2)
check('untracked reasons never settle', H.SettleReload(nil, 3), false)
local labels = H.ReloadLabels()
check('labels in order', labels[1], 'Layout page')
check('labels in order 2', labels[2], 'Rows')
H.ClearReload()
check('cleared', H.ReloadCount(), 0)

-- Page reset
local defaults = {font = '__default', sound = {enable = true, channel = 'Master'}, uiScale = false,
	colors = {lamp = {r = 1, g = 0.7, b = 0.3}}}
local live = {font = 'Audiowide', sound = {enable = true, channel = 'SFX'}, uiScale = 0.64,
	colors = {lamp = {r = 0, g = 1, b = 0}}}
local page = {cards = {
	{rows = {{'dropdown', 'Typeface', 'font'}, {'switch', 'Sounds', 'sound.enable'}, {'note', 'text'},
		{'segmented', 'Channel', 'sound.channel'}, {'segmented', 'UI scale', 'uiScale'}}},
	{rows = {{'dropdown', 'Typeface again', 'font'}, {'color', 'Lamps', 'colors.lamp'}, {'button', 'Go', 'Go', function() end},
		{'slider', 'No default', 'missing.value', 0, 1, 0.1}}},
}}
local plan = H.ResetPlan(page, defaults, live)
check('reset plans only changed settings', #plan, 3)
check('reset plan 1', plan[1].path, 'font')
check('reset plan 1 goes to the default', plan[1].new, '__default')
check('reset plan 1 remembers the value', plan[1].old, 'Audiowide')
check('reset plan 2', plan[2].path, 'sound.channel')
check('reset plan 3 copies the color', plan[3].new ~= defaults.colors.lamp and plan[3].new.g, 0.7)
check('reset plan rows ride along', plan[1].row[2], 'Typeface')

-- NEW marks per version
local seen = {theme = true}
check('an old true is not this version', H.Seen(seen, 'theme', '0.6.0'), false)
check('mark is fresh', H.MarkSeen(seen, 'theme', '0.6.0'), true)
check('seen now', H.Seen(seen, 'theme', '0.6.0'), true)
check('mark again is not fresh', H.MarkSeen(seen, 'theme', '0.6.0'), false)
check('a new version lights it again', H.Seen(seen, 'theme', '0.7.0'), false)
check('no version, no marks', H.MarkSeen(seen, 'x', nil), false)

if failures == 0 then print('ok') else print(failures..' failures') end
