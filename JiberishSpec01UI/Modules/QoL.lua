-- Quality of life, in the SPEC-01 language: a cursor ring, quieter errors,
-- faster looting, gossip and quest shortcuts, the delete confirmation filled
-- in, a longer camera, combat text in the reference's typeface, an interrupt
-- call-out, achievement screenshots and a flash when a quest is ready to hand
-- in. Every feature has its own switch. The away screen is Modules/Away.lua
-- (its settings stay here, under qol.afk*).
--
-- Nothing here hooks a Blizzard method or writes onto its frames, except two
-- documented spots: quieted error types go into the game's own
-- BLACK_LISTED_MESSAGE_TYPES table (and only the ones this added are ever
-- removed again, by setting them back to nil), and the delete popup's edit box
-- is given its text the way a player typing would.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, GetTime, InCombatLockdown = CreateFrame, UIParent, GetTime, InCombatLockdown
local max = math.max
local format, find = string.format, string.find

-- defaults:begin
UI:RegisterDefaults('qol', {
	cursorRing = false, cursorCombat = true, cursorSize = 40,
	quietErrors = true, errorSound = true,
	fastLoot = true,
	gossipSkip = false, autoQuest = false, gossipExclude = '',
	deleteFill = true,
	cameraMax = true, cameraFactor = 2.6,
	combatFont = true, incomingText = false, outgoingText = 'off', outgoingSize = 26,
	interrupt = 'off',
	achieveShot = false,
	questFlash = true,
})
-- defaults:end

local module = UI:RegisterModule('qol', {always = true})
local function DB() return UI.db.qol end
local function IsSecret(value) return issecretvalue and issecretvalue(value) end
-- A call's first result, or nil when it fails or the answer is secret.
local function Plain(func, ...)
	if type(func) ~= 'function' then return nil end
	local ok, value = pcall(func, ...)
	if not ok or IsSecret(value) then return nil end
	return value
end
local function Forbidden(object) return not object or (object.IsForbidden and object:IsForbidden()) end

local events = CreateFrame('Frame')
local handlers = {}
local function On(event, handler)
	if not handlers[event] then
		handlers[event] = {}
		pcall(events.RegisterEvent, events, event)
	end
	table.insert(handlers[event], handler)
end
events:SetScript('OnEvent', function(_, event, ...)
	for _, handler in ipairs(handlers[event] or {}) do UI:Safe(handler, event, ...) end
end)

-- Cursor ring ---------------------------------------------------------------------
local ring
local function BuildRing()
	ring = CreateFrame('Frame', nil, UIParent)
	ring:SetFrameStrata('TOOLTIP')
	ring:EnableMouse(false)
	ring.outer = Kit:Texture(ring, 'circle-ring', 'OVERLAY')
	ring.outer:SetAllPoints()
	Kit:Tint(ring.outer, 'lamp', 0.85)
	ring.dot = Kit:Texture(ring, 'circle', 'OVERLAY', 1)
	ring.dot:SetSize(4, 4)
	ring.dot:SetPoint('CENTER')
	Kit:Tint(ring.dot, 'lamp', 0.9)
	ring:SetScript('OnUpdate', function(self)
		local scale = UIParent:GetEffectiveScale()
		local x, y = GetCursorPosition()
		self:ClearAllPoints()
		self:SetPoint('CENTER', UIParent, 'BOTTOMLEFT', x / scale, y / scale)
	end)
	ring:Hide()
end

local inFight = false
local function UpdateRing()
	local db = DB()
	local wanted = db.cursorRing and (not db.cursorCombat or inFight)
	if not wanted then
		if ring then ring:Hide() end
		return
	end
	if not ring then BuildRing() end
	ring:SetSize(db.cursorSize or 40, db.cursorSize or 40)
	Kit:Tint(ring.outer, 'lamp', 0.85)
	Kit:Tint(ring.dot, 'lamp', 0.9)
	if not ring:IsShown() then
		ring:SetAlpha(0)
		ring:Show()
		Kit:FadeTo(ring, 1, 'FAST')
	end
