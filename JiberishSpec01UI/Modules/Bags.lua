-- Bags and bank as SPEC-01 devices: one BG-1 housing holds every bag, one
-- BK-1 housing the bank, each item on a light key over a black display.
--
-- The game still runs the bags: its key bindings and bag buttons open and
-- close its own container frames, which are parked out of sight, and these
-- devices follow their state. Items are the game's own secure item buttons
-- (ContainerFrameItemButtonTemplate, one parent frame per bag carrying the bag
-- ID), so using, equipping, splitting and selling items stay the game's code.
-- Nothing is written onto those buttons that the game's click code reads; all
-- of this module's state lives in side tables keyed by the button.
local _, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent, InCombatLockdown, GetTime = CreateFrame, UIParent, InCombatLockdown, GetTime
local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local C_Container, C_NewItems, C_Bank = C_Container, C_NewItems, C_Bank

local module = UI:RegisterModule('bags', {})

-- defaults:begin
UI:RegisterDefaults('bags', {
	-- 'sections': items sorted into kinds; 'grid': every bag slot in its place.
	layout = 'sections', columns = 12, keySize = 36, spacing = 4, scale = 1, bankColumns = 14,
	itemLevel = true, itemLevelMin = 1, qualityEdge = true, newItems = true, newSection = true,
	questMarker = true, junkMarker = true, junkDesaturate = false, cooldowns = true, bagSlots = false,
	autoOpen = {vendor = true, mail = true, auction = true, bank = true, trade = false},
	sellJunk = true, repair = 'player', report = true,
})
-- defaults:end

local function DB() return UI.db.bags end
local IsSecret, Forbidden = UI.Util.IsSecret, UI.Util.Forbidden
local function API(object, name) return object and type(object[name]) == 'function' and object[name] or nil end

local BagIndex = (Enum and Enum.BagIndex) or {}
local BankType = (Enum and Enum.BankType) or {}
local BACKPACK = BagIndex.Backpack or 0
local REAGENT_BAG = BagIndex.ReagentBag or BagIndex.Reagentbag
local CHARACTER_BANK, ACCOUNT_BANK = BankType.Character or 0, BankType.Account or 2
local POOR = (Enum and Enum.ItemQuality and Enum.ItemQuality.Poor) or 0
local GetNumSlots = API(C_Container, 'GetContainerNumSlots') or _G.GetContainerNumSlots
local GetFreeSlots = API(C_Container, 'GetContainerNumFreeSlots') or _G.GetContainerNumFreeSlots
local GetItemInfoTable = API(C_Container, 'GetContainerItemInfo')
local GetQuestInfo = API(C_Container, 'GetContainerItemQuestInfo')
local GetCooldown = API(C_Container, 'GetContainerItemCooldown') or _G.GetContainerItemCooldown
local PickupItem = API(C_Container, 'PickupContainerItem') or _G.PickupContainerItem
local UseItem = API(C_Container, 'UseContainerItem') or _G.UseContainerItem
local SetItemSearch = API(C_Container, 'SetItemSearch') or _G.SetItemSearch
local ItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
local ItemInfo = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo

