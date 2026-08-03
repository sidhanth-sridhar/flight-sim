--!strict
--[[
	InputController
	---------------
	Turns keyboard and mouse into the control values the physics consumes.

	THE CONTRACT
	------------
	`state.controls` is exactly the Controls table FlightModel and
	GroundHandling already expect, with the signs they already define:

		pitch     -1..1   positive = nose up
		roll      -1..1   positive = right
		yaw       -1..1   positive = nose right
		throttle   0..1
		flaps      0..1   fraction of the aircraft's maximum deflection
		brake      0..1

	Nothing here changes those semantics. The three new pieces of state the
	control scheme needs - engine on/off, camera hold, altitude hold - live in
	a SEPARATE `state.systems` table rather than being bolted onto Controls,
	so the physics contract is untouched and FlightModel needs no edit to
	accept them.

	WHY update() TAKES A SNAPSHOT
	-----------------------------
	Reading UserInputService directly inside the update loop would make this
	module untestable - every check would need a real player pressing real
	keys. Instead `poll()` gathers a plain snapshot of which ACTIONS are held,
	and `update()` is a pure function of (state, dt, snapshot, flightState).
	The test suite drives it frame by frame with synthetic snapshots, which is
	how the ramps, the edge-triggered detents and the altitude-hold law can be
	verified at all.

	Actions, not keys: the snapshot is keyed by action name, so rebinding is a
	change to one table and never touches the logic.

	SMOOTHING
	---------
	Controls are smoothed, never instant. A yoke has mass and a throttle has
	travel, and the difference between "instant" and "eased" is most of what
	makes an aircraft feel like an aircraft rather than a cursor. All smoothing
	is frame-rate independent - see MathUtil.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local FlightSim = ReplicatedStorage:WaitForChild("FlightSim")
local Constants = require(FlightSim.Config.Constants)
local MathUtil = require(FlightSim.Shared.MathUtil)

local InputController = {}

local clamp = math.clamp
local abs = math.abs

-- =========================================================================
-- BINDINGS
-- =========================================================================

--[[
	Action -> key. Overridable per player at construction, which is what the
	settings menu will edit later; the logic below never mentions a KeyCode.

	The eight bindings specified by the pilot are marked. The rest are chosen
	to stay clear of them and of each other.
]]
InputController.DEFAULT_BINDINGS = {
	ThrottleUp = Enum.KeyCode.W, -- specified
	ThrottleDown = Enum.KeyCode.S, -- specified
	YawLeft = Enum.KeyCode.A, -- specified
	YawRight = Enum.KeyCode.D, -- specified
	FlapsDown = Enum.KeyCode.F, -- specified
	FlapsUp = Enum.KeyCode.G, -- specified
	CameraHold = Enum.KeyCode.C, -- specified
	AltitudeHold = Enum.KeyCode.R, -- specified
	EngineToggle = Enum.KeyCode.E, -- specified

	--[[
		Brake on B. V was the alternative, but V is wanted for cycling the
		view: it sits next to C, and camera hold and view cycle belong
		together. B is also where most flight sims put wheel brakes.
	]]
	Brake = Enum.KeyCode.B,

	-- Pitch trim. Genuinely useful once the aircraft is stable enough to fly
	-- hands-off, and comma/period are well clear of the left-hand cluster.
	TrimNoseDown = Enum.KeyCode.Comma,
	TrimNoseUp = Enum.KeyCode.Period,

	--[[
		Gear on L, not the conventional G - the pilot assigned G to flaps up.
		A no-op on the fixed-gear 172, wired now so the retractable aircraft in
		Phase 5 needs no new binding.
	]]
	GearToggle = Enum.KeyCode.L,

	ViewCycle = Enum.KeyCode.V,
	Pause = Enum.KeyCode.P,

	-- Zero the virtual stick without moving the mouse. Only meaningful in
	-- Direct mode, where the stick stays where it was last put.
	RecenterStick = Enum.KeyCode.X,
	MouseModeToggle = Enum.KeyCode.M,
}

-- =========================================================================
-- TUNING
-- =========================================================================

InputController.DEFAULTS = {
	--[[
		Mouse.

		Direct    the pointer IS the yoke: deflection accumulates and stays
		          where it is put, so the aircraft can be trimmed and left.
		          This is the realistic mode.
		Centering the stick springs back to neutral when the mouse stops. More
		          forgiving, and the arcade mode of the two.
	]]
	mouseMode = "Direct",
	mouseSensitivity = 0.0035, -- stick deflection per pixel
	mouseExpo = 0.35, -- fine control near centre, full authority at the edge
	mouseDeadzone = 0.02,
	centeringRate = 2.5, -- per second, Centering mode only

	throttleRate = 0.5, -- full travel in 2 s
	yawRate = 2.5, -- pedal application
	yawReturnRate = 3.5, -- pedals centre faster than they apply
	brakeRate = 6.0,
	trimRate = 0.08, -- per second held

	-- Time constant for the yoke's "mass". Small: this is control feel, not
	-- aircraft response, and the aircraft's own inertia does the rest.
	controlSmoothTime = 0.06,

	trimLimit = 0.35,

	--[[
		Altitude hold, as a cascade: altitude error sets a target vertical
		speed, and the vertical speed error sets a pitch command. Cascading
		rather than commanding pitch straight from altitude error is what stops
		it porpoising - the inner loop damps the outer one.
	]]
	altHold = {
		altitudeGain = 0.06, -- m/s of climb demanded per metre of error
		maxClimbRate = 5.0, -- m/s, roughly 1000 ft/min
		verticalSpeedGain = 0.18, -- pitch command per m/s of error
		pitchLimit = 0.45, -- never commands more than this, however lost it is
		-- Stick movement AWAY FROM where it sat at engagement that disconnects
		-- it, as every autopilot does. Measured as a change, not an absolute -
		-- see the note at the disconnect test.
		disconnectThreshold = 0.15,
	},

	-- Cockpit / chase / free, per the camera modes the design calls for.
	-- ViewCycle wraps within this count; the camera system owns the meaning.
	viewCount = 3,
}

-- =========================================================================
-- TYPES
-- =========================================================================

export type Controls = {
	pitch: number,
	roll: number,
	yaw: number,
	throttle: number,
	flaps: number,
	brake: number,
}

--[[
	State that is not a physics control input.

	Kept apart from Controls deliberately: FlightModel's contract stays exactly
	as it was, and FlightController reads these to drive the systems they name.
]]
export type Systems = {
	engineCommanded: boolean, -- E. FlightController calls Engine.start/stop.
	cameraHold: boolean, -- C. Momentary - true only while held.
	altitudeHold: boolean, -- R. Latching toggle.
	altitudeTargetM: number, -- captured when altitude hold engages
	gearDown: boolean, -- L
	paused: boolean, -- P
	viewIndex: number, -- V, cycles
	mouseMode: string,
}

export type InputSnapshot = {
	held: { [string]: boolean },
	mouseDelta: Vector2,
}

export type FlightState = {
	altitude: number, -- m
	verticalSpeed: number, -- m/s
}

-- =========================================================================
-- CONSTRUCTION
-- =========================================================================

function InputController.new(definition: any, overrides: { [string]: any }?)
	local config = table.clone(InputController.DEFAULTS)
	config.altHold = table.clone(InputController.DEFAULTS.altHold)
	if overrides then
		for k, v in overrides do
			config[k] = v
		end
	end

	--[[
		Flap detents come from the aircraft, not from here. The 172 has four
		(0/10/20/30 degrees); another aircraft may have six or none, and F/G
		step through whatever it declares.
	]]
	local flaps = definition.flaps
	local detents = {}
	for i, degrees in flaps.detents do
		detents[i] = degrees / flaps.maxDeflection
	end

	return {
		definition = definition,
		config = config,
		bindings = table.clone(InputController.DEFAULT_BINDINGS),

		detents = detents,
		detentIndex = 1,
		flapsTarget = detents[1],

		-- The virtual stick, in deflection units before shaping.
		stickX = 0,
		stickY = 0,
		trim = 0,

		-- smoothDamp carries velocity; the caller owns it.
		pitchVelocity = 0,
		rollVelocity = 0,

		-- Stick position captured when altitude hold engaged; the disconnect
		-- test measures movement away from this, not absolute deflection.
		altHoldPitchReference = 0,

		-- Previous frame's held set, for edge detection.
		wasHeld = {} :: { [string]: boolean },

		controls = {
			pitch = 0,
			roll = 0,
			yaw = 0,
			throttle = 0,
			flaps = detents[1],
			brake = 0,
		} :: Controls,

		systems = {
			engineCommanded = false,
			cameraHold = false,
			altitudeHold = false,
			altitudeTargetM = 0,
			gearDown = true,
			paused = false,
			viewIndex = 1,
			mouseMode = config.mouseMode,
		} :: Systems,
	}
end

-- =========================================================================
-- ALTITUDE HOLD
-- =========================================================================

--[[
	Pitch command to hold an altitude.

	Cascaded: altitude error -> demanded vertical speed -> pitch. The inner
	vertical-speed loop is what provides the damping; commanding pitch directly
	from altitude error gives a phugoid that never settles.

	Pure, and exported so the tests can exercise the law on its own.
]]
function InputController.altitudeHoldPitch(config: any, targetM: number, altitudeM: number, verticalSpeedMs: number): number
	local a = config.altHold

	local altitudeError = targetM - altitudeM
	local demandedClimb = clamp(altitudeError * a.altitudeGain, -a.maxClimbRate, a.maxClimbRate)
	local climbError = demandedClimb - verticalSpeedMs

	return clamp(climbError * a.verticalSpeedGain, -a.pitchLimit, a.pitchLimit)
end

-- =========================================================================
-- UPDATE
-- =========================================================================

local function rising(state: any, snapshot: InputSnapshot, action: string): boolean
	return snapshot.held[action] == true and state.wasHeld[action] ~= true
end

--[[
	Advance the control state by one frame.

	Pure with respect to Roblox: everything it needs is in `snapshot` and
	`flightState`. `flightState` may be nil when the aircraft is not flying;
	altitude hold simply cannot engage without it.
]]
function InputController.update(state: any, dt: number, snapshot: InputSnapshot, flightState: FlightState?)
	dt = clamp(dt, 0, Constants.SIM.MAX_TIMESTEP)
	if dt <= 0 then
		return state.controls, state.systems
	end

	local config = state.config
	local controls = state.controls
	local systems = state.systems
	local held = snapshot.held

	-- ---- Latching toggles (edge-triggered) -------------------------------
	--[[
		Edge detection matters for every one of these. Without it, holding F
		for a fifth of a second would run the flaps from up to fully down, and
		E would strobe the engine on and off at frame rate.
	]]
	if rising(state, snapshot, "EngineToggle") then
		systems.engineCommanded = not systems.engineCommanded
	end
	if rising(state, snapshot, "GearToggle") and state.definition.gear.retractable then
		systems.gearDown = not systems.gearDown
	end
	if rising(state, snapshot, "Pause") then
		systems.paused = not systems.paused
	end
	if rising(state, snapshot, "ViewCycle") then
		-- Wraps rather than growing without bound, so the camera system can
		-- index straight into its view list with no arithmetic of its own.
		systems.viewIndex = (systems.viewIndex % config.viewCount) + 1
	end
	if rising(state, snapshot, "MouseModeToggle") then
		systems.mouseMode = if systems.mouseMode == "Direct" then "Centering" else "Direct"
	end
	if rising(state, snapshot, "RecenterStick") then
		--[[
			Clearing the smoothing velocities as well as the stick matters:
			smoothDamp carries momentum, so zeroing only the input leaves the
			controls coasting past neutral and settling from the far side.

			Trim is deliberately NOT cleared. Recentring the stick means
			letting go of it, and a trimmed aircraft with the stick released
			holds its trimmed attitude - that is what trim is for. Zeroing it
			here would make the aircraft pitch the moment the pilot tidied up
			their controls.
		]]
		state.stickX, state.stickY = 0, 0
		state.pitchVelocity, state.rollVelocity = 0, 0
	end

	-- C is momentary: the camera is held only while the key is down.
	systems.cameraHold = held.CameraHold == true

	-- ---- Flaps -----------------------------------------------------------
	-- F steps toward more flap, G back toward clean, one detent per press.
	if rising(state, snapshot, "FlapsDown") then
		state.detentIndex = math.min(state.detentIndex + 1, #state.detents)
		state.flapsTarget = state.detents[state.detentIndex]
	end
	if rising(state, snapshot, "FlapsUp") then
		state.detentIndex = math.max(state.detentIndex - 1, 1)
		state.flapsTarget = state.detents[state.detentIndex]
	end

	--[[
		Flaps travel at a fixed rate rather than snapping. They are slow on a
		real aircraft - deliberately so, because deploying them instantly at
		speed would tear them off - and that slowness is felt on approach.
	]]
	local flapRate = 1 / math.max(state.definition.flaps.travelTime, 0.01)
	controls.flaps = MathUtil.approach(controls.flaps, state.flapsTarget, flapRate * dt)

	-- ---- Throttle --------------------------------------------------------
	-- Hold to ramp, in both directions. A throttle lever has travel.
	local throttleDelta = 0
	if held.ThrottleUp then
		throttleDelta += config.throttleRate * dt
	end
	if held.ThrottleDown then
		throttleDelta -= config.throttleRate * dt
	end
	controls.throttle = clamp(controls.throttle + throttleDelta, 0, 1)

	-- ---- Rudder ----------------------------------------------------------
	--[[
		One axis, no mode switching: on the ground GroundHandling reads it as
		nose wheel steering, in the air the fin reads it as rudder. The handover
		is continuous because steering authority fades with wheel load rather
		than being switched off.

		Pedals centre faster than they apply, which is what a spring-centred
		pedal set does and stops the aircraft wallowing in yaw.
	]]
	local yawTarget = 0
	if held.YawLeft then
		yawTarget -= 1
	end
	if held.YawRight then
		yawTarget += 1
	end

	local yawSpeed = if yawTarget == 0 then config.yawReturnRate else config.yawRate
	controls.yaw = MathUtil.approach(controls.yaw, yawTarget, yawSpeed * dt)

	-- ---- Brake -----------------------------------------------------------
	controls.brake = MathUtil.approach(controls.brake, if held.Brake then 1 else 0, config.brakeRate * dt)

	-- ---- Trim ------------------------------------------------------------
	if held.TrimNoseUp then
		state.trim += config.trimRate * dt
	end
	if held.TrimNoseDown then
		state.trim -= config.trimRate * dt
	end
	state.trim = clamp(state.trim, -config.trimLimit, config.trimLimit)

	-- ---- Mouse: pitch and roll -------------------------------------------
	--[[
		INVERTED, as specified and as every flight sim does it: pushing the
		pointer forward pitches the nose DOWN.

		Roblox reports Delta.Y as negative when the mouse moves forward, and
		pitch is positive nose-up, so accumulating the delta directly gives the
		inverted sense with no negation anywhere. Sign errors here are the most
		likely thing to be wrong in this file, so both directions are asserted
		in runTests().
	]]
	local delta = snapshot.mouseDelta
	state.stickX = clamp(state.stickX + delta.X * config.mouseSensitivity, -1, 1)
	state.stickY = clamp(state.stickY + delta.Y * config.mouseSensitivity, -1, 1)

	if systems.mouseMode == "Centering" and delta.Magnitude < 1e-6 then
		local decay = config.centeringRate * dt
		state.stickX = MathUtil.approach(state.stickX, 0, decay)
		state.stickY = MathUtil.approach(state.stickY, 0, decay)
	end

	-- Deadzone removes drift near centre; expo gives fine control there while
	-- keeping full deflection reachable at the edges.
	local rawRoll = MathUtil.expo(MathUtil.deadzone(state.stickX, config.mouseDeadzone), config.mouseExpo)
	local rawPitch = MathUtil.expo(MathUtil.deadzone(state.stickY, config.mouseDeadzone), config.mouseExpo)

	-- ---- Altitude hold ---------------------------------------------------
	local engagedThisFrame = false
	if rising(state, snapshot, "AltitudeHold") and flightState then
		systems.altitudeHold = not systems.altitudeHold
		if systems.altitudeHold then
			-- Capture the altitude at the moment of engagement, which is what
			-- the pilot means by "hold this".
			systems.altitudeTargetM = flightState.altitude
			--[[
				Also capture where the stick was sitting. The disconnect test
				below measures MOVEMENT away from this reference, not absolute
				deflection.

				Absolute deflection cannot work here: in Direct mouse mode the
				stick holds wherever it was last put, so a pilot holding any
				real pitch input - the normal way to fly without trim - would
				press R and have it engage and drop out on the same frame, with
				nothing to show for it but a dead key. Real autopilots
				disconnect on a change in control pressure for the same reason.
			]]
			state.altHoldPitchReference = rawPitch
			engagedThisFrame = true
		end
	end

	-- Moving the stick away from where it was at engagement disconnects it.
	if systems.altitudeHold and not engagedThisFrame then
		if abs(rawPitch - state.altHoldPitchReference) > config.altHold.disconnectThreshold then
			systems.altitudeHold = false
		end
	end

	local commandedPitch: number
	if systems.altitudeHold and flightState then
		commandedPitch = InputController.altitudeHoldPitch(
			config,
			systems.altitudeTargetM,
			flightState.altitude,
			flightState.verticalSpeed
		)
	else
		commandedPitch = clamp(rawPitch + state.trim, -1, 1)
	end

	-- ---- Smoothing -------------------------------------------------------
	-- The yoke has mass. Applied last so it smooths whatever produced the
	-- command, including an altitude-hold handover.
	controls.pitch, state.pitchVelocity =
		MathUtil.smoothDamp(controls.pitch, commandedPitch, state.pitchVelocity, config.controlSmoothTime, dt)
	controls.roll, state.rollVelocity =
		MathUtil.smoothDamp(controls.roll, rawRoll, state.rollVelocity, config.controlSmoothTime, dt)

	--[[
		smoothDamp can overshoot fractionally on a large step, and a control
		value outside its declared range would silently violate the contract
		the physics relies on.
	]]
	controls.pitch = clamp(MathUtil.sanitize(controls.pitch), -1, 1)
	controls.roll = clamp(MathUtil.sanitize(controls.roll), -1, 1)
	controls.yaw = clamp(MathUtil.sanitize(controls.yaw), -1, 1)
	controls.throttle = clamp(MathUtil.sanitize(controls.throttle), 0, 1)
	controls.flaps = clamp(MathUtil.sanitize(controls.flaps), 0, 1)
	controls.brake = clamp(MathUtil.sanitize(controls.brake), 0, 1)

	-- Snapshot the held set for next frame's edge detection.
	table.clear(state.wasHeld)
	for action, isHeld in held do
		if isHeld then
			state.wasHeld[action] = true
		end
	end

	return controls, systems
end

-- =========================================================================
-- LIVE INPUT
-- =========================================================================

--[[
	Build a snapshot from the real keyboard and mouse.

	The only impure function in the module, and deliberately trivial: it maps
	keys to action names and reads the accumulated mouse delta. Everything that
	could be wrong in an interesting way lives in update(), where it can be
	tested.
]]
function InputController.poll(state: any, mouseDelta: Vector2?): InputSnapshot
	local held = {}
	for action, keyCode in state.bindings do
		if UserInputService:IsKeyDown(keyCode) then
			held[action] = true
		end
	end

	return {
		held = held,
		mouseDelta = mouseDelta or Vector2.zero,
	}
end

-- Rebind one action. The settings menu will drive this.
function InputController.rebind(state: any, action: string, keyCode: Enum.KeyCode)
	assert(InputController.DEFAULT_BINDINGS[action] ~= nil, "[InputController] unknown action: " .. tostring(action))
	state.bindings[action] = keyCode
end

-- =========================================================================
-- VERIFICATION
-- =========================================================================

--[[
	Run from the Studio command bar:
		require(game.StarterPlayer.StarterPlayerScripts.FlightSim.Controls.InputController).runTests()

	Drives update() with synthetic snapshots, so none of this needs a player,
	a keyboard, or a running game.
]]
function InputController.runTests(): (boolean, { any })
	local Cessna172 = require(FlightSim.Aircraft.Definitions.Cessna172)

	local results = {}
	local allPassed = true

	local function record(label: string, passed: boolean, detail: string)
		if not passed then
			allPassed = false
		end
		table.insert(results, { label = label, passed = passed, detail = detail })
		print(string.format("  [%s] %-46s %s", passed and "PASS" or "FAIL", label, detail))
	end

	local function checkRange(label: string, actual: number, lo: number, hi: number, unit: string)
		record(label, actual >= lo and actual <= hi, string.format("%.4f %s (expected %.3f..%.3f)", actual, unit, lo, hi))
	end

	print("=== InputController: verification ===")

	local dt = 1 / 60

	local function snap(actions: { string }?, mouse: Vector2?): InputSnapshot
		local held = {}
		if actions then
			for _, a in actions do
				held[a] = true
			end
		end
		return { held = held, mouseDelta = mouse or Vector2.zero }
	end

	-- Run n frames with a fixed snapshot.
	local function run(state: any, n: number, actions: { string }?, mouse: Vector2?, flight: FlightState?)
		for _ = 1, n do
			InputController.update(state, dt, snap(actions, mouse), flight)
		end
		return state.controls, state.systems
	end

	local function fresh(overrides: { [string]: any }?)
		return InputController.new(Cessna172, overrides)
	end

	-- 1. Contract ----------------------------------------------------------
	local state = fresh()
	local controls = state.controls
	local fields = { "pitch", "roll", "yaw", "throttle", "flaps", "brake" }
	local complete = true
	local extra = 0
	for _, f in fields do
		if type(controls[f]) ~= "number" then
			complete = false
		end
	end
	for k in controls do
		if not table.find(fields, k) then
			extra += 1
		end
	end
	record("Controls has exactly the six physics fields", complete and extra == 0, string.format("%d unexpected field(s)", extra))

	record(
		"Starts neutral",
		controls.pitch == 0 and controls.roll == 0 and controls.yaw == 0
			and controls.throttle == 0 and controls.brake == 0,
		"all zero"
	)

	-- 2. Throttle ----------------------------------------------------------
	state = fresh()
	run(state, 60, { "ThrottleUp" })
	checkRange("W ramps the throttle up over ~1 s", state.controls.throttle, 0.4, 0.6, "")

	run(state, 300, { "ThrottleUp" })
	record("Throttle clamps at 1", state.controls.throttle == 1, string.format("%.4f", state.controls.throttle))

	run(state, 60, { "ThrottleDown" })
	checkRange("S ramps the throttle down", state.controls.throttle, 0.4, 0.6, "")

	run(state, 300, { "ThrottleDown" })
	record("Throttle clamps at 0", state.controls.throttle == 0, string.format("%.4f", state.controls.throttle))

	-- Throttle must hold its setting when nothing is pressed - it is a lever,
	-- not a spring.
	run(state, 60, { "ThrottleUp" })
	local heldThrottle = state.controls.throttle
	run(state, 60, nil)
	record(
		"Throttle holds its setting when released",
		math.abs(state.controls.throttle - heldThrottle) < 1e-9,
		string.format("%.4f", state.controls.throttle)
	)

	-- 3. Rudder ------------------------------------------------------------
	state = fresh()
	run(state, 60, { "YawRight" })
	record("D yaws the nose right (positive)", state.controls.yaw > 0.5, string.format("%+.3f", state.controls.yaw))

	state = fresh()
	run(state, 60, { "YawLeft" })
	record("A yaws the nose left (negative)", state.controls.yaw < -0.5, string.format("%+.3f", state.controls.yaw))

	run(state, 120, nil)
	record("Rudder centres when released", math.abs(state.controls.yaw) < 1e-6, string.format("%+.6f", state.controls.yaw))

	-- Opposite keys together must cancel, not fight.
	state = fresh()
	run(state, 60, { "YawLeft", "YawRight" })
	record("Opposing rudder inputs cancel", math.abs(state.controls.yaw) < 1e-6, string.format("%+.6f", state.controls.yaw))

	-- 4. Flaps -------------------------------------------------------------
	--[[
		The 172 has four detents. F steps down through them; each press must
		move exactly one, no matter how long the key is held.
	]]
	state = fresh()
	record("Flaps start retracted", state.controls.flaps == 0, string.format("%.3f", state.controls.flaps))

	run(state, 120, { "FlapsDown" }) -- one long press
	record("A held F press steps exactly one detent", state.detentIndex == 2, string.format("index %d", state.detentIndex))
	checkRange("One detent is 10 of 30 degrees", state.controls.flaps, 0.32, 0.34, "")

	run(state, 1, nil) -- release
	run(state, 120, { "FlapsDown" })
	run(state, 1, nil)
	run(state, 120, { "FlapsDown" })
	record("F reaches full flap in three presses", state.detentIndex == 4, string.format("index %d", state.detentIndex))
	checkRange("Full flap is 1.0", state.controls.flaps, 0.99, 1.0, "")

	run(state, 1, nil)
	run(state, 120, { "FlapsDown" })
	record("Flaps cannot step past the last detent", state.detentIndex == 4, string.format("index %d", state.detentIndex))

	run(state, 1, nil)
	run(state, 120, { "FlapsUp" })
	record("G steps flaps back up", state.detentIndex == 3, string.format("index %d", state.detentIndex))

	for _ = 1, 6 do
		run(state, 1, nil)
		run(state, 60, { "FlapsUp" })
	end
	record("Flaps cannot step past clean", state.detentIndex == 1, string.format("index %d", state.detentIndex))

	-- Travel is rate limited: one frame after commanding full flap they must
	-- be nowhere near it.
	state = fresh()
	InputController.update(state, dt, snap({ "FlapsDown" }), nil)
	record(
		"Flaps travel takes time, they do not snap",
		state.controls.flaps < 0.05,
		string.format("%.4f after one frame, target %.3f", state.controls.flaps, state.flapsTarget)
	)

	-- 5. Mouse: the inversion ----------------------------------------------
	--[[
		THE sign check. Roblox gives Delta.Y < 0 when the mouse moves forward,
		and forward must pitch the nose DOWN, which is negative pitch.
	]]
	state = fresh()
	run(state, 30, nil, Vector2.new(0, -40))
	record(
		"Pointer forward pitches the nose DOWN",
		state.controls.pitch < -0.1,
		string.format("pitch %+.3f", state.controls.pitch)
	)

	state = fresh()
	run(state, 30, nil, Vector2.new(0, 40))
	record(
		"Pointer back pitches the nose UP",
		state.controls.pitch > 0.1,
		string.format("pitch %+.3f", state.controls.pitch)
	)

	state = fresh()
	run(state, 30, nil, Vector2.new(40, 0))
	record("Pointer right rolls right", state.controls.roll > 0.1, string.format("roll %+.3f", state.controls.roll))

	state = fresh()
	run(state, 30, nil, Vector2.new(-40, 0))
	record("Pointer left rolls left", state.controls.roll < -0.1, string.format("roll %+.3f", state.controls.roll))

	-- Deflection must saturate rather than growing without bound.
	state = fresh()
	run(state, 200, nil, Vector2.new(500, 500))
	record(
		"Stick deflection clamps to full travel",
		state.controls.pitch <= 1 and state.controls.roll <= 1 and state.stickX == 1 and state.stickY == 1,
		string.format("pitch %.3f, roll %.3f", state.controls.pitch, state.controls.roll)
	)

	-- Direct mode holds its deflection; that is the whole point of it.
	local heldPitch = state.controls.pitch
	run(state, 60, nil)
	record(
		"Direct mode holds deflection when the mouse stops",
		math.abs(state.controls.pitch - heldPitch) < 1e-3,
		string.format("%.4f -> %.4f", heldPitch, state.controls.pitch)
	)

	-- Centering mode springs back.
	state = fresh({ mouseMode = "Centering" })
	run(state, 30, nil, Vector2.new(0, 200))
	local deflected = state.controls.pitch
	run(state, 120, nil)
	record(
		"Centering mode returns to neutral",
		math.abs(state.controls.pitch) < math.abs(deflected) * 0.2,
		string.format("%+.3f -> %+.3f", deflected, state.controls.pitch)
	)

	-- X recentres without mouse movement, and kills the smoothing momentum so
	-- the controls settle at neutral instead of coasting through it.
	state = fresh()
	run(state, 30, nil, Vector2.new(200, 200))
	run(state, 1, { "RecenterStick" })
	record("X recentres the stick", state.stickX == 0 and state.stickY == 0, "stick zeroed")
	--[[
		Clearing the smoothing velocity cannot be asserted by reading it back:
		smoothDamp runs later in the same frame and legitimately computes a
		fresh velocity toward neutral. The observable effect is that the
		controls decay to neutral without OVERSHOOTING through it, which is
		what carried-over momentum would cause.
	]]
	local startSign = math.sign(state.controls.pitch)
	local overshot = false
	for _ = 1, 90 do
		InputController.update(state, dt, snap(), nil)
		if startSign ~= 0 and math.sign(state.controls.pitch) == -startSign then
			overshot = true
		end
	end
	record("Recentred controls do not overshoot neutral", not overshot, "never crossed centre")
	record(
		"Controls settle at neutral after recentring",
		math.abs(state.controls.pitch) < 1e-3 and math.abs(state.controls.roll) < 1e-3,
		string.format("pitch %+.5f, roll %+.5f", state.controls.pitch, state.controls.roll)
	)

	-- Trim must survive a recentre: releasing the stick on a trimmed aircraft
	-- holds the trimmed attitude, which is the entire point of trim.
	state = fresh()
	run(state, 120, { "TrimNoseUp" })
	local trimmed = state.trim
	run(state, 1, { "RecenterStick" })
	record(
		"X does not clear trim",
		math.abs(state.trim - trimmed) < 1e-9,
		string.format("trim %+.4f preserved", state.trim)
	)

	-- 6. Expo ---------------------------------------------------------------
	-- A small deflection must produce less than a linear response; full
	-- deflection must still reach full authority.
	state = fresh()
	run(state, 1, nil, Vector2.new(0, 0))
	state.stickY = 0.5
	local shaped = MathUtil.expo(MathUtil.deadzone(0.5, state.config.mouseDeadzone), state.config.mouseExpo)
	record(
		"Expo softens the centre",
		shaped < 0.5,
		string.format("0.500 stick -> %.4f command", shaped)
	)
	local shapedFull = MathUtil.expo(MathUtil.deadzone(1.0, state.config.mouseDeadzone), state.config.mouseExpo)
	checkRange("Full deflection still reaches full authority", shapedFull, 0.99, 1.0, "")

	-- 7. Toggles ------------------------------------------------------------
	state = fresh()
	record("Engine starts off", not state.systems.engineCommanded, "false")

	run(state, 120, { "EngineToggle" }) -- one long press
	record("A held E press toggles the engine once", state.systems.engineCommanded, "true")

	run(state, 1, nil)
	run(state, 120, { "EngineToggle" })
	record("E toggles the engine back off", not state.systems.engineCommanded, "false")

	-- C is momentary, not a toggle.
	state = fresh()
	run(state, 30, { "CameraHold" })
	record("C holds the camera while held", state.systems.cameraHold, "true")
	run(state, 30, nil)
	record("C releases the camera when released", not state.systems.cameraHold, "false")

	-- Gear is a no-op on a fixed-gear aircraft.
	state = fresh()
	run(state, 60, { "GearToggle" })
	record(
		"Gear toggle is inert on fixed gear",
		state.systems.gearDown == true,
		"gearDown stays true"
	)

	-- 8. Brake --------------------------------------------------------------
	state = fresh()
	run(state, 60, { "Brake" })
	record("B applies the brake", state.controls.brake > 0.9, string.format("%.3f", state.controls.brake))
	run(state, 60, nil)
	record("Brake releases", state.controls.brake < 1e-6, string.format("%.6f", state.controls.brake))

	-- 9. Trim ---------------------------------------------------------------
	state = fresh()
	run(state, 120, { "TrimNoseUp" })
	record("Trim biases the pitch command nose-up", state.trim > 0, string.format("trim %+.4f", state.trim))
	record("Trim reaches the controls", state.controls.pitch > 0, string.format("pitch %+.4f", state.controls.pitch))

	run(state, 600, { "TrimNoseUp" })
	checkRange("Trim is limited", state.trim, 0.34, 0.36, "")

	state = fresh()
	run(state, 120, { "TrimNoseDown" })
	record("Trim works nose-down too", state.trim < 0, string.format("trim %+.4f", state.trim))

	-- 10. Altitude hold ------------------------------------------------------
	local level: FlightState = { altitude = 500, verticalSpeed = 0 }

	state = fresh()
	run(state, 1, { "AltitudeHold" }, nil, level)
	record("R engages altitude hold", state.systems.altitudeHold, "engaged")
	checkRange("Engaging captures the current altitude", state.systems.altitudeTargetM, 499, 501, "m")

	run(state, 1, nil, nil, level)
	run(state, 1, { "AltitudeHold" }, nil, level)
	record("R disengages altitude hold", not state.systems.altitudeHold, "disengaged")

	-- The control law itself.
	local cfg = InputController.DEFAULTS
	local below = InputController.altitudeHoldPitch(cfg, 600, 500, 0)
	local above = InputController.altitudeHoldPitch(cfg, 400, 500, 0)
	local onTarget = InputController.altitudeHoldPitch(cfg, 500, 500, 0)
	record("Below target commands nose up", below > 0, string.format("%+.4f", below))
	record("Above target commands nose down", above < 0, string.format("%+.4f", above))
	record("On target commands nothing", math.abs(onTarget) < 1e-9, string.format("%+.9f", onTarget))

	--[[
		The damping check. On target but climbing hard, the law must command
		nose DOWN to arrest the climb - if it did not, it would porpoise.
	]]
	local climbingOnTarget = InputController.altitudeHoldPitch(cfg, 500, 500, 4)
	record(
		"Climbing through the target is arrested",
		climbingOnTarget < 0,
		string.format("%+.4f with +4 m/s climb", climbingOnTarget)
	)

	-- Authority is bounded however far off it is.
	local wayOff = InputController.altitudeHoldPitch(cfg, 5000, 0, 0)
	record(
		"Altitude hold authority is limited",
		math.abs(wayOff) <= cfg.altHold.pitchLimit + 1e-9,
		string.format("%+.4f at 5000 m error", wayOff)
	)

	-- Manual pitch disconnects it, as on a real autopilot.
	state = fresh()
	run(state, 1, { "AltitudeHold" }, nil, level)
	run(state, 30, nil, Vector2.new(0, 300), level)
	record("Manual pitch disconnects altitude hold", not state.systems.altitudeHold, "disconnected")

	--[[
		THE regression this guards against.

		In Direct mode the stick holds wherever it was put, so a pilot flying
		with real pitch deflection - the normal way to hold an attitude without
		trim - would press R and have it engage and disconnect on the same
		frame. The key would simply appear dead.
	]]
	state = fresh()
	run(state, 40, nil, Vector2.new(0, 200), level) -- fly with the stick well back
	local deflectedPitch = state.controls.pitch
	record(
		"Setup: stick is deflected past the disconnect threshold",
		math.abs(deflectedPitch) > InputController.DEFAULTS.altHold.disconnectThreshold,
		string.format("pitch %+.3f", deflectedPitch)
	)

	run(state, 1, { "AltitudeHold" }, nil, level)
	record(
		"R engages with the stick already deflected",
		state.systems.altitudeHold,
		"stayed engaged"
	)

	-- ...and stays engaged while the stick is simply held where it was.
	run(state, 60, nil, nil, level)
	record(
		"Holding the stick still keeps it engaged",
		state.systems.altitudeHold,
		"still engaged"
	)

	-- ...but moving it away from that reference still disconnects.
	run(state, 40, nil, Vector2.new(0, -250), level)
	record(
		"Moving the stick from its reference disconnects",
		not state.systems.altitudeHold,
		"disconnected"
	)

	-- 10b. View cycling ------------------------------------------------------
	state = fresh()
	local seenViews = {}
	for _ = 1, 8 do
		run(state, 1, { "ViewCycle" })
		run(state, 1, nil)
		seenViews[state.systems.viewIndex] = true
	end
	local maxView, viewCount = 0, 0
	for v in seenViews do
		maxView = math.max(maxView, v)
		viewCount += 1
	end
	record(
		"View index wraps instead of growing",
		maxView <= InputController.DEFAULTS.viewCount and viewCount == InputController.DEFAULTS.viewCount,
		string.format("reached %d distinct views, max index %d", viewCount, maxView)
	)
	record(
		"View index stays a valid 1-based index",
		state.systems.viewIndex >= 1 and state.systems.viewIndex <= InputController.DEFAULTS.viewCount,
		string.format("viewIndex = %d", state.systems.viewIndex)
	)

	-- 11. Ranges -------------------------------------------------------------
	--[[
		Whatever is thrown at it, every value must stay inside the contract.
		A control outside its range would reach the aerodynamics as a camber
		shift no aerofoil could produce.
	]]
	state = fresh()
	local everything = {
		"ThrottleUp", "ThrottleDown", "YawLeft", "YawRight", "FlapsDown", "FlapsUp",
		"Brake", "TrimNoseUp", "TrimNoseDown", "EngineToggle", "AltitudeHold", "CameraHold",
	}
	local inRange = true
	for i = 1, 200 do
		local m = Vector2.new(if i % 2 == 0 then 900 else -900, if i % 3 == 0 then 900 else -900)
		local c = InputController.update(state, dt, snap(everything, m), level)
		if c.pitch < -1 or c.pitch > 1 or c.roll < -1 or c.roll > 1 or c.yaw < -1 or c.yaw > 1
			or c.throttle < 0 or c.throttle > 1 or c.flaps < 0 or c.flaps > 1
			or c.brake < 0 or c.brake > 1 then
			inRange = false
		end
		if c.pitch ~= c.pitch or c.roll ~= c.roll then
			inRange = false
		end
	end
	record("All controls stay inside the contract under abuse", inRange, "200 frames of conflicting input")

	-- 12. Timestep ------------------------------------------------------------
	state = fresh()
	InputController.update(state, 10, snap({ "ThrottleUp" }), nil)
	record(
		"A frame hitch cannot slam the throttle",
		state.controls.throttle <= InputController.DEFAULTS.throttleRate * Constants.SIM.MAX_TIMESTEP + 1e-9,
		string.format("%.4f after a 10 s hitch", state.controls.throttle)
	)

	-- 13. Rebinding -----------------------------------------------------------
	state = fresh()
	InputController.rebind(state, "Brake", Enum.KeyCode.V)
	record("Rebinding takes effect", state.bindings.Brake == Enum.KeyCode.V, "Brake -> V")
	record(
		"Rebinding an unknown action is rejected",
		not pcall(InputController.rebind, state, "Nonsense", Enum.KeyCode.Z),
		"errored as expected"
	)

	-- No binding may be claimed by two actions, or one key silently shadows
	-- another and the pilot cannot tell why a control is dead.
	local seen, collision = {}, nil
	for action, key in InputController.DEFAULT_BINDINGS do
		if seen[key] then
			collision = string.format("%s and %s both on %s", action, seen[key], key.Name)
		end
		seen[key] = action
	end
	record("No two actions share a key", collision == nil, collision or "all bindings unique")

	local passCount = 0
	for _, r in results do
		if r.passed then
			passCount += 1
		end
	end
	print(string.format("=== %s (%d/%d) ===", allPassed and "ALL PASSED" or "FAILURES PRESENT", passCount, #results))

	return allPassed, results
end

return InputController