end
-- The event says a fight has started before lockdown does.
On('PLAYER_REGEN_DISABLED', function() inFight = true; UpdateRing() end)
On('PLAYER_REGEN_ENABLED', function() inFight = false; UpdateRing() end)

-- Quiet errors ------------------------------------------------------------------------
-- By message type, so the (possibly secret) text is never read and it works
-- in every language. Types this client doesn't have are skipped.
local QUIET = {
	-- Not enough of a resource.
	'OUT_OF_MANA', 'OUT_OF_RAGE', 'OUT_OF_ENERGY', 'OUT_OF_FOCUS', 'OUT_OF_RUNIC_POWER', 'OUT_OF_RUNES',
	'OUT_OF_HOLY_POWER', 'OUT_OF_SOUL_SHARDS', 'OUT_OF_CHI', 'OUT_OF_COMBO_POINTS', 'OUT_OF_ARCANE_CHARGES',
	'OUT_OF_LUNAR_POWER', 'OUT_OF_INSANITY', 'OUT_OF_FURY', 'OUT_OF_PAIN', 'OUT_OF_MAELSTROM', 'OUT_OF_ESSENCE',
	'OUT_OF_POWER_DISPLAY', 'SPELL_FAILED_NO_COMBO_POINTS',
	-- Not ready yet.
	'ABILITY_COOLDOWN', 'SPELL_COOLDOWN', 'ITEM_COOLDOWN', 'SPELL_FAILED_NOT_READY', 'SPELL_FAILED_SPELL_IN_PROGRESS',
	'SPELL_FAILED_ANOTHER_IN_PROGRESS',
	-- Range and facing.
	'OUT_OF_RANGE', 'SPELL_OUT_OF_RANGE', 'SPELL_FAILED_OUT_OF_RANGE', 'BADATTACKPOS', 'BADATTACKFACING',
	'SPELL_FAILED_UNIT_NOT_INFRONT', 'SPELL_FAILED_NOT_INFRONT', 'SPELL_FAILED_NOT_BEHIND',
	-- No target, or the wrong one.
	'GENERIC_NO_TARGET', 'NO_ATTACK_TARGET', 'INVALID_ATTACK_TARGET', 'SPELL_FAILED_BAD_TARGETS',
	'SPELL_FAILED_BAD_IMPLICIT_TARGETS', 'SPELL_FAILED_TARGETS_DEAD',
}
local quietIds, written = {}, {}
for _, name in ipairs(QUIET) do
	local id = _G['LE_GAME_ERR_'..name]
	if type(id) == 'number' then quietIds[id] = true end
end

local function SyncErrors()
	local list = _G.BLACK_LISTED_MESSAGE_TYPES
	if type(list) ~= 'table' then return end
	local on = DB().quietErrors
	for id in pairs(quietIds) do
		if on and list[id] == nil then
			list[id] = true
			written[id] = true
		elseif not on and written[id] then
			-- Removed, never set to false: a value of ours would make the game's
			-- handler run tainted for that message.
			list[id] = nil
			written[id] = nil
		end
	end
end

local lastTick
On('UI_ERROR_MESSAGE', function(_, errorType)
	local db = DB()
	if not (db.quietErrors and db.errorSound) or IsSecret(errorType) or not quietIds[errorType] then return end
	if not written[errorType] then return end
	local now = GetTime()
	if lastTick and now - lastTick < 0.4 then return end
	lastTick = now
	Kit:Play('tick')
end)

-- Faster looting --------------------------------------------------------------------
local function AutoLootApplies()
	local get = (C_CVar and C_CVar.GetCVarBool) or GetCVarBool
	local on = get and get('autoLootDefault') and true or false
	local toggled = IsModifiedClick and IsModifiedClick('AUTOLOOTTOGGLE') and true or false
	return on ~= toggled
