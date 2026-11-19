-- The console's deck: meters, the stats strip, function keys and header
-- panels. Part of the action bars (ActionBars.lua).
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown, GetTime = CreateFrame, UIParent, InCombatLockdown, GetTime
local floor, max, min = math.floor, math.max, math.min
local format, ipairs, pairs, pcall, tonumber = format, ipairs, pairs, pcall, tonumber
local P = UI.ActionBarParts
local Forbidden, IsSecret = UI.Util.Forbidden, UI.Util.IsSecret
local ApplyLock, BuildXP, ColorOf, DB, Deck, HW = P.ApplyLock, P.BuildXP, P.ColorOf, P.DB, P.Deck, P.HW
local LightCap, Readout, ROW_GAP, Smooth, Sound, Sprites = P.LightCap, P.Readout, P.ROW_GAP, P.Smooth, P.Sound, P.Sprites
local Surface, XPHeight = P.Surface, P.XPHeight

;(function()
local GetMoney, GetXPExhaustion, UnitXP, UnitXPMax, UnitLevel = GetMoney, GetXPExhaustion, UnitXP, UnitXPMax, UnitLevel
local ceil = math.ceil

local Plain = UI.Util.PlainValue
local function Call(func, ...)
	if type(func) ~= 'function' then return nil end
	local ok, a, b, c, d, e = pcall(func, ...)
	if not ok then return nil end
	return Plain(a), Plain(b), Plain(c), Plain(d), Plain(e)
end

-- Formatting ------------------------------------------------------------------------------
local function Short(value)
	if not value then return '--' end
	if value >= 1e6 then return format('%.1fM', value / 1e6) end
	if value >= 1e4 then return format('%.0fK', value / 1e3) end
	if value >= 1e3 then return format('%.1fK', value / 1e3) end
	return format('%d', value)
end

local function Duration(seconds)
	if not seconds or seconds ~= seconds or seconds == math.huge or seconds < 0 then return '--' end
	seconds = floor(seconds)
	if seconds >= 86400 then return format('%dD %02dH', floor(seconds / 86400), floor(seconds % 86400 / 3600)) end
	if seconds >= 3600 then return format('%dH %02dM', floor(seconds / 3600), floor(seconds % 3600 / 60)) end
	if seconds >= 60 then return format('%dM %02dS', floor(seconds / 60), seconds % 60) end
	return format('%dS', seconds)
end

local function Gold(copper)
	if not copper then return '--' end
	local sign = copper < 0 and '-' or ''
	copper = math.abs(copper)
	local gold = floor(copper / 10000)
	if gold >= 1e6 then return format('%s%.1fMG', sign, gold / 1e6) end
	if gold >= 1e4 then return format('%s%.0fKG', sign, gold / 1e3) end
	if gold > 0 then return format('%s%dG', sign, gold) end
	return format('%s%dS', sign, floor(copper / 100))
end

-- Session numbers ---------------------------------------------------------------------------
local session = {start = GetTime(), xp = 0, questXP = 0, kills = 0}
local last = {}
local played = {}
local questUntil = 0

local function Level()
	local level = Plain(UnitLevel('player'))
	local cap = Call(GetMaxLevelForPlayerExpansion) or Plain(MAX_PLAYER_LEVEL) or level
	return level, cap
end

local function XP()
	local current, total = Plain(UnitXP('player')), Plain(UnitXPMax('player'))
	local disabled = Call(IsXPUserDisabled)
	local level, cap = Level()
	if not (current and total and level and cap) or total <= 0 then return nil end
	if level >= cap or disabled then return nil end
	return current, total, level
end

local function TrackXP()
	local current, total = Plain(UnitXP('player')), Plain(UnitXPMax('player'))
	local level = Plain(UnitLevel('player'))
	if not (current and total and level) then return end
	if last.xp and last.level then
		local gained
		if level == last.level then gained = current - last.xp
		elseif level > last.level then
			gained = (last.max - last.xp) + current
			-- A new level: its played time starts now.
			played.level, played.at = 0, GetTime()
		end
		if gained and gained > 0 then session.xp = session.xp + gained end
	end
	last.xp, last.max, last.level = current, total, level
end

local function Hours() return max((GetTime() - session.start) / 3600, 1 / 3600) end
local function Rate() return session.xp > 0 and session.xp / Hours() or nil end
local function Remaining()
	local current, total = XP()
	return current and (total - current) or nil
end
local function KillXP()
	local other = session.xp - session.questXP
	if session.kills <= 0 or other <= 0 then return nil end
	return other / session.kills
end

-- Time played: asked once, quietly. The chat frames are taken off the answer
-- while our request is out, so it prints nowhere; they get it back right after.
local quieted = {}
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
	if played.asked or not RequestTimePlayed then return end
	played.asked = true
	Quiet(true)
	pcall(RequestTimePlayed)
	-- Never hold the chat frames for long, answered or not.
	C_Timer.After(5, function() Quiet(false) end)
end

local function Played()
	if not played.total then return nil, nil end
	local since = GetTime() - played.at
	return played.total + since, played.level + since
end

-- Reputation and honor ------------------------------------------------------------------------
local function Reputation()
	local name, low, high, value, reaction, factionID
	local data = C_Reputation and C_Reputation.GetWatchedFactionData and Call(C_Reputation.GetWatchedFactionData)
	if type(data) == 'table' then
		name, reaction, factionID = Plain(data.name), Plain(data.reaction), Plain(data.factionID)
		low, high, value = Plain(data.currentReactionThreshold), Plain(data.nextReactionThreshold), Plain(data.currentStanding)
	elseif GetWatchedFactionInfo then
		name, reaction, low, high, value = Call(GetWatchedFactionInfo)
	end
	if not (name and low and high and value) then return nil end
	local standing = reaction and _G['FACTION_STANDING_LABEL'..reaction]
	-- Renown factions read their renown level and progress to the next one.
	if factionID and C_Reputation.IsMajorFaction and Call(C_Reputation.IsMajorFaction, factionID) and C_MajorFactions then
		local major = Call(C_MajorFactions.GetMajorFactionData, factionID)
		if type(major) == 'table' and Plain(major.renownLevelThreshold) and Plain(major.renownReputationEarned) then
			return {name = name, value = major.renownReputationEarned, max = max(major.renownLevelThreshold, 1),
				standing = format('Renown %d', Plain(major.renownLevel) or 0)}
		end
	end
	return {name = name, value = min(max(value - low, 0), max(high - low, 1)), max = max(high - low, 1),
		standing = type(standing) == 'string' and standing or ''}
end

local function Honor()
	if not (UnitHonor and UnitHonorMax) then return nil end
	local value, total, level = Call(UnitHonor, 'player'), Call(UnitHonorMax, 'player'), Call(UnitHonorLevel, 'player')
	if not (value and total) or total <= 0 then return nil end
	return {value = value, max = total, level = level}
end

-- The XP of quests in the log that are ready to hand in.
local function QuestPreview()
	if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and GetQuestLogRewardXP) then return 0 end
	local total = 0
	local count = Call(C_QuestLog.GetNumQuestLogEntries) or 0
	for index = 1, count do
		local info = Call(C_QuestLog.GetInfo, index)
		local id = type(info) == 'table' and not info.isHeader and Plain(info.questID)
		if id and Call(C_QuestLog.ReadyForTurnIn, id) then total = total + (Call(GetQuestLogRewardXP, id) or 0) end
	end
	return total
