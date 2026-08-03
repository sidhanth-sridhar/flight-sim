--!strict
--[[
	Aerodynamics
	------------
	Per-surface lift and drag model. This is the heart of the simulator.

	THE ARCHITECTURAL DECISION
	--------------------------
	The tempting shortcut is to model the whole aircraft as one object: read
	the mouse, torque the body toward where the player is pointing, add a
	forward force for thrust. It works in an afternoon, and it can never be
	made to feel like an aircraft, because the aircraft has no idea which way
	it is actually moving through the air.

	Instead, an aircraft here is a collection of independent SURFACES - left
	wing, right wing, horizontal stabiliser, vertical fin - each mounted at
	its own position and angle. Every frame, each surface:

	  1. works out the airflow AT ITS OWN LOCATION, including the contribution
	     from the aircraft's rotation (this is the important part);
	  2. computes its own angle of attack from that local airflow;
	  3. produces its own lift and drag force, applied at its own position.

	Because the forces are applied off-centre, the moments that rotate the
	aircraft are never authored - they emerge. That single property gives us,
	for free and for correct physical reasons:

	  - Pitch stability. The tail sits behind the centre of mass, so if the
	    nose rises the tail meets the air at a higher angle, generates more
	    lift, and pushes the nose back down.
	  - Roll damping. Roll left and the descending left wing sees upward
	    airflow, raising its angle of attack and its lift, which opposes the
	    roll. This is why aircraft do not spin up indefinitely.
	  - Stalls that are directional. Drop one wing in a stall and only that
	    wing stalls, so it drops further - the aircraft departs into a spin,
	    exactly as a real one does.
	  - Adverse yaw, dutch roll, and the slow, heavy feel of low-speed
	    handling, because control authority scales with dynamic pressure.

	None of that behaviour appears anywhere in this file as a special case.

	UNITS: pure SI (metres, m/s, kg/m^3, newtons, radians). No studs.
]]

local Aerodynamics = {}

local sin = math.sin
local exp = math.exp
local atan2 = math.atan2
local sqrt = math.sqrt
local pi = math.pi

-- =========================================================================
-- TUNING CONSTANTS
-- =========================================================================

--[[
	How abruptly flow separates once the wing stalls. Higher = sharper break.

	40 gives a definite, feelable stall with a clear nose drop, without being
	so violent that recovery is impossible. Trainers stall gently (30-ish);
	swept-wing and high-performance aircraft break hard (50+).
]]
local DEFAULT_STALL_SHARPNESS = 40

--[[
	How far beyond the stall angle the separation blend is centred.

	The blend function is symmetric about its centre, so at the centre the
	surface has lost half its attached lift. If we centred it on alphaStall,
	peak lift would occur several degrees BEFORE alphaStall and CLmax would
	come out well below the real value.

	Offsetting the centre by ~3 degrees makes peak CL occur AT alphaStall,
	which is what "stall angle" means to a pilot and what published data
	reports. Verified in runTests().
]]
local STALL_BLEND_OFFSET = math.rad(3)

-- Below this airflow speed, aerodynamic forces are ignored entirely.
-- Avoids dividing by near-zero when parked, and stops a stationary aircraft
-- from jittering as noise-level velocities produce wild angles of attack.
local MIN_AIRFLOW_SPEED = 0.1 -- m/s

-- =========================================================================
-- TYPES
-- =========================================================================

export type Surface = {
	name: string,

	-- Geometry -----------------------------------------------------------
	area: number, -- m^2, planform area of THIS surface
	chord: number, -- m, mean aerodynamic chord (moment arms, Reynolds later)
	aspectRatio: number, -- span^2 / area of the COMPLETE surface (see note below)
	offset: Vector3, -- m, position relative to centre of mass, body axes
	forward: Vector3, -- unit, chord line pointing forward, body axes
	normal: Vector3, -- unit, direction of positive lift, body axes
	span: Vector3, -- unit, derived: spanwise axis (computed, do not set)

	-- Lift ---------------------------------------------------------------
	cl0: number, -- lift coefficient at zero angle of attack (camber)
	clAlpha: number, -- lift curve slope, per radian
	alphaStall: number, -- rad, positive stall angle (where CL peaks)
	alphaStallNeg: number, -- rad, negative stall angle, as a positive number
	stallSharpness: number,

	-- Drag ---------------------------------------------------------------
	cd0: number, -- parasitic drag coefficient at zero lift
	oswald: number, -- Oswald span efficiency, 0-1

	-- Controls -----------------------------------------------------------
	controlEffect: number, -- change in CL per unit control deflection (-1..1)
	flapEffect: number, -- change in CL per unit flap extension (0..1)
	flapDragEffect: number, -- change in CD0 at full flap

	-- Integration metadata ------------------------------------------------
	-- Ignored by the solver; read by FlightModel to decide which control axis
	-- drives this surface. Kept on the Surface itself rather than in a
	-- wrapper table so the per-frame loop stays flat.
	controlAxis: string?, -- "pitch" | "roll" | "yaw" | nil
	controlSign: number, -- +1 or -1; ailerons are differential, hence the sign
}

