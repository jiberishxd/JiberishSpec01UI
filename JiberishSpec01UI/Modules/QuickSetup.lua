-- The hub's landing page: Quick setup. The few decisions that shape the whole
-- interface, each on a QS device of its own: the layout (two preview tiles),
-- the finish, the key color, the typeface, the UI scale, the fade, sounds and
-- motion. Each applies at once through UI:HubChange, so Undo (Ctrl+Z) takes it
-- back and anything that needs a reload lights the header's reload lamp. Every
-- device carries an LCD with the value in use and one line saying what it does;
-- the page that holds the rest of that setting's options is one key away.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown = CreateFrame, UIParent, InCombatLockdown
local floor, max, min = math.floor, math.max, math.min
local IsSecret = UI.Util.IsSecret

local QS = {} -- the page's parts, filled as it builds

-- Values ---------------------------------------------------------------------------------
local function Read(path) return UI.ReadOption(path) end

local FINISHES = {{'paper', 'Paper'}, {'graphite', 'Graphite'}}
local MOTION = {{false, 'Full'}, {true, 'Reduced'}}

local function Name(items, value, fallback)
	for _, item in ipairs(items or {}) do
		if item[1] == value then return item[2] end
	end
	return fallback or tostring(value or '')
end

local function ScaleItems()
	local perfect = floor(UI.Pixel.PerfectScale() * 100 + 0.5) / 100
	return {{perfect, 'Pixel'}, {0.64, '0.64'}, {0.8, '0.80'}, {1, '1.00'}}
end

local function CurrentScale() return UI.db.uiScale or UIParent:GetScale() end

-- The fade styles as the Fade page lists them, so the two can't drift.
local function FadeStyles()
	local page = UI:GetPage('fade')
	for _, card in ipairs(page and page.cards or {}) do
		for _, row in ipairs(card.rows or {}) do
			if row[3] == 'appearance.fade.style' and type(row.items) == 'table' then return row.items end
		end
	end
	return {{'smooth', 'Smooth'}}
end

local function ClassColor()
	local _, class = UnitClass('player')
	if IsSecret(class) or not class then return 1, 0.2, 0.1 end
	local color = (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS or {})[class]
	if not color then return 1, 0.2, 0.1 end
	return color.r, color.g, color.b
end

local function MasterVolume()
	local value = GetCVar and GetCVar('Sound_MasterVolume')
	if IsSecret(value) then return 0 end
	return floor((tonumber(value) or 0) * 100 + 0.5)
end

