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

-- Color ------------------------------------------------------------------------------------
-- A color value is {r, g, b} or {r =, g =, b =}, either with an optional alpha
-- ([4] or a =). A gradient is {from = color, to = color, dir = 'VERTICAL' | 'HORIZONTAL' | 'DIAGONAL'};
-- 'VERTICAL' runs from the top (from) to the bottom (to).
local function ColorParts(color)
	if type(color) ~= 'table' then return 1, 1, 1, 1 end
	if type(color.from) == 'table' then color = color.from end
	return color.r or color[1] or 1, color.g or color[2] or 1, color.b or color[3] or 1, color.a or color[4] or 1
end
Kit.ColorParts = ColorParts

-- OKLCH, the reference's color space, to and from sRGB (Björn Ottosson's OKLab).
-- Colors outside sRGB keep their lightness and hue and lose chroma until they fit.
local Color = {}
local sqrt, cos, sin, rad, deg = math.sqrt, math.cos, math.sin, math.rad, math.deg
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local MAX_CHROMA = 0.37

local function Linear(c) return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4 end
local function Gamma(c)
	c = c <= 0.0031308 and 12.92 * c or 1.055 * c ^ (1 / 2.4) - 0.055
	return min(max(c, 0), 1)
end
local function Cbrt(x) return x < 0 and -((-x) ^ (1 / 3)) or x ^ (1 / 3) end

function Color.ToLCH(r, g, b)
	r, g, b = Linear(r), Linear(g), Linear(b)
	local l = Cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
	local m = Cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
	local s = Cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
	local L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
	local A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
	local B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
	return L, sqrt(A * A + B * B), deg(atan2(B, A)) % 360
end

local function LinearOf(L, C, H)
	local a, b = C * cos(rad(H)), C * sin(rad(H))
	local l = (L + 0.3963377774 * a + 0.2158037573 * b) ^ 3
	local m = (L - 0.1055613458 * a - 0.0638541728 * b) ^ 3
	local s = (L - 0.0894841775 * a - 1.2914855480 * b) ^ 3
	return 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
		-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
		-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
end

local function Fits(r, g, b)
	local e = 0.0005
	return r >= -e and r <= 1 + e and g >= -e and g <= 1 + e and b >= -e and b <= 1 + e
end

function Color.ToRGB(L, C, H)
	L = min(max(L, 0), 1)
	local r, g, b = LinearOf(L, C, H)
	if not Fits(r, g, b) then
		local low, high = 0, C
		for _ = 1, 14 do
			local mid = (low + high) / 2
			if Fits(LinearOf(L, mid, H)) then low = mid else high = mid end
		end
		r, g, b = LinearOf(L, low, H)
	end
	return Gamma(r), Gamma(g), Gamma(b)
end

function Color.Hex(r, g, b)
	return format('#%02X%02X%02X', floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5))
end

function Color.Parse(text)
	local hex = type(text) == 'string' and text:gsub('[%s#]', '') or ''
	if hex:match('^%x%x%x$') then hex = hex:gsub('(%x)', '%1%1') end
	if not (hex:match('^%x%x%x%x%x%x$') or hex:match('^%x%x%x%x%x%x%x%x$')) then return nil end
	local function Byte(index) return tonumber(hex:sub(index, index + 1), 16) / 255 end
	return Byte(1), Byte(3), Byte(5), #hex == 8 and Byte(7) or nil
end

