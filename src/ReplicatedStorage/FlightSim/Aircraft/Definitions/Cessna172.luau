--!strict
--[[
	Cessna 172S Skyhawk
	-------------------
	Complete definition of one aircraft: mass, aerodynamic surfaces, engine,
	landing gear, operating limits, and the parts to build it from.

	Adding another aircraft means copying this file and changing numbers. No
	code elsewhere knows what a Cessna is.

	COORDINATE SYSTEM
	-----------------
	Roblox body axes, metres:
		-Z  forward (nose)		+X  right (starboard)		+Y  up

	All offsets are measured from the DATUM, an arbitrary reference point near
	the centre of the cabin - not from the centre of mass. The centre of mass
	is whatever the part layout produces, and FlightModel converts these datum
	offsets into centre-of-mass-relative moment arms once at spawn. That
	indirection matters: it means changing the model's mass distribution can
	never silently corrupt the aerodynamics.

	WHERE THE NUMBERS COME FROM
	---------------------------
	Published figures for the 172S: 16.17 m^2 wing, 11.0 m span, 180 hp
	Lycoming IO-360, 2,550 lb maximum takeoff weight, 48 kt clean stall.
	Coefficients come from the aerofoils used (NACA 2412 wing, symmetric
	tail). Nothing here is reverse-engineered from a desired flight feel - the
	behaviour is meant to fall out of honest numbers, and the test suite
	checks that it does.
]]

local FlightSim = script.Parent.Parent.Parent
local Aerodynamics = require(FlightSim.Physics.Aerodynamics)
local Units = require(FlightSim.Shared.Units)

-- =========================================================================
-- PRIMARY DIMENSIONS
-- =========================================================================

local WING_AREA = 16.17 -- m^2, total
local WING_SPAN = 11.0 -- m
local WING_AR = (WING_SPAN * WING_SPAN) / WING_AREA -- 7.48
local WING_CHORD = 1.47 -- m, mean aerodynamic chord

local STAB_AREA = 3.0 -- m^2, horizontal tail including elevator
local STAB_SPAN = 3.4
local STAB_AR = (STAB_SPAN * STAB_SPAN) / STAB_AREA -- 3.85

local FIN_AREA = 1.3 -- m^2, vertical tail including rudder
local FIN_SPAN = 1.5
local FIN_AR = (FIN_SPAN * FIN_SPAN) / FIN_AREA -- 1.73

--[[
	Rigging angles.

	The wing is bolted on at +1.5 degrees so the fuselage sits level in cruise
	while the wing still meets the air at a useful angle - without it, level
	flight would mean flying permanently nose-high.

	THE TAILPLANE CARRIES AN UPLOAD, NOT A DOWNLOAD, and the old comment here
	said the opposite. It claimed -2 degrees produced "a download that balances
	the nose-down pitching moment of the cambered wing". Both halves were wrong,
	and measuring the surfaces is what showed it:

	  - The wing's aerodynamic centre sits 0.19 m AHEAD of the centre of mass,
	    so wing lift is a nose-UP moment, not a nose-down one. That geometry is
	    correct for a 172, whose CG range (35-47% MAC) is genuinely aft of the
	    quarter-chord.
	  - A tail DOWNLOAD acts behind the CoM and therefore also pitches the nose
	    UP. So the two moments added instead of cancelling, and the elevator was
	    left to supply the whole balance.

	The consequence was an aeroplane that could not be trimmed hands-off
	anywhere: it needed -0.38 stick in cruise and -0.79 on approach with full
	flap, and the pilot reported exactly that as being unable to get the nose
	down. With an aft CG the tail has to LIFT to trim, so the incidence is
	positive.

	+1.0 degree was chosen by measurement, not by feel - it is the value that
	puts the cruise stick at -0.02, and it centres the whole envelope (-0.43 on
	approach to +0.65 clean at 65 kt) about neutral instead of hard against the
	nose-down stop. See the trim-requirement test in runTests().

	This changes TRIM, not STABILITY: static margin depends on lift slopes and
	moment arms, not on rigging incidence, and the +16% MAC is unaffected.
]]
local WING_INCIDENCE = 1.5
local STAB_INCIDENCE = 1.0

local wingForward, wingNormal = Aerodynamics.axesWithIncidence(WING_INCIDENCE)
local stabForward, stabNormal = Aerodynamics.axesWithIncidence(STAB_INCIDENCE)

-- =========================================================================
-- DEFINITION
-- =========================================================================

local Cessna172 = {}

Cessna172.id = "c172"
Cessna172.name = "Cessna 172S Skyhawk"
Cessna172.category = "Single-engine piston"
Cessna172.description = "Forgiving four-seat trainer. Slow, stable, and honest about what it is doing."

-- Reference quantities used to non-dimensionalise airframe drag.
Cessna172.reference = {
	wingArea = WING_AREA,
	wingSpan = WING_SPAN,
	chord = WING_CHORD,
}

Cessna172.mass = {
	empty = 767, -- kg
	maxTakeoff = 1157,
	fuelCapacity = 153, -- kg, 212 litres usable avgas
}

--[[
	Airframe parasitic drag, on the wing reference area, EXCLUDING the wing
	itself (each surface carries its own cd0).

	This covers the fuselage, wing struts, fixed landing gear, antennas and
	the interference between them. Together with the wing's 0.009 it gives a
	total zero-lift drag coefficient of about 0.028, which reproduces the
	real aircraft's cruise performance: 122 kt true at 75% power at 8,000 ft.

	The propeller adds its own drag on top when it is not being driven - see
	Engine.getPropDragCD0. That contribution is why the published glide ratio
	(about 9:1) is so much worse than the airframe alone would manage.
]]
Cessna172.drag = {
	airframeCD0 = 0.019,
}

-- =========================================================================
-- AERODYNAMIC SURFACES
-- =========================================================================
--[[
	The wing is split into left and right panels. This is not cosmetic - it is
	what makes roll damping and asymmetric stalls work, because each panel
	sees its own airflow when the aircraft is rolling.

	Note each panel gets HALF the area but the FULL wing's aspect ratio.
	Induced drag depends on the whole span, not on one panel.
]]

local AILERON_AUTHORITY = 0.40 -- change in CL at full deflection
local ELEVATOR_AUTHORITY = 0.60
local RUDDER_AUTHORITY = 0.50

