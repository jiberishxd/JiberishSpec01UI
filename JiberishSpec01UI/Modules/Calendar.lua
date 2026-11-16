-- CL-1: SPEC-01's calendar (component 13) as a gadget in the drawer, with a
-- live clock and reminders.
--
--   * The face: a black screen with "SET DATE" and the weekday printed along
--     the top, the date as three LCD fields (year, month, day) where the
--     selected field is a lit block, and a grid of day cells (today ringed,
--     days with reminders lit, the selected day in the key color). A jog
--     wheel turns the selected field; its centre SET key steps through the
--     fields and confirms with a latch. Every detent ticks.
--   * The clock: local or realm time, 12 or 24 hours, with a blinking colon,
--     and the game's calendar events on the selected day.
--   * Reminders on any day: a title, a time, a repeat (once, daily, weekly) and
--     how early to alert. They are account-wide (UI:Account('calendar')), never
--     part of a profile. When one is due it sounds an alarm, shows a toast with
--     a Snooze key, and optionally prints a line in chat. Reminders missed in
--     the last hour (the game was closed) fire on login.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, GetTime = CreateFrame, GetTime
local floor, max, min = math.floor, math.max, math.min

local module = UI:RegisterModule('calendar', {always = true})

-- defaults:begin
UI:RegisterDefaults('calendar', {enable = true, clock24 = true, server = false, firstDay = 'sun', sound = true,
	toast = true, chat = true})
-- defaults:end

local function DB() return UI.db.calendar end
local function IsSecret(value) return issecretvalue and issecretvalue(value) end
local function Store()
	local store = UI:Account('calendar')
	if type(store.reminders) ~= 'table' then store.reminders = {} end
	return store
end

-- Dates -------------------------------------------------------------------------------
local function DaysIn(year, month)
	return tonumber(date('%d', time({year = year, month = month + 1, day = 0, hour = 12})))
end
local function Stamp(year, month, day, hour, minute)
	return time({year = year, month = month, day = day, hour = hour or 12, min = minute or 0, sec = 0})
end
local function Weekday(year, month, day) -- 0 = Sunday
	return tonumber(date('%w', Stamp(year, month, day)))
end
local function DayNumber(stamp) -- whole local days, for comparing dates
	local t = date('*t', stamp)
	return floor(Stamp(t.year, t.month, t.day) / 86400 + 0.5)
end

-- Whether a reminder falls on a given date.
local function OccursOn(reminder, year, month, day)
	local base = Stamp(reminder.year, reminder.month, reminder.day)
	local target = Stamp(year, month, day)
	local from, to = DayNumber(base), DayNumber(target)
	if to < from then return false end
	if reminder.rep == 'daily' then return true end
	if reminder.rep == 'weekly' then return (to - from) % 7 == 0 end
	return to == from
end

