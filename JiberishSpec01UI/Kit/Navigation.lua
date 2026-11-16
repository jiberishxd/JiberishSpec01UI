-- Hardware kit navigation and layout: tabs, accordion, collapsible, toolbar,
-- pagination, breadcrumb, menubar, navbar, scroll area, carousel and resizable panes.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame = CreateFrame
local floor, max, min = math.floor, math.max, math.min

-- 12 Tabs ---------------------------------------------------------------------
-- opts.items: {{text=, body=}}; opts.width
function Kit:Tabs(parent, opts)
	opts = opts or {}
	local items = opts.items or {}
	local width = opts.width or 280
	local tabs = CreateFrame('Frame', nil, parent)
	tabs.opts = opts
	tabs:SetSize(width, opts.height or 90)
	local names = {}
	for index, item in ipairs(items) do names[index] = item.text end
	tabs.body = self:Text(tabs, '', 11, 'dim')
	tabs.body:SetPoint('TOPLEFT', 2, -42)
	tabs.body:SetWidth(width - 4)
	tabs.body:SetJustifyH('LEFT')
	tabs.list = self:Segmented(tabs, {items = names, width = width, value = opts.value or 1, onChange = function(index)
		tabs.body:SetText(items[index].body or '')
		if opts.onChange then opts.onChange(index, tabs) end
	end})
	tabs.list:SetPoint('TOP')
	function tabs:SetValue(index)
		self.list:SetValue(index)
		self.body:SetText(items[self.list:GetValue()] and items[self.list:GetValue()].body or '')
	end
	function tabs:GetValue() return self.list:GetValue() end
	tabs:SetValue(opts.value or 1)
	return tabs
end

-- 16 Accordion / 38 Collapsible --------------------------------------------------
-- opts.items: {{title=, body=}}; opts.numbered; opts.open (index); opts.onResize(height)
function Kit:Accordion(parent, opts)
	opts = opts or {}
	local items = opts.items or {}
	local width, rowHeight = opts.width or 280, 30
	local accordion = CreateFrame('Frame', nil, parent)
	accordion.opts, accordion.rows = opts, {}
	local function Layout()
		local y = 0
		for index, row in ipairs(accordion.rows) do
			row:ClearAllPoints()
			row:SetPoint('TOPLEFT', 0, -y)
			y = y + rowHeight
			local open = accordion.open == index
			row.panel:SetShown(open)
			Kit:SetLed(row.led, open)
			if open then
				row.panel:ClearAllPoints()
				row.panel:SetPoint('TOPLEFT', accordion, 'TOPLEFT', 0, -y)
				y = y + row.panel:GetHeight() + 8
			end
		end
		accordion:SetSize(width, y)
		if opts.onResize then opts.onResize(y, accordion) end
	end
	function accordion:SetValue(index)
		self.open = index
		Layout()
	end
	function accordion:GetValue() return self.open end
	for index, item in ipairs(items) do
		local row = CreateFrame('Button', nil, accordion)
		row:SetSize(width, rowHeight)
		local x = 0
		if opts.numbered ~= false then
			row.number = self:Label(row, format('%02d', index), 'dim', 8)
			row.number:SetPoint('LEFT', 2, 0)
			x = 26
		end
		row.title = self:Label(row, item.title, 'ink', 9)
		row.title:SetPoint('LEFT', x + 2, 0)
		row.led = self:Led(row, 5)
		row.led:SetPoint('RIGHT', -6, 0)
		row.rule = self:Solid(row, 'line')
		row.rule:SetHeight(1)
		row.rule:SetPoint('TOPLEFT'); row.rule:SetPoint('TOPRIGHT')
		row.panel = self:Well(accordion, 6, 'track')
		row.panel.text = self:Text(row.panel, item.body or '', 11, 'dim')
		row.panel.text:SetPoint('TOPLEFT', 10, -8)
		row.panel.text:SetWidth(width - 20)
		row.panel.text:SetJustifyH('LEFT')
		row.panel:SetSize(width, max(row.panel.text:GetStringHeight(), 12) + 16)
		row:SetScript('OnClick', function()
			local opening = accordion.open ~= index
			Kit:Play(opening and 'latch-down' or 'latch-up')
			accordion:SetValue(opening and index or nil)
		end)
		accordion.rows[index] = row
	end
	accordion:SetValue(opts.open)
	return accordion
end

function Kit:Collapsible(parent, opts)
	opts = opts or {}
	return self:Accordion(parent, {items = {{title = opts.title or 'Advanced', body = opts.body}}, width = opts.width,
		numbered = false, open = opts.open and 1 or nil, onResize = opts.onResize})