local BAG_IDS = {BACKPACK, 1, 2, 3, 4}
if REAGENT_BAG then BAG_IDS[#BAG_IDS + 1] = REAGENT_BAG end

-- The bank: character tabs (or the old bank and its bags), the old reagent
-- bank where the client has one, and warband tabs where it has those.
local CHARACTER_TABS, ACCOUNT_TABS = {}, {}
for index = 1, 12 do
	local id = BagIndex['CharacterBankTab_'..index]
	if id then CHARACTER_TABS[#CHARACTER_TABS + 1] = id end
end
for index = 1, 8 do
	local id = BagIndex['AccountBankTab_'..index]
	if id then ACCOUNT_TABS[#ACCOUNT_TABS + 1] = id end
end
local LEGACY_BANK = #CHARACTER_TABS == 0 and (BagIndex.Bank or -1) or nil
if LEGACY_BANK then
	CHARACTER_TABS[1] = LEGACY_BANK
	local first = REAGENT_BAG and 6 or 5 -- the bank's bags follow the player's own
	for id = first, first + (NUM_BANKBAGSLOTS or 7) - 1 do
		CHARACTER_TABS[#CHARACTER_TABS + 1] = id
	end
end
local REAGENT_BANK = LEGACY_BANK and (BagIndex.Reagentbank or BagIndex.ReagentBank) or nil
local tabBank = {} -- bag ID -> 'character' | 'account' | 'reagent'
for _, id in ipairs(CHARACTER_TABS) do tabBank[id] = 'character' end
for _, id in ipairs(ACCOUNT_TABS) do tabBank[id] = 'account' end
if REAGENT_BANK then tabBank[REAGENT_BANK] = 'reagent' end

local PAD, HEAD, TOOL, INNER, SECTION = 10, 30, 34, 8, 18

-- Side tables -------------------------------------------------------------------
local slotOf = setmetatable({}, {__mode = 'k'})  -- button -> {bag, slot, device}
local parts = setmetatable({}, {__mode = 'k'})   -- button -> our regions on it
local itemOf = setmetatable({}, {__mode = 'k'})  -- button -> what it holds right now

local function NumSlots(bag)
	local ok, count = pcall(GetNumSlots, bag)
	return ok and type(count) == 'number' and not IsSecret(count) and count or 0
end

local function QualityColor(quality)
	if IsSecret(quality) or quality == nil then return nil end
	if C_Item and C_Item.GetItemQualityColor then
		local ok, r, g, b = pcall(C_Item.GetItemQualityColor, quality)
		if ok and r then return r, g, b end
	end
	local color = _G.ITEM_QUALITY_COLORS and _G.ITEM_QUALITY_COLORS[quality]
	if color then return color.r, color.g, color.b end
end

local function Sound(voice)
	if UI.InterfaceSound then UI:InterfaceSound(voice, 'window', 'bags') else Kit:Play(voice) end
end

-- Money as an LCD reads it: digits only, no coin art.
local function MoneyText(copper)
	if type(copper) ~= 'number' or IsSecret(copper) then return '' end
	local gold, silver = floor(copper / 10000), floor(copper / 100) % 100
	local text = (BreakUpLargeNumbers and BreakUpLargeNumbers(gold) or tostring(gold))
	return format('%sG %02dS', text, silver)
end

local function LCDChip(parent, width)
	local chip = Kit:LCDPanel(parent, {radius = 3})
	chip:SetSize(width, 18)
	chip.ghost = Kit:Text(chip, '', 9, 'lcdGhost', true)
	chip.ghost:SetPoint('RIGHT', -5, 0)
	chip.value = Kit:Text(chip, '', 9, 'lcdInk', true)
	chip.value:SetPoint('RIGHT', -5, 0)
	function chip:SetValue(text)
		text = text or ''
		self.value:SetText(text)
		self.ghost:SetText((text:gsub('[%w]', '8')))
	end
	return chip
end

-- Item keys ----------------------------------------------------------------------
-- One frame per bag carries the bag ID, as the game's own container frames do;
-- the item buttons read it from there when they are clicked.
local holders = {}
local function Holder(device, bag)
	local key = device.key..bag
	local holder = holders[key]
	if holder then return holder end
	holder = CreateFrame('Frame', format('JiberishSpec01%sBag%s', device.key, bag < 0 and 'm'..-bag or bag), device.content)
	holder:SetID(bag)
	holder:SetAllPoints(device.content)
	holder:SetFrameLevel(device.content:GetFrameLevel() + 2)
	holder.buttons = {}
	holders[key] = holder
	device.holders[bag] = holder
	return holder
end

local function Template(bag)
	if bag == LEGACY_BANK then return 'BankItemButtonGenericTemplate' end
	if tabBank[bag] == 'character' or tabBank[bag] == 'account' then return 'BankItemButtonTemplate' end
	if bag == REAGENT_BANK then return 'ReagentBankItemButtonGenericTemplate' end
	return 'ContainerFrameItemButtonTemplate'
end

local FACE = 4
local function DressButton(button, size)
	local p = parts[button]
	if not p then
		p = {}
		parts[button] = p
		local name = button:GetName() or ''
		if button.ClearNormalTexture then button:ClearNormalTexture()
		elseif button.SetNormalTexture then button:SetNormalTexture('') end
		local pushed = button.GetPushedTexture and button:GetPushedTexture()
		if pushed then pushed:SetAlpha(0) end
		for _, key in ipairs({'IconBorder', 'IconOverlay', 'IconOverlay2', 'NewItemTexture', 'BattlepayItemTexture', 'searchOverlay',
			'ExtendedSlot', 'UpgradeIcon', 'JunkIcon', 'flash', 'IconQuestTexture', 'Background'}) do
			local region = button[key] or _G[name..key]
			if region and region.SetAlpha then region:SetAlpha(0) end
		end
		local quest = _G[name..'IconQuestTexture']
		if quest then quest:SetAlpha(0) end
		p.key = Kit:Skin(button, 'key', 'BACKGROUND', -7)
		p.key.kitMaxCorner = 8
		p.icon = button.icon or button.Icon or _G[name..'IconTexture']
		if p.icon then
			p.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
			if p.icon.AddMaskTexture then
				p.mask = button:CreateMaskTexture()
				p.mask:SetTexture(Kit.media..'mask-icon.tga', 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
				p.mask:SetAllPoints(p.icon)
				p.icon:AddMaskTexture(p.mask)
			end
		end
		local highlight = button.GetHighlightTexture and button:GetHighlightTexture()
		if highlight and p.icon then
			highlight:ClearAllPoints()
			highlight:SetAllPoints(p.icon)
			highlight:SetColorTexture(1, 1, 1, 0.16)
		end
		p.cooldown = button.Cooldown or _G[name..'Cooldown']
		if p.cooldown and p.icon and not Forbidden(p.cooldown) then
			p.cooldown:ClearAllPoints()
			p.cooldown:SetAllPoints(p.icon)
			if p.cooldown.SetSwipeTexture then p.cooldown:SetSwipeTexture(Kit.media..'mask-icon.tga', 0, 0, 0, 0.72) end
		end
		-- The item's quality as a lit edge around the legend.
		p.edge = Kit:Texture(button, 'ring-6', 'OVERLAY', 1)
		p.edge:Hide()
		-- New items: the edge breathes in the lamp color until the item is looked at.
		p.glow = Kit:Texture(button, 'ring-6', 'OVERLAY', 2)
		Kit:Tint(p.glow, 'lamp')
		p.glow:Hide()
		p.pulse = p.glow:CreateAnimationGroup()
		p.pulse:SetLooping('BOUNCE')
		local fade = p.pulse:CreateAnimation('Alpha')
		fade:SetFromAlpha(0.25)
		fade:SetToAlpha(1)
		fade:SetDuration(Kit.SPEED.SLOW * 2)
		fade:SetSmoothing('IN_OUT')
		p.level = Kit:Text(button, '', 9, 'white', true)
		Kit:Font(p.level, 9, 'OUTLINE', true)
		p.quest = Kit:Icon(button, 'warning', 10, 'amber')
		p.junk = Kit:Icon(button, 'trash', 9, 'amber')
		local count = button.Count or _G[name..'Count']
		if count then
			Kit:Font(count, 10, 'OUTLINE', true)
			count:ClearAllPoints()
			if p.icon then count:SetPoint('BOTTOMRIGHT', p.icon, 'BOTTOMRIGHT', -1, 1) end
		end
		-- Pressing an item presses its key.
		button:HookScript('OnMouseDown', function() Kit:SetSprite(p.key, 'key-down') end)
		button:HookScript('OnMouseUp', function() Kit:SetSprite(p.key, 'key') end)
		button:HookScript('OnHide', function() Kit:SetSprite(p.key, 'key') end)
		-- Looking at a new item makes it old.
		button:HookScript('OnEnter', function(self)
			local where = slotOf[self]
			if where and C_NewItems and C_NewItems.RemoveNewItem then pcall(C_NewItems.RemoveNewItem, where.bag, where.slot) end
			if parts[self] then parts[self].pulse:Stop(); parts[self].glow:Hide() end
		end)
	end
	if p.size ~= size then
		p.size = size
		button:SetSize(size, size)
		local face = max(3, floor(size * 0.11 + 0.5))
		if p.icon then
			p.icon:ClearAllPoints()
			p.icon:SetPoint('TOPLEFT', face, -face)
			p.icon:SetPoint('BOTTOMRIGHT', -face, face + 1)
			Kit:Place(p.edge, p.icon, 1, 1, 1, 1)
			Kit:Place(p.glow, p.icon, 2, 2, 2, 2)
			p.level:ClearAllPoints()
			p.level:SetPoint('BOTTOMLEFT', p.icon, 'BOTTOMLEFT', 1, 1)
			p.quest:ClearAllPoints()
			p.quest:SetPoint('TOPLEFT', p.icon, 'TOPLEFT', 0, 0)
			p.junk:ClearAllPoints()
			p.junk:SetPoint('TOPRIGHT', p.icon, 'TOPRIGHT', 0, 0)
		end
	end
end

local function NewButton(device, bag, slot)
	local holder = Holder(device, bag)
	local name = format('%sSlot%d', holder:GetName(), slot)
	local ok, button = pcall(CreateFrame, 'ItemButton', name, holder, Template(bag))
	if not ok or not button then ok, button = pcall(CreateFrame, 'ItemButton', name, holder, 'ContainerFrameItemButtonTemplate') end
	if not ok or not button then ok, button = pcall(CreateFrame, 'Button', name, holder, 'ContainerFrameItemButtonTemplate') end
	if not ok or not button then return nil end
	button:SetID(slot)
	-- The bank's tab buttons find their slot from these, as the game's do.
	if tabBank[bag] == 'character' and bag ~= LEGACY_BANK or tabBank[bag] == 'account' then
		button.bankTabID, button.containerSlotID = bag, slot
	end
	slotOf[button] = {bag = bag, slot = slot, device = device}
	DressButton(button, DB().keySize)
	button:Hide()
	holder.buttons[slot] = button
	return button
end

-- Secure item buttons are made out of combat only; in a fight a bag that grew
-- shows what already exists, and the rest is made once the fight ends.
local function Build(device, bags)
	if InCombatLockdown() then
		return UI:AfterCombat(function() Build(device, bags) ; device:Layout() end, 'bags.build.'..device.key)
	end
	for _, bag in ipairs(bags) do
		local holder = Holder(device, bag)
		for slot = 1, NumSlots(bag) do
			if not holder.buttons[slot] then NewButton(device, bag, slot) end
		end
	end
end

-- What a slot holds, read once per update.
local function Category(entry, bag, slot)
	if not entry.icon then return 'empty' end
	if DB().newSection and entry.new then return 'new' end
	if entry.junk then return 'junk' end
	if entry.questItem then return 'quest' end
	if entry.equipLoc and entry.equipLoc ~= '' and entry.equipLoc ~= 'INVTYPE_NON_EQUIP_IGNORE' and (entry.classID == 2 or entry.classID == 4) then
		return 'equipment'
	end
	if entry.classID == 0 then return 'consumable' end
	if entry.classID == 5 or entry.classID == 7 or entry.classID == 3 or entry.classID == 8 or REAGENT_BAG and bag == REAGENT_BAG then
		return 'trade'
	end
	return 'other'
end

local function Read(bag, slot)
	local entry = {}
	local info = GetItemInfoTable and select(2, pcall(GetItemInfoTable, bag, slot))
	if type(info) ~= 'table' then return entry end
	entry.icon, entry.count, entry.locked, entry.quality = info.iconFileID, info.stackCount, info.isLocked, info.quality
	entry.link, entry.filtered, entry.itemID, entry.noValue = info.hyperlink, info.isFiltered, info.itemID, info.hasNoValue
	if IsSecret(entry.icon) then entry.category = 'other' return entry end
	if not entry.icon then return entry end
	if not IsSecret(entry.quality) then entry.junk = entry.quality == POOR and not entry.noValue end
	if not IsSecret(entry.itemID) and entry.itemID and ItemInfoInstant then
		local ok, _, _, _, equipLoc, _, classID = pcall(ItemInfoInstant, entry.itemID)
		if ok then entry.equipLoc, entry.classID = equipLoc, classID end
	end
	if GetQuestInfo then
		local ok, quest = pcall(GetQuestInfo, bag, slot)
		if ok and type(quest) == 'table' then
			entry.questItem = (quest.isQuestItem or quest.questID) and true or false
			entry.questStarter = quest.questID and not quest.isActive
		end
	end
	if C_NewItems and C_NewItems.IsNewItem then
		local ok, new = pcall(C_NewItems.IsNewItem, bag, slot)
		entry.new = ok and not IsSecret(new) and new and true or false
	end
	entry.category = Category(entry, bag, slot)
	return entry
end

local function ItemLevel(entry, bag, slot)
	if not (DB().itemLevel and entry.category ~= 'empty' and entry.equipLoc and entry.equipLoc ~= '' and (entry.classID == 2 or entry.classID == 4)) then return nil end
	if not (C_Item and C_Item.GetCurrentItemLevel and ItemLocation and ItemLocation.CreateFromBagAndSlot) then return nil end
	local ok, level = pcall(function() return C_Item.GetCurrentItemLevel(ItemLocation:CreateFromBagAndSlot(bag, slot)) end)
	if not ok or type(level) ~= 'number' or IsSecret(level) or level < (DB().itemLevelMin or 1) then return nil end
	return level
end

local function UpdateCooldown(button)
	local p, where = parts[button], slotOf[button]
	if not (p and p.cooldown and where) then return end
	local entry = itemOf[button]
	if not (DB().cooldowns and entry and entry.icon) then p.cooldown:Hide() return end
	local ok, start, duration, enable = pcall(GetCooldown, where.bag, where.slot)
	if not ok then return end
	if IsSecret(start) or IsSecret(duration) or IsSecret(enable) then
		p.cooldown:SetCooldown(start, duration)
	elseif CooldownFrame_Set then
		CooldownFrame_Set(p.cooldown, start or 0, duration or 0, enable)
	end
end

local function PaintSearch(button)
	local entry = itemOf[button]
	local filtered = entry and entry.filtered
	if IsSecret(filtered) then filtered = false end
	button:SetAlpha(filtered and 0.22 or 1)
end

local function UpdateButton(button)
	local where = slotOf[button]
	if not where then return end
	local entry = Read(where.bag, where.slot)
	itemOf[button] = entry
	local p, db = parts[button], DB()
	SetItemButtonTexture(button, entry.icon)
	SetItemButtonCount(button, entry.count)
	SetItemButtonDesaturated(button, (not IsSecret(entry.locked) and entry.locked) or (entry.junk and db.junkDesaturate) or false)
	if not p then return entry end
	p.key:SetAlpha(entry.icon and 1 or 0.55)
	local r, g, b = QualityColor(entry.quality)
	local showEdge = db.qualityEdge and entry.icon and r and not IsSecret(entry.quality) and entry.quality >= 2
	if entry.questItem and db.questMarker then
		p.edge:SetVertexColor(Kit:RGB('amber'))
		p.edge:Show()
	elseif showEdge then
		p.edge:SetVertexColor(r, g, b, 0.95)
		p.edge:Show()
	else
		p.edge:Hide()
	end
	p.quest:SetShown(db.questMarker and entry.questStarter and true or false)
	p.junk:SetShown(db.junkMarker and entry.junk and true or false)
	local level = ItemLevel(entry, where.bag, where.slot)
	p.level:SetText(level or '')
	if level and r then p.level:SetTextColor(r, g, b) else p.level:SetTextColor(1, 1, 1) end
	local glowing = db.newItems and entry.new
	p.glow:SetShown(glowing and true or false)
	if glowing then if not p.pulse:IsPlaying() then p.pulse:Play() end else p.pulse:Stop() end
	UpdateCooldown(button)
	PaintSearch(button)
	if button.UpdateItemContextMatching then pcall(button.UpdateItemContextMatching, button) end
	return entry
end

-- Devices ------------------------------------------------------------------------
local ORDER = {'new', 'equipment', 'consumable', 'trade', 'quest', 'other', 'junk'}
local TITLES = {new = 'New', equipment = 'Equipment', consumable = 'Consumables', trade = 'Trade goods', quest = 'Quest',
	other = 'Other', junk = 'Junk'}

local function SectionLabel(device, index)
	local label = device.labels[index]
	if not label then
		label = Kit:Label(device.content, '', 'darkDim', 8, true)
		label.rule = device.content:CreateTexture(nil, 'ARTWORK')
		label.rule:SetColorTexture(1, 1, 1, 0.08)
		label.rule:SetHeight(1)
		label.rule:SetPoint('LEFT', label, 'RIGHT', 6, 0)
		label.rule:SetPoint('RIGHT', device.content, 'RIGHT', -INNER, 0)
		device.labels[index] = label
	end
	label:Show()
	label.rule:Show()
	return label
end

-- Every key the device shows, in order: by kind (quality first within a kind)
-- or every slot in bag order.
local function Collect(device, bags)
	local list = {}
	for _, bag in ipairs(bags) do
		local holder = device.holders[bag]
		if holder then
			for slot = 1, NumSlots(bag) do
				local button = holder.buttons[slot]
				if button then list[#list + 1] = button end
			end
		end
	end
	return list
end

local function SortKey(button)
	local entry, where = itemOf[button] or {}, slotOf[button]
	local quality = entry.quality
	if IsSecret(quality) or type(quality) ~= 'number' then quality = 0 end
	local id = entry.itemID
	if IsSecret(id) or type(id) ~= 'number' then id = 0 end
	return quality, id, where.bag, where.slot
end

local function ByQuality(a, b)
	local qa, ia, ba, sa = SortKey(a)
	local qb, ib, bb, sb = SortKey(b)
	if qa ~= qb then return qa > qb end
	if ia ~= ib then return ia < ib end
	if ba ~= bb then return ba < bb end
	return sa < sb
end

local function LayoutDevice(device)
	local db = DB()
	local bags = device:Bags()
	Build(device, bags)
	local size, gap = db.keySize, db.spacing
	local columns = device.bank and db.bankColumns or db.columns
	local span = columns * size + (columns - 1) * gap
	local width = max(span + 2 * INNER + 2 * PAD, device.minWidth or 340, device:ToolWidth())
	local keys = Collect(device, bags)
	device.kitKeys = keys
	for _, holder in pairs(device.holders) do
		for _, button in pairs(holder.buttons) do button:Hide() end
	end
	for _, label in ipairs(device.labels) do label:Hide(); label.rule:Hide() end
	device.free:Hide()

	local protected = InCombatLockdown() and keys[1] and keys[1]:IsProtected()
	local y, labelIndex = INNER, 0
	local function Row(list)
		for index, button in ipairs(list) do
			DressButton(button, size)
			local column, row = (index - 1) % columns, floor((index - 1) / columns)
			if not protected then
				button:ClearAllPoints()
				button:SetPoint('TOPLEFT', device.content, 'TOPLEFT', INNER + column * (size + gap), -(y + row * (size + gap)))
			end
			button:Show()
		end
		if #list > 0 then y = y + ceil(#list / columns) * (size + gap) - gap end
	end

	local freeCount = 0
	if db.layout == 'grid' or device.bank then
		for _, button in ipairs(keys) do if not itemOf[button] then UpdateButton(button) end end
		Row(keys)
	else
		local sections = {}
		for _, button in ipairs(keys) do
			local entry = itemOf[button] or UpdateButton(button) or {}
			local category = entry.category or 'empty'
			if category == 'empty' then
				freeCount = freeCount + 1
				button:Hide()
			else
				sections[category] = sections[category] or {}
				table.insert(sections[category], button)
			end
		end
		for _, category in ipairs(ORDER) do
			local list = sections[category]
			if list and #list > 0 then
				table.sort(list, ByQuality)
				labelIndex = labelIndex + 1
				local label = SectionLabel(device, labelIndex)
				label:ClearAllPoints()
				label:SetPoint('TOPLEFT', device.content, 'TOPLEFT', INNER, -y)
				label:SetText(format('%s  %d', strupper(TITLES[category]), #list))
				y = y + SECTION - 4
				Row(list)
				y = y + 10
			end
		end
		-- Free slots are one key: drop an item on it to put it in the first free slot.
		local free = device.free
		free:SetSize(size, size)
		free:ClearAllPoints()
		free:SetPoint('TOPLEFT', device.content, 'TOPLEFT', INNER, -y)
		free.count:SetText(freeCount)
		free:Show()
		y = y + size
	end
	if protected then UI:AfterCombat(function() device:Layout() end, 'bags.layout.'..device.key) end

	local contentHeight = y + INNER
	local bottom = device.slotsRow and device.slotsRow:IsShown() and 34 or 0
	device:SetSize(width, HEAD + TOOL + contentHeight + PAD + bottom + 4)
	device.screen:ClearAllPoints()
	device.screen:SetPoint('TOPLEFT', device, 'TOPLEFT', PAD - 3, -(HEAD + TOOL) + 3)
	device.screen:SetPoint('TOPRIGHT', device, 'TOPRIGHT', -PAD + 3, -(HEAD + TOOL) + 3)
	device.screen:SetHeight(contentHeight + 6)
	device.dirtyLayout = nil
	device:UpdateHeader()
end

local function FirstFreeSlot()
	for _, bag in ipairs(BAG_IDS) do
		if bag ~= REAGENT_BAG then
			for slot = 1, NumSlots(bag) do
				local info = GetItemInfoTable and select(2, pcall(GetItemInfoTable, bag, slot))
				if type(info) ~= 'table' or not info.iconFileID then return bag, slot end
			end
		end
	end
end

local function PutInFree()
	if not (CursorHasItem and CursorHasItem()) then return end
	local bag, slot = FirstFreeSlot()
	if bag then PickupItem(bag, slot) end
end

local function FreeKey(device)
	local free = CreateFrame('Button', nil, device.content)
	free:SetFrameLevel(device.content:GetFrameLevel() + 3)
	free.skin = Kit:Skin(free, 'key-down', 'BACKGROUND', -7)
	free.skin.kitMaxCorner = 8
	free.count = Kit:Text(free, '', 11, 'ink', true)
	free.count:SetPoint('CENTER', 0, 3)
	free.label = Kit:Label(free, 'Free', 'dim', 7)
	free.label:SetPoint('BOTTOM', 0, 6)
	free:RegisterForClicks('LeftButtonUp')
	free:SetScript('OnClick', PutInFree)
	free:SetScript('OnReceiveDrag', PutInFree)
	free:SetScript('OnEnter', function(self)
		GameTooltip:SetOwner(self, 'ANCHOR_TOP')
		GameTooltip:AddLine('Free slots', 1, 1, 1)
		GameTooltip:AddLine('Drop an item here to put it in the first free slot.', 0.7, 0.7, 0.7, true)
		GameTooltip:Show()
	end)
	free:SetScript('OnLeave', function() GameTooltip:Hide() end)
	return free
end

-- A small key in a device's tool row.
local function ToolKey(parent, text, icon, onClick, tip)
	local key = Kit:Key(parent, {width = text and max(44, #text * 7 + 20) or 28, height = 22, tone = 'default', text = text, icon = icon,
		iconSize = 11, textSize = 8, onClick = onClick})
	if tip then
		key:HookScript('OnEnter', function(self)
			GameTooltip:SetOwner(self, 'ANCHOR_TOP')
			GameTooltip:AddLine(tip, 1, 1, 1)
			GameTooltip:Show()
		end)
		key:HookScript('OnLeave', function() GameTooltip:Hide() end)
	end
	return key
end

local function NewDevice(key, model, title, bank)
	local device = Kit:Device(UIParent, {name = 'JiberishSpec01'..key, model = model, title = title, radius = 12})
	device.key, device.bank = key, bank
	device.holders, device.labels = {}, {}
	device:SetFrameStrata('HIGH')
	device:SetToplevel(true)
	device:EnableMouse(true)
	device:SetClampedToScreen(true)
	device:Hide()
	-- Contents sit on the reference's black display.
	device.screen = Kit:Screen(device, {inset = 3, radius = 9, shadow = false})
	device.screen:SetFrameLevel(device:GetFrameLevel() + 1)
	Kit:Relevel(device.screen)
	device.content = device.screen.screen
	device.free = FreeKey(device)
	device.money = LCDChip(device, 96)
	device.money:SetPoint('TOPRIGHT', -PAD, -3)
	device.slots = LCDChip(device, 54)
	device.slots:SetPoint('RIGHT', device.money, 'LEFT', -6, 0)
	if device.title then device.title:SetPoint('RIGHT', device.slots, 'LEFT', -6, 0) end
	-- Tool row: search, then keys from the right.
	device.search = Kit:TextField(device, {width = 150, placeholder = 'Search',
		onChange = function(text) if SetItemSearch then pcall(SetItemSearch, text) end end})
	device.search:SetHeight(26)
	device.search.glass:SetHeight(24)
	device.search.edit.placeholder:ClearAllPoints()
	device.search.edit.placeholder:SetPoint('LEFT', device.search.glass, 'LEFT', 10, 0)
	device.search:SetPoint('TOPLEFT', PAD - 2, -(HEAD + 2))
	device.close = Kit:Key(device, {round = true, width = 22, height = 22, icon = 'close', iconSize = 9,
		onClick = function() device:Close() end})
	device.close:SetPoint('TOPRIGHT', -PAD, -(HEAD + 4))
	device.tools = {}
	function device:AddTool(tool)
		local last = self.tools[#self.tools] or self.close
		tool:SetPoint('RIGHT', last, 'LEFT', -5, 0)
		self.tools[#self.tools + 1] = tool
		return tool
	end
	device.Layout = function(self)
		if not self:IsShown() then self.dirtyLayout = true return end
		UI:Safe(LayoutDevice, self)
	end
	function device:ToolWidth()
		local width = 2 * PAD + self.search:GetWidth() + 12 + self.close:GetWidth()
		if self.tabs then width = width + self.tabs:GetWidth() * self.tabs:GetScale() + 12 end
		for _, tool in ipairs(self.tools) do width = width + tool:GetWidth() + 5 end
		return width
	end
	tinsert(UISpecialFrames, device:GetName())
	-- The lamp is lit while the device is open.
	device:HookScript('OnHide', function(self) if self.lamp and not self:IsShown() then Kit:SetLed(self.lamp, false) end end)
	return device
end

-- Updates come in bursts (a stack split fires several); one pass a frame.
local function Refill(device, bags)
	for _, bag in ipairs(bags) do
		local holder = device.holders[bag]
		if holder then
			for slot = 1, NumSlots(bag) do
				local button = holder.buttons[slot]
				if button then UI:Safe(UpdateButton, button) end
			end
		end
	end
end

-- The bags device -----------------------------------------------------------------
local bagsDevice, bankDevice
local syncing, openedForBank

local function AnyBlizzardBagOpen()
	if not IsBagOpen then return false end
	for _, bag in ipairs(BAG_IDS) do
		if IsBagOpen(bag) then return true end
	end
	return false
end

-- Close the game's own (parked) bags as well, so its key bindings stay in step.
local function CloseBlizzardBags()
	if syncing or not AnyBlizzardBagOpen() then return end
	syncing = true
	UI:Safe(CloseAllBags)
	syncing = nil
end

local function FreeSlotText()
	local free, total = 0, 0
	for _, bag in ipairs(BAG_IDS) do
		local slots = NumSlots(bag)
		if slots > 0 then
			total = total + slots
			local ok, count = pcall(GetFreeSlots, bag)
			if ok and type(count) == 'number' and not IsSecret(count) then free = free + count end
		end
	end
	return format('%d/%d', free, total)
end

local function BagSlotsRow(device)
	local row = CreateFrame('Frame', nil, device)
	row:SetHeight(28)
	row:SetPoint('BOTTOMLEFT', PAD, PAD - 2)
	row:SetPoint('BOTTOMRIGHT', -PAD, PAD - 2)
	row.keys = {}
	local x = 0
	for index, bag in ipairs(BAG_IDS) do
		local key = CreateFrame('Button', nil, row)
		key:SetSize(26, 26)
		key:SetPoint('LEFT', x, 0)
		x = x + 30
		key.skin = Kit:Skin(key, 'key', 'BACKGROUND', -7)
		key.skin.kitMaxCorner = 7
		key.icon = key:CreateTexture(nil, 'ARTWORK')
		key.icon:SetPoint('TOPLEFT', 4, -4)
		key.icon:SetPoint('BOTTOMRIGHT', -4, 5)
		key.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		key.bag = bag
		key.inventory = bag ~= BACKPACK and C_Container and C_Container.ContainerIDToInventoryID
			and select(2, pcall(C_Container.ContainerIDToInventoryID, bag)) or nil
		if type(key.inventory) ~= 'number' then key.inventory = nil end
		key:RegisterForDrag('LeftButton')
		local function Put(self)
			if not (CursorHasItem and CursorHasItem()) then return false end
			if self.bag == BACKPACK then if PutItemInBackpack then PutItemInBackpack() end
			elseif self.inventory and PutItemInBag then PutItemInBag(self.inventory) end
			return true
		end
		key:SetScript('OnClick', function(self) if not Put(self) then Kit:Play('tick') end end)
		key:SetScript('OnReceiveDrag', Put)
		key:SetScript('OnDragStart', function(self)
			if self.inventory and PickupBagFromSlot then PickupBagFromSlot(self.inventory) end
		end)
		key:SetScript('OnEnter', function(self)
			GameTooltip:SetOwner(self, 'ANCHOR_TOP')
			if self.inventory and GameTooltip:SetInventoryItem('player', self.inventory) then
				-- the bag's own tooltip
			else
				GameTooltip:AddLine(self.bag == BACKPACK and (BACKPACK_TOOLTIP or 'Backpack') or (EQUIP_CONTAINER or 'Equip a bag'), 1, 1, 1)
			end
			GameTooltip:Show()
		end)
		key:SetScript('OnLeave', function() GameTooltip:Hide() end)
		row.keys[index] = key
	end
	function row:Update()
		for _, key in ipairs(self.keys) do
			local texture = key.bag == BACKPACK and [[Interface\Buttons\Button-Backpack-Up]]
				or (key.inventory and GetInventoryItemTexture('player', key.inventory))
			key.icon:SetTexture(texture)
			key.icon:SetShown(texture ~= nil)
		end
	end
	return row
end

local function BuildBags()
	local device = NewDevice('Bags', 'BG-1', 'Bags', false)
	function device:Bags() return BAG_IDS end
	function device:UpdateHeader()
		self.money:SetValue(MoneyText(GetMoney()))
		self.slots:SetValue(FreeSlotText())
		if self.slotsRow then self.slotsRow:Update() end
	end
	device:AddTool(ToolKey(device, 'Sort', nil, function()
		if C_Container and C_Container.SortBags then C_Container.SortBags() end
	end, 'Sort the bags'))
	device:AddTool(ToolKey(device, nil, 'more', function()
		DB().bagSlots = not DB().bagSlots
		device.slotsRow:SetShown(DB().bagSlots)
		device:Layout()
	end, 'Bag slots'))
	device.slotsRow = BagSlotsRow(device)
	device.slotsRow:SetShown(DB().bagSlots)
	-- Placed by an anchor that the movers handle; the device grows up and to the left from it.
	device.anchor = CreateFrame('Frame', 'JiberishSpec01BagsAnchor', UIParent)
	device.anchor:SetSize(220, 40)
	UI:RegisterMover(device.anchor, 'bags.bags', 'Bags', {'BOTTOMRIGHT', -24, 210})
	device:SetPoint('BOTTOMRIGHT', device.anchor, 'BOTTOMRIGHT')
	device:HookScript('OnHide', function(self)
		-- Still shown: only the UI around it was hidden (Alt+Z, a cinematic).
		if self:IsShown() then return end
		if SetItemSearch then pcall(SetItemSearch, '') end
		device.search:SetValue('')
		if not syncing then Sound('latch-up') end
		CloseBlizzardBags()
	end)
	function device:Open()
		if self:IsShown() and not self.kitClosing then return end
		self:SetScale(DB().scale or 1)
		Refill(self, BAG_IDS)
		self.dirtyLayout = nil
		if not self:IsShown() then self:SetAlpha(0) end
		self:Show()
		UI:Safe(LayoutDevice, self)
		Kit:Open(self)
		-- Staggered entrance (a motion extra): keys light up in order. Alpha only:
		-- they are the game's secure item buttons.
		if Kit.Cascade then Kit:Cascade(self.kitKeys, {offset = false, step = 0.006, limit = 160}) end
		if self.lamp then Kit:SetLed(self.lamp, true) end
		Sound('open')
	end
	function device:Close()
		if not self:IsShown() then return end
		Kit:Close(self)
		CloseBlizzardBags()
	end
	return device
end

-- Follow the game's own bags: after any of its open or close calls, the device
-- shows when any of its (parked) bags is open.
local AUTO = {MerchantFrame = 'vendor', MailFrame = 'mail', AuctionHouseFrame = 'auction', AuctionFrame = 'auction',
	TradeFrame = 'trade', BankFrame = 'bank'}

local pendingReason, syncQueued
local function DoSync()
	syncQueued = false
	local reason = pendingReason
	pendingReason = nil
	if not bagsDevice then return end
	local open = AnyBlizzardBagOpen()
	if open and reason and not DB().autoOpen[reason] then
		-- Opened for a vendor or the mail with that turned off: close the game's
		-- again, unless the bags were already open before.
		if not (bagsDevice:IsShown() and not bagsDevice.kitClosing) then CloseBlizzardBags() end
		return
	end
	if open then bagsDevice:Open() else bagsDevice:Close() end
end

-- The game's open-all calls open each bag in turn; the device follows once,
-- a frame later, when they are done.
local function Sync(frame)
	if syncing then return end
	if type(frame) == 'table' and frame.GetName then
		local ok, name = pcall(frame.GetName, frame)
		local reason = ok and type(name) == 'string' and AUTO[name]
		if reason then pendingReason = reason end
	end
	if syncQueued then return end
	syncQueued = true
	C_Timer.After(0, function() UI:Safe(DoSync) end)
end

-- The bank device -----------------------------------------------------------------
local bankTab = 'character'
local function TabBags(tab)
	if tab == 'account' then return ACCOUNT_TABS end
	if tab == 'reagent' then return {REAGENT_BANK} end
	return CHARACTER_TABS
end

local function CanView(bankType)
	if not (C_Bank and C_Bank.CanViewBank) then return bankType == CHARACTER_BANK end
	local ok, can = pcall(C_Bank.CanViewBank, bankType)
	return ok and not IsSecret(can) and can and true or false
end

local function HasWarband() return #ACCOUNT_TABS > 0 and CanView(ACCOUNT_BANK) end
local function HasReagentBank()
	return REAGENT_BANK and NumSlots(REAGENT_BANK) > 0 and (not IsReagentBankUnlocked or IsReagentBankUnlocked()) and true or false
end

-- The game's bank panel decides where a right-clicked bag item goes, so it is
-- told which bank is showing, as ElvUI does.
local function TellBankPanel()
	local panel = _G.BankPanel
	if not panel or Forbidden(panel) then return end
	local bankType = bankTab == 'account' and ACCOUNT_BANK or CHARACTER_BANK
	local tabs = TabBags(bankTab)
	if type(panel.SetBankType) == 'function' then
		pcall(panel.SetBankType, panel, bankType)
	else
		panel.bankType = bankType
	end
	if tabs[1] then panel.selectedTabID = tabs[1] end
	-- Shown only while the game's bank window is parked: an invisible panel
	-- runs no OnShow, so its own buttons are never built or refreshed.
	local bank = _G.BankFrame
	if not panel:IsShown() and bank and not bank:IsVisible() then pcall(panel.Show, panel) end
end

local function BuildBank()
	local device = NewDevice('Bank', 'BK-1', 'Bank', true)
	device.minWidth = 420
	function device:Bags()
		local list = {}
		for _, bag in ipairs(TabBags(bankTab)) do
			if bag and NumSlots(bag) > 0 then list[#list + 1] = bag end
		end
		return list
	end
	function device:UpdateHeader()
		local account = bankTab == 'account'
		local money = account and C_Bank and C_Bank.FetchDepositedMoney and select(2, pcall(C_Bank.FetchDepositedMoney, ACCOUNT_BANK))
		self.money:SetValue(MoneyText(account and money or GetMoney()))
		local free, total = 0, 0
		for _, bag in ipairs(self:Bags()) do
			local slots = NumSlots(bag)
			total = total + slots
			local ok, count = pcall(GetFreeSlots, bag)
			if ok and type(count) == 'number' and not IsSecret(count) then free = free + count end
		end
		self.slots:SetValue(format('%d/%d', free, total))
		for _, key in ipairs(self.moneyKeys) do key:SetShown(account) end
	end
	-- Tabs: the character bank, the old reagent bank, the warband bank.
	device.tabValues = {'character'}
	local names = {'Bank'}
	if REAGENT_BANK then device.tabValues[#device.tabValues + 1] = 'reagent'; names[#names + 1] = 'Reagents' end
	if #ACCOUNT_TABS > 0 then device.tabValues[#device.tabValues + 1] = 'account'; names[#names + 1] = 'Warband' end
	if #names > 1 then
		device.tabs = Kit:Segmented(device, {items = names, width = 74 * #names, onChange = function(index)
			bankTab = device.tabValues[index] or 'character'
			TellBankPanel()
			Build(device, device:Bags())
			Refill(device, device:Bags())
			device:Layout()
		end})
		device.tabs:SetScale(0.8)
		device.tabs:SetPoint('LEFT', device.search, 'RIGHT', 12 / 0.8, 0)
	end
	device:AddTool(ToolKey(device, 'Sort', nil, function()
		if bankTab == 'account' and C_Container.SortAccountBankBags then C_Container.SortAccountBankBags()
		elseif C_Container.SortBankBags then C_Container.SortBankBags() end
	end, 'Sort the bank'))
	if C_Bank and C_Bank.AutoDepositItemsIntoBank then
		device:AddTool(ToolKey(device, 'Deposit', nil, function()
			pcall(C_Bank.AutoDepositItemsIntoBank, bankTab == 'account' and ACCOUNT_BANK or CHARACTER_BANK)
		end, 'Deposit every item this bank takes'))
	elseif DepositReagentBank then
		device:AddTool(ToolKey(device, 'Deposit', nil, function() DepositReagentBank() end, 'Deposit reagents'))
	end
	device.moneyKeys = {}
	if #ACCOUNT_TABS > 0 then
		for _, info in ipairs({{'Out', 'BANK_MONEY_WITHDRAW', 'Take money out of the warband bank'},
			{'In', 'BANK_MONEY_DEPOSIT', 'Put money in the warband bank'}}) do
			local key = device:AddTool(ToolKey(device, info[1], nil, function()
				if StaticPopupDialogs and StaticPopupDialogs[info[2]] then StaticPopup_Show(info[2], nil, nil, {bankType = ACCOUNT_BANK}) end
			end, info[3]))
			device.moneyKeys[#device.moneyKeys + 1] = key
		end
	end
	-- The game's own bank, for buying tabs and their settings.
	device:AddTool(ToolKey(device, nil, 'more', function() module:ShowBlizzardBank() end, 'Open the game\'s bank (buy and set up tabs)'))
	device.anchor = CreateFrame('Frame', 'JiberishSpec01BankAnchor', UIParent)
	device.anchor:SetSize(220, 40)
	UI:RegisterMover(device.anchor, 'bags.bank', 'Bank', {'TOPLEFT', 40, -110})
	device:SetPoint('TOPLEFT', device.anchor, 'TOPLEFT')
	device:HookScript('OnHide', function(self)
		-- Still shown: only the UI around it was hidden; the bank stays open.
		if self:IsShown() then return end
		if SetItemSearch then pcall(SetItemSearch, '') end
		device.search:SetValue('')
		if not device.toBlizzard then
			Sound('latch-up')
			if not device.closingFromGame then
				local close = (C_Bank and C_Bank.CloseBankFrame) or _G.CloseBankFrame
				if close then pcall(close) end
			end
		end
		device.toBlizzard, device.closingFromGame = nil, nil
	end)
	function device:Open()
		self:SetScale(DB().scale or 1)
		bankTab = 'character'
		if not CanView(CHARACTER_BANK) and HasWarband() then bankTab = 'account' end
		if self.tabs then
			for index, value in ipairs(self.tabValues) do if value == bankTab then self.tabs:SetValue(index) end end
		end
		TellBankPanel()
		Build(self, self:Bags())
		Refill(self, self:Bags())
		if not self:IsShown() then self:SetAlpha(0) end
		self:Show()
		UI:Safe(LayoutDevice, self)
		Kit:Open(self)
		-- Staggered entrance (a motion extra): keys light up in order. Alpha only:
		-- they are the game's secure item buttons.
		if Kit.Cascade then Kit:Cascade(self.kitKeys, {offset = false, step = 0.006, limit = 160}) end
		if self.lamp then Kit:SetLed(self.lamp, true) end
		Sound('open')
	end
	function device:Close() if self:IsShown() then Kit:Close(self) end end
	return device
end

-- Blizzard's frames -------------------------------------------------------------------
-- The game's bag frames stay in charge of being open or closed but are parked
-- under a hidden parent, so they are never seen and their slots never take a
-- click. Their events stop; the combined bag keeps the one it needs to build itself.
local parkedBank = false
local function ParkBank()
	local bank = _G.BankFrame
	if not bank or Forbidden(bank) then return end
	if InCombatLockdown() and bank:IsProtected() then return UI:AfterCombat(ParkBank, 'bags.parkbank') end
	parkedBank = true
	if bank:GetParent() ~= UI.hiddenParent then bank:SetParent(UI.hiddenParent) end
end

local function ParkBlizzard()
	for index = 1, NUM_CONTAINER_FRAMES or 13 do
		local frame = _G['ContainerFrame'..index]
		if frame and not Forbidden(frame) then UI:Retire(frame) end
	end
	local combined = _G.ContainerFrameCombinedBags
	if combined and not Forbidden(combined) then
		UI:Retire(combined)
		pcall(combined.RegisterEvent, combined, 'BAG_CONTAINER_UPDATE')
	end
	ParkBank()
	local bank = _G.BankFrame
	if bank and not Forbidden(bank) then
		-- The game moves its windows about; keep the bank parked unless we let it out.
		hooksecurefunc(bank, 'SetParent', function(self, parent)
			if parent == UI.hiddenParent or not parkedBank then return end
			C_Timer.After(0, ParkBank)
		end)
	end
end

function module:ShowBlizzardBank()
	local bank = _G.BankFrame
	if not bank or Forbidden(bank) or (InCombatLockdown() and bank:IsProtected()) then return end
	parkedBank = false
	bankDevice.toBlizzard = true
	bankDevice:Hide()
	bank:SetParent(UIParent)
	if ShowUIPanel and not bank:IsShown() then ShowUIPanel(bank) end
end

-- Merchant ---------------------------------------------------------------------------
local function Report(text) if DB().report then UI:Print(text) end end

local function Repair()
	local mode = DB().repair
	if mode == 'off' or not (CanMerchantRepair and CanMerchantRepair()) then return end
	local cost, can = GetRepairAllCost()
	if not can or type(cost) ~= 'number' or IsSecret(cost) or cost <= 0 then return end
	local guild = false
	if mode == 'guild' and IsInGuild and IsInGuild() and CanGuildBankRepair and CanGuildBankRepair() then
		local limit = GetGuildBankWithdrawMoney and GetGuildBankWithdrawMoney() or 0
		guild = type(limit) == 'number' and (limit < 0 or limit >= cost)
	end
	if not guild and GetMoney() < cost then return Report('Not enough money to repair.') end
	RepairAllItems(guild)
	Report(format('Repaired for %s%s.', GetMoneyString and GetMoneyString(cost) or cost, guild and ' (guild)' or ''))
end

local function JunkSlots()
	local list, value = {}, 0
	for _, bag in ipairs(BAG_IDS) do
		for slot = 1, NumSlots(bag) do
			local info = GetItemInfoTable and select(2, pcall(GetItemInfoTable, bag, slot))
			if type(info) == 'table' and info.hyperlink and not IsSecret(info.quality) and info.quality == POOR and not info.hasNoValue then
				local price = ItemInfo and select(11, ItemInfo(info.hyperlink))
				if type(price) == 'number' and price > 0 then
					list[#list + 1] = {bag, slot}
					value = value + price * (info.stackCount or 1)
				end
			end
		end
	end
	return list, value
end

local function SellJunk()
	if not DB().sellJunk then return end
	local list, value = JunkSlots()
	if #list == 0 then return end
	if C_MerchantFrame and C_MerchantFrame.SellAllJunkItems then
		pcall(C_MerchantFrame.SellAllJunkItems)
	else
		-- A few at a time: the vendor buys back only the last twelve.
		local index = 0
		local function Step()
			if not (MerchantFrame and MerchantFrame:IsShown()) then return end
			for _ = 1, 4 do
				index = index + 1
				local spot = list[index]
				if not spot then return end
				UseItem(spot[1], spot[2])
			end
			C_Timer.After(0.2, Step)
		end
		Step()
	end
	Report(format('Sold junk for %s.', GetMoneyString and GetMoneyString(value) or value))
end

-- Events -------------------------------------------------------------------------------
local dirty, queued, grew = {}, false, false
local function Flush()
	queued = false
	local bags, bank = {}, {}
	for bag in pairs(dirty) do
		if tabBank[bag] then bank[#bank + 1] = bag else bags[#bags + 1] = bag end
		dirty[bag] = nil
	end
	-- Bags that changed size get their buttons now, so a fight never needs new ones.
	if grew and not InCombatLockdown() and bagsDevice then
		grew = false
		Build(bagsDevice, BAG_IDS)
	end
	if #bags > 0 and bagsDevice then
		if bagsDevice:IsShown() then
			Refill(bagsDevice, bags)
			bagsDevice:Layout()
		else
			bagsDevice.dirtyLayout = true
		end
	end
	if #bank > 0 and bankDevice and bankDevice:IsShown() then
		Refill(bankDevice, bank)
		bankDevice:Layout()
	end
end

local function Dirty(bag)
	if type(bag) ~= 'number' or IsSecret(bag) then
		for _, id in ipairs(BAG_IDS) do dirty[id] = true end
		if bankDevice and bankDevice:IsShown() then for _, id in ipairs(bankDevice:Bags()) do dirty[id] = true end end
	else
		dirty[bag] = true
	end
	if queued then return end
	queued = true
	C_Timer.After(0, Flush)
end

local function ForVisible(func)
	for _, device in ipairs({bagsDevice, bankDevice}) do
		if device and device:IsShown() then
			for _, holder in pairs(device.holders) do
				for _, button in pairs(holder.buttons) do
					if button:IsShown() then UI:Safe(func, button) end
				end
			end
		end
	end
end

local function OnEvent(_, event, ...)
	if event == 'BAG_UPDATE' or event == 'BAG_CLOSED' then
		Dirty(...)
	elseif event == 'BAG_CONTAINER_UPDATE' or event == 'QUEST_ACCEPTED' or event == 'QUEST_REMOVED' or event == 'BAG_NEW_ITEMS_UPDATED'
		or event == 'PLAYERBANKSLOTS_CHANGED' or event == 'PLAYERREAGENTBANKSLOTS_CHANGED' or event == 'BANK_TABS_CHANGED'
		or event == 'PLAYERBANKBAGSLOTS_CHANGED' then
		if event == 'BAG_CONTAINER_UPDATE' or event == 'BANK_TABS_CHANGED' then grew = true end
		if event == 'PLAYERBANKSLOTS_CHANGED' and LEGACY_BANK then Dirty(LEGACY_BANK)
		elseif event == 'PLAYERREAGENTBANKSLOTS_CHANGED' and REAGENT_BANK then Dirty(REAGENT_BANK)
		else Dirty() end
	elseif event == 'ITEM_LOCK_CHANGED' then
		local bag, slot = ...
		if type(bag) == 'number' and type(slot) == 'number' and not IsSecret(bag) and not IsSecret(slot) then
			for _, device in ipairs({bagsDevice, bankDevice}) do
				local holder = device and device.holders[bag]
				local button = holder and holder.buttons[slot]
				if button then UI:Safe(UpdateButton, button) end
			end
		end
	elseif event == 'BAG_UPDATE_COOLDOWN' then
		ForVisible(UpdateCooldown)
	elseif event == 'INVENTORY_SEARCH_UPDATE' then
		ForVisible(function(button)
			local where, entry = slotOf[button], itemOf[button]
			if not (where and entry) then return end
			local info = GetItemInfoTable and select(2, pcall(GetItemInfoTable, where.bag, where.slot))
			entry.filtered = type(info) == 'table' and info.isFiltered or false
			PaintSearch(button)
		end)
	elseif event == 'PLAYER_MONEY' or event == 'ACCOUNT_MONEY' or event == 'PLAYER_TRADE_MONEY' then
		for _, device in ipairs({bagsDevice, bankDevice}) do
			if device and device:IsShown() then UI:Safe(device.UpdateHeader, device) end
		end
	elseif event == 'BANKFRAME_OPENED' then
		ParkBank()
		bankDevice:Open()
		if DB().autoOpen.bank and bagsDevice and not bagsDevice:IsShown() then
			openedForBank = true
			if OpenAllBags then OpenAllBags() end
		end
	elseif event == 'BANKFRAME_CLOSED' then
		bankDevice.closingFromGame = true
		bankDevice:Close()
		if not bankDevice:IsShown() then bankDevice.closingFromGame = nil end
		ParkBank()
		if openedForBank then
			openedForBank = nil
			CloseBlizzardBags()
		end
	elseif event == 'MERCHANT_SHOW' then
		if IsShiftKeyDown and IsShiftKeyDown() then return end
		UI:Safe(Repair)
		UI:Safe(SellJunk)
	elseif event == 'PLAYER_REGEN_ENABLED' then
		if bagsDevice and bagsDevice.dirtyLayout and bagsDevice:IsShown() then bagsDevice:Layout() end
	end
end

function module:Enable()
	bagsDevice = BuildBags()
	bankDevice = BuildBank()
	-- A pool sized to the bags now, so a fight never needs new buttons.
	Build(bagsDevice, BAG_IDS)
	Refill(bagsDevice, BAG_IDS)
	ParkBlizzard()
	for _, name in ipairs({'ToggleBackpack', 'ToggleAllBags', 'OpenAllBags', 'OpenBackpack', 'ToggleBag', 'CloseAllBags',
		'CloseBackpack'}) do
		if type(_G[name]) == 'function' then hooksecurefunc(name, function(...) UI:Safe(Sync, ...) end) end
	end
	local driver = CreateFrame('Frame')
	for _, event in ipairs({'BAG_UPDATE', 'BAG_CLOSED', 'BAG_CONTAINER_UPDATE', 'BAG_NEW_ITEMS_UPDATED',
		'ITEM_LOCK_CHANGED', 'BAG_UPDATE_COOLDOWN', 'INVENTORY_SEARCH_UPDATE', 'QUEST_ACCEPTED', 'QUEST_REMOVED', 'PLAYER_MONEY',
		'ACCOUNT_MONEY', 'PLAYER_TRADE_MONEY', 'BANKFRAME_OPENED', 'BANKFRAME_CLOSED', 'PLAYERBANKSLOTS_CHANGED',
		'PLAYERREAGENTBANKSLOTS_CHANGED', 'PLAYERBANKBAGSLOTS_CHANGED', 'BANK_TABS_CHANGED', 'MERCHANT_SHOW', 'PLAYER_REGEN_ENABLED'}) do
		pcall(driver.RegisterEvent, driver, event)
	end
	driver:SetScript('OnEvent', function(...) UI:Safe(OnEvent, ...) end)
	-- The bank may already be open after a reload.
	if _G.BankFrame and _G.BankFrame:IsShown() then OnEvent(nil, 'BANKFRAME_OPENED') end
end

function module:Refresh()
	for _, device in ipairs({bagsDevice, bankDevice}) do
		if device then
			device:SetScale(DB().scale or 1)
			if device.slotsRow then device.slotsRow:SetShown(DB().bagSlots) end
			if device:IsShown() then
				Refill(device, device:Bags())
				device:Layout()
			else
				device.dirtyLayout = true
			end
		end
	end
end

UI:RegisterPage('bags', {title = 'Bags', order = 19, cards = {
	{title = 'Style', rows = {
		{'segmented', 'Style', 'style.bags', items = {{'device', 'Device'}, {'blizzard', 'Blizzard'}}, reload = true,
			note = 'Every bag in one BG-1 device and the bank in a BK-1, items on keys over a black display.'},
		{'segmented', 'Layout', 'bags.layout', items = {{'sections', 'Sections'}, {'grid', 'Grid'}},
			note = 'Sections sort items by kind, with free slots as one key. Grid keeps every bag slot in place.'},
		{'switch', 'New items first', 'bags.newSection', 'Items you just got sit in their own section at the top.'},
	}},
	{title = 'Size', rows = {
		{'slider', 'Columns', 'bags.columns', 6, 20, 1},
		{'slider', 'Bank columns', 'bags.bankColumns', 8, 24, 1},
		{'slider', 'Key size', 'bags.keySize', 26, 48, 1, format = function(v) return v..' px' end},
		{'slider', 'Spacing', 'bags.spacing', 0, 10, 1, format = function(v) return v..' px' end},
		{'slider', 'Scale', 'bags.scale', 0.6, 1.4, 0.05, format = function(v) return format('%d%%', v * 100 + 0.5) end},
	}},
	{title = 'Keys', rows = {
		{'switch', 'Item level', 'bags.itemLevel', 'On weapons and armor.'},
		{'slider', 'Lowest item level shown', 'bags.itemLevelMin', 1, 700, 1},
		{'switch', 'Quality edge', 'bags.qualityEdge', 'A lit edge in the item\'s quality color (uncommon and up).'},
		{'switch', 'New item pulse', 'bags.newItems', 'New items breathe until you point at them.'},
		{'switch', 'Quest marker', 'bags.questMarker', 'Quest items get an amber edge, quest starters a sign.'},
		{'switch', 'Junk marker', 'bags.junkMarker'},
		{'switch', 'Gray out junk', 'bags.junkDesaturate'},
		{'switch', 'Cooldowns', 'bags.cooldowns', 'A swipe over items on cooldown.'},
	}},
	{title = 'Opening', rows = {
		{'switch', 'With a vendor', 'bags.autoOpen.vendor'},
		{'switch', 'With the mail', 'bags.autoOpen.mail'},
		{'switch', 'With the auction house', 'bags.autoOpen.auction'},
		{'switch', 'With the bank', 'bags.autoOpen.bank'},
		{'switch', 'With a trade', 'bags.autoOpen.trade'},
	}},
	{title = 'Merchant', rows = {
		{'switch', 'Sell junk', 'bags.sellJunk', 'Gray items are sold when a vendor opens. Hold Shift to skip.'},
		{'segmented', 'Repair', 'bags.repair', items = {{'off', 'Off'}, {'player', 'Own'}, {'guild', 'Guild'}},
			note = 'Repairs everything when a vendor opens; Guild uses guild funds when it can.'},
		{'switch', 'Report in chat', 'bags.report', 'What was sold and what repairs cost.'},
	}},
}})