-- =========================================================================
-- AIRFOIL PRESETS
-- =========================================================================
--[[
	Starting coefficient sets. Individual aircraft definitions override what
	they need; these keep a surface definition down to a few meaningful lines.
]]

Aerodynamics.Airfoils = {
	-- NACA 2412 - the Cessna 172's wing. Cambered, so it makes lift at zero
	-- angle of attack, and stalls gently around 16 degrees.
	CAMBERED = {
		cl0 = 0.25,
		cd0 = 0.009,
		alphaStall = math.rad(16),
		alphaStallNeg = math.rad(14),
		oswald = 0.80,
		stallSharpness = 35,
	},

	-- NACA 0012 - symmetric, used for tailplanes and fins. Makes zero lift at
	-- zero angle of attack, which is exactly what a control surface wants:
	-- it should do nothing until it is asked to.
	SYMMETRIC = {
		cl0 = 0,
		cd0 = 0.008,
		alphaStall = math.rad(14),
		alphaStallNeg = math.rad(14),
		oswald = 0.75,
		stallSharpness = 40,
	},

	-- Thin flat plate. Stalls very early and drags heavily. For control
	-- surfaces, airbrakes and anything crude that still needs to feel air.
	FLAT = {
		cl0 = 0,
		cd0 = 0.02,
		alphaStall = math.rad(8),
		alphaStallNeg = math.rad(8),
		oswald = 0.60,
		stallSharpness = 50,
	},
}

-- =========================================================================
-- LIFT CURVE SLOPE
-- =========================================================================

--[[
	Lift curve slope of a finite wing, per radian.

	Thin aerofoil theory says an infinitely long wing has a slope of exactly
	2*pi per radian. Real wings are not infinite: air escapes around the tips,
	creating downwash that reduces the effective angle of attack. Prandtl's
	lifting-line correction gives:

		CL_alpha = 2*pi*AR / (AR + 2)

	For the Cessna's aspect ratio of 7.47 this yields about 4.96 per radian
	(0.087 per degree) - matching published data for the type.

	This is also why gliders have long thin wings: higher aspect ratio means a
	steeper lift slope and much less induced drag.
]]
function Aerodynamics.finiteWingLiftSlope(aspectRatio: number): number
	return (2 * pi * aspectRatio) / (aspectRatio + 2)
end

-- =========================================================================
-- SURFACE CONSTRUCTION
-- =========================================================================

--[[
	Build a validated Surface from a partial description.

	IMPORTANT - ASPECT RATIO ON SPLIT WINGS
	---------------------------------------
	A main wing is modelled as two surfaces so that roll damping and
	single-wing stalls work. When doing that, halve the AREA but pass the
	COMPLETE wing's aspect ratio, because induced drag and downwash depend on
	the full span, not on one panel. Passing the half-panel's aspect ratio is
	a common mistake that roughly doubles induced drag and produces an
	aircraft that mysteriously will not climb.
]]
function Aerodynamics.newSurface(props: { [string]: any }): Surface
	assert(props.name, "[Aerodynamics] surface needs a name")
	assert(props.area and props.area > 0, "[Aerodynamics] surface needs a positive area (m^2)")
	assert(props.aspectRatio and props.aspectRatio > 0, "[Aerodynamics] surface needs a positive aspectRatio")
	assert(props.offset, "[Aerodynamics] surface needs an offset from centre of mass (Vector3, metres)")

	-- Merge the chosen airfoil preset underneath any explicit overrides.
	local preset = props.airfoil or Aerodynamics.Airfoils.SYMMETRIC

	local function pick(key: string, fallback: any): any
		if props[key] ~= nil then
			return props[key]
		end
		if preset[key] ~= nil then
			return preset[key]
		end
		return fallback
	end

	-- Body axes. Roblox convention: -Z is forward, +Y is up.
	local forward = (props.forward or Vector3.new(0, 0, -1)).Unit
	local normal = (props.normal or Vector3.new(0, 1, 0)).Unit

	-- Re-orthogonalise: if a caller supplies a slightly non-perpendicular
	-- pair (easy to do when hand-authoring a canted fin), silently correcting
	-- it here is far better than letting a skewed basis corrupt every angle
	-- of attack that surface ever computes.
	local span = normal:Cross(forward)
	if span.Magnitude < 1e-6 then
		error("[Aerodynamics] surface '" .. tostring(props.name) .. "': forward and normal are parallel")
	end
	span = span.Unit
	normal = forward:Cross(span).Unit

	local aspectRatio = props.aspectRatio

	local surface: Surface = {
		name = props.name,

		area = props.area,
		chord = props.chord or sqrt(props.area / aspectRatio),
		aspectRatio = aspectRatio,
		offset = props.offset,
		forward = forward,
		normal = normal,
		span = span,

		cl0 = pick("cl0", 0),
		-- Default the slope from aspect ratio unless explicitly overridden.
		clAlpha = props.clAlpha or Aerodynamics.finiteWingLiftSlope(aspectRatio),
		alphaStall = pick("alphaStall", math.rad(15)),
		alphaStallNeg = pick("alphaStallNeg", math.rad(15)),
		stallSharpness = pick("stallSharpness", DEFAULT_STALL_SHARPNESS),

		cd0 = pick("cd0", 0.01),
		oswald = pick("oswald", 0.8),

		controlEffect = props.controlEffect or 0,
		flapEffect = props.flapEffect or 0,
		flapDragEffect = props.flapDragEffect or 0,

		controlAxis = props.controlAxis,
		controlSign = props.controlSign or 1,
	}

	return surface
