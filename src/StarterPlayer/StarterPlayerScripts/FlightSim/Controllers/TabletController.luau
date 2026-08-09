--!strict
--[[
	TabletController
	----------------
	Owns the flight tablet (Phase 4b): the key that opens it, the gate that says
	whether it may open, the network round trip that fills it, and the flight it
	starts.

	WHY THIS EXISTS AS A SEPARATE FILE
	----------------------------------
	The bootstrap only scans `Controllers/`. A module dropped into `UI/Tablet/`
	is never found by CONTROLLER_ORDER no matter what it is called, and it fails
	SILENTLY - the same trap already documented for `Controls/InputController`
	and already solved once, for the instruments, by UIController. So the widget
	lives where widgets belong and this controller owns its lifecycle.

	THE GATE, WHICH IS THE WHOLE REASON THIS FEATURE NEEDED A DECISION
	------------------------------------------------------------------
	The cursor is the yoke (§6g). Every other piece of UI in this project is
	inert because of it - §7 states flatly that an on-screen button cannot be a
	flight control here, since reaching a corner of the screen commands near-full
	deflection on both axes on the way. Switches dodged the rule by being keys.
	A picker cannot: no key chooses among airports.

	⚠️ PILOT'S DECISION, 2026-08-09: the tablet works ON THE GROUND, or with
	ALTITUDE HOLD ENGAGED. The rule itself lives in
	InputController.tabletMayOpen, with the reasoning; the short version is that
	§28 already made the mode on R ignore the cursor completely, so in that state
	the pilot's hands are off the controls by construction and a clickable panel
	costs them nothing.

	AND IT IS RE-CHECKED EVERY FRAME, NOT ONLY ON OPEN
	--------------------------------------------------
	That is not belt-and-braces, it closes a real hole. Open the tablet during
	the take-off roll - legal, the wheels are down - and then do nothing: the
	throttle is a lever and holds its setting with the keys neutral, so the
	aeroplane accelerates, rotates on trim, and is airborne and hand-flying with
	a clickable panel on screen and the yoke released. So the gate is a
	condition, not an event: the moment it stops being true the tablet closes
	itself and says why.

	WHAT IT TALKS TO
	----------------
	  RequestAirportList -> AirportService's registry snapshot, including the
	                        flight plans. Fetched once, on open.
	  StartFlight        -> AircraftService validates the selection and spawns
	                        the aeroplane at the DEPARTURE field.
	Aircraft come from Aircraft/Registry.luau directly - it is in
	ReplicatedStorage, so the aircraft picker costs no network at all.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local FlightSim = ReplicatedStorage:WaitForChild("FlightSim")

local Remotes = require(FlightSim.Net.Remotes)

local Tablet = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("Tablet"):WaitForChild("Tablet"))

--[[
	Required for the binding table and for the gate, which is a pure function
	living with the rest of the control-scheme rules rather than here. Same
	arrangement UIController has with ToggleHud.
]]
local InputController = require(script.Parent.Parent:WaitForChild("Controls"):WaitForChild("InputController"))

--[[
	The direction of this dependency matters: this module asks FlightController
	for the aircraft's state and PUSHES the tablet's state back through
	setTabletOpen(). FlightController knows nothing about this file, which is
	what keeps the two from becoming a require cycle - see the note on
	`tabletOpen` there.
]]
local FlightController = require(script.Parent:WaitForChild("FlightController"))

local TabletController = {}

local player = Players.LocalPlayer

-- =========================================================================
-- STATE
-- =========================================================================

local screenGui: ScreenGui? = nil
local handle: any = nil
local connections: { RBXScriptConnection } = {}
local initialised = false

local open = false
local snapshot: any = nil
local fetching = false
local selection: Tablet.Selection = { from = nil, to = nil, aircraftId = "c172" }

--[[
	The refusal toast: one inert TextLabel that says why the tablet would not
	open, or why it just closed itself.

	A TextLabel and nothing else, which is what §7 permits without qualification:
	a non-interactive label absorbs no input at all, so this may live on screen
	permanently while the cursor is the yoke. It is a separate ScreenGui from the
	tablet's because it has to be visible in exactly the state the tablet is not.
]]
local toastGui: ScreenGui? = nil
local toastLabel: TextLabel? = nil
local toastUntil = 0

local TOAST_SECONDS = 4

local function log(message: string, ...)
	print("[FlightSim:Tablet] " .. string.format(message, ...))
end

-- =========================================================================
-- THE GATE
-- =========================================================================

--[[
	May the tablet be open right now, given the live aeroplane?

	A thin reader around the pure rule: this function's whole job is to fetch
	three booleans out of FlightController and hand them to
	InputController.tabletMayOpen, which owns the decision and is tested
	independently of any aircraft.
]]
function TabletController.mayOpen(): boolean
	local systems = FlightController.getSystems()
	return InputController.tabletMayOpen(
		FlightController.isFlying(),
		FlightController.isOnGround(),
		systems ~= nil and systems.altitudeHold == true
	)
end

--[[
	Pure, and exported so runTests() can drive the key without a keyboard - the
	same shape as UIController.shouldToggleHud and FlightController.shouldReset.

	`blocked` is true when the press belongs to something else: Roblox consumed
	it, or a text box has focus. M is a LETTER, so without that guard typing
	"climbing" in chat would open and close the tablet twice mid-sentence - and
	unlike the HUD, opening this one takes the controls away.
]]
function TabletController.shouldToggle(keyCode: Enum.KeyCode, blocked: boolean, boundKey: Enum.KeyCode): boolean
	if blocked then
		return false
	end
	return keyCode == boundKey
end

--[[
	Which key opens the tablet.

	The DEFAULTS, not a live aircraft's binding table - like the HUD key and for
	the same reason: this must work with no aircraft at all, so there may be no
	per-player bindings to read. A rebind through InputController.rebind() on the
	defaults is still honoured.
]]
local function tabletKey(): Enum.KeyCode
	return InputController.DEFAULT_BINDINGS.ToggleTablet
end

local function isTyping(): boolean
	return UserInputService:GetFocusedTextBox() ~= nil
end

-- =========================================================================
-- THE TOAST
-- =========================================================================

local function toast(message: string)
	if toastLabel then
		toastLabel.Text = message
		toastLabel.Visible = true
	end
	toastUntil = os.clock() + TOAST_SECONDS
end

local function buildToast(parent: Instance)
	local gui = Instance.new("ScreenGui")
	gui.Name = "FlightTabletMessage"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 21
	gui.Parent = parent

	local text = Instance.new("TextLabel")
	text.Name = "Message"
	text.AnchorPoint = Vector2.new(0.5, 0)
	text.Position = UDim2.new(0.5, 0, 0, 96)
	text.Size = UDim2.new(0, 620, 0, 26)
	text.BackgroundTransparency = 0.35
	text.BackgroundColor3 = Color3.fromRGB(18, 22, 28)
	text.BorderSizePixel = 0
	text.Font = Enum.Font.Code
	text.TextSize = 14
	text.TextColor3 = Color3.fromRGB(226, 152, 72)
	text.Text = ""
	text.Visible = false
	text.Parent = gui

	toastGui = gui
	toastLabel = text
end

-- =========================================================================
-- OPENING AND CLOSING
-- =========================================================================

local function redraw()
	if handle then
		Tablet.renderSelection(handle, snapshot, selection)
	end
end

local function onPick(field: string, id: string)
	selection = Tablet.choose(selection, field, id)
	redraw()
end

--[[
	Fetch the registry, once.

	On its own thread: InvokeServer yields, and yielding inside an input handler
	stalls every other handler behind it. Guarded by `fetching` so mashing M
	while the server is slow cannot queue five identical round trips.

	pcall'd because a RemoteFunction that errors on the server re-raises on the
	client, and a failed fetch must leave the pilot with an explanation rather
	than a blank panel.
]]
local function fetchSnapshot()
	if snapshot or fetching then
		return
	end
	fetching = true

	task.spawn(function()
		local ok, result = pcall(function()
			return Remotes.Get("RequestAirportList"):InvokeServer()
		end)
		fetching = false

		if not ok or type(result) ~= "table" then
			log("Could not fetch the airport list: %s", tostring(result))
			if handle then
				Tablet.setStatus(handle, "Could not reach the server. Close and reopen to retry.", true)
			end
			return
		end

		snapshot = result

		--[[
			The departure column opens on the field the pilot is at. Measured
			from the aircraft if they have one and from their character if they
			do not - after a crash there may be no aeroplane, and the tablet is
			exactly what a pilot reaches for then.
		]]
		local aircraft = FlightController.getAircraft()
		local root = if aircraft then aircraft.PrimaryPart else nil
		if not root then
			local character = player.Character
			local humanoidRoot = character and character:FindFirstChild("HumanoidRootPart")
			root = if humanoidRoot and humanoidRoot:IsA("BasePart") then humanoidRoot else nil
		end

		selection = Tablet.defaultSelection(snapshot, Tablet.nearestAirport(snapshot, root and root.Position))

		if handle then
			Tablet.renderPickers(handle, snapshot, onPick)
			Tablet.setStatus(handle, string.format("%d airfield(s) on file.", #snapshot.airports))
			redraw()
		end
	end)
end

local function setOpen(shouldOpen: boolean)
	open = shouldOpen

	if screenGui then
		screenGui.Enabled = shouldOpen
	end

	--[[
		The controls, and the ONE line that makes this safe. While the tablet is
		up FlightController sends a neutral snapshot, so the cursor is not the
		yoke and the keys are inert. Trim is untouched, so a trimmed aeroplane
		flies on hands-off exactly as it does while the pilot is typing.
	]]
	FlightController.setTabletOpen(shouldOpen)

	if shouldOpen then
		fetchSnapshot()
		redraw()
	end
end

function TabletController.open(): boolean
	if open then
		return true
	end

	if not TabletController.mayOpen() then
		toast(Tablet.CLOSED_IN_FLIGHT_MESSAGE)
		return false
	end

	setOpen(true)
	log("Opened")
	return true
end

function TabletController.close()
	if not open then
		return
	end
	setOpen(false)
	log("Closed")
end

function TabletController.isOpen(): boolean
	return open
end

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	if not TabletController.shouldToggle(input.KeyCode, gameProcessed or isTyping(), tabletKey()) then
		return
	end

	if open then
		TabletController.close()
	else
		TabletController.open()
	end
end

--[[
	Start the flight the tablet is showing.

	On its own thread, for the same reason the fetch is: InvokeServer yields.
	The tablet closes on success rather than on the click, so a refused plan
	leaves the pilot looking at the panel that produced it with the reason
	written underneath.
]]
local function onStartFlight()
	if not open then
		return
	end

	local plan = Tablet.planFor(snapshot, selection)
	if not plan then
		Tablet.setStatus(handle, "Pick a departure and a destination first.", true)
		return
	end

	local request = { aircraftId = selection.aircraftId, from = selection.from, to = selection.to }
	Tablet.setStatus(handle, string.format("Starting %s -> %s...", plan.fromName, plan.toName))

	task.spawn(function()
		local ok, accepted, message = pcall(function()
			return Remotes.Get("StartFlight"):InvokeServer(request)
		end)

		if not ok then
			log("StartFlight failed: %s", tostring(accepted))
			Tablet.setStatus(handle, "Could not reach the server.", true)
			return
		end

		--[[
			pcall folds the remote's two return values into its own, so
			`accepted` is the server's first (was it accepted) and `message` its
			second (the plan, or why not). Unpacked here rather than at the call
			site because getting it wrong reads as the server always refusing.
		]]
		if not accepted then
			Tablet.setStatus(handle, tostring(message), true)
			return
		end

		log("Flight started: %s -> %s", tostring(selection.from), tostring(selection.to))
		TabletController.close()
		toast(string.format(
			"%s to %s. Board the aeroplane on the apron.",
			plan.fromName,
			plan.toName
		))
	end)
end

-- =========================================================================
-- THE PER-FRAME GATE
-- =========================================================================

--[[
	Close the tablet the moment it stops being allowed, and hide the toast when
	it has been read.

	See the header for the hole this closes: the gate is a CONDITION, and an
	aeroplane that leaves the ground with the tablet up would otherwise be
	hand-flying with the yoke released and a clickable panel over the windscreen.

	Cheap enough to run every frame - three boolean reads and a clock comparison.
]]
local function onHeartbeat()
	if open and not TabletController.mayOpen() then
		TabletController.close()
		toast("Tablet closed - you are flying. " .. Tablet.CLOSED_IN_FLIGHT_MESSAGE)
	end

	if toastLabel and toastLabel.Visible and os.clock() > toastUntil then
		toastLabel.Visible = false
	end
end

-- =========================================================================
-- LIFECYCLE
-- =========================================================================

function TabletController.Init()
	if initialised then
		return
	end
	initialised = true

	local playerGui = player:WaitForChild("PlayerGui")

	local gui, built = Tablet.build(playerGui)
	screenGui = gui
	handle = built

	buildToast(playerGui)

	--[[
		The pickers are drawn empty now and refilled when the snapshot arrives.
		Drawing them at all before the fetch is deliberate: the aircraft column
		comes from ReplicatedStorage and is correct immediately, so a tablet
		opened before the server answers is already half useful.
	]]
	Tablet.renderPickers(handle, nil, onPick)
	Tablet.setStatus(handle, "Fetching airfields...")
	redraw()

	--[[
		Fetched AT STARTUP, not on first open, and this was found by looking at
		the built panel rather than by reasoning: opened cold, the two airport
		columns were empty while the round trip completed, and the aircraft
		column was already full because it needs no network. A picker that is
		blank for the first moments of every session reads as broken.

		The data is static and the call is one round trip, so there is nothing to
		spend by doing it now. setOpen() still calls this, which makes it the
		retry path for a fetch that failed - it is guarded on `snapshot` and
		`fetching`, so an early success means opening costs nothing.
	]]
	fetchSnapshot()

	handle.start.Activated:Connect(onStartFlight)

	--[[
		A LIFETIME connection, deliberately not routed through
		InputController.update() - the third action in this project to be wired
		this way, after ResetAircraft and ToggleHud, and for the same reason
		every time: update() only runs while an aircraft is being flown, and the
		whole point of this key is planning a flight while standing on the apron
		with no aeroplane at all. It is also the only way the key that CLOSES the
		tablet can work, because a tablet that is open is feeding update() a
		snapshot with no keys in it.
	]]
	table.insert(connections, UserInputService.InputBegan:Connect(onInputBegan))
	table.insert(connections, RunService.Heartbeat:Connect(onHeartbeat))

	log("Ready - press %s to open", tabletKey().Name)
end

function TabletController.Shutdown()
	for _, c in connections do
		c:Disconnect()
	end
	table.clear(connections)

	--[[
		Released explicitly rather than left to the GUI going away. The tablet's
		hold on the yoke lives in FlightController, so destroying the panel
		without clearing it would leave the pilot with the controls permanently
		neutral and nothing on screen to explain it.
	]]
	FlightController.setTabletOpen(false)
	open = false

	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end
	if toastGui then
		toastGui:Destroy()
		toastGui = nil
		toastLabel = nil
	end

	handle = nil
	snapshot = nil
	initialised = false
end

-- =========================================================================
-- VERIFICATION
-- =========================================================================

--[[
	Run from the Studio command bar, CLIENT datamodel:
		require(game.StarterPlayer.StarterPlayerScripts.FlightSim.Controllers.TabletController).runTests()

	Delegates to the widget's own suite and then checks this controller's own
	behaviour: the key, and the gate.
]]
function TabletController.runTests(): (boolean, { any })
	local combined = {}
	local allOk = true

	local ok, results = Tablet.runTests()
	allOk = allOk and ok
	for _, r in results do
		table.insert(combined, r)
	end

	local ownOk, ownResults = TabletController.runOwnTests()
	allOk = allOk and ownOk
	for _, r in ownResults do
		table.insert(combined, r)
	end

	return allOk, combined
end

function TabletController.runOwnTests(): (boolean, { any })
	local results = {}
	local allPassed = true

	local function record(label: string, passed: boolean, detail: string)
		if not passed then
			allPassed = false
		end
		table.insert(results, { label = label, passed = passed, detail = detail })
		print(string.format("  [%s] %-54s %s", passed and "PASS" or "FAIL", label, detail))
	end

	print("=== TabletController: verification ===")

	local M = InputController.DEFAULT_BINDINGS.ToggleTablet

	record("The tablet is bound to M", M == Enum.KeyCode.M, tostring(M))
	record("The bound key toggles", TabletController.shouldToggle(M, false, M), "accepted")
	record("Any other key does not", not TabletController.shouldToggle(Enum.KeyCode.J, false, M), "J ignored")

	--[[
		THE one that matters for this key. M is a letter, and unlike the HUD
		toggle, opening this releases the yoke - so typing "climbing" in chat
		would hand the controls over mid-sentence.
	]]
	record(
		"M is ignored while the press belongs to a text box",
		not TabletController.shouldToggle(M, true, M),
		"blocked press ignored"
	)
	record(
		"A rebound key is honoured, and the old one released",
		TabletController.shouldToggle(Enum.KeyCode.N, false, Enum.KeyCode.N)
			and not TabletController.shouldToggle(M, false, Enum.KeyCode.N),
		"N accepted, M ignored"
	)

	--[[
		The gate as this controller reads it. The pure rule is asserted in
		InputController's suite across all four states; what is checked HERE is
		the wiring - that with no aircraft (which is the state this suite runs
		in) the tablet is allowed, because the pilot is on their feet.
	]]
	record(
		"With no aircraft, the tablet is allowed",
		TabletController.mayOpen(),
		"not flying - the pilot is on the apron"
	)

	--[[
		And that the gate is genuinely reading FlightController rather than
		returning a constant. isFlying() is false in this suite, so the only
		honest way to show the wiring is live is to check the reader it depends
		on answers at all.
	]]
	record(
		"The ground reader answers without an aircraft",
		FlightController.isOnGround() == false,
		"false with no rig, rather than erroring"
	)

	--[[
		The tablet's hold on the yoke is a real, observable thing rather than a
		flag this module keeps to itself. Set and cleared here, and restored
		afterwards, because this suite may be run on a live client.
	]]
	local before = FlightController.isTabletOpen()
	FlightController.setTabletOpen(true)
	record(
		"Opening the tablet takes the yoke",
		FlightController.isTabletOpen() == true,
		"FlightController is holding a neutral snapshot"
	)
	FlightController.setTabletOpen(false)
	record(
		"...and closing hands it back",
		FlightController.isTabletOpen() == false,
		"released"
	)
	FlightController.setTabletOpen(before)

	local passCount = 0
	for _, r in results do
		if r.passed then
			passCount += 1
		end
	end
	print(string.format("=== %s (%d/%d) ===", allPassed and "ALL PASSED" or "FAILURES PRESENT", passCount, #results))

	return allPassed, results
end

return TabletController
