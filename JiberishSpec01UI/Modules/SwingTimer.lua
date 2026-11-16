-- The game's swing timers (Forever's Blizzard_SwingTimer: main hand, off hand
-- and ranged) as SPEC-01 meters: a dark glass housing, the fill on a black
-- screen with quarter ticks, a lit spark riding the fill's edge, a printed slot
-- label and an LCD time.
--
-- The frames are Edit Mode systems, so they are skinned where they are: never
-- reparented or moved, and nothing is written onto them (our parts live in a
-- side table). The game times the fill itself; the spark is anchored to the
-- fill texture's edge, so it moves with no Lua per frame. Colors are repainted
-- after the game's own updates (a new swing, the range check).
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, hooksecurefunc = CreateFrame, hooksecurefunc

local module = UI:RegisterModule('swingtimer', {always = true})

-- defaults:begin
UI:RegisterDefaults('swingtimer', {enable = true, colors = 'slots', range = true, spark = true, ticks = true})
-- defaults:end

local function DB() return UI.db.swingtimer end
local function IsSecret(value) return issecretvalue and issecretvalue(value) end
local function Is(object, kind) return type(object) == 'table' and object.IsObjectType and object:IsObjectType(kind) end

local FRAMES = {
	{name = 'SwingTimerMainHandFrame', slot = 'MainHand', token = 'lamp'},
	{name = 'SwingTimerOffHandFrame', slot = 'OffHand', token = 'blue'},
	{name = 'SwingTimerRangedFrame', slot = 'Ranged', token = 'amber'},
}
local FLAT = [[Interface\Buttons\WHITE8X8]]

local parts = setmetatable({}, {__mode = 'k'}) -- Blizzard frame -> our pieces

local function SwingType(slot)
	local enum = Enum and Enum.PlayerSwingType
	return enum and enum[slot]
end

local function InRange(slot)
	local api = C_SwingTimer and C_SwingTimer.IsTargetWithinSwingRange
	local kind = SwingType(slot)
	if not (api and kind) then return nil end
	local ok, answer = pcall(api, kind)
	if not ok or IsSecret(answer) then return nil end
	return answer
end

local function Token(entry)
	local mode = DB().colors
	if mode == 'key' then return 'lamp' end
	if mode == 'class' then return 'class' end
	return entry.token
end

local function ClassRGB()
	local _, class = UnitClass('player')
	local color = not IsSecret(class) and class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if color then return color.r, color.g, color.b end
	return Kit:RGB('lamp')
end

local function Paint(frame)
	local own = parts[frame]
	if not own then return end
	local bar, db = own.bar, DB()
	local fill = bar:GetStatusBarTexture()
	if fill and fill:GetTexture() ~= FLAT then bar:SetStatusBarTexture(FLAT) end
	local r, g, b
	local out = db.range and InRange(own.entry.slot) == false
	if out then
		r, g, b = Kit:RGB('red')
	elseif Token(own.entry) == 'class' then
		r, g, b = ClassRGB()
	else
		r, g, b = Kit:RGB(Token(own.entry))
	end
	bar:SetStatusBarColor(r, g, b, 1)
	own.spark:SetVertexColor(r, g, b)
	own.glow:SetVertexColor(r, g, b)
	own.spark:SetShown(db.spark and true or false)
	own.glow:SetShown(db.spark and true or false)
	for _, tick in ipairs(own.ticks) do tick:SetShown(db.ticks and true or false) end
	own.lamp:SetVertexColor(r, g, b)
	own.lamp:SetAlpha(out and 0.35 or 1)
end

-- Hide the game's art: every texture on the frame and the bar but the fill.
local function Strip(frame, bar)
	local fill = bar:GetStatusBarTexture()
	for _, holder in ipairs({frame, bar}) do
		for _, region in ipairs({holder:GetRegions()}) do
			if Is(region, 'Texture') and region ~= fill then region:SetAlpha(0) end
		end
	end
end

