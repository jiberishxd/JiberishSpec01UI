-- Combat cues: the interface switching into a live state as a fight starts, and
-- back as it ends, told with SPEC-01's own hardware. Every part can be shaped
-- on the Combat cues page, and the status device and the ring placed anywhere.
--
--   * Status: a CB-1 device (full, compact, timer only or lamp only) whose
--     lamp lights, legend reads COMBAT (or your word) and LCD counts the fight
--     up; on leaving it reads CLEAR and the fight's length, then goes away or
--     settles into an idle READY state. Unlock mode places it ('Combat status').
--   * Arming ring: ticks, dots or arc segments around the screen centre, under
--     your character, on your unit frame or anywhere you put it ('Combat ring'),
--     lighting in sequence; it can stay faintly lit for the fight.
--   * Lamps: dark SPEC-01 device lamps light for the fight, cascading out from
--     the middle, and go back exactly as they were.
--   * Edge glow, corner brackets, rails and a frame trace as extras.
--   * Sounds for going in, coming out and each minute of a fight.
--
-- Everything here is our own unprotected frames, so it all runs in combat. With
-- reduced motion nothing moves: the states simply change.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, GetTime, UIParent, InCombatLockdown = CreateFrame, GetTime, UIParent, InCombatLockdown
local floor, max, min, abs, cos, sin, pi = math.floor, math.max, math.min, math.abs, math.cos, math.sin, math.pi

local module = UI:RegisterModule('combatcue', {always = true})

local RED, GREEN = {1, 0.23, 0.19}, {0.18, 0.62, 0.37}
-- defaults:begin
UI:RegisterDefaults('combatcue', {enable = true, where = 'always', sound = true,
	-- Status device.
	status = true, hold = true, idle = false, statusScale = 1, statusLayout = 'full', statusFinish = 'theme',
	legend = 'COMBAT', legendText = '', clearWord = 'CLEAR', clearText = '', timerFormat = 'mmss', tenths = false,
	timerInk = 'lcd', inColor = {1, 0.23, 0.19}, outColor = {0.18, 0.62, 0.37}, enter = 'drop', exit = 'rise',
	clearHold = 2.2,
	-- Arming ring.
	ring = true, ringPos = 'player', ringRadius = 74, ringTicks = 60, ringLength = 6, ringWidth = 2,
	ringIn = {1, 0.23, 0.19}, ringOut = {0.18, 0.62, 0.37}, ringDir = 'cw', ringSpeed = 1, ringStyle = 'ticks',
	ringHold = false, ringPlaced = false, showcase = false,
	-- Device lamps.
	lamps = true, lampSpeed = 0.3, lampColor = 'red', lampScope = 'all', lampUnits = true, lampBars = true,
	lampGroup = true, lampOther = true,
	-- Edge glow.
	edge = false, edgeColor = {1, 0.23, 0.19}, edgeIntensity = 0.55, edgeDuration = 0.7, edgeSides = 'all',
	edgePulse = false,
	-- Extras.
	brackets = false, rails = false, trace = false, extrasIn = {1, 0.23, 0.19}, extrasOut = {0.18, 0.62, 0.37},
	bracketSize = 28, bracketInset = 10, railSides = 'both',
	-- Sounds.
	soundEnter = 'latch-down', soundEnter2 = 'blip', soundLeave = 'success', soundMinute = 'off', soundDouble = false,
})
-- defaults:end

local function DB() return UI.db.combatcue end
local IsSecret = UI.Util.IsSecret
local function Reduced() return Kit:DB().reduceMotion end
local Px = UI.Util.Px
local function RGB(color, fallback)
	if type(color) == 'table' then
		local r, g, b = Kit.ColorParts(color)
		return r, g, b
	end
	return unpack(fallback)
end
local function Paint(color, fallback, ...)
	local r, g, b = RGB(color, fallback)
	for index = 1, select('#', ...) do select(index, ...):SetVertexColor(r, g, b) end
end

