-- The hub: one SPEC-01 window for everything, like ElvUI's options. A sidebar
-- of sections; each section is a grid of numbered cards built from simple row
-- descriptions that modules register with UI:RegisterPage.
--
--   /spec            open the hub (last page)
--   /spec <page>     open a page: overview, theme, unitframes, actionbars, ...
-- The sidebar's search field looks through every page's settings.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent = CreateFrame, UIParent
local floor, max, min = math.floor, math.max, math.min

local hub
local pages, pageOrder = {}, {}

-- defaults:begin
UI:RegisterDefaults('hub', {page = 'overview', advanced = false, describe = false, seen = {}, collapsed = {},
	expanded = {}, group = false})
-- defaults:end
local SIDEBAR, CONTENT_COLUMNS = 156, 4

-- page: {title, order, build(content) -> height} or {title, order, cards = {{title, rows}}}
--       since = '0.5.0' marks it NEW; search = {{label, note}} indexes a page that builds itself.
-- rows: {'switch', label, path, note} | {'slider', label, path, min, max, step, note, format = fn}
--       {'segmented', label, path, items = {{value, text}}, note = } | {'button', label, text, func, note}
--       {'color', label, path, note}              value {r, g, b} or {r =, g =, b =}
--       {'dropdown', label, path, items = {{value, text}} or function() return items end, note = }
--       {'input', label, path, note}              text, saved on Enter or when the field lets go
--       {'note', text} | {'header', text}         a paragraph, or a small printed divider
-- Every row may also carry:
--   reload = true      the change applies after a reload
--   since = '0.5.0'    a NEW marker while that is the addon's version
--   hidden = fn        the row is left out while fn() is true (the page rebuilds when that changes)
--   disabled = fn      the row is dimmed and locked while fn() is true
--   get = fn, set = fn read and write the value through these instead of the path
local function SortPages()
	table.sort(pageOrder, function(a, b)
		local oa, ob = pages[a].order or 50, pages[b].order or 50
		if oa ~= ob then return oa < ob end
		return a < b
	end)
end

-- Registering a key again replaces that page in place.
function UI:RegisterPage(key, page)
	page.key = key
	if not pages[key] then pageOrder[#pageOrder + 1] = key end
	pages[key] = page
	SortPages()
	if hub then hub.navDirty = true end
	return page
end

function UI:GetPage(key) return pages[key] end

-- NEW markers: rows and pages added in the version the player is running.
local VERSION
do
	local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
	local ok, version = pcall(get, UI.name, 'Version')
	VERSION = ok and type(version) == 'string' and version or nil
end
UI.version = VERSION
function UI:IsNew(since) return since ~= nil and VERSION ~= nil and since == VERSION end

local function Test(func)
	if type(func) ~= 'function' then return false end
	local ok, value = pcall(func)
	return ok and value and true or false
end

local function PageIsNew(page)
	if UI:IsNew(page.since) then return true end
	for _, card in ipairs(page.cards or {}) do
		for _, row in ipairs(card.rows or {}) do
			if UI:IsNew(row.since) and not Test(row.hidden) then return true end
		end
	end
	return false
end

local function Read(path)
	local node = UI.db
	for key in path:gmatch('[^.]+') do
		if type(node) ~= 'table' then return nil end
		node = node[key]
	end
	return node
end
UI.ReadOption = Read

function UI:NeedsReload()
	self.reloadPending = true
	if hub then
		hub.reload:Show()
		hub.reload:SetTone('primary')
		-- A lamp on the key blinks until the reload.
		if hub.reload.led then
			Kit:SetLed(hub.reload.led, true, 'amber')
			if Kit:Faithful('breathe') then Kit:Blink(hub.reload.led, 0.8, true) end
		end
	end
end

-- Rows -----------------------------------------------------------------------
-- Each row is a label column on the left and a control column on the right.
-- Labels are one line; a row's long description lives behind an info mark
-- (hover the label or the mark), unless "Descriptions" is on in the header,
-- which adds one dim, truncated line under the label. A control too wide to
-- share the line (a long segmented picker) drops under its label instead.
-- Every height is measured after widths are set, so nothing can overlap.
local ROW_HEIGHT = {switch = 30, segmented = 34, slider = 54, button = 34, color = 30, dropdown = 34, input = 36, note = 0, header = 24}
local NOTE_INDEX = {switch = 4, slider = 7, button = 5, color = 4, input = 4}
local CARD_ROWS = 6 -- settings shown per card before "More options" (Advanced shows all)

local function HubDB() return UI.db.hub end
local function Advanced() return HubDB().advanced and true or false end

local function NoteOf(row)
	local index = NOTE_INDEX[row[1]]
	return (index and type(row[index]) == 'string' and row[index]) or row.note
end

local function Get(row)
	if row.get then
		local ok, value = pcall(row.get)
		return ok and value or nil
	end
	return Read(row[3])
end

local function Items(row)
	if type(row.items) == 'function' then
		local ok, items = pcall(row.items)
		return ok and type(items) == 'table' and items or {}
	end
	return row.items or {}
end

-- The control that made a change keeps animating; only the others refresh.
local changedPaths, UpdateLCD = {}, nil
local function Changed(row, value, control)
	changedPaths[row[3] or row] = true
	if UpdateLCD then UpdateLCD() end
	UI.changing = control
	if row.set then
		UI:Safe(row.set, value)
		Kit:Apply()
	else
		Kit:SetOption(row[3], value)
	end
	UI.changing = nil
	if row.reload then UI:NeedsReload() end
end

-- A dimmed, locked row: its control is covered by a frame that takes the mouse.
local function Lockable(control, label, row)
	if not row.disabled then return end
	local cover = CreateFrame('Frame', nil, control)
	cover:SetAllPoints()
	cover:SetFrameLevel(control:GetFrameLevel() + 20)
	cover:EnableMouse(true)
	cover:Hide()
	local refresh = control.refresh
	control.refresh = function()
		if refresh then refresh() end
		local off = Test(row.disabled)
		cover:SetShown(off)
		control:SetAlpha(off and 0.4 or 1)
		label:SetAlpha(off and 0.5 or 1)
	end
end

-- A wrapped note card for the hub's hovers (the kit's tooltip is one line).
local noteTip
local function ShowNote(anchor, title, text)
	if not text or text == '' then return end
	if not noteTip then
		noteTip = Kit:Panel(Kit:Root(), {radius = 4, fill = 'glass', border = false, shadow = 0.5})
		noteTip:SetFrameStrata('TOOLTIP')
		noteTip.title = Kit:Label(noteTip, '', 'darkInk', 8, true)
		noteTip.title:SetPoint('TOPLEFT', 10, -9)
		noteTip.text = Kit:Text(noteTip, '', 9, 'darkInk')
		noteTip.text:SetJustifyH('LEFT')
		noteTip.text:SetSpacing(2)
	end
	local width = 260
	noteTip.title:SetText(title and strupper(title) or '')
	noteTip.text:SetWidth(width - 20)
	noteTip.text:SetText(text)
	noteTip.text:ClearAllPoints()
	if title and title ~= '' then
		noteTip.text:SetPoint('TOPLEFT', noteTip.title, 'BOTTOMLEFT', 0, -5)
	else
		noteTip.text:SetPoint('TOPLEFT', 10, -9)
	end
	local height = noteTip.text:GetStringHeight() + 20 + ((title and title ~= '') and 14 or 0)
	noteTip:SetSize(width, height)
	noteTip:ClearAllPoints()
	noteTip:SetPoint('BOTTOMLEFT', anchor, 'TOPLEFT', 0, 6)
	noteTip:Show()
	Kit:Animate(noteTip, 0.1, 0, 1, function(alpha) noteTip:SetAlpha(alpha) end)
end
local function HideNote() if noteTip then noteTip:Hide() end end

-- A frame over some text that shows the full note on hover.
local function Hover(parent, title, text)
	local hit = CreateFrame('Frame', nil, parent)
	hit:EnableMouse(true)
	hit:SetScript('OnEnter', function(self) ShowNote(self, title, text) end)
	hit:SetScript('OnLeave', HideNote)
	return hit
end

