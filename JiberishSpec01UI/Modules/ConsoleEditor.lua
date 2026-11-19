-- The console editor: every element of the CX-1 console as a block you can
-- move anywhere inside it.
--
--   Blocks     each key bank, the two function key clusters, the meters and
--              stats strip, the menu keys (when set into the console), each
--              docked unit frame and cast bar, and the stance and pet keys
--              (tucked on the top edge until dragged into the body): glass
--              blocks with a printed label and a lamp, lit in the key color
--              when selected.
--   Moving     drag a block: it snaps to the grid (whole screen pixels: 1, 2,
--              4 or 8) and to the other blocks' edges and centres, with
--              hairline guides. A spot over another block or outside the
--              console's body is refused, and the block springs back. Arrow
--              keys nudge the selected block one pixel (Shift: one grid step).
--   Inspector  the block's spot and size in screen pixels; a bank's columns and
--              the key size; a cast bar's or the meters' width; taking a block
--              out of the console (a unit frame gets its own spot back) and
--              putting it back; the console's size (auto or fixed); reset; the
--              block's settings page (right-clicking a block does the same).
--
-- The arrangement is saved in the profile (actionbars.consoleLayout), so it
-- goes with exported profiles; a layout preset brings back its own. Editing is
-- out of combat only: entering combat closes the editor (every change is saved
-- as it is made). /spec console, or the Action bars page; in edit mode,
-- clicking the console's handle or the edit strip's Console key opens it in
-- place of the handles, and Done (or Esc) goes back to them.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown = CreateFrame, UIParent, InCombatLockdown
local floor, max, min, abs = math.floor, math.max, math.min, math.abs

