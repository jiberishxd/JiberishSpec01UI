-- The minimap as a SPEC-01 navigator: the map on the reference's black display,
-- in a light housing printed "NV-1 MAP", with the zone, your coordinates and the
-- time printed along the bottom of the display. Lamps in the header light for
-- mail, calendar invites and active tracking; a small LCD shows the instance
-- difficulty. Addon minimap buttons gather into an "NV-2 Apps" drawer of keys.
--
-- 'navigator': all of the above. 'ring': the round map in a machined bezel,
-- with a location strip (zone, clock, calendar and tracking keys, lamps) and a
-- coordinates LCD. A round map in the navigator gets the same bezel.
-- The minimap cluster stays where Edit Mode puts it; Blizzard's own pieces
-- (zone text, clock, calendar, tracking, zoom buttons, the expansion button...)
-- are only faded and made unclickable, never reparented; our keys click them.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown = CreateFrame, UIParent, InCombatLockdown
local floor, max, min = math.floor, math.max, math.min

local module = UI:RegisterModule('minimap', {})
local function DB() return UI.db.minimap end
local function IsSecret(value) return issecretvalue and issecretvalue(value) end
local function Plain(value) if not IsSecret(value) then return value end end
local function Forbidden(object) return type(object) ~= 'table' or (object.IsForbidden and object:IsForbidden()) end
local function Fade(region)
	if region and region.SetAlpha and not Forbidden(region) then region:SetAlpha(0) end
end

-- defaults:begin
-- size 0 keeps the game's (Edit Mode's) size. zoomReset: seconds before the map
-- zooms back out, 0 never. The show* switches keep Blizzard's own pieces.
UI:RegisterDefaults('minimap', {size = 0, shape = 'square', zoomReset = 8, clock24 = true, serverTime = false, coordsDecimals = 1,
	collector = true, appsPerRow = 6, lampMail = true, lampInvites = true, lampTracking = true, difficulty = true,
	showZoom = false, showExpansion = true, showCompartment = false, showTracking = true, showCalendar = true,
	showDifficulty = false, showMail = false,
	-- The location strip (ring style): zone, clock, keys and lamps, above or below the map.
	location = true, locationPos = 'top', coordsChip = true,
	-- Our round calendar and tracking keys; with one on, Blizzard's own is hidden.
	keyCalendar = true, keyTracking = true,
	-- The bezel around a round map, in physical pixels, and keys behind the
	-- round buttons on its edge (expansion summary, time of day).
	ringPx = 3, edgeKeys = true})
-- defaults:end

-- The ring style is always round; the navigator follows the shape setting.
local function Round() return UI:Style('minimap') == 'ring' or DB().shape == 'round' end
local function Mask() return Kit.media..(Round() and 'mask-round.tga' or 'mask-square.tga') end

-- Blizzard's pieces --------------------------------------------------------------------
-- Each piece has a switch; off, it is faded and stops taking the mouse, and
-- stays that way when Blizzard shows it again.
local pieces = setmetatable({}, {__mode = 'k'}) -- frame -> hidden?
local function Hold(frame)
	if pieces[frame] then frame:SetAlpha(0) end
end
local hookedPiece = setmetatable({}, {__mode = 'k'})
local function SetPiece(frame, shown)
	if Forbidden(frame) or not frame.SetAlpha then return end
	pieces[frame] = not shown
	if not hookedPiece[frame] then
		hookedPiece[frame] = true
		hooksecurefunc(frame, 'Show', Hold)
		hooksecurefunc(frame, 'SetAlpha', function(self) if pieces[self] and not IsSecret(self:GetAlpha()) and self:GetAlpha() > 0 then self:SetAlpha(0) end end)
	end
	frame:SetAlpha(shown and 1 or 0)
	if frame.EnableMouse and not (frame.IsProtected and frame:IsProtected() and InCombatLockdown()) then
		pcall(frame.EnableMouse, frame, shown and true or false)
	end
end

local function Cluster() return _G.MinimapCluster end

local function ApplyPieces()
	local db, map, cluster = DB(), _G.Minimap, Cluster()
	SetPiece(map and map.ZoomIn, db.showZoom); SetPiece(map and map.ZoomOut, db.showZoom)
	SetPiece(_G.MinimapZoomIn, db.showZoom); SetPiece(_G.MinimapZoomOut, db.showZoom)
	SetPiece(_G.ExpansionLandingPageMinimapButton, db.showExpansion)
	SetPiece(_G.GarrisonLandingPageMinimapButton, db.showExpansion)
	SetPiece(_G.AddonCompartmentFrame, db.showCompartment)
	local tracking = db.showTracking and not db.keyTracking
	SetPiece(cluster and cluster.Tracking, tracking)
	SetPiece(cluster and cluster.Tracking and cluster.Tracking.Button, tracking)
	SetPiece(_G.MiniMapTracking, tracking)
	SetPiece(_G.GameTimeFrame, db.showCalendar and not db.keyCalendar)
	-- The ring style's strip (and the navigator's readout) replace the zone
	-- text and the clock; the LCD chip replaces the coordinates.
	local ring = UI:Style('minimap') == 'ring'
	local zone = not ring or db.location
	local clock = (ring and db.location) or (not ring and db.clock)
	local coords = db.coords and ((ring and db.coordsChip) or (not ring and db.clock))
	SetPiece(cluster and cluster.ZoneTextButton, not zone)
	SetPiece(_G.MinimapZoneTextButton, not zone)
	SetPiece(_G.TimeManagerClockButton, not clock)
	local container = cluster and cluster.MinimapContainer
	SetPiece(container and container.PlayerCoords, not coords)
	SetPiece(cluster and cluster.InstanceDifficulty, db.showDifficulty)
	SetPiece(_G.MiniMapInstanceDifficulty, db.showDifficulty)
	local indicators = cluster and cluster.IndicatorFrame
	SetPiece(indicators and indicators.MailFrame, db.showMail)
	SetPiece(_G.MiniMapMailFrame, db.showMail)
end

-- Readout ------------------------------------------------------------------------------
local function Coordinates()
	if not C_Map or not C_Map.GetBestMapForUnit then return end
	local map = Plain(C_Map.GetBestMapForUnit('player'))
	local position = map and C_Map.GetPlayerMapPosition(map, 'player')
	if not position then return end
	local ok, x, y = pcall(position.GetXY, position)
	x, y = ok and Plain(x), ok and Plain(y)
	if x and y then return x * 100, y * 100 end
end

