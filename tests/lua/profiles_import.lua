-- Offline test of the profile import preview (Modules/ProfilesImport.lua) and
-- the profile strings (Modules/Profiles.lua), run by tests/test_profiles_import.py
-- through tools/lua/minilua.py: the real hub (for its pages and row labels), the
-- Theme / Colors / Housing / Fonts pages, the shipped default profile string and
-- a modified copy of it.
-- usage: minilua.py tests/lua/profiles_import.lua <addon folder>
local root = ...
local failures = 0
local function check(label, got, want)
	if got ~= want then
		failures = failures + 1
		print('FAIL '..label..': got '..tostring(got)..', want '..tostring(want))
	end
end
local function ok(label, value) check(label, value and true or false, true) end

-- A client with nothing on screen: every frame and kit call is a no-op.
local function Any()
	local t = {}
	return setmetatable(t, {__index = function(self) return function() return self end end})
end
function CreateFrame() return Any() end
UIParent = Any()
UISpecialFrames = {}
DEFAULT_CHAT_FRAME = {AddMessage = function() end}
function InCombatLockdown() return false end
function GetTime() return 100 end
C_Timer = {After = function() end}
C_AddOns = {GetAddOnMetadata = function() return '0.6.0' end}
function geterrorhandler() return function(e) print('ERROR', e) end end
function hooksecurefunc(owner, name, hook)
	local original = owner[name]
	owner[name] = function(...)
		local results = {original(...)}
		hook(...)
		return unpack(results)
	end
end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function strtrim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end
function strjoin(sep, ...) return table.concat({...}, sep) end
function tostringall(...) local out = {} for i = 1, select('#', ...) do out[i] = tostring(select(i, ...)) end return unpack(out) end
strupper, strlower, strsub, strfind, strmatch, strbyte, strchar = string.upper, string.lower, string.sub, string.find, string.match, string.byte, string.char
format, gsub, gmatch, tinsert = string.format, string.gsub, string.gmatch, table.insert
function UnitName() return 'Tester' end
function GetRealmName() return 'Offline' end
function date() return '2026-11-18 12:00' end
function ReloadUI() end
NUM_CHAT_WINDOWS = 10
SlashCmdList = {}

local UI = {}
local function Load(file)
	local chunk = assert(loadfile(root..'/'..file))
	chunk('JiberishSpec01UI', UI)
end
Load('Core.lua')
Load('Kit/Util.lua')
UI.Kit = Any()
UI.Kit.Util = UI.Util
UI.Pixel = Any()
for _, file in ipairs({'Modules/Hub.lua', 'Modules/Appearance.lua', 'Modules/Motion.lua', 'Modules/DefaultProfile.lua',
	'Modules/Profiles.lua', 'Modules/ProfilesImport.lua'}) do
	Load(file)
end

local P, S = UI.ProfileImport, UI.ProfileStore
ok('preview helpers exposed', P and S)

-- The saved variables as a new install has them: the shipped default profile.
JiberishSpec01DB = {}
for key, value in pairs(UI.defaults) do JiberishSpec01DB[key] = S.Copy(value, 1) end
UI.db = JiberishSpec01DB
local shipped, shippedName, shippedInfo = UI:DecodeProfile(UI.DEFAULT_PROFILE)
ok('the default profile string reads', type(shipped) == 'table')
check('it reads as format 1', shippedInfo and shippedInfo.version, 1)
ok('it holds frame positions', shippedInfo and shippedInfo.positions)
S.LoadInto(UI.db, shipped)

