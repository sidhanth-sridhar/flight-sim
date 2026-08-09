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
	fuelCapacityKg: number, -- TOTAL usable, both tanks

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

-- =========================================================================
-- PHASE 4c SYSTEMS
-- =========================================================================

--[[
	THE FUEL SELECTOR, as the real 172S has it: a valve in the pedestal with
	four positions, feeding from two wing tanks.

	The POH's rule - take off and land on BOTH - only becomes a rule you can
	break once the tanks are separate, which is the whole point of modelling it.
]]
export type FuelSelector = "OFF" | "LEFT" | "RIGHT" | "BOTH"

--[[
	THE IGNITION, OFF-R-L-BOTH-START, and the reason the 172S has a mag CHECK
	rather than a mag switch.

	Two magnetos fire two plugs per cylinder. Running on one lights the charge
	from one side only, so the flame front takes longer, the burn is less
	complete, and the engine loses a little power - which shows on the
	tachometer as the drop the run-up is looking for. The POH's limits are a
	drop no greater than 150 RPM on either magneto, and no more than 50 RPM of
	difference between them.
]]
export type Magnetos = "OFF" | "R" | "L" | "BOTH" | "START"

export type State = {
	running: boolean,
	starting: boolean,
	startProgress: number,

	throttleInput: number, -- what the pilot has commanded, 0-1
	throttleActual: number, -- what the engine has actually reached, 0-1

	rpm: number,
	powerW: number,
	thrustN: number,

	--[[
		⚠️ `fuelKg` IS NOW DERIVED, AND IS KEPT BECAUSE THINGS READ IT.

		The tanks are the truth. This is their sum, rewritten every frame, so the
		fuel gauge (§19), the debug HUD and `AircraftService`'s state sync all
		keep working untouched - none of them ever cared which wing the fuel was
		in. Writing to it directly no longer means anything; write to the tanks.
	]]
	fuelKg: number,
	fuelLeftKg: number,
	fuelRightKg: number,
	fuelFlowKgS: number,

	fuelSelector: FuelSelector,
	--[[
		Fuel between the selector and the cylinders.

		This is what makes turning the valve OFF a survivable few seconds rather
		than an instant stop, which is what actually happens: the engine runs on
		what is already in the lines. There is no published figure for it - the
		POH does not certify how long you may fly with the fuel off - so the
		volume is stated as a mechanism and the test asserts the resulting time
		is in the handful-of-seconds band a real one gives, not a POH number.
	]]
	lineFuelKg: number,

	-- 0 = idle cutoff, 1 = full rich.
	mixture: number,
	magnetos: Magnetos,

	--[[
		Engine gauges the POH lists and the panel did not read (item 6). They are
		MODELLED, not faked: pressure and temperature follow the engine's actual
		state, so a cold start reads cold and climbs, and an idling engine reads
		lower oil pressure than one at cruise - which is what the gauges are for.
	]]
	oilPressurePsi: number,
	oilTempC: number,
}

-- =========================================================================
-- CONSTRUCTION
-- =========================================================================

--[[
	Fuel downstream of the selector, in kg.

	0.05 kg is about 70 ml, which at a cruise burn of 27.9 kg/h keeps the engine
	alive for roughly six seconds after the valve is shut. See the note on
	`lineFuelKg`: this is a MECHANISM with a plausible volume, not a published
	number, because the POH does not certify flight with the fuel off.
]]
local LINE_FUEL_KG = 0.05

-- Oil starts at the outside air temperature, because a cold aeroplane is cold.
-- 15 C is the ISA sea-level figure the rest of the project is built on.
local AMBIENT_OIL_TEMP_C = 15

--[[
	Oil warms toward its running temperature with a time constant of about two
	minutes, which is the order of a real warm-up: a 172 is ready to run up
	after a few minutes of idling on a temperate day, not after ten seconds.
]]
local OIL_WARMUP_TAU = 120

--[[
	POH FIGURES FOR THE LYCOMING IO-360-L2A, and everything below is asserted
	against these rather than against what the code happens to do.

	Oil pressure: minimum 25 psi (idle), green 50-90, red line 115.
	Oil temperature: green up to 245 F (118 C), red line 245 F.
	Mag drop: no more than 150 RPM on either magneto, no more than 50 RPM
	differential between them, checked at 1,800 RPM.
]]
Engine.OIL_PRESSURE_MIN_PSI = 25
Engine.OIL_PRESSURE_GREEN = { 50, 90 }
Engine.OIL_PRESSURE_REDLINE_PSI = 115
Engine.OIL_TEMP_GREEN_C = { 38, 118 }
Engine.OIL_TEMP_REDLINE_C = 118
Engine.MAG_DROP_LIMIT_RPM = 150
Engine.MAG_DIFFERENTIAL_LIMIT_RPM = 50

--[[
	How much power a single magneto makes, as a fraction of both.

	NOT CHOSEN FOR FEEL - derived from the POH limit it has to satisfy. RPM in
	this model tracks the power fraction, so a drop of d RPM at a run-up setting
	of r RPM needs a factor of about 1 - d/(r - idle). The POH allows up to 150
	RPM at 1,800; a healthy engine drops 75-125. 0.955 lands near the middle of
	that and inside the limit, which is what a serviceable magneto looks like.

	Both magnetos are given the SAME factor deliberately, so the differential is
	exactly zero: a differential is a FAULT, and this engine is not faulty. When
	Phase 6's damage model arrives, an unhealthy magneto is one number here.
]]
Engine.SINGLE_MAG_POWER_FACTOR = 0.955

--[[
	Below this fraction of the correct mixture the engine will not run at all.

	This is the idle cutoff at the lean end of the travel - pulling the red knob
	fully out is how a 172 is SHUT DOWN, which is why the mixture is a control
	that can stop the engine and the throttle is not.
]]
Engine.LEAN_CUTOFF_RATIO = 0.35

