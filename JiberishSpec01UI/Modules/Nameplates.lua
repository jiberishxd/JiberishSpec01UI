-- Nameplates as small SPEC-01 devices. Each game nameplate carries one of our
-- own plates: a dark glass housing with a target lamp, the level on a tiny LCD
-- chip, the name, a health readout, a threat lamp and an LED (or pill, or bar)
-- health meter, with a cast bar docked underneath and your debuffs above.
-- Friendly plates can be just a name. Nothing of Blizzard's plate shows.
--
-- How the game's frame is put away: on every plate the game hands its frame
-- out (it does so again and again from a shared pool), the frame is held
-- invisible with its events stopped and its children parked on a hidden frame,
-- and the plate's click area is given to a frame of ours covering the plate.
-- Its widgets (quest progress, the soft target icon) move onto the plate itself
-- so they still show. Plates the game keeps to itself (forbidden ones, friendly
-- players in some instances) are left alone.
--
-- Unit values may be secret in combat: they go straight to the client's
-- setters (bars, text, alpha), and nothing here compares or adds them up
-- unless the client says the value is plain.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, InCombatLockdown = CreateFrame, InCombatLockdown
local max, min, floor = math.max, math.min, math.floor

local module = UI:RegisterModule('nameplates', {})
local function DB() return UI.db.nameplates end
local function IsSecret(value) return issecretvalue and issecretvalue(value) end

-- An aura update with nothing in it. Its fields can be secret in restricted
-- content; then it counts as a full update, never tested.
local function AuraUpdateEmpty(info)
	if type(info) ~= 'table' then return false end
	for _, field in ipairs({'isFullUpdate', 'addedAuras', 'updatedAuraInstanceIDs', 'removedAuraInstanceIDs'}) do
		local value = info[field]
		if IsSecret(value) or value then return false end
	end
	return true
end
local function Style()
	local style = UI:Style('nameplates')
	return (style == 'pill' or style == 'bar') and style or 'dots'
end

-- The first value of a call, or nil if the call fails or the value is secret.
local function Plain(func, ...)
	if type(func) ~= 'function' then return nil end
	local ok, value = pcall(func, ...)
	if not ok or IsSecret(value) then return nil end
	return value
end

local function Forbidden(frame)
	if type(frame) ~= 'table' then return true end
	if not frame.IsForbidden then return false end
	local ok, forbidden = pcall(frame.IsForbidden, frame)
	return not ok or forbidden == true
end

-- A color setting: {r, g, b} or {r =, g =, b =}.
local function RGB(color)
	if type(color) ~= 'table' then return nil end
	return color[1] or color.r, color[2] or color.g, color[3] or color.b
end

local INTERPOLATION = Enum and Enum.StatusBarInterpolation
local IMMEDIATE = INTERPOLATION and INTERPOLATION.Immediate
local TIMER = Enum and Enum.StatusBarTimerDirection
local STRETCHED = Enum and Enum.UITextureSliceMode and Enum.UITextureSliceMode.Stretched
-- The fill's glide, following the appearance page's "Smooth bars".
local function Smooth()
	if Kit.Smooth then return Kit:Smooth() end
	return INTERPOLATION and INTERPOLATION.ExponentialEaseOut
end
local AURA_MAX = 8

-- Settings ------------------------------------------------------------------------
-- defaults:begin
UI:RegisterDefaults('nameplates', {
	-- Friendly and enemy plates.
	friendlyNameOnly = true, friendlyClassColor = true, enemyPlayerClassColor = true,
	npcColor = 'reaction', -- 'reaction' | 'accent'
	-- Name and health readout.
	nameSize = 8, namePosition = 'header', -- 'header' | 'center' | 'above'
	nameLength = 0, -- characters; 0 keeps the whole name
	healthText = 'percent', -- 'percent' | 'current' | 'both' | 'deficit' | 'none'
	healthTextPosition = 'header', -- 'header' | 'bar'
	-- Auras.
	auraSize = 18, auraCount = 5, auraPosition = 'above', -- 'above' | 'below'
	auraFilter = 'mine', -- 'mine' | 'all' | 'important' | 'boss'
	auraTime = false,
	-- Cast bar.
	castHeight = 18, castIcon = true, castName = true, castTarget = true,
	castColor = {0.91, 0.63, 0.07}, castLockedColor = {0.55, 0.55, 0.52},
	-- Threat.
	threatColorBar = false, tankMode = 'auto', -- 'auto' | 'on' | 'off'
	threatSecure = {0.18, 0.62, 0.37}, threatInsecure = {0.91, 0.63, 0.07}, threatAggro = {1, 0.23, 0.19},
	-- Target.
	targetStyle = 'lamp', -- 'lamp' | 'glow' | 'sides' | 'brackets'
	nonTargetAlpha = 1,
	-- Execute range and quest units.
	execute = false, executePercent = 0.2, questMarker = true,
	-- Quest units: the marker's look and place, and colors for the plate.
	questStyle = 'glyph', -- 'glyph' | 'led' | 'chip' | 'progress' | 'exclamation' | 'none'
	questPosition = 'right', -- 'right' | 'left' | 'above' | 'header'
	questSize = 12, questColor = 'amber', -- 'amber' | 'key' | 'custom'
	questCustomColor = {1, 0.66, 0}, questBlink = true, questBreathe = false, questLamp = true,
	questHealth = false, questHealthColor = {1, 0.66, 0}, questName = false, questNameColor = {1, 0.78, 0.36},
	-- The game's own plate settings, set out of combat and put back when turned off.
	stacking = 'game', -- 'game' | 'stack' | 'overlap'
	maxDistance = 0, -- yards; 0 leaves the game's
	savedCVars = {},
	-- Scale.
	eliteScale = 1, minionScale = 0.85,
	keepDistance = false, -- true keeps the game's distance (and target) scaling on top of ours
	-- Plate states: non-target plates as slim Compact strips, the target as the Full device.
	otherPlates = 'compact', -- 'compact' | 'full'
	compactWidth = 0.7, compactLevel = true, compactMeter = 'hairline', -- 'hairline' | 'dots'
	compactHousing = 'none', -- 'none' | 'glass'
	expandMouseover = false, expandFocus = true,
	housing = 'glass', -- 'glass' | 'none' (Full)
	targetHeight = 5, levelInline = true,
	-- Printed legends: LV before the level, HP before the health readout.
	legends = true,
})
-- defaults:end

local home = CreateFrame('Frame') -- spare plates wait here
local hidden = CreateFrame('Frame') -- the game's plate parts are parked here
hidden:Hide()

local spare = {}
local byUnit = {} -- unit token -> our plate
-- For add-ons on our plates (NavBar.lua): read-only unit -> plate, and
-- callbacks run as a plate is attached to or leaves a unit.
module.byUnit = byUnit
module.listeners = {}
local function Tell(what, plate, unit)
	for _, listener in ipairs(module.listeners) do UI:Safe(listener, what, plate, unit) end
end
local onPlate = setmetatable({}, {__mode = 'k'}) -- game nameplate -> our plate
local clicks = setmetatable({}, {__mode = 'k'}) -- game nameplate -> our click frame
local preview -- the sample plate on the settings page

-- Colors ------------------------------------------------------------------------
local function Soften(r, g, b)
	-- A little toward gray, so plates sit calmly over the world.
	local gray = 0.299 * r + 0.587 * g + 0.114 * b
	return (r + (gray - r) * 0.15) * 0.95, (g + (gray - g) * 0.15) * 0.95, (b + (gray - b) * 0.15) * 0.95
end

local function Checked(ok, r, g, b)
	if ok and not IsSecret(r) and r and not IsSecret(g) and not IsSecret(b) then return Soften(r, g, b) end
end

local function ClassColor(unit)
	local r, g, b = Checked(pcall(function()
		local _, class = UnitClass(unit)
		local color = not IsSecret(class) and class and (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)[class]
		if color then return color.r, color.g, color.b end
	end))
	if r then return r, g, b end
	return Kit:RGB('lamp')
end

local function ReactionColor(unit)
	local r, g, b = Checked(pcall(function()
		if UnitIsTapDenied and UnitIsTapDenied(unit) then return 0.55, 0.55, 0.53 end
		local reaction = UnitReaction(unit, 'player')
		local color = not IsSecret(reaction) and reaction and FACTION_BAR_COLORS and FACTION_BAR_COLORS[reaction]
		if color then return color.r, color.g, color.b end
	end))
	if r then return r, g, b end
	return Kit:RGB('lamp')
end

local function HealthColor(plate)
	local db, unit = DB(), plate.unit
	if db.threatColorBar and plate.threatKey then
		local r, g, b = RGB(db[plate.threatKey])
		if r then return r, g, b end
	end
	if plate.questOn and db.questHealth then
		local r, g, b = RGB(db.questHealthColor)
		if r then return r, g, b end
	end
	local isPlayer = Plain(UnitIsPlayer, unit) == true
	if plate.friendly then
		if isPlayer and db.friendlyClassColor then return ClassColor(unit) end
		if not db.classColor then return Kit:RGB('lamp') end
		return ReactionColor(unit)
	end
	if isPlayer then
		if db.enemyPlayerClassColor then return ClassColor(unit) end
		return db.classColor and ReactionColor(unit) or Kit:RGB('lamp')
	end
	if not db.classColor or db.npcColor == 'accent' then return Kit:RGB('lamp') end
	return ReactionColor(unit)
end

-- A lamp that's off reads as a dark dot on the glass.
local function Lamp(led, on, token)
	if on then
		Kit:SetLed(led, true, token)
	else
		Kit:SetLed(led, false)
		Kit:Tint(led, 'darkEdge')
	end
end

-- Numbers ------------------------------------------------------------------------------
-- The client's number formatting takes secret values; ours only plain ones.
local function Short(value)
	if AbbreviateNumbers then
		local ok, text = pcall(AbbreviateNumbers, value)
		if ok then return text end
	end
	if IsSecret(value) then return value end
	if value >= 1e6 then return format('%.1fm', value / 1e6) end
	if value >= 1e4 then return format('%.0fk', value / 1e3) end
	return format('%d', value)
end

local function SetHealthText(fontString, unit, kind)
	local ok = pcall(function()
		if kind == 'none' then fontString:SetText('') return end
		if kind == 'current' then return fontString:SetFormattedText('%s', Short(UnitHealth(unit))) end
		if kind == 'both' then return fontString:SetFormattedText('%s / %s', Short(UnitHealth(unit)), Short(UnitHealthMax(unit))) end
		if kind == 'deficit' then
			local health, maximum = UnitHealth(unit), UnitHealthMax(unit)
			if not IsSecret(health) and not IsSecret(maximum) then
				local missing = maximum - health
				return fontString:SetText(missing > 0 and '-'..Short(missing) or '')
			end
			if UnitHealthMissing then return fontString:SetFormattedText('-%s', Short(UnitHealthMissing(unit))) end
		end
		if UnitHealthPercent and CurveConstants and CurveConstants.ScaleTo100 then
			return fontString:SetFormattedText('%d', UnitHealthPercent(unit, true, CurveConstants.ScaleTo100))
		end
		local health, maximum = UnitHealth(unit), UnitHealthMax(unit)
		if IsSecret(health) or IsSecret(maximum) then return fontString:SetText('') end
		fontString:SetFormattedText('%d', maximum > 0 and floor(health / maximum * 100 + 0.5) or 0)
	end)
	if not ok then fontString:SetText('') end
end

-- A plain name cut to a number of characters, counting UTF-8 characters.
local function Truncate(text, length)
	if not length or length <= 0 then return text end
	local out, count = {}, 0
	for char in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
		count = count + 1
		if count > length then break end
		out[count] = char
	end
	return table.concat(out)
end

-- Execute range: 1 at or under the percentage, 0 above, looked up by the client
-- from the unit's health so a secret health still lights it.
local executeCurves = {}
local function ExecuteCurve(percent)
	local curve = executeCurves[percent]
	if curve ~= nil then return curve or nil end
	executeCurves[percent] = false
	if not (C_CurveUtil and C_CurveUtil.CreateCurve) then return nil end
	local ok, made = pcall(C_CurveUtil.CreateCurve)
	if not ok or not made then return nil end
	if Enum and Enum.LuaCurveType and made.SetType then pcall(made.SetType, made, Enum.LuaCurveType.Linear) end
	made:AddPoint(0, 1)
	made:AddPoint(percent, 1)
	made:AddPoint(min(percent + 0.001, 1), 0)
	if percent + 0.001 < 1 then made:AddPoint(1, 0) end
	executeCurves[percent] = made
	return made
end

