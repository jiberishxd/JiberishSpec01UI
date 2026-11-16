-- The Motion page: SPEC-01's own animations (on by default, each family can be
-- turned off) and optional extras that make the interface feel more alive.
-- The animations themselves live in Kit/Motion.lua; this module holds the
-- settings, re-applies the extras when they change, and runs the few that need
-- events (combat pulse, spectrum). Reduce motion (Theme page) turns all of it off.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame = CreateFrame

-- defaults:begin
UI:RegisterDefaults('motion', {
	-- Faithful SPEC-01 motion, by family.
	faithful = true, print = true, chosen = true, breathe = true, slide = true, caret = true, setting = true,
	transitions = true,
	-- Extras: how strongly they move (0.5 subtle, 1 normal, 1.5 lively), and each one's switch.
	intensity = 1,
	alive = {hoverLift = true, pressFlash = true, livingLamps = false, lcdPrint = true, numberRoll = true, stagger = true,
		powerOn = false, shimmer = false, meterCascade = true, spring = false, combatPulse = false, cooldownReady = true,
		spectrum = false},
})
-- defaults:end

local module = UI:RegisterModule('motion', {always = true})

-- Device headers shimmer (the Shimmer extra) on a strip of their own.
local strips = setmetatable({}, {__mode = 'k'})
local function HeaderStrip(device)
	local strip = strips[device]
	if strip then return strip end
	strip = CreateFrame('Frame', nil, device)
	strip:SetPoint('TOPLEFT', 6, -3)
	strip:SetPoint('TOPRIGHT', -6, -3)
	strip:SetHeight(20)
	strip:EnableMouse(false)
	strips[device] = strip
	return strip
end

local function ApplyShimmer()
	local on = Kit:Alive('shimmer')
	for key in pairs(Kit.keys or {}) do Kit:KeyShimmer(key) end
	for device in pairs(Kit.devices or {}) do
		if device.lamp and (on or strips[device]) then
			Kit:Shimmer(HeaderStrip(device), on, {gap = 6.4, alpha = 0.12, width = 0.3})
		end
	end
end

local function ApplyLamps()
	local on = Kit:Alive('livingLamps')
	local low = 1 - 0.4 * math.min(1.5, Kit:Intensity())
	for led in pairs(Kit.leds or {}) do
		local looping = Kit:Looping(Kit.MotionTag('breathe', led))
		if on and led.on then
			-- Restart so a new intensity takes.
			Kit:Breathe(led, true, {period = 2.4, low = low})
		elseif looping then
			Kit:Breathe(led, false)
		end
	end
end

-- Spectrum: in the hub's header while SPEC-01 sounds play, and on the away screen.
local hubSpectrum, afkSpectrum, quietTimer
local function HubSpectrum()
	if hubSpectrum then return hubSpectrum end
	local hub = UI.HubFrame and UI:HubFrame()
	if not hub or not hub.heading then return end
	hubSpectrum = Kit:Spectrum(hub, {count = 10, height = 12, token = 'dim'})
	hubSpectrum:SetPoint('BOTTOMLEFT', hub.heading, 'BOTTOMRIGHT', 10, 1)
	return hubSpectrum
end

local function Played()
	if not Kit:Alive('spectrum') then return end
	local spectrum = HubSpectrum()
	if not spectrum or not spectrum:IsVisible() then return end
	spectrum:Show()
	spectrum:SetPlaying(true)
	if quietTimer then quietTimer:Cancel() end
	quietTimer = C_Timer.NewTimer(0.6, function()
		quietTimer = nil
		spectrum:SetPlaying(false)
	end)
end

local function ApplySpectrum()
	local on = Kit:Alive('spectrum')
	Kit.OnPlayed = on and Played or nil
	if hubSpectrum then
		hubSpectrum:SetShown(on)
		if not on then hubSpectrum:SetPlaying(false) end
	end
	local away = _G.JiberishSpec01AwayScreen
	if on and away and not afkSpectrum then
		afkSpectrum = Kit:Spectrum(away, {count = 24, width = 3, gap = 3, height = 36})
		afkSpectrum:SetPoint('BOTTOM', away, 'BOTTOM', 0, 72)
	end
	if afkSpectrum then
		afkSpectrum:SetShown(on)
		-- It loops only while the away screen shows.
		afkSpectrum:SetPlaying(on)
	end
