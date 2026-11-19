-- The objective tracker as a SPEC-01 instrument panel: "OT-1 Objectives".
--
-- Housing: a dark device behind Blizzard's tracker, its printed header (lamp,
-- model code, name, an LCD counter of tracked quests or the quest log) on the
-- tracker header's own centre line, a hairline under it, and even gutters.
-- Sections: printed bands (Blizzard's own name in the header font, a hairline
-- rule, a dim section code and a round key that folds the section); a folded
-- section shows how many entries it holds on a small LCD.
-- Quests: Blizzard's round quest buttons become small SPEC-01 keys with a
-- monochrome glyph, lit in the key colour when focused, green when ready to
-- turn in, red if failed (blocks without one get a lamp instead: one status
-- light per quest). The title sits on a slab of dark glass with a thin edge
-- in that state's colour; on hover it lifts with a soft lamp glow. Each
-- objective has a lamp in place of its dash, an open count such as 3/8 sits
-- on a small LCD glass under Blizzard's own digits, progress bars are LED dot
-- meters in glass, timers read on an LCD and "Ready for turn-in" reads in a
-- soft green ink beside a green lamp. Quest item buttons wear a key.
-- Motion and sound: a new quest powers on (title prints in, its key flashes,
-- a relay), a count that moves flashes its glass with a tick, a finished objective
-- flashes its lamp with a detent, a finished quest gets a lamp sweep, and a
-- quest that leaves powers down. Reduce motion and the sound settings rule.
--
-- Blizzard's tracker stays in charge: its quest item buttons are secure, it is
-- placed and sized with Edit Mode, and its layout runs in secure code that
-- other addons have tainted before. So this file:
--   * never calls the tracker's Update or layout methods, never writes fields
--     onto its frames and never moves, shows or hides its frames;
--   * only post-hooks: hooksecurefunc on module methods, HookScript on a few
--     buttons for hover and press (drawn on our own textures), and does its
--     work on Blizzard's frames one frame later, outside Blizzard's own call;
--   * leaves the scenario and widget sections' contents alone (their frames
--     come from the pool the game shares with tooltips and map pins), styling
--     their headers only;
--   * changes the typeface and line spacing through the tracker's font
--     objects, so Blizzard measures its lines in the new font and wraps them
--     within its own width; everything of ours is drawn under or beside its
--     text in the space it leaves, never over it;
--   * keeps everything it adds in side tables keyed by Blizzard's frames, and
--     quiets Blizzard's art with alpha and vertex alpha (its own animations
--     reset alpha), hiding only art it never shows again; our own fills bake
--     their alpha into the color texture.
-- The housing is a frame of our own, anchored to the tracker and to the lowest
-- section showing, so it follows Edit Mode moves and the content's height.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown, GetTime = CreateFrame, UIParent, InCombatLockdown, GetTime
local floor, max, min, sin, pi = math.floor, math.max, math.min, math.sin, math.pi

local module = UI:RegisterModule('objectives', {})
local IsSecret, Plain, Forbidden = UI.Util.IsSecret, UI.Util.PlainValue, UI.Util.Forbidden
-- Quiet one of Blizzard's regions. Textures also lose their color: the tracker's
-- own animations set alpha back to 1, a vertex alpha of 0 survives them.
-- hide: also hide it, for art Blizzard only ever animates and never shows again.
local function Mute(region, hide)
	if Forbidden(region) then return end
	if region.IsObjectType and region:IsObjectType('Texture') then region:SetVertexColor(1, 1, 1, 0) end
	if region.SetAlpha then region:SetAlpha(0) end
	if hide and region.Hide then region:Hide() end
end

-- defaults:begin
-- textOffset / headerOffset: points added to the tracker's own sizes.
-- headerStyle: 'code' (section code and a rule), 'rule' or 'plain'.
-- completed: 'lit' (lit lamp, bright text), 'dim' (lit lamp, faded line) or 'green'.
-- hideCombat / hideBoss / hideInstance fade the tracker out (alpha only).
-- lamps: status lamps for titles and objectives. chips: counts on LCD chips.
-- motion / sounds: the tracker's own animations and voices.
-- density: 'compact', 'normal' or 'roomy' (space between wrapped lines).
-- titleColor: 'ink' or 'difficulty'. counter: 'tracked', 'log' or 'off'.
UI:RegisterDefaults('objectives', {textOffset = 0, headerOffset = 0, headerStyle = 'code', completed = 'lit', housing = true,
	hideCombat = false, hideBoss = false, hideInstance = false, untrackDone = false,
	lamps = true, chips = true, motion = true, sounds = true, density = 'normal', titleColor = 'ink', counter = 'tracked'})
-- defaults:end
local function DB() return UI.db.objectives end

-- Section modules: the code printed on each band, whether its blocks come from
-- the shared widget pool (header only), and what its block ids are ('watch':
-- watched quests, 'task': area quests).
local SECTIONS = {
	{'ScenarioObjectiveTracker', 'SC-1', true}, {'UIWidgetObjectiveTracker', 'UW-1', true},
	{'CampaignQuestObjectiveTracker', 'CQ-1', false, 'watch'}, {'QuestObjectiveTracker', 'QT-1', false, 'watch'},
	{'AdventureObjectiveTracker', 'AD-1'}, {'AchievementObjectiveTracker', 'AC-1'}, {'MonthlyActivitiesObjectiveTracker', 'MA-1'},
	{'ProfessionsRecipeTracker', 'PR-1'}, {'BonusObjectiveTracker', 'BN-1', false, 'task'},
	{'WorldQuestObjectiveTracker', 'WQ-1', false, 'task'}, {'InitiativeTasksObjectiveTracker', 'IT-1'},
}
local POOLED, CODES, KIND = {}, {}, {}

