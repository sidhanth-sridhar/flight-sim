--!strict
--[[
	FlightModel
	-----------
	The integrator. Everything else in Physics/ computes numbers; this module
	is what actually makes an aeroplane move.

	Once per frame, on the pilot's client, it:

	  1. reads the assembly's true state from Roblox,
	  2. asks each aerodynamic surface what force it is producing,
	  3. sums those into ONE resultant force and ONE resultant torque,
	  4. adds thrust, propeller effects and airframe drag,
	  5. writes the result to the AeroForce / AeroTorque constraints.

	WHY FORCE AND TORQUE ARE SEPARATED
	----------------------------------
	The AeroForce constraint has ApplyAtCenterOfMass = true, so it produces
	pure translation and no rotation whatsoever. Every rotation the aircraft
	experiences therefore comes from the torque we compute here, as

		tau = sum over surfaces of (r x F)

	where r is the surface's offset from the CENTRE OF MASS. That is the whole
	mechanism: we never author a pitching moment, a roll rate or a yaw
	response. They are the arithmetic consequence of where the forces act.

	Get r wrong - measure it from the root part, or from the datum, instead of
	from the centre of mass - and the aircraft will still fly, but its
	stability will be quietly wrong in a way no amount of coefficient tuning
	can fix. See the frames note below.

	WHAT THIS MODULE DELIBERATELY DOES NOT DO
	-----------------------------------------
	  - Gravity. Workspace.Gravity is set to 9.80665 at startup and Roblox
	    applies weight itself. Adding it here would double it.
	  - Ground handling: wheel steering, braking, rolling resistance. Contact
	    is Roblox's rigid body solver against the collidable wheels; the
	    steering and braking forces belong in a separate GroundHandling module
	    so that this one stays a pure air model.
	  - Input. Controls arrive as a plain table of numbers, already smoothed.
	    This module has no idea a mouse exists.

	UNITS
	-----
	Pure SI internally: metres, m/s, radians, newtons, newton-metres. The ONLY
	place studs appear is the boundary - reading velocity and position out of
	Roblox, and writing force and torque back in. Both go through Shared/Units.
]]

local FlightSim = script.Parent.Parent

local Aerodynamics = require(FlightSim.Physics.Aerodynamics)
local Atmosphere = require(FlightSim.Physics.Atmosphere)
local Engine = require(FlightSim.Physics.Engine)
local Constants = require(FlightSim.Config.Constants)
local MathUtil = require(FlightSim.Shared.MathUtil)
local Units = require(FlightSim.Shared.Units)

local FlightModel = {}

local sanitizeVector = MathUtil.sanitizeVector
local clampMagnitude = MathUtil.clampMagnitude

-- =========================================================================
-- SAFETY LIMITS
-- =========================================================================

--[[
	Hard ceiling on the acceleration the model may command, in g.

	This is not a flight envelope - the aircraft's own structural limits are
	in definition.limits and belong to a damage model. This is a numerical
	backstop. If a bad frame ever produces an absurd force, the alternative to
	clamping is an assembly flung several kilometres in one step, or velocities
	large enough to go non-finite on the next frame.

	20 g is far outside anything reachable in normal flight (a deliberate
	high-speed pull-up in the Cessna tops out near 4 g), so the clamp is
	invisible in practice and only bites when something has already gone wrong.
]]
local MAX_ACCEL_G = 20

-- Same idea for rotation: an angular acceleration ceiling in rad/s^2, applied
-- via a torque limit scaled by the aircraft's size and mass.
local MAX_ANGULAR_ACCEL = 40

-- =========================================================================
-- TYPES
-- =========================================================================

export type Controls = {
	pitch: number, -- -1..1, positive = nose up (pull back)
	roll: number, -- -1..1, positive = roll right
	yaw: number, -- -1..1, positive = nose right
	throttle: number, -- 0..1
	flaps: number, -- 0..1, fraction of full flap deflection
	brake: number, -- 0..1, consumed by GroundHandling, carried here for telemetry
}

export type Environment = {
	windVelocity: Vector3?, -- m/s, world space. The air mass's own motion.
	tempOffsetC: number?, -- ISA deviation, from the weather system
}

--[[
	The aircraft's physical state, in SI, as read from Roblox.

	Passing this in rather than reading it inside the solver is what makes the
	whole model testable: runTests() feeds synthetic kinematics and asserts on
	the resulting forces, with no dependence on Roblox actually simulating
	anything.
]]
export type Kinematics = {
	cframe: CFrame, -- body orientation (position ignored except for altitude)
	velocity: Vector3, -- centre of mass velocity, m/s, world
	angularVelocity: Vector3, -- rad/s, world
	altitude: number, -- m above sea level

	--[[
		The y of the ground directly beneath, or nil when there is none within
		reach. Consumed only by ground effect.

		It arrives HERE, in the kinematics, rather than being raycast inside
		computeForces - and that placement is the whole point. computeForces is
		pure: it reads nothing from the datamodel, which is what lets the test
		suite assert on pitch stability, roll damping and weathervaning without
		Roblox simulating anything. A raycast inside it would end that property
		for one term. readKinematics is already the impure half, so the ray goes
		there and the number travels in like every other measurement.

		nil means "no ground found within a wingspan", which is a real answer and
		not a missing one: with no ground below, there is no ground effect.
	]]
	groundY: number?,
}

local DEFAULT_CONTROLS: Controls = {
	pitch = 0,
	roll = 0,
	yaw = 0,
	throttle = 0,
	flaps = 0,
	brake = 0,
}

-- =========================================================================
-- CONSTRUCTION
-- =========================================================================

