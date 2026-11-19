-- Offline test of Kit/Util.lua, run by tests/test_util.py through tools/lua/minilua.py.
-- usage: minilua.py tests/lua/util.lua JiberishSpec01UI/Kit/Util.lua
local path = ...
local failures = 0
local function check(label, got, want)
	if got ~= want then
		failures = failures + 1
		print('FAIL '..label..': got '..tostring(got)..', want '..tostring(want))
	end
end
local function count(...) return select('#', ...) end

-- A client with secret values: SECRET (and the number 42) are secret.
local SECRET = setmetatable({}, {__tostring = function() return 'SECRET' end})
local secrets = {[SECRET] = true, [42] = true}
issecretvalue = function(value) return value ~= nil and secrets[value] == true end

local function Load(ui)
	local chunk = assert(loadfile(path))
	chunk('JiberishSpec01UI', ui)
	return ui.Util
end

local UI = {}
local Util = Load(UI)
check('exposed as UI.Util', UI.Util, Util)

-- IsSecret
check('IsSecret secret', Util.IsSecret(SECRET), true)
check('IsSecret secret number', Util.IsSecret(42), true)
check('IsSecret plain', Util.IsSecret(7), false)
check('IsSecret nil', Util.IsSecret(nil), false)
check('IsSecret no argument', Util.IsSecret(), false)

-- PlainValue
check('PlainValue plain', Util.PlainValue(7), 7)
check('PlainValue string', Util.PlainValue('x'), 'x')
check('PlainValue false', Util.PlainValue(false), false)
check('PlainValue secret', Util.PlainValue(SECRET), nil)
check('PlainValue secret gives one nil', count(Util.PlainValue(SECRET)), 1)

-- PlainCall
check('PlainCall result', Util.PlainCall(function(a, b) return a + b end, 2, 3), 5)
check('PlainCall first result only', count(Util.PlainCall(function() return 1, 2 end)), 1)
check('PlainCall false', Util.PlainCall(function() return false end), false)
check('PlainCall secret', Util.PlainCall(function() return SECRET end), nil)
check('PlainCall error', Util.PlainCall(function() error('boom') end), nil)
check('PlainCall not a function', Util.PlainCall(nil, 1), nil)
check('PlainCall table', Util.PlainCall({}), nil)

-- Forbidden
local frame = {IsForbidden = function() return false end}
local forbidden = {IsForbidden = function() return true end}
local broken = {IsForbidden = function() error('forbidden') end}
check('Forbidden frame', Util.Forbidden(frame), false)
check('Forbidden table without IsForbidden', Util.Forbidden({}), false)
check('Forbidden forbidden', Util.Forbidden(forbidden), true)
check('Forbidden IsForbidden errors', Util.Forbidden(broken), true)
check('Forbidden nil', Util.Forbidden(nil), true)
check('Forbidden false', Util.Forbidden(false), true)
check('Forbidden string', Util.Forbidden('frame'), true)
check('Forbidden number', Util.Forbidden(3), true)

-- IsObjectType
local function Region(kind, isForbidden)
	return {IsForbidden = function() return isForbidden end,
		IsObjectType = function(self, wanted) return wanted == kind end}
end
check('IsObjectType match', Util.IsObjectType(Region('Texture'), 'Texture'), true)
check('IsObjectType other kind', Util.IsObjectType(Region('Texture'), 'Frame'), false)
check('IsObjectType forbidden', Util.IsObjectType(Region('Texture', true), 'Texture'), false)
check('IsObjectType no method', Util.IsObjectType({}, 'Texture'), false)
check('IsObjectType nil', Util.IsObjectType(nil, 'Texture'), false)

-- Px and Snap: fall back to UI units until the pixel helpers exist, then use them.
check('Px without Pixel', Util.Px(frame, 3), 3)
check('Px without Pixel, default 1', Util.Px(frame), 1)
check('Snap without Pixel', Util.Snap(frame, 2.6), 3)
UI.Pixel = {
	Px = function(f, n) return (n or 1) * 0.5 end,
	Snap = function(f, value) return math.floor(value / 0.5 + 0.5) * 0.5 end,
}
check('Px through Pixel', Util.Px(frame, 3), 1.5)
check('Snap through Pixel', Util.Snap(frame, 1.3), 1.5)

-- Numbers
check('Round up', Util.Round(2.5), 3)
check('Round down', Util.Round(2.49), 2)
check('Round negative', Util.Round(-2.6), -3)
check('SnapTo', Util.SnapTo(7.4, 2), 8)
check('SnapTo below', Util.SnapTo(6.9, 2), 6)
check('Clamp inside', Util.Clamp(5, 1, 10), 5)
check('Clamp low', Util.Clamp(-1, 1, 10), 1)
check('Clamp high', Util.Clamp(11, 1, 10), 10)
check('Clamp fallback', Util.Clamp('x', 1, 10, 4), 4)
check('Clamp fallback clamped', Util.Clamp(nil, 1, 10, 40), 10)

-- RGB
local r, g, b = Util.RGB({0.1, 0.2, 0.3})
check('RGB array r', r, 0.1); check('RGB array g', g, 0.2); check('RGB array b', b, 0.3)
r, g, b = Util.RGB({r = 0.4, g = 0, b = 0.6})
check('RGB keyed r', r, 0.4); check('RGB keyed zero g', g, 0); check('RGB keyed b', b, 0.6)
r, g, b = Util.RGB(nil)
check('RGB nil r', r, nil); check('RGB nil b', b, nil)
r, g, b = Util.RGB('red', 1)
check('RGB default r', r, 1); check('RGB default b', b, 1)
r, g, b = Util.RGB({0.5}, 1)
check('RGB partial r', r, 0.5); check('RGB partial g', g, 1)
r, g, b = Util.RGB({0.5})
check('RGB partial, no default', g, nil)

-- Slider labels
check('Int', Util.Int(7.4), '7')
check('Int rounds', Util.Int(7.5), '8')
check('Int negative', Util.Int(-3), '-3')
check('Percent', Util.Percent(0.5), '50%')
check('Percent rounds', Util.Percent(0.255), '26%')
check('Percent whole', Util.Percent(1), '100%')

-- A client without secret values.
issecretvalue = nil
local Classic = Load({})
check('no API: IsSecret', Classic.IsSecret(SECRET), false)
check('no API: PlainValue', Classic.PlainValue(SECRET), SECRET)
check('no API: PlainCall', Classic.PlainCall(function() return 42 end), 42)

if failures > 0 then error(failures..' Util checks failed') end
print('ok')
