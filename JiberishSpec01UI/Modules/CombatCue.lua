-- Combat cues: the moment a fight starts and ends, told in SPEC-01's own terms.
--
--   * Brackets: four corner brackets drop in from a third of the way across the
--     screen and lock onto its corners (red going in, green coming out), then
--     either fade or stay faint for the length of the fight.
--   * Rails: hairlines draw out from the middle of the top and bottom edges.
--   * Trace: a lit head runs once around the edge of every SPEC-01 frame on
--     screen, starting at the centre and rippling outward, and leaves its
--     outline glowing for a moment.
--   * Readout: an LCD at the top prints ENGAGED, or CLEAR with how long the
--     fight lasted, next to a lamp, then slides away.
--
-- Everything is our own frames over the interface; nothing is protected, so it
-- all runs in combat. With reduced motion only the readout shows, without moving.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, GetTime, UIParent, InCombatLockdown = CreateFrame, GetTime, UIParent, InCombatLockdown
local floor, max, min, abs = math.floor, math.max, math.min, math.abs

local module = UI:RegisterModule('combatcue', {always = true})

-- defaults:begin
UI:RegisterDefaults('combatcue', {enable = true, brackets = true, hold = true, rails = true, trace = true,
	readout = true, sound = true})
-- defaults:end

local function DB() return UI.db.combatcue end
local function IsSecret(value) return issecretvalue and issecretvalue(value) end
local function Reduced() return Kit:DB().reduceMotion end
local fighting = false -- in a fight (or a preview of one)
local function Px(frame, n) return UI.Pixel.Px(frame, n) end

local root
local ARM, INSET = 28, 10

-- Brackets and rails --------------------------------------------------------------------
local CORNERS = {
	{'TOPLEFT', 1, -1}, {'TOPRIGHT', -1, -1}, {'BOTTOMLEFT', 1, 1}, {'BOTTOMRIGHT', -1, 1},
}

local function Build()
	if root then return root end
	root = CreateFrame('Frame', nil, UIParent)
	root:SetAllPoints()
	root:SetFrameStrata('HIGH')
	root:EnableMouse(false)
	root.brackets = {}
	for index, corner in ipairs(CORNERS) do
		local bracket = CreateFrame('Frame', nil, root)
		bracket:SetSize(ARM, ARM)
		bracket.corner = corner
		bracket.across = bracket:CreateTexture(nil, 'OVERLAY')
		bracket.down = bracket:CreateTexture(nil, 'OVERLAY')
		bracket.glow = Kit:Texture(bracket, 'glow', 'ARTWORK')
		bracket.glow:SetPoint(corner[1], bracket, corner[1], -corner[2] * 10, -corner[3] * 10)
		bracket.glow:SetSize(ARM + 10, ARM + 10)
		for _, piece in ipairs({bracket.across, bracket.down}) do piece:SetColorTexture(1, 1, 1, 1) end
		bracket:SetAlpha(0)
		root.brackets[index] = bracket
	end
	root.rails = {}
	for index, side in ipairs({'TOP', 'BOTTOM'}) do
		local rail = root:CreateTexture(nil, 'OVERLAY')
		rail:SetColorTexture(1, 1, 1, 1)
		rail.side = side
		rail:SetAlpha(0)
		root.rails[index] = rail
	end
	-- The readout: an LCD with a lamp, under the top edge.
	local lcd = Kit:LCDPanel(root, {radius = 4})
	lcd:SetSize(150, 26)
	lcd:SetPoint('TOP', root, 'TOP', 0, -40)
	lcd.led = Kit:Led(lcd, 6, true)
	lcd.led:SetPoint('LEFT', 9, 0)
	lcd.text = Kit:Text(lcd, '', 12, 'lcdInk', true)
	lcd.text:SetPoint('LEFT', lcd.led, 'RIGHT', 8, 0)
	lcd.time = Kit:Text(lcd, '', 12, 'lcdDim', true)
	lcd.time:SetPoint('RIGHT', -10, 0)
	lcd:SetAlpha(0)
	lcd:Hide()
	root.lcd = lcd
	return root
end