-- Construction --------------------------------------------------------------------
-- A pill or bar fill is masked to its shape; the mask is sized from the bar's
-- own height, checked for a secret before it is compared.
local function MaskFill(bar, file, margin)
	local mask = bar:CreateMaskTexture()
	mask:SetTexture(Kit.media..file..'.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
	if mask.SetTextureSliceMargins then
		mask:SetTextureSliceMargins(margin, margin, margin, margin)
		if STRETCHED and mask.SetTextureSliceMode then mask:SetTextureSliceMode(STRETCHED) end
	end
	mask:SetAllPoints(bar)
	bar:GetStatusBarTexture():AddMaskTexture(mask)
	if mask.SetScale then
		local function Fit(_, _, height)
			if IsSecret(height) or not height or height <= 0 then return end
			mask:SetScale(file == 'mask-pill' and height / (2 * margin) or 2 / margin)
		end
		bar:HookScript('OnSizeChanged', Fit)
		Fit(nil, nil, bar:GetHeight())
	end
end

local function BuildMeter(plate)
	local style = Style()
	local track = CreateFrame('Frame', nil, plate)
	track.shell = Kit:Shell(track, {surface = 'screen', radius = style == 'bar' and 2 or 99, shadow = false})
	local bar = CreateFrame('StatusBar', nil, track)
	local side = style == 'dots' and 3 or (style == 'bar' and 1 or 2)
	local inset = style == 'bar' and 1 or 2
	bar:SetPoint('TOPLEFT', side, -inset)
	bar:SetPoint('BOTTOMRIGHT', -side, inset)
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(1)
	if style == 'dots' then
		bar:SetStatusBarTexture([[Interface\Buttons\WHITE8X8]])
		Kit:Perforate(bar, 'black', 'darkEdge')
	else
		bar:SetStatusBarTexture(Kit.media..'bar-flat.tga')
		MaskFill(bar, style == 'pill' and 'mask-pill' or 'mask-bar', style == 'pill' and 15 or 5)
	end
	if Kit.MarkBar then Kit:MarkBar(bar:GetStatusBarTexture()) end
	-- Execute range: a red wash over the fill and a hairline at the percentage.
	plate.exec = bar:CreateTexture(nil, 'ARTWORK', nil, 3)
	plate.exec:SetAllPoints(bar:GetStatusBarTexture())
	plate.exec:SetColorTexture(1, 1, 1, 1)
	Kit:Tint(plate.exec, 'red')
	plate.exec:SetAlpha(0)
	plate.execLine = bar:CreateTexture(nil, 'OVERLAY', nil, 7)
	plate.execLine:SetColorTexture(1, 1, 1, 1)
	Kit:Tint(plate.execLine, 'red')
	plate.execLine:SetWidth(1)
	plate.execLine:Hide()
	-- Health text on the bar itself, when it's placed there.
	plate.barText = Kit:Text(bar, '', 7, 'white', true, true)
	plate.barText:SetPoint('CENTER', 0, 0)
	plate.track, plate.health, plate.side = track, bar, side
end

local function IconMask(owner, texture)
	local mask = owner:CreateMaskTexture()
	mask:SetTexture(Kit.media..'mask-icon.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
	mask:SetAllPoints(texture)
	texture:AddMaskTexture(mask)
end

local function BuildCast(plate)
	local cast = CreateFrame('Frame', nil, plate)
	cast:SetPoint('TOPLEFT', plate, 'BOTTOMLEFT', 0, -2)
	cast:SetPoint('TOPRIGHT', plate, 'BOTTOMRIGHT', 0, -2)
	cast:SetHeight(18)
	cast.shell = Kit:Shell(cast, {surface = 'glass', radius = 4, shadowAlpha = 0.4})
	cast.icon = cast:CreateTexture(nil, 'ARTWORK')
	cast.icon:SetSize(12, 12)
	cast.icon:SetPoint('LEFT', 3, 0)
	cast.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	IconMask(cast, cast.icon)
	cast.label = Kit:Text(cast, '', 7, 'darkInk', true)
	cast.label:SetJustifyH('LEFT')
	cast.label:SetWordWrap(false)
	local track = CreateFrame('Frame', nil, cast)
	track:SetHeight(4)
	track.shell = Kit:Shell(track, {surface = 'screen', radius = 99, shadow = false})
	local bar = CreateFrame('StatusBar', nil, track)
	bar:SetPoint('TOPLEFT', 1, -1)
	bar:SetPoint('BOTTOMRIGHT', -1, 1)
	bar:SetStatusBarTexture(Kit.media..'bar-flat.tga')
	bar:SetMinMaxValues(0, 1)
	if Kit.MarkBar then Kit:MarkBar(bar:GetStatusBarTexture()) end
	cast.bar, cast.track = bar, track
	cast.gray = bar:CreateTexture(nil, 'ARTWORK', nil, 2)
	cast.gray:SetAllPoints(bar:GetStatusBarTexture())
	cast.gray:SetTexture(Kit.media..'bar-flat.tga')
	cast.gray:SetAlpha(0)
	cast:SetAlpha(0)
	cast:Hide()
	plate.cast = cast
end

local function BuildAuras(plate)
	plate.auras = {}
	for index = 1, AURA_MAX do
		local icon = CreateFrame('Frame', nil, plate)
		icon:SetSize(18, 18)
		icon.shell = Kit:Shell(icon, {surface = 'glass', radius = 3, shadowAlpha = 0.4})
		icon.texture = icon:CreateTexture(nil, 'ARTWORK')
		icon.texture:SetPoint('TOPLEFT', 2, -2)
		icon.texture:SetPoint('BOTTOMRIGHT', -2, 2)
		icon.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		IconMask(icon, icon.texture)
		icon.cooldown = CreateFrame('Cooldown', nil, icon, 'CooldownFrameTemplate')
		icon.cooldown:SetAllPoints(icon.texture)
		if icon.cooldown.SetDrawEdge then icon.cooldown:SetDrawEdge(false) end
		if icon.cooldown.SetHideCountdownNumbers then icon.cooldown:SetHideCountdownNumbers(true) end
		if icon.cooldown.SetSwipeTexture then icon.cooldown:SetSwipeTexture(Kit.media..'mask-icon.tga', 0, 0, 0, 0.7) end
		icon.count = Kit:Text(icon, '', 7, 'darkInk', true, true)
		icon.count:SetPoint('BOTTOMRIGHT', 1, 0)
		icon.count:SetDrawLayer('OVERLAY', 7)
		icon:Hide()
		plate.auras[index] = icon
	end
end

local function LayoutCast(plate)
	local db, cast = DB(), plate.cast
	-- Compact plates cast on a slim bar with no name or icon.
	local compact = plate.state == 'compact'
	local height = compact and 8 or (db.castHeight or 18)
	cast:SetHeight(height)
	local iconSize = max(8, height - 6)
	cast.icon:SetSize(iconSize, iconSize)
	local showIcon, showName = db.castIcon and not compact, db.castName and not compact
	cast.icon:SetShown(showIcon and true or false)
	local left = showIcon and cast.icon or nil
	cast.label:ClearAllPoints()
	if left then cast.label:SetPoint('TOPLEFT', left, 'TOPRIGHT', 4, 1) else cast.label:SetPoint('TOPLEFT', 4, -2) end
	cast.label:SetPoint('RIGHT', cast, 'RIGHT', -4, 0)
	cast.label:SetShown(showName and true or false)
	cast.track:ClearAllPoints()
	if left then cast.track:SetPoint('BOTTOMLEFT', left, 'BOTTOMRIGHT', 4, 0) else cast.track:SetPoint('BOTTOMLEFT', cast, 'BOTTOMLEFT', compact and 2 or 4, compact and 2 or 3) end
	cast.track:SetPoint('BOTTOMRIGHT', cast, 'BOTTOMRIGHT', compact and -2 or -4, compact and 2 or 3)
	-- Without a name line, the bar takes the height.
	cast.track:SetHeight(showName and 4 or max(4, height - (compact and 4 or 6)))
end

local function LayoutAuras(plate)
	local db = DB()
	local size, count = db.auraSize or 18, min(db.auraCount or 5, AURA_MAX)
	if plate.state == 'compact' then size = max(10, floor(size * 0.75 + 0.5)) end
	for index, icon in ipairs(plate.auras) do
		icon:SetSize(size, size)
		if icon.cooldown.SetHideCountdownNumbers then icon.cooldown:SetHideCountdownNumbers(not db.auraTime) end
		icon:ClearAllPoints()
		if index == 1 then
			if db.auraPosition == 'below' then
				icon:SetPoint('TOPLEFT', plate, 'BOTTOMLEFT', 0, -(db.castbar and (db.castHeight or 18) + 6 or 3))
			else
				-- Above the name when the name sits above the plate.
				local lift = (db.namePosition == 'above' and not plate.nameOnly) and (db.nameSize or 8) + 6 or 0
				-- Room for anything riding the plate's top edge (the nav tape).
				if module.TopLift then lift = lift + (module.TopLift(plate) or 0) end
				icon:SetPoint('BOTTOMLEFT', plate, 'TOPLEFT', 0, 3 + lift)
			end
		else
			icon:SetPoint('LEFT', plate.auras[index - 1], 'RIGHT', 3, 0)
		end
		if index > count then icon:Hide() end
	end
end
module.LayoutAuras = LayoutAuras

-- Quest units --------------------------------------------------------------------
-- A mark for units your quests need: the quest glyph, a lamp, a printed Q chip,
-- an LCD with the objective's progress, or the old exclamation mark.
local QUEST_GLYPH = {6 / 8, 7 / 8, 0, 1 / 4} -- 'quest' in icons-menu.tga (8 x 4)
local BuildQuest, NameRight, PlaceQuest, PaintQuest, QuestMotion, QuestProgress, HeaderLamp
do
	local function MarkerRGB(db, boss)
		if boss then return Kit:RGB('red') end
		if db.questColor == 'key' then return Kit:RGB('lamp') end
		if db.questColor == 'custom' then
			local r, g, b = RGB(db.questCustomColor)
			if r then return r, g, b end
		end
		return Kit:RGB('amber')
	end

	function BuildQuest(plate)
		local mark = CreateFrame('Frame', nil, plate)
		mark:SetSize(12, 12)
		mark:EnableMouse(false)
		mark.bang = Kit:Text(mark, '!', 11, 'amber', true, true)
		mark.bang:SetPoint('CENTER')
		mark.glyph = mark:CreateTexture(nil, 'OVERLAY', nil, 2)
		mark.glyph:SetTexture(Kit.media..'icons-menu.tga')
		mark.glyph:SetTexCoord(unpack(QUEST_GLYPH))
		mark.glyph:SetAllPoints()
		mark.led = Kit:Led(mark, 6, true)
		mark.led:SetPoint('CENTER')
		mark.chip = Kit:LCDPanel(mark, {radius = 2})
		mark.chip:SetAllPoints()
		mark.chip.text = Kit:Text(mark.chip, 'Q', 7, 'lcdInk', true)
		mark.chip.text:SetPoint('CENTER', 0.5, 0)
		mark:Hide()
		plate.quest = mark
	end

	-- The name's anchors in the header: it stops before the quest mark when
	-- the mark sits in the header.
	function NameRight(plate)
		local db = DB()
		if plate.nameOnly or db.namePosition == 'above' then return end
		plate.name:ClearAllPoints()
		if db.level then plate.name:SetPoint('LEFT', plate.chip, 'RIGHT', 5, 0)
		else plate.name:SetPoint('LEFT', plate.lamp, 'RIGHT', 5, 0) end
		local right = plate.percent:IsShown() and plate.percent or plate.threat
		if plate.percent:IsShown() and plate.percentLegend and plate.percentLegend:IsShown() then right = plate.percentLegend end
		if plate.quest and plate.quest:IsShown() and db.questPosition == 'header' then right = plate.quest end
		plate.name:SetPoint('RIGHT', right, 'LEFT', -4, 0)
	end

	function PlaceQuest(plate)
		local db, mark = DB(), plate.quest
		local size = db.questSize or 12
		local style = db.questStyle or 'glyph'
		if style == 'chip' then mark:SetSize(size + 2, max(size - 1, 9))
		elseif style == 'progress' then mark:SetSize(max(size * 2.4, 24), max(size - 1, 9))
		else mark:SetSize(size, size) end
		Kit:Font(mark.bang, size + 1, nil, true)
		Kit:Font(mark.chip.text, max(6, floor(size * 0.62 + 0.5)), nil, true, 'numbers')
		local led = max(4, floor(size * 0.5 + 0.5))
		mark.led:SetSize(led, led)
		if mark.led.glow and Kit.FitSprite then Kit:FitSprite(mark.led.glow, led, led) end
		mark:ClearAllPoints()
		local position = db.questPosition or 'right'
		if position == 'left' then
			mark:SetPoint('RIGHT', plate, 'LEFT', -3, 2)
		elseif position == 'above' then
			if db.namePosition == 'above' and not plate.nameOnly then mark:SetPoint('BOTTOM', plate.name, 'TOP', 0, 2)
			else mark:SetPoint('BOTTOM', plate, 'TOP', 0, 2) end
		elseif position == 'header' then
			mark:SetPoint('RIGHT', plate.percent:IsShown() and plate.percent or plate.threat, 'LEFT', -4, 0)
		else
			mark:SetPoint('LEFT', plate, 'RIGHT', 3, 2)
		end
	end

	-- progress: the objective count, when the game shares it plainly; without
	-- it the Progress style falls back to the glyph.
	function PaintQuest(plate, boss, progress)
		local db, mark = DB(), plate.quest
		local style = db.questStyle or 'glyph'
		if style == 'progress' and not progress then style = 'glyph' end
		local r, g, b = MarkerRGB(db, boss)
		mark.bang:SetShown(style == 'exclamation')
		mark.bang:SetTextColor(r, g, b)
		mark.glyph:SetShown(style == 'glyph')
		mark.glyph:SetVertexColor(r, g, b)
		Kit:ShowLed(mark.led, style == 'led')
		if style == 'led' then
			mark.led:SetVertexColor(r, g, b)
			if mark.led.glow then mark.led.glow:SetVertexColor(r, g, b) end
		end
		local chip = style == 'chip' or style == 'progress'
		mark.chip:SetShown(chip)
		if chip then
			mark.chip.text:SetText(style == 'progress' and progress or 'Q')
			mark.chip.text:SetTextColor(r, g, b)
		end
	end

	-- "3/8" or "40%" from the unit's tooltip objective lines; plain text only.
	function QuestProgress(unit)
		if not (C_TooltipInfo and C_TooltipInfo.GetUnit and unit) then return nil end
		local ok, data = pcall(C_TooltipInfo.GetUnit, unit)
		if not ok or IsSecret(data) or type(data) ~= 'table' then return nil end
		local lines = data.lines
		if IsSecret(lines) or type(lines) ~= 'table' then return nil end
		local objective = Enum and Enum.TooltipDataLineType and Enum.TooltipDataLineType.QuestObjective
		for _, line in ipairs(lines) do
			if type(line) == 'table' then
				local kind, text, done = line.type, line.leftText, line.completed
				local isObjective = objective and not IsSecret(kind) and kind == objective
				local finished = not IsSecret(done) and done == true
				if isObjective and not finished and not IsSecret(text) and type(text) == 'string' then
					local have, need = text:match('(%d+)%s*/%s*(%d+)')
					if have then return have..'/'..need end
					local percent = text:match('(%d+)%%')
					if percent then return percent..'%' end
				end
			end
		end
		return nil
	end

	-- The header lamp glows amber on quest units you haven't targeted.
	function HeaderLamp(plate)
		if plate.isTarget then return end
		if plate.questOn and DB().questLamp and not plate.nameOnly then Lamp(plate.lamp, true, 'amber')
		else Lamp(plate.lamp, false) end
	end

	-- The mark blinks while the unit is your target, or breathes otherwise.
	function QuestMotion(plate)
		local db, mark = DB(), plate.quest
		local want
		if plate.questOn and mark:IsShown() and not Kit:DB().reduceMotion then
			if plate.isTarget and db.questBlink then want = 'blink' elseif db.questBreathe then want = 'breathe' end
		end
		if plate.questMotion == want then return end
		if plate.questMotion == 'blink' then Kit:Blink(mark, nil, false)
		elseif plate.questMotion == 'breathe' then Kit:Breathe(mark, false) end
		mark:SetAlpha(1)
		plate.questMotion = want
		if want == 'blink' then Kit:Blink(mark, 0.8, true)
		elseif want == 'breathe' then Kit:Breathe(mark, true, {period = 2.2, low = 0.45}) end
	end
end

-- Sizes come from the settings, so a change applies to every plate at once.
-- Two states: every plate is a slim Compact strip (name, a hairline meter, a
-- small level) until it is your target (or focus, or under the mouse, as
-- chosen), when it opens into the Full device: lamp, LV and level, name, HP
-- and readout, and the meter, all in one tight housing.
local function UnitPlate(unit)
	if not C_NamePlate or not C_NamePlate.GetNamePlateForUnit then return nil end
	local ok, nameplate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
	return ok and nameplate or nil
end

local function State(plate)
	if plate.nameOnly then return 'name' end
	if plate.preview then return plate.previewState or 'full' end
	local db = DB()
	if db.otherPlates == 'full' then return 'full' end
	local nameplate = plate.nameplate
	if not nameplate then return 'full' end
	if nameplate == UnitPlate('target') then return 'full' end
	if db.expandFocus and nameplate == UnitPlate('focus') then return 'full' end
	if db.expandMouseover and nameplate == UnitPlate('mouseover') then return 'full' end
	return 'compact'
end
module.State = State

local function Layout(plate)
	local db = DB()
	local nameOnly = plate.nameOnly
	local state = nameOnly and 'name' or (plate.state or State(plate))
	plate.state = state
	local compact = state == 'compact'
	local fullWidth = db.width or 132
	local width = compact and floor(fullWidth * (db.compactWidth or 0.7) + 0.5) or fullWidth
	local height = compact and ((db.compactMeter or 'hairline') == 'dots' and 3 or 2) or max(3, db.targetHeight or 5)
	local nameSize = compact and max(6, (db.nameSize or 8) - 1) or (db.nameSize or 8)
	local plateHeight = nameOnly and 16 or (compact and (height + nameSize + 5) or (height + 21))
	plate.stateWidth, plate.stateHeight = width, plateHeight
	if not plate.morphing then plate:SetSize(width, plateHeight) end
	-- Housing: a tight glass device in Full; none (or a faint glass) in Compact.
	local housing = compact and (db.compactHousing or 'none') or (db.housing or 'glass')
	plate.shell:SetShown(not nameOnly and housing ~= 'none')
	plate.shell:SetAlpha(compact and 0.4 or 1)
	-- The meter sits right under the header, inside the same housing.
	local pad = (compact or housing == 'none') and 0 or 4
	plate.track:SetShown(not nameOnly)
	plate.track:ClearAllPoints()
	plate.track:SetPoint('BOTTOMLEFT', pad, pad)
	plate.track:SetPoint('BOTTOMRIGHT', -pad, pad)
	plate.track:SetHeight(compact and height or height + 2)
	local dots = Style() == 'dots'
	local hairline = compact and (db.compactMeter or 'hairline') ~= 'dots'
	local bar = plate.health
	-- A hairline hides the dot cover; dots keep it.
	if bar.kitCover then
		bar.kitCover:SetAlpha(hairline and 0 or 1)
		bar.kitUnder:SetAlpha(hairline and 0 or 1)
	end
	local side, inset = plate.side, 1
	if compact then side, inset = 0, 0 end
	local avail = width - 2 * pad - side * 2
	plate.fillWidth = avail
	bar:ClearAllPoints()
	if dots and not nameOnly and not hairline then
		local pitch = max(height, 1)
		local count = max(1, floor(avail / pitch + 0.001))
		plate.fillWidth = count * pitch
		bar:SetPoint('LEFT', plate.track, 'LEFT', side + (avail - plate.fillWidth) / 2, 0)
		bar:SetSize(plate.fillWidth, height)
		if Kit.SizePerforation then Kit:SizePerforation(bar) end
	else
		bar:SetPoint('TOPLEFT', plate.track, 'TOPLEFT', side, -inset)
		bar:SetPoint('BOTTOMRIGHT', plate.track, 'BOTTOMRIGHT', -side, inset)
	end
	-- Level: printed inline (LV and the number, no box) or on its LCD chip in
	-- Full; just a small dim number in Compact.
	local legends = db.legends ~= false and not compact
	local inline = compact or db.levelInline ~= false
	local chip = (compact and db.compactLevel ~= false or (not compact and db.level)) and not nameOnly
	plate.chip:SetShown(chip and true or false)
	if plate.chip.shell then plate.chip.shell:SetShown(not inline) end
	if plate.chip.inner then plate.chip.inner:SetShown(not inline) end
	plate.chip.legend:SetShown(legends)
	Kit:Font(plate.chip.text, compact and max(6, nameSize - 1) or 7, nil, true, 'numbers')
	plate.chipInk = inline and (compact and 'darkDim' or 'darkInk') or 'lcdInk'
	Kit:Tint(plate.chip.text, plate.chipInk)
	Kit:Tint(plate.chip.legend, inline and 'darkDim' or 'lcdDim')
	plate.chip:ClearAllPoints()
	plate.chip.text:ClearAllPoints()
	if compact then
		plate.chip:SetSize(16, nameSize + 2)
		plate.chip:SetPoint('TOPLEFT', plate, 'TOPLEFT', 0, 0)
		plate.chip.text:SetPoint('LEFT', plate.chip, 'LEFT', 0, 0)
		plate.chip.text:SetJustifyH('LEFT')
	else
		plate.chip:SetSize(legends and 30 or 20, 11)
		plate.chip:SetPoint('TOPLEFT', plate, 'TOPLEFT', 12, -4)
		if legends then
			plate.chip.text:SetPoint('RIGHT', plate.chip, 'RIGHT', inline and 0 or -3, 0)
			plate.chip.text:SetJustifyH('RIGHT')
		else
			plate.chip.text:SetPoint('CENTER', 0.5, 0)
			plate.chip.text:SetJustifyH('CENTER')
		end
	end
	plate.chip.legend:ClearAllPoints()
	plate.chip.legend:SetPoint('LEFT', plate.chip, 'LEFT', inline and 0 or 3, 0)
	-- Lamps: the target lamp in Full; threat as a tiny dot in Compact.
	plate.lamp:ClearAllPoints()
	plate.lamp:SetPoint('TOPLEFT', plate, 'TOPLEFT', 5, -7)
	Kit:ShowLed(plate.lamp, not nameOnly and not compact)
	plate.threat:ClearAllPoints()
	if compact then
		plate.threat:SetSize(3, 3)
		plate.threat:SetPoint('TOPRIGHT', plate, 'TOPRIGHT', 0, -2)
	else
		plate.threat:SetSize(4, 4)
		plate.threat:SetPoint('TOPRIGHT', plate, 'TOPRIGHT', -5, -7)
	end
	Kit:ShowLed(plate.threat, db.threat and not nameOnly)
	-- The health readout: in the header (Full only) or on the bar.
	local text, onBar = db.healthText or 'percent', db.healthTextPosition == 'bar'
	plate.percent:SetShown(not nameOnly and not compact and text ~= 'none' and not onBar)
	plate.percentLegend:SetShown(plate.percent:IsShown() and legends)
	plate.barText:SetShown(not nameOnly and not compact and text ~= 'none' and onBar)
	-- The name: in the header, centred in it, above the plate, or on its own.
	Kit:Font(plate.name, nameSize, nil, true)
	plate.name:ClearAllPoints()
	if nameOnly then
		plate.name:SetPoint('CENTER')
		plate.name:SetWidth(width)
		plate.name:SetJustifyH('CENTER')
	elseif compact then
		if chip then plate.name:SetPoint('LEFT', plate.chip, 'LEFT', 14, 0)
		else plate.name:SetPoint('TOPLEFT', plate, 'TOPLEFT', 0, -1) end
		plate.name:SetPoint('RIGHT', plate, 'RIGHT', -6, 0)
		plate.name:SetJustifyH('LEFT')
	elseif db.namePosition == 'above' then
		plate.name:SetPoint('BOTTOM', plate, 'TOP', 0, 2)
		plate.name:SetWidth(width)
		plate.name:SetJustifyH('CENTER')
	else
		plate.name:SetWidth(0)
		plate.name:SetJustifyH(db.namePosition == 'center' and 'CENTER' or 'LEFT')
		NameRight(plate)
	end
	-- Execute hairline at its percentage along the fill.
	local fill = plate.fillWidth
	plate.execLine:ClearAllPoints()
	plate.execLine:SetPoint('TOPLEFT', bar, 'TOPLEFT', fill * (db.executePercent or 0.2), 0)
	plate.execLine:SetPoint('BOTTOMLEFT', bar, 'BOTTOMLEFT', fill * (db.executePercent or 0.2), 0)
	plate.execLine:SetShown(db.execute and not nameOnly and not compact and true or false)
	if not db.execute or nameOnly then plate.exec:SetAlpha(0) end
	if plate.quest then PlaceQuest(plate) end
	LayoutCast(plate)
	LayoutAuras(plate)
end

-- Opening into Full or folding back to Compact: the plate's size eases and
-- the header's parts fade in.
local function Morph(plate, state, animate)
	local oldWidth, oldHeight = plate:GetSize()
	plate.state = state
	plate.morphing = true
	Layout(plate)
	local width, height = plate.stateWidth, plate.stateHeight
	plate.morphKey = plate.morphKey or {}
	if not animate or Kit:DB().reduceMotion or not oldWidth or oldWidth <= 0 then
		Kit:Animate(plate.morphKey, 0, 0, 1, function() end)
		plate.morphing = nil
		plate:SetSize(width, height)
		return
	end
	Kit:Animate(plate.morphKey, 0.18, 0, 1, function(t)
		plate:SetSize(oldWidth + (width - oldWidth) * t, oldHeight + (height - oldHeight) * t)
	end, function()
		plate.morphing = nil
		plate:SetSize(width, height)
	end, 'detent')
	if state == 'full' then
		for _, part in ipairs({plate.chip, plate.percent, plate.percentLegend}) do
			if part:IsShown() then
				part:SetAlpha(0)
				Kit:FadeTo(part, 1, 'FAST')
			end
		end
	end
end

-- Defined further down, with the other target styles.
local BuildBrackets

local function Build()
	local plate = CreateFrame('Frame', nil, home)
	plate:EnableMouse(false)
	plate:Hide()
	plate.scaleKey = {}
	plate.shell = Kit:Shell(plate, {surface = 'glass', radius = 5, shadowAlpha = 0.45})
	-- Target looks: a lit ring around the plate, or lamps either side of it.
	plate.ring = Kit:Texture(plate, 'ring-6', 'OVERLAY', 6)
	Kit:Place(plate.ring, plate, 2, 2, 2, 2)
	Kit:Tint(plate.ring, 'lamp')
	plate.ring:Hide()
	plate.sideLeft = Kit:Led(plate, 5, false)
	plate.sideLeft:SetPoint('RIGHT', plate, 'LEFT', -4, 0)
	plate.sideRight = Kit:Led(plate, 5, false)
	plate.sideRight:SetPoint('LEFT', plate, 'RIGHT', 4, 0)
	BuildBrackets(plate)
	-- Header: target lamp, level chip, name, health readout, threat lamp.
	plate.lamp = Kit:Led(plate, 4, false)
	plate.lamp:SetPoint('TOPLEFT', 6, -9)
	plate.chip = Kit:LCDPanel(plate, {radius = 2})
	plate.chip:SetSize(24, 11)
	plate.chip:SetPoint('TOPLEFT', 14, -5.5)
	plate.chip.text = Kit:Text(plate.chip, '', 7, 'lcdInk', true)
	plate.chip.text:SetPoint('CENTER', 0.5, 0)
	-- Printed legends: LV in the chip before the level, HP before the readout.
	-- Each is its own string, so a secret value is never joined to it.
	plate.chip.legend = Kit:Label(plate.chip, 'Lv', 'lcdDim', 5, true)
	plate.chip.legend:SetPoint('LEFT', 3, 0)
	plate.threat = Kit:Led(plate, 4, false)
	plate.threat:SetPoint('TOPRIGHT', -6, -9)
	plate.percent = Kit:Text(plate, '', 7, 'darkDim', true)
	plate.percent:SetPoint('RIGHT', plate.threat, 'LEFT', -4, 0)
	plate.percent:SetJustifyH('RIGHT')
	plate.percentLegend = Kit:Label(plate, 'Hp', 'darkDim', 5, true)
	plate.percentLegend:SetPoint('RIGHT', plate.percent, 'LEFT', -2, 0)
	plate.percentLegend:SetAlpha(0.7)
	plate.name = Kit:Text(plate, '', 8, 'darkInk', true)
	plate.name:SetJustifyH('LEFT')
	plate.name:SetWordWrap(false)
	-- A quest unit: a mark beside the plate (or in its header).
	BuildQuest(plate)
	BuildMeter(plate)
	BuildCast(plate)
	BuildAuras(plate)
	Lamp(plate.lamp, false)
	Lamp(plate.threat, false)
	Lamp(plate.sideLeft, false)
	Lamp(plate.sideRight, false)
	Kit:ShowLed(plate.sideLeft, false)
	Kit:ShowLed(plate.sideRight, false)
	plate.events = CreateFrame('Frame', nil, plate)
	Layout(plate)
	return plate
end

-- Updates ---------------------------------------------------------------------------
local function UpdateExecute(plate)
	if not DB().execute or plate.nameOnly or not UnitHealthPercent then plate.exec:SetAlpha(0) return end
	local curve = ExecuteCurve(DB().executePercent or 0.2)
	if not curve then plate.exec:SetAlpha(0) return end
	local ok, alpha = pcall(UnitHealthPercent, plate.unit, true, curve)
	if not ok or not pcall(plate.exec.SetAlpha, plate.exec, alpha) then plate.exec:SetAlpha(0) end
end

local function UpdateHealth(plate)
	local unit = plate.unit
	plate.health:SetMinMaxValues(0, UnitHealthMax(unit))
	plate.health:SetValue(UnitHealth(unit), Smooth())
	local kind = DB().healthText or 'percent'
	if plate.percent:IsShown() then SetHealthText(plate.percent, unit, kind) end
	if plate.barText:IsShown() then SetHealthText(plate.barText, unit, kind) end
	UpdateExecute(plate)
end

local function UpdateColor(plate)
	local r, g, b = HealthColor(plate)
	plate.health:SetStatusBarColor(r, g, b)
	-- A name-only plate carries its color in the name.
	if plate.nameOnly then
		plate.name:SetTextColor(r, g, b)
	else
		Kit:Tint(plate.name, 'darkInk')
		if plate.questOn and DB().questName then
			local nr, ng, nb = RGB(DB().questNameColor)
			if nr then plate.name:SetTextColor(nr, ng, nb) end
		end
	end
end

-- A long name steps its font down (to two sizes under the setting, 6 at
-- least) before it is cut short, so names fit the header where they can.
local function FitName(plate)
	local name, base = plate.name, DB().nameSize or 8
	local room = name:GetWidth()
	if IsSecret(room) or not room or room <= 0 then return end
	for size = base, max(6, base - 2), -1 do
		Kit:Font(name, size, nil, true)
		local width = name:GetStringWidth()
		if IsSecret(width) or not width or width <= room then return end
	end
end

local function UpdateName(plate)
	local unit = plate.unit
	local name = UnitName(unit)
	if IsSecret(name) then plate.name:SetText(name)
	else
		plate.name:SetText(name and Truncate(strupper(name), DB().nameLength) or '')
		UI:Safe(FitName, plate)
	end
	local class = Plain(UnitClassification, unit)
	plate.elite = class == 'elite' or class == 'rareelite' or class == 'worldboss'
	local chip = plate.chip.text
	Kit:Tint(chip, plate.chipInk or 'lcdInk')
	local level = Plain(UnitLevel, unit)
	if level == nil then
		-- A secret level is formatted by the client, untested.
		if not pcall(function() chip:SetFormattedText('%d', UnitLevel(unit)) end) then chip:SetText('') end
		return
	end
	if level <= 0 or class == 'worldboss' then
		chip:SetText('??')
		Kit:Tint(chip, 'red')
		return
	end
	local mark = (class == 'elite' or class == 'rareelite') and '+' or (class == 'rare') and '*' or ''
	chip:SetText(level..mark)
end

local function UpdateQuest(plate)
	local db, unit = DB(), plate.unit
	local on = false
	if not plate.nameOnly and unit and C_QuestLog and C_QuestLog.UnitIsRelatedToActiveQuest then
		on = Plain(C_QuestLog.UnitIsRelatedToActiveQuest, unit) == true
	end
	local was = plate.questOn
	plate.questOn = on
	local style = db.questStyle or 'glyph'
	local show = on and db.questMarker and style ~= 'none'
	if show then
		local boss = UnitIsQuestBoss and Plain(UnitIsQuestBoss, unit) == true
		PlaceQuest(plate)
		PaintQuest(plate, boss, style == 'progress' and QuestProgress(unit) or nil)
	end
	plate.quest:SetShown(show and true or false)
	NameRight(plate)
	if was ~= on then UpdateColor(plate) end
	HeaderLamp(plate)
	QuestMotion(plate)
end

-- A tank wants to hold aggro; everyone else wants not to have it.
local function TankMode()
	local mode = DB().tankMode
	if mode == 'on' then return true elseif mode == 'off' then return false end
	local spec = GetSpecialization and Plain(GetSpecialization)
	local role = spec and GetSpecializationRole and Plain(GetSpecializationRole, spec)
	return role == 'TANK'
end

-- Which threat color a plate shows: 'threatSecure', 'threatInsecure', 'threatAggro' or nil.
local function ThreatKey(plate)
	local status = Plain(UnitThreatSituation, 'player', plate.unit)
	if status == nil then return nil end
	if TankMode() then
		if status == 3 then return 'threatSecure' end
		if status >= 1 then return 'threatInsecure' end
		-- On the unit's threat list but held by someone else: lost.
		if Plain(UnitAffectingCombat, plate.unit) == true then return 'threatAggro' end
		return nil
	end
	if status >= 2 then return 'threatAggro' end
	if status == 1 then return 'threatInsecure' end
	return nil
end

-- The threat lamp in its color setting (an explicit color the kit's repaint resets).
local function PaintThreat(plate)
	local db, key = DB(), plate.threatKey
	if not db.threat then return end
	if key then
		Lamp(plate.threat, true, 'amber')
		local r, g, b = RGB(db[key])
		if r then plate.threat:SetVertexColor(r, g, b) end
	else
		Lamp(plate.threat, false)
	end
end

local function UpdateThreat(plate)
	local db = DB()
	local key = (db.threat or db.threatColorBar) and ThreatKey(plate) or nil
	local changed = key ~= plate.threatKey
	plate.threatKey = key
	PaintThreat(plate)
	if changed and db.threatColorBar then UpdateColor(plate) end
end

-- The game's plate frames are scaled by its own nameplate settings (global,
-- selected and distance scale), not by the interface's UI scale. Our plate
-- undoes that: its size on screen follows the UI scale times our own
-- multiplier, so a plate matches the rest of the interface and the target
-- grows only by the Target scale set here. With "keep distance scaling" on,
-- the game's scaling stays on top.
local function Factor(plate)
	local parent = plate:GetParent()
	if plate.preview or not parent or parent == UIParent then return 1 end
	local ui = UIParent:GetEffectiveScale()
	local base
	if DB().keepDistance then
		base = Plain(WorldFrame.GetEffectiveScale, WorldFrame)
	else
		base = Plain(parent.GetEffectiveScale, parent)
	end
	if type(base) ~= 'number' or base <= 0 then return 1 end
	return ui / base
end

local function ApplyScale(plate)
	local scale = max((plate.mult or 1) * Factor(plate), 0.01)
	local current = Plain(plate.GetScale, plate)
	if not current or math.abs(current - scale) > 0.002 then plate:SetScale(scale) end
end

local function SetScaleTo(plate, scale, animate)
	local from = plate.mult or scale
	local function Step(value)
		plate.mult = value
		ApplyScale(plate)
	end
	if not animate or Kit:DB().reduceMotion then
		Kit:Animate(plate.scaleKey, 0, from, scale, Step)
		return
	end
	Kit:Animate(plate.scaleKey, Kit:Speed('FAST'), from, scale, Step, nil, 'cubic')
end

-- The game eases its plates' scale (targeting, distance): follow it while
-- plates are up, ten times a second.
local scaleDriver = CreateFrame('Frame')
local scaleElapsed, lastOver = 0, nil
scaleDriver:SetScript('OnUpdate', function(_, elapsed)
	scaleElapsed = scaleElapsed + elapsed
	if scaleElapsed < 0.1 then return end
	scaleElapsed = 0
	for _, plate in pairs(byUnit) do
		if plate.mult and plate:IsShown() then ApplyScale(plate) end
	end
	-- Opening on mouseover: follow the plate under the mouse.
	if DB().expandMouseover then
		local over = UnitPlate('mouseover')
		if over ~= lastOver then
			lastOver = over
			for _, plate in pairs(byUnit) do
				if plate.state == 'compact' or plate.state == 'full' then
					if State(plate) ~= plate.state and module.UpdateTarget then UI:Safe(module.UpdateTarget, plate, true) end
				end
			end
		end
	end
end)

local function PlateOf(unit)
	if not C_NamePlate or not C_NamePlate.GetNamePlateForUnit then return nil end
	local ok, nameplate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
	return ok and nameplate or nil
end

local function BaseScale(plate)
	local db = DB()
	if plate.preview then return 1 end
	return (db.scale or 1) * (plate.elite and (db.eliteScale or 1) or 1) * (plate.minion and (db.minionScale or 1) or 1)
end

-- Target brackets: four corner marks in the lamp color, 1 physical pixel thick,
-- that close in on the plate when it becomes the target and open out as it
-- stops being one.
local BRACKET_ARM, BRACKET_GAP, BRACKET_TRAVEL = 7, 4, 7

function BuildBrackets(plate)
	local frame = CreateFrame('Frame', nil, plate)
	frame:SetFrameLevel(plate:GetFrameLevel() + 8)
	frame:EnableMouse(false)
	frame:Hide()
	frame.corners = {}
	for _, corner in ipairs({'TOPLEFT', 'TOPRIGHT', 'BOTTOMLEFT', 'BOTTOMRIGHT'}) do
		local h = frame:CreateTexture(nil, 'OVERLAY', nil, 7)
		local v = frame:CreateTexture(nil, 'OVERLAY', nil, 7)
		for _, line in ipairs({h, v}) do
			line:SetColorTexture(1, 1, 1, 1)
			Kit:Tint(line, 'lamp')
			line:SetPoint(corner)
		end
		frame.corners[corner] = {h, v}
	end
	frame.spread = BRACKET_TRAVEL
	plate.brackets = frame
	return frame
end

local function PlaceBrackets(plate, spread)
	local frame = plate.brackets
	frame.spread = spread
	local pad = BRACKET_GAP + spread
	frame:ClearAllPoints()
	frame:SetPoint('TOPLEFT', plate, 'TOPLEFT', -pad, pad)
	frame:SetPoint('BOTTOMRIGHT', plate, 'BOTTOMRIGHT', pad, -pad)
	local px = UI.Pixel and UI.Pixel.Px(frame, 1) or 1
	for _, lines in pairs(frame.corners) do
		lines[1]:SetSize(BRACKET_ARM, px)
		lines[2]:SetSize(px, BRACKET_ARM)
	end
end

local function ShowBrackets(plate, on, animate)
	local frame = plate.brackets
	if not frame then return end
	local key = frame
	if on then
		local instant = not animate or Kit:DB().reduceMotion
		if not frame:IsShown() then
			PlaceBrackets(plate, instant and 0 or BRACKET_TRAVEL)
			frame:SetAlpha(instant and 1 or 0)
			frame:Show()
		end
		-- Living lamps: a slow breathe once the brackets have settled at full alpha.
		local function Settle()
			if not Kit.Breathe then return end
			if Kit.Alive and Kit:Alive('livingLamps') and not Kit:DB().reduceMotion then
				Kit:Breathe(frame, true, {period = 2.4, low = 0.55})
			else
				Kit:Breathe(frame, false)
			end
		end
		if Kit.Breathe then Kit:Breathe(frame, false) end
		if instant then
			PlaceBrackets(plate, 0)
			frame:SetAlpha(1)
			Settle()
		else
			local from, alpha = frame.spread, frame:GetAlpha()
			Kit:Animate(key, Kit:Speed('NORMAL'), 0, 1, function(t)
				local e = Kit.ease.cubic(t)
				PlaceBrackets(plate, from * (1 - e))
				frame:SetAlpha(alpha + (1 - alpha) * Kit.ease.sine(t))
			end, Settle, 'linear')
		end
	elseif frame:IsShown() then
		if Kit.Breathe then Kit:Breathe(frame, false) end
		if not animate or Kit:DB().reduceMotion then
			frame:Hide()
			return
		end
		local from, alpha = frame.spread, frame:GetAlpha()
		Kit:Animate(key, Kit:Speed('FAST'), 0, 1, function(t)
			PlaceBrackets(plate, from + (BRACKET_TRAVEL - from) * Kit.ease.cubic(t))
			frame:SetAlpha(alpha * (1 - Kit.ease.sine(t)))
		end, function() frame:Hide() end, 'linear')
	end
end

local function UpdateTarget(plate, animate)
	local db = DB()
	local target = plate.preview or (plate.nameplate ~= nil and PlateOf('target') == plate.nameplate)
	plate.isTarget = target
	-- Open into Full or fold to Compact when the plate's state changed.
	local state = State(plate)
	if state ~= plate.state then Morph(plate, state, animate) end
	Lamp(plate.lamp, target)
	HeaderLamp(plate)
	local style = db.targetStyle or 'lamp'
	plate.ring:SetShown(target and style == 'glow' and not plate.nameOnly)
	for _, side in ipairs({plate.sideLeft, plate.sideRight}) do
		local on = target and style == 'sides'
		Kit:ShowLed(side, on)
		if on then Lamp(side, true) end
	end
	ShowBrackets(plate, target and style == 'brackets' and not plate.nameOnly, animate)
	SetScaleTo(plate, BaseScale(plate) * (target and (db.targetScale or 1) or 1), animate)
	-- Other plates step back while you have a target.
	local alpha = 1
	if not target and not plate.preview and PlateOf('target') then alpha = db.nonTargetAlpha or 1 end
	plate.wantAlpha = alpha
	Kit:FadeTo(plate, alpha, animate and 'FAST' or 0)
	QuestMotion(plate)
end
module.UpdateTarget = UpdateTarget

-- Your debuffs on the unit. Aura fields may be secret: only the data table is
-- tested, the icon and count go straight to the client.
local FILTERS = {mine = 'HARMFUL|PLAYER', all = 'HARMFUL', important = 'HARMFUL|INCLUDE_NAME_PLATE_ONLY', boss = 'HARMFUL'}

local function AuraCount(unit, data)
	local count = data.applications
	if IsSecret(count) then
		if C_UnitAuras.GetAuraApplicationDisplayCount and not IsSecret(data.auraInstanceID) then
			return C_UnitAuras.GetAuraApplicationDisplayCount(unit, data.auraInstanceID, 2, 99)
		end
		return ''
	end
	return count and count > 1 and count or ''
end

local function AuraTimer(icon, unit, data)
	local cooldown = icon.cooldown
	local id = data.auraInstanceID
	if C_UnitAuras.GetAuraDuration and cooldown.SetCooldownFromDurationObject and not IsSecret(id) then
		local ok, duration = pcall(C_UnitAuras.GetAuraDuration, unit, id)
		if ok and duration then
			cooldown:SetCooldownFromDurationObject(duration)
			return
		end
	end
	local expires, length = data.expirationTime, data.duration
	if IsSecret(expires) or IsSecret(length) or not expires or not length or length <= 0 then cooldown:Clear() return end
	cooldown:SetCooldown(expires - length, length)
end

local function UpdateAuras(plate)
	local db, auras = DB(), plate.auras
	local count = min(db.auraCount or 5, AURA_MAX)
	local slot = 1
	if db.debuffs and not plate.nameOnly and C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
		local filter = FILTERS[db.auraFilter] or FILTERS.mine
		-- Boss auras are looked for among the first 16 only.
		for index = 1, db.auraFilter == 'boss' and 16 or 40 do
			if slot > count then break end
			local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, plate.unit, index, filter)
			if not ok or type(data) ~= 'table' then break end
			-- Boss auras only: a secret answer counts as no.
			local boss = data.isBossAura
			if db.auraFilter ~= 'boss' or (not IsSecret(boss) and boss) then
				local icon = auras[slot]
				icon.texture:SetTexture(data.icon)
				local countOk, stack = pcall(AuraCount, plate.unit, data)
				if countOk then icon.count:SetText(stack) else icon.count:SetText('') end
				if not pcall(AuraTimer, icon, plate.unit, data) then icon.cooldown:Clear() end
				icon:Show()
				slot = slot + 1
			end
		end
	end
	for index = slot, AURA_MAX do auras[index]:Hide() end
end

-- Friendly or enemy, and whether the plate is just a name.
local function SetMode(plate)
	local unit = plate.unit
	local friend = Plain(UnitIsFriend, 'player', unit)
	if friend == nil then friend = Plain(UnitCanAttack, 'player', unit) == false end
	plate.friendly = friend and true or false
	plate.nameOnly = plate.friendly and DB().friendlyNameOnly and true or false
	plate.minion = Plain(UnitIsMinion, unit) == true
end

-- Cast bar ------------------------------------------------------------------------------
-- Asked through duration objects, which are never secret; names and flags may
-- be, so they are never tested.
local function Casting(unit)
	if UnitCastingDuration then
		local duration = UnitCastingDuration(unit)
		if duration then return duration, false, false end
		if UnitEmpoweredChannelDuration then
			duration = UnitEmpoweredChannelDuration(unit, true)
			if duration then return duration, true, true end
		end
		if UnitChannelDuration then
			duration = UnitChannelDuration(unit)
			if duration then return duration, true, false end
		end
		return nil
	end
	if UnitCastingInfo(unit) ~= nil then return true, false, false end
	if UnitChannelInfo(unit) ~= nil then return true, true, false end
	return nil
end

-- The locked color when the cast can't be interrupted, the cast color when it
-- can. The flag may be secret: then the client picks the color from it, untested.
local colors
local function CastColors()
	if colors then return colors end
	local db = DB()
	local lr, lg, lb = RGB(db.castLockedColor)
	local cr, cg, cb = RGB(db.castColor)
	if not lr then lr, lg, lb = 0.55, 0.55, 0.52 end
	if not cr then cr, cg, cb = Kit:RGB('amber') end
	colors = {locked = {lr, lg, lb}, open = {cr, cg, cb}}
	if CreateColor then colors.lockedColor, colors.openColor = CreateColor(lr, lg, lb, 1), CreateColor(cr, cg, cb, 1) end
	return colors
end

local function PaintCast(cast, notInterruptible)
	local fill = cast.bar:GetStatusBarTexture()
	local palette = CastColors()
	cast.gray:SetAlpha(0)
	cast.gray:SetVertexColor(palette.locked[1], palette.locked[2], palette.locked[3])
	if IsSecret(notInterruptible) then
		if fill.SetVertexColorFromBoolean and palette.lockedColor then
			if pcall(fill.SetVertexColorFromBoolean, fill, notInterruptible, palette.lockedColor, palette.openColor) then return end
		end
		cast.bar:SetStatusBarColor(unpack(palette.open))
		-- Or a locked-color cover over the fill, shown by the client from the flag.
		if cast.gray.SetAlphaFromBoolean then pcall(cast.gray.SetAlphaFromBoolean, cast.gray, notInterruptible, 1, 0) end
		return
	end
	cast.bar:SetStatusBarColor(unpack(notInterruptible and palette.locked or palette.open))
end

-- The spell's name, and who it's aimed at when the client says.
local function CastLabel(cast, unit, name)
	if not DB().castTarget or not UnitSpellTargetName then return cast.label:SetText(name) end
	local ok, target = pcall(UnitSpellTargetName, unit)
	if ok and (IsSecret(target) or (type(target) == 'string' and target ~= '')) then
		if pcall(cast.label.SetFormattedText, cast.label, '%s > %s', name, target) then return end
	end
	cast.label:SetText(name)
end

local function CastStart(plate)
	local cast, unit = plate.cast, plate.unit
	if not DB().castbar then return false end
	local duration, channel, empowering = Casting(unit)
	if not duration then return false end
	local name, texture, notInterruptible
	if channel then name, _, texture, _, _, _, notInterruptible = UnitChannelInfo(unit)
	else name, _, texture, _, _, _, _, notInterruptible = UnitCastingInfo(unit) end
	CastLabel(cast, unit, name)
	cast.icon:SetTexture(texture)
	PaintCast(cast, notInterruptible)
	if duration ~= true and cast.bar.SetTimerDuration and TIMER then
		cast.bar:SetTimerDuration(duration, IMMEDIATE, (channel and not empowering) and TIMER.RemainingTime or TIMER.ElapsedTime)
		cast:SetScript('OnUpdate', nil)
	else
		local _, _, _, startTime, endTime = (channel and UnitChannelInfo or UnitCastingInfo)(unit)
		if IsSecret(startTime) or IsSecret(endTime) or not startTime or not endTime then return false end
		cast.bar:SetMinMaxValues(startTime / 1000, endTime / 1000)
		cast:SetScript('OnUpdate', function()
			local now = GetTime()
			cast.bar:SetValue(channel and (endTime / 1000 - (now - startTime / 1000)) or now)
		end)
	end
	cast.stopping = nil
	cast:Show()
	Kit:FadeTo(cast, 1, 'FAST')
	return true
end

local function CastStop(plate, failed)
	local cast = plate.cast
	if cast.stopping or not cast:IsShown() then return end
	cast.stopping = true
	cast:SetScript('OnUpdate', nil)
	local function Out()
		if cast.stopping then Kit:FadeTo(cast, 0, 'FAST', function() if cast.stopping then cast:Hide() end end) end
	end
	if failed then
		cast.gray:SetAlpha(0)
		cast.bar:SetStatusBarColor(Kit:RGB('red'))
		cast.label:SetText(failed)
		C_Timer.After(0.4, Out)
	else
		Out()
	end
end

local function CastRefresh(plate)
	local ok, started = pcall(CastStart, plate)
	if not (ok and started) then CastStop(plate) end
end

local function CastClear(plate)
	local cast = plate.cast
	cast.stopping = nil
	cast:SetScript('OnUpdate', nil)
	Kit:Animate(cast, 0, 0, 0, function() end)
	cast:SetAlpha(0)
	cast:Hide()
end

-- Events ----------------------------------------------------------------------------------
local CAST_EVENTS = {'UNIT_SPELLCAST_START', 'UNIT_SPELLCAST_STOP', 'UNIT_SPELLCAST_FAILED', 'UNIT_SPELLCAST_INTERRUPTED',
	'UNIT_SPELLCAST_DELAYED', 'UNIT_SPELLCAST_CHANNEL_START', 'UNIT_SPELLCAST_CHANNEL_STOP', 'UNIT_SPELLCAST_CHANNEL_UPDATE',
	'UNIT_SPELLCAST_EMPOWER_START', 'UNIT_SPELLCAST_EMPOWER_STOP', 'UNIT_SPELLCAST_EMPOWER_UPDATE',
	'UNIT_SPELLCAST_INTERRUPTIBLE', 'UNIT_SPELLCAST_NOT_INTERRUPTIBLE'}
local UNIT_EVENTS = {'UNIT_HEALTH', 'UNIT_MAXHEALTH', 'UNIT_NAME_UPDATE', 'UNIT_LEVEL', 'UNIT_FACTION', 'UNIT_FLAGS',
	'UNIT_CLASSIFICATION_CHANGED', 'UNIT_THREAT_LIST_UPDATE', 'UNIT_THREAT_SITUATION_UPDATE', 'UNIT_AURA'}

local function Reflag(plate)
	local was = plate.nameOnly
	SetMode(plate)
	if was ~= plate.nameOnly then
		Layout(plate)
		UpdateTarget(plate, false)
		UpdateQuest(plate)
		UpdateAuras(plate)
	end
	UpdateColor(plate)
end

local HANDLERS = {
	UNIT_HEALTH = UpdateHealth, UNIT_MAXHEALTH = UpdateHealth,
	UNIT_NAME_UPDATE = function(plate) UpdateName(plate); UpdateQuest(plate) end,
	UNIT_LEVEL = UpdateName, UNIT_CLASSIFICATION_CHANGED = UpdateName,
	UNIT_FACTION = Reflag, UNIT_FLAGS = UpdateColor,
	UNIT_THREAT_LIST_UPDATE = UpdateThreat, UNIT_THREAT_SITUATION_UPDATE = UpdateThreat,
	UNIT_AURA = UpdateAuras,
}

local function OnEvent(events, event, _, info)
	local plate = events:GetParent()
	if not plate.unit then return end
	if event == 'UNIT_AURA' and AuraUpdateEmpty(info) then return end
	local handler = HANDLERS[event]
	if handler then return UI:Safe(handler, plate) end
	if event == 'UNIT_SPELLCAST_INTERRUPTED' or event == 'UNIT_SPELLCAST_FAILED' then
		-- A rejected key press mid-cast also fires FAILED: stop only if nothing is cast.
		local ok, casting = pcall(Casting, plate.unit)
		if ok and casting then CastRefresh(plate)
		else CastStop(plate, event == 'UNIT_SPELLCAST_INTERRUPTED' and 'INTERRUPTED' or nil) end
	else
		CastRefresh(plate)
	end
end

local function Listen(plate, unit)
	local events = plate.events
	events:UnregisterAllEvents()
	for _, event in ipairs(UNIT_EVENTS) do pcall(events.RegisterUnitEvent, events, event, unit) end
	for _, event in ipairs(CAST_EVENTS) do pcall(events.RegisterUnitEvent, events, event, unit) end
	events:SetScript('OnEvent', OnEvent)
end

-- The game's frame ------------------------------------------------------------------------
-- The game's frame stays on its plate (moving the whole frame away breaks
-- picking a target between overlapping plates), held invisible, with its
-- events stopped and its children parked on a hidden frame: its auras, health
-- and cast bar, whose mouse-enabled pieces would otherwise catch tooltips and
-- clicks above every plate. Its widgets (quest progress) and soft target icon
-- move onto the plate itself and keep working.
--
-- Events the game's frame registers when it is made; a frame given back gets
-- them again (its unit events come back with its next unit).
local LOAD_EVENTS = {'VARIABLES_LOADED', 'CVAR_UPDATE', 'PLAYER_ENTERING_WORLD', 'PLAYER_TARGET_CHANGED',
	'PLAYER_SOFT_FRIEND_CHANGED', 'PLAYER_SOFT_ENEMY_CHANGED', 'UPDATE_MOUSEOVER_UNIT', 'PLAYER_LEVEL_UP', 'PLAYER_ROLES_ASSIGNED',
	'UNIT_ENTERED_VEHICLE', 'UNIT_EXITED_VEHICLE', 'GROUP_JOINED', 'GROUP_LEFT'}
