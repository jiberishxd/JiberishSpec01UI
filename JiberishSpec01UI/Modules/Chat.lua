-- Chat as a SPEC-01 device: messages on the reference's black display, tabs
-- printed in a light housing's header with a lamp on the selected one, and the
-- edit box as the reference's black text field. Typing clicks like a keyboard.
-- On top of that: a copy key, clickable web addresses, history across
-- reloads, short channel names, link tooltips on hover, activity lamps on
-- tabs, whisper sounds and glass chat bubbles.
--
-- Every piece of the chat's chrome is skinned too: tabs as segmented keys,
-- the edit box's channel lamp and header, the menu, channel, social, voice and
-- text-to-speech buttons as round glass keys, the scroll-to-bottom key, the
-- scroll bar, the resize grip, the dock's overflow key and the combat log's
-- filter bar. The housing can be the light device, dark glass or a bare
-- hairline display.
--
-- Chat code is where 12.x secret values (whisper names, lockdowns) live, so
-- nothing here replaces AddMessage, overrides the game's chat format strings,
-- or writes fields onto its frames (our parts live in side tables). The only
-- function hooks are post-hooks that take no arguments' values: a new
-- temporary (whisper) window or a combat log filter change queues a skinning
-- pass one frame later. Tab lamps follow the selected window on a light
-- ticker, history is read back from the frames at logout, and message filters
-- only ever return a new message when the text is plain (a secret message is
-- passed on untouched).
local _, UI = ...
local Kit = UI.Kit

local CreateFrame = CreateFrame
local max, min, floor = math.max, math.min, math.floor
local format, gsub, find, match = string.format, string.gsub, string.find, string.match

-- defaults:begin
UI:RegisterDefaults('chat', {
	font = 'plex', fontSize = 12, editTop = false, timestamps = 'keep',
	copy = true, urls = true, history = true, historyLines = 40,
	classColors = true, linkTips = true, flash = true, whisperSound = true, bubbles = true,
	housing = 'device', outline = 'none', shadow = true, tabSize = 9, chrome = true,
})
-- defaults:end

local module = UI:RegisterModule('chat', {})
local function DB() return UI.db.chat end
local function Forbidden(object) return not object or (object.IsForbidden and object:IsForbidden()) end
local function IsSecret(value) return issecretvalue and issecretvalue(value) end

local TAB_PARTS = {'Left', 'Middle', 'Right', 'SelectedLeft', 'SelectedMiddle', 'SelectedRight', 'ActiveLeft', 'ActiveMiddle',
	'ActiveRight', 'HighlightLeft', 'HighlightMiddle', 'HighlightRight'}
local EDIT_PARTS = {'Left', 'Mid', 'Right', 'FocusLeft', 'FocusMid', 'FocusRight'}

local devices, lamps, fields, typed, tabFrames = {}, {}, {}, {}, {}
local tabKeys = {} -- tab -> {thumb (light housing), cap (dark housings)}

local function Clear(texture)
	if texture and not Forbidden(texture) and texture.SetTexture then
		texture:SetTexture(nil)
		texture:SetAlpha(0)
	end
end

local function Is(object, kind)
	return type(object) == 'table' and not Forbidden(object) and object.IsObjectType and object:IsObjectType(kind)
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

local function TypeSound(_, character)
	local db = UI.db.sound
	if db.enable and db.chat and not IsSecret(character) then Kit:Play(character == ' ' and 'type-space' or 'type', true) end
end

-- Text that can be read: plain, and not a protected (|K) Battle.net line.
local function Readable(text)
	if type(text) ~= 'string' or IsSecret(text) then return false end
	return not find(text, '|K', 1, true)
end

-- Tabs: the lamp lights on the selected window; another window's lamp blinks
-- amber while it has unread lines. Unread lines are noticed by comparing each
-- window's line count and last line between ticks; nothing is hooked.
local selectedTab
local seen = {} -- frame -> {count, last}
local unread = {} -- tab -> true

