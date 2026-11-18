-- Hardware kit overlays: tooltip, popover, hover card, menu, context menu,
-- dialog, alert dialog, drawer and toast. Overlay frames are created once and
-- reused; nothing here is protected, so they are safe to show in combat.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, GetTime, InCombatLockdown = CreateFrame, UIParent, GetTime, InCombatLockdown
local max, min = math.max, math.min

local root, catcher, current
function Kit:Root()
	if root then return root end
	root = CreateFrame('Frame', 'JiberishSpec01Overlay', UIParent)
	root:SetAllPoints()
	-- Above the settings window and the deck, which are both full-screen dialogs.
	root:SetFrameStrata('FULLSCREEN_DIALOG')
	root:SetFrameLevel(100)
	-- Invisible full-screen button: a click outside the open popover closes it.
	catcher = CreateFrame('Button', nil, root)
	catcher:SetAllPoints()
	catcher:SetFrameLevel(110)
	catcher:RegisterForClicks('AnyUp')
	catcher:SetScript('OnClick', function() Kit:ClosePopover() end)
	catcher:Hide()
	return root
end

function Kit:ClosePopover()
	local panel = current
	current = nil
	if panel then
		panel:Hide()
		if panel.onClose then panel.onClose(panel) end
	end
	if catcher then catcher:Hide() end
end

-- 20 Popover ---------------------------------------------------------------
-- opts: width, height, side ('BOTTOM' | 'TOP' | 'RIGHT' | 'CURSOR'), fill, border, radius,
--       cache (any key; the panel and whatever build() made are reused), build(panel), onClose
local popovers = setmetatable({}, {__mode = 'k'})
function Kit:Popover(anchor, opts)
	opts = opts or {}
	self:ClosePopover()
	local parent = self:Root()
	local key = opts.cache or anchor
	local panel = popovers[key]
	local fresh = not panel
	if fresh then
		-- The reference popover: an LCD window in a white frame.
		panel = self:Panel(parent, {sprite = 'popover'})
		panel:SetFrameLevel(120)
		panel:EnableMouse(true)
		panel:SetClampedToScreen(true)
		popovers[key] = panel
	end
	panel:SetSize(opts.width or 200, opts.height or 120)
	panel:ClearAllPoints()
	local side = opts.side or 'BOTTOM'
	if side == 'CURSOR' then
		local x, y = self:Cursor(parent)
		panel:SetPoint('TOPLEFT', parent, 'BOTTOMLEFT', x, y)
	elseif side == 'TOP' then panel:SetPoint('BOTTOM', anchor, 'TOP', 0, 8)
	elseif side == 'RIGHT' then panel:SetPoint('LEFT', anchor, 'RIGHT', 8, 0)
	else panel:SetPoint('TOP', anchor, 'BOTTOM', 0, -8) end
	panel.onClose = opts.onClose
	if opts.build and (fresh or opts.rebuild) then opts.build(panel, fresh) end
	catcher:Show()
	panel:Show()
	current = panel
	if opts.sound ~= false then self:Play('open') end
	if opts.instant then panel:SetAlpha(1)
	else self:Animate(panel, 0.12, 0, 1, function(alpha) panel:SetAlpha(alpha) end) end
	return panel
end

function Kit:IsPopoverOpen(key) return current ~= nil and popovers[key] == current end

