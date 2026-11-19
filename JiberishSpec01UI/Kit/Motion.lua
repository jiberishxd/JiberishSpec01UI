-- SPEC-01 motion: the reference's named animations, with its timings and step
-- counts, plus the optional "alive" extras the Motion page switches on.
--
-- From the reference's stylesheets (SPEC-01 by Shu Ding, MIT; see
-- Media/Hardware/LICENSE-SPEC-01.txt):
--   lcd-print      text revealed left to right in hard steps (toasts 280 ms / 16,
--                  dialog title 260 ms / 16 after 120 ms, description 320 ms / 20
--                  after 260 ms, menu options 200 ms / 12, hover LCDs 260 ms / 14)
--   blink          0.6 s, on for half, off for half (a timer that is done)
--   badge-breathe  1.6 s ease-in-out to 35% opacity and back (info badges)
--   te-shimmer     1.6 s linear sweep of light (loading blocks)
--   spectrum       bars 15% -> 85% -> 35% high, each 420 ms + 37 ms per bar,
--                  alternating, started 91 ms apart
--   menu-chosen    300 ms: the chosen option flashes twice before the menu goes
--   side-panel-in  240 ms fade and 6 px rise on cubic-bezier(0.2, 0.8, 0.2, 1)
--   block-caret    1.06 s blink (screen and code cursors 1.1 s and 1 s)
--   setting        1.1 s: the field being set shows set 70% of the time
--
-- Cost: one-shots run on Kit:Animate's driver. Loops share one driver that runs
-- at 30 fps only while a looping region is visible; hidden owners pause their
-- loops (OnHide), and nothing runs while nothing loops.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, GetTime = CreateFrame, GetTime
local floor, max, min, cos, pi = math.floor, math.max, math.min, math.cos, math.pi

local IsSecret = UI.Util.IsSecret

-- Settings --------------------------------------------------------------------
-- The Motion page (Modules/Motion.lua) declares these; until it loads, the
-- faithful set is on and the extras are off.
function Kit:Reduced() return self:DB().reduceMotion and true or false end

-- A faithful family: print, chosen, breathe, slide, caret, setting, transitions.
function Kit:Faithful(family)
	if self:Reduced() then return false end
	local db = UI.db and UI.db.motion
	if type(db) ~= 'table' then return true end
	if db.faithful == false then return false end
	return not (family and db[family] == false)
end

-- An optional extra from the Motion page's Alive card.
function Kit:Alive(feature)
	if self:Reduced() then return false end
	local alive = UI.db and type(UI.db.motion) == 'table' and UI.db.motion.alive
	return type(alive) == 'table' and alive[feature] == true
end

-- How large the extras move: 0.5 subtle, 1 normal, 1.5 lively.
function Kit:Intensity()
	local db = UI.db and UI.db.motion
	return type(db) == 'table' and tonumber(db.intensity) or 1
end

-- A small overshoot for the Spring settle extra; detent otherwise.
Kit.ease.spring = function(t)
	local c = 1.2 * Kit:Intensity()
	return 1 + (c + 1) * (t - 1) ^ 3 + c * (t - 1) ^ 2
end
function Kit:ControlEase() return self:Alive('spring') and 'spring' or 'detent' end

