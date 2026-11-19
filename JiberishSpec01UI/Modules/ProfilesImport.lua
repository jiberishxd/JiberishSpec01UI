-- Profile strings in and out: the PR-1 text sheet, the PR-2 import preview
-- (what a string would change, by hub page, before anything is applied), the
-- safety net (a "Before import" profile and an Undo toast), the export
-- options, and the automatic profile per specialization.
--
-- Profiles.lua owns the store and the string format; this file reaches them
-- through UI.ProfileStore. Setting paths are named by the hub rows that show
-- them: every registered page's rows are read, so a label here is the label
-- the player sees in the hub (the path itself where no row shows it).
local _, UI = ...
local Kit = UI.Kit
local Store = UI.ProfileStore
local PlainCall = UI.Util and UI.Util.PlainCall

local CreateFrame, UIParent = CreateFrame, UIParent
local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local ARROW = ' -> '

-- Hub rows by setting path -----------------------------------------------------------
-- The hub keeps its page list to itself, but UI:GetPage reads any page by key.
-- Keys are noted as pages register after this file loads; the pages registered
-- before it, and every settings section's own name, are tried as well.
local pageKeys = {}
local EARLY_PAGES = {'overview', 'theme', 'colors', 'housing', 'fonts', 'fade', 'motion', 'layout', 'setup', 'profiles',
	'components', 'about'}
if hooksecurefunc then
	hooksecurefunc(UI, 'RegisterPage', function(_, key) if type(key) == 'string' then pageKeys[key] = true end end)
end

local function PageOf(key)
	local page = UI.GetPage and UI:GetPage(key)
	return type(page) == 'table' and page or nil
end