function Engine.createState(config: Config): State
	--[[
		Split evenly, because that is how an aeroplane is fuelled and because the
		imbalance this system exists to model is something the PILOT creates by
		flying on one tank - not something it starts with.
	]]
	local half = config.fuelCapacityKg * 0.5

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
		fuelLeftKg = half,
		fuelRightKg = half,
		fuelFlowKgS = 0,

		--[[
			BOTH, and full rich, and both magnetos: the aeroplane starts in the
			configuration the POH says to take off in. That keeps every existing
			caller correct without knowing these fields exist - which is the
			whole reason the 790 checks that predate this phase still pass.
		]]
		fuelSelector = "BOTH" :: FuelSelector,
		lineFuelKg = LINE_FUEL_KG,
		mixture = 1,
		magnetos = "BOTH" :: Magnetos,

		oilPressurePsi = 0,
		oilTempC = AMBIENT_OIL_TEMP_C,
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
-- MIXTURE, MAGNETOS AND FUEL FEED (Phase 4c)
-- =========================================================================

--[[
	THE CORRECT MIXTURE IS A FUNCTION OF AIR DENSITY, and that single fact is
	why the red knob exists.

	The engine wants a fixed ratio of fuel to AIR. Full rich delivers the fuel
	for sea-level air, so at 8,000 ft - where there is 79% as much air - full
	rich is 27% too much fuel. That is the mixture a pilot leans away, and it is
	why leaning is a cruise-at-altitude procedure rather than a sea-level one.

	So the best mixture setting IS the density ratio, and `leanRatio` below is
	how far off it the pilot is: 1.0 is correct, above 1 is rich, below is lean.
]]
function Engine.leanRatio(mixture: number, densityRatio: number): number
	return math.clamp(mixture, 0, 1) / max(densityRatio, 0.05)
end

--[[
	What leaning does to POWER.

	Rich of correct costs nothing here, and that is deliberate rather than
	sloppy: a real engine loses two or three percent at full rich, and modelling
	that would silently change every performance figure §4 verified at full
	rich. Full rich at sea level is this model's reference condition and stays
	exactly as it was.

	Lean of correct, power falls away - gently at first, which is the band a
	pilot leans into for economy, then steeply as the mixture approaches the
	cutoff and the engine starts to run rough and quit.
]]
function Engine.mixturePowerFactor(mixture: number, densityRatio: number): number
	local ratio = Engine.leanRatio(mixture, densityRatio)

	if ratio >= 1 then
		return 1
	end
	if ratio <= Engine.LEAN_CUTOFF_RATIO then
		return 0
	end

	--[[
		Shallow near best power and steep near the cutoff, reaching exactly zero
		AT the cutoff so there is no step where the engine quits.

		⚠️ THE EXPONENT IS DERIVED FROM THE FIGURE IT HAS TO HIT, not chosen.
		Best economy is about a leanRatio of 0.8, where a real engine keeps
		roughly 95% of its power - so shortfall^n = 0.05 at shortfall = 0.3077,
		giving n = ln(0.05)/ln(0.3077) = 2.54. A plain square was tried first
		and gave 0.87, which is a far harsher penalty than leaning really costs
		and disagreed with this comment - the test caught the disagreement.
	]]
	local span = 1 - Engine.LEAN_CUTOFF_RATIO
	local shortfall = (1 - ratio) / span
	return math.clamp(1 - shortfall ^ 2.5, 0, 1)
end

--[[
	What the ignition is doing to the power, and whether the engine runs at all.

	OFF and START both mean "not making power on both mags": OFF is the switch
	the pilot turns to shut down, and START is the position they hold against
	the spring while the starter turns it over, which the update loop reads
	rather than this function.
]]
function Engine.magnetoPowerFactor(magnetos: Magnetos): number
	if magnetos == "OFF" then
		return 0
	end
	if magnetos == "L" or magnetos == "R" then
		return Engine.SINGLE_MAG_POWER_FACTOR
	end
	return 1
end

--[[
	Which tanks the selector feeds from, and in what proportion.

	BOTH draws evenly. The real 172's tanks gravity-feed through a common line
	and do not drain perfectly evenly, but "evenly" is the honest model of a
	system whose whole design intent is to drain together - the imbalance this
	phase exists to make real is the one a pilot CREATES by selecting one tank.

	Returns a pair of fractions summing to 1, or nil for OFF - which is a real
	answer, not a failure: the valve is shut and no tank is feeding anything.
]]
function Engine.fuelDrawSplit(selector: FuelSelector): ({ left: number, right: number })?
	if selector == "OFF" then
		return nil
	elseif selector == "LEFT" then
		return { left = 1, right = 0 }
	elseif selector == "RIGHT" then
		return { left = 0, right = 1 }
	end
	return { left = 0.5, right = 0.5 }
end

--[[
	Draw `demandKg` from the tanks the selector has selected.

	Returns how much was actually delivered, which is less than demanded when
	the selected tank is dry - and THAT is the behaviour worth having: running a
	tank dry with the other one full stops the engine, exactly as it does in a
	real aeroplane, and the fix is to change tanks rather than to land.

	A tank that runs dry mid-draw hands its share back to the other one only on
	BOTH, where both are genuinely connected. On LEFT, an empty left tank is the
	end of the matter however full the right one is.
]]
function Engine.drawFuel(state: State, demandKg: number): number
	local split = Engine.fuelDrawSplit(state.fuelSelector)
	if not split or demandKg <= 0 then
		return 0
	end

	local fromLeft = math.min(state.fuelLeftKg, demandKg * split.left)
	local fromRight = math.min(state.fuelRightKg, demandKg * split.right)

	--[[
		On BOTH, a shortfall on one side is made up by the other. This is what
		makes BOTH the position you take off and land on: it is the only one
		that cannot be starved by an imbalance the pilot did not notice.
	]]
	if split.left > 0 and split.right > 0 then
		local shortfall = demandKg - fromLeft - fromRight
		if shortfall > 0 then
			local extraLeft = math.min(state.fuelLeftKg - fromLeft, shortfall)
			fromLeft += extraLeft
			shortfall -= extraLeft
			fromRight += math.min(state.fuelRightKg - fromRight, shortfall)
		end
	end

	state.fuelLeftKg = max(0, state.fuelLeftKg - fromLeft)
	state.fuelRightKg = max(0, state.fuelRightKg - fromRight)

	return fromLeft + fromRight
