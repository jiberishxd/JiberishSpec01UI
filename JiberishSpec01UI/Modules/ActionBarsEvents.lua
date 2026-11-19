-- The extra and zone abilities, Blizzard's retired bars, and the action bar
-- events. Part of the action bars (ActionBars.lua).
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown, GetTime = CreateFrame, UIParent, InCombatLockdown, GetTime
local floor, max, min = math.floor, math.max, math.min
local format, ipairs, pairs, pcall, tonumber = format, ipairs, pairs, pcall, tonumber
local P = UI.ActionBarParts
local Forbidden, IsSecret = UI.Util.Forbidden, UI.Util.IsSecret
local ApplyCVars, Bind, binder, bySlot, DB, Dress = P.ApplyCVars, P.Bind, P.binder, P.bySlot, P.DB, P.Dress
local dressed, Fade, ForKeys, HideDocked, HW, keys = P.dressed, P.Fade, P.ForKeys, P.HideDocked, P.HW, P.keys
local LayoutConsole, LayoutMenu, LayoutStance, PlacePetKeys, RefreshDressed, RETIRED_BARS = P.LayoutConsole, P.LayoutMenu, P.LayoutStance, P.PlacePetKeys, P.RefreshDressed, P.RETIRED_BARS
local RETIRED_BUTTONS, SetGlow, UpdateCooldown, UpdateFades, UpdateGlow, UpdateGrid = P.RETIRED_BUTTONS, P.SetGlow, P.UpdateCooldown, P.UpdateFades, P.UpdateGlow, P.UpdateGrid
local UpdateKey, UpdateLeave, UpdatePet, UpdateRange, UpdateStance, UpdateState = P.UpdateKey, P.UpdateLeave, P.UpdatePet, P.UpdateRange, P.UpdateStance, P.UpdateState
local UpdateUsable, UpdateXP = P.UpdateUsable, P.UpdateXP

-- Extra ability and zone ability ------------------------------------------------------------
-- Blizzard's own buttons keep working; their style frames go, they sit on a key,
-- and our holder (a mover) carries them.
local function BuildExtra()
	local holder = CreateFrame('Frame', 'JiberishSpec01ExtraHolder', UIParent)
	holder:SetSize(60, 60)
	UI:RegisterMover(holder, 'ab.extra', 'Extra ability', {'BOTTOM', 0, 300})
	local zoneHolder = CreateFrame('Frame', 'JiberishSpec01ZoneHolder', UIParent)
	zoneHolder:SetSize(60, 60)
	UI:RegisterMover(zoneHolder, 'ab.zone', 'Zone ability', {'BOTTOM', -90, 300})
	local function Carry(frame, target)
		if not frame or Forbidden(frame) then return end
		local function Place()
			if InCombatLockdown() then return UI:AfterCombat(Place, 'ab.carry.'..(frame:GetName() or '')) end
			if frame:GetParent() ~= target then frame:SetParent(target) end
			local _, relative = frame:GetPoint(1)
			if relative ~= target then
				frame:ClearAllPoints()
				frame:SetPoint('CENTER', target, 'CENTER')
			end
		end
		Place()
		-- Its container re-lays it from time to time; put it back a frame later.
		local function Queue() C_Timer.After(0, function() UI:Safe(Place) end) end
		hooksecurefunc(frame, 'SetPoint', function(self)
			local _, relative = self:GetPoint(1)
			if relative ~= target then Queue() end
		end)
		hooksecurefunc(frame, 'SetParent', function(self, parent) if parent ~= target then Queue() end end)
	end
	Carry(_G.ExtraActionBarFrame, holder)
	Carry(_G.ZoneAbilityFrame, zoneHolder)
	local extra = _G.ExtraActionButton1
	if extra and not Forbidden(extra) then
		Fade(extra.style)
		-- Hardware: a big round key in a round hole.
		Dress(extra, HW.On() and 52 or 48, true)
	end
	local zone = _G.ZoneAbilityFrame
	if zone then
		Fade(zone.Style)
		-- Zone abilities come and go from a pool; dress each one as it shows,
		-- out of combat (they are sized here).
		local container = zone.SpellButtonContainer
		local function DressZone()
			if not HW.On() or not (container and container.EnumerateActive) then return end
			if InCombatLockdown() then return UI:AfterCombat(DressZone, 'ab.zonekeys') end
			for button in container:EnumerateActive() do
				if not Forbidden(button) and not dressed[button] then Dress(button, 52, true) end
			end
		end
		if type(zone.UpdateDisplayedZoneAbilities) == 'function' then
			hooksecurefunc(zone, 'UpdateDisplayedZoneAbilities', function() C_Timer.After(0, function() UI:Safe(DressZone) end) end)
		end
		UI:Safe(DressZone)
	end