end

function module:Refresh()
	UI:Safe(ApplyShimmer)
	UI:Safe(ApplyLamps)
	UI:Safe(ApplySpectrum)
end

function module:Enable()
	local driver = CreateFrame('Frame')
	driver:RegisterEvent('PLAYER_REGEN_DISABLED')
	driver:RegisterEvent('PLAYER_ENTERING_WORLD')
	driver:RegisterEvent('PLAYER_FLAGS_CHANGED')
	driver:SetScript('OnEvent', function(_, event, unit)
		if event == 'PLAYER_REGEN_DISABLED' then
			UI:Safe(Kit.PulseDevices, Kit, 'lamp')
		elseif event == 'PLAYER_FLAGS_CHANGED' then
			if unit == 'player' then C_Timer.After(0.3, function() UI:Safe(ApplySpectrum) end) end
		else
			-- Devices built since login pick up the extras.
			C_Timer.After(1, function() module:Refresh() end)
		end
	end)
	self:Refresh()
end

-- Preview -------------------------------------------------------------------------------
-- A MO-1 device under the hub while this page is open, with one part per effect
-- and a Replay key that sets them all going.
local preview
local function Preview(hub)
	if preview then return preview end
	preview = Kit:Device(hub, {model = 'MO-1', title = 'Preview', width = 760, height = 100, radius = 12})
	preview:EnableMouse(true)
	local key = Kit:Key(preview, {tone = 'primary', text = 'Key', width = 70, height = 30})
	key:SetPoint('BOTTOMLEFT', 14, 16)
	local badge = Kit:Badge(preview, {text = 'Live', tone = 'blue'})
	badge:SetPoint('LEFT', key, 'RIGHT', 12, 0)
	local switch = Kit:Switch(preview, {labels = false, checked = true})
	switch:SetPoint('LEFT', badge, 'RIGHT', 14, 0)
	local meter = Kit:Meter(preview, {label = 'Meter', width = 120, value = 0.4})
	meter:SetPoint('LEFT', switch, 'RIGHT', 14, -4)
	local lcd = Kit:LCD(preview, {tag = 'LCD', ghost = '8888', text = 'IDLE', width = 76})
	lcd:SetPoint('LEFT', meter, 'RIGHT', 14, 4)
	local gold = Kit:LCD(preview, {tag = 'Gold', ghost = '88888', width = 84})
	gold:SetPoint('LEFT', lcd, 'RIGHT', 10, 0)
	local amount = 1250
	Kit:Roll(gold.digits, amount)
	local screen = Kit:Screen(preview, {inset = 3, radius = 6})
	screen:SetSize(64, 34)
	screen:SetPoint('LEFT', gold, 'RIGHT', 10, 0)
	local spectrum = Kit:Spectrum(screen.screen, {count = 10, height = 18})
	spectrum:SetPoint('CENTER')
	local words = {'READY', 'SYNC', 'ARMED', 'LIVE', 'OK'}
	local word = 1
	local replay = Kit:Key(preview, {text = 'Replay', width = 72, height = 30, onClick = function()
		word = word % #words + 1
		lcd:SetText(words[word])
		if not Kit:Alive('lcdPrint') then Kit:Print(lcd.digits, {force = true, duration = 0.28, steps = 16}) end
		amount = amount + math.random(40, 900)
		Kit:Roll(gold.digits, amount)
		meter:SetValue(math.random(15, 100) / 100, true)
		switch:SetValue(not switch:GetValue(), true)
		Kit:PowerOn(screen.screen)
		Kit:MotionNotify('press', key.face)
		spectrum:SetPlaying(Kit:Alive('spectrum'))
		if Kit:Alive('spectrum') then C_Timer.After(1.2, function() spectrum:SetPlaying(false) end) end
	end})
	replay:SetPoint('LEFT', screen, 'RIGHT', 12, 0)
	Kit:SetLed(preview.lamp, true)
	preview:Hide()
	return preview
end

local function Intensity(value)
	if value <= 0.6 then return 'Subtle' elseif value >= 1.4 then return 'Lively' end
	return 'Normal'