-- The soft target icon runs on these.
local SOFT_EVENTS = {'PLAYER_TARGET_CHANGED', 'PLAYER_SOFT_FRIEND_CHANGED', 'PLAYER_SOFT_ENEMY_CHANGED'}

local owner = setmetatable({}, {__mode = 'k'}) -- game frame -> our plate holding it
local parked = setmetatable({}, {__mode = 'k'}) -- game frame -> set of its parked children
local hooked = setmetatable({}, {__mode = 'k'})

local function Protected(frame) return Plain(frame.IsProtected, frame) == true end

-- A protected frame is only moved out of combat.
local function Reparent(frame, parent)
	if frame:GetParent() == parent then return end
	if InCombatLockdown() and Protected(frame) then
		return UI:AfterCombat(function()
			if not Forbidden(frame) and frame:GetParent() ~= parent then frame:SetParent(parent) end
		end, 'nameplates.'..tostring(frame))
	end
	frame:SetParent(parent)
end

local function MoveKeepers(game, to)
	for _, keep in ipairs({game.WidgetContainer, game.SoftTargetFrame}) do
		if type(keep) == 'table' and keep.SetParent and not Forbidden(keep) then UI:Safe(Reparent, keep, to) end
	end
end

-- One click frame of ours per game plate, covering it, kept there for good.
local function OwnClicks(nameplate)
	if type(nameplate.SetAllHitTestPoints) ~= 'function' then return end
	local frame = clicks[nameplate]
	if not frame then
		frame = CreateFrame('Frame', nil, nameplate)
		frame:SetAllPoints(nameplate)
		frame:EnableMouse(false)
		clicks[nameplate] = frame
	end
	if nameplate.ClearAllHitTestPoints then pcall(nameplate.ClearAllHitTestPoints, nameplate) end
	pcall(nameplate.SetAllHitTestPoints, nameplate, frame)
