-- Jiberish SPEC-01 UI: a standalone reskin of the Blizzard interface in the
-- style of SPEC-01/HARDWARE by Shu Ding (https://github.com/shuding/spec-01,
-- MIT; see Media/Hardware/LICENSE-SPEC-01.txt). No other addon is required.
local ADDON, UI = ...
_G.JiberishSpec01UI = UI

UI.name = ADDON
UI.title = 'Jiberish SPEC-01 UI'
UI.MediaPath = 'Interface\\AddOns\\'..ADDON..'\\Media\\'
UI.modules, UI.moduleOrder, UI.startedStyle = {}, {}, {}

local defaults = {
	finish = 'paper', accent = 'red', customAccent = {1, 0.2, 0.1}, font = '__default', scale = 1, reduceMotion = false,
	sound = {enable = true, channel = 'Master', widgets = true, interface = true, actionbars = true, chat = true},
	toasts = {enable = true, duration = 5, x = 0, y = -160,
		mail = true, levelUp = true, readyCheck = true, durability = true, achievement = true,
		questComplete = true, questAccept = false, zone = true, reputation = true, currency = false},
	-- Loot: our own loot window, a feed of items gained, and roll frames.
	loot = {window = true, feed = true, rolls = true, feedX = -260, feedY = 0},
	status = {enable = false, x = 0, y = 220},
	-- The SPEC-01 style for each part of the interface; 'blizzard' leaves it alone.
	-- Changing a style takes effect after a reload.
	style = {unitframes = 'paper', actionbars = 'keys', minimap = 'navigator', chat = 'display', tooltip = 'display',
		windows = 'display', nameplates = 'dots', objectives = 'device', buffs = 'keys', loot = 'device',
		group = 'device', bags = 'device', infopanel = 'device', meters = 'device'},
	unitframes = {positions = {}, scale = 1, barStyle = 'dots', healthColor = 'accent', portrait = 'model', party = true, castbar = true,
		arrive = true, combatSweep = false,
		auras = true, digits = true},
	-- layout 'console': our own keys in one device along the bottom, with the
	-- player and target docked into it; 'free': each bar placed on its own.
	actionbars = {scale = 1, housing = true, hotkeys = true, macros = false, xpbar = true, art = false,
		layout = 'console', rows = 3, keySize = 34, side = true, pet = true, stance = true, dock = true},
	minimap = {scale = 1, clock = true, coords = true},
	nameplates = {width = 132, height = 8, scale = 1, targetScale = 1.12, level = true, castbar = true, debuffs = true,
		classColor = true, threat = true},
	objectives = {scale = 1, collapsed = false},
	buffs = {size = 30, perRow = 12, scale = 1},
	hub = {page = 'overview'},
	-- The UI scale, saved and put back whenever the client changes it.
	-- false until the first login captures the game's own scale.
	uiScale = false, uiScaleLocked = true,
	housingAlpha = 0.95,
	-- Saved frame positions: CENTER offsets from the screen centre, in UIParent units.
	movers = {},
}
UI.defaults = defaults

local function Fill(target, source)
	for key, value in pairs(source) do
		if type(value) == 'table' then
			if type(target[key]) ~= 'table' then target[key] = {} end
			Fill(target[key], value)
		elseif target[key] == nil then
			target[key] = value
		end
	end
	return target
end

-- Until saved variables load, the kit reads the defaults.
UI.db = Fill({}, defaults)

-- Modules declare their own settings next to their code: UI:RegisterDefaults('bags',
-- {columns = 10}) or UI:RegisterDefaults('style', {bags = 'device'}). Files load
-- before the saved variables, so these are in place when they are filled. Keep
-- each call between '-- defaults:begin' and '-- defaults:end' lines so the
-- settings test can read it.
function UI:RegisterDefaults(section, values)
	if type(defaults[section]) ~= 'table' then defaults[section] = {} end
	Fill(defaults[section], values)
	if type(self.db[section]) ~= 'table' then self.db[section] = {} end
	Fill(self.db[section], values)
end

function UI:Print(...)
	DEFAULT_CHAT_FRAME:AddMessage('|cffff3b30SPEC-01|r '..strjoin(' ', tostringall(...)))
end

-- Run something that must not take the rest of the UI down with it.
function UI:Safe(func, ...)
	local ok, problem = pcall(func, ...)
	if not ok and geterrorhandler then geterrorhandler()(problem) end
	return ok
end

function UI:IsAddOnLoaded(name)
	local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
	return loaded and loaded(name) and true or false
end

