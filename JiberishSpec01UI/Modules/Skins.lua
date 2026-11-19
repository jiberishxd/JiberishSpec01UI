-- Every Blizzard window, dialog and menu as a SPEC-01 device.
--
-- A window loses its parchment, portrait and borders and becomes a charcoal
-- housing drawn from code (Kit:Shell): a printed header with a status lamp,
-- a bold model code and the window's name, and its insets and lists set on
-- black screens. Then everything inside is walked and dressed by its shape:
--   three-part and text buttons   -> charcoal keycaps that go down when pressed
--   small icon buttons            -> charcoal keycaps with a kit glyph (zoom,
--                                    page, search, filter...) or the game's
--                                    icon relit monochrome (rotate, reset...)
--   check buttons                 -> a glass box with a lit check
--   tabs                          -> segmented keys, the selected one raised and light;
--                                    rows that overlap in the game's art are spread
--                                    so the keys sit side by side
--   side tabs (icon tabs)         -> keys around the icon, light and lit when chosen
--   scroll bars                   -> a thin track with a dark thumb
--   sliders                       -> a glass track with a round thumb
--   status bars                   -> LED dot meters
--   item and spell slots          -> light keys with a quality-colored edge
--   edit boxes and search boxes   -> black glass fields
--   dropdowns                     -> keycaps with a chevron
--   insets and scrolling lists    -> black screens
--   large background art          -> removed; dark text relit light
-- Blizzard's art is also told apart by its atlas or file name: ornate frame
-- art (metal and wood borders, rivets, filigree, parchment, slot frames, gold
-- button faces) goes wherever it sits, and the game's gold, blue and green
-- highlight and selection glows are relit as a faint white lift.
-- Windows are walked again on show and when their lists or pages update, so
-- pooled rows and late content get the same treatment. Windows click open and
-- latch shut, keys, checks, tabs and lists answer with the SPEC-01 voices.
--
-- Loot and roll frames, alerts and banners belong to the notifications module.
--
-- Combat and taint: nothing here writes a field onto a Blizzard frame. Global
-- functions, the menu manager and a few mixins and side tabs are post-hooked
-- with hooksecurefunc and scripts are added with HookScript; everything this
-- file adds lives in weak side tables. Regions of protected frames are never
-- re-anchored in combat. Values that may be secret are tested with
-- issecretvalue before anything else touches them.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, CreateFont, InCombatLockdown, C_Timer = CreateFrame, CreateFont, InCombatLockdown, C_Timer
local max, min, floor = math.max, math.min, math.floor
local type, ipairs, pairs, pcall = type, ipairs, pairs, pcall

local module = UI:RegisterModule('windows', {})

local IsSecret, Forbidden, Is = UI.Util.IsSecret, UI.Util.Forbidden, UI.Util.IsObjectType
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

-- Small round lamps stay crisp: snapped to the pixel grid, no texel bias.
local function Crisp(texture)
	if texture.SetSnapToPixelGrid then texture:SetSnapToPixelGrid(true) end
	if texture.SetTexelSnappingBias then texture:SetTexelSnappingBias(0) end
	return texture
end

