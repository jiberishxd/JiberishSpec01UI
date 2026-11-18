-- The minimap as a SPEC-01 navigator: the map set in the reference's recessed
-- black display (corner marks at its corners), in a housing printed "NV-1 MAP",
-- with a readout LCD under the display: the zone (with its PvP lamp), your
-- coordinates and the time, each in a cell of its own, and a day/night disc by
-- the clock. The header carries lamps for mail, calendar invites and active
-- tracking, a small LCD with the instance difficulty and the keys: Apps (the
-- "NV-2 Apps" drawer the addon minimap buttons gather into), the calendar and
-- the tracking menu.
--
-- 'navigator': all of the above. 'ring': the round map in a machined bezel,
-- with a location strip (zone, clock, calendar and tracking keys, lamps) and a
-- coordinates LCD. A round map in the navigator gets the same bezel.
-- The minimap cluster stays where Edit Mode puts it; Blizzard's own pieces
-- (zone text, clock, calendar, tracking, zoom buttons, the expansion button...)
-- are only faded and made unclickable, never reparented; our keys click them.
--
-- Everything we draw that takes the mouse sits above the map's frame level:
-- MinimapCluster itself takes the mouse over its whole header row, so a key at
-- or below the cluster's level never sees a click.
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
	ringPx = 3, edgeKeys = true,
	-- The clock prints in LCD ink ('lcd') or the key color ('key'); a disc by
	-- it shows day or night. showDayNight keeps Blizzard's own day/night disc
	-- on the Device (the Ring keeps it on its bezel).
	clockInk = 'lcd', dayNight = true, showDayNight = false})
-- defaults:end

-- The ring style is always round; the navigator follows the shape setting.
local function Round() return UI:Style('minimap') == 'ring' or DB().shape == 'round' end
local function Mask() return Kit.media..(Round() and 'mask-round.tga' or 'mask-square.tga') end

-- Pixels -------------------------------------------------------------------------------
-- Small round textures snap to the pixel grid, so a lamp is a full disc and
-- never a smeared blob at any UI scale.
local function SnapTexture(texture)
	if texture and texture.SetSnapToPixelGrid then
		texture:SetSnapToPixelGrid(true)
		texture:SetTexelSnappingBias(0)
	end
end

-- Lamps sized to a whole number of physical pixels (about `units` UI units).
local pixelLamps = setmetatable({}, {__mode = 'k'}) -- lamp -> units
local function FitLamp(led)
	local units, parent = pixelLamps[led], led:GetParent()
	if not (units and parent) then return end
	local size = max(UI.Pixel.Snap(parent, units), UI.Pixel.Px(parent, 3))
	led:SetSize(size, size)
	if led.glow then Kit:FitSprite(led.glow, size, size) end
end
local function PixelLamp(parent, units, on)
	local led = Kit:Led(parent, units, on)
	SnapTexture(led)
	SnapTexture(led.glow)
	pixelLamps[led] = units
	FitLamp(led)
	return led
end
local function RefitLamps()
	for led in pairs(pixelLamps) do FitLamp(led) end
end

-- A lamp that comes on blinks three times first (not with Reduce motion).
local function Blip(led)
	if Kit:Reduced() or not Kit:Faithful() then return end
	Kit:Animate(Kit.MotionTag('mm-blip', led), 0.6, 0, 1, function(_, progress)
		led:SetAlpha(floor(progress * 6) % 2 == 0 and 1 or 0.2)
	end, function() led:SetAlpha(1) end, 'linear')
end
local function SetLamp(led, on, token)
	on = on and true or false
	if on and not led.on and led.kitWasSet then Blip(led) end
	led.kitWasSet = true
	Kit:SetLed(led, on, token)
end

-- A tooltip on one of our keys or cells; build(tooltip) fills it.
local function Tip(frame, build)
	frame:HookScript('OnEnter', function(self)
		GameTooltip:SetOwner(self, 'ANCHOR_BOTTOMLEFT')
		build(GameTooltip, self)
		GameTooltip:Show()
	end)
	frame:HookScript('OnLeave', function(self)
		if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
	end)
end
local function Dim(tooltip, text) tooltip:AddLine(text, 0.62, 0.62, 0.6, true) end

-- Blizzard's pieces --------------------------------------------------------------------
-- Each piece has a switch; off, it is faded and stops taking the mouse, and
-- stays that way when Blizzard shows it again. keepMouse: a piece that never
-- took the mouse (the day/night disc, the coordinates) is left as it is.
local pieces = setmetatable({}, {__mode = 'k'}) -- frame -> hidden?
local function Hold(frame)
	if pieces[frame] then frame:SetAlpha(0) end
end
local hookedPiece = setmetatable({}, {__mode = 'k'})
local function SetPiece(frame, shown, keepMouse)
	if Forbidden(frame) or not frame.SetAlpha then return end
	pieces[frame] = not shown
	if not hookedPiece[frame] then
		hookedPiece[frame] = true
		hooksecurefunc(frame, 'Show', Hold)
		hooksecurefunc(frame, 'SetAlpha', function(self) if pieces[self] and not IsSecret(self:GetAlpha()) and self:GetAlpha() > 0 then self:SetAlpha(0) end end)
	end
	frame:SetAlpha(shown and 1 or 0)
	if not keepMouse and frame.EnableMouse and not (frame.IsProtected and frame:IsProtected() and InCombatLockdown()) then
		pcall(frame.EnableMouse, frame, shown and true or false)
	end
end

local function Cluster() return _G.MinimapCluster end
-- Blizzard's external event button (Forever), on the map's left edge.
local function EventButton() return _G.MinimapBackdrop and _G.MinimapBackdrop.ExternalEventURLButton end
local drawer -- the apps drawer, once built

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
	SetPiece(container and container.PlayerCoords, not coords, true)
	SetPiece(cluster and cluster.InstanceDifficulty, db.showDifficulty)
	SetPiece(_G.MiniMapInstanceDifficulty, db.showDifficulty)
	local indicators = cluster and cluster.IndicatorFrame
	SetPiece(indicators and indicators.MailFrame, db.showMail)
	SetPiece(_G.MiniMapMailFrame, db.showMail)
	-- The day/night disc sits on a round map's edge; on the Device's square
	-- display it would cover the corner, so the readout's disc replaces it.
	SetPiece(cluster and cluster.DielFrame, ring or db.showDayNight, true)
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

