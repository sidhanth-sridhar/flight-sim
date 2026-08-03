--!strict
--[[
	Units
	-----
	Conversions between the three unit systems this project has to speak:

	  1. SI (metres, kg, m/s, Newtons) - the physics modules work entirely in
	     SI, because every aerodynamic formula and every published aircraft
	     performance figure is expressed this way.
	  2. Roblox studs - what the engine actually consumes.
	  3. Aviation units (knots, feet, feet per minute, nautical miles) - what
	     the cockpit instruments display, because that is what pilots read.

	Keeping all three separated by explicit conversions, rather than hoping
	they line up, is what stops the "why is my aircraft 20x too fast" class of
	bug. The physics never sees knots; the instruments never see Newtons.

	At the current scale (1 stud = 1 m) the stud conversions are identity, but
	route through them anyway - changing world scale then stays a one-line
	edit in Constants rather than an archaeology project.

	A NOTE ON MASS
	--------------
	Roblox mass = density x volume(studs^3). At 1 stud = 1 m, one Roblox mass
	unit equals one kilogram, so kg needs no conversion. The catch is that
	Roblox caps density at 100, so a 1,111 kg Cessna needs at least ~11 m^3 of
	part volume to reach its real mass. Handled in the aircraft builder via
	CustomPhysicalProperties; noted here because it surprises people.
]]

local Constants = require(script.Parent.Parent.Config.Constants)

local Units = {}

local SCALE = Constants.STUDS_PER_METER

-- =========================================================================
-- EXACT CONVERSION FACTORS
-- =========================================================================
-- All internationally defined exact values - no rounding, because errors
-- here compound through the entire simulation.

Units.METERS_PER_FOOT = 0.3048 -- exact by definition
Units.METERS_PER_NAUTICAL_MILE = 1852 -- exact by definition
Units.MS_PER_KNOT = 1852 / 3600 -- 1 nm/h = 0.5144444... m/s
Units.KG_PER_POUND = 0.45359237 -- exact by definition
Units.WATTS_PER_HP = 745.699872 -- mechanical horsepower
Units.PA_PER_INHG = 3386.389 -- altimeter settings

-- Gravity expressed in the units Roblox wants (studs/s^2).
Units.GRAVITY_STUDS = Constants.GRAVITY_MS2 * SCALE

-- =========================================================================
-- LENGTH
-- =========================================================================

function Units.metersToStuds(m: number): number
	return m * SCALE
end

function Units.studsToMeters(studs: number): number
	return studs / SCALE
end

function Units.feetToMeters(ft: number): number
	return ft * Units.METERS_PER_FOOT
end

function Units.metersToFeet(m: number): number
	return m / Units.METERS_PER_FOOT
end

-- Convenience: altitude comes off the aircraft in studs and goes onto the
-- altimeter in feet, so this pairing gets used every instrument frame.
function Units.studsToFeet(studs: number): number
	return Units.metersToFeet(studs / SCALE)
end

function Units.feetToStuds(ft: number): number
	return Units.feetToMeters(ft) * SCALE
end

function Units.nauticalMilesToMeters(nm: number): number
	return nm * Units.METERS_PER_NAUTICAL_MILE
end

function Units.metersToNauticalMiles(m: number): number
	return m / Units.METERS_PER_NAUTICAL_MILE
end

-- Flight-planning distances come out of the world in studs.
function Units.studsToNauticalMiles(studs: number): number
	return Units.metersToNauticalMiles(studs / SCALE)
end

-- =========================================================================
-- SPEED
-- =========================================================================

function Units.knotsToMs(kt: number): number
	return kt * Units.MS_PER_KNOT
end

function Units.msToKnots(ms: number): number
	return ms / Units.MS_PER_KNOT
end

function Units.msToStudsPerSec(ms: number): number
	return ms * SCALE
end

function Units.studsPerSecToMs(sps: number): number
	return sps / SCALE
end

-- Airspeed indicator path: assembly velocity (studs/s) -> displayed knots.
function Units.studsPerSecToKnots(sps: number): number
	return Units.msToKnots(sps / SCALE)
end

function Units.knotsToStudsPerSec(kt: number): number
	return Units.knotsToMs(kt) * SCALE
end

-- Vertical speed indicator path: climb rate is metres/s internally but every
-- VSI in aviation is marked in feet per minute.
function Units.msToFeetPerMin(ms: number): number
	return Units.metersToFeet(ms) * 60
end

function Units.feetPerMinToMs(fpm: number): number
	return Units.feetToMeters(fpm / 60)
end

function Units.studsPerSecToFeetPerMin(sps: number): number
	return Units.msToFeetPerMin(sps / SCALE)
end

-- =========================================================================
-- MASS, FORCE AND POWER
-- =========================================================================

-- Aircraft specifications are almost always published in pounds.
function Units.poundsToKg(lb: number): number
	return lb * Units.KG_PER_POUND
end

function Units.kgToPounds(kg: number): number
	return kg / Units.KG_PER_POUND
end

--[[
	Force conversion - the one that actually matters for physics correctness.

	Roblox applies force as mass x acceleration in ITS units: mass units and
	studs/s^2. A Newton is kg x m/s^2. Since 1 mass unit = 1 kg, the only
	adjustment needed is the length scale.

	Get this wrong and lift is off by the scale factor, which looks like a
	perfectly plausible but permanently untunable aircraft.
]]
function Units.newtonsToRobloxForce(n: number): number
	return n * SCALE
end

function Units.newtonsToRobloxForceVector(v: Vector3): Vector3
	return v * SCALE
end

-- Torque follows the same rule (force x distance), so the scale applies once
-- for the force and once for the moment arm.
function Units.newtonMetersToRobloxTorque(nm: number): number
	return nm * SCALE * SCALE
end

function Units.newtonMetersToRobloxTorqueVector(v: Vector3): Vector3
	return v * SCALE * SCALE
end

function Units.horsepowerToWatts(hp: number): number
	return hp * Units.WATTS_PER_HP
end

function Units.wattsToHorsepower(w: number): number
	return w / Units.WATTS_PER_HP
end

-- =========================================================================
-- PRESSURE
-- =========================================================================
-- Altimeter settings are given in inches of mercury (US) or hectopascals
-- (most of the world). Standard sea level is 29.92 inHg / 1013.25 hPa.

function Units.inHgToPascals(inHg: number): number
	return inHg * Units.PA_PER_INHG
end

function Units.pascalsToInHg(pa: number): number
	return pa / Units.PA_PER_INHG
end

function Units.hectopascalsToPascals(hpa: number): number
	return hpa * 100
end

function Units.pascalsToHectopascals(pa: number): number
	return pa / 100
end

return Units
