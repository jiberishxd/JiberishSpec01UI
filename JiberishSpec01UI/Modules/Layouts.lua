-- The hub's Layout page: every frame of the interface on one map.
--
--   Map        a scaled-down screen on a black display, one glass block per
--              frame at its true place and size. Click a block to select it,
--              drag it to move the real frame (snapped like the handles).
--   Inspector  the selected frame's anchor, offsets, scale, opacity and
--              visibility, with reset and centre keys.
--   Presets    whole arrangements, drawn as small maps: Jiberish's own setup,
--              and the same with every unit frame inside the console.
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
local IsSecret, Round = UI.Util.IsSecret, UI.Util.Round

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

-- Settings may be tables (the console's own arrangement): compared by content
-- and written as copies, so a layout's own table is never edited in place.
local function Copy(value)
	if type(value) ~= 'table' then return value end
	local copy = {}
	for key, item in pairs(value) do copy[key] = Copy(item) end
	return copy
end
local function Same(a, b)
	if type(a) ~= 'table' or type(b) ~= 'table' then return a == b end
	for key, item in pairs(a) do if not Same(item, b[key]) then return false end end
	for key in pairs(b) do if a[key] == nil then return false end end
	return true
end

local function ApplySettings(settings)
	local reload = false
	for path, value in pairs(settings or {}) do
		local node, leaf = Resolve(path)
		if node and not Same(node[leaf], value) then
			Kit:SetOption(path, Copy(value))
			if RELOAD[path] or path:find('^style%.') then reload = true end
		end
	end
	return reload
end

local function ReloadToast()
	UI:NeedsReload()
	Kit:Toast({title = 'Reload to finish', text = 'Some of this layout takes effect after a reload.',
		action = {text = 'Reload', reload = true}})
end

-- Presets (defined with the solver below) ----------------------------------------------
local Refresh -- the page's refresh, set when it is built
local PRESETS, PRESET_BY_KEY = {}, {}
local ApplyPreset, ConfirmPreset
-- Layouts there used to be, and the one each now opens as (saved settings may
-- still name them).
local RENAMED = {console = 'main', cockpit = 'main', center = 'main', centre = 'main', healer = 'main', classic = 'main',
	zen = 'main', minimal = 'main', wide = 'main', streamer = 'main'}
local function Lookup(key) return type(key) == 'string' and PRESET_BY_KEY[RENAMED[key] or key] or nil end

-- Custom layouts: positions as fractions of the screen, so they carry across resolutions.
local SNAPSHOT = {'actionbars.layout', 'actionbars.dock', 'actionbars.rows', 'actionbars.side', 'actionbars.keySize',
	'actionbars.consoleWidth', 'actionbars.consoleHeight', 'actionbars.dockFocus', 'actionbars.dockToT', 'actionbars.dockPet',
	'actionbars.consoleLayout', 'actionbars.menuLayout', 'actionbars.menuEdge', 'unitframes.scale', 'nameplates.scale', 'style.infopanel'}

local function SaveCustom(name)
	name = strtrim(name or '')
	if name == '' then return UI:Print('Give the layout a name first.') end
	local width, height = UIParent:GetSize()
	local entry = {name = name, settings = {}, movers = {}}
	for _, path in ipairs(SNAPSHOT) do
		local node, leaf = Resolve(path)
		if node then entry.settings[path] = Copy(node[leaf]) end
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
	-- The arrangement in use is solved again for the new scale once it has
	-- settled, and again after the reload that applies the new key sizes.
	local preset = Lookup(DB().preset)
	if preset then
		if reload then DB().resolvePending = preset.key end
		C_Timer.After(0.8, function()
			if not InCombatLockdown() and ApplyPreset then ApplyPreset(preset, {quiet = true, keepSettings = true}) end
		end)
	end
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

-- Layout solver --------------------------------------------------------------------------
-- A layout is a list of placement rules run in order on a model of the screen
-- (bottom-left origin, UIParent units). Each rule asks for a spot against a
-- screen edge or next to a frame placed before it. A spot that would overlap
-- a placed frame, a frame Edit Mode owns (chat, minimap, objectives, buffs), a
-- reserved area or the screen's edge is nudged along the rule's free
-- directions in grid steps, nearest first; failing that it is tried smaller
-- (down to 75%), then at the rule's fallback. Sizes are the frames' real sizes
-- without any layout scale; frames a layout builds after its reload (bars,
-- a re-sized console) use fair guesses, and the layout is solved again once
-- they exist. Every remaining frame is fitted from its default spot the same
-- way, so nothing is left overlapping.
local STEP, MARGIN, GAP, PAD = 8, 12, 10, 3
local SHRINK = {1, 0.9, 0.8, 0.75}
local DIRS = {up = {0, 1}, down = {0, -1}, left = {-1, 0}, right = {1, 0}}

-- Frames that never show at the same time may share a spot.
local EXCLUSIVE = {['group.small'] = 'group.large', ['group.large'] = 'group.small',
	['group.boss'] = 'group.arena', ['group.arena'] = 'group.boss', ['dm.dock'] = 'dm.own', ['dm.own'] = 'dm.dock'}

-- Sizes for frames not built yet, by key prefix.
local GUESS = {{'ab.bar', 480, 50}, {'ab.side', 50, 480}, {'ab.menu', 160, 60}, {'ab.bags', 160, 34}, {'ab.', 160, 44},
	{'uf.player', 224, 70}, {'uf.target', 224, 70}, {'uf.party', 176, 50}, {'uf.', 136, 36}, {'cb.', 240, 30},
	{'group.small', 420, 200}, {'group.large', 560, 300}, {'group.', 200, 300}, {'dm.', 270, 180}, {'tl.', 440, 60},
	{'nav.compass', 460, 86}, {'nav.map', 300, 300}}

-- Frames the game's Edit Mode places: never moved from here, but nothing may
-- cover them. Extra room around chat for its tabs and edit box.
local OBSTACLES = {{'ChatFrame1', 4, 28, 4, 30}, {'MinimapCluster', 4, 4, 4, 4}, {'ObjectiveTrackerFrame', 4, 4, 4, 4},
	{'BuffFrame', 4, 4, 4, 4}, {'DebuffFrame', 4, 4, 4, 4}}

-- Docked into the console when the layout docks: always (true), or when the
-- layout also docks that frame (the setting that does).
local DOCKABLE = {['uf.player'] = true, ['uf.target'] = true, ['cb.player'] = true, ['cb.target'] = true,
	['uf.focus'] = 'actionbars.dockFocus', ['uf.targettarget'] = 'actionbars.dockToT', ['uf.pet'] = 'actionbars.dockPet'}

-- The console settings its size follows (a layout that changes one of them
-- builds a new console on its reload).
local CONSOLE_SETTINGS = {'layout', 'dock', 'rows', 'keySize', 'consoleWidth', 'consoleHeight', 'dockFocus', 'dockToT', 'dockPet'}

-- A raid, boss or arena holder's size from its settings, for when it reports
-- none (no group yet, or not built).
local function GroupSize(kind)
	local p = UI.db.group and UI.db.group[kind]
	if type(p) ~= 'table' or not p.width or not p.height then return nil end
	local scale = p.scale or 1
	if kind == 'boss' or kind == 'arena' then return p.width * scale, (5 * p.height + 4 * (p.spacing or 0)) * scale end
	local rows, columns = p.unitsPerColumn or 5, p.maxColumns or 4
	local vertical = not (p.growth or 'down_right'):find('^left') and not (p.growth or 'down_right'):find('^right')
	local spacing, columnSpacing = p.spacing or 0, p.columnSpacing or 0
	if vertical then
		return (columns * p.width + (columns - 1) * columnSpacing) * scale, (rows * p.height + (rows - 1) * spacing) * scale
	end
	return (rows * p.width + (rows - 1) * spacing) * scale, (columns * p.height + (columns - 1) * columnSpacing) * scale
end

-- The console a layout's settings build, measured as the action bar module
-- does (Hardware look, default function keys), for a layout that changes it:
-- the console on screen is the one before the reload.
local function ConsoleGuess(settings)
	local db = UI.db.actionbars or {}
	local function Get(key)
		local value = settings['actionbars.'..key]
		if value == nil then value = db[key] end
		return value
	end
	local keySize, rows = tonumber(Get('keySize')) or 34, tonumber(Get('rows')) or 3
	local dock = Get('dock') ~= false
	local fn = Get('fnKeys') ~= false and 64 or 0
	local column = dock and 238 or 0
	local width, height = tonumber(Get('consoleWidth')) or 0, tonumber(Get('consoleHeight')) or 0
	if width <= 0 then width = 20 + 12 * keySize + 55 + 2 * (column + fn) end
	local frames = dock and (Get('dockFocus') and 162 or Get('dockToT') and 148 or 94) or 0
	local body = max(rows * (keySize + 11) + (rows - 1) * 5, frames, fn)
	if height <= 0 then height = 24 + body + (dock and 36 or 0) + 35 end
	return width, height
end

-- Whether the console on screen was built with these settings. Its size
-- applies at once; the rest on a reload, so they are compared with the values
-- this session started with (builtWith, kept on entering the world).
local LIVE_CONSOLE = {consoleWidth = true, consoleHeight = true}
local builtWith
local function ConsoleCurrent(settings)
	local db = UI.db.actionbars or {}
	for _, key in ipairs(CONSOLE_SETTINGS) do
		local wanted, now = settings['actionbars.'..key], db[key]
		if builtWith and not LIVE_CONSOLE[key] then now = builtWith[key] end
		if wanted ~= nil and now ~= nil and wanted ~= now then return false end
	end
	return true
end

-- Never placed by a layout: devices the player pops out and places themself.
local function Unmanaged(key) return key:find('^gadget%.') ~= nil end

-- The info panel's strips and HUD, only while its layout shows them.
local function InfoShown(key)
	local p = UI.db.infopanel
	if type(p) ~= 'table' then return true end
	local layout = p.layout or 'strips'
	if key == 'ip.hud' then return layout == 'hud' or layout == 'both' end
	if key == 'ip.extra' and not p.extra then return false end
	return layout ~= 'hud'
end

local function Solver(preset)
	local W, H = UIParent:GetSize()
	local settings = preset.settings or {}
	local free = settings['actionbars.layout'] == 'free'
	local docked = not free and settings['actionbars.dock'] ~= false
	local rows = settings['actionbars.rows'] or 3
	local fresh = ConsoleCurrent(settings)
	local s = {W = W, H = H, rects = {}, scale = {}, order = {}, shrunk = false, missed = {}, blocks = {}, sizes = {},
		docked = docked, free = free}

	-- A frame's size without any layout scale.
	function s.size(key)
		local cached = s.sizes[key]
		if cached then return cached[1], cached[2] end
		local width, height
		if key == 'ab.console' and not fresh then
			width, height = ConsoleGuess(settings)
		elseif UI:HasMover(key) then
			width, height = UI:GetMoverSize(key)
			local multiplier = UI:GetMoverOption(key, 'scale') or 1
			if width and multiplier > 0 then width, height = width / multiplier, height / multiplier end
		end
		if (not width or width < 2 or not height or height < 2) and key:find('^group%.') then
			width, height = GroupSize(key:sub(7))
		end
		if not width or width < 2 or not height or height < 2 then
			width, height = 120, 40
			for _, guess in ipairs(GUESS) do
				if key:sub(1, #guess[1]) == guess[1] then width, height = guess[2], guess[3] break end
			end
			if key == 'ab.console' then width, height = ConsoleGuess(settings) end
		end
		s.sizes[key] = {width, height}
		return width, height
	end
	-- Its size at a layout scale.
	function s.dims(key, scale)
		local width, height = s.size(key)
		return width * (scale or 1), height * (scale or 1)
	end

	-- Docked by this layout.
	local function Docks(key)
		local rule = DOCKABLE[key]
		if rule == true then return true end
		return rule and settings[rule] == true or false
	end

	function s.present(key)
		if Unmanaged(key) then return false end
		-- Docked frames are placed by the console. A layout that docks, applied
		-- before the reload that docks them, places them beside it meanwhile.
		if docked and Docks(key) and (UI:MoverDocked(key) or not UI:HasMover(key)) then return false end
		-- Any other frame its dock holds (stance and pet keys put back in the
		-- console) takes no screen space. The unit frames above follow the layout's own docking.
		if not DOCKABLE[key] and UI.MoverDocked and UI:MoverDocked(key) then return false end
		if key == 'ab.console' then return not free end
		-- The micro menu set into the console's header takes no space of its own.
		if key == 'ab.menu' then
			local menu = settings['actionbars.menuLayout']
			if menu == nil and type(UI.db.actionbars) == 'table' then menu = UI.db.actionbars.menuLayout end
			if menu == 'console' then return false end
		end
		local bar = key:match('^ab%.bar(%d)$')
		if bar then return free and tonumber(bar) <= rows end
		if key:find('^ip%.') and not InfoShown(key) then return false end
		return UI:HasMover(key)
	end

	-- Areas nothing may cover: Edit Mode frames, and any the layout reserves.
	for _, spec in ipairs(OBSTACLES) do
		local cx, cy, width, height = FrameRect(_G[spec[1]])
		if cx then
			s.blocks[#s.blocks + 1] = {x = cx + W / 2 - width / 2 - spec[2], y = cy + H / 2 - height / 2 - spec[5],
				w = width + spec[2] + spec[4], h = height + spec[3] + spec[5], label = spec[1]}
		end
	end
	function s.reserve(x, y, width, height) s.blocks[#s.blocks + 1] = {x = x, y = y, w = width, h = height, reserved = true} end

	local function Overlap(a, x, y, width, height)
		return x < a.x + a.w + PAD and a.x < x + width + PAD and y < a.y + a.h + PAD and a.y < y + height + PAD
	end

	-- rule: edge (may sit flush on the screen's edge), dip (may hang that far
	-- under the bottom edge), over (frames it is meant to sit on, as a list).
	local function Free(key, x, y, width, height, rule)
		local edge = rule and rule.edge
		local inset = edge and 0 or MARGIN / 2
		local bottom = rule and rule.dip and -rule.dip or 2
		if x < inset or y < bottom or x + width > W - inset or y + height > H - 2 then return false end
		local over = rule and rule.over
		for other, rect in pairs(s.rects) do
			if other ~= key and EXCLUSIVE[key] ~= other and Overlap(rect, x, y, width, height) then
				local allowed = false
				for _, name in ipairs(over or {}) do if name == other then allowed = true break end end
				if not allowed then return false end
			end
		end
		for _, rect in ipairs(s.blocks) do
			if Overlap(rect, x, y, width, height) then return false end
		end
		return true
	end

	-- The nearest free spot from (x, y), stepping along the given directions.
	local function Nearest(key, x, y, width, height, nudge, rule)
		if Free(key, x, y, width, height, rule) then return x, y end
		local steps = math.ceil(max(W, H) / STEP)
		local alive = {}
		for index = 1, #nudge do alive[index] = DIRS[nudge[index]] ~= nil end
		for step = 1, steps do
			local any = false
			for index, name in ipairs(nudge) do
				if alive[index] then
					local dir = DIRS[name]
					local tx, ty = x + dir[1] * step * STEP, y + dir[2] * step * STEP
					if tx < -width or ty < -height or tx > W or ty > H then
						alive[index] = false
					else
						any = true
						if Free(key, tx, ty, width, height, rule) then return tx, ty end
					end
				end
			end
			if not any then break end
		end
	end

	local function Record(key, x, y, width, height, factor)
		s.rects[key] = {x = x, y = y, w = width, h = height}
		s.scale[key] = factor
		s.order[#s.order + 1] = key
		if factor < 0.999 * (s.asked[key] or 1) then s.shrunk = true end
		return s.rects[key]
	end
	s.asked = {}

	-- One try at a spot: the nearest free place from (x, y) along opts.nudge,
	-- at the asked scale and then smaller. (x, y) is the bottom-left at the
	-- asked scale; a smaller try keeps the same centre line and bottom.
	local function Attempt(key, x, y, opts)
		local width, height = s.size(key)
		local nudge = opts.nudge or {'up', 'left', 'right'}
		local start = opts.scale or 1
		s.asked[key] = start
		-- A frame taller than allowed starts at the scale that fits the cap.
		if opts.maxHeight and height * start > opts.maxHeight then start = max(start * SHRINK[#SHRINK], opts.maxHeight / height) end
		for _, step in ipairs(SHRINK) do
			local factor = start * step
			local sw, sh = width * factor, height * factor
			local bx = x + (width * (opts.scale or 1) - sw) / 2
			local fx, fy = Nearest(key, bx, y, sw, sh, nudge, opts)
			if fx then return Record(key, fx, fy, sw, sh, factor) end
			if opts.fallback then
				local ax, ay = opts.fallback(sw, sh)
				if ax then
					fx, fy = Nearest(key, ax, ay, sw, sh, nudge, opts)
					if fx then return Record(key, fx, fy, sw, sh, factor) end
				end
			end
		end
	end

	-- Nothing fitted: keep it on the screen at its asked-for spot, and note it.
	local function Miss(key, x, y, opts)
		local width, height = s.size(key)
		local factor = (opts and opts.scale) or 1
		width, height = width * factor, height * factor
		s.missed[#s.missed + 1] = key
		return Record(key, min(max(x, 0), max(W - width, 0)), min(max(y, 0), max(H - height, 0)), width, height, factor)
	end

	-- Place a frame with its bottom-left at (x, y), or the nearest free spot.
	-- opts: nudge (directions, nearest first), scale (the frame's own layout
	-- scale, tried smaller only when nothing fits), maxHeight, edge, dip, over
	-- (see Free), fallback(width, height) -> x, y.
	function s.put(key, x, y, opts)
		if s.rects[key] or not s.present(key) then return s.rects[key] end
		opts = opts or {}
		return Attempt(key, x, y, opts) or Miss(key, x, y, opts)
	end

	-- Place a frame by its centre.
	function s.at(key, cx, cy, opts)
		local width, height = s.dims(key, opts and opts.scale)
		return s.put(key, cx - width / 2, cy - height / 2, opts)
	end

	-- Several candidate spots in order, {x, y, opts} each; the first that fits wins.
	function s.try(key, candidates)
		if s.rects[key] or not s.present(key) then return s.rects[key] end
		for _, candidate in ipairs(candidates) do
			local rect = Attempt(key, candidate[1], candidate[2], candidate[3] or {})
			if rect then return rect end
		end
		local first = candidates[1] or {MARGIN, MARGIN}
		return Miss(key, first[1], first[2], first[3])
	end

	-- The raid grids always get a spot: the layout's own choices first, then a
	-- column on the left over chat (smaller if need be), then centred above the
	-- core, then the top left under the objectives, then anywhere free. The
	-- small and large grids never show together, so the large one takes the
	-- small one's spot when it can.
	function s.raid(candidates)
		local core = s.highest({'ab.console', 'ab.bar1', 'ab.bar2', 'ab.bar3', 'cb.player', 'cb.target', 'tl.player', 'ab.extra',
			'uf.player', 'uf.target'}, MARGIN)
		for _, key in ipairs({'group.small', 'group.large'}) do
			if s.present(key) and not s.rects[key] then
				local width, height = s.size(key)
				local list = {}
				local small = key == 'group.large' and s.rects['group.small']
				if small then list[#list + 1] = {small.x, small.y, {nudge = {'up', 'right', 'left'}}} end
				for _, candidate in ipairs(candidates or {}) do list[#list + 1] = candidate end
				list[#list + 1] = {MARGIN, MARGIN, {nudge = {'up', 'right'}, scale = 0.9}}
				list[#list + 1] = {MARGIN, MARGIN, {nudge = {'up', 'right'}, scale = 0.75}}
				list[#list + 1] = {W / 2 - width / 2, core + 16, {nudge = {'up', 'left', 'right'}}}
				list[#list + 1] = {MARGIN, H * 0.72 - height, {nudge = {'down', 'right'}, scale = 0.9}}
				list[#list + 1] = {W / 2 - width / 2, H / 2 - height / 2, {nudge = {'up', 'down', 'left', 'right'}, scale = 0.75}}
				s.try(key, list)
			end
		end
	end

	-- Player and target as a mirror pair: the same height, symmetric about
	-- centreX with `gap` from it to each frame's inner edge. If either spot is
	-- taken, both move together: up first (down with opts.down), then further
	-- out, nearest first; then both smaller. opts.scale: both frames' scale.
	function s.pair(leftKey, rightKey, centreX, gap, y, opts)
		opts = opts or {}
		local start = opts.scale or 1
		local leftOn, rightOn = s.present(leftKey) and not s.rects[leftKey], s.present(rightKey) and not s.rects[rightKey]
		if not (leftOn and rightOn) then
			if leftOn then s.put(leftKey, centreX - gap - s.dims(leftKey, start), y, {nudge = {'up', 'left'}, scale = start}) end
			if rightOn then s.put(rightKey, centreX + gap, y, {nudge = {'up', 'right'}, scale = start}) end
			return
		end
		s.asked[leftKey], s.asked[rightKey] = start, start
		for _, shrink in ipairs(SHRINK) do
			local factor = start * shrink
			local lw, lh = s.dims(leftKey, factor)
			local rw, rh = s.dims(rightKey, factor)
			local steps = math.ceil(H / STEP)
			for step = 0, steps do
				for _, out in ipairs(opts.outward == false and {0} or {0, 1, 2, 3, 4, 6, 8, 12, 16}) do
					local up = (opts.down and -1 or 1) * step * STEP
					local spread = out * STEP
					local lx, rx, ty = centreX - gap - lw - spread, centreX + gap + spread, y + up
					if Free(leftKey, lx, ty, lw, lh) and Free(rightKey, rx, ty, rw, rh) then
						Record(leftKey, lx, ty, lw, lh, factor)
						Record(rightKey, rx, ty, rw, rh, factor)
						return
					end
				end
			end
		end
		s.put(leftKey, centreX - gap - s.dims(leftKey, start), y, {nudge = {'up', 'left'}, scale = start})
		s.put(rightKey, centreX + gap, y, {nudge = {'up', 'right'}, scale = start})
	end

	-- Helpers for rules.
	function s.get(key) return s.rects[key] end
	function s.top(key, fallback) local rect = s.rects[key] return rect and rect.y + rect.h or fallback end
	function s.right(key, fallback) local rect = s.rects[key] return rect and rect.x + rect.w or fallback end
	function s.left(key, fallback) local rect = s.rects[key] return rect and rect.x or fallback end
	function s.bottom(key, fallback) local rect = s.rects[key] return rect and rect.y or fallback end
	function s.mid(key, scale) local width = s.dims(key, scale) return W / 2 - width / 2 end
	-- The highest top among the given keys (those placed), or a default.
	function s.highest(keys, default)
		local best = default
		for _, key in ipairs(keys) do
			local top = s.top(key)
			if top and (not best or top > best) then best = top end
		end
		return best
	end
	-- Place a frame above the highest of the given frames, centred on the first
	-- of them that is placed (so it follows a console that isn't centred).
	function s.above(key, keys, gap, opts)
		local width = s.dims(key, opts and opts.scale)
		local x = W / 2 - width / 2
		for _, other in ipairs(keys) do
			local rect = s.rects[other]
			if rect then x = rect.x + rect.w / 2 - width / 2 break end
		end
		return s.put(key, x, s.highest(keys, MARGIN) + (gap or GAP), opts or {nudge = {'up'}})
	end
	return s
end

-- Shared rules ------------------------------------------------------------------------------
-- The frames every layout puts on the screen's edges, after its own core:
-- whatever the layout has not placed yet. opts: meters ('corner' | 'middle'),
-- party ('left' | 'right'), edgeScale.
local CORE_KEYS = {'ab.console', 'ab.bar1', 'ab.bar2', 'ab.bar3', 'uf.player', 'uf.target', 'cb.player', 'cb.target',
	'group.small', 'tl.player', 'ab.extra'}

local function Edges(s, opts)
	opts = opts or {}
	local W, H, edge = s.W, s.H, opts.edgeScale or 1
	-- Top centre: the HUD, then the combat status and banners under it.
	local _, hudHeight = s.size('ip.hud')
	s.put('ip.hud', s.mid('ip.hud'), H - hudHeight - 4, {nudge = {'down'}})
	local _, statusHeight = s.size('cue.status')
	s.put('cue.status', s.mid('cue.status'), s.bottom('ip.hud', H) - statusHeight - GAP, {nudge = {'down'}})
	local _, bannerHeight = s.size('nt.banner')
	s.put('nt.banner', s.mid('nt.banner'), s.bottom('cue.status', s.bottom('ip.hud', H)) - bannerHeight - GAP, {nudge = {'down'}})
	-- Right edge: side bars centred, the menu in the corner.
	local sideWidth, sideHeight = s.size('ab.side')
	s.put('ab.side', W - sideWidth - 6, H / 2 - sideHeight / 2, {nudge = {'down', 'up', 'left'}})
	-- Bottom-right corner: the menu, the bag keys right-aligned just above it. If
	-- the console reaches the corner, they go up over its right end.
	local menuWidth = s.size('ab.menu')
	s.put('ab.menu', W - menuWidth - MARGIN, MARGIN, {nudge = {'up', 'left'}})
	local bagKeysWidth = s.size('ab.bags')
	s.put('ab.bags', s.right('ab.menu', W - MARGIN) - bagKeysWidth, s.top('ab.menu', MARGIN) + 6, {nudge = {'up', 'left'}})
	-- Meters: a column at the right edge, stacked upward over the menu (or from
	-- the middle), each at most a third of the screen tall.
	local meterCap = H * 0.35
	local meterWidth, meterHeight = s.size('dm.own')
	-- Meters and bags keep left of the side bar column over its whole height.
	local sideLeft = s.left('ab.side')
	local sideRoom = sideLeft and (W - sideLeft) + GAP - MARGIN or 0
	local meterY = opts.meters == 'middle' and H * 0.4 - min(meterHeight, meterCap) / 2
		or s.highest({'ab.menu', 'ab.bags'}, MARGIN) + GAP
	s.put('dm.own', W - meterWidth - MARGIN - sideRoom, meterY, {nudge = {'up', 'left'}, scale = edge, maxHeight = meterCap})
	s.put('dm.dock', s.left('dm.own', W - meterWidth - MARGIN - sideRoom), s.bottom('dm.own', meterY),
		{nudge = {'up', 'left'}, scale = edge, maxHeight = meterCap})
	for index = 2, 3 do
		local key, previous = 'dm.own'..index, index == 2 and 'dm.own' or 'dm.own2'
		local width = s.dims(key, edge)
		s.put(key, s.right(previous, W - MARGIN - sideRoom) - width, s.top(previous, meterY) + GAP,
			{nudge = {'up', 'left'}, scale = edge, maxHeight = meterCap})
	end
	-- Bags over the meters at the right edge.
	local bagsWidth = s.dims('bags.bags', edge)
	s.put('bags.bags', W - bagsWidth - MARGIN - sideRoom, s.highest({'dm.own', 'dm.own2', 'dm.own3', 'dm.dock', 'ab.menu', 'ab.bags'}, MARGIN) + GAP,
		{nudge = {'up', 'left'}, scale = edge})
	-- Boss and arena: a column left of the side bars, upper half.
	local bossWidth, bossHeight = s.dims('group.boss', edge)
	local columnRight = s.left('ab.side', W - 6) - 16
	s.put('group.boss', columnRight - bossWidth, H * 0.66 - bossHeight, {nudge = {'down', 'left', 'up'}, scale = edge})
	local arenaWidth, arenaHeight = s.dims('group.arena', edge)
	s.put('group.arena', columnRight - arenaWidth, H * 0.66 - arenaHeight, {nudge = {'down', 'left', 'up'}, scale = edge})
	-- The drawer's pull tab, flush on the right edge.
	local tabWidth = s.size('drawer.tab')
	s.put('drawer.tab', W - tabWidth, H * 0.3, {nudge = {'down', 'up'}, edge = true})
	-- Party: a column on the chosen side, from the middle down.
	local partyX
	for index = 1, 4 do
		local key = 'uf.party'..index
		local width, height = s.dims(key, edge)
		partyX = partyX or (opts.party == 'right' and W - width - MARGIN - s.size('ab.side') - 12 or MARGIN)
		local y = index == 1 and H * 0.62 - height or s.bottom('uf.party'..(index - 1), H * 0.62) - height - 6
		s.put(key, partyX, y, {nudge = {'down', opts.party == 'right' and 'left' or 'right', 'up'}, scale = edge})
	end
	-- Loot and notices around the middle, clear of the play area's centre.
	local lootWidth = s.size('nt.loot')
	s.put('nt.loot', W * 0.72 - lootWidth / 2, H * 0.42, {nudge = {'up', 'left', 'down'}})
	s.put('nt.rolls', s.mid('nt.rolls'), s.highest(CORE_KEYS, H * 0.3) + 24, {nudge = {'up'}})
	s.put('nt.lootwindow', W * 0.22, H * 0.52, {nudge = {'up', 'right', 'down'}})
	s.put('bags.bank', MARGIN, H * 0.52, {nudge = {'down', 'up', 'right'}})
	-- Everything else, from its own default spot.
	for _, entry in ipairs(UI:GetMovers()) do
		local key = entry.key
		if not s.rects[key] and s.present(key) then
			local anchor, x, y = UI:GetMoverDefault(key)
			local width, height = s.size(key)
			if anchor then
				local left = (anchor:find('LEFT') and 0 or anchor:find('RIGHT') and W - width or W / 2 - width / 2) + x
				local bottom = (anchor:find('BOTTOM') and 0 or anchor:find('TOP') and H - height or H / 2 - height / 2) + y
				s.put(key, left, bottom, {nudge = {'up', 'down', 'left', 'right'}})
			end
		end
	end
end

-- The layouts --------------------------------------------------------------------------------
-- Both are Jiberish's own arrangement, measured from the shipped profile at its
-- UI scale of 0.64 on a 16:9 screen (2133 x 1200 UI units) and written as
-- relations, so it keeps its shape on any screen: the console on the bottom
-- centre, the frames around it measured from it, from the screen's centre or
-- from the edge they sit on. Each frame keeps the scale it has there.

-- The console on the bottom centre, 11 from the edge.
local function Console(s, nudge)
	local width = s.size('ab.console')
	s.put('ab.console', s.W / 2 - width / 2, 11, {nudge = nudge or {'up'}})
	return s.get('ab.console') or {x = s.W / 2, y = 11, w = 0, h = 0}
end

-- The menu keys set over the console's header, right of its name; the drawer's
-- pull tab tucked under the console's bottom edge, centred.
local function ConsoleTrim(s, console)
	local cx = console.x + console.w / 2
	local menuWidth = s.dims('ab.menu', 0.75)
	s.put('ab.menu', cx + 86.6 - menuWidth, console.y + console.h - 24.2, {nudge = {'up'}, scale = 0.75, over = {'ab.console'}})
	local tabWidth = s.dims('drawer.tab', 1.28)
	s.put('drawer.tab', cx - tabWidth / 2, console.y - 15.8, {nudge = {'down', 'right'}, scale = 1.28, edge = true, dip = 6,
		over = {'ab.console'}})
end

-- The aura timeline centred at (cx, cy), the extra and zone abilities left of it.
local function Timeline(s, cx, cy)
	s.at('tl.player', cx, cy, {nudge = {'up'}, scale = 0.83})
	local centre = s.get('tl.player')
	local y = (centre and centre.y + centre.h / 2 or cy) - 31.5
	s.at('ab.extra', cx - 224, y, {nudge = {'left', 'up'}})
	s.at('ab.zone', cx - 291.6, y, {nudge = {'left', 'up'}})
end

-- The screen's edges: the info strips and banners along the top, the side
-- bars, meters, bag keys and boss frames on the right, the raid bottom left.
local function Frame(s)
	local W, H = s.W, s.H
	local width, height = s.dims('ip.main', 0.9)
	s.put('ip.main', W / 2 - width / 2, H - 17.6 - height, {nudge = {'down'}, scale = 0.9})
	width, height = s.dims('ip.extra', 0.9)
	s.put('ip.extra', 17.33, H - 43.2 - height, {nudge = {'down', 'right'}, scale = 0.9})
	width, height = s.dims('ip.hud')
	s.put('ip.hud', W / 2 - 4 - width / 2, H - 56.8 - height, {nudge = {'down'}})
	-- The NV-3 compass, centred under the info strip (and the HUD when it shows).
	width, height = s.dims('nav.compass')
	local under = min(s.bottom('ip.main', H - 17.6), s.bottom('ip.hud', H))
	s.put('nav.compass', W / 2 - width / 2, under - GAP - height, {nudge = {'down'}})
	width, height = s.dims('cue.status')
	s.put('cue.status', W / 2 - width / 2, min(H - 94, s.bottom('nav.compass', H) - GAP) - height, {nudge = {'down'}})
	-- Banners show briefly; they may come over the combat status.
	width, height = s.dims('nt.banner')
	s.put('nt.banner', W / 2 - width / 2, H - 146 - height, {nudge = {'down'}, over = {'cue.status'}})
	-- Right edge: the side bars, the meter in the corner level with the
	-- console's base, the bag keys over it; bags open over the meter.
	width, height = s.dims('ab.side')
	s.put('ab.side', W - 6 - width, H / 2 - 40 - height / 2, {nudge = {'down', 'up', 'left'}})
	-- Where a wide console leaves no room in the corner: left of the side bars, over the console.
	local function OverConsole(meterWidth) return s.left('ab.side', W - 6) - GAP - meterWidth, s.top('ab.console', 11) + GAP end
	width = s.dims('dm.own')
	s.put('dm.own', W - 6 - width, 11, {nudge = {'up', 'left'}, maxHeight = H * 0.35, fallback = OverConsole})
	s.put('dm.dock', W - 6 - s.dims('dm.dock'), 11, {nudge = {'up', 'left'}, maxHeight = H * 0.35, fallback = OverConsole})
	local meterTop = s.highest({'dm.own', 'dm.dock'}, 11)
	s.put('ab.bags', W - 15 - s.dims('ab.bags'), meterTop + 6.5, {nudge = {'up', 'left'}})
	local meter = s.get('dm.own') or s.get('dm.dock') or {x = W - 276, y = 11, w = 270, h = 0}
	s.put('bags.bags', meter.x + meter.w - 9 - s.dims('bags.bags'), meter.y + 9.8, {nudge = {'up', 'left'}, over = {'dm.own', 'dm.dock'}})
	-- The raid over chat, bottom left (the large grid flush with the margin).
	s.put('group.large', 494.93 - s.dims('group.large', 0.8), 286.4, {nudge = {'up', 'right'}, scale = 0.8})
	s.put('group.small', 452.26 - s.dims('group.small', 0.8), 286.4, {nudge = {'up', 'right'}, scale = 0.8})
	s.raid()
end

-- Around the screen's centre: the combat ring by your character, the focus to
-- its right, the party column on the left (over the raid on a short screen),
-- the boss and arena frames left of the side bars, loot and rolls (which give
-- way to them) right of the centre.
local function Middle(s)
	local W, H = s.W, s.H
	local _, height = s.dims('uf.party1')
	local raidTop = s.highest({'group.small', 'group.large'}, 0)
	local first = max(H / 2 + 93.2, raidTop + GAP + 3 * 50 + height / 2)
	for index = 1, 4 do
		_, height = s.dims('uf.party'..index)
		s.put('uf.party'..index, 300, first - (index - 1) * 50 - height / 2, {nudge = {'up', 'right', 'down'}})
	end
	s.at('cue.ring', W / 2 - 28, H / 2 - 22.8, {nudge = {'up', 'down'}})
	_, height = s.dims('uf.focus')
	s.put('uf.focus', W / 2 + 132.8, H / 2 - 22.8 - height / 2, {nudge = {'right', 'up', 'down'}})
	local width
	for _, key in ipairs({'group.boss', 'group.arena'}) do
		width, height = s.dims(key)
		s.put(key, W - 110.67 - width, H / 2 + 9.5 - height / 2, {nudge = {'down', 'up', 'left'}})
	end
	width, height = s.dims('nt.loot')
	s.put('nt.loot', W / 2 + 322.6 - width, H / 2 - 64.8 - height / 2, {nudge = {'up', 'down', 'right'}})
	width = s.dims('nt.rolls')
	s.put('nt.rolls', W / 2 + 280 - width / 2, H / 2 + 40, {nudge = {'up', 'down', 'left', 'right'}})
	-- The loot window opens beside the rolls (they may meet).
	_, height = s.dims('nt.lootwindow')
	s.put('nt.lootwindow', W / 2 + 435.67, H / 2 + 204 - height, {nudge = {'down', 'right', 'up', 'left'}, over = {'nt.rolls'}})
	_, height = s.dims('bags.bank')
	s.put('bags.bank', 12, H - 76.8 - height, {nudge = {'down', 'right'}})
end

-- The NV-4 overlay map (shown on demand), right of the centre: past the loot
-- feed and rolls and under the loot window, clear of the boss column, or
-- under the rolls (smaller where that is narrow); else right of the combat ring under the loot feed,
-- centred above the ring, or the nearest free spot.
local function OverlayMap(s)
	local W, H = s.W, s.H
	local width, height = s.dims('nav.map')
	local x = max(s.right('nt.rolls', W / 2), s.right('nt.loot', W / 2), s.right('uf.focus', W / 2)) + GAP
	local top = min(s.bottom('nt.lootwindow', H / 2 + height / 2 + GAP) - GAP, H / 2 + height / 2)
	local ring = s.top('cue.ring', H / 2 + 72)
	-- Or under the rolls, right of the loot feed.
	local x2 = max(s.right('nt.loot', W / 2), s.right('uf.focus', W / 2)) + GAP
	local top2 = min(s.bottom('nt.rolls', top + GAP), s.bottom('nt.lootwindow', top + GAP)) - GAP
	s.try('nav.map', {
		{x, top - height, {nudge = {'down', 'right', 'up'}}},
		{x2, top2 - height, {nudge = {'down', 'up', 'right'}}},
		{x, top - height, {nudge = {'down', 'right', 'up'}, scale = 0.85}},
		{s.right('cue.ring', W / 2 + 70) + GAP, s.bottom('nt.loot', H / 2 - 80) - GAP - height * 0.85,
			{nudge = {'down', 'right', 'left'}, scale = 0.85}},
		{W / 2 - width / 2, ring + GAP, {nudge = {'up', 'right', 'left'}}},
		{W / 2 + W * 0.17 - width / 2, H / 2 - height / 2, {nudge = {'up', 'down', 'right', 'left'}, scale = 0.75}},
	})
end

-- In a docking layout, frames not docked yet (before its reload) sit beside
-- the console meanwhile.
local function Flank(s, console)
	local _, unitHeight = s.size('uf.player')
	s.pair('uf.player', 'uf.target', console.x + console.w / 2, console.w / 2 + 8, max(MARGIN, console.y + console.h / 2 - unitHeight / 2))
	s.put('cb.player', s.left('uf.player', console.x - 248), s.top('uf.player', console.y + console.h) + 6, {nudge = {'up', 'left'}})
	s.put('cb.target', s.left('uf.target', console.x + console.w + 8), s.top('uf.target', console.y + console.h) + 6, {nudge = {'up', 'right'}})
	s.put('uf.focus', s.left('cb.player', console.x - 248), s.top('cb.player', console.y + console.h) + 6, {nudge = {'up', 'left'}})
	s.put('uf.pet', s.left('uf.player', console.x - 248), s.bottom('uf.player', MARGIN) - 36, {nudge = {'down', 'up', 'left'}})
	s.put('uf.targettarget', s.left('cb.target', console.x + console.w + 8), s.top('cb.target', console.y + console.h) + 6,
		{nudge = {'up', 'right'}})
end

PRESETS = {
	{key = 'main', title = 'Jiberish main', model = 'LY-1',
		note = 'Jiberish\'s own setup: a compact console, player and target mirrored over its ends with their cast bars, the timeline above, raid over chat.',
		settings = {['actionbars.layout'] = 'console', ['actionbars.dock'] = false, ['actionbars.rows'] = 2, ['actionbars.side'] = true,
			['actionbars.keySize'] = 34, ['actionbars.consoleWidth'] = 640, ['actionbars.consoleHeight'] = 0,
			['actionbars.dockFocus'] = false, ['actionbars.dockToT'] = false, ['actionbars.dockPet'] = false,
			['actionbars.consoleLayout'] = {}, ['actionbars.menuLayout'] = 'console', ['actionbars.menuEdge'] = 'header'},
		rules = function(s)
			local console = Console(s)
			local cx, top = console.x + console.w / 2, console.y + console.h
			-- Player and target mirrored over the console, outer edges at its ends.
			local width = s.dims('uf.player', 0.9)
			s.pair('uf.player', 'uf.target', cx, max(24, console.w / 2 + 1.6 - width), top + 84.5, {scale = 0.9})
			-- Their cast bars just over them, each from its frame's left edge.
			s.put('cb.player', s.left('uf.player', cx - 322), s.top('uf.player', top + 148) + 11, {nudge = {'up'}, scale = 0.84})
			s.put('cb.target', s.left('uf.target', cx + 120), s.top('uf.target', top + 148) + 10, {nudge = {'up'}, scale = 0.9})
			-- The pet and target of target between the console and them, at its ends.
			s.put('uf.pet', console.x, top + 44, {nudge = {'up', 'left'}})
			s.put('uf.targettarget', console.x + console.w - s.dims('uf.targettarget'), top + 25, {nudge = {'up', 'right'}})
			ConsoleTrim(s, console)
			Timeline(s, cx, s.highest({'cb.player', 'cb.target', 'uf.player', 'uf.target'}, top) + 76)
			Frame(s)
			Middle(s)
			OverlayMap(s)
			Edges(s, {meters = 'corner', party = 'left'})
		end},
	{key = 'integrated', title = 'Integrated console', model = 'LY-2',
		note = 'One CX-1 console holds it all: the key banks, player and target with the focus under the player, both cast bars, pet and target of target.',
		settings = {['actionbars.layout'] = 'console', ['actionbars.dock'] = true, ['actionbars.rows'] = 3, ['actionbars.side'] = true,
			['actionbars.keySize'] = 34, ['actionbars.consoleWidth'] = 0, ['actionbars.consoleHeight'] = 0,
			['actionbars.dockFocus'] = true, ['actionbars.dockToT'] = true, ['actionbars.dockPet'] = true,
			['actionbars.consoleLayout'] = {}, ['actionbars.menuLayout'] = 'console', ['actionbars.menuEdge'] = 'header'},
		rules = function(s)
			-- Centred; on a narrow screen it steps right of the chat rather than over it.
			local console = Console(s, {'right', 'up'})
			local cx, top = console.x + console.w / 2, console.y + console.h
			Flank(s, console)
			ConsoleTrim(s, console)
			-- The timeline over the console, its abilities clear of the stance and
			-- pet keys tucked on the console's top edge.
			local _, height = s.dims('tl.player', 0.83)
			Timeline(s, cx, s.highest({'cb.player', 'cb.target', 'uf.player', 'uf.target'}, top + 72) + height / 2)
			Frame(s)
			Middle(s)
			OverlayMap(s)
			Edges(s, {meters = 'corner', party = 'left'})
		end},
}
for _, preset in ipairs(PRESETS) do PRESET_BY_KEY[preset.key] = preset end

-- Solve a layout for the screen as it is now.
local function Solve(preset)
	local s = Solver(preset)
	local ok, problem = pcall(preset.rules, s)
	if not ok then geterrorhandler()(problem) end
	return s
end

-- A solved frame's spot, measured from the screen point nearest it, so it
-- stays on that edge when the resolution changes: anchor, x, y.
local function SpotOf(rect, W, H)
	local cx, cy = rect.x + rect.w / 2, rect.y + rect.h / 2
	local horizontal = cx < W / 3 and 'LEFT' or cx > W * 2 / 3 and 'RIGHT' or ''
	local vertical = cy < H / 3 and 'BOTTOM' or cy > H * 2 / 3 and 'TOP' or ''
	local point = vertical..horizontal
	if point == '' then point = 'CENTER' end
	local x = horizontal == 'LEFT' and rect.x or horizontal == 'RIGHT' and rect.x + rect.w - W or cx - W / 2
	local y = vertical == 'BOTTOM' and rect.y or vertical == 'TOP' and rect.y + rect.h - H or cy - H / 2
	return point, floor(x * 100 + 0.5) / 100, floor(y * 100 + 0.5) / 100
end

-- The placed frames as they really are now: {key = {x, y, w, h}}, bottom-left origin.
local function LiveRects()
	local W, H = UIParent:GetSize()
	local rects = {}
	for _, entry in ipairs(UI:GetMovers()) do
		if not entry.docked and not Unmanaged(entry.key) then
			local cx, cy = UI:GetMoverCenter(entry.key)
			local width, height = UI:GetMoverSize(entry.key)
			if cx and width and width > 1 and height > 1 then
				rects[entry.key] = {x = cx + W / 2 - width / 2, y = cy + H / 2 - height / 2, w = width, h = height}
			end
		end
	end
	return rects
end

-- Debug only: every pair of placed frames (and game frames) that still overlap.
local function ReportOverlaps(label)
	if not DB().debugLayout then return end
	local rects = LiveRects()
	local W, H = UIParent:GetSize()
	for _, spec in ipairs(OBSTACLES) do
		local cx, cy, width, height = FrameRect(_G[spec[1]])
		if cx then rects[spec[1]] = {x = cx + W / 2 - width / 2, y = cy + H / 2 - height / 2, w = width, h = height} end
	end
	local keys, found = {}, 0
	for key in pairs(rects) do keys[#keys + 1] = key end
	table.sort(keys)
	for i = 1, #keys do
		for j = i + 1, #keys do
			local a, b = rects[keys[i]], rects[keys[j]]
			if EXCLUSIVE[keys[i]] ~= keys[j] and a.x < b.x + b.w - 1 and b.x < a.x + a.w - 1 and a.y < b.y + b.h - 1 and b.y < a.y + a.h - 1 then
				found = found + 1
				UI:Print(format('Layout check (%s): %s overlaps %s.', label, keys[i], keys[j]))
			end
		end
	end
	if found == 0 then UI:Print(format('Layout check (%s): no overlaps.', label)) end
end

-- Modules lay their frames out after they move (the console grows to hold its
-- contents, meters resize to their rows): once they have, any frame whose
-- size differs from what the solver used means the layout is solved again.
local function Verify(preset, solved, pass)
	C_Timer.After(pass == 1 and 0.6 or 2, function()
		if InCombatLockdown() or DB().preset ~= preset.key then return end
		local live = LiveRects()
		local changed = false
		for key, rect in pairs(solved) do
			local now = live[key]
			if now and (abs(now.w - rect.w) > 4 or abs(now.h - rect.h) > 4) then changed = true break end
		end
		if changed and pass < 3 then
			ApplyPreset(preset, {quiet = true, keepSettings = true, pass = pass + 1})
		else
			ReportOverlaps(preset.title)
		end
	end)
end

-- For 10 s after a layout is applied (and after the reload one asks for),
-- the core frames' real sizes are watched: the console composes itself after
-- login, docked frames settle, the menu and meters size to their contents.
-- A real change (over 4 px from what the solver used) solves the layout again,
-- debounced, at most six times per apply.
local WATCHED = {['ab.console'] = true, ['uf.player'] = true, ['uf.target'] = true, ['ab.menu'] = true, ['ab.bags'] = true,
	['group.small'] = true, ['dm.own'] = true}
local watchUntil, watchCount, watchPending, lastRects = 0, 0, false, nil
local hookedSize = setmetatable({}, {__mode = 'k'})

local function SizeChanged()
	if watchPending or watchCount >= 6 or GetTime() > watchUntil then return end
	watchPending = true
	C_Timer.After(0.35, function()
		watchPending = false
		local preset = Lookup(DB().preset)
		if not preset or InCombatLockdown() or GetTime() > watchUntil or not lastRects then return end
		local live, changed = LiveRects(), false
		for key in pairs(WATCHED) do
			local now, then_ = live[key], lastRects[key]
			if now and then_ and (abs(now.w - then_.w) > 4 or abs(now.h - then_.h) > 4) then changed = true break end
		end
		if changed then
			watchCount = watchCount + 1
			ApplyPreset(preset, {quiet = true, keepSettings = true, watched = true})
		end
	end)
end

local function WatchSizes()
	watchUntil, watchCount = GetTime() + 10, 0
	for _, entry in ipairs(UI:GetMovers()) do
		local frame = entry.frame
		if WATCHED[entry.key] and frame and frame.HookScript and not hookedSize[frame] then
			hookedSize[frame] = true
			frame:HookScript('OnSizeChanged', SizeChanged)
		end
	end
end

-- opts: quiet (no sound or toast), keepSettings (positions only, e.g. after
-- the reload a layout asked for, or a new screen scale), pass (re-solves so
-- far), watched (a re-solve the size watch started).
function ApplyPreset(preset, opts)
	opts = opts or {}
	if InCombatLockdown() then return UI:Print('Layouts can be applied once you leave combat.') end
	local reload = not opts.keepSettings and ApplySettings(preset.settings)
	local s = Solve(preset)
	if not opts.quiet and UI.SnapshotMovers then UI:SnapshotMovers() end
	-- One write of every spot, then one placement pass: no frame flickers
	-- through intermediate spots. A frame's opacity and Hide choices stay.
	local movers = UI.db.movers
	local kept = {}
	for key, saved in pairs(movers) do
		if Unmanaged(key) then kept[key] = saved
		elseif type(saved) == 'table' and (saved.alpha or saved.hidden) then kept[key] = {alpha = saved.alpha, hidden = saved.hidden} end
	end
	wipe(movers)
	for key, saved in pairs(kept) do if Unmanaged(key) then movers[key] = saved end end
	-- Offsets in whole screen pixels: a frame with whole-pixel sizes lands on them.
	local px = UI.Pixel and UI.Pixel.Px and UI.Pixel.Px(UIParent, 1) or 0
	for key, rect in pairs(s.rects) do
		local point, x, y = SpotOf(rect, s.W, s.H)
		if px > 0 then x, y = floor(x / px + 0.5) * px, floor(y / px + 0.5) * px end
		local look = kept[key] or {}
		local scale = floor(s.scale[key] * 100 + 0.5) / 100
		movers[key] = {x, y, anchor = point, scale = abs(scale - 1) > 0.004 and scale or nil, alpha = look.alpha, hidden = look.hidden}
	end
	DB().preset = preset.key
	DB().resolvePending = reload and preset.key or nil
	UI:PlaceAllMovers()
	lastRects = s.rects
	if not opts.watched then WatchSizes() end
	Verify(preset, s.rects, opts.pass or 1)
	if #s.missed > 0 and DB().debugLayout then
		UI:Print(format('%d frame%s could not fit in the %s layout: %s.', #s.missed, #s.missed == 1 and '' or 's', preset.title,
			table.concat(s.missed, ', ')))
	end
	if not opts.quiet then
		Kit:Play('latch-down')
		if reload then ReloadToast() end
	end
	if Refresh then Refresh() end
end

function ConfirmPreset(preset)
	Kit:AlertDialog({title = 'Use the '..preset.title..' layout', confirm = 'Apply',
		text = 'Every frame moves to the '..preset.title..' arrangement. Undo (Ctrl+Z in edit mode) brings back your current positions.',
		onConfirm = function() ApplyPreset(preset) end})
end

-- After the reload a layout asked for, its frames exist at their new sizes:
-- solve it again with the real sizes. Old layout keys move to the new set once.
local resolver = CreateFrame('Frame')
resolver:RegisterEvent('PLAYER_ENTERING_WORLD')
resolver:SetScript('OnEvent', function(self)
	self:UnregisterAllEvents()
	local db = DB()
	if RENAMED[db.preset] then db.preset = RENAMED[db.preset] end
	-- The console settings this session's console was built with.
	builtWith = {}
	for _, key in ipairs(CONSOLE_SETTINGS) do builtWith[key] = UI.db.actionbars and UI.db.actionbars[key] end
	local key = db.resolvePending
	local preset = Lookup(key)
	if not preset then db.resolvePending = nil return end
	C_Timer.After(3, function()
		UI:AfterCombat(function() ApplyPreset(preset, {quiet = true, keepSettings = true}) end, 'layout.resolve')
	end)
end)

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

-- A layout's entries for its card: the solver's spots for the screen as it is
-- now, and the Edit Mode frames it worked around. Also whether anything had to
-- be made smaller or didn't fit.
local function PresetEntries(preset)
	local s = Solve(preset)
	local labels = {}
	for _, entry in ipairs(UI:GetMovers()) do labels[entry.key] = entry.label end
	local entries = {}
	for _, key in ipairs(s.order) do
		local rect = s.rects[key]
		local label = labels[key] or key:gsub('^%a+%.', ''):gsub('^%l', strupper)
		entries[#entries + 1] = {key = key, label = label, short = ShortLabel(label), cx = rect.x + rect.w / 2 - s.W / 2,
			cy = rect.y + rect.h / 2 - s.H / 2, w = rect.w, h = rect.h, kind = 'mover'}
	end
	for _, block in ipairs(s.blocks) do
		entries[#entries + 1] = {key = 'block:'..(block.label or #entries), label = block.reserved and 'Clear' or block.label,
			short = block.reserved and 'Clear' or '', cx = block.x + block.w / 2 - s.W / 2, cy = block.y + block.h / 2 - s.H / 2,
			w = block.w, h = block.h, kind = 'editmode'}
	end
	return entries, s.shrunk or #s.missed > 0
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
	local columns, gap = min(3, max(#PRESETS, 1)), 12
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
		-- Amber when the solver had to make something smaller to fit this screen.
		tile.warn = Kit:Led(tile, 5, false)
		tile.warn:SetPoint('TOPRIGHT', 0, -4)
		tile.warnText = Kit:Label(tile, 'Tight fit', 'dim', 7)
		tile.warnText:SetPoint('RIGHT', tile.warn, 'LEFT', -4, 0)
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
			local entries, tight = PresetEntries(tile.preset)
			tile.map:Draw(entries)
			-- A console arranged in its editor makes the layout the user's own.
			local edited = false
			for _ in pairs(UI.db.actionbars and type(UI.db.actionbars.consoleLayout) == 'table' and UI.db.actionbars.consoleLayout or {}) do
				edited = true
				break
			end
			Kit:SetLed(tile.lamp, DB().preset == tile.preset.key and not edited)
			Kit:SetLed(tile.warn, tight, 'amber')
			Kit:ShowLed(tile.warn, tight)
			tile.warnText:SetShown(tight)
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

	-- Edit mode places every frame on the screen itself; its strip's Layout map key comes back here.
	local edit = Kit:Button(body, {text = 'Edit mode', width = 120, height = 28, tone = 'primary'})
	edit:SetPoint('TOPLEFT')
	edit.onClick = function()
		if InCombatLockdown() then return UI:Print('Frames can be moved once you leave combat.') end
		local unlock = not UI:MoversUnlocked()
		if UI.EditMode then UI:EditMode(unlock) else UI:ToggleMovers(not unlock) end
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
	-- The handles' grid, in screen pixels (as the console editor's).
	local grids = UI.MOVER_GRIDS or {1, 2, 4, 8}
	local gridIndex = #grids
	for index, value in ipairs(grids) do if value == (UI.MoverGrid and UI:MoverGrid() or DB().grid) then gridIndex = index end end
	local gridControl = Kit:Segmented(body, {items = {'1 px', '2 px', '4 px', '8 px'}, width = 160, value = gridIndex, onChange = function(index)
		if UI.SetMoverGrid then UI:SetMoverGrid(grids[index]) else DB().grid = grids[index]; UI:RefreshMoverGrid() end
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
		edit:SetKeyText(UI:MoversUnlocked() and 'Done editing' or 'Edit mode')
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
	local preset = Lookup(key)
	if not preset then return false end
	ApplyPreset(preset)
	return true
end

-- A layout as the solver places it on this screen, for small previews:
-- a list of {key, x, y, w, h} as fractions of the screen from the bottom left.
function UI:LayoutPresetMap(key)
	local preset = Lookup(key)
	if not preset then return nil end
	local s = Solve(preset)
	local list = {}
	for _, frameKey in ipairs(s.order) do
		local rect = s.rects[frameKey]
		list[#list + 1] = {key = frameKey, x = rect.x / s.W, y = rect.y / s.H, w = rect.w / s.W, h = rect.h / s.H, scale = s.scale[frameKey]}
	end
	return list
end

-- Turn the layout overlap check on or off (it prints after each apply), and run it now.
function UI:LayoutDebug(on)
	if on == nil then on = not DB().debugLayout end
	DB().debugLayout = on and true or nil
	if on then
		local preset = Lookup(DB().preset)
		ReportOverlaps(preset and preset.title or 'current')
	end
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