-- 10 Menu / 08 option lists --------------------------------------------------
-- items: strings or {text=, icon=, checked=, disabled=, separator=}
local ROW = 24
local function MenuRow(panel)
	local row = CreateFrame('Button', nil, panel)
	row:SetHeight(ROW)
	row.highlight = Kit:Texture(row, 'round-3', 'BACKGROUND')
	row.highlight:SetAllPoints()
	Kit:Tint(row.highlight, 'accent')
	row.highlight:Hide()
	row.icon = Kit:Icon(row, 'check', 12, 'ink')
	row.icon:SetPoint('LEFT', 8, 0)
	row.label = Kit:Label(row, '', 'ink')
	row.rule = Kit:Solid(row, 'line')
	row.rule:SetHeight(1)
	row.rule:SetPoint('LEFT', 6, 0); row.rule:SetPoint('RIGHT', -6, 0)
	row:SetScript('OnEnter', function(self)
		if self.item.disabled or self.item.separator then return end
		self.highlight:Show()
		Kit:Tint(self.label, 'onAccent'); Kit:Tint(self.icon, 'onAccent')
		Kit:Play('tick')
	end)
	row:SetScript('OnLeave', function(self)
		self.highlight:Hide()
		Kit:Tint(self.label, self.item.disabled and 'dim' or 'ink'); Kit:Tint(self.icon, 'ink')
	end)
	row:SetScript('OnClick', function(self)
		if self.item.disabled or self.item.separator or panel.kitChoosing then return end
		Kit:Play('down')
		local select = panel.onSelect
		if not (Kit.Faithful and Kit:Faithful('chosen')) then
			Kit:ClosePopover()
			if select then select(self.index, self.item) end
			return
		end
		-- menu-chosen: the choice applies now; the option flashes twice and the
		-- menu closes after it (unless something else replaced it meanwhile).
		if select then select(self.index, self.item) end
		panel.kitChoosing = true
		Kit:Chosen(self, self.highlight, self.label, function()
			panel.kitChoosing = nil
			if current == panel then Kit:ClosePopover() end
		end, 'onAccent', self.item.disabled and 'dim' or 'ink')
	end)
	return row
end

function Kit:Menu(anchor, items, onSelect, opts)
	opts = opts or {}
	local width = opts.width or max(140, anchor and anchor:GetWidth() or 140)
	local panel = self:Popover(anchor, {width = width, height = #items * ROW + 8, side = opts.side,
		cache = opts.cache or anchor, sound = opts.sound, instant = opts.instant})
	panel.onSelect = onSelect
	panel.rows = panel.rows or {}
	for index, item in ipairs(items) do
		local info = type(item) == 'table' and item or {text = item}
		local row = panel.rows[index]
		if not row then row = MenuRow(panel); panel.rows[index] = row end
		row.item, row.index = info, index
		row:ClearAllPoints()
		row:SetPoint('TOPLEFT', 4, -4 - (index - 1) * ROW)
		row:SetPoint('TOPRIGHT', -4, -4 - (index - 1) * ROW)
		row.highlight:Hide()
		row.rule:SetShown(info.separator and true or false)
		row.label:SetShown(not info.separator)
		row.label:SetText(info.text and strupper(info.text) or '')
		Kit:Tint(row.label, info.disabled and 'dim' or 'ink')
		Kit:Tint(row.icon, 'ink')
		local icon = info.checked and 'check' or info.icon
		row.icon:SetShown(icon and not info.separator and true or false)
		if icon then Kit:SetIcon(row.icon, icon) end
		row.label:ClearAllPoints()
		row.label:SetPoint('LEFT', (icon or opts.indent) and 26 or 10, 0)
		row:Show()
		-- lcd-print: options print in as the menu opens (200 ms, 12 steps).
		if Kit.Print and not info.separator then Kit:Print(row.label, {duration = 0.2, steps = 12}) end
	end
	panel.kitChoosing = nil
	for index = #items + 1, #panel.rows do panel.rows[index]:Hide() end
	return panel
end

-- 28 Context menu ------------------------------------------------------------
function Kit:ContextMenu(frame, items, onSelect)
	frame:EnableMouse(true)
	frame:SetScript('OnMouseUp', function(self, button)
		if button == 'RightButton' then Kit:Menu(self, items, onSelect, {side = 'CURSOR', width = 150}) end
	end)
end

-- 19 Tooltip -------------------------------------------------------------------
local tooltip
function Kit:ShowTooltip(anchor, text)
	if not tooltip then
		tooltip = self:Panel(self:Root(), {radius = 3, fill = 'glass', border = false, shadow = 0.5})
		tooltip:SetFrameStrata('TOOLTIP')
		tooltip.text = self:Label(tooltip, '', 'darkInk')
		tooltip.text:SetPoint('CENTER')
	end
	tooltip.text:SetText(strupper(text or ''))
	tooltip:SetSize(tooltip.text:GetStringWidth() + 20, 24)
	tooltip:ClearAllPoints()
	tooltip:SetPoint('BOTTOM', anchor, 'TOP', 0, 6)
	tooltip:Show()
	self:Animate(tooltip, 0.1, 0, 1, function(alpha) tooltip:SetAlpha(alpha) end)
