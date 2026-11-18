-- Hardware kit displays: meter, progress, bar graph, LCD, badge, avatar, alert,
-- separator, item list, code block and the bezel display.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame = CreateFrame
local floor, max, min = math.floor, math.max, math.min

-- Turn any native StatusBar into an LED dot meter. The bar keeps filling
-- natively (so secret values still work); unlit dots sit under the fill and a
-- perforated cover in the track color hides everything between the dots.
-- coverToken: the surface around the dots; unlitToken: dots that are off (light by default, dim on dark glass).
function Kit:Perforate(bar, coverToken, unlitToken)
	local function Tile(file, layer, sublevel)
		local texture = bar:CreateTexture(nil, layer, nil, sublevel)
		texture:SetTexture(self.media..file..'.tga', 'REPEAT', 'REPEAT')
		texture:SetAllPoints(bar)
		return texture
	end
	if not bar.kitCover then
		bar.kitUnder = Tile('tile-dot', 'BACKGROUND', 1)
		bar.kitCover = Tile('tile-perf', 'OVERLAY', -8) -- above the fill, below bar text
		bar:HookScript('OnSizeChanged', function(self) Kit:SizePerforation(self) end)
	end
	self:Tint(bar.kitUnder, unlitToken or 'ledOff')
	self:Tint(bar.kitCover, coverToken or 'track')
	bar.kitPerforated = true
	self:SizePerforation(bar)
end

-- One dot per bar thickness: tiles repeat along the bar's length.
function Kit:SizePerforation(bar)
	if not bar.kitCover or not bar.kitPerforated then return end
	local width, height = bar:GetSize()
	if (issecretvalue and (issecretvalue(width) or issecretvalue(height))) or not width or not height or width <= 0 or height <= 0 then
		bar.kitCover:Hide(); bar.kitUnder:Hide()
		return
	end
	local vertical = bar.GetOrientation and bar:GetOrientation() == 'VERTICAL'
	local thickness = vertical and width or height
	for _, texture in ipairs({bar.kitUnder, bar.kitCover}) do
		texture:SetHorizTile(not vertical); texture:SetVertTile(vertical)
		if texture.SetScale then texture:SetScale(thickness / 16) end
		texture:Show()
	end
end

function Kit:Unperforate(bar)
	bar.kitPerforated = nil
	if bar.kitCover then bar.kitCover:Hide(); bar.kitUnder:Hide() end
end

-- 09 Meter / 37 Progress ------------------------------------------------------
-- opts: label, value (0..1), width, format(value)
function Kit:Meter(parent, opts)
	opts = opts or {}
	local width = opts.width or 200
	local meter = CreateFrame('Frame', nil, parent)
	meter.opts = opts
	meter:SetSize(width, 30)
	meter.label = self:Label(meter, opts.label or '', 'ink')
	meter.label:SetPoint('TOPLEFT')
	meter.readout = self:Label(meter, '', 'dim')
	meter.readout:SetPoint('TOPRIGHT')
	local track = self:Well(meter, 6, 'track')
	track:SetPoint('BOTTOMLEFT'); track:SetPoint('BOTTOMRIGHT')
	track:SetHeight(12)
	local bar = CreateFrame('StatusBar', nil, track)
	bar:SetPoint('TOPLEFT', 4, -2); bar:SetPoint('BOTTOMRIGHT', -4, 2)
	bar:SetStatusBarTexture([[Interface\Buttons\WHITE8X8]])
	bar:SetMinMaxValues(0, 1)
	self:Tint(bar, opts.tone or 'accent')
	self:Perforate(bar, 'track')
	meter.bar = bar
	local dots = max(1, floor((width - 8) / 8))
	local function Paint(value)
		bar:SetValue(floor(value * dots + 0.5) / dots)
		meter.readout:SetText(opts.format and opts.format(value) or format('%d%%', floor(value * 100 + 0.5)))
	end
	function meter:SetValue(value, animate)
		value = Kit:Clamp(value or 0, 0, 1)
		local from = self.value or 0
		self.value = value
		-- Meter cascade (an extra): the dots light one after another, linearly.
		local cascade = animate and Kit.Alive and Kit:Alive('meterCascade')
		Kit:Animate(self, animate and (cascade and 0.45 or 0.3) or 0, animate and from or value, value, Paint, nil,
			cascade and 'linear' or nil)
	end
	function meter:GetValue() return self.value end
	meter:SetValue(opts.value or 0)
	return meter
