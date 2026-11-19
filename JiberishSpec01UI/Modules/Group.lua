-- Raid, boss and arena frames as SPEC-01 devices.
--
-- Raid: two secure group headers, one for raids of up to 20 (and, as an
-- option, the party) and one for larger raids, chosen by a visibility driver.
-- Each member is a compact dark-glass key: name and status printed on it, a
-- health meter (dots, pill or bar, as the unit frames), an optional power
-- sliver, and indicators as lamps and badges: role, leader, raid marker, ready
-- check, summon, resurrection, phasing, a dispel ring in the debuff's type
-- colour, boss debuffs, your own heals over time, private auras, incoming heals
-- and absorbs, and a target outline.
-- Boss 1-5 and arena 1-5: medium devices with an LCD health readout, cast
-- strip, target lamp and your debuffs; arena adds the opponent's spec (also
-- before the gates open) and their trinket.
--
-- Everything that may be secret in 12.x is handed to setters untested: health
-- goes to StatusBars, range and target answers to SetAlphaFromBoolean, debuff
-- colours come from the client's colour curve, casts from duration objects.
-- The secure buttons are only sized and anchored out of combat; everything
-- drawn sits on our own child frames.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown, GetTime = CreateFrame, UIParent, InCombatLockdown, GetTime
local floor, max, min = math.floor, math.max, math.min

local module = UI:RegisterModule('group', {})

-- defaults:begin
UI:RegisterDefaults('group', {
	partyAsRaid = false, hideBlizzard = true,
	healthColor = 'class', customColor = {0.18, 0.62, 0.37}, -- 'class' | 'reaction' | 'accent' | 'custom' | 'gradient2'
	healthStart = {0.10, 0.45, 0.28}, healthEnd = {0.47, 0.88, 0.45}, healthDirection = 'horizontal',
	-- Fill looks, as on the unit frames: 'flat' | 'solid' | 'gloss' | 'gradient' | 'glass' | 'striped' | 'lsm:<name>';
	-- the track: 'default' (housing) | 'screen' | 'dim' | 'clear'.
	healthTexture = 'flat', powerTexture = 'flat', castTexture = 'flat', track = 'default',
	rangeFade = true, rangeAlpha = 0.45, healPrediction = true, absorbs = true,
	nameSize = 9, statusText = true,
	roleIcon = true, leader = true, raidIcon = true, readyCheck = true, summon = true, resurrect = true, phase = true,
	targetOutline = true, targetColor = {1, 1, 1},
	dispel = true, dispelOnly = true,
	dispelColors = {magic = {0.2, 0.6, 1}, curse = {0.6, 0, 1}, disease = {0.6, 0.4, 0}, poison = {0, 0.6, 0}, bleed = {0.8, 0.1, 0.1}},
	bossDebuffs = true, bossDebuffSize = 18, hots = true, hotCount = 3, hotSize = 10, privateAuras = true, privateSize = 16,
	-- Raids of up to 20 (and the party, with partyAsRaid), and raids of 21 to 40.
	small = {width = 88, height = 42, spacing = 4, columnSpacing = 4, growth = 'down_right', groupBy = 'GROUP',
		sortMethod = 'INDEX', unitsPerColumn = 5, maxColumns = 4, power = 'healers', healthText = 'none', scale = 1},
	large = {width = 72, height = 32, spacing = 3, columnSpacing = 3, growth = 'down_right', groupBy = 'GROUP',
		sortMethod = 'INDEX', unitsPerColumn = 5, maxColumns = 8, power = 'none', healthText = 'none', scale = 1},
	boss = {enable = true, width = 200, height = 46, spacing = 30, castbar = true, auras = true, growth = 'down', scale = 1},
	arena = {enable = true, width = 200, height = 46, spacing = 30, castbar = true, trinket = true, spec = true, auras = true,
		growth = 'down', scale = 1},
})
-- defaults:end

local function DB() return UI.db.group end
local IsSecret = UI.Util.IsSecret
-- A call's first result, or nil when it fails or the answer is secret.
local Plain = UI.Util.PlainCall
-- A value is there: a secret one always is, a plain one unless nil.
local function Has(value) return IsSecret(value) or value ~= nil end
local RGB, Forbidden = UI.Util.RGB, UI.Util.Forbidden

local SMOOTH = Enum and Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut
local IMMEDIATE = Enum and Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.Immediate
local TIMER = Enum and Enum.StatusBarTimerDirection
local STRETCHED = Enum and Enum.UITextureSliceMode and Enum.UITextureSliceMode.Stretched

-- The unit frames' housing style, so boss and arena frames match them.
local function HousingStyle()
	local style = UI:Style('unitframes')
	return (style == 'dark' or style == 'lcd') and style or 'paper'
end

-- Meters ----------------------------------------------------------------------------
local function MaskFill(bar, file, margin)
	local mask = bar:CreateMaskTexture()
	mask:SetTexture(Kit.media..file..'.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
	if mask.SetTextureSliceMargins then
		mask:SetTextureSliceMargins(margin, margin, margin, margin)
		if STRETCHED and mask.SetTextureSliceMode then mask:SetTextureSliceMode(STRETCHED) end
	end
	mask:SetAllPoints(bar)
	bar:GetStatusBarTexture():AddMaskTexture(mask)
	bar.fillMask = mask -- the fill looks share it
	if mask.SetScale then
		local function Fit(_, _, height)
			if IsSecret(height) or not height or height <= 0 then return end
			mask:SetScale(file == 'mask-pill' and height / (2 * margin) or 2 / margin)
		end
		bar:HookScript('OnSizeChanged', Fit)
		Fit(nil, nil, bar:GetHeight())
	end
end

-- A meter as the unit frames draw it: LED dots, the slider's pill or a flat bar.
local function Meter(parent, onDark)
	local style = UI.db.unitframes and UI.db.unitframes.barStyle or 'dots'
	local track = CreateFrame('Frame', nil, parent)
	local inset = style == 'bar' and 1 or 2
	track.inset = inset
	track.shell = Kit:Shell(track, {surface = (style == 'bar' or onDark) and 'glass' or 'lcd', radius = style == 'bar' and 2 or 99,
		shadow = false, fill = (style ~= 'bar' and not onDark) and 'track' or nil})
	local bar = CreateFrame('StatusBar', nil, track)
	bar:SetPoint('TOPLEFT', style == 'dots' and 3 or inset, -inset)
	bar:SetPoint('BOTTOMRIGHT', style == 'dots' and -3 or -inset, inset)
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(1)
	if style == 'dots' then
		bar:SetStatusBarTexture([[Interface\Buttons\WHITE8X8]])
		bar.coverToken = onDark and 'glass' or 'track'
		Kit:Perforate(bar, bar.coverToken, onDark and 'darkEdge' or nil)
	else
		bar:SetStatusBarTexture(Kit.media..'bar-flat.tga')
		MaskFill(bar, style == 'pill' and 'mask-pill' or 'mask-bar', style == 'pill' and 15 or 5)
	end
	bar.track, bar.style = track, style
	return bar
end

-- An overlay bar that continues from the end of another bar's fill (incoming
-- heals after health, absorbs after heals). Its position follows the client's
-- fill, so nothing is computed from the values here.
local function Overlay(after, health, token, alpha)
	local bar = CreateFrame('StatusBar', nil, health)
	bar:SetFrameLevel(health:GetFrameLevel() + 1)
	bar:SetPoint('TOPLEFT', after:GetStatusBarTexture(), 'TOPRIGHT')
	bar:SetPoint('BOTTOMLEFT', after:GetStatusBarTexture(), 'BOTTOMRIGHT')
	bar:SetStatusBarTexture(health.style == 'dots' and [[Interface\Buttons\WHITE8X8]] or Kit.media..'bar-flat.tga')
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)
	Kit:Tint(bar:GetStatusBarTexture(), token, alpha)
	local function Width() local width = health:GetWidth(); if not IsSecret(width) and width and width > 0 then bar:SetWidth(width) end end
	health:HookScript('OnSizeChanged', Width)
	Width()
	-- The run starts where the fill ends, so it is clipped at the bar's end.
	if health.SetClipsChildren then health:SetClipsChildren(true) end
	bar:Hide()
	return bar
end

-- Fill looks, shared with the unit frames (UI.BarLooks); without them the
-- meters keep their plain fill.
local function ApplyLooks(health, power, cast)
	local looks, db = UI.BarLooks, DB()
	if not looks then return end
	if health then looks.ApplyFill(health, db.healthTexture); looks.ApplyTrack(health, db.track) end
	if power then looks.ApplyFill(power, db.powerTexture); looks.ApplyTrack(power, db.track) end
	if cast then looks.ApplyFill(cast, db.castTexture); looks.ApplyTrack(cast, db.track) end
end

local function FillItems() return UI.BarLooks and UI.BarLooks.FillItems() or {{'flat', 'Flat'}} end
local TRACK_ITEMS = {{'default', 'Housing'}, {'screen', 'Black'}, {'dim', 'Dim fill'}, {'clear', 'None'}}

-- Colours --------------------------------------------------------------------------
local function ClassColor(unit)
	local ok, r, g, b = pcall(function()
		if UnitIsPlayer(unit) then
			local _, class = UnitClass(unit)
			local color = not IsSecret(class) and class and (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)[class]
			if color then return color.r, color.g, color.b end
		else
			local reaction = UnitReaction(unit, 'player')
			local color = not IsSecret(reaction) and reaction and FACTION_BAR_COLORS and FACTION_BAR_COLORS[reaction]
			if color then return color.r, color.g, color.b end
		end
	end)
	if ok and not IsSecret(r) and r then
		local gray = 0.299 * r + 0.587 * g + 0.114 * b
		return (r + (gray - r) * 0.15) * 0.95, (g + (gray - g) * 0.15) * 0.95, (b + (gray - b) * 0.15) * 0.95
	end
	return Kit:RGB('lamp')
end

local PowerColorOf -- the game's power colors, below

local function ReactionColor(unit)
	local ok, r, g, b = pcall(function()
		local reaction = UnitReaction(unit, 'player')
		local color = not IsSecret(reaction) and reaction and FACTION_BAR_COLORS and FACTION_BAR_COLORS[reaction]
		if color then return color.r, color.g, color.b end
	end)
	if ok and not IsSecret(r) and r then return r, g, b end
	return Kit:RGB('lamp')
end

local function HealthColor(unit)
	local mode = DB().healthColor
	-- A key color set to Class means each member's own class, not the player's.
	if mode == 'accent' and Kit:DB().accent ~= 'class' then return Kit:RGB('lamp') end
	if mode == 'custom' then return RGB(DB().customColor, 1) end
	if mode == 'reaction' then return ReactionColor(unit) end
	if mode == 'gradient2' then return RGB(DB().healthEnd, 1) end
	return ClassColor(unit)
