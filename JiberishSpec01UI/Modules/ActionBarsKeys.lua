-- Our action keys, key binds, and the pet and stance keys dressed as keys.
-- Part of the action bars (ActionBars.lua).
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown, GetTime = CreateFrame, UIParent, InCombatLockdown, GetTime
local floor, max, min = math.floor, math.max, math.min
local format, ipairs, pairs, pcall, tonumber = format, ipairs, pairs, pcall, tonumber
local P = UI.ActionBarParts
local Forbidden, IsSecret = UI.Util.Forbidden, UI.Util.IsSecret
local API, BarDB, C, ColorOf, DB, Fade = P.API, P.BarDB, P.C, P.ColorOf, P.DB, P.Fade
local Flag, GetActionInfo, GetActionText, GetActionTexture, HasAction, HW = P.Flag, P.GetActionInfo, P.GetActionText, P.GetActionTexture, P.HasAction, P.HW
local IsActionInRange, IsAutoRepeatAction, IsConsumableAction, IsCurrentAction, IsEquippedAction, IsOverlayed = P.IsActionInRange, P.IsAutoRepeatAction, P.IsConsumableAction, P.IsCurrentAction, P.IsEquippedAction, P.IsOverlayed
local IsStackableAction, IsUsableAction, Legend, LightCap, MODERN_COOLDOWNS, RANGE_EVENTS = P.IsStackableAction, P.IsUsableAction, P.Legend, P.LightCap, P.MODERN_COOLDOWNS, P.RANGE_EVENTS
local Shown, Sound, Sprites = P.Shown, P.Sound, P.Sprites

-- Our action keys ---------------------------------------------------------------------
local keys, keyOf, bySlot = {}, {}, {}

local function Press(key, down)
	if key.down == down then return end
	key.down = down
	if down and Kit.MotionNotify then Kit:MotionNotify('press', key) end
	Kit:SetSprite(key.skin, Sprites()[down and 2 or 1])
	-- The legend travels with the cap.
	local travel = down and max(1, floor(key.size / 22)) or 0
	key.face:ClearAllPoints()
	key.face:SetPoint('TOPLEFT', 0, -travel)
	key.face:SetPoint('BOTTOMRIGHT', 0, -travel)
	Sound(down)
end

local function Tint(key)
	local icon = key.icon
	local db = DB()
	if key.outOfRange then icon:SetVertexColor(ColorOf(db.rangeColor, 1, 0.38, 0.32)); icon:SetDesaturated(false)
	elseif key.usable == false and key.noMana then icon:SetVertexColor(ColorOf(db.manaColor, 0.45, 0.58, 1)); icon:SetDesaturated(false)
	elseif key.usable == false then icon:SetVertexColor(ColorOf(db.unusableColor, 0.5, 0.5, 0.48)); icon:SetDesaturated(true)
	else icon:SetVertexColor(1, 1, 1); icon:SetDesaturated(false) end
	HW.Lamp(key)
end

local function UpdateUsable(key, usable, noMana)
	if usable == nil and key.slot then usable, noMana = IsUsableAction(key.slot) end
	-- A secret answer counts as usable: the key is never wrongly dimmed.
	key.usable, key.noMana = Flag(usable), Flag(noMana)
	if key.usable == nil then key.usable = true end
	Tint(key)
end

local function UpdateRange(key, inRange, checksRange)
	if inRange == nil and checksRange == nil then
		local answer = key.slot and IsActionInRange(key.slot)
		key.outOfRange = not IsSecret(answer) and answer == false
	else
		key.outOfRange = Flag(checksRange) == true and Flag(inRange) == false
	end
	Tint(key)
end

local function UpdateState(key)
	local slot = key.slot
	key.on = slot and key.has and (Flag(IsCurrentAction(slot)) or Flag(IsAutoRepeatAction(slot))) or false
	key.equipped = slot and key.has and Flag(IsEquippedAction(slot)) or false
	HW.Lamp(key)
end

-- A proc: 'pulse' is a lit ring and a slow pulse of the key color, 'ring' the
-- ring alone, 'off' nothing.
local function SetGlow(key, on)
	local style = DB().glow or 'pulse'
	if on == key.glowing and style == key.glowStyle then return end
	key.glowing, key.glowStyle = on, style
	key.pulse:Stop(); key.glow:Hide(); key.ring:Hide()
	if on and style ~= 'off' then
		key.ring:Show()
		if style == 'pulse' then key.glow:Show(); key.pulse:Play() end
	end
end

local function UpdateGlow(key)
	SetGlow(key, key.spell and IsOverlayed and Flag(IsOverlayed(key.spell)) or false)
end

-- Cooldowns run on the client's duration objects; nothing is timed here.
-- The motion layer hears about each change ('cooldown ready' flashes).
local function Notify(kind, cooldown)
	local key = cooldown.kitKey
	if key and Kit.MotionNotify then Kit:MotionNotify(kind, key) end
end

local function ShowCooldown(cooldown, active, duration)
	if IsSecret(active) or active then
		if duration then
			cooldown:SetCooldownFromDurationObject(duration)
			Notify('cooldown-start', cooldown)
		else cooldown:Clear() end
	else
		cooldown:Clear()
		Notify('cooldown-clear', cooldown)
	end
end