local function LayoutBrackets(thickness)
	for _, bracket in ipairs(root.brackets) do
		local point, sx, sy = bracket.corner[1], bracket.corner[2], bracket.corner[3]
		bracket.across:ClearAllPoints()
		bracket.across:SetPoint(point, bracket, point, 0, 0)
		bracket.across:SetSize(ARM, thickness)
		bracket.down:ClearAllPoints()
		bracket.down:SetPoint(point, bracket, point, 0, 0)
		bracket.down:SetSize(thickness, ARM)
		bracket.sx, bracket.sy = sx, sy
	end
end

local function Color(token, ...)
	local r, g, b = Kit:RGB(token)
	for index = 1, select('#', ...) do
		local region = select(index, ...)
		region:SetVertexColor(r, g, b)
	end
end

-- t: 0 (a third of the way in) to 1 (locked on the corner).
local function PlaceBrackets(t)
	local width, height = UIParent:GetSize()
	local inX, inY = width * 0.16, height * 0.16
	for _, bracket in ipairs(root.brackets) do
		bracket:ClearAllPoints()
		bracket:SetPoint(bracket.corner[1], root, bracket.corner[1],
			bracket.sx * (INSET + inX * (1 - t)), bracket.sy * (INSET + inY * (1 - t)))
	end
end

local function Brackets(entering)
	if not DB().brackets then
		for _, bracket in ipairs(root.brackets) do bracket:SetAlpha(0) end
		return
	end
	local token = entering and 'red' or 'green'
	for _, bracket in ipairs(root.brackets) do
		Color(token, bracket.across, bracket.down, bracket.glow)
		bracket.glow:SetAlpha(0.35)
	end
	local hold = entering and DB().hold
	if Reduced() then
		PlaceBrackets(1)
		for _, bracket in ipairs(root.brackets) do bracket:SetAlpha(hold and 0.3 or 0) end
		return
	end
	if entering then
		-- In: drop from a third of the way across and snap onto the corners.
		Kit:Animate(root.brackets, 0.42, 0, 1, function(value, progress)
			PlaceBrackets(value)
			local alpha = min(1, progress * 3)
			for _, bracket in ipairs(root.brackets) do bracket:SetAlpha(alpha) end
		end, function()
			-- Hold a beat at full, then settle to the faint hold (or out).
			C_Timer.After(0.5, function()
				if not (fighting or InCombatLockdown()) then return end
				for _, bracket in ipairs(root.brackets) do Kit:FadeTo(bracket, hold and 0.3 or 0, 'SLOW') end
			end)
		end, 'detent')
	else
		-- Out: open back out toward the middle as they go.
		PlaceBrackets(1)
		Kit:Animate(root.brackets, 0.7, 1, 0, function(value, progress)
			PlaceBrackets(0.6 + 0.4 * value)
			local alpha = progress < 0.25 and 1 or (1 - (progress - 0.25) / 0.75)
			for _, bracket in ipairs(root.brackets) do bracket:SetAlpha(alpha) end
		end, function()
			for _, bracket in ipairs(root.brackets) do bracket:SetAlpha(0) end
		end, 'cubic')
	end
end

local function Rails(entering)
	if not DB().rails or Reduced() then
		for _, rail in ipairs(root.rails) do rail:SetAlpha(0) end
		return
	end
	local width = UIParent:GetWidth()
	local thickness = Px(root, 1)
	for _, rail in ipairs(root.rails) do
		Color(entering and 'red' or 'green', rail)
		rail:ClearAllPoints()
		rail:SetPoint(rail.side, root, rail.side, 0, 0)
		rail:SetHeight(thickness)
	end
	Kit:Animate(root.rails, entering and 0.5 or 0.8, 0, 1, function(value, progress)
		local span = max(width * min(1, value * 1.15), 1)
		local alpha = progress < 0.6 and 0.9 or 0.9 * (1 - (progress - 0.6) / 0.4)
		for _, rail in ipairs(root.rails) do
			rail:SetWidth(span)
			rail:SetAlpha(alpha)
		end
	end, function()
		for _, rail in ipairs(root.rails) do rail:SetAlpha(0) end
	end, 'cubic')
end

-- Trace ---------------------------------------------------------------------------------
-- One outline per SPEC-01 frame, made on first use and kept.
local traces = setmetatable({}, {__mode = 'k'})

