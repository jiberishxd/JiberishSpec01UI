-- Unit frames: status lamps, auras, range and motion. Part of the unit frames
-- (UnitFrames.lua).
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown, GetTime = CreateFrame, UIParent, InCombatLockdown, GetTime
local floor, max, min, sin, pi = math.floor, math.max, math.min, math.sin, math.pi
local P = UI.UnitFrameParts
local IsSecret, Plain = UI.Util.IsSecret, UI.Util.PlainCall
local casts, Cfg, DB, IMMEDIATE, Indicators, ordered = P.casts, P.Cfg, P.DB, P.IMMEDIATE, P.Indicators, P.ordered
local TIMER, UpdateCombat, UpdateHealth, UpdateIndicators, UpdateName, UpdatePower = P.TIMER, P.UpdateCombat, P.UpdateHealth, P.UpdateIndicators, P.UpdateName, P.UpdatePower

-- Status lamps -------------------------------------------------------------------------
-- SPEC-01 glyphs for the unit's state, lit in their color while it holds:
-- combat, resting (you only), group leader, role and PvP. 'lit' shows only the
-- lit ones; 'panel' prints every glyph and leaves the idle ones unlit, like a
-- device's status row. Combat may be secret: its glyph is then lit straight
-- from the answer (SetAlphaFromBoolean), never tested.
-- Kept in a block of its own: the main chunk may hold at most 200 locals.
local STATUS_EVENTS, StatusMode, UpdateStatus, PlaceStatus
do
local STATUS = {
	{key = 'combat', icon = 'warning', token = 'red'},
	{key = 'rest', icon = 'pause', token = 'ledGreen', player = true},
	{key = 'lead', icon = 'tri-up', token = 'amber'},
	{key = 'role', icon = 'user', token = 'ledBlue'},
	{key = 'pvp', icon = 'power', token = 'red'},
}
local ROLE_TOKENS = {TANK = 'ledBlue', HEALER = 'ledGreen', DAMAGER = 'red'}
STATUS_EVENTS = {UNIT_FLAGS = true, UNIT_FACTION = true, PLAYER_UPDATE_RESTING = true, PLAYER_FLAGS_CHANGED = true,
	PARTY_LEADER_CHANGED = true, PLAYER_ROLES_ASSIGNED = true, GROUP_ROSTER_UPDATE = true,
	PLAYER_REGEN_DISABLED = true, PLAYER_REGEN_ENABLED = true}

function StatusMode(frame)
	if frame.layout.size ~= 'large' then return 'off' end
	if frame.shapeName == 'console' then return 'panel' end
	return Cfg(frame).status or 'off'
end