--[[
	THE THREE FRAMES - this is where the bugs live.

	  datum      arbitrary point near the cabin centre. Every offset in the
	             aircraft definition is measured from here.
	  root part  what Roblox measures from. Sits at `DatumOffset` in datum
	             coordinates - the attribute AircraftBuilder writes at build.
	  CoM        what moment arms MUST be measured from. Roblox computes it
	             from the real part layout, so it is not a number we choose.

	Converting between them:

	  rootLocal = datum - datumOffset
	  comDatum  = comLocal + datumOffset
	  armFromCoM = surfaceOffsetDatum - comDatum

	These are resolved once here, at spawn, and cached. Doing it per frame
	would be pure waste: the part layout does not change in flight (our fuel is
	a number, not a part, so burning it does not shift the centre of mass).
]]
function FlightModel.new(model: Model, definition: any)
	local root = model.PrimaryPart
	assert(root, "[FlightModel] model has no PrimaryPart")

	local aeroForce = root:FindFirstChild("AeroForce") :: VectorForce?
	local aeroTorque = root:FindFirstChild("AeroTorque") :: Torque?
	assert(aeroForce, "[FlightModel] root has no AeroForce constraint - build it with AircraftBuilder")
	assert(aeroTorque, "[FlightModel] root has no AeroTorque constraint - build it with AircraftBuilder")

	local datumOffset = root:GetAttribute("DatumOffset") :: Vector3? or Vector3.zero
	local comLocal = root.CFrame:PointToObjectSpace(root.AssemblyCenterOfMass)
	local comDatum = comLocal + datumOffset

	-- Resolve each surface's moment arm about the centre of mass, once.
	local surfaces = {}
	local surfaceTelemetry = {}
	for i, surface in definition.surfaces do
		surfaces[i] = {
			surface = surface,
			arm = surface.offset - comDatum,
		}
		surfaceTelemetry[i] = {
			name = surface.name,
			alpha = 0,
			cl = 0,
			cd = 0,
			q = 0,
			force = Vector3.zero,
		}
	end

	local mass = root.AssemblyMass

	--[[
		How far down readKinematics has to look for the ground.

		Ground effect is identically 1 at and above one wingspan, so a ray longer
		than the largest declared span could only find ground that cannot matter.
		The 20% margin covers the aircraft being nose-high with a wing lower than
		the centre of mass, which is exactly the attitude a flare is flown in.

		Zero when no surface declares a span, and then no ray is cast at all -
		an aircraft with no ground effect pays nothing for the feature.
	]]
	local groundProbeReach = 0
	for _, entry in surfaces do
		local span = entry.surface.groundEffectSpan
		if span and span > groundProbeReach then
			groundProbeReach = span
		end
	end
	groundProbeReach *= 1.2

	local probeParams = RaycastParams.new()
	probeParams.FilterType = Enum.RaycastFilterType.Exclude
	probeParams.FilterDescendantsInstances = { model }
	probeParams.IgnoreWater = false

	-- The main wing is the largest surface by area on anything that flies, and
	-- its stall angle is the one an instrument needs to mark.
	local stallAlpha, largestArea = 0, 0
	for _, entry in surfaces do
		if entry.surface.area > largestArea then
			largestArea = entry.surface.area
			stallAlpha = entry.surface.alphaStall
		end
	end

	local state = {
		model = model,
		definition = definition,
		root = root,
		aeroForce = aeroForce,
		aeroTorque = aeroTorque,

		groundProbeReach = groundProbeReach,
		groundProbeParams = probeParams,

		-- Cached geometry (body frame, metres)
		datumOffset = datumOffset,
		comLocal = comLocal,
		comDatum = comDatum,
		surfaces = surfaces,
		thrustArm = definition.engine.thrustOffset - comDatum,

		mass = mass,
		engine = Engine.createState(definition.engine),

		--[[
			Telemetry is written into a table owned by the state, not returned
			fresh each frame. At 240 fps a new table per frame per aircraft is
			real garbage collector pressure for no benefit - the HUD reads the
			numbers immediately and never keeps them.
		]]
		telemetry = {
			airspeedTrue = 0,
			airspeedIndicated = 0,
			altitude = 0,
			verticalSpeed = 0,
			alpha = 0,
			beta = 0,
			pitchAttitude = 0,
			bankAngle = 0,

			-- For the direction indicator and the turn coordinator. Radians and
			-- radians per second; the instruments convert, the physics does not.
			heading = 0,
			turnRate = 0,
			-- The inclinometer ball, m/s^2, positive to the aircraft's right.
			lateralAcceleration = 0,

			--[[
				The angle of attack at which the main wing stalls, in radians.

				STATIC - written once here rather than every frame, because it is
				a property of the aerofoil and not of the flight state. It is in
				the telemetry table anyway because it is meaningless to the
				physics and essential to the HUD: without it an instrument can
				display alpha but cannot say whether that alpha is a problem,
				which is exactly the gap the pilot reported.

				Taken from the largest surface by area, which is the main wing on
				any aircraft that flies. Reading it off the definition by name
				would break the moment an aircraft called its wing something else.
			]]
			stallAlpha = stallAlpha,

			loadFactor = 0,
			density = 0,
			dynamicPressure = 0,
			thrust = 0,
			rpm = 0,
			fuelKg = 0,
			force = Vector3.zero,
			torque = Vector3.zero,
			surfaces = surfaceTelemetry,
		},
	}

	return state
end

-- Re-read the centre of mass and rebuild every moment arm. Needed only if the
-- physical model changes in flight - dropping stores, losing a wing to damage.
function FlightModel.recomputeGeometry(state: any)
	local root = state.root
	state.comLocal = root.CFrame:PointToObjectSpace(root.AssemblyCenterOfMass)
	state.comDatum = state.comLocal + state.datumOffset
	state.mass = root.AssemblyMass

	for _, entry in state.surfaces do
		entry.arm = entry.surface.offset - state.comDatum
	end
	state.thrustArm = state.definition.engine.thrustOffset - state.comDatum
end

-- =========================================================================
-- CONTROL ROUTING
-- =========================================================================

--[[
	Which control axis drives this surface, and in which sense.

	The sign lives on the surface rather than here because it is a property of
	how the surface is rigged, not of the control system. Ailerons are the
	obvious case: both are driven by "roll", but with opposite signs, and it is
	that opposition alone which turns a symmetric input into a rolling moment.
	Give them the same sign and they become flaps.
]]
local function controlFor(surface: any, controls: Controls): number
	local axis = surface.controlAxis
	if axis == nil then
		return 0
	end

	local value: number
	if axis == "pitch" then
		value = controls.pitch
	elseif axis == "roll" then
		value = controls.roll
	elseif axis == "yaw" then
		value = controls.yaw
	else
		return 0
	end

	return value * surface.controlSign
end

-- =========================================================================
-- THE SOLVER
-- =========================================================================