-- Five colors that go with one, by harmony (as the reference's palette).
local HARMONIES = {'Mono', 'Ana', 'Comp', 'Tri'}
function Color.Harmony(L, C, H, mode, out)
	local function Turn(by, l, c) return {l or L, c or C, (H + by + 360) % 360} end
	if mode == 'Mono' then
		for index, l in ipairs({0.3, 0.45, L, 0.8, 0.92}) do out[index] = {l, l > 0.85 and C * 0.5 or C, H} end
	elseif mode == 'Ana' then
		for index, by in ipairs({-40, -20, 0, 20, 40}) do out[index] = Turn(by) end
	elseif mode == 'Comp' then
		out[1], out[2], out[3] = Turn(0), Turn(0, L * 0.7), Turn(180)
		out[4], out[5] = Turn(180, min(0.92, L * 1.25), C * 0.6), Turn(0, 0.94, C * 0.2)
	else
		out[1], out[2], out[3] = Turn(0), Turn(120), Turn(240)
		out[4], out[5] = Turn(0, L * 0.65), Turn(0, 0.94, C * 0.2)
	end
	return out
end
Kit.Color = Color

-- The CX-1 color instrument --------------------------------------------------------------
-- After the reference's /color device: a harmony dial and RANDOM on the left
-- wing; a black screen in the middle with the color on a ring of 36 hues, its
-- OKLCH numbers, hex and a palette that goes with it; Lightness, Chroma and Hue
-- encoders on the right wing (or R, G and B). Added for the game: an LCD hex
-- readout that can be typed into, the key colors, class colors and recent
-- colors, an alpha slider, a two-stop gradient editor, and Cancel and Apply.
-- Every change shows at once (onChange runs live); Cancel or Escape puts the
-- color it opened with back.
local picker, ctx
local DIRECTIONS = {'VERTICAL', 'HORIZONTAL', 'DIAGONAL'}
local RING, DOT, SWATCH = 58, 5, 60
local CLASSES = {'WARRIOR', 'PALADIN', 'HUNTER', 'ROGUE', 'PRIEST', 'DEATHKNIGHT', 'SHAMAN', 'MAGE', 'WARLOCK', 'MONK',
	'DRUID', 'DEMONHUNTER', 'EVOKER'}

local function Recent() return UI:Account('colors') end

-- The color being edited: OKLCH plus its sRGB, and alpha.
local function State() return picker.state end

local function Emit()
	if not ctx then return end
	local state = State()
	local function Make(r, g, b, a, keyed)
		local value = keyed and {r = r, g = g, b = b} or {r, g, b}
		if ctx.alpha then if keyed then value.a = a else value[4] = a end end
		return value
	end
	local value
	if ctx.gradient then
		ctx.stops[ctx.stop] = {state.r, state.g, state.b, state.a}
		local from, to = ctx.stops.from, ctx.stops.to
		value = {from = Make(from[1], from[2], from[3], from[4], true), to = Make(to[1], to[2], to[3], to[4], true), dir = ctx.dir}
	else
		value = Make(state.r, state.g, state.b, state.a, ctx.keyed)
	end
	ctx.current = value
	if ctx.onChange then ctx.onChange(value) end
end

local Paint

-- Set the color from sRGB (keeping the hue of a gray) or from OKLCH.
local function SetRGB(r, g, b, quiet)
	local state = State()
	state.r, state.g, state.b = r, g, b
	local L, C, H = Color.ToLCH(r, g, b)
	state.l, state.c = L, C
	if C > 0.002 then state.h = H end
	Paint()
	if not quiet then Emit() end
end

local function SetLCH(L, C, H, quiet)
	local state = State()
	state.l, state.c, state.h = min(max(L, 0), 1), min(max(C, 0), MAX_CHROMA), (H or state.h) % 360
	state.r, state.g, state.b = Color.ToRGB(state.l, state.c, state.h)
	Paint()
	if not quiet then Emit() end
end

local function SetAlpha(a)
	State().a = min(max(a, 0), 1)
	Paint()
	Emit()
end

-- A small chip that sets a color when pressed.
local function Chip(parent, width, height, onClick)
	local chip = CreateFrame('Button', nil, parent)
	chip:SetSize(width, height)
	chip.shell = Kit:Shell(chip, {surface = 'screen', radius = 2, shadow = false})
	chip.color = chip:CreateTexture(nil, 'ARTWORK')
	chip.color:SetPoint('TOPLEFT', 1, -1)
	chip.color:SetPoint('BOTTOMRIGHT', -1, 1)
	chip.color:SetColorTexture(1, 1, 1, 1)
	chip:SetScript('OnClick', function(self)
		Kit:Play('tick')
		onClick(self)
	end)
	return chip
end

local function PushRecent(r, g, b)
	local store = Recent()
	store.recent = type(store.recent) == 'table' and store.recent or {}
	local hex = Color.Hex(r, g, b)
	for index = #store.recent, 1, -1 do if store.recent[index] == hex then table.remove(store.recent, index) end end
	table.insert(store.recent, 1, hex)
	for index = #store.recent, 9, -1 do store.recent[index] = nil end
end

local function Finish(apply)
	if not (picker and ctx) then return end
	local open = ctx
	open.applied = true
	if apply then
		local state = State()
		PushRecent(state.r, state.g, state.b)
		Kit:Play('success')
	elseif open.onChange then
		-- Put the old color back now, not when the closing animation ends.
		open.onChange(open.original)
	end
	Kit:Close(picker)
end

local function Build()
	picker = Kit:Device(UIParent, {name = 'JiberishSpec01ColorPicker', model = 'CX-1', title = 'Color', width = 640, height = 300, radius = 14})
	picker:SetFrameStrata('FULLSCREEN_DIALOG')
	picker:SetToplevel(true)
	picker:SetClampedToScreen(true)
	picker:SetMovable(true)
	picker:EnableMouse(true)
	picker:SetScript('OnMouseDown', function(self, button) if button == 'LeftButton' then self:StartMoving() end end)
	picker:SetScript('OnMouseUp', function(self) self:StopMovingOrSizing(); Kit:ResetRest(self) end)
	picker:Hide()
	tinsert(UISpecialFrames, 'JiberishSpec01ColorPicker')
	picker.state = {l = 0.68, c = 0.18, h = 47, r = 1, g = 0.5, b = 0.2, a = 1}

	-- Left wing: the harmony dial and RANDOM.
	picker.harmony = Kit:ModeDial(picker, {label = 'Harmony', items = HARMONIES, value = 2, size = 40, sweep = 150,
		onChange = function() Paint() end})
	picker.harmony:SetPoint('TOPLEFT', 12, -30)
	picker.random = Kit:Key(picker, {text = 'Random', width = 126, height = 28, onClick = function()
		SetLCH(0.55 + math.random() * 0.3, 0.08 + math.random() * 0.2, math.random() * 360)
	end})
	picker.random:SetPoint('TOPLEFT', picker.harmony, 'BOTTOMLEFT', 6, -10)

	-- The screen: the hue ring with the color in its middle, and the numbers.
	local display = Kit:Screen(picker, {inset = 4, radius = 8})
	display:SetSize(272, 156)
	display:SetPoint('TOPLEFT', 166, -30)
	picker.display = display
	local screen = display.screen
	local ring = CreateFrame('Frame', nil, screen)
	ring:SetSize(148, 148)
	ring:SetPoint('LEFT', 0, 0)
	picker.ring = ring
	picker.glow = Kit:Texture(ring, 'glow', 'BORDER', 0)
	picker.glow:SetSize(SWATCH * 1.9, SWATCH * 1.9)
	picker.glow:SetPoint('CENTER')
	picker.glow:SetBlendMode('ADD')
	picker.now = Kit:Texture(ring, 'circle', 'ARTWORK', 1)
	picker.now:SetSize(SWATCH, SWATCH)
	picker.now:SetPoint('CENTER')
	picker.dots = {}
	for index = 0, 35 do
		local angle = rad(index * 10 - 90)
		local dot = Kit:Texture(ring, 'circle', 'ARTWORK', 2)
		dot:SetSize(DOT, DOT)
		dot:SetPoint('CENTER', ring, 'CENTER', cos(angle) * RING, -sin(angle) * RING)
		picker.dots[index] = dot
	end
	picker.marker = Kit:Texture(ring, 'circle-ring', 'OVERLAY', 3)
	picker.marker:SetSize(DOT * 2.2, DOT * 2.2)
	picker.marker:SetVertexColor(0.95, 0.95, 0.93, 1)
	-- Turning the ring sets the hue; it clicks every ten degrees, like its dots.
	Kit:Drag(ring, function(self, x, y)
		local dx, dy = x - self:GetWidth() / 2, y - self:GetHeight() / 2
		if dx * dx + dy * dy < (SWATCH / 2) ^ 2 then return end
		local hue = (deg(atan2(-dy, dx)) + 90) % 360
		local state = State()
		if floor(hue / 10 + 0.5) ~= floor(state.h / 10 + 0.5) then Kit:Play('tick') end
		SetLCH(state.l, state.c, hue)
	end)
	local numbers = CreateFrame('Frame', nil, screen)
	numbers:SetPoint('TOPLEFT', ring, 'TOPRIGHT', 0, -10)
	numbers:SetPoint('BOTTOMRIGHT', -10, 10)
	picker.tag = Kit:Label(numbers, 'OKLCH', 'screenAccent', 8, true)
	picker.tag:SetPoint('TOPLEFT')
	picker.values = {}
	for index, name in ipairs({'L', 'C', 'H'}) do
		local key = Kit:Label(numbers, name, 'darkDim', 8)
		key:SetPoint('TOPLEFT', 0, -16 - (index - 1) * 18)
		local value = Kit:Text(numbers, '', 13, 'darkInk', true, true)
		value:SetPoint('LEFT', key, 'LEFT', 16, 0)
		picker.values[index] = value
	end
	picker.hex = Kit:Text(numbers, '', 11, 'darkInk', true, true)
	picker.hex:SetPoint('TOPLEFT', 0, -74)
	picker.palette = {}
	for index = 1, 5 do
		local chip = Chip(numbers, 18, 12, function(self)
			if self.lch then SetLCH(self.lch[1], self.lch[2], self.lch[3]) end
		end)
		chip:SetPoint('BOTTOMLEFT', (index - 1) * 21, 0)
		picker.palette[index] = chip
	end
	Kit:Label(picker, 'CX-1  Color', 'legend', 7):SetPoint('TOP', display, 'BOTTOM', 0, -4)

	-- Under the screen: the hex LCD (type into it) and the gradient stops.
	picker.lcd = Kit:LCD(picker, {tag = 'Hex', ghost = '888888', size = 'sm', width = 120})
	picker.lcd:SetPoint('TOPLEFT', display, 'BOTTOMLEFT', 0, -18)
	if picker.lcd.ghost then Kit:Ghost(picker.lcd.ghost) end
	local edit = CreateFrame('EditBox', nil, picker.lcd)
	edit:SetAllPoints()
	edit:SetAutoFocus(false)
	edit:SetMaxLetters(9)
	edit:SetJustifyH('RIGHT')
	edit:SetTextInsets(8, 8, 12, 0)
	edit:SetAlpha(0)
	picker.edit = edit
	edit:SetScript('OnEditFocusGained', function(self)
		local path, size, flags = picker.lcd.digits:GetFont()
		if path then self:SetFont(path, size, flags or '') end
		self:SetTextColor(Kit:RGB('lcdInk'))
		self:SetAlpha(1)
		picker.lcd.digits:Hide()
		local state = State()
		self:SetText(Color.Hex(state.r, state.g, state.b):sub(2))
		self:HighlightText()
	end)
	edit:SetScript('OnEditFocusLost', function(self)
		self:SetAlpha(0)
		picker.lcd.digits:Show()
	end)
	edit:SetScript('OnEscapePressed', edit.ClearFocus)
	edit:SetScript('OnChar', function(_, character) Kit:Play(character == ' ' and 'type-space' or 'type') end)
	edit:SetScript('OnEnterPressed', function(self)
		local r, g, b, a = Color.Parse(self:GetText())
		self:ClearFocus()
		if not r then Kit:Play('error') return end
		Kit:Play('down')
		if a and ctx and ctx.alpha then State().a = a end
		SetRGB(r, g, b)
	end)

	picker.stopKeys = {}
	for index, stop in ipairs({'from', 'to'}) do
		local key = Kit:Key(picker, {text = stop == 'from' and 'From' or 'To', toggle = true, tone = 'dark', width = 58, height = 26,
			onClick = function()
				if not ctx then return end
				ctx.stop = stop
				local color = ctx.stops[stop]
				State().a = color[4] or 1
				SetRGB(color[1], color[2], color[3], true)
			end})
		key:SetPoint('LEFT', picker.lcd, 'RIGHT', 10 + (index - 1) * 62, 0)
		picker.stopKeys[stop] = key
	end
	picker.bar = CreateFrame('Frame', nil, picker)
	picker.bar:SetSize(132, 12)
	picker.bar:SetPoint('TOPLEFT', picker.stopKeys.from, 'BOTTOMLEFT', 0, -6)
	picker.bar.shell = Kit:Shell(picker.bar, {surface = 'screen', radius = 2, shadow = false})
	picker.bar.fill = picker.bar:CreateTexture(nil, 'ARTWORK')
	picker.bar.fill:SetPoint('TOPLEFT', 1, -1)
	picker.bar.fill:SetPoint('BOTTOMRIGHT', -1, 1)
	picker.bar.fill:SetColorTexture(1, 1, 1, 1)
	picker.direction = Kit:Segmented(picker, {items = {'Down', 'Across', 'Diagonal'}, width = 150, value = 1, onChange = function(index)
		if not ctx then return end
		ctx.dir = DIRECTIONS[index] or 'VERTICAL'
		Paint()
		Emit()
	end})
	picker.direction:SetPoint('TOPLEFT', picker.lcd, 'BOTTOMLEFT', 0, -8)

	-- Right wing: the encoders (Lightness, Chroma, Hue or R, G, B), alpha, and the keys.
	local function Encoders(specs)
		local set = {}
		for index, spec in ipairs(specs) do
			local knob = Kit:Knob(picker, {label = spec[1], size = 34, min = 0, max = spec[2], step = 1, format = spec[4],
				onChange = spec[3]})
			knob:SetPoint('TOPLEFT', 452 + (index - 1) * 60, -28)
			set[index] = knob
		end
		return set
	end
	local function Three(value) return format('%03d', value) end
	picker.lch = Encoders({
		{'Lightness', 100, function(v) local s = State(); SetLCH(v / 100, s.c, s.h) end},
		{'Chroma', 100, function(v) local s = State(); SetLCH(s.l, v / 100 * MAX_CHROMA, s.h) end},
		{'Hue', 359, function(v) local s = State(); SetLCH(s.l, s.c, v) end, Three},
	})
	picker.rgb = Encoders({
		{'Red', 255, function(v) local s = State(); SetRGB(v / 255, s.g, s.b) end, Three},
		{'Green', 255, function(v) local s = State(); SetRGB(s.r, v / 255, s.b) end, Three},
		{'Blue', 255, function(v) local s = State(); SetRGB(s.r, s.g, v / 255) end, Three},
	})
	picker.mode = Kit:Segmented(picker, {items = {'LCH', 'RGB'}, width = 120, value = 1, onChange = function() Paint() end})
	picker.mode:SetPoint('TOPLEFT', 482, -124)
	picker.alphaSlider = Kit:Slider(picker, {label = 'Alpha', min = 0, max = 100, step = 1, width = 170, ticks = 10,
		format = function(v) return format('%d%%', v) end, onChange = function(v) SetAlpha(v / 100) end})
	picker.alphaSlider:SetPoint('TOPLEFT', 454, -160)
	picker.cancel = Kit:Key(picker, {text = 'Cancel', width = 82, height = 30, onClick = function() Finish(false) end})
	picker.apply = Kit:Key(picker, {text = 'Apply', tone = 'primary', width = 82, height = 30, onClick = function() Finish(true) end})
	picker.apply:SetPoint('BOTTOMRIGHT', -14, 14)
	picker.cancel:SetPoint('RIGHT', picker.apply, 'LEFT', -8, 0)

	-- Along the foot: the key colors, recent colors and class colors.
	picker.rows = CreateFrame('Frame', nil, picker)
	picker.rows:SetSize(420, 44)
	local function Row(label, y)
		local text = Kit:Label(picker.rows, label, 'legend', 7)
		text:SetPoint('TOPLEFT', 0, y - 3)
		return text
	end
	local x0 = 50
	Row('Key', 0)
	picker.keyChips = {}
	for index, name in ipairs(Kit.accentOrder) do
		local skin = Kit.accentSkin and Kit.accentSkin[name]
		local color = skin and skin.key or Kit.accents[name]
		local chip = Chip(picker.rows, 18, 14, function() SetRGB(color[1], color[2], color[3]) end)
		chip.color:SetColorTexture(color[1], color[2], color[3], 1)
		if Kit.accents[name] then Kit:AttachTooltip(chip, Kit.accents[name].name) end
		chip:SetPoint('TOPLEFT', x0 + (index - 1) * 21, 0)
	end
	local recentLabel = Row('Recent', 0)
	recentLabel:ClearAllPoints()
	recentLabel:SetPoint('TOPLEFT', x0 + 6 * 21 + 12, -3)
	picker.recentChips = {}
	for index = 1, 8 do
		local chip = Chip(picker.rows, 18, 14, function(self) if self.rgb then SetRGB(self.rgb[1], self.rgb[2], self.rgb[3]) end end)
		chip:SetPoint('TOPLEFT', x0 + 6 * 21 + 60 + (index - 1) * 21, 0)
		picker.recentChips[index] = chip
	end
	Row('Class', -22)
	local colors = CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS or {}
	local count = 0
	for _, class in ipairs(CLASSES) do
		local color = colors[class]
		if color then
			count = count + 1
			local chip = Chip(picker.rows, 18, 14, function() SetRGB(color.r, color.g, color.b) end)
			chip.color:SetColorTexture(color.r, color.g, color.b, 1)
			Kit:AttachTooltip(chip, LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class] or class)
			chip:SetPoint('TOPLEFT', x0 + (count - 1) * 21, -22)
		end
	end

	picker:SetScript('OnHide', function()
		if picker.edit:HasFocus() then picker.edit:ClearFocus() end
		local open = ctx
		ctx = nil
		if open and not open.applied and open.onChange then open.onChange(open.original) end
	end)
