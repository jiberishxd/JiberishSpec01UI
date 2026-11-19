-- The hub's bookkeeping, in plain Lua with no game calls (so tests/lua/hub_history.lua
-- runs it offline): the Undo history, the list of changes waiting on a reload,
-- the settings a page's Reset puts back, and NEW marks per version.
--
-- Hub.lua does the writing and the painting; this file only remembers.
local _, UI = ...

local History = {}
UI.HubHistory = History

local function Copy(value)
	if type(value) ~= 'table' then return value end
	local copy = {}
	for key, item in pairs(value) do copy[key] = Copy(item) end
	return copy
end

local function Same(a, b)
	if type(a) ~= 'table' or type(b) ~= 'table' then return a == b end
	for key, item in pairs(a) do if not Same(item, b[key]) then return false end end
	for key in pairs(b) do if a[key] == nil then return false end end
	return true
end
History.Copy, History.Same = Copy, Same

-- Settings paths -------------------------------------------------------------------
local function Split(path)
	local keys = {}
	for key in tostring(path):gmatch('[^.]+') do keys[#keys + 1] = key end
	return keys
end

function History.Read(root, path)
	local node = root
	for _, key in ipairs(Split(path)) do
		if type(node) ~= 'table' then return nil end
		node = node[key]
	end
	return node
end

-- Writes only where the parent table exists (a module that isn't loaded is skipped).
function History.Write(root, path, value)
	local keys = Split(path)
	local node = root
	for index = 1, #keys - 1 do
		node = type(node) == 'table' and node[keys[index]] or nil
	end
	if type(node) ~= 'table' or #keys == 0 then return false end
	node[keys[#keys]] = Copy(value)
	return true
end

-- Settings that belong to this computer or this window, not to a page: a page's
-- Reset never touches them (the same list Profiles keeps out of exports, plus
-- the hub's own state and frame positions). Any '__' key is account-wide.
local PRIVATE = {'uiScale', 'setup', 'chat.log', 'sound.muted', 'sound.errorSpeechWas', 'layout.lastHeight', 'hub', 'movers'}
function History.IsPrivate(path)
	if type(path) ~= 'string' or path == '' then return true end
	for _, key in ipairs(Split(path)) do
		if key:sub(1, 2) == '__' then return true end
	end
	for _, private in ipairs(PRIVATE) do
		if path == private or path:sub(1, #private + 1) == private..'.' then return true end
	end
	return false
end

-- Undo -------------------------------------------------------------------------------
-- An entry is one change {key, path, label, old, new, set, row} or a batch
-- {label, changes = {change, ...}} (a page reset). A run of changes to the same
-- setting close together (a slider drag, a knob turned) is one entry; one that
-- ends where it started leaves no entry at all.
local LIMIT, MERGE = 40, 1.5
local undo = {}
History.LIMIT, History.MERGE = LIMIT, MERGE

function History.Push(entry, now)
	local top = undo[#undo]
	if top and not top.changes and not entry.changes and entry.key ~= nil and top.key == entry.key
		and now and top.at and now - top.at <= MERGE then
		top.new, top.at = Copy(entry.new), now
		if Same(top.old, top.new) then undo[#undo] = nil return nil end
		return top
	end
	if not entry.changes and Same(entry.old, entry.new) then return nil end
	entry.old, entry.new, entry.at = Copy(entry.old), Copy(entry.new), now
	undo[#undo + 1] = entry
	while #undo > LIMIT do table.remove(undo, 1) end
	return entry
end

function History.Pop()
	local entry = undo[#undo]
	undo[#undo] = nil
	return entry
end

function History.Peek() return undo[#undo] end
function History.Count() return #undo end
function History.Clear() for index = #undo, 1, -1 do undo[index] = nil end end

-- The changes an entry holds, newest first (the order to put them back in).
function History.Changes(entry)
	if not entry then return {} end
	if not entry.changes then return {entry} end
	local list = {}
	for index = #entry.changes, 1, -1 do list[#list + 1] = entry.changes[index] end
	return list
end

-- Reload -----------------------------------------------------------------------------
-- What waits on a reload, in the order it was changed. A setting is tracked by
-- its path and the value it had before its first change: changing it back
-- (by hand or with Undo) takes it off the list. Anything flagged without a
-- path (a module asking for a reload) stays until the reload.
local reload, reloadOrder = {}, {}

local function Unlist(key)
	reload[key] = nil
	for index, other in ipairs(reloadOrder) do
		if other == key then table.remove(reloadOrder, index) break end
	end
end

-- path: the setting (nil for an untracked reason); from: its value before the change.
function History.FlagReload(path, label, from)
	local key = path or ('?'..tostring(label))
	if not reload[key] then
		reload[key] = {label = label or path or 'A change', tracked = path ~= nil, from = Copy(from)}
		reloadOrder[#reloadOrder + 1] = key
	end
	return reload[key]
end

-- The setting now holds `value`: if that is where it started, no reload is owed for it.
function History.SettleReload(path, value)
	local item = path and reload[path]
	if item and item.tracked and Same(item.from, value) then Unlist(path) return true end
	return false
end

function History.ReloadCount() return #reloadOrder end

function History.ReloadLabels()
	local labels, seen = {}, {}
	for _, key in ipairs(reloadOrder) do
		local label = reload[key].label
		if not seen[label] then seen[label] = true; labels[#labels + 1] = label end
	end
	return labels
end

function History.ClearReload()
	for key in pairs(reload) do reload[key] = nil end
	for index = #reloadOrder, 1, -1 do reloadOrder[index] = nil end
end

-- Page reset -------------------------------------------------------------------------
local SETTING = {switch = true, segmented = true, slider = true, color = true, dropdown = true, input = true}
History.SETTING = SETTING

-- Every setting row a page's cards hold that is not at its registered default,
-- as {path, label, old, new, row}, each path once. Private paths and paths with
-- no default are left alone.
function History.ResetPlan(page, defaults, db)
	local plan, seen = {}, {}
	for _, card in ipairs(type(page) == 'table' and page.cards or {}) do
		for _, row in ipairs(card.rows or {}) do
			local path = row[3]
			if SETTING[row[1]] and type(path) == 'string' and not seen[path] and not History.IsPrivate(path) then
				seen[path] = true
				local default = History.Read(defaults, path)
				local current = History.Read(db, path)
				if default ~= nil and not Same(current, default) then
					plan[#plan + 1] = {key = path, path = path, label = row[2], old = Copy(current), new = Copy(default), row = row}
				end
			end
		end
	end
	return plan
end

-- NEW marks -----------------------------------------------------------------------------
-- A page counts as seen for the version it was last opened in, so each release's
-- NEW lamps light again on the pages it changed.
function History.Seen(seen, key, version)
	return type(seen) == 'table' and version ~= nil and seen[key] == version
end

function History.MarkSeen(seen, key, version)
	if type(seen) ~= 'table' or version == nil then return false end
	local fresh = seen[key] ~= version
	seen[key] = version
	return fresh
end
