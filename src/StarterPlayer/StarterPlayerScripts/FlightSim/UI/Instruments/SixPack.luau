--!strict
--[[
	SixPack
	-------
	The standard six instruments, in the standard layout:

		airspeed   attitude   altimeter
		turn       heading    vertical speed

	That arrangement is not decoration. It is the layout every pilot has been
	trained on since the 1950s - the three primary instruments across the top
	with attitude in the middle, and the scan pattern radiates from it.

	WHAT THIS MODULE IS
	-------------------
	Six spec tables and six samplers. All the drawing, all the needle maths and
	the redraw loop belong to `Instrument`; nothing here creates a frame or
	computes an angle. If something in this file starts doing either, it belongs
	in the framework instead.

	UNITS CONVERT HERE, AND NOWHERE DEEPER
	--------------------------------------
	The physics is pure SI and stays that way. The samplers below are the entire
	boundary: metres per second become knots, metres become feet, radians become
	degrees, and nothing converted travels back the other way. `Instrument`
	itself is unit-agnostic - it maps numbers to angles and does not know what
	they mean.

	THE ARCS ARE THE AIRCRAFT'S OWN NUMBERS
	---------------------------------------
	Every marking on the airspeed indicator comes from `Cessna172.limits`. The
	white arc IS vs0..vfe, the green IS vs1..vno, the redline IS vne. Change the
	aircraft and the face changes with it; there is no number here that was
	chosen to look about right.

	IT MUST NOT EAT MOUSE INPUT
	---------------------------
	The cursor is the yoke and covers the whole screen, so nothing here is
	Active and nothing is a GuiButton. Six dials is a far larger target than the
	debug HUD ever was, and one Active frame among them would take the flight
	controls away. A test counts them and requires zero.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FlightSim = ReplicatedStorage:WaitForChild("FlightSim")

local Constants = require(FlightSim.Config.Constants)
local Units = require(FlightSim.Shared.Units)
local Cessna172 = require(FlightSim.Aircraft.Definitions.Cessna172)

local Instrument = require(script.Parent:WaitForChild("Instrument"))
local InstrumentError = require(script.Parent:WaitForChild("InstrumentError"))
local FlightController = require(script.Parent.Parent.Parent:WaitForChild("Controllers"):WaitForChild("FlightController"))

local SixPack = {}

local deg = math.deg

-- =========================================================================
-- LAYOUT
-- =========================================================================

local DIAL_SIZE = 116
local GAP = 8
local BOTTOM_MARGIN = 14

-- Four across: the six-pack occupies the left three, the engine cluster the
-- fourth, which is the arrangement on the real aeroplane.
local COLUMNS = 4

-- =========================================================================
-- THE SIX FACES, AS DATA
-- =========================================================================

local L = Cessna172.limits

--[[
	AIRSPEED. 40 to 200 kt over 320 degrees, which is the ordinary light-aircraft
	face - the scale starts at 40 because below the stall there is nothing worth
	reading, and the needle simply rests against the bottom peg when parked.

	Arcs from the definition, drawn at two radii because on a real ASI the white
	flap arc runs INSIDE the green one and they overlap between Vs1 and Vfe.
]]
SixPack.ASI = {
	name = "Airspeed",
	caption = "KNOTS",
	-- Clear of the 120/140 labels, which sit low on this face.
	captionY = 0.63,
	breakpoints = Instrument.linearFace(40, 200, 0, 320),
	ticks = { major = 20, minor = 10, labelRadius = 0.56 },
	arcs = {
		{ from = L.vs0, to = L.vfe, color = Instrument.ARC.WHITE, radius = 0.72, thickness = 4 },
		{ from = L.vs1, to = L.vno, color = Instrument.ARC.GREEN, radius = 0.86, thickness = 5 },
		{ from = L.vno, to = L.vne, color = Instrument.ARC.YELLOW, radius = 0.86, thickness = 5 },
	},
	redline = L.vne,
}

--[[
	ATTITUDE. Not a dial - see Instrument.buildHorizon for why it gets its own
	builder rather than being forced into a breakpoint table.

	Pitch is limited to 60 degrees, well past anything this aeroplane does in
	normal flight but short of the tumbling a real vacuum gyro would do. The
	Phase 1 gate reached -64 degrees in a stall departure, so the limit is
	reachable and has to behave rather than scroll away.
]]
SixPack.ATTITUDE = {
	name = "Attitude",
	pitchLimit = 60,
	ladderEvery = 10,
	ladderTo = 30,
}

--[[
	ALTIMETER. The classic two-pointer face: one revolution is 1,000 ft, the
	long needle reads hundreds and the short one thousands.

	Both needles read ONE altitude through different gearing, which is exactly
	what the multi-needle support in the framework is for. The face itself
	wraps, so 1,000 ft is drawn where 0 is and the closing tick is suppressed.
]]
SixPack.ALTIMETER = {
	name = "Altimeter",
	caption = "ALT  FT",
	captionY = 0.62,
	breakpoints = Instrument.linearFace(0, 1000, 0, 360),
	period = 1000,
	ticks = { major = 100, minor = 20, labelScale = 0.01, labelRadius = 0.60 },
	needles = {
		-- Declared thousands-first so the long hundreds needle draws OVER it,
		-- as it does on the real instrument.
		{ name = "Thousands", breakpoints = Instrument.linearFace(0, 10000, 0, 360), period = 10000, length = 0.26, width = 0.06 },
		{ name = "Hundreds", length = 0.42, width = 0.03 },
	},
}

--[[
	TURN COORDINATOR. Two independent readings on one case, which is the whole
	reason `setNeedle` and `setBall` exist separately from `setValue`.

	The symbol banks with RATE OF TURN, not with bank angle - a standard rate
	turn is 3 degrees of heading per second however steeply you bank to get it,
	and the index marks are placed at exactly that. No numbers on the face,
	because the real instrument has none: it has L and R and two marks.

	The ball's full scale is 3.0 m/s^2, about 0.3 g, which is roughly where a
	real inclinometer's ball reaches the end of its tube.
]]
SixPack.TURN = {
	name = "TurnCoordinator",
	caption = "2 MIN",
	-- Above the hub: the bottom of this face is the inclinometer's.
	captionY = 0.28,
	breakpoints = Instrument.linearFace(-6, 6, -40, 80),
	ticks = { major = 3, labelEvery = 0 },
	needles = {
		{ name = "Symbol", shape = "wings", length = 0.34, color = Instrument.ARC.WHITE },
	},
	ball = { fullScale = 3.0, travel = 0.20, centerY = 0.78 },
	lagTau = 0.35,
}

--[[
	DIRECTION INDICATOR. A rotating card read against a fixed lubber line, which
	is what makes it possible to hold a heading - the number you are flying sits
	at the top and stays there.

	Labelled every 30 degrees in tens, as every compass card is: 3 for 030, 33
	for 330. N/E/S/W would be nicer to read but the gate asks for a heading to
	be held, and a number is what you hold.

	No lag: the face wraps, and filtering across the 360/000 seam would send the
	card the long way round on rollout.
]]
SixPack.HEADING = {
	name = "Heading",
	breakpoints = Instrument.linearFace(0, 360, 0, 360),
	period = 360,
	rotatingCard = true,
	ticks = { major = 30, minor = 10, labelScale = 0.1, labelRadius = 0.62 },
}

--[[
	VERTICAL SPEED. Zero at nine o'clock, climb clockwise, descent
	anticlockwise, and COMPRESSED above 1,000 fpm - the outer half of the scale
	gets 50 degrees where the inner half gets 80.

	That compression is the reason the framework takes a breakpoint table rather
	than a range: a real VSI gives its resolution to the rates you actually trim
	for, and squeezes the ones you are only ever reacting to.

	LAG: set to 2.0 s. A real VSI is slower than this - six to nine seconds is
	usual, because it works by measuring the leak rate from a calibrated orifice
	- and that is genuinely how the instrument behaves. Two seconds is a
	deliberate compromise for a simulator where the pilot cannot feel the seat,
	and it is flagged in the handoff as the pilot's to overrule.
]]
SixPack.VSI = {
	name = "VerticalSpeed",
	caption = "FPM x1000",
	-- Between the hub and the -1/-2 labels; this face is numbered low on both
	-- sides, so the usual position below the hub is taken.
	captionY = 0.60,
	breakpoints = {
		{ value = -2000, angle = 140 },
		{ value = -1000, angle = 190 },
		{ value = 0, angle = 270 },
		{ value = 1000, angle = 350 },
		{ value = 2000, angle = 400 },
	},
	-- Labelled in thousands, as the real face is: 2, 1, 0, 1, 2 with the scale
	-- named in the caption rather than repeated on every number.
	ticks = { major = 500, minor = 100, labelEvery = 2, labelScale = 0.001, labelRadius = 0.58 },
	lagTau = 2.0,
}

--[[
	TACHOMETER. 0 to 3,000 rpm over 300 degrees, labelled in hundreds as every
	light-aircraft tachometer is.

	The green arc runs from `limits.rpmGreenLow` to `engine.maxRPM`, and the
	redline IS `engine.maxRPM` - taken from the definition rather than typed,
	so the arc cannot drift away from the engine it describes. Same rule as the
	airspeed arcs.

	A small lag, because a real tachometer is mechanically damped and the
	engine model's rpm steps as the throttle ramps.
]]
SixPack.TACHOMETER = {
	name = "Tachometer",
	caption = "RPM x100",
	captionY = 0.62,
	--[[
		Zero at the lower LEFT, sweeping clockwise through the top to the
		redline at the lower right. That is not decoration: it puts the cruise
		range - the green arc, and the only part of the scale anyone reads in
		flight - across the top right of the dial where the eye lands.

		Starting at the top instead was tried and looked wrong for exactly that
		reason: it drove 2,100 to 2,700 rpm round to the left-hand side.
	]]
	breakpoints = Instrument.linearFace(0, 3000, 210, 300),
	ticks = { major = 500, minor = 100, labelScale = 0.01, labelRadius = 0.60 },
	arcs = {
		{ from = Cessna172.limits.rpmGreenLow, to = Cessna172.engine.maxRPM, color = Instrument.ARC.GREEN, radius = 0.86, thickness = 5 },
	},
	redline = Cessna172.engine.maxRPM,
	lagTau = 0.25,
}

--[[
	FUEL. Marked E, 1/4, 1/2, 3/4, F over a quarter of a turn.

	IT READS A LEVEL, NOT A MASS, and that is why there is no unit conversion
	here and no invented fuel density. A real float-type fuel gauge measures how
	full the tank is; showing a fraction of capacity is the honest presentation
	of `fuelKg` against `fuelCapacityKg`, and inventing a kg-per-gallon constant
	to print gallons would be making up a number the definition does not have.

	The red band at the bottom is `limits.fuelReserveKg` - 45 minutes at cruise
	burn, derived in the definition rather than drawn by eye.

	Lagged hard, at 4 s. Real fuel gauges are heavily damped precisely so the
	needle does not swing about with every attitude change as the fuel sloshes;
	a fuel gauge that twitched during a turn would be worse than useless.
]]
SixPack.FUEL = {
	name = "Fuel",
	caption = "FUEL",
	-- Below the hub: this face uses only the top of the dial, so the bottom is
	-- free and the caption cannot collide with a number.
	captionY = 0.72,
	breakpoints = Instrument.linearFace(0, Cessna172.engine.fuelCapacityKg, -60, 120),
	--[[
		Ticks at every quarter but numbers only at E, 1/2 and F.

		Five labels across 120 degrees overlap - drawn and looked at, "1/4",
		"1/2" and "3/4" ran into each other - and the real gauge is sparse for
		the same reason. The quarter marks are still there as ticks, which is
		all a level gauge needs.
	]]
	ticks = {
		major = Cessna172.engine.fuelCapacityKg / 4,
		labelEvery = 2,
		labelNames = { "E", "1/2", "F" },
		labelRadius = 0.58,
	},
	arcs = {
		{ from = 0, to = Cessna172.limits.fuelReserveKg, color = Instrument.ARC.RED, radius = 0.86, thickness = 5 },
	},
	lagTau = 4.0,
}

-- =========================================================================
-- SAMPLERS - THE UNIT BOUNDARY
-- =========================================================================

--[[
	One function per instrument, each taking the raw SI telemetry and returning
	what the face is calibrated in. Pure and exported, so the conversions can be
	asserted against published figures without building a single frame.
]]
SixPack.samplers = {
	--[[
		⚠️ THE GAUGES READ LIKE INSTRUMENTS, NOT LIKE THE PHYSICS (§32).

		Three of these samplers now inject a real instrument's error before the
		needle sees the number. The physics is untouched and never sees any of
		it - the aeroplane still flies on true values, and only the display
		lies, in the ways real displays lie.

		This is the right layer for it precisely because the samplers are the
		one door every panel value already comes through.
	]]
	airspeedKt = function(t: any): number
		-- Static-source position error, from the POH calibration table. Worst
		-- slow and nose-high, which is when the pilot most needs the number.
		return Units.msToKnots(InstrumentError.indicatedAirspeed(t.airspeedIndicated or 0, t.flaps))
	end,
	altitudeFt = function(t: any): number
		-- What the Kollsman window says, not what the aeroplane's height is.
		return Units.metersToFeet(InstrumentError.indicatedAltitude(
			t.altitude or 0,
			t.qnhPa,
			t.altimeterSettingPa
		))
	end,
	verticalSpeedFpm = function(t: any): number
		return Units.msToFeetPerMin(t.verticalSpeed or 0)
	end,
	--[[
		MAGNETIC, not true - the DI is set from the compass, and so is every
		runway number and published bearing.

		It gets magnetic variation and NOTHING else. The turning error in
		InstrumentError belongs to the wet compass, which is a different
		instrument that fails differently; a gyroscopic DI is steady in a turn
		by design. See §32 - putting dip error on this gauge would be modelling
		the wrong instrument.
	]]
	headingDeg = function(t: any): number
		return deg(InstrumentError.magneticHeading(t.heading or 0))
	end,
	turnRateDegPerSec = function(t: any): number
		return deg(t.turnRate or 0)
	end,
	pitchDeg = function(t: any): number
		return deg(t.pitchAttitude or 0)
	end,
	bankDeg = function(t: any): number
		return deg(t.bankAngle or 0)
	end,
	-- Already SI and already what the ball reads; here for symmetry, and so
	-- that every value on the panel arrives through the same door.
	lateralAccel = function(t: any): number
		return t.lateralAcceleration or 0
	end,
	-- Engine rpm and fuel are already in the units their faces are marked in -
	-- rpm is rpm, and the fuel gauge reads a level against capacity in the same
	-- kilograms the physics burns. Nothing to convert, which is the point.
	rpm = function(t: any): number
		return t.rpm or 0
	end,
	fuelKg = function(t: any): number
		return t.fuelKg or 0
	end,
}

-- =========================================================================
-- STATE
-- =========================================================================

local player = Players.LocalPlayer

local screenGui: ScreenGui? = nil
local gauges: { [string]: any } = {}
local registration: any = nil
local initialised = false

-- =========================================================================
-- BUILD
-- =========================================================================

--[[
	Build the panel into `parent` and return the ScreenGui.

	Exported so runTests() can build a real panel against a real PlayerGui and
	then destroy it - "do six dials actually come out, with a needle each and
	nothing that swallows a click" is not a question arithmetic can answer, and
	section 17 learned that the expensive way.
]]
--[[
	Build the panel itself: a plain Frame of a fixed pixel size, containing the
	eight instruments and NOTHING that knows about a screen.

	THIS IS THE SPLIT THAT KEEPS THE 3D PANEL POSSIBLE. The instruments are
	going to end up on a real panel inside the Cessna, which in Roblox means a
	SurfaceGui on a part - and a SurfaceGui hosts exactly the same GuiObjects.
	So everything below is expressed in pixels within its own frame, with no
	scale positioning, no viewport, no GUI inset and no camera. Moving the panel
	into the cockpit becomes a matter of reparenting this frame; nothing here
	has to be rewritten.

	`SixPack.build` wraps it in a ScreenGui for now. That wrapper is the only
	part that is throwaway.
]]
function SixPack.buildPanel(parent: Instance): (Frame, { [string]: any })
	local panelWidth = DIAL_SIZE * COLUMNS + GAP * (COLUMNS - 1)
	local panelHeight = DIAL_SIZE * 2 + GAP

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.fromOffset(panelWidth, panelHeight)
	panel.BackgroundTransparency = 1
	panel.BorderSizePixel = 0
	panel.Parent = parent

	local built: { [string]: any } = {}

	local function positionAt(root: Frame, column: number, row: number)
		root.Position = UDim2.fromOffset(column * (DIAL_SIZE + GAP), row * (DIAL_SIZE + GAP))
	end

	--[[
		Top row: the three primary instruments, attitude in the middle, with the
		engine cluster to the right of the six-pack exactly as it sits on a real
		172 panel.
	]]
	built.airspeed = Instrument.build(panel, SixPack.ASI, DIAL_SIZE)
	positionAt(built.airspeed.root, 0, 0)

	built.attitude = Instrument.buildHorizon(panel, SixPack.ATTITUDE, DIAL_SIZE)
	positionAt(built.attitude.root, 1, 0)

	built.altimeter = Instrument.build(panel, SixPack.ALTIMETER, DIAL_SIZE)
	positionAt(built.altimeter.root, 2, 0)

	built.tachometer = Instrument.build(panel, SixPack.TACHOMETER, DIAL_SIZE)
	positionAt(built.tachometer.root, 3, 0)

	-- Bottom row.
	built.turn = Instrument.build(panel, SixPack.TURN, DIAL_SIZE)
	positionAt(built.turn.root, 0, 1)

	built.heading = Instrument.build(panel, SixPack.HEADING, DIAL_SIZE)
	positionAt(built.heading.root, 1, 1)

	built.vsi = Instrument.build(panel, SixPack.VSI, DIAL_SIZE)
	positionAt(built.vsi.root, 2, 1)

	built.fuel = Instrument.build(panel, SixPack.FUEL, DIAL_SIZE)
	positionAt(built.fuel.root, 3, 1)

	return panel, built
end

--[[
	Wrap the panel in a ScreenGui and hang it where the 3D panel will sit:
	bottom centre, under the cowling, which is where a real panel is relative to
	the windscreen.

	Everything screen-specific in this module is in this function and nowhere
	else. When the instruments move into the cockpit, this is what gets deleted.
]]
--[[
	Mount the panel on a real part in the world - the cockpit's `PanelBoard`.

	This is what §19 has been building toward since Phase 2: `buildPanel` knows
	nothing about a screen, so putting the instruments in the aeroplane is a
	reparent rather than a rewrite. Nothing below is new drawing code.

	⚠️ THE BOARD'S SHAPE MUST MATCH THE FRAME'S, OR THE DIALS GO OVAL. The frame
	is a fixed pixel size and a SurfaceGui maps it onto the face, so the part's
	own aspect ratio is what decides whether a circular dial renders circular.
	`Cessna172`'s board is sized 0.96 x 0.472 m for exactly this reason, and a
	check asserts the two agree rather than trusting the definition.

	`PixelsPerStud` is derived from the frame and the part, so the panel fills
	the face whatever size the board is built at.
]]
function SixPack.mountOnPart(board: BasePart, face: Enum.NormalId?): (SurfaceGui, Frame, { [string]: any })
	local surface = Instance.new("SurfaceGui")
	surface.Name = "FlightSimPanel"
	surface.Adornee = board
	--[[
		The pilot faces -Z, so the face they see is the part's +Z side, which
		Roblox calls Back. Passed in rather than assumed so a definition that
		mounts a panel the other way round can say so.
	]]
	surface.Face = face or Enum.NormalId.Back
	surface.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surface.LightInfluence = 0
	surface.AlwaysOnTop = false
	surface.Parent = board

	local panel, built = SixPack.buildPanel(surface)
	surface.PixelsPerStud = panel.AbsoluteSize.X > 0
		and (panel.Size.X.Offset / board.Size.X)
		or 50
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)

	return surface, panel, built
end

function SixPack.build(parent: Instance): (ScreenGui, { [string]: any })
	local gui = Instance.new("ScreenGui")
	gui.Name = "FlightSimSixPack"
	gui.ResetOnSpawn = false
	--[[
		Left false deliberately, and it is not a style choice: it puts this GUI's
		origin in the same space the yoke already works in, so no pixel offset
		here needs correcting for the top bar. Section 6g and section 16 are the
		record of what happens when those two spaces are mixed.
	]]
	gui.IgnoreGuiInset = false
	gui.Enabled = false
	gui.Parent = parent

	local panel, built = SixPack.buildPanel(gui)
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = UDim2.new(0.5, 0, 1, -BOTTOM_MARGIN)

	return gui, built
end

--[[
	Drive every instrument from one telemetry table. Pure with respect to the
	datamodel apart from the writes it makes to the gauges themselves, so the
	tests can push synthetic telemetry through the real path.
]]
function SixPack.render(built: { [string]: any }, telemetry: any, dt: number?)
	local s = SixPack.samplers

	Instrument.setValue(built.airspeed, s.airspeedKt(telemetry), dt)
	Instrument.setValue(built.altimeter, s.altitudeFt(telemetry), dt)
	Instrument.setValue(built.vsi, s.verticalSpeedFpm(telemetry), dt)
	Instrument.setValue(built.heading, s.headingDeg(telemetry), dt)

	Instrument.setAttitude(built.attitude, s.pitchDeg(telemetry), s.bankDeg(telemetry), dt)

	-- Two readings, two calls: the coordinator's symbol and its ball answer to
	-- different quantities and neither follows from the other.
	Instrument.setNeedle(built.turn, "Symbol", s.turnRateDegPerSec(telemetry), dt)
	Instrument.setBall(built.turn, s.lateralAccel(telemetry), dt)

	-- Engine cluster.
	Instrument.setValue(built.tachometer, s.rpm(telemetry), dt)
	Instrument.setValue(built.fuel, s.fuelKg(telemetry), dt)
end

-- =========================================================================
-- LIFECYCLE
-- =========================================================================

function SixPack.Init()
	if initialised then
		return
	end
	initialised = true

	local playerGui = player:WaitForChild("PlayerGui")
	local gui, built = SixPack.build(playerGui)
	screenGui = gui
	gauges = built

	--[[
		ONE registration for the whole panel, on the framework's shared loop.

		No sampler is registered: nothing on the six-pack needs a peak or an
		edge caught between redraws. That is a real difference from the debug
		HUD, which does - and the reason the loop offers both.
	]]
	registration = Instrument.register(function(dt: number)
		local telemetry = FlightController.getTelemetry()
		local flying = telemetry ~= nil and FlightController.isFlying()

		if not flying then
			if gui.Enabled then
				gui.Enabled = false
			end
			return
		end

		if not gui.Enabled then
			gui.Enabled = true
		end

		SixPack.render(built, telemetry, dt)
	end)

	Instrument.startLoop()

	if Constants.DEBUG.ENABLED then
		print("[FlightSim:HUD] Six-pack ready")
	end
end

function SixPack.Shutdown()
	if registration then
		Instrument.unregister(registration)
		registration = nil
	end
	if Instrument.registeredCount() == 0 then
		Instrument.stopLoop()
	end
	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end
	table.clear(gauges)
	initialised = false
end

-- =========================================================================
-- VERIFICATION
-- =========================================================================

--[[
	Run from the Studio command bar, CLIENT datamodel:
		require(game.Players.LocalPlayer.PlayerScripts.FlightSim.UI.Instruments.SixPack).runTests()

	The specs and samplers are data and pure functions, so most of this needs no
	GUI. A real panel is built once, driven with synthetic telemetry, and
	destroyed - because section 17's lesson is that a gauge which lies produces
	no error at all.
]]
function SixPack.runTests(): (boolean, { any })
	local results = {}
	local allPassed = true

	local function record(label: string, passed: boolean, detail: string)
		if not passed then
			allPassed = false
		end
		table.insert(results, { label = label, passed = passed, detail = detail })
		print(string.format("  [%s] %-54s %s", passed and "PASS" or "FAIL", label, detail))
	end

	local function checkRange(label: string, value: number, low: number, high: number, unit: string)
		record(label, value >= low and value <= high, string.format("%.3f %s (expected %.2f..%.2f)", value, unit, low, high))
	end

	print("=== SixPack: verification ===")

	-- 1. The unit boundary --------------------------------------------------
	--[[
		Asserted against known conversions rather than against whatever the
		code produces. These four are the entire reason the physics never has
		to know what a knot is.
	]]
	local s = SixPack.samplers
	--[[
		⚠️ 80 KT IS DELIBERATE, AND SO IS THE VARIATION BELOW.

		Since §32 three of these samplers inject a real instrument's error, so
		a test that feeds 100 kt and demands 100 kt back is asserting the
		absence of the feature. 80 kt is the one speed the POH calibration
		table says the ASI reads correctly, so this still tests the unit
		boundary and only the unit boundary. The error itself is asserted
		against published numbers in InstrumentError's own suite, and the two
		checks below pin the fact that it reaches the panel at all.
	]]
	checkRange("Airspeed converts m/s to knots", s.airspeedKt({ airspeedIndicated = Units.knotsToMs(80) }), 79.9, 80.1, "kt")
	checkRange("Altitude converts metres to feet", s.altitudeFt({ altitude = 304.8 }), 999.9, 1000.1, "ft")
	checkRange("Vertical speed converts m/s to fpm", s.verticalSpeedFpm({ verticalSpeed = 5.08 }), 999, 1001, "fpm")
	local magneticOf180 = 180 - InstrumentError.MAGNETIC_VARIATION_DEG
	checkRange(
		"Heading converts radians to degrees, and reads MAGNETIC",
		s.headingDeg({ heading = math.pi }),
		magneticOf180 - 0.1,
		magneticOf180 + 0.1,
		"deg"
	)
	checkRange("Turn rate converts radians to degrees", s.turnRateDegPerSec({ turnRate = math.rad(3) }), 2.99, 3.01, "deg/s")
	record(
		"The ball stays in SI, because that is what it reads",
		s.lateralAccel({ lateralAcceleration = -1.25 }) == -1.25,
		"m/s^2 passed through unconverted"
	)
	--[[
		The position error reaches the panel. Fed the calibrated speed the POH
		pairs with 40 kt indicated, the gauge must show 40 - if this reads 48
		the sampler has been "simplified" back to the raw number.
	]]
	record(
		"The ASI shows INDICATED airspeed, not calibrated",
		math.abs(s.airspeedKt({ airspeedIndicated = Units.knotsToMs(48) }) - 40) < 0.05,
		string.format("48 kt calibrated shows %.1f kt indicated", s.airspeedKt({ airspeedIndicated = Units.knotsToMs(48) }))
	)
	record(
		"Absent telemetry is survivable rather than an error",
		s.airspeedKt({}) == 0
			and s.pitchDeg({}) == 0
			and s.headingDeg({}) == (-InstrumentError.MAGNETIC_VARIATION_DEG) % 360,
		"an empty table reads zero, except the DI - a TRUE heading of zero is genuinely not magnetic zero"
	)

	-- 2. The airspeed face is the aircraft's ------------------------------
	local bands = Instrument.arcBands(SixPack.ASI)
	record(
		"The white arc is Vs0 to Vfe, from the definition",
		bands[1].from == L.vs0 and bands[1].to == L.vfe,
		string.format("%d..%d kt", L.vs0, L.vfe)
	)
	record(
		"The green arc is Vs1 to Vno, from the definition",
		bands[2].from == L.vs1 and bands[2].to == L.vno,
		string.format("%d..%d kt", L.vs1, L.vno)
	)
	record(
		"The yellow caution arc is Vno to Vne",
		bands[3].from == L.vno and bands[3].to == L.vne,
		string.format("%d..%d kt", L.vno, L.vne)
	)
	record(
		"The redline is Vne",
		SixPack.ASI.redline == L.vne,
		string.format("%d kt", L.vne)
	)
	--[[
		The face has to CONTAIN the aircraft's envelope. A scale ending below
		Vne would put the redline off the dial, and the needle would sit on the
		peg through the entire overspeed it is meant to be warning about.
	]]
	local asiMin, asiMax = Instrument.faceRange(SixPack.ASI)
	record(
		"The scale reaches past Vne, so the redline is on the dial",
		asiMax > L.vne and asiMin <= L.vs0,
		string.format("face %d..%d kt against Vs0 %d and Vne %d", asiMin, asiMax, L.vs0, L.vne)
	)

	-- 3. Face sanity, one per instrument ------------------------------------
	--[[
		The VSI's compression, which is the reason for breakpoints. The outer
		half of the scale must get LESS sweep per hundred feet than the inner
		half, or the face is merely linear with extra steps.
	]]
	local vsiInner = Instrument.angleFor(SixPack.VSI, 1000) - Instrument.angleFor(SixPack.VSI, 0)
	local vsiOuter = Instrument.angleFor(SixPack.VSI, 2000) - Instrument.angleFor(SixPack.VSI, 1000)
	record(
		"The VSI compresses its outer scale, as a real one does",
		vsiOuter < vsiInner * 0.8,
		string.format("%.0f deg for the first 1000 fpm, %.0f for the second", vsiInner, vsiOuter)
	)
	record(
		"VSI zero sits at nine o'clock",
		math.abs(Instrument.angleFor(SixPack.VSI, 0) - 270) < 1e-9,
		"270 deg, so climb reads clockwise from level"
	)
	record(
		"Climb and descent are on opposite sides of zero",
		Instrument.angleFor(SixPack.VSI, 500) > 270 and Instrument.angleFor(SixPack.VSI, -500) < 270,
		"up is clockwise"
	)

	record(
		"The heading card wraps instead of hitting a stop",
		math.abs(Instrument.angleFor(SixPack.HEADING, 370) - 10) < 1e-9,
		"370 deg reads as 010"
	)
	--[[
		A compass card must not carry both 000 and 360 - they are the same
		bearing and would be drawn on top of each other with the labels stacked.
	]]
	local headingMarks = Instrument.tickMarks(SixPack.HEADING)
	local zeroLike = 0
	for _, m in headingMarks do
		if math.abs(Instrument.angleFor(SixPack.HEADING, m.value) % 360) < 1e-9 then
			zeroLike += 1
		end
	end
	record(
		"The card carries north exactly once, not 000 and 360 stacked",
		zeroLike == 1,
		string.format("%d tick(s) at the top of the card", zeroLike)
	)

	local altMarks = Instrument.tickMarks(SixPack.ALTIMETER)
	local altLabels = 0
	for _, m in altMarks do
		if m.label then
			altLabels += 1
		end
	end
	record(
		"The altimeter is numbered 0 to 9 once round, not 0 to 10",
		altLabels == 10,
		string.format("%d labels on a 1000 ft revolution", altLabels)
	)

	-- 3b. The engine cluster -------------------------------------------------
	--[[
		The tachometer's markings come from the engine, not from this file. The
		redline being `engine.maxRPM` by IDENTITY rather than by a matching
		literal is the point: change the engine and the arc follows.
	]]
	local tachBands = Instrument.arcBands(SixPack.TACHOMETER)
	record(
		"The tachometer's green arc runs to the engine's own maximum",
		tachBands[1].from == Cessna172.limits.rpmGreenLow
			and tachBands[1].to == Cessna172.engine.maxRPM,
		string.format("%d..%d rpm", tachBands[1].from, tachBands[1].to)
	)
	record(
		"The tachometer redline IS engine.maxRPM",
		SixPack.TACHOMETER.redline == Cessna172.engine.maxRPM,
		string.format("%d rpm", Cessna172.engine.maxRPM)
	)
	local tachMin, tachMax = Instrument.faceRange(SixPack.TACHOMETER)
	record(
		"The tachometer scale reaches past the redline",
		tachMax > Cessna172.engine.maxRPM and tachMin <= Cessna172.engine.idleRPM,
		string.format("face %d..%d against idle %d and max %d",
			tachMin, tachMax, Cessna172.engine.idleRPM, Cessna172.engine.maxRPM)
	)

	--[[
		The fuel gauge reads a LEVEL. Full tanks must put the needle at the top
		of the scale, and the scale's top must be the aircraft's actual capacity
		- a gauge that reads three quarters on full tanks is worse than none.
	]]
	local fuelMin, fuelMax = Instrument.faceRange(SixPack.FUEL)
	record(
		"The fuel scale is exactly the aircraft's capacity",
		fuelMin == 0 and fuelMax == Cessna172.engine.fuelCapacityKg,
		string.format("0..%d kg", Cessna172.engine.fuelCapacityKg)
	)
	local fuelBands = Instrument.arcBands(SixPack.FUEL)
	record(
		"The red band is the reserve from the definition",
		fuelBands[1].from == 0 and fuelBands[1].to == Cessna172.limits.fuelReserveKg,
		string.format("0..%d kg, about 45 min at cruise burn", Cessna172.limits.fuelReserveKg)
	)
	record(
		"...and the reserve is a small part of the tanks, not most of them",
		Cessna172.limits.fuelReserveKg < Cessna172.engine.fuelCapacityKg * 0.25,
		string.format("%d of %d kg", Cessna172.limits.fuelReserveKg, Cessna172.engine.fuelCapacityKg)
	)

	--[[
		E, 1/4, 1/2, 3/4, F rather than numbers - and in that ORDER, since the
		names are matched to the majors by position.
	]]
	local fuelMarks = Instrument.tickMarks(SixPack.FUEL)
	local fuelLabels = {}
	for _, m in fuelMarks do
		if m.label then
			table.insert(fuelLabels, m.label)
		end
	end
	record(
		"The fuel gauge is marked E to F, not in kilograms",
		table.concat(fuelLabels, ",") == "E,1/2,F",
		table.concat(fuelLabels, " ")
	)
	--[[
		The quarter marks survive as unlabelled ticks. Dropping the numbers to
		stop them overlapping must not also drop the graduations, or the gauge
		loses the resolution that makes "about a quarter left" readable.
	]]
	local fuelMajors = 0
	for _, m in fuelMarks do
		if m.major then
			fuelMajors += 1
		end
	end
	record(
		"The quarter marks are still graduated, just not numbered",
		fuelMajors == 5,
		string.format("%d major ticks, %d numbered", fuelMajors, #fuelLabels)
	)
	--[[
		The names must land on the values they claim. "1/2" sitting anywhere but
		half a tank is an instrument that lies, and the label list is matched by
		position rather than by value, so this is the check that ties the two
		back together.
	]]
	local halfMark
	for _, m in fuelMarks do
		if m.label == "1/2" then
			halfMark = m
		end
	end
	record(
		"The 1/2 mark sits at half the tanks",
		halfMark ~= nil and math.abs(halfMark.value - Cessna172.engine.fuelCapacityKg / 2) < 1e-6,
		string.format("%.1f kg of %d", halfMark and halfMark.value or -1, Cessna172.engine.fuelCapacityKg)
	)

	-- 4. The built panel ----------------------------------------------------
	local holder = Instance.new("Folder")
	holder.Name = "__SixPackTest"
	holder.Parent = workspace

	local ok, err = pcall(function()
		local gui, built = SixPack.build(holder)

		record(
			"All eight instruments are built",
			built.airspeed and built.attitude and built.altimeter and built.tachometer
				and built.turn and built.heading and built.vsi and built.fuel ~= nil,
			"six-pack plus tachometer and fuel"
		)

		record(
			"The panel starts hidden until the pilot is flying",
			gui.Enabled == false,
			"Enabled = false"
		)
		record(
			"Respects the GUI inset, keeping the yoke's coordinate space simple",
			gui.IgnoreGuiInset == false,
			"IgnoreGuiInset = false"
		)

		--[[
			THE constraint. The cursor is the yoke and roams the whole screen;
			one Active frame among six dials would eat the flight controls.
		]]
		local active, buttons, total = 0, 0, 0
		for _, d in gui:GetDescendants() do
			total += 1
			if d:IsA("GuiButton") then
				buttons += 1
			end
			if d:IsA("GuiObject") and d.Active then
				active += 1
			end
		end
		record(
			"Nothing on the panel can swallow mouse input",
			active == 0 and buttons == 0,
			string.format("%d active, %d button(s) across %d instances", active, buttons, total)
		)

		--[[
			The layout, asserted as a layout: attitude in the MIDDLE of the top
			row is what the whole instrument scan is built around, and the six
			must not overlap.
		]]
		local aiX = built.attitude.root.Position.X.Offset
		local asiX = built.airspeed.root.Position.X.Offset
		local altX = built.altimeter.root.Position.X.Offset
		record(
			"Attitude sits between airspeed and altimeter on the top row",
			asiX < aiX and aiX < altX
				and built.airspeed.root.Position.Y.Offset == built.attitude.root.Position.Y.Offset,
			string.format("x = %d, %d, %d across one row", asiX, aiX, altX)
		)
		record(
			"The bottom row is below the top one and does not overlap it",
			built.turn.root.Position.Y.Offset >= DIAL_SIZE,
			string.format("row 2 at y = %d, dials are %d tall", built.turn.root.Position.Y.Offset, DIAL_SIZE)
		)

		-- 5. Synthetic telemetry through the real render path ---------------
		--[[
			A single flight condition driven through the actual render function,
			with every needle then checked against the angle its own face says
			that value should produce. This is the check that a gauge is not
			lying: not that it moved, but that it moved to the right place.
		]]
		local telemetry = {
			airspeedIndicated = Units.knotsToMs(95),
			altitude = Units.feetToMeters(2500),
			verticalSpeed = 0,
			heading = math.rad(90),
			turnRate = math.rad(3),
			pitchAttitude = math.rad(5),
			bankAngle = math.rad(20),
			lateralAcceleration = 0,
		}
		SixPack.render(built, telemetry)

		--[[
			Against what the SAMPLER produced, not against 95.

			The needle's job is to point at the number the instrument shows,
			and since §32 that is 95 kt corrected for position error. Asserting
			the raw 95 here would make the gauge and the instrument model
			disagree, and only one of them is what the pilot reads.
		]]
		local shownKt = SixPack.samplers.airspeedKt(telemetry)
		record(
			"Airspeed points where its indicated speed belongs on the face",
			math.abs(built.airspeed.needle.Rotation - Instrument.angleFor(SixPack.ASI, shownKt)) < 1e-3,
			string.format("95 kt calibrated shows %.1f kt indicated; needle %.1f deg", shownKt, built.airspeed.needle.Rotation)
		)

		--[[
			2,500 ft: the hundreds needle must be at the 500 mark - half way
			round - and the thousands needle a quarter of the way. This is the
			pair that caught the inherited-period bug in the framework.
		]]
		local hundreds, thousands
		for _, n in built.altimeter.needles do
			if n.name == "Hundreds" then hundreds = n.frame.Rotation end
			if n.name == "Thousands" then thousands = n.frame.Rotation end
		end
		record(
			"At 2500 ft the altimeter reads 2500, on both needles",
			math.abs(hundreds - 180) < 1e-3 and math.abs(thousands - 90) < 1e-3,
			string.format("hundreds %.1f deg, thousands %.1f deg", hundreds, thousands)
		)

		-- The DI reads magnetic (§32), so a TRUE 090 is not 090 under the
		-- lubber line - it is 090 less the variation.
		local shownHeading = SixPack.samplers.headingDeg(telemetry)
		record(
			"The heading card puts the MAGNETIC heading under the lubber line",
			math.abs(built.heading.card.Rotation + shownHeading) < 1e-3,
			string.format("true 090 is %.0f magnetic; card at %.1f deg", shownHeading, built.heading.card.Rotation)
		)

		record(
			"The attitude indicator shows 5 up and 20 right",
			built.attitude.horizonLine.Position.Y.Offset > 0
				and math.abs(built.attitude.horizonLine.Rotation + 20) < 1e-3,
			string.format("horizon %+.1f px, %+.1f deg",
				built.attitude.horizonLine.Position.Y.Offset, built.attitude.horizonLine.Rotation)
		)

		record(
			"A standard rate turn banks the coordinator's symbol to the right",
			built.turn.needles[1].frame.Rotation > 5,
			string.format("%.1f deg of symbol bank at 3 deg/s", built.turn.needles[1].frame.Rotation)
		)
		record(
			"In balance the ball is centred",
			built.turn.ball.Position.X.Scale == 0.5,
			"centred"
		)

		--[[
			A skid must show on the ball, and on the correct side. This is the
			reading that tells a pilot which rudder to press, so a sign error
			here would teach precisely the wrong reflex.
		]]
		telemetry.lateralAcceleration = 1.5
		SixPack.render(built, telemetry)
		record(
			"Specific force to the right slides the ball left",
			built.turn.ball.Position.X.Scale < 0.5,
			string.format("ball at %.3f - step on the ball means left rudder here", built.turn.ball.Position.X.Scale)
		)

		--[[
			Below the bottom of the airspeed scale the needle must sit on the
			peg rather than wrap round to a high reading. Parked on the apron is
			the commonest state this panel is ever in.
		]]
		telemetry.airspeedIndicated = 0
		SixPack.render(built, telemetry)
		record(
			"Parked, the airspeed needle rests at the bottom of the scale",
			math.abs(built.airspeed.needle.Rotation - Instrument.angleFor(SixPack.ASI, asiMin)) < 1e-3,
			string.format("%.1f deg at 0 kt", built.airspeed.needle.Rotation)
		)

		-- NaN must not blank the panel, for the same reason it must not blank
		-- a single needle: an invisible instrument reads as a switched-off one.
		SixPack.render(built, {
			airspeedIndicated = 0 / 0,
			altitude = 0 / 0,
			verticalSpeed = 0 / 0,
			heading = 0 / 0,
			turnRate = 0 / 0,
			pitchAttitude = 0 / 0,
			bankAngle = 0 / 0,
			lateralAcceleration = 0 / 0,
		})
		local r = built.airspeed.needle.Rotation
		record(
			"NaN telemetry parks the panel instead of making it vanish",
			r == r and built.attitude.horizonLine.Rotation == 0,
			"every needle still has a finite rotation"
		)

		--[[
			THE PANEL-WIDE CONTAINMENT CHECK. Nothing may reach outside its own
			dial, because ClipsDescendants cannot trim a rotated element (see
			Instrument.buildHorizon) and six gauges sit 8 px apart. One escapee
			lands on its neighbour's face and reads as that instrument's needle.
		]]
		SixPack.render(built, telemetry)
		local overflow = {}
		for _, gauge in { built.airspeed, built.altimeter, built.turn, built.heading, built.vsi } do
			for _, n in gauge.needles do
				-- The rotating pivot is centred on the hub, so its half-diagonal
				-- is the furthest any part of it can reach at any angle.
				local halfW = n.frame.Size.X.Offset * 0.5
				local halfH = n.frame.Size.Y.Offset * 0.5
				local reach = math.sqrt(halfW * halfW + halfH * halfH)
				if reach > DIAL_SIZE * 0.5 + 1.5 then
					table.insert(overflow, string.format("%s.%s %.0f px", gauge.spec.name, n.name, reach))
				end
			end
		end
		record(
			"No needle can sweep outside its own dial",
			#overflow == 0,
			if #overflow == 0 then string.format("all within a %.0f px radius", DIAL_SIZE * 0.5)
			else table.concat(overflow, ", ")
		)

		--[[
			5b. THE PANEL MUST WORK OFF A SCREEN.

			The instruments are going to live on a real panel inside the Cessna,
			which in Roblox is a SurfaceGui on a part. So the panel is built into
			one here and driven, which proves it carries no screen-space
			assumption - no viewport, no GUI inset, no camera. If this ever fails,
			something screen-specific has leaked out of SixPack.build() and into
			buildPanel(), and the 3D cockpit has just become a rewrite.
		]]
		local board = Instance.new("Part")
		board.Size = Vector3.new(6, 3, 0.2)
		board.Anchored = true
		board.Parent = holder

		local surface = Instance.new("SurfaceGui")
		surface.Face = Enum.NormalId.Front
		surface.Parent = board

		local surfaceOk, surfaceErr = pcall(function()
			local surfacePanel, surfaceBuilt = SixPack.buildPanel(surface)
			SixPack.render(surfaceBuilt, {
				airspeedIndicated = Units.knotsToMs(110),
				altitude = Units.feetToMeters(3200),
				verticalSpeed = 0,
				heading = math.rad(270),
				turnRate = 0,
				pitchAttitude = 0,
				bankAngle = 0,
				lateralAcceleration = 0,
				rpm = 2400,
				fuelKg = Cessna172.engine.fuelCapacityKg,
			})
			local surfaceKt = SixPack.samplers.airspeedKt({ airspeedIndicated = Units.knotsToMs(110) })
			record(
				"The panel builds and drives inside a SurfaceGui, not just a ScreenGui",
				surfacePanel.Parent == surface
					and math.abs(surfaceBuilt.airspeed.needle.Rotation - Instrument.angleFor(SixPack.ASI, surfaceKt)) < 1e-3,
				"the 3D panel needs no rewrite of this module"
			)
			record(
				"The panel frame carries no scale-based positioning of its own",
				surfacePanel.Size.X.Scale == 0 and surfacePanel.Size.Y.Scale == 0,
				string.format("%d x %d px, fixed", surfacePanel.Size.X.Offset, surfacePanel.Size.Y.Offset)
			)
		end)
		if not surfaceOk then
			record("The panel builds inside a SurfaceGui", false, tostring(surfaceErr))
		end

		--[[
			5c. AND IT MOUNTS ON THE COCKPIT'S OWN BOARD.

			`mountOnPart` is the one-call version the cockpit uses. It is checked
			against the REAL board out of the definition rather than a made-up
			part, because the thing that can silently go wrong is the board's
			SHAPE: a SurfaceGui maps a fixed-pixel frame onto the face, so if the
			part's aspect ratio does not match the frame's, every circular dial
			renders as an oval and nothing errors.
		]]
		local boardSpec
		for _, spec in Cessna172.model.decorations do
			if spec.name == "PanelBoard" then
				boardSpec = spec
			end
		end
		record(
			"The cockpit defines a panel board to mount on",
			boardSpec ~= nil,
			boardSpec and string.format("%.2f x %.2f m", boardSpec.size.X, boardSpec.size.Y) or "no PanelBoard"
		)
		if boardSpec then
			local cockpitBoard = Instance.new("Part")
			cockpitBoard.Size = boardSpec.size
			cockpitBoard.Anchored = true
			cockpitBoard.Parent = holder

			local mountOk, mountErr = pcall(function()
				local mountedGui, mountedPanel, mountedBuilt = SixPack.mountOnPart(cockpitBoard)
				SixPack.render(mountedBuilt, telemetry)

				record(
					"The six-pack mounts on the cockpit panel board",
					mountedGui:IsA("SurfaceGui")
						and mountedGui.Adornee == cockpitBoard
						and mountedPanel.Parent == mountedGui,
					string.format("SurfaceGui on the %s face", mountedGui.Face.Name)
				)
				--[[
					⚠️ A DIAL IS ONLY ROUND IF THE BOARD IS THE FRAME'S SHAPE.
					Asserted to 1%, which is far tighter than an eye would catch
					but loose enough to survive rounding the board to centimetres.
				]]
				local frameAspect = mountedPanel.Size.X.Offset / mountedPanel.Size.Y.Offset
				local boardAspect = cockpitBoard.Size.X / cockpitBoard.Size.Y
				record(
					"The board's aspect ratio matches the panel's, so dials stay round",
					math.abs(frameAspect - boardAspect) / frameAspect < 0.01,
					string.format("board %.4f against frame %.4f", boardAspect, frameAspect)
				)
				record(
					"The mounted panel faces the pilot",
					mountedGui.Face == Enum.NormalId.Back,
					"the +Z face, which is aft - the pilot flies facing -Z"
				)
			end)
			if not mountOk then
				record("The six-pack mounts on the cockpit panel board", false, tostring(mountErr))
			end
		end

		-- 6. The engine cluster, driven ---------------------------------------
		telemetry.rpm = 2400
		telemetry.fuelKg = Cessna172.engine.fuelCapacityKg * 0.5
		telemetry.airspeedIndicated = Units.knotsToMs(95)
		SixPack.render(built, telemetry)

		record(
			"The tachometer points where 2400 rpm belongs",
			math.abs(built.tachometer.needle.Rotation - Instrument.angleFor(SixPack.TACHOMETER, 2400)) < 1e-3,
			string.format("%.1f deg at 2400 rpm", built.tachometer.needle.Rotation)
		)
		record(
			"Half tanks put the fuel needle at the 1/2 mark",
			math.abs(built.fuel.needle.Rotation - Instrument.angleFor(SixPack.FUEL, Cessna172.engine.fuelCapacityKg / 2)) < 1e-3,
			string.format("%.1f deg", built.fuel.needle.Rotation)
		)

		--[[
			Dry tanks and a dead engine must read at the bottom of both scales,
			not somewhere in the middle. This is the state the aircraft spawns
			in, so it is the reading the pilot sees most often.
		]]
		telemetry.rpm = 0
		telemetry.fuelKg = 0
		SixPack.render(built, telemetry)
		record(
			"Engine stopped and tanks dry both read empty",
			math.abs(built.tachometer.needle.Rotation - Instrument.angleFor(SixPack.TACHOMETER, 0)) < 1e-3
				and math.abs(built.fuel.needle.Rotation - Instrument.angleFor(SixPack.FUEL, 0)) < 1e-3,
			"both needles on their bottom stops"
		)

		gui:Destroy()
	end)

	holder:Destroy()

	if not ok then
		allPassed = false
		record("Suite completed without erroring", false, tostring(err))
	end

	local passCount = 0
	for _, res in results do
		if res.passed then
			passCount += 1
		end
	end
	print(string.format("=== %s (%d/%d) ===", allPassed and "ALL PASSED" or "FAILURES PRESENT", passCount, #results))

	return allPassed, results
end

return SixPack