end

-- Stats readouts ------------------------------------------------------------------------------
-- Each: a printed label and a reader returning the LCD text and, when it has
-- something to say, the lamp's color.
local STATS = {
	level = {'Level', function()
		local current, total, level = XP()
		if current then return format('%d  %.1f%%', level, current / total * 100), 'lamp' end
		local plain = Level()
		return plain and format('%d  MAX', plain) or '--'
	end},
	xph = {'XP/hr', function()
		if not XP() then return 'MAX' end
		local rate = Rate()
		return rate and Short(rate) or '--', rate and 'green' or nil
	end},
	ttl = {'To level', function()
		local left, rate = Remaining(), Rate()
		if not left then return 'MAX' end
		return rate and Duration(left / rate * 3600) or '--', rate and 'lamp' or nil
	end},
	left = {'XP left', function()
		local left = Remaining()
		return left and Short(left) or 'MAX'
	end},
	kills = {'Kills to lv', function()
		local left, each = Remaining(), KillXP()
		if not left then return 'MAX' end
		return each and format('%d', ceil(left / each)) or '--', each and 'amber' or nil
	end},
	rested = {'Rested', function()
		local current, total = XP()
		local rested = Plain(Call(GetXPExhaustion))
		if not (current and rested) or rested <= 0 then return '0%' end
		return format('%d%%', floor(rested / total * 100 + 0.5)), 'blue'
	end},
	quests = {'Quest XP', function()
		if session.xp <= 0 then return '--' end
		return format('%d%%', floor(session.questXP / session.xp * 100 + 0.5)), 'green'
	end},
	played = {'Played', function()
		local total = Played()
		return Duration(total)
	end},
	levelTime = {'This level', function()
		local _, level = Played()
		return Duration(level)
	end},
	session = {'Session', function() return Duration(GetTime() - session.start), 'green' end},
	goldph = {'Gold/hr', function()
		local now = Plain(GetMoney())
		if not (now and session.money) then return '--' end
		local gained = now - session.money
		return Gold(gained / Hours()), gained > 0 and 'amber' or nil
	end},
	gold = {'Gold', function() return Gold(Plain(GetMoney())) end},
	rep = {'Rep', function()
		local rep = Reputation()
		if not rep then return '--' end
		return format('%s %d%%', strupper(strsub(rep.standing, 1, 8)), floor(rep.value / rep.max * 100)), 'green'
	end},
	honor = {'Honor', function()
		local honor = Honor()
		if not honor then return '--' end
		return format('%s %d%%', honor.level and tostring(honor.level) or '', floor(honor.value / honor.max * 100)), 'red'
	end},
	fps = {'FPS', function() return format('%d', floor((Call(GetFramerate) or 0) + 0.5)) end},
	clock = {'Clock', function() return date('%H:%M') end},
}
Deck.STAT_ITEMS = {{'none', 'None'}, {'xph', 'XP per hour'}, {'ttl', 'Time to level'}, {'left', 'XP left'},
	{'kills', 'Kills to level'}, {'rested', 'Rested XP'}, {'level', 'Level and %'}, {'quests', 'Quest share of XP'},
	{'levelTime', 'Played this level'}, {'played', 'Played in total'}, {'session', 'Session time'},
	{'goldph', 'Gold per hour'}, {'gold', 'Gold'}, {'rep', 'Reputation'}, {'honor', 'Honor'}, {'fps', 'Frame rate'},
	{'clock', 'Clock'}}
local STAT_SLOTS = 6

local function StatsWanted()
	local db = DB()
	if db.stats == false or db.statsStyle == 'hidden' then return false end
	for index = 1, STAT_SLOTS do
		local id = db['stat'..index]
		if id and STATS[id] then return true end
	end
	return false
end

-- Meters ------------------------------------------------------------------------------------
local SOURCES = {'auto', 'xp', 'rep', 'honor'}
Deck.SOURCE_ITEMS = {{'auto', 'Auto'}, {'xp', 'Experience'}, {'rep', 'Reputation'}, {'honor', 'Honor'}}
local DEFAULT_COLOR = {xp = 'lamp', rested = 'blue', rep = 'green', honor = 'red', preview = 'amber'}

local function MeterRGB(kind)
	local db = DB()
	if db.meterColors == 'custom' then
		local value = db[kind..'Color']
		if type(value) == 'table' then return ColorOf(value, 1, 1, 1) end
	end
	return Kit:RGB(DEFAULT_COLOR[kind] or 'lamp')
end

-- What a meter shows: the source asked for, resolved.
local function Resolve(source)
	if source == 'auto' or not source then
		if XP() then return 'xp' end
		if Reputation() then return 'rep' end
		if Honor() then return 'honor' end
		return 'xp'
	end
	return source
end