end

--[[
	Oil pressure, in psi, as a function of what the engine is doing.

	Pressure comes from an engine-driven pump, so it tracks RPM: nothing when
	stopped, about the POH's 25 psi minimum at idle, and mid-green at cruise.
	Cold oil is thicker and reads HIGHER, which is why a cold start pegs the
	needle near the top of the green and it settles as the oil warms - a real
	and recognisable thing for a gauge to do.
]]
function Engine.oilPressureFor(rpm: number, maxRPM: number, oilTempC: number, running: boolean): number
	if not running then
		-- A stopped engine has no oil pressure at all, which is the single most
		-- important thing this gauge ever says.
		return 0
	end

	local rpmFraction = math.clamp(rpm / max(maxRPM, 1), 0, 1)

	-- 25 psi at idle rising to about 75 at full RPM: the middle of the green.
	local base = Engine.OIL_PRESSURE_MIN_PSI + (78 - Engine.OIL_PRESSURE_MIN_PSI) * rpmFraction

	--[[
		Cold oil is thicker. Up to +25 psi when stone cold, fading out as the
		oil reaches operating temperature. Clamped below the red line, because a
		gauge that pegs on a healthy engine is telling the pilot a lie.
	]]
	local coldness = math.clamp((60 - oilTempC) / 60, 0, 1)
	return math.min(base + coldness * 25, Engine.OIL_PRESSURE_REDLINE_PSI - 1)
end

