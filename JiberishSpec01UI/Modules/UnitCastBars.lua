-- Unit frames: the cast bars, enabling the module and docking. Part of the unit
-- frames (UnitFrames.lua).
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown, GetTime = CreateFrame, UIParent, InCombatLockdown, GetTime
local floor, max, min, sin, pi = math.floor, math.max, math.min, math.sin, math.pi
local P = UI.UnitFrameParts
local IsSecret = UI.Util.IsSecret
local ApplyFill, ApplyShell, ApplyTrack, BelowOffset, Build, CastCfg = P.ApplyFill, P.ApplyShell, P.ApplyTrack, P.BelowOffset, P.Build, P.CastCfg
local CastColor, casts, Cfg, DB, EXTRAS, FindRangeSpell = P.CastColor, P.casts, P.Cfg, P.DB, P.EXTRAS, P.FindRangeSpell
local FitLamp, frames, IMMEDIATE, Indicators, LAYOUT, Layout = P.FitLamp, P.frames, P.IMMEDIATE, P.Indicators, P.LAYOUT, P.Layout
local LayoutAuras, MarkBar, MaskFill, module, ordered, PartyAsRaid = P.LayoutAuras, P.MarkBar, P.MaskFill, P.module, P.ordered, P.PartyAsRaid
local PartyVisibility, PlaceExtras, RefreshModel, Style, SweepAll, TIMER = P.PartyVisibility, P.PlaceExtras, P.RefreshModel, P.Style, P.SweepAll, P.TIMER
local UpdateAll, UpdateRangeDriver, Watch = P.UpdateAll, P.UpdateRangeDriver, P.Watch

-- Cast bars -------------------------------------------------------------------------------
-- The client runs the bar from its duration object (no timing is read or
-- computed here), and every cast event simply asks again what is being cast.
-- The 'slider' cast style is the reference's slider: a thin track with the lit
-- fill, a round thumb with a hairline needle riding the fill's leading edge (it
-- is anchored to the fill texture, so the client moves it), a tick scale under
-- it, the spell name above on the left and the time on the right.
local function CastSliderParts(cast)
	local parts = cast.slider
	if parts then return parts end
	local track = cast.bar:GetParent()
	parts = {}
	parts.rail = CreateFrame('Frame', nil, track)
	parts.rail:SetAllPoints(track)
	parts.rail:SetFrameLevel(max(cast.bar:GetFrameLevel() - 1, 0))
	parts.rail.skin = Kit:Skin(parts.rail, 'slider-track', 'BACKGROUND', 0)
	parts.thumb = CreateFrame('Frame', nil, cast.bar)
	parts.thumb:SetFrameLevel(cast.bar:GetFrameLevel() + 3)
	parts.thumb:SetPoint('CENTER', cast.bar:GetStatusBarTexture(), 'RIGHT', 0, 0)
	parts.thumb.skin = Kit:Skin(parts.thumb, 'slider-thumb', 'ARTWORK', 0)
	for _, side in ipairs({'TOP', 'BOTTOM'}) do
		local needle = parts.thumb:CreateTexture(nil, 'OVERLAY')
		needle:SetColorTexture(1, 1, 1, 1)
		Kit:Tint(needle, 'ink')
		needle:SetWidth(1)
		needle:SetHeight(4)
		if side == 'TOP' then needle:SetPoint('BOTTOM', parts.thumb, 'TOP', 0, -2)
		else needle:SetPoint('TOP', parts.thumb, 'BOTTOM', 0, 2) end
		parts[side] = needle
	end
	-- The tick scale: tall every fifth, laid out against the scale's own width.
	parts.ticks = CreateFrame('Frame', nil, cast)
	parts.ticks:EnableMouse(false)
	parts.ticks.marks = {}
	for index = 0, 20 do
		local tick = parts.ticks:CreateTexture(nil, 'ARTWORK')
		tick:SetColorTexture(1, 1, 1, 1)
		parts.ticks.marks[index] = tick
	end
	parts.ticks:SetScript('OnSizeChanged', function(self, width)
		if IsSecret(width) or not width or width <= 0 then return end
		local px = UI.Pixel and UI.Pixel.Px(self, 1) or 1
		for index, tick in pairs(self.marks) do
			tick:SetSize(px, index % 5 == 0 and 5 or 3)
			tick:ClearAllPoints()
			tick:SetPoint('TOP', self, 'TOPLEFT', width * index / 20, 0)
		end
	end)
	cast.slider = parts
	return parts
