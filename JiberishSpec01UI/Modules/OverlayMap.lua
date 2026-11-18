-- The NV-4 overlay map: a see-through local map in the style of an action
-- game's overlay. Only the ground around you shows (100 to 600 yards from you
-- to the edge), drawn from the zone map's own art tiles at an adjustable
-- opacity, square or round, with an optional soft edge. North is up and your
-- arrow turns; or the map turns with you and a lit N rides the edge. The same
-- points of interest as the compass sit on it as small keys, your group as dots
-- in their class color, and your super-tracked target waits on the rim when it
-- is beyond it. Toggled with /spec map, a key binding or the hub; it never
-- takes the mouse, and it is placed with the other frames (/spec move).
--
-- The art: the zone map's detail layer (C_Map.GetMapArtLayers and
-- GetMapArtLayerTextures), its 256-texel tiles laid out as the world map lays
-- them, scaled from the map's size in yards. Only the tiles under the window
-- exist; north-up, they sit on one canvas frame that one anchor moves as you
-- walk. Turning with you, each of those few tiles (a handful at this zoom) is
-- turned and placed about you. Tiles are made again only when the map, the zoom
-- or the size changes. Nothing here touches the Blizzard minimap: these are
-- our own textures. In instances the game shares no position: NO SIGNAL.
local _, UI = ...
local Kit = UI.Kit
local Nav = UI.Navigation

local CreateFrame, UIParent, GetTime, InCombatLockdown = CreateFrame, UIParent, GetTime, InCombatLockdown
local floor, max, min, abs, ceil, sqrt, sin, cos = math.floor, math.max, math.min, math.abs, math.ceil, math.sqrt, math.sin, math.cos

local module = UI:RegisterModule('overlaymap', {always = true})

-- defaults:begin
UI:RegisterDefaults('overlaymap', {
	enable = true, shown = false, -- shown: toggled on (saved)
	shape = 'square', -- 'square' | 'round'
	size = 300, radius = 250, -- UI units; yards from you to the edge
	opacity = 0.6, backdrop = 0.3, fade = true,
	housing = 'bezel', -- 'bezel' | 'hairline' | 'none'
	rotate = false,
	pois = true, keySize = 14, group = true, arrowSize = 16, scaleChip = true, hideInCombat = false,
})
-- defaults:end

local function DB() return UI.db.overlaymap end
local function Reduced() return Kit:Reduced() end
local function Snap(value, px) return floor(value / px + 0.5) * px end
local function Clamp(value, low, high, fallback)
	value = type(value) == 'number' and value or fallback
	return max(low, min(high, value))
end

local holder, window, canvas, pins
local m = {} -- the layout: sizes and the tile grid
local tiles, spare = {}, {} -- tile index -> texture; unused textures
local masks = {}
local keys, freeKeys, dots = {}, {}, {}
local preview, fighting = false, false
local nearList, seen = {}, {}

local TILE_BUDGET = 36 -- tiles under the window, at most, when choosing a layer's detail
local SHADOW_PEAK = 0.6 -- the soft-square mask's plateau (Media/Hardware/shadow.tga)

-- Frame -----------------------------------------------------------------------------------
local function Bar(parent)
	local bar = CreateFrame('Frame', nil, parent)
	bar:EnableMouse(false)
	bar.shell = Kit:Shell(bar, {surface = 'paper', radius = 3, wall = true, shadowAlpha = 0.4})
	return bar
end

