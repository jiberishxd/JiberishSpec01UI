-- Buffs and debuffs as SPEC-01 keys. Blizzard's aura frames stay in charge
-- (right-click to cancel, Edit Mode size and layout, its timers); each aura
-- button is set on a light key with its icon inset and rounded as a key's
-- legend, the time left printed on a small gray LCD chip under it, the stack
-- count in bold Plex, and a debuff's type (or a weapon enchant) as a colored
-- ring around the key. The collapse button becomes a round key.
--
-- Aura buttons come from a pool and are reused: each is dressed once, the
-- first time a pass sees it, and passes run one frame after Blizzard updates
-- its auras. Nothing is written onto Blizzard's buttons and none of their
-- methods are hooked; durations and colors, which can be secret, go straight
-- from Blizzard to its own regions and are never read here.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame = CreateFrame
local max, floor = math.max, math.floor

local module = UI:RegisterModule('buffs', {})
local Forbidden, IsSecret = UI.Util.Forbidden, UI.Util.IsSecret

-- defaults:begin
-- keyPad: how far the key shows around each icon. time: 'chip' (on a gray LCD
-- chip flush under the key), 'text' (plain, under the key) or 'off'. timeSize,
-- countSize 0 = auto. line: a thin bar that drains with the time left, 'top'
-- (above the key), 'bottom' (between the key and its chip) or 'off'. led: the
-- debuff type (and an aura about to run out) as a lamp on the key.
UI:RegisterDefaults('buffs', {keyPad = 2, time = 'chip', timeSize = 0, countSize = 0, ring = true, housing = false,
	line = 'top', led = true, countChip = true})
-- defaults:end
local function DB() return UI.db.buffs end
local function Sized(value, auto)
	value = tonumber(value)
	return (value and value > 0) and floor(value) or auto
end

local STRETCHED = Enum and Enum.UITextureSliceMode and Enum.UITextureSliceMode.Stretched
-- ring-6 is authored at twice its size, with 15 px slices.
local RING_SCALE, RING_SLICE = 0.5, 15
local REMAINING = Enum and Enum.StatusBarTimerDirection and Enum.StatusBarTimerDirection.RemainingTime
local IMMEDIATE = Enum and Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.Immediate

-- Per button: what we built and the parts we found, made once. Buttons that
-- turned out not to be auras are remembered too, so they are passed over.
local dressed = setmetatable({}, {__mode = 'k'})
local notAura = setmetatable({}, {__mode = 'k'})
local collapse
-- Set when Edit Mode or the grid relaid the buttons: their times are placed again.
local relayout = true

local function Parts(button)
	local name = button.GetName and button:GetName()
	local function Named(suffix) return name and _G[name..suffix] end
	return {
		icon = button.Icon or button.icon or Named('Icon'),
		count = button.Count or button.count or Named('Count'),
		duration = button.Duration or button.duration or Named('Duration'),
		border = button.DebuffBorder or button.Border or Named('Border'),
		enchant = button.TempEnchantBorder,
	}
end

-- The time left, written by the client itself from the aura's duration object:
-- seconds, then minutes, then hours. nil when the client has no such formatter.
local formatter
local function Formatter()
	if formatter ~= nil then return formatter or nil end
	formatter = false
	if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter and Enum and Enum.NumericRuleFormatRounding) then return nil end
	local Down, Up = Enum.NumericRuleFormatRounding.Down, Enum.NumericRuleFormatRounding.Up or Enum.NumericRuleFormatRounding.Down
	local f = C_StringUtil.CreateNumericRuleFormatter()
	local ok = pcall(f.SetBreakpoints, f, {
		{threshold = 0, format = '%d', step = 1, rounding = Up},
		{threshold = 60, format = '%dm', step = 1, rounding = Down, components = {{div = 60}}},
		{threshold = 3600, format = '%dh', step = 1, rounding = Down, components = {{div = 3600}}},
	})
	if ok then formatter = f end
	return formatter or nil
end

