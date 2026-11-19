-- The character window, all the way in (Skins.lua gives it its housing and
-- header, then hands over here):
--   gear slots      light keys with the icon in a window, quality as a lit edge
--                   and a lamp, and a printed legend (HEAD, NECK, RNG1 ...) in an
--                   empty slot. The game's slot frames (Forever's brass-riveted
--                   BorderFrame, Retail's Char-*Slot art) are gone. Each slot's item
--                   level sits on its own small LCD beside it (under it in
--                   Forever's three-weapon row), in LCD ink: quality is the edge
--                   and the lamp, never the digits.
--   rails           each slot column, the weapon row and the ammo slot sit on a
--                   machined plate; plates and screen are laid out from
--                   the slots' real positions so every gutter is the same
--   model           a recessed display in a glass bezel, with a faint grid, a
--                   vignette and corner marks; its camera keys are charcoal caps
--                   with kit glyphs, docked inside the top of the screen
--   title           "LEVEL 26 PALADIN" printed in small caps
--   stats           printed small-caps category headers on a rule, legends in dim
--                   print and values in screen ink (the game's green and red kept as
--                   the kit's own), the item level on an LCD, the kit's thin scroll bar
--   tabs            the pane toggle a key with a chevron; the stats pane's sidebar
--                   tabs and Forever's big side tabs as evenly spaced keys: charcoal,
--                   or raised and light with a lit lamp when chosen, showing the
--                   game's icon (cropped, desaturated unless chosen) or a SPEC-01 glyph
--   panes           reputation, currency, skills, PvP, statistics, titles and
--                   equipment sets: lists on black screens, printed headers, the
--                   game's bars as dot meters, plus/minus keys, kit checks, gold
--                   print relit, the PvP rank dial as a lamp ring
--   flyouts         the alt-swap flyout on glass, its items as keys, its page keys
--
-- Same rules as Skins.lua: post-hooks and HookScript only, our parts in side
-- tables, pooled rows dressed from our own timer after the game is done, and
-- values that may be secret only ever handed to setters. Textures that come
-- from an atlas never get their texture coordinates changed (that shows the
-- whole atlas sheet); only plain icon files are cropped.
local _, UI = ...
local Kit = UI.Kit

local module = UI.modules.windows
if not module or not module.parts then return end
local P = module.parts

local CreateFrame, C_Timer, hooksecurefunc = CreateFrame, C_Timer, hooksecurefunc
local floor, max, min = math.floor, math.max, math.min
local type, ipairs, pairs, pcall, tonumber = type, ipairs, pairs, pcall, tonumber

local IsSecret, Is, Hide, Own, First = P.IsSecret, P.Is, P.Hide, P.Own, P.First

local function DB() return UI.db.skins end
-- Frames this file sets on a black screen of its own (the walk adds no second one).
local function Screened(frame)
	if type(frame) == 'table' and type(P.Screened) == 'function' then P.Screened(frame) end
end
local Px, Snap = UI.Util.Px, UI.Util.Snap

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

-- Print a string in capitals (after the game has set it).
local function PrintUpper(text)
	if not Is(text, 'FontString') then return end
	local value = text:GetText()
	if IsSecret(value) or type(value) ~= 'string' then return end
	local upper = Upper(value)
	if upper ~= value then text:SetText(upper) end
end

local function Hex(token)
	local r, g, b = Kit:RGB(token)
	return format('|cff%02x%02x%02x', floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5))
end

-- A texture region of the game's: not ours, and not a mask (a mask at alpha 0
-- would hide whatever it masks).
local function Art(region)
	return Is(region, 'Texture') and not region:IsObjectType('MaskTexture') and not P.IsOwn(region)
end

-- Hide every texture a frame draws itself, but the ones kept.
local function HideTextures(frame, keep)
	for _, region in ipairs({frame:GetRegions()}) do
		if Art(region) and not (keep and keep[region]) then region:SetAlpha(0) end
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

-- Glyphs from the menu atlas (Media/Hardware/icons-menu.tga, 8 x 4), in the
-- atlas order of tools/build-hardware-art.py.
local MENU_GLYPHS = {character = 0, spellbook = 1, talents = 2, professions = 3, achievements = 4, legacy = 5, quest = 6,
	guild = 7, social = 8, finder = 9, journal = 10, collections = 11, menu = 12, help = 13, store = 14, house = 15, map = 16,
	pvp = 17, backpack = 18, bag = 19, reagent = 20, key = 21, mount = 22, hearth = 23, drawer = 24, move = 25,
	calendar = 26, meter = 27, lock = 28, reload = 29, macro = 30}
local function SetGlyph(texture, name)
	local index = MENU_GLYPHS[name] or 0
	local column, row = index % 8, floor(index / 8)
	texture:SetTexture(Kit.media..'icons-menu.tga')
	texture:SetTexCoord(column / 8, (column + 1) / 8, row / 4, (row + 1) / 4)
end

-- Crop a plain icon file's baked border. Atlas textures are left alone.
local function CropIcon(texture, inset)
	if not Is(texture, 'Texture') then return end
	local atlas = texture.GetAtlas and texture:GetAtlas()
	if IsSecret(atlas) or (type(atlas) == 'string' and atlas ~= '') then return end
	inset = inset or 0.08
	texture:SetTexCoord(inset, 1 - inset, inset, 1 - inset)
end

-- The game's gold print (NORMAL_FONT_COLOR) becomes screen ink; every other
-- color (red warnings, green bonuses, white values) is the game's meaning and stays.
local function Ungild(text, token)
	if not Is(text, 'FontString') or P.IsOwn(text) then return end
	local ok, r, g, b = pcall(text.GetTextColor, text)
	if not ok or IsSecret(r) or IsSecret(g) or IsSecret(b) or type(r) ~= 'number' then return end
	if r > 0.9 and g > 0.6 and g < 0.92 and b < 0.3 then text:SetTextColor(Kit:RGB(token or 'darkInk')) end
end

local function UngildTree(frame, depth)
	if P.Forbidden(frame) or not frame.GetRegions or P.IsOwn(frame) then return end
	for _, region in ipairs({frame:GetRegions()}) do Ungild(region) end
	if (depth or 0) >= 4 then return end
	for _, child in ipairs({frame:GetChildren()}) do UngildTree(child, (depth or 0) + 1) end
end

-- The kit's check in place of the game's yellow tick.
local function CheckMark(texture, token)
	if not Is(texture, 'Texture') or not First('charcheck', texture) then return end
	texture:SetTexture(Kit.media..'icons.tga')
	Kit:SetIcon(texture, 'check')
	Kit:Tint(texture, token or 'lamp')
	if texture.SetBlendMode then texture:SetBlendMode('BLEND') end
end

-- A flat wash in a token's color (selection and hover bars).
local function Wash(texture, token, alpha)
	if not Is(texture, 'Texture') then return end
	texture:SetColorTexture(1, 1, 1, 1)
	texture:SetAlpha(1)
	if texture.SetBlendMode then texture:SetBlendMode('BLEND') end
	Kit:Tint(texture, token, alpha)
end

-- Round lamps a whole number of physical pixels wide, snapped to the pixel
-- grid, so they read as full LEDs (never a crescent) at any UI scale.
local lamps = setmetatable({}, {__mode = 'k'}) -- lamp -> its size in physical pixels
local function FitLamp(led)
	local px = lamps[led]
	if not px then return end
	local size = Px(led:GetParent(), px)
	led:SetSize(size, size)
	if led.glow then Kit:FitSprite(led.glow, size, size) end
end

local function Lamp(parent, px, on)
	local led = Own(Kit:Led(parent, 4, on))
	if led.glow then Own(led.glow) end
	for _, texture in ipairs({led, led.glow}) do
		if texture and texture.SetSnapToPixelGrid then
			texture:SetSnapToPixelGrid(true)
			texture:SetTexelSnappingBias(0)
		end
	end
	lamps[led] = px
	FitLamp(led)
	return led
end

-- Gear slots ---------------------------------------------------------------------------
-- Column: L and R the side columns, B the weapon row, A the ammo slot.
local SLOTS = {
	{'Head', 'HEAD', 'L'}, {'Neck', 'NECK', 'L'}, {'Shoulder', 'SHLD', 'L'}, {'Back', 'BACK', 'L'}, {'Chest', 'CHST', 'L'},
	{'Shirt', 'SHRT', 'L'}, {'Tabard', 'TABD', 'L'}, {'Wrist', 'WRST', 'L'},
	{'Hands', 'HNDS', 'R'}, {'Waist', 'WAST', 'R'}, {'Legs', 'LEGS', 'R'}, {'Feet', 'FEET', 'R'}, {'Finger0', 'RNG1', 'R'},
	{'Finger1', 'RNG2', 'R'}, {'Trinket0', 'TRK1', 'R'}, {'Trinket1', 'TRK2', 'R'},
	{'MainHand', 'MH', 'B'}, {'SecondaryHand', 'OH', 'B'}, {'Ranged', 'RNGD', 'B'}, {'Ammo', 'AMMO', 'A'},
}
local READOUT_W, READOUT_H, READOUT_GAP = 24, 12, 4 -- the item level LCD beside a slot
local KEY_EDGE = 2                                  -- the key's lip outside the icon, physical px
local RAIL_PAD, GUTTER = 5, 6                       -- plate padding around its keys; space between parts

