-- Combat cues: the interface switching into a live state as a fight starts, and
-- back as it ends, told with SPEC-01's own hardware.
--
--   * Status: a CB-1 device drops in at the top of the screen with a detent. Its
--     lamp blinks red then holds, the legend reads COMBAT and an LCD counts the
--     fight up (mm:ss over unlit 88:88). On leaving it flips to a green lamp,
--     CLEAR and the fight's length, holds, then rises away. It can stay up for
--     the whole fight or only flash. Unlock mode places it ('Combat status').
--   * Arming ring: hairline ticks around where your character stands light in
--     sequence, clockwise in red going in (counter-clockwise in green coming
--     out), flash once and fade. Drawn from code, so it stays crisp.
--   * Lamps: every SPEC-01 device lamp that is dark lights red for the fight,
--     cascading out from the middle of the screen; each goes back exactly as it
--     was, unless its own module changed it meanwhile.
--   * Edge glow (off by default): a brief red glow along the screen's edges.
--   * Brackets, rails and frame trace from the first version stay as options,
--     off by default.
--
-- Everything here is our own unprotected frames, so it all runs in combat. With
-- reduced motion nothing moves: the states simply change.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, GetTime, UIParent, InCombatLockdown = CreateFrame, GetTime, UIParent, InCombatLockdown
local floor, max, min, abs, cos, sin, pi = math.floor, math.max, math.min, math.abs, math.cos, math.sin, math.pi

local module = UI:RegisterModule('combatcue', {always = true})

-- defaults:begin
UI:RegisterDefaults('combatcue', {enable = true, status = true, hold = true, ring = true, lamps = true, edge = false,
	brackets = false, rails = false, trace = false, sound = true})
-- defaults:end

local function DB() return UI.db.combatcue end
local function IsSecret(value) return issecretvalue and issecretvalue(value) end
local function Reduced() return Kit:DB().reduceMotion end
local function Px(frame, n) return UI.Pixel.Px(frame, n) end

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

local root
local function Root()
	if root then return root end
	root = CreateFrame('Frame', nil, UIParent)
	root:SetAllPoints()
	root:SetFrameStrata('HIGH')
	root:EnableMouse(false)
	return root
end

local function Color(token, ...)
	local r, g, b = Kit:RGB(token)
	for index = 1, select('#', ...) do select(index, ...):SetVertexColor(r, g, b) end
end

-- Status device ---------------------------------------------------------------------------
local holder, status, ticker

local function Clock(seconds)
	seconds = max(0, floor(seconds))
	if seconds >= 6000 then return format('%03d', floor(seconds / 60)) end
	return format('%02d:%02d', floor(seconds / 60), seconds % 60)
end

local function Tick()
	if status and status:IsShown() and started then status.time:SetText(Clock(GetTime() - started)) end
end

local function StartClock()
	if ticker then ticker:Cancel() end
	ticker = C_Timer.NewTicker(0.25, Tick)
	Tick()
end

local function StopClock()
	if ticker then ticker:Cancel(); ticker = nil end
end

local function Status()
	if status then return status end
	-- The mover holds the spot; the device moves inside it, so drops and rises
	-- never disturb where Unlock mode put it.
	holder = CreateFrame('Frame', 'JiberishSpec01CombatStatus', UIParent)
	holder:SetSize(176, 62)
	holder:SetFrameStrata('HIGH')
	status = Kit:Device(holder, {surface = 'paper', model = 'CB-1', title = 'Combat', width = 176, height = 62, radius = 8})
	status:SetPoint('CENTER', holder, 'CENTER', 0, 0)
	status:EnableMouse(false)
	status.lcd = Kit:LCDPanel(status, {radius = 4})
	status.lcd:SetPoint('TOPLEFT', status, 'TOPLEFT', 8, -22)
	status.lcd:SetPoint('BOTTOMRIGHT', status, 'BOTTOMRIGHT', -8, 8)
	-- The fight's length over unlit segments, in the numbers typeface.
	status.ghost = Kit:Text(status.lcd, '88:88', 20, 'lcdGhost', true)
	Kit:Font(status.ghost, 20, nil, true, 'numbers')
	status.ghost:SetPoint('RIGHT', status.lcd, 'RIGHT', -9, 0)
	status.ghost:SetJustifyH('RIGHT')
	Kit:Ghost(status.ghost)
	status.time = Kit:Text(status.lcd, '00:00', 20, 'lcdInk', true)
	Kit:Font(status.time, 20, nil, true, 'numbers')
	status.time:SetPoint('RIGHT', status.lcd, 'RIGHT', -9, 0)
	status.time:SetJustifyH('RIGHT')
	status.state = Kit:Label(status.lcd, '', 'lcdDim', 8, true)
	status.state:SetPoint('LEFT', status.lcd, 'LEFT', 9, 0)
	status:Hide()
	-- Unlock mode shows it in place so it can be moved.
	function holder:SetPreview(on)
		if on then
			status:ClearAllPoints()
			status:SetPoint('CENTER', holder, 'CENTER', 0, 0)
			status:SetAlpha(1)
			status:Show()
		elseif not (fighting or preview) then
			status:Hide()
		end
	end
	UI:RegisterMover(holder, 'cue.status', 'Combat status', {'TOP', 0, -96})
	return status
