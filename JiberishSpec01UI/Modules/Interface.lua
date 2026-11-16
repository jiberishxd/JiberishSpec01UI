-- Tooltips as SPEC-01 dark glass, and the game's own interface sounds
-- answered with SPEC-01 voices.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, GetTime = CreateFrame, GetTime
local function IsSecret(value) return issecretvalue and issecretvalue(value) end
local function Forbidden(object)
	if type(object) ~= 'table' then return true end
	if object.IsForbidden then
		local ok, forbidden = pcall(object.IsForbidden, object)
		return not ok or forbidden
	end
	return false
end

-- Interface sounds ------------------------------------------------------------------
-- One sound per thing that happens. Blizzard plays its own click for many of
-- the same moments this addon answers (a window opening, a tab, a checkbox),
-- so both go through here: sounds of one family from different sources within
-- 0.15 s are heard once, and the same voice never repeats within 0.08 s.
-- family: 'window', 'press', 'check', 'tab', 'scroll', 'menu' or the voice.
-- source: 'game' (the PlaySound mapping) or 'skin' (this addon's widgets).
-- kind: the Sounds page choice it follows; worked out from the family if not given.
--
-- Each kind of sound is 'spec' (ours, the game's own muted), 'game' (the
-- game's only), 'both' or 'off' (neither).
local FAMILY_KIND = {window = 'windows', menu = 'menus', tab = 'tabs', check = 'checkboxes', press = 'buttons', scroll = 'buttons',
	loot = 'loot', alert = 'alerts'}

function UI:SoundMode(kind)
	local kinds = self.db.sound.kinds
	return kinds and kinds[kind] or 'spec'
end

-- Whether our sounds for a kind are heard: 'spec' and 'both', with sounds on.
function UI:SpecSounds(kind)
	local db = self.db.sound
	if not (db and db.enable and db.interface) then return false end
	local mode = self:SoundMode(kind)
	return mode == 'spec' or mode == 'both'
end

local lastTime, lastSource, lastVoice = {}, {}, {}
function UI:InterfaceSound(voice, family, source, kind)
	family = family or voice
	kind = kind or FAMILY_KIND[family]
	if kind then
		if not self:SpecSounds(kind) then return end
	else
		local db = self.db.sound
		if not (db and db.enable and db.interface) then return end
	end
	local now = GetTime()
	if lastSource[family] and lastSource[family] ~= source and now - lastTime[family] < 0.15 then return end
	if now - (lastVoice[voice] or 0) < 0.08 then return end
	lastTime[family], lastSource[family], lastVoice[voice] = now, source, now
	Kit:Play(voice, true)
end

-- Tooltips -----------------------------------------------------------------------------
local tooltip = UI:RegisterModule('tooltip', {})

local shells = setmetatable({}, {__mode = 'k'}) -- tooltip -> its glass
local lines = setmetatable({}, {__mode = 'k'})  -- tooltip -> its quality line

local function ClearLine(tip)
	local line = lines[tip]
	if line then line:Hide() end
end

local function SkinTooltip(tip, _, embedded)
	if Forbidden(tip) or embedded or tip.IsEmbedded then return end
	if not Forbidden(tip.NineSlice) then tip.NineSlice:SetAlpha(0) end
	if shells[tip] then return end
	-- Dark glass with a lit 1 px edge, drawn from code in physical pixels.
	local shell = Kit:Shell(tip, {surface = 'glass', edge = 'darkEdge', radius = 6, shadowAlpha = 0.5})
	shells[tip] = shell
	local line = shell:CreateTexture(nil, 'ARTWORK')
	line:SetColorTexture(1, 1, 1, 1)
	line:SetPoint('TOPLEFT', tip, 'TOPLEFT', 7, -1)
	line:SetPoint('TOPRIGHT', tip, 'TOPRIGHT', -7, -1)
	line:SetHeight(UI.Pixel.Px(tip, 2))
	line:Hide()
	lines[tip] = line
	if tip.HasScript and tip:HasScript('OnTooltipCleared') then
		tip:HookScript('OnTooltipCleared', ClearLine)
	end
	tip:HookScript('OnHide', ClearLine)
end

-- Item tooltips: the quality color as a lamp line along the top.
local function ItemLine(tip, data)
	local line = lines[tip]
	if not line then return end
	local id = type(data) == 'table' and data.id
	if IsSecret(id) or not id then return ClearLine(tip) end
	local quality = C_Item and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(id)
	if not IsSecret(quality) and not quality and tip.GetItem then
		local ok, _, link = pcall(tip.GetItem, tip)
		if ok and not IsSecret(link) and link and C_Item and C_Item.GetItemQualityByID then quality = C_Item.GetItemQualityByID(link) end
	end
	if IsSecret(quality) or not quality then return ClearLine(tip) end
	local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
	if not color then return ClearLine(tip) end
	line:SetVertexColor(color.r, color.g, color.b, 1)
	line:Show()
end

local TIPS = {'GameTooltip', 'ItemRefTooltip', 'ShoppingTooltip1', 'ShoppingTooltip2', 'ItemRefShoppingTooltip1',
	'ItemRefShoppingTooltip2', 'FriendsTooltip', 'QuickKeybindTooltip', 'GameSmallHeaderTooltip', 'EmbeddedItemTooltip',
	'WorldMapTooltip', 'WorldMapCompareTooltip1', 'WorldMapCompareTooltip2', 'NamePlateTooltip', 'SettingsTooltip',
	'LibDBIconTooltip', 'AceGUITooltip'}

local function Fonts()
	if _G.GameTooltipHeaderText then Kit:Font(_G.GameTooltipHeaderText, 13, '', true) end
	if _G.GameTooltipText then Kit:Font(_G.GameTooltipText, 12, '', false) end
	if _G.GameTooltipTextSmall then Kit:Font(_G.GameTooltipTextSmall, 10, '', false) end
end

function tooltip:Enable()
	if SharedTooltip_SetBackdropStyle then
		hooksecurefunc('SharedTooltip_SetBackdropStyle', function(tip, _, embedded) UI:Safe(SkinTooltip, tip, nil, embedded) end)
	end
	local processor = _G.TooltipDataProcessor
	if processor and processor.AddTooltipPostCall then
		if processor.AllTypes then
			processor.AddTooltipPostCall(processor.AllTypes, function(tip) UI:Safe(SkinTooltip, tip) end)
		end
		local types = Enum and Enum.TooltipDataType
		if types and types.Item then
			processor.AddTooltipPostCall(types.Item, function(tip, data) UI:Safe(ItemLine, tip, data) end)
		end
	end
	for _, name in ipairs(TIPS) do
		local tip = _G[name]
		-- The embedded item tooltip sits inside another tooltip's glass.
		if type(tip) == 'table' and not Forbidden(tip) and name ~= 'EmbeddedItemTooltip' and tip.HookScript then
			UI:Safe(SkinTooltip, tip)
			tip:HookScript('OnShow', function(self) UI:Safe(SkinTooltip, self) end)
		end
	end
	local bar = _G.GameTooltipStatusBar
	if bar and not Forbidden(bar) then
		for _, region in ipairs({bar:GetRegions()}) do
			if region ~= bar:GetStatusBarTexture() and region.IsObjectType and region:IsObjectType('Texture') then region:SetAlpha(0) end
		end
		UI:Safe(Kit.Perforate, Kit, bar, 'glass', 'darkEdge')
	end
	Fonts()
end

-- Interface sounds -------------------------------------------------------------------
-- Blizzard's clicks are mapped onto the SPEC-01 voices, so every checkbox, tab
-- and window in the game answers with the same switches as the kit.
--
-- Each game sound kit: our voice, then the game's own sound files for it (file
-- data IDs from the game's SoundKitEntry table; kits by their SOUNDKIT name).
-- A kind set to 'spec' or 'off' mutes those files with MuteSoundFile. A mute
-- lasts until the game client restarts, so it is redone at every login, and
-- the saved list of what this addon muted means only those files are ever
-- unmuted (that list is account state, see State below). Some files serve several kinds (one click sound is the checkbox,
-- the menu and the chat scroll sound), so a file is muted only when every
-- kind that uses it asks for that.
local sounds = UI:RegisterModule('sounds', {always = true})
local KITS = {
	windows = {
		IG_MAINMENU_OPEN = {'open', 567490},
		IG_MAINMENU_CLOSE = {'latch-up', 567464},
		IG_MAINMENU_QUIT = {'latch-up', 567481},
		IG_MAINMENU_LOGOUT = {'latch-up', 567481},
		IG_MAINMENU_CONTINUE = {'latch-up', 567481},
		IG_CHARACTER_INFO_OPEN = {'open', 567507},
		IG_CHARACTER_INFO_CLOSE = {'latch-up', 567433},
		IG_BACKPACK_OPEN = {'open', 567461},
		IG_BACKPACK_CLOSE = {'latch-up', 567512},
		IG_SPELLBOOK_OPEN = {'open', 567440},
		IG_SPELLBOOK_CLOSE = {'latch-up', 567496},
		IG_ABILITY_OPEN = {'open', 567440},
		IG_ABILITY_CLOSE = {'latch-up', 567496},
		IG_QUEST_LOG_OPEN = {'open', 567504},
		IG_QUEST_LOG_CLOSE = {'latch-up', 567508},
		IG_QUEST_LIST_OPEN = {'open', 567504},
		IG_QUEST_LIST_CLOSE = {'latch-up', 567508},
		IG_MINIMAP_OPEN = {'open', 567529},
		IG_MINIMAP_CLOSE = {'latch-up', 567515},
		UI_PROFESSIONS_WINDOW_OPEN = {'open', 567507},
		UI_PROFESSIONS_WINDOW_CLOSE = {'latch-up', 567433},
		ACHIEVEMENT_MENU_OPEN = {'open', 567511},
		ACHIEVEMENT_MENU_CLOSE = {'latch-up', 567509},
		AUCTION_WINDOW_OPEN = {'open', 567482},
		AUCTION_WINDOW_CLOSE = {'latch-up', 567499},
		GUILD_VAULT_OPEN = {'open', 567485},
		GUILD_VAULT_CLOSE = {'latch-up', 567510},
		UI_TRANSMOG_OPEN_WINDOW = {'open', 537908},
		UI_TRANSMOG_CLOSE_WINDOW = {'latch-up', 537906},
		UI_CLASS_TALENT_OPEN_WINDOW = {'open', 567507},
		UI_CLASS_TALENT_CLOSE_WINDOW = {'latch-up', 567433},
		MONEY_FRAME_OPEN = {'open', 567483},
		MONEY_FRAME_CLOSE = {'latch-up', 567501},
	},
	menus = {
		U_CHAT_SCROLL_BUTTON = {'blip', 567407},
	},
	tabs = {
		IG_CHARACTER_INFO_TAB = {'tick', 567422},
		IG_ABILITY_PAGE_TURN = {'tick', 567472, 567502, 567457},
		IG_MAINMENU_OPTION_FAER_TAB = {'tick', 567407},
		UI_TOYBOX_TABS = {'tick', 567422},
		UI_TRANSMOG_PAGE_TURN = {'tick', 567472, 567502, 567457},
		IG_QUEST_LIST_SELECT = {'blip', 567508},
	},
	checkboxes = {
		IG_MAINMENU_OPTION_CHECKBOX_ON = {'latch-down', 567407},
		IG_MAINMENU_OPTION_CHECKBOX_OFF = {'latch-up', 567407},
	},
	buttons = {
		IG_MAINMENU_OPTION = {'down', 567481},
		GS_TITLE_OPTION_OK = {'down', 567407},
		GS_TITLE_OPTION_EXIT = {'down', 567407},
		IG_CHAT_EMOTE_BUTTON = {'down', 567481},
		IG_CHAT_SCROLL_UP = {'tick', 567407},
		IG_CHAT_SCROLL_DOWN = {'tick', 567407},
		IG_CHAT_BOTTOM = {'tick', 567407},
		IG_MINIMAP_ZOOM_IN = {'tick', 567467},
		IG_MINIMAP_ZOOM_OUT = {'tick', 567467},
	},
	loot = {
		LOOT_WINDOW_COIN_SOUND = {'blip', 567428},
		LOOT_WINDOW_OPEN_EMPTY = {'blip', 567444},
		UI_EPICLOOT_TOAST = {'success', 642829},
		UI_LEGENDARY_LOOT_TOAST = {'success', 1489461},
		UI_RAID_LOOT_TOAST_LESSER_ITEM_WON = {'success', 1138111},
	},
	alerts = {
		READY_CHECK = {'warning', 567478},
		RAID_WARNING = {'warning', 567397},
		TELL_MESSAGE = {'blip', 567421},
		LFG_ROLE_CHECK = {'warning', 567513},
		IG_PLAYER_INVITE = {'open', 567451},
	},
}
local KIND_FAMILY = {windows = 'window', menus = 'menu', tabs = 'tab', checkboxes = 'check', loot = 'loot'}
local KINDS = {'windows', 'menus', 'tabs', 'checkboxes', 'buttons', 'errors', 'quest', 'loot', 'alerts'}

local function Muting(kind)
	local mode = UI:SoundMode(kind)
	if mode == 'off' then return true end
	-- With our sounds off, 'spec' would leave silence: the game's play instead.
	return mode == 'spec' and UI:SpecSounds(kind)
end

local function WantedMutes()
	local users = {}
	for kind, kits in pairs(KITS) do
		for name, entry in pairs(kits) do
			if SOUNDKIT and SOUNDKIT[name] then
				for index = 2, #entry do
					local file = entry[index]
					users[file] = users[file] or {}
					users[file][kind] = true
				end
			end
		end
	end
	local wanted = {}
	for file, kinds in pairs(users) do
		local all = true
		for kind in pairs(kinds) do
			if not Muting(kind) then all = false break end
		end
		if all then wanted[file] = true end
	end
	return wanted
end

-- What this addon muted and the player's own error-speech setting are about
-- the game client, not a profile: they live in the account table, which a
-- profile switch, reset or import never replaces. Older saves kept them in
-- the profile; they move over once.
local function State()
	local state = UI:Account('sound')
	local db = UI.db.sound
	if type(db.muted) == 'table' then
		state.muted = type(state.muted) == 'table' and state.muted or {}
		for file in pairs(db.muted) do state.muted[file] = true end
	end
	db.muted = nil
	if db.errorSpeechWas ~= nil then
		if state.errorSpeechWas == nil then state.errorSpeechWas = db.errorSpeechWas end
		db.errorSpeechWas = nil
	end
	if type(state.muted) ~= 'table' then state.muted = {} end
	return state
end

local function ApplyMutes()
	if not (MuteSoundFile and UnmuteSoundFile) then return end
	local state = State()
	local wanted = WantedMutes()
	-- Every file this addon knows is unmuted unless wanted (unmuting one that
	-- is not muted does nothing), plus anything an older version muted.
	for _, kits in pairs(KITS) do
		for _, entry in pairs(kits) do
			for index = 2, #entry do
				if not wanted[entry[index]] then pcall(UnmuteSoundFile, entry[index]) end
			end
		end
	end
	for file in pairs(state.muted) do
		if not wanted[file] then
			pcall(UnmuteSoundFile, file)
			state.muted[file] = nil
		end
	end
	for file in pairs(wanted) do
		pcall(MuteSoundFile, file)
		state.muted[file] = true
	end
end

-- Errors: the character's spoken error lines ("Not enough mana") are a game
-- setting. 'spec' and 'off' turn it off, remembering the player's own value
-- to put back when the choice changes.
local function GetSetting(name)
	local get = (C_CVar and C_CVar.GetCVar) or GetCVar
	return get and get(name)
end
local function PutSetting(name, value)
	local set = (C_CVar and C_CVar.SetCVar) or SetCVar
	if set then pcall(set, name, value) end
end

local function ApplyErrorSpeech()
	local state = State()
	local quiet = Muting('errors')
	if quiet and state.errorSpeechWas == nil then
		local current = GetSetting('Sound_EnableErrorSpeech')
		if current and current ~= '0' then
			state.errorSpeechWas = current
			PutSetting('Sound_EnableErrorSpeech', '0')
		end
	elseif not quiet and state.errorSpeechWas ~= nil then
		PutSetting('Sound_EnableErrorSpeech', state.errorSpeechWas)
		state.errorSpeechWas = nil
	end
end

-- The modes as one string, so a repaint only re-mutes after a change.
local applied
local function ApplyModes()
	local db = UI.db.sound
	local signature = {tostring(db.enable), tostring(db.interface)}
	for _, kind in ipairs(KINDS) do signature[#signature + 1] = UI:SoundMode(kind) end
	signature = table.concat(signature, ',')
	if signature == applied then return end
	applied = signature
	UI:Safe(ApplyMutes)
	UI:Safe(ApplyErrorSpeech)
end

-- Quest ready: a chime when every objective of a quest is done. The first
-- scan after login only notes what is already complete.
local complete, primed = {}, false
local function ScanQuests()
	local log = C_QuestLog
	if not (log and log.GetNumQuestLogEntries and log.GetInfo and log.IsComplete) then return end
	local now, newly = {}, false
	for index = 1, log.GetNumQuestLogEntries() do
		local info = log.GetInfo(index)
		local id = info and not info.isHeader and info.questID
		if not IsSecret(id) and id and log.IsComplete(id) then
			now[id] = true
			if primed and not complete[id] then newly = true end
		end
	end
	complete, primed = now, true
	if newly and UI:SpecSounds('quest') then Kit:Play('success', true) end
end

local scanQueued
local function QueueScan()
	if scanQueued then return end
	scanQueued = true
	C_Timer.After(0.3, function()
		scanQueued = false
		UI:Safe(ScanQuests)
	end)
end

-- The Sounds page's test buttons: what each kind sounds like right now.
UI.SOUND_TEST = {windows = 'open', menus = 'blip', tabs = 'tick', checkboxes = 'latch-down', buttons = 'down', errors = 'error',
	quest = 'success', loot = 'success', alerts = 'warning'}
function UI:TestSound(kind)
	local mode = self:SoundMode(kind)
	if mode == 'off' then return self:Print('This kind of sound is off.') end
	if mode == 'game' then return self:Print('This kind of sound plays the game\'s own.') end
	Kit:Play(self.SOUND_TEST[kind] or 'tick', true)
end

local lastError = 0
function sounds:Enable()
	local map = {}
	for kind, kits in pairs(KITS) do
		for name, entry in pairs(kits) do
			local id = SOUNDKIT and SOUNDKIT[name]
			if id then
				local family = KIND_FAMILY[kind] or (kind == 'buttons' and (entry[1] == 'tick' and 'scroll' or 'press')) or name
				map[id] = {entry[1], family, kind}
			end
		end
	end
	-- A light lookup inside the game's PlaySound; the modes are read as it runs.
	hooksecurefunc('PlaySound', function(kit)
		if IsSecret(kit) then return end
		local entry = map[kit]
		if entry then UI:InterfaceSound(entry[1], entry[2], 'game', entry[3]) end
	end)
	local driver = CreateFrame('Frame')
	driver:RegisterEvent('UI_ERROR_MESSAGE')
	driver:RegisterEvent('QUEST_LOG_UPDATE')
	driver:RegisterEvent('PLAYER_ENTERING_WORLD')
	driver:SetScript('OnEvent', function(_, event)
		if event == 'UI_ERROR_MESSAGE' then
			local now = GetTime()
			if now - lastError > 1 and UI:SpecSounds('errors') then
				lastError = now
				Kit:Play('error', true)
			end
		else
			QueueScan()
		end
	end)
	ApplyModes()
end

Kit:OnRefresh(function()
	if sounds.enabled then UI:Safe(ApplyModes) end
end)

Kit:OnRefresh(function()
	if tooltip.enabled then UI:Safe(Fonts) end
end)
