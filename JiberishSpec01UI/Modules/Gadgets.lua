-- Gadgets for the drawer (Modules/Drawer.lua): the TM-1 timer, the VL-1 volume
-- dial and the CP-1 CPU meter, after SPEC-01's /timer page, its mode dial (53)
-- and its meter (09). Each builds once into the body the drawer gives it, and
-- works the same in the drawer or popped out into its own device.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, GetTime, InCombatLockdown = CreateFrame, GetTime, InCombatLockdown
local floor, max, min, abs, sin, cos, pi = math.floor, math.max, math.min, math.abs, math.sin, math.cos, math.pi

local module = UI:RegisterModule('gadgets', {always = true})

-- defaults:begin
UI:RegisterDefaults('gadgets', {timerMinutes = 15, timerAlarm = true, timerSound = 'chime', timerRing = 6,
	timerToast = true, timerTab = true, volumeKnobs = true, cpuRate = 1, cpuTop = true})
-- defaults:end

local function DB() return UI.db.gadgets end
local IsSecret, Plain, Px = UI.Util.IsSecret, UI.Util.PlainCall, UI.Util.Px

-- Timer -------------------------------------------------------------------------------------------
-- The face is a 60-minute dial: the red sector is the time left, from 12
-- o'clock clockwise, shrinking back to 12 as it runs. It is drawn from thin
-- radial strokes (one per two degrees) so it stays clean at any scale.
-- State lives account-wide so a running timer survives a reload or relog.
local timer = {} -- widgets
local DETENTS = {1, 5, 15, 25, 45}
local SECTOR_STEPS = 180
local ALARMS = {chime = {'success'}, beeps = {'blip', 'blip', 'blip'}, latch = {'latch-down'}}

local function State()
	local state = UI:Account('timer')
	if type(state.minutes) ~= 'number' then state.minutes = DB().timerMinutes or 15 end
	return state
end

local runEnd       -- GetTime() at which a running timer ends
local ringing, ringUntil = false, 0

local function Left()
	local state = State()
	if runEnd then return max(0, runEnd - GetTime()) end
	if state.left then return state.left end
	return state.minutes * 60
end

local function Clock(seconds)
	seconds = floor(seconds + 0.999)
	return format('%02d:%02d', floor(seconds / 60), seconds % 60)
end

local function Phase()
	if ringing then return 'done' end
	if runEnd then return 'run' end
	if State().left then return 'hold' end
	return 'set'
end

local function PaintSector(fraction)
	local face = timer.face
	if not face then return end
	local lit = floor(max(0, min(1, fraction)) * SECTOR_STEPS + 0.999)
	if lit == face.lit then return end
	face.lit = lit
	for index, stroke in ipairs(face.strokes) do stroke:SetShown(index <= lit) end
end

local function PaintTimer()
	if not timer.lcd then return end
	local phase, left = Phase(), Left()
	timer.lcd.tag:SetText(phase == 'run' and 'RUN' or phase == 'hold' and 'HOLD' or phase == 'done' and 'DONE' or 'SET')
	timer.lcd.digits:SetText(Clock(left))
	PaintSector(left / 3600)
	if timer.play then
		Kit:SetIcon(timer.play.icon, phase == 'run' and 'pause' or phase == 'done' and 'stop' or 'play')
	end
	if timer.bell then timer.bell:SetChecked(DB().timerAlarm and true or false) end
end

local function TabText()
	if not UI.SetDrawerTabText then return end
	if DB().timerTab and (runEnd or ringing) then
		UI:SetDrawerTabText(ringing and 'DONE' or Clock(Left()), ringing and 'red' or 'lamp')
	else
		UI:SetDrawerTabText(nil)
	end
end

local driver = CreateFrame('Frame')
local since = 0
local StopAlarm

local function Finish()
	local state = State()
	runEnd, state.endsAt, state.left = nil, nil, nil
	ringing = true
	ringUntil = GetTime() + (DB().timerAlarm and (DB().timerRing or 6) or 0.1)
	if DB().timerToast then
		Kit:Toast({title = 'Timer', text = format('%d minute%s done', state.minutes, state.minutes == 1 and '' or 's'),
			tone = 'warning', sound = false, action = {text = 'Stop', onClick = function() StopAlarm() end}})
	end
	if timer.glow then Kit:Blink(timer.glow, 0.5, true) end
