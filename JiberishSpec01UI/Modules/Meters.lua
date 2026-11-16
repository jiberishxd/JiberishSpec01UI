-- Damage meters as SPEC-01 devices.
--
-- Details!: each window sits in a dark housing; its bars, bar text and title
--   use SPEC-01 bar art and IBM Plex through Details' own window API, so the
--   settings live in Details and its own options keep working.
-- Blizzard's damage meter (Blizzard_DamageMeter): its session windows sit in
--   dark housings that follow Edit Mode's background opacity, with SPEC-01 bar
--   art and type. Edit Mode keeps placing them.
-- Skada and Recount: housings and bar art, when they are loaded.
-- Dock: a DM-0 device holding one or two Details windows (and our own meter).
-- Own meter: a DM-1 device reading the game's own combat data (C_DamageMeter).
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent = CreateFrame, UIParent
local floor, max, min = math.floor, math.max, math.min

local module = UI:RegisterModule('meters', {})

-- defaults:begin
UI:RegisterDefaults('meters', {
	bar = 'dots', barHeight = 16, fontSize = 10, classColors = true,
	details = true, detailsBase = true, blizzard = true, skada = true, recount = true,
	dock = false, dockWidth = 320, dockHeight = 220, dockWindows = 1,
	own = false, ownType = 'damage', ownSession = 'current', ownRows = 8, ownWidth = 250,
	-- Details window ids that already got the flat base skin once; after that the
	-- player's own skin choice stays.
	baseApplied = {},
})
-- defaults:end

local function DB() return UI.db.meters end
local function IsSecret(value) return issecretvalue and issecretvalue(value) end
local function Plain(value) if IsSecret(value) then return nil end return value end
local function Forbidden(object) return not object or (object.IsForbidden and object:IsForbidden()) end

local BARS = {dots = {'SPEC-01 Dots', 'bar-dots'}, segments = {'SPEC-01 Segments', 'bar-segments'}, flat = {'SPEC-01 Flat', 'bar-flat'}}
local function Bar() return BARS[DB().bar] or BARS.dots end
local function BarFile() return Kit.media..Bar()[2]..'.tga' end
local FONT, FONT_BOLD = 'IBM Plex Mono', 'IBM Plex Mono Bold'
local INK = {0.95, 0.95, 0.92, 1}

-- Details picks bar art and type by their LibSharedMedia names.
local function RegisterMedia()
	local LSM = LibStub and LibStub('LibSharedMedia-3.0', true)
	if not LSM then return end
	for _, bar in pairs(BARS) do pcall(LSM.Register, LSM, 'statusbar', bar[1], Kit.media..bar[2]..'.tga') end
	pcall(LSM.Register, LSM, 'font', FONT, Kit.fonts.regular)
	pcall(LSM.Register, LSM, 'font', FONT_BOLD, Kit.fonts.bold)
end

-- Housings ------------------------------------------------------------------------------
-- A dark SPEC-01 shell behind another addon's window. It sits on UIParent at the
-- window's strata, just under it, and follows the window's visibility.
local housings = setmetatable({}, {__mode = 'k'})

local function Housing(target, insets, parent)
	if Forbidden(target) then return end
	insets = insets or {}
	local housing = housings[target]
	if not housing then
		housing = CreateFrame('Frame', nil, parent or UIParent)
		housing:EnableMouse(false)
		housing.shell = Kit:Shell(housing, {surface = 'dark', radius = 8})
		housings[target] = housing
		if not parent then
			target:HookScript('OnShow', function() if not housing.docked then housing:Show() end end)
			target:HookScript('OnHide', function() housing:Hide() end)
		end
	end
	housing:ClearAllPoints()
	housing:SetPoint('TOPLEFT', target, 'TOPLEFT', -(insets.left or 5), insets.top or 5)
	housing:SetPoint('BOTTOMRIGHT', target, 'BOTTOMRIGHT', insets.right or 5, -(insets.bottom or 5))
	housing:SetFrameStrata(target:GetFrameStrata())
	housing:SetFrameLevel(max(target:GetFrameLevel() - 2, 1))
	Kit:Relevel(housing)
	housing:SetShown(target:IsShown() and not housing.docked)
	return housing