local function Build()
	holder = CreateFrame('Frame', 'JiberishSpec01OverlayMap', UIParent)
	holder:SetFrameStrata('LOW')
	holder:EnableMouse(false)
	holder:SetSize(300, 300)
	holder:Hide()
	-- Dark glass behind the art.
	holder.glass = CreateFrame('Frame', nil, holder)
	holder.glass:SetAllPoints()
	holder.glass:EnableMouse(false)
	holder.glass.shell = Kit:Shell(holder.glass, {surface = 'glass', radius = 6, alpha = 0.3, shadow = false})
	-- The art, clipped to the window.
	window = CreateFrame('Frame', nil, holder)
	window:SetAllPoints()
	window:SetClipsChildren(true)
	window:SetFrameLevel(holder:GetFrameLevel() + 3)
	window:EnableMouse(false)
	canvas = CreateFrame('Frame', nil, window)
	canvas:SetSize(1, 1)
	canvas:EnableMouse(false)
	-- Shape and soft edge: masks on every tile, fixed to the window.
	for _, name in ipairs({'round', 'fadeSquare', 'fadeRound'}) do
		local mask = canvas:CreateMaskTexture()
		mask:SetPoint('CENTER', window, 'CENTER', 0, 0)
		masks[name] = mask
	end
	masks.round:SetTexture(Kit.media..'mask-round.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
	masks.fadeSquare:SetTexture(Kit.media..'shadow.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
	masks.fadeRound:SetTexture(Kit.media..'glow.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
	-- The frame: a machined bezel (four bars, or a ring), or hairlines.
	holder.frame = CreateFrame('Frame', nil, holder)
	holder.frame:SetAllPoints()
	holder.frame:SetFrameLevel(holder:GetFrameLevel() + 6)
	holder.frame:EnableMouse(false)
	holder.bars = {Bar(holder.frame), Bar(holder.frame), Bar(holder.frame), Bar(holder.frame)}
	holder.ring = Kit:Texture(holder.frame, 'bezel-ring', 'ARTWORK', 1)
	holder.ring:SetPoint('CENTER')
	holder.hair = {}
	for index = 1, 4 do
		local line = holder.frame:CreateTexture(nil, 'ARTWORK', nil, 2)
		line:SetColorTexture(1, 1, 1, 1)
		holder.hair[index] = line
	end
	holder.brackets = {}
	for index = 1, 8 do
		local piece = holder.frame:CreateTexture(nil, 'ARTWORK', nil, 3)
		piece:SetColorTexture(1, 1, 1, 1)
		holder.brackets[index] = piece
	end
	-- Points, group and your arrow, over the art and never masked.
	pins = CreateFrame('Frame', nil, holder)
	pins:SetAllPoints()
	pins:SetFrameLevel(holder:GetFrameLevel() + 8)
	pins:EnableMouse(false)
	holder.arrowGlow = Kit:Texture(pins, 'glow', 'ARTWORK', 1)
	holder.arrowGlow:SetBlendMode('ADD')
	holder.arrowGlow:SetPoint('CENTER')
	holder.arrow = {}
	for index = 1, 4 do
		local line = pins:CreateLine(nil, 'OVERLAY', nil, 6)
		line:SetColorTexture(1, 1, 1, 1)
		holder.arrow[index] = line
	end
	holder.north = Kit:Text(pins, 'N', 9, 'lamp', true, true)
	holder.scale = Kit:LCDPanel(pins, {radius = 2})
	holder.scale:SetSize(54, 11)
	holder.scale:SetFrameLevel(pins:GetFrameLevel() + 4)
	Kit:Relevel(holder.scale)
	holder.scale.text = Kit:Text(holder.scale, '', 7, 'lcdInk', true)
	Kit:Font(holder.scale.text, 7, nil, true, 'numbers')
	holder.scale.text:SetPoint('CENTER')
	holder.scale.text:SetShadowOffset(0, 0)
	holder.signal = CreateFrame('Frame', nil, pins)
	holder.signal:SetSize(90, 12)
	holder.signal:SetPoint('CENTER', 0, 0)
	holder.signal:SetFrameLevel(pins:GetFrameLevel() + 6)
	holder.signal.text = Kit:Label(holder.signal, 'No signal', 'red', 8, true)
	holder.signal.text:SetPoint('CENTER', 4, 0)
	holder.signal.led = Kit:Led(holder.signal, 5, true)
	Kit:SetLed(holder.signal.led, true, 'red')
	holder.signal.led:SetPoint('RIGHT', holder.signal.text, 'LEFT', -4, 0)
	holder.signal:Hide()
end

-- Layout --------------------------------------------------------------------------------------
local function LayoutFrame(size, round, px)
	local housing = DB().housing or 'bezel'
	local thick = 6
	for index, bar in ipairs(holder.bars) do
		bar:ClearAllPoints()
		bar:SetShown(housing == 'bezel' and not round)
		if index == 1 then
			bar:SetPoint('BOTTOMLEFT', holder, 'TOPLEFT', -thick, 0)
			bar:SetPoint('BOTTOMRIGHT', holder, 'TOPRIGHT', thick, 0)
			bar:SetHeight(thick)
		elseif index == 2 then
			bar:SetPoint('TOPLEFT', holder, 'BOTTOMLEFT', -thick, 0)
			bar:SetPoint('TOPRIGHT', holder, 'BOTTOMRIGHT', thick, 0)
			bar:SetHeight(thick)
		elseif index == 3 then
			bar:SetPoint('TOPRIGHT', holder, 'TOPLEFT', 0, 0)
			bar:SetPoint('BOTTOMRIGHT', holder, 'BOTTOMLEFT', 0, 0)
			bar:SetWidth(thick)
		else
			bar:SetPoint('TOPLEFT', holder, 'TOPRIGHT', 0, 0)
			bar:SetPoint('BOTTOMLEFT', holder, 'BOTTOMRIGHT', 0, 0)
			bar:SetWidth(thick)
		end
	end
	-- Round: the bezel's ring (thick) or a hairline ring.
	holder.ring:SetShown(round and housing ~= 'none')
	local ringSize = housing == 'bezel' and size + 2 * thick or size
	holder.ring:SetSize(ringSize, ringSize)
	Kit:Tint(holder.ring, housing == 'bezel' and 'keyEdge' or 'darkDim', housing == 'bezel' and 1 or 0.8)
	-- Square hairlines and corner brackets.
	local hair = housing == 'hairline' and not round
	local edges = {{'TOPLEFT', 'TOPRIGHT', true}, {'BOTTOMLEFT', 'BOTTOMRIGHT', true}, {'TOPLEFT', 'BOTTOMLEFT', false},
		{'TOPRIGHT', 'BOTTOMRIGHT', false}}
	for index, line in ipairs(holder.hair) do
		local edge = edges[index]
		line:ClearAllPoints()
		line:SetPoint(edge[1], holder, edge[1], 0, 0)
		line:SetPoint(edge[2], holder, edge[2], 0, 0)
		if edge[3] then line:SetHeight(px) else line:SetWidth(px) end
		Kit:Tint(line, 'darkDim', 0.45)
		line:SetShown(hair)
	end
	local arm, weight = 10, 2 * px
	local corners = {{'TOPLEFT', 1, -1}, {'TOPRIGHT', -1, -1}, {'BOTTOMLEFT', 1, 1}, {'BOTTOMRIGHT', -1, 1}}
	for index, corner in ipairs(corners) do
		local across, down = holder.brackets[index * 2 - 1], holder.brackets[index * 2]
		across:ClearAllPoints()
		across:SetPoint(corner[1], holder, corner[1], 0, 0)
		across:SetSize(arm, weight)
		down:ClearAllPoints()
		down:SetPoint(corner[1], holder, corner[1], 0, 0)
		down:SetSize(weight, arm)
		Kit:Tint(across, 'darkInk', 0.9)
		Kit:Tint(down, 'darkInk', 0.9)
		across:SetShown(hair)
		down:SetShown(hair)
	end
end

-- Which masks each tile wears, for the shape and the edge.
local function Masks()
	local db = DB()
	local round = db.shape == 'round'
	local list = {}
	if round then list[#list + 1] = masks.round end
	if db.fade then list[#list + 1] = round and masks.fadeRound or masks.fadeSquare end
	return list
end

local function ApplyMasks(tile)
	for _, mask in pairs(masks) do pcall(tile.RemoveMaskTexture, tile, mask) end
	for _, mask in ipairs(m.masks) do tile:AddMaskTexture(mask) end
end

local function ReleaseTiles()
	for index, tile in pairs(tiles) do
		tile:Hide()
		tile:SetTexture(nil)
		tiles[index] = nil
		spare[#spare + 1] = tile
	end
end

local function Layout()
	if not holder then return end
	local db = DB()
	local px = UI.Pixel.Px(holder, 1)
	m.px, m.scale = px, holder:GetEffectiveScale()
	local size = Snap(Clamp(db.size, 160, 600, 300), px)
	local round = db.shape == 'round'
	holder:SetSize(size, size)
	m.size, m.half, m.round = size, size / 2, round
	m.radius = Clamp(db.radius, 100, 600, 250)
	m.k = m.half / m.radius -- UI units per yard
	m.rotate = db.rotate and true or false
	-- Glass.
	local glass = holder.glass.shell
	glass.opts.radius = round and 999 or 6
	glass.opts.alpha = Clamp(db.backdrop, 0, 0.9, 0.3)
	holder.glass:SetShown(glass.opts.alpha > 0.01)
	Kit:PaintShell(glass)
	Kit:FitShell(glass)
	LayoutFrame(size, round, px)
	-- Masks: the hard circle at the window's size; the soft square at it; the
	-- soft round glow larger, so its falloff begins further out.
	masks.round:SetSize(size, size)
	masks.fadeSquare:SetSize(size, size)
	masks.fadeRound:SetSize(size * 1.5, size * 1.5)
	m.masks = Masks()
	local opacity = Clamp(db.opacity, 0.1, 1, 0.6)
	if db.fade and not round then opacity = min(1, opacity / SHADOW_PEAK) end
	m.opacity = opacity
	for _, tile in pairs(tiles) do ApplyMasks(tile); tile:SetAlpha(opacity) end
	for _, tile in ipairs(spare) do ApplyMasks(tile) end
	-- Your arrow, the north mark and the scale chip.
	m.arrow = Clamp(db.arrowSize, 10, 28, 16)
	holder.arrowGlow:SetSize(m.arrow * 2.4, m.arrow * 2.4)
	Kit:Tint(holder.arrowGlow, 'lamp', 0.35)
	for _, line in ipairs(holder.arrow) do
		line:SetThickness(px * 2)
		Kit:Tint(line, 'lamp')
	end
	holder.scale:ClearAllPoints()
	holder.scale:SetPoint('BOTTOM', holder, 'BOTTOM', 0, round and size * 0.06 + 4 or 6)
	holder.scale:SetShown(db.scaleChip and true or false)
	holder.scale.text:SetText(format('%d YD', floor(m.radius + 0.5)))
	m.key = floor(Clamp(db.keySize, 10, 22, 14) + 0.5)
	for _, slot in pairs(keys) do slot.dressed = nil end
	m.rebuild = true
end

-- Tiles ------------------------------------------------------------------------------------------
-- The most detailed art layer whose tiles under the window stay within budget.
local function ChooseLayer(layers, worldW, radius, rotate)
	local best
	for index, info in ipairs(layers) do
		local width, tileW = Nav.Number(info.layerWidth), Nav.Number(info.tileWidth)
		local height, tileH = Nav.Number(info.layerHeight), Nav.Number(info.tileHeight)
		if width and tileW and height and tileH and width > 0 and tileW > 0 and height > 0 and tileH > 0 then
			local across = 2 * radius * (rotate and 1.42 or 1) * (width / worldW) / tileW + 2
			if not best or across * across <= TILE_BUDGET then best = index end
		end
	end
	return best
end

local function RebuildTiles(here)
	m.rebuild = nil
	ReleaseTiles()
	m.grid = nil
	local mapID = here.mapID
	if not (mapID and here.worldW and C_Map and C_Map.GetMapArtLayers) then return end
	local layers = Nav.Plain(C_Map.GetMapArtLayers, mapID)
	if type(layers) ~= 'table' or #layers == 0 then return end
	local index = ChooseLayer(layers, here.worldW, m.radius, m.rotate)
	if not index then return end
	local info = layers[index]
	local textures = Nav.Plain(C_Map.GetMapArtLayerTextures, mapID, index)
	if type(textures) ~= 'table' or #textures == 0 then return end
	local grid = {mapID = mapID, layer = index, textures = textures,
		cols = ceil(info.layerWidth / info.tileWidth), rows = ceil(info.layerHeight / info.tileHeight)}
	-- A tile's size in UI units: its texels, at the map's yards per texel, at the zoom.
	grid.tw = info.tileWidth * (here.worldW / info.layerWidth) * m.k
	grid.th = info.tileHeight * (here.worldH / info.layerHeight) * m.k
	m.grid = grid
	m.range = nil
end

local function Tile(index)
	local tile = tiles[index]
	if tile then return tile end
	local file = m.grid.textures[index]
	if file == nil or Nav.IsSecret(file) then return nil end
	tile = table.remove(spare)
	if not tile then
		tile = canvas:CreateTexture(nil, 'BACKGROUND', nil, -6)
		ApplyMasks(tile)
	end
	tile:SetTexture(file, nil, nil, 'TRILINEAR')
	tile:SetSize(m.grid.tw, m.grid.th)
	tile:SetAlpha(m.opacity)
	tile:SetRotation(0)
	tile:Show()
	tiles[index] = tile
	return tile
end

-- The tiles under the window (wider when turning: its corners sweep a circle),
-- made or let go only when that range changes.
local function UpdateTiles(cx, cy)
	local grid = m.grid
	local reach = m.half * (m.rotate and 1.42 or 1) + 2
	local c1 = max(1, floor((cx - reach) / grid.tw) + 1)
	local c2 = min(grid.cols, floor((cx + reach) / grid.tw) + 1)
	local r1 = max(1, floor((cy - reach) / grid.th) + 1)
	local r2 = min(grid.rows, floor((cy + reach) / grid.th) + 1)
	local range = c1..':'..c2..':'..r1..':'..r2
	if range == m.range then return false end
	m.range = range
	local keep = {}
	for col = c1, c2 do
		for row = r1, r2 do
			local index = (row - 1) * grid.cols + col
			keep[index] = true
			local fresh = not tiles[index]
			local tile = Tile(index)
			if tile and fresh then
				tile.col, tile.row = col, row
				tile:ClearAllPoints()
				tile:SetPoint('TOPLEFT', canvas, 'TOPLEFT', (col - 1) * grid.tw, -(row - 1) * grid.th)
			end
		end
	end
	for index, tile in pairs(tiles) do
		if not keep[index] then
			tile:Hide()
			tile:SetTexture(nil)
			tiles[index] = nil
			spare[#spare + 1] = tile
		end
	end
	return true
end

-- North-up: one anchor moves the canvas. Turning: each tile is placed about
-- you and turned with the map.
local function PlaceArt(cx, cy, facing)
	local px = m.px
	local changed = UpdateTiles(cx, cy)
	if not m.rotate or not facing then
		if changed or m.turned then
			m.turned = nil
			for _, tile in pairs(tiles) do
				tile:SetRotation(0)
				tile:ClearAllPoints()
				tile:SetPoint('TOPLEFT', canvas, 'TOPLEFT', (tile.col - 1) * m.grid.tw, -(tile.row - 1) * m.grid.th)
			end
		end
		canvas:ClearAllPoints()
		canvas:SetPoint('TOPLEFT', window, 'CENTER', Snap(-cx, px), Snap(cy, px))
		return
	end
	m.turned = true
	local c, s = cos(facing), sin(facing)
	local grid = m.grid
	for _, tile in pairs(tiles) do
		local east = (tile.col - 0.5) * grid.tw - cx
		local north = -((tile.row - 0.5) * grid.th - cy)
		tile:ClearAllPoints()
		tile:SetPoint('CENTER', window, 'CENTER', east * c + north * s, -east * s + north * c)
		tile:SetRotation(-facing)
	end
end

-- Points on the map ------------------------------------------------------------------------------
-- A spot `east` and `north` units from you, on screen: turned with the map when it turns.
local function OnScreen(east, north, facing)
	if m.rotate and facing then
		local c, s = cos(facing), sin(facing)
		return east * c + north * s, -east * s + north * c
	end
	return east, north
end

-- Inside the window's shape, with room for `pad`; or the spot on its rim.
local function Fit(x, y, pad)
	local limit = m.half - pad
	if m.round then
		local r = sqrt(x * x + y * y)
		if r <= limit then return x, y, true end
		return x / r * limit, y / r * limit, false
	end
	if abs(x) <= limit and abs(y) <= limit then return x, y, true end
	local scale = limit / max(abs(x), abs(y))
	return x * scale, y * scale, false
end

local function KeySlot(uid)
	local slot = keys[uid]
	if slot then return slot, false end
	slot = table.remove(freeKeys)
	if not slot then slot = {key = Nav:MakeKey(pins)} end
	keys[uid] = slot
	return slot, true
end

local function DrawPoints(here, facing)
	local db = DB()
	wipe(seen)
	if db.pois and here.wx then
		local list = Nav:Near(m.radius * 1.5, nearList, 40)
		local art = UI.db.compass and UI.db.compass.icons == 'game'
		for _, entry in ipairs(list) do
			local poi = entry.poi
			local x, y = OnScreen(entry.east * m.k, -entry.south * m.k, facing)
			local fx, fy, inside = Fit(x, y, m.key / 2 + 2)
			if inside or poi.super then
				seen[poi.uid] = true
				local slot, fresh = KeySlot(poi.uid)
				if slot.poi ~= poi or not slot.dressed then
					slot.poi, slot.dressed = poi, true
					Nav:DressKey(slot.key, poi, m.key, art)
				end
				slot.key:ClearAllPoints()
				slot.key:SetPoint('CENTER', pins, 'CENTER', Snap(fx, m.px), Snap(fy, m.px))
				if fresh then
					slot.key:SetAlpha(0)
					slot.key:Show()
				end
				local alpha = inside and 1 or 0.85
				if fresh and not Reduced() then Kit:FadeTo(slot.key, alpha, 'FAST')
				elseif not Kit:Animating(slot.key) then slot.key:SetAlpha(alpha) end
			end
		end
	end
	for uid, slot in pairs(keys) do
		if not seen[uid] then
			slot.key:Hide()
			slot.poi = nil
			keys[uid] = nil
			freeKeys[#freeKeys + 1] = slot
		end
	end
end

-- Group members, where the game shares their spot (never in instances).
local groupAt, colorAt = 0, 0
local function ClassColor(unit)
	local _, class = UnitClass(unit)
	if Nav.IsSecret(class) or type(class) ~= 'string' then return 0.8, 0.8, 0.8 end
	local color = (C_ClassColor and C_ClassColor.GetClassColor and C_ClassColor.GetClassColor(class))
		or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[class])
	if color then return color.r, color.g, color.b end
	return 0.8, 0.8, 0.8
end

local function Dot(index)
	local dot = dots[index]
	if dot then return dot end
	dot = Kit:Texture(pins, 'circle', 'OVERLAY', 3)
	dot.ring = Kit:Texture(pins, 'circle', 'OVERLAY', 2)
	dots[index] = dot
	return dot
end

local function DrawGroup(here, facing, now)
	local count = 0
	if DB().group and here.wx and IsInGroup and IsInGroup() then
		local raid = IsInRaid and IsInRaid()
		local total = raid and (GetNumGroupMembers() or 0) or 4
		for index = 1, total do
			local unit = (raid and 'raid' or 'party')..index
			local exists = Nav.Plain(UnitExists, unit)
			local isMe = exists and Nav.Plain(UnitIsUnit, unit, 'player')
			if exists and not isMe then
				local x, y = Nav.XY(Nav.Plain(C_Map.GetPlayerMapPosition, here.mapID, unit))
				if x and (x ~= 0 or y ~= 0) then
					local east, north = (x * here.worldW - here.wx) * m.k, -(y * here.worldH - here.wy) * m.k
					local sx, sy = OnScreen(east, north, facing)
					local fx, fy, inside = Fit(sx, sy, 4)
					count = count + 1
					local dot = Dot(count)
					local size = inside and 7 or 5
					dot:SetSize(size, size)
					dot.ring:SetSize(size + 2, size + 2)
					dot:ClearAllPoints()
					dot:SetPoint('CENTER', pins, 'CENTER', Snap(fx, m.px), Snap(fy, m.px))
					dot.ring:ClearAllPoints()
					dot.ring:SetPoint('CENTER', dot, 'CENTER', 0, 0)
					if dot.unit ~= unit or now - colorAt > 2 then
						dot.unit = unit
						dot:SetVertexColor(ClassColor(unit))
						dot.ring:SetVertexColor(0, 0, 0, 0.7)
					end
					dot:SetAlpha(inside and 1 or 0.6)
					dot:Show()
					dot.ring:Show()
				end
			end
		end
	end
	if now - colorAt > 2 then colorAt = now end
	for index = count + 1, #dots do
		dots[index]:Hide()
		dots[index].ring:Hide()
	end
end

-- Your arrow: a lit chevron, turned with your facing (north-up) or pointing up.
local ARROW = {{0, 1, -0.62, -0.62}, {0, 1, 0.62, -0.62}, {-0.62, -0.62, 0, -0.18}, {0.62, -0.62, 0, -0.18}}
local function DrawArrow(facing)
	local angle = (not m.rotate and facing) or 0
	local c, s = cos(angle), sin(angle)
	local half = m.arrow / 2
	for index, line in ipairs(holder.arrow) do
		local p = ARROW[index]
		local x1, y1 = (p[1] * c - p[2] * s) * half, (p[1] * s + p[2] * c) * half
		local x2, y2 = (p[3] * c - p[4] * s) * half, (p[3] * s + p[4] * c) * half
		line:SetStartPoint('CENTER', pins, x1, y1)
		line:SetEndPoint('CENTER', pins, x2, y2)
		line:SetShown(facing ~= nil)
	end
	holder.arrowGlow:SetShown(facing ~= nil)
	-- North: fixed at the top, or riding the rim as the map turns.
	local nx, ny = 0, m.half - 9
	if m.rotate and facing then nx, ny = sin(facing) * (m.half - 9), cos(facing) * (m.half - 9) end
	holder.north:ClearAllPoints()
	holder.north:SetPoint('CENTER', pins, 'CENTER', Snap(nx, m.px), Snap(ny, m.px))
	holder.north:SetShown(facing ~= nil or not m.rotate)
end

-- The driver ---------------------------------------------------------------------------------------
local since = 0

local function Signal(on)
	if m.signal == on then return end
	m.signal = on
	holder.signal:SetShown(not on)
	canvas:SetShown(on)
end

local function Step(_, elapsed)
	since = since + elapsed
	local rate = UI.db.navigation.rate == 20 and 20 or 30
	if since < 1 / rate then return end
	since = 0
	local scale = holder:GetEffectiveScale()
	if not m.scale or abs(scale - m.scale) > 0.0001 then Layout() end
	local now = GetTime()
	local here = Nav:Sense(now)
	Nav:Tick(now)
	if m.rebuild or (m.grid and m.grid.mapID ~= here.mapID) or (not m.grid and here.mapID and m.lastTry ~= here.mapID) then
		m.lastTry = here.mapID
		RebuildTiles(here)
	end
	local facing = here.facing
	if not (here.wx and m.grid) then
		Signal(false)
		DrawArrow(facing)
		DrawPoints(here, facing)
		DrawGroup(here, facing, now)
		return
	end
	Signal(true)
	PlaceArt(here.x * here.worldW * m.k, here.y * here.worldH * m.k, facing)
	DrawArrow(facing)
	DrawPoints(here, facing)
	if now - groupAt >= 0.1 then
		groupAt = now
		DrawGroup(here, facing, now)
	end
end

-- Showing --------------------------------------------------------------------------------------------
local function Wanted()
	local db = DB()
	if preview then return true end
	return db.enable and db.shown and not (fighting and db.hideInCombat) and true or false
end

local function Show(animate)
	if not holder then return end
	local on = Wanted()
	if on == holder:IsShown() then return end
	if on then
		holder:Show()
		if animate and not Reduced() then
			holder:SetAlpha(0)
			Kit:FadeTo(holder, UI:MoverAlphaFor(holder), 'FAST')
		end
	else
		holder:Hide()
	end
end

local function Setup()
	if holder or not DB().enable then return end
	Build()
	Layout()
	holder:SetScript('OnShow', function()
		Nav:Want(module, true)
		since, m.signal = 1, nil
		m.rebuild = true
	end)
	holder:SetScript('OnHide', function()
		Nav:Want(module, false)
		ReleaseTiles()
		m.grid, m.range = nil, nil
	end)
	holder:SetScript('OnUpdate', Step)
	-- Scripts first: a frame hidden in unlock mode hooks OnShow when it registers.
	UI:RegisterMover(holder, 'nav.map', 'Overlay map', {'CENTER', 420, 40})
	function holder:SetPreview(on)
		preview = on and true or false
		Show(false)
	end
	Nav:OnChange(function(what) if what == 'map' then m.rebuild = true end end)
	local events = CreateFrame('Frame')
	events:RegisterEvent('PLAYER_REGEN_DISABLED')
	events:RegisterEvent('PLAYER_REGEN_ENABLED')
	events:SetScript('OnEvent', function(_, event)
		fighting = event == 'PLAYER_REGEN_DISABLED'
		Show(true)
	end)
	fighting = InCombatLockdown()
	Show(false)
end

-- /spec map, the binding and the hub's key.
function module:Toggle(show)
	local db = DB()
	if not db.enable then return UI:Print('The overlay map is off: turn it on under Navigation in /spec.') end
	Setup()
	if show == nil then show = not db.shown end
	db.shown = show and true or false
	Kit:Play(db.shown and 'power-up' or 'power-down')
	Show(true)
end

function module:Enable()
	Setup()
end

function module:Refresh()
	Setup()
	if not holder then return end
	Layout()
	UI:PlaceMover('nav.map')
	if not DB().enable then holder:Hide() else Show(false) end
end

Kit:OnRefresh(function() if holder then UI:Safe(Layout) end end)
