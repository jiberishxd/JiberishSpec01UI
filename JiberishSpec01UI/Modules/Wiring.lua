-- Wiring: circuit traces between the interface's devices, so every part reads
-- as one board.
--
--   * Traces are two-tone, so they read on light and dark ground alike: a dark
--     casing under a lit core, routed with right-angle elbows between two
--     devices. Each end has a keyed connector plug at the device's edge and a
--     round LED in a dark ring; each elbow is a square pad with a lit edge. A
--     small printed label names the link (UF-1 · UF-2). Idle traces can run as
--     fine dashes, like a ribbon cable, and go solid when they carry a signal.
--   * Links: player to target, target to its target, player to pet or focus,
--     unit frames to the console, the aura timeline to the player, the game's
--     swing timers to the console.
--   * Chassis: dark hairline buses along the screen's edges (bottom, and the
--     left and right edges, optionally the top) with a short right-angle feed
--     from each device to its nearest bus, ending in a keyed plug at the
--     device's edge and a pad on the bus, so the whole interface hangs on one
--     frame of lines. Feeds never cross a device: blocked ones step along the
--     edge, or chain into the device in the way. The older rails (a bus with
--     risers) stand down while the chassis is on.
--   * States: a new target draws its trace in from the player with a lit
--     capsule at its head, then holds it lit in the target's reaction color
--     (hostile red, friendly green, neutral amber) and its LEDs on; losing the
--     target pulls the trace back. While a target is held, a quiet packet runs
--     along its trace every few seconds. In combat the target and console traces
--     turn red and carry a packet every few seconds; leaving combat sends one
--     green packet down every trace. Each LED blinks as a packet arrives.
--
-- Everything is drawn on one frame under the devices, from our own frames'
-- geometry (the game's swing timers are read guarded). A link is drawn only
-- while both of its ends are on screen. Paths are worked out again only when
-- something moves, resizes, shows or hides; nothing runs per frame except a
-- running animation.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent = CreateFrame, UIParent
local max, min, abs, floor = math.max, math.min, math.abs, math.floor

local module = UI:RegisterModule('wiring', {always = true})

-- defaults:begin
UI:RegisterDefaults('wiring', {enable = true, style = 'traces', target = true, tot = false, pet = false, focus = false,
	console = false, timeline = false, swing = false, topRail = false, thickness = 2, opacity = 0.85, pulses = true,
	speed = 700, casing = true, nodes = true, labels = false, dashed = false, ambient = false,
	chassis = false, chassisDensity = 'standard', chassisBottom = true, chassisTop = false, chassisLeft = true,
	chassisRight = true, chassisFull = true, chassisColor = 'black', chassisThickness = 1, chassisMoved = false})
-- defaults:end

local function DB() return UI.db.wiring end
local function IsSecret(value) return issecretvalue and issecretvalue(value) end
local function Reduced() return Kit:DB().reduceMotion end
local function Plain(func, ...)
	if type(func) ~= 'function' then return nil end
	local ok, value = pcall(func, ...)
	if not ok or IsSecret(value) then return nil end
	return value
end

local root
local wires = {} -- key -> wire
local fighting = false

-- Geometry ---------------------------------------------------------------------------
local function Snap(value) return UI.Pixel.Snap(root, value) end
local function Px(n) return UI.Pixel.Px(root, n) end

-- A frame's rectangle in the board's units, or nil when it isn't on screen or
-- can't be read plainly.
local function Rect(frame)
	if type(frame) ~= 'table' or not frame.GetRect then return nil end
	if frame.IsForbidden and frame:IsForbidden() then return nil end
	if not Plain(frame.IsVisible, frame) then return nil end
	local alpha = Plain(frame.GetEffectiveAlpha or frame.GetAlpha, frame)
	if type(alpha) == 'number' and alpha < 0.05 then return nil end
	local ok, left, bottom, width, height = pcall(frame.GetRect, frame)
	if not ok or IsSecret(left) or IsSecret(bottom) or IsSecret(width) or IsSecret(height) then return nil end
	if not (left and bottom and width and height) or width < 2 or height < 2 then return nil end
	local scale = Plain(frame.GetEffectiveScale, frame)
	if not scale then return nil end
	local ratio = scale / root:GetEffectiveScale()
	return {l = left * ratio, b = bottom * ratio, r = (left + width) * ratio, t = (bottom + height) * ratio}
end

-- Watch a frame so a move, resize, show or hide re-routes the board.
local watched = setmetatable({}, {__mode = 'k'})
local Queue
local function Watch(frame)
	if type(frame) ~= 'table' or watched[frame] or not frame.HookScript then return end
	if frame.IsForbidden and frame:IsForbidden() then return end
	watched[frame] = true
	for _, script in ipairs({'OnShow', 'OnHide', 'OnSizeChanged'}) do
		pcall(frame.HookScript, frame, script, function() Queue() end)
	end
end

-- Two rectangles joined with right-angle runs: out of the facing sides, an
-- elbow halfway between. nil when they overlap or nearly touch.
local GAP = 10
local function Route(a, b)
	local acx, acy = (a.l + a.r) / 2, (a.b + a.t) / 2
	local bcx, bcy = (b.l + b.r) / 2, (b.b + b.t) / 2
	local sx, sy, ex, ey, across
	if b.l >= a.r + GAP then sx, sy, ex, ey, across = a.r, acy, b.l, bcy, true
	elseif b.r <= a.l - GAP then sx, sy, ex, ey, across = a.l, acy, b.r, bcy, true
	elseif b.b >= a.t + GAP then sx, sy, ex, ey = acx, a.t, bcx, b.b
	elseif b.t <= a.b - GAP then sx, sy, ex, ey = acx, a.b, bcx, b.t
	else return nil end
	sx, sy, ex, ey = Snap(sx), Snap(sy), Snap(ex), Snap(ey)
	if across then
		-- Keep the run level where the two sides overlap vertically.
		local low, high = max(a.b, b.b) + 6, min(a.t, b.t) - 6
		if low <= high then
			local y = Snap(min(max((acy + bcy) / 2, low), high))
			return {{sx, y}, {ex, y}}
		end
		local mx = Snap((sx + ex) / 2)
		return {{sx, sy}, {mx, sy}, {mx, ey}, {ex, ey}}
	end
	local low, high = max(a.l, b.l) + 6, min(a.r, b.r) - 6
	if low <= high then
		local x = Snap(min(max((acx + bcx) / 2, low), high))
		return {{x, sy}, {x, ey}}
	end
	local my = Snap((sy + ey) / 2)
	return {{sx, sy}, {sx, my}, {ex, my}, {ex, ey}}
end

-- Parts ---------------------------------------------------------------------------------
-- Pieces are made as a wire first needs them and kept for reuse.
local function Line(list, index, sublevel, layer)
	local line = list[index]
	if not line then
		line = root:CreateLine(nil, layer or 'ARTWORK', nil, sublevel)
		line:SetColorTexture(1, 1, 1, 1)
		list[index] = line
	end
	return line
end

local function Square(list, index, sublevel)
	local square = list[index]
	if not square then
		square = root:CreateTexture(nil, 'OVERLAY', nil, sublevel)
		square:SetColorTexture(1, 1, 1, 1)
		list[index] = square
	end
	return square
end

-- An end node: a dark ring, a lamp and its glow.
local function Node(wire, index)
	local node = wire.ends[index]
	if node then return node end
	node = {}
	node.ring = Kit:Texture(root, 'circle', 'OVERLAY', 3)
	node.ring:SetVertexColor(0, 0, 0, 0.75)
	node.lamp = Kit:Texture(root, 'circle', 'OVERLAY', 5)
	node.glow = Kit:Texture(root, 'glow', 'OVERLAY', 4)
	node.glow:SetBlendMode('ADD')
	node.plug = root:CreateTexture(nil, 'OVERLAY', nil, 2)
	node.plug:SetColorTexture(1, 1, 1, 1)
	node.key = root:CreateTexture(nil, 'OVERLAY', nil, 3)
	node.key:SetColorTexture(1, 1, 1, 1)
	wire.ends[index] = node
	return node
end

local function HideNode(node)
	for _, part in pairs(node) do if type(part) == 'table' and part.Hide then part:Hide() end end
end

-- Wires --------------------------------------------------------------------------------
local LABELS = {
	target = 'UF-1 · UF-2', tot = 'UF-2 · UF-3', pet = 'UF-1 · PET', focus = 'UF-1 · FOC',
	['console.player'] = 'UF-1 · CX-1', ['console.target'] = 'UF-2 · CX-1', timeline = 'UF-1 · TL-1', rail = 'BUS',
}

local function Wire(key, kind)
	local wire = wires[key]
	if wire then wire.kind = kind or wire.kind return wire end
	wire = {key = key, kind = kind, casing = {}, core = {}, dashes = {}, pads = {}, lits = {}, ends = {}, fraction = 1,
		token = 'darkInk', alpha = 0.85, active = false, shown = false}
	wires[key] = wire
	return wire
end

local function SetPath(wire, points)
	-- Drop zero-length runs.
	local clean = {}
	for _, point in ipairs(points) do
		local last = clean[#clean]
		if not last or abs(last[1] - point[1]) > 0.01 or abs(last[2] - point[2]) > 0.01 then clean[#clean + 1] = point end
	end
	if #clean < 2 then wire.points = nil return end
	wire.points, wire.cum = clean, {0}
	for index = 2, #clean do
		local a, b = clean[index - 1], clean[index]
		wire.cum[index] = wire.cum[index - 1] + abs(b[1] - a[1]) + abs(b[2] - a[2])
	end
	wire.total = wire.cum[#clean]
end

local function PointAt(wire, distance)
	local points, cum = wire.points, wire.cum
	if not points then return 0, 0 end
	distance = min(max(distance, 0), wire.total)
	for index = 2, #points do
		if distance <= cum[index] or index == #points then
			local a, b = points[index - 1], points[index]
			local span = cum[index] - cum[index - 1]
			local t = span > 0 and (distance - cum[index - 1]) / span or 1
			return a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t
		end
	end
	return points[#points][1], points[#points][2]
end

-- The unit direction of the segment at one end, pointing out of the device.
local function Outward(wire, atEnd)
	local points = wire.points
	local a, b
	if atEnd then a, b = points[#points], points[#points - 1] else a, b = points[1], points[2] end
	local dx, dy = b[1] - a[1], b[2] - a[2]
	local length = abs(dx) + abs(dy)
	if length <= 0 then return 1, 0 end
	return dx / length, dy / length
end

local DrawChassis
local function Paint(wire)
	if wire.kind == 'chassis' then return DrawChassis(wire) end
	local db = DB()
	local r, g, b = Kit:RGB(wire.token)
	for _, line in ipairs(wire.core) do line:SetVertexColor(r, g, b, wire.alpha) end
	for _, line in ipairs(wire.dashes) do line:SetVertexColor(r, g, b, wire.alpha) end
	for _, line in ipairs(wire.casing) do line:SetVertexColor(0, 0, 0, db.casing and 0.55 or 0) end
	for _, pad in ipairs(wire.pads) do pad:SetVertexColor(0.04, 0.04, 0.04, 0.85) end
	for _, lit in ipairs(wire.lits) do lit:SetVertexColor(r, g, b, 0.7) end
	local ir, ig, ib = Kit:RGB('darkInk')
	for _, node in ipairs(wire.ends) do
		node.plug:SetVertexColor(0.06, 0.06, 0.06, 0.9)
		node.key:SetVertexColor(ir, ig, ib, 0.55)
		if wire.active then
			node.lamp:SetVertexColor(r, g, b, 1)
			node.glow:SetVertexColor(r, g, b, 0.75)
		else
			local lr, lg, lb = Kit:RGB('ledOff')
			node.lamp:SetVertexColor(lr, lg, lb, 1)
			node.glow:SetVertexColor(r, g, b, 0)
		end
	end
	if wire.label then Kit:Tint(wire.label, wire.active and wire.token or 'legend', wire.active and 0.95 or 0.8) end
end

-- One run drawn as fine dashes along it.
local DASH, SPACE = 4, 3
local function Dashes(wire, used, ax, ay, bx, by, thickness)
	local length = abs(bx - ax) + abs(by - ay)
	if length <= 0 then return used end
	local dash, space = Px(DASH), Px(SPACE)
	local dx, dy = (bx - ax) / length, (by - ay) / length
	local at = 0
	while at < length do
		local stop = min(at + dash, length)
		used = used + 1
		local line = Line(wire.dashes, used, 2)
		line:SetThickness(thickness)
		line:SetStartPoint('BOTTOMLEFT', root, Snap(ax + dx * at), Snap(ay + dy * at))
		line:SetEndPoint('BOTTOMLEFT', root, Snap(ax + dx * stop), Snap(ay + dy * stop))
		line:Show()
		at = stop + space
	end
	return used
end

-- Chassis lines: a dark core with a faint lit edge on one side, square pads at
-- corners and junctions, and a keyed plug where a feed meets its device.
local CHASSIS_COLORS = {
	black = function() return 0.05, 0.05, 0.05, 0.92, 1, 1, 1, 0.22 end,
	ink = function() local r, g, b = Kit:RGB('darkInk') return r, g, b, 0.8, 0, 0, 0, 0.5 end,
	key = function() local r, g, b = Kit:RGB('lamp') return r, g, b, 0.9, 1, 1, 1, 0.3 end,
}
function DrawChassis(wire)
	local db = DB()
	local points = wire.points
	local count = points and wire.shown and #points or 0
	local cr, cg, cb, ca, hr, hg, hb, ha = (CHASSIS_COLORS[db.chassisColor] or CHASSIS_COLORS.black)()
	local core = Px(max(1, db.chassisThickness or 1))
	local edge = Px(1)
	local shift = core / 2 + edge / 2
	for index = 1, max(count - 1, #wire.core) do
		local coreLine, litLine = wire.core[index], wire.casing[index]
		if index < count then
			local a, b = points[index], points[index + 1]
			local across = abs(b[2] - a[2]) < abs(b[1] - a[1])
			local dx, dy = across and 0 or -shift, across and shift or 0
			coreLine = Line(wire.core, index, 1, 'BORDER')
			coreLine:SetThickness(core)
			coreLine:SetStartPoint('BOTTOMLEFT', root, a[1], a[2])
			coreLine:SetEndPoint('BOTTOMLEFT', root, b[1], b[2])
			coreLine:SetVertexColor(cr, cg, cb, ca)
			coreLine:Show()
			litLine = Line(wire.casing, index, 0, 'BORDER')
			litLine:SetThickness(edge)
			litLine:SetStartPoint('BOTTOMLEFT', root, a[1] + dx, a[2] + dy)
			litLine:SetEndPoint('BOTTOMLEFT', root, b[1] + dx, b[2] + dy)
			litLine:SetVertexColor(hr, hg, hb, ha)
			litLine:Show()
		else
			if coreLine then coreLine:Hide() end
			if litLine then litLine:Hide() end
		end
	end
	-- Pads on every corner and at the bus end of a feed (a feed's first point is its plug).
	local padSize, used = Px(4), 0
	for index = 1, count do
		if not (wire.feed and index == 1) and (index > 1 and index < count or wire.feed or wire.bus) then
			used = used + 1
			local pad, lit = Square(wire.pads, used, 4), Square(wire.lits, used, 5)
			pad:SetSize(padSize, padSize)
			pad:ClearAllPoints()
			pad:SetPoint('CENTER', root, 'BOTTOMLEFT', points[index][1], points[index][2])
			pad:SetVertexColor(cr * 0.6, cg * 0.6, cb * 0.6, 1)
			lit:SetSize(padSize, edge)
			lit:ClearAllPoints()
			lit:SetPoint('TOP', pad, 'TOP')
			lit:SetVertexColor(hr, hg, hb, ha + 0.15)
			pad:Show(); lit:Show()
		end
	end
	for index = used + 1, #wire.pads do wire.pads[index]:Hide(); wire.lits[index]:Hide() end
	-- The plug at the device's edge.
	if wire.feed and count > 0 then
		local node = Node(wire, 1)
		local ox, oy = Outward(wire, false)
		local length, width = Px(6), Px(4)
		local across = abs(ox) > abs(oy)
		node.plug:SetSize(across and length or width, across and width or length)
		node.plug:ClearAllPoints()
		node.plug:SetPoint('CENTER', root, 'BOTTOMLEFT', points[1][1] + ox * length / 2, points[1][2] + oy * length / 2)
		node.plug:SetVertexColor(cr * 0.6, cg * 0.6, cb * 0.6, 1)
		node.key:SetSize(across and Px(2) or edge, across and edge or Px(2))
		node.key:ClearAllPoints()
		node.key:SetPoint('CENTER', node.plug, 'CENTER')
		node.key:SetVertexColor(hr, hg, hb, ha + 0.25)
		node.plug:Show(); node.key:Show()
		node.ring:Hide(); node.lamp:Hide(); node.glow:Hide()
	elseif wire.ends[1] then
		HideNode(wire.ends[1])
	end
	if wire.ends[2] then HideNode(wire.ends[2]) end
	if wire.label then wire.label:Hide() end
end

-- Lay the wire out up to its drawn fraction (from its start).
local function Draw(wire)
	if wire.kind == 'chassis' then return DrawChassis(wire) end
	local db = DB()
	local points = wire.points
	local count = points and wire.shown and #points or 0
	local visible = count > 0 and wire.fraction * wire.total or 0
	local core = Px(max(1, db.thickness or 2))
	local casing = core + Px(2)
	local dashed = db.dashed and not wire.active and wire.fraction >= 1
	local dashUsed = 0
	for index = 1, max(count - 1, #wire.core) do
		local coreLine, caseLine = wire.core[index], wire.casing[index]
		if index < count and visible > wire.cum[index] then
			local a = points[index]
			local x, y = PointAt(wire, min(visible, wire.cum[index + 1]))
			caseLine = Line(wire.casing, index, 0)
			caseLine:SetThickness(casing)
			caseLine:SetStartPoint('BOTTOMLEFT', root, a[1], a[2])
			caseLine:SetEndPoint('BOTTOMLEFT', root, x, y)
			caseLine:Show()
			if dashed then
				if coreLine then coreLine:Hide() end
				dashUsed = Dashes(wire, dashUsed, a[1], a[2], x, y, core)
			else
				coreLine = Line(wire.core, index, 1)
				coreLine:SetThickness(core)
				coreLine:SetStartPoint('BOTTOMLEFT', root, a[1], a[2])
				coreLine:SetEndPoint('BOTTOMLEFT', root, x, y)
				coreLine:Show()
			end
		else
			if coreLine then coreLine:Hide() end
			if caseLine then caseLine:Hide() end
		end
	end
	for index = dashUsed + 1, #wire.dashes do wire.dashes[index]:Hide() end
	-- Elbow pads: a dark square with a lit edge along its top.
	local padSize, elbows = Px(5), 0
	if db.nodes then
		for index = 2, count - 1 do
			if visible >= wire.cum[index] then
				elbows = elbows + 1
				local pad, lit = Square(wire.pads, elbows, 4), Square(wire.lits, elbows, 5)
				pad:SetSize(padSize, padSize)
				pad:ClearAllPoints()
				pad:SetPoint('CENTER', root, 'BOTTOMLEFT', points[index][1], points[index][2])
				lit:SetSize(padSize, Px(1))
				lit:ClearAllPoints()
				lit:SetPoint('TOP', pad, 'TOP')
				pad:Show(); lit:Show()
			end
		end
	end
	for index = elbows + 1, #wire.pads do wire.pads[index]:Hide(); wire.lits[index]:Hide() end
	-- End nodes: a keyed plug at the device's edge and a lamp in a ring just out from it.
	for index = 1, 2 do
		local reached = count > 0 and db.nodes and (index == 1 or wire.fraction >= 1)
		local node = wire.ends[index]
		if reached then
			node = Node(wire, index)
			local point = index == 1 and points[1] or points[count]
			local ox, oy = Outward(wire, index == 2)
			local plugLength, plugWidth = Px(7), Px(5)
			local across = abs(ox) > abs(oy)
			node.plug:SetSize(across and plugLength or plugWidth, across and plugWidth or plugLength)
			node.plug:ClearAllPoints()
			node.plug:SetPoint('CENTER', root, 'BOTTOMLEFT', point[1] + ox * plugLength / 2, point[2] + oy * plugLength / 2)
			node.key:SetSize(across and Px(2) or Px(1), across and Px(1) or Px(2))
			node.key:ClearAllPoints()
			node.key:SetPoint('CENTER', node.plug, 'CENTER')
			local lx, ly = point[1] + ox * (plugLength + Px(4)), point[2] + oy * (plugLength + Px(4))
			node.ring:SetSize(Px(9), Px(9))
			node.ring:ClearAllPoints()
			node.ring:SetPoint('CENTER', root, 'BOTTOMLEFT', lx, ly)
			node.lamp:SetSize(Px(5), Px(5))
			node.lamp:ClearAllPoints()
			node.lamp:SetPoint('CENTER', node.ring, 'CENTER')
			node.glow:SetSize(Px(18), Px(18))
			node.glow:ClearAllPoints()
			node.glow:SetPoint('CENTER', node.ring, 'CENTER')
			for _, part in pairs(node) do if type(part) == 'table' and part.Show then part:Show() end end
		elseif node then
			HideNode(node)
		end
	end
	-- The printed label, beside the start.
	local text = db.labels and count > 0 and (LABELS[wire.key] or (wire.key:find('^swing') and 'ST · CX-1'))
	if text then
		if not wire.label then wire.label = Kit:Label(root, text, 'legend', 7, true) end
		wire.label:SetText(text)
		local ox, oy = Outward(wire, false)
		local start = points[1]
		local offset = Px(14)
		wire.label:ClearAllPoints()
		if abs(ox) > abs(oy) then
			wire.label:SetPoint(ox > 0 and 'BOTTOMLEFT' or 'BOTTOMRIGHT', root, 'BOTTOMLEFT', start[1] + ox * offset, start[2] + Px(5))
		else
			wire.label:SetPoint('LEFT', root, 'BOTTOMLEFT', start[1] + Px(7), start[2] + oy * offset)
		end
		wire.label:SetAlpha(min(1, wire.fraction * 2))
		wire.label:Show()
	elseif wire.label then
		wire.label:Hide()
	end
	Paint(wire)
end

local function Hide(wire)
	wire.shown = false
	Draw(wire)
end

-- Packets --------------------------------------------------------------------------------
local pool = {}
local TRAIL = {0.6, 0.35, 0.15}
local function Packet()
	local packet = table.remove(pool)
	if packet then return packet end
	packet = {trail = {}}
	packet.glow = Kit:Texture(root, 'glow', 'OVERLAY', 6)
	packet.glow:SetBlendMode('ADD')
	packet.head = Kit:Texture(root, 'circle', 'OVERLAY', 7)
	for index = 1, #TRAIL do packet.trail[index] = Kit:Texture(root, 'circle', 'OVERLAY', 6) end
	return packet
end

local function Release(packet)
	packet.glow:Hide()
	packet.head:Hide()
	for _, dot in ipairs(packet.trail) do dot:Hide() end
	pool[#pool + 1] = packet
end

-- An LED blinks as a packet arrives.
local function Blink(wire, index)
	local node = wire.ends[index]
	if not (node and wire.shown and node.lamp:IsShown()) or Reduced() then return end
	local r, g, b = Kit:RGB(wire.active and wire.token or 'darkInk')
	Kit:Animate(node, 0.35, 1, 0, function(value)
		node.glow:SetVertexColor(r, g, b, 0.2 + 0.8 * value)
		node.lamp:SetVertexColor(min(1, r + value * 0.5), min(1, g + value * 0.5), min(1, b + value * 0.5), 1)
	end, function() Paint(wire) end, 'sine')
end

-- Send a lit capsule with a short trail along a wire, from one distance to another.
local function Pulse(wire, token, from, to, done)
	if not (wire.points and wire.shown) or Reduced() or not DB().pulses then
		if done then done() end
		return
	end
	from, to = from or 0, to or wire.total
	local packet = Packet()
	local r, g, b = Kit:RGB(token)
	local headSize, glowSize = Px(7), Px(22)
	packet.glow:SetSize(glowSize, glowSize)
	packet.glow:SetVertexColor(r, g, b, 0.9)
	packet.head:SetSize(headSize, headSize)
	packet.head:SetVertexColor(min(1, r + 0.45), min(1, g + 0.45), min(1, b + 0.45), 1)
	for index, dot in ipairs(packet.trail) do
		local size = Px(6 - index)
		dot:SetSize(size, size)
		dot:SetVertexColor(r, g, b, TRAIL[index])
	end
	local direction = to >= from and 1 or -1
	local spacing = Px(5)
	local duration = max(0.2, abs(to - from) / max(DB().speed or 700, 50))
	Kit:Animate(packet, duration, 0, 1, function(value, progress)
		local distance = from + (to - from) * value
		local fade = progress < 0.08 and progress / 0.08 or (progress > 0.9 and (1 - progress) / 0.1 or 1)
		local x, y = PointAt(wire, distance)
		for _, region in ipairs({packet.glow, packet.head}) do
			region:ClearAllPoints()
			region:SetPoint('CENTER', root, 'BOTTOMLEFT', x, y)
			region:SetAlpha(fade)
			region:Show()
		end
		for index, dot in ipairs(packet.trail) do
			local tx, ty = PointAt(wire, distance - direction * spacing * index)
			dot:ClearAllPoints()
			dot:SetPoint('CENTER', root, 'BOTTOMLEFT', tx, ty)
			dot:SetAlpha(fade)
			dot:Show()
		end
	end, function()
		Release(packet)
		Blink(wire, direction > 0 and 2 or 1)
		if done then done() end
	end, 'inout')
end

-- Links -----------------------------------------------------------------------------------
local function Movers()
	local byKey = {}
	for _, entry in ipairs(UI.GetMovers and UI:GetMovers() or {}) do byKey[entry.key] = entry end
	return byKey
end

local function Docked(key) return UI.MoverDocked and UI:MoverDocked(key) end
local function Exists(unit) return Plain(UnitExists, unit) == true end

-- The reaction of the target, as a token.
local function Reaction()
	if Plain(UnitCanAttack, 'player', 'target') == true then return 'red' end
	if Plain(UnitIsFriend, 'player', 'target') == true then return 'green' end
	return 'amber'
end

-- A game swing timer counts only while it is timing (or idling visibly with a weapon).
local function Swinging(frame)
	if type(frame) ~= 'table' then return false end
	local has = Plain(frame.HasSwingTimer, frame)
	return has ~= false
end

-- Each link: its key and its two frames, only while both ends mean something.
local SWING = {'SwingTimerMainHandFrame', 'SwingTimerOffHandFrame', 'SwingTimerRangedFrame'}
local function Links(byKey)
	local db = DB()
	local function Frame(key) return byKey[key] and byKey[key].frame end
	local list = {}
	local function Add(key, on, a, b) if on and a and b then list[#list + 1] = {key = key, a = a, b = b} end end
	local player, target = Frame('uf.player'), Frame('uf.target')
	local hasTarget = Exists('target')
	local bothDocked = Docked('uf.player') and Docked('uf.target')
	Add('target', db.target and hasTarget and not bothDocked, player, target)
	Add('tot', db.tot and hasTarget and Exists('targettarget'), target, Frame('uf.targettarget'))
	Add('pet', db.pet and Exists('pet'), player, Frame('uf.pet'))
	Add('focus', db.focus and Exists('focus'), player, Frame('uf.focus'))
	local console = Frame('ab.console')
	Add('console.player', db.console and not Docked('uf.player'), player, console)
	Add('console.target', db.console and hasTarget and not Docked('uf.target'), target, console)
	local timeline = UI.db.timeline
	Add('timeline', db.timeline and type(timeline) == 'table' and timeline.enable, player, Frame('tl.player'))
	if db.swing then
		for _, name in ipairs(SWING) do
			local frame = _G[name]
			Add('swing.'..name, Swinging(frame), frame, console)
		end
	end
	return list
end

-- Rails: the devices near the bottom (or top) edge, each with a riser.
local function Rails(byKey, list)
	local db = DB()
	local width, height = root:GetSize()
	local devices = {}
	for key, entry in pairs(byKey) do
		if not entry.docked then devices[#devices + 1] = {key = key, frame = entry.frame} end
	end
	devices[#devices + 1] = {key = 'chat', frame = _G.ChatFrame1}
	local edge = Px(4)
	local function Rail(railKey, y, below)
		local any = false
		for _, device in ipairs(devices) do
			Watch(device.frame)
			local rect = Rect(device.frame)
			if rect then
				local near = below and rect.b < height * 0.3 or (not below and rect.t > height * 0.7)
				local gap = below and rect.b - y or y - rect.t
				if near and gap > Px(12) then
					local x = Snap((rect.l + rect.r) / 2)
					list[#list + 1] = {key = railKey..'.'..device.key, points = {{x, below and Snap(rect.b) or Snap(rect.t)}, {x, y}}}
					any = true
				end
			end
		end
		if any then list[#list + 1] = {key = railKey, points = {{Snap(edge * 2), y}, {Snap(width - edge * 2), y}}} end
	end
	Rail('rail', Snap(edge * 2), true)
	if db.topRail then Rail('rail.top', Snap(height - edge * 2), false) end
end

-- Chassis ------------------------------------------------------------------------------
-- Which devices hang on the chassis at each density.
local STANDARD = {'^chat$', '^ab%.', '^dm%.', '^ip%.', '^bags%.', '^tl%.', '^uf%.player$', '^uf%.target$', '^minimap$',
	'^objectives$', '^buffs$'}
local function Wanted(key, density)
	if density == 'minimal' then return false end
	if density == 'full' then return true end
	for _, pattern in ipairs(STANDARD) do if key:find(pattern) then return true end end
	return false
end

-- Devices on screen: our movers plus the game's chat, minimap, tracker and buffs.
local function Devices(byKey)
	local list = {}
	local function Add(key, frame)
		Watch(frame)
		local rect = Rect(frame)
		if rect and rect.r - rect.l >= 12 and rect.t - rect.b >= 8 then list[#list + 1] = {key = key, rect = rect} end
	end
	for key, entry in pairs(byKey) do
		if not entry.docked then Add(key, entry.frame) end
	end
	Add('chat', _G.ChatFrame1)
	Add('minimap', _G.Minimap)
	Add('objectives', _G.ObjectiveTrackerFrame)
	Add('buffs', _G.BuffFrame)
	return list
end

-- Whether an upright or level run crosses any device but the ones named.
local function Blocked(devices, x1, y1, x2, y2, skip, margin)
	local lowX, highX, lowY, highY = min(x1, x2), max(x1, x2), min(y1, y2), max(y1, y2)
	for _, device in ipairs(devices) do
		local r = device.rect
		if device ~= skip and highX > r.l - margin and lowX < r.r + margin and highY > r.b - margin and lowY < r.t + margin then
			return device
		end
	end
	return nil
end

local FRACTIONS = {0.5, 0.3, 0.7, 0.15, 0.85}

-- Every chassis line, by key, into `live`; feeds recorded by device key.
local feeds = {}
local function Chassis(byKey, live)
	local db = DB()
	wipe(feeds)
	local width, height = root:GetSize()
	local inset = Px(6)
	local L, R, B, T = Snap(inset), Snap(width - inset), Snap(inset), Snap(height - inset)
	local density = db.chassisDensity or 'standard'
	local devices = Devices(byKey)
	local sides = {bottom = db.chassisBottom, top = db.chassisTop, left = db.chassisLeft, right = db.chassisRight}
	local used = {bottom = {}, top = {}, left = {}, right = {}}
	local reach = {left = 0, right = 0}
	local spacing, margin = Px(8), Px(2)
	local function Free(side, at)
		for _, other in ipairs(used[side]) do if abs(other - at) < spacing then return false end end
		return true
	end
	for _, device in ipairs(devices) do
		if Wanted(device.key, density) then
			local r = device.rect
			-- The nearest bus that is on.
			local choices = {}
			if sides.bottom then choices[#choices + 1] = {'bottom', r.b - B} end
			if sides.top then choices[#choices + 1] = {'top', T - r.t} end
			if sides.left then choices[#choices + 1] = {'left', r.l - L} end
			if sides.right then choices[#choices + 1] = {'right', R - r.r} end
			table.sort(choices, function(a, b) return a[2] < b[2] end)
			local placed = false
			for _, choice in ipairs(choices) do
				local side = choice[1]
				if choice[2] > Px(4) then
					for _, fraction in ipairs(FRACTIONS) do
						local x1, y1, x2, y2
						if side == 'bottom' or side == 'top' then
							x1 = Snap(r.l + (r.r - r.l) * fraction)
							x2 = x1
							if side == 'bottom' then y1, y2 = Snap(r.b), B else y1, y2 = Snap(r.t), T end
						else
							y1 = Snap(r.b + (r.t - r.b) * fraction)
							y2 = y1
							if side == 'left' then x1, x2 = Snap(r.l), L else x1, x2 = Snap(r.r), R end
						end
						local along = (side == 'bottom' or side == 'top') and x1 or y1
						if Free(side, along) then
							local blocker = Blocked(devices, x1, y1, x2, y2, device, margin)
							if not blocker then
								used[side][#used[side] + 1] = along
								live['ch.'..device.key] = {kind = 'chassis', feed = true, points = {{x1, y1}, {x2, y2}}}
								feeds[device.key] = {bus = (side == 'top') and 'ch.top' or 'ch.main', x = x2, y = y2}
								if side == 'left' or side == 'right' then reach[side] = max(reach[side], y2) end
								placed = true
							elseif fraction == FRACTIONS[#FRACTIONS] and (side == 'bottom' or side == 'top') then
								-- No clear column: chain into the device in the way instead.
								local br = blocker.rect
								local cx = Snap(min(max(x1, br.l + Px(6)), br.r - Px(6)))
								local cy = side == 'bottom' and Snap(br.t) or Snap(br.b)
								live['ch.'..device.key] = {kind = 'chassis', feed = true, points = {{cx, y1}, {cx, cy}}}
								placed = true
							end
						end
						if placed then break end
					end
				end
				if placed then break end
			end
		end
	end
	-- The buses: bottom across (turning up the left and right edges), top across.
	local full = db.chassisFull or density == 'minimal'
	local leftTop = density == 'minimal' and (sides.top and T or Snap(height * 0.6)) or max(reach.left, Snap(height * 0.25))
	local rightTop = density == 'minimal' and (sides.top and T or Snap(height * 0.6)) or max(reach.right, Snap(height * 0.25))
	if sides.top then leftTop, rightTop = T, T end
	local lowX, highX = R, L
	for _, at in ipairs(used.bottom) do lowX, highX = min(lowX, at), max(highX, at) end
	local main = {}
	if sides.left then main[#main + 1] = {L, leftTop}; main[#main + 1] = {L, B}
	elseif sides.bottom then main[#main + 1] = {full and L or Snap(lowX - Px(12)), B} end
	if sides.bottom or (sides.left and sides.right) then
		if sides.right then main[#main + 1] = {R, B}; main[#main + 1] = {R, rightTop}
		else main[#main + 1] = {full and R or Snap(highX + Px(12)), B} end
	elseif sides.right then main = {{R, B}, {R, rightTop}} end
	if #main >= 2 and (full or #used.bottom > 0 or #used.left > 0 or #used.right > 0) then
		live['ch.main'] = {kind = 'chassis', bus = true, points = main}
	end
	if sides.top then live['ch.top'] = {kind = 'chassis', bus = true, points = {{L, T}, {R, T}}} end
end

-- How far along a wire a point on it lies.
local function DistanceOn(wire, x, y)
	local points, cum = wire.points, wire.cum
	if not points then return nil end
	local best, bestGap
	for index = 2, #points do
		local a, b = points[index - 1], points[index]
		local lowX, highX, lowY, highY = min(a[1], b[1]), max(a[1], b[1]), min(a[2], b[2]), max(a[2], b[2])
		local cx, cy = min(max(x, lowX), highX), min(max(y, lowY), highY)
		local gap = abs(cx - x) + abs(cy - y)
		if not bestGap or gap < bestGap then
			bestGap, best = gap, cum[index - 1] + abs(cx - a[1]) + abs(cy - a[2])
		end
	end
	return best
end

-- A packet down one device's feed, along the bus, and up another's.
local function Relay(fromKey, toKey, token)
	local from, to = feeds[fromKey], feeds[toKey]
	local feedA, feedB = wires['ch.'..fromKey], wires['ch.'..toKey]
	if not (from and to and from.bus == to.bus and feedA and feedB and feedA.shown and feedB.shown) then return end
	local bus = wires[from.bus]
	if not (bus and bus.shown) then return end
	local d1, d2 = DistanceOn(bus, from.x, from.y), DistanceOn(bus, to.x, to.y)
	if not (d1 and d2) then return end
	Pulse(feedA, token, 0, feedA.total, function()
		Pulse(bus, token, d1, d2, function()
			Pulse(feedB, token, feedB.total, 0)
		end)
	end)
end

-- State: which wires carry a signal, and in what color.
local LIVE = {target = true, ['console.player'] = true, ['console.target'] = true}
local function Restyle(wire)
	if wire.kind == 'chassis' then return Draw(wire) end
	local db = DB()
	local idle = db.opacity or 0.85
	wire.token, wire.alpha, wire.active = 'darkInk', idle, false
	if fighting and (LIVE[wire.key] or wire.key == 'rail') then
		wire.token, wire.alpha, wire.active = 'red', 1, true
	elseif wire.key == 'target' or wire.key == 'tot' or wire.key == 'console.target' then
		wire.token, wire.alpha, wire.active = Reaction(), 1, true
	end
	Draw(wire)
end

-- Work out every path again and draw them.
local function Rebuild()
	if not root then return end
	local db = DB()
	local live = {}
	if db.enable then
		local byKey = Movers()
		local style = db.style or 'traces'
		if style ~= 'rails' then
			for _, link in ipairs(Links(byKey)) do
				Watch(link.a)
				Watch(link.b)
				local a, b = Rect(link.a), Rect(link.b)
				local points = a and b and Route(a, b)
				if points then live[link.key] = points end
			end
		end
		if db.chassis then
			UI:Safe(Chassis, byKey, live)
		elseif style ~= 'traces' then
			local list = {}
			Rails(byKey, list)
			for _, item in ipairs(list) do live[item.key] = item.points end
		end
	end
	for key, spec in pairs(live) do
		local points = spec.points or spec
		local wire = Wire(key, spec.kind)
		wire.feed, wire.bus = spec.feed, spec.bus
		if not wire.retracting then
			SetPath(wire, points)
			wire.shown = wire.points ~= nil
			if not Kit:Animating(wire) then wire.fraction = 1 end
			Restyle(wire)
		end
	end
	for key, wire in pairs(wires) do
		if not live[key] and wire.shown and not wire.retracting then Hide(wire) end
	end
end

local queued = false
function Queue()
	if queued then return end
	queued = true
	C_Timer.After(0, function()
		queued = false
		UI:Safe(Rebuild)
	end)
end

-- Events ---------------------------------------------------------------------------------
local ambient
local function Ambient()
	if ambient then ambient:Cancel(); ambient = nil end
	if not (DB().ambient and DB().enable) or Reduced() then return end
	ambient = C_Timer.NewTicker(4, function()
		if fighting then return end
		for _, key in ipairs({'target', 'tot'}) do
			local wire = wires[key]
			if wire and wire.shown and not wire.retracting and not Kit:Animating(wire) then
				UI:Safe(Pulse, wire, wire.token)
			end
		end
	end)
end

-- A new target draws its trace in from the player; a lost one pulls it back.
local function TargetChanged()
	local wire = wires.target
	if Exists('target') then
		if wire then wire.retracting = nil end
		Rebuild()
		wire = wires.target
		if wire and wire.shown then
			if Reduced() then wire.fraction = 1; Draw(wire) return end
			Kit:Animate(wire, 0.35, 0, 1, function(value)
				wire.fraction = value
				Draw(wire)
			end, function() wire.fraction = 1; Draw(wire) end, 'cubic')
			Pulse(wire, Reaction(), 0, wire.total)
		end
		-- And along the chassis: down the player's feed, along the bus, up the target's.
		if DB().chassis then Relay('uf.player', 'uf.target', Reaction()) end
	elseif wire and wire.shown and not Reduced() then
		wire.retracting = true
		Kit:Animate(wire, 0.28, wire.fraction or 1, 0, function(value)
			wire.fraction = value
			Draw(wire)
		end, function()
			wire.retracting = nil
			wire.fraction = 1
			Hide(wire)
			Rebuild()
		end, 'cubic')
		-- The other target links have no target to point at any more.
		for _, key in ipairs({'tot', 'console.target'}) do if wires[key] and wires[key].shown then Hide(wires[key]) end end
	else
		if wire then wire.retracting = nil end
		Rebuild()
	end
end

local ticker
local function PulseLive(token)
	for key, wire in pairs(wires) do
		if wire.shown and (LIVE[key] or key == 'rail' or key == 'ch.main') then Pulse(wire, token) end
	end
end

local function CombatChanged(entering)
	fighting = entering
	for _, wire in pairs(wires) do if wire.shown then Restyle(wire) end end
	if ticker then ticker:Cancel(); ticker = nil end
	if entering then
		PulseLive('red')
		ticker = C_Timer.NewTicker(3.2, function()
			if fighting then UI:Safe(PulseLive, 'red') end
		end)
	else
		-- One green packet down every trace and the main bus, then the board settles.
		for key, wire in pairs(wires) do
			if wire.shown and (wire.kind ~= 'chassis' or key == 'ch.main') then Pulse(wire, 'green') end
		end
	end
end

function module:Enable()
	-- 0.5.2: the first build saved faint traces (1 px at 35%); move once to the new look.
	local saved = UI.db.wiring
	if type(saved) == 'table' and not saved.upgraded then
		if saved.opacity and saved.opacity <= 0.35 then saved.opacity = 0.85 end
		if saved.thickness and saved.thickness < 2 then saved.thickness = 2 end
		saved.upgraded = 1
	end
	-- 0.5.2: the chassis joins the board; the timeline trace and dashed idle traces go off. Once.
	if type(saved) == 'table' and not saved.chassisMoved then
		saved.chassis, saved.timeline, saved.dashed, saved.chassisMoved = true, false, false, true
	end
	-- 0.5.2: in game the traces read as stray lines rather than hardware; off
	-- for everyone once, until a better design replaces them.
	if type(saved) == 'table' and not saved.offMoved then
		saved.enable, saved.offMoved = false, true
	end
	-- 0.5.2: wiring comes back as one link: player to target, while a target
	-- exists. Every other trace, the chassis, labels and ambient packets go off. Once.
	if type(saved) == 'table' and not saved.targetOnly then
		saved.enable, saved.style, saved.target, saved.chassis = true, 'traces', true, false
		saved.tot, saved.pet, saved.focus, saved.console, saved.timeline, saved.swing = false, false, false, false, false, false
		saved.labels, saved.dashed, saved.ambient, saved.targetOnly = false, false, false, true
	end
	root = CreateFrame('Frame', 'JiberishSpec01Wiring', UIParent)
	root:SetAllPoints()
	root:SetFrameStrata('BACKGROUND')
	root:SetFrameLevel(1)
	root:EnableMouse(false)
	local events = CreateFrame('Frame')
	for _, event in ipairs({'PLAYER_TARGET_CHANGED', 'PLAYER_REGEN_DISABLED', 'PLAYER_REGEN_ENABLED', 'UNIT_PET',
		'PLAYER_FOCUS_CHANGED', 'UNIT_TARGET', 'PLAYER_ENTERING_WORLD', 'UNIT_FACTION'}) do
		pcall(events.RegisterEvent, events, event)
	end
	events:SetScript('OnEvent', function(_, event, unit)
		if event == 'PLAYER_TARGET_CHANGED' then UI:Safe(TargetChanged)
		elseif event == 'PLAYER_REGEN_DISABLED' then UI:Safe(CombatChanged, true)
		elseif event == 'PLAYER_REGEN_ENABLED' then UI:Safe(CombatChanged, false)
		elseif event == 'UNIT_PET' then if unit == 'player' then Queue() end
		elseif event == 'UNIT_TARGET' or event == 'UNIT_FACTION' then if unit == 'target' then Queue() end
		elseif event == 'PLAYER_ENTERING_WORLD' then
			Queue()
			-- Frames built after login settle a moment later.
			C_Timer.After(1, Queue)
		else Queue() end
	end)
	-- The swing timers show and hide as weapons swing; follow them.
	for _, name in ipairs(SWING) do
		local frame = _G[name]
		if type(frame) == 'table' then
			for _, method in ipairs({'ResetSwingTimer', 'ClearSwingTimer', 'UpdateShownState'}) do
				if type(frame[method]) == 'function' then hooksecurefunc(frame, method, function() Queue() end) end
			end
		end
	end
	if UI.OnMoversChanged then UI:OnMoversChanged(function() Queue() end) end
	if UI.Pixel and UI.Pixel.OnChange then UI.Pixel.OnChange(function() Queue() end) end
	Kit:OnRefresh(function() for _, wire in pairs(wires) do if wire.shown then Restyle(wire) end end end)
	Ambient()
	Queue()
	self.ready = true
end

function module:Refresh()
	if not self.ready then return end
	Ambient()
	for _, wire in pairs(wires) do if wire.shown then Restyle(wire) end end
	Queue()
end

-- Previews for the page: a packet down every trace, and a fight starting and ending.
function module:Preview(kind)
	if not root then return end
	if kind == 'combat' then
		if fighting then return end
		CombatChanged(true)
		C_Timer.After(3.6, function() if not InCombatLockdown() then CombatChanged(false) end end)
	else
		for key, wire in pairs(wires) do
			if wire.shown and (wire.kind ~= 'chassis' or key == 'ch.main' or key == 'ch.top') then
				Pulse(wire, wire.active and wire.token or 'lamp')
			end
		end
	end
end

-- Hub -----------------------------------------------------------------------------------
local function Off() return not DB().enable end
local function Percent(value) return format('%d%%', value * 100 + 0.5) end
local function Whole(value) return format('%d', floor(value + 0.5)) end
UI:RegisterPage('wiring', {title = 'Wiring', order = 4.25, cards = {
	{title = 'Wiring', rows = {
		{'switch', 'Wiring', 'wiring.enable', 'Two-tone traces join the interface\'s devices, so every part reads as one board.', since = '0.5.2'},
		{'segmented', 'Style', 'wiring.style', items = {{'traces', 'Traces'}, {'rails', 'Rails'}, {'both', 'Both'}},
			note = 'Traces join devices to each other. Rails run a bus along the screen edge with a riser into each device near it.',
			disabled = Off, since = '0.5.2'},
		{'slider', 'Line', 'wiring.thickness', 1, 3, 1, 'Width of the lit core in screen pixels.', format = Whole, disabled = Off, since = '0.5.2'},
		{'slider', 'Opacity', 'wiring.opacity', 0.3, 1, 0.05, 'How strongly idle traces show; traces carrying a signal are full.', format = Percent, disabled = Off, since = '0.5.2'},
		{'button', 'Preview', 'Packets', function() module:Preview('target') end, 'A packet down every trace.'},
		{'button', 'Preview', 'Fight', function() module:Preview('combat') end, 'A fight starting, then ending a few seconds later.'},
	}},
	{title = 'Chassis', rows = {
		{'switch', 'Chassis', 'wiring.chassis', 'Dark buses along the screen edges with a short feed into every device, so the whole interface hangs on one frame of lines.', disabled = Off, since = '0.5.2'},
		{'segmented', 'Density', 'wiring.chassisDensity', items = {{'minimal', 'Minimal'}, {'standard', 'Standard'}, {'full', 'Full'}},
			note = 'Minimal: the buses only. Standard: bars, chat, meters, info panel, bags, minimap, tracker, buffs, timeline, player and target. Full: every device.',
			disabled = Off, since = '0.5.2'},
		{'switch', 'Bottom bus', 'wiring.chassisBottom', nil, disabled = Off, since = '0.5.2'},
		{'switch', 'Left edge', 'wiring.chassisLeft', nil, disabled = Off, since = '0.5.2'},
		{'switch', 'Right edge', 'wiring.chassisRight', nil, disabled = Off, since = '0.5.2'},
		{'switch', 'Top bus', 'wiring.chassisTop', nil, disabled = Off, since = '0.5.2'},
		{'switch', 'Full width', 'wiring.chassisFull', 'The bottom bus spans the whole screen rather than just its devices.', disabled = Off, since = '0.5.2'},
		{'segmented', 'Color', 'wiring.chassisColor', items = {{'black', 'Black'}, {'ink', 'Ink'}, {'key', 'Key color'}}, disabled = Off, since = '0.5.2'},
		{'slider', 'Thickness', 'wiring.chassisThickness', 1, 2, 1, 'Width of the dark core in screen pixels.', format = Whole, disabled = Off, since = '0.5.2'},
	}},
	{title = 'Look', rows = {
		{'switch', 'Casing', 'wiring.casing', 'A dark edge under the lit core, so traces read on bright ground.', disabled = Off, since = '0.5.2'},
		{'switch', 'Nodes', 'wiring.nodes', 'Keyed plugs and lamps at each end, square pads at each elbow.', disabled = Off, since = '0.5.2'},
		{'switch', 'Labels', 'wiring.labels', 'A small printed name for each link, such as UF-1 · UF-2.', disabled = Off, since = '0.5.2'},
		{'switch', 'Dashed when idle', 'wiring.dashed', 'Idle traces run as fine dashes, like a ribbon cable, and go solid when they carry a signal.', disabled = Off, since = '0.5.2'},
	}},
	{title = 'Signals', rows = {
		{'switch', 'Pulses', 'wiring.pulses', 'A lit capsule runs along a trace when something happens: a new target, a fight starting or ending.', disabled = Off, since = '0.5.2'},
		{'switch', 'Ambient packets', 'wiring.ambient', 'While you hold a target, a quiet packet runs along its trace every few seconds.', disabled = Off, since = '0.5.2'},
		{'slider', 'Packet speed', 'wiring.speed', 200, 1600, 50, nil, format = Whole, disabled = Off, since = '0.5.2'},
	}},
	{title = 'Links', rows = {
		{'switch', 'Player and target', 'wiring.target', 'Drawn while you have a target and the frames aren\'t both docked in the console.', disabled = Off, since = '0.5.2'},
		{'switch', 'Target of target', 'wiring.tot', nil, disabled = Off, since = '0.5.2'},
		{'switch', 'Pet', 'wiring.pet', nil, disabled = Off, since = '0.5.2'},
		{'switch', 'Focus', 'wiring.focus', nil, disabled = Off, since = '0.5.2'},
		{'switch', 'Unit frames to console', 'wiring.console', 'When a unit frame isn\'t docked in the console.', disabled = Off, since = '0.5.2'},
		{'switch', 'Aura timeline', 'wiring.timeline', 'A signal trace from the player frame to the aura timeline. The chassis feeds the timeline either way.', disabled = Off, since = '0.5.2'},
		{'switch', 'Swing timers', 'wiring.swing', 'Only while a swing timer is timing.', disabled = Off, since = '0.5.2'},
		{'switch', 'Top rail', 'wiring.topRail', 'Rails style only (when the chassis is off): a second rail along the top edge.', disabled = Off, since = '0.5.2'},
	}},
}})