end

local LayoutCastPlate
local function LayoutCastSlider(cast, cfg, height)
	local parts = CastSliderParts(cast)
	local track = cast.bar:GetParent()
	local onDark = Style() == 'dark'
	cast.shell:Hide()
	track.shell:Hide()
	parts.rail:Show(); parts.thumb:Show(); parts.ticks:Show()
	local thumbHeight = min(22, max(14, height * 0.6))
	parts.thumb:SetSize(thumbHeight * 30 / 46, thumbHeight)
	Kit:FitSprite(parts.thumb.skin, thumbHeight * 30 / 46, thumbHeight)
	for _, tick in pairs(parts.ticks.marks) do Kit:Tint(tick, onDark and 'darkDim' or 'dim') end
	Kit:Tint(parts.TOP, onDark and 'darkInk' or 'ink')
	Kit:Tint(parts.BOTTOM, onDark and 'darkInk' or 'ink')
	-- Name and time above, the track in the middle, the scale under it.
	cast.icon:SetSize(12, 12)
	cast.icon:ClearAllPoints()
	cast.icon:SetPoint('TOPLEFT', cast, 'TOPLEFT', 0, 0)
	cast.icon:SetShown(cfg.icon and true or false)
	cast.label:ClearAllPoints()
	if cfg.icon then cast.label:SetPoint('LEFT', cast.icon, 'RIGHT', 5, 0) else cast.label:SetPoint('TOPLEFT', cast, 'TOPLEFT', 0, -1) end
	cast.label:SetPoint('RIGHT', cast.time, 'LEFT', -4, 0)
	cast.label:SetShown(cfg.name and true or false)
	cast.time:ClearAllPoints()
	cast.time:SetPoint('TOPRIGHT', cast, 'TOPRIGHT', 0, -1)
	cast.time:SetShown(cfg.time and true or false)
	track:ClearAllPoints()
	track:SetHeight(8)
	track:SetPoint('LEFT', cast, 'LEFT', thumbHeight * 0.4, -2)
	track:SetPoint('RIGHT', cast, 'RIGHT', -thumbHeight * 0.4, -2)
	parts.ticks:ClearAllPoints()
	parts.ticks:SetPoint('TOPLEFT', track, 'BOTTOMLEFT', 0, -thumbHeight * 0.5 + 2)
	parts.ticks:SetPoint('TOPRIGHT', track, 'BOTTOMRIGHT', 0, -thumbHeight * 0.5 + 2)
	parts.ticks:SetHeight(5)
	parts.ticks:SetShown(height >= 26)
end

local function LayoutCast(cast)
	local cfg = CastCfg(cast.unit)
	if not cfg then return end
	if not cast.docked then cast:SetSize(cfg.width or 240, cfg.height or 30) end
	local height = cast.docked and cast:GetHeight() or (cfg.height or 30)
	if DB().castStyle == 'slider' then
		LayoutCastSlider(cast, cfg, height)
	else
		LayoutCastPlate(cast, cfg, height)
	end
	-- Under its frame: anchored there, and no spot of its own.
	if cfg.position == 'under' and frames[cast.unit] then
		local owner = frames[cast.unit]
		cast:ClearAllPoints()
		local lamps = owner.lampRail and Cfg(owner).classPower and (Cfg(owner).lampSize or 6) + 12 or 0
		cast:SetPoint('TOP', owner, 'BOTTOM', 0, -6 - lamps)
	end
end

