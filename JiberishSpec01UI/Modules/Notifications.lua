-- Loot and notifications as SPEC-01 devices.
--
-- Loot window ('LT-1 Loot'): our own, opened at the cursor or its spot; rows
-- cascade in on a black display, each item on a key, and leave as they are
-- taken. Rolls ('RL-1 Roll'): one device per roll with need/greed/
-- disenchant/transmog/pass keys and a dot line for the time left. Loot feed:
-- glass chips that slide in beside the screen edge as items and coins arrive,
-- counting up on repeats. Banners: level-up (LCD digits running up to the new
-- level), quest complete, achievement, zone and reputation, one at a time from
-- a queue that waits out combat and cinematics. Blizzard's own alert frames
-- that remain get a glass shell.
--
-- Nothing here is protected; Blizzard's frames are only quieted (events off,
-- parked or faded), never hooked by method. Chat lines can be secret in 12.x,
-- so they are only read when plain.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, GetTime, InCombatLockdown = CreateFrame, UIParent, GetTime, InCombatLockdown
local floor, max, min = math.floor, math.max, math.min

local module = UI:RegisterModule('loot', {})
local function IsSecret(value) return issecretvalue and issecretvalue(value) end
local function Plain(value) if not IsSecret(value) then return value end end
local function Toasts() return UI.db.toasts end
local function LootDB() return UI.db.loot end
local function Wants(setting) local db = Toasts(); return db.enable and db[setting] end

-- defaults:begin
-- Per banner: hold (seconds on screen) and sound (a SPEC-01 voice, or 'off').
-- Whether each banner shows at all stays under toasts.* (levelUp, questComplete, ...).
UI:RegisterDefaults('banners', {scale = 1,
	levelUp = {hold = 5, sound = 'success'}, quest = {hold = 3.5, sound = 'success'}, questAccept = {hold = 3, sound = 'open'},
	achievement = {hold = 5, sound = 'success'}, zone = {hold = 3, sound = 'blip'}, subzone = {enable = true, hold = 2.5, sound = 'tick'},
	reputation = {hold = 3, sound = 'tick'}})
-- feedGrow: 'up' or 'down' from the feed's spot. feedQuality: the lowest item quality shown.
UI:RegisterDefaults('loot', {windowScale = 1, rowHeight = 30, feedMax = 6, feedGrow = 'up', feedLife = 5, feedQuality = 0,
	feedMoney = true, rollScale = 1, alerts = true})
-- defaults:end

-- Which banner settings an entry uses.
local BANNER_OF = {['levelup'] = 'levelUp', quest = 'quest', questAccept = 'questAccept', achievement = 'achievement', zone = 'zone',
	sub = 'subzone', rep = 'reputation'}
local function BannerDB(kind) return UI.db.banners[BANNER_OF[kind] or ''] end

-- Loot and alert sounds go through the interface's sound choices (Sounds page).
local function Play(name, kind)
	if not name or name == 'off' then return end
	if UI.InterfaceSound then return UI:InterfaceSound(name, 'notify:'..name, 'notifications', kind or 'loot') end
	Kit:Play(name, true)
end
local function Ghost(fontString) if Kit.Ghost then Kit:Ghost(fontString) end return fontString end

local SPEED = Kit.SPEED
local MASK = Kit.media..'mask-icon.tga'

-- Item quality colors as palette tokens (Kit:Tint takes a color table).
local qualityTokens = {}
local function Quality(quality)
	quality = Plain(quality)
	if type(quality) ~= 'number' then return 'darkInk' end
	if qualityTokens[quality] then return qualityTokens[quality] end
	local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
	local token = color and {color.r, color.g, color.b} or 'darkInk'
	qualityTokens[quality] = token
	return token
end