end

-- Blizzard's bars ----------------------------------------------------------------------
local function RetireBlizzard()
	-- Keep only what the extra action button needs from the bar controllers, as ElvUI does.
	local controller = _G.ActionBarController
	if controller and not Forbidden(controller) then
		controller:UnregisterAllEvents()
		controller:RegisterEvent('SETTINGS_LOADED')
		pcall(controller.RegisterEvent, controller, 'UPDATE_EXTRA_ACTIONBAR')
	end
	local actionEvents = _G.ActionBarActionEventsFrame
	if actionEvents and not Forbidden(actionEvents) then actionEvents:UnregisterAllEvents() end
	local events = _G.ActionBarButtonEventsFrame
	if events and not Forbidden(events) then
		events:UnregisterAllEvents()
		events:RegisterEvent('ACTIONBAR_SLOT_CHANGED')
		events:RegisterEvent('ACTIONBAR_UPDATE_COOLDOWN')
		if WOW_PROJECT_ID and WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE then pcall(events.RegisterEvent, events, 'PLAYER_ENTERING_WORLD') end
	end
	for _, prefix in ipairs(RETIRED_BUTTONS) do
		for index = 1, 12 do
			local button = _G[prefix..index]
			if button and not Forbidden(button) then
				button:UnregisterAllEvents()
				button:SetAttribute('statehidden', true)
				button:Hide()
			end
		end
	end
	for _, name in ipairs(RETIRED_BARS) do UI:Retire(_G[name]) end
	-- The vehicle leave button is an Edit Mode system: never reparented, only
	-- silenced and hidden (the console has its own Leave key).
	local leave = _G.MainMenuBarVehicleLeaveButton
	if leave and not Forbidden(leave) then
		leave:UnregisterAllEvents()
		leave:Hide()
		leave:SetAlpha(0)
	end
	-- Experience and reputation are the console's own meter now.
	if DB().xpbar then
		-- Only the manager: the two bar containers are Edit Mode systems that call
		-- their parent's methods, so they must stay its children (as ElvUI does).
		UI:Retire(_G.StatusTrackingBarManager)
	end
end

-- Events ---------------------------------------------------------------------------------
local dirty, queued = {}, false
local function Flush()
	queued = false
	local work = dirty
	dirty = {}
	if work.all then ForKeys(UpdateKey); RefreshDressed()
	else
		if work.cooldown then ForKeys(UpdateCooldown) end
		if work.state then ForKeys(UpdateState); RefreshDressed() end
		if work.usable then ForKeys(UpdateUsable) end
		if work.range then ForKeys(UpdateRange) end
	end
	if work.pet then UI:Safe(UpdatePet); UI:Safe(PlacePetKeys) end
	if work.stance then UI:Safe(UpdateStance) end
	if work.stanceLayout then UI:Safe(LayoutStance) end
	if work.xp then UI:Safe(UpdateXP) end
	if work.leave then UI:Safe(UpdateLeave) end
	if work.cvars then UI:Safe(ApplyCVars) end
	if work.menu then UI:Safe(LayoutMenu) end
	if work.layout then UI:Safe(LayoutConsole) end