-- The game's calendar events on a date, as plain titles (secret ones skipped).
local calendarOpened = false
local function GameEvents(year, month, day)
	local list = {}
	local api = C_Calendar
	if not (api and api.GetMonthInfo and api.GetNumDayEvents and api.GetDayEvent) then return list end
	if not calendarOpened and api.OpenCalendar then
		calendarOpened = true
		pcall(api.OpenCalendar)
	end
	local ok, info = pcall(api.GetMonthInfo, 0)
	if not ok or type(info) ~= 'table' or IsSecret(info.month) or IsSecret(info.year) then return list end
	if type(info.month) ~= 'number' or type(info.year) ~= 'number' then return list end
	local offset = (year - info.year) * 12 + (month - info.month)
	if offset < -1 or offset > 1 then return list end
	local okCount, count = pcall(api.GetNumDayEvents, offset, day)
	if not okCount or IsSecret(count) or type(count) ~= 'number' then return list end
	for index = 1, min(count, 4) do
		local okEvent, event = pcall(api.GetDayEvent, offset, day, index)
		local title = okEvent and type(event) == 'table' and event.title
		if type(title) == 'string' and not IsSecret(title) and title ~= '' then list[#list + 1] = title end
	end
	return list
end

-- The clock ----------------------------------------------------------------------------
local function ClockTime()
	if DB().server and GetGameTime then
		local hour, minute = GetGameTime()
		if not IsSecret(hour) and not IsSecret(minute) and type(hour) == 'number' then return hour, minute end
	end
	local now = date('*t')
	return now.hour, now.min
end

local function ClockText(hour, minute, colon)
	local separator = colon and ':' or ' '
	if DB().clock24 then return format('%02d%s%02d', hour, separator, minute), '' end
	local suffix = hour < 12 and 'AM' or 'PM'
	hour = hour % 12
	if hour == 0 then hour = 12 end
	return format('%2d%s%02d', hour, separator, minute), suffix
end

-- Reminders ------------------------------------------------------------------------------
local REPEATS = {'none', 'daily', 'weekly'}
local REPEAT_TEXT = {none = 'Once', daily = 'Daily', weekly = 'Weekly'}
local LEADS = {0, 5, 15, 60}
local LEAD_TEXT = {[0] = 'At time', [5] = '5m', [15] = '15m', [60] = '1h'}

local function Alarm()
	if not DB().sound then return end
	Kit:Play('open', true)
	for index = 1, 3 do
		C_Timer.After(0.22 * index, function() Kit:Play('blip', true) end)
	end
	C_Timer.After(0.9, function() Kit:Play('success', true) end)
end

local Fire
local function Snooze(reminder)
	reminder.snoozeAt = time() + 300
	Kit:Play('latch-down', true)
end

function Fire(reminder, at)
	local when = date(DB().clock24 and '%H:%M' or '%I:%M %p', at)
	Alarm()
	if DB().toast and Kit.Toast then
		Kit:Toast({title = reminder.title ~= '' and reminder.title or 'Reminder', text = 'CL-1  '..when, tone = 'warning',
			duration = 12, sound = false, action = {text = 'Snooze', onClick = function() Snooze(reminder) end}})
	end
	if DB().chat then UI:Print(format('Reminder: %s (%s)', reminder.title ~= '' and reminder.title or 'untitled', when)) end
	if module.OnFire then UI:Safe(module.OnFire) end
end

-- Due checks: today's and tomorrow's occurrence (a lead can cross midnight);
-- anything due in the last hour that hasn't fired yet fires now.
local CATCH_UP = 3600
local function Check()
	if not DB().enable then return end
	local now = time()
	for _, reminder in ipairs(Store().reminders) do
		if reminder.snoozeAt and now >= reminder.snoozeAt then
			reminder.snoozeAt = nil
			UI:Safe(Fire, reminder, now)
		end
		local today = date('*t', now)
		for shift = 0, 1 do
			local t = date('*t', Stamp(today.year, today.month, today.day) + shift * 86400)
			if OccursOn(reminder, t.year, t.month, t.day) then
				local at = Stamp(t.year, t.month, t.day, reminder.hour, reminder.min)
				local alertAt = at - (reminder.lead or 0) * 60
				if now >= alertAt and now - alertAt < CATCH_UP and reminder.firedFor ~= at then
					reminder.firedFor = at
					UI:Safe(Fire, reminder, at)
				end
			end
		end
	end
end

local nextId = 0
local function AddReminder(entry)
	local store = Store()
	nextId = max(nextId, store.nextId or 0) + 1
	store.nextId = nextId
	entry.id = nextId
	-- A reminder already past today (and not repeating) is marked as fired.
	local at = Stamp(entry.year, entry.month, entry.day, entry.hour, entry.min)
	if entry.rep == 'none' and at - entry.lead * 60 <= time() then entry.firedFor = at end
	table.insert(store.reminders, entry)
end

local function RemoveReminder(id)
	local list = Store().reminders
	for index = #list, 1, -1 do
		if list[index].id == id then table.remove(list, index) end
	end
end

-- The face -------------------------------------------------------------------------------
local FIELDS = {'year', 'month', 'day'}
local WEEKDAYS = {'S', 'M', 'T', 'W', 'T', 'F', 'S'}
local LIST_ROWS = 4
local WIDTH, HEIGHT = 440, 404

local face -- the built gadget (one, whichever holder shows it)

local function SortedForDay(year, month, day)
	local list = {}
	for _, reminder in ipairs(Store().reminders) do
		if OccursOn(reminder, year, month, day) then list[#list + 1] = reminder end
	end
	table.sort(list, function(a, b) return a.hour * 60 + a.min < b.hour * 60 + b.min end)
	return list
end

local function Paint()
	if not face then return end
	local year, month, day = face.year, face.month, face.day
	face.weekday:SetText(strupper(date('%A', Stamp(year, month, day))))
	face.fields[1].text:SetText(format('%04d', year))
	face.fields[2].text:SetText(format('%02d', month))
	face.fields[3].text:SetText(format('%02d', day))
	for index, field in ipairs(face.fields) do
		field.bar:SetShown(index == face.field)
		Kit:Tint(field.text, index == face.field and 'onAccent' or 'darkInk')
	end
	-- The grid: weeks from the chosen first day.
	local mondayFirst = DB().firstDay == 'mon'
	for index, legend in ipairs(face.legends) do
		legend:SetText(WEEKDAYS[mondayFirst and (index % 7) + 1 or index])
	end
	local first = Weekday(year, month, 1)
	if mondayFirst then first = (first + 6) % 7 end
	local count = DaysIn(year, month)
	local now = date('*t')
	for slot, cell in ipairs(face.cells) do
		local d = slot - first
		cell.day = d >= 1 and d <= count and d or nil
		cell:SetShown(cell.day ~= nil)
		if cell.day then
			local marked = false
			for _, reminder in ipairs(Store().reminders) do
				if OccursOn(reminder, year, month, d) then marked = true break end
			end
			if d == day then Kit:Tint(cell.fill, 'accent', 1)
			elseif marked then Kit:Tint(cell.fill, 'darkInk', 0.9)
			else Kit:Tint(cell.fill, 'darkDim', 0.35) end
			cell.ring:SetShown(year == now.year and month == now.month and d == now.day)
		end
	end
	-- The selected day: game events and reminders.
	local events = GameEvents(year, month, day)
	face.events:SetText(#events > 0 and strupper(table.concat(events, '  /  ')) or 'NO GAME EVENTS')
	local list = SortedForDay(year, month, day)
	for index, row in ipairs(face.rows) do
		local reminder = list[index]
		row:SetShown(reminder ~= nil)
		if reminder then
			row.reminder = reminder
			row.time:SetText(format('%02d:%02d', reminder.hour, reminder.min))
			row.title:SetText(reminder.title ~= '' and reminder.title or 'Untitled')
			row.tag:SetText(strupper(REPEAT_TEXT[reminder.rep] or 'Once')..'  '..strupper(LEAD_TEXT[reminder.lead or 0] or ''))
		end
	end
	face.more:SetText(#list > LIST_ROWS and format('+%d MORE', #list - LIST_ROWS) or '')
	face.empty:SetShown(#list == 0)
end

local function SetDate(year, month, day)
	while month > 12 do month = month - 12; year = year + 1 end
	while month < 1 do month = month + 12; year = year - 1 end
	year = Kit:Clamp(year, 1970, 2099)
	face.year, face.month = year, month
	face.day = Kit:Clamp(day, 1, DaysIn(year, month))
	Paint()
end

local function Turn(delta)
	local year, month, day = face.year, face.month, face.day
	if face.field == 1 then year = year + delta
	elseif face.field == 2 then month = month + delta
	else
		day = day + delta
		if day < 1 then
			month = month - 1
			if month < 1 then month = 12; year = year - 1 end
			day = DaysIn(year, month)
		elseif day > DaysIn(year, month) then
			day = 1; month = month + 1
		end
	end
	SetDate(year, month, day)
	Kit:Play('tick')
end

-- A small LCD number that the wheel turns and clicks step.
local function Spinner(parent, width, low, high, step, value, format1)
	local box = Kit:LCDPanel(parent, {radius = 3})
	box:SetSize(width, 26)
	box:EnableMouse(true)
	box:EnableMouseWheel(true)
	box.text = Kit:Text(box, '', 14, 'lcdInk', true)
	box.text:SetPoint('CENTER')
	box.low, box.high, box.step = low, high, step
	function box:SetValue(v)
		local span = self.high - self.low + 1
		self.value = (v - self.low) % span + self.low
		self.text:SetText(format(format1, self.value))
	end
	local function Nudge(direction)
		local amount = IsShiftKeyDown() and 1 or box.step
		box:SetValue(box.value + direction * amount)
		Kit:Play('tick')
	end
	box:SetScript('OnMouseWheel', function(_, delta) Nudge(delta) end)
	box:SetScript('OnMouseUp', function(_, button) Nudge(button == 'RightButton' and -1 or 1) end)
	box:SetScript('OnEnter', function(self) Kit:ShowTooltip(self, 'Wheel or click to change (Shift: fine)') end)
	box:SetScript('OnLeave', function() Kit:HideTooltip() end)
	box:SetValue(value)
	return box
end

local function BuildFace(body)
	local frame = CreateFrame('Frame', nil, body)
	frame:SetSize(WIDTH, HEIGHT)
	face = frame
	local today = date('*t')
	frame.year, frame.month, frame.day, frame.field = today.year, today.month, today.day, 3

	-- The black screen: date fields, weekday legend and the day grid.
	local screen = Kit:Panel(frame, {radius = 6, fill = 'glass', border = 'darkEdge'})
	screen:SetPoint('TOPLEFT', 0, 0)
	screen:SetSize(300, 150)
	local tag = Kit:Label(screen, 'Set date', 'darkDim', 8)
	tag:SetPoint('TOPLEFT', 14, -12)
	frame.weekday = Kit:Label(screen, '', 'darkDim', 8)
	frame.weekday:SetPoint('TOPRIGHT', -14, -12)
	frame.fields = {}
	local x = 14
	for index, name in ipairs(FIELDS) do
		local width = name == 'year' and 70 or 40
		local field = CreateFrame('Button', nil, screen)
		field:SetSize(width, 32)
		field:SetPoint('TOPLEFT', x, -28)
		field.bar = Kit:Texture(field, 'round-3', 'BACKGROUND')
		field.bar:SetAllPoints()
		Kit:Tint(field.bar, 'accent')
		field.text = Kit:Text(field, '', 24, 'darkInk')
		Kit:Font(field.text, 24, nil, false, 'numbers')
		field.text:SetPoint('CENTER')
		field:SetScript('OnClick', function()
			frame.field = index
			Paint()
			Kit:Play('blip')
		end)
		frame.fields[index] = field
		x = x + width
		if index < #FIELDS then
			local dot = Kit:Text(screen, '·', 18, 'darkDim')
			dot:SetPoint('CENTER', screen, 'TOPLEFT', x + 9, -44)
			x = x + 18
		end
	end
	frame.legends, frame.cells = {}, {}
	local CELL, GAP = 11, 4
	for column = 1, 7 do
		local legend = Kit:Label(screen, '', 'darkDim', 7)
		legend:SetPoint('TOPLEFT', 14 + (column - 1) * (CELL + GAP) + 2, -70)
		frame.legends[column] = legend
	end
	for slot = 1, 42 do
		local cell = CreateFrame('Button', nil, screen)
		cell:SetSize(CELL, CELL)
		cell:SetPoint('TOPLEFT', 14 + ((slot - 1) % 7) * (CELL + GAP), -82 - floor((slot - 1) / 7) * (CELL + GAP - 4))
		cell.fill = cell:CreateTexture(nil, 'ARTWORK')
		cell.fill:SetColorTexture(1, 1, 1, 1)
		cell.fill:SetPoint('TOPLEFT', 1, -1)
		cell.fill:SetPoint('BOTTOMRIGHT', -1, 1)
		cell.ring = Kit:Texture(cell, 'ring-3', 'OVERLAY')
		cell.ring:SetPoint('TOPLEFT', -1, 1)
		cell.ring:SetPoint('BOTTOMRIGHT', 1, -1)
		Kit:Tint(cell.ring, 'darkInk')
		cell:SetScript('OnClick', function(self)
			if not self.day then return end
			frame.field = 3
			SetDate(frame.year, frame.month, self.day)
			Kit:Play('tick')
		end)
		frame.cells[slot] = cell
	end
	-- The clock, on the screen's right half.
	frame.clockTag = Kit:Label(screen, 'Local', 'darkDim', 7)
	frame.clockTag:SetPoint('TOPRIGHT', -14, -76)
	frame.clock = Kit:Text(screen, '', 26, 'darkInk', true)
	Kit:Font(frame.clock, 26, nil, true, 'numbers')
	frame.clock:SetPoint('TOPRIGHT', -14, -88)
	frame.clock:SetJustifyH('RIGHT')
	frame.ampm = Kit:Label(screen, '', 'darkDim', 7)
	frame.ampm:SetPoint('TOPRIGHT', frame.clock, 'BOTTOMRIGHT', 0, -3)
	local clockKey = CreateFrame('Button', nil, screen)
	clockKey:SetPoint('TOPLEFT', frame.clock, 'TOPLEFT', -6, 4)
	clockKey:SetPoint('BOTTOMRIGHT', frame.clock, 'BOTTOMRIGHT', 6, -4)
	clockKey:SetScript('OnClick', function()
		DB().server = not DB().server
		Kit:Play(DB().server and 'latch-down' or 'latch-up')
		module:Tick(true)
	end)
	clockKey:SetScript('OnEnter', function(self) Kit:ShowTooltip(self, 'Click: local or realm time') end)
	clockKey:SetScript('OnLeave', function() Kit:HideTooltip() end)
	frame.events = Kit:Label(screen, '', 'darkDim', 7)
	frame.events:SetPoint('BOTTOMLEFT', 14, 10)
	frame.events:SetPoint('BOTTOMRIGHT', -14, 10)
	frame.events:SetJustifyH('LEFT')
	frame.events:SetWordWrap(false)

	-- The jog wheel and its SET key.
	local jog = CreateFrame('Frame', nil, frame)
	jog:SetSize(124, 124)
	jog:SetPoint('LEFT', screen, 'RIGHT', 10, 0)
	jog.ticks = Kit:Texture(jog, 'knob-ticks', 'BACKGROUND')
	jog.ticks:SetAllPoints()
	Kit:Tint(jog.ticks, 'dim')
	jog.dial = CreateFrame('Frame', nil, jog)
	jog.dial:SetPoint('TOPLEFT', 16, -16)
	jog.dial:SetPoint('BOTTOMRIGHT', -16, 16)
	jog.cap = Kit:Skin(jog.dial, 'knob-cap', 'BORDER', 0)
	local origin, turned
	Kit:Drag(jog.dial, function(_, _, y)
		local steps = floor((y - origin) / 10 + 0.5)
		if steps ~= turned then
			Turn(steps - turned)
			turned = steps
		end
	end, function(self)
		local _, y = Kit:Cursor(self)
		origin, turned = y, 0
	end)
	jog.dial:EnableMouseWheel(true)
	jog.dial:SetScript('OnMouseWheel', function(_, delta) Turn(delta) end)
	jog.set = Kit:Key(jog, {round = true, width = 44, height = 44, tone = 'dark', text = 'Set', textSize = 8, lip = 1})
	jog.set:SetPoint('CENTER')
	jog.set:SetFrameLevel(jog.dial:GetFrameLevel() + 3)
	jog.set.onClick = function()
		if frame.field < #FIELDS then
			frame.field = frame.field + 1
			Kit:Play('latch-down')
		else
			frame.field = 1
			Kit:Play('latch-up')
		end
		Paint()
	end
	local todayKey = Kit:Key(frame, {text = 'Today', width = 64, height = 22, textSize = 8})
	todayKey:SetPoint('TOP', jog, 'BOTTOM', 0, -2)
	todayKey.onClick = function()
		local now = date('*t')
		frame.field = 3
		SetDate(now.year, now.month, now.day)
	end

	-- Reminders on the selected day.
	local header = Kit:Label(frame, 'Reminders', 'dim', 8, true)
	header:SetPoint('TOPLEFT', screen, 'BOTTOMLEFT', 2, -12)
	frame.more = Kit:Label(frame, '', 'dim', 7)
	frame.more:SetPoint('TOPRIGHT', frame, 'TOPRIGHT', -2, -162)
	local rule = Kit:Solid(frame, 'hair', 'ARTWORK')
	rule:SetHeight(1)
	rule:SetPoint('LEFT', header, 'RIGHT', 8, 0)
	rule:SetPoint('RIGHT', frame, 'RIGHT', -60, 0)
	frame.rows = {}
	for index = 1, LIST_ROWS do
		local row = CreateFrame('Frame', nil, frame)
		row:SetSize(WIDTH, 22)
		row:SetPoint('TOPLEFT', screen, 'BOTTOMLEFT', 0, -26 - (index - 1) * 24)
		row.lamp = Kit:Led(row, 5, true)
		row.lamp:SetPoint('LEFT', 4, 0)
		row.time = Kit:Text(row, '', 11, 'ink', true)
		Kit:Font(row.time, 11, nil, true, 'numbers')
		row.time:SetPoint('LEFT', 16, 0)
		row.title = Kit:Text(row, '', 11, 'ink')
		row.title:SetPoint('LEFT', 64, 0)
		row.title:SetPoint('RIGHT', -150, 0)
		row.title:SetJustifyH('LEFT')
		row.title:SetWordWrap(false)
		row.tag = Kit:Label(row, '', 'dim', 7)
		row.tag:SetPoint('RIGHT', -36, 0)
		row.delete = Kit:Key(row, {icon = 'close', width = 24, height = 20, iconSize = 10})
		row.delete:SetPoint('RIGHT', -4, 0)
		row.delete.onClick = function()
			if row.reminder then
				RemoveReminder(row.reminder.id)
				Kit:Play('latch-up')
				Paint()
			end
		end
		frame.rows[index] = row
	end
	frame.empty = Kit:Label(frame, 'Nothing set for this day', 'dim', 8)
	frame.empty:SetPoint('TOPLEFT', screen, 'BOTTOMLEFT', 4, -32)

	-- Adding one: title, time, repeat, lead, Add.
	local addTop = -26 - LIST_ROWS * 24 - 8
	local title = Kit:TextField(frame, {width = 200, placeholder = 'Reminder title'})
	title:SetPoint('TOPLEFT', screen, 'BOTTOMLEFT', 0, addTop)
	local now = date('*t')
	local hour = Spinner(frame, 38, 0, 23, 1, now.hour, '%02d')
	hour:SetPoint('LEFT', title, 'RIGHT', 10, 0)
	local colon = Kit:Text(frame, ':', 14, 'ink', true)
	colon:SetPoint('LEFT', hour, 'RIGHT', 2, 0)
	local minute = Spinner(frame, 38, 0, 59, 5, floor(now.min / 5) * 5, '%02d')
	minute:SetPoint('LEFT', colon, 'RIGHT', 2, 0)
	local add = Kit:Key(frame, {text = 'Add', width = 64, height = 30, tone = 'primary'})
	add:SetPoint('LEFT', minute, 'RIGHT', 10, 0)
	local repeatControl = Kit:Segmented(frame, {items = {'Once', 'Daily', 'Weekly'}, width = 200, value = 1})
	repeatControl:SetPoint('TOPLEFT', title, 'BOTTOMLEFT', 0, -8)
	local leadControl = Kit:Segmented(frame, {items = {'At time', '5m', '15m', '1h'}, width = 220, value = 1})
	leadControl:SetPoint('LEFT', repeatControl, 'RIGHT', 10, 0)
	add.onClick = function()
		AddReminder({title = strtrim(title:GetValue() or ''), year = frame.year, month = frame.month, day = frame.day,
			hour = hour.value, min = minute.value, rep = REPEATS[repeatControl:GetValue() or 1] or 'none',
			lead = LEADS[leadControl:GetValue() or 1] or 0})
		title:SetValue('')
		title.edit:ClearFocus()
		Kit:Play('success')
		Paint()
	end
	title.edit:SetScript('OnEnterPressed', function() add.onClick() end)

	Paint()
	module:Tick(true)
	return WIDTH, HEIGHT
end

-- The clock ticks twice a second while the face shows (the colon blinks).
local clockTicker
function module:Tick(force)
	if not face then return end
	face.colon = force and true or not face.colon
	local hour, minute = ClockTime()
	local text, suffix = ClockText(hour, minute, face.colon)
	face.clock:SetText(text)
	face.ampm:SetText(suffix)
	face.clockTag:SetText(DB().server and 'REALM' or 'LOCAL')
	-- A new day under the open face: repaint the ring on today.
	local today = date('%Y%m%d')
	if face.paintedDay ~= today then
		face.paintedDay = today
		Paint()
	end
end

local function StartClock()
	if clockTicker then return end
	clockTicker = C_Timer.NewTicker(0.5, function() UI:Safe(module.Tick, module) end)
end
local function StopClock()
	if clockTicker then clockTicker:Cancel(); clockTicker = nil end
end

-- Without the drawer: a CL-1 device of its own, centred, with a close key.
local standalone
local function Standalone()
	if standalone then return standalone end
	standalone = Kit:Device(UIParent, {name = 'JiberishSpec01Calendar', surface = 'dark', model = 'CL-1', title = 'Calendar',
		width = WIDTH + 28, height = HEIGHT + 44})
	standalone:SetFrameStrata('DIALOG')
	standalone:SetPoint('CENTER')
	standalone:SetMovable(true)
	standalone:EnableMouse(true)
	standalone:RegisterForDrag('LeftButton')
	standalone:SetScript('OnDragStart', standalone.StartMoving)
	standalone:SetScript('OnDragStop', standalone.StopMovingOrSizing)
	standalone:SetClampedToScreen(true)
	local close = Kit:Key(standalone, {icon = 'close', width = 24, height = 20, iconSize = 10})
	close:SetPoint('TOPRIGHT', -8, -6)
	close.onClick = function() standalone:Hide() end
	local body = CreateFrame('Frame', nil, standalone)
	body:SetPoint('TOPLEFT', 14, -30)
	body:SetSize(WIDTH, HEIGHT)
	BuildFace(body)
	face:SetPoint('TOPLEFT')
	standalone:SetScript('OnShow', function() StartClock(); Paint() end)
	standalone:SetScript('OnHide', StopClock)
	tinsert(UISpecialFrames, 'JiberishSpec01Calendar')
	standalone:Hide()
	return standalone
end

function UI:OpenCalendar()
	if UI.OpenDrawer and module.inDrawer then
		UI:OpenDrawer('calendar')
		return
	end
	local frame = Standalone()
	if frame:IsShown() then frame:Hide() else Kit:Play('open', true); frame:Show() end
end

-- The drawer's gadget.
if UI.RegisterGadget then
	module.inDrawer = true
	UI:RegisterGadget('calendar', {title = 'Calendar', model = 'CL-1', icon = 'calendar', order = 10,
		build = function(body)
			local width, height = BuildFace(body)
			face:SetPoint('TOPLEFT')
			return width, height
		end,
		onShow = function() StartClock(); Paint() end,
		onHide = StopClock,
	})
end

-- Due reminders are checked every second.
function module:Enable()
	local function Begin()
		C_Timer.NewTicker(1, function() UI:Safe(Check) end)
		C_Timer.After(5, function() UI:Safe(Check) end)
	end
	Begin()
	local events = CreateFrame('Frame')
	pcall(events.RegisterEvent, events, 'CALENDAR_UPDATE_EVENT_LIST')
	events:SetScript('OnEvent', function()
		if face and face:IsVisible() then UI:Safe(Paint) end
	end)
end

function module:Refresh()
	if face and face:IsVisible() then
		Paint()
		module:Tick(true)
	end
end

-- Hub ------------------------------------------------------------------------------------
local function Off() return not DB().enable end
UI:RegisterPage('calendar', {title = 'Calendar and clock', order = 4.3, cards = {
	{title = 'Calendar', rows = {
		{'switch', 'Reminders', 'calendar.enable', 'Reminders you set on the CL-1 calendar alert you when they are due.', since = '0.5.2'},
		{'button', 'Calendar', 'Open', function() UI:OpenCalendar() end, 'The CL-1 calendar and clock, with your reminders.'},
		{'segmented', 'Week starts', 'calendar.firstDay', items = {{'sun', 'Sunday'}, {'mon', 'Monday'}}, since = '0.5.2'},
	}},
	{title = 'Clock', rows = {
		{'segmented', 'Hours', 'calendar.clock24', items = {{true, '24 h'}, {false, '12 h'}}, since = '0.5.2'},
		{'segmented', 'Time', 'calendar.server', items = {{false, 'Local'}, {true, 'Realm'}}, since = '0.5.2'},
	}},
	{title = 'Alerts', rows = {
		{'switch', 'Alarm sound', 'calendar.sound', 'A SPEC-01 chime when a reminder is due.', disabled = Off, since = '0.5.2'},
		{'switch', 'Toast', 'calendar.toast', 'A toast with the reminder and a Snooze key.', disabled = Off, since = '0.5.2'},
		{'switch', 'Chat line', 'calendar.chat', 'The reminder printed in chat as well.', disabled = Off, since = '0.5.2'},
	}},
}})