-- Geometry (plain functions: the console's own layout uses them too) ----------------------
-- Rects are {x, y, w, h} in console units from its top-left corner, y down.
-- Bounds are {left, top, right, bottom}; right and bottom may be nil (open).
local Grid = {}
UI.ConsoleGrid = Grid
local EPS = 0.001

function Grid.Overlap(a, b)
	return a.x < b.x + b.w - EPS and b.x < a.x + a.w - EPS and a.y < b.y + b.h - EPS and b.y < a.y + a.h - EPS
end

function Grid.Inside(rect, bounds)
	return rect.x >= bounds.left - EPS and rect.y >= bounds.top - EPS
		and (not bounds.right or rect.x + rect.w <= bounds.right + EPS)
		and (not bounds.bottom or rect.y + rect.h <= bounds.bottom + EPS)
end

-- Whether a rect may sit where it is: inside the body, over no other block
-- (blocks with its own key don't count).
function Grid.Free(rect, blocks, bounds)
	if not Grid.Inside(rect, bounds) then return false end
	for _, other in ipairs(blocks) do
		if other.key ~= rect.key and Grid.Overlap(rect, other) then return false end
	end
	return true
end

function Grid.Snap(value, step)
	if not step or step <= 0 then return value end
	return floor(value / step + 0.5) * step
end

-- Nearest first: down, right, left, up (the console grows downward and rightward).
local SEARCH = {{0, 1}, {1, 0}, {-1, 0}, {0, -1}}

-- Lay blocks out so none covers another or leaves the body: the saved ones
-- (block.saved) first, the most recently edited (block.rank) first among them,
-- then in list order. A block that doesn't fit where it asks moves to the
-- nearest free spot in `step`s; failing that it goes under everything.
-- px: one screen pixel, so a block clamped to an edge stays on the pixel grid.
function Grid.Resolve(blocks, bounds, step, px)
	step = (step and step > 0) and step or 1
	px = (px and px > 0) and px or step
	local order, position = {}, {}
	for index, block in ipairs(blocks) do
		order[#order + 1] = block
		position[block] = index
	end
	table.sort(order, function(a, b)
		if (a.saved and true or false) ~= (b.saved and true or false) then return a.saved and true or false end
		local ra, rb = tonumber(a.rank) or 0, tonumber(b.rank) or 0
		if ra ~= rb then return ra > rb end
		return position[a] < position[b]
	end)
	local placed = {}
	local probe = {}
	local function Fits(block, x, y)
		probe.key, probe.x, probe.y, probe.w, probe.h = block.key, x, y, block.w, block.h
		return Grid.Free(probe, placed, bounds)
	end
	for _, block in ipairs(order) do
		local x, y = max(block.x, bounds.left), max(block.y, bounds.top)
		if bounds.right and x + block.w > bounds.right then x = max(bounds.left, floor((bounds.right - block.w) / px + EPS) * px) end
		if bounds.bottom and y + block.h > bounds.bottom then y = max(bounds.top, floor((bounds.bottom - block.h) / px + EPS) * px) end
		if not Fits(block, x, y) then
			local found = false
			for ring = 1, 800 do
				local distance = ring * step
				for _, dir in ipairs(SEARCH) do
					local tx, ty = x + dir[1] * distance, y + dir[2] * distance
					if Fits(block, tx, ty) then x, y, found = tx, ty, true break end
				end
				if found then break end
			end
			if not found then
				local bottom = bounds.top
				for _, other in ipairs(placed) do bottom = max(bottom, other.y + other.h) end
				x, y = bounds.left, bottom + step
			end
		end
		block.x, block.y = x, y
		placed[#placed + 1] = block
	end
	return blocks
end

-- Pull (x, y) onto other blocks' edges and centres (and the console's centre
-- line) within `reach`: x, y and the guide lines it met (gx, gy, or nil).
function Grid.Magnet(block, x, y, blocks, reach, centreX)
	local bestX, bestY, dx, dy, gx, gy = reach + EPS, reach + EPS, 0, 0, nil, nil
	local function TryX(edge, line)
		local gap = line - edge
		if abs(gap) < bestX then bestX, dx, gx = abs(gap), gap, line end
	end
	local function TryY(edge, line)
		local gap = line - edge
		if abs(gap) < bestY then bestY, dy, gy = abs(gap), gap, line end
	end
	for _, other in ipairs(blocks) do
		if other.key ~= block.key then
			for _, line in ipairs({other.x, other.x + other.w, other.x + other.w / 2}) do
				TryX(x, line); TryX(x + block.w, line); TryX(x + block.w / 2, line)
			end
			for _, line in ipairs({other.y, other.y + other.h, other.y + other.h / 2}) do
				TryY(y, line); TryY(y + block.h, line); TryY(y + block.h / 2, line)
			end
		end
	end
	if centreX then TryX(x + block.w / 2, centreX) end
	return x + (gx and dx or 0), y + (gy and dy or 0), gx, gy
end

-- The editor ------------------------------------------------------------------------------
-- How far a console with no fixed size may grow while blocks are moved, in console units.
local MAX_W, MAX_H = 2400, 600
local GRIDS = {1, 2, 4, 8}
local MAGNET = 6 -- screen pixels

local LABELS = {['uf.player'] = 'Player', ['uf.target'] = 'Target', ['uf.focus'] = 'Focus', ['uf.targettarget'] = 'Target of target',
	['uf.pet'] = 'Pet', ['cb.player'] = 'Player cast', ['cb.target'] = 'Target cast', fnL = 'Function keys', fnR = 'Function keys',
	deck = 'Meters', menu = 'Menu keys', stance = 'Stance keys', petbar = 'Pet keys'}
-- Frames the layouts dock with a setting of their own; the rest are taken out with an off flag.
local DOCK_SETTING = {['uf.focus'] = 'dockFocus', ['uf.targettarget'] = 'dockToT', ['uf.pet'] = 'dockPet'}
local REMOVABLE = {unit = true, cast = true, fn = true, deck = true, mini = true, menu = true}
-- The hub page each kind of block's settings are on (unit frames and cast bars by their mover's).
local BLOCK_PAGE = {bank = 'actionbars', fn = 'actionbars', menu = 'actionbars', mini = 'actionbars', deck = 'actionbars',
	unit = 'unitframes', cast = 'unitframes'}

local editing, selected, drag, fromEditMode = false, nil, nil, false
local overlay, inspector, keyboard
local blockFrames, guides = {}, {}
local current, currentBounds = {}, nil
local Draw -- set below

local function DB() return UI.db.actionbars end
local function Console() return UI.ConsoleFrame and UI:ConsoleFrame() or nil end
local function Px()
	local console = Console()
	return UI.Pixel.Px(console or UIParent, 1)
end
local function GridPixels()
	local value = tonumber(DB().consoleGrid) or 2
	for _, size in ipairs(GRIDS) do if size == value then return value end end
	return 2
end
local function GridStep() return Px() * GridPixels() end
local function Layout()
	if type(DB().consoleLayout) ~= 'table' then DB().consoleLayout = {} end
	return DB().consoleLayout
end
local function Edited()
	for _ in pairs(Layout()) do return true end
	return false
end

local function Label(key)
	local bank = key:match('^bank(%d)$')
	if bank then return 'Bank '..strsub('ABC', tonumber(bank), tonumber(bank))..(bank == '1' and ' (bar 1)' or ' (bar '..bank..')') end
	if key == 'fnL' then return LABELS.fnL..' L' elseif key == 'fnR' then return LABELS.fnR..' R' end
	return LABELS[key] or key
end

local function Find(key)
	for _, block in ipairs(current) do if block.key == key then return block end end
end

local function OpenSettings(block)
	if not (block and UI.ToggleHub) then return Kit:Play('error') end
	local page = (block.kind == 'unit' or block.kind == 'cast') and UI.MoverPage and UI:MoverPage(block.key)
	page = page or BLOCK_PAGE[block.kind] or 'actionbars'
	Kit:Play('open')
	UI:ToggleHub(page, true)
end

-- Where blocks may go: the console's body; open sides up to the most it may grow.
local function Limits()
	local bounds = currentBounds or {left = 10, top = 24}
	return {left = bounds.left, top = bounds.top, right = bounds.right or MAX_W - bounds.left,
		bottom = bounds.bottom or MAX_H - bounds.left}
end

-- Saving -----------------------------------------------------------------------------------
-- The first change keeps every block where it is now, so only the moved one moves.
local function Snapshot()
	local layout = Layout()
	if next(layout) ~= nil then return layout end
	for _, block in ipairs(current) do
		-- Stance and pet keys still tucked on the top edge stay there.
		if not block.tucked then
			local spot = {x = block.x, y = block.y}
			if block.kind == 'cast' or block.kind == 'deck' or block.bay then spot.w = block.w end
			layout[block.key] = spot
		end
	end
	return layout
end

local function Relayout()
	if InCombatLockdown() then return false end
	UI:RelayoutConsole()
	if Draw then Draw() end
	return true
end

-- Change a block's saved fields (nil values are left as they are).
local function Commit(key, changes)
	if InCombatLockdown() then return false end
	local layout = Snapshot()
	local spot = type(layout[key]) == 'table' and layout[key] or {}
	for field, value in pairs(changes) do spot[field] = value end
	-- The block just edited keeps its spot; others make room for it.
	local rank = 0
	for _, other in pairs(layout) do if type(other) == 'table' then rank = max(rank, tonumber(other.rank) or 0) end end
	spot.rank = rank + 1
	layout[key] = spot
	return Relayout()
end

-- A setting that relays the console out on its own (key size, console size, docking).
local function SetOption(path, value)
	Kit:SetOption(path, value)
	C_Timer.After(0.25, function() if editing and Draw then Draw() end end)
end

-- Blocks -----------------------------------------------------------------------------------
local function Paint(frame, invalid)
	local chosen = frame.block and frame.block.key == selected
	Kit:Tint(frame.fill, invalid and 'red' or chosen and 'accent' or 'white', invalid and 0.4 or chosen and 0.32 or 0.05)
	Kit:SetLed(frame.lamp, chosen or invalid, invalid and 'red' or nil)
	Kit:Tint(frame.label, chosen and 'darkInk' or 'darkDim')
end

local function PaintAll()
	for _, frame in ipairs(blockFrames) do if frame:IsShown() then Paint(frame) end end
end

local UpdateInspector -- set below

local function Select(key)
	if selected == key then return end
	selected = key
	PaintAll()
	if UpdateInspector then UpdateInspector() end
end

local function HideGuides() for _, line in ipairs(guides) do line:Hide() end end

-- Hairline guides through the console where a dragged block met another.
local function ShowGuides(gx, gy)
	local console = Console()
	if not console then return end
	local px = Px()
	for index = 1, 2 do
		local line = guides[index]
		if not line then
			line = overlay:CreateTexture(nil, 'OVERLAY', nil, 7)
			line:SetColorTexture(1, 1, 1, 1)
			Kit:Tint(line, 'accent', 0.9)
			guides[index] = line
		end
		local at = index == 1 and gx or gy
		line:ClearAllPoints()
		if at then
			if index == 1 then
				line:SetSize(px, console:GetHeight())
				line:SetPoint('TOPLEFT', console, 'TOPLEFT', at - px / 2, 0)
			else
				line:SetSize(console:GetWidth(), px)
				line:SetPoint('TOPLEFT', console, 'TOPLEFT', 0, -(at - px / 2))
			end
			line:Show()
		else
			line:Hide()
		end
	end
end

local function Place(frame, x, y)
	frame:ClearAllPoints()
	frame:SetPoint('TOPLEFT', Console(), 'TOPLEFT', x, -y)
end

local function Cursor()
	local x, y = GetCursorPosition()
	local scale = Console():GetEffectiveScale()
	return x / scale, y / scale
end

local function DragUpdate(frame)
	if not drag or InCombatLockdown() then return end
	local block = drag.block
	local cx, cy = Cursor()
	local step, px = GridStep(), Px()
	local x = Grid.Snap(drag.x + (cx - drag.sx), step)
	local y = Grid.Snap(drag.y - (cy - drag.sy), step)
	local gx, gy
	x, y, gx, gy = Grid.Magnet(block, x, y, current, MAGNET * px, Console():GetWidth() / 2)
	x, y = Grid.Snap(x, px), Grid.Snap(y, px)
	drag.nx, drag.ny = x, y
	Place(frame, x, y)
	drag.valid = Grid.Free({key = block.key, x = x, y = y, w = block.w, h = block.h}, current, Limits())
	Paint(frame, not drag.valid)
	ShowGuides(gx, gy)
end

local function BlockDown(frame, button)
	if button ~= 'LeftButton' or InCombatLockdown() or not frame.block then return end
	Select(frame.block.key)
	local cx, cy = Cursor()
	drag = {frame = frame, block = frame.block, sx = cx, sy = cy, x = frame.block.x, y = frame.block.y,
		nx = frame.block.x, ny = frame.block.y, valid = true}
	Kit:Play('down')
	frame:SetScript('OnUpdate', DragUpdate)
end

local function BlockUp(frame, button)
	if button == 'RightButton' then
		if frame.block and not drag then
			Select(frame.block.key)
			OpenSettings(frame.block)
		end
		return
	end
	if not drag or drag.frame ~= frame then return end
	frame:SetScript('OnUpdate', nil)
	HideGuides()
	local moved = drag
	drag = nil
	if moved.nx == moved.x and moved.ny == moved.y then
		Kit:Play('up')
		Paint(frame)
		return
	end
	if moved.valid and Commit(moved.block.key, {x = moved.nx, y = moved.ny}) then
		Kit:Play('latch-down')
		return
	end
	-- Refused: it springs back to where it was.
	Kit:Play('error')
	Kit:Animate(frame, 0.22, 0, 1, function(t)
		Place(frame, moved.nx + (moved.x - moved.nx) * t, moved.ny + (moved.y - moved.ny) * t)
	end, function() Paint(frame) end, 'settle')
end

local function BlockFrame(index)
	local frame = blockFrames[index]
	if frame then return frame end
	frame = CreateFrame('Button', nil, overlay)
	frame:SetFrameLevel(overlay:GetFrameLevel() + 2)
	frame:RegisterForClicks('LeftButtonUp', 'RightButtonUp')
	frame.shell = Kit:Shell(frame, {surface = 'glass', radius = 3, shadow = false, alpha = 0.6})
	frame.fill = frame:CreateTexture(nil, 'ARTWORK')
	frame.fill:SetAllPoints()
	frame.fill:SetColorTexture(1, 1, 1, 1)
	frame.label = Kit:Label(frame, '', 'darkDim', 7, true)
	frame.label:SetPoint('CENTER')
	frame.label:SetWordWrap(false)
	frame.lamp = Kit:Led(frame, 4, false)
	frame.lamp:SetPoint('TOPLEFT', 3, -3)
	frame:SetScript('OnMouseDown', BlockDown)
	frame:SetScript('OnMouseUp', BlockUp)
	frame:SetScript('OnEnter', function(self)
		if not self.block or drag then return end
		GameTooltip:SetOwner(self, 'ANCHOR_TOP')
		GameTooltip:AddLine(Label(self.block.key), 1, 1, 1)
		GameTooltip:AddLine('Drag to move it. Arrow keys nudge one pixel, Shift one grid step. Right-click: its settings.', 0.8, 0.8, 0.78, true)
		if self.block.tucked then
			GameTooltip:AddLine(self.block.header and 'In the console\'s header: drag it into the body to place it freely. Reset block puts it back.'
				or 'Tucked on the console\'s top edge: drag it into the console to set it in. Reset block tucks it back.', 0.8, 0.8, 0.78, true)
		end
		GameTooltip:Show()
	end)
	frame:SetScript('OnLeave', function() GameTooltip:Hide() end)
	blockFrames[index] = frame
	return frame
end

function Draw()
	local console = Console()
	if not (editing and console and overlay) then return end
	current, currentBounds = UI:ConsoleSlots()
	current = current or {}
	for index, block in ipairs(current) do
		local frame = BlockFrame(index)
		frame.block = block
		frame:SetSize(max(block.w, 2), max(block.h, 2))
		Place(frame, block.x, block.y)
		frame.label:SetText(strupper(Label(block.key))..(block.header and '  (HEADER)' or block.tucked and '  (TOP EDGE)' or ''))
		frame.label:SetWidth(max(block.w - 8, 1))
		frame.label:SetShown(block.w > 30 and block.h > 9)
		Paint(frame)
		frame:Show()
	end
	for index = #current + 1, #blockFrames do blockFrames[index]:Hide() end
	if selected and not Find(selected) then selected = nil end
	if UpdateInspector then UpdateInspector() end
end

-- Changes from the inspector and the keyboard ------------------------------------------
local function Nudge(dx, dy, step)
	local block = Find(selected)
	if not block or InCombatLockdown() then return end
	step = step or Px()
	local x, y = Grid.Snap(block.x + dx * step, Px()), Grid.Snap(block.y + dy * step, Px())
	if Grid.Free({key = block.key, x = x, y = y, w = block.w, h = block.h}, current, Limits()) and Commit(block.key, {x = x, y = y}) then
		Kit:Play('tick')
	else
		Kit:Play('error')
	end
end

-- A cast bar's or the meters' width, a grid step at a time (refused if it would cover another block).
local function Widen(sign)
	local block = Find(selected)
	if not block then return end
	local width = Grid.Snap(block.w + sign * GridStep() * 4, Px())
	if width < (block.bay and 96 or 40) or not Grid.Free({key = block.key, x = block.x, y = block.y, w = width, h = block.h}, current, Limits()) then
		return Kit:Play('error')
	end
	Commit(block.key, {w = width})
	Kit:Play('tick')
end

local function Columns(sign)
	local block = Find(selected)
	if not block then return end
	local spot = Layout()[block.key]
	-- A bank has 12 keys; the stance, pet, menu and function keys as many as
	-- they show (function keys start in one column, the others in one line).
	local most = block.kind == 'bank' and 12 or max(block.count or 1, 1)
	local now = type(spot) == 'table' and tonumber(spot.columns) or (block.kind == 'fn' and 1 or most)
	local value = Kit:Clamp(now + sign, 1, most)
	if value == now then return Kit:Play('error') end
	Commit(block.key, {columns = value})
	Kit:Play('tick')
end

-- The stance or pet keys' own key size (the device scales to it).
local function MiniKeys(sign)
	local block = Find(selected)
	if not block then return end
	local spot = Layout()[block.key]
	local now = type(spot) == 'table' and tonumber(spot.keys) or floor((block.keySize or 24) + 0.5)
	local value = Kit:Clamp(now + sign, 16, block.kind == 'menu' and 40 or 48)
	if value == now then return Kit:Play('error') end
	Commit(block.key, {keys = value})
	Kit:Play('tick')
end

local function KeySize(sign)
	local value = Kit:Clamp((tonumber(DB().keySize) or 34) + sign, 24, 48)
	SetOption('actionbars.keySize', value)
	Kit:Play('tick')
end

local function Remove()
	local block = Find(selected)
	if not block or not REMOVABLE[block.kind] then return Kit:Play('error') end
	local setting = DOCK_SETTING[block.key]
	selected = nil
	if block.key == 'menu' then
		-- The menu keys go back to their own device and mover.
		SetOption('actionbars.menuLayout', 'line')
	elseif setting then
		SetOption('actionbars.'..setting, false)
	else
		Commit(block.key, {off = true})
	end
	Kit:Play('latch-up')
end

-- What was taken out and can go back in: {key, label}.
local function Removed()
	local list = {}
	local unitframes = UI.modules.unitframes
	local frames = unitframes and unitframes.frames or {}
	if DB().dock then
		for key, setting in pairs(DOCK_SETTING) do
			local unit = key == 'uf.targettarget' and 'targettarget' or key:sub(4)
			if not DB()[setting] and frames[unit] then list[#list + 1] = {key = key} end
		end
	end
	for key, spot in pairs(Layout()) do
		if type(spot) == 'table' and spot.off then list[#list + 1] = {key = key} end
	end
	if DB().menuLayout ~= 'console' and DB().menuEnable ~= false then list[#list + 1] = {key = 'menu'} end
	table.sort(list, function(a, b) return a.key < b.key end)
	return list
end

local function Add(key)
	local setting = DOCK_SETTING[key]
	if key == 'menu' then
		SetOption('actionbars.menuLayout', 'console')
	elseif setting then
		SetOption('actionbars.'..setting, true)
	else
		local spot = Layout()[key]
		if type(spot) == 'table' then spot.off = nil end
		Relayout()
	end
	selected = key
	Kit:Play('latch-down')
end

local function ResetBlock()
	local block = selected and Layout()[selected]
	if not block then return Kit:Play('error') end
	Layout()[selected] = nil
	Relayout()
	Kit:Play('latch-up')
end

local function ResetConsole()
	wipe(Layout())
	selected = nil
	Relayout()
	Kit:Play('latch-up')
end

local function ConsoleSize(field, sign)
	local console = Console()
	if not console then return end
	local path = field == 'w' and 'actionbars.consoleWidth' or 'actionbars.consoleHeight'
	local now = field == 'w' and tonumber(DB().consoleWidth) or tonumber(DB().consoleHeight)
	if not now or now <= 0 then now = floor((field == 'w' and console:GetWidth() or console:GetHeight()) + 0.5) end
	local low, high = field == 'w' and 300 or 80, field == 'w' and MAX_W or MAX_H
	SetOption(path, Kit:Clamp(now + sign * 10, low, high))
	Kit:Play('tick')
end

-- The inspector ------------------------------------------------------------------------------
local INSPECTOR_W, INSPECTOR_H = 352, 250

local function Key(parent, text, width, onClick, tone)
	local key = Kit:Key(parent, {text = text, width = width, height = 22, textSize = 7, tone = tone, onClick = onClick})
	return key
end

local function BuildInspector()
	inspector = Kit:Device(UIParent, {model = 'CE-1', title = 'Console editor', width = INSPECTOR_W, height = INSPECTOR_H})
	inspector:SetFrameStrata('DIALOG')
	inspector:SetClampedToScreen(true)
	inspector:EnableMouse(true)
	inspector:Hide()
	local lcd = Kit:LCDPanel(inspector, {radius = 4})
	lcd:SetSize(INSPECTOR_W - 20, 34)
	lcd:SetPoint('TOPLEFT', 10, -28)
	inspector.name = Kit:Text(lcd, '', 9, 'lcdInk', true)
	inspector.name:SetPoint('TOPLEFT', 8, -5)
	inspector.spot = Kit:Text(lcd, '', 8, 'lcdInk', true)
	inspector.spot:SetPoint('BOTTOMLEFT', 8, 5)
	inspector.state = Kit:Text(lcd, '', 8, 'lcdDim', true)
	inspector.state:SetPoint('TOPRIGHT', -8, -5)

	-- Nudge keys and the grid.
	local y = -72
	local arrows = {{'<', -1, 0}, {'>', 1, 0}, {'^', 0, -1}, {'v', 0, 1}}
	for index, spec in ipairs(arrows) do
		local key = Key(inspector, spec[1], 30, function() Nudge(spec[2], spec[3], IsShiftKeyDown() and GridStep() or nil) end)
		key:SetPoint('TOPLEFT', 10 + (index - 1) * 34, y)
	end
	inspector.grid = Kit:Segmented(inspector, {items = {'1PX', '2PX', '4PX', '8PX'}, width = 172, onChange = function(index)
		DB().consoleGrid = GRIDS[index]
	end})
	inspector.grid:SetPoint('TOPRIGHT', -10, y + 2)

	-- The selected block's own controls (labels set per block).
	y = -104
	inspector.context = {}
	for index = 1, 5 do
		local key = Key(inspector, '', 62, function(self) if self.action then self.action() end end)
		key:SetPoint('TOPLEFT', 10 + (index - 1) * 66, y)
		inspector.context[index] = key
	end

	-- The console's own size.
	y = -136
	inspector.size = Kit:Label(inspector, '', 'dim', 8, true)
	inspector.size:SetPoint('TOPLEFT', 12, y - 6)
	local sizeKeys = {{'W -', function() ConsoleSize('w', -1) end}, {'W +', function() ConsoleSize('w', 1) end},
		{'H -', function() ConsoleSize('h', -1) end}, {'H +', function() ConsoleSize('h', 1) end},
		{'AUTO', function() SetOption('actionbars.consoleWidth', 0); SetOption('actionbars.consoleHeight', 0); Kit:Play('tick') end}}
	for index, spec in ipairs(sizeKeys) do
		local key = Key(inspector, spec[1], index == 5 and 46 or 34, spec[2])
		key:SetPoint('TOPRIGHT', -10 - (5 - index) * 38 - (index < 5 and 12 or 0), y)
	end

	-- Taken-out elements, to put back.
	y = -168
	inspector.addLabel = Kit:Label(inspector, 'PUT BACK', 'dim', 7, true)
	inspector.addLabel:SetPoint('TOPLEFT', 12, y - 7)
	inspector.add = {}
	for index = 1, 4 do
		local key = Key(inspector, '', 66, function(self) if self.addKey then Add(self.addKey) end end)
		key:SetPoint('TOPLEFT', 74 + (index - 1) * 70, y)
		inspector.add[index] = key
	end

	-- Reset and done.
	y = -210
	Key(inspector, 'RESET BLOCK', 88, ResetBlock):SetPoint('TOPLEFT', 10, y)
	Key(inspector, 'RESET ALL', 80, function()
		Kit:AlertDialog({title = 'Reset the console', confirm = 'Reset',
			text = 'Every block goes back to the console\'s own arrangement.', onConfirm = ResetConsole})
	end):SetPoint('TOPLEFT', 102, y)
	-- The selected block's settings page, printed with the gear.
	inspector.settings = Key(inspector, 'SETTINGS', 80, function() OpenSettings(Find(selected)) end)
	inspector.settings:SetPoint('TOPLEFT', 186, y)
	if UI.SetGearGlyph and inspector.settings.face then
		local glyph = inspector.settings.face:CreateTexture(nil, 'OVERLAY', nil, 2)
		glyph:SetSize(10, 10)
		glyph:SetPoint('LEFT', 7, 0)
		UI:SetGearGlyph(glyph)
		Kit:Tint(glyph, 'ink')
		if inspector.settings.text then inspector.settings.text:SetPoint('CENTER', 6, 0) end
	end
	-- Opened from edit mode, Done goes back to the frames' handles.
	Key(inspector, 'DONE', 66, function() UI:EditConsole(false) end, 'primary'):SetPoint('TOPRIGHT', -10, y)
end

local function SetContext(index, text, action)
	local key = inspector.context[index]
	key.action = action
	key:SetKeyText(text or '')
	key:SetShown(action ~= nil)
end

function UpdateInspector()
	if not inspector or not inspector:IsShown() then return end
	local px = Px()
	local block = Find(selected)
	local function P(value) return floor(value / px + 0.5) end
	if block then
		inspector.name:SetText(strupper(Label(block.key)))
		inspector.spot:SetText(format('X %d   Y %d   W %d   H %d   PX', P(block.x), P(block.y), P(block.w), P(block.h)))
	else
		inspector.name:SetText('SELECT A BLOCK')
		inspector.spot:SetText('DRAG TO MOVE  -  ARROWS NUDGE 1 PX')
	end
	inspector.state:SetText(Edited() and 'CUSTOM' or 'AUTO')
	inspector.settings:SetKeyEnabled(block ~= nil)
	for index = 1, 5 do SetContext(index) end
	if block and block.kind == 'bank' then
		SetContext(1, 'COLS -', function() Columns(-1) end)
		SetContext(2, 'COLS +', function() Columns(1) end)
		SetContext(3, 'KEYS -', function() KeySize(-1) end)
		SetContext(4, 'KEYS +', function() KeySize(1) end)
	elseif block and block.kind == 'menu' and block.header then
		SetContext(5, 'TAKE OUT', Remove)
	elseif block and block.kind == 'fn' then
		SetContext(1, 'COLS -', function() Columns(-1) end)
		SetContext(2, 'COLS +', function() Columns(1) end)
		SetContext(5, 'TAKE OUT', Remove)
	elseif block and (block.kind == 'mini' or block.kind == 'menu') then
		SetContext(1, 'COLS -', function() Columns(-1) end)
		SetContext(2, 'COLS +', function() Columns(1) end)
		SetContext(3, 'KEYS -', function() MiniKeys(-1) end)
		SetContext(4, 'KEYS +', function() MiniKeys(1) end)
		SetContext(5, 'TAKE OUT', Remove)
	elseif block then
		-- A cast bar, the meters, or a frame's bay (the frame follows its bay's width).
		if block.kind == 'cast' or block.kind == 'deck' or block.bay then
			SetContext(1, 'WIDTH -', function() Widen(-1) end)
			SetContext(2, 'WIDTH +', function() Widen(1) end)
		end
		if REMOVABLE[block.kind] then SetContext(5, 'TAKE OUT', Remove) end
	end
	local console = Console()
	if console then
		local fixed = (tonumber(DB().consoleWidth) or 0) > 0 or (tonumber(DB().consoleHeight) or 0) > 0
		inspector.size:SetText(format('CONSOLE %d x %d  %s', floor(console:GetWidth() + 0.5), floor(console:GetHeight() + 0.5),
			fixed and 'FIXED' or 'FITS'))
	end
	local removed = Removed()
	for index, key in ipairs(inspector.add) do
		local entry = removed[index]
		key.addKey = entry and entry.key
		key:SetKeyText(entry and strupper(Label(entry.key)) or '')
		key:SetShown(entry ~= nil)
	end
	inspector.addLabel:SetShown(#removed > 0)
	for index, size in ipairs(GRIDS) do
		if size == GridPixels() and inspector.grid:GetValue() ~= index then inspector.grid:SetValue(index) end
	end
end

-- Keyboard: arrows nudge, Escape is Done; every other key goes on to the game.
-- Captured only while editing, and given back before combat (it can't be then).
local ARROWS = {LEFT = {-1, 0}, RIGHT = {1, 0}, UP = {0, -1}, DOWN = {0, 1}}
local function Keyboard(on)
	if not keyboard then
		keyboard = CreateFrame('Frame', nil, UIParent)
		keyboard:Hide()
		keyboard:SetScript('OnKeyDown', function(self, key)
			if InCombatLockdown() then return end
			local arrow = ARROWS[key]
			local hub = UI.HubFrame and UI:HubFrame()
			if key == 'ESCAPE' and hub and hub:IsShown() then
				-- The hub open over the editor takes Escape for itself.
				self:SetPropagateKeyboardInput(true)
			elseif key == 'ESCAPE' then
				self:SetPropagateKeyboardInput(false)
				UI:EditConsole(false)
			elseif arrow and selected then
				self:SetPropagateKeyboardInput(false)
				Nudge(arrow[1], arrow[2], IsShiftKeyDown() and GridStep() or nil)
			else
				self:SetPropagateKeyboardInput(true)
			end
		end)
	end
	if InCombatLockdown() then return end
	if on then
		keyboard:Show()
		keyboard:EnableKeyboard(true)
		keyboard:SetPropagateKeyboardInput(true)
	else
		keyboard:EnableKeyboard(false)
		keyboard:Hide()
	end
end

local function BuildOverlay(console)
	overlay = CreateFrame('Frame', nil, console)
	overlay:SetAllPoints()
	overlay:SetFrameStrata('DIALOG')
	overlay:SetFrameLevel(console:GetFrameLevel() + 40)
	overlay:EnableMouse(false)
	-- The header is no place for blocks: printed dim over it.
	overlay.header = overlay:CreateTexture(nil, 'BACKGROUND')
	overlay.header:SetPoint('TOPLEFT')
	overlay.header:SetPoint('TOPRIGHT')
	overlay.header:SetHeight(24)
	overlay.header:SetColorTexture(0, 0, 0, 0.25)
	overlay.hint = Kit:Label(overlay, 'EDITING  -  DRAG BLOCKS, ARROWS NUDGE, RIGHT-CLICK SETTINGS, ESC DONE', 'darkInk', 7, true)
	overlay.hint:SetPoint('TOP', 0, -8)
	overlay:Hide()
end

-- Opening and closing ----------------------------------------------------------------------
function UI:ConsoleEditing() return editing end

-- closing: leaving everything (a fight starting), so edit mode's handles don't come back.
function UI:EditConsole(on, closing)
	if on == nil then on = not editing end
	if on == editing then return end
	if on then
		if InCombatLockdown() then
			Kit:Play('error')
			return UI:Print('The console can be edited once you leave combat.')
		end
		local console = Console()
		if not console then
			return UI:Print('The console editor needs the console bar layout (Action bars, Layout: Console).')
		end
		-- In edit mode the editor takes the handles' place (they would cover
		-- the console's blocks); the edit strip stays.
		fromEditMode = UI.MoversUnlocked and UI:MoversUnlocked() or false
		if UI.SelectMover then UI:SelectMover(nil) end
		if not overlay then BuildOverlay(console) end
		if not inspector then BuildInspector() end
		editing, selected, drag = true, nil, nil
		if fromEditMode and UI.SetEditModeConsole then UI:SetEditModeConsole(true) end
		inspector:ClearAllPoints()
		inspector:SetPoint('BOTTOM', console, 'TOP', 0, 14)
		overlay:Show()
		inspector:Show()
		Keyboard(true)
		Kit:Play('open')
		UI:RelayoutConsole()
		Draw()
	else
		editing, drag = false, nil
		for _, frame in ipairs(blockFrames) do frame:SetScript('OnUpdate', nil) end
		HideGuides()
		if overlay then overlay:Hide() end
		if inspector then inspector:Hide() end
		GameTooltip:Hide()
		Keyboard(false)
		Kit:Play('latch-up')
		-- Back to edit mode's handles, if it is still on.
		if fromEditMode and not closing and not InCombatLockdown() and UI.SetEditModeConsole and UI:MoversUnlocked() then
			UI:SetEditModeConsole(false)
		end
		fromEditMode = false
	end
end

-- Combat ends editing (each change is already saved) and gives the keyboard back.
local watcher = CreateFrame('Frame')
watcher:RegisterEvent('PLAYER_REGEN_DISABLED')
watcher:SetScript('OnEvent', function()
	if editing then UI:EditConsole(false, true) end
end)