-- The clock prints in LCD ink, or in the key color.
local function ClockToken() return DB().clockInk == 'key' and 'accent' or 'lcdInk' end

-- Day or night: the game's own cycle where it has one (Forever), else the realm's hour.
local function IsDay()
	local api = C_DateAndTime
	if api and api.IsDayTime then
		local ok, day = pcall(api.IsDayTime)
		day = ok and Plain(day)
		if type(day) == 'boolean' then return day end
	end
	local hour = GetGameTime and Plain(GetGameTime())
	if type(hour) == 'number' then return hour >= 6 and hour < 18 end
	return true
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

-- Tracking can be switched off by the game's rules (some realms have no tracking at all).
local function TrackingAllowed()
	local rules = C_GameRules
	local rule = Enum and Enum.GameRule and Enum.GameRule.IngameTrackingDisabled
	if rules and rules.IsGameRuleActive and rule then
		local ok, active = pcall(rules.IsGameRuleActive, rule)
		if ok and Plain(active) == true then return false end
	end
	return C_Minimap and C_Minimap.GetNumTrackingTypes and true or false
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

local function InviteCount()
	local count = C_Calendar and C_Calendar.GetNumPendingInvites and Plain(C_Calendar.GetNumPendingInvites())
	return type(count) == 'number' and count or 0
end
local function Invites() return InviteCount() > 0 end

-- A new external event (Forever) lights the Apps key amber.
local function EventIsNew()
	local api = C_ExternalEventURL
	if not api then return false end
	local function Call(func)
		if type(func) ~= 'function' then return nil end
		local ok, value = pcall(func)
		if ok then return Plain(value) end
	end
	if Call(api.CanShow) == false then return false end
	return Call(api.HasURL) == true and Call(api.IsNew) == true
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
local collected, order = setmetatable({}, {__mode = 'k'}), {}
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

