--!strict
--[[
	Engine
	------
	Piston engine and fixed-pitch propeller model.

	WHY NOT JUST "thrust = throttle * maxThrust"
	--------------------------------------------
	Because a propeller is not a rocket. A rocket produces the same thrust at
	any speed; a propeller produces a great deal of thrust when stationary and
	steadily less as the aircraft accelerates, because the engine delivers
	POWER, and thrust is power divided by speed.

	That single fact is responsible for most of how a light aircraft behaves:

	  - Strong acceleration at the start of the takeoff roll that tails off.
	  - A definite maximum level speed, reached when the falling thrust curve
	    meets the rising drag curve. No artificial speed cap is needed.
	  - Climb performance that decays with altitude until the aircraft simply
	    cannot climb any more - a service ceiling that emerges on its own.

	THE MODEL
	---------
	  1. Available power = rated power x throttle x an altitude correction.
	  2. Static thrust from momentum theory - what the prop can produce at
	     zero airspeed.
	  3. A blend between the two that is exact at both ends.

	UNITS: SI throughout (watts, newtons, m/s, kg). Configuration may be
	given in horsepower; convert with Shared/Units at definition time.
]]

local MathUtil = require(script.Parent.Parent.Shared.MathUtil)

local Engine = {}

local sqrt = math.sqrt
local pi = math.pi
local max = math.max

-- =========================================================================
-- TYPES
-- =========================================================================

export type Config = {
	maxPowerW: number, -- rated shaft power at sea level
	propDiameter: number, -- m
	propEfficiency: number, -- cruise propulsive efficiency, ~0.8 for a good fixed-pitch prop
	figureOfMerit: number, -- how close the prop gets to ideal static thrust, ~0.55

	idleRPM: number,
	maxRPM: number,
	idlePowerFraction: number, -- power produced at closed throttle

	bsfc: number, -- brake specific fuel consumption, kg per joule
	fuelCapacityKg: number,

	spoolTime: number, -- seconds for the engine to answer a throttle change
	startTime: number, -- seconds for the starter to bring it to life

	thrustOffset: Vector3, -- m, thrust application point relative to the datum

	-- Left-turning tendencies. A clockwise-turning propeller (viewed from the
	-- cockpit) tries to roll the aircraft the other way, and its spiralling
	-- slipstream strikes the left side of the fin, yawing the nose left. Every
	-- pilot learns to hold right rudder on takeoff because of these.
	torqueReaction: number, -- N*m of roll per watt of power
	slipstreamYaw: number, -- N*m of yaw per watt of power

	-- Extra parasitic drag coefficient from a windmilling propeller, on the
	-- wing reference area. Significant: it roughly doubles a light single's
	-- zero-lift drag and is why published glide ratios look poor next to what
	-- the airframe alone would manage.
	windmillCD0: number,
}

export type State = {
	running: boolean,
	starting: boolean,
	startProgress: number,

	throttleInput: number, -- what the pilot has commanded, 0-1
	throttleActual: number, -- what the engine has actually reached, 0-1

	rpm: number,
	powerW: number,
	thrustN: number,

	fuelKg: number,
	fuelFlowKgS: number,
}

-- =========================================================================
-- CONSTRUCTION
-- =========================================================================

function Engine.createState(config: Config): State
	return {
		running = false,
		starting = false,
		startProgress = 0,

		throttleInput = 0,
		throttleActual = 0,

		rpm = 0,
		powerW = 0,
		thrustN = 0,

		fuelKg = config.fuelCapacityKg,
		fuelFlowKgS = 0,
	}
end

-- =========================================================================
-- POWER
-- =========================================================================

--[[
	Altitude correction for a normally aspirated engine (the Gagg-Farrar
	relation, standard in aircraft performance work):

		P / P_sealevel = 1.132 * sigma - 0.132

	where sigma is the density ratio. The engine breathes air, so less dense
	air means less oxygen, means less power. It falls off slightly faster than
	density alone because friction losses stay constant while output drops.

	At 8,000 ft (sigma 0.786) this gives 76% power, matching the figure in the
	real aircraft's cruise performance tables - which is exactly why a Cessna
	is usually flown at "75% power" up there with the throttle wide open.
]]
function Engine.getPowerFactor(densityRatio: number): number
	return max(0, 1.132 * densityRatio - 0.132)