end

--[[
	Build a surface set at a given incidence angle.

	Incidence is the angle at which a surface is bolted to the airframe,
	measured from the fuselage reference line. It is not cosmetic:

	  - The wing is rigged at about +1.5 degrees so the fuselage sits level in
	    cruise while the wing still meets the air at a useful angle. Without
	    it, level flight would mean flying permanently nose-up.
	  - The tailplane is rigged at a slight NEGATIVE angle, so it produces a
	    download that balances the nose-down pitching moment of a cambered
	    wing. This is a large part of why an aircraft is stable in pitch.

	Implemented by rotating the forward and normal vectors about the span
	axis, which keeps everything downstream - angle of attack, lift direction,
	stall - working with no special cases.
]]
function Aerodynamics.axesWithIncidence(incidenceDeg: number, spanAxis: Vector3?): (Vector3, Vector3)
	local i = math.rad(incidenceDeg)
	local axis = spanAxis or Vector3.new(1, 0, 0)
	-- Positive incidence must raise the leading edge, giving forward =
	-- (0, sin i, -cos i) and normal = (0, cos i, sin i) for a wing.
	local rotation = CFrame.fromAxisAngle(axis, i)
	return rotation * Vector3.new(0, 0, -1), rotation * Vector3.new(0, 1, 0)
end

-- =========================================================================
-- STALL MODEL
-- =========================================================================

--[[
	Separation blend factor: 0 = flow fully attached, 1 = fully separated.

	Two opposing sigmoids, one for each stall direction, combined so the
	result is ~0 through the normal flight envelope and rises smoothly to 1
	outside it. Adapted from the standard formulation in Beard & McLain,
	"Small Unmanned Aircraft: Theory and Practice".

	A smooth blend rather than a hard switch matters: a discontinuity in CL
	would make the aircraft snap violently at the stall and would wreck any
	numerical integration near that angle.
]]
local function separationFactor(alpha: number, surface: Surface): number
	local m = surface.stallSharpness
	local posCenter = surface.alphaStall + STALL_BLEND_OFFSET
	local negCenter = surface.alphaStallNeg + STALL_BLEND_OFFSET

	local ePos = exp(-m * (alpha - posCenter))
	local eNeg = exp(m * (alpha + negCenter))

	return (1 + ePos + eNeg) / ((1 + ePos) * (1 + eNeg))
end

Aerodynamics.separationFactor = separationFactor

-- =========================================================================
-- COEFFICIENTS
-- =========================================================================

--[[
	Lift coefficient at a given angle of attack.

	camberShift lets control surfaces and flaps do their job: deflecting a
	control surface changes the effective camber of the aerofoil, shifting the
	whole lift curve up or down without changing its slope. That is physically
	what a hinged trailing edge does, and it automatically reproduces two real
	behaviours we would otherwise have to fake:

	  - control authority scales with airspeed, because the shift is turned
	    into force by dynamic pressure;
	  - a deflected control brings the surface closer to its stall angle, so
	    hauling back on the yoke at low speed stalls the aircraft sooner.

	Attached flow is linear: CL = CL0 + CL_alpha * alpha
	Separated flow behaves like a flat plate: CL = sin(2*alpha)
	The two are blended by separationFactor.
]]
function Aerodynamics.liftCoefficient(alpha: number, surface: Surface, camberShift: number?): number
	local shift = camberShift or 0

	local attached = surface.cl0 + shift + surface.clAlpha * alpha

	-- Flat plate: peaks at 45 degrees, zero at 90 where the surface is edge
	-- on to the flow in the lift sense.
	local separated = sin(2 * alpha)

	local sigma = separationFactor(alpha, surface)
	return (1 - sigma) * attached + sigma * separated
