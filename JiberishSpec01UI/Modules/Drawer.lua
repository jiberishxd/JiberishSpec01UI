-- The drawer: SPEC-01's drawer (component 31) as a home for small gadgets.
-- A sheet slides in from a screen edge over a soft dim, with a grab handle
-- you can drag back out (it follows the cursor, stretches past its rest with a
-- rubber band, and a quick flick dismisses it), a printed title and subtitle,
-- a row of keys to switch gadgets, and keys to pop the current gadget out
-- into its own floating device or close the drawer. Esc closes it.
--
-- Gadgets (the timer, the volume dial, the CPU meter, the calendar) register
-- through UI:RegisterGadget and build their content once into a body frame
-- that moves between the drawer and their own device when popped out. A slim
-- tab on the screen edge opens the drawer and can carry a short readout (the
-- running timer). Everything is our own frames: nothing is protected.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, GetTime, GetCursorPosition = CreateFrame, UIParent, GetTime, GetCursorPosition
local floor, max, min, abs = math.floor, math.max, math.min, math.abs

local module = UI:RegisterModule('drawer', {always = true})

-- defaults:begin
UI:RegisterDefaults('drawer', {enable = true, edge = 'bottom', dim = true, tab = true, last = false, popped = {}})
-- defaults:end

local function DB() return UI.db.drawer end
local function Reduced() return Kit:DB().reduceMotion end

-- Gadget registry -------------------------------------------------------------------------
-- Gadgets may register before or after the drawer is built.
local gadgets, ordered = {}, {}
local built = false
local BuildTab, Visibility -- defined with the sheet