end
local function Queue(what)
	dirty[what] = true
	if queued then return end
	queued = true
	C_Timer.After(0, Flush)
end

local EVENTS = {
	ACTIONBAR_UPDATE_COOLDOWN = 'cooldown', LOSS_OF_CONTROL_ADDED = 'cooldown', LOSS_OF_CONTROL_UPDATE = 'cooldown',
	SPELL_UPDATE_CHARGES = 'cooldown', SPELL_UPDATE_COOLDOWN = 'cooldown',
	ACTIONBAR_UPDATE_STATE = 'state', START_AUTOREPEAT_SPELL = 'state', STOP_AUTOREPEAT_SPELL = 'state', PLAYER_ENTER_COMBAT = 'state',
	PLAYER_LEAVE_COMBAT = 'state', TRADE_SKILL_SHOW = 'state', TRADE_SKILL_CLOSE = 'state', ARCHAEOLOGY_CLOSED = 'state',
	ACTIONBAR_UPDATE_USABLE = 'usable', SPELL_UPDATE_USABLE = 'usable',
	PLAYER_ENTERING_WORLD = 'all', SPELLS_CHANGED = 'all', UPDATE_BONUS_ACTIONBAR = 'all',
	UPDATE_VEHICLE_ACTIONBAR = 'all', UPDATE_OVERRIDE_ACTIONBAR = 'all', ACTIONBAR_PAGE_CHANGED = 'all', SPELL_UPDATE_ICON = 'all',
	BAG_UPDATE_DELAYED = 'all', UPDATE_MACROS = 'all', PLAYER_MOUNT_DISPLAY_CHANGED = 'all', LEARNED_SPELL_IN_SKILL_LINE = 'all',
	PET_BAR_UPDATE = 'pet', PET_BAR_UPDATE_COOLDOWN = 'pet', PET_UI_UPDATE = 'pet', PLAYER_FARSIGHT_FOCUS_CHANGED = 'pet',
	UPDATE_SHAPESHIFT_USABLE = 'stance', UPDATE_SHAPESHIFT_COOLDOWN = 'stance', UPDATE_SHAPESHIFT_FORMS = 'stanceLayout',
	PLAYER_XP_UPDATE = 'xp', PLAYER_LEVEL_UP = 'xp', UPDATE_EXHAUSTION = 'xp', UPDATE_FACTION = 'xp', ENABLE_XP_GAIN = 'xp',
	DISABLE_XP_GAIN = 'xp',
	UPDATE_MULTI_CAST_ACTIONBAR = 'leave', VEHICLE_UPDATE = 'leave', UPDATE_POSSESS_BAR = 'leave', TAXIMAP_CLOSED = 'leave',
	CVAR_UPDATE = 'cvars', PLAYER_TARGET_CHANGED = 'usable',
}