local fighting = false -- in a real fight
local started          -- when the fight (or the preview's) began
local preview          -- the running preview's token

-- 0.5.1 shipped brackets, rails, trace and an LCD readout on by default; this
-- version leads with the status device and the ring. Move saved profiles once.
local function Upgrade(db)
	if db.upgraded then return end
	if db.readout == false then db.status = false end
	db.readout = nil
	db.brackets, db.rails, db.trace = false, false, false
	db.upgraded = 1
end

-- Where the cue plays. Previews ignore this.
local function Allowed()
	local where = DB().where
	if where == 'always' then return true end
	local inInstance = IsInInstance and IsInInstance()
	if where == 'instances' then return inInstance and true or false end
	if where == 'world' then return not inInstance end
	if where == 'group' then return IsInGroup and IsInGroup() and true or false end
	return true
end

local root
local function Root()
	if root then return root end
	root = CreateFrame('Frame', nil, UIParent)
	root:SetAllPoints()
	root:SetFrameStrata('HIGH')
	root:EnableMouse(false)
	return root
end

-- Status device ---------------------------------------------------------------------------
local holder, status, ticker, lastMinute

local LAYOUTS = {full = {176, 62}, compact = {132, 34}, timer = {112, 34}, lamp = {30, 30}}
local SURFACES = {theme = 'paper', paper = 'paper', graphite = 'dark', lcd = 'lcd', glass = 'glass'}
local GHOSTS = {mmss = '88:88', mss = '8:88', sec = '888'}

local function Clock(seconds)
	local db = DB()
	seconds = max(0, seconds)
	local whole = floor(seconds)
	local text
	if db.timerFormat == 'sec' then text = format('%d', whole)
	elseif db.timerFormat == 'mss' then text = format('%d:%02d', floor(whole / 60), whole % 60)
	else text = whole >= 6000 and format('%03d', floor(whole / 60)) or format('%02d:%02d', floor(whole / 60), whole % 60) end
	if db.tenths then text = text..format('.%d', floor((seconds - whole) * 10)) end
	return text
end

local function Words(entering)
	local db = DB()
	if entering then
		if db.legend == 'custom' and db.legendText ~= '' then return strupper(db.legendText) end
		return db.legend == 'custom' and 'COMBAT' or db.legend
	end
	if db.clearWord == 'custom' and db.clearText ~= '' then return strupper(db.clearText) end
	return db.clearWord == 'custom' and 'CLEAR' or db.clearWord
end

local function PlaySound(name)
	if not name or name == 'off' then return end
	Kit:Play(name, true)
	if DB().soundDouble then C_Timer.After(0.05, function() Kit:Play(name, true) end) end
end

local function Tick()
	if not (status and status:IsShown() and started) then return end
	local elapsed = GetTime() - started
	status.time:SetText(Clock(elapsed))
	-- A sound each full minute of a real fight.
	local minute = floor(elapsed / 60)
	if fighting and minute > 0 and minute ~= lastMinute then
		lastMinute = minute
		PlaySound(DB().soundMinute)
	end
end

local function StartClock()
	if ticker then ticker:Cancel() end
	lastMinute = 0
	ticker = C_Timer.NewTicker(DB().tenths and 0.1 or 0.25, Tick)
	Tick()
end

local function StopClock()
	if ticker then ticker:Cancel(); ticker = nil end
end

-- Lay the device out for its layout, finish, scale and type.
local function LayoutStatus()
	if not status then return end
	local db = DB()
	local layout = LAYOUTS[db.statusLayout] and db.statusLayout or 'full'
	local size = LAYOUTS[layout]
	local surface = SURFACES[db.statusFinish] or 'paper'
	if status.surface ~= surface then
		status.surface = surface
		Kit:SetSurface(status.shell, surface)
		local ink = Kit.INK[surface] or Kit.INK.paper
		Kit:Tint(status.model, ink[1])
		Kit:Tint(status.title, ink[2])
	end
	status:SetSize(size[1], size[2])
	local scale = db.statusScale or 1
	status:SetScale(scale)
	holder:SetSize(size[1] * scale, size[2] * scale)
	local header = layout == 'full'
	status.model:SetShown(header)
	status.title:SetShown(header)
	status.lamp:ClearAllPoints()
	if layout == 'full' then
		status.lamp:SetSize(5, 5)
		status.lamp:SetPoint('TOPLEFT', 10, -9)
	elseif layout == 'lamp' then
		status.lamp:SetSize(10, 10)
		status.lamp:SetPoint('CENTER')
	else
		status.lamp:SetSize(7, 7)
		status.lamp:SetPoint('LEFT', 10, 0)
	end
	Kit:ShowLed(status.lamp, layout ~= 'timer')
	status.lcd:ClearAllPoints()
	if layout == 'full' then
		status.lcd:SetPoint('TOPLEFT', status, 'TOPLEFT', 8, -22)
		status.lcd:SetPoint('BOTTOMRIGHT', status, 'BOTTOMRIGHT', -8, 8)
	elseif layout == 'compact' then
		status.lcd:SetPoint('TOPLEFT', status, 'TOPLEFT', 24, -5)
		status.lcd:SetPoint('BOTTOMRIGHT', status, 'BOTTOMRIGHT', -6, 5)
	else
		status.lcd:SetPoint('TOPLEFT', status, 'TOPLEFT', 5, -5)
		status.lcd:SetPoint('BOTTOMRIGHT', status, 'BOTTOMRIGHT', -5, 5)
	end
	status.lcd:SetShown(layout ~= 'lamp')
	status.state:SetShown(layout == 'full')
	local digits = layout == 'full' and 20 or 15
	local ghost = (GHOSTS[db.timerFormat] or '88:88')..(db.tenths and '.8' or '')
	Kit:Font(status.ghost, digits, nil, true, 'numbers')
	Kit:Font(status.time, digits, nil, true, 'numbers')
	status.ghost:SetText(ghost)
end

local function Status()
	if status then return status end
	-- The mover holds the spot; the device moves inside it, so entrances and
	-- exits never disturb where Unlock mode put it.
	holder = CreateFrame('Frame', 'JiberishSpec01CombatStatus', UIParent)
	holder:SetSize(176, 62)
	holder:SetFrameStrata('HIGH')
	status = Kit:Device(holder, {surface = 'paper', model = 'CB-1', title = 'Combat', width = 176, height = 62, radius = 8})
	status.surface = 'paper'
	status:SetPoint('CENTER', holder, 'CENTER', 0, 0)
	status:EnableMouse(false)
	status.lcd = Kit:LCDPanel(status, {radius = 4})
	status.ghost = Kit:Text(status.lcd, '88:88', 20, 'lcdGhost', true)
	status.ghost:SetPoint('RIGHT', status.lcd, 'RIGHT', -9, 0)
	status.ghost:SetJustifyH('RIGHT')
	Kit:Ghost(status.ghost)
	status.time = Kit:Text(status.lcd, '00:00', 20, 'lcdInk', true)
	status.time:SetPoint('RIGHT', status.lcd, 'RIGHT', -9, 0)
	status.time:SetJustifyH('RIGHT')
	status.state = Kit:Label(status.lcd, '', 'lcdDim', 8, true)
	status.state:SetPoint('LEFT', status.lcd, 'LEFT', 9, 0)
	status:Hide()
	LayoutStatus()
	-- Unlock mode shows it in place so it can be moved.
	function holder:SetPreview(on)
		if on then
			status:ClearAllPoints()
			status:SetPoint('CENTER', holder, 'CENTER', 0, 0)
			status:SetAlpha(1)
			status:Show()
		elseif not (fighting or preview or DB().idle or DB().showcase) then
			status:Hide()
		end
	end
	UI:RegisterMover(holder, 'cue.status', 'Combat status', {'TOP', 0, -96})
	return status
end

-- Entrances and exits. kind: drop / slide / fade / pop / none, and rise / slide / fade / none.
local function Move(device, kind, entering, done)
	local base = DB().statusScale or 1
	local function Reset()
		device:ClearAllPoints()
		device:SetPoint('CENTER', holder, 'CENTER', 0, 0)
		device:SetScale(base)
	end
	if Reduced() or kind == 'none' then
		Reset()
		device:SetAlpha(entering and 1 or 0)
		if done then done() end
		return
	end
	local duration = entering and 0.42 or 0.45
	Kit:Animate(device, duration, 0, 1, function(value, progress)
		local x, y, scale = 0, 0, base
		local t = entering and 1 - value or value
		if kind == 'drop' then y = 26 * t
		elseif kind == 'rise' then y = 18 * t
		elseif kind == 'slide' then x = (entering and -40 or 40) * t
		elseif kind == 'pop' then scale = base * (1 - 0.15 * t) end
		device:ClearAllPoints()
		device:SetPoint('CENTER', holder, 'CENTER', x / max(scale, 0.01), y / max(scale, 0.01))
		device:SetScale(max(scale, 0.01))
		local alpha = entering and min(1, progress * 1.6) or 1 - progress
		device:SetAlpha(alpha)
	end, function() Reset(); if done then done() end end, entering and (kind == 'pop' and 'spring' or 'detent') or 'cubic')
end

local function SetState(entering)
	local db = status and DB()
	if not db then return end
	local color = entering and db.inColor or db.outColor
	local r, g, b = RGB(color, entering and RED or GREEN)
	Kit:SetLed(status.lamp, true, entering and 'red' or 'green')
	status.lamp:SetVertexColor(r, g, b)
	status.title:SetText(Words(entering))
	status.state:SetText(entering and 'LIVE' or 'DONE')
	status.state:SetTextColor(r, g, b)
	if db.timerInk == 'state' then status.time:SetTextColor(r, g, b) else Kit:Tint(status.time, 'lcdInk') end
end

-- Out of combat with Idle on: the device rests, lamp dark, reading READY.
local function Idle()
	if not (status and DB().idle and DB().status) or fighting then return end
	StopClock()
	Kit:Blink(status.lamp, nil, false)
	Kit:SetLed(status.lamp, false)
	status.title:SetText('READY')
	status.state:SetText('READY')
	Kit:Tint(status.state, 'lcdDim')
	Kit:Tint(status.time, 'lcdDim')
	if not status:IsShown() then
		status:Show()
		Move(status, DB().enter, true)
	end
end

local function Away(token)
	if not status or not status:IsShown() then return end
	if DB().idle then return Idle() end
	Move(status, DB().exit, false, function()
		if status.token == token then status:Hide(); StopClock() end
	end)
end

local function ShowStatus(entering)
	if not DB().status then
		if status then status:Hide() end
		return
	end
	local device = Status()
	LayoutStatus()
	local token = {}
	device.token = token
	if entering then
		SetState(true)
		if not device:IsShown() then device:Show(); Move(device, DB().enter, true) end
		if not Reduced() then
			Kit:Flash(device, {token = 'red', alpha = 0.3})
			Kit:Blink(device.lamp, 0.16, true)
			C_Timer.After(0.65, function() if device.token == token then Kit:Blink(device.lamp, nil, false) end end)
		end
		StartClock()
		-- Flash only: up for a moment, then away until the fight ends.
		if not DB().hold then C_Timer.After(2.4, function() if device.token == token then Away(token) end end) end
	else
		Kit:Blink(device.lamp, nil, false)
		StopClock()
		SetState(false)
		device.time:SetText(Clock(started and GetTime() - started or 0))
		if not device:IsShown() then device:Show(); Move(device, DB().enter, true) end
		Kit:Flash(device, {token = 'green', alpha = 0.35})
		C_Timer.After(DB().clearHold or 2.2, function() if device.token == token then Away(token) end end)
	end
end

-- Arming ring -------------------------------------------------------------------------------
local ringHolder, ring

local function PlayerFrame()
	for _, entry in ipairs(UI.GetMovers and UI:GetMovers() or {}) do
		if entry.key == 'uf.player' then return entry.frame end
	end
end

-- Where the ring sits: its own mover when custom, else docked to a spot.
-- Only "on your unit frame" follows another frame; every other spot is a
-- plain mover spot, so Unlock mode can always drag the ring (and a drag makes
-- it Custom). A preset spot is applied once, when it is chosen.
local placingRing = false
local function PlaceRing()
	if not ringHolder then return end
	local db = DB()
	local size = 2 * (db.ringRadius or 74) + 40
	ringHolder:SetSize(size, size)
	if db.ringPos == 'frame' then
		UI:DockMover('cue.ring', function(frame)
			local player = PlayerFrame()
			if player then frame:SetPoint('CENTER', player, 'CENTER', 0, 0)
			else frame:SetPoint('CENTER', UIParent, 'CENTER', 0, -70) end
		end)
		return
	end
	UI:DockMover('cue.ring', nil)
	if db.ringPlaced ~= db.ringPos and db.ringPos ~= 'custom' then
		placingRing = true
		UI:SetMoverPosition('cue.ring', 'CENTER', 0, db.ringPos == 'center' and 0 or -70)
		placingRing = false
	end
	db.ringPlaced = db.ringPos
end

-- Dragging the ring in Unlock mode makes its position Custom.
UI:OnMoversChanged(function(key)
	if key ~= 'cue.ring' or placingRing or not UI:MoversUnlocked() then return end
	local db = DB()
	if db.ringPos ~= 'frame' and db.ringPos ~= 'custom' then db.ringPos, db.ringPlaced = 'custom', 'custom' end
end)

local function Ring()
	if ring then return ring end
	ringHolder = CreateFrame('Frame', 'JiberishSpec01CombatRing', UIParent)
	ringHolder:SetSize(188, 188)
	ringHolder:SetFrameStrata('HIGH')
	ringHolder:EnableMouse(false)
	ring = CreateFrame('Frame', nil, ringHolder)
	ring:SetAllPoints()
	ring.ticks = {}
	ring.core = Kit:Texture(ring, 'glow', 'ARTWORK')
	ring.core:SetPoint('CENTER')
	ring.core:SetBlendMode('ADD')
	ring:SetAlpha(0)
	ring:Hide()
	function ringHolder:SetPreview(on)
		if on then
			ring.preview = true
			ring:Show()
			ring:SetAlpha(0.6)
			for _, tick in ipairs(ring.ticks) do tick:SetAlpha(0.8) end
		elseif ring.preview and not DB().showcase then
			ring.preview = nil
			if not (fighting and DB().ringHold) then ring:Hide() end
		end
	end
	UI:RegisterMover(ringHolder, 'cue.ring', 'Combat ring', {'CENTER', 0, -70})
	PlaceRing()
	return ring
end

-- Lay out ticks for the current style, count, size and a direction.
local function LayoutRing(clockwise)
	local db = DB()
	local count = max(8, floor(db.ringTicks or 60))
	local radius = db.ringRadius or 74
	local thick = Px(ring, db.ringWidth or 2)
	local length = db.ringLength or 6
	local style = db.ringStyle
	for index = #ring.ticks + 1, count do
		local tick = ring:CreateTexture(nil, 'OVERLAY')
		ring.ticks[index] = tick
	end
	for index, tick in ipairs(ring.ticks) do
		if index > count then
			tick:Hide()
		else
			local step = 2 * pi * (index - 1) / count
			local angle = pi / 2 + (clockwise and -step or step)
			local major = (index - 1) % max(1, floor(count / 4)) == 0
			tick.major = major
			tick:ClearAllPoints()
			if style == 'dots' then
				tick:SetTexture(Kit.media..'circle.tga')
				local dot = max(thick * 1.6, major and length * 0.6 or length * 0.4)
				tick:SetSize(dot, dot)
				tick:SetRotation(0)
				tick:SetPoint('CENTER', ring, 'CENTER', radius * cos(angle), radius * sin(angle))
			elseif style == 'arc' then
				tick:SetColorTexture(1, 1, 1, 1)
				local arc = 2 * pi * radius / count * 0.78
				tick:SetSize(arc, thick * (major and 2 or 1.5))
				tick:SetRotation(angle - pi / 2)
				tick:SetPoint('CENTER', ring, 'CENTER', radius * cos(angle), radius * sin(angle))
			else
				tick:SetColorTexture(1, 1, 1, 1)
				local size = major and length * 2 or length
				local at = radius + (major and length * 0.5 or 0)
				tick:SetSize(thick, size)
				tick:SetRotation(angle - pi / 2)
				tick:SetPoint('CENTER', ring, 'CENTER', at * cos(angle), at * sin(angle))
			end
			tick:Show()
		end
	end
	ring.count = count
	ring.core:SetSize(2 * radius + 40, 2 * radius + 40)
end

local function ArmRing(entering)
	if not DB().ring then
		if ring then ring:Hide() end
		return
	end
	local r = Ring()
	PlaceRing()
	if Reduced() then r:Hide() return end
	local db = DB()
	local clockwise = db.ringDir == 'cw'
	if not entering then clockwise = not clockwise end
	LayoutRing(clockwise)
	local count = r.count
	local ticks = {}
	for index = 1, count do ticks[index] = r.ticks[index] end
	Paint(entering and db.ringIn or db.ringOut, entering and RED or GREEN, r.core, unpack(ticks))
	r.core:SetAlpha(0)
	r:Show()
	r:SetAlpha(1)
	local speed = max(0.25, db.ringSpeed or 1)
	Kit:Animate(r, (entering and 0.35 or 0.6) / speed, 0, 1, function(value)
		local lit = value * count
		for index = 1, count do
			local tick = ticks[index]
			tick:SetAlpha(index <= lit and (tick.major and 1 or 0.85) or 0.12)
		end
	end, function()
		-- One brighter flash, then out (or a faint hold for the fight).
		for index = 1, count do ticks[index]:SetAlpha(1) end
		local hold = entering and db.ringHold
		Kit:Animate(r.core, (entering and 0.55 or 0.8) / speed, 0, 1, function(_, progress)
			r.core:SetAlpha(0.28 * (1 - progress))
			r:SetAlpha(hold and 1 - 0.8 * progress or 1 - progress * progress)
		end, function() if not hold or not (fighting or preview) then r:Hide() end end, 'linear')
	end, 'cubic')
end

-- Show while configuring: the status device in its live state and the ring
-- lit, held on screen out of combat so they can be styled and placed.
local showing = false
local function ShowCase(on)
	if fighting then return end
	showing = on and true or false
	local db = DB()
	if showing then
		if db.status then
			local device = Status()
			LayoutStatus()
			device.token = {}
			StopClock()
			SetState(true)
			device:ClearAllPoints()
			device:SetPoint('CENTER', holder, 'CENTER', 0, 0)
			device:SetScale(db.statusScale or 1)
			device:SetAlpha(1)
			device.time:SetText(Clock(42))
			device:Show()
		elseif status then
			status:Hide()
		end
		if db.ring then
			local r = Ring()
			PlaceRing()
			LayoutRing(db.ringDir == 'cw')
			local ticks = {}
			for index = 1, r.count do ticks[index] = r.ticks[index] end
			Paint(db.ringIn, RED, r.core, unpack(ticks))
			for index = 1, r.count do ticks[index]:SetAlpha(ticks[index].major and 1 or 0.85) end
			r.core:SetAlpha(0.12)
			r.preview = true
			r:SetAlpha(1)
			r:Show()
		elseif ring then
			ring:Hide()
		end
	else
		if status and not (preview or db.idle) then status:Hide() end
		if status and db.idle then Idle() end
		if ring then ring.preview = nil; ring:Hide() end
	end
end
module.ShowCase = ShowCase

-- Device lamps -------------------------------------------------------------------------------
local lit = setmetatable({}, {__mode = 'k'}) -- lamps we lit for the fight
local setting = false                        -- our own Kit:SetLed calls
local hooked = false

local function Hook()
	if hooked then return end
	hooked = true
	-- A lamp's own module setting it during the fight takes it back from us.
	hooksecurefunc(Kit, 'SetLed', function(_, led)
		if not setting and lit[led] then lit[led] = nil end
	end)
end

-- Which group a device belongs to, from the mover that carries it.
local function GroupOf(device, byFrame)
	local frame = device
	for _ = 1, 8 do
		if not frame then break end
		local key = byFrame[frame]
		if key then
			if key:find('^uf%.') or key:find('^cb%.') then return 'units' end
			if key:find('^ab%.') then return 'bars' end
			if key:find('^group%.') then return 'group' end
			return 'other'
		end
		frame = frame.GetParent and frame:GetParent()
	end
	return 'other'
end

local function Wanted(group)
	local db = DB()
	if db.lampScope == 'all' then return true end
	if db.lampScope == 'units' then return group == 'units' end
	if db.lampScope == 'bars' then return group == 'bars' end
	return (group == 'units' and db.lampUnits) or (group == 'bars' and db.lampBars)
		or (group == 'group' and db.lampGroup) or (group == 'other' and db.lampOther) or false
end

local function LightLamps()
	if not DB().lamps then return end
	Hook()
	local byFrame = {}
	for _, entry in ipairs(UI.GetMovers and UI:GetMovers() or {}) do byFrame[entry.frame] = entry.key end
	local cx, cy = UIParent:GetCenter()
	local list = {}
	for device in pairs(Kit.devices or {}) do
		local lamp = device.lamp
		if device ~= status and lamp and not lit[lamp] and not lamp.on and lamp:IsVisible() and device:IsVisible()
			and Wanted(GroupOf(device, byFrame)) then
			local x, y = device:GetCenter()
			if x and y and not IsSecret(x) and not IsSecret(y) then
				local ratio = device:GetEffectiveScale() / UIParent:GetEffectiveScale()
				list[#list + 1] = {lamp = lamp, distance = abs(x * ratio - cx) + abs(y * ratio - cy)}
			end
		end
	end
	table.sort(list, function(a, b) return a.distance < b.distance end)
	local farthest = list[#list] and list[#list].distance or 1
	local spread, token = DB().lampSpeed or 0.3, DB().lampColor or 'red'
	for _, item in ipairs(list) do
		local lamp = item.lamp
		lit[lamp] = true
		local function Light()
			if not lit[lamp] then return end
			setting = true
			Kit:SetLed(lamp, true, token)
			setting = false
		end
		if Reduced() or spread <= 0 then Light() else C_Timer.After(spread * item.distance / max(farthest, 1), Light) end
	end
end

local function RestoreLamps()
	for lamp in pairs(lit) do
		lit[lamp] = nil
		setting = true
		Kit:SetLed(lamp, false)
		setting = false
	end
end

-- Edge glow ------------------------------------------------------------------------------------
local edges
local SIDES = {all = {'TOP', 'BOTTOM', 'LEFT', 'RIGHT'}, topbottom = {'TOP', 'BOTTOM'}, sides = {'LEFT', 'RIGHT'},
	bottom = {'BOTTOM'}}

local function StopEdges()
	if not edges then return end
	for _, glow in pairs(edges) do
		Kit:Breathe(glow, false)
		Kit:FadeTo(glow, 0, 'SLOW')
	end
end

local function EdgeGlow(entering)
	if not entering then return StopEdges() end
	local db = DB()
	if not db.edge or Reduced() then return end
	edges = edges or {}
	local width, height = UIParent:GetSize()
	local shown = {}
	for _, side in ipairs(SIDES[db.edgeSides] or SIDES.all) do
		local glow = edges[side]
		if not glow then
			glow = Kit:Texture(Root(), 'glow', 'ARTWORK')
			glow:SetBlendMode('ADD')
			edges[side] = glow
		end
		glow:ClearAllPoints()
		if side == 'TOP' or side == 'BOTTOM' then glow:SetSize(width * 1.2, 90) else glow:SetSize(90, height * 1.2) end
		glow:SetPoint('CENTER', root, side, 0, 0)
		Paint(db.edgeColor, RED, glow)
		shown[#shown + 1] = glow
	end
	local peak = db.edgeIntensity or 0.55
	Kit:Animate(shown, db.edgeDuration or 0.7, 0, 1, function(_, progress)
		local alpha = peak * sin(pi * progress)
		if db.edgePulse and progress > 0.5 then alpha = max(alpha, peak * 0.35) end
		for _, glow in ipairs(shown) do glow:SetAlpha(alpha) end
	end, function()
		for _, glow in ipairs(shown) do
			if db.edgePulse and (fighting or preview) then
				glow:SetAlpha(peak * 0.35)
				Kit:Breathe(glow, true, {period = 2.4, low = 0.3})
			else
				glow:SetAlpha(0)
			end
		end
	end, 'linear')
end

-- Brackets, rails and frame trace -------------------------------------------------------------
local brackets, rails
local CORNERS = {{'TOPLEFT', 1, -1}, {'TOPRIGHT', -1, -1}, {'BOTTOMLEFT', 1, 1}, {'BOTTOMRIGHT', -1, 1}}

local function BuildFrames()
	if brackets then return end
	brackets, rails = {}, {}
	for index, corner in ipairs(CORNERS) do
		local bracket = CreateFrame('Frame', nil, Root())
		bracket.corner = corner
		bracket.across = bracket:CreateTexture(nil, 'OVERLAY')
		bracket.down = bracket:CreateTexture(nil, 'OVERLAY')
		for _, piece in ipairs({bracket.across, bracket.down}) do piece:SetColorTexture(1, 1, 1, 1) end
		bracket:SetAlpha(0)
		brackets[index] = bracket
	end
	for index, side in ipairs({'TOP', 'BOTTOM'}) do
		local rail = root:CreateTexture(nil, 'OVERLAY')
		rail:SetColorTexture(1, 1, 1, 1)
		rail.side = side
		rail:SetAlpha(0)
		rails[index] = rail
	end
end

local function PlaceBrackets(t)
	local db = DB()
	local width, height = UIParent:GetSize()
	local thickness, arm, inset = Px(root, 2), db.bracketSize or 28, db.bracketInset or 10
	for _, bracket in ipairs(brackets) do
		local point, sx, sy = bracket.corner[1], bracket.corner[2], bracket.corner[3]
		bracket:SetSize(arm, arm)
		bracket.across:ClearAllPoints(); bracket.across:SetPoint(point); bracket.across:SetSize(arm, thickness)
		bracket.down:ClearAllPoints(); bracket.down:SetPoint(point); bracket.down:SetSize(thickness, arm)
		bracket:ClearAllPoints()
		bracket:SetPoint(point, root, point, sx * (inset + width * 0.16 * (1 - t)), sy * (inset + height * 0.16 * (1 - t)))
	end
end

local function Extras(entering)
	local db = DB()
	local color, fallback = entering and db.extrasIn or db.extrasOut, entering and RED or GREEN
	if db.brackets and not Reduced() then
		BuildFrames()
		for _, bracket in ipairs(brackets) do Paint(color, fallback, bracket.across, bracket.down) end
		Kit:Animate(brackets, entering and 0.42 or 0.7, 0, 1, function(value, progress)
			PlaceBrackets(entering and value or 1 - 0.4 * value)
			local alpha = entering and min(1, progress * 3) or (1 - progress)
			for _, bracket in ipairs(brackets) do bracket:SetAlpha(alpha) end
		end, function()
			if entering then
				C_Timer.After(0.5, function() for _, bracket in ipairs(brackets) do Kit:FadeTo(bracket, 0, 'SLOW') end end)
			end
		end, entering and 'detent' or 'cubic')
	end
	if db.rails and not Reduced() then
		BuildFrames()
		local width = UIParent:GetWidth()
		local active = {}
		for _, rail in ipairs(rails) do
			local wanted = db.railSides == 'both' or (db.railSides == 'top' and rail.side == 'TOP')
				or (db.railSides == 'bottom' and rail.side == 'BOTTOM')
			rail:SetAlpha(0)
			if wanted then
				Paint(color, fallback, rail)
				rail:ClearAllPoints()
				rail:SetPoint(rail.side, root, rail.side, 0, 0)
				rail:SetHeight(Px(root, 1))
				active[#active + 1] = rail
			end
		end
		Kit:Animate(rails, entering and 0.5 or 0.8, 0, 1, function(value, progress)
			local alpha = progress < 0.6 and 0.9 or 0.9 * (1 - (progress - 0.6) / 0.4)
			for _, rail in ipairs(active) do rail:SetWidth(max(width * min(1, value * 1.15), 1)); rail:SetAlpha(alpha) end
		end, function() for _, rail in ipairs(active) do rail:SetAlpha(0) end end, 'cubic')
	end
end

local traces = setmetatable({}, {__mode = 'k'})

local function AlongEdge(width, height, along)
	local at = (along % 1) * 2 * (width + height)
	if at < width then return at, 0 end
	at = at - width
	if at < height then return width, -at end
	at = at - height
	if at < width then return width - at, -height end
	return 0, -(height - (at - width))
end

local function RunTrace(frame, color, fallback, duration)
	local trace = traces[frame]
	if not trace then
		trace = CreateFrame('Frame', nil, Root())
		trace.head = Kit:Texture(trace, 'glow', 'OVERLAY', 2)
		trace.head:SetSize(26, 26)
		trace.head:SetBlendMode('ADD')
		trace.dot = trace:CreateTexture(nil, 'OVERLAY', nil, 3)
		trace.dot:SetColorTexture(1, 1, 1, 1)
		traces[frame] = trace
	end
	trace:ClearAllPoints()
	trace:SetAllPoints(frame)
	local width, height = frame:GetSize()
	if IsSecret(width) or IsSecret(height) or not width or not height then return end
	local ratio = frame:GetEffectiveScale() / trace:GetEffectiveScale()
	width, height = width * ratio, height * ratio
	if width < 8 or height < 8 then return end
	trace.dot:SetSize(Px(trace, 2), Px(trace, 2))
	Paint(color, fallback, trace.head, trace.dot)
	trace:Show()
	Kit:Animate(trace, duration, 0, 1, function(value, progress)
		local x, y = AlongEdge(width, height, value)
		trace.head:ClearAllPoints(); trace.head:SetPoint('CENTER', trace, 'TOPLEFT', x, y)
		trace.dot:ClearAllPoints(); trace.dot:SetPoint('CENTER', trace, 'TOPLEFT', x, y)
		trace:SetAlpha(progress > 0.85 and (1 - progress) / 0.15 or 1)
	end, function() trace:Hide() end, 'inout')
end

local function TraceAll(entering)
	local db = DB()
	if not db.trace or Reduced() then return end
	local color, fallback = entering and db.extrasIn or db.extrasOut, entering and RED or GREEN
	local cx, cy = UIParent:GetCenter()
	for _, entry in ipairs(UI.GetMovers and UI:GetMovers() or {}) do
		local frame = entry.frame
		if frame and frame ~= holder and frame ~= ringHolder and not entry.docked and frame:IsVisible()
			and frame:GetAlpha() > 0.05 then
			local x, y = frame:GetCenter()
			if x and y and not IsSecret(x) and not IsSecret(y) then
				local delay = min(0.3, (abs(x - cx) + abs(y - cy)) / 4000)
				C_Timer.After(delay, function() UI:Safe(RunTrace, frame, color, fallback, entering and 0.65 or 0.9) end)
			end
		end
	end
end

-- Driver --------------------------------------------------------------------------------------
local function Cue(entering)
	if entering then UI:Safe(LightLamps) else UI:Safe(RestoreLamps) end
	UI:Safe(ShowStatus, entering)
	UI:Safe(ArmRing, entering)
	UI:Safe(EdgeGlow, entering)
	UI:Safe(Extras, entering)
	UI:Safe(TraceAll, entering)
	local db = DB()
	if db.sound then
		if entering then
			PlaySound(db.soundEnter)
			C_Timer.After(0.09, function() PlaySound(db.soundEnter2) end)
		else
			PlaySound(db.soundLeave)
		end
	end
end

function module:Enable()
	local db = DB()
	Upgrade(db)
	db.showcase = false
	if not db.enable then return end
	Status()
	if db.ring then Ring() end
	local events = CreateFrame('Frame')
	events:RegisterEvent('PLAYER_REGEN_DISABLED')
	events:RegisterEvent('PLAYER_REGEN_ENABLED')
	events:RegisterEvent('PLAYER_ENTERING_WORLD')
	events:SetScript('OnEvent', function(_, event)
		if event == 'PLAYER_ENTERING_WORLD' then
			C_Timer.After(1, function() if not fighting then UI:Safe(Idle) end end)
			return
		end
		local entering = event == 'PLAYER_REGEN_DISABLED'
		-- A real fight ends any preview, and the configuring view.
		preview = nil
		if entering and showing then showing = false; DB().showcase = false; if ring then ring.preview = nil end end
		if entering and not Allowed() then fighting = true return end
		if not entering and not fighting then return end
		local cued = entering or (status and status:IsShown()) or next(lit) ~= nil or Allowed()
		fighting = entering
		if entering then started = GetTime() end
		if cued then Cue(entering) end
	end)
	self.ready = true
end

-- Settings changed: lay out again, and show or drop the idle device.
function module:Refresh()
	if not self.ready then return end
	if status then
		LayoutStatus()
		if not DB().status then status:Hide()
		elseif DB().idle and not fighting and not preview then Idle()
		elseif not DB().idle and not fighting and not preview and status.title:GetText() == 'READY' then status:Hide() end
	end
	if DB().ring then Ring() end
	PlaceRing()
	if showing or DB().showcase then ShowCase(DB().showcase) end
end

-- Previews: going in runs for a few seconds, then plays coming out by itself,
-- so nothing is left lit. Neither does anything during a real fight.
local loop
function module:Preview(entering)
	if fighting or InCombatLockdown() then return end
	Upgrade(DB())
	local token = {}
	preview = token
	if entering then
		started = GetTime() - 42
		Cue(true)
		C_Timer.After(3.5, function()
			if preview == token and not fighting then preview = nil; Cue(false) end
		end)
	else
		if not started then started = GetTime() - 42 end
		preview = nil
		Cue(false)
	end
end

local function StopLoop()
	if loop then loop:Cancel(); loop = nil end
end

local function ToggleLoop()
	if loop then StopLoop() return end
	module:Preview(true)
	loop = C_Timer.NewTicker(5.5, function()
		if fighting then StopLoop() return end
		module:Preview(true)
	end)
end

-- Presets set groups of options at once.
local PRESETS = {
	minimal = {status = true, hold = true, statusLayout = 'compact', enter = 'fade', exit = 'fade', ring = false,
		lamps = true, edge = false, edgePulse = false, brackets = false, rails = false, trace = false, sound = true,
		soundEnter = 'tick', soundEnter2 = 'off', soundLeave = 'tick'},
	standard = {status = true, hold = true, statusLayout = 'full', statusScale = 1, enter = 'drop', exit = 'rise',
		ring = true, ringStyle = 'ticks', ringRadius = 74, ringTicks = 60, ringHold = false, lamps = true, edge = false,
		edgePulse = false, brackets = false, rails = false, trace = false, sound = true, soundEnter = 'latch-down',
		soundEnter2 = 'blip', soundLeave = 'success'},
	cinematic = {status = true, hold = true, statusLayout = 'full', statusScale = 1.15, enter = 'pop', exit = 'rise',
		ring = true, ringStyle = 'ticks', ringRadius = 96, ringTicks = 72, ringHold = true, lamps = true, edge = true,
		edgePulse = true, brackets = true, rails = true, trace = false, sound = true, soundEnter = 'latch-down',
		soundEnter2 = 'blip', soundLeave = 'success'},
	off = {status = false, ring = false, lamps = false, edge = false, edgePulse = false, brackets = false,
		rails = false, trace = false, sound = false},
}

local function ApplyPreset(name)
	local db = DB()
	for key, value in pairs(PRESETS[name]) do db[key] = value end
	Kit:Play('latch-down', true)
	Kit:Apply()
end

-- Hub -------------------------------------------------------------------------------------------
local function Off() return not DB().enable end
local function NoStatus() return Off() or not DB().status end
local function NoRing() return Off() or not DB().ring end
local function NoLamps() return Off() or not DB().lamps end
local function NoEdge() return Off() or not DB().edge end
local function NoSound() return Off() or not DB().sound end
local function NoExtras() return Off() or not (DB().brackets or DB().rails or DB().trace) end
local function Times(value) return format('%.2fx', value) end
local function Seconds(value) return format('%.1f s', value) end
local function Units(value) return format('%d', value + 0.5) end
local function Pixels(value) return format('%d px', value + 0.5) end
local Percent = UI.Util.Percent

local SOUNDS = {{'off', 'None'}}
for _, name in ipairs({'latch-down', 'latch-up', 'blip', 'success', 'tick', 'down', 'down-primary', 'up', 'open',
	'warning', 'error', 'type', 'type-big'}) do
	SOUNDS[#SOUNDS + 1] = {name, (name:gsub('-', ' '):gsub('^%l', strupper))}
end
local LAMP_TOKENS = {{'red', 'Red'}, {'amber', 'Amber'}, {'lamp', 'Key color'}, {'green', 'Green'}, {'blue', 'Blue'}}

UI:RegisterPage('combatcue', {title = 'Combat cues', order = 4.2, onHide = StopLoop, cards = {
	{title = 'Combat cues', rows = {
		{'switch', 'Combat cues', 'combatcue.enable', 'The interface switches into a live state as a fight starts, and back as it ends.', reload = true, since = '0.5.1'},
		{'dropdown', 'Show in', 'combatcue.where', items = {{'always', 'Everywhere'}, {'instances', 'Instances only'},
			{'world', 'Open world only'}, {'group', 'When grouped'}}, disabled = Off, since = '0.5.1'},
		{'button', 'Preset: Minimal', 'Apply', function() ApplyPreset('minimal') end},
		{'button', 'Preset: Standard', 'Apply', function() ApplyPreset('standard') end},
		{'button', 'Preset: Cinematic', 'Apply', function() ApplyPreset('cinematic') end},
		{'button', 'Preset: Off', 'Apply', function() ApplyPreset('off') end},
	}},
	{title = 'Preview', rows = {
		{'switch', 'Show while configuring', 'combatcue.showcase', 'Keeps the status device and the ring on screen out of combat, so you can style them and place them in Unlock mode. Off again after a reload or when a fight starts.',
			disabled = Off, since = '0.5.2', set = function(value) DB().showcase = value and true or false; UI:Safe(ShowCase, value) end},
		{'button', 'Move them', 'Unlock', function() if UI.ToggleHub then UI:ToggleHub(nil, false) end; UI:ToggleMovers(false) end,
			'Unlock mode: drag the status device or the ring; a dragged ring becomes Custom.'},
		{'button', 'Going in', 'Play', function() module:Preview(true) end},
		{'button', 'Coming out', 'Play', function() module:Preview(false) end},
		{'button', 'Loop preview', 'Start / stop', ToggleLoop},
		{'note', 'Previews follow every setting here.'},
	}},
	{title = 'Status device', rows = {
		{'switch', 'Status device', 'combatcue.status', 'A CB-1 device: a lamp, the legend and the fight\'s time.', disabled = Off, since = '0.5.1'},
		{'segmented', 'Layout', 'combatcue.statusLayout', items = {{'full', 'Full'}, {'compact', 'Compact'}, {'timer', 'Timer'}, {'lamp', 'Lamp'}}, disabled = NoStatus},
		{'dropdown', 'Finish', 'combatcue.statusFinish', items = {{'theme', 'Follow theme'}, {'paper', 'Paper'}, {'graphite', 'Graphite'}, {'lcd', 'LCD'}, {'glass', 'Glass'}}, disabled = NoStatus},
		{'slider', 'Scale', 'combatcue.statusScale', 0.6, 2, 0.05, nil, format = Times, disabled = NoStatus},
		{'switch', 'Keep it up', 'combatcue.hold', 'Up for the whole fight. Off: it flashes in, then waits for the fight to end.', disabled = NoStatus},
		{'switch', 'Idle READY state', 'combatcue.idle', 'Stays on screen out of combat, lamp dark, reading READY.', disabled = NoStatus},
		{'dropdown', 'Combat legend', 'combatcue.legend', items = {{'COMBAT', 'COMBAT'}, {'FIGHT', 'FIGHT'}, {'ENGAGED', 'ENGAGED'}, {'custom', 'Custom'}}, disabled = NoStatus},
		{'input', 'Custom legend', 'combatcue.legendText', hidden = function() return DB().legend ~= 'custom' end},
		{'dropdown', 'Clear legend', 'combatcue.clearWord', items = {{'CLEAR', 'CLEAR'}, {'DONE', 'DONE'}, {'custom', 'Custom'}}, disabled = NoStatus},
		{'input', 'Custom clear legend', 'combatcue.clearText', hidden = function() return DB().clearWord ~= 'custom' end},
		{'segmented', 'Timer', 'combatcue.timerFormat', items = {{'mmss', '00:00'}, {'mss', '0:00'}, {'sec', 'Seconds'}}, disabled = NoStatus},
		{'switch', 'Tenths', 'combatcue.tenths', 'A tenth-of-a-second digit on the timer.', disabled = NoStatus},
		{'segmented', 'Timer ink', 'combatcue.timerInk', items = {{'lcd', 'LCD'}, {'state', 'State color'}}, disabled = NoStatus},
		{'color', 'In combat', 'combatcue.inColor', 'The lamp and LIVE tag in a fight.', disabled = NoStatus},
		{'color', 'Out of combat', 'combatcue.outColor', 'The lamp and DONE tag as it ends.', disabled = NoStatus},
		{'dropdown', 'Entrance', 'combatcue.enter', items = {{'drop', 'Drop'}, {'slide', 'Slide'}, {'fade', 'Fade'}, {'pop', 'Pop'}, {'none', 'None'}}, disabled = NoStatus},
		{'dropdown', 'Exit', 'combatcue.exit', items = {{'rise', 'Rise'}, {'slide', 'Slide'}, {'fade', 'Fade'}, {'none', 'None'}}, disabled = NoStatus},
		{'slider', 'CLEAR holds', 'combatcue.clearHold', 0.5, 8, 0.1, nil, format = Seconds, disabled = NoStatus},
	}},
	{title = 'Arming ring', rows = {
		{'switch', 'Arming ring', 'combatcue.ring', 'Ticks light in sequence around a point as a fight starts and ends.', disabled = Off, since = '0.5.1'},
		{'dropdown', 'Position', 'combatcue.ringPos', items = {{'center', 'Screen centre'}, {'player', 'Under your character'},
			{'frame', 'On your unit frame'}, {'custom', 'Custom (Unlock mode)'}}, disabled = NoRing},
		{'segmented', 'Style', 'combatcue.ringStyle', items = {{'ticks', 'Ticks'}, {'dots', 'Dots'}, {'arc', 'Arc'}}, disabled = NoRing},
		{'slider', 'Radius', 'combatcue.ringRadius', 30, 200, 2, nil, format = Units, disabled = NoRing},
		{'slider', 'Ticks', 'combatcue.ringTicks', 16, 120, 4, nil, format = Units, disabled = NoRing},
		{'slider', 'Tick length', 'combatcue.ringLength', 2, 20, 1, nil, format = Units, disabled = NoRing},
		{'slider', 'Tick thickness', 'combatcue.ringWidth', 1, 4, 1, 'In screen pixels.', format = Pixels, disabled = NoRing},
		{'segmented', 'Direction', 'combatcue.ringDir', items = {{'cw', 'Clockwise'}, {'ccw', 'Counter'}}, disabled = NoRing},
		{'slider', 'Speed', 'combatcue.ringSpeed', 0.5, 2, 0.05, nil, format = Times, disabled = NoRing},
		{'color', 'Going in', 'combatcue.ringIn', nil, disabled = NoRing},
		{'color', 'Coming out', 'combatcue.ringOut', nil, disabled = NoRing},
		{'switch', 'Hold during the fight', 'combatcue.ringHold', 'The ring stays faintly lit until the fight ends.', disabled = NoRing},
	}},
	{title = 'Device lamps', rows = {
		{'switch', 'Device lamps', 'combatcue.lamps', 'Dark SPEC-01 lamps light for the fight, cascading out from the middle.', disabled = Off, since = '0.5.1'},
		{'dropdown', 'Color', 'combatcue.lampColor', items = LAMP_TOKENS, disabled = NoLamps},
		{'slider', 'Cascade', 'combatcue.lampSpeed', 0, 1, 0.05, 'How long the cascade takes to reach the farthest lamp. 0: all at once.', format = Seconds, disabled = NoLamps},
		{'dropdown', 'Which devices', 'combatcue.lampScope', items = {{'all', 'All'}, {'units', 'Unit frames'}, {'bars', 'Bars and console'}, {'custom', 'Choose'}}, disabled = NoLamps},
		{'switch', 'Unit frames', 'combatcue.lampUnits', nil, hidden = function() return DB().lampScope ~= 'custom' end},
		{'switch', 'Bars and console', 'combatcue.lampBars', nil, hidden = function() return DB().lampScope ~= 'custom' end},
		{'switch', 'Raid, boss and arena', 'combatcue.lampGroup', nil, hidden = function() return DB().lampScope ~= 'custom' end},
		{'switch', 'Everything else', 'combatcue.lampOther', nil, hidden = function() return DB().lampScope ~= 'custom' end},
	}},
	{title = 'Edge glow', rows = {
		{'switch', 'Edge glow', 'combatcue.edge', 'A glow along the edges of the screen as a fight starts.', disabled = Off, since = '0.5.1'},
		{'dropdown', 'Edges', 'combatcue.edgeSides', items = {{'all', 'All four'}, {'topbottom', 'Top and bottom'}, {'sides', 'Left and right'}, {'bottom', 'Bottom'}}, disabled = NoEdge},
		{'color', 'Color', 'combatcue.edgeColor', nil, disabled = NoEdge},
		{'slider', 'Intensity', 'combatcue.edgeIntensity', 0.1, 1, 0.05, nil, format = Percent, disabled = NoEdge},
		{'slider', 'Duration', 'combatcue.edgeDuration', 0.2, 2, 0.1, nil, format = Seconds, disabled = NoEdge},
		{'switch', 'Pulse during the fight', 'combatcue.edgePulse', 'The edges keep breathing faintly until the fight ends.', disabled = NoEdge},
	}},
	{title = 'Extras', rows = {
		{'switch', 'Corner brackets', 'combatcue.brackets', 'Brackets drop in and lock onto the screen\'s corners.', disabled = Off, since = '0.5.1'},
		{'slider', 'Bracket size', 'combatcue.bracketSize', 12, 80, 2, nil, format = Units, hidden = function() return not DB().brackets end},
		{'slider', 'Bracket inset', 'combatcue.bracketInset', 0, 80, 2, nil, format = Units, hidden = function() return not DB().brackets end},
		{'switch', 'Rails', 'combatcue.rails', 'Hairlines draw out along the screen\'s edges.', disabled = Off, since = '0.5.1'},
		{'segmented', 'Rail edges', 'combatcue.railSides', items = {{'both', 'Both'}, {'top', 'Top'}, {'bottom', 'Bottom'}}, hidden = function() return not DB().rails end},
		{'switch', 'Frame trace', 'combatcue.trace', 'A lit head runs once around every SPEC-01 frame. While it is on, the unit frames\' own combat sweep stands down.', disabled = Off, since = '0.5.1'},
		{'color', 'Going in', 'combatcue.extrasIn', nil, disabled = NoExtras},
		{'color', 'Coming out', 'combatcue.extrasOut', nil, disabled = NoExtras},
	}},
	{title = 'Sounds', rows = {
		{'switch', 'Sounds', 'combatcue.sound', nil, disabled = Off, since = '0.5.1'},
		{'dropdown', 'Going in', 'combatcue.soundEnter', items = SOUNDS, disabled = NoSound},
		{'dropdown', 'Then', 'combatcue.soundEnter2', items = SOUNDS, disabled = NoSound},
		{'dropdown', 'Coming out', 'combatcue.soundLeave', items = SOUNDS, disabled = NoSound},
		{'dropdown', 'Every minute', 'combatcue.soundMinute', items = SOUNDS, disabled = NoSound},
		{'switch', 'Louder', 'combatcue.soundDouble', 'Each sound plays twice, a hair apart.', disabled = NoSound},
	}},
}})