end

-- Details! ---------------------------------------------------------------------------------
local BASE_SKIN = 'Minimalistic'
local applying = false

local function Details()
	local details = _G.Details
	if type(details) ~= 'table' or type(details.IsLoaded) ~= 'function' then return end
	local ok, loaded = pcall(details.IsLoaded)
	return ok and loaded and details or nil
end

local function DetailsWindows()
	local details, list = Details(), {}
	if not details or type(details.ListInstances) ~= 'function' then return list end
	for _, instance in details:ListInstances() do
		if type(instance) == 'table' and instance.baseframe and instance.IsEnabled and instance:IsEnabled() then
			list[#list + 1] = instance
		end
	end
	return list
end

-- The title bar sits above the base frame, or below it with the toolbar at the bottom.
local function DetailsInsets(instance)
	local toolbarBottom = instance.toolbar_side == 2
	local statusbar = instance.show_statusbar and 14 or 0
	return {left = 5, right = 5, top = toolbarBottom and 5 or 24, bottom = (toolbarBottom and 24 or 5) + statusbar}
end

local function StyleDetails(instance, keepSkin)
	local db = DB()
	if not db.details then return end
	local details = Details()
	applying = true
	local id = instance.GetId and instance:GetId()
	if type(db.baseApplied) ~= 'table' then db.baseApplied = {} end
	if not keepSkin and db.detailsBase and id and not db.baseApplied[id] then
		db.baseApplied[id] = true
		if instance.skin ~= BASE_SKIN and details.skins and details.skins[BASE_SKIN] then
			pcall(instance.ChangeSkin, instance, BASE_SKIN)
		end
	end
	local r, g, b = Kit:RGB('lamp')
	pcall(instance.SetBarSettings, instance, db.barHeight, Bar()[1], db.classColors, {r, g, b, 1}, BARS.flat[1], false,
		{0.09, 0.09, 0.085, 0.85}, 1, nil, nil, 2)
	pcall(instance.SetBarTextSettings, instance, db.fontSize, FONT, INK, false, false, false, false)
	pcall(instance.AttributeMenu, instance, true, nil, nil, FONT_BOLD, db.fontSize, INK, nil, false)
	pcall(instance.SetBackgroundAlpha, instance, 0)
	pcall(instance.HideSideBars, instance)
	pcall(instance.HideMainIcon, instance, true)
	applying = false
	Housing(instance.baseframe, DetailsInsets(instance))
end

local function StyleAllDetails(keepSkin)
	for _, instance in ipairs(DetailsWindows()) do UI:Safe(StyleDetails, instance, keepSkin) end
end

local Dock -- defined below

local detailsHooked
local function HookDetails()
	local details = Details()
	if not details or detailsHooked then return end
	detailsHooked = true
	-- A window opened later, or a skin picked in Details' options, gets the SPEC-01
	-- bars and housing again (keeping the skin the player chose).
	if type(details.ChangeSkin) == 'function' then
		hooksecurefunc(details, 'ChangeSkin', function()
			if applying then return end
			C_Timer.After(0, function() StyleAllDetails(true); Dock() end)
		end)
	end
	if type(details.CreateEventListener) == 'function' then
		local ok, listener = pcall(details.CreateEventListener, details)
		if ok and listener and listener.RegisterEvent then
			pcall(listener.RegisterEvent, listener, 'DETAILS_INSTANCE_OPEN', function()
				C_Timer.After(0, function() StyleAllDetails(); Dock() end)
			end)
		end
	end
end

local function WaitForDetails()
	if not DB().details or type(_G.Details) ~= 'table' then return end
	local tries = 0
	local ticker
	ticker = C_Timer.NewTicker(1, function()
		tries = tries + 1
		if Details() then
			ticker:Cancel()
			RegisterMedia()
			StyleAllDetails()
			HookDetails()
			Dock()
		elseif tries >= 40 then
			ticker:Cancel()
		end
	end)
end

-- Blizzard's damage meter -------------------------------------------------------------------
local blizzardWindows = setmetatable({}, {__mode = 'k'})
local dressedText = setmetatable({}, {__mode = 'k'})

local function Plex(region, size, bold)
	if Forbidden(region) or dressedText[region] or not (region.IsObjectType and region:IsObjectType('FontString')) then return end
	dressedText[region] = true
	local _, current = region:GetFont()
	current = Plain(current)
	Kit:Font(region, size or (current and floor(current + 0.5)) or DB().fontSize, '', bold)
	region:SetShadowOffset(1, -1)
	region:SetShadowColor(0, 0, 0, 0.6)
end

local function StyleEntry(entry)
	if Forbidden(entry) then return end
	local bar = entry.StatusBar
	if bar and not Forbidden(bar) then
		local fill = bar.GetStatusBarTexture and bar:GetStatusBarTexture()
		if fill then fill:SetTexture(BarFile()) end
		local back = bar.Background
		if back and back.SetColorTexture then
			back:SetColorTexture(1, 1, 1, 1)
			Kit:Tint(back, 'glass', 0.85)
		end
		if bar.BackgroundEdge then bar.BackgroundEdge:SetAlpha(0) end
		for _, region in ipairs({bar:GetRegions()}) do Plex(region, DB().fontSize) end
	end
	if entry.Icon and entry.Icon.SetTexCoord and not dressedText[entry.Icon] then
		dressedText[entry.Icon] = true
		entry.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	end
	for _, region in ipairs({entry:GetRegions()}) do Plex(region, DB().fontSize) end
end

local restyle = {} -- one function per hooked list, to repaint its rows after a setting changes
local function HookScrollBox(owner)
	local box = owner and owner.GetScrollBox and owner:GetScrollBox()
	if not box or blizzardWindows[box] then return end
	blizzardWindows[box] = true
	local function Each() if box.ForEachFrame then box:ForEachFrame(StyleEntry) end end
	restyle[#restyle + 1] = Each
	if type(box.Update) == 'function' then hooksecurefunc(box, 'Update', Each) end
	Each()
end

-- Edit Mode sets the window's background opacity on its Background texture;
-- the housing follows it. The texture itself is emptied, not faded, so that
-- opacity setting keeps its meaning.
local function Behind(window, background)
	local housing = Housing(window, {left = 2, right = 2, top = 2, bottom = 2}, window)
	if background and background.SetTexture and not blizzardWindows[background] then
		blizzardWindows[background] = true
		local alpha = Plain(background:GetAlpha())
		background:SetTexture(nil)
		if alpha then housing:SetAlpha(alpha) end
		hooksecurefunc(background, 'SetAlpha', function(_, value)
			if not IsSecret(value) and type(value) == 'number' then housing:SetAlpha(value) end
		end)
	end
	return housing
end

local function StyleSessionWindow(window)
	if Forbidden(window) or blizzardWindows[window] then return end
	blizzardWindows[window] = true
	if window.Header and window.Header.SetAlpha then window.Header:SetAlpha(0) end
	local container = window.MinimizeContainer
	Behind(window, container and container.Background)
	Plex(window.SessionTimer, DB().fontSize, true)
	local typeDropdown = window.DamageMeterTypeDropdown
	if typeDropdown then Plex(typeDropdown.TypeName, DB().fontSize, true) end
	HookScrollBox(window)
	local source = container and container.SourceWindow
	if source and not Forbidden(source) then
		Behind(source, source.Background)
		HookScrollBox(source)
	end
	if type(window.ShowLocalPlayerEntry) == 'function' then
		hooksecurefunc(window, 'ShowLocalPlayerEntry', function(self)
			local entry = self.MinimizeContainer and self.MinimizeContainer.LocalPlayerEntry
			if entry then UI:Safe(StyleEntry, entry) end
		end)
	end
end

local function StyleBlizzard()
	local meter = _G.DamageMeter
	if Forbidden(meter) or type(meter.ForEachSessionWindow) ~= 'function' then return end
	meter:ForEachSessionWindow(function(window) UI:Safe(StyleSessionWindow, window) end)
end

local blizzardHooked
local function HookBlizzard()
	if not DB().blizzard then return end
	local meter = _G.DamageMeter
	if Forbidden(meter) then return end
	if not blizzardHooked and type(meter.SetupSessionWindow) == 'function' then
		blizzardHooked = true
		-- New session windows are styled a frame later, outside Blizzard's own call.
		hooksecurefunc(meter, 'SetupSessionWindow', function() C_Timer.After(0, StyleBlizzard) end)
	end
	StyleBlizzard()
end

-- Skada and Recount ---------------------------------------------------------------------
local function StyleSkada()
	local Skada = _G.Skada
	if not DB().skada or type(Skada) ~= 'table' or type(Skada.GetWindows) ~= 'function' then return end
	local ok, windows = pcall(Skada.GetWindows, Skada)
	if not ok or type(windows) ~= 'table' then return end
	for _, window in ipairs(windows) do
		local group = type(window) == 'table' and window.bargroup
		if group and not Forbidden(group) then
			if group.SetTexture then pcall(group.SetTexture, group, BarFile()) end
			if group.SetFont then pcall(group.SetFont, group, Kit.fonts.regular, DB().fontSize) end
			local titled = window.db and window.db.enabletitle
			Housing(group, {top = titled and 20 or 5})
		end
	end
end

local function StyleRecount()
	local Recount = _G.Recount
	if not DB().recount or type(Recount) ~= 'table' then return end
	local main = Recount.MainWindow
	if main and not Forbidden(main) then Housing(main, {left = 2, right = 2, top = -8, bottom = 2}) end
	if type(Recount.SetBarTextures) == 'function' then pcall(Recount.SetBarTextures, Recount, Bar()[1]) end
end

-- Own meter (C_DamageMeter) ----------------------------------------------------------------
local own
local TYPES = {
	{'damage', 'DamageDone', 'Damage'}, {'healing', 'HealingDone', 'Healing'}, {'interrupts', 'Interrupts', 'Interrupts'},
	{'dispels', 'Dispels', 'Dispels'}, {'taken', 'DamageTaken', 'Damage taken'},
}
local function TypeOf(key)
	for index, entry in ipairs(TYPES) do if entry[1] == key then return entry, index end end
	return TYPES[1], 1
end

local function HasMeterAPI()
	return C_DamageMeter and C_DamageMeter.GetCombatSessionFromType and Enum and Enum.DamageMeterType and Enum.DamageMeterSessionType
end

local HEADER, ROW_GAP = 24, 2

local function OwnRow(index)
	local row = own.rows[index]
	if row then return row end
	local parent = own.display.screen
	row = CreateFrame('Frame', nil, parent)
	row.bar = CreateFrame('StatusBar', nil, row)
	row.bar:SetAllPoints()
	row.bar:SetStatusBarTexture(Kit.media..'bar-flat.tga')
	row.bar:SetMinMaxValues(0, 1)
	row.rank = Kit:Text(row.bar, '', 8, 'darkDim', true)
	row.rank:SetPoint('LEFT', 4, 0)
	row.rank:SetWidth(14)
	row.rank:SetJustifyH('RIGHT')
	row.value = Kit:Text(row.bar, '', 9, 'darkInk', true, true)
	row.value:SetPoint('RIGHT', -5, 0)
	row.rate = Kit:Text(row.bar, '', 8, 'darkDim', false, true)
	row.rate:SetPoint('RIGHT', row.value, 'LEFT', -5, 0)
	row.name = Kit:Text(row.bar, '', 9, 'darkInk', false, true)
	row.name:SetPoint('LEFT', row.rank, 'RIGHT', 5, 0)
	row.name:SetPoint('RIGHT', row.rate, 'LEFT', -5, 0)
	row.name:SetJustifyH('LEFT')
	row.name:SetWordWrap(false)
	row.lamp = Kit:Led(row.bar, 4, true)
	row.lamp:SetPoint('LEFT', 1, 0)
	own.rows[index] = row
	return row
end

local function LayoutOwn()
	if not own then return end
	local db = DB()
	local rows = Kit:Clamp(floor(db.ownRows or 8), 1, 30)
	local height = db.barHeight or 16
	if not own.docked then own:SetSize(db.ownWidth, HEADER + 8 + rows * (height + ROW_GAP) + 6) end
	for index = 1, max(rows, #own.rows) do
		local row = OwnRow(index)
		row:ClearAllPoints()
		row:SetPoint('TOPLEFT', own.display.screen, 'TOPLEFT', 3, -3 - (index - 1) * (height + ROW_GAP))
		row:SetPoint('TOPRIGHT', own.display.screen, 'TOPRIGHT', -3, -3 - (index - 1) * (height + ROW_GAP))
		row:SetHeight(height)
		if db.bar == 'flat' then
			Kit:Unperforate(row.bar)
		else
			Kit:Perforate(row.bar, 'black', 'darkEdge')
		end
		row.enabled = index <= rows
		if not row.enabled then row:Hide() end
	end
end

local function Clock(seconds)
	seconds = Plain(seconds)
	if not seconds then return '--:--' end
	return format('%d:%02d', floor(seconds / 60), floor(seconds % 60))
end

local function UpdateOwn()
	if not own or not own:IsShown() then return end
	local db = DB()
	local entry = TypeOf(db.ownType)
	own.title:SetText(strupper(entry[3]))
	local sessionType = Enum.DamageMeterSessionType[db.ownSession == 'overall' and 'Overall' or 'Current']
	local meterType = Enum.DamageMeterType[entry[2]]
	local sources
	if sessionType and meterType then
		local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType, sessionType, meterType)
		sources = ok and type(session) == 'table' and session.combatSources or nil
	end
	local count = type(sources) == 'table' and #sources or 0
	for index, row in ipairs(own.rows) do
		local source = row.enabled and index <= count and sources[index]
		if source then
			row:Show()
			-- Amounts may be secret: they only ever go to setters.
			pcall(row.bar.SetMinMaxValues, row.bar, 0, sources[1].totalAmount)
			pcall(row.bar.SetValue, row.bar, source.totalAmount)
			local class = Plain(source.classFilename)
			local color = class and (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)[class]
			if color and db.classColors then row.bar:SetStatusBarColor(color.r, color.g, color.b, 0.9)
			else row.bar:SetStatusBarColor(Kit:RGB('lamp')) end
			local name = source.name
			if not IsSecret(name) and type(name) == 'string' and Ambiguate then name = Ambiguate(name, 'short') end
			row.name:SetText(name)
			row.rank:SetText(index)
			if AbbreviateNumbers then
				pcall(row.value.SetText, row.value, AbbreviateNumbers(source.totalAmount))
				pcall(row.rate.SetText, row.rate, AbbreviateNumbers(source.amountPerSecond))
			end
			Kit:ShowLed(row.lamp, Plain(source.isLocalPlayer) == true)
		else
			row:Hide()
		end
	end
	own.empty:SetShown(count == 0)
	local ok, seconds = pcall(C_DamageMeter.GetSessionDurationSeconds, sessionType)
	own.clock:SetText(ok and Clock(seconds) or '--:--')
end

local queued
local function QueueOwn()
	if queued then return end
	queued = true
	C_Timer.After(0.25, function()
		queued = false
		UI:Safe(UpdateOwn)
	end)
end

local function OwnMenu(anchor)
	local db = DB()
	local items, actions = {}, {}
	for _, entry in ipairs(TYPES) do
		items[#items + 1] = {text = entry[3], checked = db.ownType == entry[1]}
		actions[#actions + 1] = function() Kit:SetOption('meters.ownType', entry[1]) end
	end
	items[#items + 1] = {separator = true}; actions[#actions + 1] = false
	items[#items + 1] = {text = 'This fight', checked = db.ownSession ~= 'overall'}
	actions[#actions + 1] = function() Kit:SetOption('meters.ownSession', 'current') end
	items[#items + 1] = {text = 'Overall', checked = db.ownSession == 'overall'}
	actions[#actions + 1] = function() Kit:SetOption('meters.ownSession', 'overall') end
	items[#items + 1] = {separator = true}; actions[#actions + 1] = false
	items[#items + 1] = {text = 'Reset'}
	actions[#actions + 1] = function()
		if C_DamageMeter.ResetAllCombatSessions then pcall(C_DamageMeter.ResetAllCombatSessions) end
		QueueOwn()
	end
	Kit:Menu(anchor, items, function(index) if actions[index] then actions[index]() end end, {side = 'CURSOR', width = 160})
end

local combatTicker
local function BuildOwn()
	if own or not HasMeterAPI() then return end
	local db = DB()
	own = Kit:Device(UIParent, {model = 'DM-1', title = 'Damage', radius = 10, width = db.ownWidth, height = 120})
	own:SetFrameStrata('LOW')
	own:SetFrameLevel(4)
	Kit:Relevel(own)
	own.rows = {}
	own.display = Kit:Screen(own, {inset = 3, radius = 6})
	own.display:SetPoint('TOPLEFT', 8, -HEADER)
	own.display:SetPoint('BOTTOMRIGHT', -8, 8)
	Kit:Relevel(own.display)
	own.clockPanel = Kit:LCDPanel(own, {radius = 3})
	own.clockPanel:SetSize(44, 14)
	own.clockPanel:SetPoint('TOPRIGHT', -8, -5)
	own.clock = Kit:Text(own.clockPanel, '--:--', 8, 'lcdInk', true)
	own.clock:SetPoint('CENTER')
	own.title:ClearAllPoints()
	own.title:SetPoint('LEFT', own.model, 'RIGHT', 5, 0)
	own.title:SetPoint('RIGHT', own.clockPanel, 'LEFT', -6, 0)
	own.empty = Kit:Label(own.display.screen, 'No data', 'darkDim', 8)
	own.empty:SetPoint('CENTER')
	-- Left-click the header: next type. Right-click: types, session and reset.
	own:EnableMouse(true)
	own:SetScript('OnMouseUp', function(self, button)
		local _, y = GetCursorPosition()
		local top = self:GetTop()
		if top and (top - y / self:GetEffectiveScale()) > HEADER then return end
		if button == 'RightButton' then return OwnMenu(self) end
		Kit:Play('tick')
		local _, index = TypeOf(DB().ownType)
		Kit:SetOption('meters.ownType', TYPES[index % #TYPES + 1][1])
	end)
	LayoutOwn()
	UI:RegisterMover(own, 'dm.own', 'Meter', {'BOTTOMRIGHT', -16, 260})
	local events = CreateFrame('Frame')
	for _, event in ipairs({'DAMAGE_METER_COMBAT_SESSION_UPDATED', 'DAMAGE_METER_CURRENT_SESSION_UPDATED', 'DAMAGE_METER_RESET',
		'PLAYER_REGEN_DISABLED', 'PLAYER_REGEN_ENABLED', 'GROUP_ROSTER_UPDATE', 'PLAYER_ENTERING_WORLD'}) do
		pcall(events.RegisterEvent, events, event)
	end
	events:SetScript('OnEvent', function(_, event)
		if event == 'PLAYER_REGEN_DISABLED' then
			Kit:SetLed(own.lamp, true)
			if not combatTicker then combatTicker = C_Timer.NewTicker(1, QueueOwn) end
		elseif event == 'PLAYER_REGEN_ENABLED' then
			Kit:SetLed(own.lamp, false)
			if combatTicker then combatTicker:Cancel(); combatTicker = nil end
		end
		QueueOwn()
	end)
	QueueOwn()
end

-- Dock ----------------------------------------------------------------------------------------
local dock
function Dock()
	local db = DB()
	local windows = {}
	if db.dock then
		for _, instance in ipairs(DetailsWindows()) do
			if #windows < (db.dockWindows or 1) then windows[#windows + 1] = instance end
		end
		if own and #windows < 2 then windows[#windows + 1] = own end
	end
	-- Windows leaving the dock get their own housings back.
	for target, housing in pairs(housings) do
		if housing.docked then
			housing.docked = nil
			housing:SetShown(target:IsShown())
		end
	end
	if own and own.docked then
		own.docked = nil
		own.shell:Show()
		UI:PlaceMover('dm.own')
		LayoutOwn()
	end
	if not db.dock or #windows == 0 then
		if dock then dock:Hide() end
		return
	end
	if not dock then
		dock = Kit:Device(UIParent, {model = 'DM-0', title = 'Meters', radius = 10, width = db.dockWidth, height = db.dockHeight})
		dock:SetFrameStrata('BACKGROUND')
		dock:SetFrameLevel(2)
		Kit:Relevel(dock)
		UI:RegisterMover(dock, 'dm.dock', 'Meters', {'BOTTOMRIGHT', -16, 230})
	end
	dock:SetSize(db.dockWidth, db.dockHeight)
	dock:Show()
	UI:PlaceMover('dm.dock')
	local top, gap, inset = HEADER, 6, 8
	local height = (db.dockHeight - top - inset - gap * (#windows - 1)) / #windows
	local width = db.dockWidth - inset * 2
	for index, window in ipairs(windows) do
		local y = -top - (index - 1) * (height + gap)
		if window == own then
			own.docked = true
			own.shell:Hide()
			own:ClearAllPoints()
			own:SetPoint('TOPLEFT', dock, 'TOPLEFT', inset - 8, y + HEADER)
			own:SetSize(width + 16, height + HEADER)
			LayoutOwn()
		else
			local frame = window.baseframe
			local insets = DetailsInsets(window)
			frame:ClearAllPoints()
			frame:SetPoint('TOPLEFT', dock, 'TOPLEFT', inset, y - (insets.top - 5))
			pcall(window.SetSize, window, width, max(height - (insets.top - 5) - (insets.bottom - 5), 40))
			local housing = housings[frame]
			if housing then
				housing.docked = true
				housing:Hide()
			end
		end
	end
end

-- Module ---------------------------------------------------------------------------------------
local function Loaded(name)
	return UI:IsAddOnLoaded(name)
end

function module:Enable()
	RegisterMedia()
	WaitForDetails()
	if Loaded('Blizzard_DamageMeter') then HookBlizzard() end
	if DB().own then BuildOwn() end
	local driver = CreateFrame('Frame')
	driver:RegisterEvent('ADDON_LOADED')
	driver:RegisterEvent('PLAYER_ENTERING_WORLD')
	driver:SetScript('OnEvent', function(_, event, name)
		if event == 'ADDON_LOADED' then
			if name == 'Blizzard_DamageMeter' then C_Timer.After(0, HookBlizzard)
			elseif name == 'Skada' then C_Timer.After(1, StyleSkada)
			elseif name == 'Recount' then C_Timer.After(1, StyleRecount) end
		else
			C_Timer.After(2, function()
				UI:Safe(StyleSkada)
				UI:Safe(StyleRecount)
			end)
		end
	end)
	Dock()
end

-- Every option change reaches every module; restyle only when ours changed.
local signature
local function Signature()
	local db = DB()
	return strjoin(',', tostringall(db.bar, db.barHeight, db.fontSize, db.classColors, db.details, db.detailsBase, db.dock,
		db.dockWidth, db.dockHeight, db.dockWindows, db.ownType, db.ownSession, db.ownRows, db.ownWidth, Kit:DB().finish,
		Kit:DB().accent))
end

function module:Refresh()
	local now = Signature()
	if now == signature then return end
	signature = now
	if Details() then StyleAllDetails(true) end
	for _, Each in ipairs(restyle) do UI:Safe(Each) end
	if own then LayoutOwn(); QueueOwn() end
	Dock()
end

-- Hub page ---------------------------------------------------------------------------------
local TYPE_ITEMS = {}
for _, entry in ipairs(TYPES) do TYPE_ITEMS[#TYPE_ITEMS + 1] = {entry[1], entry[3]} end
local function Count(v) return format('%d', v) end

UI:RegisterPage('meters', {title = 'Damage meters', order = 18, cards = {
	{title = 'Style', rows = {
		{'segmented', 'Meters', 'style.meters', items = {{'device', 'Device'}, {'blizzard', 'Blizzard'}}, reload = true,
			note = 'Meter windows in dark SPEC-01 housings, with SPEC-01 bars and type.'},
		{'segmented', 'Bars', 'meters.bar', items = {{'dots', 'Dots'}, {'segments', 'Segments'}, {'flat', 'Flat'}}},
		{'slider', 'Bar height', 'meters.barHeight', 10, 28, 1, nil, format = Count},
		{'slider', 'Text size', 'meters.fontSize', 8, 14, 1, nil, format = Count},
		{'switch', 'Class colors', 'meters.classColors', 'Bars in class colors; off uses the lamp color.'},
	}},
	{title = 'Meters', rows = {
		{'switch', 'Details!', 'meters.details', 'Bars, type and housing set through Details\' own window settings.', reload = true},
		{'switch', 'Flat base skin', 'meters.detailsBase', 'Each Details window starts on its flat Minimalistic skin, once; a skin you pick later stays.'},
		{'switch', 'Blizzard meter', 'meters.blizzard', 'The game\'s own damage meter windows. Edit Mode places them.', reload = true},
		{'switch', 'Skada', 'meters.skada', nil, reload = true},
		{'switch', 'Recount', 'meters.recount', nil, reload = true},
	}},
	{title = 'Dock', rows = {
		{'switch', 'Dock', 'meters.dock', 'One DM-0 device holding Details windows (and the DM-1 meter). Place it with /spec move.'},
		{'slider', 'Dock width', 'meters.dockWidth', 200, 640, 10, nil, format = Count},
		{'slider', 'Dock height', 'meters.dockHeight', 120, 520, 10, nil, format = Count},
		{'slider', 'Docked windows', 'meters.dockWindows', 1, 2, 1, nil, format = Count},
	}},
	{title = 'DM-1 meter', rows = {
		{'switch', 'Own meter', 'meters.own', 'A DM-1 device reading the game\'s own combat data. Click its header for the next type; right-click for more.', reload = true},
		{'dropdown', 'Shows', 'meters.ownType', items = TYPE_ITEMS},
		{'segmented', 'Session', 'meters.ownSession', items = {{'current', 'This fight'}, {'overall', 'Overall'}}},
		{'slider', 'Rows', 'meters.ownRows', 3, 20, 1, nil, format = Count},
		{'slider', 'Width', 'meters.ownWidth', 180, 420, 10, nil, format = Count},
	}},
}})