end

function Kit:Progress(parent, opts)
	opts = opts or {}
	opts.label = opts.label or 'Progress'
	return self:Meter(parent, opts)
end

-- 44 Bar graph -----------------------------------------------------------------
function Kit:BarGraph(parent, opts)
	opts = opts or {}
	local columns, rows = opts.columns or 16, opts.rows or 8
	local cell, gap = opts.cell or 6, 1
	local graph = self:Panel(parent, {radius = 6, fill = 'glass', border = 'darkEdge'})
	graph.opts = opts
	graph:SetSize(columns * (cell + gap) + 15, rows * (3 + gap) + 15)
	graph.cells = {}
	for column = 1, columns do
		graph.cells[column] = {}
		for row = 1, rows do
			local texture = graph:CreateTexture(nil, 'ARTWORK')
			texture:SetColorTexture(1, 1, 1, 1)
			texture:SetSize(cell, 3)
			texture:SetPoint('BOTTOMLEFT', 8 + (column - 1) * (cell + gap), 8 + (row - 1) * (3 + gap))
			graph.cells[column][row] = texture
		end
	end
	function graph:SetValues(values)
		self.values = values
		for column = 1, columns do
			local lit = floor(Kit:Clamp(values[column] or 0, 0, 1) * rows + 0.5)
			for row = 1, rows do Kit:Tint(self.cells[column][row], 'accent', row <= lit and 1 or 0.14) end
		end
	end
	graph:SetValues(opts.values or {})
	return graph
end

-- 56 LCD --------------------------------------------------------------------------
local LCD_SIZES = {sm = {14, 7, 7}, md = {24, 10, 8}, lg = {40, 14, 8}}
local fitted = setmetatable({}, {__mode = 'k'}) -- fixed-width readouts, refit when the typeface changes
-- opts: tag, text, ghost (unlit segments, e.g. '888.8'), size ('sm' | 'md' | 'lg'), width
function Kit:LCD(parent, opts)
	opts = opts or {}
	local size = LCD_SIZES[opts.size or 'md'] or LCD_SIZES.md
	local lcd = self:Panel(parent, {radius = 6, fill = 'lcd', border = 'hair'})
	lcd.opts = opts
	local top = size[2]
	if opts.tag then
		lcd.tag = self:Label(lcd, opts.tag, 'lcdDim', size[3])
		lcd.tag:SetPoint('TOPLEFT', size[2], -size[2] + 2)
		top = top + size[3] + 2
	end
	lcd.ghost = self:Text(lcd, opts.ghost or '', size[1], 'lcdGhost')
	lcd.ghost:SetPoint('TOPRIGHT', -size[2], -top)
	lcd.digits = self:Text(lcd, '', size[1], 'lcdInk')
	lcd.digits:SetPoint('TOPRIGHT', -size[2], -top)
	-- A hidden copy at the full size measures what the readout needs.
	lcd.measure = self:Text(lcd, '', size[1], 'lcdInk')
	lcd.measure:Hide()
	-- A fixed-width readout shrinks its digits (and ghost) to fit the glass, so
	-- a wide typeface (Audiowide) never spills past the panel; kept centred in
	-- the digit band. Measured from the full text, not a print-in frame.
	function lcd:Fit()
		local text = self.text or ''
		if not opts.width or (issecretvalue and issecretvalue(text)) then return end
		Kit:Font(self.measure, size[1])
		self.measure:SetText(text)
		local wide = self.measure:GetStringWidth() or 0
		self.measure:SetText(opts.ghost or '')
		wide = max(wide, self.measure:GetStringWidth() or 0)
		local room = (self:GetWidth() or 0) - size[2] * 2
		local fitted = size[1]
		if room > 0 and wide > room then fitted = max(6, floor(size[1] * room / wide)) end
		if fitted ~= self.fitted then
			self.fitted = fitted
			Kit:Font(self.digits, fitted)
			Kit:Font(self.ghost, fitted)
			local drop = floor((size[1] - fitted) / 2 + 0.5)
			self.ghost:SetPoint('TOPRIGHT', -size[2], -top - drop)
			self.digits:SetPoint('TOPRIGHT', -size[2], -top - drop)
		end
	end
	function lcd:SetText(text)
		self.text = text or ''
		-- LCD print-in (an extra) prints a changed readout in; otherwise just sets it.
		if Kit.PrintText then Kit:PrintText(self.digits, text or '') else self.digits:SetText(text or '') end
		if not opts.width then
			self:SetWidth(max(self.digits:GetStringWidth(), self.ghost:GetStringWidth(), self.tag and self.tag:GetStringWidth() or 0) + size[2] * 2)
		else
			self:Fit()
		end
	end
	lcd:SetSize(opts.width or 80, top + size[1] + size[2] - 2)
	lcd:SetText(opts.text)
	if opts.width then
		fitted[lcd] = true
		lcd:HookScript('OnSizeChanged', function(self) self.fitted = nil; self:Fit() end)
	end
	return lcd