end

--[[
	Drag coefficient. Three physically distinct contributions:

	  1. Parasitic (cd0) - skin friction and form drag. Roughly constant.
	  2. Induced - the price of making lift. Producing lift throws air
	     downward and sheds tip vortices, and that energy comes out of the
	     aircraft's forward motion:

	         CDi = CL^2 / (pi * e * AR)

	     Because it goes as CL SQUARED, it is negligible in fast cruise and
	     dominant when slow. This is the mechanism behind the "region of
	     reverse command": below a certain speed, flying slower requires MORE
	     power, not less. Landing approaches live there, and it is one of the
	     things that makes flying an aircraft feel like flying an aircraft.

	  3. Separation - once stalled, the surface behaves like a flat plate,
	     with CD peaking near 2.0 when broadside to the flow. This is the
	     sudden deceleration felt at the stall.

	Note that parasitic drag sits OUTSIDE the separation blend, while only
	induced drag is blended out. Skin friction does not stop existing because
	the wing stalled. Blending it away leaves a genuine bug at the extremes:
	a surface in exactly reversed flow (alpha = 180 degrees, edge-on to the
	air) would produce mathematically zero drag and coast forever. Rare, but
	reachable in a tailslide or a fully developed spin, and "rare" is not the
	same as "never" once players start experimenting.
]]
function Aerodynamics.dragCoefficient(alpha: number, cl: number, surface: Surface, flapDeflection: number?): number
	local flap = flapDeflection or 0

	local parasitic = surface.cd0 + surface.flapDragEffect * flap
	local induced = (cl * cl) / (pi * surface.oswald * surface.aspectRatio)

	local s = sin(alpha)
	local separated = 2 * s * s

	local sigma = separationFactor(alpha, surface)
	return parasitic + (1 - sigma) * induced + sigma * separated
end

-- =========================================================================
-- RIGID BODY HELPER
-- =========================================================================

--[[
	Velocity of a specific point on a rotating rigid body:

		v_point = v_centreOfMass + omega x r

	This one cross product is what makes the whole model come alive. Without
	it, every surface would see identical airflow and the aircraft would have
	no rotational damping whatsoever - it would oscillate forever and be
	undampable by any amount of tuning.

	With it, rolling right means the right wing is moving downward through the
	air, so it meets the flow at a higher angle, makes more lift, and resists
	the roll. Real, correct, and free.

	All arguments in world space, SI units.
]]
function Aerodynamics.getPointVelocity(
	centerOfMassVelocity: Vector3,
	angularVelocity: Vector3,
	offsetFromCenterOfMass: Vector3
): Vector3
	return centerOfMassVelocity + angularVelocity:Cross(offsetFromCenterOfMass)
end

-- =========================================================================
-- MAIN SOLVER
-- =========================================================================

