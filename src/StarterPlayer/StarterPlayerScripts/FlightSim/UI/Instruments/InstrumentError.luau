--!strict
--[[
	InstrumentError - the gauges read like real instruments, not like the physics.

	Phase 4, scope item 3. Until now every gauge showed the perfect number,
	which is the one thing a real cockpit never does.

	⚠️ THESE ARE DISPLAY ERRORS AND LIVE ONLY IN THE INSTRUMENT LAYER.

	Nothing here is ever fed back into the flight model. The aeroplane still
	flies on true values; only the needles lie, in the specific ways real
	needles lie. That separation is the entire training value of the phase - a
	pilot who learns on a perfect altimeter cannot read a real one - and it is
	also what keeps §4's published performance figures meaningful, because the
	physics never sees any of this.

	Everything is pure except the wet compass, which has to remember where its
	card was last frame. Purity is what lets each error be asserted against
	published numbers instead of eyeballed on a gauge.
]]

-- The SHARED FlightSim in ReplicatedStorage, not the one this script lives
-- under - Physics and Shared are replicated, the UI is not. Matches how
-- SixPack and Instrument resolve it.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FlightSim = ReplicatedStorage:WaitForChild("FlightSim")
local Atmosphere = require(FlightSim.Physics.Atmosphere)
local Units = require(FlightSim.Shared.Units)

local InstrumentError = {}

-- =========================================================================
-- AIRSPEED: STATIC-SOURCE POSITION ERROR
-- =========================================================================

--[[
	The published C172S airspeed calibration, as (CAS, IAS) pairs in knots.

	A real pitot-static system does not measure the free stream. The static
	port sits on a fuselage whose local pressure differs from ambient, and how
	much it differs depends on the angle of attack - so the error is largest
	slow and nose-high, exactly when the pilot most needs the number.

	Read straight off the POH calibration table. The physics computes
	equivalent airspeed, which is CAS for our purposes, so this converts the
	honest number INTO the one the instrument would show.

	Note the shape: at 48 kt CAS the ASI under-reads by 8 kt, by 80 kt the two
	agree, and above that it slightly over-reads. Anchored at (0, 0) because a
	parked aeroplane must indicate zero, not 40.
]]
local CALIBRATION_FLAPS_UP = {
	{ cas = 0, ias = 0 },
	{ cas = 48, ias = 40 },
	{ cas = 54, ias = 50 },
	{ cas = 62, ias = 60 },
	{ cas = 71, ias = 70 },
	{ cas = 80, ias = 80 },
	{ cas = 89, ias = 90 },
	{ cas = 99, ias = 100 },
	{ cas = 108, ias = 110 },
	{ cas = 118, ias = 120 },
	{ cas = 127, ias = 130 },
	{ cas = 137, ias = 140 },
}

-- Flaps 30. The error shrinks, because the flaps change the flow over the
-- static port at a given speed - which is why the POH prints two tables.
local CALIBRATION_FLAPS_DOWN = {
	{ cas = 0, ias = 0 },
	{ cas = 46, ias = 40 },
	{ cas = 53, ias = 50 },
	{ cas = 61, ias = 60 },
	{ cas = 70, ias = 70 },
	{ cas = 80, ias = 80 },
	{ cas = 85, ias = 85 },
}

