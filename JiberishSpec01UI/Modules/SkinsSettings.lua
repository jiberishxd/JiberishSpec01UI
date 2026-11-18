-- The game's Options window, the game menu and Edit Mode, all the way in.
-- Skins.lua gives each its housing; this file dresses what the walk can't see
-- or would dress the wrong way:
--   Options      the category list as printed rows on a black screen, the
--                chosen one lit with a lamp and a key-colored rule; section
--                headers as ruled small caps; expandable sections as glass
--                plates with a chevron; checkboxes, sliders with steppers,
--                dropdowns with their arrow keys, key binding buttons, tabs,
--                the search field and the bottom keys as SPEC-01 controls
--   Game menu    every button a keycap, Return to Game the light key
--   Edit Mode    the manager's and a system's settings (pooled per system) as
--                SPEC-01 controls
-- The Options rows are pooled: they are dressed after every list update and
-- row init, from our own timer. Post-hooks only; our parts in side tables.
local _, UI = ...
local Kit = UI.Kit

local module = UI.modules.windows
if not module or not module.parts then return end
local P = module.parts

local CreateFrame, C_Timer, hooksecurefunc = CreateFrame, C_Timer, hooksecurefunc
local max = math.max
local type, ipairs, pairs, pcall, unpack = type, ipairs, pairs, pcall, unpack

local IsSecret, Is, Hide, Own, First = P.IsSecret, P.Is, P.Hide, P.Own, P.First

module.extras = module.extras or {}

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

local function WatchBox(box, dress)
	if type(box) ~= 'table' or not First('setbox', box) then return end
	local queued = Debounce(function()
		if box.ForEachFrame then pcall(box.ForEachFrame, box, function(row) UI:Safe(dress, row) end) end
	end)
	if type(box.Update) == 'function' then hooksecurefunc(box, 'Update', queued) end
	local util = _G.ScrollUtil
	local add = util and (util.AddInitializedFrameCallback or util.AddAcquiredFrameCallback)
	if add then pcall(add, box, function() queued() end, {}, true) end
	queued()
	return queued
end

local function HideTextures(frame, keep)
	for _, region in ipairs({frame:GetRegions()}) do
		if Is(region, 'Texture') and not (keep and keep[region]) and not P.IsOwn(region) then region:SetAlpha(0) end
	end
end

-- A button that should read as a charcoal keycap whatever its template.
local function KeyButton(button)
	if not Is(button, 'Button') or P.IsOwn(button) then return end
	if button.Left or button.Middle or button.Right or button.NineSlice then
		P.PushButton(button)
		return
	end
	if not First('setkey', button) then return end
	local keep = {}
	local text = button.GetFontString and button:GetFontString()
	if Is(button.Icon, 'Texture') then keep[button.Icon] = true end
	P.HideButtonArt(button)
	HideTextures(button, keep)
	P.Keycap(button, false)
	P.SetFonts(button, P.fonts.key, P.fonts.keyHot, P.fonts.keyDim)
	if Is(text, 'FontString') then text:SetTextColor(Kit:RGB('darkInk')) end
end

-- A settings checkbox: only the tick survives, on the kit's small key.
local function SettingsCheckbox(checkbox)
	if not Is(checkbox, 'CheckButton') then return end
	local checked = checkbox.GetCheckedTexture and checkbox:GetCheckedTexture()
	local keep = {}
	if Is(checked, 'Texture') then keep[checked] = true end
	local disabled = checkbox.GetDisabledCheckedTexture and checkbox:GetDisabledCheckedTexture()
	if Is(disabled, 'Texture') then keep[disabled] = true end
	HideTextures(checkbox, keep)
	P.Checkbox(checkbox)
end

-- A dropdown with its arrow keys either side (SettingsDropdownWithButtons).
local function DropdownControl(control)
	if type(control) ~= 'table' or P.Forbidden(control) then return end
	if Is(control.Dropdown, 'Button') or Is(control.Dropdown, 'DropdownButton') then P.Dropdown(control.Dropdown) end
	P.StepButton(control.DecrementButton, 'chevron-left')
	P.StepButton(control.IncrementButton, 'chevron-right')
