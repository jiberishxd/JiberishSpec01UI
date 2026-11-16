-- Wiring: circuit traces between the interface's devices, so every part reads
-- as one board.
--
--   * Traces: hairlines routed with right-angle elbows between two devices,
--     with square solder pads where a trace meets an edge and at each elbow:
--     player to target, target to its target, player to pet, the unit frames to
--     the console, the aura timeline to the player, the swing timer to the console.
--   * Rails: a baseline along the bottom of the screen (and optionally the top)
--     with risers up into every device that sits near it, like a backplane.
--   * States: idle traces are dim ink. A new target draws its trace in from the
--     player with a lit packet at the head, then holds it in the target's
--     reaction color (hostile red, friendly green, neutral amber); losing the
--     target pulls it back. In combat the target and console traces turn red
--     and a packet runs along them every few seconds; leaving combat sends one
--     green packet down every trace before they dim again.
--
-- Everything is drawn on one frame under the devices, from our own frames'
-- geometry (the game's swing timers are read guarded). Paths are worked out
-- again only when something moves, resizes, shows or hides; nothing runs per
-- frame except a running animation.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent = CreateFrame, UIParent
local max, min, abs = math.max, math.min, math.abs

local module = UI:RegisterModule('wiring', {always = true})

-- defaults:begin
UI:RegisterDefaults('wiring', {enable = true, style = 'traces', target = true, tot = true, pet = true, focus = false,
	console = true, timeline = true, swing = true, topRail = false, thickness = 1, opacity = 0.35, pulses = true,
	speed = 700})
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
	local shown = Plain(frame.IsVisible, frame)
	if not shown then return nil end
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
-- elbow halfway between. nil when they overlap.
local GAP = 4
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
		local low, high = max(a.b, b.b) + 3, min(a.t, b.t) - 3
		if low <= high then
			local y = Snap(min(max((acy + bcy) / 2, low), high))
			return {{sx, y}, {ex, y}}
		end
		local mx = Snap((sx + ex) / 2)
		return {{sx, sy}, {mx, sy}, {mx, ey}, {ex, ey}}
	end
	local low, high = max(a.l, b.l) + 3, min(a.r, b.r) - 3
	if low <= high then
		local x = Snap(min(max((acx + bcx) / 2, low), high))
		return {{x, sy}, {x, ey}}
	end
	local my = Snap((sy + ey) / 2)
	return {{sx, sy}, {sx, my}, {ex, my}, {ex, ey}}
end

-- Wires --------------------------------------------------------------------------------
local function Wire(key)
	local wire = wires[key]
	if wire then return wire end
	wire = {key = key, lines = {}, nodes = {}, fraction = 1, token = 'rule', alpha = 0.35, shown = false}
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

local function Paint(wire)
	local r, g, b = Kit:RGB(wire.token)
	for _, line in ipairs(wire.lines) do line:SetVertexColor(r, g, b, wire.alpha) end
	for _, node in ipairs(wire.nodes) do node:SetVertexColor(r, g, b, min(1, wire.alpha * 1.5)) end
end

-- Lay the wire out up to its drawn fraction (from its start).
local function Draw(wire)
	local points = wire.points
	local count = points and wire.shown and #points or 0
	local visible = count > 0 and wire.fraction * wire.total or 0
	local thickness = Px(max(1, DB().thickness or 1))
	local pad = Px(3)
	for index = 1, max(count - 1, #wire.lines) do
		local line = wire.lines[index]
		if index < count and visible > wire.cum[index] then
			if not line then
				line = root:CreateLine(nil, 'ARTWORK')
				line:SetColorTexture(1, 1, 1, 1)
				wire.lines[index] = line
			end
			local a = points[index]
			local x, y = PointAt(wire, min(visible, wire.cum[index + 1]))
			line:SetThickness(thickness)
			line:SetStartPoint('BOTTOMLEFT', root, a[1], a[2])
			line:SetEndPoint('BOTTOMLEFT', root, x, y)
			line:Show()
		elseif line then
			line:Hide()
		end
	end
	for index = 1, max(count, #wire.nodes) do
		local node = wire.nodes[index]
		local reached = index <= count and (visible >= wire.cum[index] - 0.01) and (index < count or wire.fraction >= 1)
		if reached then
			if not node then
				node = root:CreateTexture(nil, 'ARTWORK', nil, 2)
				node:SetColorTexture(1, 1, 1, 1)
				wire.nodes[index] = node
			end
			node:SetSize(pad, pad)
			node:ClearAllPoints()
			node:SetPoint('CENTER', root, 'BOTTOMLEFT', points[index][1], points[index][2])
			node:Show()
		elseif node then
			node:Hide()
		end
	end
	Paint(wire)
end

local function Hide(wire)
	wire.shown = false
	Draw(wire)
end

-- Packets --------------------------------------------------------------------------------
local pool = {}
local function Packet()
	local packet = table.remove(pool)
	if packet then return packet end
	packet = {}
	packet.glow = Kit:Texture(root, 'glow', 'OVERLAY', 1)
	packet.glow:SetBlendMode('ADD')
	packet.dot = root:CreateTexture(nil, 'OVERLAY', nil, 3)
	packet.dot:SetColorTexture(1, 1, 1, 1)
	return packet
end

local function Release(packet)
	packet.glow:Hide()
	packet.dot:Hide()
	pool[#pool + 1] = packet
end

-- Send a lit packet along a wire, from one distance to another.
local function Pulse(wire, token, from, to, done)
	if not (wire.points and wire.shown) or Reduced() or not DB().pulses then
		if done then done() end
		return
	end
	from, to = from or 0, to or wire.total
	local packet = Packet()
	local r, g, b = Kit:RGB(token)
	local size = Px(16)
	packet.glow:SetSize(size, size)
	packet.glow:SetVertexColor(r, g, b, 0.9)
	packet.dot:SetSize(Px(3), Px(3))
	packet.dot:SetVertexColor(min(1, r + 0.4), min(1, g + 0.4), min(1, b + 0.4), 1)
	packet.glow:Show()
	packet.dot:Show()
	local duration = max(0.18, abs(to - from) / max(DB().speed or 700, 50))
	Kit:Animate(packet, duration, 0, 1, function(value, progress)
		local x, y = PointAt(wire, from + (to - from) * value)
		packet.glow:ClearAllPoints()
		packet.glow:SetPoint('CENTER', root, 'BOTTOMLEFT', x, y)
		packet.dot:ClearAllPoints()
		packet.dot:SetPoint('CENTER', root, 'BOTTOMLEFT', x, y)
		local fade = progress < 0.1 and progress / 0.1 or (progress > 0.85 and (1 - progress) / 0.15 or 1)
		packet.glow:SetAlpha(fade)
		packet.dot:SetAlpha(fade)
	end, function()
		Release(packet)
		if done then done() end
	end, 'inout')
end

-- Connections ----------------------------------------------------------------------------
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

-- Each connection: its key, its setting, and its two frames (or nil).
local SWING = {'SwingTimerMainHandFrame', 'SwingTimerOffHandFrame', 'SwingTimerRangedFrame'}
local function Connections(byKey)
	local db = DB()
	local function Frame(key) return byKey[key] and byKey[key].frame end
	local list = {}
	local function Add(key, on, a, b) if on and a and b then list[#list + 1] = {key = key, a = a, b = b} end end
	local player, target = Frame('uf.player'), Frame('uf.target')
	local bothDocked = Docked('uf.player') and Docked('uf.target')
	Add('target', db.target and Exists('target') and not bothDocked, player, target)
	Add('tot', db.tot and Exists('targettarget'), target, Frame('uf.targettarget'))
	Add('pet', db.pet and Exists('pet'), player, Frame('uf.pet'))
	Add('focus', db.focus and Exists('focus'), player, Frame('uf.focus'))
	local console = Frame('ab.console')
	Add('console.player', db.console and not Docked('uf.player'), player, console)
	Add('console.target', db.console and Exists('target') and not Docked('uf.target'), target, console)
	Add('timeline', db.timeline, player, Frame('tl.player'))
	if db.swing then
		for _, name in ipairs(SWING) do Add('swing.'..name, true, _G[name], console) end
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
				if near and gap > Px(2) then
					local x = Snap((rect.l + rect.r) / 2)
					list[#list + 1] = {key = railKey..'.'..device.key, points = {{x, y}, {x, below and Snap(rect.b) or Snap(rect.t)}}}
					any = true
				end
			end
		end
		if any then list[#list + 1] = {key = railKey, points = {{Snap(edge * 2), y}, {Snap(width - edge * 2), y}}, rail = true} end
	end
	Rail('rail', Snap(edge), true)
	if db.topRail then Rail('rail.top', Snap(height - edge), false) end
end

-- Colors for a wire in the current state.
local LIVE = {target = true, ['console.player'] = true, ['console.target'] = true}
local function Restyle(wire)
	local db = DB()
	local idle = db.opacity or 0.35
	local lit = min(1, idle + 0.45)
	wire.token, wire.alpha = 'rule', idle
	if fighting and (LIVE[wire.key] or wire.key == 'rail') then
		wire.token, wire.alpha = 'red', wire.key == 'rail' and min(1, idle + 0.15) or lit
	elseif wire.key == 'target' or wire.key == 'tot' or wire.key == 'console.target' then
		wire.token, wire.alpha = Reaction(), lit
	end
	Paint(wire)
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
			for _, connection in ipairs(Connections(byKey)) do
				Watch(connection.a)
				Watch(connection.b)
				local a, b = Rect(connection.a), Rect(connection.b)
				local points = a and b and Route(a, b)
				if points then live[connection.key] = points end
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
		SetPath(wire, points)
		wire.shown = wire.points ~= nil
		if not Kit:Animating(wire) then wire.fraction = 1 end
		Restyle(wire)
		Draw(wire)
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
-- A new target draws its trace in from the player; a lost one pulls it back.
local function TargetChanged()
	local wire = wires.target
	if Exists('target') then
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
			Hide(wire)
			wire.fraction = 1
			Rebuild()
		end, 'cubic')
	else
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
	if UI.OnMoversChanged then UI:OnMoversChanged(function() Queue() end) end
	if UI.Pixel and UI.Pixel.OnChange then UI.Pixel.OnChange(function() Queue() end) end
	Kit:OnRefresh(function() for _, wire in pairs(wires) do if wire.shown then Restyle(wire) end end end)
	Queue()
end

function module:Refresh()
	Queue()
end

-- Previews for the page: a target arriving, and a fight starting and ending.
function module:Preview(kind)
	if not root then return end
	if kind == 'combat' then
		if fighting then return end
		CombatChanged(true)
		C_Timer.After(3.6, function() if not InCombatLockdown() then CombatChanged(false) end end)
	else
		for _, wire in pairs(wires) do if wire.shown then Pulse(wire, 'lamp') end end
	end
end

-- Hub -----------------------------------------------------------------------------------
local function Off() return not DB().enable end
local function Percent(value) return format('%d%%', value * 100 + 0.5) end
local function Whole(value) return format('%d', value + 0.5) end
UI:RegisterPage('wiring', {title = 'Wiring', order = 4.25, cards = {
	{title = 'Wiring', rows = {
		{'switch', 'Wiring', 'wiring.enable', 'Hairline traces join the interface\'s devices, so every part reads as one board.', since = '0.5.2'},
		{'segmented', 'Style', 'wiring.style', items = {{'traces', 'Traces'}, {'rails', 'Rails'}, {'both', 'Both'}},
			note = 'Traces join devices to each other. Rails run a baseline along the screen edge with a riser into each device near it.',
			disabled = Off, since = '0.5.2'},
		{'switch', 'Pulses', 'wiring.pulses', 'A lit packet runs along a trace when something happens: a new target, a fight starting or ending.', disabled = Off, since = '0.5.2'},
		{'slider', 'Line', 'wiring.thickness', 1, 2, 1, 'Width in screen pixels.', format = Whole, disabled = Off, since = '0.5.2'},
		{'slider', 'Opacity', 'wiring.opacity', 0.1, 0.8, 0.05, 'How strongly idle traces show; lit ones are brighter.', format = Percent, disabled = Off, since = '0.5.2'},
		{'slider', 'Packet speed', 'wiring.speed', 200, 1600, 50, nil, format = Whole, disabled = Off, since = '0.5.2'},
		{'button', 'Preview', 'Target', function() module:Preview('target') end, 'A packet down every trace.'},
		{'button', 'Preview', 'Fight', function() module:Preview('combat') end, 'A fight starting, then ending a few seconds later.'},
	}},
	{title = 'Traces', rows = {
		{'switch', 'Player and target', 'wiring.target', 'Drawn while you have a target and the frames aren\'t both docked in the console.', disabled = Off, since = '0.5.2'},
		{'switch', 'Target of target', 'wiring.tot', nil, disabled = Off, since = '0.5.2'},
		{'switch', 'Pet', 'wiring.pet', nil, disabled = Off, since = '0.5.2'},
		{'switch', 'Focus', 'wiring.focus', nil, disabled = Off, since = '0.5.2'},
		{'switch', 'Unit frames to console', 'wiring.console', 'When a unit frame isn\'t docked in the console.', disabled = Off, since = '0.5.2'},
		{'switch', 'Aura timeline', 'wiring.timeline', nil, disabled = Off, since = '0.5.2'},
		{'switch', 'Swing timers', 'wiring.swing', nil, disabled = Off, since = '0.5.2'},
		{'switch', 'Top rail', 'wiring.topRail', 'A second rail along the top edge, for the minimap and info panel.', disabled = Off, since = '0.5.2'},
	}},
}})
