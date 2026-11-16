-- Every Blizzard window, dialog and menu as a SPEC-01 device.
--
-- A window loses its parchment, portrait and borders and becomes a charcoal
-- housing drawn from code (Kit:Shell): a printed header with a status lamp,
-- a bold model code and the window's name, and its insets and lists set on
-- black screens. Then everything inside is walked and dressed by its shape:
--   three-part and text buttons   -> charcoal keycaps that go down when pressed
--   check buttons                 -> a glass box with a lit check
--   tabs                          -> segmented keys, the selected one raised and light
--   scroll bars                   -> a thin track with a dark thumb
--   sliders                       -> a glass track with a round thumb
--   status bars                   -> LED dot meters
--   item slots                    -> light keys with a quality-colored edge
--   edit boxes and search boxes   -> black glass fields
--   dropdowns                     -> keycaps with a chevron
--   insets                        -> black screens
--   large background art          -> removed; dark text relit light
-- Windows are walked again on show and when their lists update, so pooled rows
-- and late content get the same treatment. Windows click open and latch shut,
-- keys, checks, tabs and lists answer with the SPEC-01 voices.
--
-- Loot and roll frames, alerts and banners belong to the notifications module.
--
-- Combat and taint: nothing here hooks a Blizzard method or writes a field onto
-- a Blizzard frame. Only global functions (and the menu manager and tab mixin)
-- are post-hooked with hooksecurefunc and scripts are added with HookScript;
-- everything this file adds lives in weak side tables. Regions of protected
-- frames are never re-anchored in combat.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, CreateFont, InCombatLockdown, C_Timer = CreateFrame, CreateFont, InCombatLockdown, C_Timer
local max, min = math.max, math.min
local type, ipairs, pairs, pcall = type, ipairs, pairs, pcall

local module = UI:RegisterModule('windows', {})

local function IsSecret(value) return issecretvalue and issecretvalue(value) end
local function Forbidden(object)
	if type(object) ~= 'table' then return true end
	if object.IsForbidden then
		local ok, forbidden = pcall(object.IsForbidden, object)
		return not ok or forbidden
	end
	return false
end
local function Is(object, kind)
	return not Forbidden(object) and object.IsObjectType and object:IsObjectType(kind) and true or false
end
local function Hide(region)
	if not Forbidden(region) and region.SetAlpha then region:SetAlpha(0) end
end
local function Size(object)
	local width, height = object:GetSize()
	if IsSecret(width) or IsSecret(height) then return 0, 0 end
	return width or 0, height or 0
end
-- Regions of a protected frame can't be re-anchored while in combat.
local function Locked(frame)
	return InCombatLockdown() and frame and frame.IsProtected and frame:IsProtected() and true or false
end
local function NameOf(object)
	local name = object.GetName and object:GetName()
	return type(name) == 'string' and name or nil
end
local function Sound(voice, family)
	if UI.InterfaceSound then UI:InterfaceSound(voice, family, 'skin') end
end

-- Each object is dressed once per kind.
local marks = {}
local function First(kind, object)
	local set = marks[kind]
	if not set then
		set = setmetatable({}, {__mode = 'k'})
		marks[kind] = set
	end
	if set[object] then return false end
	set[object] = true
	return true
end

-- Frames and textures this file made. The walk never strips or dresses them.
local own = setmetatable({}, {__mode = 'k'})
local function Own(object)
	own[object] = true
	return object
end

-- Frames the walk never enters: map canvases, talent trees, and anything the
-- notifications module owns.
local skip = setmetatable({}, {__mode = 'k'})
local SKIP_TYPES = {Model = true, PlayerModel = true, DressUpModel = true, CinematicModel = true, TabardModel = true,
	ModelScene = true, Minimap = true, Cooldown = true, GameTooltip = true, MessageFrame = true, ScrollingMessageFrame = true,
	Browser = true, MovieFrame = true, FogOfWarFrame = true, UnitPositionFrame = true, ArchaeologyDigSiteFrame = true,
	QuestPOIFrame = true, ScenarioPOIFrame = true, ColorSelect = true, OffScreenFrame = true}

-- A frame of our own under a Blizzard one, with a code-built shell.
-- l, t, r, b grow outward; negative values inset.
local function Back(owner, opts, l, t, r, b)
	local frame = Own(CreateFrame('Frame', nil, owner))
	frame:SetPoint('TOPLEFT', owner, 'TOPLEFT', -(l or 0), t or 0)
	frame:SetPoint('BOTTOMRIGHT', owner, 'BOTTOMRIGHT', r or 0, -(b or 0))
	frame:SetFrameLevel(owner:GetFrameLevel())
	frame:EnableMouse(false)
	frame.shell = Own(Kit:Shell(frame, opts))
	return frame
end

