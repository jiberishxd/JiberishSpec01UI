-- The character window, all the way in (Skins.lua gives it its housing and
-- header, then hands over here):
--   gear slots      light keys with the icon in a window, quality as a lit edge
--                   and a lamp, the item level on an LCD strip, and a printed
--                   legend (HEAD, NECK, RNG1 ...) in an empty slot
--   title           "LEVEL 26 PALADIN" printed in small caps
--   model           a black display with a faint grid, a vignette and corner
--                   marks, its camera keys as small charcoal caps
--   stats           printed legends and LCD-ink values, the game's green and red
--                   kept as the kit's own; category rows as ruled small caps
--   tabs            the pane toggle a key with a chevron; the stats pane's icon
--                   tabs and the big side tabs as keys with a lit lamp on the
--                   chosen one (the game's icons cropped, or SPEC-01 glyphs)
--   panes           reputation, currency, skills, PvP, statistics, titles and
--                   equipment sets: ruled headers, dot meters, cropped icons
--   flyouts         the alt-swap flyout on glass, its items as keys
--
-- Same rules as Skins.lua: post-hooks and HookScript only, our parts in side
-- tables, pooled rows dressed from our own timer after the game is done, and
-- values that may be secret only ever handed to setters.
local _, UI = ...
local Kit = UI.Kit

local module = UI.modules.windows
if not module or not module.parts then return end
local P = module.parts

local CreateFrame, C_Timer, hooksecurefunc = CreateFrame, C_Timer, hooksecurefunc
local floor, max = math.floor, math.max
local type, ipairs, pairs, pcall, tonumber = type, ipairs, pairs, pcall, tonumber

local IsSecret, Is, Hide, Own, First = P.IsSecret, P.Is, P.Hide, P.Own, P.First

local function DB() return UI.db.skins end

-- Small helpers ------------------------------------------------------------------------
-- Uppercase text, leaving the game's escape codes (colors, textures) alone.
local function Upper(text)
	local saved = {}
	local function Mask(code)
		saved[#saved + 1] = code
		return '\1'..#saved..'\2'
	end
	local masked = text:gsub('|c%x%x%x%x%x%x%x%x', Mask):gsub('|r', Mask):gsub('|T.-|t', Mask):gsub('|A.-|a', Mask)
	masked = masked:upper()
	return (masked:gsub('\1(%d+)\2', function(index) return saved[tonumber(index)] end))
end

local function Hex(token)
	local r, g, b = Kit:RGB(token)
	return format('|cff%02x%02x%02x', floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5))
end

-- Hide every texture a frame draws itself, but the ones kept.
local function HideTextures(frame, keep)
	for _, region in ipairs({frame:GetRegions()}) do
		if Is(region, 'Texture') and not (keep and keep[region]) and not P.IsOwn(region) then region:SetAlpha(0) end
	end
end

-- Calls fn once, a frame from now, however often it is asked for.
local function Debounce(fn)
	local armed = false
	return function(...)
		if armed then return end
		armed = true
		local args = {...}
		C_Timer.After(0, function()
			armed = false
			UI:Safe(fn, unpack(args))
		end)
	end
end

-- Pooled rows of a scroll box: dressed after every update and every row init.
local function WatchBox(box, dress)
	if type(box) ~= 'table' or not First('charbox', box) then return end
	local queued = Debounce(function()
		if box.ForEachFrame then pcall(box.ForEachFrame, box, function(row) UI:Safe(dress, row) end) end
	end)
	if type(box.Update) == 'function' then hooksecurefunc(box, 'Update', queued) end
	local util = _G.ScrollUtil
	local add = util and (util.AddInitializedFrameCallback or util.AddAcquiredFrameCallback)
	if add then pcall(add, box, function() queued() end, {}, true) end
	queued()
end

-- Glyphs from the menu atlas (Media/Hardware/icons-menu.tga, 8 x 4).
local MENU_GLYPHS = {character = 0, professions = 3, achievements = 4, quest = 6, guild = 7, social = 8, journal = 10,
	collections = 11, map = 16, pvp = 17, backpack = 18}
local function SetGlyph(texture, name)
	local index = MENU_GLYPHS[name] or 0
	local column, row = index % 8, floor(index / 8)
	texture:SetTexture(Kit.media..'icons-menu.tga')
	texture:SetTexCoord(column / 8, (column + 1) / 8, row / 4, (row + 1) / 4)
end

-- Gear slots -----------------------------------------------------------------------------
local SLOTS = {
	{'Head', 'HEAD'}, {'Neck', 'NECK'}, {'Shoulder', 'SHLD'}, {'Back', 'BACK'}, {'Chest', 'CHST'}, {'Shirt', 'SHRT', true},
	{'Tabard', 'TABD', true}, {'Wrist', 'WRST'}, {'Hands', 'HNDS'}, {'Waist', 'WAST'}, {'Legs', 'LEGS'}, {'Feet', 'FEET'},
	{'Finger0', 'RNG1'}, {'Finger1', 'RNG2'}, {'Trinket0', 'TRK1'}, {'Trinket1', 'TRK2'}, {'MainHand', 'MH'},
	{'SecondaryHand', 'OH'}, {'Ranged', 'RNGD'}, {'Ammo', 'AMMO', true},
}
local slots = setmetatable({}, {__mode = 'k'}) -- slot button -> {legend, plate, level, noLevel}

local function QualityColor(quality)
	if type(quality) ~= 'number' or quality < 2 then return nil end
	if C_Item and C_Item.GetItemQualityColor then
		local ok, r, g, b = pcall(C_Item.GetItemQualityColor, quality)
		if ok and type(r) == 'number' then return r, g, b end
	end
	local color = _G.ITEM_QUALITY_COLORS and _G.ITEM_QUALITY_COLORS[quality]
	if color then return color.r, color.g, color.b end
end

local function SlotQuality(button)
	local id = button:GetID()
	if IsSecret(id) or type(id) ~= 'number' then return nil end
	local quality = GetInventoryItemQuality('player', id)
	if IsSecret(quality) then return nil end
	return QualityColor(quality)
end

local function ItemLevel(id)
	local link = GetInventoryItemLink('player', id)
	if IsSecret(link) then return nil end
	if type(link) ~= 'string' then return nil end
	local info = C_Item and C_Item.GetDetailedItemLevelInfo or _G.GetDetailedItemLevelInfo
	if not info then return nil end
	local ok, level = pcall(info, link)
	if not ok then return nil end
	return level
end

local function UpdateSlot(button)
	local parts = slots[button]
	if not parts then return end
	local db = DB()
	local id = button:GetID()
	if IsSecret(id) or type(id) ~= 'number' then return end
	local texture = GetInventoryItemTexture('player', id)
	local empty = not IsSecret(texture) and texture == nil
	local icon = P.IconOf(button)
	local legends = db.slotLegends and true or false
	if icon then icon:SetAlpha((empty and legends) and 0 or 1) end
	parts.legend:SetShown(empty and legends)
	-- Item level on the LCD strip, in the item's quality color.
	local level = (db.itemLevel and not empty and not parts.noLevel) and ItemLevel(id) or nil
	if IsSecret(level) then
		parts.level:SetFormattedText('%d', level)
		parts.plate:Show()
	elseif type(level) == 'number' and level > 1 then
		parts.level:SetText(floor(level))
		parts.plate:Show()
	else
		parts.plate:Hide()
	end
	local r, g, b = SlotQuality(button)
	if r then parts.level:SetTextColor(r, g, b) else parts.level:SetTextColor(Kit:RGB('lcdInk')) end
	P.Quality(button)
end

local function DressSlot(button, legend, noLevel)
	if P.Forbidden(button) or not button.CreateTexture then return end
	if not First('charslot', button) then return end
	local icon = P.IconOf(button)
	local keep = {}
	if icon then keep[icon] = true end
	if Is(button.ignoreTexture, 'Texture') then keep[button.ignoreTexture] = true end
	local highlight = button.GetHighlightTexture and button:GetHighlightTexture()
	if Is(highlight, 'Texture') then keep[highlight] = true end
	HideTextures(button, keep)
	Hide(button.IconBorder)
	Hide(button.IconOverlay)
	Hide(button.IconOverlay2)
	P.Item(button)
	if Is(highlight, 'Texture') and icon and not P.Locked(button) then
		highlight:SetColorTexture(1, 1, 1, 0.14)
		highlight:ClearAllPoints()
		highlight:SetAllPoints(icon)
	end
	local top = Own(CreateFrame('Frame', nil, button))
	top:SetAllPoints(icon or button)
	top:SetFrameLevel(button:GetFrameLevel() + 3)
	top:EnableMouse(false)
	local parts = {noLevel = noLevel}
	parts.legend = Own(Kit:Label(top, legend, 'dim', 7, true))
	parts.legend:SetPoint('CENTER', 0, 0)
	parts.plate = Own(CreateFrame('Frame', nil, top))
	parts.plate:SetPoint('BOTTOMLEFT', 1, 1)
	parts.plate:SetPoint('BOTTOMRIGHT', -1, 1)
	parts.plate:SetHeight(10)
	parts.plate.fill = Own(parts.plate:CreateTexture(nil, 'BACKGROUND'))
	parts.plate.fill:SetAllPoints()
	parts.plate.fill:SetColorTexture(1, 1, 1, 1)
	Kit:Tint(parts.plate.fill, 'lcd', 0.88)
	parts.level = Own(parts.plate:CreateFontString(nil, 'OVERLAY'))
	Kit:Font(parts.level, 8, nil, true, 'numbers')
	parts.level:SetPoint('CENTER', 0, 0)
	parts.plate:Hide()
	slots[button] = parts
	P.SetQualitySource(button, SlotQuality)
	UpdateSlot(button)
end

local function UpdateAllSlots()
	for button in pairs(slots) do UI:Safe(UpdateSlot, button) end
end

-- The model's display ----------------------------------------------------------------------
local screen
local function HideSceneArt(scene)
	for _, region in ipairs({scene:GetRegions()}) do
		if Is(region, 'Texture') and not P.IsOwn(region) then region:SetAlpha(0) end
	end
end

local function Grid(frame)
	frame.lines = frame.lines or {}
	for _, line in ipairs(frame.lines) do line:Hide() end
	local width, height = P.Size(frame)
	if width <= 0 or height <= 0 then return end
	local px, step, index = UI.Pixel.Px(frame, 1), 16, 0
	local function Line(vertical, offset)
		index = index + 1
		local line = frame.lines[index]
		if not line then
			line = Own(frame:CreateTexture(nil, 'BORDER'))
			line:SetColorTexture(1, 1, 1, 1)
			frame.lines[index] = line
		end
		line:ClearAllPoints()
		if vertical then
			line:SetPoint('TOPLEFT', frame, 'TOPLEFT', offset, 0)
			line:SetPoint('BOTTOMLEFT', frame, 'BOTTOMLEFT', offset, 0)
			line:SetWidth(px)
		else
			line:SetPoint('TOPLEFT', frame, 'TOPLEFT', 0, -offset)
			line:SetPoint('TOPRIGHT', frame, 'TOPRIGHT', 0, -offset)
			line:SetHeight(px)
		end
		line:SetVertexColor(1, 1, 1, 0.04)
		line:Show()
	end
	for x = step, width - 1, step do Line(true, UI.Pixel.Snap(frame, x)) end
	for y = step, height - 1, step do Line(false, UI.Pixel.Snap(frame, y)) end
end

local function Corner(frame, point, sx, sy)
	local arm, px = 10, UI.Pixel.Px(frame, 2)
	local across = Own(frame:CreateTexture(nil, 'ARTWORK'))
	local down = Own(frame:CreateTexture(nil, 'ARTWORK'))
	for _, piece in ipairs({across, down}) do
		piece:SetColorTexture(1, 1, 1, 1)
		Kit:Tint(piece, 'darkDim', 0.8)
		piece:SetPoint(point, frame, point, sx * 6, sy * 6)
	end
	across:SetSize(arm, px)
	down:SetSize(px, arm)
end

local function ModelScreen(scene)
	if screen or type(scene) ~= 'table' or P.Forbidden(scene) then return end
	HideSceneArt(scene)
	scene:HookScript('OnShow', function(self) UI:Safe(HideSceneArt, self) end)
	local parent = scene:GetParent() or scene
	screen = Own(CreateFrame('Frame', nil, parent))
	local head, trinket = _G.CharacterHeadSlot, _G.CharacterTrinket1Slot
	if type(head) == 'table' and type(trinket) == 'table' then
		screen:SetPoint('TOPLEFT', head, 'TOPRIGHT', 8, 0)
		screen:SetPoint('BOTTOMRIGHT', trinket, 'BOTTOMLEFT', -8, 0)
	else
		screen:SetAllPoints(scene)
	end
	screen:SetFrameLevel(max(scene:GetFrameLevel() - 1, 0))
	screen:EnableMouse(false)
	screen.shell = Own(Kit:Shell(screen, {surface = 'screen', radius = 6, shadow = false}))
	screen.grid = Own(CreateFrame('Frame', nil, screen))
	screen.grid:SetAllPoints()
	screen.grid:EnableMouse(false)
	screen:HookScript('OnSizeChanged', function() UI:Safe(Grid, screen.grid) end)
	-- A vignette: the top and bottom fall off into black.
	for _, side in ipairs({'TOP', 'BOTTOM'}) do
		local shade = Own(screen.grid:CreateTexture(nil, 'ARTWORK'))
		shade:SetColorTexture(1, 1, 1, 1)
		shade:SetPoint(side..'LEFT')
		shade:SetPoint(side..'RIGHT')
		shade:SetHeight(48)
		local edge, clear = CreateColor(0, 0, 0, 0.55), CreateColor(0, 0, 0, 0)
		if side == 'TOP' then shade:SetGradient('VERTICAL', clear, edge) else shade:SetGradient('VERTICAL', edge, clear) end
	end
	Corner(screen.grid, 'TOPLEFT', 1, -1)
	Corner(screen.grid, 'TOPRIGHT', -1, -1)
	Corner(screen.grid, 'BOTTOMLEFT', 1, 1)
	Corner(screen.grid, 'BOTTOMRIGHT', -1, 1)
	Grid(screen.grid)
	screen:SetShown(DB().modelScreen and true or false)
	-- The camera keys (zoom, rotate, reset).
	local controls = scene.ControlFrame
	if type(controls) == 'table' and not P.Forbidden(controls) then
		P.Strip(controls)
		for _, button in ipairs({controls:GetChildren()}) do
			if Is(button, 'Button') and First('camkey', button) then
				local keep = {}
				if Is(button.Icon, 'Texture') then keep[button.Icon] = true end
				P.HideButtonArt(button)
				HideTextures(button, keep)
				P.Keycap(button, false, 4)
				if Is(button.Icon, 'Texture') then Kit:Tint(button.Icon, 'darkInk') end
			end
		end
	end
end

-- Title ----------------------------------------------------------------------------------------
local upping = false
local function PrintTitle(text)
	if upping or not Is(text, 'FontString') then return end
	local value = text:GetText()
	if IsSecret(value) or type(value) ~= 'string' then return end
	local upper = Upper(value)
	if upper ~= value then
		upping = true
		text:SetText(upper)
		upping = false
	end
end

local function Title(text)
	if not Is(text, 'FontString') or not First('chartitle', text) then return end
	Kit:Font(text, 10, nil, true)
	text:SetTextColor(Kit:RGB('darkInk'))
	text:SetShadowOffset(0, 0)
	hooksecurefunc(text, 'SetText', function(self) UI:Safe(PrintTitle, self) end)
	hooksecurefunc(text, 'SetFormattedText', function(self) UI:Safe(PrintTitle, self) end)
	PrintTitle(text)
end

-- Tabs -----------------------------------------------------------------------------------------
-- A key around an icon: charcoal, or light and lit when chosen.
local tabKeys = setmetatable({}, {__mode = 'k'}) -- tab -> key frame
local selectedOf = setmetatable({}, {__mode = 'k'}) -- tab -> function(tab) -> chosen

local function Chosen(tab)
	local test = selectedOf[tab]
	if test then
		local ok, on = pcall(test, tab)
		if ok and not IsSecret(on) then return on and true or false end
	end
	return false
end

local function PaintTabKey(tab)
	local key = tabKeys[tab]
	if not key then return end
	local on = Chosen(tab)
	Kit:SetSprite(key.skin, on and 'key' or 'cap')
	Kit:SetLed(key.led, on)
	local glyphs = key.glyph and DB().sideTabs == 'glyphs'
	if key.glyph then
		key.glyph:SetShown(glyphs and true or false)
		Kit:Tint(key.glyph, on and 'ink' or 'darkInk')
	end
	if key.icon then
		key.icon:SetAlpha(glyphs and 0 or (on and 1 or 0.72))
		if key.icon.SetDesaturated then key.icon:SetDesaturated(not on and not glyphs) end
	end
end

local RepaintTabKeys = Debounce(function()
	for tab in pairs(tabKeys) do UI:Safe(PaintTabKey, tab) end
end)

local function TabKey(tab, icon, opts)
	if tabKeys[tab] or P.Forbidden(tab) then return tabKeys[tab] end
	local key = Own(CreateFrame('Frame', nil, tab))
	local pad = opts.pad or 3
	if icon then
		key:SetPoint('TOPLEFT', icon, 'TOPLEFT', -pad, pad)
		key:SetPoint('BOTTOMRIGHT', icon, 'BOTTOMRIGHT', pad, -pad)
	else
		key:SetAllPoints(tab)
	end
	key:SetFrameLevel(max(tab:GetFrameLevel() - 1, 0))
	key:EnableMouse(false)
	key.skin = Own(Kit:Skin(key, 'cap', 'BACKGROUND', 0))
	key.skin.kitMaxCorner = 6
	Kit:FitSprite(key.skin, key:GetWidth(), key:GetHeight())
	key.top = Own(CreateFrame('Frame', nil, tab))
	key.top:SetAllPoints(key)
	key.top:SetFrameLevel(tab:GetFrameLevel() + 2)
	key.top:EnableMouse(false)
	key.led = Own(Kit:Led(key.top, 4, false))
	key.led:SetPoint(opts.ledPoint or 'TOPLEFT', key, opts.ledPoint or 'TOPLEFT', opts.ledX or 3, opts.ledY or -3)
	key.icon = icon
	if opts.glyph then
		key.glyph = Own(key.top:CreateTexture(nil, 'OVERLAY', nil, 1))
		SetGlyph(key.glyph, opts.glyph)
		key.glyph:SetPoint('TOPLEFT', icon or key, 'TOPLEFT', 3, -3)
		key.glyph:SetPoint('BOTTOMRIGHT', icon or key, 'BOTTOMRIGHT', -3, 3)
	end
	-- Hover: the key brightens a touch.
	tab:HookScript('OnEnter', function() key.skin:SetAlpha(0.85) end)
	tab:HookScript('OnLeave', function() key.skin:SetAlpha(1) end)
	-- Some of Forever's side tabs are plain frames that take clicks by mouse-up.
	local clickScript = tab.HasScript and tab:HasScript('OnClick') and 'OnClick' or 'OnMouseUp'
	tab:HookScript(clickScript, function() P.Sound('tick', 'tab'); RepaintTabKeys() end)
	tab:HookScript('OnShow', RepaintTabKeys)
	tabKeys[tab] = key
	selectedOf[tab] = opts.selected
	PaintTabKey(tab)
	return key
end

-- Which glyph a side tab gets, from its name, key or tooltip.
local GLYPH_WORDS = {{'paperdoll', 'character'}, {'character', 'character'}, {'skill', 'professions'},
	{'profession', 'professions'}, {'honor', 'pvp'}, {'pvp', 'pvp'}, {'currenc', 'backpack'}, {'token', 'backpack'},
	{'quest', 'quest'}, {'achievement', 'achievements'}, {'statistic', 'journal'}, {'reputation', 'social'},
	{'faction', 'social'}, {'title', 'collections'}, {'guild', 'guild'}}
local function GlyphFor(tab)
	local words = {}
	local name = P.NameOf(tab)
	if name then words[#words + 1] = name end
	local ok, key = pcall(tab.GetParentKey, tab)
	if ok and type(key) == 'string' then words[#words + 1] = key end
	for _, field in ipairs({'tooltipText', 'tooltip', 'title', 'label', 'mode', 'tabKey'}) do
		local value = tab[field]
		if type(value) == 'string' and not IsSecret(value) then words[#words + 1] = value end
	end
	local text = table.concat(words, ' '):lower()
	for _, pair in ipairs(GLYPH_WORDS) do
		if text:find(pair[1], 1, true) then return pair[2] end
	end
end

local function SideTabChosen(tab)
	if Is(tab.SelectedTexture, 'Texture') and tab.SelectedTexture:IsShown() then return true end
	if type(tab.isSelected) == 'boolean' then return tab.isSelected end
	if tab.GetChecked then
		local ok, checked = pcall(tab.GetChecked, tab)
		if ok and not IsSecret(checked) then return checked and true or false end
	end
	return false
end

local function CropSideIcon(tab)
	local icon = tab.Icon
	if not Is(icon, 'Texture') then return end
	if tab.Mask and icon.RemoveMaskTexture then pcall(icon.RemoveMaskTexture, icon, tab.Mask) end
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
end

local function SideTab(tab)
	if P.Forbidden(tab) or not tab.GetRegions or not First('sidetab', tab) then return end
	local icon = Is(tab.Icon, 'Texture') and tab.Icon or nil
	local keep = {}
	if icon then keep[icon] = true end
	HideTextures(tab, keep)
	for _, part in ipairs({'Background', 'HighlightTexture', 'TabGlow', 'SelectedTexture', 'Mask'}) do
		if Is(tab[part], 'Texture') then tab[part]:SetAlpha(0) end
	end
	P.HideButtonArt(tab)
	CropSideIcon(tab)
	if type(tab.UpdateIconInterior) == 'function' then
		hooksecurefunc(tab, 'UpdateIconInterior', function(self) UI:Safe(CropSideIcon, self); RepaintTabKeys() end)
	end
	TabKey(tab, icon, {pad = 3, glyph = GlyphFor(tab), selected = SideTabChosen, ledPoint = 'TOPLEFT'})
end

local function SidebarTabChosen(tab)
	if Is(tab.checked, 'Texture') then return tab.checked:IsShown() end
	if tab.GetChecked then
		local ok, checked = pcall(tab.GetChecked, tab)
		if ok and not IsSecret(checked) then return checked and true or false end
	end
	return false
end

local function SidebarTab(tab)
	if P.Forbidden(tab) or not tab.GetRegions or not First('sidebartab', tab) then return end
	local icon = Is(tab.Icon, 'Texture') and tab.Icon or nil
	local keep = {}
	if icon then keep[icon] = true end
	for _, part in ipairs({'hover', 'pushed', 'checked', 'TabBg', 'Highlight', 'Hider'}) do
		if Is(tab[part], 'Texture') then tab[part]:SetAlpha(0) end
	end
	HideTextures(tab, keep)
	P.HideButtonArt(tab)
	if icon then icon:SetTexCoord(0.1, 0.9, 0.1, 0.9) end
	TabKey(tab, icon, {pad = 2, selected = SidebarTabChosen})
end

-- The right pane's toggle: a charcoal key with a chevron.
local function PaneToggle(frame)
	local toggle = frame.RightPaneToggleButton
	if not Is(toggle, 'Button') or not First('charpanetoggle', toggle) then return end
	P.HideButtonArt(toggle)
	HideTextures(toggle)
	local cap = P.Keycap(toggle, false, 4)
	local chevron = Own(Kit:Icon(cap, 'chevron-left', 10, 'darkInk'))
	chevron:SetPoint('CENTER')
	local function Paint()
		P.HideButtonArt(toggle)
		local ok, collapsed = pcall(frame.IsRightPaneCollapsed, frame)
		Kit:SetIcon(chevron, (ok and not IsSecret(collapsed) and collapsed) and 'chevron-right' or 'chevron-left')
	end
	if type(frame.UpdateRightPaneToggleButton) == 'function' then
		hooksecurefunc(frame, 'UpdateRightPaneToggleButton', function() UI:Safe(Paint) end)
	end
	local clickScript = toggle.HasScript and toggle:HasScript('OnClick') and 'OnClick' or 'OnMouseUp'
	toggle:HookScript(clickScript, function() C_Timer.After(0, function() UI:Safe(Paint) end) end)
	Paint()
end

-- Stats --------------------------------------------------------------------------------------
local shades = setmetatable({}, {__mode = 'k'}) -- stat row -> its zebra shade
local rules = setmetatable({}, {__mode = 'k'})  -- category row -> its rule

local CODE_GREEN = {'|cff20ff20', '|cFF20FF20'}
local CODE_RED = {'|cffff2020', '|cFFFF2020'}

local function RecolorValue(value)
	local text = value:GetText()
	if IsSecret(text) or type(text) ~= 'string' then return end
	local green, red, changed = Hex('ledGreen'), Hex('red'), text
	for _, code in ipairs(CODE_GREEN) do changed = changed:gsub(code, green) end
	for _, code in ipairs(CODE_RED) do changed = changed:gsub(code, red) end
	if changed ~= text then value:SetText(changed) end
	-- Colored through the string's color instead.
	local r, g, b = value:GetTextColor()
	if IsSecret(r) or IsSecret(g) or IsSecret(b) or not r then return end
	if g > 0.75 and r < 0.5 and b < 0.5 then value:SetTextColor(Kit:RGB('ledGreen'))
	elseif r > 0.8 and g < 0.4 then value:SetTextColor(Kit:RGB('red'))
	elseif r + g + b > 2.4 or (r > 0.9 and g > 0.75 and b < 0.3) then value:SetTextColor(Kit:RGB('darkInk')) end
end

local function Legend(label)
	local text = label:GetText()
	if IsSecret(text) or type(text) ~= 'string' then return end
	local printed = Upper((text:gsub(':%s*$', '')))
	if printed ~= text then label:SetText(printed) end
end

local function StatCategory(row)
	Hide(row.Background)
	local title = row.Title
	if Is(title, 'FontString') then
		if First('statcat', title) then Kit:Font(title, 8, nil, true) end
		title:SetTextColor(Kit:RGB('darkDim'))
		Legend(title)
		if not P.Locked(row) then
			title:ClearAllPoints()
			title:SetPoint('LEFT', row, 'LEFT', 6, -2)
			title:SetJustifyH('LEFT')
		end
	end
	if not rules[row] then
		local rule = Own(row:CreateTexture(nil, 'ARTWORK'))
		rule:SetColorTexture(1, 1, 1, 1)
		Kit:Tint(rule, 'darkEdge')
		rule:SetPoint('BOTTOMLEFT', row, 'BOTTOMLEFT', 4, 1)
		rule:SetPoint('BOTTOMRIGHT', row, 'BOTTOMRIGHT', -4, 1)
		rule:SetHeight(UI.Pixel.Px(row, 1))
		rules[row] = rule
	end
end

local function StatRow(row)
	if row.Title then return StatCategory(row) end
	local background = row.Background
	if Is(background, 'Texture') then
		background:SetAlpha(0)
		local shade = shades[row]
		if not shade then
			shade = Own(row:CreateTexture(nil, 'BORDER'))
			shade:SetColorTexture(1, 1, 1, 0.035)
			shade:SetAllPoints(row)
			shades[row] = shade
		end
		shade:SetShown(background:IsShown())
	end
	if Is(row.Label, 'FontString') then
		if First('statlabel', row.Label) then Kit:Font(row.Label, 9, nil, false) end
		row.Label:SetTextColor(Kit:RGB('darkDim'))
		Legend(row.Label)
	end
	if Is(row.Value, 'FontString') then
		if First('statvalue', row.Value) then Kit:Font(row.Value, 11, nil, true, 'numbers') end
		RecolorValue(row.Value)
	end
	if Is(row.Icon, 'Texture') then row.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
end

local function StatsPane(pane)
	if type(pane) ~= 'table' or P.Forbidden(pane) or not First('statspane', pane) then return end
	P.Strip(pane)
	Hide(pane.ClassBackground)
	P.ScrollBar(pane.ScrollBar)
	WatchBox(pane.ScrollBox, StatRow)
end

-- Retail's stats pane: rows from a pool, refreshed by PaperDollFrame_UpdateStats.
local function RetailStats()
	local pane = _G.CharacterStatsPane
	local pool = type(pane) == 'table' and pane.statsFramePool
	if not pool or not pool.EnumerateActive then return end
	for row in pool:EnumerateActive() do UI:Safe(StatRow, row) end
	local level = pane.ItemLevelFrame
	if type(level) == 'table' and Is(level.Value, 'FontString') then
		if First('statilvl', level.Value) then Kit:Font(level.Value, 18, nil, true, 'numbers') end
		level.Value:SetTextColor(Kit:RGB('lcdInk'))
	end
end

-- Lists and side panes ---------------------------------------------------------------------
local plates = setmetatable({}, {__mode = 'k'})

local function ListHeader(row)
	local keep = {}
	if Is(row.StateIcon, 'Texture') then keep[row.StateIcon] = true; Kit:Tint(row.StateIcon, 'darkDim') end
	HideTextures(row, keep)
	if not plates[row] then
		local plate = P.Back(row, {surface = 'glass', radius = 4, shadow = false}, 0, -1, 0, -1)
		plate:SetFrameLevel(max(row:GetFrameLevel() - 1, 0))
		Kit:Relevel(plate)
		plates[row] = plate
	end
	for _, region in ipairs({row:GetRegions()}) do
		if Is(region, 'FontString') then region:SetTextColor(Kit:RGB('darkInk')) end
	end
end

local function ListEntry(row)
	local content = row.Content
	if type(content) ~= 'table' then
		P.RelightRegions(row)
		return
	end
	local highlight = content.BackgroundHighlight
	if type(highlight) == 'table' and type(highlight.TextureRegions) == 'table' and First('listhl', highlight) then
		local r, g, b = Kit:RGB('lamp')
		for _, region in ipairs(highlight.TextureRegions) do
			if Is(region, 'Texture') then region:SetColorTexture(r, g, b, 0.12) end
		end
	end
	local bar = content.ReputationBar or content.SkillsBar
	if Is(bar, 'StatusBar') then P.StatusBar(bar) end
	if Is(content.CurrencyIcon, 'Texture') then content.CurrencyIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
	P.RelightRegions(content)
end

local function ListRow(row)
	if P.Forbidden(row) then return end
	if row.StateIcon then ListHeader(row) else ListEntry(row) end
end

local function ListFrame(frame)
	if type(frame) ~= 'table' or P.Forbidden(frame) or not frame.ScrollBox or not First('charlist', frame) then return end
	P.Strip(frame)
	P.ScrollBar(frame.ScrollBar)
	WatchBox(frame.ScrollBox, ListRow)
end

local function SideRows(pane)
	local pools = pane.rowPools
	if type(pools) ~= 'table' or not pools.EnumerateActive then return end
	for row in pools:EnumerateActive() do
		if Is(row.Background, 'Texture') then
			row.Background:SetAlpha(0)
			for _, region in ipairs({row:GetRegions()}) do
				if Is(region, 'FontString') then region:SetTextColor(Kit:RGB('darkDim')) end
			end
		elseif row.IconSlot then
			Hide(row.IconSlot)
			if Is(row.Icon, 'Texture') then row.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
		end
		P.RelightRegions(row)
	end
end

local function SidePane(pane)
	if type(pane) ~= 'table' or P.Forbidden(pane) or not First('charside', pane) then return end
	P.Strip(pane)
	Hide(pane.Divider)
	if Is(pane.Title, 'FontString') then
		Kit:Font(pane.Title, 12, nil, true)
		pane.Title:SetTextColor(Kit:RGB('darkInk'))
	end
	P.ScrollBar(pane.DescriptionScrollBar)
	for _, key in ipairs({'StandingBar', 'RankBar'}) do
		if Is(pane[key], 'StatusBar') then P.StatusBar(pane[key]) end
	end
	local queued = Debounce(function() SideRows(pane) end)
	if type(pane.AcquireRow) == 'function' then hooksecurefunc(pane, 'AcquireRow', queued) end
	pane:HookScript('OnShow', function() queued(); P.Queue(pane) end)
	queued()
	P.Queue(pane)
end

-- Titles and equipment sets ------------------------------------------------------------------
local OUTFIT_ART = {['UI-Character-Info-OutfitCard'] = true, ['UI-Character-Info-OutfitIcon-Frame'] = true}

local function TintBars(row)
	local r, g, b = Kit:RGB('lamp')
	if Is(row.SelectedBar, 'Texture') then row.SelectedBar:SetColorTexture(r, g, b, 0.18) end
	if Is(row.HighlightBar, 'Texture') then row.HighlightBar:SetColorTexture(1, 1, 1, 0.07) end
end

local function TitleRow(row)
	if P.Forbidden(row) or not First('titlerow', row) then return end
	for _, region in ipairs({row:GetRegions()}) do
		if Is(region, 'Texture') and region:GetDrawLayer() == 'BACKGROUND' then region:SetAlpha(0) end
	end
	TintBars(row)
	P.RelightRegions(row)
end

local function OutfitRow(row)
	if P.Forbidden(row) then return end
	if First('outfitrow', row) then
		for _, region in ipairs({row:GetRegions()}) do
			if Is(region, 'Texture') then
				local atlas = region.GetAtlas and region:GetAtlas()
				local bar = region == row.SelectedBar or region == row.HighlightBar or region == row.icon
				if not bar and ((not IsSecret(atlas) and atlas and OUTFIT_ART[atlas]) or region:GetDrawLayer() == 'BACKGROUND') then
					region:SetAlpha(0)
				end
			end
		end
		local plate = P.Back(row, {surface = 'glass', radius = 4, shadow = false}, 0, 0, -7, 0)
		plate:SetFrameLevel(max(row:GetFrameLevel() - 1, 0))
		Kit:Relevel(plate)
		TintBars(row)
	end
	if Is(row.icon, 'Texture') then row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
	P.RelightRegions(row)
end

local function Managers(paperDoll)
	local titles, sets = paperDoll.TitleManagerPane, paperDoll.EquipmentManagerPane
	if type(titles) == 'table' then
		P.ScrollBar(titles.ScrollBar)
		WatchBox(titles.ScrollBox, TitleRow)
	end
	if type(sets) == 'table' then
		P.Strip(sets)
		P.ScrollBar(sets.ScrollBar)
		WatchBox(sets.ScrollBox, OutfitRow)
		for _, key in ipairs({'EquipSet', 'SaveSet', 'NewSet'}) do
			local button = sets[key]
			if Is(button, 'Button') then
				Hide(button.StateTexture)
				P.PushButton(button)
			end
		end
	end
end

-- The alt-swap flyout ----------------------------------------------------------------------
local chevrons = setmetatable({}, {__mode = 'k'})
local FLIP = {RIGHT = 'LEFT', LEFT = 'RIGHT', UP = 'DOWN', DOWN = 'UP'}

local function Popout(button)
	if P.Forbidden(button) then return end
	P.HideButtonArt(button)
	local chevron = chevrons[button]
	if not chevron then
		local lid = Own(CreateFrame('Frame', nil, button))
		lid:SetAllPoints()
		lid:EnableMouse(false)
		lid:SetFrameLevel(button:GetFrameLevel() + 1)
		chevron = Own(Kit:Icon(lid, 'chevron-right', 9, 'darkInk'))
		chevron:SetPoint('CENTER')
		chevrons[button] = chevron
	end
	local parent = button:GetParent()
	local direction = (parent and parent.flyoutDirection) or button.flyoutDirection
		or (parent and parent.verticalFlyout and 'UP') or 'RIGHT'
	if type(direction) ~= 'string' then direction = 'RIGHT' end
	if button.flyoutLocked == true then direction = FLIP[direction] or direction end
	Kit:SetIcon(chevron, 'chevron-'..direction:lower())
end

local function Flyout()
	local flyout = _G.EquipmentFlyoutFrame
	if type(flyout) ~= 'table' or P.Forbidden(flyout) then return end
	local frame = flyout.buttonFrame
	if type(frame) == 'table' then
		for index = 1, tonumber(frame.numBGs) or 1 do Hide(frame['bg'..index]) end
		if First('flyoutglass', frame) then Own(Kit:Shell(frame, {surface = 'glass', radius = 6, shadowAlpha = 0.45})) end
	end
	Hide(_G.EquipmentFlyoutFrameHighlight)
	for _, button in ipairs(type(flyout.buttons) == 'table' and flyout.buttons or {}) do UI:Safe(P.Item, button) end
end

-- Putting it together ------------------------------------------------------------------------
local function AllSlots()
	local list = {}
	for _, slot in ipairs(SLOTS) do
		local button = _G['Character'..slot[1]..'Slot']
		if type(button) == 'table' then list[#list + 1] = {button, slot[2], slot[3]} end
	end
	return list
end

local function Refresh(frame)
	UpdateAllSlots()
	local scene = _G.CharacterModelScene
	if type(scene) == 'table' then HideSceneArt(scene) end
	if screen then screen:SetShown(DB().modelScreen and true or false) end
	local paperDoll = _G.PaperDollFrame
	if paperDoll and type(paperDoll.TopBackgroundStripHost) == 'table' then P.Strip(paperDoll.TopBackgroundStripHost) end
	if type(frame) == 'table' and type(frame.RightPaneHost) == 'table' then
		local divider = frame.RightPaneHost:GetChildren()
		if type(divider) == 'table' and not P.IsOwn(divider) then P.Strip(divider) end
	end
	RepaintTabKeys()
end

function module.CharacterExtras(frame)
	if not First('charextras', frame) then return end
	for _, entry in ipairs(AllSlots()) do UI:Safe(DressSlot, entry[1], entry[2], entry[3]) end
	if type(_G.PaperDollItemSlotButton_Update) == 'function' then
		hooksecurefunc('PaperDollItemSlotButton_Update', function(button)
			if slots[button] then UI:Safe(UpdateSlot, button) end
		end)
	end
	UI:Safe(ModelScreen, _G.CharacterModelScene)
	UI:Safe(Title, _G.CharacterLevelText)
	UI:Safe(Title, _G.PetCharacterLevelText)
	UI:Safe(PaneToggle, frame)
	-- The big side tabs (Forever), the stats pane's icon tabs and the bottom tabs.
	local modeTabs = type(frame.ModeTabs) == 'table' and frame.ModeTabs.Tabs
	if type(modeTabs) == 'table' then
		for _, tab in ipairs(modeTabs) do UI:Safe(SideTab, tab) end
	end
	for index = 1, 6 do
		local tab = _G['PaperDollSidebarTab'..index]
		if type(tab) == 'table' then UI:Safe(SidebarTab, tab) end
		local bottom = _G['CharacterFrameTab'..index]
		if type(bottom) == 'table' then UI:Safe(P.Tab, bottom) end
	end
	for _, name in ipairs({'UpdateTabLayout', 'SetTab', 'SelectTab', 'SetMode', 'ShowSubFrame', 'UpdateTabs'}) do
		if type(frame[name]) == 'function' then hooksecurefunc(frame, name, RepaintTabKeys) end
	end
	for _, name in ipairs({'CharacterFrame_ShowSubFrame', 'PaperDollFrame_UpdateSidebarTabs', 'PaperDollFrame_SetSidebar',
		'PaperDollFrame_ShowSidebar'}) do
		if type(_G[name]) == 'function' then hooksecurefunc(name, RepaintTabKeys) end
	end
	-- Stats.
	UI:Safe(StatsPane, _G.CharacterStatsPaneScrollBox)
	UI:Safe(StatsPane, _G.CharacterStatsPanePetScrollBox)
	if type(_G.PaperDollFrame_UpdateStats) == 'function' then
		hooksecurefunc('PaperDollFrame_UpdateStats', function() UI:Safe(RetailStats) end)
	end
	-- Panes.
	local reputation, tokens, skills = _G.ReputationFrame, _G.TokenFrame, _G.SkillsFrame
	UI:Safe(ListFrame, reputation)
	UI:Safe(ListFrame, tokens)
	UI:Safe(ListFrame, skills)
	UI:Safe(ListFrame, _G.StatisticsFrame)
	if type(reputation) == 'table' then UI:Safe(SidePane, reputation.ReputationDetailFrame) end
	if type(tokens) == 'table' then UI:Safe(SidePane, tokens.DetailFrame) end
	if type(skills) == 'table' then UI:Safe(SidePane, skills.SkillDetailFrame) end
	local rank = _G.PVPRankFrame
	if type(rank) == 'table' then
		if type(rank.MainInfoFrame) == 'table' then Hide(rank.MainInfoFrame.Line) end
		UI:Safe(SidePane, rank.DetailFrame)
	end
	local paperDoll = _G.PaperDollFrame
	if type(paperDoll) == 'table' then
		UI:Safe(Managers, paperDoll)
		paperDoll:HookScript('OnShow', function() UI:Safe(Refresh, frame) end)
	end
	-- The flyout.
	if type(_G.EquipmentFlyout_UpdateItems) == 'function' then
		hooksecurefunc('EquipmentFlyout_UpdateItems', function() UI:Safe(Flyout) end)
	end
	if type(_G.EquipmentFlyoutPopoutButton_RefreshVisualState) == 'function' then
		hooksecurefunc('EquipmentFlyoutPopoutButton_RefreshVisualState', function(button) UI:Safe(Popout, button) end)
	end
	-- Equipment changes, and Statistics when its addon loads.
	local events = CreateFrame('Frame')
	events:RegisterEvent('PLAYER_EQUIPMENT_CHANGED')
	events:RegisterEvent('ADDON_LOADED')
	local slotsSoon = Debounce(UpdateAllSlots)
	events:SetScript('OnEvent', function(_, event, name)
		if event == 'ADDON_LOADED' then
			if name == 'Blizzard_Statistics' then UI:Safe(ListFrame, _G.StatisticsFrame) end
		elseif frame:IsVisible() then
			slotsSoon()
		end
	end)
	frame:HookScript('OnShow', function(self) UI:Safe(Refresh, self) end)
	Refresh(frame)
end

-- Settings changed on the hub: repaint what is open.
Kit:OnRefresh(function()
	if next(slots) then UI:Safe(Refresh, _G.CharacterFrame) end
end)
