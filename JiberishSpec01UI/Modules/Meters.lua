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
	own = true, ownType = 'damage', ownSession = 'current', ownRows = 8, ownWidth = 270,
	-- DM-1 windows: replace the game's meter, how many, and what each row shows.
	replaceGame = true, ownCount = 1, ownRate = true, ownPercent = true, ownNameColor = false, ownTooltip = true,
	ownMotion = true, ownSounds = true, windows = {},
	-- The game's own meter.
	blizzHeader = true, blizzFill = 'class', blizzRanks = false, blizzRate = false, blizzMotion = true,
	blizzSounds = true, blizzTopBlip = false,
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
-- Every session window (an Edit Mode system: never moved or reparented) becomes
-- a DM-1 device in place: a dark housing with a printed header above it (lamp,
-- DM-1, the meter's name), the session timer on an LCD, the type, session and
-- settings dropdowns as SPEC-01 keys, a hairline scroll bar and a grip glyph.
-- Each pooled row keeps the game's own bar, re-dressed: our bar art (or key
-- color) is put back whenever the game recolors it, its background becomes a
-- dark track, a lit line and a spark ride the fill's edge, the class icon sits
-- cropped on a small key and the player's row lights a lamp. Errors go to the
-- error handler. Everything we add lives in side tables.
local blizzardWindows = setmetatable({}, {__mode = 'k'})
local dressedText = setmetatable({}, {__mode = 'k'})
local rowParts = setmetatable({}, {__mode = 'k'})   -- entry -> our pieces
local windowParts = setmetatable({}, {__mode = 'k'}) -- session window -> header pieces

local function Plex(region, size, bold, role)
	if Forbidden(region) or dressedText[region] or not (region.IsObjectType and region:IsObjectType('FontString')) then return end
	dressedText[region] = true
	local _, current = region:GetFont()
	current = Plain(current)
	Kit:Font(region, size or (current and floor(current + 0.5)) or DB().fontSize, 'OUTLINE', bold, role)
	region:SetShadowOffset(0, 0)
end

local function Motion() return DB().blizzMotion and not Kit:Reduced() end
local function Sound(name) if DB().blizzSounds then Kit:Play(name) end end

-- Fade every texture on a Blizzard frame (its art), keeping the ones in `keep`.
local function FadeArt(frame, keep)
	if Forbidden(frame) then return end
	for _, region in ipairs({frame:GetRegions()}) do
		if region.IsObjectType and region:IsObjectType('Texture') and not (keep and keep[region]) then region:SetAlpha(0) end
	end
end

-- A SPEC-01 key behind a Blizzard button, with an optional glyph over it.
local keyed = setmetatable({}, {__mode = 'k'})
local function DressKey(button, icon, size)
	if Forbidden(button) or keyed[button] then return keyed[button] end
	FadeArt(button)
	local key = CreateFrame('Frame', nil, button)
	key:SetAllPoints()
	key:SetFrameLevel(max(button:GetFrameLevel() - 1, 0))
	key:EnableMouse(false)
	key.skin = Kit:Skin(key, 'key', 'BACKGROUND', 0)
	key.skin.kitMaxCorner = 5
	if icon then
		key.top = CreateFrame('Frame', nil, button)
		key.top:SetAllPoints()
		key.top:SetFrameLevel(button:GetFrameLevel() + 2)
		key.top:EnableMouse(false)
		key.icon = Kit:Icon(key.top, icon, size or 10, 'ink')
		key.icon:SetPoint('CENTER')
	end
	button:HookScript('OnEnter', function() key.skin:SetAlpha(0.85) end)
	button:HookScript('OnLeave', function() key.skin:SetAlpha(1) end)
	if button.HasScript and button:HasScript('OnMouseDown') then
		button:HookScript('OnMouseDown', function() Kit:SetSprite(key.skin, 'key-down'); Sound('tick') end)
		button:HookScript('OnMouseUp', function() Kit:SetSprite(key.skin, 'key') end)
	end
	keyed[button] = key
	return key
end

-- Rows ----------------------------------------------------------------------------------------
-- The game's own bar is reused: its fill takes our bar art (and the key color,
-- if chosen) every time the game recolors it, its background becomes the dark
-- track, and a lit line and spark ride the fill's edge. Parts are found by
-- type, not by name, so Forever's and Retail's rows are both reached.
local function Is(object, kind) return type(object) == 'table' and object.IsObjectType and object:IsObjectType(kind) end

-- The first StatusBar on the row, or one or two levels down.
local function FindBar(entry)
	if Is(entry.StatusBar, 'StatusBar') then return entry.StatusBar end
	local function Search(frame, depth)
		for _, child in ipairs({frame:GetChildren()}) do
			if Is(child, 'StatusBar') then return child end
			if depth < 2 then
				local found = Search(child, depth + 1)
				if found then return found end
			end
		end
	end
	return Search(entry, 0)
end

local function FindIcon(entry, bar)
	for _, holder in ipairs({entry, bar}) do
		local icon = holder.Icon or holder.icon
		if Is(icon, 'Texture') then return icon end
	end
end

-- Every FontString on the row and its children.
local function EachText(frame, func, depth)
	depth = depth or 0
	for _, region in ipairs({frame:GetRegions()}) do
		if Is(region, 'FontString') then func(region) end
	end
	if depth < 2 then
		for _, child in ipairs({frame:GetChildren()}) do
			if not rowParts[child] then EachText(child, func, depth + 1) end
		end
	end
end

local function KeyColor(parts)
	if DB().blizzFill ~= 'key' or not parts.fill then return end
	parts.coloring = true
	parts.fill:SetVertexColor(Kit:RGB('lamp'))
	parts.coloring = false
end

local function Art(parts)
	if parts.fill then parts.fill:SetTexture(BarFile()) end
	KeyColor(parts)
end

local function DressRow(entry)
	if Forbidden(entry) or rowParts[entry] then return rowParts[entry] end
	local bar = FindBar(entry)
	if not bar or Forbidden(bar) then return end
	local parts = {}
	rowParts[entry] = parts
	parts.fill = bar:GetStatusBarTexture()
	Art(parts)
	-- The game swaps or recolors the fill as it updates: put ours back.
	hooksecurefunc(bar, 'SetStatusBarTexture', function(self)
		parts.fill = self:GetStatusBarTexture()
		if parts.fill then parts.fill:SetTexture(BarFile()) end
		KeyColor(parts)
	end)
	if parts.fill and parts.fill.SetVertexColor then
		hooksecurefunc(parts.fill, 'SetVertexColor', function()
			if not parts.coloring then KeyColor(parts) end
		end)
	end
	if bar.SetStatusBarColor then hooksecurefunc(bar, 'SetStatusBarColor', function() KeyColor(parts) end) end
	-- The background: a dark track.
	local back = bar.Background
	if Is(back, 'Texture') then
		back:SetColorTexture(1, 1, 1, 1)
		Kit:Tint(back, 'glass', 0.9)
	end
	if bar.BackgroundEdge and bar.BackgroundEdge.SetAlpha then bar.BackgroundEdge:SetAlpha(0) end
	-- A faint lit line on the fill's top edge and a spark on its leading edge.
	if parts.fill then
		parts.edge = bar:CreateTexture(nil, 'OVERLAY', nil, 5)
		parts.edge:SetColorTexture(1, 1, 1, 1)
		parts.edge:SetPoint('TOPLEFT', parts.fill, 'TOPLEFT')
		parts.edge:SetPoint('TOPRIGHT', parts.fill, 'TOPRIGHT')
		parts.edge:SetHeight(UI.Pixel.Px(bar, 1))
		parts.edge:SetAlpha(0.3)
		parts.spark = bar:CreateTexture(nil, 'OVERLAY', nil, 6)
		parts.spark:SetColorTexture(1, 1, 1, 1)
		parts.spark:SetBlendMode('ADD')
		parts.spark:SetWidth(UI.Pixel.Px(bar, 2))
		parts.spark:SetPoint('TOP', parts.fill, 'TOPRIGHT', 0, 0)
		parts.spark:SetPoint('BOTTOM', parts.fill, 'BOTTOMRIGHT', 0, 0)
		parts.spark:SetAlpha(0.55)
	end
	-- Type: names in Plex, the right-aligned figures in the numbers face.
	EachText(entry, function(region)
		local value = region:GetJustifyH() == 'RIGHT'
		Plex(region, DB().fontSize, value, value and 'numbers' or nil)
		if value and not parts.value then parts.value = region end
	end)
	-- The icon on a small charcoal key, cropped.
	local icon = FindIcon(entry, bar)
	if icon then
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		local holder = icon:GetParent()
		if holder and holder.CreateTexture then
			parts.iconKey = holder:CreateTexture(nil, 'BACKGROUND', nil, -3)
			parts.iconKey:SetColorTexture(1, 1, 1, 1)
			Kit:Tint(parts.iconKey, 'black', 0.9)
			parts.iconKey:SetPoint('TOPLEFT', icon, 'TOPLEFT', -1, 1)
			parts.iconKey:SetPoint('BOTTOMRIGHT', icon, 'BOTTOMRIGHT', 1, -1)
		end
	end
	parts.top = CreateFrame('Frame', nil, entry)
	parts.top:SetAllPoints()
	parts.top:SetFrameLevel(entry:GetFrameLevel() + 6)
	parts.top:EnableMouse(false)
	parts.rank = Kit:Text(parts.top, '', 7, 'darkInk', true)
	Kit:Font(parts.rank, 7, 'OUTLINE', true, 'numbers')
	if icon then parts.rank:SetPoint('BOTTOMRIGHT', icon, 'BOTTOMRIGHT', 1, -1) else parts.rank:SetPoint('LEFT', 2, 0) end
	parts.lamp = Kit:Led(parts.top, 4, true)
	if icon then parts.lamp:SetPoint('TOPLEFT', icon, 'TOPLEFT', -1, 1) else parts.lamp:SetPoint('RIGHT', -2, 0) end
	Kit:ShowLed(parts.lamp, false)
	-- Per second, dim, just before the game's figure.
	parts.rate = Kit:Text(parts.top, '', 8, 'darkDim', false, true)
	Kit:Font(parts.rate, 8, 'OUTLINE', false, 'numbers')
	if parts.value then parts.rate:SetPoint('RIGHT', parts.value, 'LEFT', -5, 0) else parts.rate:SetPoint('RIGHT', bar, 'RIGHT', -60, 0) end
	-- A row arriving fades in.
	entry:HookScript('OnShow', function(self)
		if not Motion() then return end
		self:SetAlpha(0)
		Kit:FadeTo(self, 1, 'FAST')
	end)
	return parts