-- The first line of a paragraph.
local function FirstLine(text)
	return (text:match('^([^\n]*)') or text):gsub('%s+$', '')
end

local function Note(card, row, y, width, full)
	local text = row[2] or ''
	local note = Kit:Text(card.body, '', 9, 'dim')
	note:SetPoint('TOPLEFT', 0, -y)
	note:SetWidth(width)
	note:SetJustifyH('LEFT')
	if full then
		note:SetText(text)
		note:SetWordWrap(true)
		return max(note:GetStringHeight(), 10) + 10
	end
	-- One dim line; the rest on hover.
	local line = FirstLine(text)
	note:SetWordWrap(false)
	note:SetText(line)
	if line ~= text or note:GetStringWidth() > width + 1 then
		local hit = Hover(card.body, card.title and card.title:GetText(), text)
		hit:SetAllPoints(note)
		local more = Kit:Icon(card.body, 'more', 9, 'dim')
		more:SetPoint('LEFT', note, 'LEFT', min(note:GetStringWidth(), width) + 4, 0)
		note:SetWidth(width - 14)
	end
	return 18
end

local function Header(card, row, y)
	local text = Kit:Label(card.body, row[2], 'dim', 8, true)
	text:SetPoint('TOPLEFT', 0, -y - 6)
	local rule = Kit:Solid(card.body, 'line')
	rule:SetHeight(1)
	rule:SetPoint('LEFT', text, 'RIGHT', 8, 0)
	rule:SetPoint('RIGHT', card.body, 'RIGHT', 0, 0)
	return ROW_HEIGHT.header
end

-- New in this version, and the page not opened since: a small key-color lamp.
local function ShowsNew(page, row)
	return UI:IsNew(row.since) and not (HubDB().seen or {})[page.key]
end

-- Dropdowns open as a SPEC-01 drawer: a sheet that unrolls under the control
-- with a grab line, printed rows with a lamp on the chosen one, a tick as the
-- pointer moves through them and a latch on choosing; a click anywhere else
-- rolls it back up.
local DRAWER_ROW, DRAWER_MAX = 20, 12
local drawer
local function CloseDrawer(instant)
	if not drawer or not drawer:IsShown() or drawer.closing then return end
	drawer.catcher:Hide()
	if instant or not Kit:Faithful('slide') then drawer:Hide() return end
	drawer.closing = true
	local from = drawer:GetHeight()
	Kit:Animate(drawer, 0.14, from, 1, function(height) drawer:SetHeight(max(height, 1)) end, function()
		drawer.closing = nil
		drawer:Hide()
	end, 'cubic')
end

local function DrawerRow(parent)
	local item = CreateFrame('Button', nil, parent)
	item:SetHeight(DRAWER_ROW)
	item.highlight = item:CreateTexture(nil, 'BACKGROUND')
	item.highlight:SetAllPoints()
	item.highlight:SetColorTexture(1, 1, 1, 1)
	Kit:Tint(item.highlight, 'lamp', 0.18)
	item.highlight:Hide()
	item.lamp = Kit:Led(item, 5, false)
	item.lamp:SetPoint('LEFT', 8, 0)
	item.label = Kit:Label(item, '', 'ink', 9)
	item.label:SetPoint('LEFT', 20, 0)
	item.label:SetPoint('RIGHT', -8, 0)
	item.label:SetJustifyH('LEFT')
	item.label:SetWordWrap(false)
	item:SetScript('OnEnter', function(self)
		self.highlight:Show()
		Kit:Play('tick')
	end)
	item:SetScript('OnLeave', function(self) self.highlight:Hide() end)
	item:SetScript('OnClick', function(self)
		local owner, value = drawer.owner, self.value
		Kit:Play('latch-down')
		Kit:Chosen(self, self.highlight, self.label, function()
			CloseDrawer()
			if owner and owner.choose then owner.choose(value) end
		end, 'ink', 'ink')
	end)
	return item
end

