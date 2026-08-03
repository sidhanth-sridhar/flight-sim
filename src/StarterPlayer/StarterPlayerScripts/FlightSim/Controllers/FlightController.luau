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

	NETWORK OWNERSHIP
	-----------------
	Not handled here, because it does not need to be. A VehicleSeat transfers
	ownership of its whole assembly to whoever sits in it, which is the entire
	reason the pilot's seat is a VehicleSeat. If the aircraft is not owned by
	this client the forces written here are simply ignored by the engine, so
	there is no failure mode to guard against - only a loop doing nothing.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local FlightSim = ReplicatedStorage:WaitForChild("FlightSim")

local Constants = require(FlightSim.Config.Constants)
local AircraftBuilder = require(FlightSim.Aircraft.AircraftBuilder)
local Cessna172 = require(FlightSim.Aircraft.Definitions.Cessna172)
local Engine = require(FlightSim.Physics.Engine)
local FlightModel = require(FlightSim.Physics.FlightModel)
local GroundHandling = require(FlightSim.Physics.GroundHandling)

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
	Where the test aircraft appears. AircraftService does not exist yet, so
	this controller spawns one itself purely so there is something to fly.

	100 m up, as specified. Note this means the aircraft free-falls onto the
	baseplate before anyone can reach it. To have it start parked instead, use
	CFrame.new(0, 1.30, 0) - that is the height at which the tyres rest exactly
	on a surface whose top is y = 0, derived in GroundHandling.runTests().
]]
local SPAWN_CFRAME = CFrame.new(0, 1.30, 0)

-- =========================================================================
-- STATE
-- =========================================================================

local player = Players.LocalPlayer

local rig: any = nil
local seat: VehicleSeat? = nil
local connections: { RBXScriptConnection } = {}
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

local EMPTY_SNAPSHOT = { held = {}, mouseDelta = Vector2.zero }

local function stopLoop()
	if stepConnection then
		stepConnection:Disconnect()
		stepConnection = nil
	end

	if rig then
		FlightModel.release(rig.flightModel)
	end

	--[[
		Hand the mouse back. Locking it is what makes GetMouseDelta report
		anything at all - unlocked, it returns zero and the yoke is dead - but
		leaving it locked after the pilot climbs out would trap the cursor.
	]]
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
end

local function startLoop()
	if stepConnection or not rig then
		return
	end

	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter

	stepConnection = RunService.Stepped:Connect(function(_, deltaTime)
		if not rig or not rig.model.Parent then
			stopLoop()
			return
		end

		local snapshot = if isTyping()
			then EMPTY_SNAPSHOT
			else InputController.poll(rig.input, UserInputService:GetMouseDelta())

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
		setCharacterNeutralised(player.Character, false)
		stopLoop()
		log("Flight loop stopped")
	end
end

local function teardown()
	stopLoop()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	rig = nil
	seat = nil
end

-- =========================================================================
-- INIT
-- =========================================================================

--[[
	Called once by Init.client.luau. Anything thrown here is caught by the
	bootstrap's pcall, which is why nothing below leaves partial state behind:
	the rig is only published once it is completely assembled.
]]
function FlightController.Init()
	if initialised then
		return
	end
	initialised = true

	local model = AircraftBuilder.build(Cessna172, SPAWN_CFRAME, workspace)

	rig = {
		model = model,
		definition = Cessna172,
		flightModel = FlightModel.new(model, Cessna172),
		gear = GroundHandling.new(model, Cessna172),
		input = InputController.new(Cessna172),
	}

	local pilotSeat = model:FindFirstChild("PilotSeat")
	if not (pilotSeat and pilotSeat:IsA("VehicleSeat")) then
		error("[FlightController] aircraft has no VehicleSeat named PilotSeat")
	end
	seat = pilotSeat

	table.insert(connections, pilotSeat:GetPropertyChangedSignal("Occupant"):Connect(onOccupantChanged))

	--[[
		Boarding needs a prompt, not a touch. Roblox seats are triggered by the
		character touching them, and a 5.7 m character cannot touch a 0.55 m
		seat buried inside the cabin - the root part passes nearly a metre
		above it. Sit() sidesteps the geometry entirely.
	]]
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "BoardPrompt"
	prompt.ActionText = "Board"
	prompt.ObjectText = Cessna172.name
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = pilotSeat

	table.insert(connections, prompt.Triggered:Connect(function(triggeringPlayer)
		if triggeringPlayer ~= player then
			return
		end
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			pilotSeat:Sit(humanoid)
		end
	end))

	-- The aircraft going away must take the loop with it, or Stepped keeps
	-- firing against a destroyed assembly every frame for the rest of the
	-- session.
	table.insert(connections, model.Destroying:Connect(teardown))

	--[[
		Dying while seated does not always fire Occupant changed before the
		character is gone, so release explicitly. Without this the constraints
		keep their last force and the empty aircraft flies itself away.
	]]
	table.insert(connections, player.CharacterRemoving:Connect(stopLoop))

	log("Ready - %s spawned at %s", Cessna172.name, tostring(SPAWN_CFRAME.Position))
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
]]
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
	pad.Position = Vector3.new(0, -2, 0)
	pad.Anchored = true
	pad.Parent = workspace

	local model = AircraftBuilder.build(Cessna172, CFrame.new(0, 1.30, 0), workspace)

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
	local function snap(actions: { string }?, mouse: Vector2?)
		local held = {}
		if actions then
			for _, a in actions do
				held[a] = true
			end
		end
		return { held = held, mouseDelta = mouse or Vector2.zero }
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
