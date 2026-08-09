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

local UserInputService = game:GetService("UserInputService")

local Instruments = script.Parent.Parent:WaitForChild("UI"):WaitForChild("Instruments")

--[[
	The bindings table, for the HUD toggle key. Required here for the same
	reason FlightController requires it for Backspace: the key must be
	rebindable and must be covered by the "no two actions share a key" test,
	but it cannot be consumed by update() - see below.
]]
local InputController = require(script.Parent.Parent:WaitForChild("Controls"):WaitForChild("InputController"))

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
-- Display errors for the gauges (§32). Pure, and tested alongside the widgets
-- it feeds rather than in a suite of its own, because it has no lifecycle.
local InstrumentError = require(Instruments:WaitForChild("InstrumentError"))

--[[
	The controls reference (Phase 4c). It lives here rather than in a controller
	of its own for the same reason the instruments do - the bootstrap only scans
	`Controllers/` - and it belongs with the HUD specifically, because it is the
	same KIND of thing: a read-only overlay that absorbs no input and is
	therefore safe to show while the cursor is the yoke.
]]
local BindsPanel = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("Binds"):WaitForChild("BindsPanel"))

local UIController = {}

local initialised = false
local connections: { RBXScriptConnection } = {}

--[[
	Pure, and exported so runTests() can drive the key without a keyboard - the
	same shape as FlightController.shouldReset().

	`blocked` is true when the press belongs to something else: Roblox's own UI
	consumed it, or a text box has focus. That matters more for this key than
	for most, because H is a LETTER. Without the guard, typing "how's the
	weather" in chat would strobe the panel on and off six times.
]]
function UIController.shouldToggleHud(keyCode: Enum.KeyCode, blocked: boolean, boundKey: Enum.KeyCode): boolean
	if blocked then
		return false
	end
	return keyCode == boundKey
end

--[[
	Which key currently toggles the HUD.

	The defaults, not a live aircraft's binding table: unlike the flight
	controls this key has to work with no aircraft at all, so there may be no
	per-player bindings to read. Rebinding through InputController.rebind() on
	the defaults is still honoured.
]]
local function hudKey(): Enum.KeyCode
	return InputController.DEFAULT_BINDINGS.ToggleHud
end

local function isTyping(): boolean
	return UserInputService:GetFocusedTextBox() ~= nil
end

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	local blocked = gameProcessed or isTyping()

	if UIController.shouldToggleHud(input.KeyCode, blocked, hudKey()) then
		DebugHud.toggle()
	end

	--[[
		The controls list, on the same guard. K is a letter, so without the
		blocked check, typing "checklist" in chat would flash the panel twice.
	]]
	if UIController.shouldToggleHud(input.KeyCode, blocked, InputController.DEFAULT_BINDINGS.ToggleBinds) then
		BindsPanel.toggle()
	end
end

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

	--[[
		Built hidden. Forty-one bindings is a large panel and the pilot asks for
		it rather than being shown it - and a ScreenGui that is not enabled
		absorbs nothing at all, which is how the cursor-is-the-yoke rule is
		satisfied by construction rather than by remembering.
	]]
	BindsPanel.Init()

	--[[
		H toggles the HUD, on a LIFETIME connection rather than a per-aircraft
		one, and deliberately not through InputController.update().

		Same rule as ResetAircraft (see the handoff, section 6j): update() only
		runs inside the frame loop, and the frame loop only runs while the pilot
		is sitting in a working aircraft. The pilot must be able to set this from
		the apron so the HUD is already in the state they want when they board -
		and after a crash, when there may be no aircraft at all.
	]]
	table.insert(connections, UserInputService.InputBegan:Connect(onInputBegan))
end

