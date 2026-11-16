-- The objective tracker as a SPEC-01 device: "OT-1 Objectives", a dark
-- housing behind Blizzard's tracker with a lamp, model code and a count of
-- watched quests in its header. Section headers lose their bars and carry a
-- dim section code and a round key for collapsing; quest titles and lines are
-- set in the reference's typeface, each objective has a lamp in place of its
-- dash (lit once it is done), and progress and timer bars fill as LED dots.
--
-- Blizzard's tracker stays in charge: its quest item buttons are secure, it is
-- placed and sized with Edit Mode, and its layout runs in secure code that
-- other addons have tainted before. So this file:
--   * never calls the tracker's Update or layout methods, never writes fields
--     onto its frames and never hooks scripts on its layout frames;
--   * only post-hooks (hooksecurefunc) module methods, and does every bit of
--     work one frame later, outside Blizzard's own call;
--   * leaves the scenario and widget sections' contents alone (their frames
--     come from the pool the game shares with tooltips and map pins), styling
--     their headers only;
--   * changes the typeface through the tracker's font objects, so Blizzard
--     measures its lines in the new font and its layout stays right.
-- The housing is a frame of our own, anchored to the tracker and to the
-- lowest section showing, so it follows Edit Mode moves and the content's
-- height without reading any of Blizzard's geometry.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown = CreateFrame, UIParent, InCombatLockdown
local max = math.max

local module = UI:RegisterModule('objectives', {})
local function IsSecret(value) return issecretvalue and issecretvalue(value) end
local function Forbidden(object) return type(object) ~= 'table' or (object.IsForbidden and object:IsForbidden()) end
local function Hide(region) if not Forbidden(region) and region.SetAlpha then region:SetAlpha(0) end end

-- defaults:begin
-- textOffset / headerOffset: points added to the tracker's own sizes.
-- headerStyle: 'code' (section code and a rule), 'rule' or 'plain'.
-- completed: 'lit' (lit lamp, bright text), 'dim' (lit lamp, faded line) or 'green'.
-- hideCombat / hideBoss / hideInstance fade the tracker out (alpha only).
UI:RegisterDefaults('objectives', {textOffset = 0, headerOffset = 0, headerStyle = 'code', completed = 'lit', housing = true,
	hideCombat = false, hideBoss = false, hideInstance = false, untrackDone = false})
-- defaults:end
local function DB() return UI.db.objectives end

-- Section modules and the code printed on each header.
local SECTIONS = {
	{'ScenarioObjectiveTracker', 'SC-1', true}, {'UIWidgetObjectiveTracker', 'UW-1', true},
	{'CampaignQuestObjectiveTracker', 'CQ-1'}, {'QuestObjectiveTracker', 'QT-1'}, {'AdventureObjectiveTracker', 'AD-1'},
	{'AchievementObjectiveTracker', 'AC-1'}, {'MonthlyActivitiesObjectiveTracker', 'MA-1'},
	{'ProfessionsRecipeTracker', 'PR-1'}, {'BonusObjectiveTracker', 'BN-1'}, {'WorldQuestObjectiveTracker', 'WQ-1'},
	{'InitiativeTasksObjectiveTracker', 'IT-1'},
}
-- Sections whose blocks share the game's widget pool: header only.
local POOLED = {}
local CODES = {}