end

local function StepSlider(holder)
	if type(holder) ~= 'table' or P.Forbidden(holder) then return end
	if Is(holder.Slider, 'Slider') then P.Slider(holder.Slider) end
	P.StepButton(holder.Back, 'chevron-left')
	P.StepButton(holder.Forward, 'chevron-right')
	for _, key in ipairs({'LeftText', 'RightText', 'TopText', 'MinText', 'MaxText'}) do
		local label = holder[key]
		if Is(label, 'FontString') then label:SetTextColor(Kit:RGB('darkDim')) end
	end
end

-- Options: the category list -------------------------------------------------------------------
local categoryRows = setmetatable({}, {__mode = 'k'}) -- row -> {lamp, rule}

local function CurrentCategoryName()
	local panel = _G.SettingsPanel
	if type(panel) ~= 'table' or type(panel.GetCurrentCategory) ~= 'function' then return nil end
	local ok, category = pcall(panel.GetCurrentCategory, panel)
	if not ok or type(category) ~= 'table' or type(category.GetName) ~= 'function' then return nil end
	local ok2, name = pcall(category.GetName, category)
	if ok2 and not IsSecret(name) and type(name) == 'string' then return name end
end

local function LabelOf(row)
	local label = row.Label or row.Text or (row.GetFontString and row:GetFontString())
	return Is(label, 'FontString') and label or nil
end

local function PaintCategory(row, current)
	local parts = categoryRows[row]
	if not parts then return end
	local label = LabelOf(row)
	local text = label and label:GetText()
	local on = current ~= nil and not IsSecret(text) and text == current
	Kit:ShowLed(parts.lamp, on)
	Kit:SetLed(parts.lamp, on)
	parts.rule:SetShown(on)
	if label then label:SetTextColor(Kit:RGB(on and 'darkInk' or (parts.header and 'darkDim' or 'darkInk'))) end
	if label and parts.header then label:SetAlpha(1) elseif label then label:SetAlpha(on and 1 or 0.78) end
end

local function CategoryRow(row)
	if P.Forbidden(row) then return end
	if not categoryRows[row] then
		Hide(row.Background)
		HideTextures(row)
		local parts = {}
		parts.lamp = Own(Kit:Led(row, 4, false))
		parts.lamp:SetPoint('LEFT', row, 'LEFT', 6, 0)
		Kit:ShowLed(parts.lamp, false)
		parts.rule = Own(row:CreateTexture(nil, 'ARTWORK'))
		parts.rule:SetColorTexture(1, 1, 1, 1)
		Kit:Tint(parts.rule, 'lamp', 0.8)
		parts.rule:SetPoint('TOPLEFT', row, 'TOPLEFT', 0, -3)
		parts.rule:SetPoint('BOTTOMLEFT', row, 'BOTTOMLEFT', 0, 3)
		parts.rule:SetWidth(UI.Pixel.Px(row, 2))
		parts.rule:Hide()
		-- Top-level categories (with an expand toggle) read as printed headers.
		parts.header = row.Toggle ~= nil
		local label = LabelOf(row)
		if label then
			if parts.header then Kit:Font(label, 9, nil, true) else Kit:Font(label, 10, nil, false) end
		end
		local toggle = row.Toggle
		if Is(toggle, 'Button') then
			P.HideButtonArt(toggle)
			HideTextures(toggle)
			local chevron = Own(Kit:Icon(toggle, 'chevron-down', 9, 'darkDim'))
			chevron:SetPoint('CENTER')
		end
		row:HookScript('OnEnter', function(self) local l = LabelOf(self) if l then l:SetAlpha(1) end end)
		row:HookScript('OnLeave', function(self) PaintCategory(self, CurrentCategoryName()) end)
		categoryRows[row] = parts
	end
	PaintCategory(row, CurrentCategoryName())
