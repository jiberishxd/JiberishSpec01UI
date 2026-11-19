-- Offline checks for Movers.lua and EditMode.lua with mocked frames: every
-- registered mover key's settings page, whole-pixel snapping and nudging, and
-- edit mode's states (handles, the console editor in place, leaving).
-- Arguments: the addon folder, then "key=page" pairs (the pages the hub
-- registers, as found by tests/test_edit_mode.py) and "mover:key" for each
-- RegisterMover key found in the code ("prefix." for built keys).
local addonDir = ...
local args = {...}
local PHYS_H, UI_SCALE = 1440, 0.64
local W, H = 2560 * 768 / PHYS_H / UI_SCALE, 768 / UI_SCALE
local PX = 768 / PHYS_H / UI_SCALE

local function R(kind)
	local o = {kind = kind, shown = false, alpha = 1, size = {100, 40}}
	return setmetatable(o, {__index = function(self, key)
		if not key:match('^%u') then return nil end
		local f = function(s, ...)
			local a = {...}
			if key == 'SetSize' then s.size = {a[1], a[2]}
			elseif key == 'GetSize' then return s.size[1], s.size[2]
			elseif key == 'GetWidth' then return s.size[1]
			elseif key == 'GetHeight' then return s.size[2]
			elseif key == 'SetWidth' then s.size[1] = a[1]
			elseif key == 'Show' then s.shown = true
			elseif key == 'Hide' then s.shown = false
			elseif key == 'SetShown' then s.shown = a[1] and true or false
			elseif key == 'IsShown' or key == 'IsVisible' then return s.shown
			elseif key == 'SetAlpha' then s.alpha = a[1]
			elseif key == 'GetAlpha' then return s.alpha
			elseif key == 'SetText' then s.text = a[1]
			elseif key == 'GetStringWidth' then return 40
			elseif key == 'GetEffectiveScale' or key == 'GetScale' then return 1
			elseif key == 'GetFrameLevel' then return 1
			elseif key == 'SetScript' then rawset(s, 'on'..a[1], a[2])
			elseif key == 'SetPoint' then s.point = a
			elseif key == 'IsProtected' then return false
			elseif key == 'IsMouseEnabled' then return true
			elseif key == 'SetKeyText' then s.text = a[1]
			elseif key == 'SetChecked' then s.checked = a[1]
			elseif key:find('^Create') then return R(key)
			end
		end
		rawset(self, key, f)
		return f
	end})
end

function CreateFrame(_, name) local f = R('Frame') if name then f.GetName = function() return name end end return f end
-- Override bindings: the keys edit mode holds (key -> button name).
local bound = {}
function SetOverrideBindingClick(_, _, key, name) bound[key] = name end
function ClearOverrideBindings() for key in pairs(bound) do bound[key] = nil end end
UIParent = R('UIParent')
UIParent.size = {W, H}
UIParent.shown = true
local now = 100
function GetTime() return now end
C_Timer = {After = function() end}
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
strupper = string.upper
format = string.format
local combat = false
function InCombatLockdown() return combat end
local shift = false
function IsShiftKeyDown() return shift end
function IsControlKeyDown() return false end
function GetCursorPosition() return 0, 0 end
GameTooltip = R('GameTooltip')

local UI = {db = {movers = {}}, modules = {}}
function UI:RegisterDefaults(section, values)
	self.db[section] = self.db[section] or {}
	for k, v in pairs(values) do self.db[section][k] = v end
end
function UI:Safe(f, ...)
	local ok, e = pcall(f, ...)
	if not ok then print('ERROR', e) end
	return ok
end
function UI:AfterCombat(f) f() end
function UI:Print(...) print('PRINT', ...) end
local pages, opened = {}, nil
function UI:GetPage(key) return pages[key] end
function UI:ToggleHub(key) opened = key end
UI.Pixel = {Px = function(_, n) return (n or 1) * PX end, OnChange = function() end}
UI.Kit = setmetatable({media = 'M\\'}, {__index = function(_, key)
	if key == 'Key' then
		return function(_, _, opts)
			local o = R('Key')
			rawset(o, 'face', R('Face'))
			rawset(o, 'text', R('Text'))
			rawset(o, 'onClick', opts and opts.onClick)
			return o
		end
	end
	if key == 'LCDPanel' or key == 'Device' then return function() return R(key) end end
	return function() return R('Kit.'..key) end
end})
assert(loadfile(addonDir..'/Kit/Util.lua'))('JiberishSpec01UI', UI)
assert(loadfile(addonDir..'/Modules/Movers.lua'))('JiberishSpec01UI', UI)
assert(loadfile(addonDir..'/Modules/EditMode.lua'))('JiberishSpec01UI', UI)

local fails = 0
local function check(label, ok, detail)
	if not ok then fails = fails + 1 end
	print(format('%-58s %s%s', label, ok and 'ok' or 'FAIL', detail and ('  '..detail) or ''))