function LayoutCastPlate(cast, cfg, height)
	-- The plate style: its housing and pill track (and none of the slider's parts).
	if cast.slider then cast.slider.rail:Hide(); cast.slider.thumb:Hide(); cast.slider.ticks:Hide() end
	-- Docked, the console decides (SetDocked's keepShell).
	cast.shell:SetShown(not cast.docked or cast.keepShell and true or false)
	cast.bar:GetParent().shell:Show()
	cast.bar:GetParent():SetHeight(8)
	cast.time:ClearAllPoints()
	cast.time:SetPoint('TOPRIGHT', -6, -5)
	local iconSize = max(8, height - 10)
	cast.icon:ClearAllPoints()
	cast.icon:SetPoint('LEFT', 6, 0)
	cast.icon:SetSize(iconSize, iconSize)
	cast.icon:SetShown(cfg.icon and true or false)
	local leftOf = cfg.icon and cast.icon or nil
	cast.label:ClearAllPoints()
	if leftOf then cast.label:SetPoint('TOPLEFT', leftOf, 'TOPRIGHT', 6, 0) else cast.label:SetPoint('TOPLEFT', 6, -5) end
	cast.label:SetPoint('RIGHT', cast.time, 'LEFT', -4, 0)
	cast.label:SetShown(cfg.name and true or false)
	cast.time:SetShown(cfg.time and true or false)
	local track = cast.bar:GetParent()
	track:ClearAllPoints()
	if leftOf then track:SetPoint('BOTTOMLEFT', leftOf, 'BOTTOMRIGHT', 6, 0)
	else track:SetPoint('BOTTOMLEFT', cast, 'BOTTOMLEFT', 6, 6) end
	track:SetPoint('BOTTOMRIGHT', cast, 'BOTTOMRIGHT', -6, 6)
end

local function BuildCastBar(unit, title, at)
	local style = Style()
	local ink = Kit.INK[style]
	local cfg = CastCfg(unit)
	local cast = CreateFrame('Frame', 'JiberishSpec01'..unit:gsub('^%l', strupper)..'Cast', UIParent)
	cast:SetSize(cfg.width or 240, cfg.height or 30)
	cast:SetScale(DB().scale or 1)
	cast.shell = Kit:Shell(cast, {surface = style, radius = 7, group = 'unitframes'})
	cast.icon = cast:CreateTexture(nil, 'ARTWORK')
	cast.icon:SetSize(20, 20)
	cast.icon:SetPoint('LEFT', 6, 0)
	cast.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	cast.iconMask = cast:CreateMaskTexture()
	cast.iconMask:SetTexture(Kit.media..'mask-icon.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
	cast.iconMask:SetAllPoints(cast.icon)
	cast.icon:AddMaskTexture(cast.iconMask)
	cast.time = Kit:Text(cast, '', 'tiny', ink[2], true)
	cast.time:SetPoint('TOPRIGHT', -6, -5)
	cast.time:SetJustifyH('RIGHT')
	cast.label = Kit:Label(cast, '', ink[1], 'tiny', true)
	cast.label:SetJustifyH('LEFT')
	cast.label:SetWordWrap(false)
	local track = CreateFrame('Frame', nil, cast)
	track:SetHeight(8)
	track.shell = Kit:Shell(track, {surface = style == 'dark' and 'glass' or 'lcd', radius = 99, shadow = false,
		fill = style ~= 'dark' and 'track' or nil})
	local bar = CreateFrame('StatusBar', nil, track)
	bar:SetPoint('TOPLEFT', 2, -2)
	bar:SetPoint('BOTTOMRIGHT', -2, 2)
	bar:SetStatusBarTexture(Kit.media..'bar-flat.tga')
	MaskFill(bar, 'mask-pill', 15)
	MarkBar(bar)
	bar:SetMinMaxValues(0, 1)
	bar.track = track
	cast.bar = bar
	ApplyFill(bar, DB().castTexture)
	ApplyTrack(bar, DB().track)
	cast:SetAlpha(0)
	cast:Hide()
	cast.unit = unit
	-- The time left, from the client's duration object while a cast runs.
	cast.clock = CreateFrame('Frame', nil, cast)

	-- The lock wash: the "can't interrupt" color over the fill, shown straight
	-- from the flag, which may be secret and is then never tested.
	local wash = bar:CreateTexture(nil, 'ARTWORK', nil, 3)
	wash:SetAllPoints(bar:GetStatusBarTexture())
	wash:SetColorTexture(1, 1, 1, 1)
	if bar.fillMask then wash:AddMaskTexture(bar.fillMask) end
	wash:Hide()
	cast.wash = wash

	local function Paint(channel, locked)
		bar:SetStatusBarColor(CastColor(channel and 'channel' or 'cast'))
		wash:SetVertexColor(CastColor('locked'))
		if IsSecret(locked) then
			if wash.SetAlphaFromBoolean then
				wash:Show()
				wash:SetAlphaFromBoolean(locked, 1, 0)
			else
				wash:Hide()
			end
		else
			wash:SetAlpha(1)
			wash:SetShown(locked and true or false)
		end
	end

	-- Is anything being cast? Asked through the duration objects, which are
	-- never secret; names and flags may be, so they are never tested.
	local function Casting()
		if UnitCastingDuration then
			local duration = UnitCastingDuration(unit)
			if duration then return duration, false, false end
			if UnitEmpoweredChannelDuration then
				duration = UnitEmpoweredChannelDuration(unit, true)
				if duration then return duration, true, true end
			end
			if UnitChannelDuration then
				duration = UnitChannelDuration(unit)
				if duration then return duration, true, false end
			end
			return nil
		end
		-- Older clients without duration objects have no secret values either.
		if UnitCastingInfo(unit) ~= nil then return true, false, false end
		if UnitChannelInfo(unit) ~= nil then return true, true, false end
		return nil
	end

	-- duration: the client's duration object, or true with plain start and end times.
	local function StartClock(duration, endTime)
		cast.time:SetText('')
		if not CastCfg(unit).time then cast.clock:SetScript('OnUpdate', nil) return end
		local elapsed = 1
		cast.clock:SetScript('OnUpdate', function(_, delta)
			elapsed = elapsed + delta
			if elapsed < 0.05 then return end
			elapsed = 0
			if duration ~= true and duration.GetRemainingDuration then
				if not pcall(function() cast.time:SetFormattedText('%.1f', duration:GetRemainingDuration()) end) then cast.time:SetText('') end
			elseif endTime then
				cast.time:SetFormattedText('%.1f', max(endTime / 1000 - GetTime(), 0))
			end
		end)
	end

	-- Shows whatever the unit is casting right now; false if nothing.
	local function Start()
		local duration, channel, empowering = Casting()
		if not duration then return false end
		local name, texture, notInterruptible
		if channel then name, _, texture, _, _, _, notInterruptible = UnitChannelInfo(unit)
		else name, _, texture, _, _, _, _, notInterruptible = UnitCastingInfo(unit) end
		cast.label:SetText(name)
		cast.icon:SetTexture(texture)
		Paint(channel, notInterruptible)
		if duration ~= true and bar.SetTimerDuration and TIMER then
			-- An empowered cast charges up; a channel drains.
			bar:SetTimerDuration(duration, IMMEDIATE, (channel and not empowering) and TIMER.RemainingTime or TIMER.ElapsedTime)
			cast:SetScript('OnUpdate', nil)
			StartClock(duration)
		else
			local _, _, _, startTime, endTime = (channel and UnitChannelInfo or UnitCastingInfo)(unit)
			if IsSecret(startTime) or IsSecret(endTime) or not startTime then return false end
			bar:SetMinMaxValues(startTime / 1000, endTime / 1000)
			cast:SetScript('OnUpdate', function()
				local now = GetTime()
				bar:SetValue(channel and (endTime / 1000 - (now - startTime / 1000)) or now)
			end)
			StartClock(true, endTime)
		end
		cast.stopping = nil
		cast:Show()
		Kit:FadeTo(cast, 1, 'FAST')
		return true
	end

	local function Stop(failed)
		if cast.stopping or not cast:IsShown() then return end
		cast.stopping = true
		cast:SetScript('OnUpdate', nil)
		cast.clock:SetScript('OnUpdate', nil)
		cast.time:SetText('')
		local function Out()
			if cast.stopping then Kit:FadeTo(cast, 0, 'FAST', function() if cast.stopping then cast:Hide() end end) end
		end
		if failed then
			-- An interrupted cast holds a moment in red so the eye catches it.
			wash:Hide()
			bar:SetStatusBarColor(CastColor('interrupted'))
			cast.label:SetText(failed)
			C_Timer.After(0.6, Out)
		else
			Out()
		end
	end

	local function Refresh()
		local ok, started = pcall(Start)
		if not (ok and started) then Stop() end
	end

	cast:SetScript('OnEvent', function(_, event)
		if UI:MoversUnlocked() then return end
		if event == 'UNIT_SPELLCAST_INTERRUPTED' or event == 'UNIT_SPELLCAST_FAILED' then
			-- A rejected key press during a cast also fires FAILED: only stop if
			-- nothing is being cast any more.
			local ok, casting = pcall(Casting)
			if ok and casting then Refresh()
			else Stop(event == 'UNIT_SPELLCAST_INTERRUPTED' and 'INTERRUPTED' or 'FAILED') end
		elseif event == 'PLAYER_TARGET_CHANGED' then
			cast.stopping = true
			cast:Hide()
			Refresh()
		else
			-- Starts, stops, delays and updates all just ask the client again.
			Refresh()
		end
	end)
	for _, event in ipairs({'UNIT_SPELLCAST_START', 'UNIT_SPELLCAST_STOP', 'UNIT_SPELLCAST_FAILED', 'UNIT_SPELLCAST_INTERRUPTED',
		'UNIT_SPELLCAST_DELAYED', 'UNIT_SPELLCAST_CHANNEL_START', 'UNIT_SPELLCAST_CHANNEL_UPDATE', 'UNIT_SPELLCAST_CHANNEL_STOP',
		'UNIT_SPELLCAST_INTERRUPTIBLE', 'UNIT_SPELLCAST_NOT_INTERRUPTIBLE', 'UNIT_SPELLCAST_EMPOWER_START',
		'UNIT_SPELLCAST_EMPOWER_UPDATE', 'UNIT_SPELLCAST_EMPOWER_STOP'}) do
		pcall(cast.RegisterUnitEvent, cast, event, unit)
	end
	if unit == 'target' then cast:RegisterEvent('PLAYER_TARGET_CHANGED') end
	-- 'under' rides under its frame; 'docked' and 'free' have their own spot
	-- (a docked bar uses it when the console isn't docking).
	if cfg.position ~= 'under' or not frames[unit] then UI:RegisterMover(cast, 'cb.'..unit, title, at) end
	function cast:SetPreview(on)
		if on then
			self.stopping = nil
			self:SetScript('OnUpdate', nil)
			self.clock:SetScript('OnUpdate', nil)
			self.label:SetText(strupper(title))
			self.time:SetText('1.5')
			self.bar:SetMinMaxValues(0, 1)
			self.bar:SetValue(0.6)
			Paint(true)
			self:Show()
			self:SetAlpha(1)
		else
			self.stopping = true
			self:SetAlpha(0)
			self:Hide()
			-- Pick up a cast that started while placing.
			Refresh()
		end
	end
	casts[unit] = cast
	LayoutCast(cast)
	return cast
end

-- Blizzard frames this replaces. Boss and raid frames stay Blizzard's.
local function RetireBlizzard(layout)
	local unit = layout.unit
	if unit == 'player' then UI:Retire(_G.PlayerFrame)
	elseif unit == 'target' then UI:Retire(_G.TargetFrame); UI:Retire(_G.ComboFrame)
	elseif unit == 'focus' then UI:Retire(_G.FocusFrame)
	elseif unit == 'pet' then UI:Retire(_G.PetFrame)
	elseif unit == 'party1' then
		-- Members live in a pool inside PartyFrame; hiding the parent hides them.
		UI:Retire(_G.PartyFrame)
		for index = 1, 4 do UI:Retire(_G['PartyMemberFrame'..index]) end
		-- Edit Mode's "raid-style party frames" would show beside ours.
		UI:Retire(_G.CompactPartyFrame)
	end
end

local function HideBlizzardCastBar()
	for _, name in ipairs({'PlayerCastingBarFrame', 'CastingBarFrame'}) do
		local bar = _G[name]
		if bar and not (bar.IsForbidden and bar:IsForbidden()) then UI:Retire(bar) end
	end
end

local function Add(layout)
	local frame = Build(layout)
	frames[layout.unit] = frame
	ordered[#ordered + 1] = frame
	return frame
end

-- A frame (or the console holding it) rescaled from the Layout page or a
-- handle: redraw its model at the new scale. Moves alone don't redraw.
if UI.OnMoversChanged then
	UI:OnMoversChanged(function(key)
		if key == '__select' or key == '__lock' then return end
		for _, frame in ipairs(ordered) do
			if frame.model and frame.portraitMode == 'model' then
				local scale = frame:GetEffectiveScale()
				if frame.modelScale ~= scale then
					frame.modelScale = scale
					RefreshModel(frame)
				end
			end
		end
	end)
end

-- A model drawn before the interface's scale settles (login, a UI scale
-- change) renders off-centre or out of its box: redraw every model after.
UI.Pixel.OnChange(function()
	for _, frame in pairs(frames) do
		if frame.model and frame.portraitMode == 'model' then RefreshModel(frame) end
		FitLamp(frame)
	end
end)

-- 0.5.1: the combat cue took over marking combat, so the sweep is off by
-- default, and switched off once in profiles saved before.
local function MoveSweep()
	if DB().sweepMoved then return end
	DB().combatSweep = false
	DB().sweepMoved = true
end

function module:Enable()
	MoveSweep()
	-- 0.5.0's gloss switch: off carries over as no motion.
	if DB().powerGloss == false then DB().powerMotion = 'off' end
	DB().powerGloss = nil
	if InCombatLockdown() then
		UI:AfterCombat(function()
			self.enabled = UI:Safe(self.Enable, self)
			-- The console docked nothing while these were missing: let it look again.
			local bars = UI.modules.actionbars
			if self.enabled and bars and bars.enabled and bars.Refresh then UI:Safe(bars.Refresh, bars) end
		end, 'unitframes')
		return
	end
	-- Party frames sit under one parent that hides them in raids, where the raid
	-- frames take over, and when solo (and always while raid frames show the party).
	module.partyHeader = CreateFrame('Frame', 'JiberishSpec01PartyHeader', UIParent, 'SecureHandlerStateTemplate')
	module.partyHeader:SetAllPoints()
	RegisterStateDriver(module.partyHeader, 'visibility', PartyVisibility())
	local units = DB().units
	for _, layout in ipairs(LAYOUT) do
		local skip = not units[layout.key].enable or (layout.party and not DB().party) or (layout.unit == 'focus' and not _G.FocusFrame)
		if not skip then
			Add(layout)
			RetireBlizzard(layout)
		end
	end
	for _, layout in ipairs(EXTRAS) do
		if Indicators()[layout.extra] and frames[layout.owner] then Add(layout) end
	end
	PlaceExtras()
	if DB().castbar then
		local playerCast = BuildCastBar('player', 'Player cast', {'BOTTOM', 0, 196})
		local targetCast = BuildCastBar('target', 'Target cast', {'BOTTOM', 228, 166})
		-- Only cast bars set to 'docked' are handed to the console.
		if CastCfg('player').position == 'docked' then module.playerCast = playerCast end
		if CastCfg('target').position == 'docked' then module.targetCast = targetCast end
		HideBlizzardCastBar()
		-- Auras below a frame make room for a cast bar placed under it.
		for unit in pairs(casts) do if frames[unit] then UI:Safe(LayoutAuras, frames[unit]) end end
	end
	FindRangeSpell()
	UpdateRangeDriver()
	local driver = CreateFrame('Frame')
	driver:RegisterEvent('PLAYER_REGEN_DISABLED')
	driver:RegisterEvent('PLAYER_REGEN_ENABLED')
	driver:RegisterEvent('SPELLS_CHANGED')
	driver:SetScript('OnEvent', function(_, event)
		if event == 'SPELLS_CHANGED' then return FindRangeSpell() end
		if event == 'PLAYER_REGEN_DISABLED' then SweepAll('lamp', 0.5, 0.9)
		else SweepAll('amber', 0.9, 0.55) end
	end)
end

-- Docked inside the console, a frame or cast bar sits on the console's own
-- housing, so it drops its shell; undocked it gets it back.
-- keepShell: an LCD-style frame keeps its own LCD face inside the console.
-- embed: {width, height} in the frame's own units: the frame sits embedded in
-- a console bay at that size, without its housing or header (the console
-- prints the header over the bay); nil for the floating docked look.
function module:SetDocked(object, docked, keepShell, embed)
	object.docked = docked and true or nil
	object.keepShell = keepShell and true or nil
	local width, height = embed and embed[1], embed and embed[2]
	local embedded = docked and width and height and true or nil
	if object.layout and (embedded ~= object.embedded or (embedded and (object.embedW ~= width or object.embedH ~= height))) then
		object.embedded, object.embedW, object.embedH = embedded, width, height
		if embedded then
			local frame = object
			object.embedCfg = setmetatable({}, {__index = function(_, field)
				if field == 'width' then return frame.embedW
				elseif field == 'height' then return frame.embedH
				elseif field == 'header' then return false end
				return Cfg(frame)[field]
			end})
		else
			object.embedCfg = nil
		end
		UI:Safe(Layout, object)
		if object:IsShown() then UI:Safe(UpdateAll, object) end
		return
	end
	object.embedded = object.layout and object.embedded or (docked and embed and true or nil)
	if object.shapeName then ApplyShell(object, object.shapeName)
	elseif object.shell then object.shell:SetShown(not docked or keepShell and true or false) end
	-- A cast bar's width changes with its slot; its parts follow.
	if object.label and object.bar then LayoutCast(object) end
end

-- A frame's own size from its settings (frame units), whatever its bay made it.
function module:DockBaseSize(frame)
	local cfg = frame and frame.layout and Cfg(frame)
	if not cfg then return 0, 0 end
	return cfg.width or 0, cfg.height or 0
end

-- Room an embedded large frame needs under its face for its class lamps and
-- one row of auras (frame units).
function module:DockRoom(frame)
	if not (frame and frame.layout and frame.layout.size == 'large') then return 0 end
	local cfg = Cfg(frame)
	local room = 0
	if DB().auras and cfg.auras and (cfg.auraPosition or 'below') == 'below' and (cfg.auraMax or 8) > 0 then
		room = BelowOffset(frame) + (cfg.auraSize or 22)
	elseif frame.lampRail and cfg.classPower then
		room = (cfg.lampSize or 6) + 12
	end
	return room
end

local lastPartyAsRaid
function module:Refresh()
	MoveSweep()
	for _, frame in ipairs(ordered) do
		UI:Safe(Layout, frame)
		if frame:IsShown() then UI:Safe(UpdateAll, frame) end
	end
	PlaceExtras()
	for key, cast in pairs(casts) do
		UI:Safe(LayoutCast, cast)
		UI:Safe(ApplyFill, cast.bar, DB().castTexture)
		UI:Safe(ApplyTrack, cast.bar, DB().track)
		if not InCombatLockdown() and not cast.docked then
			UI:SetMoverBaseScale('cb.'..key, DB().scale or 1, cast, CastCfg(key).position == 'under')
		end
	end
	-- The raid frames took over (or gave back) the party.
	local asRaid = PartyAsRaid()
	if module.partyHeader and asRaid ~= lastPartyAsRaid and not UI:MoversUnlocked() then
		lastPartyAsRaid = asRaid
		UI:AfterCombat(function()
			RegisterStateDriver(module.partyHeader, 'visibility', PartyVisibility())
			for _, frame in ipairs(ordered) do if frame.layout.party then Watch(frame) end end
		end, 'uf.partyAsRaid')
	end
	UpdateRangeDriver()
	-- A scale change doesn't resize, so physical-pixel edges are refit here.
	Kit:RefitShells()
end
