-- Physical pixels and the UI scale.
--
-- Borders, corners, shadows and insets are measured in real screen pixels, so
-- they stay crisp and even at any UI scale. The UI scale itself is saved and
-- put back whenever the client changes it, so frames never drift; the first
-- value saved is whatever the game already had, so nothing jumps on install.
local _, UI = ...
local Kit = UI.Kit

local floor, max, min = math.floor, math.max, math.min
local Pixel = {}
UI.Pixel = Pixel

-- UI units per physical pixel at a UI scale of 1.
function Pixel.Perfect()
	local _, height = GetPhysicalScreenSize()
	if not height or height <= 0 then height = 1080 end
	return 768 / height
end

-- n physical pixels in a frame's own units.
function Pixel.Px(frame, n)
	local scale = frame and frame.GetEffectiveScale and frame:GetEffectiveScale() or UIParent:GetEffectiveScale()
	return (n or 1) * Pixel.Perfect() / max(scale, 0.01)
end

-- A value in a frame's units, rounded to whole physical pixels. The tiny
-- epsilon keeps values on an exact boundary from flipping between reloads.
function Pixel.Snap(frame, value)
	local px = Pixel.Px(frame, 1)
	return floor(value / px + 0.5 + 0.001) * px
end

local listeners = {}
function Pixel.OnChange(callback) listeners[#listeners + 1] = callback end

local function Changed()
	for _, callback in ipairs(listeners) do UI:Safe(callback) end
end

function Pixel.Clamp(scale) return max(0.4, min(1.15, scale)) end

-- Put our scale back if the client (or a resolution change) moved it.
-- force: apply even when "Keep UI scale" is off (the player just chose a scale).
local function Apply(force)
	local db = UI.db
	if not db.uiScale or not (db.uiScaleLocked or force) then return Changed() end
	local wanted = Pixel.Clamp(db.uiScale)
	if math.abs(UIParent:GetScale() - wanted) > 0.0005 then
		UI:AfterCombat(function() UIParent:SetScale(wanted); Changed() end, 'uiScale')
	else
		Changed()
	end
end

-- Rescaling the whole interface is heavy, so a slider drag applies once it settles.
local pending
function Pixel.SetScale(scale)
	UI.db.uiScale = Pixel.Clamp(scale)
	if pending then pending:Cancel() end
	pending = C_Timer.NewTimer(0.4, function() pending = nil; Apply(true) end)
end

-- The scale at which one UI unit is exactly one physical pixel.
function Pixel.PerfectScale()
	return Pixel.Clamp(Pixel.Perfect())
end

-- Every shell is measured in physical pixels, so refit them all on any change.
Pixel.OnChange(function() Kit:RefitShells() end)

local driver = CreateFrame('Frame')
driver:RegisterEvent('PLAYER_LOGIN')
driver:RegisterEvent('UI_SCALE_CHANGED')
driver:RegisterEvent('DISPLAY_SIZE_CHANGED')
driver:SetScript('OnEvent', function(_, event)
	if event == 'PLAYER_LOGIN' and not UI.db.uiScale then
		UI.db.uiScale = UIParent:GetScale()
	end
	-- One frame later, after the client has finished its own scale pass.
	C_Timer.After(0, Apply)
end)
