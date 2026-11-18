-- Navigation: what the NV-3 compass (Compass.lua) and the NV-4 overlay map
-- (OverlayMap.lua) share. Where you are and which way you face, which way you
-- are moving and how fast, and the points of interest around you, all read
-- from the zone map the game is showing you; plus the hub's Navigation page.
--
-- What the game lets an addon know, and so what these show:
--   * Your map position (C_Map.GetPlayerMapPosition) and facing
--     (GetPlayerFacing) are shared in the open world. In dungeons, raids,
--     battlegrounds and other restricted places they are nil (or secret):
--     then both devices print NO SIGNAL and nothing is measured.
--   * Distances are map coordinates times the map's size in yards
--     (C_Map.GetMapWorldSize), so they are as exact as the map itself.
--   * Movement direction comes from how your position changes; speed from
--     GetUnitSpeed (or the skyriding forward speed), else from the same change.
--   * Points of interest are only what the zone map itself knows: quests in
--     your log (C_QuestLog.GetQuestsOnMap), world quests and bonus objectives
--     (C_TaskQuest), quest-line starts (C_QuestLine), flight masters
--     (C_TaxiMap), area POIs including the town-service icons some city maps
--     carry (C_AreaPoiInfo), vignettes (C_VignetteInfo), dungeon and raid
--     entrances (C_EncounterJournal), entrances to other maps (C_Map map
--     links) and your waypoint or super-tracked target (C_SuperTrack). NPCs
--     the game draws only as minimap tracking blips (repairers, innkeepers,
--     mailboxes, trainers and vendors outside the cities that map them) have no
--     position an addon can read.
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
	services = true, -- town-service icons on city maps (inn, bank, mail, repair, ...)
	areaPois = true, -- other map POIs: events, quest hubs, delves, landmarks
	vignettes = true, -- rares, treasures and events the minimap shows
	dungeons = true, -- dungeon, raid and delve entrances
	mapLinks = false, -- entrances to other maps (caves, buildings)
	waypoint = true, -- your map pin and super-tracked target
	rate = 30, -- updates per second while a device is shown
})
-- defaults:end

local function DB() return UI.db.navigation end
local function IsSecret(value) return issecretvalue and issecretvalue(value) end
Nav.IsSecret = IsSecret

-- One plain answer, or nil when the call fails or answers secret.
local function Plain(func, ...)
	if type(func) ~= 'function' then return nil end
	local ok, value = pcall(func, ...)
	if not ok or IsSecret(value) then return nil end
	return value
end
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

-- Geometry (pure; tools/ checks these offline) ---------------------------------------
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