-- Text -------------------------------------------------------------------------
-- Blizzard's buttons and tabs take their text from font objects, which they
-- swap on every state change, so the SPEC-01 legends are font objects too.
local fontObjects = {}
local function FontObject(name, size, token, bold)
	local font = CreateFont('JiberishSpec01'..name)
	fontObjects[#fontObjects + 1] = {font, size, token, bold}
	return font
end
local KEY_FONT = FontObject('KeyText', 10, 'darkInk', true)
local KEY_HOT = FontObject('KeyHighlight', 10, 'white', true)
local KEY_DIM = FontObject('KeyDisabled', 10, 'darkDim', true)
local TAB_ON = FontObject('TabOn', 9, 'ink', true)
local TAB_OFF = FontObject('TabOff', 9, 'darkDim', true)
local TAB_HOT = FontObject('TabHighlight', 9, 'darkInk', true)
-- Legends on the light key of a window's main action.
local INK_FONT = FontObject('KeyInk', 10, 'ink', true)
local INK_HOT = FontObject('KeyInkHighlight', 10, 'ink', true)
local INK_DIM = FontObject('KeyInkDisabled', 10, 'dim', true)

local function PaintFonts()
	for _, entry in ipairs(fontObjects) do
		local font, size, token, bold = entry[1], entry[2], entry[3], entry[4]
		if font:SetFont(Kit:FontPath(bold), size, '') == false then font:SetFont(STANDARD_TEXT_FONT, size, '') end
		font:SetTextColor(Kit:RGB(token))
		font:SetShadowOffset(0, 0)
	end
end
PaintFonts()
Kit:OnRefresh(PaintFonts)

local function SetFonts(button, normal, highlight, disabled)
	if Locked(button) or not button.SetNormalFontObject then return end
	pcall(button.SetNormalFontObject, button, normal)
	pcall(button.SetHighlightFontObject, button, highlight)
	pcall(button.SetDisabledFontObject, button, disabled)
end

-- Parchment windows print dark text; on the charcoal housing it needs to be
-- light. Only dark strings change, so colored text keeps its color.
local LIGHT = {0.92, 0.92, 0.88}
local function Relight(fontString)
	if Forbidden(fontString) or own[fontString] then return end
	local ok, r, g, b = pcall(fontString.GetTextColor, fontString)
	if not ok or IsSecret(r) or IsSecret(g) or IsSecret(b) or not r then return end
	if r + g + b < 1.2 then fontString:SetTextColor(LIGHT[1], LIGHT[2], LIGHT[3]) end
end

local function RelightRegions(frame)
	for _, region in ipairs({frame:GetRegions()}) do
		if Is(region, 'FontString') then Relight(region) end
	end
	-- Book pages (item text) are HTML.
	if Is(frame, 'SimpleHTML') then
		for _, part in ipairs({'P', 'H1', 'H2', 'H3'}) do pcall(frame.SetTextColor, frame, part, LIGHT[1], LIGHT[2], LIGHT[3]) end
	end
end

local function RelightAll(frame, depth)
	if Forbidden(frame) or not frame.GetRegions then return end
	RelightRegions(frame)
	if depth >= 6 then return end
	for _, child in ipairs({frame:GetChildren()}) do
		if not own[child] then RelightAll(child, depth + 1) end
	end
end

-- Stripping art ---------------------------------------------------------------
-- Art pieces a window or panel keeps under these keys or name suffixes.
local ART = {'NineSlice', 'Bg', 'BG', 'Background', 'TitleBg', 'TopTileStreaks', 'PortraitContainer', 'PortraitOverlay',
	'portrait', 'Portrait', 'PortraitFrame', 'ArtOverlayFrame', 'BorderTexture', 'Border', 'TopBorder', 'BottomBorder',
	'LeftBorder', 'RightBorder', 'TopEdge', 'BottomEdge', 'LeftEdge', 'RightEdge', 'TopLeftCorner', 'TopRightCorner',
	'BottomLeftCorner', 'BottomRightCorner', 'Center', 'Shadows', 'shadows', 'ShadowOverlay', 'InsetBorderTop',
	'InsetBorderTopLeft', 'InsetBorderTopRight', 'InsetBorderBottom', 'InsetBorderBottomLeft', 'InsetBorderBottomRight',
	'InsetBorderLeft', 'InsetBorderRight', 'BackgroundTile', 'Divider', 'TitleMarquee', 'StoneBg'}
local NAMED_ART = {'Bg', 'TitleBg', 'Portrait', 'PortraitFrame', 'TopBorder', 'BottomBorder', 'LeftBorder', 'RightBorder',
	'TopLeftCorner', 'TopRightCorner', 'BotLeftCorner', 'BotRightCorner', 'BtnCornerLeft', 'BtnCornerRight',
	'ButtonBottomBorder', 'InsetBg', 'TitleBG', 'DialogBG', 'Background', 'BackgroundOverlay', 'TopLeft', 'TopRight',
	'BottomLeft', 'BottomRight', 'Top', 'Bottom', 'Left', 'Right', 'Middle'}
local KEEP = {'Icon', 'icon', 'AlertIcon', 'IconTexture', 'IconBorder', 'Spinner'}

local function NineSlicePanel(frame)
	return not Forbidden(frame) and frame.GetObjectType and frame.TopLeftCorner and frame.Center and true or false
end

-- A backdrop (BackdropTemplate or a nine-slice panel) loses its nine pieces
-- only: such frames may hold content of their own.
local BACKDROP = {'TopLeftCorner', 'TopRightCorner', 'BottomLeftCorner', 'BottomRightCorner', 'TopEdge', 'BottomEdge',
	'LeftEdge', 'RightEdge', 'Center'}
local function Unbackdrop(frame)
	for _, key in ipairs(BACKDROP) do
		local piece = frame[key]
		if Is(piece, 'Texture') then piece:SetAlpha(0) end
	end
end

local function Keep(frame)
	local keep = {}
	for _, key in ipairs(KEEP) do
		if type(frame[key]) == 'table' then keep[frame[key]] = true end
	end
	local name = NameOf(frame)
	if name then
		for _, suffix in ipairs({'Icon', 'AlertIcon', 'IconTexture'}) do
			if type(_G[name..suffix]) == 'table' then keep[_G[name..suffix]] = true end
		end
	end
	return keep
end

-- Hide the art a frame owns: its own textures and its usual art pieces.
local function Strip(frame)
	if Forbidden(frame) or not frame.GetRegions then return end
	local keep = Keep(frame)
	for _, region in ipairs({frame:GetRegions()}) do
		if Is(region, 'Texture') and not keep[region] and not own[region] then region:SetAlpha(0) end
	end
	for _, key in ipairs(ART) do
		local piece = frame[key]
		if type(piece) == 'table' and not keep[piece] and not own[piece] then
			if Is(piece, 'Texture') then piece:SetAlpha(0)
			elseif key == 'NineSlice' then Hide(piece)
			elseif NineSlicePanel(piece) then Unbackdrop(piece)
			elseif not Forbidden(piece) and piece.GetRegions then
				for _, region in ipairs({piece:GetRegions()}) do
					if Is(region, 'Texture') and not keep[region] then region:SetAlpha(0) end
				end
			end
		end
	end
	local name = NameOf(frame)
	if name then
		for _, suffix in ipairs(NAMED_ART) do
			local piece = _G[name..suffix]
			if Is(piece, 'Texture') and not keep[piece] then piece:SetAlpha(0) end
		end
	end
end

-- Inside a window: big background art goes (parchment, page backgrounds, tree
-- art, row backdrops); icons and anything in the artwork layers stay.
local DECOR_LAYERS = {BACKGROUND = true, BORDER = true}
local function Decor(frame)
	if not First('decor', frame) then return end
	local keep = Keep(frame)
	for _, region in ipairs({frame:GetRegions()}) do
		if Is(region, 'Texture') and not keep[region] and not own[region] and DECOR_LAYERS[region:GetDrawLayer()] then
			local width, height = Size(region)
			if max(width, height) >= 96 then region:SetAlpha(0) end
		end
	end
end

-- Insets and list areas: black screens.
local function Inset(frame)
	if Forbidden(frame) or own[frame] or not frame.GetRegions or not First('inset', frame) then return end
	Strip(frame)
	Hide(frame.NineSlice)
	Own(Kit:Shell(frame, {surface = 'screen', radius = 6, shadow = false}))
end

-- Keys -----------------------------------------------------------------------------
local BUTTON_ART = {'GetNormalTexture', 'GetPushedTexture', 'GetHighlightTexture', 'GetDisabledTexture'}
local function HideButtonArt(button)
	for _, getter in ipairs(BUTTON_ART) do
		if button[getter] then Hide(button[getter](button)) end
	end
end

-- A keycap from the reference's own art behind a Blizzard button: the charcoal
-- cap for most buttons, the light key for a window's main action. It goes down
-- (the captured pressed art) while held, lifts a little under the cursor and
-- fades when the button is disabled.
local caps = setmetatable({}, {__mode = 'k'})
local function CapState(cap, state)
	Kit:SetSprite(cap.skin, state == 'down' and cap.down or cap.up)
	cap.lift:SetAlpha(state == 'hover' and 1 or 0)
end

local function Keycap(button, primary, corner)
	local cap = Own(CreateFrame('Frame', nil, button))
	cap:SetAllPoints(button)
	cap:SetFrameLevel(max(button:GetFrameLevel() - 1, 0))
	cap:EnableMouse(false)
	cap.up, cap.down = primary and 'key' or 'cap', primary and 'key-down' or 'cap-in'
	cap.skin = Own(Kit:Skin(cap, cap.up, 'BACKGROUND', 0))
	cap.skin.kitMaxCorner = corner or 7
	Kit:FitSprite(cap.skin, cap:GetWidth(), cap:GetHeight())
	-- Under the cursor: a faint lit face.
	cap.lift = Own(Kit:Texture(cap, 'round-6', 'BORDER', 0))
	Kit:Place(cap.lift, cap, -1, -1, -1, -2)
	cap.lift:SetVertexColor(1, 1, 1, primary and 0.18 or 0.07)
	cap.lift:SetAlpha(0)
	caps[button] = cap
	local function Enabled(self) cap:SetAlpha((not self.IsEnabled or self:IsEnabled()) and 1 or 0.45) end
	button:HookScript('OnEnter', function(self) if not self.IsEnabled or self:IsEnabled() then CapState(cap, 'hover') end end)
	button:HookScript('OnLeave', function() CapState(cap, 'up') end)
	button:HookScript('OnMouseDown', function(self, mouse)
		if (self.IsEnabled and not self:IsEnabled()) or mouse ~= 'LeftButton' then return end
		CapState(cap, 'down')
		Sound(primary and 'down-primary' or 'down', 'press')
	end)
	button:HookScript('OnMouseUp', function(self, mouse)
		CapState(cap, self:IsMouseOver() and 'hover' or 'up')
		if (not self.IsEnabled or self:IsEnabled()) and mouse == 'LeftButton' then Sound('up', 'press') end
	end)
	button:HookScript('OnHide', function() CapState(cap, 'up') end)
	pcall(button.HookScript, button, 'OnEnable', Enabled)
	pcall(button.HookScript, button, 'OnDisable', Enabled)
	Enabled(button)
	return cap
end

-- A window's main action gets the light key: the first button of a popup, and
-- buttons named for accepting, buying, learning, crafting and the like.
local PRIMARY = {'Accept', 'Confirm', 'Okay', 'Complete', 'Purchase', 'Buy', 'Learn', 'Create', 'Craft', 'Submit', 'Save',
	'Apply', 'Join', 'Start', 'Continue'}
local PRIMARY_TEXT = {}
if type(_G.RETURN_TO_GAME) == 'string' then PRIMARY_TEXT[_G.RETURN_TO_GAME] = true end
local function Primary(button)
	local name = NameOf(button) or ''
	if name:match('^StaticPopup%dButton1$') then return true end
	local ok, text = pcall(button.GetText, button)
	if ok and not IsSecret(text) and type(text) == 'string' and PRIMARY_TEXT[text] then return true end
	local key = button.GetParentKey and button:GetParentKey()
	key = type(key) == 'string' and key or ''
	for _, word in ipairs(PRIMARY) do
		if name:find(word, 1, true) or key:find(word, 1, true) then return true end
	end
	return false
end

local PUSH_PARTS = {'Left', 'Middle', 'Right', 'Mid', 'Center', 'LeftDisabled', 'MiddleDisabled', 'RightDisabled',
	'LeftSeparator', 'RightSeparator', 'Background', 'NineSlice'}
local function PushButton(button)
	if not First('push', button) then return end
	for _, part in ipairs(PUSH_PARTS) do Hide(button[part]) end
	local name = NameOf(button)
	if name then
		for _, part in ipairs({'Left', 'Middle', 'Right'}) do Hide(_G[name..part]) end
	end
	HideButtonArt(button)
	local primary = Primary(button)
	Keycap(button, primary)
	if primary then SetFonts(button, INK_FONT, INK_HOT, INK_DIM) else SetFonts(button, KEY_FONT, KEY_HOT, KEY_DIM) end
end

-- Close buttons: the reference's round key with an X.
local function Close(button)
	if Forbidden(button) or own[button] or not button.GetRegions or not First('close', button) then return end
	HideButtonArt(button)
	for _, region in ipairs({button:GetRegions()}) do
		if Is(region, 'Texture') then region:SetAlpha(0) end
	end
	local key = Own(CreateFrame('Frame', nil, button))
	key:SetSize(18, 18)
	key:SetPoint('CENTER')
	key:EnableMouse(false)
	key.skin = Own(Kit:Skin(key, 'key-round', 'ARTWORK', 0))
	Kit:FitSprite(key.skin, 18, 18)
	key.icon = Own(Kit:Icon(key, 'close', 8, 'ink'))
	key.icon:SetPoint('CENTER')
	button:HookScript('OnMouseDown', function() Kit:SetSprite(key.skin, 'key-round-down') end)
	button:HookScript('OnMouseUp', function() Kit:SetSprite(key.skin, 'key-round') end)
	button:HookScript('OnHide', function() Kit:SetSprite(key.skin, 'key-round') end)
end

-- Check boxes: a small glass box; the tick becomes the kit's check in the lamp color.
local function Checkbox(button)
	if not First('check', button) then return end
	local width, height = Size(button)
	local side = Kit:Clamp(min(width, height) - 8, 12, 18)
	for _, getter in ipairs({'GetNormalTexture', 'GetPushedTexture', 'GetDisabledTexture', 'GetHighlightTexture'}) do
		if button[getter] then Hide(button[getter](button)) end
	end
	local box = Own(CreateFrame('Frame', nil, button))
	box:SetSize(side, side)
	box:SetPoint('CENTER')
	-- Under the button, so its check is drawn on the key.
	box:SetFrameLevel(max(button:GetFrameLevel() - 1, 0))
	box:EnableMouse(false)
	-- A small light keycap, as the reference's checkboxes are.
	box.skin = Own(Kit:Skin(box, 'key', 'BACKGROUND', 0))
	box.skin.kitMaxCorner = 4
	Kit:FitSprite(box.skin, side, side)
	button:HookScript('OnEnter', function() box.skin:SetAlpha(0.85) end)
	button:HookScript('OnLeave', function() box.skin:SetAlpha(1) end)
	button:HookScript('OnMouseDown', function() Kit:SetSprite(box.skin, 'key-down') end)
	button:HookScript('OnMouseUp', function() Kit:SetSprite(box.skin, 'key') end)
	button:HookScript('OnClick', function(self)
		local ok, checked = pcall(self.GetChecked, self)
		if ok and not IsSecret(checked) then Sound(checked and 'latch-down' or 'latch-up', 'check') end
	end)
	for getter, token in pairs({GetCheckedTexture = 'lamp', GetDisabledCheckedTexture = 'darkDim'}) do
		local check = button[getter] and button[getter](button)
		if Is(check, 'Texture') then
			check:SetTexture(Kit.media..'icons.tga')
			Kit:SetIcon(check, 'check')
			Kit:Tint(check, token)
			if not Locked(button) then
				check:ClearAllPoints()
				check:SetPoint('CENTER', box, 'CENTER')
				check:SetSize(side - 2, side - 2)
			end
		end
	end
end

-- Tabs: segmented keys. The selected tab is raised and light, the rest charcoal.
local TAB_PARTS = {'Left', 'Middle', 'Right', 'LeftActive', 'MiddleActive', 'RightActive', 'LeftHighlight',
	'MiddleHighlight', 'RightHighlight', 'LeftDisabled', 'MiddleDisabled', 'RightDisabled', 'Selected', 'SelectedTexture',
	'TabBg', 'Hider', 'Background', 'Border'}
local tabs = setmetatable({}, {__mode = 'k'})

local function TabSelected(tab)
	if type(tab.isSelected) == 'boolean' then return tab.isSelected end
	if Is(tab.LeftActive, 'Texture') then return tab.LeftActive:IsShown() end
	if tab.GetChecked then
		local ok, checked = pcall(tab.GetChecked, tab)
		if ok and not IsSecret(checked) then return checked and true or false end
	end
	if tab.IsEnabled and tab.LeftDisabled then return not tab:IsEnabled() end
	return false
end

local function PaintTab(tab)
	local back = tabs[tab]
	if not back then return end
	local on = TabSelected(tab)
	-- The reference's segmented control: a recessed track, and the chosen
	-- segment a raised light thumb on it.
	back.thumb:SetShown(on and true or false)
	local text = tab.Text or tab.text or (tab.GetFontString and tab:GetFontString())
	if Is(text, 'FontString') then text:SetTextColor(Kit:RGB(on and 'ink' or 'darkDim')) end
end

local tabsPending = false
local function RepaintTabs()
	if tabsPending then return end
	tabsPending = true
	C_Timer.After(0, function()
		tabsPending = false
		for tab in pairs(tabs) do
			if tab:IsVisible() then UI:Safe(PaintTab, tab) end
		end
	end)
end

local function Tab(tab)
	if not First('tab', tab) then return end
	for _, part in ipairs(TAB_PARTS) do
		if Is(tab[part], 'Texture') then tab[part]:SetAlpha(0) end
	end
	local name = NameOf(tab)
	if name then
		for _, part in ipairs(TAB_PARTS) do Hide(_G[name..part]) end
	end
	for _, getter in ipairs({'GetNormalTexture', 'GetPushedTexture', 'GetDisabledTexture', 'GetHighlightTexture'}) do
		if tab[getter] then Hide(tab[getter](tab)) end
	end
	-- Bottom tabs carry art padding; the key sits on their visible part.
	local _, height = Size(tab)
	local inset = height > 28 and 4 or 1
	local back = Back(tab, {surface = 'glass', radius = 6, shadow = false}, -2, -inset, -2, -1)
	-- Under the tab, so its legend is drawn on the thumb.
	back:SetFrameLevel(max(tab:GetFrameLevel() - 1, 0))
	Kit:Relevel(back)
	back.thumb = Own(Kit:Skin(back, 'segment-thumb', 'ARTWORK', 0))
	back.thumb.kitMaxCorner = 6
	Kit:FitSprite(back.thumb, back:GetWidth(), back:GetHeight())
	back.thumb:Hide()
	tabs[tab] = back
	if Is(tab.Icon, 'Texture') then
		tab.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	else
		SetFonts(tab, TAB_OFF, TAB_HOT, TAB_ON)
	end
	local clickScript = tab.HasScript and tab:HasScript('OnClick') and 'OnClick' or 'OnMouseUp'
	tab:HookScript(clickScript, function()
		Sound('tick', 'tab')
		RepaintTabs()
	end)
	tab:HookScript('OnShow', RepaintTabs)
	PaintTab(tab)
end

-- Scroll bars: a thin track, a charcoal thumb, chevrons for the step buttons.
local function StepButton(button, icon)
	if Forbidden(button) or not button.GetRegions or not First('step', button) then return end
	HideButtonArt(button)
	for _, region in ipairs({button:GetRegions()}) do
		if Is(region, 'Texture') then region:SetAlpha(0) end
	end
	for _, key in ipairs({'Texture', 'Overlay'}) do Hide(button[key]) end
	local lid = Own(CreateFrame('Frame', nil, button))
	lid:SetAllPoints()
	lid:EnableMouse(false)
	local chevron = Own(Kit:Icon(lid, icon, 9, 'darkDim'))
	chevron:SetPoint('CENTER')
	button:HookScript('OnEnter', function() Kit:Tint(chevron, 'darkInk') end)
	button:HookScript('OnLeave', function() Kit:Tint(chevron, 'darkDim') end)
	button:HookScript('OnMouseDown', function() Sound('tick', 'scroll') end)
end

local function ScrollBar(bar)
	if Forbidden(bar) or not bar.GetRegions or not First('scroll', bar) then return end
	Strip(bar)
	local track = bar.Track
	if not Forbidden(track) and track.GetRegions then
		Strip(track)
		for _, key in ipairs({'Begin', 'Middle', 'End'}) do Hide(track[key]) end
		local line = Own(track:CreateTexture(nil, 'BACKGROUND'))
		line:SetColorTexture(1, 1, 1, 1)
		Kit:Tint(line, 'darkEdge')
		line:SetPoint('TOP', 0, -2)
		line:SetPoint('BOTTOM', 0, 2)
		line:SetWidth(UI.Pixel.Px(track, 2))
		local thumb = track.Thumb
		if not Forbidden(thumb) and thumb.GetRegions then
			Strip(thumb)
			HideButtonArt(thumb)
			for _, key in ipairs({'Begin', 'Middle', 'End'}) do Hide(thumb[key]) end
			local pill = Own(CreateFrame('Frame', nil, thumb))
			pill:SetPoint('TOPLEFT', thumb, 'TOPLEFT', 2, -1)
			pill:SetPoint('BOTTOMRIGHT', thumb, 'BOTTOMRIGHT', -2, 1)
			pill:EnableMouse(false)
			pill.skin = Own(Kit:Skin(pill, 'cap', 'ARTWORK', 0))
			pill.skin.kitMaxCorner = 3
			Kit:FitSprite(pill.skin, pill:GetWidth(), pill:GetHeight())
		end
	end
	local name = NameOf(bar)
	for key, icon in pairs({Back = 'chevron-up', Forward = 'chevron-down', ScrollUpButton = 'chevron-up',
		ScrollDownButton = 'chevron-down', UpButton = 'chevron-up', DownButton = 'chevron-down'}) do
		StepButton(bar[key] or (name and _G[name..key]), icon)
	end
	-- Old bars: the thumb is a texture on the slider itself.
	local thumb = bar.GetThumbTexture and bar:GetThumbTexture()
	if Is(thumb, 'Texture') then
		thumb:SetTexture(Kit.media..'round-3.tga')
		Kit:Tint(thumb, 'darkDim')
		thumb:SetAlpha(1)
		if not Locked(bar) then thumb:SetWidth(6) end
	end
end

-- Sliders (settings and volume): a glass track and a round thumb.
local function Slider(slider)
	if not First('slider', slider) then return end
	local thumb = slider:GetThumbTexture()
	for _, region in ipairs({slider:GetRegions()}) do
		if Is(region, 'Texture') and region ~= thumb then region:SetAlpha(0) end
	end
	for _, key in ipairs({'Left', 'Middle', 'Right'}) do Hide(slider[key]) end
	local vertical = slider.GetOrientation and slider:GetOrientation() == 'VERTICAL'
	local track = Own(CreateFrame('Frame', nil, slider))
	if vertical then
		track:SetPoint('TOP', 0, -2); track:SetPoint('BOTTOM', 0, 2); track:SetWidth(4)
	else
		track:SetPoint('LEFT', 2, 0); track:SetPoint('RIGHT', -2, 0); track:SetHeight(4)
	end
	track:SetFrameLevel(slider:GetFrameLevel())
	track:EnableMouse(false)
	Own(Kit:Shell(track, {surface = 'glass', radius = 2, shadow = false}))
	if Is(thumb, 'Texture') then
		thumb:SetTexture(Kit.media..'circle.tga')
		thumb:SetTexCoord(0, 1, 0, 1)
		Kit:Tint(thumb, 'darkInk')
		if not Locked(slider) then thumb:SetSize(12, 12) end
	end
	-- MinimalSliderWithSteppers: the stepper buttons sit on the parent.
	local parent = slider:GetParent()
	if not Forbidden(parent) and parent.Slider == slider then
		StepButton(parent.Back, 'chevron-left')
		StepButton(parent.Forward, 'chevron-right')
	end
end

-- Status bars become dot meters on a black track.
local function StatusBar(bar)
	if not First('bar', bar) then return end
	local width, height = Size(bar)
	if width < 24 or height <= 0 then return end
	local fill = bar:GetStatusBarTexture()
	for _, region in ipairs({bar:GetRegions()}) do
		if Is(region, 'Texture') and region ~= fill and not own[region] then region:SetAlpha(0) end
	end
	for _, key in ipairs({'Border', 'BorderLeft', 'BorderRight', 'BorderMid', 'BorderCenter', 'Background', 'BarBG', 'BG'}) do
		local piece = bar[key]
		if Is(piece, 'Texture') then piece:SetAlpha(0) elseif NineSlicePanel(piece) then Unbackdrop(piece) end
	end
	local name = NameOf(bar)
	if name then Hide(_G[name..'Border']); Hide(_G[name..'Background']) end
	Back(bar, {surface = 'screen', radius = 4, shadow = false}, 2, 2, 2, 2)
	if height <= 22 and width >= height * 3 then
		Kit:Perforate(bar, 'black', 'darkEdge')
		if bar.kitUnder then own[bar.kitUnder], own[bar.kitCover] = true, true end
	end
end

-- Item slots: a light key behind, the icon cropped, quality as the key's edge.
local rings = setmetatable({}, {__mode = 'k'})
local function IconOf(button)
	local name = NameOf(button)
	local icon = button.icon or button.Icon or (name and _G[name..'IconTexture'])
	return Is(icon, 'Texture') and icon or nil
end

local function Wide(button)
	local width, height = Size(button)
	return height > 0 and width > height * 1.6
end

-- The game colors an item's border by quality; the key's edge follows it.
-- A slot whose quality is better read from the game (the character window's
-- slots, whose borders are atlases rather than tinted) registers a source:
-- source(button) returns r, g, b, or nil for no quality.
local qualitySources = setmetatable({}, {__mode = 'k'})
local function Quality(button)
	local ring = rings[button]
	if not ring then return end
	local source = qualitySources[button]
	if source then
		local ok, r, g, b = pcall(source, button)
		if ok and r then
			ring:SetVertexColor(r, g, b, 1)
			if ring.led then ring.led:SetVertexColor(r, g, b, 1); ring.led:Show() end
		else
			local er, eg, eb = Kit:RGB('darkEdge')
			ring:SetVertexColor(er, eg, eb, 1)
			if ring.led then ring.led:Hide() end
		end
		return
	end
	local border = button.IconBorder
	if Is(border, 'Texture') and border:IsShown() then
		local r, g, b = border:GetVertexColor()
		if not IsSecret(r) and not IsSecret(g) and not IsSecret(b) and r and r + g + b < 2.85 then
			ring:SetVertexColor(r, g, b, 1)
			if ring.led then ring.led:SetVertexColor(r, g, b, 1); ring.led:Show() end
			return
		end
	end
	local r, g, b = Kit:RGB('darkEdge')
	ring:SetVertexColor(r, g, b, 1)
	if ring.led then ring.led:Hide() end
end

local function Item(button)
	if Forbidden(button) or not button.CreateTexture or not First('item', button) then return end
	local icon = IconOf(button)
	local name = NameOf(button)
	if button.GetNormalTexture then Hide(button:GetNormalTexture()) end
	for _, key in ipairs({'ItemSlotBackground', 'SlotBackground', 'NameFrame', 'SlotArt'}) do
		if Is(button[key], 'Texture') then button[key]:SetAlpha(0) end
	end
	if name then
		for _, suffix in ipairs({'NormalTexture', 'NameFrame', 'Frame', 'SlotTexture'}) do Hide(_G[name..suffix]) end
	end
	local target = (icon and Wide(button)) and icon or button
	local key = Own(CreateFrame('Frame', nil, button))
	key:SetPoint('TOPLEFT', target, 'TOPLEFT', -3, 3)
	key:SetPoint('BOTTOMRIGHT', target, 'BOTTOMRIGHT', 3, -3)
	key:SetFrameLevel(max(button:GetFrameLevel() - 1, 0))
	key:EnableMouse(false)
	key.skin = Own(Kit:Skin(key, 'key', 'BACKGROUND', 0))
	key.skin.kitMaxCorner = 7
	local lid = Own(CreateFrame('Frame', nil, button))
	lid:SetAllPoints(target)
	lid:EnableMouse(false)
	local ring = Own(Kit:Texture(lid, 'ring-3', 'OVERLAY', 7))
	Kit:Place(ring, target, 1, 1, 1, 1)
	-- The icon sits in a window cut into the key; quality also lights a lamp.
	if icon then
		local window = Own(Kit:Texture(lid, 'inset-6', 'ARTWORK', 0))
		Kit:Place(window, icon, 0, 0, 0, 0)
		window:SetVertexColor(0, 0, 0, 0.55)
	end
	ring.led = Own(Kit:Texture(lid, 'circle', 'OVERLAY', 7))
	ring.led:SetSize(4, 4)
	ring.led:SetPoint('TOPRIGHT', target, 'TOPRIGHT', -2, -2)
	ring.led:Hide()
	rings[button] = ring
	if icon then icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) end
	Hide(button.IconBorder)
	Quality(button)
