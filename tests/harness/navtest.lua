-- Offline checks for Navigation.lua, Compass.lua and OverlayMap.lua with mocked frames.
local addonDir = ...
local calls = {}
local function R(kind)
	local o = {kind = kind, points = {}, shown = true, alpha = 1, size = {1, 1}}
	return setmetatable(o, {__index = function(self, key)
		if not key:match('^%u') then return nil end
		local f = function(s, ...)
			local a = {...}
			if key == 'SetPoint' then s.point = a
			elseif key == 'ClearAllPoints' then s.point = nil
			elseif key == 'SetSize' then s.size = {a[1], a[2]}
			elseif key == 'SetWidth' then s.size[1] = a[1]
			elseif key == 'SetHeight' then s.size[2] = a[1]
			elseif key == 'GetSize' then return s.size[1], s.size[2]
			elseif key == 'GetWidth' then return s.size[1]
			elseif key == 'GetHeight' then return s.size[2]
			elseif key == 'Show' then s.shown = true
			elseif key == 'Hide' then s.shown = false
			elseif key == 'SetShown' then s.shown = a[1] and true or false
			elseif key == 'IsShown' or key == 'IsVisible' then return s.shown
			elseif key == 'SetAlpha' then s.alpha = a[1]
			elseif key == 'GetAlpha' then return s.alpha
			elseif key == 'SetText' then s.text = a[1]
			elseif key == 'GetStringWidth' then return 20
			elseif key == 'GetEffectiveScale' or key == 'GetScale' then return 1
			elseif key == 'GetFrameLevel' then return 1
			elseif key == 'SetTexture' then s.texture = a[1]
			elseif key == 'SetRotation' then s.rotation = a[1]
			elseif key == 'SetScript' then local sc = rawget(s, 'scripts') or {}; rawset(s, 'scripts', sc); sc[a[1]] = a[2]
			elseif key == 'SetStartPoint' then s.start = a
			elseif key == 'SetEndPoint' then s.stop = a
			elseif key == 'IsProtected' or key == 'IsForbidden' then return false
			elseif key:find('^Create') then local c = R(key) calls[#calls + 1] = c return c
			end
		end
		rawset(self, key, f)
		return f
	end})
end
function CreateFrame(_, name) local f = R('Frame') calls[#calls + 1] = f if name then _G[name] = f end return f end
UIParent = R('UIParent')
local now = 100
function GetTime() return now end
local timers = {}
C_Timer = {After = function(_, f) timers[#timers + 1] = f end}
local function RunTimers() local list = timers; timers = {}; for _, f in ipairs(list) do f() end end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
strupper = string.upper
format = string.format
function InCombatLockdown() return false end
-- The world: one zone 3000 x 2000 yd, one art layer of 1002 x 668 texels in 256-texel tiles.
local player = {x = 0.5, y = 0.5}
local facing = 0
function GetPlayerFacing() return facing end
function GetUnitSpeed() return 7 end
function GetZoneText() return 'Elwynn Forest' end
function GetSubZoneText() return 'Goldshire' end
function UnitFactionGroup() return 'Alliance' end
function IsInGroup() return false end
Enum = {MinimapTrackingFilter = {Innkeeper = 32}, UIMapType = {Continent = 2, Zone = 3, Micro = 5}, FlightPathFaction = {Neutral = 0, Horde = 1, Alliance = 2}, SuperTrackingMapPinType = {AreaPOI = 0, QuestOffer = 1, TaxiNode = 2}}
C_Map = {
	GetBestMapForUnit = function() return 37 end,
	GetMapArtID = function() return 1 end,
	GetMapWorldSize = function() return 3000, 2000 end,
	GetMapInfo = function(id) return {mapType = 3, parentMapID = 12, name = 'Elwynn Forest'} end,
	GetPlayerMapPosition = function() return {x = player.x, y = player.y} end,
	GetMapArtLayers = function() return {{layerWidth = 1002, layerHeight = 668, tileWidth = 256, tileHeight = 256}} end,
	GetMapArtLayerTextures = function() local t = {} for i = 1, 12 do t[i] = 1000 + i end return t end,
	HasUserWaypoint = function() return false end,
}
C_TaxiMap = {GetTaxiNodesForMap = function() return {
	{nodeID = 1, position = {x = 0.5, y = 0.45}, faction = 0}, -- 100 yd north
	{nodeID = 2, position = {x = 0.55, y = 0.5}, faction = 1}, -- Horde: skipped
} end}
C_QuestLog = {GetQuestsOnMap = function() return {{questID = 7, x = 0.53, y = 0.5}} end, -- 90 yd east
	GetQuestWatchType = function() return 0 end, ReadyForTurnIn = function() return false end}
C_SuperTrack = {GetSuperTrackedQuestID = function() return 0 end}

local UI = {modules = {}, moduleOrder = {}, db = {}}
local account = {}
function UI:Account(section) account[section] = account[section] or {}; return account[section] end
function time() return 1000 end
function IsResting() return true end
function IsMounted() return false end
function IsAltKeyDown() return true end
function IsShiftKeyDown() return false end
function IsControlKeyDown() return false end
function UnitName(u) return 'Innkeeper Farley' end
function UnitIsPlayer() return false end
function UnitCanAttack() return false end
local npcExists = true
function UnitExists(u) if u == 'npc' then return npcExists end return true end
function CheckInteractDistance() return true end
function CanMerchantRepair() return true end
C_TooltipInfo = {GetUnit = function(u) return {lines = {{leftText = 'Innkeeper Farley'}, {leftText = '<Innkeeper>'}, {leftText = 'Level 30'}}} end}
C_Minimap = {GetNumTrackingTypes = function() return 1 end, GetTrackingFilter = function() return {filterID = 32} end,
	GetTrackingInfo = function() return {name = 'Innkeeper'} end}
UI.Pixel = {Px = function(_, n) return n or 1 end, Perfect = function() return 1 end}
function UI:RegisterModule(name, m) self.modules[name] = m; return m end
function UI:RegisterDefaults(section, values) self.db[section] = self.db[section] or {}; for k, v in pairs(values) do self.db[section][k] = v end end
function UI:RegisterPage() end
function UI:Safe(f, ...) local ok, e = pcall(f, ...) if not ok then print('ERROR', e) end return ok end
function UI:RegisterMover() end
function UI:PlaceMover() end
function UI:MoverAlphaFor() return 1 end
function UI:Print(...) print('PRINT', ...) end
UI.db.navigation = {}
UI.db.reduceMotion = false
local Kit = setmetatable({media = 'M\\'}, {__index = function(_, key)
	if key == 'Shell' then return function(_, owner, opts) local o = R('Shell') o.opts = opts or {} return o end end
	if key == 'Device' then return function() local d = R('Device') d.shell = R('Shell') return d end end
	if key == 'RGB' then return function() return 1, 1, 1 end end
	if key == 'Reduced' or key == 'Animating' then return function() return false end end
	return function() local o = R('Kit.'..key) calls[#calls + 1] = o return o end
end})
UI.Kit = Kit

local function load(name) assert(loadfile(addonDir..'/Modules/'..name))('JiberishSpec01UI', UI) end
-- The shared helpers (Kit/Util.lua) load first, as in the TOC.
assert(loadfile(addonDir..'/Kit/Util.lua'))('JiberishSpec01UI', UI)
load('Navigation.lua')
local Nav = UI.Navigation
local fails = 0
local function check(label, got, want, tol)
	local ok = math.abs(got - want) <= (tol or 1e-6)
	if not ok then fails = fails + 1 end
	print(format('%-44s %s  got %.4f want %.4f', label, ok and 'ok  ' or 'FAIL', got, want))
end
-- Heading from facing (radians CCW from north).
check('heading facing 0 = N', Nav.Heading(0), 0)
check('heading facing +pi/2 (turned left) = W', Nav.Heading(math.pi / 2), 270)
check('heading facing -pi/2 = E', Nav.Heading(-math.pi / 2), 90)
check('heading facing pi = S', Nav.Heading(math.pi), 180)
-- Bearings from map steps (east, south yards).
check('bearing north', Nav.Bearing(0, -10), 0)
check('bearing east', Nav.Bearing(10, 0), 90)
check('bearing south', Nav.Bearing(0, 10), 180)
check('bearing west', Nav.Bearing(-10, 0), 270)
check('bearing NE', Nav.Bearing(10, -10), 45)
check('relative 350 from 10', Nav.Relative(350, 10), -20)
check('relative 10 from 350', Nav.Relative(10, 350), 20)
check('relative behind', math.abs(Nav.Relative(180, 0)), 180)
print('point 44 =', Nav.Point(44), ' point 338 =', Nav.Point(338), ' yards', Nav.Yards(87.4), Nav.Yards(1234))
-- Spread: three points 2 apart with step 10 never overlap and keep order.
local row = {{pos = 50}, {pos = 52}, {pos = 54}, {pos = 200}}
Nav.Spread(row, 10, 5, 295)
for i = 1, 3 do check('spread gap '..i, (row[i + 1].pos + row[i + 1].shift) - (row[i].pos + row[i].shift) >= 10 - 1e-9 and 1 or 0, 1) end
check('spread centred on cluster', (row[1].pos + row[1].shift + row[3].pos + row[3].shift) / 2, 52)
check('spread lone point stays', row[4].shift, 0)
local edge = {{pos = 2}, {pos = 3}}
Nav.Spread(edge, 10, 5, 295)
check('spread kept inside the low end', edge[1].pos + edge[1].shift, 5)

-- Sensing and points.
UI.modules.navigation:Enable()
local here = Nav:Sense(now)
check('position yards x', here.wx, 1500)
check('position yards y', here.wy, 1000)
check('heading read', here.heading, 0)
Nav:Want('test', true)
RunTimers()
print('points:', #Nav.pois)
for _, poi in ipairs(Nav.pois) do
	local d, b = Nav:Measure(poi)
	print(format('  %-6s %-5s %6.1f yd  bearing %5.1f', poi.uid, poi.kind, d, b))
end
local near = Nav:Near(400)
check('flight master 100 yd north: distance', near[2] and near[2].distance or -1, 100, 1e-6)
-- Moving: walk east for half a second -> movement bearing 90.
now = now + 0.1; player.x = player.x + 0.0005; Nav:Sense(now)
now = now + 0.1; player.x = player.x + 0.0005; Nav:Sense(now)
now = now + 0.1; player.x = player.x + 0.0005; here = Nav:Sense(now)
check('moving east bearing', here.moveDeg or -1, 90, 1e-6)
print('moving', here.moving, 'speed', here.speed)

-- The overlay map: tiles under a 300-unit window at 250 yd.
load('OverlayMap.lua')
UI.db.overlaymap.shown = true
local map = UI.modules.overlaymap
map:Enable()
local holder = _G.JiberishSpec01OverlayMap
holder.scripts.OnShow()
now = now + 1
player.x, player.y = 0.5, 0.5
holder.scripts.OnUpdate(holder, 1)
local tiles, canvas = {}, nil
for _, c in ipairs(calls) do
	if c.kind == 'CreateTexture' and type(c.texture) == 'number' and c.texture > 1000 and c.shown then
		tiles[#tiles + 1] = c.texture
		canvas = c.point and c.point[2]
		print(format('  tile %d at %s %.1f %.1f size %.1f x %.1f', c.texture, c.point[3], c.point[4], c.point[5], c.size[1], c.size[2]))
	end
end
table.sort(tiles)
print('tiles shown:', table.concat(tiles, ' '))
check('north-up: 4 tiles under the window', #tiles, 4)
check('canvas x offset (-900)', canvas.point[4], -900, 0.01)
check('canvas y offset (+600)', canvas.point[5], 600, 0.01)
-- Points on the map: the quest 90 yd east -> 54 units right of centre.
for _, c in ipairs(calls) do
	if c.kind == 'Frame' and c.point and c.point[1] == 'CENTER' and c.point[3] == 'CENTER' and c.size[1] == 14 then
		print(format('  map key at %.1f %.1f', c.point[4], c.point[5]))
	end
end
-- Turning with you, facing west.
UI.db.overlaymap.rotate = true
map:Refresh()
facing = math.pi / 2
now = now + 1
holder.scripts.OnUpdate(holder, 1)
for _, c in ipairs(calls) do
	if c.kind == 'CreateTexture' and c.texture == 1002 and c.shown then
		print(format('  rotated tile 1002 centre %.1f %.1f rotation %.3f', c.point[4], c.point[5], c.rotation))
		check('rotated tile 1002 x (north -> right)', c.point[4], 370.1, 0.2)
		check('rotated tile 1002 y (west -> up)', c.point[5], 210.2, 0.2)
		check('rotated tile turned -facing', c.rotation, -math.pi / 2)
	end
end
-- No signal: the position goes away.
C_Map.GetPlayerMapPosition = function() return nil end
now = now + 1
holder.scripts.OnUpdate(holder, 1)
print('signal frame shown (NO SIGNAL)', holder.signal.shown)

-- The compass.
C_Map.GetPlayerMapPosition = function() return {x = player.x, y = player.y} end
load('Compass.lua')
local compass = UI.modules.compass
compass:Enable()
local frame = _G.JiberishSpec01Compass
facing = 0
now = now + 1
frame.scripts.OnUpdate(frame, 1)
local w, h = frame:GetSize()
print(format('compass size %.0f x %.0f', w, h))
local function LabelX(text)
	for _, c in ipairs(calls) do
		if c.kind == 'Kit.Text' and c.text == text and c.point and c.alpha > 0 then return c.point[4] end
	end
end
check('facing N: N under the caret (x = 222)', LabelX('N') or -1, 222, 0.6)
check('facing N: E a quarter turn right (spacing snapped: 12/5 per degree)', LabelX('E') or -1, 222 + 90 * 12 / 5, 0.6)
facing = -math.pi / 2 -- east
now = now + 1
frame.scripts.OnUpdate(frame, 1)
check('facing E: E under the caret', LabelX('E') or -1, 222, 0.6)
for _, c in ipairs(calls) do
	if c.kind == 'Kit.Text' and c.text and c.text:find('°') then print('  heading chip:', c.text) end
	if c.kind == 'Kit.Text' and c.text and c.text:find('Y/S') then print('  speed chip:', c.text) end
end
for _, c in ipairs(calls) do
	if c.kind == 'Frame' and c.point and c.point[1] == 'TOP' and c.point[3] == 'TOPLEFT' and c.size[1] == 16 and c.shown then
		print(format('  compass key at x %.1f', c.point[4]))
	end
end

-- A city with a building that has no art: the drawn map falls back to the city.
-- City 84 is 1000 x 800 yd; the inn (999) sits in its rectangle x 0.40-0.50, y 0.60-0.70.
local city = {x = 0.45, y = 0.65}
C_Map.GetBestMapForUnit = function() return 999 end
C_Map.GetMapInfo = function(id)
	if id == 999 then return {mapType = 5, parentMapID = 84, name = 'The Gilded Rose'} end
	if id == 84 then return {mapType = 3, parentMapID = 13, name = 'Stormwind City'} end
	return {mapType = 2, parentMapID = 0, name = 'Eastern Kingdoms'}
end
C_Map.GetMapWorldSize = function(id) if id == 999 then return 100, 80 end if id == 84 then return 1000, 800 end return 30000, 20000 end
C_Map.GetMapArtLayers = function(id) if id == 999 then return {} end return {{layerWidth = 1002, layerHeight = 668, tileWidth = 256, tileHeight = 256}} end
C_Map.GetPlayerMapPosition = function(id)
	if id == 84 then return {x = city.x, y = city.y} end
	if id == 999 then return {x = (city.x - 0.40) / 0.10, y = (city.y - 0.60) / 0.10} end
	return {x = 0.3, y = 0.4}
end
C_Map.GetMapRectOnMap = function(inner, outer) if inner == 999 and outer == 84 then return 0.40, 0.50, 0.60, 0.70 end end
C_TaxiMap.GetTaxiNodesForMap = function(id) if id == 84 then return {{nodeID = 9, position = {x = 0.45, y = 0.55}, faction = 0}} end return {} end
C_QuestLog.GetQuestsOnMap = function(id) if id == 999 then return {{questID = 70, x = 0.9, y = 0.5}} end return {} end
now = now + 1
here = Nav:Sense(now)
print('maps: best', here.bestID, 'drawn', here.mapID, 'zone', here.zoneID)
check('building without art: drawn on the city', here.mapID, 84)
check('learned services kept on the city', here.zoneID, 84)
local zx, zy = Nav.Translate(999, 84, 0.9, 0.5)
check('translate building -> city x', zx, 0.49)
check('translate building -> city y', zy, 0.65)
local bx, by = Nav.Translate(84, 999, 0.49, 0.65)
check('translate city -> building x', bx, 0.9)
local zone, sub = Nav:Zone()
print('header:', zone, '/', sub)
-- Learn: talking to the innkeeper here, then a repair merchant 3 yd away (a different family).
UI.modules.navigation:Enable()
Nav:Learn('inn', 2, 'Innkeeper Farley', 'Innkeeper')
city.x = city.x + 0.003 -- 3 yd east
now = now + 1; Nav:Sense(now)
Nav:Learn('inn', 2, 'Innkeeper Farley', 'Innkeeper') -- the same inn again: merged
Nav:Learn('repair', 2, 'Smith', 'Armorer')
local list = account.services[84]
check('inn merged within 8 yd, repair kept apart', #list, 2)
check('inn seen twice', list[1].seen, 2)
-- A near (title) trainer, then the exact profession trainer 5 yd away replaces it.
Nav:Learn('trainer', 1, 'Trainer', 'Tailoring Trainer')
city.y = city.y + 0.00625 -- 5 yd south
now = now + 1; Nav:Sense(now)
Nav:Learn('profession', 2, 'Trainer', 'Tailoring Trainer')
check('near trainer replaced by the exact profession trainer', #list, 3)
check('kind became profession', list[3].k == 'profession' and 1 or 0, 1)
check('confidence exact', list[3].c, 2)
-- A mailbox used outside a town with nobody to talk to waits for a second visit.
npcExists = false
IsResting = function() return false end
Nav:Learn('mail', 0)
RunTimers()
local function count(kind) local n = 0 for _, p in ipairs(Nav.pois) do if p.kind == kind then n = n + 1 end end return n end
check('one-visit mailbox hidden', count('mail'), 0)
Nav:Learn('mail', 0)
RunTimers()
check('mailbox shown after a second visit', count('mail'), 1)
check('taxi from the city map', count('taxi'), 1)
check('building quest carried onto the city map', count('quest'), 1)
for _, p in ipairs(Nav.pois) do
	local d, b = Nav:Measure(p)
	print(format('  %-10s %-10s %6.1f yd  bearing %5.1f  x %.4f y %.4f', p.uid, p.kind, d, b, p.x, p.y))
end
local inn = Nav:Nearest('inn')
check('nearest inn found', inn and 1 or 0, 1)
-- Titles: the localized tracking name finds an innkeeper by title.
npcExists = true
local before = #list
UI.modules.navigation:Enable()
print('learned total', Nav:LearnedCount())
-- The compass readout while Alt is held.
now = now + 1
frame.scripts.OnUpdate(frame, 1)
for _, c in ipairs(calls) do
	if c.kind == 'Kit.Text' and c.text and c.text:find('|T') then print('  nearest readout:', c.text) break end
end
-- Secret values: nothing secret is compared, stored or measured.
local SECRET = setmetatable({}, {__tostring = function() return 'SECRET' end})
issecretvalue = function(v) return v == SECRET end
C_TooltipInfo.GetUnit = function() return {lines = {{leftText = 'x'}, {leftText = SECRET}}} end
local learned = Nav:LearnedCount()
UI.modules.navigation:Enable()
-- An NPC under the mouse whose title is secret is not learned.
for _, f in ipairs(calls) do
	if f.scripts and f.scripts.OnEvent then pcall(f.scripts.OnEvent, f, 'UPDATE_MOUSEOVER_UNIT') end
end
check('secret title: nothing learned', Nav:LearnedCount(), learned)
GetPlayerFacing = function() return SECRET end
now = now + 1
here = Nav:Sense(now)
check('secret facing: no heading', here.heading == nil and 1 or 0, 1)
C_Map.GetPlayerMapPosition = function() return {x = SECRET, y = SECRET} end
now = now + 1
here = Nav:Sense(now)
check('secret position: no fix', here.x == nil and 1 or 0, 1)
UnitIsPlayer = function() return SECRET end
C_TooltipInfo.GetUnit = function() return {lines = {{leftText = 'x'}, {leftText = '<Banker>'}}} end
for _, f in ipairs(calls) do
	if f.scripts and f.scripts.OnEvent then pcall(f.scripts.OnEvent, f, 'UPDATE_MOUSEOVER_UNIT') end
end
check('secret UnitIsPlayer: nothing learned', Nav:LearnedCount(), learned)
-- Control: the same banker with plain answers (and a plain position) is learned, as ~near.
UnitIsPlayer = function() return false end
C_Map.GetPlayerMapPosition = function(id) if id == 84 then return {x = 0.2, y = 0.2} end return {x = 0.3, y = 0.4} end
now = now + 1; Nav:Sense(now)
for _, f in ipairs(calls) do
	if f.scripts and f.scripts.OnEvent then pcall(f.scripts.OnEvent, f, 'UPDATE_MOUSEOVER_UNIT') end
end
check('plain banker title within 10 yd: learned', Nav:LearnedCount(), learned + 1)
local last = account.services[84][#account.services[84]]
print('  learned:', last.k, 'confidence', last.c, last.n, last.s)
print('failures', fails)