--[[
	Compute the aerodynamic force produced by one surface.

	Arguments
	  surface        the Surface definition
	  bodyCFrame     aircraft orientation (position is ignored; rotation only)
	  pointVelocity  velocity of this surface through the AIR, world space,
	                 m/s. Caller must subtract wind: (bodyVelocity - windVelocity)
	                 then add the omega x r term via getPointVelocity().
	  density        air density at the aircraft's altitude, kg/m^3
	  control        control surface deflection, -1 to 1
	  flap           flap extension, 0 to 1

	Returns (force, alpha, cl, cd, dynamicPressure)
	  force is a world-space vector in NEWTONS, to be applied at
	  surface.offset relative to the centre of mass.

	PERFORMANCE
	  Called once per surface per physics frame - typically 4 to 8 times per
	  aircraft per frame. Allocates no tables; returns multiple values rather
	  than a result table specifically to avoid per-frame garbage.
]]
function Aerodynamics.solveSurface(
	surface: Surface,
	bodyCFrame: CFrame,
	pointVelocity: Vector3,
	density: number,
	control: number?,
	flap: number?
): (Vector3, number, number, number, number)
	-- Airflow expressed in the aircraft's own axes.
	local vLocal = bodyCFrame:VectorToObjectSpace(pointVelocity)

	-- Resolve onto this surface's own axes. A canted or angled surface (a
	-- tailplane with incidence, a V-tail) is handled purely by its forward
	-- and normal vectors - no special cases anywhere else.
	local vForward = vLocal:Dot(surface.forward)
	local vNormal = vLocal:Dot(surface.normal)

	--[[
		Spanwise flow is deliberately discarded.

		This is "strip theory": a wing responds to the component of airflow in
		its chord plane, and air sliding along the span does little. It is why
		a sideslipping aircraft loses lift on the wing - and why the vertical
		fin, whose "span" is vertical, responds strongly to sideslip and
		provides weathervane stability.
	]]
	local speedSq = vForward * vForward + vNormal * vNormal
	local speed = sqrt(speedSq)

	if speed < MIN_AIRFLOW_SPEED then
		return Vector3.zero, 0, 0, 0, 0
	end

	--[[
		Angle of attack: the angle between the chord line and the oncoming air.

		Negating the normal component gives the sign convention pilots use -
		air arriving from below the wing is a POSITIVE angle of attack. An
		aircraft descending with its nose level has positive alpha, which is
		exactly how a glide works.

		Note this depends on the direction of travel, not on pitch attitude.
		That distinction is the entire reason an aircraft can be pointing up
		and still be falling.
	]]
	local alpha = atan2(-vNormal, vForward)

	-- Dynamic pressure, q = 0.5 * rho * V^2.
	local q = 0.5 * density * speedSq

	local camberShift = surface.controlEffect * (control or 0) + surface.flapEffect * (flap or 0)

	local cl = Aerodynamics.liftCoefficient(alpha, surface, camberShift)
	local cd = Aerodynamics.dragCoefficient(alpha, cl, surface, flap)

	local lift = q * surface.area * cl
	local drag = q * surface.area * cd

	--[[
		Force directions.

		Lift and drag are defined relative to the AIRFLOW, not the aircraft:
		drag acts directly along the relative wind, lift perpendicular to it.
		That is why lift tilts backward at high angle of attack, and why a
		steep turn needs so much extra lift to hold altitude.

		Working in the surface's 2D chord plane, the unit airflow direction is
		(vForward, vNormal)/speed. Drag opposes it. Lift is that rotated 90
		degrees, chosen so positive lift points along +normal at zero alpha.
	]]
	local invSpeed = 1 / speed
	local fComponent = vForward * invSpeed
	local nComponent = vNormal * invSpeed

	-- Drag direction: opposite to travel.
	local dragF = -fComponent
	local dragN = -nComponent

	-- Lift direction: drag rotated -90 degrees in the (forward, normal) plane.
	local liftF = dragN
	local liftN = -dragF

	local localForce = surface.forward * (lift * liftF + drag * dragF)
		+ surface.normal * (lift * liftN + drag * dragN)

	return bodyCFrame:VectorToWorldSpace(localForce), alpha, cl, cd, q
end

-- =========================================================================
-- ANALYSIS HELPERS
-- =========================================================================
-- Not used in the physics loop. These exist for tuning aircraft, validating
-- definitions, and populating the flight tablet with real performance data.

-- Highest lift coefficient a surface can reach, found by scanning. Returns
-- (clMax, alphaAtClMax in radians).
function Aerodynamics.findClMax(surface: Surface, camberShift: number?): (number, number)
	local best, bestAlpha = -math.huge, 0
	-- 0.1 degree steps from 0 to 40 degrees - well past any real stall.
	for i = 0, 400 do
		local alpha = math.rad(i * 0.1)
		local cl = Aerodynamics.liftCoefficient(alpha, surface, camberShift)
		if cl > best then
			best, bestAlpha = cl, alpha
		end
	end
	return best, bestAlpha
end

--[[
	Stall speed in m/s: the slowest the aircraft can fly and still produce
	lift equal to its weight.

		L = W  ->  0.5*rho*V^2*S*CLmax = m*g  ->  V = sqrt(2*m*g/(rho*S*CLmax))

	The classic consequences all fall out of this formula: stall speed rises
	with weight, rises with altitude as density falls, and rises with load
	factor in a turn (a 60 degree bank pulls 2g, raising stall speed by 41%).
]]
function Aerodynamics.stallSpeed(massKg: number, wingAreaM2: number, clMax: number, density: number, loadFactor: number?): number
	local g = 9.80665
	local n = loadFactor or 1
	return sqrt((2 * massKg * g * n) / (density * wingAreaM2 * clMax))
end

