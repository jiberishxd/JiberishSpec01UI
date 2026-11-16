-- Hardware kit inputs: text field, text area, drum select, combobox, code
-- (OTP) entry, dropdown, color swatch and the command palette.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame = CreateFrame
local floor, max, min, abs = math.floor, math.max, math.min, math.abs

local function TypeSound(_, character)
	Kit:Play(character == ' ' and 'type-space' or 'type')
end

-- Shared dark-glass edit box. Returns holder, glass, edit.
local function Glass(parent, opts, height, multiline)
	local holder = CreateFrame('Frame', nil, parent)
	holder.opts = opts
	local labelHeight = opts.label and 16 or 0
	holder:SetSize(opts.width or 180, labelHeight + height)
	if opts.label then
		holder.label = Kit:Label(holder, opts.label, 'ink', 8)
		holder.label:SetPoint('TOPLEFT')
	end
	local glass = Kit:Well(holder, 6, 'glass')
	glass:SetPoint('BOTTOMLEFT'); glass:SetPoint('BOTTOMRIGHT')
	glass:SetHeight(height)
	glass.focus = Kit:Texture(glass, 'ring-6', 'BORDER')
	glass.focus:SetAllPoints()
	Kit:Tint(glass.focus, 'accent')
	glass.focus:Hide()
	local edit = CreateFrame('EditBox', nil, glass)
	edit:SetAutoFocus(false)
	edit:SetMultiLine(multiline and true or false)
	Kit:Font(edit, 12)
	Kit:Tint(edit, 'darkInk')
	if multiline then
		glass:SetClipsChildren(true)
		edit:SetPoint('TOPLEFT', 10, -8)
		edit:SetWidth((opts.width or 180) - 20)
	else
		edit:SetPoint('TOPLEFT', 10, 0)
		edit:SetPoint('BOTTOMRIGHT', -10, 0)
	end
	edit.placeholder = Kit:Text(glass, opts.placeholder or '', 12, 'darkDim')
	edit.placeholder:SetPoint('TOPLEFT', 10, multiline and -8 or -10)
	local function Placeholder() edit.placeholder:SetShown(edit:GetText() == '') end
	edit:SetScript('OnEscapePressed', edit.ClearFocus)
	edit:SetScript('OnEditFocusGained', function() glass.focus:Show() end)
	edit:SetScript('OnEditFocusLost', function() glass.focus:Hide() end)
	edit:SetScript('OnChar', TypeSound)
	edit:SetScript('OnTextChanged', function(self, user)
		Placeholder()
		if user and opts.onChange then opts.onChange(self:GetText(), holder) end
	end)
	glass:EnableMouse(true)
	glass:SetScript('OnMouseDown', function() edit:SetFocus() end)
	holder.glass, holder.edit = glass, edit
	function holder:SetValue(text) edit:SetText(text or ''); Placeholder() end
	function holder:GetValue() return edit:GetText() end
	holder:SetValue(opts.value)
	return holder, glass, edit
end

-- 07 Text field ------------------------------------------------------------
function Kit:TextField(parent, opts)
	opts = opts or {}
	local field, _, edit = Glass(parent, opts, 32, false)
	edit:SetScript('OnEnterPressed', function(self)
		self:ClearFocus()
		Kit:Play('down')
		if opts.onEnter then opts.onEnter(self:GetText(), field) end
	end)
	-- block-caret: the reference's drawn block caret, blinking every 1.06 s.
	if Kit.Caret then Kit:Caret(edit) end
	return field
end

-- 24 Textarea ----------------------------------------------------------------
function Kit:TextArea(parent, opts)
	opts = opts or {}
	return (Glass(parent, opts, opts.height or 70, true))
end