end

local ringNext = 0
local function Tick(_, elapsed)
	since = since + elapsed
	if ringing then
		local now = GetTime()
		if DB().timerAlarm and now >= ringNext and now < ringUntil then
			local voices = ALARMS[DB().timerSound] or ALARMS.chime
			for index, voice in ipairs(voices) do
				C_Timer.After((index - 1) * 0.16, function() if ringing then Kit:Play(voice, true) end end)
			end
			ringNext = now + 1.1
		end
		if now >= ringUntil then StopAlarm(true) end
	elseif runEnd and runEnd <= GetTime() then
		Finish()
	end
	if since < 0.1 then return end
	since = 0
	if timer.lcd and timer.lcd:IsVisible() then PaintTimer() end
	TabText()
	if not (runEnd or ringing) then driver:SetScript('OnUpdate', nil) end
end

local function Wake() driver:SetScript('OnUpdate', Tick) end

function StopAlarm(keepText)
	ringing = false
	ringNext = 0
	if timer.glow then
		Kit:Blink(timer.glow, nil, false)
		timer.glow:SetAlpha(0.35)
	end
	if not keepText then State().left = nil end
	PaintTimer()
	TabText()
end

local function Start()
	local state = State()
	local left = state.left or state.minutes * 60
	runEnd = GetTime() + left
	state.endsAt, state.left = time() + left, nil
	if timer.glow and not Kit:DB().reduceMotion then Kit:Breathe(timer.glow, true, {period = 1.6, low = 0.2}) end
	Wake()
	PaintTimer()
end

local function Pause()
	local state = State()
	state.left = Left()
	runEnd, state.endsAt = nil, nil
	if timer.glow then Kit:Breathe(timer.glow, false) end
	PaintTimer()
	TabText()
end

local function Reset()
	local state = State()
	runEnd, state.endsAt, state.left = nil, nil, nil
	if ringing then StopAlarm() end
	if timer.glow then Kit:Breathe(timer.glow, false) end
	PaintTimer()
	TabText()
end

local function SyncSlider(minutes)
	if not timer.slider then return end
	local nearest = 1
	for index, value in ipairs(DETENTS) do
		if abs(value - minutes) < abs(DETENTS[nearest] - minutes) then nearest = index end
	end
	timer.slider:SetValue(nearest)
end

local function SetMinutes(minutes, quiet)
	minutes = max(1, min(60, floor(minutes + 0.5)))
	local state = State()
	if runEnd then return end
	if state.minutes == minutes and not state.left then return end
	state.minutes, state.left = minutes, nil
	DB().timerMinutes = minutes
	if not quiet then Kit:Play('tick') end
	SyncSlider(minutes)
	PaintTimer()
end

