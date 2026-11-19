-- The hub: one SPEC-01 window for everything, like ElvUI's options. A sidebar
-- of sections; each section is a grid of numbered cards built from simple row
-- descriptions that modules register with UI:RegisterPage.
--
--   /spec            open the hub (last page; Quick setup the first time)
--   /spec <page>     open a page: quick, whatsnew, theme, unitframes, actionbars, ...
--   /spec <word>     open the hub searching for that word (Core.lua's command table)
-- The sidebar's search field looks through every page's settings.
--
-- The header keeps three things for every page: Undo (also Ctrl+Z while the hub
-- is up) takes back the last change made here, Reset page puts the page's
-- settings back to their defaults, and one amber lamp with its Reload key
-- lights while any change waits on a reload (hover the lamp for the list).
-- Every change made through a row, or through UI:HubChange, is recorded for
-- Undo and the reload lamp; the bookkeeping lives in HubHistory.lua.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent = CreateFrame, UIParent
local floor, max, min = math.floor, math.max, math.min

local hub
local pages, pageOrder = {}, {}

-- defaults:begin
-- seen: page key -> the version it was last opened in (its NEW lamps go out).
-- landed: the hub has opened on Quick setup once (older saves start there once).
-- told: the version the "updated" toast last spoke for (WhatsNew.lua).
UI:RegisterDefaults('hub', {page = 'quick', advanced = false, describe = false, seen = {}, collapsed = {},
	expanded = {}, group = false, landed = false, told = false})
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
--   since = '0.5.0'    a NEW lamp while that is the addon's version, until the page is
--                      opened in that version (so set it to the release a row is new in)
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

-- HubHistory.lua loads just after this file; it is only read once things run.
local function Book() return UI.HubHistory end
local PaintReload, PaintUndo -- the header's lamp and Undo key, once built

-- A change that may owe a reload: listed while the setting differs from where it
-- started, so changing it back (or Undo) puts the lamp out again.
local function TrackReload(change, before, after)
	local book = Book()
	if not book then return end
	if change.reload then book.FlagReload(change.path, change.where or change.label, before) end
	if change.path then book.SettleReload(change.path, after) end
	UI.reloadPending = book.ReloadCount() > 0 or nil
	if PaintReload then PaintReload() end
end

-- Modules call this when something they changed only applies after a reload.
-- reason: a short name for the list on the lamp (else the page it came from).
function UI:NeedsReload(reason)
	local book = Book()
	if book then
		local label = reason
		if type(label) ~= 'string' then
			local page = hub and hub:IsShown() and pages[UI.db.hub.page]
			label = page and (page.title..' page') or 'Changes made outside this window'
		end
		book.FlagReload(nil, label)
	end
	self.reloadPending = true
	if PaintReload then PaintReload() end
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

-- A lamp at a whole number of physical pixels, snapped to the pixel grid, so it
-- reads as a full round LED at any scale.
local function Lamp(parent, px, on)
	local led = Kit:Led(parent, UI.Pixel.Px(parent, px), on)
	for _, texture in ipairs({led, led.glow}) do
		if texture and texture.SetSnapToPixelGrid then
			texture:SetSnapToPixelGrid(true)
			texture:SetTexelSnappingBias(0)
		end
	end
	return led
end
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
	if type(row[3]) ~= 'string' then return nil end
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
-- Every change is recorded for Undo (a run of changes to one setting, like a
-- slider drag, is one step) and for the reload lamp.
local changedPaths, UpdateLCD = {}, nil
local function Record(change)
	local book = Book()
	if not book then return end
	book.Push(change, GetTime())
	TrackReload(change, change.old, change.new)
	if PaintUndo then PaintUndo() end
end

local function Changed(row, value, control)
	local path = row[3]
	local book = Book()
	local old = book and book.Copy(Get(row))
	changedPaths[path or row] = true
	if UpdateLCD then UpdateLCD() end
	UI.changing = control
	if row.set then
		UI:Safe(row.set, value)
		Kit:Apply()
	else
		Kit:SetOption(path, value)
	end
	UI.changing = nil
	local page = pages[UI.db.hub.page]
	local label = row[2] or path or 'A setting'
	Record({key = path or row, path = path, label = label, old = old, new = value, set = row.set, row = row,
		reload = row.reload, where = page and page.key ~= 'quick' and (page.title..': '..label) or label})
end

-- For pages that build their own controls: change a setting the way a row does,
-- with Undo, the change count and the reload lamp. opts: label, reload, set(value),
-- get(), items / format (how Undo's toast names a value), control (the one changing).
function UI:HubChange(path, value, opts)
	opts = opts or {}
	Changed({opts.kind or 'custom', opts.label or path, path, set = opts.set, get = opts.get, reload = opts.reload,
		items = opts.items, format = opts.format}, value, opts.control)
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
local function ShowNote(anchor, title, text, below)
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
	if below then noteTip:SetPoint('TOPRIGHT', anchor, 'BOTTOMRIGHT', 0, -6)
	else noteTip:SetPoint('BOTTOMLEFT', anchor, 'TOPLEFT', 0, 6) end
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

-- Whether a page has been opened in this version (Book is loaded by then).
local function Seen(key)
	local book = Book()
	return book and book.Seen(HubDB().seen, key, VERSION) or false
end

-- New in this version, and the page not opened in it yet: a small key-color lamp.
local function ShowsNew(page, row)
	return UI:IsNew(row.since) and not Seen(page.key)
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
	item.label = Kit:Label(item, '', 'ink', 9)
	item.label:SetPoint('LEFT', 20, 0)
	item.lamp = Lamp(item, 6, false)
	item.lamp:SetPoint('CENTER', item.label, 'LEFT', -9, 0)
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
		for index, item in ipairs(Items(row)) do
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
	card.rowDesc, card.rowDescHeight = nil, nil
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
	local left = ShowsNew(page, row) and 10 or 0
	local label = Kit:Label(card.body, row[2] or '', 'ink', 9)
	label:SetPoint('TOPLEFT', left, -y)
	if left > 0 then
		local lamp = Lamp(card.body, 5, true)
		lamp:SetPoint('CENTER', label, 'LEFT', -6, 0)
	end
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
	-- Descriptions: under the whole row, the card's full width, two lines at most;
	-- made now and shown while the hub's Descriptions key is on.
	card.rowDesc, card.rowDescHeight = nil, nil
	if noteText then
		local line = Kit:Text(card.body, noteText, 9, 'dim')
		line:SetPoint('TOPLEFT', left, -y - height + 4)
		line:SetWidth(width - left)
		line:SetJustifyH('LEFT')
		line:SetWordWrap(true)
		if line.SetMaxLines then line:SetMaxLines(2) end
		line:Hide()
		card.rowDesc, card.rowDescHeight = line, min(line:GetStringHeight(), 26) + 6
	end
	Lockable(control, label, row)
	if control.refresh and row.disabled then control.refresh() end
	card.controls[#card.controls + 1] = control
	return height
end

-- Which rows are hidden right now, as one string; a change re-lays the page out.
local function HiddenSignature(page)
	local marks = {}
	for _, card in ipairs(page.cards or {}) do
		for _, row in ipairs(card.rows or {}) do
			if row.hidden then marks[#marks + 1] = Test(row.hidden) and '1' or '0' end
		end
	end
	return table.concat(marks)
end

local RebuildPage, Relayout

-- Card state, per page and card: collapsed, or showing every option.
local function CardState(page, index)
	local db = HubDB()
	local id = page.key..':'..index
	return db.collapsed[id], db.expanded[id], id
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

-- Pages are built once. Every row of every card is made up front, each on a
-- holder frame of its own (hidden rows and those behind More options too);
-- folding, More options, Advanced, Descriptions and rows that show or hide with
-- other settings only re-lay the page out: rows ease to their new places,
-- appearing ones fade in, leaving ones fade out, cards ease to their new
-- heights and the grid re-flows, with the scroll position kept.
local function Unit(card, row, width, page)
	local holder = CreateFrame('Frame', nil, card.body)
	holder:SetSize(width, 1)
	holder:Hide()
	local unit = {row = row, holder = holder, kind = row[1], setting = row[1] ~= 'note' and row[1] ~= 'header'}
	local function Shim(body) return {body = body, controls = card.controls, title = card.title} end
	if row[1] == 'note' then
		unit.compact = CreateFrame('Frame', nil, holder)
		unit.compact:SetAllPoints()
		unit.full = CreateFrame('Frame', nil, holder)
		unit.full:SetAllPoints()
		unit.compactHeight = Note(Shim(unit.compact), row, 0, width, false)
		unit.fullHeight = Note(Shim(unit.full), row, 0, width, true)
	else
		local shim = Shim(holder)
		unit.base = BuildRow(shim, row, 0, width, page)
		unit.desc, unit.descHeight = shim.rowDesc, shim.rowDescHeight
	end
	return unit
end

-- The row's height as things stand, showing the parts that apply.
local function UnitHeight(unit, card)
	if unit.expander then return 34 end
	if unit.compact then
		local full = card.preview or Advanced()
		unit.compact:SetShown(not full)
		unit.full:SetShown(full)
		return full and unit.fullHeight or unit.compactHeight
	end
	local described = unit.desc and HubDB().describe and true or false
	if unit.desc then unit.desc:SetShown(described) end
	return unit.base + (described and unit.descHeight or 0)
end

-- Which rows a card shows: hidden() rows never; past the first few settings
-- only with Advanced or More options.
local function PlanCard(page, card)
	local advanced = Advanced()
	local _, expanded = CardState(page, card.index)
	local shown, skipped = 0, 0
	for _, unit in ipairs(card.units) do
		local want = false
		if not Test(unit.row.hidden) then
			if advanced or expanded or shown < CARD_ROWS or (not unit.setting and skipped == 0) then
				want = true
				if unit.setting then shown = shown + 1 end
			elseif unit.setting then
				skipped = skipped + 1
			end
		end
		unit.want = want
	end
	local expander = card.expander
	if skipped > 0 then
		expander.want, expander.more = true, true
		expander.key:SetKeyText(format('More options (%d)', skipped))
		if expander.key.icon then Kit:SetIcon(expander.key.icon, 'chevron-down') end
	elseif expanded and not advanced then
		expander.want, expander.more = true, false
		expander.key:SetKeyText('Fewer options')
		if expander.key.icon then Kit:SetIcon(expander.key.icon, 'chevron-up') end
	else
		expander.want = false
	end
end

local function PlaceUnit(unit, body, y)
	unit.atY = y
	unit.holder:ClearAllPoints()
	unit.holder:SetPoint('TOPLEFT', body, 'TOPLEFT', 0, -y)
	unit.holder:SetPoint('TOPRIGHT', body, 'TOPRIGHT', 0, -y)
end

local function PlaceCard(card, content, x, y, height)
	card.atX, card.atY, card.atH = x, y, height
	card:ClearAllPoints()
	card:SetPoint('TOPLEFT', content, 'TOPLEFT', x, -y)
	card:SetHeight(max(height, 1))
end

local function Lerp(a, b, t) return a + (b - a) * t end

-- Work out where everything goes, then move there (eased, or at once).
function Relayout(page, animate)
	local area, cards = page.area, page.cardFrames
	if not cards or #cards == 0 then return 40 end
	local content = area and area.content or cards[1]:GetParent()
	animate = animate and Kit:Faithful('slide') and area and area:IsVisible()
	page.hiddenSignature = HiddenSignature(page)
	-- Rows and card heights.
	for _, card in ipairs(cards) do
		PlanCard(page, card)
		local collapsed = CardState(page, card.index)
		card.folded = collapsed and true or false
		local y = 0
		local list = card.allUnits
		for _, unit in ipairs(list) do
			local wanted = unit.want and not card.folded
			unit.toY = y
			if wanted then
				unit.height = UnitHeight(unit, card)
				unit.holder:SetHeight(unit.height)
				y = y + unit.height
			end
			unit.wanted = wanted
		end
		card.toH = card.folded and 34 or (28 + y + 10)
		Kit:SetIcon(card.chevron, card.folded and 'chevron-right' or 'chevron-down')
	end
	-- Cards in one grid row share the tallest one's height; then the grid flows.
	local column, rowCards, y, rowHeight = 0, {}, 0, 0
	local function Settle()
		local tallest = 0
		for _, card in ipairs(rowCards) do tallest = max(tallest, card.toH) end
		for _, card in ipairs(rowCards) do if not card.folded then card.toH = tallest end end
		local settled = 0
		for _, card in ipairs(rowCards) do settled = max(settled, card.toH) end
		return settled
	end
	for _, card in ipairs(cards) do
		local span = card.span or 1
		if column + span > CONTENT_COLUMNS then
			y = y + Settle() + Kit.GAP
			rowCards, column = {}, 0
		end
		rowCards[#rowCards + 1] = card
		card.toX, card.toY = Kit.PAD / 2 + column * (Kit.COLUMN + Kit.GAP), 8 + y
		column = column + span
	end
	rowHeight = Settle()
	local total = 8 + y + rowHeight + 24
	-- Move.
	local fromTotal = content:GetHeight() or total
	if not animate then
		for _, card in ipairs(cards) do
			for _, unit in ipairs(card.allUnits) do
				unit.holder:SetShown(unit.wanted)
				unit.holder:SetAlpha(1)
				if unit.wanted then PlaceUnit(unit, card.body, unit.toY) end
			end
			card.body:SetShown(not card.folded)
			card.body:SetAlpha(1)
			PlaceCard(card, content, card.toX, card.toY, card.toH)
		end
		content:SetHeight(total)
		if area then area:Refresh() end
		return total
	end
	-- Eased: everything from where it is now to where it goes, in one animation.
	for _, card in ipairs(cards) do
		card.fromX, card.fromY, card.fromH = card.atX or card.toX, card.atY or card.toY, card.atH or card.toH
		if not card.folded then card.body:Show() end
		for _, unit in ipairs(card.allUnits) do
			local shown = unit.holder:IsShown()
			unit.fromA = shown and unit.holder:GetAlpha() or 0
			unit.toA = unit.wanted and 1 or 0
			unit.fromY = (shown and unit.atY) or unit.toY
			if unit.wanted and not shown then
				unit.holder:SetAlpha(0)
				unit.holder:Show()
				PlaceUnit(unit, card.body, unit.toY)
			end
		end
	end
	content:SetHeight(max(fromTotal, total))
	area:Refresh()
	Kit:Animate(page, 0.22, 0, 1, function(t)
		for _, card in ipairs(cards) do
			PlaceCard(card, content, Lerp(card.fromX, card.toX, t), Lerp(card.fromY, card.toY, t), Lerp(card.fromH, card.toH, t))
			if card.folded then card.body:SetAlpha(1 - t) end
			for _, unit in ipairs(card.allUnits) do
				if unit.holder:IsShown() then
					if unit.fromY ~= unit.toY then PlaceUnit(unit, card.body, Lerp(unit.fromY, unit.toY, t)) end
					if unit.fromA ~= unit.toA then unit.holder:SetAlpha(Lerp(unit.fromA, unit.toA, t)) end
				end
			end
		end
	end, function()
		for _, card in ipairs(cards) do
			card.body:SetShown(not card.folded)
			card.body:SetAlpha(1)
			for _, unit in ipairs(card.allUnits) do
				unit.holder:SetShown(unit.wanted)
				unit.holder:SetAlpha(1)
				if unit.wanted then PlaceUnit(unit, card.body, unit.toY) end
			end
			PlaceCard(card, content, card.toX, card.toY, card.toH)
		end
		content:SetHeight(total)
		area:Refresh()
	end, 'detent')
	return total
end

local function BuildCards(content, page)
	local cards = {}
	local span = page.span or 2
	local width = span * Kit.COLUMN + (span - 1) * Kit.GAP
	local bodyWidth = width - 24
	page.controls = {}
	for index, spec in ipairs(page.cards) do
		local card = Kit.CardShell(content, index, spec.title, width, 200)
		card.span, card.controls, card.index = span, {}, index
		-- Rows past the card's edge while it eases smaller are cut off, not drawn
		-- over; the clip sits a little outside the body so lamps and glows near
		-- its edges stay whole.
		card.clip = CreateFrame('Frame', nil, card)
		card.clip:SetPoint('TOPLEFT', card, 'TOPLEFT', 2, -24)
		card.clip:SetPoint('BOTTOMRIGHT', card, 'BOTTOMRIGHT', -2, 2)
		card.clip:SetClipsChildren(true)
		card.body:SetParent(card.clip)
		-- Printed model code (UF-01), and a lamp lit while the page's module runs.
		card.number:SetText(format('%s-%02d', PageCode(page), index))
		-- Preview cards keep their notes whole: they reserve room for a live sample.
		card.preview = type(spec.title) == 'string' and strupper(spec.title) == 'PREVIEW'
		-- The header folds the card; a chevron shows which way.
		local fold = CreateFrame('Button', nil, card)
		fold:SetPoint('TOPLEFT', 4, -4)
		fold:SetPoint('TOPRIGHT', -4, -4)
		-- As tall as twice the title's middle, so the chevron and lamp centre on it.
		fold:SetHeight(23)
		card.chevron = Kit:Icon(fold, 'chevron-down', 9, 'dim')
		card.chevron:SetPoint('RIGHT', fold, 'RIGHT', -8, 0)
		card.lamp = Lamp(fold, 6, PageRunning(page))
		card.lamp:SetPoint('RIGHT', card.chevron, 'LEFT', -9, 0)
		card.rule:SetWidth(max(width - 50 - card.number:GetStringWidth() - card.title:GetStringWidth() - 34, 1))
		fold:SetScript('OnClick', function()
			local collapsed = CardState(page, index)
			Kit:Play(collapsed and 'latch-down' or 'latch-up')
			HubDB().collapsed[page.key..':'..index] = not collapsed or nil
			Relayout(page, true)
		end)
		fold:SetScript('OnEnter', function() Kit:Tint(card.chevron, 'ink') end)
		fold:SetScript('OnLeave', function() Kit:Tint(card.chevron, 'dim') end)
		-- Every row, built once.
		card.units, card.allUnits = {}, {}
		for _, row in ipairs(spec.rows) do
			local unit = Unit(card, row, bodyWidth, page)
			card.units[#card.units + 1] = unit
			card.allUnits[#card.allUnits + 1] = unit
		end
		-- More options / Fewer options.
		-- As wide as the card, with a chevron, so rows past the first few are plain to see.
		local holder = CreateFrame('Frame', nil, card.body)
		holder:SetSize(bodyWidth, 32)
		holder:Hide()
		local key = Kit:Key(holder, {text = 'More options', icon = 'chevron-down', iconSize = 9, width = bodyWidth, height = 24,
			textSize = 8})
		key:SetPoint('TOPLEFT', 0, -4)
		card.expander = {holder = holder, key = key, expander = true, row = {}}
		key.onClick = function()
			local id = page.key..':'..index
			local more = card.expander.more
			Kit:Play(more and 'latch-down' or 'latch-up')
			HubDB().expanded[id] = more and true or nil
			Relayout(page, true)
		end
		card.allUnits[#card.allUnits + 1] = card.expander
		cards[#cards + 1] = card
		for _, control in ipairs(card.controls) do page.controls[#page.controls + 1] = control end
	end
	page.cardFrames = cards
	return Relayout(page, false)
end

-- Window ------------------------------------------------------------------------
local Search, ClearSearch, GroupOf, BuildNav, LayoutNav, CascadeCards, MarkNav, LayoutHeader, SearchField

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
	local page = pages[key] or pages.quick or pages.overview
	key = page.key
	UI.db.hub.page = key
	ClearSearch()
	for pageKey, entry in pairs(hub.nav) do
		local selected = pageKey == key
		Kit:SetLed(entry.led, selected)
		Kit:Tint(entry.label, selected and 'ink' or 'dim')
	end
	HideAreas(page)
	-- Rows that show or hide with other settings, or the hub's Advanced and
	-- Descriptions keys, changed while this page was away: lay it out again.
	if page.area and page.cards and (page.layoutDirty or page.hiddenSignature ~= HiddenSignature(page)) then
		page.layoutDirty = nil
		Relayout(page, false)
	end
	if not page.area then
		local area = Kit:ScrollArea(hub, {width = hub:GetWidth() - SIDEBAR - Kit.PAD * 2, height = hub:GetHeight() - 104, step = 60,
			smooth = true})
		area:SetPoint('TOPLEFT', SIDEBAR + Kit.PAD, -92)
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
	if page.noCascade then
		page.noCascade = nil
	else
		if Kit.SlideIn and Kit:Faithful('slide') then Kit:SlideIn(page.area) end
		CascadeCards(page.cardFrames)
	end
	if page.onShow then page.onShow(page.area) end
	for _, control in ipairs(page.controls or {}) do
		if control.refresh then pcall(control.refresh) end
	end
	if hub.heading:GetText() ~= strupper(page.title) then Kit:PrintText(hub.heading, strupper(page.title)) end
	MarkNav(key)
	if UpdateLCD then UpdateLCD() end
	-- NEW marks show until a page has been opened once in this version.
	local book = Book()
	if book and book.MarkSeen(UI.db.hub.seen, key, VERSION) then
		local entry = hub.nav and hub.nav[key]
		if entry and entry.new then entry.new:Hide() end
	end
	if hub.PaintPageKeys then hub.PaintPageKeys(page) end
	if hub.navGroup ~= nil and hub.navGroup ~= GroupOf(key) then
		UI.db.hub.group = false
		LayoutNav(true)
	end
end

-- Only for a real change of what a page holds (it was registered again): built
-- afresh, in place, without the opening cascade.
function RebuildPage(page)
	if not page.area then return end
	local scroll = page.area.offset
	page.area:Hide()
	if page.onHide then page.onHide(page.area) end
	page.area, page.controls, page.cardFrames = nil, nil, nil
	if UI.db.hub.page == page.key and hub:IsShown() then
		page.noCascade = true
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
	row.led = Lamp(row, 6, false)
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
			if changed and page.area then page.layoutDirty = true end
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
	local area = Kit:ScrollArea(hub, {width = hub:GetWidth() - SIDEBAR - Kit.PAD * 2, height = hub:GetHeight() - 104, step = 60,
		smooth = true})
	area:SetPoint('TOPLEFT', SIDEBAR + Kit.PAD, -92)
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
	if hub.PaintPageKeys then hub.PaintPageKeys(nil) end
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

-- /spec <word>: the hub opens with that word in the search field.
function UI:SearchHub(query)
	query = strtrim(tostring(query or ''))
	self:ToggleHub(nil, true)
	if not hub or not hub.search then return end
	hub.search:SetValue(query)
	UI:Safe(Search, query)
end

-- Sidebar ------------------------------------------------------------------------------
-- Pages are grouped into a few sections. One section is open at a time (the
-- current page's, or the one last clicked); the others fold to their headers.
local GROUPS = {
	{'general', 'General', {'quick', 'whatsnew', 'overview', 'setup', 'theme', 'colors', 'housing', 'fonts', 'fade', 'motion', 'sounds', 'combatcue'}},
	{'layout', 'Layout', {'layout', 'profiles'}},
	{'frames', 'Frames', {'unitframes', 'group', 'nameplates', 'navbar', 'wiring'}},
	{'bars', 'Bars and auras', {'actionbars', 'buffs', 'timeline', 'cooldowns', 'swingtimer'}},
	{'interface', 'Interface', {'minimap', 'navigation', 'chat', 'windows', 'bags', 'objectives', 'infopanel', 'meters', 'banners',
		'notifications', 'qol', 'away'}},
	{'extras', 'Extras', {'drawer', 'calendar', 'components', 'commands', 'about'}},
}
local GROUP_OF = {}
for _, group in ipairs(GROUPS) do
	for _, key in ipairs(group[3]) do GROUP_OF[key] = group[1] end
end

-- A page no section names falls into Interface.
function GroupOf(key) return GROUP_OF[key] or 'interface' end

local NAV_TOP, NAV_ROW, NAV_HEAD = 128, 20, 22

local function NavEntry(key, page)
	local entry = CreateFrame('Button', nil, hub)
	entry:SetSize(SIDEBAR - 20, NAV_ROW - 2)
	-- Above the sidebar's lit plate.
	entry:SetFrameLevel(hub:GetFrameLevel() + 4)
	entry.label = Kit:Label(entry, page.title, 'dim', 9)
	entry.label:SetPoint('LEFT', 22, 0)
	entry.label:SetPoint('RIGHT', -16, 0)
	entry.label:SetJustifyH('LEFT')
	entry.label:SetWordWrap(false)
	entry.led = Lamp(entry, 6, false)
	entry.led:SetPoint('CENTER', entry.label, 'LEFT', -10, 0)
	entry.status = Lamp(entry, 5, false)
	entry.status:SetPoint('RIGHT', -4, 0)
	entry.status:Hide()
	if PageIsNew(page) and not Seen(key) then
		entry.new = Lamp(entry, 4, true)
		entry.new:SetPoint('RIGHT', -10, 0)
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

local function NavHeader(group)
	local head = CreateFrame('Button', nil, hub)
	head:SetSize(SIDEBAR - 20, NAV_HEAD)
	head.group = group
	head:SetFrameLevel(hub:GetFrameLevel() + 4)
	head.label = Kit:Label(head, group[2], 'dim', 8, true)
	head.label:SetPoint('LEFT', 12, 0)
	head.lamp = Lamp(head, 5, true)
	head.lamp:SetPoint('CENTER', head.label, 'LEFT', -7, 0)
	head.chevron = Kit:Icon(head, 'chevron-right', 8, 'dim')
	head.chevron:SetPoint('RIGHT', -2, 0)
	head:SetScript('OnEnter', function(self) Kit:Tint(self.label, 'ink') end)
	head:SetScript('OnLeave', function(self) if hub.navGroup ~= group[1] then Kit:Tint(self.label, 'dim') end end)
	head:SetScript('OnClick', function()
		local open = hub.navGroup == group[1]
		Kit:Play(open and 'latch-up' or 'latch-down')
		UI.db.hub.group = not open and group[1] or false
		hub.navOpenOverride = true
		LayoutNav(true)
	end)
	return head
end

-- Entries and headers are made once (again only when pages are registered);
-- opening a section only re-lays the sidebar out.
function BuildNav()
	for _, entry in pairs(hub.nav or {}) do entry:Hide() end
	for _, head in ipairs(hub.navHeads or {}) do head:Hide() end
	hub.nav, hub.navHeads, hub.navMembers = {}, {}, {}
	for _, key in ipairs(pageOrder) do
		local page = pages[key]
		if not page.hidden then
			local group = GroupOf(key)
			hub.navMembers[group] = hub.navMembers[group] or {}
			table.insert(hub.navMembers[group], key)
			-- Every page has an entry (the tour points at one); folded ones stay hidden.
			local entry = NavEntry(key, page)
			entry:Hide()
			hub.nav[key] = entry
		end
	end
	for _, group in ipairs(GROUPS) do
		if hub.navMembers[group[1]] then hub.navHeads[#hub.navHeads + 1] = NavHeader(group) end
	end
	hub.navDirty = nil
	LayoutNav(false)
end

-- Places the headers and the open section's entries: eased, or at once.
function LayoutNav(animate)
	if not hub.navHeads then return end
	-- The open section: the one last clicked, else the current page's.
	local current = GroupOf(UI.db.hub.page or 'quick')
	local open = UI.db.hub.group
	if not hub.navOpenOverride or open == nil then open = current end
	hub.navOpenOverride = nil
	hub.navGroup = open or false
	animate = animate and Kit:Faithful('slide') and hub:IsVisible()
	local moves, y = {}, -NAV_TOP
	local function Move(frame, toY, show)
		local shown = frame:IsShown()
		moves[#moves + 1] = {frame = frame, fromY = shown and frame.navY or toY, toY = toY, show = show,
			fromA = shown and frame:GetAlpha() or 0}
		if show and not shown then frame:SetAlpha(0); frame:Show() end
		if not animate then
			frame:SetShown(show)
			frame:SetAlpha(1)
		end
	end
	for _, head in ipairs(hub.navHeads) do
		local group = head.group
		local isOpen = open == group[1]
		Kit:Tint(head.label, isOpen and 'ink' or 'dim')
		Kit:SetIcon(head.chevron, isOpen and 'chevron-down' or 'chevron-right')
		Move(head, y, true)
		y = y - NAV_HEAD
		for _, key in ipairs(hub.navMembers[group[1]] or {}) do
			local entry = hub.nav[key]
			Move(entry, y, isOpen)
			if isOpen then y = y - NAV_ROW end
		end
		y = y - 4
	end
	local function Place(frame, at)
		frame.navY = at
		frame:ClearAllPoints()
		frame:SetPoint('TOPLEFT', hub, 'TOPLEFT', Kit.PAD + 4, at)
	end
	-- Paint the current page's lamp.
	for pageKey, entry in pairs(hub.nav) do
		local selected = pageKey == UI.db.hub.page and not hub.searching
		Kit:SetLed(entry.led, selected)
		Kit:Tint(entry.label, selected and 'ink' or 'dim')
	end
	if hub.navMarker then hub.navMarker:Hide() end
	if not animate then
		for _, move in ipairs(moves) do Place(move.frame, move.toY) end
		MarkNav(UI.db.hub.page)
		return
	end
	Kit:Animate(hub.navHeads, 0.22, 0, 1, function(t)
		for _, move in ipairs(moves) do
			Place(move.frame, move.fromY + (move.toY - move.fromY) * t)
			local toA = move.show and 1 or 0
			if move.fromA ~= toA then move.frame:SetAlpha(move.fromA + (toA - move.fromA) * t) end
		end
	end, function()
		for _, move in ipairs(moves) do
			Place(move.frame, move.toY)
			move.frame:SetShown(move.show)
			move.frame:SetAlpha(1)
		end
		MarkNav(UI.db.hub.page)
	end, 'detent')
end

-- Header toggles: Advanced shows every option and whole notes; Descriptions adds a
-- line under each label. Built pages are rebuilt the next time they show.
local function ForgetPages()
	local current = pages[UI.db.hub.page]
	for _, page in pairs(pages) do
		if page.area and page.cards then
			if page == current and page.area:IsShown() then Relayout(page, true) else page.layoutDirty = true end
		end
	end
end

-- The header grid, right to left: close, sound | Move UI | finish | key colors |
-- the reload lamp and key on the first row; Advanced, Descriptions | LCD |
-- Reset page, Undo on the second. Gaps are fixed (4-6 px within a group, 12
-- between groups) and widths measured, so nothing overlaps at any scale; when
-- the first row would reach the brand, the reload lamp moves to the second row.
local ROW1_Y, ROW2_Y, GAP_IN, GAP_OUT = -14, -54, 6, 12
function LayoutHeader()
	if not hub or not hub.close then return end
	local x = -Kit.PAD
	local function Put(frame, y, gapBefore)
		if not frame:IsShown() then return end
		x = x - (gapBefore or 0)
		frame:ClearAllPoints()
		frame:SetPoint('TOPRIGHT', hub, 'TOPRIGHT', x, y)
		x = x - frame:GetWidth()
	end
	local KEY_TOP = ROW1_Y
	Put(hub.close, KEY_TOP, 0)
	Put(hub.sound, KEY_TOP, GAP_IN)
	Put(hub.move, KEY_TOP, GAP_OUT)
	Put(hub.finish, KEY_TOP, GAP_OUT)
	for index = #Kit.accentOrder, 1, -1 do
		local swatch = hub.accents[Kit.accentOrder[index]]
		-- Centered on the keys' row.
		Put(swatch, KEY_TOP - 4, index == #Kit.accentOrder and GAP_OUT + 4 or GAP_IN + 2)
	end
	local box = hub.reloadBox
	local brandRight = Kit.PAD + 4 + (hub.brand:GetStringWidth() or 200) + 16
	local reloadOnTop = (hub:GetWidth() + x - GAP_OUT - 2 - box:GetWidth()) > brandRight
	if reloadOnTop then Put(box, KEY_TOP, GAP_OUT + 2) end
	-- Second row.
	x = -Kit.PAD
	Put(hub.advanced, ROW2_Y, 0)
	Put(hub.describe, ROW2_Y, GAP_IN)
	Put(hub.lcd, ROW2_Y - 3, GAP_OUT)
	Put(hub.resetPage, ROW2_Y, GAP_OUT)
	Put(hub.undo, ROW2_Y, GAP_IN)
	if not reloadOnTop then Put(box, ROW2_Y + 1, GAP_OUT) end
end

-- The sidebar's search: a black screen field drawn from code (a crisp 1 px
-- edge, no offset shadow), as tall as a sidebar row and a half, with the
-- reference's block caret. Keeps TextField's GetValue / SetValue / .edit.
function SearchField(parent, width, onChange)
	local field = CreateFrame('Frame', nil, parent)
	field:SetSize(width, 26)
	field.shell = Kit:Shell(field, {surface = 'screen', radius = 4, shadow = false})
	field.glass = field
	local edit = CreateFrame('EditBox', nil, field)
	edit:SetPoint('TOPLEFT', 9, 0)
	edit:SetPoint('BOTTOMRIGHT', -24, 0)
	edit:SetAutoFocus(false)
	edit:SetFont(Kit:FontPath(false), 10, '')
	edit:SetTextColor(Kit:RGB('darkInk'))
	edit:SetJustifyV('MIDDLE')
	field.edit = edit
	field.placeholder = Kit:Label(field, 'Search', 'darkDim', 9)
	field.placeholder:SetPoint('LEFT', 10, 0)
	field.icon = Kit:Icon(field, 'search', 10, 'darkDim')
	field.icon:SetPoint('RIGHT', -9, 0)
	edit:SetScript('OnTextChanged', function(self, user)
		field.placeholder:SetShown(self:GetText() == '')
		if user and onChange then onChange(self:GetText()) end
	end)
	edit:SetScript('OnEditFocusGained', function() Kit:Tint(field.icon, 'lamp') end)
	edit:SetScript('OnEditFocusLost', function() Kit:Tint(field.icon, 'darkDim') end)
	edit:SetScript('OnEnterPressed', function(self) self:ClearFocus() end)
	field:EnableMouse(true)
	field:SetScript('OnMouseDown', function() edit:SetFocus() end)
	function field:GetValue() return edit:GetText() end
	function field:SetValue(text)
		edit:SetText(text or '')
		field.placeholder:SetShown((text or '') == '')
	end
	if Kit.Caret then Kit:Caret(edit) end
	return field
end

-- Undo, Reset page and the reload lamp ---------------------------------------------
-- Key colors as {value, name}, for anything that names one (Undo's toast).
function UI.AccentItems()
	local items = {}
	for _, name in ipairs(Kit.accentOrder) do items[#items + 1] = {name, Kit.accents[name] and Kit.accents[name].name or name} end
	items[#items + 1] = {'class', 'Class color'}
	items[#items + 1] = {'custom', 'Custom'}
	return items
end

-- How Undo's toast names a value: the row's own item name or format, on/off.
local function ValueText(change, value)
	local row = change.row or {}
	if type(value) == 'boolean' then return value and 'on' or 'off' end
	for _, item in ipairs(Items(row)) do
		if type(item) == 'table' and item[1] == value then return tostring(item[2] or item[1]) end
	end
	if type(value) == 'number' then
		if row.format then
			local ok, text = pcall(row.format, value)
			if ok and text then return tostring(text) end
		end
		return format('%g', value)
	end
	if type(value) == 'table' then return 'its earlier color' end
	if value == nil or value == '' then return 'empty' end
	return tostring(value)
end

-- Takes back the last change made in the hub (a page reset is one change).
function UI:HubUndo()
	local book = Book()
	local entry = book and book.Pop()
	if not entry then
		Kit:Play('error')
		return false
	end
	local changes = book.Changes(entry)
	for _, change in ipairs(changes) do
		local value = book.Copy(change.old)
		changedPaths[change.path or change.key or change] = true
		if change.set then
			UI:Safe(change.set, value)
		elseif change.path and not entry.changes then
			UI:Safe(Kit.SetOption, Kit, change.path, value)
		elseif change.path then
			book.Write(UI.db, change.path, value)
		end
		TrackReload(change, change.new, change.old)
	end
	if entry.changes or entry.set then Kit:Apply() end
	Kit:Play('latch-up')
	local text = entry.changes and format('%s: %d %s put back as they were.', entry.label, #changes, #changes == 1 and 'setting' or 'settings')
		or format('%s back to %s.', entry.label, ValueText(entry, entry.old))
	Kit:Toast({title = 'Undone', text = text, sound = false,
		action = book.Count() > 0 and {text = 'Undo', onClick = function() UI:HubUndo() end} or nil})
	if PaintUndo then PaintUndo() end
	if UpdateLCD then UpdateLCD() end
	return true
end

-- Every setting on a page back to its registered default (UI.defaults), after a
-- confirm; private settings (UI scale, frame positions, the hub's own) stay.
function UI:HubResetPage(key)
	local page = pages[key or UI.db.hub.page]
	local book = Book()
	if not (page and page.cards and book) then return Kit:Play('error') end
	local plan = book.ResetPlan(page, UI.defaults, UI.db)
	if #plan == 0 then
		Kit:Toast({title = page.title, text = 'Every setting here is already at its default.'})
		return
	end
	Kit:AlertDialog({title = 'Reset '..page.title,
		text = format('%d %s on this page go back to their defaults. Undo brings them back.', #plan, #plan == 1 and 'setting' or 'settings'),
		confirm = 'Reset', onConfirm = function()
			for _, change in ipairs(plan) do
				local row = change.row
				change.set, change.reload = row.set, row.reload
				change.where = page.title..': '..tostring(change.label)
				if row.set then UI:Safe(row.set, book.Copy(change.new)) else book.Write(UI.db, change.path, change.new) end
				changedPaths[change.path] = true
				TrackReload(change, change.old, change.new)
			end
			book.Push({label = page.title..' reset', changes = plan}, GetTime())
			Kit:Apply()
			Kit:Play('success')
			if PaintUndo then PaintUndo() end
			if UpdateLCD then UpdateLCD() end
			Kit:Toast({title = page.title..' reset', text = format('%d back to defaults.', #plan), tone = 'success', sound = false,
				action = {text = 'Undo', onClick = function() UI:HubUndo() end}})
		end})
end

function PaintUndo()
	if not hub or not hub.undo then return end
	local book = Book()
	hub.undo:SetKeyEnabled(book ~= nil and book.Count() > 0)
end

function PaintReload()
	local box = hub and hub.reloadBox
	if not box then return end
	local book = Book()
	local labels = book and book.ReloadLabels() or {}
	local waiting = #labels > 0
	Kit:SetLed(box.lamp, waiting, 'amber')
	local blink = waiting and Kit:Faithful('breathe') and true or false
	if blink ~= box.blinking then
		box.blinking = blink
		Kit:Blink(box.lamp, 0.8, blink)
	end
	box.legend:SetText(waiting and format('%d TO APPLY', #labels) or 'UP TO DATE')
	Kit:Tint(box.legend, waiting and 'ink' or 'dim')
	hub.reload:SetTone(waiting and 'primary' or 'default')
end

-- The lamp's hover: what is waiting on the reload.
local function ReloadNote(anchor)
	local book = Book()
	local labels = book and book.ReloadLabels() or {}
	local text
	if #labels == 0 then
		text = 'Nothing is waiting on a reload. Settings that only apply after one light this lamp when you change them, and are listed here.'
	else
		local lines = {}
		for index, label in ipairs(labels) do
			if index > 12 then lines[#lines + 1] = format('... and %d more', #labels - 12) break end
			lines[#lines + 1] = '- '..label
		end
		text = 'These apply after a reload:\n'..table.concat(lines, '\n')..'\n\nThe Reload key reloads the interface now (once out of combat).'
	end
	ShowNote(anchor, 'Reload', text, true)
end

-- The header's second row of keys: Undo, Reset page and the reload lamp.
local function BuildTools(height)
	hub.undo = Kit:Key(hub, {text = 'Undo', width = 72, height = 30, textSize = 8})
	hub.undo.onClick = function() UI:HubUndo() end
	Kit:AttachTooltip(hub.undo, function()
		local top = Book() and Book().Peek()
		return top and ('Undo '..top.label..'  (Ctrl+Z)') or 'Nothing to undo'
	end)
	hub.resetPage = Kit:Key(hub, {text = 'Reset page', width = 98, height = 30, textSize = 8})
	hub.resetPage.onClick = function() UI:HubResetPage() end
	Kit:AttachTooltip(hub.resetPage, 'This page\'s settings back to their defaults')
	hub.PaintPageKeys = function(page)
		hub.resetPage:SetKeyEnabled(page and page.cards and not page.noReset and true or false)
	end
	-- One lamp for every change that waits on a reload, and the key that does it.
	local box = CreateFrame('Frame', nil, hub)
	box.lamp = Lamp(box, 6, false)
	box.lamp:SetPoint('LEFT', 2, 0)
	box.legend = Kit:Label(box, 'UP TO DATE', 'dim', 8, true)
	box.legend:SetPoint('LEFT', box.lamp, 'RIGHT', 6, 0)
	box.legend:SetWidth(68)
	box.legend:SetJustifyH('LEFT')
	box.legend:SetWordWrap(false)
	hub.reload = Kit:Key(box, {text = 'Reload', width = 76, height = height})
	hub.reload:SetPoint('RIGHT', box, 'RIGHT', 0, 0)
	Kit:ReloadKey(hub.reload, true)
	-- Another Reload key (a dialog's, a toast's) may have taken the shared secure
	-- cover since; pointing at this one puts it back over this key.
	hub.reload:HookScript('OnEnter', function(self) if self.kitReload and not InCombatLockdown() then Kit:ReloadKey(self, true) end end)
	box:SetSize(2 + 6 + 6 + 68 + 6 + hub.reload:GetWidth(), height)
	box.hit = CreateFrame('Frame', nil, box)
	box.hit:SetPoint('TOPLEFT', box, 'TOPLEFT', 0, 0)
	box.hit:SetPoint('BOTTOMRIGHT', hub.reload, 'BOTTOMLEFT', -2, 0)
	box.hit:EnableMouse(true)
	box.hit:SetScript('OnEnter', function(self) ReloadNote(self) end)
	box.hit:SetScript('OnLeave', HideNote)
	hub.reloadBox = box
	PaintReload()
	PaintUndo()
end

-- Ctrl+Z while the hub is up, as an override binding: no frame takes the
-- keyboard, so every other key goes straight to the game.
local function Keyboard(on)
	UI.Util.Keys('hub', on and {['CTRL-Z'] = function() UI:HubUndo() end} or nil, 3)
end

local function Build()
	local width = Kit.PAD * 2 + SIDEBAR + CONTENT_COLUMNS * Kit.COLUMN + (CONTENT_COLUMNS - 1) * Kit.GAP + 14
	hub = Kit:Panel(UIParent, {radius = 10, fill = 'page', border = 'hair', name = 'JiberishSpec01Hub'})
	hub:SetSize(width, 712)
	hub:SetPoint('CENTER')
	-- The scale first: lamps and hairlines below are measured in physical pixels.
	hub:SetScale(UI.db.scale or 1)
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
	-- A pressed key (the reference's baked key-down, readable on Paper and
	-- Graphite) with a lit bar along its left edge, on a frame above the
	-- housing and below the entries.
	hub.navMarker = CreateFrame('Frame', nil, hub)
	hub.navMarker:SetSize(SIDEBAR - 16, NAV_ROW)
	hub.navMarker:SetFrameLevel(hub:GetFrameLevel() + 2)
	hub.navMarker.skin = Kit:Skin(hub.navMarker, 'key-down', 'BACKGROUND', 0)
	hub.navMarker.skin.kitMaxCorner = 6
	Kit:FitSprite(hub.navMarker.skin, SIDEBAR - 16, NAV_ROW)
	hub.navMarker.bar = Kit:Solid(hub.navMarker, 'lamp', 'OVERLAY')
	hub.navMarker.bar:SetSize(UI.Pixel.Px(hub, 2), NAV_ROW - 8)
	hub.navMarker.bar:SetPoint('LEFT', 3, 0)
	hub.navMarker:Hide()
	tinsert(UISpecialFrames, 'JiberishSpec01Hub')

	-- Header: brand on the left, the page name, then the reference's own top bar
	-- controls on the right: key colors, finish, sound and close.
	hub.brand = Kit:Text(hub, 'JIBERISH / SPEC-01', 20, 'ink', true)
	hub.brand:SetPoint('TOPLEFT', Kit.PAD + 4, -18)
	hub.heading = Kit:Label(hub, '', 'dim', 9)
	hub.heading:SetPoint('TOPLEFT', Kit.PAD + 5, -48)

	-- The header's keys are the reference's own baked keycaps at their full
	-- height (so the lip and depth read): round keys for sound and close, a
	-- legend key for Move UI, latching keys with lamps for the finish and the
	-- page toggles, and round color keys for the key colors. They are laid out
	-- right to left on a grid with measured widths, so nothing overlaps.
	local KEY_H = 32
	hub.close = Kit:Key(hub, {round = true, icon = 'close', width = KEY_H, height = KEY_H, iconSize = 12})
	hub.close.onClick = function()
		Kit:Play('latch-up')
		Kit:Close(hub)
	end
	Kit:AttachTooltip(hub.close, 'Close')
	hub.sound = Kit:Key(hub, {round = true, icon = 'speaker', width = KEY_H, height = KEY_H, iconSize = 13, toggle = true,
		checked = Kit:DB().sound.enable})
	hub.sound.onClick = function(self)
		Kit:SetOption('sound.enable', self.checked)
		if self.icon then Kit:Tint(self.icon, self.checked and 'ink' or 'dim') end
	end
	Kit:AttachTooltip(hub.sound, 'Sounds')
	-- Move UI: closes the hub and opens edit mode; lit while edit mode is on.
	hub.move = Kit:Key(hub, {text = 'Move UI', icon = 'grip', iconSize = 11, width = 112, height = KEY_H, led = true})
	if hub.move.led then
		hub.move.led:ClearAllPoints()
		hub.move.led:SetPoint('TOPRIGHT', hub.move.face, 'TOPRIGHT', -7, -7)
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
	Kit:AttachTooltip(hub.move, 'Edit mode: drag, snap and nudge every frame; a handle\'s gear opens its settings')
	if UI.OnMoversChanged then
		UI:OnMoversChanged(function(what)
			if what == '__lock' and hub.move.led then Kit:SetLed(hub.move.led, UI:MoversUnlocked() and true or false) end
		end)
	end
	-- The finish: two latching keys, one lit.
	local finishes = {'paper', 'graphite'}
	hub.finish = CreateFrame('Frame', nil, hub)
	hub.finish.keys = {}
	for index, name in ipairs({'Paper', 'Graphite'}) do
		local key = Kit:Key(hub.finish, {text = name, width = index == 1 and 78 or 96, height = KEY_H, led = true, sound = false})
		key.onClick = function()
			if hub.finish.value == index then return end
			Kit:Play('latch-down')
			hub.finish:SetValue(index)
			UI:HubChange('finish', finishes[index], {label = 'Finish', control = hub.finish,
				items = {{'paper', 'Paper'}, {'graphite', 'Graphite'}}})
		end
		hub.finish.keys[index] = key
	end
	hub.finish.keys[1]:SetPoint('LEFT', hub.finish, 'LEFT', 0, 0)
	hub.finish.keys[2]:SetPoint('LEFT', hub.finish.keys[1], 'RIGHT', 4, 0)
	hub.finish:SetSize(hub.finish.keys[1]:GetWidth() + 4 + hub.finish.keys[2]:GetWidth(), KEY_H)
	function hub.finish:SetValue(index)
		self.value = index
		for i, key in ipairs(self.keys) do key:SetChecked(i == index) end
	end
	hub.finish:SetValue(Kit:DB().finish == 'graphite' and 2 or 1)
	-- Key colors: the reference's round keys in each color, a lit ring on the chosen one.
	hub.accents = {}
	local SWATCH = 24
	local roundInfo = Kit.skin['key-round']
	for _, name in ipairs(Kit.accentOrder) do
		local swatch = CreateFrame('Button', nil, hub)
		swatch:SetSize(SWATCH, SWATCH)
		swatch.face = CreateFrame('Frame', nil, swatch)
		swatch.face:SetAllPoints()
		swatch.cap = swatch.face:CreateTexture(nil, 'ARTWORK')
		swatch.cap:SetTexture(Kit.media..[[Skin\key-round.tga]])
		local k = SWATCH / roundInfo.w
		Kit:Place(swatch.cap, swatch.face, roundInfo.l * k, roundInfo.t * k, roundInfo.r * k, roundInfo.b * k)
		local color = Kit.accentSkin[name].key
		swatch.cap:SetVertexColor(color[1], color[2], color[3])
		swatch.ring = Kit:Texture(swatch, 'circle-ring', 'BACKGROUND')
		swatch.ring:SetPoint('TOPLEFT', -4, 4)
		swatch.ring:SetPoint('BOTTOMRIGHT', 4, -4)
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
		swatch:SetScript('OnClick', function()
			if UI.db.accent ~= name then UI:HubChange('accent', name, {label = 'Key color', items = UI.AccentItems}) end
		end)
		Kit:AttachTooltip(swatch, Kit.accents[name] and Kit.accents[name].name or name)
		hub.accents[name] = swatch
	end
	BuildTools(KEY_H)
	-- How much each page shows: every option (Advanced), and a line of description.
	hub.advanced = Kit:Key(hub, {text = 'Advanced', width = 104, height = 30, textSize = 8, toggle = true,
		checked = UI.db.hub.advanced and true or false})
	hub.advanced.onClick = function(self)
		UI.db.hub.advanced = self.checked and true or false
		ForgetPages()
	end
	Kit:AttachTooltip(hub.advanced, 'Every option and whole notes')
	hub.describe = Kit:Key(hub, {text = 'Descriptions', width = 122, height = 30, textSize = 8, toggle = true,
		checked = UI.db.hub.describe and true or false})
	hub.describe.onClick = function(self)
		UI.db.hub.describe = self.checked and true or false
		ForgetPages()
	end
	Kit:AttachTooltip(hub.describe, 'A line under each setting')
	-- An LCD strip: the page's code and how many settings changed since opening.
	hub.lcd = Kit:LCDPanel(hub, {radius = 3})
	hub.lcd:SetSize(150, 24)
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
	hub.layoutHeader = LayoutHeader
	LayoutHeader()

	-- Sidebar: a search field over the reference's nav items (a lamp and a printed label).
	local divider = Kit:Solid(hub, 'line')
	divider:SetWidth(1)
	divider:SetPoint('TOPLEFT', Kit.PAD + SIDEBAR - 8, -92)
	divider:SetPoint('BOTTOMLEFT', Kit.PAD + SIDEBAR - 8, 18)
	hub.search = SearchField(hub, SIDEBAR - 20, function(text)
		if hub.searchTimer then hub.searchTimer:Cancel() end
		hub.searchTimer = C_Timer.NewTimer(0.12, function()
			hub.searchTimer = nil
			UI:Safe(Search, text)
		end)
	end)
	hub.search:SetPoint('TOPLEFT', Kit.PAD + 2, -92)
	hub.search.edit:SetScript('OnEscapePressed', function(self)
		self:ClearFocus()
		ClearSearch()
		SelectPage(UI.db.hub.page)
	end)
	BuildNav()

	hub:SetScale(UI.db.scale or 1)
	hub:SetScript('OnShow', function()
		Keyboard(true)
		UI:UpdateHub()
	end)
	hub:SetScript('OnHide', function(self)
		Keyboard(false)
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
	if hub.sound.icon then Kit:Tint(hub.sound.icon, db.sound.enable and 'ink' or 'dim') end
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
			UI:Safe(Relayout, page, true)
		end)
	end
	for _, control in ipairs(page and page.controls or {}) do
		if control.refresh and control ~= UI.changing then pcall(control.refresh) end
	end
	if page and page.refresh then pcall(page.refresh, page.area) end
end

function UI:ToggleHub(key, show)
	if not hub then
		-- Saves from before Quick setup open on it once.
		local db = UI.db.hub
		if not db.landed then
			db.landed = true
			if db.page == 'overview' then db.page = 'quick' end
		end
		Build()
	end
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
				UI:HubChange('style.'..area[1], values[i], {label = area[2]..' style', reload = true, items = area[3]})
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
		{'note', 'Commands: /spec opens this window and /spec help lists every command (Extras > Commands). /spec followed by any other word searches the settings for it.'},
	}},
}})