local function Trace(frame)
	local trace = traces[frame]
	if trace then return trace end
	trace = CreateFrame('Frame', nil, root)
	trace:SetFrameStrata('HIGH')
	trace.edges = {}
	for index = 1, 4 do
		local edge = trace:CreateTexture(nil, 'OVERLAY')
		edge:SetColorTexture(1, 1, 1, 1)
		trace.edges[index] = edge
	end
	trace.head = Kit:Texture(trace, 'glow', 'OVERLAY', 2)
	trace.head:SetSize(26, 26)
	trace.head:SetBlendMode('ADD')
	trace.dot = trace:CreateTexture(nil, 'OVERLAY', nil, 3)
	trace.dot:SetColorTexture(1, 1, 1, 1)
	trace:SetAlpha(0)
	traces[frame] = trace
	return trace
end

local function Fit(trace, frame)
	trace:ClearAllPoints()
	trace:SetAllPoints(frame)
	local px = Px(trace, 1)
	local top, bottom, left, right = unpack(trace.edges)
	top:ClearAllPoints(); top:SetPoint('TOPLEFT'); top:SetPoint('TOPRIGHT'); top:SetHeight(px)
	bottom:ClearAllPoints(); bottom:SetPoint('BOTTOMLEFT'); bottom:SetPoint('BOTTOMRIGHT'); bottom:SetHeight(px)
	left:ClearAllPoints(); left:SetPoint('TOPLEFT'); left:SetPoint('BOTTOMLEFT'); left:SetWidth(px)
	right:ClearAllPoints(); right:SetPoint('TOPRIGHT'); right:SetPoint('BOTTOMRIGHT'); right:SetWidth(px)
	trace.dot:SetSize(2 * px, 2 * px)
end

-- Where a point `along` (0..1) the outline is, clockwise from the top-left corner.
local function AlongEdge(width, height, along)
	local length = 2 * (width + height)
	local at = (along % 1) * length
	if at < width then return at, 0 end
	at = at - width
	if at < height then return width, -at end
	at = at - height
	if at < width then return width - at, -height end
	return 0, -(height - (at - width))
end

local function Run(trace, frame, token, duration)
	Fit(trace, frame)
	-- In the trace's own units: the frame may carry its own scale.
	local width, height = frame:GetSize()
	if IsSecret(width) or IsSecret(height) or not width or not height then return end
	local ratio = frame:GetEffectiveScale() / trace:GetEffectiveScale()
	width, height = width * ratio, height * ratio
	if width < 8 or height < 8 then return end
	Color(token, trace.head, trace.dot, unpack(trace.edges))
	trace:Show()
	Kit:Animate(trace, duration, 0, 1, function(value, progress)
		local x, y = AlongEdge(width, height, value)
		trace.head:ClearAllPoints()
		trace.head:SetPoint('CENTER', trace, 'TOPLEFT', x, y)
		trace.dot:ClearAllPoints()
		trace.dot:SetPoint('CENTER', trace, 'TOPLEFT', x, y)
		-- The head runs at full; the outline glows up behind it and fades at the end.
		trace:SetAlpha(1)
		local outline = progress < 0.7 and 0.55 * min(1, progress * 2.5) or 0.55 * (1 - (progress - 0.7) / 0.3)
		for _, edge in ipairs(trace.edges) do edge:SetAlpha(outline) end
		local head = progress > 0.85 and (1 - progress) / 0.15 or 1
		trace.head:SetAlpha(0.9 * head)
		trace.dot:SetAlpha(head)
	end, function() trace:SetAlpha(0) trace:Hide() end, 'inout')
end

