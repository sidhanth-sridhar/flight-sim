--!strict
--[[
	UIController
	------------
	Starts and stops everything on screen. At the moment that is one thing: the
	raw-numbers debug HUD.

	WHY THIS EXISTS AS A SEPARATE FILE
	----------------------------------
	The bootstrap only scans `Controllers/`. A module dropped into
	`UI/Instruments/` is never found by CONTROLLER_ORDER no matter what it is
	called - the same trap already documented for `Controls/InputController`,
	which the bootstrap silently skips.

	So the widget lives where widgets belong, in `UI/Instruments/`, and this
	controller - a name CONTROLLER_ORDER has listed since Phase 0 - owns its
	lifecycle. It mirrors exactly how FlightController drives InputController.

	Extending the bootstrap to scan more folders was the alternative and was not
	taken: "controller" would stop meaning anything, and the loader's explicit
	ordering is the thing that makes startup dependencies visible.
]]

local DebugHud = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("Instruments"):WaitForChild("DebugHud"))

local UIController = {}

local initialised = false

function UIController.Init()
	if initialised then
		return
	end
	initialised = true

	-- DebugHud decides for itself whether to appear; it is gated on
	-- Constants.DEBUG.SHOW_PHYSICS_OVERLAY rather than on anything here.
	DebugHud.Init()
end

function UIController.Shutdown()
	DebugHud.Shutdown()
	initialised = false
end

-- Delegated so the whole UI surface can be verified from one entry point as
-- more instruments arrive.
function UIController.runTests(): (boolean, { any })
	return DebugHud.runTests()
end

return UIController