end

-- The game sets its frame's alpha itself; while one of our plates holds the
-- frame, it goes straight back to 0. One hook per frame, for its lifetime.
local function HoldAlpha(game)
	if hooked[game] then return end
	hooked[game] = true
	local busy = false
	hooksecurefunc(game, 'SetAlpha', function(self)
		if busy or not owner[self] then return end
		busy = true
		self:SetAlpha(0)
		busy = false
	end)
end

local function HideGameFrame(nameplate, plate)
	local game = nameplate.UnitFrame
	if type(game) ~= 'table' or Forbidden(game) then return end
	plate.gameFrame = game
	owner[game] = plate
	HoldAlpha(game)
	game:SetAlpha(0)
	for _, piece in ipairs({game.selectionHighlight, game.behindCameraIcon}) do
		if type(piece) == 'table' and piece.SetAlpha and not Forbidden(piece) then piece:SetAlpha(0) end
	end
	local children = parked[game] or {}
	parked[game] = children
	for index = game:GetNumChildren(), 1, -1 do
		local child = (select(index, game:GetChildren()))
		if child and child ~= game.WidgetContainer and child ~= game.SoftTargetFrame and not Forbidden(child)
			and not Protected(child) and child:GetParent() ~= hidden then
			children[child] = true
			child:SetParent(hidden)
		end
	end
	pcall(game.UnregisterAllEvents, game)
	for _, event in ipairs(SOFT_EVENTS) do pcall(game.RegisterEvent, game, event) end
	local cast = game.castBar or (type(game.CastBarsContainer) == 'table' and game.CastBarsContainer.castBar)
	if type(cast) == 'table' and cast.UnregisterAllEvents and not Forbidden(cast) then pcall(cast.UnregisterAllEvents, cast) end
	MoveKeepers(game, nameplate)
	OwnClicks(nameplate)