local function PageKeys()
	local keys, seen = {}, {}
	local function Add(key)
		if type(key) == 'string' and not seen[key] and PageOf(key) then
			seen[key] = true
			keys[#keys + 1] = key
		end
	end
	for _, key in ipairs(EARLY_PAGES) do Add(key) end
	for key in pairs(pageKeys) do Add(key) end
	for key in pairs(type(UI.defaults) == 'table' and UI.defaults or {}) do Add(key) end
	table.sort(keys, function(a, b)
		local oa, ob = tonumber(PageOf(a).order) or 50, tonumber(PageOf(b).order) or 50
		if oa ~= ob then return oa < ob end
		return a < b
	end)
	return keys
end

local SETTING = {switch = true, slider = true, segmented = true, color = true, dropdown = true, input = true}
local function Top(path) return strmatch(path, '^[^.]+') end
local function Parent(path) return strmatch(path, '^(.+)%.[^.]+$') end
local function List(value) return type(value) == 'table' and value or {} end

-- Every setting row of one page under its path, with the label the hub shows:
-- under a header row the header comes first ("Unit frames / Size"); a label
-- used twice on the page gets its card's title in front.
local function IndexPage(index, page, rank, votes)
	local title = type(page.title) == 'string' and page.title or tostring(page.key)
	if not index.rank[title] then index.rank[title] = rank end
	local used = {}
	for _, card in ipairs(List(page.cards)) do
		for _, row in ipairs(List(card.rows)) do
			if type(row) == 'table' and SETTING[row[1]] and type(row[2]) == 'string' then used[row[2]] = (used[row[2]] or 0) + 1 end
		end
	end
	for _, card in ipairs(List(page.cards)) do
		local header
		for _, row in ipairs(List(card.rows)) do
			local path = type(row) == 'table' and row[3]
			if type(row) ~= 'table' then
				-- nothing
			elseif row[1] == 'header' then
				header = type(row[2]) == 'string' and row[2] or nil
			elseif SETTING[row[1]] and type(path) == 'string' and type(row[2]) == 'string' and not index.rows[path] then
				local label = row[2]
				if header then label = header..' / '..label
				elseif used[label] > 1 and type(card.title) == 'string' then label = card.title..' / '..label end
				index.seq = index.seq + 1
				index.rows[path] = {page = title, label = label, row = row, seq = index.seq}
				local top = Top(path)
				votes[top] = votes[top] or {}
				votes[top][title] = (votes[top][title] or 0) + 1
			end
		end
	end
end

-- index.rows[path] = {page, label, row}; index.tops[section] = the page showing
-- most of that section's rows; index.rank[page title] = its sidebar position.
local function BuildIndex()
	local index, votes = {rows = {}, tops = {}, rank = {}, movers = {}, styles = {}, seq = 0}, {}
	for rank, key in ipairs(PageKeys()) do IndexPage(index, PageOf(key), rank, votes) end
	for top, counts in pairs(votes) do
		local best, most
		for title, count in pairs(counts) do
			if not most or count > most or (count == most and index.rank[title] < index.rank[best]) then best, most = title, count end
		end
		index.tops[top] = best
	end
	-- The Layout page builds itself; its preset is named as its cards name it.
	local layout = PageOf('layout')
	if layout and not index.rows['layout.preset'] and UI.LayoutPresets then
		index.seq = index.seq + 1
		index.rows['layout.preset'] = {page = type(layout.title) == 'string' and layout.title or 'Layout', label = 'Preset', seq = index.seq,
			row = {'dropdown', 'Preset', 'layout.preset', items = function()
				local items = {}
				for _, preset in ipairs(List(UI:LayoutPresets())) do items[#items + 1] = {preset.key, preset.title} end
				return items
			end}}
	end
	if UI.GetMovers then
		local ok, list = pcall(UI.GetMovers, UI)
		for _, mover in ipairs(ok and List(list) or {}) do
			if type(mover) == 'table' and type(mover.key) == 'string' and type(mover.label) == 'string' then
				index.movers[mover.key] = mover.label
			end
		end
	end
	-- The Overview page builds itself; its interface styles are listed in UI.AREAS.
	for _, area in ipairs(List(UI.AREAS)) do
		if type(area) == 'table' and type(area[1]) == 'string' and type(area[2]) == 'string' then index.styles[area[1]] = area end
	end
	return index
end

-- Values in words -----------------------------------------------------------------------
local function Number(value)
	if value == floor(value) and abs(value) < 1e15 then return format('%d', value) end
	return (gsub(format('%.3f', value), '%.?0+$', ''))
end

local function Hex(value)
	if type(value) ~= 'table' then return nil end
	local r, g, b = value.r or value[1], value.g or value[2], value.b or value[3]
	if type(r) ~= 'number' or type(g) ~= 'number' or type(b) ~= 'number' then return nil end
	local function Byte(x) return floor(max(0, min(1, x)) * 255 + 0.5) end
	return format('#%02X%02X%02X', Byte(r), Byte(g), Byte(b))
end

local function Entries(value)
	local count = 0
	for _ in pairs(value) do count = count + 1 end
	return count == 1 and '1 entry' or format('%d entries', count)
end

local function Plain(value)
	local kind = type(value)
	if value == nil then return 'unset' end
	if kind == 'boolean' then return value and 'On' or 'Off' end
	if kind == 'number' then return Number(value) end
	if kind == 'string' then
		if value == '' then return '(empty)' end
		-- '__default', '__inherit': the addon's own markers, shown without the marks.
		if strsub(value, 1, 2) == '__' then value = strsub(value, 3) end
		return strupper(strsub(value, 1, 1))..strsub(value, 2)
	end
	if kind == 'table' then return Hex(value) or Entries(value) end
	return tostring(value)
end

local function Items(info)
	if info.items == nil then
		local items = info.row.items
		if type(items) == 'function' then
			local ok, result = pcall(items)
			items = ok and result or nil
		end
		info.items = type(items) == 'table' and items or false
	end
	return info.items or {}
end

-- A value as its hub row shows it: the option's name, On / Off, the slider's
-- own format, a color as hex.
local function Shown(info, value)
	local row = info and info.row
	if row and value ~= nil then
		local kind = row[1]
		if kind == 'segmented' or kind == 'dropdown' then
			for _, item in ipairs(Items(info)) do
				if type(item) == 'table' and item[1] == value and item[2] ~= nil then return tostring(item[2]) end
			end
		elseif kind == 'slider' and type(row.format) == 'function' and type(value) == 'number' then
			local ok, text = pcall(row.format, value)
			if ok and (type(text) == 'string' or type(text) == 'number') then return tostring(text) end
		elseif kind == 'color' and type(value) == 'table' then
			if type(value.from) == 'table' then return (Hex(value.from) or '?')..' / '..(Hex(value.to) or '?') end
		end
	end
	return Plain(value)
end

local function Spot(spot)
	if type(spot) ~= 'table' then return 'default spot' end
	local text = type(spot[1]) == 'number'
		and format('%s %s, %s', tostring(spot.anchor or 'CENTER'), Number(floor(spot[1] + 0.5)), Number(floor((spot[2] or 0) + 0.5)))
		or 'default spot'
	if type(spot.scale) == 'number' then text = text..' x'..Number(spot.scale) end
	if spot.hidden then text = text..', hidden' end
	return text
end

-- Comparing ---------------------------------------------------------------------------------
local function Same(a, b, depth)
	if a == b then return true end
	local kind = type(a)
	if kind ~= type(b) then return false end
	if kind == 'number' then return abs(a - b) <= 1e-9 * max(1, abs(a), abs(b)) end
	if kind ~= 'table' or (depth or 0) > 30 then return false end
	for key, value in pairs(a) do
		if not Same(value, b[key], (depth or 0) + 1) then return false end
	end
	for key in pairs(b) do
		if a[key] == nil then return false end
	end
	return true
end

local function Keys(a, b)
	local keys, seen = {}, {}
	for _, source in pairs({a or false, b or false}) do
		if source then
			for key in pairs(source) do
				if not seen[key] then seen[key] = true; keys[#keys + 1] = key end
			end
		end
	end
	table.sort(keys, function(x, y)
		local tx, ty = type(x), type(y)
		if tx == 'number' and ty == 'number' then return x < y end
		if tx ~= ty then return tx < ty end
		return tostring(x) < tostring(y)
	end)
	return keys
end

-- The nearest hub row at or above a path, and what is left of the path below it.
local function Locate(index, path)
	local probe, rest = path, nil
	while probe do
		local info = index.rows[probe]
		if info then return info, rest end
		local parent = Parent(probe)
		if not parent then return nil end
		local leaf = strsub(probe, #parent + 2)
		rest = rest and leaf..'.'..rest or leaf
		probe = parent
	end
end

local function Titled(word) return strupper(strsub(word, 1, 1))..strsub(word, 2) end

local function Entry(index, path, old, new)
	local entry = {path = path, old = old, new = new}
	local top = Top(path)
	local info, rest = Locate(index, path)
	if top == 'style' and index.styles[strsub(path, 7)] then
		local area = index.styles[strsub(path, 7)]
		-- Interface styles are chosen on the Overview page and load after a reload.
		info = {row = {'segmented', items = area[3]}}
		entry.group, entry.rank, entry.label, entry.reload = 'Interface styles', 0.5, area[2]..' style', true
	elseif info then
		entry.group = info.page
		entry.label = rest and (info.label..' ('..rest..')') or info.label
		entry.reload = info.row.reload and true or false
		entry.seq = info.seq
		if rest then info = nil end
	else
		local page = PageOf(top)
		entry.group = index.tops[top] or (page and type(page.title) == 'string' and page.title) or Titled(top)
		-- No row shows it: the path below its section ("preset" under Layout); the tooltip has it whole.
		entry.label = Parent(path) and strsub(path, #top + 2) or path
	end
	entry.rank = entry.rank or index.rank[entry.group] or 500
	entry.oldText, entry.newText = Shown(info, old), Shown(info, new)
	return entry
end

-- Settings that belong to the hub window itself (its page, NEW markers seen).
local IGNORE = {hub = true}

local function Walk(index, old, new, path, out, depth)
	for _, key in ipairs(Keys(old, new)) do
		local name = tostring(key)
		local sub = path and (path..'.'..name) or name
		local a, b = old and old[key], new and new[key]
		if not (path == nil and IGNORE[name]) and not Same(a, b) then
			if path == nil and name == 'movers' then
				-- One change per frame, named as the mover handles name it.
				local ma, mb = type(a) == 'table' and a or nil, type(b) == 'table' and b or nil
				for _, frame in ipairs(Keys(ma, mb)) do
					local x, y = ma and ma[frame], mb and mb[frame]
					if not Same(x, y) then
						out[#out + 1] = {path = 'movers.'..tostring(frame), group = 'Frame positions', rank = 10000, mover = true,
							label = index.movers[frame] or tostring(frame), old = x, new = y, oldText = Spot(x), newText = Spot(y)}
					end
				end
			else
				local info = index.rows[sub]
				local whole = info and info.row[1] == 'color'
				local ta, tb = type(a), type(b)
				if not whole and depth < 12 and (ta == 'table' or tb == 'table') and (ta == tb or a == nil or b == nil) then
					Walk(index, ta == 'table' and a or nil, tb == 'table' and b or nil, sub, out, depth + 1)
				else
					out[#out + 1] = Entry(index, sub, a, b)
				end
			end
		end
	end
	return out
end

local function Diff(index, current, target) return Walk(index, current, target, nil, {}, 0) end

local function GroupSummary(group)
	local count = #group.changes
	if group.movers then return format(count == 1 and '%d frame' or '%d frames', count) end
	if count > 2 then return format('%d settings', count) end
	local parts = {}
	for i, entry in ipairs(group.changes) do parts[i] = entry.label..' '..entry.oldText..ARROW..entry.newText end
	return table.concat(parts, ', ')
end

-- Changes by hub page, in sidebar order (interface styles first, frame positions last).
local function Summarize(changes)
	local groups, byTitle = {}, {}
	local counts = {changes = #changes, settings = 0, frames = 0, reload = 0, areas = 0}
	for _, entry in ipairs(changes) do
		local group = byTitle[entry.group]
		if not group then
			group = {title = entry.group, rank = entry.rank, changes = {}, reload = 0, movers = entry.mover}
			byTitle[entry.group] = group
			groups[#groups + 1] = group
		end
		group.changes[#group.changes + 1] = entry
		if entry.reload then group.reload = group.reload + 1; counts.reload = counts.reload + 1 end
		if entry.mover then counts.frames = counts.frames + 1 else counts.settings = counts.settings + 1 end
	end
	table.sort(groups, function(a, b)
		if a.rank ~= b.rank then return a.rank < b.rank end
		return a.title < b.title
	end)
	for _, group in ipairs(groups) do
		-- In the order the page shows its rows; settings no row shows go last.
		table.sort(group.changes, function(a, b)
			local sa, sb = a.seq or 1e9, b.seq or 1e9
			if sa ~= sb then return sa < sb end
			return a.path < b.path
		end)
		group.summary = GroupSummary(group)
		if not group.movers then counts.areas = counts.areas + 1 end
	end
	return groups, counts
end

-- "Theme: Finish Paper -> Graphite, Accent Red -> Green; Unit frames: 12 settings"
local function SummaryLine(groups)
	local parts = {}
	for i, group in ipairs(groups) do parts[i] = group.title..': '..group.summary end
	return table.concat(parts, '; ')
end

-- What applying would leave --------------------------------------------------------------
-- Appearance: the Theme, Colors, Housing and Fonts pages (fade has its own page).
local APPEARANCE = {finish = true, accent = true, customAccent = true, font = true, housingAlpha = true, appearance = true,
	colors = true, housing = true, fonts = true}

local function GetPath(node, path)
	for key in gmatch(path, '[^.]+') do
		if type(node) ~= 'table' then return nil end
		node = node[key]
	end
	return node
end

local function SetPath(node, path, value)
	local parent, leaf = Parent(path), strmatch(path, '[^.]+$')
	if parent then
		for key in gmatch(parent, '[^.]+') do
			if type(node[key]) ~= 'table' then node[key] = {} end
			node = node[key]
		end
	end
	node[leaf] = value
end

-- The settings as they would be after an import in this mode: 'all', 'positions'
-- (everything but frame positions) or 'appearance'. What belongs to this
-- computer (the private paths) and the hub window's own state stay as they are;
-- a string without frame positions keeps the current ones.
local function Target(current, data, mode)
	local target
	if mode == 'appearance' then
		target = Store.Copy(current)
		local full = Store.Fill(Store.Copy(data), UI.defaults or {})
		if UI.Migrate then UI:Migrate(full) end
		for key in pairs(APPEARANCE) do target[key] = Store.Copy(full[key], 1) end
		if type(target.appearance) == 'table' then
			target.appearance.fade = Store.Copy(type(current.appearance) == 'table' and current.appearance.fade or nil, 1)
		end
	else
		target = Store.Copy(data)
		if mode == 'positions' or data.movers == nil then target.movers = Store.Copy(current.movers, 1) end
		target.hub = Store.Copy(current.hub, 1)
		for _, path in ipairs(Store.PRIVATE) do
			local joined = table.concat(path, '.')
			SetPath(target, joined, Store.Copy(GetPath(current, joined), 1))
		end
	end
	Store.Fill(target, UI.defaults or {})
	if UI.Migrate then UI:Migrate(target) end
	return target
end

local MODES = {'all', 'positions', 'appearance'}

-- Everything the PR-2 device shows, for one decoded string.
local function Preview(data, name, info, current)
	current = current or Store.Copy(UI.db)
	local index = BuildIndex()
	local preview = {data = data, name = name, info = info or {}, modes = {}}
	for _, mode in ipairs(MODES) do
		local target = Target(current, data, mode)
		local changes = Diff(index, current, target)
		local groups, counts = Summarize(changes)
		preview.modes[mode] = {target = target, changes = changes, groups = groups, counts = counts}
	end
	return preview
end

-- Shared with the offline test (tests/lua/profiles_import.lua).
UI.ProfileImport = {BuildIndex = BuildIndex, Diff = Diff, Summarize = Summarize, SummaryLine = SummaryLine, Target = Target,
	Preview = Preview, Same = Same, Shown = Shown}

-- Applying, and the safety net -------------------------------------------------------------
local function Stamp()
	local ok, text = pcall(date, '%Y-%m-%d %H:%M')
	return ok and type(text) == 'string' and text or tostring(floor(GetTime()))
end

-- Repaint, put frames in their new spots (out of combat) and light the reload key.
local function Settle(frames, reload)
	Kit:Apply()
	if frames and UI.PlaceAllMovers then
		UI:AfterCombat(function() UI:Safe(UI.PlaceAllMovers, UI) end, 'profileImportMovers')
	end
	if reload and UI.NeedsReload then UI:NeedsReload() end
end

local function OfferReload(text)
	Kit:Dialog({title = 'Reload to apply', text = text, tone = 'warning', width = 340,
		actions = {{text = 'Later'}, {text = 'Reload', tone = 'primary', reload = true}}})
end

function UI:LastImport()
	local store = Store.Live()
	local name = store.lastImport
	if type(name) == 'string' and type(store.profiles[name]) == 'table' then return name end
	return nil
end

local function Count(count, one, many) return format(count == 1 and one or many, count) end

-- Apply a preview in one of its modes. The settings in use are kept first as a
-- "Before import" profile; the toast that follows can put them back.
function UI:ApplyImport(preview, mode)
	local plan = preview and preview.modes[mode]
	if not plan or #plan.changes == 0 then return false end
	local store = Store.Live()
	local snapshot = Store.UniqueName('Before import '..Stamp())
	store.profiles[snapshot] = Store.Copy(UI.db)
	store.lastImport = snapshot
	Store.LoadInto(UI.db, plan.target)
	store.profiles[store.live] = Store.Copy(UI.db)
	local counts = plan.counts
	-- Appearance repaints at once; a whole profile also reaches modules that keep their own copies.
	local reload = counts.reload > 0 or mode ~= 'appearance'
	Settle(counts.frames > 0, reload)
	Kit:Play('success')
	Kit:Toast({title = 'Import applied', tone = 'success', duration = 15,
		text = format('%s. Your previous settings are kept as "%s".', Count(counts.changes, '1 change', '%d changes'), snapshot),
		action = {text = 'Undo', onClick = function() UI:UndoImport() end}})
	if reload then
		local names = {}
		for _, entry in ipairs(plan.changes) do
			if entry.reload and #names < 3 then names[#names + 1] = entry.label end
		end
		OfferReload(#names > 0
			and format('%s after a reload (%s%s). Everything else already shows.', Count(counts.reload, '1 change applies', '%d changes apply'),
				table.concat(names, ', '), counts.reload > #names and ', ...' or '')
			or 'The new settings show now; parts of the interface that keep their own copy pick them up after a reload.')
	end
	return true
end

-- Put back the settings from before the last import.
function UI:UndoImport()
	local store = Store.Live()
	local name = UI:LastImport()
	if not name then
		Kit:Toast({title = 'Nothing to undo', text = 'The settings from before the last import are no longer saved.', tone = 'warning'})
		return false
	end
	local saved = store.profiles[name]
	local frames = not Same(UI.db.movers, saved.movers)
	Store.LoadInto(UI.db, saved)
	store.profiles[store.live] = Store.Copy(UI.db)
	store.lastImport = nil
	Settle(frames, true)
	Kit:Toast({title = 'Import undone', tone = 'success', duration = 12,
		text = format('Your settings from before the import are back (still kept as "%s"). Reload to apply them everywhere.', name),
		action = {text = 'Reload', reload = true}})
	return true
end

-- The string's settings as a profile of their own, as before 0.6: nothing in use changes.
function UI:SaveImport(preview)
	local name = Store.UniqueName(preview.name)
	Store.Live().profiles[name] = Store.Copy(preview.data)
	Kit:Play('success')
	Kit:Apply()
	Kit:AlertDialog({title = 'Profile saved', text = format('Saved as "%s". Use it on this character now?', name),
		confirm = 'Use it', onConfirm = function() UI:SwitchProfile(name) end})
	return name
end

-- The text sheet: a device with a black display holding the string --------------------------
local sheet, ShowPreview
local function Status(text, token)
	sheet.status:SetText(text or '')
	Kit:Tint(sheet.status, token or 'dim')
	Kit:SetLed(sheet.lamp, true, token == 'red' and 'red' or nil)
end

local function Sheet()
	if sheet then return sheet end
	sheet = Kit:Device(UIParent, {model = 'PR-1', title = 'Profile string', width = 480, height = 330, name = 'JiberishSpec01ProfileSheet'})
	sheet:SetFrameStrata('FULLSCREEN_DIALOG')
	sheet:SetFrameLevel(300)
	Kit:Relevel(sheet)
	sheet:SetPoint('CENTER', 0, 40)
	sheet:EnableMouse(true)
	sheet:SetMovable(true)
	sheet:SetClampedToScreen(true)
	sheet:RegisterForDrag('LeftButton')
	sheet:SetScript('OnDragStart', sheet.StartMoving)
	sheet:SetScript('OnDragStop', sheet.StopMovingOrSizing)
	tinsert(UISpecialFrames, 'JiberishSpec01ProfileSheet')
	Kit:SetLed(sheet.lamp, true)
	sheet.hint = Kit:Text(sheet, '', 9, 'dim')
	sheet.hint:SetPoint('TOPLEFT', 14, -28)
	sheet.hint:SetPoint('TOPRIGHT', -14, -28)
	sheet.hint:SetJustifyH('LEFT')
	local screen = Kit:Screen(sheet, {inset = 3, radius = 6})
	screen:SetPoint('TOPLEFT', 12, -54)
	screen:SetPoint('BOTTOMRIGHT', -12, 64)
	local scroll = CreateFrame('ScrollFrame', nil, screen.screen)
	scroll:SetPoint('TOPLEFT', 8, -8)
	scroll:SetPoint('BOTTOMRIGHT', -8, 8)
	local edit = CreateFrame('EditBox', nil, scroll)
	edit:SetMultiLine(true)
	edit:SetAutoFocus(false)
	edit:SetMaxLetters(0)
	Kit:Font(edit, 10)
	Kit:Tint(edit, 'darkInk')
	edit:SetWidth(400)
	scroll:SetScrollChild(edit)
	scroll:SetScript('OnSizeChanged', function(self, width) edit:SetWidth(max(width, 10)) end)
	scroll:EnableMouseWheel(true)
	scroll:SetScript('OnMouseWheel', function(self, delta)
		self:SetVerticalScroll(Kit:Clamp(self:GetVerticalScroll() - delta * 30, 0, self:GetVerticalScrollRange()))
	end)
	edit:SetScript('OnCursorChanged', function(_, _, y, _, height)
		local top, view = scroll:GetVerticalScroll(), scroll:GetHeight()
		y = -y
		if y < top then scroll:SetVerticalScroll(y)
		elseif y + height > top + view then scroll:SetVerticalScroll(y + height - view) end
	end)
	edit:SetScript('OnEscapePressed', function() Kit:Close(sheet) end)
	-- An export can be selected and copied but not changed. A paste is kept
	-- (closing the sheet or a failed read does not lose it) until it is used.
	edit:SetScript('OnTextChanged', function(self, user)
		if sheet.readOnly then
			if user then
				self:SetText(sheet.value or '')
				self:HighlightText()
			end
		elseif user then
			sheet.draft = self:GetText()
			if sheet.failed then
				sheet.failed = nil
				Status('')
			end
		end
	end)
	edit:SetScript('OnEditFocusGained', function(self) if sheet.readOnly then self:HighlightText() end end)
	edit:SetScript('OnChar', function(_, character)
		if not sheet.readOnly then Kit:Play(character == ' ' and 'type-space' or 'type') end
	end)
	screen.screen:EnableMouse(true)
	screen.screen:SetScript('OnMouseDown', function() edit:SetFocus() end)
	sheet.edit = edit
	sheet.primary = Kit:Key(sheet, {width = 96, height = 28, tone = 'primary', text = 'Preview'})
	sheet.primary:SetPoint('BOTTOMRIGHT', -14, 14)
	sheet.closeKey = Kit:Key(sheet, {width = 84, height = 28, text = 'Close'})
	sheet.closeKey:SetPoint('RIGHT', sheet.primary, 'LEFT', -8, 0)
	sheet.closeKey.onClick = function() Kit:Close(sheet) end
	-- Export: frame positions in or out, on a switch with its printed legend.
	sheet.positions = Kit:Switch(sheet, {labels = false, checked = true, onChange = function(value)
		Store.Live().exportPositions = value and true or false
		UI:ShowExport(true)
	end})
	sheet.positions:SetPoint('BOTTOMLEFT', 16, 20)
	sheet.positionsLegend = Kit:Label(sheet, 'Positions', 'dim', 7)
	sheet.positionsLegend:SetPoint('LEFT', sheet.positions, 'RIGHT', 6, 0)
	sheet.status = Kit:Text(sheet, '', 9, 'dim')
	sheet.status:SetJustifyH('LEFT')
	sheet.status:SetJustifyV('BOTTOM')
	sheet.status:SetWordWrap(true)
	if sheet.status.SetMaxLines then sheet.status:SetMaxLines(3) end
	sheet:Hide()
	return sheet
end

-- The status line sits beside the keys; in an export it starts after the positions switch.
local function PlaceStatus(afterSwitch)
	sheet.status:ClearAllPoints()
	if afterSwitch then sheet.status:SetPoint('BOTTOMLEFT', sheet.positionsLegend, 'BOTTOMRIGHT', 12, -4)
	else sheet.status:SetPoint('BOTTOMLEFT', 16, 18) end
	sheet.status:SetPoint('RIGHT', sheet.closeKey, 'LEFT', -10, 0)
end

local function Thousands(n)
	local text = tostring(n)
	while true do
		local done
		text, done = gsub(text, '^(%d+)(%d%d%d)', '%1,%2')
		if done == 0 then return text end
	end
end

-- A short line on what an export holds: settings that differ from the defaults
-- (in how many hub pages), frame positions, length.
local function ExportSummary(data, value)
	local base = Store.Fill({}, UI.defaults or {})
	if UI.Migrate then UI:Migrate(base) end
	local full = Store.Fill(Store.Copy(data), UI.defaults or {})
	local _, counts = Summarize(Diff(BuildIndex(), base, full))
	local frames = 0
	for _ in pairs(type(data.movers) == 'table' and data.movers or {}) do frames = frames + 1 end
	return format('%s in %s  /  %s  /  %s characters',
		Count(counts.settings, '1 setting changed', '%d settings changed'), Count(counts.areas, '1 page', '%d pages'),
		data.movers and Count(frames, '1 frame position', '%d frame positions') or 'no frame positions', Thousands(#value))
end

function UI:ShowExport(refresh)
	local frame = Sheet()
	local positions = Store.Live().exportPositions ~= false
	local data = Store.StripPrivate(Store.Copy(UI.db))
	if not positions then data.movers = nil end
	frame.readOnly = true
	frame.value = UI:EncodeProfile(data, UI:ActiveProfile(), {positions = positions})
	frame.title:SetText(strupper('Export  /  '..UI:ActiveProfile()))
	frame.hint:SetText(positions
		and 'Every setting in this profile as one line of text, frame positions included. Copy it with Ctrl+C and paste it into the Import sheet on any character.'
		or 'Every setting in this profile as one line of text, without frame positions: whoever imports it keeps their own. Copy it with Ctrl+C.')
	frame.edit:SetText(frame.value)
	frame.primary:Hide()
	frame.positions:Show()
	frame.positionsLegend:Show()
	frame.positions:SetValue(positions)
	PlaceStatus(true)
	local ok, summary = pcall(ExportSummary, data, frame.value)
	Status(ok and summary or format('%s characters', Thousands(#frame.value)))
	if not refresh then Kit:Open(frame) end
	frame.edit:SetFocus()
	frame.edit:HighlightText()
end

-- Read the pasted text: a plain-words problem under it, or the PR-2 preview.
local function ReadPaste()
	local frame = sheet
	local data, name, info = UI:DecodeProfile(frame.edit:GetText())
	if not data then
		frame.failed = true
		Status(name, 'red')
		Kit:Play('error')
		return
	end
	local ok, preview = pcall(Preview, data, name, info)
	if not ok then
		frame.failed = true
		Status('The string was read, but comparing it with your settings failed: '..tostring(preview), 'red')
		Kit:Play('error')
		return
	end
	Kit:Close(frame)
	ShowPreview(preview)
end

function UI:ShowImport()
	local frame = Sheet()
	frame.readOnly = false
	frame.value = nil
	frame.failed = nil
	frame.title:SetText('IMPORT')
	frame.hint:SetText('Paste a SPEC-01 profile string, then press Preview to see what it would change. Nothing changes until you choose.')
	frame.edit:SetText(frame.draft or '')
	frame.primary:Show()
	frame.primary:SetKeyText('Preview')
	frame.positions:Hide()
	frame.positionsLegend:Hide()
	PlaceStatus(false)
	Status(frame.draft and frame.draft ~= '' and 'Your last paste is still here.' or '')
	frame.primary.onClick = ReadPaste
	Kit:Open(frame)
	frame.edit:SetFocus()
end

-- The PR-2 import preview --------------------------------------------------------------
local PREVIEW_W, PREVIEW_H, GROUP_H, LINE_H = 560, 500, 36, 16
local SCOPES = {{'all', 'Everything', 'Apply all'}, {'positions', 'No positions', 'Apply without positions'},
	{'appearance', 'Appearance', 'Apply appearance only'}}
local device

local function PreviewLCD(parent, tag, x)
	local lcd = Kit:LCD(parent, {tag = tag, size = 'sm', width = 78, ghost = '8888'})
	lcd:SetPoint('TOPLEFT', x, -60)
	lcd.led = Kit:Led(lcd, 4, false)
	lcd.led:SetPoint('TOPRIGHT', -7, -7)
	Kit:ShowLed(lcd.led, false)
	return lcd
end

local function GroupRow(list, index)
	local row = list.groupRows[index]
	if row then return row end
	row = CreateFrame('Button', nil, list.content)
	row:SetHeight(GROUP_H - 4)
	row.hover = Kit:Solid(row, 'darkEdge', 'BACKGROUND', 0, 0.55)
	row.hover:SetAllPoints()
	row.hover:Hide()
	row.lamp = Kit:Led(row, 5, true)
	row.lamp:SetPoint('TOPLEFT', 4, -7)
	row.title = Kit:Label(row, '', 'darkInk', 9)
	row.title:SetPoint('TOPLEFT', 16, -4)
	row.reload = Kit:Label(row, 'Reload', 'amber', 7)
	row.reload:SetPoint('LEFT', row.title, 'RIGHT', 8, 0)
	row.caret = Kit:Label(row, '+', 'darkDim', 9)
	row.caret:SetPoint('TOPRIGHT', -4, -4)
	row.count = Kit:Text(row, '', 9, 'screenAccent')
	Kit:Font(row.count, 9, nil, true, 'numbers')
	row.count:SetPoint('RIGHT', row.caret, 'LEFT', -8, 0)
	row.summary = Kit:Text(row, '', 9, 'darkDim')
	row.summary:SetPoint('TOPLEFT', 16, -18)
	row.summary:SetPoint('RIGHT', -4, 0)
	row.summary:SetJustifyH('LEFT')
	row.summary:SetWordWrap(false)
	row:SetScript('OnEnter', function(self) self.hover:Show(); Kit:Play('tick') end)
	row:SetScript('OnLeave', function(self) self.hover:Hide() end)
	row:SetScript('OnClick', function(self)
		local open = not list.expanded[self.group.title]
		list.expanded[self.group.title] = open or nil
		Kit:Play(open and 'latch-down' or 'latch-up')
		list:Arrange()
	end)
	list.groupRows[index] = row
	return row
end

local function ChangeRow(list, index)
	local row = list.changeRows[index]
	if row then return row end
	row = CreateFrame('Frame', nil, list.content)
	row:SetHeight(LINE_H)
	row:EnableMouse(true)
	row.dot = Kit:Led(row, 4, true)
	row.dot:SetPoint('LEFT', 18, 0)
	row.label = Kit:Text(row, '', 9, 'darkInk')
	row.label:SetPoint('LEFT', 28, 0)
	row.label:SetJustifyH('LEFT')
	row.label:SetWordWrap(false)
	row.value = Kit:Text(row, '', 9, 'darkDim')
	row.value:SetPoint('RIGHT', -4, 0)
	row.value:SetJustifyH('RIGHT')
	row.value:SetWordWrap(false)
	Kit:AttachTooltip(row, function(self)
		local entry = self.entry
		return entry and (entry.path..':  '..entry.oldText..ARROW..entry.newText) or ''
	end)
	list.changeRows[index] = row
	return row
end

local function BuildList(parent)
	local list = Kit:ScrollArea(parent, {width = PREVIEW_W - 48, height = 280, smooth = true, step = 48})
	list.groupRows, list.changeRows, list.expanded = {}, {}, {}
	list.empty = Kit:Text(list.content, '', 10, 'darkDim')
	list.empty:SetPoint('TOPLEFT', 8, -12)
	list.empty:SetPoint('RIGHT', -8, 0)
	list.empty:SetJustifyH('LEFT')
	function list:Arrange()
		local width = self:GetWidth() - 12
		if not width or width < 100 then width = PREVIEW_W - 60 end
		local groups = self.groups or {}
		for _, row in ipairs(self.groupRows) do row:Hide() end
		for _, row in ipairs(self.changeRows) do row:Hide() end
		local y, used = 0, 0
		for index, group in ipairs(groups) do
			local row = GroupRow(self, index)
			row.group = group
			row:ClearAllPoints()
			row:SetPoint('TOPLEFT', self.content, 'TOPLEFT', 0, -y)
			row:SetWidth(width)
			row.title:SetText(strupper(group.title))
			row.count:SetText(tostring(#group.changes))
			row.summary:SetText(group.summary)
			row.reload:SetShown(group.reload > 0)
			Kit:SetLed(row.lamp, true, group.reload > 0 and 'amber' or nil)
			local open = self.expanded[group.title]
			row.caret:SetText(open and '-' or '+')
			row:Show()
			y = y + GROUP_H
			if open then
				local labelWidth = floor((width - 32) * 0.5)
				for _, entry in ipairs(group.changes) do
					used = used + 1
					local line = ChangeRow(self, used)
					line.entry = entry
					line:ClearAllPoints()
					line:SetPoint('TOPLEFT', self.content, 'TOPLEFT', 0, -y)
					line:SetWidth(width)
					line.label:SetWidth(labelWidth)
					line.label:SetText(entry.label)
					line.value:SetWidth(width - labelWidth - 36)
					line.value:SetText(entry.oldText..ARROW..entry.newText)
					Kit:ShowLed(line.dot, entry.reload and true or false)
					Kit:SetLed(line.dot, true, 'amber')
					Kit:Tint(line.label, entry.reload and 'screenAccent' or 'darkInk')
					line:Show()
					y = y + LINE_H
				end
				y = y + 6
			end
		end
		self.empty:SetShown(#groups == 0)
		self.content:SetHeight(max(y, 1))
		self:Refresh()
	end
	return list
end

local function Device()
	if device then return device end
	device = Kit:Device(UIParent, {model = 'PR-2', title = 'Import', width = PREVIEW_W, height = PREVIEW_H, name = 'JiberishSpec01ImportPreview'})
	device:SetFrameStrata('FULLSCREEN_DIALOG')
	device:SetFrameLevel(300)
	Kit:Relevel(device)
	device:SetPoint('CENTER', 0, 30)
	device:EnableMouse(true)
	device:SetMovable(true)
	device:SetClampedToScreen(true)
	device:RegisterForDrag('LeftButton')
	device:SetScript('OnDragStart', device.StartMoving)
	device:SetScript('OnDragStop', device.StopMovingOrSizing)
	tinsert(UISpecialFrames, 'JiberishSpec01ImportPreview')
	Kit:SetLed(device.lamp, true)
	device.info = Kit:Text(device, '', 9, 'ink')
	device.info:SetPoint('TOPLEFT', 14, -28)
	device.info:SetPoint('TOPRIGHT', -14, -28)
	device.info:SetJustifyH('LEFT')
	device.info:SetWordWrap(false)
	device.note = Kit:Text(device, '', 9, 'dim')
	device.note:SetPoint('TOPLEFT', 14, -42)
	device.note:SetPoint('TOPRIGHT', -14, -42)
	device.note:SetJustifyH('LEFT')
	device.note:SetWordWrap(false)
	device.lcds = {}
	for index, tag in ipairs({'Changes', 'Pages', 'Frames', 'Reload'}) do
		device.lcds[index] = PreviewLCD(device, tag, 14 + (index - 1) * 86)
	end
	-- Which part of the string to apply; the list, the counts and the Apply key follow it.
	device.scopeLegend = Kit:Label(device, 'Apply', 'dim', 7)
	device.scopeLegend:SetPoint('TOPLEFT', 14, -110)
	local names = {}
	for index, scope in ipairs(SCOPES) do names[index] = scope[2] end
	device.scope = Kit:Segmented(device, {items = names, width = PREVIEW_W - 70 - 14, value = 1,
		onChange = function(index) device.mode = SCOPES[index][1]; device:ShowPlan() end})
	device.scope:SetPoint('TOPLEFT', 56, -100)
	local screen = Kit:Screen(device, {inset = 3, radius = 6})
	screen:SetPoint('TOPLEFT', 12, -140)
	screen:SetPoint('BOTTOMRIGHT', -12, 58)
	device.list = BuildList(screen.screen)
	device.list:SetPoint('TOPLEFT', 8, -8)
	device.list:SetPoint('BOTTOMRIGHT', -6, 8)
	device.apply = Kit:Key(device, {width = 176, height = 30, tone = 'primary', text = 'Apply all'})
	device.apply:SetPoint('BOTTOMRIGHT', -14, 14)
	device.apply.onClick = function()
		local preview, mode = device.preview, device.mode
		device.preview = nil
		Kit:Close(device)
		if UI:ApplyImport(preview, mode) and sheet then sheet.draft = nil end
	end
	device.save = Kit:Key(device, {width = 128, height = 30, text = 'Save as profile'})
	device.save:SetPoint('RIGHT', device.apply, 'LEFT', -8, 0)
	device.save.onClick = function()
		local preview = device.preview
		device.preview = nil
		Kit:Close(device)
		UI:SaveImport(preview)
		if sheet then sheet.draft = nil end
	end
	device.cancel = Kit:Key(device, {width = 80, height = 30, text = 'Cancel'})
	device.cancel:SetPoint('RIGHT', device.save, 'LEFT', -8, 0)
	-- Back to the sheet, the paste still in it.
	device.cancel.onClick = function()
		device.preview = nil
		Kit:Close(device, function() UI:ShowImport() end)
	end
	-- A printed legend for the amber lamps.
	device.legendLamp = Kit:Led(device, 5, true)
	device.legendLamp:SetPoint('BOTTOMLEFT', 18, 26)
	Kit:SetLed(device.legendLamp, true, 'amber')
	device.legend = Kit:Label(device, 'Needs a reload', 'dim', 7)
	device.legend:SetPoint('LEFT', device.legendLamp, 'RIGHT', 6, 0)

	function device:ShowPlan()
		local preview = self.preview
		local plan = preview.modes[self.mode]
		local counts = plan.counts
		local values = {counts.changes, counts.areas, counts.frames, counts.reload}
		for index, lcd in ipairs(self.lcds) do lcd:SetText(tostring(min(values[index], 9999))) end
		local reloadLed = self.lcds[4].led
		Kit:ShowLed(reloadLed, counts.reload > 0)
		Kit:SetLed(reloadLed, counts.reload > 0, 'amber')
		for _, scope in ipairs(SCOPES) do
			if scope[1] == self.mode then self.apply:SetKeyText(scope[3]) end
		end
		self.apply:SetKeyEnabled(counts.changes > 0)
		self.legendLamp:SetShown(counts.reload > 0)
		self.legend:SetShown(counts.reload > 0)
		self.list.groups = plan.groups
		self.list.empty:SetText(self.mode == 'appearance'
			and 'The theme, colors, housings and fonts in this string already match yours.'
			or 'Nothing would change: these settings already match yours.')
		self.list:ScrollTo(0)
		self.list:Arrange()
	end
	device:Hide()
	return device
end

function ShowPreview(preview)
	local frame = Device()
	frame.preview, frame.mode = preview, 'all'
	frame.list.expanded = {}
	local info = preview.info or {}
	local name = preview.name or 'Imported'
	frame.title:SetText(strupper('Import  /  '..name))
	frame.info:SetText(format('"%s"  /  format %s  /  compared with your profile "%s"', name, tostring(info.version or '?'), UI:ActiveProfile()))
	frame.note:SetText(info.positions == false
		and 'This string holds no frame positions: yours stay where they are. Click a page to list its changes.'
		or 'Nothing changes until you apply. Click a page to list its changes; your current settings are kept as a profile first.')
	frame.scope:SetValue(1)
	-- One page of changes is opened from the start.
	local groups = preview.modes.all.groups
	if #groups == 1 then frame.list.expanded[groups[1].title] = true end
	Kit:Open(frame)
	frame:ShowPlan()
	if Kit.Print then
		Kit:Print(frame.info, {duration = 0.26, steps = 16})
		Kit:Print(frame.note, {duration = 0.3, steps = 18, delay = 0.12})
	end
end

-- The automatic profile per specialization -----------------------------------------------
-- Off unless a profile is chosen. A change of specialization, out of combat,
-- points this character at that specialization's profile and offers the reload.
local NONE = '__none'

local function SpecAPI(name)
	local func = C_SpecializationInfo and C_SpecializationInfo[name]
	if type(func) ~= 'function' then func = _G[name] end
	return type(func) == 'function' and func or nil
end

local function CurrentSpec()
	local get = SpecAPI('GetSpecialization')
	local index = get and PlainCall and PlainCall(get)
	return type(index) == 'number' and index > 0 and index or nil
end

local function SpecName(index)
	local get = SpecAPI('GetSpecializationInfo')
	if not get or not index then return nil end
	local ok, _, name = pcall(get, index)
	return ok and type(name) == 'string' and not UI.Util.IsSecret(name) and name or nil
end

function UI:SpecProfilesAvailable() return CurrentSpec() ~= nil end

local function SpecMap(create)
	local store = Store.Live()
	if type(store.specs) ~= 'table' then
		if not create then return nil end
		store.specs = {}
	end
	local key = Store.CharKey()
	if type(store.specs[key]) ~= 'table' then
		if not create then return nil end
		store.specs[key] = {}
	end
	return store.specs[key]
end

-- The profile chosen for a specialization (the one in use when nil), or nil.
function UI:SpecProfile(spec)
	spec = spec or CurrentSpec()
	local map = spec and SpecMap()
	local profile = map and map[spec]
	return type(profile) == 'string' and profile or nil
end

local function Follow()
	local profile = UI:SpecProfile()
	if not profile then return end
	if not Store.Exists(profile) then
		SpecMap(true)[CurrentSpec()] = nil
		return
	end
	if profile ~= UI:WantedProfile() then UI:SwitchProfile(profile) end
end

function UI:SetSpecProfile(profile, spec)
	spec = spec or CurrentSpec()
	if not spec then return end
	local map = SpecMap(true)
	map[spec] = (type(profile) == 'string' and profile ~= NONE and Store.Exists(profile)) and profile or nil
	if not map[spec] then
		if next(map) == nil then Store.Live().specs[Store.CharKey()] = nil end
		Kit:Toast({title = 'Automatic profile off', text = format('%s follows "This character uses" again.', SpecName(spec) or 'This specialization')})
		return
	end
	Kit:Toast({title = 'Automatic profile', tone = 'success',
		text = format('%s uses "%s" from now on.', SpecName(spec) or 'This specialization', map[spec])})
	UI:AfterCombat(Follow, 'specProfile')
end

local specWatch = CreateFrame('Frame')
pcall(specWatch.RegisterEvent, specWatch, 'PLAYER_SPECIALIZATION_CHANGED')
specWatch:SetScript('OnEvent', function(_, _, unit)
	if unit ~= nil and (UI.Util.IsSecret(unit) or unit ~= 'player') then return end
	if not UI.db or not SpecMap() then return end
	-- The new specialization settles first; a switch waits for combat to end.
	C_Timer.After(0.5, function() UI:AfterCombat(function() UI:Safe(Follow) end, 'specProfile') end)
end)