--[[
	Compute the total aerodynamic and propulsive force and torque.

	Pure with respect to Roblox: it reads nothing from the datamodel and writes
	nothing to it. Everything it needs arrives in `kinematics`. That is what
	lets runTests() assert on real flight behaviour - pitch stability, roll
	damping, weathervaning - without ever running the physics engine.

	Returns (force, torque) in world space, newtons and newton-metres.
	Telemetry is written into state.telemetry.
]]
function FlightModel.computeForces(
	state: any,
	kinematics: Kinematics,
	dt: number,
	controls: Controls?,
	environment: Environment?
): (Vector3, Vector3)
	local def = state.definition
	local c = controls or DEFAULT_CONTROLS
	local env = environment

	local cf = kinematics.cframe
	local omega = kinematics.angularVelocity
	local altitude = kinematics.altitude

	local tempOffset = env and env.tempOffsetC or 0
	local wind = env and env.windVelocity or Vector3.zero

	--[[
		Velocity RELATIVE TO THE AIR, which is the only velocity aerodynamics
		cares about. An aircraft holding station in a 40 kt headwind is doing
		40 kt through the air and zero over the ground, and every surface must
		see the former.
	]]
	local vAir = kinematics.velocity - wind

	local density = Atmosphere.getDensity(altitude, tempOffset)
	local densityRatio = density / Atmosphere.SEA_LEVEL_DENSITY

	local totalForce = Vector3.zero
	local totalTorque = Vector3.zero

	-- ---- Aerodynamic surfaces ------------------------------------------
	local telemetry = state.telemetry
	local flaps = math.clamp(c.flaps, 0, 1)

	for i, entry in state.surfaces do
		local surface = entry.surface

		-- Moment arm rotated into world space. Rotation only - the arm is
		-- already in metres and VectorToWorldSpace does not scale.
		local armWorld = cf:VectorToWorldSpace(entry.arm)

		--[[
			The cross product that makes the model come alive. Without the
			omega x r term every surface would see identical airflow, the
			aircraft would have no rotational damping at all, and no amount of
			tuning could stop it oscillating.
		]]
		local pointVelocity = Aerodynamics.getPointVelocity(vAir, omega, armWorld)

		--[[
			This surface's own height above the ground, for ground effect.

			`altitude` is the centre of mass; armWorld.Y carries the surface up or
			down from it and already accounts for bank, so the low wing in a turn
			correctly sits closer to the ground than the high one.

			The ground's own height comes from the kinematics, measured by one
			raycast in readKinematics. It used to be assumed to be y = 0, which
			was true of the bare baseplate; with a real airport the runway is
			crowned 5 cm above the grass, and beyond the field there is no ground
			at all. nil therefore means no ground effect, which is correct rather
			than defensive.
		]]
		local groundY = kinematics.groundY
		local surfaceHeight = if groundY then (altitude + armWorld.Y) - groundY else nil

		local force, alpha, cl, cd, q = Aerodynamics.solveSurface(
			surface,
			cf,
			pointVelocity,
			density,
			controlFor(surface, c),
			flaps,
			surfaceHeight
		)

		totalForce += force
		-- The entire reason the aircraft rotates.
		totalTorque += armWorld:Cross(force)

		local t = telemetry.surfaces[i]
		t.alpha, t.cl, t.cd, t.q, t.force = alpha, cl, cd, q, force
	end

	-- ---- Engine ----------------------------------------------------------
	--[[
		Only the FORWARD component of airspeed unloads the propeller. A
		sideways or vertical component does not help it, and feeding it the
		total speed would have a fast descent produce thrust as though the
		aircraft were flying forward at that speed.
	]]
	local vAirBody = cf:VectorToObjectSpace(vAir)
	local forwardSpeed = -vAirBody.Z -- -Z is forward

	local thrust = Engine.update(state.engine, def.engine, dt, c.throttle, forwardSpeed, density, densityRatio)

	local forwardWorld = cf:VectorToWorldSpace(Vector3.new(0, 0, -1))
	local thrustForce = forwardWorld * thrust
	totalForce += thrustForce

	--[[
		Thrust acts on the propeller shaft, not at the centre of mass. On the
		172 the thrust line sits about 0.28 m BELOW the centre of mass - the
		high wing and the fuel it carries hold the balance point above the
		propeller shaft - so opening the throttle produces a nose-UP pitching
		moment. That is the "power up, nose up" behaviour of the high-wing
		Cessnas, and it is why a go-around needs forward pressure on the yoke.

		The sign is asserted by runTests() rather than trusted to this comment,
		because this exact claim was stated backwards here once already.

		This has to be applied by hand precisely because AeroForce is set to
		ApplyAtCenterOfMass; the constraint contributes no moment of its own.
	]]
	local thrustArmWorld = cf:VectorToWorldSpace(state.thrustArm)
	totalTorque += thrustArmWorld:Cross(thrustForce)

	--[[
		Left-turning tendencies, both proportional to the power being produced.

		  torqueReaction  the propeller turns clockwise seen from the cockpit,
		                  so Newton's third law rolls the airframe the other
		                  way - to the LEFT.
		  slipstreamYaw   the corkscrewing slipstream strikes the left side of
		                  the fin, pushing the tail right and the nose LEFT.

		Both are why a pilot holds right rudder on takeoff, and both fade as
		power comes off. Sign convention, in body axes:

		  positive torque about forward (-Z)  =  roll right
		  positive torque about up (+Y)       =  yaw left
	]]
	local power = state.engine.powerW
	if power > 0 then
		local rollAxis = forwardWorld
		local upWorld = cf:VectorToWorldSpace(Vector3.new(0, 1, 0))

		-- Negative about the forward axis: roll to the left.
		totalTorque += rollAxis * (-def.engine.torqueReaction * power)
		-- Positive about the up axis: yaw to the left.
		totalTorque += upWorld * (def.engine.slipstreamYaw * power)
	end

	-- ---- Airframe parasitic drag -----------------------------------------
	--[[
		Everything that drags but makes no lift: fuselage, struts, fixed gear,
		antennas, and the interference between them - plus the propeller when
		it is not being driven hard.

		Applied at the centre of mass, contributing no moment. That is a
		deliberate simplification: the true centre of pressure of the fuselage
		wanders with sideslip, and modelling it properly would mean giving the
		fuselage its own surfaces. The fin already provides the directional
		stability that would dominate that effect.
	]]
	local speedSq = vAir:Dot(vAir)
	if speedSq > 1e-6 then
		local speed = math.sqrt(speedSq)
		local q = 0.5 * density * speedSq

		local cd0 = def.drag.airframeCD0 + Engine.getPropDragCD0(state.engine, def.engine)
		local dragMagnitude = q * def.reference.wingArea * cd0

		totalForce += vAir * (-dragMagnitude / speed)
	end

	-- ---- Safety ----------------------------------------------------------
	--[[
		A single NaN written to a constraint permanently destroys a Roblox
		assembly: the parts vanish and cannot be recovered without respawning
		the aircraft. Every value that reaches a constraint passes through here
		first. It costs a handful of comparisons per frame and removes an
		entire category of unrecoverable failure.
	]]
	totalForce = sanitizeVector(totalForce)
	totalTorque = sanitizeVector(totalTorque)

	local mass = state.mass
	totalForce = clampMagnitude(totalForce, mass * Constants.GRAVITY_MS2 * MAX_ACCEL_G)
	-- Torque limit scaled by a crude moment of inertia estimate (m * span^2).
	local inertiaScale = mass * def.reference.wingSpan * def.reference.wingSpan * 0.1
	totalTorque = clampMagnitude(totalTorque, inertiaScale * MAX_ANGULAR_ACCEL)

	-- ---- Telemetry -------------------------------------------------------
	local trueAirspeed = math.sqrt(speedSq)

	telemetry.airspeedTrue = trueAirspeed
	telemetry.airspeedIndicated = Atmosphere.trueToEquivalent(trueAirspeed, altitude, tempOffset)
	telemetry.altitude = altitude
	telemetry.verticalSpeed = kinematics.velocity.Y
	telemetry.density = density
	telemetry.dynamicPressure = 0.5 * density * speedSq
	telemetry.thrust = thrust
	telemetry.rpm = state.engine.rpm
	telemetry.fuelKg = state.engine.fuelKg
	--[[
		Published for the INSTRUMENTS, not used by the physics.

		The ASI's static-source position error depends on flap setting - the
		POH prints a separate calibration table for flaps down - so the
		instrument layer needs to know which one to read. Telemetry is the
		display channel and already carries alpha and beta the same way, so
		this belongs here rather than widening the six-field Controls contract
		(§6c) that the aerodynamics consumes.
	]]
	telemetry.flaps = controls.flaps or 0
	telemetry.force = totalForce
	telemetry.torque = totalTorque

	--[[
		Whole-aircraft angle of attack and sideslip, for the HUD only - the
		surfaces each computed their own from their own local airflow, which is
		what the physics used. These are the numbers a pilot would read.
	]]
	if trueAirspeed > 0.5 then
		telemetry.alpha = math.atan2(-vAirBody.Y, -vAirBody.Z)
		telemetry.beta = math.asin(math.clamp(vAirBody.X / trueAirspeed, -1, 1))
	else
		telemetry.alpha = 0
		telemetry.beta = 0
	end

	--[[
		ATTITUDE, which is a different thing from angle of attack and is here
		because confusing the two is the most natural mistake a pilot can make
		with this HUD.

		Alpha is measured against the AIRFLOW; attitude is measured against the
		HORIZON. In a climbing pull they diverge enormously - measured on a real
		stall entry here, 20.8 degrees of attitude with only 8.7 degrees of alpha,
		because the flight path curves up to follow the nose. Showing only alpha
		made it look stuck; showing both makes the difference legible.

		Cheap: LookVector.Y is the sine of the pitch attitude directly, and bank
		falls out of the right and up vectors with no trigonometry beyond one
		atan2. Negated so that positive bank is right wing down, matching the
		sign convention `Controls.roll` already uses.
	]]
	telemetry.pitchAttitude = math.asin(math.clamp(cf.LookVector.Y, -1, 1))
	telemetry.bankAngle = -math.atan2(cf.RightVector.Y, cf.UpVector.Y)

	--[[
		Load factor - what an accelerometer in the cockpit reads, in g.

		Gravity is excluded because we never apply it: totalForce is the sum of
		aerodynamic and propulsive forces only, which is exactly what a real
		accelerometer measures. Level flight therefore reads 1 g, and a 60
		degree banked turn reads 2 g.
	]]
	local upBody = cf:VectorToWorldSpace(Vector3.new(0, 1, 0))
	telemetry.loadFactor = totalForce:Dot(upBody) / (mass * Constants.GRAVITY_MS2)

	--[[
		HEADING, for the direction indicator. Radians, 0 .. 2pi, increasing
		clockwise from north as a compass does.

		North is -Z, which is not a choice made here: AirportService already
		defines runway 36 as the one you take off along -Z (see the handoff,
		section 11), and there is no magnetic model, so a designator is simply
		the world heading over ten. -Z must therefore be 000/360 or the runway
		numbers painted on the ground would disagree with the instrument.
	]]
	local look = cf.LookVector
	telemetry.heading = math.atan2(look.X, -look.Z) % (2 * math.pi)

	--[[
		RATE OF TURN, for the turn coordinator. Radians per second, positive to
		the RIGHT so that it matches heading increasing clockwise.

		It is the angular velocity about the WORLD vertical, not about the
		aircraft's own yaw axis: those differ in a bank, and it is the former
		that a turn coordinator is calibrated against - a standard rate turn is
		3 degrees of HEADING per second regardless of how steeply banked the
		aeroplane is to achieve it.

		Negated because Roblox's angular velocity follows the right-hand rule,
		so positive about +Y swings the nose to the LEFT.
	]]
	telemetry.turnRate = -kinematics.angularVelocity.Y

	--[[
		LATERAL ACCELERATION - the inclinometer ball, in m/s^2, positive when the
		specific force is toward the aircraft's RIGHT.

		This is the real quantity rather than sideslip angle, and the two are
		genuinely different: beta says where the nose points relative to the
		airflow, while the ball is a pendulum answering to the resultant of
		gravity and every other force. In a correctly banked turn beta is near
		zero AND the ball is centred, but in a forward slip - deliberate cross
		control, flown and signed off in the Phase 1 gate - they part company,
		and only the ball tells the pilot what their feet are doing.

		Same construction as loadFactor one line above, and for the same reason:
		gravity is never applied by this model, so totalForce is precisely the
		non-gravitational force a real accelerometer senses.
	]]
	local rightBody = cf:VectorToWorldSpace(Vector3.new(1, 0, 0))
	telemetry.lateralAcceleration = totalForce:Dot(rightBody) / mass

	return totalForce, totalTorque
