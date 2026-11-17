-- The hub's Layout page: every frame of the interface on one map.
--
--   Map        a scaled-down screen on a black display, one glass block per
--              frame at its true place and size. Click a block to select it,
--              drag it to move the real frame (snapped like the handles).
--   Inspector  the selected frame's anchor, offsets, scale, opacity and
--              visibility, with reset and centre keys.
--   Presets    whole arrangements (our own designs), drawn as small maps.
--   Screen     1080p, 1440p and 4K layouts: UI scale and density for the
--              screen, combined with whichever arrangement is in use.
--   Custom     the current layout saved under a name, to come back to.
--
-- Frames Blizzard's Edit Mode owns (objectives, buffs, minimap, chat) are
-- shown on the map read-only; they are placed with Edit Mode, never moved or
-- reparented from here.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown = CreateFrame, UIParent, InCombatLockdown
local floor, max, min, abs = math.floor, math.max, math.min, math.abs

local function DB() return UI.db.layout end
local function IsSecret(value) return issecretvalue and issecretvalue(value) end
local function Round(value) return floor(value + 0.5) end

-- Settings a layout changes ---------------------------------------------------------
-- A path is only set when the setting exists (a module that isn't installed or
-- has no such option is skipped).
local function Resolve(path)
	local node = UI.db
	local keys = {strsplit('.', path)}
	for index = 1, #keys - 1 do
		node = type(node) == 'table' and node[keys[index]] or nil
	end
	local leaf = keys[#keys]
	if type(node) ~= 'table' or node[leaf] == nil then return end
	return node, leaf
end

-- These only take effect after a reload.
local RELOAD = {['actionbars.layout'] = true, ['actionbars.rows'] = true, ['actionbars.side'] = true, ['actionbars.dock'] = true,
	['actionbars.keySize'] = true, ['group.partyAsRaid'] = true}

local function ApplySettings(settings)
	local reload = false
	for path, value in pairs(settings or {}) do
		local node, leaf = Resolve(path)
		if node and node[leaf] ~= value then
			Kit:SetOption(path, value)
			if RELOAD[path] or path:find('^style%.') then reload = true end
		end
	end
	return reload
end

local function ReloadToast()
	UI:NeedsReload()
	Kit:Toast({title = 'Reload to finish', text = 'Some of this layout takes effect after a reload.',
		action = {text = 'Reload', onClick = function() ReloadUI() end}})
end

-- Screen helpers for the presets ------------------------------------------------------
-- A preset key may name a mover a module registers under its own key: '@boss'
-- is the first mover whose key contains 'boss'.
local function FindMover(token)
	if token:sub(1, 1) ~= '@' then return token end
	local word = token:sub(2):lower()
	for _, entry in ipairs(UI:GetMovers()) do
		if entry.key:lower():find(word, 1, true) then return entry.key end
	end
end

local function Screen()
	local width, height = UIParent:GetSize()
	local screen = {W = width, H = height}
	-- On a wider than 16:9 screen, the 16:9 band in the middle and its margin.
	screen.inset = max(0, (width - height * 16 / 9) / 2)
	-- A frame's size in UIParent units, or a fair guess for one not built yet.
	function screen.size(key, guessWidth, guessHeight)
		key = FindMover(key)
		local frameWidth, frameHeight
		if key then frameWidth, frameHeight = UI:GetMoverSize(key) end
		if frameWidth and frameWidth > 1 then return frameWidth, frameHeight end
		return guessWidth or 120, guessHeight or 40
	end
	return screen
end

-- Presets: our own arrangements ------------------------------------------------------
-- positions(screen) returns {[moverKey] = {anchor, x, y}} in UIParent units;
-- every other frame goes back to its default spot.
local PRESETS = {
	{key = 'console', title = 'Console', model = 'LY-1',
		note = 'One console along the bottom with the player and target docked into it.',
		settings = {['actionbars.layout'] = 'console', ['actionbars.dock'] = true, ['actionbars.rows'] = 3, ['actionbars.side'] = true},
		positions = function() return {} end},
	{key = 'classic', title = 'Classic', model = 'LY-2',
		note = 'Three bars stacked at the bottom, unit frames above them either side of centre.',
		settings = {['actionbars.layout'] = 'free', ['actionbars.dock'] = false, ['actionbars.rows'] = 3, ['actionbars.side'] = true},
		positions = function(s)
			local barWidth, bar = s.size('ab.bar1', 480, 50)
			local top = 12 + 3 * (bar + 6)
			local playerWidth, playerHeight = s.size('uf.player', 224, 70)
			local smallWidth = s.size('uf.targettarget', 128, 30)
			local petWidth = s.size('uf.pet', 128, 30)
			local x = max(Round(s.W * 0.13), Round(playerWidth / 2 + 40))
			local y = top + 28
			local stanceWidth = s.size('ab.stance', 200, 40)
			local petKeysWidth = s.size('ab.pet', 280, 40)
			return {
				['ab.bar1'] = {'BOTTOM', 0, 12}, ['ab.bar2'] = {'BOTTOM', 0, 12 + bar + 6}, ['ab.bar3'] = {'BOTTOM', 0, 12 + 2 * (bar + 6)},
				['uf.player'] = {'BOTTOM', -x, y}, ['uf.target'] = {'BOTTOM', x, y},
				['uf.targettarget'] = {'BOTTOM', x + playerWidth / 2 + smallWidth / 2 + 12, y},
				['uf.pet'] = {'BOTTOM', -x - playerWidth / 2 - petWidth / 2 - 12, y},
				['uf.focus'] = {'BOTTOM', -x, y + playerHeight + 40},
				['cb.player'] = {'BOTTOM', 0, top + 20},
				['cb.target'] = {'BOTTOM', x, y + playerHeight + 10},
				['ab.stance'] = {'BOTTOM', -barWidth / 2 - stanceWidth / 2 - 12, 12},
				['ab.pet'] = {'BOTTOM', barWidth / 2 + petKeysWidth / 2 + 12, 12},
			}
		end},
	{key = 'healer', title = 'Healer', model = 'LY-3',
		note = 'Raid frames at the bottom centre above the keys; player and target out to the sides.',
		settings = {['actionbars.layout'] = 'console', ['actionbars.dock'] = false, ['actionbars.rows'] = 2, ['actionbars.side'] = true,
			['group.partyAsRaid'] = true},
		positions = function(s)
			local _, console = s.size('ab.console', 600, 150)
			local top = 12 + console
			local _, castHeight = s.size('cb.player', 240, 20)
			local _, raidHeight = s.size('group.small', 420, 200)
			local playerWidth = s.size('uf.player', 224, 70)
			local x = max(Round(s.W * 0.3), Round(playerWidth / 2 + 320))
			return {
				['cb.player'] = {'BOTTOM', 0, top + 10},
				['group.small'] = {'BOTTOM', 0, top + castHeight + 24},
				['uf.player'] = {'BOTTOM', -x, top + 30}, ['uf.target'] = {'BOTTOM', x, top + 30},
				['uf.targettarget'] = {'BOTTOM', x, top + 120},
				['uf.focus'] = {'BOTTOM', -x, top + 120},
				['cb.target'] = {'BOTTOM', x, top + 10},
				['@boss'] = {'RIGHT', -40, 120},
				_raidTop = top + castHeight + 24 + raidHeight,
			}
		end},
	{key = 'centre', title = 'Tank / DPS centre', model = 'LY-4',
		note = 'Player and target tight around the middle of the screen, where your eyes already are.',
		settings = {['actionbars.layout'] = 'console', ['actionbars.dock'] = false, ['actionbars.side'] = false,
			['nameplates.scale'] = 1.1, ['nameplates.targetScale'] = 1.25},
		positions = function(s)
			local playerWidth, playerHeight = s.size('uf.player', 224, 70)
			local smallWidth = s.size('uf.targettarget', 128, 30)
			local x = Round(playerWidth / 2 + 70)
			local y = Round(s.H * 0.27)
			return {
				['uf.player'] = {'BOTTOM', -x, y}, ['uf.target'] = {'BOTTOM', x, y},
				['uf.targettarget'] = {'BOTTOM', x + playerWidth / 2 + smallWidth / 2 + 10, y},
				['uf.focus'] = {'BOTTOM', -x - playerWidth / 2 - smallWidth / 2 - 10, y + playerHeight + 12},
				['cb.player'] = {'BOTTOM', 0, y - 34},
				['cb.target'] = {'BOTTOM', x, y + playerHeight + 8},
			}
		end},
	{key = 'minimal', title = 'Minimal', model = 'LY-5',
		note = 'One row of keys, no side bars or info panel, compact frames that fade when idle.',
		settings = {['actionbars.layout'] = 'console', ['actionbars.dock'] = true, ['actionbars.rows'] = 1, ['actionbars.side'] = false,
			['style.infopanel'] = 'blizzard', ['unitframes.scale'] = 0.9, ['appearance.fade.enable'] = true},
		positions = function() return {} end},
	{key = 'wide', title = 'Widescreen', model = 'LY-6',
		note = 'On ultrawide screens, everything kept inside the 16:9 band in the middle.',
		settings = {['actionbars.layout'] = 'console', ['actionbars.dock'] = true},
		positions = function(s)
			local spots = {}
			if s.inset < 1 then return spots end
			for _, entry in ipairs(UI:GetMovers()) do
				local anchor, x, y = UI:GetMoverDefault(entry.key)
				if anchor then
					if anchor:find('LEFT') then spots[entry.key] = {anchor, x + s.inset, y}
					elseif anchor:find('RIGHT') then spots[entry.key] = {anchor, x - s.inset, y} end
				end
			end
			return spots
		end},
}
local PRESET_BY_KEY = {}
for _, preset in ipairs(PRESETS) do PRESET_BY_KEY[preset.key] = preset end

-- A preset's spots, with '@' keys resolved and helper entries dropped.
local function PresetSpots(preset)
	local spots = {}
	local ok, list = pcall(preset.positions, Screen())
	if not ok or type(list) ~= 'table' then return spots end
	for token, spot in pairs(list) do
		if type(token) == 'string' and token:sub(1, 1) ~= '_' and type(spot) == 'table' then
			local key = FindMover(token)
			if key then spots[key] = spot end
		end
	end
	return spots
end

local Refresh -- the page's refresh, set when it is built

local function ApplyPreset(preset)
	if InCombatLockdown() then return UI:Print('Layouts can be applied once you leave combat.') end
	local reload = ApplySettings(preset.settings)
	local spots = PresetSpots(preset)
	wipe(UI.db.movers)
	for key, spot in pairs(spots) do UI:SetMoverPosition(key, spot[1], spot[2], spot[3]) end
	DB().preset = preset.key
	UI:PlaceAllMovers()
	Kit:Play('success')
	if reload then ReloadToast() end
	if Refresh then Refresh() end
end

local function ConfirmPreset(preset)
	Kit:AlertDialog({title = 'Use the '..preset.title..' layout', confirm = 'Apply',
		text = 'Every frame moves to the '..preset.title..' arrangement and your current positions are replaced. Save them as a custom layout first if you want to come back to them.',
		onConfirm = function() ApplyPreset(preset) end})
end

-- Custom layouts: positions as fractions of the screen, so they carry across resolutions.
local SNAPSHOT = {'actionbars.layout', 'actionbars.dock', 'actionbars.rows', 'actionbars.side', 'actionbars.keySize',
	'unitframes.scale', 'nameplates.scale', 'style.infopanel'}

local function SaveCustom(name)
	name = strtrim(name or '')
	if name == '' then return UI:Print('Give the layout a name first.') end
	local width, height = UIParent:GetSize()
	local entry = {name = name, settings = {}, movers = {}}
	for _, path in ipairs(SNAPSHOT) do
		local node, leaf = Resolve(path)
		if node then entry.settings[path] = node[leaf] end
	end
	for key, saved in pairs(UI.db.movers) do
		if type(saved) == 'table' and saved[1] then
			entry.movers[key] = {anchor = saved.anchor or 'CENTER', fx = saved[1] / width, fy = (saved[2] or 0) / height,
				scale = saved.scale, alpha = saved.alpha, hidden = saved.hidden}
		end
	end
	local list = DB().custom
	for index, other in ipairs(list) do
		if other.name == name then table.remove(list, index) break end
	end
	list[#list + 1] = entry
	Kit:Play('success')
	Kit:Toast({title = 'Layout saved', text = name})
	if Refresh then Refresh() end
end

local function ApplyCustom(entry)
	if InCombatLockdown() then return UI:Print('Layouts can be applied once you leave combat.') end
	local reload = ApplySettings(entry.settings)
	local width, height = UIParent:GetSize()
	wipe(UI.db.movers)
	for key, spot in pairs(entry.movers or {}) do
		UI.db.movers[key] = {Round(spot.fx * width * 100) / 100, Round(spot.fy * height * 100) / 100, anchor = spot.anchor,
			scale = spot.scale, alpha = spot.alpha, hidden = spot.hidden}
	end
	DB().preset = 'custom:'..entry.name
	UI:PlaceAllMovers()
	Kit:Play('success')
	if reload then ReloadToast() end
	if Refresh then Refresh() end
end

-- Screen sizes ------------------------------------------------------------------------
-- Each size is two densities, as screen pixels per UI unit. A whole number (or
-- 1.5, where every second unit lands on a whole pixel) keeps the game's own art
-- and one-unit lines sharp; SPEC-01's borders are drawn in physical pixels at
-- any scale, so they stay sharp regardless.
local RESOLUTIONS = {
	{key = '1080', title = '1080p', height = 1080,
		compact = {pixels = 1, keySize = 32, unitScale = 0.9, spacing = 3},
		comfortable = {pixels = 1, keySize = 36, unitScale = 1, spacing = 4}},
	{key = '1440', title = '1440p', height = 1440,
		compact = {pixels = 1, keySize = 40, unitScale = 1.2, spacing = 4},
		comfortable = {pixels = 1.5, keySize = 34, unitScale = 1, spacing = 4}},
	{key = '2160', title = '4K', height = 2160,
		compact = {pixels = 1.5, keySize = 38, unitScale = 1.1, spacing = 4},
		comfortable = {pixels = 2, keySize = 36, unitScale = 1, spacing = 4}},
}
local RESOLUTION_BY_KEY = {}
for _, resolution in ipairs(RESOLUTIONS) do RESOLUTION_BY_KEY[resolution.key] = resolution end

local function PhysicalSize()
	local width, height = GetPhysicalScreenSize()
	if IsSecret(width) or IsSecret(height) or not height or height <= 0 then return 1920, 1080 end
	return width, height
end

-- The size class nearest a physical height.
local function Detect(height)
	if height >= 1800 then return '2160' elseif height >= 1260 then return '1440' end
	return '1080'
end

-- The size class in use, its density and the UI scale they give on this screen.
local function Plan(sizeKey, densityKey)
	local _, height = PhysicalSize()
	if not sizeKey or sizeKey == 'auto' then sizeKey = Detect(height) end
	local resolution = RESOLUTION_BY_KEY[sizeKey] or RESOLUTIONS[1]
	local density = resolution[densityKey] or resolution.comfortable
	local scale = UI.Pixel.Clamp(density.pixels * 768 / height)
	return resolution, density, scale, height
end

local function ApplyResolution(sizeKey, densityKey)
	if InCombatLockdown() then return UI:Print('Screen layouts can be applied once you leave combat.') end
	sizeKey, densityKey = sizeKey or DB().resolution, densityKey or DB().density
	local resolution, density, scale, height = Plan(sizeKey, densityKey)
	DB().resolution, DB().density, DB().lastHeight = sizeKey, densityKey, height
	UI.db.uiScaleLocked = true
	UI.Pixel.SetScale(scale)
	local reload = ApplySettings({['actionbars.keySize'] = density.keySize, ['unitframes.scale'] = density.unitScale,
		['actionbars.spacing'] = density.spacing})
	Kit:Play('success')
	Kit:Toast({title = resolution.title..' layout', text = format('UI scale %.3f', scale)})
	if reload then ReloadToast() end
	if Refresh then Refresh() end
end

-- When the resolution changes, offer the matching screen layout.
local watcher = CreateFrame('Frame')
watcher:RegisterEvent('PLAYER_LOGIN')
watcher:RegisterEvent('DISPLAY_SIZE_CHANGED')
watcher:SetScript('OnEvent', function(_, event)
	local width, height = PhysicalSize()
	local last = DB().lastHeight
	if event == 'PLAYER_LOGIN' then
		if not last then DB().lastHeight = height end
		return
	end
	if last == height then return end
	DB().lastHeight = height
	if not DB().suggest then return end
	local resolution = RESOLUTION_BY_KEY[Detect(height)]
	Kit:Toast({title = format('Screen now %dx%d', width, height), text = 'Use the '..resolution.title..' layout for this screen?',
		duration = 12, action = {text = 'Apply', onClick = function() ApplyResolution('auto', DB().density) end}})
	if Refresh then Refresh() end
end)

-- Edit Mode frames, shown read-only ------------------------------------------------------
local EDIT_MODE = {{'ObjectiveTrackerFrame', 'Objectives'}, {'BuffFrame', 'Buffs'}, {'DebuffFrame', 'Debuffs'},
	{'MinimapCluster', 'Minimap'}, {'ChatFrame1', 'Chat'}, {'TalkingHeadFrame', 'Talking head'}, {'EncounterBar', 'Encounter bar'},
	{'DurabilityFrame', 'Durability'}, {'VehicleSeatIndicator', 'Vehicle seats'}, {'ArcheologyDigsiteProgressBar', 'Digsite'}}

-- A frame's centre (from the screen centre) and size, in UIParent units.
local function FrameRect(frame)
	if not frame or (frame.IsForbidden and frame:IsForbidden()) or not frame:IsVisible() then return end
	local ok, left, bottom, width, height = pcall(frame.GetRect, frame)
	if not ok or IsSecret(left) or IsSecret(bottom) or IsSecret(width) or IsSecret(height) then return end
	if not left or not width or width < 2 or height < 2 then return end
	local ratio = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
	local screenWidth, screenHeight = UIParent:GetSize()
	return (left + width / 2) * ratio - screenWidth / 2, (bottom + height / 2) * ratio - screenHeight / 2, width * ratio, height * ratio
end

-- Maps ---------------------------------------------------------------------------------------
-- A map is a black display; draw(entries) lays one glass block per entry:
-- {key, label, cx, cy, w, h, kind ('mover' | 'editmode' | 'hidden')}.
local function Map(parent, width, height, interactive)
	local holder = Kit:Screen(parent, {inset = 4, radius = 8, shadow = false})
	holder:SetSize(width, height)
	local map = holder.screen
	holder.map = map
	-- Centre lines, as the handles' grid has.
	for _, vertical in ipairs({true, false}) do
		local line = map:CreateTexture(nil, 'ARTWORK')
		line:SetColorTexture(1, 1, 1, 0.08)
		if vertical then line:SetWidth(1); line:SetPoint('TOP'); line:SetPoint('BOTTOM')
		else line:SetHeight(1); line:SetPoint('LEFT'); line:SetPoint('RIGHT') end
	end
	holder.blocks = {}
	-- The screen's outline inside the display (letterboxed to the screen's shape).
	holder.frame = CreateFrame('Frame', nil, map)
	holder.frame.edge = holder.frame:CreateTexture(nil, 'BORDER')
	holder.frame.edge:SetAllPoints()
	holder.frame.edge:SetColorTexture(1, 1, 1, 0.03)

	function holder:Scale()
		local screenWidth, screenHeight = UIParent:GetSize()
		local mapWidth, mapHeight = map:GetSize()
		local scale = min(mapWidth / max(screenWidth, 1), mapHeight / max(screenHeight, 1))
		self.frame:ClearAllPoints()
		self.frame:SetPoint('CENTER')
		self.frame:SetSize(screenWidth * scale, screenHeight * scale)
		return scale
	end

	local function Block(index)
		local block = holder.blocks[index]
		if block then return block end
		block = CreateFrame('Button', nil, holder.frame)
		block.shell = Kit:Shell(block, {surface = 'glass', radius = 3, shadow = false})
		block.fill = block:CreateTexture(nil, 'ARTWORK')
		block.fill:SetAllPoints()
		block.fill:SetColorTexture(1, 1, 1, 1)
		block.fill:SetAlpha(0)
		block.label = Kit:Label(block, '', 'darkInk', 7)
		block.label:SetPoint('CENTER')
		block.label:SetWordWrap(false)
		block.lamp = Kit:Led(block, 3, false)
		block.lamp:SetPoint('TOPLEFT', 3, -3)
		if interactive then
			block:RegisterForClicks('LeftButtonUp', 'RightButtonUp')
			block:SetScript('OnEnter', function(self)
				GameTooltip:SetOwner(self, 'ANCHOR_TOP')
				GameTooltip:AddLine(self.entry.label or '', 1, 1, 1)
				if self.entry.kind == 'editmode' then GameTooltip:AddLine('Placed with Edit Mode (game menu, Edit Mode)', 0.7, 0.7, 0.7)
				else GameTooltip:AddLine('Drag to move. Right-click to put it back.', 0.7, 0.7, 0.7) end
				GameTooltip:Show()
			end)
			block:SetScript('OnLeave', function() GameTooltip:Hide() end)
		else
			block:EnableMouse(false)
		end
		holder.blocks[index] = block
		return block
	end

	function holder:Draw(entries, selectedKey)
		local scale = self:Scale()
		for index, entry in ipairs(entries) do
			local block = Block(index)
			block.entry = entry
			block:ClearAllPoints()
			block:SetPoint('CENTER', self.frame, 'CENTER', entry.cx * scale, entry.cy * scale)
			block:SetSize(max(entry.w * scale, 6), max(entry.h * scale, 5))
			local editMode, chosen = entry.kind == 'editmode', entry.key == selectedKey
			block:SetAlpha(entry.kind == 'hidden' and 0.35 or editMode and 0.6 or 1)
			Kit:Tint(block.fill, chosen and 'lamp' or 'white', chosen and 0.32 or editMode and 0 or 0.06)
			block.label:SetText(strupper(entry.short or entry.label or ''))
			block.label:SetWidth(max(block:GetWidth() - 4, 1))
			block.label:SetShown(block:GetWidth() > 26 and block:GetHeight() > 9)
			Kit:ShowLed(block.lamp, chosen)
			if chosen then Kit:SetLed(block.lamp, true) end
			block:Show()
		end
		for index = #entries + 1, #self.blocks do self.blocks[index]:Hide() end
		return scale
	end
	return holder
end

local function ShortLabel(label)
	label = (label or ''):gsub('Target of target', 'ToT')
	label = label:gsub(' keys', '')
	label = label:gsub('Loot ', '')
	return label
end

-- The live entries: every placed frame, then the Edit Mode frames.
local function LiveEntries()
	local entries = {}
	for _, entry in ipairs(UI:GetMovers()) do
		if not entry.docked then
			local cx, cy = UI:GetMoverCenter(entry.key)
			local width, height = UI:GetMoverSize(entry.key)
			if cx and width and width > 0 then
				local hidden = UI:GetMoverOption(entry.key, 'hidden') or not entry.frame:IsShown()
				entries[#entries + 1] = {key = entry.key, label = entry.label, short = ShortLabel(entry.label), cx = cx, cy = cy,
					w = width, h = height, kind = hidden and 'hidden' or 'mover'}
			end
		end
	end
	for _, spec in ipairs(EDIT_MODE) do
		local cx, cy, width, height = FrameRect(_G[spec[1]])
		if cx then
			entries[#entries + 1] = {key = 'editmode:'..spec[1], label = spec[2], short = spec[2], cx = cx, cy = cy, w = width, h = height,
				kind = 'editmode'}
		end
	end
	return entries
end

-- Sizes for frames a preset places that aren't built yet (the free layout's bars
-- while the console is in use), by key prefix.
local GUESS = {{'ab.bar', 480, 50}, {'ab.', 200, 40}, {'uf.', 176, 44}, {'cb.', 240, 20}}
local function Guess(key)
	for _, guess in ipairs(GUESS) do
		if key:sub(1, #guess[1]) == guess[1] then return guess[2], guess[3] end
	end
	return 120, 40
end

local DOCKED = {['uf.player'] = true, ['uf.target'] = true, ['cb.player'] = true, ['cb.target'] = true}

local function Entry(key, label, anchor, x, y, width, height)
	local screenWidth, screenHeight = UIParent:GetSize()
	local ax = anchor:find('LEFT') and -screenWidth / 2 or anchor:find('RIGHT') and screenWidth / 2 or 0
	local ay = anchor:find('TOP') and screenHeight / 2 or anchor:find('BOTTOM') and -screenHeight / 2 or 0
	local px = anchor:find('LEFT') and -width / 2 or anchor:find('RIGHT') and width / 2 or 0
	local py = anchor:find('TOP') and height / 2 or anchor:find('BOTTOM') and -height / 2 or 0
	return {key = key, label = label, short = ShortLabel(label), cx = ax + x - px, cy = ay + y - py, w = width, h = height, kind = 'mover'}
end

-- A preset's entries: its spots, every other frame at its default.
local function PresetEntries(preset)
	local spots = PresetSpots(preset)
	local entries, seen = {}, {}
	local settings = preset.settings or {}
	local docked = settings['actionbars.dock'] ~= false and settings['actionbars.layout'] ~= 'free'
	local free = settings['actionbars.layout'] == 'free'
	for _, entry in ipairs(UI:GetMovers()) do
		seen[entry.key] = true
		local spot = spots[entry.key]
		local hide = (DOCKED[entry.key] and docked and not spot) or (free and entry.key == 'ab.console')
			or (not free and entry.key:find('^ab%.bar'))
		local anchor, x, y
		if spot then anchor, x, y = spot[1], spot[2], spot[3] else anchor, x, y = UI:GetMoverDefault(entry.key) end
		local width, height = UI:GetMoverSize(entry.key)
		if not hide and anchor and width and width > 0 then
			entries[#entries + 1] = Entry(entry.key, entry.label, anchor, x, y, width, height)
		end
	end
	for key, spot in pairs(spots) do
		if not seen[key] then
			local width, height = Guess(key)
			entries[#entries + 1] = Entry(key, key:gsub('^%a+%.', ''):gsub('^%l', strupper), spot[1], spot[2], spot[3], width, height)
		end
	end
	return entries
end

-- The page -------------------------------------------------------------------------------------
local INSPECTOR = 260
local ANCHOR_NAMES = {TOPLEFT = 'Top left', TOP = 'Top', TOPRIGHT = 'Top right', LEFT = 'Left', CENTER = 'Centre', RIGHT = 'Right',
	BOTTOMLEFT = 'Bottom left', BOTTOM = 'Bottom', BOTTOMRIGHT = 'Bottom right'}
local ANCHOR_ITEMS = {}
for _, point in ipairs(UI.MOVER_POINTS) do ANCHOR_ITEMS[#ANCHOR_ITEMS + 1] = {point, ANCHOR_NAMES[point] or point} end

-- Dimmed while nothing is selected; every control's handler checks the selection anyway.
local function Disable(control, off)
	control:SetAlpha(off and 0.4 or 1)
	control.kitDisabled = off or nil
end

local function BuildMapCard(content, page)
	local width = 4 * Kit.COLUMN + 3 * Kit.GAP
	local bodyWidth = width - 24
	local mapWidth = bodyWidth - INSPECTOR - 16
	local screenWidth, screenHeight = UIParent:GetSize()
	local mapHeight = Round(mapWidth * screenHeight / max(screenWidth, 1))
	local bodyHeight = max(mapHeight, 410)
	local card = Kit.CardShell(content, 1, 'Layout map', width, 28 + bodyHeight + 12)
	card.span = 4
	local body = card.body

	local map = Map(body, mapWidth, mapHeight, true)
	map:SetPoint('TOPLEFT')
	page.map = map
	local hint = Kit:Text(body, 'Click a frame to select it, drag it to move it. Arrow keys nudge the selection (Shift for 10). Dim blocks are placed with Edit Mode.', 8, 'dim')
	hint:SetPoint('TOPLEFT', map, 'BOTTOMLEFT', 2, -6)
	hint:SetWidth(mapWidth)
	hint:SetJustifyH('LEFT')

	-- Inspector.
	local inspector = CreateFrame('Frame', nil, body)
	inspector:SetPoint('TOPLEFT', mapWidth + 16, 0)
	inspector:SetSize(INSPECTOR, bodyHeight)
	local title = Kit:Text(inspector, 'NO FRAME SELECTED', 11, 'ink', true)
	title:SetPoint('TOPLEFT')
	title:SetWidth(INSPECTOR)
	title:SetJustifyH('LEFT')
	title:SetWordWrap(false)
	local lcd = Kit:LCDPanel(inspector, {radius = 4})
	lcd:SetSize(INSPECTOR, 24)
	lcd:SetPoint('TOPLEFT', 0, -18)
	lcd.text = Kit:Text(lcd, '', 9, 'lcdInk', true)
	lcd.text:SetPoint('LEFT', 8, 0)

	local controls = {}
	local function Selected()
		local key = UI:SelectedMover()
		if key and UI:HasMover(key) and not UI:MoverDocked(key) then return key end
	end

	local anchorLabel = Kit:Label(inspector, 'Anchor', 'ink', 9)
	anchorLabel:SetPoint('TOPLEFT', 0, -56)
	local anchor
	if Kit.Dropdown then
		anchor = Kit:Dropdown(inspector, {items = ANCHOR_ITEMS, width = 150, onChange = function(value)
			local key = Selected()
			if key then UI:SetMoverAnchor(key, value) end
		end})
	else
		-- Without the dropdown component: a key that steps through the anchors.
		anchor = Kit:Button(inspector, {text = 'Center', width = 150, height = 26})
		function anchor:SetValue(value) self.value = value; self:SetKeyText(ANCHOR_NAMES[value] or value or '') end
		anchor.onClick = function(self)
			local key = Selected()
			if not key then return end
			local points = UI.MOVER_POINTS
			local next = points[1]
			for index, point in ipairs(points) do if point == self.value then next = points[index % #points + 1] end end
			UI:SetMoverAnchor(key, next)
		end
	end
	anchor:SetPoint('TOPRIGHT', 0, -50)
	controls[#controls + 1] = anchor

	local function SliderRow(label, y, low, high, step, format, onChange)
		local slider = Kit:Slider(inspector, {label = label, min = low, max = high, step = step, width = INSPECTOR, ticks = 10,
			format = format, onChange = onChange})
		slider:SetPoint('TOPLEFT', 0, y)
		controls[#controls + 1] = slider
		return slider
	end
	local function Offset(axis)
		return function(value)
			local key = Selected()
			if not key then return end
			local point, x, y = UI:GetMoverPosition(key)
			if axis == 'x' then x = value else y = value end
			UI:SetMoverPosition(key, point, x, y)
		end
	end
	local sliderX = SliderRow('X', -84, -Round(screenWidth), Round(screenWidth), 1, function(v) return format('%d', v) end, Offset('x'))
	local sliderY = SliderRow('Y', -144, -Round(screenHeight), Round(screenHeight), 1, function(v) return format('%d', v) end, Offset('y'))
	-- A multiplier on the frame's own size setting from its module's page.
	local sliderScale = SliderRow('Scale (on top of its own)', -204, 0.5, 2, 0.05, function(v) return format('x%.2f', v) end, function(value)
		local key = Selected()
		if key then UI:SetMoverOption(key, 'scale', abs(value - 1) < 0.001 and nil or value) end
	end)
	local sliderAlpha = SliderRow('Opacity', -264, 0, 1, 0.05, function(v) return format('%d%%', v * 100 + 0.5) end, function(value)
		local key = Selected()
		if key then UI:SetMoverOption(key, 'alpha', value >= 0.999 and nil or value) end
	end)
	local hiddenLabel = Kit:Label(inspector, 'Hidden', 'ink', 9)
	hiddenLabel:SetPoint('TOPLEFT', 0, -334)
	local hidden = Kit:Switch(inspector, {labels = false, onChange = function(value)
		local key = Selected()
		if key then UI:SetMoverOption(key, 'hidden', value or nil) end
	end})
	hidden:SetPoint('TOPRIGHT', 0, -326)
	controls[#controls + 1] = hidden
	local reset = Kit:Button(inspector, {text = 'Reset', width = 80, height = 28})
	reset:SetPoint('TOPLEFT', 0, -370)
	reset.onClick = function()
		local key = Selected()
		if key and not InCombatLockdown() then UI:ResetMover(key) end
	end
	local centre = Kit:Button(inspector, {text = 'Centre', width = 80, height = 28})
	centre:SetPoint('LEFT', reset, 'RIGHT', 10, 0)
	centre.onClick = function()
		local key = Selected()
		if not key or InCombatLockdown() then return end
		local _, cy = UI:GetMoverCenter(key)
		UI:SetMoverCenter(key, 0, cy)
	end
	controls[#controls + 1], controls[#controls + 2] = reset, centre

	function page.inspect()
		local key = Selected()
		for _, control in ipairs(controls) do Disable(control, not key) end
		if not key then
			title:SetText('NO FRAME SELECTED')
			lcd.text:SetText('PICK A FRAME ON THE MAP')
			return
		end
		local label = key
		for _, entry in ipairs(UI:GetMovers()) do if entry.key == key then label = entry.label end end
		title:SetText(strupper(label))
		local point, x, y = UI:GetMoverPosition(key)
		lcd.text:SetText(format('%s   X %d   Y %d', point, Round(x), Round(y)))
		anchor:SetValue(point)
		sliderX:SetValue(Round(x))
		sliderY:SetValue(Round(y))
		sliderScale:SetValue(UI:GetMoverOption(key, 'scale') or 1)
		sliderAlpha:SetValue(UI:GetMoverOption(key, 'alpha') or 1)
		hidden:SetValue(UI:GetMoverOption(key, 'hidden') and true or false)
	end

	-- Dragging blocks moves the real frames.
	local function Hook(block)
		if block.kitHooked then return end
		block.kitHooked = true
		block:SetScript('OnMouseDown', function(self, button)
			local entry = self.entry
			if button ~= 'LeftButton' or not entry or entry.kind == 'editmode' or InCombatLockdown() then return end
			UI:SelectMover(entry.key)
			Kit:Play('down', true)
			local scale = map.scale or 1
			local startX, startY = GetCursorPosition()
			local baseX, baseY = UI:GetMoverCenter(entry.key)
			if not baseX then return end
			self:SetScript('OnUpdate', function(dragged)
				if InCombatLockdown() then return dragged:SetScript('OnUpdate', nil) end
				local x, y = GetCursorPosition()
				local effective = dragged:GetEffectiveScale() * scale
				local cx, cy = UI:SnapMover(entry.key, baseX + (x - startX) / effective, baseY + (y - startY) / effective)
				local nowX, nowY = UI:GetMoverCenter(entry.key)
				if abs(nowX - cx) > 0.01 or abs(nowY - cy) > 0.01 then UI:SetMoverCenter(entry.key, cx, cy) end
			end)
		end)
		block:SetScript('OnMouseUp', function(self, button)
			if button == 'RightButton' then
				local entry = self.entry
				if entry and entry.kind ~= 'editmode' and not InCombatLockdown() then
					UI:ResetMover(entry.key)
					Kit:Play('latch-up', true)
				end
				return
			end
			if self:GetScript('OnUpdate') then
				self:SetScript('OnUpdate', nil)
				Kit:Play('up', true)
			end
		end)
		block:SetScript('OnHide', function(self) self:SetScript('OnUpdate', nil) end)
	end

	function page.drawMap()
		map.scale = map:Draw(LiveEntries(), UI:SelectedMover())
		for _, block in ipairs(map.blocks) do Hook(block) end
	end
	return card
end

local function BuildPresetsCard(content, page)
	local width = 4 * Kit.COLUMN + 3 * Kit.GAP
	local bodyWidth = width - 24
	local columns, gap = 3, 12
	local tileWidth = floor((bodyWidth - (columns - 1) * gap) / columns)
	local screenWidth, screenHeight = UIParent:GetSize()
	local mapHeight = Round((tileWidth - 8) * screenHeight / max(screenWidth, 1)) + 8
	local tileHeight = 26 + mapHeight + 50
	local rows = math.ceil(#PRESETS / columns)
	local card = Kit.CardShell(content, 2, 'Presets', width, 28 + rows * tileHeight + (rows - 1) * gap + 12)
	card.span = 4
	page.presetTiles = {}
	for index, preset in ipairs(PRESETS) do
		local column, row = (index - 1) % columns, floor((index - 1) / columns)
		local tile = CreateFrame('Frame', nil, card.body)
		tile:SetSize(tileWidth, tileHeight)
		tile:SetPoint('TOPLEFT', column * (tileWidth + gap), -row * (tileHeight + gap))
		tile.lamp = Kit:Led(tile, 5, false)
		tile.lamp:SetPoint('TOPLEFT', 0, -4)
		tile.model = Kit:Label(tile, preset.model, 'ink', 8, true)
		tile.model:SetPoint('LEFT', tile.lamp, 'RIGHT', 5, 0)
		tile.title = Kit:Label(tile, preset.title, 'dim', 8)
		tile.title:SetPoint('LEFT', tile.model, 'RIGHT', 5, 0)
		tile.map = Map(tile, tileWidth, mapHeight, false)
		tile.map:SetPoint('TOPLEFT', 0, -18)
		tile.note = Kit:Text(tile, preset.note, 8, 'dim')
		tile.note:SetPoint('TOPLEFT', tile.map, 'BOTTOMLEFT', 0, -6)
		tile.note:SetWidth(tileWidth - 90)
		tile.note:SetJustifyH('LEFT')
		tile.apply = Kit:Button(tile, {text = 'Apply', width = 76, height = 26})
		tile.apply:SetPoint('TOPRIGHT', tile.map, 'BOTTOMRIGHT', 0, -6)
		tile.apply.onClick = function() ConfirmPreset(preset) end
		tile.preset = preset
		page.presetTiles[index] = tile
	end
	function page.drawPresets()
		for _, tile in ipairs(page.presetTiles) do
			tile.map:Draw(PresetEntries(tile.preset))
			Kit:SetLed(tile.lamp, DB().preset == tile.preset.key)
		end
	end
	return card
end

local function BuildScreenCard(content, page)
	local width = 2 * Kit.COLUMN + Kit.GAP
	local bodyWidth = width - 24
	local card = Kit.CardShell(content, 3, 'Screen size', width, 300)
	card.span = 2
	local body = card.body
	local lcd = Kit:LCDPanel(body, {radius = 4})
	lcd:SetSize(bodyWidth, 30)
	lcd:SetPoint('TOPLEFT')
	lcd.tag = Kit:Label(lcd, 'DETECTED', 'lcdDim', 7)
	lcd.tag:SetPoint('LEFT', 8, 0)
	lcd.text = Kit:Text(lcd, '', 12, 'lcdInk', true)
	lcd.text:SetPoint('RIGHT', -8, 0)

	local sizeLabel = Kit:Label(body, 'Layout for', 'ink', 9)
	sizeLabel:SetPoint('TOPLEFT', 0, -48)
	local sizes = {{'auto', 'Auto'}, {'1080', '1080p'}, {'1440', '1440p'}, {'2160', '4K'}}
	local sizeIndex = 1
	for index, item in ipairs(sizes) do if item[1] == DB().resolution then sizeIndex = index end end
	local sizeNames = {}
	for index, item in ipairs(sizes) do sizeNames[index] = item[2] end
	local size = Kit:Segmented(body, {items = sizeNames, width = 240, value = sizeIndex, onChange = function(index)
		DB().resolution = sizes[index][1]
		page.drawScreen()
	end})
	size:SetPoint('TOPRIGHT', 0, -42)

	local densityLabel = Kit:Label(body, 'Density', 'ink', 9)
	densityLabel:SetPoint('TOPLEFT', 0, -88)
	local density = Kit:Segmented(body, {items = {'Compact', 'Comfortable'}, width = 240, value = DB().density == 'compact' and 1 or 2,
		onChange = function(index)
			DB().density = index == 1 and 'compact' or 'comfortable'
			page.drawScreen()
		end})
	density:SetPoint('TOPRIGHT', 0, -82)

	local plan = Kit:Text(body, '', 9, 'ink')
	plan:SetPoint('TOPLEFT', 0, -124)
	plan:SetWidth(bodyWidth)
	plan:SetJustifyH('LEFT')
	local apply = Kit:Button(body, {text = 'Apply', width = 96, height = 28, tone = 'primary'})
	apply:SetPoint('TOPRIGHT', 0, -150)
	apply.onClick = function() ApplyResolution(DB().resolution, DB().density) end
	local suggestLabel = Kit:Label(body, 'Offer a layout when the screen changes', 'ink', 9)
	suggestLabel:SetPoint('TOPLEFT', 0, -192)
	local suggest = Kit:Switch(body, {labels = false, checked = DB().suggest and true or false,
		onChange = function(value) DB().suggest = value end})
	suggest:SetPoint('TOPRIGHT', 0, -186)
	local note = Kit:Text(body, 'Scales are picked so each UI unit is a whole number of screen pixels (or 1.5, where every second unit lands on a whole pixel), which keeps the game\'s own art sharp. SPEC-01 borders are drawn in screen pixels, so they stay sharp at any scale. The arrangement comes from the preset; this sets scale and density.', 8, 'dim')
	note:SetPoint('TOPLEFT', 0, -222)
	note:SetWidth(bodyWidth)
	note:SetJustifyH('LEFT')

	function page.drawScreen()
		local physicalWidth, physicalHeight = PhysicalSize()
		local detected = RESOLUTION_BY_KEY[Detect(physicalHeight)]
		lcd.text:SetText(format('%dx%d  %s', physicalWidth, physicalHeight, strupper(detected.title)))
		local resolution, plan_, scale = Plan(DB().resolution, DB().density)
		plan:SetText(format('%s %s: UI scale %.3f, %s screen px per unit, keys %d, unit frames %d%%.', resolution.title, DB().density,
			scale, plan_.pixels == floor(plan_.pixels) and format('%d', plan_.pixels) or format('%.1f', plan_.pixels), plan_.keySize,
			plan_.unitScale * 100 + 0.5))
	end
	card:SetHeight(28 + 222 + note:GetStringHeight() + 22)
	return card
end

local function BuildEditCard(content, page)
	local width = 2 * Kit.COLUMN + Kit.GAP
	local bodyWidth = width - 24
	local card = Kit.CardShell(content, 4, 'Edit and save', width, 300)
	card.span = 2
	local body = card.body

	local edit = Kit:Button(body, {text = 'Unlock mode', width = 120, height = 28, tone = 'primary'})
	edit:SetPoint('TOPLEFT')
	edit.onClick = function()
		if InCombatLockdown() then return UI:Print('Frames can be moved once you leave combat.') end
		local unlock = not UI:MoversUnlocked()
		UI:ToggleMovers(not unlock)
		if unlock then UI:ToggleHub(nil, false) end
	end
	local resetAll = Kit:Button(body, {text = 'Reset all', width = 96, height = 28})
	resetAll:SetPoint('TOPRIGHT')
	resetAll.onClick = function()
		Kit:AlertDialog({title = 'Reset every frame', confirm = 'Reset',
			text = 'Every SPEC-01 frame goes back to its default spot, scale and opacity.',
			onConfirm = function() UI:ResetMovers() end})
	end

	local gridLabel = Kit:Label(body, 'Grid', 'ink', 9)
	gridLabel:SetPoint('TOPLEFT', 0, -48)
	local grids = {4, 8, 16, 32}
	local gridIndex = 2
	for index, value in ipairs(grids) do if value == DB().grid then gridIndex = index end end
	local gridControl = Kit:Segmented(body, {items = {'4', '8', '16', '32'}, width = 160, value = gridIndex, onChange = function(index)
		DB().grid = grids[index]
		UI:RefreshMoverGrid()
	end})
	gridControl:SetPoint('TOPLEFT', 60, -42)
	local snapLabel = Kit:Label(body, 'Snap', 'ink', 9)
	snapLabel:SetPoint('TOPRIGHT', -62, -48)
	local snap = Kit:Switch(body, {labels = false, checked = DB().snap and true or false, onChange = function(value) DB().snap = value end})
	snap:SetPoint('TOPRIGHT', 0, -42)

	-- Edit Mode is opened from the game menu only: opening it from addon code
	-- taints it, and its later saves on protected bars then fail.
	local editNote = Kit:Text(body, 'Objectives, buffs, the minimap and chat are placed with the game\'s Edit Mode: open the game menu (Esc) and choose Edit Mode.', 8, 'dim')
	editNote:SetPoint('TOPLEFT', 0, -82)
	editNote:SetWidth(bodyWidth)
	editNote:SetJustifyH('LEFT')

	local saveLabel = Kit:Label(body, 'Save this layout as', 'ink', 9)
	saveLabel:SetPoint('TOPLEFT', 0, -112)
	local name = Kit:TextField(body, {width = bodyWidth - 96, placeholder = 'Layout name', onEnter = function(text) SaveCustom(text) end})
	name:SetPoint('TOPLEFT', 0, -128)
	local save = Kit:Button(body, {text = 'Save', width = 86, height = 30})
	save:SetPoint('TOPRIGHT', 0, -129)
	save.onClick = function() SaveCustom(name:GetValue()) end

	local listTitle = Kit:Label(body, 'Saved layouts', 'dim', 8)
	listTitle:SetPoint('TOPLEFT', 0, -172)
	local list = CreateFrame('Frame', nil, body)
	list:SetPoint('TOPLEFT', 0, -188)
	list:SetSize(bodyWidth, 10)
	local rows = {}
	local ROW = 32
	function page.drawCustom()
		local entries = DB().custom
		for index, entry in ipairs(entries) do
			local row = rows[index]
			if not row then
				row = CreateFrame('Frame', nil, list)
				row:SetSize(bodyWidth, ROW - 4)
				row.lamp = Kit:Led(row, 5, false)
				row.lamp:SetPoint('LEFT', 2, 0)
				row.name = Kit:Text(row, '', 10, 'ink')
				row.name:SetPoint('LEFT', 14, 0)
				row.name:SetPoint('RIGHT', row, 'RIGHT', -170, 0)
				row.name:SetJustifyH('LEFT')
				row.name:SetWordWrap(false)
				row.delete = Kit:Button(row, {text = 'Delete', width = 74, height = 24})
				row.delete:SetPoint('RIGHT')
				row.apply = Kit:Button(row, {text = 'Apply', width = 74, height = 24})
				row.apply:SetPoint('RIGHT', row.delete, 'LEFT', -8, 0)
				rows[index] = row
			end
			row:ClearAllPoints()
			row:SetPoint('TOPLEFT', 0, -(index - 1) * ROW)
			row.name:SetText(entry.name)
			Kit:SetLed(row.lamp, DB().preset == 'custom:'..entry.name)
			row.apply.onClick = function()
				Kit:AlertDialog({title = 'Use '..entry.name, confirm = 'Apply', text = 'Every frame moves to this saved layout.',
					onConfirm = function() ApplyCustom(entry) end})
			end
			row.delete.onClick = function()
				Kit:AlertDialog({title = 'Delete '..entry.name, confirm = 'Delete', tone = 'error', text = 'This saved layout is removed.',
					onConfirm = function()
						for i, other in ipairs(DB().custom) do if other == entry then table.remove(DB().custom, i) break end end
						page.drawCustom()
					end})
			end
			row:Show()
		end
		for index = #entries + 1, #rows do rows[index]:Hide() end
		if #entries == 0 then
			list.empty = list.empty or Kit:Text(list, 'Nothing saved yet.', 9, 'dim')
			list.empty:SetPoint('TOPLEFT')
			list.empty:Show()
		elseif list.empty then
			list.empty:Hide()
		end
		list:SetHeight(max(#entries * ROW, 16))
		-- The card grows with its list; the page re-flows when it is next built.
		card:SetHeight(28 + 188 + max(#entries * ROW, 16) + 14)
		edit:SetKeyText(UI:MoversUnlocked() and 'Lock layout' or 'Unlock mode')
	end
	page.drawCustom()
	return card
end

-- For the installer and other modules ------------------------------------------------------
-- The presets as {key, title, note, model}, in order.
function UI:LayoutPresets()
	local list = {}
	for _, preset in ipairs(PRESETS) do
		list[#list + 1] = {key = preset.key, title = preset.title, note = preset.note, model = preset.model}
	end
	return list
end

-- Apply a preset by key, as its card on the Layout page does (no confirmation).
function UI:ApplyLayoutPreset(key)
	local preset = PRESET_BY_KEY[key]
	if not preset then return false end
	ApplyPreset(preset)
	return true
end

-- Apply a screen layout: size 'auto' | '1080' | '1440' | '2160', density 'compact' | 'comfortable'.
function UI:ApplyScreenLayout(sizeKey, densityKey) ApplyResolution(sizeKey, densityKey) end

-- The size class this screen is detected as, its title and the UI scale a layout would give.
function UI:ScreenLayoutPlan(sizeKey, densityKey)
	local resolution, _, scale, height = Plan(sizeKey, densityKey)
	return resolution.key, resolution.title, scale, height
end

UI:RegisterPage('layout', {title = 'Layout', order = 3, span = 4,
	build = function(content, page)
		page.controls = {}
		local cards = {BuildMapCard(content, page), BuildPresetsCard(content, page), BuildScreenCard(content, page),
			BuildEditCard(content, page)}
		local height = Kit:FlowCards(content, cards, 4)
		-- The map follows the real frames: on any mover change, and twice a second
		-- for frames that move on their own (modules re-laying out, Edit Mode).
		local dirty, elapsed = true, 0
		local ticker = CreateFrame('Frame', nil, content)
		ticker:SetScript('OnUpdate', function(_, delta)
			elapsed = elapsed + delta
			if not dirty and elapsed < 0.5 then return end
			if elapsed < 0.05 then return end
			dirty, elapsed = false, 0
			UI:Safe(page.drawMap)
			UI:Safe(page.inspect)
		end)
		UI:OnMoversChanged(function(key)
			dirty = true
			if key == '__lock' and page.drawCustom then page.drawCustom() end
		end)
		Refresh = function()
			dirty = true
			UI:Safe(page.drawPresets)
			UI:Safe(page.drawScreen)
			UI:Safe(page.drawCustom)
		end
		page.refresh = Refresh
		Refresh()
		return height
	end,
	onShow = function()
		UI:SetMoverKeys('hub', true)
		if Refresh then Refresh() end
	end,
	onHide = function() UI:SetMoverKeys('hub', false) end})