local function UpdateCooldown(key)
	local slot = key.slot
	if not slot or not key.has then
		key.cooldown:Clear(); key.charge:Clear(); key.loc:Clear()
		return
	end
	if MODERN_COOLDOWNS then
		local info = C.GetActionCooldown(slot)
		local charges = C.GetActionCharges and C.GetActionCharges(slot)
		local loc = C.GetActionLossOfControlCooldownInfo and C.GetActionLossOfControlCooldownInfo(slot)
		local locActive = loc and loc.isActive
		local replace = loc and Flag(loc.shouldReplaceNormalCooldown)
		ShowCooldown(key.loc, locActive, (IsSecret(locActive) or locActive) and C.GetActionLossOfControlCooldownDuration
			and C.GetActionLossOfControlCooldownDuration(slot))
		if replace then
			key.cooldown:Clear(); key.charge:Clear()
			return
		end
		local active = info and info.isActive
		ShowCooldown(key.cooldown, active, (IsSecret(active) or active) and C.GetActionCooldownDuration(slot))
		local chargeActive = charges and charges.isActive
		ShowCooldown(key.charge, chargeActive, (IsSecret(chargeActive) or chargeActive) and C.GetActionChargeDuration
			and C.GetActionChargeDuration(slot))
		return
	end
	-- Clients without duration objects have no secret cooldowns either.
	local start, duration, enable = GetActionCooldown(slot)
	if IsSecret(start) or IsSecret(duration) then return end
	if start and duration and duration > 0 and enable ~= 0 and enable ~= false then key.cooldown:SetCooldown(start, duration)
	else key.cooldown:Clear() end
end

local function Count(slot)
	if C.GetActionDisplayCount then return C.GetActionDisplayCount(slot) end
	if not (IsConsumableAction(slot) or IsStackableAction(slot)) then return '' end
	local count = GetActionCount(slot)
	if IsSecret(count) then return count end
	return (count and count > 0) and count or ''
end

local function SpellOf(slot)
	local actionType, id, subType = GetActionInfo(slot)
	if IsSecret(actionType) or IsSecret(id) then return nil end
	if actionType == 'spell' then return id end
	if actionType == 'macro' and not IsSecret(subType) and subType == 'spell' then return id end
	return nil
end

-- Spells held down to charge (empowered casts) cast on release. Only out of combat;
-- bar 1 sets this in its paging snippet too.
local function UpdateRelease(key)
	if not (C_Spell and C_Spell.IsPressHoldReleaseSpell) or InCombatLockdown() then return end
	local button = key.button
	local hold = key.spell and C_Spell.IsPressHoldReleaseSpell(key.spell)
	if Flag(hold) then
		button:SetAttribute('pressAndHoldAction', true)
		button:SetAttribute('typerelease', 'actionrelease')
	elseif button:GetAttribute('typerelease') then
		button:SetAttribute('typerelease', nil)
	end
end

local function UpdateLegend(key)
	local db = DB()
	local text = db.hotkeys and key.binding or ''
	local light = LightCap()
	if HW.On() then
		-- Printed on the cap's band, above the icon window: ink on the cap, fitted to the band.
		if key.legendWidth then HW.FitLegend(key.hotkey, text, key.legendWidth, key.legendSize)
		else key.hotkey:SetText(text) end
		key.hotkeyChip:Hide()
		Kit:Tint(key.hotkey, light and (key.has and 'ink' or 'dim') or (key.has and 'darkInk' or 'darkDim'))
		key.hotkey:SetShadowOffset(0, 0)
		return
	end
	key.hotkey:SetText(text)
	local chip = key.has and db.legendChip ~= false and text ~= ''
	key.hotkeyChip:SetShown(chip)
	if chip then
		-- A tiny label of the cap's own color, as the reference prints its legends.
		Kit:Tint(key.hotkeyChip, light and 'key' or 'dark', 0.92)
		Kit:Tint(key.hotkey, light and 'ink' or 'darkInk')
		key.hotkey:SetShadowOffset(0, 0)
	elseif key.has then
		Kit:Tint(key.hotkey, 'white')
		key.hotkey:SetShadowOffset(1, -1)
	else
		-- On an empty cap the legend is printed straight on it.
		Kit:Tint(key.hotkey, light and 'dim' or 'darkDim')
		key.hotkey:SetShadowOffset(0, 0)
	end
end

-- The count on a small gray LCD chip. A secret count is printed and the chip
-- shown, never tested; a plain one hides the chip when there is nothing.
local function UpdateCount(key, count)
	-- A secret count is handed straight on and never tested.
	local secret = IsSecret(count)
	if secret then key.count:SetText(count) else key.count:SetText(count or '') end
	local chip = DB().countChip ~= false
	local shown = secret or (count ~= nil and count ~= '')
	key.countChip:SetShown(chip and shown and true or false)
	if chip then
		Kit:Tint(key.count, 'lcdInk')
		key.count:SetShadowOffset(0, 0)
	else
		Kit:Tint(key.count, 'white')
		key.count:SetShadowOffset(1, -1)
	end
end

-- While something is on the cursor every key shows, so it can be dropped.
P.dragging = false
local function UpdateGrid(key)
	local show = key.has or P.dragging or BarDB(key.bar.id).grid ~= false
	key.button:SetAlpha(show and 1 or 0)
end

local function UpdateKey(key)
	local slot = key.slot
	local has = slot and HasAction(slot)
	key.has = Flag(has) ~= false and slot ~= nil
	if key.has then
		key.icon:SetTexture(GetActionTexture(slot))
		key.icon:Show()
		key.spell = SpellOf(slot)
		UpdateCount(key, Count(slot))
		if DB().macros then key.macro:SetText(GetActionText(slot)) else key.macro:SetText('') end
	else
		key.icon:Hide()
		key.spell = nil
		UpdateCount(key, '')
		key.macro:SetText('')
	end
	-- An empty key is a blank keycap: fainter, no icon window, its legend only.
	-- Hardware: a blank cap in its slot, as solid as any other.
	local empty = HW.On() and 1 or Kit:Clamp(tonumber(DB().emptyAlpha) or 0.5, 0.15, 1)
	key.skin:SetAlpha(key.has and 1 or empty)
	key.window:SetShown(key.has and true or false)
	UpdateLegend(key)
	UpdateGrid(key)
	UpdateCooldown(key)
	UpdateUsable(key)
	UpdateRange(key)
	UpdateState(key)
	UpdateGlow(key)
	UpdateRelease(key)
