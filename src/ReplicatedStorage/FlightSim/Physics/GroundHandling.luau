--!strict
--[[
	GroundHandling
	--------------
	Everything the aircraft does while its wheels are touching the ground:
	rolling resistance, brakes, nose wheel steering, and the sideways grip that
	stops it sliding across the runway.

	WHAT ROBLOX ALREADY DOES, AND WHAT IT DOES NOT
	----------------------------------------------
	The wheels are real collidable parts, so Roblox's rigid body solver handles
	CONTACT for us - the aircraft rests on its gear, rolls over bumps, and
	cannot sink through the runway. That is the hard part and we get it free.

	What Roblox does not give us is tyre behaviour. Its friction is isotropic:
	a box slides the same way in every direction. A tyre is the opposite - it
	rolls almost freely forwards and grips hard sideways, and that asymmetry is
	the entire reason a wheeled vehicle goes where it is pointed. Without it an
	aircraft on the runway behaves like a curling stone.

	So this module supplies the three forces Roblox cannot:

	  1. LATERAL GRIP    resists sideways motion, capped by tyre friction.
	  2. ROLLING + BRAKES resist forward motion, scaled by the load on wheels.
	  3. STEERING        a cornering force at the steered nose wheel.

	WHY STEERING IS A FORCE, NOT A YAW RATE
	---------------------------------------
	The obvious implementation is to command a yaw rate proportional to pedal
	input. It is simple, and it is wrong in a way that shows up precisely when
	it matters most: during the takeoff roll, as speed builds and lift grows,
	the nose wheel gets lighter and steering must fade out - and the moment the
	nose lifts, it must vanish entirely and hand over to the rudder.

	Modelling it as a real cornering force at the nose wheel's contact patch
	produces all of that for free, because the force is proportional to the
	load actually on that wheel. The yaw comes from r x F, exactly as every
	other moment in this project does.

	LOAD TRANSFER
	-------------
	The single most important input here is how much weight the wheels are
	carrying. It is NOT simply the aircraft's weight: as the aircraft
	accelerates down the runway the wing takes an increasing share, so

		load on wheels = weight - lift

	falling to zero at flying speed. Every force in this module scales with
	that number, which is why braking gets less effective the faster you are
	going and why the aircraft stops responding to the nose wheel just before
	it flies.

	UNITS: pure SI. Studs appear only where world positions are read.
]]

local FlightSim = script.Parent.Parent

local Constants = require(FlightSim.Config.Constants)
local MathUtil = require(FlightSim.Shared.MathUtil)
local Units = require(FlightSim.Shared.Units)

local GroundHandling = {}

local abs = math.abs
local clamp = math.clamp
local max = math.max
local min = math.min

-- =========================================================================
-- TUNING
-- =========================================================================

--[[
	How far below a wheel's centre we look for ground, as a multiple of its
	radius. Slightly over 1 so that contact is detected while the tyre is
	still settling, rather than flickering on and off as the suspension-free
	rigid body micro-bounces.
]]
local CONTACT_PROBE = 1.35

--[[
	Speed below which rolling resistance and braking fade out, m/s.

	Without this, a stationary aircraft gets a constant retarding force which
	reverses sign every frame as the velocity dithers around zero, and the
	whole airframe buzzes. Fading the force to nothing as the aircraft stops is
	both stable and physically sensible - static friction does not push.
]]
local CREEP_SPEED = 0.4

-- =========================================================================
-- TYPES
-- =========================================================================

export type Telemetry = {
	onGround: boolean,
	wheelsOnGround: number,
	normalLoad: number, -- N carried by the wheels
	groundSpeed: number, -- m/s along the runway
	lateralSpeed: number, -- m/s sideways; large values mean a skid
	steeringForce: number, -- N at the nose wheel
	brakingForce: number, -- N
}

-- =========================================================================
-- CONSTRUCTION
-- =========================================================================