-- Which aura a Blizzard button shows, read (never written) from what it was
-- given, and that aura's duration object. Anything secret or missing: nil.
local function AuraDuration(button)
	if not (C_UnitAuras and C_UnitAuras.GetAuraDuration) then return nil end
	local info = button.buttonInfo
	if type(info) ~= 'table' then return nil end
	local kind = info.auraType
	if IsSecret(kind) or kind == 'TempEnchant' then return nil end
	local unit = info.unit
	if IsSecret(unit) or type(unit) ~= 'string' then
		local frame = _G.BuffFrame
		unit = frame and not IsSecret(frame.unit) and type(frame.unit) == 'string' and frame.unit or 'player'
	end
	local id = info.auraInstanceID
	if IsSecret(id) or type(id) ~= 'number' then
		local index = info.index
		if IsSecret(index) or type(index) ~= 'number' or not C_UnitAuras.GetAuraDataByIndex then return nil end
		local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, unit, index, kind == 'Debuff' and 'HARMFUL' or 'HELPFUL')
		if not ok or type(data) ~= 'table' then return nil end
		id = data.auraInstanceID
		if IsSecret(id) or type(id) ~= 'number' then return nil end
	end
	local ok, duration = pcall(C_UnitAuras.GetAuraDuration, unit, id)
	if ok and duration then return duration, id end
	return nil
end

-- Blizzard colors these rings itself (debuff type, weapon enchant); they keep
-- that color and take the reference's rounded ring around the key. Done once:
-- Blizzard only recolors and shows or hides them afterwards.
local function Ring(texture, around)
	if Forbidden(texture) or not texture.SetTexture then return end
	texture:SetTexture(Kit.media..'ring-6.tga')
	texture:SetTexCoord(0, 1, 0, 1)
	if texture.SetTextureSliceMargins then
		texture:SetTextureSliceMargins(RING_SLICE, RING_SLICE, RING_SLICE, RING_SLICE)
		if STRETCHED and texture.SetTextureSliceMode then texture:SetTextureSliceMode(STRETCHED) end
	end
	if texture.SetScale then texture:SetScale(RING_SCALE) end
	local scale = texture.SetScale and RING_SCALE or 1
	texture:ClearAllPoints()
	texture:SetPoint('TOPLEFT', around, 'TOPLEFT', -1 / scale, 1 / scale)
	texture:SetPoint('BOTTOMRIGHT', around, 'BOTTOMRIGHT', 1 / scale, -1 / scale)
end

-- The time sits on the chip: our own text when the client writes it from the
-- duration object, else Blizzard's (which Blizzard recolors itself).
local function PlaceTime(look)
	local duration = look.parts.duration
	local mode = DB().time or 'chip'
	local own = look.binding ~= nil
	duration:ClearAllPoints()
	duration:SetPoint('CENTER', look.chip, 'CENTER', 0, 0)
	Kit:Tint(duration, mode == 'chip' and 'lcdInk' or 'white')
	duration:SetShadowOffset(mode == 'chip' and 0 or 1, mode == 'chip' and 0 or -1)
	duration:SetAlpha((mode == 'off' or own) and 0 or 1)
	look.time:SetShown(own and mode ~= 'off')
	Kit:Tint(look.time, mode == 'chip' and 'lcdInk' or 'white')
	look.time:SetShadowOffset(mode == 'chip' and 0 or 1, mode == 'chip' and 0 or -1)
end

-- The drain line's spot: above the key, or between the key and its chip.
local function PlaceLine(look)
	local line, db = look.line, DB()
	line:ClearAllPoints()
	if db.line == 'bottom' then
		line:SetPoint('TOPLEFT', look.key, 'BOTTOMLEFT', 2, -1)
		line:SetPoint('TOPRIGHT', look.key, 'BOTTOMRIGHT', -2, -1)
	else
		line:SetPoint('BOTTOMLEFT', look.key, 'TOPLEFT', 2, 2)
		line:SetPoint('BOTTOMRIGHT', look.key, 'TOPRIGHT', -2, 2)
	end
	line:SetHeight(2)
	if look.chip then
		look.chip:ClearAllPoints()
		local below = db.line == 'bottom' and line or look.key
		look.chip:SetPoint('TOPLEFT', below, 'BOTTOMLEFT', db.line == 'bottom' and -2 or 0, -1)
		look.chip:SetPoint('TOPRIGHT', below, 'BOTTOMRIGHT', db.line == 'bottom' and 2 or 0, -1)
	end
end

