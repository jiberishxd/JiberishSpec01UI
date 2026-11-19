-- Unit frames: construction, fill looks and the layout of each shape. Part of
-- the unit frames (UnitFrames.lua).
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown, GetTime = CreateFrame, UIParent, InCombatLockdown, GetTime
local floor, max, min, sin, pi = math.floor, math.max, math.min, math.sin, math.pi
local P = UI.UnitFrameParts
local IsSecret, RGB = UI.Util.IsSecret, UI.Util.RGB
local ApplyMotion, Arrive, AuraUpdateEmpty, AVATAR_EVENTS, AvatarStatus, Cfg = P.ApplyMotion, P.Arrive, P.AuraUpdateEmpty, P.AVATAR_EVENTS, P.AvatarStatus, P.Cfg
local Chip, ClassColor, DB, frames, IsAvatar, LayoutAuras = P.Chip, P.ClassColor, P.DB, P.frames, P.IsAvatar, P.LayoutAuras
local LayoutPowerDigits, MarkBar, ModelFallback, module, ordered, PartyAsRaid = P.LayoutPowerDigits, P.MarkBar, P.ModelFallback, P.module, P.ordered, P.PartyAsRaid
local PartyVisibility, PlaceStatus, RefreshModel, ShapeOf, ShowAvatar, STATUS_EVENTS = P.PartyVisibility, P.PlaceStatus, P.RefreshModel, P.ShapeOf, P.ShowAvatar, P.STATUS_EVENTS
local StatusMode, Style, UpdateAll, UpdateAuras, UpdateCombat, UpdateHealth = P.StatusMode, P.Style, P.UpdateAll, P.UpdateAuras, P.UpdateCombat, P.UpdateHealth
local UpdateIndicators, UpdateName, UpdatePortrait, UpdatePower, UpdateStatus = P.UpdateIndicators, P.UpdateName, P.UpdatePortrait, P.UpdatePower, P.UpdateStatus

-- Construction ----------------------------------------------------------------------------
-- Health and power meters: the reference's LED meter, its slider's pill, or a
-- flat bar on a charcoal plate. Each is a native StatusBar.
-- Kept in a block of its own: the main chunk may hold at most 200 locals.
local MaskFill, Gradient, ApplyFill, ApplyTrack, ApplyLooks
do
local STRETCHED = Enum and Enum.UITextureSliceMode and Enum.UITextureSliceMode.Stretched