local function LastLine(frame)
	local count = frame.GetNumMessages and frame:GetNumMessages() or 0
	if IsSecret(count) then return nil, nil end
	if count == 0 then return 0, nil end
	local text = frame:GetMessageInfo(count)
	if IsSecret(text) then text = '\0secret'..count end
	return count, text
end

-- The selected tab is the segmented control's raised key (on the light
-- housing) or a lit charcoal cap (on dark glass); the others are printed.
local function PaintTab(tab, on)
	local lamp = lamps[tab]
	if not lamp then return end
	if on then Kit:SetLed(lamp, true)
	elseif unread[tab] and DB().flash then Kit:SetLed(lamp, true, 'amber')
	else Kit:SetLed(lamp, false) end
	local key = tabKeys[tab]
	local light = Surface() == 'paper'
	if key then
		key.thumb:SetShown(on and light)
		key.cap:SetShown(on and not light)
	end
	local ink, dim = Inks()
	local text = tab.Text or _G[(tab:GetName() or '')..'Text']
	if text then Kit:Tint(text, on and ink or dim) end
end

local blink = false
local function PaintTabs()
	local frame = _G.SELECTED_CHAT_FRAME or _G.DEFAULT_CHAT_FRAME
	local selected = frame and _G[(frame:GetName() or '')..'Tab']
	-- New lines in windows that aren't in front.
	for tab, chat in pairs(tabFrames) do
		local count, last = LastLine(chat)
		local before = seen[chat]
		if count and before and (count ~= before[1] or last ~= before[2]) and tab ~= selected then unread[tab] = true end
		seen[chat] = {count, last}
	end
	if selected then unread[selected] = nil end
	blink = not blink
	local changed = selected ~= selectedTab
	if changed and selectedTab and lamps[selectedTab] then Kit:Play('tick') end
	selectedTab = selected
	for tab in pairs(lamps) do
		if tab == selected then PaintTab(tab, true)
		elseif unread[tab] and DB().flash then
			-- A slow blink: lit every other tick.
			if blink then Kit:SetLed(lamps[tab], true, 'amber') else Kit:SetLed(lamps[tab], false) end
		elseif changed then PaintTab(tab, false) end
	end
end

local function SkinTab(tab, frame)
	if Forbidden(tab) or lamps[tab] then return end
	local name = tab:GetName() or ''
	for _, part in ipairs(TAB_PARTS) do
		Clear(_G[name..part])
		Clear(tab[part])
	end
	if tab.GetHighlightTexture then Clear(tab:GetHighlightTexture()) end
	-- The game's own unread glow: the lamp blinks instead.
	Clear(tab.glow); Clear(_G[name..'Glow'])
	local text = tab.Text or _G[name..'Text']
	if text then Kit:Font(text, DB().tabSize or 9, Flags(), true) end
	local lamp = Kit:Led(tab, 5, false)
	lamp:SetPoint('RIGHT', text or tab, text and 'LEFT' or 'LEFT', -5, 0)
	-- The key behind the selected tab, hugging the lamp and the label. It sits
	-- one level under the tab so the tab's own label stays on top.
	local holder = CreateFrame('Frame', nil, tab)
	holder:SetFrameLevel(max(tab:GetFrameLevel() - 1, 0))
	holder:EnableMouse(false)
	if text then
		holder:SetPoint('TOPLEFT', text, 'TOPLEFT', -15, 5)
		holder:SetPoint('BOTTOMRIGHT', text, 'BOTTOMRIGHT', 8, -5)
	else
		holder:SetPoint('TOPLEFT', 2, -4)
		holder:SetPoint('BOTTOMRIGHT', -2, 4)
	end
	local thumb = Kit:Skin(holder, 'segment-thumb', 'BACKGROUND', 0)
	thumb.kitMaxCorner = 6
	local cap = Kit:Shell(holder, {surface = 'dark', radius = 5, shadow = false})
	thumb:Hide(); cap:Hide()
	tabKeys[tab] = {holder = holder, thumb = thumb, cap = cap}
	-- Hover: unselected tabs lift to full ink.
	tab:HookScript('OnEnter', function(self)
		local label = self.Text or _G[(self:GetName() or '')..'Text']
		if label and self ~= selectedTab then Kit:Tint(label, (Inks())) end
	end)
	tab:HookScript('OnLeave', function(self) if self ~= selectedTab then PaintTab(self, false) end end)
	lamps[tab] = lamp
	tabFrames[tab] = frame
	selectedTab = nil
