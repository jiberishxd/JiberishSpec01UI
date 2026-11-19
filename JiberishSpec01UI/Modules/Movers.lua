-- Placing frames, and edit mode. Every SPEC-01 frame registers here. Edit
-- mode (UI:EditMode; /spec edit, /spec move, unlock, the unlock key binding)
-- shows a glass handle over each one: its printed legend, a lamp lit in the
-- key color while selected, and a settings key (the gear) that opens the
-- frame's own hub page (right-clicking the handle does the same). Handles
-- snap to a grid of whole screen pixels (1, 2, 4 or 8, as in the console
-- editor) and to the edges and centres of other frames and the screen's
-- centre lines, with hairline guides (hold Shift to place freely); arrow keys
-- nudge the selected frame one pixel (Shift: one grid step); the wheel scales
-- it. Clicking the console's handle opens the console editor in place.
-- Modules/EditMode.lua draws the header strip and the selected frame's
-- inspector chip. Unlocking is refused in combat, and a fight starting leaves
-- edit mode (every change is already saved).
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

-- grid: the handles' grid in screen pixels (1, 2, 4 or 8).
-- defaults:begin
UI:RegisterDefaults('layout', {grid = 8, snap = true, preset = 'console', resolution = 'auto', density = 'comfortable',
	suggest = true, lastHeight = false, custom = {}})
-- defaults:end

local IsSecret = UI.Util.IsSecret
local function DB() return UI.db.layout end

local movers, order = {}, {}
local handles, grid = {}, nil
local unlocked, selected = false, nil
local MAGNET = 6 -- screen pixels, as in the console editor
local consoleMode = false -- edit mode with the console editor open in place of the handles
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

-- Settings pages ------------------------------------------------------------------
-- The hub page a frame's settings key opens: by exact key first, then by key
-- prefix. A module may name its own with RegisterMover's opts.page; a key
-- that matches nothing opens the Layout page.
local PAGE_OF = {['ab.bags'] = 'actionbars', ['nav.compass'] = 'navigation', ['nav.map'] = 'navigation',
	['drawer.tab'] = 'drawer', ['ip.hud'] = 'infopanel'}
local PAGE_PREFIX = {{'uf.', 'unitframes'}, {'cb.', 'unitframes'}, {'ab.', 'actionbars'}, {'bags.', 'bags'},
	{'group.', 'group'}, {'tl.', 'timeline'}, {'ip.', 'infopanel'}, {'nt.', 'banners'}, {'dm.', 'meters'},
	{'cue.', 'combatcue'}, {'nav.', 'navigation'}, {'gadget.', 'drawer'}, {'drawer.', 'drawer'}}