end

-- Health on a meter: one color, or the two-color gradient set on the fill
-- texture itself (shared with the unit frames), never read from the value.
local function PaintHealth(bar, unit)
	local db, colors = DB(), UI.UnitColors
	if db.healthColor == 'gradient2' and colors and colors.FillGradient then
		colors.FillGradient(bar, db.healthDirection, db.healthStart, db.healthEnd)
	else
		bar:SetStatusBarColor(HealthColor(unit))
	end
end

-- Power and cast colors follow the unit frames' Colors card when it is there.
local function PaintPower(bar, unit)
	local colors = UI.UnitColors
	if colors and colors.PaintPower then return colors.PaintPower(bar, unit) end
	bar:SetStatusBarColor(PowerColorOf(unit))
end

local function CastColor(kind, fallback)
	local colors = UI.UnitColors
	if colors and colors.CastColor then return colors.CastColor(kind) end
	return Kit:RGB(fallback)
end

function PowerColorOf(unit)
	local ok, r, g, b = pcall(function()
		local _, token = UnitPowerType(unit)
		local color = token and PowerBarColor and PowerBarColor[token]
		if color then return color.r, color.g, color.b end
	end)
	if ok and not IsSecret(r) and r then return r, g, b end
	return 0.29, 0.64, 1
end

-- Debuff type colours, as the client's colour curve, so a secret dispel type
-- still colours the ring. Indexes are the client's dispel type numbers.
local DISPEL_INDEX = {magic = 1, curse = 2, disease = 3, poison = 4, bleed = 11}
local DISPEL_NAME = {Magic = 'magic', Curse = 'curse', Disease = 'disease', Poison = 'poison', Bleed = 'bleed'}
local dispelCurve
local function BuildDispelCurve()
	if not (C_CurveUtil and C_CurveUtil.CreateColorCurve and C_UnitAuras and C_UnitAuras.GetAuraDispelTypeColor and CreateColor) then
		dispelCurve = nil
		return
	end
	if not dispelCurve then
		dispelCurve = C_CurveUtil.CreateColorCurve()
		local step = Enum and Enum.LuaCurveType and Enum.LuaCurveType.Step
		if step and dispelCurve.SetType then dispelCurve:SetType(step) end
	elseif dispelCurve.ClearPoints then
		dispelCurve:ClearPoints()
	end
	-- No type: no ring.
	dispelCurve:AddPoint(0, CreateColor(0, 0, 0, 0))
	for key, index in pairs(DISPEL_INDEX) do
		local r, g, b = RGB(DB().dispelColors[key], 1)
		dispelCurve:AddPoint(index, CreateColor(r, g, b, 1))
	end
	dispelCurve:AddPoint(9, CreateColor(0, 0, 0, 0)) -- enrage
end

-- Shared pieces -----------------------------------------------------------------------
local function AuraIcon(parent, size, withCooldown)
	local icon = CreateFrame('Frame', nil, parent)
	icon:SetSize(size, size)
	icon.texture = icon:CreateTexture(nil, 'ARTWORK')
	icon.texture:SetAllPoints()
	icon.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	icon.mask = icon:CreateMaskTexture()
	icon.mask:SetTexture(Kit.media..'mask-icon.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
	icon.mask:SetAllPoints(icon.texture)
	icon.texture:AddMaskTexture(icon.mask)
	if withCooldown then
		icon.cooldown = CreateFrame('Cooldown', nil, icon, 'CooldownFrameTemplate')
		icon.cooldown:SetAllPoints(icon.texture)
		icon.cooldown:SetDrawEdge(false)
		if icon.cooldown.SetHideCountdownNumbers then icon.cooldown:SetHideCountdownNumbers(true) end
		if icon.cooldown.SetSwipeTexture then icon.cooldown:SetSwipeTexture(Kit.media..'mask-icon.tga', 0, 0, 0, 0.7) end
	end
	icon.count = Kit:Text(icon, '', 'tiny', 'white', true, true)
	icon.count:SetPoint('BOTTOMRIGHT', 2, -1)
	icon:Hide()
	return icon
end

-- Fills an aura icon from aura data. Secret fields go straight to setters.
local function ShowAura(icon, unit, data)
	icon.texture:SetTexture(data.icon)
	local count = data.applications
	if IsSecret(count) then
		if C_UnitAuras.GetAuraApplicationDisplayCount and not IsSecret(data.auraInstanceID) then
			icon.count:SetText(C_UnitAuras.GetAuraApplicationDisplayCount(unit, data.auraInstanceID, 2, 99))
		else
			icon.count:SetText('')
		end
	elseif count and count > 1 then
		icon.count:SetText(count)
	else
		icon.count:SetText('')
	end
	if icon.cooldown then
		local done
		if C_UnitAuras.GetAuraDuration and icon.cooldown.SetCooldownFromDurationObject then
			local ok, duration = pcall(C_UnitAuras.GetAuraDuration, unit, data.auraInstanceID)
			if ok and duration then
				icon.cooldown:SetCooldownFromDurationObject(duration)
				done = true
			end
		end
		if not done then
			local length, expires = data.duration, data.expirationTime
			if not IsSecret(length) and not IsSecret(expires) and length and expires and length > 0 then
				icon.cooldown:SetCooldown(expires - length, length)
			else
				icon.cooldown:Clear()
			end
		end
	end
	icon:Show()
end

local function AuraByIndex(unit, index, filter)
	if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return nil end
	local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, unit, index, filter)
	return ok and type(data) == 'table' and data or nil
end

-- Raid cells --------------------------------------------------------------------------
local ROLE_COORDS = {TANK = {0, 19 / 64, 22 / 64, 41 / 64}, HEALER = {20 / 64, 39 / 64, 1 / 64, 20 / 64},
	DAMAGER = {20 / 64, 39 / 64, 22 / 64, 41 / 64}}
local SUMMON_ATLAS = {'Raid-Icon-SummonPending', 'Raid-Icon-SummonAccepted', 'Raid-Icon-SummonDeclined'}
local cells = {} -- every styled raid cell (secure, from the headers)
local headers = {} -- profile key -> header

local function Badge(face, size, layer)
	local texture = face:CreateTexture(nil, 'OVERLAY', nil, layer or 3)
	texture:SetSize(size, size)
	texture:Hide()
	return texture
end

-- Builds everything a cell draws on its own child frame. Used for the secure
-- cells and for the placement previews.
local function BuildFace(cell, profile)
	local face = CreateFrame('Frame', nil, cell)
	face:SetAllPoints()
	face:EnableMouse(false)
	cell.face, cell.profile = face, profile
	cell.shell = Kit:Shell(face, {surface = 'glass', radius = 4, shadowAlpha = 0.25, group = 'unitframes'})

	cell.nameText = Kit:Text(face, '', DB().nameSize or 9, 'darkInk', true)
	cell.nameText:SetPoint('TOPLEFT', 6, -5)
	cell.nameText:SetPoint('TOPRIGHT', -26, -5)
	cell.nameText:SetJustifyH('LEFT')
	cell.nameText:SetWordWrap(false)
	cell.status = Kit:Text(face, '', 'tiny', 'darkDim', true)
	cell.status:SetPoint('TOPRIGHT', -5, -6)
	cell.status:SetJustifyH('RIGHT')

	cell.health = Meter(face, true)
	cell.power = Meter(face, true)
	cell.power.track:SetHeight(4)
	cell.power.track:SetPoint('BOTTOMLEFT', 4, 4)
	cell.power.track:SetPoint('BOTTOMRIGHT', -4, 4)

	ApplyLooks(cell.health, cell.power)
	cell.heals = Overlay(cell.health, cell.health, 'green', 0.55)
	cell.absorb = Overlay(cell.heals, cell.health, 'white', 0.35)

	cell.role = Badge(face, 10)
	cell.role:SetTexture([[Interface\LFGFrame\UI-LFG-ICON-PORTRAITROLES]])
	cell.role:SetPoint('BOTTOMRIGHT', cell.health.track, 'TOPRIGHT', 0, 2)
	cell.leader = Badge(face, 10, 4)
	cell.leader:SetTexture([[Interface\GroupFrame\UI-Group-LeaderIcon]])
	cell.leader:SetPoint('CENTER', face, 'TOPLEFT', 3, -2)
	cell.marker = Badge(face, 12, 4)
	cell.marker:SetTexture([[Interface\TargetingFrame\UI-RaidTargetingIcons]])
	cell.marker:SetPoint('CENTER', face, 'TOP', 0, -1)
	-- One centre badge: ready check, summon, resurrection or phasing.
	cell.center = Badge(face, 18, 6)
	cell.center:SetPoint('CENTER', 0, 2)

	cell.ring = Kit:Texture(face, 'ring-6', 'OVERLAY', 5)
	cell.ring:SetAllPoints()
	cell.ring:Hide()
	cell.outline = Kit:Texture(face, 'ring-6', 'OVERLAY', 6)
	Kit:Place(cell.outline, face, 1, 1, 1, 1)
	cell.outline:Hide()

	cell.boss = {}
	for index = 1, 2 do
		local icon = AuraIcon(face, DB().bossDebuffSize, true)
		icon:SetFrameLevel(face:GetFrameLevel() + 4)
		cell.boss[index] = icon
	end
	cell.boss[1]:SetPoint('CENTER', face, 'CENTER', 0, 0)
	cell.boss[2]:SetPoint('LEFT', cell.boss[1], 'RIGHT', 2, 0)
	cell.hots = {}
	for index = 1, 5 do
		local icon = AuraIcon(face, DB().hotSize, false)
		icon:SetFrameLevel(face:GetFrameLevel() + 3)
		if index == 1 then icon:SetPoint('BOTTOMRIGHT', cell.health.track, 'TOPRIGHT', -12, 2)
		else icon:SetPoint('RIGHT', cell.hots[index - 1], 'LEFT', -1, 0) end
		cell.hots[index] = icon
	end
	-- Slots the client draws private auras into.
	cell.private = {}
	for index = 1, 2 do
		local slot = CreateFrame('Frame', nil, face)
		slot:SetSize(DB().privateSize, DB().privateSize)
		slot:SetFrameLevel(face:GetFrameLevel() + 5)
		slot:EnableMouse(false)
		if index == 1 then slot:SetPoint('LEFT', face, 'LEFT', 4, -2)
		else slot:SetPoint('LEFT', cell.private[1], 'RIGHT', 1, 0) end
		cell.private[index] = slot
	end
	return face
end