local function StatusRow(frame)
	local row = frame.status
	if row then return row end
	row = CreateFrame('Frame', nil, frame.overlay)
	row:EnableMouse(false)
	row:SetSize(64, 9)
	row.size, row.grow, row.icons = 9, 'RIGHT', {}
	for _, info in ipairs(STATUS) do
		if not info.player or frame.unit == 'player' then
			local icon = Kit:Icon(row, info.icon, 9, 'ledOff')
			row.icons[#row.icons + 1] = {texture = icon, info = info}
		end
	end
	frame.status = row
	return row
end

-- A plain true/false, or a secret (combat only); role also returns the role.
local function StatusValue(frame, key)
	local unit = frame.unit
	if key == 'combat' then
		if unit == 'player' and frame.combatEvent ~= nil then return frame.combatEvent end
		local ok, value = pcall(UnitAffectingCombat, unit)
		if not ok then return false end
		return value
	elseif key == 'rest' then
		return Plain(IsResting) == true
	elseif key == 'lead' then
		return Plain(UnitIsGroupLeader, unit) == true
	elseif key == 'role' then
		local role = Plain(UnitGroupRolesAssigned, unit)
		return (role and ROLE_TOKENS[role]) and true or false, role
	elseif key == 'pvp' then
		return Plain(UnitIsPVP, unit) == true or Plain(UnitIsPVPFreeForAll, unit) == true
	end
	return false
end

function UpdateStatus(frame)
	local mode = StatusMode(frame)
	local row = frame.status
	if mode == 'off' then
		if row then row:Hide() end
		return
	end
	row = StatusRow(frame)
	row:Show()
	local size, gap, grow = row.size, 3, row.grow
	local from, to = grow == 'LEFT' and 'RIGHT' or 'LEFT', grow == 'LEFT' and 'LEFT' or 'RIGHT'
	local previous
	for _, entry in ipairs(row.icons) do
		local icon, info = entry.texture, entry.info
		local value, role = StatusValue(frame, info.key)
		local token = (info.key == 'role' and role and ROLE_TOKENS[role]) or info.token
		local shown
		if IsSecret(value) then
			Kit:Tint(icon, token)
			if icon.SetAlphaFromBoolean then icon:SetAlphaFromBoolean(value, 1, mode == 'panel' and 0.3 or 0) end
			shown = true
		else
			local lit = value == true
			Kit:Tint(icon, lit and token or 'ledOff')
			icon:SetAlpha(lit and 1 or 0.75)
			shown = lit or mode == 'panel'
		end
		icon:ClearAllPoints()
		icon:SetShown(shown)
		if shown then
			icon:SetSize(size, size)
			if previous then icon:SetPoint(from, previous, to, grow == 'LEFT' and -gap or gap, 0)
			else icon:SetPoint(from, row, from, 0, 0) end
			previous = icon
		end
	end
end

-- Where the row sits: point on the row, the region and its point, and which way it grows.
function PlaceStatus(frame, point, region, relative, x, y, grow, size)
	if StatusMode(frame) == 'off' then
		if frame.status then frame.status:Hide() end
		return
	end
	local row = StatusRow(frame)
	row.size, row.grow = size or 9, grow or 'RIGHT'
	row:SetSize(5 * ((size or 9) + 3), size or 9)
	row:ClearAllPoints()
	row:SetPoint(point, region, relative, x or 0, y or 0)
	row:SetFrameLevel(frame.overlay:GetFrameLevel() + 2)
	UpdateStatus(frame)
end

end
-- Auras --------------------------------------------------------------------------------
-- Aura fields may be secret: only the data table itself is tested, the icon goes
-- straight to SetTexture, a secret stack count is formatted by the client, and
-- the timer runs from the client's duration object.
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

-- The timer line over a key runs on the same duration object (the client moves
-- it); without one, a plain expiry drives it at 10 Hz. An aura known to last
-- forever has no line; a secret length keeps it.
local function AuraTimer(icon, unit, data)
	local cooldown, line = icon.cooldown, icon.line
	local lines = DB().auraLines
	local id = data.auraInstanceID
	local length = data.duration
	local permanent = not IsSecret(length) and (not length or length <= 0)
	line:SetScript('OnUpdate', nil)
	if C_UnitAuras.GetAuraDuration and cooldown.SetCooldownFromDurationObject and not IsSecret(id) then
		local ok, duration = pcall(C_UnitAuras.GetAuraDuration, unit, id)
		if ok and duration then
			cooldown:SetCooldownFromDurationObject(duration)
			if lines and not permanent and line.SetTimerDuration and TIMER then
				line:SetTimerDuration(duration, IMMEDIATE, TIMER.RemainingTime)
				line:SetAlpha(1)
				-- A secret length may still be an aura that lasts forever: the
				-- duration says so itself, and that answer only reaches alpha.
				if IsSecret(length) and duration.IsZero and line.SetAlphaFromBoolean then
					local okZero, zero = pcall(duration.IsZero, duration)
					if okZero then
						if IsSecret(zero) then line:SetAlphaFromBoolean(zero, 0, 1)
						elseif zero then line:SetAlpha(0) end
					end
				end
				line:Show()
			else
				line:Hide()
			end
			return
		end
	end
	local expires = data.expirationTime
	if IsSecret(expires) or IsSecret(length) or not expires or not length or length <= 0 then
		cooldown:Clear()
		line:Hide()
		return
	end
	cooldown:SetCooldown(expires - length, length)
	if not lines then line:Hide() return end
	line:SetMinMaxValues(0, length)
	local wait = 1
	line:SetScript('OnUpdate', function(self, elapsed)
		wait = wait + elapsed
		if wait < 0.1 then return end
		wait = 0
		self:SetValue(max(expires - GetTime(), 0))
	end)
	line:Show()
end

-- The line's color: the debuff's type, a plain red for other harm, green for help.
local function PaintAuraLine(icon, data, harmful)
	if not harmful then icon.line:SetStatusBarColor(Kit:RGB('green')) return end
	local kind = data.dispelName
	local color = not IsSecret(kind) and kind and DebuffTypeColor and DebuffTypeColor[kind]
	if color then icon.line:SetStatusBarColor(color.r, color.g, color.b)
	else icon.line:SetStatusBarColor(Kit:RGB('red')) end
end

local function AuraKey(frame, index)
	local icon = CreateFrame('Frame', nil, frame.face)
	icon.shell = Kit:Shell(icon, {surface = 'glass', radius = 4, shadowAlpha = 0.25})
	icon.texture = icon:CreateTexture(nil, 'ARTWORK')
	icon.texture:SetPoint('TOPLEFT', 2, -2)
	icon.texture:SetPoint('BOTTOMRIGHT', -2, 2)
	icon.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	icon.mask = icon:CreateMaskTexture()
	icon.mask:SetTexture(Kit.media..'mask-icon.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
	icon.mask:SetAllPoints(icon.texture)
	icon.texture:AddMaskTexture(icon.mask)
	icon.cooldown = CreateFrame('Cooldown', nil, icon, 'CooldownFrameTemplate')
	icon.cooldown:SetAllPoints(icon.texture)
	if icon.cooldown.SetDrawEdge then icon.cooldown:SetDrawEdge(false) end
	if icon.cooldown.SetSwipeTexture then icon.cooldown:SetSwipeTexture(Kit.media..'mask-icon.tga', 0, 0, 0, 0.7) end
	icon.count = Kit:Text(icon, '', 'small', 'white', true, true)
	icon.count:SetPoint('BOTTOMRIGHT', 2, -1)
	icon.count:SetDrawLayer('OVERLAY', 7)
	-- The timer line riding just above the key.
	icon.line = CreateFrame('StatusBar', nil, icon)
	icon.line:SetPoint('BOTTOMLEFT', icon, 'TOPLEFT', 2, 1)
	icon.line:SetPoint('BOTTOMRIGHT', icon, 'TOPRIGHT', -2, 1)
	icon.line:SetHeight(2)
	icon.line:SetStatusBarTexture([[Interface\Buttons\WHITE8X8]])
	icon.line:SetMinMaxValues(0, 1)
	icon.line.back = icon.line:CreateTexture(nil, 'BACKGROUND')
	icon.line.back:SetAllPoints()
	icon.line.back:SetColorTexture(0, 0, 0, 0.45)
	icon.line:Hide()
	icon:Hide()
	frame.auras[index] = icon
	return icon
end

-- How far below the frame its auras start: past a cast bar placed under it and
-- the class resource rail.
local function BelowOffset(frame)
	local offset = 6
	local castCfg = DB().cast[frame.unit]
	if casts[frame.unit] and castCfg and castCfg.position == 'under' then offset = offset + (castCfg.height or 30) + 6 end
	if frame.lampRail and Cfg(frame).classPower then offset = offset + (Cfg(frame).lampSize or 6) + 12 end
	return offset
end

-- The cooldown's own countdown, small and fitted: mono numbers with an
-- outline, along the key's foot so a long time ("49m", "1h") stays inside.
-- The client may re-apply the cooldown's countdown font object, so that object
-- is ours too: one per size, in the reference's bold mono with an outline.
local clockFonts = {}
local function AuraClock(icon, cfg, size)
	local cooldown = icon.cooldown
	local fontSize = min(cfg.auraTimeSize or 8, max(6, floor(size * 0.5)))
	if cooldown.SetCountdownFont and CreateFont then
		local name = 'JiberishSpec01AuraClock'..fontSize
		local font = clockFonts[fontSize] or _G[name] or CreateFont(name)
		font:SetFont(Kit:FontPath(true), fontSize, 'OUTLINE')
		clockFonts[fontSize] = font
		pcall(cooldown.SetCountdownFont, cooldown, name)
	end
	local text = cooldown.GetCountdownFontString and cooldown:GetCountdownFontString()
	if not text then return end
	Kit:Font(text, fontSize, 'OUTLINE', true)
	text:SetShadowOffset(0, 0)
	text:ClearAllPoints()
	text:SetPoint('BOTTOM', icon, 'BOTTOM', 0, 1)
	text:SetJustifyH('CENTER')
	text:SetTextColor(1, 1, 1)
end

local function LayoutAuras(frame)
	local cfg = Cfg(frame)
	local count = (DB().auras and cfg.auras) and max(0, min(cfg.auraMax or 8, 40)) or 0
	-- An embedded small frame's bay has no room for auras.
	if frame.embedded and frame.layout.size ~= 'large' then count = 0 end
	frame.auras = frame.auras or {}
	for index = #frame.auras + 1, count do AuraKey(frame, index) end
	local size, gap = cfg.auraSize or 22, 4
	local perRow = max(1, cfg.auraPerRow or 8)
	local position, leftward = cfg.auraPosition or 'below', cfg.auraGrow == 'left'
	local below = BelowOffset(frame)
	for index, icon in ipairs(frame.auras) do
		icon:SetSize(size, size)
		Kit:Font(icon.count, cfg.stackSize or 10, nil, true)
		if icon.cooldown.SetHideCountdownNumbers then icon.cooldown:SetHideCountdownNumbers(not cfg.auraTime) end
		AuraClock(icon, cfg, size)
		if icon.cooldown.SetDrawSwipe then icon.cooldown:SetDrawSwipe(cfg.auraSwipe and true or false) end
		local column, row = (index - 1) % perRow, floor((index - 1) / perRow)
		local x, y = column * (size + gap), row * (size + gap)
		icon:ClearAllPoints()
		if position == 'above' then
			if leftward then icon:SetPoint('BOTTOMRIGHT', frame.face, 'TOPRIGHT', -x, 6 + y)
			else icon:SetPoint('BOTTOMLEFT', frame.face, 'TOPLEFT', x, 6 + y) end
		elseif position == 'right' then
			icon:SetPoint('TOPLEFT', frame.face, 'TOPRIGHT', 6 + x, -y)
		elseif position == 'left' then
			icon:SetPoint('TOPRIGHT', frame.face, 'TOPLEFT', -6 - x, -y)
		else
			if leftward then icon:SetPoint('TOPRIGHT', frame.face, 'BOTTOMRIGHT', -x, -below - y)
			else icon:SetPoint('TOPLEFT', frame.face, 'BOTTOMLEFT', x, -below - y) end
		end
		if index > count then icon:Hide() end
	end
	frame.auraCount = count
end

local function UpdateDispel(frame)
	if not frame.dispel then return end
	if not Indicators().dispel or not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then frame.dispel:Hide() return end
	local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, frame.unit, 1, 'HARMFUL|RAID')
	if not ok or type(data) ~= 'table' then frame.dispel:Hide() return end
	local kind = data.dispelName
	local color = not IsSecret(kind) and kind and DebuffTypeColor and DebuffTypeColor[kind]
	if color then frame.dispel:SetVertexColor(color.r, color.g, color.b, 0.95)
	else frame.dispel:SetVertexColor(0.64, 0.19, 0.79, 0.95) end
	frame.dispel:Show()
end

local function UpdateAuras(frame)
	UpdateDispel(frame)
	if not frame.auras or not C_UnitAuras or not C_UnitAuras.GetAuraDataByIndex then return end
	local cfg = Cfg(frame)
	local count = frame.auraCount or 0
	local slot = 1
	local filters = {}
	if cfg.debuffs then filters[#filters + 1] = cfg.onlyMine and 'HARMFUL|PLAYER' or 'HARMFUL' end
	if cfg.buffs then filters[#filters + 1] = cfg.onlyMine and 'HELPFUL|PLAYER' or 'HELPFUL' end
	for _, filter in ipairs(filters) do
		for index = 1, 40 do
			if slot > count then break end
			local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, frame.unit, index, filter)
			if not ok or type(data) ~= 'table' then break end
			-- Boss auras only: a secret answer counts as no.
			local boss = data.isBossAura
			if not cfg.bossOnly or (not IsSecret(boss) and boss) then
				local icon = frame.auras[slot]
				icon.texture:SetTexture(data.icon)
				local countOk, stack = pcall(AuraCount, frame.unit, data)
				if countOk then icon.count:SetText(stack) else icon.count:SetText('') end
				if not pcall(AuraTimer, icon, frame.unit, data) then icon.cooldown:Clear(); icon.line:Hide() end
				local harmful = filter:find('HARMFUL') and true or false
				pcall(PaintAuraLine, icon, data, harmful)
				local surface = harmful and 'glass' or 'paper'
				if icon.surface ~= surface then
					icon.surface = surface
					Kit:SetSurface(icon.shell, surface)
				end
				icon:Show()
				slot = slot + 1
			end
		end
	end
	for index = slot, #frame.auras do frame.auras[index]:Hide() end
end

local function UpdateAll(frame, polled)
	if not UnitExists(frame.unit) then return end
	UpdateName(frame, polled)
	UpdateHealth(frame)
	UpdatePower(frame)
	UpdateAuras(frame)
	UpdateCombat(frame)
	UpdateIndicators(frame)
	if frame.status then UpdateStatus(frame) end
end

-- Range ---------------------------------------------------------------------------------
-- Group members: the client's range answer, straight into the alpha. Hostile
-- units: a known ranged spell of the class. Others stay at full alpha.
-- Kept in a block of its own: the main chunk may hold at most 200 locals.
local FindRangeSpell, UpdateRangeDriver
do
local RANGE_SPELLS = {
	DEATHKNIGHT = {47541, 49576}, DEMONHUNTER = {185123}, DRUID = {8921, 5176}, EVOKER = {361469}, HUNTER = {185358, 75},
	MAGE = {116, 133, 30451}, MONK = {117952, 115546}, PALADIN = {20271, 62124}, PRIEST = {589, 585}, ROGUE = {185763, 114014},
	SHAMAN = {188196, 403}, WARLOCK = {686, 232670}, WARRIOR = {355, 57755},
}
local rangeSpell
function FindRangeSpell()
	rangeSpell = nil
	local _, class = UnitClass('player')
	for _, id in ipairs(RANGE_SPELLS[class] or {}) do
		local known = (C_SpellBook and Plain(C_SpellBook.IsSpellKnown, id)) or Plain(IsSpellKnown, id)
		if known then rangeSpell = id return end
	end
end

-- Range dims the frame's face, not the frame: the frame's own alpha belongs to
-- the idle fade and unlock mode, and two owners of one alpha made it flicker.
local function Fade(frame, inRange, alpha)
	frame.ranged = true
	local target = frame.face or frame
	if IsSecret(inRange) then
		if target.SetAlphaFromBoolean then pcall(target.SetAlphaFromBoolean, target, inRange, 1, alpha) end
		return
	end
	local want = inRange and 1 or alpha
	if Kit:Animating(target) then return end
	local current = target:GetAlpha()
	if IsSecret(current) or math.abs(current - want) > 0.01 then target:SetAlpha(want) end
end

local function ApplyRange(frame)
	local unit, alpha = frame.unit, Cfg(frame).rangeAlpha or 0.45
	-- The console hides docked frames in pet battles by alpha; leave them be.
	if C_PetBattles and Plain(C_PetBattles.IsInBattle) then return end
	if Plain(UnitExists, unit) ~= true then return end
	local grouped = frame.layout.party or Plain(UnitInParty, unit) or Plain(UnitInRaid, unit)
	if grouped and UnitInRange then
		local inRange, checked = UnitInRange(unit)
		if not IsSecret(checked) and not checked then return Fade(frame, true, alpha) end
		return Fade(frame, inRange, alpha)
	end
	if rangeSpell and C_Spell and C_Spell.IsSpellInRange and Plain(UnitCanAttack, 'player', unit) then
		local ok, inRange = pcall(C_Spell.IsSpellInRange, rangeSpell, unit)
		if ok and (IsSecret(inRange) or inRange ~= nil) then return Fade(frame, inRange, alpha) end
	end
	Fade(frame, true, alpha)
end

local rangeDriver = CreateFrame('Frame')
local rangeElapsed = 0
local function RangeTick(_, delta)
	rangeElapsed = rangeElapsed + delta
	if rangeElapsed < 0.2 then return end
	rangeElapsed = 0
	for _, frame in ipairs(ordered) do
		if Cfg(frame).rangeFade then
			if frame:IsVisible() then UI:Safe(ApplyRange, frame) end
		elseif frame.ranged then
			frame.ranged = nil
			local face = frame.face or frame
			face:SetAlpha(1)
		end
	end
end

function UpdateRangeDriver()
	local any = false
	for _, frame in ipairs(ordered) do
		if Cfg(frame).rangeFade or frame.ranged then any = true break end
	end
	rangeDriver:SetScript('OnUpdate', any and RangeTick or nil)
end
end

-- Motion -------------------------------------------------------------------------------
-- A target arriving from nothing (never on a swap): the frame fades in, its bars
-- glide up from zero, and the portrait swells about 10% past full and settles.
-- Only this addon's own inner pieces move, so it is safe in combat.
local function Arrive(frame)
	if not DB().arrive or not Cfg(frame).arrive or Kit:DB().reduceMotion then return end
	frame.face:SetAlpha(0)
	Kit:FadeTo(frame.face, 1, 'NORMAL')
	frame.health:SetValue(0, IMMEDIATE)
	if frame.power then frame.power:SetValue(0, IMMEDIATE) end
	C_Timer.After(0, function() UI:Safe(UpdateHealth, frame); UI:Safe(UpdatePower, frame) end)
	-- The pop scales the portrait; a 3D model drawn mid-scale renders off-centre,
	-- so a model only fades in (the face fade above) and is drawn at full size.
	if frame.portraitHolder and frame.portraitSlot:IsShown() and frame.portraitMode ~= 'model' then
		local holder = frame.portraitHolder
		Kit:Animate(holder, 0.4, 0, 1, function(e)
			holder:SetScale(max(0.6 + 0.4 * (e + 0.1 * sin(pi * e)), 0.01))
		end, function() holder:SetScale(1) end, 'linear')
	end
end

-- A light runs along the top edge of each frame as combat starts (key color,
-- quick) and ends (amber, slower), one frame after another.
local function Sweep(frame, token, duration, peak)
	local light = frame.sweep
	if not light or not frame:IsVisible() or not Cfg(frame).sweep then return end
	local width = frame:GetWidth()
	Kit:Tint(light, token)
	Kit:Animate(light, duration, 0, 1, function(t)
		light:ClearAllPoints()
		light:SetPoint('CENTER', frame.face, 'TOPLEFT', -20 + (width + 40) * Kit.ease.cubic(t), -1)
		local alpha = t < 0.15 and t / 0.15 or t > 0.75 and (1 - t) / 0.25 or 1
		light:SetAlpha(alpha * peak)
	end, function() light:SetAlpha(0) end, 'linear')
end

-- The combat cue module marks combat itself; while it is on, this light stands down.
local function CueTraces()
	local cue = UI.db.combatcue
	return type(cue) == 'table' and cue.enable and true or false
end

local function SweepAll(token, duration, peak)
	if not DB().combatSweep or Kit:DB().reduceMotion or CueTraces() then return end
	for index, frame in ipairs(ordered) do
		C_Timer.After(min((index - 1) * 0.035, 0.5), function() Sweep(frame, token, duration, peak) end)
	end
end


-- Shared with the other action bar files.
P.Arrive = Arrive
P.BelowOffset = BelowOffset
P.FindRangeSpell = FindRangeSpell
P.LayoutAuras = LayoutAuras
P.PlaceStatus = PlaceStatus
P.STATUS_EVENTS = STATUS_EVENTS
P.StatusMode = StatusMode
P.SweepAll = SweepAll
P.UpdateAll = UpdateAll
P.UpdateAuras = UpdateAuras
P.UpdateRangeDriver = UpdateRangeDriver
P.UpdateStatus = UpdateStatus