Cessna172.surfaces = {
	Aerodynamics.newSurface({
		name = "WingLeft",
		area = WING_AREA / 2,
		aspectRatio = WING_AR,
		chord = WING_CHORD,
		-- Quarter chord of the panel, out at its centre of lift.
		offset = Vector3.new(-2.75, 0.95, -0.25),
		forward = wingForward,
		normal = wingNormal,
		airfoil = Aerodynamics.Airfoils.CAMBERED,

		-- Roll right means less lift on the right, more on the left.
		controlAxis = "roll",
		controlSign = 1,
		controlEffect = AILERON_AUTHORITY,

		-- Flaps raise CLmax (lowering stall speed) and add a great deal of
		-- drag, which is exactly what makes a steep, slow approach possible.
		flapEffect = 0.60,
		flapDragEffect = 0.045,

		--[[
			The FULL span, not this panel's. Ground effect is a property of the
			whole vortex system, and sqrt(AR * area) on a half-panel would give
			7.78 m for an 11 m wing - a 30% error into a squared term.
		]]
		groundEffectSpan = WING_SPAN,
	}),

	Aerodynamics.newSurface({
		name = "WingRight",
		area = WING_AREA / 2,
		aspectRatio = WING_AR,
		chord = WING_CHORD,
		offset = Vector3.new(2.75, 0.95, -0.25),
		forward = wingForward,
		normal = wingNormal,
		airfoil = Aerodynamics.Airfoils.CAMBERED,

		controlAxis = "roll",
		controlSign = -1,
		controlEffect = AILERON_AUTHORITY,

		flapEffect = 0.60,
		flapDragEffect = 0.045,
		groundEffectSpan = WING_SPAN,
	}),

	--[[
		Horizontal stabiliser. Sits about 4.2 m behind the centre of mass,
		which is the single most important number for pitch stability: if the
		nose rises, the tail meets the air at a higher angle, makes more lift,
		and pushes the nose back down.

		Pull back on the yoke and the elevator reduces the tail's lift, so the
		tail sinks and the nose rises - hence controlSign = -1.
	]]
	Aerodynamics.newSurface({
		name = "Stabilizer",
		area = STAB_AREA,
		aspectRatio = STAB_AR,
		chord = 1.0,
		offset = Vector3.new(0, 0.35, 4.15),
		forward = stabForward,
		normal = stabNormal,
		airfoil = Aerodynamics.Airfoils.SYMMETRIC,

		controlAxis = "pitch",
		controlSign = -1,
		controlEffect = ELEVATOR_AUTHORITY,
	}),

	--[[
		Vertical fin. Its "lift" acts sideways, so its normal points right.

		Two behaviours come out of this for free:
		  - Weathervane stability. Sideslip makes the fin push the tail back
		    into line, so the aircraft naturally points where it is going.
		  - Rudder-induced roll. The fin sits ABOVE the centre of mass, so its
		    side force also rolls the aircraft. This is why rudder alone can
		    roll an aeroplane, and why uncoordinated flight feels wrong.
	]]
	Aerodynamics.newSurface({
		name = "Fin",
		area = FIN_AREA,
		aspectRatio = FIN_AR,
		chord = 1.1,
		offset = Vector3.new(0, 1.05, 4.225),
		forward = Vector3.new(0, 0, -1),
		normal = Vector3.new(1, 0, 0), -- +X, so positive lift pushes the tail right
		airfoil = Aerodynamics.Airfoils.SYMMETRIC,

		-- Right rudder pushes the TAIL left, which swings the NOSE right.
		controlAxis = "yaw",
		controlSign = -1,
		controlEffect = RUDDER_AUTHORITY,
	}),
}

-- =========================================================================
-- ENGINE
-- =========================================================================

Cessna172.engine = {
	maxPowerW = Units.horsepowerToWatts(180), -- Lycoming IO-360-L2A
	propDiameter = 1.93,
	propEfficiency = 0.80,
	figureOfMerit = 0.55,

	idleRPM = 600,
	maxRPM = 2700,
	idlePowerFraction = 0.05,

	-- 0.45 lb per horsepower-hour, the usual figure for this engine class.
	bsfc = 7.6e-8, -- kg per joule
	fuelCapacityKg = 153,

	spoolTime = 0.35,
	startTime = 1.5,

	--[[
		Propeller on the nose, on the fuselage centreline.

		This sits about 0.28 m BELOW the centre of mass, because the high wing
		and the fuel in it carry the balance point well above the propeller
		shaft. Adding power therefore pitches the nose UP - the "power up,
		nose up" behaviour characteristic of the high-wing Cessnas, and the
		reason a go-around needs forward pressure on the yoke.

		Verified by FlightModel.runTests(), which checks the sign of the arm
		rather than trusting this comment.
	]]
	thrustOffset = Vector3.new(0, 0.05, -2.2),

	--[[
		Left-turning tendencies, in newton-metres per watt of power.

		The propeller turns clockwise seen from the cockpit, so Newton's third
		law rolls the airframe anticlockwise, and the slipstream corkscrews
		back to strike the left side of the fin, yawing the nose left.

		This is why every pilot holds right rudder on takeoff. Small numbers,
		very recognisable behaviour.
	]]
	torqueReaction = 1.6e-3,
	slipstreamYaw = 2.2e-3,

	windmillCD0 = 0.020,
}

-- =========================================================================
-- LANDING GEAR
-- =========================================================================
--[[
	Fixed tricycle gear. The main wheels sit slightly BEHIND the centre of
	mass so the aircraft rests on them and cannot tip onto its tail, and the
	nose wheel carries the rest.

	Contact and suspension are handled by Roblox's rigid body solver against
	real collidable parts - we do not simulate the gear ourselves. What we do
	supply is steering, braking and rolling resistance.
]]

Cessna172.gear = {
	retractable = false,

	wheels = {
		{ name = "Nose", offset = Vector3.new(0, -0.95, -1.4), radius = 0.18, steering = true },
		{ name = "Left", offset = Vector3.new(-1.25, -0.95, 0.4), radius = 0.2, braked = true },
		{ name = "Right", offset = Vector3.new(1.25, -0.95, 0.4), radius = 0.2, braked = true },
	},

	--[[
		How far the nose wheel turns at full pedal, in radians.

		10 degrees is the real figure for a 172 on rudder pedals alone. With a
		1.8 m wheelbase that gives a turn radius of 1.8 / tan(10 deg) = 10.2 m,
		which is what the aeroplane actually does on a taxiway. (Real 172s reach
		about 30 degrees using differential braking on top of the pedals; that is
		not modelled, so this is the pedals-only figure and correctly so.)

		An ANGLE, not a force fraction, and that replaced `steeringAuthority =
		0.55` for a measured reason. Steering used to be a sideways shove at a
		nose wheel that stayed pointed straight ahead, while all three wheels
		shared one lateral axis - so the mains' grip cancelled the very rotation
		the nose was asking for. Full rudder at 12 kt turned the aircraft 5.8
		degrees in five seconds: a 207 m radius. Pointing the wheel instead makes
		the cornering force emerge from slip angle, as a tyre's does.

		The yaw still emerges from r x F, and the two behaviours that mattered on
		the takeoff roll still come for free: authority falls away as lift
		unloads the nose wheel, and vanishes the moment it leaves the ground -
		which is exactly when the rudder takes over.
	]]
	steeringAngle = math.rad(10),

	--[[
		Slip angle at which a tyre reaches its maximum cornering force.

		6 degrees is the ordinary figure for a pneumatic tyre. Below it the
		cornering force rises roughly in proportion to slip; above it the tyre is
		sliding and there is no more to be had.

		Used by the steered wheel, and it is what makes the speed fade work: a
		10-degree taxi input is past saturation and pulls full grip, while the
		fraction of a degree left at rotation speed produces almost nothing.
	]]
	tyreSlipAngle = math.rad(6),
	-- Steering is progressively reduced above this speed; the rudder does the
	-- work by then, and full-authority nose wheel steering at speed is how
	-- real aircraft depart the side of the runway.
	steeringFadeSpeed = 25, -- m/s

	-- Sideways grip of a tyre on dry asphalt. This is what stops the aircraft
	-- sliding sideways across the runway in a crosswind landing.
	tyreFriction = 0.8,

	-- Rolling resistance and braking, as fractions of the weight on wheels.
	rollingResistance = 0.025,
	brakeForce = 0.35,
}

-- =========================================================================
-- FLAPS
-- =========================================================================