-- What follows the settings: the key's margin, the chips, sizes and rings.
local function Look(look)
	local db, parts = DB(), look.parts
	local pad = Kit:Clamp(floor(tonumber(db.keyPad) or 2), 0, 8)
	look.key:ClearAllPoints()
	look.key:SetPoint('TOPLEFT', parts.icon, 'TOPLEFT', -pad, pad)
	look.key:SetPoint('BOTTOMRIGHT', parts.icon, 'BOTTOMRIGHT', pad, -pad - 1)
	if look.chip then
		-- The chip's housing shows only in 'chip' mode.
		look.chip.shell:SetAlpha(db.time == 'chip' and 1 or 0)
		if look.chip.inner then look.chip.inner:SetAlpha(db.time == 'chip' and 1 or 0) end
		local size = Sized(db.timeSize, 8)
		Kit:Font(parts.duration, size, db.time == 'chip' and '' or 'OUTLINE', true)
		Kit:Font(look.time, size, db.time == 'chip' and '' or 'OUTLINE', true)
		PlaceTime(look)
	end
	PlaceLine(look)
	if parts.count then
		Kit:Font(parts.count, Sized(db.countSize, 9), db.countChip ~= false and '' or 'OUTLINE', true)
		Kit:Tint(parts.count, db.countChip ~= false and 'darkInk' or 'white')
		parts.count:SetShadowOffset(0, 0)
	end
	local ring = db.ring ~= false and 1 or 0
	for _, texture in ipairs({parts.border, parts.enchant}) do
		if not Forbidden(texture) and texture.SetAlpha then texture:SetAlpha(ring) end
	end
end

