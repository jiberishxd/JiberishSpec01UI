-- The nameplate nav tape: a row of hairline ticks laid on top of a plate, with
-- the distance printed above it. A marker rides the tape to where the unit is
-- on your screen, the ticks near it lift and light like the ticks under
-- SPEC-01's slider, and the tape scrolls as the unit or your view moves, so
-- every step either of you takes shows as motion.
--
-- What the game lets an addon know, and so what this shows:
--   * Distance comes in brackets, from whether your own spells (and, out of
--     combat, the interact distances) reach the unit: "< 20 YD", "20-25 YD".
--     When those answers are secret, every bracket label is stacked in one
--     place and each is shown or hidden straight from the answers
--     (SetAlphaFromBoolean, through a parent frame for the lower edge), so the
--     right one still reads without the addon ever seeing it.
--   * Facing: an enemy's facing and position are not readable at all. The
--     marker shows where the plate is across your screen, and turns red while
--     the unit is targeting you.
--   * Motion is read from where the plate moves on screen (the unit walking,
--     you strafing or turning the camera), plus your own heading where the game
--     shares it. The unit's speed, when plain, makes the ticks near it ripple.
-- Ticks are placed on whole physical pixels, so they stay sharp while they move.
-- Nothing runs while no tape is shown.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, GetTime, InCombatLockdown = CreateFrame, GetTime, InCombatLockdown
local floor, max, min, abs, sin, pi = math.floor, math.max, math.min, math.abs, math.sin, math.pi

local module = UI:RegisterModule('navbar', {})
module.always = true

-- defaults:begin
UI:RegisterDefaults('navbar', {enable = true, show = 'target', yards = true, bearing = true, facing = true, tape = true,
	lens = true, position = 'above', ticks = 24})
-- defaults:end

local function DB() return UI.db.navbar end
local function IsSecret(value) return issecretvalue and issecretvalue(value) end
local function Plain(func, ...)
	if type(func) ~= 'function' then return nil end
	local ok, value = pcall(func, ...)
	if not ok or IsSecret(value) then return nil end
	return value
end
local function Plates() return UI.modules.nameplates end
local function Reduced() return UI.db.reduceMotion end

-- Range checkers ---------------------------------------------------------------------
-- Spells that reach an enemy, per class. Their ranges are read from the game,
-- so talents that extend them are counted; spells with a minimum range are left
-- out (being out of range of those says nothing about distance).
local CLASS_SPELLS = {
	DEATHKNIGHT = {49576, 47541}, DEMONHUNTER = {185123, 183752, 204021}, EVOKER = {362969},
	DRUID = {5176, 339, 6795, 33786, 22568, 8921}, HUNTER = {466930, 75}, MAGE = {44614, 11366, 118, 116, 133, 44425},
	MONK = {115546, 115078, 100780, 117952}, PALADIN = {853, 35395, 62124, 183218, 20271, 20473},
	PRIEST = {589, 8092, 585}, ROGUE = {185565, 36554, 185763, 2094, 921}, SHAMAN = {370, 8042, 117014, 188196, 73899},
	WARRIOR = {355, 5246}, WARLOCK = {686, 5782, 232670, 234153},
}
-- Out of combat only: the game's interact distances (duel, follow).
local INTERACT = {{index = 3, range = 10}, {index = 4, range = 28}}

local checkers = {}
local IsSpellInRange = (C_Spell and C_Spell.IsSpellInRange) or _G.IsSpellInRange

local function Known(spell)
	if IsPlayerSpell and Plain(IsPlayerSpell, spell) then return true end
	local book = C_SpellBook and C_SpellBook.IsSpellKnown
	return book and Plain(book, spell) and true or false
end

local function SpellRange(spell)
	local info = C_Spell and C_Spell.GetSpellInfo and Plain(C_Spell.GetSpellInfo, spell)
	if type(info) ~= 'table' then return nil end
	local low, high = info.minRange, info.maxRange
	if IsSecret(low) or IsSecret(high) or type(high) ~= 'number' then return nil end
	if type(low) == 'number' and low > 0 then return nil end
	return high > 0 and high or 5 -- melee
end

-- Auto Attack reaches exactly melee distance for every class, and is asked
-- like any other spell, in combat too.
local AUTO_ATTACK = 6603
local MELEE = 5