end

-- The game hands a frame we held to a plate we don't cover: give it all back.
local function GiveBack(game)
	local children = parked[game]
	if not children or Forbidden(game) then return end
	parked[game], owner[game] = nil, nil
	for child in pairs(children) do
		if not Forbidden(child) and child:GetParent() == hidden then UI:Safe(Reparent, child, game) end
	end
	for _, event in ipairs(LOAD_EVENTS) do pcall(game.RegisterEvent, game, event) end
	MoveKeepers(game, game)
	for _, piece in ipairs({game.selectionHighlight, game.behindCameraIcon}) do
		if type(piece) == 'table' and piece.SetAlpha and not Forbidden(piece) then piece:SetAlpha(1) end
	end
	game:SetAlpha(1)
end

-- Plates ------------------------------------------------------------------------------------
-- After moving onto a game plate, set every layer's level again: each housing
-- just under what it holds.
local function Stack(plate)
	local level = plate:GetFrameLevel()
	plate.shell:SetFrameLevel(max(level - 1, 0))
	plate.track:SetFrameLevel(level + 1)
	plate.track.shell:SetFrameLevel(level)
	plate.health:SetFrameLevel(level + 2)
	local cast = plate.cast
	cast:SetFrameLevel(level + 1)
	cast.shell:SetFrameLevel(level)
	cast.track:SetFrameLevel(level + 2)
	cast.track.shell:SetFrameLevel(level + 1)
	cast.bar:SetFrameLevel(level + 3)
	for _, icon in ipairs(plate.auras) do
		icon:SetFrameLevel(level + 1)
		icon.shell:SetFrameLevel(level)
		icon.cooldown:SetFrameLevel(level + 2)
	end
