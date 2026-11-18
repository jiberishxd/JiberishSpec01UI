-- Chat as a SPEC-01 communications device, "CH-1".
--
-- Housing: a machined device around each window. Its printed header carries a
-- power lamp, the model code, the window's name and a small LCD (unread lines
-- in other windows, or the time) with the copy key. Under the header the tabs
-- sit in a recessed track as a segmented key row: the window in view is the
-- raised key with a lit lamp, another window with new lines breathes its lamp,
-- a whisper window blinks amber. The messages sit on a recessed black screen
-- with fine corner marks and a soft shade under its top edge, and the text
-- field below it is the reference's black glass: a channel badge in the
-- channel's colour on the left, a block caret, and a character count LCD on
-- the right. The game's chat buttons are round (or square) glass keys in a
-- recessed rail; the scroll-to-bottom key lights a lamp when lines arrive
-- while you're scrolled up, and the dock's overflow key lights one when a
-- hidden tab has news. The scroll bar is a hairline track, the combat log's
-- filter bar a glass strip on the screen.
-- Motion and sound: the display powers on at login (a flicker, a scanline,
-- the lamp lighting and the header printing in), the text field prints its
-- badge in when it opens, a tab change is a detent, a whisper flashes the
-- power lamp amber with its blip, typing clicks like a keyboard (Enter is the
-- big key). Reduce motion and the sound settings rule all of it.
-- On top of that: a copy key, clickable web addresses, history across
-- reloads, link tooltips on hover, dim timestamps and glass chat bubbles.
--
-- Chat code is where 12.x secret values (whisper names, lockdowns) live, so
-- nothing here replaces AddMessage, overrides the game's chat format strings,
-- or writes fields onto its frames (our parts live in side tables). The only
-- function hooks are post-hooks that take no arguments' values: they queue a
-- skinning pass one frame later or repaint our own lamps and inks. Placement
-- stays with Edit Mode and the dock: windows, tabs and the side buttons are
-- never moved (only the edit box is anchored into our text field, as before).
-- Unread lines are noticed by comparing each window's line count and last line
-- on a light ticker, history is read back from the frames at logout, and
-- message filters only ever return a new message when the text is plain (a
-- secret message is passed on untouched). Anything the client may keep secret
-- (counts, colours, insets, tab names) is checked first and only ever passed
-- on to setters.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, GetTime = CreateFrame, GetTime
local max, min, floor = math.max, math.min, math.floor
local format, gsub, find, match = string.format, string.gsub, string.find, string.match

-- defaults:begin
-- 0.5.2 (the CH-1 redesign): headerLcd 'auto' | 'clock' | 'unread' | 'off';
-- keyShape 'round' | 'square'; stampDim prints timestamps in dim LCD ink.
UI:RegisterDefaults('chat', {
	font = 'plex', fontSize = 12, editTop = false, timestamps = 'keep',
	copy = true, urls = true, history = true, historyLines = 40,
	classColors = true, linkTips = true, flash = true, whisperSound = true, bubbles = true,
	housing = 'device', outline = 'none', shadow = true, tabSize = 9, chrome = true,
	headerLcd = 'auto', stampDim = false, keyShape = 'round', lineSpacing = 1, badge = true, countLcd = true,
	caret = true, powerOn = true, sounds = true,
})
-- defaults:end

local module = UI:RegisterModule('chat', {})
local function DB() return UI.db.chat end
local function Forbidden(object) return not object or (object.IsForbidden and object:IsForbidden()) end
local function IsSecret(value) return issecretvalue and issecretvalue(value) end
-- A number the client may keep secret, or 0.
local function Plain(value) return not IsSecret(value) and type(value) == 'number' and value or 0 end

local TAB_PARTS = {'Left', 'Middle', 'Right', 'SelectedLeft', 'SelectedMiddle', 'SelectedRight', 'ActiveLeft', 'ActiveMiddle',
	'ActiveRight', 'HighlightLeft', 'HighlightMiddle', 'HighlightRight'}
local EDIT_PARTS = {'Left', 'Mid', 'Right', 'FocusLeft', 'FocusMid', 'FocusRight'}

local devices, lamps, fields, typed, tabFrames = {}, {}, {}, {}, {}
local tabKeys = {}  -- tab -> {holder, thumb (light housing), cap (dark housings)}
local seen = {}     -- chat frame -> {line count, last line}
local unread = {}   -- tab -> new lines since its window was last in view
local scrolled = {} -- chat frame -> true: new lines while scrolled up
local painted = {}  -- tab -> the lamp state last painted

-- Geometry, in the window's own units. The deck is the window's top edge
-- (raised over the combat log's filter bar); the tabs' track, the header and
-- (with the field on top) the text field are placed above it.
local GEO = {screen = 8, margin = 6, gap = 6, wellLow = 5, well = 18, head = 16, field = 24, badge = 42, count = 28, lcd = 40}
-- The header's centre line, the housing's top and the top field's foot, above the deck.
local function Rows(top)
	local fieldLow = GEO.wellLow + GEO.well + GEO.gap
	local head
	if top then head = fieldLow + GEO.field + GEO.gap + GEO.head / 2
	else head = GEO.wellLow + GEO.well + GEO.gap + 1 + GEO.head / 2 end
	return head, head + GEO.head / 2 + GEO.margin, fieldLow
end

local function Clear(texture)
	if texture and not Forbidden(texture) and texture.SetTexture then
		texture:SetTexture(nil)
		texture:SetAlpha(0)
	end
end

local function Is(object, kind)
	return type(object) == 'table' and not Forbidden(object) and object.IsObjectType and object:IsObjectType(kind)
end

local function Hex(r, g, b)
	return format('|cff%02x%02x%02x', floor((r or 1) * 255 + 0.5), floor((g or 1) * 255 + 0.5), floor((b or 1) * 255 + 0.5))
end

-- The housing's surface, and the ink tokens printed on it.
local SURFACES = {device = 'paper', glass = 'glass', hairline = 'glass'}
local function Surface() return SURFACES[DB().housing] or 'paper' end
local function Inks()
	local ink = Kit.INK[Surface()] or Kit.INK.paper
	return ink[1], ink[2]
end

local OUTLINES = {none = '', outline = 'OUTLINE', thick = 'THICKOUTLINE'}
local function Flags() return OUTLINES[DB().outline] or '' end
local function Shadow(region)
	if not region.SetShadowOffset then return end
	if DB().shadow and DB().outline == 'none' then
		region:SetShadowOffset(1, -1)
		region:SetShadowColor(0, 0, 0, 0.9)
	else
		region:SetShadowOffset(0, 0)
	end
end

local function FontPath(bold)
	return DB().font == 'plex' and Kit:FontPath(bold) or STANDARD_TEXT_FONT
end

-- A string in `size`, shrunk until it fits `room` (wide typefaces such as Audiowide).
local function FitFont(fontString, room, size, bold)
	Kit:Font(fontString, size, nil, bold)
	local wide = Plain(fontString:GetStringWidth())
	if room > 0 and wide > room then Kit:Font(fontString, max(5, floor(size * room / wide)), nil, bold) end
end

-- Sounds ------------------------------------------------------------------------------
-- Device voices (a tab's detent, the power-on, the field opening) follow the
-- interface sounds and this page's switch; the chat keys follow the controls'
-- sounds; typing follows the chat typing switch. Every voice is rate-limited.
local lastVoice = {}
local function Voice(name, gap)
	local sound = UI.db.sound
	if not (sound and sound.enable and sound.interface ~= false) or not DB().sounds then return end
	local now = GetTime()
	if now - (lastVoice[name] or 0) < (gap or 0.08) then return end
	lastVoice[name] = now
	Kit:Play(name, true)
end
local function KeySound(name) if DB().sounds then Kit:Play(name) end end
local function Typing()
	local sound = UI.db.sound
	return sound and sound.enable and sound.chat
end
local lastType = 0
local function TypeSound(_, character)
	if not Typing() or IsSecret(character) then return end
	local now = GetTime()
	if now - lastType < 0.025 then return end
	lastType = now
	Kit:Play(character == ' ' and 'type-space' or 'type', true)
end

-- Text that can be read: plain, and not a protected (|K) Battle.net line.
local function Readable(text)
	if type(text) ~= 'string' or IsSecret(text) then return false end
	return not find(text, '|K', 1, true)
end

-- Glass details -------------------------------------------------------------------------
-- Fine corner marks inside a screen and a soft shade under its top edge, drawn
-- on the glass's own shell (under the window's text) in physical pixels.
local marked = {}
local CORNERS = {{'TOPLEFT', 1, -1}, {'TOPRIGHT', -1, -1}, {'BOTTOMLEFT', 1, 1}, {'BOTTOMRIGHT', -1, 1}}
local function FitMarks(glass, marks)
	local Pixel = UI.Pixel
	local px, inset, length = Pixel.Px(glass, 1), Pixel.Snap(glass, 4), Pixel.Snap(glass, 7)
	for index, corner in ipairs(CORNERS) do
		local across, down = marks[index * 2 - 1], marks[index * 2]
		for _, mark in ipairs({across, down}) do
			mark:ClearAllPoints()
			mark:SetPoint(corner[1], glass, corner[1], corner[2] * inset, corner[3] * inset)
		end
		across:SetSize(length, px)
		down:SetSize(px, length)
	end
	marks.shade:SetHeight(Pixel.Snap(glass, 10))
end

local function Detail(glass)
	if not glass or marked[glass] then return end
	local marks = {}
	for index = 1, 8 do
		local mark = glass:CreateTexture(nil, 'BORDER', nil, 2)
		mark:SetColorTexture(1, 1, 1, 1)
		Kit:Tint(mark, 'darkDim', 0.45)
		marks[index] = mark
	end
	local shade = glass:CreateTexture(nil, 'BORDER', nil, 1)
	shade:SetColorTexture(1, 1, 1, 1)
	shade:SetGradient('VERTICAL', CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0.32))
	shade:SetPoint('TOPLEFT', glass, 'TOPLEFT', 3, -1)
	shade:SetPoint('TOPRIGHT', glass, 'TOPRIGHT', -3, -1)
	marks.shade = shade
	marked[glass] = marks
	FitMarks(glass, marks)
end

-- A recessed track (the tab row, the key rail): the reference's well on the
-- light device, dark glass on the dark one; the hairline housing gets a rule.
local function Recess(frame, housing, corner, rule)
	local texture
	if housing == 'device' then texture = Kit:Skin(frame, 'well', 'BACKGROUND', 0)
	elseif housing == 'glass' then texture = Kit:Skin(frame, 'glass', 'BACKGROUND', 0) end
	if texture then
		texture.kitMaxCorner = corner
		Kit:FitSprite(texture, frame:GetWidth(), frame:GetHeight())
		return texture
	end
	if not rule then return nil end
	local line = Kit:Solid(frame, 'darkEdge', 'BACKGROUND', 0, 0.8)
	line:SetPoint('BOTTOMLEFT')
	line:SetPoint('BOTTOMRIGHT')
	line:SetHeight(UI.Pixel.Px(frame, 1))
	return line
end