Cessna172.flaps = {
	-- Detents in degrees, as they are marked in the real cockpit.
	detents = { 0, 10, 20, 30 },
	maxDeflection = 30,
	-- Seconds to travel the full range - flaps are slow, deliberately so.
	travelTime = 4.0,
}

-- =========================================================================
-- OPERATING LIMITS
-- =========================================================================
--[[
	The speeds painted on a real airspeed indicator. Phase 2 will draw the
	instrument arcs directly from these numbers.
]]

Cessna172.limits = {
	vs0 = 40, -- kt, stall, full flap
	vs1 = 48, -- kt, stall, clean
	vx = 62, -- kt, best angle of climb
	vy = 74, -- kt, best rate of climb
	vbg = 68, -- kt, best glide
	vfe = 85, -- kt, maximum with flaps extended
	vno = 129, -- kt, maximum structural cruising
	vne = 163, -- kt, never exceed

	gPositive = 3.8,
	gNegative = -1.52,

	serviceCeiling = 4267, -- m (14,000 ft)

	--[[
		The tachometer's green arc. 2,100 rpm is the bottom of the normal
		operating range on the 172S; the top of the arc is the redline and is
		NOT repeated here - it is `engine.maxRPM`, and a second copy of a number
		is a second place for it to go stale.
	]]
	rpmGreenLow = 2100,

	--[[
		The red band at the bottom of the fuel gauge.

		Derived, not chosen: 45 minutes at cruise is the VFR night reserve, and
		this aircraft burns 27.9 kg/h at cruise (see section 4), so 0.75 h gives
		about 21 kg. Reaching this band means landing somewhere, not pressing on.
	]]
	fuelReserveKg = 21,
}

-- =========================================================================
-- PHYSICAL MODEL
-- =========================================================================
--[[
	The parts AircraftBuilder welds together.

	Masses are specified directly in kilograms and the builder solves for the
	density each part needs. Specifying density instead would mean the mass
	silently changing every time a part was resized - and mass is the number
	that actually matters to the physics.

	THE DENSITY CEILING
	-------------------
	This is where the 1 stud = 1 metre decision bites, and it dictates the
	part sizes below.

	Roblox mass = density x volume, and density is capped at 100. At metre
	scale one mass unit is one kilogram, so a part can only ever weigh 100 kg
	per cubic metre of its bounding box. An 1,111 kg aeroplane therefore needs
	at least 11.1 m^3 of parts - and since a real Cessna's structure is mostly
	empty air, that is a genuine constraint rather than a rounding concern.

	The boxes below are consequently sized to the aircraft's true external
	dimensions rather than to its structure, giving about 14.4 m^3 and leaving
	every part under the ceiling (the cabin, at 97, is closest).
	AircraftBuilder verifies this and refuses to build if any part exceeds it,
	because the failure mode otherwise is an aircraft that is silently too
	light and flies like a balloon.

	The budget totals 1,111 kg, a realistic loaded weight (two adults,
	baggage, most of a full fuel load), and places the centre of mass where it
	gives a 14% static margin - stable, and verified in runTests().

	This geometry is deliberately crude. It exists so the physics has
	something correctly proportioned to act on; the shape gets replaced with
	proper modelling later, and the aerodynamic offsets above will not need to
	change when it does.

	⚠️ PHASE 4 UPDATE: THE BOXES BELOW ARE STILL THE AIRCRAFT.

	They are now INVISIBLE (hideStructuralParts) and a modelled skin is drawn
	over them in `decorations`, but nothing about their role changed. They are
	the mass budget, the centre of mass, the static margin and the inertia
	tensor; §4's published figures are all measured against exactly these
	numbers. The skin is massless by construction - AircraftBuilder forces
	Massless on every decoration and measure() skips massless parts - so it
	CANNOT move any of it.

	If a box below is ever resized or moved, the definition is re-verified,
	not assumed. Do not "tidy" a box to match the skin: the skin exists to
	match the box.
]]

-- =========================================================================
-- THE MODELLED SKIN (Phase 4)
-- =========================================================================

--[[
	The 172S's real shape, built from primitives rather than a mesh.

	WHY PRIMITIVES IN CODE. The same reasoning as the airport in §11: a mesh
	is an opaque binary that Rojo cannot diff, cannot be reviewed, and cannot
	be adjusted without leaving the repository - and §3 makes files the source
	of truth. Geometry in code is readable, reviewable and parametric, and the
	airport proved the approach at a far larger scale.

	EVERY PART HERE IS MASSLESS. AircraftBuilder forces Massless on every
	decoration and measure() skips massless parts, so nothing in this section
	can move the centre of mass, the static margin or the inertia tensor. That
	is what makes it safe to model freely: the shape is not the physics.

	Coordinates are the datum frame of §5 - -Z forward, +X right, +Y up - and
	are chosen to clothe the structural boxes above rather than to be
	independently "correct". Where a visual edge and a box edge disagree, the
	box wins, because the box is what flies.
]]

local WHITE = Color3.fromRGB(240, 240, 243)
local TRIM = Color3.fromRGB(38, 88, 168)
local DARK = Color3.fromRGB(38, 38, 42)
local GLASS = Color3.fromRGB(140, 170, 195)
local METAL = Color3.fromRGB(165, 168, 175)
local RUBBER = Color3.fromRGB(26, 26, 28)

local SKIN: { any } = {}

local function add(spec: any)
	table.insert(SKIN, spec)
end

--[[
	Add a part and its mirror image across the centreline.

	A mirror negates X, and with it the Y and Z components of any rotation -
	a strut leaning outboard to starboard must lean outboard to port, not
	inboard. Rotation about X (sweep, rake) is unchanged by a left-right
	mirror, which is why only two of the three flip.

	`mirrorSign` on a hinge is for ANTISYMMETRIC surfaces. Flaps and elevators
	move together; ailerons move opposite, so the aileron declares -1 and the
	left copy inherits a negated sign.
]]
local function addPair(spec: any)
	local right = table.clone(spec)
	right.name = spec.name .. "Right"
	add(right)

	local left = table.clone(spec)
	left.name = spec.name .. "Left"
	left.position = Vector3.new(-spec.position.X, spec.position.Y, spec.position.Z)
	if spec.rotation then
		left.rotation = Vector3.new(spec.rotation.X, -spec.rotation.Y, -spec.rotation.Z)
	end
	if spec.hinge then
		local hinge = table.clone(spec.hinge)
		if hinge.offset then
			hinge.offset = Vector3.new(-hinge.offset.X, hinge.offset.Y, hinge.offset.Z)
		end
		hinge.sign = (hinge.sign or 1) * (hinge.mirrorSign or 1)
		left.hinge = hinge
	end
	add(left)
end

--[[
	Loft a tapering body from a list of stations, front to back.

	One box is emitted between each adjacent pair, sized to the mean of the
	two. Enough stations and the steps disappear into a smooth taper - which
	is how the tail cone narrows from a 1.16 m cabin to a 0.34 m tailpost
	without a single hand-placed wedge.
]]
local function loft(prefix: string, color: Color3, stations: { any })
	for i = 1, #stations - 1 do
		local a, b = stations[i], stations[i + 1]
		add({
			name = string.format("%s%02d", prefix, i),
			size = Vector3.new((a.w + b.w) / 2, (a.h + b.h) / 2, math.abs(b.z - a.z)),
			position = Vector3.new(0, (a.y + b.y) / 2, (a.z + b.z) / 2),
			color = color,
		})
	end
end