-- Parts ----------------------------------------------------------------------------------
-- A QS device: printed header, an LCD with the value in use at its top right,
-- and the one-line explanation along its bottom.
local function Device(content, model, title, width, height, note)
	local device = Kit:Device(content, {model = model, title = title, width = width, height = height, radius = 10})
	device.lcd = Kit:LCDPanel(device, {radius = 3})
	device.lcd:SetSize(min(96, floor(width * 0.42)), 16)
	device.lcd:SetPoint('TOPRIGHT', -10, -6)
	device.value = Kit:Text(device.lcd, '', 8, 'lcdInk', true)
	device.value:SetPoint('CENTER', 0, 0)
	device.value:SetWidth(device.lcd:GetWidth() - 8)
	device.value:SetWordWrap(false)
	Kit:Font(device.value, 8, nil, true, 'numbers')
	if device.title then
		device.title:ClearAllPoints()
		device.title:SetPoint('LEFT', device.model, 'RIGHT', 5, 0)
		device.title:SetPoint('RIGHT', device.lcd, 'LEFT', -6, 0)
	end
	device.note = Kit:Text(device, note or '', 9, 'dim')
	device.note:SetPoint('BOTTOMLEFT', 12, 10)
	device.note:SetWidth(width - 24)
	device.note:SetJustifyH('LEFT')
	device.note:SetWordWrap(true)
	if device.note.SetMaxLines then device.note:SetMaxLines(2) end
	device.body = CreateFrame('Frame', nil, device)
	device.body:SetPoint('TOPLEFT', 12, -30)
	device.body:SetPoint('TOPRIGHT', -12, -30)
	device.body:SetHeight(height - 30 - 34)
	if device.lamp then Kit:SetLed(device.lamp, true) end
	function device:SetReadout(text) Kit:PrintText(self.value, strupper(text or '')) end
	QS.devices[#QS.devices + 1] = device
	return device
end

-- Latching keys, one lit: {value, text} items; onPick(value).
local function KeyRow(parent, items, width, height, onPick)
	local row = CreateFrame('Frame', nil, parent)
	local gap = 4
	local keyWidth = floor((width - gap * (#items - 1)) / #items)
	row:SetSize(width, height)
	row.keys = {}
	for index, item in ipairs(items) do
		-- Narrow keys latch without a lamp, so the legend has the whole cap.
		local key = Kit:Key(row, {text = item[2], width = keyWidth, height = height, led = keyWidth >= 64, sound = false, textSize = 8})
		key:SetPoint('LEFT', (index - 1) * (keyWidth + gap), 0)
		key.value = item[1]
		key.onClick = function()
			Kit:Play('latch-down')
			onPick(key.value)
		end
		row.keys[index] = key
	end
	function row:SetValue(value)
		for _, key in ipairs(self.keys) do key:SetChecked(key.value == value) end
	end
	function row:SetItems(list)
		for index, item in ipairs(list) do
			local key = self.keys[index]
			if key then key.value = item[1]; key:SetKeyText(item[2]) end
		end
	end
	return row
end

-- A selector: two arrow keys stepping through items, the choice on an LCD between.
local function Stepper(parent, width, getItems, getValue, onPick)
	local stepper = CreateFrame('Frame', nil, parent)
	stepper:SetSize(width, 28)
	local function Step(direction)
		local items = getItems()
		if #items == 0 then return Kit:Play('error') end
		local current = 0
		for index, item in ipairs(items) do if item[1] == getValue() then current = index end end
		local index = ((current - 1 + direction) % #items) + 1
		if current == 0 then index = direction > 0 and 1 or #items end
		onPick(items[index][1])
	end
	stepper.back = Kit:Key(stepper, {icon = 'tri-left', iconSize = 9, width = 28, height = 28, sound = 'down'})
	stepper.back:SetPoint('LEFT', 0, 0)
	stepper.back.onClick = function() Step(-1) end
	stepper.next = Kit:Key(stepper, {icon = 'tri-right', iconSize = 9, width = 28, height = 28, sound = 'down'})
	stepper.next:SetPoint('RIGHT', 0, 0)
	stepper.next.onClick = function() Step(1) end
	stepper.lcd = Kit:LCDPanel(stepper, {radius = 3})
	stepper.lcd:SetPoint('TOPLEFT', stepper.back, 'TOPRIGHT', 4, -2)
	stepper.lcd:SetPoint('BOTTOMRIGHT', stepper.next, 'BOTTOMLEFT', -4, 2)
	stepper.text = Kit:Text(stepper.lcd, '', 9, 'lcdInk', true)
	stepper.text:SetPoint('LEFT', 6, 0)
	stepper.text:SetPoint('RIGHT', -6, 0)
	stepper.text:SetWordWrap(false)
	function stepper:SetValue(text) self.text:SetText(strupper(text or '')) end
	return stepper
end

-- A round key cap in a key color, with a lit ring when chosen (the header's swatches).
local function Swatch(parent, size, r, g, b, tip, onClick)
	local swatch = CreateFrame('Button', nil, parent)
	swatch:SetSize(size, size)
	swatch.face = CreateFrame('Frame', nil, swatch)
	swatch.face:SetAllPoints()
	local info = Kit.skin['key-round']
	swatch.cap = swatch.face:CreateTexture(nil, 'ARTWORK')
	swatch.cap:SetTexture(Kit.media..[[Skin\key-round.tga]])
	local k = size / info.w
	Kit:Place(swatch.cap, swatch.face, info.l * k, info.t * k, info.r * k, info.b * k)
	swatch.cap:SetVertexColor(r, g, b)
	swatch.ring = Kit:Texture(swatch, 'circle-ring', 'BACKGROUND')
	swatch.ring:SetPoint('TOPLEFT', -3, 3)
	swatch.ring:SetPoint('BOTTOMRIGHT', 3, -3)
	Kit:Tint(swatch.ring, 'lamp')
	swatch:SetScript('OnMouseDown', function(self)
		self.face:ClearAllPoints()
		self.face:SetPoint('TOPLEFT', 0, -1)
		self.face:SetPoint('BOTTOMRIGHT', 0, -1)
		Kit:Play('down')
	end)
	swatch:SetScript('OnMouseUp', function(self)
		self.face:ClearAllPoints()
		self.face:SetAllPoints()
		Kit:Play('up')
	end)
	swatch:SetScript('OnEnter', function(self) self.cap:SetAlpha(0.85) end)
	swatch:SetScript('OnLeave', function(self) self.cap:SetAlpha(1) end)
	swatch:SetScript('OnClick', onClick)
	Kit:AttachTooltip(swatch, tip)
	return swatch
end

-- A layout preview: the preset as the solver places it on this screen, one
-- glass block per frame on a black display (unit frames lit in the key color).
local function LayoutTile(parent, preset, width)
	local screenWidth, screenHeight = UIParent:GetSize()
	local mapHeight = floor((width - 6) * screenHeight / max(screenWidth, 1) + 0.5) + 6
	local tile = CreateFrame('Button', nil, parent)
	tile:SetSize(width, mapHeight + 22)
	tile.preset = preset
	tile.map = Kit:Screen(tile, {inset = 3, radius = 5})
	tile.map:SetPoint('TOPLEFT', 0, 0)
	tile.map:SetSize(width, mapHeight)
	local glass = tile.map.screen
	local ok, rects = pcall(UI.LayoutPresetMap, UI, preset.key)
	local w, h = width - 6, mapHeight - 6
	for _, rect in ipairs(ok and type(rects) == 'table' and rects or {}) do
		local block = glass:CreateTexture(nil, 'ARTWORK')
		block:SetColorTexture(1, 1, 1, 1)
		block:SetPoint('BOTTOMLEFT', glass, 'BOTTOMLEFT', floor(rect.x * w + 0.5), floor(rect.y * h + 0.5))
		block:SetSize(max(1, floor(rect.w * w + 0.5)), max(1, floor(rect.h * h + 0.5)))
		local key = tostring(rect.key)
		if key:find('^uf%.') then Kit:Tint(block, 'lamp', 0.75)
		elseif key:find('^ab%.') then Kit:Tint(block, 'screenText', 0.45)
		else Kit:Tint(block, 'screenText', 0.22) end
	end
	tile.lamp = Kit:Led(tile, 5, false)
	tile.lamp:SetPoint('TOPLEFT', tile.map, 'BOTTOMLEFT', 2, -9)
	tile.model = Kit:Label(tile, preset.model or '', 'ink', 8, true)
	tile.model:SetPoint('LEFT', tile.lamp, 'RIGHT', 5, 0)
	tile.title = Kit:Label(tile, preset.title or preset.key, 'dim', 8)
	tile.title:SetPoint('LEFT', tile.model, 'RIGHT', 5, 0)
	tile.state = Kit:Label(tile, '', 'dim', 7, true)
	tile.state:SetPoint('RIGHT', tile.map, 'BOTTOMRIGHT', -2, -9)
	tile.highlight = tile:CreateTexture(nil, 'OVERLAY')
	tile.highlight:SetAllPoints(tile.map)
	tile.highlight:SetColorTexture(1, 1, 1, 1)
	Kit:Tint(tile.highlight, 'lamp', 0.12)
	tile.highlight:Hide()
	tile:SetScript('OnEnter', function(self) self.highlight:Show(); Kit:Play('tick') end)
	tile:SetScript('OnLeave', function(self) self.highlight:Hide() end)
	tile:SetScript('OnClick', function(self)
		if InCombatLockdown() then
			Kit:Play('error')
			return UI:Print('Layouts can be applied once you leave combat.')
		end
		Kit:Play('down')
		local title = self.preset.title or self.preset.key
		Kit:AlertDialog({title = 'Use the '..title..' layout', confirm = 'Apply',
			text = 'Every frame moves to the '..title..' arrangement. Undo in edit mode (Ctrl+Z) brings your current positions back.',
			onConfirm = function()
				UI:ApplyLayoutPreset(self.preset.key)
				if QS.refresh then QS.refresh() end
			end})
	end)
	return tile
end

-- The page -------------------------------------------------------------------------------
local function Change(path, value, label, extra)
	local opts = extra or {}
	opts.label = label
	UI:HubChange(path, value, opts)
end

local function BuildLayout(device, width)
	local presets = UI.LayoutPresets and UI:LayoutPresets() or {}
	QS.tiles = {}
	if #presets == 0 then
		device.note:SetText('The Layout module is not loaded.')
		return
	end
	local gap = 12
	local columns = min(#presets, 2)
	local tileWidth = floor((width - gap * (columns - 1)) / columns)
	for index, preset in ipairs(presets) do
		if index > columns then break end
		local tile = LayoutTile(device.body, preset, tileWidth)
		tile:SetPoint('TOPLEFT', (index - 1) * (tileWidth + gap), 0)
		QS.tiles[index] = tile
	end
end

local function BuildColors(device, width)
	QS.swatches = {}
	local names = {}
	for _, name in ipairs(Kit.accentOrder) do names[#names + 1] = name end
	names[#names + 1] = 'class'
	local size, gap = 20, 6
	local per = min(#names, floor((width + gap) / (size + gap)))
	for index, name in ipairs(names) do
		local r, g, b
		if name == 'class' then r, g, b = ClassColor()
		else
			local color = Kit.accentSkin[name] and Kit.accentSkin[name].key or {Kit.accents[name][1], Kit.accents[name][2], Kit.accents[name][3]}
			r, g, b = color[1], color[2], color[3]
		end
		local tip = name == 'class' and 'Class color' or (Kit.accents[name] and Kit.accents[name].name or name)
		local swatch = Swatch(device.body, size, r, g, b, tip, function()
			if UI.db.accent ~= name then Change('accent', name, 'Key color', {items = UI.AccentItems}) end
		end)
		local column, row = (index - 1) % per, floor((index - 1) / per)
		swatch:SetPoint('TOPLEFT', 4 + column * (size + gap), -4 - row * (size + gap + 4))
		swatch.name = name
		QS.swatches[#QS.swatches + 1] = swatch
	end
end

local function BuildFont(device, width)
	QS.font = Stepper(device.body, width, function() return Kit:FontChoices() end, function() return UI.db.font end,
		function(value) Change('font', value, 'Typeface', {items = Kit:FontChoices()}) end)
	QS.font:SetPoint('TOPLEFT', 0, 0)
	-- A sample in the typeface in use: it changes with the choice.
	QS.fontSample = Kit:Text(device.body, 'SPEC-01 / 0123456789', 10, 'ink')
	QS.fontSample:SetPoint('TOPLEFT', QS.font, 'BOTTOMLEFT', 0, -10)
	QS.fontSample:SetWidth(width)
	QS.fontSample:SetJustifyH('LEFT')
	QS.fontSample:SetWordWrap(false)
end

local function BuildScale(device, width)
	QS.scale = KeyRow(device.body, ScaleItems(), width, 28, function(value)
		if InCombatLockdown() then UI:Print('The UI scale changes once you leave combat.') end
		Change('uiScale', value, 'UI scale', {format = function(v) return format('%.2f', v) end})
	end)
	QS.scale:SetPoint('TOPLEFT', 0, 0)
	local more = Kit:Key(device.body, {text = 'Fine scale', width = 92, height = 22, textSize = 7})
	more:SetPoint('TOPLEFT', QS.scale, 'BOTTOMLEFT', 0, -8)
	more.onClick = function() UI:ToggleHub('theme', true) end
end

local function BuildFade(device, width)
	local label = Kit:Label(device.body, 'Fade', 'ink', 8)
	label:SetPoint('TOPLEFT', 0, -6)
	QS.fadeSwitch = Kit:Switch(device.body, {labels = false, checked = Read('appearance.fade.enable') and true or false,
		onChange = function(value, self) Change('appearance.fade.enable', value, 'Fade', {control = self}) end})
	QS.fadeSwitch:SetPoint('TOPRIGHT', -2, 0)
	QS.fadeStyle = Stepper(device.body, width, FadeStyles, function() return Read('appearance.fade.style') end,
		function(value) Change('appearance.fade.style', value, 'Fade style', {items = FadeStyles()}) end)
	QS.fadeStyle:SetPoint('TOPLEFT', 0, -32)
	local preview = Kit:Key(device.body, {text = 'Preview', width = 76, height = 22, textSize = 7})
	preview:SetPoint('TOPLEFT', QS.fadeStyle, 'BOTTOMLEFT', 0, -6)
	preview.onClick = function()
		local fade = UI.modules.fade
		if fade and fade.Preview then UI:Safe(fade.Preview, fade) else Kit:Play('error') end
	end
	local more = Kit:Key(device.body, {text = 'Parts', width = 60, height = 22, textSize = 7})
	more:SetPoint('LEFT', preview, 'RIGHT', 4, 0)
	more.onClick = function() UI:ToggleHub('fade', true) end
end

local function BuildSound(device)
	local label = Kit:Label(device.body, 'Sounds', 'ink', 8)
	label:SetPoint('TOPLEFT', 0, -6)
	QS.soundSwitch = Kit:Switch(device.body, {labels = false, checked = Read('sound.enable') and true or false,
		onChange = function(value, self) Change('sound.enable', value, 'Sounds', {control = self}) end})
	QS.soundSwitch:SetPoint('TOPLEFT', 0, -22)
	local more = Kit:Key(device.body, {text = 'More', width = 52, height = 22, textSize = 7})
	more:SetPoint('TOPLEFT', QS.soundSwitch, 'BOTTOMLEFT', 0, -10)
	more.onClick = function() UI:ToggleHub('sounds', true) end
	-- The game's master volume (a game setting, so not part of Undo).
	QS.volume = Kit:Knob(device.body, {size = 40, min = 0, max = 100, step = 5, sweep = 270, label = 'Master',
		value = MasterVolume(), format = function(v) return format('%d%%', v) end,
		onChange = function(value) pcall(SetCVar, 'Sound_MasterVolume', format('%.2f', value / 100)) end})
	QS.volume:SetPoint('TOPRIGHT', 0, 8)
end

local function BuildShortcuts(device, width)
	local keys = {
		{'Installer', 'Run the installer again', function() UI:ToggleHub(nil, false); if UI.OpenSetup then UI:OpenSetup(1) end end},
		{'Edit mode', 'Move and arrange every frame', function()
			if InCombatLockdown() then
				Kit:Play('error')
				return UI:Print('Frames can be moved once you leave combat.')
			end
			UI:ToggleHub(nil, false)
			if UI.EditMode then UI:EditMode(true) elseif UI.ToggleMovers then UI:ToggleMovers(false) end
		end},
		{'Styles', 'The SPEC-01 style for each part, or Blizzard\'s', function() UI:ToggleHub('overview', true) end},
		{'Profiles', 'Save, copy, share and import setups', function() UI:ToggleHub('profiles', true) end},
		{'What\'s new', 'What changed in this version', function() UI:ToggleHub('whatsnew', true) end},
		{'Commands', 'Every /spec command', function() UI:ToggleHub('commands', true) end},
	}
	local gap = 6
	local keyWidth = floor((width - gap * (#keys - 1)) / #keys)
	for index, entry in ipairs(keys) do
		local key = Kit:Key(device.body, {text = entry[1], width = keyWidth, height = 28, textSize = 8,
			tone = index == 1 and 'primary' or nil})
		key:SetPoint('TOPLEFT', (index - 1) * (keyWidth + gap), 0)
		key.onClick = entry[3]
		Kit:AttachTooltip(key, entry[2])
	end
end

-- Paint every device from the settings as they are now (also after Undo, or a
-- change made from the header or another page).
local function Refresh()
	if not QS.devices then return end
	local db = UI.db
	local changing = UI.changing
	-- Layout
	local preset = db.layout and db.layout.preset
	local inUse
	for _, tile in ipairs(QS.tiles or {}) do
		local on = tile.preset.key == preset
		Kit:SetLed(tile.lamp, on)
		tile.state:SetText(on and 'IN USE' or 'APPLY')
		Kit:Tint(tile.state, on and 'ink' or 'dim')
		if on then inUse = tile.preset end
	end
	QS.layout:SetReadout(inUse and (inUse.model or inUse.title) or (type(preset) == 'string' and preset:gsub('^custom:', '') or 'Custom'))
	-- Finish
	if changing ~= QS.finish then QS.finish:SetValue(db.finish) end
	QS.finishDevice:SetReadout(Name(FINISHES, db.finish, 'Paper'))
	-- Key color
	for _, swatch in ipairs(QS.swatches or {}) do swatch.ring:SetShown(db.accent == swatch.name) end
	QS.colorDevice:SetReadout(Name(UI.AccentItems(), db.accent, 'Custom'))
	-- Typeface
	local fontName = Name(Kit:FontChoices(), db.font, tostring(db.font or ''))
	QS.font:SetValue(fontName)
	QS.fontDevice:SetReadout(fontName)
	-- UI scale
	local scale = CurrentScale()
	QS.scale:SetItems(ScaleItems())
	local lit
	for _, item in ipairs(ScaleItems()) do
		if math.abs(item[1] - scale) < 0.005 and lit == nil then lit = item[1] end
	end
	QS.scale:SetValue(lit)
	QS.scaleDevice:SetReadout(format('%.2f', scale))
	-- Fade
	local fadeOn = Read('appearance.fade.enable') and true or false
	if changing ~= QS.fadeSwitch then QS.fadeSwitch:SetValue(fadeOn) end
	local styleName = Name(FadeStyles(), Read('appearance.fade.style'), 'Smooth')
	QS.fadeStyle:SetValue(styleName)
	QS.fadeDevice:SetReadout(fadeOn and styleName or 'Off')
	-- Sounds
	local soundOn = Read('sound.enable') and true or false
	if changing ~= QS.soundSwitch then QS.soundSwitch:SetValue(soundOn) end
	QS.volume:SetValue(MasterVolume())
	QS.soundDevice:SetReadout(soundOn and format('On  %d%%', MasterVolume()) or 'Off')
	-- Motion
	if changing ~= QS.motion then QS.motion:SetValue(db.reduceMotion and true or false) end
	QS.motionDevice:SetReadout(db.reduceMotion and 'Reduced' or 'Full')
end
QS.refresh = Refresh

local function Build(content, page)
	QS.devices = {}
	page.controls = {}
	local COLUMN, GAP, x0 = Kit.COLUMN, Kit.GAP, Kit.PAD / 2
	local wide = 2 * COLUMN + GAP
	local function X(column) return x0 + column * (COLUMN + GAP) end
	local inner = COLUMN - 24
	local intro = Kit:Text(content, 'The choices that shape the whole interface. Each applies as you pick it; Undo (Ctrl+Z) takes it back, and anything that needs a reload lights the lamp in the header. Every other setting is in the sidebar, or a search away.', 9, 'dim')
	intro:SetPoint('TOPLEFT', x0 + 2, -10)
	intro:SetWidth(4 * COLUMN + 3 * GAP - 4)
	intro:SetJustifyH('LEFT')
	local y = 10 + max(intro:GetStringHeight(), 12) + 12

	-- Row 1: layout (two columns), finish, key color.
	local screenWidth, screenHeight = UIParent:GetSize()
	local tileWidth = floor((wide - 24 - 12) / 2)
	local rowOne = 30 + floor((tileWidth - 6) * screenHeight / max(screenWidth, 1) + 0.5) + 6 + 22 + 44
	QS.layout = Device(content, 'QS-1', 'Layout', wide, rowOne,
		'Where everything sits. Jiberish main is a compact console with the unit frames over it; Integrated console docks them inside. Asks first.')
	QS.layout:SetPoint('TOPLEFT', X(0), -y)
	BuildLayout(QS.layout, wide - 24)
	QS.finishDevice = Device(content, 'QS-2', 'Finish', COLUMN, rowOne,
		'Paper is the reference: off-white housings and warm hairlines. Graphite darkens the same art.')
	QS.finishDevice:SetPoint('TOPLEFT', X(2), -y)
	QS.finish = KeyRow(QS.finishDevice.body, FINISHES, inner, 32, function(value)
		if UI.db.finish ~= value then Change('finish', value, 'Finish', {items = FINISHES, control = QS.finish}) end
		QS.finish:SetValue(value)
	end)
	QS.finish:SetPoint('TOPLEFT', 0, 0)
	local housing = Kit:Key(QS.finishDevice.body, {text = 'Housings', width = 84, height = 22, textSize = 7})
	housing:SetPoint('TOPLEFT', QS.finish, 'BOTTOMLEFT', 0, -10)
	housing.onClick = function() UI:ToggleHub('housing', true) end
	QS.colorDevice = Device(content, 'QS-3', 'Key color', COLUMN, rowOne,
		'Primary keys, lamps and lit dots. Class paints each unit frame in its own class.')
	QS.colorDevice:SetPoint('TOPLEFT', X(3), -y)
	BuildColors(QS.colorDevice, inner)
	local colors = Kit:Key(QS.colorDevice.body, {text = 'Custom colors', width = 104, height = 22, textSize = 7})
	colors:SetPoint('TOPLEFT', 0, -38)
	colors.onClick = function() UI:ToggleHub('colors', true) end
	y = y + rowOne + GAP

	-- Row 2: typeface, UI scale, fade, sounds.
	local rowTwo = 30 + 96 + 34
	QS.fontDevice = Device(content, 'QS-4', 'Typeface', COLUMN, rowTwo,
		'Every SPEC-01 label and readout. IBM Plex Mono is the reference; Audiowide ships too.')
	QS.fontDevice:SetPoint('TOPLEFT', X(0), -y)
	BuildFont(QS.fontDevice, inner)
	QS.scaleDevice = Device(content, 'QS-5', 'UI scale', COLUMN, rowTwo,
		'Pixel is one unit per screen pixel, the sharpest edges. Jiberish plays at 0.64.')
	QS.scaleDevice:SetPoint('TOPLEFT', X(1), -y)
	BuildScale(QS.scaleDevice, inner)
	QS.fadeDevice = Device(content, 'QS-6', 'Fade', COLUMN, rowTwo,
		'Parts rest faded out of combat and wake as a fight starts, in this style.')
	QS.fadeDevice:SetPoint('TOPLEFT', X(2), -y)
	BuildFade(QS.fadeDevice, inner)
	QS.soundDevice = Device(content, 'QS-7', 'Sounds', COLUMN, rowTwo,
		'SPEC-01 key, switch and screen sounds. The knob is the game\'s master volume.')
	QS.soundDevice:SetPoint('TOPLEFT', X(3), -y)
	BuildSound(QS.soundDevice)
	y = y + rowTwo + GAP

	-- Row 3: motion, and the way to everything else.
	local rowThree = 30 + 40 + 34
	QS.motionDevice = Device(content, 'QS-8', 'Motion', COLUMN, rowThree,
		'Reduced: controls snap to place and screens skip their flicker.')
	QS.motionDevice:SetPoint('TOPLEFT', X(0), -y)
	QS.motion = KeyRow(QS.motionDevice.body, MOTION, inner, 28, function(value)
		if (UI.db.reduceMotion and true or false) ~= value then
			Change('reduceMotion', value, 'Motion', {items = MOTION, control = QS.motion})
		end
		QS.motion:SetValue(value)
	end)
	QS.motion:SetPoint('TOPLEFT', 0, 0)
	local rest = Device(content, 'QS-9', 'Everything else', 3 * COLUMN + 2 * GAP, rowThree,
		'Every other setting has a page in the sidebar; Search finds any of them, and Advanced shows every option on a page.')
	rest:SetPoint('TOPLEFT', X(1), -y)
	rest:SetReadout('Sidebar')
	BuildShortcuts(rest, 3 * COLUMN + 2 * GAP - 24)
	y = y + rowThree + 24

	-- The hub deals the devices in like cards.
	page.cardFrames = QS.devices
	Refresh()
	return y
end

UI:RegisterPage('quick', {title = 'Quick setup', order = 0.5, span = 4, since = '0.6.0', code = 'QS',
	build = Build,
	refresh = function() if QS.devices then UI:Safe(Refresh) end end,
	onShow = function() if QS.devices then UI:Safe(Refresh) end end,
	search = {
		{'Layout', 'Jiberish main or Integrated console, with a preview of each.'},
		{'Finish', 'Paper or Graphite housings.'},
		{'Key color', 'The key color, including Class.'},
		{'Typeface', 'IBM Plex Mono, Audiowide or any installed font.'},
		{'UI scale', 'Pixel-perfect or a preset scale.'},
		{'Fade', 'Fade parts out of combat, and the style they fade in.'},
		{'Sounds and volume', 'SPEC-01 sounds on or off; the game\'s master volume.'},
		{'Motion', 'Full or reduced motion.'},
	}})
