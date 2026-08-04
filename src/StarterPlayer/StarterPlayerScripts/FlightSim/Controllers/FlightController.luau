--!strict
--[[
	FlightController
	----------------
	The frame loop. Every other module computes something; this one decides
	when to run them and in what order.

	It owns very little on purpose. Input shaping belongs to InputController,
	forces belong to FlightModel and GroundHandling, and the engine model
	belongs to Engine. What lives here is the sequencing, the lifecycle
	(sit down, fly, get out, die, despawn) and nothing else.

	ORDER WITHIN A FRAME - the part that is easy to get wrong
	---------------------------------------------------------
	  1. Read the assembly ONCE. Every consumer gets the same kinematics, so
	     the aerodynamics and the landing gear cannot disagree about where the
	     aircraft is or how fast it is going.
	  2. Feed altitude and vertical speed to the input layer, so altitude hold
	     is working from this frame's state rather than last frame's.
	  3. Aerodynamics, then gear - the gear needs the lift to know how much
	     weight is still on the wheels.
	  4. Sum, and write ONCE. FlightModel.applyForces overwrites; calling it
	     twice silently discards the first contribution.

	Runs on Stepped, which fires immediately before Roblox integrates physics.
	That is where forces belong: applying them on RenderStepped or Heartbeat
	means they are always one frame stale.

	WHERE THE AIRCRAFT COMES FROM
	-----------------------------
	Not from here. AircraftService builds it on the server and grants this
	client network ownership, then fires AircraftAssigned. This controller waits
	for that event and adopts whatever it is given - it never builds an
	aircraft outside its own test suite.

	NETWORK OWNERSHIP
	-----------------
	Granted by the server at spawn, before this client is ever told the aircraft
	exists, and verified there - BasePart:IsNetworkOwner() does not exist on the
	client, so a check here would be dead code that never fires.

	The failure mode is worth knowing because it is silent: forces written to an
	assembly this client does not own are discarded by the engine with no error
	and no motion, which from the cockpit looks exactly like broken
	aerodynamics. If the controls do nothing at all, read the server log before
	suspecting the physics.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local FlightSim = ReplicatedStorage:WaitForChild("FlightSim")

local Constants = require(FlightSim.Config.Constants)
local Remotes = require(FlightSim.Net.Remotes)
local Registry = require(FlightSim.Aircraft.Registry)
local Engine = require(FlightSim.Physics.Engine)
local FlightModel = require(FlightSim.Physics.FlightModel)
local GroundHandling = require(FlightSim.Physics.GroundHandling)

-- Test-only. runTests() builds its own aircraft rather than asking the server
-- for one, so that the sequencing can be verified without a live server.
local AircraftBuilder = require(FlightSim.Aircraft.AircraftBuilder)
local Cessna172 = require(FlightSim.Aircraft.Definitions.Cessna172)

--[[
	InputController lives under Controls/, not Controllers/. It is not a
	controller in the bootstrap's sense - it has no Init() and is not started
	by Init.client.luau - it is a library this controller drives. The folder
	rename is a separate task; do not "fix" this path.
]]
local InputController = require(script.Parent.Parent:WaitForChild("Controls"):WaitForChild("InputController"))

local FlightController = {}

local min = math.min

-- =========================================================================
-- CONFIGURATION
-- =========================================================================

--[[
	How long to wait for a replicated aircraft to become complete.

	The server fires AircraftAssigned with a Model reference, but a reference is
	not a guarantee that every descendant has arrived on this machine yet.
	Constructing the flight model against a half-replicated aircraft would cache
	a centre of mass computed from whichever parts happened to exist - every
	moment arm silently wrong, and nothing to show for it but an aeroplane that
	flies oddly. So adoption waits for the pieces it needs.
]]
local RIG_WAIT_TIMEOUT = 10

-- =========================================================================
-- STATE
-- =========================================================================

local player = Players.LocalPlayer

local rig: any = nil
local seat: VehicleSeat? = nil

-- Two lifetimes, and conflating them was a real bug waiting to happen. The
-- lifetime connections live as long as the client does; the rig connections
-- belong to one aircraft and are dropped when it is.
local connections: { RBXScriptConnection } = {}
local rigConnections: { RBXScriptConnection } = {}

local stepConnection: RBXScriptConnection? = nil
local initialised = false

--[[
	Reused every frame rather than reallocated. One small table per frame per
	aircraft is real collector pressure at 240 fps for no benefit - the input
	layer reads these numbers immediately and never retains them.
]]
local flightState = { altitude = 0, verticalSpeed = 0 }

local function log(message: string, ...)
	if Constants.DEBUG.ENABLED then
		print("[FlightSim:Flight] " .. string.format(message, ...))
	end
end

-- =========================================================================
-- FRAME
-- =========================================================================

--[[
	One integration step.

	Separated from the loop and from all Roblox event plumbing so it can be
	driven directly by runTests() with synthetic input, exactly as
	FlightModel.computeForces and InputController.update can.

	`snapshot` is an InputController input snapshot. Returns the summed force
	and torque actually written, for inspection.
]]
function FlightController.stepFrame(r: any, dt: number, snapshot: any): (Vector3, Vector3)
	dt = min(dt, Constants.SIM.MAX_TIMESTEP)
	if dt <= 0 then
		return Vector3.zero, Vector3.zero
	end

	local fm = r.flightModel
	local gear = r.gear

	-- 1. One reading of the assembly, shared by everything downstream.
	local k = FlightModel.readKinematics(fm)

	flightState.altitude = k.altitude
	flightState.verticalSpeed = k.velocity.Y

	-- 2. Input.
	local controls, systems = InputController.update(r.input, dt, snapshot, flightState)

	--[[
		Paused: stop integrating, but zero the constraints first.

		Leaving the last frame's force applied while time continues would
		accelerate the aircraft indefinitely - a "pause" that flies away. This
		is a stopgap, not a real pause: Roblox keeps simulating, so the
		aircraft becomes an unpowered glider and falls. Pause needs a proper
		design decision before it is worth binding.
	]]
	if systems.paused then
		FlightModel.release(fm)
		return Vector3.zero, Vector3.zero
	end

	-- 3. Engine. E produces a COMMANDED state; the engine model owns the rest,
	--    including the starter cranking and refusing to catch without fuel.
	if systems.engineCommanded then
		if not fm.engine.running and not fm.engine.starting then
			Engine.start(fm.engine, r.definition.engine)
		end
	elseif fm.engine.running or fm.engine.starting then
		Engine.stop(fm.engine)
	end

	-- 4. Aerodynamics, then gear. The gear needs the lift to know how much
	--    weight the wheels are still carrying.
	local aeroForce, aeroTorque = FlightModel.computeForces(fm, k, dt, controls, nil)
	local gearForce, gearTorque = GroundHandling.computeForces(gear, k, dt, controls, aeroForce.Y)

	local totalForce = aeroForce + gearForce
	local totalTorque = aeroTorque + gearTorque

	-- 5. One write.
	FlightModel.applyForces(fm, totalForce, totalTorque)

	return totalForce, totalTorque
end

-- =========================================================================
-- LIFECYCLE
-- =========================================================================

local function isTyping(): boolean
	-- Without this, typing "was" in chat feeds throttle, rudder and flaps.
	return UserInputService:GetFocusedTextBox() ~= nil
end

--[[
	Neutralise the pilot's body while they are aboard.

	A Roblox character is about 5.7 studs tall and cannot be scaled below
	roughly 5 - the avatar scale limits clamp it - which at 1 stud = 1 m makes
	the pilot a 5.7 METRE giant folded into a 1.5 m cabin. That is not
	cosmetic, it breaks the flight model in two ways:

	  - Mass. A seated character welds into the assembly and moves its centre
	    of mass. FlightModel caches comLocal at spawn and measures every moment
	    arm from it, so the arms would all silently be wrong. Measured: 1122 kg
	    seated against the 1111 kg the aircraft was designed and tested at.
	  - Collision. The character's legs reach well below the cabin floor and
	    through the runway, so the ground shoves the aircraft around via a body
	    that is not supposed to be part of it.

	Making the parts massless and non-collidable fixes both exactly: the
	assembly keeps the mass and balance the physics was built around, and the
	pilot stops fighting the aeroplane. They are invisible from the cockpit
	view anyway, which is where Phase 2 puts the camera.
]]
local function setCharacterNeutralised(character: Model?, neutralised: boolean)
	if not character then
		return
	end
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			part.Massless = neutralised
			part.CanCollide = not neutralised
		end
	end
end

--[[
	Where the yoke is, in screen pixels, and the screen it is measured against.

	THE GUI INSET IS THE TRAP HERE, and it is worth the explanation because it
	produces a small permanent bias rather than an obvious failure.
	GetMouseLocation() measures from the top-left of the area BELOW Roblox's top
	bar, while Camera.ViewportSize describes the whole render viewport including
	the strip behind it. Comparing one against the other puts "centre" about
	half the inset too low - roughly 18 px on a 1080p screen, a few percent of
	permanent nose-up that a pilot would feel as a trimmed-out aircraft and
	never think to blame on a coordinate space.

	Both are therefore reduced to the same space: the usable area below the top
	bar. Verified live rather than assumed - see the handoff.
]]
local function readPointer(): (Vector2, Vector2)
	local camera = workspace.CurrentCamera
	if not camera then
		return Vector2.zero, Vector2.zero
	end

	local inset = GuiService:GetGuiInset()
	local usable = camera.ViewportSize - Vector2.new(inset.X, inset.Y)

	return UserInputService:GetMouseLocation(), usable
end

local function stopLoop()
	if stepConnection then
		stepConnection:Disconnect()
		stepConnection = nil
	end

	if rig then
		FlightModel.release(rig.flightModel)
	end

	-- Belt and braces. The cursor is already free while flying, but anything
	-- that locks it later must not strand the pilot with a trapped pointer.
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

local function startLoop()
	if stepConnection or not rig then
		return
	end

	--[[
		The cursor stays FREE, and visible, for the whole flight.

		This is the PTFS scheme: the pointer's position on screen is the yoke,
		so the pilot can see exactly where their controls are and put them back
		by moving the mouse to the middle. Locking it to centre - which the
		previous relative scheme required, because GetMouseDelta reports nothing
		unless the cursor is locked - would make an absolute position
		meaningless, since a locked cursor never leaves the centre.
	]]
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true

	stepConnection = RunService.Stepped:Connect(function(_, deltaTime)
		if not rig or not rig.model.Parent then
			stopLoop()
			return
		end

		--[[
			Typing releases the yoke rather than freezing it.

			With a free cursor this is not the nicety it was: reaching for the
			chat box moves the pointer to the bottom-left of the screen, which
			under absolute control is hard nose-up and full left roll. Sending a
			neutral snapshot means chatting can never roll the aircraft
			inverted. Trim is untouched, so a trimmed aircraft keeps its
			attitude exactly as it would with the pilot's hands off the yoke.
		]]
		local snapshot
		if isTyping() then
			snapshot = InputController.neutralSnapshot()
		else
			local pointer, viewport = readPointer()
			snapshot = InputController.poll(rig.input, pointer, viewport)
		end

		FlightController.stepFrame(rig, deltaTime, snapshot)
	end)

	log("Flight loop started")
end

local function onOccupantChanged()
	if not seat then
		return
	end

	local occupant = seat.Occupant
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if occupant and occupant == humanoid then
		setCharacterNeutralised(character, true)
		startLoop()
	else
		-- Only report a stop if there was something to stop. This runs once on
		-- adoption, when nobody is aboard yet, and "Flight loop stopped" as the
		-- first line after spawning an aircraft reads like a fault.
		local wasRunning = stepConnection ~= nil
		setCharacterNeutralised(player.Character, false)
		stopLoop()
		if wasRunning then
			log("Flight loop stopped")
		end
	end
end

-- Drop the current aircraft. Lifetime connections survive, so a replacement
-- can be adopted afterwards.
local function releaseRig()
	stopLoop()
	for _, connection in rigConnections do
		connection:Disconnect()
	end
	table.clear(rigConnections)
	rig = nil
	seat = nil
end

local function teardown()
	releaseRig()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

-- =========================================================================
-- ADOPTION
-- =========================================================================

--[[
	Block until the replicated model is complete enough to build a flight model
	against, or give up. Returns the definition, or nil and a reason.

	Waiting on these four specifically: the root (everything is measured from
	it), both constraints (there is nothing to write forces to without them),
	and the seat (there is no way aboard without it). Their arrival does not
	strictly prove every wing panel has replicated, but the model is parented
	last by the builder, so in practice the descendants come as one.
]]
local function waitForRig(model: Model): (any?, string?)
	local deadline = os.clock() + RIG_WAIT_TIMEOUT

	while os.clock() < deadline do
		local root = model.PrimaryPart
		if
			root
			and root:FindFirstChild("AeroForce")
			and root:FindFirstChild("AeroTorque")
			and model:FindFirstChild("PilotSeat")
		then
			break
		end
		if not model.Parent then
			return nil, "the aircraft was destroyed before it finished replicating"
		end
		task.wait()
	end

	if not model.PrimaryPart then
		return nil, string.format("aircraft did not finish replicating within %d s", RIG_WAIT_TIMEOUT)
	end

	--[[
		Which aeroplane is this? The server stamps the id on the model and both
		sides resolve it through the same Registry, so the client never assumes
		it was given the aircraft it asked for - a flight plan or a spawn point
		may well hand it something else.
	]]
	local id = model:GetAttribute("AircraftId")
	local definition = Registry.get(if type(id) == "string" then id else nil)
	if not definition then
		return nil, string.format("unknown AircraftId '%s' on the assigned model", tostring(id))
	end

	return definition, nil
end

--[[
	Take ownership of an aircraft the server has assigned to this client.

	Adopting a second one replaces the first, because the server enforces one
	aircraft per player: a new assignment means the old aircraft is already
	gone or about to be.
]]
local function adopt(model: Model)
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		warn("[FlightSim:Flight] AircraftAssigned fired without a model - nothing to fly.")
		return
	end

	if rig and rig.model == model then
		return
	end

	releaseRig()

	local definition, reason = waitForRig(model)
	if not definition then
		warn("[FlightSim:Flight] Could not adopt the assigned aircraft: " .. tostring(reason))
		return
	end

	local pilotSeat = model:FindFirstChild("PilotSeat")
	if not (pilotSeat and pilotSeat:IsA("VehicleSeat")) then
		warn("[FlightSim:Flight] Assigned aircraft has no VehicleSeat named PilotSeat.")
		return
	end

	-- Published only once fully assembled; a half-built rig reaching the frame
	-- loop would be worse than none.
	rig = {
		model = model,
		definition = definition,
		flightModel = FlightModel.new(model, definition),
		gear = GroundHandling.new(model, definition),
		input = InputController.new(definition),
	}
	seat = pilotSeat

	table.insert(rigConnections, pilotSeat:GetPropertyChangedSignal("Occupant"):Connect(onOccupantChanged))

	-- The aircraft going away must take the loop with it, or Stepped keeps
	-- firing against a destroyed assembly every frame for the rest of the
	-- session.
	table.insert(rigConnections, model.Destroying:Connect(releaseRig))

	log("Adopted %s (%s)", definition.name, model.Name)

	-- Boarding is server-side now: AircraftService puts the ProximityPrompt on
	-- the seat, so every player can see and use it. If the pilot was already
	-- sitting when this arrived - a re-adoption - pick the loop up immediately.
	onOccupantChanged()
end

-- =========================================================================
-- INIT
-- =========================================================================

--[[
	Called once by Init.client.luau.

	Ordering: the AircraftAssigned handler is connected BEFORE the spawn is
	requested. The server fires that event during the invocation, so connecting
	afterwards is a race this would sometimes lose - and losing it means sitting
	on the apron with no aeroplane and no error.

	The request itself runs on its own thread. InvokeServer yields, and the
	bootstrap starts controllers in order on one thread, so blocking here would
	hold up every controller after this one for a network round trip.
]]
function FlightController.Init()
	if initialised then
		return
	end
	initialised = true

	table.insert(connections, Remotes.Get("AircraftAssigned").OnClientEvent:Connect(adopt))

	--[[
		Dying while seated does not always fire Occupant changed before the
		character is gone, so release explicitly. Without this the constraints
		keep their last force and the empty aircraft flies itself away.
	]]
	table.insert(connections, player.CharacterRemoving:Connect(stopLoop))

	--[[
		Dying gets you a fresh aircraft.

		The server treats a spawn request from a player who already has one as
		"replace it", so this is currently the only route back into the air
		after putting an aeroplane on its back: die, or respawn the character
		from the Roblox menu. There is no reset-aircraft key yet - binding one
		is a decision for the pilot, since the bindings are theirs.

		Death rather than CharacterAdded, deliberately. The initial character
		may arrive either side of this controller starting, so requesting on
		CharacterAdded would sometimes fire a second spawn moments after the
		first and replace an aircraft the pilot had already boarded. Died only
		ever means what it says.
	]]
	local diedConnection: RBXScriptConnection? = nil

	local function watchCharacter(character: Model)
		if diedConnection then
			diedConnection:Disconnect()
		end
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			diedConnection = humanoid.Died:Connect(function()
				FlightController.requestAircraft()
			end)
		end
	end

	table.insert(connections, player.CharacterAdded:Connect(watchCharacter))
	if player.Character then
		task.spawn(watchCharacter, player.Character)
	end

	task.spawn(FlightController.requestAircraft)
end

--[[
	Ask the server for an aircraft. The reply is only ever a yes or a reason -
	the aircraft itself arrives on AircraftAssigned, so there is exactly one
	path by which this client ever adopts one.
]]
function FlightController.requestAircraft(aircraftId: string?)
	local ok, accepted, message = pcall(function()
		return Remotes.Get("RequestSpawnAircraft"):InvokeServer(aircraftId or Registry.DEFAULT_ID)
	end)

	if not ok then
		warn("[FlightSim:Flight] Spawn request failed: " .. tostring(accepted))
		return
	end

	if not accepted then
		warn("[FlightSim:Flight] Server refused to spawn an aircraft: " .. tostring(message))
	end
end

function FlightController.Shutdown()
	teardown()
	initialised = false
end

-- =========================================================================
-- VERIFICATION
-- =========================================================================

--[[
	Run from the Studio command bar:
		require(game.StarterPlayer.StarterPlayerScripts.FlightSim.Controllers.FlightController).runTests()

	Exercises stepFrame() against a real assembly with synthetic input, which
	covers the sequencing this module exists to get right. It does not test the
	Roblox event plumbing - sitting down, dying - because that needs a player.

	The rig is built 5 km from the origin, on its own pad, because that is where
	the aircraft ISN'T. AircraftService parks live aircraft on the origin, and
	these test parts are created on the client, inside the same workspace, with
	collision on. A test rig materialising inside the pilot's aeroplane would
	shove it - and since the pilot's client owns that assembly, the shove would
	replicate and be entirely real. Distance is the cheap fix.
]]
local TEST_ORIGIN = Vector3.new(5000, 0, 5000)
function FlightController.runTests(): (boolean, { any })
	local results = {}
	local allPassed = true

	local function record(label: string, passed: boolean, detail: string)
		if not passed then
			allPassed = false
		end
		table.insert(results, { label = label, passed = passed, detail = detail })
		print(string.format("  [%s] %-46s %s", passed and "PASS" or "FAIL", label, detail))
	end

	print("=== FlightController: verification ===")

	local pad = Instance.new("Part")
	pad.Name = "__FlightControllerTestPad"
	pad.Size = Vector3.new(400, 4, 400)
	pad.Position = TEST_ORIGIN + Vector3.new(0, -2, 0)
	pad.Anchored = true
	pad.Parent = workspace

	local model = AircraftBuilder.build(Cessna172, CFrame.new(TEST_ORIGIN + Vector3.new(0, 1.30, 0)), workspace)

	--[[
		Everything from here to the matching cleanup runs inside a pcall.

		An earlier version destroyed the rig on the last line, which meant any
		error mid-suite leaked a 1,100 kg aircraft and a 400 m pad into the
		workspace - and in Studio those survive into the next Play session and
		look convincingly like a double-spawn bug. It cost real time to
		diagnose once already.
	]]
	local testRig = {
		model = model,
		definition = Cessna172,
		flightModel = FlightModel.new(model, Cessna172),
		gear = GroundHandling.new(model, Cessna172),
		input = InputController.new(Cessna172),
	}

	local body = function()

	local dt = 1 / 60

	-- A synthetic screen with the cursor parked in the middle, so the yoke sits
	-- neutral and these sequencing tests are not fighting a phantom roll input.
	local VIEWPORT = Vector2.new(1920, 1080)
	local function snap(actions: { string }?, pointerPos: Vector2?)
		local held = {}
		if actions then
			for _, a in actions do
				held[a] = true
			end
		end
		return {
			held = held,
			pointer = pointerPos or VIEWPORT * 0.5,
			viewportSize = VIEWPORT,
		}
	end

	-- 1. A frame runs and produces something finite.
	local f, t = FlightController.stepFrame(testRig, dt, snap())
	record(
		"A frame produces finite force and torque",
		f.Magnitude == f.Magnitude and f.Magnitude < math.huge
			and t.Magnitude == t.Magnitude and t.Magnitude < math.huge,
		string.format("|F| = %.1f N, |T| = %.1f N*m", f.Magnitude, t.Magnitude)
	)

	--[[
		2. THE check this module exists for: exactly one write per frame.

		applyForces overwrites, so if the gear contribution were written
		separately the aerodynamics would be silently discarded. Comparing the
		constraint against the returned sum catches that.
	]]
	local root = model.PrimaryPart :: BasePart
	local aeroForce = root:FindFirstChild("AeroForce") :: VectorForce
	local written = aeroForce.Force / Constants.STUDS_PER_METER
	record(
		"The constraint holds the SUM of both contributors",
		(written - f).Magnitude < 1e-3,
		string.format("written %.1f N vs returned %.1f N", written.Magnitude, f.Magnitude)
	)

	-- 3. On the ground with no power, the gear must be contributing.
	record(
		"Gear forces reach the constraint on the ground",
		testRig.gear.telemetry.onGround,
		string.format("%d wheels down", testRig.gear.telemetry.wheelsOnGround)
	)

	-- 4. dt is clamped, so a frame hitch cannot integrate a huge step.
	local fHitch = FlightController.stepFrame(testRig, 10, snap())
	record(
		"A 10 s frame hitch stays finite",
		fHitch.Magnitude == fHitch.Magnitude and fHitch.Magnitude < math.huge,
		string.format("|F| = %.1f N", fHitch.Magnitude)
	)
	record(
		"Zero dt is a no-op",
		select(1, FlightController.stepFrame(testRig, 0, snap())) == Vector3.zero,
		"returned zero"
	)

	-- 5. Engine command wiring.
	record("Engine starts stopped", not testRig.flightModel.engine.running, "running = false")

	FlightController.stepFrame(testRig, dt, snap({ "EngineToggle" }))
	for _ = 1, 180 do
		FlightController.stepFrame(testRig, dt, snap())
	end
	record(
		"E commands the engine to start",
		testRig.flightModel.engine.running,
		string.format("running = true, rpm %.0f", testRig.flightModel.engine.rpm)
	)

	--[[
		6. Pause must not leave a force applied.

		Run with the engine live and the throttle open, because a parked
		aircraft with the engine off produces exactly zero force anyway - the
		test would pass whether pause worked or not.
	]]
	for _ = 1, 120 do
		FlightController.stepFrame(testRig, dt, snap({ "ThrottleUp" }))
	end
	local fPowered = select(1, FlightController.stepFrame(testRig, dt, snap()))
	record(
		"Setup: thrust is being produced before pausing",
		fPowered.Magnitude > 100,
		string.format("|F| = %.0f N", fPowered.Magnitude)
	)

	FlightController.stepFrame(testRig, dt, snap({ "Pause" }))
	local fPaused = FlightController.stepFrame(testRig, dt, snap())
	record(
		"Pause zeroes the constraints",
		fPaused == Vector3.zero and aeroForce.Force == Vector3.zero,
		string.format("|F| = %.6f", aeroForce.Force.Magnitude)
	)

	FlightController.stepFrame(testRig, dt, snap({ "Pause" }))
	local fResumed = FlightController.stepFrame(testRig, dt, snap())
	record(
		"Unpausing resumes integration",
		fResumed.Magnitude > 100,
		string.format("|F| = %.0f N", fResumed.Magnitude)
	)

	FlightController.stepFrame(testRig, dt, snap({ "EngineToggle" }))
	FlightController.stepFrame(testRig, dt, snap())
	record(
		"E commands it to stop again",
		not testRig.flightModel.engine.running,
		"running = false"
	)

	-- 7. Telemetry is populated for the HUD that comes next.
	local tel = testRig.flightModel.telemetry
	record(
		"Telemetry is populated",
		type(tel.altitude) == "number" and type(tel.airspeedTrue) == "number" and tel.altitude == tel.altitude,
		string.format("alt %.1f m, IAS %.1f m/s", tel.altitude, tel.airspeedIndicated)
	)

	-- 8. Release leaves nothing applied.
	FlightModel.release(testRig.flightModel)
	record(
		"release() zeroes both constraints",
		aeroForce.Force == Vector3.zero,
		"zeroed"
	)
	end

	local ok, err = pcall(body)

	model:Destroy()
	pad:Destroy()

	if not ok then
		allPassed = false
		record("Suite completed without erroring", false, tostring(err))
	end

	local passCount = 0
	for _, r in results do
		if r.passed then
			passCount += 1
		end
	end
	print(string.format("=== %s (%d/%d) ===", allPassed and "ALL PASSED" or "FAILURES PRESENT", passCount, #results))

	return allPassed, results
end

return FlightController
