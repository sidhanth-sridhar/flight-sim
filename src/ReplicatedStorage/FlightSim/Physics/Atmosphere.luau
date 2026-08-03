--!strict
--[[
	Atmosphere
	----------
	Implementation of the International Standard Atmosphere (ISA), the model
	every real aircraft's performance charts are built against.

	WHY THIS MATTERS FOR THE GAME
	-----------------------------
	Air density is the single input that makes altitude *mean* something.
	Every aerodynamic force is proportional to it, so as the aircraft climbs:

	  - lift falls, so the aircraft must fly at a higher true airspeed or a
	    higher angle of attack to stay level;
	  - the engine makes less power, because it is breathing thinner air;
	  - true airspeed exceeds indicated airspeed by an increasing margin,
	    which is why the airspeed indicator alone cannot tell a pilot how fast
	    they are actually moving;
	  - the aircraft eventually reaches a service ceiling naturally - we never
	    need to code an artificial altitude cap, it emerges from the physics.

	On a hot day, density drops, and takeoff runs get noticeably longer. That
	emergent realism is worth the ~100 lines below.

	UNITS
	-----
	This module is pure SI: metres, kelvin, pascals, kg/m^3, m/s. It has no
	knowledge of studs. Convert at the call site with Shared/Units.

	VALIDITY
	--------
	Modelled from sea level to 20 km, which covers the troposphere and the
	lower stratosphere - far above anything we plan to fly. Inputs outside
	that range are clamped rather than extrapolated.
]]

local Atmosphere = {}

local exp = math.exp
local sqrt = math.sqrt
local clamp = math.clamp

-- =========================================================================
-- ISA CONSTANTS (internationally defined - do not "tidy" these numbers)
-- =========================================================================

local T0 = 288.15 -- sea level temperature, K (15 C)
local P0 = 101325 -- sea level pressure, Pa
local RHO0 = 1.225 -- sea level density, kg/m^3
local LAPSE = 0.0065 -- troposphere temperature lapse rate, K/m
local G0 = 9.80665 -- standard gravity, m/s^2
local R_SPECIFIC = 287.05287 -- specific gas constant for dry air, J/(kg*K)
local GAMMA = 1.4 -- ratio of specific heats for air

local TROPOPAUSE_ALT = 11000 -- m, where the lapse rate stops
local TROPOPAUSE_TEMP = 216.65 -- K, constant above this altitude
local TROPOPAUSE_PRESSURE = 22632.06 -- Pa, ISA value at 11 km
local MAX_ALT = 20000 -- m, top of the modelled range

--[[
	The barometric exponent, g0 / (L * R).

	This falls out of integrating the hydrostatic equation dp = -rho*g*dh
	together with the ideal gas law p = rho*R*T, through a layer where
	temperature varies linearly with height. The result is the classic
	power law:

		p/p0 = (T/T0) ^ (g0 / (L*R))

	and because rho = p/(R*T), the density ratio is the same power law with
	the exponent reduced by exactly 1:

		rho/rho0 = (T/T0) ^ (g0/(L*R) - 1)
]]
local PRESSURE_EXPONENT = G0 / (LAPSE * R_SPECIFIC) -- ~5.255877
local DENSITY_EXPONENT = PRESSURE_EXPONENT - 1 -- ~4.255877

-- Exposed for other systems (weather, instruments) that need reference values.
Atmosphere.SEA_LEVEL_DENSITY = RHO0
Atmosphere.SEA_LEVEL_PRESSURE = P0
Atmosphere.SEA_LEVEL_TEMPERATURE = T0
Atmosphere.MAX_ALTITUDE = MAX_ALT

-- =========================================================================
-- CORE PROPERTIES
-- =========================================================================

