-- The info panel: one or two slim SPEC-01 strips ("IP-1") of readout modules,
-- and the HD-1 HUD. Each module is one data text (time, system, gold,
-- durability, bag space, friends, guild, spec, coordinates, experience, item
-- level), built like the reference's hardware:
--   * a status LED (latency green/amber/red, friends and guild online,
--     durability and bag space running low),
--   * a printed small-caps legend (TIME, MS, FR, GLD, SPEC, POS) and a glyph,
--   * the value on an LCD over unlit "888" ghost segments,
--   * extras per module: a blinking clock colon, a segment graph of the frame
--     rate, detent dots for your specializations, a tick tape that runs as you
--     walk across the map.
-- Three styles: Console (a recessed LCD window per module), LCD strip (one long
-- LCD, modules split by hairline rules) and Minimal (no housing, just glass
-- text and lamps). Each module lifts a pixel under the mouse and has a tooltip
-- and a click action.
--
-- Cost: readouts update from events; one ticker drives the clock, frame rate
-- and HUD status (every second) and, only while a coordinates module is shown,
-- the coordinates (ten times a second with the tape, four without). Nothing
-- runs while the strips and HUD are hidden.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, GameTooltip = CreateFrame, UIParent, GameTooltip
local floor, max, min, abs, ceil = math.floor, math.max, math.min, math.abs, math.ceil

local module = UI:RegisterModule('infopanel', {})

-- defaults:begin
UI:RegisterDefaults('infopanel', {
	extra = false, slots = 6, width = 720, height = 22, labels = true, clock24 = true, clockLocal = true,
	main1 = 'time', main2 = 'system', main3 = 'friends', main4 = 'guild', main5 = 'spec', main6 = 'coords',
	main7 = 'none', main8 = 'none',
	extra1 = 'gold', extra2 = 'durability', extra3 = 'bags', extra4 = 'xp', extra5 = 'ilvl', extra6 = 'none',
	extra7 = 'none', extra8 = 'none',
	-- 'strips': the IP strips; 'hud': the HD-1 top-centre device instead; 'both'.
	layout = 'strips', hudKeys = true, hudXP = true, hudStatus = true,
	-- 'console' | 'lcd' | 'minimal'; legend: 'both' | 'text' | 'icon' | 'none'.
	style = 'console', legend = 'both', leds = true, ghost = true, graphs = true, tape = true, blink = true, lift = true,
})
-- defaults:end

local function DB() return UI.db.infopanel end
local function IsSecret(value) return issecretvalue and issecretvalue(value) end
local function Plain(value) if IsSecret(value) then return nil end return value end

local MAX_SLOTS, PAD, GAP = 8, 5, 4
local strips, sessionMoney = {}, nil

-- Tooltips -----------------------------------------------------------------------------
local function Owner(slot)
	local _, y = slot:GetCenter()
	local _, height = UIParent:GetSize()
	GameTooltip:SetOwner(slot, (not IsSecret(y) and y and y > height / 2) and 'ANCHOR_BOTTOM' or 'ANCHOR_TOP', 0, 0)
	GameTooltip:ClearLines()
end

local function Line(left, right, r, g, b)
	if right then GameTooltip:AddDoubleLine(left, right, 0.62, 0.62, 0.58, r or 0.94, g or 0.94, b or 0.9)
	else GameTooltip:AddLine(left, r or 0.94, g or 0.94, b or 0.9, true) end
end

local function Hint(text) GameTooltip:AddLine(text, 0.55, 0.55, 0.5) end

local function Call(name, ...)
	local func = _G[name]
	if type(func) == 'function' then return pcall(func, ...) end
end

-- Data texts -----------------------------------------------------------------------------
-- Each: label, events (or ticker = 'clock' | 'coords'), Value() -> text[, token],
-- Tooltip(), Click(slot, button).
local DATA, ORDER = {}, {'none', 'time', 'system', 'gold', 'durability', 'bags', 'friends', 'guild', 'spec', 'coords', 'xp', 'ilvl'}
local NAMES = {none = 'Empty', time = 'Time', system = 'FPS and latency', gold = 'Gold', durability = 'Durability', bags = 'Bag space',
	friends = 'Friends', guild = 'Guild', spec = 'Specialization', coords = 'Coordinates', xp = 'Experience', ilvl = 'Item level'}

DATA.none = {label = '', Value = function() return '' end}

-- mode: 'local', 'realm', or nil for the player's choice.
local function Clock(mode)
	local db = DB()
	if mode == nil then mode = db.clockLocal and 'local' or 'realm' end
	local hour, minute
	if mode == 'realm' then hour, minute = GetGameTime()
	else local now = date('*t'); hour, minute = now.hour, now.min end
	if db.clock24 then return format('%02d:%02d', hour, minute) end
	local suffix = hour >= 12 and 'PM' or 'AM'
	hour = hour % 12
	if hour == 0 then hour = 12 end
	return format('%d:%02d %s', hour, minute, suffix)
end

DATA.time = {label = 'Time', ticker = 'clock',
	Value = function() return Clock() end,
	Tooltip = function()
		Line(date('%A %d %B'))
		Line('Local time', Clock('local'))
		Line('Realm time', Clock('realm'))
		local invites = C_Calendar and C_Calendar.GetNumPendingInvites and Plain(C_Calendar.GetNumPendingInvites())
		if invites and invites > 0 then Line('Calendar invites', tostring(invites), 0.91, 0.63, 0.07) end
		Hint('Click: calendar. Right-click: clock and stopwatch.')
	end,
	Click = function(_, button)
		if button == 'RightButton' then
			if not _G.TimeManagerFrame and C_AddOns and C_AddOns.LoadAddOn then pcall(C_AddOns.LoadAddOn, 'Blizzard_TimeManager') end
			Call('TimeManager_Toggle')
		else
			Call('ToggleCalendar')
		end
	end}

local function Latency()
	local _, _, home, world = GetNetStats()
	return Plain(home) or 0, Plain(world) or 0
end

