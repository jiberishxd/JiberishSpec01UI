-- Placing frames. Every SPEC-01 frame registers here; /spec move (or the
-- hub's Layout page) shows a labelled handle over each one. Handles snap to a
-- grid and to the edges and centres of other frames (hold Shift to place
-- freely); arrow keys nudge the selected frame (Shift for 10); right-click a
-- handle to put that frame back. Unlocking is refused in combat, and a fight
-- starting locks everything again.
--
-- A frame's spot is saved as the screen point it is measured from (its anchor:
-- CENTER, an edge or a corner) and the offset of the frame's own same point
-- from it, in UIParent units: {x, y, anchor = 'BOTTOM'}. A frame anchored to
-- an edge stays on that edge when the resolution or aspect ratio changes.
-- Older saves, {x, y} with no anchor, are CENTER offsets and still read as such.
-- Each spot may also carry scale, alpha and hidden.
--
-- A docked frame (the player and target frames inside the action bar console)
-- is placed by its dock instead, and has no handle of its own.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown = CreateFrame, UIParent, InCombatLockdown
local floor, abs, max = math.floor, math.abs, math.max

-- defaults:begin
UI:RegisterDefaults('layout', {grid = 8, snap = true, preset = 'console', resolution = 'auto', density = 'comfortable',
	suggest = true, lastHeight = false, custom = {}})
-- defaults:end

local function IsSecret(value) return issecretvalue and issecretvalue(value) end
local function DB() return UI.db.layout end

local movers, order = {}, {}
local handles, grid = {}, nil
local unlocked, selected = false, nil
local MAGNET = 8
local listeners = {}

local POINTS = {'TOPLEFT', 'TOP', 'TOPRIGHT', 'LEFT', 'CENTER', 'RIGHT', 'BOTTOMLEFT', 'BOTTOM', 'BOTTOMRIGHT'}
UI.MOVER_POINTS = POINTS