-- A component transition at the reference's duration, or `fallback` with the
-- faithful transitions off (the kit's earlier, quicker timing).
function Kit:TransitionTime(seconds, fallback)
	if self:Faithful('transitions') then return seconds end
	return fallback or seconds
end

-- Tags: one key object per (kind, thing), so a region can blink and shimmer at once.
local tags = {}
local function Tag(kind, object)
	local byKind = tags[kind]
	if not byKind then byKind = setmetatable({}, {__mode = 'k'}); tags[kind] = byKind end
	local tag = byKind[object]
	if not tag then tag = {}; byKind[object] = tag end
	return tag
end
Kit.MotionTag = Tag

-- Loops -----------------------------------------------------------------------
local loops, active = {}, {}
local owners = setmetatable({}, {__mode = 'k'})
local loopDriver = CreateFrame('Frame')
loopDriver:Hide()
local STEP = 1 / 30
local wait = 0
loopDriver:SetScript('OnUpdate', function(self, elapsed)
	wait = wait + elapsed
	if wait < STEP then return end
	wait = 0
	local now, any = GetTime(), false
	for key, loop in pairs(active) do
		any = true
		if not pcall(loop.update, now - loop.start, loop) then Kit:StopLoop(key) end
	end
	if not any then self:Hide() end
end)

local function Watch(owner)
	local set = owners[owner]
	if set then return set end
	set = {}
	owners[owner] = set
	owner:HookScript('OnShow', function()
		for key in pairs(set) do
			local loop = loops[key]
			if loop then active[key] = loop; loopDriver:Show() end
		end
	end)
	owner:HookScript('OnHide', function()
		for key in pairs(set) do
			if active[key] then
				active[key] = nil
				local loop = loops[key]
				if loop and loop.rest then pcall(loop.rest, loop) end
			end
		end
	end)
	return set
end

-- update(t, loop) runs at 30 fps while owner is visible; rest(loop) puts the
-- region back when the loop pauses or stops. Reduced motion never loops.
function Kit:Loop(key, owner, update, rest)
	self:StopLoop(key)
	if self:Reduced() or not owner then return end
	local loop = {key = key, owner = owner, update = update, rest = rest, start = GetTime()}
	loops[key] = loop
	Watch(owner)[key] = true
	if owner:IsVisible() then
		active[key] = loop
		loopDriver:Show()
	end
	return loop
end

function Kit:StopLoop(key)
	local loop = loops[key]
	if not loop then return end
	loops[key], active[key] = nil, nil
	local set = owners[loop.owner]
	if set then set[key] = nil end
	if loop.rest then pcall(loop.rest, loop) end
end

function Kit:Looping(key) return loops[key] ~= nil end

local function OwnerOf(region)
	if region.IsObjectType and region:IsObjectType('Frame') then return region end
	return region.GetParent and region:GetParent()
end

-- Plain alpha of a region, to come back to.
local function BaseAlpha(region)
	local alpha = region.GetAlpha and region:GetAlpha()
	if IsSecret(alpha) or type(alpha) ~= 'number' then return 1 end
	return alpha
end

-- The resting alpha for an effect: read while it's at rest, kept while it runs.
local resting = setmetatable({}, {__mode = 'k'})
local function Resting(key, region, running)
	if running and resting[key] then return resting[key] end
	local base = BaseAlpha(region)
	resting[key] = base
	return base
end

-- lcd-print ----------------------------------------------------------------------
local ALL = 1000 -- a gradient starting past the last character shows everything
local function Length(text)
	if strlenutf8 then return strlenutf8(text) end
	return #text
end

-- opts: duration (s), steps, delay (s), force (print even with the faithful set off).
function Kit:Print(fontString, opts)
	if not fontString or not fontString.SetAlphaGradient then return end
	opts = opts or {}
	local key = Tag('print', fontString)
	if self:Reduced() or not (opts.force or self:Faithful('print')) then
		self:Animate(key, 0, 0, 1, function() end)
		fontString:SetAlphaGradient(ALL, 1)
		return
	end
	local duration, steps, delay = opts.duration or 0.28, opts.steps or 16, opts.delay or 0
	local text = fontString:GetText()
	local base = Resting(key, fontString, self:Animating(key))
	if IsSecret(text) or type(text) ~= 'string' then
		-- Secret or missing text has no length to step through: a stepped fade instead.
		fontString:SetAlphaGradient(ALL, 1)
		self:Animate(key, delay + duration, 0, 1, function(_, progress)
			local t = progress * (delay + duration)
			local shown = t < delay and 0 or floor(min(1, (t - delay) / duration) * steps) / steps
			fontString:SetAlpha(base * shown)
		end, function() fontString:SetAlpha(base) end, 'linear')
		return
	end
	local length = Length(text)
	if length == 0 then return end
	self:Animate(key, delay + duration, 0, 1, function(_, progress)
		local t = progress * (delay + duration)
		if t < delay then
			fontString:SetAlpha(0)
			return
		end
		fontString:SetAlpha(base)
		local f = min(1, (t - delay) / duration)
		local reveal = floor(f * steps) / steps -- steps(n, end)
		fontString:SetAlphaGradient(floor(reveal * length + 0.5), 1)
	end, function()
		fontString:SetAlpha(base)
		fontString:SetAlphaGradient(ALL, 1)
	end, 'linear')
end

-- Set a readout and print it in when it changed (the "LCD print-in" extra).
-- Secret text is set and never compared; it prints only when forced.
-- opts: everything Kit:Print takes, plus minGap (seconds between prints).
local lastText = setmetatable({}, {__mode = 'k'})
local lastPrint = setmetatable({}, {__mode = 'k'})
function Kit:PrintText(fontString, text, opts)
	if not fontString then return end
	fontString:SetText(text)
	if not self:Alive('lcdPrint') or IsSecret(text) or type(text) ~= 'string' then return end
	if lastText[fontString] == text then return end
	lastText[fontString] = text
	opts = opts or {}
	local now = GetTime()
	if opts.minGap and now - (lastPrint[fontString] or 0) < opts.minGap then return end
	lastPrint[fontString] = now
	opts.force = true
	opts.duration, opts.steps = opts.duration or 0.26, opts.steps or 14
	self:Print(fontString, opts)
end

-- Print every font string on a frame (a hover card's LCD, a banner).
function Kit:PrintAll(frame, opts)
	for _, region in ipairs({frame:GetRegions()}) do
		if region.IsObjectType and region:IsObjectType('FontString') and region:IsShown() then self:Print(region, opts) end
	end
end

-- blink, breathe, carets ------------------------------------------------------------
-- On for the first half of each period, off for the second (steps(1)).
function Kit:Blink(region, period, on)
	local key = Tag('blink', region)
	if on == false then return self:StopLoop(key) end
	period = period or 0.6
	self:StopLoop(key)
	local base = BaseAlpha(region)
	self:Loop(key, OwnerOf(region), function(t)
		region:SetAlpha((t % period) < period / 2 and base or 0)
	end, function() region:SetAlpha(base) end)
end

-- To `low` and back over `period`, eased in and out. opts: period, low.
function Kit:Breathe(region, on, opts)
	local key = Tag('breathe', region)
	if on == false then return self:StopLoop(key) end
	opts = opts or {}
	local period, low = opts.period or 1.6, opts.low or 0.35
	self:StopLoop(key)
	local base = BaseAlpha(region)
	self:Loop(key, OwnerOf(region), function(t)
		local wave = 0.5 - 0.5 * cos(2 * pi * (t % period) / period)
		region:SetAlpha(base * (1 - (1 - low) * wave))
	end, function() region:SetAlpha(base) end)
end

-- A drawn block caret on an edit box we own, blinking at the reference's 1.06 s.
-- The client's thin caret stays under it; the block is what reads.
function Kit:Caret(edit, opts)
	if not edit or Tag('caret', edit).block then return end
	opts = opts or {}
	local tag = Tag('caret', edit)
	local block = edit:CreateTexture(nil, 'OVERLAY', nil, 7)
	block:SetColorTexture(1, 1, 1, 1)
	Kit:Tint(block, opts.token or 'accent', 0.85)
	block:Hide()
	tag.block = block
	if edit.SetBlinkSpeed then edit:SetBlinkSpeed(0.53) end
	local period = opts.period or 1.06
	local function Run()
		if not Kit:Faithful('caret') then block:Hide(); return end
		block:Show()
		Kit:Loop(tag, edit, function(t)
			block:SetAlpha((t % period) < period / 2 and 1 or 0)
		end, function() block:SetAlpha(1) end)
	end
	edit:HookScript('OnCursorChanged', function(self, x, y, width, height)
		if IsSecret(x) or IsSecret(y) or IsSecret(height) then return end
		local size = select(2, self:GetFont()) or 12
		-- The cursor's x and y are measured inside the text area, which sits
		-- within the box's text insets; a single line is centred vertically.
		local left, _, top = 0, 0, 0
		if self.GetTextInsets then left, _, top = self:GetTextInsets() end
		left, top = left or 0, top or 0
		local blockHeight = floor(size * 1.1 + 0.5)
		block:ClearAllPoints()
		if self.IsMultiLine and self:IsMultiLine() then
			block:SetPoint('TOPLEFT', self, 'TOPLEFT', left + (x or 0), (y or 0) - top)
		else
			block:SetPoint('LEFT', self, 'LEFT', left + (x or 0), 0)
		end
		block:SetSize(max(1, floor(size * 0.6 + 0.5)), blockHeight)
		if self:HasFocus() then Run() end
	end)
	edit:HookScript('OnEditFocusGained', Run)
	edit:HookScript('OnEditFocusLost', function()
		Kit:StopLoop(tag)
		block:Hide()
	end)
end

-- setting: the field being set shows `paint(true)` 70% of each 1.1 s, `paint(false)` the rest.
function Kit:SettingBlink(region, on, paint)
	local key = Tag('setting', region)
	if on == false or not self:Faithful('setting') then
		self:StopLoop(key)
		if paint then pcall(paint, false) end
		return
	end
	local owner = OwnerOf(region)
	self:Loop(key, owner, function(t)
		local set = (t % 1.1) < 1.1 * 0.7
		if paint then paint(set) else region:SetAlpha(set and 1 or 0.35) end
	end, function()
		if paint then pcall(paint, false) else region:SetAlpha(1) end
	end)
end

-- te-shimmer ------------------------------------------------------------------------
-- A soft band of light across a frame. opts: period (1.6), gap (seconds dark
-- between sweeps), alpha, width (fraction of the frame).
local function Band(frame)
	local holder = CreateFrame('Frame', nil, frame)
	holder:SetAllPoints()
	holder:SetClipsChildren(true)
	holder:EnableMouse(false)
	holder:SetFrameLevel(frame:GetFrameLevel() + 2)
	local band = CreateFrame('Frame', nil, holder)
	band:EnableMouse(false)
	band.left = band:CreateTexture(nil, 'OVERLAY')
	band.left:SetColorTexture(1, 1, 1, 1)
	band.left:SetBlendMode('ADD')
	band.left:SetPoint('TOPLEFT'); band.left:SetPoint('BOTTOMRIGHT', band, 'BOTTOM')
	band.left:SetGradient('HORIZONTAL', CreateColor(1, 1, 1, 0), CreateColor(1, 1, 1, 1))
	band.right = band:CreateTexture(nil, 'OVERLAY')
	band.right:SetColorTexture(1, 1, 1, 1)
	band.right:SetBlendMode('ADD')
	band.right:SetPoint('TOPLEFT', band, 'TOP'); band.right:SetPoint('BOTTOMRIGHT')
	band.right:SetGradient('HORIZONTAL', CreateColor(1, 1, 1, 1), CreateColor(1, 1, 1, 0))
	holder.band = band
	return holder
end

function Kit:Shimmer(frame, on, opts)
	local tag = Tag('shimmer', frame)
	if on == false then
		self:StopLoop(tag)
		if tag.holder then tag.holder:Hide() end
		return
	end
	opts = opts or {}
	local period, gap = opts.period or 1.6, opts.gap or 0
	local alpha = (opts.alpha or 0.22) * min(1.5, self:Intensity())
	tag.holder = tag.holder or Band(frame)
	local holder, band = tag.holder, tag.holder.band
	holder:Show()
	band:SetAlpha(alpha)
	self:Loop(tag, frame, function(t)
		local width = frame:GetWidth()
		if IsSecret(width) or width <= 0 then return end
		local bandWidth = width * (opts.width or 0.45)
		local phase = t % (period + gap)
		if phase > period then band:Hide(); return end
		band:Show()
		band:SetSize(bandWidth, frame:GetHeight())
		band:ClearAllPoints()
		band:SetPoint('LEFT', holder, 'LEFT', -bandWidth + (width + bandWidth) * phase / period, 0)
	end, function() band:Hide() end)
end

-- spectrum ---------------------------------------------------------------------------
-- Equalizer bars as lamp-lit columns. opts: count (12), width (2), gap (2), height (22), token.
function Kit:Spectrum(parent, opts)
	opts = opts or {}
	local count, width, gap, height = opts.count or 12, opts.width or 2, opts.gap or 2, opts.height or 22
	local frame = CreateFrame('Frame', nil, parent)
	frame:SetSize(count * width + (count - 1) * gap, height)
	frame:EnableMouse(false)
	frame.bars = {}
	for index = 1, count do
		local bar = frame:CreateTexture(nil, 'ARTWORK')
		bar:SetColorTexture(1, 1, 1, 1)
		Kit:Tint(bar, opts.token or 'screenInk')
		bar:SetSize(width, height * 0.2)
		bar:SetPoint('BOTTOMLEFT', (index - 1) * (width + gap), 0)
		frame.bars[index] = bar
	end
	local tag = Tag('spectrum', frame)
	local function Rest()
		for _, bar in ipairs(frame.bars) do bar:SetHeight(height * 0.2) end
	end
	function frame:SetPlaying(on)
		if not on or Kit:Reduced() then
			Kit:StopLoop(tag)
			return Rest()
		end
		if Kit:Looping(tag) then return end
		Kit:Loop(tag, frame, function(t)
			for index, bar in ipairs(frame.bars) do
				local i = index - 1
				local cycle = 0.42 + i * 0.037
				local phase = (t + i * 0.091) / cycle
				local turn = floor(phase)
				local f = phase - turn
				if turn % 2 == 1 then f = 1 - f end -- alternate
				local level
				if f < 0.5 then level = 0.15 + 0.7 * Kit.ease.inout(f * 2)
				else level = 0.85 - 0.5 * Kit.ease.inout((f - 0.5) * 2) end
				bar:SetHeight(max(1, height * level))
			end
		end, Rest)
	end
	return frame
end

-- menu-chosen --------------------------------------------------------------------------
-- The option flashes on, off, on, off over 300 ms (steps(1)), then done().
-- highlight: a region shown for the "on" quarters; label: tinted onToken while
-- on and offToken while off (defaults darkInk / ink).
function Kit:Chosen(row, highlight, label, done, onToken, offToken)
	if not self:Faithful('chosen') then
		if done then done() end
		return
	end
	self:Animate(Tag('chosen', row), 0.3, 0, 1, function(_, progress)
		local on = progress < 1 and floor(progress * 4) % 2 == 0
		if highlight then highlight:SetShown(on) end
		if label then Kit:Tint(label, on and (onToken or 'darkInk') or (offToken or 'ink')) end
	end, function()
		if highlight then highlight:Hide() end
		if label then Kit:Tint(label, offToken or 'ink') end
		if done then done() end
	end, 'linear')
end

-- side-panel-in ---------------------------------------------------------------------------
-- Fade in while every anchor travels from `dx, dy` (default 0, -6: a 6 px rise)
-- to its place, over 240 ms on the settle curve. Our own frames only.
local slideRest = setmetatable({}, {__mode = 'k'})
function Kit:SlideIn(frame, dx, dy, duration)
	if not frame or (frame.IsProtected and frame:IsProtected()) then return end
	dx, dy = dx or 0, dy or -6
	local key = Tag('slide', frame)
	-- Mid-slide the anchors carry an offset; only a frame at rest is read again.
	if not self:Animating(key) or not slideRest[frame] then
		local points = {}
		for index = 1, frame:GetNumPoints() do points[index] = {frame:GetPoint(index)} end
		slideRest[frame] = points
	end
	local points = slideRest[frame]
	if #points == 0 then return end
	local function Place(offset)
		frame:ClearAllPoints()
		for _, p in ipairs(points) do frame:SetPoint(p[1], p[2], p[3], (p[4] or 0) + dx * offset, (p[5] or 0) + dy * offset) end
	end
	local base = Resting(key, frame, self:Animating(key))
	self:Animate(key, duration or 0.24, 0, 1, function(progress)
		frame:SetAlpha(base * min(1, progress * 1.4))
		Place(1 - progress)
	end, function()
		frame:SetAlpha(base)
		Place(0)
	end, 'settle')
end

-- Extras ---------------------------------------------------------------------------------------
-- A quick lamp-colored flash over a frame (press flash, cooldown ready).
local flashes = setmetatable({}, {__mode = 'k'})
function Kit:Flash(frame, opts)
	if not frame or self:Reduced() then return end
	opts = opts or {}
	local flash = flashes[frame]
	if not flash then
		flash = frame:CreateTexture(nil, 'OVERLAY', nil, 6)
		flash:SetTexture(self.media..'glow.tga')
		flash:SetBlendMode('ADD')
		flash:SetPoint('TOPLEFT', -6, 6)
		flash:SetPoint('BOTTOMRIGHT', 6, -6)
		flashes[frame] = flash
	end
	self:Tint(flash, opts.token or 'lamp')
	local peak = (opts.alpha or 0.55) * min(1.5, self:Intensity())
	flash:Show()
	self:Animate(Tag('flash', frame), opts.duration or 0.32, peak, 0, function(alpha) flash:SetAlpha(alpha) end,
		function() flash:Hide() end, 'sine')
end

-- Count a readout to a new number. format(value) -> text. Secret values are set at once.
local rolled = setmetatable({}, {__mode = 'k'})
local function Whole(value) return tostring(floor(value + 0.5)) end
function Kit:Roll(fontString, value, format, duration)
	format = format or Whole
	if IsSecret(value) then
		rolled[fontString] = nil
		self:Animate(Tag('roll', fontString), 0, 0, 1, function() end)
		return fontString:SetText(value)
	end
	if type(value) ~= 'number' or not self:Alive('numberRoll') then
		rolled[fontString] = value
		self:Animate(Tag('roll', fontString), 0, 0, 1, function() end)
		return fontString:SetText(type(value) == 'number' and format(value) or value)
	end
	local from = rolled[fontString]
	rolled[fontString] = value
	if not from or from == value then return fontString:SetText(format(value)) end
	self:Animate(Tag('roll', fontString), duration or 0.45, from, value, function(current)
		fontString:SetText(format(current))
	end, function() fontString:SetText(format(value)) end, 'cubic')
end

-- Children (or a list of frames) fade in one after another, rising a little.
-- offset false: alpha only (secure buttons, which must not move in combat).
function Kit:Cascade(frames, opts)
	if not self:Alive('stagger') or type(frames) ~= 'table' then return end
	opts = opts or {}
	local step, rise = opts.step or 0.03, (opts.rise or 4) * self:Intensity()
	local index = 0
	for _, frame in ipairs(frames) do
		if frame and frame.IsShown and frame:IsShown() then
			index = index + 1
			local delay = (index - 1) * step
			local key = Tag('cascade', frame)
			local running = self:Animating(key)
			local base = Resting(key, frame, running)
			local points
			if opts.offset ~= false and not (frame.IsProtected and frame:IsProtected()) then
				-- Mid-cascade the anchors carry an offset: keep the ones read at rest.
				points = running and key.points or nil
				if not points then
					points = {}
					for p = 1, frame:GetNumPoints() do points[p] = {frame:GetPoint(p)} end
					key.points = points
				end
			end
			local function Place(offset)
				if not points or #points == 0 then return end
				frame:ClearAllPoints()
				for _, p in ipairs(points) do frame:SetPoint(p[1], p[2], p[3], p[4] or 0, (p[5] or 0) - rise * offset) end
			end
			frame:SetAlpha(0)
			self:Animate(key, delay + 0.2, 0, 1, function(_, progress)
				local t = progress * (delay + 0.2)
				local local01 = t < delay and 0 or (t - delay) / 0.2
				frame:SetAlpha(base * Kit.ease.sine(local01))
				Place(1 - Kit.ease.cubic(local01))
			end, function()
				frame:SetAlpha(base)
				Place(0)
			end, 'linear')
			if index >= (opts.limit or 60) then break end
		end
	end
end

-- Screen power-on: a black display flickers on with a scanline running down it.
local scans = setmetatable({}, {__mode = 'k'})
function Kit:PowerOn(screen)
	if not screen or not self:Alive('powerOn') then return end
	local line = scans[screen]
	if not line then
		line = screen:CreateTexture(nil, 'OVERLAY', nil, 7)
		line:SetColorTexture(1, 1, 1, 1)
		line:SetBlendMode('ADD')
		line:SetHeight(2)
		scans[screen] = line
	end
	local height = screen:GetHeight()
	if IsSecret(height) or not height or height <= 0 then return end
	local base = Resting(Tag('power', screen), screen, self:Animating(Tag('power', screen)))
	local FLICKER = {0, 0.7, 0.15, 0.85, 0.4, 1}
	line:Show()
	self:Animate(Tag('power', screen), 0.28, 0, 1, function(_, progress)
		screen:SetAlpha(base * FLICKER[min(#FLICKER, floor(progress * #FLICKER) + 1)])
		line:ClearAllPoints()
		line:SetPoint('TOPLEFT', screen, 'TOPLEFT', 0, -height * progress)
		line:SetPoint('TOPRIGHT', screen, 'TOPRIGHT', 0, -height * progress)
		line:SetAlpha(0.35 * (1 - progress) * min(1.5, Kit:Intensity()))
	end, function()
		screen:SetAlpha(base)
		line:Hide()
	end, 'linear')
end

-- Devices register here so the combat pulse can reach every housing on screen.
Kit.devices = setmetatable({}, {__mode = 'k'})
function Kit:PulseDevices(token)
	if not self:Alive('combatPulse') then return end
	local r, g, b = self:RGB(token or 'lamp')
	local strength = min(1, 0.7 * self:Intensity())
	for device in pairs(self.devices) do
		local shell = device.shell
		if shell and shell.edge and device:IsVisible() then
			self:Animate(Tag('pulse', shell), 0.6, 0, 1, function(_, progress)
				local amount = math.sin(pi * progress) * strength
				shell.edge:SetVertexColor(r * amount, g * amount, b * amount, 1)
			end, function() Kit:PaintShell(shell) end, 'linear')
		end
	end
end

-- A hook for modules this file must not edit directly (unit frames, action
-- bars): Kit:MotionNotify('cooldown-done', key) flashes a key when a cooldown
-- that ran longer than the global cooldown ends; 'cooldown-start' records it.
local cooldownStart = setmetatable({}, {__mode = 'k'})
function Kit:MotionNotify(kind, frame)
	if not frame then return end
	if kind == 'cooldown-start' then
		if not cooldownStart[frame] then cooldownStart[frame] = GetTime() end
	elseif kind == 'cooldown-done' then
		local started = cooldownStart[frame]
		cooldownStart[frame] = nil
		if started and GetTime() - started > 2 and self:Alive('cooldownReady') then self:Flash(frame, {duration = 0.45}) end
	elseif kind == 'cooldown-clear' then
		cooldownStart[frame] = nil
	elseif kind == 'press' then
		if self:Alive('pressFlash') then self:Flash(frame, {alpha = 0.4, duration = 0.25}) end
	elseif kind == 'show' then
		self:PowerOn(frame)
	end
end