local function Clock()
	local db = DB()
	if db.serverTime and GetGameTime then
		local hour, minute = GetGameTime()
		if db.clock24 then return format('%02d:%02d', hour, minute) end
		return format('%d:%02d %s', (hour - 1) % 12 + 1, minute, hour < 12 and 'AM' or 'PM')
	end
	return db.clock24 and date('%H:%M') or (date('%I:%M %p'):gsub('^0', ''))
end

-- Instance difficulty, printed short: N, H, M, M+12, LFR, TW...
local SHORT = {[1] = 'N', [2] = 'H', [3] = '10N', [4] = '25N', [5] = '10H', [6] = '25H', [7] = 'LFR', [8] = 'M+', [9] = '40',
	[11] = 'HS', [12] = 'NS', [14] = 'N', [15] = 'H', [16] = 'M', [17] = 'LFR', [23] = 'M', [24] = 'TW', [33] = 'TW', [39] = 'HS',
	[40] = 'MS', [149] = 'HS', [150] = 'NS', [151] = 'LFR', [152] = 'VS', [153] = 'TS', [167] = 'TG', [168] = 'MC', [205] = 'FS',
	[208] = 'DLV', [216] = 'QS', [220] = 'ST'}
local function Difficulty()
	local ok, _, kind, difficultyID = pcall(GetInstanceInfo)
	kind, difficultyID = ok and Plain(kind), ok and Plain(difficultyID)
	if not kind or kind == 'none' or type(difficultyID) ~= 'number' then return '' end
	local text = SHORT[difficultyID] or ''
	if difficultyID == 8 and C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo then
		local level = Plain(C_ChallengeMode.GetActiveKeystoneInfo())
		if type(level) == 'number' and level > 0 then text = 'M+'..level end
	end
	return text
end

local function Tracking()
	local api = C_Minimap
	if not (api and api.GetNumTrackingTypes and api.GetTrackingInfo) then return false end
	for index = 1, Plain(api.GetNumTrackingTypes()) or 0 do
		local info = api.GetTrackingInfo(index)
		-- Town services are always on; anything else switched on lights the lamp.
		if type(info) == 'table' and Plain(info.active) == true and Plain(info.subType) ~= -1 and Plain(info.type) ~= 'townfolk' then
			return true
		end
	end
	return false
end

local function Invites()
	local count = C_Calendar and C_Calendar.GetNumPendingInvites and Plain(C_Calendar.GetNumPendingInvites())
	return type(count) == 'number' and count > 0
end

-- The apps drawer ---------------------------------------------------------------------
-- Addon minimap buttons (LibDBIcon and the usual named ones) move into a
-- drawer of keys. They are addon frames, not Blizzard's, so moving them is safe.
local BLIZZARD = {MinimapZoomIn = true, MinimapZoomOut = true, MiniMapWorldMapButton = true, MiniMapTracking = true,
	MiniMapTrackingButton = true, MiniMapMailFrame = true, GameTimeFrame = true, QueueStatusMinimapButton = true,
	QueueStatusButton = true, ExpansionLandingPageMinimapButton = true, GarrisonLandingPageMinimapButton = true,
	MiniMapBattlefieldFrame = true, MinimapZoneTextButton = true, TimeManagerClockButton = true, MiniMapInstanceDifficulty = true,
	GuildInstanceDifficulty = true, MiniMapChallengeMode = true, AddonCompartmentFrame = true, MinimapBackdrop = true,
	MiniMapLFGFrame = true, MinimapToggleButton = true, MiniMapVoiceChatFrame = true, MiniMapRecordingButton = true}
-- Addon buttons that don't use LibDBIcon, by name.
local ADDON_BUTTONS = {DBMMinimapButton = true, AtlasLootMinimapButton = true, ZygorGuidesViewerMapIcon = true,
	TomTomMapIcon = true, WIM3MinimapButton = true, GatherMinimapButton = true, RecountMinimapButton = true,
	OutfitterMinimapButton = true, CTMod_MinimapButton = true, MinimapButton_LDB = true}
local drawer, collected, order = nil, setmetatable({}, {__mode = 'k'}), {}
local APP = 26

local function IsApp(frame)
	if Forbidden(frame) or collected[frame] or not frame.IsObjectType or not frame:IsObjectType('Button') then return false end
	if frame.IsProtected and frame:IsProtected() then return false end
	-- Blizzard's own pieces hang off their parent under a key; addon buttons don't.
	if frame.GetParentKey and frame:GetParentKey() then return false end
	local name = frame.GetName and frame:GetName()
	if type(name) ~= 'string' or BLIZZARD[name] then return false end
	if name:find('^LibDBIcon10_') then return true end
	return ADDON_BUTTONS[name] or false
end

