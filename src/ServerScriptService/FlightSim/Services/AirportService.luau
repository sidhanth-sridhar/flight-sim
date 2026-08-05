--!strict
--[[
	AirportService
	--------------
	One single-runway GA airport, built from constants at server start, plus the
	registry that everything else asks about runways and navigation points.

	WHY THIS EXISTS AT ALL, AND IT IS NOT SCENERY
	---------------------------------------------
	The Phase 1 gate was flown on a bare baseplate and the pilot reported the
	landing as extremely hard. That is not a flight model problem - §9 measured
	the approach and the flare against published figures and both were correct.
	It is a VISION problem: a featureless grey plane gives no depth cue and no
	speed cue, so there is nothing to judge height or closure against in the last
	five metres, which is exactly where a landing is won.

	So the markings here are load-bearing, not decoration:

	  - Centreline dashes are a RULER. 30 m painted, 20 m gap, a 50 m period.
	    At 60 kt one dash-plus-gap passes every 1.6 s, which is how a pilot
	    reads closure rate without an instrument.
	  - Vertical objects are the DEPTH cue. Edge markers of known height every
	    60 m, threshold wing bars, a windsock and hangars. Flat paint alone
	    cannot tell you whether you are three metres up or one.
	  - The aiming point tells you where you are going to touch down, which is
	    the whole of the approach.

	SPLIT: DATA IS AVAILABLE BEFORE Init(), GEOMETRY IS NOT
	-------------------------------------------------------
	Every function that answers a question - getRunway, navPoints,
	apronSlotCFrame - is a pure function of the constants below and works the
	moment this module is required. Only build() touches the world, and only
	Init() calls build().

	That split is not tidiness, it is a load-order fix. Init.server.luau starts
	services by walking Services:GetChildren(), whose order Roblox does not
	define, so AircraftService may well initialise before this module does. It
	asks for an apron slot during that call. Making the answer pure means the
	race cannot exist, and the explicit SERVICE_ORDER in the bootstrap is then a
	second belt rather than the only one.

	COORDINATES
	-----------
	World -Z is treated as NORTH. There is no magnetic model and no variation, so
	a runway's designator is simply its world heading over ten: the runway runs
	along Z, and taking off toward -Z is runway 36.

		-Z  north  runway 36 (heading 360)
		+Z  south  runway 18 (heading 180)
		+X  east
		-X  west - the taxiway, the apron and the whole circuit live here
]]

local Workspace = game:GetService("Workspace")

local AirportService = {}

-- =========================================================================
-- DIMENSIONS
-- =========================================================================

--[[
	THE AIRPORT'S ELEVATION, and the single most load-bearing number in this file.

	It used to be zero, and section 14 named that the largest known trap in
	Phase 3: with real terrain the ground is wherever the terrain says it is,
	and an airport nailed to y = 0 cannot sit on it. It is now a declared
	elevation and everything in this module derives from it, so the number can
	move and the aerodrome moves with it.

	250 m is about 820 ft, an ordinary elevation for a light-aircraft field. It
	is deliberately NOT zero: an airport that happens to sit at sea level would
	let a y = 0 assumption survive anywhere it was still hiding, and nothing
	would report it. The altimeter now reads field elevation on the ground,
	which is what a real one does.

	TERRAIN IS FITTED TO THIS, NOT THE OTHER WAY ROUND. TerrainService reads
	these constants and builds ground to match. The arrow points that way
	because the note at the top of this file is load-bearing: every question
	this module answers must be answerable before anything has initialised, and
	taking the elevation from a service would put it behind an Init() again.

	The grass sits 5 cm BELOW the pavement. Two reasons, and the first is not
	cosmetic: the ground spans the whole world and the runway sits inside its
	footprint, so coplanar top faces would z-fight across the entire runway. The
	second is that real runways are crowned slightly above the surrounding
	field, so the step is also correct.

	Consumers that were already right: AircraftService adds its spawn height to
	apronSlotCFrame() rather than to a constant, and FlightModel's ground effect
	raycasts (section 11). Both followed the elevation with no change at all.
]]
--[[
	THE AIRPORT REGISTRY.

	Phase 3 needs more than one aerodrome, and the pilot's decision was that
	EACH AIRPORT DECLARES ITS OWN ELEVATION rather than reading it back off the
	terrain. That keeps the property the note at the top of this file depends
	on: every question this module answers is answerable before anything has
	initialised. Taking elevation from TerrainService would have put it behind
	an Init() and reintroduced exactly the race §11 removed.

	TerrainService reads this table and fits a flat pad to each entry. The
	geometry below still describes the primary field only - a second aerodrome's
	runway, taxiway and apron are the next system, and this is the seam they
	will hang off rather than a finished registry.
]]
local PRIMARY_ID = "meadow"

local AIRPORTS: { [string]: any } = {
	meadow = {
		id = "meadow",
		name = "Meadow Field",
		-- 250 m is about 820 ft, an ordinary elevation for a light-aircraft
		-- field. Deliberately not zero - see the note below.
		elevation = 250,
		origin = Vector3.new(0, 0, 0),
		surface = "paved",
		-- The runway designators this field owns. Geometry for meadow is the
		-- one below and is signed off; do not move it.
		runways = { "18", "36" },
		-- Explicit, not runways[1]: the list is sorted for display, and 36 is
		-- the one aircraft park facing and the circuit is described from.
		defaultRunway = "36",
	},

	--[[
		Ridge Strip: a short grass strip 150 m higher and about 1.7 km east.

		It exists to exercise the things a second aerodrome is FOR - a different
		elevation, a shorter runway, a different surface, and a runway on the
		other axis. 09/27 runs east-west, where meadow's 18/36 runs along Z, so
		the geometry builder needs a heading it has never had.

		Its position is fixed by the terrain, not chosen freely: TerrainService
		fits a flat pad to each airport, and the pads must stay further apart
		than the blend distance or they pull each other off their declared
		elevations. This one leaves 210 m of slack.

		GEOMETRY IS NOT BUILT YET - this entry is the elevation the ground is
		already fitted to. The strip itself is the next system.
	]]
	ridge = {
		id = "ridge",
		name = "Ridge Strip",
		elevation = 400,
		origin = Vector3.new(1600, 0, 200),
		surface = "grass",
		runways = { "09", "27" },
		defaultRunway = "09",
	},
}

--[[
	How far the surrounding field sits BELOW the pavement, in metres.

	Not cosmetic: coplanar top faces z-fight across the whole runway, and a real
	runway is crowned slightly above the field anyway. Declared once here so
	that terrain and pavement cannot disagree about it - TerrainService builds
	its pads to grassOf(), and building them to elevationOf() by mistake put the
	ground exactly level with the runway and was caught by the test that asks
	whether the pavement still stands proud.
]]
local GRASS_OFFSET = 0.05

function AirportService.elevationOf(airportId: string?): number
	local airport = AIRPORTS[airportId or PRIMARY_ID]
	return if airport then airport.elevation else AIRPORTS[PRIMARY_ID].elevation
end

-- The height of the FIELD around an airport, which is what terrain is built to.
function AirportService.grassOf(airportId: string?): number
	return AirportService.elevationOf(airportId) - GRASS_OFFSET
end

function AirportService.getAirport(airportId: string?): any?
	return AIRPORTS[airportId or PRIMARY_ID]
end

function AirportService.airportIds(): { string }
	local ids = {}
	for id in AIRPORTS do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

AirportService.AIRPORTS = AIRPORTS
AirportService.PRIMARY_ID = PRIMARY_ID

--[[
	The primary field's surface, kept as a module constant because every piece
	of geometry below is still written against it. When the second aerodrome's
	geometry lands, these become per-airport lookups and this pair goes away.
]]
local SURFACE_Y = AIRPORTS[PRIMARY_ID].elevation
local GRASS_Y = AirportService.grassOf(PRIMARY_ID)
local PAVEMENT_THICKNESS = 0.4

--[[
	Runway 1,000 m x 23 m - 3,280 ft x 75 ft.

	The 172 needs about 370 m to get off at sea level and rather less to stop, so
	this is generous on purpose. A runway sized to the minimum would make every
	landing a spot landing and teach the pilot nothing about judging a normal
	one; 1,000 m is also an ordinary length for a real single-runway GA field,
	which is the point of the exercise.
]]
local RUNWAY_LENGTH = 1000
local RUNWAY_WIDTH = 23
local RUNWAY_HALF = RUNWAY_LENGTH / 2

-- Runway 36's threshold is the SOUTH end: you start there and fly north.
local THRESHOLD_36_Z = RUNWAY_HALF -- +500
local THRESHOLD_18_Z = -RUNWAY_HALF -- -500

--[[
	Aiming point 300 m in from the threshold.

	Real figure for a runway under 1,200 m; 400 m is used on longer ones. It is
	the mark a pilot flies the approach at, so getting it wrong would teach a
	sight picture that does not transfer.
]]
local AIMING_POINT_DISTANCE = 300

-- Taxiway parallel to the runway, on the west side.
local TAXIWAY_X = -60
local TAXIWAY_WIDTH = 15
local TAXIWAY_HALF_LENGTH = 480 -- slightly shorter than the runway

-- Connectors join the taxiway to the runway near each threshold.
local CONNECTOR_Z = 480

--[[
	The apron, west of the taxiway.

	Sized so seven spawn slots at 18 m spacing fit inside it with the outermost
	aircraft still clear of the edge. AircraftService owns the slot spacing; this
	owns where slot zero is.

	Workspace.SpawnLocation now lives here too, 40 m north of the aircraft line
	at (-150, 340) and flush with the surface. It used to sit on the world
	origin, which the runway now runs through - see the obstruction sweep in
	runTests(). Moving it also closes the "aircraft park 30 m from the spawn pad,
	which is a short walk" note in §0: the pilot now materialises on the apron
	beside their aeroplane.
]]
local APRON_CENTRE = Vector3.new(-150, 0, 300)
local APRON_SIZE_X = 180
local APRON_SIZE_Z = 100

--[[
	Circuit altitude, 305 m - 1,000 ft AGL, the standard light-aircraft pattern.

	Downwind sits 900 m out, about half a nautical mile, which puts the runway in
	roughly the right place in the side window for a 172.
]]
local PATTERN_ALTITUDE = 305
local DOWNWIND_OFFSET = 900

--[[
	How far beyond each threshold the crosswind and base turns happen.

	450 m, and the number is bounded by the world rather than chosen freely: the
	turn points sit at 500 + 450 = 950 m from the origin, against a field that
	reaches 1,024 m. At the 800 m this started as, the upwind point was at
	Z = -1,300 - three hundred metres past the edge of the world, where a pilot
	flying the circuit would have been over open space with no ground beneath.
	runTests() caught it, and now asserts it.
]]
local CIRCUIT_EXTENSION = 450

--[[
	The extent of the world, which TerrainService fills and which the circuit
	must fit inside.

	4,096 m, doubled when the second aerodrome arrived. The old 2,048 m was
	Roblox's maximum PART size and the field used to be one part; terrain is not
	a part, so retiring the baseplate removed the ceiling. This must match
	TerrainService.FIELD_SIZE - a test asserts it rather than trusting two files
	to be edited together.
]]
local FIELD_SIZE = 4096

AirportService.SURFACE_Y = SURFACE_Y
AirportService.GRASS_Y = GRASS_Y
AirportService.FIELD_SIZE = FIELD_SIZE
AirportService.CONTAINER_NAME = "Airport"

-- =========================================================================
-- COLOURS AND MATERIALS
-- =========================================================================

local ASPHALT = Color3.fromRGB(62, 62, 66)
local TAXIWAY_COLOR = Color3.fromRGB(74, 74, 78)
local APRON_COLOR = Color3.fromRGB(86, 86, 90)
local GRASS_COLOR = Color3.fromRGB(78, 112, 56)
local PAINT_WHITE = Color3.fromRGB(238, 238, 234)
local PAINT_YELLOW = Color3.fromRGB(216, 184, 40)
local MARKER_BLUE = Color3.fromRGB(40, 90, 200)
local MARKER_GREEN = Color3.fromRGB(40, 170, 80)
local HANGAR_COLOR = Color3.fromRGB(140, 142, 148)

-- =========================================================================
-- TYPES
-- =========================================================================