end

local function FollowQuality(button)
	if type(button) == 'table' and rings[button] then
		Hide(button.IconBorder)
		Quality(button)
	end
end

-- Edit and search boxes: black glass.
local function EditBox(box)
	if not First('edit', box) then return end
	local name = NameOf(box)
	for _, part in ipairs({'Left', 'Right', 'Middle', 'Mid', 'FocusLeft', 'FocusRight', 'FocusMid', 'Background'}) do
		Hide(box[part])
		if name then Hide(_G[name..part]) end
	end
	Hide(box.NineSlice)
	local field = Back(box, {surface = 'glass', radius = 5, shadow = false}, 5, 1, 1, 1)
	box:HookScript('OnEditFocusGained', function() field.shell.opts.edge = 'darkDim'; Kit:PaintShell(field.shell) end)
	box:HookScript('OnEditFocusLost', function() field.shell.opts.edge = nil; Kit:PaintShell(field.shell) end)
	if Is(box.searchIcon, 'Texture') then Kit:Tint(box.searchIcon, 'darkDim') end
	if Is(box.Instructions, 'FontString') then Kit:Tint(box.Instructions, 'darkDim') end
end

-- Dropdowns (WowStyle1Dropdown, filter dropdowns): a keycap with a chevron.
local function Dropdown(dropdown)
	if not First('dropdown', dropdown) then return end
	for _, region in ipairs({dropdown:GetRegions()}) do
		if Is(region, 'Texture') and region ~= dropdown.Icon then region:SetAlpha(0) end
	end
	HideButtonArt(dropdown)
	Hide(dropdown.Arrow)
	Hide(dropdown.Background)
	Hide(dropdown.NineSlice)
	local cap = Keycap(dropdown, false)
	local chevron = Own(Kit:Icon(cap, 'chevron-down', 9, 'darkDim'))
	chevron:SetPoint('RIGHT', -8, 0)
	if Is(dropdown.Text, 'FontString') then Kit:Font(dropdown.Text, 10, nil, false) end
