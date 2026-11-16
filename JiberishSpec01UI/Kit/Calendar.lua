-- Hardware kit calendar: a date readout on dark glass, a dot per day of the
-- month, and a jog wheel that turns the highlighted field. Also the date picker.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame = CreateFrame
local floor, max, min = math.floor, math.max, math.min

local function DaysIn(year, month)
	return tonumber(date('%d', time({year = year, month = month + 1, day = 0, hour = 12})))
end

local FIELDS = {'year', 'month', 'day'}

-- 13 Calendar ---------------------------------------------------------------
-- opts: date = {year=, month=, day=}, onChange(dateTable, calendar), onSet(dateTable, calendar)
function Kit:Calendar(parent, opts)
	opts = opts or {}
	local calendar = CreateFrame('Frame', nil, parent)
	calendar.opts = opts
	calendar:SetSize(300, 96)
	local glass = self:Panel(calendar, {radius = 6, fill = 'glass', border = 'darkEdge'})
	glass:SetPoint('LEFT')
	glass:SetSize(204, 96)
	glass.tag = self:Label(glass, 'Set date', 'darkDim', 7)
	glass.tag:SetPoint('TOPLEFT', 12, -10)
	glass.weekday = self:Label(glass, '', 'darkDim', 7)
	glass.weekday:SetPoint('TOPRIGHT', -12, -10)
	calendar.fields = {}
	local x = 12
	for index, name in ipairs(FIELDS) do
		local width = name == 'year' and 52 or 30
		local field = CreateFrame('Button', nil, glass)
		field:SetSize(width, 24)
		field:SetPoint('TOPLEFT', x, -24)
		field.bar = self:Texture(field, 'round-3', 'BACKGROUND')
		field.bar:SetAllPoints()
		self:Tint(field.bar, 'accent')
		field.text = self:Text(field, '', 18, 'darkInk')
		field.text:SetPoint('CENTER')
		field:SetScript('OnClick', function()
			calendar:SetField(index)
			Kit:Play('blip')
		end)
		calendar.fields[index] = field
		x = x + width
		if index < #FIELDS then
			local separator = self:Text(glass, '·', 16, 'darkDim')
			separator:SetPoint('LEFT', glass, 'TOPLEFT', x + 4, -36)
			x = x + 14
		end
	end
	-- One dot per day, laid out as weeks.
	calendar.dots = {}
	for day = 1, 37 do
		local dot = CreateFrame('Button', nil, glass)
		dot:SetSize(7, 7)
		dot.texture = dot:CreateTexture(nil, 'ARTWORK')
		dot.texture:SetPoint('CENTER')
		dot.texture:SetSize(4, 4)
		dot.texture:SetColorTexture(1, 1, 1, 1)
		dot:SetPoint('TOPLEFT', 12 + ((day - 1) % 7) * 7, -54 - floor((day - 1) / 7) * 7)
		dot:SetScript('OnClick', function(self)
			if not self.day then return end
			calendar:SetDate(calendar.year, calendar.month, self.day)
			calendar:SetField(3)
			Kit:Play('tick')
			if opts.onChange then opts.onChange(calendar:GetDate(), calendar) end
		end)
		calendar.dots[day] = dot
	end

	local function Paint()
		local stamp = time({year = calendar.year, month = calendar.month, day = calendar.day, hour = 12})
		glass.weekday:SetText(strupper(date('%a', stamp)))
		calendar.fields[1].text:SetText(format('%04d', calendar.year))
		calendar.fields[2].text:SetText(format('%02d', calendar.month))
		calendar.fields[3].text:SetText(format('%02d', calendar.day))
		for index, field in ipairs(calendar.fields) do
			field.bar:SetShown(index == calendar.field)
			Kit:Tint(field.text, index == calendar.field and 'onAccent' or 'darkInk')
		end
		local first = tonumber(date('%w', time({year = calendar.year, month = calendar.month, day = 1, hour = 12})))
		local count = DaysIn(calendar.year, calendar.month)
		for slot, dot in ipairs(calendar.dots) do
			local day = slot - first
			dot.day = day >= 1 and day <= count and day or nil
			dot:SetShown(dot.day ~= nil)
			if dot.day then
				if day == calendar.day then Kit:Tint(dot.texture, 'accent')
				else Kit:Tint(dot.texture, 'darkDim', 0.55) end
			end
		end
	end

	function calendar:SetDate(year, month, day)
		year = Kit:Clamp(year, 1970, 2099)
		while month > 12 do month = month - 12; year = year + 1 end
		while month < 1 do month = month + 12; year = year - 1 end
		self.year, self.month = year, month
		self.day = Kit:Clamp(day, 1, DaysIn(year, month))
		Paint()
	end
	function calendar:GetDate() return {year = self.year, month = self.month, day = self.day} end
	function calendar:SetField(index)
		self.field = index
		Paint()
	end
	local function Turn(delta)
		local year, month, day = calendar.year, calendar.month, calendar.day
		if calendar.field == 1 then year = year + delta
		elseif calendar.field == 2 then month = month + delta
		else
			-- Roll through month boundaries instead of stopping at them.
			day = day + delta
			if day < 1 then
				month = month - 1
				if month < 1 then month = 12; year = year - 1 end
				day = DaysIn(year, month)
			elseif day > DaysIn(year, month) then
				day = 1; month = month + 1
			end
		end
		calendar:SetDate(year, month, day)
		Kit:Play('tick')
		if opts.onChange then opts.onChange(calendar:GetDate(), calendar) end
	end

	-- Jog wheel: scroll or drag to turn; the centre key steps through the fields.
	local jog = CreateFrame('Frame', nil, calendar)
	jog:SetSize(84, 84)
	jog:SetPoint('RIGHT', 0, 0)
	jog.ticks = self:Texture(jog, 'knob-ticks', 'BACKGROUND')
	jog.ticks:SetAllPoints()
	self:Tint(jog.ticks, 'dim')
	jog.ring = self:Texture(jog, 'circle', 'BORDER')
	jog.ring:SetPoint('TOPLEFT', 12, -12); jog.ring:SetPoint('BOTTOMRIGHT', -12, 12)
	self:Tint(jog.ring, 'key')
	jog.edge = self:Texture(jog, 'circle-ring', 'BORDER', 1)
	jog.edge:SetAllPoints(jog.ring)
	self:Tint(jog.edge, 'keyEdge')
	local origin, turned
	self:Drag(jog, function(_, _, y)
		local steps = floor((y - origin) / 10 + 0.5)
		if steps ~= turned then
			Turn(steps - turned)
			turned = steps
		end
	end, function(self)
		local _, y = Kit:Cursor(self)
		origin, turned = y, 0
	end)
	jog:EnableMouseWheel(true)
	jog:SetScript('OnMouseWheel', function(_, delta) Turn(delta) end)
	jog.set = self:Key(jog, {round = true, width = 34, height = 34, tone = 'dark', text = 'Set', textSize = 8, lip = 1})
	jog.set:SetPoint('CENTER')
	jog.set.onClick = function()
		if calendar.field < #FIELDS then calendar:SetField(calendar.field + 1)
		else
			calendar:SetField(1)
			Kit:Play('success')
			if opts.onSet then opts.onSet(calendar:GetDate(), calendar) end
		end
	end
	calendar.jog, calendar.glass = jog, glass

	local today = opts.date or date('*t')
	calendar.field = 3
	calendar:SetDate(today.year, today.month, today.day)
	return calendar
