-- Unit frames: the avatars (portraits) and the indicators. Part of the unit
-- frames (UnitFrames.lua).
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown, GetTime = CreateFrame, UIParent, InCombatLockdown, GetTime
local floor, max, min, sin, pi = math.floor, math.max, math.min, math.sin, math.pi
local P = UI.UnitFrameParts
local IsSecret, Plain = UI.Util.IsSecret, UI.Util.PlainCall
local CLASS_ICONS, ClassColor, DB, DrawModel, Indicators, ReactionColor = P.CLASS_ICONS, P.ClassColor, P.DB, P.DrawModel, P.Indicators, P.ReactionColor
local RefreshModel, UpdateTag, VerifyModel = P.RefreshModel, P.UpdateTag, P.VerifyModel

-- Avatars ---------------------------------------------------------------------------
-- SPEC-01's component 35 and its relatives, as portrait styles. The reference's
-- avatar is a small LED matrix behind a round black lens in a light bezel; each
-- person's glyph is worked out from their name (FNV-1a, mirrored, kept inside
-- the lens) so it never changes. Here a colored ring sits between bezel and
-- lens (reaction, class or key color) and a presence lamp sits on the rim:
-- green online, red in combat, amber away, unlit when dead or offline.
--   matrix:   the reference's LED glyph
--   monogram: the unit's initials in Plex Mono on the lens
--   ring:     the 2D portrait in the round lens
--   glyph:    the class icon in the round lens
--   key:      the 2D portrait on a rounded-square key
-- Names and GUIDs are used only when plain; a secret name falls back to the
-- class (matrix) or the class icon (monogram).
local AVATARS = {matrix = true, monogram = true, ring = true, glyph = true, key = true}
-- Events that can change the presence lamp.
local AVATAR_EVENTS = {UNIT_HEALTH = true, UNIT_CONNECTION = true, UNIT_FLAGS = true, PLAYER_FLAGS_CHANGED = true}
local IsAvatar, ShowAvatar, UpdateAvatar, AvatarStatus
do
local MATRIX = 7
local function Disc(parent, sublevel)
	local texture = parent:CreateTexture(nil, 'BORDER', nil, sublevel)
	texture:SetTexture(Kit.media..'mask-round.tga')
	return texture
end

local function Xor8(a, b)
	local result, place = 0, 1
	for _ = 1, 8 do
		local x, y = a % 2, b % 2
		if x ~= y then result = result + place end
		a, b, place = (a - x) / 2, (b - y) / 2, place * 2
	end
	return result
end

-- FNV-1a over the bytes, kept exact in doubles: the multiply by 16777619
-- (2^24 + 403) is split so no step passes 2^53.
local function Fnv(text)
	local hash = 2166136261
	for index = 1, #text do
		local low = hash % 256
		hash = hash - low + Xor8(low, text:byte(index))
		hash = ((hash % 256) * 16777216 + hash * 403) % 4294967296
	end
	return hash
end

local function Lit(hash, row, column)
	local half = column < 4 and column or MATRIX - 1 - column
	local shift = (row * 4 + half) % 31
	local bit = floor(hash / 2 ^ shift) % 2
	local inside = math.sqrt((row - 3) ^ 2 + (column - 3) ^ 2) <= 3.2
	return inside and (bit == 1 or (row == 3 and half == 3)), inside
end

local function Seed(unit)
	local name = UnitName(unit)
	if not IsSecret(name) and type(name) == 'string' and name ~= '' then return name end
	local guid = Plain(UnitGUID, unit)
	if type(guid) == 'string' then return guid end
	local _, class = UnitClass(unit)
	if not IsSecret(class) and class then return class end
	return 'SPEC-01'
end

local function Initials(unit)
	local name = UnitName(unit)
	if IsSecret(name) or type(name) ~= 'string' or name == '' then return nil end
	local letters = ''
	for word in name:gmatch('%S+') do
		local first = word:match('^[%z\1-\127\194-\244][\128-\191]*')
		if first then letters = letters..first end
		if #letters >= 2 then break end
	end
	return letters ~= '' and strupper(letters) or nil
end

