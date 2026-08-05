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

	--[[
		Straight toggle between the inside and outside views, on T.

		V cycles all three and stays exactly as it was; this is the one a pilot
		actually reaches for in flight, because switching between first and third
		person is a single press rather than a cycle that can land on Free.

		A KEY, not an on-screen button, and that is forced by the control scheme
		rather than chosen for tidiness: the cursor IS the yoke, so a button in a
		corner of the screen could only be clicked by dragging the controls to
		near-full deflection on the way to it. Pressing T costs no cursor movement
		at all, which is what makes it safe to use mid-turn. See also the rule in
		the handoff that nothing in the HUD may be a GuiButton.
	]]
	ViewToggle = Enum.KeyCode.T,

	Pause = Enum.KeyCode.P,

	--[[
		Reset the aircraft. Backspace, specified by the pilot.

		The recovery path from an aeroplane on its back: it asks the server for a
		spawn, and the server treats a request from a player who already has an
		aircraft as "replace it". Until this existed the only way back into the air
		was to die or respawn from the Roblox menu.

		It is listed here so it is rebindable and so the collision test covers it,
		but update() deliberately does NOT consume it. Reset has to work when there
		is no aircraft to reset - and update() only runs while one is being flown.
		FlightController listens for it directly; see the note there.
	]]
	ResetAircraft = Enum.KeyCode.Backspace, -- specified

	--[[
		Show or hide the debug HUD. H, specified by the pilot.

		This is now the pilot-facing control for the raw-numbers panel.
		Constants.DEBUG.SHOW_PHYSICS_OVERLAY still exists and still decides what
		state the HUD STARTS in, but it is a developer default rather than
		something anyone reaches for mid-flight.

		Consumed by UIController off InputBegan, NOT by update(), for the same
		reason as ResetAircraft directly above: update() only runs while an
		aircraft is being flown, and the pilot must be able to set this from the
		apron so the HUD is already in the state they want when they board.
		Two tests assert it stays inert here.
	]]
	ToggleHud = Enum.KeyCode.H, -- specified

	--[[
		X (RecenterStick) and M (MouseModeToggle) were removed when the yoke
		became absolute. Neither could still mean anything: there are no mouse
		modes left, and Roblox exposes no API to warp the cursor, so "recentre
		the stick" would have to lie about where the pointer is. Recentring is
		now what it is in PTFS - move the mouse back to the middle of the screen.
	]]
}

-- =========================================================================
-- TUNING
-- =========================================================================

InputController.DEFAULTS = {
	--[[
		Mouse - absolute, PTFS style.

		The cursor is free on screen and its POSITION is the yoke. Where the
		pointer sits relative to the middle of the screen is the deflection:
		centre is neutral, the edges are full travel, and the pilot can see
		exactly where their controls are because the cursor is drawn there.

		This replaced a relative scheme that accumulated GetMouseDelta() into a
		virtual stick with the cursor locked to centre. Absolute position has no
		sensitivity constant at all - the mapping is fixed by the screen - which
		is why mouseSensitivity and centeringRate are gone rather than retuned.

		Full deflection is reached at the screen EDGE, per axis. On a 16:9
		display that makes roll about 1.8x less sensitive per pixel than pitch.
		That is deliberate and matches PTFS: the horizontal axis is the one the
		hand travels furthest along, and a twitchy roll axis is far more
		unpleasant than a slightly slow one.
	]]
	mouseExpo = 0.35, -- fine control near centre, full authority at the edge
	mouseDeadzone = 0.02, -- a small dead patch at centre so neutral is findable

	throttleRate = 0.5, -- full travel in 2 s
	yawRate = 2.5, -- pedal application
	yawReturnRate = 3.5, -- pedals centre faster than they apply
	brakeRate = 6.0,
	trimRate = 0.08, -- per second held

	-- Time constant for the yoke's "mass". Small: this is control feel, not
	-- aircraft response, and the aircraft's own inertia does the rest.
	controlSmoothTime = 0.06,

	--[[
		How far trim can bias the pitch command.

		0.7, raised from 0.35, and the number is derived rather than felt: the
		aircraft's trim requirement spans -0.43 (65 kt, full flap) to +0.65
		(65 kt, clean) once the tailplane is rigged correctly. Trim that cannot
		cover that range leaves the pilot holding the stick off-centre for the
		whole approach, which is what they reported as being unable to get the
		nose down.

		Trim exists precisely so the yoke can sit neutral in any configuration.
		A limit narrower than the aircraft's own trim requirement is not a safety
		feature, it is a missing control - and this one was less than half of it.
	]]
	trimLimit = 0.7,

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
		--[[
			How fast the demanded climb may be walked, in m/s^2, when capturing.

			Derived, not felt: 1.0 m/s^2 is almost exactly 0.1 g, the vertical
			acceleration a passenger would call a gentle level-off. It rolls a
			full-rate climb off to level in about four seconds. See
			altitudeHoldPitchCaptured for what it fixes.
		]]
		captureAccel = 1.0,
	},

	--[[
		STABILITY AUGMENTATION - the lateral half of the mode on R.

		Measured before any of this was written: with the pitch cascade alone,
		engaging in a climb produced a SPIRAL. The aeroplane rolled off (nothing
		was holding the wings), the bank stole vertical lift, the altitude
		channel pulled harder - and in a bank, pulling tightens the turn rather
		than climbing. Over fifteen seconds the bank went -29.9 to -61.3 degrees
		and the heading swung 209 degrees, with pitch saturated for 723 of 901
		frames. The pitch axis was fighting a problem that lives in roll.

		So the mode holds the wings and the heading, and the altitude channel is
		then asked to do only what it can actually do.

		These are NEW gains. None of the tuned pitch gains are touched.
	]]
	stability = {
		--[[
			Roll rate damping, roll command per rad/s. This is the term that
			stops a roll rather than one that chooses a bank, and it is first
			because a divergence is a rate before it is an angle.
		]]
		rollDamping = 1.6,

		-- Roll command per radian of bank error. 1.2 rolls out of 20 degrees of
		-- unwanted bank with about 0.42 of aileron, which is firm but not a
		-- snatch.
		levelGain = 1.2,

		--[[
			Bank demanded per radian of heading error, and the limit on it.

			25 degrees of heading error asks for the full 20 degrees of bank; a
			light-aircraft autopilot uses 20 to 25 degrees and no more, because
			a steeper turn to correct a heading is how a spiral starts.
		]]
		headingGain = 0.8,
		maxBank = math.rad(20),

		-- Never commands more aileron than this, however lost it is. The same
		-- reasoning as pitchLimit: an augmentation that can hit the stops is a
		-- divergence waiting to happen.
		rollLimit = 0.6,

		--[[
			How far the roll command must be off centre before the pilot is
			judged to be flying the ailerons themselves. Above this the
			augmentation hands the roll axis back completely and the heading
			reference follows the aeroplane. In update() the cursor can no
			longer reach this while the mode is engaged - it is ignored - so
			only the rudder threshold below is live there; this one still
			governs the pure law, which its direct-call tests drive.
		]]
		pilotRollThreshold = 0.06,

		--[[
			Rudder input does the same to the heading reference, and this is the
			pilot's explicit requirement: the mode must never fight the rudder.
			Any rudder at all releases the reference to follow, so a bootful of
			rudder yaws the aeroplane and the mode simply accepts the new
			heading instead of rolling against it.
		]]
		pilotYawThreshold = 0.02,
	},

	-- Cockpit / chase / free, per the camera modes the design calls for.
	-- ViewCycle wraps within this count; the camera system owns the meaning.
	viewCount = 3,

	--[[
		The two views T alternates between: first person and third person.

		Indices, not names, and deliberately so. The camera owns what a viewIndex
		MEANS - this module knows only that there are viewCount of them - so
		hardcoding "1 is the cockpit" in the logic below would point the arrow the
		wrong way, from input to camera. Carrying the pair as CONFIGURATION keeps
		the toggle general: it alternates between two numbers it was handed.

		That the two numbers happen to be Cockpit and Chase is asserted at the
		other end, by CameraController.runTests(), which is where the names live.
		Same assertion-not-dependency arrangement as viewCount above.
	]]
	toggleViews = { 1, 2 },
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
}

