-- Navigation: what the NV-3 compass (Compass.lua) and the NV-4 overlay map
-- (OverlayMap.lua) share. Where you are and which way you face, which way you
-- are moving and how fast, and the points of interest around you, all read
-- from the maps the game keeps; plus a learned atlas of town services and the
-- hub's Navigation page.
--
-- What the game lets an addon know, and so what these show:
--   * Your map position (C_Map.GetPlayerMapPosition) and facing
--     (GetPlayerFacing) are shared in the open world and in cities. In
--     dungeons, raids, battlegrounds and other restricted places they are nil
--     (or secret): then both devices print NO SIGNAL and nothing is measured.
--   * Maps: the game names the most detailed map you are on (a building, a
--     floor of Dalaran or Ironforge, a cave). When that map has no art, no size
--     in yards or no position for you, its parents are tried in turn (the
--     district, the city, the zone), so the map is never blank. Points from the
--     map you are on, the drawn map and the city or zone above are all gathered
--     and carried onto the drawn map with C_Map.GetMapRectOnMap.
--   * Distances are map coordinates times the map's size in yards
--     (C_Map.GetMapWorldSize), so they are as exact as the map itself.
--   * Points come from the maps: quests in your log, world quests and bonus
--     objectives, quest-line starts, flight masters, area POIs (including the
--     town-service icons some city maps carry), vignettes, dungeon entrances,
--     entrances to other maps and your waypoint or super-tracked target.
--   * Town services the game shows only as minimap tracking blips (repairers,
--     innkeepers, bankers, mailboxes, trainers, vendors, stable masters...) have
--     no position an addon can ask for. They are learned instead: where you
--     stand when you use one (you are within reach of it), and where you stand
--     when a friendly NPC whose title names a service is within ten yards.
--     Learned spots are kept for the whole account, per city or zone map.
-- Nothing here touches the Blizzard minimap or map frames.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, GetTime = CreateFrame, GetTime
local floor, max, min, sqrt, atan2, deg = math.floor, math.max, math.min, math.sqrt, math.atan2, math.deg

local module = UI:RegisterModule('navigation', {always = true})

local Nav = {}
UI.Navigation = Nav

-- defaults:begin
UI:RegisterDefaults('navigation', {
	quests = 'tracked', -- 'tracked' | 'all' | 'off': quests in your log
	worldQuests = true, -- world quests and bonus objectives
	questGivers = true, -- available quest-line starts
	flightMasters = true,
	services = true, -- town services: from city maps and learned
	areaPois = true, -- other map POIs: events, quest hubs, delves, landmarks
	vignettes = true, -- rares, treasures and events the minimap shows
	dungeons = true, -- dungeon, raid and delve entrances
	mapLinks = false, -- entrances to other maps (caves, buildings)
	waypoint = true, -- your map pin and super-tracked target
	rate = 30, -- updates per second while a device is shown
	-- Town services learned as you use them (and, near them, from NPC titles).
	learn = true, learnNear = true,
	svcRepair = true, svcInn = true, svcBank = true, svcMail = true, svcAuction = true, svcTrainer = true,
	svcVendor = false, svcStable = true, svcBarber = true, svcTransmog = true,
})
-- defaults:end

local function DB() return UI.db.navigation end
local IsSecret = UI.Util.IsSecret
Nav.IsSecret = IsSecret

-- One plain answer, or nil when the call fails or answers secret.
local Plain = UI.Util.PlainCall
Nav.Plain = Plain

-- Two plain answers, or nothing.
local function Plain2(func, ...)
	if type(func) ~= 'function' then return nil end
	local ok, a, b = pcall(func, ...)
	if not ok or IsSecret(a) or IsSecret(b) then return nil end
	return a, b
end

local function Number(value)
	if IsSecret(value) or type(value) ~= 'number' then return nil end
	return value
end
Nav.Number = Number

local function True(value) return not IsSecret(value) and value == true end

local function Text(value)
	if IsSecret(value) or type(value) ~= 'string' then return nil end
	return value
end
Nav.Text = Text

-- A map position (a Vector2D, or a table with x and y), plain, or nothing.
local function XY(pos)
	if pos == nil or IsSecret(pos) or type(pos) ~= 'table' then return nil end
	local ok, x, y = pcall(function() return pos.x, pos.y end)
	if not ok then return nil end
	x, y = Number(x), Number(y)
	if not (x and y) then return nil end
	return x, y
end
Nav.XY = XY