end
-- Saved spots keep two decimals of a UI unit (Movers.lua's Store), well under a hundredth of a pixel.
local function Whole(value) return math.abs(value / PX - math.floor(value / PX + 0.5)) < 0.01 end

-- Settings pages: every key the code registers opens a page the hub has.
local keys = {}
for _, arg in ipairs(args) do
	local page = arg:match('^page:(.+)$')
	if page then pages[page] = {title = page} end
	local key = arg:match('^mover:(.+)$')
	if key then keys[#keys + 1] = key:sub(-1) == '.' and key..'x' or key end
end
pages.layout = pages.layout or {title = 'Layout'}
for _, key in ipairs(keys) do
	local page = UI:MoverPage(key)
	check('page '..key, page ~= 'layout' and pages[page] ~= nil, page)
end
check('unknown key falls back to Layout', UI:MoverPage('zz.unknown') == 'layout')

-- Registering, with a page override.
local function Frame(w, h) local f = R('Mover') f.size = {w, h} f.shown = true return f end
UI:RegisterMover(Frame(200, 60), 'uf.player', 'Player', {'BOTTOM', -300, 200})
UI:RegisterMover(Frame(200, 60), 'uf.target', 'Target', {'BOTTOM', 300, 200})
UI:RegisterMover(Frame(80, 30), 'zz.mine', 'Mine', {'CENTER', 0, 0}, {page = 'unitframes'})
check('opts.page overrides the map', UI:MoverPage('zz.mine') == 'unitframes')
UI:OpenMoverSettings('uf.target')
check('settings key opens the page', opened == 'unitframes', tostring(opened))

-- Edit mode on: handles, keyboard, strip.
UI:EditMode(true)
check('edit mode on', UI:MoversUnlocked() == true and UI:EditModeActive() == true)
check('edit mode binds Escape and Ctrl+Z only', bound.ESCAPE ~= nil and bound['CTRL-Z'] ~= nil and bound.W == nil
	and bound.LEFT == nil)
check('handle shown', UI:MoverHandle('uf.player') and UI:MoverHandle('uf.player'):IsShown())
UI:ToggleMovers(false) -- /spec unlock while on: no change
check('unlock while on keeps edit mode', UI:MoversUnlocked() == true)

-- Snapping: a whole-pixel spot; magnet onto the other frame's edge with a guide.
UI.db.layout.grid = 4
local cx, cy, gx = UI:SnapMover('uf.player', 300 - 200 + 3 * PX, -H / 2 + 230)
local _, x, y = UI:GetMoverPosition('uf.player')
UI:SetMoverCenter('uf.player', cx, cy)
_, x, y = UI:GetMoverPosition('uf.player')
check('snapped spot is whole pixels', Whole(x) and Whole(y), format('%.4f %.4f', x / PX, y / PX))
check('magnet met the target frame edge', gx ~= nil and math.abs(gx - 200) < 1e-6, tostring(gx))
shift = true
cx, cy, gx = UI:SnapMover('uf.player', 13.37, -H / 2 + 231.1)
shift = false
check('Shift: free, still whole pixels, no guide', gx == nil)
-- Grid choices are the console editor's.
UI.db.layout.grid = 16
check('a grid of 16 falls back to 8 px', UI:MoverGrid() == 8)

-- Nudging one pixel.
UI:SetMoverPosition('uf.player', 'BOTTOM', -300.3, 200.2)
UI:SelectMover('uf.player')
UI:NudgeMover('uf.player', PX, 0)
_, x, y = UI:GetMoverPosition('uf.player')
check('nudge lands on whole pixels', Whole(x) and Whole(y), format('%.4f %.4f', x / PX, y / PX))
check('nudge saved in the movers table', type(UI.db.movers['uf.player']) == 'table' and UI.db.movers['uf.player'].anchor == 'BOTTOM')

-- The console editor in place: handles hidden, strip kept; back again.
UI:SetEditModeConsole(true)
check('console mode hides handles', not UI:MoverHandle('uf.player'):IsShown() and UI:EditModeConsole())
UI:SetEditModeConsole(false)
check('back from the console shows handles', UI:MoverHandle('uf.player'):IsShown() and not UI:EditModeConsole())

-- Docked frames have no handle.
UI:DockMover('uf.target', function() end)
check('docked frame has no handle', not UI:MoverHandle('uf.target'):IsShown())
UI:DockMover('uf.target', nil)
check('undocked frame gets its handle back', UI:MoverHandle('uf.target'):IsShown())

-- Leaving.
UI:EditMode(false)
check('edit mode off', UI:MoversUnlocked() == false and not UI:MoverHandle('uf.player'):IsShown())
check('edit mode off gives the keys back', next(bound) == nil)
UI:ToggleMovers() -- /spec move toggles
check('/spec move toggles on', UI:MoversUnlocked() == true)
UI:ToggleMovers(true)
check('/spec lock leaves', UI:MoversUnlocked() == false)
combat = true
UI:EditMode(true)
check('refused in combat', UI:MoversUnlocked() == false)
combat = false

print(format('failures %d', fails))
