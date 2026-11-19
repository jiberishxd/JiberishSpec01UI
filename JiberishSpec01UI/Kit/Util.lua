-- Small shared helpers, loaded straight after Core.lua so every file can use them.
--
-- Files take local aliases at load time, so call sites keep a local upvalue in
-- hot paths:
--     local IsSecret, Plain = UI.Util.IsSecret, UI.Util.PlainCall
-- Keep these tiny: they run in OnUpdate handlers and unit events.
local _, UI = ...
local Util = {}
UI.Util = Util -- Theme.lua also hangs it on the kit as Kit.Util

local type, pcall, floor, format = type, pcall, math.floor, string.format
local issecretvalue = issecretvalue

-- Secret values ----------------------------------------------------------------------------
-- Retail hides some values (health, auras, names in combat) behind secret values
-- that can be shown but not compared, measured or used as table keys. Clients
-- without them have no secrets.

-- True when value is a secret value.
local IsSecret = issecretvalue and function(value) return issecretvalue(value) end
	or function() return false end
Util.IsSecret = IsSecret

-- value, or nil when it is secret.
function Util.PlainValue(value)
	if IsSecret(value) then return nil end
	return value
end

-- The first result of func(...), or nil when func is not a function, errors,
-- or answers a secret value.
function Util.PlainCall(func, ...)
	if type(func) ~= 'function' then return nil end
	local ok, value = pcall(func, ...)
	if not ok or IsSecret(value) then return nil end
	return value
end

-- Frames ------------------------------------------------------------------------------------

-- True for anything we must not touch: non-tables, and forbidden frames (or
-- ones whose IsForbidden itself errors).
local function Forbidden(object)
	if type(object) ~= 'table' then return true end
	local check = object.IsForbidden
	if not check then return false end
	local ok, forbidden = pcall(check, object)
	return not ok or forbidden == true
end
Util.Forbidden = Forbidden

-- True when object is a frame or region of this kind (and safe to touch).
function Util.IsObjectType(object, kind)
	return not Forbidden(object) and object.IsObjectType and object:IsObjectType(kind) and true or false
end

-- Physical pixels (Kit/Pixel.lua): n pixels in frame's units, and a value rounded
-- to whole pixels. Before the pixel helpers load these fall back to UI units.
function Util.Px(frame, n)
	local Pixel = UI.Pixel
	if Pixel then return Pixel.Px(frame, n) end
	return n or 1
end

function Util.Snap(frame, value)
	local Pixel = UI.Pixel
	if Pixel then return Pixel.Snap(frame, value) end
	return floor(value + 0.5)
end

-- Numbers -----------------------------------------------------------------------------------

-- value rounded to the nearest whole number.
function Util.Round(value) return floor(value + 0.5) end

-- value rounded to the nearest multiple of step (one pixel, a grid cell).
function Util.SnapTo(value, step) return floor(value / step + 0.5) * step end

-- value held within [low, high]; a non-number is replaced by fallback first.
function Util.Clamp(value, low, high, fallback)
	if type(value) ~= 'number' then value = fallback end
	if value < low then return low end
	if value > high then return high end
	return value
end

-- r, g, b of a color setting, {r, g, b} or {r =, g =, b =}. Missing parts (or a
-- non-table) give default, which is nil unless passed.
function Util.RGB(color, default)
	if type(color) ~= 'table' then return default, default, default end
	return color[1] or color.r or default, color[2] or color.g or default, color[3] or color.b or default
end

-- Slider labels: a whole number, and a 0-1 fraction as a percentage.
function Util.Int(value) return format('%d', floor(value + 0.5)) end
function Util.Percent(value) return format('%d%%', floor(value * 100 + 0.5)) end