-- Tabs -----------------------------------------------------------------------------------
local function TabText(tab) return tab.Text or _G[(tab:GetName() or '')..'Text'] end
local function Whisper(chat)
	local kind = chat and chat.chatType
	return not IsSecret(kind) and (kind == 'WHISPER' or kind == 'BN_WHISPER')
end
-- A window is in view while it's shown: the dock's selected one, or an undocked one that's open.
local function InView(chat) return chat:IsShown() and true or false end

local function InkTab(tab)
	local chat, text = tabFrames[tab], TabText(tab)
	if not chat or not text then return end
	local ink, dim = Inks()
	Kit:Tint(text, (InView(chat) or tab:IsMouseOver()) and ink or dim)
end

-- The window in view is the segmented control's raised key (the light housing)
-- or a lit charcoal cap (dark glass) with a lit lamp; amber on a whisper window.
-- Another window with new lines breathes its lamp in the key colour, a whisper
-- window blinks amber; the rest are printed with an unlit lamp.
local function PaintTab(tab, force)
	local lamp, chat = lamps[tab], tabFrames[tab]
	if not lamp or not chat then return end
	local on = InView(chat)
	local new = not on and unread[tab] and DB().flash
	local whisper = Whisper(chat)
	InkTab(tab)
	-- A whisper tab's conversation icon would sit under the lamp.
	local icon = tab.conversationIcon
	if Is(icon, 'Texture') then icon:SetAlpha(0) end
	local state = (on and 'on' or new and 'new' or 'off')..(whisper and '+' or '')
	if painted[tab] == state and not force then return end
	local was = painted[tab]
	painted[tab] = state
	Kit:Blink(lamp, nil, false)
	Kit:Breathe(lamp, false)
	if on then
		Kit:SetLed(lamp, true, whisper and 'amber' or nil)
	elseif new then
		Kit:SetLed(lamp, true, whisper and 'amber' or 'lamp')
		-- (Living lamps would breathe a lit lamp too: a blinking one only blinks.)
		if whisper then Kit:Breathe(lamp, false); Kit:Blink(lamp, 0.8) else Kit:Breathe(lamp, true, {period = 1.6, low = 0.3}) end
	else
		Kit:SetLed(lamp, false)
	end
	local key = tabKeys[tab]
	if not key then return end
	local light = Surface() == 'paper'
	key.thumb:SetShown(on and light)
	key.cap:SetShown(on and not light)
	-- The key comes up under the tab just chosen.
	if on and was and not force then
		key.holder:SetAlpha(0.3)
		Kit:FadeTo(key.holder, 1, 'FAST')
	elseif not Kit:Animating(key.holder) then
		key.holder:SetAlpha(1)
	end
end

-- A label wider than its tab (a wide typeface after the game sized the tab)
-- is cut to fit, so it never runs under the next tab. Whisper tabs, whose
-- names may be secret, already have a fixed width from the game.
local function FitTab(tab)
	local text = TabText(tab)
	if not Is(text, 'FontString') then return end
	local value = text:GetText()
	if IsSecret(value) or type(value) ~= 'string' then return end
	local room = Plain(tab:GetWidth()) - 22
	if room > 8 and Plain(text:GetStringWidth()) > room then
		text:SetWordWrap(false)
		text:SetWidth(room)
	end
end

local lastDocked
-- quiet: no detent (a skinning pass, not the player changing tabs).
function module.PaintTabs(quiet, force)
	local dock, selected = _G.GENERAL_CHAT_DOCK, _G.FCFDock_GetSelectedWindow
	local docked = dock and selected and selected(dock) or nil
	if docked ~= lastDocked then
		if lastDocked and docked and not quiet then Voice('detent', 0.06) end
		lastDocked = docked
	end
	for tab, chat in pairs(tabFrames) do
		if InView(chat) then unread[tab] = nil end
		PaintTab(tab, force)
	end
end

-- The game repaints a tab's label in its own colours when tabs change; ink them again.
function module.InkTabs()
	for tab in pairs(lamps) do InkTab(tab) end
end