-- Nothing changes when the string is what is in use already.
local same = P.Preview(shipped, shippedName, shippedInfo)
check('the same profile changes nothing', #same.modes.all.changes, 0)

-- A round trip through a string keeps every setting.
local text = UI:EncodeProfile(UI.db, 'Round trip')
local back, backName = UI:DecodeProfile(text)
check('round trip name', backName, 'Round trip')
check('round trip changes nothing', #P.Preview(back, backName).modes.all.changes, 0)

-- A modified copy: two theme settings, a color override, two unit frame
-- settings, the layout preset, a style and three frame positions.
local copy = S.Copy(UI.db)
copy.finish = copy.finish == 'graphite' and 'paper' or 'graphite'
copy.accent = copy.accent == 'green' and 'blue' or 'green'
copy.colors.lampOn = not copy.colors.lampOn
copy.colors.lamp = {r = 0, g = 1, b = 0}
copy.unitframes.scale = (copy.unitframes.scale or 1) + 0.25
copy.unitframes.digits = not copy.unitframes.digits
copy.layout = copy.layout or {}
copy.layout.preset = 'test-preset'
copy.style.chat = copy.style.chat == 'blizzard' and 'display' or 'blizzard'
local moved, frames = 0, {}
for key in pairs(copy.movers) do
	if moved < 3 then
		moved = moved + 1
		frames[#frames + 1] = key
		copy.movers[key] = {(copy.movers[key][1] or 0) + 40, (copy.movers[key][2] or 0) - 40, anchor = copy.movers[key].anchor}
	end
end
copy.movers['test.new'] = {10, 20, anchor = 'CENTER'}
-- Private paths never travel: a different UI scale in the copy is not imported.
copy.uiScale = 0.5
local modified = UI:EncodeProfile(copy, 'Modified')
local data, name, info = UI:DecodeProfile(modified)
ok('the modified string reads', type(data) == 'table')
check('the modified name', name, 'Modified')
local preview = P.Preview(data, name, info)
local all = preview.modes.all

local function Group(plan, title)
	for _, group in ipairs(plan.groups) do
		if group.title == title then return group end
	end
end
local function Change(plan, path)
	for _, entry in ipairs(plan.changes) do
		if entry.path == path then return entry end
	end
end

local theme = Group(all, 'Theme')
ok('a Theme group', theme)
local finish = Change(all, 'finish')
ok('finish changes', finish)
check('finish is labelled as on the Theme page', finish and finish.label, 'Finish')
check('finish shows the option name', finish and finish.newText, copy.finish == 'graphite' and 'Graphite' or 'Paper')
check('finish is grouped under Theme', finish and finish.group, 'Theme')
local accent = Change(all, 'accent')
check('accent label', accent and accent.label, 'Accent')
check('accent new value in words', accent and accent.newText, copy.accent == 'green' and 'Green' or 'Blue')
check('theme summary lists both changes', theme and theme.summary,
	'Finish '..finish.oldText..' -> '..finish.newText..', Accent '..accent.oldText..' -> '..accent.newText)
local lamp = Change(all, 'colors.lamp')
ok('a color changes as one setting', lamp)
check('a color reads as hex', lamp and lamp.newText, '#00FF00')
check('colors are grouped under Colors', lamp and lamp.group, 'Colors')
check('colors.lampOn is labelled by its row', Change(all, 'colors.lampOn') and Change(all, 'colors.lampOn').label, 'Lamps')
local positions = Group(all, 'Frame positions')
ok('a Frame positions group', positions)
check('frame positions count every moved frame', positions and #positions.changes, moved + 1)
check('frame positions summary', positions and positions.summary, (moved + 1)..' frames')
check('frame positions come last', all.groups[#all.groups].title, 'Frame positions')
check('the new frame from its default spot', Change(all, 'movers.test.new') and Change(all, 'movers.test.new').oldText, 'default spot')
local style = Change(all, 'style.chat')
ok('a style change', style)
check('styles group', style and style.group, 'Interface styles')
check('a style change needs a reload', style and style.reload, true)
check('styles come first', all.groups[1].title, 'Interface styles')
ok('the unit frame scale changes', Change(all, 'unitframes.scale'))
ok('the layout preset changes', Change(all, 'layout.preset'))
check('no private path in the changes', Change(all, 'uiScale'), nil)
check('nothing from the hub window', Change(all, 'hub.page'), nil)
check('counts: frames', all.counts.frames, moved + 1)
check('counts: settings', all.counts.settings, 8)
check('counts: reload', all.counts.reload >= 1, true)
print('summary: '..P.SummaryLine(all.groups))

-- Without frame positions: the same, minus the frames.
local noPositions = preview.modes.positions
check('no positions: no Frame positions group', Group(noPositions, 'Frame positions'), nil)
check('no positions: the settings still change', noPositions.counts.settings, all.counts.settings)
-- Appearance only: theme, colors, housing, fonts and nothing else.
local look = preview.modes.appearance
check('appearance: finish', Change(look, 'finish') ~= nil, true)
check('appearance: colors', Change(look, 'colors.lamp') ~= nil, true)
check('appearance: no unit frames', Change(look, 'unitframes.scale'), nil)
check('appearance: no layout', Change(look, 'layout.preset'), nil)
check('appearance: no style', Change(look, 'style.chat'), nil)
check('appearance: no positions', look.counts.frames, 0)
check('appearance count', look.counts.settings, 4)

-- A string exported without positions keeps the player's own.
local bare = UI:EncodeProfile(copy, 'Bare', {positions = false})
local bareData, _, bareInfo = UI:DecodeProfile(bare)
check('a string without positions says so', bareInfo.positions, false)
check('importing it moves no frame', P.Preview(bareData, 'Bare', bareInfo).modes.all.counts.frames, 0)

-- Apply, the safety net, and Undo.
local before = S.Copy(UI.db)
ok('apply all', UI:ApplyImport(preview, 'all'))
check('finish applied', UI.db.finish, copy.finish)
check('private uiScale kept', UI.db.uiScale, before.uiScale)
check('frames moved', UI.db.movers['test.new'] and UI.db.movers['test.new'][1], 10)
local store = UI.db.__profiles
local snapshot = UI:LastImport()
check('the snapshot name', snapshot, 'Before import 2026-11-18 12:00')
ok('the snapshot is a profile', store.profiles[snapshot])
check('the snapshot holds the old finish', store.profiles[snapshot].finish, before.finish)
ok('undo', UI:UndoImport())
check('undo puts the finish back', UI.db.finish, before.finish)
check('undo puts the frames back', UI.db.movers['test.new'], nil)
check('undo is spent', UI:LastImport(), nil)
check('the snapshot profile stays', store.profiles[snapshot] ~= nil, true)
check('after undo nothing differs from before', #P.Diff(P.BuildIndex(), before, S.Copy(UI.db)), 0)
-- Appearance only leaves the rest alone.
UI:ApplyImport(P.Preview(data, name, info), 'appearance')
check('appearance applied', UI.db.finish, copy.finish)
check('appearance leaves unit frames', UI.db.unitframes.scale, before.unitframes.scale)
check('appearance leaves frames', UI.db.movers['test.new'], nil)
UI:UndoImport()

-- Problems, in plain words; nothing is read from a damaged string.
local function Problem(input)
	local result, why = UI:DecodeProfile(input)
	check('no data from '..tostring(input):sub(1, 24), result, nil)
	return why or ''
end
local function Has(label, text, part) ok(label..' ('..text..')', strfind(text, part, 1, true)) end
Has('empty', Problem(''), 'paste a profile string')
Has('not ours', Problem('hello there'), 'not a SPEC-01 profile string')
Has('ElvUI', Problem('!E1!abcdef'), 'ElvUI')
Has('newer', Problem('SPEC01:9:0000:AAAA'), 'newer version')
Has('cut short', Problem(strsub(modified, 1, #modified - 7)), 'cut short')
local flipped = strsub(modified, 1, 60)..(strsub(modified, 61, 61) == 'A' and 'B' or 'A')..strsub(modified, 62)
Has('changed', Problem(flipped), 'check does not match')
Has('broken start', Problem('SPEC01::zz:AAAA'), 'start of the string is damaged')
-- Text pasted in front of a string is skipped.
local prefixed = UI:DecodeProfile('[Guild] Someone: '..modified)
ok('a chat prefix is skipped', type(prefixed) == 'table')

if failures > 0 then
	print(failures..' failures')
else
	print('ok')
end