export type Runway = {
	id: string, -- "36"
	airport: string, -- "meadow" - which field this runway belongs to
	heading: number, -- degrees, 1..360
	length: number, -- m
	width: number, -- m
	threshold: Vector3, -- start of the usable surface
	departureEnd: Vector3, -- the far end
	direction: Vector3, -- unit, threshold -> departure end
	circuit: string, -- "left" | "right"
}

-- =========================================================================
-- THE REGISTRY
-- =========================================================================

--[[
	One runway, two directions. They are separate entries because a pilot uses
	them as separate runways - different threshold, different heading, different
	circuit - and every consumer downstream wants "runway 36", not "the runway,
	reversed".
]]
--[[
	THE RUNWAY REGISTRY IS SCOPED BY AIRPORT, and it had to be.

	It used to be one flat table keyed by designator, which worked exactly as
	long as there was one aerodrome. Two fields collide immediately: Meadow and
	Ridge could each own a "09", and a flat table silently returns whichever was
	written last. Every entry now names the airport it belongs to.

	The entries are GENERATED from these specs rather than written out. A
	runway's threshold, departure end and direction all follow from its
	airport's origin, its elevation and its heading, so writing them by hand
	means writing the same fact four times and maintaining it in four places -
	and Ridge's east-west runways would have been four more chances to get a
	sign wrong.
]]
local RIDGE_LENGTH = 550
local RIDGE_WIDTH = 18

local RUNWAY_SPECS: { [string]: { any } } = {
	meadow = {
		--[[
			Left-hand, which is the default for light aircraft everywhere and
			also the right choice here: the 172's left-turning tendency is
			modelled and was confirmed in the gate, so a left circuit is the one
			the aeroplane wants to fly.
		]]
		{ designator = "36", heading = 360, length = RUNWAY_LENGTH, width = RUNWAY_WIDTH, circuit = "left" },
		{ designator = "18", heading = 180, length = RUNWAY_LENGTH, width = RUNWAY_WIDTH, circuit = "left" },
	},
	ridge = {
		-- East-west, where Meadow runs north-south. This is the pair that
		-- proves nothing downstream assumes one orientation.
		{ designator = "09", heading = 90, length = RIDGE_LENGTH, width = RIDGE_WIDTH, circuit = "left" },
		{ designator = "27", heading = 270, length = RIDGE_LENGTH, width = RIDGE_WIDTH, circuit = "left" },
	},
}

--[[
	Heading to a unit direction, in the same convention FlightModel publishes:
	-Z is north, so heading 360 is (0, 0, -1) and heading 090 is (1, 0, 0).

	The near-zero snap is not cosmetic. `math.sin(math.rad(360))` is about
	-2.4e-16 rather than 0, which would put Meadow's threshold 1.2e-13 off the
	centreline and break assertions that have always compared against exactly
	zero. Snapping keeps the cardinal headings exact.
]]
local function directionFor(heading: number): Vector3
	local function snap(v: number): number
		return if math.abs(v) < 1e-9 then 0 else v
	end
	local r = math.rad(heading)
	return Vector3.new(snap(math.sin(r)), 0, snap(-math.cos(r)))
end

AirportService.directionFor = directionFor

local RUNWAYS: { [string]: { [string]: Runway } } = {}

for airportId, specs in RUNWAY_SPECS do
	local airport = AIRPORTS[airportId]
	local centre = Vector3.new(airport.origin.X, airport.elevation, airport.origin.Z)
	RUNWAYS[airportId] = {}

	for _, spec in specs do
		local dir = directionFor(spec.heading)
		local half = spec.length / 2
		RUNWAYS[airportId][spec.designator] = {
			id = spec.designator,
			airport = airportId,
			heading = spec.heading,
			length = spec.length,
			width = spec.width,
			-- The threshold is BEHIND the centre along the direction of travel.
			threshold = centre - dir * half,
			departureEnd = centre + dir * half,
			direction = dir,
			circuit = spec.circuit,
		}
	end
end

AirportService.DEFAULT_RUNWAY = "36"

--[[
	A runway, by airport and designator.

	BOTH arguments are meaningful now, and the airport comes first because that
	is the order the question is asked in - "Ridge's zero-niner", not "the
	zero-niner at Ridge". Passing only one argument gets that airport's default
	runway rather than silently searching every field for a matching number.
]]
function AirportService.getRunway(airportId: string?, runwayId: string?): Runway?
	local airport = AIRPORTS[airportId or PRIMARY_ID]
	if not airport then
		return nil
	end
	local runways = RUNWAYS[airport.id]
	if not runways then
		return nil
	end
	return runways[runwayId or airport.defaultRunway]
end

function AirportService.runwayIds(airportId: string?): { string }
	local ids = {}
	for id in RUNWAYS[airportId or PRIMARY_ID] or {} do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

-- Every runway everywhere, as { airport, runway } pairs. What navigation
-- between fields walks.
function AirportService.allRunways(): { Runway }
	local all = {}
	for _, id in AirportService.airportIds() do
		for _, designator in AirportService.runwayIds(id) do
			table.insert(all, RUNWAYS[id][designator])
		end
	end
	return all
end

-- =========================================================================
-- NAVIGATION POINTS
-- =========================================================================

--[[
	The circuit, derived from the runway rather than written out twice.

	A left circuit turns left off the departure heading, so the pattern sits on
	the left of the runway as flown. Computing the side from the direction vector
	means runway 18's circuit is generated, not maintained - and cannot drift out
	of step with 36's.

	Ground points carry y = SURFACE_Y; airborne points carry the pattern
	altitude, because a navigation point without a height is only half an answer.
]]
function AirportService.navPoints(airportId: string?, runwayId: string?): { [string]: Vector3 }?
	local runway = AirportService.getRunway(airportId, runwayId)
	if not runway then
		return nil
	end

	local dir = runway.direction
	local up = Vector3.yAxis

	--[[
		The left-hand side of the runway as flown.

		dir:Cross(up) points to the aircraft's RIGHT for a -Z heading, so the
		left side is the negation. Getting this backwards would put the whole
		circuit on the wrong side of the field and read as a right-hand pattern -
		which is exactly the sort of thing that looks fine until someone flies
		it, so runTests() checks the sign for both runways.
	]]
	local right = dir:Cross(up).Unit
	local lateral = if runway.circuit == "left" then -right else right

	local threshold = runway.threshold
	local departureEnd = runway.departureEnd

	return {
		Threshold = threshold,
		AimingPoint = threshold + dir * AIMING_POINT_DISTANCE,
		DepartureEnd = departureEnd,

		-- Straight ahead after take-off, still climbing.
		Upwind = departureEnd + dir * CIRCUIT_EXTENSION + up * PATTERN_ALTITUDE,

		-- Turned 90 degrees onto crosswind, half way out to the downwind line.
		Crosswind = departureEnd
			+ dir * CIRCUIT_EXTENSION
			+ lateral * (DOWNWIND_OFFSET / 2)
			+ up * PATTERN_ALTITUDE,

		--[[
			Abeam the middle of the runway, tracking back the other way.

			ANCHORED TO THE RUNWAY'S MIDPOINT, and it was not until a second
			aerodrome existed. This point alone was written as
			`lateral * DOWNWIND_OFFSET + up * PATTERN_ALTITUDE` - no base
			position at all - which was exactly right while Meadow was the only
			field, sat on the world origin, at y = 0. Both of those stopped
			being true: §20 lifted the airport to 250 m and §23 added a field
			1.6 km east.

			The result was a downwind leg 250 m too low at Meadow, and at Ridge
			one that was not at Ridge at all - it was over Meadow. Every other
			point in this table was already built from `threshold` or
			`departureEnd` and was correct throughout; this one was correct by
			coincidence, which is the only reason nothing reported it.
		]]
		Downwind = (threshold + departureEnd) * 0.5 + lateral * DOWNWIND_OFFSET + up * PATTERN_ALTITUDE,

		-- Abeam the threshold and turning base.
		Base = threshold - dir * CIRCUIT_EXTENSION + lateral * DOWNWIND_OFFSET + up * PATTERN_ALTITUDE,

		-- Lined up on the extended centreline, descending. Half pattern
		-- altitude, which is about where a 172 is on a normal final.
		Final = threshold - dir * CIRCUIT_EXTENSION + up * (PATTERN_ALTITUDE * 0.5),
	}
end

AirportService.PATTERN_ALTITUDE = PATTERN_ALTITUDE

-- =========================================================================
-- APRON SLOTS
-- =========================================================================

--[[
	Where AircraftService parks aircraft.

	Returns a CFrame ON THE SURFACE (y = SURFACE_Y). AircraftService adds its own
	spawn height, because how far a 172's centre sits above its tyres is a fact
	about the aircraft's gear geometry and belongs with the aircraft, not with
	the tarmac.

	The rotation is identity, and that is deliberate rather than lazy: a default
	CFrame's LookVector is (0, 0, -1), which is north, which is runway 36. So a
	parked aeroplane is already pointing at the runway it will depart from, and
	AircraftService needed no rotation added when it moved here from the origin.

	Slot 0 sits at the apron centre and the rest alternate either side of it, so
	a handful of aircraft stay clustered rather than trailing off one way.
]]
--[[
	Where aircraft park at each field.

	Meadow parks on its apron. Ridge is a grass strip with no apron, so aircraft
	park on the grass beside the threshold end - which is what actually happens
	at a strip. Both are given as an offset ALONG and ACROSS the field's default
	runway rather than as world coordinates, so the parking rotates with the
	aerodrome instead of having to be re-derived for every heading.
]]
local PARKING: { [string]: { along: number, across: number } } = {
	-- Reproduces the old APRON_CENTRE exactly: the apron sits 300 m south along
	-- runway 36's reciprocal and 150 m to its left.
	meadow = { along = -300, across = -150 },
	ridge = { along = -210, across = -34 },
}

--[[
	The surface CFrame of one parking slot at one airport.

	SLOTS SPREAD ACROSS THE RUNWAY, NOT ALONG THE X AXIS, and that generalisation
	is what makes this work at Ridge. Meadow's runway runs north-south, so its
	"right" vector is +X and the old X-spread was correct by coincidence; Ridge's
	runs east-west, and spreading along X would have parked its aircraft nose to
	tail down the strip. Meadow's layout is unchanged - a test asserts the slots
	are still 18 m apart along X and still face runway 36.

	Aircraft face the runway they will depart from, which is the whole reason
	the CFrame is oriented rather than a bare position.
]]
function AirportService.apronSlotCFrame(airportId: string?, slot: number, spacing: number): CFrame
	local airport = AIRPORTS[airportId or PRIMARY_ID] or AIRPORTS[PRIMARY_ID]
	local runway = RUNWAYS[airport.id][airport.defaultRunway]
	local parking = PARKING[airport.id] or { along = 0, across = 0 }

	local dir = runway.direction
	local right = dir:Cross(Vector3.yAxis)

	local offset = 0
	if slot > 0 then
		local step = math.ceil(slot / 2)
		local side = if slot % 2 == 1 then 1 else -1
		offset = side * step * spacing
	end

	local centre = Vector3.new(airport.origin.X, airport.elevation, airport.origin.Z)
	local position = centre + dir * parking.along + right * (parking.across + offset)

	return CFrame.lookAt(position, position + dir)
end

--[[
	Which aerodrome is nearest a point, by airport origin.

	The pilot's decision (recorded in §0) is that a player spawns at the field
	nearest them, with no chooser - that is deferred to the Phase 4b tablet.
	Measured to the ORIGIN rather than to the parking or the threshold because
	the origin is the one point every airport has regardless of how it is laid
	out, and the fields are kilometres apart so nothing subtler would change the
	answer.

	Pure, like everything else above it, so AircraftService can ask before any
	geometry exists.
]]
function AirportService.nearestAirport(position: Vector3): string
	local bestId, bestDistance = PRIMARY_ID, math.huge

	for _, id in AirportService.airportIds() do
		local airport = AIRPORTS[id]
		local origin = Vector3.new(airport.origin.X, airport.elevation, airport.origin.Z)
		-- Horizontal distance: an aircraft 400 m above Ridge is at Ridge, not
		-- somewhere between the two fields.
		local flat = Vector3.new(origin.X - position.X, 0, origin.Z - position.Z)
		local d = flat.Magnitude
		if d < bestDistance then
			bestId, bestDistance = id, d
		end
	end

	return bestId
end