-- Angle of attack required for level flight at a given speed. Solves the
-- linear part of the lift curve, so it is only valid below the stall - which
-- is precisely the region where the answer is useful.
function Aerodynamics.trimAlphaForLevelFlight(
	massKg: number,
	wingAreaM2: number,
	surface: Surface,
	speedMs: number,
	density: number
): number
	local q = 0.5 * density * speedMs * speedMs
	local requiredCl = (massKg * 9.80665) / (q * wingAreaM2)
	return (requiredCl - surface.cl0) / surface.clAlpha
end

-- =========================================================================
-- VERIFICATION
-- =========================================================================

--[[
	Validates the model against known Cessna 172 numbers and against basic
	physical identities.

	Run from the Studio command bar:
		require(game.ReplicatedStorage.FlightSim.Physics.Aerodynamics).runTests()
]]
function Aerodynamics.runTests(): (boolean, { any })
	local Atmosphere = require(script.Parent.Atmosphere)

	local results = {}
	local allPassed = true

	local function record(label: string, passed: boolean, detail: string)
		if not passed then
			allPassed = false
		end
		table.insert(results, { label = label, passed = passed, detail = detail })
		print(string.format("  [%s] %-38s %s", passed and "PASS" or "FAIL", label, detail))
	end

	local function checkRange(label: string, actual: number, lo: number, hi: number, unit: string)
		record(label, actual >= lo and actual <= hi, string.format("%.4f %s (expected %.3f..%.3f)", actual, unit, lo, hi))
	end

	print("=== Aerodynamics: verification ===")

	-- Cessna 172S reference figures --------------------------------------
	local MASS = 1111 -- kg, maximum takeoff weight
	local WING_AREA = 16.2 -- m^2
	local WING_SPAN = 11.0 -- m
	local WING_AR = (WING_SPAN * WING_SPAN) / WING_AREA -- 7.47
	local RHO_SL = Atmosphere.getDensity(0)

	-- 1. Lift curve slope from aspect ratio ------------------------------
	local slope = Aerodynamics.finiteWingLiftSlope(WING_AR)
	checkRange("Lift slope, AR 7.47 (per rad)", slope, 4.85, 5.05, "/rad")
	checkRange("Lift slope (per degree)", math.rad(slope), 0.083, 0.090, "/deg")

	-- Infinite aspect ratio must approach the thin aerofoil limit of 2*pi.
	checkRange("Lift slope, AR 1000 -> 2*pi", Aerodynamics.finiteWingLiftSlope(1000), 6.25, 6.29, "/rad")

	-- 2. Build the reference wing ----------------------------------------
	local wing = Aerodynamics.newSurface({
		name = "TestWing",
		area = WING_AREA,
		aspectRatio = WING_AR,
		offset = Vector3.new(0, 0, 0),
		airfoil = Aerodynamics.Airfoils.CAMBERED,
		controlEffect = 0.5,
		flapEffect = 0.6,
		flapDragEffect = 0.045,
	})

	-- 3. Coefficients at known angles ------------------------------------
	-- A cambered aerofoil makes lift at zero angle of attack.
	checkRange("CL at alpha 0 (cambered)", Aerodynamics.liftCoefficient(0, wing), 0.24, 0.26, "")

	local tail = Aerodynamics.newSurface({
		name = "TestTail",
		area = 2.0,
		aspectRatio = 4.0,
		offset = Vector3.new(0, 0, 4),
		airfoil = Aerodynamics.Airfoils.SYMMETRIC,
		controlEffect = 0.7,
	})
	-- A symmetric aerofoil makes none. Anything else means the tail would
	-- pitch the aircraft while doing nothing.
	record(
		"CL at alpha 0 (symmetric) is zero",
		math.abs(Aerodynamics.liftCoefficient(0, tail)) < 1e-9,
		string.format("%.10f", Aerodynamics.liftCoefficient(0, tail))
	)

	-- Symmetry: a symmetric aerofoil must mirror exactly about zero.
	local clPos = Aerodynamics.liftCoefficient(math.rad(5), tail)
	local clNeg = Aerodynamics.liftCoefficient(math.rad(-5), tail)
	record(
		"Symmetric aerofoil is antisymmetric",
		math.abs(clPos + clNeg) < 1e-6,
		string.format("+5deg=%.5f, -5deg=%.5f", clPos, clNeg)
	)

	-- 4. THE STALL -------------------------------------------------------
	-- Peak lift must occur at the stated stall angle, and reach the CLmax
	-- published for this aerofoil. This is the check that matters most.
	local clMax, alphaAtMax = Aerodynamics.findClMax(wing)
	checkRange("CLmax (clean)", clMax, 1.40, 1.65, "")
	checkRange("Alpha at CLmax", math.deg(alphaAtMax), 14.0, 18.0, "deg")

	-- Lift must actually COLLAPSE past the stall, not merely stop rising.
	local clDeep = Aerodynamics.liftCoefficient(math.rad(25), wing)
	record(
		"Lift collapses after stall",
		clDeep < clMax * 0.75,
		string.format("CL 25deg = %.3f vs CLmax %.3f (%.0f%%)", clDeep, clMax, clDeep / clMax * 100)
	)

	-- Drag must rise steeply once separated - the deceleration you feel.
	local cdCruise = Aerodynamics.dragCoefficient(math.rad(2), Aerodynamics.liftCoefficient(math.rad(2), wing), wing)
	local cdStalled = Aerodynamics.dragCoefficient(math.rad(25), clDeep, wing)
	record(
		"Drag rises sharply in stall",
		cdStalled > cdCruise * 5,
		string.format("cruise %.4f -> stalled %.4f (%.1fx)", cdCruise, cdStalled, cdStalled / cdCruise)
	)

	-- Flow must be fully attached in normal flight and fully separated well
	-- past the stall, or the blend is mistuned.
	record(
		"Flow attached at cruise alpha",
		separationFactor(math.rad(2), wing) < 0.02,
		string.format("sigma = %.5f", separationFactor(math.rad(2), wing))
	)
	record(
		"Flow separated at 35 deg",
		separationFactor(math.rad(35), wing) > 0.98,
		string.format("sigma = %.5f", separationFactor(math.rad(35), wing))
	)

	-- 5. Real-world performance ------------------------------------------
	-- A C172 stalls clean at 48-51 knots. This falls out of CLmax and wing
	-- loading with nothing tuned to produce it, so it is a genuine test of
	-- whether the whole model is physically consistent.
	local vStall = Aerodynamics.stallSpeed(MASS, WING_AREA, clMax, RHO_SL)
	local vStallKt = vStall / (1852 / 3600)
	checkRange("Clean stall speed", vStallKt, 46, 56, "kt")

	-- With full flap, CLmax rises and stall speed drops to around 40 knots.
	local clMaxFlap = Aerodynamics.findClMax(wing, wing.flapEffect * 1.0)
	local vStallFlapKt = Aerodynamics.stallSpeed(MASS, WING_AREA, clMaxFlap, RHO_SL) / (1852 / 3600)
	record(
		"Full flap lowers stall speed",
		vStallFlapKt < vStallKt - 3,
		string.format("%.1f kt flapped vs %.1f kt clean", vStallFlapKt, vStallKt)
	)

	-- A 60 degree bank is a 2g turn, which raises stall speed by sqrt(2).
	local vStall2g = Aerodynamics.stallSpeed(MASS, WING_AREA, clMax, RHO_SL, 2)
	record(
		"2g turn raises stall speed 41%",
		math.abs(vStall2g / vStall - sqrt(2)) < 0.01,
		string.format("%.2fx", vStall2g / vStall)
	)

	-- Cruise: a C172 at 120 kt should need only a degree or two of alpha.
	local cruiseMs = 120 * (1852 / 3600)
	local trimAlpha = Aerodynamics.trimAlphaForLevelFlight(MASS, WING_AREA, wing, cruiseMs, RHO_SL)
	checkRange("Trim alpha at 120 kt cruise", math.deg(trimAlpha), -1.0, 4.0, "deg")

	-- ...and near the stall it should need close to the stall angle.
	local slowAlpha = Aerodynamics.trimAlphaForLevelFlight(MASS, WING_AREA, wing, vStall * 1.02, RHO_SL)
	checkRange("Trim alpha just above stall", math.deg(slowAlpha), 12.0, 20.0, "deg")

	-- 6. Induced drag behaviour ------------------------------------------
	-- Induced drag must dominate when slow and vanish when fast. This is the
	-- "region of reverse command" that defines how an approach is flown.
	local cdSlow = Aerodynamics.dragCoefficient(slowAlpha, Aerodynamics.liftCoefficient(slowAlpha, wing), wing)
	local cdFast = Aerodynamics.dragCoefficient(trimAlpha, Aerodynamics.liftCoefficient(trimAlpha, wing), wing)
	record(
		"Induced drag dominates when slow",
		cdSlow > cdFast * 3,
		string.format("CD slow %.4f vs CD cruise %.4f (%.1fx)", cdSlow, cdFast, cdSlow / cdFast)
	)

	-- 7. Vector solver ---------------------------------------------------
	-- Straight and level at cruise: lift should be within a few percent of
	-- weight, and drag should oppose motion.
	local level = CFrame.identity
	local velocity = Vector3.new(0, 0, -cruiseMs) -- -Z is forward
	local force, alpha, cl, cd, q = Aerodynamics.solveSurface(wing, level, velocity, RHO_SL)

	record(
		"Solver: alpha is zero in level flight",
		math.abs(alpha) < 1e-9,
		string.format("alpha = %.10f rad", alpha)
	)
	checkRange("Solver: dynamic pressure at 120 kt", q, 2300, 2360, "Pa")

	-- At zero alpha the cambered wing makes ~9.4 kN against a ~10.9 kN
	-- weight, so it should be close to but slightly below level flight.
	checkRange("Solver: lift at cruise", force.Y, 8500, 10500, "N")

	-- Drag must point backward (+Z), opposing the -Z motion.
	record(
		"Solver: drag opposes motion",
		force.Z > 0,
		string.format("Fz = %.1f N (positive = rearward)", force.Z)
	)

	-- No sideways force from a symmetric, non-sideslipping case.
	record("Solver: no lateral force", math.abs(force.X) < 1e-6, string.format("Fx = %.9f N", force.X))

	--[[
		Lift/drag ratio of the WING IN ISOLATION - around 20:1 at zero alpha,
		peaking near 23:1.

		That looks too good next to the Cessna's published ~9:1 glide ratio,
		but the two numbers measure different things. This is a bare wing:
		CD is 0.009 parasitic plus 0.0033 induced and nothing else. The real
		aircraft also drags a fuselage, wing struts, fixed landing gear, a
		tail and the interference between them - roughly doubling total
		parasitic drag while contributing no lift.

		So the whole-airframe figure will land in the 9-11 range once the
		fuselage drag body is added in Phase 1. THAT is the number to check
		against the real aircraft; this one just confirms the wing itself is
		efficient and the drag polar is the right shape.
	]]
	local ldRatio = force.Y / force.Z
	checkRange("Solver: wing-alone L/D at cruise", ldRatio, 15, 25, ":1")

	-- 8. Rotational damping ----------------------------------------------
	-- The mechanism that makes the aircraft stable. A wing offset to the
	-- side, on a rolling body, must meet the air at a different angle than
	-- the same wing when not rolling - which is what opposes the roll.
	local rightWing = Aerodynamics.newSurface({
		name = "RightWing",
		area = WING_AREA / 2,
		aspectRatio = WING_AR,
		offset = Vector3.new(2.75, 0, 0),
		airfoil = Aerodynamics.Airfoils.CAMBERED,
	})

	local rollRate = Vector3.new(0, 0, 1) -- rad/s about the forward axis
	local vRolling = Aerodynamics.getPointVelocity(velocity, rollRate, rightWing.offset)
	local _, alphaRolling = Aerodynamics.solveSurface(rightWing, level, vRolling, RHO_SL)
	local _, alphaStatic = Aerodynamics.solveSurface(rightWing, level, velocity, RHO_SL)

	record(
		"Roll changes local angle of attack",
		math.abs(alphaRolling - alphaStatic) > 1e-4,
		string.format("static %.3f deg -> rolling %.3f deg", math.deg(alphaStatic), math.deg(alphaRolling))
	)

	-- 9. Numerical safety -------------------------------------------------
	-- A parked aircraft must produce exactly zero force, not NaN.
	local zeroForce = Aerodynamics.solveSurface(wing, level, Vector3.zero, RHO_SL)
	record("Zero airspeed produces zero force", zeroForce == Vector3.zero, tostring(zeroForce))

	-- Extreme angles must stay finite. A NaN force permanently destroys a
	-- Roblox assembly, so this is a genuine crash-prevention check.
	local extreme = Aerodynamics.solveSurface(wing, level, Vector3.new(0, 200, -1), RHO_SL)
	record(
		"Extreme angle stays finite",
		extreme.Magnitude == extreme.Magnitude and extreme.Magnitude < math.huge,
		string.format("|F| = %.1f N", extreme.Magnitude)
	)

	-- Reversed flow (flying backwards, as in a tailslide) must stay finite
	-- AND must still produce drag. A surface that generates exactly zero
	-- force in reversed flow would coast forever - see dragCoefficient.
	local reversed = Aerodynamics.solveSurface(wing, level, Vector3.new(0, 0, cruiseMs), RHO_SL)
	record(
		"Reversed flow stays finite",
		reversed.Magnitude == reversed.Magnitude and reversed.Magnitude < math.huge,
		string.format("|F| = %.1f N", reversed.Magnitude)
	)
	record(
		"Reversed flow still produces drag",
		reversed.Magnitude > 100,
		string.format("|F| = %.1f N (must be non-zero)", reversed.Magnitude)
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

return Aerodynamics
