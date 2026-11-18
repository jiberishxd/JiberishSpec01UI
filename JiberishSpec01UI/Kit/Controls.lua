-- Hardware kit controls: buttons, switches, keycaps, sliders, knobs and dials.
-- Every constructor takes (parent, opts) and returns a frame with SetValue/GetValue
-- where it holds a value; opts.onChange(value, widget) reports user changes only.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame = CreateFrame
local floor, max, min, cos, sin, rad = math.floor, math.max, math.min, math.cos, math.sin, math.rad

local function Changed(widget, value)
	if widget.opts.onChange then widget.opts.onChange(value, widget) end
end

-- 01 Button --------------------------------------------------------------
function Kit:Button(parent, opts)
	opts = opts or {}
	if opts.round then
		opts.width, opts.height = opts.width or 40, opts.height or 40
	else
		opts.width, opts.height = opts.width or 64, opts.height or 32
	end
	return self:Key(parent, opts)
end

-- 02 Switch --------------------------------------------------------------
function Kit:Switch(parent, opts)
	opts = opts or {}
	local zoom = self.zoom
	local width, height, thumbSize = 52 * zoom, 28 * zoom, 22 * zoom
	local switch = CreateFrame('Button', nil, parent)
	switch.opts = opts
	switch:SetSize(width, height)
	switch.off = self:Skin(switch, 'switch-off', 'BACKGROUND', 0)
	switch.on = self:Skin(switch, 'switch-on', 'BACKGROUND', 1)
	switch.thumb = CreateFrame('Frame', nil, switch)
	switch.thumb:SetSize(thumbSize, thumbSize)
	switch.thumb.skin = self:Skin(switch.thumb, 'switch-thumb', 'ARTWORK', 0)
	if opts.labels ~= false then
		switch.offLabel = self:Label(switch, (opts.labels and opts.labels[1]) or 'Off', 'dim')
		switch.offLabel:SetPoint('RIGHT', switch, 'LEFT', -8, 0)
		switch.onLabel = self:Label(switch, (opts.labels and opts.labels[2]) or 'On', 'dim')
		switch.onLabel:SetPoint('LEFT', switch, 'RIGHT', 8, 0)
	end
	-- The state printed in the track, on the side the thumb leaves bare: ON lit
	-- in the key's ink, OFF in red, so on and off read at a glance on any finish.
	switch.legendOn = self:Label(switch, 'On', 'onAccent', 6, true)
	switch.legendOn:SetPoint('LEFT', switch, 'LEFT', 8 * zoom, 0)
	switch.legendOff = self:Label(switch, 'Off', 'red', 6, true)
	switch.legendOff:SetPoint('RIGHT', switch, 'RIGHT', -7 * zoom, 0)
	for _, legend in ipairs({switch.legendOn, switch.legendOff}) do legend:SetDrawLayer('ARTWORK', 2) end
	local inset = 3 * zoom
	local function Paint(position)
		switch.thumb:ClearAllPoints()
		switch.thumb:SetPoint('LEFT', switch, 'LEFT', inset + position * (width - thumbSize - inset * 2), 0)
		switch.on:SetAlpha(position)
		switch.off:SetAlpha(1 - 0.35 * position)
		switch.legendOn:SetAlpha(position)
		switch.legendOff:SetAlpha(1 - position)
	end
	function switch:SetValue(checked, animate)
		self.checked = checked and true or false
		local target = self.checked and 1 or 0
		Kit:Animate(self, animate and 0.12 or 0, animate and 1 - target or target, target, Paint, nil, Kit.ControlEase and Kit:ControlEase() or 'detent')
	end
	function switch:GetValue() return self.checked end
	switch:SetScript('OnClick', function(self)
		self:SetValue(not self.checked, true)
		Kit:Play('down-primary')
		Changed(self, self.checked)
	end)
	switch:SetValue(opts.checked)
	return switch
end