end
-- A typeface change measures every fixed-width readout again.
Kit:OnRefresh(function()
	for lcd in pairs(fitted) do lcd.fitted = nil; lcd:Fit() end
end)

-- 34 Badge ---------------------------------------------------------------------------
function Kit:Badge(parent, opts)
	opts = opts or {}
	local badge = self:Panel(parent, {sprite = 'badge'})
	badge.opts = opts
	badge.bar = self:Solid(badge, 'dim')
	badge.bar:SetSize(3, 10)
	badge.bar:SetPoint('LEFT', 6, 0)
	badge.label = self:Label(badge, '', 'ink', 8)
	badge.label:SetPoint('LEFT', 14, 0)
	function badge:SetBadge(text, tone)
		self.label:SetText(strupper(text or ''))
		Kit:Tint(self.bar, tone or 'dim')
		self:SetSize(self.label:GetStringWidth() + 24, 20)
		-- badge-breathe: an info badge's lamp breathes (1.6 s, to 35%).
		if Kit.Breathe then Kit:Breathe(self.bar, (tone == 'blue' or tone == 'info') and Kit:Faithful('breathe')) end
	end
	badge:SetBadge(opts.text, opts.tone)
	return badge
end

-- 35 Avatar: initials on a dot matrix, or one of the addon's class icons ---------
local GLYPHS = {
	A = '010101111101101', B = '110101110101110', C = '011100100100011', D = '110101101101110', E = '111100110100111',
	F = '111100110100100', G = '011100101101011', H = '101101111101101', I = '111010010010111', J = '001001001101010',
	K = '101101110101101', L = '100100100100111', M = '101111111101101', N = '111101101101101', O = '010101101101010',
	P = '110101110100100', Q = '010101101111011', R = '110101110101101', S = '011100010001110', T = '111010010010010',
	U = '101101101101111', V = '101101101101010', W = '101101111111101', X = '101101010101101', Y = '101101010010010',
	Z = '111001010100111',
}

function Kit:Avatar(parent, opts)
	opts = opts or {}
	local size = opts.size or 40
	local avatar = CreateFrame('Frame', nil, parent)
	avatar.opts = opts
	avatar:SetSize(size, size)
	avatar.disc = self:Skin(avatar, 'avatar', 'BORDER', 0)
	avatar.dots = {}
	local pitch = size / 11
	for row = 1, 5 do
		for column = 1, 7 do
			local dot = self:Texture(avatar, 'circle', 'ARTWORK')
			dot:SetSize(pitch * 0.62, pitch * 0.62)
			dot:SetPoint('CENTER', avatar, 'CENTER', (column - 4) * pitch, (3 - row) * pitch)
			avatar.dots[(row - 1) * 7 + column] = dot
		end
	end
	avatar.icon = avatar:CreateTexture(nil, 'ARTWORK', nil, 2)
	avatar.icon:SetPoint('TOPLEFT', size * 0.16, -size * 0.16)
	avatar.icon:SetPoint('BOTTOMRIGHT', -size * 0.16, size * 0.16)
	avatar.icon:Hide()
	function avatar:SetName(name)
		self.icon:Hide()
		local first, second = (name or ''):match('^%s*(%a)%a*%s*(%a?)')
		local glyphs = {GLYPHS[first and strupper(first) or ''], GLYPHS[second and strupper(second) or '']}
		for row = 1, 5 do
			for column = 1, 7 do
				local glyph = column <= 3 and glyphs[1] or column >= 5 and glyphs[2]
				local offset = (row - 1) * 3 + (column <= 3 and column or column - 4)
				local lit = glyph and glyph:sub(offset, offset) == '1'
				local dot = self.dots[(row - 1) * 7 + column]
				dot:Show()
				Kit:Tint(dot, 'ink', lit and 1 or 0.12)
			end
		end
	end
	-- Show the unit's portrait instead of initials.
	function avatar:SetUnit(unit)
		if not UnitExists(unit) then return self:SetName(nil) end
		for _, dot in ipairs(self.dots) do dot:Hide() end
		SetPortraitTexture(self.icon, unit)
		self.icon:Show()
	end
	if opts.unit then avatar:SetUnit(opts.unit, opts.style) else avatar:SetName(opts.name) end
	return avatar