-- Every non-passive spell in the player's own spellbook that can reach a unit,
-- one per distinct range: harmful ones measure enemies, helpful ones friends.
-- Read from the spellbook, so it works on every client and rank.
local function SpellbookSpells(visit)
	local book = C_SpellBook
	if book and book.GetNumSpellBookSkillLines and book.GetSpellBookSkillLineInfo and book.GetSpellBookItemInfo then
		local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
		local spellType = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell
		for line = 1, Plain(book.GetNumSpellBookSkillLines) or 0 do
			local info = Plain(book.GetSpellBookSkillLineInfo, line)
			if type(info) == 'table' and not IsSecret(info.itemIndexOffset) and not IsSecret(info.numSpellBookItems) then
				local first = (info.itemIndexOffset or 0) + 1
				for slot = first, first + (info.numSpellBookItems or 0) - 1 do
					local item = Plain(book.GetSpellBookItemInfo, slot, bank)
					if type(item) == 'table' and not IsSecret(item.spellID) and not IsSecret(item.isPassive)
						and (not spellType or item.itemType == spellType) and item.spellID and not item.isPassive then
						visit(item.spellID)
					end
				end
			end
		end
		return
	end
	-- Older clients.
	if GetNumSpellTabs and GetSpellTabInfo and GetSpellBookItemInfo then
		for tab = 1, Plain(GetNumSpellTabs) or 0 do
			local ok, _, _, offset, count = pcall(GetSpellTabInfo, tab)
			if ok and type(offset) == 'number' and type(count) == 'number' then
				for slot = offset + 1, offset + count do
					local okItem, kind, id = pcall(GetSpellBookItemInfo, slot, 'spell')
					if okItem and kind == 'SPELL' and type(id) == 'number' then visit(id) end
				end
			end
		end
	end
end

local harmChecks, helpChecks = {}, {}