end
local lastLoot
On('LOOT_READY', function()
	if not DB().fastLoot or not AutoLootApplies() then return end
	local now = GetTime()
	if lastLoot and now - lastLoot < 0.3 then return end
	lastLoot = now
	local count = Plain(GetNumLootItems)
	if type(count) ~= 'number' then return end
	for slot = count, 1, -1 do LootSlot(slot) end
end)

-- Gossip and quests ----------------------------------------------------------------
-- Held off while Shift is down, so any NPC can still be read. Per visit to an
-- NPC: at most one gossip option is picked for you (a menu that leads back to
-- itself can't loop) and at most a few quests. NPCs on the exclusion list
-- (their ids, comma separated) are always left to you.
local visit = {} -- {guid, option = true, quests = n}
local MAX_QUESTS = 8

local function NpcID()
	local guid = UnitGUID('npc')
	if not guid or IsSecret(guid) then return nil, nil end
	local id = select(6, strsplit('-', guid))
	return tonumber(id), guid
end

local function Excluded(id)
	if not id then return false end
	for entry in tostring(DB().gossipExclude or ''):gmatch('%d+') do
		if tonumber(entry) == id then return true end
	end
	return false
end

-- Whether the NPC in front of us may be handled for us at all, starting a new
-- visit when it's a different NPC.
local function Skipping()
	if IsShiftKeyDown() then return false end
	local id, guid = NpcID()
	if not guid then return false end
	if visit.guid ~= guid then visit = {guid = guid, quests = 0} end
	return not Excluded(id)
end
local function TakeQuestTurn()
	if visit.quests >= MAX_QUESTS then return false end
	visit.quests = visit.quests + 1
	return true
end
On('GOSSIP_CLOSED', function() visit = {} end)
-- Quest-only NPCs never close a gossip window; their visit lasts until the next NPC.

-- Only a plain, ordinary option is ever picked: available, with no special
-- flags, nothing to pay, no spell and not marked as starting something.
local function SafeOption(option)
	if type(option) ~= 'table' then return false end
	local id, status, flags = option.gossipOptionID, option.status, option.flags
	if IsSecret(id) or IsSecret(status) or IsSecret(flags) or IsSecret(option.name) then return false end
	if type(id) ~= 'number' then return false end
	local available = Enum and Enum.GossipOptionStatus and Enum.GossipOptionStatus.Available or 0
	if status ~= nil and status ~= available then return false end
	if flags ~= nil and flags ~= 0 then return false end
	if (option.spellID and option.spellID ~= 0) or (option.cost and option.cost ~= 0) or option.overrideIconID then return false end
	if type(option.rewards) == 'table' and #option.rewards > 0 then return false end
	local name = type(option.name) == 'string' and option.name or ''
	-- Paid teleports and encounter starters show a coin, an icon or <...> text.
	if find(name, '|T', 1, true) or find(name, '|A', 1, true) or find(name, '<', 1, true) or find(name, 'Gold', 1, true) then return false end
	return true
end

On('GOSSIP_SHOW', function()
	local db = DB()
	if not (db.autoQuest or db.gossipSkip) or not C_GossipInfo or not Skipping() then return end
	if db.autoQuest then
		for _, quest in ipairs(C_GossipInfo.GetActiveQuests and C_GossipInfo.GetActiveQuests() or {}) do
			if not IsSecret(quest.isComplete) and quest.isComplete and not IsSecret(quest.questID) and TakeQuestTurn() then
				return C_GossipInfo.SelectActiveQuest(quest.questID)
			end
		end
		for _, quest in ipairs(C_GossipInfo.GetAvailableQuests and C_GossipInfo.GetAvailableQuests() or {}) do
			if not IsSecret(quest.questID) and TakeQuestTurn() then return C_GossipInfo.SelectAvailableQuest(quest.questID) end
		end
	end
	if db.gossipSkip and not visit.option then
		local options = C_GossipInfo.GetOptions and C_GossipInfo.GetOptions() or {}
		local active = C_GossipInfo.GetNumActiveQuests and C_GossipInfo.GetNumActiveQuests() or 0
		local available = C_GossipInfo.GetNumAvailableQuests and C_GossipInfo.GetNumAvailableQuests() or 0
		if #options == 1 and active == 0 and available == 0 and SafeOption(options[1]) then
			visit.option = true
			C_GossipInfo.SelectOption(options[1].gossipOptionID)
		end
	end
end)

On('QUEST_GREETING', function()
	if not (DB().autoQuest and Skipping()) then return end
	for index = 1, (GetNumActiveQuests and GetNumActiveQuests() or 0) do
		local _, complete = GetActiveTitle(index)
		if not IsSecret(complete) and complete and TakeQuestTurn() then return SelectActiveQuest(index) end
	end
	if (GetNumAvailableQuests and GetNumAvailableQuests() or 0) > 0 and TakeQuestTurn() then SelectAvailableQuest(1) end
end)
On('QUEST_DETAIL', function()
	if DB().autoQuest and Skipping() then AcceptQuest() end
end)

-- A quest that takes money or items is always handed in by you.
local function Costs()
	local money = Plain(GetQuestMoneyToGet)
	local items = Plain(GetNumQuestItems)
	if money == nil or items == nil then return true end
	return money > 0 or items > 0
end
On('QUEST_PROGRESS', function()
	if DB().autoQuest and Skipping() and not Costs() and IsQuestCompletable() then CompleteQuest() end
end)
On('QUEST_COMPLETE', function()
	if not (DB().autoQuest and Skipping()) or Costs() then return end
	-- With a choice of rewards, the choice stays the player's.
	local choices = GetNumQuestChoices and GetNumQuestChoices() or 0
	if choices <= 1 then GetQuestReward(choices == 1 and 1 or nil) end
end)

-- Delete confirmation --------------------------------------------------------------
On('DELETE_ITEM_CONFIRM', function()
	if not DB().deleteFill then return end
	C_Timer.After(0, function()
		for _, which in ipairs({'DELETE_GOOD_ITEM', 'DELETE_GOOD_QUEST_ITEM'}) do
			local popup = StaticPopup_FindVisible and StaticPopup_FindVisible(which)
			if popup and not Forbidden(popup) then
				local box = (popup.GetEditBox and popup:GetEditBox()) or popup.editBox or popup.EditBox
					or (popup.GetName and popup:GetName() and _G[popup:GetName()..'EditBox'])
				if box and box.SetText then box:SetText(DELETE_ITEM_CONFIRM_STRING or 'DELETE') end
			end
		end
	end)
end)

-- Camera --------------------------------------------------------------------------
local function ApplyCamera()
	if not DB().cameraMax then return end
	if InCombatLockdown() then return UI:AfterCombat(ApplyCamera, 'qol.camera') end
	pcall(SetCVar, 'cameraDistanceMaxZoomFactor', tostring(DB().cameraFactor or 2.6))
end

-- Combat text ----------------------------------------------------------------------
-- The game reads DAMAGE_TEXT_FONT for numbers over targets when the world
-- loads, so a change shows after a relog; its own scrolling text uses
-- CombatTextFont, which changes at once.
local function ApplyCombatFont()
	if not DB().combatFont then return end
	_G.DAMAGE_TEXT_FONT = Kit:FontPath(true)
	local font = _G.CombatTextFont
	if font and font.SetFont then
		local _, size = font:GetFont()
		font:SetFont(Kit:FontPath(true), size or 24, 'OUTLINE')
	end
end

-- Our own incoming text: damage and heals taken, rising from left of centre in
-- the reference's type. Amounts can be secret, so they only ever go to SetText.
local floaters, nextFloater = {}, 1
local function Floater()
	local text = floaters[nextFloater]
	if not text then
		local holder = CreateFrame('Frame', nil, UIParent)
		holder:SetSize(200, 20)
		holder:SetFrameStrata('HIGH')
		holder.text = Kit:Text(holder, '', 'head', 'white', true, true)
		holder.text:SetPoint('CENTER')
		floaters[nextFloater] = holder
		text = holder
	end
	nextFloater = nextFloater % 8 + 1
	return text
end

local ACTION_TOKENS = {WOUND = 'red', HEAL = 'green', BLOCK = 'dim', DODGE = 'dim', PARRY = 'dim', MISS = 'dim', IMMUNE = 'dim',
	ABSORB = 'blue', RESIST = 'dim', EVADE = 'dim', DEFLECT = 'dim', REFLECT = 'blue'}
On('UNIT_COMBAT', function(_, unit, action, _, amount)
	if not DB().incomingText or IsSecret(unit) or unit ~= 'player' then return end
	local holder = Floater()
	local plainAction = not IsSecret(action) and action or nil
	local token = plainAction and ACTION_TOKENS[plainAction] or 'white'
	Kit:Tint(holder.text, token == 'white' and 'darkInk' or token)
	if plainAction and plainAction ~= 'WOUND' and plainAction ~= 'HEAL' then
		holder.text:SetText(_G[plainAction] or plainAction)
	elseif IsSecret(amount) or amount ~= nil then
		if plainAction == 'HEAL' then holder.text:SetFormattedText('+%s', amount)
		else holder.text:SetFormattedText('-%s', amount) end
	else
		return
	end
	local x = -240 + math.random(-24, 24)
	holder:Show()
	Kit:Animate(holder, 1.1, 0, 1, function(progress)
		holder:ClearAllPoints()
		holder:SetPoint('CENTER', UIParent, 'CENTER', x, -40 + 70 * Kit.ease.cubic(progress))
		holder:SetAlpha(progress < 0.7 and 1 or 1 - Kit.ease.sine((progress - 0.7) / 0.3))
	end, function() holder:Hide() end, 'linear')
end)

-- Big numbers on your target: what it takes pops over its nameplate (or the
-- screen centre) in bold Plex, overshoots and settles, then rises and fades.
-- The combat log is closed to addons here, so this reads UNIT_COMBAT for the
-- target, which reports damage from anyone, not only you. Amounts may be secret
-- and only ever go to SetFormattedText; colors come from plain flags only.
local SCHOOL_COLORS = {[1] = {0.94, 0.94, 0.9}, [2] = {1, 0.86, 0.45}, [4] = {1, 0.42, 0.18}, [8] = {0.45, 0.85, 0.35},
	[16] = {0.5, 0.78, 1}, [32] = {0.72, 0.52, 1}, [64] = {1, 0.55, 0.95}}
local bigs, nextBig = {}, 1
local function BigFloater()
	local holder = bigs[nextBig]
	if not holder then
		holder = CreateFrame('Frame', nil, UIParent)
		holder:SetSize(240, 40)
		holder:SetFrameStrata('HIGH')
		holder.text = Kit:Text(holder, '', DB().outgoingSize or 26, 'white', true, true)
		holder.text:SetPoint('CENTER')
		holder:Hide()
		bigs[nextBig] = holder
	end
	nextBig = nextBig % 10 + 1
	return holder
end

local function TargetPlate()
	if not C_NamePlate or not C_NamePlate.GetNamePlateForUnit then return nil end
	local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, 'target')
	if ok and plate and not (plate.IsForbidden and plate:IsForbidden()) then return plate end