end

-- The text field is part of the housing and always shows, like the
-- reference's text field; the edit box types into it when chat is open.
local function PlaceEditBox(frame)
	local name = frame:GetName()
	local box = name and _G[name..'EditBox']
	local field = fields[frame]
	if Forbidden(box) or not field then return end
	if not typed[box] then
		for _, part in ipairs(EDIT_PARTS) do Clear(_G[name..'EditBox'..part]) end
		Clear(box.focusLeft); Clear(box.focusMid); Clear(box.focusRight)
		box:HookScript('OnChar', TypeSound)
		-- The channel lamp follows the header's color, which the game sets
		-- to the channel's; read a frame later, after the game repainted it.
		local function Relamp() C_Timer.After(0, function() UI:Safe(module.PaintField, frame) end) end
		box:HookScript('OnShow', function() field.hint:Hide(); Relamp() end)
		box:HookScript('OnHide', function() field.hint:Show(); Relamp() end)
		box:HookScript('OnTextChanged', Relamp)
		box:HookScript('OnEditFocusGained', Relamp)
		field.hint:SetShown(not box:IsShown())
		typed[box] = true
		module.FontField(frame)
		module.PaintField(frame)
	end
	local point, relative = box:GetPoint(1)
	if point == 'TOPLEFT' and relative == field then return end
	box:ClearAllPoints()
	box:SetPoint('TOPLEFT', field, 'TOPLEFT', 16, 0)
	box:SetPoint('BOTTOMRIGHT', field, 'BOTTOMRIGHT', -4, 0)
end

-- The housing around a window: wide enough for the game's button column on
-- its left, and tall enough for the combat log's filter bar over its messages.
local function Plain(value) return not IsSecret(value) and type(value) == 'number' and value or 0 end
function module.FitDevice(frame, device)
	local top = DB().editTop
	local name = frame:GetName()
	local buttons = frame.buttonFrame or (name and _G[name..'ButtonFrame'])
	local column = 0
	if buttons and not Forbidden(buttons) and buttons:IsShown() then column = Plain(buttons:GetWidth()) end
	local extra = 0
	local filters = _G.CombatLogQuickButtonFrame_Custom
	if frame == _G.COMBATLOG and Is(filters, 'Frame') and filters:IsShown() then extra = Plain(filters:GetHeight()) end
	local left = -14 - (column > 0 and column + 2 or 0)
	local rise = (top and 66 or 34) + extra
	local spot = left..':'..rise
	if device.spot == spot then return end
	device.spot = spot
	device:ClearAllPoints()
	device:SetPoint('TOPLEFT', frame, 'TOPLEFT', left, rise)
	device:SetPoint('BOTTOMRIGHT', frame, 'BOTTOMRIGHT', 14, top and -14 or -46)
	local field = fields[frame]
	if top and field then
		field:ClearAllPoints()
		field:SetPoint('TOPLEFT', device, 'TOPLEFT', -left - 6, -6)
		field:SetPoint('TOPRIGHT', device, 'TOPRIGHT', -8, -6)
	end
end

local function FontPath(bold)
	return DB().font == 'plex' and Kit:FontPath(bold) or STANDARD_TEXT_FONT
end

-- The window's text in the chosen typeface, size and outline.
local function FontChat(frame)
	local db = DB()
	local ok = pcall(frame.SetFont, frame, FontPath(false), db.fontSize or 12, Flags())
	if ok then Shadow(frame) end
end

-- The text field: what's typed and the channel header in the typeface; a lamp
-- in the channel's color while typing, unlit otherwise.
function module.FontField(frame)
	local name = frame:GetName()
	local box = name and _G[name..'EditBox']
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