local function OnEvent(_, event, ...)
	if event == 'ACTIONBAR_SLOT_CHANGED' then
		local slot = ...
		if not slot or slot == 0 or not bySlot[slot] then return Queue('all') end
		for key in pairs(bySlot[slot]) do UI:Safe(UpdateKey, key) end
	elseif event == 'ACTION_USABLE_CHANGED' then
		local changes = ...
		if type(changes) ~= 'table' then return Queue('usable') end
		for _, change in ipairs(changes) do
			local slotKeys = type(change) == 'table' and bySlot[change.slot]
			if slotKeys then for key in pairs(slotKeys) do UpdateUsable(key, change.usable, change.noMana) end end
		end
	elseif event == 'ACTION_RANGE_CHECK_UPDATE' then
		local slot, inRange, checksRange = ...
		local slotKeys = bySlot[slot]
		if slotKeys then for key in pairs(slotKeys) do UpdateRange(key, inRange, checksRange) end end
	elseif event == 'SPELL_ACTIVATION_OVERLAY_GLOW_SHOW' or event == 'SPELL_ACTIVATION_OVERLAY_GLOW_HIDE' then
		local spell = ...
		local on = event == 'SPELL_ACTIVATION_OVERLAY_GLOW_SHOW'
		for _, key in ipairs(keys) do
			if IsSecret(spell) then UpdateGlow(key) elseif key.spell == spell then SetGlow(key, on) end
		end
	elseif event == 'UPDATE_BINDINGS' then
		Bind()
	elseif event == 'PLAYER_REGEN_DISABLED' or event == 'PLAYER_REGEN_ENABLED' then
		-- The fight starts before lockdown does, so trust the event.
		P.inCombat = event == 'PLAYER_REGEN_DISABLED'
		if P.console and P.console.lamp then Kit:SetLed(P.console.lamp, P.inCombat) end
		UpdateFades()
	elseif event == 'ACTIONBAR_SHOWGRID' or event == 'ACTIONBAR_HIDEGRID' then
		P.dragging = event == 'ACTIONBAR_SHOWGRID'
		ForKeys(UpdateGrid)
	elseif event == 'UNIT_PET' or event == 'UNIT_FLAGS' then
		Queue('pet')
	elseif event == 'UPDATE_SHAPESHIFT_FORM' then
		Queue('all'); Queue('stance')
	elseif event == 'PLAYER_CONTROL_LOST' or event == 'PLAYER_CONTROL_GAINED' then
		Queue('pet'); Queue('leave')
	elseif event == 'PET_BATTLE_OPENING_START' then
		-- Pet battle abilities answer the number keys while a battle is on.
		if not InCombatLockdown() then ClearOverrideBindings(binder) end
		HideDocked(true)
	elseif event == 'PET_BATTLE_CLOSE' then
		Bind()
		HideDocked(false)
	elseif event == 'UNIT_ENTERED_VEHICLE' or event == 'UNIT_EXITED_VEHICLE' then
		Queue('leave'); Queue('state')
	elseif event == 'UNIT_INVENTORY_CHANGED' then
		Queue('all')
	elseif EVENTS[event] then
		Queue(EVENTS[event])
		-- The unit frames may have been built (or resized) after the console: lay it out again.
		if event == 'PLAYER_ENTERING_WORLD' then Queue('pet'); Queue('stanceLayout'); Queue('xp'); Queue('leave'); Queue('menu'); Queue('layout') end
		if event == 'PLAYER_TARGET_CHANGED' then Queue('range') end
	end
end

-- The console's deck --------------------------------------------------------------------
-- Everything around the keys that is read rather than pressed, and the keys
-- that open things:
--   * Meters along the base: experience, reputation or honor (or Auto: XP
--     while levelling, reputation at the cap), one or two stacked, as LED
--     dots, a flat bar with a lit edge, segments or a slim hairline, with
--     rested XP (and optionally the XP of quests ready to hand in) as lighter
--     overlays. Click to cycle the source, right-click for reputations.
--   * A stats strip above them: up to six small LCD readouts the player picks
--     (XP per hour, time to level, time played, session, rested, kills to
--     level, gold per hour, reputation, honor, ...).
--   * Function keys at the top of the side columns: mount, hearthstone, map,
--     spellbook, bags, drawer, move UI, calendar, ..., or a macro by name.
--     They are our own secure buttons, set up out of combat only.
--   * Small LCD panels in the header: zone and coordinates, gold, durability
--     and latency.
-- All values read here are plain or skipped: nothing secret is compared.
-- The deck runs inside a function of its own: its locals count against that
-- function's limit, not the main chunk's.

-- Shared with the other action bar files.
P.BuildExtra = BuildExtra
P.EVENTS = EVENTS
P.OnEvent = OnEvent
P.RetireBlizzard = RetireBlizzard