local function Shown()
	local shown = {}
	for _, button in ipairs(order) do
		if button:IsShown() then shown[#shown + 1] = button end
	end
	return shown
end

-- The Apps key's lamp: lit while the drawer is open, amber for a new event.
local appsLampState
local function UpdateAppsLamp()
	local key = module.appsKey
	if not key then return end
	local state = (drawer and drawer:IsShown() and not drawer.kitClosing) and 'open' or (EventIsNew() and 'new') or 'off'
	if state == appsLampState then return end
	appsLampState = state
	SetLamp(key.lamp, state ~= 'off', state == 'new' and 'amber' or nil)
end

local function PlaceApps()
	if not drawer then return end
	local perRow = Kit:Clamp(floor(DB().appsPerRow or 6), 3, 12)
	local shown = Shown()
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
	drawer:SetSize(max(20 + across * (APP + 4) - 4, 120), 26 + lines * (APP + 4) - 4 + 10)
	drawer.empty:SetShown(#shown == 0)
	if module.appsKey then module.appsKey.count:SetText(#shown > 0 and #shown or '') end
end
local placeQueued
local function QueuePlace()
	if placeQueued then return end
	placeQueued = true
	C_Timer.After(0, function() placeQueued = nil; UI:Safe(PlaceApps) end)
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

local function Slot()
	local slot = CreateFrame('Frame', nil, drawer)
	slot:SetSize(APP, APP)
	slot.skin = Kit:Skin(slot, 'key', 'BACKGROUND', 0)
	slot.skin.kitMaxCorner = 7
	return slot
end

local function Collect(button)
	if not IsApp(button) then return end
	collected[button] = true
	order[#order + 1] = button
	local slot = Slot()
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
	button:HookScript('OnShow', QueuePlace)
	button:HookScript('OnHide', QueuePlace)
	Seat(button)
end

-- Blizzard's external event button (Forever) moves onto a key in the drawer,
-- like an addon button: it is a plain Blizzard button (no Edit Mode system,
-- not protected), and it has to stay Blizzard's own, since only the game's own
-- click may open the event's page (C_ExternalEventURL.LaunchURL is restricted).
-- Its ring and its "new" swirl give way to the key; the Apps lamp shows "new".
local eventAdopted
local function AdoptEventButton()
	local button = EventButton()
	if eventAdopted or not drawer or Forbidden(button) or (button.IsProtected and button:IsProtected()) then return end
	eventAdopted = true
	collected[button] = true
	button.kitSlot = Slot()
	button:SetScale((APP - 4) / 32)
	if button.Border and button.Border.SetAlpha then button.Border:SetAlpha(0) end
	if button.SpellEffectModelScene and button.SpellEffectModelScene.SetAlpha then button.SpellEffectModelScene:SetAlpha(0) end
	hooksecurefunc(button, 'SetPoint', function(self)
		if self.kitSeating then return end
		C_Timer.After(0, function() UI:Safe(Seat, self) end)
	end)
	hooksecurefunc(button, 'SetParent', function(self, parent)
		if parent ~= self.kitSlot then C_Timer.After(0, function() UI:Safe(Seat, self) end) end
	end)
	button:HookScript('OnShow', QueuePlace)
	button:HookScript('OnHide', QueuePlace)
	button:HookScript('OnMouseDown', function(_, mouse) if mouse == 'LeftButton' then Kit:Play('down') end end)
	button:HookScript('OnMouseUp', function(_, mouse) if mouse == 'LeftButton' then Kit:Play('up') end end)
	button:HookScript('OnClick', function() C_Timer.After(0.2, function() appsLampState = nil; UI:Safe(UpdateAppsLamp) end) end)
	table.insert(order, 1, button)
	Seat(button)
end

local function Scan()
	if not drawer then return end
	AdoptEventButton()
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

local KEY_H = 15 -- header and strip keys

-- device: what the drawer opens beside; keyParent: where the Apps key goes.
local function BuildDrawer(device, keyParent)
	drawer = Kit:Device(UIParent, {model = 'NV-2', title = 'Apps', radius = 12, width = 120, height = 60})
	drawer:SetFrameStrata('MEDIUM')
	drawer:SetFrameLevel(device:GetFrameLevel() + 20)
	Kit:Relevel(drawer)
	drawer:EnableMouse(true)
	drawer:SetPoint('TOPRIGHT', device, 'TOPLEFT', -6, 0)
	drawer.empty = Kit:Label(drawer, 'No addon buttons', 'dim', 8)
	drawer.empty:SetPoint('TOPLEFT', 12, -30)
	drawer:Hide()
	drawer:HookScript('OnShow', function() appsLampState = nil; UI:Safe(UpdateAppsLamp) end)
	drawer:HookScript('OnHide', function() appsLampState = nil; UI:Safe(UpdateAppsLamp) end)
	-- The Apps key: a lamp (open, or amber for a new event), its legend and the count.
	local key = Kit:Key(keyParent, {width = 46, height = KEY_H, text = 'Apps', textSize = 7})
	key:RegisterForClicks('LeftButtonUp')
	key.lamp = PixelLamp(key.face, 4, false)
	key.lamp:SetPoint('LEFT', key.face, 'LEFT', 5, 0)
	key.text:ClearAllPoints()
	key.text:SetPoint('LEFT', key.lamp, 'RIGHT', 3, 0)
	key.count = Kit:Text(key.face, '', 7, 'dim', true)
	key.count:SetPoint('RIGHT', key.face, 'RIGHT', -5, 0)
	key.navWidth = 46
	key.onClick = function()
		if drawer:IsShown() and not drawer.kitClosing then
			Kit:Close(drawer)
		else
			Kit:ResetRest(drawer)
			PlaceApps()
			Kit:Open(drawer)
			Kit:Play('open')
		end
		appsLampState = nil
		UpdateAppsLamp()
	end
	Tip(key, function(tooltip)
		local count = #Shown()
		tooltip:SetText('Apps')
		Dim(tooltip, count > 0 and (count..(count == 1 and ' button' or ' buttons')) or 'No addon buttons')
		if EventIsNew() then tooltip:AddLine('New event', 1, 0.66, 0) end
	end)
	module.appsKey = key
	local ldbi = LibStub and LibStub('LibDBIcon-1.0', true)
	if ldbi and type(ldbi.RegisterCallback) == 'function' then
		pcall(ldbi.RegisterCallback, module, 'LibDBIcon_IconCreated', QueueScan)
	end
	UpdateAppsLamp()
	return key
end

-- Shape, size, zoom ---------------------------------------------------------------------
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
	if _G.ToggleCalendar then return _G.ToggleCalendar() end
	local button = _G.GameTimeFrame
	if button and button.Click and not Forbidden(button) then button:Click() end
end

-- Tracking types as plain {index, name, active}, in the game's order, filtered
-- the way the game's own menu filters them. The API returns a table on current
-- clients and loose values on older ones.
local function TrackingListed(index)
	local api, constants = C_Minimap, _G.MinimapConstants
	if not (api.GetTrackingFilter and type(constants) == 'table' and type(constants.OPTIONAL_FILTERS) == 'table') then return true end
	if GetCVarBool and GetCVarBool('minimapTrackingShowAll') then return true end
	local ok, filter = pcall(api.GetTrackingFilter, index)
	if not ok or type(filter) ~= 'table' then return false end
	local id, spell = Plain(filter.filterID), Plain(filter.spellID)
	return (id ~= nil and constants.OPTIONAL_FILTERS[id]) or spell ~= nil
end

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
		if type(name) == 'string' and TrackingListed(index) then
			list[#list + 1] = {index = index, name = name, active = active and true or false}
		end
	end
	return list
end

local function TrackingActive(index)
	local ok, info, _, active = pcall(C_Minimap.GetTrackingInfo, index)
	if ok and type(info) == 'table' then active = info.active end
	return Plain(active) and true or false
end

local function SetTracking(index, on)
	local util = _G.MinimapUtil
	if util and util.SetTrackingFilterByFilterIndex and pcall(util.SetTrackingFilterByFilterIndex, index, on) then return end
	if C_Minimap.SetTracking then pcall(C_Minimap.SetTracking, index, on) end
end

-- The tracking menu, built by us from the tracking API, so no Blizzard menu
-- frame is ever opened or moved from addon code. A spell's tracking takes a
-- moment to report back, so the menu shows what was asked for meanwhile.
-- Without the menu API, the game's own button opens its menu where the game puts it.
local wanted = {}
local function OpenTracking(anchor)
	local list = TrackingList()
	local api = C_Minimap
	if list and MenuUtil and MenuUtil.CreateContextMenu and api and (api.SetTracking or _G.MinimapUtil) then
		wipe(wanted)
		MenuUtil.CreateContextMenu(anchor, function(_, root)
			root:CreateTitle('Tracking')
			if #list == 0 then root:CreateTitle('Nothing to track') end
			for _, entry in ipairs(list) do
				root:CreateCheckbox(entry.name, function()
					if wanted[entry.index] ~= nil then return wanted[entry.index] end
					return TrackingActive(entry.index)
				end, function()
					local on = wanted[entry.index]
					if on == nil then on = TrackingActive(entry.index) end
					wanted[entry.index] = not on
					SetTracking(entry.index, not on)
					Kit:Play(on and 'latch-up' or 'latch-down')
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
	if _G.TimeManager_Toggle then return _G.TimeManager_Toggle() end
	local button = _G.TimeManagerClockButton
	if button and button.Click and not Forbidden(button) then button:Click() end
end

local function OpenMap()
	if _G.ToggleWorldMap then _G.ToggleWorldMap() end
end

-- Key tooltips.
local function CalendarTip(tooltip)
	tooltip:SetText('Calendar')
	local count = InviteCount()
	if count > 0 then tooltip:AddLine(count..(count == 1 and ' invite waiting' or ' invites waiting'), 1, 0.66, 0) end
	Dim(tooltip, date('%A %d %B'))
end
local function TrackingTip(tooltip)
	tooltip:SetText('Tracking')
	local any
	for _, entry in ipairs(TrackingList() or {}) do
		if entry.active then any = true; Dim(tooltip, entry.name) end
	end
	if not any then Dim(tooltip, 'Nothing tracked') end
end

-- A small round key with an icon (the ring's strip).
local function RoundKey(parent, icon, onClick, tip)
	local key = Kit:Key(parent, {round = true, width = 16, height = 16, icon = icon, iconSize = 8})
	key:RegisterForClicks('LeftButtonUp')
	key.onClick = function(self) UI:Safe(onClick, self) end
	if tip then Tip(key, tip) end
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
	SnapTexture(bezel.lamp)
	SnapTexture(bezel.lamp.glow)
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
		local alpha = button:GetAlpha()
		key:SetShown(button:IsShown() and not IsSecret(alpha) and alpha > 0)
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
	-- The day/night disc stays on the ring's bezel; the Device reads it on its LCD.
	if UI:Style('minimap') == 'ring' then UI:Safe(EdgeKey, cluster and cluster.DielFrame) end
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
	Next(strip.tracking, db.keyTracking and TrackingAllowed())
	Next(strip.calendar, db.keyCalendar)
	Next(strip.clock, db.clock)
	Next(strip.craft, db.lampMail)
	Next(strip.mail, db.lampMail)
	-- An empty FontString reads back as nil, so the shown text is kept here.
	Next(strip.difficulty, db.difficulty and (strip.difficultyText or '') ~= '')
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
	strip.lamp = PixelLamp(strip, 5, true)
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
	strip.difficultyText = ''
	strip.mail = PixelLamp(strip, 5, false)
	strip.craft = PixelLamp(strip, 5, false)
	-- The clock on an LCD; click for the stopwatch and alarm.
	strip.clock = CreateFrame('Button', nil, strip)
	strip.clock:SetSize(44, 15)
	strip.clock:RegisterForClicks('LeftButtonUp')
	strip.clock.lcd = Kit:LCDPanel(strip.clock, {radius = 3})
	strip.clock.lcd:SetAllPoints()
	strip.clock.text = Kit:Text(strip.clock, '', 9, ClockToken(), true)
	strip.clock.text:SetPoint('CENTER', 0, 0)
	strip.clock:SetScript('OnClick', function() Kit:Play('tick'); OpenClock() end)
	strip.calendar = RoundKey(strip, 'calendar', OpenCalendar, CalendarTip)
	strip.tracking = RoundKey(strip, 'search', function(key) OpenTracking(key) end, TrackingTip)
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
		SetLamp(strip.mail, Plain(HasNewMail and HasNewMail()) and true or false, 'amber')
		SetLamp(strip.craft, Indicator('CraftingOrderFrame'), 'blue')
		Kit:Tint(strip.calendar.icon, Invites() and 'amber' or 'ink')
		local difficulty = Difficulty()
		if difficulty ~= strip.difficultyText then
			strip.difficultyText = difficulty
			strip.difficulty.text:SetText(difficulty)
			FitStrip()
		end
	end
	if chip and chip:IsShown() then
		local x, y = Coordinates()
		local decimals = Kit:Clamp(floor(tonumber(db.coordsDecimals) or 1), 0, 2)
		chip.text:SetText(x and format('%.'..decimals..'f  %.'..decimals..'f', x, y) or '--')
	end
	UpdateAppsLamp()
end

-- The navigator ---------------------------------------------------------------------------
-- In UI units, snapped to whole physical pixels as they are laid out: the
-- screen's bezel round the map (and the black margin inside it), the housing's
-- gutter round the screen and under the readout, the printed header above and
-- the gap and readout LCD below.
local NAV = {bezel = 6, inset = 3, gutter = 7, header = 23, gap = 5, readout = 16, keyGap = 4, lamp = 5, chipW = 26, chipH = 13}

local LayoutHeaderNow, LayoutReadout, FitNavigator
local laying
-- The header is laid out in one pass, from measured widths: nothing is
-- shown, measured and moved again, and a call made while it runs is ignored,
-- so it can't flicker. It runs when something it shows changes, never per tick.
local function LayoutHeader(device)
	if laying or not device then return end
	laying = true
	local ok, problem = pcall(LayoutHeaderNow, device)
	laying = nil
	if not ok then error(problem, 0) end
end

function LayoutHeaderNow(device)
	local db, Snap = DB(), UI.Pixel.Snap
	local width = device:GetWidth()
	if IsSecret(width) or not width or width <= 0 then return end
	local g = Snap(device, NAV.gutter)
	local function Top(height) return -Snap(device, (NAV.header - height) / 2) end
	-- The printed name on the left, never cut: status lamp, model, title.
	device.lamp:ClearAllPoints()
	device.lamp:SetPoint('TOPLEFT', device, 'TOPLEFT', g, Top(device.lamp:GetHeight()))
	device.title:ClearAllPoints()
	device.title:SetPoint('LEFT', device.model, 'RIGHT', 4, 0)
	local left = g + device.lamp:GetWidth() + 5 + (device.model:GetStringWidth() or 0) + 4 + (device.title:GetStringWidth() or 0) + 10
	-- Keys from the right: tracking, calendar, apps.
	local x = g
	for _, entry in ipairs({{device.trackingKey, db.keyTracking and TrackingAllowed()}, {device.calendarKey, db.keyCalendar},
		{module.appsKey, db.collector}}) do
		local key = entry[1]
		if key then
			local shown = entry[2] and true or false
			key:SetShown(shown)
			if shown then
				key:SetSize(Snap(device, key.navWidth or 18), Snap(device, KEY_H))
				key:ClearAllPoints()
				key:SetPoint('TOPRIGHT', device, 'TOPRIGHT', -x, Top(key:GetHeight()))
				x = x + key:GetWidth() + Snap(device, NAV.keyGap)
			end
		end
	end
	x = x + Snap(device, 4)
	-- Then the difficulty LCD and the lamps, which give way as room runs out:
	-- first their labels, then tracking, invites, the LCD and mail.
	local chipFrame = device.chip
	chipFrame:SetSize(Snap(device, NAV.chipW), Snap(device, NAV.chipH))
	local chipShown = db.difficulty and (device.difficulty or '') ~= ''
	local lamps = {{device.tracking, db.lampTracking and TrackingAllowed(), 2}, {device.invites, db.lampInvites, 3}, {device.mail, db.lampMail, 5}}
	local function Need(squeeze)
		local need = x
		if chipShown and squeeze < 4 then need = need + chipFrame:GetWidth() + 6 end
		for _, spec in ipairs(lamps) do
			if spec[2] and squeeze < spec[3] then
				need = need + spec[1]:GetWidth() + (squeeze < 1 and (3 + (spec[1].label:GetStringWidth() or 0) + 8) or 5)
			end
		end
		return need
	end
	local squeeze = 0
	while squeeze < 6 and left + Need(squeeze) > width do squeeze = squeeze + 1 end
	chipFrame:SetShown(chipShown and squeeze < 4 and true or false)
	if chipFrame:IsShown() then
		chipFrame:ClearAllPoints()
		chipFrame:SetPoint('TOPRIGHT', device, 'TOPRIGHT', -x, Top(chipFrame:GetHeight()))
		x = x + chipFrame:GetWidth() + 6
	end
	local lampsFrom = x
	for _, spec in ipairs(lamps) do
		local lamp = spec[1]
		local shown = spec[2] and squeeze < spec[3] and true or false
		local labelled = shown and squeeze < 1
		Kit:ShowLed(lamp, shown)
		lamp.label:SetShown(labelled)
		if shown then
			lamp:ClearAllPoints()
			lamp:SetPoint('TOPRIGHT', device, 'TOPRIGHT', -x, Top(lamp:GetHeight()))
			x = x + lamp:GetWidth()
			if labelled then
				lamp.label:ClearAllPoints()
				lamp.label:SetPoint('RIGHT', lamp, 'LEFT', -3, 0)
				x = x + 3 + (lamp.label:GetStringWidth() or 0) + 8
			else
				x = x + 5
			end
		end
	end
	-- Hovering the lamps names them (their labels are the first thing to go).
	local hit = device.lampsHit
	hit:SetShown(x > lampsFrom)
	if x > lampsFrom then
		hit:ClearAllPoints()
		hit:SetPoint('TOPRIGHT', device, 'TOPRIGHT', -lampsFrom + 3, -Snap(device, 3))
		hit:SetSize(x - lampsFrom, Snap(device, NAV.header - 6))
	end
end

-- Measure a template in a font string's own font, then put its text back.
local function Measure(fontString, template)
	local text = fontString:GetText()
	fontString:SetText(template)
	local width = fontString:GetStringWidth() or 0
	fontString:SetText(text or '')
	return width
end

-- The readout's fixed columns, right to left: the clock (with the day/night
-- disc), the coordinates, then the zone, which takes what is left and ends in
-- an ellipsis. Cells are sized from templates, so the digits never push them.
function LayoutReadout(device)
	local readout, db = device.readout, DB()
	if not readout:IsShown() then return end
	local width, height = readout:GetSize()
	if IsSecret(width) or IsSecret(height) or not width or width <= 0 then return end
	local Snap, Px = UI.Pixel.Snap, UI.Pixel.Px
	local pad, px = Snap(device, 5), Px(device, 1)
	local function Middle(size) return -Snap(device, (height - size) / 2) end
	-- Clock: the unlit digits behind it, and the disc at the cell's left.
	local template = db.clock24 and '00:00' or '00:00 PM'
	readout.ghost:SetText((template:gsub('%d', '8')))
	local clockWidth = Measure(readout.clockText, template)
	local disc = Snap(device, 7)
	local day = db.dayNight and true or false
	readout.disc:SetShown(day)
	readout.discShade:SetShown(day and readout.night or false)
	readout.disc:SetSize(disc, disc)
	readout.discShade:SetSize(disc, disc)
	local cell = readout.clockCell
	cell:ClearAllPoints()
	cell:SetPoint('TOPRIGHT', readout, 'TOPRIGHT', 0, 0)
	cell:SetPoint('BOTTOMRIGHT', readout, 'BOTTOMRIGHT', 0, 0)
	cell:SetWidth(Snap(device, clockWidth + pad * 2 + (day and disc + 4 or 0) + 1))
	readout.clockText:ClearAllPoints()
	readout.clockText:SetPoint('RIGHT', cell, 'RIGHT', -pad, 0)
	readout.ghost:ClearAllPoints()
	readout.ghost:SetPoint('RIGHT', cell, 'RIGHT', -pad, 0)
	readout.disc:ClearAllPoints()
	readout.disc:SetPoint('TOPLEFT', cell, 'TOPLEFT', pad, Middle(disc))
	-- The night's crescent: the LCD's own gray over the disc, a little up and right.
	readout.discShade:ClearAllPoints()
	readout.discShade:SetPoint('TOPLEFT', readout.disc, 'TOPLEFT', Snap(device, 2), Snap(device, 2))
	Kit:Tint(readout.clockText, ClockToken())
	local right = cell
	-- Coordinates.
	local coords = db.coords and true or false
	readout.coordsCell:SetShown(coords)
	readout.rules[2]:SetShown(coords)
	if coords then
		local decimals = Kit:Clamp(floor(tonumber(db.coordsDecimals) or 1), 0, 2)
		local digits = decimals > 0 and ('00.'..strrep('0', decimals)) or '00'
		local coordsCell = readout.coordsCell
		coordsCell:ClearAllPoints()
		coordsCell:SetPoint('TOPRIGHT', cell, 'TOPLEFT', 0, 0)
		coordsCell:SetPoint('BOTTOMRIGHT', cell, 'BOTTOMLEFT', 0, 0)
		coordsCell:SetWidth(Snap(device, Measure(readout.coordsText, digits..' '..digits) + pad * 2))
		readout.coordsText:ClearAllPoints()
		readout.coordsText:SetPoint('CENTER', coordsCell, 'CENTER', 0, 0)
		right = coordsCell
	end
	-- Hairline rules between the cells.
	local inset = Snap(device, 3)
	for index, frame in ipairs({cell, readout.coordsCell}) do
		local rule = readout.rules[index]
		rule:ClearAllPoints()
		rule:SetPoint('TOPRIGHT', frame, 'TOPLEFT', 0, -inset)
		rule:SetPoint('BOTTOMRIGHT', frame, 'BOTTOMLEFT', 0, inset)
		rule:SetWidth(px)
	end
	readout.rules[1]:Show()
	-- The zone: its PvP lamp and the name, cut with an ellipsis.
	local zone = readout.zoneCell
	zone:ClearAllPoints()
	zone:SetPoint('TOPLEFT', readout, 'TOPLEFT', 0, 0)
	zone:SetPoint('BOTTOMRIGHT', right, 'BOTTOMLEFT', 0, 0)
	readout.lamp:ClearAllPoints()
	readout.lamp:SetPoint('TOPLEFT', zone, 'TOPLEFT', pad, Middle(readout.lamp:GetHeight()))
	readout.zoneText:ClearAllPoints()
	readout.zoneText:SetPoint('LEFT', readout.lamp, 'RIGHT', 4, 0)
	readout.zoneText:SetPoint('RIGHT', zone, 'RIGHT', -pad, 0)
	-- Print the clock and coordinates again on the next tick.
	readout.last.clock, readout.last.coords = nil, nil
end

-- Four corner marks just inside the map's corners, one physical pixel thick.
local function FitMarks(device)
	local marks = device.marks
	local shown = not Round()
	marks:SetShown(shown)
	if not shown then return end
	local Snap, Px = UI.Pixel.Snap, UI.Pixel.Px
	local arm, inset, px = Snap(marks, 7), Snap(marks, 3), Px(marks, 1)
	for point, pair in pairs(marks.corners) do
		local sx = point:find('LEFT') and 1 or -1
		local sy = point:find('TOP') and -1 or 1
		for index, line in ipairs(pair) do
			line:ClearAllPoints()
			line:SetPoint(point, marks, point, sx * inset, sy * inset)
			if index == 1 then line:SetSize(arm, px) else line:SetSize(px, arm) end
		end
	end
end

-- The device around the map: the screen's bezel, the housing, the readout.
-- Runs on build, on Refresh and when the UI scale changes; never per tick.
function FitNavigator()
	local device, screen, map = module.device, module.screen, _G.Minimap
	if not (device and screen and map) then return end
	local db, Snap, Px = DB(), UI.Pixel.Snap, UI.Pixel.Px
	local b = Snap(device, NAV.bezel)
	-- A round map in the bezel: the (hidden) screen's rect sits just outside its ring.
	if Round() then b = Px(map, Kit:Clamp(floor(tonumber(db.ringPx) or 3), 1, 8) + 1) + Snap(device, 3) end
	local g, gap = Snap(device, NAV.gutter), Snap(device, NAV.gap)
	screen:ClearAllPoints()
	screen:SetPoint('TOPLEFT', map, 'TOPLEFT', -b, b)
	screen:SetPoint('BOTTOMRIGHT', map, 'BOTTOMRIGHT', b, -b)
	local readout = device.readout
	local shown = db.clock and true or false
	readout:SetShown(shown)
	local bottom = screen
	if shown then
		readout:ClearAllPoints()
		readout:SetPoint('TOPLEFT', screen, 'BOTTOMLEFT', 0, -gap)
		readout:SetPoint('TOPRIGHT', screen, 'BOTTOMRIGHT', 0, -gap)
		readout:SetHeight(Snap(device, NAV.readout))
		bottom = readout
	end
	device:ClearAllPoints()
	device:SetPoint('TOPLEFT', screen, 'TOPLEFT', -g, Snap(device, NAV.header))
	device:SetPoint('BOTTOMRIGHT', bottom, 'BOTTOMRIGHT', g, -g)
	RefitLamps()
	FitMarks(device)
	LayoutHeader(device)
	LayoutReadout(device)
end

local function HeaderLamp(parent, label)
	local lamp = PixelLamp(parent, NAV.lamp, false)
	lamp.label = Kit:Label(parent, label, 'dim', 7)
	return lamp
end

local function LampsTip(tooltip)
	local function Row(label, lit, text)
		local v = lit and 1 or 0.62
		tooltip:AddDoubleLine(label, text, 0.9, 0.9, 0.88, v, lit and 0.66 or v, lit and 0 or v)
	end
	local db, count = DB(), InviteCount()
	tooltip:SetText('NV-1 Map')
	if db.lampMail then
		local mail = Plain(HasNewMail and HasNewMail()) and true or false
		Row('Mail', mail, mail and 'New mail' or 'None')
	end
	if db.lampInvites then Row('Invites', count > 0, count > 0 and tostring(count) or 'None') end
	if db.lampTracking and TrackingAllowed() then
		local on = Tracking()
		Row('Tracking', on, on and 'On' or 'Town services')
	end
	local device = module.device
	if device and (device.difficulty or '') ~= '' then Row('Difficulty', false, device.difficulty) end
end

local function HeaderKey(parent, icon, onClick, tip)
	local key = Kit:Key(parent, {width = 18, height = KEY_H, icon = icon, iconSize = 9})
	key:RegisterForClicks('LeftButtonUp')
	key.navWidth = 18
	key.onClick = function(self) UI:Safe(onClick, self) end
	Tip(key, tip)
	return key
end

local function NavReadout(device)
	local readout = Kit:LCDPanel(device.controls, {radius = 3})
	device.readout = readout
	readout.last = {}
	-- Zone cell: click for the world map.
	local zone = CreateFrame('Button', nil, readout)
	zone:RegisterForClicks('LeftButtonUp')
	zone:SetScript('OnClick', function() Kit:Play('tick'); OpenMap() end)
	Tip(zone, function(tooltip)
		local name = Plain(GetZoneText and GetZoneText()) or ''
		local sub = Plain(GetSubZoneText and GetSubZoneText()) or ''
		tooltip:SetText(name ~= '' and name or (readout.last.zone or ''))
		if sub ~= '' and sub ~= name then Dim(tooltip, sub) end
		Dim(tooltip, 'Click for the world map')
	end)
	readout.zoneCell = zone
	readout.lamp = PixelLamp(zone, NAV.lamp, false)
	readout.zoneText = Kit:Text(zone, '', 8, 'lcdInk', true)
	readout.zoneText:SetJustifyH('LEFT')
	readout.zoneText:SetWordWrap(false)
	-- Coordinates cell.
	readout.coordsCell = CreateFrame('Frame', nil, readout)
	readout.coordsText = Kit:Text(readout.coordsCell, '', 8, 'lcdInk')
	readout.coordsText:SetJustifyH('CENTER')
	-- Clock cell, with the unlit digits behind and the day/night disc: click for the stopwatch and alarm.
	local clock = CreateFrame('Button', nil, readout)
	clock:RegisterForClicks('LeftButtonUp')
	clock:SetScript('OnClick', function() Kit:Play('tick'); OpenClock() end)
	Tip(clock, function(tooltip)
		tooltip:SetText(DB().dayNight and (IsDay() and 'Day' or 'Night') or 'Clock')
		Dim(tooltip, 'Local '..(DB().clock24 and date('%H:%M') or (date('%I:%M %p'):gsub('^0', ''))))
		local hour, minute = GetGameTime()
		if type(Plain(hour)) == 'number' and type(Plain(minute)) == 'number' then Dim(tooltip, format('Realm %02d:%02d', hour, minute)) end
		Dim(tooltip, 'Click for the stopwatch and alarms')
	end)
	readout.clockCell = clock
	readout.ghost = Kit:Ghost(Kit:Text(clock, '', 9, 'lcdGhost', true))
	readout.ghost:SetDrawLayer('ARTWORK', 0) -- always under the lit digits
	readout.ghost:SetJustifyH('RIGHT')
	readout.clockText = Kit:Text(clock, '', 9, ClockToken(), true)
	readout.clockText:SetJustifyH('RIGHT')
	readout.disc = Kit:Texture(clock, 'circle', 'OVERLAY', 1)
	Kit:Tint(readout.disc, 'lcdInk')
	readout.discShade = Kit:Texture(clock, 'circle', 'OVERLAY', 2)
	Kit:Tint(readout.discShade, 'lcd')
	SnapTexture(readout.disc)
	SnapTexture(readout.discShade)
	readout.rules = {Kit:Solid(readout, 'lcdDim', 'ARTWORK', 1, 0.45), Kit:Solid(readout, 'lcdDim', 'ARTWORK', 1, 0.45)}
	return readout
end

-- Clock and coordinates, five times a second; text is set only when it changes.
local function NavFast()
	local device = module.device
	local readout, db = device.readout, DB()
	if not readout:IsShown() then return end
	local last = readout.last
	local clock = Clock()
	if clock ~= last.clock then last.clock = clock; readout.clockText:SetText(clock) end
	if db.coords then
		local x, y = Coordinates()
		local decimals = Kit:Clamp(floor(tonumber(db.coordsDecimals) or 1), 0, 2)
		local text = x and format('%.'..decimals..'f %.'..decimals..'f', x, y) or '--'
		if text ~= last.coords then last.coords = text; readout.coordsText:SetText(text) end
	end
end

-- The zone, on zone changes: a new name prints in left to right on the LCD.
local function NavZone()
	local device = module.device
	if not device then return end
	local readout = device.readout
	local token = PvPToken()
	Kit:SetLed(readout.lamp, token ~= nil, token)
	local zone = Plain(GetMinimapZoneText and GetMinimapZoneText())
	zone = strupper(type(zone) == 'string' and zone or '')
	if zone == readout.last.zone then return end
	local first = readout.last.zone == nil
	readout.last.zone = zone
	readout.zoneText:SetText(zone)
	if not first and readout:IsVisible() and Kit:Faithful('print') then
		Kit:Print(readout.zoneText, {duration = 0.32, steps = 16, force = true})
	end
end

-- Lamps, the difficulty LCD and the day/night disc: once a second and on their events.
local function NavStatus()
	local device = module.device
	if not device then return end
	SetLamp(device.mail, Plain(HasNewMail and HasNewMail()) and true or false)
	SetLamp(device.invites, Invites())
	SetLamp(device.tracking, Tracking())
	local ink = Invites() and 'amber' or 'ink'
	if device.calendarInk ~= ink then
		device.calendarInk = ink
		Kit:Tint(device.calendarKey.icon, ink)
	end
	-- Kept as text here: an empty FontString reads back as nil.
	local difficulty = Difficulty()
	if difficulty ~= device.difficulty then
		device.difficulty = difficulty
		device.chip.text:SetText(difficulty)
		LayoutHeader(device)
	end
	local readout = device.readout
	local night = not IsDay()
	if night ~= readout.night then
		readout.night = night
		readout.discShade:SetShown(night and DB().dayNight and true or false)
	end
	UpdateAppsLamp()
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
	SetPiece(container and container.PlayerCoords, false, true)
	if cluster and cluster.Tracking and cluster.Tracking.Background then Fade(cluster.Tracking.Background) end
	map:EnableMouseWheel(true)
	-- Replace, not add to, any wheel handler, so one notch is one zoom step.
	map:SetScript('OnMouseWheel', function(self, delta)
		if delta > 0 then self:SetZoom(min(self:GetZoom() + 1, self:GetZoomLevels() - 1))
		else self:SetZoom(max(self:GetZoom() - 1, 0)) end
		Kit:Play('tick')
		ZoomLater(self)
	end)

	-- Housing and screen behind the map, hugging it so little below (the quest
	-- tracker) is covered. Everything that takes the mouse is on `controls`,
	-- above the map and above MinimapCluster, which takes the mouse itself.
	local holder = map:GetParent() or UIParent
	local level = map:GetFrameLevel()
	local device = Kit:Device(holder, {model = 'NV-1', title = 'Map', corner = 14})
	device:SetFrameLevel(max(level - 3, 0))
	Kit:Relevel(device)
	device:EnableMouse(false)
	SnapTexture(device.lamp)
	SnapTexture(device.lamp.glow)
	pixelLamps[device.lamp] = NAV.lamp
	Kit:SetLed(device.lamp, true) -- powered
	local screen = Kit:Screen(holder, {inset = NAV.inset, corner = 6})
	screen:SetFrameLevel(max(level - 2, 0))
	Kit:Relevel(screen)
	screen:EnableMouse(false)
	local controls = CreateFrame('Frame', nil, device)
	controls:SetAllPoints(device)
	-- Above Blizzard's header pieces too (Forever raises its zone button to level 10).
	controls:SetFrameLevel(max(level + 6, 12))
	controls:EnableMouse(false)
	device.controls = controls
	-- Corner marks over the map's corners.
	local marks = CreateFrame('Frame', nil, map)
	marks:SetAllPoints(map)
	marks:SetFrameLevel(level + 3)
	marks:EnableMouse(false)
	marks.corners = {}
	for _, corner in ipairs({'TOPLEFT', 'TOPRIGHT', 'BOTTOMLEFT', 'BOTTOMRIGHT'}) do
		local pair = {}
		for index = 1, 2 do
			local line = marks:CreateTexture(nil, 'OVERLAY', nil, 7)
			line:SetColorTexture(1, 1, 1, 1)
			Kit:Tint(line, 'darkInk', 0.55)
			SnapTexture(line)
			pair[index] = line
		end
		marks.corners[corner] = pair
	end
	device.marks = marks
	-- Header: lamps, the difficulty LCD and the keys.
	device.mail = HeaderLamp(controls, 'Mail')
	device.invites = HeaderLamp(controls, 'Inv')
	device.tracking = HeaderLamp(controls, 'Trk')
	device.chip = Kit:LCDPanel(controls, {radius = 3})
	device.chip.text = Kit:Text(device.chip, '', 'tiny', 'lcdInk', true)
	device.chip.text:SetPoint('CENTER', 0, 0)
	device.difficulty = ''
	device.lampsHit = CreateFrame('Frame', nil, controls)
	device.lampsHit:EnableMouse(true)
	Tip(device.lampsHit, LampsTip)
	device.calendarKey = HeaderKey(controls, 'calendar', OpenCalendar, CalendarTip)
	device.trackingKey = HeaderKey(controls, 'search', function(key) OpenTracking(key) end, TrackingTip)
	NavReadout(device)
	module.device = device
	module.screen = screen
	-- A round map sits in the machined bezel instead of the square display.
	Bezel(map)
	if DB().collector then BuildDrawer(device, controls) end
	-- Only a change of size lays the header and readout out again.
	device:HookScript('OnSizeChanged', function()
		UI:Safe(LayoutHeader, device)
		UI:Safe(LayoutReadout, device)
	end)
	UI.Pixel.OnChange(FitNavigator)
	FitNavigator()

	module.ticker = C_Timer.NewTicker(0.2, function()
		if device:IsVisible() then UI:Safe(NavFast) end
	end)
	module.statusTicker = C_Timer.NewTicker(1, function()
		if device:IsVisible() then UI:Safe(NavStatus) end
	end)
	module.Tick = function() NavFast(); NavStatus() end
	module.Zone = NavZone
	module.Tick()
	NavZone()
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
		local key = BuildDrawer(strip, strip)
		key:ClearAllPoints()
		key:SetPoint('TOPRIGHT', strip, 'TOPLEFT', -4, -3)
		drawer:ClearAllPoints()
		drawer:SetPoint('TOPRIGHT', strip, 'BOTTOMLEFT', -6, -4)
	end
	module.ticker = C_Timer.NewTicker(0.5, function()
		if (strip and strip:IsVisible()) or (chip and chip:IsVisible()) then UI:Safe(TickStrip) end
	end)
	module.Tick = TickStrip
	module.Zone = UpdateZone
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
		'ZONE_CHANGED', 'ZONE_CHANGED_INDOORS', 'ZONE_CHANGED_NEW_AREA', 'DIEL_CYCLE_CHANGED', 'EXTERNAL_EVENT_URL_CHANGED'}) do
		pcall(driver.RegisterEvent, driver, event)
	end
	driver:SetScript('OnEvent', function(_, event)
		if event == 'PLAYER_ENTERING_WORLD' then
			ApplyPieces()
			QueueScan()
			C_Timer.After(3, QueueScan)
			C_Timer.After(1, function() UI:Safe(ApplyEdgeKeys) end)
		end
		if event == 'MINIMAP_UPDATE_TRACKING' then wipe(wanted) end
		if (event:find('^ZONE_CHANGED') or event == 'PLAYER_ENTERING_WORLD') and module.Zone then UI:Safe(module.Zone) end
		if event == 'EXTERNAL_EVENT_URL_CHANGED' then appsLampState = nil end
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
	if strip then Kit:Tint(strip.clock.text, ClockToken()) end
	if module.device then
		module.device.readout.night = nil
		UI:Safe(FitNavigator)
	end
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
			note = 'Device: the map on a recessed display, in a housing with lamps, keys and a readout LCD. Ring: the round map in a machined bezel, with a location strip.'},
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
		{'switch', 'Calendar key', 'minimap.keyCalendar', 'A key for the calendar; its icon turns amber with an invite. Replaces Blizzard\'s button.', since = '0.5.0'},
		{'switch', 'Tracking key', 'minimap.keyTracking', 'A key for the tracking menu. Replaces Blizzard\'s button.', since = '0.5.0'},
		{'slider', 'Bezel thickness', 'minimap.ringPx', 1, 8, 1, 'The ring around a round map, in screen pixels.', since = '0.5.0',
			format = function(v) return v..' px' end},
		{'switch', 'Edge keys', 'minimap.edgeKeys', 'The round buttons on the map edge (expansion summary, time of day) sit on round keys.', since = '0.5.0'},
	}},
	{title = 'Readout', rows = {
		{'switch', 'Readout', 'minimap.clock', 'Device style: zone, coordinates and time on an LCD under the map. Click the zone for the world map, the time for the stopwatch.'},
		{'switch', 'Coordinates', 'minimap.coords', 'Your map position.'},
		{'slider', 'Coordinate decimals', 'minimap.coordsDecimals', 0, 2, 1},
		{'switch', '24-hour clock', 'minimap.clock24'},
		{'switch', 'Server time', 'minimap.serverTime', 'The realm\'s time instead of your computer\'s.'},
		{'segmented', 'Clock color', 'minimap.clockInk', items = {{'lcd', 'LCD ink'}, {'key', 'Key color'}}, since = '0.5.2'},
		{'switch', 'Day and night', 'minimap.dayNight', 'A disc by the clock: full by day, a crescent at night.', since = '0.5.2'},
	}},
	{title = 'Lamps', rows = {
		{'switch', 'Mail', 'minimap.lampMail', 'Lit when there is new mail.'},
		{'switch', 'Calendar invites', 'minimap.lampInvites', 'Lit when an invite is waiting.'},
		{'switch', 'Tracking', 'minimap.lampTracking', 'Lit while you track something beyond town services.'},
		{'switch', 'Difficulty', 'minimap.difficulty', 'An LCD with the instance difficulty: N, H, M, M+12, LFR...'},
	}},
	{title = 'Addon buttons', rows = {
		{'switch', 'Apps drawer', 'minimap.collector', 'Addon minimap buttons (and the game\'s event button) gather on keys in a drawer; the Apps key opens it.', reload = true},
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
		{'switch', 'Day/night disc', 'minimap.showDayNight', 'Blizzard\'s own, on the Device\'s display; the readout\'s disc shows the same.', since = '0.5.2'},
	}},
}})