function module.PaintField(frame)
	local field = fields[frame]
	local name = frame:GetName()
	local box = name and _G[name..'EditBox']
	if not field or Forbidden(box) then return end
	local header = box.header or _G[name..'EditBoxHeader']
	if box:IsShown() and Is(header, 'FontString') then
		local r, g, b = header:GetTextColor()
		if not (IsSecret(r) or IsSecret(g) or IsSecret(b)) and r then
			field.lamp:SetVertexColor(r, g, b, 1)
			field.lampGlow:SetVertexColor(r, g, b, 1)
			field.lampGlow:Show()
			return
		end
	end
	field.lamp:SetVertexColor(Kit:RGB('ledOff'))
	field.lampGlow:Hide()
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

local CopyWindow -- defined below

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

	-- Housing: a header row for the tabs, the display, and a strip for the
	-- text field (under the display, or above the tabs). Blizzard's chat
	-- buttons, left of the window, live inside it. The light device, dark
	-- glass, or (hairline) no housing at all: a faint display with a fine edge.
	local top, housing = DB().editTop, DB().housing
	local surface = Surface()
	local ink, dim = Inks()
	local device = Kit:Device(frame, {header = false, corner = 16, surface = surface})
	device:SetFrameLevel(max(frame:GetFrameLevel() - 2, 0))
	Kit:Relevel(device)
	device:EnableMouse(false)
	if housing == 'hairline' then device.shell:Hide() end
	device.model = Kit:Label(device, 'CH-'..index, ink, 8, true)
	device.model:SetPoint('TOPRIGHT', -66, top and -43 or -11)
	device.title = Kit:Label(device, 'Comms', dim, 8)
	device.title:SetPoint('LEFT', device.model, 'RIGHT', 5, 0)
	device.model:SetShown(housing ~= 'hairline')
	device.title:SetShown(housing ~= 'hairline')
	local screen
	if housing == 'hairline' then
		screen = CreateFrame('Frame', nil, frame)
		screen.shell = Kit:Shell(screen, {surface = 'glass', radius = 8, alpha = 0.55, shadow = false})
	else
		screen = Kit:Screen(frame, {inset = 4, corner = 9})
	end
	screen:SetPoint('TOPLEFT', frame, 'TOPLEFT', -6, 6)
	screen:SetPoint('BOTTOMRIGHT', frame, 'BOTTOMRIGHT', 6, -6)
	screen:SetFrameLevel(max(frame:GetFrameLevel() - 1, 0))
	if screen.bezel then Kit:Relevel(screen) end
	screen:EnableMouse(false)
	device.screen = screen
	local field = CreateFrame('Frame', nil, device)
	if top then
		field:SetPoint('TOPLEFT', device, 'TOPLEFT', 8, -6)
		field:SetPoint('TOPRIGHT', device, 'TOPRIGHT', -8, -6)
	else
		field:SetPoint('BOTTOMLEFT', frame, 'BOTTOMLEFT', -6, -40)
		field:SetPoint('BOTTOMRIGHT', frame, 'BOTTOMRIGHT', 6, -40)
	end
	field:SetHeight(26)
	field.glass = Kit:Skin(field, 'glass', 'BACKGROUND', 0)
	field.glass.kitMaxCorner = 10
	-- The channel lamp: unlit until you type, then the channel's color.
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
	field.hint:SetPoint('LEFT', field.lamp, 'RIGHT', 7, 0)
	fields[frame] = field
	module.FitDevice(frame, device)

	-- The copy key, in the header next to the model code.
	local copy = Kit:Key(device, {width = 22, height = 18, round = true, icon = 'copy', iconSize = 10, sound = 'down',
		onClick = function() CopyWindow(frame) end})
	copy:SetPoint('TOPRIGHT', device, 'TOPRIGHT', -12, top and -38 or -6)
	copy:SetShown(DB().copy)
	copy:SetScript('OnEnter', function(self) Kit:ShowTooltip(self, 'Copy this window') end)
	copy:SetScript('OnLeave', function() Kit:HideTooltip() end)
	device.copy = copy
	devices[frame] = device

	frame:HookScript('OnHyperlinkEnter', LinkEnter)
	frame:HookScript('OnHyperlinkLeave', LinkLeave)
	FontChat(frame)
	SkinTab(_G[name..'Tab'], frame)
	if DB().chrome then UI:Safe(module.SkinWindowChrome, frame) end