local slots = setmetatable({}, {__mode = 'k'}) -- slot button -> {legend, lcd, level, column}
local UpdateSlot, DressSlot, UpdateAllSlots
local screen -- the model's display, built in the next section
local LayoutRails, LayoutSoon
do
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
		if IsSecret(link) or type(link) ~= 'string' then return nil end
		local info = C_Item and C_Item.GetDetailedItemLevelInfo or _G.GetDetailedItemLevelInfo
		if not info then return nil end
		local ok, level = pcall(info, link)
		if not ok then return nil end
		return level
	end

	UpdateSlot = function(button)
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
		-- The item level on its LCD, in LCD ink; dashes on an empty readout.
		if parts.lcd then
			parts.lcd:SetShown(db.itemLevel and true or false)
			local level = (db.itemLevel and not empty) and ItemLevel(id) or nil
			if IsSecret(level) then
				parts.level:SetFormattedText('%d', level)
				Kit:Tint(parts.level, 'lcdInk')
			elseif type(level) == 'number' and level > 1 then
				parts.level:SetText(floor(level))
				Kit:Tint(parts.level, 'lcdInk')
			else
				parts.level:SetText('--')
				Kit:Tint(parts.level, 'lcdDim')
			end
		end
		P.Quality(button)
	end

	-- The key Skins.lua put behind the slot (its own frame, found by its sprite).
	local function SlotKey(button)
		for _, child in ipairs({button:GetChildren()}) do
			if P.IsOwn(child) and type(child.skin) == 'table' and child.skin.kitSprite == 'key' then return child end
		end
	end

	DressSlot = function(button, legend, column)
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
		-- Forever's ornate slot frame (brass rivet corners) lives on a child frame.
		local border = button.BorderFrame
		if type(border) == 'table' and not P.Forbidden(border) and border.GetRegions then HideTextures(border) end
		-- The ammo slot's pointer arrow, likewise.
		if column == 'A' then
			for _, child in ipairs({button:GetChildren()}) do
				if not P.IsOwn(child) and not P.Forbidden(child) and child.GetRegions and not P.NameOf(child)
					and not Is(child, 'Cooldown') then
					HideTextures(child)
				end
			end
		end
		P.Item(button)
		local anchor = icon or button
		-- The key hugs the icon, so neighbouring slots keep a gap between their keys.
		local key = SlotKey(button)
		if key then
			local edge = Px(button, KEY_EDGE)
			key:ClearAllPoints()
			key:SetPoint('TOPLEFT', anchor, 'TOPLEFT', -edge, edge)
			key:SetPoint('BOTTOMRIGHT', anchor, 'BOTTOMRIGHT', edge, -edge)
		end
		-- The quality lamp: whole pixels, on the pixel grid.
		local ring = P.Ring(button)
		local led = ring and ring.led
		if Is(led, 'Texture') then
			if led.SetSnapToPixelGrid then
				led:SetSnapToPixelGrid(true)
				led:SetTexelSnappingBias(0)
			end
			lamps[led] = 4
			FitLamp(led)
			local inset = Snap(button, 3)
			led:ClearAllPoints()
			led:SetPoint('TOPRIGHT', anchor, 'TOPRIGHT', -inset, -inset)
		end
		if Is(highlight, 'Texture') and icon and not P.Locked(button) then
			highlight:SetColorTexture(1, 1, 1, 0.14)
			highlight:ClearAllPoints()
			highlight:SetAllPoints(icon)
		end
		local top = Own(CreateFrame('Frame', nil, button))
		top:SetAllPoints(anchor)
		top:SetFrameLevel(button:GetFrameLevel() + 3)
		top:EnableMouse(false)
		local parts = {column = column}
		parts.legend = Own(Kit:Label(top, legend, 'dim', 7, true))
		parts.legend:SetPoint('CENTER', 0, 0)
		-- The item level readout: beside a side column's key (on the model's
		-- side), under a weapon when the row holds three, beside the outer
		-- weapons when it holds two. Not on the ammo slot.
		if column ~= 'A' then
			local lcd = Own(Kit:LCDPanel(button, {radius = 2}))
			Own(lcd.shell)
			Own(lcd.inner)
			lcd:SetSize(Snap(button, READOUT_W), Snap(button, READOUT_H))
			lcd:SetFrameLevel(button:GetFrameLevel() + 2)
			lcd:EnableMouse(false)
			local away = Snap(button, READOUT_GAP) + Px(button, KEY_EDGE)
			local place = column
			if column == 'B' and type(_G.CharacterRangedSlot) ~= 'table' then
				place = button == _G.CharacterMainHandSlot and 'R' or 'L'
			end
			if place == 'L' then lcd:SetPoint('LEFT', button, 'RIGHT', away, 0)
			elseif place == 'R' then lcd:SetPoint('RIGHT', button, 'LEFT', -away, 0)
			else lcd:SetPoint('TOP', button, 'BOTTOM', 0, -away) end
			parts.level = Own(Kit:Text(lcd, '--', 8, 'lcdDim', true))
			Kit:Font(parts.level, 8, nil, true, 'numbers')
			parts.level:SetPoint('CENTER', 0, 0)
			parts.lcd = lcd
		end
		slots[button] = parts
		P.SetQualitySource(button, SlotQuality)
		UpdateSlot(button)
	end

	UpdateAllSlots = function()
		for button in pairs(slots) do UI:Safe(UpdateSlot, button) end
	end

	-- Layout -----------------------------------------------------------------------------
	-- Edges of a shown frame in screen units (left, right, top, bottom).
	local function Edges(frame)
		if type(frame) ~= 'table' or P.Forbidden(frame) or not frame:IsVisible() then return nil end
		local l, r, t, b = frame:GetLeft(), frame:GetRight(), frame:GetTop(), frame:GetBottom()
		if IsSecret(l) or IsSecret(r) or IsSecret(t) or IsSecret(b) or not l or not r or not t or not b then return nil end
		local scale = frame:GetEffectiveScale()
		return l * scale, r * scale, t * scale, b * scale
	end

	local function Union(frames)
		local l, r, t, b
		for _, frame in ipairs(frames) do
			local fl, fr, ft, fb = Edges(frame)
			if fl then
				l, r = l and min(l, fl) or fl, r and max(r, fr) or fr
				t, b = t and max(t, ft) or ft, b and min(b, fb) or fb
			end
		end
		return l, r, t, b
	end

	-- Place `frame` over a screen-unit rectangle, in whole pixels of its parent.
	local function PlaceAt(frame, l, r, t, b)
		local parent = frame:GetParent()
		local pl, pb = parent:GetLeft(), parent:GetBottom()
		if IsSecret(pl) or IsSecret(pb) or not pl or not pb then return false end
		local scale = parent:GetEffectiveScale()
		frame:ClearAllPoints()
		frame:SetPoint('BOTTOMLEFT', parent, 'BOTTOMLEFT', Snap(parent, l / scale - pl), Snap(parent, b / scale - pb))
		frame:SetSize(Snap(parent, max(r - l, 1) / scale), Snap(parent, max(t - b, 1) / scale))
		return true
	end

	-- A machined plate: a raised dark panel.
	local rails = {}
	local function Rail(column, host, level)
		local rail = rails[column]
		if not rail then
			rail = Own(CreateFrame('Frame', nil, host))
			rail:EnableMouse(false)
			rail.shell = Own(Kit:Shell(rail, {surface = 'dark', radius = 8, shadow = false}))
			rails[column] = rail
		end
		rail:SetFrameLevel(max(level, 1))
		Kit:Relevel(rail)
		return rail
	end

	-- The slots of a column, with their readouts when shown.
	local function Members(column)
		local list, first = {}, nil
		for _, slot in ipairs(SLOTS) do
			local button = _G['Character'..slot[1]..'Slot']
			if slot[3] == column and type(button) == 'table' and slots[button] then
				first = first or button
				list[#list + 1] = button
				local lcd = slots[button].lcd
				if lcd and lcd:IsShown() then list[#list + 1] = lcd end
			end
		end
		return list, first
	end

	LayoutRails = function()
		local scene = _G.CharacterModelScene
		local host = _G.PaperDollItemsFrame or (_G.PaperDollFrame and _G.PaperDollFrame.ItemsFrame)
		if type(host) ~= 'table' or P.Forbidden(host) or not host:IsVisible() then return end
		local edges = {}
		for _, column in ipairs({'L', 'R', 'B', 'A'}) do
			local list, first = Members(column)
			local l, r, t, b = Union(list)
			local rail = rails[column]
			if l and first then
				rail = Rail(column, host, first:GetFrameLevel() - 3)
				local pad = RAIL_PAD * host:GetEffectiveScale()
				l, r, t, b = l - pad, r + pad, t + pad, b - pad
				if PlaceAt(rail, l, r, t, b) then
					rail:Show()
					edges[column] = {l, r, t, b}
				end
			elseif rail then
				rail:Hide()
			end
		end
		-- The screen fills the space the plates leave, one gutter from each.
		if not screen or type(scene) ~= 'table' then return end
		local left, right = edges.L, edges.R
		if not left or not right then return end
		local gutter = GUTTER * host:GetEffectiveScale()
		local l, r = left[2] + gutter, right[1] - gutter
		local t = max(left[3], right[3])
		local b = min(left[4], right[4])
		local bottom = edges.B
		if bottom and bottom[3] > b and bottom[3] < t then b = bottom[3] + gutter end
		if r - l > 40 and t - b > 40 then PlaceAt(screen, l, r, t, b) end
		-- The camera keys dock inside the top of the screen.
		local controls = scene.ControlFrame
		if type(controls) == 'table' and not P.Forbidden(controls) and not P.Locked(controls) then
			controls:ClearAllPoints()
			controls:SetPoint('TOP', screen, 'TOP', 0, -Snap(screen, 4))
		end
	end

	-- Layout runs once the game has placed everything: next frame, and again a
	-- little later in case a slot moved on show.
	local armed = false
	LayoutSoon = function()
		if armed then return end
		armed = true
		C_Timer.After(0, function()
			armed = false
			UI:Safe(LayoutRails)
			C_Timer.After(0.1, function() UI:Safe(LayoutRails) end)
		end)
	end
end

-- The model's display ----------------------------------------------------------------------
local ModelScreen, HideSceneArt
do
	HideSceneArt = function(scene)
		for _, region in ipairs({scene:GetRegions()}) do
			if Art(region) then region:SetAlpha(0) end
		end
	end

	local function Grid(frame)
		frame.lines = frame.lines or {}
		for _, line in ipairs(frame.lines) do line:Hide() end
		local width, height = P.Size(frame)
		if width <= 0 or height <= 0 then return end
		local px, step, index = Px(frame, 1), 16, 0
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
		for x = step, width - 1, step do Line(true, Snap(frame, x)) end
		for y = step, height - 1, step do Line(false, Snap(frame, y)) end
	end

	-- Corner marks: two-pixel arms, a few pixels in from each corner.
	local function Corner(frame, point, sx, sy)
		local arm, px, inset = Snap(frame, 10), Px(frame, 2), Snap(frame, 6)
		local across = Own(frame:CreateTexture(nil, 'ARTWORK'))
		local down = Own(frame:CreateTexture(nil, 'ARTWORK'))
		for _, piece in ipairs({across, down}) do
			piece:SetColorTexture(1, 1, 1, 1)
			Kit:Tint(piece, 'darkDim', 0.8)
			piece:SetPoint(point, frame, point, sx * inset, sy * inset)
		end
		across:SetSize(arm, px)
		down:SetSize(px, arm)
	end

	-- The camera keys: charcoal caps with the kit's glyphs.
	local CAMERA = {zoomInButton = {'icon', 'plus'}, zoomOutButton = {'icon', 'minus'},
		rotateLeftButton = {'icon', 'tri-left'}, rotateRightButton = {'icon', 'tri-right'}, resetButton = {'glyph', 'reload'}}
	local function CameraKeys(controls)
		if type(controls) ~= 'table' or P.Forbidden(controls) or not First('camkeys', controls) then return end
		P.Strip(controls)
		for name, art in pairs(CAMERA) do
			local button = controls[name]
			if Is(button, 'Button') and First('camkey', button) then
				P.HideButtonArt(button)
				HideTextures(button)
				-- The buttons overlap (32 wide, 26 apart); the caps sit on their hit
				-- area, so neighbours keep an even gap.
				local cap = P.Keycap(button, false, 4)
				local inset = Snap(button, 5)
				cap:ClearAllPoints()
				cap:SetPoint('TOPLEFT', button, 'TOPLEFT', inset, -inset)
				cap:SetPoint('BOTTOMRIGHT', button, 'BOTTOMRIGHT', -inset, inset)
				local mark
				if art[1] == 'icon' then
					mark = Own(Kit:Icon(cap, art[2], Snap(button, 10), 'darkInk'))
				else
					mark = Own(cap:CreateTexture(nil, 'OVERLAY'))
					SetGlyph(mark, art[2])
					mark:SetSize(Snap(button, 12), Snap(button, 12))
					Kit:Tint(mark, 'darkInk')
				end
				mark:SetPoint('CENTER', cap, 'CENTER', 0, 0)
				-- The legend goes down with the cap.
				local down = Px(button, 1)
				button:HookScript('OnMouseDown', function() mark:SetPoint('CENTER', cap, 'CENTER', 0, -down) end)
				button:HookScript('OnMouseUp', function() mark:SetPoint('CENTER', cap, 'CENTER', 0, 0) end)
				button:HookScript('OnHide', function() mark:SetPoint('CENTER', cap, 'CENTER', 0, 0) end)
			end
		end
	end

	ModelScreen = function(scene)
		if screen or type(scene) ~= 'table' or P.Forbidden(scene) then return end
		HideSceneArt(scene)
		scene:HookScript('OnShow', function(self) UI:Safe(HideSceneArt, self) end)
		local parent = scene:GetParent() or scene
		local level = scene:GetFrameLevel()
		screen = Own(CreateFrame('Frame', nil, parent))
		-- Until the plates are laid out: between the head and trinket columns.
		local head, trinket = _G.CharacterHeadSlot, _G.CharacterTrinket1Slot
		if type(head) == 'table' and type(trinket) == 'table' then
			screen:SetPoint('TOPLEFT', head, 'TOPRIGHT', 8, 0)
			screen:SetPoint('BOTTOMRIGHT', trinket, 'BOTTOMLEFT', -8, 0)
		else
			screen:SetAllPoints(scene)
		end
		-- Everything here stays under the model.
		screen:SetFrameLevel(max(level - 2, 1))
		screen:EnableMouse(false)
		screen.bezel = Own(Kit:Shell(screen, {surface = 'glass', radius = 8, shadow = false}))
		screen.glass = Own(CreateFrame('Frame', nil, screen))
		local inset = Snap(screen, 3)
		screen.glass:SetPoint('TOPLEFT', inset, -inset)
		screen.glass:SetPoint('BOTTOMRIGHT', -inset, inset)
		screen.glass:SetFrameLevel(max(level - 1, 1))
		screen.glass:EnableMouse(false)
		Own(Kit:Shell(screen.glass, {surface = 'screen', radius = 6, shadow = false}))
		local grid = Own(CreateFrame('Frame', nil, screen.glass))
		grid:SetAllPoints()
		grid:SetFrameLevel(screen.glass:GetFrameLevel())
		grid:EnableMouse(false)
		screen.grid = grid
		grid:HookScript('OnSizeChanged', function() UI:Safe(Grid, grid) end)
		-- A vignette: the top and bottom fall off into black.
		for _, side in ipairs({'TOP', 'BOTTOM'}) do
			local shade = Own(grid:CreateTexture(nil, 'ARTWORK', nil, -1))
			shade:SetColorTexture(1, 1, 1, 1)
			shade:SetPoint(side..'LEFT')
			shade:SetPoint(side..'RIGHT')
			shade:SetHeight(48)
			local edge, clear = CreateColor(0, 0, 0, 0.55), CreateColor(0, 0, 0, 0)
			if side == 'TOP' then shade:SetGradient('VERTICAL', clear, edge) else shade:SetGradient('VERTICAL', edge, clear) end
		end
		Corner(grid, 'TOPLEFT', 1, -1)
		Corner(grid, 'TOPRIGHT', -1, -1)
		Corner(grid, 'BOTTOMLEFT', 1, 1)
		Corner(grid, 'BOTTOMRIGHT', -1, 1)
		Grid(grid)
		screen:SetShown(DB().modelScreen and true or false)
		CameraKeys(scene.ControlFrame)
	end
end

-- Title ----------------------------------------------------------------------------------------
local Title
do
	local upping = false
	local function PrintTitle(text)
		if upping then return end
		upping = true
		PrintUpper(text)
		upping = false
	end

	Title = function(text)
		if not Is(text, 'FontString') or not First('chartitle', text) then return end
		Kit:Font(text, 10, nil, true)
		text:SetTextColor(Kit:RGB('darkInk'))
		text:SetShadowOffset(0, 0)
		hooksecurefunc(text, 'SetText', function(self) UI:Safe(PrintTitle, self) end)
		hooksecurefunc(text, 'SetFormattedText', function(self) UI:Safe(PrintTitle, self) end)
		PrintTitle(text)
	end
end

-- Tabs -----------------------------------------------------------------------------------------
-- A key per tab: charcoal, or raised, light and lamp-lit when chosen. The key
-- shows the game's icon (set into the key, cropped, desaturated unless chosen)
-- or a SPEC-01 glyph (Windows -> Side tabs).
local tabKeys = setmetatable({}, {__mode = 'k'})   -- tab -> key frame
local selectedOf = setmetatable({}, {__mode = 'k'}) -- tab -> function(tab) -> chosen
local RepaintTabKeys, ModeTab, SidebarTab, PaneToggle, CropModeIcons
do
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
		local glyphs = key.glyph ~= nil and DB().sideTabs == 'glyphs'
		if key.glyph then
			key.glyph:SetShown(glyphs)
			Kit:Tint(key.glyph, on and 'ink' or 'darkDim')
		end
		if key.icon then
			key.icon:SetAlpha(glyphs and 0 or (on and 1 or 0.62))
			if key.icon.SetDesaturated then key.icon:SetDesaturated(not on) end
		end
		if key.window then key.window:SetShown(not glyphs) end
	end

	RepaintTabKeys = Debounce(function()
		for tab in pairs(tabKeys) do UI:Safe(PaintTabKey, tab) end
	end)

	-- The game's icon centered in the key, inside its margin. `down` nudges it
	-- one pixel while the tab is held.
	local function FitTabKey(tab, down)
		local key = tabKeys[tab]
		if not key then return end
		local width, height = P.Size(key)
		if width <= 0 or height <= 0 then width, height = key.fallback, key.fallback end
		local side = Snap(key, max(min(width, height) - key.margin * 2, 8))
		local nudge = down and Px(key, 1) or 0
		if key.icon and not P.Locked(tab) then
			key.icon:ClearAllPoints()
			key.icon:SetPoint('CENTER', key, 'CENTER', nudge, -nudge)
			key.icon:SetSize(side, side)
		end
		if key.glyph then
			local glyph = Snap(key, side * 0.8)
			key.glyph:SetSize(glyph, glyph)
			key.glyph:SetPoint('CENTER', key, 'CENTER', nudge, -nudge)
		end
	end

	-- opts: inset {l, t, r, b} from the tab's edges, or shrink (a centered square
	-- key, this much smaller than the tab); margin around the icon; lamp (px);
	-- glyph (a menu glyph name); selected(tab) -> chosen.
	local function TabKey(tab, icon, opts)
		if tabKeys[tab] or P.Forbidden(tab) then return tabKeys[tab] end
		local key = Own(CreateFrame('Frame', nil, tab))
		if opts.inset then
			key:SetPoint('TOPLEFT', tab, 'TOPLEFT', Snap(tab, opts.inset[1]), Snap(tab, opts.inset[2]))
			key:SetPoint('BOTTOMRIGHT', tab, 'BOTTOMRIGHT', Snap(tab, opts.inset[3]), Snap(tab, opts.inset[4]))
		else
			local width, height = P.Size(tab)
			local side = (width > 0 and height > 0) and min(width, height) - (opts.shrink or 4) or (opts.fallback or 36)
			side = Snap(tab, max(side, 16))
			key:SetSize(side, side)
			key:SetPoint('CENTER', tab, 'CENTER', 0, 0)
		end
		key:SetFrameLevel(max(tab:GetFrameLevel() - 1, 0))
		key:EnableMouse(false)
		key.margin, key.fallback, key.icon = opts.margin or 6, opts.fallback or 36, icon
		key.skin = Own(Kit:Skin(key, 'cap', 'BACKGROUND', 0))
		key.skin.kitMaxCorner = 6
		Kit:FitSprite(key.skin, key:GetWidth(), key:GetHeight())
		key.top = Own(CreateFrame('Frame', nil, tab))
		key.top:SetAllPoints(key)
		key.top:SetFrameLevel(tab:GetFrameLevel() + 2)
		key.top:EnableMouse(false)
		-- The icon sits in a window cut into the key.
		if icon then
			key.window = Own(Kit:Texture(key.top, 'inset-6', 'ARTWORK', 0))
			Kit:Place(key.window, icon, 0, 0, 0, 0)
			key.window:SetVertexColor(0, 0, 0, 0.55)
		end
		-- The lamp sits in the key's top-left margin, clear of the icon.
		local lampPx = opts.lamp or 4
		key.led = Lamp(key.top, lampPx, false)
		local inset = Snap(key, max((key.margin - Px(key, lampPx)) / 2, 1))
		key.led:SetPoint('TOPLEFT', key, 'TOPLEFT', inset, -inset)
		if opts.glyph then
			key.glyph = Own(key.top:CreateTexture(nil, 'OVERLAY', nil, 1))
			SetGlyph(key.glyph, opts.glyph)
		end
		tabKeys[tab] = key
		selectedOf[tab] = opts.selected
		key:HookScript('OnSizeChanged', function() UI:Safe(FitTabKey, tab) end)
		-- Hover: the key brightens a touch.
		tab:HookScript('OnEnter', function() key.skin:SetAlpha(0.85) end)
		tab:HookScript('OnLeave', function() key.skin:SetAlpha(1) end)
		-- The game re-centers its icon on press and release; it goes back in the key.
		tab:HookScript('OnMouseDown', function(self, button) if button == 'LeftButton' then UI:Safe(FitTabKey, self, true) end end)
		tab:HookScript('OnMouseUp', function(self) UI:Safe(FitTabKey, self) end)
		-- Forever's side tabs are plain frames that take clicks by mouse-up.
		local clickScript = tab.HasScript and tab:HasScript('OnClick') and 'OnClick' or 'OnMouseUp'
		tab:HookScript(clickScript, function() P.Sound('tick', 'tab'); RepaintTabKeys() end)
		tab:HookScript('OnShow', RepaintTabKeys)
		FitTabKey(tab)
		PaintTabKey(tab)
		return key
	end

	-- Which glyph a tab gets, from its name, key or tooltip.
	local GLYPH_WORDS = {{'paperdoll', 'character'}, {'character', 'character'}, {'skill', 'professions'},
		{'profession', 'professions'}, {'honor', 'pvp'}, {'pvp', 'pvp'}, {'currenc', 'bag'}, {'token', 'bag'},
		{'quest', 'quest'}, {'achievement', 'achievements'}, {'statistic', 'meter'}, {'reputation', 'social'},
		{'faction', 'social'}, {'title', 'achievements'}, {'guild', 'guild'}}
	local function GlyphFor(tab)
		local words = {}
		local name = P.NameOf(tab)
		if name then words[#words + 1] = name end
		local ok, key = pcall(tab.GetParentKey, tab)
		if ok and type(key) == 'string' then words[#words + 1] = key end
		for _, field in ipairs({'frameName', 'tooltipText', 'tooltip', 'title', 'label'}) do
			local value = tab[field]
			if type(value) == 'string' and not IsSecret(value) then words[#words + 1] = value end
		end
		local text = table.concat(words, ' '):lower()
		for _, pair in ipairs(GLYPH_WORDS) do
			if text:find(pair[1], 1, true) then return pair[2] end
		end
		return 'character'
	end

	-- Forever's big side tabs (character, reputation, skills, PvP, currency, statistics).
	local MODE_GLYPHS = {PaperDollFrame = 'character', ReputationFrame = 'social', SkillsFrame = 'professions',
		PVPRankFrame = 'pvp', TokenFrame = 'bag', StatisticsFrame = 'meter'}

	local function ModeChosen(tab)
		if Is(tab.SelectedTexture, 'Texture') then return tab.SelectedTexture:IsShown() end
		if type(tab.isSelected) == 'boolean' then return tab.isSelected end
		return false
	end

	-- The game resets the crop whenever it sets a portrait or the icon size.
	local function CropModeIcon(tab)
		local key = tabKeys[tab]
		if key and key.icon then
			if tab.Mask and key.icon.RemoveMaskTexture then pcall(key.icon.RemoveMaskTexture, key.icon, tab.Mask) end
			CropIcon(key.icon, 0.1)
			FitTabKey(tab)
		end
	end

	CropModeIcons = function(frame)
		local tabs = type(frame) == 'table' and type(frame.ModeTabs) == 'table' and frame.ModeTabs.Tabs
		if type(tabs) ~= 'table' then return end
		for _, tab in ipairs(tabs) do UI:Safe(CropModeIcon, tab) end
		RepaintTabKeys()
	end

	ModeTab = function(tab)
		if P.Forbidden(tab) or not tab.GetRegions or not First('sidetab', tab) then return end
		local icon = Is(tab.Icon, 'Texture') and tab.Icon or nil
		HideTextures(tab, icon and {[icon] = true} or nil)
		for _, part in ipairs({'Background', 'HighlightTexture', 'SelectedTexture'}) do Hide(tab[part]) end
		-- The "look here" glow pulses its alpha; it is emptied instead.
		if Is(tab.TabGlow, 'Texture') then tab.TabGlow:SetColorTexture(0, 0, 0, 0) end
		P.HideButtonArt(tab)
		local frameName = type(tab.frameName) == 'string' and tab.frameName or nil
		TabKey(tab, icon, {inset = {3, -2, -2, 2}, margin = 7, lamp = 5, fallback = 52,
			glyph = (frameName and MODE_GLYPHS[frameName]) or GlyphFor(tab), selected = ModeChosen})
		if type(tab.UpdateIconInterior) == 'function' then
			hooksecurefunc(tab, 'UpdateIconInterior', function(self) UI:Safe(CropModeIcon, self); RepaintTabKeys() end)
		end
		CropModeIcon(tab)
	end

	-- The stats pane's tabs (stats, titles, equipment sets, pet).
	local SIDEBAR_GLYPHS = {PAPERDOLL_SIDEBARTAB_STATS = 'meter', PAPERDOLL_SIDEBARTAB_TITLES = 'achievements',
		PAPERDOLL_SIDEBARTAB_EQUIPMENTMANAGER = 'drawer', PAPERDOLL_SIDEBARTAB_PET = 'collections'}
	local function SidebarGlyph(tab)
		local list = _G.PAPERDOLL_SIDEBARS
		local ok, id = pcall(tab.GetID, tab)
		local entry = ok and type(list) == 'table' and list[id]
		if type(entry) == 'table' then
			for name, glyph in pairs(SIDEBAR_GLYPHS) do
				if _G[name] == entry then return glyph end
			end
		end
		return GlyphFor(tab)
	end

	-- Chosen when the pane it opens is showing (Retail's tabs are plain buttons).
	local function SidebarChosen(tab)
		local get = _G.GetPaperDollSideBarFrame
		if type(get) == 'function' then
			local ok, pane = pcall(get, tab:GetID())
			if ok and type(pane) == 'table' and pane.IsShown then return pane:IsShown() and true or false end
		end
		if tab.GetChecked then
			local ok, checked = pcall(tab.GetChecked, tab)
			if ok and not IsSecret(checked) then return checked and true or false end
		end
		return false
	end

	SidebarTab = function(tab)
		if P.Forbidden(tab) or not tab.GetRegions or not First('sidebartab', tab) then return end
		-- Named like a tab, so the generic walk would give it a segmented-tab
		-- back as well: claimed here, and that back hidden if it came first.
		First('tab', tab)
		for _, child in ipairs({tab:GetChildren()}) do
			if P.IsOwn(child) then child:Hide() end
		end
		local icon = Is(tab.Icon, 'Texture') and tab.Icon or nil
		for _, part in ipairs({'hover', 'pushed', 'checked', 'TabBg', 'Highlight', 'Hider'}) do Hide(tab[part]) end
		HideTextures(tab, icon and {[icon] = true} or nil)
		P.HideButtonArt(tab)
		if tab.GetCheckedTexture then Hide(tab:GetCheckedTexture()) end
		-- The icons come from a sheet by texture coordinates (or the portrait):
		-- they are moved into the key but never re-cropped.
		TabKey(tab, icon, {shrink = 4, margin = 5, lamp = 4, fallback = 36, glyph = SidebarGlyph(tab),
			selected = SidebarChosen})
	end

	-- The right pane's toggle: a charcoal key with a chevron.
	PaneToggle = function(frame)
		local toggle = frame.RightPaneToggleButton
		if not Is(toggle, 'Button') or not First('charpanetoggle', toggle) then return end
		P.HideButtonArt(toggle)
		HideTextures(toggle)
		local cap = P.Keycap(toggle, false, 4)
		local chevron = Own(Kit:Icon(cap, 'chevron-left', Snap(toggle, 10), 'darkInk'))
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
end

-- Stats --------------------------------------------------------------------------------------
local rules = setmetatable({}, {__mode = 'k'}) -- header row -> its rule
local function Rule(row, inset)
	local rule = rules[row]
	if not rule then
		rule = Own(row:CreateTexture(nil, 'ARTWORK'))
		rule:SetColorTexture(1, 1, 1, 1)
		Kit:Tint(rule, 'darkEdge')
		rules[row] = rule
	end
	rule:ClearAllPoints()
	rule:SetPoint('BOTTOMLEFT', row, 'BOTTOMLEFT', inset or 4, 1)
	rule:SetPoint('BOTTOMRIGHT', row, 'BOTTOMRIGHT', -(inset or 4), 1)
	rule:SetHeight(Px(row, 1))
	return rule
end

local StatsPane, RetailStats, StatCategory
do
	local shades = setmetatable({}, {__mode = 'k'}) -- stat row -> its zebra shade

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
		elseif r + g + b > 2.4 or (r > 0.9 and g > 0.6 and b < 0.3) then value:SetTextColor(Kit:RGB('darkInk')) end
	end

	local function Legend(label)
		local text = label:GetText()
		if IsSecret(text) or type(text) ~= 'string' then return end
		local printed = Upper((text:gsub(':%s*$', '')))
		if printed ~= text then label:SetText(printed) end
	end

	-- A printed small-caps header on a rule; the space above it parts the sections.
	StatCategory = function(row)
		if type(row) ~= 'table' or P.Forbidden(row) then return end
		Hide(row.Background)
		local title = row.Title
		if Is(title, 'FontString') then
			if First('statcat', title) then Kit:Font(title, 8, nil, true) end
			title:SetTextColor(Kit:RGB('darkDim'))
			title:SetShadowOffset(0, 0)
			Legend(title)
			if not P.Locked(row) then
				title:ClearAllPoints()
				title:SetPoint('BOTTOMLEFT', row, 'BOTTOMLEFT', 6, 5)
				title:SetJustifyH('LEFT')
			end
		end
		Rule(row)
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
			row.Label:SetShadowOffset(0, 0)
			Legend(row.Label)
		end
		if Is(row.Value, 'FontString') then
			if First('statvalue', row.Value) then Kit:Font(row.Value, 11, nil, true, 'numbers') end
			row.Value:SetShadowOffset(0, 0)
			RecolorValue(row.Value)
		end
		-- Resistance icons are atlases (left uncropped); file icons are cropped.
		CropIcon(row.Icon)
	end

	StatsPane = function(pane)
		if type(pane) ~= 'table' or P.Forbidden(pane) or not First('statspane', pane) then return end
		P.Strip(pane)
		Screened(pane)
		Screened(pane.ScrollBox)
		Hide(pane.ClassBackground)
		Hide(pane.Border)
		P.ScrollBar(pane.ScrollBar)
		WatchBox(pane.ScrollBox, StatRow)
	end

	-- The average item level on an LCD.
	local function ItemLevelReadout(frame)
		if type(frame) ~= 'table' or P.Forbidden(frame) or not Is(frame.Value, 'FontString') then return end
		if First('ilvlcd', frame) then
			Hide(frame.Background)
			local lcd = Own(Kit:LCDPanel(frame, {radius = 4}))
			Own(lcd.shell)
			Own(lcd.inner)
			lcd:SetPoint('CENTER', frame, 'CENTER', 0, 0)
			lcd:SetSize(Snap(frame, 84), Snap(frame, 24))
			lcd:SetFrameLevel(max(frame:GetFrameLevel() - 1, 1))
			lcd:EnableMouse(false)
			Kit:Font(frame.Value, 16, nil, true, 'numbers')
			frame.Value:SetShadowOffset(0, 0)
		end
		frame.Value:SetTextColor(Kit:RGB('lcdInk'))
	end

	-- Retail's stats pane: rows from a pool, refreshed by PaperDollFrame_UpdateStats.
	RetailStats = function()
		local pane = _G.CharacterStatsPane
		if type(pane) ~= 'table' then return end
		local pool = pane.statsFramePool
		if pool and pool.EnumerateActive then
			for row in pool:EnumerateActive() do UI:Safe(StatRow, row) end
		end
		for _, key in ipairs({'ItemLevelCategory', 'AttributesCategory', 'EnhancementsCategory'}) do
			UI:Safe(StatCategory, pane[key])
		end
		UI:Safe(ItemLevelReadout, pane.ItemLevelFrame)
	end
end

-- Lists and side panes ---------------------------------------------------------------------
local ColoredBar, ListFrame, SidePane
do
	local plates = setmetatable({}, {__mode = 'k'})

	-- The game's colored progress bars (reputation, skills, the pet's
	-- experience; Forever's are plain frames with a sized fill texture): a dot
	-- meter on a black track. The fill keeps its own color; a perforated cover
	-- in the screen's black lets it show through as lit dots.
	ColoredBar = function(bar)
		if type(bar) ~= 'table' or P.Forbidden(bar) or not Is(bar.Fill, 'Texture') then return end
		if not First('coloredbar', bar) then return end
		-- Claimed, so the walk's status-bar dressing (which would hide the fill) passes it by.
		First('bar', bar)
		-- If that dressing came first, its parts go and the fill comes back.
		for _, child in ipairs({bar:GetChildren()}) do
			if P.IsOwn(child) then child:Hide() end
		end
		for _, region in ipairs({bar:GetRegions()}) do
			if Art(region) and region ~= bar.Fill then region:SetAlpha(0) end
		end
		bar.Fill:SetAlpha(1)
		local _, fillHeight = P.Size(bar.Fill)
		if fillHeight <= 0 then fillHeight = 15 end
		local area = type(bar.FillArea) == 'table' and bar.FillArea or bar
		-- The band the fill draws in.
		local band = Own(CreateFrame('Frame', nil, bar))
		band:SetPoint('LEFT', area, 'LEFT', 0, 0)
		band:SetPoint('RIGHT', area, 'RIGHT', 0, 0)
		band:SetHeight(fillHeight)
		band:SetFrameLevel(max(bar:GetFrameLevel() - 1, 0))
		band:EnableMouse(false)
		local track = Own(CreateFrame('Frame', nil, band))
		local pad = Snap(bar, 2)
		track:SetPoint('TOPLEFT', band, 'TOPLEFT', -pad, pad)
		track:SetPoint('BOTTOMRIGHT', band, 'BOTTOMRIGHT', pad, -pad)
		track:SetFrameLevel(band:GetFrameLevel())
		track:EnableMouse(false)
		Own(Kit:Shell(track, {surface = 'screen', radius = 3, shadow = false}))
		-- Unlit dots under the fill, the cover over it (and under the bar's text).
		local under = Own(bar:CreateTexture(nil, 'BACKGROUND', nil, 7))
		local cover = Own(bar:CreateTexture(nil, 'BORDER', nil, 7))
		under:SetTexture(Kit.media..'tile-dot.tga', 'REPEAT', 'REPEAT')
		cover:SetTexture(Kit.media..'tile-perf.tga', 'REPEAT', 'REPEAT')
		Kit:Tint(under, 'darkEdge')
		Kit:Tint(cover, 'screenFill')
		for _, texture in ipairs({under, cover}) do
			texture:SetAllPoints(band)
			texture:SetHorizTile(true)
			texture:SetVertTile(false)
			if texture.SetScale then texture:SetScale(fillHeight / 16) end
		end
		local text = bar.Text
		if Is(text, 'FontString') then
			Kit:Font(text, 9, nil, true)
			text:SetTextColor(Kit:RGB('darkInk'))
			text:SetShadowOffset(1, -1)
			text:SetShadowColor(0, 0, 0, 1)
		end
		if Is(bar.BonusIcon, 'Frame') and Is(bar.BonusIcon.Texture, 'Texture') then
			bar.BonusIcon.Texture:SetDesaturated(true)
		end
	end

	-- A bar: the game's colored bar, or a native status bar.
	local function AnyBar(bar)
		if type(bar) ~= 'table' or P.Forbidden(bar) then return end
		if Is(bar.Fill, 'Texture') then ColoredBar(bar)
		elseif Is(bar, 'StatusBar') then P.StatusBar(bar) end
	end

	-- A sub-header's collapse button: a small charcoal key with plus or minus.
	local marks = setmetatable({}, {__mode = 'k'}) -- button -> its mark
	local function PaintCollapse(button)
		local mark = marks[button]
		if not mark then return end
		local ok, collapsed = pcall(function() return button:GetParent():IsCollapsed() end)
		if not ok or IsSecret(collapsed) then return end
		Kit:SetIcon(mark, collapsed and 'plus' or 'minus')
	end

	local function CollapseKey(button)
		if not Is(button, 'Button') or not First('collapsekey', button) then return end
		P.HideButtonArt(button)
		HideTextures(button)
		local cap = Own(CreateFrame('Frame', nil, button))
		local side = Snap(button, 14)
		cap:SetSize(side, side)
		cap:SetPoint('CENTER')
		cap:SetFrameLevel(button:GetFrameLevel())
		cap:EnableMouse(false)
		cap.skin = Own(Kit:Skin(cap, 'cap', 'BACKGROUND', 0))
		cap.skin.kitMaxCorner = 3
		Kit:FitSprite(cap.skin, side, side)
		local mark = Own(Kit:Icon(cap, 'minus', Snap(button, 8), 'darkInk'))
		mark:SetPoint('CENTER')
		marks[button] = mark
		if type(button.RefreshIcon) == 'function' then
			hooksecurefunc(button, 'RefreshIcon', function(self) UI:Safe(PaintCollapse, self) end)
		end
		button:HookScript('OnMouseDown', function() Kit:SetSprite(cap.skin, 'cap-in') end)
		button:HookScript('OnMouseUp', function() Kit:SetSprite(cap.skin, 'cap') end)
		PaintCollapse(button)
	end

	-- Top-level headers: glass plates with printed capitals.
	local function ListHeader(row)
		local keep = {}
		local state = row.StateIcon
		if Is(state, 'Texture') then
			keep[state] = true
			if state.SetDesaturated then state:SetDesaturated(true) end
			Kit:Tint(state, 'darkDim')
		end
		HideTextures(row, keep)
		if not plates[row] then
			local plate = P.Back(row, {surface = 'glass', radius = 4, shadow = false}, 0, -1, 0, -1)
			plate:SetFrameLevel(max(row:GetFrameLevel() - 1, 0))
			Kit:Relevel(plate)
			plates[row] = plate
		end
		for _, region in ipairs({row:GetRegions()}) do
			if Is(region, 'FontString') and not P.IsOwn(region) then
				if First('listhead', region) then Kit:Font(region, 9, nil, true) end
				region:SetTextColor(Kit:RGB('darkInk'))
				region:SetShadowOffset(0, 0)
				PrintUpper(region)
			end
		end
	end

	local function ListEntry(row)
		if Is(row.ToggleCollapseButton, 'Button') then CollapseKey(row.ToggleCollapseButton) end
		local content = row.Content
		if type(content) ~= 'table' then
			P.RelightRegions(row)
			UngildTree(row, 2)
			return
		end
		local highlight = content.BackgroundHighlight
		if type(highlight) == 'table' and type(highlight.TextureRegions) == 'table' and First('listhl', highlight) then
			for _, region in ipairs(highlight.TextureRegions) do Wash(region, 'lamp', 0.12) end
		end
		AnyBar(content.ReputationBar or content.SkillsBar)
		CropIcon(content.CurrencyIcon)
		CheckMark(content.WatchedCurrencyCheck, 'lamp')
		if type(content.ParagonIcon) == 'table' then Hide(content.ParagonIcon.Glow) end
		P.RelightRegions(content)
		UngildTree(content, 1)
	end

	local function ListRow(row)
		if P.Forbidden(row) then return end
		if row.StateIcon then ListHeader(row) else ListEntry(row) end
	end

	-- The thin gold lines the game hangs above and below a list.
	local function HideLooseArt(box)
		if type(box) ~= 'table' or P.Forbidden(box) or not box.GetChildren then return end
		for _, child in ipairs({box:GetChildren()}) do
			if child ~= box.ScrollTarget and not P.IsOwn(child) and not P.Forbidden(child) and child.GetRegions
				and child:GetNumChildren() == 0 then
				HideTextures(child)
			end
		end
	end

	ListFrame = function(frame)
		if type(frame) ~= 'table' or P.Forbidden(frame) or not frame.ScrollBox or not First('charlist', frame) then return end
		P.Strip(frame)
		P.ScrollBar(frame.ScrollBar)
		HideLooseArt(frame.ScrollBox)
		-- Forever sets its lists straight on the housing: a black screen under
		-- each (the scroll bar inside it). Retail's already sit in an inset.
		local character = _G.CharacterFrame
		if type(character) == 'table' and type(character.LeftPaneHost) == 'table' and frame:GetParent() == character then
			local back = Own(CreateFrame('Frame', nil, frame))
			back:SetPoint('TOPLEFT', frame.ScrollBox, 'TOPLEFT', -Snap(frame, 6), Snap(frame, 4))
			back:SetPoint('BOTTOMRIGHT', frame.ScrollBox, 'BOTTOMRIGHT', Snap(frame, 21), -Snap(frame, 6))
			back:EnableMouse(false)
			Own(Kit:Shell(back, {surface = 'screen', radius = 6, shadow = false}))
			Screened(frame)
			Screened(frame.ScrollBox)
		end
		WatchBox(frame.ScrollBox, ListRow)
	end

	-- Side panes' rows: category rows printed on a rule, label rows in dim print
	-- with their values in ink, icon rows' icons without the game's slot frame.
	local function SideRows(pane)
		local pools = pane.rowPools
		if type(pools) ~= 'table' or not pools.EnumerateActive then return end
		for row in pools:EnumerateActive() do
			if Is(row.Background, 'Texture') then
				row.Background:SetAlpha(0)
				for _, region in ipairs({row:GetRegions()}) do
					if Is(region, 'FontString') and not P.IsOwn(region) then
						if First('sidecat', region) then Kit:Font(region, 8, nil, true) end
						region:SetTextColor(Kit:RGB('darkDim'))
						PrintUpper(region)
					end
				end
				Rule(row)
			else
				if row.IconSlot then Hide(row.IconSlot) end
				if Is(row.Value, 'FontString') then
					Ungild(row.Label, 'darkDim')
					Ungild(row.Value, 'darkInk')
				else
					Ungild(row.Label, 'darkInk')
				end
			end
			P.RelightRegions(row)
		end
		UngildTree(pane, 3)
	end

	SidePane = function(pane)
		if type(pane) ~= 'table' or P.Forbidden(pane) or not First('charside', pane) then return end
		P.Strip(pane)
		Hide(pane.Divider)
		if Is(pane.Title, 'FontString') then
			Kit:Font(pane.Title, 12, nil, true)
			pane.Title:SetTextColor(Kit:RGB('darkInk'))
		end
		if Is(pane.Subtitle, 'FontString') then pane.Subtitle:SetTextColor(Kit:RGB('darkDim')) end
		if Is(pane.EmptyText, 'FontString') then pane.EmptyText:SetTextColor(Kit:RGB('darkDim')) end
		-- A rule where the game's gold divider was.
		if Is(pane.Divider, 'Texture') then
			local rule = Own(pane:CreateTexture(nil, 'ARTWORK'))
			rule:SetColorTexture(1, 1, 1, 1)
			Kit:Tint(rule, 'darkEdge')
			rule:SetPoint('TOPLEFT', pane.Divider, 'TOPLEFT', 0, 0)
			rule:SetPoint('TOPRIGHT', pane.Divider, 'TOPRIGHT', 0, 0)
			rule:SetHeight(Px(pane, 1))
		end
		P.ScrollBar(pane.DescriptionScrollBar)
		for _, key in ipairs({'StandingBar', 'RankBar'}) do AnyBar(pane[key]) end
		for _, key in ipairs({'AtWarCheckbox', 'MakeInactiveCheckbox', 'WatchFactionCheckbox', 'InactiveCheckbox',
			'BackpackCheckbox'}) do
			if Is(pane[key], 'CheckButton') then UI:Safe(P.Checkbox, pane[key]) end
		end
		if Is(pane.ViewRenownButton, 'Button') then UI:Safe(P.PushButton, pane.ViewRenownButton) end
		local queued = Debounce(function() SideRows(pane) end)
		if type(pane.AcquireRow) == 'function' then hooksecurefunc(pane, 'AcquireRow', queued) end
		if type(pane.Refresh) == 'function' then hooksecurefunc(pane, 'Refresh', queued) end
		pane:HookScript('OnShow', function() queued(); P.Queue(pane) end)
		queued()
		P.Queue(pane)
	end
end

-- PvP rank (Forever) ---------------------------------------------------------------------
-- The rank dial: a lamp-colored ring on a black disc where the game's painted
-- honor ring was, the rank badge relit in monochrome, the fields in screen print.
local PvPRank
do
	local function Dial(dial)
		if not Is(dial, 'Cooldown') or not First('pvpdial', dial) then return end
		for _, region in ipairs({dial:GetRegions()}) do
			if Art(region) and region ~= dial.FactionBadge then region:SetAlpha(0) end
		end
		local disc = Own(dial:CreateTexture(nil, 'BACKGROUND', nil, 2))
		disc:SetTexture(Kit.media..'circle.tga')
		Kit:Tint(disc, 'screenFill')
		disc:SetAllPoints(dial)
		local ring = Own(dial:CreateTexture(nil, 'BORDER', nil, 2))
		ring:SetTexture(Kit.media..'circle-ring.tga')
		Kit:Tint(ring, 'darkEdge')
		ring:SetAllPoints(dial)
		if dial.SetSwipeTexture then
			local r, g, b = Kit:RGB('lamp')
			dial:SetSwipeTexture(Kit.media..'circle-ring.tga', r, g, b, 1)
		end
		if dial.SetDrawEdge then dial:SetDrawEdge(false) end
		local badge = dial.FactionBadge
		if Is(badge, 'Texture') then
			badge:SetDesaturated(true)
			badge:SetVertexColor(0.92, 0.92, 0.88, 0.9)
		end
		local reward = dial.NextRewardLevel
		if type(reward) == 'table' and not P.Forbidden(reward) then
			if Is(reward.RingBorder, 'Texture') then
				reward.RingBorder:SetTexture(Kit.media..'circle-ring.tga')
				reward.RingBorder:SetTexCoord(0, 1, 0, 1)
				Kit:Tint(reward.RingBorder, 'darkDim')
			end
			if Is(reward.IconCover, 'Texture') then
				reward.IconCover:SetTexture(Kit.media..'circle.tga')
				Kit:Tint(reward.IconCover, 'glass')
			end
			if Is(reward.LevelLabel, 'FontString') then
				Kit:Font(reward.LevelLabel, 13, nil, true, 'numbers')
				reward.LevelLabel:SetTextColor(Kit:RGB('darkInk'))
				reward.LevelLabel:SetShadowOffset(0, 0)
			end
			P.HideButtonArt(reward)
		end
	end

	PvPRank = function(rank)
		if type(rank) ~= 'table' or P.Forbidden(rank) or not First('pvprank', rank) then return end
		local info = rank.MainInfoFrame
		if type(info) == 'table' then
			Hide(info.Line)
			local fields = {CurrentSeasonField = {9, 'darkDim'}, CurrentRankField = {13, 'darkInk'},
				CurrentRankProgressField = {10, 'darkDim'}}
			for key, look in pairs(fields) do
				local field = info[key]
				if Is(field, 'FontString') then
					Kit:Font(field, look[1], nil, true)
					field:SetTextColor(Kit:RGB(look[2]))
					field:SetShadowOffset(0, 0)
				end
			end
			Dial(info.RankProgressBarDisplay)
		end
		if Is(rank.SeasonTimerField, 'FontString') then
			Kit:Font(rank.SeasonTimerField, 9, nil, false)
			rank.SeasonTimerField:SetTextColor(Kit:RGB('darkDim'))
		end
		SidePane(rank.DetailFrame)
	end
end

-- Titles and equipment sets ------------------------------------------------------------------
local Managers
do
	local OUTFIT_ART = {['UI-Character-Info-OutfitCard'] = true, ['UI-Character-Info-OutfitIcon-Frame'] = true}

	local function TitleRow(row)
		if P.Forbidden(row) then return end
		if First('titlerow', row) then
			for _, region in ipairs({row:GetRegions()}) do
				if Art(region) and region:GetDrawLayer() == 'BACKGROUND' then region:SetAlpha(0) end
			end
			Hide(row.Stripe)
			Wash(row.GetHighlightTexture and row:GetHighlightTexture(), 'white', 0.06)
			Wash(row.SelectedBar, 'lamp', 0.16)
			Wash(row.HighlightBar, 'white', 0.06)
			CheckMark(row.Check, 'lamp')
			P.SetFonts(row, P.fonts.key, P.fonts.keyHot, P.fonts.keyDim)
		end
		P.RelightRegions(row)
		Ungild(row.text)
	end

	-- A set's delete and edit keys: the kit's close and gear glyphs.
	local function SetKeys(row)
		local delete, edit = row.DeleteButton, row.EditButton
		if Is(delete, 'Button') and Is(delete.texture, 'Texture') and First('setdelete', delete) then
			delete.texture:SetTexture(Kit.media..'icons.tga')
			Kit:SetIcon(delete.texture, 'close')
			Kit:Tint(delete.texture, 'darkInk')
		end
		if Is(edit, 'Button') and Is(edit.texture, 'Texture') and First('setedit', edit) then
			SetGlyph(edit.texture, 'menu')
			Kit:Tint(edit.texture, 'darkInk')
		end
	end

	local function OutfitRow(row)
		if P.Forbidden(row) then return end
		if First('outfitrow', row) then
			for _, region in ipairs({row:GetRegions()}) do
				if Art(region) then
					local atlas = region.GetAtlas and region:GetAtlas()
					local keepIt = region == row.SelectedBar or region == row.HighlightBar or region == row.icon
						or region == row.Check or region == row.SpecIcon
					if not keepIt and ((not IsSecret(atlas) and atlas and OUTFIT_ART[atlas]) or region:GetDrawLayer() == 'BACKGROUND') then
						region:SetAlpha(0)
					end
				end
			end
			local plate = P.Back(row, {surface = 'glass', radius = 4, shadow = false}, 0, 0, -7, 0)
			plate:SetFrameLevel(max(row:GetFrameLevel() - 1, 0))
			Kit:Relevel(plate)
			Wash(row.SelectedBar, 'lamp', 0.18)
			Wash(row.HighlightBar, 'white', 0.07)
			CheckMark(row.Check, 'lamp')
			Hide(row.SpecRing)
			SetKeys(row)
		end
		CropIcon(row.icon)
		CropIcon(row.SpecIcon)
		P.RelightRegions(row)
		-- Set names print in ink; a set missing items stays red.
		Ungild(row.text)
	end

	-- "New set": a charcoal key with the kit's plus.
	local function NewSetKey(button)
		if not Is(button, 'Button') or not First('newset', button) then return end
		HideTextures(button)
		P.HideButtonArt(button)
		local cap = P.Keycap(button, false)
		local plus = Own(Kit:Icon(cap, 'plus', Snap(button, 10), 'darkInk'))
		plus:SetPoint('LEFT', cap, 'LEFT', Snap(button, 14), 0)
		for _, region in ipairs({button:GetRegions()}) do
			if Is(region, 'FontString') and not P.IsOwn(region) then
				Kit:Font(region, 10, nil, true)
				region:SetTextColor(Kit:RGB('darkInk'))
				region:SetShadowOffset(0, 0)
			end
		end
	end

	Managers = function(paperDoll)
		local titles, sets = paperDoll.TitleManagerPane, paperDoll.EquipmentManagerPane
		if type(titles) == 'table' and not P.Forbidden(titles) then
			P.Strip(titles)
			P.ScrollBar(titles.ScrollBar)
			WatchBox(titles.ScrollBox, TitleRow)
		end
		if type(sets) == 'table' and not P.Forbidden(sets) then
			P.Strip(sets)
			P.ScrollBar(sets.ScrollBar)
			WatchBox(sets.ScrollBox, OutfitRow)
			for _, key in ipairs({'EquipSet', 'SaveSet'}) do
				local button = sets[key]
				if Is(button, 'Button') then
					Hide(button.StateTexture)
					P.PushButton(button)
				end
			end
			NewSetKey(sets.NewSet)
		end
	end
end

-- The alt-swap flyout ----------------------------------------------------------------------
local Popout, Flyout
do
	local chevrons = setmetatable({}, {__mode = 'k'})
	local FLIP = {RIGHT = 'LEFT', LEFT = 'RIGHT', UP = 'DOWN', DOWN = 'UP'}

	Popout = function(button)
		if P.Forbidden(button) then return end
		P.HideButtonArt(button)
		local chevron = chevrons[button]
		if not chevron then
			local lid = Own(CreateFrame('Frame', nil, button))
			lid:SetAllPoints()
			lid:EnableMouse(false)
			lid:SetFrameLevel(button:GetFrameLevel() + 1)
			chevron = Own(Kit:Icon(lid, 'chevron-right', Snap(button, 9), 'darkInk'))
			chevron:SetPoint('CENTER')
			chevrons[button] = chevron
		end
		local parent = button:GetParent()
		local direction = (parent and parent.flyoutDirection) or button.flyoutDirection
			or (parent and parent.verticalFlyout and 'UP') or 'RIGHT'
		if IsSecret(direction) or type(direction) ~= 'string' then direction = 'RIGHT' end
		if button.flyoutLocked == true then direction = FLIP[direction] or direction end
		Kit:SetIcon(chevron, 'chevron-'..direction:lower())
	end

	-- The flyout's page keys (Forever): charcoal caps with chevrons.
	local function Navigation(nav)
		if type(nav) ~= 'table' or P.Forbidden(nav) or not First('flyoutnav', nav) then return end
		Hide(nav.BottomBackground)
		Own(Kit:Shell(nav, {surface = 'glass', radius = 6, shadowAlpha = 0.45}))
		for key, icon in pairs({PrevButton = 'chevron-left', NextButton = 'chevron-right'}) do
			local button = nav[key]
			if Is(button, 'Button') then
				P.HideButtonArt(button)
				local cap = P.Keycap(button, false, 4)
				local side = Snap(button, 22)
				cap:ClearAllPoints()
				cap:SetPoint('CENTER', button, 'CENTER', 0, 0)
				cap:SetSize(side, side)
				local mark = Own(Kit:Icon(cap, icon, Snap(button, 9), 'darkInk'))
				mark:SetPoint('CENTER')
			end
		end
		for _, key in ipairs({'PreviousPageText', 'NextPageText'}) do
			local text = nav[key]
			if Is(text, 'FontString') then
				Kit:Font(text, 8, nil, true)
				text:SetTextColor(Kit:RGB('darkDim'))
			end
		end
	end

	Flyout = function()
		local flyout = _G.EquipmentFlyoutFrame
		if type(flyout) ~= 'table' or P.Forbidden(flyout) then return end
		local frame = flyout.buttonFrame
		if type(frame) == 'table' then
			for index = 1, tonumber(frame.numBGs) or 1 do Hide(frame['bg'..index]) end
			if First('flyoutglass', frame) then Own(Kit:Shell(frame, {surface = 'glass', radius = 6, shadowAlpha = 0.45})) end
		end
		Hide(_G.EquipmentFlyoutFrameHighlight)
		Hide(flyout.Highlight)
		Navigation(flyout.NavigationFrame)
		for _, button in ipairs(type(flyout.buttons) == 'table' and flyout.buttons or {}) do UI:Safe(P.Item, button) end
	end
end

-- Putting it together ------------------------------------------------------------------------
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
	for led in pairs(lamps) do UI:Safe(FitLamp, led) end
	LayoutSoon()
	RepaintTabKeys()
end

function module.CharacterExtras(frame)
	if not First('charextras', frame) then return end
	for _, slot in ipairs(SLOTS) do
		local button = _G['Character'..slot[1]..'Slot']
		if type(button) == 'table' then UI:Safe(DressSlot, button, slot[2], slot[3]) end
	end
	if type(_G.PaperDollItemSlotButton_Update) == 'function' then
		hooksecurefunc('PaperDollItemSlotButton_Update', function(button)
			if slots[button] then UI:Safe(UpdateSlot, button) end
		end)
	end
	UI:Safe(ModelScreen, _G.CharacterModelScene)
	UI:Safe(Title, _G.CharacterLevelText)
	UI:Safe(Title, _G.PetCharacterLevelText)
	UI:Safe(PaneToggle, frame)
	-- Forever's big side tabs, the stats pane's sidebar tabs and Retail's bottom tabs.
	local modeTabs = type(frame.ModeTabs) == 'table' and frame.ModeTabs.Tabs
	if type(modeTabs) == 'table' then
		for _, tab in ipairs(modeTabs) do UI:Safe(ModeTab, tab) end
	end
	local sidebar = _G.PaperDollSidebarTabs
	if type(sidebar) == 'table' and not P.Forbidden(sidebar) then P.Strip(sidebar) end
	for index = 1, 6 do
		local tab = _G['PaperDollSidebarTab'..index]
		if type(tab) == 'table' then UI:Safe(SidebarTab, tab) end
		local bottom = _G['CharacterFrameTab'..index]
		if type(bottom) == 'table' then UI:Safe(P.Tab, bottom) end
	end
	for _, name in ipairs({'UpdateTabLayout', 'SetSelectedModeTabByFrame', 'RefreshDisplay', 'OnModeTabClicked', 'ShowSubFrame',
		'SetTab', 'SelectTab', 'UpdateTabs'}) do
		if type(frame[name]) == 'function' then hooksecurefunc(frame, name, RepaintTabKeys) end
	end
	for _, name in ipairs({'UpdateCharacterModeTabPortrait', 'SetupModeTabs'}) do
		if type(frame[name]) == 'function' then hooksecurefunc(frame, name, function(self) UI:Safe(CropModeIcons, self) end) end
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
	UI:Safe(RetailStats)
	-- Panes.
	local reputation, tokens, skills = _G.ReputationFrame, _G.TokenFrame, _G.SkillsFrame
	UI:Safe(ListFrame, reputation)
	UI:Safe(ListFrame, tokens)
	UI:Safe(ListFrame, skills)
	UI:Safe(ListFrame, _G.StatisticsFrame)
	if type(reputation) == 'table' then UI:Safe(SidePane, reputation.ReputationDetailFrame) end
	if type(tokens) == 'table' then UI:Safe(SidePane, tokens.DetailFrame) end
	if type(skills) == 'table' then UI:Safe(SidePane, skills.SkillDetailFrame) end
	UI:Safe(PvPRank, _G.PVPRankFrame)
	UI:Safe(ColoredBar, _G.PetPaperDollFrameExpBar)
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
	frame:HookScript('OnSizeChanged', function() LayoutSoon() end)
	Refresh(frame)
end

-- Settings changed on the hub: repaint what is open.
Kit:OnRefresh(function()
	if next(slots) then UI:Safe(Refresh, _G.CharacterFrame) end
end)