end

local function RepaintCategories()
	local current = CurrentCategoryName()
	for row in pairs(categoryRows) do
		if row:IsVisible() then UI:Safe(PaintCategory, row, current) end
	end
end

-- Options: the settings list ---------------------------------------------------------------------
local headers = setmetatable({}, {__mode = 'k'})

-- A section header (a row with a nine-slice): ruled small caps.
local function SectionHeader(row)
	Hide(row.NineSlice)
	if headers[row] then return end
	local rule = Own(row:CreateTexture(nil, 'ARTWORK'))
	rule:SetColorTexture(1, 1, 1, 1)
	Kit:Tint(rule, 'darkEdge')
	rule:SetPoint('BOTTOMLEFT', row, 'BOTTOMLEFT', 18, 6)
	rule:SetPoint('BOTTOMRIGHT', row, 'BOTTOMRIGHT', -32, 6)
	rule:SetHeight(UI.Pixel.Px(row, 1))
	headers[row] = rule
	local title = row.Title or row.Text
	if Is(title, 'FontString') then
		Kit:Font(title, 10, nil, true)
		title:SetTextColor(Kit:RGB('darkInk'))
	end
end

-- An expandable section's header button: a glass plate with a chevron.
local expanders = setmetatable({}, {__mode = 'k'})
local function Expander(row, button)
	if not Is(button, 'Button') then return end
	local parts = expanders[button]
	if not parts then
		for _, key in ipairs({'Left', 'Middle', 'Right'}) do Hide(button[key]) end
		P.HideButtonArt(button)
		HideTextures(button)
		local plate = P.Back(button, {surface = 'glass', radius = 5, shadow = false}, -2, -1, -2, -3)
		plate:SetFrameLevel(max(button:GetFrameLevel() - 1, 0))
		Kit:Relevel(plate)
		local lid = Own(CreateFrame('Frame', nil, button))
		lid:SetAllPoints()
		lid:EnableMouse(false)
		parts = {chevron = Own(Kit:Icon(lid, 'chevron-right', 9, 'darkDim'))}
		parts.chevron:SetPoint('RIGHT', -12, 0)
		local text = button.GetFontString and button:GetFontString()
		if Is(text, 'FontString') then
			Kit:Font(text, 10, nil, true)
			text:SetTextColor(Kit:RGB('darkInk'))
		end
		button:HookScript('OnEnter', function() Kit:Tint(parts.chevron, 'darkInk') end)
		button:HookScript('OnLeave', function() Kit:Tint(parts.chevron, 'darkDim') end)
		expanders[button] = parts
		if type(row.OnExpandedChanged) == 'function' then
			hooksecurefunc(row, 'OnExpandedChanged', function(self, expanded)
				Kit:SetIcon(parts.chevron, (not IsSecret(expanded) and expanded) and 'chevron-down' or 'chevron-right')
			end)
		end
	end
end

local function Bindings(row)
	local pool = row.bindingsPool
	if type(pool) == 'table' and pool.EnumerateActive then
		for panel in pool:EnumerateActive() do
			KeyButton(panel.Button1)
			KeyButton(panel.Button2)
			if panel.CustomButton then KeyButton(panel.CustomButton) end
			P.RelightRegions(panel)
		end
	end
end