end

-- 17 Toolbar ---------------------------------------------------------------------------
-- opts.items: {{text= | icon=, toggle=, onClick=}} or 'separator'
function Kit:Toolbar(parent, opts)
	opts = opts or {}
	local toolbar = CreateFrame('Frame', nil, parent)
	toolbar.opts, toolbar.keys = opts, {}
	local x = 0
	for index, item in ipairs(opts.items or {}) do
		if item == 'separator' then
			local line = self:Separator(toolbar, 22, true)
			line:SetPoint('LEFT', x + 4, 0)
			x = x + 14
		else
			local key = self:Key(toolbar, {width = 34, height = 30, text = item.text, icon = item.icon,
				toggle = item.toggle, checked = item.checked})
			key:SetPoint('LEFT', x, 0)
			key.onClick = function(self) if item.onClick then item.onClick(self.checked, self) end end
			if item.tooltip then self:AttachTooltip(key, item.tooltip) end
			toolbar.keys[index] = key
			x = x + 40
		end
	end
	toolbar:SetSize(max(x - 6, 1), 32)
	return toolbar
end

-- 18 Pagination ---------------------------------------------------------------------------
function Kit:Pagination(parent, opts)
	opts = opts or {}
	local pages = opts.pages or 9
	local width = opts.width or 280
	local pager = CreateFrame('Frame', nil, parent)
	pager.opts = opts
	pager:SetSize(width, 44)
	local function Step(delta)
		local value = Kit:Clamp(pager.value + delta, 1, pages)
		if value == pager.value then return end
		pager:SetValue(value, true)
		Kit:Play('tick')
		if opts.onChange then opts.onChange(value, pager) end
	end
	pager.previous = self:Key(pager, {round = true, width = 30, height = 30, icon = 'chevron-left', onClick = function() Step(-1) end})
	pager.previous:SetPoint('LEFT')
	pager.next = self:Key(pager, {round = true, width = 30, height = 30, icon = 'chevron-right', onClick = function() Step(1) end})
	pager.next:SetPoint('RIGHT')
	local strip = self:Well(pager, 6, 'track')
	strip:SetPoint('LEFT', pager.previous, 'RIGHT', 10, 1)
	strip:SetPoint('RIGHT', pager.next, 'LEFT', -10, 1)
	strip:SetHeight(30)
	strip:SetClipsChildren(true)
	for _, edge in ipairs({'TOP', 'BOTTOM'}) do
		local mark = self:Solid(pager, 'accent', 'OVERLAY')
		mark:SetSize(1, 6)
		mark:SetPoint('CENTER', strip, edge, 0, 0)
	end
	local pitch, numbers = 28, {}
	for index = 1, pages do numbers[index] = self:Text(strip, tostring(index), 12, 'dim') end
	local function Paint(position)
		for index, number in ipairs(numbers) do
			number:ClearAllPoints()
			number:SetPoint('CENTER', strip, 'CENTER', (index - position) * pitch, 0)
			Kit:Tint(number, index == pager.value and 'ink' or 'dim')
		end
	end
	function pager:SetValue(value, animate)
		value = Kit:Clamp(value or 1, 1, pages)
		local from = self.value or value
		self.value = value
		Kit:Animate(self, animate and 0.18 or 0, animate and from or value, value, Paint, nil, 'detent')
	end
	function pager:GetValue() return self.value end
	strip:EnableMouseWheel(true)
	strip:SetScript('OnMouseWheel', function(_, delta) Step(-delta) end)
	pager:SetValue(opts.value or 1)
	return pager
end

-- 36 Breadcrumb -----------------------------------------------------------------------------
function Kit:Breadcrumb(parent, opts)
	opts = opts or {}
	local items = opts.items or {}
	local crumb = CreateFrame('Frame', nil, parent)
	crumb.opts = opts
	local x = 0
	for index, text in ipairs(items) do
		local last = index == #items
		if last then
			local led = self:Led(crumb, 5, true)
			led:SetPoint('LEFT', x, 0)
			x = x + 9
		end
		local button = CreateFrame('Button', nil, crumb)
		button.label = self:Label(button, text, last and 'ink' or 'dim')
		button.label:SetPoint('LEFT')
		button:SetSize(button.label:GetStringWidth(), 16)
		button:SetPoint('LEFT', x, 0)
		if not last then
			button:SetScript('OnEnter', function(self) Kit:Tint(self.label, 'ink') end)
			button:SetScript('OnLeave', function(self) Kit:Tint(self.label, 'dim') end)
			button:SetScript('OnClick', function()
				Kit:Play('tick')
				if opts.onClick then opts.onClick(index, text) end
			end)
		end
		x = x + button:GetWidth()
		if not last then
			local slash = self:Label(crumb, '/', 'dim')
			slash:SetPoint('LEFT', x + 5, 0)
			x = x + 16
		end
	end
	crumb:SetSize(max(x, 1), 16)
	return crumb