end

On('UNIT_COMBAT', function(_, unit, action, indicator, amount, school)
	local mode = DB().outgoingText
	if mode == 'off' or IsSecret(unit) or unit ~= 'target' then return end
	local plainAction = not IsSecret(action) and action or nil
	if plainAction and plainAction ~= 'WOUND' then return end
	if not IsSecret(amount) and amount == nil then return end
	local crit = not IsSecret(indicator) and indicator == 'CRITICAL'
	local holder = BigFloater()
	local size = (DB().outgoingSize or 26) * (crit and 1.25 or 1)
	Kit:Font(holder.text, size, 'OUTLINE', true)
	local color = not IsSecret(school) and SCHOOL_COLORS[school] or SCHOOL_COLORS[1]
	if crit then color = {1, 0.78, 0.2} end
	holder.text:SetTextColor(color[1], color[2], color[3])
	holder.text:SetFormattedText(crit and '%s!' or '%s', amount)
	local plate = mode == 'plate' and TargetPlate()
	local x = math.random(-30, 30)
	local function Place(rise)
		holder:ClearAllPoints()
		if plate then holder:SetPoint('BOTTOM', plate, 'TOP', x, 6 + rise)
		else holder:SetPoint('CENTER', UIParent, 'CENTER', x, 90 + rise) end
	end
	holder:SetScale(1)
	holder:SetAlpha(1)
	Place(0)
	holder:Show()
	local still = Kit:DB().reduceMotion
	Kit:Animate(holder, still and 0.9 or 1.1, 0, 1, function(progress)
		if not still then
			-- Pop: overshoot to 1.35 in the first 15%, settle to 1 by 30%.
			local scale = progress < 0.15 and 0.6 + 0.75 * Kit.ease.cubic(progress / 0.15)
				or progress < 0.3 and 1.35 - 0.35 * Kit.ease.sine((progress - 0.15) / 0.15) or 1
			holder:SetScale(max(scale, 0.01))
			Place(46 * Kit.ease.cubic(max(progress - 0.25, 0) / 0.75))
		end
		holder:SetAlpha(progress < 0.65 and 1 or 1 - Kit.ease.sine((progress - 0.65) / 0.35))
	end, function() holder:Hide() end, 'linear')
end)

