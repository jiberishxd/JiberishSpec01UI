-- Profiles: named sets of every setting, shared across characters, with each
-- character choosing its own. A profile can be written out as one line of text
-- and read back in, here or on another account.
--
-- The live settings are JiberishSpec01DB itself, as Core uses them; the
-- profiles are kept beside them under JiberishSpec01DB.__profiles. At logout the
-- live settings are saved under the profile they belong to; at load, when this
-- character wants a different profile, its saved copy replaces the live
-- settings in place (before any module starts), and the defaults fill in the rest.
-- Keys starting with '__' (the profile store, account-wide state) belong to no
-- profile: they are never copied, swapped, exported or imported.
local ADDON, UI = ...
local Kit = UI.Kit

local CreateFrame, UIParent = CreateFrame, UIParent
local floor, max = math.floor, math.max

local STORE, DEFAULT = '__profiles', 'Default'
local FORMAT_VERSION = 1

local function CharKey()
	local name, realm = UnitName('player'), GetRealmName and GetRealmName()
	return (name or '?')..' - '..(realm or '?')
end

local function Reserved(key) return type(key) == 'string' and strsub(key, 1, 2) == '__' end

-- A deep copy; at the top level, '__' keys are left out.
local function Copy(value, depth)
	if type(value) ~= 'table' then return value end
	depth = depth or 0
	if depth > 40 then return {} end
	local out = {}
	for key, item in pairs(value) do
		if depth > 0 or not Reserved(key) then out[key] = Copy(item, depth + 1) end
	end
	return out
end