local function Skin(entry)
	local frame = _G[entry.name]
	if type(frame) ~= 'table' or parts[frame] then return end
	if frame.IsForbidden and frame:IsForbidden() then return end
	local bar = frame.StatusBar
	if not Is(bar, 'StatusBar') then return end
	Strip(frame, bar)
	local own = {entry = entry, bar = bar}
	parts[frame] = own
	-- Housing around the whole frame, a black screen behind the bar.
	own.housing = CreateFrame('Frame', nil, frame)
	own.housing:SetPoint('TOPLEFT', bar, 'TOPLEFT', -4, 4)
	own.housing:SetPoint('BOTTOMRIGHT', bar, 'BOTTOMRIGHT', 4, -4)
	own.housing:SetFrameLevel(math.max(bar:GetFrameLevel() - 2, 0))
	Kit:Shell(own.housing, {surface = 'glass', radius = 5, alpha = 0.9})
	own.screen = CreateFrame('Frame', nil, frame)
	own.screen:SetPoint('TOPLEFT', bar, 'TOPLEFT', -1, 1)
	own.screen:SetPoint('BOTTOMRIGHT', bar, 'BOTTOMRIGHT', 1, -1)
	own.screen:SetFrameLevel(math.max(bar:GetFrameLevel() - 1, 0))
	Kit:Shell(own.screen, {surface = 'screen', radius = 2, shadow = false})
	-- Quarter ticks over the fill, like the scale under SPEC-01's slider.
	own.ticks = {}
	for index = 1, 3 do
		local tick = bar:CreateTexture(nil, 'OVERLAY', nil, 1)
		tick:SetColorTexture(0, 0, 0, 0.55)
		tick:SetWidth(UI.Pixel.Px(bar, 1))
		tick:SetPoint('TOP', bar, 'TOPLEFT', 0, 0)
		tick:SetPoint('BOTTOM', bar, 'BOTTOMLEFT', 0, 0)
		own.ticks[index] = tick
	end
	local function PlaceTicks()
		local width = bar:GetWidth()
		if IsSecret(width) or not width then return end
		for index, tick in ipairs(own.ticks) do
			tick:ClearAllPoints()
			tick:SetWidth(UI.Pixel.Px(bar, 1))
			tick:SetPoint('TOP', bar, 'TOPLEFT', UI.Pixel.Snap(bar, width * index / 4), 0)
			tick:SetPoint('BOTTOM', bar, 'BOTTOMLEFT', UI.Pixel.Snap(bar, width * index / 4), 0)
		end
	end
	bar:HookScript('OnSizeChanged', function() UI:Safe(PlaceTicks) end)
	PlaceTicks()
	-- The spark: a white hairline with a soft glow, on the fill's moving edge.
	local fill = bar:GetStatusBarTexture()
	bar:SetStatusBarTexture(FLAT)
	fill = bar:GetStatusBarTexture() or fill
	own.spark = bar:CreateTexture(nil, 'OVERLAY', nil, 3)
	own.spark:SetColorTexture(1, 1, 1, 1)
	own.spark:SetWidth(UI.Pixel.Px(bar, 2))
	own.spark:SetPoint('TOP', fill, 'TOPRIGHT', 0, 0)
	own.spark:SetPoint('BOTTOM', fill, 'BOTTOMRIGHT', 0, 0)
	own.spark:SetBlendMode('ADD')
	own.glow = Kit:Texture(bar, 'glow', 'OVERLAY', 2)
	own.glow:SetPoint('TOPLEFT', fill, 'TOPRIGHT', -6, 5)
	own.glow:SetPoint('BOTTOMRIGHT', fill, 'BOTTOMRIGHT', 6, -5)
	own.glow:SetBlendMode('ADD')
	own.glow:SetAlpha(0.6)
	-- A slot lamp on the housing's left edge.
	own.lamp = Kit:Texture(own.housing, 'circle', 'OVERLAY', 2)
	own.lamp:SetSize(4, 4)
	own.lamp:SetPoint('RIGHT', own.housing, 'LEFT', -3, 0)
	-- The game's labels in the reference's typeface: slot printed, time on the LCD ink.
	if Is(bar.TypeLabel, 'FontString') then
		Kit:Font(bar.TypeLabel, 9, 'OUTLINE', true)
		Kit:Tint(bar.TypeLabel, 'darkInk')
		bar.TypeLabel:SetShadowOffset(0, 0)
	end
	if Is(bar.TimeLabel, 'FontString') then
		Kit:Font(bar.TimeLabel, 10, 'OUTLINE', true, 'numbers')
		Kit:Tint(bar.TimeLabel, 'screenAccent')
		bar.TimeLabel:SetShadowOffset(0, 0)
	end
	-- Repaint after the game's own updates.
	for _, method in ipairs({'ApplyRangePresentation', 'ResetSwingTimer', 'ClearSwingTimer', 'UpdateShownState',
		'OnEditModeExit', 'UpdateSystemSettingOpacity'}) do
		if type(frame[method]) == 'function' then
			hooksecurefunc(frame, method, function(self) UI:Safe(Paint, self) end)
		end
	end
	Paint(frame)
end

local function SkinAll()
	for _, entry in ipairs(FRAMES) do UI:Safe(Skin, entry) end
end

local function Loaded()
	if C_AddOns and C_AddOns.IsAddOnLoaded then return C_AddOns.IsAddOnLoaded('Blizzard_SwingTimer') end
	return IsAddOnLoaded and IsAddOnLoaded('Blizzard_SwingTimer')
end

function module:Enable()
	if not DB().enable then return end
	local events = CreateFrame('Frame')
	events:RegisterEvent('ADDON_LOADED')
	pcall(events.RegisterEvent, events, 'PLAYER_SWING_RANGE_UPDATE')
	events:RegisterEvent('PLAYER_TARGET_CHANGED')
	events:SetScript('OnEvent', function(_, event, name)
		if event == 'ADDON_LOADED' then
			if name == 'Blizzard_SwingTimer' then SkinAll() end
		else
			for frame in pairs(parts) do UI:Safe(Paint, frame) end
		end
	end)
	if Loaded() then SkinAll() end
	self.ready = true
end

function module:Refresh()
	for frame in pairs(parts) do UI:Safe(Paint, frame) end
end

Kit:OnRefresh(function() module:Refresh() end)

-- Hub ------------------------------------------------------------------------------
local function Off() return not DB().enable end
UI:RegisterPage('swingtimer', {title = 'Swing timer', order = 12.6, cards = {
	{title = 'Swing timer', rows = {
		{'switch', 'SPEC-01 swing timer', 'swingtimer.enable', 'The game\'s main hand, off hand and ranged swing timers as SPEC-01 meters. Place them in Edit Mode.', reload = true, since = '0.5.1'},
		{'dropdown', 'Colors', 'swingtimer.colors', items = {{'slots', 'Per hand'}, {'key', 'Key color'}, {'class', 'Class'}},
			disabled = Off, since = '0.5.1'},
		{'switch', 'Out of range in red', 'swingtimer.range', 'The meter turns red while your target is out of that weapon\'s reach.', disabled = Off, since = '0.5.1'},
		{'switch', 'Spark', 'swingtimer.spark', 'A lit edge riding the fill.', disabled = Off, since = '0.5.1'},
		{'switch', 'Quarter ticks', 'swingtimer.ticks', 'Marks at a quarter, half and three quarters of the swing.', disabled = Off, since = '0.5.1'},
		{'note', 'The swing timers are part of the game on Forever realms; turn them on in Edit Mode. Retail has none.'},
	}},
}})