end

-- Money: coins counted in the reference's typeface.
local function Money(frame)
	if not First('money', frame) then return end
	local name = NameOf(frame)
	for _, key in ipairs({'GoldButton', 'SilverButton', 'CopperButton'}) do
		local button = frame[key] or (name and _G[name..key])
		local text = not Forbidden(button) and button.GetFontString and button:GetFontString()
		if Is(text, 'FontString') then Kit:Font(text, 10, nil, true) end
	end
end

-- Dialog headers (the game menu's, settings dialogs'): art off, text in ink.
local function DialogHeader(header)
	if Forbidden(header) or not header.GetRegions or not First('header', header) then return end
	Strip(header)
	for _, key in ipairs({'LeftBG', 'CenterBG', 'RightBG'}) do Hide(header[key]) end
	if Is(header.Text, 'FontString') then
		Kit:Font(header.Text, 10, nil, true)
		Kit:Tint(header.Text, 'darkInk')
	end
end

-- The walk ------------------------------------------------------------------------
local boxes = setmetatable({}, {__mode = 'k'})
local Queue -- set below

local Classify, Walk -- set below

-- Scrolling lists reuse their rows: each row is dressed (and relit) as the
-- list hands it out. The callbacks only note the row; the dressing runs from
-- our own timer, after the game's list code has finished.
local rowQueue, rowsArmed = {}, false
local function DressRow(row)
	if Forbidden(row) or own[row] or not row.GetObjectType then return end
	if Classify(row, row:GetObjectType(), true) then
		Decor(row)
		Walk(row, 0, true)
	else
		RelightRegions(row)
	end