end

local function Drop(device, from, to, fromAlpha, toAlpha, duration, ease, done)
	if Reduced() then
		device:ClearAllPoints()
		device:SetPoint('CENTER', holder, 'CENTER', 0, 0)
		device:SetAlpha(toAlpha)
		if done then done() end
		return
	end
	Kit:Animate(device, duration, 0, 1, function(value, progress)
		device:ClearAllPoints()
		device:SetPoint('CENTER', holder, 'CENTER', 0, from + (to - from) * value)
		device:SetAlpha(fromAlpha + (toAlpha - fromAlpha) * min(1, progress * 1.6))
	end, done, ease)
end

local function Rise(token)
	if not status or not status:IsShown() then return end
	Drop(status, 0, 18, 1, 0, 0.45, 'cubic', function()
		if status.token == token then status:Hide(); StopClock() end
	end)
end

local function ShowStatus(entering)
	if not DB().status then return end
	local device = Status()
	local token = {}
	device.token = token
	if entering then
		Kit:SetLed(device.lamp, true, 'red')
		device.title:SetText('COMBAT')
		device.state:SetText('LIVE')
		Kit:Tint(device.state, 'red')
		device:Show()
		Drop(device, 26, 0, 0, 1, 0.42, 'detent')
		if not Reduced() then
			Kit:Blink(device.lamp, 0.16, true)
			C_Timer.After(0.65, function() if device.token == token then Kit:Blink(device.lamp, nil, false) end end)
		end
		StartClock()
		-- Flash only: up for a moment, then away until the fight ends.
		if not DB().hold then C_Timer.After(2.4, function() if device.token == token then Rise(token) end end) end
	else
		Kit:Blink(device.lamp, nil, false)
		StopClock()
		Kit:SetLed(device.lamp, true, 'green')
		device.title:SetText('CLEAR')
		device.state:SetText('DONE')
		Kit:Tint(device.state, 'lcdDim')
		device.time:SetText(Clock(started and GetTime() - started or 0))
		if not device:IsShown() then
			device:Show()
			Drop(device, 26, 0, 0, 1, 0.42, 'detent')
		end
		Kit:Flash(device, {token = 'green', alpha = 0.35, duration = 0.45})
		C_Timer.After(2.2, function() if device.token == token then Rise(token) end end)
	end
end

-- Arming ring -------------------------------------------------------------------------------
local ring
local RING_TICKS, RING_RADIUS = 60, 74

local function Ring()
	if ring then return ring end
	ring = CreateFrame('Frame', nil, Root())
	ring:SetSize(2 * RING_RADIUS + 24, 2 * RING_RADIUS + 24)
	ring:SetPoint('CENTER', UIParent, 'CENTER', 0, -70)
	ring.ticks = {}
	for index = 1, RING_TICKS do
		local tick = ring:CreateTexture(nil, 'OVERLAY')
		tick:SetColorTexture(1, 1, 1, 1)
		tick.major = (index - 1) % 15 == 0
		ring.ticks[index] = tick
	end
	ring.core = Kit:Texture(ring, 'glow', 'ARTWORK')
	ring.core:SetPoint('CENTER')
	ring.core:SetSize(2 * RING_RADIUS + 40, 2 * RING_RADIUS + 40)
	ring.core:SetBlendMode('ADD')
	ring:SetAlpha(0)
	ring:Hide()
	return ring