function MaskFill(bar, file, margin)
	local mask = bar:CreateMaskTexture()
	mask:SetTexture(Kit.media..file..'.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
	if mask.SetTextureSliceMargins then
		mask:SetTextureSliceMargins(margin, margin, margin, margin)
		if STRETCHED and mask.SetTextureSliceMode then mask:SetTextureSliceMode(STRETCHED) end
	end
	mask:SetAllPoints(bar)
	bar:GetStatusBarTexture():AddMaskTexture(mask)
	bar.fillMask = mask -- the fill looks below share it
	if mask.SetScale then
		local function Fit(_, _, height)
			-- Check for a secret first: comparing one is an error.
			if IsSecret(height) or not height or height <= 0 then return end
			mask:SetScale(file == 'mask-pill' and height / (2 * margin) or 2 / margin)
		end
		bar:HookScript('OnSizeChanged', Fit)
		Fit(nil, nil, bar:GetHeight())
	end
end

-- Fill looks ----------------------------------------------------------------------
-- A meter's fill can be flat, solid, glossed, shaded, glassy or segmented, or
-- any LibSharedMedia status bar texture. The light and shade are textures
-- anchored to the fill texture itself, so the client carries them with the
-- fill and no value is ever read. Pill and bar meters clip them with the
-- fill's own mask. The track behind can be the meter's housing, a black
-- screen, a dim wash of the fill's color, or nothing. Shared with the raid,
-- boss and arena frames through UI.BarLooks.
local LSM = LibStub and LibStub('LibSharedMedia-3.0', true)
local SOLID = [[Interface\Buttons\WHITE8X8]]
local FILL_ITEMS = {{'flat', 'Flat'}, {'solid', 'Solid'}, {'gloss', 'Gloss'}, {'gradient', 'Gradient'}, {'glass', 'Glass'},
	{'striped', 'Segmented'}}
local TRACK_ITEMS = {{'default', 'Housing'}, {'screen', 'Black'}, {'dim', 'Dim fill'}, {'custom', 'Custom'}, {'clear', 'None'}}

local function FillItems(withDefault)
	local items = {}
	if withDefault then items[1] = {'default', 'Page default'} end
	for _, item in ipairs(FILL_ITEMS) do items[#items + 1] = item end
	if LSM and LSM.List then
		local ok, names = pcall(LSM.List, LSM, 'statusbar')
		if ok and type(names) == 'table' then
			for _, name in ipairs(names) do items[#items + 1] = {'lsm:'..name, name} end
		end
	end
	return items
end

local function FillFile(look)
	if look == 'solid' then return SOLID end
	if type(look) == 'string' and look:sub(1, 4) == 'lsm:' and LSM and LSM.Fetch then
		local ok, path = pcall(LSM.Fetch, LSM, 'statusbar', look:sub(5), true)
		if ok and type(path) == 'string' then return path end
	end
	return Kit.media..'bar-flat.tga'
end

-- A light or shade texture over the fill, clipped like the fill.
local function LookPart(bar, name, sublevel)
	local parts = bar.lookParts
	if not parts then parts = {}; bar.lookParts = parts end
	local part = parts[name]
	if not part then
		part = bar:CreateTexture(nil, 'ARTWORK', nil, sublevel or 2)
		part:SetColorTexture(1, 1, 1, 1)
		if bar.fillMask then part:AddMaskTexture(bar.fillMask) end
		parts[name] = part
	end
	part:ClearAllPoints()
	part:Show()
	return part
end

function Gradient(texture, orientation, r1, g1, b1, a1, r2, g2, b2, a2)
	texture:SetColorTexture(1, 1, 1, 1)
	if texture.SetGradient and CreateColor then
		texture:SetGradient(orientation, CreateColor(r1, g1, b1, a1), CreateColor(r2, g2, b2, a2))
	else
		texture:SetColorTexture(r2, g2, b2, (a1 + a2) / 2)
	end
end

-- Segment gaps: hairlines across the whole meter in the track's black, every
-- few units, so the fill reads as a row of cells.
local function Segment(bar)
	local lines = bar.lookLines
	if not lines then lines = {}; bar.lookLines = lines end
	local count = 0
	local width = bar:GetWidth()
	if bar.look == 'striped' and not bar.kitPerforated and not IsSecret(width) and width and width > 0 then
		local px = UI.Pixel.Px(bar, 1)
		local step = max(UI.Pixel.Snap(bar, 6), 3 * px)
		count = min(floor(width / step), 96)
		for index = 1, count do
			local line = lines[index]
			if not line then
				line = bar:CreateTexture(nil, 'ARTWORK', nil, 4)
				line:SetColorTexture(0, 0, 0, 0.8)
				lines[index] = line
			end
			line:ClearAllPoints()
			line:SetWidth(px)
			line:SetPoint('TOPLEFT', bar, 'TOPLEFT', index * step, 0)
			line:SetPoint('BOTTOMLEFT', bar, 'BOTTOMLEFT', index * step, 0)
			line:Show()
		end
	end
	for index = count + 1, #lines do lines[index]:Hide() end
end

function ApplyFill(bar, look)
	if not bar then return end
	look = look or 'flat'
	bar.look = look
	local fill = bar:GetStatusBarTexture()
	if not fill then return end
	-- A dot meter keeps its plain fill: the dots are its look.
	if not bar.kitPerforated then
		local file = FillFile(look)
		if bar.lookFile ~= file then
			bar.lookFile = file
			fill:SetTexture(file)
		end
	end
	local px = UI.Pixel.Px(bar, 1)
	local used = {}
	if look == 'gloss' then
		local high = LookPart(bar, 'high')
		high:SetPoint('TOPLEFT', fill, 'TOPLEFT')
		high:SetPoint('BOTTOMRIGHT', fill, 'RIGHT')
		Gradient(high, 'VERTICAL', 1, 1, 1, 0.03, 1, 1, 1, 0.36)
		used.high = true
	elseif look == 'gradient' then
		local shade = LookPart(bar, 'shade')
		shade:SetAllPoints(fill)
		Gradient(shade, 'HORIZONTAL', 0, 0, 0, 0.55, 0, 0, 0, 0)
		used.shade = true
	elseif look == 'glass' then
		local sheen = LookPart(bar, 'sheen')
		sheen:SetPoint('TOPLEFT', fill, 'TOPLEFT')
		sheen:SetPoint('BOTTOMRIGHT', fill, 'RIGHT')
		sheen:SetColorTexture(1, 1, 1, 0.12)
		local lit = LookPart(bar, 'lit', 3)
		lit:SetPoint('TOPLEFT', fill, 'TOPLEFT')
		lit:SetPoint('TOPRIGHT', fill, 'TOPRIGHT')
		lit:SetHeight(px)
		lit:SetColorTexture(1, 1, 1, 0.5)
		local low = LookPart(bar, 'low', 3)
		low:SetPoint('BOTTOMLEFT', fill, 'BOTTOMLEFT')
		low:SetPoint('BOTTOMRIGHT', fill, 'BOTTOMRIGHT')
		low:SetHeight(px)
		low:SetColorTexture(0, 0, 0, 0.4)
		used.sheen, used.lit, used.low = true, true, true
	end
	for name, part in pairs(bar.lookParts or {}) do
		if not used[name] then part:Hide() end
	end
	if not bar.lookHooked then
		bar.lookHooked = true
		bar:HookScript('OnSizeChanged', function(self) UI:Safe(Segment, self) end)
	end
	Segment(bar)
end

-- The dim wash follows the fill's color; the color may be secret, so it is
-- handed straight to the setter.
local function FollowColor(bar, r, g, b)
	local dim = bar.lookDim
	if dim and dim:IsShown() then pcall(dim.SetVertexColor, dim, r, g, b) end
end

function ApplyTrack(bar, track)
	local shell = bar and bar.track and bar.track.shell
	if not shell then return end
	local base = bar.trackBase
	if not base then
		base = {surface = shell.opts.surface, fill = shell.opts.fill}
		bar.trackBase = base
	end
	track = track or 'default'
	-- A dot meter needs its housing color between the dots.
	if bar.kitPerforated and track == 'clear' then track = 'default' end
	local black = track == 'screen' or track == 'dim'
	local custom = track == 'custom'
	if black then shell.opts.surface, shell.opts.fill, shell.opts.alpha = 'screen', nil, nil
	elseif custom then
		-- Your own color and opacity, on a screen-style track.
		local color = DB().trackColor
		shell.opts.surface = 'screen'
		shell.opts.fill = type(color) == 'table' and {RGB(color)} or nil
		shell.opts.alpha = DB().trackAlpha or 1
	else shell.opts.surface, shell.opts.fill, shell.opts.alpha = base.surface, base.fill, nil end
	Kit:PaintShell(shell)
	shell:SetAlpha(track == 'clear' and 0 or 1)
	if bar.kitCover and bar.coverToken then
		Kit:Tint(bar.kitCover, (black and 'black') or (custom and shell.opts.fill) or bar.coverToken)
	end
	local dim = bar.lookDim
	if track == 'dim' then
		if not dim then
			dim = bar:CreateTexture(nil, 'BACKGROUND', nil, 2)
			dim:SetAllPoints(bar)
			dim:SetColorTexture(1, 1, 1, 1)
			if bar.fillMask then dim:AddMaskTexture(bar.fillMask) end
			bar.lookDim = dim
			hooksecurefunc(bar, 'SetStatusBarColor', FollowColor)
		end
		dim:SetAlpha(0.22)
		dim:Show()
		FollowColor(bar, bar:GetStatusBarColor())
	elseif dim then
		dim:Hide()
	end
end

UI.BarLooks = {FillItems = FillItems, TrackItems = TRACK_ITEMS, ApplyFill = ApplyFill, ApplyTrack = ApplyTrack}

-- A frame's own choice, else the page's.
local function LookOf(frame, field)
	local value = Cfg(frame)[field]
	if value == 'default' or not value then value = DB()[field] end
	return value
end

function ApplyLooks(frame)
	local track = LookOf(frame, 'track')
	ApplyFill(frame.health, LookOf(frame, 'healthTexture'))
	ApplyTrack(frame.health, track)
	if frame.power then
		local look = LookOf(frame, 'powerTexture')
		-- The console faceplate lights its power as segments unless told otherwise.
		if frame.shapeName == 'console' and look == 'flat' then look = 'striped' end
		ApplyFill(frame.power, look)
		ApplyTrack(frame.power, track)
	end
end

end
local function BarStyle(layout)
	local style = DB().units[layout.key].barStyle
	if style == 'default' or not style then style = DB().barStyle or 'dots' end
	return style
end

local function Meter(parent, height, onDark, style)
	local track = CreateFrame('Frame', nil, parent)
	local inset = style == 'bar' and 1 or 2
	track:SetHeight(height + inset * 2)
	track.shell = Kit:Shell(track, {surface = (style == 'bar' or onDark) and 'glass' or 'lcd', radius = style == 'bar' and 2 or 99,
		shadow = false, fill = (style ~= 'bar' and not onDark) and 'track' or nil})
	local bar = CreateFrame('StatusBar', nil, track)
	bar:SetPoint('TOPLEFT', style == 'dots' and 3 or inset, -inset)
	bar:SetPoint('BOTTOMRIGHT', style == 'dots' and -3 or -inset, inset)
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(1)
	if style == 'dots' then
		bar:SetStatusBarTexture([[Interface\Buttons\WHITE8X8]])
		bar.coverToken = (onDark and 'glass') or 'track'
		Kit:Perforate(bar, bar.coverToken, onDark and 'darkEdge' or nil)
	else
		bar:SetStatusBarTexture(Kit.media..'bar-flat.tga')
		MaskFill(bar, style == 'pill' and 'mask-pill' or 'mask-bar', style == 'pill' and 15 or 5)
	end
	MarkBar(bar)
	bar.track, bar.inset = track, inset
	return bar
end

-- The portrait: a black display holding a 3D model or a 2D face (made when first
-- chosen), in a holder that scales about its centre for the arrival pop.
local function Portrait(frame, parent)
	-- A fixed slot holds the layout; the holder inside it scales about its centre.
	local slot = CreateFrame('Frame', nil, parent)
	slot:SetSize(34, 34)
	local holder = CreateFrame('Frame', nil, slot)
	holder:SetAllPoints(slot)
	local screen = Kit:Screen(holder, {inset = 2, radius = 5, shadow = false})
	screen:SetAllPoints(holder)
	frame.portraitSlot, frame.portraitHolder, frame.portraitScreen = slot, holder, screen
	return slot
end

local function PortraitMode(frame)
	local mode = Cfg(frame).portrait
	if mode == 'default' or not mode then
		local page = DB().portrait
		local valid = page == 'model' or page == 'texture' or page == 'class' or IsAvatar(page)
		mode = frame.layout.size == 'large' and (valid and page or 'texture') or 'off'
	end
	return mode
end

-- Shows the chosen portrait; false when it's off.
local function ApplyPortrait(frame)
	local mode = PortraitMode(frame)
	local changed = frame.portraitMode ~= mode
	frame.portraitMode = mode
	if mode == 'off' then frame.portraitSlot:Hide() return false end
	frame.portraitSlot:Show()
	local screen = frame.portraitScreen.screen
	-- An avatar replaces the black display entirely.
	local avatar = ShowAvatar(frame, mode)
	frame.portraitScreen:SetShown(not avatar)
	if avatar then
		ModelFallback(frame, false)
		if frame.model then frame.model:Hide() end
		if frame.portrait then frame.portrait:Hide() end
		if UnitExists(frame.unit) then UI:Safe(UpdatePortrait, frame) end
		return true
	end
	if mode == 'model' then
		if not frame.model then
			frame.model = CreateFrame('PlayerModel', nil, screen)
			frame.model:SetAllPoints()
			frame.model:HookScript('OnShow', function() RefreshModel(frame) end)
			frame.model:HookScript('OnSizeChanged', function() RefreshModel(frame) end)
		end
		frame.model:SetFrameLevel(screen:GetFrameLevel() + 3)
		frame.model:Show()
		if frame.portrait then frame.portrait:Hide() end
	else
		ModelFallback(frame, false)
		if not frame.portrait then
			frame.portrait = screen:CreateTexture(nil, 'ARTWORK')
			frame.portrait:SetAllPoints()
		end
		frame.portrait:Show()
		if frame.model then frame.model:Hide() end
	end
	if changed and UnitExists(frame.unit) then UI:Safe(UpdatePortrait, frame) end
	return true
end

-- Secure frames change size and scale only out of combat.
local function Resize(frame, cfg)
	if InCombatLockdown() then
		return UI:AfterCombat(function() Resize(frame, frame.embedCfg or Cfg(frame)) end, 'uf.size.'..frame.unit)
	end
	frame:SetSize(cfg.width, cfg.height)
	local scale = (DB().scale or 1) * (cfg.scale or 1)
	-- The Layout page's per-frame scale multiplies this one.
	if frame.layout.owner then
		if frame:GetScale() ~= scale then frame:SetScale(scale) end
	else
		UI:SetMoverBaseScale('uf.'..frame.unit, scale, frame)
	end
	-- A model drawn at the old size can go blank: redraw it at the new one.
	RefreshModel(frame)
end

-- The LCD's unlit '888' is shown or hidden by the appearance setting
-- (Kit:Ghost); it is only printed behind a percentage, where it reads right.
-- Kept in a block of its own: the main chunk may hold at most 200 locals.
local LayoutLarge, LayoutCompact, NoPortrait, Gauge, ApplyShell, ResetParts, SHAPE_LAYOUTS, SyncGhost
do
local function ShowGhost(frame, cfg)
	if not frame.ghost then return end
	frame.ghost:SetText('') -- see SyncGhost: no unlit digits behind health readouts
	if not Kit.Ghost then frame.ghost:Show() end
end

-- After every layout: the unlit '888' sits exactly behind the readout, in the
-- same face and size, right-aligned on the value's own right edge, and never
-- outlined or shadowed (an outlined ghost reads as garbled digits). It shows
-- only behind a percentage (three digits at most) set in the monospaced IBM
-- Plex Mono, where each digit lands on an unlit one; otherwise it is blank.
function SyncGhost(frame)
	-- Unlit digits behind a live, variable-width health readout kept showing
	-- through it in game (a dark first digit), so health readouts go without
	-- them; fixed readouts (clocks, timers) keep theirs.
	if frame.ghost then frame.ghost:SetText('') end
end

-- A theme repaint re-applies every registered font, ghosts included: put the
-- ghosts back behind their readouts once it has run.
Kit:OnRefresh(function()
	C_Timer.After(0, function()
		for _, frame in ipairs(ordered) do
			if frame.ghost then UI:Safe(SyncGhost, frame, Cfg(frame)) end
		end
	end)
end)

-- Moving a text or lamp between the face, the LCD and the overlay above the
-- meters. Only this addon's own regions move.
local function Put(region, parent)
	if region and region:GetParent() ~= parent then region:SetParent(parent) end
end
local function PutLamp(frame, parent)
	Put(frame.lamp, parent)
	Put(frame.lamp.glow, parent)
end

local function Ink(frame) return Kit.INK[Style()] or Kit.INK.paper end

-- The portrait's side: 'auto' is the frame's near side (fallback); 'left' or
-- 'right' as chosen. Returns that side, the other one, and the inward sign.
local function PortraitSide(cfg, fallback)
	local side = cfg.portraitSide == 'left' and 'LEFT' or cfg.portraitSide == 'right' and 'RIGHT' or fallback
	if side == 'LEFT' then return 'LEFT', 'RIGHT', 1 end
	return 'RIGHT', 'LEFT', -1
end

-- Large frames (player, target): header row, portrait, LCD readout, meters.
function LayoutLarge(frame, cfg)
	local ink = Ink(frame)
	PutLamp(frame, frame.face)
	Put(frame.nameText, frame.face)
	Put(frame.levelText, frame.face)
	Put(frame.digits, frame.lcd)
	Put(frame.ghost, frame.lcd)
	Kit:Tint(frame.nameText, ink[1])
	Kit:Tint(frame.code, ink[1])
	Kit:Tint(frame.levelText, ink[2])
	Kit:Tint(frame.digits, 'lcdInk')
	Kit:Font(frame.levelText, Kit.SIZE.tiny, nil, false)
	local width = cfg.width
	local mirror, pad = frame.layout.mirror, 7
	local near, far = mirror and 'RIGHT' or 'LEFT', mirror and 'LEFT' or 'RIGHT'
	local sign = mirror and -1 or 1
	local header = cfg.header
	-- Header: lamp, model code and name in a row from the near side; level on the far side.
	local row = frame.headerRow
	row:ClearAllPoints()
	row:SetPoint('TOPLEFT', pad, -4)
	row:SetPoint('TOPRIGHT', -pad, -4)
	row:SetHeight(13)
	local previous
	local function Next(region, shown, gap)
		region:ClearAllPoints()
		if region.glow then Kit:ShowLed(region, shown) else region:SetShown(shown) end
		if not shown then return end
		if previous then region:SetPoint(near, previous, far, sign * gap, 0)
		else region:SetPoint(near, row, near, sign * 1, 0) end
		previous = region
	end
	Next(frame.lamp, header and cfg.combatLamp, 4)
	Next(frame.code, header and cfg.headerCode, 4)
	Next(frame.nameText, header, 6)
	frame.levelText:ClearAllPoints()
	frame.levelText:SetPoint(far, row, far, 0, 0)
	frame.levelText:SetShown(header and cfg.headerLevel)
	Kit:Font(frame.nameText, cfg.nameSize or 10, nil, true)
	-- Status lamps sit in the header, between the name and the level.
	local status = header and StatusMode(frame) ~= 'off'
	if status then
		local leveled = cfg.headerLevel and true or false
		local anchor = leveled and frame.levelText or row
		PlaceStatus(frame, far, anchor, leveled and near or far, leveled and -sign * 6 or 0, 0, mirror and 'RIGHT' or 'LEFT')
	end
	frame.nameText:SetWidth(max(width - 110 - (status and 56 or 0), 30))
	frame.nameText:SetJustifyH(mirror and 'RIGHT' or 'LEFT')

	-- Body: portrait, then the LCD and meters in a column beside it.
	local top = header and 21 or 7
	local lcdHeight = max(14, (cfg.digitsSize or 13) + 7)
	local healthTrack = (cfg.healthHeight or 6) + frame.health.inset * 2
	local powerTrack = frame.power and (cfg.powerHeight or 3) + frame.power.inset * 2 or 0
	local body = lcdHeight + 3 + healthTrack + (frame.power and 2 + powerTrack or 0)
	local hasPortrait = ApplyPortrait(frame)
	-- The portrait: as tall as the readout and meters (size 0), or its own size up
	-- to the frame's height; on the near side, or the side chosen.
	local room = max(16, cfg.height - top - 4)
	local want = tonumber(cfg.portraitSize) or 0
	local portraitSize = hasPortrait and (want > 0 and min(max(want, 16), room) or max(16, min(body, room))) or 0
	local pSide, pOther, pSign = PortraitSide(cfg, near)
	local slot = frame.portraitSlot
	slot:ClearAllPoints()
	slot:SetSize(max(portraitSize, 1), max(portraitSize, 1))
	slot:SetPoint('TOP'..pSide, pSign * pad, -top)
	local column = max(width - pad * 2 - (hasPortrait and portraitSize + 6 or 0), 20)
	-- A portrait taller than the column: the column sits centred beside it.
	local drop = hasPortrait and max(0, floor((portraitSize - body) / 2)) or 0
	local lcd = frame.lcd
	lcd:Show()
	lcd:ClearAllPoints()
	lcd:SetSize(column, lcdHeight)
	if hasPortrait then lcd:SetPoint('TOP'..pSide, slot, 'TOP'..pOther, pSign * 6, -drop)
	else lcd:SetPoint('TOP'..near, sign * pad, -top) end
	frame.tag:SetWidth(max(column - 50, 10))
	frame.tag:SetShown(cfg.lcdTag ~= 'none')
	Kit:Font(frame.digits, cfg.digitsSize or 13, nil, false)
	Kit:Font(frame.ghost, cfg.digitsSize or 13, nil, false)
	frame.digits:ClearAllPoints()
	frame.digits:SetPoint('RIGHT', lcd, 'RIGHT', -6, 0)
	frame.digits:SetJustifyH('RIGHT')
	frame.ghost:ClearAllPoints()
	frame.ghost:SetPoint('RIGHT', lcd, 'RIGHT', -6, 0)
	frame.ghost:SetJustifyH('RIGHT')
	ShowGhost(frame, cfg)
	frame.health.track:ClearAllPoints()
	frame.health.track:SetSize(column, healthTrack)
	frame.health.track:SetPoint('TOPLEFT', lcd, 'BOTTOMLEFT', 0, -3)
	if frame.power then
		frame.power.track:ClearAllPoints()
		frame.power.track:SetSize(column, powerTrack)
		frame.power.track:SetPoint('TOPLEFT', frame.health.track, 'BOTTOMLEFT', 0, -2)
	end
end

-- Compact frames (focus, party, target of target, pet): name row, digits, meters.
function LayoutCompact(frame, cfg)
	local width, height = cfg.width, cfg.height
	local small = frame.layout.size == 'small'
	local ink = Ink(frame)
	PutLamp(frame, frame.face)
	Put(frame.nameText, frame.face)
	Put(frame.digits, frame.face)
	Kit:Tint(frame.nameText, ink[1])
	Kit:Tint(frame.digits, ink[1])
	frame.digits:SetJustifyH('RIGHT')
	-- Small device frames carry health only.
	if frame.power then frame.power.track:SetShown(not small) end
	local pad, top = 7, small and 5 or 6
	local hasPortrait = ApplyPortrait(frame)
	local left, right = pad, pad
	local slot = frame.portraitSlot
	slot:ClearAllPoints()
	if hasPortrait then
		-- As tall as the frame (size 0) or its own size; on the left, or the side chosen.
		local want = tonumber(cfg.portraitSize) or 0
		local size = want > 0 and min(max(want, 12), height - 4) or max(12, height - 8)
		local side = PortraitSide(cfg, 'LEFT')
		slot:SetSize(size, size)
		if side == 'RIGHT' then
			slot:SetPoint('RIGHT', -4, 0)
			right = 4 + size + 5
		else
			slot:SetPoint('LEFT', 4, 0)
			left = 4 + size + 5
		end
	end
	local header = cfg.header
	Kit:ShowLed(frame.lamp, header and cfg.combatLamp)
	frame.lamp:ClearAllPoints()
	frame.lamp:SetPoint('TOPLEFT', left, -top - 3)
	frame.nameText:ClearAllPoints()
	if cfg.combatLamp then frame.nameText:SetPoint('LEFT', frame.lamp, 'RIGHT', 4, 0)
	else frame.nameText:SetPoint('TOPLEFT', left, -top - 1) end
	frame.nameText:SetShown(header)
	frame.nameText:SetWidth(max(width - left - right - 40, 20))
	Kit:Font(frame.nameText, cfg.nameSize or (small and 8 or 9), nil, true)
	Kit:Font(frame.digits, cfg.digitsSize or (small and 9 or 10), nil, true)
	frame.digits:ClearAllPoints()
	frame.digits:SetPoint('TOPRIGHT', -right, -top)
	local healthTrack = (cfg.healthHeight or 5) + frame.health.inset * 2
	frame.health.track:ClearAllPoints()
	frame.health.track:SetSize(max(width - left - right, 20), healthTrack)
	frame.health.track:SetPoint('TOPLEFT', left, header and -(top + 13) or -top)
	if frame.power and not small then
		frame.power.track:ClearAllPoints()
		frame.power.track:SetSize(max(width - left - right, 20), (cfg.powerHeight or 3) + frame.power.inset * 2)
		frame.power.track:SetPoint('TOPLEFT', frame.health.track, 'BOTTOMLEFT', 0, -2)
	end
end

-- The portrait belongs to the device shape only.
function NoPortrait(frame)
	frame.portraitSlot:Hide()
	frame.portraitMode = 'off'
end

-- A meter's track height for a thickness setting.
local function TrackHeight(meter, thickness) return thickness + meter.inset * 2 end

-- Bar: the frame is one wide meter, with the name and health printed on it.
local function LayoutBar(frame, cfg)
	local width, height = cfg.width, cfg.height
	local pad = 3
	local inner = max(width - pad * 2, 20)
	local powerTrack = frame.power and TrackHeight(frame.power, 2) or 0
	local healthTrack = max(8, height - pad * 2 - (frame.power and powerTrack + 1 or 0))
	local track = frame.health.track
	track:ClearAllPoints()
	track:SetSize(inner, healthTrack)
	track:SetPoint('TOPLEFT', pad, -pad)
	if frame.power then
		frame.power.track:ClearAllPoints()
		frame.power.track:SetSize(inner, powerTrack)
		frame.power.track:SetPoint('TOPLEFT', track, 'BOTTOMLEFT', 0, -1)
	end
	-- The words sit above the meter's fill, outlined to read over any color.
	local over = frame.overlay
	over:SetFrameLevel(track:GetFrameLevel() + 6)
	PutLamp(frame, over)
	Put(frame.nameText, over)
	Put(frame.levelText, over)
	Put(frame.digits, over)
	local nameSize = min(cfg.nameSize or 10, max(healthTrack - 1, 7))
	Kit:Font(frame.nameText, nameSize, 'OUTLINE', true)
	Kit:Font(frame.levelText, max(nameSize - 2, 6), 'OUTLINE', false)
	Kit:Font(frame.digits, min(cfg.digitsSize or 10, max(healthTrack - 1, 7)), 'OUTLINE', true)
	for _, text in ipairs({frame.nameText, frame.levelText, frame.digits}) do Kit:Tint(text, 'white') end
	local x = 6
	frame.lamp:ClearAllPoints()
	Kit:ShowLed(frame.lamp, cfg.combatLamp and true or false)
	if cfg.combatLamp then
		frame.lamp:SetPoint('LEFT', track, 'LEFT', 6, 0)
		x = 15
	end
	frame.nameText:ClearAllPoints()
	frame.nameText:SetPoint('LEFT', track, 'LEFT', x, 0)
	frame.nameText:SetWidth(max(inner - x - 70, 20))
	frame.nameText:SetJustifyH('LEFT')
	frame.nameText:SetShown(cfg.header and true or false)
	frame.digits:ClearAllPoints()
	frame.digits:SetPoint('RIGHT', track, 'RIGHT', -6, 0)
	frame.digits:SetJustifyH('RIGHT')
	frame.levelText:ClearAllPoints()
	frame.levelText:SetPoint('RIGHT', frame.digits, 'LEFT', -5, 0)
	frame.levelText:SetShown(cfg.header and cfg.headerLevel and frame.layout.size == 'large' or false)
end

-- Square: a tile with the name across the top, big LCD digits in the middle and
-- the meters along the bottom.
local function LayoutSquare(frame, cfg)
	local width, height = cfg.width, cfg.height
	local pad = 5
	local ink = Ink(frame)
	PutLamp(frame, frame.face)
	Put(frame.nameText, frame.face)
	Put(frame.digits, frame.lcd)
	Put(frame.ghost, frame.lcd)
	local nameSize = min(cfg.nameSize or 9, 10)
	Kit:Font(frame.nameText, nameSize, nil, true)
	Kit:Tint(frame.nameText, ink[1])
	frame.nameText:ClearAllPoints()
	frame.nameText:SetPoint('TOPLEFT', pad, -pad)
	frame.nameText:SetWidth(max(width - pad * 2 - 9, 10))
	frame.nameText:SetJustifyH('LEFT')
	frame.nameText:SetShown(cfg.header and true or false)
	Kit:ShowLed(frame.lamp, cfg.combatLamp and true or false)
	frame.lamp:ClearAllPoints()
	frame.lamp:SetPoint('TOPRIGHT', -pad, -pad - 1)
	local top = pad + ((cfg.header or cfg.combatLamp) and nameSize + 4 or 0)
	local healthTrack = TrackHeight(frame.health, cfg.healthHeight or 4)
	local powerTrack = frame.power and TrackHeight(frame.power, min(cfg.powerHeight or 2, 3)) or 0
	local meters = healthTrack + (frame.power and powerTrack + 2 or 0)
	local lcd = frame.lcd
	local lcdWidth = max(width - pad * 2, 10)
	local lcdHeight = max(12, height - top - meters - pad - 3)
	lcd:Show()
	lcd:ClearAllPoints()
	lcd:SetPoint('TOPLEFT', pad, -top)
	lcd:SetSize(lcdWidth, lcdHeight)
	-- Big digits, as large as the tile allows for three characters.
	local size = max(8, min(floor(lcdHeight * 0.62), floor((lcdWidth - 8) / 1.9), 30))
	Kit:Font(frame.digits, size, nil, false)
	Kit:Font(frame.ghost, size, nil, false)
	Kit:Tint(frame.digits, 'lcdInk')
	ShowGhost(frame, cfg)
	-- A percentage lines up digit for digit over the unlit '888', centred.
	local half = cfg.healthText == 'percent' and frame.ghost:GetStringWidth() / 2 or 0
	for _, text in ipairs({frame.digits, frame.ghost}) do
		text:ClearAllPoints()
		if half > 0 then
			text:SetPoint('RIGHT', lcd, 'CENTER', half, 0)
			text:SetJustifyH('RIGHT')
		else
			text:SetPoint('CENTER', lcd, 'CENTER', 0, 0)
			text:SetJustifyH('CENTER')
		end
	end
	frame.health.track:ClearAllPoints()
	frame.health.track:SetSize(lcdWidth, healthTrack)
	frame.health.track:SetPoint('TOPLEFT', lcd, 'BOTTOMLEFT', 0, -3)
	if frame.power then
		frame.power.track:ClearAllPoints()
		frame.power.track:SetSize(lcdWidth, powerTrack)
		frame.power.track:SetPoint('TOPLEFT', frame.health.track, 'BOTTOMLEFT', 0, -2)
	end
end

-- Slim: a thin line meter with the name above it and the health at its right end.
local function LayoutSlim(frame, cfg)
	local width = cfg.width
	PutLamp(frame, frame.face)
	Put(frame.nameText, frame.face)
	Put(frame.levelText, frame.face)
	Put(frame.digits, frame.face)
	local nameSize = cfg.nameSize or 9
	Kit:Font(frame.nameText, nameSize, 'OUTLINE', true)
	Kit:Font(frame.levelText, max(nameSize - 2, 6), 'OUTLINE', false)
	Kit:Font(frame.digits, cfg.digitsSize or 9, 'OUTLINE', true)
	for _, text in ipairs({frame.nameText, frame.levelText, frame.digits}) do Kit:Tint(text, 'white') end
	local healthTrack = TrackHeight(frame.health, cfg.healthHeight or 4)
	local health = frame.health.track
	health:ClearAllPoints()
	health:SetSize(width, healthTrack)
	if frame.power then
		local power = frame.power.track
		power:ClearAllPoints()
		power:SetSize(width, TrackHeight(frame.power, min(cfg.powerHeight or 2, 2)))
		power:SetPoint('BOTTOMLEFT', 0, 0)
		health:SetPoint('BOTTOMLEFT', power, 'TOPLEFT', 0, 1)
	else
		health:SetPoint('BOTTOMLEFT', 0, 0)
	end
	local x = 0
	frame.lamp:ClearAllPoints()
	Kit:ShowLed(frame.lamp, cfg.combatLamp and true or false)
	if cfg.combatLamp then
		frame.lamp:SetPoint('BOTTOMLEFT', health, 'TOPLEFT', 1, 4)
		x = 8
	end
	frame.nameText:ClearAllPoints()
	frame.nameText:SetPoint('BOTTOMLEFT', health, 'TOPLEFT', x, 2)
	frame.nameText:SetWidth(max(width - x - 60, 20))
	frame.nameText:SetJustifyH('LEFT')
	frame.nameText:SetShown(cfg.header and true or false)
	frame.digits:ClearAllPoints()
	frame.digits:SetPoint('BOTTOMRIGHT', health, 'TOPRIGHT', 0, 2)
	frame.digits:SetJustifyH('RIGHT')
	frame.levelText:ClearAllPoints()
	frame.levelText:SetPoint('RIGHT', frame.digits, 'LEFT', -5, 0)
	frame.levelText:SetShown(cfg.header and cfg.headerLevel and frame.layout.size == 'large' or false)
end

-- LCD strip: the whole frame is a gray LCD, name and digits printed on it and a
-- dot meter along its bottom.
local function LayoutStrip(frame, cfg)
	local width = cfg.width
	local pad = 5
	PutLamp(frame, frame.face)
	Put(frame.nameText, frame.face)
	Put(frame.levelText, frame.face)
	Put(frame.digits, frame.face)
	Put(frame.ghost, frame.face)
	local nameSize = cfg.nameSize or 9
	Kit:Font(frame.nameText, nameSize, nil, true)
	Kit:Font(frame.levelText, max(nameSize - 2, 6), nil, false)
	Kit:Font(frame.digits, cfg.digitsSize or 11, nil, false)
	Kit:Font(frame.ghost, cfg.digitsSize or 11, nil, false)
	Kit:Tint(frame.nameText, 'lcdInk')
	Kit:Tint(frame.levelText, 'lcdDim')
	Kit:Tint(frame.digits, 'lcdInk')
	ShowGhost(frame, cfg)
	local x = pad
	frame.lamp:ClearAllPoints()
	Kit:ShowLed(frame.lamp, cfg.combatLamp and true or false)
	if cfg.combatLamp then
		frame.lamp:SetPoint('TOPLEFT', pad, -pad - 2)
		x = pad + 9
	end
	frame.nameText:ClearAllPoints()
	frame.nameText:SetPoint('TOPLEFT', x, -pad)
	frame.nameText:SetWidth(max(width - x - pad - 70, 20))
	frame.nameText:SetJustifyH('LEFT')
	frame.nameText:SetShown(cfg.header and true or false)
	for _, text in ipairs({frame.digits, frame.ghost}) do
		text:ClearAllPoints()
		text:SetPoint('TOPRIGHT', -pad, -pad + 1)
		text:SetJustifyH('RIGHT')
	end
	frame.levelText:ClearAllPoints()
	frame.levelText:SetPoint('RIGHT', frame.digits, 'LEFT', -6, 0)
	frame.levelText:SetShown(cfg.header and cfg.headerLevel and frame.layout.size ~= 'small' or false)
	local inner = max(width - pad * 2, 20)
	local bottom = pad
	if frame.power then
		local powerTrack = TrackHeight(frame.power, min(cfg.powerHeight or 2, 3))
		frame.power.track:ClearAllPoints()
		frame.power.track:SetSize(inner, powerTrack)
		frame.power.track:SetPoint('BOTTOMLEFT', pad, pad)
		bottom = pad + powerTrack + 2
	end
	frame.health.track:ClearAllPoints()
	frame.health.track:SetSize(inner, TrackHeight(frame.health, cfg.healthHeight or 4))
	frame.health.track:SetPoint('BOTTOMLEFT', pad, bottom)
end

-- The printed header the new faceplates share: combat lamp, model code and name
-- from the near side, level on the far side.
local function PrintHeader(frame, cfg, pad, y, width)
	local ink = Ink(frame)
	PutLamp(frame, frame.face)
	Put(frame.nameText, frame.face)
	Put(frame.levelText, frame.face)
	Kit:Tint(frame.nameText, ink[1])
	Kit:Tint(frame.code, ink[1])
	Kit:Tint(frame.levelText, ink[2])
	local mirror = frame.layout.mirror
	local near, far, sign = mirror and 'RIGHT' or 'LEFT', mirror and 'LEFT' or 'RIGHT', mirror and -1 or 1
	local header, large = cfg.header, frame.layout.size == 'large'
	local x = pad
	Kit:ShowLed(frame.lamp, header and cfg.combatLamp and true or false)
	frame.lamp:ClearAllPoints()
	if header and cfg.combatLamp then
		frame.lamp:SetPoint(near, frame.face, 'TOP'..near, sign * (x + 2), y - 6)
		x = x + 9
	end
	frame.code:ClearAllPoints()
	frame.code:SetShown(header and large and cfg.headerCode and true or false)
	if frame.code:IsShown() then
		frame.code:SetPoint('TOP'..near, frame.face, 'TOP'..near, sign * x, y - 2)
		x = x + frame.code:GetStringWidth() + 5
	end
	Kit:Font(frame.nameText, cfg.nameSize or (large and 10 or 9), nil, true)
	frame.nameText:ClearAllPoints()
	frame.nameText:SetPoint('TOP'..near, frame.face, 'TOP'..near, sign * x, y - 1)
	frame.nameText:SetJustifyH(mirror and 'RIGHT' or 'LEFT')
	frame.nameText:SetWidth(max(width - x - pad - 40, 20))
	frame.nameText:SetShown(header and true or false)
	Kit:Font(frame.levelText, Kit.SIZE.tiny, nil, false)
	frame.levelText:ClearAllPoints()
	frame.levelText:SetPoint('TOP'..far, frame.face, 'TOP'..far, -sign * pad, y - 2)
	frame.levelText:SetShown(header and cfg.headerLevel and large or false)
	return near, far, sign
end

-- Console: a printed header, an LCD readout on the near side, the meters beside
-- it (power as lit segments) and, on the player and target, a row of status
-- glyph lamps under them. Medium and small consoles drop the code, level and
-- lamps and give the readout and meters the room.
local function LayoutConsole(frame, cfg)
	local width, height = cfg.width, cfg.height
	local size = frame.layout.size
	local large = size == 'large'
	local pad = large and 7 or 5
	local near, far, sign = PrintHeader(frame, cfg, pad, large and -4 or -3, width)
	local nameSize = cfg.nameSize or (large and 10 or 9)
	local top = cfg.header and (large and 19 or nameSize + 7) or pad
	local statusRow = large and 9 or 0
	local bottom = large and statusRow + 9 or pad
	local bodyHeight = max(12, height - top - bottom)
	local lcd = frame.lcd
	Put(frame.digits, lcd)
	lcd:Show()
	lcd:ClearAllPoints()
	-- Wide enough for four digits at the chosen size, and no more than 40% of the frame.
	local digits = max(9, min(floor(bodyHeight * (large and 0.62 or 0.7)), cfg.digitsSize and cfg.digitsSize + (large and 8 or 2) or 22))
	local lcdWidth = min(max(floor(digits * 2.6) + 12, 34), floor(width * 0.4))
	digits = min(digits, floor((lcdWidth - 10) / 2.4))
	lcd:SetSize(lcdWidth, bodyHeight)
	lcd:SetPoint('TOP'..near, frame.face, 'TOP'..near, sign * pad, -top)
	Kit:Font(frame.digits, digits, nil, false)
	Kit:Tint(frame.digits, 'lcdInk')
	frame.digits:ClearAllPoints()
	frame.digits:SetPoint('RIGHT', lcd, 'RIGHT', -5, 0)
	frame.digits:SetJustifyH('RIGHT')
	frame.digits:SetWidth(0)
	local column = max(width - pad * 2 - lcdWidth - 6, 20)
	local healthHeight = cfg.healthHeight or (large and 6 or 5)
	local powerHeight = frame.power and max(cfg.powerHeight or 3, large and 4 or 3) or 0
	-- Meters centred on the readout's height.
	local meters = TrackHeight(frame.health, healthHeight) + (frame.power and TrackHeight(frame.power, powerHeight) + 3 or 0)
	local offset = max(0, floor((bodyHeight - meters) / 2))
	frame.health.track:ClearAllPoints()
	frame.health.track:SetSize(column, TrackHeight(frame.health, healthHeight))
	frame.health.track:SetPoint('TOP'..near, lcd, 'TOP'..far, sign * 6, -offset)
	if frame.power then
		frame.power.track:ClearAllPoints()
		frame.power.track:SetSize(column, TrackHeight(frame.power, powerHeight))
		frame.power.track:SetPoint('TOPLEFT', frame.health.track, 'BOTTOMLEFT', 0, -3)
	end
	if large then
		PlaceStatus(frame, 'BOTTOM'..near, frame.face, 'BOTTOM'..near, sign * pad, 5, frame.layout.mirror and 'LEFT' or 'RIGHT', statusRow)
	end
end

-- Gauge: a round instrument on the near side, built like the minimap's ring
-- from the 512 px round art so it stays smooth at any size: a black outline, a
-- charcoal bezel band and a lit inner edge around a dark recessed screen. Health
-- rises inside it as a dim liquid with a lit surface line; it is a native
-- vertical StatusBar under the round mask that copies the health meter's own
-- values, so the client fills it, secret or not. A ring of hairline ticks is
-- drawn in code in physical pixels (long ones at the quarters), and the
-- health figure sits in the centre.
local GAUGE_TICKS, GAUGE_RING = 24, 3

local function Round(parent, layer, sublevel)
	local texture = parent:CreateTexture(nil, layer or 'BACKGROUND', nil, sublevel or 0)
	texture:SetTexture(Kit.media..'mask-round.tga')
	return texture
end

function Gauge(frame)
	local gauge = frame.gauge
	if gauge then return gauge end
	gauge = CreateFrame('Frame', nil, frame.face)
	gauge:EnableMouse(false)
	gauge.outline = Round(gauge, 'BACKGROUND', -6)
	gauge.outline:SetVertexColor(0, 0, 0, 0.85)
	gauge.band = Round(gauge, 'BACKGROUND', -5)
	gauge.lit = Round(gauge, 'BACKGROUND', -4)
	gauge.lit:SetVertexColor(1, 1, 1, 0.14)
	gauge.well = Round(gauge, 'BACKGROUND', -3)
	gauge.ticks = {}
	for index = 1, GAUGE_TICKS do
		local tick = gauge:CreateTexture(nil, 'BACKGROUND', nil, -7)
		tick:SetColorTexture(1, 1, 1, 1)
		gauge.ticks[index] = tick
	end
	gauge.bar = CreateFrame('StatusBar', nil, gauge)
	gauge.bar:SetAllPoints(gauge)
	gauge.bar:SetOrientation('VERTICAL')
	gauge.bar:SetStatusBarTexture([[Interface\Buttons\WHITE8X8]])
	gauge.bar:SetMinMaxValues(0, 1)
	gauge.bar:SetValue(1)
	gauge.bar:SetAlpha(0.45)
	local mask = gauge.bar:CreateMaskTexture()
	mask:SetTexture(Kit.media..'mask-round.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
	mask:SetAllPoints(gauge)
	local fill = gauge.bar:GetStatusBarTexture()
	fill:AddMaskTexture(mask)
	-- The liquid's surface: a lit hairline on the fill's top edge, inside the mask.
	gauge.surface = gauge.bar:CreateTexture(nil, 'OVERLAY')
	gauge.surface:SetColorTexture(1, 1, 1, 1)
	gauge.surface:SetPoint('TOPLEFT', fill, 'TOPLEFT')
	gauge.surface:SetPoint('TOPRIGHT', fill, 'TOPRIGHT')
	gauge.surface:AddMaskTexture(mask)
	gauge.front = CreateFrame('Frame', nil, gauge)
	gauge.front:SetAllPoints()
	gauge.front:SetFrameLevel(gauge.bar:GetFrameLevel() + 2)
	gauge.front:EnableMouse(false)
	gauge.shade = Kit:Texture(gauge.front, 'bezel-shade', 'OVERLAY', 0)
	gauge.shade:SetAllPoints(gauge)
	gauge.shade:SetAlpha(0.5)
	gauge.ring = Kit:Texture(gauge.front, 'bezel-ring', 'OVERLAY', 1)
	gauge.ring:SetVertexColor(1, 1, 1, 0.08)
	-- Follow the health meter: every value goes straight from setter to setter.
	local health, bar = frame.health, gauge.bar
	hooksecurefunc(health, 'SetMinMaxValues', function(_, low, high) pcall(bar.SetMinMaxValues, bar, low, high) end)
	hooksecurefunc(health, 'SetValue', function(_, value, interpolation) pcall(bar.SetValue, bar, value, interpolation) end)
	hooksecurefunc(health, 'SetStatusBarColor', function(_, r, g, b) pcall(bar.SetStatusBarColor, bar, r, g, b) end)
	frame.gauge = gauge
	return gauge
end

-- Sizes in physical pixels around a disc of `size` units.
local function FitGauge(frame, gauge)
	local Px = UI.Pixel.Px
	local function Around(texture, n)
		local inset = Px(gauge, n)
		texture:ClearAllPoints()
		texture:SetPoint('TOPLEFT', gauge, 'TOPLEFT', -inset, inset)
		texture:SetPoint('BOTTOMRIGHT', gauge, 'BOTTOMRIGHT', inset, -inset)
	end
	Around(gauge.outline, GAUGE_RING + 1)
	Around(gauge.band, GAUGE_RING)
	Around(gauge.lit, 1)
	Around(gauge.ring, GAUGE_RING)
	gauge.well:ClearAllPoints()
	gauge.well:SetAllPoints(gauge)
	Kit:Tint(gauge.band, 'dark')
	Kit:Tint(gauge.well, 'glass')
	gauge.surface:SetHeight(Px(gauge, 1))
	-- The tick ring, just outside the bezel.
	local ink = Ink(frame)
	local px = Px(gauge, 1)
	local radius = gauge:GetWidth() / 2
	for index, tick in ipairs(gauge.ticks) do
		local major = (index - 1) % (GAUGE_TICKS / 4) == 0
		local length = (major and 4 or 2) * px
		local angle = pi / 2 - (index - 1) / GAUGE_TICKS * 2 * pi
		local reach = radius + (GAUGE_RING + 3) * px + length / 2
		local x = UI.Pixel.Snap(gauge, math.cos(angle) * reach)
		local y = UI.Pixel.Snap(gauge, sin(angle) * reach)
		tick:ClearAllPoints()
		tick:SetSize(px, length)
		tick:SetPoint('CENTER', gauge, 'CENTER', x, y)
		if tick.SetRotation then tick:SetRotation(angle - pi / 2) end
		Kit:Tint(tick, major and ink[1] or ink[2], major and 0.9 or 0.55)
	end
end

local function LayoutGauge(frame, cfg)
	local width, height = cfg.width, cfg.height
	local pad = 6
	local mirror = frame.layout.mirror
	local near, far, sign = mirror and 'RIGHT' or 'LEFT', mirror and 'LEFT' or 'RIGHT', mirror and -1 or 1
	local gauge = Gauge(frame)
	-- Room around the disc for the bezel and the tick ring.
	local around = UI.Pixel.Px(frame.face, GAUGE_RING + 3 + 4) + 1
	local size = UI.Pixel.Snap(frame.face, max(16, height - 2 * pad - 2 * around))
	gauge:Show()
	gauge:ClearAllPoints()
	gauge:SetSize(size, size)
	gauge:SetPoint(near, frame.face, near, sign * (pad + around), 0)
	FitGauge(frame, gauge)
	Put(frame.digits, gauge.front)
	Kit:Font(frame.digits, max(7, min(floor(size * 0.32), cfg.digitsSize or 13)), 'OUTLINE', true)
	Kit:Tint(frame.digits, 'darkInk')
	frame.digits:ClearAllPoints()
	frame.digits:SetPoint('CENTER', gauge, 'CENTER', 0, 0)
	frame.digits:SetJustifyH('CENTER')
	-- The rest beside it: header, then the meters.
	local left = pad + size + 2 * around + 6
	local column = max(width - left - pad, 20)
	PutLamp(frame, frame.face)
	Put(frame.nameText, frame.face)
	Put(frame.levelText, frame.face)
	local ink = Ink(frame)
	Kit:Tint(frame.nameText, ink[1])
	Kit:Tint(frame.levelText, ink[2])
	Kit:Font(frame.nameText, cfg.nameSize or 10, nil, true)
	Kit:Font(frame.levelText, Kit.SIZE.tiny, nil, false)
	local header = cfg.header
	local x = left
	Kit:ShowLed(frame.lamp, header and cfg.combatLamp and true or false)
	frame.lamp:ClearAllPoints()
	if header and cfg.combatLamp then
		frame.lamp:SetPoint(near, frame.face, 'TOP'..near, sign * (x + 2), -pad - 5)
		x = x + 9
	end
	frame.nameText:ClearAllPoints()
	frame.nameText:SetPoint('TOP'..near, frame.face, 'TOP'..near, sign * x, -pad)
	frame.nameText:SetWidth(max(column - (x - left) - 36, 20))
	frame.nameText:SetJustifyH(mirror and 'RIGHT' or 'LEFT')
	frame.nameText:SetShown(header and true or false)
	frame.levelText:ClearAllPoints()
	frame.levelText:SetPoint('TOP'..far, frame.face, 'TOP'..far, -sign * pad, -pad - 1)
	frame.levelText:SetShown(header and cfg.headerLevel and frame.layout.size == 'large' or false)
	local top = header and pad + (cfg.nameSize or 10) + 5 or pad
	frame.health.track:ClearAllPoints()
	frame.health.track:SetSize(column, TrackHeight(frame.health, cfg.healthHeight or 5))
	frame.health.track:SetPoint('TOP'..near, frame.face, 'TOP'..near, sign * left, -top)
	if frame.power then
		frame.power.track:ClearAllPoints()
		frame.power.track:SetSize(column, TrackHeight(frame.power, cfg.powerHeight or 3))
		frame.power.track:SetPoint('TOPLEFT', frame.health.track, 'BOTTOMLEFT', 0, -2)
	end
	PlaceStatus(frame, 'BOTTOM'..far, frame.face, 'BOTTOM'..far, -sign * pad, pad - 1, mirror and 'RIGHT' or 'LEFT')
end

-- Tape: the name and health over a meter with a tick scale under it, every 5%
-- with long ticks at the quarters, like the scale under SPEC-01's slider.
local TAPE_TICKS = 21
local function LayoutTape(frame, cfg)
	local width = cfg.width
	local pad = 6
	local inner = max(width - pad * 2, 20)
	local near, far, sign = PrintHeader(frame, cfg, pad, -pad + 2, width)
	Put(frame.digits, frame.face)
	Kit:Font(frame.digits, cfg.digitsSize or 10, nil, true)
	Kit:Tint(frame.digits, Ink(frame)[1])
	frame.digits:ClearAllPoints()
	frame.digits:SetPoint('TOP'..far, frame.face, 'TOP'..far, -sign * pad, -pad + 1)
	frame.digits:SetJustifyH(far == 'RIGHT' and 'RIGHT' or 'LEFT')
	-- The level moves beside the digits.
	frame.levelText:ClearAllPoints()
	frame.levelText:SetPoint(far, frame.digits, near, -sign * 6, 0)
	local top = cfg.header and pad + (cfg.nameSize or 10) + 4 or pad
	local healthTrack = TrackHeight(frame.health, cfg.healthHeight or 5)
	local track = frame.health.track
	track:ClearAllPoints()
	track:SetSize(inner, healthTrack)
	track:SetPoint('TOPLEFT', frame.face, 'TOPLEFT', pad, -top)
	-- The scale.
	local ticks = frame.tapeTicks
	if not ticks then
		ticks = {}
		for index = 1, TAPE_TICKS do
			local tick = frame.face:CreateTexture(nil, 'ARTWORK', nil, 2)
			tick:SetColorTexture(1, 1, 1, 1)
			ticks[index] = tick
		end
		frame.tapeTicks = ticks
	end
	local px = UI.Pixel.Px(frame.face, 1)
	local ink = Ink(frame)
	for index, tick in ipairs(ticks) do
		local major = (index - 1) % 5 == 0
		local x = UI.Pixel.Snap(frame.face, (index - 1) / (TAPE_TICKS - 1) * (inner - px))
		Kit:Tint(tick, major and ink[1] or ink[2], major and 0.9 or 0.6)
		tick:ClearAllPoints()
		tick:SetSize(px, (major and 4 or 2) * px)
		tick:SetPoint('TOPLEFT', track, 'BOTTOMLEFT', x, -2 * px)
		tick:Show()
	end
	if frame.power then
		frame.power.track:ClearAllPoints()
		frame.power.track:SetSize(inner, TrackHeight(frame.power, cfg.powerHeight or 3))
		frame.power.track:SetPoint('TOPLEFT', track, 'BOTTOMLEFT', 0, -(6 * px + 2))
	end
	PlaceStatus(frame, 'BOTTOM'..far, frame.face, 'TOP'..far, -sign * 2, 3, frame.layout.mirror and 'RIGHT' or 'LEFT')
end

-- Printed: a spec sheet. The name over a hairline rule, then each meter on its
-- own row behind a printed legend (HP, PWR) in the reference's small caps, the
-- health figure at the end of its row.
local function Legend(frame, key, text)
	frame.legends = frame.legends or {}
	local legend = frame.legends[key]
	if not legend then
		legend = Kit:Label(frame.face, text, 'legend', 7, true)
		frame.legends[key] = legend
	end
	Kit:Tint(legend, 'legend')
	legend:Show()
	return legend
end

local function LayoutPrinted(frame, cfg)
	local width = cfg.width
	local pad = 7
	local near, far, sign = PrintHeader(frame, cfg, pad, -pad + 2, width)
	local top = cfg.header and pad + (cfg.nameSize or 10) + 4 or pad
	-- The rule under the header.
	local rule = frame.printRule
	if not rule then
		rule = frame.face:CreateTexture(nil, 'ARTWORK', nil, 1)
		rule:SetColorTexture(1, 1, 1, 1)
		frame.printRule = rule
	end
	Kit:Tint(rule, 'rule')
	rule:ClearAllPoints()
	rule:SetHeight(UI.Pixel.Px(frame.face, 1))
	rule:SetPoint('TOPLEFT', frame.face, 'TOPLEFT', pad, -top + 2)
	rule:SetPoint('TOPRIGHT', frame.face, 'TOPRIGHT', -pad, -top + 2)
	rule:SetShown(cfg.header and true or false)
	local legendWidth = 22
	local digitsWidth = 34
	local column = max(width - pad * 2 - legendWidth - digitsWidth, 20)
	local healthTrack = TrackHeight(frame.health, cfg.healthHeight or 5)
	local hp = Legend(frame, 'hp', 'HP')
	frame.health.track:ClearAllPoints()
	frame.health.track:SetSize(column, healthTrack)
	frame.health.track:SetPoint('TOPLEFT', frame.face, 'TOPLEFT', pad + legendWidth, -top - 2)
	hp:ClearAllPoints()
	hp:SetPoint('LEFT', frame.face, 'LEFT', pad, 0)
	hp:SetPoint('TOP', frame.health.track, 'TOP', 0, 0)
	hp:SetPoint('BOTTOM', frame.health.track, 'BOTTOM', 0, 0)
	Put(frame.digits, frame.face)
	Kit:Font(frame.digits, cfg.digitsSize or 10, nil, true)
	Kit:Tint(frame.digits, Ink(frame)[1])
	frame.digits:ClearAllPoints()
	frame.digits:SetPoint('RIGHT', frame.face, 'RIGHT', -pad, 0)
	frame.digits:SetPoint('TOP', frame.health.track, 'TOP', 0, 2)
	frame.digits:SetPoint('BOTTOM', frame.health.track, 'BOTTOM', 0, -2)
	frame.digits:SetJustifyH('RIGHT')
	if frame.power then
		local pwr = Legend(frame, 'pwr', 'PWR')
		frame.power.track:ClearAllPoints()
		frame.power.track:SetSize(column, TrackHeight(frame.power, cfg.powerHeight or 3))
		frame.power.track:SetPoint('TOPLEFT', frame.health.track, 'BOTTOMLEFT', 0, -4)
		pwr:ClearAllPoints()
		pwr:SetPoint('LEFT', frame.face, 'LEFT', pad, 0)
		pwr:SetPoint('TOP', frame.power.track, 'TOP', 0, 2)
		pwr:SetPoint('BOTTOM', frame.power.track, 'BOTTOM', 0, -2)
	end
	PlaceStatus(frame, 'BOTTOM'..far, frame.face, 'TOP'..far, -sign * 2, 3, frame.layout.mirror and 'RIGHT' or 'LEFT')
end

-- The frame's own housing for its shape. Docked in the console, a device frame
-- sits on the console's housing (an LCD-style one keeps its face); the other
-- shapes keep theirs, since the housing is their body. Slim has none.
function ApplyShell(frame, shape)
	local shell = frame.shell
	local surface = shape == 'lcdstrip' and 'lcd' or Style()
	if shell.opts.surface ~= surface then Kit:SetSurface(shell, surface) end
	local radius = shape == 'device' and (frame.layout.size == 'small' and 6 or 8)
		or ((shape == 'square' or shape == 'console' or shape == 'gauge') and 8 or 6)
	if shell.opts.radius ~= radius then
		shell.opts.radius = radius
		Kit:FitShell(shell)
	end
	local shown = shape ~= 'slim'
	if frame.docked and shape == 'device' then shown = frame.keepShell and true or false end
	-- Embedded in a console bay: the bay is its housing.
	if frame.embedded then shown = false end
	shell:SetShown(shown)
end

-- Everything a shape may not use starts hidden; each layout shows its own.
function ResetParts(frame)
	frame.code:Hide()
	frame.levelText:Hide()
	frame.lcd:Hide()
	frame.tag:Hide()
	frame.ghost:SetText('')
	frame.health.track:Show()
	if frame.power then frame.power.track:Show() end
	if frame.gauge then frame.gauge:Hide() end
	if frame.printRule then frame.printRule:Hide() end
	for _, legend in pairs(frame.legends or {}) do legend:Hide() end
	for _, tick in ipairs(frame.tapeTicks or {}) do tick:Hide() end
	if frame.status then frame.status:Hide() end
end

SHAPE_LAYOUTS = {bar = LayoutBar, square = LayoutSquare, slim = LayoutSlim, lcdstrip = LayoutStrip,
	console = LayoutConsole, gauge = LayoutGauge, tape = LayoutTape, printed = LayoutPrinted}
end

local function LayoutLamps(frame, cfg)
	if not frame.lamps then return end
	local size = cfg.lampSize or 6
	frame.lampRail:SetHeight(size + 8)
	for index, lamp in ipairs(frame.lamps) do
		lamp:SetSize(size, size)
		if lamp.glow then Kit:FitSprite(lamp.glow, size, size) end
		lamp:ClearAllPoints()
		lamp:SetPoint('LEFT', 8 + (index - 1) * (size + 6), 0)
	end
end

-- Your own colors over each layout's: the housing tint, the name, the digits and level.
local function ApplyColors(frame)
	local db, shell = DB(), frame.shell
	if shell then
		if db.housing == 'custom' then
			shell.opts.fill, shell.opts.alpha = {RGB(db.housingColor)}, db.housingAlpha or 0.95
			shell.customTint = true
			Kit:PaintShell(shell)
		elseif shell.customTint then
			shell.opts.fill, shell.opts.alpha, shell.customTint = nil, nil, nil
			Kit:PaintShell(shell)
		end
	end
	if db.nameColor == 'custom' then Kit:Tint(frame.nameText, {RGB(db.nameCustom)})
	elseif db.nameColor == 'class' then Kit:Tint(frame.nameText, {ClassColor(frame.unit)}) end
	if db.textColor == 'custom' then
		local color = {RGB(db.textCustom)}
		Kit:Tint(frame.digits, color)
		Kit:Tint(frame.levelText, color)
	end
end

-- The header lamp at a whole number of physical pixels, snapped to the pixel
-- grid: at a fractional scale a 5-unit circle lands between pixels and draws
-- as a crescent. Measured at layout time, when the frame's scale has settled.
local function FitLamp(frame)
	local lamp = frame.lamp
	if not lamp then return end
	local px = UI.Pixel.Px(frame.face, 1)
	local size = max(3, floor((frame.lampUnits or 5) / px + 0.5)) * px
	lamp:SetSize(size, size)
	if lamp.glow then Kit:FitSprite(lamp.glow, size, size) end
	for _, texture in ipairs({lamp, lamp.glow}) do
		if texture.SetSnapToPixelGrid then
			texture:SetSnapToPixelGrid(true)
			texture:SetTexelSnappingBias(0)
		end
	end
end

-- Your own text placement over each shape's: the digits' alignment in the LCD
-- (left, centre or right; the LCD label moves to the other end), then the name
-- and the digits nudged by their offsets (x right, y up). Kept in a block of its
-- own: the main chunk may hold at most 200 locals.
local PlaceText
do
	-- Each shifted region's anchors as last set, so a shift that the layout
	-- didn't redo is taken back before the new one (never added twice).
	local shifted = setmetatable({}, {__mode = 'k'})
	local function Shift(region, dx, dy)
		local count = region and region:GetNumPoints() or 0
		if count == 0 then return end
		local last, points = shifted[region], {}
		local same = last and last.count == count
		for index = 1, count do
			local point, relative, relativePoint, x, y = region:GetPoint(index)
			points[index] = {point, relative, relativePoint, x or 0, y or 0}
			local was = same and last[index]
			same = was and was[1] == point and was[2] == relative and was[3] == relativePoint and was[4] == (x or 0)
				and was[5] == (y or 0) or false
		end
		local ox, oy = 0, 0
		if same then ox, oy = last.dx, last.dy end
		if ox == dx and oy == dy then return end
		region:ClearAllPoints()
		local record = {count = count, dx = dx, dy = dy}
		for index, spot in ipairs(points) do
			local x, y = spot[4] - ox + dx, spot[5] - oy + dy
			region:SetPoint(spot[1], spot[2], spot[3], x, y)
			record[index] = {spot[1], spot[2], spot[3], x, y}
		end
		shifted[region] = record
	end

	local function Align(frame, cfg)
		local lcd, digits = frame.lcd, frame.digits
		if not (lcd and digits and lcd:IsShown() and digits:GetNumPoints() > 0) then return end
		local _, relative = digits:GetPoint(1)
		if relative ~= lcd then return end
		local align = cfg.digitsAlign == 'left' and 'LEFT' or cfg.digitsAlign == 'center' and 'CENTER' or nil
		if frame.tag then
			frame.tag:ClearAllPoints()
			if align == 'LEFT' then frame.tag:SetPoint('RIGHT', lcd, 'RIGHT', -6, 0); frame.tag:SetJustifyH('RIGHT')
			else frame.tag:SetPoint('LEFT', lcd, 'LEFT', 6, 0); frame.tag:SetJustifyH('LEFT') end
		end
		if not align then return end
		for _, region in ipairs({digits, frame.ghost}) do
			region:ClearAllPoints()
			region:SetPoint(align, lcd, align, align == 'LEFT' and 6 or 0, 0)
			region:SetJustifyH(align)
		end
	end

	function PlaceText(frame, cfg)
		Align(frame, cfg)
		local nameX, nameY = tonumber(cfg.nameX) or 0, tonumber(cfg.nameY) or 0
		local digitsX, digitsY = tonumber(cfg.digitsX) or 0, tonumber(cfg.digitsY) or 0
		Shift(frame.nameText, nameX, nameY)
		Shift(frame.digits, digitsX, digitsY)
		Shift(frame.ghost, digitsX, digitsY)
	end
end

local function Layout(frame)
	-- Embedded in the console, the frame takes its bay's size and leaves its
	-- header to the legend printed on the console (SetDocked).
	local cfg = frame.embedCfg or Cfg(frame)
	FitLamp(frame)
	Resize(frame, cfg)
	local shape = ShapeOf(frame)
	frame.shapeName = shape
	ApplyShell(frame, shape)
	ResetParts(frame)
	if shape == 'device' then
		if frame.layout.size == 'large' then LayoutLarge(frame, cfg) else LayoutCompact(frame, cfg) end
	else
		NoPortrait(frame)
		SHAPE_LAYOUTS[shape](frame, cfg)
	end
	-- Shapes without a place of their own carry the status lamps over their far corner.
	if not (frame.status and frame.status:IsShown()) and StatusMode(frame) ~= 'off' then
		local mirror = frame.layout.mirror
		PlaceStatus(frame, mirror and 'BOTTOMLEFT' or 'BOTTOMRIGHT', frame.face, mirror and 'TOPLEFT' or 'TOPRIGHT',
			mirror and 2 or -2, 3, mirror and 'RIGHT' or 'LEFT')
	end
	PlaceText(frame, cfg)
	SyncGhost(frame, cfg)
	ApplyColors(frame)
	LayoutLamps(frame, cfg)
	LayoutAuras(frame)
	LayoutPowerDigits(frame)
	ApplyLooks(frame)
	ApplyMotion(frame)
	if frame.raidIcon then
		frame.raidIcon:ClearAllPoints()
		frame.raidIcon:SetPoint('CENTER', frame.face, 'TOP', 0, 2)
	end
end

local HANDLERS = {
	UNIT_HEALTH = UpdateHealth, UNIT_MAXHEALTH = UpdateHealth, UNIT_CONNECTION = UpdateHealth, UNIT_FACTION = UpdateHealth,
	UNIT_POWER_UPDATE = UpdatePower, UNIT_POWER_FREQUENT = UpdatePower, UNIT_MAXPOWER = UpdatePower, UNIT_DISPLAYPOWER = UpdatePower,
	RUNE_POWER_UPDATE = UpdatePower, UPDATE_SHAPESHIFT_FORM = UpdatePower,
	UNIT_NAME_UPDATE = UpdateName, UNIT_LEVEL = UpdateName, UNIT_PORTRAIT_UPDATE = UpdateName, UNIT_MODEL_CHANGED = UpdateName,
	UNIT_AURA = UpdateAuras, UNIT_FLAGS = UpdateCombat,
	RAID_TARGET_UPDATE = UpdateIndicators, PARTY_LEADER_CHANGED = UpdateIndicators, PLAYER_ROLES_ASSIGNED = UpdateIndicators,
	INCOMING_SUMMON_CHANGED = UpdateIndicators, INCOMING_RESURRECT_CHANGED = UpdateIndicators, READY_CHECK_CONFIRM = UpdateIndicators,
}
-- Group events party frames listen to besides their unit events.
local INDICATOR_EVENTS = {'PARTY_LEADER_CHANGED', 'PLAYER_ROLES_ASSIGNED', 'INCOMING_SUMMON_CHANGED', 'INCOMING_RESURRECT_CHANGED',
	'READY_CHECK', 'READY_CHECK_CONFIRM', 'READY_CHECK_FINISHED'}

-- Unit watch shows a frame while its unit exists. Party frames skip it while
-- the raid frames show the party: their header stays hidden then.
local function Watch(frame)
	if frame.layout.party and PartyAsRaid() then
		UnregisterUnitWatch(frame)
		frame:Hide()
		return
	end
	RegisterUnitWatch(frame)
end

local function Build(layout)
	local unit, size = layout.unit, layout.size
	local style = Style()
	local parent = layout.party and module.partyHeader or UIParent
	local frame = CreateFrame('Button', 'JiberishSpec01'..unit:gsub('^%l', strupper), parent, 'SecureUnitButtonTemplate')
	frame.unit, frame.layout, frame.key = unit, layout, layout.key
	-- Click-casting addons (Clique and the like) bind the frames listed here.
	local clickCast = _G.ClickCastFrames or {}
	_G.ClickCastFrames = clickCast
	clickCast[frame] = true
	local cfg = Cfg(frame)
	frame:SetSize(cfg.width, cfg.height)
	frame:SetScale((DB().scale or 1) * (cfg.scale or 1))
	if frame.SetDontSavePosition then frame:SetDontSavePosition(true) end
	frame:SetAttribute('unit', unit)
	frame:SetAttribute('*type1', 'target')
	frame:SetAttribute('*type2', 'togglemenu')
	frame:RegisterForClicks('AnyUp')
	frame:SetScript('OnEnter', function(self) if UnitFrame_OnEnter then UnitFrame_OnEnter(self) end end)
	frame:SetScript('OnLeave', function(self) if UnitFrame_OnLeave then UnitFrame_OnLeave(self) end end)

	-- Everything drawn sits on 'face', our own child: it can fade and move in
	-- combat without touching the secure button.
	local face = CreateFrame('Frame', nil, frame)
	face:SetAllPoints()
	face:EnableMouse(false)
	frame.face = face
	frame.shell = Kit:Shell(face, {surface = style, radius = size == 'small' and 6 or 8, group = 'unitframes'})
	local ink = Kit.INK[style]
	local barStyle = BarStyle(layout)
	Portrait(frame, face)

	-- Every frame carries the parts of every shape; its layout shows the ones its
	-- shape uses and moves texts between the face, the LCD and the overlay.
	local large = size == 'large'
	frame.headerRow = CreateFrame('Frame', nil, face)
	frame.lamp = Kit:Led(face, large and 5 or 4, false)
	frame.lampUnits = large and 5 or 4
	frame.code = Kit:Label(face, layout.model, ink[1], 'tiny', true)
	frame.nameText = Kit:Label(face, '', ink[1], large and 'small' or (size == 'small' and 'tiny' or 'label'), true)
	frame.nameText:SetJustifyH('LEFT')
	frame.nameText:SetWordWrap(false)
	frame.levelText = Kit:Label(face, '', ink[2], 'tiny')
	frame.lcd = Kit:LCDPanel(face)
	frame.tag = Kit:Label(frame.lcd, '', 'lcdDim', 'tiny')
	frame.tag:SetPoint('LEFT', 6, 0)
	frame.tag:SetJustifyH('LEFT')
	frame.tag:SetWordWrap(false)
	frame.ghost = Kit:Text(frame.lcd, '888', 'value', 'lcdGhost')
	frame.ghost:SetPoint('RIGHT', -6, 0)
	if Kit.Ghost then Kit:Ghost(frame.ghost) end
	frame.digits = Kit:Text(frame.lcd, '', 'value', 'lcdInk')
	frame.digits:SetPoint('RIGHT', -6, 0)
	frame.digits:SetJustifyH('RIGHT')
	frame.health = Meter(face, cfg.healthHeight or (large and 6 or 5), style == 'dark', barStyle)
	if layout.power then frame.power = Meter(face, cfg.powerHeight or 3, style == 'dark', barStyle) end
	-- Above the meters: where the bar shape prints its words.
	frame.overlay = CreateFrame('Frame', nil, face)
	frame.overlay:SetAllPoints(face)
	frame.overlay:EnableMouse(false)

	-- The light that sweeps the top edge when combat starts and ends.
	frame.sweep = face:CreateTexture(nil, 'OVERLAY', nil, 6)
	frame.sweep:SetTexture(Kit.media..'sweep.tga')
	frame.sweep:SetBlendMode('ADD')
	frame.sweep:SetSize(64, 6)
	frame.sweep:SetAlpha(0)

	-- Raid target marker, centred on the top edge.
	frame.raidIcon = face:CreateTexture(nil, 'OVERLAY', nil, 7)
	frame.raidIcon:SetTexture([[Interface\TargetingFrame\UI-RaidTargetingIcons]])
	frame.raidIcon:SetSize(14, 14)
	frame.raidIcon:Hide()

	-- A ring in the debuff's color when there is one you can dispel.
	frame.dispel = Kit:Texture(face, 'ring-6', 'OVERLAY', 4)
	Kit:Place(frame.dispel, face, 2, 2, 2, 2)
	frame.dispel:Hide()

	if layout.party then
		-- Role, leader and status chips on the top edge; a lamp-colored outline on your target.
		frame.roleChip, frame.leadChip, frame.statusChip = Chip(face, 22), Chip(face, 14), Chip(face, 20)
		frame.outline = Kit:Texture(face, 'ring-6', 'OVERLAY', 3)
		Kit:Place(frame.outline, face, 1, 1, 1, 1)
		Kit:Tint(frame.outline, 'lamp')
		frame.outline:Hide()
	end

	if layout.classpower then
		-- Combo points, holy power and the like: lamps on a charcoal rail under the frame.
		frame.lampRail = CreateFrame('Frame', nil, face)
		frame.lampRail:SetPoint('TOP', face, 'BOTTOM', 0, -3)
		frame.lampRail.shell = Kit:Shell(frame.lampRail, {surface = 'glass', radius = 99, shadowAlpha = 0.25})
		frame.lamps = {}
		for index = 1, 10 do frame.lamps[index] = Kit:Led(frame.lampRail, 6, false) end
		frame.lampRail:Hide()
	end

	-- Placement: through the shared movers, or beside its party frame.
	if not layout.owner then UI:RegisterMover(frame, 'uf.'..unit, layout.title, layout.at) end
	function frame:SetPreview(on)
		if InCombatLockdown() then
			-- Movers lock when a fight starts: put the frame back once it ends.
			if not on then UI:AfterCombat(function() self:SetPreview(false) end, 'preview.uf.'..unit) end
			return
		end
		local header = layout.party and module.partyHeader
		if on then
			UnregisterUnitWatch(self)
			self:Show()
			-- Party frames live under a header hidden when solo or in a raid.
			if header then UnregisterStateDriver(header, 'visibility'); header:Show() end
		else
			Watch(self)
			if header then RegisterStateDriver(header, 'visibility', PartyVisibility()) end
		end
	end

	for event in pairs(HANDLERS) do
		if event:find('^UNIT_') then pcall(frame.RegisterUnitEvent, frame, event, unit) end
	end
	frame:RegisterEvent('PLAYER_ENTERING_WORLD')
	frame:RegisterEvent('PLAYER_REGEN_DISABLED')
	frame:RegisterEvent('PLAYER_REGEN_ENABLED')
	frame:RegisterEvent('RAID_TARGET_UPDATE')
	if unit == 'target' or unit == 'targettarget' or layout.party then frame:RegisterEvent('PLAYER_TARGET_CHANGED') end
	if unit == 'focus' then pcall(frame.RegisterEvent, frame, 'PLAYER_FOCUS_CHANGED') end
	if unit == 'pet' or unit:find('^partypet') then frame:RegisterEvent('UNIT_PET') end
	if layout.party then
		frame:RegisterEvent('GROUP_ROSTER_UPDATE')
		for _, event in ipairs(INDICATOR_EVENTS) do pcall(frame.RegisterEvent, frame, event) end
	end
	if layout.size == 'large' then
		-- The status lamps' events (party frames already listen to the group ones).
		for _, event in ipairs({'PLAYER_FLAGS_CHANGED', 'PARTY_LEADER_CHANGED', 'PLAYER_ROLES_ASSIGNED', 'GROUP_ROSTER_UPDATE'}) do
			pcall(frame.RegisterEvent, frame, event)
		end
		if unit == 'player' then pcall(frame.RegisterEvent, frame, 'PLAYER_UPDATE_RESTING') end
	end
	if layout.classpower then
		pcall(frame.RegisterEvent, frame, 'RUNE_POWER_UPDATE')
		pcall(frame.RegisterEvent, frame, 'UPDATE_SHAPESHIFT_FORM')
		pcall(frame.RegisterEvent, frame, 'PLAYER_SPECIALIZATION_CHANGED')
	end
	frame:SetScript('OnEvent', function(self, event, _, info)
		-- An aura event that changed nothing: no added, updated or removed auras.
		if event == 'UNIT_AURA' and AuraUpdateEmpty(info) then return end
		if event == 'PLAYER_REGEN_DISABLED' or event == 'PLAYER_REGEN_ENABLED' then
			UI:Safe(UpdateCombat, self, event)
			if self.status then UI:Safe(UpdateStatus, self) end
			return
		end
		if event == 'READY_CHECK' then self.readyShown = GetTime() + 3600
		elseif event == 'READY_CHECK_FINISHED' then
			-- Answers stay up a few seconds after the check ends.
			self.readyShown = GetTime() + 6
			C_Timer.After(6.1, function() UI:Safe(UpdateIndicators, self) end)
		end
		if event == 'PLAYER_TARGET_CHANGED' and unit == 'target' then
			local exists = UnitExists('target')
			if exists and not self.hadUnit then UI:Safe(Arrive, self) end
			self.hadUnit = exists
		end
		if event == 'PLAYER_TARGET_CHANGED' and layout.party then return UI:Safe(UpdateIndicators, self) end
		local handler = HANDLERS[event]
		if handler then UI:Safe(handler, self) else UI:Safe(UpdateAll, self) end
		if handler and self.status and STATUS_EVENTS[event] then UI:Safe(UpdateStatus, self) end
		if self.avatarStyle and AVATAR_EVENTS[event] then UI:Safe(AvatarStatus, self) end
		-- Loading screens leave models blank: draw again once the world is up.
		if event == 'PLAYER_ENTERING_WORLD' then RefreshModel(self) end
	end)
	frame:HookScript('OnShow', function(self) UI:Safe(UpdateAll, self) end)
	if layout.poll then
		-- A unit with no events of its own (target of target) is refreshed on a timer, only while shown.
		local elapsed = 0
		frame:HookScript('OnUpdate', function(self, delta)
			elapsed = elapsed + delta
			if elapsed < layout.poll then return end
			elapsed = 0
			UI:Safe(UpdateAll, self, true)
		end)
	end
	Layout(frame)
	Watch(frame)
	return frame
end

-- Party pets and targets sit right of their party frame (past its auras when
-- those are on the right), pets first. Out of combat only: the frames are secure.
local function PlaceExtras()
	if InCombatLockdown() then return UI:AfterCombat(PlaceExtras, 'uf.extras') end
	for index = 1, 4 do
		local owner = frames['party'..index]
		if owner then
			local cfg = Cfg(owner)
			local x = 6
			if DB().auras and cfg.auras and cfg.auraPosition == 'right' then
				x = x + min(cfg.auraMax or 4, cfg.auraPerRow or 4) * ((cfg.auraSize or 18) + 4) + 2
			end
			local previous
			for _, unit in ipairs({'partypet'..index, 'party'..index..'target'}) do
				local frame = frames[unit]
				if frame then
					frame:ClearAllPoints()
					if previous then frame:SetPoint('TOPLEFT', previous, 'TOPRIGHT', 6, 0)
					else frame:SetPoint('TOPLEFT', owner, 'TOPRIGHT', x, 0) end
					previous = frame
				end
			end
		end
	end
end


-- Shared with the other action bar files.
P.ApplyFill = ApplyFill
P.ApplyShell = ApplyShell
P.ApplyTrack = ApplyTrack
P.Build = Build
P.FitLamp = FitLamp
P.Layout = Layout
P.MaskFill = MaskFill
P.PlaceExtras = PlaceExtras
P.Watch = Watch