end

local function Take()
	while #spare > 0 do
		local plate = table.remove(spare)
		if not Forbidden(plate) then return plate end
	end
	return Build()
end

local function Release(unit)
	local plate = byUnit[unit]
	if not plate then return end
	Tell('remove', plate, unit)
	byUnit[unit] = nil
	if plate.nameplate then onPlate[plate.nameplate] = nil end
	if plate.gameFrame and owner[plate.gameFrame] == plate then owner[plate.gameFrame] = nil end
	plate.unit, plate.nameplate, plate.gameFrame, plate.threatKey = nil, nil, nil, nil
	plate.state, plate.morphing = nil, nil
	plate.events:UnregisterAllEvents()
	CastClear(plate)
	Kit:Animate(plate, 0, 0, 0, function() end)
	plate:Hide()
	if Forbidden(plate) then return end
	plate:ClearAllPoints()
	plate:SetParent(home)
	spare[#spare + 1] = plate
end

local function NamePlateFor(unit)
	if not C_NamePlate or not C_NamePlate.GetNamePlateForUnit then return end
	local ok, nameplate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
	if ok and type(nameplate) == 'table' and not Forbidden(nameplate) then return nameplate end
end

-- Plates the game keeps as they are: your own (the personal resource display)
-- and those that show only widgets (a lootable corpse's sparkle).
local function GameKeeps(unit, nameplate)
	if PlateOf('player') == nameplate then return true end
	return Plain(UnitNameplateShowsWidgetsOnly, unit) == true
end

local function Added(unit)
	if IsSecret(unit) then return end
	if byUnit[unit] then Release(unit) end
	local nameplate = NamePlateFor(unit)
	if not nameplate or GameKeeps(unit, nameplate) then return end
	-- A plate whose removal never arrived is cleared first.
	local stale = onPlate[nameplate]
	if stale and stale.unit then Release(stale.unit) end
	local plate = Take()
	plate:SetParent(nameplate)
	plate:ClearAllPoints()
	plate:SetPoint('CENTER', nameplate, 'CENTER', 0, 0)
	Stack(plate)
	plate.unit, plate.nameplate = unit, nameplate
	byUnit[unit], onPlate[nameplate] = plate, plate
	SetMode(plate)
	Layout(plate)
	HideGameFrame(nameplate, plate)
	Listen(plate, unit)
	UI:Safe(UpdateName, plate)
	UI:Safe(UpdateThreat, plate)
	UI:Safe(UpdateColor, plate)
	UI:Safe(UpdateHealth, plate)
	UI:Safe(UpdateAuras, plate)
	UI:Safe(UpdateQuest, plate)
	UpdateTarget(plate, false)
	CastClear(plate)
	CastRefresh(plate)
	plate:SetAlpha(0)
	plate:Show()
	Kit:FadeTo(plate, plate.wantAlpha or 1, 'FAST')
	Tell('add', plate, unit)
end

-- Right after the game hands a plate its frame (it can do so after our own
-- handler ran): put it away under one of our plates, give it back elsewhere.
local function HandedOut(unit)
	if IsSecret(unit) then return end
	local plate = byUnit[unit]
	local nameplate = plate and plate.nameplate or NamePlateFor(unit)
	if not nameplate then return end
	local game = nameplate.UnitFrame
	if type(game) ~= 'table' or Forbidden(game) then return end
	if plate then HideGameFrame(nameplate, plate)
	elseif parked[game] then GiveBack(game) end
end

-- The game redoes every plate's frame on these; put them away again.
local RECLAIM = {DISPLAY_SIZE_CHANGED = true, VARIABLES_LOADED = true, CVAR_UPDATE = true}
local function Reclaim()
	for _, plate in pairs(byUnit) do
		if plate.nameplate then HideGameFrame(plate.nameplate, plate) end
	end
end

-- The game stacks and hit-tests plates at their own size: make it ours.
local function ApplySize()
	if not C_NamePlate then return end
	UI:AfterCombat(function()
		local db = DB()
		-- In the game plate's own units: our plate's screen size divided by
		-- the game's plate scale (taken at the world's scale and the global CVar).
		local world = Plain(WorldFrame.GetEffectiveScale, WorldFrame) or 1
		local getCVar = (C_CVar and C_CVar.GetCVar) or GetCVar
		local global = tonumber(getCVar and Plain(getCVar, 'nameplateGlobalScale') or nil) or 1
		local ratio = UIParent:GetEffectiveScale() / max(world * global, 0.01)
		local width = (db.width or 132) * (db.scale or 1) * ratio
		local height = (max(3, db.targetHeight or 5) + 21) * (db.scale or 1) * ratio
		if C_NamePlate.SetNamePlateSize then
			pcall(C_NamePlate.SetNamePlateSize, width, height)
		else
			if C_NamePlate.SetNamePlateEnemySize then pcall(C_NamePlate.SetNamePlateEnemySize, width, height) end
			if C_NamePlate.SetNamePlateFriendlySize then pcall(C_NamePlate.SetNamePlateFriendlySize, width, height) end
		end
	end, 'nameplates.size')
end

-- The game's plate settings ------------------------------------------------------------------
-- Stacking and distance are the game's own settings. The first value seen is
-- kept, and put back when the setting returns to the game's or the plates are
-- turned off.
local function ReadCVar(name)
	if C_CVar and C_CVar.GetCVar then return Plain(C_CVar.GetCVar, name) end
	return Plain(GetCVar, name)
end

local function WriteCVar(name, value)
	if C_CVar and C_CVar.SetCVar then return pcall(C_CVar.SetCVar, name, value) end
	if SetCVar then return pcall(SetCVar, name, value) end
end

local function Remember(name)
	local saved = DB().savedCVars
	if saved[name] == nil then
		local value = ReadCVar(name)
		if value ~= nil then saved[name] = value end
	end
end

local function Restore(name)
	local saved = DB().savedCVars
	if saved[name] ~= nil then
		WriteCVar(name, saved[name])
		saved[name] = nil
	end
end

local STACK_CVAR = 'nameplateStackingTypes'
local function ApplyCVars()
	UI:AfterCombat(function()
		local db = DB()
		if db.stacking == 'game' or not db.stacking then
			Restore(STACK_CVAR)
			Restore('nameplateMotion')
		else
			local stack = db.stacking == 'stack'
			local kinds = Enum and Enum.NamePlateStackType
			if kinds and C_CVar and C_CVar.SetCVarBitfield and ReadCVar(STACK_CVAR) ~= nil then
				Remember(STACK_CVAR)
				pcall(C_CVar.SetCVarBitfield, STACK_CVAR, kinds.Enemy, stack)
			elseif ReadCVar('nameplateMotion') ~= nil then
				Remember('nameplateMotion')
				WriteCVar('nameplateMotion', stack and '1' or '0')
			end
		end
		if (db.maxDistance or 0) > 0 then
			Remember('nameplateMaxDistance')
			WriteCVar('nameplateMaxDistance', tostring(db.maxDistance))
		else
			Restore('nameplateMaxDistance')
		end
	end, 'nameplates.cvars')
end

-- Plates turned off: everything we changed goes back.
local restorer = CreateFrame('Frame')
restorer:RegisterEvent('PLAYER_LOGIN')
restorer:SetScript('OnEvent', function()
	if UI:ModuleEnabled('nameplates') then return end
	UI:AfterCombat(function()
		for name in pairs(DB().savedCVars) do Restore(name) end
	end, 'nameplates.restore')
end)

function module:Enable()
	for _ = 1, 20 do spare[#spare + 1] = Build() end
	local driver = CreateFrame('Frame')
	driver:RegisterEvent('NAME_PLATE_UNIT_ADDED')
	driver:RegisterEvent('NAME_PLATE_UNIT_REMOVED')
	driver:RegisterEvent('PLAYER_TARGET_CHANGED')
	pcall(driver.RegisterEvent, driver, 'PLAYER_FOCUS_CHANGED')
	driver:RegisterEvent('PLAYER_ENTERING_WORLD')
	driver:RegisterEvent('DISPLAY_SIZE_CHANGED')
	driver:RegisterEvent('QUEST_LOG_UPDATE')
	pcall(driver.RegisterEvent, driver, 'PLAYER_SPECIALIZATION_CHANGED')
	local questQueued
	driver:SetScript('OnEvent', function(_, event, unit)
		if event == 'NAME_PLATE_UNIT_ADDED' then
			UI:Safe(Added, unit)
			-- Once more a frame later, after the game has finished with its plate.
			C_Timer.After(0, function() if byUnit[unit] then UI:Safe(HandedOut, unit) end end)
		elseif event == 'NAME_PLATE_UNIT_REMOVED' then
			if not IsSecret(unit) then UI:Safe(Release, unit) end
		elseif event == 'PLAYER_TARGET_CHANGED' or event == 'PLAYER_FOCUS_CHANGED' then
			for _, plate in pairs(byUnit) do UI:Safe(UpdateTarget, plate, true) end
		elseif event == 'QUEST_LOG_UPDATE' then
			-- The quest log updates in bursts; look once they settle.
			if questQueued then return end
			questQueued = true
			C_Timer.After(0.3, function()
				questQueued = nil
				for _, plate in pairs(byUnit) do UI:Safe(UpdateQuest, plate) end
			end)
		elseif event == 'PLAYER_SPECIALIZATION_CHANGED' then
			for _, plate in pairs(byUnit) do UI:Safe(UpdateThreat, plate) end
		else
			ApplySize()
		end
	end)
	-- A script post-hook on the game's plate driver, not a hook on its methods.
	local game = _G.NamePlateDriverFrame
	if type(game) == 'table' and game.HookScript and not Forbidden(game) then
		game:HookScript('OnEvent', function(_, event, unit)
			if event == 'NAME_PLATE_UNIT_ADDED' then UI:Safe(HandedOut, unit)
			elseif RECLAIM[event] then UI:Safe(Reclaim) end
		end)
	end
	ApplySize()
	ApplyCVars()
	-- Plates already up (a /reload with mobs around).
	if C_NamePlate and C_NamePlate.GetNamePlates then
		local ok, plates = pcall(C_NamePlate.GetNamePlates)
		if ok and type(plates) == 'table' then
			for _, nameplate in ipairs(plates) do
				local unit = not Forbidden(nameplate) and nameplate.namePlateUnitToken
				if type(unit) == 'string' then UI:Safe(Added, unit) end
			end
		end
	end
end

-- The sample plate --------------------------------------------------------------------------
-- A plate that follows every setting, filled with made-up values.
local SAMPLE_AURAS = {[[Interface\Icons\Spell_Shadow_ShadowWordPain]], [[Interface\Icons\Spell_Fire_Immolation]],
	[[Interface\Icons\Spell_Nature_Slow]], [[Interface\Icons\Spell_Shadow_CurseOfTounges]], [[Interface\Icons\Ability_Rogue_Rupture]],
	[[Interface\Icons\Spell_Frost_FrostNova]], [[Interface\Icons\Spell_Holy_SealOfMight]], [[Interface\Icons\Ability_Warrior_Sunder]]}
local SAMPLE_TEXT = {percent = '62', current = '1.2m', both = '1.2m / 2.0m', deficit = '-760k', none = ''}

local function FillSample(plate)
	local db = DB()
	plate.friendly, plate.nameOnly, plate.elite = false, false, true
	Layout(plate)
	plate.name:SetText(Truncate('TRAINING DUMMY', db.nameLength))
	Kit:Tint(plate.name, 'darkInk')
	Kit:Tint(plate.chip.text, plate.chipInk or 'lcdInk')
	plate.chip.text:SetText('80+')
	plate.health:SetMinMaxValues(0, 1)
	plate.health:SetValue(0.62, IMMEDIATE)
	local r, g, b
	if db.threatColorBar then r, g, b = RGB(db.threatInsecure) end
	if not r then
		if not db.classColor or db.npcColor == 'accent' then r, g, b = Kit:RGB('lamp')
		else
			local color = FACTION_BAR_COLORS and FACTION_BAR_COLORS[2]
			if color then r, g, b = Soften(color.r, color.g, color.b) else r, g, b = Kit:RGB('lamp') end
		end
	end
	plate.health:SetStatusBarColor(r, g, b)
	local text = SAMPLE_TEXT[db.healthText or 'percent'] or ''
	plate.percent:SetText(text)
	plate.barText:SetText(text)
	if db.threat then
		Lamp(plate.threat, true, 'amber')
		local tr, tg, tb = RGB(db.threatInsecure)
		if tr then plate.threat:SetVertexColor(tr, tg, tb) end
	end
	plate.exec:SetAlpha(0)
	-- The sample is a quest unit, so every quest setting shows on it.
	plate.questOn = true
	local questShown = db.questMarker and (db.questStyle or 'glyph') ~= 'none'
	PlaceQuest(plate)
	PaintQuest(plate, false, '3/8')
	plate.quest:SetShown(questShown and true or false)
	NameRight(plate)
	if db.questName then
		local nr, ng, nb = RGB(db.questNameColor)
		if nr then plate.name:SetTextColor(nr, ng, nb) end
	end
	if db.questHealth then
		local hr, hg, hb = RGB(db.questHealthColor)
		if hr then plate.health:SetStatusBarColor(hr, hg, hb) end
	end
	for index, icon in ipairs(plate.auras) do
		local shown = db.debuffs and index <= min(db.auraCount or 5, AURA_MAX)
		icon.texture:SetTexture(SAMPLE_AURAS[index])
		icon.count:SetText(index == 1 and '3' or '')
		icon.cooldown:Clear()
		icon:SetShown(shown and true or false)
	end
	local cast = plate.cast
	cast:SetScript('OnUpdate', nil)
	if db.castbar then
		cast.stopping = nil
		cast.label:SetText(db.castTarget and 'SHADOW BOLT > YOU' or 'SHADOW BOLT')
		cast.icon:SetTexture([[Interface\Icons\Spell_Shadow_ShadowBolt]])
		cast.bar:SetMinMaxValues(0, 1)
		cast.bar:SetValue(0.45)
		PaintCast(cast, false)
		cast:Show()
		cast:SetAlpha(1)
	else
		cast:Hide()
	end
	UpdateTarget(plate, false)
end

local function ShowSample(area)
	local card
	for _, child in ipairs({area.content:GetChildren()}) do
		local title = child.title and child.title.GetText and child.title:GetText()
		if type(title) == 'string' and strupper(title) == 'PREVIEW' then card = child break end
	end
	if not card then return end
	preview = preview or Build()
	preview.preview = true
	preview:SetParent(card.body)
	preview:ClearAllPoints()
	preview:SetPoint('CENTER', card.body, 'CENTER', 0, 4)
	Stack(preview)
	preview:Show()
	UI:Safe(FillSample, preview)
end

-- Settings apply to every plate at once, shown or spare.
function module:Refresh()
	colors = nil
	for _, plate in ipairs(spare) do UI:Safe(Layout, plate) end
	for _, plate in pairs(byUnit) do
		SetMode(plate)
		UI:Safe(Layout, plate)
		UI:Safe(UpdateName, plate)
		UI:Safe(UpdateThreat, plate)
		UI:Safe(UpdateColor, plate)
		UI:Safe(UpdateHealth, plate)
		UI:Safe(UpdateAuras, plate)
		UI:Safe(UpdateQuest, plate)
		UI:Safe(UpdateTarget, plate, false)
		if not DB().threat then Lamp(plate.threat, false) end
		if not DB().castbar then CastClear(plate) end
	end
	ApplySize()
	ApplyCVars()
end

-- The sample follows the page whether or not the plates are on.
-- The kit's repaint puts every text and lamp back to its token: name-only
-- colors and threat colors are painted again after it.
Kit:OnRefresh(function()
	colors = nil
	for _, plate in pairs(byUnit) do
		UI:Safe(UpdateColor, plate)
		UI:Safe(PaintThreat, plate)
		UI:Safe(UpdateQuest, plate)
	end
	if preview and preview:IsVisible() then UI:Safe(FillSample, preview) end
end)

local function Int(value) return format('%d', value + 0.5) end
local function Percent(value) return format('%d%%', value * 100 + 0.5) end
local function Get(key) return UI.db.nameplates[key] end

UI:RegisterPage('nameplates', {title = 'Nameplates', order = 15,
	onShow = function(area) ShowSample(area) end,
	onHide = function() if preview then preview:Hide() end end,
	cards = {
	{title = 'Preview', rows = {
		{'note', 'A sample plate that follows every setting on this page.\n \n \n \n \n \n \n '},
	}},
	{title = 'Style', rows = {
		{'segmented', 'Style', 'style.nameplates', items = {{'dots', 'Dots'}, {'pill', 'Pill'}, {'bar', 'Bar'}, {'blizzard', 'Blizzard'}},
			reload = true, note = 'Each plate is a dark glass device: target lamp, level chip, name, health and a cast bar docked under it.'},
		{'slider', 'Width', 'nameplates.width', 96, 200, 4, 'Plate width.', format = Int},
		{'slider', 'Scale', 'nameplates.scale', 0.5, 1.5, 0.05, 'Plates follow the UI scale; this sizes them on top of it.', format = Percent},
		{'switch', 'Legends', 'nameplates.legends', 'LV before the level and HP before the health readout.', since = '0.5.2'},
	}},
	{title = 'Enemies', rows = {
		{'switch', 'Class and reaction colors', 'nameplates.classColor', 'Off: every plate lights in the key color.'},
		{'switch', 'Enemy players in class colors', 'nameplates.enemyPlayerClassColor'},
		{'segmented', 'Creatures', 'nameplates.npcColor', items = {{'reaction', 'Reaction'}, {'accent', 'Key color'}},
			note = 'Red, yellow or green by how they feel about you, or the key color.'},
		{'switch', 'Level chip', 'nameplates.level', 'The level on a small LCD; + elite, * rare, ?? boss.'},
	}},
	{title = 'Quest units', rows = {
		{'switch', 'Quest marker', 'nameplates.questMarker', 'A mark beside units your quests need.'},
		{'dropdown', 'Marker', 'nameplates.questStyle', items = {{'glyph', 'Quest glyph'}, {'led', 'Lamp'}, {'chip', 'Q chip'},
			{'progress', 'Progress LCD'}, {'exclamation', 'Exclamation'}, {'none', 'None'}},
			note = 'Progress shows the objective count (3/8) on an LCD when the game shares it; otherwise the glyph. Quest bosses show in red.',
			disabled = function() return not Get('questMarker') end, since = '0.5.2'},
		{'segmented', 'Position', 'nameplates.questPosition', items = {{'right', 'Right'}, {'left', 'Left'}, {'above', 'Above'},
			{'header', 'Header'}}, disabled = function() return not Get('questMarker') end, since = '0.5.2'},
		{'slider', 'Size', 'nameplates.questSize', 8, 20, 1, nil, format = Int, since = '0.5.2'},
		{'segmented', 'Color', 'nameplates.questColor', items = {{'amber', 'Amber'}, {'key', 'Key color'}, {'custom', 'Custom'}},
			since = '0.5.2'},
		{'color', 'Marker color', 'nameplates.questCustomColor', hidden = function() return Get('questColor') ~= 'custom' end,
			since = '0.5.2'},
		{'switch', 'Blink on target', 'nameplates.questBlink', 'The mark blinks while the quest unit is your target.', since = '0.5.2'},
		{'switch', 'Breathe', 'nameplates.questBreathe', 'The mark slowly breathes on every quest unit.', since = '0.5.2'},
		{'switch', 'Header lamp', 'nameplates.questLamp', 'The plate\'s header lamp glows amber on quest units you haven\'t targeted.',
			since = '0.5.2'},
		{'switch', 'Color the meter', 'nameplates.questHealth', 'Quest units\' health in their own color.', since = '0.5.2'},
		{'color', 'Meter color', 'nameplates.questHealthColor', hidden = function() return not Get('questHealth') end, since = '0.5.2'},
		{'switch', 'Color the name', 'nameplates.questName', 'Quest units\' names in their own color.', since = '0.5.2'},
		{'color', 'Name color', 'nameplates.questNameColor', hidden = function() return not Get('questName') end, since = '0.5.2'},
	}},
	{title = 'Friends', rows = {
		{'switch', 'Name only', 'nameplates.friendlyNameOnly', 'Friendly plates are just the name, in its color.'},
		{'switch', 'Players in class colors', 'nameplates.friendlyClassColor'},
	}},
	{title = 'Name and health', rows = {
		{'segmented', 'Name', 'nameplates.namePosition', items = {{'header', 'Header'}, {'center', 'Centred'}, {'above', 'Above'}}},
		{'slider', 'Name size', 'nameplates.nameSize', 6, 14, 1, nil, format = Int},
		{'slider', 'Name length', 'nameplates.nameLength', 0, 30, 1, '0 keeps the whole name.',
			format = function(value) return value < 0.5 and 'All' or Int(value) end},
		{'dropdown', 'Health text', 'nameplates.healthText', items = {{'percent', 'Percent'}, {'current', 'Current'},
			{'both', 'Current / max'}, {'deficit', 'Missing'}, {'none', 'None'}}},
		{'segmented', 'Health text on', 'nameplates.healthTextPosition', items = {{'header', 'Header'}, {'bar', 'Meter'}},
			hidden = function() return Get('healthText') == 'none' end},
	}},
	{title = 'Auras', rows = {
		{'switch', 'Debuffs', 'nameplates.debuffs', 'Debuffs on the unit, above or below the plate.'},
		{'dropdown', 'Which', 'nameplates.auraFilter', items = {{'mine', 'Mine'}, {'all', 'All'}, {'important', 'Important'},
			{'boss', 'Boss'}}, note = 'Important: the ones the game marks for nameplates.', disabled = function() return not Get('debuffs') end},
		{'slider', 'Size', 'nameplates.auraSize', 12, 32, 1, nil, format = Int},
		{'slider', 'Most shown', 'nameplates.auraCount', 1, AURA_MAX, 1, nil, format = Int},
		{'segmented', 'Position', 'nameplates.auraPosition', items = {{'above', 'Above'}, {'below', 'Below'}}},
		{'switch', 'Time left', 'nameplates.auraTime', 'The client\'s countdown on each key.'},
	}},
	{title = 'Cast bar', rows = {
		{'switch', 'Cast bars', 'nameplates.castbar', 'Docked under each plate.'},
		{'slider', 'Height', 'nameplates.castHeight', 10, 30, 1, nil, format = Int, disabled = function() return not Get('castbar') end},
		{'switch', 'Icon', 'nameplates.castIcon', nil, disabled = function() return not Get('castbar') end},
		{'switch', 'Spell name', 'nameplates.castName', nil, disabled = function() return not Get('castbar') end},
		{'switch', 'Target', 'nameplates.castTarget', 'Who the spell is aimed at, after its name.',
			disabled = function() return not Get('castbar') or not Get('castName') end},
		{'color', 'Can be interrupted', 'nameplates.castColor'},
		{'color', 'Can\'t be interrupted', 'nameplates.castLockedColor'},
	}},
	{title = 'Threat', rows = {
		{'switch', 'Threat lamp', 'nameplates.threat', 'A lamp in the threat color on each plate.'},
		{'switch', 'Color the meter', 'nameplates.threatColorBar', 'The health meter takes the threat color too.'},
		{'segmented', 'Tank mode', 'nameplates.tankMode', items = {{'auto', 'By spec'}, {'on', 'On'}, {'off', 'Off'}},
			note = 'A tank wants aggro: holding it is the safe color, losing it the warning.'},
		{'color', 'Safe', 'nameplates.threatSecure'},
		{'color', 'Close', 'nameplates.threatInsecure'},
		{'color', 'Aggro', 'nameplates.threatAggro'},
	}},
	{title = 'Plate states', rows = {
		{'segmented', 'Other plates', 'nameplates.otherPlates', items = {{'compact', 'Compact'}, {'full', 'Full'}}, since = '0.5.2',
			note = 'Compact: plates you have not targeted are a slim name and meter, and open into the full device when targeted.'},
		{'slider', 'Compact width', 'nameplates.compactWidth', 0.4, 1, 0.05, nil, format = Percent, since = '0.5.2',
			hidden = function() return Get('otherPlates') == 'full' end},
		{'switch', 'Compact level', 'nameplates.compactLevel', 'A small level number before the name.', since = '0.5.2',
			hidden = function() return Get('otherPlates') == 'full' end},
		{'segmented', 'Compact meter', 'nameplates.compactMeter', items = {{'hairline', 'Hairline'}, {'dots', 'Dots'}}, since = '0.5.2',
			hidden = function() return Get('otherPlates') == 'full' end},
		{'segmented', 'Compact housing', 'nameplates.compactHousing', items = {{'none', 'None'}, {'glass', 'Faint glass'}}, since = '0.5.2',
			hidden = function() return Get('otherPlates') == 'full' end},
		{'switch', 'Open on mouseover', 'nameplates.expandMouseover', 'The plate under the mouse opens too.', since = '0.5.2'},
		{'switch', 'Open your focus', 'nameplates.expandFocus', nil, since = '0.5.2'},
	}},
	{title = 'Full plate', rows = {
		{'segmented', 'Housing', 'nameplates.housing', items = {{'glass', 'Glass'}, {'none', 'None'}}, since = '0.5.2',
			note = 'None: the header and meter on their own, without the dark housing.'},
		{'slider', 'Meter height', 'nameplates.targetHeight', 3, 10, 1, nil, format = Int, since = '0.5.2'},
		{'switch', 'Level inline', 'nameplates.levelInline', 'LV and the level printed in the header; off puts them on an LCD chip.', since = '0.5.2'},
	}},
	{title = 'Target', rows = {
		{'segmented', 'Look', 'nameplates.targetStyle', items = {{'lamp', 'Lamp'}, {'glow', 'Ring'}, {'sides', 'Side lamps'}, {'brackets', 'Brackets'}},
			note = 'The header lamp lights on every look.'},
		{'slider', 'Target scale', 'nameplates.targetScale', 1, 1.5, 0.01, 'Your target\'s plate grows by this much.', format = Percent},
		{'slider', 'Others while targeting', 'nameplates.nonTargetAlpha', 0.2, 1, 0.05, 'Opacity of the other plates.', format = Percent},
	}},
	{title = 'Execute range', rows = {
		{'switch', 'Execute range', 'nameplates.execute', 'A red wash over the meter under the percentage, and a hairline at it.'},
		{'slider', 'Below', 'nameplates.executePercent', 0.05, 0.5, 0.01, nil, format = Percent,
			disabled = function() return not Get('execute') end},
	}},
	{title = 'Scale', rows = {
		{'slider', 'Elites and bosses', 'nameplates.eliteScale', 0.6, 1.6, 0.05, nil, format = Percent},
		{'slider', 'Minions and pets', 'nameplates.minionScale', 0.5, 1.2, 0.05, nil, format = Percent},
		{'switch', 'Keep distance scaling', 'nameplates.keepDistance', 'Off: every plate is one size, whatever its distance, and the target grows only by Target scale. On: the game\'s own plate scaling stays on top.', since = '0.5.2'},
		{'button', 'Game plate scale', 'Reset', function()
			if InCombatLockdown() then return UI:Print('The game\'s plate scale can be reset once you leave combat.') end
			local setCVar = (C_CVar and C_CVar.SetCVar) or SetCVar
			for _, name in ipairs({'nameplateGlobalScale', 'nameplateSelectedScale', 'nameplateLargerScale'}) do
				if setCVar then pcall(setCVar, name, 1) end
			end
			Kit:Play('latch-up', true)
		end, 'Sets the game\'s own nameplate global, target and larger scale back to 100%.', since = '0.5.2'},
	}},
	{title = 'Game settings', rows = {
		{'segmented', 'Stacking', 'nameplates.stacking', items = {{'game', 'Game\'s'}, {'stack', 'Stack'}, {'overlap', 'Overlap'}},
			note = 'Set out of combat; Game\'s puts back what you had.'},
		{'slider', 'Distance', 'nameplates.maxDistance', 0, 60, 1, 'How far away plates show, in yards. 0 keeps the game\'s.',
			format = function(value) return value < 0.5 and 'Game' or Int(value) end},
	}},
}})