end

-- Ticks laid out for a direction: clockwise from the top, or counter-clockwise.
local function LayoutRing(clockwise)
	local width = Px(ring, 2)
	for index, tick in ipairs(ring.ticks) do
		local step = 2 * pi * (index - 1) / RING_TICKS
		local angle = pi / 2 + (clockwise and -step or step)
		local length = tick.major and 12 or 6
		local radius = RING_RADIUS + (tick.major and 3 or 0)
		tick:ClearAllPoints()
		tick:SetSize(width, length)
		tick:SetPoint('CENTER', ring, 'CENTER', radius * cos(angle), radius * sin(angle))
		tick:SetRotation(angle - pi / 2)
	end
end

local function ArmRing(entering)
	if not DB().ring or Reduced() then return end
	local r = Ring()
	local token = entering and 'red' or 'green'
	LayoutRing(entering)
	Color(token, r.core, unpack(r.ticks))
	r.core:SetAlpha(0)
	r:Show()
	r:SetAlpha(1)
	local count = #r.ticks
	Kit:Animate(r, entering and 0.35 or 0.6, 0, 1, function(value)
		local lit = value * count
		for index, tick in ipairs(r.ticks) do
			local on = index <= lit
			tick:SetAlpha(on and (tick.major and 1 or 0.85) or 0.12)
		end
	end, function()
		-- One brighter flash, then out.
		for _, tick in ipairs(r.ticks) do tick:SetAlpha(1) end
		Kit:Animate(r.core, entering and 0.55 or 0.8, 0, 1, function(_, progress)
			r.core:SetAlpha(0.28 * (1 - progress))
			r:SetAlpha(1 - progress * progress)
		end, function() r:Hide() end, 'linear')
	end, 'cubic')
end

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