end

--[[
	Static thrust from momentum theory.

	An ideal actuator disc of area A, absorbing power P in air of density rho,
	produces T = (2 * rho * A * P^2)^(1/3) at zero forward speed. Real
	propellers fall short of the ideal because of blade drag, tip losses and
	swirl, so the result is scaled by a figure of merit (~0.55 for a fixed
	pitch prop optimised for cruise rather than static pull).

	For the Cessna's 180 hp and 1.93 m propeller this predicts about 2,780 N,
	which is in line with measured figures for the type.
]]
function Engine.getStaticThrust(powerW: number, propDiameter: number, density: number, figureOfMerit: number): number
	if powerW <= 0 then
		return 0
	end
	local discArea = pi * (propDiameter * 0.5) ^ 2
	local ideal = (2 * density * discArea * powerW * powerW) ^ (1 / 3)
	return figureOfMerit * ideal
end

--[[
	Thrust at forward speed.

	Two limits have to be respected:
	  at V = 0        thrust is the static thrust above;
	  at high V       thrust approaches P * efficiency / V.

	The naive way to combine them is min() of the two, but that produces a
	kink in the thrust curve exactly in the speed range used for climbing,
	which is felt as a strange step in acceleration. This form:

		T = T_static / sqrt(1 + (V / V_transition)^2)

	is smooth everywhere, exact at V = 0, and converges to P*eta/V at speed
	(because T_static * V_transition = P * eta by construction).
]]
function Engine.getThrust(
	powerW: number,
	airspeedMs: number,
	propDiameter: number,
	density: number,
	figureOfMerit: number,
	propEfficiency: number
): number
	local staticThrust = Engine.getStaticThrust(powerW, propDiameter, density, figureOfMerit)
	if staticThrust <= 0 then
		return 0
	end

	-- Speed at which the power-limited and thrust-limited curves cross.
	local transitionSpeed = (powerW * propEfficiency) / staticThrust
	if transitionSpeed <= 0 then
		return staticThrust
	end

	-- Only forward motion unloads the propeller. Flying backwards does not
	-- give the engine more thrust, so clamp negative airspeed to zero.
	local v = max(0, airspeedMs)
	local ratio = v / transitionSpeed

	return staticThrust / sqrt(1 + ratio * ratio)
end

-- =========================================================================
-- UPDATE
-- =========================================================================

