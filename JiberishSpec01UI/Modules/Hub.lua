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
	end
end

-- Rows -----------------------------------------------------------------------
local ROW_HEIGHT = {switch = 34, segmented = 40, slider = 46, button = 38, color = 34, dropdown = 38, input = 42, note = 0, header = 24}
local NOTE_INDEX = {switch = 4, slider = 7, button = 5, color = 4, input = 4}

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
local function Changed(row, value, control)
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

local function BuildRow(card, row, y, width)
	local kind = row[1]
	if kind == 'note' then
		local text = Kit:Text(card.body, row[2], 9, 'dim')
		text:SetPoint('TOPLEFT', 0, -y)
		text:SetWidth(width)
		text:SetJustifyH('LEFT')
		return max(text:GetStringHeight(), 10) + 10
	elseif kind == 'header' then
		local text = Kit:Label(card.body, row[2], 'dim', 8, true)
		text:SetPoint('TOPLEFT', 0, -y - 6)
		local rule = Kit:Solid(card.body, 'line')
		rule:SetHeight(1)
		rule:SetPoint('LEFT', text, 'RIGHT', 8, 0)
		rule:SetPoint('RIGHT', card.body, 'RIGHT', 0, 0)
		return ROW_HEIGHT.header
	end
	local label = Kit:Label(card.body, row[2] or '', 'ink', 9)
	local left = 0
	if UI:IsNew(row.since) then
		local badge = Kit:Label(card.body, 'New', 'onAccent', 7, true)
		local chip = Kit:Solid(card.body, 'accent', 'BACKGROUND')
		badge:SetPoint('TOPLEFT', 4, -y - 1)
		chip:SetPoint('TOPLEFT', badge, 'TOPLEFT', -3, 2)
		chip:SetPoint('BOTTOMRIGHT', badge, 'BOTTOMRIGHT', 3, -2)
		left = badge:GetStringWidth() + 12
	end
	label:SetPoint('TOPLEFT', left, -y)
	local noteText = NoteOf(row)
	local controlWidth = 0
	local control
	if kind == 'switch' then
		control = Kit:Switch(card.body, {labels = false, checked = Get(row) and true or false,
			onChange = function(value, self) Changed(row, value, self) end})
		control:SetPoint('TOPRIGHT', -2, -y)
		control.refresh = function() control:SetValue(Get(row) and true or false) end
	elseif kind == 'segmented' then
		local values, names, current = {}, {}, 1
		for index, item in ipairs(row.items) do
			values[index], names[index] = item[1], item[2]
			if item[1] == Get(row) then current = index end
		end
		control = Kit:Segmented(card.body, {items = names, width = min(66 * #names, width * 0.62), value = current,
			onChange = function(index, self) Changed(row, values[index], self) end})
		control:SetPoint('TOPRIGHT', 0, -y + 2)
		control.refresh = function()
			local value = Get(row)
			for index, item in ipairs(values) do
				if item == value then control:SetValue(index) end
			end
		end
	elseif kind == 'slider' then
		control = Kit:Slider(card.body, {label = '', min = row[4], max = row[5], step = row[6], value = Get(row),
			width = width * 0.48, ticks = 10, format = row.format,
			onChange = function(value, self) Changed(row, value, self) end})
		control:SetPoint('TOPRIGHT', 0, -y + 12)
		control.refresh = function() control:SetValue(Get(row)) end
	elseif kind == 'button' then
		control = Kit:Button(card.body, {text = row[3], width = max(80, #row[3] * 8 + 28), height = 26})
		control:SetPoint('TOPRIGHT', 0, -y + 2)
		control.onClick = function() UI:Safe(row[4], control) end
	elseif kind == 'color' then
		control = Kit:ColorSwatch(card.body, {value = Get(row), onChange = function(value, self) Changed(row, value, self) end})
		control:SetPoint('TOPRIGHT', -2, -y + 2)
		control.refresh = function() control:SetValue(Get(row)) end
	elseif kind == 'dropdown' then
		control = Kit:Dropdown(card.body, {items = Items(row), value = Get(row), width = min(170, width * 0.5),
			onChange = function(value, self) Changed(row, value, self) end})
		control:SetPoint('TOPRIGHT', 0, -y + 2)
		control.refresh = function()
			if type(row.items) == 'function' then control:SetItems(Items(row)) end
			control:SetValue(Get(row))
		end
	elseif kind == 'input' then
		control = Kit:TextField(card.body, {width = min(170, width * 0.5), value = Get(row) or ''})
		control:SetPoint('TOPRIGHT', 0, -y + 4)
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
	else
		label:SetText(strupper(tostring(row[2] or kind)))
		return 20
	end
	controlWidth = control:GetWidth()
	Lockable(control, label, row)
	if control.refresh and row.disabled then control.refresh() end
	label:SetPoint('TOPRIGHT', card.body, 'TOPRIGHT', -controlWidth - 10, -y)
	label:SetJustifyH('LEFT')
	card.controls[#card.controls + 1] = control
	if noteText then
		local note = Kit:Text(card.body, noteText, 9, 'dim')
		note:SetPoint('TOPLEFT', 0, -y - 13)
		note:SetPoint('TOPRIGHT', card.body, 'TOPRIGHT', -controlWidth - 10, -y - 13)
		note:SetJustifyH('LEFT')
		note:SetWordWrap(true)
		return max(ROW_HEIGHT[kind], 15 + note:GetStringHeight() + 10)
	end
	return ROW_HEIGHT[kind]
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

local function BuildCards(content, page)
	local cards = {}
	local span = page.span or 2
	local width = span * Kit.COLUMN + (span - 1) * Kit.GAP
	page.controls = {}
	page.hiddenSignature = HiddenSignature(page)
	for index, spec in ipairs(page.cards) do
		local card = Kit.CardShell(content, index, spec.title, width, 200)
		card.span, card.controls = span, {}
		local y = 0
		for _, row in ipairs(spec.rows) do
			if not Test(row.hidden) then y = y + BuildRow(card, row, y, width - 24) end
		end
		card:SetHeight(28 + y + 10)
		cards[#cards + 1] = card
		for _, control in ipairs(card.controls) do page.controls[#page.controls + 1] = control end
	end
	page.cardFrames = cards
	return Kit:FlowCards(content, cards, CONTENT_COLUMNS)
end

-- Window ------------------------------------------------------------------------
local Search, ClearSearch

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
		local area = Kit:ScrollArea(hub, {width = hub:GetWidth() - SIDEBAR - Kit.PAD * 2, height = hub:GetHeight() - 78, step = 60})
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
	if Kit.Cascade then Kit:Cascade(page.cardFrames or {page.area.content:GetChildren()}) end
	if page.onShow then page.onShow(page.area) end
	for _, control in ipairs(page.controls or {}) do
		if control.refresh then pcall(control.refresh) end
	end
	hub.heading:SetText(strupper(page.title))
end

-- A page whose hidden rows changed is built again (its old frames stay hidden).
local function RebuildPage(page)
	if not page.area then return end
	local scroll = page.area.offset
	page.area:Hide()
	if page.onHide then page.onHide(page.area) end
	page.area, page.controls = nil, nil
	if UI.db.hub.page == page.key and hub:IsShown() then
		SelectPage(page.key)
		if scroll and page.area then page.area:ScrollTo(scroll) end
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
			for _, card in ipairs(page.cards or {}) do
				for _, row in ipairs(card.rows or {}) do
					local kind = row[1]
					if kind ~= 'header' and not Test(row.hidden) and type(row[2]) == 'string' then
						entries[#entries + 1] = {page = key, label = row[2], note = kind ~= 'note' and NoteOf(row) or nil,
							where = page.title..'  /  '..(card.title or ''), new = UI:IsNew(row.since), isNote = kind == 'note'}
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
		SelectPage(self.pageKey)
	end)
	return row
end

local function Results()
	if hub.results then return hub.results end
	local area = Kit:ScrollArea(hub, {width = hub:GetWidth() - SIDEBAR - Kit.PAD * 2, height = hub:GetHeight() - 78, step = 60})
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
		row.pageKey = entry.page
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
local NAV_TOP = 110
local function BuildNav()
	for _, entry in pairs(hub.nav or {}) do entry:Hide() end
	hub.nav = {}
	local shown = {}
	for _, key in ipairs(pageOrder) do
		if not pages[key].hidden then shown[#shown + 1] = key end
	end
	local gaps = 0
	for _, key in ipairs(shown) do if pages[key].gap then gaps = gaps + 1 end end
	local step = min(26, floor((hub:GetHeight() - NAV_TOP - 18 - gaps * 10) / max(#shown, 1)))
	local y, row = -NAV_TOP, 0
	for _, key in ipairs(shown) do
		local page = pages[key]
		if page.gap then y = y - 10 end
		local entry = CreateFrame('Button', nil, hub)
		entry:SetSize(SIDEBAR - 20, step - 2)
		entry:SetPoint('TOPLEFT', Kit.PAD + 4, y - row * step)
		row = row + 1
		entry.led = Kit:Led(entry, 5, false)
		entry.led:SetPoint('LEFT', 2, 0)
		entry.label = Kit:Label(entry, page.title, 'dim', 9)
		entry.label:SetPoint('LEFT', 14, 0)
		entry.status = Kit:Led(entry, 4, false)
		entry.status:SetPoint('RIGHT', -2, 0)
		entry.status:Hide()
		if PageIsNew(page) then
			entry.new = Kit:Label(entry, 'New', 'accentInk', 7, true)
			entry.new:SetPoint('RIGHT', -10, 0)
		end
		entry:SetScript('OnEnter', function(self) Kit:Tint(self.label, 'ink') end)
		entry:SetScript('OnLeave', function(self)
			if UI.db.hub.page ~= key or hub.searching then Kit:Tint(self.label, 'dim') end
		end)
		entry:SetScript('OnClick', function()
			if UI.db.hub.page == key and not hub.searching then return end
			Kit:Play('tick')
			SelectPage(key)
		end)
		hub.nav[key] = entry
	end
	hub.navDirty = nil
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
	tinsert(UISpecialFrames, 'JiberishSpec01Hub')

	-- Header: brand on the left, the page name, then the reference's own top bar
	-- controls on the right: key colors, finish, sound and close.
	hub.brand = Kit:Text(hub, 'JIBERISH / SPEC-01', 20, 'ink', true)
	hub.brand:SetPoint('TOPLEFT', Kit.PAD + 4, -18)
	hub.heading = Kit:Label(hub, '', 'dim', 9)
	hub.heading:SetPoint('TOPLEFT', Kit.PAD + 5, -44)

	hub.close = Kit:Button(hub, {round = true, icon = 'close', width = 28, height = 28, iconSize = 12})
	hub.close:SetPoint('TOPRIGHT', -Kit.PAD, -14)
	hub.close.onClick = function() Kit:Close(hub) end
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
	hub.finish:SetPoint('RIGHT', hub.sound, 'LEFT', -12, 1)
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
	hub.reload = Kit:Button(hub, {text = 'Reload UI', width = 96, height = 26})
	hub.reload:SetPoint('RIGHT', hub.accents[Kit.accentOrder[1]], 'LEFT', -18, 0)
	hub.reload.onClick = function() ReloadUI() end
	Kit:AttachTooltip(hub.reload, 'Style changes apply after a reload')
	hub.reload:SetShown(UI.reloadPending and true or false)

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