local function LightLamps()
	if not DB().lamps then return end
	Hook()
	local cx, cy = UIParent:GetCenter()
	local list = {}
	for device in pairs(Kit.devices or {}) do
		local lamp = device.lamp
		if device ~= status and lamp and not lit[lamp] and not lamp.on and lamp:IsVisible() and device:IsVisible() then
			local x, y = device:GetCenter()
			if x and y and not IsSecret(x) and not IsSecret(y) then
				local ratio = device:GetEffectiveScale() / UIParent:GetEffectiveScale()
				list[#list + 1] = {lamp = lamp, distance = abs(x * ratio - cx) + abs(y * ratio - cy)}
			end
		end
	end
	table.sort(list, function(a, b) return a.distance < b.distance end)
	local farthest = list[#list] and list[#list].distance or 1
	for _, item in ipairs(list) do
		local lamp = item.lamp
		lit[lamp] = true
		local function Light()
			if not lit[lamp] then return end
			setting = true
			Kit:SetLed(lamp, true, 'red')
			setting = false
		end
		if Reduced() then Light() else C_Timer.After(0.3 * item.distance / max(farthest, 1), Light) end
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
local function Edges()
	if edges then return edges end
	edges = {}
	for index, side in ipairs({'TOP', 'BOTTOM', 'LEFT', 'RIGHT'}) do
		local glow = Kit:Texture(Root(), 'glow', 'ARTWORK')
		glow:SetBlendMode('ADD')
		glow.side = side
		glow:SetAlpha(0)
		edges[index] = glow
	end
	return edges
end

local function EdgeGlow(entering)
	if not (entering and DB().edge) or Reduced() then return end
	local width, height = UIParent:GetSize()
	for _, glow in ipairs(Edges()) do
		glow:ClearAllPoints()
		if glow.side == 'TOP' or glow.side == 'BOTTOM' then
			glow:SetSize(width * 1.2, 90)
			glow:SetPoint('CENTER', root, glow.side, 0, 0)
		else
			glow:SetSize(90, height * 1.2)
			glow:SetPoint('CENTER', root, glow.side, 0, 0)
		end
	end
	Color('red', unpack(edges))
	Kit:Animate(edges, 0.7, 0, 1, function(_, progress)
		local alpha = 0.55 * sin(pi * progress)
		for _, glow in ipairs(edges) do glow:SetAlpha(alpha) end
	end, function() for _, glow in ipairs(edges) do glow:SetAlpha(0) end end, 'linear')
end

-- Brackets, rails and frame trace (from 0.5.1; off by default) --------------------------------
local brackets, rails
local ARM, INSET = 28, 10
local CORNERS = {{'TOPLEFT', 1, -1}, {'TOPRIGHT', -1, -1}, {'BOTTOMLEFT', 1, 1}, {'BOTTOMRIGHT', -1, 1}}

local function BuildFrames()
	if brackets then return end
	brackets, rails = {}, {}
	for index, corner in ipairs(CORNERS) do
		local bracket = CreateFrame('Frame', nil, Root())
		bracket:SetSize(ARM, ARM)
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
	local width, height = UIParent:GetSize()
	local thickness = Px(root, 2)
	for _, bracket in ipairs(brackets) do
		local point, sx, sy = bracket.corner[1], bracket.corner[2], bracket.corner[3]
		bracket.across:ClearAllPoints(); bracket.across:SetPoint(point); bracket.across:SetSize(ARM, thickness)
		bracket.down:ClearAllPoints(); bracket.down:SetPoint(point); bracket.down:SetSize(thickness, ARM)
		bracket:ClearAllPoints()
		bracket:SetPoint(point, root, point, sx * (INSET + width * 0.16 * (1 - t)), sy * (INSET + height * 0.16 * (1 - t)))
	end
end

local function Brackets(entering)
	if not DB().brackets or Reduced() then return end
	BuildFrames()
	for _, bracket in ipairs(brackets) do Color(entering and 'red' or 'green', bracket.across, bracket.down) end
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

local function Rails(entering)
	if not DB().rails or Reduced() then return end
	BuildFrames()
	local width = UIParent:GetWidth()
	for _, rail in ipairs(rails) do
		Color(entering and 'red' or 'green', rail)
		rail:ClearAllPoints()
		rail:SetPoint(rail.side, root, rail.side, 0, 0)
		rail:SetHeight(Px(root, 1))
	end
	Kit:Animate(rails, entering and 0.5 or 0.8, 0, 1, function(value, progress)
		local alpha = progress < 0.6 and 0.9 or 0.9 * (1 - (progress - 0.6) / 0.4)
		for _, rail in ipairs(rails) do rail:SetWidth(max(width * min(1, value * 1.15), 1)); rail:SetAlpha(alpha) end
	end, function() for _, rail in ipairs(rails) do rail:SetAlpha(0) end end, 'cubic')
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

local function RunTrace(frame, token, duration)
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
	Color(token, trace.head, trace.dot)
	trace:Show()
	Kit:Animate(trace, duration, 0, 1, function(value, progress)
		local x, y = AlongEdge(width, height, value)
		trace.head:ClearAllPoints(); trace.head:SetPoint('CENTER', trace, 'TOPLEFT', x, y)
		trace.dot:ClearAllPoints(); trace.dot:SetPoint('CENTER', trace, 'TOPLEFT', x, y)
		trace:SetAlpha(progress > 0.85 and (1 - progress) / 0.15 or 1)
	end, function() trace:Hide() end, 'inout')
end

local function TraceAll(entering)
	if not DB().trace or Reduced() then return end
	local token = entering and 'red' or 'green'
	local cx, cy = UIParent:GetCenter()
	for _, entry in ipairs(UI.GetMovers and UI:GetMovers() or {}) do
		local frame = entry.frame
		if frame and frame ~= holder and not entry.docked and frame:IsVisible() and frame:GetAlpha() > 0.05 then
			local x, y = frame:GetCenter()
			if x and y and not IsSecret(x) and not IsSecret(y) then
				local delay = min(0.3, (abs(x - cx) + abs(y - cy)) / 4000)
				C_Timer.After(delay, function() UI:Safe(RunTrace, frame, token, entering and 0.65 or 0.9) end)
			end
		end
	end
end

-- Driver --------------------------------------------------------------------------------------
local function Cue(entering)
	if entering then
		UI:Safe(LightLamps)
	else
		UI:Safe(RestoreLamps)
	end
	UI:Safe(ShowStatus, entering)
	UI:Safe(ArmRing, entering)
	UI:Safe(EdgeGlow, entering)
	UI:Safe(Brackets, entering)
	UI:Safe(Rails, entering)
	UI:Safe(TraceAll, entering)
	if DB().sound then
		if entering then
			Kit:Play('latch-down', true)
			C_Timer.After(0.09, function() Kit:Play('blip', true) end)
		else
			Kit:Play('success', true)
		end
	end
end

function module:Enable()
	local db = DB()
	Upgrade(db)
	if not db.enable then return end
	Status()
	local events = CreateFrame('Frame')
	events:RegisterEvent('PLAYER_REGEN_DISABLED')
	events:RegisterEvent('PLAYER_REGEN_ENABLED')
	events:SetScript('OnEvent', function(_, event)
		local entering = event == 'PLAYER_REGEN_DISABLED'
		-- A real fight ends any preview.
		preview = nil
		fighting = entering
		if entering then started = GetTime() end
		Cue(entering)
	end)
	self.ready = true
end

-- Previews: going in runs for a few seconds, then plays coming out by itself,
-- so nothing is left lit. Neither does anything during a real fight.
function module:Preview(entering)
	if fighting or InCombatLockdown() then return end
	Upgrade(DB())
	local token = {}
	preview = token
	if entering then
		started = GetTime() - 42
		Cue(true)
		C_Timer.After(3.5, function()
			if preview == token and not fighting then Cue(false); preview = nil end
		end)
	else
		if not started then started = GetTime() - 42 end
		Cue(false)
		preview = nil
	end
end

-- Hub -------------------------------------------------------------------------------------------
local function Off() return not DB().enable end
local function NoStatus() return Off() or not DB().status end
UI:RegisterPage('combatcue', {title = 'Combat cues', order = 4.2, cards = {
	{title = 'Combat cues', rows = {
		{'switch', 'Combat cues', 'combatcue.enable', 'The interface switches into a live state as a fight starts, and back as it ends.', reload = true, since = '0.5.1'},
		{'switch', 'Status device', 'combatcue.status', 'A CB-1 device at the top: a red lamp, COMBAT and the fight\'s time; then CLEAR and how long it lasted. Place it in Unlock mode.', disabled = Off, since = '0.5.1'},
		{'switch', 'Keep it up', 'combatcue.hold', 'The status device stays up for the whole fight. Off: it flashes in, then waits for the fight to end.', disabled = NoStatus, since = '0.5.1'},
		{'switch', 'Arming ring', 'combatcue.ring', 'Hairline ticks around your character light in sequence: red going in, green coming out.', disabled = Off, since = '0.5.1'},
		{'switch', 'Device lamps', 'combatcue.lamps', 'Every dark SPEC-01 lamp glows red for the fight, cascading out from the middle.', disabled = Off, since = '0.5.1'},
		{'switch', 'Sound', 'combatcue.sound', 'A latch and a blip going in, a chime coming out.', disabled = Off, since = '0.5.1'},
		{'button', 'Preview going in', 'Play', function() module:Preview(true) end},
		{'button', 'Preview coming out', 'Play', function() module:Preview(false) end},
	}},
	{title = 'Extras', rows = {
		{'switch', 'Edge glow', 'combatcue.edge', 'A brief red glow along the edges of the screen as a fight starts.', disabled = Off, since = '0.5.1'},
		{'switch', 'Corner brackets', 'combatcue.brackets', 'Brackets drop in and lock onto the screen\'s corners.', disabled = Off, since = '0.5.1'},
		{'switch', 'Rails', 'combatcue.rails', 'Hairlines draw out along the top and bottom edges.', disabled = Off, since = '0.5.1'},
		{'switch', 'Frame trace', 'combatcue.trace', 'A lit head runs once around every SPEC-01 frame. While it is on, the unit frames\' own combat sweep stands down.', disabled = Off, since = '0.5.1'},
	}},
}})