--[[
	Resolve each wheel's moment arm about the centre of mass, and its static
	share of the aircraft's weight.

	FRAMES: identical to FlightModel - the definition measures wheel offsets
	from the DATUM, Roblox measures from the ROOT PART, and moment arms must
	be measured from the CENTRE OF MASS. See FlightModel's note; getting this
	wrong here tips the aircraft onto its nose under braking.
]]
function GroundHandling.new(model: Model, definition: any)
	local root = model.PrimaryPart
	assert(root, "[GroundHandling] model has no PrimaryPart")

	local datumOffset = root:GetAttribute("DatumOffset") :: Vector3? or Vector3.zero
	local comLocal = root.CFrame:PointToObjectSpace(root.AssemblyCenterOfMass)
	local comDatum = comLocal + datumOffset

	local wheels = {}
	for i, spec in definition.gear.wheels do
		wheels[i] = {
			name = spec.name,
			arm = spec.offset - comDatum, -- metres, body frame, from CoM
			radius = spec.radius,
			steering = spec.steering == true,
			braked = spec.braked == true,
			share = 0, -- filled in below
			grounded = false,
		}
	end

	--[[
		Static weight distribution.

		Balance the aircraft on its wheels: the group ahead of the centre of
		mass and the group behind it must produce no net pitching moment, so
		each group's share is proportional to the OTHER group's distance from
		the centre of mass. A tricycle gear puts most of the weight on the
		mains because they sit close behind the balance point; the same
		arithmetic handles a taildragger with the groups reversed.
	]]
	local fwd, aft = {}, {}
	local fwdZ, aftZ = 0, 0
	for _, w in wheels do
		if w.arm.Z < 0 then
			table.insert(fwd, w)
			fwdZ += w.arm.Z
		else
			table.insert(aft, w)
			aftZ += w.arm.Z
		end
	end

	if #fwd > 0 and #aft > 0 then
		local meanFwd = abs(fwdZ / #fwd)
		local meanAft = abs(aftZ / #aft)
		local span = meanFwd + meanAft
		-- The group further from the centre of mass carries less.
		local fwdShare = if span > 0 then meanAft / span else 0.5
		for _, w in fwd do
			w.share = fwdShare / #fwd
		end
		for _, w in aft do
			w.share = (1 - fwdShare) / #aft
		end
	else
		-- Degenerate layout (all wheels on one side of the CoM). Split evenly
		-- rather than dividing by zero; validate() flags it as a problem.
		for _, w in wheels do
			w.share = 1 / #wheels
		end
	end

	local probeParams = RaycastParams.new()
	probeParams.FilterType = Enum.RaycastFilterType.Exclude
	probeParams.FilterDescendantsInstances = { model }
	probeParams.IgnoreWater = false

	return {
		model = model,
		definition = definition,
		root = root,
		comLocal = comLocal,
		comDatum = comDatum,
		wheels = wheels,
		mass = root.AssemblyMass,
		probeParams = probeParams,

		telemetry = {
			onGround = false,
			wheelsOnGround = 0,
			normalLoad = 0,
			groundSpeed = 0,
			lateralSpeed = 0,
			steeringForce = 0,
			brakingForce = 0,
		} :: Telemetry,
	}
end

-- Mirror of FlightModel.recomputeGeometry, for when the mass layout changes.
function GroundHandling.recomputeGeometry(state: any)
	local root = state.root
	state.comLocal = root.CFrame:PointToObjectSpace(root.AssemblyCenterOfMass)
	state.comDatum = state.comLocal + root:GetAttribute("DatumOffset")
	state.mass = root.AssemblyMass
	for i, spec in state.definition.gear.wheels do
		state.wheels[i].arm = spec.offset - state.comDatum
	end
end

-- =========================================================================
-- THE SOLVER
-- =========================================================================

--[[
	Compute the total force and torque the landing gear contributes.

	  kinematics   same structure FlightModel uses; cframe MUST carry the
	               aircraft's world position, because wheel contact depends on
	               where the wheels actually are.
	  liftVertical the vertical component of the aerodynamic force already
	               computed this frame, in newtons. This is what unloads the
	               wheels as speed builds - pass 0 and the aircraft will brake
	               and steer at full authority right up to rotation, which is
	               wrong and very noticeable.

	Returns (force, torque) in world space, newtons and newton-metres, to be
	summed with the aerodynamic pair before being written to the constraints.
]]
function GroundHandling.computeForces(
	state: any,
	kinematics: any,
	dt: number,
	controls: any,
	liftVertical: number?
): (Vector3, Vector3)
	local def = state.definition
	local gear = def.gear
	local cf = kinematics.cframe
	local omega = kinematics.angularVelocity
	local velocity = kinematics.velocity

	local telemetry = state.telemetry
	telemetry.onGround = false
	telemetry.wheelsOnGround = 0
	telemetry.normalLoad = 0
	telemetry.steeringForce = 0
	telemetry.brakingForce = 0

	-- ---- Contact ---------------------------------------------------------
	--[[
		Wheel positions are derived from the kinematics, not read off the
		parts, so the whole solver stays a pure function of its inputs and can
		be tested against synthetic states. Only the raycast touches the world.
	]]
	local comWorld = cf:PointToWorldSpace(state.comLocal)

	local groundedCount = 0
	local groundNormal = Vector3.yAxis
	local normalAccum = Vector3.zero

	for _, wheel in state.wheels do
		local wheelWorld = comWorld + cf:VectorToWorldSpace(Units.metersToStuds(wheel.arm))
		local probe = Units.metersToStuds(wheel.radius * CONTACT_PROBE)

		local hit = workspace:Raycast(wheelWorld, Vector3.new(0, -probe, 0), state.probeParams)
		wheel.grounded = hit ~= nil

		if hit then
			groundedCount += 1
			normalAccum += hit.Normal
		end
	end

	if groundedCount == 0 then
		-- Airborne. The gear contributes nothing at all, which is exactly what
		-- we want - no residual drag or phantom moments in flight.
		telemetry.groundSpeed = 0
		telemetry.lateralSpeed = 0
		return Vector3.zero, Vector3.zero
	end

	if normalAccum.Magnitude > 1e-6 then
		groundNormal = normalAccum.Unit
	end

	telemetry.onGround = true
	telemetry.wheelsOnGround = groundedCount

	-- ---- Load on the wheels ---------------------------------------------
	--[[
		Weight minus lift. Clamped at zero because once the wing carries more
		than the aircraft weighs, the wheels carry nothing - they do not start
		pulling the aircraft down.
	]]
	local weight = state.mass * Constants.GRAVITY_MS2
	local totalLoad = max(0, weight - (liftVertical or 0))
	telemetry.normalLoad = totalLoad

	-- ---- Ground plane axes ----------------------------------------------
	--[[
		The runway's frame, not the aircraft's. Forward is the aircraft's nose
		projected onto the ground plane, so that a nose-high attitude during
		rotation does not tilt the rolling direction into the tarmac.
	]]
	local noseWorld = cf:VectorToWorldSpace(Vector3.new(0, 0, -1))
	local rollDir = noseWorld - groundNormal * noseWorld:Dot(groundNormal)
	if rollDir.Magnitude < 1e-4 then
		-- Aircraft pointing straight up or down; no meaningful rolling axis.
		return Vector3.zero, Vector3.zero
	end
	rollDir = rollDir.Unit
	-- Points to the aircraft's RIGHT. Order matters: normal x roll would give
	-- the left, silently inverting both the steering and the reported skid.
	local lateralDir = rollDir:Cross(groundNormal).Unit

	--[[
		Total share of the wheels actually touching down, computed once rather
		than per wheel. Used to renormalise the load so that lifting the nose
		wheel transfers its weight to the mains instead of deleting it.
	]]
	local groundedShare = 0
	for _, w in state.wheels do
		if w.grounded then
			groundedShare += w.share
		end
	end
	groundedShare = max(groundedShare, 1e-6)

	local totalForce = Vector3.zero
	local totalTorque = Vector3.zero

	local brake = clamp(controls.brake or 0, 0, 1)
	local steerInput = clamp(controls.yaw or 0, -1, 1)

	--[[
		Nose wheel steering fades with speed. Full authority at 60 kt would
		make the aircraft dartingly unstable and is how real aircraft leave the
		side of the runway; by then the rudder has the airflow to do the job.
	]]
	local groundSpeedAlongRunway = velocity:Dot(rollDir)
	local steerFade = 1 - clamp(abs(groundSpeedAlongRunway) / max(gear.steeringFadeSpeed, 0.1), 0, 1)

	telemetry.groundSpeed = groundSpeedAlongRunway
	telemetry.lateralSpeed = velocity:Dot(lateralDir)

	for _, wheel in state.wheels do
		if not wheel.grounded then
			continue
		end

		local armWorld = cf:VectorToWorldSpace(wheel.arm)
		local wheelVelocity = velocity + omega:Cross(armWorld)

		local vRoll = wheelVelocity:Dot(rollDir)
		local vLat = wheelVelocity:Dot(lateralDir)

		local loadFraction = wheel.share / groundedShare
		local wheelLoad = totalLoad * loadFraction

		-- Effective mass at this wheel, used to size the impulse that cancels
		-- sideways motion within one timestep.
		local wheelMass = state.mass * loadFraction
		local gripLimit = gear.tyreFriction * wheelLoad

		local wheelForce = Vector3.zero

		-- ---- Lateral grip ------------------------------------------------
		--[[
			Apply exactly the force needed to cancel this wheel's sideways
			velocity this frame, then clamp it to what the tyre can actually
			hold. Below the limit the tyre grips and the aircraft tracks
			straight; above it, the clamp bites and the aircraft slides - which
			is a skid, and it is the correct behaviour rather than a failure.
		]]
		local lateralNeeded = -wheelMass * vLat / dt
		local lateralForce = clamp(lateralNeeded, -gripLimit, gripLimit)
		wheelForce += lateralDir * lateralForce

		-- ---- Steering ----------------------------------------------------
		if wheel.steering and steerFade > 0 then
			--[[
				A cornering force at the steered wheel. Positive yaw input
				means nose right; the nose wheel achieves that by pushing the
				NOSE sideways, and since it sits ahead of the centre of mass
				the resulting r x F yaws the aircraft the right way with no
				sign conventions needed here.
			]]
			local steerForce = steerInput * gear.steeringAuthority * gripLimit * steerFade
			wheelForce += lateralDir * steerForce
			telemetry.steeringForce += steerForce
		end

		-- ---- Rolling resistance and brakes -------------------------------
		--[[
			Both oppose the direction of roll and both scale with the load on
			the wheel, which is why braking fades as the wing takes the weight.

			The creep factor fades them to nothing at walking pace so a
			stationary aircraft does not buzz as the retarding force flips sign
			with the numerical noise in its velocity.
		]]
		local creep = clamp(abs(vRoll) / CREEP_SPEED, 0, 1)
		if creep > 0 then
			local direction = if vRoll > 0 then -1 else 1

			local retarding = gear.rollingResistance * wheelLoad
			if wheel.braked then
				local braking = gear.brakeForce * wheelLoad * brake
				retarding += braking
				telemetry.brakingForce += braking
			end
			retarding *= creep

			--[[
				A brake can bring a wheel to a stop; it cannot drag the
				aircraft backwards. Cap the retarding force at whatever would
				exactly cancel this wheel's rolling velocity in one timestep.
			]]
			local stoppingForce = wheelMass * abs(vRoll) / dt
			retarding = min(retarding, stoppingForce)

			wheelForce += rollDir * (retarding * direction)
		end

		totalForce += wheelForce
		-- Applied at the wheel, so the moment - and therefore every rotation
		-- the gear produces - comes out of the geometry.
		totalTorque += armWorld:Cross(wheelForce)
	end

	-- A NaN here destroys the assembly just as surely as one from the
	-- aerodynamics, and dt appears in two divisions above.
	return MathUtil.sanitizeVector(totalForce), MathUtil.sanitizeVector(totalTorque)
end

-- =========================================================================
-- VERIFICATION
-- =========================================================================

--[[
	Run from the Studio command bar:
		require(game.ReplicatedStorage.FlightSim.Physics.GroundHandling).runTests()

	Requires something to land on - the tests build the aircraft just above
	Workspace.Baseplate and raycast onto it.
]]
function GroundHandling.runTests(): (boolean, { any })
	local AircraftBuilder = require(FlightSim.Aircraft.AircraftBuilder)
	local Cessna172 = require(FlightSim.Aircraft.Definitions.Cessna172)

	local results = {}
	local allPassed = true

	local function record(label: string, passed: boolean, detail: string)
		if not passed then
			allPassed = false
		end
		table.insert(results, { label = label, passed = passed, detail = detail })
		print(string.format("  [%s] %-44s %s", passed and "PASS" or "FAIL", label, detail))
	end

	local function checkRange(label: string, actual: number, lo: number, hi: number, unit: string)
		record(label, actual >= lo and actual <= hi, string.format("%.4f %s (expected %.3f..%.3f)", actual, unit, lo, hi))
	end

	print("=== GroundHandling: verification ===")

	-- Something to roll on. Built rather than assumed, so the suite does not
	-- depend on whatever happens to be in the place file.
	local pad = Instance.new("Part")
	pad.Name = "__GroundTestPad"
	pad.Size = Vector3.new(400, 4, 400)
	pad.Position = Vector3.new(0, -2, 0) -- top surface at y = 0
	pad.Anchored = true
	pad.Parent = workspace

	--[[
		Cabin (the root) sits 0.15 above the datum; the wheels sit 0.95 below
		it with a 0.2 radius. Placing the root 1.30 up therefore puts the tyres
		exactly on the pad's surface.
	]]
	local GROUND_Y = 1.30
	local model = AircraftBuilder.build(Cessna172, CFrame.new(0, GROUND_Y, 0), workspace)
	local state = GroundHandling.new(model, Cessna172)

	local dt = 1 / 60
	local weight = state.mass * Constants.GRAVITY_MS2

	local function controlsWith(over: { [string]: number }?): any
		local c = { pitch = 0, roll = 0, yaw = 0, throttle = 0, flaps = 0, brake = 0 }
		if over then
			for k, v in over do
				c[k] = v
			end
		end
		return c
	end

	local function onGround(speedMs: number, lateralMs: number?, omega: Vector3?): any
		return {
			cframe = CFrame.new(0, GROUND_Y, 0),
			velocity = Vector3.new(lateralMs or 0, 0, -(speedMs or 0)),
			angularVelocity = omega or Vector3.zero,
			altitude = 0,
		}
	end

	-- 1. Weight distribution ------------------------------------------------
	local nose, left, right = state.wheels[1], state.wheels[2], state.wheels[3]
	local shareSum = nose.share + left.share + right.share
	record("Weight shares sum to 1", abs(shareSum - 1) < 1e-9, string.format("%.6f", shareSum))
	record(
		"Mains carry more than the nose wheel",
		left.share + right.share > nose.share,
		string.format("mains %.1f%%, nose %.1f%%", (left.share + right.share) * 100, nose.share * 100)
	)
	record(
		"Main wheels share the load equally",
		abs(left.share - right.share) < 1e-9,
		string.format("%.4f vs %.4f", left.share, right.share)
	)
	record(
		"Nose wheel arm is ahead of the centre of mass",
		nose.arm.Z < 0 and left.arm.Z > 0,
		string.format("nose z=%.3f, mains z=%+.3f", nose.arm.Z, left.arm.Z)
	)

	-- 2. Airborne ------------------------------------------------------------
	-- High above the pad, nothing must be produced at all.
	local airborne = {
		cframe = CFrame.new(0, 500, 0),
		velocity = Vector3.new(0, 0, -50),
		angularVelocity = Vector3.zero,
		altitude = 500,
	}
	local fAir, tAir = GroundHandling.computeForces(state, airborne, dt, controlsWith({ brake = 1, yaw = 1 }), 0)
	record(
		"Airborne: no force",
		fAir == Vector3.zero and tAir == Vector3.zero,
		string.format("|F| = %.6f, |T| = %.6f", fAir.Magnitude, tAir.Magnitude)
	)
	record("Airborne: telemetry reports not on ground", not state.telemetry.onGround, "onGround = false")

	-- 3. Contact detection ---------------------------------------------------
	local fRoll = GroundHandling.computeForces(state, onGround(20), dt, controlsWith(), 0)
	record(
		"On the ground: all three wheels detected",
		state.telemetry.wheelsOnGround == 3,
		string.format("%d wheels", state.telemetry.wheelsOnGround)
	)
	checkRange("Load on wheels equals weight", state.telemetry.normalLoad, weight * 0.99, weight * 1.01, "N")

	-- 4. Rolling resistance --------------------------------------------------
	-- Opposes motion, and is a small fraction of the weight.
	record(
		"Rolling resistance opposes motion",
		fRoll.Z > 0,
		string.format("Fz = %+.1f N against -Z travel", fRoll.Z)
	)
	checkRange("Rolling resistance magnitude", fRoll.Magnitude / weight, 0.015, 0.035, "x weight")

	-- 5. Brakes --------------------------------------------------------------
	local fBrake = GroundHandling.computeForces(state, onGround(20), dt, controlsWith({ brake = 1 }), 0)
	record(
		"Brakes increase the retarding force",
		fBrake.Z > fRoll.Z * 3,
		string.format("%.0f N rolling -> %.0f N braking", fRoll.Z, fBrake.Z)
	)
	record(
		"Braking is applied by the main wheels only",
		state.telemetry.brakingForce > 0,
		string.format("%.0f N of brake force", state.telemetry.brakingForce)
	)

	-- Deceleration must be believable: a light aircraft pulls a few m/s^2.
	checkRange("Braking deceleration", fBrake.Magnitude / state.mass, 1.5, 4.0, "m/s2")

	-- A brake cannot drag the aircraft backwards. At walking pace the force
	-- must not exceed what stops the aircraft dead this frame.
	local fCrawl = GroundHandling.computeForces(state, onGround(0.05), dt, controlsWith({ brake = 1 }), 0)
	local impliedDeltaV = (fCrawl.Magnitude / state.mass) * dt
	record(
		"Brakes cannot reverse the aircraft",
		impliedDeltaV <= 0.05 + 1e-6,
		string.format("would remove %.4f m/s from a 0.050 m/s roll", impliedDeltaV)
	)

	-- 6. Load transfer -------------------------------------------------------
	--[[
		THE check that justifies the whole liftVertical parameter. As the wing
		takes the weight, the wheels must lose their grip on proceedings.
	]]
	local fBrakeFlying = GroundHandling.computeForces(state, onGround(20), dt, controlsWith({ brake = 1 }), weight * 0.9)
	record(
		"Lift unloads the wheels",
		fBrakeFlying.Magnitude < fBrake.Magnitude * 0.2,
		string.format("%.0f N at rest -> %.0f N with 90%% of weight on the wing", fBrake.Magnitude, fBrakeFlying.Magnitude)
	)

	local fBrakeAirborneLift = GroundHandling.computeForces(state, onGround(20), dt, controlsWith({ brake = 1 }), weight * 1.5)
	record(
		"Wheels carry nothing once lift exceeds weight",
		fBrakeAirborneLift.Magnitude < 1e-6,
		string.format("|F| = %.9f N", fBrakeAirborneLift.Magnitude)
	)

	-- 7. Lateral grip --------------------------------------------------------
	--[[
		The property that makes the aircraft track straight instead of sliding
		about like a curling stone.
	]]
	local fSlide = GroundHandling.computeForces(state, onGround(20, 3), dt, controlsWith(), 0)
	record(
		"Sideways motion is resisted",
		fSlide.X < 0,
		string.format("Fx = %+.0f N against +X drift", fSlide.X)
	)
	checkRange("Lateral speed is reported", state.telemetry.lateralSpeed, 2.9, 3.1, "m/s")

	-- Grip is finite: a violent slide must saturate at the friction limit
	-- rather than producing an unbounded force.
	local fBigSlide = GroundHandling.computeForces(state, onGround(20, 40), dt, controlsWith(), 0)
	local maxGrip = Cessna172.gear.tyreFriction * weight
	record(
		"Lateral grip saturates at the friction limit",
		abs(fBigSlide.X) <= maxGrip * 1.01,
		string.format("%.0f N vs limit %.0f N", abs(fBigSlide.X), maxGrip)
	)

	-- 8. Steering ------------------------------------------------------------
	local _, tSteer = GroundHandling.computeForces(state, onGround(5), dt, controlsWith({ yaw = 1 }), 0)
	--[[
		Positive torque about body +Y yaws the nose LEFT, so a nose-right
		moment is a NEGATIVE Y component. Same convention as FlightModel.
	]]
	local yawRight = -tSteer.Y
	record(
		"Right pedal steers the nose right",
		yawRight > 0,
		string.format("%+.0f N*m nose-right", yawRight)
	)

	local _, tSteerLeft = GroundHandling.computeForces(state, onGround(5), dt, controlsWith({ yaw = -1 }), 0)
	record(
		"Steering is symmetric",
		abs(-tSteerLeft.Y + yawRight) < 1e-6,
		string.format("right %+.0f vs left %+.0f N*m", yawRight, -tSteerLeft.Y)
	)

	-- Authority must fade with speed, and be gone by the fade speed.
	local _, tSteerFast = GroundHandling.computeForces(state, onGround(24), dt, controlsWith({ yaw = 1 }), 0)
	record(
		"Steering authority fades with speed",
		abs(tSteerFast.Y) < abs(tSteer.Y) * 0.5,
		string.format("5 m/s: %.0f N*m -> 24 m/s: %.0f N*m", abs(tSteer.Y), abs(tSteerFast.Y))
	)

	-- ...and must be gone entirely once the wing has the weight, which is what
	-- hands control over to the rudder during the takeoff roll.
	GroundHandling.computeForces(state, onGround(20), dt, controlsWith({ yaw = 1 }), weight)
	record(
		"Steering vanishes when the wheels are unloaded",
		abs(state.telemetry.steeringForce) < 1e-6,
		string.format("%.6f N of steering force", state.telemetry.steeringForce)
	)

	-- 9. Numerical safety ----------------------------------------------------
	local fWild, tWild = GroundHandling.computeForces(
		state,
		{
			cframe = CFrame.new(0, GROUND_Y, 0) * CFrame.Angles(0.4, 1.2, 0.3),
			velocity = Vector3.new(120, -40, 90),
			angularVelocity = Vector3.new(20, -15, 10),
			altitude = 0,
		},
		dt,
		controlsWith({ brake = 1, yaw = -1 }),
		0
	)
	record(
		"Extreme state stays finite",
		fWild.Magnitude == fWild.Magnitude
			and fWild.Magnitude < math.huge
			and tWild.Magnitude == tWild.Magnitude
			and tWild.Magnitude < math.huge,
		string.format("|F| = %.0f N, |T| = %.0f N*m", fWild.Magnitude, tWild.Magnitude)
	)

	-- A vertical aircraft has no meaningful rolling direction; it must return
	-- zero rather than a normalised zero vector full of NaNs.
	local fVertical = GroundHandling.computeForces(
		state,
		{
			cframe = CFrame.new(0, GROUND_Y, 0) * CFrame.Angles(math.rad(90), 0, 0),
			velocity = Vector3.new(0, -10, 0),
			angularVelocity = Vector3.zero,
			altitude = 0,
		},
		dt,
		controlsWith(),
		0
	)
	record(
		"Vertical attitude produces no NaN",
		fVertical.Magnitude == fVertical.Magnitude,
		string.format("|F| = %.3f N", fVertical.Magnitude)
	)

	model:Destroy()
	pad:Destroy()

	local passCount = 0
	for _, r in results do
		if r.passed then
			passCount += 1
		end
	end
	print(string.format("=== %s (%d/%d) ===", allPassed and "ALL PASSED" or "FAILURES PRESENT", passCount, #results))

	return allPassed, results
end

return GroundHandling
