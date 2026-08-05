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

local Instruments = script.Parent.Parent:WaitForChild("UI"):WaitForChild("Instruments")

local DebugHud = require(Instruments:WaitForChild("DebugHud"))

--[[
	The gauge framework. Required here only so its suite is reachable from
	UIController.runTests() - it has no Init() and starts nothing on its own,
	exactly as InputController is a library FlightController drives rather than
	a controller the bootstrap starts.
]]
local Instrument = require(Instruments:WaitForChild("Instrument"))

-- The panel itself. Unlike the framework this one has a lifecycle, and this
-- controller owns it for the reason the header gives.
local SixPack = require(Instruments:WaitForChild("SixPack"))

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

	--[[
		The six-pack is NOT gated on the debug flag. It is the instrument panel
		the aircraft is meant to be flown on, so it appears whenever the pilot is
		flying; the debug HUD is a diagnostic that happens to share the screen.
	]]
	SixPack.Init()
end

function UIController.Shutdown()
	SixPack.Shutdown()
	DebugHud.Shutdown()
	initialised = false
end

--[[
	Delegated so the whole UI surface can be verified from one entry point as
	more instruments arrive.

	Both suites always run - the second is NOT skipped when the first fails, or
	a broken HUD would hide every instrument result behind it and each fix would
	surface exactly one more problem.
]]
function UIController.runTests(): (boolean, { any })
	local combined = {}
	local allOk = true

	for _, suite in { DebugHud, Instrument, SixPack } do
		local ok, results = suite.runTests()
		allOk = allOk and ok
		for _, r in results do
			table.insert(combined, r)
		end
	end

	return allOk, combined
end

return UIController