end
local function FlushRows()
	rowsArmed = false
	local list = rowQueue
	rowQueue = {}
	for row in pairs(list) do UI:Safe(DressRow, row) end
end
local function QueueRow(row)
	if type(row) ~= 'table' then return end
	rowQueue[row] = true
	if not rowsArmed then
		rowsArmed = true
		C_Timer.After(0, FlushRows)
	end
end

local lastScroll = 0
local lastListWalk = setmetatable({}, {__mode = 'k'})
local function WatchList(box)
	if boxes[box] or not box.RegisterCallback then return end
	boxes[box] = true
	local util = _G.ScrollUtil
	local add = util and (util.AddInitializedFrameCallback or util.AddAcquiredFrameCallback)
	if add then
		pcall(add, box, function(_, row) QueueRow(row) end, {}, true)
	else
		-- No per-row callbacks on this client: a light walk at most every 0.2 s.
		local events = _G.ScrollBoxListMixin and _G.ScrollBoxListMixin.Event
		local event = events and events.OnUpdate
		if event then
			pcall(box.RegisterCallback, box, event, function()
				local now = GetTime()
				if now - (lastListWalk[box] or 0) >= 0.2 then
					lastListWalk[box] = now
					Queue(box)
				end
			end, {})
		end
	end
	box:HookScript('OnMouseWheel', function()
		local now = GetTime()
		if now - lastScroll > 0.06 then
			lastScroll = now
			Sound('tick', 'scroll')
		end
	end)
end

local function Has(object, key, kind) return Is(object[key], kind) end

-- A plain text button with its own art: a keycap. Rows in lists are left alone.
local function TextButton(button, inList)
	if inList or button.Icon or button.icon or button:IsObjectType('CheckButton') then return false end
	local text = button.GetFontString and button:GetFontString()
	local normal = button.GetNormalTexture and button:GetNormalTexture()
	if not Is(text, 'FontString') or not Is(normal, 'Texture') then return false end
	local width, height = Size(button)
	return width >= 40 and height >= 16 and height <= 40
end

local function IsTab(button)
	if button.LeftActive or button.isTabOnTop ~= nil then return true end
	local name = NameOf(button)
	if name and name:find('Tab%d*$') and (button.Left or button.Text or button.Icon or button.TabBg) then return true end
	return type(button.isSelected) == 'boolean' and button.SetTabSelected ~= nil
end

-- Dress one child by its shape. Returns true to keep walking into it.
Classify = function(child, kind, inList)
	if kind == 'Button' or kind == 'CheckButton' then
		local name = NameOf(child)
		if child.IconBorder then Item(child) return false end
		if name and name:find('CloseButton$') and not child.Left then Close(child) return false end
		if IsTab(child) then Tab(child) return false end
		if kind == 'CheckButton' and not child.Icon and not child.icon and child.GetCheckedTexture and child:GetCheckedTexture() then
			local width, height = Size(child)
			if width <= 36 and height <= 36 then Checkbox(child) return false end
		end
		if child.Arrow and (child.Text or child.Background) then Dropdown(child) return false end
		if (Has(child, 'Left', 'Texture') and Has(child, 'Right', 'Texture')) or (name and Is(_G[name..'Left'], 'Texture')
			and Is(_G[name..'Right'], 'Texture') and not _G[name..'Icon']) then
			PushButton(child)
			return false
		end
		if TextButton(child, inList) then PushButton(child) return false end
		return true
	elseif kind == 'EditBox' then
		if child.Left or child.Middle or child.searchIcon or child.Instructions or child.NineSlice then EditBox(child) end
		return false
	elseif kind == 'Slider' then
		local name = NameOf(child)
		if (name and name:find('ScrollBar')) or child.ScrollUpButton or (name and _G[name..'ScrollUpButton']) then ScrollBar(child)
		else Slider(child) end
		return false
	elseif kind == 'StatusBar' then
		StatusBar(child)
		return false
	end
	if child.Track and (child.Back or child.Forward) then ScrollBar(child) return false end
	if child.ScrollTarget and child.ForEachFrame then WatchList(child) end
	if child.GoldButton then Money(child) return false end
	if child.NineSlice and child.Bg and not child.CloseButton then Inset(child) end
	if NineSlicePanel(child) then Unbackdrop(child) end
	return true
end

Walk = function(frame, depth, inList)
	if depth > 10 then return end
	RelightRegions(frame)
	for _, child in ipairs({frame:GetChildren()}) do
		if not own[child] and not skip[child] and not Forbidden(child) and child.GetObjectType then
			local kind = child:GetObjectType()
			if not SKIP_TYPES[kind] then
				if Classify(child, kind, inList) then
					Decor(child)
					Walk(child, depth + 1, inList or child.ScrollTarget ~= nil)
				else
					RelightRegions(child)
				end
			end
		end
	end
end

-- Walks run one frame later, once per frame however often they are asked for.
local pending, scheduled = {}, false
local function Flush()
	scheduled = false
	local list = pending
	pending = {}
	for frame in pairs(list) do
		if not Forbidden(frame) and frame:IsVisible() then UI:Safe(Walk, frame, 0, boxes[frame] and true or false) end
	end
end
Queue = function(frame)
	if Forbidden(frame) then return end
	pending[frame] = true
	if not scheduled then
		scheduled = true
		C_Timer.After(0, Flush)
	end
end

-- Windows ----------------------------------------------------------------------------
local function TitleOf(frame)
	local container = frame.TitleContainer or (frame.BorderFrame and frame.BorderFrame.TitleContainer)
	local name = NameOf(frame)
	local title = (container and container.TitleText) or frame.TitleText or (frame.BorderFrame and frame.BorderFrame.TitleText)
		or (name and (_G[name..'TitleText'] or _G[name..'Title']))
	return Is(title, 'FontString') and title or nil
end

-- The printed header: status lamp, bold model code, the window's own title.
local function Header(frame, info)
	local head = Own(CreateFrame('Frame', nil, frame))
	head:SetPoint('TOPLEFT')
	head:SetPoint('TOPRIGHT')
	head:SetHeight(22)
	head:EnableMouse(false)
	head.lamp = Own(Kit:Led(head, 5, true))
	head.lamp:SetPoint('TOPLEFT', 10, -9)
	head.model = Own(Kit:Label(head, info.model or '', 'darkInk', 8, true))
	head.model:SetPoint('LEFT', head.lamp, 'RIGHT', 5, 0)
	local rule = Own(head:CreateTexture(nil, 'ARTWORK'))
	rule:SetColorTexture(1, 1, 1, 1)
	Kit:Tint(rule, 'darkEdge')
	rule:SetPoint('BOTTOMLEFT', 1, 0)
	rule:SetPoint('BOTTOMRIGHT', -1, 0)
	rule:SetHeight(UI.Pixel.Px(head, 1))
	local title = TitleOf(frame)
	if title then
		Kit:Font(title, 9, nil, false)
		Kit:Tint(title, 'darkDim')
		if not Locked(frame) then
			title:ClearAllPoints()
			title:SetPoint('LEFT', head.model, 'RIGHT', 6, 0)
			title:SetPoint('RIGHT', head, 'RIGHT', -30, 0)
			title:SetJustifyH('LEFT')
		end
	end
	return head
end

local function CloseOf(frame)
	local name = NameOf(frame)
	local named = name and _G[name..'CloseButton']
	if type(named) == 'table' and named.Left then named = nil end -- a text button called "Close"
	return frame.CloseButton or (frame.BorderFrame and frame.BorderFrame.CloseButton)
		or (frame.TitleContainer and frame.TitleContainer.CloseButton) or named or frame.ClosePanelButton
end

local INSETS = {'Inset', 'LeftInset', 'RightInset', 'BottomInset', 'TopInset', 'CenterInset'}
local housings = setmetatable({}, {__mode = 'k'}) -- window -> our housing shell

local function Opened(frame, info)
	Queue(frame)
	C_Timer.After(0.2, function() Queue(frame) end)
	if info.quiet ~= true then Sound('open', 'window') end
	if info.ownFade or InCombatLockdown() or Kit:DB().reduceMotion then return end
	Kit:Animate(frame, Kit:Speed('NORMAL'), 0, 1, function(alpha) frame:SetAlpha(alpha) end, nil, 'sine')
	-- Screen power-on (a motion extra): the housing (our own frame) flickers on.
	if Kit.PowerOn and housings[frame] then Kit:PowerOn(housings[frame]) end
end

local function Closed(_, info)
	-- Hiding the whole interface (Alt+Z, loading screens) is silent.
	if info.quiet == true or not UIParent:IsShown() then return end
	Sound('latch-up', 'window')
end

