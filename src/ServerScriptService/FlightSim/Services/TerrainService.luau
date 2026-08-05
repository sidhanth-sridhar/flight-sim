--!strict
--[[
	TerrainService
	--------------
	The ground. Real Roblox Terrain, replacing the 2,048 m baseplate part that
	stood in for a world through Phases 1 and 2.

	WHY THIS EXISTS, AND WHAT IT HAD TO MEASURE FIRST
	-------------------------------------------------
	The handoff (section 14) named this the largest known trap in Phase 3:
	AirportService assumed its pavement sat at y = 0, and terrain breaks that,
	because the ground is then wherever the terrain says it is. Nothing here was
	written until the engine had been measured, and the measurements decided the
	whole design:

	  1. A terrain surface sits exactly HALF A VOXEL above the top of the block
	     you fill. Requested 0, 1, 2, 3, ... 12 and measured 2.000, 3.016,
	     4.016, 5.000 ... 14.000 - a constant +2.000 with a 16 mm ripple.
	  2. A UNIFORM fill is perfectly flat. Over a runway-sized 1,000 x 22 m
	     footprint, 123 samples came back min 102.0000, max 102.0000:
	     zero peak-to-peak. Terrain can carry an airport.
	  3. A SLOPED fill is not exact. Six-metre steps over 20 m came back with up
	     to 1.23 m of deviation, because the isosurface smooths them. Terrain is
	     scenery, not survey.
	  4. A part resting on terrain wins the ground probe, as it must for the
	     pavement to be the surface the aircraft touches.
	  5. Terrain writes are NOT queryable in the same frame. The first sweep
	     found nothing at all until a yield was added.

	(3) is why the runway is still PARTS on a terrain pad rather than terrain
	itself - a metre of error on a runway is not a runway, and the markings in
	section 11 are load-bearing and cannot be painted onto voxels. (2) is why a
	pad works at all.

	WHO DECIDES THE ELEVATION
	-------------------------
	AirportService does, and this module builds ground to match it. The arrow
	points that way round deliberately: the airport's geometry is a declared
	constant available before anything initialises (section 11's load-order
	fix), so making terrain the authority would have reintroduced exactly the
	race that fix removed. Terrain is fitted to the airport, not the other way
	about.
]]

local Workspace = game:GetService("Workspace")

local AirportService = require(script.Parent:WaitForChild("AirportService"))

local TerrainService = {}

-- =========================================================================
-- THE ENGINE'S NUMBERS
-- =========================================================================

--[[
	Roblox's terrain voxel is 4 studs, and at 1 stud = 1 m that is a 4 m grid.

	SURFACE_OFFSET is half of it, and is not a fudge factor: a fully occupied
	voxel presents its surface at the voxel's outer face, so the isosurface
	lands half a voxel above the top of what you asked to fill. Measured across
	ten heights and constant to within 16 mm.

	It is derived from VOXEL rather than typed as "2" so that the relationship
	is visible, and runTests() measures it live - if Roblox ever changes the
	grid, a test fails loudly instead of the runway quietly floating.
]]
local VOXEL = 4
local SURFACE_OFFSET = VOXEL / 2

-- =========================================================================
-- LAYOUT
-- =========================================================================

-- The same 2,048 m square the baseplate covered, so the circuit in section 11
-- still fits inside the world with the same margins it was checked against.
local FIELD_SIZE = 2048
local FIELD_HALF = FIELD_SIZE / 2

--[[
	The flat pad, sized to contain the whole airport with room to overrun.

	The airport spans roughly x -240..20 and z -520..400 (runway, taxiway
	Alpha, apron). This is generous on every side, because an aircraft that
	lands long or drifts off the side must not meet a hill.
]]
local PAD_CENTRE_X = -110
local PAD_CENTRE_Z = -50
local PAD_SIZE_X = 900
local PAD_SIZE_Z = 1700

-- Where the relief reaches full height, measured outward from the pad edge. A
-- hard edge would put a cliff on the approach; this ramps it in.
local BLEND_DISTANCE = 400

--[[
	Relief amplitude. Deliberately gentle - this is a training field, and the
	circuit is flown at 305 m above the surface, so hills that could reach the
	downwind leg would be a hazard rather than scenery.
]]
local RELIEF_AMPLITUDE = 18

-- Terrain is filled as columns. 64 m trades a visible step against the number
-- of FillBlock calls: the field is 32 x 32 = 1,024 of them at this size.
local BLOCK = 64

-- How deep the ground goes. Only the surface is ever seen or raycast, so this
-- only has to be thicker than the deepest relief plus a margin.
local DEPTH = 120

local GROUND_MATERIAL = Enum.Material.Grass

-- =========================================================================
-- THE HEIGHT FIELD
-- =========================================================================