local FONT_OBJECTS = {'ObjectiveFont', 'ObjectiveTrackerLineFont', 'ObjectiveTrackerHeaderFont'}
for size = 12, 22 do FONT_OBJECTS[#FONT_OBJECTS + 1] = 'ObjectiveTrackerFont'..size end
-- Density: extra space between wrapped lines, and how far plates reach past their text.
local SPACING = {compact = 0, normal = 1, roomy = 3}
local PLATE_PAD = {compact = 1, normal = 2, roomy = 3}

-- Everything added to Blizzard's frames is kept here, keyed by their frame.
local headers = setmetatable({}, {__mode = 'k'})
local blocks = setmetatable({}, {__mode = 'k'})
local rigs = setmetatable({}, {__mode = 'k'})
local bars = setmetatable({}, {__mode = 'k'})
local items = setmetatable({}, {__mode = 'k'})
local timers = setmetatable({}, {__mode = 'k'})
local pois = setmetatable({}, {__mode = 'k'})
local hooked = setmetatable({}, {__mode = 'k'})
local counts = setmetatable({}, {__mode = 'k'})
-- Keyed by quest or objective: what was seen last (so changes can tick), quests
-- just accepted or tracked (they power on), quests leaving, finished quests.
local seen, fresh, leaving, questDone = {}, {}, {}, {}
local housing

local function Tracker() return _G.ObjectiveTrackerFrame end
local function MasterHeader()
	local tracker = Tracker()
	return tracker and (tracker.Header or tracker.HeaderMenu)
end
local Px = UI.Util.Px
-- A length in a frame's units, rounded to whole physical pixels.
local Snap = UI.Util.Snap
-- A plain color texture: color and alpha baked into the texture itself.
local function Fill(texture, token, alpha)
	local r, g, b = Kit:RGB(token)
	texture:SetColorTexture(r, g, b, alpha or 1)
end
local function Tag(kind, object) return Kit.MotionTag('ot-'..kind, object) end
local function FontSize(fontString, fallback)
	local _, size = fontString:GetFont()
	size = Plain(size)
	return type(size) == 'number' and size > 0 and size or fallback or 12
end
local function LampSize(frame, size) return max(Snap(frame, 5), Snap(frame, size * 0.42)) end

-- Motion and sound ----------------------------------------------------------------
local function Moving() return DB().motion ~= false and not Kit:Reduced() end

-- Every voice is rate-limited: one sound at a time, each voice at most every
-- `gap` seconds, and nothing before the tracker has settled after login.
local lastVoice, lastAny = {}, 0
local function Sound(voice, gap)
	local sound = UI.db.sound
	if not (sound and sound.enable and sound.interface) or DB().sounds == false or not module.settled then return end
	local now = GetTime()
	if now - lastAny < 0.04 or now - (lastVoice[voice] or 0) < (gap or 0.09) then return end
	lastAny, lastVoice[voice] = now, now
	Kit:Play(voice, true)
end

-- Typeface --------------------------------------------------------------------------
-- The tracker's own font objects keep their sizes and take the interface's
-- typeface (and a little line spacing), before layout.
local baseSizes = {}
local function SetTypeface()
	local db = DB()
	for _, name in ipairs(FONT_OBJECTS) do
		local font = _G[name]
		if font and font.GetFont and font.SetFont then
			local _, size, flags = font:GetFont()
			if not IsSecret(size) and size then
				baseSizes[name] = baseSizes[name] or {size, flags or ''}
				local base = baseSizes[name]
				local header = name == 'ObjectiveTrackerHeaderFont'
				local offset = tonumber(header and db.headerOffset or db.textOffset) or 0
				font:SetFont(Kit:FontPath(header), max(base[1] + offset, 7), base[2])
				if not header and name ~= 'ObjectiveFont' and font.SetSpacing then font:SetSpacing(SPACING[db.density] or 1) end
			end
		end
	end
end

-- LCD chips ---------------------------------------------------------------------------
-- A small gray LCD with bold digits over unlit ghost digits, built on the kit's
-- LCD panel. Counts, timers and section totals all read on one.
local CHIP_PAD = 3
local function Chip(parent, size)
	local chip = Kit:LCDPanel(parent, {radius = 2})
	chip:EnableMouse(false)
	chip.ghost = Kit:Ghost(Kit:Text(chip, '', size, 'lcdGhost', true))
	chip.digits = Kit:Text(chip, '', size, 'lcdInk', true)
	for _, fontString in ipairs({chip.ghost, chip.digits}) do
		fontString:SetPoint('RIGHT', chip, 'RIGHT', -CHIP_PAD, 0)
		fontString:SetJustifyH('RIGHT')
		fontString:SetWordWrap(false)
	end
	chip:Hide()
	return chip
end

-- Set a chip's reading; auto sizes the chip to its ghost, otherwise the digits
-- shrink to fit the chip. Returns whether the reading changed.
local function SetChip(chip, text, size, auto)
	if chip.text == text and chip.size == size then return false end
	local changed = chip.text ~= nil and chip.text ~= text
	chip.text, chip.size = text, size
	Kit:Font(chip.digits, size, nil, true, 'numbers')
	Kit:Font(chip.ghost, size, nil, true, 'numbers')
	chip.digits:SetText(text)
	chip.ghost:SetText((text:gsub('%d', '8')))
	local wide = max(Plain(chip.digits:GetStringWidth()) or 0, Plain(chip.ghost:GetStringWidth()) or 0)
	if auto then
		chip:SetWidth(floor(wide + CHIP_PAD * 2 + 0.5))
	else
		local room = (Plain(chip:GetWidth()) or 0) - CHIP_PAD * 2 + 1
		if room > 0 and wide > room then
			local fit = max(6, floor(size * room / wide))
			Kit:Font(chip.digits, fit, nil, true, 'numbers')
			Kit:Font(chip.ghost, fit, nil, true, 'numbers')
		end
	end
	return changed
end

local function PrintChip(chip, delay)
	if chip and chip:IsShown() and Moving() then Kit:Print(chip.digits, {force = true, duration = 0.26, steps = 14, delay = delay}) end
end

-- One hidden string measures Blizzard's text in Blizzard's own font.
local measure
local function Measure(fontString, text)
	local path, size, flags = fontString:GetFont()
	if not path or IsSecret(path) or IsSecret(size) or type(size) ~= 'number' then return nil end
	if not measure then
		local holder = CreateFrame('Frame', nil, UIParent)
		holder:Hide()
		measure = holder:CreateFontString(nil, 'OVERLAY')
	end
	measure:SetFont(path, size, flags or '')
	measure:SetText(text)
	return Plain(measure:GetStringWidth()), Plain(measure:GetStringHeight())
end

-- Blizzard text prints in left to right, by its alpha gradient only (the
-- tracker animates the string's alpha itself).
local function PrintIn(fontString)
	if not fontString or not fontString.SetAlphaGradient or not Moving() then return end
	local text = fontString:GetText()
	if IsSecret(text) or type(text) ~= 'string' or text == '' then return end
	local length = strlenutf8 and strlenutf8(text) or #text
	Kit:Animate(Tag('print', fontString), 0.3, 0, 1, function(_, progress)
		fontString:SetAlphaGradient(floor(floor(progress * 16) / 16 * length + 0.5), 1)
	end, function() fontString:SetAlphaGradient(1000, 1) end, 'linear')
end

-- Dot meters on Blizzard's bars ------------------------------------------------
-- Kit:Perforate writes onto the bar and hooks its size; Blizzard's tracker bars
-- get the same dots from textures kept in a side table, sized on each pass,
-- set in a glass bezel of our own.
local FLARES = {'Flare1', 'Flare2', 'SmallFlare1', 'SmallFlare2', 'FullBarFlare1', 'FullBarFlare2'}
local function SizeDots(bar, dots)
	local width, height = bar:GetSize()
	if IsSecret(width) or IsSecret(height) or not height or height <= 0 then
		dots.under:Hide(); dots.cover:Hide()
		return
	end
	for _, texture in ipairs({dots.under, dots.cover}) do
		texture:SetHorizTile(true); texture:SetVertTile(false)
		if texture.SetScale then texture:SetScale(height / 16) end
		texture:Show()
	end
	-- Pooled bars change parents: keep the bezel just under the bar.
	dots.bezel:SetFrameLevel(max(bar:GetFrameLevel() - 1, 1))
	Kit:Relevel(dots.bezel)
end

local function SkinBar(bar)
	if Forbidden(bar) or not bar.GetStatusBarTexture then return end
	local dots = bars[bar]
	if not dots then
		local fill, icon = bar:GetStatusBarTexture(), bar.Icon
		for _, region in ipairs({bar:GetRegions()}) do
			if region ~= fill and region ~= icon and region.IsObjectType and region:IsObjectType('Texture') then Mute(region) end
		end
		-- Bonus bars flare and sheen as they fill; the dots say it instead.
		local holder = bar:GetParent()
		for _, key in ipairs(FLARES) do
			local flare = not Forbidden(holder) and holder[key]
			if not Forbidden(flare) and flare.GetRegions then
				for _, region in ipairs({flare:GetRegions()}) do Mute(region) end
			end
		end
		bar:SetStatusBarTexture([[Interface\Buttons\WHITE8X8]])
		if Kit.MarkBar then Kit:MarkBar(bar) end
		Kit:Tint(bar, 'lamp')
		dots = {}
		dots.well = bar:CreateTexture(nil, 'BACKGROUND', nil, 0)
		dots.well:SetColorTexture(1, 1, 1, 1)
		dots.well:SetAllPoints(bar)
		Kit:Tint(dots.well, 'glass')
		for key, file, layer, sublevel in string.gmatch('under tile-dot BACKGROUND 1 cover tile-perf OVERLAY -8', '(%S+) (%S+) (%S+) (%S+)') do
			local texture = bar:CreateTexture(nil, layer, nil, tonumber(sublevel))
			texture:SetTexture(Kit.media..file..'.tga', 'REPEAT', 'REPEAT')
			texture:SetAllPoints(bar)
			dots[key] = texture
		end
		Kit:Tint(dots.under, 'darkEdge')
		Kit:Tint(dots.cover, 'glass')
		-- The bezel: a glass shell two physical pixels round the meter.
		local bezel = CreateFrame('Frame', nil, bar)
		bezel:EnableMouse(false)
		bezel:SetPoint('TOPLEFT', bar, 'TOPLEFT', -Px(bar, 2), Px(bar, 2))
		bezel:SetPoint('BOTTOMRIGHT', bar, 'BOTTOMRIGHT', Px(bar, 2), -Px(bar, 2))
		bezel:SetFrameLevel(max(bar:GetFrameLevel() - 1, 1))
		bezel.shell = Kit:Shell(bezel, {surface = 'glass', radius = 3, shadow = false})
		dots.bezel = bezel
		local label = bar.Label
		if label and label.SetFont then
			Kit:Font(label, 9, 'OUTLINE', true)
			Kit:Tint(label, 'darkInk')
		end
		-- The bonus and scenario bars carry a reward icon beside them.
		if bar.Icon and bar.Icon.SetTexCoord then bar.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
		bars[bar] = dots
	end
	SizeDots(bar, dots)
end

-- Timers read on an LCD chip; Blizzard's own label (rewritten every frame) goes
-- quiet and a light ticker copies it while a timer shows.
local timerTicker
local function TickTimer(holder, chip)
	local text = Plain(holder.Label:GetText())
	if type(text) ~= 'string' or text == '' then return end
	SetChip(chip, text, 9, true)
	local duration, start = Plain(holder.duration), Plain(holder.startTime)
	local low = type(duration) == 'number' and type(start) == 'number' and duration > 0
		and (duration - (GetTime() - start)) / duration < 0.33 or false
	if chip.low ~= low then
		chip.low = low
		Kit:Tint(chip.digits, low and 'red' or 'lcdInk')
	end
end

local function TickTimers()
	local any = false
	for holder, chip in pairs(timers) do
		if chip:IsShown() and holder:IsVisible() then
			any = true
			TickTimer(holder, chip)
		end
	end
	if not any and timerTicker then timerTicker:Cancel(); timerTicker = nil end
end

local function SkinTimer(holder)
	if Forbidden(holder) or not holder.Bar then return end
	UI:Safe(SkinBar, holder.Bar)
	local label = holder.Label
	if Forbidden(label) or not label.GetText then return end
	local chip = timers[holder]
	if not chip then
		local rig = CreateFrame('Frame', nil, holder)
		rig:SetAllPoints()
		rig:EnableMouse(false)
		chip = Chip(rig, 9)
		chip:SetHeight(14)
		chip:SetPoint('LEFT', holder, 'LEFT', 0, 0)
		timers[holder] = chip
	end
	local on = DB().chips ~= false
	label:SetAlpha(on and 0 or 1)
	chip:SetShown(on)
	if not on then return end
	TickTimer(holder, chip)
	if not timerTicker then timerTicker = C_Timer.NewTicker(0.25, function() UI:Safe(TickTimers) end) end
end

local function SkinBars(section)
	local pools = {section.usedProgressBars, section.usedTimerBars}
	for index = 1, 2 do
		local pool = pools[index]
		if type(pool) == 'table' then
			for _, holder in pairs(pool) do
				if type(holder) == 'table' then
					if index == 2 and holder.Label then UI:Safe(SkinTimer, holder)
					elseif holder.Bar or holder.GetStatusBarTexture then UI:Safe(SkinBar, holder.Bar or holder)
					else
						-- Some clients keep one table of bars per block.
						for _, inner in pairs(holder) do
							if type(inner) == 'table' then UI:Safe(SkinBar, inner.Bar or inner) end
						end
					end
				end
			end
		end
	end
end

-- Quest item and group-finder buttons ----------------------------------------------
-- Each becomes a SPEC-01 key: our key art behind it, Blizzard's frame art
-- quiet, a rounded icon, a lamp-colored hover glow and a key press. The item
-- button is secure: it is only dressed out of combat, never moved, and its
-- press is drawn on our own textures.
local MASK = Kit.media..'mask-icon.tga'
local function SkinEdgeButton(button)
	if Forbidden(button) or items[button] or InCombatLockdown() then return end
	if not (button.IsObjectType and button:IsObjectType('Button')) then return end
	local item = button.icon ~= nil
	local key = CreateFrame('Frame', nil, button)
	if item then
		key:SetPoint('TOPLEFT', -3, 3)
		key:SetPoint('BOTTOMRIGHT', 3, -4)
	else
		key:SetSize(22, 22)
		key:SetPoint('CENTER', -1, 0)
	end
	key:SetFrameLevel(max(button:GetFrameLevel() - 1, 0))
	key:EnableMouse(false)
	key.skin = Kit:Skin(key, 'key', 'BACKGROUND', 0)
	key.skin.kitMaxCorner = 7
	items[button] = key
	for _, getter in ipairs({'GetNormalTexture', 'GetPushedTexture', 'GetDisabledTexture'}) do
		local texture = button[getter] and button[getter](button)
		if texture then Mute(texture) end
	end
	local highlight = button.GetHighlightTexture and button:GetHighlightTexture()
	if highlight then
		highlight:SetTexture(Kit.media..'glow.tga')
		highlight:SetBlendMode('ADD')
		Kit:Tint(highlight, 'lamp', 0.35)
	end
	local icon = button.icon
	if icon and icon.SetTexCoord then
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		if icon.AddMaskTexture then
			local mask = button:CreateMaskTexture()
			mask:SetTexture(MASK, 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
			mask:SetAllPoints(icon)
			icon:AddMaskTexture(mask)
		end
	end
	-- Inside the quest's area the item glows; in the key colour here.
	if button.Glow and button.Glow.SetDesaturated then
		button.Glow:SetDesaturated(true)
		Kit:Tint(button.Glow, 'lamp')
	end
	local count = button.Count
	if count and count.SetFont then Kit:Font(count, 9, 'OUTLINE', true) end
	button:HookScript('OnMouseDown', function(_, mouse)
		if mouse ~= 'LeftButton' and mouse ~= 'RightButton' then return end
		Kit:SetSprite(key.skin, 'key-down')
		Sound('down', 0.05)
	end)
	button:HookScript('OnMouseUp', function()
		Kit:SetSprite(key.skin, 'key')
		Sound('up', 0.05)
	end)
end

local function SkinRightEdge(section)
	local frames = section.usedRightEdgeFrames
	if type(frames) ~= 'table' then return end
	for _, frame in pairs(frames) do
		if type(frame) == 'table' then UI:Safe(SkinEdgeButton, frame) end
	end
end

-- Lines -------------------------------------------------------------------------------
-- Each line gets a rig of our own: above it its lamp and a halo to flash, under
-- it a small LCD glass behind its count.
local CHECK_ATLAS = 'ui-questtracker-tracker-check'
local function IsCheck(icon)
	if Forbidden(icon) then return false end
	local atlas = icon.GetAtlas and Plain(icon:GetAtlas())
	return atlas == nil or (type(atlas) == 'string' and strlower(atlas) == CHECK_ATLAS)
end

local function LineKind(key)
	if key == 'QuestComplete' or key == 'ClickComplete' then return 'ready' end
	if key == 'Failed' then return 'failed' end
	if key == 'Waypoint' then return 'waypoint' end
	return 'objective'
end

local function Complete(line, check)
	local text = line.Text
	local style = text and text.colorStyle
	local colors = _G.OBJECTIVE_TRACKER_COLOR
	if style and colors and style == colors.Complete then return true end
	local icon = check and line.Icon
	return icon and icon:IsShown() and true or false
end

local function Rig(line)
	local rig = rigs[line]
	if rig then return rig end
	-- Above the line: the lamp and the halo it flashes from.
	rig = CreateFrame('Frame', nil, line)
	rig:SetAllPoints()
	rig:EnableMouse(false)
	rig.halo = CreateFrame('Frame', nil, rig)
	rig.halo:EnableMouse(false)
	rig.halo:SetSize(5, 5)
	rig.lamp = Kit:Led(rig.halo, 5, false)
	rig.lamp:SetPoint('CENTER', rig.halo)
	-- Under it: a small LCD glass the line's own count is printed on.
	rig.back = CreateFrame('Frame', nil, line)
	rig.back:SetAllPoints()
	rig.back:EnableMouse(false)
	rig.lcd = CreateFrame('Frame', nil, rig.back)
	rig.lcd:EnableMouse(false)
	rig.lcd.glass = Kit:Texture(rig.lcd, 'round-3', 'BACKGROUND', 1)
	Kit:Place(rig.lcd.glass, rig.lcd, 0, 0, 0, 0)
	rig.lcd:Hide()
	-- Blizzard's glow sweeps and check flash give way to ours.
	Mute(line.Glow, true)
	Mute(line.CheckGlow, true)
	rigs[line] = rig
	return rig
end

local function SizeLamp(holder, lamp, size)
	holder:SetSize(size, size)
	lamp:SetSize(size, size)
	if lamp.glow then Kit:FitSprite(lamp.glow, size, size) end
end

-- "Ready for turn-in" reads in a soft green ink: lit, not loud.
local readyInk
local function ReadyInk()
	if not readyInk then
		local r, g, b = Kit:RGB('ledGreen')
		local ir, ig, ib = Kit:RGB('darkInk')
		readyInk = {r * 0.55 + ir * 0.45, g * 0.55 + ig * 0.45, b * 0.55 + ib * 0.45}
	end
	return readyInk
end

-- The LCD glass under a leading count (3/8): measured in Blizzard's own font
-- from the start of its text, one physical pixel round the digits' box. The
-- digits are Blizzard's own, so nothing can drift from them.
local function PlaceCount(rig, text, count)
	local width, height = Measure(text, count)
	if not width or not height or width <= 0 or height <= 0 then return false end
	local lcd, px = rig.lcd, Px(rig.lcd, 1)
	lcd:ClearAllPoints()
	lcd:SetPoint('TOPLEFT', text, 'TOPLEFT', -2 * px, px)
	lcd:SetSize(Snap(lcd, width) + 4 * px, Snap(lcd, height) + px)
	return true
end

local function PaintLine(block, key, line, ctx)
	if Forbidden(line) or not line.Text then return end
	local rig = Rig(line)
	local text, icon, dash = line.Text, line.Icon, line.Dash
	local db = DB()
	local kind = LineKind(key)
	local check = icon and kind ~= 'waypoint' and IsCheck(icon)
	local done = kind == 'ready' or (kind == 'objective' and Complete(line, check))
	local lamps = db.lamps ~= false
	local style = db.completed
	local under = max(line:GetFrameLevel() - 1, 0)
	rig.back:SetFrameLevel(under)
	rig.lcd:SetFrameLevel(under)
	-- The lamp takes the dash's and the check's place.
	if check then icon:SetVertexColor(1, 1, 1, lamps and 0 or 1) end
	if dash then dash:SetAlpha(lamps and 0 or 1) end
	if kind == 'waypoint' and icon and not IsCheck(icon) and icon.SetDesaturated then
		icon:SetDesaturated(true)
		Kit:Tint(icon, 'lamp')
	end
	local size = FontSize(text, 12)
	local dashText = dash and Plain(dash:GetText())
	local slot = (type(dashText) == 'string' and dashText ~= '') and 'dash' or 'margin'
	if rig.slot ~= slot or rig.size ~= size then
		rig.slot, rig.size, rig.count = slot, size, nil
		SizeLamp(rig.halo, rig.lamp, LampSize(rig.halo, size))
		rig.halo:ClearAllPoints()
		if slot == 'dash' then rig.halo:SetPoint('CENTER', dash, 'CENTER', 0, 0)
		else rig.halo:SetPoint('CENTER', text, 'TOPLEFT', -Snap(rig.halo, 5), -Snap(rig.halo, size / 2)) end
	end
	local showLamp = lamps and kind ~= 'waypoint'
	Kit:ShowLed(rig.lamp, showLamp)
	if showLamp then
		if kind == 'failed' then Kit:SetLed(rig.lamp, true, 'red')
		elseif kind == 'ready' then Kit:SetLed(rig.lamp, true, 'ledGreen')
		elseif done then Kit:SetLed(rig.lamp, true, style == 'green' and 'green' or nil)
		else Kit:SetLed(rig.lamp, false) end
	end
	if kind == 'failed' then Kit:Tint(text, 'red')
	elseif kind == 'ready' then Kit:Tint(text, ReadyInk())
	elseif kind == 'waypoint' then Kit:Tint(text, 'darkDim')
	elseif done and style == 'green' then Kit:Tint(text, 'green')
	elseif done and style == 'dim' then Kit:Tint(text, 'darkDim', 0.55)
	else Kit:Tint(text, done and 'darkInk' or 'darkDim') end

	-- A leading count (3/8) of an objective still to do sits on LCD glass.
	local raw = Plain(text:GetText())
	local parsed = kind == 'objective' and type(raw) == 'string' and raw:match('^(%d[%d,%.]*/%d[%d,%.]*)%s') or nil
	local count = db.chips ~= false and not done and parsed or nil
	if count and (rig.count ~= count) then
		if not PlaceCount(rig, text, count) then count = nil end
	end
	rig.count = count
	if count then Kit:Tint(rig.lcd.glass, Kit:DB().finish == 'graphite' and 'lcd' or 'darkEdge', 0.95) end
	rig.lcd:SetShown(count ~= nil)

	-- Changes since the last pass: a count that moved flashes its glass and
	-- ticks, a finished objective flashes its lamp with a detent.
	ctx.index = ctx.index + 1
	local id = Plain(block.id)
	if id == nil or (type(id) ~= 'number' and type(id) ~= 'string') then return end
	local stamp = tostring(id)..':'..tostring(key)
	local before, now = seen[stamp], (parsed or '')..(done and '+' or '-')
	if ctx.powering then
		if count and Moving() then
			local delay = ctx.index * 0.05
			C_Timer.After(delay, function() if rig.lcd:IsVisible() then Kit:Flash(rig.lcd, {alpha = 0.35, duration = 0.3}) end end)
		end
	elseif before and before ~= now and module.settled then
		local wasDone, oldCount = before:sub(-1) == '+', before:sub(1, -2)
		if done and not wasDone then
			Sound('detent')
			if lamps and Moving() then Kit:Flash(rig.halo, {alpha = 0.85, duration = 0.35}) end
		elseif parsed and oldCount ~= '' and oldCount ~= parsed then
			Sound('tick')
			if count and Moving() then Kit:Flash(rig.lcd, {alpha = 0.35, duration = 0.3}) end
		end
	end
	seen[stamp] = now
end

-- Blocks ------------------------------------------------------------------------------
local function TitleOf(block)
	if block.HeaderText then return block.HeaderText end
	for _, region in ipairs({block:GetRegions()}) do
		if region.IsObjectType and region:IsObjectType('FontString') then return region end
	end
end

-- Difficulty colours, blended toward the screen's ink so they sit in the palette.
local difficulty = {}
local function Difficulty(id)
	if type(id) ~= 'number' or not (C_PlayerInfo and C_PlayerInfo.GetContentDifficultyQuestForPlayer and GetDifficultyColor) then return end
	local ok, level = pcall(C_PlayerInfo.GetContentDifficultyQuestForPlayer, id)
	level = ok and Plain(level) or nil
	if level == nil then return end
	if difficulty[level] then return difficulty[level] end
	local found, color = pcall(GetDifficultyColor, level)
	if not found or type(color) ~= 'table' or type(color.r) ~= 'number' then return end
	local r, g, b = Kit:RGB('darkInk')
	difficulty[level] = {color.r * 0.65 + r * 0.35, color.g * 0.65 + g * 0.35, color.b * 0.65 + b * 0.35}
	return difficulty[level]
end

local function SweepBand(entry)
	if entry.clip then return entry.clip end
	local clip = CreateFrame('Frame', nil, entry.front)
	clip:SetClipsChildren(true)
	clip:EnableMouse(false)
	clip:SetAllPoints(entry.slab)
	local band = CreateFrame('Frame', nil, clip)
	band:EnableMouse(false)
	band.left = band:CreateTexture(nil, 'OVERLAY')
	band.right = band:CreateTexture(nil, 'OVERLAY')
	for _, half in ipairs({band.left, band.right}) do
		half:SetColorTexture(1, 1, 1, 1)
		half:SetBlendMode('ADD')
	end
	band.left:SetPoint('TOPLEFT'); band.left:SetPoint('BOTTOMRIGHT', band, 'BOTTOM')
	band.right:SetPoint('TOPLEFT', band, 'TOP'); band.right:SetPoint('BOTTOMRIGHT')
	clip.band = band
	clip:Hide()
	entry.clip = clip
	return clip
end

-- A band of lamp light runs across the title's slab.
local function Sweep(entry, token)
	if not entry.title or not Moving() then return end
	local clip = SweepBand(entry)
	local band = clip.band
	local r, g, b = Kit:RGB(token)
	band.left:SetGradient('HORIZONTAL', CreateColor(r, g, b, 0), CreateColor(r, g, b, 1))
	band.right:SetGradient('HORIZONTAL', CreateColor(r, g, b, 1), CreateColor(r, g, b, 0))
	clip:Show()
	Kit:Animate(Tag('sweep', entry), 0.55, 0, 1, function(value, progress)
		local width, height = clip:GetSize()
		if IsSecret(width) or IsSecret(height) or not width or width <= 0 then return end
		local bandWidth = max(24, width * 0.4)
		band:SetSize(bandWidth, height)
		band:ClearAllPoints()
		band:SetPoint('LEFT', clip, 'LEFT', -bandWidth + (width + bandWidth) * value, 0)
		band:SetAlpha(0.5 * sin(pi * progress) * min(1.5, Kit:Intensity()))
	end, function() clip:Hide() end, 'inout')
end

-- The lamp blinks `times` times, then the next pass paints its state.
local function Blink(entry, lamp, times, duration)
	entry.blinking = true
	Kit:Animate(Tag('blink', lamp), duration, 0, 1, function(_, progress)
		Kit:SetLed(lamp, floor(progress * times * 2) % 2 == 0)
	end, function()
		entry.blinking = nil
		module:Queue()
	end, 'linear')
end

-- A quest arrives: its title prints in, its lamp blinks and a relay closes.
local function PowerOn(entry)
	Sound('relay', 0.2)
	if not Moving() or not entry.title then return end
	PrintIn(entry.title)
	Blink(entry, entry.lamp, 3, 0.48)
	Kit:Flash(entry.key or entry.halo, {alpha = 0.8, duration = 0.45})
	entry.slab:SetAlpha(0.9)
	entry.plateTarget = nil
	Sweep(entry, 'lamp')
end

-- Every objective is done: a sweep of light, then the lamps flash down the block.
local function Completed(block, entry)
	if not Moving() then return end
	Sweep(entry, 'ledGreen')
	Kit:Flash(entry.key or entry.halo, {token = 'ledGreen', alpha = 0.9, duration = 0.5})
	if DB().lamps == false or type(block.usedLines) ~= 'table' then return end
	local list = {}
	for _, line in pairs(block.usedLines) do
		local rig = type(line) == 'table' and rigs[line]
		local top = rig and Plain(line:GetTop())
		if top then list[#list + 1] = {top, rig} end
	end
	table.sort(list, function(a, b) return a[1] > b[1] end)
	for index, item in ipairs(list) do
		C_Timer.After(0.08 + index * 0.06, function()
			if item[2]:IsVisible() then Kit:Flash(item[2].halo, {alpha = 0.7, duration = 0.3}) end
		end)
	end
end

-- A quest leaves (turned in): the lamp blinks off under a last sweep. Blizzard
-- fades the block itself.
local function PowerDown(entry)
	Sound('power-down', 0.3)
	if not Moving() then return end
	Sweep(entry, 'lamp')
	Blink(entry, entry.lamp, 2, 0.3)
end

-- A quest untracked or abandoned leaves at once: a CRT switch-off over where it
-- was, on a frame of our own above the housing.
local ghost
local function Ghost(block)
	if Forbidden(block) or not housing or not housing:IsVisible() or not block:IsVisible() then return end
	local left, bottom, width, height = block:GetRect()
	left, bottom, width, height = Plain(left), Plain(bottom), Plain(width), Plain(height)
	if not (left and bottom and width and height) or width <= 0 or height <= 0 then return end
	if not ghost then
		ghost = CreateFrame('Frame', nil, housing)
		ghost:EnableMouse(false)
		ghost.fill = ghost:CreateTexture(nil, 'ARTWORK')
		ghost.fill:SetColorTexture(1, 1, 1, 1)
		ghost.fill:SetAllPoints()
		Kit:Tint(ghost.fill, 'dark')
		ghost.line = ghost:CreateTexture(nil, 'OVERLAY')
		ghost.line:SetColorTexture(1, 1, 1, 1)
		ghost.line:SetBlendMode('ADD')
		Kit:Tint(ghost.line, 'lamp')
	end
	ghost:SetFrameLevel(housing:GetFrameLevel() + 60)
	local scale = block:GetEffectiveScale() / ghost:GetEffectiveScale()
	ghost:ClearAllPoints()
	ghost:SetPoint('BOTTOMLEFT', UIParent, 'BOTTOMLEFT', left * scale, bottom * scale)
	ghost:SetSize(width * scale, height * scale)
	ghost.line:SetHeight(Px(ghost, 2))
	ghost:Show()
	Kit:Animate(Tag('ghost', ghost), 0.28, 0, 1, function(_, progress)
		-- The picture shuts to a line, the line shrinks to a point.
		local shut = min(1, progress / 0.4)
		ghost.fill:SetAlpha(0.92 * shut * (1 - max(0, progress - 0.4) / 0.6))
		ghost.line:SetWidth(max(1, width * scale * (1 - max(0, progress - 0.4) / 0.6)))
		ghost.line:SetAlpha(shut * (1 - progress * 0.6))
		ghost.line:ClearAllPoints()
		ghost.line:SetPoint('CENTER', ghost, 'CENTER')
	end, function() ghost:Hide() end, 'linear')
end

local function Block(block)
	local entry = blocks[block]
	if entry then return entry end
	entry = {title = TitleOf(block)}
	blocks[block] = entry
	for _, part in ipairs({'Background', 'HeaderBackground', 'Stripe', 'Sheen', 'Glow', 'ShineTop', 'ShineBottom', 'HeaderGlow'}) do
		Mute(block[part], true)
	end
	-- Under the title, one level below the block's text: a slab of dark glass
	-- (a fill, a low wash and a thin state edge on its left) and a hover glow.
	entry.back = CreateFrame('Frame', nil, block)
	entry.back:SetAllPoints()
	entry.back:EnableMouse(false)
	entry.slab = CreateFrame('Frame', nil, entry.back)
	entry.slab:EnableMouse(false)
	entry.slab:SetAlpha(0)
	entry.fill = entry.slab:CreateTexture(nil, 'BACKGROUND', nil, 1)
	entry.fill:SetAllPoints()
	entry.wash = entry.slab:CreateTexture(nil, 'BACKGROUND', nil, 2)
	entry.wash:SetAllPoints()
	entry.edge = entry.slab:CreateTexture(nil, 'BACKGROUND', nil, 3)
	entry.edge:SetPoint('TOPLEFT')
	entry.edge:SetPoint('BOTTOMLEFT')
	entry.glow = Kit:Texture(entry.back, 'glow', 'BACKGROUND', 0)
	entry.glow:SetAlpha(0)
	Kit:Tint(entry.glow, 'lamp')
	-- Over it: the title's lamp (for blocks without a quest key) and its halo.
	entry.front = CreateFrame('Frame', nil, block)
	entry.front:SetAllPoints()
	entry.front:EnableMouse(false)
	entry.halo = CreateFrame('Frame', nil, entry.front)
	entry.halo:EnableMouse(false)
	entry.halo:SetSize(5, 5)
	entry.lamp = Kit:Led(entry.halo, 5, false)
	entry.lamp:SetPoint('CENTER', entry.halo)
	return entry
end

-- The slab starts just right of the quest key's column and ends at the title's
-- right edge (left of any item key), on whole physical pixels.
local function PlaceSlab(entry, lift)
	local title, slab = entry.title, entry.slab
	local pad = Px(slab, PLATE_PAD[DB().density] or 2)
	slab:ClearAllPoints()
	slab:SetPoint('TOPLEFT', title, 'TOPLEFT', -Snap(slab, 4), pad + lift)
	slab:SetPoint('BOTTOMRIGHT', title, 'BOTTOMRIGHT', 0, -pad + lift)
	entry.edge:SetWidth(Px(slab, 2))
	entry.glow:ClearAllPoints()
	entry.glow:SetPoint('TOPLEFT', slab, 'TOPLEFT', -8, 8)
	entry.glow:SetPoint('BOTTOMRIGHT', slab, 'BOTTOMRIGHT', 8, -8)
end

-- Quest keys -----------------------------------------------------------------------------
-- Blizzard's round quest buttons (the ? ! and ... left of each title) become
-- small SPEC-01 round keys: our key and ring under Blizzard's glyph, its own
-- ring art quiet, the glyph monochrome. Lit in the key colour when focused,
-- green when ready to turn in, red if failed. Style only: they are pooled, so
-- nothing is moved and everything is set again on each pass.
local POI_ART = {'NormalTexture', 'PushedTexture', 'HighlightTexture', 'Glow', 'UnderlayAtlas', 'UnderlayBannerAtlas',
	'UnderlayBannerAtlasHighlight'}
local POI_TOKENS = {focus = 'lamp', complete = 'ledGreen', failed = 'red'}
local function DressPOI(button, state)
	local dress = pois[button]
	if not dress then
		dress = CreateFrame('Frame', nil, button)
		dress:EnableMouse(false)
		dress:SetPoint('CENTER')
		dress.glow = Kit:Texture(dress, 'glow', 'BACKGROUND', -1)
		dress.glow:SetPoint('TOPLEFT', -6, 6)
		dress.glow:SetPoint('BOTTOMRIGHT', 6, -6)
		dress.glow:SetAlpha(0)
		dress.skin = Kit:Skin(dress, 'key-round', 'BACKGROUND', 0)
		dress.ring = Kit:Texture(dress, 'circle-ring', 'ARTWORK', 0)
		dress.ring:SetAllPoints()
		button:HookScript('OnEnter', function() dress.hover = true; Kit:FadeTo(dress.glow, 0.25, 'FAST') end)
		button:HookScript('OnLeave', function() dress.hover = nil; Kit:FadeTo(dress.glow, dress.lit or 0, 'FAST') end)
		pois[button] = dress
	end
	-- Just under Blizzard's glyph layer, above the button's own (quiet) art.
	dress:SetFrameLevel(max(button:GetFrameLevel(), 1))
	local size = Snap(dress, 17)
	if dress.size ~= size then
		dress.size = size
		dress:SetSize(size, size)
	end
	for _, key in ipairs(POI_ART) do
		local region = button[key]
		if not Forbidden(region) and region.SetVertexColor then region:SetVertexColor(1, 1, 1, 0) end
	end
	local token = POI_TOKENS[state]
	local glyph = button.Display and button.Display.Icon
	if not Forbidden(glyph) and glyph.SetDesaturated then
		glyph:SetDesaturated(true)
		local r, g, b = Kit:RGB(token or 'ink')
		glyph:SetVertexColor(r, g, b, 1)
	end
	local r, g, b = Kit:RGB(token or 'keyEdge')
	dress.ring:SetVertexColor(r, g, b, token and 1 or 0.6)
	Kit:Tint(dress.glow, token or 'lamp')
	dress.lit = token and 0.18 or 0
	if not dress.hover then Kit:FadeTo(dress.glow, dress.lit, 'FAST') end
end

local function PaintTitle(block, entry, ctx)
	local title = entry.title
	if not title then return end
	local db = DB()
	local id = Plain(block.id)
	local quest = entry.kind ~= nil and type(id) == 'number'
	local log = C_QuestLog
	local focused = quest and ctx.focus == id
	local complete = quest and log and log.IsComplete and Plain(log.IsComplete(id)) == true or false
	local failed = quest and log and log.IsFailed and Plain(log.IsFailed(id)) == true or false
	local state = failed and 'failed' or focused and 'focus' or complete and 'complete' or nil
	local hover = entry.hover
	local token
	if hover or focused then token = 'lamp'
	elseif failed then token = 'red'
	elseif db.titleColor == 'difficulty' and quest then token = Difficulty(id) or 'darkInk'
	else token = 'darkInk' end
	Kit:Tint(title, token)

	-- One status light per quest: its quest key when it has one, else our lamp.
	local named = (Plain(title:GetText()) or '') ~= ''
	local poi = block.poiButton
	local keyed = not Forbidden(poi) and poi:IsShown()
	if keyed then UI:Safe(DressPOI, poi, state) end
	entry.key = keyed and pois[poi] or nil
	local size = FontSize(title, 12)
	if entry.size ~= size then
		entry.size = size
		SizeLamp(entry.halo, entry.lamp, LampSize(entry.halo, size))
		entry.halo:ClearAllPoints()
		entry.halo:SetPoint('CENTER', title, 'TOPLEFT', -Snap(entry.halo, 9), -Snap(entry.halo, size / 2))
	end
	Kit:ShowLed(entry.lamp, named and not keyed and db.lamps ~= false)
	if not entry.blinking then
		Kit:SetLed(entry.lamp, state ~= nil, state == 'failed' and 'red' or state == 'complete' and 'ledGreen' or nil)
	end
	if focused and entry.focus ~= id and module.settled and Moving() then
		Kit:Flash(entry.key or entry.halo, {alpha = 0.6, duration = 0.4})
	end
	entry.focus = focused and id or nil

	-- The slab: dark glass with a thin edge in the state's colour (key colour
	-- when focused, green when ready, red if failed) and the faintest wash of
	-- it; on hover it lifts two physical pixels with a soft lamp glow.
	local edge = state and POI_TOKENS[state]
	local target = not named and 0 or (hover or state) and 1 or 0
	Fill(entry.fill, hover and 'darkEdge' or 'glass', hover and 0.6 or 0.45)
	Fill(entry.wash, edge or 'lamp', edge and 0.05 or 0)
	Fill(entry.edge, edge or 'darkEdge', edge and 0.9 or 0)
	if entry.plateTarget ~= target or entry.lifted ~= (hover or false) then
		entry.plateTarget, entry.lifted = target, hover or false
		PlaceSlab(entry, hover and Px(entry.slab, 2) or 0)
		Kit:FadeTo(entry.slab, target, 'FAST')
		Kit:FadeTo(entry.glow, (hover and named) and 0.14 * min(1.5, Kit:Intensity()) or 0, 'FAST')
	end

	-- A quest that has just finished gets its sweep.
	if quest then
		local before = questDone[id]
		questDone[id] = complete
		if complete and before == false and module.settled and not ctx.powering then Completed(block, entry) end
	end
end

local function PaintBlock(block, entry, ctx)
	local under = max(block:GetFrameLevel() - 1, 0)
	entry.back:SetFrameLevel(under)
	entry.slab:SetFrameLevel(under)
	PaintTitle(block, entry, ctx)
	ctx.index = 0
	local lines = block.usedLines
	if type(lines) == 'table' then
		for key, line in pairs(lines) do
			if type(line) == 'table' then UI:Safe(PaintLine, block, key, line, ctx) end
		end
	end
end

-- The quest focused by the game, read once per pass.
local context = {}
local function Context()
	local id = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID()
	context.focus, context.powering, context.index = Plain(id), false, 0
	return context
end

function module.PaintBlock(block)
	local entry = blocks[block]
	if entry and not Forbidden(block) then PaintBlock(block, entry, Context()) end
end

local function HoverHooks(block)
	if hooked[block] then return end
	hooked[block] = true
	-- Blizzard repaints the block on hover; ours lands one frame later.
	local function Hover(on)
		C_Timer.After(0, function()
			local entry = blocks[block]
			if entry then
				entry.hover = on
				UI:Safe(module.PaintBlock, block)
			end
		end)
	end
	local button = block.HeaderButton
	for _, frame in ipairs({block, button}) do
		if not Forbidden(frame) and frame.HookScript then
			frame:HookScript('OnEnter', function() Hover(true) end)
			frame:HookScript('OnLeave', function() Hover(false) end)
		end
	end
	if not Forbidden(button) and button.HookScript then
		button:HookScript('OnMouseDown', function() Sound('down', 0.05) end)
		button:HookScript('OnMouseUp', function() Sound('up', 0.05) end)
	end
end

local function SkinBlock(block, section, ctx)
	if Forbidden(block) or not block.HeaderText then return false end
	local entry = Block(block)
	HoverHooks(block)
	entry.kind = KIND[section]
	local id = Plain(block.id)
	ctx.powering = false
	if id ~= nil and fresh[id] then
		fresh[id] = nil
		ctx.powering = module.settled and true or false
	end
	PaintBlock(block, entry, ctx)
	if ctx.powering then PowerOn(entry) end
	ctx.powering = false
	return true
end

local function SkinBlocks(section, ctx)
	if POOLED[section] or type(section.usedBlocks) ~= 'table' then return end
	local n = 0
	for _, byTemplate in pairs(section.usedBlocks) do
		if type(byTemplate) == 'table' then
			for _, block in pairs(byTemplate) do
				if type(block) == 'table' then
					local ok, counted = pcall(SkinBlock, block, section, ctx)
					if not ok and geterrorhandler then geterrorhandler()(counted) end
					if ok and counted then n = n + 1 end
				end
			end
		end
	end
	-- A folded section shows the count it had while open.
	if not section.isCollapsed then counts[section] = n end
	SkinRightEdge(section)
	SkinBars(section)
end

-- Headers ---------------------------------------------------------------------------
local function IsCollapsed(header)
	local tracker = Tracker()
	if header == MasterHeader() then return tracker and tracker.isCollapsed end
	local section = header:GetParent()
	return header.isCollapsed or (section and section.isCollapsed)
end

-- The round key: its chevron drops in on the detent curve when it turns.
local function PaintChevron(header, collapsed, animate)
	local entry = headers[header]
	local key = entry and entry.key
	if not key then return end
	Kit:SetIcon(key.icon, collapsed and 'chevron-down' or 'chevron-up')
	local direction = collapsed and 1 or -1
	Kit:Animate(Tag('chevron', key), (animate and Moving()) and 0.18 or 0, 0, 1, function(value)
		key.icon:SetPoint('CENTER', 0, direction * 3 * (1 - value))
		key.icon:SetAlpha(value)
	end, function()
		key.icon:SetPoint('CENTER', 0, 0)
		key.icon:SetAlpha(1)
	end, 'detent')
end

local function RoundKey(button)
	for _, getter in ipairs({'GetNormalTexture', 'GetPushedTexture', 'GetHighlightTexture', 'GetDisabledTexture'}) do
		local texture = button[getter] and button[getter](button)
		if texture then Mute(texture) end
	end
	local key = CreateFrame('Frame', nil, button)
	key:SetSize(16, 16)
	key:SetPoint('CENTER')
	key:EnableMouse(false)
	key.skin = Kit:Skin(key, 'key-round', 'ARTWORK', 0)
	key.glow = Kit:Texture(key, 'glow', 'BACKGROUND', -1)
	key.glow:SetPoint('TOPLEFT', -7, 7)
	key.glow:SetPoint('BOTTOMRIGHT', 7, -7)
	key.glow:SetAlpha(0)
	Kit:Tint(key.glow, 'lamp')
	key.icon = Kit:Icon(key, 'chevron-up', 8, 'ink')
	key.icon:SetPoint('CENTER')
	local function Press(down) Kit:SetSprite(key.skin, down and 'key-round-down' or 'key-round') end
	button:HookScript('OnEnter', function() Kit:FadeTo(key.glow, 0.22 * min(1.5, Kit:Intensity()), 'FAST') end)
	button:HookScript('OnLeave', function() Kit:FadeTo(key.glow, 0, 'FAST'); Press(false) end)
	button:HookScript('OnMouseDown', function(_, mouse) if mouse == 'LeftButton' then Press(true) end end)
	button:HookScript('OnMouseUp', function() Press(false) end)
	return key
end

-- The header font's size, and the section code's (a little over half of it).
local function HeaderSize()
	local font, size = _G.ObjectiveTrackerHeaderFont, nil
	if font and font.GetFont then
		local _, got = font:GetFont()
		size = Plain(got)
	end
	size = type(size) == 'number' and size or 14
	return size, max(7, floor(size * 0.6 + 0.5))
end

-- A section band is Blizzard's own name (in the tracker's header font, so
-- there is one label, never two), a hairline rule after it, the dim section
-- code, a folded count and the round key, all on the band's centre line.
local function SkinHeader(header, code, section)
	if Forbidden(header) or headers[header] then return end
	local master = header == MasterHeader()
	local entry = {master = master, section = section}
	headers[header] = entry
	for _, part in ipairs({'Background', 'Line', 'LineSheen', 'LineGlow', 'Divider', 'Sheen', 'Glow', 'Shine', 'Stripe'}) do
		Mute(header[part], true)
	end
	local button = header.MinimizeButton
	if not Forbidden(button) then entry.key = RoundKey(button) end
	if not master then
		entry.code = Kit:Label(header, code or '', 'darkDim', 8, true)
		entry.code:SetWordWrap(false)
		entry.rule = header:CreateTexture(nil, 'ARTWORK')
		entry.rule:SetColorTexture(1, 1, 1, 1)
		Kit:Tint(entry.rule, 'darkEdge')
		entry.count = Chip(header, 8)
		entry.count:SetHeight(12)
		if entry.key then entry.count:SetPoint('RIGHT', entry.key, 'LEFT', -Snap(header, 5), 0)
		else entry.count:SetPoint('RIGHT', header, 'RIGHT', -Snap(header, 4), 0) end
	end
	PaintChevron(header, IsCollapsed(header), false)
	if header.SetCollapsed then
		hooksecurefunc(header, 'SetCollapsed', function(self, collapsed)
			C_Timer.After(0, function()
				UI:Safe(PaintChevron, self, collapsed, true)
				Sound(collapsed and 'latch-up' or 'latch-down')
				module:Queue()
			end)
		end)
	end
end

function module.PaintHeader(header)
	local entry = headers[header]
	if not entry then return end
	local db = DB()
	local text = header.Text
	if entry.master then
		if text then text:SetAlpha(db.housing ~= false and 0 or 1) end
		return
	end
	if text then
		text:SetAlpha(1)
		Kit:Tint(text, 'darkInk')
	end
	local style = db.headerStyle or 'code'
	local textSize, codeSize = HeaderSize()
	local collapsed = IsCollapsed(header)
	local n = counts[entry.section]
	local folded = collapsed and type(n) == 'number' and n > 0 or false
	if folded then SetChip(entry.count, format('%02d', min(n, 99)), 8, true) end
	entry.count:SetShown(folded)
	-- The code sits left of the count (or the key), its baseline on the name's.
	local right = folded and entry.count or entry.key or false
	if entry.style ~= style or entry.codeSize ~= codeSize or entry.codeTo ~= right then
		entry.style, entry.codeSize, entry.codeTo, entry.ruleTo = style, codeSize, right, nil
		Kit:Font(entry.code, codeSize, '', true)
		local drop = -Snap(header, (textSize - codeSize) * 0.3)
		entry.code:ClearAllPoints()
		if right then entry.code:SetPoint('RIGHT', right, 'LEFT', -Snap(header, 6), drop)
		else entry.code:SetPoint('RIGHT', header, 'RIGHT', -Snap(header, 6), drop) end
		entry.code:SetShown(style == 'code')
	end
	-- The rule runs from the end of the name to the code (or the count or key);
	-- a name too long for one leaves it out.
	local width = text and Plain(text:GetStringWidth())
	local headerWidth = Plain(header:GetWidth())
	local showRule = style ~= 'plain' and type(width) == 'number' and type(headerWidth) == 'number'
	if showRule then
		local used = 7 + width + 6 + 6 + 22 + (folded and 26 or 0) + (style == 'code' and (Plain(entry.code:GetStringWidth()) or 0) + 6 or 0)
		showRule = headerWidth - used >= 8
	end
	local ruleTo = style == 'code' and entry.code or right
	if showRule and (entry.ruleTo ~= ruleTo or entry.nameWidth ~= width) then
		entry.ruleTo, entry.nameWidth = ruleTo, width
		entry.rule:ClearAllPoints()
		entry.rule:SetPoint('LEFT', text, 'LEFT', Snap(header, width + 7), 0)
		if ruleTo then entry.rule:SetPoint('RIGHT', ruleTo, 'LEFT', -Snap(header, 6), 0)
		else entry.rule:SetPoint('RIGHT', header, 'RIGHT', -Snap(header, 6), 0) end
	end
	entry.rule:SetHeight(Px(header, 1))
	entry.rule:SetShown(showRule and true or false)
end

-- Housing -----------------------------------------------------------------------------
-- Gutters from the tracker's edges to the housing's, in UI units.
local HOUSE_L, HOUSE_R, HOUSE_T, HOUSE_B = 12, 11, 2, 10

local function CounterText()
	local mode = DB().counter or 'tracked'
	local log = C_QuestLog
	if mode == 'log' and log and log.GetNumQuestLogEntries then
		local _, quests = log.GetNumQuestLogEntries()
		local most = log.GetMaxNumQuestsCanAccept and log.GetMaxNumQuestsCanAccept()
		quests, most = Plain(quests), Plain(most)
		if type(quests) ~= 'number' then return end
		if type(most) == 'number' and most > 0 then return format('%02d/%02d', quests, most), 'LOG' end
		return format('%02d', quests), 'LOG'
	elseif mode == 'tracked' then
		local count = log and log.GetNumQuestWatches and log.GetNumQuestWatches() or (GetNumQuestWatches and GetNumQuestWatches())
		count = Plain(count)
		if type(count) == 'number' then return format('%02d', count), 'TRK' end
	end
end

-- The lowest section showing, found by order only: sections are laid out top
-- to bottom in the tracker's module order. The widget section is skipped.
local function LowestSection(tracker)
	local list, lowest = tracker.modules or tracker.MODULES, nil
	if type(list) ~= 'table' then return end
	for _, section in ipairs(list) do
		if section ~= _G.UIWidgetObjectiveTracker and not Forbidden(section) and section.IsShown and section:IsShown() then
			lowest = section
		end
	end
	return lowest
end

local function BuildHousing()
	if housing then return housing end
	local tracker = Tracker()
	housing = Kit:Device(UIParent, {model = 'OT-1', title = 'Objectives', surface = 'dark', corner = 10})
	housing:SetFrameStrata(tracker:GetFrameStrata() or 'MEDIUM')
	housing:SetFrameLevel(max(tracker:GetFrameLevel() - 1, 1))
	Kit:Relevel(housing)
	housing:EnableMouse(false)
	housing.counter = Chip(housing, 9)
	housing.counter:SetHeight(14)
	housing.legend = Kit:Label(housing, '', 'darkDim', 8, true)
	housing.legend:SetPoint('RIGHT', housing.counter, 'LEFT', -4, 0)
	housing.rule = housing:CreateTexture(nil, 'ARTWORK')
	housing.rule:SetColorTexture(1, 1, 1, 1)
	Kit:Tint(housing.rule, 'darkEdge')
	housing:Hide()
	return housing
end

-- The printed header sits on the tracker header's centre line, the counter
-- left of its key; anchored once each time that key is first seen.
local function AlignHeader(header)
	local entry = header and headers[header]
	local key = entry and entry.key or false
	-- Some clients show a filter button left of the key; the counter clears it.
	local filter = header and header.FilterButton
	if not Forbidden(filter) and filter:IsShown() then key = filter end
	if housing.alignedTo == (header or false) and housing.keyTo == key then return end
	housing.alignedTo, housing.keyTo = header or false, key
	housing.counter:ClearAllPoints()
	if key then housing.counter:SetPoint('RIGHT', key, 'LEFT', -6, 0)
	elseif header then housing.counter:SetPoint('RIGHT', header, 'RIGHT', -2, 0)
	else housing.counter:SetPoint('TOPRIGHT', housing, 'TOPRIGHT', -10, -7) end
	if not header then return end
	housing.lamp:ClearAllPoints()
	housing.lamp:SetPoint('LEFT', header, 'LEFT', 10 - HOUSE_L, 0)
	housing.title:ClearAllPoints()
	housing.title:SetPoint('LEFT', housing.model, 'RIGHT', 5, 0)
	housing.title:SetPoint('RIGHT', housing.legend, 'LEFT', -6, 0)
	housing.rule:ClearAllPoints()
	housing.rule:SetPoint('TOP', header, 'BOTTOM', 0, 0)
	housing.rule:SetPoint('LEFT', housing, 'LEFT', 10, 0)
	housing.rule:SetPoint('RIGHT', housing, 'RIGHT', -10, 0)
end

local function LayoutHousing()
	local tracker, header = Tracker(), MasterHeader()
	if not housing or not tracker then return end
	local alpha = tracker:GetAlpha()
	local shown = DB().housing ~= false and not module.faded and tracker:IsShown() and not IsSecret(alpha)
		and alpha > 0 and (not header or header:IsShown())
	if not shown then
		housing:Hide()
		return
	end
	local lowest = not tracker.isCollapsed and LowestSection(tracker) or nil
	housing:ClearAllPoints()
	housing:SetPoint('TOPLEFT', tracker, 'TOPLEFT', -HOUSE_L, HOUSE_T)
	housing:SetPoint('TOPRIGHT', tracker, 'TOPRIGHT', HOUSE_R, HOUSE_T)
	if lowest then
		housing:SetPoint('BOTTOM', lowest, 'BOTTOM', 0, -HOUSE_B)
	elseif header then
		housing:SetPoint('BOTTOM', header, 'BOTTOM', 0, -6)
	else
		housing:SetHeight(32)
	end
	AlignHeader(header)
	housing.rule:SetHeight(Px(housing, 1))
	housing.rule:SetShown(header ~= nil and lowest ~= nil)
	local text, legend = CounterText()
	if text then
		-- A new count prints itself in.
		if SetChip(housing.counter, text, 9, true) and housing:IsShown() then PrintChip(housing.counter) end
	end
	housing.counter:SetShown(text ~= nil)
	housing.legend:SetText(text and legend or '')
	-- The lamp is lit while the tracker is open and has something in it.
	Kit:SetLed(housing.lamp, lowest ~= nil)
	if not housing:IsShown() then
		housing:SetAlpha(0)
		housing:Show()
		Kit:FadeTo(housing, 1, 'NORMAL')
	end
end

-- Fading out ------------------------------------------------------------------------------
-- In a fight, a boss encounter or an instance the tracker can fade away. Alpha
-- only: collapsing it from our code would taint its secure item buttons. The
-- items stay where they are and keep working.
local inCombat, inEncounter, inInstance = false, false, false
local function ApplyFade()
	local tracker = Tracker()
	if Forbidden(tracker) then return end
	local db = DB()
	local fade = (db.hideCombat and inCombat) or (db.hideBoss and inEncounter) or (db.hideInstance and inInstance) or false
	if fade == (module.faded or false) then return end
	module.faded = fade
	Kit:FadeTo(tracker, fade and 0 or 1, 'NORMAL')
	if housing then
		if fade then Kit:FadeTo(housing, 0, 'NORMAL', function() if module.faded then housing:Hide() end end)
		else C_Timer.After(0, function() UI:Safe(module.Layout) end) end
	end
end

local function CheckInstance()
	local ok, inside, kind = pcall(IsInInstance)
	inInstance = ok and not IsSecret(inside) and inside and kind ~= 'none' and true or false
end

-- Finished quests can leave the tracker by themselves (they stay in the log).
local function UntrackDone()
	if not DB().untrackDone or InCombatLockdown() or not C_QuestLog then return end
	local log = C_QuestLog
	if not (log.GetNumQuestWatches and log.GetQuestIDForQuestWatchIndex and log.IsComplete and log.RemoveQuestWatch) then return end
	for index = log.GetNumQuestWatches(), 1, -1 do
		local questID = log.GetQuestIDForQuestWatchIndex(index)
		if not IsSecret(questID) and questID and Plain(log.IsComplete(questID)) == true then log.RemoveQuestWatch(questID) end
	end
end

-- Quests arriving and leaving ------------------------------------------------------------
local function FindBlock(id)
	for _, info in ipairs(SECTIONS) do
		local section = info[4] == 'watch' and _G[info[1]]
		if type(section) == 'table' and type(section.usedBlocks) == 'table' then
			for _, byTemplate in pairs(section.usedBlocks) do
				local block = type(byTemplate) == 'table' and byTemplate[id]
				if type(block) == 'table' then return block end
			end
		end
	end
end

local function QuestEvent(event, first, second)
	local id = Plain(event == 'QUEST_ACCEPTED' and (second or first) or first)
	if type(id) ~= 'number' then return end
	local now = GetTime()
	if event == 'QUEST_ACCEPTED' or (event == 'QUEST_WATCH_LIST_CHANGED' and Plain(second) == true) then
		fresh[id] = now
		return
	end
	if event == 'QUEST_WATCH_LIST_CHANGED' and Plain(second) ~= false then return end
	-- Turned in, abandoned or untracked: once per quest, however many events say so.
	if now - (leaving[id] or 0) < 2 then return end
	leaving[id] = now
	local block = FindBlock(id)
	local entry = block and blocks[block]
	if not entry or Forbidden(block) or not block:IsVisible() then return end
	if event == 'QUEST_TURNED_IN' then
		PowerDown(entry)
	else
		Sound('power-down', 0.3)
		if Moving() then Ghost(block) end
	end
end

-- Passes ---------------------------------------------------------------------------------
local function Sections()
	local list, found = {}, {}
	local tracker = Tracker()
	local modules = tracker and (tracker.modules or tracker.MODULES)
	if type(modules) == 'table' then
		for _, section in ipairs(modules) do
			if type(section) == 'table' and not found[section] then found[section] = true; list[#list + 1] = section end
		end
	end
	for _, info in ipairs(SECTIONS) do
		local section = _G[info[1]]
		if type(section) == 'table' and not found[section] then found[section] = true; list[#list + 1] = section end
	end
	return list
end

local function Pass()
	local tracker = Tracker()
	if Forbidden(tracker) then return end
	BuildHousing()
	Mute(tracker.NineSlice)
	local now = GetTime()
	for id, at in pairs(fresh) do
		if now - at > 6 then fresh[id] = nil end
	end
	local ctx = Context()
	local header = MasterHeader()
	if header then
		UI:Safe(SkinHeader, header)
		UI:Safe(module.PaintHeader, header)
	end
	for _, section in ipairs(Sections()) do
		if not Forbidden(section) then
			if section.Header then UI:Safe(SkinHeader, section.Header, CODES[section] or '', section) end
			UI:Safe(SkinBlocks, section, ctx)
			if section.Header then UI:Safe(module.PaintHeader, section.Header) end
		end
	end
	LayoutHousing()
end
module.Layout = LayoutHousing

local pending
function module:Queue()
	if pending then return end
	pending = true
	C_Timer.After(0, function()
		pending = nil
		UI:Safe(Pass)
	end)
end

local function Queue() module:Queue() end

-- After a setting or the typeface changes, everything measures again.
local function Invalidate()
	wipe(difficulty)
	readyInk = nil
	for _, entry in pairs(headers) do entry.style, entry.ruleTo = nil, nil end
	for _, entry in pairs(blocks) do entry.size, entry.plateTarget = nil, nil end
	for _, rig in pairs(rigs) do rig.slot, rig.count = nil, nil end
	for _, chip in pairs(timers) do chip.text = nil end
	if housing then housing.counter.text = nil end
end

local function HookSection(section)
	if Forbidden(section) or hooked[section] then return end
	hooked[section] = true
	for _, method in ipairs({'Update', 'AddBlock', 'GetProgressBar', 'GetTimerBar'}) do
		if type(section[method]) == 'function' then hooksecurefunc(section, method, Queue) end
	end
end

local function Start()
	local tracker = Tracker()
	if Forbidden(tracker) or module.started then return end
	module.started = true
	for _, info in ipairs(SECTIONS) do
		local section = _G[info[1]]
		if type(section) == 'table' then
			CODES[section] = info[2]
			if info[3] then POOLED[section] = true end
			KIND[section] = info[4]
		end
	end
	SetTypeface()
	Kit:OnRefresh(function()
		SetTypeface()
		Invalidate()
		Queue()
	end)
	for _, section in ipairs(Sections()) do HookSection(section) end
	-- Sections join the tracker after login (and addons add their own).
	if type(tracker.AddModule) == 'function' then
		hooksecurefunc(tracker, 'AddModule', function(_, section)
			C_Timer.After(0, function()
				if type(section) == 'table' and not CODES[section] then CODES[section] = 'OT-'..(#Sections()) end
				HookSection(section)
				Queue()
			end)
		end)
	end
	if type(tracker.Update) == 'function' then hooksecurefunc(tracker, 'Update', Queue) end
	Pass()
	-- Objectives on screen at login are not new.
	C_Timer.After(2, function() module.settled = true end)
	-- Edit Mode, instances and cinematics show and hide the tracker without an
	-- event of its own; a light check keeps the housing in step.
	C_Timer.NewTicker(0.5, function() UI:Safe(LayoutHousing) end)
end

local QUEST_EVENTS = {QUEST_ACCEPTED = true, QUEST_TURNED_IN = true, QUEST_REMOVED = true, QUEST_WATCH_LIST_CHANGED = true}

function module:Enable()
	local driver = CreateFrame('Frame')
	for _, event in ipairs({'QUEST_LOG_UPDATE', 'QUEST_WATCH_LIST_CHANGED', 'SCENARIO_UPDATE', 'SCENARIO_CRITERIA_UPDATE',
		'TRACKED_ACHIEVEMENT_LIST_CHANGED', 'TRACKED_RECIPE_UPDATE', 'SUPER_TRACKING_CHANGED', 'PLAYER_ENTERING_WORLD',
		'PLAYER_REGEN_ENABLED', 'PLAYER_REGEN_DISABLED', 'ENCOUNTER_START', 'ENCOUNTER_END', 'ZONE_CHANGED_NEW_AREA', 'ADDON_LOADED',
		'QUEST_ACCEPTED', 'QUEST_TURNED_IN', 'QUEST_REMOVED'}) do
		pcall(driver.RegisterEvent, driver, event)
	end
	driver:SetScript('OnEvent', function(_, event, first, second)
		if event == 'ADDON_LOADED' then
			if first == 'Blizzard_ObjectiveTracker' then UI:Safe(Start) end
			return
		end
		if QUEST_EVENTS[event] and module.started then UI:Safe(QuestEvent, event, first, second) end
		-- The fight starts before lockdown does, so trust the event.
		if event == 'PLAYER_REGEN_DISABLED' then inCombat = true
		elseif event == 'PLAYER_REGEN_ENABLED' then inCombat = false; UI:Safe(UntrackDone)
		elseif event == 'ENCOUNTER_START' then inEncounter = true
		elseif event == 'ENCOUNTER_END' then inEncounter = false
		elseif event == 'PLAYER_ENTERING_WORLD' or event == 'ZONE_CHANGED_NEW_AREA' then CheckInstance(); inEncounter = false
		elseif event == 'QUEST_LOG_UPDATE' then UI:Safe(UntrackDone) end
		if module.started then
			UI:Safe(ApplyFade)
			if event ~= 'PLAYER_REGEN_DISABLED' and event ~= 'ENCOUNTER_START' and event ~= 'ENCOUNTER_END' then Queue() end
		end
	end)
	CheckInstance()
	inCombat = InCombatLockdown() and true or false
	if Tracker() then Start() end
	if module.started then UI:Safe(ApplyFade) end
end

function module:Refresh()
	if not module.started then return end
	SetTypeface()
	Invalidate()
	for header in pairs(headers) do UI:Safe(module.PaintHeader, header) end
	UI:Safe(ApplyFade)
	UI:Safe(UntrackDone)
	Queue()
end

local SINCE = '0.5.2'
UI:RegisterPage('objectives', {title = 'Objectives', order = 15, cards = {
	{title = 'Style', rows = {
		{'segmented', 'Style', 'style.objectives', items = {{'device', 'Device'}, {'blizzard', 'Blizzard'}}, reload = true,
			note = 'The tracker as an OT-1 instrument panel: printed section bands, lamps, LCD counts and dot meters.'},
		{'switch', 'Housing', 'objectives.housing', 'The dark OT-1 device behind the tracker.'},
		{'segmented', 'Header counter', 'objectives.counter', items = {{'tracked', 'Tracked'}, {'log', 'Quest log'}, {'off', 'Off'}},
			note = 'The LCD in the housing\'s header: quests you track, or quests in your log out of the most you can hold.', since = SINCE},
		{'switch', 'Objective lamps', 'objectives.lamps', 'A lamp in place of each dash and check, lit once the objective is done. Each quest\'s round key lights in the key colour when focused, green when ready to turn in.', since = SINCE},
		{'switch', 'LCD counters', 'objectives.chips', 'Counts such as 3/8 sit on a small LCD glass while the objective is open; quest timers read on an LCD chip.', since = SINCE},
		{'note', 'Place and size the tracker with Edit Mode; the housing follows it.'},
	}},
	{title = 'Text', rows = {
		{'slider', 'Text size', 'objectives.textOffset', -3, 4, 1, 'Quest titles and objective lines, in points from the game\'s size.',
			format = function(v) return v > 0 and ('+'..v) or tostring(v) end},
		{'slider', 'Header size', 'objectives.headerOffset', -3, 4, 1, nil, format = function(v) return v > 0 and ('+'..v) or tostring(v) end},
		{'segmented', 'Density', 'objectives.density', items = {{'compact', 'Compact'}, {'normal', 'Normal'}, {'roomy', 'Roomy'}},
			note = 'Space between wrapped lines and round the plates, for wide typefaces. Applies as the tracker next lays out.', since = SINCE},
		{'segmented', 'Section headers', 'objectives.headerStyle', items = {{'code', 'Code'}, {'rule', 'Rule'}, {'plain', 'Plain'}},
			note = 'A dim section code and a rule, the rule alone, or just the name.'},
		{'segmented', 'Quest titles', 'objectives.titleColor', items = {{'ink', 'Ink'}, {'difficulty', 'Difficulty'}},
			note = 'Titles in the screen\'s ink, or tinted by the quest\'s difficulty for your level.', since = SINCE},
		{'segmented', 'Done objectives', 'objectives.completed', items = {{'lit', 'Lit'}, {'dim', 'Dim'}, {'green', 'Green'}},
			note = 'A finished objective keeps a lit lamp and bright text, fades back, or turns green.'},
		{'switch', 'Untrack finished quests', 'objectives.untrackDone', 'A quest leaves the tracker once every objective is done; it stays in your quest log.'},
	}},
	{title = 'Motion and sound', rows = {
		{'switch', 'Tracker motion', 'objectives.motion', 'A new quest powers on, a count prints its new value, a finished quest gets a lamp sweep and one that leaves powers down. Off with Reduce motion.', since = SINCE},
		{'switch', 'Tracker sounds', 'objectives.sounds', 'A relay as a quest arrives, a tick as a count moves, a detent as an objective is done, latches as sections fold and a power-down as a quest leaves.', since = SINCE},
		{'switch', 'Interface sounds', 'sound.interface', 'Every interface sound, the tracker\'s included (also on the Sounds page).'},
		{'note', 'The chime when a quest is ready to turn in is Quest ready on the Sounds page.'},
	}},
	{title = 'Fade out', rows = {
		{'switch', 'In combat', 'objectives.hideCombat', 'The tracker fades away while you fight.'},
		{'switch', 'In boss fights', 'objectives.hideBoss', 'From the pull to the end of the encounter.'},
		{'switch', 'In instances', 'objectives.hideInstance', 'Dungeons, raids, battlegrounds and arenas.'},
		{'note', 'Fading never folds the tracker from here (that taints its quest item buttons); the items keep working while it is hidden.'},
	}},
}})