local FONT_OBJECTS = {'ObjectiveFont', 'ObjectiveTrackerLineFont', 'ObjectiveTrackerHeaderFont'}
for size = 12, 22 do FONT_OBJECTS[#FONT_OBJECTS + 1] = 'ObjectiveTrackerFont'..size end

-- Everything added to Blizzard's frames is kept here, keyed by their frame.
local headers = setmetatable({}, {__mode = 'k'})
local blocks = setmetatable({}, {__mode = 'k'})
local lamps = setmetatable({}, {__mode = 'k'})
local bars = setmetatable({}, {__mode = 'k'})
local items = setmetatable({}, {__mode = 'k'})
local hooked = setmetatable({}, {__mode = 'k'})
-- Objectives seen so far (quest:objective -> done), for the fade-in and the completion tick.
local seen = {}
local housing

local function Tracker() return _G.ObjectiveTrackerFrame end
local function MasterHeader()
	local tracker = Tracker()
	return tracker and (tracker.Header or tracker.HeaderMenu)
end

-- Typeface ---------------------------------------------------------------------
-- The tracker's own font objects keep their sizes and take Plex, before layout.
local baseSizes = {}
local function SetTypeface()
	local db = DB()
	for _, name in ipairs(FONT_OBJECTS) do
		local font = _G[name]
		if font and font.GetFont and font.SetFont then
			local _, size, flags = font:GetFont()
			if not IsSecret(size) and size then
				baseSizes[name] = baseSizes[name] or {size, flags or ''}
				local base = baseSizes[name]
				local header = name == 'ObjectiveTrackerHeaderFont'
				local offset = tonumber(header and db.headerOffset or db.textOffset) or 0
				font:SetFont(Kit:FontPath(header), max(base[1] + offset, 7), base[2])
			end
		end
	end
end

-- Dot meters on Blizzard's bars ------------------------------------------------
-- Kit:Perforate writes onto the bar and hooks its size; Blizzard's tracker bars
-- get the same dots from textures kept in a side table, sized on each pass.
local function SizeDots(bar, dots)
	local width, height = bar:GetSize()
	if IsSecret(width) or IsSecret(height) or not height or height <= 0 then
		dots.under:Hide(); dots.cover:Hide()
		return
	end
	for _, texture in ipairs({dots.under, dots.cover}) do
		texture:SetHorizTile(true); texture:SetVertTile(false)
		if texture.SetScale then texture:SetScale(height / 16) end
		texture:Show()
	end
end

local function SkinBar(bar)
	if Forbidden(bar) or not bar.GetStatusBarTexture then return end
	local dots = bars[bar]
	if not dots then
		local fill, icon = bar:GetStatusBarTexture(), bar.Icon
		for _, region in ipairs({bar:GetRegions()}) do
			if region ~= fill and region ~= icon and region.IsObjectType and region:IsObjectType('Texture') then region:SetAlpha(0) end
		end
		bar:SetStatusBarTexture([[Interface\Buttons\WHITE8X8]])
		if Kit.MarkBar then Kit:MarkBar(bar) end
		Kit:Tint(bar, 'lamp')
		dots = {}
		dots.well = bar:CreateTexture(nil, 'BACKGROUND', nil, 0)
		dots.well:SetColorTexture(1, 1, 1, 1)
		dots.well:SetAllPoints(bar)
		Kit:Tint(dots.well, 'glass')
		for key, file, layer, sublevel in string.gmatch('under tile-dot BACKGROUND 1 cover tile-perf OVERLAY -8', '(%S+) (%S+) (%S+) (%S+)') do
			local texture = bar:CreateTexture(nil, layer, nil, tonumber(sublevel))
			texture:SetTexture(Kit.media..file..'.tga', 'REPEAT', 'REPEAT')
			texture:SetAllPoints(bar)
			dots[key] = texture
		end
		Kit:Tint(dots.under, 'darkEdge')
		Kit:Tint(dots.cover, 'glass')
		local label = bar.Label
		if label and label.SetFont then
			Kit:Font(label, 9, 'OUTLINE', true)
			Kit:Tint(label, 'darkInk')
		end
		-- The bonus and scenario bars carry a reward icon beside them.
		if bar.Icon and bar.Icon.SetTexCoord then bar.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
		bars[bar] = dots
	end
	SizeDots(bar, dots)
end

local function SkinBars(section)
	for _, pool in ipairs({section.usedProgressBars, section.usedTimerBars}) do
		if type(pool) == 'table' then
			for _, holder in pairs(pool) do
				if type(holder) == 'table' then
					if holder.Bar or holder.GetStatusBarTexture then UI:Safe(SkinBar, holder.Bar or holder)
					else
						-- Some clients keep one table of bars per block.
						for _, inner in pairs(holder) do
							if type(inner) == 'table' then UI:Safe(SkinBar, inner.Bar or inner) end
						end
					end
				end
			end
		end
	end
end

-- Quest item buttons ------------------------------------------------------------
local function SkinItem(button)
	if Forbidden(button) or items[button] then return end
	-- The button may be secure: our key is only made out of combat.
	if InCombatLockdown() then return end
	local key = CreateFrame('Frame', nil, button)
	key:SetPoint('TOPLEFT', -3, 3)
	key:SetPoint('BOTTOMRIGHT', 3, -4)
	key:SetFrameLevel(max(button:GetFrameLevel() - 1, 0))
	key:EnableMouse(false)
	key.skin = Kit:Skin(key, 'key', 'BACKGROUND', 0)
	key.skin.kitMaxCorner = 7
	items[button] = key
	local normal = button.GetNormalTexture and button:GetNormalTexture()
	if normal then normal:SetAlpha(0) end
	local icon = button.icon or button.Icon
	if icon and icon.SetTexCoord then icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
	local count = button.Count
	if count and count.SetFont then Kit:Font(count, 9, 'OUTLINE', true) end
end

-- Blocks and lines -------------------------------------------------------------------
local function TitleOf(block)
	if block.HeaderText then return block.HeaderText end
	for _, region in ipairs({block:GetRegions()}) do
		if region.IsObjectType and region:IsObjectType('FontString') then return region end
	end
end

local function Complete(line)
	local text = line.Text
	local style = text and text.colorStyle
	local colors = _G.OBJECTIVE_TRACKER_COLOR
	if style and colors and (style == colors.Complete or style == colors.CompleteHighlight) then return true end
	local icon = line.Icon
	return icon and icon.IsShown and icon:IsShown() and true or false
end

local function PaintTitle(block, hover)
	local entry = blocks[block]
	local title = entry and entry.title
	if not title then return end
	local id = type(block.id) == 'number' and block.id
	local focused = id and C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID() == id
	local done = id and C_QuestLog and C_QuestLog.IsComplete and C_QuestLog.IsComplete(id)
	Kit:Tint(title, (hover or focused) and 'lamp' or done and 'green' or 'darkInk')
end

local function PaintLine(block, key, line)
	if Forbidden(line) then return end
	local done = Complete(line)
	local led = lamps[line]
	if not led then
		led = Kit:Led(line, 4, done)
		lamps[line] = led
	end
	-- The lamp takes the dash's place, or the check's once the objective is done.
	local dash, check = line.Dash, line.Icon
	if dash then dash:SetAlpha(0) end
	local spot = (done and check and check:IsShown() and check) or (dash and dash:IsShown() and dash) or nil
	if check then check:SetAlpha(done and 0 or 1) end
	led:ClearAllPoints()
	if spot then led:SetPoint('CENTER', spot, 'CENTER') else led:SetPoint('RIGHT', line.Text or line, 'LEFT', -4, 0) end
	Kit:ShowLed(led, spot ~= nil or done)
	Kit:SetLed(led, done, done and DB().completed == 'green' and 'green' or nil)
	if line.Text then
		local style = DB().completed
		if done and style == 'green' then Kit:Tint(line.Text, 'green')
		elseif done and style == 'dim' then Kit:Tint(line.Text, 'darkDim', 0.55)
		else Kit:Tint(line.Text, done and 'darkInk' or 'darkDim') end
	end

	-- New objectives fade in; a finished one ticks once.
	local id = (type(block.id) == 'number' or type(block.id) == 'string') and block.id
	if id then
		local stamp = tostring(id)..':'..tostring(key)
		local before = seen[stamp]
		if before == nil then
			seen[stamp] = done
			if module.settled then
				Kit:Animate(line, Kit:Speed('FAST'), 0, 1, function(alpha) line:SetAlpha(alpha) end, nil, 'sine')
			end
		elseif done and not before then
			seen[stamp] = true
			if UI.db.sound.interface then Kit:Play('tick', true) end
		elseif not done then
			seen[stamp] = false
		end
	end
end

local function HoverHooks(block)
	if hooked[block] then return end
	hooked[block] = true
	-- Blizzard repaints the block on hover; ours lands one frame later.
	local function Enter() C_Timer.After(0, function() UI:Safe(module.PaintBlock, block, true) end) end
	local function Leave() C_Timer.After(0, function() UI:Safe(module.PaintBlock, block, false) end) end
	for _, frame in ipairs({block, block.HeaderButton}) do
		if not Forbidden(frame) and frame.HookScript then
			frame:HookScript('OnEnter', Enter)
			frame:HookScript('OnLeave', Leave)
		end
	end
end

function module.PaintBlock(block, hover)
	if not blocks[block] then return end
	PaintTitle(block, hover)
	local lines = block.usedLines or block.lines
	if type(lines) == 'table' then
		for key, line in pairs(lines) do
			if type(line) == 'table' then UI:Safe(PaintLine, block, key, line) end
		end
	end
end

local function SkinBlock(block)
	if Forbidden(block) then return end
	local entry = blocks[block]
	if not entry then
		entry = {title = TitleOf(block)}
		blocks[block] = entry
		for _, part in ipairs({'Background', 'HeaderBackground', 'Stripe', 'Sheen', 'Glow', 'ShineTop', 'ShineBottom'}) do
			Hide(block[part])
		end
		HoverHooks(block)
	end
	module.PaintBlock(block, false)
	UI:Safe(SkinItem, block.ItemButton or block.itemButton)
end

local function SkinBlocks(section)
	if POOLED[section] or type(section.usedBlocks) ~= 'table' then return end
	for _, byTemplate in pairs(section.usedBlocks) do
		if type(byTemplate) == 'table' then
			for _, block in pairs(byTemplate) do
				if type(block) == 'table' then UI:Safe(SkinBlock, block) end
			end
		end
	end
	SkinBars(section)
end

-- Headers ---------------------------------------------------------------------------
local function PaintChevron(header, collapsed)
	local entry = headers[header]
	if not entry or not entry.icon then return end
	Kit:SetIcon(entry.icon, collapsed and 'chevron-down' or 'chevron-up')
end

local function IsCollapsed(header)
	local tracker = Tracker()
	if header == MasterHeader() then return tracker and tracker.isCollapsed end
	local section = header:GetParent()
	return header.isCollapsed or (section and section.isCollapsed)
end

local function SkinHeader(header, code)
	if Forbidden(header) or headers[header] then return end
	local master = header == MasterHeader()
	local entry = {}
	headers[header] = entry
	for _, part in ipairs({'Background', 'Line', 'LineSheen', 'LineGlow', 'Divider', 'Sheen', 'Glow', 'Stripe'}) do
		Hide(header[part])
	end
	local text = header.Text
	if text then
		Kit:Font(text, 10, '', true)
		Kit:Tint(text, 'darkInk')
		-- The housing's own header names the device; the "All objectives" line gives way to it.
		if master and DB().housing ~= false then text:SetAlpha(0) end
	end
	local button = header.MinimizeButton
	if not Forbidden(button) then
		for _, getter in ipairs({'GetNormalTexture', 'GetPushedTexture', 'GetHighlightTexture', 'GetDisabledTexture'}) do
			local texture = button[getter] and button[getter](button)
			if texture then texture:SetAlpha(0) end
		end
		local key = CreateFrame('Frame', nil, button)
		key:SetSize(16, 16)
		key:SetPoint('CENTER')
		key:EnableMouse(false)
		key.skin = Kit:Skin(key, 'key-round', 'ARTWORK', 0)
		entry.icon = Kit:Icon(key, 'chevron-up', 8, 'ink')
		entry.icon:SetPoint('CENTER')
		entry.key = key
	end
	if code and not master then
		entry.code = Kit:Label(header, code, 'darkDim', 8)
		if entry.key then entry.code:SetPoint('RIGHT', entry.key, 'LEFT', -6, 0) else entry.code:SetPoint('RIGHT', -6, 0) end
		-- A hairline under each section, as the reference rules its groups.
		entry.rule = header:CreateTexture(nil, 'ARTWORK')
		entry.rule:SetColorTexture(1, 1, 1, 1)
		Kit:Tint(entry.rule, 'darkEdge')
		entry.rule:SetHeight(UI.Pixel and UI.Pixel.Px(header, 1) or 1)
		entry.rule:SetPoint('BOTTOMLEFT', 0, 0)
		entry.rule:SetPoint('BOTTOMRIGHT', 0, 0)
	end
	PaintChevron(header, IsCollapsed(header))
	module.PaintHeader(header)
	if header.SetCollapsed then
		hooksecurefunc(header, 'SetCollapsed', function(self, collapsed)
			C_Timer.After(0, function()
				UI:Safe(PaintChevron, self, collapsed)
				if UI.db.sound.interface then Kit:Play(collapsed and 'latch-up' or 'latch-down', true) end
				module:Queue()
			end)
		end)
	end
end

function module.PaintHeader(header)
	local entry = headers[header]
	if not entry then return end
	local style = DB().headerStyle or 'code'
	if entry.code then entry.code:SetShown(style == 'code') end
	if entry.rule then entry.rule:SetShown(style ~= 'plain') end
	-- With the housing on, its header names the device; the "All objectives" line gives way.
	if header == MasterHeader() and header.Text then header.Text:SetAlpha(DB().housing ~= false and 0 or 1) end
end

-- Housing -----------------------------------------------------------------------------
local function WatchCount()
	local count = C_QuestLog and C_QuestLog.GetNumQuestWatches and C_QuestLog.GetNumQuestWatches()
		or (GetNumQuestWatches and GetNumQuestWatches()) or 0
	if IsSecret(count) then return '' end
	return format('%02d', count)
end

-- The lowest section showing, found by order only: sections are laid out top
-- to bottom in the tracker's module order. The widget section is skipped.
local function LowestSection(tracker)
	local list, lowest = tracker.modules or tracker.MODULES, nil
	if type(list) ~= 'table' then return end
	for _, section in ipairs(list) do
		if section ~= _G.UIWidgetObjectiveTracker and not Forbidden(section) and section.IsShown and section:IsShown() then
			lowest = section
		end
	end
	return lowest
end

local function BuildHousing()
	if housing then return housing end
	local tracker = Tracker()
	housing = Kit:Device(UIParent, {model = 'OT-1', title = 'Objectives', surface = 'dark', corner = 10})
	housing:SetFrameStrata(tracker:GetFrameStrata() or 'MEDIUM')
	housing:SetFrameLevel(max(tracker:GetFrameLevel() - 1, 1))
	Kit:Relevel(housing)
	housing:EnableMouse(false)
	housing.count = Kit:Label(housing, '', 'darkDim', 8)
	housing:Hide()
	return housing
end

local function LayoutHousing()
	local tracker, header = Tracker(), MasterHeader()
	if not housing or not tracker then return end
	local shown = DB().housing ~= false and not module.faded and tracker:IsShown() and not IsSecret(tracker:GetAlpha())
		and tracker:GetAlpha() > 0 and (not header or header:IsShown())
	if not shown then
		housing:Hide()
		return
	end
	local lowest = not tracker.isCollapsed and LowestSection(tracker)
	housing:ClearAllPoints()
	housing:SetPoint('TOPLEFT', tracker, 'TOPLEFT', -12, 6)
	housing:SetPoint('TOPRIGHT', tracker, 'TOPRIGHT', 10, 6)
	if lowest then
		housing:SetPoint('BOTTOM', lowest, 'BOTTOM', 0, -8)
	elseif header then
		housing:SetPoint('BOTTOM', header, 'BOTTOM', 0, -6)
	else
		housing:SetHeight(32)
	end
	housing.count:SetText(WatchCount())
	local entry = header and headers[header]
	housing.count:ClearAllPoints()
	if entry and entry.key then housing.count:SetPoint('RIGHT', entry.key, 'LEFT', -6, 0)
	else housing.count:SetPoint('TOPRIGHT', -12, -11) end
	-- The lamp is lit while the tracker is open and has something in it.
	Kit:SetLed(housing.lamp, lowest ~= nil)
	if not housing:IsShown() then
		housing:SetAlpha(0)
		housing:Show()
		Kit:FadeTo(housing, 1, 'NORMAL')
	end
end

-- Fading out ------------------------------------------------------------------------------
-- In a fight, a boss encounter or an instance the tracker can fade away. Alpha
-- only: collapsing it from our code would taint its secure item buttons. The
-- items stay where they are and keep working.
local inCombat, inEncounter, inInstance = false, false, false
local function ApplyFade()
	local tracker = Tracker()
	if Forbidden(tracker) then return end
	local db = DB()
	local fade = (db.hideCombat and inCombat) or (db.hideBoss and inEncounter) or (db.hideInstance and inInstance) or false
	if fade == (module.faded or false) then return end
	module.faded = fade
	Kit:FadeTo(tracker, fade and 0 or 1, 'NORMAL')
	if housing then
		if fade then Kit:FadeTo(housing, 0, 'NORMAL', function() if module.faded then housing:Hide() end end)
		else C_Timer.After(0, function() UI:Safe(module.Layout) end) end
	end
end

local function CheckInstance()
	local ok, inside, kind = pcall(IsInInstance)
	inInstance = ok and not IsSecret(inside) and inside and kind ~= 'none' and true or false
end

-- Finished quests can leave the tracker by themselves (they stay in the log).
local function UntrackDone()
	if not DB().untrackDone or InCombatLockdown() or not C_QuestLog then return end
	local log = C_QuestLog
	if not (log.GetNumQuestWatches and log.GetQuestIDForQuestWatchIndex and log.IsComplete and log.RemoveQuestWatch) then return end
	for index = log.GetNumQuestWatches(), 1, -1 do
		local questID = log.GetQuestIDForQuestWatchIndex(index)
		if not IsSecret(questID) and questID and log.IsComplete(questID) == true then log.RemoveQuestWatch(questID) end
	end
end

-- Passes ---------------------------------------------------------------------------------
local function Sections()
	local list, found = {}, {}
	local tracker = Tracker()
	local modules = tracker and (tracker.modules or tracker.MODULES)
	if type(modules) == 'table' then
		for _, section in ipairs(modules) do
			if type(section) == 'table' and not found[section] then found[section] = true; list[#list + 1] = section end
		end
	end
	for _, info in ipairs(SECTIONS) do
		local section = _G[info[1]]
		if type(section) == 'table' and not found[section] then found[section] = true; list[#list + 1] = section end
	end
	return list
end

local function Pass()
	local tracker = Tracker()
	if Forbidden(tracker) then return end
	BuildHousing()
	Hide(tracker.NineSlice)
	local header = MasterHeader()
	if header then UI:Safe(SkinHeader, header) end
	for _, section in ipairs(Sections()) do
		if not Forbidden(section) then
			if section.Header then UI:Safe(SkinHeader, section.Header, CODES[section] or '') end
			SkinBlocks(section)
		end
	end
	LayoutHousing()
end
module.Layout = LayoutHousing

local pending
function module:Queue()
	if pending then return end
	pending = true
	C_Timer.After(0, function()
		pending = nil
		UI:Safe(Pass)
	end)
end

local function Queue() module:Queue() end

local function HookSection(section)
	if Forbidden(section) or hooked[section] then return end
	hooked[section] = true
	for _, method in ipairs({'Update', 'AddBlock', 'GetProgressBar', 'GetTimerBar'}) do
		if type(section[method]) == 'function' then hooksecurefunc(section, method, Queue) end
	end
end

local function Start()
	local tracker = Tracker()
	if Forbidden(tracker) or module.started then return end
	module.started = true
	for _, info in ipairs(SECTIONS) do
		local section = _G[info[1]]
		if type(section) == 'table' then
			CODES[section] = info[2]
			if info[3] then POOLED[section] = true end
		end
	end
	SetTypeface()
	Kit:OnRefresh(SetTypeface)
	for _, section in ipairs(Sections()) do HookSection(section) end
	-- Sections join the tracker after login (and addons add their own).
	if type(tracker.AddModule) == 'function' then
		hooksecurefunc(tracker, 'AddModule', function(_, section)
			C_Timer.After(0, function()
				if type(section) == 'table' and not CODES[section] then CODES[section] = 'OT-'..(#Sections()) end
				HookSection(section)
				Queue()
			end)
		end)
	end
	if type(tracker.Update) == 'function' then hooksecurefunc(tracker, 'Update', Queue) end
	Pass()
	-- Objectives on screen at login are not new.
	C_Timer.After(2, function() module.settled = true end)
	-- Edit Mode, instances and cinematics show and hide the tracker without an
	-- event of its own; a light check keeps the housing in step.
	C_Timer.NewTicker(0.5, function() UI:Safe(LayoutHousing) end)
end

function module:Enable()
	local driver = CreateFrame('Frame')
	for _, event in ipairs({'QUEST_LOG_UPDATE', 'QUEST_WATCH_LIST_CHANGED', 'SCENARIO_UPDATE', 'SCENARIO_CRITERIA_UPDATE',
		'TRACKED_ACHIEVEMENT_LIST_CHANGED', 'TRACKED_RECIPE_UPDATE', 'SUPER_TRACKING_CHANGED', 'PLAYER_ENTERING_WORLD',
		'PLAYER_REGEN_ENABLED', 'PLAYER_REGEN_DISABLED', 'ENCOUNTER_START', 'ENCOUNTER_END', 'ZONE_CHANGED_NEW_AREA', 'ADDON_LOADED'}) do
		pcall(driver.RegisterEvent, driver, event)
	end
	driver:SetScript('OnEvent', function(_, event, name)
		if event == 'ADDON_LOADED' then
			if name == 'Blizzard_ObjectiveTracker' then UI:Safe(Start) end
			return
		end
		-- The fight starts before lockdown does, so trust the event.
		if event == 'PLAYER_REGEN_DISABLED' then inCombat = true
		elseif event == 'PLAYER_REGEN_ENABLED' then inCombat = false; UI:Safe(UntrackDone)
		elseif event == 'ENCOUNTER_START' then inEncounter = true
		elseif event == 'ENCOUNTER_END' then inEncounter = false
		elseif event == 'PLAYER_ENTERING_WORLD' or event == 'ZONE_CHANGED_NEW_AREA' then CheckInstance(); inEncounter = false
		elseif event == 'QUEST_LOG_UPDATE' then UI:Safe(UntrackDone) end
		if module.started then
			UI:Safe(ApplyFade)
			if event ~= 'PLAYER_REGEN_DISABLED' and event ~= 'ENCOUNTER_START' and event ~= 'ENCOUNTER_END' then Queue() end
		end
	end)
	CheckInstance()
	inCombat = InCombatLockdown() and true or false
	if Tracker() then Start() end
	if module.started then UI:Safe(ApplyFade) end
end

function module:Refresh()
	if not module.started then return end
	SetTypeface()
	for header in pairs(headers) do UI:Safe(module.PaintHeader, header) end
	UI:Safe(ApplyFade)
	UI:Safe(UntrackDone)
	Queue()
end

UI:RegisterPage('objectives', {title = 'Objectives', order = 15, cards = {
	{title = 'Style', rows = {
		{'segmented', 'Style', 'style.objectives', items = {{'device', 'Device'}, {'blizzard', 'Blizzard'}}, reload = true,
			note = 'The tracker in a dark OT-1 housing: lamps for objectives, dot meters for progress.'},
		{'switch', 'Housing', 'objectives.housing', 'The dark OT-1 device behind the tracker.'},
		{'switch', 'Objective sounds', 'sound.interface', 'A tick when an objective is done, a latch when a section folds.'},
		{'note', 'Place and size the tracker with Edit Mode; the housing follows it.'},
	}},
	{title = 'Text', rows = {
		{'slider', 'Text size', 'objectives.textOffset', -3, 4, 1, 'Quest titles and objective lines, in points from the game\'s size.',
			format = function(v) return v > 0 and ('+'..v) or tostring(v) end},
		{'slider', 'Header size', 'objectives.headerOffset', -3, 4, 1, nil, format = function(v) return v > 0 and ('+'..v) or tostring(v) end},
		{'segmented', 'Section headers', 'objectives.headerStyle', items = {{'code', 'Code'}, {'rule', 'Rule'}, {'plain', 'Plain'}},
			note = 'A dim section code and a rule, the rule alone, or just the name.'},
		{'segmented', 'Done objectives', 'objectives.completed', items = {{'lit', 'Lit'}, {'dim', 'Dim'}, {'green', 'Green'}},
			note = 'A finished objective keeps a lit lamp and bright text, fades back, or turns green.'},
		{'switch', 'Untrack finished quests', 'objectives.untrackDone', 'A quest leaves the tracker once every objective is done; it stays in your quest log.'},
	}},
	{title = 'Fade out', rows = {
		{'switch', 'In combat', 'objectives.hideCombat', 'The tracker fades away while you fight.'},
		{'switch', 'In boss fights', 'objectives.hideBoss', 'From the pull to the end of the encounter.'},
		{'switch', 'In instances', 'objectives.hideInstance', 'Dungeons, raids, battlegrounds and arenas.'},
		{'note', 'Fading never folds the tracker from here (that taints its quest item buttons); the items keep working while it is hidden.'},
	}},
}})