local function Window(frame, info)
	if Forbidden(frame) or not frame.GetChildren then return end
	info = info or {}
	if First('window', frame) then
		Strip(frame)
		if not Forbidden(frame.BorderFrame) then Strip(frame.BorderFrame) end
		if not Forbidden(frame.TitleContainer) then Strip(frame.TitleContainer) end
		DialogHeader(frame.Header)
		housings[frame] = Own(Kit:Shell(frame, {surface = 'dark', radius = info.radius or 10, shadowAlpha = 0.45}))
		if info.header ~= false and not frame.Header then Header(frame, info) end
		Close(CloseOf(frame))
		local name = NameOf(frame)
		for _, key in ipairs(INSETS) do
			Inset(frame[key])
			if name then Inset(_G[name..key]) end
		end
		if name then Inset(_G[name..'InsetRight']) end
		if info.after then UI:Safe(info.after, frame) end
		frame:HookScript('OnShow', function(self) Opened(self, info) end)
		frame:HookScript('OnHide', function(self) Closed(self, info) end)
	end
	Queue(frame)
end
UI.SkinWindow = Window

-- Per-window touches the walk can't find on its own -------------------------------------
local function CharacterPack(frame)
	local scene = _G.CharacterModelScene
	if scene then
		for _, key in ipairs({'BackgroundTopLeft', 'BackgroundTopRight', 'BackgroundBotLeft', 'BackgroundBotRight',
			'BackgroundOverlay'}) do Hide(scene[key]) end
	end
	for _, suffix in ipairs({'TopLeft', 'TopRight', 'BotLeft', 'BotRight', 'Overlay'}) do
		Hide(_G['CharacterModelFrameBackground'..suffix])
	end
	for _, suffix in ipairs({'TopLeft', 'TopRight', 'BottomLeft', 'BottomRight', 'Left', 'Right', 'Top', 'Bottom', 'Bottom2'}) do
		Hide(_G['PaperDollInnerBorder'..suffix])
	end
	local stats = _G.CharacterStatsPane
	if stats then
		Hide(stats.ClassBackground)
		if stats.ItemLevelFrame then Hide(stats.ItemLevelFrame.Background) end
		for _, key in ipairs({'ItemLevelCategory', 'AttributesCategory', 'EnhancementsCategory'}) do
			local category = stats[key]
			if type(category) == 'table' then
				Hide(category.Background)
				if Is(category.Title, 'FontString') then
					Kit:Font(category.Title, 9, nil, true)
					Kit:Tint(category.Title, 'darkInk')
				end
			end
		end
	end
	for _, slot in ipairs({'Head', 'Neck', 'Shoulder', 'Back', 'Chest', 'Shirt', 'Tabard', 'Wrist', 'Hands', 'Waist', 'Legs',
		'Feet', 'Finger0', 'Finger1', 'Trinket0', 'Trinket1', 'MainHand', 'SecondaryHand', 'Ranged', 'Ammo'}) do
		local button = _G['Character'..slot..'Slot']
		if button and not Forbidden(button) then
			Hide(_G['Character'..slot..'SlotFrame'])
			Item(button)
		end
	end
	-- Forever's two-pane character window.
	for _, key in ipairs({'LeftPaneHost', 'RightPaneHost'}) do
		local pane = frame[key]
		if type(pane) == 'table' then
			Strip(pane)
			Hide(pane.StoneBg)
		end
	end
	if type(frame.RightPaneHost) == 'table' then Inset(frame.RightPaneHost) end
	local paperDoll = _G.PaperDollFrame
	if paperDoll and type(paperDoll.TopBackgroundStripHost) == 'table' then Strip(paperDoll.TopBackgroundStripHost) end
	-- The rest of the window (slots, model screen, stats, side tabs, panes):
	-- Modules/SkinsCharacter.lua.
	if module.CharacterExtras then UI:Safe(module.CharacterExtras, frame) end
end

-- Windows dressed further by Modules/SkinsSettings.lua (settings, game menu, Edit Mode).
local function Extra(name)
	return function(frame)
		local extra = module.extras and module.extras[name]
		if extra then UI:Safe(extra, frame) end
	end
end

local function MapPack(frame)
	if type(frame.ScrollContainer) == 'table' then skip[frame.ScrollContainer] = true end
	local nav = frame.NavBar
	if type(nav) == 'table' then
		Strip(nav)
		if type(nav.overlay) == 'table' then Strip(nav.overlay) end
		Hide(nav.InsetBorderBottom)
	end
	local quests = _G.QuestMapFrame
	if quests and frame == _G.WorldMapFrame then
		Hide(quests.Background)
		if type(quests.DetailsFrame) == 'table' then Strip(quests.DetailsFrame) end
	end
end

local function TalentPack(frame)
	local talents = frame.TalentsFrame
	if type(talents) == 'table' then
		-- The talent tree itself is left to the game: its buttons take part in
		-- protected actions and draw their own art per node.
		if type(talents.ButtonsParent) == 'table' then skip[talents.ButtonsParent] = true end
		Hide(talents.Background)
		Hide(talents.BlackBG)
	end
	local spells = frame.SpellBookFrame
	if type(spells) == 'table' then
		for _, key in ipairs({'BookBGLeft', 'BookBGRight', 'BookBGHalved', 'BookCornerFlipbook', 'Bookmark'}) do Hide(spells[key]) end
	end
end

local function LossOfControlPack(frame)
	for _, key in ipairs({'blackBg', 'RedLineTop', 'RedLineBottom'}) do Hide(frame[key]) end
	if Is(frame.AbilityName, 'FontString') then Kit:Font(frame.AbilityName, 16, 'OUTLINE', true) end
	local left = frame.TimeLeft
	if type(left) == 'table' then
		if Is(left.NumberText, 'FontString') then Kit:Font(left.NumberText, 14, 'OUTLINE', true) end
		if Is(left.SecondsText, 'FontString') then Kit:Font(left.SecondsText, 14, 'OUTLINE', true) end
	end
end