--[[
	Temperature in kelvin at a given altitude.

	tempOffsetC shifts the whole profile - this is how weather makes a hot
	summer day (+15) or a freezing morning (-10) affect aircraft performance.
	Real-world charts call this "ISA deviation".
]]
function Atmosphere.getTemperature(altitudeM: number, tempOffsetC: number?): number
	local h = clamp(altitudeM, 0, MAX_ALT)
	local base: number

	if h < TROPOPAUSE_ALT then
		-- Troposphere: temperature falls linearly, ~2 C per 1000 ft.
		base = T0 - LAPSE * h
	else
		-- Lower stratosphere: isothermal.
		base = TROPOPAUSE_TEMP
	end

	return base + (tempOffsetC or 0)
end

-- Static air pressure in pascals. Not affected by temperature offset: a warm
-- day changes density through temperature, not through pressure.
function Atmosphere.getPressure(altitudeM: number): number
	local h = clamp(altitudeM, 0, MAX_ALT)

	if h < TROPOPAUSE_ALT then
		local thetaRatio = 1 - (LAPSE * h) / T0
		return P0 * thetaRatio ^ PRESSURE_EXPONENT
	else
		-- Isothermal layer: the power law degenerates into an exponential.
		local dh = h - TROPOPAUSE_ALT
		return TROPOPAUSE_PRESSURE * exp(-(G0 * dh) / (R_SPECIFIC * TROPOPAUSE_TEMP))
	end
end

--[[
	Air density in kg/m^3. THE most important function in this module - it is
	read once per physics frame and feeds every aerodynamic force.

	With no temperature offset the fast power law is used directly. With an
	offset we fall back to the ideal gas law, because a shifted temperature
	profile no longer satisfies the power law's assumptions.
]]
function Atmosphere.getDensity(altitudeM: number, tempOffsetC: number?): number
	local offset = tempOffsetC or 0
	local h = clamp(altitudeM, 0, MAX_ALT)

	if offset == 0 then
		if h < TROPOPAUSE_ALT then
			local thetaRatio = 1 - (LAPSE * h) / T0
			return RHO0 * thetaRatio ^ DENSITY_EXPONENT
		else
			return Atmosphere.getPressure(h) / (R_SPECIFIC * TROPOPAUSE_TEMP)
		end
	end

	-- rho = p / (R * T), with the actual (offset) temperature.
	return Atmosphere.getPressure(h) / (R_SPECIFIC * Atmosphere.getTemperature(h, offset))
end

-- Density relative to sea level, conventionally written sigma. Engine power
-- and the true/indicated airspeed relationship both scale with this.
function Atmosphere.getDensityRatio(altitudeM: number, tempOffsetC: number?): number
	return Atmosphere.getDensity(altitudeM, tempOffsetC) / RHO0
end

-- Speed of sound, m/s. a = sqrt(gamma * R * T) - depends only on temperature.
function Atmosphere.getSpeedOfSound(altitudeM: number, tempOffsetC: number?): number
	return sqrt(GAMMA * R_SPECIFIC * Atmosphere.getTemperature(altitudeM, tempOffsetC))
end

-- Mach number. Irrelevant for the Cessna, but the jet in Phase 5 will need
-- it, and it costs nothing to define correctly now.
function Atmosphere.getMachNumber(trueAirspeedMs: number, altitudeM: number, tempOffsetC: number?): number
	return trueAirspeedMs / Atmosphere.getSpeedOfSound(altitudeM, tempOffsetC)
end

-- =========================================================================
-- AIRSPEED
-- =========================================================================

--[[
	Dynamic pressure, q = 0.5 * rho * V^2, in pascals.

	This is the term that converts "how fast am I going through how thick an
	air mass" into a force per unit area. Lift and drag are just q * area *
	a dimensionless coefficient, so this single quantity governs how much
	authority the aircraft has - which is exactly why controls go soggy at
	low speed and why the aircraft stalls.
]]
function Atmosphere.getDynamicPressure(trueAirspeedMs: number, altitudeM: number, tempOffsetC: number?): number
	local rho = Atmosphere.getDensity(altitudeM, tempOffsetC)
	return 0.5 * rho * trueAirspeedMs * trueAirspeedMs