end

-- 23 Date picker -----------------------------------------------------------------
function Kit:DatePicker(parent, opts)
	opts = opts or {}
	local picker = CreateFrame('Frame', nil, parent)
	picker.opts = opts
	local labelHeight = opts.label and 16 or 0
	picker:SetSize(opts.width or 160, labelHeight + 30)
	if opts.label then
		picker.label = self:Label(picker, opts.label, 'ink', 8)
		picker.label:SetPoint('TOPLEFT')
	end
	local glass = self:Well(picker, 6, 'glass', 'Button')
	glass:SetPoint('BOTTOMLEFT'); glass:SetPoint('BOTTOMRIGHT')
	glass:SetHeight(30)
	glass.text = self:Text(glass, '', 12, 'darkInk')
	glass.text:SetPoint('LEFT', 10, 0)
	glass.icon = self:Icon(glass, 'calendar', 14, 'darkDim')
	glass.icon:SetPoint('RIGHT', -10, 0)
	function picker:SetDate(value)
		self.date = {year = value.year, month = value.month, day = value.day}
		glass.text:SetText(format('%02d/%02d/%04d', value.month, value.day, value.year))
	end
	function picker:GetDate() return self.date end
	glass:SetScript('OnClick', function(self)
		Kit:Play('down')
		local panel = Kit:Popover(self, {width = 324, height = 120, cache = picker, build = function(panel)
			panel.calendar = Kit:Calendar(panel, {date = picker.date, onChange = function(value)
				picker:SetDate(value)
			end, onSet = function(value)
				picker:SetDate(value)
				Kit:ClosePopover()
				if opts.onChange then opts.onChange(value, picker) end
			end})
			panel.calendar:SetPoint('CENTER')
		end})
		panel.calendar:SetDate(picker.date.year, picker.date.month, picker.date.day)
		-- setting: the field being set blinks (1.1 s, set 70% of the time) while the calendar is open.
		if Kit.SettingBlink then
			Kit:SettingBlink(glass.text, true, function(set) Kit:Tint(glass.text, set and 'accent' or 'darkInk') end)
			if not panel.kitSettingHooked then
				panel.kitSettingHooked = true
				panel:HookScript('OnHide', function() Kit:SettingBlink(glass.text, false, function() Kit:Tint(glass.text, 'darkInk') end) end)
			end
		end
	end)
	picker:SetDate(opts.date or date('*t'))
	return picker
end