end

-- Range checks are switched on per slot, so the client only reports slots in view.
local watched = {}
local function WatchSlot(key, slot)
	if key.slot == slot then return end
	local old = key.slot
	if old then
		if bySlot[old] then bySlot[old][key] = nil end
		if RANGE_EVENTS then
			watched[old] = (watched[old] or 1) - 1
			if watched[old] <= 0 then watched[old] = nil; C.EnableActionRangeCheck(old, false) end
		end
	end
	key.slot = slot
	if slot then
		bySlot[slot] = bySlot[slot] or {}
		bySlot[slot][key] = true
		if RANGE_EVENTS then
			watched[slot] = (watched[slot] or 0) + 1
			if watched[slot] == 1 then C.EnableActionRangeCheck(slot, true) end
		end
	end
end

local function ForKeys(func) for _, key in ipairs(keys) do UI:Safe(func, key) end end

-- Bar 1's page, as Blizzard picks it: vehicle, override and possess bars first,
-- then a temporary shapeshift bar, the bar pages, then a bonus bar (stances,
-- stealth, forms, skyriding), else page 1.
local function PageConditions()
	local function Index(name)
		local func = API(name)
		if not func then return nil end
		local ok, index = pcall(func)
		return ok and type(index) == 'number' and index or nil
	end
	local parts = {}
	local override, vehicle, temp = Index('GetOverrideBarIndex'), Index('GetVehicleBarIndex'), Index('GetTempShapeshiftBarIndex')
	if override then parts[#parts + 1] = format('[overridebar] %d;', override) end
	if vehicle then parts[#parts + 1] = format('[vehicleui][possessbar] %d;', vehicle) end
	if temp then parts[#parts + 1] = format('[shapeshift] %d;', temp) end
	parts[#parts + 1] = '[bar:2] 2; [bar:3] 3; [bar:4] 4; [bar:5] 5; [bar:6] 6; '..
		-- One token per bonus bar: the driver only re-pages when the token changes.
		'[bonusbar:1,stealth] bonus1s; [bonusbar:1] bonus1; [bonusbar:2] bonus2; [bonusbar:3] bonus3; [bonusbar:4] bonus4; [bonusbar:5] bonus5; 1'
	return table.concat(parts, ' ')
end

local RELEASE_SNIPPET = [[
	local actionType, id, subType = GetActionInfo(self:GetAttribute('action'))
	local spell = (actionType == 'spell' or (actionType == 'macro' and subType == 'spell')) and id
	if spell and IsPressHoldReleaseSpell and IsPressHoldReleaseSpell(spell) then
		self:SetAttribute('pressAndHoldAction', true)
		self:SetAttribute('typerelease', 'actionrelease')
	elseif self:GetAttribute('typerelease') then
		self:SetAttribute('typerelease', nil)
	end
]]

local function FaceInset(size)
	local inset = tonumber(DB().iconInset)
	if inset and inset > 0 then return Kit:Clamp(floor(inset), 2, floor(size / 3)) end
	return max(4, floor(size * 0.16 + 0.5))
end


-- Where a legend sits on the key, as an offset direction from that corner.
local Corner
do
local CORNERS = {TOPLEFT = {1, -1}, TOP = {0, -1}, TOPRIGHT = {-1, -1}, BOTTOMLEFT = {1, 1}, BOTTOM = {0, 1}, BOTTOMRIGHT = {-1, 1}}
function Corner(text, point, inset)
	local sign = CORNERS[point] or CORNERS.TOPLEFT
	text:ClearAllPoints()
	text:SetPoint(CORNERS[point] and point or 'TOPLEFT', sign[1] * (inset + 1), sign[2] * (inset + 1))
end
end

local function Sized(value, auto)
	value = tonumber(value)
	return (value and value > 0) and floor(value) or auto
end

-- Everything on a key that follows the settings: legends, countdown numbers.
local function ApplyLook(key)
	local db, size = DB(), key.size
	local inset = FaceInset(size)
	if HW.On() then
		-- The legend is printed in the cap's band; the lamp sits at its other end.
		local side, band = HW.Window(size, inset)
		local point = db.hotkeyPoint or 'TOPLEFT'
		local align = point:find('RIGHT') and 'RIGHT' or ((point == 'TOP' or point == 'BOTTOM') and 'CENTER' or 'LEFT')
		-- The legend's box: the band between the cap's sides, less the lamp's room.
		key.legendSize = Sized(db.hotkeySize, HW.LegendSize(band))
		key.legendWidth = size - 2 * side - (align == 'CENTER' and 12 or 7)
		key.hotkey:SetJustifyH(align)
		key.hotkey:ClearAllPoints()
		local y = -band / 2
		if align == 'RIGHT' then key.hotkey:SetPoint('RIGHT', key.face, 'TOPRIGHT', -side, y)
		elseif align == 'CENTER' then key.hotkey:SetPoint('CENTER', key.face, 'TOP', 0, y)
		else key.hotkey:SetPoint('LEFT', key.face, 'TOPLEFT', side, y) end
		key.lamp:ClearAllPoints()
		if align == 'RIGHT' then key.lamp:SetPoint('CENTER', key.face, 'TOPLEFT', side + 2, y)
		else key.lamp:SetPoint('CENTER', key.face, 'TOPRIGHT', -side - 2, y) end
		-- Counts on their LCD chip over the window's corner; macro names along its foot.
		Kit:Font(key.count, Sized(db.countSize, max(7, floor(size * 0.22))), '', true)
		local countPoint = db.countPoint or 'BOTTOMRIGHT'
		key.count:ClearAllPoints()
		key.count:SetPoint(countPoint, key.icon, countPoint, countPoint:find('LEFT') and 2 or (countPoint:find('RIGHT') and -2 or 0), 2)
		Kit:Font(key.macro, Sized(db.macroSize, 7), '', false)
		key.macro:ClearAllPoints()
		key.macro:SetPoint('BOTTOMLEFT', key.icon, 'BOTTOMLEFT', 1, 1)
		key.macro:SetPoint('BOTTOMRIGHT', key.icon, 'BOTTOMRIGHT', -1, 1)
		UpdateLegend(key)
	else
		Kit:Font(key.hotkey, Sized(db.hotkeySize, max(7, floor(size * 0.22))), '', true)
		Corner(key.hotkey, db.hotkeyPoint, inset + 1)
		Kit:Font(key.count, Sized(db.countSize, max(7, floor(size * 0.24))), '', true)
		Corner(key.count, db.countPoint or 'BOTTOMRIGHT', inset + 1)
		Kit:Font(key.macro, Sized(db.macroSize, 7), '', false)
		key.macro:ClearAllPoints()
		key.macro:SetPoint('BOTTOMLEFT', inset, inset)
		key.macro:SetPoint('BOTTOMRIGHT', -inset, inset)
	end
	local cooldown = key.cooldown
	if cooldown.SetHideCountdownNumbers then cooldown:SetHideCountdownNumbers(db.cdNumbers == false) end
	-- Short cooldowns (the global cooldown) show no numbers.
	if cooldown.SetMinimumCountdownDuration then
		cooldown:SetMinimumCountdownDuration(floor((tonumber(db.cdMin) or 0) * 1000))
	end
	if key.numbers then
		Kit:Font(key.numbers, Sized(db.cdSize, max(9, floor(size * 0.36))), 'OUTLINE', true)
		key.numbers:SetTextColor(ColorOf(db.cdColor, 1, 1, 1))
	end
end

-- A key at a new size: its cap, icon window, glow and lamp. Out of combat only.
local function SizeKey(key, size)
	key.size = size
	key.button:SetSize(size, size)
	key.skin.kitMaxCorner = max(6, floor(size * 0.27))
	Kit:FitSprite(key.skin, size, size)
	local inset = FaceInset(size)
	local left, top, right, bottom = HW.Window(size, inset)
	key.icon:ClearAllPoints()
	key.icon:SetPoint('TOPLEFT', left, -top)
	key.icon:SetPoint('BOTTOMRIGHT', -right, bottom)
	HW.Crop(key.icon, size - left - right, size - top - bottom)
	key.glow:ClearAllPoints()
	key.glow:SetPoint('TOPLEFT', -size * 0.28, size * 0.28)
	key.glow:SetPoint('BOTTOMRIGHT', size * 0.28, -size * 0.28)
	Kit:Place(key.window, key.icon, 0, 0, 0, 0)
	key.lamp:ClearAllPoints()
	key.lamp:SetPoint('TOPRIGHT', -max(2, floor(inset / 2)), -max(2, floor(inset / 2)))
	HW.ShowSlot(key.slotRing, HW.On())
	ApplyLook(key)
end

local function CreateKey(bar, index, header, size)
	local name = format('JiberishSpec01Bar%dKey%d', bar.id, index)
	local button = CreateFrame('CheckButton', name, header, 'SecureActionButtonTemplate')
	button:SetSize(size, size)
	-- The ID stays 0: with an ID, Blizzard's secure click code works out the
	-- slot from the bar page and ignores the 'action' attribute.
	button:SetAttribute('index', index)
	button:RegisterForClicks('AnyDown', 'AnyUp')
	button:RegisterForDrag('LeftButton', 'RightButton')
	button:SetAttribute('type', 'action')
	button:SetAttribute('action', (bar.page - 1) * 12 + index)
	button:SetAttribute('flyoutDirection', 'UP')
	button:SetAttribute('checkselfcast', true)
	button:SetAttribute('checkfocuscast', true)
	button:SetAttribute('checkmouseovercast', true)
	if bar.paging then
		button:SetAttribute('_childupdate-page', [[
			local page = tonumber(message) or 1
			self:SetAttribute('action', (page - 1) * 12 + self:GetAttribute('index'))
		]]..(C_Spell and C_Spell.IsPressHoldReleaseSpell and RELEASE_SNIPPET or ''))
	end
	-- Drag a spell off (only with the pickup modifier while bars are locked)
	-- or onto a key, in combat too.
	header:WrapScript(button, 'OnDragStart', [[
		if self:GetAttribute('buttonlock') and not IsModifiedClick('PICKUPACTION') then return false end
		return 'action', self:GetAttribute('action')
	]])
	header:WrapScript(button, 'OnReceiveDrag', [[
		return 'action', self:GetAttribute('action')
	]])

	-- The keycap, the legend that travels with it, and lamps above everything.
	local key = CreateFrame('Frame', nil, button)
	key:SetAllPoints()
	key:EnableMouse(false)
	key.button, key.size, key.bar, key.index = button, size, bar, index
	key.command = bar.command..index
	key.skin = Kit:Skin(key, Sprites()[1], 'BACKGROUND', 0)
	key.skin.kitMaxCorner = max(6, floor(size * 0.27))
	Kit:FitSprite(key.skin, size, size)
	-- The hole in the housing the cap sits in (Hardware look).
	key.slotRing = HW.Slot(key, key)
	local face = CreateFrame('Frame', nil, key)
	face:SetPoint('TOPLEFT')
	face:SetPoint('BOTTOMRIGHT')
	key.face = face
	local inset = FaceInset(size)
	key.icon = face:CreateTexture(nil, 'ARTWORK')
	key.icon:SetPoint('TOPLEFT', inset, -inset)
	key.icon:SetPoint('BOTTOMRIGHT', -inset, inset)
	key.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	local mask = face:CreateMaskTexture()
	mask:SetTexture(Kit.media..'mask-icon.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
	mask:SetAllPoints(key.icon)
	key.icon:AddMaskTexture(mask)
	-- The icon sits in a window cut into the cap: a soft inner shadow at its edge.
	key.window = Kit:Texture(face, 'inset-6', 'ARTWORK', 2)
	Kit:Place(key.window, key.icon, 0, 0, 0, 0)
	key.window:SetVertexColor(0, 0, 0, 0.6)
	key.hover = face:CreateTexture(nil, 'OVERLAY', nil, 1)
	key.hover:SetAllPoints(key.icon)
	key.hover:SetColorTexture(1, 1, 1, 0.14)
	key.hover:AddMaskTexture(mask)
	key.hover:Hide()

	local function Cooldown(swipe, drawSwipe)
		local cooldown = CreateFrame('Cooldown', nil, face, 'CooldownFrameTemplate')
		cooldown:SetAllPoints(key.icon)
		cooldown:SetDrawEdge(not drawSwipe)
		cooldown:SetDrawSwipe(drawSwipe)
		cooldown:SetDrawBling(false)
		if drawSwipe and cooldown.SetSwipeTexture then cooldown:SetSwipeTexture(Kit.media..'mask-icon.tga', swipe[1], swipe[2], swipe[3], swipe[4]) end
		return cooldown
	end
	key.cooldown = Cooldown({0, 0, 0, 0.72}, true)
	if HW.On() then
		-- The reference's sweep: a lighter shade with a lit edge riding it.
		key.cooldown:SetSwipeColor(0, 0, 0, 0.62)
		key.cooldown:SetDrawEdge(true)
		local r, g, b = Kit:RGB('lamp')
		if key.cooldown.SetEdgeTexture then pcall(key.cooldown.SetEdgeTexture, key.cooldown, [[Interface\Cooldown\edge]], r, g, b, 1) end
	end
	-- Our own cooldown frame, so this field and hook touch nothing of Blizzard's.
	key.cooldown.kitKey = key
	key.cooldown:HookScript('OnCooldownDone', function() if Kit.MotionNotify then Kit:MotionNotify('cooldown-done', key) end end)
	key.charge = Cooldown(nil, false)
	key.charge:SetHideCountdownNumbers(true)
	key.loc = Cooldown({0.6, 0.05, 0.03, 0.6}, true)
	key.numbers = key.cooldown.GetCountdownFontString and key.cooldown:GetCountdownFontString()

	local top = CreateFrame('Frame', nil, face)
	top:SetAllPoints()
	top:SetFrameLevel(face:GetFrameLevel() + 4)
	-- Hardware prints the legend on the cap, with no shadow; Classic over the icon.
	key.hotkey = Kit:Text(top, '', max(7, floor(size * 0.24)), 'white', true, not HW.On())
	key.hotkey:SetPoint('TOPLEFT', inset + 1, -inset - 1)
	key.hotkeyChip = Kit:Texture(top, 'round-3', 'ARTWORK', 0)
	Kit:Place(key.hotkeyChip, key.hotkey, 2, 1, 2, 1)
	key.hotkeyChip:Hide()
	key.count = Kit:Text(top, '', max(7, floor(size * 0.24)), 'lcdInk', true, false)
	key.count:SetPoint('BOTTOMRIGHT', -inset, inset)
	key.countChip = Kit:Texture(top, 'round-3', 'ARTWORK', 0)
	Kit:Place(key.countChip, key.count, 2, 1, 2, 1)
	Kit:Tint(key.countChip, 'lcd', 0.95)
	key.countChip:Hide()
	key.macro = Kit:Text(top, '', 7, 'white', false, true)
	key.macro:SetPoint('BOTTOMLEFT', inset, inset)
	key.macro:SetPoint('BOTTOMRIGHT', -inset, inset)
	key.macro:SetWordWrap(false)
	key.lamp = Kit:Led(top, 4, false)
	key.lamp:SetPoint('TOPRIGHT', -max(2, floor(inset / 2)), -max(2, floor(inset / 2)))
	Kit:ShowLed(key.lamp, false)
	-- A proc: a lit ring round the legend and a slow pulse of the key color.
	key.ring = Kit:Texture(top, 'ring-6', 'OVERLAY', 3)
	Kit:Place(key.ring, key.icon, 1, 1, 1, 1)
	Kit:Tint(key.ring, 'lamp')
	key.ring:Hide()
	key.glow = top:CreateTexture(nil, 'OVERLAY', nil, 2)
	key.glow:SetTexture(Kit.media..'glow.tga')
	key.glow:SetBlendMode('ADD')
	key.glow:SetPoint('TOPLEFT', -size * 0.28, size * 0.28)
	key.glow:SetPoint('BOTTOMRIGHT', size * 0.28, -size * 0.28)
	Kit:Tint(key.glow, 'lamp', 0.8)
	key.glow:Hide()
	key.pulse = key.glow:CreateAnimationGroup()
	key.pulse:SetLooping('BOUNCE')
	local fade = key.pulse:CreateAnimation('Alpha')
	fade:SetFromAlpha(0.25)
	fade:SetToAlpha(1)
	fade:SetDuration(0.4)
	fade:SetSmoothing('IN_OUT')

	keyOf[button] = key
	keys[#keys + 1] = key
	SizeKey(key, size)

	-- Clicks come down and up (key binds too), so the cap goes down with them.
	button:SetScript('PostClick', function(self, _, down)
		local pressed = keyOf[self]
		if down == nil then
			Press(pressed, true)
			C_Timer.After(0.08, function() Press(pressed, false) end)
		else
			Press(pressed, down and true or false)
		end
	end)
	button:HookScript('OnMouseUp', function(self) Press(keyOf[self], false) end)
	button:HookScript('OnHide', function(self) Press(keyOf[self], false) end)
	button:SetScript('OnEnter', function(self)
		local hovered = keyOf[self]
		hovered.hover:Show()
		if not hovered.has then return end
		if GameTooltip_SetDefaultAnchor then GameTooltip_SetDefaultAnchor(GameTooltip, self)
		else GameTooltip:SetOwner(self, 'ANCHOR_RIGHT') end
		GameTooltip:SetAction(hovered.slot)
		GameTooltip:Show()
	end)
	button:SetScript('OnLeave', function(self)
		keyOf[self].hover:Hide()
		GameTooltip:Hide()
	end)
	-- Paging (and drags) change the action; the key follows.
	button:SetScript('OnAttributeChanged', function(self, attribute, value)
		if attribute ~= 'action' then return end
		local changed = keyOf[self]
		WatchSlot(changed, tonumber(value))
		UI:Safe(UpdateKey, changed)
	end)
	WatchSlot(key, button:GetAttribute('action'))
	return button
end

-- Countdown numbers only show while the game's countdownForCooldowns setting
-- is on. With our switch on, it is turned on (the player's own value saved
-- once); switched off, their value comes back.
local function ApplyCountdownCVar()
	if InCombatLockdown() then return UI:AfterCombat(ApplyCountdownCVar, 'ab.countdown') end
	local get = (C_CVar and C_CVar.GetCVar) or GetCVar
	local set = (C_CVar and C_CVar.SetCVar) or SetCVar
	if not (get and set and UI.Account) then return end
	local saved = UI:Account('cvars')
	if DB().cdNumbers ~= false then
		local ok, current = pcall(get, 'countdownForCooldowns')
		if ok and current ~= nil and tostring(current) ~= '1' then
			if saved.countdownForCooldowns == nil then saved.countdownForCooldowns = tostring(current) end
			pcall(set, 'countdownForCooldowns', '1')
		end
	elseif saved.countdownForCooldowns ~= nil then
		pcall(set, 'countdownForCooldowns', saved.countdownForCooldowns)
		saved.countdownForCooldowns = nil
	end
end

-- Lock bars: follow the game's own setting, or force it either way.
local function ApplyLock()
	local lock = DB().lock
	if lock ~= 'on' and lock ~= 'off' then return end
	if InCombatLockdown() then return UI:AfterCombat(ApplyLock, 'ab.lock') end
	local set = (C_CVar and C_CVar.SetCVar) or SetCVar
	if set then pcall(set, 'lockActionBars', lock == 'on' and '1' or '0') end
end

-- Attributes read from settings that may only change out of combat.
local function ApplyCVars()
	if InCombatLockdown() then return UI:AfterCombat(ApplyCVars, 'ab.cvars') end
	local onDown = GetCVarBool and GetCVarBool('ActionButtonUseKeyDown')
	local locked = GetCVarBool and GetCVarBool('lockActionBars')
	for _, key in ipairs(keys) do
		key.button:SetAttribute('useOnKeyDown', onDown and true or false)
		key.button:SetAttribute('buttonlock', locked and true or false)
	end
end

-- Key binds -------------------------------------------------------------------------
-- Each key answers the game's own binding command (ACTIONBUTTON1, MULTIACTIONBAR1BUTTON1, ...),
-- so the binding window keeps working.
local binder = CreateFrame('Frame')
local extraKeys = {} -- {button, command, legend fontstring} for pet and stance keys
local dressed = {} -- Blizzard pet, stance and ability buttons -> our key parts

local function Bind()
	if InCombatLockdown() then return UI:AfterCombat(Bind, 'ab.bind') end
	ClearOverrideBindings(binder)
	local function BindCommand(command, buttonName)
		local first
		for _, binding in ipairs({GetBindingKey(command)}) do
			SetOverrideBindingClick(binder, false, binding, buttonName, 'LeftButton')
			first = first or binding
		end
		return first
	end
	for _, key in ipairs(keys) do
		local shown = key.index <= Shown(key.bar.id)
		key.binding = shown and Legend(BindCommand(key.command, key.button:GetName())) or ''
		UpdateLegend(key)
	end
	for _, extra in ipairs(extraKeys) do
		local legend = Legend(BindCommand(extra.command, extra.button:GetName()))
		if extra.hotkey then
			local text = DB().hotkeys and legend or ''
			local key = dressed[extra.button]
			if HW.On() and key and key.legendWidth then HW.FitLegend(extra.hotkey, text, key.legendWidth, key.legendSize)
			else extra.hotkey:SetText(text) end
		end
	end
end

-- Pet and stance keys: the game's own buttons, dressed as keys ----------------------
-- Pet keys are Blizzard's PetActionButtons moved into our module, as ElvUI does;
-- stance keys are new StanceButtonTemplate buttons. They keep the game's own
-- click and autocast handling; this only paints them.
-- Nothing runs every frame: the cap goes down from the button's own mouse and
-- click scripts (key binds click too), and the lamp follows the pet, stance
-- and action state events.
local function DressedPress(key, down)
	if not key or key.down == down then return end
	key.down = down
	Kit:SetSprite(key.skin, (key.sprites or Sprites())[down and 2 or 1])
	Sound(down)
end

local function DressedChecked(key)
	local okChecked, checked = pcall(key.button.GetChecked, key.button)
	checked = okChecked and Flag(checked) or false
	if checked ~= key.checked then
		key.checked = checked
		Kit:SetLed(key.lamp, checked)
		Kit:ShowLed(key.lamp, checked)
	end
end

local function RefreshDressed()
	for _, key in pairs(dressed) do UI:Safe(DressedChecked, key) end
end

local function WatchPress(button)
	button:HookScript('OnMouseDown', function(self)
		local key = dressed[self]
		if key then key.held = true end
		DressedPress(key, true)
	end)
	button:HookScript('OnMouseUp', function(self)
		local key = dressed[self]
		if key then key.held = nil end
		DressedPress(key, false)
	end)
	button:HookScript('OnHide', function(self) DressedPress(dressed[self], false) end)
	-- A key bind: a short press, and the lamp checked once the game has answered.
	button:HookScript('PostClick', function(self)
		local key = dressed[self]
		if not key then return end
		if not key.held then
			DressedPress(key, true)
			C_Timer.After(0.08, function() if not key.held then DressedPress(key, false) end end)
		end
		C_Timer.After(0, function() UI:Safe(DressedChecked, key) end)
	end)
end

-- round: a big round key (the extra and zone abilities, Hardware look).
local function Dress(button, size, round)
	if dressed[button] then return dressed[button] end
	local name = button:GetName() or ''
	local hardware = HW.On()
	round = round and hardware
	button:SetSize(size, size)
	for _, part in ipairs({'SlotArt', 'SlotBackground', 'RightDivider', 'BottomDivider', 'FlyoutBorderShadow', 'Border', 'NormalTexture2'}) do
		Fade(button[part])
	end
	Fade(_G[name..'NormalTexture'])
	if button.GetNormalTexture then Fade(button:GetNormalTexture()) end
	if button.GetPushedTexture then Fade(button:GetPushedTexture()) end
	if button.GetCheckedTexture then Fade(button:GetCheckedTexture()) end
	local inset = FaceInset(size)
	local left, top, right, bottom = HW.Window(size, inset)
	if round then left, top, right, bottom = inset + 2, inset + 2, inset + 2, inset + 2 end
	local icon = button.icon or button.Icon or _G[name..'Icon']
	local maskFile = round and 'circle' or 'mask-icon'
	if icon then
		icon:ClearAllPoints()
		icon:SetPoint('TOPLEFT', left, -top)
		icon:SetPoint('BOTTOMRIGHT', -right, bottom)
		HW.Crop(icon, size - left - right, size - top - bottom)
		local mask = button.IconMask
		if mask and mask.SetTexture then
			mask:SetTexture(Kit.media..maskFile..'.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
			mask:ClearAllPoints()
			mask:SetAllPoints(icon)
		end
		local cooldown = button.cooldown or _G[name..'Cooldown']
		if cooldown and not Forbidden(cooldown) then
			cooldown:ClearAllPoints()
			cooldown:SetAllPoints(icon)
			if cooldown.SetSwipeTexture then cooldown:SetSwipeTexture(Kit.media..maskFile..'.tga', 0, 0, 0, 0.72) end
		end
		local highlight = button.GetHighlightTexture and button:GetHighlightTexture()
		if highlight then highlight:ClearAllPoints(); highlight:SetAllPoints(icon); highlight:SetAlpha(0.2) end
	end
	local hotkey = button.HotKey or _G[name..'HotKey']
	if hotkey then
		hotkey:ClearAllPoints()
		if hardware and not round then
			-- Printed on the cap's band, in ink, like the action keys, in a box
			-- that ends short of the lamp (the game's own box is wider and right-aligned).
			Kit:Font(hotkey, HW.LegendSize(top), '', true)
			hotkey:SetJustifyH('LEFT')
			hotkey:SetPoint('LEFT', button, 'TOPLEFT', left, -top / 2)
			hotkey:SetWidth(max(size - left - right - 7, 1))
			hotkey:SetWordWrap(false)
			hotkey:SetShadowOffset(0, 0)
			local r, g, b = Kit:RGB(LightCap() and 'ink' or 'darkInk')
			hotkey:SetTextColor(r, g, b)
		else
			Kit:Font(hotkey, max(7, floor(size * 0.26)), 'OUTLINE', true)
			hotkey:SetPoint('TOPLEFT', inset, -inset)
		end
	end
	local count = button.Count or _G[name..'Count']
	if count then Kit:Font(count, max(8, floor(size * 0.3)), 'OUTLINE', true) end
	local key = CreateFrame('Frame', nil, button)
	key.button = button
	key:SetAllPoints()
	key:SetFrameLevel(max(button:GetFrameLevel() - 1, 0))
	key:EnableMouse(false)
	key.sprites = round and {'key-round', 'key-round-down'} or nil
	key.skin = Kit:Skin(key, (key.sprites or Sprites())[1], 'BACKGROUND', 0)
	key.skin.kitMaxCorner = max(5, floor(size * 0.27))
	Kit:FitSprite(key.skin, size, size)
	if hardware then
		key.slotRing = HW.Slot(key, key, round)
		HW.ShowSlot(key.slotRing, true)
	end
	local lid = CreateFrame('Frame', nil, button)
	lid:SetAllPoints()
	lid:SetFrameLevel(button:GetFrameLevel() + 3)
	lid:EnableMouse(false)
	if icon then
		if round then
			key.window = Kit:Texture(lid, 'circle-ring', 'ARTWORK', 0)
			Kit:Place(key.window, icon, 1, 1, 1, 1)
			key.window:SetVertexColor(0, 0, 0, 0.45)
		else
			key.window = Kit:Texture(lid, 'inset-6', 'ARTWORK', 0)
			Kit:Place(key.window, icon, 0, 0, 0, 0)
			key.window:SetVertexColor(0, 0, 0, 0.6)
		end
	end
	key.lamp = Kit:Led(lid, 4, false)
	if hardware and not round then key.lamp:SetPoint('CENTER', button, 'TOPRIGHT', -right - 2, -top / 2)
	else key.lamp:SetPoint('TOPRIGHT', -2, -2) end
	Kit:ShowLed(key.lamp, false)
	key.hotkey = hotkey
	key.legendWidth, key.legendSize = size - left - right - 7, HW.LegendSize(top)
	dressed[button] = key
	WatchPress(button)
	DressedChecked(key)
	return key
end

local petKeys, stanceKeys = {}, {}

local function UpdatePet()
	C_Timer.After(0, RefreshDressed)
	for index, button in ipairs(petKeys) do
		local ok, name, texture, isToken, isActive, autoCastAllowed, autoCastEnabled = pcall(GetPetActionInfo, index)
		if ok then
			local icon = button.icon or _G[button:GetName()..'Icon']
			if icon then
				if texture then
					icon:SetTexture(isToken and _G[texture] or texture)
					icon:Show()
				else
					icon:Hide()
				end
			end
			local follow = not IsSecret(name) and name == 'PET_ACTION_FOLLOW'
			button:SetChecked(Flag(isActive) and not follow or false)
			local overlay = button.AutoCastOverlay
			if overlay then
				overlay:SetShown(Flag(autoCastAllowed) or false)
				if overlay.ShowAutoCastEnabled then overlay:ShowAutoCastEnabled(Flag(autoCastEnabled) or false) end
			elseif button.AutoCastable then
				button.AutoCastable:SetShown(Flag(autoCastAllowed) or false)
				local shine = button.AutoCastShine
				if shine and AutoCastShine_AutoCastStart then
					if Flag(autoCastEnabled) then AutoCastShine_AutoCastStart(shine) else AutoCastShine_AutoCastStop(shine) end
				end
			end
			if icon then
				local usable = GetPetActionSlotUsable and GetPetActionSlotUsable(index)
				local dim = texture and (not (PetHasActionBar and PetHasActionBar()) or Flag(usable) == false)
				icon:SetDesaturated(dim and true or false)
				icon:SetVertexColor(dim and 0.5 or 1, dim and 0.5 or 1, dim and 0.48 or 1)
			end
			local cooldown = button.cooldown or _G[button:GetName()..'Cooldown']
			if cooldown and CooldownFrame_Set and GetPetActionCooldown then
				pcall(function() CooldownFrame_Set(cooldown, GetPetActionCooldown(index)) end)
			end
		end
	end
end

local function UpdateStance()
	C_Timer.After(0, RefreshDressed)
	local forms = GetNumShapeshiftForms and GetNumShapeshiftForms() or 0
	for index, button in ipairs(stanceKeys) do
		if index <= forms then
			local ok, texture, isActive, isCastable = pcall(GetShapeshiftFormInfo, index)
			if ok then
				local icon = button.icon or _G[button:GetName()..'Icon']
				if icon then
					icon:SetTexture(texture)
					icon:SetDesaturated(Flag(isCastable) == false)
				end
				button:SetChecked(Flag(isActive) or false)
				local cooldown = button.cooldown or _G[button:GetName()..'Cooldown']
				if cooldown and CooldownFrame_Set and GetShapeshiftFormCooldown then
					pcall(function() CooldownFrame_Set(cooldown, GetShapeshiftFormCooldown(index)) end)
				end
			end
		end
	end
end


-- Shared with the other action bar files.
P.ApplyCountdownCVar = ApplyCountdownCVar
P.ApplyCVars = ApplyCVars
P.ApplyLock = ApplyLock
P.ApplyLook = ApplyLook
P.Bind = Bind
P.binder = binder
P.bySlot = bySlot
P.CreateKey = CreateKey
P.Dress = Dress
P.dressed = dressed
P.extraKeys = extraKeys
P.ForKeys = ForKeys
P.keyOf = keyOf
P.keys = keys
P.PageConditions = PageConditions
P.petKeys = petKeys
P.RefreshDressed = RefreshDressed
P.SetGlow = SetGlow
P.SizeKey = SizeKey
P.stanceKeys = stanceKeys
P.UpdateCooldown = UpdateCooldown
P.UpdateGlow = UpdateGlow
P.UpdateGrid = UpdateGrid
P.UpdateKey = UpdateKey
P.UpdatePet = UpdatePet
P.UpdateRange = UpdateRange
P.UpdateStance = UpdateStance
P.UpdateState = UpdateState
P.UpdateUsable = UpdateUsable