local function BuildFace(parent, size)
	local face = CreateFrame('Frame', nil, parent)
	face:SetSize(size, size)
	local radius = size / 2
	local px = Px(face, 1)
	face.shadow = Kit:Texture(face, 'glow', 'BACKGROUND', -2)
	face.shadow:SetPoint('TOPLEFT', -10, 6)
	face.shadow:SetPoint('BOTTOMRIGHT', 10, -14)
	face.shadow:SetVertexColor(0, 0, 0, 0.35)
	face.rim = Kit:Texture(face, 'mask-round', 'BACKGROUND', 0)
	face.rim:SetAllPoints()
	Kit:Tint(face.rim, 'keyEdge')
	face.disc = Kit:Texture(face, 'mask-round', 'BORDER', 0)
	face.disc:SetPoint('TOPLEFT', 3, -3)
	face.disc:SetPoint('BOTTOMRIGHT', -3, 3)
	Kit:Tint(face.disc, 'panelHi')
	face.ring = Kit:Texture(face, 'bezel-ring', 'BORDER', 1)
	face.ring:SetAllPoints(face.disc)
	face.ring:SetAlpha(0.5)
	-- The red sector: radial strokes from the centre out to just inside the ticks.
	local reach = radius - 16
	local width = 2 * pi * reach / SECTOR_STEPS * 1.6
	face.strokes = {}
	for index = 1, SECTOR_STEPS do
		local angle = (index - 0.5) / SECTOR_STEPS * 2 * pi
		local stroke = face:CreateTexture(nil, 'ARTWORK', nil, 0)
		stroke:SetColorTexture(1, 1, 1, 1)
		Kit:Tint(stroke, 'red')
		stroke:SetSize(width, reach)
		stroke:SetPoint('CENTER', face, 'CENTER', sin(angle) * reach / 2, cos(angle) * reach / 2)
		stroke:SetRotation(-angle)
		stroke:Hide()
		face.strokes[index] = stroke
	end
	-- Minute ticks, majors every five, numerals every ten.
	for minute = 0, 59 do
		local angle = minute / 60 * 2 * pi
		local major = minute % 5 == 0
		local length = major and 7 or 4
		local at = radius - 9 - length / 2
		local tick = face:CreateTexture(nil, 'ARTWORK', nil, 2)
		tick:SetColorTexture(1, 1, 1, 1)
		Kit:Tint(tick, 'ink', major and 0.9 or 0.45)
		tick:SetSize((major and 2 or 1) * px * 1.5, length)
		tick:SetPoint('CENTER', face, 'CENTER', sin(angle) * at, cos(angle) * at)
		tick:SetRotation(-angle)
		if minute % 10 == 0 then
			local numeral = Kit:Text(face, tostring(minute), 8, 'ink', true)
			local numeralAt = radius - 26
			numeral:SetPoint('CENTER', face, 'CENTER', sin(angle) * numeralAt, cos(angle) * numeralAt)
			numeral:SetDrawLayer('OVERLAY', 1)
		end
	end
	-- The black centre knob.
	face.knob = Kit:Texture(face, 'mask-round', 'OVERLAY', 2)
	face.knob:SetSize(size * 0.22, size * 0.22)
	face.knob:SetPoint('CENTER')
	face.knob:SetVertexColor(0.13, 0.13, 0.12, 1)
	face.shine = Kit:Texture(face, 'glow', 'OVERLAY', 3)
	face.shine:SetSize(size * 0.12, size * 0.08)
	face.shine:SetPoint('CENTER', face.knob, 'CENTER', -size * 0.03, size * 0.04)
	face.shine:SetVertexColor(1, 1, 1, 0.18)
	-- Drag around the face to set the minutes; the wheel nudges by one.
	face:EnableMouse(true)
	face:EnableMouseWheel(true)
	face:SetScript('OnMouseWheel', function(_, delta) SetMinutes(State().minutes + delta) end)
	face:SetScript('OnMouseDown', function(self, button)
		if button ~= 'LeftButton' or runEnd then return end
		self:SetScript('OnUpdate', function()
			local x, y = Kit:Cursor(self)
			local dx, dy = x - radius, y - radius
			if dx * dx + dy * dy < 25 then return end
			local angle = math.atan2(dx, dy)
			if angle < 0 then angle = angle + 2 * pi end
			local minutes = floor(angle / (2 * pi) * 60 + 0.5)
			SetMinutes(minutes == 0 and 60 or minutes)
		end)
	end)
	face:SetScript('OnMouseUp', function(self) self:SetScript('OnUpdate', nil) end)
	face.lit = -1
	return face
end

