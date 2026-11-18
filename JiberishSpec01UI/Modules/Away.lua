-- The away screen: a SPEC-01 standby console that powers on while you are
-- away (or on demand: /spec afk, or Preview on its hub page).
--
--   * Your character stands on an open stage over the dimmed world: nothing
--     behind it, only corner marks, a lit floor ring and a scan line. It turns
--     slowly; drag across it to turn it yourself, scroll to step the camera.
--   * AW-1, the main housing: status lamp, name, guild, level, class (in its
--     colour) and zone; the time away on an LCD whose unlit segments are cut to
--     the same digits, one cell per character; clock and date, time played,
--     gold, item level and durability; experience (rested in blue) as a dot
--     meter; and the function keys: Back, Screenshot, Music, Spin and Dance,
--     and four that put the screen away and open bags, map, calendar or friends.
--   * CN-1, the console: an LCD log of what happened while you were away
--     (whispers, guild and group chat, mail, levels and experience, loot,
--     money, ready checks and queues), newest at the bottom and printed in,
--     over a strip with frame rate, latency and memory.
--   * VL-1, the mixer: master volume on a large knob, music, effects, ambience
--     and dialog on small ones and a mute key, on the same CVars as the VL-1
--     gadget. CVars change only when you turn something.
-- It powers on the hardware way (housings slide in, lamps blink on, LCDs print
-- in) and off with a short fade; lamps breathe and a scan line runs while it
-- waits. Reduce motion turns all of that off.
--
-- Back, Esc, a step or anything that clears the away flag puts it away; a
-- fight, a cinematic or a loading screen always does. The interface is hidden
-- under it only out of combat, and comes back after combat if a fight starts
-- first. Nothing here hooks a Blizzard method: UIParent and the game menu get
-- HookScript handlers, and the chat frames are taken off the answer to our own
-- /played request for a moment, as the action bar console does. Chat text and
-- senders may be secret: they only ever go to SetFormattedText.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, WorldFrame, GetTime, InCombatLockdown = CreateFrame, UIParent, WorldFrame, GetTime, InCombatLockdown
local floor, max, min, abs, pi = math.floor, math.max, math.min, math.abs, math.pi
local format, ipairs, pairs, pcall, tostring, type = string.format, ipairs, pairs, pcall, tostring, type

-- defaults:begin
UI:RegisterDefaults('qol', {afk = true, afkSpin = false, afkHideUI = true,
	afkTurn = true, afkLog = true, afkChat = true, afkBlips = true, afkPlayed = true})
-- defaults:end

local module = UI:RegisterModule('away', {always = true})
local function DB() return UI.db.qol end
local function IsSecret(value) return issecretvalue and issecretvalue(value) end
-- A call's first result, or nil when it fails or the answer is secret.
local function Plain(func, ...)
	if type(func) ~= 'function' then return nil end
	local ok, value = pcall(func, ...)
	if not ok or IsSecret(value) then return nil end
	return value
end
-- A call's first four results, each nil when secret.
local function Call(func, ...)
	if type(func) ~= 'function' then return nil end
	local ok, a, b, c, d = pcall(func, ...)
	if not ok then return nil end
	if IsSecret(a) then a = nil end
	if IsSecret(b) then b = nil end
	if IsSecret(c) then c = nil end
	if IsSecret(d) then d = nil end
	return a, b, c, d
end
-- A value for SetFormattedText: secret values pass as they are, nil becomes ''.
local function Arg(value)
	if IsSecret(value) or value ~= nil then return value end
	return ''
end
local GetCVar = (C_CVar and C_CVar.GetCVar) or _G.GetCVar
local SetCVar = (C_CVar and C_CVar.SetCVar) or _G.SetCVar
local Tag = Kit.MotionTag

local A = {}  -- the screen's frames
local S = {}  -- this session: since, preview, dismissed, uiHidden, spinning
-- Design units; the whole console scales down to fit smaller screens.
local CANVAS_W, CANVAS_H = 1240, 620
local MAIN_W, MAIN_H, CONSOLE_H, MIXER_W, MIXER_H, STAGE_W = 580, 278, 300, 150, 362, 470
local KEY, KEY_GAP = 34, 14

local function Px(frame, n) return UI.Pixel.Px(frame, n) end
local function Snap(frame, value) return UI.Pixel.Snap(frame, value) end
local function Shown() return A.screen and A.screen:IsShown() and not A.closing end

-- The same voice at most once per `gap` seconds; a delay lets it clear the
-- kit's own key sounds, which play in the same frame.
local heard = {}
local function Sound(name, delay, gap)
	local function Play()
		local now = GetTime()
		if now - (heard[name] or -10) < (gap or 0.25) then return end
		heard[name] = now
		Kit:Play(name)
	end
	if delay and delay > 0 then C_Timer.After(delay, Play) else Play() end
end

-- Motion ---------------------------------------------------------------------------------
-- Every moving frame keeps its resting anchor and moves by an offset from it.
local function Place(frame, dx, dy)
	local rest = frame.rest
	if not rest then return end
	frame:ClearAllPoints()
	frame:SetPoint(rest[1], rest[2], rest[3], rest[4] + dx, rest[5] + dy)
end
local function Anchor(frame, point, relative, relativePoint, x, y)
	frame.rest = {point, relative, relativePoint, x or 0, y or 0}
	Place(frame, 0, 0)
end

-- Fade in while travelling from (dx, dy) to rest, after `delay`.
local function Slide(frame, dx, dy, delay, duration)
	local total = delay + duration
	frame:SetAlpha(0)
	Place(frame, dx, dy)
	Kit:Animate(Tag('awaySlide', frame), total, 0, 1, function(_, progress)
		local t = progress * total
		local f = t <= delay and 0 or min(1, (t - delay) / duration)
		frame:SetAlpha(Kit.ease.sine(f))
		local travel = 1 - Kit.ease.cubic(f)
		Place(frame, dx * travel, dy * travel)
	end, function()
		frame:SetAlpha(1)
		Place(frame, 0, 0)
	end, 'linear')
end

-- A lamp blinks on (on, off, on, off, on) after `delay`, then may breathe.
local function LampOn(led, token, delay, breathe)
	Kit:SetLed(led, false)
	Kit:Animate(Tag('awayLamp', led), delay + 0.3, 0, 1, function(_, progress)
		local t = progress * (delay + 0.3)
		if t < delay then return end
		local on = floor((t - delay) / 0.075) % 2 == 0
		if led.on ~= on then Kit:SetLed(led, on, token) end
	end, function()
		Kit:SetLed(led, true, token)
		if breathe then Kit:Breathe(led, true, {period = 2.6, low = 0.35}) end
	end, 'linear')
end

-- Print a string in, as the kit's LCDs do (Reduce motion shows it at once).
local function PrintIn(fontString, delay)
	if fontString and fontString:IsShown() then Kit:Print(fontString, {delay = delay or 0, duration = 0.3, steps = 16, force = true}) end
end

-- Stop a print part way, so a reused line shows its new text whole.
local function StopPrint(fontString)
	Kit:Animate(Tag('print', fontString), 0, 0, 1, function() end)
	if fontString.SetAlphaGradient then fontString:SetAlphaGradient(1000, 1) end
	fontString:SetAlpha(1)
end

-- Digit LCD --------------------------------------------------------------------------------
-- One cell per character, each holding an unlit ghost and its lit digit
-- centred on the same spot, so the ghost always matches the readout (its 8s
-- are cut from the text itself) and lines up in any typeface, even a wide or
-- proportional one. Cells are as wide as the widest digit; the readout
-- shrinks to fit its glass.
local Digits = {all = {}}

function Digits.New(parent, tag, size)
	local lcd = Kit:Panel(parent, {radius = 6, fill = 'lcd', border = 'hair'})
	lcd.size, lcd.cells, lcd.pattern, lcd.text, lcd.shown, lcd.colon = size, {}, '', '', 1000, true
	lcd.tag = Kit:Label(lcd, tag, 'lcdDim', 8)
	lcd.tag:SetPoint('TOPLEFT', 10, -8)
	lcd.tag:SetPoint('TOPRIGHT', -22, -8)
	lcd.tag:SetJustifyH('LEFT')
	lcd.tag:SetWordWrap(false)
	lcd.lamp = Kit:Led(lcd, 4, false)
	lcd.lamp:SetPoint('TOPRIGHT', -10, -9)
	lcd.band = CreateFrame('Frame', nil, lcd)
	lcd.band:SetPoint('BOTTOMLEFT', 10, 8)
	lcd.band:SetPoint('BOTTOMRIGHT', -10, 8)
	lcd.band:SetHeight(size)
	lcd.measure = Kit:Text(lcd.band, '', size, 'lcdInk')
	lcd.measure:Hide()
	lcd.band:SetScript('OnSizeChanged', function() Digits.Layout(lcd) end)
	Digits.all[lcd] = true
	return lcd
end

function Digits.Cell(lcd, index)
	local cell = lcd.cells[index]
	if cell then return cell end
	cell = {}
	cell.ghost = Kit:Ghost(Kit:Text(lcd.band, '', lcd.size, 'lcdGhost'))
	cell.ghost:SetDrawLayer('OVERLAY', 0)
	cell.digit = Kit:Text(lcd.band, '', lcd.size, 'lcdInk')
	cell.digit:SetDrawLayer('OVERLAY', 1)
	lcd.cells[index] = cell
	return cell
end

-- Width of every cell at a font size, and their sum.
function Digits.Widths(lcd, size)
	local measure, pattern = lcd.measure, lcd.pattern
	Kit:Font(measure, size)
	local digit = 0
	for value = 0, 9 do
		measure:SetText(tostring(value))
		digit = max(digit, measure:GetStringWidth() or 0)
	end
	local widths, total = {}, 0
	for index = 1, #pattern do
		local char = pattern:sub(index, index)
		local width = digit
		if char ~= '8' then
			measure:SetText(char)
			width = (measure:GetStringWidth() or 0) + size * 0.12
		end
		widths[index], total = width, total + width
	end
	return widths, total