end
local function Off() return Kit:DB().reduceMotion end

local function Extra(label, key, note)
	return {'switch', label, 'motion.alive.'..key, note, since = '0.5.0', disabled = Off}
end

UI:RegisterPage('motion', {title = 'Motion', order = 4,
	onShow = function(area)
		local hub = area:GetParent()
		local strip = Preview(hub)
		strip:ClearAllPoints()
		strip:SetPoint('TOP', hub, 'BOTTOM', 0, -6)
		strip:SetWidth(math.max(hub:GetWidth() * 0.8, 760))
		Kit:ResetRest(strip)
		Kit:Open(strip)
		module:Refresh()
	end,
	onHide = function()
		if preview and preview:IsShown() then Kit:Close(preview) end
	end,
	cards = {
	{title = 'Faithful SPEC-01 motion', rows = {
		{'note', 'The reference\'s own animations, at its timings. Reduce motion on the Theme page turns all of these and the extras off.'},
		{'switch', 'SPEC-01 motion', 'motion.faithful', 'Master switch for the animations below.', since = '0.5.0', disabled = Off},
		{'switch', 'LCD print', 'motion.print', 'Toasts, dialogs, menus and hover cards print their text in, left to right in hard steps.',
			since = '0.5.0', disabled = Off},
		{'switch', 'Chosen flash', 'motion.chosen', 'A picked menu option flashes twice before the menu closes.', since = '0.5.0', disabled = Off},
		{'switch', 'Breathing badges', 'motion.breathe', 'Info badges breathe, as on the reference.', since = '0.5.0', disabled = Off},
		{'switch', 'Panel slide', 'motion.slide', 'Hub pages fade in with a 6 px rise.', since = '0.5.0', disabled = Off},
		{'switch', 'Block caret', 'motion.caret', 'Text fields show the reference\'s blinking block caret.', since = '0.5.0', disabled = Off},
		{'switch', 'Setting blink', 'motion.setting', 'A date being set blinks while its calendar is open.', since = '0.5.0', disabled = Off},
		{'switch', 'Key and control travel', 'motion.transitions', 'Keys travel down and back, and indicators and levers move, at the reference\'s speeds.',
			since = '0.5.0', disabled = Off},
	}},
	{title = 'Alive', rows = {
		{'note', 'Extras in the same mechanical spirit. The Replay key on the preview under this window shows them.'},
		{'slider', 'Intensity', 'motion.intensity', 0.5, 1.5, 0.5, 'How far things lift, glow and overshoot.', format = Intensity,
			since = '0.5.0', disabled = Off},
		{'header', 'Touch'},
		Extra('Hover lift', 'hoverLift', 'Keys rise a pixel and glow softly under the pointer.'),
		Extra('Press flash', 'pressFlash', 'A lamp-colored flash on every key press.'),
		Extra('Spring settle', 'spring', 'Switches and levers overshoot a touch and settle.'),
		{'header', 'Readouts'},
		Extra('LCD print-in', 'lcdPrint', 'Readouts that change print in: LCDs, the info panel, banners and the loot window.'),
		Extra('Number roll', 'numberRoll', 'Counted values like gold roll to their new amount.'),
		Extra('Meter cascade', 'meterCascade', 'Dot meters light one dot after another as they fill.'),
		{'header', 'Ambient'},
		Extra('Living lamps', 'livingLamps', 'Lit status lamps breathe slowly.'),
		Extra('Shimmer', 'shimmer', 'A sweep of light crosses primary keys and device headers every few seconds.'),
		Extra('Spectrum', 'spectrum', 'An equalizer in the hub header while sounds play, and on the away screen.'),
		{'header', 'Moments'},
		Extra('Staggered entrance', 'stagger', 'Hub cards and bag keys come in one after another.'),
		Extra('Screen power-on', 'powerOn', 'Black displays and window housings flicker on with a scanline.'),
		Extra('Combat pulse', 'combatPulse', 'Device edges pulse once as combat starts.'),
		Extra('Cooldown ready', 'cooldownReady', 'Action keys flash when a cooldown longer than the global one ends.'),
	}},
}})