-- Where you are ---------------------------------------------------------------------
-- One reading per frame, shared by both devices: map, position (map and
-- yards), heading, movement and speed. Every field is plain or nil.
local here = {}
Nav.here = here
local history, HISTORY = {}, 0.6 -- recent positions, seconds kept
local listeners = {}
-- callback(what): 'map' when the map changed, 'pois' when the list was rebuilt.
function Nav:OnChange(callback) listeners[#listeners + 1] = callback end
local function Notify(what)
	for _, callback in ipairs(listeners) do UI:Safe(callback, what) end
end

local Dirty -- defined with the POIs
local MAP_EVERY, BASE_SPEED = 0.5, 7

local function MapChanged(mapID)
	here.mapID = mapID
	wipe(history)
	here.worldW, here.worldH, here.artID = nil, nil, nil
	if mapID and C_Map then
		local width, height = Plain2(C_Map.GetMapWorldSize, mapID)
		width, height = Number(width), Number(height)
		if width and height and width > 0 and height > 0 then here.worldW, here.worldH = width, height end
		here.artID = Plain(C_Map.GetMapArtID, mapID)
		if C_QuestLine and C_QuestLine.RequestQuestLinesForMap then pcall(C_QuestLine.RequestQuestLinesForMap, mapID) end
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
		local mapID = C_Map and Number(Plain(C_Map.GetBestMapForUnit, 'player'))
		local artID = mapID and C_Map and Plain(C_Map.GetMapArtID, mapID)
		if mapID ~= here.mapID or artID ~= here.artID then MapChanged(mapID) end
	end
	local x, y
	if here.mapID and here.worldW then x, y = XY(Plain(C_Map.GetPlayerMapPosition, here.mapID, 'player')) end
	if x and (x ~= 0 or y ~= 0) then
		here.x, here.y = x, y
		here.wx, here.wy = x * here.worldW, y * here.worldH
		-- Keep the window's samples, dropping the oldest beyond it.
		local sample = {t = now, wx = here.wx, wy = here.wy}
		history[#history + 1] = sample
		while #history > 2 and now - history[1].t > HISTORY + 0.1 do table.remove(history, 1) end
		Move(now)
	else
		here.x, here.y, here.wx, here.wy = nil, nil, nil, nil
		here.moving, here.moveDeg = false, nil
		here.speed = Speed()
		here.pace = here.speed and here.speed / BASE_SPEED * 100 or nil
		wipe(history)
	end
	return here
end

-- The zone printed on the compass: zone, subzone and its PvP state.
function Nav:Zone()
	local zone, sub = Plain(GetZoneText), Plain(GetSubZoneText)
	local pvp
	local get = (C_PvP and C_PvP.GetZonePVPInfo) or _G.GetZonePVPInfo
	if get then pvp = Text(Plain(get)) end
	return Text(zone) or '', Text(sub) or '', pvp
end

-- Points of interest ------------------------------------------------------------------
-- kind -> how it is drawn: a printed glyph on a small key, a lamp color, the
-- game's own atlas when the "game icons" look is on, and a rank (lower wins a
-- place on a crowded tape).
local KINDS = {
	waypoint = {glyph = '+', token = 'lamp', rank = 1, atlas = 'Waypoint-MapPin-Tracked'},
	turnin = {glyph = '?', token = 'amber', rank = 2, atlas = 'QuestTurnin'},
	quest = {glyph = 'Q', token = 'amber', rank = 3, atlas = 'QuestNormal'},
	world = {glyph = 'W', token = 'blue', rank = 4, atlas = 'worldquest-icon'},
	giver = {glyph = '!', token = 'amber', rank = 5, atlas = 'QuestNormal'},
	rare = {glyph = '*', token = 'red', rank = 6},
	treasure = {glyph = 'T', token = 'amber', rank = 7},
	event = {glyph = 'E', token = 'blue', rank = 7},
	dungeon = {glyph = 'D', token = 'red', rank = 8},
	taxi = {glyph = 'F', token = 'green', rank = 9, atlas = 'TaxiNode_Neutral'},
	portal = {glyph = 'P', token = 'green', rank = 9},
	inn = {glyph = 'I', token = 'ink', rank = 10},
	bank = {glyph = 'B', token = 'ink', rank = 10},
	mail = {glyph = 'M', token = 'ink', rank = 10},
	repair = {glyph = 'R', token = 'ink', rank = 10},
	auction = {glyph = 'A', token = 'ink', rank = 10},
	vendor = {glyph = 'V', token = 'ink', rank = 11},
	trainer = {glyph = 'TR', token = 'ink', rank = 11},
	stable = {glyph = 'S', token = 'ink', rank = 11},
	transmog = {glyph = 'X', token = 'ink', rank = 11},
	barber = {glyph = 'BB', token = 'ink', rank = 11},
	poi = {glyph = 'i', token = 'dim', rank = 12},
	link = {glyph = '>', token = 'dim', rank = 13},
}
Nav.KINDS = KINDS

-- Town services and other area POIs, told apart by the art the map gives
-- them (atlas names are the same in every language; names are not).
local SERVICE_KINDS = {inn = true, bank = true, mail = true, repair = true, auction = true, vendor = true, trainer = true,
	stable = true, transmog = true, barber = true}
local ART = {
	{'innkeeper', 'inn'}, {'bank', 'bank'}, {'mail', 'mail'}, {'repair', 'repair'}, {'auction', 'auction'},
	{'transmog', 'transmog'}, {'barber', 'barber'}, {'stable', 'stable'}, {'portal', 'portal'}, {'teleport', 'portal'},
	{'vendor', 'vendor'}, {'merchant', 'vendor'}, {'trainer', 'trainer'}, {'profession', 'trainer'},
	{'flightmaster', 'taxi'}, {'taxinode', 'taxi'}, {'dungeon', 'dungeon'}, {'raid', 'dungeon'}, {'delve', 'dungeon'},
	{'innkeep', 'inn'}, {'^inn', 'inn'},
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

local function Wanted() return next(consumers) ~= nil end

-- A device being shown asks for points; while none is, rebuilding waits.
function Nav:Want(owner, on)
	consumers[owner] = on and true or nil
	if on and stale then Dirty() end
end

local function Add(kind, x, y, uid, extra)
	x, y = Number(x), Number(y)
	if not (x and y) or (x == 0 and y == 0) then return end
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
			if questID and not True(info.isHidden) then
				Add('giver', info.x, info.y, 'g'..questID, {id = questID})
			end
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
						local wanted = (SERVICE_KINDS[kind] and db.services) or (kind == 'dungeon' and db.dungeons)
							or (not SERVICE_KINDS[kind] and kind ~= 'dungeon' and db.areaPois)
						-- Flight masters come from the taxi list, and only once.
						if kind == 'taxi' and db.flightMasters then wanted = false end
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
		for index, link in ipairs(Plain(C_Map.GetMapLinksForMap, mapID) or {}) do
			if type(link) == 'table' then
				local x, y = XY(link.position)
				Add('link', x, y, 'l'..index, {atlas = Text(link.atlasName)})
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
	-- A super-tracked map pin (an area POI, a quest offer, a flight master).
	if track and track.GetSuperTrackedMapPin then
		local pinType, pinID = Plain2(track.GetSuperTrackedMapPin)
		local types = Enum and Enum.SuperTrackingMapPinType
		pinType, pinID = Number(pinType), Number(pinID)
		if pinType and pinID and types then
			local prefix = (pinType == types.AreaPOI and 'a') or (pinType == types.QuestOffer and 'g')
				or (pinType == types.TaxiNode and 't') or nil
			for _, poi in ipairs(pois) do
				if prefix and poi.uid == prefix..pinID then poi.super = true end
			end
		end
	end
end

local function Rebuild()
	pending = false
	if not Wanted() then stale = true return end
	stale = false
	wipe(pois)
	local mapID = here.mapID
	if mapID and here.worldW and C_Map then
		local db = DB()
		local track = C_SuperTrack
		local superQuest = track and track.GetSuperTrackedQuestID and Number(Plain(track.GetSuperTrackedQuestID))
		if superQuest == 0 then superQuest = nil end
		local superVignette = track and track.GetSuperTrackedVignette and Plain(track.GetSuperTrackedVignette)
		UI:Safe(GatherQuests, mapID, db, superQuest)
		UI:Safe(GatherMap, mapID, db)
		if db.vignettes then UI:Safe(GatherVignettes, mapID, superVignette) end
		if db.waypoint then UI:Safe(GatherWaypoints, mapID, superQuest) end
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
	key.art = key.face:CreateTexture(nil, 'ARTWORK')
	key.art:SetPoint('TOPLEFT', 2, -2)
	key.art:SetPoint('BOTTOMRIGHT', -2, 2)
	key.art:Hide()
	key.lamp = Kit:Led(key.face, 3, true)
	key.lamp:SetPoint('TOPRIGHT', -2, -2)
	return key
end

-- Dress a key for a point. size: its side in UI units; art: use the game's icon.
function Nav:DressKey(key, poi, size, art)
	local kind = KINDS[poi.kind] or KINDS.poi
	key:SetSize(size, size)
	local atlas = art and (poi.atlas or kind.atlas)
	local shown = false
	if atlas and key.atlas ~= atlas then
		key.atlas = atlas
		key.hasArt = pcall(key.art.SetAtlas, key.art, atlas) and true or false
	end
	if atlas then shown = key.hasArt end
	key.art:SetShown(shown and true or false)
	key.glyph:SetShown(not shown)
	if not shown then
		key.glyph:SetText(kind.glyph)
		Kit:Font(key.glyph, max(6, floor(size * (#kind.glyph > 1 and 0.4 or 0.52))), nil, true)
		Kit:Tint(key.glyph, kind.token == 'dim' and 'dim' or 'ink')
	end
	Kit:SetLed(key.lamp, true, kind.token ~= 'ink' and kind.token ~= 'dim' and kind.token or 'ledOff')
	key.lamp:SetShown(kind.token ~= 'ink' and kind.token ~= 'dim')
	if poi.super then
		Kit:Tint(key.glow, 'lamp')
		key.glow:SetAlpha(0.55)
		key.glow:Show()
	else
		key.glow:Hide()
	end
end

-- Events ------------------------------------------------------------------------------
local POI_EVENTS = {'ZONE_CHANGED', 'ZONE_CHANGED_INDOORS', 'ZONE_CHANGED_NEW_AREA', 'PLAYER_ENTERING_WORLD', 'NEW_WMO_CHUNK',
	'PLAYER_MAP_CHANGED', 'QUEST_LOG_UPDATE', 'QUEST_WATCH_LIST_CHANGED', 'QUEST_POI_UPDATE', 'QUESTLINE_UPDATE',
	'SUPER_TRACKING_CHANGED', 'USER_WAYPOINT_UPDATED', 'WAYPOINT_UPDATE', 'VIGNETTES_UPDATED', 'VIGNETTE_MINIMAP_UPDATED',
	'AREA_POIS_UPDATED', 'TAXIMAP_OPENED', 'TAXIMAP_CLOSED', 'TAXI_NODE_STATUS_CHANGED'}
local ZONE_EVENTS = {ZONE_CHANGED = true, ZONE_CHANGED_INDOORS = true, ZONE_CHANGED_NEW_AREA = true, PLAYER_ENTERING_WORLD = true,
	NEW_WMO_CHUNK = true, PLAYER_MAP_CHANGED = true}

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
local function Int(value) return format('%d', value + 0.5) end
local function Yd(value) return format('%d yd', value + 0.5) end
local function Pct(value) return format('%d%%', value * 100 + 0.5) end
local function Px(value) return format('%d px', value + 0.5) end
local function Deg(value) return format('%d°', value + 0.5) end
local function CompassOff() return not UI.db.compass.enable end
local function MapOff() return not UI.db.overlaymap.enable end
local function NoPois() return CompassOff() or not UI.db.compass.pois end

UI:RegisterPage('navigation', {title = 'Navigation', order = 12.2, since = '0.5.2', cards = {
	{title = 'NV-3 compass', rows = {
		{'switch', 'Compass', 'compass.enable', 'A heading tape at the top of the screen: where you face and where you are moving, the zone, your coordinates, and the points of interest around you at their bearing.', since = '0.5.2'},
		{'segmented', 'Housing', 'compass.housing', items = {{'device', 'Device'}, {'glass', 'Glass'}, {'hairline', 'Hairline'}},
			disabled = CompassOff, since = '0.5.2', note = 'Device: a machined housing in the finish. Glass: a strip of dark glass. Hairline: just the tape over the world.'},
		{'slider', 'Width', 'compass.width', 300, 900, 10, nil, format = Int, disabled = CompassOff, since = '0.5.2'},
		{'slider', 'Field of view', 'compass.fov', 90, 360, 15, 'How many degrees the tape spans.', format = Deg, disabled = CompassOff, since = '0.5.2'},
		{'switch', 'Location', 'compass.location', 'Zone and subzone, with a lamp for the zone\'s PvP state.', disabled = CompassOff, since = '0.5.2'},
		{'switch', 'Coordinates', 'compass.coords', 'Your map coordinates on an LCD.', disabled = CompassOff, since = '0.5.2'},
		{'switch', 'Heading', 'compass.heading', 'Your heading in degrees on an LCD over the caret.', disabled = CompassOff, since = '0.5.2'},
		{'switch', 'Movement', 'compass.motion', 'A second marker on the tape for the way you are actually moving (strafing, backing up, falling), and your speed.', disabled = CompassOff, since = '0.5.2'},
		{'segmented', 'Speed', 'compass.speedUnit', items = {{'yards', 'Yards/s'}, {'percent', 'Percent'}},
			disabled = function() return CompassOff() or not UI.db.compass.motion end, since = '0.5.2'},
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
		{'switch', 'Distances', 'compass.distances', 'Yards on a small LCD chip under each key.', disabled = NoPois, since = '0.5.2'},
		{'switch', 'Pin your target', 'compass.pinTarget', 'Your super-tracked quest or waypoint waits at the tape\'s end when it is behind you.', disabled = NoPois, since = '0.5.2'},
		{'segmented', 'Icons', 'compass.icons', items = {{'glyph', 'Printed'}, {'game', 'Game icons'}}, disabled = NoPois, since = '0.5.2',
			note = 'Printed: a letter on each key (Q quest, ? turn-in, ! quest giver, F flight master, D dungeon, * rare). Game icons: the map\'s own art.'},
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
		{'switch', 'Town services', 'navigation.services', 'Inns, banks, mail, repairs, auctions and the rest, on city maps that carry them.', since = '0.5.2'},
		{'switch', 'Dungeons', 'navigation.dungeons', 'Dungeon, raid and delve entrances.', since = '0.5.2'},
		{'switch', 'Rares and treasures', 'navigation.vignettes', 'What the minimap marks: rares, treasures and events.', since = '0.5.2'},
		{'switch', 'Other map points', 'navigation.areaPois', 'Events, quest hubs and landmarks the map marks.', since = '0.5.2'},
		{'switch', 'Map entrances', 'navigation.mapLinks', 'Entrances to caves and buildings with a map of their own.', since = '0.5.2'},
		{'switch', 'Waypoint', 'navigation.waypoint', 'Your map pin, your super-tracked target and the game\'s route to it.', since = '0.5.2'},
		{'segmented', 'Updates', 'navigation.rate', items = {{20, '20 / s'}, {30, '30 / s'}}, since = '0.5.2',
			note = 'How often heading and position are read while a device is shown. Nothing runs while both are hidden.'},
	}},
	{title = 'What the game allows', rows = {
		{'note', 'Position and facing are shared in the open world. In dungeons, raids, battlegrounds and other restricted places the game hides them, and both devices print NO SIGNAL.\n\nPoints come only from what the zone map knows: quests in your log, world quests, quest-line starts, flight masters, map icons (including the town services some city maps draw), rares and treasures, dungeon entrances and your waypoint. Repairers, innkeepers, mailboxes, trainers and vendors that the game shows only as minimap tracking blips have no position an addon can read, so they can\'t be shown outside the cities that map them.'},
	}},
}})