-- Settings that belong to this computer or this session, never to a shared string.
local PRIVATE = {{'chat', 'log'}, {'sound', 'muted'}, {'sound', 'errorSpeechWas'}, {'layout', 'lastHeight'}, {'uiScale'}, {'setup'}}
local function StripPrivate(data)
	for key in pairs(data) do
		if Reserved(key) then data[key] = nil end
	end
	for _, path in ipairs(PRIVATE) do
		local node = data
		for index = 1, #path - 1 do
			node = type(node) == 'table' and node[path[index]] or nil
		end
		if type(node) == 'table' then node[path[#path]] = nil end
	end
	return data
end

-- Drop any imported value whose type differs from its default, all the way down.
local function Conform(data, defaults, depth)
	if type(data) ~= 'table' or type(defaults) ~= 'table' or (depth or 0) > 40 then return data end
	for key, value in pairs(data) do
		local default = defaults[key]
		if default ~= nil then
			if type(value) ~= type(default) then data[key] = nil
			elseif type(value) == 'table' then Conform(value, default, (depth or 0) + 1) end
		end
	end
	return data
end

local function Fill(target, source)
	for key, value in pairs(source) do
		if type(value) == 'table' then
			if type(target[key]) ~= 'table' then target[key] = {} end
			Fill(target[key], value)
		elseif target[key] == nil then
			target[key] = value
		end
	end
	return target
end

local function Store(db)
	local store = db[STORE]
	if type(store) ~= 'table' then
		store = {}
		db[STORE] = store
	end
	if type(store.profiles) ~= 'table' then store.profiles = {} end
	if type(store.chars) ~= 'table' then store.chars = {} end
	return store
end

-- The live settings become a copy of data, with the defaults filled in.
local function LoadInto(db, data)
	for key in pairs(db) do
		if not Reserved(key) then db[key] = nil end
	end
	for key, value in pairs(type(data) == 'table' and data or {}) do
		if not Reserved(key) then db[key] = Copy(value, 1) end
	end
	Fill(db, UI.defaults)
	if UI.Migrate then UI:Migrate(db) end
end

local function Wanted(store) return store.chars[CharKey()] or DEFAULT end

local loader = CreateFrame('Frame')
loader:RegisterEvent('ADDON_LOADED')
loader:RegisterEvent('PLAYER_LOGOUT')
loader:RegisterEvent('PLAYER_LOGIN')
loader:SetScript('OnEvent', function(_, event, name)
	if event == 'ADDON_LOADED' then
		if name ~= ADDON then return end
		local db = JiberishSpec01DB
		if type(db) ~= 'table' then return end -- first run: Core makes it, and logout saves it
		local store = Store(db)
		-- A new install starts from the shipped default profile (frame positions
		-- left out: the layout it names is solved for this screen after login).
		if UI.freshInstall and UI.DEFAULT_PROFILE then
			local ok, data = pcall(UI.DecodeProfile, UI, UI.DEFAULT_PROFILE)
			if ok and type(data) == 'table' then
				data.movers, data.hub = nil, nil
				LoadInto(db, data)
				UI.applyDefaultLayout = type(db.layout) == 'table' and db.layout.preset or nil
			end
		end
		local wanted = Wanted(store)
		if store.live == nil then store.live = wanted end
		store.discard = nil -- from 0.5 builds that deferred a reset to the next load
		if store.live ~= wanted then
			-- Keep what is live under its own name first.
			store.profiles[store.live] = Copy(db)
			LoadInto(db, store.profiles[wanted])
			store.live = wanted
		end
	elseif event == 'PLAYER_LOGIN' then
		-- The default profile's layout, solved for this screen once frames exist.
		local preset = UI.applyDefaultLayout
		if preset and UI.ApplyLayoutPreset then
			UI.applyDefaultLayout = nil
			C_Timer.After(2.5, function()
				UI:AfterCombat(function() UI:Safe(UI.ApplyLayoutPreset, UI, preset) end, 'defaultLayout')
			end)
		end
	elseif event == 'PLAYER_LOGOUT' then
		local db = JiberishSpec01DB
		if type(db) ~= 'table' then return end
		local store = Store(db)
		store.live = store.live or Wanted(store)
		store.profiles[store.live] = Copy(db)
	end
end)

-- API ------------------------------------------------------------------------------
local function Live()
	local store = Store(UI.db)
	store.live = store.live or Wanted(store)
	return store
end

function UI:ActiveProfile() return Live().live end
-- The profile this character loads next time; differs from the active one while a switch waits for a reload.
function UI:WantedProfile() return Wanted(Live()) end

function UI:ProfileNames()
	local store, names, seen = Live(), {}, {}
	local function Add(profile)
		if profile and not seen[profile] then
			seen[profile] = true
			names[#names + 1] = profile
		end
	end
	Add(store.live)
	Add(DEFAULT)
	for profile in pairs(store.profiles) do Add(profile) end
	table.sort(names, function(a, b) return strlower(a) < strlower(b) end)
	return names
end

local function Exists(profile)
	local store = Live()
	return profile == store.live or store.profiles[profile] ~= nil or profile == DEFAULT
end

local function AskReload(text)
	Kit:AlertDialog({title = 'Reload to apply', text = text, confirm = 'Reload', onConfirm = ReloadUI})
end

function UI:SwitchProfile(profile)
	local store = Live()
	if not profile or profile == Wanted(store) then return end
	-- The current settings are saved under their own name when the game logs out.
	store.chars[CharKey()] = profile ~= DEFAULT and profile or nil
	if profile == store.live then
		-- Back to the profile already loaded: the waiting switch is called off.
		Kit:Toast({title = 'Profile kept', text = format('This character stays on "%s".', profile)})
		Kit:Apply()
		return
	end
	Kit:Apply()
	AskReload(format('This character will use the profile "%s". It loads after a reload.', profile))
end

-- Replace the live settings now; modules that keep their own copies catch up after a reload.
local function LoadNow(data)
	LoadInto(UI.db, data)
	Kit:Apply()
	UI:NeedsReload()
end

local function Clean(profile)
	profile = strtrim(tostring(profile or ''))
	if profile == '' or #profile > 48 or profile == STORE then return nil end
	return profile
end

function UI:NewProfile(profile, switch)
	profile = Clean(profile)
	if not profile then return false end
	if Exists(profile) then
		Kit:Toast({title = 'Name taken', text = format('A profile called "%s" already exists.', profile), tone = 'warning'})
		return false
	end
	Live().profiles[profile] = {}
	if switch then
		Kit:AlertDialog({title = 'New profile', text = format('Made "%s" with the default settings. Use it on this character now?', profile),
			confirm = 'Use it', onConfirm = function() UI:SwitchProfile(profile) end})
	end
	return true
end

-- Copy another profile's settings over the one in use.
function UI:CopyProfile(source)
	local store = Live()
	if not source or source == store.live then return end
	local data = store.profiles[source]
	if not data and source ~= DEFAULT then return end
	Kit:AlertDialog({title = 'Copy settings', text = format('Replace every setting in "%s" with the ones from "%s"?', store.live, source),
		confirm = 'Copy', onConfirm = function()
			LoadNow(data or {})
			store.profiles[store.live] = Copy(UI.db)
			Kit:Toast({title = 'Settings copied', text = format('"%s" now matches "%s". Reload to apply them everywhere.', store.live, source), tone = 'success'})
		end})
end

function UI:RenameProfile(profile)
	local store = Live()
	profile = Clean(profile)
	if not profile or profile == store.live then return end
	if Exists(profile) then
		Kit:Toast({title = 'Name taken', text = format('A profile called "%s" already exists.', profile), tone = 'warning'})
		return
	end
	local old = store.live
	-- Every character without a choice uses Default, so it keeps its name.
	if old == DEFAULT then
		Kit:Toast({title = 'Default stays', text = 'The Default profile keeps its name. Make a new profile, or copy this one into it.', tone = 'warning'})
		return
	end
	store.profiles[profile] = store.profiles[old]
	store.profiles[old] = nil
	for char, used in pairs(store.chars) do
		if used == old then store.chars[char] = profile end
	end
	store.live = profile
	Kit:Play('success')
end

function UI:DeleteProfile(profile)
	local store = Live()
	if not profile or profile == store.live then return end
	if profile == DEFAULT then
		Kit:Toast({title = 'Default stays', text = 'Characters without a profile of their own use Default, so it cannot be deleted.', tone = 'warning'})
		return
	end
	Kit:AlertDialog({title = 'Delete profile', text = format('Delete "%s"? Characters using it go back to "%s".', profile, DEFAULT),
		confirm = 'Delete', onConfirm = function()
			store.profiles[profile] = nil
			for char, used in pairs(store.chars) do
				if used == profile then store.chars[char] = nil end
			end
			Kit:Play('success')
			Kit:Apply()
		end})
end

function UI:ResetProfile()
	local store = Live()
	Kit:AlertDialog({title = 'Reset profile', text = format('Put every setting in "%s" back to its default?', store.live),
		confirm = 'Reset', onConfirm = function()
			LoadNow({})
			store.profiles[store.live] = Copy(UI.db)
			Kit:Toast({title = 'Profile reset', text = 'Every setting is back to its default. Reload to apply them everywhere.', tone = 'success'})
		end})
end

-- Profile strings -------------------------------------------------------------------
-- Format: SPEC01:<version>:<adler-32 of the payload, hex>:<payload in base64>.
-- The payload is our own compact encoding of plain tables, strings, numbers and
-- booleans, read back without running any code.
local function Serialize(value, out, depth)
	local kind = type(value)
	if kind == 'table' then
		if depth > 40 then out[#out + 1] = 'TE' return end
		out[#out + 1] = 'T'
		local keys = {}
		for key in pairs(value) do
			local keyKind = type(key)
			if keyKind == 'string' or keyKind == 'number' or keyKind == 'boolean' then keys[#keys + 1] = key end
		end
		table.sort(keys, function(a, b)
			local ka, kb = type(a), type(b)
			if ka ~= kb then return ka < kb end
			if ka == 'boolean' then return (a and 1 or 0) < (b and 1 or 0) end
			return a < b
		end)
		for _, key in ipairs(keys) do
			local item = value[key]
			local itemKind = type(item)
			if not (depth == 0 and Reserved(key)) and (itemKind == 'table' or itemKind == 'string' or itemKind == 'number' or itemKind == 'boolean') then
				Serialize(key, out, depth + 1)
				Serialize(item, out, depth + 1)
			end
		end
		out[#out + 1] = 'E'
	elseif kind == 'string' then
		out[#out + 1] = 'S'..#value..':'..value
	elseif kind == 'number' then
		-- Not a number or infinite: written as 0.
		if value ~= value or value == math.huge or value == -math.huge then value = 0 end
		out[#out + 1] = 'N'..format('%.17g', value)..';'
	elseif kind == 'boolean' then
		out[#out + 1] = value and 'Y' or 'F'
	end
end

local function Parse(text)
	local position, length = 1, #text
	local function Fail(why) error(why, 0) end
	local Value
	function Value(depth)
		if depth > 41 then Fail('nested too deep') end
		local tag = strsub(text, position, position)
		position = position + 1
		if tag == 'T' then
			local out = {}
			while true do
				if position > length then Fail('cut short') end
				if strsub(text, position, position) == 'E' then
					position = position + 1
					return out
				end
				local key = Value(depth + 1)
				local item = Value(depth + 1)
				if key == nil or type(key) == 'table' or key ~= key then Fail('bad key') end
				out[key] = item
			end
		elseif tag == 'S' then
			local colon = strfind(text, ':', position, true)
			if not colon then Fail('bad text') end
			local size = tonumber(strsub(text, position, colon - 1))
			if not size or size < 0 then Fail('bad text') end
			local value = strsub(text, colon + 1, colon + size)
			if #value ~= size then Fail('cut short') end
			position = colon + size + 1
			return value
		elseif tag == 'N' then
			local stop = strfind(text, ';', position, true)
			if not stop then Fail('bad number') end
			local value = tonumber(strsub(text, position, stop - 1))
			if not value then Fail('bad number') end
			position = stop + 1
			return value
		elseif tag == 'Y' then return true
		elseif tag == 'F' then return false
		end
		Fail('unknown mark')
	end
	local ok, result = pcall(Value, 0)
	if not ok then return nil, result end
	if position <= length then return nil, 'extra text at the end' end
	return result
end

local ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local DECODE = {}
for index = 1, 64 do DECODE[strbyte(ALPHABET, index)] = index - 1 end
local function Char64(index) return strsub(ALPHABET, index + 1, index + 1) end

local function Encode64(data)
	local out = {}
	for index = 1, #data, 3 do
		local a, b, c = strbyte(data, index, index + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		out[#out + 1] = Char64(floor(n / 262144) % 64)..Char64(floor(n / 4096) % 64)
			..(b and Char64(floor(n / 64) % 64) or '=')..(c and Char64(n % 64) or '=')
	end
	return table.concat(out)
end

local PAD = strbyte('=')
local function Decode64(text)
	text = gsub(text, '[^%w%+/=]', '')
	if #text == 0 or #text % 4 ~= 0 then return nil end
	local out = {}
	for index = 1, #text, 4 do
		local w, x, y, z = strbyte(text, index, index + 3)
		local a, b = DECODE[w], DECODE[x]
		local c = y ~= PAD and DECODE[y] or nil
		local d = z ~= PAD and DECODE[z] or nil
		if not a or not b or (y ~= PAD and not c) or (z ~= PAD and not d) or (not c and d) then return nil end
		local n = a * 262144 + b * 4096 + (c or 0) * 64 + (d or 0)
		out[#out + 1] = strchar(floor(n / 65536) % 256)
		if c then out[#out + 1] = strchar(floor(n / 256) % 256) end
		if d then out[#out + 1] = strchar(n % 256) end
	end
	return table.concat(out)
end

local function Checksum(data)
	local a, b = 1, 0
	for index = 1, #data do
		a = (a + strbyte(data, index)) % 65521
		b = (b + a) % 65521
	end
	-- Two halves, so the number never exceeds a 32-bit C long.
	return format('%04x%04x', b, a)
end

function UI:EncodeProfile(data, profile)
	local out = {}
	Serialize({v = FORMAT_VERSION, n = profile, d = StripPrivate(Copy(data))}, out, -1)
	local payload = table.concat(out)
	return format('SPEC01:%d:%s:%s', FORMAT_VERSION, Checksum(payload), Encode64(payload))
end

-- Returns data, name; or nil and the reason.
function UI:DecodeProfile(text)
	local version, sum, body = strmatch(text or '', '^%s*SPEC01:(%d+):(%x+):(.-)%s*$')
	if not version then return nil, 'That is not a SPEC-01 profile string.' end
	if tonumber(version) ~= FORMAT_VERSION then return nil, 'That string was made by a newer version of this addon.' end
	local payload = Decode64(body)
	if not payload then return nil, 'The string is damaged: some of it is missing or changed.' end
	if Checksum(payload) ~= strlower(sum) then return nil, 'The string is damaged: its check does not match.' end
	local value, problem = Parse(payload)
	if type(value) ~= 'table' or type(value.d) ~= 'table' then return nil, 'The string could not be read ('..tostring(problem or 'no settings')..').' end
	local data = Conform(StripPrivate(value.d), UI.defaults)
	if UI.Migrate then UI:Migrate(data) end
	return data, type(value.n) == 'string' and value.n or nil
end

-- The text sheet: a device with a black display holding the string --------------------------
local sheet
local function Sheet()
	if sheet then return sheet end
	sheet = Kit:Device(UIParent, {model = 'PR-1', title = 'Profile string', width = 480, height = 320, name = 'JiberishSpec01ProfileSheet'})
	sheet:SetFrameStrata('FULLSCREEN_DIALOG')
	sheet:SetFrameLevel(300)
	Kit:Relevel(sheet)
	sheet:SetPoint('CENTER', 0, 40)
	sheet:EnableMouse(true)
	sheet:SetMovable(true)
	sheet:SetClampedToScreen(true)
	sheet:RegisterForDrag('LeftButton')
	sheet:SetScript('OnDragStart', sheet.StartMoving)
	sheet:SetScript('OnDragStop', sheet.StopMovingOrSizing)
	tinsert(UISpecialFrames, 'JiberishSpec01ProfileSheet')
	Kit:SetLed(sheet.lamp, true)
	sheet.hint = Kit:Text(sheet, '', 9, 'dim')
	sheet.hint:SetPoint('TOPLEFT', 14, -28)
	sheet.hint:SetPoint('TOPRIGHT', -14, -28)
	sheet.hint:SetJustifyH('LEFT')
	local screen = Kit:Screen(sheet, {inset = 3, radius = 6})
	screen:SetPoint('TOPLEFT', 12, -54)
	screen:SetPoint('BOTTOMRIGHT', -12, 54)
	local scroll = CreateFrame('ScrollFrame', nil, screen.screen)
	scroll:SetPoint('TOPLEFT', 8, -8)
	scroll:SetPoint('BOTTOMRIGHT', -8, 8)
	local edit = CreateFrame('EditBox', nil, scroll)
	edit:SetMultiLine(true)
	edit:SetAutoFocus(false)
	edit:SetMaxLetters(0)
	Kit:Font(edit, 10)
	Kit:Tint(edit, 'darkInk')
	edit:SetWidth(400)
	scroll:SetScrollChild(edit)
	scroll:SetScript('OnSizeChanged', function(self, width) edit:SetWidth(max(width, 10)) end)
	scroll:EnableMouseWheel(true)
	scroll:SetScript('OnMouseWheel', function(self, delta)
		self:SetVerticalScroll(Kit:Clamp(self:GetVerticalScroll() - delta * 30, 0, self:GetVerticalScrollRange()))
	end)
	edit:SetScript('OnCursorChanged', function(_, _, y, _, height)
		local top, view = scroll:GetVerticalScroll(), scroll:GetHeight()
		y = -y
		if y < top then scroll:SetVerticalScroll(y)
		elseif y + height > top + view then scroll:SetVerticalScroll(y + height - view) end
	end)
	edit:SetScript('OnEscapePressed', function() Kit:Close(sheet) end)
	-- An export can be selected and copied but not changed.
	edit:SetScript('OnTextChanged', function(self, user)
		if sheet.readOnly and user then
			self:SetText(sheet.value or '')
			self:HighlightText()
		end
	end)
	edit:SetScript('OnEditFocusGained', function(self) if sheet.readOnly then self:HighlightText() end end)
	edit:SetScript('OnChar', function(_, character)
		if not sheet.readOnly then Kit:Play(character == ' ' and 'type-space' or 'type') end
	end)
	screen.screen:EnableMouse(true)
	screen.screen:SetScript('OnMouseDown', function() edit:SetFocus() end)
	sheet.edit = edit
	sheet.primary = Kit:Key(sheet, {width = 96, height = 28, tone = 'primary', text = 'Import'})
	sheet.primary:SetPoint('BOTTOMRIGHT', -14, 14)
	sheet.closeKey = Kit:Key(sheet, {width = 84, height = 28, text = 'Close'})
	sheet.closeKey:SetPoint('RIGHT', sheet.primary, 'LEFT', -8, 0)
	sheet.closeKey.onClick = function() Kit:Close(sheet) end
	sheet.status = Kit:Text(sheet, '', 9, 'dim')
	sheet.status:SetPoint('BOTTOMLEFT', 16, 24)
	sheet.status:SetPoint('RIGHT', sheet.closeKey, 'LEFT', -10, 0)
	sheet.status:SetJustifyH('LEFT')
	sheet:Hide()
	return sheet
end

local function Status(text, token)
	sheet.status:SetText(text or '')
	Kit:Tint(sheet.status, token or 'dim')
end

local function UniqueName(profile)
	profile = Clean(profile) or 'Imported'
	if not Exists(profile) then return profile end
	for index = 2, 99 do
		local candidate = profile..' '..index
		if not Exists(candidate) then return candidate end
	end
	return profile..' '..floor(GetTime())
end

function UI:ShowExport()
	local frame = Sheet()
	frame.readOnly = true
	frame.value = UI:EncodeProfile(Copy(UI.db), UI:ActiveProfile())
	frame.title:SetText(strupper('Export  /  '..UI:ActiveProfile()))
	frame.hint:SetText('Every setting in this profile as one line of text. Copy it with Ctrl+C and paste it into the Import sheet on any character.')
	frame.edit:SetText(frame.value)
	frame.primary:Hide()
	Status(format('%d characters', #frame.value))
	Kit:Open(frame)
	frame.edit:SetFocus()
	frame.edit:HighlightText()
end

function UI:ShowImport()
	local frame = Sheet()
	frame.readOnly = false
	frame.value = nil
	frame.title:SetText('IMPORT')
	frame.hint:SetText('Paste a SPEC-01 profile string. It is saved as a new profile; nothing changes until you choose to use it.')
	frame.edit:SetText('')
	frame.primary:Show()
	frame.primary:SetKeyText('Import')
	Status('')
	frame.primary.onClick = function()
		local data, profile = UI:DecodeProfile(frame.edit:GetText())
		if not data then
			Status(profile, 'red')
			Kit:Play('error')
			return
		end
		local name = UniqueName(profile)
		Live().profiles[name] = data
		Kit:Play('success')
		Kit:Close(frame)
		Kit:AlertDialog({title = 'Profile imported', text = format('Saved as "%s". Use it on this character now?', name),
			confirm = 'Use it', onConfirm = function() UI:SwitchProfile(name) end})
		Kit:Apply()
	end
	Kit:Open(frame)
	frame.edit:SetFocus()
end

-- Hub page -----------------------------------------------------------------------------
local function OtherProfiles()
	local items, live = {}, UI:ActiveProfile()
	for _, profile in ipairs(UI:ProfileNames()) do
		if profile ~= live then items[#items + 1] = {profile, profile} end
	end
	return items
end

local function AllProfiles()
	local items = {}
	for _, profile in ipairs(UI:ProfileNames()) do items[#items + 1] = {profile, profile} end
	return items
end

UI:RegisterPage('profiles', {title = 'Profiles', order = 4, since = '0.5.0', cards = {
	{title = 'Profile', rows = {
		{'note', 'A profile holds every setting in this addon. Characters can share one or each have their own; switching loads it after a reload.'},
		{'dropdown', 'This character uses', nil, items = AllProfiles, get = function() return UI:WantedProfile() end,
			set = function(profile) UI:SwitchProfile(profile) end, note = 'The profile this character loads. A new choice takes effect after a reload.'},
		{'input', 'Rename', nil, get = function() return UI:ActiveProfile() end, set = function(profile) UI:RenameProfile(profile) end,
			'A new name for the profile in use.'},
		{'button', 'Reset', 'Reset', function() UI:ResetProfile() end, 'Every setting in this profile back to its default.'},
	}},
	{title = 'More profiles', rows = {
		{'input', 'New profile', nil, get = function() return '' end, set = function(profile) UI:NewProfile(profile, true) end,
			'Type a name and press Enter. It starts with the defaults.'},
		{'dropdown', 'Copy from', nil, items = OtherProfiles, get = function() return nil end,
			set = function(profile) UI:CopyProfile(profile) end, note = 'Overwrite this profile with another one\'s settings.'},
		{'dropdown', 'Delete', nil, items = OtherProfiles, get = function() return nil end,
			set = function(profile) UI:DeleteProfile(profile) end, note = 'The profile in use cannot be deleted.'},
	}},
	{title = 'Share', rows = {
		{'button', 'Export', 'Export', function() UI:ShowExport() end, 'This profile as a line of text to copy.'},
		{'button', 'Import', 'Import', function() UI:ShowImport() end, 'Paste a profile string to save it as a new profile.'},
	}},
}})