-- A meter's reading: value, max, legend, LCD text, color kind, tooltip lines,
-- rested and preview amounts (XP only).
local function Read(source)
	source = Resolve(source)
	if source == 'xp' then
		local current, total, level = XP()
		if not current then
			local plain = Level()
			return {value = 1, max = 1, legend = 'XP', text = 'MAX', kind = 'xp', dim = true,
				tip = {plain and format('Level %d (max)', plain) or 'Level max'}}
		end
		local rested = Plain(Call(GetXPExhaustion)) or 0
		local reading = {value = current, max = total, legend = 'XP', text = format('%4.1f%%', current / total * 100),
			kind = 'xp', rested = rested, level = level}
		reading.tip = {format('Level %d  %s / %s  (%.1f%%)', level, Short(current), Short(total), current / total * 100),
			format('%s to level', Short(total - current))}
		if rested > 0 then reading.tip[#reading.tip + 1] = format('Rested %s (%d%% of the level)', Short(rested), floor(rested / total * 100)) end
		local rate = Rate()
		if rate then reading.tip[#reading.tip + 1] = format('%s XP per hour, level in %s', Short(rate), Duration((total - current) / rate * 3600)) end
		if DB().questPreview then
			reading.preview = QuestPreview()
			if reading.preview > 0 then reading.tip[#reading.tip + 1] = format('Quests ready to hand in: %s XP', Short(reading.preview)) end
		end
		return reading
	elseif source == 'rep' then
		local rep = Reputation()
		if not rep then return {value = 0, max = 1, legend = 'Rep', text = '--', kind = 'rep', dim = true, tip = {'No reputation watched'}} end
		return {value = rep.value, max = rep.max, legend = 'Rep', text = format('%4.1f%%', rep.value / rep.max * 100), kind = 'rep',
			tip = {rep.name, format('%s  %s / %s', rep.standing, Short(rep.value), Short(rep.max))}}
	else
		local honor = Honor()
		if not honor then return {value = 0, max = 1, legend = 'Hon', text = '--', kind = 'honor', dim = true, tip = {'No honor'}} end
		return {value = honor.value, max = honor.max, legend = 'Hon', text = format('%4.1f%%', honor.value / honor.max * 100),
			kind = 'honor', tip = {format('Honor level %s', honor.level or '?'), format('%s / %s', Short(honor.value), Short(honor.max))}}
	end
end
Deck.Read = Read

local function MeterHeight()
	return DB().barStyle == 'slim' and 3 or XPHeight()
end

-- A style on a meter's bar: dots (perforated), flat with a lit edge,
-- segments, or a slim hairline.
local function Style(meter)
	local style = DB().barStyle or 'dots'
	local bar = meter.bar
	local onDark = Surface() == 'dark'
	if style == 'dots' then
		Kit:Perforate(bar, onDark and 'glass' or 'track', onDark and 'darkEdge' or nil)
		bar:SetStatusBarTexture([[Interface\Buttons\WHITE8X8]])
	else
		if bar.kitCover then bar.kitPerforated = false; bar.kitCover:Hide(); bar.kitUnder:Hide() end
		bar:SetStatusBarTexture(Kit.media..'bar-flat.tga')
	end
	local fill = bar:GetStatusBarTexture()
	if not meter.edge then
		meter.edge = bar:CreateTexture(nil, 'OVERLAY', nil, 2)
		meter.edge:SetColorTexture(1, 1, 1, 0.9)
		meter.edge:SetBlendMode('ADD')
		meter.seams = {}
	end
	meter.edge:ClearAllPoints()
	meter.edge:SetWidth(UI.Pixel and UI.Pixel.Px(bar, 1) or 1)
	meter.edge:SetPoint('TOP', fill, 'TOPRIGHT', 0, 0)
	meter.edge:SetPoint('BOTTOM', fill, 'BOTTOMRIGHT', 0, 0)
	meter.edge:SetShown(style == 'flat' or style == 'slim')
	-- Segments: hairline seams in the track's color across the fill.
	local width = bar:GetWidth()
	local count = (style == 'segments' and not IsSecret(width) and width and width > 0) and floor(width / 7) or 0
	local tr, tg, tb = Kit:RGB(onDark and 'glass' or 'track')
	for index = 1, max(count, #meter.seams) do
		local seam = meter.seams[index]
		if index <= count then
			if not seam then
				seam = bar:CreateTexture(nil, 'OVERLAY', nil, 1)
				meter.seams[index] = seam
			end
			seam:SetColorTexture(tr, tg, tb, 1)
			seam:ClearAllPoints()
			seam:SetSize(1, 1)
			seam:SetPoint('TOP', bar, 'TOPLEFT', index * width / (count + 1), 0)
			seam:SetPoint('BOTTOM', bar, 'BOTTOMLEFT', index * width / (count + 1), 0)
			seam:Show()
		elseif seam then
			seam:Hide()
		end
	end
	meter.shell:SetAlpha(style == 'slim' and 0.6 or 1)
	-- Slim: the fill takes the whole hairline, and the percent is printed in the
	-- numbers face at the end, with no LCD box round it.
	bar:ClearAllPoints()
	if style == 'slim' then
		bar:SetPoint('TOPLEFT', 0, 0)
		bar:SetPoint('BOTTOMRIGHT', 0, 0)
	else
		bar:SetPoint('TOPLEFT', 3, -2)
		bar:SetPoint('BOTTOMRIGHT', -3, 2)
	end
	local lcd = meter.lcd
	if lcd then
		local boxed = style ~= 'slim'
		if lcd.shell then lcd.shell:SetShown(boxed) end
		if lcd.inner then lcd.inner:SetShown(boxed) end
		Kit:Font(meter.percent, 8, nil, true, not boxed and 'numbers' or nil)
		Kit:Tint(meter.percent, boxed and 'lcdInk' or (onDark and 'darkInk' or 'ink'))
	end
end

-- Overlays from the fill's end: rested XP, quests ready.
local function Overlay(meter, key, from, amount, kind, alpha)
	local texture = meter[key]
	if not texture then
		texture = meter.bar:CreateTexture(nil, 'BACKGROUND', nil, key == 'restedFill' and 3 or 4)
		texture:SetColorTexture(1, 1, 1, 1)
		meter[key] = texture
	end
	local width = meter.bar:GetWidth()
	if not amount or amount <= 0 or IsSecret(width) or not width or width <= 0 then texture:Hide() return from end
	local to = min(from + amount, 1)
	if to <= from then texture:Hide() return from end
	local r, g, b = MeterRGB(kind)
	texture:SetVertexColor(r, g, b, alpha)
	texture:ClearAllPoints()
	texture:SetPoint('TOPLEFT', meter.bar, 'TOPLEFT', width * from, 0)
	texture:SetPoint('BOTTOMLEFT', meter.bar, 'BOTTOMLEFT', width * from, 0)
	texture:SetWidth(max(width * (to - from), 1))
	texture:Show()
	return to
end

-- Paint one meter from its source.
local function Paint(meter, source)
	local reading = Read(source)
	meter.reading = reading
	local bar = meter.bar
	bar:SetMinMaxValues(0, reading.max)
	bar:SetValue(reading.value, Smooth())
	local r, g, b = MeterRGB(reading.kind)
	if reading.dim then r, g, b = Kit:RGB('dim') end
	bar:SetStatusBarColor(r, g, b, 1)
	if meter.edge then meter.edge:SetVertexColor(min(r + 0.4, 1), min(g + 0.4, 1), min(b + 0.4, 1), 1) end
	local at = reading.max > 0 and reading.value / reading.max or 0
	local db = DB()
	at = Overlay(meter, 'restedFill', at, db.restedOverlay ~= false and reading.rested and reading.rested / reading.max, 'rested', 0.45)
	Overlay(meter, 'previewFill', at, reading.preview and reading.preview / reading.max, 'preview', 0.55)
	meter.tip = reading.tip
	HW.MeterText(meter, reading.legend, reading.text)
	return reading
end

-- Clicks: left cycles the source, right opens reputations.
local function Clicked(meter, button)
	if button == 'RightButton' then
		if ToggleCharacter then pcall(ToggleCharacter, 'ReputationFrame') end
		return
	end
	local field = meter.second and 'barSecond' or 'barSource'
	local current = DB()[field] or 'auto'
	local nextSource = SOURCES[1]
	for index, id in ipairs(SOURCES) do
		if id == current then nextSource = SOURCES[index % #SOURCES + 1] break end
	end
	DB()[field] = nextSource
	Kit:Play('tick', true)
	Deck.UpdateMeters()
	if GameTooltip:IsOwned(meter) and meter:GetScript('OnEnter') then meter:GetScript('OnEnter')(meter) end
end

-- Dress a meter track (BuildXP's) with clicks, the tooltip and its style.
function Deck.DressMeter(meter, second)
	meter.second = second
	meter:SetScript('OnEnter', function(self)
		GameTooltip:SetOwner(self, 'ANCHOR_TOP')
		local reading = self.reading
		GameTooltip:AddLine(reading and (reading.kind == 'xp' and 'Experience' or reading.kind == 'rep' and 'Reputation' or 'Honor') or 'Meter', 1, 1, 1)
		if self.tip then for _, line in ipairs(self.tip) do GameTooltip:AddLine(line, 0.85, 0.85, 0.82) end end
		GameTooltip:AddLine('Click: next source   Right-click: reputations', 0.55, 0.55, 0.52)
		GameTooltip:Show()
	end)
	meter:SetScript('OnMouseUp', function(self, button) UI:Safe(Clicked, self, button) end)
	meter.bar:HookScript('OnSizeChanged', function() UI:Safe(Style, meter) end)
	Style(meter)
end

-- Readout, meters and strip -----------------------------------------------------------------
local strips = {}

function Deck.UpdateMeters()
	if not P.xp then return end
	local db = DB()
	local readout = P.console and P.console.readout
	local reading
	if db.xpbar then
		reading = Paint(P.xp, db.barSource)
		P.xp:SetShown(true)
		if P.xp.secondMeter then
			local wanted = db.barSecond and db.barSecond ~= 'none'
			P.xp.secondMeter:SetShown(wanted and true or false)
			if wanted then Paint(P.xp.secondMeter, db.barSecond) end
		end
	else
		P.xp:Hide()
		if P.xp.secondMeter then P.xp.secondMeter:Hide() end
		reading = Read('xp')
	end
	if readout then
		local level = Level()
		local text
		if reading.kind == 'xp' and reading.level then text = format('LV %d  %4.1f%%', reading.level, reading.value / reading.max * 100)
		elseif reading.kind == 'rep' then text = format('LV %s  REP', level or '??')
		elseif reading.kind == 'honor' then text = format('LV %s  HON', level or '??')
		else text = level and format('LV %d  MAX', level) or 'LV ??' end
		readout:SetText(Readout(text))
	end
end

local function BuildStrip(parent)
	local strip = CreateFrame('Frame', nil, parent)
	strip.cells = {}
	local dark = Surface() == 'dark'
	for index = 1, STAT_SLOTS do
		local cell = CreateFrame('Frame', nil, strip)
		cell.led = Kit:Led(cell, 4, false)
		cell.legend = Kit:Label(cell, '', dark and 'darkDim' or 'dim', 7, true)
		cell.legend:SetWordWrap(false)
		cell.lcd = Kit:LCDPanel(cell, {radius = 3})
		cell.value = Kit:Text(cell.lcd, '', 'tiny', 'lcdInk', true)
		cell.value:SetPoint('RIGHT', -4, 0)
		cell.value:SetJustifyH('RIGHT')
		cell.value:SetWordWrap(false)
		-- Minimal text: the value printed in the numbers face, a hairline dot
		-- between readouts, no boxes.
		cell.plain = Kit:Text(cell, '', 8, dark and 'darkInk' or 'ink', true)
		Kit:Font(cell.plain, 8, nil, true, 'numbers')
		cell.plain:SetWordWrap(false)
		cell.dot = cell:CreateTexture(nil, 'ARTWORK')
		cell.dot:SetColorTexture(1, 1, 1, 1)
		cell.dot:SetSize(2, 2)
		Kit:Tint(cell.dot, dark and 'darkDim' or 'dim', 0.6)
		strip.cells[index] = cell
	end
	strips[#strips + 1] = strip
	return strip
end

local function TextStrip() return (DB().statsStyle or 'text') == 'text' end

function Deck.StripHeight()
	if not StatsWanted() then return 0 end
	if TextStrip() then return 10 end
	return DB().statsSize == 'comfortable' and 25 or 14
end

local function LayoutStrip(strip, width)
	local db = DB()
	local ids = {}
	for index = 1, STAT_SLOTS do
		local id = db['stat'..index]
		if id and STATS[id] then ids[#ids + 1] = id end
	end
	strip.ids = ids
	local count = #ids
	local text = TextStrip()
	local comfortable = not text and db.statsSize == 'comfortable'
	local height = text and 10 or (comfortable and 25 or 14)
	strip:SetHeight(height)
	local gap = 8
	local cellWidth = count > 0 and (width - gap * (count - 1)) / count or 0
	for index, cell in ipairs(strip.cells) do
		local id = ids[index]
		cell:SetShown(id ~= nil)
		if id then
			cell:ClearAllPoints()
			cell:SetPoint('TOPLEFT', strip, 'TOPLEFT', (index - 1) * (cellWidth + gap), 0)
			cell:SetSize(cellWidth, height)
			cell.legend:SetText(strupper(STATS[id][1]))
			cell.led:ClearAllPoints()
			cell.legend:ClearAllPoints()
			cell.lcd:ClearAllPoints()
			cell.plain:ClearAllPoints()
			cell.dot:ClearAllPoints()
			cell.led:SetShown(not text)
			cell.lcd:SetShown(not text)
			cell.plain:SetShown(text)
			cell.dot:SetShown(text and index > 1)
			if text then
				-- Legend and value meet at the cell's middle; a dot marks the cell's start.
				cell.legend:SetWidth(0)
				cell.legend:SetJustifyH('RIGHT')
				cell.legend:SetPoint('RIGHT', cell, 'CENTER', -3, 0)
				cell.plain:SetPoint('LEFT', cell, 'CENTER', 3, 0)
				cell.plain:SetJustifyH('LEFT')
				cell.dot:SetPoint('CENTER', cell, 'LEFT', -gap / 2, 0)
			elseif comfortable then
				-- Lamp and legend on a printed line, the LCD under them.
				cell.led:SetPoint('TOPLEFT', 1, -2)
				cell.legend:SetPoint('LEFT', cell.led, 'RIGHT', 4, 0)
				cell.legend:SetPoint('RIGHT', cell, 'RIGHT', 0, 0)
				cell.legend:SetJustifyH('LEFT')
				cell.lcd:SetPoint('BOTTOMLEFT')
				cell.lcd:SetPoint('BOTTOMRIGHT')
				cell.lcd:SetHeight(14)
			else
				-- One line: lamp, legend, LCD.
				cell.led:SetPoint('LEFT', 1, 0)
				cell.legend:SetPoint('LEFT', cell.led, 'RIGHT', 4, 0)
				local legendWidth = min(56, cellWidth * 0.45)
				cell.legend:SetWidth(legendWidth)
				cell.legend:SetJustifyH('LEFT')
				cell.lcd:SetPoint('TOPRIGHT')
				cell.lcd:SetPoint('BOTTOMRIGHT')
				cell.lcd:SetWidth(max(cellWidth - legendWidth - 13, 10))
			end
		end
	end
end

local function UpdateStrip(strip)
	if not (strip:IsVisible() and strip.ids) then return end
	for index, id in ipairs(strip.ids) do
		local cell = strip.cells[index]
		local ok, text, lamp = pcall(STATS[id][2])
		if not ok then text, lamp = '--', nil end
		if cell.text ~= text then cell.text = text; cell.value:SetText(text or ''); cell.plain:SetText(text or '') end
		if cell.lamp ~= lamp then
			cell.lamp = lamp
			Kit:SetLed(cell.led, lamp ~= nil, lamp)
		end
	end
end

-- The bottom of a device: the second meter, and the strip above the meters.
function Deck.BuildBottom(parent)
	if not P.xp then return end
	-- A second meter above the first, built like it.
	local second = BuildXP(parent)
	second.second = true
	P.xp.secondMeter = second
	Deck.DressMeter(P.xp, false)
	Deck.DressMeter(second, true)
	P.xp.strip = BuildStrip(parent)
end

local function SecondShown()
	local db = DB()
	return db.xpbar and db.barSecond and db.barSecond ~= 'none'
end

-- Height of everything along the base, with the gap above it.
function Deck.BottomHeight()
	local db = DB()
	local height = 0
	if db.xpbar then height = height + MeterHeight() + ROW_GAP end
	if SecondShown() then height = height + MeterHeight() + 4 end
	local strip = Deck.StripHeight()
	if strip > 0 then height = height + strip + ROW_GAP end
	return height
end

-- Place the meters and the strip along `parent`'s base, `inset` in from its edges.
-- right and bottom: the insets from those edges (the left one's by default);
-- hidden: the console editor took the deck out.
function Deck.PlaceBottom(parent, inset, right, bottom, hidden)
	if not P.xp then return end
	local db = DB()
	right = right or inset
	local y = bottom or inset
	if hidden then
		P.xp:Hide()
		if P.xp.secondMeter then P.xp.secondMeter:Hide() end
		if P.xp.strip then P.xp.strip:Hide() end
		return
	end
	P.xp:SetShown(db.xpbar and true or false)
	HW.PlaceMeter(P.xp, parent, inset, right, y, MeterHeight())
	if db.xpbar then y = y + MeterHeight() end
	local second = P.xp.secondMeter
	if second then
		second:SetShown(SecondShown() and true or false)
		if second:IsShown() then
			y = y + 4
			HW.PlaceMeter(second, parent, inset, right, y, MeterHeight())
			y = y + MeterHeight()
		else
			HW.PlaceMeter(second, parent, inset, right, y, MeterHeight())
		end
	end
	local strip = P.xp.strip
	if strip then
		local height = Deck.StripHeight()
		strip:SetShown(height > 0)
		if height > 0 then
			if db.xpbar or SecondShown() then y = y + ROW_GAP end
			strip:ClearAllPoints()
			strip:SetPoint('BOTTOMLEFT', parent, 'BOTTOMLEFT', inset, y)
			strip:SetPoint('BOTTOMRIGHT', parent, 'BOTTOMRIGHT', -right, y)
			LayoutStrip(strip, parent:GetWidth() - inset - right)
			UpdateStrip(strip)
		end
	end
	Deck.UpdateMeters()
end

-- Function keys -------------------------------------------------------------------------------
-- secure: attributes for our secure button; click: Blizzard buttons the key
-- clicks (the first that exists), securely; func: plain Lua run on click.
-- names: Blizzard button names separated by spaces; the first that exists.
local function FirstButton(names)
	for name in names:gmatch('%S+') do
		local button = _G[name]
		if button and not Forbidden(button) then return button end
	end
end

local function ShownFrame(...)
	for index = 1, select('#', ...) do
		local frame = _G[select(index, ...)]
		if type(frame) == 'table' and frame.IsShown and frame:IsShown() then return true end
	end
	return false
end

local function BarsLocked()
	local get = (C_CVar and C_CVar.GetCVarBool) or GetCVarBool
	return get and get('lockActionBars') and true or false
end

local HEARTH = 6948
local function HearthCooldown()
	local get = (C_Container and C_Container.GetItemCooldown) or _G.GetItemCooldown
	local start, duration = Call(get, HEARTH)
	if start and duration and start > 0 and duration > 1.5 then return start, duration end
end

local FN = {
	mount = {glyph = 'mount', legend = 'Mount', tip = 'Summon a random favorite mount.',
		secure = {type = 'macro', macrotext = '/run if C_MountJournal then C_MountJournal.SummonByID(0) end'},
		lamp = function() return Call(IsMounted) and 'green' or nil end},
	hearth = {glyph = 'hearth', legend = 'Hearth', tip = 'Use your hearthstone.', secure = {type = 'item', item = 'item:'..HEARTH},
		cooldown = HearthCooldown, lamp = function() return HearthCooldown() and 'amber' or nil end},
	map = {glyph = 'map', legend = 'Map', tip = 'Open the world map.', func = function() if ToggleWorldMap then ToggleWorldMap() end end,
		lamp = function() return ShownFrame('WorldMapFrame') and 'lamp' or nil end},
	spellbook = {glyph = 'spellbook', legend = 'Spells', tip = 'Open your spellbook.',
		click = 'SpellbookMicroButton', func = function()
			if PlayerSpellsUtil and PlayerSpellsUtil.ToggleSpellBookFrame then PlayerSpellsUtil.ToggleSpellBookFrame() end
		end, lamp = function() return ShownFrame('PlayerSpellsFrame', 'SpellBookFrame') and 'lamp' or nil end},
	talents = {glyph = 'talents', legend = 'Talent', tip = 'Open your talents.', click = 'PlayerSpellsMicroButton TalentMicroButton',
		lamp = function() return ShownFrame('PlayerSpellsFrame', 'PlayerTalentFrame', 'TalentFrame') and 'lamp' or nil end},
	character = {glyph = 'character', legend = 'Char', tip = 'Open your character.', click = 'CharacterMicroButton',
		lamp = function() return ShownFrame('CharacterFrame') and 'lamp' or nil end},
	collections = {glyph = 'collections', legend = 'Coll', tip = 'Open your collections.', click = 'CollectionsMicroButton',
		lamp = function() return ShownFrame('CollectionsJournal') and 'lamp' or nil end},
	journal = {glyph = 'journal', legend = 'Guide', tip = 'Open the adventure guide.', click = 'EJMicroButton',
		lamp = function() return ShownFrame('EncounterJournal') and 'lamp' or nil end},
	finder = {glyph = 'finder', legend = 'Group', tip = 'Open the group finder.', click = 'LFDMicroButton LFGMicroButton',
		lamp = function() return ShownFrame('PVEFrame', 'LFGParentFrame') and 'lamp' or nil end},
	quests = {glyph = 'quest', legend = 'Quest', tip = 'Open your quest log.', click = 'QuestLogMicroButton',
		lamp = function() return ShownFrame('QuestLogFrame') and 'lamp' or nil end},
	bags = {glyph = 'backpack', legend = 'Bags', tip = 'Open your bags.', func = function() if ToggleAllBags then ToggleAllBags() end end,
		lamp = function() return ShownFrame('ContainerFrameCombinedBags', 'ContainerFrame1') and 'lamp' or nil end},
	drawer = {glyph = 'drawer', legend = 'Drawer', tip = 'Open the gadget drawer.', func = function() if UI.ToggleDrawer then UI:ToggleDrawer() end end,
		lamp = function() return UI.DrawerOpen and UI:DrawerOpen() and 'lamp' or nil end},
	move = {glyph = 'move', legend = 'Move', tip = 'Move and size the interface.', func = function() if UI.ToggleMovers then UI:ToggleMovers() end end,
		lamp = function() return UI.MoversUnlocked and UI:MoversUnlocked() and 'amber' or nil end},
	calendar = {glyph = 'calendar', legend = 'Cal', tip = 'Open the calendar.', func = function()
			if UI.OpenCalendar then UI:OpenCalendar() elseif ToggleCalendar then ToggleCalendar() end
		end},
	meter = {glyph = 'meter', legend = 'Meter', tip = 'Show or hide the damage meters.', func = function()
			local shown
			for _, entry in ipairs(UI.GetMovers and UI:GetMovers() or {}) do
				if entry.key:find('^dm%.') and entry.frame and not entry.frame:IsProtected() then
					if shown == nil then shown = not entry.frame:IsShown() end
					entry.frame:SetShown(shown)
				end
			end
			local details = _G.Details
			if type(details) == 'table' and type(details.ToggleWindows) == 'function' then pcall(details.ToggleWindows, details) end
		end},
	lock = {glyph = 'lock', legend = 'Lock', tip = 'Lock or unlock the action bars.', func = function()
			if InCombatLockdown() then return end
			DB().lock = BarsLocked() and 'off' or 'on'
			ApplyLock()
		end, lamp = function() return not BarsLocked() and 'amber' or nil end},
	reload = {glyph = 'reload', legend = 'Reload', tip = 'Reload the interface.', func = function()
			Kit:AlertDialog({title = 'Reload UI', text = 'Reload the interface now?', confirm = 'Reload', onConfirm = ReloadUI, reload = true})
		end},
	menu = {glyph = 'menu', legend = 'Menu', tip = 'Open the game menu.', click = 'MainMenuMicroButton',
		lamp = function() return ShownFrame('GameMenuFrame') and 'lamp' or nil end},
	macro = {glyph = 'macro', legend = 'Macro', tip = 'Run your chosen macro.', macro = true},
}
Deck.FN_ITEMS = {{'none', 'None'}, {'mount', 'Mount'}, {'hearth', 'Hearthstone'}, {'map', 'Map'}, {'spellbook', 'Spellbook'},
	{'talents', 'Talents'}, {'character', 'Character'}, {'bags', 'Bags'}, {'collections', 'Collections'},
	{'journal', 'Adventure guide'}, {'finder', 'Group finder'}, {'quests', 'Quest log'}, {'drawer', 'Drawer'},
	{'move', 'Move UI'}, {'calendar', 'Calendar'}, {'meter', 'Damage meters'}, {'lock', 'Lock bars'},
	{'reload', 'Reload UI'}, {'menu', 'Game menu'}, {'macro', 'Custom macro'}}
local FN_SLOTS = 8
local fnKeys = {}

local function FnSize() return Kit:Clamp(floor(tonumber(DB().fnSize) or 22), 18, 32) end

-- How many keys each side carries (slots 1-4 left, 5-8 right).
local function FnCounts()
	local db = DB()
	if db.fnKeys == false then return 0, 0 end
	local left, right = 0, 0
	for index = 1, FN_SLOTS do
		local id = db['fn'..index]
		if id and FN[id] then
			if index <= FN_SLOTS / 2 then left = left + 1 else right = right + 1 end
		end
	end
	return left, right
end

-- Round glyph keycaps (the reference's round key) on the light keys; the
-- charcoal caps keep their own shape. No slot or well behind them.
function Deck.FnSprite(down)
	if LightCap() then return down and 'key-round-down' or 'key-round' end
	return Sprites()[down and 2 or 1]
end

-- The face: pressed one unit down, lifted one unit while the mouse is over it.
local function FnFace(key)
	local offset = key.down and -1 or (key.hover and 1 or 0)
	key.face:ClearAllPoints()
	key.face:SetPoint('TOPLEFT', 0, offset)
	key.face:SetPoint('BOTTOMRIGHT', 0, offset)
end

local function FnPress(key, down)
	if key.down == down then return end
	key.down = down
	Kit:SetSprite(key.skin, Deck.FnSprite(down))
	FnFace(key)
	Sound(down)
end

local function FnKey(parent, index)
	local button = CreateFrame('Button', 'JiberishSpec01FnKey'..index, parent, 'SecureActionButtonTemplate')
	button:RegisterForClicks('AnyUp')
	local key = {button = button, index = index}
	local back = CreateFrame('Frame', nil, button)
	back:SetAllPoints()
	back:EnableMouse(false)
	back:SetFrameLevel(max(button:GetFrameLevel() - 1, 0))
	key.back = back
	key.skin = Kit:Skin(back, Deck.FnSprite(false), 'BACKGROUND', 0)
	key.skin.kitMaxCorner = 6
	key.face = CreateFrame('Frame', nil, button)
	key.face:SetAllPoints()
	key.face:EnableMouse(false)
	key.glyph = key.face:CreateTexture(nil, 'ARTWORK')
	key.glyph:SetTexture(Kit.media..'icons-menu.tga')
	key.glyph:SetPoint('CENTER')
	key.cooldown = CreateFrame('Cooldown', nil, key.face, 'CooldownFrameTemplate')
	key.cooldown:SetAllPoints()
	key.cooldown:SetDrawEdge(false)
	key.cooldown:SetHideCountdownNumbers(true)
	if key.cooldown.SetSwipeTexture then key.cooldown:SetSwipeTexture(Kit.media..'mask-icon.tga', 0, 0, 0, 0.45) end
	-- The lamp inside the cap's top, clear of a round cap's edge.
	key.lamp = Kit:Led(key.face, 3, false)
	key.lamp:SetPoint('TOP', 0, -2)
	-- The legend is printed beside or under the key (see Deck.PlaceFnAt).
	key.legend = Kit:Label(parent, '', Surface() == 'dark' and 'darkDim' or 'dim', 6, true)
	key.legend:SetWordWrap(false)
	button:HookScript('OnMouseDown', function() FnPress(key, true) end)
	button:HookScript('OnMouseUp', function() FnPress(key, false) end)
	button:HookScript('OnHide', function() FnPress(key, false) end)
	button:HookScript('OnClick', function()
		local def = key.def
		-- Plain functions run here; secure actions were done by the button itself.
		if def and def.func and not key.secure then UI:Safe(def.func) end
		C_Timer.After(0.1, function() UI:Safe(Deck.FnLamps) end)
	end)
	button:SetScript('OnEnter', function(self)
		local def = key.def
		if not def then return end
		key.hover = true
		FnFace(key)
		Kit:Play('tick')
		GameTooltip:SetOwner(self, 'ANCHOR_TOP')
		GameTooltip:AddLine(def.name or def.legend, 1, 1, 1)
		GameTooltip:AddLine(def.tip, 0.85, 0.85, 0.82, true)
		GameTooltip:Show()
	end)
	button:SetScript('OnLeave', function()
		key.hover = nil
		FnFace(key)
		GameTooltip:Hide()
	end)
	fnKeys[index] = key
	return key
end

-- Set up each key for its slot. Out of combat only (secure attributes).
function Deck.ConfigureFn()
	if #fnKeys == 0 then return end
	if InCombatLockdown() then return UI:AfterCombat(Deck.ConfigureFn, 'ab.fnkeys') end
	local db = DB()
	local size = FnSize()
	for index, key in ipairs(fnKeys) do
		local id = db.fnKeys ~= false and db['fn'..index]
		local def = id and FN[id]
		local button = key.button
		for _, attribute in ipairs({'type', 'macrotext', 'item', 'clickbutton', 'macro'}) do button:SetAttribute(attribute, nil) end
		key.def, key.secure = def, nil
		-- Just the icon on the console's housing, or the icon on a keycap.
		local bare = db.consoleBare ~= false
		key.skin:SetShown(not bare)
		if def then
			if def.secure then
				for attribute, value in pairs(def.secure) do button:SetAttribute(attribute, value) end
				key.secure = true
			elseif def.macro then
				local name = strtrim(db.fnMacro or '')
				if name ~= '' then button:SetAttribute('type', 'macro'); button:SetAttribute('macro', name); key.secure = true end
			elseif def.click then
				local target = FirstButton(def.click)
				if target then button:SetAttribute('type', 'click'); button:SetAttribute('clickbutton', target); key.secure = true end
			end
			local index0 = Deck.MENU_INDEX and Deck.MENU_INDEX[def.glyph] or 0
			local column, row = index0 % 8, floor(index0 / 8)
			key.glyph:SetTexCoord(column / 8, (column + 1) / 8, row / 4, (row + 1) / 4)
			local glyphSize = floor(size * (bare and 0.86 or 0.62) + 0.5)
			key.glyph:SetSize(glyphSize, glyphSize)
			Kit:Tint(key.glyph, bare and (Surface() == 'dark' and 'darkInk' or 'ink') or (LightCap() and 'ink' or 'darkInk'), bare and 0.78 or 0.85)
			local legend = def.legend
			if def.macro and strtrim(db.fnMacro or '') ~= '' then legend = strsub(strtrim(db.fnMacro), 1, 6) end
			key.legend:SetText(strupper(legend))
			button:SetSize(size, size)
			Kit:SetSprite(key.skin, Deck.FnSprite(key.down))
			Kit:FitSprite(key.skin, size, size)
			if key.cooldown.SetSwipeTexture then
				key.cooldown:SetSwipeTexture(Kit.media..(LightCap() and 'circle' or 'mask-icon')..'.tga', 0, 0, 0, 0.45)
			end
			button:Show()
		else
			button:Hide()
		end
		key.legend:SetShown(def ~= nil)
	end
	Deck.FnLamps()
end

function Deck.FnLamps()
	for _, key in ipairs(fnKeys) do
		local def = key.def
		if def and key.button:IsVisible() then
			local ok, lamp = pcall(def.lamp or function() end)
			lamp = ok and lamp or nil
			if key.lit ~= lamp then
				key.lit = lamp
				Kit:SetLed(key.lamp, lamp ~= nil, lamp)
			end
			if def.cooldown then
				local start, duration = def.cooldown()
				if start then key.cooldown:SetCooldown(start, duration) else key.cooldown:Clear() end
			end
		end
	end
end

function Deck.BuildFn(parent)
	if #fnKeys > 0 then return end
	parent.fnLeft = CreateFrame('Frame', nil, parent)
	parent.fnRight = CreateFrame('Frame', nil, parent)
	for index = 1, FN_SLOTS do FnKey(index <= FN_SLOTS / 2 and parent.fnLeft or parent.fnRight, index) end
	Deck.ConfigureFn()
end

-- The function keys' clusters. Each side's keys run in `columns` (from the
-- console editor; one column by default) with their legends printed beside
-- them, facing the banks; in two or more columns the legends go under each
-- key and the keys space out to fit them. Legends are measured, never overlap.
-- Gap between keys, between a key and its legend, and the widest legend.
-- (A column's keys sit closer: 4 keys of 22 stay inside a 2-row console.)
Deck.FN_GAP, Deck.FN_LEGEND_GAP, Deck.FN_LEGEND_MAX, Deck.FN_COLUMN_GAP = 6, 5, 44, 4
function Deck.FnColumns(side)
	local custom = Deck.CustomLayout()
	local spot = custom and custom[side == 1 and 'fnL' or 'fnR']
	return Kit:Clamp(floor(type(spot) == 'table' and tonumber(spot.columns) or 1), 1, FN_SLOTS / 2)
end

-- A side's shown keys, the widest legend among them, and its size: width,
-- height, keys, legend width, columns.
function Deck.FnCluster(side)
	local FN_GAP, FN_LEGEND_GAP, FN_LEGEND_MAX = Deck.FN_GAP, Deck.FN_LEGEND_GAP, Deck.FN_LEGEND_MAX
	local list, legend = {}, 0
	if #fnKeys == 0 or DB().fnKeys == false then return 0, 0, list, 0, 1 end
	local first = side == 1 and 1 or FN_SLOTS / 2 + 1
	for index = first, first + FN_SLOTS / 2 - 1 do
		local key = fnKeys[index]
		if key and key.def then
			list[#list + 1] = key
			local text = key.legend
			local width = text.GetUnboundedStringWidth and text:GetUnboundedStringWidth() or text:GetStringWidth()
			legend = max(legend, width or 0)
		end
	end
	if #list == 0 then return 0, 0, list, 0, 1 end
	legend = min(math.ceil(legend), FN_LEGEND_MAX)
	local size, columns = FnSize(), Deck.FnColumns(side)
	local across = min(columns, #list)
	local lines = math.ceil(#list / across)
	if across == 1 then
		return size + FN_LEGEND_GAP + legend, lines * size + (lines - 1) * Deck.FN_COLUMN_GAP, list, legend, 1
	end
	local pitch = max(size, legend) + FN_GAP
	return across * pitch - FN_GAP, lines * (size + 12) - 4, list, legend, across
end

-- The larger side's size (for the console's side columns and body).
function Deck.FnBlock()
	local lw, lh = Deck.FnCluster(1)
	local rw, rh = Deck.FnCluster(2)
	if lw == 0 and rw == 0 then return 0, 0, 1 end
	return max(lw, rw), max(lh, rh), 1
end

-- Each cluster's size: left width, height, right width, height.
function Deck.FnSides()
	local lw, lh = Deck.FnCluster(1)
	local rw, rh = Deck.FnCluster(2)
	return lw, lh, rw, rh
end

-- One cluster (side 1 left, 2 right) with its top-left at x, y in the parent
-- (y down); no x hides it.
function Deck.PlaceFnAt(parent, side, x, y)
	if #fnKeys == 0 or not parent.fnLeft then return end
	if InCombatLockdown() then return UI:AfterCombat(function() Deck.PlaceFnAt(parent, side, x, y) end, 'ab.fnplace'..side) end
	local cluster = side == 1 and parent.fnLeft or parent.fnRight
	if not x then cluster:Hide() return end
	local FN_GAP, FN_LEGEND_GAP = Deck.FN_GAP, Deck.FN_LEGEND_GAP
	local width, height, list, legend, across = Deck.FnCluster(side)
	local size = FnSize()
	local pitch = max(size, legend) + FN_GAP
	for index, key in ipairs(list) do
		local line, place = floor((index - 1) / across), (index - 1) % across
		local button, text = key.button, key.legend
		button:ClearAllPoints()
		text:ClearAllPoints()
		text:SetWidth(across == 1 and legend or pitch - 2)
		if across == 1 then
			-- One column, the legend beside each key, facing the banks.
			local top = -(index - 1) * (size + Deck.FN_COLUMN_GAP)
			if side == 1 then
				button:SetPoint('TOPLEFT', cluster, 'TOPLEFT', 0, top)
				text:SetPoint('LEFT', button, 'RIGHT', FN_LEGEND_GAP, 0)
				text:SetJustifyH('LEFT')
			else
				button:SetPoint('TOPRIGHT', cluster, 'TOPRIGHT', 0, top)
				text:SetPoint('RIGHT', button, 'LEFT', -FN_LEGEND_GAP, 0)
				text:SetJustifyH('RIGHT')
			end
		else
			button:SetPoint('TOPLEFT', cluster, 'TOPLEFT', place * pitch + (pitch - FN_GAP - size) / 2, -line * (size + 12))
			text:SetPoint('TOP', button, 'BOTTOM', 0, -3)
			text:SetJustifyH('CENTER')
		end
	end
	cluster:SetSize(max(width, 1), max(height, 1))
	cluster:ClearAllPoints()
	cluster:SetPoint('TOPLEFT', parent, 'TOPLEFT', x, -y)
	cluster:SetShown(#list > 0)
end

-- Header panels -------------------------------------------------------------------------------
local PANELS = {
	{id = 'zone', field = 'panelZone', width = 128, read = function()
		local zone = Call(GetMinimapZoneText) or Call(GetZoneText) or ''
		local map = C_Map and Call(C_Map.GetBestMapForUnit, 'player')
		local position = map and C_Map.GetPlayerMapPosition and Call(C_Map.GetPlayerMapPosition, map, 'player')
		local x, y
		if position and position.GetXY then x, y = Call(position.GetXY, position) end
		zone = strupper(strsub(zone, 1, 12))
		if x and y then return format('%s %.1f %.1f', zone, x * 100, y * 100) end
		return zone
	end},
	{id = 'gold', field = 'panelGold', width = 64, read = function() return Gold(Plain(GetMoney())) end},
	{id = 'durability', field = 'panelDurability', width = 58, led = true, read = function()
		local lowest
		for slot = 1, 19 do
			local current, maximum = Call(GetInventoryItemDurability, slot)
			if current and maximum and maximum > 0 then lowest = min(lowest or 1, current / maximum) end
		end
		if not lowest then return 'DUR --' end
		return format('DUR %d%%', floor(lowest * 100 + 0.5)), lowest < 0.2 and 'red' or lowest < 0.5 and 'amber' or 'green'
	end},
	{id = 'latency', field = 'panelLatency', width = 58, led = true, read = function()
		local _, _, home, world = Call(GetNetStats)
		local ms = max(home or 0, world or 0)
		return format('%dMS', ms), ms > 300 and 'red' or ms > 150 and 'amber' or 'green'
	end},
}

function Deck.BuildPanels(device)
	device.panels = {}
	for _, def in ipairs(PANELS) do
		local panel = Kit:LCDPanel(device, {radius = 3})
		panel:SetSize(def.width, 14)
		panel.def = def
		panel.text = Kit:Text(panel, '', 'tiny', 'lcdInk', true)
		panel.text:SetPoint('RIGHT', -5, 0)
		panel.text:SetWordWrap(false)
		if def.led then
			panel.led = Kit:Led(panel, 4, false)
			panel.led:SetPoint('LEFT', 5, 0)
		end
		panel:Hide()
		device.panels[#device.panels + 1] = panel
	end
end

-- Lay the panels out leftward from `anchor` while they fit beside the title,
-- and return the frame the title should end at.
function Deck.PlacePanels(device, anchor, used)
	if not device.panels then return anchor end
	local db = DB()
	local room = device:GetWidth() - used - 170 -- the model plate and title keep their room
	local at = anchor
	for _, panel in ipairs(device.panels) do
		local wanted = db[panel.def.field] ~= false
		if wanted and room >= panel:GetWidth() + 6 then
			room = room - panel:GetWidth() - 6
			panel:ClearAllPoints()
			panel:SetPoint('RIGHT', at, 'LEFT', -6, 0)
			panel:Show()
			at = panel
		else
			panel:Hide()
		end
	end
	Deck.UpdatePanels(device)
	return at
end

function Deck.UpdatePanels(device)
	for _, panel in ipairs(device and device.panels or {}) do
		if panel:IsShown() then
			local ok, text, lamp = pcall(panel.def.read)
			if ok then
				panel.text:SetText(text or '')
				if panel.led then Kit:SetLed(panel.led, lamp ~= nil, lamp) end
			end
		end
	end
end

-- Events and the ticker ------------------------------------------------------------------------
local events = CreateFrame('Frame')
for _, event in ipairs({'PLAYER_ENTERING_WORLD', 'PLAYER_XP_UPDATE', 'PLAYER_LEVEL_UP', 'QUEST_TURNED_IN',
	'CHAT_MSG_COMBAT_XP_GAIN', 'TIME_PLAYED_MSG', 'PLAYER_MONEY', 'UPDATE_INVENTORY_DURABILITY', 'BAG_UPDATE_COOLDOWN',
	'PLAYER_MOUNT_DISPLAY_CHANGED', 'CVAR_UPDATE', 'HONOR_XP_UPDATE', 'HONOR_LEVEL_UPDATE', 'QUEST_LOG_UPDATE'}) do
	pcall(events.RegisterEvent, events, event)
end
events:SetScript('OnEvent', function(_, event, ...)
	if event == 'PLAYER_ENTERING_WORLD' then
		if not session.money then session.money = Plain(GetMoney()) end
		TrackXP()
		local db = DB()
		local wantsPlayed = false
		for index = 1, STAT_SLOTS do
			local id = db['stat'..index]
			if id == 'played' or id == 'levelTime' then wantsPlayed = true end
		end
		if wantsPlayed and StatsWanted() and P.xp then C_Timer.After(2, AskPlayed) end
	elseif event == 'PLAYER_XP_UPDATE' or event == 'PLAYER_LEVEL_UP' then
		TrackXP()
	elseif event == 'QUEST_TURNED_IN' then
		local _, xpReward = ...
		xpReward = Plain(xpReward)
		if type(xpReward) == 'number' and xpReward > 0 then session.questXP = session.questXP + xpReward end
		questUntil = GetTime() + 1
	elseif event == 'CHAT_MSG_COMBAT_XP_GAIN' then
		-- Only counted, never read: a kill's XP message (quest XP arrives with a turn-in).
		if GetTime() > questUntil then session.kills = session.kills + 1 end
	elseif event == 'TIME_PLAYED_MSG' then
		local total, level = ...
		total, level = Plain(total), Plain(level)
		if type(total) == 'number' then played.total, played.level, played.at = total, level or 0, GetTime() end
		C_Timer.After(0, function() Quiet(false) end)
	elseif event == 'QUEST_LOG_UPDATE' then
		if DB().questPreview then UI:Safe(Deck.UpdateMeters) end
		return
	end
	if event == 'HONOR_XP_UPDATE' or event == 'HONOR_LEVEL_UPDATE' then UI:Safe(Deck.UpdateMeters) end
	UI:Safe(Deck.FnLamps)
end)

-- Once a second, while a console is shown: the strip, the panels and the key lamps.
C_Timer.NewTicker(1, function()
	if not (P.xp and P.xp:GetParent() and P.xp:GetParent():IsVisible()) then return end
	for _, strip in ipairs(strips) do UI:Safe(UpdateStrip, strip) end
	if P.console then UI:Safe(Deck.UpdatePanels, P.console) end
	UI:Safe(Deck.FnLamps)
end)
end)()