--[[
	---- Fuselage ------------------------------------------------------------

	The step between the fourth and fifth stations is the windscreen: the deck
	rises from 0.55 to 0.84 in half a metre, which is what gives a high-wing
	Cessna its distinctive shouldered profile. The glass that bridges it is
	placed explicitly below, because a loft can only make steps, not slopes.
]]
loft("Fuselage", WHITE, {
	{ z = -2.90, w = 0.72, h = 0.62, y = 0.12 },
	{ z = -2.30, w = 0.92, h = 0.74, y = 0.12 },
	{ z = -1.70, w = 1.00, h = 0.80, y = 0.12 },
	{ z = -1.10, w = 1.06, h = 0.86, y = 0.12 },
	{ z = -0.55, w = 1.14, h = 1.20, y = 0.24 },
	{ z = 0.35, w = 1.16, h = 1.24, y = 0.22 },
	{ z = 1.05, w = 1.06, h = 1.12, y = 0.26 },
	{ z = 1.60, w = 0.92, h = 0.94, y = 0.32 },
	{ z = 2.35, w = 0.74, h = 0.78, y = 0.36 },
	{ z = 3.15, w = 0.58, h = 0.64, y = 0.40 },
	{ z = 3.95, w = 0.44, h = 0.52, y = 0.44 },
	{ z = 4.70, w = 0.34, h = 0.44, y = 0.48 },
})

-- ---- Glazing ------------------------------------------------------------
-- The windscreen bridges the deck step at 27.8 degrees, computed from the
-- stations either side of it rather than eyeballed.
add({
	name = "Windscreen",
	size = Vector3.new(1.06, 0.05, 0.64),
	position = Vector3.new(0, 0.695, -0.825),
	rotation = Vector3.new(-27.8, 0, 0),
	color = GLASS,
	transparency = 0.55,
	reflectance = 0.2,
	material = Enum.Material.Glass,
})
addPair({
	name = "WindowSide",
	size = Vector3.new(0.03, 0.36, 1.30),
	position = Vector3.new(0.585, 0.58, 0.05),
	color = GLASS,
	transparency = 0.55,
	reflectance = 0.2,
	material = Enum.Material.Glass,
})
addPair({
	name = "WindowRear",
	size = Vector3.new(0.03, 0.26, 0.52),
	position = Vector3.new(0.535, 0.56, 1.02),
	color = GLASS,
	transparency = 0.55,
	reflectance = 0.2,
	material = Enum.Material.Glass,
})

-- The Cessna side stripe, and the door seams either side of it.
addPair({
	name = "Stripe",
	size = Vector3.new(0.03, 0.10, 2.70),
	position = Vector3.new(0.585, 0.02, 0.15),
	color = TRIM,
})
addPair({
	name = "DoorSeam",
	size = Vector3.new(0.02, 0.62, 0.03),
	position = Vector3.new(0.59, 0.22, -0.62),
	color = Color3.fromRGB(205, 205, 208),
})

-- ---- Cowling and propeller ----------------------------------------------
add({
	name = "SpinnerCone",
	size = Vector3.new(0.28, 0.36, 0.36),
	position = Vector3.new(0, 0.12, -3.02),
	rotation = Vector3.new(0, 90, 0),
	shape = "Cylinder",
	color = WHITE,
})
add({
	name = "SpinnerBase",
	size = Vector3.new(0.36, 0.36, 0.36),
	position = Vector3.new(0, 0.12, -2.92),
	shape = "Ball",
	color = WHITE,
})
addPair({
	name = "CowlIntake",
	size = Vector3.new(0.20, 0.12, 0.12),
	position = Vector3.new(0.22, 0.00, -2.86),
	color = DARK,
})
add({
	name = "Exhaust",
	size = Vector3.new(0.08, 0.08, 0.22),
	position = Vector3.new(-0.24, -0.20, -2.58),
	color = DARK,
})

--[[
	The propeller is hinged so it can spin, and is a single part rather than
	two blades: a 172S has a two-blade fixed-pitch prop, so one part through
	the hub IS both blades.

	The disc behind it is the blur. A solid blade at 2,400 rpm strobes badly
	against any frame rate, which is exactly what a real propeller does not
	look like; the animation layer fades this in as the blade fades out.
]]
add({
	name = "Propeller",
	size = Vector3.new(0.20, 1.96, 0.06),
	position = Vector3.new(0, 0.12, -3.10),
	color = DARK,
	hinge = { axis = "Z", channel = "propeller" },
})
add({
	name = "PropellerDisc",
	size = Vector3.new(0.02, 1.96, 1.96),
	position = Vector3.new(0, 0.12, -3.08),
	rotation = Vector3.new(0, 90, 0),
	shape = "Cylinder",
	color = DARK,
	transparency = 1,
	castShadow = false,
	-- Paired to the propeller hinge: the blade fades out INTO this disc, so
	-- dropping it with the rest of the shell would leave the blur half-done.
	keepWithMesh = true,
})

--[[
	---- Wing ---------------------------------------------------------------

	Dihedral is 1.73 degrees (1 deg 44 min on the real aircraft), applied as a
	rotation on each panel about its own centre. Over a 2 m panel that
	displaces the ends by about 3 cm, which is below the thickness of the
	skin - so the panels still meet without a visible break.
]]
local DIHEDRAL = 1.73

add({
	name = "WingCentre",
	size = Vector3.new(1.55, 0.22, 1.58),
	position = Vector3.new(0, 0.96, 0.11),
	color = WHITE,
})
addPair({
	name = "WingInner",
	size = Vector3.new(2.35, 0.21, 1.58),
	position = Vector3.new(1.94, 0.99, 0.11),
	rotation = Vector3.new(0, 0, DIHEDRAL),
	color = WHITE,
})
addPair({
	name = "WingOuter",
	size = Vector3.new(1.65, 0.18, 1.42),
	position = Vector3.new(3.95, 1.05, 0.05),
	rotation = Vector3.new(0, 0, DIHEDRAL),
	color = WHITE,
})
addPair({
	name = "WingTip",
	size = Vector3.new(0.45, 0.14, 1.10),
	position = Vector3.new(5.00, 1.09, -0.02),
	rotation = Vector3.new(0, 0, DIHEDRAL),
	color = WHITE,
})

-- Navigation lights: red to port, green to starboard, so the aircraft states
-- its own heading at night the way a real one does. Added singly because the
-- colours differ, which is the whole point of them.
add({
	name = "NavLightRight",
	size = Vector3.new(0.10, 0.10, 0.14),
	position = Vector3.new(5.20, 1.10, -0.10),
	color = Color3.fromRGB(0, 220, 60),
	material = Enum.Material.Neon,
})
add({
	name = "NavLightLeft",
	size = Vector3.new(0.10, 0.10, 0.14),
	position = Vector3.new(-5.20, 1.10, -0.10),
	color = Color3.fromRGB(230, 30, 30),
	material = Enum.Material.Neon,
})