end

--[[
	True airspeed -> equivalent airspeed.

	An airspeed indicator is a pressure gauge: it measures q and is calibrated
	assuming sea-level density. At altitude the air is thinner, so the same
	true speed produces less q and the needle under-reads:

		EAS = TAS * sqrt(rho / rho0)

	Pilots use the rough rule "TAS is about 2% higher than IAS per 1000 ft",
	and this function reproduces that naturally.

	Strictly this returns EQUIVALENT airspeed. Real indicated airspeed also
	includes instrument and position error, and compressibility above roughly
	200 knots. At Cessna speeds the difference is negligible, so the
	instruments treat this as IAS. When the Phase 5 jet arrives, the
	compressibility correction belongs here.
]]
function Atmosphere.trueToEquivalent(trueAirspeedMs: number, altitudeM: number, tempOffsetC: number?): number
	return trueAirspeedMs * sqrt(Atmosphere.getDensityRatio(altitudeM, tempOffsetC))
end

-- The inverse: what true airspeed does a target indicated airspeed represent?
-- Used by the autopilot and by AI traffic flying published speeds.
function Atmosphere.equivalentToTrue(equivalentAirspeedMs: number, altitudeM: number, tempOffsetC: number?): number
	local sigma = Atmosphere.getDensityRatio(altitudeM, tempOffsetC)
	if sigma <= 0 then
		return equivalentAirspeedMs
	end
	return equivalentAirspeedMs / sqrt(sigma)
end

-- =========================================================================
-- DERIVED ALTITUDES
-- =========================================================================

--[[
	Pressure altitude: what an altimeter reads when set to standard pressure
	(1013.25 hPa / 29.92 inHg) rather than the local setting.

	This is why altimeters need setting before every flight - fly into a low
	pressure system without resetting and the altimeter reads HIGH, meaning
	the aircraft is lower than it appears. Feeding real QNH into this gives
	the weather system a genuine, and genuinely dangerous, effect.

	The ~27 ft per hPa figure comes from the density of air near sea level.
]]
function Atmosphere.getPressureAltitude(trueAltitudeM: number, qnhPa: number?): number
	local qnh = qnhPa or P0
	local FEET_PER_PASCAL = 27.3 / 100 -- ~27.3 ft per hPa, converted to per Pa
	local errorFeet = (P0 - qnh) * FEET_PER_PASCAL
	return trueAltitudeM + errorFeet * 0.3048
end

--[[
	Density altitude: the standard-atmosphere altitude at which the current
	density would be normal. This is the number that actually determines
	aircraft performance.

	A hot day at a 5,000 ft mountain airfield can produce a density altitude
	of 8,000 ft or more - the aircraft performs as though it were far higher
	than it is, takeoff runs stretch, and climb rate collapses. It is a
	classic cause of real accidents and it will make mountain strips in this
	game genuinely demanding.

	Derived by inverting the troposphere density power law.
]]
function Atmosphere.getDensityAltitude(trueAltitudeM: number, tempOffsetC: number?): number
	local rho = Atmosphere.getDensity(trueAltitudeM, tempOffsetC)
	local sigma = rho / RHO0
	if sigma <= 0 then
		return MAX_ALT
	end
	return (T0 / LAPSE) * (1 - sigma ^ (1 / DENSITY_EXPONENT))
end

-- =========================================================================
-- VERIFICATION
-- =========================================================================