--[[
	One frame of input, with nothing read from the engine.

	`pointer` is the cursor in screen pixels and `viewportSize` is the screen it
	is measured against. Both are carried raw rather than pre-normalised so that
	update() owns the whole mapping - centre, deadzone, expo, inversion and
	clamping are the parts that can be wrong in an interesting way, and keeping
	them here is what lets runTests() drive them with plain numbers.

	A viewportSize with a zero component means "no screen", and is treated as
	neutral rather than divided by. That is not just defensive: it is how the
	neutral snapshot below works, and it is what FlightController hands over
	while the pilot is typing.
]]
export type InputSnapshot = {
	held: { [string]: boolean },
	pointer: Vector2,
	viewportSize: Vector2,
}

--[[
	What the stability augmentation mode needs to know about the aeroplane.

	The lateral three arrived with that mode. They are optional: without them
	only the pitch channel augments, which is what the mode did before and is
	still a sane degraded state rather than an error.
]]
export type FlightState = {
	altitude: number, -- m
	verticalSpeed: number, -- m/s
	bankAngle: number?, -- rad, positive = right wing down
	rollRate: number?, -- rad/s about the aircraft's own roll axis
	heading: number?, -- rad, 0 .. 2pi, clockwise from north
}

-- =========================================================================
-- CONSTRUCTION
-- =========================================================================

function InputController.new(definition: any, overrides: { [string]: any }?)
	local config = table.clone(InputController.DEFAULTS)
	-- Both nested tables are cloned, or every InputController in the game would
	-- share one - and a per-player rebind of either would silently rebind
	-- everybody's. table.clone is shallow; this is the whole of what it misses.
	config.altHold = table.clone(InputController.DEFAULTS.altHold)
	config.stability = table.clone(InputController.DEFAULTS.stability)
	config.toggleViews = table.clone(InputController.DEFAULTS.toggleViews)
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

		--[[
			No stick state. The yoke's position is wherever the cursor is, so
			there is nothing to carry between frames - which also means the
			controls can never disagree with what the pilot can see on screen.
		]]
		trim = 0,

		-- smoothDamp carries velocity; the caller owns it.
		pitchVelocity = 0,
		rollVelocity = 0,

		-- Set on engagement, so the demanded climb starts where the aeroplane
		-- already is. nil while altitude hold is off.
		altHoldCapture = nil :: any,
		-- The heading the stability mode steers back to. Set on engagement and
		-- allowed to follow whenever the pilot uses the rudder - the cursor
		-- cannot reach the law while engaged, so only the pedals release it.
		headingReference = nil :: any,

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
-- The outer loop on its own: how fast we want to be climbing, given how far off
-- the target altitude we are.
function InputController.demandedClimbFor(config: any, targetM: number, altitudeM: number): number
	local a = config.altHold
	return clamp((targetM - altitudeM) * a.altitudeGain, -a.maxClimbRate, a.maxClimbRate)
end

--[[
	The cascade with NO capture. Kept because it is the honest description of
	the inner loop and the tests drive it directly, but update() no longer calls
	it - see altitudeHoldPitchCaptured below for why.
]]
function InputController.altitudeHoldPitch(config: any, targetM: number, altitudeM: number, verticalSpeedMs: number): number
	local a = config.altHold
	local climbError = InputController.demandedClimbFor(config, targetM, altitudeM) - verticalSpeedMs
	return clamp(climbError * a.verticalSpeedGain, -a.pitchLimit, a.pitchLimit)
end

--[[
	ALTITUDE CAPTURE, and the reason the autopilot used to bang.

	Engaging sets the target to the CURRENT altitude, so the outer loop's error
	is zero and it demands zero climb - instantly, however fast the aeroplane
	happens to be going up. Measured: at the 172's own Vy rate of climb of
	+3.98 m/s the cascade commands -0.450 on the first frame, which is the full
	nose-down limit, and it saturates for any climb above 2.50 m/s (492 ft/min).
	A normal climb is 783 ft/min, so engaging in the climb ALWAYS slammed the
	nose down.

	The fix is what a real autopilot does on capture: the demanded climb STARTS
	at whatever the aeroplane is already doing and is walked toward zero, so the
	inner loop sees no step at all. Engagement is now a no-op on the first frame
	by construction - demanded climb equals actual climb, so the climb error is
	zero and the commanded pitch is zero.

	None of the tuned gains are touched. The one new number is the rate at which
	the demand is walked, and it is derived rather than felt: 1.0 m/s^2 is
	almost exactly 0.1 g, which is the vertical acceleration a passenger would
	call a gentle level-off. It takes about four seconds to roll a full-rate
	climb off to level.
]]
export type AltHoldCapture = { demandedClimb: number }

--[[
	NOT clamped to maxClimbRate, and that was a bug in the first version of this
	fix - caught by its own test.

	`maxClimbRate` limits what the OUTER loop may ask for from altitude error. It
	is not a statement about what the aeroplane is currently doing. Clamping the
	capture to it reintroduced the exact step this exists to remove, precisely
	when the step was largest: entering at 12 m/s captured at 5, leaving a 7 m/s
	error on the first frame and commanding the full nose-down limit again.

	The demand is walked down toward the outer loop's (clamped) value anyway, so
	starting above the limit is transient by construction.
]]
function InputController.altHoldCapture(config: any, verticalSpeedMs: number): AltHoldCapture
	return { demandedClimb = verticalSpeedMs }