--[[
	Pure: the terrain's intended SURFACE height at a world point.

	Flat over the pad, ramping out to gentle relief beyond it. Exported so the
	tests can assert the shape of the world without building any of it - the
	same data-before-geometry split AirportService uses.
]]
function TerrainService.surfaceHeightFor(x: number, z: number): number
	local base = AirportService.GRASS_Y

	-- Distance outside the pad, per axis, in metres. Zero anywhere on the pad.
	local outX = math.max(0, math.abs(x - PAD_CENTRE_X) - PAD_SIZE_X / 2)
	local outZ = math.max(0, math.abs(z - PAD_CENTRE_Z) - PAD_SIZE_Z / 2)
	local outside = math.sqrt(outX * outX + outZ * outZ)

	if outside <= 0 then
		return base
	end

	local blend = math.min(1, outside / BLEND_DISTANCE)
	-- Smoothstep, so the pad edge has no crease in it.
	blend = blend * blend * (3 - 2 * blend)

	--[[
		Two sine waves at different wavelengths and angles. Not noise: it is
		reproducible, it is cheap, and it is inspectable - a test can assert the
		amplitude never exceeds what was declared, which is the property that
		actually matters near an aerodrome.
	]]
	local h = math.sin(x / 260) * math.cos(z / 310) * 0.65
		+ math.sin((x + z) / 170) * 0.35

	return base + h * RELIEF_AMPLITUDE * blend
end

-- Pure: the fill top to request for a desired surface height. See SURFACE_OFFSET.
function TerrainService.fillTopFor(surfaceY: number): number
	return surfaceY - SURFACE_OFFSET
end

TerrainService.VOXEL = VOXEL
TerrainService.SURFACE_OFFSET = SURFACE_OFFSET
TerrainService.FIELD_SIZE = FIELD_SIZE
TerrainService.RELIEF_AMPLITUDE = RELIEF_AMPLITUDE

function TerrainService.padBounds(): (number, number, number, number)
	return PAD_CENTRE_X - PAD_SIZE_X / 2,
		PAD_CENTRE_X + PAD_SIZE_X / 2,
		PAD_CENTRE_Z - PAD_SIZE_Z / 2,
		PAD_CENTRE_Z + PAD_SIZE_Z / 2
end

-- =========================================================================
-- MEASURING THE WORLD
-- =========================================================================

local probeParams = RaycastParams.new()
probeParams.FilterType = Enum.RaycastFilterType.Exclude
probeParams.FilterDescendantsInstances = {}
probeParams.IgnoreWater = false

--[[
	The ground height actually present at a point, terrain or part, or nil if
	there is nothing there.

	This is a MEASUREMENT and not a calculation, which is the point of it:
	surfaceHeightFor says what was asked for, this says what the engine
	produced, and the tests compare the two. Everything in Phase 1 and 2 that
	needed ground height already raycasts - FlightModel's ground-effect probe
	and GroundHandling's wheel probes both filter only the aircraft, so both
	were already finding terrain the moment it existed and needed no change.
]]
function TerrainService.surfaceAt(x: number, z: number, from: number?): number?
	local start = from or (AirportService.SURFACE_Y + 400)
	local hit = Workspace:Raycast(Vector3.new(x, start, z), Vector3.new(0, -(start + 1000), 0), probeParams)
	return if hit then hit.Position.Y else nil
end

-- Terrain-only, ignoring any pavement laid over it.
function TerrainService.terrainHeightAt(x: number, z: number): number?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { Workspace.Terrain }
	local start = AirportService.SURFACE_Y + 400
	local hit = Workspace:Raycast(Vector3.new(x, start, z), Vector3.new(0, -(start + 1000), 0), params)
	return if hit then hit.Position.Y else nil
end

-- =========================================================================
-- BUILD
-- =========================================================================

--[[
	Retire the baseplate.

	It is Rojo-managed and stays in the project file on purpose: without it the
	Studio EDIT view would have no ground at all, which section 11 already
	called out when the airport moved into code. So it is removed at RUN time
	only, exactly as the airport is built at run time - the edit view keeps its
	floor and the running game gets terrain.
]]
local function retireBaseplate(): boolean
	local baseplate = Workspace:FindFirstChild("Baseplate")
	if baseplate and baseplate:IsA("BasePart") then
		baseplate:Destroy()
		return true
	end
	return false
end