local function SkinTab(tab, frame)
	if Forbidden(tab) or lamps[tab] then return end
	local name = tab:GetName() or ''
	for _, part in ipairs(TAB_PARTS) do
		Clear(_G[name..part])
		Clear(tab[part])
	end
	if tab.GetHighlightTexture then Clear(tab:GetHighlightTexture()) end
	-- The game's own unread glow and flash: the lamp tells instead.
	Clear(tab.glow); Clear(_G[name..'Glow'])
	local flash = _G[name..'Flash']
	if Is(flash, 'Frame') then
		for _, region in ipairs({flash:GetRegions()}) do if Is(region, 'Texture') then Clear(region) end end
	end
	local text = TabText(tab)
	if text then Kit:Font(text, DB().tabSize or 9, Flags(), true) end
	local lamp = Kit:Led(tab, 5, false)
	lamp:SetPoint('RIGHT', text or tab, 'LEFT', -5, 0)
	-- The key behind the tab in view, the tab's width and centred on its label
	-- (the game prints it 5 below the tab's middle). It sits one level under
	-- the tab so the tab's own label stays on top.
	local holder = CreateFrame('Frame', nil, tab)
	holder:SetFrameLevel(max(tab:GetFrameLevel() - 1, 0))
	holder:EnableMouse(false)
	holder:SetPoint('LEFT', tab, 'LEFT', 1, -5)
	holder:SetPoint('RIGHT', tab, 'RIGHT', -1, -5)
	holder:SetHeight(GEO.well - 4)
	local thumb = Kit:Skin(holder, 'segment-thumb', 'BACKGROUND', 0)
	thumb.kitMaxCorner = 6
	local cap = Kit:Shell(holder, {surface = 'dark', radius = 5, shadow = false})
	thumb:Hide(); cap:Hide()
	tabKeys[tab] = {holder = holder, thumb = thumb, cap = cap}
	-- Hover: printed tabs lift to full ink.
	tab:HookScript('OnEnter', function(self)
		local label = TabText(self)
		if label then Kit:Tint(label, (Inks())) end
	end)
	tab:HookScript('OnLeave', function(self) InkTab(self) end)
	lamps[tab] = lamp
	tabFrames[tab] = frame
	painted[tab] = nil
end

-- The text field ------------------------------------------------------------------------
-- The badge prints the channel's short code beside a bar in its colour.
local BADGES = {SAY = 'SAY', YELL = 'YELL', EMOTE = 'EMOTE', PARTY = 'PARTY', PARTY_LEADER = 'PARTY', RAID = 'RAID',
	RAID_LEADER = 'RAID', RAID_WARNING = 'RW', INSTANCE_CHAT = 'INST', INSTANCE_CHAT_LEADER = 'INST', GUILD = 'GUILD',
	OFFICER = 'OFCR', WHISPER = 'TELL', BN_WHISPER = 'BNET', CHANNEL = 'CHAN', COMMUNITIES_CHANNEL = 'COMM',
	VOICE_TEXT = 'VOICE'}

local function EditBoxOf(frame)
	local name = frame:GetName()
	return name and _G[name..'EditBox']
end

-- The edit box's chat type (and channel number), as a code and the type's colours.
local function ChannelOf(box)
	local kind = box.GetAttribute and box:GetAttribute('chatType')
	if IsSecret(kind) or type(kind) ~= 'string' then return nil, nil end
	local infos = _G.ChatTypeInfo
	local code, info = BADGES[kind] or strupper(kind:sub(1, 5)), type(infos) == 'table' and infos[kind] or nil
	if kind == 'CHANNEL' then
		local target = box:GetAttribute('channelTarget')
		if not IsSecret(target) and (type(target) == 'number' or (type(target) == 'string' and match(target, '^%d+$'))) then
			code = 'CH '..target
			if type(infos) == 'table' and infos['CHANNEL'..target] then info = infos['CHANNEL'..target] end
		end
	end
	return code, info
end

-- The character count, on a small LCD while you type; red near the game's limit.
function module.Count(frame)
	local field, box = fields[frame], EditBoxOf(frame)
	if not field or Forbidden(box) then return end
	local count = field.count
	local show = DB().countLcd and box:IsShown()
	count:SetShown(show and true or false)
	if not show then return end
	local text = box:GetText()
	if IsSecret(text) or type(text) ~= 'string' then count.digits:SetText('') return end
	local letters = strlenutf8 and strlenutf8(text) or #text
	count.digits:SetText(format('%d', min(letters, 999)))
	Kit:Tint(count.digits, #text >= 240 and 'red' or 'lcdInk')
end

-- The text field: what's typed and the channel header in the typeface.
function module.FontField(frame)
	local name = frame:GetName()
	local box = EditBoxOf(frame)
	if Forbidden(box) then return end
	local size = DB().fontSize or 12
	if pcall(box.SetFont, box, FontPath(false), size, Flags()) then Shadow(box) end
	local header = box.header or _G[name..'EditBoxHeader']
	if Is(header, 'FontString') then
		pcall(header.SetFont, header, FontPath(true), size, Flags())
		Shadow(header)
	end
	local suffix = box.headerSuffix or _G[name..'EditBoxHeaderSuffix']
	if Is(suffix, 'FontString') then pcall(suffix.SetFont, suffix, FontPath(true), size, Flags()) end
	local field = fields[frame]
	if field then Kit:Font(field.hint, 8, nil, false) end
end

-- The badge (or, with it off, a lamp) in the channel's colour while typing and
-- dimmed between messages; the hint follows whichever shows.
function module.PaintField(frame)
	local field, box = fields[frame], EditBoxOf(frame)
	if not field or Forbidden(box) then return end
	local db = DB()
	local shown = box:IsShown()
	local r, g, b
	local header = box.header or _G[(frame:GetName() or '')..'EditBoxHeader']
	if shown and Is(header, 'FontString') then
		local hr, hg, hb = header:GetTextColor()
		if not (IsSecret(hr) or IsSecret(hg) or IsSecret(hb)) and type(hr) == 'number' then r, g, b = hr, hg, hb end
	end
	local code, info = ChannelOf(box)
	if not r and type(info) == 'table' and type(info.r) == 'number' and not IsSecret(info.r) then r, g, b = info.r, info.g, info.b end
	local color = field.color
	if r then color[1], color[2], color[3] = r, g, b end
	local badge = field.badge
	badge:SetShown(db.badge and true or false)
	if db.badge then
		badge.label:SetText(code or 'SAY')
		FitFont(badge.label, GEO.badge - 17, 7, true)
		Kit:Tint(badge.bar, r and color or 'ledOff')
		badge:SetAlpha(shown and 1 or 0.55)
	end
	local lamp = not db.badge
	field.lamp:SetShown(lamp)
	if lamp and shown and r then
		field.lamp:SetVertexColor(r, g, b, 1)
		field.lampGlow:SetVertexColor(r, g, b, 1)
		field.lampGlow:Show()
	else
		field.lamp:SetVertexColor(Kit:RGB('ledOff'))
		field.lampGlow:Hide()
	end
	field.hint:ClearAllPoints()
	if db.badge then field.hint:SetPoint('LEFT', badge, 'RIGHT', 6, 0)
	else field.hint:SetPoint('LEFT', field.lamp, 'RIGHT', 7, 0) end
	module.Count(frame)
end

-- The field opening: its focus ring fades up and the badge prints in; closing, the hint prints back.
function module.Opened(frame)
	local field = fields[frame]
	if not field then return end
	field.hint:Hide()
	Kit:FadeTo(field.focus, 1, 'FAST')
	if field.badge:IsShown() then Kit:Print(field.badge.label, {duration = 0.2, steps = 8}) end
	Voice('tick', 0.15)
end
function module.Closed(frame)
	local field = fields[frame]
	if not field then return end
	field.hint:Show()
	Kit:Print(field.hint, {duration = 0.28, steps = 16})
	Kit:FadeTo(field.focus, 0, 'FAST')
	field.count:Hide()
end

-- The reference's block caret, drawn on our field under the edit box's text
-- and placed from the cursor and the box's insets. Insets follow the channel
-- header (a whisper target may be secret): whenever any of it is, the block
-- steps aside and the game's own thin caret is the cursor.
local carets = {}
local CARET_PERIOD = 1.06
local function Caret(box, field)
	local block = field:CreateTexture(nil, 'ARTWORK', nil, 2)
	block:SetColorTexture(1, 1, 1, 1)
	Kit:Tint(block, 'accent', 0.8)
	block:Hide()
	carets[box] = block
	local tag = Kit.MotionTag('chat-caret', box)
	local placed = false
	local function Stop()
		Kit:StopLoop(tag)
		block:Hide()
	end
	local function Run()
		if not (placed and DB().caret and box:HasFocus() and Kit:Faithful('caret')) then return Stop() end
		block:Show()
		-- Restarted on every move, so the block stays solid while typing.
		Kit:Loop(tag, field, function(t) block:SetAlpha((t % CARET_PERIOD) < CARET_PERIOD / 2 and 0.8 or 0) end,
			function() block:SetAlpha(0.8) end)
	end
	box:HookScript('OnCursorChanged', function(self, x, _, _, height)
		placed = false
		local left = self.GetTextInsets and self:GetTextInsets()
		local _, size = self:GetFont()
		if not (IsSecret(x) or IsSecret(height) or IsSecret(left) or IsSecret(size)) and type(x) == 'number' and type(left) == 'number' then
			size = type(size) == 'number' and size > 0 and size or DB().fontSize or 12
			block:ClearAllPoints()
			block:SetPoint('LEFT', self, 'LEFT', left + x, 0)
			block:SetSize(max(2, floor(size * 0.55 + 0.5)), floor(size * 1.15 + 0.5))
			placed = true
		end
		Run()
	end)
	box:HookScript('OnEditFocusGained', Run)
	box:HookScript('OnEditFocusLost', Stop)
	box:HookScript('OnHide', Stop)
end

local function BuildField(frame, device)
	local field = CreateFrame('Frame', nil, device)
	if DB().editTop then
		local _, _, low = Rows(true)
		field:SetPoint('BOTTOMLEFT', device.deck, 'BOTTOMLEFT', -GEO.screen, low)
		field:SetPoint('BOTTOMRIGHT', device.deck, 'BOTTOMRIGHT', GEO.screen, low)
	else
		field:SetPoint('TOPLEFT', frame, 'BOTTOMLEFT', -GEO.screen, -(GEO.screen + GEO.gap))
		field:SetPoint('TOPRIGHT', frame, 'BOTTOMRIGHT', GEO.screen, -(GEO.screen + GEO.gap))
	end
	field:SetHeight(GEO.field)
	field.glass = Kit:Skin(field, 'glass', 'BACKGROUND', 0)
	field.glass.kitMaxCorner = 10
	-- The focus ring, in the key colour while typing.
	field.focus = Kit:Texture(field, 'ring-6', 'BORDER')
	field.focus:SetAllPoints()
	Kit:Tint(field.focus, 'accent')
	field.focus:SetAlpha(0)
	-- The channel badge: a printed chip with a bar in the channel's colour.
	local badge = Kit:Panel(field, {sprite = 'badge'})
	badge:SetSize(GEO.badge, 16)
	badge:SetPoint('LEFT', field, 'LEFT', 5, 0)
	badge.bar = Kit:Solid(badge, 'ledOff')
	badge.bar:SetSize(3, 8)
	badge.bar:SetPoint('LEFT', badge, 'LEFT', 6, 0)
	badge.label = Kit:Label(badge, 'Say', 'ink', 7, true)
	badge.label:SetPoint('LEFT', badge, 'LEFT', 13, 0)
	badge.label:SetWordWrap(false)
	field.badge, field.color = badge, {1, 1, 1}
	-- With the badge off: a lamp, unlit until you type, then the channel's colour.
	field.lamp = Kit:Texture(field, 'circle', 'OVERLAY', 2)
	field.lamp:SetSize(5, 5)
	field.lamp:SetPoint('LEFT', 9, 0)
	field.lampGlow = Kit:Texture(field, 'glow', 'OVERLAY', 1)
	field.lampGlow:SetPoint('TOPLEFT', field.lamp, 'TOPLEFT', -5, 5)
	field.lampGlow:SetPoint('BOTTOMRIGHT', field.lamp, 'BOTTOMRIGHT', 5, -5)
	field.lampGlow:SetAlpha(0.6)
	field.lampGlow:Hide()
	field.lamp:SetVertexColor(Kit:RGB('ledOff'))
	field.hint = Kit:Label(field, 'Press Enter to chat', 'darkDim', 8)
	field.hint:SetPoint('LEFT', badge, 'RIGHT', 6, 0)
	-- The character count.
	local count = Kit:LCDPanel(field, {radius = 3})
	count:SetSize(GEO.count, 14)
	count:SetPoint('RIGHT', field, 'RIGHT', -5, 0)
	count.ghost = Kit:Ghost(Kit:Text(count, '888', 8, 'lcdGhost', true))
	count.digits = Kit:Text(count, '', 8, 'lcdInk', true)
	for _, fontString in ipairs({count.ghost, count.digits}) do
		fontString:SetPoint('RIGHT', count, 'RIGHT', -3, 0)
		fontString:SetJustifyH('RIGHT')
	end
	count:Hide()
	field.count = count
	fields[frame] = field
end

-- The text field is part of the housing and always shows, like the
-- reference's text field; the edit box types into it when chat is open.
local placed = {}
local function PlaceEditBox(frame)
	local box, field = EditBoxOf(frame), fields[frame]
	if Forbidden(box) or not field then return end
	if not typed[box] then
		local name = frame:GetName()
		for _, part in ipairs(EDIT_PARTS) do Clear(_G[name..'EditBox'..part]) end
		Clear(box.focusLeft); Clear(box.focusMid); Clear(box.focusRight)
		box:HookScript('OnChar', TypeSound)
		box:HookScript('OnEnterPressed', function() if Typing() then Kit:Play('type-big', true) end end)
		-- The badge follows the header's colour, which the game sets to the
		-- channel's; read a frame later, after the game repainted it.
		local pending = false
		local function Relamp()
			if pending then return end
			pending = true
			C_Timer.After(0, function()
				pending = false
				UI:Safe(module.PaintField, frame)
			end)
		end
		box:HookScript('OnShow', function() UI:Safe(module.Opened, frame); Relamp() end)
		box:HookScript('OnHide', function() UI:Safe(module.Closed, frame); Relamp() end)
		box:HookScript('OnTextChanged', function() UI:Safe(module.Count, frame); Relamp() end)
		box:HookScript('OnEditFocusGained', Relamp)
		Caret(box, field)
		field.hint:SetShown(not box:IsShown())
		if box:IsShown() then field.focus:SetAlpha(1) end
		typed[box] = true
		module.FontField(frame)
		module.PaintField(frame)
	end
	-- The game starts the header 15 in from the box's left and keeps the text
	-- 13 off its right: the box overlaps the badge and the count by that much.
	local db = DB()
	local left = db.badge and (5 + GEO.badge + 4 - 15) or 6
	local right = db.countLcd and -(GEO.count + 5 + 3 - 13) or -4
	local spot = left..':'..right
	local point, relative = box:GetPoint(1)
	if placed[box] == spot and point == 'TOPLEFT' and relative == field then return end
	placed[box] = spot
	box:ClearAllPoints()
	box:SetPoint('TOPLEFT', field, 'TOPLEFT', left, 0)
	box:SetPoint('BOTTOMRIGHT', field, 'BOTTOMRIGHT', right, 0)
end

-- The housing ---------------------------------------------------------------------------
-- Wide enough for the game's button column on whichever side it sits, and tall
-- enough for the combat log's filter bar over its messages.
function module.FitDevice(frame, device)
	local top = DB().editTop
	local name = frame:GetName()
	local buttons = frame.buttonFrame or (name and _G[name..'ButtonFrame'])
	local column = 0
	if buttons and not Forbidden(buttons) and buttons:IsShown() then column = Plain(buttons:GetWidth()) end
	local side = frame.buttonSide
	if IsSecret(side) or side ~= 'right' then side = 'left' end
	local extra = 0
	local filters = _G.CombatLogQuickButtonFrame_Custom
	if frame == _G.COMBATLOG and Is(filters, 'Frame') and filters:IsShown() then extra = Plain(filters:GetHeight()) end
	local edge = GEO.screen + GEO.margin
	-- The column sits 5 off the window (its background's 2 and the game's 3).
	local wide = column > 0 and (5 + column + GEO.margin) or edge
	local left, right = side == 'left' and wide or edge, side == 'right' and wide or edge
	local _, rise = Rows(top)
	local bottom = top and edge or (GEO.screen + GEO.gap + GEO.field + GEO.margin)
	local spot = left..':'..right..':'..(rise + extra)..':'..bottom..':'..column
	if device.spot == spot then return end
	device.spot = spot
	device:ClearAllPoints()
	device:SetPoint('TOPLEFT', frame, 'TOPLEFT', -left, rise + extra)
	device:SetPoint('BOTTOMRIGHT', frame, 'BOTTOMRIGHT', right, -bottom)
	device.deck:ClearAllPoints()
	device.deck:SetPoint('BOTTOMLEFT', frame, 'TOPLEFT', 0, extra)
	device.deck:SetPoint('BOTTOMRIGHT', frame, 'TOPRIGHT', 0, extra)
	-- The key rail behind the column.
	local rail = device.rail
	if rail then
		rail:SetShown(column > 0)
		if column > 0 then
			rail:ClearAllPoints()
			rail:SetPoint('TOPLEFT', buttons, 'TOPLEFT', -2, 2)
			rail:SetPoint('BOTTOMRIGHT', buttons, 'BOTTOMRIGHT', 2, -2)
		end
	end
end

-- The printed header: lamp, model code, the window's name, the LCD's tag and
-- readout, and the copy key. The title runs up to whatever is shown at the
-- right and is cut there, so long names and wide typefaces never overlap.
function module.LayoutHeader(device)
	local db = DB()
	local printed = db.housing ~= 'hairline'
	local lcd = printed and db.headerLcd ~= 'off'
	device.copy:SetShown(db.copy and true or false)
	Kit:ShowLed(device.lamp, printed)
	device.model:SetShown(printed)
	device.title:SetShown(printed)
	device.lcd:SetShown(lcd)
	device.tag:SetShown(lcd)
	device.lcd:ClearAllPoints()
	if db.copy then device.lcd:SetPoint('RIGHT', device.copy, 'LEFT', -5, 0)
	else device.lcd:SetPoint('RIGHT', device.head, 'RIGHT', -2, 0) end
	device.tag:ClearAllPoints()
	device.tag:SetPoint('RIGHT', device.lcd, 'LEFT', -4, 0)
	device.title:ClearAllPoints()
	device.title:SetPoint('LEFT', device.model, 'RIGHT', 5, 0)
	if lcd then device.title:SetPoint('RIGHT', device.tag, 'LEFT', -6, 0)
	elseif db.copy then device.title:SetPoint('RIGHT', device.copy, 'LEFT', -6, 0)
	else device.title:SetPoint('RIGHT', device.head, 'RIGHT', -2, 0) end
	device.reading = nil
end

-- The header's name: the window's tab, as the game names it (a whisper
-- window's may be secret: it's passed on as it is).
function module.Retitle(frame, device)
	local tab = _G[(frame:GetName() or '')..'Tab']
	local text = tab and TabText(tab)
	local value = text and text.GetText and text:GetText()
	if IsSecret(value) then device.title:SetText(value)
	elseif type(value) == 'string' and value ~= '' then device.title:SetText(strupper(value))
	else device.title:SetText('COMMS') end
end

-- The LCD: new lines in other windows ('NEW 03'), else the time.
local function FitLCD(lcd, size)
	Kit:Font(lcd.digits, size, nil, true)
	Kit:Font(lcd.ghost, size, nil, true)
	local wide = max(Plain(lcd.digits:GetStringWidth()), Plain(lcd.ghost:GetStringWidth()))
	local room = GEO.lcd - 6
	if wide > room then
		local fit = max(5, floor(size * room / wide))
		Kit:Font(lcd.digits, fit, nil, true)
		Kit:Font(lcd.ghost, fit, nil, true)
	end
end

function module.Readout(device, total, clock)
	local mode = DB().headerLcd
	if mode == 'off' or not device.lcd:IsShown() then return end
	local text, tag
	if mode == 'unread' or (mode == 'auto' and total > 0) then text, tag = format('%02d', min(total, 99)), 'NEW'
	else text, tag = clock, '' end
	if device.reading == text and device.tagText == tag then return end
	local first = device.reading == nil
	device.reading, device.tagText = text, tag
	local lcd = device.lcd
	lcd.digits:SetText(text)
	lcd.ghost:SetText((gsub(text, '%d', '8')))
	FitLCD(lcd, 8)
	device.tag:SetText(tag)
	if not first and device:IsVisible() then Kit:Print(lcd.digits, {duration = 0.2, steps = 8}) end
end

local function BuildHeader(device, index)
	local head = CreateFrame('Frame', nil, device)
	local mid = Rows(DB().editTop)
	head:SetPoint('LEFT', device.deck, 'BOTTOMLEFT', -GEO.screen, mid)
	head:SetPoint('RIGHT', device.deck, 'BOTTOMRIGHT', GEO.screen, mid)
	head:SetHeight(GEO.head)
	device.head = head
	local ink, dim = Inks()
	-- The power lamp, in a holder of its own so a whisper's flash can glow around it.
	device.lampHolder = CreateFrame('Frame', nil, head)
	device.lampHolder:SetSize(5, 5)
	device.lampHolder:SetPoint('LEFT', head, 'LEFT', 4, 0)
	device.lamp = Kit:Led(device.lampHolder, 5, false)
	device.lamp:SetPoint('CENTER')
	device.model = Kit:Label(head, 'CH-'..index, ink, 8, true)
	device.model:SetPoint('LEFT', device.lampHolder, 'RIGHT', 5, 0)
	device.title = Kit:Label(head, 'Comms', dim, 8)
	device.title:SetJustifyH('LEFT')
	device.title:SetWordWrap(false)
	local lcd = Kit:LCDPanel(head, {radius = 3})
	lcd:SetSize(GEO.lcd, 14)
	lcd.ghost = Kit:Ghost(Kit:Text(lcd, '', 8, 'lcdGhost', true))
	lcd.digits = Kit:Text(lcd, '', 8, 'lcdInk', true)
	for _, fontString in ipairs({lcd.ghost, lcd.digits}) do
		fontString:SetPoint('RIGHT', lcd, 'RIGHT', -3, 0)
		fontString:SetJustifyH('RIGHT')
		fontString:SetWordWrap(false)
	end
	device.lcd = lcd
	device.tag = Kit:Label(head, '', dim, 7, true)
	-- The header's print follows the housing's colour (Kit:PaintShell).
	device.kitHeader = true
	Kit:PaintShell(device.shell)
end

local CopyWindow -- defined below

-- The copy key, in the header. Tabs reach a little way up into the header
-- row, so the key sits in their stratum, above them.
local function BuildCopyKey(frame, device)
	local copy = Kit:Key(device.head, {width = 18, height = 18, round = true, icon = 'copy', iconSize = 9, sound = 'down',
		onClick = function() CopyWindow(frame) end})
	copy:SetPoint('RIGHT', device.head, 'RIGHT', 0, 0)
	copy:SetFrameStrata('MEDIUM')
	copy:SetFrameLevel(20)
	copy:HookScript('OnEnter', function(self) Kit:ShowTooltip(self, 'Copy this window') end)
	copy:HookScript('OnLeave', function() Kit:HideTooltip() end)
	device.copy = copy
end

-- Power-on: the display flickers on with a scanline running down it, the lamp
-- lights and the header prints in. Reduce motion (or the switch) just lights it.
local FLICKER = {0, 0.6, 0.12, 0.85, 0.4, 1}
function module.PowerUp(device)
	local lamp = device.lamp
	if not DB().powerOn or Kit:Reduced() or not device:IsVisible() then
		Kit:SetLed(lamp, true)
		return false
	end
	local screen = device.screen
	local glass = device.glass or screen
	local scan = device.scan
	if not scan then
		scan = glass:CreateTexture(nil, 'OVERLAY', nil, 7)
		scan:SetColorTexture(1, 1, 1, 1)
		scan:SetBlendMode('ADD')
		device.scan = scan
	end
	local height = Plain(glass:GetHeight())
	scan:SetHeight(UI.Pixel.Snap(glass, 2))
	scan:Show()
	Kit:SetLed(lamp, false)
	local lit = false
	Kit:Animate(Kit.MotionTag('chat-power', device), 0.45, 0, 1, function(_, progress)
		screen:SetAlpha(FLICKER[min(#FLICKER, floor(progress * #FLICKER) + 1)])
		scan:ClearAllPoints()
		scan:SetPoint('TOPLEFT', glass, 'TOPLEFT', 2, -height * progress)
		scan:SetPoint('TOPRIGHT', glass, 'TOPRIGHT', -2, -height * progress)
		scan:SetAlpha(0.3 * (1 - progress) * min(1.5, Kit:Intensity()))
		if progress >= 0.55 and not lit then
			lit = true
			Kit:SetLed(lamp, true)
		end
	end, function()
		screen:SetAlpha(1)
		scan:Hide()
		Kit:SetLed(lamp, true)
	end, 'linear')
	Kit:Print(device.model, {force = true, duration = 0.2, steps = 8, delay = 0.1})
	Kit:Print(device.title, {force = true, duration = 0.3, steps = 14, delay = 0.18})
	if device.lcd:IsShown() then Kit:Print(device.lcd.digits, {force = true, duration = 0.22, steps = 8, delay = 0.3}) end
	return true
end

function module.PowerAll()
	local any = false
	for _, device in pairs(devices) do
		if UI:Safe(module.PowerUp, device) and device:IsVisible() and DB().powerOn and not Kit:Reduced() then any = true end
	end
	if any then Voice('power-up', 1) end
end

-- A whisper: the power lamp flashes amber three times with a glow around it.
function module.Alert(device)
	local lamp = device.lamp
	if not lamp or not device:IsVisible() or DB().housing == 'hairline' then return end
	if Kit:Reduced() then
		Kit:SetLed(lamp, true, 'amber')
		C_Timer.After(1.2, function() Kit:SetLed(lamp, true) end)
		return
	end
	Kit:Flash(device.lampHolder, {token = 'amber', alpha = 0.8, duration = 0.5})
	local last
	Kit:Animate(Kit.MotionTag('chat-alert', lamp), 1.2, 0, 1, function(_, progress)
		local on = floor(progress * 6) % 2 == 0
		if on ~= last then
			last = on
			Kit:SetLed(lamp, true, on and 'amber' or nil)
		end
	end, function() Kit:SetLed(lamp, true) end, 'linear')
end

-- The window's text in the chosen typeface, size, outline and line spacing.
local function FontChat(frame)
	local db = DB()
	local ok = pcall(frame.SetFont, frame, FontPath(false), db.fontSize or 12, Flags())
	if ok then Shadow(frame) end
	if frame.SetSpacing then pcall(frame.SetSpacing, frame, db.lineSpacing or 1) end
end

-- Link tooltips: hovering an item, spell, achievement or quest link in chat
-- shows it, as the reference's hover cards do.
local TIP_LINKS = {item = true, spell = true, achievement = true, quest = true, currency = true, talent = true, enchant = true,
	battlepet = true, mount = true, instancelock = true, unit = true, keystone = true, conduit = true, azessence = true, transmogillusion = true}
local function LinkEnter(frame, link)
	if not DB().linkTips or type(link) ~= 'string' or IsSecret(link) then return end
	local kind = match(link, '^(%a+):')
	if not kind or not TIP_LINKS[kind] then return end
	GameTooltip:SetOwner(frame, 'ANCHOR_CURSOR')
	if pcall(GameTooltip.SetHyperlink, GameTooltip, link) then GameTooltip:Show() else GameTooltip:Hide() end
end
local function LinkLeave(frame) if GameTooltip:GetOwner() == frame then GameTooltip:Hide() end end

local function SkinChatFrame(frame, index)
	if Forbidden(frame) or devices[frame] then return end
	local name = frame:GetName()
	-- Blizzard's background and border textures are regions of the frame.
	for _, region in ipairs({frame:GetRegions()}) do
		if region.IsObjectType and region:IsObjectType('Texture') then Clear(region) end
	end
	Clear(frame.Background)
	local buttons = frame.buttonFrame or _G[name..'ButtonFrame']
	if buttons and not Forbidden(buttons) then
		for _, region in ipairs({buttons:GetRegions()}) do
			if region.IsObjectType and region:IsObjectType('Texture') then Clear(region) end
		end
	end

	-- Housing: the light device, dark glass, or (hairline) no housing at all:
	-- a faint display with a fine edge. Blizzard's chat buttons live inside it.
	local db = DB()
	local housing = db.housing
	local device = Kit:Device(frame, {header = false, corner = 16, surface = Surface()})
	device:SetFrameLevel(max(frame:GetFrameLevel() - 2, 0))
	Kit:Relevel(device)
	device:EnableMouse(false)
	if housing == 'hairline' then device.shell:Hide() end
	device.deck = CreateFrame('Frame', nil, device)
	device.deck:SetHeight(1)
	device.deck:SetPoint('BOTTOMLEFT', frame, 'TOPLEFT')
	device.deck:SetPoint('BOTTOMRIGHT', frame, 'TOPRIGHT')

	-- The screen: from just under the tabs to the window's foot, its glass a
	-- few units past the text on every side.
	local screen, glass
	if housing == 'hairline' then
		screen = CreateFrame('Frame', nil, frame)
		screen.shell = Kit:Shell(screen, {surface = 'glass', radius = 8, alpha = 0.55, shadow = false})
		glass = screen.shell
	else
		screen = Kit:Screen(frame, {inset = 3, corner = 9})
		glass = screen.screen.glass
	end
	screen:SetPoint('TOPLEFT', device.deck, 'BOTTOMLEFT', -GEO.screen, 3)
	screen:SetPoint('BOTTOMRIGHT', frame, 'BOTTOMRIGHT', GEO.screen, -GEO.screen)
	screen:SetFrameLevel(max(frame:GetFrameLevel() - 1, 0))
	-- Its shells (and the glass's details) come along, under the window's text.
	Kit:Relevel(screen)
	screen:EnableMouse(false)
	device.screen, device.glass = screen, glass
	Detail(glass)

	-- The tabs' track and the key rail.
	local well = CreateFrame('Frame', nil, device)
	well:SetPoint('BOTTOMLEFT', device.deck, 'BOTTOMLEFT', -GEO.screen, GEO.wellLow)
	well:SetPoint('BOTTOMRIGHT', device.deck, 'BOTTOMRIGHT', GEO.screen, GEO.wellLow)
	well:SetHeight(GEO.well)
	well:EnableMouse(false)
	Recess(well, housing, 6, true)
	device.well = well
	if housing ~= 'hairline' then
		device.rail = CreateFrame('Frame', nil, device)
		device.rail:EnableMouse(false)
		device.rail:Hide()
		Recess(device.rail, housing, 8)
	end

	BuildHeader(device, index)
	BuildCopyKey(frame, device)
	BuildField(frame, device)
	devices[frame] = device
	module.LayoutHeader(device)
	module.FitDevice(frame, device)
	module.Retitle(frame, device)
	Kit:SetLed(device.lamp, true)

	frame:HookScript('OnHyperlinkEnter', LinkEnter)
	frame:HookScript('OnHyperlinkLeave', LinkLeave)
	-- The column showing or going: refit the housing (and its rail).
	if buttons and not Forbidden(buttons) then
		buttons:HookScript('OnShow', function() module.QueuePass() end)
		buttons:HookScript('OnHide', function() module.QueuePass() end)
	end
	FontChat(frame)
	SkinTab(_G[name..'Tab'], frame)
	if db.chrome then UI:Safe(module.SkinWindowChrome, frame) end
end

-- Chrome -------------------------------------------------------------------------
-- Round (or square) glass keys for the chat's buttons, a hairline scroll bar,
-- the grip and the combat log's filter bar. Every part is ours and kept in
-- `chrome`; the game's art is only made transparent (alpha and vertex alpha,
-- which its own flash animations can't bring back), so its states still work.
local chrome = setmetatable({}, {__mode = 'k'})
local bottomLamps, bottomState = {}, {}
local overflowLamp

local function HideArt(button)
	for _, getter in ipairs({'GetNormalTexture', 'GetPushedTexture', 'GetHighlightTexture', 'GetDisabledTexture'}) do
		local texture = button[getter] and button[getter](button)
		if Is(texture, 'Texture') then
			texture:SetAlpha(0)
			texture:SetVertexColor(1, 1, 1, 0)
		end
	end
end

local function KeyRadius() return DB().keyShape == 'square' and 5 or 64 end

-- A cap of our own under one of the game's buttons, inset a little so a
-- column of them reads as separate keys.
local function KeyCap(button, parts)
	local cap = CreateFrame('Frame', nil, button)
	local width = Plain(button:GetWidth())
	local inset = (width > 0 and width < 24) and 1 or 3
	cap:SetPoint('TOPLEFT', inset, -inset)
	cap:SetPoint('BOTTOMRIGHT', -inset, inset)
	cap:SetFrameLevel(max(button:GetFrameLevel() - 1, 0))
	cap:EnableMouse(false)
	parts.cap = cap
	parts.shell = Kit:Shell(cap, {surface = 'glass', radius = KeyRadius(), shadowAlpha = 0.25})
end

-- Hover lifts a key to charcoal; pressed it goes black and its glyph travels down.
local function KeyState(parts, down)
	if parts.icon then
		parts.icon:SetPoint('CENTER', 0, down and -1 or 0)
		Kit:Tint(parts.icon, (down or parts.hover) and 'darkInk' or 'darkDim')
	end
	Kit:SetSurface(parts.shell, down and 'screen' or (parts.hover and 'dark' or 'glass'))
end

local function KeyScripts(button, parts)
	button:HookScript('OnEnter', function() parts.hover = true; KeyState(parts, false) end)
	button:HookScript('OnLeave', function() parts.hover = false; KeyState(parts, false) end)
	button:HookScript('OnMouseDown', function() KeyState(parts, true); KeySound('down') end)
	button:HookScript('OnMouseUp', function() KeyState(parts, false); KeySound('up') end)
end

-- icon: one of the kit's icons, drawn over the game's hidden art; nil keeps
-- the game's own icon (voice states), grayed and inked to match.
local function GlassKey(button, icon, size)
	if not Is(button, 'Button') or chrome[button] then return nil end
	local parts = {}
	chrome[button] = parts
	KeyCap(button, parts)
	if icon then
		HideArt(button)
		parts.icon = Kit:Icon(button, icon, size or 12, 'darkDim')
		parts.icon:SetPoint('CENTER')
	else
		for _, getter in ipairs({'GetNormalTexture', 'GetPushedTexture', 'GetDisabledTexture'}) do
			local texture = button[getter] and button[getter](button)
			if Is(texture, 'Texture') then
				texture:SetDesaturated(true)
				texture:SetVertexColor(Kit:RGB('darkInk'))
			end
		end
		local glow = button.GetHighlightTexture and button:GetHighlightTexture()
		if Is(glow, 'Texture') then glow:SetAlpha(0); glow:SetVertexColor(1, 1, 1, 0) end
		local inner = button.Icon or button.icon
		if Is(inner, 'Texture') then inner:SetDesaturated(true); inner:SetVertexColor(Kit:RGB('darkInk')) end
	end
	KeyScripts(button, parts)
	return parts
end

-- The scroll bar: a hairline track and a small pill thumb that lights on hover; the step arrows go.
local function SkinScrollBar(bar)
	if Forbidden(bar) or not bar.GetRegions or chrome[bar] then return end
	chrome[bar] = {}
	for _, region in ipairs({bar:GetRegions()}) do if Is(region, 'Texture') then region:SetAlpha(0) end end
	for _, key in ipairs({'Back', 'Forward'}) do
		local step = bar[key]
		if Is(step, 'Button') then
			HideArt(step)
			for _, region in ipairs({step:GetRegions()}) do if Is(region, 'Texture') then region:SetAlpha(0) end end
		end
	end
	local track = bar.Track
	if Forbidden(track) or not track.GetRegions then return end
	for _, region in ipairs({track:GetRegions()}) do if Is(region, 'Texture') then region:SetAlpha(0) end end
	local line = track:CreateTexture(nil, 'BACKGROUND')
	line:SetColorTexture(1, 1, 1, 1)
	Kit:Tint(line, 'darkEdge')
	line:SetPoint('TOP', 0, -2)
	line:SetPoint('BOTTOM', 0, 2)
	line:SetWidth(UI.Pixel.Px(track, 1))
	local thumb = track.Thumb
	if Forbidden(thumb) or not thumb.GetRegions then return end
	for _, region in ipairs({thumb:GetRegions()}) do if Is(region, 'Texture') then region:SetAlpha(0) end end
	local pill = thumb:CreateTexture(nil, 'ARTWORK')
	pill:SetTexture(Kit.media..'round-3.tga')
	if pill.SetTextureSliceMargins then pill:SetTextureSliceMargins(3, 3, 3, 3) end
	pill:SetPoint('TOP', 0, -1)
	pill:SetPoint('BOTTOM', 0, 1)
	pill:SetWidth(4)
	Kit:Tint(pill, 'darkDim')
	thumb:HookScript('OnEnter', function() Kit:Tint(pill, 'lamp') end)
	thumb:HookScript('OnLeave', function() Kit:Tint(pill, 'darkDim') end)
end

-- Per window: the scroll-to-bottom key (its lamp: dim while scrolled up,
-- blinking amber once new lines arrive), the scroll bar and the resize grip.
function module.SkinWindowChrome(frame)
	local name = frame:GetName() or ''
	local bottom = frame.ScrollToBottomButton or _G[name..'ButtonFrameBottomButton']
	if Is(bottom, 'Button') and not chrome[bottom] then
		local parts = GlassKey(bottom, 'chevron-down', 11)
		-- The game's flash says only "not at the bottom"; the lamp says more.
		local flash = bottom.Flash or _G[name..'ButtonFrameBottomButtonFlash']
		if Is(flash, 'Texture') then Clear(flash) end
		if parts then
			local lamp = Kit:Led(bottom, 4, false)
			lamp:SetPoint('TOPRIGHT', bottom, 'TOPRIGHT', -3, -3)
			bottomLamps[frame] = lamp
			bottomState[frame] = nil
		end
	end
	for _, key in ipairs({'UpButton', 'DownButton'}) do
		local step = _G[name..'ButtonFrame'..key]
		if Is(step, 'Button') then GlassKey(step, key == 'UpButton' and 'chevron-up' or 'chevron-down', 11) end
	end
	SkinScrollBar(frame.ScrollBar)
	local grip = frame.ResizeButton or _G[name..'ResizeButton']
	if Is(grip, 'Button') and not chrome[grip] then
		local parts = {}
		chrome[grip] = parts
		HideArt(grip)
		parts.icon = Kit:Icon(grip, 'grip', 12, 'darkDim')
		parts.icon:SetPoint('CENTER')
		grip:HookScript('OnEnter', function() Kit:Tint(parts.icon, 'darkInk') end)
		grip:HookScript('OnLeave', function() Kit:Tint(parts.icon, 'darkDim') end)
	end
end

local function PaintBottomLamp(chat, state)
	local lamp = bottomLamps[chat]
	if not lamp or bottomState[chat] == state then return end
	bottomState[chat] = state
	Kit:Blink(lamp, nil, false)
	if state == 'new' then
		Kit:SetLed(lamp, true, 'amber')
		Kit:Breathe(lamp, false)
		Kit:Blink(lamp, 0.8)
	elseif state == 'up' then
		Kit:SetLed(lamp, true, 'darkDim')
	else
		Kit:SetLed(lamp, false)
	end
end

-- The dock's overflow key lights while the game pulses it (a hidden tab has news).
local function PaintOverflow()
	local button = _G.GeneralDockManagerOverflowButton
	if not overflowLamp or not Is(button, 'Button') then return end
	local highlight = button:GetHighlightTexture()
	local anim = Is(highlight, 'Texture') and highlight.FlashAnim
	local playing = anim and anim.IsPlaying and anim:IsPlaying()
	if IsSecret(playing) then return end
	local on = playing and true or false
	if overflowLamp.on == on then return end
	Kit:Blink(overflowLamp, nil, false)
	Kit:SetLed(overflowLamp, on, on and 'amber' or nil)
	if on then
		Kit:Breathe(overflowLamp, false)
		Kit:Blink(overflowLamp, 0.8)
	end
end

-- The game's buttons that are shared by every window.
local SHARED = {
	{'ChatFrameMenuButton', 'more'}, {'ChatFrameChannelButton', 'align-left'}, {'TextToSpeechButton', 'speaker'},
	{'ChatFrameToggleVoiceDeafenButton'}, {'ChatFrameToggleVoiceMuteButton'},
}

local function SkinSocial()
	local social = _G.QuickJoinToastButton
	if not Is(social, 'Button') or chrome[social] then return end
	local parts = {}
	chrome[social] = parts
	for _, region in ipairs({social:GetRegions()}) do
		if Is(region, 'Texture') then region:SetAlpha(0)
		elseif Is(region, 'FontString') then
			Kit:Font(region, 9, 'OUTLINE', true)
			Kit:Tint(region, 'darkInk')
		end
	end
	HideArt(social)
	local count = social.FriendCount
	if Is(count, 'FontString') then
		Kit:Font(count, 9, 'OUTLINE', true)
		Kit:Tint(count, 'darkInk')
	end
	KeyCap(social, parts)
	parts.icon = Kit:Icon(social, 'user', 12, 'darkDim')
	parts.icon:SetPoint('CENTER', 0, Is(count, 'FontString') and 3 or 0)
	KeyScripts(social, parts)
end

-- The dock's overflow key (with its lamp) and its list of docked windows, as a glass popover.
local function SkinOverflow()
	local button = _G.GeneralDockManagerOverflowButton
	if Is(button, 'Button') and not chrome[button] then
		local parts = GlassKey(button, 'chevron-down', 10)
		if parts then
			overflowLamp = Kit:Led(button, 3, false)
			overflowLamp:SetPoint('TOPRIGHT', button, 'TOPRIGHT', -1, -1)
		end
	end
	local list = _G.GeneralDockManagerOverflowButtonList
	if not Is(list, 'Frame') or chrome[list] then return end
	chrome[list] = {}
	for _, region in ipairs({list:GetRegions()}) do if Is(region, 'Texture') then region:SetAlpha(0) end end
	if list.NineSlice and not Forbidden(list.NineSlice) then list.NineSlice:SetAlpha(0) end
	Kit:Shell(list, {surface = 'glass', radius = 6, shadowAlpha = 0.4})
end

-- The combat log's filter bar: a strip of dark glass on the screen with
-- printed filters that tick when chosen, a filter key and the progress bar as
-- a thin lamp line.
local function SkinCombatLog()
	local bar = _G.CombatLogQuickButtonFrame_Custom
	if not Is(bar, 'Frame') then return end
	local parts = chrome[bar]
	if not parts then
		parts = {}
		chrome[bar] = parts
		for _, region in ipairs({bar:GetRegions()}) do if Is(region, 'Texture') then region:SetAlpha(0) end end
		Clear(_G.CombatLogQuickButtonFrame_CustomTexture)
		parts.strip = CreateFrame('Frame', nil, bar)
		parts.strip:SetPoint('TOPLEFT', 0, -1)
		parts.strip:SetPoint('BOTTOMRIGHT', 0, 1)
		parts.strip:SetFrameLevel(max(bar:GetFrameLevel() - 1, 0))
		Kit:Shell(parts.strip, {surface = 'glass', radius = 4, shadow = false, alpha = 0.85})
		local progress = _G.CombatLogQuickButtonFrame_CustomProgressBar or bar.ProgressBar
		if Is(progress, 'StatusBar') then
			for _, region in ipairs({progress:GetRegions()}) do
				if Is(region, 'Texture') and region ~= progress:GetStatusBarTexture() then region:SetAlpha(0) end
			end
			progress:SetStatusBarTexture([[Interface\Buttons\WHITE8X8]])
			local r, g, b = Kit:RGB('lamp')
			progress:SetStatusBarColor(r, g, b, 0.85)
		end
		GlassKey(_G.CombatLogQuickButtonFrame_CustomAdditionalFilterButton, 'filter', 10)
	end
	-- Filter buttons are made as filters are added: catch new ones each pass.
	for index = 1, 20 do
		local button = _G['CombatLogQuickButtonFrameButton'..index]
		if not button then break end
		if not chrome[button] and Is(button, 'Button') then
			chrome[button] = {}
			HideArt(button)
			local text = button.GetFontString and button:GetFontString()
			if Is(text, 'FontString') then
				Kit:Font(text, 9, nil, true)
				Kit:Tint(text, 'darkDim')
			end
			button:HookScript('OnEnter', function(self)
				local label = self.GetFontString and self:GetFontString()
				if Is(label, 'FontString') then Kit:Tint(label, 'darkInk') end
			end)
			button:HookScript('OnLeave', function(self)
				local label = self.GetFontString and self:GetFontString()
				if Is(label, 'FontString') then Kit:Tint(label, 'darkDim') end
			end)
			button:HookScript('OnMouseDown', function() KeySound('tick') end)
		end
	end
end

function module.SkinChrome()
	if not DB().chrome then return end
	for _, entry in ipairs(SHARED) do UI:Safe(GlassKey, _G[entry[1]], entry[2], entry[3]) end
	UI:Safe(SkinSocial)
	UI:Safe(SkinOverflow)
	UI:Safe(SkinCombatLog)
end

-- The ticker ----------------------------------------------------------------------------
-- Twice a second: new lines in each window (its line count and last line,
-- nothing more), the tab lamps, the scroll and overflow lamps and the header LCDs.
local function LastLine(frame)
	local count = frame.GetNumMessages and frame:GetNumMessages() or 0
	if IsSecret(count) then return nil, nil end
	if count == 0 then return 0, nil end
	local text = frame:GetMessageInfo(count)
	if IsSecret(text) then text = '\0secret'..count end
	return count, text
end

local function AtBottom(chat)
	if not chat.AtBottom then return true end
	local at = chat:AtBottom()
	if IsSecret(at) then return true end
	return at and true or false
end

function module.Readouts()
	local total = 0
	for tab, count in pairs(unread) do if tab:IsShown() then total = total + count end end
	local clock = date(DB().timestamps == '%I:%M %p ' and '%I:%M' or '%H:%M')
	for _, device in pairs(devices) do
		if device:IsVisible() then module.Readout(device, total, clock) end
	end
end

function module.Tick()
	for tab, chat in pairs(tabFrames) do
		local count, last = LastLine(chat)
		local before = seen[chat]
		if count and before then
			local added = 0
			if count > before[1] then added = count - before[1]
			elseif count == before[1] and last ~= before[2] then added = 1 end
			if added > 0 then
				if InView(chat) then
					if not AtBottom(chat) then scrolled[chat] = true end
				elseif tab:IsShown() then
					unread[tab] = min((unread[tab] or 0) + added, 999)
				end
			end
			before[1], before[2] = count, last
		elseif count then
			seen[chat] = {count, last}
			-- A whisper window that opened behind the one in view: its first lines are news.
			local temporary = chat.isTemporary
			if not IsSecret(temporary) and temporary and count > 0 and not InView(chat) and tab:IsShown() then unread[tab] = count end
		end
		local bottom = AtBottom(chat)
		if bottom then scrolled[chat] = nil end
		PaintBottomLamp(chat, scrolled[chat] and 'new' or (not bottom and 'up') or 'off')
	end
	module.PaintTabs()
	module.Readouts()
	PaintOverflow()
end

-- Lines that arrive without anyone saying them (history coming back) aren't news.
function module.Baseline()
	for _, chat in pairs(tabFrames) do
		local count, last = LastLine(chat)
		if count then seen[chat] = {count, last} end
	end
	wipe(unread)
end

-- One pass over every chat window, including whisper windows opened since.
local function Pass()
	local names = _G.CHAT_FRAMES or {}
	for index = 1, max(NUM_CHAT_WINDOWS or 10, #names) do
		local frame = _G['ChatFrame'..index]
		if frame then
			UI:Safe(SkinChatFrame, frame, index)
			UI:Safe(PlaceEditBox, frame)
		end
	end
	for _, name in ipairs(names) do
		local frame = _G[name]
		if frame and not devices[frame] then
			UI:Safe(SkinChatFrame, frame, frame:GetID() or 0)
			UI:Safe(PlaceEditBox, frame)
		end
	end
	module.SkinChrome()
	for frame, device in pairs(devices) do
		UI:Safe(module.FitDevice, frame, device)
		UI:Safe(module.Retitle, frame, device)
	end
	for tab in pairs(lamps) do UI:Safe(FitTab, tab) end
	UI:Safe(module.PaintTabs, true)
end

local pending
function module.QueuePass()
	if pending then return end
	pending = true
	C_Timer.After(0, function()
		pending = nil
		Pass()
	end)
end

-- Copy window ---------------------------------------------------------------------
-- A device with the window's lines, readable ones only, in a text area that
-- selects everything on open so Ctrl+C copies it.
local copier
local function BuildCopier()
	copier = Kit:Device(UIParent, {model = 'CP-1', title = 'Copy chat', name = 'JiberishSpec01ChatCopy', width = 620, height = 380, radius = 14})
	copier:SetPoint('CENTER')
	copier:SetFrameStrata('DIALOG')
	copier:EnableMouse(true)
	copier:SetMovable(true)
	copier:RegisterForDrag('LeftButton')
	copier:SetScript('OnDragStart', copier.StartMoving)
	copier:SetScript('OnDragStop', copier.StopMovingOrSizing)
	Kit:SetLed(copier.lamp, true)
	local screen = Kit:Screen(copier, {inset = 4, radius = 8})
	screen:SetPoint('TOPLEFT', 12, -28)
	screen:SetPoint('BOTTOMRIGHT', -12, 12)
	local scroll = CreateFrame('ScrollFrame', nil, screen.screen)
	scroll:SetPoint('TOPLEFT', 8, -8)
	scroll:SetPoint('BOTTOMRIGHT', -8, 8)
	local edit = CreateFrame('EditBox', nil, scroll)
	edit:SetMultiLine(true)
	edit:SetAutoFocus(false)
	edit:SetWidth(580)
	Kit:Font(edit, 11)
	Kit:Tint(edit, 'darkInk')
	edit:SetScript('OnEscapePressed', function() copier:Hide() end)
	scroll:SetScrollChild(edit)
	scroll:EnableMouseWheel(true)
	scroll:SetScript('OnMouseWheel', function(self, delta)
		local range = self:GetVerticalScrollRange()
		self:SetVerticalScroll(min(max(self:GetVerticalScroll() - delta * 40, 0), range))
	end)
	copier.edit, copier.scroll = edit, scroll
	local close = Kit:Key(copier, {width = 22, height = 18, round = true, icon = 'close', iconSize = 9,
		onClick = function() copier:Hide() end})
	close:SetPoint('TOPRIGHT', -10, -5)
	copier:SetScript('OnHide', function() Kit:Play('latch-up') end)
	tinsert(UISpecialFrames, 'JiberishSpec01ChatCopy')
	copier:Hide()
end

function CopyWindow(frame)
	if not copier then BuildCopier() end
	local lines = {}
	local count = frame.GetNumMessages and frame:GetNumMessages() or 0
	if IsSecret(count) then count = 0 end
	for index = 1, count do
		local text, r, g, b = frame:GetMessageInfo(index)
		if Readable(text) then
			if IsSecret(r) or IsSecret(g) or IsSecret(b) then r, g, b = 1, 1, 1 end
			-- Textures inline in the line don't copy; leave them out.
			text = gsub(text, '|T.-|t', '')
			lines[#lines + 1] = Hex(r, g, b)..text..'|r'
		end
	end
	copier.edit:SetText(table.concat(lines, '\n'))
	Kit:Open(copier)
	Kit:Play('open')
	C_Timer.After(0, function()
		copier.scroll:SetVerticalScroll(copier.scroll:GetVerticalScrollRange())
		copier.edit:SetFocus()
		copier.edit:HighlightText()
	end)
end

-- Web addresses ------------------------------------------------------------------
-- An http(s):// or www. address becomes the game's addon link type, whose
-- clicks reach addons through EventRegistry's "SetItemRef" (the game can't
-- open a browser, so a click shows the address ready to copy).
local URL_PREFIX = 'addon:JiberishSpec01:url:'
local function Linked(url)
	return format('|cff4aa3ff|H%s%s|h[%s]|h|r', URL_PREFIX, url, url)
end

local function WrapURLs(text)
	if not Readable(text) or not (find(text, '://', 1, true) or find(text, 'www.', 1, true)) then return nil end
	-- Leave text inside existing links alone: only plain words are matched.
	local changed = false
	local out = gsub(text, '(%S+)', function(word)
		if find(word, '|H', 1, true) or find(word, '|h', 1, true) then return nil end
		if match(word, '^%a[%w+.-]*://%S') or match(word, '^www%.[%w%-]+%.%a') then
			changed = true
			return Linked(word)
		end
	end)
	return changed and out or nil
end

-- A message filter returns a new message only when it changed something:
-- with the text or any other argument secret it returns false and nothing
-- else, so the game uses its own arguments untouched. (Shortening channel
-- names or printing them as badges isn't offered: the game builds the
-- "[2. Trade]" prefix itself after the filters, from the channel argument it
-- also matches against each window's channel list, so neither can change here.)
local function Filter(_, _, text, ...)
	if not DB().urls or IsSecret(text) then return false end
	for index = 1, select('#', ...) do
		if IsSecret((select(index, ...))) then return false end
	end
	local wrapped = WrapURLs(text)
	if not wrapped then return false end
	return false, wrapped, ...
end

local FILTERED = {'CHAT_MSG_SAY', 'CHAT_MSG_YELL', 'CHAT_MSG_GUILD', 'CHAT_MSG_OFFICER', 'CHAT_MSG_PARTY', 'CHAT_MSG_PARTY_LEADER',
	'CHAT_MSG_RAID', 'CHAT_MSG_RAID_LEADER', 'CHAT_MSG_INSTANCE_CHAT', 'CHAT_MSG_INSTANCE_CHAT_LEADER', 'CHAT_MSG_WHISPER',
	'CHAT_MSG_WHISPER_INFORM', 'CHAT_MSG_BN_WHISPER', 'CHAT_MSG_BN_WHISPER_INFORM', 'CHAT_MSG_CHANNEL', 'CHAT_MSG_COMMUNITIES_CHANNEL'}

local urlBox
local function ShowURL(url)
	if not urlBox then
		urlBox = Kit:Device(UIParent, {model = 'LN-1', title = 'Link', name = 'JiberishSpec01ChatLink', width = 440, height = 84, radius = 12})
		urlBox:SetPoint('CENTER', 0, 120)
		urlBox:SetFrameStrata('DIALOG')
		urlBox:EnableMouse(true)
		Kit:SetLed(urlBox.lamp, true)
		urlBox.field = Kit:TextField(urlBox, {width = 380})
		urlBox.field:SetPoint('BOTTOMLEFT', 12, 12)
		urlBox.hint = Kit:Label(urlBox, 'Ctrl+C to copy', 'dim', 8)
		urlBox.hint:SetPoint('TOPRIGHT', -40, -11)
		local close = Kit:Key(urlBox, {width = 22, height = 18, round = true, icon = 'close', iconSize = 9,
			onClick = function() urlBox:Hide() end})
		close:SetPoint('TOPRIGHT', -10, -5)
		urlBox.field.edit:SetScript('OnEscapePressed', function() urlBox:Hide() end)
		urlBox.field.edit:SetScript('OnTextChanged', function(self, user) if user then self:SetText(urlBox.url or '') self:HighlightText() end end)
		tinsert(UISpecialFrames, 'JiberishSpec01ChatLink')
	end
	urlBox.url = url
	urlBox.field:SetValue(url)
	Kit:Open(urlBox)
	Kit:Play('open')
	urlBox.field.edit:SetFocus()
	urlBox.field.edit:HighlightText()
end

local function OnLinkClicked(_, link)
	if type(link) ~= 'string' or IsSecret(link) then return end
	local url = match(link, '^addon:JiberishSpec01:url:(.+)$')
	if url then ShowURL(url) end
end

-- History -------------------------------------------------------------------------
-- At logout each window's last lines are read back and kept for this
-- character; at login they're shown again, dimmed, under a divider.
local replayed = {} -- frame -> {count, first line text}
local DIVIDER = '|cff5c5d58—— history ——|r'
-- History is the character's, not the profile's: it lives in account-level
-- state that profiles (and exported profile strings) never touch. The key is
-- worked out when it's needed, at login or logout, never at file load.
local function CharacterKey()
	local name = UnitName('player')
	local realm = GetRealmName and GetRealmName() or ''
	if IsSecret(name) or IsSecret(realm) or not name then return nil end
	return name..' - '..(realm or '')
end

-- The log store, with history kept in the profile by earlier builds moved
-- over once (an old 'Name-Realm' key becomes 'Name - Realm').
local function Log()
	local log = UI:Account('chatlog')
	local old = UI.db.chat.log
	if type(old) == 'table' then
		for key, store in pairs(old) do
			if type(key) == 'string' and type(store) == 'table' then
				local name, realm = match(key, '^(.-)%-(.*)$')
				local newKey = name and (name..' - '..realm) or key
				if log[newKey] == nil then log[newKey] = store end
			end
		end
	end
	UI.db.chat.log = nil
	return log
end

-- The replayed lines sit just above the divider. A window that has dropped
-- old lines since has moved them up, so the divider is looked for near where
-- it was put; if it's gone, so are the replayed lines.
local function ReplayedRange(frame, count)
	local back = replayed[frame]
	if not back then return nil end
	for index = min(back.divider, count), 1, -1 do
		local text = frame:GetMessageInfo(index)
		if not IsSecret(text) and text == DIVIDER then
			return max(1, index - back.lines), index
		end
	end
	return nil
end

local function SaveHistory()
	local db = DB()
	local key = CharacterKey()
	if not db.history or not key then return end
	local log = Log()
	log[key] = log[key] or {}
	local store = log[key]
	local keep = db.historyLines or 40
	for index = 1, NUM_CHAT_WINDOWS or 10 do
		local frame = _G['ChatFrame'..index]
		local count = frame and frame.GetNumMessages and frame:GetNumMessages() or 0
		if frame and not IsSecret(count) and count > 0 then
			-- The stored lines keep their own colours; the window's replayed
			-- (dimmed) copies are skipped, so nothing repeats or dims further.
			local lines = {}
			for _, line in ipairs(store[index] or {}) do lines[#lines + 1] = line end
			local from, to = ReplayedRange(frame, count)
			for line = 1, count do
				if not (from and line >= from and line <= to) then
					local text, r, g, b = frame:GetMessageInfo(line)
					if Readable(text) and text ~= DIVIDER and not IsSecret(r) and not IsSecret(g) and not IsSecret(b) then
						lines[#lines + 1] = {text, r or 1, g or 1, b or 1}
					end
				end
			end
			while #lines > keep do table.remove(lines, 1) end
			store[index] = lines
		end
	end
end

local function ReplayHistory()
	local db = DB()
	local key = CharacterKey()
	local store = key and db.history and Log()[key]
	if not store then return end
	for index, lines in pairs(store) do
		local frame = type(index) == 'number' and _G['ChatFrame'..index]
		if frame and #lines > 0 and not Forbidden(frame) then
			for _, line in ipairs(lines) do
				frame:AddMessage(line[1], line[2] * 0.55, line[3] * 0.55, line[4] * 0.55)
			end
			frame:AddMessage(DIVIDER)
			local after = frame:GetNumMessages()
			-- Where the divider went, and how many replayed lines sit above it.
			if not IsSecret(after) then replayed[frame] = {divider = after, lines = #lines} end
		end
	end
end

-- Chat bubbles -----------------------------------------------------------------------
-- Outside instances bubbles can be read; inside, they're the game's alone.
local bubbled = setmetatable({}, {__mode = 'k'})
local function SkinBubble(bubble)
	if Forbidden(bubble) or bubbled[bubble] then return end
	local holder = bubble.GetChildren and select(1, bubble:GetChildren())
	if not holder or Forbidden(holder) then return end
	bubbled[bubble] = true
	for _, region in ipairs({holder:GetRegions()}) do
		if region:IsObjectType('Texture') then region:SetAlpha(0)
		elseif region:IsObjectType('FontString') then
			local _, size = region:GetFont()
			region:SetFont(Kit:FontPath(false), (not IsSecret(size) and size) or 12, '')
		end
	end
	local glass = CreateFrame('Frame', nil, holder)
	glass:SetPoint('TOPLEFT', 4, -4)
	glass:SetPoint('BOTTOMRIGHT', -4, 4)
	glass:SetFrameLevel(max(holder:GetFrameLevel() - 1, 0))
	Kit:Shell(glass, {surface = 'glass', radius = 8, shadowAlpha = 0.25})
	if holder.Tail then holder.Tail:SetAlpha(0) end
end

local bubbleScan = CreateFrame('Frame')
bubbleScan:Hide()
bubbleScan:SetScript('OnUpdate', function(self, elapsed)
	self.left = (self.left or 0) - elapsed
	if self.left <= 0 then self:Hide() end
	if not (C_ChatBubbles and C_ChatBubbles.GetAllChatBubbles) then return self:Hide() end
	for _, bubble in pairs(C_ChatBubbles.GetAllChatBubbles(false)) do UI:Safe(SkinBubble, bubble) end
end)
local function ScanBubbles()
	if not DB().bubbles then return end
	if IsInInstance and IsInInstance() then return end
	bubbleScan.left = 0.3
	bubbleScan:Show()
end

-- CVars --------------------------------------------------------------------------
-- Timestamps: the game's choice, off, or a format of ours. Dim, they print in
-- the LCD's dim ink so they read as a column beside the messages: the format
-- itself carries the colour (the game puts it through date()), so no chat
-- format string or message is touched. Turned off, any dim format of ours
-- is put back to plain.
local function Undim(value) return (gsub(gsub(value, '|c%x%x%x%x%x%x%x%x', ''), '|r', '')) end
local function Dim(value)
	local r, g, b = Kit:RGB(Kit:DB().finish == 'graphite' and 'lcdDim' or 'darkDim')
	return Hex(r, g, b)..(gsub(value, '%s+$', ''))..'|r '
end

local function ApplyCVars()
	local db = DB()
	if db.classColors then pcall(SetCVar, 'chatClassColorOverride', '0') end
	local current = GetCVar and GetCVar('showTimestamps')
	if IsSecret(current) or type(current) ~= 'string' then return end
	local plain = Undim(current)
	local want
	if db.timestamps == 'none' then want = 'none'
	elseif db.timestamps ~= 'keep' then want = db.timestamps
	else want = plain end
	if want ~= 'none' and db.stampDim then want = Dim(want) end
	if want ~= current then pcall(SetCVar, 'showTimestamps', want) end
end

-- Whispers ------------------------------------------------------------------------
local lastWhisper = 0
local function Whispered()
	local now = GetTime()
	if now - lastWhisper < 1 then return end
	lastWhisper = now
	if DB().whisperSound then Kit:Play('blip', true) end
	if DB().flash then
		for _, device in pairs(devices) do UI:Safe(module.Alert, device) end
	end
end

function module:Enable()
	Pass()
	local add = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
	if add then for _, event in ipairs(FILTERED) do add(event, Filter) end end
	if EventRegistry and EventRegistry.RegisterCallback then
		EventRegistry:RegisterCallback('SetItemRef', OnLinkClicked, module)
	end
	ApplyCVars()
	-- Post-hooks, their arguments never looked at: windows opening, docking,
	-- renaming or changing side, and the combat log's filters changing queue a
	-- pass; the game repainting its tabs gets our inks back at once, and a
	-- new tab chosen repaints the lamps (with a detent).
	local hooked = {}
	local function Hook(name, callback)
		if hooked[name] or type(_G[name]) ~= 'function' then return end
		hooked[name] = true
		hooksecurefunc(name, callback)
	end
	local function QueuePass() module.QueuePass() end
	for _, name in ipairs({'FCF_OpenTemporaryWindow', 'Blizzard_CombatLog_Update_QuickButtons', 'FCF_SetWindowName',
		'FCFDock_UpdateTabs', 'FCF_SetButtonSide', 'FCF_DockFrame', 'FCF_UnDockFrame'}) do
		Hook(name, QueuePass)
	end
	Hook('FCFTab_UpdateColors', function() UI:Safe(module.InkTabs) end)
	Hook('FCFDock_SelectWindow', function() UI:Safe(module.PaintTabs) end)
	local function WatchFilterBar()
		local bar = _G.CombatLogQuickButtonFrame_Custom
		if hooked.filterBar or not Is(bar, 'Frame') then return end
		hooked.filterBar = true
		bar:HookScript('OnShow', QueuePass)
		bar:HookScript('OnHide', QueuePass)
	end
	WatchFilterBar()
	local loader = CreateFrame('Frame')
	loader:RegisterEvent('ADDON_LOADED')
	loader:SetScript('OnEvent', function(_, _, addon)
		if addon == 'Blizzard_CombatLog' then
			Hook('Blizzard_CombatLog_Update_QuickButtons', QueuePass)
			WatchFilterBar()
			QueuePass()
		end
	end)
	-- Screens' corner marks are drawn in physical pixels.
	UI.Pixel.OnChange(function()
		for glass, marks in pairs(marked) do FitMarks(glass, marks) end
	end)
	local driver = CreateFrame('Frame')
	for _, event in ipairs({'PLAYER_ENTERING_WORLD', 'UPDATE_CHAT_WINDOWS', 'UPDATE_FLOATING_CHAT_WINDOWS', 'CHAT_MSG_WHISPER',
		'CHAT_MSG_WHISPER_INFORM', 'CHAT_MSG_BN_WHISPER', 'CHAT_MSG_BN_WHISPER_INFORM', 'PLAYER_LOGOUT', 'CHAT_MSG_SAY',
		'CHAT_MSG_YELL', 'CHAT_MSG_PARTY', 'CHAT_MSG_PARTY_LEADER', 'CHAT_MSG_MONSTER_SAY', 'CHAT_MSG_MONSTER_YELL',
		'CHAT_MSG_MONSTER_PARTY'}) do
		pcall(driver.RegisterEvent, driver, event)
	end
	local first = true
	driver:SetScript('OnEvent', function(_, event)
		if event == 'PLAYER_LOGOUT' then return UI:Safe(SaveHistory) end
		if event == 'CHAT_MSG_WHISPER' or event == 'CHAT_MSG_BN_WHISPER' then Whispered() end
		if event:find('^CHAT_MSG_') and not event:find('WHISPER') then return ScanBubbles() end
		if event == 'PLAYER_ENTERING_WORLD' and first then
			first = false
			-- Late enough that the loading screen has gone.
			C_Timer.After(0.8, function() UI:Safe(module.PowerAll) end)
			C_Timer.After(1, function()
				UI:Safe(ReplayHistory)
				UI:Safe(module.Baseline)
			end)
		end
		module.QueuePass()
	end)
	C_Timer.NewTicker(0.5, function() UI:Safe(module.Tick) end)
end

function module:Refresh()
	wipe(placed)
	for frame, device in pairs(devices) do
		UI:Safe(FontChat, frame)
		UI:Safe(module.FontField, frame)
		UI:Safe(PlaceEditBox, frame)
		UI:Safe(module.PaintField, frame)
		UI:Safe(module.LayoutHeader, device)
	end
	for tab in pairs(lamps) do
		local text = TabText(tab)
		if text then Kit:Font(text, DB().tabSize or 9, Flags(), true) end
		UI:Safe(FitTab, tab)
	end
	-- The side keys' shape.
	local radius = KeyRadius()
	for _, parts in pairs(chrome) do
		if parts.shell then
			parts.shell.opts.radius = radius
			Kit:FitShell(parts.shell)
		end
	end
	for box, block in pairs(carets) do
		if not DB().caret or not box:HasFocus() then block:Hide() end
	end
	ApplyCVars()
	UI:Safe(module.PaintTabs, true, true)
	UI:Safe(module.Readouts)
end

UI:RegisterPage('chat', {title = 'Chat', order = 13, cards = {
	{title = 'Style', rows = {
		{'segmented', 'Style', 'style.chat', items = {{'display', 'Device'}, {'blizzard', 'Blizzard'}}, reload = true,
			note = 'Messages on a black display in a housing; tabs in its header.'},
		{'segmented', 'Housing', 'chat.housing', items = {{'device', 'Device'}, {'glass', 'Dark glass'}, {'hairline', 'Hairline'}},
			reload = true, since = '0.5.1', note = 'The light device, dark glass, or no housing: a faint display with a fine edge.'},
		{'switch', 'Chat buttons', 'chat.chrome', 'The menu, channel, social, voice, text-to-speech and scroll buttons as glass keys, a hairline scroll bar, and the combat log\'s filter bar in glass.',
			reload = true, since = '0.5.1'},
		{'segmented', 'Side keys', 'chat.keyShape', items = {{'round', 'Round'}, {'square', 'Square'}}, since = '0.5.2',
			note = 'The chat buttons as round glass keys or square keycaps.'},
		{'segmented', 'Header readout', 'chat.headerLcd', items = {{'auto', 'Auto'}, {'clock', 'Clock'}, {'unread', 'Unread'}, {'off', 'Off'}},
			since = '0.5.2', note = 'The LCD in the header: new lines in your other windows, the time, or (auto) news when there is some and the time otherwise.'},
		{'segmented', 'Typeface', 'chat.font', items = {{'plex', 'Plex Mono'}, {'game', 'Game'}}},
		{'slider', 'Text size', 'chat.fontSize', 9, 18, 1},
		{'slider', 'Line spacing', 'chat.lineSpacing', 0, 6, 1, 'Room between lines of chat.', since = '0.5.2'},
		{'segmented', 'Outline', 'chat.outline', items = {{'none', 'None'}, {'outline', 'Thin'}, {'thick', 'Thick'}}, since = '0.5.1'},
		{'switch', 'Text shadow', 'chat.shadow', 'A soft drop shadow under the text (with no outline).', since = '0.5.1'},
		{'slider', 'Tab text size', 'chat.tabSize', 8, 14, 1, since = '0.5.1'},
	}},
	{title = 'Text field', rows = {
		{'switch', 'Text field on top', 'chat.editTop', 'Type above the tabs instead of under the messages.', reload = true},
		{'switch', 'Channel badge', 'chat.badge', 'A printed badge in the channel\'s colour (Say, Guild, Party, Tell...) at the start of the field.', since = '0.5.2'},
		{'switch', 'Character count', 'chat.countLcd', 'An LCD counting what you\'ve typed; red near the limit.', since = '0.5.2'},
		{'switch', 'Block caret', 'chat.caret', 'The reference\'s blinking block cursor while you type.', since = '0.5.2'},
		{'switch', 'Typing sounds', 'sound.chat', 'A key click for each character typed.'},
	}},
	{title = 'Messages', rows = {
		{'switch', 'Web addresses', 'chat.urls', 'Addresses become links; click one to copy it.'},
		{'switch', 'Class colored names', 'chat.classColors', 'Names in their class color.'},
		{'segmented', 'Timestamps', 'chat.timestamps', items = {{'keep', 'Game'}, {'none', 'Off'}, {'%H:%M ', '24 h'}, {'%I:%M %p ', '12 h'}}},
		{'switch', 'Dim timestamps', 'chat.stampDim', 'Timestamps in the LCD\'s dim ink, so they read as a column beside the messages. This writes a colour into the game\'s own timestamp setting (turn it off to put it back).', since = '0.5.2'},
		{'switch', 'Link tooltips', 'chat.linkTips', 'Hover an item or spell link to see it.'},
	}},
	{title = 'Windows', rows = {
		{'switch', 'Copy key', 'chat.copy', 'A key in each window\'s header copies its text.'},
		{'switch', 'History', 'chat.history', 'Your last lines come back, dimmed, after a reload or relog.'},
		{'slider', 'History lines', 'chat.historyLines', 10, 120, 10},
		{'switch', 'Activity lamps', 'chat.flash', 'A tab\'s lamp breathes when its window has new lines (a whisper blinks amber), and a whisper flashes the power lamp.'},
		{'switch', 'Whisper sound', 'chat.whisperSound', 'A blip when someone whispers you.'},
		{'switch', 'Power-on', 'chat.powerOn', 'The display flickers on at login, the lamp lights and the header prints in.', since = '0.5.2'},
		{'switch', 'Device sounds', 'chat.sounds', 'A detent on changing tabs, the power-on hum, a tick as the field opens and key clicks on the chat buttons.', since = '0.5.2'},
		{'switch', 'Glass bubbles', 'chat.bubbles', 'Chat bubbles as dark glass (outside instances, where the game allows it).'},
	}},
}})