function UI:MoverPage(key)
	local mover = movers[key]
	local page = mover and mover.page or PAGE_OF[key]
	if not page and type(key) == 'string' then
		for _, entry in ipairs(PAGE_PREFIX) do
			if key:sub(1, #entry[1]) == entry[1] then page = entry[2] break end
		end
	end
	if page and self.GetPage and not self:GetPage(page) then page = nil end
	return page or 'layout'
end

-- The title of a frame's settings page, for tooltips.
function UI:MoverPageTitle(key)
	local page = self.GetPage and self:GetPage(self:MoverPage(key))
	return page and page.title or 'Layout'
end

function UI:OpenMoverSettings(key)
	if not self.ToggleHub then return end
	Kit:Play('open', true)
	self:ToggleHub(self:MoverPage(key), true)
end

-- The gear glyph of the menu atlas (Media/Hardware/icons-menu.tga, 8 x 4; 'menu' is cell 12).
function UI:SetGearGlyph(texture)
	texture:SetTexture(Kit.media..'icons-menu.tga')
	texture:SetTexCoord(4 / 8, 5 / 8, 1 / 4, 2 / 4)
end

-- Registering and placing -----------------------------------------------------------
local RefreshHandle -- set below

-- default: {point, x, y}: the frame's point that far from the same point of UIParent.
-- opts.page: the hub page its settings key opens (else the table above).
function UI:RegisterMover(frame, key, label, default, opts)
	local mover = movers[key]
	if mover then
		mover.frame, mover.label, mover.default = frame, label, default
	else
		mover = {frame = frame, key = key, label = label, default = default}
		movers[key] = mover
		order[#order + 1] = key
	end
	if type(opts) == 'table' and opts.page then mover.page = opts.page end
	self:PlaceMover(key)
	-- A frame built while edit mode is on gets its handle at once.
	if unlocked and RefreshHandle then RefreshHandle(mover) end
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
	if handles[key] and RefreshHandle then RefreshHandle(mover) end
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

-- One undo step for a frame, before a change made from outside (the inspector chip).
function UI:RememberMover(key, kind) Remember(key, kind) end

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
function UI:MoverLabel(key) return movers[key] and movers[key].label end

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
local Clamp = UI.Util.Clamp

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

local PaintHandle -- set below

function UI:SelectMover(key)
	if selected == key then return end
	selected = key
	if PaintHandle then for _, handle in pairs(handles) do PaintHandle(handle) end end
	Changed('__select')
end

function UI:SelectedMover() return selected end

-- Pixels and the grid -----------------------------------------------------------------
-- One screen pixel in UIParent units; the handles' grid is 1, 2, 4 or 8 of them.
local GRIDS = {1, 2, 4, 8}
UI.MOVER_GRIDS = GRIDS
local function Px() return UI.Pixel.Px(UIParent, 1) end
local function RoundPx(value)
	local px = Px()
	return floor(value / px + 0.5) * px
end
local function GridPixels()
	local value = tonumber(DB().grid)
	for _, size in ipairs(GRIDS) do if size == value then return value end end
	return 8
end
local function GridStep() return GridPixels() * Px() end

function UI:MoverGrid() return GridPixels() end
function UI:SetMoverGrid(pixels)
	DB().grid = pixels
	self:RefreshMoverGrid()
end

-- Snapping --------------------------------------------------------------------------
-- The frame's centre onto the grid (counted from the screen centre, as the grid
-- is drawn), then onto other frames' edges and centres and the screen's centre
-- lines within MAGNET pixels; the spot that gives is whole pixels from its
-- anchor. Returns the centre and the guide lines met (gx, gy: offsets from the
-- screen centre, or nil). Shift, or snapping off: whole pixels only.
local function Snap(mover, cx, cy)
	local anchor = Anchor(mover)
	local gx, gy
	if DB().snap and not IsShiftKeyDown() then
		local step = GridStep()
		cx, cy = floor(cx / step + 0.5) * step, floor(cy / step + 0.5) * step
		local width, height = Size(mover)
		local reach = MAGNET * Px()
		local bestX, bestY, dx, dy = reach, reach, 0, 0
		local function TryX(edge, line)
			local gap = line - edge
			if abs(gap) < bestX then bestX, dx, gx = abs(gap), gap, line end
		end
		local function TryY(edge, line)
			local gap = line - edge
			if abs(gap) < bestY then bestY, dy, gy = abs(gap), gap, line end
		end
		local left, right, bottom, top = cx - width / 2, cx + width / 2, cy - height / 2, cy + height / 2
		for _, key in ipairs(order) do
			local other = movers[key]
			if other ~= mover and not other.dock and other.frame:IsVisible() then
				local ox, oy = Center(other)
				local ow, oh = Size(other)
				for _, line in ipairs({ox - ow / 2, ox + ow / 2, ox}) do TryX(left, line); TryX(right, line); TryX(cx, line) end
				for _, line in ipairs({oy - oh / 2, oy + oh / 2, oy}) do TryY(bottom, line); TryY(top, line); TryY(cy, line) end
			end
		end
		-- The screen's centre lines.
		TryX(cx, 0)
		TryY(cy, 0)
		if gx then cx = cx + dx end
		if gy then cy = cy + dy end
	end
	local x, y = FromCenter(mover, anchor, cx, cy)
	local nx, ny = CenterOf(mover, anchor, RoundPx(x), RoundPx(y))
	return nx, ny, gx, gy
end

-- cx, cy and the guide lines met, for the Layout page's map.
function UI:SnapMover(key, cx, cy)
	local mover = movers[key]
	if not mover then return cx, cy end
	return Snap(mover, cx, cy)
end

-- Hairline guides across the screen where a dragged frame met a line.
local guides
local function HideGuides() if guides then guides:Hide() end end
local function ShowGuides(gx, gy)
	if not gx and not gy then return HideGuides() end
	if not guides then
		guides = CreateFrame('Frame', nil, UIParent)
		guides:SetAllPoints()
		guides:SetFrameStrata('FULLSCREEN')
		guides:EnableMouse(false)
		for _, axis in ipairs({'x', 'y'}) do
			local line = guides:CreateTexture(nil, 'OVERLAY')
			line:SetColorTexture(1, 1, 1, 1)
			Kit:Tint(line, 'accent', 0.9)
			guides[axis] = line
		end
	end
	local px = Px()
	local width, height = UIParent:GetSize()
	guides.x:SetShown(gx ~= nil)
	guides.y:SetShown(gy ~= nil)
	if gx then
		guides.x:ClearAllPoints()
		guides.x:SetSize(px, height)
		guides.x:SetPoint('CENTER', UIParent, 'CENTER', gx, 0)
	end
	if gy then
		guides.y:ClearAllPoints()
		guides.y:SetSize(width, px)
		guides.y:SetPoint('CENTER', UIParent, 'CENTER', 0, gy)
	end
	guides:Show()
end

-- Nudging ---------------------------------------------------------------------------
-- dx, dy in UIParent units; the spot stays on whole pixels.
function UI:NudgeMover(key, dx, dy)
	local mover = movers[key]
	if not mover or mover.dock or InCombatLockdown() then return end
	local point, x, y = Position(mover)
	Remember(key, 'nudge')
	Store(key, point, RoundPx(x + dx), RoundPx(y + dy))
	self:PlaceMover(key)
	Kit:Play('tick', true)
end

-- Arrow keys nudge the selected frame a pixel (Shift: a grid step) in edit
-- mode, or while the hub's Layout page asks for them (UI:SetMoverKeys('hub',
-- true)); in edit mode Escape leaves and Ctrl+Z undoes. Every other key goes
-- on to the game. The console editor, open in place, has the keyboard instead.
-- Never held in combat (EnableKeyboard and SetPropagateKeyboardInput are protected then).
local keySources = {}
local keyboard = CreateFrame('Frame', nil, UIParent)
keyboard:Hide()
local ARROWS = {LEFT = {-1, 0}, RIGHT = {1, 0}, UP = {0, 1}, DOWN = {0, -1}}