-- callback(key): key is a mover's key after it moved, '__lock' when handles
-- are shown or hidden, '__select' when the selection changed, nil for all.
function UI:OnMoversChanged(callback) listeners[#listeners + 1] = callback end
local function Changed(key)
	for _, callback in ipairs(listeners) do UI:Safe(callback, key) end
end

local function Saved(key)
	local saved = UI.db.movers[key]
	return type(saved) == 'table' and saved or nil
end

local function Round(value) return floor(value * 100 + 0.5) / 100 end

-- Geometry ----------------------------------------------------------------------
-- The offset of a point from the centre of a width x height rectangle.
local function PointOffset(point, width, height)
	local x, y = 0, 0
	if point:find('LEFT') then x = -width / 2 elseif point:find('RIGHT') then x = width / 2 end
	if point:find('TOP') then y = height / 2 elseif point:find('BOTTOM') then y = -height / 2 end
	return x, y
end

local function Ratio(frame) return frame:GetEffectiveScale() / UIParent:GetEffectiveScale() end

-- The frame's size in UIParent units.
local function Size(mover)
	local frame = mover.frame
	local width, height = frame:GetSize()
	if IsSecret(width) or IsSecret(height) or not width or not height then return 0, 0 end
	local ratio = Ratio(frame)
	return width * ratio, height * ratio
end

-- The anchor, x and y the frame is placed by: its saved spot, else its default.
local function Position(mover)
	local saved = Saved(mover.key)
	if saved and saved[1] then return saved.anchor or 'CENTER', saved[1], saved[2] or 0 end
	local default = mover.default or {}
	return default[1] or 'CENTER', default[2] or 0, default[3] or 0
end

-- Where a spot puts the frame's centre, as an offset from the screen centre.
local function CenterOf(mover, point, x, y)
	local width, height = UIParent:GetSize()
	local frameWidth, frameHeight = Size(mover)
	local ax, ay = PointOffset(point, width, height)
	local px, py = PointOffset(point, frameWidth, frameHeight)
	return ax + x - px, ay + y - py
end

local function Center(mover) return CenterOf(mover, Position(mover)) end

-- The spot, measured from a given anchor, that puts the frame's centre at cx, cy.
local function FromCenter(mover, point, cx, cy)
	local width, height = UIParent:GetSize()
	local frameWidth, frameHeight = Size(mover)
	local ax, ay = PointOffset(point, width, height)
	local px, py = PointOffset(point, frameWidth, frameHeight)
	return cx - ax + px, cy - ay + py
end

-- The anchor a new save is measured from: the frame's saved anchor, else the
-- point of its default spot, so frames keep to the edge they were designed for.
local function Anchor(mover)
	local saved = Saved(mover.key)
	if saved and saved.anchor then return saved.anchor end
	return (mover.default and mover.default[1]) or 'CENTER'
end

local function Store(key, point, x, y)
	local saved = Saved(key) or {}
	saved[1], saved[2], saved.anchor = Round(x), Round(y), point
	UI.db.movers[key] = saved
end

-- Scale, alpha and hidden ---------------------------------------------------------
-- Applied through the frame itself, while placing it (so protected frames only
-- out of combat). A saved scale multiplies the scale the frame's module sets;
-- clearing it gives the module's scale back. Hidden is alpha 0 with the mouse
-- off; one of our own plain frames is also kept hidden while it is set.
local keepHidden = setmetatable({}, {__mode = 'k'})

-- The module's own scale: the frame's scale, unless it is still the one we set.
local function ModuleScale(mover)
	local current = mover.frame:GetScale()
	if mover.setScale and mover.baseScale and abs(current - mover.setScale) < 0.0005 then return mover.baseScale end
	return current
end

local function ApplyScale(mover)
	local frame, saved = mover.frame, Saved(mover.key)
	local multiplier = saved and saved.scale
	local base = ModuleScale(mover)
	mover.baseScale = base
	if multiplier and abs(multiplier - 1) > 0.0005 then
		local target = base * multiplier
		if abs(frame:GetScale() - target) > 0.0005 then frame:SetScale(target) end
		mover.setScale = target
	elseif mover.setScale then
		if abs(frame:GetScale() - base) > 0.0005 then frame:SetScale(base) end
		mover.setScale = nil
	end
end

local function ApplyLook(mover)
	local frame, saved = mover.frame, Saved(mover.key)
	ApplyScale(mover)
	local hidden, alpha = saved and saved.hidden, saved and saved.alpha
	if hidden then
		frame:SetAlpha(0)
		if not mover.mouseOff then
			mover.mouseWas = frame:IsMouseEnabled()
			frame:EnableMouse(false)
			mover.mouseOff = true
		end
		if not frame:IsProtected() then
			if not keepHidden[frame] then
				keepHidden[frame] = {wasShown = frame:IsShown()}
				if not mover.hideHooked then
					mover.hideHooked = true
					frame:HookScript('OnShow', function(self)
						if keepHidden[self] then self:Hide() end
					end)
				end
			end
			frame:Hide()
		end
	else
		if mover.mouseOff then
			frame:EnableMouse(mover.mouseWas and true or false)
			mover.mouseOff, mover.mouseWas = nil, nil
		end
		local held = keepHidden[frame]
		if held then
			keepHidden[frame] = nil
			if held.wasShown then frame:Show() end
		end
		if alpha then frame:SetAlpha(alpha)
		elseif mover.alphaSet then frame:SetAlpha(1) end
	end
	mover.alphaSet = (hidden or alpha) and true or nil
end

-- Registering and placing -----------------------------------------------------------
-- default: {point, x, y}: the frame's point that far from the same point of UIParent.
function UI:RegisterMover(frame, key, label, default)
	local mover = movers[key]
	if mover then
		mover.frame, mover.label, mover.default = frame, label, default
	else
		mover = {frame = frame, key = key, label = label, default = default}
		movers[key] = mover
		order[#order + 1] = key
	end
	self:PlaceMover(key)
	return mover
end

function UI:PlaceMover(key)
	local mover = movers[key]
	if not mover then return end
	local frame = mover.frame
	local function Place()
		ApplyLook(mover)
		if mover.dock then
			frame:ClearAllPoints()
			mover.dock(frame)
		else
			local point, x, y = Position(mover)
			local ratio = Ratio(frame)
			frame:ClearAllPoints()
			frame:SetPoint(point, UIParent, point, x / ratio, y / ratio)
			if frame.SetUserPlaced and frame:IsMovable() then frame:SetUserPlaced(false) end
		end
		Changed(key)
	end
	if frame:IsProtected() and InCombatLockdown() then
		return self:AfterCombat(Place, 'mover.'..key)
	end
	Place()
end

-- place(frame): anchors the frame inside its dock; nil gives it back its own spot.
function UI:DockMover(key, place)
	local mover = movers[key]
	if not mover then return end
	mover.dock = place
	if handles[key] then handles[key]:SetShown(unlocked and not place) end
	self:PlaceMover(key)
end

function UI:MoverDocked(key) return movers[key] and movers[key].dock ~= nil end

-- For modules that size their own frames: set the frame's own scale through
-- here, and the frame's saved multiplier is kept on top of it. frame: used
-- directly when it has not been registered yet. keepPoints: rescale without
-- re-placing (a frame its module anchors itself). Out of combat for protected frames.
function UI:SetMoverBaseScale(key, scale, frame, keepPoints)
	local mover = movers[key]
	if not mover then
		if frame and frame:GetScale() ~= scale then frame:SetScale(scale) end
		return
	end
	mover.baseScale, mover.setScale = scale, nil
	if mover.frame:GetScale() ~= scale then mover.frame:SetScale(scale) end
	ApplyScale(mover)
	if not keepPoints then self:PlaceMover(key) end
end

function UI:PlaceAllMovers()
	for _, key in ipairs(order) do self:PlaceMover(key) end
end

-- Undo -------------------------------------------------------------------------------
-- Every change made while placing is undoable (Ctrl+Z or the toolbar's Undo):
-- a snapshot of the frame's saved spot is taken before the change. Changes of
-- one kind to one frame within a second (a wheel spin, held arrow keys) share
-- one snapshot.
local undo = {}
local UNDO_LIMIT = 60

local function Copy(saved)
	if type(saved) ~= 'table' then return false end
	local copy = {}
	for field, value in pairs(saved) do copy[field] = value end
	return copy
end

local function Remember(key, kind)
	local top = undo[#undo]
	local now = GetTime()
	if kind and top and top.key == key and top.kind == kind and now - top.time < 1 then
		top.time = now
		return
	end
	undo[#undo + 1] = {key = key, kind = kind, time = now, saved = Copy(UI.db.movers[key])}
	if #undo > UNDO_LIMIT then table.remove(undo, 1) end
	Changed('__undo')
end

local function RememberAll()
	local all = {}
	for key, saved in pairs(UI.db.movers) do all[key] = Copy(saved) end
	undo[#undo + 1] = {all = all, time = GetTime()}
	if #undo > UNDO_LIMIT then table.remove(undo, 1) end
	Changed('__undo')
end

-- One undo step covering every saved spot (a layout applied in one go).
function UI:SnapshotMovers() RememberAll() end

function UI:CanUndoMover() return #undo > 0 end

function UI:UndoMover()
	if InCombatLockdown() then return end
	local step = table.remove(undo)
	if not step then Kit:Play('error', true) return end
	if step.all then
		wipe(self.db.movers)
		for key, saved in pairs(step.all) do self.db.movers[key] = saved or nil end
		self:PlaceAllMovers()
	else
		self.db.movers[step.key] = step.saved or nil
		self:PlaceMover(step.key)
	end
	Kit:Play('latch-up', true)
	Changed('__undo')
end

function UI:ResetMovers()
	if InCombatLockdown() then return self:Print('Frames can be reset once you leave combat.') end
	RememberAll()
	wipe(self.db.movers)
	self:PlaceAllMovers()
	self:Print('Frame positions reset.')
end

function UI:ResetMover(key)
	Remember(key)
	self.db.movers[key] = nil
	self:PlaceMover(key)
end

-- For the hub's Layout page and the presets -----------------------------------------
-- An ordered list of {key, label, frame, docked}.
function UI:GetMovers()
	local list = {}
	for _, key in ipairs(order) do
		local mover = movers[key]
		list[#list + 1] = {key = key, label = mover.label, frame = mover.frame, docked = mover.dock ~= nil}
	end
	return list
end

function UI:HasMover(key) return movers[key] ~= nil end

-- anchor, x, y: the frame's spot (saved, else default).
function UI:GetMoverPosition(key)
	local mover = movers[key]
	if mover then return Position(mover) end
	local saved = Saved(key)
	if saved and saved[1] then return saved.anchor or 'CENTER', saved[1], saved[2] or 0 end
end

function UI:GetMoverDefault(key)
	local mover = movers[key]
	local default = mover and mover.default
	if default then return default[1] or 'CENTER', default[2] or 0, default[3] or 0 end
end

-- Save a spot and place the frame. A frame not registered yet (a module that
-- builds it after a reload) gets the spot saved for when it does.
function UI:SetMoverPosition(key, anchor, x, y)
	local mover = movers[key]
	if not mover then
		Store(key, anchor or 'CENTER', x or 0, y or 0)
		return
	end
	anchor = anchor or Anchor(mover)
	if x == nil or y == nil then
		local cx, cy = Center(mover)
		x, y = FromCenter(mover, anchor, cx, cy)
	end
	Store(key, anchor, x, y)
	self:PlaceMover(key)
end

-- Measure the frame from another anchor without moving it.
function UI:SetMoverAnchor(key, anchor)
	local mover = movers[key]
	if not mover then return end
	local cx, cy = Center(mover)
	Store(key, anchor, FromCenter(mover, anchor, cx, cy))
	self:PlaceMover(key)
end

-- The frame's centre as an offset from the screen centre, in UIParent units.
function UI:GetMoverCenter(key)
	local mover = movers[key]
	if mover then return Center(mover) end
end

function UI:SetMoverCenter(key, cx, cy)
	local mover = movers[key]
	if not mover then return end
	local anchor = Anchor(mover)
	Store(key, anchor, FromCenter(mover, anchor, cx, cy))
	self:PlaceMover(key)
end

-- width, height in UIParent units.
function UI:GetMoverSize(key)
	local mover = movers[key]
	if mover then return Size(mover) end
end

-- field: 'scale', 'alpha' or 'hidden'; nil clears it.
function UI:SetMoverOption(key, field, value, quiet)
	local mover = movers[key]
	local saved = Saved(key)
	if not saved and value == nil then return end
	if not quiet and saved and saved[field] == value then return end
	if not quiet then Remember(key, field) end
	if not saved then
		if value == nil then return end
		if mover then
			local anchor = Anchor(mover)
			local cx, cy = Center(mover)
			Store(key, anchor, FromCenter(mover, anchor, cx, cy))
		else
			Store(key, 'CENTER', 0, 0)
		end
		saved = Saved(key)
	end
	saved[field] = value
	self:PlaceMover(key)
end

-- The opacity unlock mode set for a frame (0 when hidden), for anything else
-- that fades it (the idle fade multiplies by this).
local byFrame = setmetatable({}, {__mode = 'k'})
function UI:MoverAlphaFor(frame)
	local key = byFrame[frame]
	if not key then
		for moverKey, mover in pairs(movers) do
			if mover.frame == frame then key = moverKey; byFrame[frame] = key break end
		end
	end
	local saved = key and Saved(key)
	if not saved then return 1 end
	if saved.hidden then return 0 end
	return saved.alpha or 1
end

function UI:GetMoverOption(key, field)
	local saved = Saved(key)
	return saved and saved[field]
end

-- Size and opacity, for unlock mode's grip, wheel and inspector.
local function Clamp(value, low, high) return value < low and low or (value > high and high or value) end

-- quiet: the caller already took an undo snapshot (a grip drag).
function UI:SetMoverScale(key, scale, quiet)
	scale = Clamp(floor(scale * 100 + 0.5) / 100, 0.3, 3)
	self:SetMoverOption(key, 'scale', abs(scale - 1) < 0.005 and nil or scale, quiet)
end

function UI:StepMoverScale(key, delta)
	self:SetMoverScale(key, (self:GetMoverOption(key, 'scale') or 1) + delta)
	Kit:Play('tick', true)
end

function UI:StepMoverAlpha(key, delta)
	local alpha = Clamp(floor(((self:GetMoverOption(key, 'alpha') or 1) + delta) * 100 + 0.5) / 100, 0.05, 1)
	self:SetMoverOption(key, 'alpha', alpha < 1 and alpha or nil)
	Kit:Play('tick', true)
end

function UI:ToggleMoverHidden(key)
	self:SetMoverOption(key, 'hidden', not self:GetMoverOption(key, 'hidden') or nil)
	Kit:Play(self:GetMoverOption(key, 'hidden') and 'latch-down' or 'latch-up', true)
end

-- Put a frame back where its module wants it, keeping nothing of what was set.
function UI:ResetMoverLook(key)
	local saved = Saved(key)
	if not saved then return end
	Remember(key)
	saved.scale, saved.alpha, saved.hidden = nil, nil, nil
	self:PlaceMover(key)
end

function UI:SelectMover(key)
	if selected == key then return end
	selected = key
	for handleKey, handle in pairs(handles) do
		Kit:Tint(handle.fill, 'lamp', handleKey == key and 0.45 or 0.22)
	end
	Changed('__select')
end

function UI:SelectedMover() return selected end

-- Snapping --------------------------------------------------------------------------
local function GridSize() return max(DB().grid or 8, 1) end

local function Rect(mover, cx, cy)
	local width, height = Size(mover)
	return cx - width / 2, cy - height / 2, cx + width / 2, cy + height / 2
end

local function Snap(mover, cx, cy)
	if IsShiftKeyDown() or not DB().snap then return cx, cy end
	local step = GridSize()
	cx, cy = floor(cx / step + 0.5) * step, floor(cy / step + 0.5) * step
	local left, bottom, right, top = Rect(mover, cx, cy)
	local bestX, bestY = MAGNET + 1, MAGNET + 1
	local dx, dy = 0, 0
	for _, key in ipairs(order) do
		local other = movers[key]
		if other ~= mover and not other.dock and other.frame:IsVisible() then
			local ox, oy = Center(other)
			local l, b, r, t = Rect(other, ox, oy)
			-- Edges against edges (touching or aligned) and centre against centre.
			for _, pair in ipairs({{left, r}, {left, l}, {right, l}, {right, r}, {cx, ox}}) do
				local gap = pair[2] - pair[1]
				if abs(gap) < bestX then bestX, dx = abs(gap), gap end
			end
			for _, pair in ipairs({{bottom, t}, {bottom, b}, {top, b}, {top, t}, {cy, oy}}) do
				local gap = pair[2] - pair[1]
				if abs(gap) < bestY then bestY, dy = abs(gap), gap end
			end
		end
	end
	if bestX <= MAGNET then cx = cx + dx end
	if bestY <= MAGNET then cy = cy + dy end
	return cx, cy
end

function UI:SnapMover(key, cx, cy)
	local mover = movers[key]
	if not mover then return cx, cy end
	return Snap(mover, cx, cy)
end

-- Nudging ---------------------------------------------------------------------------
function UI:NudgeMover(key, dx, dy)
	local mover = movers[key]
	if not mover or mover.dock or InCombatLockdown() then return end
	local point, x, y = Position(mover)
	Remember(key, 'nudge')
	Store(key, point, x + dx, y + dy)
	self:PlaceMover(key)
	Kit:Play('tick', true)
end

-- Arrow keys nudge the selected frame while handles are shown, or while the
-- hub's Layout page asks for them (UI:SetMoverKeys('hub', true)). Only arrow
-- keys are kept; every other key goes on to the game.
local keySources = {}
local keyboard = CreateFrame('Frame', nil, UIParent)
keyboard:Hide()
local ARROWS = {LEFT = {-1, 0}, RIGHT = {1, 0}, UP = {0, 1}, DOWN = {0, -1}}

local function UpdateKeyboard()
	if InCombatLockdown() then return end
	local wanted = unlocked or (selected ~= nil and next(keySources) ~= nil)
	if wanted then
		keyboard:Show()
		keyboard:EnableKeyboard(true)
		keyboard:SetPropagateKeyboardInput(true)
	elseif keyboard:IsShown() then
		keyboard:EnableKeyboard(false)
		keyboard:Hide()
	end
end

keyboard:SetScript('OnKeyDown', function(self, key)
	if InCombatLockdown() then return end
	-- Unlock mode's own keys: Escape locks, Ctrl+Z undoes.
	if unlocked and key == 'ESCAPE' then
		self:SetPropagateKeyboardInput(false)
		UI:ToggleMovers(true)
		return
	end
	if unlocked and key == 'Z' and IsControlKeyDown() then
		self:SetPropagateKeyboardInput(false)
		UI:UndoMover()
		return
	end
	local arrow = ARROWS[key]
	if not arrow or not selected then
		self:SetPropagateKeyboardInput(true)
		return
	end
	self:SetPropagateKeyboardInput(false)
	local step = IsShiftKeyDown() and 10 or 1
	UI:NudgeMover(selected, arrow[1] * step, arrow[2] * step)
end)

function UI:SetMoverKeys(source, on)
	keySources[source] = on and true or nil
	UpdateKeyboard()
end

-- Handles --------------------------------------------------------------------------
-- One grid frame; its lines are reused when the grid is redrawn.
local gridLines, gridDrawn = {}, false
local function DrawGrid()
	local width, height = UIParent:GetSize()
	local step = max(16, GridSize() * 4)
	local used = 0
	local function Line(alpha, w, h, x, y)
		used = used + 1
		local line = gridLines[used]
		if not line then
			line = grid:CreateTexture(nil, 'BACKGROUND')
			gridLines[used] = line
		end
		line:SetColorTexture(1, 1, 1, alpha)
		line:SetSize(w, h)
		line:ClearAllPoints()
		line:SetPoint('CENTER', x, y)
		line:Show()
	end
	for x = 0, width / 2, step do
		for _, sign in ipairs(x == 0 and {1} or {1, -1}) do Line(x == 0 and 0.18 or 0.05, 1, height, sign * x, 0) end
	end
	for y = 0, height / 2, step do
		for _, sign in ipairs(y == 0 and {1} or {1, -1}) do Line(y == 0 and 0.18 or 0.05, width, 1, 0, sign * y) end
	end
	for index = used + 1, #gridLines do gridLines[index]:Hide() end
	gridDrawn = true
end

local function Grid()
	if not grid then
		grid = CreateFrame('Frame', nil, UIParent)
		grid:SetAllPoints()
		grid:SetFrameStrata('BACKGROUND')
		grid:EnableMouse(false)
		grid:Hide()
	end
	if not gridDrawn then DrawGrid() end
	return grid
end

-- Redraw the grid, after the grid size or the screen changed.
function UI:RefreshMoverGrid()
	gridDrawn = false
	if grid and grid:IsShown() then DrawGrid() end
end

-- A small LCD by the selected handle: its anchor and offsets.
local readout
local function Readout()
	if readout then return readout end
	readout = Kit:LCDPanel(UIParent, {radius = 4})
	readout:SetFrameStrata('DIALOG')
	readout:SetSize(170, 20)
	readout:EnableMouse(false)
	readout.text = Kit:Text(readout, '', 9, 'lcdInk', true)
	readout.text:SetPoint('CENTER')
	readout:Hide()
	return readout
end

local function UpdateReadout()
	local mover = selected and movers[selected]
	local handle = mover and handles[selected]
	if not (unlocked and handle and handle:IsShown()) then
		if readout then readout:Hide() end
		return
	end
	local panel = Readout()
	local point, x, y = Position(mover)
	local saved = Saved(mover.key)
	local scale, alpha = saved and saved.scale or 1, saved and saved.alpha or 1
	panel.text:SetText(format('%s  X %d  Y %d  %d%%%s', point, floor(x + 0.5), floor(y + 0.5), floor(scale * 100 + 0.5),
		saved and saved.hidden and '  HIDDEN' or (alpha < 1 and format('  A %d%%', floor(alpha * 100 + 0.5)) or '')))
	panel:SetWidth(panel.text:GetStringWidth() + 16)
	panel:ClearAllPoints()
	local _, cy = Center(mover)
	-- Above the frame in the lower half of the screen, below it in the upper half.
	if cy < 0 then panel:SetPoint('BOTTOM', handle, 'TOP', 0, 4) else panel:SetPoint('TOP', handle, 'BOTTOM', 0, -4) end
	panel:Show()
end

UI:OnMoversChanged(function(key)
	if key == nil or key == selected or key == '__select' or key == '__lock' then UpdateReadout() end
	if key == '__select' or key == '__lock' then UpdateKeyboard() end
end)

local function Handle(mover)
	local handle = handles[mover.key]
	if handle then return handle end
	handle = CreateFrame('Button', nil, UIParent)
	handle:SetFrameStrata('DIALOG')
	handle:SetAllPoints(mover.frame)
	handle:RegisterForClicks('RightButtonUp')
	handle.fill = handle:CreateTexture(nil, 'BACKGROUND')
	handle.fill:SetAllPoints()
	handle.fill:SetColorTexture(1, 1, 1, 1)
	Kit:Tint(handle.fill, 'lamp', mover.key == selected and 0.45 or 0.22)
	handle.edge = Kit:Shell(handle, {surface = 'glass', radius = 4, alpha = 0, shadow = false})
	handle.label = Kit:Label(handle, mover.label, 'white', 9, true)
	handle.label:SetShadowOffset(1, -1)
	handle.label:SetPoint('CENTER')
	handle.lamp = Kit:Led(handle, 5, true)
	handle.lamp:SetPoint('RIGHT', handle.label, 'LEFT', -5, 0)
	handle:SetScript('OnEnter', function(self) Kit:Tint(self.fill, 'lamp', 0.4) end)
	handle:SetScript('OnLeave', function(self) Kit:Tint(self.fill, 'lamp', mover.key == selected and 0.45 or 0.22) end)
	handle:SetScript('OnClick', function()
		if InCombatLockdown() then return end
		UI:ResetMover(mover.key)
		Kit:Play('latch-up', true)
	end)
	-- Wheel: scale (Shift for fine steps); Ctrl+wheel: opacity.
	handle:EnableMouseWheel(true)
	handle:SetScript('OnMouseWheel', function(_, delta)
		if InCombatLockdown() then return end
		UI:SelectMover(mover.key)
		if IsControlKeyDown() then
			UI:StepMoverAlpha(mover.key, delta * 0.05)
		else
			UI:StepMoverScale(mover.key, delta * (IsShiftKeyDown() and 0.01 or 0.05))
		end
	end)
	-- A grip in the bottom-right corner: drag it to resize the frame.
	local grip = CreateFrame('Button', nil, handle)
	grip:SetSize(14, 14)
	grip:SetPoint('BOTTOMRIGHT', -1, 1)
	grip:SetFrameLevel(handle:GetFrameLevel() + 2)
	for index = 1, 3 do
		local line = grip:CreateTexture(nil, 'OVERLAY')
		line:SetColorTexture(1, 1, 1, 0.75)
		line:SetSize(index * 4, UI.Pixel.Px(grip, 1))
		line:SetPoint('BOTTOMRIGHT', -1, 1 + (index - 1) * 3)
	end
	grip:SetScript('OnEnter', function() Kit:ShowTooltip(grip, 'Drag to resize. Wheel over the frame: scale; Ctrl+wheel: opacity.') end)
	grip:SetScript('OnLeave', function() Kit:HideTooltip() end)
	grip:SetScript('OnMouseDown', function(self, button)
		if button ~= 'LeftButton' or InCombatLockdown() then return end
		UI:SelectMover(mover.key)
		local uiScale = UIParent:GetEffectiveScale()
		local startX, startY = GetCursorPosition()
		local width, height = Size(mover)
		local saved = Saved(mover.key)
		local startScale = saved and saved.scale or 1
		if width <= 0 or height <= 0 then return end
		Kit:Play('down', true)
		self.remembered = nil
		self:SetScript('OnUpdate', function()
			if InCombatLockdown() then self:SetScript('OnUpdate', nil) return end
			local x, y = GetCursorPosition()
			local dx, dy = (x - startX) / uiScale, (startY - y) / uiScale
			local factor = ((width + dx) / width + (height + dy) / height) / 2
			local scale = floor(max(0.3, math.min(3, startScale * factor)) * 100 + 0.5) / 100
			local now = Saved(mover.key)
			if (now and now.scale or 1) ~= scale then
				if not self.remembered then self.remembered = true; Remember(mover.key) end
				UI:SetMoverScale(mover.key, scale, true)
			end
		end)
	end)
	grip:SetScript('OnMouseUp', function(self)
		self:SetScript('OnUpdate', nil)
		Kit:Play('up', true)
	end)
	-- Locking (Esc, a fight) hides the handle before any mouse-up arrives.
	grip:SetScript('OnHide', function(self) self:SetScript('OnUpdate', nil) end)
	handle.grip = grip
	handle:SetScript('OnMouseDown', function(self, button)
		if button ~= 'LeftButton' or InCombatLockdown() then return end
		UI:SelectMover(mover.key)
		local scale = UIParent:GetEffectiveScale()
		local startX, startY = GetCursorPosition()
		local baseX, baseY = Center(mover)
		Kit:Play('down', true)
		local remembered = false
		self:SetScript('OnUpdate', function()
			if InCombatLockdown() then return end
			local x, y = GetCursorPosition()
			local cx, cy = Snap(mover, baseX + (x - startX) / scale, baseY + (y - startY) / scale)
			local nowX, nowY = Center(mover)
			if abs(nowX - cx) > 0.01 or abs(nowY - cy) > 0.01 then
				if not remembered then remembered = true; Remember(mover.key) end
				UI:SetMoverCenter(mover.key, cx, cy)
			end
		end)
	end)
	handle:SetScript('OnMouseUp', function(self, button)
		if button ~= 'LeftButton' then return end
		self:SetScript('OnUpdate', nil)
		Kit:Play('up', true)
	end)
	handles[mover.key] = handle
	return handle
end

-- Unlock mode's console ------------------------------------------------------------------
-- A UM-1 device at the top of the screen while frames are unlocked: grid, snap
-- and grid size, undo, reset and lock on the first row; the selected frame's
-- scale, opacity, anchor and visibility on the second. Drag its housing to move it.
local console
local GRIDS = {4, 8, 16, 32}

local function Row(parent, items, y)
	local x = 10
	for _, item in ipairs(items) do
		if item.gap then
			x = x + item.gap
		else
			item.widget:ClearAllPoints()
			item.widget:SetPoint('TOPLEFT', parent, 'TOPLEFT', x, y)
			x = x + item.widget:GetWidth() + 4
		end
	end
	return x + 6
end

local function KeyOf(parent, text, width, opts)
	opts = opts or {}
	opts.text, opts.width, opts.height = text, width, 24
	return Kit:Key(parent, opts)
end

local function LCDBox(parent, width)
	local panel = Kit:LCDPanel(parent, {radius = 3})
	panel:SetSize(width, 24)
	panel.text = Kit:Text(panel, '', 10, 'lcdInk', true)
	panel.text:SetPoint('CENTER')
	return panel
end

local function UpdateConsole()
	if not (console and console:IsShown()) then return end
	local db = DB()
	console.grid:SetChecked(grid and grid:IsShown())
	console.snap:SetChecked(db.snap and true or false)
	console.size:SetKeyText(format('Grid %d', GridSize()))
	console.undo:SetKeyEnabled(#undo > 0)
	local mover = selected and movers[selected]
	local on = mover ~= nil and not mover.dock
	for _, widget in ipairs(console.frameKeys) do widget:SetKeyEnabled(on) end
	if not on then
		console.name:SetText('Click a frame to select it')
		console.scale.text:SetText('---')
		console.alpha.text:SetText('---')
		console.hide:SetChecked(false)
		console.anchor:SetKeyText('Anchor')
		return
	end
	local saved = Saved(selected)
	console.name:SetText(strupper(mover.label or selected))
	console.scale.text:SetText(format('%d%%', floor(((saved and saved.scale) or 1) * 100 + 0.5)))
	console.alpha.text:SetText(format('%d%%', floor(((saved and saved.alpha) or 1) * 100 + 0.5)))
	console.hide:SetChecked(saved and saved.hidden and true or false)
	console.anchor:SetKeyText(Position(mover))
end

local function Console()
	if console then return console end
	console = Kit:Device(UIParent, {surface = 'dark', model = 'UM-1', title = 'Unlock mode', width = 200, height = 96, radius = 8})
	console:SetFrameStrata('FULLSCREEN_DIALOG')
	console:SetClampedToScreen(true)
	console:SetMovable(true)
	console:EnableMouse(true)
	console:RegisterForDrag('LeftButton')
	console:SetScript('OnDragStart', function(self) self:StartMoving() end)
	console:SetScript('OnDragStop', function(self) self:StopMovingOrSizing() end)
	Kit:SetLed(console.lamp, true)

	console.grid = KeyOf(console, 'Grid', 58, {toggle = true, onClick = function(key)
		Grid():SetShown(key.checked)
	end})
	console.snap = KeyOf(console, 'Snap', 58, {toggle = true, onClick = function(key)
		DB().snap = key.checked
	end})
	console.size = KeyOf(console, 'Grid 8', 70, {onClick = function()
		local index = 1
		for at, value in ipairs(GRIDS) do if value == GridSize() then index = at end end
		DB().grid = GRIDS[index % #GRIDS + 1]
		UI:RefreshMoverGrid()
		UpdateConsole()
	end})
	console.undo = KeyOf(console, 'Undo', 58, {onClick = function() UI:UndoMover() end})
	console.resetAll = KeyOf(console, 'Reset all', 80, {onClick = function()
		Kit:AlertDialog({title = 'Reset every frame', confirm = 'Reset',
			text = 'Every SPEC-01 frame goes back to its default spot, scale and opacity. Undo can bring them back.',
			onConfirm = function() UI:ResetMovers() end})
	end})
	console.layout = KeyOf(console, 'Layouts', 70, {onClick = function() UI:ToggleHub('layout', true) end})
	console.lock = KeyOf(console, 'Lock', 64, {tone = 'primary', onClick = function() UI:ToggleMovers(true) end})
	local width = Row(console, {{widget = console.grid}, {widget = console.snap}, {widget = console.size}, {gap = 8},
		{widget = console.undo}, {widget = console.resetAll}, {widget = console.layout}, {gap = 8}, {widget = console.lock}}, -26)

	-- The selected frame.
	console.name = Kit:Label(console, '', 'darkDim', 8, true)
	console.scaleDown = KeyOf(console, '-', 26, {onClick = function() UI:StepMoverScale(selected, -0.05) end})
	console.scale = LCDBox(console, 52)
	console.scaleUp = KeyOf(console, '+', 26, {onClick = function() UI:StepMoverScale(selected, 0.05) end})
	console.alphaDown = KeyOf(console, '-', 26, {onClick = function() UI:StepMoverAlpha(selected, -0.1) end})
	console.alpha = LCDBox(console, 52)
	console.alphaUp = KeyOf(console, '+', 26, {onClick = function() UI:StepMoverAlpha(selected, 0.1) end})
	console.anchor = KeyOf(console, 'Anchor', 96, {onClick = function()
		local mover = movers[selected]
		if not mover then return end
		local current, index = Position(mover), 1
		for at, point in ipairs(POINTS) do if point == current then index = at end end
		Remember(selected)
		UI:SetMoverAnchor(selected, POINTS[index % #POINTS + 1])
		Kit:Play('tick', true)
	end})
	console.hide = KeyOf(console, 'Hide', 58, {toggle = true, onClick = function() UI:ToggleMoverHidden(selected) end})
	console.reset = KeyOf(console, 'Reset', 58, {onClick = function()
		UI:ResetMover(selected)
		Kit:Play('latch-up', true)
	end})
	console.frameKeys = {console.scaleDown, console.scaleUp, console.alphaDown, console.alphaUp, console.anchor,
		console.hide, console.reset}
	console.scaleLabel = Kit:Label(console, 'Scale', 'darkDim', 8, true)
	console.alphaLabel = Kit:Label(console, 'Opacity', 'darkDim', 8, true)
	Row(console, {{widget = console.scaleDown}, {widget = console.scale}, {widget = console.scaleUp}, {gap = 10},
		{widget = console.alphaDown}, {widget = console.alpha}, {widget = console.alphaUp}, {gap = 10},
		{widget = console.anchor}, {widget = console.hide}, {widget = console.reset}}, -70)
	console.name:SetPoint('BOTTOMLEFT', console.scaleDown, 'TOPLEFT', 0, 4)
	console.scaleLabel:SetPoint('BOTTOM', console.scale, 'TOP', 0, 4)
	console.alphaLabel:SetPoint('BOTTOM', console.alpha, 'TOP', 0, 4)
	console.hint = Kit:Label(console, 'Drag frames  -  grip resizes  -  wheel scales  -  arrows nudge  -  Ctrl+Z undo  -  Esc locks', 'darkDim', 7)
	console.hint:SetPoint('BOTTOM', console, 'BOTTOM', 0, 7)
	console:SetSize(width, 112)
	console:SetPoint('TOP', UIParent, 'TOP', 0, -24)
	console:Hide()
	return console
end

UI:OnMoversChanged(function() UpdateConsole() end)

function UI:ToggleMovers(lock)
	if lock == nil then lock = unlocked end
	if not lock and InCombatLockdown() then return self:Print('Frames can be moved once you leave combat.') end
	unlocked = not lock
	Grid():SetShown(unlocked)
	for _, key in ipairs(order) do
		local mover = movers[key]
		local handle = Handle(mover)
		handle:SetShown(unlocked and not mover.dock)
		if not unlocked then handle:SetScript('OnUpdate', nil) end
		if mover.frame.SetPreview then UI:Safe(mover.frame.SetPreview, mover.frame, unlocked) end
	end
	Kit:Play(unlocked and 'latch-down' or 'latch-up', true)
	if unlocked then
		local panel = Console()
		panel:SetAlpha(0)
		panel:Show()
		Kit:FadeTo(panel, 1, 'FAST')
	elseif console then
		console:Hide()
	end
	Changed('__lock')
end

function UI:MoversUnlocked() return unlocked end

-- Defaults and edge anchors depend on the screen's size in UI units, so
-- re-place everything whenever the UI scale or resolution changes, and redraw the grid.
UI.Pixel.OnChange(function()
	UI:PlaceAllMovers()
	UI:RefreshMoverGrid()
end)

local driver = CreateFrame('Frame')
driver:RegisterEvent('PLAYER_REGEN_DISABLED')
driver:RegisterEvent('PLAYER_REGEN_ENABLED')
driver:SetScript('OnEvent', function(_, event)
	if event == 'PLAYER_REGEN_ENABLED' then return UpdateKeyboard() end
	-- Lockdown starts after this event, so the keyboard can still be let go here;
	-- first, so nothing below can leave it holding keys through the fight.
	keyboard:SetPropagateKeyboardInput(true)
	keyboard:EnableKeyboard(false)
	keyboard:Hide()
	if unlocked then UI:Safe(UI.ToggleMovers, UI, true) end
end)