end

-- Chrome -------------------------------------------------------------------------
-- Round glass keys for the chat's buttons, a hairline scroll bar, the grip and
-- the combat log's filter bar. Every part is ours and kept in `chrome`; the
-- game's art is only made transparent, so its own state changes still work.
local chrome = setmetatable({}, {__mode = 'k'})

local function HideArt(button)
	for _, getter in ipairs({'GetNormalTexture', 'GetPushedTexture', 'GetHighlightTexture', 'GetDisabledTexture'}) do
		local texture = button[getter] and button[getter](button)
		if Is(texture, 'Texture') then texture:SetAlpha(0) end
	end
end

-- icon: one of the kit's icons, drawn over the game's hidden art; nil keeps
-- the game's own icon (voice states), grayed and inked to match.
local function GlassKey(button, icon, size)
	if not Is(button, 'Button') or chrome[button] then return end
	local parts = {}
	chrome[button] = parts
	parts.shell = Kit:Shell(button, {surface = 'glass', radius = 7, shadowAlpha = 0.25})
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
		if Is(glow, 'Texture') then glow:SetAlpha(0) end
		local inner = button.Icon or button.icon
		if Is(inner, 'Texture') then inner:SetDesaturated(true); inner:SetVertexColor(Kit:RGB('darkInk')) end
	end
	button:HookScript('OnEnter', function()
		if parts.icon then Kit:Tint(parts.icon, 'darkInk') end
		Kit:SetSurface(parts.shell, 'dark')
	end)
	button:HookScript('OnLeave', function()
		if parts.icon then Kit:Tint(parts.icon, 'darkDim') end
		Kit:SetSurface(parts.shell, 'glass')
	end)
	button:HookScript('OnMouseDown', function() if parts.icon then parts.icon:SetPoint('CENTER', 0, -1) end end)
	button:HookScript('OnMouseUp', function() if parts.icon then parts.icon:SetPoint('CENTER', 0, 0) end end)
end

-- The scroll bar: a hairline track and a small pill thumb; the step arrows go.
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
	thumb:HookScript('OnEnter', function() Kit:Tint(pill, 'darkInk') end)
	thumb:HookScript('OnLeave', function() Kit:Tint(pill, 'darkDim') end)
end

-- Per window: the scroll-to-bottom key (its flash becomes a lit ring), the
-- scroll bar and the resize grip.
function module.SkinWindowChrome(frame)
	local name = frame:GetName() or ''
	local bottom = frame.ScrollToBottomButton or _G[name..'ButtonFrameBottomButton']
	if Is(bottom, 'Button') and not chrome[bottom] then
		GlassKey(bottom, 'chevron-down', 11)
		local flash = bottom.Flash or _G[name..'ButtonFrameBottomButtonFlash']
		if Is(flash, 'Texture') then
			flash:SetTexture(Kit.media..'circle-ring.tga')
			flash:ClearAllPoints()
			flash:SetAllPoints(bottom)
			flash:SetVertexColor(Kit:RGB('lamp'))
			flash:SetBlendMode('ADD')
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

