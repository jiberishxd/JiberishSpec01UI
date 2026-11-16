-- The game's Cooldown Manager (Blizzard_CooldownViewer: Essential and Utility
-- cooldowns, tracked buff icons and tracked buff bars) in SPEC-01 parts.
--
--   * Icons sit in a window cut into a key (light, charcoal or dark glass), cropped,
--     with the reference's rounded mask, an inner shadow and a SPEC-01 swipe.
--     Counts and timers are in the reference's typeface; the timer can take the
--     LCD ink. A proc (the game's spell alert) lights a lamp and a lit ring.
--   * Bars are SPEC-01 meters: the fill (flat or LED dots) on a black screen in a
--     glass housing, a spark riding the fill's edge, printed name and time.
--
-- The viewers are Edit Mode systems and their items are pooled: nothing is
-- reparented or re-anchored, nothing is written onto Blizzard's frames (our parts
-- live in a weak side table), and dressing an item is idempotent, so a reused
-- item is simply dressed again. Times, counts and names may be secret; they are
-- never read, only styled. The spark is anchored to the fill texture, so the
-- engine moves it.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, hooksecurefunc = CreateFrame, hooksecurefunc
local max = math.max

local module = UI:RegisterModule('cooldowns', {always = true})

-- defaults:begin
UI:RegisterDefaults('cooldowns', {enable = true, key = 'light', keyPad = 2, countSize = 0, timerSize = 0, timers = true,
	timerInk = 'lcd', glow = 'lamp', bar = 'flat', barColor = 'key', spark = true, housing = true})
-- defaults:end

local function DB() return UI.db.cooldowns end
local function IsSecret(value) return issecretvalue and issecretvalue(value) end
local function Is(object, kind)
	return type(object) == 'table' and object.IsObjectType and not (object.IsForbidden and object:IsForbidden())
		and object:IsObjectType(kind)
end

local VIEWERS = {'EssentialCooldownViewer', 'UtilityCooldownViewer', 'BuffIconCooldownViewer', 'BuffBarCooldownViewer'}
local OVERLAY_ATLAS, OVERLAY_FILE = 'UI-HUD-CoolDownManager-IconOverlay', 6707800
local BAR_ATLAS, BAR_BG_ATLAS = 'UI-HUD-CoolDownManager-Bar', 'UI-HUD-CoolDownManager-Bar-BG'
local FLAT = [[Interface\Buttons\WHITE8X8]]
local KEY_SPRITES = {light = 'key', dark = 'cap'}

local looks = setmetatable({}, {__mode = 'k'}) -- Blizzard item -> our parts
local hookedViewers = {}
local alertsHooked = false

local function Sized(value, auto)
	value = tonumber(value) or 0
	return value > 0 and value or auto
end

-- Plain texture/atlas reads only: a secret answer is never compared.
local function AtlasOf(region)
	local atlas = region.GetAtlas and region:GetAtlas()
	if IsSecret(atlas) then return nil end
	return atlas
end

local function FileOf(region)
	local file = region.GetTexture and region:GetTexture()
	if IsSecret(file) then return nil end
	return file
end

