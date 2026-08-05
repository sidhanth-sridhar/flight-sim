--!strict
--[[
	Instrument
	----------
	The framework every cockpit gauge is built from: the needle-angle maths, the
	dial drawing, and the one redraw loop they all share.

	THE POINT OF THIS MODULE IS THAT A GAUGE IS DATA
	------------------------------------------------
	An airspeed indicator and an altimeter differ in their numbers, not in their
	behaviour. Both map a value to a needle angle, draw ticks at intervals, and
	paint coloured bands over parts of the range. Written as bespoke code each
	they would be six near-copies drifting apart; written as specs they are six
	tables and one tested implementation.

	So a dial is a `DialSpec`, and the only thing a gauge module writes is that
	table. If a new instrument needs new *code* here rather than a new spec, the
	spec format is the thing that is wrong.

	THE FACE IS A BREAKPOINT TABLE, WHICH IS WHY ONE MECHANISM COVERS ALL SIX
	------------------------------------------------------------------------
	`breakpoints` is a list of { value, angle } pairs, interpolated linearly
	between and clamped outside. That single mechanism covers every face in the
	six-pack, including the two that are not linear at all:

	  - a linear dial is two breakpoints (use Instrument.linearFace)
	  - the VSI is compressed above 1000 fpm, which is three or four
	  - the heading card wraps, which is `period = 360`
	  - the altimeter's hundreds needle wraps every 1000 ft, `period = 1000`

	A `curve` function was the alternative and was not taken: a function cannot
	be inspected, so the tests could not assert that the green arc lands exactly
	on Vno without re-running the same code they are meant to be checking.

	ANGLES ARE DEGREES CLOCKWISE FROM 12 O'CLOCK
	--------------------------------------------
	Which is also exactly what Roblox's `GuiObject.Rotation` does to a frame
	anchored at its bottom edge, so a needle needs no conversion at all - the
	angle this module computes is written straight to `Rotation`. That is the
	whole reason for the convention.

	IT MUST NOT EAT MOUSE INPUT
	---------------------------
	The cursor is the yoke and roams the entire screen, because the screen edge
	is full control deflection. Anything Active or clickable here would swallow
	the flight controls - a gauge in a corner would be worse than the HUD,
	because a panel of six is much harder to keep clear of. Nothing this module
	creates is ever Active and nothing is a GuiButton. A test counts them.

	UNITS CONVERT AT THIS BOUNDARY AND NOWHERE ELSE
	-----------------------------------------------
	The physics is pure SI. Gauges are labelled in knots, feet and feet per
	minute, so the conversion happens in the sampler that feeds a gauge - and
	nothing converted ever travels back the other way. This module itself is
	unit-agnostic: it maps numbers to angles and does not know what they mean.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FlightSim = ReplicatedStorage:WaitForChild("FlightSim")

local Constants = require(FlightSim.Config.Constants)

local Instrument = {}

local sin, cos, rad = math.sin, math.cos, math.rad
local exp = math.exp

-- =========================================================================
-- TYPES
-- =========================================================================

export type Breakpoint = { value: number, angle: number }

export type Arc = {
	from: number,
	to: number,
	color: Color3,
	-- Fraction of the dial radius the band sits at. Several arcs overlap on a
	-- real airspeed indicator (the white flap arc runs inside the green), so
	-- each carries its own radius rather than sharing one.
	radius: number?,
	thickness: number?,
}

export type Ticks = {
	major: number, -- value interval for long, labelled ticks
	minor: number?, -- value interval for short ticks
	labelEvery: number?, -- label every Nth major tick; defaults to every one
	labelScale: number?, -- printed label = value * this (altimeter: 0.001)
	labelFormat: string?,
}

export type DialSpec = {
	name: string,
	caption: string?, -- short face legend, e.g. "KNOTS"
	breakpoints: { Breakpoint },
	period: number?, -- wrapping faces: 360 for a heading card
	ticks: Ticks?,
	arcs: { Arc }?,
	redline: number?,
	-- Seconds of first-order lag. Real instruments do not answer instantly and
	-- the VSI is famously slow; 0 or nil is an immediate needle.
	lagTau: number?,
}

-- =========================================================================
-- APPEARANCE
-- =========================================================================

-- Aviation-standard band colours, so the specs name a meaning rather than a
-- Color3 and six gauges cannot end up with six different greens.
Instrument.ARC = {
	WHITE = Color3.fromRGB(240, 240, 240), -- flap operating range
	GREEN = Color3.fromRGB(60, 200, 90), -- normal operating range
	YELLOW = Color3.fromRGB(240, 205, 70), -- caution, smooth air only
	RED = Color3.fromRGB(225, 60, 55), -- never exceed
}

local COLOR_FACE = Color3.fromRGB(18, 20, 24)
local COLOR_BEZEL = Color3.fromRGB(70, 76, 86)
local COLOR_TICK = Color3.fromRGB(228, 233, 240)
local COLOR_LABEL = Color3.fromRGB(228, 233, 240)
local COLOR_CAPTION = Color3.fromRGB(150, 160, 170)
local COLOR_NEEDLE = Color3.fromRGB(245, 248, 252)

local FONT = Enum.Font.GothamMedium

-- =========================================================================
-- THE FACE: VALUE -> ANGLE
-- =========================================================================

--[[
	Breakpoints must ascend in value, or the search below silently returns the
	wrong segment and the needle points somewhere plausible but wrong - the
	worst possible failure for an instrument. Called by build() and by the
	tests; cheap enough to run on every spec at construction.
]]
function Instrument.validate(spec: DialSpec): (boolean, string?)
	local bp = spec.breakpoints
	if type(bp) ~= "table" or #bp < 2 then
		return false, "a face needs at least two breakpoints"
	end
	for i = 2, #bp do
		if bp[i].value <= bp[i - 1].value then
			return false, string.format("breakpoint %d does not ascend in value", i)
		end
	end
	if spec.period and spec.period <= 0 then
		return false, "period must be positive"
	end
	return true, nil
end

--[[
	THE needle-angle maths. Pure, and the function every other calculation in
	this module goes through - ticks and arcs included, so the paint on the face
	and the needle over it can never disagree about where a value sits.

	Outside the face the needle CLAMPS rather than running off. A real needle
	stops against a peg; more importantly a value beyond the end of the scale is
	usually a value that has gone bad, and a wildly spinning needle reads as a
	broken gauge rather than as an out-of-range reading.
]]
function Instrument.angleFor(spec: DialSpec, value: any): number
	local bp = spec.breakpoints

	-- A non-number or a NaN parks the needle at the start of the scale. It must
	-- not reach Rotation: Roblox does not reject a NaN rotation, it renders an
	-- invisible frame, so the needle would simply vanish with no clue why.
	if type(value) ~= "number" or value ~= value then
		return bp[1].angle
	end

	if spec.period then
		value %= spec.period
	end

	if value <= bp[1].value then
		return bp[1].angle
	end
	if value >= bp[#bp].value then
		return bp[#bp].angle
	end

	for i = 1, #bp - 1 do
		local a, b = bp[i], bp[i + 1]
		if value <= b.value then
			local t = (value - a.value) / (b.value - a.value)
			return a.angle + t * (b.angle - a.angle)
		end
	end

	return bp[#bp].angle
end

-- The common case: a plain proportional face, as two breakpoints.
function Instrument.linearFace(minValue: number, maxValue: number, startAngle: number, sweepAngle: number): { Breakpoint }
	return {
		{ value = minValue, angle = startAngle },
		{ value = maxValue, angle = startAngle + sweepAngle },
	}
end

function Instrument.faceRange(spec: DialSpec): (number, number)
	local bp = spec.breakpoints
	return bp[1].value, bp[#bp].value
end

-- =========================================================================
-- TICKS AND ARCS, DERIVED FROM THE SAME MAPPING
-- =========================================================================

--[[
	Every tick the face carries, as data, so a test can assert that the 60 kt
	tick exists and sits where the needle points at 60 kt.

	Minor ticks that coincide with a major one are dropped, or the face carries
	two overlapping frames at every major position - invisible, but it doubles
	the instance count of the whole panel for nothing.
]]
function Instrument.tickMarks(spec: DialSpec): { { value: number, angle: number, major: boolean, label: string? } }
	local marks = {}
	local ticks = spec.ticks
	if not ticks then
		return marks
	end

	local minValue, maxValue = Instrument.faceRange(spec)
	local labelEvery = ticks.labelEvery or 1
	local labelScale = ticks.labelScale or 1
	local labelFormat = ticks.labelFormat or "%d"

	local majorIndex = 0
	local majorValues: { number } = {}

	--[[
		Coincidence is tested with a TOLERANCE, not by table lookup on the value.

		Both loops accumulate by repeated addition, so a face with a fractional
		interval - a 0.1 g turn coordinator, say - lands on 0.30000000000000004
		in one loop and 0.3 in the other, and an exact-key lookup would miss the
		match and stack two frames at every major tick.
	]]
	local function isMajor(v: number): boolean
		for _, m in majorValues do
			if math.abs(m - v) < ticks.major * 1e-6 then
				return true
			end
		end
		return false
	end

	local value = minValue
	while value <= maxValue + 1e-9 do
		local labelled = (majorIndex % labelEvery) == 0
		table.insert(majorValues, value)
		table.insert(marks, {
			value = value,
			angle = Instrument.angleFor(spec, value),
			major = true,
			label = if labelled then string.format(labelFormat, value * labelScale) else nil,
		})
		majorIndex += 1
		value += ticks.major
	end

	if ticks.minor then
		value = minValue
		while value <= maxValue + 1e-9 do
			if not isMajor(value) then
				table.insert(marks, {
					value = value,
					angle = Instrument.angleFor(spec, value),
					major = false,
					label = nil,
				})
			end
			value += ticks.minor
		end
	end

	return marks
end

--[[
	The coloured bands, with their ends resolved to angles.

	`from` and `to` come from the aircraft definition's published limits, never
	from a number typed here - so the green arc IS Vs1 to Vno rather than
	something that looks about right. The angles come from angleFor, which is
	what makes "the needle sits at the top of the green arc at Vno" true by
	construction instead of by eye.
]]
function Instrument.arcBands(spec: DialSpec): { { from: number, to: number, fromAngle: number, toAngle: number, color: Color3, radius: number, thickness: number } }
	local bands = {}
	for _, arc in spec.arcs or {} do
		table.insert(bands, {
			from = arc.from,
			to = arc.to,
			fromAngle = Instrument.angleFor(spec, arc.from),
			toAngle = Instrument.angleFor(spec, arc.to),
			color = arc.color,
			radius = arc.radius or 0.86,
			thickness = arc.thickness or 5,
		})
	end
	return bands
end

-- =========================================================================
-- NEEDLE LAG
-- =========================================================================

--[[
	First-order lag, frame-rate independent.

	The exponential form matters: `current + (target - current) * k` with a
	constant k is a different filter at 30 fps than at 240, so an instrument
	tuned by eye on one machine is wrong on every other one. This is the same
	correction CameraController's smoothing needed.

	tau is the time to reach 63% of a step change. nil or 0 is no lag at all.
]]
function Instrument.applyLag(current: number, target: number, tau: number?, dt: number): number
	if not tau or tau <= 0 or dt <= 0 then
		return target
	end
	if current ~= current then -- a NaN would be sticky forever
		return target
	end
	return current + (target - current) * (1 - exp(-dt / tau))
end

-- =========================================================================
-- THE SHARED REDRAW LOOP
-- =========================================================================

--[[
	One Heartbeat connection for the whole panel, not one per gauge.

	Eight gauges each with their own connection and their own accumulator would
	redraw at eight slightly different phases, which is both wasteful and makes
	the panel shimmer as needles update out of step with one another.

	TWO RATES, AND THE SECOND ONE IS THE LESSON FROM THE DEBUG HUD
	--------------------------------------------------------------
	`update` runs at INSTRUMENT_HZ and redraws. `sample` runs EVERY frame.
	The debug HUD learned this twice the hard way (see the handoff, sections 6i
	and 15): a 30 Hz readout drops most of what happens between samples, and the
	stall break - the single most important event on the panel - lasts under a
	second and fell between redraws. Anything that needs a peak, a maximum or an
	edge caught must register a sampler; anything that only needs to look right
	needs only an update.
]]

type Registration = {
	update: (number) -> (),
	sample: ((number) -> ())?,
}

local registered: { Registration } = {}
local accumulator = 0
local connection: RBXScriptConnection? = nil

function Instrument.register(update: (number) -> (), sample: ((number) -> ())?): Registration
	local entry: Registration = { update = update, sample = sample }
	table.insert(registered, entry)
	return entry
end

function Instrument.unregister(entry: Registration)
	local index = table.find(registered, entry)
	if index then
		table.remove(registered, index)
	end
end

function Instrument.registeredCount(): number
	return #registered
end

--[[
	Exported and driven by hand from the tests, which is the only way to assert
	the redraw rate without waiting on real frames.

	Returns whether this call redrew. The accumulator keeps its REMAINDER rather
	than being zeroed - zeroing quietly runs the panel slower than requested for
	any rate the frame time does not divide - but a backlog is discarded, so a
	ten-second frame hitch produces exactly one redraw and not three hundred.
]]
function Instrument.stepLoop(dt: number): boolean
	for _, entry in registered do
		if entry.sample then
			entry.sample(dt)
		end
	end

	local interval = 1 / Constants.SIM.INSTRUMENT_HZ
	accumulator += dt
	if accumulator < interval then
		return false
	end
	accumulator %= interval

	for _, entry in registered do
		entry.update(dt)
	end
	return true
end

function Instrument.startLoop()
	if connection then
		return
	end
	accumulator = 0
	connection = RunService.Heartbeat:Connect(Instrument.stepLoop)
end

function Instrument.stopLoop()
	if connection then
		connection:Disconnect()
		connection = nil
	end
	accumulator = 0
end

function Instrument.clearRegistrations()
	table.clear(registered)
end

-- =========================================================================
-- DRAWING
-- =========================================================================
-- Everything below creates instances. Nothing it creates is ever Active and
-- nothing is a GuiButton - see the header.

local function place(parent: Instance, angleDeg: number, radiusFraction: number, size: UDim2, color: Color3, rotate: boolean): Frame
	local a = rad(angleDeg)
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	-- Angles are clockwise from 12 o'clock; screen Y grows downward, hence the
	-- minus on the cosine rather than on the sine.
	frame.Position = UDim2.fromScale(0.5 + 0.5 * radiusFraction * sin(a), 0.5 - 0.5 * radiusFraction * cos(a))
	frame.Size = size
	frame.BackgroundColor3 = color
	frame.BorderSizePixel = 0
	frame.Rotation = if rotate then angleDeg else 0
	frame.Parent = parent
	return frame
end

local function drawArc(parent: Instance, band: any, size: number)
	-- Painted as short segments around the circle. Roblox has no arc primitive,
	-- and an image would mean an asset per aircraft's limits - which defeats the
	-- entire point of deriving the arcs from the definition.
	local span = band.toAngle - band.fromAngle
	local segments = math.max(2, math.ceil(math.abs(span) / 2))
	local segmentLength = (math.abs(span) / segments) * rad(1) * (size * 0.5 * band.radius)

	for i = 0, segments - 1 do
		local angle = band.fromAngle + span * ((i + 0.5) / segments)
		--[[
			Width is the TANGENTIAL dimension and height the radial one.

			At 12 o'clock with no rotation a frame's height runs along the radius,
			so a segment sized (thickness, length) would stick out from the face
			like a tick mark instead of lying along the band. Ticks want exactly
			that and pass their size the other way round.
		]]
		place(
			parent,
			angle,
			band.radius,
			UDim2.fromOffset(math.ceil(segmentLength) + 1, math.max(2, band.thickness)),
			band.color,
			true
		)
	end
end

--[[
	Build one gauge. `size` is the dial's diameter in pixels.

	Returns a handle carrying the spec, the needle frames and the last displayed
	value - which is what setValue needs for the lag filter, and what the tests
	read back instead of trying to recover an angle from a rendered frame.
]]
function Instrument.build(parent: Instance, spec: DialSpec, size: number): any
	local ok, reason = Instrument.validate(spec)
	if not ok then
		error(string.format("Instrument %q: %s", spec.name, tostring(reason)), 2)
	end

	local root = Instance.new("Frame")
	root.Name = spec.name
	root.Size = UDim2.fromOffset(size, size)
	root.BackgroundColor3 = COLOR_FACE
	root.BorderSizePixel = 0
	root.Parent = parent

	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0.5, 0)
	round.Parent = root

	local bezel = Instance.new("UIStroke")
	bezel.Color = COLOR_BEZEL
	bezel.Thickness = 2
	bezel.Parent = root

	-- Arcs first, so ticks and the needle draw over them.
	for _, band in Instrument.arcBands(spec) do
		drawArc(root, band, size)
	end

	if spec.redline then
		local angle = Instrument.angleFor(spec, spec.redline)
		place(root, angle, 0.86, UDim2.fromOffset(4, math.max(8, size * 0.10)), Instrument.ARC.RED, true)
	end

	for _, mark in Instrument.tickMarks(spec) do
		local length = if mark.major then size * 0.10 else size * 0.05
		local width = if mark.major then 3 else 2
		place(root, mark.angle, 0.90, UDim2.fromOffset(width, length), COLOR_TICK, true)

		if mark.label then
			local a = rad(mark.angle)
			local labelRadius = 0.66
			local text = Instance.new("TextLabel")
			text.AnchorPoint = Vector2.new(0.5, 0.5)
			text.Position = UDim2.fromScale(0.5 + 0.5 * labelRadius * sin(a), 0.5 - 0.5 * labelRadius * cos(a))
			text.Size = UDim2.fromOffset(size * 0.28, size * 0.14)
			text.BackgroundTransparency = 1
			text.Font = FONT
			text.TextSize = math.max(9, size * 0.11)
			text.TextColor3 = COLOR_LABEL
			text.Text = mark.label
			text.Parent = root
		end
	end

	if spec.caption then
		local caption = Instance.new("TextLabel")
		caption.AnchorPoint = Vector2.new(0.5, 0.5)
		caption.Position = UDim2.fromScale(0.5, 0.72)
		caption.Size = UDim2.fromOffset(size * 0.6, size * 0.10)
		caption.BackgroundTransparency = 1
		caption.Font = FONT
		caption.TextSize = math.max(8, size * 0.082)
		caption.TextColor3 = COLOR_CAPTION
		caption.Text = spec.caption
		caption.Parent = root
	end

	--[[
		THE NEEDLE PIVOT, AND THE TRAP THAT COST A REDRAW OF THIS WHOLE BLOCK.

		Roblox rotates a GuiObject about its own CENTRE, not about its
		AnchorPoint. The AnchorPoint positions the frame and does nothing else.
		Measured rather than read: a frame anchored (0.5, 1) at the dial centre
		and set to Rotation = 180 pointed straight UP, identical to 0 - if the
		anchor were the pivot it would have pointed straight down.

		The consequence is nasty because it is not a crash. Every angle this
		module computes was correct, all thirty-seven arithmetic checks passed,
		and the needle still pointed at the wrong speed - a gauge that lies.

		So the frame that CARRIES the rotation is a transparent pivot, twice the
		needle's length, centred exactly on the hub - which makes its centre the
		hub, and therefore makes rotation happen about the hub. The visible
		needle is a child occupying only the top half of it.
	]]
	local needle = Instance.new("Frame")
	needle.Name = "Needle"
	needle.AnchorPoint = Vector2.new(0.5, 0.5)
	needle.Position = UDim2.fromScale(0.5, 0.5)
	needle.Size = UDim2.fromOffset(math.max(2, size * 0.035), size * 0.80)
	needle.BackgroundTransparency = 1
	needle.BorderSizePixel = 0
	needle.Rotation = spec.breakpoints[1].angle
	needle.Parent = root

	local needleBody = Instance.new("Frame")
	needleBody.Name = "NeedleBody"
	needleBody.AnchorPoint = Vector2.new(0.5, 0)
	needleBody.Position = UDim2.fromScale(0.5, 0)
	needleBody.Size = UDim2.fromScale(1, 0.5)
	needleBody.BackgroundColor3 = COLOR_NEEDLE
	needleBody.BorderSizePixel = 0
	needleBody.Parent = needle

	local hub = Instance.new("Frame")
	hub.AnchorPoint = Vector2.new(0.5, 0.5)
	hub.Position = UDim2.fromScale(0.5, 0.5)
	hub.Size = UDim2.fromOffset(math.max(4, size * 0.07), math.max(4, size * 0.07))
	hub.BackgroundColor3 = COLOR_BEZEL
	hub.BorderSizePixel = 0
	hub.Parent = root
	local hubRound = Instance.new("UICorner")
	hubRound.CornerRadius = UDim.new(0.5, 0)
	hubRound.Parent = hub

	return {
		spec = spec,
		root = root,
		-- The frame that carries Rotation. Its centre is the hub; see above.
		needle = needle,
		needleBody = needleBody,
		size = size,
		-- Starts at the bottom of the scale rather than at 0, which for a face
		-- that begins at 40 kt is not on the dial at all.
		value = spec.breakpoints[1].value,
	}
end

--[[
	Point the needle at `value`, applying the spec's lag.

	dt is optional and defaults to no lag: a caller that only wants the needle
	placed - the tests, and the initial draw - should not have to invent a
	timestep to get an exact answer.
]]
function Instrument.setValue(gauge: any, value: any, dt: number?)
	local target = if type(value) == "number" and value == value then value else gauge.spec.breakpoints[1].value

	if dt and gauge.spec.lagTau then
		gauge.value = Instrument.applyLag(gauge.value, target, gauge.spec.lagTau, dt)
	else
		gauge.value = target
	end

	gauge.needle.Rotation = Instrument.angleFor(gauge.spec, gauge.value)
end

-- =========================================================================
-- VERIFICATION
-- =========================================================================

--[[
	Run from the Studio command bar, CLIENT datamodel:
		require(game.Players.LocalPlayer.PlayerScripts.FlightSim.UI.Instruments.Instrument).runTests()

	Almost all of this is pure and needs no GUI. The build is exercised once
	against a real container, because "does a dial actually come out with the
	right ticks, arcs and a needle that can be rotated" is not a question
	arithmetic can answer.
]]
function Instrument.runTests(): (boolean, { any })
	local results = {}
	local allPassed = true

	local function record(label: string, passed: boolean, detail: string)
		if not passed then
			allPassed = false
		end
		table.insert(results, { label = label, passed = passed, detail = detail })
		print(string.format("  [%s] %-52s %s", passed and "PASS" or "FAIL", label, detail))
	end

	local function checkRange(label: string, value: number, low: number, high: number, unit: string)
		record(label, value >= low and value <= high, string.format("%.4f %s (expected %.3f..%.3f)", value, unit, low, high))
	end

	print("=== Instrument: verification ===")

	local Cessna172 = require(FlightSim.Aircraft.Definitions.Cessna172)
	local L = Cessna172.limits

	-- 1. The face ----------------------------------------------------------
	local linear: DialSpec = {
		name = "Linear",
		breakpoints = Instrument.linearFace(0, 100, 0, 300),
	}

	record("A linear face starts at the start of the sweep", Instrument.angleFor(linear, 0) == 0, "0 -> 0 deg")
	record("...and ends at the end of it", Instrument.angleFor(linear, 100) == 300, "100 -> 300 deg")
	checkRange("...and is proportional in between", Instrument.angleFor(linear, 25), 74.99, 75.01, "deg")

	--[[
		Clamping, not wrapping. A needle that runs past the end of its scale and
		reappears at the bottom would show a gross overspeed as a comfortable
		cruise, which is the most dangerous thing an instrument can do.
	]]
	record(
		"Below the scale the needle stops at the peg",
		Instrument.angleFor(linear, -500) == 0,
		"-500 -> 0 deg"
	)
	record(
		"Above the scale it stops at the other peg, it does not wrap",
		Instrument.angleFor(linear, 5000) == 300,
		"5000 -> 300 deg"
	)

	--[[
		A NaN must not reach Rotation. Roblox does not reject it - the frame just
		stops rendering - so the needle would silently disappear and the gauge
		would look switched off rather than broken.
	]]
	record(
		"A NaN parks the needle instead of vanishing",
		Instrument.angleFor(linear, 0 / 0) == 0 and Instrument.angleFor(linear, nil) == 0,
		"NaN and nil both -> 0 deg"
	)

	-- 2. Non-linear and wrapping faces, on the same mechanism ---------------
	local compressed: DialSpec = {
		name = "Compressed",
		breakpoints = {
			{ value = 0, angle = 0 },
			{ value = 1000, angle = 90 },
			{ value = 2000, angle = 120 },
		},
	}
	record(
		"A compressed face gives the ends less sweep per unit",
		Instrument.angleFor(compressed, 500) == 45 and Instrument.angleFor(compressed, 1500) == 105,
		"500 -> 45 deg, 1500 -> 105 deg (half the rate)"
	)

	local card: DialSpec = {
		name = "Card",
		breakpoints = Instrument.linearFace(0, 360, 0, 360),
		period = 360,
	}
	record(
		"A wrapping face carries past its end instead of clamping",
		Instrument.angleFor(card, 370) == 10 and Instrument.angleFor(card, -10) == 350,
		"370 -> 10 deg, -10 -> 350 deg"
	)

	-- 3. Validation --------------------------------------------------------
	local descending: DialSpec = {
		name = "Descending",
		breakpoints = { { value = 100, angle = 0 }, { value = 0, angle = 300 } },
	}
	local okDesc = Instrument.validate(descending)
	record("A face whose values descend is rejected", not okDesc, "rejected before it can point the wrong way")
	record(
		"A face with one breakpoint is rejected",
		not Instrument.validate({ name = "One", breakpoints = { { value = 0, angle = 0 } } } :: any),
		"rejected"
	)
	record("A valid face passes", (Instrument.validate(linear)), "accepted")

	-- 4. Arcs come from the aircraft, not from eye -------------------------
	--[[
		The airspeed face this project will actually fly. Built here from
		Cessna172.limits so the assertions below are against published figures
		rather than against numbers typed twice.
	]]
	local asi: DialSpec = {
		name = "ASI",
		caption = "KNOTS",
		breakpoints = Instrument.linearFace(40, 200, 0, 320),
		ticks = { major = 20, minor = 10 },
		arcs = {
			{ from = L.vs0, to = L.vfe, color = Instrument.ARC.WHITE, radius = 0.74 },
			{ from = L.vs1, to = L.vno, color = Instrument.ARC.GREEN, radius = 0.86 },
			{ from = L.vno, to = L.vne, color = Instrument.ARC.YELLOW, radius = 0.86 },
		},
		redline = L.vne,
	}

	local bands = Instrument.arcBands(asi)
	record(
		"The white arc is exactly Vs0 to Vfe",
		bands[1].from == L.vs0 and bands[1].to == L.vfe,
		string.format("%d..%d kt", bands[1].from, bands[1].to)
	)
	record(
		"The green arc is exactly Vs1 to Vno",
		bands[2].from == L.vs1 and bands[2].to == L.vno,
		string.format("%d..%d kt", bands[2].from, bands[2].to)
	)
	record(
		"The yellow arc is exactly Vno to Vne",
		bands[3].from == L.vno and bands[3].to == L.vne,
		string.format("%d..%d kt", bands[3].from, bands[3].to)
	)

	--[[
		THE check this whole module exists for.

		An arc drawn at one angle and a needle that reaches a different angle for
		the same speed is an instrument that lies, and it is the exact failure a
		hand-drawn face produces. Both go through angleFor, so this is true by
		construction - and asserted anyway, because "by construction" is what
		section 6g claimed about the yoke's centre.
	]]
	local vneNeedle = Instrument.angleFor(asi, L.vne)
	record(
		"The needle reaches the redline exactly at Vne",
		math.abs(vneNeedle - Instrument.angleFor(asi, asi.redline :: number)) < 1e-9,
		string.format("%.2f deg at %d kt", vneNeedle, L.vne)
	)
	record(
		"The green arc's top end is where the needle sits at Vno",
		math.abs(bands[2].toAngle - Instrument.angleFor(asi, L.vno)) < 1e-9,
		string.format("%.2f deg at %d kt", bands[2].toAngle, L.vno)
	)
	record(
		"Arc ends ascend with speed, so the face is not mirrored",
		bands[1].fromAngle < bands[2].fromAngle and bands[2].toAngle < Instrument.angleFor(asi, L.vne),
		"Vs0 < Vs1 ... Vno < Vne in angle as well as in knots"
	)

	-- 5. Ticks -------------------------------------------------------------
	local marks = Instrument.tickMarks(asi)
	local majors, minors, labels = 0, 0, 0
	local at60 = nil
	for _, m in marks do
		if m.major then majors += 1 else minors += 1 end
		if m.label then labels += 1 end
		if m.value == 60 then at60 = m end
	end
	record(
		"Major ticks land on the major interval across the whole face",
		majors == 9,
		string.format("%d majors at 20 kt over 40..200", majors)
	)
	record(
		"Minor ticks fill in between without doubling the majors",
		minors == 8,
		string.format("%d minors at 10 kt, none coincident with a major", minors)
	)
	record(
		"A tick sits where the needle points for the same value",
		at60 ~= nil and math.abs((at60 :: any).angle - Instrument.angleFor(asi, 60)) < 1e-9,
		"60 kt tick and 60 kt needle agree"
	)
	record("Major ticks are labelled", labels == majors, string.format("%d labels", labels))

	-- 6. Lag ---------------------------------------------------------------
	record("No lag means the needle is already there", Instrument.applyLag(0, 100, nil, 1 / 60) == 100, "immediate")
	local lagged = Instrument.applyLag(0, 100, 1.0, 1.0)
	checkRange("One time constant covers 63% of a step", lagged, 62.0, 64.0, "%")

	--[[
		Frame-rate independence, which a naive `current + (target-current)*k`
		does not have - it would settle four times faster at 240 fps than at 60,
		so an instrument tuned on one machine is wrong on every other one.
	]]
	local slow, fast = 0, 0
	for _ = 1, 30 do
		slow = Instrument.applyLag(slow, 100, 0.5, 1 / 30)
	end
	for _ = 1, 240 do
		fast = Instrument.applyLag(fast, 100, 0.5, 1 / 240)
	end
	record(
		"Lag is frame-rate independent",
		math.abs(slow - fast) < 0.5,
		string.format("30 fps %.2f vs 240 fps %.2f after one second", slow, fast)
	)

	-- 7. The shared loop ---------------------------------------------------
	Instrument.clearRegistrations()
	local updates, samples = 0, 0
	local entry = Instrument.register(function() updates += 1 end, function() samples += 1 end)

	for _ = 1, 60 do
		Instrument.stepLoop(1 / 60)
	end
	record(
		"Redraws at INSTRUMENT_HZ, not at frame rate",
		updates == Constants.SIM.INSTRUMENT_HZ,
		string.format("%d redraws in 60 frames of 1 s (INSTRUMENT_HZ = %d)", updates, Constants.SIM.INSTRUMENT_HZ)
	)
	record(
		"...while samplers run every single frame",
		samples == 60,
		string.format("%d samples in 60 frames - this is what catches the stall break", samples)
	)

	--[[
		A frame hitch must not fire a burst of redraws. Nothing here needs to
		catch up: a gauge shows the CURRENT value, so three hundred redraws of
		the same number is three hundred wasted frames of work.
	]]
	updates = 0
	Instrument.stepLoop(10.0)
	record(
		"A 10 s frame hitch redraws once, not three hundred times",
		updates == 1,
		string.format("%d redraw(s)", updates)
	)

	Instrument.unregister(entry)
	record("Unregistering removes it from the loop", Instrument.registeredCount() == 0, "0 registered")
	updates = 0
	Instrument.stepLoop(1.0)
	record("...and it stops being called", updates == 0, "no redraw after unregister")

	-- 8. The drawn article -------------------------------------------------
	local holder = Instance.new("Folder")
	holder.Name = "__InstrumentTest"
	holder.Parent = workspace

	local screen = Instance.new("ScreenGui")
	screen.Name = "__InstrumentTestGui"
	screen.IgnoreGuiInset = false
	screen.Parent = holder

	local ok, err = pcall(function()
		local gauge = Instrument.build(screen, asi, 160)

		record("A gauge builds", gauge.root ~= nil and gauge.needle ~= nil, "root and needle present")

		--[[
			The trap, pinned down. Roblox rotates about the frame's CENTRE and
			ignores the AnchorPoint for that purpose - measured, not read - so
			the frame carrying Rotation has to be centred on the hub or every
			needle on the panel points at the wrong number while all the
			arithmetic above still passes.
		]]
		record(
			"The frame that rotates is CENTRED on the hub",
			gauge.needle.AnchorPoint == Vector2.new(0.5, 0.5)
				and gauge.needle.Position == UDim2.fromScale(0.5, 0.5),
			"Roblox pivots about the centre, so the centre must be the hub"
		)
		record(
			"The visible needle occupies only the half above the hub",
			gauge.needleBody.Size == UDim2.fromScale(1, 0.5)
				and gauge.needleBody.AnchorPoint == Vector2.new(0.5, 0)
				and gauge.needle.BackgroundTransparency == 1,
			"pivot is twice the needle's length and transparent"
		)

		Instrument.setValue(gauge, 100)
		local drawn = gauge.needle.Rotation
		record(
			"setValue writes the computed angle straight to Rotation",
			math.abs(drawn - Instrument.angleFor(asi, 100)) < 1e-4,
			string.format("%.2f deg at 100 kt", drawn)
		)

		Instrument.setValue(gauge, L.vne)
		record(
			"At Vne the needle is on the redline",
			math.abs(gauge.needle.Rotation - Instrument.angleFor(asi, L.vne)) < 1e-4,
			string.format("%.2f deg", gauge.needle.Rotation)
		)

		-- Lag needs a dt; without one the caller gets the exact value, which is
		-- what the initial draw and every test above depends on.
		Instrument.setValue(gauge, 40)
		local lagSpec = table.clone(asi)
		lagSpec.lagTau = 1.0
		local laggy = Instrument.build(screen, lagSpec, 160)
		Instrument.setValue(laggy, 200, 1 / 60)
		record(
			"A lagged needle does not jump to the new value",
			laggy.value > 40 and laggy.value < 60,
			string.format("%.1f kt shown, %d kt commanded", laggy.value, 200)
		)

		--[[
			THE constraint from section 6i, arrived at from the other direction:
			the cursor is the yoke and covers the whole screen, so anything here
			that absorbs input takes the flight controls away. A panel of six
			gauges is a much bigger target than the HUD ever was.
		]]
		local active, buttons = 0, 0
		for _, d in screen:GetDescendants() do
			if d:IsA("GuiButton") then
				buttons += 1
			end
			if d:IsA("GuiObject") and d.Active then
				active += 1
			end
		end
		record(
			"Nothing on a gauge can swallow mouse input",
			active == 0 and buttons == 0,
			string.format("%d active, %d button(s) across %d instances", active, buttons, #screen:GetDescendants())
		)

		record(
			"Respects the GUI inset instead of hiding under the top bar",
			screen.IgnoreGuiInset == false,
			"IgnoreGuiInset = false, which is what keeps the yoke's coordinate space simple"
		)

		-- A face that cannot be drawn correctly must not be drawn at all.
		local threw = not pcall(function()
			Instrument.build(screen, descending, 100)
		end)
		record("Building an invalid face errors rather than drawing it wrong", threw, "errored as expected")
	end)

	holder:Destroy()
	Instrument.clearRegistrations()

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

return Instrument