-- The game's buttons that are shared by every window.
local SHARED = {
	{'ChatFrameMenuButton', 'more'}, {'ChatFrameChannelButton', 'align-left'}, {'TextToSpeechButton', 'speaker'},
	{'ChatFrameToggleVoiceDeafenButton'}, {'ChatFrameToggleVoiceMuteButton'},
	{'GeneralDockManagerOverflowButton', 'chevron-down', 10},
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
	parts.shell = Kit:Shell(social, {surface = 'glass', radius = 7, shadowAlpha = 0.25})
	parts.icon = Kit:Icon(social, 'user', 12, 'darkDim')
	parts.icon:SetPoint('CENTER', 0, Is(count, 'FontString') and 3 or 0)
	social:HookScript('OnEnter', function() Kit:Tint(parts.icon, 'darkInk') end)
	social:HookScript('OnLeave', function() Kit:Tint(parts.icon, 'darkDim') end)
end

-- The overflow list of docked windows, as a glass popover.
local function SkinOverflowList()
	local list = _G.GeneralDockManagerOverflowButtonList
	if not Is(list, 'Frame') or chrome[list] then return end
	chrome[list] = {}
	for _, region in ipairs({list:GetRegions()}) do if Is(region, 'Texture') then region:SetAlpha(0) end end
	if list.NineSlice and not Forbidden(list.NineSlice) then list.NineSlice:SetAlpha(0) end
	Kit:Shell(list, {surface = 'glass', radius = 6, shadowAlpha = 0.4})
end

-- The combat log's filter bar: a strip of dark glass with printed filters, a
-- filter key and the progress bar as a thin lamp line.
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
	local dim = 'darkDim'
	for index = 1, 20 do
		local button = _G['CombatLogQuickButtonFrameButton'..index]
		if not button then break end
		if not chrome[button] and Is(button, 'Button') then
			chrome[button] = {}
			HideArt(button)
			local text = button.GetFontString and button:GetFontString()
			if Is(text, 'FontString') then
				Kit:Font(text, 9, nil, true)
				Kit:Tint(text, dim)
			end
			button:HookScript('OnEnter', function(self)
				local label = self.GetFontString and self:GetFontString()
				if Is(label, 'FontString') then Kit:Tint(label, 'darkInk') end
			end)
			button:HookScript('OnLeave', function(self)
				local label = self.GetFontString and self:GetFontString()
				if Is(label, 'FontString') then Kit:Tint(label, 'darkDim') end
			end)
		end
	end
end

function module.SkinChrome()
	if not DB().chrome then return end
	for _, entry in ipairs(SHARED) do UI:Safe(GlassKey, _G[entry[1]], entry[2], entry[3]) end
	UI:Safe(SkinSocial)
	UI:Safe(SkinOverflowList)
	UI:Safe(SkinCombatLog)
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
	for frame, device in pairs(devices) do UI:Safe(module.FitDevice, frame, device) end
	selectedTab = nil
	PaintTabs()
end

local pending
local function QueuePass()
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

local function Hex(r, g, b)
	return format('|cff%02x%02x%02x', floor((r or 1) * 255 + 0.5), floor((g or 1) * 255 + 0.5), floor((b or 1) * 255 + 0.5))
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
-- names isn't offered: the game matches the channel argument against each
-- window's channel list, so it can't be changed here.)
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
local function ApplyCVars()
	local db = DB()
	if db.classColors then pcall(SetCVar, 'chatClassColorOverride', '0') end
	if db.timestamps ~= 'keep' then pcall(SetCVar, 'showTimestamps', db.timestamps) end
end

-- Whispers ------------------------------------------------------------------------
local lastWhisper = 0
local function Whispered()
	if not DB().whisperSound then return end
	local now = GetTime()
	if now - lastWhisper < 1 then return end
	lastWhisper = now
	Kit:Play('blip', true)
end

function module:Enable()
	Pass()
	local add = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
	if add then for _, event in ipairs(FILTERED) do add(event, Filter) end end
	if EventRegistry and EventRegistry.RegisterCallback then
		EventRegistry:RegisterCallback('SetItemRef', OnLinkClicked, module)
	end
	ApplyCVars()
	-- Post-hooks that only queue a pass: a whisper window opening, the combat
	-- log's filters changing. Their arguments are never looked at.
	local hooked = {}
	local function HookPass(name)
		if hooked[name] or type(_G[name]) ~= 'function' then return end
		hooked[name] = true
		hooksecurefunc(name, function() QueuePass() end)
	end
	HookPass('FCF_OpenTemporaryWindow')
	HookPass('Blizzard_CombatLog_Update_QuickButtons')
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
			HookPass('Blizzard_CombatLog_Update_QuickButtons')
			WatchFilterBar()
			QueuePass()
		end
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
			C_Timer.After(1, function() UI:Safe(ReplayHistory) end)
		end
		QueuePass()
	end)
	C_Timer.NewTicker(0.5, function() UI:Safe(PaintTabs) end)