DATA.system = {label = 'Sys', ticker = 'clock',
	Value = function()
		local fps = Plain(GetFramerate()) or 0
		local _, world = Latency()
		return format('%d FPS  %d MS', floor(fps + 0.5), world), world > 250 and 'red' or world > 120 and 'amber' or nil
	end,
	Tooltip = function()
		local home, world = Latency()
		Line('Frame rate', format('%d', floor((Plain(GetFramerate()) or 0) + 0.5)))
		Line('Home latency', home..' ms')
		Line('World latency', world..' ms')
		-- The heaviest addons, out of combat only (measuring them is slow).
		if InCombatLockdown() or type(UpdateAddOnMemoryUsage) ~= 'function' or type(GetAddOnMemoryUsage) ~= 'function'
			or not (C_AddOns and C_AddOns.GetNumAddOns) then return end
		if not pcall(UpdateAddOnMemoryUsage) then return end
		local list, total = {}, 0
		for index = 1, Plain(C_AddOns.GetNumAddOns()) or 0 do
			local ok, memory = pcall(GetAddOnMemoryUsage, index)
			memory = ok and Plain(memory)
			if memory and memory > 0 then
				local name, title = C_AddOns.GetAddOnInfo(index)
				list[#list + 1] = {name = Plain(title) or Plain(name) or '?', memory = memory}
				total = total + memory
			end
		end
		table.sort(list, function(a, b) return a.memory > b.memory end)
		local function Size(kb) return kb >= 1024 and format('%.1f MB', kb / 1024) or format('%d KB', kb) end
		GameTooltip:AddLine(' ')
		Line('Addon memory', Size(total))
		for index = 1, min(8, #list) do
			local name = list[index].name
			if type(name) == 'string' then name = name:gsub('|c%x%x%x%x%x%x%x%x', ''):gsub('|r', '') end
			Line(name, Size(list[index].memory), 0.62, 0.62, 0.58)
		end
	end}

local function Money(copper)
	if GetMoneyString then return GetMoneyString(copper, true) end
	return format('%dg %ds %dc', floor(copper / 10000), floor(copper / 100) % 100, copper % 100)
end

DATA.gold = {label = 'Gold', events = {'PLAYER_MONEY', 'PLAYER_TRADE_MONEY', 'SEND_MAIL_MONEY_CHANGED', 'SEND_MAIL_COD_CHANGED'},
	Value = function()
		local money = Plain(GetMoney()) or 0
		return (BreakUpLargeNumbers and BreakUpLargeNumbers(floor(money / 10000)) or tostring(floor(money / 10000)))..'G'
	end,
	-- For the Number roll motion extra: the gold as a number, and how to print it.
	Number = function() return floor((Plain(GetMoney()) or 0) / 10000) end,
	Format = function(gold)
		gold = floor(gold + 0.5)
		return (BreakUpLargeNumbers and BreakUpLargeNumbers(gold) or tostring(gold))..'G'
	end,
	Tooltip = function()
		local money = Plain(GetMoney()) or 0
		Line('On this character', Money(money))
		if sessionMoney then
			local change = money - sessionMoney
			if change ~= 0 then
				local good = change > 0
				Line(good and 'Earned this session' or 'Spent this session', Money(abs(change)), good and 0.18 or 1, good and 0.62 or 0.23, good and 0.37 or 0.19)
			end
		end
		if C_Bank and C_Bank.FetchDepositedMoney and Enum and Enum.BankType and Enum.BankType.Account then
			local ok, warband = pcall(C_Bank.FetchDepositedMoney, Enum.BankType.Account)
			if ok and Plain(warband) and warband > 0 then Line('Warband bank', Money(warband)) end
		end
		Hint('Click: bags.')
	end,
	Click = function() Call('ToggleAllBags') end}

local DURABILITY_SLOTS = {{1, 'HEADSLOT'}, {3, 'SHOULDERSLOT'}, {5, 'CHESTSLOT'}, {9, 'WRISTSLOT'}, {10, 'HANDSSLOT'},
	{6, 'WAISTSLOT'}, {7, 'LEGSSLOT'}, {8, 'FEETSLOT'}, {16, 'MAINHANDSLOT'}, {17, 'SECONDARYHANDSLOT'}}

local function Durability(slot)
	local current, maximum = GetInventoryItemDurability(slot)
	current, maximum = Plain(current), Plain(maximum)
	if current and maximum and maximum > 0 then return current / maximum end
end

DATA.durability = {label = 'Dura', events = {'UPDATE_INVENTORY_DURABILITY', 'PLAYER_EQUIPMENT_CHANGED'},
	Value = function()
		local lowest
		for _, entry in ipairs(DURABILITY_SLOTS) do
			local value = Durability(entry[1])
			if value and (not lowest or value < lowest) then lowest = value end
		end
		if not lowest then return '--' end
		return format('%d%%', floor(lowest * 100 + 0.5)), lowest < 0.25 and 'red' or lowest < 0.5 and 'amber' or nil
	end,
	Tooltip = function()
		for _, entry in ipairs(DURABILITY_SLOTS) do
			local value = Durability(entry[1])
			if value then
				local r, g, b = 0.94, 0.94, 0.9
				if value < 0.25 then r, g, b = 1, 0.23, 0.19 elseif value < 0.5 then r, g, b = 0.91, 0.63, 0.07 end
				Line(_G[entry[2]] or entry[2], format('%d%%', floor(value * 100 + 0.5)), r, g, b)
			end
		end
		Hint('Click: character.')
	end,
	Click = function() Call('ToggleCharacter', 'PaperDollFrame') end}

local function BagSpace()
	local container = C_Container
	if not container then return 0, 0, 0, 0 end
	local free, total, reagentFree, reagentTotal = 0, 0, 0, 0
	for bag = 0, (NUM_BAG_SLOTS or 4) do
		local slots = Plain(container.GetContainerNumSlots(bag)) or 0
		local open, family = container.GetContainerNumFreeSlots(bag)
		open, family = Plain(open) or 0, Plain(family) or 0
		if family == 0 then free, total = free + open, total + slots end
	end
	local reagent = (NUM_BAG_SLOTS or 4) + 1
	if (NUM_TOTAL_EQUIPPED_BAG_SLOTS or 0) >= reagent then
		reagentTotal = Plain(container.GetContainerNumSlots(reagent)) or 0
		reagentFree = Plain((container.GetContainerNumFreeSlots(reagent))) or 0
	end
	return free, total, reagentFree, reagentTotal
end

DATA.bags = {label = 'Bags', events = {'BAG_UPDATE_DELAYED'},
	Value = function()
		local free, total = BagSpace()
		return format('%d/%d', free, total), total > 0 and free <= 2 and 'red' or total > 0 and free <= 8 and 'amber' or nil
	end,
	Tooltip = function()
		local free, total, reagentFree, reagentTotal = BagSpace()
		Line('Free slots', format('%d of %d', free, total))
		if reagentTotal > 0 then Line('Reagent bag', format('%d of %d', reagentFree, reagentTotal)) end
		Hint('Click: bags.')
	end,
	Click = function() Call('ToggleAllBags') end}

local function OnlineFriends()
	local online = 0
	if C_FriendList and C_FriendList.GetNumOnlineFriends then online = Plain(C_FriendList.GetNumOnlineFriends()) or 0 end
	local battleNet = 0
	if BNGetNumFriends then
		local _, count = BNGetNumFriends()
		battleNet = Plain(count) or 0
	end
	return online, battleNet
end

DATA.friends = {label = 'Friends', events = {'FRIENDLIST_UPDATE', 'BN_FRIEND_ACCOUNT_ONLINE', 'BN_FRIEND_ACCOUNT_OFFLINE', 'BN_CONNECTED',
	'BN_DISCONNECTED', 'BN_FRIEND_INFO_CHANGED'},
	Value = function()
		local online, battleNet = OnlineFriends()
		return tostring(online + battleNet)
	end,
	Tooltip = function()
		local online, battleNet = OnlineFriends()
		Line('Online', format('%d  (%d Battle.net)', online + battleNet, battleNet))
		local shown = 0
		if C_FriendList and C_FriendList.GetNumFriends then
			for index = 1, Plain(C_FriendList.GetNumFriends()) or 0 do
				local info = C_FriendList.GetFriendInfoByIndex(index)
				if info and info.connected and shown < 20 then
					shown = shown + 1
					Line(info.name or '?', format('%s %s', info.level or '', info.area or ''))
				end
			end
		end
		if C_BattleNet and C_BattleNet.GetFriendAccountInfo and BNGetNumFriends then
			for index = 1, Plain((BNGetNumFriends())) or 0 do
				local account = C_BattleNet.GetFriendAccountInfo(index)
				local game = account and account.gameAccountInfo
				if game and game.isOnline and shown < 20 then
					shown = shown + 1
					Line(account.accountName or '?', game.characterName or game.clientProgram or '', 0.29, 0.64, 1)
				end
			end
		end
		Hint('Click: friends.')
	end,
	Click = function() Call('ToggleFriendsFrame', 1) end}

DATA.guild = {label = 'Guild', events = {'GUILD_ROSTER_UPDATE', 'PLAYER_GUILD_UPDATE'},
	Value = function()
		if not IsInGuild() then return '--' end
		local _, online = GetNumGuildMembers()
		return tostring(Plain(online) or 0)
	end,
	Tooltip = function()
		if not IsInGuild() then Line('Not in a guild') return end
		if C_GuildInfo and C_GuildInfo.GuildRoster then pcall(C_GuildInfo.GuildRoster) end
		local name, rank = GetGuildInfo('player')
		Line(name or 'Guild', rank)
		local total, online = GetNumGuildMembers()
		total, online = Plain(total) or 0, Plain(online) or 0
		Line('Online', format('%d of %d', online, total))
		local shown = 0
		for index = 1, total do
			local member, _, _, level, _, zone, _, _, isOnline, _, class = GetGuildRosterInfo(index)
			if isOnline and member and shown < 25 then
				shown = shown + 1
				local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
				GameTooltip:AddDoubleLine(Ambiguate and not IsSecret(member) and Ambiguate(member, 'guild') or member,
					format('%s %s', level or '', zone or ''), color and color.r or 0.94, color and color.g or 0.94, color and color.b or 0.9,
					0.62, 0.62, 0.58)
			end
		end
		Hint('Click: guild.')
	end,
	Click = function() Call('ToggleGuildFrame') end}

-- C_SpecializationInfo first, the old globals where only they exist.
local function SpecAPI(name)
	local func = C_SpecializationInfo and C_SpecializationInfo[name]
	if type(func) ~= 'function' then func = _G[name] end
	return type(func) == 'function' and func or nil
end

local function CurrentSpec()
	local get = SpecAPI('GetSpecialization')
	if not get then return nil end
	local ok, index = pcall(get)
	return ok and Plain(index) or nil
end

local function SpecInfo(index)
	local get = SpecAPI('GetSpecializationInfo')
	if not index or not get then return nil end
	local ok, id, name, _, icon = pcall(get, index)
	if not ok then return nil end
	return id, name, icon
end

local function SpecCount()
	local get = SpecAPI('GetNumSpecializations')
	local ok, count = pcall(get or function() return 0 end)
	return ok and Plain(count) or 0
end

local function SpecName(index)
	local _, name, icon = SpecInfo(index)
	return name, icon
end

local function LootSpecName()
	local loot = GetLootSpecialization and Plain(GetLootSpecialization()) or 0
	if loot == 0 then return 'Current spec' end
	if GetSpecializationInfoByID then
		local _, name = GetSpecializationInfoByID(loot)
		return name or '?'
	end
	return '?'
end

DATA.spec = {label = 'Spec', events = {'PLAYER_SPECIALIZATION_CHANGED', 'PLAYER_LOOT_SPEC_UPDATED', 'ACTIVE_TALENT_GROUP_CHANGED'},
	Value = function()
		local name = SpecName(CurrentSpec())
		return name and strupper(name) or '--'
	end,
	Tooltip = function()
		local name = SpecName(CurrentSpec())
		Line('Specialization', name or 'None')
		Line('Loot', LootSpecName())
		Hint('Click: change spec. Right-click: loot spec. Shift-click: talents.')
	end,
	Click = function(slot, button)
		if IsShiftKeyDown() then
			if PlayerSpellsUtil and PlayerSpellsUtil.ToggleClassTalentOrSpecFrame then pcall(PlayerSpellsUtil.ToggleClassTalentOrSpecFrame)
			else Call('ToggleTalentFrame') end
			return
		end
		if InCombatLockdown() then return UI:Print('Specializations can be changed once you leave combat.') end
		local count = SpecCount()
		local current = CurrentSpec()
		local items, values = {}, {}
		if button == 'RightButton' then
			local loot = GetLootSpecialization and Plain(GetLootSpecialization()) or 0
			items[1], values[1] = {text = 'Current spec', checked = loot == 0}, 0
			for index = 1, count do
				local id, specName = SpecInfo(index)
				items[#items + 1], values[#values + 1] = {text = specName or '?', checked = id ~= nil and loot == id}, id
			end
			Kit:Menu(slot, items, function(index)
				if SetLootSpecialization and values[index] then pcall(SetLootSpecialization, values[index]) end
			end, {width = 170})
		else
			for index = 1, count do
				local _, specName = SpecInfo(index)
				items[#items + 1] = {text = specName or '?', checked = index == current}
			end
			Kit:Menu(slot, items, function(index)
				if index == current or InCombatLockdown() then return end
				local set = SpecAPI('SetSpecialization')
				if set then pcall(set, index) end
			end, {width = 170})
		end
	end}

local function Position()
	if not (C_Map and C_Map.GetBestMapForUnit) then return end
	local map = C_Map.GetBestMapForUnit('player')
	local position = map and C_Map.GetPlayerMapPosition(map, 'player')
	if not position then return end
	local ok, x, y = pcall(position.GetXY, position)
	x, y = ok and Plain(x), ok and Plain(y)
	if x and y and (x > 0 or y > 0) then return x * 100, y * 100 end
end

DATA.coords = {label = 'Pos', ticker = 'coords', events = {'ZONE_CHANGED', 'ZONE_CHANGED_INDOORS', 'ZONE_CHANGED_NEW_AREA'},
	Value = function()
		local x, y = Position()
		if not x then return '--' end
		return format('%.1f %.1f', x, y)
	end,
	Tooltip = function()
		Line(GetZoneText and GetZoneText() or '', GetSubZoneText and GetSubZoneText() or '')
		local pvp = GetZonePVPInfo and GetZonePVPInfo()
		if pvp then Line('Zone', pvp) end
		local x, y = Position()
		if x then Line('Coordinates', format('%.2f, %.2f', x, y)) end
		Hint('Click: world map. Shift-click: put the coordinates in chat.')
	end,
	Click = function()
		if IsShiftKeyDown() then
			local x, y = Position()
			if not x then return end
			local zone = GetZoneText and Plain(GetZoneText()) or ''
			Call('ChatFrame_OpenChat', format('%s %.1f, %.1f', zone, x, y))
			return
		end
		Call('ToggleWorldMap')
	end}

local function Experience()
	local level = Plain(UnitLevel('player'))
	local cap = (GetMaxLevelForPlayerExpansion and GetMaxLevelForPlayerExpansion()) or MAX_PLAYER_LEVEL or level
	local current, total = Plain(UnitXP('player')), Plain(UnitXPMax('player'))
	if level and cap and level < cap and current and total and total > 0 and not (IsXPUserDisabled and IsXPUserDisabled()) then
		return 'xp', current, total, Plain(GetXPExhaustion and GetXPExhaustion())
	end
	local data = C_Reputation and C_Reputation.GetWatchedFactionData and C_Reputation.GetWatchedFactionData()
	if type(data) == 'table' and data.name then
		local low, high, value = Plain(data.currentReactionThreshold), Plain(data.nextReactionThreshold), Plain(data.currentStanding)
		if low and high and value and high > low then return 'rep', value - low, high - low, nil, data.name end
	end
end

DATA.xp = {label = 'XP', events = {'PLAYER_XP_UPDATE', 'UPDATE_EXHAUSTION', 'PLAYER_LEVEL_UP', 'UPDATE_FACTION', 'ENABLE_XP_GAIN', 'DISABLE_XP_GAIN'},
	Value = function()
		local kind, current, total = Experience()
		if not kind then return 'MAX' end
		if kind == 'rep' then return format('REP %.1f%%', current / total * 100) end
		return format('%.1f%%', current / total * 100)
	end,
	Tooltip = function()
		local kind, current, total, rested, faction = Experience()
		if not kind then Line('Maximum level') return end
		if kind == 'rep' then Line(faction) end
		Line(kind == 'rep' and 'Standing' or 'Experience', format('%s / %s', BreakUpLargeNumbers and BreakUpLargeNumbers(current) or current,
			BreakUpLargeNumbers and BreakUpLargeNumbers(total) or total))
		Line('To go', BreakUpLargeNumbers and BreakUpLargeNumbers(total - current) or tostring(total - current))
		if rested and rested > 0 then Line('Rested', format('%s (%.0f%%)', BreakUpLargeNumbers and BreakUpLargeNumbers(rested) or rested,
			rested / total * 100), 0.29, 0.64, 1) end
	end}

DATA.ilvl = {label = 'iLvl', events = {'PLAYER_EQUIPMENT_CHANGED', 'PLAYER_AVG_ITEM_LEVEL_UPDATE'},
	Value = function()
		if not GetAverageItemLevel then return '--' end
		local _, equipped = GetAverageItemLevel()
		equipped = Plain(equipped)
		return equipped and format('%.1f', equipped) or '--'
	end,
	Tooltip = function()
		if not GetAverageItemLevel then return end
		local overall, equipped = GetAverageItemLevel()
		Line('Equipped', format('%.1f', Plain(equipped) or 0))
		Line('Best owned', format('%.1f', Plain(overall) or 0))
		Hint('Click: character.')
	end,
	Click = function() Call('ToggleCharacter', 'PaperDollFrame') end}

-- Module dressing: legend, glyph and status lamp --------------------------------------
-- Glyphs: 'menu' names come from icons-menu.tga (the same order as MENU_ICONS in
-- tools/build-hardware-art.py), 'kit' names from Kit.icons.
local MENU_ICONS = {'character', 'spellbook', 'talents', 'professions', 'achievements', 'legacy', 'quest', 'guild',
	'social', 'finder', 'journal', 'collections', 'menu', 'help', 'store', 'house',
	'map', 'pvp', 'backpack', 'bag', 'reagent', 'key'}
local MENU_INDEX = {}
for index, name in ipairs(MENU_ICONS) do MENU_INDEX[name] = index - 1 end

local function LowestDurability()
	local lowest
	for _, entry in ipairs(DURABILITY_SLOTS) do
		local value = Durability(entry[1])
		if value and (not lowest or value < lowest) then lowest = value end
	end
	return lowest
end

-- Lamp(): a color token for the module's LED, 'key' for the key color, nil for off.
local DRESS = {
	time = {legend = 'TIME', icon = {'kit', 'calendar'}, Lamp = function()
		local invites = C_Calendar and C_Calendar.GetNumPendingInvites and Plain(C_Calendar.GetNumPendingInvites())
		return invites and invites > 0 and 'amber' or nil
	end},
	system = {legend = 'MS', icon = {'kit', 'power'}, Lamp = function()
		local _, world = Latency()
		return world > 250 and 'red' or world > 120 and 'amber' or 'ledGreen'
	end},
	gold = {legend = 'GOLD', icon = {'menu', 'store'}},
	durability = {legend = 'DUR', icon = {'menu', 'character'}, Lamp = function()
		local lowest = LowestDurability()
		if not lowest then return nil end
		return lowest < 0.25 and 'red' or lowest < 0.5 and 'amber' or 'ledGreen'
	end},
	bags = {legend = 'BAG', icon = {'menu', 'backpack'}, Lamp = function()
		local free, total = BagSpace()
		if total <= 0 then return nil end
		return free <= 2 and 'red' or free <= 8 and 'amber' or 'ledGreen'
	end},
	friends = {legend = 'FR', icon = {'menu', 'social'}, Lamp = function()
		local online, battleNet = OnlineFriends()
		return online + battleNet > 0 and 'ledGreen' or nil
	end},
	guild = {legend = 'GLD', icon = {'menu', 'guild'}, Lamp = function()
		if not IsInGuild() then return nil end
		local _, online = GetNumGuildMembers()
		online = Plain(online)
		return online and online > 1 and 'ledBlue' or nil
	end},
	spec = {legend = 'SPEC', icon = {'menu', 'talents'}, Lamp = function() return CurrentSpec() and 'key' or nil end},
	coords = {legend = 'POS', icon = {'menu', 'map'}, Lamp = function() return Position() and 'ledGreen' or nil end},
	xp = {legend = 'XP', icon = {'menu', 'achievements'}, Lamp = function()
		local kind, _, _, rested = Experience()
		if kind == 'xp' and rested and rested > 0 then return 'ledBlue' end
		return kind and 'key' or nil
	end},
	ilvl = {legend = 'ILV', icon = {'menu', 'character'}},
}

local function Style()
	local style = DB().style
	if style == 'lcd' or style == 'minimal' then return style end
	return 'console'
end

-- The ink tokens for a style: value, legend.
local function Inks()
	if Style() == 'minimal' then return 'darkInk', 'darkDim' end
	return 'lcdInk', 'lcdDim'
end

local function SetGlyph(texture, icon)
	if icon[1] == 'menu' then
		local index = MENU_INDEX[icon[2]] or 0
		local column, row = index % 8, floor(index / 8)
		texture:SetTexture(Kit.media..'icons-menu.tga')
		texture:SetTexCoord(column / 8, (column + 1) / 8, row / 4, (row + 1) / 4)
	else
		texture:SetTexture(Kit.media..'icons.tga')
		Kit:SetIcon(texture, icon[2])
	end
end

-- Unlit segments behind a readout: every letter and digit as an 8.
local function GhostOf(text)
	if type(text) ~= 'string' then return '' end
	return (text:gsub('[%w]', '8'))
end

-- Segment graph: the frame rate over the last few seconds --------------------------------
local GRAPH_COLUMNS, GRAPH_ROWS = 10, 4

local function BuildGraph(slot)
	local graph = slot.graph
	if graph.cells then return end
	graph.cells, graph.samples = {}, {}
	for column = 1, GRAPH_COLUMNS do
		graph.cells[column] = {}
		for row = 1, GRAPH_ROWS do
			local cell = graph:CreateTexture(nil, 'ARTWORK')
			cell:SetColorTexture(1, 1, 1, 1)
			cell:SetSize(2, 2)
			cell:SetPoint('BOTTOMLEFT', (column - 1) * 3, (row - 1) * 3)
			graph.cells[column][row] = cell
		end
	end
	graph:SetSize(GRAPH_COLUMNS * 3 - 1, GRAPH_ROWS * 3 - 1)
end

local function DrawGraph(slot, sample, token)
	local graph = slot.graph
	BuildGraph(slot)
	local samples = graph.samples
	if sample then
		samples[#samples + 1] = sample
		if #samples > GRAPH_COLUMNS then table.remove(samples, 1) end
	end
	local top = 60
	for _, value in ipairs(samples) do if value > top then top = value end end
	local ink = Inks()
	local offset = GRAPH_COLUMNS - #samples
	for column = 1, GRAPH_COLUMNS do
		local value = samples[column - offset]
		local lit = value and max(1, ceil(value / top * GRAPH_ROWS)) or 0
		for row = 1, GRAPH_ROWS do
			Kit:Tint(graph.cells[column][row], row <= lit and (token or ink) or ink, row <= lit and 1 or 0.18)
		end
	end
end

-- Tick tape: runs past as you walk east and west ------------------------------------------
local TAPE_STEP, TAPE_MAJOR = 4, 5

local function BuildTape(slot)
	local tape = slot.tape
	if tape.ticks then return end
	tape.strip = CreateFrame('Frame', nil, tape)
	tape.strip:SetSize(1, 4)
	tape.ticks = {}
	tape.caret = tape:CreateTexture(nil, 'OVERLAY', nil, 2)
	tape.caret:SetColorTexture(1, 1, 1, 1)
end

local function LayoutTape(slot)
	local tape = slot.tape
	BuildTape(slot)
	local px = UI.Pixel.Px(tape, 1)
	local width = max(tape:GetWidth(), 10)
	local count = floor(width / TAPE_STEP) + TAPE_MAJOR * 2 + 2
	for index = 1, count do
		local tick = tape.ticks[index]
		if not tick then
			tick = tape.strip:CreateTexture(nil, 'ARTWORK')
			tick:SetColorTexture(1, 1, 1, 1)
			tape.ticks[index] = tick
		end
		local major = (index - 1) % TAPE_MAJOR == 0
		tick:ClearAllPoints()
		tick:SetSize(px, major and 3 or 2)
		tick:SetPoint('BOTTOMLEFT', tape.strip, 'BOTTOMLEFT', (index - 1) * TAPE_STEP, 0)
		tick.major = major
		tick:Show()
	end
	for index = count + 1, #tape.ticks do tape.ticks[index]:Hide() end
	tape.caret:ClearAllPoints()
	tape.caret:SetSize(px, 4)
	tape.caret:SetPoint('BOTTOM', tape, 'BOTTOM', 0, 0)
	local ink, dim = Inks()
	for _, tick in ipairs(tape.ticks) do Kit:Tint(tick, tick.major and ink or dim, tick.major and 0.8 or 0.5) end
	Kit:Tint(tape.caret, 'lamp')
	tape.at = nil
end

local function MoveTape(slot, x)
	local tape = slot.tape
	if not tape.ticks then return end
	-- One map percent is two ticks; the strip wraps every major tick.
	local period = TAPE_STEP * TAPE_MAJOR
	local offset = -(((x or 0) * TAPE_STEP * 2) % period) - period
	local px = UI.Pixel.Px(tape, 1)
	offset = floor(offset / px + 0.5) * px
	if tape.at == offset then return end
	tape.at = offset
	tape.strip:ClearAllPoints()
	tape.strip:SetPoint('BOTTOMLEFT', tape, 'BOTTOMLEFT', offset, 0)
end

-- Spec detents: one dot per specialization, the active one lit ---------------------------
local function PaintDots(slot)
	local count = min(SpecCount(), 4)
	local current = CurrentSpec()
	for index = 1, 4 do
		local dot = slot.dots[index]
		if index <= count and slot.dotsShown then
			if not dot then
				dot = Kit:Texture(slot.inner, 'circle', 'OVERLAY', 1)
				dot:SetSize(3, 3)
				slot.dots[index] = dot
			end
			dot:ClearAllPoints()
			dot:SetPoint('LEFT', slot.dotAnchor, 'RIGHT', 5 + (index - 1) * 5, 0)
			Kit:Tint(dot, index == current and 'lamp' or 'ledOff')
			dot:Show()
		elseif dot then
			dot:Hide()
		end
	end
end

-- Slots ----------------------------------------------------------------------------------
local function Paint(slot, clockTick)
	local data = DATA[slot.key] or DATA.none
	local dress = DRESS[slot.key]
	local db = DB()
	local ok, text, token = pcall(data.Value)
	if not ok then text, token = '--', nil end
	if slot.key == 'time' and db.blink and type(text) == 'string' then
		-- The colon blinks once a second, on the clock's own tick.
		if clockTick then slot.colon = not slot.colon end
		if slot.colon then text = text:gsub(':', ' ') end
	end
	-- Motion extras: gold rolls to its new amount; other readouts print in when
	-- they change (not the clock, latency or coordinates, which tick constantly).
	local number = ok and data.Number and Kit.Roll and Kit:Alive('numberRoll') and data.Number()
	if number then
		Kit:Roll(slot.value, number, data.Format)
		text = data.Format(number)
	elseif Kit.PrintText and not data.ticker then Kit:PrintText(slot.value, text or '', {minGap = 1})
	else slot.value:SetText(text or '') end
	local ink = Inks()
	Kit:Tint(slot.value, token or ink)
	if slot.ghost:IsShown() then slot.ghost:SetText(GhostOf(text)) end
	-- The lamp.
	local lamp
	if dress and dress.Lamp then
		local lampOk, answer = pcall(dress.Lamp)
		if lampOk then lamp = answer end
	end
	if db.leds then Kit:SetLed(slot.led, lamp ~= nil, lamp ~= 'key' and lamp or nil) end
	if slot.graphShown and slot.key == 'system' then
		local fps = Plain(GetFramerate()) or 0
		-- The graph lights in the lamp's color once latency turns amber or red.
		DrawGraph(slot, clockTick and fps or nil, (lamp == 'amber' or lamp == 'red') and lamp or nil)
	end
	if slot.tapeShown and slot.key == 'coords' then MoveTape(slot, (Position())) end
	if slot.dotsShown then PaintDots(slot) end
end

local function Lift(slot, up)
	slot.inner:ClearAllPoints()
	slot.inner:SetPoint('TOPLEFT', 0, up and 1 or 0)
	slot.inner:SetPoint('BOTTOMRIGHT', 0, up and 1 or 0)
end

local function CreateSlot(strip, index)
	local slot = CreateFrame('Button', nil, strip)
	slot:RegisterForClicks('LeftButtonUp', 'RightButtonUp')
	slot.lcd = Kit:LCDPanel(slot, {radius = 3})
	slot.lcd:SetAllPoints()
	slot.lcd:EnableMouse(false)
	slot.inner = CreateFrame('Frame', nil, slot)
	slot.inner:SetFrameLevel(slot.lcd:GetFrameLevel() + 2)
	slot.inner:EnableMouse(false)
	Lift(slot, false)
	-- The rule sits on the module's own level, over the LCD strip's long screen.
	slot.rule = slot.inner:CreateTexture(nil, 'ARTWORK')
	slot.rule:SetColorTexture(1, 1, 1, 1)
	slot.led = Kit:Led(slot.inner, 4, false)
	slot.icon = slot.inner:CreateTexture(nil, 'OVERLAY')
	slot.label = Kit:Label(slot.inner, '', 'lcdDim', 7, true)
	slot.ghost = Kit:Text(slot.inner, '', 9, 'lcdGhost', true)
	slot.ghost:SetDrawLayer('ARTWORK')
	slot.ghost:SetJustifyH('RIGHT')
	slot.ghost:SetWordWrap(false)
	slot.value = Kit:Text(slot.inner, '', 9, 'lcdInk', true)
	slot.value:SetJustifyH('RIGHT')
	slot.value:SetWordWrap(false)
	slot.graph = CreateFrame('Frame', nil, slot.inner)
	slot.tape = CreateFrame('Frame', nil, slot.inner)
	slot.tape:SetClipsChildren(true)
	slot.dots = {}
	slot.index = index
	slot:SetScript('OnEnter', function(self)
		local data = DATA[self.key]
		local ink = Inks()
		Kit:Tint(self.label, ink)
		Kit:Tint(self.icon, ink)
		if DB().lift then Lift(self, true) end
		if not data or not data.Tooltip then return end
		Owner(self)
		GameTooltip:AddLine(strupper(NAMES[self.key] or ''), 0.94, 0.94, 0.9)
		UI:Safe(data.Tooltip, self)
		GameTooltip:Show()
	end)
	slot:SetScript('OnLeave', function(self)
		local _, dim = Inks()
		Kit:Tint(self.label, dim)
		Kit:Tint(self.icon, dim)
		Lift(self, false)
		GameTooltip:Hide()
	end)
	slot:SetScript('OnMouseDown', function(self) if DB().lift then Lift(self, false) end end)
	slot:SetScript('OnMouseUp', function(self) if DB().lift and self:IsMouseOver() then Lift(self, true) end end)
	slot:SetScript('OnClick', function(self, button)
		local data = DATA[self.key]
		if not data or not data.Click then return end
		Kit:Play('tick')
		UI:Safe(data.Click, self, button)
	end)
	return slot
end

-- Lay out one module: lamp, glyph, legend and extras on the left, the readout on
-- the right; on a tall strip (28+) the legend sits above the readout.
local function LayoutSlot(slot, width, height)
	local db, style = DB(), Style()
	local key = slot.key
	local dress = DRESS[key] or {}
	local ink, dim = Inks()
	local stacked = height >= 28
	slot.lcd:SetShown(style == 'console')
	-- Hairline rules between modules on the LCD strip and minimal styles.
	slot.rule:ClearAllPoints()
	slot.rule:SetShown(style ~= 'console' and slot.index > 1)
	slot.rule:SetPoint('TOP', slot, 'TOPLEFT', -GAP / 2, -4)
	slot.rule:SetPoint('BOTTOM', slot, 'BOTTOMLEFT', -GAP / 2, 4)
	slot.rule:SetWidth(UI.Pixel.Px(slot, 1))
	Kit:Tint(slot.rule, dim, 0.35)

	local legendMode = db.legend or 'both'
	local showText = (legendMode == 'both' or legendMode == 'text') and dress.legend ~= nil
	local showIcon = (legendMode == 'both' or legendMode == 'icon') and dress.icon ~= nil and (stacked or width >= 84)
	local size = stacked and 12 or max(9, floor(height * 0.42))
	-- With no housing behind it, text over the world gets an outline.
	local flags = style == 'minimal' and 'OUTLINE' or nil
	Kit:Font(slot.value, size, flags, true)
	Kit:Font(slot.ghost, size, nil, true)
	Kit:Font(slot.label, 7, flags, true)
	Kit:Tint(slot.ghost, 'lcdGhost')

	-- The left cluster.
	local anchorY = stacked and -5 or 0
	local anchorPoint = stacked and 'TOPLEFT' or 'LEFT'
	local x = 6
	local last
	Kit:ShowLed(slot.led, db.leds and true or false)
	if db.leds then
		slot.led:ClearAllPoints()
		slot.led:SetPoint(stacked and 'TOPLEFT' or 'LEFT', slot.inner, anchorPoint, x, stacked and anchorY - 1 or 0)
		x = x + 4 + 4
		last = slot.led
	end
	slot.icon:SetShown(showIcon)
	if showIcon then
		local iconSize = min(12, height - 8)
		SetGlyph(slot.icon, dress.icon)
		slot.icon:SetSize(iconSize, iconSize)
		slot.icon:ClearAllPoints()
		slot.icon:SetPoint(stacked and 'TOPLEFT' or 'LEFT', slot.inner, anchorPoint, x, stacked and anchorY + 2 or 0)
		Kit:Tint(slot.icon, dim)
		x = x + iconSize + 3
		last = slot.icon
	end
	slot.label:ClearAllPoints()
	slot.label:SetPoint(stacked and 'TOPLEFT' or 'LEFT', slot.inner, anchorPoint, x, anchorY)
	slot.label:SetText(showText and dress.legend or '')
	Kit:Tint(slot.label, dim)
	if showText then last = slot.label end

	-- The readout over its ghost segments.
	slot.value:ClearAllPoints()
	slot.ghost:ClearAllPoints()
	if stacked then
		slot.value:SetPoint('BOTTOMRIGHT', slot.inner, 'BOTTOMRIGHT', -6, 5)
	else
		slot.value:SetPoint('RIGHT', slot.inner, 'RIGHT', -6, key == 'coords' and db.tape and 1 or 0)
	end
	slot.ghost:SetPoint('RIGHT', slot.value, 'RIGHT', 0, 0)
	slot.ghost:SetShown(db.ghost and style ~= 'minimal' and Kit:Look('ghostDigits') and true or false)
	slot.ghost:SetText('')

	-- Extras.
	slot.graphShown = key == 'system' and db.graphs and (stacked and width >= 90 or width >= 124)
	slot.graph:SetShown(slot.graphShown and true or false)
	if slot.graphShown then
		BuildGraph(slot)
		slot.graph:ClearAllPoints()
		if stacked then slot.graph:SetPoint('BOTTOMLEFT', slot.inner, 'BOTTOMLEFT', 6, 6)
		else slot.graph:SetPoint('LEFT', last or slot.inner, last and 'RIGHT' or 'LEFT', 6, 0) end
		DrawGraph(slot)
	end
	slot.dotsShown = key == 'spec' and (stacked or width >= 96) and SpecCount() > 1
	slot.dotAnchor = last or slot.label
	slot.tapeShown = key == 'coords' and db.tape and true or false
	slot.tape:SetShown(slot.tapeShown)
	if slot.tapeShown then
		slot.tape:ClearAllPoints()
		slot.tape:SetPoint('BOTTOMLEFT', slot.inner, 'BOTTOMLEFT', 6, 2)
		slot.tape:SetPoint('BOTTOMRIGHT', slot.inner, 'BOTTOMRIGHT', -6, 2)
		slot.tape:SetHeight(4)
		LayoutTape(slot)
	end
end

local function CreateStrip(key, label, default)
	local strip = Kit:Device(UIParent, {header = false, radius = 8, width = DB().width, height = DB().height + PAD * 2})
	strip:SetFrameStrata('LOW')
	strip:SetFrameLevel(2)
	Kit:Relevel(strip)
	strip.key = key
	strip.lamp = Kit:Led(strip, 5, false)
	strip.lamp:SetPoint('LEFT', 9, 0)
	strip.model = Kit:Label(strip, 'IP-'..(key == 'main' and 1 or 2), 'ink', 8, true)
	strip.model:SetPoint('LEFT', strip.lamp, 'RIGHT', 5, 0)
	-- The LCD strip style: one long recessed screen behind every module.
	strip.screen = Kit:LCDPanel(strip, {radius = 4})
	strip.screen:SetFrameLevel(strip:GetFrameLevel() + 1)
	strip.screen:EnableMouse(false)
	strip.slots = {}
	for index = 1, MAX_SLOTS do strip.slots[index] = CreateSlot(strip, index) end
	strips[key] = strip
	UI:RegisterMover(strip, 'ip.'..key, label, default)
	return strip
end

local function LayoutStrip(strip)
	local db = DB()
	local shown = (strip.key == 'main' or db.extra) and db.layout ~= 'hud'
	strip:SetShown(shown)
	if not shown then return end
	local style = Style()
	local count = Kit:Clamp(floor(db.slots or 6), 1, MAX_SLOTS)
	strip:SetSize(db.width, db.height + PAD * 2)
	strip.shell:SetShown(style ~= 'minimal')
	strip.model:SetShown(style ~= 'minimal')
	local left = style == 'minimal' and 9 + 5 + 6 or 9 + 5 + 5 + (strip.model:GetStringWidth() or 24) + 8
	local width = (db.width - left - PAD - (count - 1) * GAP) / count
	strip.screen:SetShown(style == 'lcd')
	if style == 'lcd' then
		strip.screen:ClearAllPoints()
		strip.screen:SetPoint('TOPLEFT', strip, 'TOPLEFT', left - 2, -PAD + 1)
		strip.screen:SetPoint('BOTTOMRIGHT', strip, 'BOTTOMRIGHT', -PAD + 2, PAD - 1)
	end
	for index, slot in ipairs(strip.slots) do
		local key = db[strip.key..index] or 'none'
		if index > count then
			slot:Hide()
			slot.key = nil
		else
			slot.key = DATA[key] and key or 'none'
			slot:ClearAllPoints()
			slot:SetPoint('LEFT', strip, 'LEFT', left + (index - 1) * (width + GAP), 0)
			slot:SetSize(max(width, 10), db.height)
			slot:SetShown(slot.key ~= 'none')
			if slot.key ~= 'none' then
				UI:Safe(LayoutSlot, slot, max(width, 10), db.height)
				Paint(slot)
			end
		end
	end
end

-- HD-1: the top-centre HUD --------------------------------------------------------------
-- A big LCD clock with ghost digits and a blinking colon, a bank of small round
-- keys either side (the game's own panels, opened the way the micro menu opens
-- them), a status row of lamps and readouts (latency, frame rate, friends,
-- guild) and the experience or reputation as LED dots underneath.
local hud
local HUD_KEY, HUD_GAP, HUD_COLS = 18, 4, 3

local function Toggle(...)
	for index = 1, select('#', ...) do
		local name = select(index, ...)
		if type(name) == 'function' then
			if pcall(name) then return true end
		else
			local object = _G[name]
			if type(object) == 'function' then
				if pcall(object) then return true end
			elseif type(object) == 'table' and object.Click and not (object.IsForbidden and object:IsForbidden()) then
				if pcall(object.Click, object) then return true end
			end
		end
	end
end

-- legend, name, opener, protected (only out of combat).
local HUD_KEYS = {
	left = {
		{'CH', 'Character', function() return Toggle(function() ToggleCharacter('PaperDollFrame') end) end},
		{'SP', 'Spellbook', function()
			local util = _G.PlayerSpellsUtil
			return Toggle(util and util.ToggleSpellBookFrame or 'SpellbookMicroButton', 'PlayerSpellsMicroButton')
		end, true},
		{'TL', 'Talents', function()
			local util = _G.PlayerSpellsUtil
			return Toggle(util and util.ToggleClassTalentOrSpecFrame or 'TalentMicroButton', 'PlayerSpellsMicroButton')
		end, true},
		{'AC', 'Achievements', function() return Toggle('ToggleAchievementFrame', 'AchievementMicroButton') end},
		{'QL', 'Quest log', function() return Toggle('ToggleQuestLog', 'QuestLogMicroButton') end},
		{'GD', 'Guild and communities', function() return Toggle('ToggleGuildFrame', 'GuildMicroButton', 'SocialsMicroButton') end},
	},
	right = {
		{'LF', 'Group finder', function() return Toggle('LFDMicroButton', 'LFGMicroButton', 'PVEFrame_ToggleFrame') end},
		{'CO', 'Collections', function() return Toggle('ToggleCollectionsJournal', 'CollectionsMicroButton') end},
		{'MP', 'World map', function() return Toggle('ToggleWorldMap') end},
		{'BG', 'Bags', function() return Toggle('ToggleAllBags') end},
		{'CA', 'Calendar', function() return Toggle('ToggleCalendar') end},
		{'ME', 'Game menu', function() return Toggle('MainMenuMicroButton', 'ToggleGameMenu') end, true},
	},
}

-- The status row: legend, data key whose lamp lights it, and the readout.
local HUD_STATUS = {
	{'MS', 'system', function() local _, world = Latency(); return tostring(world) end},
	{'FPS', nil, function() return format('%d', floor((Plain(GetFramerate()) or 0) + 0.5)) end},
	{'FR', 'friends', function() local online, battleNet = OnlineFriends(); return tostring(online + battleNet) end},
	{'GLD', 'guild', function()
		if not IsInGuild() then return '--' end
		local _, online = GetNumGuildMembers()
		return tostring(Plain(online) or 0)
	end},
}

local function HudClock()
	local db = DB()
	local now = date('*t')
	local hour, minute = now.hour, now.min
	if not db.clockLocal then hour, minute = GetGameTime() end
	local suffix = ''
	if not db.clock24 then
		suffix = hour >= 12 and 'PM' or 'AM'
		hour = hour % 12
		if hour == 0 then hour = 12 end
	end
	return format('%02d:%02d', hour, minute), suffix
end

local function PaintHudClock(clockTick)
	if not hud or not hud:IsShown() then return end
	local digits, suffix = HudClock()
	if DB().blink then
		if clockTick then hud.colon = not hud.colon end
		if hud.colon then digits = digits:gsub(':', ' ') end
	end
	hud.digits:SetText(digits)
	hud.suffix:SetText(suffix)
end

local function PaintHudStatus()
	if not hud or not hud:IsShown() or not hud.status:IsShown() then return end
	for _, cell in ipairs(hud.status.cells) do
		local entry = cell.entry
		local ok, text = pcall(entry[3])
		cell.value:SetText(ok and text or '--')
		local dress = entry[2] and DRESS[entry[2]]
		if dress and dress.Lamp then
			local lampOk, lamp = pcall(dress.Lamp)
			if not lampOk then lamp = nil end
			Kit:SetLed(cell.led, lamp ~= nil, lamp ~= 'key' and lamp or nil)
		else
			Kit:SetLed(cell.led, true, 'ledGreen')
		end
	end
end

local function Separated(value)
	return BreakUpLargeNumbers and BreakUpLargeNumbers(value) or tostring(value)
end

local function PaintHudXP()
	if not hud or not hud:IsShown() then return end
	local db = DB()
	hud.xp:SetShown(db.hudXP)
	if not db.hudXP then return end
	local level = Plain(UnitLevel('player'))
	local kind, current, total, rested, faction = Experience()
	hud.xp.level:SetText(level and format('LV %d', level) or 'LV --')
	if not kind then
		hud.xp.bar:SetMinMaxValues(0, 1)
		hud.xp.bar:SetValue(1)
		Kit:Tint(hud.xp.bar, 'dim')
		hud.xp.text:SetText('MAX')
		return
	end
	hud.xp.bar:SetMinMaxValues(0, total)
	hud.xp.bar:SetValue(current, Kit.Smooth and Kit:Smooth() or nil)
	Kit:Tint(hud.xp.bar, kind == 'rep' and 'green' or 'lamp')
	local text = format('%s / %s (%.1f%%)', Separated(current), Separated(total), current / total * 100)
	if kind == 'xp' and rested and rested > 0 then text = text..'  +'..Separated(rested) end
	if kind == 'rep' and faction then text = strupper(faction)..'  '..text end
	hud.xp.text:SetText(text)
end

local function HudKey(parent, entry)
	local key = Kit:Key(parent, {round = true, width = HUD_KEY, height = HUD_KEY, text = entry[1], textSize = 6})
	key.onClick = function()
		if entry[4] and InCombatLockdown() then
			UI:Print(entry[2]..' opens once you leave combat.')
			return
		end
		UI:Safe(entry[3])
	end
	key:HookScript('OnEnter', function(self)
		GameTooltip:SetOwner(self, 'ANCHOR_BOTTOM')
		GameTooltip:ClearLines()
		GameTooltip:AddLine(strupper(entry[2]), 0.94, 0.94, 0.9)
		GameTooltip:Show()
	end)
	key:HookScript('OnLeave', function() GameTooltip:Hide() end)
	return key
end

local function BuildHud()
	hud = Kit:Device(UIParent, {header = false, radius = 10, width = 360, height = 80})
	hud:SetFrameStrata('LOW')
	hud:SetFrameLevel(2)
	Kit:Relevel(hud)
	hud.lamp = Kit:Led(hud, 5, false)
	hud.lamp:SetPoint('TOPLEFT', 9, -8)
	hud.model = Kit:Label(hud, 'HD-1', 'ink', 8, true)
	hud.model:SetPoint('LEFT', hud.lamp, 'RIGHT', 5, 0)
	-- The clock: an LCD with ghost digits behind the lit ones.
	hud.lcd = Kit:LCDPanel(hud, {radius = 5})
	hud.lcd:SetSize(132, 40)
	hud.lcd:SetPoint('TOP', 0, -8)
	hud.ghost = Kit:Text(hud.lcd, '88:88', 24, 'lcdGhost', true)
	hud.ghost:SetPoint('CENTER', -6, 0)
	if Kit.Ghost then Kit:Ghost(hud.ghost) end
	hud.digits = Kit:Text(hud.lcd, '', 24, 'lcdInk', true)
	hud.digits:SetPoint('RIGHT', hud.ghost, 'RIGHT')
	hud.digits:SetJustifyH('RIGHT')
	hud.suffix = Kit:Label(hud.lcd, '', 'lcdDim', 8, true)
	hud.suffix:SetPoint('BOTTOMLEFT', hud.ghost, 'BOTTOMRIGHT', 3, 3)
	hud.lcd.legend = Kit:Label(hud.lcd, 'TIME', 'lcdDim', 6, true)
	hud.lcd.legend:SetPoint('TOPLEFT', 6, -4)
	hud.lcd:EnableMouse(true)
	hud.lcd:SetScript('OnMouseUp', function(_, button)
		Kit:Play('tick')
		if button == 'RightButton' then
			if not _G.TimeManagerFrame and C_AddOns and C_AddOns.LoadAddOn then pcall(C_AddOns.LoadAddOn, 'Blizzard_TimeManager') end
			Call('TimeManager_Toggle')
		else
			Call('ToggleCalendar')
		end
	end)
	-- Key banks either side of the clock.
	hud.banks = {}
	for side, list in pairs(HUD_KEYS) do
		local bank = CreateFrame('Frame', nil, hud)
		bank:SetSize(HUD_COLS * HUD_KEY + (HUD_COLS - 1) * HUD_GAP, 2 * HUD_KEY + HUD_GAP)
		if side == 'left' then bank:SetPoint('RIGHT', hud.lcd, 'LEFT', -12, 0)
		else bank:SetPoint('LEFT', hud.lcd, 'RIGHT', 12, 0) end
		for index, entry in ipairs(list) do
			local key = HudKey(bank, entry)
			local column, row = (index - 1) % HUD_COLS, floor((index - 1) / HUD_COLS)
			key:SetPoint('TOPLEFT', column * (HUD_KEY + HUD_GAP), -row * (HUD_KEY + HUD_GAP))
		end
		hud.banks[side] = bank
	end
	-- The status row: four lamps with printed legends and small readouts,
	-- split by hairline rules.
	local status = CreateFrame('Frame', nil, hud)
	status:SetPoint('TOPLEFT', hud.lcd, 'BOTTOMLEFT', -96, -6)
	status:SetPoint('TOPRIGHT', hud.lcd, 'BOTTOMRIGHT', 96, -6)
	status:SetHeight(12)
	status.cells = {}
	local cellWidth = (132 + 192) / #HUD_STATUS
	for index, entry in ipairs(HUD_STATUS) do
		local cell = CreateFrame('Frame', nil, status)
		cell:SetSize(cellWidth, 12)
		cell:SetPoint('LEFT', status, 'LEFT', (index - 1) * cellWidth, 0)
		cell.entry = entry
		cell.led = Kit:Led(cell, 4, false)
		cell.led:SetPoint('LEFT', 10, 0)
		cell.legend = Kit:Label(cell, entry[1], 'dim', 7, true)
		cell.legend:SetPoint('LEFT', cell.led, 'RIGHT', 4, 0)
		cell.value = Kit:Text(cell, '', 9, 'ink', true)
		cell.value:SetPoint('RIGHT', -10, 0)
		cell.value:SetJustifyH('RIGHT')
		if index > 1 then
			cell.rule = cell:CreateTexture(nil, 'ARTWORK')
			cell.rule:SetColorTexture(1, 1, 1, 1)
			cell.rule:SetPoint('TOP', cell, 'TOPLEFT', 0, 1)
			cell.rule:SetPoint('BOTTOM', cell, 'BOTTOMLEFT', 0, -1)
			cell.rule:SetWidth(UI.Pixel.Px(cell, 1))
			Kit:Tint(cell.rule, 'rule')
		end
		status.cells[index] = cell
	end
	hud.status = status
	-- Experience or reputation as LED dots, with the numbers either side.
	local xp = CreateFrame('Frame', nil, hud)
	xp:SetPoint('BOTTOMLEFT', 12, 8)
	xp:SetPoint('BOTTOMRIGHT', -12, 8)
	xp:SetHeight(18)
	xp.track = CreateFrame('Frame', nil, xp)
	xp.track:SetPoint('BOTTOMLEFT')
	xp.track:SetPoint('BOTTOMRIGHT')
	xp.track:SetHeight(6)
	xp.track.shell = Kit:Shell(xp.track, {surface = 'lcd', radius = 99, shadow = false, fill = 'track'})
	xp.bar = CreateFrame('StatusBar', nil, xp.track)
	xp.bar:SetPoint('TOPLEFT', 2, -1)
	xp.bar:SetPoint('BOTTOMRIGHT', -2, 1)
	xp.bar:SetStatusBarTexture([[Interface\Buttons\WHITE8X8]])
	xp.bar:SetMinMaxValues(0, 1)
	xp.bar:SetValue(0)
	Kit:Perforate(xp.bar, 'track')
	if Kit.MarkBar then Kit:MarkBar(xp.bar) end
	xp.level = Kit:Label(xp, '', 'ink', 7, true)
	xp.level:SetPoint('TOPLEFT', 0, 0)
	xp.text = Kit:Label(xp, '', 'dim', 7)
	xp.text:SetPoint('TOPRIGHT', 0, 0)
	xp.text:SetJustifyH('RIGHT')
	hud.xp = xp
	UI:RegisterMover(hud, 'ip.hud', 'HUD', {'TOP', 0, -6})
end

local function LayoutHud()
	if not hud then return end
	local db = DB()
	local shown = db.layout == 'hud' or db.layout == 'both'
	hud:SetShown(shown)
	if not shown then return end
	for _, bank in pairs(hud.banks) do bank:SetShown(db.hudKeys) end
	hud.status:SetShown(db.hudStatus and true or false)
	hud:SetHeight(58 + (db.hudStatus and 18 or 0) + (db.hudXP and 22 or 0))
	PaintHudClock()
	PaintHudStatus()
	PaintHudXP()
end

local function HudShown() return hud and hud:IsShown() end

local HUD_EVENTS = {'PLAYER_XP_UPDATE', 'UPDATE_EXHAUSTION', 'PLAYER_LEVEL_UP', 'UPDATE_FACTION', 'ENABLE_XP_GAIN', 'DISABLE_XP_GAIN'}
local HUD_STATUS_EVENTS = {'FRIENDLIST_UPDATE', 'BN_FRIEND_ACCOUNT_ONLINE', 'BN_FRIEND_ACCOUNT_OFFLINE', 'GUILD_ROSTER_UPDATE'}

-- Updates --------------------------------------------------------------------------------
local events = CreateFrame('Frame')
local ticker, sinceClock = nil, 0

local function Each(func, visibleOnly)
	for _, strip in pairs(strips) do
		if strip:IsShown() and (not visibleOnly or strip:IsVisible()) then
			for _, slot in ipairs(strip.slots) do
				if slot.key and slot:IsShown() then func(slot) end
			end
		end
	end
end

local function Used()
	local used = {}
	Each(function(slot) used[slot.key] = true end)
	return used
end

local function Tick(interval)
	sinceClock = sinceClock + interval
	local clock = sinceClock >= 0.999
	if clock then sinceClock = 0 end
	Each(function(slot)
		local data = DATA[slot.key]
		if data.ticker == 'coords' or (clock and data.ticker == 'clock') then Paint(slot, clock) end
	end, true)
	if clock and hud and hud:IsVisible() then
		PaintHudClock(true)
		PaintHudStatus()
	end
end

local function Rewire()
	events:UnregisterAllEvents()
	local used = Used()
	for key in pairs(used) do
		for _, event in ipairs(DATA[key].events or {}) do pcall(events.RegisterEvent, events, event) end
	end
	if HudShown() then
		for _, event in ipairs(HUD_EVENTS) do pcall(events.RegisterEvent, events, event) end
		if DB().hudStatus then
			for _, event in ipairs(HUD_STATUS_EVENTS) do pcall(events.RegisterEvent, events, event) end
		end
	end
	if ticker then ticker:Cancel(); ticker = nil end
	sinceClock = 1
	if used.coords then
		local interval = DB().tape and 0.1 or 0.25
		ticker = C_Timer.NewTicker(interval, function() Tick(interval) end)
	elseif used.time or used.system or HudShown() then
		ticker = C_Timer.NewTicker(1, function() Tick(1) end)
	end
end

local pending = {}
events:SetScript('OnEvent', function(_, event)
	pending[event] = true
	if pending.queued then return end
	pending.queued = true
	C_Timer.After(0.1, function()
		local fired = pending
		pending = {}
		for _, name in ipairs(HUD_EVENTS) do
			if fired[name] then UI:Safe(PaintHudXP) break end
		end
		for _, name in ipairs(HUD_STATUS_EVENTS) do
			if fired[name] then UI:Safe(PaintHudStatus) break end
		end
		Each(function(slot)
			for _, name in ipairs(DATA[slot.key].events or {}) do
				if fired[name] then Paint(slot) return end
			end
		end)
	end)
end)

local function Layout()
	for _, strip in pairs(strips) do LayoutStrip(strip) end
	LayoutHud()
	Rewire()
end

-- Combat lights the strip lamps.
local combat = CreateFrame('Frame')
combat:RegisterEvent('PLAYER_REGEN_DISABLED')
combat:RegisterEvent('PLAYER_REGEN_ENABLED')
combat:SetScript('OnEvent', function(_, event)
	for _, strip in pairs(strips) do Kit:SetLed(strip.lamp, event == 'PLAYER_REGEN_DISABLED', 'red') end
	if hud then Kit:SetLed(hud.lamp, event == 'PLAYER_REGEN_DISABLED', 'red') end
end)

function module:Enable()
	sessionMoney = Plain(GetMoney())
	-- 0.5.0 profiles that turned labels off keep them off.
	local db = DB()
	if db.labels == false and not db.legendMoved then db.legend = 'icon' end
	db.legendMoved = true
	CreateStrip('main', 'Info panel', {'TOP', 0, -6})
	CreateStrip('extra', 'Info panel 2', {'TOP', 0, -40})
	BuildHud()
	Layout()
	-- Friends and guild lists fill in a moment after login.
	C_Timer.After(3, function()
		if C_GuildInfo and C_GuildInfo.GuildRoster and IsInGuild() then pcall(C_GuildInfo.GuildRoster) end
		Each(Paint)
		UI:Safe(PaintHudStatus)
	end)
end

function module:Refresh()
	if not strips.main then return end
	Layout()
	UI:PlaceMover('ip.main')
	UI:PlaceMover('ip.extra')
	UI:PlaceMover('ip.hud')
end

-- A theme change (finish, key color, ghost digits) repaints the modules.
Kit:OnRefresh(function()
	if module.enabled and strips.main then UI:Safe(Layout) end
end)

-- Hub page ---------------------------------------------------------------------------
local ITEMS = {}
for _, key in ipairs(ORDER) do ITEMS[#ITEMS + 1] = {key, NAMES[key]} end

local function SlotRows(strip)
	local rows = {}
	for index = 1, MAX_SLOTS do
		rows[#rows + 1] = {'dropdown', 'Slot '..index, 'infopanel.'..strip..index, items = ITEMS,
			hidden = function()
				local db = DB()
				return index > (db.slots or 6) or (strip == 'extra' and not db.extra)
			end}
	end
	return rows
end

local function NoStrips() return DB().layout == 'hud' end

UI:RegisterPage('infopanel', {title = 'Info panel', order = 17, cards = {
	{title = 'Style', rows = {
		{'segmented', 'Info panel', 'style.infopanel', items = {{'device', 'Device'}, {'blizzard', 'Off'}}, reload = true,
			note = 'Slim IP-1 strips of readout modules. Place them in Unlock mode.'},
		{'segmented', 'Look', 'infopanel.style', items = {{'console', 'Console'}, {'lcd', 'LCD strip'}, {'minimal', 'Minimal'}},
			since = '0.5.1', disabled = NoStrips,
			note = 'Console: a recessed LCD window per module. LCD strip: one long screen split by hairlines. Minimal: no housing, just lamps and text.'},
		{'switch', 'Second strip', 'infopanel.extra', 'A second IP-2 strip with its own slots.', disabled = NoStrips},
		{'slider', 'Slots per strip', 'infopanel.slots', 1, MAX_SLOTS, 1, nil, format = function(v) return format('%d', v) end},
		{'slider', 'Width', 'infopanel.width', 320, 1600, 20, nil, format = function(v) return format('%d', v) end},
		{'slider', 'Height', 'infopanel.height', 16, 36, 1, 'From 28 the legend sits above the readout.', format = function(v) return format('%d', v) end},
	}},
	{title = 'Modules', rows = {
		{'segmented', 'Legends', 'infopanel.legend', items = {{'both', 'Both'}, {'text', 'Text'}, {'icon', 'Glyph'}, {'none', 'None'}},
			since = '0.5.1', note = 'A printed small-caps legend (TIME, MS, FR, GLD, SPEC, POS) and a glyph at the left of each module.'},
		{'switch', 'Status lamps', 'infopanel.leds', 'Latency green, amber or red; friends and guild online; durability and bag space running low.', since = '0.5.1'},
		{'switch', 'Ghost segments', 'infopanel.ghost', 'Unlit 888 segments behind every readout. Follows the Theme\'s ghost digits too.', since = '0.5.1'},
		{'switch', 'Frame rate graph', 'infopanel.graphs', 'A segment graph of the last ten seconds beside the system readout.', since = '0.5.1'},
		{'switch', 'Coordinate tape', 'infopanel.tape', 'A tick tape under the coordinates that runs as you walk.', since = '0.5.1'},
		{'switch', 'Blinking colon', 'infopanel.blink', 'The clock\'s colon blinks once a second.', since = '0.5.1'},
		{'switch', 'Lift on hover', 'infopanel.lift', 'A module rises a pixel under the mouse and settles when pressed.', since = '0.5.1'},
	}},
	{title = 'HD-1 HUD', rows = {
		{'segmented', 'Layout', 'infopanel.layout', items = {{'strips', 'Strips'}, {'hud', 'HUD'}, {'both', 'Both'}}, since = '0.5.0',
			note = 'HUD: a top-centre device with a big LCD clock, keys for the game\'s panels, a status row and experience as dots.'},
		{'switch', 'Panel keys', 'infopanel.hudKeys', 'Round keys either side of the clock: character, spells, talents, quests, group finder, collections, map, bags, calendar and the game menu.',
			since = '0.5.0', disabled = function() return DB().layout == 'strips' end},
		{'switch', 'Status row', 'infopanel.hudStatus', 'Lamps and readouts under the clock: latency, frame rate, friends and guild online.',
			since = '0.5.1', disabled = function() return DB().layout == 'strips' end},
		{'switch', 'Experience meter', 'infopanel.hudXP', 'Level, progress and rested experience under the clock; reputation at maximum level.',
			since = '0.5.0', disabled = function() return DB().layout == 'strips' end},
	}},
	{title = 'Clock', rows = {
		{'switch', '24-hour clock', 'infopanel.clock24'},
		{'switch', 'Local time', 'infopanel.clockLocal', 'Off shows the realm\'s time.'},
	}},
	{title = 'IP-1 slots', rows = SlotRows('main')},
	{title = 'IP-2 slots', rows = SlotRows('extra')},
}})