-- Sizes the cell's pieces for its height and whether it shows power.
local function LayoutFace(cell, showPower)
	local height = cell:GetHeight()
	if IsSecret(height) or not height or height <= 0 then height = 32 end
	local bottom = showPower and 10 or 4
	local meter = max(4, min(12, height - 20 - (showPower and 6 or 0)))
	cell.health.track:ClearAllPoints()
	cell.health.track:SetPoint('BOTTOMLEFT', 4, bottom)
	cell.health.track:SetPoint('BOTTOMRIGHT', -4, bottom)
	cell.health.track:SetHeight(meter + cell.health.track.inset * 2)
	cell.power.track:SetShown(showPower and true or false)
	cell.showPower = showPower
end

local function WantsPower(cell, unit)
	local mode = cell.profile and DB()[cell.profile].power or 'none'
	if mode == 'all' then return true end
	if mode ~= 'healers' then return false end
	return Plain(UnitGroupRolesAssigned, unit) == 'HEALER'
end

-- Updates ------------------------------------------------------------------------------
local function UpdateHealth(cell)
	local unit = cell.unit
	cell.health:SetMinMaxValues(0, UnitHealthMax(unit))
	cell.health:SetValue(UnitHealth(unit), SMOOTH)
	local dead = UnitIsDeadOrGhost(unit)
	if not IsSecret(dead) and dead then cell.health:SetStatusBarColor(0.45, 0.45, 0.42)
	else PaintHealth(cell.health, unit) end
	-- Status: dead, offline or away first, else the health percent if asked.
	local text = ''
	local connected = UnitIsConnected(unit)
	if DB().statusText then
		if not IsSecret(connected) and not connected then text = 'OFF'
		elseif not IsSecret(dead) and dead then text = 'DEAD'
		elseif Plain(UnitIsAFK, unit) then text = 'AFK' end
	end
	if text ~= '' then
		cell.status:SetText(text)
	elseif cell.profile and DB()[cell.profile].healthText == 'percent' and UnitHealthPercent and CurveConstants and CurveConstants.ScaleTo100 then
		cell.status:SetFormattedText('%d', UnitHealthPercent(unit, true, CurveConstants.ScaleTo100))
	else
		cell.status:SetText('')
	end
end

local function UpdatePower(cell)
	local show = WantsPower(cell, cell.unit)
	if show ~= cell.showPower then LayoutFace(cell, show) end
	if not show then return end
	cell.power:SetMinMaxValues(0, UnitPowerMax(cell.unit))
	cell.power:SetValue(UnitPower(cell.unit), SMOOTH)
	PaintPower(cell.power, cell.unit)
end

local function UpdatePrediction(cell)
	local unit = cell.unit
	local heals, absorbs = DB().healPrediction, DB().absorbs
	if not (heals or absorbs) then cell.heals:Hide(); cell.absorb:Hide() return end
	local maximum = UnitHealthMax(unit)
	local incoming, shield
	if CreateUnitHealPredictionCalculator and UnitGetDetailedHealPrediction then
		cell.calculator = cell.calculator or CreateUnitHealPredictionCalculator()
		local ok = pcall(UnitGetDetailedHealPrediction, unit, 'player', cell.calculator)
		if ok then
			incoming = cell.calculator:GetIncomingHeals()
			shield = cell.calculator:GetDamageAbsorbs()
		end
	else
		if UnitGetIncomingHeals then incoming = UnitGetIncomingHeals(unit) end
		if UnitGetTotalAbsorbs then shield = UnitGetTotalAbsorbs(unit) end
	end
	-- The amounts may be secret: only whether there is one is asked, never its size.
	cell.heals:SetMinMaxValues(0, maximum)
	if heals and Has(incoming) then cell.heals:SetValue(incoming) else cell.heals:SetValue(0) end
	cell.heals:Show()
	cell.absorb:SetMinMaxValues(0, maximum)
	if absorbs and Has(shield) then cell.absorb:SetValue(shield) else cell.absorb:SetValue(0) end
	cell.absorb:Show()
end

local function UpdateName(cell)
	local name = UnitName(cell.unit)
	if IsSecret(name) then cell.nameText:SetText(name) else cell.nameText:SetText(name and strupper(name) or '') end
end

local function UpdateRange(cell)
	if not DB().rangeFade then cell.face:SetAlpha(1) return end
	local connected = UnitIsConnected(cell.unit)
	if not IsSecret(connected) and not connected then cell.face:SetAlpha(1) return end
	local inRange, checked = UnitInRange(cell.unit)
	if cell.face.SetAlphaFromBoolean then
		cell.face:SetAlphaFromBoolean(inRange, 1, DB().rangeAlpha)
	elseif not IsSecret(inRange) and not IsSecret(checked) then
		cell.face:SetAlpha((checked and not inRange) and DB().rangeAlpha or 1)
	end
end

local function UpdateTarget(cell)
	if not DB().targetOutline then cell.outline:Hide() return end
	cell.outline:SetVertexColor(RGB(DB().targetColor, 1))
	local isTarget = UnitIsUnit(cell.unit, 'target')
	if IsSecret(isTarget) then
		cell.outline:Show()
		if cell.outline.SetAlphaFromBoolean then cell.outline:SetAlphaFromBoolean(isTarget, 0.9, 0) else cell.outline:Hide() end
	else
		cell.outline:SetAlpha(0.9)
		cell.outline:SetShown(isTarget and true or false)
	end
end

local function UpdateIndicators(cell)
	local unit, db = cell.unit, DB()
	-- Role.
	local role = db.roleIcon and Plain(UnitGroupRolesAssigned, unit)
	local coords = role and ROLE_COORDS[role]
	if coords then cell.role:SetTexCoord(coords[1], coords[2], coords[3], coords[4]); cell.role:Show() else cell.role:Hide() end
	-- Leader.
	cell.leader:SetShown(db.leader and Plain(UnitIsGroupLeader, unit) and true or false)
	-- Raid marker.
	local index = db.raidIcon and Plain(GetRaidTargetIndex, unit)
	if index and SetRaidTargetIconTexture then SetRaidTargetIconTexture(cell.marker, index); cell.marker:Show() else cell.marker:Hide() end
	-- One centre badge, most urgent first.
	local center = cell.center
	center:SetTexCoord(0, 1, 0, 1)
	local status = db.readyCheck and Plain(GetReadyCheckStatus, unit)
	if status then
		center:SetTexture(status == 'ready' and READY_CHECK_READY_TEXTURE or status == 'notready' and READY_CHECK_NOT_READY_TEXTURE
			or READY_CHECK_WAITING_TEXTURE)
		center:Show()
		return
	end
	local summon = db.summon and C_IncomingSummon and Plain(C_IncomingSummon.IncomingSummonStatus, unit)
	if summon and summon > 0 and SUMMON_ATLAS[summon] then
		center:SetAtlas(SUMMON_ATLAS[summon])
		center:Show()
		return
	end
	if db.resurrect and Plain(UnitHasIncomingResurrection, unit) then
		center:SetTexture([[Interface\RaidFrame\Raid-Icon-Rez]])
		center:Show()
		return
	end
	if db.phase and Plain(UnitIsPlayer, unit) and Plain(UnitIsConnected, unit) and Plain(UnitPhaseReason, unit) then
		center:SetTexture([[Interface\TargetingFrame\UI-PhasingIcon]])
		center:SetTexCoord(0.15625, 0.84375, 0.15625, 0.84375)
		center:Show()
		return
	end
	center:Hide()
end

local function Remember(cell, data)
	local id = data.auraInstanceID
	if IsSecret(id) or not id then cell.shownSecret = true else cell.shownIDs[id] = true end
end

local function UpdateAuras(cell)
	local unit, db = cell.unit, DB()
	cell.shownIDs, cell.shownSecret = cell.shownIDs or {}, nil
	wipe(cell.shownIDs)
	-- Dispel ring: the first debuff (you can dispel), in its type colour.
	local ring = cell.ring
	ring:Hide()
	if db.dispel then
		local data = AuraByIndex(unit, 1, db.dispelOnly and 'HARMFUL|RAID_PLAYER_DISPELLABLE' or 'HARMFUL')
		if data then
			if dispelCurve then
				local ok, color = pcall(C_UnitAuras.GetAuraDispelTypeColor, unit, data.auraInstanceID, dispelCurve)
				if ok and color then
					ring:SetVertexColor(color.r, color.g, color.b, color.a)
					ring:Show()
				end
				Remember(cell, data)
			elseif not IsSecret(data.dispelName) and DISPEL_NAME[data.dispelName or ''] then
				ring:SetVertexColor(RGB(db.dispelColors[DISPEL_NAME[data.dispelName]], 1))
				ring:Show()
				Remember(cell, data)
			end
		end
	end
	-- Boss and other important debuffs, in the middle of the key.
	local shown = 0
	if db.bossDebuffs then
		for index = 1, 2 do
			local data = AuraByIndex(unit, index, 'HARMFUL|IMPORTANT') or (index == 1 and AuraByIndex(unit, 1, 'HARMFUL|RAID'))
			if not data then break end
			shown = index
			cell.boss[index]:SetSize(db.bossDebuffSize, db.bossDebuffSize)
			ShowAura(cell.boss[index], unit, data)
			Remember(cell, data)
		end
	end
	for index = shown + 1, 2 do cell.boss[index]:Hide() end
	-- Your heals over time, small in the corner.
	shown = 0
	if db.hots then
		for index = 1, min(db.hotCount or 3, #cell.hots) do
			-- RAID: what the game's own raid frames show for your class (heals over
			-- time, not long buffs like Fortitude).
			local data = AuraByIndex(unit, index, 'HELPFUL|PLAYER|RAID')
			if not data then break end
			shown = index
			cell.hots[index]:SetSize(db.hotSize, db.hotSize)
			ShowAura(cell.hots[index], unit, data)
			Remember(cell, data)
		end
	end
	for index = shown + 1, #cell.hots do cell.hots[index]:Hide() end
end

-- Private auras: the client draws them into our slots for the cell's unit.
local function ReleasePrivate(cell)
	if not cell.privateIDs then return end
	for _, id in ipairs(cell.privateIDs) do pcall(C_UnitAuras.RemovePrivateAuraAnchor, id) end
	cell.privateIDs = nil
end