function UIController.Shutdown()
	for _, c in connections do
		c:Disconnect()
	end
	table.clear(connections)

	SixPack.Shutdown()
	DebugHud.Shutdown()
	BindsPanel.Shutdown()
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

	for _, suite in { DebugHud, Instrument, InstrumentError, SixPack, BindsPanel } do
		local ok, results = suite.runTests()
		allOk = allOk and ok
		for _, r in results do
			table.insert(combined, r)
		end
	end

	-- This controller's own behaviour: the HUD toggle key.
	local ownOk, ownResults = UIController.runOwnTests()
	allOk = allOk and ownOk
	for _, r in ownResults do
		table.insert(combined, r)
	end

	return allOk, combined
end

--[[
	The HUD toggle. Separate from the delegating runTests() above so that this
	controller's own logic is not buried among two hundred instrument checks.
]]
function UIController.runOwnTests(): (boolean, { any })
	local results = {}
	local allPassed = true

	local function record(label: string, passed: boolean, detail: string)
		if not passed then
			allPassed = false
		end
		table.insert(results, { label = label, passed = passed, detail = detail })
		print(string.format("  [%s] %-54s %s", passed and "PASS" or "FAIL", label, detail))
	end

	print("=== UIController: verification ===")

	local H = InputController.DEFAULT_BINDINGS.ToggleHud

	record("The HUD toggle is bound to H", H == Enum.KeyCode.H, tostring(H))
	record(
		"The bound key toggles",
		UIController.shouldToggleHud(H, false, H),
		"accepted"
	)
	record(
		"Any other key does not",
		not UIController.shouldToggleHud(Enum.KeyCode.J, false, H),
		"J ignored"
	)

	--[[
		THE one that matters for this particular key. H is a letter, so without
		the blocked guard, typing "how high" in chat would strobe the panel.
	]]
	record(
		"H is ignored while the press belongs to a text box",
		not UIController.shouldToggleHud(H, true, H),
		"blocked press ignored"
	)
	record(
		"A rebound key is honoured, and the old one released",
		UIController.shouldToggleHud(Enum.KeyCode.J, false, Enum.KeyCode.J)
			and not UIController.shouldToggleHud(H, false, Enum.KeyCode.J),
		"J accepted, H ignored"
	)

	--[[
		The state machine. The panel must be hidable and re-showable, which is
		what the old design could not do: with the constant false it built no
		panel at all, so a key could only ever have worked in one direction.
	]]
	local before = DebugHud.isVisible()

	DebugHud.setVisible(true)
	record("The HUD can be shown", DebugHud.isVisible() == true, "visible")
	local afterToggle = DebugHud.toggle()
	record(
		"...and toggling hides it again",
		afterToggle == false and DebugHud.isVisible() == false,
		"hidden"
	)
	record(
		"toggle() returns the state it produced",
		DebugHud.toggle() == true and DebugHud.isVisible() == true,
		"returned true and is visible"
	)

	DebugHud.setVisible(before)
	record(
		"The suite leaves the HUD as it found it",
		DebugHud.isVisible() == before,
		string.format("restored to %s", tostring(before))
	)

	--[[
		The binding is declared but must stay INERT in update(), the same
		arrangement ResetAircraft uses and for the same reason. Holding H must
		move no control and flip no system flag, or it would quietly acquire a
		second meaning the first time somebody added a handler for it.
	]]
	local Cessna172 = require(game:GetService("ReplicatedStorage").FlightSim.Aircraft.Definitions.Cessna172)
	local ic = InputController.new(Cessna172)
	local snapshot = {
		held = { ToggleHud = true },
		pointer = Vector2.new(960, 540),
		viewportSize = Vector2.new(1920, 1080),
	}
	for _ = 1, 60 do
		InputController.update(ic, 1 / 60, snapshot)
	end
	record(
		"Holding H moves no control",
		math.abs(ic.controls.pitch) < 1e-9 and math.abs(ic.controls.roll) < 1e-9
			and ic.controls.throttle == 0 and ic.controls.brake == 0,
		"pitch, roll, throttle and brake all still neutral"
	)

	local passCount = 0
	for _, r in results do
		if r.passed then
			passCount += 1
		end
	end
	print(string.format("=== %s (%d/%d) ===", allPassed and "ALL PASSED" or "FAILURES PRESENT", passCount, #results))

	return allPassed, results
end

return UIController