-- An icon on a light key, cropped and with rounded corners.
local function IconKey(parent, size)
	local key = CreateFrame('Frame', nil, parent)
	key:SetSize(size, size)
	key.skin = Kit:Skin(key, 'key', 'BACKGROUND', 0)
	key.skin.kitMaxCorner = 7
	key.icon = key:CreateTexture(nil, 'ARTWORK')
	key.icon:SetPoint('TOPLEFT', 3, -3)
	key.icon:SetPoint('BOTTOMRIGHT', -3, 3)
	key.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	if key.icon.AddMaskTexture then
		local mask = key:CreateMaskTexture()
		mask:SetTexture(MASK, 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
		mask:SetAllPoints(key.icon)
		key.icon:AddMaskTexture(mask)
	end
	key.count = Kit:Text(key, '', 9, 'white', true)
	Kit:Font(key.count, 9, 'OUTLINE', true)
	key.count:SetPoint('BOTTOMRIGHT', 1, -1)
	return key
end

-- A small LCD readout with unlit '8's behind its digits.
local function LCDChip(parent, width, height, size, ghost)
	local chip = Kit:LCDPanel(parent, {radius = 3})
	chip:SetSize(width, height)
	chip.ghost = Ghost(Kit:Text(chip, ghost or '88', size, 'lcdGhost', true))
	chip.ghost:SetPoint('RIGHT', -5, 0)
	chip.digits = Kit:Text(chip, '', size, 'lcdInk', true)
	chip.digits:SetPoint('RIGHT', -5, 0)
	chip.digits:SetJustifyH('RIGHT')
	return chip
end

-- Chat format strings ("You receive loot: %sx%d.") as whole-line patterns,
-- with the argument order of each capture (positional holes like %2$s too).
local MAGIC = '^$()%.[]*+-?'
local function Pattern(text)
	if type(text) ~= 'string' or text == '' then return end
	local out, order, sequence, index = {}, {}, 0, 1
	while index <= #text do
		local char = text:sub(index, index)
		if char == '%' then
			if text:sub(index + 1, index + 1) == '%' then
				out[#out + 1] = '%%'
				index = index + 2
			else
				local first, last, position, conversion = text:find('^%%(%d*)%$?[%-%d%.]*(%a)', index)
				if not first then
					out[#out + 1] = '%%'
					index = index + 1
				else
					sequence = sequence + 1
					order[#order + 1] = tonumber(position) or sequence
					out[#out + 1] = (conversion == 'd' or conversion == 'i') and '(%d+)'
						or (conversion == 'f' or conversion == 'g') and '([%d%.]+)' or '(.+)'
					index = last + 1
				end
			end
		else
			out[#out + 1] = MAGIC:find(char, 1, true) and '%'..char or char
			index = index + 1
		end
	end
	return {pattern = '^'..table.concat(out)..'$', order = order}
end

local function Patterns(names)
	local list = {}
	for _, name in ipairs(names) do
		local entry = Pattern(_G[name])
		if entry then list[#list + 1] = entry end
	end
	return list
end

-- The arguments of the first pattern that matches, in format order, or nil.
local function Match(list, message)
	if type(message) ~= 'string' or IsSecret(message) then return end
	for _, entry in ipairs(list) do
		local captures = {message:match(entry.pattern)}
		if #captures > 0 then
			local args = {}
			for index, argument in ipairs(entry.order) do args[argument] = captures[index] end
			return args
		end
	end
end

-- Banners ------------------------------------------------------------------------------
-- One device near the top of the screen; entries wait in a queue so banners
-- never overlap. Fights, cinematics and the game's own toasts hold the queue.
local banner, showing
local queue = {}
local inCombat, inCinematic = false, false
local blankedToast = false

local function GameToasting()
	local manager = _G.EventToastManagerFrame
	if blankedToast or type(manager) ~= 'table' or not manager:IsShown() then return false end
	return type(manager.IsCurrentlyToasting) == 'function' and manager:IsCurrentlyToasting() ~= nil
end

local function Busy() return showing ~= nil or inCombat or inCinematic or GameToasting() end

local BANNER_WIDTH = 388

local function BuildBanner()
	if banner then return banner end
	local b = Kit:Device(UIParent, {model = 'LV-1', title = '', surface = 'paper', radius = 14, width = BANNER_WIDTH, height = 100})
	b:SetFrameStrata('HIGH')
	b:EnableMouse(false)
	b:Hide()
	-- Left slot: an LCD readout or an icon on a key.
	b.lcd = LCDChip(b, 88, 56, 34, '88')
	b.lcd:SetPoint('TOPLEFT', 12, -28)
	b.lcd.tag = Kit:Label(b.lcd, 'LVL', 'lcdDim', 7, true)
	b.lcd.tag:SetPoint('TOPLEFT', 6, -5)
	b.key = IconKey(b, 56)
	b.key:SetPoint('TOPLEFT', 12, -28)
	b.glyph = Kit:Icon(b.key, 'check', 22, 'ink')
	b.glyph:SetPoint('CENTER')
	-- Right of it: the headline and two lines.
	b.head = Kit:Text(b, '', 'head', 'ink', true)
	b.head:SetWordWrap(false)
	b.line1 = Kit:Text(b, '', 'small', 'dim')
	b.line1:SetWordWrap(false)
	b.line2 = Kit:Text(b, '', 'small', 'dim')
	b.line2:SetWordWrap(false)
	-- A small LCD at the right: achievement points.
	b.chip = LCDChip(b, 56, 22, 11, '8888')
	b.chip:SetPoint('TOPRIGHT', -12, -30)
	b.chip.tag = Kit:Label(b, 'PTS', 'dim', 7, true)
	b.chip.tag:SetPoint('TOP', b.chip, 'BOTTOM', 0, -3)
	-- The time left, or a standing meter.
	b.dots = Kit:DotLine(b, 44, 3, 4)
	b.dots:SetPoint('BOTTOM', 0, 9)
	b.holdKey, b.countKey = {}, {}
	b.SetPreview = function(self, on)
		if on and not showing then
			module.FillBanner({kind = 'preview', model = 'NT-1', title = 'Banners', layout = 'center', head = 'Banner spot',
				line1 = 'Level-ups, quests, achievements, zones', meter = 1})
			self:SetAlpha(1)
			self:Show()
		elseif not on and not showing then
			self:Hide()
		end
	end
	b:SetScale(Kit:Clamp(tonumber(UI.db.banners.scale) or 1, 0.5, 2))
	UI:RegisterMover(b, 'nt.banner', 'Banners', {'TOP', 0, -64})
	banner = b
	return b
end

local function Place(region, point, relative, relativePoint, x, y)
	region:ClearAllPoints()
	region:SetPoint(point, relative, relativePoint, x, y)
end

-- entry: kind, model, title, layout ('lcd' | 'icon' | 'center' | 'compact'), head, line1, line2,
--        lcd = {value, tag, count}, icon (texture), glyph (kit icon name), chip = {value, tag},
--        lamp (token), meter (0..1, a standing meter instead of the time left), sound, hold, merge
function module.FillBanner(entry)
	local b = BuildBanner()
	local layout = entry.layout or 'compact'
	local height = (layout == 'compact' and 74) or (layout == 'center' and 92) or 100
	b:SetHeight(height)
	b.model:SetText(strupper(entry.model or 'NT-1'))
	b.title:SetText(strupper(entry.title or ''))
	Kit:SetLed(b.lamp, true, entry.lamp)
	local slot = layout == 'lcd' or layout == 'icon'
	b.lcd:SetShown(layout == 'lcd')
	b.key:SetShown(layout == 'icon')
	if layout == 'lcd' and entry.lcd then
		local text = tostring(entry.lcd.value or '')
		b.lcd.ghost:SetText(strrep('8', max(#text, 2)))
		b.lcd.digits:SetText(text)
		b.lcd.tag:SetText(strupper(entry.lcd.tag or ''))
	end
	if layout == 'icon' then
		b.key.icon:SetShown(entry.icon ~= nil)
		if entry.icon then b.key.icon:SetTexture(entry.icon) end
		b.glyph:SetShown(entry.icon == nil)
		Kit:SetIcon(b.glyph, entry.glyph or 'check')
		b.key.count:SetText('')
	end
	local chip = entry.chip ~= nil
	b.chip:SetShown(chip)
	b.chip.tag:SetShown(chip)
	if chip then
		b.chip.digits:SetText(tostring(entry.chip.value or ''))
		b.chip.tag:SetText(strupper(entry.chip.tag or ''))
	end
	-- Text: beside the slot, or centered for a zone.
	local left = slot and 112 or 16
	local right = chip and 80 or 16
	local width = BANNER_WIDTH - left - right
	Kit:Font(b.head, layout == 'center' and Kit.SIZE.title or Kit.SIZE.head, nil, true)
	for _, text in ipairs({b.head, b.line1, b.line2}) do
		text:SetWidth(width)
		text:SetJustifyH(layout == 'center' and 'CENTER' or 'LEFT')
	end
	b.head:SetText(entry.head or '')
	b.line1:SetText(entry.line1 or '')
	b.line2:SetText(entry.line2 or '')
	if layout == 'center' then
		Place(b.head, 'TOP', b, 'TOP', 0, -32)
	else
		Place(b.head, 'TOPLEFT', b, 'TOPLEFT', left, layout == 'compact' and -28 or -32)
	end
	Place(b.line1, 'TOP', b.head, 'BOTTOM', 0, -5)
	Place(b.line2, 'TOP', b.line1, 'BOTTOM', 0, -3)
	b.line1:SetShown((entry.line1 or '') ~= '')
	b.line2:SetShown((entry.line2 or '') ~= '')
	b.dots.lit = -1
	Kit:SetDots(b.dots, entry.meter or 1, entry.meter and (entry.lamp or 'lamp') or 'ink', 'ledOff', entry.meter and 1 or 0.55)
end

local Next
local closing = false -- the banner on screen is on its way out
local function CloseBanner()
	local entry = showing
	if not entry or not banner then return end
	-- Already gone (hidden some other way): free the spot.
	if not banner:IsShown() then
		showing, closing = nil, false
		return C_Timer.After(0, function() UI:Safe(Next) end)
	end
	closing = true
	Kit:Close(banner, function()
		if showing == entry then showing, closing = nil, false end
		C_Timer.After(SPEED.FAST, function() UI:Safe(Next) end)
	end)
end

-- The hold: the time left drains along the dots (a standing meter stays put).
local function Hold(entry)
	local b = banner
	entry.token = (entry.token or 0) + 1
	local token = entry.token
	local hold = entry.hold or 4
	if not entry.meter then
		Kit:Animate(b.holdKey, hold, 1, 0, function(value) Kit:SetDots(b.dots, value, 'ink', 'ledOff', 0.55) end, nil, 'linear')
	end
	C_Timer.After(hold, function()
		if showing == entry and entry.token == token then CloseBanner() end
	end)
end

local function Show(entry)
	local b = BuildBanner()
	showing, closing = entry, false
	module.FillBanner(entry)
	if entry.lcd and entry.lcd.count and type(entry.lcd.value) == 'number' then
		local to = entry.lcd.value
		Kit:Animate(b.countKey, SPEED.SLOW, max(to - 9, 1), to, function(value) b.lcd.digits:SetText(floor(value + 0.5)) end, nil, 'cubic')
	end
	UI:PlaceMover('nt.banner')
	Kit:ResetRest(b)
	Kit:Open(b)
	-- LCD print-in (a motion extra): the banner's lines print in one after another.
	if Kit.Alive and Kit:Alive('lcdPrint') then
		for index, text in ipairs({b.title, b.head, b.line1, b.line2}) do
			Kit:Print(text, {force = true, duration = 0.28, steps = 16, delay = 0.08 + (index - 1) * 0.07})
		end
	end
	Play(entry.sound or 'open', 'alerts')
	Hold(entry)
end

function Next()
	if Busy() or #queue == 0 then return end
	Show(table.remove(queue, 1))
end

-- Events that can wait for the fight to end do; the rest become a toast or
-- are dropped (a zone you rode through mid-fight is old news).
local IN_COMBAT = {quest = 'toast', questAccept = 'toast', zone = 'drop', sub = 'drop'}

local function Push(entry)
	-- The player's own hold time and sound for this kind of banner.
	local config = BannerDB(entry.kind)
	if config then
		entry.hold = Kit:Clamp(tonumber(config.hold) or entry.hold or 4, 1, 20)
		if config.sound then entry.sound = config.sound end
	end
	if entry.merge then
		-- Into the banner on screen, unless it is already leaving (then it queues).
		if showing and not closing and showing.merge == entry.merge and entry.Merge then
			entry.Merge(showing, entry)
			module.FillBanner(showing)
			Hold(showing)
			return
		end
		for _, queued in ipairs(queue) do
			if queued.merge == entry.merge and entry.Merge then return entry.Merge(queued, entry) end
		end
	end
	if entry.replace then
		for index = #queue, 1, -1 do
			if queue[index].replace == entry.replace then table.remove(queue, index) end
		end
	end
	if inCombat then
		local rule = IN_COMBAT[entry.kind]
		if rule == 'drop' then return end
		if rule == 'toast' then
			return Kit:Toast({title = entry.title, text = entry.head, tone = 'success'})
		end
	end
	queue[#queue + 1] = entry
	Next()
end
module.Push = Push

-- Level up -----------------------------------------------------------------------------
local function StatName(index, fallback) return _G['SPELL_STAT'..index..'_NAME'] or fallback end

local function Gains(health, power, strength, agility, stamina, intellect)
	local parts = {}
	local function Add(value, name)
		value = Plain(value)
		if type(value) == 'number' and value > 0 then parts[#parts + 1] = '+'..value..' '..name end
	end
	Add(health, HEALTH or 'Health')
	local _, powerToken = UnitPowerType('player')
	Add(power, (powerToken and _G[powerToken]) or MANA or 'Power')
	Add(strength, StatName(1, 'Strength'))
	Add(agility, StatName(2, 'Agility'))
	Add(stamina, StatName(3, 'Stamina'))
	Add(intellect, StatName(4, 'Intellect'))
	return table.concat(parts, '  ·  ')
end

local function LevelUp(level, health, power, talents, _, strength, agility, stamina, intellect)
	level = Plain(level)
	if type(level) ~= 'number' or not Wants('levelUp') then return end
	talents = Plain(talents)
	local talentLine = type(talents) == 'number' and talents > 0
		and (talents == 1 and 'A new talent point to spend' or talents..' new talent points') or nil
	Push({kind = 'levelup', model = 'LV-1', title = 'Level up', layout = 'lcd', lcd = {value = level, tag = 'LVL', count = true},
		head = format('Level %d', level), line1 = Gains(health, power, strength, agility, stamina, intellect), line2 = talentLine,
		sound = 'success', hold = 5})
end

-- The game shows its own level-up toast; while ours is on it stays invisible.
local LEVEL_TOAST = Enum and Enum.EventToastEventType and Enum.EventToastEventType.LevelUp
local toastWatch = CreateFrame('Frame')
local function CheckGameToast()
	local manager = _G.EventToastManagerFrame
	if type(manager) ~= 'table' then return end
	local current = manager.currentDisplayingToast
	local info = type(current) == 'table' and current.toastInfo
	local level = Wants('levelUp') and manager:IsShown() and type(info) == 'table' and LEVEL_TOAST ~= nil and info.eventType == LEVEL_TOAST
	level = level and true or false
	if level then manager:SetAlpha(0) end
	if level ~= blankedToast then
		blankedToast = level
		if not level then manager:SetAlpha(1) end
	end
end

local function QuietGameLevelUp()
	local manager = _G.EventToastManagerFrame
	if type(manager) == 'table' and manager.HookScript then
		manager:HookScript('OnShow', function()
			toastWatch:SetScript('OnUpdate', function() UI:Safe(CheckGameToast) end)
			UI:Safe(CheckGameToast)
		end)
		manager:HookScript('OnHide', function()
			toastWatch:SetScript('OnUpdate', nil)
			UI:Safe(CheckGameToast)
			C_Timer.After(0, function() UI:Safe(Next) end)
		end)
	end
	-- Older interfaces announce a level with LevelUpDisplay instead.
	local display = _G.LevelUpDisplay
	if Wants('levelUp') and type(display) == 'table' and display.UnregisterEvent then
		pcall(display.UnregisterEvent, display, 'PLAYER_LEVEL_UP')
	end
end

-- Quests -------------------------------------------------------------------------------
local questTitles = {}
local function QuestTitle(questID)
	questID = Plain(questID)
	if not questID then return end
	local title = C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID)
	title = Plain(title)
	if type(title) == 'string' and title ~= '' then questTitles[questID] = title end
	return questTitles[questID]
end

local function Money(copper)
	copper = Plain(copper)
	if type(copper) ~= 'number' or copper <= 0 then return end
	if GetMoneyString then return GetMoneyString(copper, true) end
	if GetCoinTextureString then return GetCoinTextureString(copper) end
	return tostring(copper)
end

local function IsTaskQuest(questID)
	local log = C_QuestLog
	if log and log.IsWorldQuest and log.IsWorldQuest(questID) then return true end
	if log and log.IsQuestTask and log.IsQuestTask(questID) then return true end
	return C_TaskQuest and C_TaskQuest.IsActive and C_TaskQuest.IsActive(questID) or false
end

local function QuestTurnedIn(questID, xp, money)
	if not Wants('questComplete') then return end
	questID = Plain(questID)
	if not questID then return end
	local title = QuestTitle(questID)
	-- World and task quests only with a name; anything else needs a name or a reward.
	if not title and Plain(IsTaskQuest(questID)) then return end
	local rewards = {}
	xp = Plain(xp)
	if type(xp) == 'number' and xp > 0 then
		rewards[#rewards + 1] = (BreakUpLargeNumbers and BreakUpLargeNumbers(xp) or tostring(xp))..' XP'
	end
	rewards[#rewards + 1] = Money(money)
	if not title and #rewards == 0 then return end
	Push({kind = 'quest', model = 'QT-1', title = 'Quest complete', layout = 'icon', glyph = 'check', lamp = 'green',
		head = title or 'Quest', line1 = table.concat(rewards, '  ·  '), sound = 'success', hold = 3.5})
end

local function QuestAccepted(first, second)
	if not Wants('questAccept') then return end
	-- Older clients send the log index first, then the quest.
	local questID = second or first
	Push({kind = 'questAccept', model = 'QT-1', title = 'New quest', layout = 'compact', lamp = 'blue',
		head = QuestTitle(questID) or 'Quest accepted', sound = 'open', hold = 3})
end

-- Achievements -------------------------------------------------------------------------
local function Achievement(id)
	id = Plain(id)
	if not id or not Wants('achievement') or not GetAchievementInfo then return end
	local _, name, points, _, _, _, _, description, _, icon = GetAchievementInfo(id)
	name = Plain(name)
	if type(name) ~= 'string' then return end
	points = Plain(points)
	Push({kind = 'achievement', model = 'AC-1', title = 'Achievement', layout = 'icon', icon = Plain(icon), head = name,
		line1 = Plain(description), chip = type(points) == 'number' and points > 0 and {value = points, tag = 'Pts'} or nil,
		sound = 'success', hold = 5})
end

-- Zones --------------------------------------------------------------------------------
local PVP = {
	sanctuary = {'blue', 'SANCTUARY_TERRITORY'}, friendly = {'green', 'FACTION_CONTROLLED_TERRITORY'},
	hostile = {'red', 'FACTION_CONTROLLED_TERRITORY'}, contested = {'amber', 'CONTESTED_TERRITORY'},
	combat = {'red', 'COMBAT_ZONE'}, arena = {'red', 'FREE_FOR_ALL_TERRITORY'},
}

local function ZonePvP()
	local get = (C_PvP and C_PvP.GetZonePVPInfo) or GetZonePVPInfo
	if not get then return end
	local kind, _, faction = get()
	kind = Plain(kind)
	local info = kind and PVP[kind]
	if not info then return end
	local text = _G[info[2]]
	if type(text) ~= 'string' then return nil, info[1] end
	if info[2] == 'FACTION_CONTROLLED_TERRITORY' then
		faction = Plain(faction)
		if type(faction) ~= 'string' or faction == '' then return nil, info[1] end
		text = format(text, faction)
	end
	return text, info[1]
end

local GAME_ZONE_TEXT = {'ZoneTextString', 'SubZoneTextString', 'PVPInfoTextString', 'PVPArenaTextString'}
local active = false -- set once the module is on
local function QuietZoneText()
	local hide = active and Wants('zone')
	for _, name in ipairs(GAME_ZONE_TEXT) do
		local text = _G[name]
		if text and text.SetAlpha then text:SetAlpha(hide and 0 or 1) end
	end
end

local lastZone, lastSub, lastZoneTime = nil, nil, 0
local function Zone(full)
	QuietZoneText()
	if not Wants('zone') then return end
	local zone, sub = Plain(GetZoneText()), Plain(GetSubZoneText())
	if type(zone) ~= 'string' or zone == '' then return end
	sub = type(sub) == 'string' and sub ~= zone and sub or ''
	local pvp, lamp = ZonePvP()
	if full or zone ~= lastZone then
		if zone == lastZone and GetTime() - lastZoneTime < 5 then return end
		lastZone, lastSub, lastZoneTime = zone, sub, GetTime()
		Push({kind = 'zone', replace = 'zone', model = 'NV-1', title = 'Location', layout = 'center', head = zone, line1 = sub,
			line2 = pvp, lamp = lamp, sound = 'blip', hold = 3})
	elseif sub ~= '' and sub ~= lastSub then
		lastSub = sub
		if UI.db.banners.subzone.enable == false then return end
		Push({kind = 'sub', replace = 'zone', model = 'NV-1', title = zone, layout = 'compact', head = sub, line1 = pvp,
			lamp = lamp, sound = 'tick', hold = 2.5})
	end
end

-- Reputation ---------------------------------------------------------------------------
local repPatterns
local function FactionData(name)
	local api = C_Reputation
	if api and api.GetNumFactions and api.GetFactionDataByIndex then
		for index = 1, min(api.GetNumFactions() or 0, 400) do
			local data = api.GetFactionDataByIndex(index)
			if data and Plain(data.name) == name and not data.isHeader then
				return data.reaction, data.currentReactionThreshold, data.nextReactionThreshold, data.currentStanding
			end
		end
	elseif GetNumFactions and GetFactionInfo then
		for index = 1, min(GetNumFactions() or 0, 400) do
			local factionName, _, standing, low, high, value, _, _, isHeader = GetFactionInfo(index)
			if Plain(factionName) == name and not isHeader then return standing, low, high, value end
		end
	end
end

local function RepEntry(name, amount)
	local reaction, low, high, value = FactionData(name)
	local meter, standing
	if type(low) == 'number' and type(high) == 'number' and type(value) == 'number' and high > low then
		meter = max(0, min(1, (value - low) / (high - low)))
	end
	if type(reaction) == 'number' then standing = _G['FACTION_STANDING_LABEL'..reaction] end
	return {kind = 'rep', merge = 'rep:'..name, faction = name, amount = amount, model = 'RP-1', title = 'Reputation',
		layout = 'compact', head = name, line1 = format('%s%d%s', amount >= 0 and '+' or '', amount, standing and ('  ·  '..standing) or ''),
		meter = meter or 0, lamp = amount >= 0 and 'green' or 'red', sound = 'tick', hold = 3,
		Merge = function(into, from)
			local merged = RepEntry(into.faction, (into.amount or 0) + (from.amount or 0))
			for key, value2 in pairs(merged) do if key ~= 'token' then into[key] = value2 end end
		end}
end

local function Reputation(message)
	if not Wants('reputation') then return end
	repPatterns = repPatterns or {
		up = Patterns({'FACTION_STANDING_INCREASED_DOUBLE_BONUS', 'FACTION_STANDING_INCREASED_ACH_BONUS',
			'FACTION_STANDING_INCREASED_BONUS', 'FACTION_STANDING_INCREASED_ACCOUNT_WIDE', 'FACTION_STANDING_INCREASED'}),
		down = Patterns({'FACTION_STANDING_DECREASED_ACCOUNT_WIDE', 'FACTION_STANDING_DECREASED'}),
	}
	local sign, args = 1, Match(repPatterns.up, message)
	if not args then sign, args = -1, Match(repPatterns.down, message) end
	local name, amount = args and args[1], args and tonumber(args[2])
	if type(name) ~= 'string' or not amount then return end
	Push(RepEntry(name, sign * floor(amount + 0.5)))
end

-- Loot feed ----------------------------------------------------------------------------
-- Chips stack up from their holder, newest at the bottom; a repeat of
-- something already showing counts up on it instead of adding a chip.
local feed, chips, chipPool = nil, {}, {}
local FEED_WIDTH, CHIP_HEIGHT, CHIP_GAP = 236, 28, 5
local function FeedMax() return Kit:Clamp(floor(tonumber(LootDB().feedMax) or 6), 1, 12) end
local function FeedLife() return Kit:Clamp(tonumber(LootDB().feedLife) or 5, 2, 20) end
local function FeedDown() return LootDB().feedGrow == 'down' end
local lootPatterns, currencyPatterns

local function PlaceChip(chip)
	chip:ClearAllPoints()
	if FeedDown() then chip:SetPoint('TOPRIGHT', feed, 'TOPRIGHT', chip.ox or 0, -(chip.y or 0))
	else chip:SetPoint('BOTTOMRIGHT', feed, 'BOTTOMRIGHT', chip.ox or 0, chip.y or 0) end
end

local function LayoutChips()
	local y = 0
	for _, chip in ipairs(chips) do
		local target = y
		y = y + CHIP_HEIGHT + CHIP_GAP
		if chip.y == nil then
			chip.y = target
			PlaceChip(chip)
		elseif chip.y ~= target then
			Kit:Animate(chip.glide, SPEED.NORMAL, chip.y, target, function(value) chip.y = value; PlaceChip(chip) end, nil, 'cubic')
		end
	end
end

local function BuildFeed()
	if feed then return feed end
	feed = CreateFrame('Frame', nil, UIParent)
	feed:SetSize(FEED_WIDTH, CHIP_HEIGHT)
	feed:SetFrameStrata('MEDIUM')
	local db = LootDB()
	feed.SetPreview = function(_, on)
		if on then module.Preview('feed') end
	end
	UI:RegisterMover(feed, 'nt.loot', 'Loot feed', {'RIGHT', db.feedX or -260, db.feedY or 0})
	return feed
end

local function NewChip()
	local chip = CreateFrame('Frame', nil, BuildFeed())
	chip:SetSize(FEED_WIDTH, CHIP_HEIGHT)
	chip.shell = Kit:Shell(chip, {surface = 'glass', radius = 7})
	chip.key = IconKey(chip, 22)
	chip.key:SetPoint('LEFT', 3, 0)
	chip.name = Kit:Text(chip, '', 10, 'darkInk')
	chip.name:SetPoint('LEFT', chip.key, 'RIGHT', 8, 0)
	chip.name:SetPoint('RIGHT', -44, 0)
	chip.name:SetJustifyH('LEFT')
	chip.name:SetWordWrap(false)
	chip.lcd = LCDChip(chip, 36, 18, 10, '888')
	chip.lcd:SetPoint('RIGHT', -5, 0)
	chip.glide, chip.fade = {}, {}
	return chip
end

local function ExpireChip(chip)
	if chip.leaving then return end
	chip.leaving = true
	Kit:Animate(chip.fade, SPEED.CLOSE, 0, 1, function(progress)
		chip:SetAlpha(1 - Kit.ease.inout(progress))
		chip.ox = 14 * Kit.ease.cubic(progress)
		PlaceChip(chip)
	end, function()
		chip:Hide()
		for index, other in ipairs(chips) do
			if other == chip then table.remove(chips, index); break end
		end
		chipPool[#chipPool + 1] = chip
		LayoutChips()
	end, 'linear')
end

local function HoldChip(chip)
	chip.stamp = (chip.stamp or 0) + 1
	local stamp = chip.stamp
	C_Timer.After(FeedLife(), function() if chip.stamp == stamp then ExpireChip(chip) end end)
end

local function SetChipCount(chip)
	local count = chip.count or 1
	chip.lcd:SetShown(chip.isMoney ~= true and count > 1)
	chip.lcd.digits:SetText(count > 999 and '999' or ('x'..count))
	chip.lcd.ghost:SetText(strrep('8', #tostring(min(count, 999)) + 1))
end

-- item: {key, name, quality, icon, count} or {money = copper}; force: shown even with the feed off (previews).
local function AddLoot(item, force)
	if not (force or LootDB().feed) then return end
	-- Items below the chosen quality stay out of the feed (an unknown quality shows).
	local quality = Plain(item.quality)
	if not force and type(item.key) == 'string' and item.key:find('^item:') and type(quality) == 'number'
		and quality < (tonumber(LootDB().feedQuality) or 0) then
		return
	end
	BuildFeed()
	for _, chip in ipairs(chips) do
		if not chip.leaving and chip.key_ == item.key then
			if item.money then
				chip.money = (chip.money or 0) + item.money
				chip.name:SetText(Money(chip.money) or '')
			else
				chip.count = (chip.count or 1) + (item.count or 1)
				SetChipCount(chip)
			end
			Play('tick')
			HoldChip(chip)
			return
		end
	end
	local chip = table.remove(chipPool) or NewChip()
	chip.key_, chip.leaving, chip.y, chip.ox = item.key, nil, nil, 24
	chip.isMoney, chip.money, chip.count = item.money ~= nil, item.money, item.count or 1
	chip.key.icon:SetTexture(item.icon or 134400)
	chip.name:SetText(item.money and (Money(item.money) or '') or (item.name or ''))
	Kit:Tint(chip.name, item.money and 'darkInk' or Quality(item.quality))
	SetChipCount(chip)
	table.insert(chips, 1, chip)
	-- Beyond the limit, the oldest leave the usual way.
	local over = {}
	for index = FeedMax() + 1, #chips do over[#over + 1] = chips[index] end
	for _, old in ipairs(over) do ExpireChip(old) end
	LayoutChips()
	chip:SetAlpha(0)
	chip:Show()
	Kit:Animate(chip.fade, SPEED.SLOW, 0, 1, function(progress)
		chip:SetAlpha(Kit.ease.sine(min(progress * 2, 1)))
		chip.ox = 24 * (1 - Kit.ease.cubic(progress))
		PlaceChip(chip)
	end, nil, 'linear')
	HoldChip(chip)
end

local function ItemFromLink(link, count)
	if type(link) ~= 'string' or IsSecret(link) then return end
	local name = link:match('%[(.-)%]') or link
	local itemID = tonumber(link:match('item:(%d+)'))
	local quality, icon
	if C_Item then
		if C_Item.GetItemQualityByID then quality = C_Item.GetItemQualityByID(link) end
		if C_Item.GetItemIconByID then icon = C_Item.GetItemIconByID(itemID or link) end
	end
	if not icon and GetItemIcon and itemID then icon = GetItemIcon(itemID) end
	if quality == nil and GetItemInfo then quality = select(3, GetItemInfo(link)) end
	return {key = 'item:'..(itemID or name), name = name, quality = quality, icon = icon, count = count}
end

local function CurrencyFromLink(link, count)
	if type(link) ~= 'string' or IsSecret(link) then return end
	local currencyID = tonumber(link:match('currency:(%d+)'))
	local info = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfoFromLink and C_CurrencyInfo.GetCurrencyInfoFromLink(link)
	return {key = 'currency:'..(currencyID or link), name = (info and info.name) or link:match('%[(.-)%]') or link,
		quality = info and info.quality, icon = info and info.iconFileID, count = count}
end

local function OnLootMessage(message)
	lootPatterns = lootPatterns or Patterns({'LOOT_ITEM_SELF_MULTIPLE', 'LOOT_ITEM_SELF', 'LOOT_ITEM_PUSHED_SELF_MULTIPLE',
		'LOOT_ITEM_PUSHED_SELF', 'LOOT_ITEM_CREATED_SELF_MULTIPLE', 'LOOT_ITEM_CREATED_SELF',
		'LOOT_ITEM_BONUS_ROLL_SELF_MULTIPLE', 'LOOT_ITEM_BONUS_ROLL_SELF'})
	local args = Match(lootPatterns, message)
	if not args then return end
	local item = ItemFromLink(args[1], tonumber(args[2]) or 1)
	if item then AddLoot(item) end
end

local function OnCurrencyMessage(message)
	if not Toasts().currency then return end
	currencyPatterns = currencyPatterns or Patterns({'CURRENCY_GAINED_MULTIPLE_BONUS', 'CURRENCY_GAINED_MULTIPLE', 'CURRENCY_GAINED'})
	local args = Match(currencyPatterns, message)
	if not args then return end
	local item = CurrencyFromLink(args[1], tonumber(args[2]) or 1)
	if item then AddLoot(item) end
end

-- Coins show from the money total changing while a corpse is open (or just
-- closed), so no chat line has to be read for them.
local looting, lootClosedAt, lastMoney = false, 0, nil
local function OnMoney()
	local money = GetMoney()
	if IsSecret(money) then return end
	local gained = lastMoney and money - lastMoney or 0
	lastMoney = money
	if gained > 0 and LootDB().feedMoney ~= false and (looting or GetTime() - lootClosedAt < 1.5) then
		AddLoot({key = 'money', money = gained, icon = 'Interface\\MoneyFrame\\UI-GoldIcon'})
	end
end

-- Loot window --------------------------------------------------------------------------
local window, rows = nil, {}
local LOOT_WIDTH, ROW_GAP = 252, 3
local function RowHeight() return Kit:Clamp(floor(tonumber(LootDB().rowHeight) or 30), 22, 44) end
local MONEY_SLOT = Enum and Enum.LootSlotType and Enum.LootSlotType.Money or LOOT_SLOT_MONEY or 2
local previewing = false

local function PlaceRow(row)
	row:ClearAllPoints()
	row:SetPoint('TOPLEFT', window.display.screen, 'TOPLEFT', 4, -(row.y + (row.rise or 0)))
	row:SetPoint('TOPRIGHT', window.display.screen, 'TOPRIGHT', -4, -(row.y + (row.rise or 0)))
end

local function WindowHeight(count)
	return 28 + 8 + max(count, 1) * (RowHeight() + ROW_GAP) - ROW_GAP + 8 + 40
end

local function LayoutRows(animate)
	local shown = {}
	for _, row in ipairs(rows) do if row.active then shown[#shown + 1] = row end end
	for index, row in ipairs(shown) do
		local target = 4 + (index - 1) * (RowHeight() + ROW_GAP)
		if not animate or row.y == nil then
			row.y = target
			PlaceRow(row)
		elseif row.y ~= target then
			Kit:Animate(row.glide, SPEED.NORMAL, row.y, target, function(value) row.y = value; PlaceRow(row) end, nil, 'cubic')
		end
	end
	local height = WindowHeight(#shown)
	if animate and window:IsShown() then
		Kit:Animate(window.sizeKey, SPEED.NORMAL, window:GetHeight(), height, function(value) window:SetHeight(value) end, nil, 'cubic')
	else
		window:SetHeight(height)
	end
	window.count:SetText(#shown == 1 and '1 item' or (#shown..' items'))
	return #shown
end

local function HideMasterLooter()
	local master = _G.MasterLooterFrame
	if master and master.Hide then master:Hide() end
end

local function RowClick(row, button)
	if previewing or not row.slot then return end
	local slot = row.slot
	if IsModifiedClick() then
		HandleModifiedItemClick(GetLootSlotLink(slot))
		return
	end
	-- The master looter's list reads the picked slot from Blizzard's own loot
	-- frame (and anchors to the picked row), as it does for its own buttons.
	local frame = _G.LootFrame
	if frame then
		frame.selectedSlot, frame.selectedQuality = slot, row.quality
		frame.selectedItemName, frame.selectedTexture = row.name:GetText(), row.key.icon:GetTexture()
		frame.selectedLootFrame, frame.selectedLootButton = row, row:GetName()
	end
	if StaticPopup_Hide then StaticPopup_Hide('CONFIRM_LOOT_DISTRIBUTION') end
	LootSlot(slot)
end

local function NewRow(index)
	local row = CreateFrame('Button', 'JiberishSpec01LootRow'..index, window.display.screen)
	row:SetHeight(RowHeight())
	row:RegisterForClicks('LeftButtonUp', 'RightButtonUp')
	row.hover = Kit:Solid(row, 'white', 'BACKGROUND', 1, 0)
	row.hover:SetAllPoints()
	row.key = IconKey(row, 26)
	row.key:SetPoint('LEFT', 2, 0)
	row.name = Kit:Text(row, '', 10, 'darkInk')
	row.name:SetPoint('LEFT', row.key, 'RIGHT', 8, 0)
	row.name:SetPoint('RIGHT', -16, 0)
	row.name:SetJustifyH('LEFT')
	row.name:SetWordWrap(false)
	row.lamp = Kit:Led(row, 5, false)
	row.lamp:SetPoint('RIGHT', -6, 0)
	row.glide, row.fade = {}, {}
	row:SetScript('OnEnter', function(self)
		self.hover:SetAlpha(0.07)
		if self.slot and not previewing and LootSlotHasItem and LootSlotHasItem(self.slot) then
			GameTooltip:SetOwner(self, 'ANCHOR_RIGHT')
			GameTooltip:SetLootItem(self.slot)
			if CursorUpdate then CursorUpdate(self) end
		end
	end)
	row:SetScript('OnLeave', function(self)
		self.hover:SetAlpha(0)
		GameTooltip:Hide()
		if ResetCursor then ResetCursor() end
	end)
	row:SetScript('OnMouseDown', function() Play('down') end)
	row:SetScript('OnClick', RowClick)
	return row
end

local function FillRow(row, data)
	row.slot, row.quality = data.slot, data.quality
	row.key.icon:SetTexture(data.icon)
	row.key.icon:SetDesaturated(data.locked and true or false)
	row.name:SetText(data.name or '')
	Kit:Tint(row.name, data.money and 'darkInk' or Quality(data.quality))
	if Kit.Alive and Kit:Alive('lcdPrint') then Kit:Print(row.name, {force = true, duration = 0.2, steps = 12}) end
	local count = Plain(data.count)
	row.key.count:SetText(type(count) == 'number' and count > 1 and count or '')
	-- Quest items carry an amber lamp.
	Kit:SetLed(row.lamp, data.quest and true or false, 'amber')
	Kit:ShowLed(row.lamp, data.quest and true or false)
end

local function SlotData(slot)
	local icon, name, count, _, quality, locked, isQuest, _, isActive = GetLootSlotInfo(slot)
	icon, name, locked, isQuest = Plain(icon), Plain(name), Plain(locked), Plain(isQuest)
	if not icon and not name then return end
	local money = GetLootSlotType and Plain(GetLootSlotType(slot)) == MONEY_SLOT
	if money and type(name) == 'string' then name = name:gsub('\n', ', ') end
	return {slot = slot, icon = icon, name = name, count = count, quality = quality, locked = locked, quest = isQuest,
		isActive = isActive, money = money}
end

-- Rows rise into place one after another.
local function Cascade()
	local index = 0
	for _, row in ipairs(rows) do
		if row.active then
			index = index + 1
			row:SetAlpha(0)
			row.rise = 6
			PlaceRow(row)
			C_Timer.After((index - 1) * 0.03, function()
				if not row.active then return end
				Kit:Animate(row.fade, SPEED.NORMAL, 0, 1, function(progress)
					row:SetAlpha(Kit.ease.sine(progress))
					row.rise = 6 * (1 - Kit.ease.cubic(progress))
					PlaceRow(row)
				end, nil, 'linear')
			end)
		end
	end
end

local function Populate(list)
	for index, data in ipairs(list) do
		local row = rows[index] or NewRow(index)
		rows[index] = row
		local height = RowHeight()
		if row:GetHeight() ~= height then
			row:SetHeight(height)
			row.key:SetSize(height - 4, height - 4)
			Kit:FitSprite(row.key.skin, height - 4, height - 4)
		end
		row.active, row.y, row.rise = true, nil, 0
		FillRow(row, data)
		row:Show()
	end
	for index = #list + 1, #rows do
		rows[index].active = false
		rows[index]:Hide()
	end
	LayoutRows(false)
end

local function OpenAtCursor()
	local cvar = (C_CVar and C_CVar.GetCVarBool) or GetCVarBool
	if cvar and cvar('lootUnderMouse') then
		local scale = window:GetEffectiveScale()
		local x, y = GetCursorPosition()
		window:ClearAllPoints()
		window:SetPoint('TOPLEFT', UIParent, 'BOTTOMLEFT', x / scale - 40, y / scale + 18)
	else
		UI:PlaceMover('nt.lootwindow')
	end
end

local function TakeAll()
	if previewing then return end
	for slot = (GetNumLootItems() or 0), 1, -1 do LootSlot(slot) end
end

local function BuildWindow()
	if window then return window end
	local w = Kit:Device(UIParent, {model = 'LT-1', title = 'Loot', surface = 'paper', radius = 12, name = 'JiberishSpec01LootFrame',
		width = LOOT_WIDTH, height = WindowHeight(1)})
	w:SetFrameStrata('HIGH')
	w:SetToplevel(true)
	w:EnableMouse(true)
	w:SetClampedToScreen(true)
	w:Hide()
	w.close = Kit:Key(w, {round = true, width = 18, height = 18, icon = 'close', iconSize = 8, onClick = function()
		if previewing then Kit:Close(w) else CloseLoot() end
	end})
	w.close:SetPoint('TOPRIGHT', -6, -4)
	w.title:SetPoint('RIGHT', w.close, 'LEFT', -6, 0)
	w.display = Kit:Screen(w, {inset = 3, radius = 8})
	w.display:SetPoint('TOPLEFT', 8, -28)
	w.display:SetPoint('BOTTOMRIGHT', -8, 40)
	w.take = Kit:Key(w, {tone = 'primary', width = 86, height = 22, text = 'Take all', textSize = 8, onClick = TakeAll})
	w.take:SetPoint('BOTTOMRIGHT', -8, 9)
	w.count = Kit:Label(w, '', 'dim', 8)
	w.count:SetPoint('BOTTOMLEFT', 14, 16)
	w.sizeKey = {}
	w:SetScale(Kit:Clamp(tonumber(LootDB().windowScale) or 1, 0.5, 2))
	-- Escape closes it like any window; closing it ends looting.
	tinsert(UISpecialFrames, 'JiberishSpec01LootFrame')
	w:SetScript('OnHide', function()
		if previewing then previewing = false return end
		if StaticPopup_Hide then StaticPopup_Hide('CONFIRM_LOOT_DISTRIBUTION') end
		CloseLoot()
		HideMasterLooter()
	end)
	w.SetPreview = function(self, on)
		if on and not self:IsShown() then module.Preview('loot')
		elseif not on and previewing then Kit:Close(self) end
	end
	window = w
	UI:RegisterMover(w, 'nt.lootwindow', 'Loot window', {'LEFT', 260, 120})
	return w
end

local function OnLootOpened()
	looting = true
	if not LootDB().window then return end
	BuildWindow()
	previewing = false
	local list = {}
	for slot = 1, GetNumLootItems() or 0 do
		local data = SlotData(slot)
		if data then list[#list + 1] = data end
	end
	-- Nothing to show: don't leave the player looting an empty corpse.
	if #list == 0 then return CloseLoot() end
	local target = Plain(UnitExists('target')) and Plain(UnitIsDead('target')) and Plain(UnitName('target'))
	window.title:SetText(strupper((IsFishingLoot and IsFishingLoot() and 'Fishing') or (type(target) == 'string' and target) or 'Loot'))
	Populate(list)
	OpenAtCursor()
	-- A reopen mid-close must start from where it is now placed.
	Kit:ResetRest(window)
	Kit:Open(window)
	window:Raise()
	Play('open')
	Cascade()
end

local function OnSlotCleared(slot)
	if not window or not window:IsShown() then return end
	for _, row in ipairs(rows) do
		if row.active and row.slot == slot then
			row.active = false
			Kit:Animate(row.fade, SPEED.FAST, row:GetAlpha(), 0, function(alpha) row:SetAlpha(alpha) end, function()
				if not row.active then row:Hide() end
			end, 'sine')
		end
	end
	LayoutRows(true)
end

local function OnSlotChanged(slot)
	if not window or not window:IsShown() then return end
	for _, row in ipairs(rows) do
		if row.active and row.slot == slot then
			local data = SlotData(slot)
			if data then FillRow(row, data) end
		end
	end
end

local function OnLootClosed()
	looting, lootClosedAt = false, GetTime()
	if StaticPopup_Hide then StaticPopup_Hide('LOOT_BIND') end
	HideMasterLooter()
	if window and window:IsShown() and not previewing then Kit:Close(window) end
end

-- Blizzard's loot frame no longer opens; the master looter's list (which
-- Forever hangs off that frame) moves to the screen so it can still show.
local function QuietGameLoot()
	local frame = _G.LootFrame
	if frame and frame.UnregisterEvent then
		for _, event in ipairs({'LOOT_OPENED', 'LOOT_SLOT_CLEARED', 'LOOT_SLOT_CHANGED', 'LOOT_READY'}) do
			pcall(frame.UnregisterEvent, frame, event)
		end
	end
	local master = _G.MasterLooterFrame
	if master and frame and master.GetParent and master:GetParent() == frame then master:SetParent(UIParent) end
end

-- Rolls --------------------------------------------------------------------------------
local rollHolder, rollFrames, rollPool = nil, {}, {}
local ROLL_WIDTH, ROLL_HEIGHT, ROLL_GAP = 320, 82, 8
local ROLL_KEYS = {
	{'need', 'Need', 'LOOT_ROLL_TYPE_NEED', 1, 'canNeed'},
	{'greed', 'Greed', 'LOOT_ROLL_TYPE_GREED', 2, 'canGreed'},
	{'disenchant', 'DE', 'LOOT_ROLL_TYPE_DISENCHANT', 3, 'canDisenchant'},
	{'transmog', 'Xmog', 'LOOT_ROLL_TYPE_TRANSMOG', 4, 'canTransmog'},
	{'pass', 'Pass', 'LOOT_ROLL_TYPE_PASS', 0},
}

local function PlaceRoll(frame)
	frame:ClearAllPoints()
	frame:SetPoint('BOTTOM', rollHolder, 'BOTTOM', 0, (frame.y or 0) - (frame.sink or 0))
end

local function LayoutRolls()
	local y = 0
	for _, frame in ipairs(rollFrames) do
		local target = y
		y = y + ROLL_HEIGHT + ROLL_GAP
		if frame.y == nil then
			frame.y = target
			PlaceRoll(frame)
		elseif frame.y ~= target then
			Kit:Animate(frame.glide, SPEED.NORMAL, frame.y, target, function(value) frame.y = value; PlaceRoll(frame) end, nil, 'cubic')
		end
	end
end

local function RemoveRoll(frame)
	if frame.leaving then return end
	frame.leaving = true
	frame:SetScript('OnUpdate', nil)
	Kit:Animate(frame.fade, SPEED.CLOSE, 0, 1, function(progress)
		frame:SetAlpha(1 - Kit.ease.inout(progress))
		frame.sink = 4 * Kit.ease.cubic(progress)
		PlaceRoll(frame)
	end, function()
		frame:Hide()
		frame.rollID, frame.sink = nil, 0
		for index, other in ipairs(rollFrames) do
			if other == frame then table.remove(rollFrames, index); break end
		end
		rollPool[#rollPool + 1] = frame
		LayoutRolls()
	end, 'linear')
end

local function RollTick(frame, elapsed)
	frame.throttle = (frame.throttle or 0) + elapsed
	if frame.throttle < 0.1 then return end
	frame.throttle = 0
	local left
	if frame.preview then
		frame.previewLeft = (frame.previewLeft or 0) - 0.1
		left = frame.previewLeft * 1000
		if left <= 0 then return RemoveRoll(frame) end
	else
		left = Plain(GetLootRollTimeLeft(frame.rollID))
		if type(left) == 'number' and left <= 0 then return RemoveRoll(frame) end
	end
	if type(left) ~= 'number' then return end
	local fraction = frame.total > 0 and left / frame.total or 0
	Kit:SetDots(frame.dots, fraction, fraction < 0.25 and 'amber' or 'lamp')
end

local function BuildRollHolder()
	if rollHolder then return rollHolder end
	rollHolder = CreateFrame('Frame', nil, UIParent)
	rollHolder:SetSize(ROLL_WIDTH, ROLL_HEIGHT)
	rollHolder:SetFrameStrata('HIGH')
	rollHolder:SetScale(Kit:Clamp(tonumber(LootDB().rollScale) or 1, 0.5, 2))
	rollHolder.SetPreview = function(_, on) if on then module.Preview('roll') end end
	UI:RegisterMover(rollHolder, 'nt.rolls', 'Loot rolls', {'BOTTOM', 0, 300})
	return rollHolder
end

local function NewRoll()
	local frame = Kit:Device(BuildRollHolder(), {model = 'RL-1', title = 'Roll', surface = 'paper', radius = 12, width = ROLL_WIDTH,
		height = ROLL_HEIGHT})
	frame:EnableMouse(true)
	frame.key = IconKey(frame, 40)
	frame.key:SetPoint('TOPLEFT', 10, -26)
	frame.key:EnableMouse(true)
	frame.key:SetScript('OnEnter', function(self)
		if frame.preview or not frame.rollID then return end
		GameTooltip:SetOwner(self, 'ANCHOR_RIGHT')
		GameTooltip:SetLootRollItem(frame.rollID)
		if CursorUpdate then CursorUpdate(self) end
	end)
	frame.key:SetScript('OnLeave', function() GameTooltip:Hide(); if ResetCursor then ResetCursor() end end)
	frame.key:SetScript('OnMouseUp', function()
		if not frame.preview and frame.rollID and IsModifiedClick() then HandleModifiedItemClick(GetLootRollItemLink(frame.rollID)) end
	end)
	frame.name = Kit:Text(frame, '', 11, 'ink', true)
	frame.name:SetPoint('TOPLEFT', frame.key, 'TOPRIGHT', 10, -2)
	frame.name:SetPoint('RIGHT', -12, 0)
	frame.name:SetJustifyH('LEFT')
	frame.name:SetWordWrap(false)
	frame.keys = {}
	local x = 0
	for _, spec in ipairs(ROLL_KEYS) do
		local rollType = _G[spec[3]] or spec[4]
		local key = Kit:Key(frame, {tone = spec[1] == 'need' and 'primary' or 'dark', width = 46, height = 20, text = spec[2], textSize = 8,
			onClick = function()
				if frame.preview then return RemoveRoll(frame) end
				if frame.rollID then RollOnLoot(frame.rollID, rollType) end
			end})
		key:SetPoint('TOPLEFT', frame.key, 'TOPRIGHT', 10 + x, -20)
		x = x + 50
		key.spec = spec
		frame.keys[#frame.keys + 1] = key
	end
	frame.dots = Kit:DotLine(frame, 44, 3, 4)
	frame.dots:SetPoint('BOTTOM', 0, 8)
	frame.glide, frame.fade = {}, {}
	return frame
end

-- data: rollID, total (ms), texture, name, count, quality, and the can* flags; preview for samples.
local function AddRoll(data)
	BuildRollHolder()
	local frame = table.remove(rollPool) or NewRoll()
	frame.rollID, frame.total, frame.preview, frame.previewLeft = data.rollID, data.total or 1, data.preview, data.total and data.total / 1000
	frame.leaving, frame.y, frame.sink = nil, nil, 0
	frame.key.icon:SetTexture(data.texture)
	local count = Plain(data.count)
	frame.key.count:SetText(type(count) == 'number' and count > 1 and count or '')
	frame.name:SetText(data.name or '')
	Kit:Tint(frame.name, Quality(data.quality))
	for _, key in ipairs(frame.keys) do
		local flag = key.spec[5]
		key:SetKeyEnabled(not flag or data[flag] and true or false)
	end
	-- Transmog takes greed's place when it is offered, as the game does.
	if data.canTransmog then frame.keys[2]:SetKeyEnabled(false) end
	frame.dots.lit = -1
	Kit:SetDots(frame.dots, 1)
	table.insert(rollFrames, 1, frame)
	LayoutRolls()
	frame:SetAlpha(0)
	frame:Show()
	frame:SetScript('OnUpdate', RollTick)
	Kit:Animate(frame.fade, SPEED.SLOW, 0, 1, function(progress)
		frame:SetAlpha(Kit.ease.sine(min(progress * 2, 1)))
		frame.sink = -8 * (1 - Kit.ease.cubic(progress))
		PlaceRoll(frame)
	end, nil, 'linear')
	Play('open')
end

local function OnStartRoll(rollID, total)
	if not LootDB().rolls then return end
	if IsSecret(rollID) then return end
	local texture, name, count, quality, _, canNeed, canGreed, canDisenchant, _, _, _, _, canTransmog = GetLootRollItemInfo(rollID)
	name, canNeed, canGreed, canDisenchant, canTransmog = Plain(name), Plain(canNeed), Plain(canGreed), Plain(canDisenchant), Plain(canTransmog)
	if not name then return end
	for _, frame in ipairs(rollFrames) do if frame.rollID == rollID then return end end
	AddRoll({rollID = rollID, total = Plain(total) or Plain(GetLootRollTimeLeft(rollID)) or 60000, texture = texture, name = name,
		count = count, quality = quality, canNeed = canNeed, canGreed = canGreed, canDisenchant = canDisenchant, canTransmog = canTransmog})
end

-- Over a copy: with reduce motion on, a removal finishes (and leaves the list) at once.
local function RemoveRolls(match)
	local copy = {}
	for index, frame in ipairs(rollFrames) do copy[index] = frame end
	for _, frame in ipairs(copy) do
		if match(frame) then RemoveRoll(frame) end
	end
end

local function OnCancelRoll(rollID)
	RemoveRolls(function(frame) return frame.rollID == rollID end)
end

local function QuietGameRolls()
	if type(UnregisterInternalEvent) == 'function' then pcall(UnregisterInternalEvent, 'START_LOOT_ROLL') end
	pcall(UIParent.UnregisterEvent, UIParent, 'START_LOOT_ROLL')
	if _G.GroupLootContainer then UI:Retire(_G.GroupLootContainer, true) end
	for index = 1, 4 do
		local frame = _G['GroupLootFrame'..index]
		if frame then UI:Retire(frame, true) end
	end
end

-- Blizzard alerts ----------------------------------------------------------------------
-- What is left of the game's alert frames (loot won, money, followers...) gets
-- a glass shell behind its own art; the achievement alert gives way to our banner.
local dressed = setmetatable({}, {__mode = 'k'})
local function Relight(frame)
	for _, region in ipairs({frame:GetRegions()}) do
		if region.IsObjectType and region:IsObjectType('FontString') then
			local ok, r, g, b = pcall(region.GetTextColor, region)
			if ok and not IsSecret(r) and r and r + g + b < 1.2 then region:SetTextColor(0.92, 0.92, 0.88) end
			local path, size = region:GetFont()
			if not IsSecret(size) and path and size then region:SetFont(Kit:FontPath(true), max(size - 1, 8), '') end
		end
	end
end

local function DressAlert(frame)
	if type(frame) ~= 'table' or (frame.IsForbidden and frame:IsForbidden()) then return end
	-- The game's achievement alert, when ours already announced it.
	if Wants('achievement') and frame.Shield and frame.Unlocked and frame.Name then
		C_Timer.After(0, function()
			if frame.animIn and frame.animIn.Stop then frame.animIn:Stop() end
			if frame.waitAndAnimOut and frame.waitAndAnimOut.Stop then frame.waitAndAnimOut:Stop() end
			frame:Hide()
		end)
		return
	end
	if dressed[frame] then return end
	dressed[frame] = true
	local width = frame:GetWidth()
	if IsSecret(width) then return end
	-- Large backgrounds and borders give way to the shell; icons stay.
	for _, region in ipairs({frame:GetRegions()}) do
		if region.IsObjectType and region:IsObjectType('Texture') then
			local layer = region:GetDrawLayer()
			local w = region:GetWidth()
			if (layer == 'BACKGROUND' or layer == 'BORDER') and not IsSecret(w) and w > width * 0.6 then region:SetAlpha(0) end
		end
	end
	for _, key in ipairs({'glow', 'shine'}) do
		local texture = frame[key]
		if type(texture) == 'table' and texture.SetTexture then texture:SetTexture(nil) end
	end
	Kit:Shell(frame, {surface = 'glass', radius = 10})
	Relight(frame)
end

local function DressAlerts()
	local alerts = _G.AlertFrame
	if type(alerts) == 'table' and type(alerts.AddAlertFrame) == 'function' then
		hooksecurefunc(alerts, 'AddAlertFrame', function(_, frame) UI:Safe(DressAlert, frame) end)
	end
end

-- Previews -----------------------------------------------------------------------------
local SAMPLE_LOOT = {
	{icon = 133784, name = '2 Gold, 14 Silver', money = true},
	{icon = 135274, name = 'Edge of the Vigil', quality = 4},
	{icon = 132944, name = 'Ironweave Cord', quality = 3},
	{icon = 134377, name = 'Linen Cloth', quality = 1, count = 7},
	{icon = 133940, name = 'Quest Seal', quality = 1, quest = true},
}

function module.Preview(kind)
	if kind == 'levelup' then
		local level = Plain(UnitLevel('player')) or 60
		Push({kind = 'levelup', model = 'LV-1', title = 'Level up', layout = 'lcd', lcd = {value = level, tag = 'LVL', count = true},
			head = format('Level %d', level), line1 = Gains(42, 30, 2, 1, 3, 1), line2 = 'A new talent point to spend', sound = 'success', hold = 5})
	elseif kind == 'quest' then
		Push({kind = 'quest', model = 'QT-1', title = 'Quest complete', layout = 'icon', glyph = 'check', lamp = 'green',
			head = 'The Signal in the Static', line1 = '1,250 XP  ·  '..(Money(31500) or ''), sound = 'success', hold = 3.5})
	elseif kind == 'achievement' then
		Push({kind = 'achievement', model = 'AC-1', title = 'Achievement', layout = 'icon', icon = 236670, head = 'Calibrated',
			line1 = 'Explore every room of the device lab.', chip = {value = 10, tag = 'Pts'}, sound = 'success', hold = 5})
	elseif kind == 'zone' then
		local pvp, lamp = ZonePvP()
		Push({kind = 'zone', replace = 'zone', model = 'NV-1', title = 'Location', layout = 'center',
			head = Plain(GetZoneText()) or 'Somewhere', line1 = Plain(GetSubZoneText()) or '', line2 = pvp, lamp = lamp, sound = 'blip', hold = 3})
	elseif kind == 'rep' then
		Push({kind = 'rep', merge = 'rep:sample', model = 'RP-1', title = 'Reputation', layout = 'compact', head = 'The Assembly',
			line1 = '+250  ·  Honored', meter = 0.62, lamp = 'green', sound = 'tick', hold = 3})
	elseif kind == 'loot' then
		BuildWindow()
		previewing = true
		local list = {}
		for index, data in ipairs(SAMPLE_LOOT) do
			list[index] = {slot = nil, icon = data.icon, name = data.name, quality = data.quality, count = data.count,
				quest = data.quest, money = data.money}
		end
		window.title:SetText('LOOT')
		Populate(list)
		UI:PlaceMover('nt.lootwindow')
		Kit:ResetRest(window)
		Kit:Open(window)
		Play('open')
		Cascade()
	elseif kind == 'roll' then
		AddRoll({preview = true, total = 15000, texture = 135274, name = 'Edge of the Vigil', quality = 4, canNeed = true,
			canGreed = true, canDisenchant = true})
	elseif kind == 'feed' then
		AddLoot({key = 'preview:1', name = 'Linen Cloth', quality = 1, icon = 134377, count = 3}, true)
		C_Timer.After(0.25, function() AddLoot({key = 'preview:2', name = 'Ironweave Cord', quality = 3, icon = 132944}, true) end)
		C_Timer.After(0.5, function() AddLoot({key = 'money', money = 21400, icon = 'Interface\\MoneyFrame\\UI-GoldIcon'}, true) end)
		C_Timer.After(0.8, function() AddLoot({key = 'preview:1', count = 2}, true) end)
	end
end
UI.Notifications = module

-- Wiring -------------------------------------------------------------------------------
local handlers = {
	PLAYER_LEVEL_UP = LevelUp,
	QUEST_TURNED_IN = QuestTurnedIn,
	QUEST_ACCEPTED = QuestAccepted,
	QUEST_COMPLETE = function()
		local questID, title = GetQuestID and Plain(GetQuestID()), GetTitleText and Plain(GetTitleText())
		if questID and type(title) == 'string' and title ~= '' then questTitles[questID] = title end
	end,
	ACHIEVEMENT_EARNED = Achievement,
	ZONE_CHANGED_NEW_AREA = function() Zone(true) end,
	ZONE_CHANGED = function() Zone(false) end,
	ZONE_CHANGED_INDOORS = function() Zone(false) end,
	PLAYER_ENTERING_WORLD = function(isLogin)
		lastMoney = Plain(GetMoney())
		QuietZoneText()
		if isLogin == true then C_Timer.After(1, function() UI:Safe(Zone, true) end)
		else lastZone, lastSub = Plain(GetZoneText()), Plain(GetSubZoneText()) end
	end,
	CHAT_MSG_COMBAT_FACTION_CHANGE = Reputation,
	CHAT_MSG_LOOT = OnLootMessage,
	CHAT_MSG_CURRENCY = OnCurrencyMessage,
	PLAYER_MONEY = OnMoney,
	LOOT_OPENED = OnLootOpened,
	LOOT_SLOT_CLEARED = OnSlotCleared,
	LOOT_SLOT_CHANGED = OnSlotChanged,
	LOOT_CLOSED = OnLootClosed,
	START_LOOT_ROLL = OnStartRoll,
	CANCEL_LOOT_ROLL = OnCancelRoll,
	CANCEL_ALL_LOOT_ROLLS = function() RemoveRolls(function() return true end) end,
	-- The fight starts before lockdown does, so trust the event.
	PLAYER_REGEN_DISABLED = function() inCombat = true end,
	PLAYER_REGEN_ENABLED = function() inCombat = false; Next() end,
	CINEMATIC_START = function() inCinematic = true end,
	CINEMATIC_STOP = function() inCinematic = false; Next() end,
	PLAY_MOVIE = function() inCinematic = true end,
	STOP_MOVIE = function() inCinematic = false; Next() end,
}

function module:Enable()
	active = true
	inCombat = InCombatLockdown() and true or false
	lastMoney = Plain(GetMoney())
	local db = LootDB()
	if db.window then BuildWindow(); QuietGameLoot() end
	if db.rolls then QuietGameRolls() end
	QuietGameLevelUp()
	if db.alerts ~= false then DressAlerts() end
	local driver = CreateFrame('Frame')
	for event in pairs(handlers) do pcall(driver.RegisterEvent, driver, event) end
	driver:SetScript('OnEvent', function(_, event, ...)
		local handler = handlers[event]
		if handler then UI:Safe(handler, ...) end
	end)
	-- Rolls already running when the interface loaded.
	if db.rolls and GetActiveLootRollIDs then
		for _, rollID in ipairs(GetActiveLootRollIDs() or {}) do UI:Safe(OnStartRoll, rollID) end
	end
end

function module:Refresh()
	QuietZoneText()
	local db = LootDB()
	if banner then UI:SetMoverBaseScale('nt.banner', Kit:Clamp(tonumber(UI.db.banners.scale) or 1, 0.5, 2), banner) end
	if window then UI:SetMoverBaseScale('nt.lootwindow', Kit:Clamp(tonumber(db.windowScale) or 1, 0.5, 2), window) end
	if rollHolder then UI:SetMoverBaseScale('nt.rolls', Kit:Clamp(tonumber(db.rollScale) or 1, 0.5, 2), rollHolder) end
	if feed then
		for _, chip in ipairs(chips) do PlaceChip(chip) end
		LayoutChips()
	end
	UI:PlaceMover('nt.banner')
end

-- Settings ------------------------------------------------------------------------------
-- Which banners show, and the loot devices themselves, are on the Notifications
-- page; this page tunes them.
local VOICES = {{'success', 'Success'}, {'open', 'Pop-up'}, {'blip', 'Blip'}, {'tick', 'Tick'}, {'latch-down', 'Latch'},
	{'down-primary', 'Key'}, {'warning', 'Warning'}, {'off', 'Off'}}
local function Seconds(v) return v..' s' end
local function Percent(v) return format('%d%%', v * 100 + 0.5) end

local function BannerRows(key, label, note)
	return {'slider', label..' time', 'banners.'..key..'.hold', 1, 12, 0.5, note, format = Seconds},
		{'dropdown', label..' sound', 'banners.'..key..'.sound', items = VOICES}
end

local bannerRows = {
	{'slider', 'Banner size', 'banners.scale', 0.6, 1.6, 0.05, 'Place the banner with /spec move.', format = Percent},
	{'button', 'Try it', 'Level up', function() module.Preview('levelup') end},
}
for _, spec in ipairs({{'levelUp', 'Level up'}, {'quest', 'Quest complete'}, {'questAccept', 'Quest accepted'},
	{'achievement', 'Achievement'}, {'zone', 'Zone'}, {'reputation', 'Reputation'}}) do
	local hold, sound = BannerRows(spec[1], spec[2])
	bannerRows[#bannerRows + 1] = hold
	bannerRows[#bannerRows + 1] = sound
end
local subHold, subSound = BannerRows('subzone', 'Subzone')
bannerRows[#bannerRows + 1] = {'switch', 'Subzones', 'banners.subzone.enable', 'A smaller banner as you move between parts of a zone.'}
bannerRows[#bannerRows + 1] = subHold
bannerRows[#bannerRows + 1] = subSound

UI:RegisterPage('banners', {title = 'Banners and loot', order = 22, cards = {
	{title = 'Banners', rows = bannerRows},
	{title = 'Loot window', rows = {
		{'slider', 'Window size', 'loot.windowScale', 0.6, 1.6, 0.05, nil, format = Percent},
		{'slider', 'Row height', 'loot.rowHeight', 22, 44, 1, 'Each item\'s row; its key grows with it.'},
		{'slider', 'Roll size', 'loot.rollScale', 0.6, 1.6, 0.05, 'The need and greed devices.', format = Percent},
		{'switch', 'Alert skin', 'loot.alerts', 'The game\'s remaining alerts (loot won, money, followers) on dark glass.', reload = true},
		{'button', 'Try it', 'Loot', function() module.Preview('loot') end},
	}},
	{title = 'Loot feed', rows = {
		{'slider', 'Chips shown', 'loot.feedMax', 1, 12, 1, 'At most this many at once; the oldest leave first.'},
		{'segmented', 'Direction', 'loot.feedGrow', items = {{'up', 'Up'}, {'down', 'Down'}}, note = 'Which way new chips stack from the feed\'s spot.'},
		{'slider', 'Time on screen', 'loot.feedLife', 2, 20, 1, nil, format = Seconds},
		{'segmented', 'Lowest quality', 'loot.feedQuality', items = {{0, 'All'}, {1, 'Common'}, {2, 'Uncommon'}, {3, 'Rare'}, {4, 'Epic'}},
			note = 'Items below it stay out of the feed.'},
		{'switch', 'Coins', 'loot.feedMoney', 'Gold, silver and copper you loot.'},
		{'button', 'Try it', 'Feed', function() module.Preview('feed') end},
	}},
}})