end

function Kit:HideTooltip() if tooltip then tooltip:Hide() end end

function Kit:AttachTooltip(frame, text)
	frame:HookScript('OnEnter', function(self) Kit:ShowTooltip(self, type(text) == 'function' and text(self) or text) end)
	frame:HookScript('OnLeave', function() Kit:HideTooltip() end)
end

-- 32 Hover card ------------------------------------------------------------------
function Kit:HoverCard(frame, opts)
	opts = opts or {}
	frame:HookScript('OnEnter', function(self)
		local card = self.kitCard
		if not card then
			card = Kit:Panel(Kit:Root(), {sprite = 'popover'})
			card:SetFrameStrata('TOOLTIP')
			card:SetSize(opts.width or 180, opts.height or 70)
			if opts.build then opts.build(card) end
			self.kitCard = card
		end
		card:ClearAllPoints()
		card:SetPoint('BOTTOM', self, 'TOP', 0, 8)
		card:Show()
		Kit:Play('blip')
		Kit:Animate(card, 0.12, 0, 1, function(alpha) card:SetAlpha(alpha) end)
		-- lcd-print: a hover LCD's contents print in (260 ms, 14 steps).
		if Kit.PrintAll then Kit:PrintAll(card, {duration = 0.26, steps = 14}) end
	end)
	frame:HookScript('OnLeave', function(self) if self.kitCard then self.kitCard:Hide() end end)
end

-- 11 Dialog / 30 Alert dialog --------------------------------------------------------
local dialog
local function BuildDialog()
	dialog = CreateFrame('Button', 'JiberishSpec01Dialog', UIParent)
	dialog:SetAllPoints()
	dialog:SetFrameStrata('FULLSCREEN_DIALOG')
	dialog:SetFrameLevel(200)
	dialog.dim = dialog:CreateTexture(nil, 'BACKGROUND')
	dialog.dim:SetAllPoints()
	dialog.dim:SetColorTexture(0, 0, 0, 0.5)
	dialog.panel = Kit:Panel(dialog, {radius = 10, shadow = 0.7})
	dialog.panel:SetPoint('CENTER', 0, 40)
	dialog.panel:EnableMouse(true)
	dialog.led = Kit:Led(dialog.panel, 6, true)
	dialog.led:SetPoint('TOPLEFT', 18, -20)
	dialog.title = Kit:Label(dialog.panel, '', 'ink', 11)
	dialog.title:SetPoint('TOPLEFT', 32, -18)
	dialog.text = Kit:Text(dialog.panel, '', 11, 'dim')
	dialog.text:SetPoint('TOPLEFT', 18, -42)
	dialog.text:SetJustifyH('LEFT'); dialog.text:SetJustifyV('TOP')
	dialog.keys = {}
	dialog:SetScript('OnClick', function() Kit:CloseDialog() end)
	dialog:Hide()
	tinsert(UISpecialFrames, 'JiberishSpec01Dialog') -- Escape closes it
end

function Kit:CloseDialog()
	if dialog and dialog:IsShown() then dialog:Hide() end
end

-- Reloading -----------------------------------------------------------------------
-- On 12.x clients an addon may no longer call ReloadUI itself (it is blocked as
-- a protected action, even from a click). The game's own /reload, run by a
-- secure action button, still works: one such button is laid over whichever
-- Reload key is showing and takes the click itself. It can only be placed out
-- of combat; a Reload key clicked in combat says to reload afterwards.
local reloadCover, reloadOwner
local function ReloadCover()
	if reloadCover then return reloadCover end
	reloadCover = CreateFrame('Button', 'JiberishSpec01ReloadButton', UIParent, 'SecureActionButtonTemplate')
	reloadCover:SetAttribute('type', 'macro')
	reloadCover:SetAttribute('macrotext', '/reload')
	reloadCover:RegisterForClicks('AnyUp', 'AnyDown')
	reloadCover:Hide()
	-- The key under it still looks and sounds pressed.
	reloadCover:HookScript('OnMouseDown', function()
		if reloadOwner then Kit:Play('down-primary', true) end
	end)
	reloadCover:HookScript('PreClick', function()
		local before = reloadOwner and reloadOwner.kitBeforeReload
		if before then pcall(before) end
	end)
	reloadCover:HookScript('OnEnter', function()
		local enter = reloadOwner and reloadOwner:GetScript('OnEnter')
		if enter then pcall(enter, reloadOwner) end
	end)
	reloadCover:HookScript('OnLeave', function()
		local leave = reloadOwner and reloadOwner:GetScript('OnLeave')
		if leave then pcall(leave, reloadOwner) end
	end)
	return reloadCover