--[[
	Checks the model against published ISA table values.

	Run from the Studio command bar:
		require(game.ReplicatedStorage.FlightSim.Physics.Atmosphere).runTests()

	Returns (allPassed, resultsTable). Keeping this in the shipping module,
	rather than in a separate test place, means it can be re-run after any
	future edit in seconds.
]]
function Atmosphere.runTests(): (boolean, { any })
	local results = {}
	local allPassed = true

	-- tolerance is fractional (0.001 = 0.1%)
	local function check(label: string, actual: number, expected: number, tolerance: number, unit: string)
		local errorFraction = if expected ~= 0 then math.abs(actual - expected) / math.abs(expected) else math.abs(actual)
		local passed = errorFraction <= tolerance
		if not passed then
			allPassed = false
		end
		table.insert(results, {
			label = label,
			actual = actual,
			expected = expected,
			unit = unit,
			passed = passed,
			errorPercent = errorFraction * 100,
		})
		print(string.format(
			"  [%s] %-34s %12.4f %-8s (expected %.4f, err %.4f%%)",
			passed and "PASS" or "FAIL",
			label,
			actual,
			unit,
			expected,
			errorFraction * 100
		))
	end

	print("=== Atmosphere: ISA verification ===")

	-- Sea level: the defining reference point of the entire model.
	check("Sea level temperature", Atmosphere.getTemperature(0), 288.15, 0.0001, "K")
	check("Sea level pressure", Atmosphere.getPressure(0), 101325, 0.0001, "Pa")
	check("Sea level density", Atmosphere.getDensity(0), 1.225, 0.001, "kg/m3")
	check("Sea level speed of sound", Atmosphere.getSpeedOfSound(0), 340.29, 0.001, "m/s")

	-- 5,000 ft (1524 m) - typical general aviation cruising altitude.
	check("5000 ft temperature", Atmosphere.getTemperature(1524), 278.24, 0.001, "K")
	check("5000 ft density", Atmosphere.getDensity(1524), 1.0556, 0.001, "kg/m3")

	-- 10,000 ft (3048 m) - published ISA table values.
	check("10000 ft pressure", Atmosphere.getPressure(3048), 69682, 0.001, "Pa")
	check("10000 ft density", Atmosphere.getDensity(3048), 0.9046, 0.001, "kg/m3")

	-- Tropopause - the model must switch layers cleanly here.
	check("Tropopause temperature", Atmosphere.getTemperature(11000), 216.65, 0.0001, "K")
	check("Tropopause pressure", Atmosphere.getPressure(11000), 22632, 0.001, "Pa")
	check("Tropopause density", Atmosphere.getDensity(11000), 0.36392, 0.001, "kg/m3")

	-- Deep in the isothermal layer - exercises the exponential branch.
	check("20 km pressure", Atmosphere.getPressure(20000), 5474.9, 0.002, "Pa")
	check("20 km density", Atmosphere.getDensity(20000), 0.08803, 0.002, "kg/m3")

	-- Airspeed relationship: the "2% per 1000 ft" rule of thumb predicts
	-- about 120 kt TAS for 100 kt indicated at 10,000 ft. The exact value is
	-- a little lower; a 5% tolerance confirms the physics without pretending
	-- the rule of thumb is exact.
	local tas100at10k = Atmosphere.equivalentToTrue(100, 3048)
	check("100 kt EAS -> TAS at 10000 ft", tas100at10k, 120, 0.05, "kt")

	-- Round trip must be lossless.
	local roundTrip = Atmosphere.trueToEquivalent(Atmosphere.equivalentToTrue(100, 3048), 3048)
	check("EAS -> TAS -> EAS round trip", roundTrip, 100, 0.0001, "kt")

	-- Density altitude on a standard day equals true altitude by definition.
	check("Density altitude, standard day", Atmosphere.getDensityAltitude(1524, 0), 1524, 0.002, "m")

	-- On a 20 C hot day the aircraft should behave as if roughly 2,300 ft
	-- higher. Wide tolerance: we are asserting the effect exists and is of a
	-- realistic magnitude, not matching a specific chart.
	local hotDA = Atmosphere.getDensityAltitude(1524, 20)
	check("Density altitude, ISA+20", hotDA, 2230, 0.15, "m")

	print(string.format("=== %s (%d checks) ===", allPassed and "ALL PASSED" or "FAILURES PRESENT", #results))
	return allPassed, results
end

return Atmosphere