end

-- 33 Alert -----------------------------------------------------------------------------
function Kit:Alert(parent, opts)
	opts = opts or {}
	local width = opts.width or 280
	local alert = CreateFrame('Frame', nil, parent)
	alert.opts = opts
	alert.title = self:Label(alert, opts.title or '', 'ink', 9)
	alert.title:SetPoint('TOP', 6, 0)
	alert.led = self:Led(alert, 6, true)
	alert.led:SetPoint('RIGHT', alert.title, 'LEFT', -6, 0)
	self:SetLed(alert.led, true, opts.tone == 'error' and 'red' or opts.tone == 'success' and 'green' or opts.tone == 'info' and 'blue' or 'amber')
	alert.text = self:Text(alert, opts.text or '', 11, 'dim')
	alert.text:SetWidth(width - 24)
	alert.text:SetPoint('TOP', 0, -18)
	local height = 18 + max(alert.text:GetStringHeight(), 12) + 12
	alert:SetSize(width, height)
	-- Bracket rules: a top rule broken around the title, and a bottom rule.
	local gap = alert.title:GetStringWidth() / 2 + 22
	for _, side in ipairs({'LEFT', 'RIGHT'}) do
		local rule = self:Solid(alert, 'hair')
		rule:SetHeight(1)
		rule:SetPoint('TOP'..side, 0, -5)
		rule:SetPoint('TOP'..(side == 'LEFT' and 'RIGHT' or 'LEFT'), alert, 'TOP', side == 'LEFT' and -gap or gap, -5)
		local post = self:Solid(alert, 'hair')
		post:SetWidth(1)
		post:SetPoint('TOP'..side, 0, -5)
		post:SetPoint('BOTTOM'..side, 0, 0)
	end
	local bottom = self:Solid(alert, 'hair')
	bottom:SetHeight(1)
	bottom:SetPoint('BOTTOMLEFT'); bottom:SetPoint('BOTTOMRIGHT')
	return alert
end

-- 43 Separator -------------------------------------------------------------------------
function Kit:Separator(parent, length, vertical)
	local line = self:Solid(parent, 'hair')
	if vertical then line:SetSize(1, length or 20) else line:SetSize(length or 100, 1) end
	return line
end