--[[
	Advance the engine one timestep.

		state       mutated in place
		throttle    pilot demand, 0-1
		airspeedMs  forward component of airspeed, m/s
		density     ambient air density, kg/m^3
		densityRatio  density / sea level density

	Returns thrust in newtons (also written to state.thrustN).
]]
function Engine.update(
	state: State,
	config: Config,
	dt: number,
	throttle: number,
	airspeedMs: number,
	density: number,
	densityRatio: number
): number
	state.throttleInput = math.clamp(throttle, 0, 1)

	-- ---- Starting --------------------------------------------------------
	if state.starting then
		state.startProgress += dt / max(config.startTime, 0.01)
		if state.startProgress >= 1 then
			state.starting = false
			state.startProgress = 0
			-- No fuel, no start. The starter will turn it over forever.
			state.running = state.fuelKg > 0
		end
	end

	if not state.running then
		-- Windmilling: the propeller keeps turning in the airstream, so the
		-- tachometer does not read zero in flight even with the engine dead.
		state.rpm = if state.starting
			then config.idleRPM * 0.4
			else math.min(airspeedMs * 12, config.idleRPM * 0.9)
		state.powerW = 0
		state.thrustN = 0
		state.fuelFlowKgS = 0
		state.throttleActual = 0
		return 0
	end

	-- ---- Throttle response ----------------------------------------------
	-- A real engine takes a moment to answer the throttle. Frame-rate
	-- independent, so response is identical at 30 and 240 fps.
	state.throttleActual = MathUtil.damp(state.throttleActual, state.throttleInput, 1 / max(config.spoolTime, 0.01), dt)

	-- ---- Power -----------------------------------------------------------
	-- Idle floor: a running engine never produces zero power, which is why an
	-- aircraft at idle still taxis forward and still floats down the runway
	-- if the approach is flown too fast.
	local throttleFraction = config.idlePowerFraction
		+ (1 - config.idlePowerFraction) * state.throttleActual

	state.powerW = config.maxPowerW * throttleFraction * Engine.getPowerFactor(densityRatio)

	-- ---- RPM -------------------------------------------------------------
	-- Fixed-pitch propeller: RPM rises with throttle, and rises further as
	-- forward speed unloads the blades. This is why the tachometer creeps up
	-- in a dive and sags in a climb at a constant throttle setting.
	local loadRelief = math.clamp(airspeedMs / 70, 0, 1) * 0.12
	local rpmFraction = math.clamp(throttleFraction * (0.9 + loadRelief), 0, 1)
	state.rpm = config.idleRPM + (config.maxRPM - config.idleRPM) * rpmFraction

	-- ---- Fuel ------------------------------------------------------------
	state.fuelFlowKgS = state.powerW * config.bsfc
	state.fuelKg = max(0, state.fuelKg - state.fuelFlowKgS * dt)

	if state.fuelKg <= 0 then
		-- Fuel exhaustion. The engine stops, and the aircraft becomes a glider
		-- with a windmilling propeller - which is the correct outcome and a
		-- genuinely useful thing for a simulator to model honestly.
		state.running = false
		state.powerW = 0
		state.thrustN = 0
		state.fuelFlowKgS = 0
		return 0
	end

	-- ---- Thrust ----------------------------------------------------------
	state.thrustN = Engine.getThrust(
		state.powerW,
		airspeedMs,
		config.propDiameter,
		density,
		config.figureOfMerit,
		config.propEfficiency
	)

	return state.thrustN
end

-- =========================================================================
-- CONTROLS
-- =========================================================================

function Engine.start(state: State, config: Config)
	if state.running or state.starting then
		return
	end
	if state.fuelKg <= 0 then
		return
	end
	state.starting = true
	state.startProgress = 0
end

function Engine.stop(state: State)
	state.running = false
	state.starting = false
	state.startProgress = 0
	state.throttleActual = 0
end

-- Skip the starter entirely. Used when spawning an aircraft already running,
-- which is how most flights will begin.
function Engine.setRunning(state: State, config: Config)
	state.running = state.fuelKg > 0
	state.starting = false
	state.startProgress = 0
	state.rpm = config.idleRPM
end

function Engine.refuel(state: State, config: Config, kg: number?)
	state.fuelKg = math.clamp(state.fuelKg + (kg or config.fuelCapacityKg), 0, config.fuelCapacityKg)
end

--[[
	Extra parasitic drag coefficient contributed by the propeller.

	A propeller driven by a running engine is pulling. A propeller being
	turned by the airstream is a disc of blades absorbing energy - a large
	drag source. Between the two extremes the contribution scales with how
	little power is being produced.
]]
function Engine.getPropDragCD0(state: State, config: Config): number
	if not state.running then
		return config.windmillCD0
	end
	return config.windmillCD0 * (1 - state.throttleActual)
end

-- =========================================================================
-- VERIFICATION
-- =========================================================================