local function SettingsRow(row)
	if P.Forbidden(row) then return end
	if row.NineSlice then SectionHeader(row) end
	if row.Checkbox then SettingsCheckbox(row.Checkbox) end
	if row.Control then DropdownControl(row.Control) end
	local button = row.Button
	if Is(button, 'Button') then
		if type(row.OnExpandedChanged) == 'function' then Expander(row, button) else KeyButton(button) end
	end
	if row.SliderWithSteppers then StepSlider(row.SliderWithSteppers) end
	KeyButton(row.Button1)
	KeyButton(row.Button2)
	KeyButton(row.ToggleTest)
	KeyButton(row.PushToTalkKeybindButton)
	if type(row.VUMeter) == 'table' then
		Hide(row.VUMeter.NineSlice)
		if Is(row.VUMeter.Status, 'StatusBar') then P.StatusBar(row.VUMeter.Status) end
	end
	if type(row.Controls) == 'table' then
		for _, control in ipairs(row.Controls) do
			if type(control) == 'table' and control.SliderWithSteppers then StepSlider(control.SliderWithSteppers) end
		end
	end
	for _, key in ipairs({'BaseTab', 'RaidTab'}) do
		if Is(row[key], 'Button') then P.Tab(row[key]) end
	end
	for _, key in ipairs({'BaseQualityControls', 'RaidQualityControls'}) do
		local group = row[key]
		if type(group) == 'table' and group.GetChildren then
			for _, child in ipairs({group:GetChildren()}) do
				if child.SliderWithSteppers then StepSlider(child.SliderWithSteppers) end
				if child.Checkbox then SettingsCheckbox(child.Checkbox) end
				if child.Control then DropdownControl(child.Control) end
			end
		end
	end
	Bindings(row)
	-- Labels: light, in the reference's typeface.
	local text = row.Text or row.Label
	if Is(text, 'FontString') and First('setlabel', text) then Kit:Font(text, 10, nil, false) end
	P.RelightRegions(row)
end

module.extras.SettingsPanel = function(panel)
	if not First('setpanel', panel) then return end
	Hide(panel.Bg)
	P.Close(panel.ClosePanelButton)
	if Is(panel.SearchBox, 'EditBox') then P.EditBox(panel.SearchBox) end
	KeyButton(panel.ApplyButton)
	KeyButton(panel.CloseButton)
	for _, key in ipairs({'GameTab', 'AddOnsTab'}) do
		if Is(panel[key], 'Button') then P.Tab(panel[key]) end
	end
	local list = panel.CategoryList
	if type(list) == 'table' then
		P.Strip(list)
		if First('setcatscreen', list) then Own(Kit:Shell(list, {surface = 'screen', radius = 6, shadow = false})) end
		-- Already a black screen: the list inside gets no second one from the walk.
		if P.Screened then P.Screened(list) end
		P.ScrollBar(list.ScrollBar)
		WatchBox(list.ScrollBox, CategoryRow)
	end
	local container = panel.Container
	if type(container) == 'table' then
		P.Strip(container)
		if First('setcontainer', container) then Own(Kit:Shell(container, {surface = 'screen', radius = 6, shadow = false})) end
		if P.Screened then P.Screened(container) end
		local settings = container.SettingsList
		if type(settings) == 'table' then
			P.Strip(settings)
			local header = settings.Header
			if type(header) == 'table' then
				P.Strip(header)
				KeyButton(header.DefaultsButton)
				if Is(header.Title, 'FontString') then
					Kit:Font(header.Title, 15, nil, true)
					header.Title:SetTextColor(Kit:RGB('darkInk'))
				end
			end
			P.ScrollBar(settings.ScrollBar)
			WatchBox(settings.ScrollBox, SettingsRow)
		end
	end
	-- The chosen category lights as the player moves around.
	for _, name in ipairs({'SelectCategory', 'DisplayCategory', 'SetCurrentCategory', 'SelectTab'}) do
		if type(panel[name]) == 'function' then
			hooksecurefunc(panel, name, function() C_Timer.After(0, RepaintCategories) end)
		end
	end
	panel:HookScript('OnShow', function() C_Timer.After(0, RepaintCategories) end)
end

-- Game menu ------------------------------------------------------------------------------------
local function GameMenuButtons(menu)
	local pool = menu.buttonPool
	if type(pool) == 'table' and pool.EnumerateActive then
		for button in pool:EnumerateActive() do UI:Safe(KeyButton, button) end
	end
	for _, child in ipairs({menu:GetChildren()}) do
		if Is(child, 'Button') and not P.IsOwn(child) and child ~= menu.CloseButton then UI:Safe(KeyButton, child) end
	end