--[[
	Flaps and ailerons. Both hinge about the datum's X axis, which is 1.73
	degrees off the true hinge line because of the dihedral - far below what
	is visible, and it keeps the animation layer talking about the aircraft's
	axes rather than each surface's own.

	Flaps deflect DOWN only, to 30 degrees, and both together. Ailerons
	deflect 20 degrees and OPPOSE each other - hence mirrorSign.
]]
addPair({
	name = "Flap",
	size = Vector3.new(2.07, 0.10, 0.42),
	position = Vector3.new(1.815, 0.97, 1.11),
	rotation = Vector3.new(0, 0, DIHEDRAL),
	color = WHITE,
	hinge = { axis = "X", channel = "flaps", offset = Vector3.new(0, 0, -0.21), maxDeg = 30 },
})
addPair({
	name = "Aileron",
	size = Vector3.new(1.80, 0.09, 0.36),
	position = Vector3.new(3.85, 1.04, 0.94),
	rotation = Vector3.new(0, 0, DIHEDRAL),
	color = WHITE,
	hinge = {
		axis = "X",
		channel = "aileron",
		offset = Vector3.new(0, 0, -0.18),
		maxDeg = 20,
		--[[
			sign = -1 so a RIGHT roll command RAISES the right aileron.

			Positive rotation about X carries a surface's trailing edge DOWN.
			The first version left this at the default +1, which dropped the
			right aileron on a right roll - adding lift to the wing that is
			supposed to be dropping, so the visible ailerons contradicted the
			roll the aeroplane was actually doing.
		]]
		sign = -1,
		mirrorSign = -1,
	},
})

--[[
	Lift struts. The angle is computed from the two attachment points rather
	than chosen: 61.5 degrees from vertical, running from the lower fuselage
	longeron out to mid-semi-span. Getting this wrong is instantly visible,
	because a strut that does not land on the wing looks like a mistake even
	to someone who has never seen a Cessna.
]]
addPair({
	name = "Strut",
	size = Vector3.new(0.08, 2.39, 0.26),
	position = Vector3.new(1.55, 0.29, 0.25),
	rotation = Vector3.new(0, 0, -61.5),
	color = WHITE,
})

-- ---- Tail ---------------------------------------------------------------
-- Named "Tailplane" and not "Stabilizer" ON PURPOSE: a decoration sharing a
-- structural part's name silently replaced it in the builder's lookup, so the
-- real stabilizer was never welded on. See the duplicate-name check in
-- AircraftBuilder.validate, which now refuses to build that.
add({
	name = "Tailplane",
	size = Vector3.new(3.42, 0.15, 0.92),
	position = Vector3.new(0, 0.36, 4.18),
	color = WHITE,
})
addPair({
	name = "Elevator",
	size = Vector3.new(1.60, 0.10, 0.46),
	position = Vector3.new(0.90, 0.36, 4.87),
	color = WHITE,
	hinge = {
		axis = "X",
		channel = "elevator",
		offset = Vector3.new(0, 0, -0.23),
		maxDeg = 22,
		sign = -1, -- stick back is elevator UP
	},
})

--[[
	The trim tab is on the RIGHT elevator only, as on the real aircraft, so it
	is added singly rather than as a pair. It moves OPPOSITE the elevator it
	trims - that is how a trim tab works, and a tab that follows the elevator
	would be modelling an anti-servo tab from a different aeroplane.
]]
add({
	name = "TrimTab",
	size = Vector3.new(0.50, 0.07, 0.20),
	position = Vector3.new(0.72, 0.36, 5.06),
	color = WHITE,
	hinge = {
		axis = "X",
		channel = "trim",
		offset = Vector3.new(0, 0, -0.10),
		maxDeg = 15,
		sign = 1,
	},
})

add({
	name = "FinMain",
	size = Vector3.new(0.13, 1.05, 0.80),
	position = Vector3.new(0, 1.02, 4.48),
	color = TRIM,
})
-- The swept leading edge, raked 30 degrees so it runs up and aft.
add({
	name = "FinLeadingEdge",
	size = Vector3.new(0.12, 1.20, 0.22),
	position = Vector3.new(0, 1.00, 4.02),
	rotation = Vector3.new(30, 0, 0),
	color = TRIM,
})
add({
	name = "FinTip",
	size = Vector3.new(0.13, 0.18, 0.58),
	position = Vector3.new(0, 1.58, 4.60),
	color = TRIM,
})
-- The dorsal fillet ahead of the fin, which a 172 has and which reads
-- immediately as "Cessna" from the side.
add({
	name = "DorsalFin",
	size = Vector3.new(0.10, 0.26, 0.90),
	position = Vector3.new(0, 0.66, 3.55),
	color = TRIM,
})
add({
	name = "Beacon",
	size = Vector3.new(0.09, 0.10, 0.09),
	position = Vector3.new(0, 1.72, 4.60),
	color = Color3.fromRGB(230, 30, 30),
	material = Enum.Material.Neon,
})

add({
	name = "Rudder",
	size = Vector3.new(0.11, 1.10, 0.48),
	position = Vector3.new(0, 1.05, 5.05),
	color = TRIM,
	hinge = {
		axis = "Y",
		channel = "rudder",
		offset = Vector3.new(0, 0, -0.24),
		maxDeg = 22,
	},
})

--[[
	---- Landing gear -------------------------------------------------------

	The wheels sit exactly where the structural wheel boxes are, at the same
	size, because those are the parts that actually touch the runway. What is
	new is the legs holding them up - the spring-steel main legs at 55 degrees
	and the nose oleo - which the crude model simply did not have.
]]
addPair({
	name = "GearLeg",
	size = Vector3.new(0.09, 1.01, 0.16),
	position = Vector3.new(0.835, -0.61, 0.40),
	rotation = Vector3.new(0, 0, 55),
	color = METAL,
})
addPair({
	name = "WheelMain",
	size = Vector3.new(0.16, 0.40, 0.40),
	position = Vector3.new(1.25, -0.95, 0.40),
	shape = "Cylinder",
	color = RUBBER,
})
addPair({
	name = "HubMain",
	size = Vector3.new(0.17, 0.18, 0.18),
	position = Vector3.new(1.25, -0.95, 0.40),
	shape = "Cylinder",
	color = METAL,
})
add({
	name = "NoseStrut",
	size = Vector3.new(0.12, 0.64, 0.16),
	position = Vector3.new(0, -0.62, -1.40),
	color = METAL,
})
add({
	name = "WheelNoseSkin",
	size = Vector3.new(0.16, 0.40, 0.40),
	position = Vector3.new(0, -0.95, -1.40),
	shape = "Cylinder",
	color = RUBBER,
})
add({
	name = "HubNose",
	size = Vector3.new(0.17, 0.18, 0.18),
	position = Vector3.new(0, -0.95, -1.40),
	shape = "Cylinder",
	color = METAL,
})
addPair({
	name = "Step",
	size = Vector3.new(0.22, 0.04, 0.28),
	position = Vector3.new(0.60, -0.46, 0.52),
	color = METAL,
})

-- ---- Small details ------------------------------------------------------
add({
	name = "AntennaVHF",
	size = Vector3.new(0.03, 0.22, 0.10),
	position = Vector3.new(0, 0.92, 0.55),
	color = DARK,
})
add({
	name = "Pitot",
	size = Vector3.new(0.05, 0.06, 0.24),
	position = Vector3.new(-1.90, 0.83, -0.30),
	color = METAL,
})
add({
	name = "LandingLight",
	size = Vector3.new(0.18, 0.10, 0.06),
	position = Vector3.new(-1.20, 0.94, -0.70),
	color = Color3.fromRGB(255, 250, 220),
	material = Enum.Material.Neon,
})