end

-- =========================================================================
-- PER-FRAME ENTRY POINT
-- =========================================================================

--[[
	Read the assembly, solve, and drive the constraints.

	Call once per frame from the pilot's client, from the aircraft's
	FlightController. `dt` is clamped so that a frame hitch - alt-tab, an asset
	load, a breakpoint - cannot integrate a huge step and launch the aircraft
	into orbit.
]]
--[[
	Read the assembly's true state out of Roblox, in SI.

	This is one half of the stud/metre boundary; everything downstream of it is
	pure SI. Exposed separately from step() because anything else that
	contributes force - GroundHandling, and later damage - needs the same
	kinematics, and reading them twice per frame would be both wasteful and a
	chance for the two readings to disagree.

	It is also the ONLY place in this module that touches the world, which is
	what keeps computeForces pure and the whole aerodynamic model testable
	without Roblox simulating anything. The ground probe below belongs here for
	that reason and no other.
]]
function FlightModel.readKinematics(state: any): Kinematics
	local root = state.root
	local com = root.AssemblyCenterOfMass

	--[[
		One ray per frame, straight down from the centre of mass, no longer than
		ground effect can reach.

		Deliberately NOT shared with GroundHandling's probes. Those are per
		wheel and about the length of a tyre radius - they answer "is this wheel
		touching?", which is a different question from "how far below is the
		surface?" and cannot answer it, because they stop well short of the
		distance ground effect still cares about.

		nil when nothing is found, which happens legitimately: beyond the edge of
		the field, and any time the aircraft is more than a wingspan up - which
		is almost always, and is the case this early-out makes free.
	]]
	local groundY: number? = nil
	if state.groundProbeReach > 0 then
		local reach = Units.metersToStuds(state.groundProbeReach)
		local hit = workspace:Raycast(com, Vector3.new(0, -reach, 0), state.groundProbeParams)
		if hit then
			groundY = Units.studsToMeters(hit.Position.Y)
		end
	end

	return {
		cframe = root.CFrame,
		velocity = root.AssemblyLinearVelocity / Constants.STUDS_PER_METER,
		angularVelocity = root.AssemblyAngularVelocity, -- rad/s: no length scale
		altitude = Units.studsToMeters(com.Y),
		groundY = groundY,
	}
end

--[[
	The other half of the boundary: SI force and torque in, Roblox units out.

	Callers with more than one force contributor must sum them and call this
	ONCE. Calling it twice does not accumulate - the second call overwrites the
	first, and the aircraft silently flies on whichever contribution happened
	to be written last.
]]
function FlightModel.applyForces(state: any, force: Vector3, torque: Vector3)
	state.aeroForce.Force = Units.newtonsToRobloxForceVector(force)
	state.aeroTorque.Torque = Units.newtonMetersToRobloxTorqueVector(torque)
end

--[[
	Aerodynamics and thrust only. Convenience for tests and for any context
	with no landing gear; the FlightController sums this with GroundHandling
	and calls applyForces itself.
]]
function FlightModel.step(state: any, dt: number, controls: Controls?, environment: Environment?)
	dt = math.min(math.max(dt, 0), Constants.SIM.MAX_TIMESTEP)
	if dt <= 0 then
		return
	end

	local kinematics = FlightModel.readKinematics(state)
	local force, torque = FlightModel.computeForces(state, kinematics, dt, controls, environment)
	FlightModel.applyForces(state, force, torque)
end

-- Stop applying force. Used when the pilot leaves the seat, when the aircraft
-- is despawned, or when network ownership moves away from this client.
function FlightModel.release(state: any)
	if state.aeroForce then
		state.aeroForce.Force = Vector3.zero
	end
	if state.aeroTorque then
		state.aeroTorque.Torque = Vector3.zero
	end
end

-- =========================================================================
-- VERIFICATION
-- =========================================================================

