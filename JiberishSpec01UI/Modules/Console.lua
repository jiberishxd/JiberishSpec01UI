-- Fading, the devices the bars sit in, and the CX-1 console: its layout as
-- blocks (banks, docked frames in their bays, cast bars, function keys, meters,
-- menu strip), docking, the free and side bars, and the pet and stance keys.
-- Part of the action bars (ActionBars.lua).
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown, GetTime = CreateFrame, UIParent, InCombatLockdown, GetTime
local floor, max, min = math.floor, math.max, math.min
local format, ipairs, pairs, pcall, tonumber = format, ipairs, pairs, pcall, tonumber
local P = UI.ActionBarParts
local Forbidden, IsSecret = UI.Util.Forbidden, UI.Util.IsSecret
local AUX, BarDB, BarEnabled, BARS, BarSize, COL_GAP = P.AUX, P.BarDB, P.BarEnabled, P.BARS, P.BarSize, P.COL_GAP
local CreateKey, DB, Deck, Docking, Dress, extraKeys = P.CreateKey, P.DB, P.Deck, P.Docking, P.Dress, P.extraKeys
local Flag, GAP, HEAD, HPad, HW, keyOf = P.Flag, P.GAP, P.HEAD, P.HPad, P.HW, P.keyOf
local KeySize, PAD, PageConditions, PerRow, petKeys, ROW_GAP = P.KeySize, P.PAD, P.PageConditions, P.PerRow, P.petKeys, P.ROW_GAP
local Rows, Shown, SizeKey, Spacing, stanceKeys, Surface = P.Rows, P.Shown, P.SizeKey, P.Spacing, P.stanceKeys, P.Surface
local UpdateStance, XPHeight = P.UpdateStance, P.XPHeight

-- Fading -------------------------------------------------------------------------------
-- A bar may fade out of combat, show only under the mouse, or both (then it
-- shows in a fight or under the mouse). Alpha only, so it works in combat.
P.inCombat = false
local UpdateFades, WatchFade
do
local faders = {} -- frame -> {id, hovered, alpha}

local function FadeTarget(id, hovered)
	local db = BarDB(id)
	if not (db.fade or db.mouseover) then return 1 end
	if db.fade and P.inCombat then return 1 end
	if db.mouseover and hovered then return 1 end
	return Kit:Clamp(tonumber(db.fadeAlpha) or 0.25, 0, 1)
end

local function UpdateFade(frame)
	local fader = faders[frame]
	if not fader then return end
	local alpha = FadeTarget(fader.id, fader.hovered)
	if fader.alpha == alpha then return end
	fader.alpha = alpha
	Kit:FadeTo(frame, alpha, 'FAST')
end

-- reset: forget the alphas set, so every frame is faded again (after a settings change).
function UpdateFades(reset)
	for frame, fader in pairs(faders) do
		if reset then fader.alpha = nil end
		UpdateFade(frame)
	end
end

local function Hover(frame, on)
	local fader = faders[frame]
	if not fader then return end
	if on then
		fader.hovered = true
		return UpdateFade(frame)
	end
	-- Moving from key to key leaves one before entering the next.
	C_Timer.After(0.15, function()
		fader.hovered = frame:IsMouseOver() and true or false
		UpdateFade(frame)
	end)
end

function WatchFade(frame, id, buttons)
	faders[frame] = faders[frame] or {id = id}
	for _, button in ipairs(buttons) do
		button:HookScript('OnEnter', function() Hover(frame, true) end)
		button:HookScript('OnLeave', function() Hover(frame, false) end)
	end
	UpdateFade(frame)
end
end

-- Devices --------------------------------------------------------------------------------
-- The devices (console, side, menu, petModule, stanceModule, xp) are shared: P.console and so on.
local leave
local bars = {} -- id -> {header, buttons, device}

local function Device(name, model, title, opts)
	opts = opts or {}
	-- group: the Housing page's Console look (color and material) for every action bar device.
	local device = Kit:Device(UIParent, {name = name, model = model, title = title, surface = Surface(), radius = opts.radius or 12,
		header = opts.header, template = opts.template, ['group'] = 'console'})
	device:SetFrameStrata('LOW')
	device:SetFrameLevel(opts.level or 10)
	Kit:Relevel(device)
	device:SetScale(DB().scale or 1)
	if device.shell then device.shell:SetShown(DB().housing ~= false) end
	return device
end

-- One bar's keys: the first `shown` of them, in lines of `perRow`; vertical
-- lines run top to bottom. Out of combat only (they are secure buttons).
local function LayoutBar(bar, size, spacing, shown, perRow, vertical)
	shown = Kit:Clamp(floor(shown or 12), 1, 12)
	local across = min(Kit:Clamp(floor(perRow or 12), 1, 12), shown)
	local lines = math.ceil(shown / across)
	for index, button in ipairs(bar.buttons) do
		local key = keyOf[button]
		if key.size ~= size then SizeKey(key, size) end
		button:ClearAllPoints()
		if index <= shown then
			local line, place = floor((index - 1) / across), (index - 1) % across
			if vertical then button:SetPoint('TOPLEFT', line * (size + spacing), -place * (size + spacing))
			else button:SetPoint('TOPLEFT', place * (size + spacing), -line * (size + spacing)) end
			button:Show()
		else
			button:Hide()
		end
	end
	local long, short = across * size + (across - 1) * spacing, lines * size + (lines - 1) * spacing
	bar.width, bar.height = vertical and short or long, vertical and long or short
	bar.header:SetSize(bar.width, bar.height)
	return bar.width, bar.height
end

local function BuildBar(bar, parent, size, vertical)
	local header = CreateFrame('Frame', format('JiberishSpec01Bar%d', bar.id), parent, 'SecureHandlerStateTemplate')
	bar.header, bar.buttons, bar.vertical = header, {}, vertical
	for index = 1, 12 do
		bar.buttons[index] = CreateKey(bar, index, header, size)
	end
	LayoutBar(bar, size, Spacing(bar.id), Shown(bar.id), vertical and PerRow(bar.id) or 12, vertical)
	if bar.paging then
		header:SetAttribute('_onstate-page', [[
			if strsub(newstate, 1, 5) == 'bonus' then newstate = HasBonusActionBar() and GetBonusBarIndex() or 1 end
			newstate = tonumber(newstate) or 1
			self:SetAttribute('actionpage', newstate)
			control:ChildUpdate('page', newstate)
		]])
		RegisterStateDriver(header, 'page', PageConditions())
		-- The console's page LCD and lamps follow the page the secure snippet picked.
		header:HookScript('OnAttributeChanged', function(_, name, value)
			if name == 'actionpage' and P.console and P.console.pager then UI:Safe(HW.ShowPage, P.console.pager, value) end
		end)
	end
	bars[bar.id] = bar
	return header
end

-- The experience meter: LED dots in a track along the console's base. At the
-- level cap it shows the watched reputation instead.
local function BuildXP(parent)
	local onDark = Surface() == 'dark'
	local track = CreateFrame('Frame', nil, parent)
	track:SetHeight(XPHeight())
	track.shell = Kit:Shell(track, {surface = onDark and 'glass' or 'lcd', radius = 99, shadow = false, fill = not onDark and 'track' or nil})
	local bar = CreateFrame('StatusBar', nil, track)
	bar:SetPoint('TOPLEFT', 3, -2)
	bar:SetPoint('BOTTOMRIGHT', -3, 2)
	bar:SetStatusBarTexture([[Interface\Buttons\WHITE8X8]])
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)
	Kit:Perforate(bar, onDark and 'glass' or 'track', onDark and 'darkEdge' or nil)
	if Kit.MarkBar then Kit:MarkBar(bar) end
	track.bar = bar
	if HW.On() then HW.MeterParts(parent, track) end
	track:EnableMouse(true)
	track:SetScript('OnEnter', function(self)
		GameTooltip:SetOwner(self, 'ANCHOR_TOP')
		if self.tip then for _, line in ipairs(self.tip) do GameTooltip:AddLine(line, 1, 1, 1) end end
		GameTooltip:Show()
	end)
	track:SetScript('OnLeave', function() GameTooltip:Hide() end)
	return track
end

-- The console's LCD: level and progress, the time, or nothing.
local function Readout(text)
	local mode = DB().readout or 'level'
	if mode == 'off' then return '' end
	if mode == 'clock' then return date('%H:%M') end
	return text
end

-- Experience, reputation or honor along the base, and the console's LCD: the deck does it.
local function UpdateXP() Deck.UpdateMeters() end

-- The leave key: vehicles and flight paths.
local function UpdateLeave()
	if not leave then return end
	local can = (CanExitVehicle and CanExitVehicle()) or (UnitOnTaxi and UnitOnTaxi('player'))
	leave:SetShown(Flag(can) or false)
end

local function BuildLeave(parent)
	leave = Kit:Key(parent, {width = 50, height = 14, text = 'Leave', tone = 'primary', textSize = 7})
	leave.onClick = function()
		if UnitOnTaxi and UnitOnTaxi('player') then TaxiRequestEarlyLanding()
		elseif VehicleExit then VehicleExit() end
	end
	leave:Hide()
	return leave