local function TraceAll(entering)
	if not DB().trace or Reduced() then return end
	local token, duration = entering and 'red' or 'green', entering and 0.65 or 0.9
	local cx, cy = UIParent:GetCenter()
	local list = {}
	for _, entry in ipairs(UI.GetMovers and UI:GetMovers() or {}) do
		local frame = entry.frame
		if frame and not entry.docked and frame:IsVisible() and frame:GetAlpha() > 0.05 then
			local x, y = frame:GetCenter()
			if x and y and not IsSecret(x) and not IsSecret(y) then
				local ratio = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
				local distance = abs(x * ratio - cx) + abs(y * ratio - cy)
				list[#list + 1] = {frame = frame, distance = distance}
			end
		end
	end
	table.sort(list, function(a, b) return a.distance < b.distance end)
	local farthest = list[#list] and list[#list].distance or 1
	for _, item in ipairs(list) do
		local delay = 0.28 * item.distance / max(farthest, 1)
		C_Timer.After(delay, function() UI:Safe(Run, Trace(item.frame), item.frame, token, duration) end)
	end
end

-- Readout -------------------------------------------------------------------------------
local started

local function Readout(entering)
	local lcd = root.lcd
	if not DB().readout then lcd:Hide() return end
	Kit:SetLed(lcd.led, true, entering and 'red' or 'green')
	if entering then
		lcd.time:SetText('')
	else
		Kit:Blink(lcd.led, nil, false)
		local length = started and max(0, GetTime() - started) or 0
		lcd.time:SetText(format('%02d:%02d', floor(length / 60), floor(length % 60)))
	end
	lcd:Show()
	Kit:PrintText(lcd.text, entering and 'ENGAGED' or 'CLEAR', {duration = 0.3})
	lcd:SetWidth(max(150, lcd.text:GetStringWidth() + lcd.time:GetStringWidth() + 48))
	if Reduced() then
		lcd:SetAlpha(1)
	else
		lcd:ClearAllPoints()
		Kit:Animate(lcd, 0.32, 1, 0, function(value, progress)
			lcd:ClearAllPoints()
			lcd:SetPoint('TOP', root, 'TOP', 0, -40 + 10 * value)
			lcd:SetAlpha(progress)
		end, nil, 'detent')
		if entering then Kit:Blink(lcd.led, 0.18, true) end
	end
	local token = {}
	lcd.token = token
	C_Timer.After(entering and 1.4 or 1.8, function()
		if lcd.token ~= token then return end
		Kit:Blink(lcd.led, nil, false)
		Kit:FadeTo(lcd, 0, 'SLOW', function() if lcd.token == token then lcd:Hide() end end)
	end)
end

-- Driver --------------------------------------------------------------------------------
local function Cue(entering)
	Build()
	LayoutBrackets(Px(root, 2))
	UI:Safe(Brackets, entering)
	UI:Safe(Rails, entering)
	UI:Safe(TraceAll, entering)
	UI:Safe(Readout, entering)
	if DB().sound then Kit:Play(entering and 'latch-down' or 'success', true) end
end

function module:Enable()
	if not DB().enable then return end
	local events = CreateFrame('Frame')
	events:RegisterEvent('PLAYER_REGEN_DISABLED')
	events:RegisterEvent('PLAYER_REGEN_ENABLED')
	events:SetScript('OnEvent', function(_, event)
		local entering = event == 'PLAYER_REGEN_DISABLED'
		fighting = entering
		if entering then started = GetTime() end
		Cue(entering)
		if not entering then started = nil end
	end)
	self.ready = true
end

-- A preview never leaves the brackets held: the hold only waits on a real fight.
function module:Preview(entering)
	if entering then started = GetTime() - 42 end
	Cue(entering)
	if not entering then started = nil end
end

-- Hub -----------------------------------------------------------------------------------
local function Off() return not DB().enable end
UI:RegisterPage('combatcue', {title = 'Combat cues', order = 4.2, cards = {
	{title = 'Combat cues', rows = {
		{'switch', 'Combat cues', 'combatcue.enable', 'The moment a fight starts and ends, shown across the screen in SPEC-01\'s style.', reload = true, since = '0.5.1'},
		{'switch', 'Corner brackets', 'combatcue.brackets', 'Brackets drop in and lock onto the corners of the screen: red going in, green coming out.', disabled = Off, since = '0.5.1'},
		{'switch', 'Hold during the fight', 'combatcue.hold', 'The brackets stay faintly lit until the fight ends.', disabled = Off, since = '0.5.1'},
		{'switch', 'Rails', 'combatcue.rails', 'Hairlines draw out from the middle of the top and bottom edges.', disabled = Off, since = '0.5.1'},
		{'switch', 'Frame trace', 'combatcue.trace', 'A lit head runs once around every SPEC-01 frame, rippling out from the middle of the screen.', disabled = Off, since = '0.5.1'},
		{'switch', 'Readout', 'combatcue.readout', 'An LCD prints ENGAGED, or CLEAR with how long the fight lasted.', disabled = Off, since = '0.5.1'},
		{'switch', 'Sound', 'combatcue.sound', 'A latch going in, a chime coming out.', disabled = Off, since = '0.5.1'},
		{'button', 'Preview going in', 'Play', function() module:Preview(true) end},
		{'button', 'Preview coming out', 'Play', function() module:Preview(false) end},
	}},
}})
