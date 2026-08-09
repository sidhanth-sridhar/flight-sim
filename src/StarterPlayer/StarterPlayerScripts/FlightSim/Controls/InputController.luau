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

	--[[
		Pitch trim. Genuinely useful once the aircraft is stable enough to fly
		hands-off, and U/J are well clear of the left-hand cluster.

		⚠️ NOSE-DOWN IS J, NOT H. H is `ToggleHud`, which the pilot specified
		(section 19), so a trim key there silently shadowed it - two actions on
		one key means the pilot cannot tell why a control is dead. U and J are a
		vertical pair on the keyboard, up above down, which is what the trim
		wheel does.
	]]
	TrimNoseDown = Enum.KeyCode.J,
	TrimNoseUp = Enum.KeyCode.U,

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
		Open or close the flight tablet (Phase 4b). M, for map.

		M IS FREE BECAUSE THE ABSOLUTE YOKE FREED IT - it used to be
		MouseModeToggle, and the note below records why that action no longer
		exists. It is also a long way from the left-hand flight cluster, which
		matters for a key that hands the controls over: a fat-fingered W or A is
		a nudge, a fat-fingered tablet key is the pilot letting go of the yoke.

		Consumed by TabletController off InputBegan, NOT by update(), and this is
		the third action in that arrangement after ResetAircraft and ToggleHud.
		The reason is the same one every time: update() only runs while an
		aircraft is being flown, and the whole point of this key is that a pilot
		can plan a flight standing on the apron with no aeroplane at all. Two
		tests assert it stays inert here.
	]]
	ToggleTablet = Enum.KeyCode.M,

	--[[
		=====================================================================
		PHASE 4c - THE 172S SYSTEMS
		=====================================================================

		⚠️ TWENTY-TWO NEW KEYS, AND THAT IS WHY THE BINDS REFERENCE EXISTS.
		Nineteen bindings were memorable; forty-one are not, and a control the
		pilot cannot find is a control that is not there. `BindsPanel` renders
		this table - not a copy of it - on K.

		EVERY ONE OF THESE IS A KEY, NOT A CLICKABLE SWITCH, and that is the
		2026-08-06 decision recorded in §14: the cursor is the yoke, so a
		clickable knob mid-flight IS the flight controls by construction. The
		tablet earned its modal state because a picker cannot be a key (§46); a
		switch can, so it is one.

		The 3D parts these drive are already modelled and inert (Phase 4 item 4).
		This phase gives them state; the parts mirror it.
	]]

	--[[
		Rudder trim, on the comma and full stop - a left/right pair that sits
		under the right hand, well away from the flight cluster. Same shape as
		the U/J pitch trim pair: two keys, held, moving a wheel.
	]]
	RudderTrimLeft = Enum.KeyCode.Comma,
	RudderTrimRight = Enum.KeyCode.Period,

	--[[
		Mixture. Q richer, Z leaner - vertically arranged on the keyboard the
		way the knob moves, and both clear of everything else.

		⚠️ Z IS THE KEY THAT CAN STOP THE ENGINE, because pulling the mixture to
		idle cutoff is how a 172 is shut down. That is correct and is the whole
		point of modelling the control; it is called out here because "my engine
		died and I do not know why" is the support question it will generate.
	]]
	MixtureRich = Enum.KeyCode.Q,
	MixtureLean = Enum.KeyCode.Z,

	--[[
		The fuel selector, stepped through OFF-LEFT-BOTH-RIGHT on the bracket
		keys. It CLAMPS at each end rather than wrapping (see
		Engine.stepFuelSelector) so that one press too many can never shut the
		fuel off.
	]]
	FuelSelectorDown = Enum.KeyCode.LeftBracket,
	FuelSelectorUp = Enum.KeyCode.RightBracket,

	--[[
		The ignition, stepped OFF-R-L-BOTH on minus and equals. The mag CHECK is
		what these are for: at 1,800 rpm, step down to L, read the drop, back to
		BOTH, down to R, read the drop.
	]]
	MagnetosDown = Enum.KeyCode.Minus,
	MagnetosUp = Enum.KeyCode.Equals,

	--[[
		The starter, HELD rather than pressed, because the real key is
		spring-loaded out of START. Y is under the right hand near the mag keys.
	]]
	StarterEngage = Enum.KeyCode.Y,

	-- The electrical masters. 1/2/3 in the order the checklist works them:
	-- battery, then alternator, then avionics.
	BatteryMaster = Enum.KeyCode.One,
	AlternatorMaster = Enum.KeyCode.Two,
	AvionicsMaster = Enum.KeyCode.Three,
	BreakerReset = Enum.KeyCode.Four,

	-- The lights, 5 through 9, in the order the panel switches run.
	LightBeacon = Enum.KeyCode.Five,
	LightNav = Enum.KeyCode.Six,
	LightStrobe = Enum.KeyCode.Seven,
	LightTaxi = Enum.KeyCode.Eight,
	LightLanding = Enum.KeyCode.Nine,

	-- Cabin environment: heat, vent, defrost.
	CabinHeat = Enum.KeyCode.I,
	CabinVent = Enum.KeyCode.O,
	CabinDefrost = Enum.KeyCode.Zero,

	-- Pitot heat, which is electrical load rather than cabin comfort but lives
	-- with the other environmental switches on the real panel.
	PitotHeat = Enum.KeyCode.Backquote,

	--[[
		The binds reference itself, on K for Keys.

		⚠️ READ OFF InputBegan BY ITS OWN PANEL, not by update(), and this is now
		the fourth action wired that way after ResetAircraft, ToggleHud and
		ToggleTablet. The reason is the same one every time - update() only runs
		while an aircraft is being flown, and a pilot who cannot remember a key
		needs the list on the apron more than anywhere else.
	]]
	ToggleBinds = Enum.KeyCode.K,

	--[[
		X (RecenterStick) and M (MouseModeToggle) were removed when the yoke
		became absolute. Neither could still mean anything: there are no mouse
		modes left, and Roblox exposes no API to warp the cursor, so "recentre
		the stick" would have to lie about where the pointer is. Recentring is
		now what it is in PTFS - move the mouse back to the middle of the screen.

		M has since been reclaimed by the tablet, directly above. X is still free.
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

	--[[
		Phase 4c rates, both per second held.

		Rudder trim is slower than pitch trim because it is used less and needs
		less precision - it takes the foot pressure out of a climb and is then
		left alone, where pitch trim is adjusted continuously through an
		approach.

		The mixture is faster than either, because its travel is a knob the
		pilot pulls in one movement rather than a wheel they wind.
	]]
	rudderTrimRate = 0.05,
	rudderTrimLimit = 1.0,
	mixtureRate = 0.35,

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

		--[[
			GAIN SCHEDULING - the fix for the porpoise, and the reason it only
			ever showed up fast.

			verticalSpeedGain converts a vertical-speed error into an ELEVATOR
			DEFLECTION. But a deflection is not a pitching moment: the moment it
			makes is proportional to dynamic pressure, so the same command is
			roughly twice as powerful at 130 kt as at 90. The loop gain
			therefore rises with the square of airspeed, and somewhere above 110
			kt it passes the point where the loop is stable and settles into a
			limit cycle instead.

			Measured, engaging with a target below and letting the aeroplane
			accelerate into the descent: calm at 94 to 111 kt with the elevator
			inside 0.16, then at 115 to 116 kt the command swung -0.359 to
			+0.083, reached the 0.45 stop, and the load factor ranged -0.16 to
			2.28 g. A recorded flight showed exactly the same split - quiet at
			83 to 104 kt, a 1.2 s limit cycle at 112 to 118 kt with the elevator
			saturated.

			So the gain is divided by dynamic pressure, normalised to the speed
			where it was tuned. Indicated airspeed is exactly the right variable
			to schedule on, because it already carries the air density: the
			same IAS means the same q, at any altitude.
		]]
		-- The speed verticalSpeedGain is correct at, in m/s. 48 m/s is about
		-- 93 kt - the middle of the measured calm band.
		refAirspeed = 48.0,
		--[[
			The schedule only ever ATTENUATES. The ceiling is 1.0, so below the
			reference speed the law is exactly the unscheduled one.

			That is a measured decision, not caution for its own sake. The
			unscheduled gain was steady everywhere from 69 to 111 kt; the only
			place it misbehaved was fast. An earlier version let the scale rise
			to 2.0, which boosted the gain 1.6x in a 74 kt Vy climb and started
			its own oscillation - 20 vertical-speed crossings in a minute with
			the elevator at 0.448 and the load factor ranging 0.55 to 1.44 g.
			Amplifying where nothing was wrong only created a second porpoise.

			The floor stops the autopilot going deaf in a dive. 0.35 is reached
			at about 158 kt, just under this aeroplane's Vne.
		]]
		minGainScale = 0.35,
		maxGainScale = 1.0,

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
	--[[
		M. Written by TabletController through FlightController, not by update().

		It is an INPUT to this module rather than an output, which makes it the
		odd one out in this table and is worth stating plainly. Everything else
		here is a decision update() made; this one is a decision made outside and
		reported in, because the tablet has to work with no aircraft at all (see
		the binding note) and update() only runs while one is being flown.

		What update() does with it is exactly what it does with altitudeHold: the
		cursor stops being the yoke. See the ignore block down in update().
	]]
	tabletOpen: boolean,

	--[[
		=====================================================================
		PHASE 4c - THE 172S SYSTEMS
		=====================================================================

		⚠️ ALL OF IT IS HERE, AND NONE OF IT IS IN Controls. That is §6c's
		contract and §14's constraint stated as code: FlightModel and
		GroundHandling consume exactly six fields, and adding a seventh for the
		mixture or the fuel valve would break a contract that three suites pin
		down. These are SYSTEMS - things the aeroplane is doing - and the
		physics reads them through the modules that own them (Engine,
		Electrical), never through the control contract.
	]]

	-- Rudder trim, -1..1, positive trims the nose right. The lateral twin of
	-- `state.trim`, which is pitch and which lives outside systems for
	-- historical reasons this deliberately does not copy.
	rudderTrim: number,

	-- Engine.FuelSelector / Engine.Magnetos, carried as plain strings so this
	-- module keeps no dependency on the physics.
	fuelSelector: string,
	magnetos: string,
	starterEngaged: boolean, -- true only while the key is held
	mixture: number, -- 0 = idle cutoff, 1 = full rich

	batteryMaster: boolean,
	alternatorMaster: boolean,
	avionicsMaster: boolean,
	breakerReset: boolean, -- edge, consumed by FlightController

	lights: {
		beacon: boolean,
		nav: boolean,
		strobe: boolean,
		taxi: boolean,
		landing: boolean,
	},

	pitotHeat: boolean,
	cabinHeat: boolean,
	cabinVent: boolean,
	cabinDefrost: boolean,
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
	airspeed: number?, -- m/s indicated, for the altitude loop's gain schedule
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
			tabletOpen = false,

			--[[
				Phase 4c. The aeroplane is handed over in the configuration the
				POH says to take off in - BOTH, full rich, both magnetos,
				masters on - so every caller that predates this phase gets an
				aeroplane that behaves exactly as it did.
			]]
			rudderTrim = 0,
			fuelSelector = "BOTH",
			magnetos = "BOTH",
			starterEngaged = false,
			mixture = 1,

			batteryMaster = true,
			alternatorMaster = true,
			avionicsMaster = true,
			breakerReset = false,

			-- All lights off. The beacon is the pilot's to switch on with 5,
			-- like every other light.
			lights = {
				beacon = false,
				nav = false,
				strobe = false,
				taxi = false,
				landing = false,
			},

			pitotHeat = false,
			cabinHeat = false,
			cabinVent = false,
			cabinDefrost = false,
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
	dt: number,
	-- Indicated airspeed in m/s. Optional: without it the loop is unscheduled,
	-- which is the behaviour that predated the porpoise fix.
	airspeedMs: number?
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

	--[[
		NO DERIVATIVE TERM, and that is a measured decision rather than an
		omission. Two attempts were made and both made the aeroplane worse:

		  1. Raw one-frame vertical acceleration. Differencing a noisy velocity
		     at frame rate banged the elevator, and the measurement lag flipped
		     the phase so the "damping" reinforced the oscillation.
		  2. A low-pass-filtered derivative on the vertical-speed error, gain
		     0.1, clamped to 0.2. Measured against the real aerodynamics with
		     the model's OWN pitch inertia, this turned a dead-steady autopilot
		     into a violent porpoise: load factor went from 0.97..1.04 to
		     0.10..1.90, peak elevator from 0.022 to the 0.45 limit, with a
		     1.2 s limit cycle that did not decay.

		The reason is the same both times. Every derivative here is taken on a
		signal that already lags the elevator by the time it takes the nose to
		move and the wing to respond - and at this aircraft's pitch inertia
		that lag is most of a second. A term meant to oppose the motion arrives
		pointing the same way as it.

		The proportional law below, with the capture walk above it, measures
		steady across the whole envelope: load factor within 0.68..1.27 from
		80 kt to 130 kt, in a Vy climb and in an idle descent.
	]]
	--[[
		Scheduled on dynamic pressure. See refAirspeed for the measurement that
		forced this: the loop is stable at 95 kt and a limit cycle at 116 kt on
		the SAME gain, because the elevator is half again as powerful there.

		Without an airspeed the scale is 1, which is the unscheduled law - so a
		caller that does not supply one degrades to the old behaviour rather
		than failing.
	]]
	local scale = 1
	if airspeedMs and airspeedMs > 1 then
		local ratio = a.refAirspeed / airspeedMs
		scale = clamp(ratio * ratio, a.minGainScale, a.maxGainScale)
	end

	local pitch = clamp(
		(demanded - verticalSpeedMs) * a.verticalSpeedGain * scale,
		-a.pitchLimit,
		a.pitchLimit
	)
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
-- THE TABLET GATE (Phase 4b)
-- =========================================================================

--[[
	MAY THE TABLET BE OPEN RIGHT NOW? The pilot's decision, as one function.

	The problem, stated once: the cursor IS the yoke (§6g), so anything the
	pilot has to click can only be reached by dragging the controls most of the
	way to their stops on the journey there. §7 puts it as a flat rule - an
	on-screen button cannot be a flight control in this game - and the switches
	dodged it entirely by being keys (§14, Phase 4c). A picker cannot: no key
	chooses among airports.

	⚠️ DECIDED BY THE PILOT (2026-08-09), and it is neither of the two options
	§14 wrote down. Not "modal, releases the yoke anywhere", and not "ground
	only". It is:

	    ON THE GROUND, or with ALTITUDE HOLD ENGAGED.

	And the second half is the good bit, because it costs nothing at all. §28
	already established that while the mode on R is engaged THE CURSOR IS NOT
	READ AS THE YOKE - update() zeroes it - and the augmentation holds the
	wings, the heading and the altitude. So in that state the pilot's hands are
	already off the controls by construction, and a clickable tablet takes
	nothing away from them. There is no new modal state, no new hand-off, and
	nothing to tune: the only mode in this project that flies the aeroplane for
	you is exactly the mode in which a cursor is free to be a cursor.

	On the ground the argument is simpler still - a parked aeroplane does not
	care where the elevator is - and it covers planning a flight before boarding,
	which is what the tablet is mostly for.

	Anywhere else, hand-flying, it refuses. That is the whole safety property:
	nothing clickable can ever appear on screen while the cursor is the yoke.

	Pure, and it takes three plain booleans rather than a rig, so every corner of
	it is driven from runTests() without an aeroplane.
]]
function InputController.tabletMayOpen(flying: boolean, onGround: boolean, altitudeHold: boolean): boolean
	--[[
		Not flying means not seated in a working aeroplane - standing on the
		apron, or walking to one, or having just bent one. The pilot is on their
		feet and there is no yoke to take away.
	]]
	if not flying then
		return true
	end

	return onGround or altitudeHold
end

-- =========================================================================
-- UPDATE
-- =========================================================================

local function rising(state: any, snapshot: InputSnapshot, action: string): boolean
	return snapshot.held[action] == true and state.wasHeld[action] ~= true
end

--[[
	The ORDER the fuel selector and the ignition step through (Phase 4c).

	⚠️ THESE ARE THE SEQUENCE, NOT THE MEANING, and the duplication against
	Engine.FUEL_SELECTOR_POSITIONS is deliberate rather than sloppy. This module
	is the input layer and must not require the physics - it is loaded on a
	client that may have no aircraft at all. So it carries which position comes
	next; Engine carries what each one DOES. `runTests` asserts the two lists
	are identical, so they cannot drift.
]]
local FUEL_SELECTOR_ORDER = { "OFF", "LEFT", "BOTH", "RIGHT" }
local MAGNETO_ORDER = { "OFF", "R", "L", "BOTH" }

--[[
	Step through a list of positions, CLAMPED at both ends.

	Clamped rather than wrapped because these are a valve and a key with stops.
	A fuel selector that wrapped from OFF round to RIGHT would let a pilot shut
	the fuel off by pressing the same key one time too many, which is the exact
	failure the physical detent exists to prevent.

	Pure and exported, so the stepping is asserted without a keyboard.
]]
function InputController.stepPosition(list: { string }, current: string, delta: number): string
	local index = table.find(list, current) or 1
	return list[clamp(index + delta, 1, #list)]
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

	-- ---- Phase 4c systems -------------------------------------------------
	--[[
		Every switch here is EDGE-TRIGGERED, for the reason stated above the
		block this sits in: without it, holding a key for a fifth of a second
		would strobe the switch at frame rate. The two knobs (mixture, rudder
		trim) are the exception and ramp while held, because they have travel
		rather than positions.
	]]
	if rising(state, snapshot, "BatteryMaster") then
		systems.batteryMaster = not systems.batteryMaster
	end
	if rising(state, snapshot, "AlternatorMaster") then
		systems.alternatorMaster = not systems.alternatorMaster
	end
	if rising(state, snapshot, "AvionicsMaster") then
		systems.avionicsMaster = not systems.avionicsMaster
	end

	--[[
		The breaker reset is an EDGE REPORTED ONWARD, not a state. It is set
		true for exactly the frame the key goes down and cleared here on every
		other frame, so FlightController can act on it once without having to
		do its own edge detection against a boolean that never changes.
	]]
	systems.breakerReset = rising(state, snapshot, "BreakerReset")

	if rising(state, snapshot, "LightBeacon") then
		systems.lights.beacon = not systems.lights.beacon
	end
	if rising(state, snapshot, "LightNav") then
		systems.lights.nav = not systems.lights.nav
	end
	if rising(state, snapshot, "LightStrobe") then
		systems.lights.strobe = not systems.lights.strobe
	end
	if rising(state, snapshot, "LightTaxi") then
		systems.lights.taxi = not systems.lights.taxi
	end
	if rising(state, snapshot, "LightLanding") then
		systems.lights.landing = not systems.lights.landing
	end

	if rising(state, snapshot, "PitotHeat") then
		systems.pitotHeat = not systems.pitotHeat
	end
	if rising(state, snapshot, "CabinHeat") then
		systems.cabinHeat = not systems.cabinHeat
	end
	if rising(state, snapshot, "CabinVent") then
		systems.cabinVent = not systems.cabinVent
	end
	if rising(state, snapshot, "CabinDefrost") then
		systems.cabinDefrost = not systems.cabinDefrost
	end

	--[[
		The fuel selector and the ignition step through their positions. Both
		CLAMP at the ends rather than wrapping - Engine owns that rule and the
		reason for it, and this layer only reports which way the pilot turned.

		The lists are duplicated here as the ORDER, not as the meaning: this
		module must not require the physics, so it carries the sequence and
		Engine carries what each position does. A test asserts the two agree.
	]]
	if rising(state, snapshot, "FuelSelectorUp") then
		systems.fuelSelector = InputController.stepPosition(FUEL_SELECTOR_ORDER, systems.fuelSelector, 1)
	end
	if rising(state, snapshot, "FuelSelectorDown") then
		systems.fuelSelector = InputController.stepPosition(FUEL_SELECTOR_ORDER, systems.fuelSelector, -1)
	end
	if rising(state, snapshot, "MagnetosUp") then
		systems.magnetos = InputController.stepPosition(MAGNETO_ORDER, systems.magnetos, 1)
	end
	if rising(state, snapshot, "MagnetosDown") then
		systems.magnetos = InputController.stepPosition(MAGNETO_ORDER, systems.magnetos, -1)
	end

	--[[
		The starter is MOMENTARY, like the camera hold and unlike everything
		else here, because the real key is spring-loaded out of START. A pilot
		who lets go mid-crank gets a crank that stops, which is the behaviour.
	]]
	systems.starterEngaged = held.StarterEngage == true

	-- ---- The two knobs, which ramp while held -----------------------------
	if held.MixtureRich then
		systems.mixture = clamp(systems.mixture + config.mixtureRate * dt, 0, 1)
	end
	if held.MixtureLean then
		systems.mixture = clamp(systems.mixture - config.mixtureRate * dt, 0, 1)
	end

	if held.RudderTrimRight then
		systems.rudderTrim += config.rudderTrimRate * dt
	end
	if held.RudderTrimLeft then
		systems.rudderTrim -= config.rudderTrimRate * dt
	end
	systems.rudderTrim = clamp(systems.rudderTrim, -config.rudderTrimLimit, config.rudderTrimLimit)

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
	--[[
		AND THE TABLET IGNORES IT FOR THE SAME REASON (Phase 4b).

		While the tablet is open the cursor is being used to click buttons, so
		reading its position as the yoke would mean picking a destination in the
		top-right corner commanded full nose-down and full right roll on the way
		there - which is §7's rule about on-screen buttons, arriving from the
		inside.

		Belt AND braces, deliberately: FlightController also sends
		neutralSnapshot() while the tablet is open, which zeroes the keys as
		well. Either alone would hold the yoke; this one is here because it is
		the half that can be ASSERTED as a pure function of state, and the state
		this protects against is the pilot dragging the cursor across the screen.

		Trim is untouched, exactly as it is while typing, so a trimmed aeroplane
		holds its attitude with the tablet up.
	]]
	if systems.altitudeHold or systems.tabletOpen then
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
			dt,
			flightState.airspeed
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

	--[[
		THE INNER LOOP IS PROPORTIONAL, AND STAYS THAT WAY.

		Two derivative terms have been tried on this loop and both made the
		aeroplane worse - a raw one-frame vertical acceleration, and a
		low-pass-filtered derivative on the vertical-speed error. The second
		was measured against the real aerodynamics using the model's OWN pitch
		inertia and turned a dead-steady autopilot into a 1.2 s limit cycle
		swinging the load factor from 0.10 to 1.90 g.

		The cause is structural: any derivative here is taken on a signal that
		already lags the elevator by the time it takes the nose to move and the
		wing to answer, so the term arrives in phase with the motion instead of
		against it.

		This check pins the law's SHAPE rather than a number: for the same
		state, the command must be exactly the proportional term. If a
		derivative is ever added again it will fail here, and whoever adds it
		can read the note above before deciding to.
	]]
	local shapeCfg = fresh().config
	local shapeMismatch = {}
	for _, vs in { -4, -1, 0, 1, 4 } do
		local cap = { demandedClimb = 0 }
		local got = InputController.altitudeHoldPitchCaptured(shapeCfg, cap, 500, 500, vs, 1 / 60)
		local expected = clamp((0 - vs) * shapeCfg.altHold.verticalSpeedGain, -shapeCfg.altHold.pitchLimit, shapeCfg.altHold.pitchLimit)
		if math.abs(got - expected) > 1e-12 then
			table.insert(shapeMismatch, string.format("%+.1f m/s: %.4f vs %.4f", vs, got, expected))
		end
	end
	record(
		"The inner loop is exactly proportional - no derivative term",
		#shapeMismatch == 0,
		if #shapeMismatch == 0 then "command is (demand - VS) * verticalSpeedGain, clamped"
		else table.concat(shapeMismatch, ", ")
	)
	--[[
		And the capture carries nothing but the demand. A derivative needs
		history, so an empty capture is the structural guarantee that there
		isn't one.
	]]
	local carried = select(2, InputController.altitudeHoldPitchCaptured(shapeCfg, { demandedClimb = 0 }, 500, 500, 2, 1 / 60))
	local extra = {}
	for key in carried do
		if key ~= "demandedClimb" then
			table.insert(extra, key)
		end
	end
	record(
		"The capture carries no derivative history",
		#extra == 0,
		if #extra == 0 then "demandedClimb only" else "unexpected: " .. table.concat(extra, ", ")
	)

	--[[
		THE GAIN SCHEDULE - the actual porpoise fix.

		verticalSpeedGain turns a vertical-speed error into an ELEVATOR
		DEFLECTION, but the moment that deflection makes scales with dynamic
		pressure. So the loop gain climbs with the square of airspeed, and above
		about 110 kt it passes the point of stability. Measured on the real
		aerodynamics with the model's own pitch inertia: calm from 94 to 111 kt
		with the elevator inside 0.16, then at 115 to 116 kt the command swung
		-0.359 to +0.083, hit the 0.45 stop, and the load factor ranged -0.16 to
		2.28 g. A recorded flight split the same way - quiet at 83 to 104 kt, a
		1.2 s limit cycle at 112 to 118 kt.
	]]
	local schedCfg = fresh().config
	local sa = schedCfg.altHold
	local fast = InputController.altitudeHoldPitchCaptured(schedCfg, { demandedClimb = 0 }, 500, 500, 2, 1 / 60, 60)
	local atRef = InputController.altitudeHoldPitchCaptured(schedCfg, { demandedClimb = 0 }, 500, 500, 2, 1 / 60, sa.refAirspeed)
	record(
		"Fast, the loop is quieter than at the reference speed",
		math.abs(fast) < math.abs(atRef),
		string.format("%.4f at 60 m/s against %.4f at the %.0f m/s reference", fast, atRef, sa.refAirspeed)
	)
	record(
		"At the reference speed the schedule changes nothing",
		math.abs(atRef - (-2 * sa.verticalSpeedGain)) < 1e-12,
		string.format("%.4f, exactly the unscheduled law", atRef)
	)
	--[[
		The scale is q, so it goes as the SQUARE of the ratio. At twice the
		reference speed the gain must be a quarter, not a half - which is the
		whole reason a linear guess would not have fixed this.
	]]
	--[[
		Checked at 1.5x the reference and not 2x: twice the reference is 187 kt,
		past this aeroplane's Vne, where minGainScale legitimately takes over.
		The first version of this check asserted the square law at a speed the
		Cessna cannot reach, and failed on correct code.
	]]
	local fastRatio = 1.5
	local scaled = InputController.altitudeHoldPitchCaptured(
		schedCfg, { demandedClimb = 0 }, 500, 500, 0.5, 1 / 60, sa.refAirspeed * fastRatio)
	local expected = -0.5 * sa.verticalSpeedGain / (fastRatio * fastRatio)
	record(
		"The schedule follows dynamic pressure, not speed",
		math.abs(scaled - expected) < 1e-12,
		string.format("%.5f at 1.5x the reference, against %.5f for an inverse SQUARE", scaled, expected)
	)
	--[[
		BELOW THE REFERENCE THE SCHEDULE DOES NOTHING, and that is the point.
		Letting it amplify at low speed started a second oscillation in a Vy
		climb - see maxGainScale. Slow flight gets exactly the law that was
		already measured steady there.
	]]
	local slow = InputController.altitudeHoldPitchCaptured(
		schedCfg, { demandedClimb = 0 }, 500, 500, 0.5, 1 / 60, sa.refAirspeed * 0.8)
	record(
		"Slow, the schedule attenuates nothing - it never amplifies",
		math.abs(slow - (-0.5 * sa.verticalSpeedGain)) < 1e-12,
		string.format("%.5f, exactly the unscheduled command", slow)
	)
	--[[
		A 1 m/s error, not 5. Five would command 0.9 and be cut to the pitch
		limit before the schedule was visible at all - the first version of this
		check asserted a scheduled value against a number pitchLimit had
		already clamped, and failed on correct code.
	]]
	local crawling = InputController.altitudeHoldPitchCaptured(
		schedCfg, { demandedClimb = 0 }, 500, 500, 1, 1 / 60, 3)
	record(
		"...even at a crawl, where an unbounded ratio would explode",
		math.abs(crawling - (-1 * sa.verticalSpeedGain)) < 1e-12,
		string.format("%.4f at 3 m/s, capped at %.2fx rather than %.0fx", crawling, sa.maxGainScale, (sa.refAirspeed / 3) ^ 2)
	)
	local diving = InputController.altitudeHoldPitchCaptured(
		schedCfg, { demandedClimb = 0 }, 500, 500, 1, 1 / 60, 400)
	record(
		"...and floored in a dive, so it never goes deaf",
		math.abs(diving) >= math.abs(-1 * sa.verticalSpeedGain * sa.minGainScale) - 1e-12,
		string.format("%.4f, floored at %.2fx", diving, sa.minGainScale)
	)
	--[[
		A zero or absent airspeed must not divide by nothing. Both degrade to
		the unscheduled law, which is what an older caller gets.
	]]
	record(
		"No airspeed degrades to the unscheduled law rather than failing",
		InputController.altitudeHoldPitchCaptured(schedCfg, { demandedClimb = 0 }, 500, 500, 2, 1 / 60)
			== -2 * sa.verticalSpeedGain
			and InputController.altitudeHoldPitchCaptured(schedCfg, { demandedClimb = 0 }, 500, 500, 2, 1 / 60, 0)
				== -2 * sa.verticalSpeedGain,
		"nil and zero both give the plain proportional command"
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

	-- 15. The flight tablet (Phase 4b) -----------------------------------------
	record(
		"M is bound to the tablet",
		InputController.DEFAULT_BINDINGS.ToggleTablet == Enum.KeyCode.M,
		tostring(InputController.DEFAULT_BINDINGS.ToggleTablet)
	)

	--[[
		Inert here, exactly like ResetAircraft and ToggleHud. TabletController
		owns the key, because the pilot has to be able to plan a flight on the
		apron with no aeroplane, and update() only runs while one is being flown.
	]]
	state = fresh()
	run(state, 120, { "ToggleTablet" })
	record(
		"Holding the tablet key moves no control",
		state.controls.pitch == 0 and state.controls.roll == 0 and state.controls.yaw == 0
			and state.controls.throttle == 0 and state.controls.brake == 0 and state.controls.flaps == 0,
		string.format("pitch %+.3f, throttle %.3f", state.controls.pitch, state.controls.throttle)
	)
	record(
		"Holding the tablet key does not open the tablet",
		not state.systems.tabletOpen and not state.systems.altitudeHold and not state.systems.paused,
		"tabletOpen still false - the controller owns it, not update()"
	)

	--[[
		THE SAFETY PROPERTY, and the reason this feature needed a decision at
		all. With the tablet open the cursor is clicking buttons, so its position
		must not reach the yoke - a destination button in the corner of the
		screen would otherwise be full nose-down and full right roll on the way
		to it (§7).

		Driven from the corner deliberately: the centre would pass whether the
		ignore worked or not.
	]]
	state = fresh()
	state.systems.tabletOpen = true
	run(state, 120, nil, pointer(1, -1)) -- top-right: hard nose-down, hard right
	record(
		"With the tablet open the cursor is not the yoke",
		math.abs(state.controls.pitch) < 1e-6 and math.abs(state.controls.roll) < 1e-6,
		string.format("pitch %+.6f, roll %+.6f with the cursor in the corner", state.controls.pitch, state.controls.roll)
	)

	--[[
		...and the yoke comes straight back. A release that could not be undone
		would be worse than no tablet: the pilot would land with the controls
		dead and no way to tell why.
	]]
	state.systems.tabletOpen = false
	run(state, 120, nil, pointer(1, -1))
	record(
		"Closing the tablet hands the yoke straight back",
		state.controls.pitch < -0.5 and state.controls.roll > 0.5,
		string.format("pitch %+.3f, roll %+.3f", state.controls.pitch, state.controls.roll)
	)

	--[[
		TRIM SURVIVES, which is what makes this safe in the air at all. A
		trimmed aeroplane flies on hands-off while the pilot plans; the same
		property §6g relies on for typing.
	]]
	state = fresh()
	run(state, 120, { "TrimNoseUp" })
	local trimmed = state.trim
	state.systems.tabletOpen = true
	run(state, 120, nil, pointer(0, 1)) -- cursor at the bottom: hard nose-up
	record(
		"The tablet releases the yoke but keeps trim",
		math.abs(state.trim - trimmed) < 1e-9 and math.abs(state.controls.pitch - trimmed) < 1e-3,
		string.format("trim %+.4f, pitch %+.4f - the aeroplane flies on trim alone", state.trim, state.controls.pitch)
	)

	--[[
		THE GATE ITSELF - the pilot's 2026-08-09 decision, asserted in all four
		states rather than in the one that motivated it. The airborne
		hand-flying case is the one that matters: it is the only "false" in the
		table, and it is the whole of the safety argument.
	]]
	record(
		"On foot, the tablet opens",
		InputController.tabletMayOpen(false, false, false),
		"not flying - there is no yoke to take away"
	)
	record(
		"On the ground, the tablet opens",
		InputController.tabletMayOpen(true, true, false),
		"parked or taxiing"
	)
	record(
		"Airborne with altitude hold engaged, the tablet opens",
		InputController.tabletMayOpen(true, false, true),
		"the mode on R already ignores the cursor (section 28)"
	)
	record(
		"Airborne and hand-flying, the tablet REFUSES",
		not InputController.tabletMayOpen(true, false, false),
		"the cursor is the yoke - nothing clickable may appear"
	)

	--[[
		Both gates open at once must not be a special case. Worth one line
		because "on the ground AND in altitude hold" is reachable - the mode
		does not disengage on touchdown - and an `elseif` chain written the
		wrong way round would fail exactly here.
	]]
	record(
		"...and both conditions together still open it",
		InputController.tabletMayOpen(true, true, true),
		"on the ground with the mode still engaged"
	)

	-- 16. Phase 4c systems ----------------------------------------------------
	print("--- Phase 4c systems ---")

	--[[
		⚠️ THE CONTRACT CHECK, RESTATED FOR THIS PHASE. §14's constraint is that
		nothing here may reach Controls, and twenty-two new switches is exactly
		the change that would break it. The six-field check at the top of this
		suite covers a fresh state; this covers one that has been driven through
		every new key.
	]]
	state = fresh()
	local everyNewKey = {
		"RudderTrimLeft", "RudderTrimRight", "MixtureRich", "MixtureLean",
		"FuelSelectorUp", "FuelSelectorDown", "MagnetosUp", "MagnetosDown",
		"StarterEngage", "BatteryMaster", "AlternatorMaster", "AvionicsMaster",
		"BreakerReset", "LightBeacon", "LightNav", "LightStrobe", "LightTaxi",
		"LightLanding", "CabinHeat", "CabinVent", "CabinDefrost", "PitotHeat",
		"ToggleBinds",
	}
	run(state, 60, everyNewKey)
	local extraFields = 0
	for k in state.controls do
		if not table.find(fields, k) then
			extraFields += 1
		end
	end
	record(
		"Holding every new systems key adds no field to Controls",
		extraFields == 0,
		string.format("%d unexpected field(s) after 60 frames of all 23 keys", extraFields)
	)
	record(
		"...and moves no flight control",
		math.abs(state.controls.pitch) < 1e-9 and math.abs(state.controls.roll) < 1e-9
			and math.abs(state.controls.yaw) < 1e-9 and state.controls.throttle == 0,
		string.format("pitch %+.6f, yaw %+.6f, throttle %.3f",
			state.controls.pitch, state.controls.yaw, state.controls.throttle)
	)

	-- ---- Rudder trim (item 1) ---------------------------------------------
	state = fresh()
	run(state, 120, { "RudderTrimRight" })
	record(
		"Rudder trim runs right and stays there",
		state.systems.rudderTrim > 0,
		string.format("%+.4f", state.systems.rudderTrim)
	)
	local heldRudderTrim = state.systems.rudderTrim
	run(state, 120, nil)
	record(
		"...holding its setting when released, like a trim wheel",
		math.abs(state.systems.rudderTrim - heldRudderTrim) < 1e-9,
		string.format("%+.4f", state.systems.rudderTrim)
	)
	run(state, 600, { "RudderTrimLeft" })
	record(
		"Rudder trim runs left too, and clamps at its limit",
		state.systems.rudderTrim < 0 and state.systems.rudderTrim >= -1.0,
		string.format("%+.4f against a limit of %.1f", state.systems.rudderTrim, InputController.DEFAULTS.rudderTrimLimit)
	)
	--[[
		The two trims are independent. One key moving both would mean trimming
		the nose up also kicked the rudder - and §38's lesson is that two
		actions on one control is a control the pilot cannot diagnose.
	]]
	state = fresh()
	run(state, 120, { "TrimNoseUp" })
	record(
		"Pitch trim does not touch rudder trim",
		state.trim > 0 and state.systems.rudderTrim == 0,
		string.format("pitch trim %+.4f, rudder trim %+.4f", state.trim, state.systems.rudderTrim)
	)

	-- ---- Mixture (item 3) --------------------------------------------------
	state = fresh()
	record("The mixture starts full rich", state.systems.mixture == 1, "1.000")
	run(state, 120, { "MixtureLean" })
	record(
		"Z leans the mixture",
		state.systems.mixture < 1,
		string.format("%.4f", state.systems.mixture)
	)
	run(state, 600, { "MixtureLean" })
	record(
		"...all the way to idle cutoff, which is how a 172 is shut down",
		state.systems.mixture == 0,
		"0.000"
	)
	run(state, 600, { "MixtureRich" })
	record(
		"Q takes it back to full rich and clamps there",
		state.systems.mixture == 1,
		"1.000"
	)

	-- ---- The fuel selector and the ignition (items 2, 4) -------------------
	--[[
		⚠️ THE LISTS MUST MATCH THE PHYSICS. This module carries the ORDER and
		Engine carries the MEANING, which is the only way the input layer can
		stay free of a dependency on the physics - and it is exactly the kind of
		duplication that rots silently, so it is asserted rather than trusted.
	]]
	local Engine = require(FlightSim.Physics.Engine)
	record(
		"The fuel selector order matches the physics module's",
		table.concat(FUEL_SELECTOR_ORDER, ",") == table.concat(Engine.FUEL_SELECTOR_POSITIONS, ","),
		table.concat(FUEL_SELECTOR_ORDER, " -> ")
	)
	record(
		"The magneto order matches the physics module's",
		table.concat(MAGNETO_ORDER, ",") == table.concat(Engine.MAGNETO_POSITIONS, ","),
		table.concat(MAGNETO_ORDER, " -> ")
	)

	state = fresh()
	record("The selector starts on BOTH, as the POH says to take off", state.systems.fuelSelector == "BOTH", "BOTH")

	-- One press is one position, however long the key is held.
	run(state, 300, { "FuelSelectorDown" })
	record(
		"A held selector press steps exactly one position",
		state.systems.fuelSelector == "LEFT",
		state.systems.fuelSelector
	)
	run(state, 1, nil)
	run(state, 120, { "FuelSelectorDown" })
	record(
		"...and the next press reaches OFF",
		state.systems.fuelSelector == "OFF",
		state.systems.fuelSelector
	)
	--[[
		THE ONE THAT MATTERS FOR SAFETY. Wrapping would put RIGHT one press past
		OFF, so a pilot stepping down past the stop would silently come round to
		a live tank - or, going the other way, shut the fuel off.
	]]
	run(state, 1, nil)
	run(state, 120, { "FuelSelectorDown" })
	record(
		"The selector CLAMPS at OFF rather than wrapping round",
		state.systems.fuelSelector == "OFF",
		"still OFF - a valve has stops"
	)

	state = fresh()
	record("The ignition starts on BOTH", state.systems.magnetos == "BOTH", "BOTH")
	run(state, 120, { "MagnetosDown" })
	record("The mag check steps down to L", state.systems.magnetos == "L", state.systems.magnetos)
	run(state, 1, nil)
	run(state, 120, { "MagnetosUp" })
	record("...and back to BOTH", state.systems.magnetos == "BOTH", state.systems.magnetos)

	-- ---- The starter is momentary ------------------------------------------
	state = fresh()
	run(state, 60, { "StarterEngage" })
	record("The starter engages while the key is held", state.systems.starterEngaged, "engaged")
	run(state, 1, nil)
	record(
		"...and releases the moment it is let go, because the key is sprung",
		not state.systems.starterEngaged,
		"released"
	)

	-- ---- Electrical and lights (items 5, 8) --------------------------------
	state = fresh()
	record(
		"The masters start on, in the configuration the aeroplane is handed over in",
		state.systems.batteryMaster and state.systems.alternatorMaster and state.systems.avionicsMaster,
		"BAT, ALT and AVIONICS all on"
	)
	run(state, 120, { "BatteryMaster" })
	record("1 toggles the battery master", not state.systems.batteryMaster, "off")
	run(state, 1, nil)
	run(state, 120, { "BatteryMaster" })
	record("...and back on, one position per press", state.systems.batteryMaster, "on")

	state = fresh()
	record("The beacon starts off - it is the pilot's to switch on with 5", state.systems.lights.beacon, "off")
	run(state, 120, { "LightLanding" })
	record("9 switches the landing light on", state.systems.lights.landing, "on")
	record(
		"...and leaves the others exactly as they were",
		not state.systems.lights.beacon and not state.systems.lights.nav
			and not state.systems.lights.strobe and not state.systems.lights.taxi,
		"beacon/nav/strobe/taxi still off"
	)

	--[[
		The breaker reset is an EDGE, not a state: true for one frame only, so
		the consumer can act on it once without doing its own edge detection.
	]]
	state = fresh()
	InputController.update(state, dt, snap({ "BreakerReset" }), nil)
	record("The breaker reset reports on the frame it is pressed", state.systems.breakerReset, "true")
	InputController.update(state, dt, snap({ "BreakerReset" }), nil)
	record(
		"...and not while the key is still held",
		not state.systems.breakerReset,
		"false - an edge, not a state"
	)

	-- ---- The cabin (item 7) -------------------------------------------------
	state = fresh()
	run(state, 120, { "CabinHeat" })
	run(state, 1, nil)
	run(state, 120, { "CabinDefrost" })
	record(
		"Cabin heat and defrost switch independently",
		state.systems.cabinHeat and state.systems.cabinDefrost and not state.systems.cabinVent,
		"heat on, defrost on, vent still off"
	)

	--[[
		⚠️ EVERY SYSTEM MUST BE PER-AIRCRAFT, and `lights` is a NESTED table -
		exactly the shape §6k records as a latent bug when `altHold` and
		`toggleViews` were cloned into DEFAULTS. Two aeroplanes sharing one
		lights table would mean one pilot's landing light switching everybody's.
	]]
	local a, b = fresh(), fresh()
	a.systems.lights.landing = true
	record(
		"Two aircraft do not share one lights table",
		b.systems.lights.landing == false,
		"the second aircraft's landing light is still off"
	)
	record(
		"...nor one systems table",
		a.systems ~= b.systems and a.systems.lights ~= b.systems.lights,
		"distinct tables"
	)

	-- ---- The binds reference's own key -------------------------------------
	record(
		"The binds reference is bound to K",
		InputController.DEFAULT_BINDINGS.ToggleBinds == Enum.KeyCode.K,
		tostring(InputController.DEFAULT_BINDINGS.ToggleBinds)
	)
	state = fresh()
	run(state, 120, { "ToggleBinds" })
	record(
		"Holding it moves no control and flips no system",
		state.controls.pitch == 0 and state.controls.throttle == 0
			and state.systems.magnetos == "BOTH" and state.systems.mixture == 1,
		"inert in update(), like the other three panel keys"
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