local function OpenDrawer(control, items, current)
	if drawer and drawer:IsShown() and drawer.owner == control then return CloseDrawer() end
	if not drawer then
		drawer = Kit:Panel(hub, {radius = 6, fill = 'panel', border = 'hair', shadow = 0.5})
		drawer:SetClipsChildren(true)
		drawer:EnableMouse(true)
		drawer.grab = Kit:Solid(drawer, 'hair')
		drawer.grab:SetSize(28, 2)
		drawer.grab:SetPoint('TOP', 0, -5)
		drawer.list = Kit:ScrollArea(drawer, {width = 200, height = 100, step = DRAWER_ROW * 3, smooth = true})
		drawer.list:SetPoint('TOPLEFT', 2, -10)
		drawer.list:SetPoint('BOTTOMRIGHT', -2, 4)
		drawer.rows = {}
		-- Clicks outside the sheet roll it back up.
		drawer.catcher = CreateFrame('Button', nil, hub)
		drawer.catcher:SetAllPoints(hub)
		drawer.catcher:SetScript('OnClick', function() CloseDrawer() end)
		drawer.catcher:Hide()
		hub:HookScript('OnHide', function() CloseDrawer(true) end)
	end
	drawer.owner = control
	local width = max(control:GetWidth(), 170)
	local shown = min(#items, DRAWER_MAX)
	local full = 14 + max(shown, 1) * DRAWER_ROW + 6
	drawer:SetWidth(width)
	drawer.list:SetWidth(width - 4)
	drawer.list.content:SetWidth(width - 12)
	for index, item in ipairs(items) do
		local entry = drawer.rows[index]
		if not entry then entry = DrawerRow(drawer.list.content); drawer.rows[index] = entry end
		local value, text = item, tostring(item)
		if type(item) == 'table' then value, text = item[1], item[2] or tostring(item[1]) end
		entry.value = value
		entry:ClearAllPoints()
		entry:SetPoint('TOPLEFT', 0, -(index - 1) * DRAWER_ROW)
		entry:SetPoint('TOPRIGHT', 0, -(index - 1) * DRAWER_ROW)
		entry.label:SetText(strupper(text))
		Kit:SetLed(entry.lamp, value == current)
		Kit:Tint(entry.label, value == current and 'ink' or 'dim')
		entry.highlight:Hide()
		entry:Show()
	end
	for index = #items + 1, #drawer.rows do drawer.rows[index]:Hide() end
	drawer.list.content:SetHeight(max(#items, 1) * DRAWER_ROW)
	-- Below the control, or above it when there is no room under it.
	drawer:ClearAllPoints()
	local bottom = control:GetBottom() or 0
	local hubBottom = hub:GetBottom() or 0
	if bottom - full < hubBottom + 12 then
		drawer:SetPoint('BOTTOMRIGHT', control, 'TOPRIGHT', 0, 4)
	else
		drawer:SetPoint('TOPRIGHT', control, 'BOTTOMRIGHT', 0, -4)
	end
	drawer:SetFrameLevel(control:GetFrameLevel() + 30)
	drawer.catcher:SetFrameLevel(drawer:GetFrameLevel() - 1)
	drawer.catcher:Show()
	drawer.closing = nil
	drawer:Show()
	-- Scroll the chosen one into view.
	for index, item in ipairs(items) do
		local value = type(item) == 'table' and item[1] or item
		if value == current then drawer.list:ScrollTo(max(0, (index - DRAWER_MAX) * DRAWER_ROW), true) end
	end
	Kit:Play('open')
	if Kit:Faithful('slide') then
		Kit:Animate(drawer, 0.18, 1, full, function(height) drawer:SetHeight(max(height, 1)) end, nil, 'detent')
	else
		drawer:SetHeight(full)
	end
	drawer.list:Refresh()
end

local function Control(card, row, width)
	local kind = row[1]
	local control
	if kind == 'switch' then
		control = Kit:Switch(card.body, {labels = false, checked = Get(row) and true or false,
			onChange = function(value, self) Changed(row, value, self) end})
		control.refresh = function() control:SetValue(Get(row) and true or false) end
	elseif kind == 'segmented' then
		local values, names, current = {}, {}, 1
		for index, item in ipairs(row.items) do
			values[index], names[index] = item[1], item[2]
			if item[1] == Get(row) then current = index end
		end
		local longest = 0
		for _, name in ipairs(names) do longest = max(longest, #tostring(name)) end
		-- On the label's line when it fits in about 60% of the card (squeezed a
		-- little if need be), else on a line of its own under the label.
		local wanted, inline = max(longest * 7 + 22, 52) * #names, floor(width * 0.6)
		local segWidth = wanted <= inline * 1.2 and min(wanted, inline) or min(wanted, width)
		control = Kit:Segmented(card.body, {items = names, width = segWidth, value = current,
			onChange = function(index, self) Changed(row, values[index], self) end})
		control.refresh = function()
			local value = Get(row)
			for index, item in ipairs(values) do
				if item == value then control:SetValue(index) end
			end
		end
	elseif kind == 'slider' then
		control = Kit:Slider(card.body, {label = '', min = row[4], max = row[5], step = row[6], value = Get(row),
			width = floor(width * 0.48), ticks = 10, format = row.format,
			onChange = function(value, self) Changed(row, value, self) end})
		control.refresh = function() control:SetValue(Get(row)) end
		control.lift = 12 -- its own (empty) label line sits above the track
		-- The value on a small LCD left of the track, not over it.
		local lcd = Kit:LCDPanel(card.body, {radius = 3})
		lcd:SetSize(48, 18)
		lcd:SetPoint('RIGHT', control, 'TOPLEFT', -6, -31)
		control.readout:ClearAllPoints()
		control.readout:SetPoint('CENTER', lcd, 'CENTER', 0, 0)
		control.readout:SetParent(lcd)
		Kit:Font(control.readout, 9, nil, true, 'numbers')
		Kit:Tint(control.readout, 'lcdInk')
		control.extra = 54
	elseif kind == 'button' then
		control = Kit:Button(card.body, {text = row[3], width = max(80, #row[3] * 8 + 28), height = 26})
		control.onClick = function() UI:Safe(row[4], control) end
	elseif kind == 'color' then
		control = Kit:ColorSwatch(card.body, {value = Get(row), onChange = function(value, self) Changed(row, value, self) end})
		control.refresh = function() control:SetValue(Get(row)) end
	elseif kind == 'dropdown' then
		control = Kit:Dropdown(card.body, {items = Items(row), value = Get(row), width = min(170, floor(width * 0.48)),
			onChange = function(value, self) Changed(row, value, self) end})
		control.refresh = function()
			if type(row.items) == 'function' then control:SetItems(Items(row)) end
			control:SetValue(Get(row))
		end
		control.choose = function(value)
			control:SetValue(value)
			Changed(row, value, control)
		end
		control.onClick = function(self) OpenDrawer(self, Items(row), Get(row)) end
	elseif kind == 'input' then
		control = Kit:TextField(card.body, {width = min(170, floor(width * 0.48)), value = Get(row) or ''})
		local function Commit()
			-- Escape lets go of the field without saving.
			if control.cancelled then control.cancelled = nil return end
			local text = control:GetValue()
			if text ~= (Get(row) or '') then Changed(row, text, control) end
		end
		control.edit:SetScript('OnEnterPressed', function(self)
			self:ClearFocus()
			Kit:Play('down')
		end)
		control.edit:SetScript('OnEscapePressed', function(self)
			control.cancelled = true
			control:SetValue(Get(row) or '')
			self:ClearFocus()
			control.cancelled = nil
		end)
		control.edit:HookScript('OnEditFocusLost', Commit)
		control.refresh = function()
			if not control.edit:HasFocus() then control:SetValue(Get(row) or '') end
		end
	end
	return control
end

local function BuildRow(card, row, y, width, page)
	local kind = row[1]
	if kind == 'note' then return Note(card, row, y, width, card.fullNotes) end
	if kind == 'header' then return Header(card, row, y) end
	local control = Control(card, row, width)
	if not control then
		local label = Kit:Label(card.body, strupper(tostring(row[2] or kind)), 'ink', 9)
		label:SetPoint('TOPLEFT', 0, -y)
		return 20
	end
	local controlWidth = control:GetWidth() + (control.extra or 0)
	local stacked = controlWidth > width * 0.66
	local labelWidth = stacked and width or (width - controlWidth - 14)
	local noteText = NoteOf(row)
	-- The label column: a NEW lamp, the label (one line), the info mark.
	local left = 0
	if ShowsNew(page, row) then
		local lamp = Kit:Led(card.body, 4, true)
		lamp:SetPoint('TOPLEFT', 0, -y - 4)
		left = 9
	end
	local label = Kit:Label(card.body, row[2] or '', 'ink', 9)
	label:SetPoint('TOPLEFT', left, -y)
	label:SetJustifyH('LEFT')
	label:SetWordWrap(false)
	local infoRoom = noteText and 14 or 0
	label:SetWidth(max(labelWidth - left - infoRoom, 20))
	if noteText then
		local textWidth = min(label:GetStringWidth(), label:GetWidth())
		local info = Kit:Icon(card.body, 'info', 9, 'dim')
		info:SetPoint('LEFT', label, 'LEFT', textWidth + 5, 0)
		local hit = Hover(card.body, row[2], noteText)
		hit:SetPoint('TOPLEFT', label, 'TOPLEFT', -2, 2)
		hit:SetPoint('BOTTOMRIGHT', info, 'BOTTOMRIGHT', 2, -2)
	end
	local textHeight = 12
	-- The control column.
	local height
	control:ClearAllPoints()
	if stacked then
		local top = y + textHeight + 4
		control:SetPoint('TOPRIGHT', card.body, 'TOPRIGHT', 0, -top + (control.lift or 0))
		height = textHeight + 4 + ROW_HEIGHT[kind]
	else
		local nudge = (kind == 'switch' or kind == 'color' or kind == 'slider') and 0 or 2
		control:SetPoint('TOPRIGHT', card.body, 'TOPRIGHT', kind == 'switch' and -2 or 0, -y + nudge + (control.lift or 0))
		height = max(ROW_HEIGHT[kind], textHeight + 10)
	end
	-- Descriptions: under the whole row, the card's full width, two lines at most.
	if noteText and HubDB().describe then
		local line = Kit:Text(card.body, noteText, 9, 'dim')
		line:SetPoint('TOPLEFT', left, -y - height + 4)
		line:SetWidth(width - left)
		line:SetJustifyH('LEFT')
		line:SetWordWrap(true)
		if line.SetMaxLines then line:SetMaxLines(2) end
		height = height + min(line:GetStringHeight(), 26) + 6
	end
	Lockable(control, label, row)
	if control.refresh and row.disabled then control.refresh() end
	card.controls[#card.controls + 1] = control
	return height
end

-- Which rows are hidden right now, as one string; a change rebuilds the page.
local function HiddenSignature(page)
	local marks = {}
	for _, card in ipairs(page.cards or {}) do
		for _, row in ipairs(card.rows or {}) do
			if row.hidden then marks[#marks + 1] = Test(row.hidden) and '1' or '0' end
		end
	end
	return table.concat(marks)
end

local RebuildPage

-- Card state, per page and card: collapsed, or showing every option.
local function CardState(page, index)
	local db = HubDB()
	local id = page.key..':'..index
	return db.collapsed[id], db.expanded[id], id
end

local function Expander(card, y, width, text, onClick)
	local key = Kit:Key(card.body, {text = text, width = min(width, #text * 7 + 34), height = 22, textSize = 8})
	key:SetPoint('TOPLEFT', 0, -y - 4)
	key.onClick = onClick
	return 32
end

-- A page's printed model code: the title's initials, e.g. Unit frames -> UF.
local function PageCode(page)
	if page.code then return page.code end
	local letters = {}
	for word in tostring(page.title or page.key):gmatch('%a+') do
		if #letters < 2 and #word > 1 then letters[#letters + 1] = strupper(word:sub(1, 1)) end
	end
	if #letters < 2 then letters = {strupper(tostring(page.title or page.key):gsub('%A', ''):sub(1, 2))} end
	page.code = table.concat(letters)
	return page.code
end

-- Whether the page's module is running (the card lamps).
local function PageRunning(page)
	local module = UI.modules[page.key]
	if not module then return true end
	if module.problem then return false end
	return (module.enabled or module.ready) and true or false
end

-- Cards in one grid row share the tallest one's height, so bottoms line up.
local function EvenRows(cards)
	local column, row = 0, {}
	local function Settle()
		local tallest = 0
		for _, card in ipairs(row) do tallest = max(tallest, card:GetHeight()) end
		for _, card in ipairs(row) do if not card.folded then card:SetHeight(tallest) end end
	end
	for _, card in ipairs(cards) do
		local span = card.span or 1
		if column + span > CONTENT_COLUMNS then Settle(); row, column = {}, 0 end
		row[#row + 1] = card
		column = column + span
	end
	Settle()
end

local function BuildCards(content, page)
	local cards = {}
	local span = page.span or 2
	local width = span * Kit.COLUMN + (span - 1) * Kit.GAP
	local advanced = Advanced()
	page.controls = {}
	page.hiddenSignature = HiddenSignature(page)
	for index, spec in ipairs(page.cards) do
		local card = Kit.CardShell(content, index, spec.title, width, 200)
		card.span, card.controls = span, {}
		local collapsed, expanded, id = CardState(page, index)
		-- Printed model code (UF-01), and a lamp lit while the page's module runs.
		card.number:SetText(format('%s-%02d', PageCode(page), index))
		card.lamp = Kit:Led(card, 5, PageRunning(page))
		card.lamp:SetPoint('TOPRIGHT', -28, -12)
		-- Preview cards keep their notes whole: they reserve room for a live sample.
		card.fullNotes = advanced or (type(spec.title) == 'string' and strupper(spec.title) == 'PREVIEW')
		-- The header folds the card; a chevron shows which way.
		local fold = CreateFrame('Button', nil, card)
		fold:SetPoint('TOPLEFT', 4, -4)
		fold:SetPoint('TOPRIGHT', -4, -4)
		fold:SetHeight(20)
		fold.chevron = Kit:Icon(card, collapsed and 'chevron-right' or 'chevron-down', 9, 'dim')
		fold.chevron:SetPoint('TOPRIGHT', -12, -10)
		card.rule:SetWidth(max(width - 50 - card.number:GetStringWidth() - card.title:GetStringWidth() - 34, 1))
		fold:SetScript('OnClick', function()
			Kit:Play(collapsed and 'latch-down' or 'latch-up')
			HubDB().collapsed[id] = not collapsed or nil
			if collapsed then page.animateCard = index end
			RebuildPage(page)
		end)
		fold:SetScript('OnEnter', function() Kit:Tint(fold.chevron, 'ink') end)
		fold:SetScript('OnLeave', function() Kit:Tint(fold.chevron, 'dim') end)
		local y = 0
		if not collapsed then
			local bodyWidth = width - 24
			local shown, skipped = 0, 0
			for _, row in ipairs(spec.rows) do
				if not Test(row.hidden) then
					local setting = row[1] ~= 'note' and row[1] ~= 'header'
					if advanced or expanded or shown < CARD_ROWS or (not setting and skipped == 0) then
						if setting then shown = shown + 1 end
						y = y + BuildRow(card, row, y, bodyWidth, page)
					else
						if setting then skipped = skipped + 1 end
					end
				end
			end
			if skipped > 0 then
				y = y + Expander(card, y, bodyWidth, format('More options (%d)', skipped), function()
					Kit:Play('down')
					HubDB().expanded[id] = true
					page.animateCard = index
					Kit:Play('latch-down')
					RebuildPage(page)
				end)
			elseif expanded and not advanced then
				y = y + Expander(card, y, bodyWidth, 'Fewer options', function()
					Kit:Play('up')
					HubDB().expanded[id] = nil
					RebuildPage(page)
				end)
			end
			card:SetHeight(28 + y + 10)
		else
			card.body:Hide()
			card:SetHeight(34)
			card.folded = true
		end
		-- A card just opened (More options, unfolding) slides its rows in like a drawer.
		if page.animateCard == index and not collapsed then
			page.animateCard = nil
			card.body:SetAlpha(0)
			C_Timer.After(0, function()
				card.body:SetAlpha(1)
				if Kit:Faithful('slide') then Kit:SlideIn(card.body, 0, 10, 0.28) end
			end)
		end
		cards[#cards + 1] = card
		for _, control in ipairs(card.controls) do page.controls[#page.controls + 1] = control end
	end
	page.cardFrames = cards
	EvenRows(cards)
	return Kit:FlowCards(content, cards, CONTENT_COLUMNS)
end

-- Window ------------------------------------------------------------------------
local Search, ClearSearch, GroupOf, BuildNav, CascadeCards, MarkNav

-- Cards deal in one after another on the detent curve: each rises 8 px and fades in.
function CascadeCards(cards)
	if type(cards) ~= 'table' then return end
	if not Kit:Faithful('slide') then return end
	for index, card in ipairs(cards) do
		if index > 10 then break end
		card:SetAlpha(0)
		C_Timer.After((index - 1) * 0.04, function()
			-- SlideIn reads the resting alpha, so the card is put back to 1 first.
			card:SetAlpha(1)
			if card:IsVisible() then Kit:SlideIn(card, 0, -8, 0.26) end
		end)
	end
end

-- The sidebar's lit plate slides from the old page's entry to the new one.
function MarkNav(key)
	local entry = hub.nav and hub.nav[key]
	local marker = hub.navMarker
	if not marker then return end
	if not (entry and entry:IsShown()) then marker:Hide() return end
	local top, hubTop = entry:GetTop(), hub:GetTop()
	if not (top and hubTop) then return end
	local to = hubTop - top
	local from = marker:IsShown() and marker.at or to
	marker.at = to
	marker:Show()
	local function Place(y)
		marker:ClearAllPoints()
		marker:SetPoint('TOPLEFT', hub, 'TOPLEFT', Kit.PAD + 2, -y + 1)
	end
	if from == to or not Kit:Faithful('slide') then Place(to) return end
	Kit:Animate(marker, 0.22, from, to, Place, nil, 'detent')
end

local function HideAreas(except)
	for _, other in pairs(pages) do
		if other.area and other ~= except and other.area:IsShown() then
			other.area:Hide()
			if other.onHide then other.onHide(other.area) end
		end
	end
end

local function SelectPage(key)
	local page = pages[key] or pages.overview
	key = page.key
	UI.db.hub.page = key
	ClearSearch()
	for pageKey, entry in pairs(hub.nav) do
		local selected = pageKey == key
		Kit:SetLed(entry.led, selected)
		Kit:Tint(entry.label, selected and 'ink' or 'dim')
	end
	HideAreas(page)
	-- Rows that show or hide with other settings changed while this page was away.
	if page.area and page.cards and page.hiddenSignature ~= HiddenSignature(page) then
		page.area:Hide()
		page.area, page.controls = nil, nil
	end
	if not page.area then
		local area = Kit:ScrollArea(hub, {width = hub:GetWidth() - SIDEBAR - Kit.PAD * 2, height = hub:GetHeight() - 78, step = 60,
			smooth = true})
		area:SetPoint('TOPLEFT', SIDEBAR + Kit.PAD, -66)
		local ok, height = pcall(page.build or BuildCards, area.content, page)
		if not ok then
			local message = Kit:Text(area.content, 'This page failed to build: '..tostring(height), 10, 'red')
			message:SetPoint('TOPLEFT', 12, -12)
			message:SetWidth(area:GetWidth() - 24)
			height = 60
		end
		area.content:SetHeight(height or 400)
		area:Refresh()
		page.area = area
	end
	page.area:Show()
	-- side-panel-in: a new page fades in with a 6 px rise (240 ms); with the
	-- Staggered entrance extra its cards follow one after another.
	if Kit.SlideIn and Kit:Faithful('slide') then Kit:SlideIn(page.area) end
	CascadeCards(page.cardFrames)
	if page.onShow then page.onShow(page.area) end
	for _, control in ipairs(page.controls or {}) do
		if control.refresh then pcall(control.refresh) end
	end
	if hub.heading:GetText() ~= strupper(page.title) then Kit:PrintText(hub.heading, strupper(page.title)) end
	MarkNav(key)
	if UpdateLCD then UpdateLCD() end
	-- NEW marks show until a page has been opened once.
	if not UI.db.hub.seen[key] then
		UI.db.hub.seen[key] = true
		hub.navDirty = true
	end
	if hub.navGroup ~= nil and hub.navGroup ~= GroupOf(key) then BuildNav() end
end

-- A page whose hidden rows changed is built again (its old frames stay hidden).
function RebuildPage(page)
	if not page.area then return end
	local scroll = page.area.offset
	page.area:Hide()
	if page.onHide then page.onHide(page.area) end
	page.area, page.controls = nil, nil
	if UI.db.hub.page == page.key and hub:IsShown() then
		SelectPage(page.key)
		if scroll and page.area then page.area:ScrollTo(scroll, true) end
	end
end

-- Search ---------------------------------------------------------------------------
-- Every row of every page, by label and note; a page that builds itself can list
-- its own entries in page.search.
local RESULT_HEIGHT = 46
local function SearchEntries()
	local entries = {}
	for _, key in ipairs(pageOrder) do
		local page = pages[key]
		if not page.hidden then
			entries[#entries + 1] = {page = key, label = page.title, where = 'Section', new = PageIsNew(page)}
			for cardIndex, card in ipairs(page.cards or {}) do
				local setting = 0
				for _, row in ipairs(card.rows or {}) do
					local kind = row[1]
					local hidden = Test(row.hidden)
					if kind ~= 'header' and kind ~= 'note' and not hidden then setting = setting + 1 end
					if kind ~= 'header' and not hidden and type(row[2]) == 'string' then
						entries[#entries + 1] = {page = key, label = kind == 'note' and FirstLine(row[2]) or row[2],
							note = kind ~= 'note' and NoteOf(row) or nil, where = page.title..'  /  '..(card.title or ''),
							new = UI:IsNew(row.since), isNote = kind == 'note', card = cardIndex, setting = setting}
					end
				end
			end
			for _, item in ipairs(page.search or {}) do
				entries[#entries + 1] = {page = key, label = item[1], note = item[2], where = page.title}
			end
		end
	end
	return entries
end

local function ResultRow(parent)
	local row = CreateFrame('Button', nil, parent)
	row:SetHeight(RESULT_HEIGHT - 4)
	row.back = Kit:Texture(row, 'round-6', 'BACKGROUND')
	row.back:SetAllPoints()
	Kit:Tint(row.back, 'track')
	row.back:SetAlpha(0)
	row.led = Kit:Led(row, 5, false)
	row.led:SetPoint('TOPLEFT', 10, -10)
	row.where = Kit:Label(row, '', 'dim', 8)
	row.where:SetPoint('TOPLEFT', 22, -8)
	row.label = Kit:Text(row, '', 10, 'ink', true)
	row.label:SetPoint('TOPLEFT', 22, -20)
	row.label:SetPoint('RIGHT', -150, 0)
	row.label:SetJustifyH('LEFT')
	row.label:SetWordWrap(false)
	row.note = Kit:Text(row, '', 9, 'dim')
	row.note:SetPoint('LEFT', row.label, 'RIGHT', 12, 0)
	row.note:SetPoint('RIGHT', -12, 0)
	row.note:SetJustifyH('LEFT')
	row.note:SetWordWrap(false)
	row.jump = Kit:Icon(row, 'chevron-right', 10, 'dim')
	row.jump:SetPoint('RIGHT', -10, 0)
	row:SetScript('OnEnter', function(self) self.back:SetAlpha(1); Kit:Play('tick') end)
	row:SetScript('OnLeave', function(self) self.back:SetAlpha(0) end)
	row:SetScript('OnClick', function(self)
		Kit:Play('down')
		local entry, page = self.entry, pages[self.pageKey]
		-- Open the card the setting is in, and its extra options if it is past them.
		if entry and entry.card and page and page.cards then
			local id = page.key..':'..entry.card
			local db = UI.db.hub
			local changed = db.collapsed[id] or (not db.advanced and entry.setting > CARD_ROWS and not db.expanded[id])
			db.collapsed[id] = nil
			if not db.advanced and entry.setting > CARD_ROWS then db.expanded[id] = true end
			if changed and page.area then
				page.area:Hide()
				if page.onHide then page.onHide(page.area) end
				page.area, page.controls = nil, nil
			end
		end
		SelectPage(self.pageKey)
		-- Scroll to the card and light it.
		local card = entry and entry.card and page and page.cardFrames and page.cardFrames[entry.card]
		if card and page.area then
			local top, cardTop = page.area.content:GetTop(), card:GetTop()
			if top and cardTop then page.area:ScrollTo(max(0, top - cardTop - 8)) end
			if Kit.Flash then Kit:Flash(card, {token = 'lamp', alpha = 0.35, duration = 0.6}) end
		end
	end)
	return row
end

local function Results()
	if hub.results then return hub.results end
	local area = Kit:ScrollArea(hub, {width = hub:GetWidth() - SIDEBAR - Kit.PAD * 2, height = hub:GetHeight() - 78, step = 60,
		smooth = true})
	area:SetPoint('TOPLEFT', SIDEBAR + Kit.PAD, -66)
	area.rows = {}
	area.empty = Kit:Text(area.content, '', 10, 'dim')
	area.empty:SetPoint('TOPLEFT', 16, -16)
	area:Hide()
	hub.results = area
	return area
end

function Search(query)
	query = strlower(strtrim(query or ''))
	if query == '' then
		if hub.searching then
			hub.searching = nil
			if hub.results then hub.results:Hide() end
			SelectPage(UI.db.hub.page)
		end
		return
	end
	hub.searching = true
	HideAreas(nil)
	local area = Results()
	local matches = {}
	for _, entry in ipairs(SearchEntries()) do
		local label, note = strlower(entry.label or ''), strlower(entry.note or '')
		if strfind(label, query, 1, true) or strfind(note, query, 1, true) then matches[#matches + 1] = entry end
	end
	local width = area.content:GetWidth()
	for index, entry in ipairs(matches) do
		local row = area.rows[index]
		if not row then
			row = ResultRow(area.content)
			area.rows[index] = row
		end
		row.pageKey, row.entry = entry.page, entry
		row:ClearAllPoints()
		row:SetPoint('TOPLEFT', 8, -8 - (index - 1) * RESULT_HEIGHT)
		row:SetWidth(width - 16)
		row.where:SetText(strupper(entry.where or ''))
		row.label:SetText(entry.isNote and entry.label or strupper(entry.label or ''))
		row.note:SetText(entry.note or '')
		Kit:SetLed(row.led, entry.new and true or false)
		row:Show()
	end
	for index = #matches + 1, #area.rows do area.rows[index]:Hide() end
	area.empty:SetText(#matches == 0 and 'Nothing matches "'..query..'". Try a shorter word.' or '')
	area.content:SetHeight(16 + max(#matches, 1) * RESULT_HEIGHT)
	area:ScrollTo(0)
	area:Show()
	hub.heading:SetText(format('SEARCH  /  %d %s', #matches, #matches == 1 and 'RESULT' or 'RESULTS'))
end

function ClearSearch()
	if not hub or not hub.search then return end
	hub.searching = nil
	if hub.results then hub.results:Hide() end
	if hub.search:GetValue() ~= '' then hub.search:SetValue('') end
	if hub.searchTimer then hub.searchTimer:Cancel(); hub.searchTimer = nil end
end

-- Sidebar ------------------------------------------------------------------------------
-- Pages are grouped into a few sections. One section is open at a time (the
-- current page's, or the one last clicked); the others fold to their headers.
local GROUPS = {
	{'general', 'General', {'overview', 'setup', 'theme', 'fonts', 'motion', 'sounds', 'combatcue'}},
	{'layout', 'Layout', {'layout', 'profiles'}},
	{'frames', 'Frames', {'unitframes', 'group', 'nameplates', 'navbar'}},
	{'bars', 'Bars and auras', {'actionbars', 'buffs', 'timeline', 'cooldowns', 'swingtimer'}},
	{'interface', 'Interface', {'minimap', 'chat', 'windows', 'bags', 'objectives', 'infopanel', 'meters', 'banners',
		'notifications', 'qol'}},
	{'extras', 'Extras', {'components', 'about'}},
}
local GROUP_OF = {}
for _, group in ipairs(GROUPS) do
	for _, key in ipairs(group[3]) do GROUP_OF[key] = group[1] end
end

-- A page no section names falls into Interface.
function GroupOf(key) return GROUP_OF[key] or 'interface' end

local NAV_TOP, NAV_ROW, NAV_HEAD = 106, 20, 22

local function NavEntry(key, page)
	local entry = CreateFrame('Button', nil, hub)
	entry:SetSize(SIDEBAR - 20, NAV_ROW - 2)
	entry.led = Kit:Led(entry, 5, false)
	entry.led:SetPoint('LEFT', 8, 0)
	entry.label = Kit:Label(entry, page.title, 'dim', 9)
	entry.label:SetPoint('LEFT', 20, 0)
	entry.label:SetPoint('RIGHT', -14, 0)
	entry.label:SetJustifyH('LEFT')
	entry.label:SetWordWrap(false)
	entry.status = Kit:Led(entry, 4, false)
	entry.status:SetPoint('RIGHT', -2, 0)
	entry.status:Hide()
	if PageIsNew(page) and not UI.db.hub.seen[key] then
		entry.new = Kit:Led(entry, 3, true)
		entry.new:SetPoint('RIGHT', -8, 0)
	end
	entry:SetScript('OnEnter', function(self) Kit:Tint(self.label, 'ink') end)
	entry:SetScript('OnLeave', function(self)
		if UI.db.hub.page ~= key or hub.searching then Kit:Tint(self.label, 'dim') end
	end)
	entry:SetScript('OnClick', function(self)
		if UI.db.hub.page == key and not hub.searching then return end
		Kit:Play('latch-down')
		Kit:Chosen(self, nil, self.label, nil, 'ink', 'ink')
		SelectPage(key)
	end)
	return entry
end

local function NavHeader(group, open)
	local head = CreateFrame('Button', nil, hub)
	head:SetSize(SIDEBAR - 20, NAV_HEAD)
	head.lamp = Kit:Led(head, 4, true)
	head.lamp:SetPoint('LEFT', 2, 0)
	head.label = Kit:Label(head, group[2], open and 'ink' or 'dim', 8, true)
	head.label:SetPoint('LEFT', 10, 0)
	head.chevron = Kit:Icon(head, open and 'chevron-down' or 'chevron-right', 8, 'dim')
	head.chevron:SetPoint('RIGHT', -2, 0)
	head:SetScript('OnEnter', function(self) Kit:Tint(self.label, 'ink') end)
	head:SetScript('OnLeave', function(self) if not open then Kit:Tint(self.label, 'dim') end end)
	head:SetScript('OnClick', function()
		Kit:Play(open and 'latch-up' or 'latch-down')
		UI.db.hub.group = not open and group[1] or false
		hub.navOpenOverride = true
		BuildNav()
	end)
	return head
end

function BuildNav()
	for _, entry in pairs(hub.nav or {}) do entry:Hide() end
	for _, head in ipairs(hub.navHeads or {}) do head:Hide() end
	hub.nav, hub.navHeads = {}, {}
	-- Which pages exist, by section, in page order.
	local members = {}
	for _, key in ipairs(pageOrder) do
		local page = pages[key]
		if not page.hidden then
			local group = GroupOf(key)
			members[group] = members[group] or {}
			table.insert(members[group], key)
		end
	end
	-- The open section: the one last clicked, else the current page's.
	local current = GroupOf(UI.db.hub.page or 'overview')
	local open = UI.db.hub.group
	if not hub.navOpenOverride or open == nil then open = current end
	hub.navOpenOverride = nil
	hub.navGroup = open or false
	local y = -NAV_TOP
	for _, group in ipairs(GROUPS) do
		local list = members[group[1]]
		if list then
			local isOpen = open == group[1]
			local head = NavHeader(group, isOpen)
			head:SetPoint('TOPLEFT', Kit.PAD + 4, y)
			hub.navHeads[#hub.navHeads + 1] = head
			y = y - NAV_HEAD
			for _, key in ipairs(list) do
				-- Every page has an entry (the tour points at one); folded ones stay hidden.
				local entry = NavEntry(key, pages[key])
				entry:SetPoint('TOPLEFT', Kit.PAD + 4, y)
				entry:SetShown(isOpen)
				if isOpen then y = y - NAV_ROW end
				hub.nav[key] = entry
			end
			y = y - 4
		end
	end
	-- Paint the current page's lamp.
	for pageKey, entry in pairs(hub.nav) do
		local selected = pageKey == UI.db.hub.page and not hub.searching
		Kit:SetLed(entry.led, selected)
		Kit:Tint(entry.label, selected and 'ink' or 'dim')
	end
	hub.navDirty = nil
	-- The lit plate lands on the current page without sliding.
	if hub.navMarker then
		hub.navMarker:Hide()
		MarkNav(UI.db.hub.page)
	end
end

-- Header toggles: Advanced shows every option and whole notes; Descriptions adds a
-- line under each label. Built pages are rebuilt the next time they show.
local function ForgetPages()
	for _, page in pairs(pages) do
		if page.area and page.cards then
			page.area:Hide()
			if page.onHide then page.onHide(page.area) end
			page.area, page.controls = nil, nil
		end
	end
	if hub:IsShown() and not hub.searching then SelectPage(UI.db.hub.page) end
end

local function Build()
	local width = Kit.PAD * 2 + SIDEBAR + CONTENT_COLUMNS * Kit.COLUMN + (CONTENT_COLUMNS - 1) * Kit.GAP + 14
	hub = Kit:Panel(UIParent, {radius = 10, fill = 'page', border = 'hair', name = 'JiberishSpec01Hub'})
	hub:SetSize(width, 680)
	hub:SetPoint('CENTER')
	-- Menus, pop-ups and dialogs opened from here draw above it (same strata, higher levels).
	hub:SetFrameStrata('FULLSCREEN_DIALOG')
	hub:SetFrameLevel(10)
	hub:EnableMouse(true)
	hub:SetMovable(true)
	hub:SetClampedToScreen(true)
	hub:RegisterForDrag('LeftButton')
	hub:SetScript('OnDragStart', hub.StartMoving)
	hub:SetScript('OnDragStop', hub.StopMovingOrSizing)
	Kit:Grain(hub, 0.35, 4)
	-- A soft vignette: the housing darkens a touch toward its top and bottom edges.
	for _, edge in ipairs({'TOP', 'BOTTOM'}) do
		local shade = hub:CreateTexture(nil, 'BORDER', nil, -2)
		shade:SetColorTexture(1, 1, 1, 1)
		shade:SetPoint(edge..'LEFT', 10, edge == 'TOP' and -10 or 10)
		shade:SetPoint(edge..'RIGHT', -10, edge == 'TOP' and -10 or 10)
		shade:SetHeight(70)
		if shade.SetGradient and CreateColor then
			local dark, clear = CreateColor(0, 0, 0, 0.14), CreateColor(0, 0, 0, 0)
			if edge == 'TOP' then shade:SetGradient('VERTICAL', clear, dark) else shade:SetGradient('VERTICAL', dark, clear) end
		else
			shade:Hide()
		end
	end
	-- The sidebar's lit plate behind the current page's entry.
	hub.navMarker = Kit:Texture(hub, 'round-3', 'BORDER')
	hub.navMarker:SetSize(SIDEBAR - 16, NAV_ROW)
	if hub.navMarker.kitScale then hub.navMarker:SetSize((SIDEBAR - 16) / hub.navMarker.kitScale, NAV_ROW / hub.navMarker.kitScale) end
	Kit:Tint(hub.navMarker, 'track')
	hub.navMarker:Hide()
	tinsert(UISpecialFrames, 'JiberishSpec01Hub')

	-- Header: brand on the left, the page name, then the reference's own top bar
	-- controls on the right: key colors, finish, sound and close.
	hub.brand = Kit:Text(hub, 'JIBERISH / SPEC-01', 20, 'ink', true)
	hub.brand:SetPoint('TOPLEFT', Kit.PAD + 4, -18)
	hub.heading = Kit:Label(hub, '', 'dim', 9)
	hub.heading:SetPoint('TOPLEFT', Kit.PAD + 5, -44)

	hub.close = Kit:Button(hub, {round = true, icon = 'close', width = 28, height = 28, iconSize = 12})
	hub.close:SetPoint('TOPRIGHT', -Kit.PAD, -14)
	hub.close.onClick = function()
		Kit:Play('latch-up')
		Kit:Close(hub)
	end
	hub.sound = Kit:Key(hub, {width = 34, height = 26, icon = 'speaker', toggle = true, checked = Kit:DB().sound.enable})
	hub.sound:SetPoint('RIGHT', hub.close, 'LEFT', -10, 0)
	hub.sound.onClick = function(self) Kit:SetOption('sound.enable', self.checked) end
	Kit:AttachTooltip(hub.sound, 'Sounds')
	local finishes = {'paper', 'graphite'}
	hub.finish = Kit:Segmented(hub, {items = {'Paper', 'Graphite'}, width = 140, value = Kit:DB().finish == 'graphite' and 2 or 1,
		onChange = function(index, self)
			UI.changing = self
			Kit:SetOption('finish', finishes[index])
			UI.changing = nil
		end})
	-- Move UI: closes the hub and unlocks every frame; lit while frames are unlocked.
	hub.move = Kit:Key(hub, {text = 'Move UI', icon = 'grip', iconSize = 11, width = 96, height = 26, led = true})
	hub.move:SetPoint('RIGHT', hub.sound, 'LEFT', -10, 0)
	if hub.move.led then
		hub.move.led:ClearAllPoints()
		hub.move.led:SetPoint('TOPRIGHT', hub.move.face or hub.move, 'TOPRIGHT', -6, -6)
		Kit:SetLed(hub.move.led, UI.MoversUnlocked and UI:MoversUnlocked() and true or false)
	end
	hub.move.onClick = function()
		if UI.MoversUnlocked and UI:MoversUnlocked() then
			Kit:Play('latch-up')
			UI:ToggleMovers(true)
			return
		end
		if InCombatLockdown() then
			Kit:Play('error')
			return UI:Print('Frames can be moved once you leave combat.')
		end
		Kit:Play('latch-down')
		Kit:Close(hub, function() if UI.ToggleMovers then UI:ToggleMovers(false) end end)
	end
	Kit:AttachTooltip(hub.move, 'Unlock mode: drag, resize and nudge every frame')
	if UI.OnMoversChanged then
		UI:OnMoversChanged(function(what)
			if what == '__lock' and hub.move.led then Kit:SetLed(hub.move.led, UI:MoversUnlocked() and true or false) end
		end)
	end
	hub.finish:SetPoint('RIGHT', hub.move, 'LEFT', -12, 1)
	hub.accents = {}
	for index, name in ipairs(Kit.accentOrder) do
		local swatch = CreateFrame('Button', nil, hub)
		swatch:SetSize(16, 16)
		swatch:SetPoint('RIGHT', hub.finish, 'LEFT', -14 - (#Kit.accentOrder - index) * 20, 0)
		swatch.ring = Kit:Texture(swatch, 'circle-ring', 'BACKGROUND')
		swatch.ring:SetPoint('TOPLEFT', -3, 3); swatch.ring:SetPoint('BOTTOMRIGHT', 3, -3)
		Kit:Tint(swatch.ring, 'ink')
		swatch.dot = Kit:Texture(swatch, 'circle', 'ARTWORK')
		swatch.dot:SetAllPoints()
		Kit:Tint(swatch.dot, Kit.accentSkin[name].key)
		swatch:SetScript('OnClick', function()
			Kit:Play('down')
			Kit:SetOption('accent', name)
		end)
		hub.accents[name] = swatch
	end
	hub.reload = Kit:Button(hub, {text = 'Reload UI', width = 104, height = 26, led = true})
	hub.reload:SetPoint('RIGHT', hub.accents[Kit.accentOrder[1]], 'LEFT', -18, 0)
	hub.reload.onClick = function() ReloadUI() end
	Kit:AttachTooltip(hub.reload, 'Style changes apply after a reload')
	hub.reload:SetShown(UI.reloadPending and true or false)
	-- How much each page shows: every option (Advanced), and a line of description.
	hub.advanced = Kit:Key(hub, {text = 'Advanced', width = 92, height = 20, textSize = 8, toggle = true,
		checked = UI.db.hub.advanced and true or false})
	hub.advanced:SetPoint('TOPRIGHT', -Kit.PAD, -40)
	hub.advanced.onClick = function(self)
		UI.db.hub.advanced = self.checked and true or false
		ForgetPages()
	end
	Kit:AttachTooltip(hub.advanced, 'Every option and whole notes')
	hub.describe = Kit:Key(hub, {text = 'Descriptions', width = 108, height = 20, textSize = 8, toggle = true,
		checked = UI.db.hub.describe and true or false})
	hub.describe:SetPoint('RIGHT', hub.advanced, 'LEFT', -8, 0)
	hub.describe.onClick = function(self)
		UI.db.hub.describe = self.checked and true or false
		ForgetPages()
	end
	Kit:AttachTooltip(hub.describe, 'A line under each setting')
	-- An LCD strip: the page's code and how many settings changed since opening.
	hub.lcd = Kit:LCDPanel(hub, {radius = 3})
	hub.lcd:SetSize(150, 20)
	hub.lcd:SetPoint('RIGHT', hub.describe, 'LEFT', -10, 0)
	hub.lcd.text = Kit:Text(hub.lcd, '', 9, 'lcdInk', true)
	hub.lcd.text:SetPoint('CENTER')
	Kit:Font(hub.lcd.text, 9, nil, true, 'numbers')
	UpdateLCD = function()
		if not hub.lcd then return end
		local key = UI.db.hub.page
		local page = pages[key]
		local position = 1
		for index, pageKey in ipairs(pageOrder) do if pageKey == key then position = index end end
		local count = 0
		for _ in pairs(changedPaths) do count = count + 1 end
		Kit:PrintText(hub.lcd.text, format('%s-%02d  %02d CHG', page and PageCode(page) or '--', position, count), {minGap = 0.2})
	end

	-- Sidebar: a search field over the reference's nav items (a lamp and a printed label).
	local divider = Kit:Solid(hub, 'line')
	divider:SetWidth(1)
	divider:SetPoint('TOPLEFT', Kit.PAD + SIDEBAR - 8, -70)
	divider:SetPoint('BOTTOMLEFT', Kit.PAD + SIDEBAR - 8, 18)
	hub.search = Kit:TextField(hub, {width = SIDEBAR - 20, placeholder = 'Search', onChange = function(text)
		if hub.searchTimer then hub.searchTimer:Cancel() end
		hub.searchTimer = C_Timer.NewTimer(0.12, function()
			hub.searchTimer = nil
			UI:Safe(Search, text)
		end)
	end})
	hub.search:SetPoint('TOPLEFT', Kit.PAD + 2, -68)
	hub.search.edit:SetScript('OnEscapePressed', function(self)
		self:ClearFocus()
		ClearSearch()
		SelectPage(UI.db.hub.page)
	end)
	hub.search.icon = Kit:Icon(hub.search.glass, 'search', 10, 'darkDim')
	hub.search.icon:SetPoint('RIGHT', -9, 0)
	BuildNav()

	hub:SetScale(UI.db.scale or 1)
	hub:SetScript('OnShow', function()
		UI:UpdateHub()
	end)
	hub:SetScript('OnHide', function(self)
		self:StopMovingOrSizing()
		local page = pages[UI.db.hub.page]
		if page and page.area and page.onHide then page.onHide(page.area) end
		Kit:ClosePopover()
	end)
	hub:Hide()
end

-- For the setup guide's tour.
function UI:HubFrame() return hub end

local scaleTimer, rebuildQueued
function UI:UpdateHub()
	if not hub then return end
	local db = UI.db
	if hub.navDirty then BuildNav() end
	-- Rescale once the slider settles, not under the cursor on every tick.
	if hub:GetScale() ~= (db.scale or 1) then
		if scaleTimer then scaleTimer:Cancel() end
		scaleTimer = C_Timer.NewTimer(0.4, function() hub:SetScale(UI.db.scale or 1) end)
	end
	for name, swatch in pairs(hub.accents) do swatch.ring:SetShown(db.accent == name) end
	if UI.changing ~= hub.finish then hub.finish:SetValue(db.finish == 'graphite' and 2 or 1) end
	hub.sound:SetChecked(db.sound.enable)
	-- A red status lamp beside any section whose module failed to start.
	for key, entry in pairs(hub.nav) do
		local module = UI.modules[key]
		local failed = module and module.problem
		entry.status:SetShown(failed and true or false)
		if failed then Kit:SetLed(entry.status, true, 'red') end
	end
	local page = pages[db.hub.page]
	-- Rows that show or hide with other settings: rebuild the page a frame later,
	-- after the control that changed has finished its own work.
	if page and page.area and page.cards and page.hiddenSignature ~= HiddenSignature(page) and not rebuildQueued then
		rebuildQueued = true
		C_Timer.After(0, function()
			rebuildQueued = nil
			UI:Safe(RebuildPage, page)
		end)
	end
	for _, control in ipairs(page and page.controls or {}) do
		if control.refresh and control ~= UI.changing then pcall(control.refresh) end
	end
	if page and page.refresh then pcall(page.refresh, page.area) end
end

function UI:ToggleHub(key, show)
	if not hub then Build() end
	if key and not pages[key] then key = nil end
	if show == nil then show = key and true or not hub:IsShown() end
	if show then
		if hub.navDirty then BuildNav() end
		SelectPage(key or UI.db.hub.page)
		if not hub:IsShown() or hub.kitClosing then
			Kit:Play('open')
			Kit:Open(hub)
			wipe(changedPaths)
			if UpdateLCD then UpdateLCD() end
			-- The brand types on and the section lamps light in turn.
			Kit:PrintText(hub.brand, 'JIBERISH / SPEC-01', {duration = 0.35})
			for index, head in ipairs(hub.navHeads or {}) do
				if Kit:Faithful('slide') then
					Kit:SetLed(head.lamp, false)
					C_Timer.After(0.12 + index * 0.06, function()
						Kit:SetLed(head.lamp, true)
						if index == 1 or index == #hub.navHeads then Kit:Play('blip') end
					end)
				end
			end
		end
	else Kit:Close(hub) end
end

-- Pages that belong to no single module ------------------------------------------
local AREAS = {
	{'unitframes', 'Unit frames', {{'paper', 'Paper'}, {'dark', 'Dark'}, {'lcd', 'LCD'}, {'blizzard', 'Blizzard'}}},
	{'actionbars', 'Action bars', {{'keys', 'Keys'}, {'caps', 'Caps'}, {'blizzard', 'Blizzard'}}},
	{'buffs', 'Buffs', {{'keys', 'Keys'}, {'blizzard', 'Blizzard'}}},
	{'objectives', 'Objectives', {{'device', 'Device'}, {'blizzard', 'Blizzard'}}},
	{'loot', 'Loot and alerts', {{'device', 'Device'}, {'blizzard', 'Blizzard'}}},
	{'group', 'Raid, boss and arena', {{'device', 'Device'}, {'blizzard', 'Blizzard'}}},
	{'bags', 'Bags and bank', {{'device', 'Device'}, {'blizzard', 'Blizzard'}}},
	{'infopanel', 'Info panel', {{'device', 'Device'}, {'blizzard', 'Off'}}},
	{'meters', 'Damage meters', {{'device', 'Device'}, {'blizzard', 'Blizzard'}}},
	{'minimap', 'Minimap', {{'navigator', 'Device'}, {'ring', 'Ring'}, {'blizzard', 'Blizzard'}}},
	{'chat', 'Chat', {{'display', 'Device'}, {'blizzard', 'Blizzard'}}},
	{'tooltip', 'Tooltips', {{'display', 'Display'}, {'blizzard', 'Blizzard'}}},
	{'windows', 'Windows and bags', {{'display', 'Display'}, {'blizzard', 'Blizzard'}}},
	{'nameplates', 'Nameplates', {{'dots', 'Dots'}, {'pill', 'Pill'}, {'bar', 'Bar'}, {'blizzard', 'Blizzard'}}},
}
UI.AREAS = AREAS

UI:RegisterPage('overview', {title = 'Overview', order = 1, span = 4,
	build = function(content, page)
		page.controls = {}
		local width = 4 * Kit.COLUMN + 3 * Kit.GAP
		local card = Kit.CardShell(content, 1, 'Interface styles', width, 60 + #AREAS * 44)
		card.span = 4
		local intro = Kit:Text(card.body, 'Pick the SPEC-01 style for each part of the interface, or keep Blizzard\'s. Style changes apply after a reload; each section in the sidebar has the details.', 9, 'dim')
		intro:SetPoint('TOPLEFT')
		intro:SetWidth(width - 24)
		intro:SetJustifyH('LEFT')
		page.lamps = {}
		for index, area in ipairs(AREAS) do
			local y = -30 - (index - 1) * 44
			local lamp = Kit:Led(card.body, 6, false)
			lamp:SetPoint('TOPLEFT', 2, y - 6)
			local label = Kit:Label(card.body, area[2], 'ink', 9)
			label:SetPoint('TOPLEFT', 16, y - 2)
			local status = Kit:Text(card.body, '', 9, 'dim')
			status:SetPoint('TOPLEFT', 16, y - 16)
			status:SetPoint('TOPRIGHT', card.body, 'TOPRIGHT', -330, y - 16)
			status:SetJustifyH('LEFT')
			status:SetWordWrap(false)
			local values, names, current = {}, {}, 1
			for i, item in ipairs(area[3]) do
				values[i], names[i] = item[1], item[2]
				if item[1] == UI:Style(area[1]) then current = i end
			end
			local picker = Kit:Segmented(card.body, {items = names, width = 300, value = current, onChange = function(i)
				Kit:SetOption('style.'..area[1], values[i])
				UI:NeedsReload()
				page.refresh()
			end})
			picker:SetPoint('TOPRIGHT', 0, y)
			page.lamps[index] = {lamp = lamp, status = status, area = area}
		end
		card:ClearAllPoints()
		card:SetPoint('TOPLEFT', content, 'TOPLEFT', Kit.PAD / 2, -8)
		page.refresh = function()
			for _, entry in ipairs(page.lamps) do
				local module = UI.modules[entry.area[1]]
				local style = UI:Style(entry.area[1])
				if module and module.problem then
					Kit:SetLed(entry.lamp, true, 'red')
					entry.status:SetText('Failed to start: '..module.problem)
					Kit:Tint(entry.status, 'red')
				elseif module and module.enabled then
					Kit:SetLed(entry.lamp, true, 'green')
					entry.status:SetText(style == UI.startedStyle[entry.area[1]] and 'Running' or 'Running; reload to apply the new style')
					Kit:Tint(entry.status, 'dim')
				else
					Kit:SetLed(entry.lamp, false)
					entry.status:SetText(style == 'blizzard' and 'Blizzard default' or 'Reload to turn on')
					Kit:Tint(entry.status, 'dim')
				end
			end
		end
		page.refresh()
		return card:GetHeight() + 30
	end})

UI:RegisterPage('components', {title = 'Components', order = 90, gap = true,
	build = function(content) return Kit:BuildGallery(content) end,
	onShow = function(area) Kit:StartGalleryTickers(area) end,
	onHide = function(area) Kit:StopGalleryTickers(area) end})

UI:RegisterPage('about', {title = 'About', order = 99, cards = {
	{title = 'Jiberish SPEC-01 UI', rows = {
		{'note', 'A reskin of the Blizzard interface in the style of SPEC-01/HARDWARE by Shu Ding (github.com/shuding/spec-01), used under the MIT license. Its control art is rendered from the reference stylesheet and its sounds from the reference sound recipe. The license notice is in Media/Hardware/LICENSE-SPEC-01.txt.'},
		{'note', 'Typeface: IBM Plex Mono, Copyright 2017 IBM Corp., SIL Open Font License 1.1 (Media/Fonts/OFL.txt).'},
		{'note', 'Commands: /spec opens this window. /spec move unlocks the unit frames. /spec reset restores their positions. /spec sound tests sound playback.'},
	}},
}})