end

function InputController.altitudeHoldPitchCaptured(
	config: any,
	capture: AltHoldCapture,
	targetM: number,
	altitudeM: number,
	verticalSpeedMs: number,
	dt: number
): (number, AltHoldCapture)
	local a = config.altHold

	local wanted = InputController.demandedClimbFor(config, targetM, altitudeM)

	--[[
		Walk the demand toward what the outer loop wants, instead of jumping to
		it. This is the whole fix: the inner loop only ever sees a demand that
		moves at a survivable rate, so it cannot be handed a step it can only
		answer by saturating.
	]]
	local step = a.captureAccel * math.max(dt, 0)
	local demanded = capture.demandedClimb + clamp(wanted - capture.demandedClimb, -step, step)

	local pitch = clamp((demanded - verticalSpeedMs) * a.verticalSpeedGain, -a.pitchLimit, a.pitchLimit)
	return pitch, { demandedClimb = demanded }
end

--[[
	THE LATERAL HALF OF THE STABILITY AUGMENTATION MODE.

	Returns the roll command to fly, and the heading reference to carry into the
	next frame. Pure, so the whole law can be driven from the test suite with
	plain numbers.

	Three things, in order of authority:

	  1. RATE DAMPING. Opposes whatever roll rate exists. A spiral is a rate
	     before it is an angle, so this is the term that actually stops one.
	  2. WINGS LEVEL. Rolls out any bank the pilot did not ask for.
	  3. HEADING. Banks - gently, and never past maxBank - to steer back to the
	     reference heading.

	AND IT GETS OUT OF THE WAY. If the pilot is rolling with the cursor, or
	using ANY rudder, the augmentation returns their own roll command untouched
	and the heading reference follows the aeroplane. That is the pilot's
	requirement stated exactly: the mode must not fight the rudder, and letting
	go must not snap the heading back to where it was engaged.

	`controls.yaw` is never read here and never written anywhere in this mode.
	The rudder is the pilot's alone.
]]
function InputController.stabilityRoll(
	config: any,
	headingReference: number?,
	bankAngle: number?,
	rollRate: number?,
	heading: number?,
	pilotRoll: number,
	pilotYaw: number
): (number, number?)
	local s = config.stability

	-- Nothing to work with: hand the pilot's own command straight back.
	if bankAngle == nil or rollRate == nil then
		return pilotRoll, headingReference
	end

	--[[
		The pilot is flying. Hand the axis back and let the reference follow, so
		that whatever heading they roll or kick the aeroplane onto becomes the
		one it then holds.
	]]
	if abs(pilotRoll) > s.pilotRollThreshold or abs(pilotYaw) > s.pilotYawThreshold then
		return pilotRoll, heading
	end

	local reference = headingReference or heading

	--[[
		Steer toward the reference by demanding a bank, bounded hard. The error
		is wrapped to the shortest way round, or turning from 350 to 010 would
		be commanded the long way - 340 degrees of turn to correct 20.
	]]
	local demandedBank = 0
	if reference and heading then
		-- angleDelta(from, to) is to - from, so this is "how far right must I
		-- turn to reach the reference". Reversed, it steers away from it.
		demandedBank = clamp(MathUtil.angleDelta(heading, reference) * s.headingGain, -s.maxBank, s.maxBank)
	end

	local command = (demandedBank - bankAngle) * s.levelGain - rollRate * s.rollDamping

	return clamp(command, -s.rollLimit, s.rollLimit), reference
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
	if rising(state, snapshot, "ViewToggle") then
		--[[
			T alternates between the two views in config.toggleViews - first
			person and third person - leaving V to cycle all of them.

			Note the asymmetry, which is deliberate. Only the FIRST view maps to
			the second; everything else maps back to the first. So from a view the
			toggle does not own - Free, or anything a later aircraft adds - T
			lands on the inside view rather than doing nothing, and a second press
			takes you outside. A strict two-way swap would leave the key dead in
			exactly the situation a pilot presses it hardest.
		]]
		local inside, outside = config.toggleViews[1], config.toggleViews[2]
		systems.viewIndex = if systems.viewIndex == inside then outside else inside
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
		The pointer's POSITION on screen is the yoke.

		Offset from the middle of the screen, normalised per axis so that the
		left and right edges are full roll and the top and bottom edges are full
		pitch. Everything in between is proportional, so the cursor is a direct
		readout of where the controls are.

		INVERTED, as specified and as every flight sim does it: pointer forward
		(up the screen) pitches the nose DOWN.

		The signs need no negation anywhere, which is worth stating because it
		looks like an omission. Screen Y grows DOWNWARD, so a pointer pushed
		forward sits above centre and yields a negative offset, and pitch is
		positive nose-up - the inversion is already in the coordinate system.
		Roll needs no help either: screen X grows right, and positive roll is
		right. Both directions are asserted separately in runTests(), because
		this is still the likeliest thing in the file to be wrong.
	]]
	local pointerX, pointerY = 0, 0
	local viewport = snapshot.viewportSize

	if viewport and viewport.X > 0 and viewport.Y > 0 then
		local pointer = snapshot.pointer or Vector2.zero
		local halfWidth = viewport.X * 0.5
		local halfHeight = viewport.Y * 0.5

		-- Clamped, so a cursor dragged off the edge of the window - or onto a
		-- second monitor - holds full deflection instead of running away.
		pointerX = clamp((pointer.X - halfWidth) / halfWidth, -1, 1)
		pointerY = clamp((pointer.Y - halfHeight) / halfHeight, -1, 1)
	end

	-- Deadzone removes jitter near centre; expo gives fine control there while
	-- keeping full deflection reachable at the edges.
	local rawRoll = MathUtil.expo(MathUtil.deadzone(pointerX, config.mouseDeadzone), config.mouseExpo)
	local rawPitch = MathUtil.expo(MathUtil.deadzone(pointerY, config.mouseDeadzone), config.mouseExpo)

	-- ---- Altitude hold ---------------------------------------------------
	if rising(state, snapshot, "AltitudeHold") and flightState then
		systems.altitudeHold = not systems.altitudeHold
		if systems.altitudeHold then
			-- Capture the altitude at the moment of engagement, which is what
			-- the pilot means by "hold this".
			systems.altitudeTargetM = flightState.altitude
			--[[
				Capture the CLIMB, which is what stops the bang. The demand
				starts at whatever the aeroplane is already doing, so the inner
				loop sees no step on the first frame. See
				altitudeHoldPitchCaptured.
			]]
			state.altHoldCapture = InputController.altHoldCapture(config, flightState.verticalSpeed)

			-- And the heading to hold, which is simply the one being flown.
			state.headingReference = flightState.heading
		end
	end

	--[[
		THE CURSOR IS IGNORED WHILE THE MODE IS ENGAGED. The cursor is the
		yoke, and letting its position reach the law was part of the hunting
		measured in altitude hold: the lateral law handed the roll axis back to
		any cursor deflection past pilotRollThreshold, so a cursor held even
		slightly off centre kept the autopilot fighting it - and a pitch move
		past the old disconnect threshold dropped the mode out entirely.
		Engaged, the autopilot now has unopposed authority. Only R turns it
		off, and then the cursor is the yoke again. The rudder is NOT ignored:
		controls.yaw still reaches the aeroplane and still releases the heading
		reference to follow.
	]]
	if systems.altitudeHold then
		rawPitch = 0
		rawRoll = 0
	end

	local commandedPitch: number
	if systems.altitudeHold and flightState then
		local autopilot: number
		autopilot, state.altHoldCapture = InputController.altitudeHoldPitchCaptured(
			config,
			state.altHoldCapture,
			systems.altitudeTargetM,
			flightState.altitude,
			flightState.verticalSpeed,
			dt
		)

		--[[
			The autopilot commands the elevator directly, and trim is NOT added.

			That is deliberate and was tested rather than assumed. Adding the
			pilot's trim on top looked obviously right - a real servo flies an
			already-trimmed aeroplane and only supplies the deviation - and it
			measured clearly WORSE: the aircraft climbed away to 17.8 m of error
			and rising, with the autopilot driving to -0.33 to fight a trim it
			no longer needed. With the throttle where a climb left it the
			aeroplane accelerates once levelled, so the deflection that trimmed
			it at 74 kt is far too much at 90, and adding it double-counts.

			The hypothesis came from a measurement taken with the ENGINE NOT
			STARTED - see the handoff. A glider does need +0.48 at 70 kt; this
			aeroplane, under power, does not.
		]]
		commandedPitch = clamp(autopilot, -1, 1)
	else
		commandedPitch = clamp(rawPitch + state.trim, -1, 1)
	end

	-- ---- Smoothing -------------------------------------------------------
	-- The yoke has mass. Applied last so it smooths whatever produced the
	-- command, including an altitude-hold handover.
	--[[
		The lateral half of the stability mode.

		Measured cause: without it, engaging in a climb rolled off into a spiral
		and the PITCH axis saturated trying to fix it - because in a bank,
		pulling tightens the turn instead of climbing. Holding the wings is what
		lets the altitude channel work at all.

		`controls.yaw` is deliberately untouched here and everywhere else in
		this mode. The rudder belongs to the pilot; the augmentation only reads
		it, to know when to get out of the way.
	]]
	local commandedRoll = rawRoll
	if systems.altitudeHold and flightState then
		commandedRoll, state.headingReference = InputController.stabilityRoll(
			config,
			state.headingReference,
			flightState.bankAngle,
			flightState.rollRate,
			flightState.heading,
			rawRoll,
			controls.yaw
		)
	end

	controls.pitch, state.pitchVelocity =
		MathUtil.smoothDamp(controls.pitch, commandedPitch, state.pitchVelocity, config.controlSmoothTime, dt)
	controls.roll, state.rollVelocity =
		MathUtil.smoothDamp(controls.roll, commandedRoll, state.rollVelocity, config.controlSmoothTime, dt)

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
	keys to action names and passes the cursor through untouched. Everything
	that could be wrong in an interesting way lives in update(), where it can be
	tested.

	The caller supplies the pointer and the viewport rather than this reading
	them, because the two must come from the same coordinate space and only the
	caller knows which - see the note on the GUI inset in FlightController.
]]
function InputController.poll(state: any, pointer: Vector2?, viewportSize: Vector2?): InputSnapshot
	local held = {}
	for action, keyCode in state.bindings do
		if UserInputService:IsKeyDown(keyCode) then
			held[action] = true
		end
	end

	return {
		held = held,
		pointer = pointer or Vector2.zero,
		viewportSize = viewportSize or Vector2.zero,
	}