-- Interrupt call-out ------------------------------------------------------------------
-- The combat log is closed to addons on these clients (registering it is a
-- forbidden action), so this listens to the cast events instead: when a cast
-- or channel stops, the game says who interrupted it. A cast seen through
-- several unit tokens (target, focus, a nameplate) is announced once. Anything
-- secret is skipped, and nothing is sent while chat is locked down.
local function Announce(text)
	if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and Plain(C_ChatInfo.InChatMessagingLockdown) then return end
	local channel = DB().interrupt
	if channel == 'party' then
		channel = (IsInGroup and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and 'INSTANCE_CHAT') or (IsInRaid and IsInRaid() and 'RAID')
			or (IsInGroup and IsInGroup() and 'PARTY') or nil
	elseif channel == 'say' then
		-- Saying something outdoors needs a key press; inside an instance it doesn't.
		channel = IsInInstance and IsInInstance() and 'SAY' or nil
	else
		channel = nil
	end
	if not channel then return end
	local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
	if send then pcall(send, text, channel) end
end

local announced = {}
local function Interrupted(unit, castGUID, spellID, interruptedBy)
	if DB().interrupt == 'off' then return end
	if IsSecret(unit) or IsSecret(castGUID) or IsSecret(spellID) or IsSecret(interruptedBy) then return end
	if type(interruptedBy) ~= 'string' or type(castGUID) ~= 'string' or announced[castGUID] then return end
	local me, pet = Plain(UnitGUID, 'player'), Plain(UnitGUID, 'pet')
	if interruptedBy ~= me and interruptedBy ~= pet then return end
	announced[castGUID] = true
	C_Timer.After(5, function() announced[castGUID] = nil end)
	local name = Plain(UnitName, unit)
	local link = spellID and ((C_Spell and C_Spell.GetSpellLink and Plain(C_Spell.GetSpellLink, spellID))
		or (GetSpellLink and Plain(GetSpellLink, spellID)))
	Announce(format('Interrupted %s: %s', name or '?', link or tostring(spellID or '?')))