--[[
	Validates the model against published Cessna 172S performance.

	Run from the Studio command bar:
		require(game.ReplicatedStorage.FlightSim.Physics.Engine).runTests()
]]
function Engine.runTests(): (boolean, { any })
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
		record(label, actual >= lo and actual <= hi, string.format("%.2f %s (expected %.2f..%.2f)", actual, unit, lo, hi))
	end

	print("=== Engine: verification ===")

	local config: Config = {
		maxPowerW = 134226, -- 180 hp
		propDiameter = 1.93,
		propEfficiency = 0.80,
		figureOfMerit = 0.55,
		idleRPM = 600,
		maxRPM = 2700,
		idlePowerFraction = 0.05,
		bsfc = 7.6e-8,
		fuelCapacityKg = 153,
		spoolTime = 0.35,
		startTime = 1.5,
		thrustOffset = Vector3.new(0, 0.05, -1.6),
		torqueReaction = 0,
		slipstreamYaw = 0,
		windmillCD0 = 0.020,
	}

	local rhoSL = Atmosphere.getDensity(0)

	-- 1. Altitude power lapse ---------------------------------------------
	record("Full power at sea level", math.abs(Engine.getPowerFactor(1.0) - 1.0) < 1e-9, string.format("%.4f", Engine.getPowerFactor(1.0)))

	-- The reason a Cessna is flown at "75% power" at 8,000 ft with the
	-- throttle fully open.
	local sigma8000 = Atmosphere.getDensityRatio(2438)
	checkRange("Power factor at 8000 ft", Engine.getPowerFactor(sigma8000) * 100, 72, 80, "%")

	-- 2. Static thrust -----------------------------------------------------
	local staticThrust = Engine.getStaticThrust(config.maxPowerW, config.propDiameter, rhoSL, config.figureOfMerit)
	checkRange("Static thrust, full power", staticThrust, 2300, 3100, "N")

	-- Thrust-to-weight at takeoff weight must be plausible for a trainer
	-- (roughly a quarter of its weight).
	local weight = 1111 * 9.80665
	checkRange("Static thrust / weight", staticThrust / weight, 0.18, 0.32, "")

	-- 3. Thrust falls with speed ------------------------------------------
	local kt = 1852 / 3600
	local t0 = Engine.getThrust(config.maxPowerW, 0, config.propDiameter, rhoSL, config.figureOfMerit, config.propEfficiency)
	local t60 = Engine.getThrust(config.maxPowerW, 60 * kt, config.propDiameter, rhoSL, config.figureOfMerit, config.propEfficiency)
	local t120 = Engine.getThrust(config.maxPowerW, 120 * kt, config.propDiameter, rhoSL, config.figureOfMerit, config.propEfficiency)

	record(
		"Thrust decreases with airspeed",
		t0 > t60 and t60 > t120,
		string.format("0kt=%.0fN  60kt=%.0fN  120kt=%.0fN", t0, t60, t120)
	)
	record("Thrust at zero speed is static thrust", math.abs(t0 - staticThrust) < 1e-6, string.format("%.1f N", t0))

	-- At cruise, thrust must be enough to overcome roughly 1,300-1,600 N of
	-- drag - the balance point that sets maximum level speed.
	checkRange("Thrust at 120 kt, full power", t120, 1200, 1800, "N")

	-- High-speed asymptote must converge on the power-limited value P*eta/V.
	local vFast = 100.0
	local tFast = Engine.getThrust(config.maxPowerW, vFast, config.propDiameter, rhoSL, config.figureOfMerit, config.propEfficiency)
	local powerLimited = config.maxPowerW * config.propEfficiency / vFast
	record(
		"Converges to P*eta/V at speed",
		math.abs(tFast - powerLimited) / powerLimited < 0.12,
		string.format("%.0f N vs power-limited %.0f N", tFast, powerLimited)
	)

	-- 4. Live state --------------------------------------------------------
	local state = Engine.createState(config)
	record("Starts stopped", not state.running and state.thrustN == 0, "running=false")
	record("Starts with full fuel", math.abs(state.fuelKg - 153) < 1e-9, string.format("%.1f kg", state.fuelKg))

	-- A stopped engine produces no thrust no matter what the throttle says.
	local deadThrust = Engine.update(state, config, 1 / 60, 1.0, 30, rhoSL, 1.0)
	record("Stopped engine makes no thrust", deadThrust == 0, string.format("%.1f N", deadThrust))

	Engine.setRunning(state, config)
	record("setRunning brings it to life", state.running, string.format("rpm=%.0f", state.rpm))

	-- 5. Throttle lag ------------------------------------------------------
	-- One frame after a slam to full power the engine must NOT already be at
	-- full power; after a second it should be essentially there.
	Engine.update(state, config, 1 / 60, 1.0, 0, rhoSL, 1.0)
	record(
		"Throttle does not respond instantly",
		state.throttleActual < 0.2,
		string.format("%.3f after one frame", state.throttleActual)
	)

	for _ = 1, 60 do
		Engine.update(state, config, 1 / 60, 1.0, 0, rhoSL, 1.0)
	end
	record(
		"Throttle settles within a second",
		state.throttleActual > 0.9,
		string.format("%.3f after 1 s", state.throttleActual)
	)
	checkRange("RPM at full throttle", state.rpm, 2300, 2700, "rpm")

	-- 6. Fuel --------------------------------------------------------------
	-- A C172 burns roughly 34-38 litres/hour at cruise power. At 0.72 kg/l
	-- that is about 25-28 kg/h.
	local cruiseState = Engine.createState(config)
	Engine.setRunning(cruiseState, config)
	for _ = 1, 120 do
		Engine.update(cruiseState, config, 1 / 60, 0.75, 60, rhoSL, 1.0)
	end
	local burnPerHour = cruiseState.fuelFlowKgS * 3600
	checkRange("Fuel burn at cruise power", burnPerHour, 20, 34, "kg/h")
	checkRange("Endurance on full tanks", config.fuelCapacityKg / burnPerHour, 4.0, 7.5, "hours")

	-- Running the tanks dry must stop the engine, not produce free thrust.
	local dryState = Engine.createState(config)
	Engine.setRunning(dryState, config)
	dryState.fuelKg = 0.001
	Engine.update(dryState, config, 1.0, 1.0, 50, rhoSL, 1.0)
	record(
		"Fuel exhaustion stops the engine",
		not dryState.running and dryState.thrustN == 0,
		string.format("running=%s thrust=%.1f", tostring(dryState.running), dryState.thrustN)
	)

	-- 7. Idle --------------------------------------------------------------
	local idleState = Engine.createState(config)
	Engine.setRunning(idleState, config)
	for _ = 1, 120 do
		Engine.update(idleState, config, 1 / 60, 0, 0, rhoSL, 1.0)
	end
	-- An idling aircraft still creeps forward on the ground, and still floats
	-- if the approach is flown fast. Idle thrust must be small but real.
	checkRange("Idle thrust", idleState.thrustN, 150, 700, "N")
	checkRange("Idle RPM", idleState.rpm, 550, 900, "rpm")

	-- 8. Propeller drag ----------------------------------------------------
	record(
		"Dead engine adds full windmill drag",
		math.abs(Engine.getPropDragCD0(dryState, config) - config.windmillCD0) < 1e-9,
		string.format("CD0 += %.4f", Engine.getPropDragCD0(dryState, config))
	)
	record(
		"Full power adds no windmill drag",
		Engine.getPropDragCD0(state, config) < 0.002,
		string.format("CD0 += %.4f", Engine.getPropDragCD0(state, config))
	)

	-- 9. Altitude performance ---------------------------------------------
	-- Thrust at 10,000 ft must be clearly down on sea level - the mechanism
	-- behind the service ceiling.
	local rho10k = Atmosphere.getDensity(3048)
	local sigma10k = Atmosphere.getDensityRatio(3048)
	local powerHigh = config.maxPowerW * Engine.getPowerFactor(sigma10k)
	local thrustHigh = Engine.getThrust(powerHigh, 60 * kt, config.propDiameter, rho10k, config.figureOfMerit, config.propEfficiency)
	record(
		"Thrust falls with altitude",
		thrustHigh < t60 * 0.85,
		string.format("sea level %.0f N -> 10000 ft %.0f N", t60, thrustHigh)
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

return Engine