end

--[[
	A snapshot with no keys held and the yoke at neutral.

	Exists so that callers wanting "hands off the controls" - FlightController
	while the pilot is typing - do not have to know that a zero viewport is the
	convention for it. Trim is untouched, exactly as letting go of a real yoke
	leaves a trimmed aircraft holding its attitude.
]]
function InputController.neutralSnapshot(): InputSnapshot
	return {
		held = {},
		pointer = Vector2.zero,
		viewportSize = Vector2.zero,
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

	-- A synthetic 16:9 screen. Deliberately not square, so that the tests can
	-- tell per-axis normalisation from a single shared radius.
	local VIEWPORT = Vector2.new(1920, 1080)

	--[[
		A cursor position expressed as a fraction of the way from the middle of
		the screen to the edge, per axis.

		pointer(0, 0) is dead centre, pointer(1, 1) the bottom-right corner,
		pointer(0, -1) the top edge. Writing the tests in these units rather
		than pixels keeps them readable and independent of VIEWPORT.
	]]
	local function pointer(fx: number, fy: number): Vector2
		return Vector2.new(VIEWPORT.X * 0.5 * (1 + fx), VIEWPORT.Y * 0.5 * (1 + fy))
	end

	--[[
		Note the default: a snapshot with no pointer given is the cursor at
		CENTRE, not at Vector2.zero. Zero is the top-left corner, which under
		absolute control is full nose-down and full left roll - so defaulting to
		it would silently deflect every test that does not mention the mouse.
	]]
	local function snap(actions: { string }?, pointerPos: Vector2?): InputSnapshot
		local held = {}
		if actions then
			for _, a in actions do
				held[a] = true
			end
		end
		return { held = held, pointer = pointerPos or pointer(0, 0), viewportSize = VIEWPORT }
	end

	-- Run n frames with a fixed snapshot. The pointer is re-sent every frame,
	-- because holding the yoke still now means holding the cursor still.
	local function run(state: any, n: number, actions: { string }?, pointerPos: Vector2?, flight: FlightState?)
		for _ = 1, n do
			InputController.update(state, dt, snap(actions, pointerPos), flight)
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

	-- 5. Mouse: the absolute yoke -------------------------------------------
	--[[
		THE sign check, and the likeliest thing in this file to be wrong.

		Screen Y grows DOWNWARD, so a pointer pushed forward sits ABOVE centre
		and must pitch the nose DOWN. Both directions are asserted separately
		rather than inferred from one, because a sign error that inverts the
		whole axis passes any single-direction test.
	]]
	state = fresh()
	run(state, 30, nil, pointer(0, -1))
	record(
		"Pointer forward pitches the nose DOWN",
		state.controls.pitch < -0.1,
		string.format("pitch %+.3f at the top edge", state.controls.pitch)
	)

	state = fresh()
	run(state, 30, nil, pointer(0, 1))
	record(
		"Pointer back pitches the nose UP",
		state.controls.pitch > 0.1,
		string.format("pitch %+.3f at the bottom edge", state.controls.pitch)
	)

	state = fresh()
	run(state, 30, nil, pointer(1, 0))
	record("Pointer right rolls right", state.controls.roll > 0.1, string.format("roll %+.3f", state.controls.roll))

	state = fresh()
	run(state, 30, nil, pointer(-1, 0))
	record("Pointer left rolls left", state.controls.roll < -0.1, string.format("roll %+.3f", state.controls.roll))

	--[[
		Centre is neutral, and returning to centre neutralises. This pair is the
		whole reason for the free cursor: the pilot can see where the controls
		are and put them back by moving the mouse, with no key press and no
		hidden state that could disagree with the cursor on screen.
	]]
	state = fresh()
	run(state, 60, nil, pointer(0, 0))
	record(
		"Cursor at screen centre is neutral",
		math.abs(state.controls.pitch) < 1e-6 and math.abs(state.controls.roll) < 1e-6,
		string.format("pitch %+.6f, roll %+.6f", state.controls.pitch, state.controls.roll)
	)

	state = fresh()
	run(state, 30, nil, pointer(0.9, 0.9))
	local deflected = state.controls.pitch
	run(state, 90, nil, pointer(0, 0))
	record(
		"Returning the cursor to centre releases the controls",
		math.abs(state.controls.pitch) < 1e-3 and math.abs(state.controls.roll) < 1e-3,
		string.format("pitch %+.3f -> %+.5f", deflected, state.controls.pitch)
	)

	-- Proportional in between: half way to the edge is a real fraction of full
	-- authority, not all of it and not none.
	state = fresh()
	run(state, 60, nil, pointer(0, 0.5))
	local halfway = state.controls.pitch
	state = fresh()
	run(state, 60, nil, pointer(0, 1))
	local fullTravel = state.controls.pitch
	record(
		"Deflection is proportional to distance from centre",
		halfway > 0.05 and halfway < fullTravel * 0.95,
		string.format("half %.3f vs full %.3f", halfway, fullTravel)
	)

	-- Beyond the edge - dragged off-window or onto a second monitor - must
	-- clamp at full travel rather than running away.
	state = fresh()
	run(state, 90, nil, Vector2.new(VIEWPORT.X * 6, VIEWPORT.Y * 6))
	record(
		"Cursor beyond the screen edge clamps at full travel",
		state.controls.pitch <= 1 and state.controls.roll <= 1
			and state.controls.pitch > 0.98 and state.controls.roll > 0.98,
		string.format("pitch %.4f, roll %.4f", state.controls.pitch, state.controls.roll)
	)

	--[[
		Per-axis normalisation, asserted with the SAME pixel offset on both axes.

		On this 16:9 screen 270 px is half the way to the top edge but only 28%
		of the way to the side, so the identical hand movement must produce less
		roll than pitch. If the axes were ever collapsed onto one shared radius
		this is the test that would notice.
	]]
	state = fresh()
	local equalOffset = 270
	run(state, 60, nil, Vector2.new(VIEWPORT.X * 0.5 + equalOffset, VIEWPORT.Y * 0.5 + equalOffset))
	record(
		"Axes normalise independently, so roll is the wider axis",
		state.controls.roll < state.controls.pitch,
		string.format("%d px gives roll %.3f but pitch %.3f", equalOffset, state.controls.roll, state.controls.pitch)
	)

	-- Inside the deadzone, the yoke is exactly neutral rather than nearly so.
	state = fresh()
	run(state, 60, nil, pointer(0.01, 0.01))
	record(
		"Offsets inside the deadzone are exactly neutral",
		state.controls.pitch == 0 and state.controls.roll == 0,
		string.format("pitch %+.6f, roll %+.6f", state.controls.pitch, state.controls.roll)
	)

	--[[
		Hands off the yoke. FlightController sends this while a text box is
		focused, because with a free cursor the pilot moving the mouse to the
		chat box would otherwise command hard nose-up and full left roll.
	]]
	state = fresh()
	run(state, 30, nil, pointer(0.9, 0.9))
	for _ = 1, 90 do
		InputController.update(state, dt, InputController.neutralSnapshot(), nil)
	end
	record(
		"A neutral snapshot releases the yoke",
		math.abs(state.controls.pitch) < 1e-3 and math.abs(state.controls.roll) < 1e-3,
		string.format("pitch %+.5f, roll %+.5f", state.controls.pitch, state.controls.roll)
	)

	-- ...but must not undo the trim. Letting go of a trimmed aircraft's yoke
	-- holds the trimmed attitude; that is the entire point of trim.
	state = fresh()
	run(state, 120, { "TrimNoseUp" })
	local trimmed = state.trim
	for _ = 1, 30 do
		InputController.update(state, dt, InputController.neutralSnapshot(), nil)
	end
	record(
		"Releasing the yoke does not clear trim",
		math.abs(state.trim - trimmed) < 1e-9,
		string.format("trim %+.4f preserved", state.trim)
	)

	-- 6. Expo ---------------------------------------------------------------
	-- A small deflection must produce less than a linear response; full
	-- deflection must still reach full authority.
	local shaped = MathUtil.expo(MathUtil.deadzone(0.5, InputController.DEFAULTS.mouseDeadzone), InputController.DEFAULTS.mouseExpo)
	record(
		"Expo softens the centre",
		shaped < 0.5,
		string.format("0.500 offset -> %.4f command", shaped)
	)
	local shapedFull = MathUtil.expo(MathUtil.deadzone(1.0, InputController.DEFAULTS.mouseDeadzone), InputController.DEFAULTS.mouseExpo)
	checkRange("Full deflection still reaches full authority", shapedFull, 0.99, 1.0, "")

	-- And the shaping is what actually reaches the controls, which ties the
	-- cursor position to the commanded deflection end to end.
	state = fresh()
	run(state, 90, nil, pointer(0, 0.5))
	checkRange("Half-screen offset commands the shaped value", state.controls.pitch, shaped - 0.02, shaped + 0.02, "")

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

	-- Long enough to reach the stop at trimRate, whatever the limit is set to.
	run(state, math.ceil(InputController.DEFAULTS.trimLimit / InputController.DEFAULTS.trimRate * 60) + 120, { "TrimNoseUp" })
	local limit = InputController.DEFAULTS.trimLimit
	checkRange("Trim is limited", state.trim, limit - 0.01, limit + 0.01, "")

	--[[
		Trim must be able to cover the aircraft's ACTUAL trim requirement, or the
		pilot flies the whole approach holding the stick off-centre - which is
		precisely what was reported. Measured span with the tailplane rigged
		correctly: -0.43 at 65 kt with full flap, +0.65 at 65 kt clean.
	]]
	record(
		"Trim range covers the aircraft's trim requirement",
		limit >= 0.65,
		string.format("+/-%.2f against a requirement of -0.43..+0.65", limit)
	)

	state = fresh()
	run(state, 120, { "TrimNoseDown" })
	record("Trim works nose-down too", state.trim < 0, string.format("trim %+.4f", state.trim))

	-- 9b. Altitude capture ----------------------------------------------------
	--[[
		THE BUG THIS FIXES, pinned as a number.

		Engaging sets the target to the current altitude, so the outer loop's
		error is zero and it demands zero climb - instantly, however fast the
		aeroplane is going up. The uncaptured cascade therefore commands full
		nose-down the moment it is engaged in any climb worth the name.
	]]
	local cfgCap = fresh().config
	local vyClimb = 3.98 -- m/s, the 172's own measured Vy rate of climb
	record(
		"Without capture, engaging in a Vy climb slams full nose-down",
		math.abs(InputController.altitudeHoldPitch(cfgCap, 500, 500, vyClimb) + cfgCap.altHold.pitchLimit) < 1e-9,
		string.format("%.3f at %+.2f m/s, which is the limit",
			InputController.altitudeHoldPitch(cfgCap, 500, 500, vyClimb), vyClimb)
	)
	record(
		"...and saturates for any climb above 2.5 m/s",
		math.abs(InputController.altitudeHoldPitch(cfgCap, 500, 500, 2.6)) >= cfgCap.altHold.pitchLimit - 1e-9
			and math.abs(InputController.altitudeHoldPitch(cfgCap, 500, 500, 2.4)) < cfgCap.altHold.pitchLimit,
		string.format("threshold is pitchLimit/verticalSpeedGain = %.2f m/s (%.0f ft/min)",
			cfgCap.altHold.pitchLimit / cfgCap.altHold.verticalSpeedGain,
			cfgCap.altHold.pitchLimit / cfgCap.altHold.verticalSpeedGain * 196.85)
	)

	--[[
		THE FIX: the demand starts where the aeroplane already is, so the inner
		loop sees no step and the first frame commands nothing at all. This is
		true for ANY entry rate, which is the property that matters.
	]]
	local worstFirstFrame = 0
	for _, vs in { -5, -3.98, -1, 0, 1, 3.98, 5, 12 } do
		local cap = InputController.altHoldCapture(cfgCap, vs)
		local pitch = InputController.altitudeHoldPitchCaptured(cfgCap, cap, 500, 500, vs, 1 / 60)
		worstFirstFrame = math.max(worstFirstFrame, math.abs(pitch))
	end
	record(
		"With capture, engagement commands nothing on the first frame",
		worstFirstFrame < 0.02,
		string.format("worst first-frame command %.4f across -5..+12 m/s entries", worstFirstFrame)
	)

	--[[
		An entry faster than maxClimbRate is captured at its TRUE rate, not at
		the limit - and the first version of this fix got that wrong. Clamping
		to maxClimbRate put back the very step capture removes, exactly when it
		was biggest: 12 m/s captured at 5 leaves a 7 m/s error on frame one and
		commands the full nose-down limit again. The walk brings it back inside
		the limit regardless, so starting outside is transient.
	]]
	local fastCap = InputController.altHoldCapture(cfgCap, 12)
	record(
		"A fast entry is captured at its true rate, not clipped to the limit",
		math.abs(fastCap.demandedClimb - 12) < 1e-9,
		string.format("%.2f m/s captured from a 12 m/s entry, above the %.1f m/s demand limit",
			fastCap.demandedClimb, cfgCap.altHold.maxClimbRate)
	)

	--[[
		The demand is WALKED, not stepped, and at the declared rate. This is what
		turns a step the inner loop can only answer by saturating into a ramp it
		can follow.
	]]
	local walk = InputController.altHoldCapture(cfgCap, 5)
	local _, walked = InputController.altitudeHoldPitchCaptured(cfgCap, walk, 500, 500, 5, 1)
	record(
		"The demanded climb walks at captureAccel, not instantly",
		math.abs((walk.demandedClimb - walked.demandedClimb) - cfgCap.altHold.captureAccel) < 1e-9,
		string.format("%.2f m/s in one second, captureAccel is %.2f m/s^2",
			walk.demandedClimb - walked.demandedClimb, cfgCap.altHold.captureAccel)
	)
	--[[
		And it converges: given long enough on target, the demand must reach what
		the outer loop actually wants, or the autopilot would hold a permanent
		climb.
	]]
	local conv = InputController.altHoldCapture(cfgCap, 5)
	for _ = 1, 600 do
		local _, next = InputController.altitudeHoldPitchCaptured(cfgCap, conv, 500, 500, 0, 1 / 60)
		conv = next
	end
	record(
		"The demand converges on what the outer loop wants",
		math.abs(conv.demandedClimb) < 1e-6,
		string.format("%.6f m/s after 10 s on target", conv.demandedClimb)
	)

	--[[
		Capture must not blunt the response once it is established. Far below the
		target with the demand settled, the autopilot should still be asking for
		everything the outer loop allows.
	]]
	local settled = { demandedClimb = cfgCap.altHold.maxClimbRate }
	local strong = InputController.altitudeHoldPitchCaptured(cfgCap, settled, 5000, 0, 0, 1 / 60)
	record(
		"A settled capture still commands full authority when far off",
		strong >= cfgCap.altHold.pitchLimit - 1e-9,
		string.format("%.3f, 5000 m below target", strong)
	)

	-- 9c. Stability augmentation, the lateral half -----------------------------
	--[[
		WHAT THIS FIXES, measured before it was written: with the pitch cascade
		alone, engaging in a climb produced a SPIRAL. Nothing held the wings, so
		the aeroplane rolled off; the bank stole vertical lift; the altitude
		channel pulled harder; and in a bank, pulling tightens the turn instead
		of climbing. Bank went -29.9 to -61.3 degrees, heading swung 209
		degrees, and pitch was saturated for 723 of 901 frames. The pitch axis
		was fighting a problem that lives in roll.
	]]
	local sCfg = fresh().config
	local sMax = sCfg.stability.maxBank

	--[[
		THE PILOT'S EXPLICIT REQUIREMENT: the mode must never fight the rudder.
		Any rudder at all hands the roll axis back and lets the heading
		reference follow, so a bootful of rudder yaws the aeroplane and the mode
		accepts the new heading rather than rolling against it.
	]]
	local ruddered, refAfterRudder = InputController.stabilityRoll(
		sCfg, math.rad(90), math.rad(15), 0.3, math.rad(120), 0, 1.0)
	record(
		"Rudder input hands the roll axis straight back to the pilot",
		ruddered == 0,
		string.format("roll command %.4f with full rudder and 15 deg of bank", ruddered)
	)
	record(
		"...and the heading reference FOLLOWS rather than snapping back",
		refAfterRudder ~= nil and math.abs((refAfterRudder :: number) - math.rad(120)) < 1e-9,
		string.format("reference moved to the flown heading %.0f, not the engaged %.0f",
			math.deg(refAfterRudder or 0), 90)
	)

	local rolled, refAfterRoll = InputController.stabilityRoll(
		sCfg, math.rad(90), math.rad(15), 0.3, math.rad(120), 0.5, 0)
	record(
		"Cursor roll input is passed through untouched",
		rolled == 0.5,
		string.format("%.3f in, %.3f out", 0.5, rolled)
	)
	record(
		"...and the reference follows the pilot's roll too",
		refAfterRoll ~= nil and math.abs((refAfterRoll :: number) - math.rad(120)) < 1e-9,
		"letting go does not snap the heading back"
	)

	--[[
		Hands-off, the three terms. Wings level first, because uncommanded bank
		is the pilot's stated complaint.
	]]
	local levelling = InputController.stabilityRoll(sCfg, nil, math.rad(20), 0, nil, 0, 0)
	record(
		"Unwanted right bank commands left aileron to level the wings",
		levelling < -0.1,
		string.format("%.3f at 20 deg of bank", levelling)
	)
	local levellingLeft = InputController.stabilityRoll(sCfg, nil, math.rad(-20), 0, nil, 0, 0)
	record(
		"...and left bank commands right, symmetrically",
		math.abs(levellingLeft + levelling) < 1e-9,
		string.format("%+.3f against %+.3f", levellingLeft, levelling)
	)
	--[[
		Rate damping is the term that actually stops a divergence, because a
		spiral is a rate before it is an angle. Rolling right with the wings
		already level must still command left.
	]]
	local damping = InputController.stabilityRoll(sCfg, nil, 0, 0.5, nil, 0, 0)
	record(
		"A roll RATE is opposed even with the wings level",
		damping < -0.1,
		string.format("%.3f at 0.5 rad/s of roll rate", damping)
	)

	--[[
		Heading hold demands a bank, and never more than maxBank - a steeper
		turn to correct a heading is how a spiral starts.
	]]
	--[[
		90 degrees off, not 180. At exactly 180 the shortest way round is
		genuinely ambiguous - angleDelta returns -pi as legitimately as +pi -
		so the first version of this check asserted a turn direction that has
		no correct answer, and failed on correct code.
	]]
	local farOff = InputController.stabilityRoll(sCfg, math.rad(90), 0, 0, math.rad(0), 0, 0)
	record(
		"A large heading error still never demands more than maxBank",
		farOff > 0 and farOff <= sMax * sCfg.stability.levelGain + 1e-9,
		string.format("%.3f commanded for 90 deg off, maxBank is %.0f deg", farOff, math.deg(sMax))
	)
	--[[
		And it turns the SHORT way round. Steering from 350 to 010 must go
		right through north, not 340 degrees the other way - which is what an
		unwrapped error would do.
	]]
	local wrapped = InputController.stabilityRoll(sCfg, math.rad(10), 0, 0, math.rad(350), 0, 0)
	record(
		"Heading hold turns the short way across north",
		wrapped > 0,
		string.format("%.3f - positive is right, toward 010 from 350", wrapped)
	)

	record(
		"Roll command is bounded by rollLimit",
		math.abs(InputController.stabilityRoll(sCfg, math.rad(180), math.rad(80), 3, 0, 0, 0))
			<= sCfg.stability.rollLimit + 1e-9,
		string.format("limit %.2f", sCfg.stability.rollLimit)
	)
	--[[
		Without lateral state the mode degrades to what it was before rather
		than erroring - a flightState from an older caller is a sane no-op.
	]]
	record(
		"With no lateral state the pilot's roll passes through unchanged",
		InputController.stabilityRoll(sCfg, nil, nil, nil, nil, 0.42, 0) == 0.42,
		"degrades to hands-off rather than failing"
	)

	--[[
		THE RUDDER MUST REACH THE AEROPLANE. Driven through the whole of
		update() rather than the law alone, because the requirement is about
		what the aircraft receives, not what one function returns.
	]]
	local sState = fresh()
	local lateral: FlightState = {
		altitude = 500, verticalSpeed = 0,
		bankAngle = math.rad(10), rollRate = 0, heading = math.rad(90),
	}
	run(sState, 1, { "AltitudeHold" }, nil, lateral)
	local withRudder = nil
	for _ = 1, 60 do
		withRudder = InputController.update(sState, dt, snap({ "YawRight" }), lateral)
	end
	record(
		"Engaged, the rudder still reaches the aeroplane",
		(withRudder :: any).yaw > 0.5,
		string.format("yaw %.3f after a second of right rudder while engaged", (withRudder :: any).yaw)
	)
	record(
		"...and the mode stops commanding roll while the rudder is in",
		math.abs((withRudder :: any).roll) < 0.05,
		string.format("roll %.4f", (withRudder :: any).roll)
	)
	record(
		"Engaging captures the heading being flown",
		sState.headingReference ~= nil,
		string.format("reference %.0f deg", math.deg(sState.headingReference or 0))
	)

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

	--[[
		WHILE ENGAGED THE CURSOR IS IGNORED, and that is the whole point of the
		mode. The cursor is the yoke, and its position reaching the law was
		measured to be part of the hunting reported in altitude hold: the
		lateral law handed the roll axis back to any cursor deflection past
		pilotRollThreshold, and a pitch move past the old disconnect threshold
		dropped the mode out. Engaged, the autopilot has unopposed authority.

		This is the OPPOSITE of the old behaviour, so the assertion is written
		against what the cursor would have commanded: full deflection used to
		drive pitch to ~1 and roll to ~1 through the "pilot is flying" handoff.
		Now the autopilot commands zero (on target, wings level) and stays at
		zero however the cursor moves.
	]]
	state = fresh()
	run(state, 1, { "AltitudeHold" }, nil, level)
	run(state, 60, nil, pointer(1, 1), level)
	record(
		"The cursor cannot fight the autopilot while engaged",
		math.abs(state.controls.pitch) < 0.05 and math.abs(state.controls.roll) < 0.05,
		string.format("pitch %+.4f, roll %+.4f with the cursor in the corner",
			state.controls.pitch, state.controls.roll)
	)
	record(
		"...and the mode stays engaged however the cursor moves",
		state.systems.altitudeHold,
		"still engaged"
	)

	-- R returns the aircraft to the pilot, and the cursor is the yoke again.
	run(state, 1, { "AltitudeHold" }, nil, level)
	record(
		"R disengages, returning control to the cursor",
		not state.systems.altitudeHold,
		"disengaged"
	)
	run(state, 60, nil, pointer(0, 1), level)
	record(
		"After disengaging the cursor commands the aircraft again",
		state.controls.pitch > 0.1,
		string.format("pitch %+.3f at full deflection", state.controls.pitch)
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

	-- 10c. View toggle (T) ---------------------------------------------------
	local INSIDE = InputController.DEFAULTS.toggleViews[1]
	local OUTSIDE = InputController.DEFAULTS.toggleViews[2]

	record(
		"The toggle pair are two distinct valid views",
		INSIDE ~= OUTSIDE
			and INSIDE >= 1 and INSIDE <= InputController.DEFAULTS.viewCount
			and OUTSIDE >= 1 and OUTSIDE <= InputController.DEFAULTS.viewCount,
		string.format("toggles %d <-> %d of %d", INSIDE, OUTSIDE, InputController.DEFAULTS.viewCount)
	)

	state = fresh()
	record("Starts in the inside view", state.systems.viewIndex == INSIDE, string.format("viewIndex %d", state.systems.viewIndex))

	-- One LONG press, which is the edge-trigger check: without it T would strobe
	-- between the two views at frame rate and the camera would be unusable.
	run(state, 120, { "ViewToggle" })
	record(
		"A held T press switches to third person exactly once",
		state.systems.viewIndex == OUTSIDE,
		string.format("viewIndex %d after 120 frames held", state.systems.viewIndex)
	)

	run(state, 1, nil)
	run(state, 120, { "ViewToggle" })
	record(
		"T switches back to first person",
		state.systems.viewIndex == INSIDE,
		string.format("viewIndex %d", state.systems.viewIndex)
	)

	--[[
		From a view the toggle does not own, T must still do something useful.

		Cycle with V onto Free, then press T: it has to land on the inside view
		rather than sitting inert. This is the asymmetry in update() and it is the
		case a pilot hits hardest - lost in the orbit camera, wanting the cockpit
		back now.
	]]
	state = fresh()
	while state.systems.viewIndex == INSIDE or state.systems.viewIndex == OUTSIDE do
		run(state, 1, { "ViewCycle" })
		run(state, 1, nil)
	end
	local strayView = state.systems.viewIndex
	run(state, 1, { "ViewToggle" })
	run(state, 1, nil)
	record(
		"T from a view it does not own returns to first person",
		state.systems.viewIndex == INSIDE,
		string.format("view %d -> %d", strayView, state.systems.viewIndex)
	)
	run(state, 1, { "ViewToggle" })
	run(state, 1, nil)
	record(
		"...and a second press then goes to third person",
		state.systems.viewIndex == OUTSIDE,
		string.format("viewIndex %d", state.systems.viewIndex)
	)

	-- T and V share one number, so V must still behave after T has set it.
	state = fresh()
	run(state, 1, { "ViewToggle" })
	run(state, 1, nil)
	local afterToggle = state.systems.viewIndex
	run(state, 1, { "ViewCycle" })
	run(state, 1, nil)
	record(
		"V still cycles normally after T has set the view",
		state.systems.viewIndex == (afterToggle % InputController.DEFAULTS.viewCount) + 1,
		string.format("%d -> %d", afterToggle, state.systems.viewIndex)
	)

	-- Whatever the two are driven with, the result must stay indexable - the
	-- camera indexes straight into its view list with no bounds check of its own.
	state = fresh()
	local viewInRange = true
	for i = 1, 200 do
		run(state, 1, if i % 3 == 0 then { "ViewToggle" } elseif i % 5 == 0 then { "ViewCycle" } else nil)
		run(state, 1, nil)
		local v = state.systems.viewIndex
		if v < 1 or v > InputController.DEFAULTS.viewCount or v ~= math.floor(v) then
			viewInRange = false
		end
	end
	record(
		"T and V interleaved always leave an indexable view",
		viewInRange,
		string.format("200 mixed presses, ended on %d", state.systems.viewIndex)
	)

	-- Per-instance config, or a rebind on one player would move everybody's.
	local a, b = fresh(), fresh()
	a.config.toggleViews[1] = 99
	record(
		"toggleViews is cloned per instance, not shared",
		b.config.toggleViews[1] == INSIDE and InputController.DEFAULTS.toggleViews[1] == INSIDE,
		string.format("other instance still %d, defaults still %d", b.config.toggleViews[1], InputController.DEFAULTS.toggleViews[1])
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
		-- The cursor teleporting corner to corner and far off-screen every
		-- frame, which is both the worst case and what an alt-tab looks like.
		local m = Vector2.new(
			if i % 2 == 0 then VIEWPORT.X * 9 else -VIEWPORT.X * 9,
			if i % 3 == 0 then VIEWPORT.Y * 9 else -VIEWPORT.Y * 9
		)
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

	-- 14. Reset ---------------------------------------------------------------
	record(
		"Backspace is bound to ResetAircraft",
		InputController.DEFAULT_BINDINGS.ResetAircraft == Enum.KeyCode.Backspace,
		tostring(InputController.DEFAULT_BINDINGS.ResetAircraft)
	)

	--[[
		Reset is deliberately inert HERE. FlightController owns it, because it has
		to work with no aircraft in existence and update() only runs while one is
		being flown. This asserts the key cannot quietly acquire a second meaning:
		holding it must not move a single control or flip a single system flag.
	]]
	state = fresh()
	run(state, 120, { "ResetAircraft" })
	local resetControls, resetSystems = state.controls, state.systems
	record(
		"Holding reset moves no control",
		resetControls.pitch == 0 and resetControls.roll == 0 and resetControls.yaw == 0
			and resetControls.throttle == 0 and resetControls.brake == 0 and resetControls.flaps == 0,
		string.format("pitch %+.3f, throttle %.3f, brake %.3f", resetControls.pitch, resetControls.throttle, resetControls.brake)
	)
	record(
		"Holding reset flips no system",
		not resetSystems.engineCommanded and not resetSystems.paused
			and not resetSystems.altitudeHold and resetSystems.viewIndex == 1,
		string.format("viewIndex %d, engine %s", resetSystems.viewIndex, tostring(resetSystems.engineCommanded))
	)

	-- poll() walks the bindings table, so it reports the key as held. That is
	-- harmless but worth pinning down: it is how a rebound reset key stays
	-- discoverable, and it must not have been dropped from the snapshot.
	state = fresh()
	record(
		"poll() knows about the reset binding",
		state.bindings.ResetAircraft == Enum.KeyCode.Backspace,
		"present in the per-player binding table"
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

return InputController