-- 51 Item list ---------------------------------------------------------------------------
-- opts: columns = {{'ID', 40}, ...}, rows = {{...}, ...}, width, onSelect(index, row)
function Kit:ItemList(parent, opts)
	opts = opts or {}
	local columns, rows = opts.columns or {}, opts.rows or {}
	local rowHeight = 20
	local list = self:Panel(parent, {radius = 6, fill = 'lcd', border = 'hair'})
	list.opts, list.rows = opts, {}
	list:SetSize(opts.width or 280, 26 + #rows * rowHeight + 6)
	local function Cells(owner, values, token, y, left)
		local x, cells = left, {}
		for index, column in ipairs(columns) do
			local cell = Kit:Label(owner, values[index] or '', token, 8)
			cell:SetPoint('LEFT', owner, 'TOPLEFT', x, y)
			cells[index] = cell
			x = x + column[2]
		end
		return cells
	end
	local headers = {}
	for index, column in ipairs(columns) do headers[index] = column[1] end
	Cells(list, headers, 'lcdDim', -13, 12)
	local rule = self:Solid(list, 'lcdDim', 'ARTWORK', 0, 0.5)
	rule:SetHeight(1)
	rule:SetPoint('TOPLEFT', 8, -24); rule:SetPoint('TOPRIGHT', -8, -24)
	function list:Select(index)
		self.selected = index
		for i, row in ipairs(self.rows) do
			row.bar:SetShown(i == index)
			for _, cell in ipairs(row.cells) do Kit:Tint(cell, i == index and 'lcd' or 'lcdInk') end
		end
	end
	for index, values in ipairs(rows) do
		local row = CreateFrame('Button', nil, list)
		row:SetPoint('TOPLEFT', 4, -26 - (index - 1) * rowHeight)
		row:SetPoint('TOPRIGHT', -4, -26 - (index - 1) * rowHeight)
		row:SetHeight(rowHeight)
		row.bar = self:Texture(row, 'round-3', 'BACKGROUND')
		row.bar:SetAllPoints()
		self:Tint(row.bar, 'lcdInk')
		row.cells = Cells(row, values, 'lcdInk', -rowHeight / 2, 8) -- rows sit 4 px inside the list
		row:SetScript('OnClick', function()
			list:Select(index)
			Kit:Play('blip')
			if opts.onSelect then opts.onSelect(index, values) end
		end)
		list.rows[index] = row
	end
	list:Select(opts.selected or 1)
	return list
end

-- 50 Code block ----------------------------------------------------------------------------
-- opts: title, lines (strings; WoW color codes are allowed), width
function Kit:CodeBlock(parent, opts)
	opts = opts or {}
	local lines = opts.lines or {}
	local block = CreateFrame('Frame', nil, parent)
	block.opts = opts
	local lineHeight = 14
	block:SetSize(opts.width or 300, (opts.title and 16 or 0) + #lines * lineHeight + 24)
	if opts.title then
		block.title = self:Label(block, opts.title, 'dim', 8)
		block.title:SetPoint('TOPLEFT')
	end
	block.glass = self:Panel(block, {radius = 10, fill = 'glass', border = 'darkEdge', shadow = 0.5})
	block.glass:SetPoint('BOTTOMLEFT'); block.glass:SetPoint('BOTTOMRIGHT')
	block.glass:SetHeight(#lines * lineHeight + 24)
	for index, text in ipairs(lines) do
		local number = self:Text(block.glass, format('%02d', index), 10, 'darkDim')
		number:SetPoint('TOPLEFT', 14, -12 - (index - 1) * lineHeight)
		local line = self:Text(block.glass, text, 10, 'darkInk')
		line:SetPoint('TOPLEFT', 40, -12 - (index - 1) * lineHeight)
	end
	return block
end

-- 45 Display: a bezel around a live 3D unit or a texture ------------------------------------
-- opts: width, height, unit, texture, label
function Kit:Display(parent, opts)
	opts = opts or {}
	local display = CreateFrame('Frame', nil, parent)
	display.opts = opts
	local width, height = opts.width or 280, opts.height or 130
	display:SetSize(width, height + (opts.label and 18 or 0))
	display.bezel = self:Panel(display, {radius = 10, fill = 'glass', border = 'darkEdge', shadow = 0.6})
	display.bezel:SetPoint('TOPLEFT'); display.bezel:SetPoint('TOPRIGHT')
	display.bezel:SetHeight(height)
	display.screen = CreateFrame('Frame', nil, display.bezel)
	display.screen:SetPoint('TOPLEFT', 8, -8); display.screen:SetPoint('BOTTOMRIGHT', -8, 8)
	display.screen:SetClipsChildren(true)
	display.backing = display.screen:CreateTexture(nil, 'BACKGROUND')
	display.backing:SetAllPoints()
	display.backing:SetColorTexture(0.07, 0.08, 0.09, 1)
	if opts.unit then
		display.model = CreateFrame('PlayerModel', nil, display.screen)
		display.model:SetAllPoints()
		display.model:SetScript('OnShow', function(self)
			self:SetUnit(opts.unit)
			if self.SetPortraitZoom then self:SetPortraitZoom(0.55) end
		end)
		if display.model:IsVisible() then
			display.model:SetUnit(opts.unit)
			if display.model.SetPortraitZoom then display.model:SetPortraitZoom(0.55) end
		end
	elseif opts.texture then
		display.image = display.screen:CreateTexture(nil, 'ARTWORK')
		display.image:SetAllPoints()
		display.image:SetTexture(opts.texture)
	end
	if opts.label then
		display.caption = self:Label(display, opts.label, 'dim', 8)
		display.caption:SetPoint('BOTTOM')
	end
	return display
end