function AirportService.distanceBetween(fromId: string, toId: string): number?
	local a, b = AIRPORTS[fromId], AIRPORTS[toId]
	if not a or not b then
		return nil
	end
	return (Vector3.new(b.origin.X - a.origin.X, 0, b.origin.Z - a.origin.Z)).Magnitude
end

--[[
	The heading a direction vector represents, in degrees, 0 .. 360.

	The exact inverse of directionFor(), and it has to be: a bearing this module
	publishes is a number the pilot will fly by reading the DI, so if the two
	disagree the flight plan is wrong in a way that only shows up in the air.
	runTests() round-trips every cardinal through both.

	Returns 360 rather than 0 for north, matching how runways are designated -
	runway 36, not runway 0.
]]
function AirportService.headingOf(direction: Vector3): number
	local heading = math.deg(math.atan2(direction.X, -direction.Z))
	if heading <= 0 then
		heading += 360
	end
	return heading
end

--[[
	True bearing from one field to another, in degrees.

	Horizontal, for the same reason nearestAirport is (§24): Ridge is 150 m
	above Meadow, and a bearing is a compass direction, not a line of sight.
]]
function AirportService.bearingBetween(fromId: string, toId: string): number?
	local a, b = AIRPORTS[fromId], AIRPORTS[toId]
	if not a or not b or a.id == b.id then
		return nil
	end
	return AirportService.headingOf(Vector3.new(b.origin.X - a.origin.X, 0, b.origin.Z - a.origin.Z))
end

--[[
	Which runway at an airport best suits arriving on a given track.

	The one whose direction most nearly matches the inbound course, which is what
	a pilot picks in the absence of wind. Derived rather than declared, so it
	stays right if a runway is added or an airport is moved.
]]
function AirportService.bestRunwayFor(airportId: string, course: Vector3): Runway?
	local runways = RUNWAYS[airportId]
	if not runways then
		return nil
	end

	local flat = Vector3.new(course.X, 0, course.Z)
	if flat.Magnitude < 1e-6 then
		return nil
	end
	flat = flat.Unit

	local best, bestDot = nil, -math.huge
	for _, designator in AirportService.runwayIds(airportId) do
		local runway = runways[designator]
		local dot = runway.direction:Dot(flat)
		if dot > bestDot then
			best, bestDot = runway, dot
		end
	end
	return best
end

--[[
	A FLIGHT PLAN from one field to another.

	Shaped like navPoints deliberately: named keys, world Vector3s for the
	geographic points, and nil for a route that does not exist. A pilot planning
	Meadow to Ridge gets the same kind of answer they already get for a circuit,
	so the two read as one navigation system rather than two.

	It is more than a distance and a bearing because a distance and a bearing do
	not tell you what to do. This carries the climb, the runway to expect at the
	far end, and the point the circuit begins - and then HANDS OFF to navPoints
	for the circuit itself rather than duplicating it, which is what stops the
	two drifting apart.

	Everything here is derived. Nothing is a number chosen to look plausible:
	the cruise altitude is circuit height above the higher of the two fields,
	the arrival runway is whichever best matches the inbound course, and the
	climb is simply the difference in elevation.
]]
export type FlightPlan = {
	from: string,
	to: string,
	fromName: string,
	toName: string,
	distance: number, -- m, horizontal
	bearing: number, -- degrees true, from -> to
	reciprocal: number, -- degrees, the way home
	departureElevation: number,
	arrivalElevation: number,
	climb: number, -- m, positive means the destination is higher
	cruiseAltitude: number, -- m above sea level
	departureRunway: string,
	arrivalRunway: string,
	Departure: Vector3,
	TopOfClimb: Vector3,
	CircuitEntry: Vector3,
	Destination: Vector3,
}

function AirportService.flightPlan(fromId: string, toId: string): FlightPlan?
	local a, b = AIRPORTS[fromId], AIRPORTS[toId]
	if not a or not b or a.id == b.id then
		return nil
	end

	local from = Vector3.new(a.origin.X, a.elevation, a.origin.Z)
	local to = Vector3.new(b.origin.X, b.elevation, b.origin.Z)
	local course = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	local distance = course.Magnitude
	local bearing = AirportService.headingOf(course)

	-- Depart on the runway pointing most nearly at the destination, arrive on
	-- the one most nearly aligned with the course in.
	local departureRunway = AirportService.bestRunwayFor(a.id, course) :: Runway
	local arrivalRunway = AirportService.bestRunwayFor(b.id, course) :: Runway

	--[[
		Circuit height above the HIGHER field, so the leg clears both and the
		descent into the arrival circuit is a normal one. Derived from
		PATTERN_ALTITUDE rather than picked, so it moves if the pattern does.
	]]
	local cruiseAltitude = math.max(a.elevation, b.elevation) + PATTERN_ALTITUDE

	local arrivalNav = AirportService.navPoints(b.id, arrivalRunway.id) :: { [string]: Vector3 }

	return {
		from = a.id,
		to = b.id,
		fromName = a.name,
		toName = b.name,
		distance = distance,
		bearing = bearing,
		reciprocal = AirportService.headingOf(-course),
		departureElevation = a.elevation,
		arrivalElevation = b.elevation,
		climb = b.elevation - a.elevation,
		cruiseAltitude = cruiseAltitude,
		departureRunway = departureRunway.id,
		arrivalRunway = arrivalRunway.id,

		-- Off the departure runway's far end, where the climb-out starts.
		Departure = departureRunway.departureEnd,

		-- Level at cruise, a quarter of the way along. Short legs like this one
		-- spend most of their time climbing or descending, which is honest.
		TopOfClimb = Vector3.new(
			from.X + course.Unit.X * distance * 0.25,
			cruiseAltitude,
			from.Z + course.Unit.Z * distance * 0.25
		),

		-- Where the arrival field's own circuit takes over. This is navPoints'
		-- answer, not a second copy of it.
		CircuitEntry = arrivalNav.Downwind,
		Destination = arrivalNav.Threshold,
	}
end

AirportService.APRON_CENTRE = APRON_CENTRE
AirportService.APRON_SIZE = Vector2.new(APRON_SIZE_X, APRON_SIZE_Z)

-- =========================================================================
-- GROUND HEIGHT
-- =========================================================================

--[[
	The height of the ground under a point, by raycast.

	This is the answer to the note left in §10: ground effect assumed the ground
	was at y = 0, which was true of the baseplate and is no longer the whole
	truth now that the runway is crowned above the grass.

	Exposed here for tests and for anything on the server that needs it. The
	CLIENT does not call this - FlightModel casts its own ray inside the frame
	loop, because a per-frame physics term cannot afford a round trip and
	ReplicatedStorage code cannot reach a server service anyway.

	Returns nil when there is nothing underneath, which is a real answer: off the
	edge of the world there is no ground and no ground effect.
]]
function AirportService.groundHeightAt(position: Vector3, maxDistance: number?): number?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = false

	-- Aircraft are not ground. Built as a list rather than inline because
	-- { FindFirstChild(...) } is an EMPTY table when the folder does not exist
	-- yet, which silently filters nothing and is a trap to read back.
	local ignore = {}
	local aircraft = Workspace:FindFirstChild("Aircraft")
	if aircraft then
		table.insert(ignore, aircraft)
	end
	params.FilterDescendantsInstances = ignore

	local reach = maxDistance or 500
	local hit = Workspace:Raycast(position + Vector3.new(0, 1, 0), Vector3.new(0, -reach, 0), params)
	return if hit then hit.Position.Y else nil
end

-- =========================================================================
-- BUILDING THE WORLD
-- =========================================================================

local function log(message: string, ...)
	print("[FlightSim:Airport] " .. string.format(message, ...))
end

local built: Folder? = nil