-- module: {Enable = function(self) end, Refresh = function(self) end}
function UI:RegisterModule(name, module)
	self.modules[name] = module
	self.moduleOrder[#self.moduleOrder + 1] = name
	return module
end

function UI:Style(name)
	return self.db.style[name] or 'blizzard'
end

function UI:ModuleEnabled(name)
	return self:Style(name) ~= 'blizzard'
end

-- Hide a Blizzard frame for good, the way oUF does (MIT): stop its events,
-- hide it and park it under a hidden parent, putting it back there whenever
-- something else reparents it. Protected frames wait for combat to end.
local hiddenParent = CreateFrame('Frame', nil, UIParent)
hiddenParent:SetAllPoints()
hiddenParent:Hide()
UI.hiddenParent = hiddenParent
local retired = {}

function UI:Retire(frame, keepEvents)
	if type(frame) ~= 'table' or not frame.SetParent or retired[frame] then return end
	if frame.IsForbidden and frame:IsForbidden() then return end
	if InCombatLockdown() and frame.IsProtected and frame:IsProtected() then
		return self:AfterCombat(function() self:Retire(frame, keepEvents) end)
	end
	retired[frame] = true
	if not keepEvents and frame.UnregisterAllEvents then frame:UnregisterAllEvents() end
	frame:Hide()
	frame:SetParent(hiddenParent)
	-- Put it back later, outside Blizzard's own call, so Edit Mode passes stay clean.
	hooksecurefunc(frame, 'SetParent', function(self, parent)
		if parent == hiddenParent then return end
		C_Timer.After(0, function()
			UI:AfterCombat(function() if self:GetParent() ~= hiddenParent then self:SetParent(hiddenParent) end end)
		end)
	end)
end

-- Changes that need frames to be created or moved wait for combat to end.
-- key: a later request with the same key replaces the earlier one.
local afterCombat, afterKeys = {}, {}
function UI:AfterCombat(func, key)
	if not InCombatLockdown() then return func() end
	if key then
		if afterKeys[key] then afterCombat[afterKeys[key]] = func return end
		afterKeys[key] = #afterCombat + 1
	end
	afterCombat[#afterCombat + 1] = func
end

-- Settings saved by older versions, brought up to date. Profiles.lua runs this
-- again on any profile it swaps in or imports.
function UI:Migrate(db)
	if type(db) ~= 'table' then return end
	-- 0.3 kept unit frame spots under unitframes.positions; movers keep them now.
	local unitframes, movers = db.unitframes, db.movers
	if type(unitframes) == 'table' and type(unitframes.positions) == 'table' and type(movers) == 'table' then
		for unit, spot in pairs(unitframes.positions) do
			if type(spot) == 'table' and not movers['uf.'..unit] then movers['uf.'..unit] = {spot[1], spot[2]} end
		end
		wipe(unitframes.positions)
	end
	-- The 0.2 styles were renamed: the light housing is 'paper'.
	if type(db.style) == 'table' and db.style.unitframes == 'device' then db.style.unitframes = 'paper' end
	-- 0.5.1: bag slots match the menu's glyph keys; the bag pictures stay an option.
	if type(db.actionbars) == 'table' and not db.actionbars.bagGlyphsMoved then
		if db.actionbars.bagIcons == 'items' then db.actionbars.bagIcons = 'glyphs' end
		db.actionbars.bagGlyphsMoved = true
	end
	-- 0.5.1: the chat housing switch became a choice of housings.
	if type(db.chat) == 'table' then
		if db.chat.housing == true then db.chat.housing = 'device'
		elseif db.chat.housing == false then db.chat.housing = 'hairline' end
	end
end

-- Account-wide state that belongs to this computer and these characters, not to
-- a profile: sounds this addon muted, saved CVar values, chat history, whether
-- setup ran. Profiles never copy, export or swap it. Keys starting with '__'
-- in JiberishSpec01DB are all outside profiles.
function UI:Account(section)
	if type(JiberishSpec01DB) ~= 'table' then JiberishSpec01DB = {} end
	local account = JiberishSpec01DB.__account
	if type(account) ~= 'table' then account = {}; JiberishSpec01DB.__account = account end
	if not section then return account end
	if type(account[section]) ~= 'table' then account[section] = {} end
	return account[section]
end

local driver = CreateFrame('Frame')
driver:RegisterEvent('ADDON_LOADED')
driver:RegisterEvent('PLAYER_LOGIN')
driver:RegisterEvent('PLAYER_REGEN_ENABLED')
driver:SetScript('OnEvent', function(_, event, name)
	if event == 'ADDON_LOADED' then
		if name ~= ADDON then return end
		JiberishSpec01DB = Fill(type(JiberishSpec01DB) == 'table' and JiberishSpec01DB or {}, defaults)
		UI.db = JiberishSpec01DB
		UI:Migrate(UI.db)
	elseif event == 'PLAYER_LOGIN' then
		UI.startedStyle = CopyTable and CopyTable(UI.db.style) or {}
		if not CopyTable then for key, value in pairs(UI.db.style) do UI.startedStyle[key] = value end end
		-- Each module runs on its own: one that fails reports its error on the
		-- hub's Overview page and leaves the rest of the interface working.
		for _, moduleName in ipairs(UI.moduleOrder) do
			local module = UI.modules[moduleName]
			if module.Enable and (module.always or UI:ModuleEnabled(moduleName)) then
				local ok, problem = pcall(module.Enable, module)
				module.enabled, module.problem = ok, not ok and tostring(problem) or nil
				if not ok and geterrorhandler then geterrorhandler()(problem) end
			end
		end
		if UI.Kit then UI.Kit:Refresh() end
	elseif event == 'PLAYER_REGEN_ENABLED' then
		local queue = afterCombat
		afterCombat, afterKeys = {}, {}
		for _, func in ipairs(queue) do UI:Safe(func) end
	end
end)

SLASH_JIBERISHSPEC1, SLASH_JIBERISHSPEC2, SLASH_JIBERISHSPEC3 = '/spec', '/spec01', '/jspec'
SlashCmdList.JIBERISHSPEC = function(input)
	local command, rest = (input or ''):match('^%s*(%S*)%s*(.-)%s*$')
	command = command:lower()
	local Kit = UI.Kit
	if command == 'deck' then UI:ToggleHub('components')
	elseif command == 'sound' then Kit:SoundReport()
	elseif command == 'toast' then Kit:Toast({title = rest ~= '' and rest or 'Test toast'})
	elseif command == 'setup' and UI.OpenSetup then UI:OpenSetup()
	elseif command == 'move' or command == 'unlock' or command == 'lock' then
		local lock
		if command == 'unlock' then lock = false elseif command == 'lock' then lock = true end
		if UI.ToggleMovers then UI:ToggleMovers(lock) end
	elseif command == 'reset' then
		if UI.ResetMovers then UI:ResetMovers() end
	elseif UI.ToggleHub then UI:ToggleHub(command ~= '' and command or nil)
	end
end