-- 08 Select: a drum of options with the choice under the accent marks ----------
function Kit:Select(parent, opts)
	opts = opts or {}
	local items = opts.items or {}
	local width, rowHeight, visible = opts.width or 150, 22, 5
	local select = CreateFrame('Frame', nil, parent)
	select.opts = opts
	local labelHeight = opts.label and 16 or 0
	select:SetSize(width, labelHeight + rowHeight * visible)
	if opts.label then
		select.label = self:Label(select, opts.label, 'ink', 8)
		select.label:SetPoint('TOPLEFT')
	end
	local drum = self:Well(select, 6, 'track', 'Button')
	drum:SetPoint('BOTTOMLEFT'); drum:SetPoint('BOTTOMRIGHT')
	drum:SetHeight(rowHeight * visible)
	drum:SetClipsChildren(true)
	for _, side in ipairs({'LEFT', 'RIGHT'}) do
		local mark = self:Solid(drum, 'accent', 'OVERLAY')
		mark:SetSize(12, 1)
		mark:SetPoint(side, side == 'LEFT' and 6 or -6, 0)
	end
	local rows = {}
	for slot = 1, visible + 2 do
		rows[slot] = self:Label(drum, '', 'dim', 10)
	end
	local half = floor((visible + 2) / 2)
	local function Paint(position)
		local nearest = floor(position + 0.5)
		for slot, row in ipairs(rows) do
			local index = nearest + slot - 1 - half
			local distance = index - position
			row:SetText(items[index] and strupper(tostring(items[index])) or '')
			row:ClearAllPoints()
			row:SetPoint('CENTER', drum, 'CENTER', 0, -distance * rowHeight)
			Kit:Tint(row, index == nearest and 'accentInk' or 'dim', max(0.15, 1 - abs(distance) * 0.3))
		end
	end
	function select:SetValue(index, animate)
		index = Kit:Clamp(index or 1, 1, max(#items, 1))
		local from = self.value or index
		self.value = index
		Kit:Animate(self, animate and 0.14 or 0, animate and from or index, index, Paint, nil, 'detent')
	end
	function select:GetValue() return self.value, items[self.value] end
	local function Move(delta)
		local index = Kit:Clamp(select.value + delta, 1, max(#items, 1))
		if index == select.value then return end
		select:SetValue(index, true)
		Kit:Play('tick')
		if opts.onChange then opts.onChange(index, select, items[index]) end
	end
	drum:EnableMouseWheel(true)
	drum:SetScript('OnMouseWheel', function(_, delta) Move(-delta) end)
	drum:SetScript('OnClick', function(self)
		local _, y = Kit:Cursor(self)
		local offset = floor((self:GetHeight() / 2 - y) / rowHeight + 0.5)
		if offset ~= 0 then Move(offset) end
	end)
	select:SetValue(opts.value or 1)
	return select
end

-- 22 Combobox ----------------------------------------------------------------------
function Kit:Combobox(parent, opts)
	opts = opts or {}
	local items = opts.items or {}
	local box, glass, edit = Glass(parent, opts, 32, false)
	box.chevron = self:Icon(glass, 'chevron-down', 12, 'darkDim')
	box.chevron:SetPoint('RIGHT', -10, 0)
	edit:SetPoint('BOTTOMRIGHT', -28, 0)
	local function Open(instant)
		local filter = strlower(edit:GetText())
		local list = {}
		for _, item in ipairs(items) do
			if filter == '' or strfind(strlower(item), filter, 1, true) then list[#list + 1] = item end
		end
		if #list == 0 then list[1] = {text = 'No results', disabled = true} end
		Kit:Menu(glass, list, function(_, item)
			box:SetValue(item.text)
			edit:ClearFocus()
			if opts.onChange then opts.onChange(item.text, box) end
		end, {cache = box, width = glass:GetWidth(), sound = not instant, instant = instant})
	end
	edit:SetScript('OnEditFocusGained', function() glass.focus:Show(); Open(false) end)
	edit:SetScript('OnTextChanged', function(self, user)
		self.placeholder:SetShown(self:GetText() == '')
		if user then Open(true) end
	end)
	edit:SetScript('OnEnterPressed', edit.ClearFocus)
	return box
end

-- 25 OTP input ------------------------------------------------------------------------
function Kit:OTP(parent, opts)
	opts = opts or {}
	local length = opts.length or 6
	local otp = CreateFrame('Frame', nil, parent)
	otp.opts, otp.slots = opts, {}
	local x = 0
	for index = 1, length do
		if index == floor(length / 2) + 1 and length > 3 then
			local dash = self:Solid(otp, 'dim')
			dash:SetSize(6, 1)
			dash:SetPoint('LEFT', x + 4, 0)
			x = x + 14
		end
		local slot = self:Well(otp, 6, 'track')
		slot:SetSize(26, 32)
		slot:SetPoint('LEFT', x, 0)
		slot.digit = self:Text(slot, '', 14, 'ink')
		slot.digit:SetPoint('CENTER')
		slot.ring = self:Texture(slot, 'ring-6', 'BORDER')
		slot.ring:SetAllPoints()
		self:Tint(slot.ring, 'accent')
		slot.ring:Hide()
		otp.slots[index] = slot
		x = x + 30
	end
	otp:SetSize(x - 4, 32)
	local edit = CreateFrame('EditBox', nil, otp)
	edit:SetAllPoints()
	edit:SetAutoFocus(false)
	edit:SetNumeric(true)
	edit:SetMaxLetters(length)
	self:Font(edit, 8)
	edit:SetAlpha(0) -- the slots draw the digits; this only captures typing
	local function Paint()
		local text = edit:GetText()
		for index, slot in ipairs(otp.slots) do
			slot.digit:SetText(text:sub(index, index))
			slot.ring:SetShown(edit:HasFocus() and index == min(#text + 1, length))
		end
	end
	edit:SetScript('OnChar', TypeSound)
	edit:SetScript('OnEscapePressed', edit.ClearFocus)
	edit:SetScript('OnEditFocusGained', Paint)
	edit:SetScript('OnEditFocusLost', Paint)
	edit:SetScript('OnTextChanged', function(self, user)
		Paint()
		if user and #self:GetText() == length then
			self:ClearFocus()
			Kit:Play('success')
			if opts.onComplete then opts.onComplete(self:GetText(), otp) end
		end
	end)
	otp.edit = edit
	function otp:SetValue(text) edit:SetText(text or ''); Paint() end
	function otp:GetValue() return edit:GetText() end
	Paint()
	return otp
end

-- Dropdown: a key showing the choice, with a chevron; the list opens as a menu.
-- opts: items ({{value, text}} or plain values), value, width, height, onChange(value, dropdown)
function Kit:Dropdown(parent, opts)
	opts = opts or {}
	local items = opts.items or {}
	local dropdown = self:Key(parent, {width = opts.width or 150, height = opts.height or 26, text = ' ', textSize = opts.textSize})
	dropdown.opts = opts
	dropdown.chevron = self:Icon(dropdown.face, 'chevron-down', 10, 'ink')
	dropdown.chevron:SetPoint('RIGHT', -9, 0)
	dropdown.text:ClearAllPoints()
	dropdown.text:SetPoint('LEFT', 10, 0)
	dropdown.text:SetPoint('RIGHT', dropdown.chevron, 'LEFT', -6, 0)
	dropdown.text:SetJustifyH('LEFT')
	dropdown.text:SetWordWrap(false)
	local function Item(index)
		local item = items[index]
		if type(item) == 'table' then return item[1], item[2] or tostring(item[1]) end
		return item, tostring(item)
	end
	function dropdown:SetValue(value)
		self.value = value
		local text = ''
		for index = 1, #items do
			local itemValue, itemText = Item(index)
			if itemValue == value then text = itemText end
		end
		self:SetKeyText(text)
	end
	function dropdown:GetValue() return self.value end
	function dropdown:SetItems(list)
		items = list or {}
		self:SetValue(self.value)
	end
	dropdown.onClick = function(self)
		if Kit:IsPopoverOpen(self) then return Kit:ClosePopover() end
		local list = {}
		for index = 1, #items do
			local itemValue, itemText = Item(index)
			list[index] = {text = itemText, checked = itemValue == self.value}
		end
		if #list == 0 then list[1] = {text = 'Nothing to choose', disabled = true} end
		Kit:Menu(self, list, function(index)
			local itemValue = Item(index)
			if itemValue == nil then return end
			self:SetValue(itemValue)
			if opts.onChange then opts.onChange(itemValue, self) end
		end, {width = max(self:GetWidth(), 140), indent = true})
	end
	dropdown:SetValue(opts.value)
	return dropdown
end

-- Color swatch: a small key with the color set in glass. Pressing it opens the
-- game's color picker; cancelling there puts the old color back.
-- opts: value ({r, g, b} or {r=, g=, b=}), width, height, onChange(value, swatch)
local function ColorParts(color)
	if type(color) ~= 'table' then return 1, 1, 1 end
	return color.r or color[1] or 1, color.g or color[2] or 1, color.b or color[3] or 1
end
Kit.ColorParts = ColorParts

local raised = {}
local function OpenPicker(r, g, b, onChange)
	local picker = _G.ColorPickerFrame
	if not picker then return end
	-- The hub sits on a full-screen strata; lift the picker above it while it is open.
	if not raised.hooked then
		raised.hooked = true
		picker:HookScript('OnHide', function(self)
			if raised.strata then self:SetFrameStrata(raised.strata) end
			raised.strata = nil
		end)
	end
	raised.strata = raised.strata or picker:GetFrameStrata()
	picker:SetFrameStrata('FULLSCREEN_DIALOG')
	picker:SetFrameLevel(400)
	local function Current()
		if picker.GetColorRGB then return picker:GetColorRGB() end
		local content = picker.Content and picker.Content.ColorPicker
		if content and content.GetColorRGB then return content:GetColorRGB() end
	end
	local function Picked()
		local nr, ng, nb = Current()
		if nr then onChange(nr, ng, nb) end
	end
	local function Cancel(previous)
		if type(previous) == 'table' then onChange(previous.r or r, previous.g or g, previous.b or b)
		else onChange(r, g, b) end
	end
	if picker.SetupColorPickerAndShow then
		picker:SetupColorPickerAndShow({r = r, g = g, b = b, hasOpacity = false, swatchFunc = Picked, cancelFunc = Cancel})
	else
		picker.hasOpacity, picker.opacityFunc = false, nil
		picker.previousValues = {r = r, g = g, b = b}
		picker.func, picker.cancelFunc = Picked, Cancel
		picker:SetColorRGB(r, g, b)
		picker:Hide()
		picker:Show()
	end
end

function Kit:ColorSwatch(parent, opts)
	opts = opts or {}
	local swatch = self:Key(parent, {width = opts.width or 46, height = opts.height or 24})
	swatch.opts = opts
	local well = CreateFrame('Frame', nil, swatch.face)
	well:SetPoint('TOPLEFT', 7, -5)
	well:SetPoint('BOTTOMRIGHT', -7, 7)
	well.shell = self:Shell(well, {surface = 'glass', radius = 3, shadow = false})
	swatch.well = well
	swatch.color = well:CreateTexture(nil, 'ARTWORK')
	swatch.color:SetPoint('TOPLEFT', 2, -2)
	swatch.color:SetPoint('BOTTOMRIGHT', -2, 2)
	function swatch:SetValue(color)
		self.value = color
		self.color:SetColorTexture(ColorParts(color))
	end
	function swatch:GetValue() return self.value end
	swatch.onClick = function(self)
		local keyed = type(self.value) == 'table' and self.value.r ~= nil
		local r, g, b = ColorParts(self.value)
		OpenPicker(r, g, b, function(nr, ng, nb)
			local color = keyed and {r = nr, g = ng, b = nb} or {nr, ng, nb}
			self:SetValue(color)
			if opts.onChange then opts.onChange(color, self) end
		end)
	end
	swatch:SetValue(opts.value)
	return swatch
end

-- 29 Command palette ---------------------------------------------------------------------
-- opts.items: {{text=, hint=, icon=, onClick=}}
function Kit:Command(parent, opts)
	opts = opts or {}
	local items = opts.items or {}
	local trigger = self:Key(parent, {width = opts.width or 180, height = 30, icon = 'search',
		text = opts.placeholder or 'Search...'})
	trigger.hint = self:Label(trigger.face, opts.shortcut or 'Ctrl K', 'dim', 8)
	trigger.hint:SetPoint('RIGHT', -10, 0)
	local rowHeight = 26
	local function Build(panel)
		panel.field = Kit:TextField(panel, {width = panel:GetWidth() - 16, placeholder = opts.placeholder or 'Search...',
			onChange = function() panel:Filter() end})
		panel.field:SetPoint('TOP', 0, -8)
		panel.rows = {}
		for index = 1, #items do
			local row = CreateFrame('Button', nil, panel)
			row:SetSize(panel:GetWidth() - 16, rowHeight)
			row.highlight = Kit:Texture(row, 'round-3', 'BACKGROUND')
			row.highlight:SetAllPoints()
			Kit:Tint(row.highlight, 'track')
			row.highlight:Hide()
			row.icon = Kit:Icon(row, 'chevron-right', 12, 'dim')
			row.icon:SetPoint('LEFT', 6, 0)
			row.label = Kit:Label(row, '', 'ink')
			row.label:SetPoint('LEFT', 24, 0)
			row.hint = Kit:Label(row, '', 'dim', 8)
			row.hint:SetPoint('RIGHT', -8, 0)
			row:SetScript('OnEnter', function(self) self.highlight:Show(); Kit:Play('tick') end)
			row:SetScript('OnLeave', function(self) self.highlight:Hide() end)
			row:SetScript('OnClick', function(self)
				Kit:Play('down')
				Kit:ClosePopover()
				if self.item.onClick then self.item.onClick(self.item) end
			end)
			panel.rows[index] = row
		end
		function panel:Filter()
			local filter = strlower(self.field:GetValue())
			local shown = 0
			for index, item in ipairs(items) do
				local row = self.rows[index]
				local match = filter == '' or strfind(strlower(item.text), filter, 1, true)
				row:SetShown(match and true or false)
				if match then
					row.item = item
					row.label:SetText(strupper(item.text))
					row.hint:SetText(item.hint and strupper(item.hint) or '')
					Kit:SetIcon(row.icon, item.icon or 'chevron-right')
					row:ClearAllPoints()
					row:SetPoint('TOP', 0, -46 - shown * rowHeight)
					shown = shown + 1
				end
			end
			self:SetHeight(54 + max(shown, 1) * rowHeight)
		end
	end
	trigger.onClick = function(self)
		local panel = Kit:Popover(self, {width = max(self:GetWidth(), 220), height = 54 + #items * rowHeight, build = Build})
		panel.field:SetValue('')
		panel:Filter()
		panel.field.edit:SetFocus()
	end
	return trigger
end