-- The game's ring overlay goes; its rounded masks take the reference's icon mask.
local function StripIconArt(holder, icon)
	for _, region in ipairs({holder:GetRegions()}) do
		if Is(region, 'MaskTexture') then
			pcall(region.SetTexture, region, Kit.media..'mask-icon.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
		elseif region ~= icon and Is(region, 'Texture') then
			if AtlasOf(region) == OVERLAY_ATLAS or FileOf(region) == OVERLAY_FILE then region:SetAlpha(0) end
		end
	end
end

-- Icons --------------------------------------------------------------------------------
local function BuildKey(look, holder, icon)
	-- Behind the icon: the key (a baked sprite) or a glass shell, on our own frame.
	local key = CreateFrame('Frame', nil, holder)
	key:SetFrameLevel(max(holder:GetFrameLevel() - 1, 0))
	key:EnableMouse(false)
	look.key = key
	-- Above it: the window's inner shadow, the proc lamp and ring.
	local lid = CreateFrame('Frame', nil, holder)
	lid:SetAllPoints(key)
	lid:SetFrameLevel(holder:GetFrameLevel() + 3)
	lid:EnableMouse(false)
	look.lid = lid
	look.window = Kit:Texture(lid, 'inset-6', 'ARTWORK', 0)
	Kit:Place(look.window, icon, 0, 0, 0, 0)
	look.window:SetVertexColor(0, 0, 0, 0.6)
	look.ring = Kit:Texture(lid, 'ring-6', 'OVERLAY', 1)
	Kit:Place(look.ring, key, 1, 1, 1, 1)
	Kit:Tint(look.ring, 'lamp')
	look.ring:Hide()
	look.led = Kit:Led(lid, 4, true)
	look.led:SetPoint('TOPRIGHT', key, 'TOPRIGHT', -2, -2)
	Kit:ShowLed(look.led, false)
end

local function PaintKey(look)
	local db, key = DB(), look.key
	local pad = Kit:Clamp(math.floor(tonumber(db.keyPad) or 2), 0, 8)
	key:ClearAllPoints()
	key:SetPoint('TOPLEFT', look.icon, 'TOPLEFT', -pad, pad)
	key:SetPoint('BOTTOMRIGHT', look.icon, 'BOTTOMRIGHT', pad, -pad - 1)
	local sprite = KEY_SPRITES[db.key]
	if sprite then
		if not key.sprite then
			key.sprite = Kit:Skin(key, sprite, 'BACKGROUND', 0)
			key.sprite.kitMaxCorner = 6
		elseif key.spriteName ~= sprite then
			Kit:SetSprite(key.sprite, sprite)
			Kit:FitSprite(key.sprite, key:GetWidth(), key:GetHeight())
		end
		key.spriteName = sprite
		key.sprite:Show()
		if key.shell then key.shell:Hide() end
	else
		if not key.shell then key.shell = Kit:Shell(key, {surface = 'glass', radius = 5, shadow = false, alpha = 0.92}) end
		key.shell:Show()
		if key.sprite then key.sprite:Hide() end
	end
end

local function StyleCooldown(look, cooldown)
	if not Is(cooldown, 'Cooldown') then return end
	for _, region in ipairs({cooldown:GetRegions()}) do
		if Is(region, 'MaskTexture') then
			pcall(region.SetTexture, region, Kit.media..'mask-icon.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
		end
	end
	if cooldown.SetSwipeTexture then cooldown:SetSwipeTexture(Kit.media..'mask-icon.tga') end
	if cooldown.SetDrawBling then cooldown:SetDrawBling(false) end
	local db = DB()
	local numbers = cooldown.GetCountdownFontString and cooldown:GetCountdownFontString()
	if Is(numbers, 'FontString') then
		Kit:Font(numbers, Sized(db.timerSize, 12), 'OUTLINE', true)
		Kit:Tint(numbers, db.timerInk == 'lcd' and 'lcdInk' or (db.timerInk == 'key' and 'lamp' or 'white'))
		numbers:SetShadowOffset(0, 0)
		-- The viewer may turn its own timers on again; hiding through alpha survives that.
		numbers:SetAlpha(db.timers and 1 or 0)
	end
end

local function StyleCounts(look, holder)
	local db = DB()
	local size = Sized(db.countSize, 11)
	local texts = {}
	local applications = holder.Applications
	if Is(applications, 'FontString') then texts[#texts + 1] = applications
	elseif type(applications) == 'table' and Is(applications.Applications, 'FontString') then texts[#texts + 1] = applications.Applications end
	local charges = holder.ChargeCount
	if type(charges) == 'table' and Is(charges.Current, 'FontString') then texts[#texts + 1] = charges.Current end
	for _, text in ipairs(texts) do
		Kit:Font(text, size, 'OUTLINE', true)
		Kit:Tint(text, 'darkInk')
		text:SetShadowOffset(0, 0)
	end
end

local function DressIcon(look, holder, icon)
	look.icon = icon
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	StripIconArt(holder, icon)
	if not look.key then BuildKey(look, holder, icon) end
	PaintKey(look)
	StyleCounts(look, holder)
end

-- Procs ------------------------------------------------------------------------------
local function SetLit(look, lit)
	local db = DB()
	local glow = db.glow
	Kit:ShowLed(look.led, lit and glow ~= 'blizzard')
	look.ring:SetShown(lit and glow ~= 'blizzard' or false)
	if lit and Kit.Flash and look.lid and glow ~= 'blizzard' then Kit:Flash(look.lid) end
end

local function AlertTarget(button)
	if looks[button] then return looks[button] end
	return nil
end

local function HookAlerts()
	local manager = _G.ActionButtonSpellAlertManager
	if type(manager) ~= 'table' or alertsHooked then return end
	local hooked = false
	if type(manager.ShowAlert) == 'function' then
		hooksecurefunc(manager, 'ShowAlert', function(_, button)
			local look = AlertTarget(button)
			if not look then return end
			UI:Safe(SetLit, look, true)
			-- 'lamp' replaces the game's flipbook glow with ours.
			local alert = button.SpellActivationAlert
			if DB().glow == 'lamp' and type(alert) == 'table' and alert.SetAlpha then alert:SetAlpha(0)
			elseif type(alert) == 'table' and alert.SetAlpha then alert:SetAlpha(1) end
		end)
		hooked = true
	end
	if type(manager.HideAlert) == 'function' then
		hooksecurefunc(manager, 'HideAlert', function(_, button)
			local look = AlertTarget(button)
			if look then UI:Safe(SetLit, look, false) end
		end)
		hooked = true
	end
	alertsHooked = hooked
end

-- Bars ---------------------------------------------------------------------------------
local function PaintBarColor(look)
	local db, bar = DB(), look.bar
	if db.barColor ~= 'key' then return end
	local r, g, b = Kit:RGB('lamp')
	look.painting = true
	bar:SetStatusBarColor(r, g, b, 1)
	look.painting = nil
	if look.spark then look.spark:SetVertexColor(r, g, b); look.glow:SetVertexColor(r, g, b) end
end

-- LED dots: unlit dots under the fill and a perforated cover over it, our own
-- textures on the bar, tiled one dot per bar height.
local function SizeDots(look)
	local bar = look.bar
	local width, height = bar:GetSize()
	if IsSecret(width) or IsSecret(height) or not width or not height or height <= 0 or width <= 0 then
		look.under:Hide(); look.cover:Hide()
		return
	end
	local on = DB().bar == 'dots'
	for _, texture in ipairs({look.under, look.cover}) do
		texture:SetHorizTile(true); texture:SetVertTile(false)
		if texture.SetScale then texture:SetScale(height / 16) end
		texture:SetShown(on)
	end
end

local function BuildBar(look, item, bar)
	-- Housing round the whole item, a black screen behind the bar.
	look.housing = CreateFrame('Frame', nil, item)
	look.housing:SetPoint('TOPLEFT', item, 'TOPLEFT', -3, 3)
	look.housing:SetPoint('BOTTOMRIGHT', item, 'BOTTOMRIGHT', 3, -3)
	look.housing:SetFrameLevel(max(item:GetFrameLevel() - 1, 0))
	Kit:Shell(look.housing, {surface = 'glass', radius = 5, alpha = 0.9})
	look.screen = CreateFrame('Frame', nil, item)
	look.screen:SetPoint('TOPLEFT', bar, 'TOPLEFT', -1, 1)
	look.screen:SetPoint('BOTTOMRIGHT', bar, 'BOTTOMRIGHT', 1, -1)
	look.screen:SetFrameLevel(max(bar:GetFrameLevel() - 1, 0))
	Kit:Shell(look.screen, {surface = 'screen', radius = 2, shadow = false})
	local function Tile(file, layer, sublevel, token)
		local texture = bar:CreateTexture(nil, layer, nil, sublevel)
		texture:SetTexture(Kit.media..file..'.tga', 'REPEAT', 'REPEAT')
		texture:SetAllPoints(bar)
		Kit:Tint(texture, token)
		return texture
	end
	look.under = Tile('tile-dot', 'BACKGROUND', 1, 'ledOff')
	look.cover = Tile('tile-perf', 'OVERLAY', -8, 'black')
	bar:HookScript('OnSizeChanged', function() if looks[item] then UI:Safe(SizeDots, looks[item]) end end)
	-- The spark rides the fill texture's edge.
	local fill = bar:GetStatusBarTexture()
	look.spark = bar:CreateTexture(nil, 'OVERLAY', nil, 3)
	look.spark:SetColorTexture(1, 1, 1, 1)
	look.spark:SetBlendMode('ADD')
	look.glow = Kit:Texture(bar, 'glow', 'OVERLAY', 2)
	look.glow:SetBlendMode('ADD')
	look.glow:SetAlpha(0.6)
	look.fill = fill
	-- The viewer colors bars from its own settings; with the key color on, ours
	-- is put back after it.
	hooksecurefunc(bar, 'SetStatusBarColor', function()
		local current = looks[item]
		if current and not current.painting then UI:Safe(PaintBarColor, current) end
	end)
end

local function PlaceSpark(look)
	local bar, fill = look.bar, look.bar:GetStatusBarTexture()
	if fill and fill ~= look.fill then look.fill = fill end
	fill = look.fill
	if not fill then return end
	look.spark:ClearAllPoints()
	look.spark:SetWidth(UI.Pixel.Px(bar, 2))
	look.spark:SetPoint('TOP', fill, 'TOPRIGHT', 0, 0)
	look.spark:SetPoint('BOTTOM', fill, 'BOTTOMRIGHT', 0, 0)
	look.glow:ClearAllPoints()
	look.glow:SetPoint('TOPLEFT', fill, 'TOPRIGHT', -6, 5)
	look.glow:SetPoint('BOTTOMRIGHT', fill, 'BOTTOMRIGHT', 6, -5)
	local on = DB().spark and true or false
	look.spark:SetShown(on)
	look.glow:SetShown(on)
end

local function DressBar(look, item, bar)
	look.bar = bar
	if not look.housing then BuildBar(look, item, bar) end
	local db = DB()
	-- The game's bar art: its fill texture becomes flat, its track goes.
	local fill = bar:GetStatusBarTexture()
	if fill then
		if fill.ClearTextureSlice then pcall(fill.ClearTextureSlice, fill) end
		if fill.SetTextureSliceMode then pcall(fill.SetTextureSliceMode, fill, 0) end
		if FileOf(fill) ~= FLAT then fill:SetTexture(FLAT) end
	end
	for _, region in ipairs({bar:GetRegions()}) do
		if region ~= fill and Is(region, 'Texture') then
			local atlas = AtlasOf(region)
			if atlas == BAR_BG_ATLAS or (atlas ~= BAR_ATLAS and region ~= look.under and region ~= look.cover
				and region ~= look.spark and region ~= look.glow) then
				region:SetAlpha(0)
			end
		end
	end
	look.housing:SetShown(db.housing and true or false)
	SizeDots(look)
	PlaceSpark(look)
	PaintBarColor(look)
	if Is(bar.Name, 'FontString') then
		Kit:Font(bar.Name, 10, '', true)
		Kit:Tint(bar.Name, 'darkInk')
		bar.Name:SetShadowOffset(1, -1)
	end
	if Is(bar.Duration, 'FontString') then
		Kit:Font(bar.Duration, Sized(db.timerSize, 10), '', true)
		Kit:Tint(bar.Duration, db.timerInk == 'lcd' and 'lcdInk' or (db.timerInk == 'key' and 'lamp' or 'white'))
		bar.Duration:SetShadowOffset(1, -1)
		bar.Duration:SetAlpha(db.timers and 1 or 0)
	end
end

-- Items ----------------------------------------------------------------------------------
local function Dress(item)
	if type(item) ~= 'table' or (item.IsForbidden and item:IsForbidden()) then return end
	local look = looks[item]
	if not look then
		look = {item = item}
		looks[item] = look
	end
	local bar = item.Bar
	if Is(bar, 'StatusBar') then
		-- A bar item: its icon is a frame holding the texture.
		local holder = item.Icon
		if type(holder) == 'table' and Is(holder.Icon, 'Texture') then
			DressIcon(look, holder, holder.Icon)
			StyleCooldown(look, holder.Cooldown or item.Cooldown)
		end
		DressBar(look, item, bar)
	elseif Is(item.Icon, 'Texture') then
		DressIcon(look, item, item.Icon)
		StyleCooldown(look, item.Cooldown)
	end
end

local function DressViewer(viewer)
	local pool = viewer.itemFramePool
	if type(pool) == 'table' and pool.EnumerateActive then
		for item in pool:EnumerateActive() do UI:Safe(Dress, item) end
	end
end

local function HookViewers()
	for _, name in ipairs(VIEWERS) do
		local viewer = _G[name]
		if type(viewer) == 'table' and not (viewer.IsForbidden and viewer:IsForbidden()) and not hookedViewers[viewer] then
			hookedViewers[viewer] = true
			if type(viewer.OnAcquireItemFrame) == 'function' then
				hooksecurefunc(viewer, 'OnAcquireItemFrame', function(_, item) UI:Safe(Dress, item) end)
			end
			-- Items refreshed in place (a spec change, an Edit Mode setting) are dressed again.
			for _, method in ipairs({'RefreshLayout', 'UpdateLayout'}) do
				if type(viewer[method]) == 'function' then
					hooksecurefunc(viewer, method, function(self) UI:Safe(DressViewer, self) end)
				end
			end
			DressViewer(viewer)
		end
	end
	HookAlerts()
end

local function Loaded()
	if C_AddOns and C_AddOns.IsAddOnLoaded then return C_AddOns.IsAddOnLoaded('Blizzard_CooldownViewer') end
	return IsAddOnLoaded and IsAddOnLoaded('Blizzard_CooldownViewer')
end

function module:Enable()
	if not DB().enable then return end
	local events = CreateFrame('Frame')
	events:RegisterEvent('ADDON_LOADED')
	events:RegisterEvent('PLAYER_ENTERING_WORLD')
	events:SetScript('OnEvent', function(_, event, name)
		if event == 'ADDON_LOADED' and name ~= 'Blizzard_CooldownViewer' then return end
		UI:Safe(HookViewers)
	end)
	if Loaded() then HookViewers() end
	self.ready = true
end

function module:Refresh()
	if not self.ready then return end
	for item in pairs(looks) do
		UI:Safe(Dress, item)
	end
end

Kit:OnRefresh(function() module:Refresh() end)

-- Hub ------------------------------------------------------------------------------------
local function Off() return not DB().enable end
local function Auto(value) return value == 0 and 'Auto' or tostring(value) end
UI:RegisterPage('cooldowns', {title = 'Cooldown manager', order = 12.7, cards = {
	{title = 'Cooldown manager', rows = {
		{'switch', 'SPEC-01 cooldown manager', 'cooldowns.enable', 'The game\'s Cooldown Manager (essential and utility cooldowns, tracked buffs and buff bars) in SPEC-01 parts. Place and size it in Edit Mode.', reload = true, since = '0.5.1'},
		{'segmented', 'Key', 'cooldowns.key', items = {{'light', 'Light'}, {'dark', 'Charcoal'}, {'glass', 'Glass'}},
			disabled = Off, since = '0.5.1', note = 'What each icon is set into.'},
		{'slider', 'Key margin', 'cooldowns.keyPad', 0, 8, 1, 'How much of the key shows around each icon.', disabled = Off, since = '0.5.1'},
		{'segmented', 'Procs', 'cooldowns.glow', items = {{'lamp', 'Lamp'}, {'both', 'Lamp and glow'}, {'blizzard', 'Game glow'}},
			disabled = Off, since = '0.5.1', note = 'When a spell lights up: a lamp and a lit ring on its key, the game\'s glow, or both.'},
	}},
	{title = 'Text', rows = {
		{'switch', 'Timers', 'cooldowns.timers', 'Time left on icons and bars.', disabled = Off, since = '0.5.1'},
		{'segmented', 'Timer ink', 'cooldowns.timerInk', items = {{'lcd', 'LCD'}, {'white', 'White'}, {'key', 'Key color'}},
			disabled = Off, since = '0.5.1'},
		{'slider', 'Timer size', 'cooldowns.timerSize', 0, 18, 1, nil, format = Auto, disabled = Off, since = '0.5.1'},
		{'slider', 'Count size', 'cooldowns.countSize', 0, 18, 1, 'Charges and stacks.', format = Auto, disabled = Off, since = '0.5.1'},
	}},
	{title = 'Buff bars', rows = {
		{'segmented', 'Fill', 'cooldowns.bar', items = {{'flat', 'Flat'}, {'dots', 'LED dots'}}, disabled = Off, since = '0.5.1'},
		{'segmented', 'Color', 'cooldowns.barColor', items = {{'key', 'Key color'}, {'blizzard', 'Edit Mode'}},
			disabled = Off, since = '0.5.1', note = 'The key color, or the color set in Edit Mode.'},
		{'switch', 'Spark', 'cooldowns.spark', 'A lit edge riding the fill.', disabled = Off, since = '0.5.1'},
		{'switch', 'Housing', 'cooldowns.housing', 'Dark glass round each bar.', disabled = Off, since = '0.5.1'},
	}},
}})