-- name, model code, options. Windows from load-on-demand Blizzard addons are
-- picked up when their addon loads.
local WINDOWS = {
	{'CharacterFrame', 'CH-1', after = CharacterPack}, {'PlayerSpellsFrame', 'SP-1', after = TalentPack},
	{'SpellBookFrame', 'SP-2', after = TalentPack}, {'ClassTalentFrame', 'TL-1', after = TalentPack},
	{'ProfessionsFrame', 'PR-1'}, {'ProfessionsBookFrame', 'PR-2'}, {'ProfessionsCustomerOrdersFrame', 'PR-3'},
	{'CollectionsJournal', 'CL-1'}, {'WardrobeFrame', 'CL-2'}, {'TransmogFrame', 'CL-3'}, {'EncounterJournal', 'EJ-1'},
	{'AchievementFrame', 'AC-1'}, {'WorldMapFrame', 'MP-1', radius = 8, after = MapPack},
	{'FlightMapFrame', 'MP-2', radius = 8, after = MapPack}, {'BattlefieldMapFrame', 'MP-3', radius = 8, after = MapPack},
	{'QuestFrame', 'QS-1'}, {'QuestLogPopupDetailFrame', 'QS-2'}, {'QuestLogFrame', 'QS-3'}, {'GossipFrame', 'GS-1'},
	{'MerchantFrame', 'MR-1'}, {'MailFrame', 'ML-1'}, {'OpenMailFrame', 'ML-2'}, {'BankFrame', 'BK-1'},
	{'GuildBankFrame', 'BK-2'}, {'ContainerFrameCombinedBags', 'BG-0'}, {'TradeFrame', 'TR-1'},
	{'AuctionHouseFrame', 'AH-1'}, {'AuctionFrame', 'AH-1'}, {'FriendsFrame', 'FR-1'}, {'CommunitiesFrame', 'CM-1'},
	{'GuildFrame', 'CM-2'}, {'PVEFrame', 'GF-1'}, {'LFGParentFrame', 'GF-1'}, {'PVPFrame', 'PV-1'}, {'PVPParentFrame', 'PV-1'},
	{'RaidParentFrame', 'RD-1'}, {'GameMenuFrame', 'SY-1', header = false, after = Extra('GameMenuFrame')},
	{'SettingsPanel', 'ST-1', after = Extra('SettingsPanel')},
	{'AddonList', 'AD-1'}, {'MacroFrame', 'MC-1'}, {'ItemTextFrame', 'TX-1'}, {'TaxiFrame', 'TX-2'},
	{'ClassTrainerFrame', 'TN-1'}, {'InspectFrame', 'IN-1'}, {'DressUpFrame', 'DR-1'}, {'TimeManagerFrame', 'TM-1'},
	{'CalendarFrame', 'CA-1'}, {'HelpFrame', 'HP-1'}, {'ChatConfigFrame', 'CC-1'}, {'KeyBindingFrame', 'KB-1'},
	{'QuickKeybindFrame', 'KB-2'}, {'EditModeManagerFrame', 'EM-1', after = Extra('EditModeManagerFrame')},
	{'EditModeSystemSettingsDialog', 'EM-2', header = false, after = Extra('EditModeSystemSettingsDialog')},
	{'PetitionFrame', 'PT-1'}, {'TabardFrame', 'TB-1'}, {'GuildRegistrarFrame', 'GR-1'}, {'StableFrame', 'SB-1'},
	{'PetStableFrame', 'SB-1'}, {'ItemSocketingFrame', 'SK-1'}, {'ItemUpgradeFrame', 'UP-1'}, {'ItemInteractionFrame', 'II-1'},
	{'ScrappingMachineFrame', 'SC-1'}, {'WeeklyRewardsFrame', 'WR-1'}, {'MajorFactionRenownFrame', 'RN-1'},
	{'ChannelFrame', 'CN-1'}, {'ClickBindingFrame', 'CB-1'}, {'GuildControlUI', 'GC-1'}, {'DeathRecapFrame', 'DR-2'},
	{'ColorPickerFrame', 'CP-1', header = false}, {'LFGDungeonReadyDialog', 'GF-2', header = false},
	{'LFGDungeonReadyStatus', 'GF-2', header = false, quiet = true}, {'LFGListInviteDialog', 'GF-3', header = false},
	{'LFGListApplicationDialog', 'GF-3', header = false}, {'ReadyCheckListenerFrame', 'RC-1', header = false},
	{'RolePollPopup', 'RC-2', header = false}, {'CooldownViewerSettings', 'CD-1'}, {'CurrencyTransferMenu', 'CU-1'},
	{'TokenFramePopup', 'CU-2', header = false}, {'ReputationDetailFrame', 'RP-2', header = false},
	{'GearManagerPopupFrame', 'EQ-1'}, {'BattlefieldFrame', 'PV-2'},
	{'LossOfControlFrame', 'LC-1', header = false, ownFade = true, quiet = true, after = LossOfControlPack},
}
for index = 1, 4 do WINDOWS[#WINDOWS + 1] = {'StaticPopup'..index, 'AL-'..index, header = false} end
for index = 1, 13 do WINDOWS[#WINDOWS + 1] = {'ContainerFrame'..index, 'BG-'..index} end

-- Frames the notifications module dresses; the generic catch-all leaves them be.
local NOT_MINE = {LootFrame = true, GroupLootContainer = true, AlertFrame = true, LevelUpDisplay = true,
	ZoneTextFrame = true, SubZoneTextFrame = true, BossBanner = true, EventToastManagerFrame = true}
for index = 1, 4 do NOT_MINE['GroupLootFrame'..index] = true end

-- With the bags module on, Blizzard's bag and bank windows are parked and
-- never seen, so they are left alone.
local OWN_BAGS = {ContainerFrameCombinedBags = true, BankFrame = true}
for index = 1, 13 do OWN_BAGS['ContainerFrame'..index] = true end
local function BagsOwned(name)
	local bags = UI.modules.bags
	return name and OWN_BAGS[name] and bags and UI:ModuleEnabled('bags') and not bags.problem and true or false
end

local watched = setmetatable({}, {__mode = 'k'})
local function WatchAll()
	for _, info in ipairs(WINDOWS) do
		local frame = _G[info[1]]
		if type(frame) == 'table' and not watched[frame] and not Forbidden(frame) and frame.HookScript and not BagsOwned(info[1]) then
			watched[frame] = true
			info.model = info.model or info[2]
			UI:Safe(Window, frame, info)
		end
	end
end

-- Any other panel the game opens: a model code made from its name.
local function Generic(frame)
	if Forbidden(frame) or watched[frame] or not frame.HookScript then return end
	local name = NameOf(frame) or 'Panel'
	if NOT_MINE[name] or BagsOwned(name) then return end
	watched[frame] = true
	local info = {model = name:sub(1, 2):upper()..'-1'}
	UI:Safe(Window, frame, info)
	-- It is already open: the open sound and fade happen now.
	if frame:IsShown() then Opened(frame, info) end
end

-- Text the game colors for parchment as it fills a window.
local function RelightTitle(fontString)
	if Is(fontString, 'FontString') then fontString:SetTextColor(Kit:RGB('darkInk')) end
end
local function RelightText(fontString)
	if Is(fontString, 'FontString') then fontString:SetTextColor(LIGHT[1], LIGHT[2], LIGHT[3]) end
end

local function RelightQuest()
	for _, name in ipairs({'QuestInfoFrame', 'QuestInfoRewardsFrame', 'QuestDetailScrollChildFrame', 'QuestRewardScrollChildFrame',
		'QuestProgressScrollChildFrame', 'QuestGreetingScrollChildFrame', 'QuestMapFrame'}) do
		local frame = _G[name]
		if type(frame) == 'table' and not Forbidden(frame) and frame:IsVisible() then RelightAll(frame, 0) end
	end
	for _, name in ipairs({'QuestInfoTitleHeader', 'QuestInfoDescriptionHeader', 'QuestInfoObjectivesHeader',
		'QuestProgressTitleText', 'QuestInfoSpellObjectiveLearnLabel'}) do
		RelightTitle(_G[name])
	end
	local rewards = _G.QuestInfoRewardsFrame
	if type(rewards) == 'table' then
		RelightTitle(rewards.Header)
		Queue(rewards)
	end
	local mapRewards = _G.MapQuestInfoRewardsFrame
	if type(mapRewards) == 'table' then Queue(mapRewards) end
end

-- Menus (the context and dropdown menus of 11.x and later): dark glass.
-- Menus are built in a protected pipeline, so nothing here runs inside it:
-- the hooks below only note which menu frame was generated, and the skin is
-- applied from our own timer once the game is done. No callback is ever handed
-- to a menu description, and no menu frame gets textures or scripts of ours:
-- the glass is a frame of our own, parented to the menu. The game's pooled
-- textures are only emptied (it sets their art again whenever it reuses them),
-- never recolored, so a reused texture never carries our changes elsewhere.
local glasses = setmetatable({}, {__mode = 'k'})
local function SkinMenu(menu)
	if Forbidden(menu) or not menu.GetRegions then return end
	local glass = glasses[menu]
	if not glass then
		glass = Own(CreateFrame('Frame'))
		glass.shell = Own(Kit:Shell(glass, {surface = 'glass', edge = 'darkEdge', radius = 6, shadowAlpha = 0.5}))
		glasses[menu] = glass
	end
	if glass:GetParent() ~= menu then glass:SetParent(menu) end
	glass:ClearAllPoints()
	glass:SetAllPoints(menu)
	-- Level with the menu: above its own background, below its rows.
	glass:SetFrameStrata(menu:GetFrameStrata())
	glass:SetFrameLevel(menu:GetFrameLevel())
	Kit:Relevel(glass)
	glass:Show()
	for _, region in ipairs({menu:GetRegions()}) do
		if Is(region, 'Texture') and not own[region] then region:SetTexture(nil) end
	end
end

local menuQueue, menusArmed = {}, false
local function FlushMenus()
	menusArmed = false
	local list = menuQueue
	menuQueue = {}
	for menu in pairs(list) do UI:Safe(SkinMenu, menu) end
end
local function QueueMenu(menu)
	if type(menu) ~= 'table' then return end
	menuQueue[menu] = true
	if not menusArmed then
		menusArmed = true
		C_Timer.After(0, FlushMenus)
	end
end

local menusHooked = false
local function HookMenus()
	if menusHooked or not (_G.Menu and _G.Menu.GetManager) then return end
	local manager = _G.Menu.GetManager()
	if not manager then return end
	menusHooked = true
	local function MenuOpened(self)
		C_Timer.After(0, function()
			local menu = self.GetOpenMenu and self:GetOpenMenu()
			if menu then UI:Safe(SkinMenu, menu) end
			Sound('blip', 'menu')
		end)
	end
	if manager.OpenMenu then hooksecurefunc(manager, 'OpenMenu', MenuOpened) end
	if manager.OpenContextMenu then hooksecurefunc(manager, 'OpenContextMenu', MenuOpened) end
	-- Every menu level, root and flyouts, is styled through its style mixin's
	-- Generate, copied onto the menu frame at each open; the post-hook hands
	-- over that frame. hooksecurefunc only: never assign into the mixin.
	for _, name in ipairs({'MenuStyle1Mixin', 'MenuStyle2Mixin'}) do
		local mixin = _G[name]
		if type(mixin) == 'table' and type(mixin.Generate) == 'function' then
			hooksecurefunc(mixin, 'Generate', QueueMenu)
		end
	end
end

-- Old dropdown lists (UIDropDownMenu), still used by some windows and addons.
local function SkinDropDownLists()
	for level = 1, _G.UIDROPDOWNMENU_MAXLEVELS or 3 do
		local list = _G['DropDownList'..level]
		if type(list) == 'table' and not Forbidden(list) and First('ddlist', list) then
			for _, suffix in ipairs({'Backdrop', 'MenuBackdrop'}) do
				local piece = _G['DropDownList'..level..suffix]
				if type(piece) == 'table' then Hide(piece) end
			end
			Own(Kit:Shell(list, {surface = 'glass', radius = 6, shadowAlpha = 0.5}))
		end
	end
end

-- Breath, fatigue and feign-death timers as dot meters.
local function SkinMirrorTimers()
	local timers = {}
	local container = _G.MirrorTimerContainer
	if type(container) == 'table' and not Forbidden(container) then
		for _, child in ipairs({container:GetChildren()}) do timers[#timers + 1] = child end
	end
	for index = 1, 3 do timers[#timers + 1] = _G['MirrorTimer'..index] end
	for _, timer in ipairs(timers) do
		if type(timer) == 'table' and not Forbidden(timer) and timer.GetRegions and First('mirror', timer) then
			local name = NameOf(timer)
			local bar = timer.StatusBar or (name and _G[name..'StatusBar'])
			Strip(timer)
			if name then Hide(_G[name..'Border']) end
			if Is(bar, 'StatusBar') then StatusBar(bar) end
			local text = timer.Text or (name and _G[name..'Text'])
			if Is(text, 'FontString') then Kit:Font(text, 10, 'OUTLINE', true) end
		end
	end
end

-- Warnings and errors in the reference's typeface.
local function Messages()
	local errors = _G.UIErrorsFrame
	if type(errors) == 'table' and errors.SetFont then errors:SetFont(Kit:FontPath(true), 14, 'OUTLINE') end
	for _, name in ipairs({'RaidWarningFrameSlot1', 'RaidWarningFrameSlot2', 'RaidBossEmoteFrameSlot1', 'RaidBossEmoteFrameSlot2'}) do
		if Is(_G[name], 'FontString') then Kit:Font(_G[name], 18, 'OUTLINE', true) end
	end
end

-- Walks asked for by events and refreshes: at most one per window every 0.25 s,
-- with one trailing walk so the last change is always seen.
local lastEventWalk = setmetatable({}, {__mode = 'k'})
local trailing = setmetatable({}, {__mode = 'k'})
local function Debounced(frame)
	if type(frame) ~= 'table' or Forbidden(frame) or not frame:IsVisible() then return end
	local wait = 0.25 - (GetTime() - (lastEventWalk[frame] or 0))
	if wait <= 0 then
		lastEventWalk[frame] = GetTime()
		Queue(frame)
	elseif not trailing[frame] then
		trailing[frame] = true
		C_Timer.After(wait, function()
			trailing[frame] = nil
			lastEventWalk[frame] = GetTime()
			Queue(frame)
		end)
	end
end

local BAGS = {'ContainerFrameCombinedBags', 'BankFrame'}
for index = 1, 13 do BAGS[#BAGS + 1] = 'ContainerFrame'..index end
local EVENT_FRAMES = {BAG_UPDATE_DELAYED = BAGS, BANKFRAME_OPENED = {'BankFrame'}, MERCHANT_UPDATE = {'MerchantFrame'},
	MAIL_INBOX_UPDATE = {'MailFrame', 'OpenMailFrame'}}

function module:Enable()
	WatchAll()
	HookMenus()
	UI:Safe(SkinDropDownLists)
	UI:Safe(Messages)
	local driver = CreateFrame('Frame')
	for _, event in ipairs({'ADDON_LOADED', 'PLAYER_ENTERING_WORLD', 'MIRROR_TIMER_START', 'BAG_UPDATE_DELAYED',
		'BANKFRAME_OPENED', 'MERCHANT_UPDATE', 'MAIL_INBOX_UPDATE'}) do
		pcall(driver.RegisterEvent, driver, event)
	end
	driver:SetScript('OnEvent', function(_, event)
		if event == 'ADDON_LOADED' or event == 'PLAYER_ENTERING_WORLD' then
			WatchAll()
			HookMenus()
		elseif event == 'MIRROR_TIMER_START' then
			C_Timer.After(0, function() UI:Safe(SkinMirrorTimers) end)
		else
			-- Contents changed: walk again only the windows the event concerns.
			for _, name in ipairs(EVENT_FRAMES[event] or {}) do
				if not BagsOwned(name) then Debounced(_G[name]) end
			end
		end
	end)
	SkinMirrorTimers()

	-- Global functions the game calls as windows fill. Post-hooks only.
	local hooks = {
		ShowUIPanel = function(frame) if not Forbidden(frame) and not watched[frame] then Generic(frame) end end,
		SetItemButtonQuality = FollowQuality, SetItemButtonBorder = FollowQuality, SetItemButtonBorderVertexColor = FollowQuality,
		PanelTemplates_SelectTab = RepaintTabs, PanelTemplates_DeselectTab = RepaintTabs, PanelTemplates_SetTab = RepaintTabs,
		PanelTemplates_UpdateTabs = RepaintTabs, PanelTemplates_EnableTab = RepaintTabs, PanelTemplates_DisableTab = RepaintTabs,
		QuestFrame_SetTitleTextColor = RelightTitle, QuestFrame_SetTextColor = RelightText,
		QuestInfo_Display = function() C_Timer.After(0, RelightQuest) end,
		QuestFrameProgressItems_Update = function() C_Timer.After(0, RelightQuest) end,
		QuestFrameGreetingPanel_OnShow = function() C_Timer.After(0, RelightQuest) end,
		QuestLogQuests_Update = function() if type(_G.QuestMapFrame) == 'table' then Queue(_G.QuestMapFrame) end end,
		ContainerFrame_Update = function(frame) if not BagsOwned(NameOf(frame)) then Debounced(frame) end end,
		ContainerFrame_GenerateFrame = function(frame) if not BagsOwned(NameOf(frame)) then Queue(frame) end end,
		BankFrameItemButton_Update = function(button) Item(button) end,
		UIDropDownMenu_CreateFrames = SkinDropDownLists,
		ToggleDropDownMenu = SkinDropDownLists,
	}
	for name, func in pairs(hooks) do
		if type(_G[name]) == 'function' then
			hooksecurefunc(name, function(...) UI:Safe(func, ...) end)
		end
	end
	-- Retail's tab system: the mixin is hooked before the on-demand windows make their tabs.
	local mixin = _G.TabSystemButtonMixin
	if type(mixin) == 'table' and mixin.SetTabSelected then
		hooksecurefunc(mixin, 'SetTabSelected', function(tab) if tabs[tab] then UI:Safe(PaintTab, tab) end end)
	end
	-- Book text is recolored by the game on every page.
	local book = _G.ItemTextFrame
	if type(book) == 'table' and book.HookScript then
		book:HookScript('OnEvent', function()
			local page = _G.ItemTextPageText
			if type(page) == 'table' then RelightRegions(page) end
		end)
	end
end

Kit:OnRefresh(function()
	if module.enabled then UI:Safe(Messages) end
	for tab in pairs(tabs) do UI:Safe(PaintTab, tab) end
end)

-- The dressing kit, for the window-specific files (SkinsCharacter, SkinsSettings).
module.parts = {
	IsSecret = IsSecret, Forbidden = Forbidden, Is = Is, Hide = Hide, Size = Size, Locked = Locked, NameOf = NameOf,
	Sound = Sound, First = First, Own = Own, IsOwn = function(object) return own[object] == true end,
	Skip = function(frame) skip[frame] = true end, Back = Back, Strip = Strip, Inset = Inset, Decor = Decor,
	HideButtonArt = HideButtonArt, Keycap = Keycap, CapState = CapState, PushButton = PushButton, Close = Close,
	Checkbox = Checkbox, Tab = Tab, PaintTab = PaintTab, RepaintTabs = RepaintTabs, StepButton = StepButton,
	ScrollBar = ScrollBar, Slider = Slider, StatusBar = StatusBar, Item = Item, IconOf = IconOf, EditBox = EditBox,
	Dropdown = Dropdown, DialogHeader = DialogHeader, RelightRegions = RelightRegions, RelightAll = RelightAll,
	SetFonts = SetFonts, fonts = {key = KEY_FONT, keyHot = KEY_HOT, keyDim = KEY_DIM, tabOn = TAB_ON, tabOff = TAB_OFF,
		tabHot = TAB_HOT, ink = INK_FONT, inkHot = INK_HOT, inkDim = INK_DIM},
	Ring = function(button) return rings[button] end,
	Quality = Quality,
	SetQualitySource = function(button, source) qualitySources[button] = source; Quality(button) end,
	Queue = function(frame) Queue(frame) end, QueueRow = QueueRow, WatchList = WatchList,
	Walk = function(frame) Walk(frame, 0, false) end,
}

-- defaults:begin
UI:RegisterDefaults('skins', {itemLevel = true, slotLegends = true, sideTabs = 'icons', modelScreen = true})
-- defaults:end

UI:RegisterPage('windows', {title = 'Windows', order = 14, cards = {
	{title = 'Windows and bags', rows = {
		{'segmented', 'Style', 'style.windows', items = {{'display', 'Device'}, {'blizzard', 'Blizzard'}}, reload = true,
			note = 'Every window as a charcoal SPEC-01 device: printed header, black screens, keycaps, glass fields and keyed item slots.'},
		{'segmented', 'Tooltips', 'style.tooltip', items = {{'display', 'Glass'}, {'blizzard', 'Blizzard'}}, reload = true,
			note = 'Dark glass with a lit edge; item quality as the top line.'},
		{'switch', 'Interface sounds', 'sound.interface', 'Windows click open and latch shut; keys, checks, tabs and lists answer too.'},
	}},
	{title = 'Character window', rows = {
		{'switch', 'Item levels', 'skins.itemLevel', 'Each equipped item\'s level on an LCD strip under its slot, in its quality color.', since = '0.5.1'},
		{'switch', 'Slot legends', 'skins.slotLegends', 'Empty slots show a printed legend (HEAD, NECK, RNG1...) instead of the game\'s silhouettes.', since = '0.5.1'},
		{'segmented', 'Side tabs', 'skins.sideTabs', items = {{'icons', 'Game icons'}, {'glyphs', 'SPEC-01 glyphs'}},
			note = 'The big tabs on the window\'s right edge: the game\'s icons cropped onto keys, or SPEC-01 glyphs where one fits.', since = '0.5.1'},
		{'switch', 'Model screen', 'skins.modelScreen', 'Your character on a black display with a faint grid and corner marks.', since = '0.5.1'},
	}},
}})