end

local function CoverKey(key)
	if InCombatLockdown() or not key:IsVisible() then return end
	local cover = ReloadCover()
	reloadOwner = key
	cover:ClearAllPoints()
	cover:SetAllPoints(key)
	cover:SetFrameStrata(key:GetFrameStrata())
	cover:SetFrameLevel(key:GetFrameLevel() + 20)
	cover:Show()
end

local function UncoverKey(key)
	if reloadOwner ~= key or not reloadCover or InCombatLockdown() then return end
	reloadOwner = nil
	reloadCover:Hide()
	reloadCover:ClearAllPoints()
end

-- What a Reload key does when it is clicked itself (only in combat, when the
-- secure button can't be placed over it).
function Kit:ReloadLater()
	UI:Print('Reload once combat ends: type /reload.')
	self:Play('error')
end

-- on: make this key a Reload key (its clicks reload); before: run just before.
function Kit:ReloadKey(key, on, before)
	key.kitReload = on and true or nil
	key.kitBeforeReload = on and before or nil
	if not key.kitReloadHooked then
		key.kitReloadHooked = true
		key:HookScript('OnShow', function(self) if self.kitReload then CoverKey(self) end end)
		key:HookScript('OnHide', function(self) UncoverKey(self) end)
	end
	if on then
		key.onClick = function() Kit:ReloadLater() end
		-- Placed a frame later, once the key has its final spot and level.
		C_Timer.After(0, function() if key.kitReload then CoverKey(key) end end)
	else
		UncoverKey(key)
	end
end

-- opts: title, text, tone ('default' | 'warning' | 'error'), width, actions = {{text=, tone=, onClick=}}
function Kit:Dialog(opts)
	opts = opts or {}
	if not dialog then BuildDialog() end
	local width = opts.width or 320
	local actions = opts.actions or {{text = 'OK', tone = 'primary'}}
	dialog.title:SetText(strupper(opts.title or ''))
	dialog.text:SetWidth(width - 36)
	dialog.text:SetText(opts.text or '')
	Kit:SetLed(dialog.led, true, opts.tone == 'warning' and 'amber' or opts.tone == 'error' and 'red' or nil)
	dialog.panel:SetSize(width, 42 + max(dialog.text:GetStringHeight(), 14) + 62)
	for index, action in ipairs(actions) do
		local key = dialog.keys[index]
		if not key then
			key = Kit:Key(dialog.panel, {width = 84, height = 30, text = ' '})
			dialog.keys[index] = key
		end
		key:SetKeyText(action.text)
		key:SetTone(action.tone or 'default')
		key:ClearAllPoints()
		key:SetPoint('BOTTOMRIGHT', -18 - (#actions - index) * 92, 16)
		key.onClick = function()
			Kit:CloseDialog()
			if action.onClick then action.onClick() end
		end
		local reload = action.reload or (action.onClick ~= nil and action.onClick == ReloadUI)
		Kit:ReloadKey(key, reload, reload and action.before or nil)
		if reload then key.onClick = function() Kit:CloseDialog(); Kit:ReloadLater() end end
		key:Show()
	end
	for index = #actions + 1, #dialog.keys do dialog.keys[index]:Hide() end
	dialog:Show()
	Kit:Play(opts.tone == 'warning' and 'warning' or opts.tone == 'error' and 'error' or 'open')
	Kit:Animate(dialog, 0.14, 0, 1, function(alpha)
		dialog:SetAlpha(alpha)
		dialog.panel:ClearAllPoints()
		dialog.panel:SetPoint('CENTER', 0, 40 - (1 - alpha) * 12)
	end)
	-- lcd-print: title 260 ms / 16 steps after 120 ms, text 320 ms / 20 after 260 ms.
	if Kit.Print then
		Kit:Print(dialog.title, {duration = 0.26, steps = 16, delay = 0.12})
		Kit:Print(dialog.text, {duration = 0.32, steps = 20, delay = 0.26})
	end
	return dialog
end

function Kit:AlertDialog(opts)
	opts = opts or {}
	opts.tone = opts.tone or 'warning'
	opts.actions = opts.actions or {{text = 'Cancel'}, {text = opts.confirm or 'Confirm', tone = 'primary', onClick = opts.onConfirm,
		reload = opts.reload}}
	return self:Dialog(opts)
end

-- 31 Drawer ---------------------------------------------------------------------------
local drawers = {}
function Kit:Drawer(opts)
	opts = opts or {}
	local key = opts.key or 'default'
	local drawer = drawers[key]
	if not drawer then
		drawer = CreateFrame('Button', nil, UIParent)
		drawer:SetAllPoints()
		drawer:SetFrameStrata('FULLSCREEN_DIALOG')
		drawer:SetFrameLevel(200)
		drawer.dim = drawer:CreateTexture(nil, 'BACKGROUND')
		drawer.dim:SetAllPoints()
		drawer.dim:SetColorTexture(0, 0, 0, 0.4)
		drawer.panel = self:Panel(drawer, {radius = 10, shadow = 0.7})
		drawer.panel:SetSize(opts.width or 420, opts.height or 200)
		drawer.panel:EnableMouse(true)
		drawer.grip = self:Texture(drawer.panel, 'round-3', 'ARTWORK')
		local gripScale = drawer.grip.kitScale or 1
		drawer.grip:SetSize(72 / gripScale, 8 / gripScale)
		drawer.grip:SetPoint('TOP', 0, -14 / gripScale)
		self:Tint(drawer.grip, 'hair')
		drawer.title = self:Label(drawer.panel, opts.title or '', 'ink', 10)
		drawer.title:SetPoint('TOPLEFT', 18, -30)
		drawer.content = CreateFrame('Frame', nil, drawer.panel)
		drawer.content:SetPoint('TOPLEFT', 18, -50)
		drawer.content:SetPoint('BOTTOMRIGHT', -18, 18)
		if opts.build then opts.build(drawer.content, drawer) end
		function drawer:Close()
			local height = self.panel:GetHeight()
			Kit:Play('latch-up')
			Kit:Animate(self, 0.16, 0, 1, function(progress)
				self.panel:ClearAllPoints()
				self.panel:SetPoint('BOTTOM', 0, -10 - progress * height)
				self.dim:SetAlpha(1 - progress)
			end, function() self:Hide() end)
		end
		drawer:SetScript('OnClick', drawer.Close)
		drawers[key] = drawer
	end
	local height = drawer.panel:GetHeight()
	drawer:Show()
	self:Play('open')
	self:Animate(drawer, 0.2, 1, 0, function(progress)
		drawer.panel:ClearAllPoints()
		drawer.panel:SetPoint('BOTTOM', 0, -10 - progress * height)
		drawer.dim:SetAlpha(1 - progress)
	end)
	return drawer
end

-- 21 Toast ------------------------------------------------------------------------------
-- The reference toast: gray LCD glass in a white bezel. Each slides down into
-- its place and fades in; a line of dots under the text runs down with the time
-- left, and pointing at a toast holds it. Toasts below glide to make room.
local toasts, pool, anchor = {}, {}, nil
local TOAST_WIDTH, TOAST_GAP, TOAST_DOTS = 300, 8, 36
local TONE_LED = {success = 'green', warning = 'amber', error = 'red', info = 'blue'}
local TONE_SOUND = {success = 'success', warning = 'warning', error = 'error'}

-- A row of small round lamps: a time-left line or a level meter.
-- Shared with the notifications module (Kit:DotLine / Kit:SetDots).
function Kit:DotLine(parent, count, size, gap)
	local line = CreateFrame('Frame', nil, parent)
	line.dots, line.lit = {}, -1
	size, gap = size or 3, gap or 4
	line:SetSize(count * size + (count - 1) * gap, size)
	for index = 1, count do
		local dot = self:Texture(line, 'circle', 'OVERLAY', 1)
		dot:SetSize(size, size)
		dot:SetPoint('LEFT', (index - 1) * (size + gap), 0)
		line.dots[index] = dot
	end
	return line
end

-- fraction 0..1 of the dots lit; tokens and alphas for lit and unlit dots.
function Kit:SetDots(line, fraction, onToken, offToken, onAlpha, offAlpha)
	local count = #line.dots
	local lit = math.floor(max(0, min(1, fraction or 0)) * count + 0.5)
	local paint = (onToken or 'lamp')..(offToken or 'ledOff')..(onAlpha or 1)..(offAlpha or 1)
	if lit == line.lit and paint == line.paint then return end
	line.lit, line.paint = lit, paint
	for index, dot in ipairs(line.dots) do
		if index <= lit then self:Tint(dot, onToken or 'lamp', onAlpha or 1)
		else self:Tint(dot, offToken or 'ledOff', offAlpha or 1) end
	end
end

function Kit:ToastAnchor()
	if not anchor then
		local db = self:DB().toasts
		anchor = CreateFrame('Frame', 'JiberishSpec01ToastAnchor', UIParent)
		anchor:SetSize(TOAST_WIDTH, 44)
		anchor:SetPoint('TOP', UIParent, 'TOP', db.x or 0, db.y or -160)
		anchor:SetFrameStrata('TOOLTIP')
	end
	return anchor
end

local function PlaceToast(toast)
	toast:ClearAllPoints()
	toast:SetPoint('TOP', anchor, 'TOP', toast.ox or 0, -(toast.y or 0) + (toast.slide or 0))
end

-- Newest on top; everything else takes the spot under the toasts above it.
local function LayoutToasts()
	local y = 0
	for _, toast in ipairs(toasts) do
		toast.target = y
		if not toast.y then toast.y = y end
		y = y + toast:GetHeight() + TOAST_GAP
	end
end

-- One driver for every toast: the time left, the dots and the glide. It runs
-- only while a toast is up.
local ticker = CreateFrame('Frame')
ticker:Hide()
local DismissToast
ticker:SetScript('OnUpdate', function(self, elapsed)
	if #toasts == 0 then return self:Hide() end
	elapsed = min(elapsed, 0.1)
	for index = #toasts, 1, -1 do
		local toast = toasts[index]
		if toast.y ~= toast.target then
			local gap = toast.target - toast.y
			toast.y = math.abs(gap) < 0.25 and toast.target or toast.y + gap * min(1, elapsed * 14)
		end
		if toast.active and not toast.hovered then
			toast.left = toast.left - elapsed
			Kit:SetDots(toast.dots, toast.left / toast.duration, 'screenInk', 'screenDim', 0.85, 0.22)
			if toast.left <= 0 then DismissToast(toast) end
		end
		PlaceToast(toast)
	end
end)

function DismissToast(toast)
	if not toast.active then return end
	toast.active = false
	local from = toast:GetAlpha()
	Kit:Animate(toast, Kit.SPEED.CLOSE, 0, 1, function(progress)
		toast:SetAlpha(from * (1 - Kit.ease.inout(progress)))
		toast.ox = 6 * Kit.ease.cubic(progress)
	end, function()
		toast:Hide()
		toast.ox, toast.slide, toast.y = 0, 0, nil
		for index, other in ipairs(toasts) do
			if other == toast then table.remove(toasts, index); break end
		end
		pool[#pool + 1] = toast
		LayoutToasts()
	end, 'linear')
end

local function CreateToast()
	local toast = Kit:Panel(Kit:ToastAnchor(), {sprite = 'toast', frameType = 'Button'})
	toast:SetWidth(TOAST_WIDTH)
	toast.led = Kit:Led(toast, 6, true)
	toast.led:SetPoint('TOPLEFT', 14, -15)
	toast.title = Kit:Label(toast, '', 'screenInk', 10)
	toast.title:SetPoint('TOPLEFT', 28, -12)
	toast.title:SetJustifyH('LEFT')
	toast.text = Kit:Text(toast, '', 10, 'screenDim')
	toast.text:SetPoint('TOPLEFT', 28, -28)
	toast.text:SetJustifyH('LEFT')
	toast.dots = Kit:DotLine(toast, TOAST_DOTS, 3, 4)
	toast.dots:SetPoint('BOTTOMLEFT', 28, 9)
	toast.action = Kit:Key(toast, {width = 60, height = 24, text = ' ', textSize = 8})
	toast.action:SetPoint('RIGHT', -10, 2)
	toast:SetScript('OnClick', DismissToast)
	-- Pointing at a toast holds it until the pointer leaves.
	toast:SetScript('OnEnter', function(self) self.hovered = true end)
	toast:SetScript('OnLeave', function(self) self.hovered = false end)
	toast.action:HookScript('OnEnter', function() toast.hovered = true end)
	toast.action:HookScript('OnLeave', function() toast.hovered = toast:IsMouseOver() end)
	return toast
end

-- opts (or a plain string): title, text, tone, duration, action = {text=, onClick=}, sound (false to mute)
function Kit:Toast(opts)
	if type(opts) ~= 'table' then opts = {title = tostring(opts)} end
	self:ToastAnchor()
	local toast = table.remove(pool) or CreateToast()
	local textWidth = TOAST_WIDTH - 42 - (opts.action and 70 or 0)
	toast.title:SetWidth(textWidth); toast.text:SetWidth(textWidth)
	toast.title:SetText(strupper(opts.title or ''))
	toast.text:SetText(opts.text or '')
	local hasText = opts.text ~= nil and opts.text ~= ''
	toast.text:SetShown(hasText)
	Kit:SetLed(toast.led, true, TONE_LED[opts.tone])
	toast.action:SetShown(opts.action ~= nil)
	if opts.action then
		toast.action:SetKeyText(opts.action.text or 'Undo')
		toast.action.onClick = function()
			DismissToast(toast)
			if opts.action.onClick then opts.action.onClick() end
		end
	end
	Kit:ReloadKey(toast.action, opts.action ~= nil and opts.action.reload and true or false)
	if opts.action and opts.action.reload then
		toast.action.onClick = function() DismissToast(toast); Kit:ReloadLater() end
	end
	toast:SetHeight((hasText and (36 + max(toast.text:GetStringHeight(), 10)) or 36) + 8)
	-- Hover comes from OnEnter/OnLeave only; before placement IsMouseOver means nothing.
	toast.active, toast.hovered = true, false
	toast.duration = max(opts.duration or self:DB().toasts.duration or 5, 0.5)
	toast.left = toast.duration
	toast.dots.lit = -1
	Kit:SetDots(toast.dots, 1, 'screenInk', 'screenDim', 0.85, 0.22)
	toast.ox, toast.y = 0, nil
	table.insert(toasts, 1, toast)
	-- At most four at once: the oldest leaves the way any toast does.
	local shown = 0
	for _, other in ipairs(toasts) do
		if other.active then
			shown = shown + 1
			if shown > 4 then DismissToast(other) end
		end
	end
	LayoutToasts()
	toast:SetAlpha(0)
	toast:Show()
	ticker:Show()
	if opts.sound ~= false then self:Play(TONE_SOUND[opts.tone] or 'open', true) end
	-- lcd-print: the toast's text prints in (280 ms, 16 steps).
	if self.Print then
		self:Print(toast.title, {duration = 0.28, steps = 16})
		if hasText then self:Print(toast.text, {duration = 0.28, steps = 16}) end
	end
	-- Slides 14 px down into place (cubic ease-out) while it fades in (sine).
	self:Animate(toast, self.SPEED.SLOW, 0, 1, function(progress)
		toast:SetAlpha(Kit.ease.sine(min(progress * 2, 1)))
		toast.slide = 14 * (1 - Kit.ease.cubic(progress))
		PlaceToast(toast)
	end, nil, 'linear')
	return toast
end