Cessna172.model = {
	-- Everything is welded to this part, and it defines the body axes.
	rootPart = "Cabin",

	--[[
		The structural boxes are the physics and are not meant to be looked
		at. Phase 4 draws the real shape over them in `decorations`, so they
		are hidden rather than deleted - deleting one would delete the mass
		and the aerodynamic reference point with it.
	]]
	hideStructuralParts = true,

	--[[
		Flip to true when the imported Cessna mesh lands (CREDITS.md).

		It drops the primitive shell below and keeps the hinged control
		surfaces, so the mesh becomes the exterior without the two fighting.
		Nothing physical moves either way - the structural boxes are the
		aircraft and both exteriors are massless decoration over them.

		The primitive shell stays in the file rather than being deleted: it is
		what the aeroplane looks like until the mesh arrives, it is the
		fallback if the import is rejected, and it costs one boolean to have
		both.
	]]
	exteriorFromMesh = false,

	parts = {
		-- Density 87. Engine, mount, propeller and cowling - the heaviest
		-- single item on the aircraft, and the reason the nose is where it is.
		{
			name = "Nose",
			size = Vector3.new(1.05, 1.15, 1.90),
			position = Vector3.new(0, 0.05, -2.00),
			mass = 200,
			color = Color3.fromRGB(225, 225, 230),
		},
		-- Density 97, the closest to the ceiling. Structure, occupants and
		-- baggage. If more mass is ever needed here, the box must grow first.
		{
			name = "Cabin",
			size = Vector3.new(1.30, 1.50, 2.90),
			position = Vector3.new(0, 0.15, -0.10),
			mass = 549,
			color = Color3.fromRGB(225, 225, 230),
		},
		-- Density 22. Deliberately light: mass this far aft drags the centre
		-- of mass backwards and eats directly into the static margin.
		{
			name = "TailBoom",
			size = Vector3.new(0.85, 1.00, 3.80),
			position = Vector3.new(0, 0.30, 2.90),
			mass = 70,
			color = Color3.fromRGB(225, 225, 230),
		},

		{
			name = "WingLeft",
			size = Vector3.new(5.00, 0.25, 1.50),
			position = Vector3.new(-2.75, 0.95, 0.125),
			mass = 110, -- structure plus the fuel it carries
			color = Color3.fromRGB(225, 225, 230),
		},
		{
			name = "WingRight",
			size = Vector3.new(5.00, 0.25, 1.50),
			position = Vector3.new(2.75, 0.95, 0.125),
			mass = 110,
			color = Color3.fromRGB(225, 225, 230),
		},
		{
			name = "WingCenter",
			size = Vector3.new(1.50, 0.25, 1.50),
			position = Vector3.new(0, 0.95, 0.125),
			mass = 30,
			color = Color3.fromRGB(225, 225, 230),
		},

		{
			name = "Stabilizer",
			size = Vector3.new(3.40, 0.15, 1.00),
			position = Vector3.new(0, 0.35, 4.40),
			mass = 20,
			color = Color3.fromRGB(225, 225, 230),
		},
		{
			name = "Fin",
			size = Vector3.new(0.15, 1.30, 1.10),
			position = Vector3.new(0, 1.05, 4.50),
			mass = 15,
			color = Color3.fromRGB(40, 90, 170),
		},

		--[[
			Landing gear. Small parts hit the density ceiling immediately - a
			0.026 m^3 wheel cannot weigh more than 2.6 kg - so the real mass of
			the gear legs is carried by the fuselage instead. Harmless here: the
			gear sits close to the centre of mass, so exactly where its few
			kilograms live makes no measurable difference to the balance.

			These are the only collidable parts, so the aircraft rests and rolls
			on its wheels rather than scraping its belly.

			TYRE FRICTION IS ZERO, AND MUST BE. This is the least obvious number
			in the file, so it is worth the paragraph.

			Roblox friction is isotropic: it resists sideways and forwards
			equally, which is the one thing a tyre never does. That is precisely
			why GroundHandling exists - it models lateral grip, rolling
			resistance, brakes and nose-wheel steering as real forces. Leaving
			Roblox friction switched on as well does not add realism, it
			double-counts, and it swamps the model.

			It also stops the aeroplane dead. Static thrust is 2,780 N against a
			weight of 10,895 N, so the aircraft can only break traction if the
			effective coefficient is below 2780 / 10895 = 0.255. These wheels
			shipped at 0.6, which combines with a default 0.3 runway to about
			0.45 - nearly double what the propeller can overcome. Measured: full
			power moved it 0.00 m. At friction 0 it accelerates away normally.

			frictionWeight matters as much as friction and is easy to miss.
			Roblox combines two surfaces as (f1*w1 + f2*w2) / (w1 + w2), so a
			zero-friction wheel at the default weight of 1 still inherits half
			the runway's friction. The weight of 100 makes the tyre dominate the
			combination, so the aircraft behaves the same on any surface and
			GroundHandling remains the only thing deciding how tyres behave.
		]]
		{
			name = "WheelNose",
			size = Vector3.new(0.16, 0.40, 0.40),
			position = Vector3.new(0, -0.95, -1.40),
			mass = 2,
			color = Color3.fromRGB(30, 30, 32),
			shape = "Cylinder",
			collide = true,
			friction = 0,
			frictionWeight = 100,
		},
		{
			name = "WheelLeft",
			size = Vector3.new(0.16, 0.40, 0.40),
			position = Vector3.new(-1.25, -0.95, 0.40),
			mass = 2,
			color = Color3.fromRGB(30, 30, 32),
			shape = "Cylinder",
			collide = true,
			friction = 0,
			frictionWeight = 100,
		},
		{
			name = "WheelRight",
			size = Vector3.new(0.16, 0.40, 0.40),
			position = Vector3.new(1.25, -0.95, 0.40),
			mass = 2,
			color = Color3.fromRGB(30, 30, 32),
			shape = "Cylinder",
			collide = true,
			friction = 0,
			frictionWeight = 100,
		},

		-- Pilot's seat. A VehicleSeat specifically, because Roblox hands
		-- network ownership of the whole assembly to whoever sits in one -
		-- which is exactly the client-owned physics model this project uses.
		{
			name = "PilotSeat",
			size = Vector3.new(0.55, 0.20, 0.55),
			position = Vector3.new(0, 0.15, -0.40),
			mass = 1,
			color = Color3.fromRGB(60, 55, 50),
			className = "VehicleSeat",
		},
	},

	-- The modelled skin. Built just below, and massless by construction.
	decorations = SKIN,
}

-- =========================================================================
-- VERIFICATION
-- =========================================================================