local function Editing() return unlocked and not consoleMode end

-- The hub over edit mode takes Escape for itself.
local function HubShown()
	local hub = UI.HubFrame and UI:HubFrame()
	return hub and hub:IsShown() and true or false
end

local function UpdateKeyboard()
	if InCombatLockdown() then return end
	local wanted = Editing() or (selected ~= nil and next(keySources) ~= nil)
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
	if Editing() and key == 'ESCAPE' and not HubShown() then
		self:SetPropagateKeyboardInput(false)
		UI:EditMode(false)
		return
	end
	if Editing() and key == 'Z' and IsControlKeyDown() then
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
	local step = IsShiftKeyDown() and GridStep() or Px()
	UI:NudgeMover(selected, arrow[1] * step, arrow[2] * step)
end)

function UI:SetMoverKeys(source, on)
	keySources[source] = on and true or nil
	UpdateKeyboard()
end

-- The grid -----------------------------------------------------------------------------
-- One frame of hairlines from the screen centre, every 8 grid steps (at least
-- 16 pixels); its lines are reused when the grid is redrawn.
local gridLines, gridDrawn, showLines = {}, false, true
local function DrawGrid()
	local width, height = UIParent:GetSize()
	local px = Px()
	local step = max(16, GridPixels() * 8) * px
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
		for _, sign in ipairs(x == 0 and {1} or {1, -1}) do Line(x == 0 and 0.18 or 0.05, px, height, sign * x, 0) end
	end
	for y = 0, height / 2, step do
		for _, sign in ipairs(y == 0 and {1} or {1, -1}) do Line(y == 0 and 0.18 or 0.05, width, px, 0, sign * y) end
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

local function ShowGrid() Grid():SetShown(Editing() and showLines) end

-- Redraw the grid, after the grid size or the screen changed.
function UI:RefreshMoverGrid()
	gridDrawn = false
	if grid and grid:IsShown() then DrawGrid() end
end