end

-- A field the row or its data may carry (both are tables; the value may be secret).
local function Field(entry, data, key)
	local value = type(data) == 'table' and data[key]
	if IsSecret(value) or value ~= nil and value ~= false then return value end
	return entry[key]
end

-- What the row shows now: rank, the player's lamp, per second.
local function FillRow(entry, data, rank, isLocal)
	local parts = DressRow(entry)
	if not parts then return end
	parts.rank:SetText(rank and tostring(rank) or '')
	parts.rank:SetShown(DB().blizzRanks and rank ~= nil)
	local mine = isLocal
	if mine == nil then mine = Field(entry, data, 'isLocalPlayer') end
	if IsSecret(mine) and parts.lamp.SetAlphaFromBoolean then
		Kit:ShowLed(parts.lamp, true)
		parts.lamp:SetAlphaFromBoolean(mine, 1, 0)
	else
		Kit:ShowLed(parts.lamp, mine == true)
		parts.lamp:SetAlpha(1)
	end
	local rate = Field(entry, data, 'amountPerSecond')
	-- The figure may be secret: tested only for being there, then formatted by the game.
	if DB().blizzRate and AbbreviateNumbers and (IsSecret(rate) or rate ~= nil) then
		pcall(function() parts.rate:SetText(AbbreviateNumbers(rate)) end)
		parts.rate:Show()
	else
		parts.rate:Hide()
	end
	Art(parts)
	return mine
end

-- The top spot: a quiet blip when you take it, at most every 20 s.
local lastTop, lastBlip = {}, 0
local function TopSpot(box, mine)
	local now = mine == true
	if now and not lastTop[box] and DB().blizzTopBlip and GetTime() - lastBlip > 20 then
		lastBlip = GetTime()
		Sound('blip')
	end
	lastTop[box] = now
end