end

-- Empty slots in the console: an unlit panel where a docked frame shows up.
local function Slot(parent, text)
	local slot = CreateFrame('Frame', nil, parent)
	slot:EnableMouse(false)
	slot.shell = Kit:Shell(slot, {surface = Surface() == 'dark' and 'glass' or 'lcd', radius = 6, shadow = false, alpha = 0.55})
	slot.text = Kit:Label(slot, text, Surface() == 'dark' and 'darkDim' or 'lcdDim', 8)
	slot.text:SetPoint('CENTER')
	return slot
end

local function Follow(slot, frame)
	if not frame then return end
	slot:SetShown(not frame:IsShown())
	frame:HookScript('OnShow', function() slot:Hide() end)
	frame:HookScript('OnHide', function() if frame.docked and slot.enabled ~= false then slot:Show() end end)
end

-- The console ----------------------------------------------------------------------------
local function UnitParts()
	local unitframes = UI.modules.unitframes
	if not (Docking() and DB().dock and unitframes and unitframes.enabled and unitframes.frames) then return {} end
	local frames, db = unitframes.frames, DB()
	-- A frame the console editor took out stays out.
	local custom = Deck.CustomLayout()
	local function In(key, frame)
		local spot = custom and custom[key]
		if type(spot) == 'table' and spot.off then return nil end
		return frame
	end
	return {player = In('uf.player', frames.player), target = In('uf.target', frames.target),
		playerCast = In('cb.player', unitframes.playerCast), targetCast = In('cb.target', unitframes.targetCast), module = unitframes,
		-- The small frames dock only when asked (each frame may not exist on every client).
		focus = db.dockFocus and frames.focus or nil, tot = db.dockToT and frames.targettarget or nil,
		pet = db.dockPet and frames.pet or nil}
end

-- Bays: where an embedded docked frame sits, cut into the console's housing.
-- A recess like the key slots' (the slot color, a lit line under it on a light
-- housing, a shade under its top edge); a legend printed over it in the banks'
-- style, with a lamp lit while its unit is there, the unit's name and level;
-- and a screen that shows, unlit, while there is no unit.
Deck.BAY_TITLES = {['uf.player'] = 'Unit A', ['uf.target'] = 'Unit B', ['uf.focus'] = 'Focus', ['uf.targettarget'] = 'ToT',
	['uf.pet'] = 'Pet', ['cb.player'] = 'Cast A', ['cb.target'] = 'Cast B'}
Deck.BAY_EMPTY = {['uf.target'] = 'No target', ['uf.focus'] = 'No focus', ['uf.targettarget'] = 'No target of target', ['uf.pet'] = 'No pet'}

function Deck.Bay(parent, key)
	parent.bays = parent.bays or {}
	local bay = parent.bays[key]
	if bay then return bay end
	local dark = Surface() == 'dark'
	bay = CreateFrame('Frame', nil, parent)
	bay:SetFrameLevel(parent:GetFrameLevel() + 1)
	bay:EnableMouse(false)
	bay.key = key
	bay.well = Kit:Texture(bay, 'round-6', 'BACKGROUND', 1)
	bay.well:SetVertexColor(HW.SLOT[1], HW.SLOT[2], HW.SLOT[3], 1)
	bay.well:SetAllPoints()
	bay.shine = Kit:Texture(bay, 'round-6', 'BACKGROUND', 0)
	bay.shine:SetVertexColor(1, 1, 1, dark and 0 or 0.7)
	bay.shine:SetPoint('TOPLEFT', 0, 0)
	bay.shine:SetPoint('BOTTOMRIGHT', 0, -UI.Pixel.Px(parent, 1))
	bay.shade = bay:CreateTexture(nil, 'BORDER')
	bay.shade:SetColorTexture(1, 1, 1, 1)
	bay.shade:SetGradient('VERTICAL', CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0.35))
	bay.shade:SetPoint('TOPLEFT', 2, -1)
	bay.shade:SetPoint('TOPRIGHT', -2, -1)
	bay.shade:SetHeight(4)
	-- The unlit screen of an empty bay.
	bay.screen = Kit:LCDPanel(bay, {radius = 4})
	bay.screen:SetFrameLevel(bay:GetFrameLevel() + 1)
	bay.ghost = Kit:Text(bay.screen, strupper(Deck.BAY_EMPTY[key] or ''), 8, 'lcdDim', true)
	bay.ghost:SetPoint('CENTER')
	-- The legend over it.
	bay.legend = CreateFrame('Frame', nil, parent)
	bay.legend:SetFrameLevel(parent:GetFrameLevel() + 2)
	bay.lamp = Kit:Led(bay.legend, 4, false)
	bay.label = Kit:Label(bay.legend, strupper(Deck.BAY_TITLES[key] or ''), dark and 'darkDim' or 'dim', 7, true)
	bay.name = Kit:Label(bay.legend, '', dark and 'darkInk' or 'ink', 7, true)
	bay.name:SetWordWrap(false)
	bay.level = Kit:Label(bay.legend, '', dark and 'darkDim' or 'dim', 7, true)
	bay.rule = bay.legend:CreateTexture(nil, 'ARTWORK')
	bay.rule:SetColorTexture(dark and 1 or 0, dark and 1 or 0, dark and 1 or 0, dark and 0.08 or 0.09)
	parent.bays[key] = bay
	return bay
end

-- The legend's parts in a row: lamp, title, the unit's name; its level at the
-- far end; the rule between them. Text widths that can't be read (a secret
-- name) leave the rule out rather than guess.
function Deck.PlaceBayLegend(bay)
	local legend = bay.legend
	local width = legend:GetWidth()
	local px = UI.Pixel.Px(legend, 1)
	bay.lamp:ClearAllPoints()
	bay.lamp:SetPoint('LEFT', legend, 'LEFT', 0, 0)
	bay.label:ClearAllPoints()
	bay.label:SetPoint('LEFT', bay.lamp, 'RIGHT', 4, 0)
	bay.level:ClearAllPoints()
	bay.level:SetPoint('RIGHT', legend, 'RIGHT', 0, 0)
	local label = bay.label:GetStringWidth() or 0
	bay.name:ClearAllPoints()
	bay.name:SetPoint('LEFT', bay.label, 'RIGHT', 5, 0)
	bay.name:SetWidth(max(width * 0.55 - label, 10))
	bay.name:SetJustifyH('LEFT')
	local name, level = bay.name:GetStringWidth(), bay.level:GetStringWidth()
	local readable = not IsSecret(name) and not IsSecret(level) and name and level
	if readable then
		name = min(name, max(width * 0.55 - label, 10))
		local from = 4 + 4 + label + (name > 0 and 5 + name or 0) + 6
		local to = width - (level > 0 and level + 6 or 0)
		bay.rule:ClearAllPoints()
		bay.rule:SetSize(max(to - from, 0), px)
		bay.rule:SetPoint('LEFT', legend, 'LEFT', from, 0)
		bay.rule:SetShown(to - from > 4)
	else
		bay.rule:Hide()
	end
end

-- Power a bay up (its unit is there) or down: the screen fades out or back
-- in with its legend printed, and the lamp follows.
function Deck.PowerBay(bay, on)
	if bay.powered == on then return end
	bay.powered = on
	Kit:SetLed(bay.lamp, on)
	-- Unlit, the screen reads as a powered-down display, a little dimmer than a lit LCD.
	Kit:FadeTo(bay.screen, on and 0 or 0.8, 'FAST')
	if not on and bay.ghost:GetText() ~= '' and Kit.Print then Kit:Print(bay.ghost) end
end

-- Put the bay under its block (the legend row, then the recess), follow its frame.
function Deck.PlaceBay(parent, block, frame, legendHeight)
	local bay = Deck.Bay(parent, block.key)
	bay:ClearAllPoints()
	bay:SetPoint('TOPLEFT', parent, 'TOPLEFT', block.x, -(block.y + legendHeight))
	bay:SetSize(block.w, max(block.h - legendHeight, 1))
	bay.screen:ClearAllPoints()
	bay.screen:SetPoint('TOPLEFT', 2, -2)
	bay.screen:SetPoint('BOTTOMRIGHT', -2, 2)
	bay.ghost:SetShown(DB().targetPlate ~= 'collapse')
	bay.legend:ClearAllPoints()
	bay.legend:SetPoint('TOPLEFT', parent, 'TOPLEFT', block.x, -block.y)
	bay.legend:SetSize(block.w, max(legendHeight - 2, 6))
	bay:Show()
	bay.legend:Show()
	if bay.frame ~= frame then
		bay.frame = frame
		-- The unit's name and level, printed on the legend as the frame shows them.
		local function Copy(target, source)
			if not source then return end
			target:SetText(source:GetText())
			hooksecurefunc(source, 'SetText', function(_, text) target:SetText(text); Deck.PlaceBayLegend(bay) end)
			hooksecurefunc(source, 'SetFormattedText', function(_, ...) target:SetFormattedText(...); Deck.PlaceBayLegend(bay) end)
		end
		if frame.layout then
			Copy(bay.name, frame.nameText)
			Copy(bay.level, frame.levelText)
		end
		frame:HookScript('OnShow', function() if bay.frame == frame then Deck.PowerBay(bay, true) end end)
		frame:HookScript('OnHide', function() if bay.frame == frame then Deck.PowerBay(bay, false) end end)
	end
	bay.powered = nil
	Deck.PowerBay(bay, frame:IsShown() and true or false)
	Deck.PlaceBayLegend(bay)