-- The grid lines, for this session (the edit strip's Lines key).
function UI:ShowMoverGrid(on)
	showLines = on and true or false
	ShowGrid()
end
function UI:MoverGridShown() return showLines end

-- Handles ----------------------------------------------------------------------------------
-- Glass over the frame with its legend printed in the middle, a lamp top left
-- (lit in the key color while selected, with a hairline edge), the settings
-- key top right and a resize grip bottom right. Small frames drop the legend,
-- then the keys; right-click always opens the settings.
local DRAG_START = 3 -- cursor units a press travels before it is a drag

local function HandleWanted(mover) return Editing() and not mover.dock end

-- The console's handle opens the console editor when clicked.
local function OpensConsole(mover)
	return mover.key == 'ab.console' and UI.EditConsole ~= nil and UI.ConsoleFrame ~= nil and UI:ConsoleFrame() == mover.frame
end

function PaintHandle(handle)
	local chosen = handle.key == selected
	Kit:Tint(handle.fill, chosen and 'accent' or 'white', chosen and 0.3 or handle.hover and 0.12 or 0.04)
	Kit:SetLed(handle.lamp, chosen)
	Kit:Tint(handle.label, chosen and 'darkInk' or 'darkDim')
	for _, line in ipairs(handle.outline) do line:SetShown(chosen) end
end

local function FitHandle(handle, mover)
	local width, height = Size(mover)
	if width <= 0 or height <= 0 then width, height = 120, 40 end -- unknown (or secret): print everything
	local px = Px()
	for index, line in ipairs(handle.outline) do
		if index <= 2 then line:SetHeight(px) else line:SetWidth(px) end
	end
	handle.label:SetShown(width >= 36 and height >= 11)
	handle.label:SetWidth(max(width - 34, 1))
	handle.lamp:SetShown(height >= 10 and width >= 16)
	handle.gear:SetShown(width >= 30 and height >= 18)
	handle.grip:SetShown(width >= 24 and height >= 14)
	if handle.hint then handle.hint:SetShown(OpensConsole(mover) and width >= 120 and height >= 34) end
end

local function Handle(mover)
	local handle = handles[mover.key]
	if handle then return handle end
	handle = CreateFrame('Button', nil, UIParent)
	handle.key = mover.key
	handle:SetFrameStrata('DIALOG')
	handle:RegisterForClicks('RightButtonUp')
	handle.edge = Kit:Shell(handle, {surface = 'glass', radius = 3, alpha = 0.45, shadow = false})
	handle.fill = handle:CreateTexture(nil, 'ARTWORK')
	handle.fill:SetAllPoints()
	handle.fill:SetColorTexture(1, 1, 1, 1)
	handle.outline = {}
	for index, ends in ipairs({{'TOPLEFT', 'TOPRIGHT'}, {'BOTTOMLEFT', 'BOTTOMRIGHT'}, {'TOPLEFT', 'BOTTOMLEFT'}, {'TOPRIGHT', 'BOTTOMRIGHT'}}) do
		local line = handle:CreateTexture(nil, 'OVERLAY')
		line:SetColorTexture(1, 1, 1, 1)
		Kit:Tint(line, 'accent', 1)
		line:SetPoint(ends[1])
		line:SetPoint(ends[2])
		line:Hide()
		handle.outline[index] = line
	end
	handle.label = Kit:Label(handle, mover.label or mover.key, 'darkDim', 8, true)
	handle.label:SetPoint('CENTER')
	handle.label:SetWordWrap(false)
	if mover.key == 'ab.console' then
		handle.hint = Kit:Label(handle, 'Click to edit its blocks', 'darkDim', 7)
		handle.hint:SetPoint('TOP', handle.label, 'BOTTOM', 0, -4)
	end
	handle.lamp = Kit:Led(handle, 4, false)
	handle.lamp:SetPoint('TOPLEFT', 4, -4)
	handle:HookScript('OnSizeChanged', function(self) FitHandle(self, mover) end)
	handle:SetScript('OnEnter', function(self) self.hover = true; PaintHandle(self) end)
	handle:SetScript('OnLeave', function(self) self.hover = nil; PaintHandle(self) end)
	handle:SetScript('OnClick', function(_, button)
		if button ~= 'RightButton' then return end
		UI:SelectMover(mover.key)
		UI:OpenMoverSettings(mover.key)
	end)

	-- The settings key: the gear, lit in the key color on hover.
	local gear = CreateFrame('Button', nil, handle)
	gear:SetSize(16, 16)
	gear:SetPoint('TOPRIGHT', -2, -2)
	gear:SetFrameLevel(handle:GetFrameLevel() + 3)
	gear.glyph = gear:CreateTexture(nil, 'OVERLAY')
	gear.glyph:SetSize(11, 11)
	gear.glyph:SetPoint('CENTER')
	UI:SetGearGlyph(gear.glyph)
	Kit:Tint(gear.glyph, 'darkDim')
	gear:SetScript('OnEnter', function(self)
		Kit:Tint(self.glyph, 'accent')
		Kit:ShowTooltip(self, UI:MoverPageTitle(mover.key)..' settings')
	end)
	gear:SetScript('OnLeave', function(self)
		Kit:Tint(self.glyph, 'darkDim')
		Kit:HideTooltip()
	end)
	gear:SetScript('OnMouseDown', function() Kit:Play('down', true) end)
	gear:SetScript('OnClick', function()
		UI:SelectMover(mover.key)
		UI:OpenMoverSettings(mover.key)
	end)
	handle.gear = gear

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
	-- Leaving edit mode (Esc, a fight) hides the handle before any mouse-up arrives.
	grip:SetScript('OnHide', function(self) self:SetScript('OnUpdate', nil) end)
	handle.grip = grip

	-- Dragging: a press only becomes a drag once the cursor travels, so a
	-- click selects without moving anything (and on the console, opens its editor).
	handle:SetScript('OnMouseDown', function(self, button)
		if button ~= 'LeftButton' or InCombatLockdown() then return end
		UI:SelectMover(mover.key)
		local scale = UIParent:GetEffectiveScale()
		local startX, startY = GetCursorPosition()
		local baseX, baseY = Center(mover)
		Kit:Play('down', true)
		local remembered = false
		self.dragged = false
		self:SetScript('OnUpdate', function()
			if InCombatLockdown() then self:SetScript('OnUpdate', nil) HideGuides() return end
			local x, y = GetCursorPosition()
			if not self.dragged then
				if abs(x - startX) < DRAG_START and abs(y - startY) < DRAG_START then return end
				self.dragged = true
			end
			local cx, cy, gx, gy = Snap(mover, baseX + (x - startX) / scale, baseY + (y - startY) / scale)
			ShowGuides(gx, gy)
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
		HideGuides()
		if not self.dragged and OpensConsole(mover) and not InCombatLockdown() then
			UI:EditConsole(true)
			return
		end
		Kit:Play('up', true)
	end)
	handle:SetScript('OnHide', function(self)
		self:SetScript('OnUpdate', nil)
		HideGuides()
	end)
	handles[mover.key] = handle
	return handle
end

function RefreshHandle(mover)
	local handle = Handle(mover)
	handle:ClearAllPoints()
	handle:SetAllPoints(mover.frame)
	handle.label:SetText(strupper(mover.label or mover.key))
	FitHandle(handle, mover)
	PaintHandle(handle)
	handle:SetShown(HandleWanted(mover))
end

local function RefreshHandles()
	for _, key in ipairs(order) do RefreshHandle(movers[key]) end
end

-- The handle over a frame (nil until edit mode first shows it), for the inspector chip.
function UI:MoverHandle(key) return handles[key] end

UI:OnMoversChanged(function(key)
	if key == '__select' or key == '__lock' then UpdateKeyboard() end
end)

-- Edit mode ------------------------------------------------------------------------------------
function UI:ToggleMovers(lock)
	if lock == nil then lock = unlocked end
	if not lock and InCombatLockdown() then return self:Print('Frames can be moved once you leave combat.') end
	if unlocked == not lock then return end
	unlocked, consoleMode = not lock, false
	-- The console editor closes: opened from edit mode it leaves with it; opened
	-- on its own (/spec console), edit mode's handles take over.
	if self.ConsoleEditing and self:ConsoleEditing() then self:EditConsole(false) end
	ShowGrid()
	HideGuides()
	for _, key in ipairs(order) do
		local mover = movers[key]
		RefreshHandle(mover)
		if mover.frame.SetPreview then UI:Safe(mover.frame.SetPreview, mover.frame, unlocked) end
	end
	Kit:Play(unlocked and 'latch-down' or 'latch-up', true)
	Changed('__lock')
end

-- on: true enters, false leaves, nil toggles. /spec move, unlock and lock and
-- the unlock key binding come here through UI:ToggleMovers.
function UI:EditMode(on)
	if on == nil then on = not unlocked end
	self:ToggleMovers(not on)
end

function UI:MoversUnlocked() return unlocked end
UI.EditModeActive = UI.MoversUnlocked

-- The console editor open in place of the handles (the edit strip stays).
function UI:SetEditModeConsole(on)
	on = (on and unlocked) and true or false
	if on == consoleMode then return end
	consoleMode = on
	ShowGrid()
	HideGuides()
	RefreshHandles()
	Changed('__lock')
end

function UI:EditModeConsole() return consoleMode end

-- Defaults and edge anchors depend on the screen's size in UI units, so
-- re-place everything whenever the UI scale or resolution changes, and redraw the grid.
UI.Pixel.OnChange(function()
	UI:PlaceAllMovers()
	UI:RefreshMoverGrid()
	if unlocked then RefreshHandles() end
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