end

-- UNIT_SPELLCAST_INTERRUPTED: unit, castGUID, spellID, interruptedBy, castID.
-- UNIT_SPELLCAST_CHANNEL_STOP: unit, castGUID, spellID, interruptedBy.
On('UNIT_SPELLCAST_INTERRUPTED', function(_, unit, castGUID, spellID, interruptedBy)
	Interrupted(unit, castGUID, spellID, interruptedBy)
end)
On('UNIT_SPELLCAST_CHANNEL_STOP', function(_, unit, castGUID, spellID, interruptedBy)
	Interrupted(unit, castGUID, spellID, interruptedBy)
end)

-- Achievement screenshots --------------------------------------------------------------
On('ACHIEVEMENT_EARNED', function()
	if DB().achieveShot and Screenshot then C_Timer.After(1.2, Screenshot) end
end)

-- Quest ready flash ------------------------------------------------------------------
-- When a quest in the log becomes ready to hand in: a green light along the
-- screen's edges, a success sound and the game's own taskbar flash.
local ready, flash = {}, nil
local function Flash()
	if not flash then
		flash = CreateFrame('Frame', nil, UIParent)
		flash:SetAllPoints()
		flash:SetFrameStrata('BACKGROUND')
		flash:EnableMouse(false)
		local function Edge(point, relative, horizontal)
			local texture = flash:CreateTexture(nil, 'BACKGROUND')
			texture:SetColorTexture(1, 1, 1, 1)
			texture:SetPoint(point)
			texture:SetPoint(relative)
			local r, g, b = Kit:RGB('green')
			if horizontal then
				texture:SetHeight(90)
				local outer, inner = CreateColor(r, g, b, 0.55), CreateColor(r, g, b, 0)
				if point:find('TOP') then texture:SetGradient('VERTICAL', inner, outer) else texture:SetGradient('VERTICAL', outer, inner) end
			else
				texture:SetWidth(90)
				local outer, inner = CreateColor(r, g, b, 0.55), CreateColor(r, g, b, 0)
				if point:find('LEFT') then texture:SetGradient('HORIZONTAL', outer, inner) else texture:SetGradient('HORIZONTAL', inner, outer) end
			end
		end
		Edge('TOPLEFT', 'TOPRIGHT', true)
		Edge('BOTTOMLEFT', 'BOTTOMRIGHT', true)
		Edge('TOPLEFT', 'BOTTOMLEFT', false)
		Edge('TOPRIGHT', 'BOTTOMRIGHT', false)
	end
	flash:SetAlpha(0)
	flash:Show()
	Kit:Animate(flash, 1.2, 0, 1, function(progress)
		flash:SetAlpha(progress < 0.25 and Kit.ease.sine(progress / 0.25) or 1 - Kit.ease.sine((progress - 0.25) / 0.75))
	end, function() flash:Hide() end, 'linear')
	Kit:Play('success')
	if FlashClientIcon then FlashClientIcon() end