function TerrainService.build(): number
	retireBaseplate()

	local terrain = Workspace.Terrain
	terrain:Clear()

	local filled = 0
	local half = BLOCK / 2

	for cx = -FIELD_HALF + half, FIELD_HALF - half, BLOCK do
		for cz = -FIELD_HALF + half, FIELD_HALF - half, BLOCK do
			local surface = TerrainService.surfaceHeightFor(cx, cz)
			local top = TerrainService.fillTopFor(surface)

			terrain:FillBlock(
				CFrame.new(cx, top - DEPTH / 2, cz),
				Vector3.new(BLOCK, DEPTH, BLOCK),
				GROUND_MATERIAL
			)
			filled += 1
		end
	end

	--[[
		Terrain writes are not queryable in the same frame - measured, and it
		cost a sweep that found nothing at all before the yield was added. Any
		caller that builds and then immediately asks for a ground height gets
		nil without this.
	]]
	task.wait()

	return filled
end

local initialised = false

function TerrainService.Init()
	if initialised then
		return
	end
	initialised = true

	local blocks = TerrainService.build()
	print(string.format(
		"[FlightSim:Terrain] Ground built: %d blocks, field %d m, airport pad at y = %.2f",
		blocks, FIELD_SIZE, AirportService.GRASS_Y
	))
end

-- =========================================================================
-- VERIFICATION
-- =========================================================================