-- 03 Checkbox: a dark keycap with a status LED ----------------------------
function Kit:Checkbox(parent, opts)
	opts = opts or {}
	local key = self:Key(parent, {width = opts.width or 48, height = opts.height or 40, tone = opts.tone or 'dark',
		text = opts.text, icon = opts.icon, toggle = true, checked = opts.checked, textSize = 8})
	key.opts = opts
	if key.text then
		key.text:ClearAllPoints()
		key.text:SetPoint('CENTER', 0, -3)
	end
	key.onClick = function(self) Changed(self, self.checked) end
	function key:SetValue(checked) self:SetChecked(checked) end
	function key:GetValue() return self.checked end
	return key
end

-- 04 Segmented control ----------------------------------------------------
function Kit:Segmented(parent, opts)
	opts = opts or {}
	local items = opts.items or {'1', '2', '3', '4'}
	local width = opts.width or 200
	local segment = (width - 4) / #items
	local control = self:Well(parent, 6, 'track')
	control.opts = opts
	control:SetSize(width, 30)
	control.thumb = self:Panel(control, {sprite = 'segment-thumb'})
	control.thumb:SetSize(segment, 26)
	control.buttons = {}
	local function Paint(position)
		control.thumb:ClearAllPoints()
		control.thumb:SetPoint('LEFT', control, 'LEFT', 2 + position * segment, 0)
	end
	function control:SetValue(index, animate)
		index = Kit:Clamp(index or 1, 1, #items)
		local from = self.value or index
		self.value = index
		for i, button in ipairs(self.buttons) do Kit:Tint(button.label, i == index and 'ink' or 'dim') end
		-- The reference's indicator: left 200 ms on the detent curve.
		Kit:Animate(self, animate and Kit:TransitionTime(0.2, 0.16) or 0, animate and from - 1 or index - 1, index - 1, Paint, nil, Kit.ControlEase and Kit:ControlEase() or 'detent')
	end
	function control:GetValue() return self.value end
	for i, text in ipairs(items) do
		local button = CreateFrame('Button', nil, control)
		button:SetSize(segment, 30)
		button:SetPoint('LEFT', control, 'LEFT', 2 + (i - 1) * segment, 0)
		button:SetFrameLevel(control.thumb:GetFrameLevel() + 1)
		button.label = self:Label(button, text, 'dim')
		button.label:SetPoint('CENTER')
		button:SetScript('OnClick', function()
			if control.value == i then return end
			control:SetValue(i, true)
			Kit:Play('tick')
			Changed(control, i)
		end)
		control.buttons[i] = button
	end
	control:SetValue(opts.value or 1)
	return control
end

-- 05 Slider ---------------------------------------------------------------
function Kit:Slider(parent, opts)
	opts = opts or {}
	local low, high, step = opts.min or 0, opts.max or 100, opts.step or 1
	local width, zoom = opts.width or 260, self.zoom
	local slider = CreateFrame('Frame', nil, parent)
	slider.opts = opts
	slider:SetSize(width, 56)
	slider.label = self:Label(slider, opts.label or '', 'ink')
	slider.label:SetPoint('TOPLEFT')
	slider.readout = self:Label(slider, '', 'dim')
	slider.readout:SetPoint('TOPRIGHT')
	local track = CreateFrame('Frame', nil, slider)
	track:SetPoint('TOPLEFT', 0, -14)
	track:SetSize(width, 46 * zoom)
	local rail = CreateFrame('Frame', nil, track)
	rail:SetPoint('LEFT'); rail:SetPoint('RIGHT')
	rail:SetHeight(8 * zoom)
	rail.skin = self:Skin(rail, 'slider-track', 'BACKGROUND', 0)
	local fill = CreateFrame('Frame', nil, track)
	fill:SetPoint('LEFT')
	fill:SetHeight(8 * zoom)
	fill.skin = self:Skin(fill, 'slider-fill', 'BORDER', 0)
	local thumb = CreateFrame('Frame', nil, track)
	thumb:SetSize(30 * zoom, 46 * zoom)
	thumb.skin = self:Skin(thumb, 'slider-thumb', 'ARTWORK', 0)
	local margin = 15 * zoom
	-- Tick scale below the track.
	local ticks = opts.ticks or 20
	for i = 0, ticks do
		local tick = self:Solid(slider, i % 5 == 0 and 'ink' or 'hair')
		tick:SetSize(1, i % 5 == 0 and 7 or 4)
		tick:SetPoint('TOP', slider, 'TOPLEFT', margin + (width - margin * 2) * i / ticks, -18 - 46 * zoom)
	end
	local function Paint()
		local fraction = (slider.value - low) / max(high - low, 1e-6)
		local x = margin + (width - margin * 2) * fraction
		thumb:ClearAllPoints()
		thumb:SetPoint('CENTER', track, 'LEFT', x, 0)
		fill:SetWidth(max(x, 8 * zoom))
		slider.readout:SetText(opts.format and opts.format(slider.value) or tostring(slider.value))
	end
	function slider:SetValue(value)
		self.value = Kit:Snap(value or low, low, high, step)
		Paint()
	end
	function slider:GetValue() return self.value end
	self:Drag(track, function(_, x)
		local value = Kit:Snap(low + (high - low) * Kit:Clamp((x - margin) / (width - margin * 2), 0, 1), low, high, step)
		if value ~= slider.value then
			slider:SetValue(value)
			Kit:Play('tick')
			Changed(slider, value)
		end
	end)
	slider:SetValue(opts.value or low)
	return slider
end

-- 06 Flat knob (also the engine of the mode dial and the jog wheel) -------
-- opts: size, min, max, step, value, label, sweep (degrees, default 270), detents
function Kit:Knob(parent, opts)
	opts = opts or {}
	local low, high, step = opts.min or 0, opts.max or 100, opts.step or 1
	local size, sweep = opts.size or 44, opts.sweep or 270
	local knob = CreateFrame('Frame', nil, parent)
	knob.opts = opts
	knob:SetSize(size + 26, size + 26 + (opts.label and 30 or 0))
	local dial = CreateFrame('Frame', nil, knob)
	dial:SetSize(size, size)
	dial:SetPoint('TOP', 0, -13)
	knob.dial = dial
	if opts.ticks ~= false then
		knob.ticks = self:Texture(knob, 'knob-ticks', 'BACKGROUND')
		knob.ticks:SetSize(size + 26, size + 26)
		knob.ticks:SetPoint('CENTER', dial)
		self:Tint(knob.ticks, 'dim')
	end
	knob.cap = self:Skin(dial, 'knob-cap', 'BORDER', 0)
	knob.pointer = self:Texture(dial, 'circle', 'ARTWORK')
	knob.pointer:SetSize(max(4, size / 9), max(4, size / 9))
	self:Tint(knob.pointer, 'lamp')
	if opts.label then
		knob.readout = self:Text(knob, '', 12, 'ink')
		knob.readout:SetPoint('TOP', dial, 'BOTTOM', 0, -12)
		knob.label = self:Label(knob, opts.label, 'dim', 8)
		knob.label:SetPoint('TOP', knob.readout, 'BOTTOM', 0, -4)
	end
	local function Paint()
		local fraction = (knob.value - low) / max(high - low, 1e-6)
		local angle = rad(90 + sweep / 2 - sweep * fraction)
		local radius = size / 2 - size / 5
		knob.pointer:ClearAllPoints()
		knob.pointer:SetPoint('CENTER', dial, 'CENTER', cos(angle) * radius, sin(angle) * radius)
		if knob.readout then knob.readout:SetText(opts.format and opts.format(knob.value) or tostring(knob.value)) end
	end
	function knob:SetValue(value)
		self.value = Kit:Snap(value or low, low, high, step)
		Paint()
	end
	function knob:GetValue() return self.value end
	local function Nudge(amount)
		local value = Kit:Snap(knob.value + amount, low, high, step)
		if value == knob.value then return end
		knob:SetValue(value)
		Kit:Play('tick')
		Changed(knob, value)
	end
	-- The whole knob takes the mouse (cap, tick ring and label), above its
	-- neighbours. On the ring, the knob turns to where you point and follows
	-- the cursor round; on the cap, dragging up or right turns it up, down or
	-- left turns it down (about 3x the knob's size for the full range; Shift
	-- for fine control). The wheel steps it, a double-click puts it back.
	knob:SetFrameLevel(parent:GetFrameLevel() + 4)
	local function Set(value)
		local snapped = Kit:Snap(value, low, high, step)
		if snapped ~= knob.value then
			knob:SetValue(snapped)
			Kit:Play('tick')
			Changed(knob, snapped)
		end
	end
	local function Centre()
		local cx, cy = dial:GetCenter()
		local kx, ky = knob:GetLeft(), knob:GetBottom()
		return cx - kx, cy - ky
	end
	local function AngleValue(x, y)
		local cx, cy = Centre()
		local angle = math.deg(math.atan2(y - cy, x - cx))
		-- 0 at the start of the sweep, clockwise.
		local start = 90 + sweep / 2
		local along = (start - angle) % 360
		if along > sweep then along = along - sweep > (360 - sweep) / 2 and 0 or sweep end
		return low + along / sweep * (high - low)
	end
	local mode, originX, originY, base
	self:Drag(knob, function(_, x, y)
		if mode == 'ring' then
			Set(AngleValue(x, y))
		else
			local travel = max(120, size * 3) * (IsShiftKeyDown() and 4 or 1)
			Set(base + ((y - originY) + (x - originX)) / travel * (high - low))
		end
	end, function(self)
		local x, y = Kit:Cursor(self)
		local cx, cy = Centre()
		local distance = math.sqrt((x - cx) ^ 2 + (y - cy) ^ 2)
		-- The ring is the tick band around the cap; the label below drags like the cap.
		mode = (distance > size * 0.42 and distance <= size * 0.5 + 15) and 'ring' or 'cap'
		originX, originY, base = x, y, knob.value
		Kit:Play('down')
	end, function() Kit:Play('up') end)
	knob:EnableMouseWheel(true)
	knob:SetScript('OnMouseWheel', function(_, delta) Nudge(delta * step * (IsShiftKeyDown() and 1 or (opts.wheelStep or 1))) end)
	local lastClick = 0
	knob:HookScript('OnMouseDown', function()
		local now = GetTime()
		if now - lastClick < 0.3 and opts.default ~= nil then Set(opts.default) end
		lastClick = now
	end)
	knob:HookScript('OnEnter', function()
		if not knob.glow then
			knob.glow = Kit:Texture(knob, 'glow', 'BACKGROUND', -1)
			knob.glow:SetPoint('TOPLEFT', dial, 'TOPLEFT', -10, 10)
			knob.glow:SetPoint('BOTTOMRIGHT', dial, 'BOTTOMRIGHT', 10, -10)
			Kit:Tint(knob.glow, 'lamp')
			knob.glow:SetAlpha(0)
		end
		Kit:FadeTo(knob.glow, 0.25, 'FAST')
	end)
	knob:HookScript('OnLeave', function() if knob.glow then Kit:FadeTo(knob.glow, 0, 'FAST') end end)
	knob:SetValue(opts.value or low)
	return knob
end

-- 15 Number stepper -------------------------------------------------------
function Kit:Stepper(parent, opts)
	opts = opts or {}
	local low, high, step = opts.min or 0, opts.max or 999, opts.step or 1
	local stepper = CreateFrame('Frame', nil, parent)
	stepper.opts = opts
	stepper:SetSize(150, 34)
	local function Nudge(direction)
		local value = Kit:Clamp(stepper.value + direction * step, low, high)
		if value == stepper.value then Kit:Play('error'); return end
		stepper:SetValue(value)
		Changed(stepper, value)
	end
	stepper.minus = self:Key(stepper, {width = 34, height = 32, icon = 'minus', onClick = function() Nudge(-1) end})
	stepper.minus:SetPoint('LEFT')
	stepper.plus = self:Key(stepper, {width = 34, height = 32, icon = 'plus', onClick = function() Nudge(1) end})
	stepper.plus:SetPoint('RIGHT')
	stepper.window = self:Well(stepper, 6, 'track')
	stepper.window:SetPoint('LEFT', stepper.minus, 'RIGHT', 6, 1)
	stepper.window:SetPoint('RIGHT', stepper.plus, 'LEFT', -6, 1)
	stepper.window:SetHeight(30)
	stepper.digits = self:Text(stepper.window, '', 16, 'accentInk')
	stepper.digits:SetPoint('CENTER')
	function stepper:SetValue(value)
		self.value = Kit:Clamp(value or low, low, high)
		self.digits:SetText(tostring(self.value))
	end
	function stepper:GetValue() return self.value end
	stepper:EnableMouseWheel(true)
	stepper:SetScript('OnMouseWheel', function(_, delta) Nudge(delta) end)
	stepper:SetValue(opts.value or low)
	return stepper
end

-- 14 Radio group / 26 Toggle group / 17 Toolbar keys ----------------------
-- opts.items: list of strings or {text=, icon=}; opts.multiple allows several lit keys.
function Kit:KeyGroup(parent, opts)
	opts = opts or {}
	local items = opts.items or {}
	local keyWidth, gap = opts.keyWidth or 56, opts.gap or 6
	local group = CreateFrame('Frame', nil, parent)
	group.opts, group.keys = opts, {}
	group:SetSize(#items * keyWidth + (#items - 1) * gap, (opts.keyHeight or 30) + 2)
	local selected = {}
	function group:SetValue(value)
		wipe(selected)
		if type(value) == 'table' then for _, index in ipairs(value) do selected[index] = true end
		elseif value then selected[value] = true end
		for index, key in ipairs(self.keys) do key:SetChecked(selected[index]) end
	end
	function group:GetValue()
		if not opts.multiple then
			for index in pairs(selected) do return index end
			return nil
		end
		local list = {}
		for index = 1, #items do if selected[index] then list[#list + 1] = index end end
		return list
	end
	for index, item in ipairs(items) do
		local info = type(item) == 'table' and item or {text = item}
		local key = self:Key(group, {width = keyWidth, height = opts.keyHeight or 30, tone = opts.tone,
			text = info.text, icon = info.icon, led = true, textSize = 8, sound = false})
		key:SetPoint('LEFT', (index - 1) * (keyWidth + gap), 0)
		key.onClick = function()
			if opts.multiple then
				selected[index] = not selected[index] or nil
				Kit:Play(selected[index] and 'latch-down' or 'latch-up')
			else
				if selected[index] then return end
				wipe(selected); selected[index] = true
				Kit:Play('latch-down')
			end
			for i, other in ipairs(group.keys) do other:SetChecked(selected[i]) end
			Changed(group, group:GetValue())
		end
		group.keys[index] = key
	end
	group:SetValue(opts.value)
	return group
end

function Kit:RadioGroup(parent, opts) return self:KeyGroup(parent, opts) end

function Kit:ToggleGroup(parent, opts)
	opts = opts or {}
	opts.multiple = opts.multiple ~= false
	opts.keyWidth = opts.keyWidth or 34
	return self:KeyGroup(parent, opts)
end

-- 54 Button group: keys that share one housing ----------------------------
function Kit:ButtonGroup(parent, opts)
	opts = opts or {}
	local items = opts.items or {}
	local keyWidth, height = opts.keyWidth or 34, opts.keyHeight or 30
	local group = self:Key(parent, {width = #items * keyWidth, height = height, tone = opts.tone, sound = false})
	group:EnableMouse(false)
	group.keys = {}
	for index, item in ipairs(items) do
		local key = CreateFrame('Button', nil, group.face)
		key:SetSize(keyWidth, height)
		key:SetPoint('LEFT', (index - 1) * keyWidth, 0)
		local ink = opts.tone == 'dark' and 'darkInk' or 'ink'
		if item.icon then
			key.icon = self:Icon(key, item.icon, 14, ink)
			key.icon:SetPoint('CENTER')
		else
			key.label = self:Label(key, item.text, ink)
			key.label:SetPoint('CENTER')
		end
		if index > 1 then
			local divider = self:Solid(key, opts.tone == 'dark' and 'darkEdge' or 'keyEdge')
			divider:SetSize(1, height - 12)
			divider:SetPoint('LEFT')
		end
		key:SetScript('OnMouseDown', function() group:SetPressed(true); Kit:Play('down') end)
		key:SetScript('OnMouseUp', function() group:SetPressed(false); Kit:Play('up') end)
		key:SetScript('OnClick', function() if item.onClick then item.onClick(key, index) end end)
		group.keys[index] = key
	end
	return group
end

-- 57 Slide switch -----------------------------------------------------------
function Kit:SlideSwitch(parent, opts)
	opts = opts or {}
	local items = opts.items or {'A', 'B', 'C'}
	local vertical = opts.vertical
	local travel = opts.length or 64
	local switch = CreateFrame('Frame', nil, parent)
	switch.opts = opts
	if vertical then switch:SetSize(90, travel + 26) else switch:SetSize(travel + 30, 52) end
	if opts.label then
		switch.caption = self:Label(switch, opts.label, 'ink', 8)
		switch.caption:SetPoint('TOP')
	end
	local rail = CreateFrame('Frame', nil, switch)
	if vertical then
		rail:SetSize(14, travel)
		rail:SetPoint('TOPRIGHT', -4, -18)
	else
		rail:SetSize(travel, 14)
		rail:SetPoint('TOP', 0, -16)
	end
	switch.slot = self:Solid(rail, 'dark')
	if vertical then switch.slot:SetSize(4, travel); switch.slot:SetPoint('CENTER')
	else switch.slot:SetSize(travel, 4); switch.slot:SetPoint('CENTER') end
	switch.lever = self:Panel(rail, {radius = 3, fill = 'key', border = 'keyEdge'})
	if vertical then switch.lever:SetSize(18, 10) else switch.lever:SetSize(10, 18) end
	switch.labels = {}
	local function Offset(index) return (index - 1) / max(#items - 1, 1) * (travel - 10) + 5 end
	for index, text in ipairs(items) do
		local label = self:Label(switch, text, 'dim', 8)
		if vertical then label:SetPoint('RIGHT', rail, 'TOPLEFT', -8, -Offset(index))
		else label:SetPoint('TOP', rail, 'BOTTOMLEFT', Offset(index), -8) end
		switch.labels[index] = label
	end
	local function Paint(position)
		switch.lever:ClearAllPoints()
		if vertical then switch.lever:SetPoint('CENTER', rail, 'TOP', 0, -position)
		else switch.lever:SetPoint('CENTER', rail, 'LEFT', position, 0) end
	end
	function switch:SetValue(index, animate)
		index = Kit:Clamp(index or 1, 1, #items)
		local from = self.value and Offset(self.value) or Offset(index)
		self.value = index
		for i, label in ipairs(self.labels) do Kit:Tint(label, i == index and 'ink' or 'dim') end
		-- The reference's slide switch lever: 300 ms on the detent curve.
		Kit:Animate(self, animate and Kit:TransitionTime(0.3, 0.12) or 0, animate and from or Offset(index), Offset(index), Paint, nil, Kit.ControlEase and Kit:ControlEase() or 'detent')
	end
	function switch:GetValue() return self.value end
	self:Drag(rail, function(_, x, y)
		local along = vertical and (travel - y) or x
		local index = Kit:Clamp(floor((along - 5) / max(travel - 10, 1) * (#items - 1) + 0.5) + 1, 1, #items)
		if index ~= switch.value then
			switch:SetValue(index, true)
			Kit:Play('latch-down')
			Changed(switch, index)
		end
	end)
	switch:SetValue(opts.value or 1)
	return switch
end

-- 52 D-pad ------------------------------------------------------------------
function Kit:DPad(parent, opts)
	opts = opts or {}
	local size = opts.size or 96
	local pad = CreateFrame('Frame', nil, parent)
	pad.opts = opts
	pad:SetSize(size, size)
	pad.well = self:Texture(pad, 'circle', 'BACKGROUND')
	pad.well:SetAllPoints()
	self:Tint(pad.well, 'well')
	pad.base = self:Texture(pad, 'circle', 'BORDER')
	pad.base:SetPoint('TOPLEFT', 5, -5); pad.base:SetPoint('BOTTOMRIGHT', -5, 5)
	self:Tint(pad.base, 'dark')
	local directions = {up = {'TOP', 0, -7, 'tri-up'}, down = {'BOTTOM', 0, 7, 'tri-down'},
		left = {'LEFT', 7, 0, 'tri-left'}, right = {'RIGHT', -7, 0, 'tri-right'}}
	pad.zones = {}
	for name, data in pairs(directions) do
		local zone = CreateFrame('Button', nil, pad)
		zone:SetSize(size * 0.3, size * 0.3)
		zone:SetPoint(data[1], data[2], data[3])
		zone.icon = self:Icon(zone, data[4], 12, 'darkDim')
		zone.icon:SetPoint('CENTER')
		zone:SetScript('OnMouseDown', function(self)
			Kit:Tint(self.icon, 'accent'); Kit:Play('down')
			if opts.onPress then opts.onPress(name, pad) end
		end)
		zone:SetScript('OnMouseUp', function(self) Kit:Tint(self.icon, 'darkDim'); Kit:Play('up') end)
		pad.zones[name] = zone
	end
	pad.center = self:Key(pad, {round = true, width = size * 0.3, height = size * 0.3, tone = 'dark', lip = 1,
		onClick = function() if opts.onPress then opts.onPress('center', pad) end end})
	pad.center:SetPoint('CENTER')
	return pad
end

-- 53 Mode dial: a knob that snaps between named stops -----------------------
function Kit:ModeDial(parent, opts)
	opts = opts or {}
	local items = opts.items or {'Low', 'Medium', 'High'}
	local size, sweep = opts.size or 52, opts.sweep or 180
	local dial = CreateFrame('Frame', nil, parent)
	dial.opts = opts
	dial:SetSize(size + 110, size + 60)
	if opts.label then
		dial.caption = self:Label(dial, opts.label, 'ink', 8)
		dial.caption:SetPoint('TOPLEFT')
	end
	dial.labels = {}
	dial.knob = self:Knob(dial, {size = size, min = 1, max = #items, step = 1, value = opts.value or 1, sweep = sweep,
		onChange = function(value)
			dial:Paint()
			if opts.onChange then opts.onChange(value, dial) end
		end})
	dial.knob:SetPoint('BOTTOM', 0, 0)
	-- Stop names sit on their own layer above the highlight badges.
	local textLayer = CreateFrame('Frame', nil, dial)
	textLayer:SetAllPoints()
	textLayer:SetFrameLevel(dial:GetFrameLevel() + 6)
	for index, text in ipairs(items) do
		local angle = rad(90 + sweep / 2 - sweep * (index - 1) / max(#items - 1, 1))
		local badge = self:Panel(dial, {radius = 3, fill = 'accent', border = false})
		local label = self:Label(textLayer, text, 'dim', 8)
		label:SetPoint('CENTER', dial.knob.dial, 'CENTER', cos(angle) * (size / 2 + 34), sin(angle) * (size / 2 + 26))
		badge:SetPoint('TOPLEFT', label, 'TOPLEFT', -5, 4)
		badge:SetPoint('BOTTOMRIGHT', label, 'BOTTOMRIGHT', 5, -4)
		dial.labels[index] = {label = label, badge = badge}
	end
	function dial:Paint()
		local value = self.knob:GetValue()
		for index, entry in ipairs(self.labels) do
			entry.badge:SetShown(index == value)
			Kit:Tint(entry.label, index == value and 'onAccent' or 'dim')
		end
	end
	function dial:SetValue(value) self.knob:SetValue(value); self:Paint() end
	function dial:GetValue() return self.knob:GetValue() end
	dial:Paint()
	return dial
end