-- Geometry (pure; checked offline) ------------------------------------------------------
-- Facing: radians counter-clockwise from north (the game's) -> compass
-- degrees, clockwise from north.
local function Heading(facing) return (360 - deg(facing) % 360) % 360 end
Nav.Heading = Heading

-- The compass bearing of a step `east` yards east and `south` yards south.
local function Bearing(east, south) return (deg(atan2(east, -south)) + 360) % 360 end
Nav.Bearing = Bearing

-- A bearing relative to a heading, -180 (behind, to the left) to 180.
local function Relative(bearing, heading) return (bearing - heading + 540) % 360 - 180 end
Nav.Relative = Relative

local POINTS8 = {'N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'}
function Nav.Point(degrees) return POINTS8[floor(((degrees % 360) + 22.5) / 45) % 8 + 1] end

-- Yards as a chip prints them: 87, 412, 1.2K.
function Nav.Yards(yards)
	if yards >= 1000 then return format('%.1fK', yards / 1000) end
	return format('%d', floor(yards + 0.5))
end

-- Spread one row of points (sorted by .pos) so none sits within `step` of the
-- next: points that would overlap merge into a cluster laid side by side,
-- centred on their own spots and kept within [lo, hi]; clusters keep merging
-- until none overlap. Order is kept, so leaders fan out without crossing.
-- Sets each point's .shift (its offset from its own spot). The aura
-- timeline's spread, for a compass tape.
local function Settle(cluster, step, lo, hi)
	local span = (cluster.n - 1) * step
	local first = cluster.sum / cluster.n - span / 2
	if first + span > hi then first = hi - span end
	if first < lo then first = lo end
	cluster.first = first
end

function Nav.Spread(row, step, lo, hi)
	local clusters = {}
	for _, point in ipairs(row) do
		clusters[#clusters + 1] = {n = 1, sum = point.pos, members = {point}}
		while true do
			local count = #clusters
			local current, previous = clusters[count], clusters[count - 1]
			Settle(current, step, lo, hi)
			if not previous or previous.first + previous.n * step <= current.first then break end
			previous.n, previous.sum = previous.n + current.n, previous.sum + current.sum
			for _, member in ipairs(current.members) do previous.members[#previous.members + 1] = member end
			clusters[count] = nil
		end
	end
	for _, cluster in ipairs(clusters) do
		for j, point in ipairs(cluster.members) do point.shift = cluster.first + (j - 1) * step - point.pos end
	end
end

-- Maps -------------------------------------------------------------------------------------
local UIMAP = (Enum and Enum.UIMapType) or {}
local CONTINENT, ZONE = UIMAP.Continent or 2, UIMAP.Zone or 3

local function MapInfo(mapID)
	local info = C_Map and Plain(C_Map.GetMapInfo, mapID)
	if type(info) ~= 'table' then return nil end
	return Number(info.mapType), Number(info.parentMapID), Text(info.name)
end

local function WorldSize(mapID)
	local width, height = Plain2(C_Map.GetMapWorldSize, mapID)
	width, height = Number(width), Number(height)
	if width and height and width > 0 and height > 0 then return width, height end
end

local function PlayerOn(mapID)
	local x, y = XY(Plain(C_Map.GetPlayerMapPosition, mapID, 'player'))
	if x and (x ~= 0 or y ~= 0) then return x, y end
end

local function HasArt(mapID)
	local layers = Plain(C_Map.GetMapArtLayers, mapID)
	return type(layers) == 'table' and layers[1] ~= nil
end

-- From the map the game puts you on: the map to draw and measure on (the first
-- of it and its parents with art, a size in yards and your position), and the
-- city or zone above it (where learned services are kept).
local function ChooseMaps(best)
	local base, zone, name
	local id, depth = best, 0
	while id and id > 0 and depth < 8 do
		local mapType, parent, mapName = MapInfo(id)
		if depth == 0 then name = mapName end
		if not base and WorldSize(id) and HasArt(id) and PlayerOn(id) then base = id end
		if not zone and mapType == ZONE and WorldSize(id) and PlayerOn(id) then zone = id end
		if (base and zone) or not mapType or mapType <= CONTINENT then break end
		id, depth = parent, depth + 1
	end
	return base, zone or base, name
end
Nav.ChooseMaps = ChooseMaps

-- One map's rectangle on another that contains it (cached; maps don't move).
local rects = {}
local function Rect(inner, outer)
	local key = inner..':'..outer
	local rect = rects[key]
	if rect == nil then
		rect = false
		if C_Map and C_Map.GetMapRectOnMap then
			local ok, x0, x1, y0, y1 = pcall(C_Map.GetMapRectOnMap, inner, outer)
			x0, x1, y0, y1 = Number(x0), Number(x1), Number(y0), Number(y1)
			if ok and x0 and x1 and y0 and y1 and x1 > x0 and y1 > y0 then rect = {x0, x1, y0, y1} end
		end
		rects[key] = rect
	end
	return rect or nil
end

-- A point on one map, on another (a parent or a child of it); nil when the two
-- don't nest.
local function Translate(from, to, x, y)
	if from == to then return x, y end
	local rect = Rect(to, from)
	if rect then return (x - rect[1]) / (rect[2] - rect[1]), (y - rect[3]) / (rect[4] - rect[3]) end
	rect = Rect(from, to)
	if rect then return rect[1] + x * (rect[2] - rect[1]), rect[3] + y * (rect[4] - rect[3]) end
end
Nav.Translate = Translate

-- Where you are ---------------------------------------------------------------------
-- One reading per frame, shared by both devices. mapID is the map drawn and
-- measured on (x, y, wx, wy are on it); zoneID the city or zone above (zx, zy);
-- bestID the map the game names. Every field is plain or nil.
local here = {}
Nav.here = here
local history, HISTORY = {}, 0.6 -- recent positions, seconds kept
local listeners = {}
-- callback(what): 'map' when the map changed, 'pois' when the list was rebuilt.
function Nav:OnChange(callback) listeners[#listeners + 1] = callback end
local function Notify(what)
	for _, callback in ipairs(listeners) do UI:Safe(callback, what) end
end

local Dirty -- defined with the points
local MAP_EVERY, BASE_SPEED = 0.5, 7

local function MapChanged(best)
	here.bestID = best
	wipe(history)
	here.mapID, here.zoneID, here.bestName = nil, nil, nil
	here.worldW, here.worldH, here.zoneW, here.zoneH, here.artID = nil, nil, nil, nil, nil
	if best and C_Map then
		local base, zone, name = ChooseMaps(best)
		here.mapID, here.zoneID, here.bestName = base, zone, name
		if base then
			here.worldW, here.worldH = WorldSize(base)
			here.artID = Plain(C_Map.GetMapArtID, base)
		end
		if zone then here.zoneW, here.zoneH = WorldSize(zone) end
		for _, id in ipairs({best, base, zone}) do
			if id and C_QuestLine and C_QuestLine.RequestQuestLinesForMap then pcall(C_QuestLine.RequestQuestLinesForMap, id) end
		end
	end
	Notify('map')
	Dirty()
end

-- Speed in yards a second: skyriding's forward speed while gliding, else the
-- unit speed; nil when neither is plain.
local function Speed()
	local info = C_PlayerInfo and C_PlayerInfo.GetGlidingInfo
	if info then
		local ok, gliding, _, forward = pcall(info)
		if ok and True(gliding) and Number(forward) then return forward end
	end
	return Number(Plain(GetUnitSpeed, 'player'))
end

local function Move(now)
	local newest = history[#history]
	-- The oldest sample still within the window, at least 0.2 s back.
	local oldest
	for index = 1, #history - 1 do
		local sample = history[index]
		if now - sample.t <= HISTORY and newest.t - sample.t >= 0.2 then oldest = sample break end
	end
	here.moveDeg, here.moving = nil, false
	local speed = Speed()
	if oldest then
		local dx, dy = newest.wx - oldest.wx, newest.wy - oldest.wy
		local moved = sqrt(dx * dx + dy * dy)
		local dt = newest.t - oldest.t
		if not speed and dt > 0 then speed = moved / dt end
		if moved >= 0.3 then here.moveDeg = Bearing(dx, dy) end
	end
	here.speed = speed
	here.moving = (speed and speed > 0.1 and here.moveDeg) and true or false
	here.pace = speed and speed / BASE_SPEED * 100 or nil
end

function Nav:Sense(now)
	now = now or GetTime()
	if here.t == now then return here end
	here.t = now
	local facing = Number(Plain(GetPlayerFacing))
	here.facing = facing
	here.heading = facing and Heading(facing) or nil
	if not here.mapAt or now - here.mapAt >= MAP_EVERY then
		here.mapAt = now
		local best = C_Map and Number(Plain(C_Map.GetBestMapForUnit, 'player'))
		local artID = here.mapID and Plain(C_Map.GetMapArtID, here.mapID)
		-- Also again while no map could be used yet (a loading screen, a position not shared yet).
		if best ~= here.bestID or artID ~= here.artID or (best and not here.mapID) then MapChanged(best) end
	end
	local x, y
	if here.mapID and here.worldW then x, y = PlayerOn(here.mapID) end
	if x then
		here.x, here.y = x, y
		here.wx, here.wy = x * here.worldW, y * here.worldH
		if here.zoneID and here.zoneID ~= here.mapID then here.zx, here.zy = PlayerOn(here.zoneID)
		else here.zx, here.zy = x, y end
		-- Keep the window's samples, dropping the oldest beyond it.
		history[#history + 1] = {t = now, wx = here.wx, wy = here.wy}
		while #history > 2 and now - history[1].t > HISTORY + 0.1 do table.remove(history, 1) end
		Move(now)
	else
		here.x, here.y, here.wx, here.wy, here.zx, here.zy = nil, nil, nil, nil, nil, nil
		here.moving, here.moveDeg = false, nil
		here.speed = Speed()
		here.pace = here.speed and here.speed / BASE_SPEED * 100 or nil
		wipe(history)
	end
	return here
end

-- The place printed on the compass: the zone or city, the subzone or district
-- (or the building's map when the game names none), and its PvP state.
function Nav:Zone()
	local zone, sub = Text(Plain(GetZoneText)) or '', Text(Plain(GetSubZoneText)) or ''
	if sub == '' and here.bestName and here.bestName ~= zone and here.bestID ~= here.zoneID then sub = here.bestName end
	local pvp
	local get = (C_PvP and C_PvP.GetZonePVPInfo) or _G.GetZonePVPInfo
	if get then pvp = Text(Plain(get)) end
	return zone, sub, pvp
end

-- Points of interest ------------------------------------------------------------------
-- Glyphs in icons-nav.tga, in atlas order (tools/build-hardware-art.py draws them).
local NAV_ICONS = {'waypoint', 'quest', 'turnin', 'giver', 'world', 'rare', 'treasure', 'event',
	'dungeon', 'taxi', 'portal', 'inn', 'bank', 'mail', 'repair', 'auction',
	'vendor', 'trainer', 'profession', 'stable', 'barber', 'transmog', 'guildbank', 'poi',
	'link'}
local ICON_INDEX = {}
for index, name in ipairs(NAV_ICONS) do ICON_INDEX[name] = index - 1 end
function Nav.IconCoords(name)
	local index = ICON_INDEX[name]
	if not index then return nil end
	local column, row = index % 8, floor(index / 8)
	return column / 8, (column + 1) / 8, row / 4, (row + 1) / 4
end
Nav.ICON_FILE = Kit.media..'icons-nav.tga'

-- kind -> how it is drawn: its glyph (and a letter where the atlas has none),
-- a lamp color, the game's own art for the "game icons" look (an atlas, else a
-- file every client has: the minimap tracking and gossip icons), a rank (lower
-- wins a place on a crowded tape), and the setting that shows a service.
local KINDS = {
	waypoint = {icon = 'waypoint', glyph = '+', token = 'lamp', rank = 1, atlas = 'Waypoint-MapPin-Tracked'},
	turnin = {icon = 'turnin', glyph = '?', token = 'amber', rank = 2, atlas = 'QuestTurnin', file = 'Interface\\GossipFrame\\ActiveQuestIcon'},
	quest = {icon = 'quest', glyph = 'Q', token = 'amber', rank = 3, atlas = 'QuestNormal', file = 'Interface\\GossipFrame\\AvailableQuestIcon'},
	world = {icon = 'world', glyph = 'W', token = 'blue', rank = 4, atlas = 'worldquest-icon'},
	giver = {icon = 'giver', glyph = '!', token = 'amber', rank = 5, atlas = 'QuestNormal', file = 'Interface\\GossipFrame\\AvailableQuestIcon'},
	rare = {icon = 'rare', glyph = '*', token = 'red', rank = 6, atlas = 'VignetteKill'},
	treasure = {icon = 'treasure', glyph = 'T', token = 'amber', rank = 7, atlas = 'VignetteLoot'},
	event = {icon = 'event', glyph = 'E', token = 'blue', rank = 7, atlas = 'VignetteEvent'},
	dungeon = {icon = 'dungeon', glyph = 'D', token = 'red', rank = 8, atlas = 'Dungeon'},
	taxi = {icon = 'taxi', glyph = 'F', token = 'green', rank = 9, atlas = 'TaxiNode_Neutral', file = 'Interface\\Minimap\\Tracking\\FlightMaster'},
	portal = {icon = 'portal', glyph = 'P', token = 'green', rank = 9, atlas = 'MagePortalAlliance'},
	inn = {icon = 'inn', glyph = 'I', token = 'ink', rank = 10, setting = 'svcInn', file = 'Interface\\Minimap\\Tracking\\Innkeeper'},
	bank = {icon = 'bank', glyph = 'B', token = 'ink', rank = 10, setting = 'svcBank', file = 'Interface\\Minimap\\Tracking\\Banker'},
	guildbank = {icon = 'guildbank', glyph = 'G', token = 'ink', rank = 11, setting = 'svcBank', file = 'Interface\\Minimap\\Tracking\\Banker'},
	mail = {icon = 'mail', glyph = 'M', token = 'ink', rank = 10, setting = 'svcMail', file = 'Interface\\Minimap\\Tracking\\Mailbox'},
	repair = {icon = 'repair', glyph = 'R', token = 'ink', rank = 10, setting = 'svcRepair', file = 'Interface\\Minimap\\Tracking\\Repair'},
	auction = {icon = 'auction', glyph = 'A', token = 'ink', rank = 10, setting = 'svcAuction', file = 'Interface\\Minimap\\Tracking\\Auctioneer'},
	vendor = {icon = 'vendor', glyph = 'V', token = 'ink', rank = 11, setting = 'svcVendor', file = 'Interface\\Minimap\\Tracking\\Food'},
	trainer = {icon = 'trainer', glyph = 'TR', token = 'ink', rank = 11, setting = 'svcTrainer', file = 'Interface\\Minimap\\Tracking\\Class'},
	profession = {icon = 'profession', glyph = 'PR', token = 'ink', rank = 11, setting = 'svcTrainer', file = 'Interface\\Minimap\\Tracking\\Profession'},
	stable = {icon = 'stable', glyph = 'S', token = 'ink', rank = 11, setting = 'svcStable', file = 'Interface\\Minimap\\Tracking\\StableMaster'},
	transmog = {icon = 'transmog', glyph = 'X', token = 'ink', rank = 11, setting = 'svcTransmog', atlas = 'poi-transmogrifier'},
	barber = {icon = 'barber', glyph = 'BB', token = 'ink', rank = 11, setting = 'svcBarber', atlas = 'Barbershop-32x32'},
	poi = {icon = 'poi', glyph = 'i', token = 'dim', rank = 12, atlas = 'PlayerPartyBlip'},
	link = {icon = 'link', glyph = '>', token = 'dim', rank = 13},
}
Nav.KINDS = KINDS

local function ServiceOn(kind)
	local setting = KINDS[kind] and KINDS[kind].setting
	if not setting then return true end
	local db = DB()
	return db.services and db[setting] and true or false
end

-- Town services and other area POIs, told apart by the art the map gives
-- them (atlas names are the same in every language; names are not).
local ART = {
	{'innkeep', 'inn'}, {'guildbank', 'guildbank'}, {'guild%-bank', 'guildbank'}, {'bank', 'bank'}, {'mail', 'mail'},
	{'repair', 'repair'}, {'auction', 'auction'}, {'transmog', 'transmog'}, {'barber', 'barber'}, {'stable', 'stable'},
	{'portal', 'portal'}, {'teleport', 'portal'}, {'vendor', 'vendor'}, {'merchant', 'vendor'}, {'profession', 'profession'},
	{'crafting', 'profession'}, {'trainer', 'trainer'}, {'flightmaster', 'taxi'}, {'taxinode', 'taxi'}, {'dungeon', 'dungeon'},
	{'raid', 'dungeon'}, {'delve', 'dungeon'}, {'^inn', 'inn'},
}
local function KindOfArt(atlas, fallback)
	atlas = Text(atlas)
	if not atlas then return fallback end
	local lower = atlas:lower()
	for _, entry in ipairs(ART) do
		if lower:find(entry[1]) then return entry[2] end
	end
	return fallback
end

local pois = {}
Nav.pois = pois
Nav.version = 0
local consumers = {}
local stale, pending = true, false
local source -- the map the points being gathered are on
local taken = {} -- uids gathered this rebuild

local function Wanted() return next(consumers) ~= nil end

-- A device being shown asks for points; while none is, rebuilding waits.
function Nav:Want(owner, on)
	consumers[owner] = on and true or nil
	if on and stale then Dirty() end
end

-- A point from the map being gathered, carried onto the drawn map.
local function Add(kind, x, y, uid, extra)
	x, y = Number(x), Number(y)
	if not (x and y) or (x == 0 and y == 0) or taken[uid] then return end
	if source ~= here.mapID then
		x, y = Translate(source, here.mapID, x, y)
		if not x then return end
	end
	taken[uid] = true
	local poi = extra or {}
	poi.kind, poi.x, poi.y, poi.uid = kind, x, y, uid
	pois[#pois + 1] = poi
	return poi
end

local function GatherQuests(mapID, db, superQuest)
	if db.quests ~= 'off' and C_QuestLog and C_QuestLog.GetQuestsOnMap then
		for _, info in ipairs(Plain(C_QuestLog.GetQuestsOnMap, mapID) or {}) do
			local questID = type(info) == 'table' and Number(info.questID)
			if questID then
				local tracked = db.quests == 'all' or questID == superQuest
					or (C_QuestLog.GetQuestWatchType and Plain(C_QuestLog.GetQuestWatchType, questID) ~= nil)
				if tracked then
					local ready = C_QuestLog.ReadyForTurnIn and Plain(C_QuestLog.ReadyForTurnIn, questID)
					Add(ready and 'turnin' or 'quest', info.x, info.y, 'q'..questID, {id = questID, super = questID == superQuest})
				end
			end
		end
	end
	if db.worldQuests and C_TaskQuest and C_TaskQuest.GetQuestsOnMap then
		for _, info in ipairs(Plain(C_TaskQuest.GetQuestsOnMap, mapID) or {}) do
			local questID = type(info) == 'table' and Number(info.questID)
			-- Task POIs for this map only (the list also carries child maps').
			local onMap = type(info) == 'table' and (Number(info.mapID) == nil or Number(info.mapID) == mapID)
			if questID and onMap then Add('world', info.x, info.y, 'w'..questID, {id = questID, super = questID == superQuest}) end
		end
	end
	if db.questGivers and C_QuestLine and C_QuestLine.GetAvailableQuestLines then
		for _, info in ipairs(Plain(C_QuestLine.GetAvailableQuestLines, mapID) or {}) do
			local questID = type(info) == 'table' and Number(info.questID)
			if questID and not True(info.isHidden) then Add('giver', info.x, info.y, 'g'..questID, {id = questID}) end
		end
	end
end

local function FactionAllows(faction)
	faction = Number(faction)
	local enum = Enum and Enum.FlightPathFaction
	if not faction or not enum or faction == enum.Neutral then return true end
	local mine = Text(Plain(UnitFactionGroup, 'player'))
	if faction == enum.Horde then return mine ~= 'Alliance' end
	if faction == enum.Alliance then return mine ~= 'Horde' end
	return true
end

local SERVICE_KINDS = {}
for kind, info in pairs(KINDS) do if info.setting then SERVICE_KINDS[kind] = true end end

local function GatherMap(mapID, db)
	if db.flightMasters and C_TaxiMap and C_TaxiMap.GetTaxiNodesForMap then
		for _, node in ipairs(Plain(C_TaxiMap.GetTaxiNodesForMap, mapID) or {}) do
			local nodeID = type(node) == 'table' and Number(node.nodeID)
			if nodeID and FactionAllows(node.faction) then
				local x, y = XY(node.position)
				Add('taxi', x, y, 't'..nodeID, {id = nodeID, atlas = Text(node.atlasName)})
			end
		end
	end
	if (db.services or db.areaPois or db.dungeons) and C_AreaPoiInfo and C_AreaPoiInfo.GetAreaPOIForMap then
		local seen = {}
		local lists = {Plain(C_AreaPoiInfo.GetAreaPOIForMap, mapID)}
		for _, name in ipairs({'GetEventsForMap', 'GetQuestHubsForMap', 'GetDelvesForMap'}) do
			if C_AreaPoiInfo[name] then lists[#lists + 1] = Plain(C_AreaPoiInfo[name], mapID) end
		end
		for _, list in ipairs(lists) do
			for _, id in ipairs(type(list) == 'table' and list or {}) do
				id = Number(id)
				if id and not seen[id] then
					seen[id] = true
					local info = Plain(C_AreaPoiInfo.GetAreaPOIInfo, mapID, id)
					if type(info) == 'table' then
						local kind = KindOfArt(info.atlasName, 'poi')
						local wanted
						if SERVICE_KINDS[kind] then wanted = ServiceOn(kind)
						elseif kind == 'dungeon' then wanted = db.dungeons
						-- Flight masters come from the taxi list, and only once.
						elseif kind == 'taxi' then wanted = not db.flightMasters and db.areaPois
						else wanted = db.areaPois end
						if wanted then
							local x, y = XY(info.position)
							Add(kind, x, y, 'a'..id, {id = id, atlas = Text(info.atlasName)})
						end
					end
				end
			end
		end
	end
	if db.dungeons and C_EncounterJournal and C_EncounterJournal.GetDungeonEntrancesForMap then
		for _, entrance in ipairs(Plain(C_EncounterJournal.GetDungeonEntrancesForMap, mapID) or {}) do
			local id = type(entrance) == 'table' and Number(entrance.areaPoiID)
			if id then
				local x, y = XY(entrance.position)
				Add('dungeon', x, y, 'd'..id, {id = id, atlas = Text(entrance.atlasName)})
			end
		end
	end
	if db.mapLinks and C_Map.GetMapLinksForMap then
		for _, link in ipairs(Plain(C_Map.GetMapLinksForMap, mapID) or {}) do
			if type(link) == 'table' then
				local x, y = XY(link.position)
				local linked = Number(link.linkedUiMapID) or 0
				Add('link', x, y, 'l'..mapID..':'..linked, {atlas = Text(link.atlasName)})
			end
		end
	end
end

-- Vignettes move (a patrolling rare), so their spots are read again each second.
local function VignetteKind(info)
	local atlas = Text(info.atlasName)
	local lower = atlas and atlas:lower() or ''
	if lower:find('loot') or lower:find('treasure') then return 'treasure' end
	if lower:find('event') then return 'event' end
	return 'rare'
end

local function GatherVignettes(mapID, superVignette)
	if not (C_VignetteInfo and C_VignetteInfo.GetVignettes) then return end
	for _, guid in ipairs(Plain(C_VignetteInfo.GetVignettes) or {}) do
		if not IsSecret(guid) then
			local info = Plain(C_VignetteInfo.GetVignetteInfo, guid)
			if type(info) == 'table' and not IsSecret(info.isDead) and not info.isDead
				and (True(info.onMinimap) or True(info.onWorldMap)) then
				local x, y = XY(Plain(C_VignetteInfo.GetVignettePosition, guid, mapID))
				Add(VignetteKind(info), x, y, 'v'..tostring(guid), {guid = guid, vignette = true,
					atlas = Text(info.atlasName), super = guid == superVignette})
			end
		end
	end
end

local function GatherWaypoints(mapID, superQuest)
	local track = C_SuperTrack
	if superQuest and C_QuestLog and C_QuestLog.GetNextWaypointForMap then
		-- The game's own route to the quest (a portal, a cave mouth) on this map.
		local x, y = Plain2(C_QuestLog.GetNextWaypointForMap, superQuest, mapID)
		if Number(x) and Number(y) then Add('waypoint', x, y, 'route', {super = true, route = true}) end
	end
	if C_Map.HasUserWaypoint and Plain(C_Map.HasUserWaypoint) and C_Map.GetUserWaypointPositionForMap then
		local x, y = XY(Plain(C_Map.GetUserWaypointPositionForMap, mapID))
		local tracked = track and track.IsSuperTrackingUserWaypoint and Plain(track.IsSuperTrackingUserWaypoint)
		Add('waypoint', x, y, 'pin', {super = tracked and true or false})
	end
end

-- A super-tracked map pin (an area POI, a quest offer, a flight master).
local function MarkPin()
	local track = C_SuperTrack
	if not (track and track.GetSuperTrackedMapPin) then return end
	local pinType, pinID = Plain2(track.GetSuperTrackedMapPin)
	local types = Enum and Enum.SuperTrackingMapPinType
	pinType, pinID = Number(pinType), Number(pinID)
	if not (pinType and pinID and types) then return end
	local prefix = (pinType == types.AreaPOI and 'a') or (pinType == types.QuestOffer and 'g')
		or (pinType == types.TaxiNode and 't') or nil
	for _, poi in ipairs(pois) do
		if prefix and poi.uid == prefix..pinID then poi.super = true end
	end
end

-- Learned services ------------------------------------------------------------------------
-- Kept for the whole account (UI:Account), per city or zone map:
-- {[zoneMapID] = {{k = kind, x, y (on that map), c = 2 used it here | 1 an NPC
-- with its title was within ten yards | 0 used it with nobody to talk to
-- (a mailbox, a barber's chair: shown once seen twice), n = name, s = title,
-- seen = times, t = time}}}.
local function Learned() return UI:Account('services') end

-- Trainers learned from a title alone can't tell class from profession; the
-- interaction can, and replaces them.
local function Family(kind) return kind == 'profession' and 'trainer' or kind end

local function Shows(entry) return entry.c >= 1 or (entry.seen or 1) >= 2 end

local function GatherLearned()
	local zone = here.zoneID
	if not (zone and DB().services) then return end
	local list = Learned()[zone]
	if type(list) ~= 'table' then return end
	source = zone
	for index, entry in ipairs(list) do
		if type(entry) == 'table' and KINDS[entry.k] and Shows(entry) and ServiceOn(entry.k) then
			Add(entry.k, entry.x, entry.y, 's'..zone..':'..index, {learned = true, approx = entry.c < 2, name = entry.n, title = entry.s})
		end
	end
end

local function Rebuild()
	pending = false
	if not Wanted() then stale = true return end
	stale = false
	wipe(pois)
	wipe(taken)
	local base = here.mapID
	if base and here.worldW and C_Map then
		local db = DB()
		local track = C_SuperTrack
		local superQuest = track and track.GetSuperTrackedQuestID and Number(Plain(track.GetSuperTrackedQuestID))
		if superQuest == 0 then superQuest = nil end
		local superVignette = track and track.GetSuperTrackedVignette and Plain(track.GetSuperTrackedVignette)
		-- The drawn map first, then the map you are on and the city or zone above:
		-- a building's quests and a city's services and entrances both show.
		local done = {}
		for _, mapID in ipairs({base, here.bestID, here.zoneID}) do
			if mapID and not done[mapID] then
				done[mapID] = true
				source = mapID
				UI:Safe(GatherQuests, mapID, db, superQuest)
				UI:Safe(GatherMap, mapID, db)
				if db.waypoint then UI:Safe(GatherWaypoints, mapID, superQuest) end
			end
		end
		source = base
		if db.vignettes then UI:Safe(GatherVignettes, base, superVignette) end
		UI:Safe(GatherLearned)
		UI:Safe(MarkPin)
	end
	Nav.version = Nav.version + 1
	Notify('pois')
end

-- Many events come in bursts (the quest log): one rebuild a quarter second after.
function Dirty()
	if pending then return end
	pending = true
	C_Timer.After(0.25, function() UI:Safe(Rebuild) end)
end
Nav.Dirty = function() Dirty() end

local vignetteAt = 0
function Nav:Tick(now)
	if now - vignetteAt < 1 or not here.mapID then return end
	vignetteAt = now
	for _, poi in ipairs(pois) do
		if poi.vignette then
			local x, y = XY(Plain(C_VignetteInfo.GetVignettePosition, poi.guid, here.mapID))
			if x then poi.x, poi.y = x, y end
		end
	end
end

-- A point measured from you: distance in yards, and its compass bearing.
function Nav:Measure(poi)
	if not (here.wx and here.worldW) then return nil end
	local east, south = poi.x * here.worldW - here.wx, poi.y * here.worldH - here.wy
	return sqrt(east * east + south * south), Bearing(east, south), east, south
end

-- The points within `range` yards, measured, nearest-and-most-important first.
-- Fills `out` (reused) with {poi, distance, bearing, east, south}.
function Nav:Near(range, out, limit)
	out = out or {}
	local count = 0
	for _, poi in ipairs(pois) do
		local distance, bearing, east, south = self:Measure(poi)
		if distance and (distance <= range or poi.super) then
			count = count + 1
			local entry = out[count] or {}
			entry.poi, entry.distance, entry.bearing, entry.east, entry.south = poi, distance, bearing, east, south
			entry.rank = poi.super and 0 or (KINDS[poi.kind] and KINDS[poi.kind].rank or 20)
			entry.pinOK = nil
			out[count] = entry
		end
	end
	for index = count + 1, #out do out[index] = nil end
	table.sort(out, function(a, b)
		if a.rank ~= b.rank then return a.rank < b.rank end
		return a.distance < b.distance
	end)
	if limit then for index = limit + 1, #out do out[index] = nil end end
	return out
end

-- The nearest point of a kind (or its family: trainers), at any distance.
-- Fills `out` (reused): {poi, distance, bearing, east, south}, or returns nil.
function Nav:Nearest(kind, out)
	local best, bestDistance
	for _, poi in ipairs(pois) do
		if Family(poi.kind) == Family(kind) then
			local distance = self:Measure(poi)
			if distance and (not bestDistance or distance < bestDistance) then best, bestDistance = poi, distance end
		end
	end
	if not best then return nil end
	out = out or {}
	out.poi = best
	out.distance, out.bearing, out.east, out.south = self:Measure(best)
	return out
end

-- Learning ----------------------------------------------------------------------------------
local MERGE, MERGE_NEAR = 8, 12 -- yards: the same service seen again

function Nav:Learn(kind, confidence, name, title)
	if not (KINDS[kind] and DB().learn) or InCombatLockdown() then return end
	self:Sense(GetTime())
	local zone, x, y, width, height = here.zoneID, here.zx, here.zy, here.zoneW, here.zoneH
	if not (zone and x and width) then return end
	local store = Learned()
	local list = store[zone]
	if type(list) ~= 'table' then list = {}; store[zone] = list end
	local now = time()
	for _, entry in ipairs(list) do
		if type(entry) == 'table' and Family(entry.k) == Family(kind) then
			local dx, dy = (entry.x - x) * width, (entry.y - y) * height
			local reach = (confidence < 2 or entry.c < 2) and MERGE_NEAR or MERGE
			if dx * dx + dy * dy <= reach * reach then
				if confidence >= entry.c then
					entry.x, entry.y, entry.c = x, y, confidence
					if confidence == 2 or entry.k == 'trainer' then entry.k = kind end
				end
				entry.n, entry.s = name or entry.n, title or entry.s
				entry.seen, entry.t = (entry.seen or 1) + 1, now
				Dirty()
				return entry
			end
		end
	end
	local entry = {k = kind, x = floor(x * 1e5 + 0.5) / 1e5, y = floor(y * 1e5 + 0.5) / 1e5, c = confidence, n = name, s = title,
		seen = 1, t = now}
	list[#list + 1] = entry
	Dirty()
	return entry
end

function Nav:ForgetLearned()
	local store, count = Learned(), 0
	for _, list in pairs(store) do if type(list) == 'table' then count = count + #list end end
	wipe(store)
	Dirty()
	return count
end

function Nav:LearnedCount()
	local count = 0
	for _, list in pairs(Learned()) do if type(list) == 'table' then count = count + #list end end
	return count
end

-- An NPC's title, the "<Innkeeper>" line under its name, when the game shares
-- it plainly.
local function Title(unit)
	if not (C_TooltipInfo and C_TooltipInfo.GetUnit) then return nil end
	local data = Plain(C_TooltipInfo.GetUnit, unit)
	if type(data) ~= 'table' then return nil end
	local lines = data.lines
	if IsSecret(lines) or type(lines) ~= 'table' then return nil end
	for index = 2, 4 do
		local line = lines[index]
		local text = type(line) == 'table' and Text(line.leftText)
		local inner = text and text:match('^<(.+)>$')
		if inner then return inner end
	end
end

local function NpcName(unit) return Text(Plain(UnitName, unit)) end

-- Titles that name a service. The game's own localized names for minimap
-- tracking come first (C_Minimap: "Innkeeper", "Banker", "Auctioneer" in your
-- language); English words fill in for titles those don't cover ("Warrior
-- Trainer", "General Goods"), so in other languages those few aren't read.
local FILTER_KINDS = {Auctioneer = 'auction', Banker = 'bank', AccountBanker = 'bank', Innkeeper = 'inn', Stablemaster = 'stable',
	Transmogrifier = 'transmog', Barber = 'barber', TrainerClass = 'trainer', TrainerProfession = 'trainer',
	VenderFood = 'vendor', VendorReagent = 'vendor', VendorPoison = 'vendor', VendorAmmo = 'vendor'}
local ENGLISH = {{'innkeeper', 'inn'}, {'banker', 'bank'}, {'guild bank', 'guildbank'}, {'auctioneer', 'auction'},
	{'stable master', 'stable'}, {'transmogrifier', 'transmog'}, {'barber', 'barber'}, {'trainer', 'trainer'},
	{'repair', 'repair'}, {'general goods', 'vendor'}, {'food & drink', 'vendor'}, {'trade supplies', 'vendor'},
	{'reagents', 'vendor'}}
local words

local function Words()
	if words then return words end
	words = {}
	local filters = Enum and Enum.MinimapTrackingFilter
	local count = C_Minimap and Number(Plain(C_Minimap.GetNumTrackingTypes)) or 0
	if filters and C_Minimap.GetTrackingFilter and C_Minimap.GetTrackingInfo then
		local byValue = {}
		for name, value in pairs(filters) do if FILTER_KINDS[name] then byValue[value] = FILTER_KINDS[name] end end
		for index = 1, count do
			local filter = Plain(C_Minimap.GetTrackingFilter, index)
			local info = Plain(C_Minimap.GetTrackingInfo, index)
			local kind = type(filter) == 'table' and byValue[Number(filter.filterID) or -1]
			local name = type(info) == 'table' and Text(info.name)
			-- "Class Trainer" and the like never appear in a title as such.
			if kind and name and kind ~= 'trainer' and kind ~= 'vendor' then words[#words + 1] = {name:lower(), kind} end
		end
	end
	for _, entry in ipairs(ENGLISH) do words[#words + 1] = entry end
	return words
end

local function KindOfTitle(title)
	if not title then return nil end
	local lower = title:lower()
	for _, entry in ipairs(Words()) do
		if lower:find(entry[1], 1, true) then return entry[2] end
	end
end

-- You are using a service: you stand within reach of it. With nobody to talk
-- to (a mailbox, a barber's chair, a toy that summons a mailbox) the spot waits
-- for a second visit before it shows, unless you are in a town (resting).
local function Used(kind)
	local hasNpc = Plain(UnitExists, 'npc')
	local name, title
	if hasNpc then name, title = NpcName('npc'), Title('npc') end
	local confidence = 2
	if not hasNpc and not Plain(IsResting) then confidence = 0 end
	-- Riding a mount with vendors on it is no place to learn.
	if Plain(IsMounted) then return end
	Nav:Learn(kind, confidence, name, title)
end

local function TrainerKind()
	local trainer = C_Trainer and C_Trainer.GetTrainerType
	local types = Enum and Enum.TrainerType
	if trainer and types then
		local value = Number(Plain(trainer))
		if value then return value == types.Tradeskills and 'profession' or 'trainer' end
	end
	if Plain(_G.IsTradeskillTrainer) then return 'profession' end
	return 'trainer'
end

-- PLAYER_INTERACTION_MANAGER_FRAME_SHOW types, by name (their numbers differ
-- between clients).
local INTERACTIONS = {Banker = 'bank', CharacterBanker = 'bank', AccountBanker = 'bank', GuildBanker = 'guildbank',
	MailInfo = 'mail', Binder = 'inn', Auctioneer = 'auction', StableMaster = 'stable', Transmogrifier = 'transmog'}
local LEARN_EVENTS = {BANKFRAME_OPENED = 'bank', MAIL_SHOW = 'mail', AUCTION_HOUSE_SHOW = 'auction', PET_STABLE_SHOW = 'stable',
	BARBER_SHOP_OPEN = 'barber', TRANSMOGRIFY_OPEN = 'transmog', GUILDBANKFRAME_OPENED = 'guildbank', CONFIRM_BINDER = 'inn'}

local function OnInteraction(event, arg)
	if not DB().learn then return end
	if event == 'MERCHANT_SHOW' then
		return Used(Plain(_G.CanMerchantRepair) and 'repair' or 'vendor')
	elseif event == 'TRAINER_SHOW' then
		return Used(TrainerKind())
	elseif event == 'GOSSIP_SHOW' then
		local kind = KindOfTitle(Title('npc'))
		if kind then return Used(kind) end
	elseif event == 'PLAYER_INTERACTION_MANAGER_FRAME_SHOW' then
		local types = Enum and Enum.PlayerInteractionType
		arg = Number(arg)
		if types and arg then
			for name, kind in pairs(INTERACTIONS) do
				if types[name] == arg then return Used(kind) end
			end
		end
	elseif LEARN_EVENTS[event] then
		return Used(LEARN_EVENTS[event])
	end
end

-- Near a service: a friendly NPC (under the mouse, or with its nameplate
-- shown) whose title names one, within ten yards (the duel distance).
local candidates = {} -- unit -> kind
local ticker

local function Close(unit)
	if InCombatLockdown() or not CheckInteractDistance then return false end
	return True(Plain(CheckInteractDistance, unit, 3))
end

local function Candidate(unit)
	if not (DB().learn and DB().learnNear) or InCombatLockdown() then return nil end
	if not Plain(UnitExists, unit) or Plain(UnitIsPlayer, unit) ~= false then return nil end
	if Plain(UnitCanAttack, 'player', unit) ~= false then return nil end
	return KindOfTitle(Title(unit))
end

local function CheckCandidates()
	if InCombatLockdown() then return end
	for unit, kind in pairs(candidates) do
		if Close(unit) then
			Nav:Learn(kind, 1, NpcName(unit), Title(unit))
			candidates[unit] = nil
		end
	end
	if not next(candidates) and ticker then ticker:Cancel(); ticker = nil end
end

local function Watch(unit, kind)
	candidates[unit] = kind
	if not ticker and C_Timer.NewTicker then ticker = C_Timer.NewTicker(1, function() UI:Safe(CheckCandidates) end) end
end

local function OnNearby(event, unit)
	if event == 'NAME_PLATE_UNIT_REMOVED' then candidates[unit] = nil return end
	if event == 'UPDATE_MOUSEOVER_UNIT' then unit = 'mouseover' end
	if type(unit) ~= 'string' then return end
	local kind = Candidate(unit)
	if not kind then return end
	if Close(unit) then Nav:Learn(kind, 1, NpcName(unit), Title(unit))
	elseif unit ~= 'mouseover' then Watch(unit, kind) end
end

-- Keys ----------------------------------------------------------------------------------------
-- A small key for a point: a housing with a printed glyph (or the game's own
-- icon), a lamp in its kind's color, a glow when it is your target. Shared by
-- both devices.
function Nav:MakeKey(parent)
	local key = CreateFrame('Frame', nil, parent)
	key:EnableMouse(false)
	key.glow = Kit:Texture(key, 'glow', 'BACKGROUND', -2)
	key.glow:SetPoint('TOPLEFT', -7, 7)
	key.glow:SetPoint('BOTTOMRIGHT', 7, -7)
	key.glow:SetBlendMode('ADD')
	key.glow:Hide()
	key.face = CreateFrame('Frame', nil, key)
	key.face:SetAllPoints()
	key.face:SetFrameLevel(key:GetFrameLevel() + 1)
	key.face.shell = Kit:Shell(key.face, {surface = 'paper', radius = 3, shadowAlpha = 0.3})
	key.glyph = Kit:Text(key.face, '', 8, 'ink', true)
	key.glyph:SetPoint('CENTER', 0, 0)
	key.icon = key.face:CreateTexture(nil, 'ARTWORK', nil, 1)
	key.icon:SetTexture(Nav.ICON_FILE)
	key.icon:SetPoint('CENTER')
	key.art = key.face:CreateTexture(nil, 'ARTWORK')
	key.art:SetPoint('TOPLEFT', 2, -2)
	key.art:SetPoint('BOTTOMRIGHT', -2, 2)
	key.art:Hide()
	key.lamp = Kit:Led(key.face, 3, true)
	key.lamp:SetPoint('TOPRIGHT', -2, -2)
	return key
end

-- The game's own picture for a point: the map's atlas, the kind's atlas, or the
-- kind's file. An atlas the client doesn't have is skipped.
local function HasAtlas(atlas)
	if not atlas then return false end
	if C_Texture and C_Texture.GetAtlasInfo then return C_Texture.GetAtlasInfo(atlas) ~= nil end
	return true
end
local function GameArt(poi, kind)
	if HasAtlas(poi.atlas) then return 'atlas', poi.atlas end
	if HasAtlas(kind.atlas) then return 'atlas', kind.atlas end
	if kind.file then return 'file', kind.file end
end

-- Dress a key for a point. size: its side in UI units; art: the game's icons,
-- drawn bare over the world (no keycap or lamp, a soft shade behind for
-- contrast); a point with no game icon keeps its printed keycap.
function Nav:DressKey(key, poi, size, art)
	local kind = KINDS[poi.kind] or KINDS.poi
	key:SetSize(size, size)
	local how, value
	if art then how, value = GameArt(poi, kind) end
	local bare = how ~= nil
	if bare and key.artValue ~= value then
		key.artValue = value
		key.art:SetTexCoord(0, 1, 0, 1)
		if how == 'atlas' then key.hasArt = pcall(key.art.SetAtlas, key.art, value) and true or false
		else key.hasArt = pcall(key.art.SetTexture, key.art, value) and true or false end
	end
	bare = bare and key.hasArt and true or false
	key.face.shell:SetShown(not bare)
	key.art:ClearAllPoints()
	if bare then
		local outset = floor(size * 0.12 + 0.5)
		key.art:SetPoint('TOPLEFT', -outset, outset)
		key.art:SetPoint('BOTTOMRIGHT', outset, -outset)
	else
		key.art:SetPoint('TOPLEFT', 2, -2)
		key.art:SetPoint('BOTTOMRIGHT', -2, 2)
	end
	key.art:SetShown(bare)
	if not key.shade then
		key.shade = Kit:Texture(key, 'glow', 'BACKGROUND', -3)
		key.shade:SetPoint('TOPLEFT', -4, 4)
		key.shade:SetPoint('BOTTOMRIGHT', 4, -4)
		key.shade:SetVertexColor(0, 0, 0)
	end
	key.shade:SetAlpha(bare and 0.55 or 0)
	local l, r, t, b
	if not bare and kind.icon then l, r, t, b = Nav.IconCoords(kind.icon) end
	key.icon:SetShown(l ~= nil)
	key.glyph:SetShown(not bare and l == nil)
	local ink = kind.token == 'dim' and 'dim' or 'ink'
	if l then
		local side = floor(size * 0.72 + 0.5)
		key.icon:SetSize(side, side)
		key.icon:SetTexCoord(l, r, t, b)
		Kit:Tint(key.icon, ink)
	elseif not bare then
		key.glyph:SetText(kind.glyph)
		Kit:Font(key.glyph, max(6, floor(size * (#kind.glyph > 1 and 0.4 or 0.52))), nil, true)
		Kit:Tint(key.glyph, ink)
	end
	-- A service learned only from a nearby title wears a dim lamp: within ten yards.
	local token = kind.token ~= 'ink' and kind.token ~= 'dim' and kind.token or nil
	if poi.approx then token = 'dim' end
	Kit:SetLed(key.lamp, true, token or 'ledOff')
	key.lamp:SetShown(token ~= nil and not bare)
	-- Bare, a point known only roughly is drawn fainter.
	key.art:SetAlpha(bare and poi.approx and 0.6 or 1)
	if poi.super then
		Kit:Tint(key.glow, 'lamp')
		key.glow:SetAlpha(0.55)
		key.glow:Show()
	else
		key.glow:Hide()
	end
end

-- A glyph inline in text: "|T...|t", tinted.
function Nav.InlineIcon(kindName, size, r, g, b)
	local kind = KINDS[kindName]
	local index = kind and kind.icon and ICON_INDEX[kind.icon]
	if not index then return '' end
	local column, row = index % 8, floor(index / 8)
	return format('|T%s:%d:%d:0:0:512:256:%d:%d:%d:%d:%d:%d:%d|t', Nav.ICON_FILE, size, size, column * 64, column * 64 + 64,
		row * 64, row * 64 + 64, floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5))
end

-- Events ------------------------------------------------------------------------------
local POI_EVENTS = {'ZONE_CHANGED', 'ZONE_CHANGED_INDOORS', 'ZONE_CHANGED_NEW_AREA', 'PLAYER_ENTERING_WORLD', 'NEW_WMO_CHUNK',
	'PLAYER_MAP_CHANGED', 'QUEST_LOG_UPDATE', 'QUEST_WATCH_LIST_CHANGED', 'QUEST_POI_UPDATE', 'QUESTLINE_UPDATE',
	'SUPER_TRACKING_CHANGED', 'USER_WAYPOINT_UPDATED', 'WAYPOINT_UPDATE', 'VIGNETTES_UPDATED', 'VIGNETTE_MINIMAP_UPDATED',
	'AREA_POIS_UPDATED', 'TAXIMAP_OPENED', 'TAXIMAP_CLOSED', 'TAXI_NODE_STATUS_CHANGED'}
local ZONE_EVENTS = {ZONE_CHANGED = true, ZONE_CHANGED_INDOORS = true, ZONE_CHANGED_NEW_AREA = true, PLAYER_ENTERING_WORLD = true,
	NEW_WMO_CHUNK = true, PLAYER_MAP_CHANGED = true}
local SERVICE_EVENTS = {'MERCHANT_SHOW', 'TRAINER_SHOW', 'GOSSIP_SHOW', 'PLAYER_INTERACTION_MANAGER_FRAME_SHOW'}
local NEARBY_EVENTS = {'UPDATE_MOUSEOVER_UNIT', 'NAME_PLATE_UNIT_ADDED', 'NAME_PLATE_UNIT_REMOVED'}

function module:Enable()
	local events = CreateFrame('Frame')
	for _, event in ipairs(POI_EVENTS) do pcall(events.RegisterEvent, events, event) end
	events:SetScript('OnEvent', function(_, event)
		if ZONE_EVENTS[event] then
			-- The map may have changed: read it again on the next frame.
			here.mapAt = nil
			Notify('zone')
		end
		Dirty()
	end)
	local learn = CreateFrame('Frame')
	for _, event in ipairs(SERVICE_EVENTS) do pcall(learn.RegisterEvent, learn, event) end
	for event in pairs(LEARN_EVENTS) do pcall(learn.RegisterEvent, learn, event) end
	for _, event in ipairs(NEARBY_EVENTS) do pcall(learn.RegisterEvent, learn, event) end
	learn:SetScript('OnEvent', function(_, event, arg)
		if event == 'UPDATE_MOUSEOVER_UNIT' or event == 'NAME_PLATE_UNIT_ADDED' or event == 'NAME_PLATE_UNIT_REMOVED' then
			UI:Safe(OnNearby, event, arg)
		else
			UI:Safe(OnInteraction, event, arg)
		end
	end)
end

function module:Refresh()
	-- A category may have been switched: build the list again.
	Dirty()
end

-- Commands -----------------------------------------------------------------------------
-- /spec map, the key binding and the hub's key all come here.
function UI:ToggleOverlayMap(show)
	local map = UI.modules.overlaymap
	if map and map.Toggle then return map:Toggle(show) end
end

-- Hub page ------------------------------------------------------------------------------
local Int = UI.Util.Int
local function Yd(value) return format('%d yd', value + 0.5) end
local function Pct(value) return format('%d%%', value * 100 + 0.5) end
local function Px(value) return format('%d px', value + 0.5) end
local function Deg(value) return format('%d°', value + 0.5) end
local function CompassOff() return not UI.db.compass.enable end
local function MapOff() return not UI.db.overlaymap.enable end
local function NoPois() return CompassOff() or not UI.db.compass.pois end
local function NoServices() return not DB().services end
local function NoLearning() return not DB().learn end

local function Forget()
	local count = Nav:ForgetLearned()
	Kit:Play('success')
	UI:Print(format('Forgot %d learned town services.', count))
end

UI:RegisterPage('navigation', {title = 'Navigation', order = 12.2, since = '0.5.2', cards = {
	{title = 'NV-3 compass', rows = {
		{'switch', 'Compass', 'compass.enable', 'A heading tape at the top of the screen: where you face and where you are moving, the zone, your coordinates, and the points of interest around you at their bearing.', since = '0.5.2'},
		{'segmented', 'Housing', 'compass.housing', items = {{'device', 'Device'}, {'glass', 'Glass'}, {'hairline', 'Hairline'}},
			disabled = CompassOff, since = '0.5.2', note = 'Device: a machined housing in the finish. Glass: a strip of dark glass. Hairline: just the tape over the world.'},
		{'slider', 'Width', 'compass.width', 300, 900, 10, nil, format = Int, disabled = CompassOff, since = '0.5.2'},
		{'slider', 'Field of view', 'compass.fov', 90, 360, 15, 'How many degrees the tape spans.', format = Deg, disabled = CompassOff, since = '0.5.2'},
		{'switch', 'Location', 'compass.location', 'Zone or city and the subzone or district, with a lamp for its PvP state.', disabled = CompassOff, since = '0.5.2'},
		{'switch', 'Coordinates', 'compass.coords', 'Your coordinates on the zone or city map, on an LCD.', disabled = CompassOff, since = '0.5.2'},
		{'switch', 'Heading', 'compass.heading', 'Your heading in degrees on an LCD over the caret.', disabled = CompassOff, since = '0.5.2'},
		{'switch', 'Movement', 'compass.motion', 'A second marker on the tape for the way you are actually moving (strafing, backing up, falling), and your speed.', disabled = CompassOff, since = '0.5.2'},
		{'segmented', 'Speed', 'compass.speedUnit', items = {{'yards', 'Yards/s'}, {'percent', 'Percent'}},
			disabled = function() return CompassOff() or not UI.db.compass.motion end, since = '0.5.2'},
		{'segmented', 'Nearest', 'compass.nearest', items = {{'alt', 'Alt'}, {'shift', 'Shift'}, {'ctrl', 'Ctrl'}, {'always', 'Always'},
			{'off', 'Off'}}, disabled = CompassOff, since = '0.5.2',
			note = 'Hold the key to see the nearest repair, inn and mailbox (with their distance and direction) in place of the zone name; they also wait at the tape\'s ends.'},
		{'button', 'Placement', 'Move frames', function() UI:ToggleHub(nil, false); UI:ToggleMovers() end, 'Drag the compass and the map anywhere.'},
	}},
	{title = 'Tape', rows = {
		{'segmented', 'Tick every', 'compass.tickStep', items = {{5, '5°'}, {10, '10°'}, {15, '15°'}}, disabled = CompassOff, since = '0.5.2'},
		{'slider', 'Minor height', 'compass.tickMinor', 1, 10, 1, nil, format = Px, disabled = CompassOff, since = '0.5.2'},
		{'slider', 'Major height', 'compass.tickMajor', 2, 14, 1, nil, format = Px, disabled = CompassOff, since = '0.5.2'},
		{'slider', 'Weight', 'compass.tickWeight', 1, 3, 1, nil, format = Px, disabled = CompassOff, since = '0.5.2'},
		{'segmented', 'Letters', 'compass.letters', items = {{'eight', 'N NE E'}, {'four', 'N E S W'}},
			disabled = CompassOff, since = '0.5.2'},
		{'switch', 'Degrees', 'compass.degrees', 'Small degree numbers at every 30°.', disabled = CompassOff, since = '0.5.2'},
		{'switch', 'Light north', 'compass.northLit', 'N printed in the key color.', disabled = CompassOff, since = '0.5.2'},
		{'switch', 'Lens', 'compass.lens', 'Ticks near the caret lift and light, as under SPEC-01\'s slider.', disabled = CompassOff, since = '0.5.2'},
		{'switch', 'Fade the ends', 'compass.edgeFade', nil, disabled = CompassOff, since = '0.5.2'},
	}},
	{title = 'Points on the tape', rows = {
		{'switch', 'Points of interest', 'compass.pois', 'Points within range ride the tape at their bearing, on small keys with their distance on a chip; keys that would overlap spread out with angled leaders.', disabled = CompassOff, since = '0.5.2'},
		{'slider', 'Range', 'compass.range', 50, 1500, 25, 'Your target is shown at any distance.', format = Yd, disabled = NoPois, since = '0.5.2'},
		{'slider', 'Most points', 'compass.maxPois', 2, 16, 1, nil, format = Int, disabled = NoPois, since = '0.5.2'},
		{'slider', 'Key size', 'compass.keySize', 12, 24, 1, nil, format = Int, disabled = NoPois, since = '0.5.2'},
		{'switch', 'Distances', 'compass.distances', 'Yards on a small LCD chip under each key (~ marks a spot learned from a nearby title: within ten yards).', disabled = NoPois, since = '0.5.2'},
		{'switch', 'Pin your target', 'compass.pinTarget', 'Your super-tracked quest or waypoint waits at the tape\'s end when it is behind you.', disabled = NoPois, since = '0.5.2'},
		{'segmented', 'Icons', 'compass.icons', items = {{'game', 'Game icons'}, {'glyph', 'SPEC-01'}}, disabled = NoPois, since = '0.6.4',
			note = 'Game icons: the game\'s own art, drawn bare over the world (! and ? for quests, the mailbox, anvil, coins, bed, flight master). SPEC-01: printed glyphs on small keycaps. Both the compass and the map use this.'},
	}},
	{title = 'NV-4 overlay map', rows = {
		{'switch', 'Overlay map', 'overlaymap.enable', 'A see-through map of the ground around you, like an action game\'s overlay. Show and hide it with /spec map, a key binding (Key Bindings, AddOns) or the key below.', since = '0.5.2'},
		{'button', 'Show or hide', 'Toggle map', function() UI:ToggleOverlayMap() end, 'Shows or hides the overlay map.'},
		{'segmented', 'Shape', 'overlaymap.shape', items = {{'square', 'Square'}, {'round', 'Round'}}, disabled = MapOff, since = '0.5.2'},
		{'slider', 'Size', 'overlaymap.size', 160, 600, 10, nil, format = Int, disabled = MapOff, since = '0.5.2'},
		{'slider', 'Zoom', 'overlaymap.radius', 100, 600, 10, 'How far the map reaches from you to its edge.', format = Yd, disabled = MapOff, since = '0.5.2'},
		{'slider', 'Map opacity', 'overlaymap.opacity', 0.1, 1, 0.05, nil, format = Pct, disabled = MapOff, since = '0.5.2'},
		{'slider', 'Glass', 'overlaymap.backdrop', 0, 0.9, 0.05, 'Dark glass behind the map, so it reads over bright ground.', format = Pct, disabled = MapOff, since = '0.5.2'},
		{'switch', 'Fade the edge', 'overlaymap.fade', nil, disabled = MapOff, since = '0.5.2'},
		{'segmented', 'Tone', 'overlaymap.tone', items = {{'mono', 'Muted'}, {'color', 'Map colors'}}, disabled = MapOff, since = '0.6.4',
			note = 'Muted: no color and a cool light, so the map reads as a projection over the world. Map colors: the map as the game draws it.'},
		{'segmented', 'Frame', 'overlaymap.housing', items = {{'bezel', 'Bezel'}, {'hairline', 'Hairline'}, {'none', 'None'}},
			disabled = MapOff, since = '0.5.2'},
		{'switch', 'Turn with you', 'overlaymap.rotate', 'The map turns so the way you face is up; a lit N rides the edge. Off: north is always up and the arrow turns.', disabled = MapOff, since = '0.5.2'},
	}},
	{title = 'On the map', rows = {
		{'switch', 'Points of interest', 'overlaymap.pois', nil, disabled = MapOff, since = '0.5.2'},
		{'slider', 'Key size', 'overlaymap.keySize', 10, 22, 1, nil, format = Int, disabled = MapOff, since = '0.5.2'},
		{'switch', 'Group', 'overlaymap.group', 'Party and raid members as dots in their class color, where the game shares their spot.', disabled = MapOff, since = '0.5.2'},
		{'slider', 'Arrow', 'overlaymap.arrowSize', 10, 28, 1, 'Your arrow\'s size.', format = Int, disabled = MapOff, since = '0.5.2'},
		{'switch', 'Scale', 'overlaymap.scaleChip', 'The zoom in yards on a chip at the bottom.', disabled = MapOff, since = '0.5.2'},
		{'switch', 'Hide in combat', 'overlaymap.hideInCombat', nil, disabled = MapOff, since = '0.5.2'},
	}},
	{title = 'Points of interest', rows = {
		{'segmented', 'Quests', 'navigation.quests', items = {{'tracked', 'Tracked'}, {'all', 'All'}, {'off', 'None'}}, since = '0.5.2',
			note = 'Quests in your log: the ones you track (and your target), or all of them on this map.'},
		{'switch', 'World quests', 'navigation.worldQuests', 'World quests and bonus objectives on this map.', since = '0.5.2'},
		{'switch', 'Quest givers', 'navigation.questGivers', 'Where an available story or side quest line starts.', since = '0.5.2'},
		{'switch', 'Flight masters', 'navigation.flightMasters', nil, since = '0.5.2'},
		{'switch', 'Dungeons', 'navigation.dungeons', 'Dungeon, raid and delve entrances.', since = '0.5.2'},
		{'switch', 'Rares and treasures', 'navigation.vignettes', 'What the minimap marks: rares, treasures and events.', since = '0.5.2'},
		{'switch', 'Other map points', 'navigation.areaPois', 'Events, quest hubs and landmarks the map marks.', since = '0.5.2'},
		{'switch', 'Map entrances', 'navigation.mapLinks', 'Entrances to caves and buildings with a map of their own.', since = '0.5.2'},
		{'switch', 'Waypoint', 'navigation.waypoint', 'Your map pin, your super-tracked target and the game\'s route to it.', since = '0.5.2'},
		{'segmented', 'Updates', 'navigation.rate', items = {{20, '20 / s'}, {30, '30 / s'}}, since = '0.5.2',
			note = 'How often heading and position are read while a device is shown. Nothing runs while both are hidden.'},
	}},
	{title = 'Town services', rows = {
		{'switch', 'Town services', 'navigation.services', 'Repairers, inns, banks, mailboxes, auction houses, trainers and the rest: from city maps that mark them, and learned as you go.', since = '0.5.2'},
		{'switch', 'Learn as you go', 'navigation.learn', 'Remember where you use a service (repair, vendor, bank, mail, auction house, trainer, inn, stable, barber, transmog, guild bank). Kept for every character on this account.', disabled = NoServices, since = '0.5.2'},
		{'switch', 'Learn from titles', 'navigation.learnNear', 'Also remember a friendly NPC whose title names a service (<Innkeeper>, <Banker>, <Warrior Trainer>) once you pass within ten yards of it, under the mouse or with its nameplate shown. Marked ~ until you use it.', disabled = function() return NoServices() or NoLearning() end, since = '0.5.2'},
		{'switch', 'Repair', 'navigation.svcRepair', nil, disabled = NoServices, since = '0.5.2'},
		{'switch', 'Inn', 'navigation.svcInn', nil, disabled = NoServices, since = '0.5.2'},
		{'switch', 'Bank and guild bank', 'navigation.svcBank', nil, disabled = NoServices, since = '0.5.2'},
		{'switch', 'Mailbox', 'navigation.svcMail', nil, disabled = NoServices, since = '0.5.2'},
		{'switch', 'Auction house', 'navigation.svcAuction', nil, disabled = NoServices, since = '0.5.2'},
		{'switch', 'Trainers', 'navigation.svcTrainer', 'Class and profession trainers.', disabled = NoServices, since = '0.5.2'},
		{'switch', 'Vendors', 'navigation.svcVendor', 'Merchants that can\'t repair.', disabled = NoServices, since = '0.5.2'},
		{'switch', 'Stable master', 'navigation.svcStable', nil, disabled = NoServices, since = '0.5.2'},
		{'switch', 'Barber', 'navigation.svcBarber', nil, disabled = NoServices, since = '0.5.2'},
		{'switch', 'Transmogrifier', 'navigation.svcTransmog', nil, disabled = NoServices, since = '0.5.2'},
		{'button', 'Learned', 'Forget learned', Forget, 'Clears every learned service for the whole account.'},
		{'note', 'The game gives addons no positions for these NPCs; it draws them only as minimap tracking blips. So the devices learn them: using one records where you stand (you are within reach of it). A mailbox or barber\'s chair used outside a town waits for a second visit before it shows, in case it was a summoned one. Titles are read in your language for the services the minimap tracking menu names (innkeeper, banker, auctioneer, stable master, transmogrifier, barber); trainer and vendor titles are read in English only, so in other languages those are learned when you use them.'},
	}},
	{title = 'What the game allows', rows = {
		{'note', 'Position and facing are shared in the open world and in cities. In dungeons, raids, battlegrounds and other restricted places the game hides them, and both devices print NO SIGNAL.\n\nInside buildings, caves and city levels without a map of their own, the city or zone map around them is drawn and measured instead, and points from all of them are shown together. Points come only from what the maps know (quests, world quests, quest-line starts, flight masters, map icons, rares, dungeon entrances, your waypoint) plus the town services you have learned.'},
	}},
}})