end

-- 27 Menubar ------------------------------------------------------------------------------------
-- opts.menus: {{text=, items={...}}}; opts.onSelect(menuIndex, itemIndex, item)
function Kit:Menubar(parent, opts)
	opts = opts or {}
	local menus = opts.menus or {}
	local keyWidth = opts.keyWidth or 56
	local bar = self:Well(parent, 6, 'track')
	bar.opts, bar.keys = opts, {}
	bar:SetSize(#menus * (keyWidth + 4) + 4, 36)
	for index, menu in ipairs(menus) do
		local key = self:Key(bar, {width = keyWidth, height = 26, text = menu.text, textSize = 8})
		key:SetPoint('LEFT', 4 + (index - 1) * (keyWidth + 4), 0)
		key.onClick = function(self)
			Kit:Menu(self, menu.items or {}, function(itemIndex, item)
				if opts.onSelect then opts.onSelect(index, itemIndex, item) end
			end, {width = 150})
		end
		bar.keys[index] = key
	end
	return bar
end

-- 55 Navbar ---------------------------------------------------------------------------------------
function Kit:Navbar(parent, opts)
	opts = opts or {}
	local items = opts.items or {}
	local bar = self:Panel(parent, {radius = 10, fill = 'panel', border = 'hair', shadow = 0.4})
	bar.opts, bar.links = opts, {}
	local x = 16
	function bar:SetValue(index)
		self.value = index
		for i, link in ipairs(self.links) do
			Kit:SetLed(link.led, i == index)
			Kit:Tint(link.label, i == index and 'ink' or 'dim')
		end
	end
	function bar:GetValue() return self.value end
	for index, text in ipairs(items) do
		local link = CreateFrame('Button', nil, bar)
		link.led = self:Led(link, 5)
		link.led:SetPoint('LEFT')
		link.label = self:Label(link, text, 'dim')
		link.label:SetPoint('LEFT', 10, 0)
		link:SetSize(link.label:GetStringWidth() + 10, 30)
		link:SetPoint('LEFT', x, 0)
		link:SetScript('OnClick', function()
			if bar.value == index then return end
			bar:SetValue(index)
			Kit:Play('tick')
			if opts.onChange then opts.onChange(index, bar) end
		end)
		bar.links[index] = link
		x = x + link:GetWidth() + 18
	end
	bar:SetSize(opts.width or (x - 2), 32)
	bar:SetValue(opts.value or 1)
	return bar
end

-- 41 Scroll area ------------------------------------------------------------------------------------
-- Returns a ScrollFrame; put children in area.content and call area:Refresh() after resizing it.
function Kit:ScrollArea(parent, opts)
	opts = opts or {}
	local area = CreateFrame('ScrollFrame', nil, parent)
	area.opts = opts
	area:SetSize(opts.width or 200, opts.height or 120)
	area.content = CreateFrame('Frame', nil, area)
	area.content:SetSize((opts.width or 200) - 8, 1)
	area:SetScrollChild(area.content)
	area.thumb = self:Solid(area, 'accent', 'OVERLAY')
	area.offset = 0
	function area:Refresh()
		local view = self:GetHeight()
		local range = max(0, self.content:GetHeight() - view)
		self.offset = Kit:Clamp(self.offset, 0, range)
		self:SetVerticalScroll(self.offset)
		self.thumb:SetShown(range > 0)
		if range > 0 then
			local length = max(16, view * view / self.content:GetHeight())
			self.thumb:SetSize(3, length)
			self.thumb:ClearAllPoints()
			self.thumb:SetPoint('TOPRIGHT', self, 'TOPRIGHT', -1, -(view - length) * (self.offset / range))
		end
	end
	function area:ScrollTo(offset)
		self.offset = offset
		self:Refresh()
	end
	area:EnableMouseWheel(true)
	area:SetScript('OnMouseWheel', function(self, delta) self:ScrollTo(self.offset - delta * (opts.step or 40)) end)
	area:SetScript('OnSizeChanged', function(self)
		self.content:SetWidth(max(self:GetWidth() - 8, 1))
		self:Refresh()
	end)
	area:Refresh()
	return area
end

-- 39 Carousel -----------------------------------------------------------------------------------------
function Kit:Carousel(parent, opts)
	opts = opts or {}
	local items = opts.items or {}
	local width = opts.width or 280
	local carousel = CreateFrame('Frame', nil, parent)
	carousel.opts = opts
	carousel:SetSize(width, 96)
	local screen = self:Panel(carousel, {radius = 10, fill = 'glass', border = 'darkEdge'})
	screen:SetPoint('TOP')
	screen:SetSize(width - 60, 76)
	screen.tag = self:Label(screen, '', 'accent', 8)
	screen.tag:SetPoint('TOPLEFT', 12, -10)
	screen.title = self:Text(screen, '', 18, 'darkInk')
	screen.title:SetPoint('CENTER', 0, -2)
	carousel.dots = {}
	for index = 1, #items do
		local dot = self:Led(carousel, 4)
		dot:SetPoint('BOTTOM', (index - (#items + 1) / 2) * 10, 2)
		carousel.dots[index] = dot
	end
	function carousel:SetValue(index, animate)
		if #items == 0 then return end
		index = (index - 1) % #items + 1
		self.value = index
		screen.tag:SetText(format('P%02d', index))
		screen.title:SetText(strupper(tostring(items[index])))
		for i, dot in ipairs(self.dots) do Kit:SetLed(dot, i == index) end
		if animate then Kit:Animate(self, 0.2, 0, 1, function(alpha) screen.title:SetAlpha(alpha) end) end
	end
	function carousel:GetValue() return self.value end
	local function Step(delta)
		carousel:SetValue((carousel.value or 1) + delta, true)
		if opts.onChange then opts.onChange(carousel.value, carousel) end
	end
	carousel.previous = self:Key(carousel, {round = true, width = 24, height = 24, icon = 'chevron-left', iconSize = 12, onClick = function() Step(-1) end})
	carousel.previous:SetPoint('LEFT', 0, 8)
	carousel.next = self:Key(carousel, {round = true, width = 24, height = 24, icon = 'chevron-right', iconSize = 12, onClick = function() Step(1) end})
	carousel.next:SetPoint('RIGHT', 0, 8)
	carousel:SetValue(opts.value or 1)
	return carousel
end

-- 40 Resizable ------------------------------------------------------------------------------------------
-- Two labelled panes with a draggable divider. opts: width, height, labels = {a, b}, split (0..1)
function Kit:Resizable(parent, opts)
	opts = opts or {}
	local width, height = opts.width or 280, opts.height or 80
	local labels = opts.labels or {'A', 'B'}
	local frame = CreateFrame('Frame', nil, parent)
	frame.opts = opts
	frame:SetSize(width, height)
	local function Pane(text)
		local pane = Kit:Well(frame, 6, 'track')
		pane.label = Kit:Label(pane, text, 'dim', 8)
		pane.label:SetPoint('CENTER')
		return pane
	end
	frame.left, frame.right = Pane(labels[1]), Pane(labels[2])
	frame.left:SetPoint('TOPLEFT'); frame.left:SetPoint('BOTTOMLEFT')
	frame.right:SetPoint('TOPRIGHT'); frame.right:SetPoint('BOTTOMRIGHT')
	local handle = CreateFrame('Frame', nil, frame)
	handle:SetSize(10, height)
	handle.grip = self:Solid(handle, 'dim')
	handle.grip:SetSize(3, 26)
	handle.grip:SetPoint('CENTER')
	function frame:SetValue(split)
		split = Kit:Clamp(split or 0.5, 0.2, 0.8)
		self.split = split
		local x = floor((width - 10) * split)
		self.left:SetWidth(x)
		self.right:SetWidth(width - 10 - x)
		handle:ClearAllPoints()
		handle:SetPoint('LEFT', self, 'LEFT', x, 0)
	end
	function frame:GetValue() return self.split end
	handle:EnableMouse(true)
	handle:SetScript('OnEnter', function(self) Kit:Tint(self.grip, 'accent') end)
	handle:SetScript('OnLeave', function(self) if not self.kitDragging then Kit:Tint(self.grip, 'dim') end end)
	self:Drag(handle, function()
		local x = Kit:Cursor(frame)
		frame:SetValue((x - 5) / (width - 10))
		if opts.onChange then opts.onChange(frame.split, frame) end
	end, function() Kit:Play('tick') end, function(dragged) Kit:Tint(dragged.grip, 'dim') end)
	frame:SetValue(opts.split or 0.5)
	return frame
end