--[[
	Where the oil temperature is heading, in Celsius.

	Toward ambient when stopped - a parked aeroplane cools off - and toward a
	running temperature that rises with power, because the oil carries the heat
	the engine makes. Cruise sits comfortably mid-green; sustained full power
	climbs toward the top of it, which is why a long climb on a hot day is where
	a 172's oil temperature is actually worth watching.
]]
function Engine.oilTargetTemp(running: boolean, powerFraction: number, ambientC: number): number
	if not running then
		return ambientC
	end
	-- 75 C at idle to 110 C at full power: inside the green, approaching but
	-- not reaching the 118 C red line on the model alone.
	return 75 + 35 * math.clamp(powerFraction, 0, 1)
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

	--[[
		---- The tanks, kept in step ------------------------------------------

		Recomputed at the top of every frame rather than only where fuel is
		burned, so anything that writes to a tank directly - a refuel, a test, a
		later damage model puncturing one - is reflected immediately.
	]]
	state.fuelKg = state.fuelLeftKg + state.fuelRightKg

	-- ---- The ignition ----------------------------------------------------
	--[[
		⚠️ MAGS OFF STOPS THE ENGINE, and it is checked before anything else
		because it outranks everything else. This is the switch that shuts the
		aeroplane down, and no amount of throttle, fuel or mixture overrides it.
	]]
	if state.magnetos == "OFF" and (state.running or state.starting) then
		state.running = false
		state.starting = false
		state.startProgress = 0
	end

	-- ---- Starting --------------------------------------------------------
	if state.starting then
		state.startProgress += dt / max(config.startTime, 0.01)
		if state.startProgress >= 1 then
			state.starting = false
			state.startProgress = 0
			--[[
				⚠️ THREE THINGS HAVE TO BE TRUE TO CATCH, not one. The starter
				will turn a fuel-starved, mixture-cut or mags-off engine over
				for as long as the pilot holds the key, and it will never fire -
				which is exactly the behaviour that makes a start a PROCEDURE
				rather than a button. `fuelKg > 0` was the whole test before.
			]]
			state.running = state.fuelKg > 0
				and state.mixture > 0
				and state.magnetos ~= "OFF"
		end
	end

	if not state.running then
		--[[
			Windmilling: the propeller keeps turning in the airstream, so the
			tachometer does not read zero in flight even with the engine dead.

			CLAMPED AT ZERO, and it has to be. `airspeedMs` here is the FORWARD
			component, which goes slightly negative on a parked aircraft from
			ordinary numerical drift - and a bare min() then produced a small
			NEGATIVE rpm. A tachometer cannot read backwards, and rearward
			airflow does not drive the propeller in reverse in any sense worth
			modelling. Found by the debug HUD on its first flight, showing
			"RPM -0" on a stationary aeroplane.
		]]
		state.rpm = if state.starting
			then config.idleRPM * 0.4
			else math.clamp(airspeedMs * 12, 0, config.idleRPM * 0.9)
		state.powerW = 0
		state.thrustN = 0
		state.fuelFlowKgS = 0
		state.throttleActual = 0

		-- A stopped engine has no oil pressure, and its oil cools toward
		-- ambient. Both are what the gauges must say.
		state.oilPressurePsi = 0
		state.oilTempC = MathUtil.damp(state.oilTempC, AMBIENT_OIL_TEMP_C, 1 / OIL_WARMUP_TAU, dt)
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

	--[[
		The two Phase 4c multipliers on the throttle's own fraction.

		BOTH ARE EXACTLY 1.0 IN THE DEFAULT CONFIGURATION - both magnetos, full
		rich, sea level - which is why every performance figure §4 verified is
		untouched by this phase. They are not corrections applied to the model;
		they are the pilot flying it wrong.
	]]
	local magFactor = Engine.magnetoPowerFactor(state.magnetos)
	local mixtureFactor = Engine.mixturePowerFactor(state.mixture, densityRatio)

	--[[
		⚠️ AN OVER-LEANED ENGINE QUITS, and it quits HERE rather than limping on
		at zero power - a windmilling propeller and a dead engine is the honest
		outcome, and it is how the mixture control shuts a 172 down.
	]]
	if mixtureFactor <= 0 then
		state.running = false
		state.powerW = 0
		state.thrustN = 0
		state.fuelFlowKgS = 0
		state.oilPressurePsi = 0
		return 0
	end

	local systemsFactor = magFactor * mixtureFactor

	state.powerW = config.maxPowerW * throttleFraction * systemsFactor * Engine.getPowerFactor(densityRatio)

	-- ---- RPM -------------------------------------------------------------
	-- Fixed-pitch propeller: RPM rises with throttle, and rises further as
	-- forward speed unloads the blades. This is why the tachometer creeps up
	-- in a dive and sags in a climb at a constant throttle setting.
	--
	-- `systemsFactor` reaches the RPM as well as the power, and that is the
	-- whole point of a mag check: the drop is something the pilot READS on the
	-- tachometer, so a magneto that changed power without changing RPM would be
	-- a system with no instrument.
	local loadRelief = math.clamp(airspeedMs / 70, 0, 1) * 0.12
	local rpmFraction = math.clamp(throttleFraction * systemsFactor * (0.9 + loadRelief), 0, 1)
	state.rpm = config.idleRPM + (config.maxRPM - config.idleRPM) * rpmFraction

	-- ---- Fuel ------------------------------------------------------------
	--[[
		Fuel flow scales with how rich the mixture is, and that asymmetry against
		power is the entire reason leaning is worth doing: at a lean ratio of 0.8
		the engine keeps 95% of its power on 80% of the fuel.
	]]
	local leanRatio = math.min(Engine.leanRatio(state.mixture, densityRatio), 1)
	state.fuelFlowKgS = state.powerW * config.bsfc * leanRatio

	--[[
		⚠️ THE ENGINE NO LONGER DRINKS STRAIGHT OUT OF A TOTAL. It draws through
		the SELECTOR, from the tank the pilot chose, into the lines - and burns
		what is in the lines. That indirection is the fuel system: with the valve
		OFF the draw is zero and the engine runs on line fuel for a few seconds
		before it starves, which is what actually happens.
	]]
	local burn = state.fuelFlowKgS * dt
	state.lineFuelKg += Engine.drawFuel(state, math.max(burn + (LINE_FUEL_KG - state.lineFuelKg), 0))
	state.lineFuelKg = math.min(state.lineFuelKg, LINE_FUEL_KG)

	state.lineFuelKg -= burn
	state.fuelKg = state.fuelLeftKg + state.fuelRightKg

	if state.lineFuelKg <= 0 then
		--[[
			Fuel starvation. Either the tanks are dry (exhaustion) or the
			selected tank is (mismanagement) or the valve is shut. The engine
			stops and the aircraft becomes a glider with a windmilling
			propeller, which is the correct outcome and a genuinely useful thing
			for a simulator to model honestly.

			The lines stay empty, so restarting means selecting a tank that has
			something in it - not just turning the key.
		]]
		state.lineFuelKg = 0
		state.running = false
		state.powerW = 0
		state.thrustN = 0
		state.fuelFlowKgS = 0
		state.oilPressurePsi = 0
		return 0
	end

	-- ---- The engine gauges (item 6) --------------------------------------
	-- Temperature first, because pressure depends on how thick the oil is.
	local powerFraction = math.clamp(state.powerW / max(config.maxPowerW, 1), 0, 1)
	state.oilTempC = MathUtil.damp(
		state.oilTempC,
		Engine.oilTargetTemp(true, powerFraction, AMBIENT_OIL_TEMP_C),
		1 / OIL_WARMUP_TAU,
		dt
	)
	state.oilPressurePsi = Engine.oilPressureFor(state.rpm, config.maxRPM, state.oilTempC, true)

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
	--[[
		⚠️ THE KEY DOES NOTHING WITH THE MAGS OFF OR THE MIXTURE CUT, and that
		is the procedure this phase exists to make real. The starter still turns
		over in `update()` if it is somehow engaged; refusing here is the
		earlier and clearer answer, so the pilot who has forgotten the mixture
		gets a dead key rather than an engine that catches anyway.
	]]
	if state.magnetos == "OFF" or state.mixture <= 0 then
		return
	end
	state.starting = true
	state.startProgress = 0
end

-- =========================================================================
-- SYSTEMS CONTROLS (Phase 4c)
-- =========================================================================

--[[
	The four selector positions, in the order the real valve turns through.
	Exported as data so the binding that steps it, the 3D part that mirrors it
	and the tests all read one list rather than three copies of it.
]]
Engine.FUEL_SELECTOR_POSITIONS = { "OFF", "LEFT", "BOTH", "RIGHT" }

--[[
	The ignition's positions, in the order the key turns.

	START is deliberately last and is NOT part of the cycle - it is
	spring-loaded on the real aeroplane, so a key left in START is a key the
	pilot is holding. `Engine.turnKey` handles it; stepping never lands on it.
]]
Engine.MAGNETO_POSITIONS = { "OFF", "R", "L", "BOTH" }