end

local paletteBuffer = {}
function Paint()
	local state = State()
	local r, g, b = state.r, state.g, state.b
	picker.now:SetVertexColor(r, g, b, 1)
	picker.glow:SetVertexColor(r, g, b, 0.6)
	local near = floor(state.h / 10 + 0.5) % 36
	for index = 0, 35 do
		local dot = picker.dots[index]
		dot:SetVertexColor(Color.ToRGB(state.l, max(state.c, 0.04), index * 10))
		dot:SetSize(index == near and DOT * 1.7 or DOT, index == near and DOT * 1.7 or DOT)
	end
	picker.marker:ClearAllPoints()
	picker.marker:SetPoint('CENTER', picker.dots[near], 'CENTER')
	picker.values[1]:SetText(format('%d', state.l * 100 + 0.5))
	picker.values[2]:SetText(format('%.2f', state.c))
	picker.values[3]:SetText(format('%03d', state.h + 0.5))
	local hex = Color.Hex(r, g, b)
	picker.hex:SetText(ctx and ctx.alpha and format('%s  %d%%', hex, state.a * 100 + 0.5) or hex)
	if not picker.edit:HasFocus() then picker.lcd.digits:SetText(hex:sub(2)) end
	Color.Harmony(state.l, state.c, state.h, HARMONIES[picker.harmony:GetValue()] or 'Ana', paletteBuffer)
	for index, chip in ipairs(picker.palette) do
		local lch = paletteBuffer[index]
		chip.lch = lch
		chip.color:SetColorTexture(Color.ToRGB(lch[1], lch[2], lch[3]))
	end
	-- Encoders follow without reporting a change.
	local rgbMode = picker.mode:GetValue() == 2
	for _, knob in ipairs(picker.lch) do knob:SetShown(not rgbMode) end
	for _, knob in ipairs(picker.rgb) do knob:SetShown(rgbMode) end
	picker.lch[1]:SetValue(floor(state.l * 100 + 0.5))
	picker.lch[2]:SetValue(floor(state.c / MAX_CHROMA * 100 + 0.5))
	picker.lch[3]:SetValue(floor(state.h + 0.5) % 360)
	picker.rgb[1]:SetValue(floor(r * 255 + 0.5))
	picker.rgb[2]:SetValue(floor(g * 255 + 0.5))
	picker.rgb[3]:SetValue(floor(b * 255 + 0.5))
	picker.alphaSlider:SetValue(floor(state.a * 100 + 0.5))
	-- The gradient preview and its stops.
	if ctx and ctx.gradient then
		ctx.stops[ctx.stop] = {r, g, b, state.a}
		local from, to = ctx.stops.from, ctx.stops.to
		local top, bottom = CreateColor(from[1], from[2], from[3], from[4] or 1), CreateColor(to[1], to[2], to[3], to[4] or 1)
		-- The preview bar runs across, whichever way the gradient goes.
		picker.bar.fill:SetGradient('HORIZONTAL', top, bottom)
		for stop, key in pairs(picker.stopKeys) do key:SetChecked(stop == ctx.stop) end
	end