local function interpolate(table_: { any }, cas: number): number
	local first = table_[1]
	local last = table_[#table_]
	if cas <= first.cas then
		return first.ias
	end
	if cas >= last.cas then
		-- Hold the final segment's slope rather than the final value: an ASI
		-- does not stop moving past the top of the published table.
		local a, b = table_[#table_ - 1], last
		local slope = (b.ias - a.ias) / (b.cas - a.cas)
		return b.ias + (cas - b.cas) * slope
	end
	for i = 1, #table_ - 1 do
		local a, b = table_[i], table_[i + 1]
		if cas >= a.cas and cas <= b.cas then
			local t = (cas - a.cas) / (b.cas - a.cas)
			return a.ias + (b.ias - a.ias) * t
		end
	end
	return cas
end

--[[
	What the ASI shows, in m/s, given the honest calibrated airspeed.

	`flaps` is 0..1. Between the two published tables the result is blended,
	because the POH prints the ends and the aeroplane flies the middle.
]]
function InstrumentError.indicatedAirspeed(calibratedMs: number, flaps: number?): number
	local cas = Units.msToKnots(math.max(0, calibratedMs))
	local up = interpolate(CALIBRATION_FLAPS_UP, cas)
	local f = math.clamp(flaps or 0, 0, 1)
	if f <= 0 then
		return Units.knotsToMs(up)
	end
	local down = interpolate(CALIBRATION_FLAPS_DOWN, cas)
	return Units.knotsToMs(up + (down - up) * f)
end

-- =========================================================================
-- HEADING: MAGNETIC RATHER THAN TRUE
-- =========================================================================

--[[
	Magnetic variation for this world, in degrees EAST.

	A real DI is set from the magnetic compass, so it reads magnetic and every
	published heading, runway number and chart bearing is magnetic too. The
	simulator's headings have been true since Phase 1, which means the runway
	numbering and the DI have quietly disagreed with each other by however much
	variation would be.

	East is positive: magnetic = true - variation. Chosen rather than measured,
	because the world is fictional - but it is one number in one place, so a
	world with a real location can set it honestly.
]]
InstrumentError.MAGNETIC_VARIATION_DEG = -12.0

function InstrumentError.magneticHeading(trueHeadingRad: number, variationDeg: number?): number
	local variation = math.rad(variationDeg or InstrumentError.MAGNETIC_VARIATION_DEG)
	return (trueHeadingRad - variation) % (2 * math.pi)
end

-- =========================================================================
-- THE WET COMPASS: TURNING ERROR AND LAG
-- =========================================================================

--[[
	⚠️ THIS IS FOR THE STANDALONE MAGNETIC COMPASS, NOT THE SIX-PACK'S DI.

	They are different instruments and they fail differently, which is exactly
	why a real cockpit carries both:

	  - The DIRECTIONAL GYRO is gyroscopic. It is steady in a turn and has no
	    dip error at all - but it precesses, so the pilot resets it against the
	    compass every so often.
	  - The WET COMPASS is a magnet in fluid. It is correct in steady level
	    flight and useless in a turn, because the card hangs at an angle to the
	    earth's field and swings.

	So the six-pack's heading gauge gets magneticHeading() and NOTHING from
	here. This function is for the compass that belongs on the windscreen
	frame, and it is written and tested now because the maths is the part worth
	getting right - scope item 4 puts the instrument in front of it.

	NORTHERLY TURNING ERROR is modelled: rolling into a turn on a northerly
	heading, the card initially swings the WRONG WAY, so the pilot must roll
	out early. On southerly headings it runs ahead and the pilot rolls out
	late. The classic mnemonic is UNOS - Undershoot North, Overshoot South -
	and the error scales with the sine of the heading, vanishing on east and
	west.

	ACCELERATION ERROR (the other half, "ANDS") is deliberately NOT modelled:
	it needs longitudinal acceleration, which telemetry does not publish, and
	inventing it here would mean a display module reaching into the physics for
	a quantity nothing else wants.
]]
local DIP_GAIN = 1.0
local COMPASS_TAU = 0.7

function InstrumentError.newCompass(): any
	return { indicated = nil :: number?, }
end

--[[
	The compass card's position after `dt`, in radians.

	Angles are unwrapped through the short way round before the lag is applied,
	or a card passing north would take the 359-degree route back to zero and
	spin the wrong way for most of a second.
]]
function InstrumentError.stepCompass(
	state: any,
	magneticHeadingRad: number,
	bankRad: number,
	dt: number
): number
	local TAU = 2 * math.pi
	--[[
		Northerly turning error: proportional to bank and to COS of heading.

		Cosine, not sine, and the first version had it wrong. The error must be
		largest through north and south and ZERO through east and west - that
		is the whole reason a pilot can turn onto an easterly heading by the
		compass and cannot turn onto a northerly one. Sine puts the maxima on
		east and west, which is the exact opposite instrument.

		Sign check, at north with left bank: cos(0) = 1, bank negative, so the
		error is POSITIVE - the card swings right while the aeroplane turns
		left, which is the lag that makes you roll out early. Undershoot North.
	]]
	local target = magneticHeadingRad - DIP_GAIN * bankRad * math.cos(magneticHeadingRad)
	target = target % TAU

	if state.indicated == nil then
		state.indicated = target
		return target
	end

	local delta = (target - state.indicated + math.pi) % TAU - math.pi
	local blend = if COMPASS_TAU > 0 then 1 - math.exp(-math.max(dt, 0) / COMPASS_TAU) else 1
	state.indicated = (state.indicated + delta * blend) % TAU
	return state.indicated
end

-- =========================================================================
-- ALTIMETER: WHAT ITS BARO SETTING SAYS
-- =========================================================================

--[[
	Standard datum, in pascals. An altimeter set here reads pressure altitude.
]]
InstrumentError.STANDARD_QNH_PA = 101325

--[[
	What the altimeter shows, in metres.

	An altimeter is a barometer with an adjustable datum. It reads the true
	height above the field only when its Kollsman window is set to the actual
	QNH; set it anywhere else and every reading is offset by the difference.

	"HIGH TO LOW, LOOK OUT BELOW" falls straight out of this: fly toward lower
	pressure without resetting, so the setting is now higher than actual, and
	the altimeter over-reads - the aeroplane is LOWER than it says.

	The conversion deliberately goes through Atmosphere.getPressureAltitude
	twice rather than restating its constant. Two readings of the same true
	altitude against two different datums differ by exactly the datum
	difference, so the feet-per-pascal figure stays in one place.
]]
function InstrumentError.indicatedAltitude(
	trueAltitudeM: number,
	actualQnhPa: number?,
	setQnhPa: number?
): number
	local actual = actualQnhPa or InstrumentError.STANDARD_QNH_PA
	local set = setQnhPa or InstrumentError.STANDARD_QNH_PA
	local offset = Atmosphere.getPressureAltitude(trueAltitudeM, actual)
		- Atmosphere.getPressureAltitude(trueAltitudeM, set)
	return trueAltitudeM + offset
end

-- =========================================================================
-- VERIFICATION
-- =========================================================================

function InstrumentError.runTests(): (boolean, { any })
	local results = {}
	local allPassed = true

	local function record(label: string, passed: boolean, detail: string)
		table.insert(results, { label = label, passed = passed, detail = detail })
		if not passed then
			allPassed = false
		end
		print(string.format("  [%s] %s - %s", if passed then "PASS" else "FAIL", label, detail))
	end

	print("\n=== InstrumentError ===")

	-- ---- ASI position error ---------------------------------------------
	local function iasKt(casKt: number, flaps: number?): number
		return Units.msToKnots(InstrumentError.indicatedAirspeed(Units.knotsToMs(casKt), flaps))
	end

	record(
		"A parked aeroplane indicates zero",
		math.abs(iasKt(0)) < 1e-9,
		string.format("%.2f kt", iasKt(0))
	)
	--[[
		THE published anchor points. These are POH numbers, not numbers this
		code produced - if the table is ever "tidied", these fail.
	]]
	record(
		"The ASI under-reads by 8 kt near the stall",
		math.abs(iasKt(48) - 40) < 0.01,
		string.format("48 kt CAS indicates %.1f kt", iasKt(48))
	)
	record(
		"The ASI is honest at 80 kt",
		math.abs(iasKt(80) - 80) < 0.01,
		string.format("80 kt CAS indicates %.1f kt", iasKt(80))
	)
	record(
		"The ASI over-reads slightly at cruise",
		iasKt(118) > 118 and math.abs(iasKt(118) - 120) < 0.01,
		string.format("118 kt CAS indicates %.1f kt", iasKt(118))
	)
	record(
		"Position error interpolates between published points",
		iasKt(51) > 40 and iasKt(51) < 60,
		string.format("51 kt CAS indicates %.1f kt, between the 48 and 54 rows", iasKt(51))
	)
	record(
		"Past the table the needle keeps moving",
		iasKt(150) > iasKt(137),
		string.format("150 kt CAS indicates %.1f kt against %.1f at 137", iasKt(150), iasKt(137))
	)
	--[[
		The error is a function of ANGLE OF ATTACK, which is why it shrinks
		with flap: at a given speed the flapped aeroplane sits at a lower
		alpha, so the static port sees less of the fuselage's own pressure
		field. The POH prints two tables for exactly this reason.
	]]
	record(
		"Flaps reduce the position error",
		math.abs(iasKt(48, 1) - 48) < math.abs(iasKt(48, 0) - 48),
		string.format(
			"48 kt CAS indicates %.1f flaps up (%.1f kt of error) against %.1f flaps down (%.1f kt)",
			iasKt(48, 0), math.abs(iasKt(48, 0) - 48), iasKt(48, 1), math.abs(iasKt(48, 1) - 48)
		)
	)
	record(
		"Half flap sits between the two tables",
		iasKt(48, 0.5) > iasKt(48, 0) and iasKt(48, 0.5) < iasKt(48, 1),
		string.format("%.1f up, %.1f half, %.1f down", iasKt(48, 0), iasKt(48, 0.5), iasKt(48, 1))
	)

	-- ---- Magnetic variation ---------------------------------------------
	local function magDeg(trueDeg: number, varDeg: number?): number
		return math.deg(InstrumentError.magneticHeading(math.rad(trueDeg), varDeg))
	end
	record(
		"West variation makes magnetic read higher than true",
		math.abs(magDeg(0, -12) - 12) < 1e-6,
		string.format("true 000 with 12W reads %.1f magnetic", magDeg(0, -12))
	)
	record(
		"East variation makes magnetic read lower than true",
		math.abs(magDeg(90, 10) - 80) < 1e-6,
		string.format("true 090 with 10E reads %.1f magnetic", magDeg(90, 10))
	)
	record(
		"Magnetic heading wraps rather than going negative",
		magDeg(5, 10) > 350,
		string.format("true 005 with 10E reads %.1f, not %.1f", magDeg(5, 10), 5 - 10)
	)

	-- ---- Wet compass ----------------------------------------------------
	--[[
		UNOS. Rolling into a turn near NORTH, the card initially swings the
		wrong way, which is what makes a pilot roll out early; near SOUTH it
		runs ahead and they roll out late. On east and west there is no error
		at all, which is the cleanest thing to assert.
	]]
	local compass = InstrumentError.newCompass()
	InstrumentError.stepCompass(compass, 0, 0, 1) -- settle on north, wings level
	local settledNorth = compass.indicated
	record(
		"Level on north the compass is honest",
		math.abs(settledNorth) < 1e-6,
		string.format("reads %.2f deg", math.deg(settledNorth))
	)

	-- Banked left (negative) on north: the error term is -gain * bank * sin(0)
	-- = 0 exactly on north, so probe just past it where sin is non-zero.
	local function errorAt(headingDeg: number, bankDeg: number): number
		local c = InstrumentError.newCompass()
		local h = math.rad(headingDeg)
		local shown = InstrumentError.stepCompass(c, h, math.rad(bankDeg), 100)
		local delta = math.deg((shown - h + math.pi) % (2 * math.pi) - math.pi)
		return delta
	end
	record(
		"Turning error is largest near north and south",
		math.abs(errorAt(20, 20)) > 3 and math.abs(errorAt(200, 20)) > 3,
		string.format("020 err %.1f, 200 err %.1f deg at 20 bank", errorAt(20, 20), errorAt(200, 20))
	)
	record(
		"Turning error vanishes on east and west",
		math.abs(errorAt(90, 20)) < 1e-6 and math.abs(errorAt(270, 20)) < 1e-6,
		string.format("090 err %.3f, 270 err %.3f deg", errorAt(90, 20), errorAt(270, 20))
	)
	record(
		"North and south errors have opposite sign",
		errorAt(20, 20) * errorAt(200, 20) < 0,
		string.format("020 %.1f against 200 %.1f deg", errorAt(20, 20), errorAt(200, 20))
	)
	record(
		"Wings level the compass has no turning error",
		math.abs(errorAt(20, 0)) < 1e-9,
		string.format("%.4f deg at zero bank", errorAt(20, 0))
	)

	--[[
		THE wrap test. A card easing from 355 to 005 must take the six-degree
		route, not the 354-degree one. Unwrapping is the whole reason the lag
		is applied to a delta rather than to the raw angles.
	]]
	local wrap = InstrumentError.newCompass()
	InstrumentError.stepCompass(wrap, math.rad(355), 0, 100)
	local shown = InstrumentError.stepCompass(wrap, math.rad(5), 0, 0.2)
	local shownDeg = math.deg(shown)
	record(
		"The card takes the short way round through north",
		shownDeg > 355 or shownDeg < 5,
		string.format("eased from 355 toward 005 and reads %.1f", shownDeg)
	)

	local lag = InstrumentError.newCompass()
	InstrumentError.stepCompass(lag, 0, 0, 100)
	local afterOneStep = math.deg(InstrumentError.stepCompass(lag, math.rad(90), 0, 0.1))
	record(
		"The card lags rather than snapping",
		afterOneStep > 0 and afterOneStep < 45,
		string.format("0 to 90 in one 0.1 s step reads %.1f", afterOneStep)
	)

	-- ---- Altimeter -------------------------------------------------------
	local STD = InstrumentError.STANDARD_QNH_PA
	record(
		"Set to the actual QNH the altimeter reads true altitude",
		math.abs(InstrumentError.indicatedAltitude(1000, 99000, 99000) - 1000) < 1e-6,
		string.format("%.2f m against a true 1000", InstrumentError.indicatedAltitude(1000, 99000, 99000))
	)
	--[[
		"High to low, look out below." A setting left HIGHER than actual makes
		the altimeter over-read, so the aeroplane is lower than indicated -
		which is the error that flies people into terrain.
	]]
	local overRead = InstrumentError.indicatedAltitude(1000, STD - 1000, STD)
	record(
		"A setting left too high makes the altimeter over-read",
		overRead > 1000,
		string.format("reads %.1f m at a true 1000 with the setting 10 hPa high", overRead)
	)
	record(
		"10 hPa of error is about 273 ft",
		math.abs((overRead - 1000) - Units.feetToMeters(273)) < 1.0,
		string.format("%.1f m against the 273 ft rule of thumb (%.1f m)", overRead - 1000, Units.feetToMeters(273))
	)
	local underRead = InstrumentError.indicatedAltitude(1000, STD + 1000, STD)
	record(
		"A setting left too low makes the altimeter under-read",
		underRead < 1000,
		string.format("reads %.1f m at a true 1000", underRead)
	)
	record(
		"The two errors are symmetric",
		math.abs((overRead - 1000) + (underRead - 1000)) < 1e-6,
		string.format("+%.2f against %.2f m", overRead - 1000, underRead - 1000)
	)

	local passed, total = 0, #results
	for _, r in results do
		if r.passed then
			passed += 1
		end
	end
	print(string.format("=== InstrumentError: %d/%d ===", passed, total))

	return allPassed, results
end

return InstrumentError