local function Build(frame)
	local avatar = frame.avatar
	if avatar then return avatar end
	avatar = CreateFrame('Frame', nil, frame.portraitHolder)
	avatar:SetAllPoints(frame.portraitHolder)
	avatar:EnableMouse(false)
	-- Round: an outline, the light bezel, the colored ring, the black lens.
	avatar.outline = Disc(avatar, -4)
	avatar.outline:SetVertexColor(0, 0, 0, 0.18)
	avatar.bezel = Disc(avatar, -3)
	if avatar.bezel.SetGradient and CreateColor then
		avatar.bezel:SetGradient('VERTICAL', CreateColor(0.9, 0.9, 0.89, 1), CreateColor(1, 1, 1, 1))
	end
	avatar.ring = Disc(avatar, -2)
	avatar.lens = Disc(avatar, -1)
	if avatar.lens.SetGradient and CreateColor then
		avatar.lens:SetGradient('VERTICAL', CreateColor(0.04, 0.04, 0.04, 1), CreateColor(0.11, 0.11, 0.11, 1))
	end
	avatar.roundMask = avatar:CreateMaskTexture()
	avatar.roundMask:SetTexture(Kit.media..'mask-round.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
	avatar.roundMask:SetAllPoints(avatar.lens)
	-- Square key: a light key with a recessed screen.
	avatar.keyFrame = CreateFrame('Frame', nil, avatar)
	avatar.keyFrame:SetAllPoints()
	avatar.keyFrame.shell = Kit:Shell(avatar.keyFrame, {surface = 'paper', radius = 6, shadowAlpha = 0.25})
	avatar.keyScreen = CreateFrame('Frame', nil, avatar.keyFrame)
	avatar.keyScreen.shell = Kit:Shell(avatar.keyScreen, {surface = 'screen', radius = 4, shadow = false})
	avatar.keyMask = avatar:CreateMaskTexture()
	avatar.keyMask:SetTexture(Kit.media..'mask-icon.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
	avatar.keyMask:SetAllPoints(avatar.keyScreen)
	-- Content.
	avatar.content = CreateFrame('Frame', nil, avatar)
	avatar.content:SetAllPoints()
	avatar.content:SetFrameLevel(avatar.keyScreen:GetFrameLevel() + 2)
	avatar.picture = avatar.content:CreateTexture(nil, 'ARTWORK')
	avatar.initials = Kit:Text(avatar.content, '', 12, 'darkInk', true)
	avatar.initials:SetPoint('CENTER', avatar.lens, 'CENTER', 0, 0)
	avatar.dots = {}
	for index = 1, MATRIX * MATRIX do
		local dot = avatar.content:CreateTexture(nil, 'ARTWORK', nil, 1)
		dot:SetColorTexture(1, 1, 1, 1)
		avatar.dots[index] = dot
	end
	-- Presence lamp on the rim, in a collar of the panel's color.
	avatar.collar = Disc(avatar.content, 2)
	avatar.collar:SetDrawLayer('OVERLAY', 1)
	avatar.led = Kit:Led(avatar.content, 6, true)
	avatar:HookScript('OnSizeChanged', function() if frame.avatarStyle then UI:Safe(UpdateAvatar, frame) end end)
	frame.avatar = avatar
	return avatar
end

local function Around(texture, avatar, inset)
	texture:ClearAllPoints()
	texture:SetPoint('TOPLEFT', avatar, 'TOPLEFT', inset, -inset)
	texture:SetPoint('BOTTOMRIGHT', avatar, 'BOTTOMRIGHT', -inset, inset)
end

local function RingColor(frame)
	local mode = DB().avatarRing
	if mode == 'class' then return ClassColor(frame.unit) end
	if mode == 'key' and Kit:DB().accent ~= 'class' then return Kit:RGB('lamp') end
	if mode == 'key' then return ClassColor(frame.unit) end
	return ReactionColor(frame.unit)
end

function IsAvatar(mode) return AVATARS[mode] and true or false end

-- Show or hide the avatar parts for a portrait mode; returns true when one shows.
function ShowAvatar(frame, mode)
	if not AVATARS[mode] then
		if frame.avatar then frame.avatar:Hide() end
		frame.avatarStyle = nil
		return false
	end
	local avatar = Build(frame)
	frame.avatarStyle = mode
	avatar:Show()
	return true
end

function AvatarStatus(frame)
	local avatar = frame.avatar
	if not (avatar and avatar:IsShown()) then return end
	local show = DB().avatarStatus and true or false
	avatar.collar:SetShown(show)
	Kit:ShowLed(avatar.led, show)
	if not show then return end
	local unit = frame.unit
	local connected, dead = Plain(UnitIsConnected, unit), Plain(UnitIsDeadOrGhost, unit)
	if connected == false or dead == true then return Kit:SetLed(avatar.led, false) end
	local fighting = Plain(UnitAffectingCombat, unit)
	if unit == 'player' and frame.combatEvent ~= nil then fighting = frame.combatEvent end
	if fighting == true then return Kit:SetLed(avatar.led, true, 'red') end
	if Plain(UnitIsAFK, unit) == true then return Kit:SetLed(avatar.led, true, 'amber') end
	Kit:SetLed(avatar.led, true, 'ledGreen')
end

function UpdateAvatar(frame)
	local avatar, style = frame.avatar, frame.avatarStyle
	if not (avatar and style) then return end
	local unit = frame.unit
	local Px = UI.Pixel.Px
	local size = avatar:GetWidth()
	if IsSecret(size) or not size or size <= 2 then return end
	local px = Px(avatar, 1)
	local round = style ~= 'key'
	for _, part in ipairs({avatar.outline, avatar.bezel, avatar.ring, avatar.lens}) do part:SetShown(round) end
	avatar.keyFrame:SetShown(not round)
	-- Geometry.
	Around(avatar.outline, avatar, -px)
	Around(avatar.bezel, avatar, 0)
	local bezel = UI.Pixel.Snap(avatar, max(2 * px, size * 0.07))
	local ring = UI.Pixel.Snap(avatar, max(px, size * 0.045))
	Around(avatar.ring, avatar, bezel)
	Around(avatar.lens, avatar, bezel + ring)
	Kit:Tint(avatar.ring, {RingColor(frame)})
	avatar.keyScreen:ClearAllPoints()
	avatar.keyScreen:SetPoint('TOPLEFT', bezel, -bezel)
	avatar.keyScreen:SetPoint('BOTTOMRIGHT', -bezel, bezel)
	avatar.keyScreen.shell.opts.edge = {RingColor(frame)}
	Kit:PaintShell(avatar.keyScreen.shell)
	-- Content.
	local picture, initials = avatar.picture, avatar.initials
	picture:Hide()
	initials:Hide()
	for _, dot in ipairs(avatar.dots) do dot:Hide() end
	picture:RemoveMaskTexture(avatar.roundMask)
	picture:RemoveMaskTexture(avatar.keyMask)
	local mode = style
	local _, class = UnitClass(unit)
	local coords = not IsSecret(class) and class and Plain(UnitIsPlayer, unit) and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
	local letters = mode == 'monogram' and Initials(unit)
	if mode == 'monogram' and not letters then mode = coords and 'glyph' or 'ring' end
	if mode == 'glyph' and not coords then mode = 'ring' end
	if mode == 'matrix' then
		local hash = Fnv(Seed(unit))
		local lens = size - 2 * (bezel + ring)
		local pitch = max(2 * px, UI.Pixel.Snap(avatar, lens * 0.8 / MATRIX))
		local dotSize = max(px, UI.Pixel.Snap(avatar, pitch * 0.62))
		for row = 0, MATRIX - 1 do
			for column = 0, MATRIX - 1 do
				local on, inside = Lit(hash, row, column)
				local dot = avatar.dots[row * MATRIX + column + 1]
				if inside then
					dot:ClearAllPoints()
					dot:SetSize(dotSize, dotSize)
					dot:SetPoint('CENTER', avatar, 'CENTER', (column - 3) * pitch, (3 - row) * pitch)
					dot:SetVertexColor(0.957, 0.957, 0.941, on and 1 or 0.08)
					dot:Show()
				end
			end
		end
	elseif mode == 'monogram' then
		Kit:Font(initials, max(7, floor((size - 2 * (bezel + ring)) * 0.42)), nil, true)
		initials:SetText(letters)
		Kit:Tint(initials, {RingColor(frame)})
		initials:Show()
	else
		local target = round and avatar.lens or avatar.keyScreen
		picture:ClearAllPoints()
		picture:SetAllPoints(target)
		if mode == 'glyph' then
			picture:SetTexture(CLASS_ICONS)
			picture:SetTexCoord(unpack(coords))
		else
			SetPortraitTexture(picture, unit)
			picture:SetTexCoord(0.1, 0.9, 0.1, 0.9)
		end
		picture:AddMaskTexture(round and avatar.roundMask or avatar.keyMask)
		picture:Show()
	end
	-- The presence lamp on the lower rim.
	local led = max(5, floor(size * 0.18))
	avatar.led:SetSize(led, led)
	if avatar.led.glow then Kit:FitSprite(avatar.led.glow, led, led) end
	avatar.led:ClearAllPoints()
	avatar.led:SetPoint('CENTER', avatar, 'BOTTOMRIGHT', -size * 0.15, size * 0.15)
	avatar.collar:ClearAllPoints()
	avatar.collar:SetPoint('TOPLEFT', avatar.led, 'TOPLEFT', -2 * px, 2 * px)
	avatar.collar:SetPoint('BOTTOMRIGHT', avatar.led, 'BOTTOMRIGHT', 2 * px, -2 * px)
	Kit:Tint(avatar.collar, 'panel')
	AvatarStatus(frame)
end
end

local function UpdatePortrait(frame)
	local unit, mode = frame.unit, frame.portraitMode
	if IsAvatar(mode) then
		UpdateAvatar(frame)
	elseif mode == 'model' and frame.model then
		-- Draw now when we can, so a new target shows at once; else when it can.
		frame.modelToken = (frame.modelToken or 0) + 1
		if DrawModel(frame) then VerifyModel(frame, 0) else RefreshModel(frame, 1) end
	elseif mode == 'class' and frame.portrait then
		local _, class = UnitClass(unit)
		local coords = not IsSecret(class) and class and Plain(UnitIsPlayer, unit) and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
		if coords then
			frame.portrait:SetTexture(CLASS_ICONS)
			frame.portrait:SetTexCoord(unpack(coords))
		else
			SetPortraitTexture(frame.portrait, unit)
			frame.portrait:SetTexCoord(0.12, 0.88, 0.12, 0.88)
		end
	elseif mode == 'texture' and frame.portrait then
		SetPortraitTexture(frame.portrait, unit)
		frame.portrait:SetTexCoord(0.12, 0.88, 0.12, 0.88)
	end
end

-- polled: a timer refresh (target of target); the portrait is redrawn only
-- when the unit behind the frame changed, told by a plain GUID.
local function UpdateName(frame, polled)
	local unit = frame.unit
	local name = UnitName(unit)
	if IsSecret(name) then frame.nameText:SetText(name)
	else frame.nameText:SetText(name and strupper(name) or strupper(frame.layout.title)) end
	if DB().nameColor == 'class' then Kit:Tint(frame.nameText, {ClassColor(unit)}) end
	if frame.levelText then
		local ok = pcall(function()
			local level = UnitLevel(unit)
			if IsSecret(level) then frame.levelText:SetFormattedText('LV %d', level) return end
			frame.levelText:SetText((level and level > 0) and ('LV '..level) or 'LV ??')
		end)
		if not ok then frame.levelText:SetText('') end
	end
	UpdateTag(frame)
	local guid = Plain(UnitGUID, unit)
	if polled and (guid == nil or guid == frame.portraitGUID) then return end
	frame.portraitGUID = guid
	UpdatePortrait(frame)
end

local function UpdateCombat(frame, event)
	if not frame.lamp then return end
	local ok, inCombat = pcall(UnitAffectingCombat, frame.unit)
	-- Lockdown starts after PLAYER_REGEN_DISABLED fires, so trust the event first.
	if event == 'PLAYER_REGEN_DISABLED' and frame.unit == 'player' then ok, inCombat = true, true end
	if event == 'PLAYER_REGEN_ENABLED' and frame.unit == 'player' then ok, inCombat = true, false end
	Kit:SetLed(frame.lamp, ok and not IsSecret(inCombat) and inCombat or false)
	if frame.unit == 'player' then
		if event == 'PLAYER_REGEN_DISABLED' then frame.combatEvent = true
		elseif event == 'PLAYER_REGEN_ENABLED' then frame.combatEvent = false end
	end
	if frame.avatarStyle then AvatarStatus(frame) end
end

-- Indicators ------------------------------------------------------------------------
local ROLE_TEXT = {TANK = 'TNK', HEALER = 'HLR', DAMAGER = 'DPS'}

local function Chip(face, width)
	local chip = Kit:LCDPanel(face, {radius = 2})
	chip:SetSize(width, 10)
	chip.text = Kit:Text(chip, '', 6, 'lcdInk', true)
	chip.text:SetPoint('CENTER', 0.5, 0)
	chip:Hide()
	return chip
end

local function SetChip(chip, text, token)
	if not text then chip:Hide() return end
	chip.text:SetText(text)
	Kit:Tint(chip.text, token or 'lcdInk')
	chip:Show()
end

local function UpdateIndicators(frame)
	local ind, unit = Indicators(), frame.unit
	if frame.raidIcon then
		local index = ind.raidTarget and Plain(GetRaidTargetIndex, unit)
		if index and SetRaidTargetIconTexture then
			SetRaidTargetIconTexture(frame.raidIcon, index)
			frame.raidIcon:Show()
		else
			frame.raidIcon:Hide()
		end
	end
	if not frame.roleChip then return end
	local role = ind.role and Plain(UnitGroupRolesAssigned, unit)
	SetChip(frame.roleChip, role and ROLE_TEXT[role])
	SetChip(frame.leadChip, ind.leader and Plain(UnitIsGroupLeader, unit) == true and 'LD' or nil)
	-- One status chip: a ready check answer, then a summon, then a resurrection.
	local status, token
	if ind.readyCheck and (frame.readyShown or 0) > GetTime() then
		local answer = Plain(GetReadyCheckStatus, unit)
		if answer == 'ready' then status, token = 'RDY', 'green'
		elseif answer == 'notready' then status, token = 'NO', 'red'
		elseif answer == 'waiting' then status, token = '...', 'amber' end
	end
	if not status and ind.summon and C_IncomingSummon and Plain(C_IncomingSummon.HasIncomingSummon, unit) == true then
		local state = Plain(C_IncomingSummon.IncomingSummonStatus, unit)
		local enum = Enum and Enum.SummonStatus
		if enum and state == enum.Accepted then status, token = 'SUM', 'green'
		elseif enum and state == enum.Declined then status, token = 'SUM', 'red'
		else status, token = 'SUM', 'blue' end
	end
	if not status and ind.resurrect and Plain(UnitHasIncomingResurrection, unit) == true then status, token = 'RES', 'green' end
	SetChip(frame.statusChip, status, token)
	-- The chips line up along the top edge, left to right.
	local previous
	for _, chip in ipairs({frame.roleChip, frame.leadChip, frame.statusChip}) do
		chip:ClearAllPoints()
		if previous then chip:SetPoint('LEFT', previous, 'RIGHT', 3, 0)
		else chip:SetPoint('CENTER', frame.face, 'TOPLEFT', 7 + chip:GetWidth() / 2, 0) end
		if chip:IsShown() then previous = chip end
	end
	if frame.outline then
		local target = ind.targetOutline and Plain(UnitIsUnit, unit, 'target') == true
		frame.outline:SetShown(target and true or false)
	end
end


-- Shared with the other action bar files.
P.AVATAR_EVENTS = AVATAR_EVENTS
P.AvatarStatus = AvatarStatus
P.Chip = Chip
P.IsAvatar = IsAvatar
P.ShowAvatar = ShowAvatar
P.UpdateCombat = UpdateCombat
P.UpdateIndicators = UpdateIndicators
P.UpdateName = UpdateName
P.UpdatePortrait = UpdatePortrait