local function PlaceApps()
	if not drawer then return end
	local perRow = Kit:Clamp(floor(DB().appsPerRow or 6), 3, 12)
	local shown = {}
	for _, button in ipairs(order) do
		if button:IsShown() then shown[#shown + 1] = button end
	end
	for _, button in ipairs(order) do
		local slot = button.kitSlot
		slot:ClearAllPoints()
		slot:Hide()
	end
	for index, button in ipairs(shown) do
		local slot = button.kitSlot
		local line, place = floor((index - 1) / perRow), (index - 1) % perRow
		slot:SetPoint('TOPLEFT', drawer, 'TOPLEFT', 10 + place * (APP + 4), -26 - line * (APP + 4))
		slot:Show()
	end
	local across = max(min(#shown, perRow), 1)
	local lines = max(math.ceil(#shown / perRow), 1)
	drawer:SetSize(20 + across * (APP + 4) - 4, 26 + lines * (APP + 4) - 4 + 10)
	drawer.empty:SetShown(#shown == 0)
	if module.appsKey then module.appsKey.count:SetText(#shown > 0 and #shown or '') end
end

local function Seat(button)
	local slot = button.kitSlot
	if button:GetParent() ~= slot then button:SetParent(slot) end
	local _, relative = button:GetPoint(1)
	if relative ~= slot then
		button.kitSeating = true
		button:ClearAllPoints()
		button:SetPoint('CENTER', slot, 'CENTER')
		button.kitSeating = nil
	end
end

local function Collect(button)
	if not IsApp(button) then return end
	collected[button] = true
	order[#order + 1] = button
	local slot = CreateFrame('Frame', nil, drawer)
	slot:SetSize(APP, APP)
	slot.skin = Kit:Skin(slot, 'key', 'BACKGROUND', 0)
	slot.skin.kitMaxCorner = 7
	button.kitSlot = slot
	button:SetSize(APP - 4, APP - 4)
	button:SetFrameLevel(slot:GetFrameLevel() + 2)
	-- The round border and backdrop give way to the key; the icon stays.
	local icon = button.icon or button.Icon
	for _, region in ipairs({button:GetRegions()}) do
		if region.IsObjectType and region:IsObjectType('Texture') and region ~= icon then
			local file = region.GetTextureFileID and region:GetTextureFileID()
			if region == button.border or region == button.background or file == 136430 or file == 136467 or file == 136477 then
				region:SetAlpha(0)
			end
		end
	end
	if icon and icon.ClearAllPoints then
		icon:ClearAllPoints()
		icon:SetPoint('TOPLEFT', 3, -3)
		icon:SetPoint('BOTTOMRIGHT', -3, 3)
		if icon.SetTexCoord then icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
	end
	local highlight = button.GetHighlightTexture and button:GetHighlightTexture()
	if highlight then highlight:SetAlpha(0.15) end
	-- No dragging round the map edge in the drawer; addons that re-place
	-- their button are put back a frame later.
	if button.SetScript then button:SetScript('OnDragStart', nil); button:SetScript('OnDragStop', nil) end
	hooksecurefunc(button, 'SetPoint', function(self)
		if self.kitSeating then return end
		C_Timer.After(0, function() UI:Safe(Seat, self) end)
	end)
	hooksecurefunc(button, 'SetParent', function(self, parent)
		if parent ~= self.kitSlot then C_Timer.After(0, function() UI:Safe(Seat, self) end) end
	end)
	button:HookScript('OnShow', function() C_Timer.After(0, function() UI:Safe(PlaceApps) end) end)
	button:HookScript('OnHide', function() C_Timer.After(0, function() UI:Safe(PlaceApps) end) end)
	Seat(button)
end

local function Scan()
	if not drawer then return end
	for _, owner in ipairs({_G.Minimap, _G.MinimapBackdrop, Cluster()}) do
		if not Forbidden(owner) then
			for _, child in ipairs({owner:GetChildren()}) do UI:Safe(Collect, child) end
		end
	end
	PlaceApps()
end

local scanQueued
local function QueueScan()
	if scanQueued then return end
	scanQueued = true
	C_Timer.After(0.5, function() scanQueued = nil; UI:Safe(Scan) end)
end

local function BuildDrawer(device)
	drawer = Kit:Device(UIParent, {model = 'NV-2', title = 'Apps', radius = 12, width = 120, height = 60})
	drawer:SetFrameStrata('MEDIUM')
	drawer:SetFrameLevel(device:GetFrameLevel() + 20)
	Kit:Relevel(drawer)
	drawer:EnableMouse(true)
	drawer:SetPoint('TOPRIGHT', device, 'TOPLEFT', -6, 0)
	drawer.empty = Kit:Label(drawer, 'No addon buttons', 'dim', 8)
	drawer.empty:SetPoint('TOPLEFT', 12, -30)
	drawer:Hide()
	local key = Kit:Key(device, {width = 34, height = 14, text = 'Apps', textSize = 7, tone = 'dark'})
	key.count = Kit:Label(device, '', 'dim', 7)
	key.count:SetPoint('RIGHT', key, 'LEFT', -3, 0)
	key.onClick = function()
		if drawer:IsShown() then Kit:Close(drawer) else Kit:ResetRest(drawer); Kit:Open(drawer); Kit:Play('open') end
	end
	module.appsKey = key
	local ldbi = LibStub and LibStub('LibDBIcon-1.0', true)
	if ldbi and type(ldbi.RegisterCallback) == 'function' then
		pcall(ldbi.RegisterCallback, module, 'LibDBIcon_IconCreated', QueueScan)
	end
	return key
end

-- The navigator ---------------------------------------------------------------------
local function SetShape(map)
	local mask = Mask()
	map:SetMaskTexture(mask)
	-- Button libraries ask the map's shape.
	local shape = Round() and 'ROUND' or 'SQUARE'
	_G.GetMinimapShape = function() return shape end
	local hybrid = _G.HybridMinimap
	if hybrid and hybrid.MapCanvas and hybrid.MapCanvas.SetMaskTexture then
		pcall(hybrid.MapCanvas.SetMaskTexture, hybrid.MapCanvas, mask)
		if hybrid.CircleMask and hybrid.CircleMask.SetAlpha then hybrid.CircleMask:SetAlpha(Round() and 1 or 0) end
	end
end

local function SetSize(map)
	local size = floor(tonumber(DB().size) or 0)
	if size <= 0 then return end
	if InCombatLockdown() and map:IsProtected() then return UI:AfterCombat(function() SetSize(map) end, 'mm.size') end
	map:SetSize(size, size)
	-- The map redraws at its new size on the next zoom change.
	local zoom = map:GetZoom()
	map:SetZoom(zoom > 0 and zoom - 1 or zoom + 1)
	map:SetZoom(zoom)
	if module.strip then module.strip.zone:SetWidth(size * 0.52) end
end

local zoomTimer
local function ZoomLater(map)
	if zoomTimer then zoomTimer:Cancel(); zoomTimer = nil end
	local seconds = tonumber(DB().zoomReset) or 0
	if seconds <= 0 or map:GetZoom() == 0 then return end
	zoomTimer = C_Timer.NewTimer(seconds, function()
		zoomTimer = nil
		map:SetZoom(0)
	end)
end

-- Blizzard's own buttons, clicked from our keys -----------------------------------------
local function OpenCalendar()
	local button = _G.GameTimeFrame
	if button and button.Click and not Forbidden(button) then button:Click()
	elseif _G.ToggleCalendar then _G.ToggleCalendar() end
end

-- Tracking types as plain {name, active} pairs, in the game's order. The API
-- returns a table on current clients and loose values on older ones.
local function TrackingList()
	local api = C_Minimap
	if not (api and api.GetNumTrackingTypes and api.GetTrackingInfo) then return end
	local ok, count = pcall(api.GetNumTrackingTypes)
	count = ok and Plain(count)
	if type(count) ~= 'number' then return end
	local list = {}
	for index = 1, count do
		local okInfo, info, _, active = pcall(api.GetTrackingInfo, index)
		local name
		if okInfo and type(info) == 'table' then name, active = Plain(info.name), Plain(info.active)
		elseif okInfo then name, active = Plain(info), Plain(active) end
		if type(name) == 'string' then list[#list + 1] = {index = index, name = name, active = active and true or false} end
	end
	return list
end

-- The tracking menu, built by us from the tracking API, so no Blizzard menu
-- frame is ever opened or moved from addon code. Without the menu API, the
-- game's own button opens its menu where the game puts it.
local function OpenTracking(anchor)
	local list = TrackingList()
	local api = C_Minimap
	if list and MenuUtil and MenuUtil.CreateContextMenu and api and api.SetTracking then
		MenuUtil.CreateContextMenu(anchor, function(_, root)
			root:CreateTitle('Tracking')
			for _, entry in ipairs(list) do
				root:CreateCheckbox(entry.name, function()
					local ok, info, _, active = pcall(api.GetTrackingInfo, entry.index)
					if ok and type(info) == 'table' then active = info.active end
					return Plain(active) and true or false
				end, function()
					local ok, info, _, active = pcall(api.GetTrackingInfo, entry.index)
					if ok and type(info) == 'table' then active = info.active end
					active = Plain(active)
					pcall(api.SetTracking, entry.index, not active)
					Kit:Play(active and 'latch-up' or 'latch-down')
				end)
			end
		end)
		return
	end
	local cluster = Cluster()
	local button = (cluster and cluster.Tracking and cluster.Tracking.Button) or _G.MiniMapTrackingButton
	if Forbidden(button) then return end
	if button.OpenMenu then button:OpenMenu()
	elseif button.Click then button:Click() end
end

local function OpenClock()
	local button = _G.TimeManagerClockButton
	if button and button.Click and not Forbidden(button) then button:Click()
	elseif _G.TimeManager_Toggle then _G.TimeManager_Toggle() end
end

local function OpenMap()
	if _G.ToggleWorldMap then _G.ToggleWorldMap() end
end

-- A small round key with an icon.
local function RoundKey(parent, icon, onClick, tip)
	local key = Kit:Key(parent, {round = true, width = 16, height = 16, icon = icon, iconSize = 8})
	key.onClick = function(self) Kit:Play('open'); onClick(self) end
	if tip then
		key:HookScript('OnEnter', function(self)
			GameTooltip:SetOwner(self, 'ANCHOR_BOTTOMLEFT')
			GameTooltip:SetText(tip)
			GameTooltip:Show()
		end)
		key:HookScript('OnLeave', function() GameTooltip:Hide() end)
	end
	return key
end

local function PvPToken()
	local get = (C_PvP and C_PvP.GetZonePVPInfo) or _G.GetZonePVPInfo
	local ok, kind = pcall(get or function() end)
	kind = ok and Plain(kind)
	if kind == 'sanctuary' then return 'blue'
	elseif kind == 'friendly' then return 'green'
	elseif kind == 'contested' then return 'amber'
	elseif kind == 'hostile' or kind == 'combat' or kind == 'arena' then return 'red' end
end

local function Indicator(key)
	local cluster = Cluster()
	local frame = cluster and cluster.IndicatorFrame and cluster.IndicatorFrame[key]
	return frame and not Forbidden(frame) and frame.IsShown and Plain(frame:IsShown()) and true or false
end

-- The bezel ----------------------------------------------------------------------------
-- Drawn at physical pixels around the round map: an outline, the machined band
-- and a one-pixel lit rim sit under the map (on its parent, so the map draws
-- over their middles); the shade inside the edge, a fine highlight and the
-- north lamp sit over it. All from 512px art, only ever shown smaller.
local bezel
local function FitBezel()
	if not bezel then return end
	local map = bezel.map
	local Px = UI.Pixel.Px
	local ring = Kit:Clamp(floor(tonumber(DB().ringPx) or 3), 1, 8)
	local function Around(texture, n)
		local inset = Px(map, n)
		texture:ClearAllPoints()
		texture:SetPoint('TOPLEFT', map, 'TOPLEFT', -inset, inset)
		texture:SetPoint('BOTTOMRIGHT', map, 'BOTTOMRIGHT', inset, -inset)
	end
	Around(bezel.shadow, ring + 10)
	Around(bezel.outline, ring + 1)
	Around(bezel.band, ring)
	Around(bezel.lit, 1)
	Around(bezel.highlight, ring)
	bezel.lamp:ClearAllPoints()
	bezel.lamp:SetPoint('CENTER', map, 'TOP', 0, Px(map, ring / 2))
	local shown = Round()
	for _, texture in ipairs({bezel.shadow, bezel.outline, bezel.band, bezel.lit}) do texture:SetShown(shown) end
	bezel.front:SetShown(shown)
	if module.screen then module.screen:SetShown(not shown) end
	-- The navigator's printed readout keeps its shade only on the square display.
	if module.strip and module.strip.shade then module.strip.shade:SetShown(not shown) end
end

local function Bezel(map)
	if bezel then return FitBezel() end
	local holder = map:GetParent() or UIParent
	bezel = {map = map}
	bezel.shadow = holder:CreateTexture(nil, 'BACKGROUND', nil, -8)
	bezel.shadow:SetTexture(Kit.media..'glow.tga')
	bezel.shadow:SetVertexColor(0, 0, 0, 0.45)
	bezel.outline = Kit:Texture(holder, 'mask-round', 'BACKGROUND', -7)
	bezel.outline:SetVertexColor(0, 0, 0, 0.85)
	bezel.band = Kit:Texture(holder, 'mask-round', 'BACKGROUND', -6)
	Kit:Tint(bezel.band, 'dark')
	bezel.lit = Kit:Texture(holder, 'mask-round', 'BACKGROUND', -5)
	bezel.lit:SetVertexColor(1, 1, 1, 0.16)
	local front = CreateFrame('Frame', nil, map)
	front:SetAllPoints(map)
	front:SetFrameLevel(map:GetFrameLevel() + 2)
	front:EnableMouse(false)
	bezel.front = front
	bezel.shade = Kit:Texture(front, 'bezel-shade', 'OVERLAY', 0)
	bezel.shade:SetAllPoints(map)
	bezel.shade:SetAlpha(0.55)
	bezel.highlight = Kit:Texture(front, 'bezel-ring', 'OVERLAY', 1)
	bezel.highlight:SetVertexColor(1, 1, 1, 0.08)
	bezel.lamp = Kit:Led(front, 5, true)
	Fade(_G.MinimapCompassTexture); Fade(_G.MinimapBorder); Fade(_G.MinimapBorderTop); Fade(_G.MinimapNorthTag)
	Fade(_G.MinimapCompassTextureUnderlay)
	map:HookScript('OnSizeChanged', function() UI:Safe(FitBezel) end)
	UI.Pixel.OnChange(FitBezel)
	FitBezel()
end

-- Keys behind the round buttons Blizzard puts on the map's edge.
local keyed = setmetatable({}, {__mode = 'k'})
local function EdgeKey(button, scale)
	if Forbidden(button) or keyed[button] or (button.IsProtected and button:IsProtected()) then return end
	local parent = button:GetParent()
	if not parent then return end
	local key = CreateFrame('Frame', nil, parent)
	key:SetFrameLevel(max(button:GetFrameLevel() - 1, 0))
	key:EnableMouse(false)
	key.skin = Kit:Skin(key, 'key-round', 'BACKGROUND', 0)
	keyed[button] = key
	local function Fit()
		local width, height = button:GetSize()
		if IsSecret(width) or IsSecret(height) or not width or width <= 0 then return end
		local size = min(width, height) * (button:GetScale() or 1) * 0.86
		key:SetSize(size, size)
		key:ClearAllPoints()
		key:SetPoint('CENTER', button, 'CENTER')
		Kit:FitSprite(key.skin, size, size)
		key:SetShown(button:IsShown() and button:GetAlpha() > 0)
	end
	if scale and button.SetScale then button:SetScale(scale) end
	button:HookScript('OnShow', Fit)
	button:HookScript('OnHide', function() key:Hide() end)
	button:HookScript('OnSizeChanged', Fit)
	Fit()
end

local function ApplyEdgeKeys()
	if not DB().edgeKeys then
		for _, key in pairs(keyed) do key:Hide() end
		return
	end
	local cluster = Cluster()
	UI:Safe(EdgeKey, _G.ExpansionLandingPageMinimapButton, 0.7)
	UI:Safe(EdgeKey, cluster and cluster.DielFrame)
	-- Addon buttons left on the map edge when the apps drawer is off.
	if not DB().collector and not Forbidden(_G.Minimap) then
		for _, child in ipairs({_G.Minimap:GetChildren()}) do
			local name = child.GetName and child:GetName()
			if type(name) == 'string' and name:find('^LibDBIcon10_') then
				for _, region in ipairs({child:GetRegions()}) do
					local file = region.GetTextureFileID and region:GetTextureFileID()
					if file == 136430 or file == 136467 or file == 136477 then region:SetAlpha(0) end
				end
				UI:Safe(EdgeKey, child)
			end
		end
	end
end

-- The location strip --------------------------------------------------------------------
-- Zone and subzone in the PvP color with a lamp, the difficulty LCD, mail and
-- crafting-order lamps, the clock on an LCD and the calendar and tracking keys,
-- on a glass plate above or below the round map. Click the zone for the map.
local strip, chip, FitNames
local function FitStrip()
	if not strip then return end
	local db, map = DB(), _G.Minimap
	local ring = UI.Pixel.Px(map, Kit:Clamp(floor(tonumber(db.ringPx) or 3), 1, 8))
	strip:SetShown(db.location and true or false)
	strip:ClearAllPoints()
	if db.locationPos == 'bottom' then
		strip:SetPoint('TOPLEFT', map, 'BOTTOMLEFT', -ring, -ring - 6)
		strip:SetPoint('TOPRIGHT', map, 'BOTTOMRIGHT', ring, -ring - 6)
	else
		strip:SetPoint('BOTTOMLEFT', map, 'TOPLEFT', -ring, ring + 6)
		strip:SetPoint('BOTTOMRIGHT', map, 'TOPRIGHT', ring, ring + 6)
	end
	if chip then
		chip:SetShown((db.coords and db.coordsChip) and true or false)
		chip:ClearAllPoints()
		local below = (db.location and db.locationPos == 'bottom') and strip or map
		chip:SetPoint('TOP', below, 'BOTTOM', 0, below == map and -ring - 5 or -4)
	end
	-- Right to left: tracking, calendar, clock, lamps, difficulty; the zone takes the rest.
	local anchor, gap = nil, 4
	local function Next(region, shown)
		region:SetShown(shown and true or false)
		if not shown then return end
		region:ClearAllPoints()
		if anchor then region:SetPoint('RIGHT', anchor, 'LEFT', -gap, 0) else region:SetPoint('RIGHT', strip, 'RIGHT', -4, 0) end
		anchor = region
	end
	Next(strip.tracking, db.keyTracking)
	Next(strip.calendar, db.keyCalendar)
	Next(strip.clock, db.clock)
	Next(strip.craft, db.lampMail)
	Next(strip.mail, db.lampMail)
	Next(strip.difficulty, db.difficulty and strip.difficulty.text:GetText() ~= '')
	strip.names:ClearAllPoints()
	strip.names:SetPoint('LEFT', strip.lamp, 'RIGHT', 5, 0)
	if anchor then strip.names:SetPoint('RIGHT', anchor, 'LEFT', -6, 0) else strip.names:SetPoint('RIGHT', strip, 'RIGHT', -6, 0) end
end

-- The zone keeps its full width when it fits; the subzone gets what is left.
function FitNames()
	if not strip then return end
	local width, text = strip.names:GetWidth(), strip.zone:GetUnboundedStringWidth()
	if IsSecret(width) or IsSecret(text) or not width or width <= 0 then return end
	strip.zone:SetWidth(min(text + 2, width))
end

local function UpdateZone()
	if not strip then return end
	local zone = Plain(GetZoneText and GetZoneText()) or ''
	local sub = Plain(GetSubZoneText and GetSubZoneText()) or ''
	if zone == '' then zone = Plain(GetMinimapZoneText and GetMinimapZoneText()) or '' end
	strip.zone:SetText(zone)
	strip.sub:SetText((sub ~= '' and sub ~= zone) and sub or '')
	local token = PvPToken()
	Kit:Tint(strip.zone, token or 'darkInk')
	Kit:SetLed(strip.lamp, true, token)
	FitNames()
end

local function BuildStrip(map)
	local holder = map:GetParent() or UIParent
	strip = CreateFrame('Button', nil, holder)
	strip:SetHeight(22)
	strip:SetFrameLevel(map:GetFrameLevel() + 5)
	strip.shell = Kit:Shell(strip, {surface = 'glass', radius = 6})
	strip:RegisterForClicks('LeftButtonUp')
	strip:SetScript('OnClick', function() Kit:Play('open'); OpenMap() end)
	strip.lamp = Kit:Led(strip, 5, true)
	strip.lamp:SetPoint('LEFT', 8, 0)
	-- Zone and subzone share a line; the subzone gives way first.
	strip.names = CreateFrame('Frame', nil, strip)
	strip.names:SetHeight(14)
	strip.zone = Kit:Text(strip.names, '', 9, 'darkInk', true)
	strip.zone:SetPoint('LEFT')
	strip.zone:SetWordWrap(false)
	strip.zone:SetJustifyH('LEFT')
	strip.sub = Kit:Text(strip.names, '', 8, 'darkDim')
	strip.sub:SetPoint('LEFT', strip.zone, 'RIGHT', 5, 0)
	strip.sub:SetPoint('RIGHT', strip.names, 'RIGHT')
	strip.sub:SetWordWrap(false)
	strip.sub:SetJustifyH('LEFT')
	strip.names:SetScript('OnSizeChanged', function() UI:Safe(FitNames) end)
	strip.difficulty = Kit:LCDPanel(strip, {radius = 3})
	strip.difficulty:SetSize(30, 14)
	strip.difficulty.text = Kit:Text(strip.difficulty, '', 'tiny', 'lcdInk', true)
	strip.difficulty.text:SetPoint('CENTER')
	strip.mail = Kit:Led(strip, 5, false)
	strip.craft = Kit:Led(strip, 5, false)
	-- The clock on an LCD; click for the stopwatch and alarm.
	strip.clock = CreateFrame('Button', nil, strip)
	strip.clock:SetSize(44, 15)
	strip.clock.lcd = Kit:LCDPanel(strip.clock, {radius = 3})
	strip.clock.lcd:SetAllPoints()
	strip.clock.text = Kit:Text(strip.clock, '', 9, 'lcdInk', true)
	strip.clock.text:SetPoint('CENTER', 0, 0)
	strip.clock:SetScript('OnClick', function() Kit:Play('tick'); OpenClock() end)
	strip.calendar = RoundKey(strip, 'calendar', OpenCalendar, 'Calendar')
	strip.tracking = RoundKey(strip, 'search', function(key) OpenTracking(key) end, 'Tracking')
	-- Coordinates on their own LCD chip under the map.
	chip = Kit:LCDPanel(holder, {radius = 4})
	chip:SetSize(76, 16)
	chip:SetFrameLevel(map:GetFrameLevel() + 5)
	chip.text = Kit:Text(chip, '', 9, 'lcdInk', true)
	chip.text:SetPoint('CENTER', 0, 0)
	module.locationStrip = strip
	FitStrip()
	UpdateZone()
end

local function TickStrip()
	if not strip then return end
	local db = DB()
	if strip:IsShown() then
		strip.clock.text:SetText(Clock())
		Kit:SetLed(strip.mail, Plain(HasNewMail and HasNewMail()) and true or false, 'amber')
		Kit:SetLed(strip.craft, Indicator('CraftingOrderFrame'), 'blue')
		Kit:Tint(strip.calendar.icon, Invites() and 'amber' or 'ink')
		local difficulty = Difficulty()
		if difficulty ~= strip.difficulty.text:GetText() then
			strip.difficulty.text:SetText(difficulty)
			FitStrip()
		end
	end
	if chip and chip:IsShown() then
		local x, y = Coordinates()
		local decimals = Kit:Clamp(floor(tonumber(db.coordsDecimals) or 1), 0, 2)
		chip.text:SetText(x and format('%.'..decimals..'f  %.'..decimals..'f', x, y) or '--')
	end
end

local function Lamp(device, label)
	local lamp = Kit:Led(device, 5, false)
	lamp.label = Kit:Label(device, label, 'dim', 7)
	return lamp
end

-- Lamps and the difficulty chip, laid out from the right of the header.
-- squeeze: 0 everything; 1 lamps without labels; 2+ drops lamps from the
-- least needed (tracking, invites, the chip, mail) until the row clears the title.
local LayoutHeaderAt
-- Squeeze in one pass, before anything shows: each level is laid out and
-- measured at once (anchors resolve on query), and the first that clears the
-- title is kept. Re-entrant calls are ignored, so nothing can flicker.
local laying
local function LayoutHeader(device)
	if laying then return end
	laying = true
	local ok, problem = pcall(function()
		for squeeze = 0, 5 do
			LayoutHeaderAt(device, squeeze)
			local leftmost = device.headerLeft and device.headerLeft:GetLeft()
			local modelRight = device.model and device.model:GetRight()
			if not (leftmost and modelRight) then return end
			local titleRight = modelRight + 5 + (device.title:GetStringWidth() or 0) + 8
			if leftmost >= titleRight then return end
		end
	end)
	laying = nil
	if not ok then error(problem, 0) end
end

function LayoutHeaderAt(device, squeeze)
	local db = DB()
	local anchor, x = device, -12
	local function Next(region, width, gap)
		region:ClearAllPoints()
		if anchor == device then region:SetPoint('TOPRIGHT', device, 'TOPRIGHT', x, -9)
		else region:SetPoint('RIGHT', anchor, 'LEFT', -(gap or 8), 0) end
		anchor = region
	end
	for _, key in ipairs({device.trackingKey, device.calendarKey}) do
		local shown = key == device.trackingKey and db.keyTracking or db.keyCalendar
		key:SetShown(shown and true or false)
		if shown then
			key:ClearAllPoints()
			if anchor == device then key:SetPoint('TOPRIGHT', device, 'TOPRIGHT', x, -4)
			else key:SetPoint('RIGHT', anchor, 'LEFT', -4, 0) end
			anchor = key
		end
	end
	local apps = module.appsKey
	if apps then
		apps:SetShown(db.collector and true or false)
		apps.count:SetShown(db.collector and true or false)
		if db.collector then
			Next(apps)
			anchor = apps.count
		end
	end
	device.chip:SetShown(db.difficulty and device.chip.text:GetText() ~= '' and squeeze < 4)
	if device.chip:IsShown() then Next(device.chip) end
	-- Dropped first to last as the header gets tight: tracking, invites, mail.
	local drop = {tracking = squeeze >= 2, invites = squeeze >= 3, mail = squeeze >= 5}
	for _, spec in ipairs({{device.mail, db.lampMail, 'mail'}, {device.invites, db.lampInvites, 'invites'},
		{device.tracking, db.lampTracking, 'tracking'}}) do
		local lamp, shown = spec[1], (spec[2] and not drop[spec[3]]) and true or false
		Kit:ShowLed(lamp, shown)
		local labelled = shown and squeeze < 1
		lamp.label:SetShown(labelled)
		if shown then
			Next(lamp, nil, labelled and 8 or 5)
			if labelled then
				lamp.label:ClearAllPoints()
				lamp.label:SetPoint('RIGHT', lamp, 'LEFT', -3, 0)
				anchor = lamp.label
			end
		end
	end
	device.headerLeft = anchor ~= device and anchor or nil
end

local function Navigator(map)
	SetShape(map)
	local loader = CreateFrame('Frame')
	loader:RegisterEvent('ADDON_LOADED')
	loader:SetScript('OnEvent', function(_, _, name)
		if name == 'Blizzard_HybridMinimap' then SetShape(map) end
		QueueScan()
	end)
	local cluster = Cluster()
	for _, region in ipairs({_G.MinimapCompassTexture, _G.MinimapBorder, _G.MinimapBorderTop, _G.MinimapNorthTag,
		_G.MinimapCompassTextureUnderlay, cluster and cluster.BorderTop}) do
		Fade(region)
	end
	-- The readout replaces Blizzard's zone text and coordinates.
	SetPiece(_G.MinimapZoneTextButton, false)
	SetPiece(cluster and cluster.ZoneTextButton, false)
	SetPiece(_G.MiniMapWorldMapButton, false)
	local container = cluster and cluster.MinimapContainer
	SetPiece(container and container.PlayerCoords, false)
	if cluster and cluster.Tracking and cluster.Tracking.Background then Fade(cluster.Tracking.Background) end
	map:EnableMouseWheel(true)
	-- Replace, not add to, any wheel handler, so one notch is one zoom step.
	map:SetScript('OnMouseWheel', function(self, delta)
		if delta > 0 then self:SetZoom(min(self:GetZoom() + 1, self:GetZoomLevels() - 1))
		else self:SetZoom(max(self:GetZoom() - 1, 0)) end
		Kit:Play('tick')
		ZoomLater(self)
	end)

	-- Housing and display bezel behind the map, hugging it so nothing below
	-- (the quest tracker) is covered.
	local holder = map:GetParent() or UIParent
	local device = Kit:Device(holder, {model = 'NV-1', title = 'Map', corner = 16})
	device:SetPoint('TOPLEFT', map, 'TOPLEFT', -14, 30)
	device:SetPoint('BOTTOMRIGHT', map, 'BOTTOMRIGHT', 14, -14)
	device:SetFrameLevel(max(map:GetFrameLevel() - 3, 0))
	Kit:Relevel(device)
	device:EnableMouse(false)
	local screen = Kit:Screen(holder, {inset = 4, corner = 8})
	screen:SetPoint('TOPLEFT', map, 'TOPLEFT', -6, 6)
	screen:SetPoint('BOTTOMRIGHT', map, 'BOTTOMRIGHT', 6, -6)
	screen:SetFrameLevel(max(map:GetFrameLevel() - 2, 0))
	Kit:Relevel(screen)
	screen:EnableMouse(false)
	device.title:SetPoint('RIGHT', device, 'TOPLEFT', 70, -11.5)
	device.mail = Lamp(device, 'Mail')
	device.invites = Lamp(device, 'Inv')
	device.tracking = Lamp(device, 'Trk')
	device.chip = Kit:LCDPanel(device, {radius = 3})
	device.chip:SetSize(30, 13)
	device.chip.text = Kit:Text(device.chip, '', 'tiny', 'lcdInk', true)
	device.chip.text:SetPoint('CENTER', 0, 0)
	device.calendarKey = RoundKey(device, 'calendar', OpenCalendar, 'Calendar')
	device.trackingKey = RoundKey(device, 'search', function(key) OpenTracking(key) end, 'Tracking')
	module.device = device
	module.screen = screen
	-- A round map sits in the machined bezel instead of the square display.
	Bezel(map)
	if DB().collector then BuildDrawer(device) end

	-- Printed along the bottom of the display, like the dashboard's screen.
	local strip = CreateFrame('Frame', nil, map)
	strip:SetPoint('BOTTOMLEFT', 0, 0)
	strip:SetPoint('BOTTOMRIGHT', 0, 0)
	strip:SetHeight(18)
	strip:SetFrameLevel(map:GetFrameLevel() + 5)
	strip:EnableMouse(false)
	strip.shade = strip:CreateTexture(nil, 'BACKGROUND')
	strip.shade:SetAllPoints()
	strip.shade:SetColorTexture(0, 0, 0, 0.62)
	strip.zone = Kit:Label(strip, '', 'darkInk', 8)
	strip.zone:SetPoint('LEFT', 6, 0)
	strip.zone:SetWidth(map:GetWidth() * 0.52)
	strip.zone:SetJustifyH('LEFT')
	strip.zone:SetWordWrap(false)
	strip.time = Kit:Text(strip, '', 10, 'lamp', true)
	strip.time:SetPoint('RIGHT', -6, 0)
	strip.coords = Kit:Text(strip, '', 9, 'darkDim')
	strip.coords:SetPoint('RIGHT', strip.time, 'LEFT', -6, 0)
	module.strip = strip
	FitBezel()
	local function Tick()
		local db = DB()
		strip:SetShown(db.clock and true or false)
		if db.clock then
			local zone = GetMinimapZoneText and Plain(GetMinimapZoneText()) or ''
			strip.zone:SetText(strupper(zone or ''))
			strip.time:SetText(Clock())
			local x, y = Coordinates()
			local decimals = Kit:Clamp(floor(tonumber(db.coordsDecimals) or 1), 0, 2)
			strip.coords:SetText(db.coords and x and format('%.'..decimals..'f %.'..decimals..'f', x, y) or '')
		end
		Kit:SetLed(device.mail, Plain(HasNewMail and HasNewMail()) and true or false)
		Kit:SetLed(device.invites, Invites())
		Kit:Tint(device.calendarKey.icon, Invites() and 'amber' or 'ink')
		Kit:SetLed(device.tracking, Tracking())
		local difficulty = Difficulty()
		if difficulty ~= device.chip.text:GetText() then
			device.chip.text:SetText(difficulty)
			LayoutHeader(device)
		end
	end
	-- Nothing to update while the device is hidden (Alt+Z, a cinematic).
	module.ticker = C_Timer.NewTicker(0.5, function()
		if device:IsVisible() then UI:Safe(Tick) end
	end)
	module.Tick = Tick
	Tick()
	LayoutHeader(device)
end

local function Ring(map)
	SetShape(map)
	Bezel(map)
	local cluster = Cluster()
	Fade(cluster and cluster.BorderTop)
	local zoneButton = cluster and cluster.ZoneTextButton
	if zoneButton and zoneButton.BorderTop then Fade(zoneButton.BorderTop) end
	if cluster and cluster.Tracking and cluster.Tracking.Background then Fade(cluster.Tracking.Background) end
	BuildStrip(map)
	local loader = CreateFrame('Frame')
	loader:RegisterEvent('ADDON_LOADED')
	loader:SetScript('OnEvent', function(_, _, name)
		if name == 'Blizzard_HybridMinimap' then SetShape(map) end
		QueueScan()
	end)
	map:HookScript('OnMouseWheel', function(self) ZoomLater(self) end)
	if DB().collector then
		-- The apps key sits at the strip's left end, before the lamp.
		local key = BuildDrawer(strip)
		key:ClearAllPoints()
		key:SetPoint('TOPRIGHT', strip, 'TOPLEFT', -4, -4)
		key.count:Hide()
		drawer:ClearAllPoints()
		drawer:SetPoint('TOPRIGHT', strip, 'BOTTOMLEFT', -6, -4)
	end
	module.ticker = C_Timer.NewTicker(0.5, function()
		if (strip and strip:IsVisible()) or (chip and chip:IsVisible()) then UI:Safe(TickStrip) end
	end)
	module.Tick = TickStrip
	TickStrip()
end

function module:Enable()
	local map = _G.Minimap
	if not map then return end
	if UI:Style('minimap') == 'ring' then Ring(map) else Navigator(map) end
	SetSize(map)
	ApplyPieces()
	UI:Safe(ApplyEdgeKeys)
	local driver = CreateFrame('Frame')
	for _, event in ipairs({'PLAYER_ENTERING_WORLD', 'CALENDAR_UPDATE_PENDING_INVITES', 'MINIMAP_UPDATE_TRACKING', 'UPDATE_PENDING_MAIL',
		'ZONE_CHANGED', 'ZONE_CHANGED_INDOORS', 'ZONE_CHANGED_NEW_AREA'}) do
		pcall(driver.RegisterEvent, driver, event)
	end
	driver:SetScript('OnEvent', function(_, event)
		if event == 'PLAYER_ENTERING_WORLD' then
			ApplyPieces()
			QueueScan()
			C_Timer.After(3, QueueScan)
			C_Timer.After(1, function() UI:Safe(ApplyEdgeKeys) end)
		end
		if event:find('^ZONE_CHANGED') or event == 'PLAYER_ENTERING_WORLD' then UI:Safe(UpdateZone) end
		if module.Tick then UI:Safe(module.Tick) end
	end)
	QueueScan()
end

function module:Refresh()
	local map = _G.Minimap
	if not map or not module.enabled then return end
	SetShape(map)
	SetSize(map)
	ApplyPieces()
	UI:Safe(FitBezel)
	UI:Safe(FitStrip)
	UI:Safe(UpdateZone)
	UI:Safe(ApplyEdgeKeys)
	if module.device then LayoutHeader(module.device) end
	if drawer then
		PlaceApps()
		if not DB().collector and drawer:IsShown() then drawer:Hide() end
	end
	if module.Tick then UI:Safe(module.Tick) end
end

local function Seconds(v) return v == 0 and 'Never' or (v..' s') end
UI:RegisterPage('minimap', {title = 'Minimap', order = 12, cards = {
	{title = 'Style', rows = {
		{'segmented', 'Style', 'style.minimap', items = {{'navigator', 'Device'}, {'ring', 'Ring'}, {'blizzard', 'Blizzard'}}, reload = true,
			note = 'Device: the map on a display, in a housing with lamps and an LCD. Ring: the round map in a machined bezel, with a location strip.'},
		{'segmented', 'Shape', 'minimap.shape', items = {{'square', 'Square'}, {'round', 'Round'}},
			note = 'The map itself, in the Device style; a round map sits in the bezel. The Ring style is always round.'},
		{'slider', 'Size', 'minimap.size', 0, 300, 10, 'Width of the map. Off keeps the size Edit Mode gives it.',
			format = function(v) return v == 0 and 'Edit Mode' or tostring(v) end},
		{'slider', 'Zoom back out', 'minimap.zoomReset', 0, 30, 1, 'Seconds after you last zoom before the map zooms out again.', format = Seconds},
		{'note', 'Scroll on the map to zoom. Place the minimap with Edit Mode.'},
	}},
	{title = 'Location and bezel', rows = {
		{'switch', 'Location strip', 'minimap.location', 'Ring style: zone and subzone in the PvP color, the clock, lamps and keys on a glass strip. Click the zone for the world map.', since = '0.5.0'},
		{'segmented', 'Strip position', 'minimap.locationPos', items = {{'top', 'Above'}, {'bottom', 'Below'}}, since = '0.5.0'},
		{'switch', 'Coordinates LCD', 'minimap.coordsChip', 'Ring style: your position on an LCD chip under the map.', since = '0.5.0'},
		{'switch', 'Calendar key', 'minimap.keyCalendar', 'A round key for the calendar; it turns amber with an invite. Replaces Blizzard\'s button.', since = '0.5.0'},
		{'switch', 'Tracking key', 'minimap.keyTracking', 'A round key for the tracking menu. Replaces Blizzard\'s button.', since = '0.5.0'},
		{'slider', 'Bezel thickness', 'minimap.ringPx', 1, 8, 1, 'The ring around a round map, in screen pixels.', since = '0.5.0',
			format = function(v) return v..' px' end},
		{'switch', 'Edge keys', 'minimap.edgeKeys', 'The round buttons on the map edge (expansion summary, time of day) sit on round keys.', since = '0.5.0'},
	}},
	{title = 'Readout', rows = {
		{'switch', 'Readout', 'minimap.clock', 'Zone, coordinates and time along the bottom of the map.'},
		{'switch', 'Coordinates', 'minimap.coords', 'Your map position.'},
		{'slider', 'Coordinate decimals', 'minimap.coordsDecimals', 0, 2, 1},
		{'switch', '24-hour clock', 'minimap.clock24'},
		{'switch', 'Server time', 'minimap.serverTime', 'The realm\'s time instead of your computer\'s.'},
	}},
	{title = 'Lamps', rows = {
		{'switch', 'Mail', 'minimap.lampMail', 'Lit when there is new mail.'},
		{'switch', 'Calendar invites', 'minimap.lampInvites', 'Lit when an invite is waiting.'},
		{'switch', 'Tracking', 'minimap.lampTracking', 'Lit while you track something beyond town services.'},
		{'switch', 'Difficulty', 'minimap.difficulty', 'An LCD with the instance difficulty: N, H, M, M+12, LFR...'},
	}},
	{title = 'Addon buttons', rows = {
		{'switch', 'Apps drawer', 'minimap.collector', 'Addon minimap buttons gather on keys in a drawer; the Apps key opens it.', reload = true},
		{'slider', 'Keys per row', 'minimap.appsPerRow', 3, 12, 1},
	}},
	{title = 'Blizzard pieces', rows = {
		{'switch', 'Zoom buttons', 'minimap.showZoom'},
		{'switch', 'Expansion button', 'minimap.showExpansion', 'The expansion summary (renown, missions).'},
		{'switch', 'Addon compartment', 'minimap.showCompartment', 'Blizzard\'s list of addons.'},
		{'switch', 'Tracking button', 'minimap.showTracking'},
		{'switch', 'Calendar button', 'minimap.showCalendar'},
		{'switch', 'Difficulty flag', 'minimap.showDifficulty', 'Blizzard\'s own; the LCD above shows the same.'},
		{'switch', 'Mail icon', 'minimap.showMail', 'Blizzard\'s own; the mail lamp shows the same.'},
	}},
}})
