-- Runs ConsoleEditor.lua's geometry offline: editor moves (accepted or refused),
-- magnet snapping, then the console's own Resolve over the saved arrangement.
local configPath, editorPath = ...
dofile(configPath)
local function Any()
	return setmetatable({}, {__index = function(self) return function() return self end end})
end
function CreateFrame() return Any() end
UIParent = Any()
function InCombatLockdown() return false end
C_Timer = {After = function() end}
GameTooltip = Any()
local UI = {Kit = Any(), db = {actionbars = {consoleLayout = {}, consoleGrid = 2}}}
UI.Pixel = {Px = function() return CONFIG.px end}
function UI:OnMoversChanged() end
assert(loadfile(editorPath))('JiberishSpec01UI', UI)
local G = UI.ConsoleGrid

for _, scenario in ipairs(CONFIG.scenarios) do
	print('SCENARIO', scenario.name)
	local blocks = scenario.blocks
	local byKey = {}
	for _, b in ipairs(blocks) do byKey[b.key] = b end
	local limits = scenario.limits
	local rank = 0
	for _, op in ipairs(scenario.ops) do
		rank = rank + 1
		local b = byKey[op[2]]
		if op[1] == 'move' then
			local x, y = G.Snap(op[3], scenario.step), G.Snap(op[4], scenario.step)
			if op[5] then
				local gx, gy
				x, y, gx, gy = G.Magnet(b, x, y, blocks, 6 * CONFIG.px, scenario.centre)
				x, y = G.Snap(x, CONFIG.px), G.Snap(y, CONFIG.px)
				print(string.format('MAGNET %s %.4f %.4f %s %s', b.key, x, y, tostring(gx), tostring(gy)))
			end
			local ok = G.Free({key = b.key, x = x, y = y, w = b.w, h = b.h}, blocks, limits)
			print(string.format('MOVE %s %s', b.key, ok and 'accepted' or 'refused'))
			if ok then b.x, b.y, b.tucked, b.rank = x, y, nil, rank end
		elseif op[1] == 'size' then
			b.w, b.h, b.rank = op[3], op[4], rank
		end
	end
	local body = {}
	for _, b in ipairs(blocks) do b.saved = true if not b.tucked then body[#body + 1] = b end end
	G.Resolve(body, scenario.bounds, 2 * CONFIG.px, CONFIG.px)
	for _, b in ipairs(body) do print(string.format('RECT %s %.6f %.6f %.6f %.6f', b.key, b.x, b.y, b.w, b.h)) end
end