end

module.extras.GameMenuFrame = function(menu)
	if not First('gamemenu', menu) then return end
	P.DialogHeader(menu.Header)
	if type(menu.InitButtons) == 'function' then
		hooksecurefunc(menu, 'InitButtons', function(self) C_Timer.After(0, function() UI:Safe(GameMenuButtons, self) end) end)
	end
	menu:HookScript('OnShow', function(self) C_Timer.After(0, function() UI:Safe(GameMenuButtons, self) end) end)
	GameMenuButtons(menu)
end

-- Edit Mode ------------------------------------------------------------------------------------
local function EditModeControls(frame)
	for _, child in ipairs({frame:GetChildren()}) do
		if not P.IsOwn(child) and not P.Forbidden(child) then
			if Is(child.Button, 'CheckButton') then SettingsCheckbox(child.Button) end
			if Is(child.Slider, 'Slider') then P.Slider(child.Slider)
			elseif type(child.Slider) == 'table' and child.Slider.Slider then StepSlider(child.Slider) end
			if type(child.SliderWithSteppers) == 'table' then StepSlider(child.SliderWithSteppers) end
			if type(child.Dropdown) == 'table' and child.Dropdown.Arrow then P.Dropdown(child.Dropdown) end
			if child.Label and Is(child.Label, 'FontString') then child.Label:SetTextColor(Kit:RGB('darkInk')) end
		end
	end
end

module.extras.EditModeManagerFrame = function(frame)
	if not First('editmode', frame) then return end
	for _, key in ipairs({'ShowGridCheckButton', 'EnableSnapCheckButton', 'EnableAdvancedOptionsCheckButton'}) do
		local holder = frame[key]
		if type(holder) == 'table' and Is(holder.Button, 'CheckButton') then SettingsCheckbox(holder.Button) end
	end
	local spacing = frame.GridSpacingSlider
	if type(spacing) == 'table' then
		if Is(spacing.Slider, 'Slider') then P.Slider(spacing.Slider) end
		if type(spacing.Slider) == 'table' and spacing.Slider.Slider then StepSlider(spacing.Slider) end
	end
	KeyButton(frame.RevertAllChangesButton)
	KeyButton(frame.SaveChangesButton)
	local account = frame.AccountSettings
	if type(account) == 'table' then
		P.Strip(account)
		local settings = account.Settings
		if type(settings) == 'table' then EditModeControls(settings) end
		local expander = account.SettingsContainer or account.Expander
		if type(expander) == 'table' then P.Queue(expander) end
	end
	frame:HookScript('OnShow', function(self) P.Queue(self) end)
end

module.extras.EditModeSystemSettingsDialog = function(dialog)
	if not First('editdialog', dialog) then return end
	local function Dress()
		local settings = dialog.Settings
		if type(settings) == 'table' then EditModeControls(settings) end
		local buttons = dialog.Buttons
		if type(buttons) == 'table' and buttons.GetChildren then
			for _, child in ipairs({buttons:GetChildren()}) do KeyButton(child) end
		end
		local extra = dialog.ExtraButtons
		if type(extra) == 'table' and extra.GetChildren then
			for _, child in ipairs({extra:GetChildren()}) do KeyButton(child) end
		end
		if Is(dialog.Title, 'FontString') then
			Kit:Font(dialog.Title, 11, nil, true)
			dialog.Title:SetTextColor(Kit:RGB('darkInk'))
		end
		P.Queue(dialog)
	end
	local soon = Debounce(Dress)
	-- A system's settings are pooled and rebuilt each time a system is chosen.
	for _, name in ipairs({'AttachToSystemFrame', 'UpdateSettings', 'UpdateButtons', 'UpdateExtraButtons', 'UpdateDialog'}) do
		if type(dialog[name]) == 'function' then hooksecurefunc(dialog, name, soon) end
	end
	dialog:HookScript('OnShow', soon)
	soon()
end
