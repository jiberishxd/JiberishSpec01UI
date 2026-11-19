-- Edit mode's header strip and inspector chip. Modules/Movers.lua runs edit
-- mode itself (UI:EditMode): the handles, snapping, guides and keyboard.
--
--   Strip  a dark SPEC-01 strip at the top of the screen while edit mode is
--          on (drag it by its housing): its lamp and legend, what is being
--          edited (FRAMES, or CONSOLE while the console editor is open in
--          place), the grid (1, 2, 4 or 8 px), Snap and Lines, Console (the
--          console editor, in place) and Layout map (the hub's Layout page),
--          Undo, Reset (every frame, after a confirm) and Done.
--   Chip   by the selected frame's handle: its name and settings key, its
--          anchor (click for the next), x and y in screen pixels from it, its
--          scale (- and +), Hide and Reset (this frame only).
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown = CreateFrame, UIParent, InCombatLockdown
local floor, max = math.floor, math.max

local strip, chip

local function Key(parent, text, width, height, opts)
	opts = opts or {}
	opts.text, opts.width, opts.height, opts.textSize = text, width, height, 7
	return Kit:Key(parent, opts)
end

local function LCD(parent, width, height)
	local panel = Kit:LCDPanel(parent, {radius = 3})
	panel:SetSize(width, height)
	panel.text = Kit:Text(panel, '', 8, 'lcdInk', true)
	panel.text:SetPoint('CENTER')
	return panel
end

-- Lay widgets out left to right from x on one line; {gap = n} adds space.
local function Row(parent, items, x, y)
	for _, item in ipairs(items) do
		if item.gap then
			x = x + item.gap
		else
			item:ClearAllPoints()
			item:SetPoint('TOPLEFT', parent, 'TOPLEFT', x, y)
			x = x + item:GetWidth() + 4
		end
	end
	return x - 4
end

-- A key printed with the gear glyph (the settings key).
local function GearKey(parent, size, onClick)
	local key = Kit:Key(parent, {width = size, height = size, onClick = onClick})
	key.glyph = key.face:CreateTexture(nil, 'OVERLAY', nil, 2)
	key.glyph:SetSize(size - 8, size - 8)
	key.glyph:SetPoint('CENTER')
	UI:SetGearGlyph(key.glyph)
	Kit:Tint(key.glyph, 'ink')
	return key
end

local function ConsoleEditing() return UI.ConsoleEditing and UI:ConsoleEditing() or false end
local function HasConsole() return UI.ConsoleFrame and UI:ConsoleFrame() ~= nil or false end

-- The strip -------------------------------------------------------------------------------
local STRIP_KEY = 22

local function UpdateStrip()
	if not (strip and strip:IsShown()) then return end
	local console = ConsoleEditing()
	strip.mode.text:SetText(console and 'CONSOLE' or 'FRAMES')
	strip.size:SetKeyText(format('Grid %d px', UI:MoverGrid()))
	strip.snap:SetChecked(UI.db.layout.snap and true or false)
	strip.lines:SetChecked(UI:MoverGridShown())
	strip.console:SetChecked(console)
	strip.console:SetKeyEnabled(HasConsole())
	-- The console editor has its own grid and undo.
	for _, key in ipairs(strip.frameKeys) do key:SetKeyEnabled(not console) end
	strip.undo:SetKeyEnabled(not console and UI:CanUndoMover())
end

local function BuildStrip()
	strip = Kit:Device(UIParent, {surface = 'dark', header = false, width = 600, height = 48, radius = 8})
	strip:SetFrameStrata('FULLSCREEN_DIALOG')
	strip:SetClampedToScreen(true)
	strip:SetMovable(true)
	strip:EnableMouse(true)
	strip:RegisterForDrag('LeftButton')
	strip:SetScript('OnDragStart', function(self) self:StartMoving() end)
	strip:SetScript('OnDragStop', function(self) self:StopMovingOrSizing() end)

	strip.lamp = Kit:Led(strip, 5, true)
	strip.title = Kit:Label(strip, 'Edit mode', 'darkInk', 9, true)
	strip.mode = LCD(strip, 62, STRIP_KEY)
	strip.size = Key(strip, 'Grid 8 px', 72, STRIP_KEY, {onClick = function()
		local grids, now, index = UI.MOVER_GRIDS, UI:MoverGrid(), 1
		for at, value in ipairs(grids) do if value == now then index = at end end
		UI:SetMoverGrid(grids[index % #grids + 1])
		Kit:Play('tick', true)
		UpdateStrip()
	end})
	strip.snap = Key(strip, 'Snap', 54, STRIP_KEY, {toggle = true, onClick = function(key) UI.db.layout.snap = key.checked end})
	strip.lines = Key(strip, 'Lines', 56, STRIP_KEY, {toggle = true, onClick = function(key) UI:ShowMoverGrid(key.checked) end})
	strip.console = Key(strip, 'Console', 70, STRIP_KEY, {toggle = true, onClick = function()
		if InCombatLockdown() then return end
		UI:EditConsole(not ConsoleEditing())
		UpdateStrip()
	end})
	strip.layout = Key(strip, 'Layout map', 80, STRIP_KEY, {onClick = function()
		if UI.ToggleHub then UI:ToggleHub('layout', true) end
	end})
	strip.undo = Key(strip, 'Undo', 50, STRIP_KEY, {onClick = function() UI:UndoMover() end})
	strip.reset = Key(strip, 'Reset', 54, STRIP_KEY, {onClick = function()
		Kit:AlertDialog({title = 'Reset every frame', confirm = 'Reset',
			text = 'Every SPEC-01 frame goes back to its default spot, scale and opacity. Undo can bring them back.',
			onConfirm = function() UI:ResetMovers() end})
	end})
	strip.done = Key(strip, 'Done', 60, STRIP_KEY, {tone = 'primary', onClick = function() UI:EditMode(false) end})
	strip.frameKeys = {strip.size, strip.snap, strip.lines, strip.reset}
	Kit:AttachTooltip(strip.layout, 'The whole interface on one map, with presets')
	Kit:AttachTooltip(strip.console, 'Edit the blocks inside the console')

	local left = 10
	strip.lamp:SetPoint('LEFT', strip, 'TOPLEFT', left, -8 - STRIP_KEY / 2)
	strip.title:SetPoint('LEFT', strip.lamp, 'RIGHT', 6, 0)
	local x = left + 11 + strip.title:GetStringWidth() + 10
	local width = Row(strip, {strip.mode, {gap = 6}, strip.size, strip.snap, strip.lines, {gap = 10}, strip.console,
		strip.layout, {gap = 10}, strip.undo, strip.reset, {gap = 10}, strip.done}, x, -8)
	strip.hint = Kit:Label(strip, 'Drag frames  -  right-click or gear: settings  -  arrows nudge 1 px, Shift a grid step'
		..'  -  wheel scales  -  Esc done', 'darkDim', 7)
	strip.hint:SetPoint('BOTTOM', strip, 'BOTTOM', 0, 7)
	strip:SetWidth(max(width + 10, strip.hint:GetStringWidth() + 24))
	strip:SetPoint('TOP', UIParent, 'TOP', 0, -24)
	strip:Hide()
end

-- The chip ---------------------------------------------------------------------------------
local CHIP_KEY = 20

local function UpdateChip()
	local key = UI:SelectedMover()
	local handle = key and UI:MoverHandle(key)
	local wanted = UI:MoversUnlocked() and not UI:EditModeConsole() and handle and handle:IsShown()
	if not wanted then
		if chip then chip:Hide() end
		return
	end
	local point, x, y = UI:GetMoverPosition(key)
	if not point then
		if chip then chip:Hide() end
		return
	end
	local px = UI.Pixel.Px(UIParent, 1)
	local function P(value) return floor(value / px + 0.5) end
	chip.name:SetText(strupper(UI:MoverLabel(key) or key))
	chip.page:SetText(strupper(UI:MoverPageTitle(key)))
	chip.anchor:SetKeyText(point)
	chip.spot.text:SetText(format('X %d  Y %d', P(x), P(y)))
	local scale, alpha = UI:GetMoverOption(key, 'scale') or 1, UI:GetMoverOption(key, 'alpha') or 1
	chip.scale.text:SetText(alpha < 1 and format('%d%% A%d', floor(scale * 100 + 0.5), floor(alpha * 100 + 0.5))
		or format('%d%%', floor(scale * 100 + 0.5)))
	chip.hide:SetChecked(UI:GetMoverOption(key, 'hidden') and true or false)
	chip:ClearAllPoints()
	-- Above the frame in the lower half of the screen, below it in the upper half.
	local _, cy = UI:GetMoverCenter(key)
	if (cy or 0) < 0 then chip:SetPoint('BOTTOM', handle, 'TOP', 0, 6) else chip:SetPoint('TOP', handle, 'BOTTOM', 0, -6) end
	if not chip:IsShown() then
		chip:SetAlpha(0)
		chip:Show()
		Kit:FadeTo(chip, 1, 'FAST')
	end
end

local function Selected()
	local key = UI:SelectedMover()
	if key and not InCombatLockdown() then return key end
end

local function BuildChip()
	chip = Kit:Device(UIParent, {surface = 'dark', header = false, width = 300, height = 56, radius = 6})
	chip:SetFrameStrata('FULLSCREEN_DIALOG')
	if strip then chip:SetFrameLevel(strip:GetFrameLevel() + 10) end
	chip:SetClampedToScreen(true)
	chip:EnableMouse(true)
	chip.lamp = Kit:Led(chip, 4, true)
	chip.lamp:SetPoint('TOPLEFT', 10, -11)
	chip.name = Kit:Label(chip, '', 'darkInk', 8, true)
	chip.name:SetPoint('LEFT', chip.lamp, 'RIGHT', 5, 0)
	chip.page = Kit:Label(chip, '', 'darkDim', 7)
	chip.page:SetPoint('LEFT', chip.name, 'RIGHT', 6, 0)
	chip.settings = GearKey(chip, 18, function()
		local key = UI:SelectedMover()
		if key then UI:OpenMoverSettings(key) end
	end)
	chip.settings:SetPoint('TOPRIGHT', -6, -4)
	Kit:AttachTooltip(chip.settings, function() return UI:MoverPageTitle(UI:SelectedMover())..' settings' end)

	chip.anchor = Key(chip, 'Center', 74, CHIP_KEY, {onClick = function()
		local key = Selected()
		if not key then return end
		local current = UI:GetMoverPosition(key)
		local points, index = UI.MOVER_POINTS, 1
		for at, point in ipairs(points) do if point == current then index = at end end
		UI:RememberMover(key)
		UI:SetMoverAnchor(key, points[index % #points + 1])
		Kit:Play('tick', true)
	end})
	Kit:AttachTooltip(chip.anchor, 'The screen point it is measured from: click for the next')
	chip.spot = LCD(chip, 94, CHIP_KEY)
	chip.down = Key(chip, '-', 22, CHIP_KEY, {onClick = function()
		local key = Selected()
		if key then UI:StepMoverScale(key, IsShiftKeyDown() and -0.01 or -0.05) end
	end})
	chip.scale = LCD(chip, 62, CHIP_KEY)
	chip.up = Key(chip, '+', 22, CHIP_KEY, {onClick = function()
		local key = Selected()
		if key then UI:StepMoverScale(key, IsShiftKeyDown() and 0.01 or 0.05) end
	end})
	chip.hide = Key(chip, 'Hide', 48, CHIP_KEY, {toggle = true, onClick = function()
		local key = Selected()
		if key then UI:ToggleMoverHidden(key) end
	end})
	chip.reset = Key(chip, 'Reset', 50, CHIP_KEY, {onClick = function()
		local key = Selected()
		if not key then return end
		UI:ResetMover(key)
		Kit:Play('latch-up', true)
	end})
	Kit:AttachTooltip(chip.reset, 'This frame back to its own spot, scale and opacity')
	local width = Row(chip, {chip.anchor, chip.spot, {gap = 4}, chip.down, chip.scale, chip.up, {gap = 4}, chip.hide, chip.reset},
		8, -28)
	chip:SetWidth(width + 8)
	chip:Hide()
end

-- Showing them -----------------------------------------------------------------------------
UI:OnMoversChanged(function(key)
	if key == '__lock' then
		if UI:MoversUnlocked() then
			if not strip then BuildStrip() end
			if not chip then BuildChip() end
			if not strip:IsShown() then
				strip:SetAlpha(0)
				strip:Show()
				Kit:FadeTo(strip, 1, 'FAST')
			end
		else
			if strip then strip:Hide() end
			if chip then chip:Hide() end
		end
	end
	if key == '__lock' or key == '__undo' or key == nil then UpdateStrip() end
	if chip and (key == nil or key == '__lock' or key == '__select' or key == UI:SelectedMover()) then UpdateChip() end
end)