local restyle = {} -- one function per hooked list, to repaint its rows after a setting changes
local boxes = {}   -- every hooked list's row pass, for the event sweep
local function HookScrollBox(owner)
	local box = owner and owner.GetScrollBox and owner:GetScrollBox()
	if not box or blizzardWindows[box] then return end
	blizzardWindows[box] = true
	local function Each()
		if not box.ForEachFrame then return end
		local order = 0
		box:ForEachFrame(function(frame, data)
			order = order + 1
			local rank = order
			if box.FindElementDataIndex and type(data) == 'table' then
				local ok, index = pcall(box.FindElementDataIndex, box, data)
				if ok and type(index) == 'number' and not IsSecret(index) then rank = index end
			end
			-- Errors reach the error handler (UI:Safe) rather than vanishing.
			UI:Safe(function()
				local mine = FillRow(frame, data, rank)
				if rank == 1 and not IsSecret(mine) then TopSpot(box, mine) end
			end)
		end)
	end
	boxes[#boxes + 1] = Each
	restyle[#restyle + 1] = function()
		for _, parts in pairs(rowParts) do Art(parts) end
		Each()
	end
	for _, method in ipairs({'Update', 'SetDataProvider', 'FullUpdate'}) do
		if type(box[method]) == 'function' then hooksecurefunc(box, method, function() UI:Safe(Each) end) end
	end
	box:HookScript('OnShow', function() C_Timer.After(0, function() UI:Safe(Each) end) end)
	UI:Safe(Each)
	-- The scroll bar: a hairline track with a small pill thumb; its arrows go.
	local scroll = owner.GetScrollBar and owner:GetScrollBar()
	if scroll and not Forbidden(scroll) and not blizzardWindows[scroll] then
		blizzardWindows[scroll] = true
		for _, arrow in ipairs({scroll.Back, scroll.Forward}) do if arrow then FadeArt(arrow) end end
		local track = scroll.Track
		if track and not Forbidden(track) then
			FadeArt(track)
			local line = track:CreateTexture(nil, 'BACKGROUND')
			line:SetColorTexture(1, 1, 1, 1)
			Kit:Tint(line, 'darkEdge', 0.9)
			line:SetPoint('TOP')
			line:SetPoint('BOTTOM')
			line:SetWidth(UI.Pixel.Px(track, 1))
			local thumb = track.Thumb
			if thumb and not Forbidden(thumb) then
				FadeArt(thumb)
				local pill = thumb:CreateTexture(nil, 'ARTWORK')
				pill:SetTexture(Kit.media..'round-3.tga')
				Kit:Tint(pill, 'darkDim', 0.9)
				pill:SetPoint('TOP')
				pill:SetPoint('BOTTOM')
				pill:SetWidth(4)
			end
		end
	end
end

-- A sweep over every hooked list a moment after the meter's data changes,
-- for rows the list filled without an Update call.
local sweepQueued
local function SweepRows()
	if sweepQueued then return end
	sweepQueued = true
	C_Timer.After(0.2, function()
		sweepQueued = false
		for _, Each in ipairs(boxes) do UI:Safe(Each) end
	end)
end

-- Windows --------------------------------------------------------------------------------------
-- Edit Mode sets the window's background opacity on its Background texture;
-- the housing follows it. The texture itself is emptied, not faded, so that
-- opacity setting keeps its meaning.
local function Behind(window, background, top)
	local housing = Housing(window, {left = 2, right = 2, top = top or 2, bottom = 2}, window)
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

local HEADER_ROW = 16

-- The printed header above the window: lamp, DM-1, the meter's name.
local function Header(window, housing)
	local parts = windowParts[window]
	if parts then return parts end
	parts = {}
	windowParts[window] = parts
	parts.strip = CreateFrame('Frame', nil, housing)
	parts.strip:SetPoint('TOPLEFT', housing, 'TOPLEFT', 8, -3)
	parts.strip:SetPoint('TOPRIGHT', housing, 'TOPRIGHT', -8, -3)
	parts.strip:SetHeight(HEADER_ROW - 4)
	parts.lamp = Kit:Led(parts.strip, 5, false)
	parts.lamp:SetPoint('LEFT', 0, 0)
	parts.model = Kit:Label(parts.strip, 'DM-1', 'darkInk', 8, true)
	parts.model:SetPoint('LEFT', parts.lamp, 'RIGHT', 5, 0)
	parts.title = Kit:Label(parts.strip, 'Damage meter', 'darkDim', 8)
	parts.title:SetPoint('LEFT', parts.model, 'RIGHT', 5, 0)
	parts.rule = parts.strip:CreateTexture(nil, 'ARTWORK')
	parts.rule:SetColorTexture(1, 1, 1, 1)
	Kit:Tint(parts.rule, 'darkEdge', 0.8)
	parts.rule:SetPoint('LEFT', parts.title, 'RIGHT', 6, 0)
	parts.rule:SetPoint('RIGHT', parts.strip, 'RIGHT', 0, 0)
	parts.rule:SetHeight(UI.Pixel.Px(parts.strip, 1))
	return parts
end

local function TimerPanel(window)
	local timer = window.SessionTimer
	if not timer or Forbidden(timer) or blizzardWindows[timer] then return end
	blizzardWindows[timer] = true
	Plex(timer, DB().fontSize, true, 'numbers')
	Kit:Tint(timer, 'lcdInk')
	local panel = Kit:LCDPanel(window, {radius = 3})
	panel:SetFrameLevel(max(window:GetFrameLevel() - 1, 0))
	Kit:Relevel(panel)
	panel:SetPoint('TOPLEFT', timer, 'TOPLEFT', -4, 3)
	panel:SetPoint('BOTTOMRIGHT', timer, 'BOTTOMRIGHT', 4, -3)
end

-- Header text the game colors gold: our ink, kept when the game recolors it.
local inked = setmetatable({}, {__mode = 'k'})
local function Ink(region, token)
	if not Is(region, 'FontString') or inked[region] then return end
	inked[region] = token
	Kit:Tint(region, token)
	hooksecurefunc(region, 'SetTextColor', function(self)
		if inked[self] == 'busy' then return end
		local wanted = inked[self]
		inked[self] = 'busy'
		Kit:Tint(self, wanted)
		inked[self] = wanted
	end)
end

-- Everything in the window's chrome the names below don't reach (Forever's
-- title and its segment button among them): every FontString in our type,
-- every small button on a key. The lists, rows and side window are left out.
local function SweepChrome(window, skip)
	local function Walk(frame, depth)
		if skip[frame] or rowParts[frame] or keyed[frame] == true then return end
		for _, region in ipairs({frame:GetRegions()}) do
			if Is(region, 'FontString') and region ~= window.SessionTimer then
				Plex(region, DB().fontSize, true)
				Ink(region, 'darkInk')
			end
		end
		if depth >= 3 then return end
		for _, child in ipairs({frame:GetChildren()}) do
			if not skip[child] and not Forbidden(child) then
				if Is(child, 'Button') and not keyed[child] and not Is(child, 'StatusBar') then
					local _, height = child:GetSize()
					if not IsSecret(height) and type(height) == 'number' and height > 0 and height <= 32 then
						UI:Safe(DressKey, child)
					end
				end
				Walk(child, depth + 1)
			end
		end
	end
	Walk(window, 0)
end

local function StyleSessionWindow(window)
	if Forbidden(window) or blizzardWindows[window] then return end
	blizzardWindows[window] = true
	local device = DB().blizzHeader
	if window.Header and window.Header.SetAlpha then window.Header:SetAlpha(0) end
	local container = window.MinimizeContainer
	local background = (window.GetBackground and select(2, pcall(window.GetBackground, window))) or (container and container.Background)
	if not Is(background, 'Texture') then background = container and container.Background end
	local housing = Behind(window, background, device and HEADER_ROW + 2 or 2)
	if device then UI:Safe(Header, window, housing) end
	UI:Safe(TimerPanel, window)
	-- The lists first, so a problem in the chrome below can't stop the rows.
	UI:Safe(HookScrollBox, window)
	local source = window.SourceWindow or (container and container.SourceWindow)
	if source and not Forbidden(source) then
		UI:Safe(Behind, source, source.Background)
		UI:Safe(HookScrollBox, source)
	end
	if type(window.ShowLocalPlayerEntry) == 'function' then
		hooksecurefunc(window, 'ShowLocalPlayerEntry', function(self)
			local entry = self.MinimizeContainer and self.MinimizeContainer.LocalPlayerEntry
			if entry then UI:Safe(FillRow, entry, nil, nil, true) end
		end)
	end
	-- Named chrome.
	UI:Safe(function()
		local typeDropdown = window.DamageMeterTypeDropdown
		if typeDropdown then
			DressKey(typeDropdown, 'chevron-down', 9)
			Plex(typeDropdown.TypeName, DB().fontSize, true)
			Ink(typeDropdown.TypeName, 'darkInk')
		end
		local session = window.SessionDropdown
		if session then
			DressKey(session)
			if session.ResetButton then
				DressKey(session.ResetButton, 'trash', 9)
				session.ResetButton:HookScript('OnClick', function() Sound('latch-up') end)
			end
		end
		if window.SettingsDropdown then DressKey(window.SettingsDropdown, 'more', 10) end
		local minimize = window.MinimizeButton
		if minimize then
			local key = DressKey(minimize, window.isMinimized and 'chevron-down' or 'chevron-up', 9)
			if key and type(window.SetMinimized) == 'function' then
				hooksecurefunc(window, 'SetMinimized', function(_, collapsed)
					if key.icon then Kit:SetIcon(key.icon, collapsed and 'chevron-down' or 'chevron-up') end
					FadeArt(minimize)
				end)
			end
		end
		-- The grip.
		local grip = container and container.ResizeButton
		if grip and not Forbidden(grip) and not keyed[grip] then
			keyed[grip] = true
			FadeArt(grip)
			local glyph = Kit:Icon(grip, 'grip', 11, 'darkDim')
			glyph:SetPoint('CENTER')
		end
	end)
	-- Whatever the names missed.
	local skip = {[housing] = true}
	for _, owner in ipairs({window, source}) do
		local box = owner and owner.GetScrollBox and owner:GetScrollBox()
		if box then skip[box] = true end
		local bar = owner and owner.GetScrollBar and owner:GetScrollBar()
		if bar then skip[bar] = true end
	end
	if source then skip[source] = true end
	if container and container.LocalPlayerEntry then skip[container.LocalPlayerEntry] = true end
	UI:Safe(SweepChrome, window, skip)
	window:HookScript('OnShow', function() C_Timer.After(0, function() UI:Safe(SweepChrome, window, skip); SweepRows() end) end)
end

local function StyleBlizzard()
	local meter = _G.DamageMeter
	if Forbidden(meter) or type(meter.ForEachSessionWindow) ~= 'function' then return end
	meter:ForEachSessionWindow(function(window) UI:Safe(StyleSessionWindow, window) end)
end

-- A fight starting sweeps every header lamp on; a reset flashes them.
local function Lamps(state)
	for _, parts in pairs(windowParts) do
		if state == 'fight' then
			Kit:SetLed(parts.lamp, true, 'red')
			if Motion() then Kit:Flash(parts.strip, {token = 'red', alpha = 0.45}) end
		elseif state == 'reset' then
			if Motion() then Kit:Flash(parts.strip, {token = 'lamp', alpha = 0.5}) end
		else
			Kit:SetLed(parts.lamp, false)
		end
	end
end

-- Replacing the game's meter: its session windows (Edit Mode systems) are
-- never moved or reparented, only made invisible and click-through, and put
-- back exactly as they were when the setting is turned off.
local function HasMeterAPI()
	return C_DamageMeter and C_DamageMeter.GetCombatSessionFromType and Enum and Enum.DamageMeterType and Enum.DamageMeterSessionType
end

-- Only while the DM-1 meter is on, so turning it off never leaves no meter at all.
local function Replacing() return DB().replaceGame and DB().own and HasMeterAPI() and true or false end

local concealed = setmetatable({}, {__mode = 'k'}) -- window -> {mouse = {}, wheel = {}}
local concealHooked = setmetatable({}, {__mode = 'k'})

local function Conceal(window)
	if Forbidden(window) then return end
	local saved = concealed[window] or {mouse = {}, wheel = {}}
	concealed[window] = saved
	window:SetAlpha(0)
	local function Walk(frame, depth)
		if frame.IsMouseEnabled then
			local enabled = frame:IsMouseEnabled()
			if not IsSecret(enabled) and enabled then
				saved.mouse[frame] = true
				frame:EnableMouse(false)
			end
		end
		if frame.IsMouseWheelEnabled then
			local wheel = frame:IsMouseWheelEnabled()
			if not IsSecret(wheel) and wheel then
				saved.wheel[frame] = true
				frame:EnableMouseWheel(false)
			end
		end
		if depth < 5 then
			for _, child in ipairs({frame:GetChildren()}) do
				if not Forbidden(child) then Walk(child, depth + 1) end
			end
		end
	end
	Walk(window, 0)
	if not concealHooked[window] then
		concealHooked[window] = true
		window:HookScript('OnShow', function(self)
			if Replacing() then C_Timer.After(0, function() UI:Safe(Conceal, self) end) end
		end)
	end
end

local function Reveal(window)
	local saved = concealed[window]
	if not saved then return end
	concealed[window] = nil
	window:SetAlpha(1)
	for frame in pairs(saved.mouse) do if not Forbidden(frame) then frame:EnableMouse(true) end end
	for frame in pairs(saved.wheel) do if not Forbidden(frame) then frame:EnableMouseWheel(true) end end
end


local function ApplyReplace()
	local meter = _G.DamageMeter
	if Forbidden(meter) or type(meter.ForEachSessionWindow) ~= 'function' then return end
	local replace = Replacing()
	meter:ForEachSessionWindow(function(window)
		if replace then UI:Safe(Conceal, window) else UI:Safe(Reveal, window) end
	end)
end

local blizzardHooked
local function HookBlizzard()
	local meter = _G.DamageMeter
	if Forbidden(meter) then return end
	if not blizzardHooked and type(meter.SetupSessionWindow) == 'function' then
		blizzardHooked = true
		-- New session windows are handled a frame later, outside Blizzard's own call.
		hooksecurefunc(meter, 'SetupSessionWindow', function()
			C_Timer.After(0, function()
				if Replacing() then UI:Safe(ApplyReplace) elseif DB().blizzard then UI:Safe(StyleBlizzard) end
			end)
		end)
		local events = CreateFrame('Frame')
		for _, event in ipairs({'PLAYER_REGEN_DISABLED', 'PLAYER_REGEN_ENABLED', 'DAMAGE_METER_RESET',
			'DAMAGE_METER_COMBAT_SESSION_UPDATED', 'DAMAGE_METER_CURRENT_SESSION_UPDATED'}) do
			pcall(events.RegisterEvent, events, event)
		end
		events:SetScript('OnEvent', function(_, event)
			if Replacing() then return end
			if event == 'PLAYER_REGEN_DISABLED' then Lamps('fight')
			elseif event == 'PLAYER_REGEN_ENABLED' then Lamps('off')
			elseif event == 'DAMAGE_METER_RESET' then Lamps('reset'); Sound('latch-up') end
			SweepRows()
		end)
	end
	if Replacing() then ApplyReplace()
	elseif DB().blizzard then StyleBlizzard() end
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
-- Up to three DM-1 windows, each with its own meter type and session, reading
-- the game's own combat data. The game hands sources over already ranked, so
-- its order is kept and nothing is ever sorted or compared; amounts, names and
-- GUIDs may be secret and then only reach setters (SetValue, SetText through
-- the game's AbbreviateNumbers, SetFormattedText, SetAlphaFromBoolean).
local owns = {}
local OWN_KEYS = {'dm.own', 'dm.own2', 'dm.own3'}
local OWN_SPOTS = {{'BOTTOMRIGHT', -16, 260}, {'BOTTOMRIGHT', -296, 260}, {'BOTTOMRIGHT', -576, 260}}
local HEADER, ROW_GAP, PAD = 26, 2, 3
local BuildOwns -- defined below

-- The meter types the client offers, in order, with our labels.
local TYPE_LABELS = {
	{'DamageDone', 'Damage'}, {'Dps', 'DPS'}, {'HealingDone', 'Healing'}, {'Hps', 'HPS'}, {'Absorbs', 'Absorbs'},
	{'Interrupts', 'Interrupts'}, {'Dispels', 'Dispels'}, {'DamageTaken', 'Damage taken'},
	{'AvoidableDamageTaken', 'Avoidable'}, {'EnemyDamageTaken', 'Enemy damage'}, {'Deaths', 'Deaths'},
}
local OLD_TYPES = {damage = 'DamageDone', healing = 'HealingDone', interrupts = 'Interrupts', dispels = 'Dispels', taken = 'DamageTaken'}

local function Types()
	local list, enum = {}, Enum and Enum.DamageMeterType
	if not enum then return list end
	for _, entry in ipairs(TYPE_LABELS) do
		if enum[entry[1]] ~= nil then list[#list + 1] = entry end
	end
	return list
end

local function TypeLabel(key)
	for _, entry in ipairs(TYPE_LABELS) do if entry[1] == key then return entry[2] end end
	return 'Damage'
end

-- Each window's own choices: meter type, session, and a size set with its grip.
local function Cfg(index)
	local db = DB()
	if type(db.windows) ~= 'table' then db.windows = {} end
	local cfg = db.windows[index]
	if type(cfg) ~= 'table' then
		local first = index == 1
		cfg = {type = first and (OLD_TYPES[db.ownType] or 'DamageDone') or (index == 2 and 'HealingDone' or 'DamageTaken'),
			session = first and db.ownSession == 'overall' and 'overall' or 'current'}
		db.windows[index] = cfg
	end
	if not (Enum.DamageMeterType and Enum.DamageMeterType[cfg.type]) then cfg.type = 'DamageDone' end
	return cfg
end

local function MeterType(cfg) return Enum.DamageMeterType[cfg.type] or Enum.DamageMeterType.DamageDone end

-- 'current', 'overall' or a session ID from the recent list.
local function SessionOf(cfg)
	if type(cfg.session) == 'number' then return nil, cfg.session end
	local kinds = Enum.DamageMeterSessionType
	return kinds[cfg.session == 'overall' and 'Overall' or 'Current'], nil
end

local function Recent()
	if not C_DamageMeter.GetAvailableCombatSessions then return {} end
	local ok, list = pcall(C_DamageMeter.GetAvailableCombatSessions)
	return ok and type(list) == 'table' and list or {}
end

local function Fetch(cfg)
	local kind, id = SessionOf(cfg)
	local meterType = MeterType(cfg)
	local ok, session
	if id then
		if C_DamageMeter.GetCombatSessionFromID then ok, session = pcall(C_DamageMeter.GetCombatSessionFromID, id, meterType) end
		-- A fight that has expired: back to the current one.
		if not ok or type(session) ~= 'table' then
			cfg.session = 'current'
			kind, id = SessionOf(cfg)
		end
	end
	if not id then ok, session = pcall(C_DamageMeter.GetCombatSessionFromType, kind, meterType) end
	return ok and type(session) == 'table' and session or nil, kind, id
end

local function Duration(kind, id)
	if id then
		for _, entry in ipairs(Recent()) do
			local entryID = entry.sessionID
			if not IsSecret(entryID) and entryID == id then return entry.durationSeconds end
		end
		return nil
	end
	local ok, seconds = pcall(C_DamageMeter.GetSessionDurationSeconds, kind)
	return ok and seconds or nil
end

local function Clock(seconds)
	seconds = Plain(seconds)
	if type(seconds) ~= 'number' then return '--:--' end
	return format('%d:%02d', floor(seconds / 60), floor(seconds % 60))
end

-- Numbers. Plain ones are formatted here (no raw floats: 72.9, 1.2K, 3.45M);
-- secret ones go to the game's AbbreviateNumbers with a K/M/B table, else to
-- SetFormattedText, so they are never read.
local abbreviate
local function AbbreviateOptions()
	if abbreviate ~= nil then return abbreviate or nil end
	abbreviate = false
	if CreateAbbreviateConfig then
		local ok, config = pcall(CreateAbbreviateConfig, {
			{breakpoint = 1000000000, abbreviation = 'B', significandDivisor = 10000000, fractionDivisor = 100, abbreviationIsGlobal = false},
			{breakpoint = 1000000, abbreviation = 'M', significandDivisor = 10000, fractionDivisor = 100, abbreviationIsGlobal = false},
			{breakpoint = 1000, abbreviation = 'K', significandDivisor = 100, fractionDivisor = 10, abbreviationIsGlobal = false},
			{breakpoint = 1, abbreviation = '', significandDivisor = 1, fractionDivisor = 1, abbreviationIsGlobal = false},
		})
		if ok and config then abbreviate = {config = config} end
	end
	return abbreviate or nil
end

local function SetNumber(fontString, value)
	if IsSecret(value) then
		local options = AbbreviateOptions()
		if AbbreviateNumbers and pcall(function()
			fontString:SetText(options and AbbreviateNumbers(value, options) or AbbreviateNumbers(value))
		end) then return end
		pcall(fontString.SetFormattedText, fontString, '%.0f', value)
		return
	end
	if type(value) ~= 'number' then fontString:SetText('') return end
	if value >= 1e9 then fontString:SetFormattedText('%.2fB', value / 1e9)
	elseif value >= 1e6 then fontString:SetFormattedText('%.2fM', value / 1e6)
	elseif value >= 1e4 then fontString:SetFormattedText('%.0fK', value / 1e3)
	elseif value >= 1e3 then fontString:SetFormattedText('%.1fK', value / 1e3)
	elseif value >= 10 or value == 0 then fontString:SetFormattedText('%d', floor(value + 0.5))
	else fontString:SetFormattedText('%.1f', value) end
end

local function OwnMotion() return DB().ownMotion and not Kit:Reduced() end
local function OwnSound(name) if DB().ownSounds then Kit:Play(name) end end

local CLASS_ICON_FILE = [[Interface\WorldStateFrame\ICONS-CLASSES]]

-- Rows -----------------------------------------------------------------------------------------
local function RowHeight() return Kit:Clamp(floor(DB().barHeight or 16), 12, 30) end

local ShowBreakdown, HideBreakdown -- defined below

local function OwnRow(window, index)
	local row = window.rows[index]
	if row then return row end
	row = CreateFrame('Button', nil, window.display.screen)
	row.window = window
	row.inner = CreateFrame('Frame', nil, row)
	row.inner:SetPoint('TOPLEFT')
	row.inner:SetPoint('BOTTOMRIGHT')
	row.rank = Kit:Text(row.inner, '', 8, 'darkDim', true)
	Kit:Font(row.rank, 8, nil, true, 'numbers')
	row.rank:SetJustifyH('RIGHT')
	row.iconBack = row.inner:CreateTexture(nil, 'BACKGROUND')
	row.iconBack:SetColorTexture(1, 1, 1, 1)
	Kit:Tint(row.iconBack, 'black', 0.9)
	row.icon = row.inner:CreateTexture(nil, 'ARTWORK')
	row.bar = CreateFrame('StatusBar', nil, row.inner)
	row.bar:SetStatusBarTexture(Kit.media..'bar-flat.tga')
	row.bar:SetMinMaxValues(0, 1)
	row.bar:SetValue(0)
	row.track = row.bar:CreateTexture(nil, 'BACKGROUND', nil, -2)
	row.track:SetAllPoints()
	row.track:SetColorTexture(1, 1, 1, 1)
	Kit:Tint(row.track, 'glass', 0.9)
	local fill = row.bar:GetStatusBarTexture()
	row.edge = row.bar:CreateTexture(nil, 'OVERLAY', nil, 5)
	row.edge:SetColorTexture(1, 1, 1, 1)
	row.edge:SetPoint('TOPLEFT', fill, 'TOPLEFT')
	row.edge:SetPoint('TOPRIGHT', fill, 'TOPRIGHT')
	row.edge:SetAlpha(0.3)
	row.spark = row.bar:CreateTexture(nil, 'OVERLAY', nil, 6)
	row.spark:SetColorTexture(1, 1, 1, 1)
	row.spark:SetBlendMode('ADD')
	row.spark:SetPoint('TOP', fill, 'TOPRIGHT', 0, 0)
	row.spark:SetPoint('BOTTOM', fill, 'BOTTOMRIGHT', 0, 0)
	row.spark:SetAlpha(0.6)
	-- Text above the bar (and its dot cover).
	row.texts = CreateFrame('Frame', nil, row.bar)
	row.texts:SetAllPoints()
	row.texts:SetFrameLevel(row.bar:GetFrameLevel() + 3)
	row.pct = Kit:Text(row.texts, '', 8, 'darkDim', false, true)
	row.rate = Kit:Text(row.texts, '', 8, 'darkDim', false, true)
	row.value = Kit:Text(row.texts, '', 9, 'darkInk', true, true)
	for _, text in ipairs({row.pct, row.rate, row.value}) do
		Kit:Font(text, text == row.value and 9 or 8, 'OUTLINE', text == row.value, 'numbers')
		text:SetJustifyH('RIGHT')
	end
	row.name = Kit:Text(row.texts, '', 9, 'darkInk', false, true)
	Kit:Font(row.name, 9, 'OUTLINE', false)
	row.name:SetJustifyH('LEFT')
	row.name:SetWordWrap(false)
	row.lamp = Kit:Led(row.inner, 4, true)
	Kit:ShowLed(row.lamp, false)
	row.hover = row.inner:CreateTexture(nil, 'HIGHLIGHT')
	row.hover:SetAllPoints()
	row.hover:SetColorTexture(1, 1, 1, 0.06)
	row:SetScript('OnEnter', function(self) if DB().ownTooltip then UI:Safe(ShowBreakdown, self) end end)
	row:SetScript('OnLeave', function() HideBreakdown() end)
	window.rows[index] = row
	return row
end

local function LayoutRow(row, height)
	local px = UI.Pixel.Px(row, 1)
	row.rank:ClearAllPoints()
	row.rank:SetPoint('LEFT', row.inner, 'LEFT', 0, 0)
	row.rank:SetWidth(14)
	row.icon:ClearAllPoints()
	row.icon:SetPoint('LEFT', row.inner, 'LEFT', 18, 0)
	row.icon:SetSize(height - 2, height - 2)
	row.iconBack:ClearAllPoints()
	row.iconBack:SetPoint('TOPLEFT', row.icon, 'TOPLEFT', -1, 1)
	row.iconBack:SetPoint('BOTTOMRIGHT', row.icon, 'BOTTOMRIGHT', 1, -1)
	row.lamp:ClearAllPoints()
	row.lamp:SetPoint('TOPLEFT', row.icon, 'TOPLEFT', -2, 2)
	row.bar:ClearAllPoints()
	row.bar:SetPoint('TOPLEFT', row.icon, 'TOPRIGHT', 3, 1)
	row.bar:SetPoint('BOTTOMRIGHT', row.inner, 'BOTTOMRIGHT', 0, 0)
	row.edge:SetHeight(px)
	row.spark:SetWidth(2 * px)
	if DB().bar == 'flat' then Kit:Unperforate(row.bar) else Kit:Perforate(row.bar, 'black', 'darkEdge') end
	-- Figures from the right: percent, per second, total; the name takes what is left.
	local db, anchor = DB(), nil
	for _, part in ipairs({{row.pct, db.ownPercent}, {row.rate, db.ownRate}, {row.value, true}}) do
		local text, shown = part[1], part[2]
		text:ClearAllPoints()
		text:SetShown(shown and true or false)
		if shown then
			if anchor then text:SetPoint('RIGHT', anchor, 'LEFT', -6, 0) else text:SetPoint('RIGHT', row.texts, 'RIGHT', -4, 0) end
			anchor = text
		end
	end
	row.name:ClearAllPoints()
	row.name:SetPoint('LEFT', row.texts, 'LEFT', 4, 0)
	row.name:SetPoint('RIGHT', anchor, 'LEFT', -6, 0)
end

-- Rows arriving: a short fade and slide from the left.
local function Arrive(row)
	if not OwnMotion() then
		row.inner:SetAlpha(1)
		return
	end
	Kit:Animate(row.inner, 0.22, 0, 1, function(value, progress)
		row.inner:ClearAllPoints()
		row.inner:SetPoint('TOPLEFT', row, 'TOPLEFT', -8 * (1 - value), 0)
		row.inner:SetPoint('BOTTOMRIGHT', row, 'BOTTOMRIGHT', -8 * (1 - value), 0)
		row.inner:SetAlpha(progress)
	end, function()
		row.inner:ClearAllPoints()
		row.inner:SetPoint('TOPLEFT')
		row.inner:SetPoint('BOTTOMRIGHT')
		row.inner:SetAlpha(1)
	end, 'settle')
end

local function ClassColor(class)
	class = Plain(class)
	local colors = CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS
	return class and colors and colors[class]
end

local function FillOwnRow(row, source, rank, top, total)
	local db = DB()
	if not row:IsShown() then
		row:Show()
		Arrive(row)
	end
	row.source = source
	row.rank:SetText(rank)
	-- Bar: the top source's amount is the scale; both only go to setters.
	pcall(row.bar.SetMinMaxValues, row.bar, 0, top.totalAmount)
	pcall(row.bar.SetValue, row.bar, source.totalAmount, OwnMotion() and Kit.SMOOTH or nil)
	local color = ClassColor(source.classFilename)
	if color and db.classColors then row.bar:SetStatusBarColor(color.r, color.g, color.b, 0.95)
	else row.bar:SetStatusBarColor(Kit:RGB('lamp')) end
	-- Icon: the spec's, else the class's, cropped.
	local spec = Plain(source.specIconID)
	local class = Plain(source.classFilename)
	if type(spec) == 'number' and spec > 0 then
		row.icon:SetTexture(spec)
		row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	elseif class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class] then
		local c = CLASS_ICON_TCOORDS[class]
		row.icon:SetTexture(CLASS_ICON_FILE)
		row.icon:SetTexCoord(c[1] + 0.02, c[2] - 0.02, c[3] + 0.02, c[4] - 0.02)
	else
		row.icon:SetTexture(134400)
		row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	end
	-- Name: shortened when plain; a secret one goes straight to the string.
	local name = source.name
	if not IsSecret(name) and type(name) == 'string' and Ambiguate then name = Ambiguate(name, 'short') end
	row.name:SetText(name)
	if color and db.ownNameColor then row.name:SetTextColor(color.r, color.g, color.b) else Kit:Tint(row.name, 'darkInk') end
	-- Figures.
	SetNumber(row.value, source.totalAmount)
	if db.ownRate then SetNumber(row.rate, source.amountPerSecond) end
	if db.ownPercent then
		local amount = source.totalAmount
		if not IsSecret(amount) and type(amount) == 'number' and type(total) == 'number' and total > 0 then
			row.pct:SetFormattedText('%d%%', floor(amount / total * 100 + 0.5))
		else
			row.pct:SetText('')
		end
	end
	-- Your row: a lamp; a secret answer sets it without being read.
	local mine = source.isLocalPlayer
	if IsSecret(mine) and row.lamp.SetAlphaFromBoolean then
		Kit:ShowLed(row.lamp, true)
		row.lamp:SetAlphaFromBoolean(mine, 1, 0)
	else
		Kit:ShowLed(row.lamp, mine == true)
		row.lamp:SetAlpha(1)
	end
end

-- Windows --------------------------------------------------------------------------------------
local function Visible(window)
	local height = RowHeight()
	local room = window:GetHeight() - HEADER - 8 - PAD * 2 + ROW_GAP
	if IsSecret(room) then return 1 end
	return max(1, floor(room / (height + ROW_GAP)))
end

local function SizeFor(rows) return HEADER + 8 + PAD * 2 + rows * (RowHeight() + ROW_GAP) - ROW_GAP end

local function LayoutOwn(window)
	if not window then return end
	local db, cfg = DB(), Cfg(window.index)
	-- While its grip is held the window follows the cursor; it snaps on release.
	if not window.docked and not window.dragging then
		window:SetSize(cfg.width or db.ownWidth, SizeFor(Kit:Clamp(floor(cfg.rows or db.ownRows or 8), 1, 40)))
	end
	local height = RowHeight()
	window.visible = Visible(window)
	for index = 1, max(window.visible, #window.rows) do
		local row = OwnRow(window, index)
		row:ClearAllPoints()
		row:SetPoint('TOPLEFT', window.display.screen, 'TOPLEFT', PAD, -PAD - (index - 1) * (height + ROW_GAP))
		row:SetPoint('TOPRIGHT', window.display.screen, 'TOPRIGHT', -PAD, -PAD - (index - 1) * (height + ROW_GAP))
		row:SetHeight(height)
		LayoutRow(row, height)
		row.enabled = index <= window.visible
		if not row.enabled then row:Hide() end
	end
end

local function SessionLabel(cfg)
	if cfg.session == 'overall' then return 'Overall' end
	if type(cfg.session) ~= 'number' then return 'Current' end
	return format('Fight %d', cfg.session)
end

-- A new fight or a reset: the header lamp blinks and the screen flashes.
local function Sweep(window)
	if not OwnMotion() then return end
	Kit:Flash(window.display, {token = 'lamp', alpha = 0.35})
	Kit:Blink(window.lamp, 0.12, true)
	C_Timer.After(0.6, function() Kit:Blink(window.lamp, nil, false) end)
end

local function UpdateOwn(window)
	if not window or not window:IsShown() then return end
	local cfg = Cfg(window.index)
	window.typeKey:SetKeyText(TypeLabel(cfg.type))
	window.sessionKey:SetKeyText(SessionLabel(cfg))
	local session, kind, id = Fetch(cfg)
	local sources = session and session.combatSources
	local count = type(sources) == 'table' and #sources or 0
	local visible = window.visible or 1
	window.offset = Kit:Clamp(window.offset or 0, 0, max(0, count - visible))
	-- Percent needs every amount plain; otherwise it is left blank.
	local total = session and Plain(session.totalAmount)
	if type(total) ~= 'number' and count > 0 then
		total = 0
		for _, source in ipairs(sources) do
			local amount = source.totalAmount
			if IsSecret(amount) or type(amount) ~= 'number' then total = nil break end
			total = total + amount
		end
	end
	local top = count > 0 and sources[1]
	for index, row in ipairs(window.rows) do
		local rank = window.offset + index
		local source = row.enabled and rank <= count and sources[rank]
		if source then UI:Safe(FillOwnRow, row, source, rank, top, total)
		else row:Hide(); row.source = nil end
	end
	window.empty:SetShown(count == 0)
	local seconds = Duration(kind, id)
	window.clock:SetText(Clock(seconds))
	-- A clock that went back to the start: a new fight began.
	local plain = Plain(seconds)
	if type(plain) == 'number' and type(window.lastSeconds) == 'number' and plain + 1 < window.lastSeconds then Sweep(window) end
	window.lastSeconds = plain
end

local queued
local function QueueOwn()
	if queued then return end
	queued = true
	C_Timer.After(0.25, function()
		queued = false
		for _, window in ipairs(owns) do UI:Safe(UpdateOwn, window) end
	end)
end

-- Pickers --------------------------------------------------------------------------------------
local function TypeMenu(window)
	local cfg = Cfg(window.index)
	local list = Types()
	local items = {}
	for _, entry in ipairs(list) do items[#items + 1] = {text = entry[2], checked = cfg.type == entry[1]} end
	Kit:Menu(window.typeKey, items, function(index)
		if not list[index] then return end
		cfg.type = list[index][1]
		window.offset = 0
		OwnSound('tick')
		UI:Safe(UpdateOwn, window)
	end, {side = 'CURSOR', width = 150})
end

local function SessionMenu(window)
	local cfg = Cfg(window.index)
	local items, actions = {}, {}
	local function Add(text, checked, action) items[#items + 1] = {text = text, checked = checked}; actions[#items] = action end
	Add('Current fight', cfg.session == 'current', function() cfg.session = 'current' end)
	Add('Overall', cfg.session == 'overall', function() cfg.session = 'overall' end)
	local recent = Recent()
	if #recent > 0 then
		items[#items + 1] = {separator = true}
		-- Newest first, at most ten.
		for index = #recent, max(1, #recent - 9), -1 do
			local entry = recent[index]
			local id = entry.sessionID
			if not IsSecret(id) and type(id) == 'number' then
				local name = entry.name
				if IsSecret(name) or type(name) ~= 'string' or name == '' then name = format('Fight %d', id) end
				Add(format('%s  %s', name, Clock(entry.durationSeconds)), cfg.session == id, function() cfg.session = id end)
			end
		end
	end
	Kit:Menu(window.sessionKey, items, function(index)
		if not actions[index] then return end
		actions[index]()
		window.offset = 0
		OwnSound('tick')
		UI:Safe(UpdateOwn, window)
	end, {side = 'CURSOR', width = 200})
end

local function ConfirmReset()
	Kit:AlertDialog({title = 'Reset the meter', confirm = 'Reset',
		text = 'Every fight the game\'s meter has recorded is cleared, in every window.',
		onConfirm = function()
			if C_DamageMeter.ResetAllCombatSessions then pcall(C_DamageMeter.ResetAllCombatSessions) end
			OwnSound('latch-up')
			for _, window in ipairs(owns) do Sweep(window) end
			QueueOwn()
		end})
end

-- Spell breakdown on hover ------------------------------------------------------------------------
local card
local CARD_ROWS, CARD_WIDTH = 8, 240

local function Card()
	if card then return card end
	card = Kit:Device(UIParent, {surface = 'dark', model = 'DM', title = '', width = CARD_WIDTH, height = 60, radius = 8})
	card:SetFrameStrata('TOOLTIP')
	Kit:Relevel(card)
	card:EnableMouse(false)
	card.kind = Kit:Label(card, '', 'darkDim', 8)
	card.kind:SetPoint('TOPRIGHT', -10, -8)
	card.note = Kit:Text(card, '', 8, 'darkDim', false)
	card.note:SetPoint('TOPLEFT', 10, -26)
	card.note:SetPoint('RIGHT', -10, 0)
	card.note:SetJustifyH('LEFT')
	card.rows = {}
	for index = 1, CARD_ROWS do
		local line = CreateFrame('Frame', nil, card)
		line:SetHeight(14)
		line:SetPoint('TOPLEFT', 10, -24 - (index - 1) * 16)
		line:SetPoint('TOPRIGHT', -10, -24 - (index - 1) * 16)
		line.icon = line:CreateTexture(nil, 'ARTWORK')
		line.icon:SetSize(12, 12)
		line.icon:SetPoint('LEFT')
		line.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		line.bar = CreateFrame('StatusBar', nil, line)
		line.bar:SetStatusBarTexture(Kit.media..'bar-flat.tga')
		line.bar:SetPoint('TOPLEFT', line.icon, 'TOPRIGHT', 4, 0)
		line.bar:SetPoint('BOTTOMRIGHT')
		line.bar:SetMinMaxValues(0, 1)
		local back = line.bar:CreateTexture(nil, 'BACKGROUND')
		back:SetAllPoints()
		back:SetColorTexture(1, 1, 1, 1)
		Kit:Tint(back, 'glass', 0.9)
		line.texts = CreateFrame('Frame', nil, line.bar)
		line.texts:SetAllPoints()
		line.texts:SetFrameLevel(line.bar:GetFrameLevel() + 2)
		line.pct = Kit:Text(line.texts, '', 8, 'darkDim', false, true)
		line.pct:SetPoint('RIGHT', -3, 0)
		line.amount = Kit:Text(line.texts, '', 8, 'darkInk', true, true)
		line.amount:SetPoint('RIGHT', line.pct, 'LEFT', -5, 0)
		Kit:Font(line.amount, 8, 'OUTLINE', true, 'numbers')
		Kit:Font(line.pct, 8, 'OUTLINE', false, 'numbers')
		line.name = Kit:Text(line.texts, '', 8, 'darkInk', false, true)
		line.name:SetPoint('LEFT', 3, 0)
		line.name:SetPoint('RIGHT', line.amount, 'LEFT', -5, 0)
		line.name:SetJustifyH('LEFT')
		line.name:SetWordWrap(false)
		card.rows[index] = line
	end
	card:Hide()
	return card
end

function HideBreakdown() if card then card:Hide() end end

function ShowBreakdown(row)
	local source, window = row.source, row.window
	if not source then return end
	local cfg = Cfg(window.index)
	local kind, id = SessionOf(cfg)
	local panel = Card()
	panel.model:SetText('DM')
	panel.title:SetText(source.name) -- may be secret: a setter only
	panel.kind:SetText(strupper(TypeLabel(cfg.type)))
	-- In a fight a row's GUID is secret and can't be asked about, except your own.
	local guid, creature = source.sourceGUID, source.sourceCreatureID
	if IsSecret(guid) or IsSecret(creature) then
		local mine = source.isLocalPlayer
		if not IsSecret(mine) and mine == true then guid, creature = UnitGUID('player'), nil else guid, creature = nil, nil end
	end
	local spells
	if guid or creature then
		local ok, data
		if id and C_DamageMeter.GetCombatSessionSourceFromID then
			ok, data = pcall(C_DamageMeter.GetCombatSessionSourceFromID, id, MeterType(cfg), guid, creature)
		elseif C_DamageMeter.GetCombatSessionSourceFromType then
			ok, data = pcall(C_DamageMeter.GetCombatSessionSourceFromType, kind, MeterType(cfg), guid, creature)
		end
		spells = ok and type(data) == 'table' and type(data.combatSpells) == 'table' and data.combatSpells or nil
	end
	local count = spells and min(#spells, CARD_ROWS) or 0
	panel.note:SetShown(count == 0)
	panel.note:SetText((guid or creature) and 'No spells recorded.' or 'Spell details show once the fight is over.')
	local total
	if count > 0 then
		total = 0
		for _, spell in ipairs(spells) do
			local amount = spell.totalAmount
			if IsSecret(amount) or type(amount) ~= 'number' then total = nil break end
			total = total + amount
		end
	end
	local getIcon, getName = C_Spell and C_Spell.GetSpellTexture, C_Spell and C_Spell.GetSpellName
	for index, line in ipairs(panel.rows) do
		local spell = index <= count and spells[index]
		if spell then
			line:Show()
			-- The spell's ID, icon and name may be secret: tested by type only, set as they are.
			local texture
			if getIcon then
				local ok, value = pcall(getIcon, spell.spellID)
				if ok then texture = value end
			end
			if type(texture) ~= 'nil' then line.icon:SetTexture(texture) else line.icon:SetTexture(134400) end
			local name
			if getName then
				local ok, value = pcall(getName, spell.spellID)
				if ok then name = value end
			end
			if type(name) ~= 'nil' then line.name:SetText(name) else line.name:SetText('') end
			pcall(line.bar.SetMinMaxValues, line.bar, 0, spells[1].totalAmount)
			pcall(line.bar.SetValue, line.bar, spell.totalAmount)
			line.bar:SetStatusBarColor(Kit:RGB('lamp'))
			SetNumber(line.amount, spell.totalAmount)
			local amount = spell.totalAmount
			if total and total > 0 and not IsSecret(amount) and type(amount) == 'number' then
				line.pct:SetFormattedText('%d%%', floor(amount / total * 100 + 0.5))
			else
				line.pct:SetText('')
			end
		else
			line:Hide()
		end
	end
	panel:SetHeight(32 + max(count, 1) * 16)
	panel:ClearAllPoints()
	local right = Plain(window:GetRight())
	local screen = UIParent:GetRight()
	if right and screen and right + CARD_WIDTH + 12 > screen then
		panel:SetPoint('TOPRIGHT', window, 'TOPLEFT', -6, 0)
	else
		panel:SetPoint('TOPLEFT', window, 'TOPRIGHT', 6, 0)
	end
	panel:Show()
end

-- Building -------------------------------------------------------------------------------------
local function HeaderKey(window, text, width, onClick, icon)
	local sound
	if not DB().ownSounds then sound = false end
	return Kit:Key(window, {text = text, icon = icon, width = width, height = 18, textSize = 8, onClick = onClick, sound = sound})
end

local function BuildOwn(index)
	if owns[index] or not HasMeterAPI() then return owns[index] end
	local db = DB()
	local window = Kit:Device(UIParent, {model = 'DM-'..index, title = '', radius = 10, width = db.ownWidth, height = 160})
	window.index = index
	window:SetFrameStrata('LOW')
	window:SetFrameLevel(4)
	Kit:Relevel(window)
	window:SetClampedToScreen(true)
	window:SetResizable(true)
	if window.SetResizeBounds then window:SetResizeBounds(200, SizeFor(1), 640, SizeFor(40)) end
	window.rows = {}
	window.offset = 0
	window.display = Kit:Screen(window, {inset = 3, radius = 6})
	window.display:SetPoint('TOPLEFT', 8, -HEADER)
	window.display:SetPoint('BOTTOMRIGHT', -8, 8)
	Kit:Relevel(window.display)
	-- Header: lamp, model, type and session keys, reset, and the session clock.
	window.title:Hide()
	window.typeKey = HeaderKey(window, 'Damage', 74, function() TypeMenu(window) end)
	window.typeKey:SetPoint('LEFT', window.model, 'RIGHT', 6, 0)
	window.sessionKey = HeaderKey(window, 'Current', 62, function() SessionMenu(window) end)
	window.sessionKey:SetPoint('LEFT', window.typeKey, 'RIGHT', 4, 0)
	window.clockPanel = Kit:LCDPanel(window, {radius = 3})
	window.clockPanel:SetSize(44, 16)
	window.clockPanel:SetPoint('TOPRIGHT', -8, -5)
	window.clock = Kit:Text(window.clockPanel, '--:--', 9, 'lcdInk', true)
	Kit:Font(window.clock, 9, nil, true, 'numbers')
	window.clock:SetPoint('RIGHT', -5, 0)
	window.ghost = Kit:Text(window.clockPanel, '88:88', 9, 'lcdGhost', true)
	Kit:Font(window.ghost, 9, nil, true, 'numbers')
	window.ghost:SetPoint('RIGHT', -5, 0)
	window.ghost:SetDrawLayer('ARTWORK', -1)
	window.resetKey = HeaderKey(window, nil, 22, ConfirmReset, 'trash')
	window.resetKey:SetPoint('RIGHT', window.clockPanel, 'LEFT', -4, 0)
	window.empty = Kit:Label(window.display.screen, 'No data', 'darkDim', 8)
	window.empty:SetPoint('CENTER')
	-- Scroll the list with the wheel.
	window.display:EnableMouseWheel(true)
	window.display:SetScript('OnMouseWheel', function(_, delta)
		window.offset = (window.offset or 0) - delta
		UI:Safe(UpdateOwn, window)
	end)
	-- The grip: drag to size; the height snaps to whole rows.
	window.grip = CreateFrame('Button', nil, window)
	window.grip:SetSize(12, 12)
	window.grip:SetPoint('BOTTOMRIGHT', -2, 2)
	window.grip:SetFrameLevel(window.display:GetFrameLevel() + 5)
	local glyph = Kit:Icon(window.grip, 'grip', 10, 'darkDim')
	glyph:SetPoint('CENTER')
	window.grip:SetScript('OnMouseDown', function(_, button)
		if button ~= 'LeftButton' or InCombatLockdown() or window.docked then return end
		window.dragging = true
		window:StartSizing('BOTTOMRIGHT')
	end)
	window.grip:SetScript('OnMouseUp', function()
		window:StopMovingOrSizing()
		window.dragging = false
		if window.docked then return end
		local cfg = Cfg(window.index)
		local width, height = Plain(window:GetWidth()), Plain(window:GetHeight())
		if width and height then
			cfg.width = floor(width + 0.5)
			cfg.rows = max(1, floor((height - HEADER - 8 - PAD * 2 + ROW_GAP) / (RowHeight() + ROW_GAP) + 0.5))
		end
		LayoutOwn(window)
		UI:PlaceMover(OWN_KEYS[window.index])
		UI:Safe(UpdateOwn, window)
	end)
	window:HookScript('OnSizeChanged', function()
		if window.sizing then return end
		window.sizing = true
		UI:Safe(LayoutOwn, window)
		window.sizing = false
	end)
	window:HookScript('OnHide', HideBreakdown)
	owns[index] = window
	LayoutOwn(window)
	UI:RegisterMover(window, OWN_KEYS[index], index == 1 and 'Meter' or 'Meter '..index, OWN_SPOTS[index])
	return window
end

local driver, combatTicker
local function Events()
	if driver then return end
	driver = CreateFrame('Frame')
	for _, event in ipairs({'DAMAGE_METER_COMBAT_SESSION_UPDATED', 'DAMAGE_METER_CURRENT_SESSION_UPDATED', 'DAMAGE_METER_RESET',
		'PLAYER_REGEN_DISABLED', 'PLAYER_REGEN_ENABLED', 'GROUP_ROSTER_UPDATE', 'PLAYER_ENTERING_WORLD'}) do
		pcall(driver.RegisterEvent, driver, event)
	end
	driver:SetScript('OnEvent', function(_, event)
		if event == 'PLAYER_REGEN_DISABLED' then
			for _, window in ipairs(owns) do Kit:SetLed(window.lamp, true, 'red'); Sweep(window) end
			if not combatTicker then combatTicker = C_Timer.NewTicker(1, QueueOwn) end
		elseif event == 'PLAYER_REGEN_ENABLED' then
			for _, window in ipairs(owns) do Kit:SetLed(window.lamp, false) end
			if combatTicker then combatTicker:Cancel(); combatTicker = nil end
		elseif event == 'DAMAGE_METER_RESET' then
			for _, window in ipairs(owns) do Sweep(window) end
		end
		QueueOwn()
	end)
end

function BuildOwns()
	if not DB().own or not HasMeterAPI() then
		for _, window in ipairs(owns) do window:Hide() end
		return
	end
	local count = Kit:Clamp(floor(DB().ownCount or 1), 1, #OWN_KEYS)
	for index = 1, #OWN_KEYS do
		if index <= count then
			local window = BuildOwn(index)
			if window then window:Show(); LayoutOwn(window) end
		elseif owns[index] then
			owns[index]:Hide()
		end
	end
	Events()
	QueueOwn()
end

-- Dock ----------------------------------------------------------------------------------------
local dock
function Dock()
	local db = DB()
	local first = owns[1]
	local windows = {}
	if db.dock then
		for _, instance in ipairs(DetailsWindows()) do
			if #windows < (db.dockWindows or 1) then windows[#windows + 1] = instance end
		end
		if first and first:IsShown() and #windows < 2 then windows[#windows + 1] = first end
	end
	-- Windows leaving the dock get their own housings back.
	for target, housing in pairs(housings) do
		if housing.docked then
			housing.docked = nil
			housing:SetShown(target:IsShown())
		end
	end
	if first and first.docked then
		first.docked = nil
		first.shell:Show()
		UI:PlaceMover(OWN_KEYS[1])
		LayoutOwn(first)
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
		if window == first then
			first.docked = true
			first.shell:Hide()
			first:ClearAllPoints()
			first:SetPoint('TOPLEFT', dock, 'TOPLEFT', inset - 8, y + HEADER)
			first:SetSize(width + 16, height + HEADER)
			LayoutOwn(first)
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
	if Loaded('Blizzard_DamageMeter') then UI:Safe(HookBlizzard) end
	BuildOwns()
	local events = CreateFrame('Frame')
	events:RegisterEvent('ADDON_LOADED')
	events:RegisterEvent('PLAYER_ENTERING_WORLD')
	events:SetScript('OnEvent', function(_, event, name)
		if event == 'ADDON_LOADED' then
			if name == 'Blizzard_DamageMeter' then C_Timer.After(0, function() UI:Safe(HookBlizzard) end)
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
		db.dockWidth, db.dockHeight, db.dockWindows, db.ownRows, db.ownWidth, db.ownCount, db.ownRate, db.ownPercent,
		db.ownNameColor, db.replaceGame, db.blizzFill, db.blizzRanks, db.blizzRate, Kit:DB().finish, Kit:DB().accent))
end

function module:Refresh()
	local now = Signature()
	if now == signature then return end
	signature = now
	if Details() then StyleAllDetails(true) end
	if _G.DamageMeter then
		UI:Safe(ApplyReplace)
		-- Shown again: skin it in place (once per window).
		if not Replacing() and DB().blizzard then UI:Safe(StyleBlizzard) end
	end
	for _, Each in ipairs(restyle) do UI:Safe(Each) end
	BuildOwns()
	for _, window in ipairs(owns) do UI:Safe(LayoutOwn, window) end
	QueueOwn()
	Dock()
end

-- Hub page ---------------------------------------------------------------------------------
local function Count(v) return format('%d', v) end
local function ResetSizes()
	local db = DB()
	for _, cfg in pairs(type(db.windows) == 'table' and db.windows or {}) do
		if type(cfg) == 'table' then cfg.rows, cfg.width = nil, nil end
	end
	for _, window in ipairs(owns) do UI:Safe(LayoutOwn, window) end
	QueueOwn()
end

UI:RegisterPage('meters', {title = 'Damage meters', order = 18, cards = {
	{title = 'DM-1 meter', rows = {
		{'switch', 'DM-1 meter', 'meters.own', 'SPEC-01 meter windows reading the game\'s own combat data. Pick the type and the fight from each window\'s header.', reload = true},
		{'switch', 'Replace the game\'s meter', 'meters.replaceGame', 'Hide the game\'s own meter windows while the DM-1 meter is on. Edit Mode still places them.'},
		{'slider', 'Windows', 'meters.ownCount', 1, 3, 1, 'Up to three DM-1 windows, each with its own type and fight.', format = Count},
		{'slider', 'Rows', 'meters.ownRows', 3, 20, 1, 'Rows per window, unless sized with its grip.', format = Count},
		{'slider', 'Width', 'meters.ownWidth', 200, 480, 10, nil, format = Count},
		{'button', 'Window sizes', 'Reset', ResetSizes, 'Windows sized with their grip go back to Rows and Width.'},
		{'switch', 'Per second', 'meters.ownRate', 'The per-second figure beside each total.'},
		{'switch', 'Percent', 'meters.ownPercent', 'Each row\'s share of the total (blank while the game keeps amounts secret).'},
		{'switch', 'Class-colored names', 'meters.ownNameColor'},
		{'switch', 'Spell breakdown', 'meters.ownTooltip', 'Hover a row for its top spells.'},
		{'switch', 'Animations', 'meters.ownMotion', 'Rows slide in, bars glide, a new fight sweeps the header lamp.'},
		{'switch', 'Sounds', 'meters.ownSounds', 'Ticks on the pickers, a latch on reset.'},
	}},
	{title = 'Style', rows = {
		{'segmented', 'Meters', 'style.meters', items = {{'device', 'Device'}, {'blizzard', 'Blizzard'}}, reload = true,
			note = 'Meter windows in dark SPEC-01 housings, with SPEC-01 bars and type.'},
		{'segmented', 'Bars', 'meters.bar', items = {{'dots', 'Dots'}, {'segments', 'Segments'}, {'flat', 'Flat'}}},
		{'slider', 'Bar height', 'meters.barHeight', 12, 28, 1, nil, format = Count},
		{'slider', 'Text size', 'meters.fontSize', 8, 14, 1, nil, format = Count},
		{'switch', 'Class colors', 'meters.classColors', 'Bars in class colors; off uses the lamp color.'},
	}},
	{title = 'Meters', rows = {
		{'switch', 'Details!', 'meters.details', 'Bars, type and housing set through Details\' own window settings.', reload = true},
		{'switch', 'Flat base skin', 'meters.detailsBase', 'Each Details window starts on its flat Minimalistic skin, once; a skin you pick later stays.'},
		{'switch', 'Blizzard meter skin', 'meters.blizzard', 'When the game\'s meter is shown (not replaced), its windows are skinned in place.', reload = true},
		{'switch', 'Skada', 'meters.skada', nil, reload = true},
		{'switch', 'Recount', 'meters.recount', nil, reload = true},
	}},
	{title = 'Game meter skin', rows = {
		{'switch', 'Device header', 'meters.blizzHeader', 'A printed DM-1 header (lamp, model, name) above each window.', reload = true},
		{'segmented', 'Fill', 'meters.blizzFill', items = {{'class', 'Class'}, {'key', 'Key color'}}},
		{'switch', 'Ranks', 'meters.blizzRanks', 'Each row\'s place printed on its icon.'},
		{'switch', 'Per second', 'meters.blizzRate', 'The per-second figure, dim, before the total.'},
		{'switch', 'Animations', 'meters.blizzMotion', 'New rows fade in, a fight start sweeps the header lamps.'},
		{'switch', 'Sounds', 'meters.blizzSounds', 'Ticks on the dropdowns, a latch on reset.'},
		{'switch', 'Top spot blip', 'meters.blizzTopBlip', 'A quiet blip when you take the top spot (at most every 20 s).'},
	}},
	{title = 'Dock', rows = {
		{'switch', 'Dock', 'meters.dock', 'One DM-0 device holding Details windows (and the first DM-1 window). Place it in Unlock mode.'},
		{'slider', 'Dock width', 'meters.dockWidth', 200, 640, 10, nil, format = Count},
		{'slider', 'Dock height', 'meters.dockHeight', 120, 520, 10, nil, format = Count},
		{'slider', 'Docked windows', 'meters.dockWindows', 1, 2, 1, nil, format = Count},
	}},
}})