end

local scanning, primed
local function ScanQuests()
	scanning = nil
	if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo and C_QuestLog.IsComplete) then return end
	local fresh = false
	local seen = {}
	for index = 1, C_QuestLog.GetNumQuestLogEntries() do
		local info = C_QuestLog.GetInfo(index)
		local id = info and not info.isHeader and info.questID
		if id and not IsSecret(id) then
			local complete = Plain(C_QuestLog.IsComplete, id)
			if complete then
				seen[id] = true
				if not ready[id] and primed then fresh = true end
			end
		end
	end
	ready = seen
	primed = true
	if fresh and DB().questFlash then Flash() end
end
On('QUEST_LOG_UPDATE', function()
	if scanning then return end
	scanning = true
	C_Timer.After(0.2, ScanQuests)
end)

-- Module ----------------------------------------------------------------------------
function module:Enable()
	SyncErrors()
	ApplyCamera()
	ApplyCombatFont()
	UpdateRing()
end

function module:Refresh()
	SyncErrors()
	ApplyCamera()
	UpdateRing()
end

UI:RegisterPage('qol', {title = 'Quality of life', order = 22, cards = {
	{title = 'Away', rows = {
		{'switch', 'Away screen', 'qol.afk', 'A SPEC-01 standby console while you are away: your character on an open stage, time away, a log of what happened, volume and function keys.'},
		{'switch', 'Hide the interface', 'qol.afkHideUI', 'Only the away screen shows while you are away.'},
		{'switch', 'Turn the camera', 'qol.afkSpin', 'The camera circles slowly around you.'},
		{'button', 'Preview', 'Show', function() if UI.PreviewAway then UI:PreviewAway() end end, 'Back, Esc or a step puts it away. Also /spec afk.'},
		{'button', 'More settings', 'Open', function() UI:ToggleHub('away', true) end, 'The console log, sounds and the turning figure.', since = '0.5.2'},
	}},
	{title = 'Cursor', rows = {
		{'switch', 'Cursor ring', 'qol.cursorRing', 'A lit ring around the mouse cursor.'},
		{'switch', 'Only in combat', 'qol.cursorCombat'},
		{'slider', 'Ring size', 'qol.cursorSize', 24, 80, 2},
	}},
	{title = 'Errors and looting', rows = {
		{'switch', 'Quiet errors', 'qol.quietErrors', 'Hides "not ready", "out of range", "no target" and out-of-power messages and their voice lines.'},
		{'switch', 'Soft error tick', 'qol.errorSound', 'A quiet tick instead, at most every 0.4 s.'},
		{'switch', 'Faster looting', 'qol.fastLoot', 'With auto loot, takes everything at once.'},
		{'switch', 'Fill in DELETE', 'qol.deleteFill', 'The delete confirmation is typed for you; the click is still yours.'},
	}},
	{title = 'Quests and NPCs', rows = {
		{'switch', 'Skip single gossip', 'qol.gossipSkip', 'Picks an NPC\'s only option. Hold Shift to read it instead.'},
		{'switch', 'Auto quests', 'qol.autoQuest', 'Accepts and hands in quests; a choice of rewards, or a quest that takes money or items, stays yours. Hold Shift to stop it.'},
		{'input', 'Leave these NPCs alone', 'qol.gossipExclude', 'NPC ids, comma separated.'},
		{'switch', 'Ready-to-hand-in flash', 'qol.questFlash', 'A green light at the screen\'s edges when a quest is complete.'},
		{'switch', 'Achievement screenshots', 'qol.achieveShot'},
	}},
	{title = 'Combat', rows = {
		{'switch', 'Combat text typeface', 'qol.combatFont', 'Numbers over targets in IBM Plex Mono (after a relog).', reload = true},
		{'switch', 'Incoming text', 'qol.incomingText', 'Damage and heals you take, rising left of centre.'},
		{'segmented', 'Target numbers', 'qol.outgoingText', items = {{'off', 'Off'}, {'plate', 'Nameplate'}, {'center', 'Centre'}}, since = '0.5.0',
			note = 'Big bold numbers that pop over your target as it takes damage. The game keeps the combat log from addons, so these show what your target takes from anyone, not only you; turn the game\'s own floating combat text off if you only want these.'},
		{'slider', 'Target number size', 'qol.outgoingSize', 16, 40, 1, nil, since = '0.5.0', format = function(v) return format('%d', v) end,
			disabled = function() return DB().outgoingText == 'off' end},
		{'segmented', 'Interrupt call-out', 'qol.interrupt', items = {{'off', 'Off'}, {'party', 'Group'}, {'say', 'Say'}},
			note = 'Names the spell you interrupted. Say works inside instances only.'},
	}},
	{title = 'Camera', rows = {
		{'switch', 'Longer camera', 'qol.cameraMax', 'Zoom out further than the game allows by default.'},
		{'slider', 'Camera distance', 'qol.cameraFactor', 1, 2.6, 0.1, nil, format = function(value) return format('%.1fx', value) end},
	}},
}})