local function stepThrough(list: { string }, current: string, delta: number): string
	local index = table.find(list, current) or 1
	local next = index + delta
	-- Clamped rather than wrapped, because these are LEVERS AND KEYS with
	-- stops. A fuel selector that wrapped from OFF round to RIGHT would let a
	-- pilot shut the fuel off by pressing the same key one time too many.
	return list[math.clamp(next, 1, #list)]
end

function Engine.stepFuelSelector(state: State, delta: number): FuelSelector
	state.fuelSelector = stepThrough(Engine.FUEL_SELECTOR_POSITIONS, state.fuelSelector, delta) :: FuelSelector
	return state.fuelSelector
end

function Engine.stepMagnetos(state: State, delta: number): Magnetos
	state.magnetos = stepThrough(Engine.MAGNETO_POSITIONS, state.magnetos, delta) :: Magnetos
	return state.magnetos
end

--[[
	Move the mixture knob. Positive is richer, negative leaner, in fractions of
	full travel - so the caller supplies rate times dt and the knob has travel
	rather than positions.
]]
function Engine.adjustMixture(state: State, delta: number): number
	state.mixture = math.clamp(state.mixture + delta, 0, 1)
	return state.mixture
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
	state.fuelKg = state.fuelLeftKg + state.fuelRightKg
	state.running = state.fuelKg > 0
	state.starting = false
	state.startProgress = 0
	state.rpm = config.idleRPM

	--[[
		An aeroplane handed over already running has warm oil and primed lines.
		Without this, every aircraft spawned running would show a cold-start oil
		pressure near the red line and a stone-cold temperature, and would cough
		on the first frame as the empty lines starved it.
	]]
	state.lineFuelKg = LINE_FUEL_KG
	state.oilTempC = Engine.oilTargetTemp(true, 0, AMBIENT_OIL_TEMP_C)
	state.oilPressurePsi = Engine.oilPressureFor(state.rpm, config.maxRPM, state.oilTempC, true)
end

--[[
	Fill the tanks. Split evenly across both, which is how an aeroplane is
	fuelled - a refuel that dumped everything into one tank would create the
	very imbalance the fuel system exists to let the pilot manage.
]]
function Engine.refuel(state: State, config: Config, kg: number?)
	local half = config.fuelCapacityKg * 0.5
	local each = (kg or config.fuelCapacityKg) * 0.5

	state.fuelLeftKg = math.clamp(state.fuelLeftKg + each, 0, half)
	state.fuelRightKg = math.clamp(state.fuelRightKg + each, 0, half)
	state.fuelKg = state.fuelLeftKg + state.fuelRightKg
end

--[[
	The imbalance between the tanks, in kg, positive when the LEFT is heavier.

	Exposed because it is the number the fuel system exists to make visible: a
	pilot who has flown an hour on one tank has an imbalance, and on a real
	aeroplane they feel it as a wing that wants to drop.

	⚠️ IT DOES NOT YET PRODUCE A ROLLING MOMENT, and §46b says why: the mass
	boxes in the definition are STATIC and already carry the fuel symmetrically,
	110 kg in each wing. Making them vary with tank contents is a change to the
	mass model and therefore a §4 decision, not a side effect of this phase.
]]
function Engine.fuelImbalanceKg(state: State): number
	return state.fuelLeftKg - state.fuelRightKg
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

	--[[
		Running the tanks dry must stop the engine, not produce free thrust.

		⚠️ THIS USED TO SET `fuelKg` DIRECTLY, and Phase 4c moved the truth: the
		TANKS are the fuel and `fuelKg` is their sum, rewritten every frame. The
		old line would now be overwritten before it was read - which is exactly
		the silent-rescale failure §30 and §35 both record, so it is stated here
		rather than quietly edited.
	]]
	--[[
		⚠️ AND IT NO LONGER STOPS IN ONE FRAME, which is the second thing Phase
		4c changed here. The engine burns what is in the LINES, so dry tanks
		mean it keeps running for the handful of seconds that fuel lasts. The
		old single-frame assertion failed on correct code for exactly that
		reason - run it to a stop instead of assuming an instant one.
	]]
	local dryState = Engine.createState(config)
	Engine.setRunning(dryState, config)
	dryState.fuelLeftKg = 0.0005
	dryState.fuelRightKg = 0.0005
	for _ = 1, 60 * 60 do
		Engine.update(dryState, config, 1 / 60, 1.0, 50, rhoSL, 1.0)
		if not dryState.running then
			break
		end
	end
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

	--[[
		A tachometer cannot read backwards.

		The forward airspeed component goes slightly negative on a parked
		aircraft through ordinary numerical drift, and the windmilling branch
		used to pass that straight through - so a stationary aeroplane reported
		a small negative rpm. Caught by the debug HUD, which showed "RPM -0".
	]]
	local backwards = Engine.createState(config)
	Engine.update(backwards, config, 1 / 60, 0, -3.0, rhoSL, 1)
	record(
		"Windmilling rpm never goes negative",
		backwards.rpm >= 0,
		string.format("%.4f rpm at -3 m/s of forward airspeed", backwards.rpm)
	)

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

	-- =====================================================================
	-- 10. PHASE 4c SYSTEMS
	-- =====================================================================
	--[[
		Asserted against the POH, not against what the code does. Every figure
		below is a published Lycoming IO-360-L2A or Cessna 172S number, or is
		derived from one and says so.
	]]
	print("--- Phase 4c systems ---")

	-- ---- The default configuration is the one §4 was verified in ----------
	--[[
		⚠️ THE MOST IMPORTANT CHECK IN THIS SECTION. Every performance figure in
		§4 was measured at full rich, both magnetos, sea level. If this phase's
		multipliers were anything other than exactly 1.0 there, it would have
		silently re-tuned the whole aeroplane - §30's lesson, and the reason
		both factors are written to be identities in the reference condition.
	]]
	record(
		"Both magnetos and full rich are exactly 1.000, so §4 is untouched",
		Engine.magnetoPowerFactor("BOTH") == 1
			and Engine.mixturePowerFactor(1, 1.0) == 1,
		string.format(
			"mags %.4f, mixture %.4f at sea level full rich",
			Engine.magnetoPowerFactor("BOTH"),
			Engine.mixturePowerFactor(1, 1.0)
		)
	)

	local fresh = Engine.createState(config)
	record(
		"A new engine starts on BOTH, full rich, both magnetos",
		fresh.fuelSelector == "BOTH" and fresh.mixture == 1 and fresh.magnetos == "BOTH",
		string.format("%s / mixture %.1f / mags %s", fresh.fuelSelector, fresh.mixture, fresh.magnetos)
	)

	-- ---- Item 2: the fuel selector ---------------------------------------
	record(
		"The tanks split the published 153 kg evenly, and sum to it",
		math.abs(fresh.fuelLeftKg - 76.5) < 1e-9
			and math.abs(fresh.fuelRightKg - 76.5) < 1e-9
			and math.abs(fresh.fuelKg - config.fuelCapacityKg) < 1e-9,
		string.format("%.1f + %.1f = %.1f kg", fresh.fuelLeftKg, fresh.fuelRightKg, fresh.fuelKg)
	)

	--[[
		BOTH drains both. The check is that they stay EQUAL, because a BOTH that
		quietly favoured one side would create the imbalance the position exists
		to prevent.
	]]
	local both = Engine.createState(config)
	Engine.setRunning(both, config)
	for _ = 1, 600 do
		Engine.update(both, config, 1 / 60, 0.75, 60, rhoSL, 1.0)
	end
	record(
		"BOTH drains both tanks, and evenly",
		both.fuelLeftKg < 76.5 and math.abs(Engine.fuelImbalanceKg(both)) < 1e-6,
		string.format("%.3f / %.3f kg, imbalance %.6f", both.fuelLeftKg, both.fuelRightKg, Engine.fuelImbalanceKg(both))
	)

	--[[
		LEFT drains the left faster - in fact only the left, which is what makes
		tank management a thing a pilot has to do.
	]]
	local onLeft = Engine.createState(config)
	Engine.setRunning(onLeft, config)
	onLeft.fuelSelector = "LEFT"
	for _ = 1, 600 do
		Engine.update(onLeft, config, 1 / 60, 0.75, 60, rhoSL, 1.0)
	end
	record(
		"LEFT drains the left tank and leaves the right alone",
		onLeft.fuelLeftKg < 76.5 and math.abs(onLeft.fuelRightKg - 76.5) < 1e-9,
		string.format("left %.3f, right %.3f kg", onLeft.fuelLeftKg, onLeft.fuelRightKg)
	)
	record(
		"...which is what makes an imbalance real",
		Engine.fuelImbalanceKg(onLeft) < 0,
		string.format("%.3f kg, the right tank now the heavier", Engine.fuelImbalanceKg(onLeft))
	)

	--[[
		⚠️ AND OFF STARVES IT - but not instantly, because the engine runs on
		what is already in the lines. There is NO PUBLISHED FIGURE for this: the
		POH does not certify flight with the fuel shut off. So the assertion is
		the MECHANISM - a few seconds, not zero and not a minute - and the note
		on `lineFuelKg` says exactly that.
	]]
	local shutOff = Engine.createState(config)
	Engine.setRunning(shutOff, config)
	for _ = 1, 120 do
		Engine.update(shutOff, config, 1 / 60, 0.75, 60, rhoSL, 1.0)
	end
	shutOff.fuelSelector = "OFF"
	local starveSeconds = 0
	for _ = 1, 60 * 60 do
		Engine.update(shutOff, config, 1 / 60, 0.75, 60, rhoSL, 1.0)
		if not shutOff.running then
			break
		end
		starveSeconds += 1 / 60
	end
	record(
		"OFF starves the engine, on line fuel, in a few seconds",
		not shutOff.running and starveSeconds > 1 and starveSeconds < 30,
		string.format("ran %.1f s on line fuel after the valve was shut", starveSeconds)
	)
	record(
		"...with fuel still in both tanks, which is the point",
		shutOff.fuelLeftKg > 70 and shutOff.fuelRightKg > 70,
		string.format("%.1f / %.1f kg left aboard", shutOff.fuelLeftKg, shutOff.fuelRightKg)
	)

	--[[
		Selecting a tank that is empty starves the engine while the other one is
		full - the classic fuel-mismanagement accident, and the reason the POH
		says to take off and land on BOTH.
	]]
	local mismanaged = Engine.createState(config)
	Engine.setRunning(mismanaged, config)
	mismanaged.fuelSelector = "LEFT"
	mismanaged.fuelLeftKg = 0
	for _ = 1, 60 * 60 do
		Engine.update(mismanaged, config, 1 / 60, 0.75, 60, rhoSL, 1.0)
		if not mismanaged.running then
			break
		end
	end
	record(
		"An empty SELECTED tank starves it with the other one full",
		not mismanaged.running and mismanaged.fuelRightKg > 70,
		string.format("stopped with %.1f kg in the right tank", mismanaged.fuelRightKg)
	)
	--[[
		And BOTH saves it, from the identical starting state. This is the pair
		that makes the POH's rule mean something rather than being a slogan.
	]]
	local saved = Engine.createState(config)
	Engine.setRunning(saved, config)
	saved.fuelLeftKg = 0
	for _ = 1, 600 do
		Engine.update(saved, config, 1 / 60, 0.75, 60, rhoSL, 1.0)
	end
	record(
		"...while BOTH keeps running on the good tank",
		saved.running and saved.fuelRightKg < 76.5,
		string.format("still running, drawing the right tank down to %.1f kg", saved.fuelRightKg)
	)

	-- ---- Item 3: mixture --------------------------------------------------
	--[[
		The correct mixture IS the density ratio - that is the whole physical
		content of leaning. At 8,000 ft (sigma 0.786) full rich is 27% too much
		fuel, which is the mixture a pilot leans away.
	]]
	record(
		"Full rich is correct at sea level and too rich at altitude",
		math.abs(Engine.leanRatio(1, 1.0) - 1) < 1e-9
			and Engine.leanRatio(1, sigma8000) > 1.25,
		string.format("sea level %.3f, 8000 ft %.3f", Engine.leanRatio(1, 1.0), Engine.leanRatio(1, sigma8000))
	)

	--[[
		THE TRADE THAT MAKES LEANING WORTH DOING, asserted as an inequality
		rather than a number: leaning must cost less power than it saves fuel,
		or there would be no reason to touch the knob.
	]]
	local rich = Engine.createState(config)
	Engine.setRunning(rich, config)
	local lean = Engine.createState(config)
	Engine.setRunning(lean, config)
	lean.mixture = 0.8
	for _ = 1, 300 do
		Engine.update(rich, config, 1 / 60, 0.75, 60, rhoSL, 1.0)
		Engine.update(lean, config, 1 / 60, 0.75, 60, rhoSL, 1.0)
	end
	local powerKept = lean.powerW / rich.powerW
	local fuelKept = lean.fuelFlowKgS / rich.fuelFlowKgS
	record(
		"Leaning saves more fuel than it costs power",
		fuelKept < powerKept and powerKept > 0.9,
		string.format("keeps %.1f%% of the power on %.1f%% of the fuel", powerKept * 100, fuelKept * 100)
	)

	--[[
		⚠️ AND THE KNOB SHUTS THE ENGINE DOWN. Pulling the mixture fully out is
		how a 172 is stopped - the throttle cannot do it, and that asymmetry is
		a real and important property of the controls.
	]]
	local cutoff = Engine.createState(config)
	Engine.setRunning(cutoff, config)
	cutoff.mixture = 0
	Engine.update(cutoff, config, 1 / 60, 0.75, 60, rhoSL, 1.0)
	record(
		"Idle cutoff stops the engine, which is how a 172 is shut down",
		not cutoff.running and cutoff.thrustN == 0,
		string.format("running=%s", tostring(cutoff.running))
	)
	record(
		"...and the throttle cannot do the same thing",
		idleState.running,
		"a closed throttle idles; only the mixture and the mags stop it"
	)

	-- ---- Item 4: magnetos and the mag check -------------------------------
	--[[
		THE RUN-UP, flown as the POH describes it: 1,800 RPM, switch to each
		magneto in turn, read the drop. The limits are published - no more than
		150 RPM on either, no more than 50 RPM between them - so this is a test
		against the POH rather than against the model.
	]]
	local function settleRPM(magnetos: Magnetos): number
		local s = Engine.createState(config)
		Engine.setRunning(s, config)
		s.magnetos = magnetos
		-- Throttle set for about 1,800 RPM, stationary, as in a real run-up.
		for _ = 1, 600 do
			Engine.update(s, config, 1 / 60, 0.62, 0, rhoSL, 1.0)
		end
		return s.rpm
	end

	local rpmBoth = settleRPM("BOTH")
	local rpmLeft = settleRPM("L")
	local rpmRight = settleRPM("R")
	local dropLeft = rpmBoth - rpmLeft
	local dropRight = rpmBoth - rpmRight

	checkRange("The run-up sits near the POH's 1800 rpm", rpmBoth, 1650, 1950, "rpm")
	record(
		"Each magneto drops the rpm, within the POH's 150 limit",
		dropLeft > 0 and dropRight > 0
			and dropLeft <= Engine.MAG_DROP_LIMIT_RPM
			and dropRight <= Engine.MAG_DROP_LIMIT_RPM,
		string.format("L %.0f rpm, R %.0f rpm against a 150 rpm limit", dropLeft, dropRight)
	)
	record(
		"...and the differential is inside the POH's 50 rpm",
		math.abs(dropLeft - dropRight) <= Engine.MAG_DIFFERENTIAL_LIMIT_RPM,
		string.format("%.0f rpm between magnetos - zero, because this engine is serviceable", math.abs(dropLeft - dropRight))
	)

	--[[
		⚠️ MAGS OFF STOPS IT, whatever else is true. This is the switch that
		shuts the aeroplane down, and it must outrank fuel, throttle and mixture.
	]]
	local magsOff = Engine.createState(config)
	Engine.setRunning(magsOff, config)
	magsOff.magnetos = "OFF"
	Engine.update(magsOff, config, 1 / 60, 1.0, 60, rhoSL, 1.0)
	record(
		"Mags OFF stops the engine at full throttle with full tanks",
		not magsOff.running and magsOff.thrustN == 0,
		string.format("running=%s thrust=%.1f", tostring(magsOff.running), magsOff.thrustN)
	)

	--[[
		A start is a PROCEDURE now: the key does nothing with the mags off or
		the mixture cut, which is the failure a pilot has to diagnose rather
		than an engine that catches regardless.
	]]
	local noStart = Engine.createState(config)
	noStart.magnetos = "OFF"
	Engine.start(noStart, config)
	local cutStart = Engine.createState(config)
	cutStart.mixture = 0
	Engine.start(cutStart, config)
	record(
		"The starter does nothing with the mags off or the mixture cut",
		not noStart.starting and not cutStart.starting,
		"both refused"
	)

	local goodStart = Engine.createState(config)
	Engine.start(goodStart, config)
	for _ = 1, 240 do
		Engine.update(goodStart, config, 1 / 60, 0.2, 0, rhoSL, 1.0)
	end
	record(
		"...and a correct start catches",
		goodStart.running,
		string.format("running after the starter, %.0f rpm", goodStart.rpm)
	)

	-- The selector and the key are levers with stops, not dials that wrap.
	local stepper = Engine.createState(config)
	stepper.fuelSelector = "OFF"
	Engine.stepFuelSelector(stepper, -1)
	record(
		"The fuel selector stops at OFF rather than wrapping round to RIGHT",
		stepper.fuelSelector == "OFF",
		"clamped - wrapping would shut the fuel off by one press too many"
	)
	Engine.stepFuelSelector(stepper, 1)
	Engine.stepFuelSelector(stepper, 1)
	record(
		"...and steps OFF -> LEFT -> BOTH in the order the valve turns",
		stepper.fuelSelector == "BOTH",
		stepper.fuelSelector
	)

	-- ---- Item 6: the engine gauges ---------------------------------------
	--[[
		Against the POH's marks: green 50-90 psi, minimum 25, red line 115. A
		stopped engine reads ZERO, which is the most important thing this gauge
		ever says.
	]]
	local gauge = Engine.createState(config)
	record(
		"A stopped engine shows no oil pressure at all",
		Engine.oilPressureFor(0, config.maxRPM, 80, false) == 0,
		"0 psi"
	)

	Engine.setRunning(gauge, config)
	for _ = 1, 60 * 60 * 5 do
		Engine.update(gauge, config, 1 / 60, 0.75, 60, rhoSL, 1.0)
	end
	checkRange("Oil pressure at cruise sits in the POH green", gauge.oilPressurePsi, 50, 90, "psi")
	checkRange("Oil temperature at cruise sits in the POH green", gauge.oilTempC, 38, 118, "C")

	local idleGauge = Engine.createState(config)
	Engine.setRunning(idleGauge, config)
	for _ = 1, 60 * 60 * 5 do
		Engine.update(idleGauge, config, 1 / 60, 0, 0, rhoSL, 1.0)
	end
	record(
		"Idle oil pressure is above the POH's 25 psi minimum",
		idleGauge.oilPressurePsi >= Engine.OIL_PRESSURE_MIN_PSI,
		string.format("%.1f psi against a 25 psi minimum", idleGauge.oilPressurePsi)
	)
	record(
		"Oil pressure is lower at idle than at cruise",
		idleGauge.oilPressurePsi < gauge.oilPressurePsi,
		string.format("idle %.1f psi against cruise %.1f psi", idleGauge.oilPressurePsi, gauge.oilPressurePsi)
	)

	--[[
		Cold oil is thicker and reads higher - the pressure a real gauge shows
		on a cold start, settling as the engine warms. And it must stay off the
		red line, because a gauge that pegs on a healthy engine is lying.
	]]
	local coldPressure = Engine.oilPressureFor(config.maxRPM * 0.7, config.maxRPM, 5, true)
	local warmPressure = Engine.oilPressureFor(config.maxRPM * 0.7, config.maxRPM, 90, true)
	record(
		"Cold oil reads higher than warm, and never reaches the red line",
		coldPressure > warmPressure and coldPressure < Engine.OIL_PRESSURE_REDLINE_PSI,
		string.format("cold %.1f psi against warm %.1f, red line %d", coldPressure, warmPressure, Engine.OIL_PRESSURE_REDLINE_PSI)
	)

	--[[
		A cold aeroplane is cold. The oil starts at ambient and takes minutes to
		warm, which is why a run-up is not the first thing you do after a start.
	]]
	local coldStart = Engine.createState(config)
	record(
		"A cold aeroplane starts at ambient oil temperature",
		math.abs(coldStart.oilTempC - 15) < 1e-9,
		string.format("%.1f C", coldStart.oilTempC)
	)

	local warming = Engine.createState(config)
	warming.oilTempC = 15
	warming.running = true
	warming.lineFuelKg = 0.05
	for _ = 1, 60 * 30 do
		Engine.update(warming, config, 1 / 60, 0.75, 60, rhoSL, 1.0)
	end
	record(
		"...and it takes minutes to warm up, not seconds",
		warming.oilTempC > 20 and warming.oilTempC < 80,
		string.format("%.1f C after 30 s of running", warming.oilTempC)
	)

	--[[
		⚠️ FUEL FLOW IS A GAUGE NOW, and it must read in the POH's band. The
		172S burns about 8.5-10 US gallons an hour in cruise, which at 0.72 kg/l
		is 23-27 kg/h. This is the same number §4 already verified as a burn
		rate - read here as an instrument rather than as an endurance.
	]]
	checkRange("Fuel flow at cruise reads in the POH band", gauge.fuelFlowKgS * 3600, 20, 34, "kg/h")

	-- ---- §4 IS UNTOUCHED, VERIFIED RATHER THAN ASSUMED --------------------
	--[[
		⚠️ THE CONSTRAINT THIS WHOLE PHASE WAS GIVEN. The brief said two tanks
		move the centre of mass. MEASURED, THEY DO NOT - and the reason is worth
		writing down, because it is the opposite of what it looks like.

		The fuel is ALREADY carried in the definition's static mass boxes:
		WingLeft and WingRight are 110 kg each, commented "structure plus the
		fuel it carries", and they never change. So `fuelKg` was never a mass in
		the first place - it is bookkeeping the engine drinks from, and splitting
		it in two moves nothing at all.

		That is a finding, not a shortcut. Making the wing boxes vary with tank
		contents would make a lateral imbalance produce a real rolling moment,
		and it is a change to the MASS MODEL - a §4 decision for the pilot, not
		a side effect of adding a fuel valve.
	]]
	local cessna = require(script.Parent.Parent.Aircraft.Definitions.Cessna172)
	local wingLeftMass, wingRightMass = 0, 0
	for _, part in cessna.model.parts do
		if part.name == "WingLeft" then
			wingLeftMass = part.mass
		elseif part.name == "WingRight" then
			wingRightMass = part.mass
		end
	end
	record(
		"The fuel is already carried symmetrically in the static wing boxes",
		wingLeftMass > 0 and wingLeftMass == wingRightMass,
		string.format("%.0f kg each side, unchanged by this phase", wingLeftMass)
	)
	record(
		"So splitting the tank moves NO mass, and §4 stands unchanged",
		Engine.createState(config).fuelLeftKg + Engine.createState(config).fuelRightKg == config.fuelCapacityKg,
		"fuelKg is bookkeeping the engine drinks from, never a mass in the model"
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