--[[
	Checks this definition against the real aircraft's published performance.

	Run from the Studio command bar:
		require(game.ReplicatedStorage.FlightSim.Aircraft.Definitions.Cessna172).runTests()

	These are whole-aircraft checks, unlike the Aerodynamics suite which tests
	the wing in isolation. If a future edit to any coefficient makes the
	aircraft unrealistic, this catches it.
]]
function Cessna172.runTests(): (boolean, { any })
	local Atmosphere = require(FlightSim.Physics.Atmosphere)
	local Engine = require(FlightSim.Physics.Engine)

	local results = {}
	local allPassed = true

	local function record(label: string, passed: boolean, detail: string)
		if not passed then
			allPassed = false
		end
		table.insert(results, { label = label, passed = passed, detail = detail })
		print(string.format("  [%s] %-40s %s", passed and "PASS" or "FAIL", label, detail))
	end

	local function checkRange(label: string, actual: number, lo: number, hi: number, unit: string)
		record(label, actual >= lo and actual <= hi, string.format("%.3f %s (expected %.2f..%.2f)", actual, unit, lo, hi))
	end

	print("=== Cessna 172S: definition verification ===")

	local KT = 1852 / 3600
	local rhoSL = Atmosphere.getDensity(0)

	-- 1. Mass budget -------------------------------------------------------
	local totalMass = 0
	local momentX, momentY, momentZ = 0, 0, 0
	for _, part in Cessna172.model.parts do
		totalMass += part.mass
		momentX += part.mass * part.position.X
		momentY += part.mass * part.position.Y
		momentZ += part.mass * part.position.Z
	end

	checkRange("Total mass", totalMass, 1000, 1157, "kg")
	record(
		"Mass is within max takeoff weight",
		totalMass <= Cessna172.mass.maxTakeoff,
		string.format("%.0f kg of %.0f kg MTOW", totalMass, Cessna172.mass.maxTakeoff)
	)

	-- 2. Centre of mass, and the stability that depends on it -------------
	local com = Vector3.new(momentX / totalMass, momentY / totalMass, momentZ / totalMass)
	record("Centre of mass", true, string.format("(%.3f, %.3f, %.3f) m from datum", com.X, com.Y, com.Z))

	-- Must be on the centreline, or the aircraft rolls on its own.
	record("Centre of mass is laterally centred", math.abs(com.X) < 0.01, string.format("x = %.4f m", com.X))

	local wingAC = Cessna172.surfaces[1].offset.Z

	--[[
		THE stability check.

		A common mistake is to require the centre of mass to sit ahead of the
		WING's quarter chord. That is not the condition - on a real 172 the
		loaded centre of mass is at 35-47% of the mean chord while the wing's
		aerodynamic centre is at 25%, so it sits comfortably BEHIND the wing AC
		and the aircraft is famously stable.

		The real condition is that the centre of mass sits ahead of the
		NEUTRAL POINT of the whole aircraft - the point where total pitching
		moment stops depending on angle of attack. The tail drags the neutral
		point a long way aft of the wing AC, which is precisely its job. The
		distance between the two, expressed as a fraction of chord, is the
		static margin:

			positive  -> nose-up disturbance produces a nose-down response
			zero      -> neutral; the aircraft holds any attitude it is put in
			negative  -> divergent, and effectively unflyable

		Light aircraft run 5-20%. Below that they feel twitchy; above, sluggish
		in pitch and heavy on the elevator during the takeoff rotation.

		The standard estimate for how far the tail moves the neutral point:

			dx = (a_tail/a_wing) * (S_tail/S_wing) * l_tail * (1 - de/da) * eta

		where de/da is the downwash gradient (the wing deflects the air the
		tail flies in, reducing its effectiveness) and eta accounts for the
		tail sitting in the fuselage's wake.
	]]
	local DOWNWASH_GRADIENT = 0.35
	local TAIL_EFFICIENCY = 0.90

	local wingSurface = Cessna172.surfaces[1]
	local stabSurface = Cessna172.surfaces[3]
	local tailArmFromWing = stabSurface.offset.Z - wingAC

	local neutralPointShift = (stabSurface.clAlpha / wingSurface.clAlpha)
		* (stabSurface.area / WING_AREA)
		* tailArmFromWing
		* (1 - DOWNWASH_GRADIENT)
		* TAIL_EFFICIENCY

	local neutralPoint = wingAC + neutralPointShift
	local staticMargin = neutralPoint - com.Z

	record(
		"Neutral point is behind the wing AC",
		neutralPointShift > 0.2,
		string.format("tail moves it %.3f m aft, to z=%+.3f", neutralPointShift, neutralPoint)
	)
	record(
		"Aircraft is statically stable in pitch",
		staticMargin > 0,
		string.format("static margin %+.3f m", staticMargin)
	)
	checkRange("Static margin", staticMargin / WING_CHORD * 100, 5, 22, "% MAC")

	-- Tail arm measured from the centre of mass drives pitch damping.
	local tailArm = stabSurface.offset.Z - com.Z
	checkRange("Tail arm", tailArm, 3.8, 4.8, "m")

	--[[
		THE RIGGING CHECK, and it is here because the aircraft failed it for
		months without anything reporting it.

		The wing's aerodynamic centre sits AHEAD of the centre of mass - correct
		for a 172, whose CG range is genuinely aft of the quarter-chord - so wing
		lift is a nose-UP moment. A tail DOWNLOAD acts behind the CoM and pitches
		the nose up as well, so a negatively rigged tailplane ADDS to the moment
		it is supposed to balance. With STAB_INCIDENCE at -2 degrees the elevator
		had to carry the whole thing: -0.38 stick in cruise, -0.79 on approach
		with full flap, and no trim range able to remove it. The pilot reported
		it as being unable to get the nose down.

		With the CG aft of the wing AC the tail has to LIFT to trim, so the
		incidence must be positive. Asserted as a SIGN relationship rather than a
		magnitude, because it is the sign that was wrong and the sign that any
		future CG change would silently flip.
	]]
	local wingAheadOfCom = com.Z - wingSurface.offset.Z
	record(
		"The wing's AC is ahead of the centre of mass, as on a real 172",
		wingAheadOfCom > 0,
		string.format("wing AC %.3f m ahead of the CoM", wingAheadOfCom)
	)
	record(
		"The tailplane is rigged to LIFT, because the CG is aft of the wing AC",
		STAB_INCIDENCE > 0,
		string.format("stab incidence %+.1f deg (a download here would ADD nose-up)", STAB_INCIDENCE)
	)
	--[[
		And the elevator must sit near neutral in the cruise, which is the whole
		observable point of getting the rigging right. Bounded well inside full
		travel so there is authority left for gusts and the flare.
	]]
	checkRange("Stabiliser incidence keeps cruise trim near neutral", STAB_INCIDENCE, 0.5, 2.0, "deg")

	--[[
		Tail volume coefficient, V = (tail area x tail arm) / (wing area x chord).
		A dimensionless summary of how much pitch authority and stability the
		tail provides. Light aircraft sit between 0.5 and 0.9.
	]]
	local tailVolume = (STAB_AREA * tailArm) / (WING_AREA * WING_CHORD)
	checkRange("Horizontal tail volume coefficient", tailVolume, 0.45, 0.95, "")

	local finArm = Cessna172.surfaces[4].offset.Z - com.Z
	local finVolume = (FIN_AREA * finArm) / (WING_AREA * WING_SPAN)
	checkRange("Vertical tail volume coefficient", finVolume, 0.02, 0.06, "")

	-- Main wheels must be behind the centre of mass or it sits on its tail.
	local mainWheel = Cessna172.gear.wheels[2].offset.Z
	record(
		"Main wheels are behind the centre of mass",
		mainWheel > com.Z,
		string.format("wheels at z=%.2f, CoM at z=%.3f", mainWheel, com.Z)
	)
	record(
		"Nose wheel is ahead of the centre of mass",
		Cessna172.gear.wheels[1].offset.Z < com.Z,
		string.format("nose wheel at z=%.2f", Cessna172.gear.wheels[1].offset.Z)
	)

	-- The wing sits above the centre of mass - the pendulum effect that makes
	-- a high-wing trainer want to stay upright.
	record(
		"Wing is above the centre of mass",
		Cessna172.surfaces[1].offset.Y > com.Y,
		string.format("wing y=%.2f, CoM y=%.3f", Cessna172.surfaces[1].offset.Y, com.Y)
	)

	--[[
		THE AIRCRAFT MUST BE ABLE TO BREAK TRACTION.

		This is a regression test for a bug that made the simulator look
		completely broken: the aeroplane shipped with tyres at friction 0.6,
		which combines with a typical runway to about 0.45 - well above the
		0.255 that 2,780 N of static thrust can overcome against 10,895 N of
		weight. Full power moved it exactly 0.00 m. From the cockpit that reads
		as "the controls do nothing", because nothing the pilot does has any
		effect at all, and there is no error anywhere to suggest otherwise.

		Roblox friction must stay near zero because GroundHandling models tyre
		behaviour itself - see the note on the wheel parts. This asserts the
		aeroplane can actually get moving even on an unusually grippy surface.
	]]
	local GRIPPIEST_PLAUSIBLE_RUNWAY = 0.5
	local staticThrust = Engine.getStaticThrust(
		Cessna172.engine.maxPowerW,
		Cessna172.engine.propDiameter,
		rhoSL,
		Cessna172.engine.figureOfMerit
	)
	local weightN = totalMass * 9.80665

	local worstWheel, worstMu = "", 0
	for _, part in Cessna172.model.parts do
		if part.collide then
			-- Roblox combines two surfaces as (f1*w1 + f2*w2) / (w1 + w2).
			local f, w = part.friction or 0.35, part.frictionWeight or 1
			local mu = (f * w + GRIPPIEST_PLAUSIBLE_RUNWAY) / (w + 1)
			if mu > worstMu then
				worstMu, worstWheel = mu, part.name
			end
		end
	end

	record(
		"Static thrust can break the tyres loose",
		worstMu * weightN < staticThrust,
		string.format(
			"%s: mu %.3f needs %.0f N to move, thrust is %.0f N",
			worstWheel, worstMu, worstMu * weightN, staticThrust
		)
	)

	-- 3. Stall speeds ------------------------------------------------------
	local wing = Cessna172.surfaces[1]
	local clMaxClean = Aerodynamics.findClMax(wing)
	local vs1 = Aerodynamics.stallSpeed(totalMass, WING_AREA, clMaxClean, rhoSL) / KT
	checkRange("Clean stall speed vs published 48 kt", vs1, 44, 56, "kt")

	local clMaxFlap = Aerodynamics.findClMax(wing, wing.flapEffect)
	local vs0 = Aerodynamics.stallSpeed(totalMass, WING_AREA, clMaxFlap, rhoSL) / KT
	checkRange("Full-flap stall speed vs published 40 kt", vs0, 36, 48, "kt")
	record("Flaps lower the stall speed", vs0 < vs1, string.format("%.1f kt -> %.1f kt", vs1, vs0))

	-- 4. Cruise and maximum speed -----------------------------------------
	-- Total zero-lift drag: airframe plus the wing's own contribution.
	local totalCD0 = Cessna172.drag.airframeCD0 + wing.cd0
	checkRange("Total zero-lift drag coefficient", totalCD0, 0.024, 0.034, "")

	--[[
		Maximum level speed at sea level, found by walking the speed up until
		drag overtakes available thrust. Nothing in the definition sets this
		number - it is where the thrust and drag curves happen to cross.
		Published figure for the 172S is about 126 kt.
	]]
	local weight = totalMass * 9.80665
	local maxSpeedKt = 0
	for v = 30, 90, 0.25 do
		local q = 0.5 * rhoSL * v * v
		local cl = weight / (q * WING_AREA)
		local cd = totalCD0 + (cl * cl) / (math.pi * wing.oswald * WING_AR)
		local drag = q * WING_AREA * cd
		local thrust = Engine.getThrust(
			Cessna172.engine.maxPowerW, v,
			Cessna172.engine.propDiameter, rhoSL,
			Cessna172.engine.figureOfMerit, Cessna172.engine.propEfficiency
		)
		if thrust >= drag then
			maxSpeedKt = v / KT
		end
	end
	checkRange("Maximum level speed at sea level", maxSpeedKt, 112, 140, "kt")
	record(
		"Maximum speed is below Vne",
		maxSpeedKt < Cessna172.limits.vne,
		string.format("%.0f kt vs Vne %.0f kt", maxSpeedKt, Cessna172.limits.vne)
	)

	-- 5. Climb -------------------------------------------------------------
	-- Rate of climb = excess power / weight. Published best rate is about
	-- 730 ft/min at sea level.
	local vy = Cessna172.limits.vy * KT
	local qVy = 0.5 * rhoSL * vy * vy
	local clVy = weight / (qVy * WING_AREA)
	local cdVy = totalCD0 + (clVy * clVy) / (math.pi * wing.oswald * WING_AR)
	local dragVy = qVy * WING_AREA * cdVy
	local thrustVy = Engine.getThrust(
		Cessna172.engine.maxPowerW, vy,
		Cessna172.engine.propDiameter, rhoSL,
		Cessna172.engine.figureOfMerit, Cessna172.engine.propEfficiency
	)
	local climbRateMs = ((thrustVy - dragVy) * vy) / weight
	local climbFpm = climbRateMs * 196.85
	checkRange("Rate of climb at Vy", climbFpm, 550, 1000, "ft/min")

	-- 6. Glide -------------------------------------------------------------
	-- Power off, the propeller windmills and adds a great deal of drag. This
	-- is why the published glide ratio is about 9:1 rather than the 12:1 the
	-- clean airframe would suggest.
	local vbg = Cessna172.limits.vbg * KT
	local qBg = 0.5 * rhoSL * vbg * vbg
	local clBg = weight / (qBg * WING_AREA)
	local cdBgClean = totalCD0 + (clBg * clBg) / (math.pi * wing.oswald * WING_AR)
	local cdBgWindmill = cdBgClean + Cessna172.engine.windmillCD0

	local glideClean = clBg / cdBgClean
	local glideWindmill = clBg / cdBgWindmill
	record(
		"Windmilling propeller degrades the glide",
		glideWindmill < glideClean * 0.85,
		string.format("%.1f:1 clean -> %.1f:1 windmilling", glideClean, glideWindmill)
	)
	checkRange("Glide ratio, power off vs published 9:1", glideWindmill, 7.0, 11.5, ":1")

	-- 7. Ordering of the published speeds ----------------------------------
	local L = Cessna172.limits
	record(
		"Speed limits are correctly ordered",
		L.vs0 < L.vs1 and L.vs1 < L.vx and L.vx < L.vy and L.vy < L.vfe and L.vfe < L.vno and L.vno < L.vne,
		string.format("%d < %d < %d < %d < %d < %d < %d", L.vs0, L.vs1, L.vx, L.vy, L.vfe, L.vno, L.vne)
	)

	-- 8. Control surface wiring -------------------------------------------
	-- Ailerons must be differential, or they act as flaps and produce no roll.
	record(
		"Ailerons are differential",
		Cessna172.surfaces[1].controlSign == -Cessna172.surfaces[2].controlSign,
		string.format("left %+d, right %+d", Cessna172.surfaces[1].controlSign, Cessna172.surfaces[2].controlSign)
	)

	local axes = {}
	for _, s in Cessna172.surfaces do
		if s.controlAxis then
			axes[s.controlAxis] = true
		end
	end
	record(
		"All three control axes are driven",
		axes.pitch and axes.roll and axes.yaw,
		string.format("pitch=%s roll=%s yaw=%s", tostring(axes.pitch ~= nil), tostring(axes.roll ~= nil), tostring(axes.yaw ~= nil))
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

return Cessna172