end

function Digits.Layout(lcd)
	local room = lcd.band:GetWidth()
	if IsSecret(room) or not room or room <= 1 then return end
	local pattern = lcd.pattern
	local size = lcd.size
	local widths, total = Digits.Widths(lcd, size)
	if total > room and total > 0 then
		size = max(8, floor(size * room / total))
		widths, total = Digits.Widths(lcd, size)
	end
	-- Right-aligned on the glass, like every LCD readout.
	local x = room - total
	for index = 1, max(#pattern, #lcd.cells) do
		local cell = Digits.Cell(lcd, index)
		cell.ghost:ClearAllPoints()
		cell.digit:ClearAllPoints()
		if index <= #pattern then
			Kit:Font(cell.ghost, size)
			Kit:Font(cell.digit, size)
			local centre = x + widths[index] / 2
			cell.ghost:SetPoint('BOTTOM', lcd.band, 'BOTTOMLEFT', centre, 0)
			cell.digit:SetPoint('BOTTOM', lcd.band, 'BOTTOMLEFT', centre, 0)
			cell.ghost:SetText(pattern:sub(index, index))
			x = x + widths[index]
		else
			cell.ghost:SetText('')
			cell.digit:SetText('')
		end
	end
	Digits.Paint(lcd)
end

function Digits.Paint(lcd)
	local text, count = lcd.text, #lcd.pattern
	for index, cell in ipairs(lcd.cells) do
		local char = index <= count and text:sub(index, index) or ''
		if char == ' ' then char = '' end
		cell.digit:SetText(char)
		local lit = index <= lcd.shown
		if char == ':' and not lcd.colon then lit = false end
		cell.digit:SetAlpha(lit and 1 or 0)
	end
end

-- text: digits and separators; the ghost is the same text with every digit an 8.
function Digits.Set(lcd, text)
	text = tostring(text or '')
	local pattern = (text:gsub('%d', '8'))
	lcd.text = text
	if pattern ~= lcd.pattern then
		lcd.pattern = pattern
		Digits.Layout(lcd)
	else
		Digits.Paint(lcd)
	end
end

-- The power-on print: the digits light left to right over their ghosts.
function Digits.Reveal(lcd, delay)
	lcd.shown = 0
	Digits.Paint(lcd)
	Kit:Animate(Tag('awayReveal', lcd), delay + 0.36, 0, 1, function(_, progress)
		local t = progress * (delay + 0.36)
		lcd.shown = t < delay and 0 or floor(min(1, (t - delay) / 0.36) * (#lcd.pattern + 1))
		Digits.Paint(lcd)
	end, function()
		lcd.shown = 1000
		Digits.Paint(lcd)
	end, 'linear')
end

-- Function keys ----------------------------------------------------------------------------
-- Light keys with a printed glyph from the menu atlas (the action bar
-- console's: the same order as MENU_ICONS in Modules/ActionBars.lua), a lamp
-- for the ones that latch, and a printed legend under them.
local GLYPH = {character = 0, social = 8, map = 16, backpack = 18, hearth = 23, calendar = 26, meter = 27, reload = 29}

local function FnKey(parent, def)
	local key = Kit:Key(parent, {width = def.width or KEY, height = KEY, text = def.text, icon = def.icon, iconSize = def.iconSize,
		sound = def.sound, onClick = def.onClick})
	if def.glyph then
		local index = GLYPH[def.glyph] or 0
		local column, row = index % 8, floor(index / 8)
		key.glyph = key.face:CreateTexture(nil, 'ARTWORK', nil, 1)
		key.glyph:SetTexture(Kit.media..'icons-menu.tga')
		key.glyph:SetTexCoord(column / 8, (column + 1) / 8, row / 4, (row + 1) / 4)
		key.glyph:SetSize(18, 18)
		key.glyph:SetPoint('CENTER', 0, -1)
		Kit:Tint(key.glyph, 'ink', 0.85)
	end
	key.lamp = Kit:Led(key.face, 4, false)
	key.lamp:SetPoint('TOPRIGHT', -5, -5)
	Kit:ShowLed(key.lamp, false)
	if def.legend then
		key.legend = Kit:Label(parent, def.legend, 'dim', 7, true)
		key.legend:SetPoint('TOP', key, 'BOTTOM', 0, -4)
		key.legend:SetWidth(KEY + KEY_GAP - 2)
		key.legend:SetWordWrap(false)
	end
	return key
end

local function SetLamp(key, on)
	Kit:SetLed(key.lamp, on and true or false)
	Kit:ShowLed(key.lamp, true)
end

-- A small printed caption over a group of keys, with a hairline after it.
local function Caption(parent, text, x, y, width)
	local line = CreateFrame('Frame', nil, parent)
	line:SetPoint('TOPLEFT', x, y)
	line:SetSize(width, 9)
	local label = Kit:Label(line, text, 'dim', 7, true)
	label:SetPoint('LEFT')
	label:SetWordWrap(false)
	local rule = Kit:Solid(line, 'line')
	rule:SetPoint('LEFT', label, 'RIGHT', 6, 0)
	rule:SetPoint('RIGHT')
	rule:SetHeight(1)
	A.rules[#A.rules + 1] = rule
	return label
end

-- Readings ---------------------------------------------------------------------------------
local function Duration(seconds)
	if not seconds or seconds < 0 then return '--' end
	seconds = floor(seconds)
	if seconds >= 86400 then return format('%dD %02dH', floor(seconds / 86400), floor(seconds % 86400 / 3600)) end
	if seconds >= 3600 then return format('%dH %02dM', floor(seconds / 3600), floor(seconds % 3600 / 60)) end
	return format('%dM %02dS', floor(seconds / 60), seconds % 60)
end

local function Thousands(value)
	if BreakUpLargeNumbers then
		local ok, text = pcall(BreakUpLargeNumbers, value)
		if ok and type(text) == 'string' then return text end
	end
	return tostring(value)
end

local function Gold(copper)
	if type(copper) ~= 'number' then return '--' end
	local gold = floor(copper / 10000)
	if gold > 0 then return Thousands(gold)..'G' end
	return format('%dS %dC', floor(copper % 10000 / 100), copper % 100)
end

local function Coins(copper)
	local parts = {}
	local gold, silver, rest = floor(copper / 10000), floor(copper % 10000 / 100), copper % 100
	if gold > 0 then parts[#parts + 1] = Thousands(gold)..'G' end
	if silver > 0 then parts[#parts + 1] = silver..'S' end
	if rest > 0 or #parts == 0 then parts[#parts + 1] = rest..'C' end
	return table.concat(parts, ' ')
end

local function Durability()
	local lowest
	for slot = 1, 18 do
		local current, maximum = Call(GetInventoryItemDurability, slot)
		if type(current) == 'number' and type(maximum) == 'number' and maximum > 0 then
			local fraction = current / maximum
			if not lowest or fraction < lowest then lowest = fraction end
		end
	end
	return lowest
end

local function ItemLevel()
	local overall, equipped = Call(GetAverageItemLevel)
	local value = equipped or overall
	if type(value) ~= 'number' or value <= 0 then return nil end
	return value
end

local function MaxLevel(level)
	if Plain(IsXPUserDisabled) then return true end
	local at = Plain(IsPlayerAtEffectiveMaxLevel)
	if at ~= nil then return at and true or false end
	local cap = Plain(GetMaxLevelForPlayerExpansion) or Plain(GetMaxPlayerLevel) or MAX_PLAYER_LEVEL
	return type(level) == 'number' and type(cap) == 'number' and level >= cap
end

-- Time played: asked once, quietly. The chat frames are taken off the answer
-- while our request is out, so it prints nowhere; they get it back right after.
-- An answer to anyone else's request is kept too, so we rarely need to ask.
local played, quieted = {}, {}
local function Quiet(on)
	if on then
		for index = 1, (NUM_CHAT_WINDOWS or 10) do
			local frame = _G['ChatFrame'..index]
			if frame and frame.IsEventRegistered and frame:IsEventRegistered('TIME_PLAYED_MSG') then
				frame:UnregisterEvent('TIME_PLAYED_MSG')
				quieted[#quieted + 1] = frame
			end
		end
	else
		for index, frame in ipairs(quieted) do
			frame:RegisterEvent('TIME_PLAYED_MSG')
			quieted[index] = nil
		end
	end
end

local function AskPlayed()
	if played.total or played.asking or not DB().afkPlayed or not RequestTimePlayed then return end
	played.asking = true
	Quiet(true)
	pcall(RequestTimePlayed)
	-- Never hold the chat frames for long, answered or not.
	C_Timer.After(5, function()
		Quiet(false)
		played.asking = nil
	end)
end

local function PlayedSeconds()
	if not played.total then return nil end
	return played.total + (GetTime() - played.at)
end

-- Console log --------------------------------------------------------------------------------
-- Entries: {kind, stamp, at, text} or {kind, stamp, at, fmt, a, b} where a and
-- b may be secret (they only ever reach SetFormattedText). Newest at the bottom.
local Log = {entries = {}, rows = {}, count = 0}
local KINDS = {
	whisper = {'Whisper', 'amber'}, bnet = {'B.net', 'blue'}, guild = {'Guild', 'green'}, officer = {'Officer', 'green'},
	party = {'Party', 'blue'}, raid = {'Raid', 'red'}, instance = {'Group', 'red'}, mail = {'Mail', 'amber'},
	level = {'Level', 'lamp'}, xp = {'XP', 'lamp'}, money = {'Money', 'amber'}, loot = {'Loot', 'green'},
	alert = {'Alert', 'red'}, sys = {'Sys', nil},
}
local MAX_ENTRIES = 40

function Log.Paint(row, entry)
	StopPrint(row.time)
	StopPrint(row.kind)
	StopPrint(row.body)
	if not entry then
		row.time:SetText('')
		row.kind:SetText('')
		row.body:SetText('')
		Kit:ShowLed(row.lamp, false)
		return
	end
	local kind = KINDS[entry.kind] or KINDS.sys
	row.time:SetText(entry.stamp)
	row.kind:SetText(strupper(kind[1]))
	if kind[2] then
		Kit:SetLed(row.lamp, true, kind[2])
		Kit:ShowLed(row.lamp, true)
	else
		Kit:ShowLed(row.lamp, false)
	end
	if entry.fmt then
		row.body:SetFormattedText(entry.fmt, Arg(entry.a), Arg(entry.b))
	else
		row.body:SetText(entry.text or '')
	end
end

function Log.Render(fresh)
	local list, rows = Log.entries, Log.rows
	local count = #rows
	for index = 1, count do Log.Paint(rows[index], list[#list - (count - index)]) end
	if fresh and rows[count] then
		PrintIn(rows[count].time)
		PrintIn(rows[count].kind, 0.04)
		PrintIn(rows[count].body, 0.08)
	end
	if A.console then A.console.count:SetText(format('%02d EVENTS', Log.count)) end
end

local ALERTS = {whisper = 'blip', bnet = 'blip', mail = 'blip', level = 'success', alert = 'warning'}
function Log.Add(kind, text, fmt, a, b)
	if not Shown() then return nil end
	if kind ~= 'sys' and not DB().afkLog then return nil end
	local entry = {kind = kind, stamp = date('%H:%M'), at = GetTime(), text = text, fmt = fmt, a = a, b = b}
	local list = Log.entries
	list[#list + 1] = entry
	if #list > MAX_ENTRIES then table.remove(list, 1) end
	if kind ~= 'sys' then Log.count = Log.count + 1 end
	Log.Render(true)
	local voice = ALERTS[kind]
	if voice and DB().afkBlips then Sound(voice, 0, 1.2) end
	if kind == 'whisper' or kind == 'bnet' or kind == 'alert' then
		-- Something for you: the console's lamp breathes amber until the screen goes.
		Kit:SetLed(A.console.lamp, true, 'amber')
		Kit:Breathe(A.console.lamp, true, {period = 1.4, low = 0.3})
		Kit:Flash(A.console, {token = 'amber', alpha = 0.22, duration = 0.5})
		if kind == 'alert' and FlashClientIcon then FlashClientIcon() end
	end
	return entry
end

-- Experience comes in many small amounts; a minute's worth shares one line.
function Log.XP(amount)
	local last = Log.entries[#Log.entries]
	if last and last.kind == 'xp' and GetTime() - last.at < 60 then
		last.amount = last.amount + amount
		last.text = format('+%s experience', Thousands(last.amount))
		last.at, last.stamp = GetTime(), date('%H:%M')
		Log.Render(false)
		return
	end
	local entry = Log.Add('xp', format('+%s experience', Thousands(amount)))
	if entry then entry.amount = amount end
end

function Log.Start()
	wipe(Log.entries)
	Log.count = 0
	Log.money = Plain(GetMoney)
	Log.xp, Log.xpMax = Plain(UnitXP, 'player'), Plain(UnitXPMax, 'player')
	Log.mail = Plain(HasNewMail)
	if S.preview then
		Log.Add('sys', 'Preview. Back, Esc or a step puts it away.')
	else
		Log.Add('sys', format('Standby since %s. Events print here.', date('%H:%M')))
	end
	if Log.mail then Log.Add('mail', 'Unread mail waiting') end
end

local CHAT = {CHAT_MSG_WHISPER = 'whisper', CHAT_MSG_BN_WHISPER = 'bnet', CHAT_MSG_GUILD = 'guild', CHAT_MSG_OFFICER = 'officer',
	CHAT_MSG_PARTY = 'party', CHAT_MSG_PARTY_LEADER = 'party', CHAT_MSG_RAID = 'raid', CHAT_MSG_RAID_LEADER = 'raid',
	CHAT_MSG_RAID_WARNING = 'raid', CHAT_MSG_INSTANCE_CHAT = 'instance', CHAT_MSG_INSTANCE_CHAT_LEADER = 'instance'}

-- Who said it, as short as the game would show it. A secret name goes as it is.
local function Speaker(sender, kind)
	if IsSecret(sender) or type(sender) ~= 'string' or kind == 'bnet' or not Ambiguate then return sender end
	local ok, short = pcall(Ambiguate, sender, 'short')
	if ok and type(short) == 'string' then return short end
	return sender
end

-- Our own lines are skipped, when the client says plainly that they are ours.
local function Mine(guid)
	if IsSecret(guid) or guid == nil then return false end
	return guid == Plain(UnitGUID, 'player')
end

-- Readouts that update ------------------------------------------------------------------------
local function PaintClass()
	local rgb = A.classRGB
	local ink = (Kit.INK[A.main.surface] or Kit.INK.paper)[1]
	if not rgb then return Kit:Tint(A.class, ink) end
	local r, g, b = rgb[1], rgb[2], rgb[3]
	-- Light class colours (white, yellow) are darkened on a light housing so they stay readable.
	local pr, pg, pb = Kit:RGB('panel')
	if 0.299 * pr + 0.587 * pg + 0.114 * pb > 0.5 and 0.299 * r + 0.587 * g + 0.114 * b > 0.6 then
		r, g, b = r * 0.58, g * 0.58, b * 0.58
	end
	Kit:Tint(A.class, {r, g, b})
end

-- Long names, guilds and zones end in an ellipsis inside the identity column.
local function FitIdentity()
	local width = A.identWidth
	A.name:SetWidth(width)
	A.guild:SetWidth(width)
	A.zone:SetWidth(width)
	A.level:SetWidth(0)
	local levelWidth = A.level:GetStringWidth() or 0
	A.level:SetWidth(min(levelWidth + 1, width * 0.5))
	A.class:SetWidth(max(10, width - min(levelWidth + 1, width * 0.5) - 8))
end

local function FillZone()
	local zone = Plain(GetRealZoneText) or Plain(GetZoneText) or ''
	local sub = Plain(GetSubZoneText) or ''
	local text = zone
	if sub ~= '' and sub ~= zone then text = zone..'  /  '..sub end
	A.zone:SetText(strupper(text))
end

local function FillIdentity()
	local name = Plain(UnitName, 'player')
	A.name:SetText(name and strupper(name) or '')
	local guild = Plain(GetGuildInfo, 'player')
	A.guild:SetText(type(guild) == 'string' and ('<'..guild..'>') or '')
	local level = Plain(UnitLevel, 'player')
	A.level:SetText(type(level) == 'number' and format('LEVEL %d', level) or 'LEVEL ??')
	local className, classFile = Call(UnitClass, 'player')
	A.class:SetText(type(className) == 'string' and strupper(className) or '')
	local color = classFile and ((C_ClassColor and C_ClassColor.GetClassColor and C_ClassColor.GetClassColor(classFile))
		or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]))
	A.classRGB = color and {color.r, color.g, color.b} or nil
	PaintClass()
	FillZone()
	FitIdentity()
end

-- The rested part sits between the dots, in blue, from the start of the meter.
local function PlaceRested()
	local rested, width = A.xpRested, A.xpBar:GetWidth()
	local fraction = A.restedFraction or 0
	if IsSecret(width) or not width or width <= 0 or fraction <= 0 then rested:Hide() return end
	rested:SetWidth(max(1, width * fraction))
	rested:Show()
end

local function UpdateXP()
	local bar = A.xpBar
	local level = Plain(UnitLevel, 'player')
	A.restedFraction = 0
	if MaxLevel(level) then
		bar:SetMinMaxValues(0, 1)
		bar:SetValue(1)
		Kit:Tint(bar, 'dim')
		A.xpText:SetText('MAX LEVEL')
		return PlaceRested()
	end
	Kit:Tint(bar, 'lamp')
	local ok, current, total = pcall(function() return UnitXP('player'), UnitXPMax('player') end)
	if not ok then return end
	if IsSecret(current) or IsSecret(total) then
		-- The bar fills natively from secret values; the readout only passes them on.
		bar:SetMinMaxValues(0, total)
		bar:SetValue(current)
		A.xpText:SetFormattedText('%s / %s', current, total)
		return PlaceRested()
	end
	total = (type(total) == 'number' and total > 0) and total or 1
	current = type(current) == 'number' and current or 0
	bar:SetMinMaxValues(0, total)
	bar:SetValue(current)
	local rested = Plain(GetXPExhaustion)
	local text = format('%.1f%%', current / total * 100)
	if type(rested) == 'number' and rested > 0 then
		text = text..format('  RESTED %d%%', floor(rested / total * 100 + 0.5))
		A.restedFraction = min(1, (current + rested) / total)
	end
	A.xpText:SetText(text)
	PlaceRested()
end

local function UpdateCells()
	local cells = A.cells
	cells.clock:SetText(date('%H:%M'))
	cells.clock.tag:SetText(strupper(date('%a %d %b')))
	cells.played:SetText(Duration(PlayedSeconds()))
	cells.gold:SetText(Gold(Plain(GetMoney)))
	if cells.ilvl:IsShown() then
		local value = ItemLevel()
		cells.ilvl:SetText(value and format('%.1f', value) or '--')
	end
	local lowest = Durability()
	cells.dur:SetText(lowest and format('%d%%', floor(lowest * 100 + 0.5)) or '--')
	Kit:SetLed(cells.dur.lamp, lowest ~= nil, lowest and (lowest < 0.2 and 'red' or lowest < 0.5 and 'amber' or 'green') or nil)
end

local function MemoryMB()
	if InCombatLockdown() or not (UpdateAddOnMemoryUsage and GetAddOnMemoryUsage) then return A.memory end
	pcall(UpdateAddOnMemoryUsage)
	local count = (C_AddOns and Plain(C_AddOns.GetNumAddOns)) or Plain(GetNumAddOns) or 0
	local total = 0
	for index = 1, count do
		local kb = Plain(GetAddOnMemoryUsage, index)
		if type(kb) == 'number' then total = total + kb end
	end
	A.memory = total / 1024
	return A.memory
end

local function SetStat(cell, text, lamp)
	cell.value:SetText(text)
	Kit:SetLed(cell.led, lamp ~= nil, lamp)
end

-- full: memory too (it is costly to read, so only every ten seconds).
local function UpdateStats(full)
	local stats = A.stats
	local fps = Plain(GetFramerate)
	if type(fps) == 'number' then
		SetStat(stats.fps, format('%d', floor(fps + 0.5)), fps >= 50 and 'green' or fps >= 25 and 'amber' or 'red')
	else
		SetStat(stats.fps, '--')
	end
	local _, _, home, world = Call(GetNetStats)
	for _, pair in ipairs({{stats.home, home}, {stats.world, world}}) do
		local ms = pair[2]
		if type(ms) == 'number' then
			SetStat(pair[1], format('%d', ms), ms < 150 and 'green' or ms < 300 and 'amber' or 'red')
		else
			SetStat(pair[1], '--')
		end
	end
	local mb = full and MemoryMB() or A.memory
	SetStat(stats.mem, type(mb) == 'number' and format('%.1f', mb) or '--', type(mb) == 'number' and 'blue' or nil)
end

-- Volume ------------------------------------------------------------------------------------
local CHANNELS = {{'Sound_MusicVolume', 'Music'}, {'Sound_SFXVolume', 'Effects'}, {'Sound_AmbienceVolume', 'Ambience'},
	{'Sound_DialogVolume', 'Dialog'}}

local function ReadVolume(name)
	local value = tonumber(Plain(GetCVar, name) or '')
	return value and floor(value * 100 + 0.5) or 100
end
local function SetVolume(name, value) pcall(SetCVar, name, format('%.2f', value / 100)) end
local function Percent(value) return format('%d%%', value) end

local function SyncVolume()
	if not A.master then return end
	A.master:SetValue(ReadVolume('Sound_MasterVolume'))
	for _, knob in ipairs(A.knobs) do knob:SetValue(ReadVolume(knob.cvar)) end
	A.mute:SetChecked(Plain(GetCVar, 'Sound_EnableAllSound') == '0')
end

-- Model -------------------------------------------------------------------------------------
-- A PlayerModel given its unit before it has a real size, or while hidden,
-- stays blank until something redraws it (see the unit frames' 3D portrait).
-- So it is drawn only once shown and sized, drawn again on the next frame
-- whenever it is shown, resized or rescaled, and retried a few times while
-- the client reports nothing loaded.
local DANCE, IDLE = 69, 0
local MODEL_TRIES = 6

local function HasModel(model)
	if not model.GetModelFileID then return true end
	local ok, id = pcall(model.GetModelFileID, model)
	if not ok or IsSecret(id) then return true end
	return id ~= nil and id ~= 0
end

local function DrawModel()
	local model = A.model
	if not (model and model:IsVisible()) then return false end
	local width, height = model:GetSize()
	if IsSecret(width) or IsSecret(height) or not width or not height or width < 2 or height < 2 then return false end
	model:ClearModel()
	model:SetUnit('player')
	if model.SetPortraitZoom then pcall(model.SetPortraitZoom, model, 0) end
	if model.SetCamDistanceScale then pcall(model.SetCamDistanceScale, model, A.zoom or 1) end
	if model.SetPosition then pcall(model.SetPosition, model, 0, 0, 0) end
	model:SetFacing(A.turn or 0.4)
	if model.SetAnimation then pcall(model.SetAnimation, model, A.dancing and DANCE or IDLE) end
	return true
end

local function RefreshModel(tries)
	tries = tries or 0
	A.modelToken = (A.modelToken or 0) + 1
	local token = A.modelToken
	C_Timer.After(tries == 0 and 0 or min(0.15 * tries, 0.8), function()
		if A.modelToken ~= token or not Shown() then return end
		local ok, drawn = pcall(DrawModel)
		if ok and drawn then
			C_Timer.After(0.25, function()
				if A.modelToken == token and Shown() and not HasModel(A.model) and tries < MODEL_TRIES then RefreshModel(tries + 1) end
			end)
		elseif tries < MODEL_TRIES then
			RefreshModel(tries + 1)
		end
	end)
end

-- Turns slowly while shown (not with Reduce motion or the switch off); a drag
-- turns it by hand and it carries on by itself a moment after.
local function TurnModel(model, elapsed)
	local drag = A.drag
	if drag then
		local x = Kit:Cursor(A.stage)
		A.turn = (drag.turn + (x - drag.x) * 0.012) % (2 * pi)
		model:SetFacing(A.turn)
	elseif DB().afkTurn and not Kit:Reduced() and GetTime() >= (A.hold or 0) then
		A.turn = ((A.turn or 0.4) + elapsed * 0.25) % (2 * pi)
		model:SetFacing(A.turn)
	end
	A.readoutWait = (A.readoutWait or 0) - elapsed
	if A.readoutWait <= 0 then
		A.readoutWait = 0.1
		A.rot:SetFormattedText('ROT %03d', floor((A.turn or 0) * 180 / pi + 0.5) % 360)
	end
end

-- Leaving -----------------------------------------------------------------------------------
local function Dismiss()
	S.dismissed = true
	module:HideAFK()
end

-- Keys that go somewhere else put the screen away first.
local function Leave(open)
	Dismiss()
	C_Timer.After(0.05, function()
		if not InCombatLockdown() then UI:Safe(open) end
	end)
end

local function SyncSpin()
	local want = DB().afkSpin and Shown()
	if want and not S.spinning and MoveViewLeftStart then
		MoveViewLeftStart(0.035)
		S.spinning = true
	elseif not want and S.spinning then
		if MoveViewLeftStop then MoveViewLeftStop() end
		S.spinning = nil
	end
end

local function PaintKeys()
	if not A.keys then return end
	SetLamp(A.keys.music, Plain(GetCVar, 'Sound_EnableMusic') == '1')
	SetLamp(A.keys.spin, DB().afkSpin)
	SetLamp(A.keys.dance, A.dancing)
end

-- The screenshot: everything of ours fades out of the shot and back after it.
local function RestoreShot()
	if not A.shooting then return end
	A.shooting = nil
	if A.shotTimer then A.shotTimer:Cancel(); A.shotTimer = nil end
	if not Shown() then return end
	A.screen:SetAlpha(1)
	if not Kit:Reduced() then
		A.flash:Show()
		Kit:Animate(Tag('awayShot', A.flash), 0.35, 0.55, 0, function(alpha) A.flash:SetAlpha(alpha) end,
			function() A.flash:Hide() end, 'sine')
	end
end

local function TakeShot()
	if not Screenshot or A.shooting then return end
	A.shooting = true
	Sound('shutter', 0.03)
	A.screen:SetAlpha(0)
	C_Timer.After(0.1, function() if A.shooting then pcall(Screenshot) end end)
	A.shotTimer = C_Timer.NewTimer(3, RestoreShot)
end

-- Building ----------------------------------------------------------------------------------
local function BuildStage(canvas)
	local stage = CreateFrame('Frame', nil, canvas)
	stage:SetSize(STAGE_W, CANVAS_H)
	A.stage = stage
	-- A soft back light behind the figure and a lit spot on the floor.
	stage.back = Kit:Texture(stage, 'glow', 'BACKGROUND', 0)
	stage.back:SetSize(420, 560)
	stage.back:SetPoint('CENTER', 0, 20)
	Kit:Tint(stage.back, 'screenAccent', 0.1)
	stage.spot = Kit:Texture(stage, 'glow', 'BACKGROUND', 1)
	stage.spot:SetSize(380, 90)
	stage.spot:SetPoint('BOTTOM', 0, 6)
	Kit:Tint(stage.spot, 'lamp', 0.22)
	stage.ring = Kit:Texture(stage, 'circle-ring', 'BORDER', 0)
	stage.ring:SetSize(300, 52)
	stage.ring:SetPoint('BOTTOM', 0, 24)
	Kit:Tint(stage.ring, 'darkInk', 0.32)
	stage.ringInner = Kit:Texture(stage, 'circle-ring', 'BORDER', 1)
	stage.ringInner:SetSize(176, 30)
	stage.ringInner:SetPoint('BOTTOM', 0, 35)
	Kit:Tint(stage.ringInner, 'lamp', 0.55)

	local model = CreateFrame('PlayerModel', nil, stage)
	model:SetPoint('TOPLEFT', 10, -24)
	model:SetPoint('BOTTOMRIGHT', -10, 30)
	model:SetFrameLevel(stage:GetFrameLevel() + 3)
	model:EnableMouse(false)
	model:HookScript('OnSizeChanged', function() if Shown() then RefreshModel() end end)
	A.model = model

	-- Hardware print over the stage: corner marks, captions, the scan line.
	local over = CreateFrame('Frame', nil, stage)
	over:SetAllPoints()
	over:SetFrameLevel(stage:GetFrameLevel() + 8)
	over:EnableMouse(false)
	A.over = over
	over.marks = {}
	for _, corner in ipairs({'TOPLEFT', 'TOPRIGHT', 'BOTTOMLEFT', 'BOTTOMRIGHT'}) do
		for _, across in ipairs({true, false}) do
			local mark = Kit:Solid(over, 'darkInk', 'OVERLAY', 0, 0.6)
			mark:SetPoint(corner)
			mark.across = across
			over.marks[#over.marks + 1] = mark
		end
	end
	local function Print(text, point, x, align)
		local label = Kit:Text(over, strupper(text), 7, 'darkDim', true, true)
		label:SetPoint(align, over, point, x, 0)
		return label
	end
	Print('Cam 01  Player', 'TOPLEFT', 30, 'LEFT')
	over.live = Print('Live', 'TOPRIGHT', -30, 'RIGHT')
	over.liveLamp = Kit:Led(over, 4, false)
	over.liveLamp:SetPoint('RIGHT', over.live, 'LEFT', -5, 0)
	A.rot = Print('Rot 000', 'BOTTOMLEFT', 30, 'LEFT')
	Print('Drag  /  scroll', 'BOTTOMRIGHT', -30, 'RIGHT')
	over.scan = over:CreateTexture(nil, 'OVERLAY', nil, 2)
	over.scan:SetColorTexture(1, 1, 1, 1)
	over.scan:SetBlendMode('ADD')
	Kit:Tint(over.scan, 'lamp')
	over.scan:Hide()
	over.trail = over:CreateTexture(nil, 'OVERLAY', nil, 1)
	over.trail:SetColorTexture(1, 1, 1, 1)
	over.trail:SetBlendMode('ADD')
	over.trail:SetPoint('TOPLEFT', over.scan, 'BOTTOMLEFT')
	over.trail:SetPoint('TOPRIGHT', over.scan, 'BOTTOMRIGHT')
	over.trail:SetHeight(18)
	over.trail:Hide()
	-- The power-on sweep: a bright line down the stage, once.
	over.power = over:CreateTexture(nil, 'OVERLAY', nil, 3)
	over.power:SetColorTexture(1, 1, 1, 1)
	over.power:SetBlendMode('ADD')
	over.power:Hide()

	-- Drag to turn, scroll to step the camera in or out.
	stage:EnableMouse(true)
	stage:EnableMouseWheel(true)
	stage:SetScript('OnMouseDown', function(self, button)
		if button ~= 'LeftButton' then return end
		A.drag = {x = Kit:Cursor(self), turn = A.turn or 0}
		Sound('servo', 0, 0.6)
	end)
	stage:SetScript('OnMouseUp', function()
		if not A.drag then return end
		A.drag = nil
		A.hold = GetTime() + 2.5
	end)
	stage:SetScript('OnHide', function() A.drag = nil end)
	stage:SetScript('OnMouseWheel', function(_, delta)
		local zoom = Kit:Clamp((A.zoom or 1) - delta * 0.08, 0.7, 1.3)
		if zoom == A.zoom then return end
		A.zoom = zoom
		if model.SetCamDistanceScale then pcall(model.SetCamDistanceScale, model, zoom) end
		Sound('tick', 0, 0.05)
	end)
	return stage
end

local function BuildMain(canvas)
	local device = Kit:Device(canvas, {model = 'AW-1', title = 'Standby', width = MAIN_W, height = MAIN_H, radius = 14})
	A.main = device
	local ink = Kit.INK[device.surface] or Kit.INK.paper
	device.badge = Kit:Badge(device, {text = 'Away', tone = 'amber'})
	device.badge:SetPoint('RIGHT', device, 'TOPRIGHT', -12, -11.5)
	device.title:SetPoint('RIGHT', device.badge, 'LEFT', -8, 0)

	-- Who: name in the title face, guild, level and class, zone.
	A.identWidth = MAIN_W - 16 * 3 - 236
	A.name = Kit:Text(device, '', 26, ink[1], true)
	A.name:SetPoint('TOPLEFT', 16, -36)
	A.guild = Kit:Text(device, '', 11, ink[2])
	A.guild:SetPoint('TOPLEFT', A.name, 'BOTTOMLEFT', 0, -5)
	A.level = Kit:Label(device, '', ink[1], 10, true)
	A.level:SetPoint('TOPLEFT', A.guild, 'BOTTOMLEFT', 0, -7)
	A.class = Kit:Label(device, '', ink[1], 10, true)
	A.class:SetPoint('LEFT', A.level, 'RIGHT', 8, 0)
	A.zone = Kit:Label(device, '', ink[2], 8)
	A.zone:SetPoint('TOPLEFT', A.level, 'BOTTOMLEFT', 0, -7)
	for _, text in ipairs({A.name, A.guild, A.level, A.class, A.zone}) do
		text:SetJustifyH('LEFT')
		text:SetWordWrap(false)
	end

	-- Time away: HH:MM:SS over its own ghost, the colons blinking.
	A.away = Digits.New(device, 'Time away', 36)
	A.away:SetSize(236, 70)
	A.away:SetPoint('TOPRIGHT', -16, -36)

	-- Clock and date, time played, gold, item level and durability.
	A.cells = {}
	A.cellOrder = {}
	for _, def in ipairs({{'clock', 'Clock'}, {'played', 'Played'}, {'gold', 'Gold'}, {'ilvl', 'Item level'}, {'dur', 'Durability'}}) do
		local lcd = Kit:LCD(device, {tag = def[2], text = '--', size = 'sm', width = 100})
		Kit:SetFontRole(lcd, 'numbers')
		A.cells[def[1]] = lcd
		A.cellOrder[#A.cellOrder + 1] = lcd
	end
	A.cells.ilvl:SetShown(GetAverageItemLevel ~= nil)
	A.cells.dur.lamp = Kit:Led(A.cells.dur, 4, false)
	A.cells.dur.lamp:SetPoint('TOPRIGHT', -7, -7)

	-- Experience as a dot meter; rested shows in blue past the lit dots.
	A.xpLegend = Kit:Label(device, 'XP', ink[1], 8, true)
	A.xpLegend:SetPoint('TOPLEFT', 16, -183)
	A.xpText = Kit:Label(device, '', ink[2], 8, true)
	A.xpText:SetPoint('TOPRIGHT', -16, -183)
	A.xpText:SetWordWrap(false)
	local track = Kit:Well(device, 6, 'track')
	track:SetHeight(12)
	track:SetPoint('LEFT', A.xpLegend, 'RIGHT', 10, 0)
	track:SetPoint('RIGHT', A.xpText, 'LEFT', -10, 0)
	local bar = CreateFrame('StatusBar', nil, track)
	bar:SetPoint('TOPLEFT', 4, -2)
	bar:SetPoint('BOTTOMRIGHT', -4, 2)
	bar:SetStatusBarTexture([[Interface\Buttons\WHITE8X8]])
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)
	Kit:Tint(bar, 'lamp')
	Kit:Perforate(bar, 'track')
	A.xpBar = bar
	-- Above the unlit dots, under the fill and the perforated cover.
	A.xpRested = bar:CreateTexture(nil, 'BACKGROUND', nil, 2)
	A.xpRested:SetColorTexture(1, 1, 1, 1)
	A.xpRested:SetPoint('TOPLEFT')
	A.xpRested:SetPoint('BOTTOMLEFT')
	Kit:Tint(A.xpRested, 'blue', 0.75)
	A.xpRested:Hide()
	bar:HookScript('OnSizeChanged', PlaceRested)

	-- Function keys: Back; the screen's own keys; keys that leave it.
	A.rules = {}
	A.keys = {}
	local top = -220
	A.back = FnKey(device, {width = 100, text = 'Back', icon = 'power', iconSize = 12, sound = 'down-primary', onClick = Dismiss})
	A.back:SetPoint('TOPLEFT', 16, top)
	Kit:SetLed(A.back.lamp, true)
	Kit:ShowLed(A.back.lamp, true)
	local SCREEN = {
		{id = 'shot', glyph = 'hearth', legend = 'Shot', onClick = TakeShot},
		{id = 'music', glyph = 'meter', legend = 'Music', sound = 'latch-down', onClick = function()
			local on = Plain(GetCVar, 'Sound_EnableMusic') == '1'
			pcall(SetCVar, 'Sound_EnableMusic', on and '0' or '1')
			PaintKeys()
		end},
		{id = 'spin', glyph = 'reload', legend = 'Spin', sound = 'latch-down', onClick = function()
			DB().afkSpin = not DB().afkSpin
			SyncSpin()
			PaintKeys()
		end},
		{id = 'dance', glyph = 'character', legend = 'Dance', sound = 'latch-down', onClick = function()
			A.dancing = not A.dancing
			if A.model.SetAnimation then pcall(A.model.SetAnimation, A.model, A.dancing and DANCE or IDLE) end
			PaintKeys()
		end},
	}
	local OPEN = {
		{id = 'bags', glyph = 'backpack', legend = 'Bags', onClick = function() Leave(function()
			local toggle = ToggleAllBags or OpenAllBags
			if toggle then toggle() end
		end) end},
		{id = 'map', glyph = 'map', legend = 'Map', onClick = function() Leave(function()
			if ToggleWorldMap then ToggleWorldMap() end
		end) end},
		{id = 'calendar', glyph = 'calendar', legend = 'Calendar', onClick = function() Leave(function()
			if UI.OpenCalendar then UI:OpenCalendar() elseif ToggleCalendar then ToggleCalendar() end
		end) end},
		{id = 'friends', glyph = 'social', legend = 'Friends', onClick = function() Leave(function()
			if ToggleFriendsFrame then ToggleFriendsFrame(1) end
		end) end},
	}
	local group = 4 * KEY + 3 * KEY_GAP
	local function Row(list, x, caption)
		Caption(device, caption, x, top + 13, group)
		for index, def in ipairs(list) do
			local key = FnKey(device, def)
			key:SetPoint('TOPLEFT', x + (index - 1) * (KEY + KEY_GAP), top)
			A.keys[def.id] = key
		end
	end
	Row(SCREEN, 16 + 100 + 24, 'Screen')
	Row(OPEN, MAIN_W - 16 - group, 'Leave and open')
	return device
end

local function BuildConsole(canvas)
	local device = Kit:Device(canvas, {model = 'CN-1', title = 'Console', width = MAIN_W, height = CONSOLE_H, radius = 14})
	A.console = device
	local ink = Kit.INK[device.surface] or Kit.INK.paper
	device.count = Kit:Label(device, '', ink[2], 8, true)
	device.count:SetPoint('RIGHT', device, 'TOPRIGHT', -14, -11.5)
	device.title:SetPoint('RIGHT', device.count, 'LEFT', -8, 0)
	-- The log: gray LCD glass, one line per event.
	local glass = Kit:Panel(device, {radius = 6, fill = 'lcd', border = 'hair'})
	glass:SetPoint('TOPLEFT', 12, -28)
	glass:SetPoint('BOTTOMRIGHT', -12, 38)
	A.glass = glass
	local line = 15
	local count = floor((CONSOLE_H - 28 - 38 - 16) / line)
	for index = 1, count do
		local row = CreateFrame('Frame', nil, glass)
		row:SetHeight(line)
		local y = 8 + (count - index) * line
		row:SetPoint('BOTTOMLEFT', 10, y)
		row:SetPoint('BOTTOMRIGHT', -10, y)
		row.time = Kit:Text(row, '', 9, 'lcdDim')
		row.time:SetPoint('LEFT')
		row.lamp = Kit:Led(row, 4, false)
		Kit:ShowLed(row.lamp, false)
		row.kind = Kit:Label(row, '', 'lcdInk', 7, true)
		row.kind:SetJustifyH('LEFT')
		row.kind:SetWordWrap(false)
		row.body = Kit:Text(row, '', 10, 'lcdInk')
		row.body:SetJustifyH('LEFT')
		row.body:SetWordWrap(false)
		row.body:SetPoint('RIGHT')
		Log.rows[index] = row
	end
	-- Hidden copies measure the time and kind columns for the typeface in use.
	A.measureTime = Kit:Text(glass, '', 9, 'lcdDim')
	A.measureTime:Hide()
	A.measureKind = Kit:Label(glass, '', 'lcdInk', 7, true)
	A.measureKind:Hide()

	-- The stats strip: lamp, legend and a small LCD per reading.
	A.stats = {}
	A.statOrder = {}
	for _, def in ipairs({{'fps', 'FPS'}, {'home', 'Home ms'}, {'world', 'World ms'}, {'mem', 'Memory mb'}}) do
		local cell = CreateFrame('Frame', nil, device)
		cell:SetHeight(16)
		cell.led = Kit:Led(cell, 4, false)
		cell.led:SetPoint('LEFT', 1, 0)
		cell.legend = Kit:Label(cell, def[2], ink[2], 7, true)
		cell.legend:SetPoint('LEFT', cell.led, 'RIGHT', 5, 0)
		cell.legend:SetWordWrap(false)
		cell.lcd = Kit:LCDPanel(cell, {radius = 3})
		cell.lcd:SetPoint('TOPRIGHT')
		cell.lcd:SetPoint('BOTTOMRIGHT')
		cell.value = Kit:Text(cell.lcd, '--', 8, 'lcdInk', true)
		cell.value:SetPoint('RIGHT', -5, 0)
		A.stats[def[1]] = cell
		A.statOrder[#A.statOrder + 1] = cell
	end
	return device
end

local function BuildMixer(canvas)
	local device = Kit:Device(canvas, {model = 'VL-1', title = 'Mix', width = MIXER_W, height = MIXER_H, radius = 14})
	A.mixer = device
	A.master = Kit:Knob(device, {size = 62, min = 0, max = 100, step = 5, sweep = 270, label = 'Master', format = Percent,
		onChange = function(value) SetVolume('Sound_MasterVolume', value) end})
	A.master:SetPoint('TOP', 0, -26)
	A.knobs = {}
	for index, channel in ipairs(CHANNELS) do
		local knob = Kit:Knob(device, {size = 28, min = 0, max = 100, step = 5, sweep = 270, label = channel[2], format = Percent,
			onChange = function(value) SetVolume(channel[1], value) end})
		knob.cvar = channel[1]
		local column, row = (index - 1) % 2, floor((index - 1) / 2)
		knob:SetPoint('TOP', device, 'TOP', column == 0 and -36 or 36, -146 - row * 86)
		knob.label:SetWidth(70)
		knob.label:SetWordWrap(false)
		A.knobs[index] = knob
	end
	A.mute = Kit:Key(device, {width = MIXER_W - 32, height = 26, text = 'Mute', toggle = true, tone = 'dark', led = true,
		onClick = function(key) pcall(SetCVar, 'Sound_EnableAllSound', key.checked and '0' or '1') end})
	A.mute:SetPoint('BOTTOM', 0, 12)
	return device
end

local function BuildScreen()
	local screen = CreateFrame('Frame', 'JiberishSpec01AwayScreen', WorldFrame)
	screen:SetFrameStrata('FULLSCREEN')
	screen:SetAllPoints(UIParent)
	screen:EnableMouse(true)
	screen:EnableKeyboard(false)
	screen:Hide()
	A.screen = screen

	-- The world stays in view, dimmed: darker at the foot and behind the housings.
	local veil = CreateFrame('Frame', nil, screen)
	veil:SetAllPoints()
	A.veil = veil
	local base = veil:CreateTexture(nil, 'BACKGROUND', nil, 0)
	base:SetAllPoints()
	base:SetColorTexture(0, 0, 0, 0.36)
	local foot = veil:CreateTexture(nil, 'BACKGROUND', nil, 1)
	foot:SetColorTexture(1, 1, 1, 1)
	foot:SetPoint('TOPLEFT', veil, 'LEFT')
	foot:SetPoint('BOTTOMRIGHT')
	foot:SetGradient('VERTICAL', CreateColor(0, 0, 0, 0.5), CreateColor(0, 0, 0, 0))
	local side = veil:CreateTexture(nil, 'BACKGROUND', nil, 1)
	side:SetColorTexture(1, 1, 1, 1)
	side:SetPoint('TOPLEFT')
	side:SetPoint('BOTTOMRIGHT', veil, 'BOTTOM')
	side:SetGradient('HORIZONTAL', CreateColor(0, 0, 0, 0.42), CreateColor(0, 0, 0, 0))

	local canvas = CreateFrame('Frame', nil, screen)
	canvas:SetSize(CANVAS_W, CANVAS_H)
	canvas:SetFrameLevel(veil:GetFrameLevel() + 2)
	Anchor(canvas, 'CENTER', screen, 'CENTER', 0, 0)
	A.canvas = canvas
	-- The camera flash after a screenshot, over everything.
	local top = CreateFrame('Frame', nil, screen)
	top:SetAllPoints()
	top:SetFrameLevel(canvas:GetFrameLevel() + 40)
	top:EnableMouse(false)
	A.flash = top:CreateTexture(nil, 'OVERLAY')
	A.flash:SetAllPoints()
	A.flash:SetColorTexture(1, 1, 1, 1)
	A.flash:Hide()

	-- Housings on the left, the stage in the middle, the mixer on the right.
	local column = MAIN_H + 16 + CONSOLE_H
	local y = -floor((CANVAS_H - column) / 2)
	Anchor(BuildMain(canvas), 'TOPLEFT', canvas, 'TOPLEFT', 0, y)
	Anchor(BuildConsole(canvas), 'TOPLEFT', canvas, 'TOPLEFT', 0, y - MAIN_H - 16)
	Anchor(BuildMixer(canvas), 'RIGHT', canvas, 'RIGHT', 0, 0)
	local gap = floor((CANVAS_W - MAIN_W - MIXER_W - STAGE_W) / 2)
	Anchor(BuildStage(canvas), 'TOPLEFT', canvas, 'TOPLEFT', MAIN_W + gap, 0)
end

-- Layout ----------------------------------------------------------------------------------
-- The screen follows the UI scale (it hangs off WorldFrame, so it stays up
-- while the interface is hidden); the console shrinks to fit the screen.
-- Hairlines, lamps and rules are whole physical pixels.
local function LayoutLog()
	local measureTime, measureKind = A.measureTime, A.measureKind
	measureTime:SetText('00:00')
	local timeWidth = floor((measureTime:GetStringWidth() or 28) + 2.5)
	local kindWidth = 0
	for _, kind in pairs(KINDS) do
		measureKind:SetText(strupper(kind[1]))
		kindWidth = max(kindWidth, measureKind:GetStringWidth() or 0)
	end
	kindWidth = floor(kindWidth + 10.5)
	for _, row in ipairs(Log.rows) do
		row.time:SetWidth(timeWidth)
		row.lamp:ClearAllPoints()
		row.lamp:SetPoint('LEFT', row, 'LEFT', timeWidth + 6, 0)
		row.kind:ClearAllPoints()
		row.kind:SetPoint('LEFT', row, 'LEFT', timeWidth + 16, 0)
		row.kind:SetWidth(kindWidth - 4)
		row.body:SetPoint('LEFT', row, 'LEFT', timeWidth + 16 + kindWidth, 0)
	end
end

local function LayoutCells()
	local shown = {}
	for _, lcd in ipairs(A.cellOrder) do
		if lcd:IsShown() then shown[#shown + 1] = lcd end
	end
	local gap, width = 8, MAIN_W - 32
	local each = (width - gap * (#shown - 1)) / #shown
	for index, lcd in ipairs(shown) do
		lcd:ClearAllPoints()
		lcd:SetPoint('TOPLEFT', A.main, 'TOPLEFT', 16 + (index - 1) * (each + gap), -134)
		lcd:SetWidth(each)
	end
	-- The stats strip along the console's foot.
	local cells = A.statOrder
	local stripGap, stripWidth = 10, MAIN_W - 24
	local cellWidth = (stripWidth - stripGap * (#cells - 1)) / #cells
	for index, cell in ipairs(cells) do
		cell:ClearAllPoints()
		cell:SetPoint('BOTTOMLEFT', A.console, 'BOTTOMLEFT', 12 + (index - 1) * (cellWidth + stripGap), 12)
		cell:SetWidth(cellWidth)
		cell.legend:SetWidth(0)
		local legendWidth = min((cell.legend:GetStringWidth() or 30) + 1, cellWidth * 0.55)
		cell.legend:SetWidth(legendWidth)
		cell.lcd:SetWidth(max(cellWidth - legendWidth - 16, 24))
	end
end

local function Layout()
	local screen, canvas, stage = A.screen, A.canvas, A.stage
	local world, ui = WorldFrame:GetEffectiveScale(), UIParent:GetEffectiveScale()
	if IsSecret(world) or IsSecret(ui) or not world or world <= 0 or not ui or ui <= 0 then world, ui = 1, 1 end
	local refit = false
	local scale = max(0.05, ui / world)
	if A.screenScale ~= scale then
		A.screenScale = scale
		screen:SetScale(scale)
		refit = true
	end
	local width, height = UIParent:GetSize()
	local fit = 1
	if not (IsSecret(width) or IsSecret(height)) and width and height and width > 0 and height > 0 then
		fit = min(1, (width - 48) / CANVAS_W, (height - 48) / CANVAS_H)
	end
	fit = max(0.45, fit)
	if A.fit ~= fit then
		A.fit = fit
		canvas:SetScale(fit)
		refit = true
	end
	if refit then Kit:RefitShells() end
	-- Corner marks: 2 px strokes, 24 units long.
	local stroke, arm = Px(stage, 2), Snap(stage, 24)
	for _, mark in ipairs(A.over.marks) do
		if mark.across then mark:SetSize(arm, stroke) else mark:SetSize(stroke, arm) end
	end
	A.over.scan:SetHeight(Px(stage, 1))
	A.over.power:SetHeight(Px(stage, 2))
	for _, rule in ipairs(A.rules) do rule:SetHeight(Px(rule:GetParent(), 1)) end
	LayoutLog()
	LayoutCells()
	FitIdentity()
	for lcd in pairs(Digits.all) do Digits.Layout(lcd) end
	PlaceRested()
end

-- Showing and hiding ------------------------------------------------------------------------
local function PaintBadge()
	local main = A.main
	main.badge:SetBadge(S.preview and 'Preview' or 'Away', S.preview and 'blue' or 'amber')
	main.title:SetText(S.preview and 'PREVIEW' or 'STANDBY')
end

-- Idle motion: the stage's scan line, the floor ring breathing, the live lamp.
local function StartIdle()
	local stage, over = A.stage, A.over
	Kit:Loop(Tag('awayScan', stage), stage, function(t)
		local height = stage:GetHeight()
		if IsSecret(height) or not height or height <= 0 then return end
		local f = (t % 5.5) / 5.5
		local y = 30 + (height - 60) * f
		over.scan:ClearAllPoints()
		over.scan:SetPoint('BOTTOMLEFT', over, 'BOTTOMLEFT', 14, y)
		over.scan:SetPoint('BOTTOMRIGHT', over, 'BOTTOMRIGHT', -14, y)
		local fade = min(1, f * 6, (1 - f) * 6)
		over.scan:SetAlpha(0.45 * fade)
		over.trail:SetAlpha(fade)
		over.scan:Show()
		over.trail:Show()
	end, function()
		over.scan:Hide()
		over.trail:Hide()
	end)
	Kit:Breathe(stage.ringInner, true, {period = 3.2, low = 0.45})
end

-- The trail under the scan line is a gradient in the lamp colour.
local function PaintTrail()
	local r, g, b = Kit:RGB('lamp')
	A.over.trail:SetGradient('VERTICAL', CreateColor(r, g, b, 0), CreateColor(r, g, b, 0.16))
	local light = 0.299 * r + 0.587 * g + 0.114 * b
	A.over.power:SetVertexColor(min(1, r + 0.5), min(1, g + 0.5), min(1, b + 0.5), light > 0.8 and 0.5 or 0.7)
end

local FLICKER = {0, 0.6, 0.1, 0.85, 0.35, 1}
local function PowerOn()
	A.veil:SetAlpha(0)
	Kit:Animate(Tag('awayVeil', A.veil), 0.5, 0, 1, function(alpha) A.veil:SetAlpha(alpha) end, nil, 'sine')
	Slide(A.main, -28, 0, 0.06, 0.36)
	Slide(A.console, -28, 0, 0.14, 0.36)
	Slide(A.mixer, 28, 0, 0.1, 0.36)
	Slide(A.stage, 0, -10, 0.12, 0.44)
	-- The figure flickers on behind a bright line running down the stage.
	local model, over, stage = A.model, A.over, A.stage
	model:SetAlpha(0)
	Kit:Animate(Tag('awayModel', model), 0.75, 0, 1, function(_, progress)
		local t = progress * 0.75
		if t < 0.25 then model:SetAlpha(0) return end
		local f = (t - 0.25) / 0.5
		model:SetAlpha(FLICKER[min(#FLICKER, floor(f * #FLICKER) + 1)])
		local height = stage:GetHeight() or 0
		over.power:ClearAllPoints()
		over.power:SetPoint('TOPLEFT', over, 'TOPLEFT', 8, -height * f)
		over.power:SetPoint('TOPRIGHT', over, 'TOPRIGHT', -8, -height * f)
		over.power:SetAlpha(1 - f)
		over.power:Show()
	end, function()
		model:SetAlpha(1)
		over.power:Hide()
	end, 'linear')
	-- Lamps blink on in turn; the away lamp and the live lamp keep breathing.
	LampOn(A.main.lamp, 'amber', 0.32, true)
	LampOn(A.away.lamp, 'amber', 0.42, true)
	LampOn(A.console.lamp, 'green', 0.4)
	LampOn(A.mixer.lamp, nil, 0.46)
	LampOn(over.liveLamp, 'red', 0.55, true)
	-- The readouts print in.
	Digits.Reveal(A.away, 0.4)
	PrintIn(A.name, 0.22)
	PrintIn(A.guild, 0.3)
	PrintIn(A.level, 0.34)
	PrintIn(A.class, 0.38)
	PrintIn(A.zone, 0.42)
	for index, lcd in ipairs(A.cellOrder) do PrintIn(lcd.digits, 0.45 + index * 0.05) end
	PrintIn(A.xpText, 0.6)
	Sound('power-up', 0.04)
	Sound('relay', 0.42)
end

local logEvents = CreateFrame('Frame')
local LOG_EVENTS = {'PLAYER_MONEY', 'PLAYER_XP_UPDATE', 'PLAYER_LEVEL_UP', 'UPDATE_PENDING_MAIL', 'CHAT_MSG_LOOT', 'READY_CHECK',
	'LFG_PROPOSAL_SHOW', 'ZONE_CHANGED', 'ZONE_CHANGED_INDOORS', 'ZONE_CHANGED_NEW_AREA', 'CVAR_UPDATE', 'SCREENSHOT_SUCCEEDED',
	'SCREENSHOT_FAILED', 'UPDATE_INVENTORY_DURABILITY', 'PLAYER_GUILD_UPDATE', 'UPDATE_EXHAUSTION'}

local function Tick()
	if not Shown() then return end
	A.tick = A.tick + 1
	-- The colons blink once a second, unless motion is reduced.
	A.away.colon = Kit:Reduced() or A.tick % 2 == 0
	local seconds = floor(GetTime() - S.since)
	Digits.Set(A.away, format('%02d:%02d:%02d', floor(seconds / 3600), floor(seconds / 60) % 60, seconds % 60))
	Digits.Paint(A.away)
	if A.tick % 2 == 0 then
		UpdateCells()
		UpdateStats(A.tick % 20 == 0)
	end
end

local function StartSession()
	S.since = GetTime()
	A.tick = 0
	A.turn, A.hold, A.zoom, A.drag, A.dancing = A.turn or 0.4, nil, 1, nil, false
	PaintBadge()
	FillIdentity()
	Layout()
	UpdateXP()
	A.away.colon = true
	Digits.Set(A.away, '00:00:00')
	UpdateCells()
	UpdateStats(true)
	SyncVolume()
	PaintKeys()
	PaintTrail()
	for _, name in ipairs(LOG_EVENTS) do pcall(logEvents.RegisterEvent, logEvents, name) end
	for name in pairs(CHAT) do pcall(logEvents.RegisterEvent, logEvents, name) end
	pcall(logEvents.RegisterUnitEvent, logEvents, 'UNIT_MODEL_CHANGED', 'player')
	Log.Start()
	if A.ticker then A.ticker:Cancel() end
	A.ticker = C_Timer.NewTicker(0.5, Tick)
	AskPlayed()
end

local function StopSession()
	if A.ticker then A.ticker:Cancel(); A.ticker = nil end
	logEvents:UnregisterAllEvents()
	A.shooting = nil
	if A.shotTimer then A.shotTimer:Cancel(); A.shotTimer = nil end
	if S.spinning then
		if MoveViewLeftStop then MoveViewLeftStop() end
		S.spinning = nil
	end
	-- Showing UIParent is allowed until lockdown starts, which comes after
	-- PLAYER_REGEN_DISABLED; later than that it waits for combat to end.
	if S.uiHidden then
		S.uiHidden = nil
		if InCombatLockdown() then UI:AfterCombat(function() UIParent:Show() end, 'qol.afk') else UIParent:Show() end
	end
	Kit:Breathe(A.console.lamp, false)
end

function module:ShowAFK(preview)
	if InCombatLockdown() then return end
	if not preview and not DB().afk then return end
	if not A.screen then BuildScreen() end
	local screen = A.screen
	if screen:IsShown() and not A.closing then
		-- Already up: a preview that turns into the real thing just says so.
		if not preview and S.preview then
			S.preview = false
			PaintBadge()
			Log.Add('sys', format('Away since %s.', date('%H:%M')))
		end
		return
	end
	-- Coming back mid power-off: cancel it.
	Kit:Animate(Tag('awayScreen', screen), 0, 0, 1, function() end)
	A.closing = nil
	screen:SetAlpha(1)
	Place(A.canvas, 0, 0)
	S.preview = preview and true or false
	if DB().afkHideUI and UIParent:IsShown() then
		UIParent:Hide()
		S.uiHidden = true
	end
	screen:Show()
	StartSession()
	SyncSpin()
	StartIdle()
	RefreshModel()
	A.model:SetScript('OnUpdate', TurnModel)
	PowerOn()
end

-- instant: no power-off fade (a loading screen or a cinematic is coming).
function module:HideAFK(instant)
	local screen = A.screen
	if not (screen and screen:IsShown()) or A.closing then return end
	A.closing = true
	StopSession()
	A.model:SetScript('OnUpdate', nil)
	if not instant then Sound('power-down', 0.04) end
	Kit:Animate(Tag('awayScreen', screen), instant and 0 or 0.34, 0, 1, function(_, progress)
		screen:SetAlpha(1 - Kit.ease.inout(progress))
		Place(A.canvas, 0, -10 * Kit.ease.cubic(progress))
	end, function()
		screen:Hide()
		screen:SetAlpha(1)
		Place(A.canvas, 0, 0)
		A.closing = nil
	end, 'linear')
end

function UI:PreviewAway()
	if InCombatLockdown() then return UI:Print('The away screen waits until the fight is over.') end
	S.dismissed = nil
	module:ShowAFK(true)
end

local function CheckAFK()
	local away = Plain(UnitIsAFK, 'player')
	if away then
		if not S.dismissed then module:ShowAFK() end
	else
		S.dismissed = nil
		if not S.preview then module:HideAFK() end
	end
end

-- Events ------------------------------------------------------------------------------------
logEvents:SetScript('OnEvent', function(_, event, ...)
	if not Shown() then return end
	local kind = CHAT[event]
	if kind then
		local text, sender = ...
		local guid = select(12, ...)
		if not (kind == 'whisper' or kind == 'bnet') and not DB().afkChat then return end
		if Mine(guid) then return end
		Log.Add(kind, nil, '%s: %s', Speaker(sender, kind), text)
	elseif event == 'PLAYER_MONEY' then
		local now = Plain(GetMoney)
		if now and Log.money and now ~= Log.money then
			local delta = now - Log.money
			Log.Add('money', (delta > 0 and '+' or '-')..Coins(abs(delta)))
		end
		Log.money = now or Log.money
		UpdateCells()
	elseif event == 'PLAYER_XP_UPDATE' or event == 'UPDATE_EXHAUSTION' then
		local current, total = Plain(UnitXP, 'player'), Plain(UnitXPMax, 'player')
		if event == 'PLAYER_XP_UPDATE' and current and Log.xp then
			local gained = current - Log.xp
			-- Across a level the old level's remainder counts too.
			if gained < 0 and Log.xpMax then gained = Log.xpMax - Log.xp + current end
			if gained > 0 then Log.XP(gained) end
		end
		Log.xp, Log.xpMax = current or Log.xp, total or Log.xpMax
		UpdateXP()
	elseif event == 'PLAYER_LEVEL_UP' then
		local level = ...
		if IsSecret(level) then Log.Add('level', nil, 'Level %s reached', level)
		elseif type(level) == 'number' then Log.Add('level', format('Level %d reached', level)) end
		FillIdentity()
		UpdateXP()
	elseif event == 'UPDATE_PENDING_MAIL' then
		local has = Plain(HasNewMail)
		if has and not Log.mail then Log.Add('mail', 'New mail arrived') end
		Log.mail = has
	elseif event == 'CHAT_MSG_LOOT' then
		-- Only our own loot; a line the client won't say whose it is goes in too.
		local text = ...
		local guid = select(12, ...)
		if IsSecret(guid) or guid == nil or Mine(guid) then Log.Add('loot', nil, '%s', text) end
	elseif event == 'READY_CHECK' then
		local initiator = ...
		Log.Add('alert', nil, 'Ready check from %s', initiator)
	elseif event == 'LFG_PROPOSAL_SHOW' then
		Log.Add('alert', 'Your group is ready: accept in time')
	elseif event == 'ZONE_CHANGED' or event == 'ZONE_CHANGED_INDOORS' or event == 'ZONE_CHANGED_NEW_AREA' then
		FillZone()
	elseif event == 'PLAYER_GUILD_UPDATE' then
		FillIdentity()
	elseif event == 'CVAR_UPDATE' then
		SyncVolume()
		PaintKeys()
	elseif event == 'SCREENSHOT_SUCCEEDED' or event == 'SCREENSHOT_FAILED' then
		C_Timer.After(0.05, RestoreShot)
	elseif event == 'UPDATE_INVENTORY_DURABILITY' then
		UpdateCells()
	elseif event == 'UNIT_MODEL_CHANGED' then
		local unit = ...
		if not IsSecret(unit) and unit == 'player' then RefreshModel() end
	end
end)

local events = CreateFrame('Frame')
local WATCH = {'PLAYER_FLAGS_CHANGED', 'PLAYER_REGEN_DISABLED', 'CINEMATIC_START', 'PLAY_MOVIE', 'PLAYER_LEAVING_WORLD',
	'PLAYER_STARTED_MOVING', 'TIME_PLAYED_MSG'}
for _, name in ipairs(WATCH) do pcall(events.RegisterEvent, events, name) end
events:SetScript('OnEvent', function(_, event, ...)
	if event == 'TIME_PLAYED_MSG' then
		local total, level = ...
		if not IsSecret(total) and type(total) == 'number' then
			played.total, played.at = total, GetTime()
			played.level = not IsSecret(level) and level or nil
		end
		C_Timer.After(0, function() Quiet(false) end)
		return
	end
	if not module.ready then return end
	if event == 'PLAYER_FLAGS_CHANGED' then
		local unit = ...
		if IsSecret(unit) or unit ~= 'player' then return end
		UI:Safe(CheckAFK)
	elseif event == 'PLAYER_STARTED_MOVING' then
		-- A step always puts it away, in a preview too.
		if Shown() then Dismiss() end
	elseif event == 'PLAYER_REGEN_DISABLED' then
		-- A fight always takes the away screen down, at once.
		module:HideAFK(true)
	else
		-- A cinematic or a loading screen does too.
		module:HideAFK(true)
	end
end)

-- A theme, finish or font change repaints and re-measures the screen.
Kit:OnRefresh(function()
	for lcd in pairs(Digits.all) do Digits.Layout(lcd) end
	if not Shown() then return end
	PaintClass()
	PaintTrail()
	Layout()
end)

-- Module -------------------------------------------------------------------------------------
function module:Enable()
	-- Esc with the interface hidden shows it again (the game's own Esc
	-- handling): that also puts the away screen away. With the interface up,
	-- Esc opens the game menu, which does the same.
	UIParent:HookScript('OnShow', function()
		if S.uiHidden and Shown() then
			S.uiHidden = nil
			Dismiss()
		end
	end)
	if GameMenuFrame and GameMenuFrame.HookScript then
		GameMenuFrame:HookScript('OnShow', function() if Shown() then Dismiss() end end)
	end
	-- The UI scale or the window changed: lay out again and redraw the figure.
	UI.Pixel.OnChange(function()
		if not Shown() then return end
		Layout()
		RefreshModel()
	end)
	self.ready = true
	C_Timer.After(1, function() UI:Safe(CheckAFK) end)
end

function module:Refresh()
	if not Shown() then return end
	if not DB().afk and not S.preview then return self:HideAFK() end
	SyncSpin()
	PaintKeys()
end

-- Hub ----------------------------------------------------------------------------------------
UI:RegisterPage('away', {title = 'Away screen', order = 22.5, since = '0.5.2', cards = {
	{title = 'Away screen', rows = {
		{'switch', 'Away screen', 'qol.afk', 'A SPEC-01 standby console while you are away: your character on an open stage, the time away, a log of what happened, volume knobs and function keys.'},
		{'switch', 'Hide the interface', 'qol.afkHideUI', 'Only the away screen shows while you are away. It never hides anything in combat.'},
		{'switch', 'Turn the camera', 'qol.afkSpin', 'The game camera circles slowly around you (the Spin key does the same).'},
		{'switch', 'Turn the figure', 'qol.afkTurn', 'Your character turns slowly on its stage. Drag it to turn it yourself. Off with Reduce motion.', since = '0.5.2'},
		{'button', 'Preview', 'Show', function() UI:PreviewAway() end, 'Back, Esc or a step puts it away. Also /spec afk.', since = '0.5.2'},
	}},
	{title = 'Console', rows = {
		{'switch', 'Event log', 'qol.afkLog', 'The console logs whispers, mail, levels and experience, loot, money, ready checks and queues while you are away.', since = '0.5.2'},
		{'switch', 'Guild and group chat', 'qol.afkChat', 'Guild, officer, party, raid and instance chat in the log too.', since = '0.5.2',
			disabled = function() return not DB().afkLog end},
		{'switch', 'Console sounds', 'qol.afkBlips', 'A blip for a whisper or mail, a chime for a level, a warning for a ready check or a queue.', since = '0.5.2'},
		{'switch', 'Time played', 'qol.afkPlayed', 'Asks the game for your time played once, quietly: nothing is printed in chat.', since = '0.5.2'},
	}},
}})
