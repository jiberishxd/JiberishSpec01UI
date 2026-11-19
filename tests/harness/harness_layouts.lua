-- Runs Modules/Layouts.lua's solver offline with mocked frames (tests/harness/layouts.py drives it).
-- CONFIG is set by the generated config file passed as the first argument.
local configPath, layoutsPath = ...
dofile(configPath)
local C = CONFIG
local W, H = C.W, C.H

local function Any()
	local t = {}
	return setmetatable(t, {__index = function(self) return function() return self end end})
end
function CreateFrame() return Any() end
UIParent = {GetSize = function() return W, H end, GetEffectiveScale = function() return C.uiScale end}
function GetPhysicalScreenSize() return C.physW, C.physH end
function InCombatLockdown() return false end
function GetTime() return 0 end
C_Timer = {After = function() end}
function geterrorhandler() return function(e) print('ERROR', e) end end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function strtrim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end
strupper = string.upper
format = string.format
function strsplit(sep, s)
	local out = {}
	for part in (s..sep):gmatch('(.-)%'..sep) do out[#out + 1] = part end
	return unpack(out)
end
function GetCursorPosition() return 0, 0 end
GameTooltip = Any()
function ReloadUI() end

-- Edit Mode obstacles.
for name, r in pairs(C.obstacles) do
	_G[name] = {IsForbidden = function() return false end, IsVisible = function() return true end,
		GetRect = function() return r[1], r[2], r[3], r[4] end, GetEffectiveScale = function() return C.uiScale end}
end

local UI = {Kit = Any(), MOVER_POINTS = {'TOPLEFT', 'TOP', 'TOPRIGHT', 'LEFT', 'CENTER', 'RIGHT', 'BOTTOMLEFT', 'BOTTOM', 'BOTTOMRIGHT'}}
UI.db = C.db
UI.Pixel = {Clamp = function(v) return v end, Px = function(frame, n) return (n or 1) * (768 / C.physH) / C.uiScale end}
function UI:RegisterPage() end
function UI:Print(...) print('PRINT', ...) end
function UI:Safe(f, ...) return pcall(f, ...) end
function UI:HasMover(key) return C.sizes[key] ~= nil end
function UI:GetMoverSize(key) local s = C.sizes[key] if s then return s[1], s[2] end end
function UI:GetMoverOption() return nil end
function UI:MoverDocked(key) return C.docked[key] == true end
function UI:GetMoverDefault(key) local d = C.defaults[key] if d then return d[1], d[2], d[3] end end
function UI:GetMovers()
	local list = {}
	for _, key in ipairs(C.order) do list[#list + 1] = {key = key, frame = Any(), docked = C.docked[key] == true} end
	return list
end
function UI:NeedsReload() end
function UI:AfterCombat(f) f() end

-- The shared helpers (Kit/Util.lua) load first, as in the TOC.
assert(loadfile((layoutsPath:gsub('Modules[/\\]Layouts%.lua$', 'Kit/Util.lua'))))('JiberishSpec01UI', UI)
local chunk = assert(loadfile(layoutsPath))
chunk('JiberishSpec01UI', UI)

for _, key in ipairs(C.presets) do
	local list = UI:LayoutPresetMap(key)
	print('PRESET', key)
	for _, r in ipairs(list or {}) do
		print(format('RECT %s %.3f %.3f %.3f %.3f %.3f', r.key, r.x * W, r.y * H, r.w * W, r.h * H, r.scale or 1))
	end
end