end

-- Bays no longer in use (a frame taken out, the floating look) are put away.
function Deck.HideBays(parent, used)
	for key, bay in pairs(parent.bays or {}) do
		local block = used[key]
		if not (block and block.bay) then
			bay:Hide()
			bay.legend:Hide()
		end
	end
end

-- The console editor's arrangement, or nil while the console arranges itself.
function Deck.CustomLayout()
	local layout = DB().consoleLayout
	if type(layout) == 'table' and next(layout) ~= nil then return layout end
end

-- The dim plates where docked frames show up (made when a frame first docks).
function Deck.Plates(parent, parts)
	for _, spec in ipairs({{'targetSlot', parts.target, 'No target'}, {'focusSlot', parts.focus, 'No focus'},
		{'totSlot', parts.tot, 'No ToT'}}) do
		if spec[2] and not parent[spec[1]] then
			local plate = Slot(parent, spec[3])
			-- A dim plate, not a box: it only marks where the frame appears.
			plate:SetAlpha(0.5)
			Kit:Font(plate.text, 7, nil, true)
			Follow(plate, spec[2])
			parent[spec[1]] = plate
		end
	end
end

-- Docked unit frames hide with the console in pet battles. Alpha only: they are
-- secure unit buttons, and alpha can change at any time.
local function HideDocked(hidden)
	for key, part in pairs(UnitParts()) do
		if key ~= 'module' and part and part.SetAlpha then part:SetAlpha(hidden and 0 or 1) end
	end
end

-- The console's own size: 0 is Auto (sized to what it holds); a fixed size is
-- kept, and the keys are fitted inside it.
local function FixedSize(value, least)
	value = tonumber(value)
	if not value or value <= 0 then return nil end
	return max(floor(value), least)
end

-- Docked frames: the console scales them down a little (to 0.8) only when a
-- fixed width is too narrow for them. Their own scale is kept as the base; a
-- change the unit frame module makes is taken as the new base.
local dockScaled = setmetatable({}, {__mode = 'k'})
local function DockScale(frame, factor)
	if not frame then return end
	local entry, current = dockScaled[frame], frame:GetScale()
	if not entry or math.abs(current - entry.set) > 0.001 then entry = {base = current}; dockScaled[frame] = entry end
	entry.set = entry.base * factor
	if math.abs(current - entry.set) > 0.001 then frame:SetScale(entry.set) end
end

-- A docked frame that changes size or scale later (another layout, a preset)
-- lays the console out again, so nothing ever overlaps.
local dockWatched = setmetatable({}, {__mode = 'k'})
local queuedLayout = false
local function WatchDocked(frame, relayout)
	if not frame or dockWatched[frame] then return end
	dockWatched[frame] = true
	local function Again()
		if (P.console and P.console.laying) or queuedLayout then return end
		queuedLayout = true
		C_Timer.After(0, function() queuedLayout = false; UI:Safe(relayout) end)
	end
	frame:HookScript('OnSizeChanged', Again)
	frame:HookScript('OnShow', Again)
	hooksecurefunc(frame, 'SetScale', Again)
end

local LayoutConsole
-- The stance latch and its placement (set with the stance keys, below).
local latch, PlaceLatch