--[[
	Run from the Studio command bar, SERVER datamodel:
		require(game.ServerScriptService.FlightSim.Services.TerrainService).runTests()

	This suite BUILDS TERRAIN, which takes a moment and replaces whatever was
	there. That is unavoidable: every claim worth making here is about what the
	engine actually produced, and the height field on its own proves nothing.
]]
function TerrainService.runTests(): (boolean, { any })
	local results = {}
	local allPassed = true

	local function record(label: string, passed: boolean, detail: string)
		if not passed then
			allPassed = false
		end
		table.insert(results, { label = label, passed = passed, detail = detail })
		print(string.format("  [%s] %-56s %s", passed and "PASS" or "FAIL", label, detail))
	end

	print("=== TerrainService: verification ===")

	-- 1. The height field, before anything is built ---------------------------
	local padMinX, padMaxX, padMinZ, padMaxZ = TerrainService.padBounds()

	record(
		"The pad contains the whole runway",
		padMinZ <= -520 and padMaxZ >= 520 and padMinX <= -20 and padMaxX >= 20,
		string.format("pad x %.0f..%.0f, z %.0f..%.0f", padMinX, padMaxX, padMinZ, padMaxZ)
	)
	record(
		"The pad contains the apron and taxiway",
		padMinX <= -245 and padMaxX >= -55 and padMinZ <= 245 and padMaxZ >= 355,
		"apron -240..-60, taxiway x -60"
	)

	--[[
		THE property the airport depends on: the pad is dead level. Asserted on
		the height FIELD here and on the built terrain below, because the two
		can disagree and it is the second one the aeroplane lands on.
	]]
	local padFlat = true
	for x = padMinX, padMaxX, 50 do
		for z = padMinZ, padMaxZ, 50 do
			if math.abs(TerrainService.surfaceHeightFor(x, z) - AirportService.GRASS_Y) > 1e-9 then
				padFlat = false
			end
		end
	end
	record(
		"The height field is exactly level across the pad",
		padFlat,
		string.format("every sample at %.2f m", AirportService.GRASS_Y)
	)

	record(
		"The pad sits at the airport's own grass height, not at zero",
		TerrainService.surfaceHeightFor(0, 0) == AirportService.GRASS_Y and AirportService.GRASS_Y ~= 0,
		string.format("%.2f m, and the airport surface is %.2f m", AirportService.GRASS_Y, AirportService.SURFACE_Y)
	)

	--[[
		Relief must stay within its declared amplitude. This is the check that
		keeps a hill out of the circuit, so it is asserted over the whole field
		rather than sampled near the airport.
	]]
	local lowest, highest = math.huge, -math.huge
	for x = -FIELD_HALF, FIELD_HALF, 64 do
		for z = -FIELD_HALF, FIELD_HALF, 64 do
			local h = TerrainService.surfaceHeightFor(x, z)
			lowest = math.min(lowest, h)
			highest = math.max(highest, h)
		end
	end
	record(
		"Relief never exceeds the declared amplitude",
		highest - AirportService.GRASS_Y <= RELIEF_AMPLITUDE + 1e-6
			and AirportService.GRASS_Y - lowest <= RELIEF_AMPLITUDE + 1e-6,
		string.format("%.1f m below to %.1f m above, limit %d m",
			AirportService.GRASS_Y - lowest, highest - AirportService.GRASS_Y, RELIEF_AMPLITUDE)
	)
	record(
		"The world is not simply flat - there IS relief out there",
		highest - lowest > 5,
		string.format("%.1f m of range across the field", highest - lowest)
	)

	--[[
		No crease at the pad edge. A step there would be a wall an aeroplane
		could hit while rolling out long, and the smoothstep blend exists for
		exactly this.
	]]
	local worstStep = 0
	for z = padMinZ - 60, padMaxZ + 60, 20 do
		local a = TerrainService.surfaceHeightFor(padMaxX + 10, z)
		local b = TerrainService.surfaceHeightFor(padMaxX + 30, z)
		worstStep = math.max(worstStep, math.abs(b - a))
	end
	record(
		"The pad blends into the relief instead of ending in a cliff",
		worstStep < 1.0,
		string.format("worst %.3f m over 20 m just outside the pad edge", worstStep)
	)

	-- 2. The engine's offset, measured rather than trusted --------------------
	local terrain = Workspace.Terrain
	local PROBE_X, PROBE_Z = 15000, 15000
	local wanted = 250
	terrain:FillBlock(
		CFrame.new(PROBE_X, TerrainService.fillTopFor(wanted) - 20, PROBE_Z),
		Vector3.new(80, 40, 80),
		GROUND_MATERIAL
	)
	task.wait()
	local measured = TerrainService.surfaceAt(PROBE_X, PROBE_Z, wanted + 200)
	record(
		"fillTopFor puts the surface where it was asked to",
		measured ~= nil and math.abs((measured :: number) - wanted) < 0.05,
		string.format("asked %.2f, got %s (offset constant is %.1f = half a %d stud voxel)",
			wanted, measured and string.format("%.3f", measured) or "nothing", SURFACE_OFFSET, VOXEL)
	)
	terrain:FillBlock(CFrame.new(PROBE_X, wanted - 40, PROBE_Z), Vector3.new(120, 200, 120), Enum.Material.Air)

	-- 3. The built world ------------------------------------------------------
	local blocks = TerrainService.build()
	record(
		"The field is built out of terrain blocks",
		blocks == (FIELD_SIZE / BLOCK) ^ 2,
		string.format("%d blocks of %d m over a %d m field", blocks, BLOCK, FIELD_SIZE)
	)

	record(
		"The baseplate part is gone - terrain is the ground now",
		Workspace:FindFirstChild("Baseplate") == nil,
		"retired at run time; the Rojo-managed part still exists for the edit view"
	)

	--[[
		THE measurement this whole module exists to make good on: the terrain
		the aeroplane actually lands beside is level across the airport, and at
		the height the airport declared.
	]]
	local minY, maxY, samples = math.huge, -math.huge, 0
	local missing = 0
	for x = -200, 0, 50 do
		for z = -500, 500, 50 do
			local y = TerrainService.terrainHeightAt(x, z)
			if y then
				minY = math.min(minY, y)
				maxY = math.max(maxY, y)
				samples += 1
			else
				missing += 1
			end
		end
	end
	record(
		"Terrain exists everywhere across the airport",
		missing == 0 and samples > 50,
		string.format("%d samples, %d gaps", samples, missing)
	)
	record(
		"The built pad is level to within a centimetre",
		maxY - minY < 0.01,
		string.format("peak-to-peak %.4f m over %d samples", maxY - minY, samples)
	)
	record(
		"...and it is at the height the airport declared",
		math.abs(minY - AirportService.GRASS_Y) < 0.05,
		string.format("terrain %.3f m against GRASS_Y %.2f m", minY, AirportService.GRASS_Y)
	)

	--[[
		And the pavement still wins. The runway is a part resting on the pad, so
		the ground probe must find the part - if terrain came out higher than the
		pavement, every wheel would be buried in grass.
	]]
	local overRunway = TerrainService.surfaceAt(0, 0)
	local terrainUnderRunway = TerrainService.terrainHeightAt(0, 0)
	record(
		"The pavement stands proud of the terrain, so the probe finds the runway",
		overRunway ~= nil and terrainUnderRunway ~= nil
			and (overRunway :: number) > (terrainUnderRunway :: number),
		string.format("surface %.3f m, terrain %.3f m below it",
			overRunway or -1, terrainUnderRunway or -1)
	)
	record(
		"The runway surface is exactly where AirportService declared it",
		overRunway ~= nil and math.abs((overRunway :: number) - AirportService.SURFACE_Y) < 1e-3,
		string.format("%.3f m against SURFACE_Y %.2f m", overRunway or -1, AirportService.SURFACE_Y)
	)

	-- Relief is really there in the built world, not just in the height field.
	local farField = {}
	for _, p in { { 900, 900 }, { -900, 900 }, { 900, -900 }, { -900, -900 } } do
		local y = TerrainService.terrainHeightAt(p[1], p[2])
		if y then
			table.insert(farField, y)
		end
	end
	local varies = false
	for _, y in farField do
		if math.abs(y - AirportService.GRASS_Y) > 1.0 then
			varies = true
		end
	end
	record(
		"The far field is not level with the airport",
		#farField == 4 and varies,
		string.format("%d corners sampled, heights differ from the pad", #farField)
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

return TerrainService