end

-- Open the instrument. opts: value, alpha, gradient, anchor (a frame to open
-- by), onChange(value) live; Cancel calls onChange with the value it opened with.
function Kit:OpenColorPicker(opts)
	opts = opts or {}
	if not picker then Build() end
	if ctx and picker:IsShown() then
		-- A second swatch takes over: the first keeps what it has.
		ctx.applied = true
	end
	local value = opts.value
	local gradient = opts.gradient or (type(value) == 'table' and type(value.from) == 'table')
	local first = gradient and type(value) == 'table' and value.from or value
	local alpha = opts.alpha or (type(first) == 'table' and (first.a ~= nil or first[4] ~= nil))
	ctx = {onChange = opts.onChange, original = value, alpha = alpha and true or false, gradient = gradient and true or false,
		keyed = type(value) == 'table' and (value.r ~= nil or gradient) or false, stop = 'from', dir = 'VERTICAL'}
	local state = State()
	if gradient then
		local from = type(value) == 'table' and value.from or {1, 1, 1, 1}
		local to = type(value) == 'table' and value.to or from
		local fr, fg, fb, fa = ColorParts(from)
		local tr, tg, tb, ta = ColorParts(to)
		ctx.stops = {from = {fr, fg, fb, fa}, to = {tr, tg, tb, ta}}
		local dir = type(value) == 'table' and value.dir
		ctx.dir = (dir == 'HORIZONTAL' or dir == 'DIAGONAL') and dir or 'VERTICAL'
		picker.direction:SetValue(ctx.dir == 'DIAGONAL' and 3 or ctx.dir == 'HORIZONTAL' and 2 or 1)
	end
	local r, g, b, a = ColorParts(first)
	state.a = alpha and a or 1
	-- Recent colors.
	local recent = type(Recent().recent) == 'table' and Recent().recent or {}
	for index, chip in ipairs(picker.recentChips) do
		local rr, rg, rb = Color.Parse(recent[index])
		chip.rgb = rr and {rr, rg, rb} or nil
		chip:SetShown(rr ~= nil)
		if rr then chip.color:SetColorTexture(rr, rg, rb, 1) end
	end
	-- Parts shown for this color: alpha and the gradient editor.
	picker.alphaSlider:SetShown(ctx.alpha)
	for _, key in pairs(picker.stopKeys) do key:SetShown(ctx.gradient) end
	picker.bar:SetShown(ctx.gradient)
	picker.direction:SetShown(ctx.gradient)
	picker.rows:ClearAllPoints()
	picker.rows:SetPoint('TOPLEFT', picker.display, 'BOTTOMLEFT', -152, ctx.gradient and -96 or -62)
	picker:SetHeight(ctx.gradient and 336 or 302)
	SetRGB(r, g, b, true)
	picker:ClearAllPoints()
	if opts.anchor then
		picker:SetPoint('TOPRIGHT', opts.anchor, 'BOTTOMRIGHT', 0, -6)
	else
		picker:SetPoint('CENTER')
	end
	Kit:ResetRest(picker)
	Kit:Open(picker)
	Kit:Play('open')
end

function Kit:CloseColorPicker(apply) Finish(apply) end

-- Color swatch: a small key with the color set in glass. Pressing it opens the
-- color instrument; Cancel there puts the old color back.
-- opts: value (a color or a gradient, see above), width, height, onChange(value, swatch),
--       alpha (true: edit alpha too; also on when the value carries one),
--       gradient (true: edit a two-stop gradient; also on when the value is one)
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
		if type(color) == 'table' and type(color.from) == 'table' then
			local fr, fg, fb, fa = ColorParts(color.from)
			local tr, tg, tb, ta = ColorParts(color.to)
			self.color:SetColorTexture(1, 1, 1, 1)
			-- A swatch shows any gradient across, from left to right.
			self.color:SetGradient('HORIZONTAL', CreateColor(fr, fg, fb, fa), CreateColor(tr, tg, tb, ta))
		else
			self.color:SetColorTexture(ColorParts(color))
		end
	end
	function swatch:GetValue() return self.value end
	swatch.onClick = function(self)
		Kit:OpenColorPicker({value = self.value, alpha = opts.alpha, gradient = opts.gradient, anchor = self,
			onChange = function(color)
				self:SetValue(color)
				if opts.onChange then opts.onChange(color, self) end
			end})
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