local function LayoutConsoleNow()
	local db = DB()
	local PAD = HPad()
	local parts = UnitParts()
	local scale = P.console:GetEffectiveScale()
	local function Measure(frame)
		if not frame then return 0, 0, 1 end
		local ratio = frame:GetEffectiveScale() / scale
		return frame:GetWidth() * ratio, frame:GetHeight() * ratio, ratio
	end
	local function Gap(bar)
		local gap = tonumber(db.keyGap)
		return (gap and gap > 0) and floor(gap) or Spacing(bar.id)
	end
	-- The widest bank at a key size.
	local function Banks(keySize)
		local widest = 0
		for _, bar in ipairs(P.console.bars) do
			local count = Shown(bar.id)
			widest = max(widest, count * keySize + (count - 1) * Gap(bar))
		end
		return widest
	end
	local fixedW, fixedH = FixedSize(db.consoleWidth, 300), FixedSize(db.consoleHeight, 80)
	-- Console units snapped to whole screen pixels (or up to the next one):
	-- every docked edge lands on one.
	local function Snap(value) return UI.Pixel.Snap(P.console, value) end
	local function SnapUp(value)
		local px = UI.Pixel.Px(P.console, 1)
		return math.ceil(value / px - 0.001) * px
	end
	-- Each side, from the edge in: the function keys, the docked frames' column
	-- (the player or target, a small frame under it: the focus under the player,
	-- the target of target under the target; the pet in the cast row's left end
	-- cell), then the banks. Both columns are as wide as the widest docked frame.
	local COLUMN = {'player', 'target', 'focus', 'tot', 'pet'}
	for _, key in ipairs(COLUMN) do WatchDocked(parts[key], LayoutConsole) end
	-- Embedded (the default, Hardware look): each docked frame sits in a bay cut
	-- into the housing, on the banks' row grid, sized by its bay; its header
	-- is printed on the housing above the bay. Floating: the frames sit on the
	-- console at their own size.
	local embedded = HW.On() and db.dockLook ~= 'float' and (parts.player or parts.target) and parts.module
		and parts.module.DockBaseSize and true or false
	local function Widest()
		local widest = 0
		if embedded then
			-- The bays are as wide as the player and target frames are set to be.
			for _, key in ipairs({'player', 'target'}) do
				local frame = parts[key]
				if frame then widest = max(widest, parts.module:DockBaseSize(frame) * frame:GetEffectiveScale() / scale) end
			end
			if widest > 0 then return widest end
		end
		for _, key in ipairs(COLUMN) do widest = max(widest, (Measure(parts[key]))) end
		return widest
	end
	local fnW, fnH = Deck.FnBlock()
	local column = Widest()
	local function Side(frameWidth, stacked)
		local frame = frameWidth > 0 and frameWidth + COL_GAP or 0
		local keys = (fnW > 0 and not (stacked and frameWidth > 0)) and fnW + COL_GAP or 0
		if stacked and frameWidth > 0 then frame = max(frameWidth, fnW) + COL_GAP end
		return frame + keys
	end
	-- A fixed width too narrow even for the smallest keys: the docked frames
	-- scale down (not under 0.8), then the function keys go under them.
	local factor, stacked = 1, false
	if fixedW and column > 0 and not embedded then
		local inner = fixedW - PAD * 2
		local least = Banks(16)
		if inner - 2 * Side(column) < least then
			local keys = fnW > 0 and fnW + COL_GAP or 0
			factor = Kit:Clamp(((inner - least) / 2 - keys - COL_GAP) / column, 0.8, 1)
			if inner - 2 * Side(column * factor) < least and fnW > 0 then stacked = true end
		end
	end
	for _, key in ipairs(COLUMN) do DockScale(parts[key], factor) end
	column = Widest()
	local pw, ph = Measure(parts.player)
	local tw, th = Measure(parts.target)
	local fw, fh = Measure(parts.focus)
	local ow, oh = Measure(parts.tot)
	local qw, qh = Measure(parts.pet)
	local sideWidth = Side(column, stacked)
	local fnPart = (fnW > 0 and not (stacked and column > 0)) and fnW + COL_GAP or 0
	local _, playerCastHeight = Measure(parts.playerCast)
	local _, targetCastHeight = Measure(parts.targetCast)
	local castHeight = max(playerCastHeight, targetCastHeight)
	-- The cast row: the cast bars over the banks' width and the pet in its
	-- left end cell, centred on one line.
	local lowHeight = max(castHeight, qh)
	local castRow = lowHeight > 0 and lowHeight + ROW_GAP or 0
	local xpHeight = Deck.BottomHeight()
	local bank = HW.On() and HW.BANK_H or 0
	local rows = #P.console.bars
	-- Menu and bag keys set into the console: a strip in the header (centred
	-- between the name and the readouts, when it fits), along the bottom over
	-- the stats, or anywhere in the body (placed in the console editor, in
	-- its own columns and key size).
	local menuSpot = Deck.CustomLayout() and Deck.CustomLayout().menu
	if type(menuSpot) ~= 'table' then menuSpot = nil end
	local inBody = menuSpot and tonumber(menuSpot.x) and tonumber(menuSpot.y) and true or false
	local stripKey = max(16, floor(KeySize() * 0.6))
	local edge = inBody and 'body' or (Deck.MenuEdge and Deck.MenuEdge() or 'bottom')
	if edge ~= 'header' and menuSpot and tonumber(menuSpot.keys) then stripKey = Kit:Clamp(floor(tonumber(menuSpot.keys)), 16, 40) end
	if edge == 'header' then stripKey = min(stripKey, HEAD - 6) end
	local stripColumns = edge == 'body' and menuSpot and tonumber(menuSpot.columns) or nil
	local stripW, stripH, stripCount = 0, 0, 0
	if Deck.MenuStrip and P.console.menuStrip then stripW, stripH, stripCount = Deck.MenuStrip(stripKey, stripColumns) end
	if edge == 'header' and stripCount > 0 then
		local right = PAD + (db.readout ~= 'off' and P.console.lcd:GetWidth() or 0) + (P.console.pager and P.console.pager:GetWidth() + 10 or 0)
		for _, panel in ipairs(P.console.panels or {}) do
			if db[panel.def.field] ~= false then right = right + panel:GetWidth() + 6 end
		end
		local estimate = fixedW or (PAD * 2 + Banks(KeySize()) + sideWidth * 2)
		if estimate - right - PAD - 160 < stripW + 12 then
			-- No room in the header: the strip goes to the bottom, at the bottom's size.
			edge = 'bottom'
			stripKey = max(16, floor(KeySize() * 0.6))
			stripW, stripH, stripCount = Deck.MenuStrip(stripKey)
		end
	end
	P.console.menuStripKey, P.console.menuStripCount, P.console.menuStripEdge, P.console.menuStripColumns = stripKey, stripCount, edge, stripColumns
	if edge == 'bottom' and stripCount > 0 then xpHeight = xpHeight + stripH + ROW_GAP end

	-- The key size: the one asked for, made just small enough to fit a fixed
	-- console (the console is never resized for the keys).
	local size = KeySize()
	local area = fixedW and (fixedW - PAD * 2 - sideWidth * 2)
	if area then
		for _, bar in ipairs(P.console.bars) do
			local count = Shown(bar.id)
			if count * size + (count - 1) * Gap(bar) > area then size = min(size, floor((area - (count - 1) * Gap(bar)) / count)) end
		end
	end
	if fixedH and rows > 0 then
		local room = fixedH - HEAD - castRow - xpHeight - PAD - rows * bank - (rows - 1) * GAP
		size = min(size, floor(room / rows))
	end
	size = max(size, 16)
	P.console.keySize = size

	-- The user's own arrangement (the console editor), or nil for the automatic one.
	local custom = Deck.CustomLayout()
	local function Saved(key) return custom and custom[key] or nil end
	-- The keyboard: each bar one row (or the columns its bank was given), as wide as its shown keys.
	local width, height = 0, 0
	for _, bar in ipairs(P.console.bars) do
		local shape = Saved('bank'..bar.id)
		LayoutBar(bar, size, Gap(bar), Shown(bar.id), shape and tonumber(shape.columns) or 12, false)
		width = max(width, bar.width)
		height = height + bar.height + bank
	end
	height = height + max(rows - 1, 0) * GAP
	if width == 0 then width, height = 12 * size + 11 * GAP, size end
	area = area or width
	local align = db.bankAlign or 'center'
	-- Spread: the keys share out the whole width with even gaps.
	if align == 'spread' and fixedW and not custom then
		for _, bar in ipairs(P.console.bars) do
			local count = Shown(bar.id)
			if count > 1 then LayoutBar(bar, size, max(Gap(bar), (area - count * size) / (count - 1)), count, 12, false) end
		end
	end
	-- The body: as tall as the tallest of the banks, the docked columns (the
	-- player and target with the room for their lamps and auras, then a row for
	-- the small frames under them; the function keys under them when stacked)
	-- and the function keys.
	local mainHeight = max(ph, th)
	local underMain = mainHeight > 0 and mainHeight + AUX or 0
	local smallRow = max(fh, oh)
	local frames = max(mainHeight, smallRow > 0 and underMain + smallRow or 0)
	local stackHeight = (stacked and fnH > 0) and fnH + 8 or 0
	local body = max(height, frames > 0 and frames + AUX + stackHeight or 0, fnH)
	-- Embedded: the bays take whole bank rows (a legend and a key's height,
	-- rows a bank gap apart). The player and target bays span the rows above
	-- the focus and target-of-target row (at least two, more when the frame
	-- and the lamps or auras under it need them); the cast row is one more row.
	local pitch, mainRows, bayInset = bank + size + GAP, 0, 3
	if embedded then
		local small = fh > 0 or oh > 0
		local need = 0
		for _, key in ipairs({'player', 'target'}) do
			local frame = parts[key]
			if frame then
				local ratio = frame:GetEffectiveScale() / scale
				need = max(need, 44 * ratio + parts.module:DockRoom(frame) * ratio + bayInset * 2)
			end
		end
		mainRows = max(2, small and rows - 1 or rows)
		while (mainRows - 1) * pitch + size < need and mainRows < 8 do mainRows = mainRows + 1 end
		local columnRows = mainRows + (small and 1 or 0)
		body = max(max(rows, columnRows) * pitch - GAP, fnH)
		if lowHeight > 0 then lowHeight, castRow = size, bank + size + GAP end
	end
	if fixedH then body = max(fixedH - HEAD - castRow - xpHeight - PAD, 0) end
	-- An even number of pixels wide, so a centred console's edges land on pixels too.
	local consoleWidth = Snap((fixedW or (PAD * 2 + width + sideWidth * 2)) / 2) * 2
	-- The cast row starts on a pixel; the deck along the base is measured from the bottom.
	local castY = SnapUp(HEAD + body + (embedded and GAP + bank or ROW_GAP))
	local consoleHeight = fixedH and Snap(fixedH) or SnapUp((castRow > 0 and castY + lowHeight or HEAD + body) + xpHeight + PAD)
	local left = PAD + sideWidth
	-- The cast bars below share the banks' whole area.
	width = area

	-- Every element of the console is a block: a rect in console units from its
	-- top-left (x right, y down), on whole pixels. They are worked out here (the
	-- automatic arrangement, then the user's own over it), checked so none
	-- covers another or leaves the body, and then placed from the list.
	local blocks, bySlot = {}, {}
	local function Put(key, kind, frame, x, y, w, h)
		if w <= 0 or h <= 0 or (Saved(key) and Saved(key).off) then return end
		local block = {key = key, kind = kind, frame = frame, x = Snap(x), y = SnapUp(y), w = w, h = h}
		blocks[#blocks + 1] = block
		bySlot[key] = block
	end
	-- The banks, top row first (bar 1 is the bottom row, as on Blizzard's
	-- bars). In the Hardware look each has its printed legend above its keys.
	local bankY = HEAD + (embedded and 0 or max(0, floor((body - height) / 2)))
	for index = #P.console.bars, 1, -1 do
		local bar = P.console.bars[index]
		local x = align == 'left' and left or left + (area - bar.width) / 2
		Put('bank'..bar.id, 'bank', bar, x - 2, bankY, bar.width + 4, bank + bar.height)
		bankY = bankY + bank + bar.height + GAP
	end
	-- The columns sit centred on the body (the keys under them when stacked),
	-- never so low that the lamps or auras under the last frame leave it.
	local top = HEAD + (frames > 0 and max(0, floor(min((body - frames - stackHeight) / 2, body - frames - stackHeight - AUX))) or 0)
	local leftX, rightX = PAD + fnPart, consoleWidth - PAD - fnPart - column
	local function Centre(x, frameWidth) return x + (column - frameWidth) / 2 end
	local castWidth = Snap((width - 8) / 2)
	if embedded then
		-- Bays: the block is the legend row and the bay under it.
		local mainBay = bank + (mainRows - 1) * pitch + size
		local smallY = HEAD + mainRows * pitch
		local castTop = castY - bank
		local function Bay(key, frame, x, y, h) if frame then Put(key, 'unit', frame, x, y, column, h) end end
		Bay('uf.player', parts.player, leftX, HEAD, mainBay)
		Bay('uf.target', parts.target, rightX, HEAD, mainBay)
		Bay('uf.focus', parts.focus, leftX, smallY, bank + size)
		Bay('uf.targettarget', parts.tot, rightX, smallY, bank + size)
		for index, cast in ipairs({parts.playerCast or false, parts.targetCast or false}) do
			if cast then
				Put(index == 1 and 'cb.player' or 'cb.target', 'cast', cast, left + (index - 1) * (castWidth + 8), castTop, castWidth, bank + size)
			end
		end
		Bay('uf.pet', parts.pet, leftX, castTop, bank + size)
		for _, block in ipairs(blocks) do
			if block.kind == 'unit' or block.kind == 'cast' then block.bay = true end
		end
	else
	Put('uf.player', 'unit', parts.player, Centre(leftX, pw), top + (mainHeight - ph) / 2, pw, ph)
	Put('uf.target', 'unit', parts.target, Centre(rightX, tw), top + (mainHeight - th) / 2, tw, th)
	Put('uf.focus', 'unit', parts.focus, Centre(leftX, fw), top + underMain + (smallRow - fh) / 2, fw, fh)
	Put('uf.targettarget', 'unit', parts.tot, Centre(rightX, ow), top + underMain + (smallRow - oh) / 2, ow, oh)
	-- The cast row, under the body.
	for index, cast in ipairs({parts.playerCast or false, parts.targetCast or false}) do
		if cast then
			local _, castH = Measure(cast)
			Put(index == 1 and 'cb.player' or 'cb.target', 'cast', cast, left + (index - 1) * (castWidth + 8),
				castY + floor((lowHeight - castHeight) / 2), castWidth, castH)
		end
	end
	Put('uf.pet', 'unit', parts.pet, Centre(leftX, qw), castY + floor((lowHeight - qh) / 2), qw, qh)
	end
	-- The function keys, each side its own cluster: at the outer edges, or under the docked frames.
	local lw, lh, rw, rh = Deck.FnSides()
	if stacked then
		local fnY = top + frames + 8
		Put('fnL', 'fn', 1, PAD + (column - lw) / 2, fnY, lw, lh)
		Put('fnR', 'fn', 2, consoleWidth - PAD - (column + rw) / 2, fnY, rw, rh)
	else
		Put('fnL', 'fn', 1, PAD, HEAD + max(0, floor((body - lh) / 2)), lw, lh)
		Put('fnR', 'fn', 2, consoleWidth - PAD - rw, HEAD + max(0, floor((body - rh) / 2)), rw, rh)
	end
	for side, key in ipairs({'fnL', 'fnR'}) do
		if bySlot[key] then bySlot[key].count = #select(3, Deck.FnCluster(side)) end
	end
	-- The meters and stats strip along the base, and the menu keys over them.
	local deckHeight = max(Deck.BottomHeight() - ROW_GAP, 0)
	Put('deck', 'deck', false, PAD, consoleHeight - PAD - deckHeight, consoleWidth - PAD * 2, deckHeight)
	local strip = P.console.menuStrip
	if strip and stripCount > 0 and edge == 'bottom' then
		Put('menu', 'menu', strip, (consoleWidth - stripW) / 2, consoleHeight - PAD - Deck.BottomHeight() - stripH, stripW, stripH)
	elseif strip and stripCount > 0 and edge == 'body' then
		Put('menu', 'menu', strip, 0, 0, stripW, stripH)
	end
	if bySlot.menu then bySlot.menu.count, bySlot.menu.keySize = stripCount, stripKey end
	-- The stance and pet keys: tucked on the console's top edge, out on their
	-- own spot (taken out), or set into the body like a bank (a saved spot).
	-- Stance keys with no stances for this character take no room.
	local minis = Deck.Minis()
	for _, mini in ipairs(minis) do
		local spot = Saved(mini.key)
		mini.columns = spot and tonumber(spot.columns) or nil
		mini.keys = spot and tonumber(spot.keys) or nil
		Deck.ShapeMini(mini)
		if spot and spot.off then
			mini.state = 'out'
		elseif spot and tonumber(spot.x) and tonumber(spot.y) then
			mini.state = 'in'
			if mini.count > 0 then
				local w, h = Measure(mini.module)
				Put(mini.key, 'mini', mini, 0, 0, w, h)
			end
		else
			mini.state = 'tucked'
		end
	end

	-- The user's arrangement: each saved block at its spot (a cast bar or the
	-- deck at its width). Nothing may cover another block or leave the body,
	-- so a block that would (another grew, a new one docked) moves to the
	-- nearest free spot; the saved ones keep theirs first. The console then
	-- fits its blocks; a fixed size is kept when they fit inside it.
	local px = UI.Pixel.Px(P.console, 1)
	local bounds = {left = SnapUp(PAD), top = SnapUp(HEAD), right = fixedW and floor((consoleWidth - PAD) / px) * px or nil,
		bottom = fixedH and floor((consoleHeight - PAD) / px) * px or nil}
	if custom then
		for _, block in ipairs(blocks) do
			local spot = custom[block.key]
			if type(spot) == 'table' and tonumber(spot.x) and tonumber(spot.y) then
				if (block.kind == 'cast' or block.kind == 'deck' or block.bay) and tonumber(spot.w) then
					block.w = Snap(max(tonumber(spot.w), block.bay and 96 or 40))
				end
				-- A frame's bay may also be made taller or shorter (the frame follows it).
				if block.bay and block.kind == 'unit' and tonumber(spot.h) then
					block.h = SnapUp(max(tonumber(spot.h), bank + 30))
				end
				block.x, block.y, block.saved, block.rank = Snap(tonumber(spot.x)), SnapUp(tonumber(spot.y)), true, tonumber(spot.rank)
			end
		end
		local grid = UI.ConsoleGrid
		if grid then grid.Resolve(blocks, bounds, px * 2, px) end
		local right, bottom = 300 - PAD, HEAD
		for _, block in ipairs(blocks) do right, bottom = max(right, block.x + block.w), max(bottom, block.y + block.h) end
		consoleWidth = max(fixedW and consoleWidth or 0, Snap((right + PAD) / 2) * 2)
		consoleHeight = max(fixedH and consoleHeight or 0, SnapUp(bottom + PAD))
		-- The stance and pet keys tuck in over the first bank's ends.
		local first = bySlot['bank'..(P.console.bars[1] and P.console.bars[1].id or 1)]
		if first then left = first.x + 2 end
	end
	P.console:SetSize(consoleWidth, consoleHeight)
	P.console.blocks, P.console.slots, P.console.bounds = blocks, blocks, bounds
	if Deck.AdjustSlots then UI:Safe(Deck.AdjustSlots, blocks, P.console) end

	-- Place them. An LCD-style frame keeps its own LCD face; paper and dark ones
	-- sit on the housing. A cast bar takes its block's width.
	local keepShell = UI:Style('unitframes') == 'lcd'
	local docked = {}
	for _, block in ipairs(blocks) do
		local kind, frame, x, y = block.kind, block.frame, block.x, block.y
		if kind == 'bank' then
			if frame.bank then HW.PlaceBank(frame.bank, P.console, x, -y, block.w, bank > 0) end
			frame.header:ClearAllPoints()
			frame.header:SetPoint('TOPLEFT', P.console, 'TOPLEFT', x + 2, -(y + bank))
		elseif kind == 'fn' then
			Deck.PlaceFnAt(P.console, frame, x, y)
		elseif kind == 'menu' then
			frame:ClearAllPoints()
			frame:SetPoint('TOPLEFT', P.console, 'TOPLEFT', x, -y)
		elseif kind == 'mini' then
			Deck.PlaceMini(frame, P.console, x, y)
		elseif (kind == 'unit' or kind == 'cast') and frame then
			docked[block.key] = frame
			local ratio = select(3, Measure(frame))
			if block.bay then
				-- In its bay: the frame fills the bay inside a small inset (large
				-- frames leave room under them for their lamps and auras).
				local inset = Snap(kind == 'unit' and frame.layout and frame.layout.size == 'large' and bayInset or 2)
				local room = kind == 'unit' and parts.module:DockRoom(frame) * ratio or 0
				local w = block.w - inset * 2
				local h = kind == 'cast' and select(2, Measure(frame)) or max(block.h - bank - inset * 2 - room, 20)
				if kind == 'cast' then
					frame:SetWidth(w / ratio)
					parts.module:SetDocked(frame, true, keepShell, {w / ratio, h / ratio})
				else
					parts.module:SetDocked(frame, true, keepShell, {w / ratio, h / ratio})
				end
				Deck.PlaceBay(P.console, block, frame, bank)
				x, y = x + inset, y + bank + (kind == 'cast' and floor((block.h - bank - h) / 2) or inset)
			else
				if kind == 'cast' then frame:SetWidth(block.w / ratio) end
				parts.module:SetDocked(frame, true, keepShell)
			end
			UI:DockMover(block.key, function(target)
				local now = target:GetEffectiveScale() / P.console:GetEffectiveScale()
				target:SetPoint('TOPLEFT', P.console, 'TOPLEFT', x / now, -y / now)
			end)
		end
	end
	-- Frames taken out of the console get their own spot back.
	for key, frame in pairs(P.console.docked or {}) do
		if not docked[key] then
			UI:DockMover(key, nil)
			local unitframes = UI.modules.unitframes
			if unitframes and unitframes.SetDocked then unitframes:SetDocked(frame, false) end
			DockScale(frame, 1)
		end
	end
	P.console.docked = docked
	Deck.HideBays(P.console, bySlot)
	for index = 1, 2 do
		if not bySlot[index == 1 and 'fnL' or 'fnR'] then Deck.PlaceFnAt(P.console, index, nil) end
	end
	-- Plates where a docked frame shows up when it has no unit: dim, the frame's
	-- size (the target's is the player's), or nothing.
	Deck.Plates(P.console, parts)
	local plateOn = db.targetPlate ~= 'collapse'
	local function Plate(plate, frame, rect, w, h)
		if not plate then return end
		plate.enabled = plateOn and frame ~= nil and rect ~= nil
		if not plate.enabled then plate:Hide() return end
		plate:SetSize(w or rect.w, h or rect.h)
		plate:ClearAllPoints()
		plate:SetPoint('TOPLEFT', P.console, 'TOPLEFT', rect.x + (rect.w - (w or rect.w)) / 2, -rect.y)
		plate:SetShown(not frame:IsShown())
	end
	-- (Embedded, each bay shows its own unlit screen instead.)
	local function Rect(key) return not embedded and bySlot[key] or nil end
	Plate(P.console.targetSlot, parts.target, Rect('uf.target'), pw > 0 and pw or tw, ph > 0 and ph or th)
	Plate(P.console.focusSlot, parts.focus, Rect('uf.focus'))
	Plate(P.console.totSlot, parts.tot, Rect('uf.targettarget'))
	for index, key in ipairs({'cb.player', 'cb.target'}) do
		local rect, slot = bySlot[key], P.console.castSlots[index]
		if rect and not rect.bay then
			slot:SetSize(rect.w, castHeight)
			slot:ClearAllPoints()
			slot:SetPoint('TOPLEFT', P.console, 'TOPLEFT', rect.x, -rect.y)
		end
	end
	local deck = bySlot.deck
	if deck then
		Deck.PlaceBottom(P.console, deck.x, consoleWidth - deck.x - deck.w, consoleHeight - deck.y - deck.h)
	else
		Deck.PlaceBottom(P.console, PAD, PAD, PAD, true)
	end
	if P.console.lcd then P.console.lcd:SetShown(DB().readout ~= 'off') end
	-- Header panels, leftward from the page lamps (or the LCD) while they fit.
	local headerStrip = strip and stripCount > 0 and edge == 'header'
	if P.console.panels then
		local anchor = P.console.pager or P.console.lcd
		local used = PAD + (P.console.lcd:IsShown() and P.console.lcd:GetWidth() or 0) + (P.console.pager and P.console.pager:GetWidth() + 10 or 0) + 8
		if headerStrip then used = used + stripW + 12 end
		local last = Deck.PlacePanels(P.console, anchor, used)
		-- The header strip sits centred between the name and the readouts
		-- (against the readouts when the name is long); the name ends before it.
		if headerStrip then
			strip:ClearAllPoints()
			local x = Deck.HeaderStripX(P.console, last, stripW)
			if x then
				strip:SetPoint('LEFT', P.console, 'TOPLEFT', x, -HEAD / 2)
				P.console.headerStripX = x
			else
				strip:SetPoint('RIGHT', last, 'LEFT', -12, 0)
				P.console.headerStripX = nil
			end
			last = strip
		end
		P.console.title:SetPoint('RIGHT', last, 'LEFT', -8, 0)
		if leave then
			leave:ClearAllPoints()
			leave:SetPoint('RIGHT', last, 'LEFT', -8, 0)
		end
	end
	if strip then
		strip:SetSize(max(stripW, 1), max(stripH, 1))
		strip:SetShown(stripCount > 0)
		-- Put the menu and bag keys into it (or back on their own devices).
		if Deck.LayoutMenu then Deck.LayoutMenu() end
	end
	-- Tucked pet and stance keys sit on the console's top edge, under it;
	-- taken-out ones go back to their own spot. The editor sees the tucked
	-- ones too (outside the body, so they hold no room in it).
	local tucked = {}
	local stanceRect
	for _, mini in ipairs(minis) do
		if mini.state == 'out' then
			Deck.FreeMini(mini)
		elseif mini.state == 'tucked' then
			local w, h = Measure(mini.module)
			-- Where the editor slid it along the edge (edgeX), or over the first bank's end.
			local spot = custom and custom[mini.key]
			local edgeX = type(spot) == 'table' and tonumber(spot.edgeX)
			local x = edgeX and Kit:Clamp(Snap(edgeX), 0, max(consoleWidth - w, 0))
				or mini.key == 'stance' and left - 8 or consoleWidth - left + 8 - w
			local y = 8 - h
			-- Never over the other one: the pet keys go above the stance keys if they would meet.
			if stanceRect and mini.count > 0 and x < stanceRect.x + stanceRect.w + 4 and stanceRect.x < x + w + 4 then
				y = stanceRect.y - h - 4
			end
			Deck.PlaceMini(mini, P.console, x, y, true)
			if mini.count > 0 then
				local rect = {key = mini.key, kind = 'mini', x = x, y = y, w = w, h = h, tucked = true, count = mini.count, keySize = mini.size}
				tucked[#tucked + 1] = rect
				if mini.key == 'stance' then stanceRect = rect end
			end
		end
	end
	-- The menu strip in the header, as the editor sees it (outside the body).
	if strip and stripCount > 0 and edge == 'header' and P.console.headerStripX then
		tucked[#tucked + 1] = {key = 'menu', kind = 'menu', x = P.console.headerStripX, y = (HEAD - stripH) / 2, w = stripW, h = stripH,
			tucked = true, header = true, count = stripCount, keySize = stripKey}
	end
	P.console.tucked = tucked
end

function LayoutConsole()
	if not P.console then return end
	if InCombatLockdown() then return UI:AfterCombat(LayoutConsole, 'ab.layout') end
	P.console.laying = true
	local ok, problem = pcall(LayoutConsoleNow)
	P.console.laying = nil
	if not ok then error(problem, 0) end
	-- The latch's default spot is in the header: it follows the console (next frame, once placed).
	if latch then C_Timer.After(0, function() UI:Safe(PlaceLatch) end) end
end

local function BuildConsole()
	P.console = Device('JiberishSpec01Console', 'CX-1', 'Console', {template = 'SecureHandlerStateTemplate', radius = 14})
	-- The whole console steps aside in pet battles.
	RegisterStateDriver(P.console, 'visibility', '[petbattle] hide; show')
	P.console.lcd = Kit:LCDPanel(P.console, {radius = 3})
	P.console.lcd:SetSize(104, 14)
	P.console.lcd:SetPoint('TOPRIGHT', -PAD, -5)
	P.console.readout = Kit:Text(P.console.lcd, '', 'tiny', 'lcdInk', true)
	P.console.readout:SetPoint('RIGHT', -5, 0)
	BuildLeave(P.console)
	if HW.On() then
		HW.Decorate(P.console, 14)
		P.console.pager = HW.BuildPager(P.console)
		P.console.pager:SetPoint('RIGHT', P.console.lcd, 'LEFT', -10, 0)
		P.console.title:SetPoint('RIGHT', P.console.pager, 'LEFT', -8, 0)
		leave:SetPoint('RIGHT', P.console.pager, 'LEFT', -8, 0)
	else
		P.console.title:SetPoint('RIGHT', P.console.lcd, 'LEFT', -8, 0)
		leave:SetPoint('RIGHT', P.console.lcd, 'LEFT', -6, 0)
	end
	local size = KeySize()
	P.console.bars = {}
	for row = 1, Rows() do
		if BarEnabled(row) then
			BuildBar(BARS[row], P.console, size)
			P.console.bars[#P.console.bars + 1] = BARS[row]
			WatchFade(BARS[row].header, row, BARS[row].buttons)
			if HW.On() then BARS[row].bank = HW.Bank(P.console, 'Bank '..strsub('ABC', row, row)..(row == 1 and '  Main' or '')) end
		end
	end
	Deck.Plates(P.console, UnitParts())
	-- The cast slots only hold the space: a cast bar appears there when a cast
	-- starts, and nothing is printed while nothing is casting.
	P.console.castSlots = {Slot(P.console, ''), Slot(P.console, '')}
	for _, slot in ipairs(P.console.castSlots) do slot:Hide() end
	P.xp = BuildXP(P.console)
	-- Where the menu and bag keys go when they are set into the console.
	P.console.menuStrip = CreateFrame('Frame', nil, P.console)
	P.console.menuStrip:SetFrameLevel(P.console:GetFrameLevel() + 4)
	P.console.menuStrip:Hide()
	Deck.BuildBottom(P.console)
	Deck.BuildFn(P.console)
	Deck.BuildPanels(P.console)
	if P.console.pager and BARS[1].header then HW.ShowPage(P.console.pager, BARS[1].header:GetAttribute('actionpage') or 1) end
	UI:RegisterMover(P.console, 'ab.console', 'Console', {'BOTTOM', 0, 12})
end

-- The console's width and height and the key size in use (nil without a console).
function UI:ConsoleSize()
	if not P.console then return nil end
	return floor(P.console:GetWidth() + 0.5), floor(P.console:GetHeight() + 0.5), P.console.keySize
end

-- The console's blocks as it last laid them out: a list of {key, kind, x, y,
-- w, h} in console units from its top-left corner (y down); kind is 'bank',
-- 'unit', 'cast', 'fn', 'deck' or 'menu'. Also its body's bounds.
function UI:ConsoleSlots()
	local list = {}
	for _, slot in ipairs(P.console and P.console.slots or {}) do
		local mini = slot.kind == 'mini' and slot.frame or nil
		list[#list + 1] = {key = slot.key, kind = slot.kind, x = slot.x, y = slot.y, w = slot.w, h = slot.h, saved = slot.saved,
			count = mini and mini.count or slot.count, keySize = mini and mini.size or slot.keySize, bay = slot.bay}
	end
	-- Pet and stance keys tucked on the top edge (outside the body).
	for _, slot in ipairs(P.console and P.console.tucked or {}) do list[#list + 1] = slot end
	return list, P.console and P.console.bounds
end
UI.ConsoleBlocks = UI.ConsoleSlots

-- The console device (nil in the free layout), and laying it out again now.
function UI:ConsoleFrame() return P.console end
function UI:RelayoutConsole() if P.console then LayoutConsole() end end

-- Free layout: every bar is its own device, sized to its keys.
local function LayoutFree()
	if InCombatLockdown() then return UI:AfterCombat(LayoutFree, 'ab.free') end
	for row = 1, Rows() do
		local bar, device = BARS[row], BARS[row].device
		if device then
			local width, height = LayoutBar(bar, BarSize(row, KeySize()), Spacing(row), Shown(row), PerRow(row), false)
			local extra = (row == 1 and P.xp) and Deck.BottomHeight() or 0
			device:SetSize(width + PAD * 2, height + PAD * 2 + extra)
			if row == 1 and P.xp then Deck.PlaceBottom(device, PAD) end
		end
	end
end

local function BuildFree()
	local size = KeySize()
	for row = 1, Rows() do
		if BarEnabled(row) then
			local device = Device(format('JiberishSpec01BarDevice%d', row), 'AB-'..row, '', {header = false,
				template = 'SecureHandlerStateTemplate', radius = 10})
			RegisterStateDriver(device, 'visibility', '[petbattle] hide; show')
			local header = BuildBar(BARS[row], device, BarSize(row, size))
			header:SetPoint('TOPLEFT', PAD, -PAD)
			BARS[row].device = device
			HW.Decorate(device, 10)
			if row == 1 then
				P.xp = BuildXP(device)
				Deck.BuildBottom(device)
				Deck.PlaceBottom(device, PAD)
				BuildLeave(device)
				leave:SetPoint('BOTTOMRIGHT', device, 'TOPRIGHT', -PAD, 4)
			end
			WatchFade(device, row, BARS[row].buttons)
		end
	end
	LayoutFree()
	for row = 1, Rows() do
		local device = BARS[row].device
		if device then
			UI:RegisterMover(device, 'ab.bar'..row, 'Bar '..row, {'BOTTOM', 0, 12 + (row - 1) * (device:GetHeight() + 6)})
		end
	end
end

-- Side bars: bar 5 and bar 4 in one device, as two columns at the screen edge
-- or as two rows. Blizzard's left bar comes first.
local function SideSize(id) return BarSize(id, max(24, floor(KeySize() * 0.9))) end

local function LayoutSide()
	if not P.side then return end
	if InCombatLockdown() then return UI:AfterCombat(LayoutSide, 'ab.side') end
	local vertical = DB().sideLayout ~= 'rows'
	local x, y, width, height = PAD, -HEAD, 0, 0
	for _, id in ipairs({5, 4}) do
		local bar = BARS[id]
		if bar.header then
			local w, h = LayoutBar(bar, SideSize(id), Spacing(id), Shown(id), PerRow(id), vertical)
			bar.header:ClearAllPoints()
			bar.header:SetPoint('TOPLEFT', P.side, 'TOPLEFT', x, y)
			if vertical then
				x = x + w + GAP
				width, height = width + w + GAP, max(height, h)
			else
				y = y - h - GAP
				width, height = max(width, w), height + h + GAP
			end
		end
	end
	if vertical then width = width - GAP else height = height - GAP end
	P.side:SetSize(PAD * 2 + max(width, 20), HEAD + max(height, 20) + PAD)
end

local function BuildSide()
	if not (BarEnabled(4) or BarEnabled(5)) then return end
	P.side = Device('JiberishSpec01SideBars', 'SX-1', 'Side', {template = 'SecureHandlerStateTemplate', radius = 12})
	HW.Decorate(P.side, 12)
	RegisterStateDriver(P.side, 'visibility', '[petbattle] hide; show')
	local vertical = DB().sideLayout ~= 'rows'
	for _, id in ipairs({5, 4}) do
		if BarEnabled(id) then
			BuildBar(BARS[id], P.side, SideSize(id), vertical)
			WatchFade(BARS[id].header, id, BARS[id].buttons)
		end
	end
	LayoutSide()
	UI:RegisterMover(P.side, 'ab.side', 'Side bars', {'RIGHT', -8, 0})
end

-- Blizzard's pet buttons, anchored in our strip; out of combat only.
local function PlacePetKeys()
	if not P.petModule then return end
	if InCombatLockdown() then return UI:AfterCombat(PlacePetKeys, 'ab.petkeys') end
	for _, button in pairs(petKeys) do
		if button:GetParent() ~= P.petModule then button:SetParent(P.petModule) end
		button:Show()
	end
	local spot = Deck.CustomLayout() and Deck.CustomLayout().petbar
	Deck.LayoutMini(P.petModule, petKeys, NUM_PET_ACTION_SLOTS or 10, type(spot) == 'table' and tonumber(spot.columns) or nil)
end

local function BuildPet()
	local size = BarSize('Pet', max(20, floor(KeySize() * 0.72)))
	local count = NUM_PET_ACTION_SLOTS or 10
	P.petModule = Device('JiberishSpec01PetKeys', 'PT-1', '', {header = false, template = 'SecureHandlerStateTemplate', radius = 9, level = 4})
	P.petModule:SetSize(PAD + count * size + (count - 1) * Spacing('Pet') + PAD, size + 16 + (HW.On() and HW.BANK_H or 0))
	P.petModule.keySize, P.petModule.spacingId = size, 'Pet'
	HW.MiniLegend(P.petModule, 'Pet')
	RegisterStateDriver(P.petModule, 'visibility', '[petbattle][vehicleui][overridebar][possessbar] hide; [@pet,exists] show; hide')
	for index = 1, count do
		local button = _G['PetActionButton'..index]
		if button and not Forbidden(button) then
			Dress(button, size)
			petKeys[index] = button
			extraKeys[#extraKeys + 1] = {button = button, command = 'BONUSACTIONBUTTON'..index, hotkey = button.HotKey}
		end
	end
	PlacePetKeys()
	local buttons = {}
	for _, button in pairs(petKeys) do buttons[#buttons + 1] = button end
	WatchFade(P.petModule, 'Pet', buttons)
	-- Edit Mode lays the pet bar out again later; take the keys back each time.
	local bar = _G.PetActionBar
	if bar and type(bar.UpdateGridLayout) == 'function' then
		hooksecurefunc(bar, 'UpdateGridLayout', function() C_Timer.After(0, PlacePetKeys) end)
	end
	if not Docking() then UI:RegisterMover(P.petModule, 'ab.pet', 'Pet keys', {'BOTTOM', 200, 150}) end
end

-- The stance latch: a small key of its own (STANCE, with a lamp lit while the
-- stance keys show) that folds the stance keys away and brings them back, with
-- a latch sound. It sits in the console's header by default and has its own
-- handle in edit mode (/spec move), so it can go anywhere. It is not secure,
-- so it works in combat; the fold itself waits for the fight to end.
local function Folded() return DB().stanceFolded and true or false end

local function PaintLatch(pending)
	if not latch then return end
	local shown = not Folded()
	latch:SetChecked(shown)
	Kit:SetLed(latch.led, shown or pending, pending and 'amber' or nil)
end

-- Its default spot: in the console's header, after the model and title.
local function LatchDefault()
	local console = P.console
	if not (console and console:IsShown() and console:GetLeft()) then return {'BOTTOM', -200, 196} end
	local ce, ue = console:GetEffectiveScale(), UIParent:GetEffectiveScale()
	local x = 120
	if console.model and console.model:GetLeft() and console.title then
		x = console.model:GetLeft() - console:GetLeft() + console.model:GetStringWidth() + 5 + console.title:GetStringWidth() + 14
	end
	local ratio = ce / ue
	return {'TOPLEFT', (console:GetLeft() + x) * ratio, (console:GetTop() - (HEAD - latch:GetHeight()) / 2) * ratio - UIParent:GetTop()}
end

function PlaceLatch()
	if not latch then return end
	local forms = GetNumShapeshiftForms and GetNumShapeshiftForms() or 0
	local parent = P.console or UIParent
	if latch:GetParent() ~= parent then latch:SetParent(parent) end
	latch:SetFrameStrata(parent:GetFrameStrata())
	latch:SetFrameLevel(parent:GetFrameLevel() + 12)
	Kit:Relevel(latch)
	latch:SetShown(forms > 0)
	PaintLatch()
	UI:RegisterMover(latch, 'ab.stancelatch', 'Stance latch', LatchDefault(), {page = 'actionbars'})
end

local function LayoutStance()
	if not P.stanceModule then return end
	if InCombatLockdown() then return UI:AfterCombat(LayoutStance, 'ab.stance') end
	local forms = GetNumShapeshiftForms and GetNumShapeshiftForms() or 0
	local folded = Folded()
	for index, button in ipairs(stanceKeys) do button:SetShown(index <= forms) end
	P.stanceModule:SetShown(forms > 0 and not folded)
	local spot = Deck.CustomLayout() and Deck.CustomLayout().stance
	if forms > 0 then Deck.LayoutMini(P.stanceModule, stanceKeys, forms, type(spot) == 'table' and tonumber(spot.columns) or nil) end
	UpdateStance()
	-- Set into the console, the stance keys take room only while there are stances (and they aren't folded).
	local present = forms > 0 and not folded
	if P.console and P.stanceModule.present ~= nil and P.stanceModule.present ~= present then LayoutConsole() end
	P.stanceModule.forms, P.stanceModule.present = forms, present
	PlaceLatch()
end

-- Fold the stance keys away, or bring them back (nil: the other way). The keys
-- are secure, so in combat the fold waits for the fight to end; the latch's
-- lamp shows amber until then.
function UI:FoldStance(folded)
	if folded == nil then folded = not Folded() end
	folded = folded and true or false
	if Folded() == folded and not InCombatLockdown() then return PaintLatch() end
	DB().stanceFolded = folded
	Kit:Play(folded and 'latch-down' or 'latch-up')
	if InCombatLockdown() then
		PaintLatch(true)
		return UI:AfterCombat(function() LayoutStance(); if P.console then LayoutConsole() end end, 'ab.stancefold')
	end
	LayoutStance()
	if P.console then LayoutConsole() end
end
function UI:StanceFolded() return Folded() end

local function BuildLatch()
	if latch then return end
	latch = Kit:Key(P.console or UIParent, {width = 60, height = 15, text = 'Stance', textSize = 6, toggle = true, sound = false})
	latch.led:ClearAllPoints()
	latch.led:SetPoint('LEFT', 7, 0)
	latch.text:ClearAllPoints()
	latch.text:SetPoint('LEFT', latch.led, 'RIGHT', 5, 0)
	latch:SetKeyText('Stance')
	latch.onClick = function() UI:FoldStance() end
	latch:HookScript('OnEnter', function(self)
		GameTooltip:SetOwner(self, 'ANCHOR_TOP')
		GameTooltip:AddLine(Folded() and 'Show stance keys' or 'Fold stance keys', 1, 1, 1)
		GameTooltip:AddLine('Click to fold the stance keys away or bring them back (/spec stance). Move this key in edit mode (/spec move).',
			0.85, 0.85, 0.82, true)
		GameTooltip:Show()
	end)
	latch:HookScript('OnLeave', function() GameTooltip:Hide() end)
	latch:Hide()
end

local function BuildStance()
	local size = BarSize('Stance', max(20, floor(KeySize() * 0.72)))
	P.stanceModule = Device('JiberishSpec01StanceKeys', 'ST-1', '', {header = false, radius = 9, level = 4})
	P.stanceModule.size, P.stanceModule.keySize, P.stanceModule.spacingId = size, size, 'Stance'
	P.stanceModule:SetHeight(size + 16 + (HW.On() and HW.BANK_H or 0))
	HW.MiniLegend(P.stanceModule, 'Stance')
	BuildLatch()
	for index = 1, (NUM_STANCE_SLOTS or 10) do
		local button = CreateFrame('CheckButton', 'JiberishSpec01StanceKey'..index, P.stanceModule, 'StanceButtonTemplate')
		button:SetID(index)
		button:SetPoint('LEFT', PAD + (index - 1) * (size + Spacing('Stance')), (Docking() and 4 or 0) - (HW.On() and HW.BANK_H / 2 or 0))
		Dress(button, size)
		stanceKeys[index] = button
		extraKeys[#extraKeys + 1] = {button = button, command = 'SHAPESHIFTBUTTON'..index, hotkey = button.HotKey}
	end
	WatchFade(P.stanceModule, 'Stance', stanceKeys)
	if not Docking() then UI:RegisterMover(P.stanceModule, 'ab.stance', 'Stance keys', {'BOTTOM', -200, 150}) end
end

-- The pet and stance keys as console blocks -------------------------------------------------
-- Keys in lines of `columns` (all in one line by default), evenly spaced, the
-- device sized round them. Out of combat only (secure buttons).
function Deck.LayoutMini(module, keys, count, columns)
	if not module or InCombatLockdown() then return end
	count = max(floor(count or 1), 1)
	local size, spacing = module.keySize or 24, Spacing(module.spacingId or 'Stance')
	local across = Kit:Clamp(floor(columns or count), 1, count)
	local lines = math.ceil(count / across)
	local keysW, keysH = across * size + (across - 1) * spacing, lines * size + (lines - 1) * spacing
	local height = keysH + 16 + (HW.On() and HW.BANK_H or 0)
	local top = (height - keysH) / 2 - ((Docking() and 4 or 0) - (HW.On() and HW.BANK_H / 2 or 0))
	module:SetSize(PAD * 2 + keysW, height)
	for index = 1, count do
		local button = keys[index]
		if button then
			local line, place = floor((index - 1) / across), (index - 1) % across
			button:ClearAllPoints()
			button:SetPoint('TOPLEFT', module, 'TOPLEFT', PAD + place * (size + spacing), -(top + line * (size + spacing)))
		end
	end
end

-- The two as the console sees them: {key, module, mover, count, size}. The
-- pet keys always hold their room (a pet can come in combat); the stance keys
-- only while this character has stances.
function Deck.Minis()
	local list = {}
	if P.stanceModule then
		list[#list + 1] = {key = 'stance', module = P.stanceModule, mover = 'ab.stance', label = 'Stance keys', at = {'BOTTOM', -200, 150},
			count = not Folded() and GetNumShapeshiftForms and GetNumShapeshiftForms() or 0, size = P.stanceModule.keySize,
			keysList = stanceKeys}
	end
	if P.petModule then
		list[#list + 1] = {key = 'petbar', module = P.petModule, mover = 'ab.pet', label = 'Pet keys', at = {'BOTTOM', 200, 150},
			count = NUM_PET_ACTION_SLOTS or 10, size = P.petModule.keySize, keysList = petKeys}
	end
	return list
end

-- Its shape (columns) and key size (a scale on the device) for where it is.
function Deck.ShapeMini(mini)
	local module = mini.module
	if mini.count > 0 then Deck.LayoutMini(module, mini.keysList, mini.count, mini.columns) end
	local base = DB().scale or 1
	local scale = mini.keys and base * Kit:Clamp(mini.keys, 16, 48) / max(mini.size or 24, 1) or base
	if math.abs(module:GetScale() - scale) > 0.001 then module:SetScale(scale) end
end

-- Anchor it inside the console (or, tucked, on its top edge and under it) at
-- x, y in console units from the top-left. With a mover of its own (it was
-- taken out once), the mover holds it there.
function Deck.PlaceMini(mini, parent, x, y, tucked)
	local module = mini.module
	local function Place(frame)
		local ratio = frame:GetEffectiveScale() / parent:GetEffectiveScale()
		frame:SetPoint('TOPLEFT', parent, 'TOPLEFT', x / ratio, -y / ratio)
	end
	-- Inside, it sits on the console's housing, above it; tucked, under its edge.
	module:SetFrameLevel(tucked and 4 or parent:GetFrameLevel() + 3)
	Kit:Relevel(module)
	if module.shell then module.shell:SetShown(tucked and DB().housing ~= false or false) end
	if UI:HasMover(mini.mover) then
		UI:DockMover(mini.mover, Place)
	else
		module:ClearAllPoints()
		Place(module)
	end
end

-- Taken out of the console: its own spot (a mover, made the first time).
function Deck.FreeMini(mini)
	local module = mini.module
	module:SetFrameLevel(4)
	Kit:Relevel(module)
	if module.shell then module.shell:SetShown(DB().housing ~= false) end
	if UI:HasMover(mini.mover) then
		UI:DockMover(mini.mover, nil)
	else
		UI:RegisterMover(module, mini.mover, mini.label, mini.at)
	end
end


-- Shared with the other action bar files.
P.BuildConsole = BuildConsole
P.BuildFree = BuildFree
P.BuildPet = BuildPet
P.BuildSide = BuildSide
P.BuildStance = BuildStance
P.BuildXP = BuildXP
P.Device = Device
P.HideDocked = HideDocked
P.LayoutConsole = LayoutConsole
P.LayoutFree = LayoutFree
P.LayoutSide = LayoutSide
P.LayoutStance = LayoutStance
P.PlacePetKeys = PlacePetKeys
P.Readout = Readout
P.UpdateFades = UpdateFades
P.UpdateLeave = UpdateLeave
P.UpdateXP = UpdateXP
