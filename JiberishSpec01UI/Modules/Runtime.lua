-- Settings plumbing, shared media, toast notifications and status badges.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent = CreateFrame, UIParent
local floor = math.floor
local LSM = LibStub and LibStub('LibSharedMedia-3.0', true)

local function IsSecret(value) return issecretvalue and issecretvalue(value) end

-- Usable from any addon that reads LibSharedMedia, when one provides the library.
if LSM then
	LSM:Register('statusbar', 'SPEC-01 Flat', Kit.media..'bar-flat.tga')
	LSM:Register('statusbar', 'SPEC-01 Dots', Kit.media..'bar-dots.tga')
	LSM:Register('statusbar', 'SPEC-01 Segments', Kit.media..'bar-segments.tga')
	for _, name in ipairs(Kit.sounds) do
		LSM:Register('sound', 'SPEC-01: '..name, Kit.media..[[Sounds\]]..name..'-1.mp3')
	end
end

function Kit:SetOption(path, value)
	local node = self:DB()
	local keys = {strsplit('.', path)}
	for index = 1, #keys - 1 do node = node[keys[index]] end
	node[keys[#keys]] = value
	self:Apply()
end

-- Only a change to the scale itself applies it; the first call just notes it.
-- The repaint runs first, so modules lay out against the new fonts and sizes.
-- A slider drag asks many times a second: an apply runs at once, and any more
-- asked for within 0.1 s become one more at its end.
local appliedScale
local lastApply, applyQueued = 0, false
local function ApplyNow(self)
	applyQueued = false
	lastApply = GetTime()
	if appliedScale == nil then appliedScale = UI.db.uiScale end
	if UI.Pixel and UI.db.uiScale and UI.db.uiScale ~= appliedScale then
		appliedScale = UI.db.uiScale
		UI.Pixel.SetScale(UI.db.uiScale)
	end
	self:RefreshNow()
	self:UpdateDeck()
	self:UpdateToastAnchor()
	UI:Safe(self.UpdateStatusStrip, self)
	for _, name in ipairs(UI.moduleOrder) do
		local module = UI.modules[name]
		if module.enabled and module.Refresh then UI:Safe(module.Refresh, module) end
	end
	if UI.UpdateSettings then UI:UpdateSettings() end
end

function Kit:Apply()
	if GetTime() - lastApply >= 0.1 then return ApplyNow(self) end
	if applyQueued then return end
	applyQueued = true
	C_Timer.After(0.1, function()
		if applyQueued then ApplyNow(Kit) end
	end)
end

-- Toast notifications ----------------------------------------------------------
local lowDurability, hadMail

local function LowestDurability()
	local lowest
	for slot = 1, 18 do
		local current, maximum = GetInventoryItemDurability(slot)
		if not IsSecret(current) and not IsSecret(maximum) and current and maximum and maximum > 0 then
			local fraction = current / maximum
			if not lowest or fraction < lowest then lowest = fraction end
		end
	end
	return lowest
end

-- With the loot and alerts module on, level-ups and achievements are its banners.
local function Banners()
	local banners = UI.modules.loot
	return banners and banners.enabled
end

local function Notify(setting, opts)
	local db = Kit:DB().toasts
	if db.enable and db[setting] then Kit:Toast(opts) end
end

local toastEvents = {
	UPDATE_PENDING_MAIL = function()
		local mail = HasNewMail() and true or false
		if mail and hadMail == false then Notify('mail', {title = 'New mail', text = 'Something is waiting in your mailbox.', tone = 'info'}) end
		hadMail = mail
	end,
	PLAYER_LEVEL_UP = function(level)
		if not IsSecret(level) and not Banners() then Notify('levelUp', {title = 'Level '..tostring(level), text = 'You gained a level.', tone = 'success'}) end
	end,
	READY_CHECK = function(initiator)
		local name = (not IsSecret(initiator) and type(initiator) == 'string') and initiator or nil
		Notify('readyCheck', {title = 'Ready check', text = name and (name..' wants to know if you are ready.') or nil, tone = 'warning'})
	end,
	UPDATE_INVENTORY_DURABILITY = function()
		local lowest = LowestDurability()
		if lowest and lowest < 0.2 and not lowDurability then
			lowDurability = true
			Notify('durability', {title = format('Durability at %d%%', floor(lowest * 100 + 0.5)), text = 'Repair before the next pull.', tone = 'warning'})
		elseif lowest and lowest > 0.3 then lowDurability = false end
	end,
	ACHIEVEMENT_EARNED = function(id)
		if IsSecret(id) or not GetAchievementInfo or Banners() then return end
		local _, name = GetAchievementInfo(id)
		if not IsSecret(name) and name then Notify('achievement', {title = 'Achievement earned', text = name, tone = 'success'}) end
	end,
}

function Kit:UpdateToastAnchor()
	local anchor = _G.JiberishSpec01ToastAnchor
	if not anchor then return end
	local db = self:DB().toasts
	anchor:ClearAllPoints()
	anchor:SetPoint('TOP', UIParent, 'TOP', db.x or 0, db.y or -160)
end

-- Status badges ------------------------------------------------------------------
local strip
-- Lockdown starts after PLAYER_REGEN_DISABLED fires, so the event says it first.
local combatEvent
local function StatusList()
	local list = {}
	local inCombat = combatEvent == 'PLAYER_REGEN_DISABLED' or (combatEvent ~= 'PLAYER_REGEN_ENABLED' and InCombatLockdown())
	if inCombat then list[#list + 1] = {'Combat', 'red'} else list[#list + 1] = {'Ready', 'green'} end
	if IsResting() then list[#list + 1] = {'Resting', 'blue'} end
	local afk, dnd = UnitIsAFK('player'), UnitIsDND('player')
	if not IsSecret(afk) and afk then list[#list + 1] = {'AFK', 'amber'} end
	if not IsSecret(dnd) and dnd then list[#list + 1] = {'DND', 'red'} end
	if HasNewMail() then list[#list + 1] = {'Mail', 'blue'} end
	local lowest = LowestDurability()
	if lowest and lowest < 0.2 then list[#list + 1] = {'Repair', 'amber'} end
	return list
end

function Kit:UpdateStatusStrip()
	local db = self:DB().status
	if not db.enable then
		if strip then strip:Hide() end
		return
	end
	if not strip then
		strip = CreateFrame('Frame', 'JiberishSpec01StatusStrip', UIParent)
		strip:SetSize(260, 22)
		strip.badges = {}
	end
	strip:ClearAllPoints()
	strip:SetPoint('BOTTOM', UIParent, 'BOTTOM', db.x or 0, db.y or 220)
	local list, width = StatusList(), 0
	for index, data in ipairs(list) do
		local badge = strip.badges[index]
		if not badge then
			badge = self:Badge(strip, {})
			strip.badges[index] = badge
		end
		badge:SetBadge(data[1], data[2])
		badge:Show()
		width = width + badge:GetWidth() + (index > 1 and 6 or 0)
	end
	for index = #list + 1, #strip.badges do strip.badges[index]:Hide() end
	local x = -width / 2
	for index = 1, #list do
		local badge = strip.badges[index]
		badge:ClearAllPoints()
		badge:SetPoint('LEFT', strip, 'CENTER', x, 0)
		x = x + badge:GetWidth() + 6
	end
	strip:Show()
end

local module = UI:RegisterModule('runtime', {always = true})
function module:Enable()
	local driver = CreateFrame('Frame')
	-- Not every client has every event; an unknown name must not stop setup.
	for event in pairs(toastEvents) do pcall(driver.RegisterEvent, driver, event) end
	for _, event in ipairs({'PLAYER_ENTERING_WORLD', 'PLAYER_REGEN_DISABLED', 'PLAYER_REGEN_ENABLED',
		'PLAYER_UPDATE_RESTING', 'PLAYER_FLAGS_CHANGED'}) do
		driver:RegisterEvent(event)
	end
	driver:SetScript('OnEvent', function(_, event, ...)
		if event == 'PLAYER_ENTERING_WORLD' then
			hadMail = HasNewMail() and true or false
			local lowest = LowestDurability()
			lowDurability = (lowest and lowest < 0.2) or false
		end
		local handler = toastEvents[event]
		if handler then UI:Safe(handler, ...) end
		combatEvent = event
		UI:Safe(Kit.UpdateStatusStrip, Kit)
		combatEvent = nil
	end)
	Kit:UpdateStatusStrip()
	return true
end

-- Hub pages ---------------------------------------------------------------------
-- defaults:begin
UI:RegisterDefaults('sound', {
	-- Each kind: 'spec' (ours, the game's own muted), 'game', 'both' or 'off'.
	kinds = {windows = 'spec', menus = 'spec', tabs = 'spec', checkboxes = 'spec', buttons = 'spec', errors = 'game',
		quest = 'spec', loot = 'both', alerts = 'both'},
})
-- defaults:end

local MODES = {{'spec', 'SPEC-01'}, {'game', 'Game'}, {'both', 'Both'}, {'off', 'Off'}}
local KIND_ROWS = {
	{'windows', 'Windows', 'Opening and closing windows and bags.'},
	{'menus', 'Menus', 'Dropdowns and right-click menus.'},
	{'tabs', 'Tabs and pages', 'Window tabs and turning pages.'},
	{'checkboxes', 'Checkboxes', 'Options turned on and off.'},
	{'buttons', 'Buttons', 'Push buttons, chat scrolling and minimap zoom.'},
	{'errors', 'Errors', '"Not enough mana" and the like. SPEC-01 and Off also quiet the character\'s spoken line.'},
	{'quest', 'Quest ready', 'A chime when every objective of a quest is done. The game has none of its own.'},
	{'loot', 'Loot', 'Coins and loot toasts.'},
	{'alerts', 'Alerts', 'Ready checks, raid warnings, whispers and invites.'},
}

local kindRows, testRows = {
	{'note', 'SPEC-01 plays ours and mutes the game\'s own; Both plays the two together. A game sound shared by several kinds is muted only while all of them ask for it.'},
}, {}
for _, kind in ipairs(KIND_ROWS) do
	kindRows[#kindRows + 1] = {'segmented', kind[2], 'sound.kinds.'..kind[1], items = MODES, note = kind[3]}
	testRows[#testRows + 1] = {'button', kind[2], 'Test', function() if UI.TestSound then UI:TestSound(kind[1]) end end}
end

UI:RegisterPage('sounds', {title = 'Sounds', order = 20, cards = {
	{title = 'Playback', rows = {
		{'switch', 'Sounds', 'sound.enable', 'The SPEC-01 sounds, everywhere.'},
		{'segmented', 'Channel', 'sound.channel', items = {{'Master', 'Master'}, {'SFX', 'Effects'}, {'Dialog', 'Dialog'}, {'Ambience', 'Ambient'}},
			note = 'Master plays even with game effects turned down. For quieter SPEC-01 sounds, pick a channel and lower its volume in the game\'s sound settings.'},
		{'switch', 'Controls', 'sound.widgets', 'Switches, keys and ticks on SPEC-01 controls.'},
		{'switch', 'Interface', 'sound.interface', 'Windows, menus, tabs and checkboxes across the game, as set below.'},
		{'switch', 'Action keys', 'sound.actionbars', 'A press and release for every action.'},
		{'switch', 'Chat typing', 'sound.chat', 'A key click for each character typed.'},
	}},
	{title = 'Game sounds', rows = kindRows},
	{title = 'Test', rows = testRows},
	{title = 'Audition', rows = {
		{'note', 'The fifteen reference voices, each recorded in three takes that vary a little, like the original.'},
		{'button', 'Key press', 'Down', function() Kit:Play('down', true) end},
		{'button', 'Primary key', 'Primary', function() Kit:Play('down-primary', true) end},
		{'button', 'Latch', 'Latch', function() Kit:Play('latch-down', true) end},
		{'button', 'Detent', 'Tick', function() Kit:Play('tick', true) end},
		{'button', 'Screen', 'Blip', function() Kit:Play('blip', true) end},
		{'button', 'Pop-up', 'Open', function() Kit:Play('open', true) end},
		{'button', 'Outcomes', 'Success', function() Kit:Play('success', true) end},
		{'button', 'Error', 'Error', function() Kit:Play('error', true) end},
		{'button', 'Diagnostics', 'Test', function() Kit:SoundReport() end, 'Prints what the client did with a test sound.'},
	}},
}})

local function Preview(kind)
	return function()
		if UI.Notifications then UI.Notifications.Preview(kind) end
	end
end

UI:RegisterPage('notifications', {title = 'Notifications', order = 21, cards = {
	{title = 'Toasts', rows = {
		{'switch', 'Notifications', 'toasts.enable', 'Toasts and banners. Toasts are small LCD cards at the top of the screen.'},
		{'slider', 'Time on screen', 'toasts.duration', 2, 15, 1, nil, format = function(v) return v..' s' end},
		{'switch', 'New mail', 'toasts.mail'},
		{'switch', 'Ready checks', 'toasts.readyCheck'},
		{'switch', 'Low durability', 'toasts.durability'},
		{'button', 'Preview', 'Send test', function() Kit:Toast({title = 'Project saved', text = 'This is what a notification looks like.', tone = 'success', action = {text = 'Undo'}}) end},
	}},
	{title = 'Banners', rows = {
		{'note', 'One device near the top of the screen, one banner at a time. Banners wait for a fight or a cinematic to end; quests during a fight become toasts.'},
		{'switch', 'Level up', 'toasts.levelUp', 'LCD digits run up to the new level, with what you gained.'},
		{'switch', 'Quest complete', 'toasts.questComplete', 'The quest and its rewards.'},
		{'switch', 'Quest accepted', 'toasts.questAccept'},
		{'switch', 'Achievements', 'toasts.achievement', 'Replaces the game\'s achievement alert.'},
		{'switch', 'Zone names', 'toasts.zone', 'Replaces the game\'s zone text.'},
		{'switch', 'Reputation', 'toasts.reputation', 'Gains add up per faction, with a standing meter.'},
		{'button', 'Level up', 'Preview', Preview('levelup')},
		{'button', 'Quest complete', 'Preview', Preview('quest')},
		{'button', 'Achievement', 'Preview', Preview('achievement')},
		{'button', 'Zone', 'Preview', Preview('zone')},
		{'button', 'Reputation', 'Preview', Preview('rep')},
	}},
	{title = 'Loot', rows = {
		{'segmented', 'Style', 'style.loot', items = {{'device', 'Device'}, {'blizzard', 'Blizzard'}}, reload = true,
			note = 'Loot window, rolls, loot feed, banners and alert frames.'},
		{'switch', 'Loot window', 'loot.window', 'Opens at the cursor when Loot Under Mouse is on.', reload = true},
		{'switch', 'Loot rolls', 'loot.rolls', 'Need, greed, disenchant, transmog and pass keys with a timer.', reload = true},
		{'switch', 'Loot feed', 'loot.feed', 'What you pick up slides in beside the screen edge. Place it with /spec move.'},
		{'switch', 'Currency in the feed', 'toasts.currency'},
		{'button', 'Loot window', 'Preview', Preview('loot')},
		{'button', 'Loot roll', 'Preview', Preview('roll')},
		{'button', 'Loot feed', 'Preview', Preview('feed')},
	}},
	{title = 'Status badges', rows = {
		{'switch', 'Status badges', 'status.enable', 'Ready or combat, resting, AFK, mail, repair.'},
		{'slider', 'Height', 'status.y', 0, 800, 10, 'Distance above the bottom of the screen.'},
	}},
}})