-- Text -------------------------------------------------------------------------
-- Blizzard's buttons and tabs take their text from font objects, which they
-- swap on every state change, so the SPEC-01 legends are font objects too.
local fonts -- key, keyHot, keyDim (charcoal keys), tabOn, tabOff, tabHot, ink, inkHot, inkDim (the light key)
do
	local list = {}
	local function FontObject(name, size, token, bold)
		local font = CreateFont('JiberishSpec01'..name)
		list[#list + 1] = {font, size, token, bold}
		return font
	end
	fonts = {
		key = FontObject('KeyText', 10, 'darkInk', true), keyHot = FontObject('KeyHighlight', 10, 'white', true),
		keyDim = FontObject('KeyDisabled', 10, 'darkDim', true), tabOn = FontObject('TabOn', 9, 'ink', true),
		tabOff = FontObject('TabOff', 9, 'darkDim', true), tabHot = FontObject('TabHighlight', 9, 'darkInk', true),
		-- Legends on the light key of a window's main action.
		ink = FontObject('KeyInk', 10, 'ink', true), inkHot = FontObject('KeyInkHighlight', 10, 'ink', true),
		inkDim = FontObject('KeyInkDisabled', 10, 'dim', true),
	}
	local function PaintFonts()
		for _, entry in ipairs(list) do
			local font, size, token, bold = entry[1], entry[2], entry[3], entry[4]
			if font:SetFont(Kit:FontPath(bold), size, '') == false then font:SetFont(STANDARD_TEXT_FONT, size, '') end
			font:SetTextColor(Kit:RGB(token))
			font:SetShadowOffset(0, 0)
		end
	end
	PaintFonts()
	Kit:OnRefresh(PaintFonts)
end

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

-- Blizzard art by name ------------------------------------------------------------
-- Ornate art is found by its atlas or file name (lowercased, backslashes):
-- 'hide' for frame art, slot frames and gold faces, 'relit' for the game's
-- highlight and selection glows. Verdicts are cached per name, so a window
-- full of rows costs one table lookup per texture after the first.
local ArtName, ArtVerdict, Relit, Ornaments
do
	local RELIT = {'ui-common-mousehilight', 'buttonhilight-square', 'buttonhilight-round', 'checkbuttonhilight',
		'ui-questtitlehighlight', 'ui-questlogtitlehighlight', 'ui-questitemhighlight', 'highlightbar', 'ui-listbox-highlight',
		'ui-character-tab-highlight', 'search-highlight', 'search-select', 'petlist-buttonhighlight', 'petlist-buttonselect',
		'nav-button-highlight', 'nav-button-select', 'ui-silver-button-highlight', 'ui-silver-button-select',
		'ui-achievement-category-highlight', 'ui-achievement-statusbar-highlight', 'ui-tradeframe-highlight',
		'ui-taxi-icon-highlight', 'ui-gearmanager-itembutton-highlight', 'common-button-list-large-hover',
		'common-button-list-large-selected', 'common-button-list-mid2-hover', 'common-button-list-mid2-selected',
		'iconframe-hover', 'iconframe-passive-hover', 'spec-hover-background', 'spec-selected-background',
		'pvpqueue-button-highlight', 'pvpqueue-button-selected', 'pvpqueue-button-casual-highlight',
		'pvpqueue-button-casual-selected', 'groupfinder-button-cover-hover', 'campcollection-frame-hover', 'transmog-tab-hl',
		'ui-character-reputationbar-highlight', 'trainertextures', 'guildframe\\guildframe'}
	local ORNATE = {
		-- Window and panel frames: metal, wood, rivets, filigree, inner tiles.
		'ui-frame-', '_ui-frame', '!ui-frame', 'generalframe-insetframe', 'diamondmetal', 'portraitmetal', 'framegeneral\\',
		'ui-background-rock', 'ui-background-marble', 'metalborder', 'woodborder', 'tsunami-corners', 'common-insideframe',
		'common-framedivider', 'gold-divide', 'filigree', 'mapcornershadow', 'bluemenu', 'dialogframe\\dialogframe-',
		'ui-dialogbox-background', 'ui-dialogbox-divider', 'ui-dialogbox-gold', 'common\\thinborder', 'shadowoverlay',
		'ui-frame-bossportrait', 'footer-bg', 'horizontaldivider', 'ui-horizontalbreak', 'ui-raidinfo-header',
		-- Parchment, pages and letters.
		'parchment', 'questbg', 'questdetailsbackgrounds', 'itemtextframe\\itemtext-', 'stationery', 'ui-mailframebg',
		'invoiceline', 'questlog-frame', 'questlog-main-background', 'questlog-reward-header', 'questlog-reward-tile',
		'questlog-reward-top-frame', 'campaign-questlog-lorebackground', 'spellbook-background', 'spellbook-page',
		'spellbook-corner', 'spellbook-divider', 'spellbook-list-backplate', 'spellbook-item-backplate', 'spellbook-parts',
		'spellbook\\professionsbook', 'professions-book-', 'spellbookdivider', 'talentframe-horizontal',
		'talentframe-vertical', 'talentframe-parts', 'talents-background', 'talents-inner-frame', 'talents-divider',
		'talents-small-divider', 'spec-background', 'spec-columndivider', 'spec-dividerline',
		-- The character and inspect sheets.
		'ui-character-info-gearslot', 'ui-character-info-title', 'ui-character-info-line-bounce', 'stonebg',
		'ui-character-info-general-bg', 'ui-character-info-stat-bg', 'ui-character-info-scrollline',
		'ui-character-info-racebg', 'ui-character-info-outfiticon-frame', 'char-paperdoll', 'char-stat-', 'char-corner',
		'char-inner', 'ui-gearmanager-border', 'ui-gearmanager-title-background', 'ui-character-reputation-detailbackground',
		'ui-character-skills-barborder', 'character-panel-background', 'dressingroom-background', 'dressingroom-sideframe',
		-- Slot frames and empty slots (the item key replaces them).
		'ui-emptyslot', 'ui-quickslot', 'ui-slot-background', 'whiteiconframe', 'spellbook-item-iconframe',
		'mountequipment-slot-background', 'mountequipment-slot-corners', 'bank-frame-item-slotframe',
		'bank-frame-bag-slotframe', 'bank-frame-bag-slot-bg', 'ui-questitemnameframe', 'ui-merchant-labelslots',
		'ui-lfg-icon-rewardring', 'ui-achievement-iconframe', 'ui-achievement-progressive-iconborder', 'mailitemborder',
		'ui-guildbankframe-slots', 'professions-slot-frame', 'professions-slot-bg',
		-- Gold and red button faces, tab art and scroll bar caps the keys replace.
		'ui-panel-button', 'dark-goldframe-button', 'uiframe-tab', 'uiframe-activetab', 'optionsframe-activetab',
		'optionsframe-inactivetab', 'common-sidetab', 'ui-guildbankframe-tab', 'interface\\chatframe\\chatframetab',
		'ui-scrollbar-endcap', 'ui-classicscrollbar', 'ui-scrollbar-center', 'macropopup-scrollbar', 'ui-pagebutton-background',
		'whoframe-columntabs', 'common-input-border', 'common-search-border', 'ui-moneyframe-border',
		-- Window backgrounds of their own.
		'groupfinder-background', 'groupfinder-scrollline', 'groupfinder-roles-background', 'ui-lfg-background',
		'ui-lfg-bluebg', 'ui-lfg-separator', 'ui-lfg-dividerline', 'collections-background', 'pet-list-bg',
		'petlist-buttonbackground', 'petjournal-petcard-bg', 'petjournal-petbattleachievementbg', 'mountjournal-bg',
		'petjournal-battleslotframe', 'mountequipment-background', 'ui-achievement-achievementbackground',
		'ui-achievement-borders', 'ui-achievement-category-background', 'ui-achievement-header',
		'ui-achievement-recentheader', 'ui-achievement-comparisonheader', 'ui-achievement-rightddlinset',
		'ui-achievement-statsbackground', 'ui-achievement-statscomparisonbackground', 'ui-achievement-reward-background',
		'ui-achievement-progressbar-border', 'ui-merchant-botframe', 'guildbankframe\\corners', 'guildvaultbg',
		'guildbankframe\\horiztile', 'guildbankframe\\verttile', 'ui-guildbankframe-emblemborder', 'ui-tabnameborder',
		'ui-classtrainer-filterborder', 'ui-classtrainer-horizontalbar', 'auctionhouse-background',
		'auctionhouse-itemheaderframe', 'ui-auctionpost', 'auctionhousedressupframe', 'bank-frame-background',
		'bank-frame-shadow', 'bank-frame-vert-shadow', 'bank-frame-horiz-shadow', 'bank-divider', 'professions-background',
		'profession-background', 'professions-recipe-header', 'professions-specializations-background',
		'professions-qualitypane-bg', 'professions-skillbar-frame', 'professions-equipment-divider',
		'professions-qualitypane-divider', 'professions-specializations-divider', 'professions-qualitybar-frame',
		'craftingorder-divider', 'communities-widebackground', 'ui-friendsframe-onlinedivider', 'plusmanz-battlenetbg',
		'clockbackground', 'timerbackground', 'tabardframeouterframe', 'tabardframecustomizationframe',
		'ui-stables-footer-bg', 'ui-stables-horz-divider', 'ui-stables-subheader-bg', 'ui-stables-pet-model-bg',
		'pvpqueue-background', 'pvpqueue-sidebar-background', 'pvpqueue-conquestbar-frame', 'honorsystem-bar-frame',
		'token-info-background', 'transfer-log-background', 'transfer-panel-background', 'ui-ej-background',
		'ui-ej-journalbg', 'ui-ej-lorebg', 'ui-ej-bossmodelpaperframe', 'ui-ej-memoryframe', 'ui-frame-lfg-progressbar-border',
		'ui-journeys-progressbar-frame', 'ui-journeys-renown-progressbar-frame', 'activities-bar-border',
		'lootroll-itementry-background', 'looting_itemcard_bg', 'lootroll-timer-border'}
	local verdicts = {} -- art name -> 'hide' | 'relit' | false

	local function Any(name, words)
		for _, word in ipairs(words) do
			if name:find(word, 1, true) then return true end
		end
		return false
	end

	-- The texture's atlas, or the file it was set from; nil for file IDs and
	-- anything the client keeps secret.
	ArtName = function(texture)
		if Forbidden(texture) or not texture.GetAtlas then return nil end
		local ok, atlas = pcall(texture.GetAtlas, texture)
		if ok and not IsSecret(atlas) and type(atlas) == 'string' and atlas ~= '' then return atlas:lower() end
		if texture.GetTextureFilePath then
			local okPath, path = pcall(texture.GetTextureFilePath, texture)
			if okPath and not IsSecret(path) and type(path) == 'string' and path ~= '' then
				return (path:lower():gsub('/', '\\'))
			end
		end
		return nil
	end

	ArtVerdict = function(name)
		if not name then return false end
		local verdict = verdicts[name]
		if verdict == nil then
			-- Icons, masks and bar fills are content, whatever family they belong to.
			if name:find('\\icons\\', 1, true) or name:find('mask', 1, true) or name:find('fill', 1, true) then verdict = false
			elseif Any(name, RELIT) then verdict = 'relit'
			elseif Any(name, ORNATE) then verdict = 'hide'
			else verdict = false end
			verdicts[name] = verdict
		end
		return verdict
	end

	-- A highlight or selection glow becomes a faint white lift. Its color, which
	-- some lists set per row, only shades the gray.
	local relit = setmetatable({}, {__mode = 'k'})
	Relit = function(texture)
		if relit[texture] then return end
		relit[texture] = true
		if texture.SetDesaturated then texture:SetDesaturated(true) end
		texture:SetAlpha(0.3)
	end

	-- Hide or relight one frame's ornate regions. keep: regions left as they are.
	Ornaments = function(frame, keep)
		if Forbidden(frame) or not frame.GetRegions then return end
		for _, region in ipairs({frame:GetRegions()}) do
			if Is(region, 'Texture') and not own[region] and not (keep and keep[region]) then
				local verdict = ArtVerdict(ArtName(region))
				if verdict == 'hide' and region:GetDrawLayer() == 'HIGHLIGHT' then verdict = 'relit' end
				if verdict == 'hide' then region:SetAlpha(0) elseif verdict == 'relit' then Relit(region) end
			end
		end
	end
end

-- Stripping art ---------------------------------------------------------------
local NineSlicePanel, Unbackdrop, Keep, Strip, Decor, Inset
local screened = setmetatable({}, {__mode = 'k'}) -- frames sitting on a black screen of ours
do
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
	-- A backdrop (BackdropTemplate or a nine-slice panel) loses its nine pieces
	-- only: such frames may hold content of their own.
	local BACKDROP = {'TopLeftCorner', 'TopRightCorner', 'BottomLeftCorner', 'BottomRightCorner', 'TopEdge', 'BottomEdge',
		'LeftEdge', 'RightEdge', 'Center'}
	local DECOR_LAYERS = {BACKGROUND = true, BORDER = true}

	NineSlicePanel = function(frame)
		return not Forbidden(frame) and frame.GetObjectType and frame.TopLeftCorner and frame.Center and true or false
	end

	Unbackdrop = function(frame)
		for _, key in ipairs(BACKDROP) do
			local piece = frame[key]
			if Is(piece, 'Texture') then piece:SetAlpha(0) end
		end
	end

	Keep = function(frame)
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
	Strip = function(frame)
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

	-- Inside a window: ornate art goes wherever it sits, glows are relit, and big
	-- background art (parchment, page backgrounds, tree art, row backdrops) goes;
	-- icons and the rest of the artwork layers stay.
	Decor = function(frame)
		if not First('decor', frame) then return end
		local keep = Keep(frame)
		for _, region in ipairs({frame:GetRegions()}) do
			if Is(region, 'Texture') and not keep[region] and not own[region] then
				local layer = region:GetDrawLayer()
				local verdict = ArtVerdict(ArtName(region))
				if verdict == 'hide' and layer == 'HIGHLIGHT' then verdict = 'relit' end
				if verdict == 'hide' then region:SetAlpha(0)
				elseif verdict == 'relit' then Relit(region)
				elseif DECOR_LAYERS[layer] then
					local width, height = Size(region)
					if max(width, height) >= 96 then region:SetAlpha(0) end
				end
			end
		end
	end

	-- Insets and list areas: black screens.
	Inset = function(frame)
		if Forbidden(frame) or own[frame] or not frame.GetRegions or not First('inset', frame) then return end
		Strip(frame)
		Hide(frame.NineSlice)
		Own(Kit:Shell(frame, {surface = 'screen', radius = 6, shadow = false}))
		screened[frame] = true
	end
end

-- Keys -----------------------------------------------------------------------------
local HideButtonArt, CapState, Keycap, PushButton, Close, Checkbox, IconGlyph, IconKey
local caps = setmetatable({}, {__mode = 'k'})
do
	local BUTTON_ART = {'GetNormalTexture', 'GetPushedTexture', 'GetHighlightTexture', 'GetDisabledTexture'}
	HideButtonArt = function(button)
		for _, getter in ipairs(BUTTON_ART) do
			if button[getter] then Hide(button[getter](button)) end
		end
	end

	-- A keycap from the reference's own art behind a Blizzard button: the charcoal
	-- cap for most buttons, the light key for a window's main action. It goes down
	-- (the captured pressed art) while held, lifts a little under the cursor and
	-- fades when the button is disabled.
	CapState = function(cap, state)
		Kit:SetSprite(cap.skin, state == 'down' and cap.down or cap.up)
		cap.lift:SetAlpha(state == 'hover' and 1 or 0)
	end

	Keycap = function(button, primary, corner)
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
	PushButton = function(button)
		if not First('push', button) then return end
		for _, part in ipairs(PUSH_PARTS) do Hide(button[part]) end
		local name = NameOf(button)
		if name then
			for _, part in ipairs({'Left', 'Middle', 'Right'}) do Hide(_G[name..part]) end
		end
		-- Glows and gold leftovers of the old panel buttons (first: the button's
		-- own state art is hidden after, so none of it is relit).
		Ornaments(button)
		HideButtonArt(button)
		local primary = Primary(button)
		Keycap(button, primary)
		if primary then
			SetFonts(button, fonts.ink, fonts.inkHot, fonts.inkDim)
		else
			SetFonts(button, fonts.key, fonts.keyHot, fonts.keyDim)
		end
	end

	-- Close buttons: the reference's round key with an X.
	Close = function(button)
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
	Checkbox = function(button)
		if not First('check', button) then return end
		local width, height = Size(button)
		local side = Kit:Clamp(min(width, height) - 8, 12, 18)
		HideButtonArt(button)
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

	-- Small icon-only buttons (zoom and rotate keys, page arrows, search, filter,
	-- collapse toggles, the gold and red square buttons): a charcoal keycap with a
	-- kit glyph where one says the same thing, else the game's icon relit.
	-- Faces: art that marks a button as one of these.
	local FACES = {'common-button-square', 'ui-squarebutton', 'squarebuttontextures', 'ui-spellbookicon-', 'ui-rotation',
		'ui-refreshbutton', 'ui-plusbutton', 'ui-minusbutton', 'ui-panel-hidebutton', 'ui-panel-minimizebutton',
		'ui-panel-maximizebutton', 'cancelbutton-', 'map-filter-button', 'questlog-icon-setting', 'common-search-clearbutton',
		'ui-linkprofession', 'bags-button-autosort', 'redbutton-', 'dressingroom-button-appearancelist',
		'transmog-button-pullup', 'common-button-list-', 'moneyframe\\arrow-', 'transfer-log-button', 'questcollapse-',
		'socialqueuing-friendlist-summonbutton', 'questsharing-questlog-button', 'common-icon-', 'ui-modelcontrolpanel',
		'dark-goldframe-button', 'ui-scrollbar-scroll', 'profession-button-red'}
	-- Glyphs, first match wins (more specific words first).
	local GLYPHS = {{'zoomin', 'plus'}, {'zoomout', 'minus'}, {'redbutton-expand', 'plus'}, {'redbutton-condense', 'minus'},
		{'redbutton-minicondense', 'minus'}, {'plusbutton', 'plus'}, {'list-plus', 'plus'}, {'minusbutton', 'minus'},
		{'list-minus', 'minus'}, {'maximizebutton', 'plus'}, {'minimizebutton', 'minus'}, {'hidebutton', 'minus'},
		{'prevpage', 'chevron-left'}, {'nextpage', 'chevron-right'}, {'arrow-left', 'chevron-left'},
		{'arrow-right', 'chevron-right'}, {'scrollupbutton', 'chevron-up'}, {'scrolldownbutton', 'chevron-down'},
		{'scrollleftbutton', 'chevron-left'}, {'scrollrightbutton', 'chevron-right'}, {'questcollapse-show', 'chevron-right'},
		{'questcollapse-hide', 'chevron-left'}, {'pullup', 'chevron-up'}, {'rotationleft', 'tri-left'},
		{'rotationright', 'tri-right'}, {'redbutton-exit', 'close'}, {'cancelbutton', 'close'}, {'clearbutton', 'close'},
		{'redx', 'close'}, {'crossmark', 'close'}, {'magnif', 'search'}, {'icon-search', 'search'}, {'filter', 'filter'},
		{'setting', 'more'}, {'autosort', 'grip'}, {'trash', 'trash'}, {'invitemail', 'mail'}, {'summonbutton', 'user'}}
	local glyphs, faces = {}, {}

	local function GlyphOf(name)
		if not name then return nil end
		local hit = glyphs[name]
		if hit == nil then
			hit = false
			if not name:find('\\icons\\', 1, true) then
				for _, pair in ipairs(GLYPHS) do
					if name:find(pair[1], 1, true) then hit = pair[2] break end
				end
			end
			glyphs[name] = hit
		end
		return hit or nil
	end

	local function IsFace(name)
		if not name then return false end
		local hit = faces[name]
		if hit == nil then
			hit = false
			for _, word in ipairs(FACES) do
				if name:find(word, 1, true) then hit = true break end
			end
			faces[name] = hit
		end
		return hit
	end

	-- glyph (a kit icon name), false (relight the art) or nil (not an icon
	-- button); and the texture that carries the game's icon.
	IconGlyph = function(button)
		local width, height = Size(button)
		if width < 12 or height < 12 or width > 44 or height > 44 then return nil end
		if width > height * 1.7 or height > width * 1.7 then return nil end
		if button.GetText then
			local ok, text = pcall(button.GetText, button)
			if ok and not IsSecret(text) and type(text) == 'string' and text ~= '' then return nil end
		end
		local normal = button.GetNormalTexture and button:GetNormalTexture()
		if not Is(normal, 'Texture') then normal = nil end
		local icon = button.Icon or button.icon
		if not Is(icon, 'Texture') then icon = nil end
		local normalName, iconName = normal and ArtName(normal), icon and ArtName(icon)
		if not IsFace(normalName) and not IsFace(iconName) then return nil end
		local glyph = GlyphOf(iconName) or GlyphOf(normalName)
		if glyph then return glyph, icon end
		return false, icon or normal
	end

	IconKey = function(button, glyph, art)
		if not First('iconkey', button) then return end
		Ornaments(button, art and {[art] = true} or nil)
		HideButtonArt(button)
		local width, height = Size(button)
		local side = Kit:Clamp(floor(min(width, height) - 6 + 0.5), 14, 26)
		local cap = Keycap(button, false, 5)
		cap:ClearAllPoints()
		cap:SetPoint('CENTER')
		cap:SetSize(side, side)
		if glyph then
			if Is(art, 'Texture') then Hide(art) end
			cap.glyph = Own(Kit:Icon(cap, glyph, side >= 20 and 10 or 8, 'darkInk'))
			cap.glyph:SetPoint('CENTER')
		elseif Is(art, 'Texture') then
			-- No glyph says it: the game's own icon, relit monochrome.
			art:SetAlpha(1)
			if art.SetDesaturated then art:SetDesaturated(true) end
			Kit:Tint(art, 'darkInk')
		end
	end
end

-- Tabs ---------------------------------------------------------------------------------
-- Segmented keys. The selected tab is raised and light, the rest charcoal.
local PaintTab, RepaintTabs, Tab, SideTab
local tabs = setmetatable({}, {__mode = 'k'}) -- tab -> our key frame
do
	local TAB_PARTS = {'Left', 'Middle', 'Right', 'LeftActive', 'MiddleActive', 'RightActive', 'LeftHighlight',
		'MiddleHighlight', 'RightHighlight', 'LeftDisabled', 'MiddleDisabled', 'RightDisabled', 'Selected', 'SelectedTexture',
		'TabBg', 'Hider', 'Background', 'Border'}

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

	local function SideChosen(tab)
		if Is(tab.SelectedTexture, 'Texture') then return tab.SelectedTexture:IsShown() end
		return TabSelected(tab)
	end

	PaintTab = function(tab)
		local back = tabs[tab]
		if not back then return end
		if back.side then
			-- A side tab: the light key and a lit lamp when chosen, else charcoal
			-- with the icon grayed.
			local on = SideChosen(tab)
			Kit:SetSprite(back.skin, on and 'key' or 'cap')
			Kit:SetLed(back.led, on)
			local icon = tab.Icon
			if Is(icon, 'Texture') then
				icon:SetAlpha(on and 1 or 0.72)
				if icon.SetDesaturated then icon:SetDesaturated(not on) end
			end
			return
		end
		local on = TabSelected(tab)
		-- The reference's segmented control: a recessed track, and the chosen
		-- segment a raised light thumb on it.
		back.thumb:SetShown(on and true or false)
		local text = tab.Text or tab.text or (tab.GetFontString and tab:GetFontString())
		if Is(text, 'FontString') then text:SetTextColor(Kit:RGB(on and 'ink' or 'darkDim')) end
	end

	-- Tab rows the game lays out overlapping (its art has wide transparent ends)
	-- are spread: each key gives up half the overlap on that side.
	local function TabOverlap(tab)
		local ok, point, relative, relativePoint, x = pcall(tab.GetPoint, tab, 1)
		if not ok or IsSecret(point) or IsSecret(relative) or IsSecret(relativePoint) or IsSecret(x) then return nil end
		if type(x) ~= 'number' or x >= 0 or type(point) ~= 'string' or type(relativePoint) ~= 'string' then return nil end
		if type(relative) ~= 'table' or not tabs[relative] or tabs[relative].side then return nil end
		if not point:find('LEFT', 1, true) or not relativePoint:find('RIGHT', 1, true) then return nil end
		return relative, floor(-x / 2 + 0.5)
	end

	local function FitTabs()
		local left, right = {}, {}
		for tab, back in pairs(tabs) do
			if not back.side and tab:IsVisible() then
				local previous, overlap = TabOverlap(tab)
				if previous then
					left[tab] = overlap
					right[previous] = max(right[previous] or 0, overlap)
				end
			end
		end
		for tab, back in pairs(tabs) do
			if not back.side and tab:IsVisible() then
				local l, r = 2 + (left[tab] or 0), 2 + (right[tab] or 0)
				if back.fitL ~= l or back.fitR ~= r then
					back.fitL, back.fitR = l, r
					back:ClearAllPoints()
					back:SetPoint('TOPLEFT', tab, 'TOPLEFT', l, -back.inset)
					back:SetPoint('BOTTOMRIGHT', tab, 'BOTTOMRIGHT', -r, 1)
				end
			end
		end
	end

	local tabsPending = false
	RepaintTabs = function()
		if tabsPending then return end
		tabsPending = true
		C_Timer.After(0, function()
			tabsPending = false
			UI:Safe(FitTabs)
			for tab in pairs(tabs) do
				if tab:IsVisible() then UI:Safe(PaintTab, tab) end
			end
		end)
	end

	local function Clicks(tab)
		local clickScript = tab.HasScript and tab:HasScript('OnClick') and 'OnClick' or 'OnMouseUp'
		tab:HookScript(clickScript, function()
			Sound('tick', 'tab')
			RepaintTabs()
		end)
		tab:HookScript('OnShow', RepaintTabs)
	end

	Tab = function(tab)
		if not First('tab', tab) then return end
		for _, part in ipairs(TAB_PARTS) do
			if Is(tab[part], 'Texture') then tab[part]:SetAlpha(0) end
		end
		local name = NameOf(tab)
		if name then
			for _, part in ipairs(TAB_PARTS) do Hide(_G[name..part]) end
		end
		HideButtonArt(tab)
		-- Bottom tabs carry art padding; the key sits on their visible part.
		local _, height = Size(tab)
		local inset = height > 28 and 4 or 1
		local back = Back(tab, {surface = 'glass', radius = 6, shadow = false}, -2, -inset, -2, -1)
		back.inset, back.fitL, back.fitR = inset, 2, 2
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
			SetFonts(tab, fonts.tabOff, fonts.tabHot, fonts.tabOn)
		end
		Clicks(tab)
		PaintTab(tab)
		RepaintTabs()
	end

	-- Big icon tabs on a window's edge (LargeSideTabButtonTemplate: the quest
	-- log's, and on Forever the collections', professions', bank's and others'):
	-- the game's tab art goes and a key sits around the icon.
	SideTab = function(tab)
		if Forbidden(tab) or not Is(tab.Icon, 'Texture') or not First('sidetab', tab) then return end
		for _, key in ipairs({'Background', 'SelectedTexture', 'HighlightTexture', 'TabGlow'}) do Hide(tab[key]) end
		-- Around the icon, whatever size the owner gives it (some fill the tab).
		local key = Own(CreateFrame('Frame', nil, tab))
		key:SetPoint('TOPLEFT', tab.Icon, 'TOPLEFT', -4, 4)
		key:SetPoint('BOTTOMRIGHT', tab.Icon, 'BOTTOMRIGHT', 4, -4)
		key:SetFrameLevel(max(tab:GetFrameLevel() - 1, 0))
		key:EnableMouse(false)
		key.skin = Own(Kit:Skin(key, 'cap', 'BACKGROUND', 0))
		key.skin.kitMaxCorner = 6
		Kit:FitSprite(key.skin, key:GetWidth(), key:GetHeight())
		key.top = Own(CreateFrame('Frame', nil, tab))
		key.top:SetAllPoints(key)
		key.top:SetFrameLevel(tab:GetFrameLevel() + 2)
		key.top:EnableMouse(false)
		key.led = Crisp(Own(Kit:Led(key.top, 4, false)))
		key.led:SetPoint('TOPLEFT', key, 'TOPLEFT', 3, -3)
		key.side = true
		tabs[tab] = key
		tab:HookScript('OnEnter', function() key.skin:SetAlpha(0.85) end)
		tab:HookScript('OnLeave', function() key.skin:SetAlpha(1) end)
		Clicks(tab)
		-- The owner window checks a tab from its own code too.
		-- (Only the mixin's own method, never a widget method.)
		if type(rawget(tab, 'SetChecked')) == 'function' then hooksecurefunc(tab, 'SetChecked', RepaintTabs) end
		PaintTab(tab)
	end
end

-- Scroll bars, sliders and meters -----------------------------------------------------
local StepButton, ScrollBar, Slider, StatusBar
do
	-- Scroll bars: a thin track, a charcoal thumb, chevrons for the step buttons.
	StepButton = function(button, icon)
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

	ScrollBar = function(bar)
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
		-- Old scroll frames keep the bar's end caps on the frame it scrolls.
		local parent = bar:GetParent()
		if not Forbidden(parent) and parent.GetRegions and not own[parent] then Ornaments(parent) end
	end

	-- Sliders (settings and volume): a glass track and a round thumb.
	Slider = function(slider)
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
			Crisp(thumb)
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
	StatusBar = function(bar)
		if not First('bar', bar) then return end
		local width, height = Size(bar)
		if width < 24 or height <= 0 then return end
		local fill = bar:GetStatusBarTexture()
		for _, region in ipairs({bar:GetRegions()}) do
			if Is(region, 'Texture') and region ~= fill and not own[region] then region:SetAlpha(0) end
		end
		for _, key in ipairs({'Border', 'BorderLeft', 'BorderRight', 'BorderMid', 'BorderCenter', 'Background', 'BarBG', 'BG',
			'Frame', 'BarFrame', 'LeftDivider', 'RightDivider'}) do
			local piece = bar[key]
			if Is(piece, 'Texture') then piece:SetAlpha(0) elseif NineSlicePanel(piece) then Unbackdrop(piece) end
		end
		local name = NameOf(bar)
		if name then Hide(_G[name..'Border']); Hide(_G[name..'Background']) end
		-- Bar art kept on the bar's parent (frames, borders) goes too.
		local parent = bar:GetParent()
		if not Forbidden(parent) and not own[parent] then Ornaments(parent) end
		Back(bar, {surface = 'screen', radius = 4, shadow = false}, 2, 2, 2, 2)
		if height <= 22 and width >= height * 3 then
			Kit:Perforate(bar, 'black', 'darkEdge')
			if bar.kitUnder then own[bar.kitUnder], own[bar.kitCover] = true, true end
		end
	end
end

-- Item and spell slots ---------------------------------------------------------------------
-- A light key behind, the icon cropped, quality as the key's edge.
local IconOf, Quality, Item, FollowQuality, SpellKey
local rings = setmetatable({}, {__mode = 'k'})
-- The game colors an item's border by quality; the key's edge follows it.
-- A slot whose quality is better read from the game (the character window's
-- slots, whose borders are atlases rather than tinted) registers a source:
-- source(button) returns r, g, b, or nil for no quality.
local qualitySources = setmetatable({}, {__mode = 'k'})
do
	IconOf = function(button)
		local name = NameOf(button)
		local icon = button.icon or button.Icon or (name and _G[name..'IconTexture'])
		return Is(icon, 'Texture') and icon or nil
	end

	local function Wide(button)
		local width, height = Size(button)
		return height > 0 and width > height * 1.6
	end

	local function Edge(ring, r, g, b)
		ring:SetVertexColor(r, g, b, 1)
		if ring.led then ring.led:SetVertexColor(r, g, b, 1); ring.led:Show() end
	end

	local function NoEdge(ring)
		local r, g, b = Kit:RGB('darkEdge')
		ring:SetVertexColor(r, g, b, 1)
		if ring.led then ring.led:Hide() end
	end

	Quality = function(button)
		local ring = rings[button]
		if not ring then return end
		local source = qualitySources[button]
		if source then
			local ok, r, g, b = pcall(source, button)
			if ok and r then Edge(ring, r, g, b) else NoEdge(ring) end
			return
		end
		local border = button.IconBorder
		if Is(border, 'Texture') and border:IsShown() then
			local r, g, b = border:GetVertexColor()
			if not IsSecret(r) and not IsSecret(g) and not IsSecret(b) and r and r + g + b < 2.85 then
				Edge(ring, r, g, b)
				return
			end
		end
		NoEdge(ring)
	end

	Item = function(button)
		if Forbidden(button) or not button.CreateTexture or not First('item', button) then return end
		local icon = IconOf(button)
		local name = NameOf(button)
		if button.GetNormalTexture then Hide(button:GetNormalTexture()) end
		for _, key in ipairs({'ItemSlotBackground', 'SlotBackground', 'NameFrame', 'SlotArt', 'EmptyBackground'}) do
			if Is(button[key], 'Texture') then button[key]:SetAlpha(0) end
		end
		if name then
			for _, suffix in ipairs({'NormalTexture', 'NameFrame', 'Frame', 'SlotTexture'}) do Hide(_G[name..suffix]) end
		end
		-- Slot frames, empty-slot art and the gold pushed and highlight art.
		Ornaments(button, icon and {[icon] = true} or nil)
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
		ring.led = Crisp(Own(Kit:Texture(lid, 'circle', 'OVERLAY', 7)))
		ring.led:SetSize(4, 4)
		ring.led:SetPoint('TOPRIGHT', target, 'TOPRIGHT', -2, -2)
		ring.led:Hide()
		rings[button] = ring
		if icon then icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) end
		Hide(button.IconBorder)
		Quality(button)
	end

	FollowQuality = function(button)
		if type(button) == 'table' and rings[button] then
			Hide(button.IconBorder)
			Quality(button)
		end
	end

	-- Spell buttons (the spellbook's, talent choices with an icon frame): the
	-- same key, their ornate icon frames, shadows and sheens gone.
	SpellKey = function(button)
		Item(button)
		for _, key in ipairs({'Border', 'BorderShadow', 'BorderSheen', 'TrainableShadow', 'TrainableBackplate',
			'IconOverlay'}) do
			if Is(button[key], 'Texture') then button[key]:SetAlpha(0) end
		end
	end
end

-- Fields and small parts ------------------------------------------------------------------
local EditBox, Dropdown, Money, DialogHeader
do
	-- Edit and search boxes: black glass.
	EditBox = function(box)
		if not First('edit', box) then return end
		local name = NameOf(box)
		for _, part in ipairs({'Left', 'Right', 'Middle', 'Mid', 'FocusLeft', 'FocusRight', 'FocusMid', 'Background'}) do
			Hide(box[part])
			if name then Hide(_G[name..part]) end
		end
		Hide(box.NineSlice)
		Ornaments(box, {[box.searchIcon or box] = true})
		local field = Back(box, {surface = 'glass', radius = 5, shadow = false}, 5, 1, 1, 1)
		box:HookScript('OnEditFocusGained', function() field.shell.opts.edge = 'darkDim'; Kit:PaintShell(field.shell) end)
		box:HookScript('OnEditFocusLost', function() field.shell.opts.edge = nil; Kit:PaintShell(field.shell) end)
		if Is(box.searchIcon, 'Texture') then Kit:Tint(box.searchIcon, 'darkDim') end
		if Is(box.Instructions, 'FontString') then Kit:Tint(box.Instructions, 'darkDim') end
		local clear = box.clearButton or box.ClearButton
		if Is(clear, 'Button') and First('editclear', clear) then
			HideButtonArt(clear)
			Hide(clear.texture)
			local mark = Own(Kit:Icon(clear, 'close', 8, 'darkDim'))
			mark:SetPoint('CENTER')
		end
	end

	-- Dropdowns (WowStyle1Dropdown, filter dropdowns): a keycap with a chevron.
	Dropdown = function(dropdown)
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
	Money = function(frame)
		if not First('money', frame) then return end
		local name = NameOf(frame)
		for _, key in ipairs({'GoldButton', 'SilverButton', 'CopperButton'}) do
			local button = frame[key] or (name and _G[name..key])
			local text = not Forbidden(button) and button.GetFontString and button:GetFontString()
			if Is(text, 'FontString') then Kit:Font(text, 10, nil, true) end
		end
		Ornaments(frame)
	end

	-- Dialog headers (the game menu's, settings dialogs'): art off, text in ink.
	DialogHeader = function(header)
		if Forbidden(header) or not header.GetRegions or not First('header', header) then return end
		Strip(header)
		for _, key in ipairs({'LeftBG', 'CenterBG', 'RightBG'}) do Hide(header[key]) end
		if Is(header.Text, 'FontString') then
			Kit:Font(header.Text, 10, nil, true)
			Kit:Tint(header.Text, 'darkInk')
		end
	end
end

-- The walk ------------------------------------------------------------------------
local boxes = setmetatable({}, {__mode = 'k'})
local noScreens = setmetatable({}, {__mode = 'k'}) -- windows whose lists another file dresses
local Queue, Classify, Walk, QueueRow, WatchList, WatchPaged
do
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
	QueueRow = function(row)
		if type(row) ~= 'table' then return end
		rowQueue[row] = true
		if not rowsArmed then
			rowsArmed = true
			C_Timer.After(0, FlushRows)
		end
	end

	-- A list not already inside one of our screens gets a black screen of its
	-- own, a few pixels proud of its rows so the gutters are even.
	-- Tried again on later walks while the list has no size yet.
	local unscreened = setmetatable({}, {__mode = 'k'})
	local function ListScreen(box)
		if screened[box] or unscreened[box] then return end
		local parent, depth = box:GetParent(), 0
		while parent and depth < 6 do
			if Forbidden(parent) or screened[parent] or noScreens[parent] then
				unscreened[box] = true
				return
			end
			parent, depth = parent:GetParent(), depth + 1
		end
		local width, height = Size(box)
		local holder = box:GetParent()
		if width < 60 or height < 60 or Forbidden(holder) then return end
		screened[box] = true
		-- On the list's parent (lists clip their children), shown with the list.
		local screen = Own(CreateFrame('Frame', nil, holder))
		screen:SetPoint('TOPLEFT', box, 'TOPLEFT', -3, 3)
		screen:SetPoint('BOTTOMRIGHT', box, 'BOTTOMRIGHT', 3, -3)
		screen:SetFrameLevel(box:GetFrameLevel())
		screen:EnableMouse(false)
		screen.shell = Own(Kit:Shell(screen, {surface = 'screen', radius = 6, shadow = false}))
		screen:SetShown(box:IsShown())
		box:HookScript('OnShow', function() screen:Show() end)
		box:HookScript('OnHide', function() screen:Hide() end)
	end

	local lastScroll = 0
	local lastListWalk = setmetatable({}, {__mode = 'k'})
	WatchList = function(box)
		UI:Safe(ListScreen, box)
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

	-- Paged content (the spellbook, collections pages): walked again whenever a
	-- page is laid out.
	local paged = setmetatable({}, {__mode = 'k'})
	WatchPaged = function(frame)
		if paged[frame] or not frame.RegisterCallback then return end
		paged[frame] = true
		local mixin = _G.PagedContentFrameBaseMixin
		local event = type(mixin) == 'table' and type(mixin.Event) == 'table' and mixin.Event.OnUpdate
		if event then pcall(frame.RegisterCallback, frame, event, function() Queue(frame) end, {}) end
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

	-- LargeSideTabButtonTemplate and its kin: an icon over 'common-sidetab' art.
	local function IsSideTab(frame)
		if not Is(frame.Icon, 'Texture') or not Is(frame.SelectedTexture, 'Texture') or not Is(frame.Background, 'Texture') then
			return false
		end
		local art = ArtName(frame.Background)
		return art ~= nil and art:find('sidetab', 1, true) ~= nil
	end

	-- A spell button: an icon in an ornate icon frame (the spellbook's).
	local function IsSpell(button)
		if not Is(button.Icon, 'Texture') or not Is(button.Border, 'Texture') then return false end
		local art = ArtName(button.Border)
		return art ~= nil and (art:find('iconframe', 1, true) ~= nil or art:find('talents-node', 1, true) ~= nil)
	end

	-- Dress one child by its shape. Returns true to keep walking into it.
	Classify = function(child, kind, inList)
		-- Already a key, slot or tab (here or in a window's own file).
		if caps[child] or rings[child] or tabs[child] then return false end
		if child.SelectedTexture and IsSideTab(child) then SideTab(child) return false end
		if kind == 'Button' or kind == 'CheckButton' then
			local name = NameOf(child)
			if child.IconBorder then Item(child) return false end
			if child.Border and IsSpell(child) then SpellKey(child) return false end
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
			local glyph, art = IconGlyph(child)
			if glyph ~= nil then IconKey(child, glyph, art) return false end
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
		if child.DisplayViewsForCurrentPage and child.RegisterCallback then WatchPaged(child) end
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
				else
					-- A model's camera keys (zoom, rotate, reset) sit on the model itself.
					local control = child.ControlFrame or child.ModelSceneControls
					if type(control) == 'table' and not own[control] and not Forbidden(control) and control.GetChildren then
						Walk(control, depth + 1, inList)
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
end

-- Windows ----------------------------------------------------------------------------
local housings = setmetatable({}, {__mode = 'k'}) -- window -> our housing shell
local Opened, Window
do
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
		head.lamp = Crisp(Own(Kit:Led(head, 5, true)))
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

	Opened = function(frame, info)
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

	Window = function(frame, info)
		if Forbidden(frame) or not frame.GetChildren then return end
		info = info or {}
		if First('window', frame) then
			if info.screens == false then noScreens[frame] = true end
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
end
UI.SkinWindow = Window

-- Per-window touches the walk can't find on its own -------------------------------------
local WINDOWS
do
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
		-- The map's own frame art, outside the canvas.
		local border = frame.BorderFrame
		if type(border) == 'table' and not Forbidden(border) then
			Hide(border.InsetBorderTop)
			Ornaments(border)
		end
	end

	-- The flight map (TaxiFrame): the window strip hid the map picture itself,
	-- leaving the nodes on a blank housing. The map and the route canvas stay
	-- as the game draws them, and the walk never enters the route canvas.
	local function TaxiPack(frame)
		for _, map in ipairs({_G.TaxiMap, frame.TaxiMap, frame.Map, frame.map}) do
			if Is(map, 'Texture') then
				map:SetAlpha(1)
				Own(map)
			end
		end
		for _, canvas in ipairs({_G.TaxiRouteMap, frame.TaxiRouteMap}) do
			if type(canvas) == 'table' and not Forbidden(canvas) then skip[canvas] = true end
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
			Hide(talents.BottomBar)
		end
		local spells = frame.SpellBookFrame
		if type(spells) == 'table' then
			for _, key in ipairs({'BookBGLeft', 'BookBGRight', 'BookBGHalved', 'BookCornerFlipbook', 'Bookmark'}) do Hide(spells[key]) end
			local pages = spells.PagedSpellsFrame
			if type(pages) == 'table' and not Forbidden(pages) then WatchPaged(pages) end
		end
		local specs = frame.SpecFrame
		if type(specs) == 'table' then
			Hide(specs.Background)
			Hide(specs.BlackBG)
		end
	end

	-- The quest giver's portrait beside the window: a black display.
	local function QuestPack()
		local scene = _G.QuestModelScene
		if type(scene) ~= 'table' or Forbidden(scene) then return end
		for _, key in ipairs({'ModelBackground', 'ModelNameDivider', 'ShadowOverlay', 'ModelNameBackground', 'Border',
			'TopBarBg'}) do Hide(scene[key]) end
		local text = scene.ModelTextFrame
		if type(text) == 'table' then Hide(text.TextBackground) end
		if First('questscene', scene) then Back(scene, {surface = 'screen', radius = 6, shadow = false}, 2, 2, 2, 2) end
	end

	-- The group finder's category cards: glass plates; the chosen one keeps the
	-- game's highlight, relit.
	local function FinderPack()
		local finder = _G.GroupFinderFrame
		if type(finder) ~= 'table' or Forbidden(finder) then return end
		for index = 1, 4 do
			local card = finder['groupButton'..index]
			if type(card) == 'table' and not Forbidden(card) and First('findercard', card) then
				Hide(card.bg)
				Hide(card.ring)
				Back(card, {surface = 'glass', radius = 6, shadow = false}, -2, -2, -2, -2)
			end
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
	-- picked up when their addon loads. Names checked against both clients'
	-- interface source (Retail 12.1.5 and Forever 1.60.1); every entry is
	-- guarded by existence.
	WINDOWS = {
		{'CharacterFrame', 'CH-1', after = CharacterPack, screens = false}, {'PlayerSpellsFrame', 'SP-1', after = TalentPack},
		{'ProfessionsFrame', 'PR-1'}, {'ProfessionsBookFrame', 'PR-2'}, {'ProfessionsCustomerOrdersFrame', 'PR-3'},
		{'CollectionsJournal', 'CL-1'}, {'TransmogFrame', 'CL-3'}, {'EncounterJournal', 'EJ-1'},
		{'AchievementFrame', 'AC-1'}, {'WorldMapFrame', 'MP-1', radius = 8, after = MapPack},
		{'FlightMapFrame', 'MP-2', radius = 8, after = MapPack}, {'BattlefieldMapFrame', 'MP-3', radius = 8, after = MapPack},
		{'QuestFrame', 'QS-1', after = QuestPack}, {'QuestLogPopupDetailFrame', 'QS-2'}, {'GossipFrame', 'GS-1'},
		{'MerchantFrame', 'MR-1'}, {'MailFrame', 'ML-1'}, {'OpenMailFrame', 'ML-2'}, {'BankFrame', 'BK-1'},
		{'GuildBankFrame', 'BK-2'}, {'GuildBankPopupFrame', 'BK-3'}, {'ContainerFrameCombinedBags', 'BG-0'},
		{'TradeFrame', 'TR-1'}, {'AuctionHouseFrame', 'AH-1'}, {'BlackMarketFrame', 'AH-2'}, {'FriendsFrame', 'FR-1'},
		{'CommunitiesFrame', 'CM-1'}, {'PVEFrame', 'GF-1', after = FinderPack}, {'LFGParentFrame', 'GF-1'},
		{'RaidParentFrame', 'RD-1'}, {'GameMenuFrame', 'SY-1', header = false, after = Extra('GameMenuFrame')},
		{'SettingsPanel', 'ST-1', after = Extra('SettingsPanel')},
		{'AddonList', 'AD-1'}, {'MacroFrame', 'MC-1'}, {'MacroPopupFrame', 'MC-2'}, {'ItemTextFrame', 'TX-1'},
		{'TaxiFrame', 'TX-2', after = TaxiPack}, {'ClassTrainerFrame', 'TN-1'}, {'InspectFrame', 'IN-1'}, {'DressUpFrame', 'DR-1'},
		{'TimeManagerFrame', 'TM-1'}, {'StopwatchFrame', 'TM-2', header = false, radius = 6}, {'CalendarFrame', 'CA-1'},
		{'HelpFrame', 'HP-1'}, {'ChatConfigFrame', 'CC-1'}, {'QuickKeybindFrame', 'KB-2'},
		{'EditModeManagerFrame', 'EM-1', after = Extra('EditModeManagerFrame')},
		{'EditModeSystemSettingsDialog', 'EM-2', header = false, after = Extra('EditModeSystemSettingsDialog')},
		{'PetitionFrame', 'PT-1'}, {'TabardFrame', 'TB-1'}, {'GuildRegistrarFrame', 'GR-1'}, {'StableFrame', 'SB-1'},
		{'PetStableFrame', 'SB-1'}, {'ItemSocketingFrame', 'SK-1'}, {'ItemUpgradeFrame', 'UP-1'}, {'ItemInteractionFrame', 'II-1'},
		{'ScrappingMachineFrame', 'SC-1'}, {'WeeklyRewardsFrame', 'WR-1'}, {'ArchaeologyFrame', 'AR-1'},
		{'ChannelFrame', 'CN-1'}, {'ClickBindingFrame', 'CB-1'}, {'GuildControlUI', 'GC-1'}, {'DeathRecapFrame', 'DR-2'},
		{'GroupLootHistoryFrame', 'LH-1'},
		{'ColorPickerFrame', 'CP-1', header = false}, {'LFGDungeonReadyDialog', 'GF-2', header = false},
		{'LFGDungeonReadyStatus', 'GF-2', header = false, quiet = true}, {'LFGListInviteDialog', 'GF-3', header = false},
		{'LFGListApplicationDialog', 'GF-3', header = false}, {'ReadyCheckListenerFrame', 'RC-1', header = false},
		{'RolePollPopup', 'RC-2', header = false}, {'CooldownViewerSettings', 'CD-1'}, {'CurrencyTransferMenu', 'CU-1'},
		{'TokenFramePopup', 'CU-2', header = false}, {'GearManagerPopupFrame', 'EQ-1'},
		{'LossOfControlFrame', 'LC-1', header = false, ownFade = true, quiet = true, after = LossOfControlPack},
	}
	for index = 1, 4 do WINDOWS[#WINDOWS + 1] = {'StaticPopup'..index, 'AL-'..index, header = false} end
	for index = 1, 13 do WINDOWS[#WINDOWS + 1] = {'ContainerFrame'..index, 'BG-'..index} end
end

-- Frames the notifications module dresses; the generic catch-all leaves them be.
local NOT_MINE = {LootFrame = true, GroupLootContainer = true, AlertFrame = true, LevelUpDisplay = true,
	ZoneTextFrame = true, SubZoneTextFrame = true, BossBanner = true, EventToastManagerFrame = true}
for index = 1, 4 do NOT_MINE['GroupLootFrame'..index] = true end

-- With the bags module on, Blizzard's bag and bank windows are parked and
-- never seen, so they are left alone.
local BagsOwned
do
	local OWN_BAGS = {ContainerFrameCombinedBags = true, BankFrame = true}
	for index = 1, 13 do OWN_BAGS['ContainerFrame'..index] = true end
	BagsOwned = function(name)
		local bags = UI.modules.bags
		return name and OWN_BAGS[name] and bags and UI:ModuleEnabled('bags') and not bags.problem and true or false
	end
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
local Quest = {}
do
	Quest.Title = function(fontString)
		if Is(fontString, 'FontString') then fontString:SetTextColor(Kit:RGB('darkInk')) end
	end
	Quest.Text = function(fontString)
		if Is(fontString, 'FontString') then fontString:SetTextColor(LIGHT[1], LIGHT[2], LIGHT[3]) end
	end
	Quest.Relight = function()
		for _, name in ipairs({'QuestInfoFrame', 'QuestInfoRewardsFrame', 'QuestDetailScrollChildFrame', 'QuestRewardScrollChildFrame',
			'QuestProgressScrollChildFrame', 'QuestGreetingScrollChildFrame', 'QuestMapFrame'}) do
			local frame = _G[name]
			if type(frame) == 'table' and not Forbidden(frame) and frame:IsVisible() then RelightAll(frame, 0) end
		end
		for _, name in ipairs({'QuestInfoTitleHeader', 'QuestInfoDescriptionHeader', 'QuestInfoObjectivesHeader',
			'QuestProgressTitleText', 'QuestInfoSpellObjectiveLearnLabel'}) do
			Quest.Title(_G[name])
		end
		local rewards = _G.QuestInfoRewardsFrame
		if type(rewards) == 'table' then
			Quest.Title(rewards.Header)
			Queue(rewards)
		end
		local mapRewards = _G.MapQuestInfoRewardsFrame
		if type(mapRewards) == 'table' then Queue(mapRewards) end
	end
end

-- Menus, old dropdown lists, timers and messages -----------------------------------
local Menus = {}
do
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
	Menus.Hook = function()
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
	Menus.Lists = function()
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
	Menus.MirrorTimers = function()
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
	Menus.Messages = function()
		local errors = _G.UIErrorsFrame
		if type(errors) == 'table' and errors.SetFont then errors:SetFont(Kit:FontPath(true), 14, 'OUTLINE') end
		for _, name in ipairs({'RaidWarningFrameSlot1', 'RaidWarningFrameSlot2', 'RaidBossEmoteFrameSlot1', 'RaidBossEmoteFrameSlot2'}) do
			if Is(_G[name], 'FontString') then Kit:Font(_G[name], 18, 'OUTLINE', true) end
		end
	end
end

-- Walks asked for by events and refreshes: at most one per window every 0.25 s,
-- with one trailing walk so the last change is always seen.
local Debounced
do
	local lastEventWalk = setmetatable({}, {__mode = 'k'})
	local trailing = setmetatable({}, {__mode = 'k'})
	Debounced = function(frame)
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
end

local EVENT_FRAMES
do
	local bags = {'ContainerFrameCombinedBags', 'BankFrame'}
	for index = 1, 13 do bags[#bags + 1] = 'ContainerFrame'..index end
	EVENT_FRAMES = {BAG_UPDATE_DELAYED = bags, BANKFRAME_OPENED = {'BankFrame'}, MERCHANT_UPDATE = {'MerchantFrame'},
		MAIL_INBOX_UPDATE = {'MailFrame', 'OpenMailFrame'}, TRAINER_UPDATE = {'ClassTrainerFrame'},
		GUILDBANKBAGSLOTS_CHANGED = {'GuildBankFrame'},
		LOOT_HISTORY_UPDATE_DROP = {'GroupLootHistoryFrame'}}
end

function module:Enable()
	WatchAll()
	Menus.Hook()
	UI:Safe(Menus.Lists)
	UI:Safe(Menus.Messages)
	local driver = CreateFrame('Frame')
	driver:RegisterEvent('ADDON_LOADED')
	driver:RegisterEvent('PLAYER_ENTERING_WORLD')
	driver:RegisterEvent('MIRROR_TIMER_START')
	for event in pairs(EVENT_FRAMES) do pcall(driver.RegisterEvent, driver, event) end
	driver:SetScript('OnEvent', function(_, event)
		if event == 'ADDON_LOADED' or event == 'PLAYER_ENTERING_WORLD' then
			WatchAll()
			Menus.Hook()
		elseif event == 'MIRROR_TIMER_START' then
			C_Timer.After(0, function() UI:Safe(Menus.MirrorTimers) end)
		else
			-- Contents changed: walk again only the windows the event concerns.
			for _, name in ipairs(EVENT_FRAMES[event] or {}) do
				if not BagsOwned(name) then Debounced(_G[name]) end
			end
		end
	end)
	Menus.MirrorTimers()

	-- Global functions the game calls as windows fill. Post-hooks only.
	local hooks = {
		ShowUIPanel = function(frame) if not Forbidden(frame) and not watched[frame] then Generic(frame) end end,
		SetItemButtonQuality = FollowQuality, SetItemButtonBorder = FollowQuality, SetItemButtonBorderVertexColor = FollowQuality,
		PanelTemplates_SelectTab = RepaintTabs, PanelTemplates_DeselectTab = RepaintTabs, PanelTemplates_SetTab = RepaintTabs,
		PanelTemplates_UpdateTabs = RepaintTabs, PanelTemplates_EnableTab = RepaintTabs, PanelTemplates_DisableTab = RepaintTabs,
		PanelTemplates_AnchorTabs = RepaintTabs, PanelTemplates_ResizeTabsToFit = RepaintTabs,
		QuestFrame_SetTitleTextColor = Quest.Title, QuestFrame_SetTextColor = Quest.Text,
		QuestInfo_Display = function() C_Timer.After(0, Quest.Relight) end,
		QuestFrameProgressItems_Update = function() C_Timer.After(0, Quest.Relight) end,
		QuestFrameGreetingPanel_OnShow = function() C_Timer.After(0, Quest.Relight) end,
		QuestLogQuests_Update = function() if type(_G.QuestMapFrame) == 'table' then Queue(_G.QuestMapFrame) end end,
		ContainerFrame_Update = function(frame) if not BagsOwned(NameOf(frame)) then Debounced(frame) end end,
		ContainerFrame_GenerateFrame = function(frame) if not BagsOwned(NameOf(frame)) then Queue(frame) end end,
		BankFrameItemButton_Update = function(button) Item(button) end,
		UIDropDownMenu_CreateFrames = Menus.Lists,
		ToggleDropDownMenu = Menus.Lists,
		-- Static popups fill (and show their item, money and edit parts) as they open.
		StaticPopup_Show = function() for index = 1, 4 do Debounced(_G['StaticPopup'..index]) end end,
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
	-- Side tabs made later (on-demand windows) repaint as their owner checks them.
	local side = _G.SidePanelTabButtonMixin
	if type(side) == 'table' and type(side.SetChecked) == 'function' then
		hooksecurefunc(side, 'SetChecked', function(tab) if tabs[tab] then RepaintTabs() end end)
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
	if module.enabled then UI:Safe(Menus.Messages) end
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
	SetFonts = SetFonts, fonts = fonts,
	Ring = function(button) return rings[button] end,
	Quality = Quality,
	SetQualitySource = function(button, source) qualitySources[button] = source; Quality(button) end,
	Queue = function(frame) Queue(frame) end, QueueRow = QueueRow, WatchList = WatchList,
	Walk = function(frame) Walk(frame, 0, false) end,
	-- Added for the window files: art by name, icon keys, side tabs, screens.
	-- ArtName(texture) -> lowercased atlas or file name, or nil
	-- ArtVerdict(name) -> 'hide' | 'relit' | false
	-- Ornaments(frame [, keep]) hides ornate regions and relights glows
	-- IconKey(button [, glyph]) a charcoal keycap with a kit glyph, or the button's icon relit
	-- SideTab(tab) a key around a big side tab's icon, lit when chosen
	-- Screened(frame) marks a frame as sitting on a black screen of the caller's
	-- (lists inside it get no second screen); Crisp(texture) snaps a small lamp
	ArtName = ArtName, ArtVerdict = ArtVerdict, Ornaments = Ornaments, Relit = Relit, SideTab = SideTab,
	SpellKey = SpellKey, WatchPaged = WatchPaged, Crisp = Crisp,
	IconKey = function(button, glyph)
		if Forbidden(button) or caps[button] then return end
		local found, art = IconGlyph(button)
		IconKey(button, glyph or found or false, art or button.Icon or button.icon)
	end,
	Screened = function(frame) if type(frame) == 'table' then screened[frame] = true end end,
}

-- defaults:begin
UI:RegisterDefaults('skins', {itemLevel = true, slotLegends = true, sideTabs = 'glyphs', modelScreen = true})
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
		{'switch', 'Item levels', 'skins.itemLevel', 'Each equipped item\'s level on an LCD beside its slot, in LCD ink.', since = '0.5.1'},
		{'switch', 'Slot legends', 'skins.slotLegends', 'Empty slots show a printed legend (HEAD, NECK, RNG1...) instead of the game\'s silhouettes.', since = '0.5.1'},
		{'segmented', 'Side tabs', 'skins.sideTabs', items = {{'icons', 'Game icons'}, {'glyphs', 'SPEC-01 glyphs'}},
			note = 'The big tabs on the window\'s right edge: the game\'s icons cropped onto keys, or SPEC-01 glyphs where one fits.', since = '0.5.1'},
		{'switch', 'Model screen', 'skins.modelScreen', 'Your character on a black display with a faint grid and corner marks.', since = '0.5.1'},
	}},
}})