local function Add(list, byRange, entry)
	if byRange[entry.range] then return end
	byRange[entry.range] = true
	list[#list + 1] = entry
end

local function BuildCheckers()
	wipe(harmChecks)
	wipe(helpChecks)
	local harmRange, helpRange = {}, {}
	if Known(AUTO_ATTACK) or IsSpellInRange then Add(harmChecks, harmRange, {spell = AUTO_ATTACK, range = MELEE}) end
	local isHarmful = C_Spell and C_Spell.IsSpellHarmful
	local isHelpful = C_Spell and C_Spell.IsSpellHelpful
	SpellbookSpells(function(spell)
		local range = SpellRange(spell)
		if not range or range > 100 then return end
		if isHarmful and Plain(isHarmful, spell) then Add(harmChecks, harmRange, {spell = spell, range = range}) end
		if isHelpful and Plain(isHelpful, spell) then Add(helpChecks, helpRange, {spell = spell, range = range}) end
	end)
	-- The class list, for anything the spellbook didn't answer.
	local _, class = UnitClass('player')
	for _, spell in ipairs(not IsSecret(class) and CLASS_SPELLS[class] or {}) do
		local range = Known(spell) and SpellRange(spell)
		if range then Add(harmChecks, harmRange, {spell = spell, range = range}) end
	end
	for _, interact in ipairs(INTERACT) do
		Add(harmChecks, harmRange, {index = interact.index, range = interact.range})
		Add(helpChecks, helpRange, {index = interact.index, range = interact.range})
	end
	local function Nearest(a, b) return a.range < b.range end
	table.sort(harmChecks, Nearest)
	table.sort(helpChecks, Nearest)
	checkers = harmChecks
end

-- The checks that fit a unit: harmful spells for enemies, helpful for the rest.
local function ChecksFor(unit)
	local hostile = Plain(UnitCanAttack, 'player', unit)
	checkers = (hostile == false and #helpChecks > 0) and helpChecks or harmChecks
end

-- Fills `answers` with each checker's answer; returns true when any is secret.
-- Checks that can't be asked right now (interact distances in combat) are nil.
local function Ask(unit, answers)
	local secret, fighting = false, InCombatLockdown()
	for index, checker in ipairs(checkers) do
		local ok, answer
		if checker.spell then
			if IsSpellInRange then ok, answer = pcall(IsSpellInRange, checker.spell, unit) end
		elseif not fighting and CheckInteractDistance then
			ok, answer = pcall(CheckInteractDistance, unit, checker.index)
		end
		if not ok then answer = nil end
		answers[index] = answer
		if IsSecret(answer) then secret = true end
	end
	for index = #checkers + 1, #answers do answers[index] = nil end
	return secret
end

-- Only with plain answers: the farthest range the unit is beyond, and the
-- nearest range it is within.
local function Bracket(answers)
	local low, high
	for index, checker in ipairs(checkers) do
		local answer = answers[index]
		if answer == true then
			if not high or checker.range < high then high = checker.range end
		elseif answer == false then
			if not low or checker.range > low then low = checker.range end
		end
	end
	if low and high and low >= high then low = nil end
	return low, high
end

-- The nearest range the unit is within reads as that range ("20 YD"); in melee
-- reach it reads MELEE; beyond every check, "40+ YD".
local function RangeText(range) return range <= MELEE and 'MELEE' or format('%d YD', range) end

local function BracketText(low, high)
	if high then return RangeText(high), high <= MELEE end
	if low then return format('%d+ YD', low), false end
	return '-- YD', false
end

-- The tape ---------------------------------------------------------------------------
local bars = setmetatable({}, {__mode = 'k'}) -- our plate -> its tape
local active = {} -- tapes being shown, in no order
local preview

local function Px(frame, n) return UI.Pixel and UI.Pixel.Px(frame, n) or n end
local function Snap(value, px) return floor(value / px + 0.5) * px end

-- Physical-pixel sizes of the parts.
local TICK_MINOR, TICK_MAJOR, LENS_LIFT, RIPPLE = 3, 5, 4, 2
local CARET_ROWS = 3
local EDGE_FADE = 0.2 -- of the width, where ticks fade out at each end
local LENS_SPAN = 4.5 -- in tick spacings, how far the lift reaches either side of the marker
local PARALLAX = 1.6 -- how much faster than the plate the ticks run past

-- A caret pointing down, drawn as rows of solid pixels so it stays crisp.
local function Caret(parent, token)
	local caret = CreateFrame('Frame', nil, parent)
	caret.rows = {}
	for row = 1, CARET_ROWS do caret.rows[row] = Kit:Solid(caret, token, 'OVERLAY', 3) end
	caret.line = Kit:Solid(caret, token, 'OVERLAY', 2)
	return caret
end

local function LayoutCaret(caret, px, tapeHeight)
	for row = 1, CARET_ROWS do
		local piece = caret.rows[row]
		local width = (2 * (CARET_ROWS - row) + 1) * px
		piece:ClearAllPoints()
		piece:SetSize(width, px)
		piece:SetPoint('TOP', caret, 'TOP', 0, -(row - 1) * px)
	end
	caret.line:ClearAllPoints()
	caret.line:SetSize(px, tapeHeight)
	caret.line:SetPoint('TOP', caret, 'TOP', 0, -CARET_ROWS * px)
	caret:SetSize((2 * CARET_ROWS - 1) * px, CARET_ROWS * px + tapeHeight)
end

local function Build()
	local bar = CreateFrame('Frame', nil, UIParent)
	bar:EnableMouse(false)
	bar:Hide()
	-- The distance, centred over the tape. Plain answers write one string; secret
	-- answers light one of a stack of bracket labels (see SetLayers).
	bar.yards = Kit:Text(bar, '', 8, 'darkInk', true, true)
	-- In melee reach: a red lamp beside MELEE.
	bar.meleeHolder = CreateFrame('Frame', nil, bar)
	bar.meleeHolder:SetSize(9, 9)
	bar.meleeHolder:SetPoint('RIGHT', bar.yards, 'LEFT', -2, 0)
	bar.melee = Kit:Led(bar.meleeHolder, 5, true)
	Kit:SetLed(bar.melee, true, 'red')
	bar.melee:SetPoint('CENTER')
	Kit:ShowLed(bar.melee, false)
	bar.yards:SetJustifyH('CENTER')
	bar.layerHolder = CreateFrame('Frame', nil, bar)
	bar.layers = {}
	-- The tape: clipped, so ticks scroll in and out under the fade.
	bar.tape = CreateFrame('Frame', nil, bar)
	bar.tape:SetClipsChildren(true)
	bar.strip = CreateFrame('Frame', nil, bar.tape)
	bar.strip:SetSize(1, 1)
	bar.ticks = {}
	-- The marker: a key-colored caret and hairline, and a red one shown instead
	-- while the unit is targeting you. Each sits on its own frame so the
	-- targeting answer can switch them without being read.
	bar.marker = CreateFrame('Frame', nil, bar)
	bar.marker:SetFrameLevel(bar.tape:GetFrameLevel() + 3)
	bar.calm = Caret(bar.marker, 'lamp')
	bar.alert = Caret(bar.marker, 'red')
	bar.alert:SetAlpha(0)
	-- Animated state.
	bar.at, bar.goal = 0, 0 -- marker position, -1..1 of the half width
	bar.speed, bar.wave = 0, 0
	bar.answers = {}
	return bar
end

-- Colors used every frame, read once per layout (and again on a theme change).
local inkR, inkG, inkB, dimR, dimG, dimB, keyR, keyG, keyB = 1, 1, 1, 0.6, 0.6, 0.6, 1, 1, 1
local function ReadColors()
	inkR, inkG, inkB = Kit:RGB('darkInk')
	dimR, dimG, dimB = Kit:RGB('darkDim')
	keyR, keyG, keyB = Kit:RGB('lamp')
end

local function LayoutTicks(bar)
	local px = bar.px
	local width = bar.width
	local wanted = max(8, floor(DB().ticks or 24))
	-- Whole physical pixels between ticks, so every tick lands on the grid.
	local spacing = max(3 * px, Snap(width / wanted, px))
	local total = floor(width / spacing) + 3
	bar.spacing, bar.tickCount = spacing, total
	for index = 1, total do
		local tick = bar.ticks[index]
		if not tick then
			tick = bar.strip:CreateTexture(nil, 'ARTWORK')
			tick:SetColorTexture(1, 1, 1, 1)
			bar.ticks[index] = tick
		end
		tick:ClearAllPoints()
		tick:SetPoint('BOTTOMLEFT', bar.strip, 'BOTTOMLEFT', (index - 1) * spacing, 0)
		tick:SetSize(px, TICK_MINOR * px)
		tick.height = nil
		tick:Show()
	end
	for index = total + 1, #bar.ticks do bar.ticks[index]:Hide() end
end

local function Layout(bar)
	local db = DB()
	ReadColors()
	local scale, rawWidth = Plain(bar.GetEffectiveScale, bar), Plain(bar.GetWidth, bar)
	if not scale then return end
	local px = Px(bar, 1)
	bar.px, bar.scale = px, scale
	local width = Snap(max(type(rawWidth) == 'number' and rawWidth or 0, 40), px)
	bar.width = width
	local tapeHeight = (TICK_MAJOR + LENS_LIFT + RIPPLE) * px
	local caretHeight = CARET_ROWS * px
	local textHeight = db.yards and 10 or 0
	bar:SetHeight(textHeight + caretHeight + tapeHeight + 2 * px)
	bar.tape:ClearAllPoints()
	bar.tape:SetPoint('BOTTOMLEFT', bar, 'BOTTOMLEFT', 0, 0)
	bar.tape:SetSize(width, tapeHeight)
	bar.yards:ClearAllPoints()
	bar.yards:SetPoint('BOTTOM', bar.tape, 'TOP', 0, caretHeight + 2 * px)
	bar.yards:SetShown(db.yards and not bar.secret and true or false)
	bar.layerHolder:ClearAllPoints()
	bar.layerHolder:SetAllPoints(bar.yards)
	bar.layerHolder:SetShown(db.yards and true or false)
	bar.marker:SetSize(1, 1)
	LayoutCaret(bar.calm, px, tapeHeight)
	LayoutCaret(bar.alert, px, tapeHeight)
	for _, caret in ipairs({bar.calm, bar.alert}) do
		caret:ClearAllPoints()
		caret:SetPoint('BOTTOM', bar.marker, 'CENTER', 0, 0)
	end
	bar.marker:SetShown(db.bearing and true or false)
	LayoutTicks(bar)
	bar.stripX, bar.markerX, bar.dirty = nil, nil, true
end

-- Where a tape goes on its plate: right on top of it (over its auras and name)
-- or under it.
local function Place(bar, plate)
	local plates, db = UI.db.nameplates, DB()
	bar:SetParent(plate)
	bar:SetFrameLevel(plate:GetFrameLevel() + 8)
	bar:ClearAllPoints()
	local inset = 6
	if db.position == 'below' then
		local drop = 2
		if plates.castbar then drop = drop + (plates.castHeight or 18) + 3 end
		if plates.debuffs and plates.auraPosition == 'below' then drop = drop + (plates.auraSize or 18) + 3 end
		bar:SetPoint('TOPLEFT', plate, 'BOTTOMLEFT', inset, -drop)
		bar:SetPoint('TOPRIGHT', plate, 'BOTTOMRIGHT', -inset, -drop)
	else
		-- Right on the plate's top edge; the plate's debuffs move up over it.
		local lift = 0
		if plates.namePosition == 'above' and not plate.nameOnly then lift = lift + (plates.nameSize or 8) + 6 end
		bar:SetPoint('BOTTOMLEFT', plate, 'TOPLEFT', inset, lift)
		bar:SetPoint('BOTTOMRIGHT', plate, 'TOPRIGHT', -inset, lift)
	end
	Layout(bar)
end

-- Tell the plate to lift (or drop back) its debuffs around the tape.
local function Relift(plate)
	local plates = Plates()
	if plates and plates.LayoutAuras and plate and plate.auras then UI:Safe(plates.LayoutAuras, plate) end
end

-- Drawing ------------------------------------------------------------------------------
-- The scroll position, in the tape's own units: the plate's place on screen
-- (so the ticks run past as it moves) plus your heading where it is shared.
local function ScrollOf(bar)
	if not DB().tape or Reduced() then return 0 end
	local scroll = bar.screenX and bar.screenX * PARALLAX or 0
	if bar.heading then scroll = scroll + bar.heading * bar.width / (pi / 2) end
	return scroll
end

-- Ticks: placed by the strip (one anchor per frame), then each one's height,
-- alpha and color from its distance to the marker and to the ends.
local function Draw(bar)
	local px, width, spacing = bar.px, bar.width, bar.spacing
	if not (px and spacing) then return end
	local stripX = Snap(-(ScrollOf(bar) % spacing), px)
	if stripX ~= bar.stripX then
		bar.stripX = stripX
		bar.strip:ClearAllPoints()
		bar.strip:SetPoint('BOTTOMLEFT', bar.tape, 'BOTTOMLEFT', stripX, 0)
		bar.dirty = true
	end
	local db = DB()
	local markerX = Snap(width / 2 + bar.at * (width / 2 - 4 * px), px)
	if markerX ~= bar.markerX then
		bar.markerX = markerX
		bar.marker:ClearAllPoints()
		-- Half a pixel right, so the odd-width caret and its hairline fill whole pixels.
		bar.marker:SetPoint('CENTER', bar.tape, 'BOTTOMLEFT', markerX + px / 2, 0)
		bar.dirty = true
	end
	local moving = bar.speed > 0 and not Reduced()
	if not (bar.dirty or moving or bar.rippling) then return end
	bar.dirty, bar.rippling = nil, moving or nil
	-- Which tick is "major" follows the scroll, so the long ticks run past too.
	local first = floor(ScrollOf(bar) / spacing)
	local lens, fade = db.lens and db.bearing, EDGE_FADE * width
	local reach = LENS_SPAN * spacing
	for index = 1, bar.tickCount do
		local tick = bar.ticks[index]
		local x = stripX + (index - 1) * spacing
		local major = (first + index - 1) % 5 == 0
		local edge = min(1, max(0, x / fade), max(0, (width - x) / fade))
		local near = 0
		if lens then
			local distance = abs(x - markerX)
			if distance < reach then
				near = 1 - distance / reach
				near = near * near * (3 - 2 * near) -- smoothstep
			end
		end
		local lift = near * LENS_LIFT
		if moving then lift = lift + near * RIPPLE * (0.5 + 0.5 * sin(bar.wave - (index + first) * 0.9)) end
		local height = floor((major and TICK_MAJOR or TICK_MINOR) + lift + 0.5) * px
		if tick.height ~= height then tick.height = height; tick:SetHeight(height) end
		local base = major and 0.85 or 0.45
		tick:SetAlpha(edge * (base + (1 - base) * near))
		local r, g, b = major and inkR or dimR, major and inkG or dimG, major and inkB or dimB
		tick:SetVertexColor(r + (keyR - r) * near, g + (keyG - g) * near, b + (keyB - b) * near)
	end
end

-- Distance labels ----------------------------------------------------------------------
local function ShowPlain(bar, low, high)
	if bar.secret then
		bar.secret = nil
		for _, layer in ipairs(bar.layers) do layer.gate:Hide() end
		bar.yards:Show()
	end
	local text, melee = BracketText(low, high)
	if text ~= bar.text then
		bar.text = text
		bar.yards:SetText(text)
		Kit:Tint(bar.yards, melee and 'red' or 'darkInk')
		Kit:ShowLed(bar.melee, melee and true or false)
		if melee and not Reduced() then Kit:Flash(bar.meleeHolder, {token = 'red', alpha = 0.6, duration = 0.3}) end
	end
end

-- One label per bracket the answers can tell apart, all in one place. Label k
-- reads "within checker k": its own alpha comes from that answer, and its gate
-- (the frame it sits on) hides it when the unit is also within checker k-1.
-- The last label, beyond every checker, is gated by the farthest one.
local function Layer(bar, index)
	local layer = bar.layers[index]
	if layer then return layer end
	local gate = CreateFrame('Frame', nil, bar.layerHolder)
	gate:SetAllPoints()
	local label = Kit:Text(gate, '', 8, 'darkInk', true, true)
	label:SetPoint('CENTER')
	local led = Kit:Led(gate, 5, true)
	Kit:SetLed(led, true, 'red')
	led:SetPoint('RIGHT', label, 'LEFT', -3, 0)
	Kit:ShowLed(led, false)
	layer = {gate = gate, label = label, led = led}
	bar.layers[index] = layer
	return layer
end

local function ShowSecret(bar, answers)
	local holder = bar.layerHolder
	if not (holder.SetAlphaFromBoolean and bar.yards.SetAlphaFromBoolean) then
		-- No way to show a secret bracket on this client: leave the yards blank.
		bar.yards:SetText('')
		bar.text = nil
		return
	end
	if not bar.secret then
		bar.secret = true
		bar.yards:Hide()
		bar.text = nil
	end
	-- The checkers that answered, nearest first.
	local usable, signature = bar.usable or {}, ''
	wipe(usable)
	for index, checker in ipairs(checkers) do
		local answer = answers[index]
		if IsSecret(answer) or answer ~= nil then
			usable[#usable + 1] = index
			signature = signature..checker.range..','
		end
	end
	bar.usable = usable
	local count = #usable
	if signature ~= bar.signature then
		bar.signature = signature
		for k = 1, count + 1 do
			local layer = Layer(bar, k)
			local range = checkers[usable[k]] and checkers[usable[k]].range
			local below = checkers[usable[k - 1]] and checkers[usable[k - 1]].range
			local melee = k <= count and range and range <= MELEE
			if k > count then layer.label:SetText(format('%d+ YD', below or 0))
			else layer.label:SetText(RangeText(range)) end
			Kit:Tint(layer.label, melee and 'red' or 'darkInk')
			Kit:ShowLed(layer.led, melee and true or false)
		end
	end
	for k = 1, #bar.layers do
		local layer = bar.layers[k]
		if k > count + 1 then
			layer.gate:Hide()
		else
			layer.gate:Show()
			local own, lower = answers[usable[k]], answers[usable[k - 1]]
			if k > count then layer.label:SetAlpha(1)
			else layer.label:SetAlphaFromBoolean(own, 1, 0) end
			if not IsSecret(lower) and lower == nil then layer.gate:SetAlpha(1)
			else layer.gate:SetAlphaFromBoolean(lower, 0, 1) end
		end
	end
end

local function SetFacing(bar, value)
	if not DB().facing then
		bar.calm:SetAlpha(1)
		bar.alert:SetAlpha(0)
		return
	end
	if IsSecret(value) and bar.alert.SetAlphaFromBoolean then
		bar.alert:SetAlphaFromBoolean(value, 1, 0)
		bar.calm:SetAlphaFromBoolean(value, 0, 1)
	else
		local on = value == true
		bar.alert:SetAlpha(on and 1 or 0)
		bar.calm:SetAlpha(on and 0 or 1)
	end
end

-- Sensing -----------------------------------------------------------------------------
-- Where the plate is across the screen: -1 (left edge) to 1 (right edge), and
-- its centre in the tape's own units.
local function Screen(bar)
	local plate = bar:GetParent()
	local x = plate and Plain(plate.GetCenter, plate)
	if type(x) ~= 'number' then return nil end
	local scale = Plain(plate.GetEffectiveScale, plate)
	local screen = UIParent:GetWidth() * UIParent:GetEffectiveScale()
	if not scale or screen <= 0 or not bar.scale then return nil end
	local physical = x * scale
	return min(max((physical - screen / 2) / (screen / 2), -1), 1), physical / bar.scale
end

local function Sense(bar)
	if bar.preview then
		-- The page's sample: a unit wandering in and out of range across your view.
		local t = GetTime()
		local distance = 21 + 19 * sin(t * 0.55)
		local low, high
		for _, range in ipairs({5, 8, 10, 15, 20, 25, 30, 35, 40}) do
			if range >= distance then high = high or range else low = range end
		end
		ShowPlain(bar, low, high)
		bar.speed = abs(sin(t * 0.55)) > 0.3 and 7 or 0
		SetFacing(bar, sin(t * 0.8) > 0.4)
		return
	end
	local unit = bar.unit
	if not unit then return end
	if DB().yards then
		ChecksFor(unit)
		if Ask(unit, bar.answers) then ShowSecret(bar, bar.answers) else ShowPlain(bar, Bracket(bar.answers)) end
	end
	-- The answer may be secret: it goes to SetFacing untested.
	local ok, targeting = pcall(UnitIsUnit, unit..'target', 'player')
	if not ok then targeting = false end
	SetFacing(bar, targeting)
	local speed = Plain(GetUnitSpeed, unit)
	bar.speed = type(speed) == 'number' and speed or 0
end

-- The driver: senses a few tapes about 15 times a second and draws every frame,
-- only while a tape is shown.
local driver = CreateFrame('Frame')
local sinceSense = 1
local lastFacing, unwrapped = nil, 0

local SENSE_PER_TICK = 3
local cursor

local function SenseSome()
	if preview and active[preview] and preview:IsVisible() then UI:Safe(Sense, preview) end
	if cursor ~= nil and not active[cursor] then cursor = nil end
	local sensed, start = 0, cursor
	repeat
		cursor = next(active, cursor)
		if cursor and cursor ~= preview and cursor:IsVisible() then
			UI:Safe(Sense, cursor)
			sensed = sensed + 1
		end
	until sensed >= SENSE_PER_TICK or cursor == start or (cursor == nil and start == nil)
end

local function Step(_, elapsed)
	-- Only when nothing is left to show does the driver stop; a tape hidden
	-- with the interface (Alt+Z, a cinematic) picks up again when it returns.
	if not next(active) then driver:SetScript('OnUpdate', nil) return end
	elapsed = min(elapsed, 0.1)
	sinceSense = sinceSense + elapsed
	if sinceSense >= 1 / 15 then
		sinceSense = 0
		SenseSome()
	end
	-- Your heading, unwrapped, so turning through north doesn't jump the tape.
	local facing = Plain(GetPlayerFacing)
	local heading
	if type(facing) == 'number' then
		if lastFacing then
			local delta = facing - lastFacing
			if delta > pi then delta = delta - 2 * pi elseif delta < -pi then delta = delta + 2 * pi end
			unwrapped = unwrapped + delta
		end
		lastFacing, heading = facing, unwrapped
	else
		lastFacing = nil
	end
	local now = GetTime()
	local ease = Reduced() and 1 or min(1, elapsed * 10)
	for bar in pairs(active) do
		if bar:IsVisible() then
			-- A plate's scale changes (targeting, distance scaling): re-measure pixels.
			local scale, width = Plain(bar.GetEffectiveScale, bar), Plain(bar.GetWidth, bar)
			if (scale and (not bar.scale or abs(scale - bar.scale) > 0.0001))
				or (width and bar.width and bar.px and abs(width - bar.width) > bar.px) then
				UI:Safe(Layout, bar)
			end
			if bar.preview then
				bar.goal = sin(now * 0.35) * 0.85
				bar.screenX = (bar.screenX or 0) + elapsed * 40 * sin(now * 0.3)
				bar.heading = nil
			else
				local bearing, screenX = Screen(bar)
				if bearing then bar.goal, bar.screenX = bearing, screenX end
				bar.heading = heading
			end
			bar.at = bar.at + (bar.goal - bar.at) * ease
			bar.wave = bar.wave + elapsed * min(bar.speed, 14) * 0.9
			Draw(bar)
		end
	end
end

local function Wake()
	if next(active) then driver:SetScript('OnUpdate', Step) end
end

-- Which plates carry a tape ---------------------------------------------------------------
local function PlateFor(unit)
	if not C_NamePlate or not C_NamePlate.GetNamePlateForUnit then return nil end
	local ok, nameplate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
	return ok and nameplate or nil
end

local function Wants(plate, unit)
	local db = DB()
	if not db.enable or not plate or plate.nameOnly then return false end
	-- Only a plate opened into its Full state carries the tape.
	if plate.state == 'compact' then return false end
	local nameplate = plate.nameplate
	if not nameplate then return false end
	if nameplate == PlateFor('target') then return true end
	if db.show == 'focus' and nameplate == PlateFor('focus') then return true end
	if db.show == 'enemies' then return Plain(UnitCanAttack, 'player', unit) == true end
	return false
end

local function Detach(plate)
	local bar = bars[plate]
	if not bar then return end
	active[bar] = nil
	bar.unit = nil
	bar:Hide()
	Relift(plate)
end

local function Attach(plate, unit)
	if not Wants(plate, unit) then return Detach(plate) end
	local bar = bars[plate]
	if not bar then bar = Build(); bars[plate] = bar end
	local fresh = bar.unit ~= unit
	bar.unit = unit
	Place(bar, plate)
	if fresh then
		bar.speed, bar.text = 0, nil
		local bearing, screenX = Screen(bar)
		bar.goal, bar.screenX = bearing or 0, screenX
		bar.at = bar.goal
		Sense(bar)
		bar:SetAlpha(0)
		Kit:FadeTo(bar, 1, 'FAST')
	end
	bar:Show()
	active[bar] = true
	Relift(plate)
	Wake()
end

local function Rescan()
	local plates = Plates()
	if not (plates and plates.byUnit) then return end
	for unit, plate in pairs(plates.byUnit) do UI:Safe(Attach, plate, unit) end
end

local function OnPlate(what, plate, unit)
	if what == 'remove' then Detach(plate) else Attach(plate, unit) end
end

function module:Enable()
	local plates = Plates()
	if not (plates and plates.enabled and plates.listeners) then return end
	BuildCheckers()
	table.insert(plates.listeners, OnPlate)
	-- Debuffs above the plate sit over the tape while it is there.
	plates.TopLift = function(plate)
		local bar = bars[plate]
		if not (bar and active[bar]) or DB().position == 'below' then return 0 end
		return bar:GetHeight() + 2
	end
	local events = CreateFrame('Frame')
	for _, event in ipairs({'PLAYER_TARGET_CHANGED', 'PLAYER_FOCUS_CHANGED', 'SPELLS_CHANGED', 'PLAYER_ENTERING_WORLD',
		'PLAYER_SPECIALIZATION_CHANGED', 'TRAIT_CONFIG_UPDATED'}) do
		pcall(events.RegisterEvent, events, event)
	end
	events:SetScript('OnEvent', function(_, event)
		if event == 'PLAYER_TARGET_CHANGED' or event == 'PLAYER_FOCUS_CHANGED' then
			UI:Safe(Rescan)
		else
			UI:Safe(BuildCheckers)
			for _, bar in pairs(bars) do bar.signature = nil end
			if event == 'PLAYER_ENTERING_WORLD' then UI:Safe(Rescan) end
		end
	end)
	Rescan()
	self.ready = true
end

function module:Refresh()
	if not self.ready then return end
	for plate, bar in pairs(bars) do
		if bar.unit and plate.nameplate then UI:Safe(Attach, plate, bar.unit) else Detach(plate) end
	end
	Rescan()
	if preview and preview:IsShown() then UI:Safe(Layout, preview) end
end

Kit:OnRefresh(function()
	for _, bar in pairs(bars) do if bar:IsShown() then UI:Safe(Layout, bar) end end
	if preview and preview:IsShown() then UI:Safe(Layout, preview) end
end)

-- Hub page -------------------------------------------------------------------------------
local function ShowPreview(area)
	local card
	for _, child in ipairs({area.content:GetChildren()}) do
		local title = child.title and child.title.GetText and child.title:GetText()
		if type(title) == 'string' and strupper(title) == 'PREVIEW' then card = child break end
	end
	if not card then return end
	if not preview then
		preview = Build()
		preview.preview = true
		-- A plate-sized strip of dark glass to sit on, as in the world.
		preview.stand = CreateFrame('Frame', nil, preview)
		preview.stand.shell = Kit:Shell(preview.stand, {surface = 'glass', radius = 4, shadow = false, alpha = 0.85})
	end
	preview:SetParent(card.body)
	preview:SetFrameLevel(card.body:GetFrameLevel() + 5)
	preview:ClearAllPoints()
	preview:SetPoint('CENTER', card.body, 'CENTER', 0, 2)
	preview:SetWidth(min(200, card.body:GetWidth() - 40))
	Layout(preview)
	preview.stand:ClearAllPoints()
	preview.stand:SetPoint('TOPLEFT', preview, 'BOTTOMLEFT', -6, -2)
	preview.stand:SetPoint('TOPRIGHT', preview, 'BOTTOMRIGHT', 6, -2)
	preview.stand:SetHeight(14)
	preview.speed, preview.at, preview.goal = 0, 0, 0
	preview:Show()
	active[preview] = true
	Wake()
end

local function HidePreview()
	if not preview then return end
	active[preview] = nil
	preview:Hide()
end

local function Int(value) return format('%d', value + 0.5) end

UI:RegisterPage('navbar', {title = 'Nameplate nav', order = 15.5,
	onShow = function(area) ShowPreview(area) end,
	onHide = HidePreview,
	cards = {
	{title = 'Preview', rows = {
		{'note', 'A sample tape with a unit wandering across your view and in and out of range.\n \n \n '},
	}},
	{title = 'Nav tape', rows = {
		{'switch', 'Nav tape', 'navbar.enable', 'A row of ticks on top of the plate: where the unit is across your view, how far away it is, and whether it is targeting you.'},
		{'dropdown', 'Show on', 'navbar.show', items = {{'target', 'Target'}, {'focus', 'Target and focus'},
			{'enemies', 'Every enemy'}}},
		{'segmented', 'Position', 'navbar.position', items = {{'above', 'On top'}, {'below', 'Below'}}},
		{'slider', 'Ticks', 'navbar.ticks', 12, 40, 1, 'How many ticks across the plate.', format = Int},
	}},
	{title = 'Readouts', rows = {
		{'switch', 'Yards', 'navbar.yards', 'The nearest range the unit is within, centred above the ticks (e.g. 20 YD), or MELEE in melee reach.'},
		{'switch', 'Marker', 'navbar.bearing', 'A caret on the tape at where the unit is across your view.', since = '0.5.1'},
		{'switch', 'Lens', 'navbar.lens', 'Ticks near the marker lift and light, like the ticks under SPEC-01\'s slider.', since = '0.5.1'},
		{'switch', 'Targeting you', 'navbar.facing', 'The marker turns red while the unit is targeting you.'},
		{'switch', 'Tape motion', 'navbar.tape', 'The ticks run past as the unit or your view moves, and ripple with the unit\'s speed.'},
	}},
	{title = 'What the game allows', rows = {
		{'note', 'Distance comes in steps, from whether your own spells reach the unit (and, out of combat, the duel and follow distances), so the tape shows a bracket such as 20-25 YD, not exact yards. When the game keeps those answers secret, the right bracket is still shown, straight from the answers.\n\nAn enemy\'s facing and position can\'t be read by any addon. The marker shows where the plate is across your screen, and the ticks move with it.'},
	}},
}})