--[[
	A paved surface: collidable, and the thing wheels actually roll on.

	Friction is left at the Roblox default here. The tyres carry friction 0 at
	weight 100 (§6f), which means the combination is dominated by the tyre
	whatever the runway does - GroundHandling models grip, rolling resistance and
	braking as real forces, and a grippy runway would double-count all three.
]]
local function pavement(name: string, size: Vector3, centre: Vector3, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Position = centre
	part.Anchored = true
	part.Locked = true
	part.Color = color
	part.Material = Enum.Material.Asphalt
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

--[[
	A painted marking.

	CanCollide = false, which matters more than it looks. Paint sits 2 cm proud
	of the surface to avoid z-fighting, and a collidable 2 cm lip under a
	nosewheel at 60 kt is a real bump the pilot would feel on every centreline
	dash. Wheels pass straight through and roll on the pavement underneath.
]]
local function marking(name: string, size: Vector3, centre: Vector3, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = Vector3.new(size.X, 0.04, size.Z)
	part.Position = Vector3.new(centre.X, SURFACE_Y + 0.02, centre.Z)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false -- keeps paint out of every ground raycast
	part.Locked = true
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Parent = parent
	return part
end

--[[
	Anything standing up: edge markers, wing bars, the windsock, hangars.

	CanCollide is off for the small ones. They exist to be SEEN - that is the
	depth cue this airport was built for - and a 1,111 kg aeroplane clipping a
	runway edge marker should not be flipped onto its back by it.
]]
local function prop(name: string, size: Vector3, centre: Vector3, color: Color3, parent: Instance, collide: boolean?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Position = centre
	part.Anchored = true
	part.CanCollide = collide == true
	part.CanTouch = false
	part.Locked = true
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Parent = parent
	return part
end

--[[
	Runway designators, as seven-segment numerals.

	Simplified rather than authentic - real runway numbers have their own
	typeface - but they read correctly from the air at the size that matters,
	and they are built from the same rectangles as everything else here.

	`right` and `up` are the directions the TEXT runs in world space, so the
	number reads correctly to a pilot on approach: text-up is the direction of
	travel down the runway.
]]
local SEGMENTS = {
	-- name = { offsetX, offsetY, width, height } in text units, origin centre
	top = { 0, 1, 1, 0 },
	middle = { 0, 0, 1, 0 },
	bottom = { 0, -1, 1, 0 },
	topLeft = { -0.5, 0.5, 0, 1 },
	topRight = { 0.5, 0.5, 0, 1 },
	bottomLeft = { -0.5, -0.5, 0, 1 },
	bottomRight = { 0.5, -0.5, 0, 1 },
}

local DIGITS: { [string]: { string } } = {
	["0"] = { "top", "topLeft", "topRight", "bottomLeft", "bottomRight", "bottom" },
	["1"] = { "topRight", "bottomRight" },
	["3"] = { "top", "topRight", "middle", "bottomRight", "bottom" },
	["6"] = { "top", "topLeft", "middle", "bottomLeft", "bottomRight", "bottom" },
	["8"] = { "top", "topLeft", "topRight", "middle", "bottomLeft", "bottomRight", "bottom" },
}

local function buildDigit(digit: string, centre: Vector3, right: Vector3, up: Vector3, height: number, parent: Instance)
	local segments = DIGITS[digit]
	if not segments then
		return
	end

	local halfHeight = height / 2
	local width = height * 0.42
	local stroke = height * 0.11

	for _, name in segments do
		local s = SEGMENTS[name]
		local offset = right * (s[1] * width) + up * (s[2] * halfHeight)
		local position = centre + offset

		-- A segment is a bar along `right` or along `up`; its thickness is the
		-- stroke either way.
		local along = if s[3] > 0 then width + stroke else stroke
		local across = if s[4] > 0 then halfHeight + stroke else stroke

		local extentX = math.abs(right.X) * along + math.abs(up.X) * across
		local extentZ = math.abs(right.Z) * along + math.abs(up.Z) * across

		marking(
			string.format("Digit%s_%s", digit, name),
			Vector3.new(extentX, 0, extentZ),
			position,
			PAINT_WHITE,
			parent
		)
	end
end

--[[
	Everything painted on one runway end: threshold bars, designator, aiming
	point. Written once and called for both directions, so 18 cannot drift out of
	step with 36.
]]
--[[
	RIDGE STRIP, and the reason it is built from VECTORS rather than from
	coordinates.

	Meadow's builder writes world coordinates directly, which is correct and is
	signed off, and works because Meadow's runway happens to run along Z. Ridge's
	runs east-west. Rather than rewrite Meadow's geometry - explicitly out of
	scope - this builds from the runway's own DIRECTION and the pilot's right
	vector, so the same code lays out a strip at any heading. Point it at 09, 27,
	18 or 143 and the arithmetic does not change.

	`along` runs from the centre toward the departure end, `across` to the
	pilot's right looking that way, and `up` is height above the surface. No
	world axis appears anywhere below.

	It is a GRASS strip, so it is deliberately sparser than Meadow: a mown
	surface, threshold bars, edge markers and a windsock. What it does NOT drop
	is the edge markers - §11 is explicit that vertical objects of known size at
	known spacing are the depth cue, and a strip with no depth cue would be
	harder to land on than the baseplate was.
]]
--[[
	Deliberately much lighter than the surrounding terrain, which is (86, 122,
	62). The first attempt used (104, 138, 72) and, looked at from the ground,
	the strip was very nearly invisible against the field it sits in - the
	§11 failure all over again, where a surface you cannot see is a surface you
	cannot land on. A mown strip really is paler than rough grass, so this is
	both more legible and more honest.
]]
local STRIP_GREEN = Color3.fromRGB(132, 156, 92)
local STRIP_MARKER = Color3.fromRGB(236, 236, 230)

local function buildRidgeStrip(parent: Instance)
	local airport = AIRPORTS.ridge
	local runway = RUNWAYS.ridge[airport.defaultRunway]
	local surfaceY = airport.elevation

	local dir = runway.direction
	-- The pilot's right, looking down this runway. Same construction as
	-- buildRunwayEnd above, and asserted there for the same reason.
	local right = dir:Cross(Vector3.yAxis)
	local centre = Vector3.new(airport.origin.X, surfaceY, airport.origin.Z)

	local function at(along: number, across: number, up: number?): Vector3
		return centre + dir * along + right * across + Vector3.new(0, up or 0, 0)
	end

	-- Oriented so the part's length lies along the runway. CFrame.lookAt's
	-- LookVector is the part's -Z, and Size.Z is its Z, so a size of
	-- (width, thickness, length) lands length-along-runway at any heading.
	local function facing(position: Vector3): CFrame
		return CFrame.lookAt(position, position + dir)
	end

	local half = runway.length / 2

	-- ---- The mown surface ------------------------------------------------
	--[[
		A part, not terrain, for the same reason Meadow's runway is a part: a
		sloped terrain fill deviates by over a metre (§20) and a landing surface
		cannot. It sits proud of the pad exactly as Meadow's pavement does.
	]]
	local strip = Instance.new("Part")
	strip.Name = "RidgeStrip"
	strip.Size = Vector3.new(runway.width, PAVEMENT_THICKNESS, runway.length)
	strip.CFrame = facing(at(0, 0, -PAVEMENT_THICKNESS / 2))
	strip.Anchored = true
	strip.Locked = true
	strip.Color = STRIP_GREEN
	strip.Material = Enum.Material.Grass
	strip.TopSurface = Enum.SurfaceType.Smooth
	strip.BottomSurface = Enum.SurfaceType.Smooth
	strip.Parent = parent

	-- ---- Threshold bars, one set per direction ---------------------------
	for _, designator in airport.runways do
		local end_ = RUNWAYS.ridge[designator]
		-- Distance from the centre to THIS runway's threshold, along its own
		-- direction: the two ends are the same place approached from opposite
		-- sides, so this must be derived per runway rather than assumed.
		local toThreshold = (end_.threshold - centre)
		for i = -1, 1, 2 do
			local bar = Instance.new("Part")
			bar.Name = string.format("RidgeThreshold%s_%d", designator, i)
			bar.Size = Vector3.new(runway.width * 0.22, 0.04, 6)
			bar.CFrame = facing(centre + toThreshold + dir * 0 + right * (i * runway.width * 0.3) + Vector3.new(0, 0.02, 0))
			bar.Anchored = true
			bar.Locked = true
			bar.CanCollide = false
			bar.CanQuery = false
			bar.Color = STRIP_MARKER
			bar.Material = Enum.Material.SmoothPlastic
			bar.Parent = parent
		end
	end

	-- ---- Edge markers: the depth cue -------------------------------------
	--[[
		Every 60 m down both sides, the same spacing Meadow uses, because the
		cue only works if the spacing is known and consistent between fields.
	]]
	local markerCount = 0
	for along = -half + 30, half - 30, 60 do
		for _, side in { -1, 1 } do
			local marker = Instance.new("Part")
			marker.Name = string.format("RidgeEdge_%d_%d", markerCount, side)
			marker.Size = Vector3.new(0.5, 0.8, 0.5)
			marker.CFrame = facing(at(along, side * (runway.width / 2 + 2), 0.4))
			marker.Anchored = true
			marker.Locked = true
			marker.CanCollide = false
			marker.CanQuery = false
			marker.Color = MARKER_BLUE
			marker.Material = Enum.Material.SmoothPlastic
			marker.Parent = parent
		end
		markerCount += 1
	end

	-- ---- Windsock ---------------------------------------------------------
	local sockBase = at(-half + 40, runway.width / 2 + 18, 0)
	prop("RidgeWindsockPole", Vector3.new(0.3, 8, 0.3), sockBase + Vector3.new(0, 4, 0), Color3.fromRGB(220, 220, 220), parent)
	prop("RidgeWindsockCone", Vector3.new(1.2, 1.2, 4), sockBase + Vector3.new(0, 7.6, -2.4), Color3.fromRGB(235, 120, 30), parent)
end

local function buildRunwayEnd(runway: Runway, parent: Instance)
	local dir = runway.direction
	local threshold = runway.threshold

	--[[
		The pilot's right, looking down this runway.

		dir:Cross(up) IS the right vector, with no negation - Roblox's own CFrame
		agrees: an identity CFrame has LookVector (0,0,-1), UpVector (0,1,0) and
		RightVector (1,0,0), and the cross of the first two gives exactly the
		third. Negating it here would mirror every marking, which on a symmetric
		runway shows up only in the designator reading "63" instead of "36".
	]]
	local right = dir:Cross(Vector3.yAxis).Unit

	--[[
		Threshold bars: eight stripes across the width, 1.8 m wide and 22.5 m
		long, starting 6 m in. The count is what a 23 m runway carries in the
		real marking tables, and a pilot reads the number of stripes as the
		runway's width - so it is not a free choice.
	]]
	local STRIPE_COUNT = 8
	local STRIPE_WIDTH = 1.8
	local STRIPE_LENGTH = 22.5
	local STRIPE_GAP = 1.0
	local pitch = STRIPE_WIDTH + STRIPE_GAP
	local spanStart = -((STRIPE_COUNT - 1) * pitch) / 2

	for i = 0, STRIPE_COUNT - 1 do
		local lateral = spanStart + i * pitch
		local centre = threshold + dir * (6 + STRIPE_LENGTH / 2) + right * lateral
		marking(
			string.format("Threshold%s_%d", runway.id, i),
			Vector3.new(
				math.abs(right.X) * STRIPE_WIDTH + math.abs(dir.X) * STRIPE_LENGTH,
				0,
				math.abs(right.Z) * STRIPE_WIDTH + math.abs(dir.Z) * STRIPE_LENGTH
			),
			centre,
			PAINT_WHITE,
			parent
		)
	end

	-- Designator, two digits, reading up-runway.
	local DIGIT_HEIGHT = 18
	local numberCentre = threshold + dir * 52
	local digits = string.split(runway.id, "")
	local spacing = DIGIT_HEIGHT * 0.62

	buildDigit(digits[1], numberCentre - right * spacing / 2, right, dir, DIGIT_HEIGHT, parent)
	buildDigit(digits[2], numberCentre + right * spacing / 2, right, dir, DIGIT_HEIGHT, parent)

	--[[
		Aiming point: two broad bars either side of the centreline, 300 m in.
		This is the mark the approach is flown at, so it is the single most
		useful piece of paint on the runway for the problem this airport exists
		to solve.
	]]
	local AIM_LENGTH = 45
	local AIM_WIDTH = 6
	for _, side in { -1, 1 } do
		local centre = threshold + dir * (AIMING_POINT_DISTANCE + AIM_LENGTH / 2) + right * (side * 6)
		marking(
			string.format("AimingPoint%s_%d", runway.id, side),
			Vector3.new(
				math.abs(right.X) * AIM_WIDTH + math.abs(dir.X) * AIM_LENGTH,
				0,
				math.abs(right.Z) * AIM_WIDTH + math.abs(dir.Z) * AIM_LENGTH
			),
			centre,
			PAINT_WHITE,
			parent
		)
	end

	-- Threshold wing bars: green, standing up, marking the landing threshold.
	for _, side in { -1, 1 } do
		prop(
			string.format("WingBar%s_%d", runway.id, side),
			Vector3.new(2.5, 1.0, 0.4),
			threshold + right * (side * (RUNWAY_WIDTH / 2 + 3)) + Vector3.new(0, 0.5, 0),
			MARKER_GREEN,
			parent
		)
	end
end

function AirportService.build(parent: Instance?): Folder
	local target = parent or Workspace

	-- Idempotent: a rebuild replaces, so calling this twice cannot leave two
	-- airports overlapping in the same place.
	local existing = target:FindFirstChild(AirportService.CONTAINER_NAME)
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = AirportService.CONTAINER_NAME
	folder.Parent = target

	--[[
		THE GRASS IS NOT BUILT HERE, and it is no longer the baseplate either.

		It is TERRAIN, built by TerrainService, which reads GRASS_Y from this
		module and fits the ground to it. The baseplate part is retired at run
		time; it stays in default.project.json only so the Studio EDIT view has
		a floor.

		FIELD_SIZE is still declared here because the circuit is checked against
		it, and TerrainService covers the same square.
	]]

	--[[
		THE PLAYER SPAWN HAS TO FOLLOW THE ELEVATION.

		Workspace.SpawnLocation is Rojo's, and Rojo puts it at y = 0 - which was
		the apron until this task and is now 250 m underneath it. A player would
		have spawned inside the ground, under an airport they could not see.

		Moved at run time rather than in the project file, for the same reason
		the baseplate is retired at run time: editing default.project.json takes
		a Rojo restart AND a plugin reconnect (§3), and nothing here needs the
		edit view to change.
	]]
	local spawn = Workspace:FindFirstChild("SpawnLocation")
	if spawn and spawn:IsA("BasePart") then
		spawn.Position = Vector3.new(spawn.Position.X, SURFACE_Y + spawn.Size.Y / 2, spawn.Position.Z)
	end

	-- ---- Runway ----------------------------------------------------------
	pavement(
		"Runway",
		Vector3.new(RUNWAY_WIDTH, PAVEMENT_THICKNESS, RUNWAY_LENGTH),
		Vector3.new(0, SURFACE_Y - PAVEMENT_THICKNESS / 2, 0),
		ASPHALT,
		folder
	)

	-- ---- Taxiway and connectors -----------------------------------------
	pavement(
		"TaxiwayAlpha",
		Vector3.new(TAXIWAY_WIDTH, PAVEMENT_THICKNESS, TAXIWAY_HALF_LENGTH * 2),
		Vector3.new(TAXIWAY_X, SURFACE_Y - PAVEMENT_THICKNESS / 2, 0),
		TAXIWAY_COLOR,
		folder
	)

	local connectorInnerX = -(RUNWAY_WIDTH / 2)
	local connectorLength = math.abs(connectorInnerX - TAXIWAY_X)
	local connectorCentreX = (connectorInnerX + TAXIWAY_X) / 2

	for _, z in { CONNECTOR_Z, -CONNECTOR_Z } do
		pavement(
			string.format("Connector%s", if z > 0 then "36" else "18"),
			Vector3.new(connectorLength, PAVEMENT_THICKNESS, TAXIWAY_WIDTH),
			Vector3.new(connectorCentreX, SURFACE_Y - PAVEMENT_THICKNESS / 2, z),
			TAXIWAY_COLOR,
			folder
		)

		-- Hold-short: a yellow ladder across the connector, before the runway.
		for i = 0, 3 do
			marking(
				string.format("HoldShort%d_%d", z, i),
				Vector3.new(0.6, 0, TAXIWAY_WIDTH),
				Vector3.new(connectorInnerX - 8 + i * 1.2, 0, z),
				PAINT_YELLOW,
				folder
			)
		end
	end

	-- ---- Apron -----------------------------------------------------------
	pavement(
		"Apron",
		Vector3.new(APRON_SIZE_X, PAVEMENT_THICKNESS, APRON_SIZE_Z),
		Vector3.new(APRON_CENTRE.X, SURFACE_Y - PAVEMENT_THICKNESS / 2, APRON_CENTRE.Z),
		APRON_COLOR,
		folder
	)

	--[[
		No link part is needed between the apron and the taxiway, and one was
		removed rather than kept for tidiness: the apron's east edge is at
		x = -60 and the taxiway spans -67.5 to -52.5, so they already overlap by
		7.5 m along the apron's whole 100 m length. A link on top of that stuck
		30 m out into the grass on the far side.
	]]

	-- ---- Centreline: the ruler ------------------------------------------
	--[[
		30 m painted, 20 m gap. At 60 kt one 50 m period passes every 1.6
		seconds, which is the closure cue that a bare baseplate cannot give and
		the reason the pilot could not judge the flare.
	]]
	local DASH_LENGTH = 30
	local DASH_GAP = 20
	local DASH_PITCH = DASH_LENGTH + DASH_GAP
	local dashCount = math.floor((RUNWAY_LENGTH - 2 * AIMING_POINT_DISTANCE * 0.2) / DASH_PITCH)

	for i = 0, dashCount do
		local z = -RUNWAY_HALF + 60 + i * DASH_PITCH + DASH_LENGTH / 2
		if z < RUNWAY_HALF - 60 then
			marking("Centreline_" .. i, Vector3.new(0.9, 0, DASH_LENGTH), Vector3.new(0, 0, z), PAINT_WHITE, folder)
		end
	end

	-- ---- Edge lines ------------------------------------------------------
	for _, side in { -1, 1 } do
		marking(
			"EdgeLine_" .. side,
			Vector3.new(0.9, 0, RUNWAY_LENGTH),
			Vector3.new(side * (RUNWAY_WIDTH / 2 - 1.2), 0, 0),
			PAINT_WHITE,
			folder
		)
	end

	-- Taxiway centreline, yellow and continuous, as taxiways are.
	marking(
		"TaxiwayCentreline",
		Vector3.new(0.6, 0, TAXIWAY_HALF_LENGTH * 2),
		Vector3.new(TAXIWAY_X, 0, 0),
		PAINT_YELLOW,
		folder
	)

	-- ---- Per-end markings ------------------------------------------------
	buildRunwayEnd(RUNWAYS.meadow["36"], folder)
	buildRunwayEnd(RUNWAYS.meadow["18"], folder)

	-- ---- Edge markers: the depth cue -------------------------------------
	--[[
		Every 60 m down both edges, 0.8 m tall.

		These are what actually tell a pilot how high they are in the flare. A
		painted surface gives closure rate but almost no height information;
		objects of known size, passing at a known spacing, give both. This is the
		single most important thing in this file for the problem it was built to
		solve, and it is also the cheapest.
	]]
	local EDGE_MARKER_PITCH = 60
	local markerCount = math.floor(RUNWAY_LENGTH / EDGE_MARKER_PITCH)
	for i = 0, markerCount do
		local z = -RUNWAY_HALF + i * EDGE_MARKER_PITCH
		for _, side in { -1, 1 } do
			prop(
				string.format("EdgeMarker_%d_%d", i, side),
				Vector3.new(0.35, 0.8, 0.35),
				Vector3.new(side * (RUNWAY_WIDTH / 2 + 2.5), SURFACE_Y + 0.4, z),
				MARKER_BLUE,
				folder
			)
		end
	end

	-- ---- Windsock --------------------------------------------------------
	-- SURFACE_Y, not 0: this was the one prop still nailed to the old sea-level
	-- assumption, and it would have left the windsock buried 250 m down.
	local sockBase = Vector3.new(-40, SURFACE_Y, 380)
	prop("WindsockPole", Vector3.new(0.3, 8, 0.3), sockBase + Vector3.new(0, 4, 0), Color3.fromRGB(220, 220, 220), folder)
	prop("WindsockCone", Vector3.new(1.2, 1.2, 4), sockBase + Vector3.new(0, 7.6, -2.4), Color3.fromRGB(235, 120, 30), folder)

	-- ---- Hangars ---------------------------------------------------------
	--[[
		Three plain blocks by the apron. Collidable, unlike the small props: they
		are large enough that passing through one would look worse than hitting
		it, and they are nowhere near the runway.

		Deliberately plain. They are here to be a known size beside the apron and
		on the horizon during the circuit, not to be architecture.
	]]
	for i = 0, 2 do
		prop(
			"Hangar_" .. i,
			Vector3.new(30, 9, 22),
			Vector3.new(APRON_CENTRE.X - 20 + i * 45, SURFACE_Y + 4.5, APRON_CENTRE.Z - 85),
			HANGAR_COLOR,
			folder,
			true
		)
	end

	buildRidgeStrip(folder)

	built = folder
	return folder
end

function AirportService.getBuilt(): Folder?
	if built and built.Parent then
		return built
	end
	local existing = Workspace:FindFirstChild(AirportService.CONTAINER_NAME)
	return if existing and existing:IsA("Folder") then existing else nil
end

-- =========================================================================
-- INIT
-- =========================================================================

function AirportService.Init()
	AirportService.build()

	local runway = AirportService.getRunway(PRIMARY_ID) :: Runway
	log(
		"Ready - runway %s/%s, %d x %d m, apron at (%.0f, %.0f), circuit %s at %d m",
		"36",
		"18",
		runway.length,
		runway.width,
		APRON_CENTRE.X,
		APRON_CENTRE.Z,
		runway.circuit,
		PATTERN_ALTITUDE
	)
end

-- =========================================================================
-- VERIFICATION
-- =========================================================================

--[[
	Run from the Studio command bar, SERVER datamodel:
		require(game.ServerScriptService.FlightSim.Services.AirportService).runTests()
]]
function AirportService.runTests(): (boolean, { any })
	local results = {}
	local allPassed = true

	local function record(label: string, passed: boolean, detail: string)
		if not passed then
			allPassed = false
		end
		table.insert(results, { label = label, passed = passed, detail = detail })
		print(string.format("  [%s] %-52s %s", passed and "PASS" or "FAIL", label, detail))
	end

	local function checkRange(label: string, actual: number, lo: number, hi: number, unit: string)
		record(label, actual >= lo and actual <= hi, string.format("%.2f %s (expected %.2f..%.2f)", actual, unit, lo, hi))
	end

	print("=== AirportService: verification ===")

	local folder: Folder? = nil

	local body = function()

	-- 1. Registry ------------------------------------------------------------
	local ids = AirportService.runwayIds("meadow")
	record("Both runway directions are registered", #ids == 2, table.concat(ids, ", "))

	local r36 = AirportService.getRunway("meadow", "36") :: Runway
	local r18 = AirportService.getRunway("meadow", "18") :: Runway
	record("Runway 36 and 18 both resolve", r36 ~= nil and r18 ~= nil, "found")
	record("An unknown designator resolves to nil", AirportService.getRunway("meadow", "09") == nil, "Meadow has no 09; Ridge does")

	--[[
		The 172 needs about 370 m at sea level. A runway that could not take off
		from would make the whole airport useless for the thing it was built for,
		so the margin is asserted rather than assumed.
	]]
	record(
		"Runway is long enough for the 172 with real margin",
		r36.length >= 370 * 2,
		string.format("%d m against a ~370 m take-off requirement", r36.length)
	)
	checkRange("Runway width is a realistic GA figure", r36.width, 18, 45, "m")

	-- 2. The two directions are genuinely reciprocal -------------------------
	record(
		"Headings are reciprocal",
		math.abs(r36.heading - r18.heading) == 180,
		string.format("%d and %d", r36.heading, r18.heading)
	)
	record(
		"Directions are opposite unit vectors",
		(r36.direction + r18.direction).Magnitude < 1e-6
			and math.abs(r36.direction.Magnitude - 1) < 1e-6,
		string.format("%s and %s", tostring(r36.direction), tostring(r18.direction))
	)
	record(
		"Each threshold is the other's departure end",
		(r36.threshold - r18.departureEnd).Magnitude < 1e-6
			and (r18.threshold - r36.departureEnd).Magnitude < 1e-6,
		"thresholds and departure ends swap"
	)
	record(
		"Thresholds are one runway length apart",
		math.abs((r36.threshold - r18.threshold).Magnitude - r36.length) < 1e-6,
		string.format("%.1f m apart", (r36.threshold - r18.threshold).Magnitude)
	)

	--[[
		The designator must match the direction it is flown in, or a pilot lines
		up on "36" and departs south. -Z is north, so runway 36's direction must
		have a negative Z component and 18's a positive one.
	]]
	record(
		"Designator 36 actually points north (-Z)",
		r36.direction.Z < -0.99,
		string.format("direction Z = %+.2f", r36.direction.Z)
	)
	record(
		"Designator 18 actually points south (+Z)",
		r18.direction.Z > 0.99,
		string.format("direction Z = %+.2f", r18.direction.Z)
	)

	-- 3. Navigation points ---------------------------------------------------
	-- 2b. The registry is scoped by airport ---------------------------------
	--[[
		THE collision the scoping exists to prevent. Both fields could own a
		"09"; a flat table keyed by designator returns whichever was written
		last, silently. Meadow has no 09 and Ridge does, and each must answer
		for itself.
	]]
	record(
		"Two airports are registered",
		#AirportService.airportIds() == 2,
		table.concat(AirportService.airportIds(), ", ")
	)
	local ridge09 = AirportService.getRunway("ridge", "09")
	record(
		"Ridge owns 09 and Meadow does not",
		ridge09 ~= nil and AirportService.getRunway("meadow", "09") == nil,
		"the same designator resolves per airport, not globally"
	)
	record(
		"Every runway knows which airport it belongs to",
		(ridge09 :: any).airport == "ridge" and (r36 :: any).airport == "meadow",
		"runway.airport is set"
	)
	record(
		"An unknown airport resolves to nil rather than the primary",
		AirportService.getRunway("nowhere", "09") == nil,
		"no silent fallback to Meadow"
	)

	--[[
		Ridge's runways run EAST-WEST where Meadow's run north-south. This is
		the pair that proves nothing downstream assumes one orientation - and
		the reason the geometry is built from direction vectors.
	]]
	local ridge27 = AirportService.getRunway("ridge", "27") :: any
	record(
		"Ridge 09 points east and 27 points west",
		math.abs((ridge09 :: any).direction.X - 1) < 1e-9 and math.abs(ridge27.direction.X + 1) < 1e-9,
		string.format("%s and %s", tostring((ridge09 :: any).direction), tostring(ridge27.direction))
	)
	record(
		"Ridge's runways are perpendicular to Meadow's",
		math.abs((ridge09 :: any).direction:Dot(r36.direction)) < 1e-9,
		"09/27 across 18/36"
	)
	--[[
		Generated thresholds, not written ones: each end must be the other's
		departure end, exactly, at any heading.
	]]
	record(
		"Ridge's two ends are reciprocal",
		((ridge09 :: any).threshold - ridge27.departureEnd).Magnitude < 1e-6
			and (ridge27.threshold - (ridge09 :: any).departureEnd).Magnitude < 1e-6,
		"thresholds and departure ends swap"
	)
	record(
		"Ridge's runway sits at Ridge's elevation, not Meadow's",
		math.abs((ridge09 :: any).threshold.Y - AirportService.elevationOf("ridge")) < 1e-9
			and AirportService.elevationOf("ridge") ~= AirportService.elevationOf("meadow"),
		string.format("%.0f m against Meadow's %.0f m",
			AirportService.elevationOf("ridge"), AirportService.elevationOf("meadow"))
	)
	--[[
		Short, but long enough. A 172 needs about 370 m to get off at sea level
		and more at 400 m, so a strip that could not be departed from would be a
		trap rather than an aerodrome.
	]]
	record(
		"Ridge's strip is short but usable",
		(ridge09 :: any).length >= 450 and (ridge09 :: any).length < r36.length,
		string.format("%d m against Meadow's %d m and a ~370 m requirement",
			(ridge09 :: any).length, r36.length)
	)
	record(
		"allRunways() returns every runway at every field",
		#AirportService.allRunways() == 4,
		string.format("%d runways across %d airports",
			#AirportService.allRunways(), #AirportService.airportIds())
	)

	--[[
		Heading to direction, at the cardinals AND at an angle no runway uses.
		The near-zero snap is what keeps 360 exactly (0, 0, -1) rather than
		1.2e-13 off the centreline.
	]]
	local d360 = AirportService.directionFor(360)
	local d90 = AirportService.directionFor(90)
	local d45 = AirportService.directionFor(45)
	record(
		"Heading 360 is exactly north, with no floating-point dust",
		d360.X == 0 and d360.Z == -1,
		tostring(d360)
	)
	record(
		"Heading 090 is exactly east",
		d90.X == 1 and d90.Z == 0,
		tostring(d90)
	)
	--[[
		1e-6, not 1e-9: Vector3 components are float32, so a unit vector's
		magnitude is only good to about 1e-7. The cardinal checks above CAN use
		exact equality, because the snap makes those components literally 0 and
		1 - but 045 has no exact float32 representation and never will. Same
		lesson as the y = 250 tolerances in §7.
	]]
	record(
		"An off-cardinal heading still gives a unit vector",
		math.abs(d45.Magnitude - 1) < 1e-6 and d45.X > 0 and d45.Z < 0,
		string.format("045 -> %s, magnitude %.9f", tostring(d45), d45.Magnitude)
	)

	-- 2bb. Every circuit belongs to its own airport ---------------------------
	--[[
		THE CLASS OF BUG THIS PAIR EXISTS TO CATCH, and it caught a real one.

		`Downwind` was written as an offset from nothing - no threshold, no
		origin - which was correct while Meadow was the only field, on the world
		origin, at y = 0. After §20 it was 250 m too low, and after §23 Ridge's
		downwind leg was over MEADOW, 1.6 km from the field it belonged to.

		Nothing reported it because the old checks only asked whether airborne
		points were above ground points and whether they fitted in the world -
		both of which a wrong point comfortably passes. These two ask the
		questions that actually matter: is every circuit point NEAR ITS OWN
		AERODROME, and is it at circuit height ABOVE THAT FIELD.
	]]
	local strayPoints, wrongHeight = {}, {}
	for _, airportIdCheck in AirportService.airportIds() do
		local elev = AirportService.elevationOf(airportIdCheck)
		local origin = (AirportService.getAirport(airportIdCheck) :: any).origin
		for _, designator in AirportService.runwayIds(airportIdCheck) do
			local points = AirportService.navPoints(airportIdCheck, designator) :: { [string]: Vector3 }
			for name, point in points do
				--[[
					Generously sized: the circuit legitimately reaches
					DOWNWIND_OFFSET out and CIRCUIT_EXTENSION beyond each
					threshold, so anything inside that plus a margin is its own.
					Ridge's stray downwind was 1.6 km out and failed by a mile.
				]]
				local flat = Vector3.new(point.X - origin.X, 0, point.Z - origin.Z).Magnitude
				local reach = RUNWAY_HALF + CIRCUIT_EXTENSION + DOWNWIND_OFFSET + 100
				if flat > reach then
					table.insert(strayPoints, string.format("%s/%s %s %.0f m out", airportIdCheck, designator, name, flat))
				end

				-- Ground points at field elevation, airborne points at circuit
				-- height above THAT field - not above sea level.
				local above = point.Y - elev
				local isGround = name == "Threshold" or name == "DepartureEnd" or name == "AimingPoint"
				if isGround and math.abs(above) > 1e-6 then
					table.insert(wrongHeight, string.format("%s/%s %s %+.1f m", airportIdCheck, designator, name, above))
				elseif not isGround and above < PATTERN_ALTITUDE * 0.4 then
					table.insert(wrongHeight, string.format("%s/%s %s only %+.1f m above field", airportIdCheck, designator, name, above))
				end
			end
		end
	end
	record(
		"Every circuit point belongs to its own aerodrome",
		#strayPoints == 0,
		if #strayPoints == 0 then "all points within reach of their own field" else table.concat(strayPoints, ", ")
	)
	record(
		"Circuit heights are measured from their own field, not from sea level",
		#wrongHeight == 0,
		if #wrongHeight == 0
			then string.format("ground at field elevation, airborne near +%d m at both fields", PATTERN_ALTITUDE)
			else table.concat(wrongHeight, ", ")
	)

	-- 2c. Nearest airport, and per-field parking ------------------------------
	--[[
		The rule a player spawns by. The pilot's decision is nearest-to-them with
		no chooser (§0), so this is the whole of the selection logic and it is
		worth pinning at both fields and in between.
	]]
	local meadowOrigin = (AirportService.getAirport("meadow") :: any).origin
	local ridgeOrigin = (AirportService.getAirport("ridge") :: any).origin
	record(
		"Standing at Meadow picks Meadow",
		AirportService.nearestAirport(Vector3.new(meadowOrigin.X, 250, meadowOrigin.Z)) == "meadow",
		"nearest = meadow"
	)
	record(
		"Standing at Ridge picks Ridge",
		AirportService.nearestAirport(Vector3.new(ridgeOrigin.X, 400, ridgeOrigin.Z)) == "ridge",
		"nearest = ridge"
	)
	--[[
		HEIGHT MUST NOT DECIDE IT. An aeroplane 400 m above Ridge is at Ridge,
		not somewhere between the two fields, so the comparison is horizontal.
		A 3D distance would have made a high overflight of Ridge resolve to
		Meadow purely because Ridge is 150 m further up.
	]]
	record(
		"Altitude does not change which field is nearest",
		AirportService.nearestAirport(Vector3.new(ridgeOrigin.X, 3000, ridgeOrigin.Z)) == "ridge",
		"3 km over Ridge is still Ridge"
	)
	local midX = (meadowOrigin.X + ridgeOrigin.X) / 2
	record(
		"Either side of the midpoint picks the field on that side",
		AirportService.nearestAirport(Vector3.new(midX - 200, 300, 200)) == "meadow"
			and AirportService.nearestAirport(Vector3.new(midX + 200, 300, 200)) == "ridge",
		string.format("midpoint x = %.0f", midX)
	)
	record(
		"Distance between the fields is symmetric and non-zero",
		math.abs((AirportService.distanceBetween("meadow", "ridge") :: number)
			- (AirportService.distanceBetween("ridge", "meadow") :: number)) < 1e-6
			and (AirportService.distanceBetween("meadow", "ridge") :: number) > 1000,
		string.format("%.0f m apart", AirportService.distanceBetween("meadow", "ridge") :: number)
	)
	record(
		"An unknown field has no distance rather than a wrong one",
		AirportService.distanceBetween("meadow", "nowhere") == nil,
		"nil"
	)

	--[[
		Parking generalised across the runway rather than along X. Meadow's
		layout must be BYTE-FOR-BYTE what it was - it is signed off - while
		Ridge's has to lie across a runway that runs the other way.
	]]
	local mSlot0 = AirportService.apronSlotCFrame("meadow", 0, 18)
	local mSlot1 = AirportService.apronSlotCFrame("meadow", 1, 18)
	record(
		"Meadow's parking is unchanged: 18 m apart along X, facing 36",
		math.abs(math.abs(mSlot1.Position.X - mSlot0.Position.X) - 18) < 1e-3
			and math.abs(mSlot1.Position.Z - mSlot0.Position.Z) < 1e-3
			and mSlot0.LookVector:Dot(r36.direction) > 0.999,
		string.format("(%.0f, %.0f) and (%.0f, %.0f)",
			mSlot0.Position.X, mSlot0.Position.Z, mSlot1.Position.X, mSlot1.Position.Z)
	)
	record(
		"Meadow's slot 0 is still on the apron",
		math.abs(mSlot0.Position.X - APRON_CENTRE.X) < 1e-3
			and math.abs(mSlot0.Position.Z - APRON_CENTRE.Z) < 1e-3,
		string.format("(%.1f, %.1f) against an apron at (%.0f, %.0f)",
			mSlot0.Position.X, mSlot0.Position.Z, APRON_CENTRE.X, APRON_CENTRE.Z)
	)

	local rSlot0 = AirportService.apronSlotCFrame("ridge", 0, 18)
	local rSlot1 = AirportService.apronSlotCFrame("ridge", 1, 18)
	record(
		"Ridge's parking spreads ACROSS its runway, not along X",
		math.abs(math.abs(rSlot1.Position.Z - rSlot0.Position.Z) - 18) < 1e-3
			and math.abs(rSlot1.Position.X - rSlot0.Position.X) < 1e-3,
		string.format("slots differ by %.1f m in Z and %.1f m in X",
			rSlot1.Position.Z - rSlot0.Position.Z, rSlot1.Position.X - rSlot0.Position.X)
	)
	record(
		"Ridge's parked aircraft face runway 09",
		rSlot0.LookVector:Dot((ridge09 :: any).direction) > 0.999,
		string.format("look %s", tostring(rSlot0.LookVector))
	)
	record(
		"Ridge's parking sits at Ridge's elevation",
		math.abs(rSlot0.Position.Y - AirportService.elevationOf("ridge")) < 1e-3,
		string.format("y = %.1f", rSlot0.Position.Y)
	)
	--[[
		And clear of the strip itself, or an aeroplane would spawn on the runway
		and the first thing anyone landing there would meet is a parked 172.
	]]
	local acrossStrip = math.abs((rSlot0.Position - Vector3.new(ridgeOrigin.X, rSlot0.Position.Y, ridgeOrigin.Z))
		:Dot((ridge09 :: any).direction:Cross(Vector3.yAxis)))
	record(
		"Ridge's parking is clear of the strip",
		acrossStrip > (ridge09 :: any).width / 2 + 11,
		string.format("%.0f m off the centreline, strip is %.0f m wide", acrossStrip, (ridge09 :: any).width)
	)

	-- 2d. Navigation between airports -----------------------------------------
	--[[
		THE bearing check, and it is the one that matters most: a bearing this
		module publishes is a number the pilot flies by reading the DI. If the
		two conventions disagree the plan is wrong in a way that only shows up
		in the air, so headingOf() is round-tripped against directionFor() at
		every cardinal and against FlightModel's own formula.
	]]
	local roundTrip = {}
	for _, h in { 90, 180, 270, 360, 45, 123.4 } do
		local back = AirportService.headingOf(AirportService.directionFor(h))
		if math.abs(back - h) > 1e-4 then
			table.insert(roundTrip, string.format("%.1f -> %.4f", h, back))
		end
	end
	record(
		"headingOf and directionFor are exact inverses",
		#roundTrip == 0,
		if #roundTrip == 0 then "90, 180, 270, 360, 45 and 123.4 all round-trip" else table.concat(roundTrip, ", ")
	)
	record(
		"North reads 360, not 0, matching how runways are designated",
		AirportService.headingOf(Vector3.new(0, 0, -1)) == 360,
		"runway 36, not runway 0"
	)
	--[[
		Agreement with FlightModel, which computes heading as
		atan2(look.X, -look.Z). Written out here rather than imported because
		this module must not depend on the physics - but the two MUST match, so
		the formula is duplicated deliberately and checked.
	]]
	local fmMismatch = {}
	for _, h in { 30, 97.125, 200, 359 } do
		local d = AirportService.directionFor(h)
		local fm = math.deg(math.atan2(d.X, -d.Z)) % 360
		if math.abs(fm - (h % 360)) > 1e-3 then
			table.insert(fmMismatch, string.format("%.3f vs %.3f", fm, h % 360))
		end
	end
	record(
		"Bearings agree with the heading the DI will show",
		#fmMismatch == 0,
		if #fmMismatch == 0 then "FlightModel's atan2(x, -z) matches at every angle tried" else table.concat(fmMismatch, ", ")
	)

	local plan = AirportService.flightPlan("meadow", "ridge") :: any
	record("A flight plan exists between the two fields", plan ~= nil, plan and string.format("%s -> %s", plan.fromName, plan.toName) or "nil")
	record(
		"There is no plan from a field to itself, or to nowhere",
		AirportService.flightPlan("meadow", "meadow") == nil
			and AirportService.flightPlan("meadow", "nowhere") == nil,
		"nil for both"
	)
	record(
		"The plan's distance agrees with distanceBetween",
		math.abs(plan.distance - (AirportService.distanceBetween("meadow", "ridge") :: number)) < 1e-6,
		string.format("%.0f m", plan.distance)
	)
	--[[
		Flying the published bearing must actually get you there. Asserted as a
		dot product against the true course rather than by comparing two angles,
		because that catches a 180 degree error which a modulo comparison can
		hide.
	]]
	local courseUnit = Vector3.new(
		(AirportService.getAirport("ridge") :: any).origin.X - (AirportService.getAirport("meadow") :: any).origin.X,
		0,
		(AirportService.getAirport("ridge") :: any).origin.Z - (AirportService.getAirport("meadow") :: any).origin.Z
	).Unit
	record(
		"Flying the published bearing tracks toward the destination",
		AirportService.directionFor(plan.bearing):Dot(courseUnit) > 0.9999,
		string.format("bearing %.1f", plan.bearing)
	)
	record(
		"The reciprocal is the way home",
		math.abs(((plan.reciprocal - plan.bearing) % 360) - 180) < 1e-3,
		string.format("%.1f out, %.1f back", plan.bearing, plan.reciprocal)
	)
	local back = AirportService.flightPlan("ridge", "meadow") :: any
	record(
		"The return plan is the mirror of the outbound one",
		math.abs(back.distance - plan.distance) < 1e-6
			and math.abs(back.bearing - plan.reciprocal) < 1e-3
			and math.abs(back.climb + plan.climb) < 1e-6,
		string.format("%.0f m, bearing %.1f, climb %+.0f m", back.distance, back.bearing, back.climb)
	)

	--[[
		The climb is the thing a short leg between two fields 150 m apart in
		height is actually about, and the cruise must clear the HIGHER field by
		a circuit height - not the departure field, which would arrive below the
		destination.
	]]
	record(
		"The plan carries the climb between the two fields",
		math.abs(plan.climb - (AirportService.elevationOf("ridge") - AirportService.elevationOf("meadow"))) < 1e-6,
		string.format("%+.0f m", plan.climb)
	)
	record(
		"Cruise clears the higher field by a circuit height",
		plan.cruiseAltitude >= math.max(plan.departureElevation, plan.arrivalElevation) + PATTERN_ALTITUDE - 1e-6,
		string.format("%.0f m against fields at %.0f and %.0f", plan.cruiseAltitude, plan.departureElevation, plan.arrivalElevation)
	)

	--[[
		The runway to expect at the far end, derived from the course rather than
		declared. Ridge runs 09/27 east-west and the course is easterly, so 09
		is the one that lines up - and this is the check that would fail if
		bestRunwayFor picked the reciprocal.
	]]
	record(
		"The arrival runway is the one aligned with the inbound course",
		plan.arrivalRunway == "09",
		string.format("arrive %s at Ridge on a %.0f bearing", plan.arrivalRunway, plan.bearing)
	)
	record(
		"...and the return arrives at Meadow on the reciprocal-aligned runway",
		back.arrivalRunway == "18" or back.arrivalRunway == "36",
		string.format("arrive %s at Meadow", back.arrivalRunway)
	)

	--[[
		The plan HANDS OFF to navPoints rather than duplicating the circuit, so
		its entry point must literally be the arrival runway's own downwind. If
		these ever differ, there are two copies of the circuit and they will
		drift.
	]]
	local arrivalNav = AirportService.navPoints("ridge", plan.arrivalRunway) :: { [string]: Vector3 }
	record(
		"The plan hands off to the arrival field's own circuit",
		(plan.CircuitEntry - arrivalNav.Downwind).Magnitude < 1e-6
			and (plan.Destination - arrivalNav.Threshold).Magnitude < 1e-6,
		"CircuitEntry is navPoints' Downwind, not a second copy"
	)
	--[[
		And the waypoints must be near the fields they belong to - the same
		question the circuit check above asks, applied to the route.
	]]
	record(
		"The plan's waypoints are at the right ends of the route",
		(Vector3.new(plan.Departure.X, 0, plan.Departure.Z)
			- Vector3.new((AirportService.getAirport("meadow") :: any).origin.X, 0, (AirportService.getAirport("meadow") :: any).origin.Z)).Magnitude < 1500
			and (Vector3.new(plan.Destination.X, 0, plan.Destination.Z)
			- Vector3.new((AirportService.getAirport("ridge") :: any).origin.X, 0, (AirportService.getAirport("ridge") :: any).origin.Z)).Magnitude < 1500,
		"departure near Meadow, destination near Ridge"
	)
	record(
		"Top of climb is at cruise and on the way",
		math.abs(plan.TopOfClimb.Y - plan.cruiseAltitude) < 1e-6
			and Vector3.new(plan.TopOfClimb.X - plan.Departure.X, 0, plan.TopOfClimb.Z - plan.Departure.Z):Dot(courseUnit) > 0,
		string.format("y = %.0f, ahead of the departure end", plan.TopOfClimb.Y)
	)

	local nav = AirportService.navPoints("meadow", "36") :: { [string]: Vector3 }
	record("Navigation points exist for runway 36", nav ~= nil, "returned a table")
	record("Navigation points are nil for an unknown runway", AirportService.navPoints("meadow", "09") == nil, "nil")

	-- The aiming point must be ON the runway, past the threshold, before the end.
	local aimDistance = (nav.AimingPoint - r36.threshold).Magnitude
	checkRange("Aiming point sits 300 m along the runway", aimDistance, 299, 301, "m")
	record(
		"Aiming point is between the threshold and the far end",
		aimDistance < r36.length and (nav.AimingPoint - r36.threshold):Dot(r36.direction) > 0,
		string.format("%.0f m in, on the runway side", aimDistance)
	)
	record(
		"Aiming point is on the runway surface, not floating",
		math.abs(nav.AimingPoint.Y - SURFACE_Y) < 1e-6,
		string.format("y = %.3f", nav.AimingPoint.Y)
	)

	--[[
		THE circuit check. A left-hand circuit must put the pattern on the LEFT
		of the departure heading. Departing north (-Z), left is west (-X), so
		every airborne point must have a negative X. Getting the cross-product
		order backwards produces a right-hand circuit that looks entirely
		plausible until somebody flies it.
	]]
	record(
		"Runway 36's left circuit is on the west side",
		nav.Downwind.X < -100 and nav.Base.X < -100 and nav.Crosswind.X < 0,
		string.format("downwind X %.0f, base X %.0f", nav.Downwind.X, nav.Base.X)
	)

	local nav18 = AirportService.navPoints("meadow", "18") :: { [string]: Vector3 }
	record(
		"Runway 18's left circuit is on the east side, being the reciprocal",
		nav18.Downwind.X > 100 and nav18.Base.X > 100,
		string.format("downwind X %.0f, base X %.0f", nav18.Downwind.X, nav18.Base.X)
	)

	checkRange("Downwind is about half a mile out", math.abs(nav.Downwind.X), 700, 1200, "m")
	--[[
		ABOVE THE FIELD, not above sea level, and this assertion had it wrong.

		It read `nav.Downwind.Y` directly and expected ~305 m, which passed only
		because Downwind was the one circuit point with no airport anchor - so
		its Y was the pattern altitude by accident rather than an altitude at
		all. With the anchor fixed, Meadow's downwind is at 555 m: 250 m of
		field plus 305 m of circuit, which is what a 1,000 ft pattern means.
	]]
	checkRange(
		"Pattern altitude is a standard 1000 ft above the field",
		nav.Downwind.Y - AirportService.elevationOf("meadow"),
		290,
		320,
		"m AGL"
	)
	record(
		"Ground points are on the ground and airborne points are not",
		nav.Threshold.Y == SURFACE_Y and nav.DepartureEnd.Y == SURFACE_Y
			and nav.Downwind.Y > 100 and nav.Final.Y > 50,
		string.format("threshold y %.1f, downwind y %.0f, final y %.0f", nav.Threshold.Y, nav.Downwind.Y, nav.Final.Y)
	)

	-- Final must be lined up on the extended centreline, short of the threshold.
	record(
		"Final is on the extended centreline, before the threshold",
		math.abs(nav.Final.X) < 1e-6 and (nav.Final - r36.threshold):Dot(r36.direction) < 0,
		string.format("X %.2f, %.0f m short", nav.Final.X, (nav.Final - r36.threshold).Magnitude)
	)

	-- The whole circuit has to fit on the field, or the pilot flies off the edge.
	local half = FIELD_SIZE / 2
	local inside = true
	for _, point in nav do
		if math.abs(point.X) > half or math.abs(point.Z) > half then
			inside = false
		end
	end
	record("The entire circuit fits inside the field", inside, string.format("field is %d m square", FIELD_SIZE))

	-- 4. Apron slots ---------------------------------------------------------
	local SPACING = 18
	local slots = {}
	for i = 0, 6 do
		slots[i] = AirportService.apronSlotCFrame("meadow", i, SPACING)
	end

	--[[
		THE safety check on parking: no aircraft may be spawned on the runway.
		A 1,111 kg aeroplane appearing on the centreline in front of somebody on
		short final is the worst thing this service could do.
	]]
	local clearOfRunway = true
	local nearestX = math.huge
	for _, cf in slots do
		nearestX = math.min(nearestX, math.abs(cf.Position.X))
		if math.abs(cf.Position.X) < r36.width / 2 + 11 then
			clearOfRunway = false
		end
	end
	record(
		"No spawn slot is on or beside the runway",
		clearOfRunway,
		string.format("nearest slot is %.0f m off the centreline (runway is %.1f m wide)", nearestX, r36.width)
	)

	-- Nor on the taxiway, which would block everyone else.
	local clearOfTaxiway = true
	for _, cf in slots do
		if math.abs(cf.Position.X - TAXIWAY_X) < TAXIWAY_WIDTH / 2 + 6 then
			clearOfTaxiway = false
		end
	end
	record("No spawn slot blocks the taxiway", clearOfTaxiway, "all slots clear of taxiway Alpha")

	-- Slots must not overlap each other: the 172's span is 11 m.
	local minGap = math.huge
	for i = 0, 6 do
		for j = i + 1, 6 do
			minGap = math.min(minGap, (slots[i].Position - slots[j].Position).Magnitude)
		end
	end
	record(
		"Parked aircraft cannot overlap",
		minGap >= 11,
		string.format("closest two slots are %.0f m apart, span is 11 m", minGap)
	)

	-- And they must actually be on the apron.
	local onApron = true
	for _, cf in slots do
		local dx = math.abs(cf.Position.X - APRON_CENTRE.X)
		local dz = math.abs(cf.Position.Z - APRON_CENTRE.Z)
		if dx > APRON_SIZE_X / 2 - 5 or dz > APRON_SIZE_Z / 2 - 4 then
			onApron = false
		end
	end
	record("Every slot is on the apron, clear of its edge", onApron, "7 slots inside the apron")

	record(
		"Slots sit on the surface, so spawn height stays the aircraft's business",
		math.abs(slots[0].Position.Y - SURFACE_Y) < 1e-3,
		string.format("y = %.3f", slots[0].Position.Y)
	)

	--[[
		A parked aeroplane must already be pointing at the runway it departs
		from. A default CFrame looks down -Z, which is north, which is 36.
	]]
	record(
		"Parked aircraft face runway 36",
		slots[0].LookVector:Dot(r36.direction) > 0.99,
		string.format("look %s vs runway %s", tostring(slots[0].LookVector), tostring(r36.direction))
	)

	-- 5. The built world -----------------------------------------------------
	folder = AirportService.build(Workspace)
	local f = folder :: Folder

	local runwayPart = f:FindFirstChild("Runway") :: Part
	record("The runway exists in the world", runwayPart ~= nil, runwayPart and "Workspace.Airport.Runway" or "missing")

	--[[
		THE dimension check that ties the registry to the geometry. If the part
		and the data disagree, every navigation point is subtly wrong and nothing
		would report it.
	]]
	record(
		"The runway part matches the registry dimensions",
		math.abs(runwayPart.Size.Z - r36.length) < 1e-3 and math.abs(runwayPart.Size.X - r36.width) < 1e-3,
		string.format("%.0f x %.0f m part vs %d x %d m registered", runwayPart.Size.Z, runwayPart.Size.X, r36.length, r36.width)
	)

	--[[
		A MILLIMETRE, not 1e-9, and the tolerance is the thing that changed.

		Roblox stores part positions as float32. At y = 0 that resolved far
		finer than 1e-9 and the old assertion passed; at y = 250 the spacing
		between representable values is about 1.5e-5, so `Position.Y + Size.Y/2`
		lands on 250.000003 and a nanometre tolerance demands more precision
		than the engine has. The code was right and the assertion was wrong -
		which is now a familiar sentence in this project.

		A millimetre is still three orders of magnitude tighter than anything
		that could matter to a wheel.
	]]
	local topY = runwayPart.Position.Y + runwayPart.Size.Y / 2
	record(
		"The runway top face is exactly the declared surface",
		math.abs(topY - SURFACE_Y) < 1e-3,
		string.format("top face at y = %.6f, SURFACE_Y %.2f", topY, SURFACE_Y)
	)
	record("The runway is collidable, so wheels roll on it", runwayPart.CanCollide, "CanCollide = true")

	-- 5b. Ridge Strip, in the world ------------------------------------------
	local strip = f:FindFirstChild("RidgeStrip") :: Part?
	record("Ridge Strip exists in the world", strip ~= nil, strip and "Workspace.Airport.RidgeStrip" or "missing")
	if strip then
		local ridgeR = AirportService.getRunway("ridge", "09") :: any
		record(
			"The strip part matches Ridge's registered dimensions",
			math.abs((strip :: Part).Size.Z - ridgeR.length) < 1e-3
				and math.abs((strip :: Part).Size.X - ridgeR.width) < 1e-3,
			string.format("%.0f x %.0f m", (strip :: Part).Size.Z, (strip :: Part).Size.X)
		)
		--[[
			Built from direction vectors, so the part must actually LIE along
			its runway. A builder that assumed one orientation would put a
			550 m strip across the field instead of down it, and the size check
			above would still pass.
		]]
		record(
			"The strip is laid along its runway, not across it",
			(strip :: Part).CFrame.LookVector:Dot(ridgeR.direction) > 0.999,
			string.format("look %s vs runway %s",
				tostring((strip :: Part).CFrame.LookVector), tostring(ridgeR.direction))
		)
		local stripTop = (strip :: Part).Position.Y + (strip :: Part).Size.Y / 2
		record(
			"The strip's top face is Ridge's declared elevation",
			math.abs(stripTop - AirportService.elevationOf("ridge")) < 1e-3,
			string.format("y = %.3f against %.0f m", stripTop, AirportService.elevationOf("ridge"))
		)
		record(
			"The strip stands proud of the terrain around it",
			stripTop > AirportService.grassOf("ridge"),
			string.format("%.3f m against grass at %.2f m", stripTop, AirportService.grassOf("ridge"))
		)
		--[[
			§11 is explicit that vertical objects at known spacing are the depth
			cue. A grass strip needs them more than a paved runway does, not
			less, because it has no painted centreline to judge against.
		]]
		local edges, bars = 0, 0
		for _, c in f:GetChildren() do
			if string.find(c.Name, "RidgeEdge") then edges += 1 end
			if string.find(c.Name, "RidgeThreshold") then bars += 1 end
		end
		record(
			"The strip has edge markers as a depth cue",
			edges >= 12 and bars == 4,
			string.format("%d edge markers, %d threshold bars (2 per end)", edges, bars)
		)
		--[[
			And Meadow is untouched. Its runway is measured and signed off, so
			the second aerodrome must not have moved it by a millimetre.
		]]
		record(
			"Meadow's runway is exactly where it always was",
			math.abs(runwayPart.Position.X) < 1e-6 and math.abs(runwayPart.Position.Z) < 1e-6
				and math.abs(topY - SURFACE_Y) < 1e-3,
			string.format("(%.3f, %.3f), top y = %.3f", runwayPart.Position.X, runwayPart.Position.Z, topY)
		)
	end

	local taxiway = f:FindFirstChild("TaxiwayAlpha") :: Part
	local apron = f:FindFirstChild("Apron") :: Part
	record("Taxiway and apron exist", taxiway ~= nil and apron ~= nil, "TaxiwayAlpha + Apron")
	record(
		"Taxiway and apron share the runway's surface plane",
		math.abs((taxiway.Position.Y + taxiway.Size.Y / 2) - SURFACE_Y) < 1e-3
			and math.abs((apron.Position.Y + apron.Size.Y / 2) - SURFACE_Y) < 1e-3,
		string.format("all three top faces at y = %.2f", SURFACE_Y)
	)

	--[[
		Paint must never be collidable or queryable. A 2 cm lip under the
		nosewheel at 60 kt is a bump felt on every centreline dash, and paint
		answering a ground raycast would put the ground 2 cm high wherever there
		happened to be a stripe.
	]]
	local paintSolid, paintQueryable, paintCount = 0, 0, 0
	for _, part in f:GetChildren() do
		if part:IsA("BasePart") and (string.find(part.Name, "Centreline") or string.find(part.Name, "Threshold")
			or string.find(part.Name, "AimingPoint") or string.find(part.Name, "Digit")
			or string.find(part.Name, "EdgeLine") or string.find(part.Name, "HoldShort")) then
			paintCount += 1
			if part.CanCollide then paintSolid += 1 end
			if part.CanQuery then paintQueryable += 1 end
		end
	end
	record(
		"No marking is collidable or queryable",
		paintSolid == 0 and paintQueryable == 0 and paintCount > 20,
		string.format("%d markings, %d solid, %d queryable", paintCount, paintSolid, paintQueryable)
	)

	-- The centreline has to actually be a ruler, not one long stripe.
	local dashes = 0
	for _, part in f:GetChildren() do
		if part:IsA("BasePart") and string.find(part.Name, "Centreline_") then
			dashes += 1
		end
	end
	record(
		"The centreline is dashed, giving a closure-rate cue",
		dashes >= 12,
		string.format("%d dashes over %d m", dashes, RUNWAY_LENGTH)
	)

	-- And the depth cue must exist, on both sides.
	local markers = 0
	for _, part in f:GetChildren() do
		if part:IsA("BasePart") and string.find(part.Name, "EdgeMarker_") then
			markers += 1
		end
	end
	record(
		"Runway edge markers give the flare a height reference",
		markers >= 30,
		string.format("%d markers, both sides, every 60 m", markers)
	)

	-- 6. Ground height -------------------------------------------------------
	--[[
		The point of this section, and the reason §10's note is now closed: the
		raycast is the source of truth, and it must agree with the constants
		everything else was built against.
	]]
	local function heightText(y: number?): string
		return if y then string.format("%.4f m", y) else "no ground found"
	end

	--[[
		Every probe below starts from SURFACE_Y + something, not from a literal
		height. That is the whole point of this task: a ray that starts at y = 50
		is now 200 m UNDERGROUND, and would have reported the runway missing.
	]]
	local overRunway = AirportService.groundHeightAt(Vector3.new(0, SURFACE_Y + 50, 0))
	record(
		"Ground height over the runway is the declared surface",
		overRunway ~= nil and math.abs((overRunway :: number) - SURFACE_Y) < 1e-3,
		heightText(overRunway)
	)

	--[[
		THE obstruction sweep, and it earned its place immediately.

		The first run of this suite reported the ground over the runway at y =
		1.00 rather than 0. The cause was Workspace.SpawnLocation - a 12 x 12 m
		pad whose top face is at y = 1.00 (§6e), sitting on the world origin,
		which the runway now runs straight through. A one-metre ledge in the
		middle of the takeoff roll.

		It is now on the apron and Rojo-managed, but the general failure is what
		matters: anything dropped into Workspace near the origin lands on the
		runway, and nothing else would report it. So the whole usable length is
		swept rather than one point.
	]]
	local obstructed = {}
	for z = -RUNWAY_HALF + 20, RUNWAY_HALF - 20, 50 do
		local y = AirportService.groundHeightAt(Vector3.new(0, SURFACE_Y + 60, z))
		if y == nil or math.abs(y - SURFACE_Y) > 0.02 then
			table.insert(obstructed, string.format("z=%.0f y=%s", z, if y then string.format("%.2f", y) else "none"))
		end
	end
	record(
		"The whole runway is clear - nothing sitting on it",
		#obstructed == 0,
		if #obstructed == 0
			then string.format("%d points swept, all at y = %.0f", math.floor((RUNWAY_LENGTH - 40) / 50) + 1, SURFACE_Y)
			else table.concat(obstructed, ", ")
	)

	-- The same for the taxiway and the apron, which are equally easy to block.
	local blockedTaxi = 0
	for z = -TAXIWAY_HALF_LENGTH + 20, TAXIWAY_HALF_LENGTH - 20, 60 do
		local y = AirportService.groundHeightAt(Vector3.new(TAXIWAY_X, SURFACE_Y + 60, z))
		if y == nil or math.abs(y - SURFACE_Y) > 0.02 then
			blockedTaxi += 1
		end
	end
	record("The taxiway is clear along its length", blockedTaxi == 0, string.format("%d obstructed points", blockedTaxi))

	local overApron = AirportService.groundHeightAt(Vector3.new(APRON_CENTRE.X, SURFACE_Y + 50, APRON_CENTRE.Z))
	record(
		"Ground height over the apron agrees with the runway",
		overApron ~= nil and math.abs((overApron :: number) - SURFACE_Y) < 1e-3,
		heightText(overApron)
	)

	--[[
		The grass beside the runway is TERRAIN now, not a part, so it is checked
		to a centimetre rather than to a micron: a terrain isosurface carries
		about 16 mm of ripple (measured in TerrainService), which a 1e-3
		tolerance would fail on correct ground.

		Sampled at x = 200, which is off every piece of pavement but still well
		inside the flat pad - out at x = 600 the terrain is deliberately no
		longer level, and asserting GRASS_Y there would be asserting that the
		world has no relief.
	]]
	local overGrass = AirportService.groundHeightAt(Vector3.new(200, SURFACE_Y + 50, 0))
	record(
		"Ground height beside the runway is the 5 cm step below",
		overGrass ~= nil and math.abs((overGrass :: number) - GRASS_Y) < 0.05,
		string.format("%s against a %.2f m grass plane", heightText(overGrass), GRASS_Y)
	)

	record(
		"The grass is BELOW the pavement, so the two cannot z-fight",
		GRASS_Y < SURFACE_Y,
		string.format("grass %.2f m, pavement %.2f m", GRASS_Y, SURFACE_Y)
	)

	--[[
		THE FIELD IS TERRAIN NOW, not the baseplate part.

		These two checks used to assert the baseplate's size and top face. The
		baseplate is retired at run time by TerrainService, so what matters is
		the same property expressed against the ground that actually exists: the
		circuit must have ground under all of it, or the pilot flies the
		downwind leg over open space.

		The circuit's own extents are already asserted further up; this walks the
		four corners of it and demands ground beneath each.
	]]
	local nav = AirportService.navPoints("meadow", "36")
	local circuitCorners = {
		{ (nav :: any).Downwind.X, (nav :: any).Downwind.Z },
		{ (nav :: any).Base.X, (nav :: any).Base.Z },
		{ (nav :: any).Upwind.X, (nav :: any).Upwind.Z },
		{ (nav :: any).Final.X, (nav :: any).Final.Z },
	}
	local groundless = {}
	for _, c in circuitCorners do
		local y = AirportService.groundHeightAt(Vector3.new(c[1], SURFACE_Y + 400, c[2]), 900)
		if y == nil then
			table.insert(groundless, string.format("(%.0f, %.0f)", c[1], c[2]))
		end
	end
	record(
		"There is ground under the whole circuit",
		#groundless == 0,
		if #groundless == 0
			then "all four circuit corners have ground beneath them"
			else "no ground at " .. table.concat(groundless, ", ")
	)
	record(
		"The baseplate has been retired in favour of terrain",
		Workspace:FindFirstChild("Baseplate") == nil,
		"TerrainService removes it at run time; Rojo still owns it for the edit view"
	)

	-- Off the edge of the world there is genuinely no ground.
	record(
		"No ground beyond the field returns nil rather than a number",
		AirportService.groundHeightAt(Vector3.new(FIELD_SIZE, 50, FIELD_SIZE)) == nil,
		"nil past the field edge"
	)

	-- 7. Rebuild is idempotent ------------------------------------------------
	AirportService.build(Workspace)
	local airports = 0
	for _, child in Workspace:GetChildren() do
		if child.Name == AirportService.CONTAINER_NAME then
			airports += 1
		end
	end
	record("Building twice leaves one airport, not two", airports == 1, string.format("%d Airport folder(s)", airports))
	folder = AirportService.getBuilt()

	end

	local ok, err = pcall(body)

	if not ok then
		allPassed = false
		record("Suite completed without erroring", false, tostring(err))
	end

	local passCount = 0
	for _, r in results do
		if r.passed then
			passCount += 1
		end
	end
	print(string.format("=== %s (%d/%d) ===", allPassed and "ALL PASSED" or "FAILURES PRESENT", passCount, #results))

	return allPassed, results
end

return AirportService
