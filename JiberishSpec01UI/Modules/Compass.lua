-- The NV-3 compass: a SPEC-01 heading tape for the top of the screen. Hairline
-- ticks every 5, 10 or 15 degrees scroll past a fixed caret as you turn, with
-- N, NE, E ... printed on the tape (N in the key color) and your heading in
-- degrees on a small LCD over the caret. A second marker rides the tape at the
-- way you are actually moving (strafing, backing up, sliding down a slope),
-- with your speed on its own LCD. Above the tape: the zone and subzone with a
-- lamp for its PvP state, and your coordinates. Under it, the points of
-- interest within range hang at their bearing on small keys with their
-- distance on an LCD chip; keys that would overlap spread out along the tape
-- with angled leaders back to their bearing, as on the aura timeline.
--
-- Ticks are laid on whole physical pixels on one strip, moved by one anchor a
-- frame, so they stay sharp while they scroll (the nameplate nav tape's way).
-- Heading and position are read 20 or 30 times a second only while the
-- compass is shown; the points are rebuilt on events (Navigation.lua). Where
-- the game hides facing (instances), the tape prints NO SIGNAL.
local _, UI = ...
local Kit = UI.Kit
local Nav = UI.Navigation

local CreateFrame, UIParent, GetTime = CreateFrame, UIParent, GetTime
local floor, max, min, abs, ceil, pi = math.floor, math.max, math.min, math.abs, math.ceil, math.pi

local module = UI:RegisterModule('compass', {always = true})

-- defaults:begin
UI:RegisterDefaults('compass', {
	enable = true,
	housing = 'device', -- 'device' | 'glass' | 'hairline'
	width = 460, fov = 180, -- the tape's width, and the degrees it spans
	tickStep = 5, tickMinor = 3, tickMajor = 6, tickWeight = 1, -- sizes in physical pixels
	letters = 'eight', -- 'eight' (N NE E ...) | 'four' (N E S W)
	degrees = true, northLit = true, lens = true, edgeFade = true,
	location = true, coords = true, heading = true,
	motion = true, speedUnit = 'yards', -- 'yards' | 'percent'
	pois = true, range = 400, maxPois = 8, keySize = 16, distances = true, pinTarget = true,
	icons = 'glyph', -- 'glyph' | 'game'
	nearest = 'alt', -- 'alt' | 'shift' | 'ctrl' | 'always' | 'off': the nearest repair, inn and mailbox
})
-- defaults:end

local function DB() return UI.db.compass end
local function Reduced() return Kit:Reduced() end
local function Px(frame, n) return UI.Pixel.Px(frame, n) end
local function Snap(value, px) return floor(value / px + 0.5) * px end
local function Clamp(value, low, high, fallback)
	value = type(value) == 'number' and value or fallback
	return max(low, min(high, value))
end

local holder, tape, strip, band
local ticks, labels, slots, free = {}, {}, {}, {}
local m = {} -- the current layout's sizes
local preview = false
local nearList = {}

local HEADER_H, ROW_GAP, CHIP_H = 14, 4, 9
local EDGE_FADE, LENS_SPAN, LENS_LIFT = 0.18, 4.5, 3
local LETTERS = {
	eight = {{0, 'N'}, {45, 'NE'}, {90, 'E'}, {135, 'SE'}, {180, 'S'}, {225, 'SW'}, {270, 'W'}, {315, 'NW'}},
	four = {{0, 'N'}, {90, 'E'}, {180, 'S'}, {270, 'W'}},
}
local NUMBERS = {30, 60, 120, 150, 210, 240, 300, 330}
local PVP = {sanctuary = 'blue', friendly = 'green', hostile = 'red', contested = 'amber', combat = 'red', arena = 'red'}

-- Inks: printed on the housing, or light with a shadow over the world.
local function OnHousing() return DB().housing == 'device' end
local function Ink() return OnHousing() and 'ink' or 'darkInk' end
local function Dim() return OnHousing() and 'dim' or 'darkDim' end
local function Shadow(fontString)
	if OnHousing() then fontString:SetShadowOffset(0, 0)
	else fontString:SetShadowOffset(1, -1); fontString:SetShadowColor(0, 0, 0, 0.7) end
end

-- Parts -------------------------------------------------------------------------------
local function Chip(parent, width)
	local chip = Kit:LCDPanel(parent, {radius = 2})
	chip:SetSize(width, HEADER_H)
	chip.text = Kit:Text(chip, '', 8, 'lcdInk', true)
	Kit:Font(chip.text, 8, nil, true, 'numbers')
	chip.text:SetPoint('CENTER', 0, 0)
	chip.text:SetShadowOffset(0, 0)
	return chip
end

local function SetChip(chip, text)
	if chip.value == text then return end
	chip.value = text
	chip.text:SetText(text)
end

-- A caret of whole-pixel rows, narrow at the top: it points up at the tape.
local function Caret(parent)
	local caret = CreateFrame('Frame', nil, parent)
	caret.rows = {}
	for row = 1, 5 do
		local piece = caret:CreateTexture(nil, 'OVERLAY', nil, 3)
		piece:SetColorTexture(1, 1, 1, 1)
		caret.rows[row] = piece
	end
	return caret
end

local function LayoutCaret(caret, size, px, token)
	for row, piece in ipairs(caret.rows) do
		piece:ClearAllPoints()
		if row <= size then
			piece:SetSize((2 * row - 1) * px, px)
			piece:SetPoint('TOP', caret, 'TOP', 0, -(row - 1) * px)
			Kit:Tint(piece, token)
			piece:Show()
		else
			piece:Hide()
		end
	end
	caret:SetSize((2 * size - 1) * px, size * px)
end

local function Build()
	holder = CreateFrame('Frame', 'JiberishSpec01Compass', UIParent)
	holder:SetFrameStrata('LOW')
	holder:EnableMouse(false)
	holder:SetSize(460, 80)
	holder.device = Kit:Device(holder, {header = false, surface = 'paper', radius = 8})
	holder.device:SetAllPoints()
	holder.device:EnableMouse(false)
	holder.glass = CreateFrame('Frame', nil, holder)
	holder.glass:SetAllPoints()
	holder.glass.shell = Kit:Shell(holder.glass, {surface = 'glass', radius = 6, alpha = 0.7, shadow = false})
	local level = holder:GetFrameLevel() + 4
	local content = CreateFrame('Frame', nil, holder)
	content:SetAllPoints()
	content:SetFrameLevel(level)
	holder.content = content
	-- The header row: model, PvP lamp, zone and subzone; heading; speed and coordinates.
	holder.model = Kit:Label(content, 'NV-3', 'ink', 7, true)
	holder.lampHolder = CreateFrame('Frame', nil, content)
	holder.lampHolder:SetSize(7, 7)
	holder.pvp = Kit:Led(holder.lampHolder, 5, false)
	holder.pvp:SetPoint('CENTER')
	holder.zone = Kit:Text(content, '', 9, 'ink', true)
	holder.zone:SetJustifyH('LEFT')
	holder.zone:SetWordWrap(false)
	holder.headingChip = Chip(content, 56)
	holder.coords = Chip(content, 70)
	holder.speed = Chip(content, 56)
	-- The tape: clipped, so ticks and letters scroll in and out at its ends.
	tape = CreateFrame('Frame', nil, content)
	tape:SetClipsChildren(true)
	tape:SetFrameLevel(level + 1)
	strip = CreateFrame('Frame', nil, tape)
	strip:SetSize(1, 1)
	holder.baseline = content:CreateTexture(nil, 'ARTWORK')
	holder.baseline:SetColorTexture(1, 1, 1, 1)
	holder.lubber = tape:CreateTexture(nil, 'OVERLAY', nil, 4)
	holder.lubber:SetColorTexture(1, 1, 1, 1)
	holder.caret = Caret(content)
	holder.caret:SetFrameLevel(level + 3)
	-- Where you are moving: a lit diamond riding the baseline.
	holder.motion = CreateFrame('Frame', nil, content)
	holder.motion:SetFrameLevel(level + 4)
	holder.motion.diamond = holder.motion:CreateTexture(nil, 'OVERLAY', nil, 5)
	holder.motion.diamond:SetColorTexture(1, 1, 1, 1)
	holder.motion.diamond:SetRotation(pi / 4)
	holder.motion.diamond:SetPoint('CENTER')
	-- No facing to read.
	holder.signal = CreateFrame('Frame', nil, content)
	holder.signal:SetFrameLevel(level + 5)
	holder.signal:SetSize(90, 12)
	holder.signal.text = Kit:Label(holder.signal, 'No signal', 'red', 8, true)
	holder.signal.text:SetPoint('CENTER', 4, 0)
	holder.signal.led = Kit:Led(holder.signal, 5, true)
	Kit:SetLed(holder.signal.led, true, 'red')
	holder.signal.led:SetPoint('RIGHT', holder.signal.text, 'LEFT', -4, 0)
	holder.signal:Hide()
	-- The points hang in a band under the tape.
	band = CreateFrame('Frame', nil, content)
	band:SetFrameLevel(level + 2)
	band:SetSize(1, 1)
	holder.at = {motion = 0}
end

-- Layout ---------------------------------------------------------------------------------
local function LayoutTicks()
	local px, total = m.px, floor(m.tapeW / m.spacing) + 3
	m.tickCount = total
	for index = 1, total do
		local tick = ticks[index]
		if not tick then
			tick = strip:CreateTexture(nil, 'ARTWORK')
			tick:SetColorTexture(1, 1, 1, 1)
			ticks[index] = tick
		end
		tick:ClearAllPoints()
		tick:SetPoint('BOTTOMLEFT', strip, 'BOTTOMLEFT', (index - 1) * m.spacing, 0)
		tick:SetWidth(m.weight * px)
		tick:SetHeight(m.minorH * px)
		tick.height = nil
		tick:Show()
	end
	for index = total + 1, #ticks do ticks[index]:Hide() end
end

local function Label(index)
	local label = labels[index]
	if not label then
		-- On the strip, so the tape's clip cuts them at its ends.
		label = Kit:Text(strip, '', 8, 'ink', true)
		labels[index] = label
	end
	return label
end

local function LayoutLabels()
	local db = DB()
	local list = {}
	for _, entry in ipairs(LETTERS[db.letters] or LETTERS.eight) do
		list[#list + 1] = {entry[1], entry[2], entry[1] % 90 == 0 and 9 or 8, true}
	end
	if db.degrees then
		for _, value in ipairs(NUMBERS) do list[#list + 1] = {value, tostring(value), 7, false} end
	end
	m.labels = list
	for index, entry in ipairs(list) do
		local label = Label(index)
		Kit:Font(label, entry[3], nil, entry[4], entry[4] and nil or 'numbers')
		label:SetText(entry[2])
		local token = entry[4] and Ink() or Dim()
		if entry[1] == 0 and db.northLit then token = 'lamp' end
		Kit:Tint(label, token)
		Shadow(label)
		label.degree = entry[1]
		label.x = nil
		label:Show()
	end
	for index = #list + 1, #labels do labels[index]:Hide() end
end

local function Layout()
	if not holder then return end
	local db = DB()
	local px = Px(holder, 1)
	m.px = px
	m.scale = holder:GetEffectiveScale()
	local housing = db.housing or 'device'
	holder.device:SetShown(housing == 'device')
	holder.glass:SetShown(housing == 'glass')
	local pad = housing == 'hairline' and 2 or 8
	local width = Snap(Clamp(db.width, 300, 900, 460), px)
	m.tapeW = width - 2 * pad
	-- Ticks on whole pixels: the spacing is snapped and the degrees per pixel follow it.
	m.step = ({[5] = 5, [10] = 10, [15] = 15})[db.tickStep] or 5
	local fov = Clamp(db.fov, 90, 360, 180)
	m.spacing = max(3 * px, Snap(m.tapeW / fov * m.step, px))
	m.ppd = m.spacing / m.step
	m.half = m.tapeW / 2
	m.halfFov = m.half / m.ppd
	m.weight = floor(Clamp(db.tickWeight, 1, 3, 1) + 0.5)
	m.minorH = floor(Clamp(db.tickMinor, 1, 10, 3) + 0.5)
	m.majorH = max(m.minorH, floor(Clamp(db.tickMajor, 2, 14, 6) + 0.5))
	m.midH = floor((m.minorH + m.majorH) / 2 + 0.5)
	m.lift = db.lens and LENS_LIFT or 0
	local tickBand = (m.majorH + m.lift) * px
	local labelBand = 11
	m.tapeH = Snap(labelBand + tickBand, px)
	m.tickBand = tickBand
	m.caret = 3
	m.caretH = m.caret * px
	local header = (db.location or db.coords or db.heading or db.motion) and HEADER_H + ROW_GAP or 0
	m.key = floor(Clamp(db.keySize, 12, 24, 16) + 0.5)
	m.chipH = db.distances and CHIP_H + 1 or 0
	m.lead = Snap(m.caretH + 5, px)
	local bandH = db.pois and (m.lead + m.key + m.chipH) or 0
	local height = Snap(pad + header + m.tapeH + m.caretH + 2 * px + bandH + pad, px)
	holder:SetSize(width, height)
	local content = holder.content
	-- Header row.
	local ink, dim = Ink(), Dim()
	holder.model:SetShown(housing == 'device' and db.location and true or false)
	holder.model:ClearAllPoints()
	holder.model:SetPoint('TOPLEFT', content, 'TOPLEFT', pad + 2, -pad - 4)
	Kit:Tint(holder.model, dim)
	holder.lampHolder:ClearAllPoints()
	if holder.model:IsShown() then holder.lampHolder:SetPoint('LEFT', holder.model, 'RIGHT', 4, 0)
	else holder.lampHolder:SetPoint('TOPLEFT', content, 'TOPLEFT', pad, -pad - 4) end
	holder.lampHolder:SetShown(db.location and true or false)
	holder.zone:ClearAllPoints()
	holder.zone:SetPoint('LEFT', holder.lampHolder, 'RIGHT', 4, 0)
	holder.zone:SetWidth(max(40, m.half - 28 - 40 - (holder.model:IsShown() and 22 or 0)))
	holder.zone:SetShown(db.location and true or false)
	Kit:Tint(holder.zone, ink)
	Shadow(holder.zone)
	holder.headingChip:ClearAllPoints()
	holder.headingChip:SetPoint('TOP', content, 'TOP', 0, -pad)
	holder.headingChip:SetShown(db.heading and true or false)
	holder.coords:ClearAllPoints()
	holder.coords:SetPoint('TOPRIGHT', content, 'TOPRIGHT', -pad, -pad)
	holder.coords:SetShown(db.coords and true or false)
	holder.speed:ClearAllPoints()
	if db.coords then holder.speed:SetPoint('RIGHT', holder.coords, 'LEFT', -4, 0)
	else holder.speed:SetPoint('TOPRIGHT', content, 'TOPRIGHT', -pad, -pad) end
	holder.speed:SetShown(db.motion and true or false)
	-- The tape.
	tape:ClearAllPoints()
	tape:SetPoint('TOPLEFT', content, 'TOPLEFT', pad, -(pad + header))
	tape:SetSize(m.tapeW, m.tapeH)
	holder.baseline:ClearAllPoints()
	holder.baseline:SetPoint('TOPLEFT', tape, 'BOTTOMLEFT', 0, 0)
	holder.baseline:SetSize(m.tapeW, px)
	Kit:Tint(holder.baseline, dim, 0.7)
	holder.lubber:ClearAllPoints()
	holder.lubber:SetPoint('BOTTOM', tape, 'BOTTOMLEFT', Snap(m.half, px) + px / 2, 0)
	holder.lubber:SetSize(px, tickBand)
	Kit:Tint(holder.lubber, 'lamp', 0.9)
	LayoutCaret(holder.caret, m.caret, px, ink)
	holder.caret:ClearAllPoints()
	holder.caret:SetPoint('TOP', tape, 'BOTTOMLEFT', Snap(m.half, px) + px / 2, -px)
	local d = 5 * px
	holder.motion:SetSize(d * 2, d * 2)
	holder.motion.diamond:SetSize(d, d)
	Kit:Tint(holder.motion.diamond, 'lamp')
	holder.signal:ClearAllPoints()
	holder.signal:SetPoint('BOTTOM', tape, 'BOTTOM', 0, 2 * px)
	band:ClearAllPoints()
	band:SetPoint('TOPLEFT', tape, 'BOTTOMLEFT', 0, 0)
	band:SetSize(m.tapeW, max(bandH, 1))
	band:SetShown(db.pois and true or false)
	LayoutTicks()
	LayoutLabels()
	for _, slot in pairs(slots) do slot.dressed = nil end
	m.stripX, m.first, m.dirty = nil, nil, true
	m.zoneDirty = true
end

-- Drawing ----------------------------------------------------------------------------------
local function Smooth(t) return t * t * (3 - 2 * t) end

local function EdgeAlpha(x)
	if DB().edgeFade == false then return 1 end
	local fade = EDGE_FADE * m.tapeW
	return min(1, max(0, x / fade), max(0, (m.tapeW - x) / fade))
end

-- The strip, placed by its first tick's degree; each tick's height and color
-- from what it marks and how near the caret it is.
local function DrawTicks(heading, signal)
	local px, spacing, step = m.px, m.spacing, m.step
	local left = (heading - m.halfFov) * m.ppd
	local first = ceil(left / spacing - 1e-6)
	local stripX = Snap(first * spacing - left, px)
	if stripX ~= m.stripX or first ~= m.first then
		m.stripX, m.first, m.dirty = stripX, first, true
		strip:ClearAllPoints()
		strip:SetPoint('BOTTOMLEFT', tape, 'BOTTOMLEFT', stripX, 0)
	end
	if m.signal ~= signal then m.signal, m.dirty = signal, true end
	if not m.dirty then return end
	m.dirty = nil
	local db = DB()
	local reach = LENS_SPAN * spacing
	local minorR, minorG, minorB = Kit:RGB(Dim())
	local majorR, majorG, majorB = Kit:RGB(Ink())
	local lensR, lensG, lensB = Kit:RGB('lamp')
	for index = 1, m.tickCount do
		local tick = ticks[index]
		local x = stripX + (index - 1) * spacing
		local degree = ((first + index - 1) * step) % 360
		local major = degree % 45 == 0
		local mid = not major and step < 15 and degree % 15 == 0
		local near = 0
		if db.lens and signal then
			local distance = abs(x - m.half)
			if distance < reach then near = Smooth(1 - distance / reach) end
		end
		local base = major and m.majorH or mid and m.midH or m.minorH
		local height = floor(base + near * m.lift + 0.5) * px
		if tick.height ~= height then tick.height = height; tick:SetHeight(height) end
		local r, g, b = minorR, minorG, minorB
		if major or mid then r, g, b = majorR, majorG, majorB end
		tick:SetVertexColor(r + (lensR - r) * near, g + (lensG - g) * near, b + (lensB - b) * near)
		local alpha = (major and 0.95 or mid and 0.75 or 0.5) + 0.3 * near
		tick:SetAlpha(min(1, alpha) * EdgeAlpha(x) * (signal and 1 or 0.25))
	end
end

local function DrawLabels(heading, signal)
	local px = m.px
	for index, entry in ipairs(m.labels) do
		local label = labels[index]
		local x = m.half + Nav.Relative(entry[1], heading) * m.ppd
		if not signal or abs(x - m.half) > m.half + 12 then
			label:SetAlpha(0)
		else
			x = Snap(x, px)
			if label.x ~= x then
				label.x = x
				label:ClearAllPoints()
				label:SetPoint('BOTTOM', tape, 'BOTTOMLEFT', x, m.tickBand + px)
			end
			label:SetAlpha(EdgeAlpha(x))
		end
	end
end

local function DrawMotion(here, heading, elapsed)
	local marker = holder.motion
	if not (DB().motion and here.moving and here.moveDeg and heading) then
		marker:Hide()
		return
	end
	local rel = Nav.Relative(here.moveDeg, heading)
	local pinned = abs(rel) > m.halfFov
	local goal = m.half + max(-m.halfFov, min(m.halfFov, rel)) * m.ppd
	local at = holder.at
	if not marker:IsShown() or Reduced() or abs(goal - (at.motion or goal)) > m.half then at.motion = goal
	else at.motion = at.motion + (goal - at.motion) * min(1, elapsed * 12) end
	marker:ClearAllPoints()
	marker:SetPoint('CENTER', tape, 'BOTTOMLEFT', Snap(at.motion, m.px) + m.px / 2, 0)
	marker:SetAlpha(pinned and 0.45 or 1)
	marker:Show()
end

-- Points --------------------------------------------------------------------------------------
local function Slot()
	local slot = table.remove(free)
	if slot then return slot end
	slot = {}
	slot.key = Nav:MakeKey(band)
	slot.chip = Kit:LCDPanel(slot.key, {radius = 2})
	slot.chip:SetFrameLevel(band:GetFrameLevel() + 4)
	Kit:Relevel(slot.chip)
	slot.chip.text = Kit:Text(slot.chip, '', 7, 'lcdInk', true)
	Kit:Font(slot.chip.text, 7, nil, true, 'numbers')
	slot.chip.text:SetPoint('CENTER', 0, 0)
	slot.chip.text:SetShadowOffset(0, 0)
	slot.stem = band:CreateTexture(nil, 'ARTWORK')
	slot.stem:SetColorTexture(1, 1, 1, 1)
	slot.leader = band:CreateLine(nil, 'ARTWORK')
	slot.leader:SetColorTexture(1, 1, 1, 1)
	return slot
end

local function Release(uid)
	local slot = slots[uid]
	slots[uid] = nil
	slot.key:Hide()
	slot.stem:Hide()
	slot.leader:Hide()
	slot.poi, slot.shift, slot.text = nil, nil, nil
	free[#free + 1] = slot
end

local row, seen = {}, {}

-- The nearest repair, inn and mailbox: while a key is held (or always), read
-- out in place of the zone name and kept on the tape, at its ends if behind you.
local NEAREST = {'repair', 'inn', 'mail'}
local nearest, combined, inList = {}, {}, {}
local function Holding()
	local key = DB().nearest
	if key == 'always' then return true end
	if key == 'alt' then return IsAltKeyDown() and true or false end
	if key == 'shift' then return IsShiftKeyDown() and true or false end
	if key == 'ctrl' then return IsControlKeyDown() and true or false end
	return false
end

-- The demo points shown while placing frames: a few kinds around you.
local DEMO = {{'quest', 32, 140}, {'giver', 40, 210}, {'taxi', -64, 380}, {'turnin', -12, 95}, {'rare', 118, 260},
	{'inn', 75, 330}, {'waypoint', 170, 520, true}}
local demoPois = {}
for index, entry in ipairs(DEMO) do demoPois[index] = {kind = entry[1], uid = 'demo'..index, super = entry[4]} end

local function Points(here, heading)
	local db = DB()
	wipe(row)
	wipe(seen)
	local list
	if preview then
		list = nearList
		for index, entry in ipairs(DEMO) do
			local item = list[index] or {}
			item.poi, item.bearing, item.distance = demoPois[index], (heading + entry[2]) % 360, entry[3]
			list[index] = item
		end
		for index = #DEMO + 1, #list do list[index] = nil end
	elseif heading and here.wx then
		list = Nav:Near(Clamp(db.range, 50, 1500, 400), nearList)
	else
		list = nearList
		wipe(list)
	end
	-- The nearest services first while held, then the rest.
	wipe(combined)
	wipe(inList)
	if m.holding and not preview and heading and here.wx then
		for index, kind in ipairs(NEAREST) do
			local entry = Nav:Nearest(kind, nearest[index])
			if entry then
				nearest[index] = entry
				entry.pinOK = true
				combined[#combined + 1] = entry
				inList[entry.poi.uid] = true
			end
		end
	end
	for _, entry in ipairs(list) do
		if not inList[entry.poi.uid] then combined[#combined + 1] = entry end
	end
	local limit = floor(Clamp(db.maxPois, 2, 16, 8) + 0.5)
	local lo, hi = m.key / 2 + 1, m.tapeW - m.key / 2 - 1
	for _, entry in ipairs(combined) do
		if #row >= limit then break end
		local rel = Nav.Relative(entry.bearing, heading)
		local pinned
		if abs(rel) > m.halfFov - 1 then
			if (entry.poi.super and db.pinTarget) or entry.pinOK then pinned = rel < 0 and -1 or 1 end
		end
		if pinned or abs(rel) <= m.halfFov - 1 then
			entry.pinned = pinned
			entry.pos = pinned and (pinned < 0 and lo or hi) or m.half + rel * m.ppd
			entry.pos = max(lo, min(hi, entry.pos))
			row[#row + 1] = entry
		end
	end
	table.sort(row, function(a, b) return a.pos < b.pos end)
	Nav.Spread(row, m.key + 4, lo, hi)
	return row
end

local function DrawPoints(here, heading, elapsed)
	local db = DB()
	if not (db.pois and heading) then
		for uid in pairs(slots) do Release(uid) end
		return
	end
	local px = m.px
	local placed = Points(here, heading)
	local ease = Reduced() and 1 or min(1, elapsed * 10)
	local art = db.icons == 'game'
	local dim = Dim()
	for _, entry in ipairs(placed) do
		local poi = entry.poi
		local uid = poi.uid
		seen[uid] = true
		local slot = slots[uid]
		local fresh = not slot
		if fresh then
			slot = Slot()
			slots[uid] = slot
			slot.shift = entry.shift
		end
		if slot.poi ~= poi or not slot.dressed then
			slot.poi, slot.dressed = poi, true
			Nav:DressKey(slot.key, poi, m.key, art)
			slot.chip:SetSize(m.key + 10, CHIP_H)
			slot.chip:ClearAllPoints()
			slot.chip:SetPoint('TOP', slot.key, 'BOTTOM', 0, -1)
			slot.chip:SetShown(db.distances and true or false)
			slot.stem:SetWidth(px)
			slot.leader:SetThickness(px * 1.2)
			Kit:Tint(slot.stem, dim, 0.8)
			Kit:Tint(slot.leader, dim, 0.8)
		end
		slot.shift = slot.shift + (entry.shift - slot.shift) * ease
		local keyX = Snap(entry.pos + slot.shift, px)
		local point = Snap(entry.pos, px)
		slot.key:ClearAllPoints()
		slot.key:SetPoint('TOP', band, 'TOPLEFT', keyX, -m.lead)
		local straight = abs(keyX - point) < px or entry.pinned
		slot.stem:SetShown(straight and not entry.pinned)
		slot.leader:SetShown(not straight)
		if straight then
			slot.stem:ClearAllPoints()
			slot.stem:SetPoint('TOP', band, 'TOPLEFT', point + px / 2, -px)
			slot.stem:SetHeight(max(px, m.lead - px))
		else
			slot.leader:SetStartPoint('TOPLEFT', band, point + px / 2, -px)
			slot.leader:SetEndPoint('TOPLEFT', band, keyX + px / 2, -m.lead)
		end
		if db.distances then
			local text = Nav.Yards(entry.distance)
			-- Learned from a nearby title only: within ten yards of here.
			if poi.approx then text = '~'..text end
			if entry.pinned then text = entry.pinned < 0 and '<'..text or text..'>' end
			if slot.text ~= text then slot.text = text; slot.chip.text:SetText(text) end
		end
		local alpha = entry.pinned and 0.8 or max(0.35, EdgeAlpha(entry.pos))
		if fresh then
			slot.key:SetAlpha(0)
			slot.key:Show()
			if Reduced() then slot.key:SetAlpha(alpha) else Kit:FadeTo(slot.key, alpha, 'FAST') end
		elseif not Kit:Animating(slot.key) then
			slot.key:SetAlpha(alpha)
		end
		slot.stem:SetAlpha(alpha)
		slot.leader:SetAlpha(alpha)
	end
	for uid in pairs(slots) do
		if not seen[uid] then Release(uid) end
	end
end

-- While held: the nearest repair, inn and mailbox, each a glyph with its
-- distance and direction ("120NE"), or -- where none is known yet.
local function NearestText()
	local r, g, b = Kit:RGB(Ink())
	local dr, dg, db = Kit:RGB(Dim())
	local parts = {}
	for index, kind in ipairs(NEAREST) do
		local entry = Nav:Nearest(kind, nearest[index])
		if entry then nearest[index] = entry end
		local text = entry and format('%s%s%s', entry.poi.approx and '~' or '', Nav.Yards(entry.distance), Nav.Point(entry.bearing))
			or format('|cff%02x%02x%02x--|r', floor(dr * 255 + 0.5), floor(dg * 255 + 0.5), floor(db * 255 + 0.5))
		parts[#parts + 1] = Nav.InlineIcon(kind, 11, r, g, b)..' '..text
	end
	return table.concat(parts, '  ')
end

-- The header: zone and PvP lamp on events, the readouts every update.
local function DrawZone()
	m.zoneDirty = nil
	if m.holding then
		local text = NearestText()
		if holder.zone.shownText ~= text then holder.zone.shownText = text; holder.zone:SetText(text) end
		return
	end
	local zone, sub, pvp
	if preview then zone, sub, pvp = 'Elwynn Forest', 'Goldshire', 'friendly'
	else zone, sub, pvp = Nav:Zone() end
	local text = strupper(zone)
	if sub ~= '' and sub ~= zone then
		local r, g, b = Kit:RGB(Dim())
		text = format('%s  |cff%02x%02x%02x%s|r', text, floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5), strupper(sub))
	end
	holder.zone.shownText = text
	holder.zone:SetText(text)
	local token = pvp and PVP[pvp]
	Kit:SetLed(holder.pvp, token and true or false, token)
end

local function Readouts(here, heading)
	local db = DB()
	if db.heading then
		SetChip(holder.headingChip, heading and format('%03d° %s', floor(heading + 0.5) % 360, Nav.Point(heading)) or '---')
	end
	if db.coords then
		-- On the city or zone map (the one the world map shows), even inside a building.
		local x, y = here.zx or here.x, here.zy or here.y
		SetChip(holder.coords, x and format('%.1f  %.1f', x * 100, y * 100) or '--.-  --.-')
	end
	if db.motion then
		local speed = here.speed
		local text = '--'
		if speed then
			if db.speedUnit == 'percent' then text = format('%d%%', floor((here.pace or 0) + 0.5))
			else text = format('%.1f Y/S', speed) end
		end
		SetChip(holder.speed, text)
	end
end

-- The driver ------------------------------------------------------------------------------------
local since, demo = 0, {}

local function Step(_, elapsed)
	since = since + elapsed
	local rate = UI.db.navigation.rate == 20 and 20 or 30
	if since < 1 / rate then return end
	elapsed, since = min(since, 0.2), 0
	-- The UI scale or the frame's own scale changed: lay out again.
	local scale = holder:GetEffectiveScale()
	if not m.scale or abs(scale - m.scale) > 0.0001 then Layout() end
	local now = GetTime()
	local here
	if preview then
		here = demo
		demo.heading = (now * 18) % 360
		demo.moving, demo.moveDeg = true, (demo.heading + 40 * math.sin(now * 0.6)) % 360
		demo.speed, demo.pace, demo.x, demo.y = 7, 100, 0.421, 0.653
	else
		here = Nav:Sense(now)
		Nav:Tick(now)
	end
	local heading = here.heading
	local signal = heading ~= nil
	local holding = DB().location and Holding() and not preview
	if holding ~= m.holding then m.holding, m.zoneDirty = holding, true end
	if m.zoneDirty or holding then DrawZone() end
	DrawTicks(heading or 0, signal)
	DrawLabels(heading or 0, signal)
	holder.signal:SetShown(not signal)
	holder.lubber:SetShown(signal)
	DrawMotion(here, heading, elapsed)
	DrawPoints(here, heading, elapsed)
	Readouts(here, heading)
end

local function Wanted() return DB().enable and true or false end

local function Show()
	if not holder then return end
	local on = Wanted() or preview
	holder:SetShown(on)
end

-- Module --------------------------------------------------------------------------------------
local function Setup()
	if holder or not Wanted() then return end
	Build()
	Layout()
	holder:SetScript('OnShow', function()
		Nav:Want(module, true)
		m.zoneDirty, since = true, 1
	end)
	holder:SetScript('OnHide', function() Nav:Want(module, false) end)
	holder:SetScript('OnUpdate', Step)
	-- Scripts first: a frame hidden in unlock mode hooks OnShow when it registers.
	UI:RegisterMover(holder, 'nav.compass', 'Compass', {'TOP', 0, -40})
	function holder:SetPreview(on)
		preview = on and true or false
		for uid in pairs(slots) do Release(uid) end
		m.zoneDirty = true
		Show()
	end
	Nav:OnChange(function(what)
		if what == 'zone' or what == 'map' then m.zoneDirty = true end
	end)
	if holder:IsShown() then Nav:Want(module, true) end
	Show()
end

function module:Enable()
	Setup()
end

function module:Refresh()
	Setup()
	if not holder then return end
	Layout()
	UI:PlaceMover('nav.compass')
	Show()
end

Kit:OnRefresh(function() if holder then UI:Safe(Layout) end end)