local function Build(button, parts)
	local icon = parts.icon
	local look = {parts = parts, button = button}
	-- The key sits behind the icon, a little larger so its face and lip show.
	local key = CreateFrame('Frame', nil, button)
	key:SetFrameLevel(max(button:GetFrameLevel() - 1, 0))
	key:EnableMouse(false)
	key.skin = Kit:Skin(key, 'key', 'BACKGROUND', 0)
	key.skin.kitMaxCorner = 6
	look.key = key
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	if icon.AddMaskTexture and button.CreateMaskTexture then
		local mask = button:CreateMaskTexture()
		mask:SetTexture(Kit.media..'mask-icon.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
		mask:SetAllPoints(icon)
		icon:AddMaskTexture(mask)
	end
	-- Above the icon, on a frame of our own: the window's inner shadow, the
	-- count chip and the lamp.
	local lid = CreateFrame('Frame', nil, button)
	lid:SetAllPoints(key)
	lid:SetFrameLevel(button:GetFrameLevel() + 2)
	lid:EnableMouse(false)
	look.lid = lid
	look.window = Kit:Texture(lid, 'inset-6', 'ARTWORK', 0)
	Kit:Place(look.window, icon, 0, 0, 0, 0)
	look.window:SetVertexColor(0, 0, 0, 0.6)
	look.led = Kit:Led(lid, 4, false)
	look.led:SetPoint('TOPRIGHT', key, 'TOPRIGHT', -2, -2)
	Kit:ShowLed(look.led, false)
	-- The drain line: a track and the client-timed fill.
	local line = CreateFrame('StatusBar', nil, button)
	line:SetFrameLevel(button:GetFrameLevel() + 1)
	line:SetStatusBarTexture(Kit.media..'bar-flat.tga')
	line:SetMinMaxValues(0, 1)
	line:SetValue(1)
	line.track = line:CreateTexture(nil, 'BACKGROUND')
	line.track:SetAllPoints()
	line.track:SetColorTexture(0, 0, 0, 0.35)
	line:Hide()
	look.line = line
	-- The time left on a gray LCD chip flush under the key.
	if parts.duration then
		local chip = Kit:LCDPanel(button, {radius = 3})
		chip:SetFrameLevel(max(button:GetFrameLevel() - 1, 0))
		Kit:Relevel(chip)
		chip:EnableMouse(false)
		chip:SetHeight(10)
		look.chip = chip
		look.time = Kit:Text(chip, '', 8, 'lcdInk', true, false)
		look.time:SetPoint('CENTER', 0, 0)
		look.time:Hide()
		local format = Formatter()
		if format and C_DurationUtil and C_DurationUtil.CreateDurationTextBinding then
			local ok, binding = pcall(C_DurationUtil.CreateDurationTextBinding)
			if ok and binding then
				binding:SetFontString(look.time)
				binding:SetFormatter(format)
				if binding.SetUpdateInterval then binding:SetUpdateInterval(0.25) end
				if binding.SetExpiredText then binding:SetExpiredText('') end
				if binding.SetZeroDurationText then binding:SetZeroDurationText('') end
				binding:SetEnabled(false)
				look.binding = binding
			end
		end
	end
	-- The stack count on a small charcoal chip at the icon's corner.
	if parts.count then
		parts.count:ClearAllPoints()
		parts.count:SetPoint('BOTTOMRIGHT', icon, 'BOTTOMRIGHT', -1, 1)
		look.countChip = Kit:Texture(lid, 'round-3', 'BACKGROUND', 0)
		Kit:Place(look.countChip, parts.count, 2, 1, 2, 1)
		Kit:Tint(look.countChip, 'dark', 0.9)
		look.countChip:Hide()
	end
	local highlight = button.GetHighlightTexture and button:GetHighlightTexture()
	if highlight then
		highlight:ClearAllPoints()
		highlight:SetAllPoints(icon)
		highlight:SetAlpha(0.2)
	end
	Ring(parts.border, key)
	Ring(parts.enchant, key)
	Look(look)
	Kit:Animate(key, Kit:Speed('FAST'), 0, 1, function(alpha) key:SetAlpha(alpha) end, nil, 'sine')
	return look
end

-- An aura about to run out blinks its lamp amber. Only from a plain time left;
-- a new aura on the button (or none) puts the lamp out first.
local function WatchExpiry(look, duration, id)
	if look.expiryFor == id and id ~= nil then return end
	look.expiryFor = id
	if look.expiryTimer then look.expiryTimer:Cancel(); look.expiryTimer = nil end
	if Kit.Blink then Kit:Blink(look.led, nil, false) end
	Kit:ShowLed(look.led, false)
	if not (id and duration and duration.GetRemainingDuration and Kit.Blink) then return end
	local ok, left = pcall(duration.GetRemainingDuration, duration)
	if not ok or IsSecret(left) or type(left) ~= 'number' or left <= 0 then return end
	local function Start()
		look.expiryTimer = nil
		if look.expiryFor ~= id or not look.button:IsVisible() then return end
		Kit:SetLed(look.led, true, 'amber')
		Kit:ShowLed(look.led, true)
		Kit:Blink(look.led, 0.6, true)
	end
	if left <= 10 then Start() else look.expiryTimer = C_Timer.NewTimer(left - 10, Start) end
end

-- Each pass: the time line and text from the aura's duration object, the
-- lamp in the debuff type's color, and the chips' visibility.
local function Refill(look)
	local db, parts = DB(), look.parts
	local timed = parts.duration and parts.duration:IsShown() and true or false
	local duration, id
	if timed then duration, id = AuraDuration(look.button) end
	-- The line drains on the client's own timer.
	local showLine = db.line ~= 'off' and duration ~= nil and REMAINING ~= nil
	if showLine then
		look.line:SetTimerDuration(duration, IMMEDIATE, REMAINING)
	end
	look.line:SetShown(showLine and true or false)
	-- The time text, written by the client from the same object.
	-- Without a duration object (weapon enchants), Blizzard's own text shows.
	if look.binding then
		local mode = db.time or 'chip'
		if duration then
			look.binding:SetDuration(duration)
			look.binding:SetEnabled(true)
		else
			look.binding:SetEnabled(false)
			look.time:SetText('')
		end
		look.time:SetShown(duration ~= nil and mode ~= 'off')
		parts.duration:SetAlpha((duration == nil and mode ~= 'off') and 1 or 0)
	end
	-- Debuffs: the lamp and the line take the type's color from Blizzard's own
	-- ring (possibly secret, so only ever handed on). Buffs: the lamp only
	-- lights, blinking, when one is about to run out.
	local border = parts.border
	local debuff = not Forbidden(border) and border:IsShown() and true or false
	if debuff then
		WatchExpiry(look, nil, nil)
		local r, g, b = border:GetVertexColor()
		look.led:SetVertexColor(r, g, b)
		look.line:SetStatusBarColor(r, g, b)
		Kit:ShowLed(look.led, db.led ~= false)
	else
		look.line:SetStatusBarColor(Kit:RGB('lamp'))
		WatchExpiry(look, db.led ~= false and duration or nil, db.led ~= false and id or nil)
	end
	if look.countChip then
		look.countChip:SetShown(db.countChip ~= false and parts.count:IsShown() and true or false)
	end
end

local function Dress(button)
	if Forbidden(button) or notAura[button] then return end
	local look = dressed[button]
	if not look then
		if not button.GetFrameLevel then notAura[button] = true return end
		local parts = Parts(button)
		if not parts.icon or not parts.icon.SetTexCoord then notAura[button] = true return end
		look = Build(button, parts)
		dressed[button] = look
	elseif relayout and look.chip then
		PlaceTime(look)
	end
	-- What changes from aura to aura: whether it has a time, and the time itself.
	if look.chip then
		local shown = look.parts.duration:IsShown() and true or false
		if shown ~= look.shown then
			look.shown = shown
			look.chip:SetShown(shown and DB().time ~= 'off')
		end
	end
	UI:Safe(Refill, look)
end

local function Collapse(button)
	if Forbidden(button) then return end
	if not collapse then
		for _, getter in ipairs({'GetNormalTexture', 'GetPushedTexture', 'GetHighlightTexture', 'GetCheckedTexture', 'GetDisabledTexture'}) do
			local texture = button[getter] and button[getter](button)
			if texture then texture:SetAlpha(0) end
		end
		for _, region in ipairs({button:GetRegions()}) do
			if region.IsObjectType and region:IsObjectType('Texture') then region:SetAlpha(0) end
		end
		collapse = CreateFrame('Frame', nil, button)
		collapse:SetSize(16, 16)
		collapse:SetPoint('CENTER')
		collapse:EnableMouse(false)
		collapse.skin = Kit:Skin(collapse, 'key-round', 'ARTWORK', 0)
		collapse.icon = Kit:Icon(collapse, 'chevron-right', 8, 'ink')
		collapse.icon:SetPoint('CENTER')
		button:HookScript('OnMouseDown', function() Kit:SetSprite(collapse.skin, 'key-round-down') end)
		button:HookScript('OnMouseUp', function() Kit:SetSprite(collapse.skin, 'key-round') end)
		button:HookScript('OnClick', function()
			if UI.db.sound.interface then Kit:Play('latch-down', true) end
			C_Timer.After(0, function() UI:Safe(Collapse, button) end)
		end)
	end
	-- Checked: the buffs are folded away; the chevron points the way they open.
	local folded = button.GetChecked and button:GetChecked() and true or false
	if folded ~= collapse.folded then
		collapse.folded = folded
		Kit:SetIcon(collapse.icon, folded and 'chevron-left' or 'chevron-right')
	end
end

-- An optional BF-1 housing behind the buffs and debuffs, following Edit Mode.
local housing
local function LayoutHousing()
	local buffs, debuffs = _G.BuffFrame, _G.DebuffFrame
	if not DB().housing or Forbidden(buffs) then
		if housing then housing:Hide() end
		return
	end
	if not housing then
		housing = Kit:Device(UIParent, {model = 'BF-1', title = 'Auras', radius = 12})
		housing:SetFrameStrata(buffs:GetFrameStrata() or 'LOW')
		housing:SetFrameLevel(max(buffs:GetFrameLevel() - 2, 1))
		Kit:Relevel(housing)
		housing:EnableMouse(false)
	end
	local lower = (not Forbidden(debuffs) and debuffs:IsShown()) and debuffs or buffs
	housing:ClearAllPoints()
	housing:SetPoint('TOPLEFT', buffs, 'TOPLEFT', -10, 26)
	housing:SetPoint('TOPRIGHT', buffs, 'TOPRIGHT', 10, 26)
	housing:SetPoint('BOTTOM', lower, 'BOTTOM', 0, -18)
	housing:SetShown(buffs:IsShown())
end

-- Each button once per pass: it can be both in auraFrames and a container child.
local visited = {}
local function Visit(button)
	if type(button) ~= 'table' or visited[button] then return end
	visited[button] = true
	UI:Safe(Dress, button)
end

local function Each(frame)
	if Forbidden(frame) then return end
	local list = frame.auraFrames
	if type(list) == 'table' then
		for _, button in pairs(list) do Visit(button) end
	end
	local container = frame.AuraContainer or frame
	if not Forbidden(container) then
		for _, child in ipairs({container:GetChildren()}) do
			if child ~= frame.CollapseAndExpandButton then Visit(child) end
		end
	end
end

local function Pass()
	wipe(visited)
	for _, name in ipairs({'BuffFrame', 'DebuffFrame'}) do
		local frame = _G[name]
		Each(frame)
		if frame and frame.CollapseAndExpandButton then UI:Safe(Collapse, frame.CollapseAndExpandButton) end
	end
	-- Older layouts keep weapon enchants on their own named buttons.
	for index = 1, 3 do Visit(_G['TempEnchant'..index]) end
	wipe(visited)
	if relayout then UI:Safe(LayoutHousing) end
	relayout = false
end

-- However many updates land in a frame, one pass runs, the frame after.
local pending
local function Queue()
	if pending then return end
	pending = true
	C_Timer.After(0, function()
		pending = nil
		UI:Safe(Pass)
	end)
end

local function Relayout()
	relayout = true
	Queue()
end

function module:Enable()
	local hooked = false
	for _, name in ipairs({'BuffFrame', 'DebuffFrame'}) do
		local frame = _G[name]
		if not Forbidden(frame) then
			for _, method in ipairs({'UpdateAuraButtons', 'Update'}) do
				if type(frame[method]) == 'function' then
					hooksecurefunc(frame, method, Queue)
					hooked = true
				end
			end
			if type(frame.UpdateGridLayout) == 'function' then hooksecurefunc(frame, 'UpdateGridLayout', Relayout) end
		end
	end
	local driver = CreateFrame('Frame')
	-- Blizzard's own aura updates are hooked above; the aura event is only a
	-- fallback for a client whose aura frames have neither method.
	if not hooked then driver:RegisterUnitEvent('UNIT_AURA', 'player', 'vehicle') end
	driver:RegisterEvent('PLAYER_ENTERING_WORLD')
	pcall(driver.RegisterEvent, driver, 'WEAPON_ENCHANT_CHANGED')
	pcall(driver.RegisterEvent, driver, 'EDIT_MODE_LAYOUTS_UPDATED')
	driver:SetScript('OnEvent', function(_, event)
		if event == 'EDIT_MODE_LAYOUTS_UPDATED' or event == 'PLAYER_ENTERING_WORLD' then Relayout() else Queue() end
	end)
	Pass()
end

function module:Refresh()
	for _, look in pairs(dressed) do UI:Safe(Look, look); look.shown = nil end
	UI:Safe(LayoutHousing)
	Relayout()
end

UI:RegisterPage('buffs', {title = 'Buffs', order = 12, cards = {
	{title = 'Style', rows = {
		{'segmented', 'Style', 'style.buffs', items = {{'keys', 'Keys'}, {'blizzard', 'Blizzard'}}, reload = true,
			note = 'Each aura on a light key with its icon in a window, time left on a gray LCD chip, a draining time line, debuff type as a colored ring and lamp.'},
		{'switch', 'Housing', 'buffs.housing', 'A BF-1 device behind your buffs and debuffs.'},
		{'note', 'Icon size, rows, spacing and direction are Edit Mode settings for the Buff and Debuff frames; the keys follow them.'},
	}},
	{title = 'Keys', rows = {
		{'slider', 'Key margin', 'buffs.keyPad', 0, 8, 1, 'How much of the key shows around each icon.'},
		{'segmented', 'Time line', 'buffs.line', items = {{'top', 'Above'}, {'bottom', 'Below'}, {'off', 'Off'}}, since = '0.5.0',
			note = 'A thin line that drains with the time left, in the lamp color (a debuff\'s in its type\'s color).'},
		{'switch', 'Lamp', 'buffs.led', 'A lamp on the key: a debuff\'s type, or amber blinking when an aura has under 10 seconds left.', since = '0.5.0'},
		{'switch', 'Count chip', 'buffs.countChip', 'Stacks on a small charcoal chip at the icon\'s corner.', since = '0.5.0'},
		{'switch', 'Debuff type ring', 'buffs.ring', 'A ring in the debuff type\'s color (magic, poison...) and around weapon enchants.'},
		{'slider', 'Stack count size', 'buffs.countSize', 0, 16, 1, nil, format = function(v) return v == 0 and 'Auto' or tostring(v) end},
	}},
	{title = 'Time left', rows = {
		{'segmented', 'Time', 'buffs.time', items = {{'chip', 'LCD chip'}, {'text', 'Text'}, {'off', 'Off'}},
			note = 'On a gray LCD chip under the key, as plain text, or hidden.'},
		{'slider', 'Time size', 'buffs.timeSize', 0, 14, 1, nil, format = function(v) return v == 0 and 'Auto' or tostring(v) end},
	}},
}})