end

function module:Refresh()
	for frame, device in pairs(devices) do
		UI:Safe(FontChat, frame)
		UI:Safe(module.FontField, frame)
		UI:Safe(module.PaintField, frame)
		if device.copy then device.copy:SetShown(DB().copy) end
	end
	for tab in pairs(lamps) do
		local text = tab.Text or _G[(tab:GetName() or '')..'Text']
		if text then Kit:Font(text, DB().tabSize or 9, Flags(), true) end
	end
	ApplyCVars()
	if not DB().flash then wipe(unread) end
	selectedTab = nil
	UI:Safe(PaintTabs)
end

UI:RegisterPage('chat', {title = 'Chat', order = 13, cards = {
	{title = 'Style', rows = {
		{'segmented', 'Style', 'style.chat', items = {{'display', 'Device'}, {'blizzard', 'Blizzard'}}, reload = true,
			note = 'Messages on a black display in a housing; tabs in its header.'},
		{'segmented', 'Housing', 'chat.housing', items = {{'device', 'Device'}, {'glass', 'Dark glass'}, {'hairline', 'Hairline'}},
			reload = true, since = '0.5.1', note = 'The light device, dark glass, or no housing: a faint display with a fine edge.'},
		{'switch', 'Chat buttons', 'chat.chrome', 'The menu, channel, social, voice, text-to-speech and scroll buttons as round glass keys, a hairline scroll bar, and the combat log\'s filter bar in glass.',
			reload = true, since = '0.5.1'},
		{'segmented', 'Typeface', 'chat.font', items = {{'plex', 'Plex Mono'}, {'game', 'Game'}}},
		{'slider', 'Text size', 'chat.fontSize', 9, 18, 1},
		{'segmented', 'Outline', 'chat.outline', items = {{'none', 'None'}, {'outline', 'Thin'}, {'thick', 'Thick'}}, since = '0.5.1'},
		{'switch', 'Text shadow', 'chat.shadow', 'A soft drop shadow under the text (with no outline).', since = '0.5.1'},
		{'slider', 'Tab text size', 'chat.tabSize', 8, 14, 1, since = '0.5.1'},
		{'switch', 'Text field on top', 'chat.editTop', 'Type above the tabs instead of under the messages.', reload = true},
		{'switch', 'Typing sounds', 'sound.chat', 'A key click for each character typed.'},
	}},
	{title = 'Messages', rows = {
		{'switch', 'Web addresses', 'chat.urls', 'Addresses become links; click one to copy it.'},
		{'switch', 'Class colored names', 'chat.classColors', 'Names in their class color.'},
		{'segmented', 'Timestamps', 'chat.timestamps', items = {{'keep', 'Game'}, {'none', 'Off'}, {'%H:%M ', '24 h'}, {'%I:%M %p ', '12 h'}}},
		{'switch', 'Link tooltips', 'chat.linkTips', 'Hover an item or spell link to see it.'},
	}},
	{title = 'Windows', rows = {
		{'switch', 'Copy key', 'chat.copy', 'A key on each window copies its text.'},
		{'switch', 'History', 'chat.history', 'Your last lines come back, dimmed, after a reload or relog.'},
		{'slider', 'History lines', 'chat.historyLines', 10, 120, 10},
		{'switch', 'Activity lamps', 'chat.flash', 'A tab\'s lamp blinks amber when it has new lines.'},
		{'switch', 'Whisper sound', 'chat.whisperSound', 'A blip when someone whispers you.'},
		{'switch', 'Glass bubbles', 'chat.bubbles', 'Chat bubbles as dark glass (outside instances, where the game allows it).'},
	}},
}})