function UI:RegisterGadget(key, def)
	if type(key) ~= 'string' or type(def) ~= 'table' then return end
	if not gadgets[key] then ordered[#ordered + 1] = key end
	def.key = key
	gadgets[key] = def
	table.sort(ordered, function(a, b)
		local oa, ob = gadgets[a].order or 50, gadgets[b].order or 50
		if oa ~= ob then return oa < ob end
		return a < b
	end)
	if built and BuildTab then UI:Safe(BuildTab) end
end

function UI:GetGadgets() return ordered, gadgets end

-- Each gadget's body is built once, on first show, into a holder frame.
local holders = {} -- key -> {frame, width, height, shown}
local function Holder(key)
	local entry = holders[key]
	if entry then return entry end
	local def = gadgets[key]
	if not def then return nil end
	local frame = CreateFrame('Frame', nil, UIParent)
	frame:Hide()
	entry = {frame = frame, width = 300, height = 160}
	holders[key] = entry
	if type(def.build) == 'function' then
		local ok, width, height = pcall(def.build, frame)
		if not ok then
			geterrorhandler()(width)
		else
			entry.width, entry.height = width or entry.width, height or entry.height
		end
	end
	frame:SetSize(entry.width, entry.height)
	return entry
end

-- The sheet ---------------------------------------------------------------------------------
local root, sheet, tabKeys
local current, open, closing = nil, false, false
local offset = 0 -- along the outward direction, from rest (positive = toward hiding)
local EDGES = {
	bottom = {point = 'BOTTOM', dx = 0, dy = -1},
	top = {point = 'TOP', dx = 0, dy = 1},
	left = {point = 'LEFT', dx = -1, dy = 0},
	right = {point = 'RIGHT', dx = 1, dy = 0},
}
local REST = 10
local HEAD = 108 -- handle, title, subtitle, tabs and rule above the body

local function Edge() return EDGES[DB().edge] or EDGES.bottom end

local function HiddenOffset()
	local edge = Edge()
	local size = edge.dx ~= 0 and sheet:GetWidth() or sheet:GetHeight()
	return size + REST + 30
end

local function Place()
	local edge = Edge()
	local at = REST + 0 - offset
	sheet:ClearAllPoints()
	sheet:SetPoint(edge.point, UIParent, edge.point, -edge.dx * at, -edge.dy * at)
end

local function SetDim(fraction)
	if root.dim then root.dim:SetAlpha((DB().dim and 0.38 or 0) * fraction) end
end

-- Whether a gadget is on screen, in the drawer or popped out; tells it on change.
local devices = {} -- key -> popped-out device
function Visibility(key)
	local entry, def = holders[key], gadgets[key]
	if not (entry and def) then return end
	local shown = (open and not closing and current == key) or (devices[key] ~= nil and devices[key]:IsShown())
	if shown == entry.shown then return end
	entry.shown = shown
	local hook = shown and def.onShow or def.onHide
	if type(hook) == 'function' then UI:Safe(hook) end
end

local function AllVisibility()
	for key in pairs(holders) do Visibility(key) end
end

-- Sizes the sheet for the gadget and puts its body in.
local function Mount(key)
	local entry = Holder(key)
	if not entry then return end
	if devices[key] then
		-- Docking a popped gadget back into the drawer.
		devices[key]:Hide()
		devices[key] = nil
		DB().popped[key] = nil
	end
	for other, held in pairs(holders) do
		if other ~= key and held.frame:GetParent() == sheet then held.frame:Hide() end
	end
	local def = gadgets[key]
	local width = max(entry.width + 40, 380, tabKeys and tabKeys.width + 120 or 0)
	sheet:SetSize(width, HEAD + entry.height + 22)
	sheet.title:SetText(strupper(def.title or key))
	sheet.subtitle:SetText(def.subtitle or ((def.model and (def.model..'  ') or '')..(def.description or '')))
	local frame = entry.frame
	frame:SetParent(sheet)
	frame:SetFrameLevel(sheet:GetFrameLevel() + 4)
	frame:ClearAllPoints()
	frame:SetPoint('TOP', sheet, 'TOP', 0, -HEAD)
	frame:Show()
	for tabKey, tab in pairs(tabKeys or {}) do
		if type(tab) == 'table' and tab.SetChecked then tab:SetChecked(tabKey == key) end
	end
	current = key
	DB().last = key
end

-- Pop-out devices -----------------------------------------------------------------------------
local PopOut

local function SaveDevicePosition(key, device)
	local x, y = device:GetCenter()
	local ux, uy = UIParent:GetCenter()
	if not (x and ux) then return end
	local ratio = device:GetEffectiveScale() / UIParent:GetEffectiveScale()
	if UI.SetMoverCenter then UI:SetMoverCenter('gadget.'..key, x * ratio - ux, y * ratio - uy) end
end

local deviceFrames = {} -- key -> the device frame, kept for re-use
local function Device(key)
	local device = deviceFrames[key]
	local entry, def = Holder(key), gadgets[key]
	if device then return device end
	device = Kit:Device(UIParent, {surface = 'paper', model = def.model or 'GD-1', title = def.title or key,
		width = entry.width + 28, height = entry.height + 44, radius = 14})
	device:SetFrameStrata('MEDIUM')
	device:SetClampedToScreen(true)
	device:SetMovable(true)
	device:EnableMouse(true)
	device:RegisterForDrag('LeftButton')
	device:SetScript('OnDragStart', function(self) self:StartMoving() end)
	device:SetScript('OnDragStop', function(self)
		self:StopMovingOrSizing()
		SaveDevicePosition(key, self)
	end)
	local close = Kit:Key(device, {width = 22, height = 20, icon = 'close', iconSize = 10, onClick = function()
		DB().popped[key] = nil
		device:Hide()
		devices[key] = nil
		Kit:Play('latch-up')
		Visibility(key)
	end})
	close:SetPoint('TOPRIGHT', -8, -5)
	Kit:AttachTooltip(close, 'Close')
	local dock = Kit:Key(device, {width = 22, height = 20, icon = 'chevron-down', iconSize = 10, onClick = function()
		UI:OpenDrawer(key)
	end})
	dock:SetPoint('RIGHT', close, 'LEFT', -4, 0)
	Kit:AttachTooltip(dock, 'Back to the drawer')
	device:Hide()
	deviceFrames[key] = device
	if UI.RegisterMover then UI:RegisterMover(device, 'gadget.'..key, def.title or key, {'CENTER', 0, 140}) end
	return device
end

function PopOut(key, quiet)
	local entry = Holder(key)
	if not entry then return end
	local device = Device(key)
	device:SetSize(entry.width + 28, entry.height + 44)
	local frame = entry.frame
	frame:SetParent(device)
	frame:SetFrameLevel(device:GetFrameLevel() + 4)
	frame:ClearAllPoints()
	frame:SetPoint('TOPLEFT', device, 'TOPLEFT', 14, -30)
	frame:Show()
	devices[key] = device
	DB().popped[key] = true
	device:Show()
	if UI.PlaceMover then UI:PlaceMover('gadget.'..key) end
	if not quiet then
		Kit:Play('open')
		if not Reduced() then
			device:SetAlpha(0)
			Kit:FadeTo(device, 1, 'FAST')
		end
	end
	if current == key and open then
		-- The drawer moves on to another gadget, or closes when there is none.
		local nextKey
		for _, other in ipairs(ordered) do if not devices[other] then nextKey = other break end end
		if nextKey then Mount(nextKey) else UI:CloseDrawer() end
	end
	Visibility(key)
end

function UI:PopOutGadget(key) if gadgets[key] then PopOut(key) end end

-- Building the sheet ----------------------------------------------------------------------------
local function TabWidth(key)
	return key.text and floor(key.text:GetStringWidth() + 34) or 60
end

function BuildTab()
	if not sheet then return end
	tabKeys = tabKeys or {}
	local x = 20
	for _, key in ipairs(ordered) do
		local def = gadgets[key]
		local tab = tabKeys[key]
		if not tab then
			tab = Kit:Key(sheet, {width = 80, height = 26, text = def.tab or def.title or key, led = true, sound = false,
				onClick = function() UI:OpenDrawer(key) end})
			tabKeys[key] = tab
		end
		tab:SetWidth(TabWidth(tab))
		tab:ClearAllPoints()
		tab:SetPoint('TOPLEFT', sheet, 'TOPLEFT', x, -62)
		tab:SetChecked(current == key)
		x = x + tab:GetWidth() + 6
	end
	tabKeys.width = x
end

local function Build()
	if root then return end
	root = CreateFrame('Button', 'JiberishSpec01Drawer', UIParent)
	root:SetAllPoints()
	root:SetFrameStrata('FULLSCREEN_DIALOG')
	root:Hide()
	root.dim = root:CreateTexture(nil, 'BACKGROUND')
	root.dim:SetAllPoints()
	root.dim:SetColorTexture(0, 0, 0, 1)
	root.dim:SetAlpha(0)
	root:SetScript('OnClick', function() UI:CloseDrawer() end)
	-- Esc closes it (the game hides every frame named in UISpecialFrames).
	if type(UISpecialFrames) == 'table' then table.insert(UISpecialFrames, 'JiberishSpec01Drawer') end
	root:SetScript('OnHide', function()
		-- Hidden by Esc (no animation) or at the end of a close: settle the state.
		if open then
			open, closing = false, false
			Kit:Play('latch-up')
		end
		AllVisibility()
	end)

	sheet = Kit:Device(root, {surface = 'paper', header = false, width = 420, height = 300, radius = 18})
	sheet:EnableMouse(true)
	sheet:SetFrameLevel(root:GetFrameLevel() + 5)
	Kit:Relevel(sheet)
	-- The grab handle: a short pill at the top; the whole top strip drags.
	sheet.grab = CreateFrame('Frame', nil, sheet)
	sheet.grab:SetPoint('TOPLEFT', 0, 0)
	sheet.grab:SetPoint('TOPRIGHT', 0, 0)
	sheet.grab:SetHeight(20)
	sheet.grab:EnableMouse(true)
	sheet.handle = Kit:Texture(sheet.grab, 'round-3', 'ARTWORK')
	local scale = sheet.handle.kitScale or 1
	sheet.handle:SetSize(44 / scale, 5 / scale)
	sheet.handle:SetPoint('TOP', sheet, 'TOP', 0, -8 / scale)
	Kit:Tint(sheet.handle, 'hair')
	sheet.title = Kit:Text(sheet, '', 13, 'ink')
	sheet.title:SetPoint('TOPLEFT', 22, -24)
	sheet.subtitle = Kit:Text(sheet, '', 10, 'dim')
	sheet.subtitle:SetPoint('TOPLEFT', sheet.title, 'BOTTOMLEFT', 0, -5)
	sheet.rule = Kit:Solid(sheet, 'hair', 'ARTWORK')
	sheet.rule:SetHeight(1)
	sheet.rule:SetPoint('TOPLEFT', 20, -98)
	sheet.rule:SetPoint('TOPRIGHT', -20, -98)
	sheet.close = Kit:Key(sheet, {width = 26, height = 24, icon = 'close', iconSize = 10, onClick = function() UI:CloseDrawer() end})
	sheet.close:SetPoint('TOPRIGHT', -18, -22)
	Kit:AttachTooltip(sheet.close, 'Close')
	sheet.pop = Kit:Key(sheet, {width = 26, height = 24, icon = 'copy', iconSize = 10, onClick = function()
		if current then PopOut(current) end
	end})
	sheet.pop:SetPoint('RIGHT', sheet.close, 'LEFT', -6, 0)
	Kit:AttachTooltip(sheet.pop, 'Pop out')

	-- Dragging the handle: follows the cursor along the way out, stretches the
	-- other way like a rubber band, and a flick or a long pull dismisses it.
	local dragging, startX, startY, startOffset, lastPos, lastTime, velocity
	local function Along()
		local edge = Edge()
		local x, y = GetCursorPosition()
		local s = sheet:GetEffectiveScale()
		x, y = x / s, y / s
		return (x - startX) * edge.dx + (y - startY) * edge.dy
	end
	sheet.grab:SetScript('OnMouseDown', function(self, button)
		if button ~= 'LeftButton' or not open or closing then return end
		local x, y = GetCursorPosition()
		local s = sheet:GetEffectiveScale()
		startX, startY = x / s, y / s
		startOffset, lastPos, lastTime, velocity = offset, 0, GetTime(), 0
		dragging = true
		self:SetScript('OnUpdate', function()
			local along = Along() + startOffset
			if along < 0 then along = -24 * (1 - 1 / (1 + (-along) / 60)) end -- rubber band
			offset = along
			Place()
			SetDim(1 - min(1, max(0, offset) / HiddenOffset()))
			local now = GetTime()
			local dt = now - lastTime
			if dt > 0.008 then
				velocity = velocity * 0.4 + 0.6 * (along - lastPos) / dt
				lastPos, lastTime = along, now
			end
		end)
	end)
	sheet.grab:SetScript('OnMouseUp', function(self)
		if not dragging then return end
		dragging = false
		self:SetScript('OnUpdate', nil)
		local far = offset > HiddenOffset() * 0.35
		if far or velocity > 650 then
			UI:CloseDrawer()
		else
			Kit:Animate(sheet.grab, 0.28, offset, 0, function(value)
				offset = value
				Place()
				SetDim(1)
			end, nil, 'settle')
		end
	end)
	BuildTab()
	built = true
end

-- Opening and closing ----------------------------------------------------------------------------
function UI:DrawerOpen() return open and not closing end

function UI:OpenDrawer(key)
	if not DB().enable then return end
	Build()
	key = key or (DB().last and gadgets[DB().last] and DB().last) or ordered[1]
	if not key or not gadgets[key] then return end
	BuildTab()
	if open and not closing then
		if current ~= key then
			local was = current
			Mount(key)
			Place()
			Kit:Play('tick')
			if was then Visibility(was) end
			Visibility(key)
		end
		return
	end
	Mount(key)
	BuildTab()
	root:EnableMouse(DB().dim and true or false)
	open, closing = true, false
	root:Show()
	Kit:Play('open')
	local from = HiddenOffset()
	if Reduced() then
		offset = 0
		Place()
		SetDim(1)
	else
		Kit:Animate(sheet.grab, 0.34, from, 0, function(value)
			offset = value
			Place()
			SetDim(1 - value / from)
		end, nil, 'toast')
	end
	AllVisibility()
end

function UI:CloseDrawer()
	if not (root and open) or closing then return end
	closing = true
	Kit:Play('latch-up')
	AllVisibility()
	local from, to = offset, HiddenOffset()
	local function Done()
		open, closing = false, false
		root:Hide()
		offset = to
	end
	if Reduced() then return Done() end
	Kit:Animate(sheet.grab, 0.22, from, to, function(value)
		offset = value
		Place()
		SetDim(1 - min(1, max(0, value) / to))
	end, Done, 'cubic')
end

function UI:ToggleDrawer(key)
	if open and not closing and (key == nil or key == current) then UI:CloseDrawer() else UI:OpenDrawer(key) end
end

-- The launcher tab ---------------------------------------------------------------------------------
local tab
local function LayoutTab()
	if not tab then return end
	local text = tab.readout:GetText()
	local hasText = text and text ~= ''
	tab.chevron:SetShown(not hasText)
	tab.readout:SetShown(hasText and true or false)
	tab:SetWidth(hasText and floor(tab.readout:GetStringWidth() + 30) or 34)
end

local function BuildLauncher()
	if tab then return end
	tab = CreateFrame('Button', 'JiberishSpec01DrawerTab', UIParent)
	tab:SetSize(34, 20)
	tab:SetFrameStrata('MEDIUM')
	tab.shell = Kit:Shell(tab, {surface = 'glass', radius = 6, alpha = 0.92})
	tab.lamp = Kit:Led(tab, 4, false)
	tab.lamp:SetPoint('LEFT', 7, 0)
	tab.chevron = Kit:Icon(tab, 'chevron-up', 10, 'darkInk')
	tab.chevron:SetPoint('LEFT', tab.lamp, 'RIGHT', 5, 0)
	tab.readout = Kit:Text(tab, '', 9, 'screenAccent', true)
	tab.readout:SetPoint('LEFT', tab.lamp, 'RIGHT', 5, 0)
	tab:RegisterForClicks('LeftButtonUp', 'RightButtonUp')
	tab:SetScript('OnClick', function() UI:ToggleDrawer() end)
	tab:SetScript('OnEnter', function(self) Kit:ShowTooltip(self, 'Drawer') end)
	tab:SetScript('OnLeave', function() Kit:HideTooltip() end)
	LayoutTab()
	if UI.RegisterMover then UI:RegisterMover(tab, 'drawer.tab', 'Drawer tab', {'RIGHT', 0, -40}) end
end

-- A gadget's short readout on the tab (the running timer); nil clears it.
function UI:SetDrawerTabText(text, token)
	if not tab then return end
	tab.readout:SetText(text or '')
	Kit:SetLed(tab.lamp, text ~= nil and text ~= '', token or 'lamp')
	LayoutTab()
end

-- Module ------------------------------------------------------------------------------------------
function module:Enable()
	if not DB().enable then return end
	BuildLauncher()
	tab:SetShown(DB().tab and true or false)
	-- Gadgets left popped out come back where they were.
	for key in pairs(DB().popped) do
		if gadgets[key] then UI:Safe(PopOut, key, true) else DB().popped[key] = nil end
	end
	self.ready = true
end

function module:Refresh()
	if not self.ready then return end
	if tab then tab:SetShown(DB().tab and true or false) end
	if root and open and not closing then
		root:EnableMouse(DB().dim and true or false)
		offset = 0
		Place()
		SetDim(1)
	end
end