local function AnchorPrivate(cell, unit)
	ReleasePrivate(cell)
	if not (unit and DB().privateAuras and C_UnitAuras and C_UnitAuras.AddPrivateAuraAnchor and C_UnitAuras.RemovePrivateAuraAnchor) then return end
	cell.privateIDs = {}
	local size = DB().privateSize
	for index, slot in ipairs(cell.private) do
		slot:SetSize(size, size)
		local ok, id = pcall(C_UnitAuras.AddPrivateAuraAnchor, {
			unitToken = unit, auraIndex = index, parent = slot,
			showCountdownFrame = true, showCooldownFrame = true, showCountdownNumbers = false,
			iconInfo = {iconWidth = size, iconHeight = size,
				iconAnchor = {point = 'CENTER', relativeTo = slot, relativePoint = 'CENTER', offsetX = 0, offsetY = 0}},
		})
		if ok and id then cell.privateIDs[#cell.privateIDs + 1] = id end
	end
end

local function UpdateCell(cell)
	if not cell.unit or not UnitExists(cell.unit) then return end
	UpdateName(cell)
	UpdatePower(cell)
	UpdateHealth(cell)
	UpdatePrediction(cell)
	UpdateRange(cell)
	UpdateTarget(cell)
	UpdateIndicators(cell)
	UpdateAuras(cell)
end

local CELL_UNIT_EVENTS = {
	UNIT_HEALTH = UpdateHealth, UNIT_MAXHEALTH = function(cell) UpdateHealth(cell); UpdatePrediction(cell) end,
	UNIT_CONNECTION = function(cell) UpdateHealth(cell); UpdateRange(cell) end, UNIT_FLAGS = UpdateHealth,
	UNIT_NAME_UPDATE = UpdateName, UNIT_AURA = UpdateAuras, UNIT_IN_RANGE_UPDATE = UpdateRange,
	UNIT_POWER_UPDATE = UpdatePower, UNIT_MAXPOWER = UpdatePower, UNIT_DISPLAYPOWER = UpdatePower,
	UNIT_HEAL_PREDICTION = UpdatePrediction, UNIT_ABSORB_AMOUNT_CHANGED = UpdatePrediction,
	UNIT_HEAL_ABSORB_AMOUNT_CHANGED = UpdatePrediction, UNIT_PHASE = UpdateIndicators,
	INCOMING_RESURRECT_CHANGED = UpdateIndicators, INCOMING_SUMMON_CHANGED = UpdateIndicators,
}
local CELL_EVENTS = {
	PLAYER_TARGET_CHANGED = UpdateTarget, RAID_TARGET_UPDATE = UpdateIndicators, READY_CHECK = UpdateIndicators,
	READY_CHECK_CONFIRM = UpdateIndicators, PARTY_LEADER_CHANGED = UpdateIndicators,
	PLAYER_ROLES_ASSIGNED = function(cell) UpdateIndicators(cell); UpdatePower(cell) end,
	GROUP_ROSTER_UPDATE = UpdateCell, PLAYER_FLAGS_CHANGED = UpdateHealth,
}

-- Does an aura update touch anything a cell shows or could show? New harmful
-- auras and your own helpful ones might; removals and changes only matter for
-- auras on the key. Without details (or with secret ones), always update.
local function AuraRelevant(cell, info)
	if type(info) ~= 'table' or not cell.shownIDs or cell.shownSecret then return true end
	-- The update's own fields can be secret in restricted content: then update.
	for _, field in ipairs({'isFullUpdate', 'addedAuras', 'updatedAuraInstanceIDs', 'removedAuraInstanceIDs'}) do
		if IsSecret(info[field]) then return true end
	end
	if info.isFullUpdate then return true end
	for _, aura in ipairs(info.addedAuras or {}) do
		if IsSecret(aura) then return true end
		local harmful, mine = aura.isHarmful, aura.isFromPlayerOrPlayerPet
		if IsSecret(harmful) or IsSecret(mine) or harmful or mine then return true end
	end
	for _, list in ipairs({info.updatedAuraInstanceIDs or {}, info.removedAuraInstanceIDs or {}}) do
		for _, id in ipairs(list) do
			if IsSecret(id) or cell.shownIDs[id] then return true end
		end
	end
	return false
end

-- A cell's events live on its own plain frame, re-registered whenever the
-- header moves a different member onto it.
local function SetCellUnit(cell, unit)
	if IsSecret(unit) then return end
	if unit == cell.unit and cell.events.registered then return end
	cell.unit = unit
	local events = cell.events
	events:UnregisterAllEvents()
	events.registered = nil
	if not unit then ReleasePrivate(cell) return end
	for event in pairs(CELL_UNIT_EVENTS) do pcall(events.RegisterUnitEvent, events, event, unit) end
	for event in pairs(CELL_EVENTS) do pcall(events.RegisterEvent, events, event) end
	events:RegisterEvent('READY_CHECK_FINISHED')
	events.registered = true
	AnchorPrivate(cell, unit)
	UI:Safe(UpdateCell, cell)
end

-- Called through the header's CallMethod from its secure setup of a new cell.
local function StyleCell(header, name)
	local cell = _G[name]
	if not cell or cells[cell] then return end
	cells[cell] = true
	BuildFace(cell, header.profile)
	LayoutFace(cell, false)
	cell.events = CreateFrame('Frame')
	cell.events:SetScript('OnEvent', function(_, event, _, info)
		-- Cells of the hidden header wait: showing them updates everything.
		if not cell:IsVisible() then cell.dirty = true return end
		if event == 'UNIT_AURA' and not AuraRelevant(cell, info) then return end
		if event == 'READY_CHECK_FINISHED' then
			-- The answers stay up a moment, then go.
			C_Timer.After(6, function() if cell.unit then UI:Safe(UpdateIndicators, cell) end end)
			return
		end
		local handler = CELL_UNIT_EVENTS[event] or CELL_EVENTS[event]
		if handler then UI:Safe(handler, cell) end
	end)
	cell:HookScript('OnAttributeChanged', function(self, attribute, value)
		if attribute == 'unit' then SetCellUnit(self, value) end
	end)
	cell:HookScript('OnShow', function(self)
		self.dirty = nil
		SetCellUnit(self, self:GetAttribute('unit'))
		UI:Safe(UpdateCell, self)
	end)
	cell:HookScript('OnEnter', function(self) if UnitFrame_OnEnter then UnitFrame_OnEnter(self) end end)
	cell:HookScript('OnLeave', function(self) if UnitFrame_OnLeave then UnitFrame_OnLeave(self) end end)
	-- Registering clicks is protected; a member who joins mid-fight gets it after.
	UI:AfterCombat(function() cell:RegisterForClicks('AnyUp') end, 'group.clicks.'..name)
	-- Click-casting addons (Clique and friends) pick frames up from this list.
	ClickCastFrames = ClickCastFrames or {}
	ClickCastFrames[cell] = true
	SetCellUnit(cell, cell:GetAttribute('unit'))
end

-- Headers --------------------------------------------------------------------------------
-- growth: units fill one way, columns stack the other.
local GROWTH = {
	down_right = {point = 'TOP', x = 0, y = -1, column = 'LEFT', vertical = true},
	down_left = {point = 'TOP', x = 0, y = -1, column = 'RIGHT', vertical = true},
	up_right = {point = 'BOTTOM', x = 0, y = 1, column = 'LEFT', vertical = true},
	up_left = {point = 'BOTTOM', x = 0, y = 1, column = 'RIGHT', vertical = true},
	right_down = {point = 'LEFT', x = 1, y = 0, column = 'TOP'},
	right_up = {point = 'LEFT', x = 1, y = 0, column = 'BOTTOM'},
	left_down = {point = 'RIGHT', x = -1, y = 0, column = 'TOP'},
	left_up = {point = 'RIGHT', x = -1, y = 0, column = 'BOTTOM'},
}
local GROUPING = {
	GROUP = {'GROUP', '1,2,3,4,5,6,7,8'},
	ROLE = {'ASSIGNEDROLE', 'TANK,HEALER,DAMAGER,NONE'},
	CLASS = {'CLASS', 'WARRIOR,DEATHKNIGHT,PALADIN,MONK,PRIEST,SHAMAN,DRUID,ROGUE,MAGE,WARLOCK,HUNTER,DEMONHUNTER,EVOKER'},
}

-- The corner of the holder the header grows from.
local function Corner(growth)
	local vertical = (growth.point == 'TOP' or growth.point == 'BOTTOM') and growth.point or growth.column
	local horizontal = (growth.point == 'LEFT' or growth.point == 'RIGHT') and growth.point or growth.column
	return vertical..horizontal
end

local function HolderSize(p)
	local growth = GROWTH[p.growth] or GROWTH.down_right
	local rows, columns = p.unitsPerColumn, p.maxColumns
	if growth.vertical then
		return columns * p.width + (columns - 1) * p.columnSpacing, rows * p.height + (rows - 1) * p.spacing
	end
	return rows * p.width + (rows - 1) * p.spacing, columns * p.height + (columns - 1) * p.columnSpacing
end

local function Visibility(key)
	if key == 'large' then return '[@raid21,exists] show; hide' end
	if DB().partyAsRaid then return '[@raid21,exists] hide; [group:raid] show; [group:party] show; hide' end
	return '[@raid21,exists] hide; [group:raid] show; hide'
end

local function ApplyHeader(key)
	local header = headers[key]
	if not header then return end
	if InCombatLockdown() then return UI:AfterCombat(function() ApplyHeader(key) end, 'group.header.'..key) end
	local p = DB()[key]
	local growth = GROWTH[p.growth] or GROWTH.down_right
	local grouping = GROUPING[p.groupBy] or GROUPING.GROUP
	local holder = header.holder
	UI:SetMoverBaseScale('group.'..key, p.scale or 1, holder)
	holder:SetSize(HolderSize(p))
	header:SetAttribute('cellWidth', p.width)
	header:SetAttribute('cellHeight', p.height)
	header:SetAttribute('showParty', key == 'small' and DB().partyAsRaid or false)
	header:SetAttribute('point', growth.point)
	header:SetAttribute('xOffset', growth.x * p.spacing)
	header:SetAttribute('yOffset', growth.y * p.spacing)
	header:SetAttribute('columnSpacing', p.columnSpacing)
	header:SetAttribute('columnAnchorPoint', growth.column)
	header:SetAttribute('unitsPerColumn', p.unitsPerColumn)
	header:SetAttribute('maxColumns', p.maxColumns)
	header:SetAttribute('groupBy', grouping[1])
	header:SetAttribute('groupingOrder', grouping[2])
	header:SetAttribute('sortMethod', p.sortMethod)
	local corner = Corner(growth)
	header:ClearAllPoints()
	header:SetPoint(corner, holder, corner)
	-- Cells already made take the new size.
	for index = 1, 40 do
		local child = header:GetAttribute('child'..index)
		if not child then break end
		child:SetSize(p.width, p.height)
		if cells[child] then LayoutFace(child, child.showPower) end
	end
	RegisterStateDriver(header, 'visibility', Visibility(key))
	-- Let the header lay its members out again.
	if header:IsShown() then header:Hide(); header:Show() end
	UI:PlaceMover('group.'..key)
end

local INITIAL_CONFIG = [[
	local header = self:GetParent()
	self:SetWidth(header:GetAttribute('cellWidth'))
	self:SetHeight(header:GetAttribute('cellHeight'))
	self:SetAttribute('*type1', 'target')
	self:SetAttribute('*type2', 'togglemenu')
	header:CallMethod('StyleCell', self:GetName())
	local clique = header:GetFrameRef('clickcast_header')
	if clique then
		clique:SetAttribute('clickcast_button', self)
		clique:RunAttribute('clickcast_register')
	end
]]

local function TemplateExists(name)
	return C_XMLUtil and C_XMLUtil.GetTemplateInfo and C_XMLUtil.GetTemplateInfo(name) ~= nil
end

-- Preview members, so the frames can be placed outside a raid.
local function BuildPreview(holder, key)
	local p = DB()[key]
	holder.dummies = holder.dummies or {}
	local growth = GROWTH[p.growth] or GROWTH.down_right
	local count = min(p.unitsPerColumn * p.maxColumns, 40)
	local roles = {'TANK', 'HEALER', 'DAMAGER', 'DAMAGER', 'DAMAGER'}
	for index = 1, count do
		local dummy = holder.dummies[index]
		if not dummy then
			dummy = CreateFrame('Frame', nil, holder)
			BuildFace(dummy, key)
			holder.dummies[index] = dummy
		end
		dummy:SetSize(p.width, p.height)
		local role = roles[(index - 1) % 5 + 1]
		LayoutFace(dummy, p.power == 'all' or (p.power == 'healers' and role == 'HEALER'))
		dummy.nameText:SetText('MEMBER '..index)
		dummy.status:SetText(index % 7 == 0 and 'DEAD' or '')
		dummy.health:SetMinMaxValues(0, 1)
		dummy.health:SetValue(index % 7 == 0 and 0 or 0.35 + ((index * 37) % 60) / 100)
		dummy.health:SetStatusBarColor(Kit:RGB('lamp'))
		dummy.power:SetValue(0.7)
		dummy.power:SetStatusBarColor(0.29, 0.64, 1)
		local coords = DB().roleIcon and ROLE_COORDS[role]
		if coords then dummy.role:SetTexCoord(coords[1], coords[2], coords[3], coords[4]); dummy.role:Show() else dummy.role:Hide() end
		dummy.ring:SetShown(DB().dispel and index % 6 == 2)
		if dummy.ring:IsShown() then dummy.ring:SetVertexColor(RGB(DB().dispelColors.magic, 1)) end
		-- Position as the header would.
		local slot, column = (index - 1) % p.unitsPerColumn, floor((index - 1) / p.unitsPerColumn)
		local x, y
		if growth.vertical then
			x = column * (p.width + p.columnSpacing) * (growth.column == 'LEFT' and 1 or -1)
			y = slot * (p.height + p.spacing) * growth.y
		else
			x = slot * (p.width + p.spacing) * growth.x
			y = column * (p.height + p.columnSpacing) * (growth.column == 'TOP' and -1 or 1)
		end
		local corner = Corner(growth)
		dummy:ClearAllPoints()
		dummy:SetPoint(corner, holder, corner, x, y)
		dummy:Show()
	end
	for index = count + 1, #holder.dummies do holder.dummies[index]:Hide() end
end

local function BuildHeader(key, label, at)
	local holder = CreateFrame('Frame', 'JiberishSpec01Raid'..(key == 'small' and 'Small' or 'Large')..'Holder', UIParent)
	holder:SetSize(HolderSize(DB()[key]))
	local templates = 'SecureUnitButtonTemplate, SecureHandlerEnterLeaveTemplate'
	if TemplateExists('PingableUnitFrameTemplate') then templates = templates..', PingableUnitFrameTemplate' end
	local header = CreateFrame('Frame', 'JiberishSpec01Raid'..(key == 'small' and 'Small' or 'Large'), holder, 'SecureGroupHeaderTemplate')
	header.holder, header.profile = holder, key
	header.StyleCell = StyleCell
	header:SetAttribute('template', templates)
	header:SetAttribute('showRaid', true)
	header:SetAttribute('showPlayer', true)
	header:SetAttribute('showSolo', false)
	header:SetAttribute('groupFilter', '1,2,3,4,5,6,7,8')
	header:SetAttribute('initialConfigFunction', INITIAL_CONFIG)
	-- Click-casting addons hook entering and leaving through these.
	header:SetAttribute('_initialAttributeNames', '_onenter,_onleave')
	header:SetAttribute('_initialAttribute-_onenter', [[
		local snippet = self:GetAttribute('clickcast_onenter')
		if snippet then self:Run(snippet) end
	]])
	header:SetAttribute('_initialAttribute-_onleave', [[
		local snippet = self:GetAttribute('clickcast_onleave')
		if snippet then self:Run(snippet) end
	]])
	if _G.Clique and _G.Clique.header and SecureHandlerSetFrameRef then
		SecureHandlerSetFrameRef(header, 'clickcast_header', _G.Clique.header)
	end
	headers[key] = header
	UI:RegisterMover(holder, 'group.'..key, label, at)
	function holder:SetPreview(on)
		if on then
			BuildPreview(self, key)
		elseif self.dummies then
			for _, dummy in ipairs(self.dummies) do dummy:Hide() end
		end
	end
	ApplyHeader(key)
	return header
end

-- Boss and arena devices -------------------------------------------------------------------
-- The cast strip under a device: the client runs it from its duration object.
local function CastStrip(device, unit)
	local cast = CreateFrame('Frame', nil, device.face)
	cast:SetHeight(18)
	cast:SetPoint('TOPLEFT', device.face, 'BOTTOMLEFT', 0, -3)
	cast:SetPoint('TOPRIGHT', device.face, 'BOTTOMRIGHT', 0, -3)
	cast.shell = Kit:Shell(cast, {surface = 'glass', radius = 5, shadowAlpha = 0.25, group = 'unitframes'})
	cast.icon = cast:CreateTexture(nil, 'ARTWORK')
	cast.icon:SetSize(12, 12)
	cast.icon:SetPoint('LEFT', 4, 0)
	cast.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	cast.label = Kit:Label(cast, '', 'darkInk', 'tiny', true)
	cast.label:SetPoint('LEFT', cast.icon, 'RIGHT', 4, 3)
	cast.label:SetPoint('RIGHT', -6, 3)
	cast.label:SetJustifyH('LEFT')
	cast.label:SetWordWrap(false)
	local track = CreateFrame('Frame', nil, cast)
	track:SetHeight(4)
	track:SetPoint('BOTTOMLEFT', cast.icon, 'BOTTOMRIGHT', 4, 0)
	track:SetPoint('BOTTOMRIGHT', -6, 3)
	local bar = CreateFrame('StatusBar', nil, track)
	bar:SetAllPoints()
	bar:SetStatusBarTexture(Kit.media..'bar-flat.tga')
	MaskFill(bar, 'mask-pill', 15)
	bar:SetMinMaxValues(0, 1)
	bar.track = track
	cast.bar = bar
	ApplyLooks(nil, nil, bar)
	cast.shield = bar:CreateTexture(nil, 'OVERLAY')
	cast.shield:SetAllPoints(bar:GetStatusBarTexture())
	cast.shield:SetColorTexture(0.55, 0.55, 0.52, 1)
	cast.shield:Hide()
	cast:SetAlpha(0)
	cast:Hide()

	local function Casting()
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

	local function Start()
		local duration, channel, empowering = Casting()
		if not duration then return false end
		local name, texture, notInterruptible
		if channel then name, _, texture, _, _, _, notInterruptible = UnitChannelInfo(unit)
		else name, _, texture, _, _, _, _, notInterruptible = UnitCastingInfo(unit) end
		cast.label:SetText(name)
		cast.icon:SetTexture(texture)
		bar:SetStatusBarColor(CastColor(channel and 'channel' or 'cast', 'amber'))
		-- A secret "can't interrupt" greys the fill without being tested.
		if IsSecret(notInterruptible) then
			cast.shield:Show()
			if cast.shield.SetAlphaFromBoolean then cast.shield:SetAlphaFromBoolean(notInterruptible, 1, 0) else cast.shield:Hide() end
		else
			cast.shield:SetAlpha(1)
			cast.shield:SetShown(notInterruptible and true or false)
		end
		if duration ~= true and bar.SetTimerDuration and TIMER then
			bar:SetTimerDuration(duration, IMMEDIATE, (channel and not empowering) and TIMER.RemainingTime or TIMER.ElapsedTime)
			cast:SetScript('OnUpdate', nil)
		else
			local _, _, _, startTime, endTime = (channel and UnitChannelInfo or UnitCastingInfo)(unit)
			if IsSecret(startTime) or IsSecret(endTime) or not startTime then return false end
			bar:SetMinMaxValues(startTime / 1000, endTime / 1000)
			cast:SetScript('OnUpdate', function()
				local now = GetTime()
				bar:SetValue(channel and (endTime / 1000 - (now - startTime / 1000)) or now)
			end)
		end
		cast.stopping = nil
		cast:Show()
		Kit:FadeTo(cast, 1, 'FAST')
		return true
	end

	local function Stop(failed)
		if cast.stopping or not cast:IsShown() then return end
		cast.stopping = true
		cast:SetScript('OnUpdate', nil)
		local function Out()
			if cast.stopping then Kit:FadeTo(cast, 0, 'FAST', function() if cast.stopping then cast:Hide() end end) end
		end
		if failed then
			cast.shield:Hide()
			bar:SetStatusBarColor(CastColor('interrupted', 'red'))
			cast.label:SetText(failed)
			C_Timer.After(0.6, Out)
		else
			Out()
		end
	end

	function cast:Refresh()
		local ok, started = pcall(Start)
		if not (ok and started) then Stop() end
	end

	cast:SetScript('OnEvent', function(_, event)
		if device.previewing then return end
		if event == 'UNIT_SPELLCAST_INTERRUPTED' or event == 'UNIT_SPELLCAST_FAILED' then
			local ok, casting = pcall(Casting)
			if ok and casting then cast:Refresh()
			else Stop(event == 'UNIT_SPELLCAST_INTERRUPTED' and 'INTERRUPTED' or 'FAILED') end
		else
			cast:Refresh()
		end
	end)
	for _, event in ipairs({'UNIT_SPELLCAST_START', 'UNIT_SPELLCAST_STOP', 'UNIT_SPELLCAST_FAILED', 'UNIT_SPELLCAST_INTERRUPTED',
		'UNIT_SPELLCAST_DELAYED', 'UNIT_SPELLCAST_CHANNEL_START', 'UNIT_SPELLCAST_CHANNEL_UPDATE', 'UNIT_SPELLCAST_CHANNEL_STOP',
		'UNIT_SPELLCAST_INTERRUPTIBLE', 'UNIT_SPELLCAST_NOT_INTERRUPTIBLE', 'UNIT_SPELLCAST_EMPOWER_START',
		'UNIT_SPELLCAST_EMPOWER_UPDATE', 'UNIT_SPELLCAST_EMPOWER_STOP'}) do
		pcall(cast.RegisterUnitEvent, cast, event, unit)
	end
	return cast
end

local function SetHealthDigits(fontString, unit)
	local ok = pcall(function()
		local dead, connected = UnitIsDeadOrGhost(unit), UnitIsConnected(unit)
		if not IsSecret(dead) and dead then fontString:SetText('DEAD') return end
		if not IsSecret(connected) and not connected then fontString:SetText('OFF') return end
		if UnitHealthPercent and CurveConstants and CurveConstants.ScaleTo100 then
			fontString:SetFormattedText('%d', UnitHealthPercent(unit, true, CurveConstants.ScaleTo100))
			return
		end
		local health, maximum = UnitHealth(unit), UnitHealthMax(unit)
		if IsSecret(health) or IsSecret(maximum) then fontString:SetText('') return end
		fontString:SetFormattedText('%d', maximum > 0 and floor(health / maximum * 100 + 0.5) or 0)
	end)
	if not ok then fontString:SetText('') end
end

local devices = {} -- boss and arena frames

local function UpdateDeviceHealth(device)
	local unit = device.unit
	device.health:SetMinMaxValues(0, UnitHealthMax(unit))
	device.health:SetValue(UnitHealth(unit), SMOOTH)
	if device.kind == 'arena' and DB().healthColor ~= 'gradient2' then device.health:SetStatusBarColor(ClassColor(unit))
	else PaintHealth(device.health, unit) end
	SetHealthDigits(device.digits, unit)
end

local function UpdateDevicePower(device)
	local unit = device.unit
	device.power:SetMinMaxValues(0, UnitPowerMax(unit))
	device.power:SetValue(UnitPower(unit), SMOOTH)
	PaintPower(device.power, unit)
end

local function UpdateDeviceName(device)
	local name = UnitName(device.unit)
	if IsSecret(name) then device.nameText:SetText(name) else device.nameText:SetText(name and strupper(name) or strupper(device.title)) end
end

local function UpdateDeviceTarget(device)
	local isTarget = UnitIsUnit(device.unit, 'target')
	local lamp = device.lamp
	if IsSecret(isTarget) then
		Kit:SetLed(lamp, true)
		if lamp.SetAlphaFromBoolean then
			lamp:SetAlphaFromBoolean(isTarget, 1, 0.35)
			if lamp.glow then lamp.glow:SetAlphaFromBoolean(isTarget, 1, 0) end
		end
	else
		lamp:SetAlpha(1)
		if lamp.glow then lamp.glow:SetAlpha(1) end
		Kit:SetLed(lamp, isTarget and true or false)
	end
end

local function UpdateDeviceAuras(device)
	if not device.auras then return end
	local shown = 0
	if DB()[device.kind].auras then
		for index = 1, #device.auras do
			local data = AuraByIndex(device.unit, index, 'HARMFUL|PLAYER')
			if not data then break end
			shown = index
			ShowAura(device.auras[index], device.unit, data)
		end
	end
	for index = shown + 1, #device.auras do device.auras[index]:Hide() end
end

-- Arena: the opponent's spec, before the gates open and after.
local function SpecInfo(index)
	local spec = GetArenaOpponentSpec and Plain(GetArenaOpponentSpec, index)
	if not spec or spec <= 0 or not GetSpecializationInfoByID then return nil end
	local ok, _, name, _, icon, _, class = pcall(GetSpecializationInfoByID, spec)
	if not ok then return nil end
	return name, icon, class
end

local function UpdateSpec(device)
	if not device.spec then return end
	local name, icon = SpecInfo(device.index)
	if icon and DB().arena.spec then
		device.spec.texture:SetTexture(icon)
		device.spec:Show()
	else
		device.spec:Hide()
	end
	device.specName = name
end

local function UpdateTrinket(device)
	local trinket = device.trinket
	if not trinket then return end
	if not (DB().arena.trinket and C_PvP and C_PvP.GetArenaCrowdControlInfo) then trinket:Hide() return end
	local ok, spell, start, duration = pcall(C_PvP.GetArenaCrowdControlInfo, device.unit)
	if not ok or IsSecret(spell) or not spell then trinket:Hide() return end
	local texture = (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(spell)) or (GetSpellTexture and GetSpellTexture(spell))
	trinket.texture:SetTexture(texture)
	if not IsSecret(start) and not IsSecret(duration) and start and duration and duration > 0 then
		trinket.cooldown:SetCooldown(start / 1000, duration / 1000)
	else
		trinket.cooldown:Clear()
	end
	trinket:Show()
end

local function UpdateDevice(device)
	if device.previewing or not UnitExists(device.unit) then return end
	UpdateDeviceName(device)
	UpdateDeviceHealth(device)
	UpdateDevicePower(device)
	UpdateDeviceTarget(device)
	UpdateDeviceAuras(device)
	if device.kind == 'arena' then UpdateSpec(device); UpdateTrinket(device) end
	if device.cast then device.cast:Refresh() end
end

local DEVICE_UNIT_EVENTS = {
	UNIT_HEALTH = UpdateDeviceHealth, UNIT_MAXHEALTH = UpdateDeviceHealth, UNIT_CONNECTION = UpdateDeviceHealth,
	UNIT_POWER_UPDATE = UpdateDevicePower, UNIT_MAXPOWER = UpdateDevicePower, UNIT_DISPLAYPOWER = UpdateDevicePower,
	UNIT_NAME_UPDATE = UpdateDeviceName, UNIT_AURA = UpdateDeviceAuras, UNIT_TARGETABLE_CHANGED = UpdateDevice,
	ARENA_COOLDOWNS_UPDATE = UpdateTrinket, ARENA_CROWD_CONTROL_SPELL_UPDATE = UpdateTrinket,
}

local function Key(parent, size)
	local key = CreateFrame('Frame', nil, parent)
	key:SetSize(size, size)
	key.shell = Kit:Shell(key, {surface = 'glass', radius = 5, shadowAlpha = 0.3, group = 'unitframes'})
	key.texture = key:CreateTexture(nil, 'ARTWORK')
	key.texture:SetPoint('TOPLEFT', 3, -3)
	key.texture:SetPoint('BOTTOMRIGHT', -3, 3)
	key.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	local mask = key:CreateMaskTexture()
	mask:SetTexture(Kit.media..'mask-icon.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
	mask:SetAllPoints(key.texture)
	key.texture:AddMaskTexture(mask)
	key.cooldown = CreateFrame('Cooldown', nil, key, 'CooldownFrameTemplate')
	key.cooldown:SetAllPoints(key.texture)
	key.cooldown:SetDrawEdge(false)
	if key.cooldown.SetSwipeTexture then key.cooldown:SetSwipeTexture(Kit.media..'mask-icon.tga', 0, 0, 0, 0.7) end
	key:Hide()
	return key
end

local function BuildDevice(kind, index, holder)
	local db = DB()[kind]
	local unit = kind..index
	local style = HousingStyle()
	local ink = Kit.INK[style] or Kit.INK.paper
	local device = CreateFrame('Button', 'JiberishSpec01'..(kind == 'boss' and 'Boss' or 'Arena')..index, holder, 'SecureUnitButtonTemplate')
	device.unit, device.kind, device.index = unit, kind, index
	device.title = (kind == 'boss' and 'Boss ' or 'Arena ')..index
	device:SetSize(db.width, db.height)
	device:SetAttribute('unit', unit)
	device:SetAttribute('*type1', 'target')
	device:SetAttribute('*type2', 'togglemenu')
	device:RegisterForClicks('AnyUp')
	device:SetScript('OnEnter', function(self) if UnitFrame_OnEnter then UnitFrame_OnEnter(self) end end)
	device:SetScript('OnLeave', function(self) if UnitFrame_OnLeave then UnitFrame_OnLeave(self) end end)
	ClickCastFrames = ClickCastFrames or {}
	ClickCastFrames[device] = true

	local face = CreateFrame('Frame', nil, device)
	face:SetAllPoints()
	face:EnableMouse(false)
	device.face = face
	device.shell = Kit:Shell(face, {surface = style, radius = 8})
	local pad = 7
	device.lamp = Kit:Led(face, 5, false)
	device.lamp:SetPoint('TOPLEFT', pad + 1, -8)
	local code = Kit:Label(face, (kind == 'boss' and 'BS-' or 'AR-')..index, ink[1], 'tiny', true)
	code:SetPoint('LEFT', device.lamp, 'RIGHT', 4, 0)
	device.nameText = Kit:Label(face, '', ink[1], 'small', true)
	device.nameText:SetPoint('LEFT', code, 'RIGHT', 6, 0)
	device.nameText:SetPoint('RIGHT', face, 'TOPRIGHT', -60, -10)
	device.nameText:SetJustifyH('LEFT')
	device.nameText:SetWordWrap(false)
	-- The health readout on a small LCD, over unlit segments.
	local lcd = Kit:LCDPanel(face)
	lcd:SetSize(44, 16)
	lcd:SetPoint('TOPRIGHT', -pad, -5)
	local ghost = Kit:Text(lcd, '888', 'small', 'lcdGhost')
	ghost:SetPoint('RIGHT', -5, 0)
	device.digits = Kit:Text(lcd, '', 'small', 'lcdInk')
	device.digits:SetPoint('RIGHT', -5, 0)
	device.digits:SetJustifyH('RIGHT')
	device.health = Meter(face, style == 'dark')
	device.health.track:SetHeight(6 + device.health.track.inset * 2)
	device.health.track:SetPoint('TOPLEFT', pad, -25)
	device.health.track:SetPoint('TOPRIGHT', -pad, -25)
	device.power = Meter(face, style == 'dark')
	device.power.track:SetHeight(3 + device.power.track.inset * 2)
	device.power.track:SetPoint('TOPLEFT', device.health.track, 'BOTTOMLEFT', 0, -2)
	device.power.track:SetPoint('TOPRIGHT', device.health.track, 'BOTTOMRIGHT', 0, -2)

	if db.castbar then device.cast = CastStrip(device, unit) end
	if db.auras ~= nil then
		device.auras = {}
		for slot = 1, 4 do
			local icon = AuraIcon(face, 20, true)
			if slot == 1 then icon:SetPoint('TOPRIGHT', face, 'TOPLEFT', -4, -2)
			else icon:SetPoint('RIGHT', device.auras[slot - 1], 'LEFT', -3, 0) end
			device.auras[slot] = icon
		end
	end
	if kind == 'arena' then
		device.spec = Key(face, 30)
		device.spec:SetPoint('RIGHT', face, 'LEFT', -4, 0)
		if device.auras then
			device.auras[1]:ClearAllPoints()
			device.auras[1]:SetPoint('TOPRIGHT', device.spec, 'TOPLEFT', -4, 0)
		end
		device.trinket = Key(face, 30)
		device.trinket:SetPoint('LEFT', face, 'RIGHT', 4, 0)
	end

	for event in pairs(DEVICE_UNIT_EVENTS) do pcall(device.RegisterUnitEvent, device, event, unit) end
	device:RegisterEvent('PLAYER_TARGET_CHANGED')
	device:RegisterEvent('PLAYER_ENTERING_WORLD')
	if kind == 'boss' then pcall(device.RegisterEvent, device, 'INSTANCE_ENCOUNTER_ENGAGE_UNIT')
	else pcall(device.RegisterEvent, device, 'ARENA_OPPONENT_UPDATE') end
	device:SetScript('OnEvent', function(self, event)
		if event == 'PLAYER_TARGET_CHANGED' then return UI:Safe(UpdateDeviceTarget, self) end
		local handler = DEVICE_UNIT_EVENTS[event]
		if handler then UI:Safe(handler, self) else UI:Safe(UpdateDevice, self) end
		if event == 'ARENA_OPPONENT_UPDATE' and C_PvP and C_PvP.RequestCrowdControlSpell then
			pcall(C_PvP.RequestCrowdControlSpell, unit)
		end
	end)
	device:HookScript('OnShow', function(self)
		UI:Safe(UpdateDevice, self)
		if not Kit:DB().reduceMotion then self.face:SetAlpha(0); Kit:FadeTo(self.face, 1, 'NORMAL') end
	end)
	RegisterUnitWatch(device)
	devices[#devices + 1] = device
	ApplyLooks(device.health, device.power, device.cast and device.cast.bar)
	return device
end

-- Before the gates open: the opponents' specs on plain stand-ins.
local function BuildPrep(holder, index)
	local style = HousingStyle()
	local ink = Kit.INK[style] or Kit.INK.paper
	local prep = CreateFrame('Frame', nil, holder)
	prep.shell = Kit:Shell(prep, {surface = style, radius = 8})
	prep.lamp = Kit:Led(prep, 5, false)
	prep.lamp:SetPoint('TOPLEFT', 8, -8)
	prep.code = Kit:Label(prep, 'AR-'..index, ink[1], 'tiny', true)
	prep.code:SetPoint('LEFT', prep.lamp, 'RIGHT', 4, 0)
	prep.name = Kit:Label(prep, '', ink[2], 'small', true)
	prep.name:SetPoint('LEFT', prep.code, 'RIGHT', 6, 0)
	prep.spec = Key(prep, 30)
	prep.spec:SetPoint('RIGHT', prep, 'LEFT', -4, 0)
	prep:Hide()
	return prep
end

local function BuildDeviceGroup(kind, label, at)
	local db = DB()[kind]
	local holder = CreateFrame('Frame', 'JiberishSpec01'..(kind == 'boss' and 'Boss' or 'Arena')..'Holder', UIParent)
	holder.kind, holder.devices, holder.preps = kind, {}, {}
	for index = 1, 5 do
		holder.devices[index] = BuildDevice(kind, index, holder)
		if kind == 'arena' then holder.preps[index] = BuildPrep(holder, index) end
	end
	function holder:Layout()
		if InCombatLockdown() then return UI:AfterCombat(function() self:Layout() end, 'group.'..kind) end
		local p = DB()[kind]
		local step = p.height + p.spacing
		UI:SetMoverBaseScale('group.'..kind, p.scale or 1, self)
		self:SetSize(p.width, 5 * p.height + 4 * p.spacing)
		for index, device in ipairs(self.devices) do
			local offset = (index - 1) * step
			device:SetSize(p.width, p.height)
			device:ClearAllPoints()
			if p.growth == 'up' then device:SetPoint('BOTTOM', self, 'BOTTOM', 0, offset)
			else device:SetPoint('TOP', self, 'TOP', 0, -offset) end
			local prep = self.preps[index]
			if prep then
				prep:SetSize(p.width, p.height)
				prep:ClearAllPoints()
				prep:SetAllPoints(device)
			end
		end
		UI:PlaceMover('group.'..kind)
	end
	function holder:SetPreview(on)
		if InCombatLockdown() then
			if on then return end
			-- Unit watches can only be registered out of combat; until then the
			-- devices stop previewing and show their units.
			UI:AfterCombat(function() self:SetPreview(false) end, 'preview.group.'..kind)
			for _, device in ipairs(self.devices) do
				device.previewing = nil
				if device.cast then device.cast.stopping = true; device.cast:Hide() end
				UI:Safe(UpdateDevice, device)
			end
			return
		end
		for index, device in ipairs(self.devices) do
			device.previewing = on or nil
			if on then
				UnregisterUnitWatch(device)
				device:Show()
				device.nameText:SetText(strupper(device.title))
				device.health:SetMinMaxValues(0, 1)
				device.health:SetValue(1 - index * 0.12)
				device.health:SetStatusBarColor(Kit:RGB('lamp'))
				device.power:SetMinMaxValues(0, 1)
				device.power:SetValue(0.8)
				device.digits:SetText(floor((1 - index * 0.12) * 100))
				Kit:SetLed(device.lamp, index == 1)
				if device.cast then
					device.cast.label:SetText('CASTING')
					device.cast.bar:SetMinMaxValues(0, 1)
					device.cast.bar:SetValue(0.6)
					device.cast.bar:SetStatusBarColor(Kit:RGB('amber'))
					device.cast.stopping = nil
					device.cast:Show()
					device.cast:SetAlpha(1)
				end
			else
				if device.cast then device.cast.stopping = true; device.cast:Hide() end
				RegisterUnitWatch(device)
				UI:Safe(UpdateDevice, device)
			end
		end
	end
	UI:RegisterMover(holder, 'group.'..kind, label, at)
	holder:Layout()
	if kind == 'arena' then
		local driver = CreateFrame('Frame')
		pcall(driver.RegisterEvent, driver, 'ARENA_PREP_OPPONENT_SPECIALIZATIONS')
		pcall(driver.RegisterEvent, driver, 'ARENA_OPPONENT_UPDATE')
		driver:RegisterEvent('PLAYER_ENTERING_WORLD')
		driver:SetScript('OnEvent', function(_, event)
			local count = GetNumArenaOpponentSpecs and Plain(GetNumArenaOpponentSpecs) or 0
			for index, prep in ipairs(holder.preps) do
				local name, icon, class = SpecInfo(index)
				local live = Plain(UnitExists, 'arena'..index)
				local show = event ~= 'PLAYER_ENTERING_WORLD' and DB().arena.spec and index <= count and icon and not live
				if show then
					prep.spec.texture:SetTexture(icon)
					prep.spec:Show()
					prep.name:SetText(strupper(name or ''))
					local color = class and (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)[class]
					if color then prep.name:SetTextColor(color.r, color.g, color.b) end
					prep:Show()
				else
					prep:Hide()
				end
			end
		end)
	end
	return holder
end

-- Blizzard's frames ---------------------------------------------------------------------------
local function RetireRaid()
	if not DB().hideBlizzard then return end
	UI:Retire(_G.CompactRaidFrameManager)
	UI:Retire(_G.CompactRaidFrameContainer)
	if DB().partyAsRaid then UI:Retire(_G.CompactPartyFrame) end
end

local function RetireBoss()
	if not DB().hideBlizzard then return end
	UI:Retire(_G.BossTargetFrameContainer)
	for index = 1, 5 do UI:Retire(_G['Boss'..index..'TargetFrame']) end
end

local function RetireArena()
	if not DB().hideBlizzard then return end
	for _, name in ipairs({'CompactArenaFrame', 'ArenaEnemyFramesContainer', 'ArenaEnemyMatchFramesContainer', 'ArenaPrepFrames',
		'ArenaEnemyFrames', 'ArenaEnemyPrepFramesContainer'}) do
		local frame = _G[name]
		if frame and not Forbidden(frame) then UI:Retire(frame) end
	end
end

-- The unit frames' party devices give way when the party shows as raid cells.
local function QuietParty()
	if not DB().partyAsRaid then return end
	local unitframes = UI.modules.unitframes
	local header = unitframes and unitframes.partyHeader
	if header then UI:AfterCombat(function() RegisterStateDriver(header, 'visibility', 'hide') end, 'group.partyheader') end
end

-- Module -----------------------------------------------------------------------------------------
local signature
local function Signature()
	local parts = {}
	local function Walk(prefix, node)
		local keys = {}
		for key in pairs(node) do keys[#keys + 1] = key end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		for _, key in ipairs(keys) do
			local value = node[key]
			if type(value) == 'table' then Walk(prefix..key..'.', value) else parts[#parts + 1] = prefix..key..'='..tostring(value) end
		end
	end
	Walk('', DB())
	return table.concat(parts, ';')
end

function module:Enable()
	if InCombatLockdown() then
		UI:AfterCombat(function() self.enabled = UI:Safe(self.Enable, self) end, 'group')
		return
	end
	BuildDispelCurve()
	BuildHeader('small', 'Raid (up to 20)', {'TOPLEFT', 24, -320})
	BuildHeader('large', 'Raid (21 to 40)', {'BOTTOMLEFT', 24, 300})
	RetireRaid()
	QuietParty()
	if DB().boss.enable then
		module.boss = BuildDeviceGroup('boss', 'Boss frames', {'RIGHT', -260, 80})
		RetireBoss()
	end
	if DB().arena.enable then
		module.arena = BuildDeviceGroup('arena', 'Arena frames', {'RIGHT', -260, 80})
		RetireArena()
		-- The arena frames load on demand on some clients.
		local loader = CreateFrame('Frame')
		loader:RegisterEvent('ADDON_LOADED')
		loader:SetScript('OnEvent', function(_, _, name)
			if name == 'Blizzard_ArenaUI' or name == 'Blizzard_CompactRaidFrames' then RetireArena() end
		end)
	end
	signature = Signature()
end

-- Settings changed somewhere: re-apply only when ours did.
function module:Refresh()
	local now = Signature()
	if now == signature then return end
	signature = now
	BuildDispelCurve()
	ApplyHeader('small')
	ApplyHeader('large')
	if module.boss then module.boss:Layout() end
	if module.arena then module.arena:Layout() end
	for cell in pairs(cells) do
		UI:Safe(ApplyLooks, cell.health, cell.power)
		if cell.nameText then Kit:Font(cell.nameText, DB().nameSize or 9, nil, true) end
		if cell.unit then UI:Safe(UpdateCell, cell) end
	end
	for _, device in ipairs(devices) do
		UI:Safe(ApplyLooks, device.health, device.power, device.cast and device.cast.bar)
		UI:Safe(UpdateDevice, device)
	end
	if UI:MoversUnlocked() then
		for _, header in pairs(headers) do header.holder:SetPreview(true) end
	end
	Kit:RefitShells()
end

-- Hub ------------------------------------------------------------------------------------------
local GROWTH_ITEMS = {{'down_right', 'Down, then right'}, {'down_left', 'Down, then left'}, {'up_right', 'Up, then right'},
	{'up_left', 'Up, then left'}, {'right_down', 'Right, then down'}, {'right_up', 'Right, then up'},
	{'left_down', 'Left, then down'}, {'left_up', 'Left, then up'}}
local Percent = UI.Util.Percent
local function Px(v) return format('%d px', v) end

local function RaidRows(key)
	local path = 'group.'..key..'.'
	return {
		{'slider', 'Width', path..'width', 40, 200, 1, nil, format = Px},
		{'slider', 'Height', path..'height', 20, 100, 1, nil, format = Px},
		{'slider', 'Spacing', path..'spacing', 0, 16, 1, 'Between members in a column.', format = Px},
		{'slider', 'Column spacing', path..'columnSpacing', 0, 30, 1, nil, format = Px},
		{'dropdown', 'Growth', path..'growth', items = GROWTH_ITEMS, note = 'Which way members fill, then which way new columns go.'},
		{'segmented', 'Group by', path..'groupBy', items = {{'GROUP', 'Group'}, {'ROLE', 'Role'}, {'CLASS', 'Class'}}},
		{'segmented', 'Sort', path..'sortMethod', items = {{'INDEX', 'Raid order'}, {'NAME', 'Name'}}},
		{'slider', 'Members per column', path..'unitsPerColumn', 1, 10, 1},
		{'slider', 'Columns', path..'maxColumns', 1, 8, 1},
		{'segmented', 'Power', path..'power', items = {{'healers', 'Healers'}, {'all', 'All'}, {'none', 'None'}}},
		{'segmented', 'Health text', path..'healthText', items = {{'none', 'None'}, {'percent', 'Percent'}}},
		{'slider', 'Scale', path..'scale', 0.5, 2, 0.05, nil, format = Percent},
	}
end

local function NotCustom() return UI.db.group.healthColor ~= 'custom' end
local function NoDispel() return not UI.db.group.dispel end
local function NoBoss() return not UI.db.group.bossDebuffs end
local function NoHots() return not UI.db.group.hots end
local function NoRange() return not UI.db.group.rangeFade end
local function NoTarget() return not UI.db.group.targetOutline end
local function NoPrivate() return not UI.db.group.privateAuras end
local function NoBossFrames() return not UI.db.group.boss.enable end
local function NoArenaFrames() return not UI.db.group.arena.enable end

UI:RegisterPage('group', {title = 'Raid, boss, arena', order = 16, cards = {
	{title = 'Group frames', rows = {
		{'segmented', 'Style', 'style.group', items = {{'device', 'Device'}, {'blizzard', 'Blizzard'}}, reload = true,
			note = 'Raid members as dark glass keys, boss and arena opponents as devices.', since = '0.5.0'},
		{'switch', 'Party as raid', 'group.partyAsRaid', 'Show the party as raid cells instead of party devices.', reload = true},
		{'switch', 'Hide Blizzard frames', 'group.hideBlizzard', 'Retire the game raid, boss and arena frames.', reload = true},
		{'button', 'Placement', 'Move frames', function() UI:ToggleHub(nil, false); UI:ToggleMovers() end,
			'Shows sample members to place the raid frames.'},
	}},
	{title = 'Raid up to 20', rows = RaidRows('small')},
	{title = 'Raid of 21 to 40', rows = RaidRows('large')},
	{title = 'Health', rows = {
		{'dropdown', 'Health color', 'group.healthColor', items = {{'class', 'Class'}, {'reaction', 'Reaction'}, {'accent', 'Key color'},
			{'custom', 'Custom'}, {'gradient2', 'Two-color gradient'}}},
		{'color', 'Gradient start', 'group.healthStart', since = '0.5.1', hidden = function() return DB().healthColor ~= 'gradient2' end},
		{'color', 'Gradient end', 'group.healthEnd', since = '0.5.1', hidden = function() return DB().healthColor ~= 'gradient2' end},
		{'segmented', 'Gradient direction', 'group.healthDirection', items = {{'horizontal', 'Along'}, {'vertical', 'Up'}}, since = '0.5.1',
			hidden = function() return DB().healthColor ~= 'gradient2' end},
		{'note', 'Power and cast colors follow the Colors card on the Unit frames page.'},
		{'color', 'Custom color', 'group.customColor', 'Used when health color is Custom.', hidden = NotCustom},
		{'switch', 'Fade out of range', 'group.rangeFade', 'Members beyond 40 yards dim.'},
		{'slider', 'Out of range opacity', 'group.rangeAlpha', 0.1, 1, 0.05, nil, format = Percent, disabled = NoRange},
		{'switch', 'Incoming heals', 'group.healPrediction', 'Heals on the way, as a green run after the health.'},
		{'switch', 'Absorbs', 'group.absorbs', 'Shields, as a pale run after the heals.'},
		{'slider', 'Name size', 'group.nameSize', 7, 14, 1},
		{'dropdown', 'Health texture', 'group.healthTexture', items = FillItems, since = '0.5.1',
			note = 'As on the unit frames: Flat, Solid, Gloss, Gradient, Glass, Segmented, or another addon\'s status bar texture.'},
		{'dropdown', 'Power texture', 'group.powerTexture', items = FillItems, since = '0.5.1'},
		{'dropdown', 'Cast texture', 'group.castTexture', items = FillItems, since = '0.5.1', note = 'Boss and arena cast bars.'},
		{'segmented', 'Track', 'group.track', items = TRACK_ITEMS, since = '0.5.1',
			note = 'Behind the fill: housing, a black screen, a dim wash of the fill\'s color, or nothing.'},
		{'switch', 'Status text', 'group.statusText', 'DEAD, OFF and AFK on the key.'},
	}},
	{title = 'Indicators', rows = {
		{'switch', 'Role', 'group.roleIcon', 'Tank, healer or damage badge.'},
		{'switch', 'Leader', 'group.leader', 'A crown on the group leader.'},
		{'switch', 'Raid marker', 'group.raidIcon'},
		{'switch', 'Ready check', 'group.readyCheck'},
		{'switch', 'Summon', 'group.summon'},
		{'switch', 'Resurrection', 'group.resurrect'},
		{'switch', 'Phasing', 'group.phase', 'Members in another phase or shard.'},
		{'switch', 'Target outline', 'group.targetOutline', 'A ring around your target.'},
		{'color', 'Target outline color', 'group.targetColor', nil, disabled = NoTarget},
	}},
	{title = 'Auras', rows = {
		{'switch', 'Dispel ring', 'group.dispel', 'A ring in the debuff type color.'},
		{'switch', 'Only what you can dispel', 'group.dispelOnly', nil, disabled = NoDispel},
		{'color', 'Magic', 'group.dispelColors.magic', nil, disabled = NoDispel},
		{'color', 'Curse', 'group.dispelColors.curse', nil, disabled = NoDispel},
		{'color', 'Disease', 'group.dispelColors.disease', nil, disabled = NoDispel},
		{'color', 'Poison', 'group.dispelColors.poison', nil, disabled = NoDispel},
		{'color', 'Bleed', 'group.dispelColors.bleed', nil, disabled = NoDispel},
		{'switch', 'Boss debuffs', 'group.bossDebuffs', 'Important debuffs in the middle of the key.'},
		{'slider', 'Boss debuff size', 'group.bossDebuffSize', 10, 32, 1, nil, format = Px, disabled = NoBoss},
		{'switch', 'Your heals over time', 'group.hots', 'Small icons in the corner.'},
		{'slider', 'How many', 'group.hotCount', 1, 5, 1, nil, disabled = NoHots},
		{'slider', 'Heal over time size', 'group.hotSize', 6, 18, 1, nil, format = Px, disabled = NoHots},
		{'switch', 'Private auras', 'group.privateAuras', 'Encounter auras the game draws itself.', reload = true},
		{'slider', 'Private aura size', 'group.privateSize', 10, 32, 1, nil, format = Px, disabled = NoPrivate},
	}},
	{title = 'Boss frames', rows = {
		{'switch', 'Boss frames', 'group.boss.enable', 'Bosses 1 to 5 as devices.', reload = true},
		{'slider', 'Width', 'group.boss.width', 120, 320, 1, nil, format = Px, disabled = NoBossFrames},
		{'slider', 'Height', 'group.boss.height', 32, 80, 1, nil, format = Px, disabled = NoBossFrames},
		{'slider', 'Spacing', 'group.boss.spacing', 4, 60, 1, 'Leaves room for the cast strip.', format = Px, disabled = NoBossFrames},
		{'segmented', 'Growth', 'group.boss.growth', items = {{'down', 'Down'}, {'up', 'Up'}}, disabled = NoBossFrames},
		{'switch', 'Cast strip', 'group.boss.castbar', nil, reload = true, disabled = NoBossFrames},
		{'switch', 'Your debuffs', 'group.boss.auras', nil, disabled = NoBossFrames},
		{'slider', 'Scale', 'group.boss.scale', 0.5, 2, 0.05, nil, format = Percent, disabled = NoBossFrames},
	}},
	{title = 'Arena frames', rows = {
		{'switch', 'Arena frames', 'group.arena.enable', 'Opponents 1 to 5 as devices.', reload = true},
		{'slider', 'Width', 'group.arena.width', 120, 320, 1, nil, format = Px, disabled = NoArenaFrames},
		{'slider', 'Height', 'group.arena.height', 32, 80, 1, nil, format = Px, disabled = NoArenaFrames},
		{'slider', 'Spacing', 'group.arena.spacing', 4, 60, 1, nil, format = Px, disabled = NoArenaFrames},
		{'segmented', 'Growth', 'group.arena.growth', items = {{'down', 'Down'}, {'up', 'Up'}}, disabled = NoArenaFrames},
		{'switch', 'Cast strip', 'group.arena.castbar', nil, reload = true, disabled = NoArenaFrames},
		{'switch', 'Spec', 'group.arena.spec', 'The opponent spec, also before the gates open.', disabled = NoArenaFrames},
		{'switch', 'Trinket', 'group.arena.trinket', 'Their crowd control trinket and its cooldown.', disabled = NoArenaFrames},
		{'switch', 'Your debuffs', 'group.arena.auras', nil, disabled = NoArenaFrames},
		{'slider', 'Scale', 'group.arena.scale', 0.5, 2, 0.05, nil, format = Percent, disabled = NoArenaFrames},
	}},
}})
