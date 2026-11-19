-- The menu (micro buttons) and bags devices, and the strip that sets them into
-- the console. Part of the action bars (ActionBars.lua).
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown, GetTime = CreateFrame, UIParent, InCombatLockdown, GetTime
local floor, max, min = math.floor, math.max, math.min
local format, ipairs, pairs, pcall, tonumber = format, ipairs, pairs, pcall, tonumber
local P = UI.ActionBarParts
local Forbidden, IsSecret = UI.Util.Forbidden, UI.Util.IsSecret
local BAGS, DB, Deck, Device, Fade, HW = P.BAGS, P.DB, P.Deck, P.Device, P.Fade, P.HW
local LayoutConsole, LightCap, MICRO, Sprites = P.LayoutConsole, P.LightCap, P.MICRO, P.Sprites

-- Menu and bags -----------------------------------------------------------------------------
-- Blizzard's micro buttons and bag slots move into the MN-1 device; they are
-- plain buttons, so this is safe at any time.
--
-- With SPEC-01 glyphs (the default), every micro button and bag slot shows a
-- printed glyph on its key instead of the game's art: the game's own textures
-- are only faded (never taken away), so the buttons keep working and the art
-- comes back with the Blizzard setting. A small lamp on the key lights while
-- its window is open and breathes amber when the game flashes the button
-- (talent points to spend, an unread guild or friend notice).
-- Glyphs in atlas order: the same list as MENU_ICONS in tools/build-hardware-art.py.
-- Kept in a function of its own: the main chunk may hold at most 200 locals.
local RepaintMenu, LayoutMenu, BuildMenu
;(function()
local MENU_ICONS = {'character', 'spellbook', 'talents', 'professions', 'achievements', 'legacy', 'quest', 'guild',
	'social', 'finder', 'journal', 'collections', 'menu', 'help', 'store', 'house',
	'map', 'pvp', 'backpack', 'bag', 'reagent', 'key', 'mount', 'hearth',
	'drawer', 'move', 'calendar', 'meter', 'lock', 'reload', 'macro'}
local MENU_INDEX = {}
for index, name in ipairs(MENU_ICONS) do MENU_INDEX[name] = index - 1 end
Deck.MENU_INDEX = MENU_INDEX -- the console's function keys use the same glyphs
local GLYPH_OF = {
	CharacterMicroButton = 'character', SpellbookMicroButton = 'spellbook', PlayerSpellsMicroButton = 'talents',
	ProfessionMicroButton = 'professions', TalentMicroButton = 'talents', AchievementMicroButton = 'achievements',
	LegacyMicroButton = 'legacy', QuestLogMicroButton = 'quest', GuildMicroButton = 'guild', SocialsMicroButton = 'social',
	LFDMicroButton = 'finder', LFGMicroButton = 'finder', EJMicroButton = 'journal', CollectionsMicroButton = 'collections',
	MainMenuMicroButton = 'menu', HelpMicroButton = 'help', StoreMicroButton = 'store', HousingMicroButton = 'house',
	WorldMapMicroButton = 'map', PVPMicroButton = 'pvp',
	MainMenuBarBackpackButton = 'backpack', CharacterBag0Slot = 'bag', CharacterBag1Slot = 'bag', CharacterBag2Slot = 'bag',
	CharacterBag3Slot = 'bag', CharacterReagentBag0Slot = 'reagent', KeyRingButton = 'key',
}
-- Bag slots and the container each shows, to tell an empty slot from a full one.
local BAG_ID = {MainMenuBarBackpackButton = 0, CharacterBag0Slot = 1, CharacterBag1Slot = 2, CharacterBag2Slot = 3,
	CharacterBag3Slot = 4, CharacterReagentBag0Slot = 5}

local menuKeys = {}   -- button -> our key frame (and its glyph and lamp)
local faded = {}      -- button -> {region = true}: the game's art we faded for glyphs
local alerting = {}   -- button -> true while the game flashes it

local function GlyphsOn() return DB().menuIcons ~= 'blizzard' end

local function BagIcon(button)
	return button.icon or button.Icon or _G[(button:GetName() or '')..'IconTexture']
end

-- A bag slot with nothing in it (the backpack is never empty).
local function EmptyBag(name)
	local bag = BAG_ID[name]
	if not bag or bag == 0 then return false end
	local toInventory = C_Container and C_Container.ContainerIDToInventoryID or _G.ContainerIDToInventoryID
	if not toInventory then return false end
	local ok, slot = pcall(toInventory, bag)
	if not ok or IsSecret(slot) or not slot then return false end
	local texture = GetInventoryItemTexture('player', slot)
	if IsSecret(texture) then return false end
	return texture == nil
end

-- The game's art on a micro button: every texture region but our own.
local function FadeArt(button, on)
	local list = faded[button]
	if on then
		if not list then list = {}; faded[button] = list end
		for _, region in ipairs({button:GetRegions()}) do
			if region.IsObjectType and region:IsObjectType('Texture') then
				list[region] = true
				region:SetAlpha(0)
			end
		end
		for _, getter in ipairs({'GetNormalTexture', 'GetPushedTexture', 'GetDisabledTexture', 'GetHighlightTexture'}) do
			local region = button[getter] and button[getter](button)
			if region then list[region] = true; region:SetAlpha(0) end
		end
		local overlay = button.NotificationOverlay
		if type(overlay) == 'table' and overlay.SetAlpha then list[overlay] = true; overlay:SetAlpha(0) end
	elseif list then
		for region in pairs(list) do region:SetAlpha(1) end
		faded[button] = nil
	end
end

local function PaintMenuButton(button)
	local key = menuKeys[button]
	if not key or not key.glyph then return end
	local name = button:GetName()
	local glyphs = GlyphsOn()
	local isBag = BAG_ID[name] ~= nil or name == 'KeyRingButton'
	-- Set into the console, a key can be just its icon on the housing (no keycap or slot).
	local strip = P.console and P.console.menuStrip
	local bare = glyphs and strip ~= nil and button:GetParent() == strip and DB().consoleBare ~= false
	key.skin:SetShown(not bare)
	if key.slotRing then HW.ShowSlot(key.slotRing, not bare) end
	local showGlyph = glyphs
	if isBag then
		local icon = BagIcon(button)
		local items = DB().bagIcons ~= 'glyphs'
		-- Bag icons: the item's own icon, the glyph only in an empty slot.
		if glyphs and items then showGlyph = EmptyBag(name) end
		-- The slot's own art (frame, quality ring, highlights) always goes with
		-- SPEC-01 keys; the bag's icon comes back, set in a black window on the key.
		FadeArt(button, glyphs)
		local window = glyphs and not showGlyph and icon ~= nil
		if icon then icon:SetAlpha((window or not glyphs) and 1 or 0) end
		if key.window then key.window:SetShown(window) end
	else
		FadeArt(button, glyphs)
	end
	key.glyph:SetShown(showGlyph)
	if showGlyph then
		local share = tonumber(DB()[isBag and 'bagsGlyph' or 'menuGlyph']) or (isBag and 0.6 or 0.68)
		if bare then share = max(share, 0.84) end
		local size = floor(min(button:GetWidth(), button:GetHeight()) * share + 0.5)
		key.glyph:SetSize(size, size)
		local enabled = not button.IsEnabled or button:IsEnabled()
		local hovered = button.IsMouseOver and button:IsMouseOver()
		local ink = bare and (P.Surface() == 'dark' and 'darkInk' or 'ink') or (LightCap() and 'ink' or 'darkInk')
		Kit:Tint(key.glyph, ink, not enabled and 0.3 or ((hovered and 1) or (bare and 0.72 or 0.82)))
	end
	-- The lamp: amber and breathing on an alert, lit while the window is open.
	local alert = alerting[button]
	if not alert and type(button.NotificationOverlay) == 'table' and button.NotificationOverlay.IsShown then
		alert = button.NotificationOverlay:IsShown()
	end
	if not alert and button.FlashBorder and button.FlashBorder.IsShown then alert = button.FlashBorder:IsShown() end
	local open = not isBag and button.GetButtonState and button:GetButtonState() == 'PUSHED'
	local lit = glyphs and not isBag and (alert or open) and true or false
	Kit:SetLed(key.lamp, lit, alert and 'amber' or nil)
	Kit:ShowLed(key.lamp, lit)
	if Kit.Breathe then
		if lit and alert and not key.breathing then
			key.breathing = true
			Kit:Breathe(key.lamp, true, {period = 1.4, low = 0.25})
		elseif key.breathing and not (lit and alert) then
			key.breathing = nil
			Kit:Breathe(key.lamp, false)
		end
	end
end

function RepaintMenu()
	for button in pairs(menuKeys) do UI:Safe(PaintMenuButton, button) end
end

local function DressMenuButton(button)
	if menuKeys[button] then return end
	local key = CreateFrame('Frame', nil, button)
	key:SetPoint('TOPLEFT', -1, 1)
	key:SetPoint('BOTTOMRIGHT', 1, -1)
	key:SetFrameLevel(max(button:GetFrameLevel() - 1, 0))
	key:EnableMouse(false)
	key.skin = Kit:Skin(key, Sprites()[1], 'BACKGROUND', 0)
	key.skin.kitMaxCorner = 6
	if HW.On() then
		key.slotRing = HW.Slot(key, key)
		HW.ShowSlot(key.slotRing, true)
	end
	menuKeys[button] = key
	local glyph = GLYPH_OF[button:GetName() or '']
	if glyph then
		local index = MENU_INDEX[glyph]
		local column, row = index % 8, floor(index / 8)
		-- The glyph sits above the game's (faded) art, so it goes on a level of its own.
		key.top = CreateFrame('Frame', nil, button)
		key.top:SetAllPoints(key)
		key.top:SetFrameLevel(button:GetFrameLevel() + 2)
		key.top:EnableMouse(false)
		key.glyph = key.top:CreateTexture(nil, 'OVERLAY', nil, 1)
		key.glyph:SetTexture(Kit.media..'icons-menu.tga')
		key.glyph:SetTexCoord(column / 8, (column + 1) / 8, row / 4, (row + 1) / 4)
		key.glyph:SetPoint('CENTER', key, 'CENTER', 0, 0)
		key.lamp = Kit:Led(key.top, 4, false)
		key.lamp:SetPoint('TOPRIGHT', key, 'TOPRIGHT', -3, -3)
		Kit:ShowLed(key.lamp, false)
		button:HookScript('OnEnter', function(self) UI:Safe(PaintMenuButton, self) end)
		button:HookScript('OnLeave', function(self) UI:Safe(PaintMenuButton, self) end)
		button:HookScript('OnEnable', function(self) UI:Safe(PaintMenuButton, self) end)
		button:HookScript('OnDisable', function(self) UI:Safe(PaintMenuButton, self) end)
		if button.SetButtonState then
			hooksecurefunc(button, 'SetButtonState', function(self) UI:Safe(PaintMenuButton, self) end)
		end
		local overlay = button.NotificationOverlay
		if type(overlay) == 'table' and overlay.HookScript then
			overlay:HookScript('OnShow', function() UI:Safe(PaintMenuButton, button) end)
			overlay:HookScript('OnHide', function() UI:Safe(PaintMenuButton, button) end)
		end
	end
	local bagName = button:GetName()
	if bagName and (BAG_ID[bagName] ~= nil or bagName == 'KeyRingButton') then
		-- Bag slots: the bag's icon sits in a black window inset on the key,
		-- cropped, like an action key's.
		local icon = BagIcon(button)
		key.window = key:CreateTexture(nil, 'ARTWORK', nil, 1)
		key.window:SetColorTexture(0, 0, 0, 0.9)
		key.window:SetPoint('TOPLEFT', key, 'TOPLEFT', 4, -4)
		key.window:SetPoint('BOTTOMRIGHT', key, 'BOTTOMRIGHT', -4, 4)
		key.window:Hide()
		if icon then
			icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
			icon:ClearAllPoints()
			icon:SetPoint('TOPLEFT', key.window, 'TOPLEFT', 1, -1)
			icon:SetPoint('BOTTOMRIGHT', key.window, 'BOTTOMRIGHT', -1, 1)
		end
	end
	UI:Safe(PaintMenuButton, button)
end

-- The game flashes a micro button to ask for attention.
local function WatchAlerts()
	local clickHooked = setmetatable({}, {__mode = 'k'})
	local function Set(button, on)
		if not menuKeys[button] then return end
		-- A pulse on a disabled button never flashes; one that times out never
		-- calls Stop, so a click on the button also clears it.
		if on and button.IsEnabled and not button:IsEnabled() then on = false end
		alerting[button] = on or nil
		if on and not clickHooked[button] and button.HasScript and button:HasScript('OnClick') then
			clickHooked[button] = true
			button:HookScript('OnClick', function(self)
				if alerting[self] then alerting[self] = nil; UI:Safe(PaintMenuButton, self) end
			end)
		end
		UI:Safe(PaintMenuButton, button)
	end
	if type(_G.MicroButtonPulse) == 'function' then
		hooksecurefunc('MicroButtonPulse', function(button) Set(button, true) end)
	end
	if type(_G.MicroButtonPulseStop) == 'function' then
		hooksecurefunc('MicroButtonPulseStop', function(button) Set(button, false) end)
	end
end

local laying
-- The game's own bag bar and micro menu code re-anchors these buttons now and
-- then (after a bag change, a layout pass); whenever one is moved off our
-- device or handed another parent, put the menu back together a frame later.
local guarded, pendingLayout = setmetatable({}, {__mode = 'k'}), false
local function Relayout()
	if pendingLayout then return end
	pendingLayout = true
	C_Timer.After(0, function()
		pendingLayout = false
		UI:Safe(LayoutMenu)
	end)
end
local function Guard(button)
	if guarded[button] then return end
	guarded[button] = true
	hooksecurefunc(button, 'SetPoint', function(self)
		if laying then return end
		local _, relative = self:GetPoint(1)
		if relative ~= P.menu then Relayout() end
	end)
	hooksecurefunc(button, 'SetParent', function(_, parent)
		if not laying and parent ~= P.menu then Relayout() end
	end)
end
-- Two small devices: the menu (micro buttons) and the bags (bag slots), each
-- with its own mover, key size, scale, orientation, columns, glyph size,
-- housing, mouseover fade and buttons to leave out. A button left out is
-- faded and loses the mouse (the game may show it again; it stays invisible).
local MENU_PAD, MENU_GAP = 6, 3
local bagsDevice
local hoverHooked = setmetatable({}, {__mode = 'k'})
local GROUPS = {menu = MICRO, bags = BAGS}

local function Opt(group, field) return DB()[group..field] end
-- Spellbook and talents come as one combined key (Retail) or two separate ones
-- (Forever), and the client builds all three. Only the ones its own micro menu
-- lays out belong on ours; asked of the menu once, after it has loaded.
local Unlisted
do
local SPELL_KEYS = {PlayerSpellsMicroButton = true, SpellbookMicroButton = true, TalentMicroButton = true}
local spellKeysListed
function Unlisted(name)
	if not SPELL_KEYS[name] then return false end
	if spellKeysListed == nil then
		local micro = _G.MicroMenu
		if type(micro) ~= 'table' or Forbidden(micro) or type(micro.GenerateButtonInfos) ~= 'function' then return false end
		spellKeysListed = false
		local ok, infos = pcall(micro.GenerateButtonInfos, micro)
		if ok and type(infos) == 'table' then
			local listed = {}
			for _, info in ipairs(infos) do
				local button = type(info) == 'table' and info.button
				local buttonName = type(button) == 'table' and button.GetName and button:GetName()
				if type(buttonName) == 'string' then listed[buttonName] = true end
			end
			if next(listed) then spellKeysListed = listed end
		end
	end
	return spellKeysListed and not spellKeysListed[name] or false
end
end
Deck.MenuUnlisted = Unlisted

local function LeftOut(group, name)
	if group == 'menu' and Unlisted(name) then return true end
	local list = Opt(group, 'Hide')
	return type(list) == 'table' and list[name] and true or false
end

-- Mouseover fade: the device shows while the mouse is over it or a key on it.
local function FadeDevice(device)
	if not device then return end
	local group = device.group
	local target = 1
	if Opt(group, 'Fade') and not device.hovered then target = 0.15 end
	if device.faded ~= target then
		device.faded = target
		Kit:FadeTo(device, target, 'FAST')
	end
end

local function Hover(device, on)
	if on then device.hovered = true; return FadeDevice(device) end
	C_Timer.After(0.15, function()
		device.hovered = device:IsMouseOver() and true or false
		FadeDevice(device)
	end)
end

local function HookHover(button, device)
	if hoverHooked[button] then return end
	hoverHooked[button] = true
	button:HookScript('OnEnter', function() Hover(device, true) end)
	button:HookScript('OnLeave', function() Hover(device, false) end)
end

-- A group's buttons, in order: the known names, then any other micro button
-- this client adds to its micro menu, then `extra` (the key ring).
local function Names(group, extra)
	local list, seen = {}, {}
	for _, name in ipairs(GROUPS[group]) do list[#list + 1] = name; seen[name] = true end
	local micro = _G.MicroMenu
	if group == 'menu' and type(micro) == 'table' and micro.GetChildren and not Forbidden(micro) then
		for _, child in ipairs({micro:GetChildren()}) do
			local name = child.GetName and child:GetName()
			if name and not seen[name] and name:find('MicroButton$') and child.IsObjectType and child:IsObjectType('Button') then
				list[#list + 1] = name
				seen[name] = true
			end
		end
	end
	if extra then list[#list + 1] = extra end
	return list
end

-- The layout a group uses: 'line', 'column', 'grid', 'balanced' or 'console'
-- (inside the console; only while there is one).
local function LayoutOf(group)
	local layout = Opt(group, 'Layout') or 'line'
	if layout == 'console' and not P.console then layout = 'line' end
	return layout
end
Deck.MenuLayoutOf = LayoutOf

-- Across and down for `count` keys. Balanced picks the most square grid whose
-- lines are all full (wider than tall); with none (a prime count), the most
-- square grid, its last line centred.
local function Shape(group, count)
	local layout = LayoutOf(group)
	if count <= 0 then return 1, 1 end
	if layout == 'column' then return 1, count end
	if layout == 'grid' then
		local columns = floor(tonumber(Opt(group, 'Columns')) or 0)
		local across = columns > 0 and min(columns, count) or count
		return across, math.ceil(count / across)
	end
	if layout == 'balanced' then
		local best
		for across = 2, count - 1 do
			local lines = count / across
			if lines == floor(lines) and across >= lines and across / lines <= 4 then
				if not best or math.abs(across - lines) < math.abs(best - count / best) then best = across end
			end
		end
		if not best then best = math.ceil(math.sqrt(count * 2)) end
		best = min(best, count)
		return best, math.ceil(count / best)
	end
	return count, 1
end

-- Bring a group's buttons onto `parent` at `size`; returns the ones to show.
local function Collect(group, extra, parent, size, device)
	local shown = {}
	local names = Names(group, extra)
	-- Blizzard's micro menu lays itself out again whenever a shown button leaves
	-- it, and then reads its first and last buttons' centres. A hidden button it
	-- never placed (Forever's Help key) has no centre and its code errors. Such
	-- buttons go first: a hidden button changing parent fires no OnShow/OnHide,
	-- so no layout runs, and by the time a shown one leaves they are gone.
	if group == 'menu' then
		for _, name in ipairs(names) do
			local button = _G[name]
			if button and not Forbidden(button) and button:GetParent() ~= parent
				and (not button:IsShown() or button:GetCenter() == nil) then
				button:SetParent(parent)
			end
		end
	end
	for _, name in ipairs(names) do
		local button = _G[name]
		if button and not Forbidden(button) then
			Guard(button)
			if button:GetParent() ~= parent then button:SetParent(parent) end
			button:SetSize(size, size)
			DressMenuButton(button)
			if device then HookHover(button, device) end
			if group == 'bags' and name ~= 'KeyRingButton' then button:Show() end
			if LeftOut(group, name) then
				-- Left out: faded, no mouse, and no gap where it was.
				button:SetAlpha(0)
				button:EnableMouse(false)
				button:ClearAllPoints()
				button:SetPoint('CENTER', parent, 'CENTER')
			else
				button:SetAlpha(1)
				button:EnableMouse(true)
				if button:IsShown() then shown[#shown + 1] = button end
			end
		end
	end
	return shown
end

-- Keys in a grid from (x, y), `across` to a line; a short last line is centred.
local function Place(shown, parent, x, y, size, gap, across, vertical)
	local count = #shown
	local lines = math.ceil(count / max(across, 1))
	for index, button in ipairs(shown) do
		local line, place = floor((index - 1) / across), (index - 1) % across
		local inLine = (line == lines - 1) and (count - line * across) or across
		local shift = (across - inLine) * (size + gap) / 2
		local px, py
		if vertical then px, py = line * (size + gap), place * (size + gap) + shift
		else px, py = place * (size + gap) + shift, line * (size + gap) end
		button:ClearAllPoints()
		button:SetPoint('TOPLEFT', parent, 'TOPLEFT', x + px, -(y + py))
	end
end

local function GroupSpacing(group) return Kit:Clamp(floor(tonumber(Opt(group, 'Spacing')) or MENU_GAP), 0, 12) end

-- Lay one group on its own device.
local function Lay(device, group, extra)
	local integrated = LayoutOf(group) == 'console'
	local enabled = Opt(group, 'Enable') ~= false
	if integrated then
		device:Hide()
		return
	end
	local size = Kit:Clamp(floor(tonumber(Opt(group, 'KeySize')) or 22), 16, 40)
	local gap = GroupSpacing(group)
	local shown = Collect(group, extra, device, size, device)
	local layout = LayoutOf(group)
	local across, lines = Shape(group, #shown)
	local vertical = layout == 'column'
	if vertical then across, lines = 1, max(#shown, 1) end
	if vertical then
		-- One column: the keys run down it.
		for index, button in ipairs(shown) do
			button:ClearAllPoints()
			button:SetPoint('TOPLEFT', device, 'TOPLEFT', MENU_PAD, -MENU_PAD - (index - 1) * (size + gap))
		end
	else
		Place(shown, device, MENU_PAD, MENU_PAD, size, gap, across, false)
	end
	device:SetSize(MENU_PAD * 2 + max(across, 1) * size + max(across - 1, 0) * gap,
		MENU_PAD * 2 + max(lines, 1) * size + max(lines - 1, 0) * gap)
	local housing = Opt(group, 'Housing') ~= false and DB().housing ~= false
	if device.shell then device.shell:SetShown(housing) end
	device:SetShown(enabled)
	-- Only a new scale re-places the device (its mover keeps the spot).
	local scale = Kit:Clamp(tonumber(Opt(group, 'Scale')) or 1, 0.5, 1.5)
	if device.baseScale ~= scale then
		device.baseScale = scale
		UI:SetMoverBaseScale(device.moverKey, scale, device)
	end
	FadeDevice(device)
end

-- The console strip: the groups set to 'console', in one line, menu then bags.
local STRIP_GROUP_GAP = 10
local function Integrated()
	local groups = {}
	for _, group in ipairs({'menu', 'bags'}) do
		if Opt(group, 'Enable') ~= false and LayoutOf(group) == 'console' then groups[#groups + 1] = group end
	end
	return groups
end

-- How many keys the strip will hold (for the console's layout, before placing).
local function StripCount(group, extra)
	local count = 0
	for _, name in ipairs(Names(group, extra)) do
		local button = _G[name]
		if button and not Forbidden(button) and not LeftOut(group, name)
			and ((group == 'bags' and name ~= 'KeyRingButton') or button:IsShown()) then count = count + 1 end
	end
	return count
end

-- The strip's width and height at `size` keys (0, 0 without one): one line,
-- or with `columns` a grid of every key (menu then bags), evenly spaced.
function Deck.MenuStrip(size, columns)
	if columns then
		local total = 0
		for _, group in ipairs(Integrated()) do total = total + StripCount(group, group == 'bags' and 'KeyRingButton' or nil) end
		if total == 0 then return 0, 0, 0 end
		local gap = GroupSpacing('menu')
		local across = Kit:Clamp(floor(columns), 1, total)
		local lines = math.ceil(total / across)
		return across * size + (across - 1) * gap, lines * size + (lines - 1) * gap, total
	end
	local width, total = 0, 0
	for index, group in ipairs(Integrated()) do
		local count = StripCount(group, group == 'bags' and 'KeyRingButton' or nil)
		if count > 0 then
			if total > 0 then width = width + STRIP_GROUP_GAP end
			width = width + count * size + (count - 1) * GroupSpacing(group)
			total = total + count
		end
	end
	if total == 0 then return 0, 0, 0 end
	return width, size, total
end

-- Edge of the console the strip runs along: 'header' or 'bottom'.
function Deck.MenuEdge() return DB().menuEdge == 'header' and 'header' or 'bottom' end

-- Where the header strip starts: centred between the console's name and its
-- readouts (`last`, the leftmost of them), or nil when it doesn't fit there.
function Deck.HeaderStripX(parent, last, width)
	local left, title = parent:GetLeft(), parent.title
	if not (left and title and last and last.GetLeft) then return nil end
	local titleLeft, readLeft = title:GetLeft(), last:GetLeft()
	if not titleLeft or not readLeft then return nil end
	local name = title.GetUnboundedStringWidth and title:GetUnboundedStringWidth() or title:GetStringWidth()
	local from, to = titleLeft - left + (name or 0) + 12, readLeft - left - 12
	if to - from < width then return nil end
	return UI.Pixel.Snap(parent, (from + to) / 2 - width / 2)
end

local function LayStrip()
	local strip = P.console and P.console.menuStrip
	if not strip then return 0 end
	local size = P.console.menuStripKey or 18
	local x, total = 0, 0
	-- A grid (set in the body by the console editor): every key in order, evenly spaced.
	local columns = P.console.menuStripColumns
	if columns then
		local all = {}
		for _, group in ipairs(Integrated()) do
			for _, button in ipairs(Collect(group, group == 'bags' and 'KeyRingButton' or nil, strip, size)) do all[#all + 1] = button end
		end
		Place(all, strip, 0, 0, size, GroupSpacing('menu'), Kit:Clamp(floor(columns), 1, max(#all, 1)), false)
		return #all
	end
	for _, group in ipairs(Integrated()) do
		local shown = Collect(group, group == 'bags' and 'KeyRingButton' or nil, strip, size)
		if #shown > 0 then
			if total > 0 then x = x + STRIP_GROUP_GAP end
			local gap = GroupSpacing(group)
			for index, button in ipairs(shown) do
				button:ClearAllPoints()
				button:SetPoint('LEFT', strip, 'LEFT', x + (index - 1) * (size + gap), 0)
			end
			x = x + #shown * size + (#shown - 1) * gap
			total = total + #shown
		end
	end
	return total
end

function LayoutMenu()
	if not P.menu or laying then return end
	laying = true
	local total
	local ok, problem = pcall(function()
		Lay(P.menu, 'menu')
		if bagsDevice then Lay(bagsDevice, 'bags', 'KeyRingButton') end
		total = LayStrip()
	end)
	laying = nil
	if not ok then error(problem, 0) end
	-- The strip holds more or fewer keys than the console made room for: lay it out again.
	if P.console and P.console.menuStrip and not P.console.laying and total ~= (P.console.menuStripCount or 0) then
		UI:Safe(LayoutConsole)
	end
	-- The game re-sets its micro button art as it updates them; fade it again.
	RepaintMenu()
end
Deck.LayoutMenu = function() if P.menu then UI:Safe(LayoutMenu) end end

local function QueueMenu() C_Timer.After(0, function() UI:Safe(LayoutMenu) end) end

local function MenuDevice(name, group, moverKey)
	local device = Device(name, '', '', {header = false, radius = 8, level = 6})
	device.group, device.moverKey = group, moverKey
	device:EnableMouse(true)
	device:SetScript('OnEnter', function(self) Hover(self, true) end)
	device:SetScript('OnLeave', function(self) Hover(self, false) end)
	device:SetScale(1)
	return device
end

function BuildMenu()
	P.menu = MenuDevice('JiberishSpec01Menu', 'menu', 'ab.menu')
	bagsDevice = MenuDevice('JiberishSpec01Bags', 'bags', 'ab.bags')
	LayoutMenu()
	-- The menu in the bottom-right corner, the bags just above it: out of the
	-- console's way on every screen.
	local menuHeight = P.menu:GetHeight() * P.menu:GetScale()
	UI:RegisterMover(P.menu, 'ab.menu', 'Menu', {'BOTTOMRIGHT', -12, 12})
	UI:RegisterMover(bagsDevice, 'ab.bags', 'Bags', {'BOTTOMRIGHT', -12, 12 + floor(menuHeight + 6)})
	-- Blizzard re-lays its micro menu and bag bar now and then; take the buttons back each time.
	if _G.UpdateMicroButtons then hooksecurefunc('UpdateMicroButtons', QueueMenu) end
	for _, owner in ipairs({_G.MicroMenu, _G.BagsBar}) do
		if owner and owner.Layout then hooksecurefunc(owner, 'Layout', QueueMenu) end
	end
	-- The micro menu's container is an Edit Mode system: it keeps its parent and
	-- is only faded (its buttons live in our device now). The bag bar is parked,
	-- as ElvUI does.
	local container = _G.MicroMenuContainer
	if container and not Forbidden(container) then container:SetAlpha(0) end
	UI:Retire(_G.BagsBar, true)
	local performance = _G.MainMenuMicroButton and (_G.MainMenuMicroButton.PerformanceIndicator or _G.MainMenuMicroButton.MainMenuBarPerformanceBar)
	Fade(performance)
	local micro = _G.MicroMenu
	if micro then Fade(micro.BorderArt); Fade(micro.BackgroundArt) end
	-- Glyph lamps and empty bag slots.
	WatchAlerts()
	local bagEvents = CreateFrame('Frame')
	for _, event in ipairs({'BAG_CONTAINER_UPDATE', 'PLAYER_EQUIPMENT_CHANGED', 'BAG_UPDATE_DELAYED'}) do
		pcall(bagEvents.RegisterEvent, bagEvents, event)
	end
	bagEvents:SetScript('OnEvent', function()
		for name in pairs(BAG_ID) do
			local button = _G[name]
			if button and menuKeys[button] then UI:Safe(PaintMenuButton, button) end
		end
	end)
end

-- The hub's rows to leave buttons out, one per button this client has.
local LABELS = {CharacterMicroButton = 'Character', SpellbookMicroButton = 'Spellbook', PlayerSpellsMicroButton = 'Talents and spells',
	ProfessionMicroButton = 'Professions', TalentMicroButton = 'Talents', AchievementMicroButton = 'Achievements',
	LegacyMicroButton = 'Legacy', QuestLogMicroButton = 'Quest log', GuildMicroButton = 'Guild', SocialsMicroButton = 'Social',
	LFDMicroButton = 'Group finder', LFGMicroButton = 'Group finder', EJMicroButton = 'Adventure guide',
	CollectionsMicroButton = 'Collections', MainMenuMicroButton = 'Game menu', HelpMicroButton = 'Help', StoreMicroButton = 'Shop',
	HousingMicroButton = 'Housing', WorldMapMicroButton = 'World map', PVPMicroButton = 'PvP',
	MainMenuBarBackpackButton = 'Backpack', CharacterBag0Slot = 'Bag 1', CharacterBag1Slot = 'Bag 2', CharacterBag2Slot = 'Bag 3',
	CharacterBag3Slot = 'Bag 4', CharacterReagentBag0Slot = 'Reagent bag', KeyRingButton = 'Key ring'}
function Deck.ButtonRows(group)
	local rows = {}
	local names = {}
	for _, name in ipairs(GROUPS[group]) do names[#names + 1] = name end
	if group == 'bags' then names[#names + 1] = 'KeyRingButton' end
	for _, name in ipairs(names) do
		rows[#rows + 1] = {'switch', LABELS[name] or name, 'actionbars.'..group..'Hide', since = '0.5.1',
			get = function() return not LeftOut(group, name) end,
			set = function(value)
				local list = DB()[group..'Hide']
				if type(list) ~= 'table' then list = {}; DB()[group..'Hide'] = list end
				list[name] = (not value) or nil
			end,
			hidden = function() return _G[name] == nil or (group == 'menu' and Unlisted(name)) end}
	end
	return rows
end

end)()

-- Shared with the other action bar files.
P.BuildMenu = BuildMenu
P.LayoutMenu = LayoutMenu
