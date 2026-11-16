-- The aura timeline: a hairline track beside the player where your buffs (and,
-- if chosen, debuffs on you and your spell cooldowns) ride toward zero as their
-- time runs out. Each sits on a SPEC-01 key with a hairline stem down to its
-- point on the line and its time on a small LCD chip under it; keys that would
-- overlap stack into lanes above (or below) the line.
--
-- Positions never come from Lua arithmetic on a possibly secret duration. Each
-- entry owns an invisible StatusBar across the track, its range set to the
-- timeline's length; the client is handed the time left (a duration object's
-- GetRemainingDuration, secret or not) through SetValue, and the entry's point
-- is anchored to the fill texture's leading edge, so the engine places it. Times
-- longer than the track wait at the far end. Anything else secret (an aura's
-- length, a cooldown's active flag, whether a duration is zero) only reaches
-- SetAlphaFromBoolean on nested frames; nothing is compared.
--
-- Lanes: where times are plain, each key's spot is known, and keys take the
-- nearest free lane (re-checked four times a second, eased when they change).
-- A time made secret by a fight keeps an estimate from its last plain reading
-- (the clock runs the same either way); a key with no estimate at all takes
-- lanes in turn.
--
-- Only what is on the line shows. Each key sits in a window frame whose alpha
-- says whether its time left is on the line (above zero, at most the line's
-- length): set outright for a plain time, and for a secret one by a step curve
-- the duration object evaluates itself (the answer goes straight to the
-- alpha). A longer timer stays hidden until it drops onto the line; one that
-- has run out (or a cooldown that is ready) leaves at once. Auras that last
-- until cancelled are never tracked. The bars also reach well past the line
-- and live in a clip frame, so nothing can be drawn beyond its ends.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, GetTime = CreateFrame, UIParent, GetTime
local floor, max, min, abs, sin, ceil = math.floor, math.max, math.min, math.abs, math.sin, math.ceil
local GetActionInfo = (C_ActionBar and C_ActionBar.GetActionInfo) or _G.GetActionInfo

local module = UI:RegisterModule('timeline', {always = true})

local function IsSecret(value) return issecretvalue and issecretvalue(value) end
local function Plain(func, ...)
	if type(func) ~= 'function' then return nil end
	local ok, value = pcall(func, ...)
	if not ok or IsSecret(value) then return nil end
	return value
end

-- An aura update with nothing in it. Its fields can be secret: then it counts
-- as a full update, never tested.
local function AuraUpdateEmpty(info)
	if type(info) ~= 'table' then return false end
	for _, field in ipairs({'isFullUpdate', 'addedAuras', 'updatedAuraInstanceIDs', 'removedAuraInstanceIDs'}) do
		local value = info[field]
		if IsSecret(value) or value then return false end
	end
	return true
end

-- defaults:begin
UI:RegisterDefaults('timeline', {
	enable = true,
	buffs = 'mine', -- 'mine' (auras you cast) | 'all' | 'off'
	longBuffs = 0, -- seconds; an optional cap: buffs known to last longer are left off (0 keeps them all)
	debuffs = false, -- harmful auras on you
	cooldowns = true, -- your spell cooldowns from the action bars
	minCooldown = 5, -- seconds; shorter cooldowns are left out when that is known
	maxTime = 60, -- the track's length in seconds; longer times wait at the far end
	width = 260,
	iconSize = 24,
	lanes = 3, -- how many keys may stack at one spot
	stack = 'up', -- 'up' | 'down' | 'both'
	chip = 'lcd', -- 'lcd' | 'plain': the time under a key
	stems = true, -- a hairline from each key to its point on the line
	counts = true, -- stack counts on keys
	timeText = true,
	labels = true,
	orientation = 'horizontal', -- 'horizontal' | 'vertical'
	reverse = false, -- zero at the right (or top)
	maxEntries = 12,
	blacklist = '', -- spell IDs, separated by commas or spaces
})
-- defaults:end

local function DB() return UI.db.timeline end

-- Saved profiles catch up once: a short-lived build capped long buffs at 5
-- minutes; keys were small; and the line is for your own abilities and
-- cooldowns (buffs you cast, cooldowns on, debuffs off), which every saved
-- profile is moved to once.
local function Upgrade()
	local db = DB()
	local done = tonumber(db.upgraded) or 0
	if done >= 4 then return end
	if done < 2 and db.longBuffs == 300 then db.longBuffs = 0 end
	if done < 3 and db.iconSize == 20 then db.iconSize = 24 end
	db.buffs, db.cooldowns, db.debuffs = 'mine', true, false
	db.upgraded = 4
end

local INTERPOLATION = Enum and Enum.StatusBarInterpolation
local IMMEDIATE = INTERPOLATION and INTERPOLATION.Immediate
local WHITE = [[Interface\Buttons\WHITE8X8]]
local MARKS = {0, 5, 10, 30, 60, 120, 300, 600}
local CHIP_H, GAP, STEM_BASE, LABEL_BAND = 10, 3, 6, 11

local holder, lane, clip, line, caps, ticks, minors
local entries, active = {}, 0
local metrics
local preview = false

local function Reduced() return Kit.Reduced and Kit:Reduced() end

-- Text -------------------------------------------------------------------------
local function Label(seconds)
	if seconds >= 60 then return format('%dM', floor(seconds / 60)) end
	if seconds == 0 then return '0' end
	return format('%dS', seconds)
end

local function TimeText(remaining)
	if remaining >= 3600 then return format('%dh', floor(remaining / 3600 + 0.5)) end
	if remaining >= 60 then return format('%dm', floor(remaining / 60 + 0.5)) end
	if remaining >= 10 then return format('%d', floor(remaining + 0.5)) end
	return format('%.1f', max(remaining, 0))
end

local blocked, blockedSource = {}, nil
local function Blocked(spellID)
	local source = DB().blacklist or ''
	if source ~= blockedSource then
		blockedSource = source
		wipe(blocked)
		for id in tostring(source):gmatch('%d+') do blocked[tonumber(id)] = true end
	end
	if IsSecret(spellID) or spellID == nil then return false end
	return blocked[spellID] or false
end

-- Geometry -------------------------------------------------------------------
local function Vertical() return DB().orientation == 'vertical' end

-- Where along the track a time sits, 0..1 from the zero end.
local function Fraction(seconds) return min(1, seconds / max(DB().maxTime or 60, 1)) end

-- The leading edge of a fill, for the orientation and direction.
local function Edge()
	if Vertical() then return DB().reverse and 'BOTTOM' or 'TOP' end
	return DB().reverse and 'LEFT' or 'RIGHT'
end

-- Sizes, worked out once per layout. A cell is a key with its chip under it;
-- "along" runs with the line, "across" away from it.
local function Metrics()
	local db = DB()
	local m = {}
	m.size = db.iconSize or 24
	m.chipH = db.timeText and (CHIP_H + 1) or 0
	m.chipW = m.size + 8
	m.vertical = Vertical()
	m.cellAlong = m.vertical and (m.size + m.chipH) or m.chipW
	m.cellAcross = m.vertical and m.chipW or (m.size + m.chipH)
	m.pitch = m.cellAcross + GAP
	m.step = m.cellAlong + GAP
	m.lanes = max(1, floor(db.lanes or 3))
	m.length = max(db.width or 260, 80)
	m.alongSign = db.reverse and -1 or 1
	m.stack = db.stack or 'up'
	if m.stack == 'down' then m.upLanes = 0
	elseif m.stack == 'both' then m.upLanes = ceil(m.lanes / 2)
	else m.upLanes = m.lanes end
	m.downLanes = m.lanes - m.upLanes
	-- Scale labels sit on the side the keys don't use ('both': below).
	m.labelsUp = m.stack == 'down'
	m.baseUp = STEM_BASE + ((db.labels and m.labelsUp) and LABEL_BAND or 0)
	m.baseDown = STEM_BASE + ((db.labels and not m.labelsUp) and LABEL_BAND or 0)
	return m
end

-- Lane k of the stacking order: which side of the line, and how far out.
local function LaneStart(m, k)
	local side, index
	if m.stack == 'down' then side, index = -1, k
	elseif m.stack == 'both' then
		if k % 2 == 1 then side, index = 1, (k + 1) / 2 else side, index = -1, k / 2 end
	else side, index = 1, k end
	return side * ((side > 0 and m.baseUp or m.baseDown) + (index - 1) * m.pitch)
end

-- Place a cell: s is the signed distance of the cell's near edge from the line
-- (positive above, or right when vertical), a its offset along the line away
-- from zero. The stem joins the line to the cell's near edge.
local function PlaceCell(key, anchor, s, a, m, stem)
	local x, y
	if m.vertical then
		y = a * m.alongSign + m.chipH / 2
		x = s >= 0 and (s + m.chipW / 2) or (s - m.chipW / 2)
	else
		x = a * m.alongSign
		y = s >= 0 and (s + m.chipH + m.size / 2) or (s - m.size / 2)
	end
	key:ClearAllPoints()
	key:SetPoint('CENTER', anchor, 'CENTER', x, y)
	if not stem then return end
	local length = abs(s)
	local show = DB().stems and abs(a) < 0.5 and length > 1
	stem:SetShown(show and true or false)
	if not show then return end
	stem:ClearAllPoints()
	if m.vertical then
		stem:SetSize(length, m.px)
		stem:SetPoint(s >= 0 and 'LEFT' or 'RIGHT', anchor, 'CENTER', 0, 0)
	else
		stem:SetSize(m.px, length)
		stem:SetPoint(s >= 0 and 'BOTTOM' or 'TOP', anchor, 'CENTER', 0, 0)
	end
end

-- Keys ------------------------------------------------------------------------------
-- A key: the outer frame takes "is it running", the face "is it only the
-- global cooldown". On the face: the housing, the icon, a red edge for harmful
-- auras, the stack count; under it the time chip; behind it a glow that pulses
-- as it runs out.
local function MakeKey(parent, level)
	local key = CreateFrame('Frame', nil, parent)
	key:SetFrameLevel(level)
	key:EnableMouse(false)
	key.glow = Kit:Texture(key, 'glow', 'BACKGROUND', -2)
	key.glow:SetPoint('TOPLEFT', -8, 8)
	key.glow:SetPoint('BOTTOMRIGHT', 8, -8)
	key.glow:SetBlendMode('ADD')
	key.glow:SetAlpha(0)
	key.face = CreateFrame('Frame', nil, key)
	key.face:SetAllPoints(key)
	key.face:SetFrameLevel(level + 1)
	key.face.shell = Kit:Shell(key.face, {surface = 'paper', radius = 4, shadowAlpha = 0.35})
	key.icon = key.face:CreateTexture(nil, 'ARTWORK')
	key.icon:SetPoint('TOPLEFT', 2, -2)
	key.icon:SetPoint('BOTTOMRIGHT', -2, 2)
	key.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	local mask = key.face:CreateMaskTexture()
	mask:SetTexture(Kit.media..'mask-icon.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
	mask:SetAllPoints(key.icon)
	key.icon:AddMaskTexture(mask)
	key.edges = {}
	for index = 1, 4 do key.edges[index] = Kit:Solid(key.face, 'red', 'OVERLAY', 2) end
	key.count = Kit:Text(key.face, '', 9, 'white', true, true)
	key.count:SetPoint('TOPRIGHT', key, 'TOPRIGHT', 2, 2)
	key.chip = Kit:LCDPanel(key, {radius = 2})
	key.chip:SetFrameLevel(level + 2)
	Kit:Relevel(key.chip)
	key.chip.text = Kit:Text(key.chip, '', 8, 'lcdInk', true)
	key.chip.text:SetPoint('CENTER', 0, 0)
	return key
end

local function SizeKey(key, m, withChip)
	local db = DB()
	key:SetSize(m.size, m.size)
	local px = m.px
	local top, bottom, left, right = key.edges[1], key.edges[2], key.edges[3], key.edges[4]
	top:ClearAllPoints(); top:SetPoint('TOPLEFT', key, 'TOPLEFT', 1, -1); top:SetPoint('TOPRIGHT', key, 'TOPRIGHT', -1, -1); top:SetHeight(px)
	bottom:ClearAllPoints(); bottom:SetPoint('BOTTOMLEFT', key, 'BOTTOMLEFT', 1, 1); bottom:SetPoint('BOTTOMRIGHT', key, 'BOTTOMRIGHT', -1, 1); bottom:SetHeight(px)
	left:ClearAllPoints(); left:SetPoint('TOPLEFT', key, 'TOPLEFT', 1, -1); left:SetPoint('BOTTOMLEFT', key, 'BOTTOMLEFT', 1, 1); left:SetWidth(px)
	right:ClearAllPoints(); right:SetPoint('TOPRIGHT', key, 'TOPRIGHT', -1, -1); right:SetPoint('BOTTOMRIGHT', key, 'BOTTOMRIGHT', -1, 1); right:SetWidth(px)
	Kit:Font(key.count, max(8, floor(m.size * 0.38)), 'OUTLINE', true)
	key.count:SetShadowOffset(0, 0)
	local chip = key.chip
	chip:SetSize(m.chipW, CHIP_H)
	chip:ClearAllPoints()
	chip:SetPoint('TOP', key, 'BOTTOM', 0, -1)
	chip:SetShown((withChip and db.timeText) and true or false)
	local lcd = db.chip ~= 'plain'
	chip.shell:SetShown(lcd)
	if chip.inner then chip.inner:SetShown(lcd) end
	if lcd then
		Kit:Font(chip.text, 8, nil, true)
		Kit:Tint(chip.text, 'lcdInk')
		chip.text:SetShadowOffset(0, 0)
	else
		Kit:Font(chip.text, 9, 'OUTLINE', true)
		Kit:Tint(chip.text, 'white')
		chip.text:SetShadowOffset(1, -1)
	end
end

-- Entries -----------------------------------------------------------------------------
-- Each entry's key hangs off a point that rides the fill edge of the entry's
-- own (invisible) StatusBar. The bar runs RANGE times the line's length past
-- zero, on the same scale, and lives in the clip frame, which shows only the
-- line itself: a key with more time left than the line rides out past the
-- clip's end, unseen, and slides on as its time drops below the line's length.
-- The gate takes a secret "lasts forever" answer, the motion frame fades a key
-- in as it arrives.
local RANGE = 6

local function NewEntry(index)
	local entry = {index = index}
	entry.bar = CreateFrame('StatusBar', nil, clip)
	entry.bar:SetStatusBarTexture(WHITE)
	entry.bar:EnableMouse(false)
	local fill = entry.bar:GetStatusBarTexture()
	fill:SetAlpha(0)
	-- An exact edge, not one snapped to the pixel grid, so the key glides.
	if fill.SetSnapToPixelGrid then fill:SetSnapToPixelGrid(false); fill:SetTexelSnappingBias(0) end
	entry.point = CreateFrame('Frame', nil, entry.bar)
	entry.point:SetSize(1, 1)
	local level = holder:GetFrameLevel() + 8 + index * 4
	entry.gate = CreateFrame('Frame', nil, entry.bar)
	entry.gate:SetAllPoints(clip)
	entry.gate:EnableMouse(false)
	-- The window: shown only while the time left is on the line (above zero,
	-- at most the line's length). Its alpha is the source of truth for that.
	entry.window = CreateFrame('Frame', nil, entry.gate)
	entry.window:SetAllPoints(clip)
	entry.window:EnableMouse(false)
	entry.window:SetAlpha(0)
	entry.motion = CreateFrame('Frame', nil, entry.window)
	entry.motion:SetAllPoints(clip)
	entry.motion:EnableMouse(false)
	entry.key = MakeKey(entry.motion, level)
	-- The stem and the lit tick where it meets the line hide with the key.
	entry.stem = Kit:Solid(entry.key, 'white', 'BACKGROUND', -4, 0.55)
	entry.tick = Kit:Solid(entry.key, 'lamp', 'OVERLAY', 4)
	entry.bar:Hide()
	entries[index] = entry
	return entry
end

local function LayoutEntry(entry)
	local db, m = DB(), metrics
	if not m then return end
	local bar = entry.bar
	bar:SetOrientation(m.vertical and 'VERTICAL' or 'HORIZONTAL')
	bar:SetReverseFill(db.reverse and true or false)
	bar:SetMinMaxValues(0, max(db.maxTime or 60, 1) * RANGE)
	-- From the zero end, RANGE times the line's length, on the line.
	bar:ClearAllPoints()
	local zero = m.vertical and (db.reverse and 'TOP' or 'BOTTOM') or (db.reverse and 'RIGHT' or 'LEFT')
	bar:SetPoint(zero, lane, zero, 0, 0)
	if m.vertical then bar:SetSize(m.px, m.length * RANGE) else bar:SetSize(m.length * RANGE, m.px) end
	entry.point:ClearAllPoints()
	entry.point:SetPoint('CENTER', bar:GetStatusBarTexture(), Edge())
	SizeKey(entry.key, m, true)
	entry.tick:ClearAllPoints()
	entry.tick:SetSize(3 * m.px, 3 * m.px)
	entry.tick:SetPoint('CENTER', entry.point, 'CENTER', 0, 0)
	if entry.sNow then PlaceCell(entry.key, entry.point, entry.sNow, 0, m, entry.stem) end
end

-- Lanes -------------------------------------------------------------------------------
local prevLane = {} -- identity -> the lane it had, so keys keep their lane when they can
local laneNow = {} -- identity -> where its key is now, carried across rebuilds

-- Work out every visible key's lane. Cheap: a dozen entries, a few lanes.
-- Keys still beyond the line take no room; they keep the lane they had.
local function Arrange()
	local m = metrics
	if not m or active == 0 then return end
	local length, maxTime, lanes = m.length, max(DB().maxTime or 60, 1), m.lanes
	local half = m.cellAlong / 2 + GAP / 2
	local busy = {}
	for k = 1, lanes do busy[k] = {} end
	local function Free(k, lo, hi)
		for _, span in ipairs(busy[k]) do
			if lo < span[2] and hi > span[1] then return false end
		end
		return true
	end
	local known, unknown = {}, {}
	for index = 1, active do
		local entry = entries[index]
		local left = entry.estimate
		if left and left > maxTime then
			local had = entry.identity and prevLane[entry.identity]
			entry.lane = (had and had <= lanes) and had or 1
		elseif left then
			entry.pos = length * left / maxTime
			known[#known + 1] = entry
		else
			unknown[#unknown + 1] = entry
		end
	end
	-- Keys on the line, nearest zero first: the lane they had if it is still
	-- free, else the lowest free one, else the least crowded.
	table.sort(known, function(a, b) return a.pos < b.pos end)
	for _, entry in ipairs(known) do
		local lo, hi = entry.pos - half, entry.pos + half
		local choice
		local had = entry.identity and prevLane[entry.identity]
		if had and had <= lanes and Free(had, lo, hi) then choice = had end
		if not choice then
			for k = 1, lanes do if Free(k, lo, hi) then choice = k break end end
		end
		if not choice then
			choice = 1
			for k = 2, lanes do if #busy[k] < #busy[choice] then choice = k end end
		end
		entry.lane = choice
		local list = busy[choice]
		list[#list + 1] = {lo, hi}
	end
	-- No time to read at all: lanes in turn.
	for order, entry in ipairs(unknown) do entry.lane = (order - 1) % lanes + 1 end
	for index = 1, active do
		local entry = entries[index]
		entry.sGoal = LaneStart(m, entry.lane or 1)
		if entry.identity then prevLane[entry.identity] = entry.lane end
		if entry.sNow == nil then
			-- New: slide in from a little further out.
			local fresh = entry.fresh and not Reduced()
			entry.sNow = entry.sGoal + (fresh and (entry.sGoal >= 0 and 8 or -8) or 0)
			PlaceCell(entry.key, entry.point, entry.sNow, 0, m, entry.stem)
		end
	end
end

-- Ease each key toward its lane.
local function Ease(entry, elapsed)
	if not (entry.sGoal and entry.sNow) then return end
	local ds = entry.sGoal - entry.sNow
	if abs(ds) < 0.05 then
		if ds ~= 0 then
			entry.sNow = entry.sGoal
			PlaceCell(entry.key, entry.point, entry.sNow, 0, metrics, entry.stem)
			if entry.identity then laneNow[entry.identity] = entry.sNow end
		end
		return
	end
	entry.sNow = entry.sNow + ds * (Reduced() and 1 or min(1, elapsed * 12))
	PlaceCell(entry.key, entry.point, entry.sNow, 0, metrics, entry.stem)
	if entry.identity then laneNow[entry.identity] = entry.sNow end
end

-- Driver ------------------------------------------------------------------------
local driver = CreateFrame('Frame')
driver:Hide()
local wait, sinceArrange = 0, 0
local Pop

-- The last plain time each identity showed, and when, so a time a fight makes
-- secret still has an estimate for lanes and minutes.
local known, knownAt = {}, {}

-- Whether a time left is on the line: 0 below 0.05 s (run out, or a cooldown
-- that is ready), 1 up to the line's length, 0 beyond. A step curve the
-- duration object evaluates itself, so a secret time is never read; the
-- answer (secret or not) goes straight to an alpha.
local windowCurves = {}
local function WindowCurve(maxTime)
	local curve = windowCurves[maxTime]
	if curve ~= nil then return curve or nil end
	curve = false
	if C_CurveUtil and C_CurveUtil.CreateCurve then
		local ok, made = pcall(C_CurveUtil.CreateCurve)
		if ok and made then
			if made.SetType and Enum and Enum.LuaCurveType and Enum.LuaCurveType.Step then made:SetType(Enum.LuaCurveType.Step) end
			made:AddPoint(0, 0)
			made:AddPoint(0.05, 1)
			made:AddPoint(maxTime + 0.001, 0)
			curve = made
		end
	end
	windowCurves[maxTime] = curve
	return curve or nil
end

local function OnLine(left, maxTime) return (left >= 0.05 and left <= maxTime) and 1 or 0 end

local function Tick(entry, now)
	local db = DB()
	local remaining, secret, value = nil, false, nil
	if entry.duration then
		local ok
		ok, value = pcall(entry.duration.GetRemainingDuration, entry.duration)
		if not ok then return end
		entry.bar:SetValue(value, IMMEDIATE)
		if IsSecret(value) then secret = true else remaining = value end
	elseif entry.expires then
		remaining = max(entry.expires - now, 0)
		entry.bar:SetValue(remaining, IMMEDIATE)
	end
	local id = entry.identity
	if remaining then
		entry.last, entry.estimate = remaining, remaining
		if id then known[id], knownAt[id] = remaining, now end
	elseif secret then
		local base = id and known[id]
		entry.estimate = base and max(base - (now - knownAt[id]), 0) or nil
	end
	if db.timeText then
		local text = entry.key.chip.text
		if remaining then text:SetText(TimeText(remaining))
		elseif entry.estimate and entry.estimate >= 60 then text:SetText(TimeText(entry.estimate))
		elseif secret then text:SetFormattedText('%.1f', value) end -- the widget formats a secret; no Lua reads it
	end
	-- Shown only while on the line: a plain time decides outright, a secret one
	-- through the curve (exact), else the estimate.
	local maxTime = max(db.maxTime or 60, 1)
	if remaining then
		entry.window:SetAlpha(OnLine(remaining, maxTime))
	else
		local curve = secret and entry.duration.EvaluateRemainingDuration and WindowCurve(maxTime)
		local shown = false
		if curve then
			local ok, alpha = pcall(entry.duration.EvaluateRemainingDuration, entry.duration, curve, 0)
			if ok then entry.window:SetAlpha(alpha); shown = true end
		end
		if not shown then entry.window:SetAlpha(entry.estimate and OnLine(entry.estimate, maxTime) or 1) end
	end
	-- Arriving: a time read (or estimated) crossing onto the line from beyond
	-- it fades the key in with a short lamp flash.
	local left = remaining or entry.estimate
	if left then
		local beyond = left > maxTime
		if entry.beyond and not beyond and not Reduced() then
			entry.motion:SetAlpha(0)
			Kit:FadeTo(entry.motion, 1, 'FAST')
			if Kit.Flash then Kit:Flash(entry.key, {token = 'lamp', alpha = 0.55, duration = 0.3}) end
		end
		entry.beyond = beyond
	end
	-- Running out: the glow behind the key pulses.
	local soon = left and left > 0 and left < 3 and not Reduced()
	if soon then
		entry.key.glow:SetAlpha(0.25 + 0.4 * (0.5 + 0.5 * sin(now * 10)))
		entry.pulsing = true
	elseif entry.pulsing then
		entry.pulsing = nil
		entry.key.glow:SetAlpha(0)
	end
	if remaining and remaining <= 0 and entry.expires and not entry.popped then
		entry.popped = true
		Pop()
	end
end

driver:SetScript('OnUpdate', function(self, elapsed)
	wait = wait + elapsed
	if wait < 1 / 30 then return end
	local step = wait
	wait = 0
	if active == 0 or not holder:IsVisible() then self:Hide() return end
	local now = GetTime()
	for index = 1, active do UI:Safe(Tick, entries[index], now) end
	sinceArrange = sinceArrange + step
	if sinceArrange >= 0.25 then
		sinceArrange = 0
		UI:Safe(Arrange)
	end
	for index = 1, active do UI:Safe(Ease, entries[index], step) end
end)

-- A small flash at the zero end (wherever it is) when something runs out.
function Pop()
	if not caps or not Kit.Flash then return end
	Kit:Flash(caps.zero, {token = 'lamp', alpha = 0.6, duration = 0.35})
end

-- Collecting ---------------------------------------------------------------------
local actionSpells, actionDirty = {}, true
local function ActionSpells()
	if not actionDirty then return actionSpells end
	actionDirty = false
	wipe(actionSpells)
	local seen = {}
	local has = (C_ActionBar and C_ActionBar.HasAction) or HasAction
	for slot = 1, 180 do
		if has and Plain(has, slot) then
			local ok, kind, id, subType = pcall(GetActionInfo, slot)
			if ok and not IsSecret(kind) and not IsSecret(id) and id and not seen[id]
				and (kind == 'spell' or (kind == 'macro' and not IsSecret(subType) and subType == 'spell')) then
				seen[id] = true
				actionSpells[#actionSpells + 1] = id
			end
		end
	end
	return actionSpells
end

-- Buffs seen to be long (a flask, a raid buff) while their length was plain,
-- by aura and by spell, so the optional cap still leaves them off when a fight
-- hides lengths.
local longAuras, longSpells, longCount = {}, {}, 0
local function RememberLong(id, spellID)
	if longCount > 400 then wipe(longAuras); wipe(longSpells); longCount = 0 end
	longCount = longCount + 1
	if not IsSecret(id) and id ~= nil then longAuras[id] = true end
	if not IsSecret(spellID) and spellID ~= nil then longSpells[spellID] = true end
end
local function KnownLong(id, spellID)
	if not IsSecret(id) and id ~= nil and longAuras[id] then return true end
	if not IsSecret(spellID) and spellID ~= nil and longSpells[spellID] then return true end
	return false
end

-- Auras seen plainly lasting until cancelled (a seal, an aura, a form), by
-- aura and by spell: in a fight, where their length is secret, they are still
-- known to stay off the line.
local lastingAuras, lastingSpells, lastingCount = {}, {}, 0
local function RememberLasting(id, spellID)
	if lastingCount > 400 then wipe(lastingAuras); wipe(lastingSpells); lastingCount = 0 end
	lastingCount = lastingCount + 1
	if not IsSecret(id) and id ~= nil then lastingAuras[id] = true end
	if not IsSecret(spellID) and spellID ~= nil then lastingSpells[spellID] = true end
end
local function KnownLasting(id, spellID)
	if not IsSecret(id) and id ~= nil and lastingAuras[id] then return true end
	if not IsSecret(spellID) and spellID ~= nil and lastingSpells[spellID] then return true end
	return false
end

-- One aura as an item, or nil. Only timed auras are kept: one that lasts until
-- cancelled (a seal, an aura, a form), or that the game won't time, never
-- shows. A timed one longer than the line is kept too, but rides beyond the
-- line's clipped end until its time left drops onto the line. When whether it
-- lasts forever is a secret, that answer hides the key by alpha.
local function AuraItem(data, harmful)
	local length = data.duration
	local id, spellID = data.auraInstanceID, data.spellId
	if Blocked(spellID) then return nil end
	local plainLength = not IsSecret(length)
	if plainLength and (not length or length <= 0) then
		RememberLasting(id, spellID)
		return nil
	end
	if not plainLength and KnownLasting(id, spellID) then return nil end
	-- The optional cap on long buffs (0, the default, keeps them all).
	local longest = DB().longBuffs or 0
	if not harmful and longest > 0 then
		if not plainLength then
			if KnownLong(id, spellID) then return nil end
		elseif length > longest then
			RememberLong(id, spellID)
			return nil
		end
	end
	local item = {icon = data.icon, kind = harmful and 'harm' or 'help'}
	item.auraID, item.apps = id, data.applications
	if not IsSecret(id) then item.identity = id end
	-- The duration object; a secret instance ID is passed on untested.
	if C_UnitAuras.GetAuraDuration and (IsSecret(id) or id ~= nil) then
		local ok, duration = pcall(C_UnitAuras.GetAuraDuration, 'player', id)
		if ok and duration and duration.GetRemainingDuration then item.duration = duration end
	end
	if item.duration and not plainLength and item.duration.IsZero then
		local okZero, zero = pcall(item.duration.IsZero, item.duration)
		if okZero then
			if IsSecret(zero) then item.zeroFlag, item.hasZero = zero, true
			elseif zero then return nil end
		end
	end
	local expires = data.expirationTime
	if not item.duration then
		if IsSecret(expires) or not plainLength or not expires or expires <= 0 then return nil end
		item.expires, item.length = expires, length
	end
	-- Whether it is on the line now, where that can be read: soon, later or unknown.
	if plainLength and not IsSecret(expires) and type(expires) == 'number' and expires > 0 then
		item.later = (expires - GetTime()) > max(DB().maxTime or 60, 1)
	else
		item.unknown = true
	end
	return item
end

local function CooldownItem(spellID)
	if Blocked(spellID) or not (C_Spell and C_Spell.GetSpellCooldown) then return nil end
	local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
	if not ok or type(info) ~= 'table' then return nil end
	local isActive, onGCD, length = info.isActive, info.isOnGCD, info.duration
	-- Plain answers rule entries out; secret ones are handed to alpha below.
	if not IsSecret(isActive) and isActive == false then return nil end
	if not IsSecret(onGCD) and onGCD then return nil end
	if not IsSecret(length) then
		if not length or length <= 0 or length < (DB().minCooldown or 0) then return nil end
	end
	local icon
	if C_Spell.GetSpellTexture then
		local got, texture = pcall(C_Spell.GetSpellTexture, spellID)
		if got then icon = texture end
	end
	local item = {icon = icon, kind = 'cooldown', identity = 'cd'..spellID}
	if IsSecret(isActive) then item.activeFlag, item.hasActive = isActive, true end
	if IsSecret(onGCD) then item.gcdFlag, item.hasGCD = onGCD, true end
	if C_Spell.GetSpellCooldownDuration then
		local got, duration = pcall(C_Spell.GetSpellCooldownDuration, spellID)
		if got and duration and duration.GetRemainingDuration then item.duration = duration end
	end
	if item.duration and item.duration.IsZero then
		local okZero, zero = pcall(item.duration.IsZero, item.duration)
		if okZero then
			if IsSecret(zero) then item.zeroFlag, item.hasZero = zero, true elseif zero then return nil end
		end
	end
	-- Unknown whether it runs at all: it shows only if it does, and doesn't use up a slot.
	item.uncounted = item.hasActive or item.hasZero
	if not item.duration then
		local start = info.startTime
		if IsSecret(start) or IsSecret(length) or not start or not length then return nil end
		item.expires, item.length = start + length, length
	end
	return item
end

-- Every aura and cooldown is read in its own protected call, so one that
-- errors can't take the others off the line. What is on the line (or may be)
-- comes first, then cooldowns, then auras still waiting beyond the line, so
-- slots go to what can be seen.
local function Collect()
	local items, db = {}, DB()
	local limit = db.maxEntries or 12
	local counted = 0
	local function Add(item)
		if not item or counted >= limit then return end
		items[#items + 1] = item
		if not item.uncounted then counted = counted + 1 end
	end
	local now, later = {}, {}
	local function Scan(filter, harmful)
		for index = 1, 40 do
			local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, 'player', index, filter)
			if not ok or type(data) ~= 'table' then return end
			local built, item = pcall(AuraItem, data, harmful)
			if not built then
				if geterrorhandler then geterrorhandler()(item) end
			elseif item then
				local list = item.later and later or now
				list[#list + 1] = item
			end
		end
	end
	if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
		if db.buffs ~= 'off' then Scan(db.buffs == 'all' and 'HELPFUL' or 'HELPFUL|PLAYER', false) end
		if db.debuffs then Scan('HARMFUL', true) end
	end
	for _, item in ipairs(now) do Add(item) end
	if db.cooldowns then
		for _, spellID in ipairs(ActionSpells()) do
			if counted >= limit then break end
			local built, item = pcall(CooldownItem, spellID)
			if built then Add(item) elseif geterrorhandler then geterrorhandler()(item) end
		end
	end
	for _, item in ipairs(later) do Add(item) end
	return items
end

-- Assigning -----------------------------------------------------------------------
local SURFACE = {help = 'paper', harm = 'glass', cooldown = 'lcd'}

-- The stack count: a plain count over one, or the game's own display string
-- for a secret one (handed straight to the widget).
local function Count(key, item)
	local text = ''
	if DB().counts and item.kind ~= 'cooldown' then
		local apps = item.apps
		if IsSecret(apps) then
			local api = C_UnitAuras and C_UnitAuras.GetAuraApplicationDisplayCount
			if api then
				local ok, shown = pcall(api, 'player', item.auraID, 2, 999)
				if ok then key.count:SetText(shown) return end
			end
		elseif type(apps) == 'number' and apps > 1 then
			text = tostring(apps)
		end
	end
	key.count:SetText(text)
end

local function Dress(key, item, entry, field)
	key.icon:SetTexture(item.icon)
	if entry[field] ~= item.kind then
		entry[field] = item.kind
		Kit:SetSurface(key.face.shell, SURFACE[item.kind] or 'paper')
		local harm = item.kind == 'harm'
		for _, edge in ipairs(key.edges) do edge:SetShown(harm) end
		Kit:Tint(key.glow, harm and 'red' or 'lamp')
	end
	key.chip.text:SetText('')
	key.glow:SetAlpha(0)
	key:SetAlpha(1)
	key.face:SetAlpha(1)
	Count(key, item)
end

local function Clear(entry)
	entry.bar:Hide()
	entry.duration, entry.expires, entry.identity, entry.last, entry.popped = nil, nil, nil, nil, nil
	entry.estimate, entry.pulsing, entry.beyond, entry.lane, entry.sGoal, entry.sNow = nil, nil, nil, nil, nil, nil
end

-- Every field an entry had is reset here, so a reused entry carries nothing
-- (timer, gate alphas, lane) over from what it showed before.
local function Assign(entry, item, seen)
	entry.duration, entry.expires, entry.popped, entry.last = item.duration, item.expires, nil, nil
	entry.identity, entry.estimate, entry.pulsing, entry.beyond = item.identity, nil, nil, nil
	entry.lane, entry.sGoal = nil, nil
	-- Where its key is: carried over for an aura seen before, else it slides in.
	local id = item.identity
	entry.sNow = id and laneNow[id] or nil
	entry.fresh = (id ~= nil and not seen[id]) and true or nil
	Dress(entry.key, item, entry, 'surface')
	local top = max(DB().maxTime or 60, 1) * RANGE
	entry.bar:SetMinMaxValues(0, top)
	-- Until its first tick, the key waits out of sight past the line.
	entry.bar:SetValue(top, IMMEDIATE)
	entry.window:SetAlpha(0)
	-- A secret "lasts forever" reaches the gate's alpha, untested.
	entry.gate:SetAlpha(1)
	if item.hasZero and entry.gate.SetAlphaFromBoolean then entry.gate:SetAlphaFromBoolean(item.zeroFlag, 0, 1) end
	-- "Is it running" and "is it only the global cooldown", when secret.
	if item.hasActive and entry.key.SetAlphaFromBoolean then entry.key:SetAlphaFromBoolean(item.activeFlag, 1, 0) end
	if item.hasGCD and entry.key.face.SetAlphaFromBoolean then entry.key.face:SetAlphaFromBoolean(item.gcdFlag, 0, 1) end
	-- A new one fades in as it slides into its lane.
	if entry.fresh and not Reduced() then
		entry.motion:SetAlpha(0)
		Kit:FadeTo(entry.motion, 1, 'FAST')
	else
		entry.motion:SetAlpha(1)
	end
	LayoutEntry(entry)
	entry.bar:Show()
end

local function Prune(table1, keep)
	for id in pairs(table1) do if not keep[id] then table1[id] = nil end end
end

local function Rebuild()
	if not holder then return end
	Upgrade()
	if not DB().enable then holder:Hide() driver:Hide() return end
	holder:Show()
	if preview then return end
	-- What ran out since last time (plain identities whose last time was nearly zero).
	local before, seen = {}, {}
	for index = 1, active do
		local entry = entries[index]
		if entry.identity then
			seen[entry.identity] = true
			before[entry.identity] = entry.last
		end
	end
	local items = Collect()
	local now, shown = {}, 0
	for _, item in ipairs(items) do
		local entry = entries[shown + 1] or NewEntry(shown + 1)
		if UI:Safe(Assign, entry, item, seen) then
			shown = shown + 1
			if item.identity then now[item.identity] = true end
		else
			Clear(entry)
		end
	end
	for index = shown + 1, #entries do Clear(entries[index]) end
	active = shown
	Prune(known, now); Prune(knownAt, now); Prune(prevLane, now); Prune(laneNow, now)
	for identity, last in pairs(before) do
		if not now[identity] and last and last < 1.5 then Pop() break end
	end
	if active > 0 then
		local stamp = GetTime()
		for index = 1, active do UI:Safe(Tick, entries[index], stamp) end
		UI:Safe(Arrange)
		sinceArrange = 0
		driver:Show()
	else
		driver:Hide()
	end
end

local queued
local function Queue()
	if queued then return end
	queued = true
	C_Timer.After(0, function()
		queued = nil
		UI:Safe(Rebuild)
	end)
end

-- The track -----------------------------------------------------------------------
local function Mark(pool, index, minor)
	local mark = pool[index]
	if not mark then
		mark = {tex = holder:CreateTexture(nil, 'ARTWORK')}
		mark.tex:SetColorTexture(1, 1, 1, 1)
		if not minor then
			mark.text = Kit:Text(holder, '', 7, 'darkDim', true, true)
		end
		pool[index] = mark
	end
	return mark
end

-- A mark at a time, reaching toward the labels' side; its label beyond it.
local function PlaceMark(mark, seconds, m, height, alpha)
	local fraction = Fraction(seconds)
	if DB().reverse then fraction = 1 - fraction end
	local along = m.length * fraction
	local tex, toward = mark.tex, m.labelsUp
	tex:ClearAllPoints()
	tex:SetAlpha(alpha)
	if m.vertical then
		tex:SetSize(height, m.px)
		tex:SetPoint(toward and 'LEFT' or 'RIGHT', lane, 'BOTTOM', 0, along)
	else
		tex:SetSize(m.px, height)
		tex:SetPoint(toward and 'BOTTOM' or 'TOP', lane, 'LEFT', along, 0)
	end
	tex:Show()
	if mark.text then
		mark.text:ClearAllPoints()
		if m.vertical then
			if toward then mark.text:SetPoint('LEFT', tex, 'RIGHT', 2, 0) else mark.text:SetPoint('RIGHT', tex, 'LEFT', -2, 0) end
		else
			if toward then mark.text:SetPoint('BOTTOM', tex, 'TOP', 0, 1) else mark.text:SetPoint('TOP', tex, 'BOTTOM', 0, -1) end
		end
		mark.text:SetText(Label(seconds))
		mark.text:SetShown(DB().labels and true or false)
	end
end

local function LayoutTrack()
	local db = DB()
	local m = Metrics()
	m.px = UI.Pixel and UI.Pixel.Px(holder, 1) or 1
	metrics = m
	local length = m.length
	-- Room for the lanes on each side, and for the labels.
	local upExt = m.upLanes > 0 and (m.baseUp + m.upLanes * m.pitch) or ((db.labels and m.labelsUp) and LABEL_BAND + 2 or 4)
	local downExt = m.downLanes > 0 and (m.baseDown + m.downLanes * m.pitch) or ((db.labels and not m.labelsUp) and LABEL_BAND + 2 or 4)
	lane:ClearAllPoints()
	if m.vertical then
		holder:SetSize(upExt + downExt, length + 12)
		lane:SetPoint('BOTTOMLEFT', holder, 'BOTTOMLEFT', downExt, 6)
		lane:SetSize(m.px, length)
	else
		holder:SetSize(length + 12, upExt + downExt)
		lane:SetPoint('BOTTOMLEFT', holder, 'BOTTOMLEFT', 6, downExt)
		lane:SetSize(length, m.px)
	end
	-- The hairline, with a shadow line for contrast against the world.
	line:ClearAllPoints()
	line:SetAllPoints(lane)
	line.shadow:ClearAllPoints()
	if m.vertical then
		line.shadow:SetPoint('TOPLEFT', line, 'TOPRIGHT'); line.shadow:SetPoint('BOTTOMLEFT', line, 'BOTTOMRIGHT'); line.shadow:SetWidth(m.px)
	else
		line.shadow:SetPoint('TOPLEFT', line, 'BOTTOMLEFT'); line.shadow:SetPoint('TOPRIGHT', line, 'BOTTOMRIGHT'); line.shadow:SetHeight(m.px)
	end
	-- The "now" lamp at zero and a small square at the far end.
	local zeroPoint = m.vertical and (db.reverse and 'TOP' or 'BOTTOM') or (db.reverse and 'RIGHT' or 'LEFT')
	local farSide = m.vertical and (db.reverse and 'BOTTOM' or 'TOP') or (db.reverse and 'LEFT' or 'RIGHT')
	caps.zero:ClearAllPoints(); caps.zero:SetSize(7, 7); caps.zero:SetPoint('CENTER', lane, zeroPoint)
	caps.far:ClearAllPoints(); caps.far:SetSize(4, 4); caps.far:SetPoint('CENTER', lane, farSide)
	-- The clip: exactly the line, plus a key's overhang (and its glow) at the
	-- zero end and half a key at the far end, so a key whose time left is the
	-- line's length still shows whole and anything longer slides out of sight.
	-- Across, it holds every lane.
	local over, farOver = m.cellAlong / 2 + 8, m.cellAlong / 2 + 1
	local up, down = upExt + 8, downExt + 8
	clip:ClearAllPoints()
	if m.vertical then
		if db.reverse then
			clip:SetPoint('TOPLEFT', lane, 'TOP', -down, over)
			clip:SetPoint('BOTTOMRIGHT', lane, 'TOP', up, -(length + farOver))
		else
			clip:SetPoint('BOTTOMLEFT', lane, 'BOTTOM', -down, -over)
			clip:SetPoint('TOPRIGHT', lane, 'BOTTOM', up, length + farOver)
		end
	elseif db.reverse then
		clip:SetPoint('BOTTOMRIGHT', lane, 'RIGHT', over, -down)
		clip:SetPoint('TOPLEFT', lane, 'RIGHT', -(length + farOver), up)
	else
		clip:SetPoint('BOTTOMLEFT', lane, 'LEFT', -over, -down)
		clip:SetPoint('TOPRIGHT', lane, 'LEFT', length + farOver, up)
	end
	-- Labelled marks, and minor ticks between them on the linear scale.
	local maxTime = max(db.maxTime or 60, 1)
	local labelled, isLabel = {}, {}
	for _, seconds in ipairs(MARKS) do
		if seconds <= maxTime then labelled[#labelled + 1] = seconds; isLabel[seconds] = true end
	end
	if labelled[#labelled] ~= maxTime then labelled[#labelled + 1] = maxTime; isLabel[maxTime] = true end
	for index, seconds in ipairs(labelled) do
		PlaceMark(Mark(ticks, index), seconds, m, (seconds == 0 or seconds == maxTime) and 5 or 4, 0.8)
	end
	for index = #labelled + 1, #ticks do ticks[index].tex:Hide(); ticks[index].text:Hide() end
	local count, seconds = 0, 0
	while seconds < maxTime and count < 90 do
		local step = seconds < 10 and 1 or (seconds < 60 and 5 or (seconds < 300 and 30 or 60))
		seconds = seconds + step
		if seconds < maxTime and not isLabel[seconds] then
			count = count + 1
			PlaceMark(Mark(minors, count, true), seconds, m, 2, 0.35)
		end
	end
	for index = count + 1, #minors do minors[index].tex:Hide() end
	for index, entry in ipairs(entries) do
		entry.sNow = entry.sGoal or entry.sNow
		if index <= active then LayoutEntry(entry) end
	end
	UI:Safe(Arrange)
end

local function Build()
	holder = CreateFrame('Frame', 'JiberishSpec01Timeline', UIParent)
	holder:SetFrameStrata('MEDIUM')
	holder:EnableMouse(false)
	lane = CreateFrame('Frame', nil, holder)
	lane:EnableMouse(false)
	line = holder:CreateTexture(nil, 'BORDER')
	line:SetColorTexture(1, 1, 1, 0.85)
	line.shadow = holder:CreateTexture(nil, 'BACKGROUND')
	line.shadow:SetColorTexture(0, 0, 0, 0.55)
	clip = CreateFrame('Frame', nil, holder)
	clip:SetClipsChildren(true)
	clip:EnableMouse(false)
	clip:SetFrameLevel(holder:GetFrameLevel() + 4)
	-- The end caps are small frames, so a flash can be laid on them. Zero is a
	-- lit lamp with its glow: "now".
	local function Cap()
		local cap = CreateFrame('Frame', nil, holder)
		cap:SetFrameLevel(holder:GetFrameLevel() + 3)
		cap:EnableMouse(false)
		return cap
	end
	caps = {zero = Cap(), far = Cap()}
	caps.zero.lamp = Kit:Led(caps.zero, 7, true)
	caps.zero.lamp:SetPoint('CENTER')
	caps.far.square = caps.far:CreateTexture(nil, 'ARTWORK')
	caps.far.square:SetAllPoints()
	caps.far.square:SetColorTexture(1, 1, 1, 0.85)
	-- After the whole UI was hidden (Alt+Z, a cinematic) the driver starts again.
	holder:HookScript('OnShow', function() if active > 0 then driver:Show() end end)
	ticks, minors = {}, {}
	LayoutTrack()
	UI:RegisterMover(holder, 'tl.player', 'Aura timeline', {'BOTTOM', -228, 330})

	-- Placing it: made-up entries counting down so the track and its stacking
	-- show; the last one waits past the line and arrives after a few seconds.
	local fakes = {
		{7.8, 'help', 136243}, {9.5, 'harm', 135987, 3}, {24, 'cooldown', 136085},
		{38, 'help', 135932}, {66, 'help', 136116},
	}
	function holder:SetPreview(on)
		preview = on and true or false
		if not on then return Rebuild() end
		holder:Show()
		local stamp = GetTime()
		for index, fake in ipairs(fakes) do
			local entry = entries[index] or NewEntry(index)
			local item = {icon = fake[3], kind = fake[2], apps = fake[4], identity = 'preview'..index}
			item.expires, item.length = stamp + fake[1], fake[1]
			UI:Safe(Assign, entry, item, {})
		end
		for index = #fakes + 1, #entries do Clear(entries[index]) end
		active = #fakes
		for index = 1, active do UI:Safe(Tick, entries[index], stamp) end
		UI:Safe(Arrange)
		driver:Show()
	end
end

function module:Enable()
	Upgrade()
	Build()
	local events = CreateFrame('Frame')
	events:RegisterUnitEvent('UNIT_AURA', 'player')
	for _, event in ipairs({'PLAYER_ENTERING_WORLD', 'SPELL_UPDATE_COOLDOWN', 'SPELLS_CHANGED', 'ACTIONBAR_SLOT_CHANGED',
		'PLAYER_TALENT_UPDATE'}) do
		pcall(events.RegisterEvent, events, event)
	end
	events:SetScript('OnEvent', function(_, event, unit, info)
		if event == 'UNIT_AURA' then
			if AuraUpdateEmpty(info) then return end
		elseif event == 'ACTIONBAR_SLOT_CHANGED' or event == 'SPELLS_CHANGED' or event == 'PLAYER_TALENT_UPDATE' then
			actionDirty = true
			if not DB().cooldowns then return end
		elseif event == 'SPELL_UPDATE_COOLDOWN' then
			if not DB().cooldowns then return end
		end
		Queue()
	end)
	Rebuild()
end

function module:Refresh()
	if not holder then return end
	if not InCombatLockdown() then
		LayoutTrack()
		UI:PlaceMover('tl.player')
	end
	Queue()
end

-- Hub ------------------------------------------------------------------------------
local function Off() return not DB().enable end
local function Seconds(value) return value >= 60 and format('%dm %02ds', floor(value / 60), value % 60) or format('%ds', value) end
local function Whole(value) return tostring(value) end
UI:RegisterPage('timeline', {title = 'Aura timeline', order = 12.5, cards = {
	{title = 'Timeline', rows = {
		{'switch', 'Aura timeline', 'timeline.enable', 'The abilities you use and your cooldowns ride a line toward zero, each on a key with its time under it.', since = '0.5.0'},
		{'dropdown', 'Buffs', 'timeline.buffs', items = {{'mine', 'Yours'}, {'all', 'All'}, {'off', 'None'}}, disabled = Off,
			note = 'Yours: auras you cast. All: every timed buff on you.'},
		{'slider', 'Longest buff', 'timeline.longBuffs', 0, 3600, 30, 'Optional: buffs that last longer than this are never tracked. At All, every timed buff is tracked and shows once its time left drops onto the line.',
			format = function(value) if value == 0 then return 'All' end return value >= 60 and format('%dm', floor(value / 60)) or format('%ds', value) end,
			disabled = Off, since = '0.5.1'},
		{'switch', 'Debuffs on you', 'timeline.debuffs', 'Harmful auras on charcoal keys with a red edge.', disabled = Off},
		{'switch', 'Cooldowns', 'timeline.cooldowns', 'Spells on your action bars while they cool down, on LCD keys.', disabled = Off},
		{'slider', 'Shortest cooldown', 'timeline.minCooldown', 0, 30, 1, 'Shorter ones are left out when the game tells their length.',
			format = Seconds, hidden = function() return not DB().cooldowns end},
		{'input', 'Hidden spells', 'timeline.blacklist', 'Spell IDs to leave off, separated by commas.'},
		{'note', 'The line is linear: a key\'s distance from zero is its time left. Only what is on the line shows: a longer timer slides on once its time left drops below the line\'s length, and auras that last until cancelled (a seal, an aura) never show. Keys that would overlap stack into lanes. The game moves the keys itself, so this keeps working when it hides exact times in combat.'},
	}},
	{title = 'Keys', rows = {
		{'slider', 'Key size', 'timeline.iconSize', 16, 40, 1, nil, format = Whole},
		{'slider', 'Lanes', 'timeline.lanes', 1, 6, 1, 'How many keys may stack at one spot.', format = Whole, since = '0.5.1'},
		{'segmented', 'Stack', 'timeline.stack', items = {{'up', 'Up'}, {'down', 'Down'}, {'both', 'Both'}},
			note = 'Which side of the line the keys stack on.', since = '0.5.1'},
		{'switch', 'Time under keys', 'timeline.timeText'},
		{'segmented', 'Time style', 'timeline.chip', items = {{'lcd', 'LCD chip'}, {'plain', 'Plain'}}, since = '0.5.1',
			hidden = function() return not DB().timeText end},
		{'switch', 'Stems', 'timeline.stems', 'A hairline from each key down to its point on the line.', since = '0.5.1'},
		{'switch', 'Stack counts', 'timeline.counts', 'How many stacks an aura has, on its key.', since = '0.5.1'},
		{'slider', 'Most keys', 'timeline.maxEntries', 4, 20, 1, nil, format = Whole},
	}},
	{title = 'Line', rows = {
		{'slider', 'Length', 'timeline.maxTime', 10, 600, 5, 'How many seconds the whole line stands for.', format = Seconds},
		{'slider', 'Size', 'timeline.width', 120, 600, 2, nil, format = Whole},
		{'segmented', 'Direction', 'timeline.orientation', items = {{'horizontal', 'Across'}, {'vertical', 'Up'}}},
		{'switch', 'Zero at the far end', 'timeline.reverse', 'Keys run toward the right (or the top).'},
		{'switch', 'Scale labels', 'timeline.labels', '0, 5S, 30S, 1M and so on beside the ticks.'},
		{'button', 'Placement', 'Move frames', function() UI:ToggleHub(nil, false); UI:ToggleMovers() end, 'Drag the timeline anywhere.'},
	}},
}})
