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
--   * Rails: a bus along the bottom of the screen (and optionally the top) with
--     risers up into every device that sits near it, like a backplane.
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
UI:RegisterDefaults('wiring', {enable = true, style = 'traces', target = true, tot = true, pet = true, focus = false,
	console = true, timeline = true, swing = true, topRail = false, thickness = 2, opacity = 0.85, pulses = true,
	speed = 700, casing = true, nodes = true, labels = true, dashed = true, ambient = true})
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
local function Line(list, index, sublevel)
	local line = list[index]
	if not line then
		line = root:CreateLine(nil, 'ARTWORK', nil, sublevel)
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

local function Wire(key)
	local wire = wires[key]
	if wire then return wire end
	wire = {key = key, casing = {}, core = {}, dashes = {}, pads = {}, lits = {}, ends = {}, fraction = 1,
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

local function Paint(wire)
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

-- Lay the wire out up to its drawn fraction (from its start).
local function Draw(wire)
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

-- State: which wires carry a signal, and in what color.
local LIVE = {target = true, ['console.player'] = true, ['console.target'] = true}
local function Restyle(wire)
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
		if style ~= 'traces' then
			local list = {}
			Rails(byKey, list)
			for _, item in ipairs(list) do live[item.key] = item.points end
		end
	end
	for key, points in pairs(live) do
		local wire = Wire(key)
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
		if wire.shown and (LIVE[key] or key == 'rail') then Pulse(wire, token) end
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
		-- One green packet down every trace, then the board settles.
		for _, wire in pairs(wires) do if wire.shown then Pulse(wire, 'green') end end
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
		for _, wire in pairs(wires) do if wire.shown then Pulse(wire, wire.active and wire.token or 'lamp') end end
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
		{'switch', 'Aura timeline', 'wiring.timeline', 'Player frame to the aura timeline, while the timeline is on.', disabled = Off, since = '0.5.2'},
		{'switch', 'Swing timers', 'wiring.swing', 'Only while a swing timer is timing.', disabled = Off, since = '0.5.2'},
		{'switch', 'Top rail', 'wiring.topRail', 'A second bus along the top edge, for the minimap and info panel.', disabled = Off, since = '0.5.2'},
	}},
}})