local function BuildTimer(body)
	local size = 168
	timer.face = BuildFace(body, size)
	timer.face:SetPoint('LEFT', body, 'LEFT', 4, 0)
	-- The LCD: SET / RUN / HOLD / DONE over mm:ss on unlit 88:88.
	timer.lcd = Kit:LCD(body, {tag = 'SET', ghost = '88:88', size = 'lg', width = 150, text = '15:00'})
	timer.lcd:SetPoint('TOPLEFT', timer.face, 'TOPRIGHT', 18, -6)
	Kit:SetFontRole(timer.lcd, 'numbers')
	-- The detent slider: 1, 5, 15, 25 and 45 minutes.
	timer.slider = Kit:Slider(body, {min = 1, max = #DETENTS, step = 1, value = 3, width = 150, ticks = 4,
		format = function() return '' end,
		onChange = function(index) SetMinutes(DETENTS[index], true) end})
	timer.slider:SetPoint('TOPLEFT', timer.lcd, 'BOTTOMLEFT', 0, -6)
	local margin = 15 * (Kit.zoom or 0.75)
	for index, value in ipairs(DETENTS) do
		local numeral = Kit:Label(body, tostring(value), 'dim', 8, true)
		numeral:SetPoint('TOP', timer.slider, 'TOPLEFT', margin + (150 - margin * 2) * (index - 1) / (#DETENTS - 1), -14 - 46 * (Kit.zoom or 0.75) - 12)
	end
	-- The big round play key with its glow ring, and the reset and bell keys.
	timer.glow = Kit:Texture(body, 'glow', 'BACKGROUND', 1)
	timer.glow:SetSize(104, 104)
	Kit:Tint(timer.glow, 'red', 1)
	timer.glow:SetAlpha(0.35)
	timer.play = Kit:Key(body, {round = true, tone = 'primary', width = 66, height = 66, icon = 'play', iconSize = 20,
		onClick = function()
			local phase = Phase()
			if phase == 'run' then Pause()
			elseif phase == 'done' then StopAlarm()
			else Start() end
		end})
	timer.play:SetPoint('TOPRIGHT', body, 'TOPRIGHT', -12, -18)
	timer.glow:SetPoint('CENTER', timer.play, 'CENTER', 0, -1)
	timer.reset = Kit:Key(body, {round = true, width = 30, height = 30, icon = 'stop', iconSize = 10, onClick = Reset})
	timer.reset:SetPoint('TOPLEFT', timer.play, 'BOTTOMLEFT', -2, -18)
	Kit:AttachTooltip(timer.reset, 'Reset')
	timer.bell = Kit:Key(body, {round = true, tone = 'dark', toggle = true, width = 30, height = 30, icon = 'speaker',
		iconSize = 10, checked = DB().timerAlarm, onClick = function(key)
			DB().timerAlarm = key.checked and true or false
		end})
	timer.bell:SetPoint('LEFT', timer.reset, 'RIGHT', 10, 0)
	Kit:AttachTooltip(timer.bell, 'Alarm')
	SyncSlider(State().minutes)
	PaintTimer()
	return 470, size + 8
end

UI:RegisterGadget('timer', {title = 'Timer', tab = 'Timer', model = 'TM-1', icon = 'play', order = 10,
	description = 'A countdown for your play: drag the dial, pick a detent, or scroll.',
	build = BuildTimer,
	onShow = function() PaintTimer() end})

-- Volume ------------------------------------------------------------------------------------------
-- The master volume on a large knob with a tick arc, the channels on small
-- knobs, and a mute key. CVars change only when you turn something.
local volume = {}
local CHANNELS = {{'Sound_MusicVolume', 'Music'}, {'Sound_SFXVolume', 'Effects'}, {'Sound_AmbienceVolume', 'Ambience'},
	{'Sound_DialogVolume', 'Dialog'}}

local GetCVar = (C_CVar and C_CVar.GetCVar) or _G.GetCVar
local SetCVar = (C_CVar and C_CVar.SetCVar) or _G.SetCVar

local function ReadVolume(name)
	local value = tonumber(Plain(GetCVar, name) or '')
	return value and floor(value * 100 + 0.5) or 100
end

local function Percent(value) return format('%d%%', value) end

local function SyncVolume()
	if not volume.master then return end
	volume.master:SetValue(ReadVolume('Sound_MasterVolume'))
	for _, knob in ipairs(volume.channels) do knob:SetValue(ReadVolume(knob.cvar)) end
	local enabled = Plain(GetCVar, 'Sound_EnableAllSound')
	volume.mute:SetChecked(enabled == '0')
	volume.lamp:SetShown(enabled == '0')
end

local function BuildVolume(body)
	volume.master = Kit:Knob(body, {size = 78, min = 0, max = 100, step = 5, sweep = 270, label = 'Master', format = Percent,
		onChange = function(value) pcall(SetCVar, 'Sound_MasterVolume', format('%.2f', value / 100)) end})
	volume.master:SetPoint('TOPLEFT', body, 'TOPLEFT', 6, 0)
	volume.channels = {}
	for index, channel in ipairs(CHANNELS) do
		local knob = Kit:Knob(body, {size = 34, min = 0, max = 100, step = 5, sweep = 270, label = channel[2], format = Percent,
			onChange = function(value) pcall(SetCVar, channel[1], format('%.2f', value / 100)) end})
		knob.cvar = channel[1]
		knob:SetPoint('TOPLEFT', body, 'TOPLEFT', 136 + (index - 1) * 70, -6)
		volume.channels[index] = knob
	end
	volume.mute = Kit:Key(body, {width = 92, height = 28, text = 'Mute', led = true, toggle = true, tone = 'dark',
		onClick = function(key)
			pcall(SetCVar, 'Sound_EnableAllSound', key.checked and '0' or '1')
			volume.lamp:SetShown(key.checked and true or false)
		end})
	volume.mute:SetPoint('BOTTOMRIGHT', body, 'BOTTOMRIGHT', -6, 4)
	volume.lamp = Kit:Label(body, 'Muted', 'red', 8, true)
	volume.lamp:SetPoint('RIGHT', volume.mute, 'LEFT', -10, 0)
	volume.lamp:Hide()
	volume.events = CreateFrame('Frame')
	volume.events:SetScript('OnEvent', function() if volume.master:IsVisible() then UI:Safe(SyncVolume) end end)
	SyncVolume()
	return 430, 170
end

local function ShowChannels()
	if not volume.channels then return end
	for _, knob in ipairs(volume.channels) do knob:SetShown(DB().volumeKnobs and true or false) end
end

UI:RegisterGadget('volume', {title = 'Volume', tab = 'Volume', model = 'VL-1', icon = 'speaker', order = 20,
	description = 'The game\'s volume on SPEC-01 knobs: drag or scroll a knob.',
	build = BuildVolume,
	onShow = function()
		UI:Safe(SyncVolume)
		ShowChannels()
		if volume.events then pcall(volume.events.RegisterEvent, volume.events, 'CVAR_UPDATE') end
	end,
	onHide = function() if volume.events then volume.events:UnregisterAllEvents() end end})

-- CPU meter -----------------------------------------------------------------------------------------
-- The interface's share of each frame from the game's addon profiler, with the
-- busiest addons, plus frame rate, latency and memory. Read only while shown.
local cpu = {}
local TOP = 5

local function Metric()
	local enum = Enum and Enum.AddOnProfilerMetric
	return enum and (enum.RecentAverageTime or enum.SessionAverageTime)
end

local function Profiler()
	local api = C_AddOnProfiler
	if type(api) ~= 'table' or not Metric() then return nil end
	if api.IsEnabled and Plain(api.IsEnabled) == false then return nil end
	return api
end

local function AddOnCount()
	local count = C_AddOns and C_AddOns.GetNumAddOns and Plain(C_AddOns.GetNumAddOns) or (GetNumAddOns and Plain(GetNumAddOns))
	return type(count) == 'number' and count or 0
end

local function AddOnName(index)
	local get = C_AddOns and C_AddOns.GetAddOnInfo or _G.GetAddOnInfo
	if not get then return nil end
	local ok, name, title = pcall(get, index)
	if not ok or IsSecret(name) then return nil end
	return name, (not IsSecret(title) and title) or name
end

local function Loaded(index)
	local check = C_AddOns and C_AddOns.IsAddOnLoaded or _G.IsAddOnLoaded
	return check and Plain(check, index) and true or false
end

local lastMemory, memory = 0, nil
local function Memory()
	-- Updating every addon's memory is costly; only out of combat, every 10 s.
	if InCombatLockdown() or GetTime() - lastMemory < 10 then return memory end
	lastMemory = GetTime()
	if not (UpdateAddOnMemoryUsage and GetAddOnMemoryUsage) then return nil end
	pcall(UpdateAddOnMemoryUsage)
	local total = 0
	for index = 1, AddOnCount() do
		local kb = Plain(GetAddOnMemoryUsage, index)
		if type(kb) == 'number' then total = total + kb end
	end
	memory = total / 1024
	return memory
end

local function SampleCPU()
	if not cpu.meter then return end
	local api, metric = Profiler(), Metric()
	local overall = api and api.GetOverallMetric and Plain(api.GetOverallMetric, metric)
	local frame = api and api.GetApplicationMetric and Plain(api.GetApplicationMetric, metric)
	if type(overall) == 'number' then
		local share = type(frame) == 'number' and frame > 0 and overall / frame or nil
		cpu.meter:SetValue(share or 0, true)
		cpu.readout:SetText(share and format('%.2f MS  %d%%', overall, floor(share * 100 + 0.5)) or format('%.2f MS', overall))
		cpu.note:SetText('')
	else
		cpu.meter:SetValue(0)
		cpu.readout:SetText('--')
		cpu.note:SetText('The game\'s addon profiler is off; frame rate, latency and memory still read.')
	end
	-- The busiest addons.
	local rows = cpu.rows
	if DB().cpuTop and type(overall) == 'number' and api.GetAddOnMetric then
		local list = {}
		for index = 1, AddOnCount() do
			if Loaded(index) then
				local name, title = AddOnName(index)
				local value = name and Plain(api.GetAddOnMetric, name, metric)
				if type(value) == 'number' and value > 0 then list[#list + 1] = {title = title, value = value} end
			end
		end
		table.sort(list, function(a, b) return a.value > b.value end)
		local top = list[1] and list[1].value or 1
		for index, row in ipairs(rows) do
			local item = list[index]
			if item then
				row.name:SetText(strupper((item.title or ''):gsub('|c%x%x%x%x%x%x%x%x', ''):gsub('|r', '')))
				row.value:SetText(format('%.2f', item.value))
				Kit:SetDots(row.dots, item.value / top, 'lamp', 'ledOff')
				row:Show()
			else
				row:Hide()
			end
		end
	else
		for _, row in ipairs(rows) do row:Hide() end
	end
	-- Frame rate, latency and memory.
	local fps = Plain(GetFramerate)
	cpu.fps:SetText(type(fps) == 'number' and format('%d', fps + 0.5) or '--')
	local ok, _, _, home, world = pcall(GetNetStats)
	local ms = ok and (not IsSecret(world) and world or (not IsSecret(home) and home)) or nil
	cpu.ms:SetText(type(ms) == 'number' and format('%d', ms) or '--')
	local mb = Memory()
	cpu.mem:SetText(mb and format('%.1f', mb) or '--')
end

local function SmallLCD(parent, tag)
	local lcd = Kit:LCD(parent, {tag = tag, ghost = '888.8', size = 'sm', width = 72})
	Kit:SetFontRole(lcd, 'numbers')
	return lcd
end

local function BuildCPU(body)
	local width = 360
	cpu.meter = Kit:Meter(body, {label = 'CPU', width = width, tone = 'lamp', format = function() return '' end})
	cpu.meter:SetPoint('TOPLEFT', body, 'TOPLEFT', 0, 0)
	cpu.readout = Kit:Label(cpu.meter, '', 'dim', 8, true)
	cpu.readout:SetPoint('TOPRIGHT')
	cpu.note = Kit:Text(body, '', 9, 'dim')
	cpu.note:SetPoint('TOPLEFT', cpu.meter, 'BOTTOMLEFT', 0, -6)
	cpu.note:SetWidth(width)
	cpu.note:SetJustifyH('LEFT')
	local fps, ms, mem = SmallLCD(body, 'FPS'), SmallLCD(body, 'MS'), SmallLCD(body, 'MB')
	fps:SetPoint('TOPLEFT', cpu.meter, 'BOTTOMLEFT', 0, -24)
	ms:SetPoint('LEFT', fps, 'RIGHT', 8, 0)
	mem:SetPoint('LEFT', ms, 'RIGHT', 8, 0)
	cpu.fps, cpu.ms, cpu.mem = fps.digits, ms.digits, mem.digits
	cpu.heading = Kit:Label(body, 'Busiest addons  (ms per frame)', 'dim', 8, true)
	cpu.heading:SetPoint('TOPLEFT', fps, 'BOTTOMLEFT', 0, -12)
	cpu.rows = {}
	for index = 1, TOP do
		local row = CreateFrame('Frame', nil, body)
		row:SetSize(width, 14)
		row:SetPoint('TOPLEFT', cpu.heading, 'BOTTOMLEFT', 0, -6 - (index - 1) * 16)
		row.name = Kit:Label(row, '', 'ink', 8)
		row.name:SetPoint('LEFT')
		row.name:SetWidth(150)
		row.name:SetJustifyH('LEFT')
		row.name:SetWordWrap(false)
		row.dots = Kit:DotLine(row, 18, 4, 4)
		row.dots:SetPoint('LEFT', row, 'LEFT', 160, 0)
		row.value = Kit:Text(row, '', 9, 'dim', true)
		row.value:SetPoint('RIGHT')
		row:Hide()
		cpu.rows[index] = row
	end
	cpu.ticker = CreateFrame('Frame', nil, body)
	cpu.elapsed = 0
	return width, 210
end

UI:RegisterGadget('cpu', {title = 'CPU meter', tab = 'CPU', model = 'CP-1', icon = 'info', order = 30,
	description = 'How much of each frame the interface takes, and which addons take it.',
	build = BuildCPU,
	onShow = function()
		if not cpu.ticker then return end
		cpu.elapsed = DB().cpuRate or 1
		cpu.ticker:SetScript('OnUpdate', function(_, elapsed)
			cpu.elapsed = cpu.elapsed + elapsed
			if cpu.elapsed < (DB().cpuRate or 1) then return end
			cpu.elapsed = 0
			UI:Safe(SampleCPU)
		end)
	end,
	onHide = function() if cpu.ticker then cpu.ticker:SetScript('OnUpdate', nil) end end})

-- Module ------------------------------------------------------------------------------------------
function module:Enable()
	-- A timer left running across a reload or relog picks up where it is; one
	-- that ran out meanwhile is cleared quietly.
	local state = State()
	if state.endsAt then
		local left = state.endsAt - time()
		if left > 0 then
			runEnd = GetTime() + left
			Wake()
		else
			state.endsAt = nil
		end
	end
	TabText()
	self.ready = true
end

function module:Refresh()
	if not self.ready then return end
	ShowChannels()
	PaintTimer()
	TabText()
end

-- Hub ---------------------------------------------------------------------------------------------
local function Seconds(value) return format('%d s', value) end
UI:RegisterPage('drawer', {title = 'Drawer and gadgets', order = 4.6, cards = {
	{title = 'Drawer', rows = {
		{'switch', 'Drawer', 'drawer.enable', 'SPEC-01\'s drawer, sliding in from a screen edge with the timer, volume and CPU meter.', reload = true, since = '0.5.2'},
		{'segmented', 'Edge', 'drawer.edge', items = {{'bottom', 'Bottom'}, {'top', 'Top'}, {'left', 'Left'}, {'right', 'Right'}}},
		{'switch', 'Dim the screen', 'drawer.dim', 'A soft shade behind the drawer; a click on it closes the drawer.'},
		{'switch', 'Launcher tab', 'drawer.tab', 'A slim tab on the screen edge that opens the drawer; place it in Unlock mode.'},
		{'button', 'Drawer', 'Open', function() UI:OpenDrawer() end, 'Open the drawer now.'},
	}},
	{title = 'Timer', rows = {
		{'switch', 'Alarm', 'gadgets.timerAlarm', 'Ring when the timer runs out.'},
		{'dropdown', 'Alarm sound', 'gadgets.timerSound', items = {{'chime', 'Chime'}, {'beeps', 'Beeps'}, {'latch', 'Latch'}}},
		{'slider', 'Ring for', 'gadgets.timerRing', 2, 20, 1, 'How long the alarm repeats. It plays on the game\'s sound effects channel.', format = Seconds},
		{'switch', 'Toast', 'gadgets.timerToast', 'A toast with a Stop key when the time is up.'},
		{'switch', 'Countdown on the tab', 'gadgets.timerTab', 'The launcher tab shows the time left while the timer runs.'},
	}},
	{title = 'Volume and CPU', rows = {
		{'switch', 'Channel knobs', 'gadgets.volumeKnobs', 'Music, effects, ambience and dialog knobs next to the master.'},
		{'slider', 'CPU update', 'gadgets.cpuRate', 0.5, 5, 0.5, 'How often the CPU meter reads, while it is shown.', format = function(v) return format('%.1f s', v) end},
		{'switch', 'Busiest addons', 'gadgets.cpuTop', 'List the addons taking the most time.'},
	}},
}})