--[[
	Tests the emergent flight behaviour, not the arithmetic.

	Run from the Studio command bar:
		require(game.ReplicatedStorage.FlightSim.Physics.FlightModel).runTests()

	The checks that matter here are the stability ones, and they are written as
	DIFFERENCES rather than absolute values: "disturb the aircraft, and the
	response must oppose the disturbance". That formulation is independent of
	how the aircraft happens to be trimmed, which is what makes it a genuine
	test of stability rather than of the current coefficient set.
]]
function FlightModel.runTests(): (boolean, { any })
	local AircraftBuilder = require(FlightSim.Aircraft.AircraftBuilder)
	local Cessna172 = require(FlightSim.Aircraft.Definitions.Cessna172)

	local results = {}
	local allPassed = true

	local function record(label: string, passed: boolean, detail: string)
		if not passed then
			allPassed = false
		end
		table.insert(results, { label = label, passed = passed, detail = detail })
		print(string.format("  [%s] %-42s %s", passed and "PASS" or "FAIL", label, detail))
	end

	local function checkRange(label: string, actual: number, lo: number, hi: number, unit: string)
		record(label, actual >= lo and actual <= hi, string.format("%.4f %s (expected %.3f..%.3f)", actual, unit, lo, hi))
	end

	print("=== FlightModel: verification ===")

	local KT = 1852 / 3600
	local model = AircraftBuilder.build(Cessna172, CFrame.new(0, 500, 0), workspace)
	local state = FlightModel.new(model, Cessna172)

	--[[
		Body-axis torque components, in the sense a pilot means them:

		  pitchUp    positive torque about +X raises the nose
		  rollRight  positive torque about the forward axis (-Z) drops the
		             right wing, hence the negation of the Z component
		  yawRight   positive torque about +Y yaws the nose LEFT, hence the
		             negation of the Y component
	]]
	local function components(cf: CFrame, torque: Vector3): (number, number, number)
		local b = cf:VectorToObjectSpace(torque)
		return b.X, -b.Z, -b.Y
	end

	local function controlsWith(over: { [string]: number }?): Controls
		local c = table.clone(DEFAULT_CONTROLS)
		if over then
			for k, v in over do
				(c :: any)[k] = v
			end
		end
		return c
	end

	--[[
		A steady flight condition. `pitchDeg` tilts the BODY while velocity
		stays along world -Z, so it changes the angle of attack without
		changing the flight path - which is precisely the disturbance static
		stability is defined against.
	]]
	local function condition(speedKt: number, pitchDeg: number?, yawDeg: number?, omega: Vector3?): Kinematics
		local cf = CFrame.Angles(math.rad(pitchDeg or 0), math.rad(yawDeg or 0), 0)
		return {
			cframe = cf,
			velocity = Vector3.new(0, 0, -speedKt * KT),
			angularVelocity = omega or Vector3.zero,
			altitude = 500,
		}
	end

	local dt = 1 / 60
	local weight = state.mass * Constants.GRAVITY_MS2

	-- 1. Geometry ----------------------------------------------------------
	-- The moment arms are the foundation of every rotational result below. If
	-- the tail's arm is wrong, every stability check is meaningless.
	local stabArm = state.surfaces[3].arm
	checkRange("Tail moment arm from CoM", stabArm.Z, 3.6, 4.8, "m")

	local wingLeftArm = state.surfaces[1].arm
	local wingRightArm = state.surfaces[2].arm
	record(
		"Wing arms are mirrored about the centreline",
		math.abs(wingLeftArm.X + wingRightArm.X) < 1e-6,
		string.format("left x=%.3f, right x=%+.3f", wingLeftArm.X, wingRightArm.X)
	)
	--[[
		The thrust line sits BELOW the centre of mass on a high-wing Cessna -
		the wing and the fuel it carries are well above the propeller shaft.
		The consequence is the "power up, nose up" behaviour every 172 pilot
		knows, and it is why a go-around needs forward pressure rather than
		back pressure.
	]]
	record(
		"Thrust line is below the centre of mass",
		state.thrustArm.Y < 0,
		string.format("y = %+.3f m (power produces nose-up pitch)", state.thrustArm.Y)
	)

	-- 2. At rest -----------------------------------------------------------
	-- A parked aircraft with the engine off must produce exactly nothing.
	local restKin: Kinematics = {
		cframe = CFrame.identity,
		velocity = Vector3.zero,
		angularVelocity = Vector3.zero,
		altitude = 0,
	}
	local fRest, tRest = FlightModel.computeForces(state, restKin, dt, controlsWith(), nil)
	record(
		"At rest, engine off: no force",
		fRest.Magnitude < 1e-6,
		string.format("|F| = %.9f N", fRest.Magnitude)
	)
	record(
		"At rest, engine off: no torque",
		tRest.Magnitude < 1e-6,
		string.format("|T| = %.9f N*m", tRest.Magnitude)
	)

	-- 3. Cruise: lift must be in the right ballpark ------------------------
	-- Nothing is trimmed here, so this is not asking for exactly 1 g - it is
	-- asking whether a 172 at 120 kt is roughly holding itself up.
	local cruise = condition(120)
	local fCruise = FlightModel.computeForces(state, cruise, dt, controlsWith(), nil)
	checkRange("Lift at 120 kt vs weight", fCruise.Y / weight, 0.6, 1.5, "x weight")
	record(
		"Drag opposes motion at cruise",
		fCruise.Z > 0,
		string.format("Fz = %+.1f N (positive = rearward)", fCruise.Z)
	)
	checkRange("Load factor at cruise", state.telemetry.loadFactor, 0.6, 1.5, "g")

	-- Whole-aircraft alpha must be zero when the flight path is level and the
	-- body is level, regardless of what incidence the wing is rigged at.
	record(
		"Alpha is zero in level flight",
		math.abs(state.telemetry.alpha) < 1e-6,
		string.format("alpha = %.9f deg", math.deg(state.telemetry.alpha))
	)

	-- 4. STATIC PITCH STABILITY -------------------------------------------
	--[[
		The single most important property in the whole simulator.

		Raise the nose without changing the flight path and the response must
		be nose-DOWN. Expressed as a difference so it holds no matter how the
		aircraft is trimmed. If this fails the aircraft is divergent in pitch
		and effectively unflyable.
	]]
	local _, tLevel = FlightModel.computeForces(state, condition(120, 0), dt, controlsWith(), nil)
	local kinUp = condition(120, 5)
	local _, tNoseUp = FlightModel.computeForces(state, kinUp, dt, controlsWith(), nil)

	local pitchLevel = select(1, components(condition(120, 0).cframe, tLevel))
	local pitchUp = select(1, components(kinUp.cframe, tNoseUp))
	record(
		"Pitch is statically stable",
		pitchUp < pitchLevel,
		string.format("+5 deg alpha changes pitch moment by %+.0f N*m (must be negative)", pitchUp - pitchLevel)
	)

	-- And symmetrically: dropping the nose must produce a nose-up response.
	local kinDown = condition(120, -5)
	local _, tNoseDown = FlightModel.computeForces(state, kinDown, dt, controlsWith(), nil)
	local pitchDown = select(1, components(kinDown.cframe, tNoseDown))
	record(
		"Pitch stability is symmetric",
		pitchDown > pitchLevel,
		string.format("-5 deg alpha changes pitch moment by %+.0f N*m (must be positive)", pitchDown - pitchLevel)
	)

	-- 5. ROLL DAMPING -----------------------------------------------------
	-- Roll right and the descending right wing meets the air at a higher
	-- angle, makes more lift, and opposes the roll. This is the reason an
	-- aircraft does not spin up indefinitely, and it comes purely from the
	-- omega x r term.
	local rollRate = Vector3.new(0, 0, -1) -- 1 rad/s about forward = roll right
	local kinRolling = condition(120, 0, 0, rollRate)
	local _, tRolling = FlightModel.computeForces(state, kinRolling, dt, controlsWith(), nil)

	local _, rollLevel = components(condition(120).cframe, tLevel)
	local _, rollDamped = components(kinRolling.cframe, tRolling)
	record(
		"Roll is damped",
		rollDamped < rollLevel,
		string.format("rolling right produces %+.0f N*m of restoring moment", rollDamped - rollLevel)
	)

	-- 6. PITCH DAMPING ----------------------------------------------------
	-- Same mechanism about the pitch axis: the tail, being a long way aft,
	-- sees a large vertical velocity when the aircraft pitches.
	local kinPitching = condition(120, 0, 0, Vector3.new(1, 0, 0)) -- nose-up rate
	local _, tPitching = FlightModel.computeForces(state, kinPitching, dt, controlsWith(), nil)
	local pitchDampComponent = select(1, components(kinPitching.cframe, tPitching))
	record(
		"Pitch rate is damped",
		pitchDampComponent < pitchLevel,
		string.format("nose-up rate produces %+.0f N*m of restoring moment", pitchDampComponent - pitchLevel)
	)

	-- 7. WEATHERVANE STABILITY --------------------------------------------
	--[[
		Yaw the body without changing the flight path and the fin must push it
		back into line. This is why an aircraft points where it is going, and
		it is entirely the fin's doing - it is the only surface whose normal
		points sideways.
	]]
	-- Nose yawed 5 deg left of a flight path that is still along world -Z.
	local kinSlip = condition(120, 0, 5)
	local _, tSlip = FlightModel.computeForces(state, kinSlip, dt, controlsWith(), nil)
	local _, _, yawSlip = components(kinSlip.cframe, tSlip)

	-- Yawing the nose 5 deg left of the flight path must produce a nose-RIGHT
	-- moment that removes the sideslip.
	record(
		"Yaw is statically stable (weathervanes)",
		yawSlip > 0,
		string.format("5 deg sideslip produces %+.0f N*m nose-right", yawSlip)
	)
	record(
		"Sideslip is reported to the instruments",
		math.abs(math.deg(state.telemetry.beta)) > 3,
		string.format("beta = %+.2f deg", math.deg(state.telemetry.beta))
	)

	-- 8. CONTROL AUTHORITY -------------------------------------------------
	-- Each control must move the aircraft the way the pilot expects. A sign
	-- error here is the difference between an aeroplane and a puzzle.
	local _, tElevator = FlightModel.computeForces(state, condition(120), dt, controlsWith({ pitch = 1 }), nil)
	local elevatorPitch = select(1, components(condition(120).cframe, tElevator))
	record(
		"Pull back raises the nose",
		elevatorPitch > pitchLevel,
		string.format("%+.0f N*m nose-up", elevatorPitch - pitchLevel)
	)

	local _, tAileron = FlightModel.computeForces(state, condition(120), dt, controlsWith({ roll = 1 }), nil)
	local _, aileronRoll = components(condition(120).cframe, tAileron)
	record(
		"Right aileron rolls right",
		aileronRoll > rollLevel,
		string.format("%+.0f N*m roll right", aileronRoll - rollLevel)
	)

	local _, tRudder = FlightModel.computeForces(state, condition(120), dt, controlsWith({ yaw = 1 }), nil)
	local _, _, rudderYaw = components(condition(120).cframe, tRudder)
	local _, _, yawLevel = components(condition(120).cframe, tLevel)
	record(
		"Right rudder yaws right",
		rudderYaw > yawLevel,
		string.format("%+.0f N*m nose-right", rudderYaw - yawLevel)
	)

	--[[
		Control authority must scale with dynamic pressure - controls go soggy
		when slow. This is not coded anywhere; it falls out of q appearing in
		every force. It is a large part of why a slow approach feels different
		from a fast cruise.
	]]
	local _, tElevatorSlow = FlightModel.computeForces(state, condition(60), dt, controlsWith({ pitch = 1 }), nil)
	local _, tLevelSlow = FlightModel.computeForces(state, condition(60), dt, controlsWith(), nil)
	local slowAuthority = select(1, components(condition(60).cframe, tElevatorSlow))
		- select(1, components(condition(60).cframe, tLevelSlow))
	local fastAuthority = elevatorPitch - pitchLevel
	record(
		"Control authority falls with airspeed",
		slowAuthority < fastAuthority * 0.5,
		string.format("60 kt: %.0f N*m vs 120 kt: %.0f N*m", slowAuthority, fastAuthority)
	)

	-- 9. Engine ------------------------------------------------------------
	local powered = FlightModel.new(model, Cessna172)
	Engine.setRunning(powered.engine, Cessna172.engine)

	-- Spool the engine up to full power over a second of simulated time.
	local staticKin: Kinematics = {
		cframe = CFrame.identity,
		velocity = Vector3.zero,
		angularVelocity = Vector3.zero,
		altitude = 0,
	}
	local fThrust
	for _ = 1, 60 do
		fThrust = FlightModel.computeForces(powered, staticKin, dt, controlsWith({ throttle = 1 }), nil)
	end

	-- Full power standing still: thrust must be forward and roughly the
	-- 2,780 N the momentum theory model predicts for this propeller.
	record(
		"Full throttle produces forward thrust",
		fThrust.Z < 0,
		string.format("Fz = %+.0f N (negative = forward)", fThrust.Z)
	)
	checkRange("Static thrust at full power", -fThrust.Z, 2300, 3100, "N")
	checkRange("Thrust / weight", -fThrust.Z / weight, 0.18, 0.32, "")

	-- The left-turning tendencies every pilot compensates for on takeoff.
	local _, tPower = FlightModel.computeForces(powered, staticKin, dt, controlsWith({ throttle = 1 }), nil)
	local _, powerRoll, powerYaw = components(CFrame.identity, tPower)
	record(
		"Engine torque rolls left",
		powerRoll < 0,
		string.format("%+.0f N*m (negative = left roll)", powerRoll)
	)
	record(
		"Slipstream yaws left",
		powerYaw < 0,
		string.format("%+.0f N*m (negative = left yaw)", powerYaw)
	)

	record(
		"Fuel is consumed",
		powered.engine.fuelKg < Cessna172.engine.fuelCapacityKg,
		string.format("%.4f kg burned in ~1 s", Cessna172.engine.fuelCapacityKg - powered.engine.fuelKg)
	)

	-- 10. Flaps ------------------------------------------------------------
	-- Flaps must add both lift and drag at a fixed speed and attitude.
	local approachKin = condition(70)
	local fClean = FlightModel.computeForces(state, approachKin, dt, controlsWith(), nil)
	local fFlapped = FlightModel.computeForces(state, approachKin, dt, controlsWith({ flaps = 1 }), nil)
	record(
		"Flaps increase lift",
		fFlapped.Y > fClean.Y,
		string.format("%.0f N -> %.0f N", fClean.Y, fFlapped.Y)
	)
	record(
		"Flaps increase drag",
		fFlapped.Z > fClean.Z,
		string.format("%.0f N -> %.0f N", fClean.Z, fFlapped.Z)
	)

	-- 11. Altitude ---------------------------------------------------------
	-- Thinner air means less lift at the same true airspeed. This is what
	-- produces a service ceiling without one ever being coded.
	local highKin: Kinematics = {
		cframe = CFrame.identity,
		velocity = Vector3.new(0, 0, -120 * KT),
		angularVelocity = Vector3.zero,
		altitude = 4000,
	}
	local fHigh = FlightModel.computeForces(state, highKin, dt, controlsWith(), nil)
	record(
		"Lift falls with altitude",
		fHigh.Y < fCruise.Y * 0.85,
		string.format("sea level %.0f N -> 4000 m %.0f N", fCruise.Y, fHigh.Y)
	)

	-- Indicated airspeed must under-read true airspeed up there, which is why
	-- the ASI alone cannot tell a pilot how fast they are actually moving.
	record(
		"Indicated airspeed under-reads at altitude",
		state.telemetry.airspeedIndicated < state.telemetry.airspeedTrue * 0.95,
		string.format(
			"%.1f kt indicated vs %.1f kt true",
			state.telemetry.airspeedIndicated / KT,
			state.telemetry.airspeedTrue / KT
		)
	)

	-- 10b. Attitude is not angle of attack -----------------------------------
	--[[
		The pair that made the AoA readout look broken until both were shown.

		Alpha is measured against the AIRFLOW and attitude against the HORIZON,
		so an aircraft pitched 20 degrees up while climbing along that path has a
		large attitude and a small alpha. Driven here with a state that separates
		them by construction: nose 20 degrees up, flying horizontally, which must
		give attitude 20 and alpha 20 - and then the same nose attitude with the
		velocity along the nose, which must give attitude 20 and alpha 0.
	]]
	local nose20 = CFrame.Angles(math.rad(20), 0, 0)

	FlightModel.computeForces(state, {
		cframe = nose20,
		velocity = Vector3.new(0, 0, -60 * KT), -- horizontal flight, nose high
		angularVelocity = Vector3.zero,
		altitude = 500,
	}, dt, controlsWith(), nil)
	record(
		"Nose high but flying level: attitude and alpha agree",
		math.abs(math.deg(state.telemetry.pitchAttitude) - 20) < 0.5
			and math.abs(math.deg(state.telemetry.alpha) - 20) < 0.5,
		string.format("attitude %.1f, alpha %.1f", math.deg(state.telemetry.pitchAttitude), math.deg(state.telemetry.alpha))
	)

	FlightModel.computeForces(state, {
		cframe = nose20,
		velocity = nose20:VectorToWorldSpace(Vector3.new(0, 0, -60 * KT)), -- along the nose
		angularVelocity = Vector3.zero,
		altitude = 500,
	}, dt, controlsWith(), nil)
	record(
		"Climbing along the nose: attitude 20, alpha ~0",
		math.abs(math.deg(state.telemetry.pitchAttitude) - 20) < 0.5
			and math.abs(math.deg(state.telemetry.alpha)) < 0.5,
		string.format("attitude %.1f, alpha %.1f - this is why AoA looked stuck",
			math.deg(state.telemetry.pitchAttitude), math.deg(state.telemetry.alpha))
	)

	-- Bank, positive to the right, matching the sign Controls.roll already uses.
	FlightModel.computeForces(state, {
		cframe = CFrame.Angles(0, 0, math.rad(-30)),
		velocity = Vector3.new(0, 0, -60 * KT),
		angularVelocity = Vector3.zero,
		altitude = 500,
	}, dt, controlsWith(), nil)
	record(
		"Bank is positive rolling right",
		state.telemetry.bankAngle > 0 and math.abs(math.deg(state.telemetry.bankAngle) - 30) < 0.5,
		string.format("%.1f deg", math.deg(state.telemetry.bankAngle))
	)

	-- 10c. Heading, turn rate and the ball ------------------------------------
	--[[
		HEADING must agree with the runway numbers painted on the ground.

		AirportService defines runway 36 as the one flown along -Z, so -Z has to
		read 360 and not 180. Getting this backwards would be invisible in the
		air and obvious on final, which is the worst way to find it.
	]]
	local function headingFacing(yawDeg: number): number
		FlightModel.computeForces(state, {
			cframe = CFrame.Angles(0, math.rad(yawDeg), 0),
			velocity = Vector3.zero,
			angularVelocity = Vector3.zero,
			altitude = 500,
		}, dt, controlsWith(), nil)
		return math.deg(state.telemetry.heading)
	end

	local northHdg = headingFacing(0)
	record(
		"Facing -Z reads 360/000, so runway 36 is runway 36",
		northHdg < 0.5 or northHdg > 359.5,
		string.format("%.1f deg", northHdg)
	)

	--[[
		A yaw to the right must INCREASE the heading, as a compass does. Roblox's
		positive yaw is to the left, so the sign is the thing being checked here
		and a missing negation would read east as west.
	]]
	local eastHdg = headingFacing(-90)
	record(
		"Yawing right increases heading: east reads 090",
		math.abs(eastHdg - 90) < 0.5,
		string.format("%.1f deg facing +X", eastHdg)
	)
	local southHdg, westHdg = headingFacing(180), headingFacing(90)
	record(
		"South reads 180 and west reads 270",
		math.abs(southHdg - 180) < 0.5 and math.abs(westHdg - 270) < 0.5,
		string.format("%.1f and %.1f deg", southHdg, westHdg)
	)
	record(
		"Heading never leaves 0..360",
		northHdg >= 0 and northHdg <= 360 and eastHdg >= 0 and westHdg <= 360,
		"wrapped, so the card cannot run off its scale"
	)

	--[[
		RATE OF TURN, positive to the right to match heading. A standard rate
		turn is 3 deg/s, which is what the turn coordinator's index marks mean,
		so the sign and the magnitude both have to be right for the instrument to
		mean anything.
	]]
	FlightModel.computeForces(state, {
		cframe = CFrame.identity,
		velocity = Vector3.new(0, 0, -90 * KT),
		angularVelocity = Vector3.new(0, -math.rad(3), 0), -- right-hand rule: nose right
		altitude = 500,
	}, dt, controlsWith(), nil)
	local rightTurn = math.deg(state.telemetry.turnRate)
	record(
		"A standard rate turn to the right reads +3 deg/s",
		math.abs(rightTurn - 3) < 0.01,
		string.format("%+.2f deg/s", rightTurn)
	)

	FlightModel.computeForces(state, {
		cframe = CFrame.identity,
		velocity = Vector3.new(0, 0, -90 * KT),
		angularVelocity = Vector3.new(0, math.rad(3), 0),
		altitude = 500,
	}, dt, controlsWith(), nil)
	record(
		"...and a left turn reads negative",
		math.abs(math.deg(state.telemetry.turnRate) + 3) < 0.01,
		string.format("%+.2f deg/s", math.deg(state.telemetry.turnRate))
	)

	--[[
		THE BALL. Straight and level with the ball centred is the reading the
		whole instrument is judged against - if wings-level flight showed a
		deflection, every coordinated turn would look like a skid.
	]]
	FlightModel.computeForces(state, {
		cframe = CFrame.identity,
		velocity = Vector3.new(0, 0, -90 * KT),
		angularVelocity = Vector3.zero,
		altitude = 500,
	}, dt, controlsWith(), nil)
	local ballLevel = state.telemetry.lateralAcceleration
	record(
		"Wings level and in balance, the ball is centred",
		math.abs(ballLevel) < 0.15,
		string.format("%.3f m/s^2 lateral", ballLevel)
	)

	--[[
		Rudder alone, wings level, is a skid - which is exactly the forward slip
		the pilot flew in the Phase 1 gate, and the case beta cannot report on
		its own. The side force must appear, and it must appear on the correct
		side: right rudder yaws the nose right, which puts the relative wind on
		the aircraft's left and the resulting side force to the... left. The sign
		is asserted rather than assumed, because it is the one thing here that
		cannot be reasoned to confidently.
	]]
	FlightModel.computeForces(state, {
		cframe = CFrame.identity,
		velocity = Vector3.new(0, 0, -90 * KT),
		angularVelocity = Vector3.zero,
		altitude = 500,
	}, dt, controlsWith({ yaw = 1 }), nil)
	local ballYaw = state.telemetry.lateralAcceleration
	record(
		"Rudder alone produces a real lateral acceleration",
		math.abs(ballYaw) > 0.3 and math.abs(ballYaw) > math.abs(ballLevel) * 2,
		string.format("%+.3f m/s^2 with full rudder vs %+.3f level", ballYaw, ballLevel)
	)

	--[[
		Sideslip and the ball are DIFFERENT quantities, which is why the ball is
		published as an acceleration rather than approximated with beta. Flying
		with the nose off the airflow gives both, but they are not the same
		number and neither can be derived from the other by a constant.
	]]
	FlightModel.computeForces(state, {
		cframe = CFrame.identity,
		velocity = Vector3.new(10, 0, -90 * KT), -- blown sideways: real sideslip
		angularVelocity = Vector3.zero,
		altitude = 500,
	}, dt, controlsWith(), nil)
	record(
		"Sideslip shows on the ball, and is not merely beta rescaled",
		math.abs(state.telemetry.beta) > math.rad(2) and math.abs(state.telemetry.lateralAcceleration) > 0.3,
		string.format("beta %.1f deg, ball %+.2f m/s^2", math.deg(state.telemetry.beta), state.telemetry.lateralAcceleration)
	)

	--[[
		The wing's stall angle has to reach the telemetry, because an instrument
		can display alpha but cannot judge it without this number - which is
		exactly the gap that made the stall invisible on the HUD.
	]]
	record(
		"The wing's stall angle is published for instruments",
		type(state.telemetry.stallAlpha) == "number" and state.telemetry.stallAlpha > math.rad(8),
		string.format("%.1f deg", math.deg(state.telemetry.stallAlpha or 0))
	)

	-- 11b. Ground effect ----------------------------------------------------
	--[[
		Two heights, SAME speed and SAME attitude, 1.2 m and 30 m.

		The pair is chosen so density cannot explain the difference: 30 m of
		altitude changes air density by about 0.3%, while 30 m is comfortably more
		than the 11 m span at which ground effect is defined to vanish. So
		whatever separates these two numbers is ground effect and nothing else.
		Flown slow and flapped, because induced drag is the term being changed and
		it dominates exactly there.
	]]
	--[[
		`groundY` is stated explicitly rather than left to default, and that is
		now the honest way to write this: the ground is wherever the raycast in
		readKinematics found it, and a synthetic kinematics table that omits it
		is describing an aircraft with no ground beneath it at all.
	]]
	local function nearGroundKin(altitudeM: number, groundY: number?): Kinematics
		return {
			cframe = CFrame.Angles(math.rad(8), 0, 0),
			velocity = Vector3.new(0, 0, -55 * KT),
			angularVelocity = Vector3.zero,
			altitude = altitudeM,
			groundY = if groundY == nil then 0 else groundY,
		}
	end

	--[[
		Asserted on the WING'S OWN COEFFICIENTS, not on the force vector, and the
		first version of this test got that wrong twice in a way worth recording.

		`force.Y` is not lift. Lift and drag are resolved about the relative wind,
		so at 8 degrees of alpha the drag vector has a real Y component - reducing
		drag moved force.Y by 38 N and an "in ground effect lift is unchanged"
		assertion failed against correct code. Likewise force.Z at two altitudes
		is not a clean comparison, because DENSITY changes with altitude and
		swamps the thing being measured.

		CL and CD are dimensionless and density-free, so they isolate exactly what
		this term does and nothing else.
	]]
	local landingControls = controlsWith({ flaps = 1 })
	local wingIndex = 1 -- WingLeft

	local function wingCoefficients(altitudeM: number): (number, number)
		FlightModel.computeForces(state, nearGroundKin(altitudeM), dt, landingControls, nil)
		local w = state.telemetry.surfaces[wingIndex]
		return w.cl, w.cd
	end

	local clAloft, cdAloft = wingCoefficients(30)
	local clFlare, cdFlare = wingCoefficients(1.2)

	record(
		"Ground effect reduces the wing's drag coefficient in the flare",
		cdFlare < cdAloft,
		string.format("CD %.5f at 30 m -> %.5f at 1.2 m", cdAloft, cdFlare)
	)

	--[[
		DRAG ONLY. This model does not touch the lift curve, so any change here
		would mean the induced term had leaked into CL - which would move the
		stall speed near the ground and quietly invalidate the figures in §4.
	]]
	record(
		"Ground effect does not change the lift coefficient",
		math.abs(clFlare - clAloft) < 1e-12,
		string.format("CL %.6f vs %.6f", clAloft, clFlare)
	)

	--[[
		And it must be SMALL - the assertion most likely to catch a later
		"improvement".

		The 172's wing sits 2.1 m up on an 11 m span. A high wing gets little
		ground effect; that is a real property of the aeroplane and the reason it
		does not float like a low-wing trainer. A version of this producing a
		dramatic cushion would be wrong, so the upper bound is asserted as firmly
		as the lower one.

		THE CEILING IS NOT A GUESS, and the first attempt at it was - 8% picked by
		eye, which failed at a perfectly correct 8.97%. The reduction in CD can
		never exceed the reduction in the INDUCED term alone, because parasitic
		drag is untouched; at h/b = 0.19 the Wieselsberger factor is ~0.90, so
		~10% is the hard physical ceiling and anything at or under it is
		consistent. 12% leaves room for the test condition moving without letting
		a genuinely dramatic version (30%+) through.
	]]
	local reduction = (cdAloft - cdFlare) / cdAloft
	checkRange("Ground effect is a few percent, not a cushion", reduction * 100, 3.0, 12.0, "%")

	-- Clear of the ground it must cost exactly nothing, or every figure measured
	-- in cruise would have quietly moved. Coefficients again, so that the density
	-- difference between the two heights cannot be mistaken for the term.
	local _, cdHigh = wingCoefficients(400)
	local _, cdMid = wingCoefficients(30)
	record(
		"No ground effect at altitude, to the last bit",
		math.abs(cdHigh - cdMid) < 1e-12,
		string.format("CD identical at 30 m and 400 m (%.8f)", cdMid)
	)

	--[[
		THE check that the airport made necessary.

		Ground effect must follow the GROUND, not the altimeter. An aeroplane
		1.2 m over a surface raised to y = 20 is in exactly as much ground effect
		as one 1.2 m over a surface at y = 0 - the altimeter reads 21.2 in one
		case and 1.2 in the other, and it is the difference that matters. Before
		the raycast this module assumed the ground was at y = 0, and this is the
		assertion that assumption would have failed.
	]]
	local function coefficientsAt(altitudeM: number, groundY: number?): number
		FlightModel.computeForces(state, {
			cframe = CFrame.Angles(math.rad(8), 0, 0),
			velocity = Vector3.new(0, 0, -55 * KT),
			angularVelocity = Vector3.zero,
			altitude = altitudeM,
			groundY = groundY,
		}, dt, landingControls, nil)
		return state.telemetry.surfaces[wingIndex].cd
	end

	local cdOverRaisedGround = coefficientsAt(21.2, 20)
	record(
		"Ground effect follows the ground, not the altimeter",
		math.abs(cdOverRaisedGround - cdFlare) < 1e-12,
		string.format("CD %.6f at 1.2 m over y=20 vs %.6f at 1.2 m over y=0", cdOverRaisedGround, cdFlare)
	)

	--[[
		And no ground at all is a real answer, not a missing one. Off the edge of
		the field the raycast finds nothing; the wing must then behave exactly as
		it does at altitude rather than falling back to a y = 0 that is not there.
	]]
	local cdNoGround = coefficientsAt(1.2, nil)
	record(
		"No ground beneath means no ground effect",
		math.abs(cdNoGround - cdAloft) < 1e-12,
		string.format("CD %.6f with groundY nil, against %.6f at 30 m", cdNoGround, cdAloft)
	)

	-- 12. Wind -------------------------------------------------------------
	--[[
		Holding station in a headwind equal to the aircraft's airspeed: ground
		velocity zero, but the aircraft must still be flying. If wind were
		handled wrongly this produces zero lift and the aeroplane falls out of
		the sky while apparently doing 120 kt.
	]]
	local hoverKin: Kinematics = {
		cframe = CFrame.identity,
		velocity = Vector3.zero,
		angularVelocity = Vector3.zero,
		altitude = 500,
	}
	local fWind = FlightModel.computeForces(state, hoverKin, dt, controlsWith(), {
		windVelocity = Vector3.new(0, 0, 120 * KT), -- blowing from ahead
	})
	record(
		"Headwind produces lift at zero ground speed",
		fWind.Y > weight * 0.5,
		string.format("%.0f N of lift with no ground speed", fWind.Y)
	)

	-- 13. Numerical safety -------------------------------------------------
	-- Absurd inputs must produce finite, bounded output rather than a NaN that
	-- would permanently destroy the assembly.
	local insaneKin: Kinematics = {
		cframe = CFrame.Angles(2.1, 1.3, 0.7),
		velocity = Vector3.new(500, -900, 700),
		angularVelocity = Vector3.new(40, -60, 30),
		altitude = 12000,
	}
	local fInsane, tInsane = FlightModel.computeForces(state, insaneKin, dt, controlsWith({ pitch = 1, roll = -1, yaw = 1 }), nil)
	record(
		"Extreme state stays finite",
		fInsane.Magnitude == fInsane.Magnitude
			and fInsane.Magnitude < math.huge
			and tInsane.Magnitude == tInsane.Magnitude
			and tInsane.Magnitude < math.huge,
		string.format("|F| = %.0f N, |T| = %.0f N*m", fInsane.Magnitude, tInsane.Magnitude)
	)
	record(
		"Force is clamped to a survivable limit",
		fInsane.Magnitude <= weight * MAX_ACCEL_G + 1,
		string.format("%.1f g", fInsane.Magnitude / weight)
	)

	-- 14. Timestep clamping ------------------------------------------------
	-- step() must refuse to integrate a frame hitch. Verified through the real
	-- entry point, since that is where the clamp lives.
	FlightModel.step(state, 10, controlsWith({ throttle = 1 }), nil)
	local appliedForce = state.aeroForce.Force
	record(
		"step() survives a 10 s frame hitch",
		appliedForce.Magnitude == appliedForce.Magnitude and appliedForce.Magnitude < math.huge,
		string.format("|F| = %.1f", appliedForce.Magnitude)
	)

	FlightModel.release(state)
	record(
		"release() zeroes the constraints",
		state.aeroForce.Force == Vector3.zero and state.aeroTorque.Torque == Vector3.zero,
		"both zero"
	)

	model:Destroy()

	local passCount = 0
	for _, r in results do
		if r.passed then
			passCount += 1
		end
	end
	print(string.format("=== %s (%d/%d) ===", allPassed and "ALL PASSED" or "FAILURES PRESENT", passCount, #results))

	return allPassed, results
end

return FlightModel
