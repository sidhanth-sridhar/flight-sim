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
	-- Label every Nth major tick; 1 (the default) labels all of them, and ZERO
	-- labels none - which the turn coordinator needs, its face carrying index
	-- marks and no numbers at all.
	labelEvery: number?,
	labelScale: number?, -- printed label = value * this (altimeter: 0.01)
	labelFormat: string?,
	labelRadius: number?, -- fraction of the dial radius, default 0.66
	--[[
		Text labels, in order, replacing the numbers on the labelled majors.

		A fuel gauge is marked E, 1/4, 1/2, 3/4, F, not 0 to 153. Matched by
		POSITION rather than keyed by value on purpose: both tick loops
		accumulate by repeated addition, so a table keyed on 38.25 would miss
		38.249999999999996 - the same float trap the major/minor coincidence
		test already had to solve.
	]]
	labelNames: { string }?,
}

--[[
	A dial may carry more than one needle, and they are geared differently.

	An altimeter is the reason: one altitude drives a hundreds needle turning
	once per 1,000 ft and a thousands needle turning once per 10,000 ft. That is
	two faces over one scale, not two instruments, and writing it as data keeps
	the altimeter a spec like everything else.

	A needle with no `breakpoints` of its own uses the dial's face, which is the
	single-needle case and needs no declaration at all.
]]
export type NeedleSpec = {
	name: string?,
	breakpoints: { Breakpoint }?,
	period: number?,
	length: number?, -- fraction of the dial RADIUS, default 0.40
	width: number?, -- fraction of the dial SIZE, default 0.035
	color: Color3?,
	lagTau: number?,
	--[[
		"bar" (default) is a pointer from the hub outward. "wings" is a small
		aeroplane seen from behind, centred on the hub, which is what a turn
		coordinator banks instead of a needle - the whole point of that
		instrument is that the symbol rolls the way the aeroplane does.
	]]
	shape: string?,
}

--[[
	The inclinometer ball, which is not a needle: it slides along a short arc
	rather than sweeping about the hub, so it gets its own element.

	`fullScale` is the lateral acceleration, in m/s^2, that puts the ball hard
	against the end of its tube.
]]
export type BallSpec = {
	fullScale: number,
	centerY: number?, -- fraction of the dial height, default 0.76
	travel: number?, -- fraction of the dial width, default 0.22
	lagTau: number?,
}

export type DialSpec = {
	name: string,
	caption: string?, -- short face legend, e.g. "KNOTS"
	captionY: number?, -- fraction of the dial height, default 0.72
	breakpoints: { Breakpoint },
	period: number?, -- wrapping faces: 360 for a heading card
	ticks: Ticks?,
	arcs: { Arc }?,
	redline: number?,
	needles: { NeedleSpec }?, -- defaults to one needle on the dial's own face
	ball: BallSpec?,
	--[[
		A direction indicator turns its CARD, not a pointer: the ticks and
		numbers rotate behind a lubber line fixed at the top, so the heading you
		are flying is always the one under the mark. A fixed card with a moving
		pointer is a different instrument and is much harder to hold a heading
		on, which is exactly what the Phase 2 gate asks for.
	]]
	rotatingCard: boolean?,
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

-- The attitude indicator's palette, and the amber used for anything that
-- represents the AEROPLANE rather than the world: the fixed aircraft symbol,
-- the bank pointer, the direction indicator's lubber line.
local COLOR_SKY = Color3.fromRGB(48, 116, 190)
local COLOR_GROUND = Color3.fromRGB(120, 78, 44)
local COLOR_SYMBOL = Color3.fromRGB(250, 190, 60)

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

	--[[
		On a face that spans exactly one period the last value IS the first -
		360 degrees is 000, 1,000 ft is where 0 ft sits - so the closing tick
		would be drawn on top of the opening one, with both labels stacked.
		Stop one step short instead.
	]]
	if spec.period and math.abs((maxValue - minValue) - spec.period) < 1e-9 then
		maxValue -= math.min(ticks.major, ticks.minor or ticks.major) * 0.5
	end

	local majorIndex = 0
	local labelIndex = 0
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
		local labelled = labelEvery > 0 and (majorIndex % labelEvery) == 0
		table.insert(majorValues, value)

		local text: string? = nil
		if labelled then
			labelIndex += 1
			if ticks.labelNames then
				-- Runs out rather than wrapping: a name list shorter than the
				-- face leaves the remaining majors unlabelled, which is a
				-- visible mistake rather than a silently repeating scale.
				text = ticks.labelNames[labelIndex]
			else
				text = string.format(labelFormat, value * labelScale)
			end
		end

		table.insert(marks, {
			value = value,
			angle = Instrument.angleFor(spec, value),
			major = true,
			label = text,
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
	WRAPPING FACES ARE NEVER LAGGED, and this is a correctness rule rather than
	a preference: filtering toward a target across the 360/000 seam makes the
	needle take the long way round the dial. Rolling out of a turn from 359 to
	001 degrees would send a lagged compass card 358 degrees backwards.

	Doing it properly means filtering the shortest angular difference, which is
	real work for no benefit here - neither the direction indicator nor the
	altimeter's wrapping needle wants lag in the first place.
]]
local function faceIsWrapping(face: any): boolean
	return face.period ~= nil
end

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

-- Angles are clockwise from 12 o'clock; screen Y grows downward, hence the
-- minus on the cosine rather than on the sine.
local function pointAt(angleDeg: number, radiusFraction: number): UDim2
	local a = rad(angleDeg)
	return UDim2.fromScale(0.5 + 0.5 * radiusFraction * sin(a), 0.5 - 0.5 * radiusFraction * cos(a))
end

local function place(parent: Instance, angleDeg: number, radiusFraction: number, size: UDim2, color: Color3, rotate: boolean): Frame
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = pointAt(angleDeg, radiusFraction)
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

	--[[
		On a direction indicator everything painted on the face rides a card
		that turns; on every other dial the face is fixed to the case. One
		variable decides which, and the drawing below is otherwise identical.

		The card is centred on the dial for the usual reason - Roblox pivots
		about a frame's centre - so its rotation is about the hub.
	]]
	local face: Instance = root
	local card: Frame? = nil
	if spec.rotatingCard then
		local c = Instance.new("Frame")
		c.Name = "Card"
		c.AnchorPoint = Vector2.new(0.5, 0.5)
		c.Position = UDim2.fromScale(0.5, 0.5)
		c.Size = UDim2.fromScale(1, 1)
		c.BackgroundTransparency = 1
		c.BorderSizePixel = 0
		c.Parent = root
		card = c
		face = c
	end

	-- Arcs first, so ticks and the needle draw over them.
	for _, band in Instrument.arcBands(spec) do
		drawArc(face, band, size)
	end

	if spec.redline then
		local angle = Instrument.angleFor(spec, spec.redline)
		place(face, angle, 0.86, UDim2.fromOffset(4, math.max(8, size * 0.10)), Instrument.ARC.RED, true)
	end

	for _, mark in Instrument.tickMarks(spec) do
		local length = if mark.major then size * 0.10 else size * 0.05
		local width = if mark.major then 3 else 2
		place(face, mark.angle, 0.90, UDim2.fromOffset(width, length), COLOR_TICK, true)

		if mark.label then
			local a = rad(mark.angle)
			local labelRadius = (spec.ticks and spec.ticks.labelRadius) or 0.66
			local text = Instance.new("TextLabel")
			text.AnchorPoint = Vector2.new(0.5, 0.5)
			text.Position = UDim2.fromScale(0.5 + 0.5 * labelRadius * sin(a), 0.5 - 0.5 * labelRadius * cos(a))
			text.Size = UDim2.fromOffset(size * 0.28, size * 0.14)
			text.BackgroundTransparency = 1
			text.Font = FONT
			text.TextSize = math.max(9, size * 0.11)
			text.TextColor3 = COLOR_LABEL
			text.Text = mark.label
			--[[
				On a card, each number is printed at its OWN angle, so that it
				stands upright at the moment it reaches the lubber line.

				The card turns by -heading, so a number at card angle t arrives at
				the top when heading = t; its screen rotation there is t + (-t) =
				0, upright. Which is why this is +angle and not -angle: the
				numbers around the rest of the card lie radially, exactly as they
				do on the real instrument.
			]]
			text.Rotation = if card then mark.angle else 0
			text.Parent = face
		end
	end

	if spec.caption then
		local caption = Instance.new("TextLabel")
		caption.AnchorPoint = Vector2.new(0.5, 0.5)
		-- Below the hub by default. The turn coordinator overrides it, because
		-- the bottom of that face belongs to the inclinometer.
		caption.Position = UDim2.fromScale(0.5, spec.captionY or 0.72)
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
	--[[
		Needles are built LAST so they draw over the face, and longest first is
		deliberately NOT done: the declaration order in the spec is the draw
		order, so a spec can put the short thousands needle over the long
		hundreds one exactly as a real altimeter does.
	]]
	-- A card instrument has no pointer: the face moves and a fixed lubber line
	-- reads it. Anything else gets one needle unless it declares more.
	local needleSpecs: { NeedleSpec } = spec.needles or (if spec.rotatingCard then {} else { {} })
	local built = {}

	for index, n in needleSpecs do
		--[[
			The effective face is MERGED, field by field, not substituted.

			An earlier version took the needle table whole if it declared
			breakpoints and the dial's otherwise, and that silently dropped the
			altimeter's hundreds needle: it declares `period = 1000` while
			reusing the dial's 0..1000 face, so "inherit the dial's face" threw
			its period away and the needle clamped at 1,000 ft instead of
			wrapping. Caught by the suite, and it was the code that was wrong.
		]]
		local face: any = {
			breakpoints = n.breakpoints or spec.breakpoints,
			period = n.period or spec.period,
		}
		local length = n.length or 0.40
		local width = n.width or 0.035

		local needle = Instance.new("Frame")
		needle.Name = n.name or (if index == 1 then "Needle" else "Needle" .. index)
		needle.AnchorPoint = Vector2.new(0.5, 0.5)
		needle.Position = UDim2.fromScale(0.5, 0.5)
		-- Twice the needle's length, so its CENTRE is the hub. See above.
		needle.Size = UDim2.fromOffset(math.max(2, size * width), size * length * 2)
		needle.BackgroundTransparency = 1
		needle.BorderSizePixel = 0
		needle.Rotation = Instrument.angleFor(face, face.breakpoints[1].value)
		needle.Parent = root

		local body
		if n.shape == "wings" then
			--[[
				A turn coordinator banks a little aeroplane rather than sweeping
				a pointer, so the symbol straddles the hub instead of radiating
				from it. The pivot frame is square here for that reason - its
				centre is still the hub, so the roll is still about the right
				point.
			]]
			needle.Size = UDim2.fromOffset(size * length * 2, size * length * 2)

			body = Instance.new("Frame")
			body.Name = "Wings"
			body.AnchorPoint = Vector2.new(0.5, 0.5)
			body.Position = UDim2.fromScale(0.5, 0.5)
			body.Size = UDim2.new(1, 0, 0, math.max(3, size * 0.035))
			body.BackgroundColor3 = n.color or COLOR_NEEDLE
			body.BorderSizePixel = 0
			body.Parent = needle

			local fin = Instance.new("Frame")
			fin.Name = "Fin"
			fin.AnchorPoint = Vector2.new(0.5, 1)
			fin.Position = UDim2.fromScale(0.5, 0.5)
			fin.Size = UDim2.fromOffset(math.max(3, size * 0.035), size * length * 0.5)
			fin.BackgroundColor3 = n.color or COLOR_NEEDLE
			fin.BorderSizePixel = 0
			fin.Parent = needle

			local nose = Instance.new("Frame")
			nose.Name = "Fuselage"
			nose.AnchorPoint = Vector2.new(0.5, 0.5)
			nose.Position = UDim2.fromScale(0.5, 0.5)
			nose.Size = UDim2.fromOffset(math.max(6, size * 0.07), math.max(6, size * 0.07))
			nose.BackgroundColor3 = n.color or COLOR_NEEDLE
			nose.BorderSizePixel = 0
			nose.Parent = needle
			local noseRound = Instance.new("UICorner")
			noseRound.CornerRadius = UDim.new(0.5, 0)
			noseRound.Parent = nose
		else
			body = Instance.new("Frame")
			body.Name = "NeedleBody"
			body.AnchorPoint = Vector2.new(0.5, 0)
			body.Position = UDim2.fromScale(0.5, 0)
			body.Size = UDim2.fromScale(1, 0.5)
			body.BackgroundColor3 = n.color or COLOR_NEEDLE
			body.BorderSizePixel = 0
			body.Parent = needle
		end

		table.insert(built, {
			name = needle.Name,
			frame = needle,
			body = body,
			face = face,
			lagTau = n.lagTau or spec.lagTau,
			value = face.breakpoints[1].value,
		})
	end

	local needle = built[1] and built[1].frame
	local needleBody = built[1] and built[1].body

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

	--[[
		The lubber line: the fixed mark a rotating card is read against. Without
		it a DI shows a heading but not YOUR heading, which is the only thing it
		is for.
	]]
	if card then
		local lubber = Instance.new("Frame")
		lubber.Name = "LubberLine"
		lubber.AnchorPoint = Vector2.new(0.5, 0)
		lubber.Position = UDim2.fromScale(0.5, 0.02)
		lubber.Size = UDim2.fromOffset(math.max(3, size * 0.035), size * 0.16)
		lubber.BackgroundColor3 = COLOR_SYMBOL
		lubber.BorderSizePixel = 0
		lubber.Parent = root
	end

	local ball, ballTube = nil, nil
	if spec.ball then
		local centerY = spec.ball.centerY or 0.76
		local travel = spec.ball.travel or 0.22

		ballTube = Instance.new("Frame")
		ballTube.Name = "BallTube"
		ballTube.AnchorPoint = Vector2.new(0.5, 0.5)
		ballTube.Position = UDim2.fromScale(0.5, centerY)
		ballTube.Size = UDim2.fromOffset(size * (travel * 2 + 0.16), size * 0.13)
		ballTube.BackgroundColor3 = Color3.fromRGB(34, 38, 44)
		ballTube.BorderSizePixel = 0
		ballTube.Parent = root
		local tubeRound = Instance.new("UICorner")
		tubeRound.CornerRadius = UDim.new(0.5, 0)
		tubeRound.Parent = ballTube

		-- The two cage lines a centred ball sits between.
		for _, side in { -1, 1 } do
			local cage = Instance.new("Frame")
			cage.AnchorPoint = Vector2.new(0.5, 0.5)
			cage.Position = UDim2.fromScale(0.5 + side * 0.14, 0.5)
			cage.Size = UDim2.fromOffset(2, size * 0.10)
			cage.BackgroundColor3 = COLOR_TICK
			cage.BorderSizePixel = 0
			cage.Parent = ballTube
		end

		ball = Instance.new("Frame")
		ball.Name = "Ball"
		ball.AnchorPoint = Vector2.new(0.5, 0.5)
		ball.Position = UDim2.fromScale(0.5, 0.5)
		ball.Size = UDim2.fromOffset(size * 0.09, size * 0.09)
		ball.BackgroundColor3 = Color3.fromRGB(30, 30, 32)
		ball.BorderSizePixel = 0
		ball.Parent = ballTube
		local ballRound = Instance.new("UICorner")
		ballRound.CornerRadius = UDim.new(0.5, 0)
		ballRound.Parent = ball
	end

	return {
		spec = spec,
		root = root,
		-- The frame that carries Rotation. Its centre is the hub; see above.
		needle = needle,
		needleBody = needleBody,
		needles = built,
		card = card,
		ball = ball,
		ballTube = ballTube,
		ballValue = 0,
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
	--[[
		A card instrument turns its face by MINUS the angle, which is what puts
		the value you are flying under the fixed lubber line at the top. A
		needle instrument turns the pointer by plus it. Same maths, opposite
		member, and a card gauge has no needle to turn.
	]]
	if gauge.card then
		local target = if type(value) == "number" and value == value then value else gauge.spec.breakpoints[1].value
		if dt and gauge.spec.lagTau and not faceIsWrapping(gauge.spec) then
			gauge.value = Instrument.applyLag(gauge.value, target, gauge.spec.lagTau, dt)
		else
			gauge.value = target
		end
		gauge.card.Rotation = -Instrument.angleFor(gauge.spec, gauge.value)
		return
	end

	for _, n in gauge.needles do
		local target = if type(value) == "number" and value == value then value else n.face.breakpoints[1].value

		if dt and n.lagTau and not faceIsWrapping(n.face) then
			n.value = Instrument.applyLag(n.value, target, n.lagTau, dt)
		else
			n.value = target
		end

		n.frame.Rotation = Instrument.angleFor(n.face, n.value)
	end

	gauge.value = gauge.needles[1].value
end

--[[
	Drive ONE needle, for the dials whose pointers read different quantities.

	The turn coordinator is the case: its aeroplane symbol answers to rate of
	turn and its ball to lateral acceleration, and neither can be derived from
	the other. An altimeter is the opposite - two needles, one altitude - and
	uses setValue.
]]
function Instrument.setNeedle(gauge: any, name: string, value: any, dt: number?)
	for _, n in gauge.needles do
		if n.name == name then
			local target = if type(value) == "number" and value == value then value else n.face.breakpoints[1].value
			if dt and n.lagTau then
				n.value = Instrument.applyLag(n.value, target, n.lagTau, dt)
			else
				n.value = target
			end
			n.frame.Rotation = Instrument.angleFor(n.face, n.value)
			return true
		end
	end
	return false
end

--[[
	Slide the inclinometer ball. `lateralAccel` is m/s^2, positive to the
	aircraft's RIGHT, exactly as FlightModel publishes it.

	THE BALL MOVES OPPOSITE TO THE ACCELERATION, and that is not a sign error.
	It is a weight in a curved tube, so it behaves like every passenger in a
	car that turns: the specific force on the AIRCRAFT points into the turn, and
	the ball slides to the OUTSIDE. That is what makes "step on the ball" the
	correct instruction - the ball falls toward the side whose rudder you need.
]]
function Instrument.setBall(gauge: any, lateralAccel: any, dt: number?)
	local ballSpec = gauge.spec.ball
	if not gauge.ball or not ballSpec then
		return false
	end

	local target = if type(lateralAccel) == "number" and lateralAccel == lateralAccel then lateralAccel else 0
	if dt and ballSpec.lagTau then
		gauge.ballValue = Instrument.applyLag(gauge.ballValue, target, ballSpec.lagTau, dt)
	else
		gauge.ballValue = target
	end

	local travel = ballSpec.travel or 0.22
	local fraction = math.clamp(-gauge.ballValue / ballSpec.fullScale, -1, 1)
	gauge.ball.Position = UDim2.fromScale(0.5 + fraction * travel, 0.5)
	return true
end

-- =========================================================================
-- THE ATTITUDE INDICATOR
-- =========================================================================

--[[
	The one instrument in the six-pack that is not a pointer, and it gets its
	own builder rather than being forced into DialSpec.

	Section 17 says that if an instrument needs new code here rather than a new
	spec, the spec format is what is wrong. This is the exception that proves
	where the line is: an attitude indicator has no needle at all. It is a
	moving horizon - a picture that translates with pitch and rotates with bank
	- and the five pointer instruments genuinely are one mechanism while this is
	genuinely a second. Torturing a breakpoint table into drawing a horizon
	would produce a worse abstraction than admitting there are two kinds.

	It still shares everything that can be shared: the same bezel, the same
	clamping discipline, the same redraw loop, and the same rule that nothing is
	Active.
]]
export type HorizonSpec = {
	name: string,
	pixelsPerDegree: number?, -- pitch scale; default sizes ~25 deg to the radius
	ladderEvery: number?, -- pitch ladder interval in degrees, default 10
	ladderTo: number?, -- highest ladder rung, default 30
	pitchLimit: number?, -- beyond this the picture stops moving, default 90
	lagTau: number?,
	-- How many chords the horizon is drawn from. More is smoother at the rim
	-- and costs one frame each; 48 is about 2.5 px per bar on a 116 px dial.
	barCount: number?,
}

function Instrument.buildHorizon(parent: Instance, spec: HorizonSpec, size: number): any
	local root = Instance.new("Frame")
	root.Name = spec.name
	root.Size = UDim2.fromOffset(size, size)
	root.BackgroundColor3 = COLOR_FACE
	root.BorderSizePixel = 0
	--[[
		Clipped, or the sky and ground - which are deliberately oversized so a
		steep bank never exposes a corner - would spill across the whole panel.
	]]
	root.ClipsDescendants = true
	root.Parent = parent

	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0.5, 0)
	round.Parent = root

	local bezel = Instance.new("UIStroke")
	bezel.Color = COLOR_BEZEL
	bezel.Thickness = 2
	bezel.Parent = root

	--[[
		THE HORIZON IS BUILT FROM CHORDS, AND THE REASON IS A HARD ROBLOX LIMIT.

		The obvious construction is an oversized sky/ground pair inside a
		rotating frame, clipped to the dial. It does not work: ClipsDescendants
		DOES NOT CLIP A ROTATED DESCENDANT. Measured three ways - a plain Frame
		clipper, a CanvasGroup clipper, and a clipper that is itself rotated -
		and all three let the rotated child escape and smear across the whole
		panel. There is no clipping route to a round attitude indicator.

		So nothing here relies on being clipped. The face is a stack of
		horizontal bars, each one a CHORD of the dial: a bar at perpendicular
		distance d from the centre is 2*sqrt(R^2 - d^2) wide, which is exactly
		the width that touches the rim and never crosses it. Rotate the stack
		and every bar is still inside the circle, because that is what a chord
		is. The bars are then coloured sky or ground according to which side of
		the horizon they fall.

		Cost is one frame per bar, positioned and recoloured at redraw. At 30 Hz
		on a 116 px dial that is cheap, and it buys a genuinely round instrument
		with no image assets and no clipping.
	]]
	local ppd = spec.pixelsPerDegree or (size * 0.5 / 25)
	local ladderEvery = spec.ladderEvery or 10
	local ladderTo = spec.ladderTo or 30

	local radius = size * 0.5
	--[[
		Bar count scales with the dial, because the stack is INSCRIBED in the
		circle and so the rim is really a polygon. A fixed count that looks
		smooth at 116 px is visibly serrated at 300 - measured by drawing one of
		each - so it is two pixels per bar at any size, bounded at both ends.
	]]
	local barCount = spec.barCount or math.clamp(math.floor(size / 2), 24, 110)
	local barThickness = (size / barCount) + 1 -- +1 so neighbours overlap, no seams

	local bars = {}
	for i = 0, barCount - 1 do
		-- Centre of this bar, in pixels from the dial's centre along the
		-- aircraft's own vertical.
		local d = ((i + 0.5) / barCount) * size - radius

		--[[
			The chord is measured at the bar's OUTER edge, not its centre, so
			the stack is inscribed in the circle rather than straddling it.
			Using the centre would let each bar's corners poke a pixel past the
			rim - which, with no clipping available, would be visible.
		]]
		local dEdge = math.abs(d) + barThickness * 0.5
		local halfChord = math.sqrt(math.max(0, radius * radius - dEdge * dEdge))

		local bar = Instance.new("Frame")
		bar.Name = string.format("Bar%02d", i)
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Position = UDim2.fromScale(0.5, 0.5)
		bar.Size = UDim2.fromOffset(math.max(1, halfChord * 2), math.ceil(barThickness))
		bar.BackgroundColor3 = if d < 0 then COLOR_SKY else COLOR_GROUND
		bar.BorderSizePixel = 0
		bar.Visible = halfChord > 0.5
		bar.Parent = root

		table.insert(bars, { frame = bar, offset = d })
	end

	--[[
		The horizon line and the pitch ladder ride the same stack. Their widths
		have to be clamped to the chord at wherever they end up, and they are
		HIDDEN once they leave the dial - with no clipping, a rung at 30 degrees
		nose-down would otherwise be drawn outside the instrument entirely.
	]]
	local horizonLine = Instance.new("Frame")
	horizonLine.Name = "HorizonLine"
	horizonLine.AnchorPoint = Vector2.new(0.5, 0.5)
	horizonLine.Position = UDim2.fromScale(0.5, 0.5)
	horizonLine.Size = UDim2.fromOffset(size, 2)
	horizonLine.BackgroundColor3 = COLOR_TICK
	horizonLine.BorderSizePixel = 0
	horizonLine.Parent = root

	local rungs = {}
	for angle = ladderEvery, ladderTo, ladderEvery do
		for _, sign in { -1, 1 } do
			local rung = Instance.new("Frame")
			rung.Name = string.format("Rung%+d", sign * angle)
			rung.AnchorPoint = Vector2.new(0.5, 0.5)
			rung.Position = UDim2.fromScale(0.5, 0.5)
			rung.Size = UDim2.fromOffset(size * (if angle % 20 == 0 then 0.30 else 0.18), 2)
			rung.BackgroundColor3 = COLOR_TICK
			rung.BorderSizePixel = 0
			rung.Parent = root

			table.insert(rungs, { frame = rung, angle = sign * angle, width = rung.Size.X.Offset })
		end
	end

	--[[
		The fixed aircraft symbol, outside the roll frame - it represents the
		aeroplane, which by definition does not move relative to the pilot. If
		this rotated, the instrument would show nothing at all.
	]]
	local symbol = Instance.new("Frame")
	symbol.Name = "AircraftSymbol"
	symbol.AnchorPoint = Vector2.new(0.5, 0.5)
	symbol.Position = UDim2.fromScale(0.5, 0.5)
	symbol.Size = UDim2.fromOffset(size * 0.44, 3)
	symbol.BackgroundColor3 = COLOR_SYMBOL
	symbol.BorderSizePixel = 0
	symbol.Parent = root

	local dot = Instance.new("Frame")
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.Size = UDim2.fromOffset(math.max(4, size * 0.045), math.max(4, size * 0.045))
	dot.BackgroundColor3 = COLOR_SYMBOL
	dot.BorderSizePixel = 0
	dot.Parent = root
	local dotRound = Instance.new("UICorner")
	dotRound.CornerRadius = UDim.new(0.5, 0)
	dotRound.Parent = dot

	-- Bank index marks, fixed to the case at the standard angles.
	for _, angle in { -60, -30, -20, -10, 0, 10, 20, 30, 60 } do
		place(
			root,
			angle,
			0.88,
			UDim2.fromOffset(2, size * (if angle % 30 == 0 then 0.11 else 0.06)),
			COLOR_TICK,
			true
		)
	end

	--[[
		The pointer that rides round the bank scale.

		A short mark repositioned around the rim, NOT a long rotated bar - a bar
		spanning the dial would sweep outside it, and with clipping unavailable
		that spill would land on the neighbouring instruments.
	]]
	local bankPointer = Instance.new("Frame")
	bankPointer.Name = "BankPointer"
	bankPointer.AnchorPoint = Vector2.new(0.5, 0.5)
	bankPointer.Position = pointAt(0, 0.74)
	bankPointer.Size = UDim2.fromOffset(math.max(3, size * 0.045), size * 0.09)
	bankPointer.BackgroundColor3 = COLOR_SYMBOL
	bankPointer.BorderSizePixel = 0
	bankPointer.Parent = root

	return {
		spec = spec,
		root = root,
		bars = bars,
		rungs = rungs,
		horizonLine = horizonLine,
		bankPointer = bankPointer,
		symbol = symbol,
		pixelsPerDegree = ppd,
		radius = radius,
		size = size,
		pitchValue = 0,
		bankValue = 0,
	}
end

--[[
	Point the horizon. Both arguments in DEGREES - this is the display side of
	the boundary, and the physics never sees them.

	Nose up moves the horizon DOWN, and bank right rotates it COUNTER-clockwise,
	because in both cases the instrument shows the world staying put while the
	aeroplane moves around it. Getting either backwards produces an instrument
	that is confidently, readably wrong, which is worse than a blank one.
]]
function Instrument.setAttitude(gauge: any, pitchDeg: any, bankDeg: any, dt: number?)
	local pitchTarget = if type(pitchDeg) == "number" and pitchDeg == pitchDeg then pitchDeg else 0
	local bankTarget = if type(bankDeg) == "number" and bankDeg == bankDeg then bankDeg else 0

	local limit = gauge.spec.pitchLimit or 90
	pitchTarget = math.clamp(pitchTarget, -limit, limit)

	if dt and gauge.spec.lagTau then
		gauge.pitchValue = Instrument.applyLag(gauge.pitchValue, pitchTarget, gauge.spec.lagTau, dt)
		gauge.bankValue = Instrument.applyLag(gauge.bankValue, bankTarget, gauge.spec.lagTau, dt)
	else
		gauge.pitchValue = pitchTarget
		gauge.bankValue = bankTarget
	end

	--[[
		The whole stack is placed by hand, because there is no rotating parent
		to inherit from - see buildHorizon for why clipping ruled that out.

		screenRot is MINUS the bank: the instrument shows the world holding
		still while the aeroplane rolls around it, and Roblox's positive
		Rotation is clockwise (verified on the airspeed dial). A local offset of
		d along the aircraft's own vertical therefore lands at
		(d*sin(bank), d*cos(bank)) on screen.
	]]
	local screenRot = -gauge.bankValue
	local b = rad(gauge.bankValue)
	local sinB, cosB = sin(b), cos(b)
	local radius = gauge.radius

	-- Where the horizon sits, in the same local units. Nose UP moves it DOWN.
	local horizonOffset = gauge.pitchValue * gauge.pixelsPerDegree

	local function placeOnStack(frame: GuiObject, d: number, nominalWidth: number?): boolean
		local halfChord = math.sqrt(math.max(0, radius * radius - d * d))
		if halfChord < 1 then
			frame.Visible = false
			return false
		end
		frame.Visible = true
		frame.Position = UDim2.new(0.5, d * sinB, 0.5, d * cosB)
		frame.Rotation = screenRot
		if nominalWidth then
			frame.Size = UDim2.fromOffset(math.min(nominalWidth, halfChord * 2), frame.Size.Y.Offset)
		end
		return true
	end

	for _, bar in gauge.bars do
		local d = bar.offset
		-- The bar's own colour is the only thing the horizon position changes:
		-- everything above the horizon line is sky, everything below is ground.
		bar.frame.BackgroundColor3 = if d < horizonOffset then COLOR_SKY else COLOR_GROUND
		bar.frame.Position = UDim2.new(0.5, d * sinB, 0.5, d * cosB)
		bar.frame.Rotation = screenRot
	end

	placeOnStack(gauge.horizonLine, horizonOffset, gauge.size)

	for _, rung in gauge.rungs do
		-- A rung for pitch angle a sits where the horizon would be if the
		-- aircraft were at that attitude.
		placeOnStack(rung.frame, horizonOffset - rung.angle * gauge.pixelsPerDegree, rung.width)
	end

	gauge.bankPointer.Position = pointAt(screenRot, 0.74)
	gauge.bankPointer.Rotation = screenRot
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

		-- 9. Two needles, one value -----------------------------------------
		--[[
			The altimeter: one altitude geared two ways. 1,500 ft must put the
			hundreds needle at the 500 position - half way round - and the
			thousands needle between 1 and 2.
		]]
		local altimeter: DialSpec = {
			name = "TwoNeedle",
			breakpoints = Instrument.linearFace(0, 1000, 0, 360),
			needles = {
				{ name = "Thousands", breakpoints = Instrument.linearFace(0, 10000, 0, 360), period = 10000, length = 0.26, width = 0.055 },
				{ name = "Hundreds", period = 1000, length = 0.42 },
			},
		}
		local alt = Instrument.build(screen, altimeter, 160)
		Instrument.setValue(alt, 1500)
		local thousands = alt.needles[1].frame.Rotation
		local hundreds = alt.needles[2].frame.Rotation
		record(
			"Two needles read one value through different gearing",
			math.abs(hundreds - 180) < 1e-4 and math.abs(thousands - 54) < 1e-4,
			string.format("1500 ft -> hundreds %.1f deg, thousands %.1f deg", hundreds, thousands)
		)
		--[[
			Inheritance is per FIELD. The hundreds needle borrows the dial's
			breakpoints while keeping its OWN period - the combination that was
			broken until the suite caught it.
		]]
		record(
			"A needle inherits the dial's face but keeps its own period",
			alt.needles[2].face.breakpoints == altimeter.breakpoints
				and alt.needles[2].face.period == 1000
				and altimeter.period == nil,
			"borrowed face, own wrapping"
		)

		Instrument.setNeedle(alt, "Hundreds", 250)
		record(
			"setNeedle drives one needle and leaves the other alone",
			math.abs(alt.needles[2].frame.Rotation - 90) < 1e-4
				and math.abs(alt.needles[1].frame.Rotation - thousands) < 1e-4,
			"hundreds moved to 90 deg, thousands unchanged"
		)

		-- 10. The inclinometer ball ------------------------------------------
		local tc: DialSpec = {
			name = "BallTest",
			breakpoints = Instrument.linearFace(-6, 6, -40, 80),
			ball = { fullScale = 3.0, travel = 0.22 },
		}
		local coordinator = Instrument.build(screen, tc, 160)

		Instrument.setBall(coordinator, 0)
		record(
			"In balance the ball is centred between the cage lines",
			coordinator.ball.Position == UDim2.fromScale(0.5, 0.5),
			"centred"
		)

		--[[
			THE sign, which is the whole meaning of the instrument. The ball is a
			weight in a curved tube, so it slides to the OUTSIDE of the turn -
			opposite to the specific force on the aircraft. That is what makes
			"step on the ball" correct, and getting it backwards would teach a
			pilot to apply exactly the wrong rudder.
		]]
		Instrument.setBall(coordinator, 1.5) -- specific force to the RIGHT
		local ballX = coordinator.ball.Position.X.Scale
		record(
			"Acceleration to the right slides the ball LEFT",
			ballX < 0.5,
			string.format("ball at %.3f for +1.5 m/s^2 to the right", ballX)
		)
		Instrument.setBall(coordinator, -1.5)
		record(
			"...and to the left slides it right, symmetrically",
			math.abs((coordinator.ball.Position.X.Scale - 0.5) + (ballX - 0.5)) < 1e-6,
			string.format("ball at %.3f", coordinator.ball.Position.X.Scale)
		)

		Instrument.setBall(coordinator, 500)
		record(
			"The ball stops at the end of its tube",
			math.abs(coordinator.ball.Position.X.Scale - (0.5 - 0.22)) < 1e-6,
			string.format("clamped at %.3f, full scale %.1f m/s^2", coordinator.ball.Position.X.Scale, tc.ball.fullScale)
		)

		-- 11. The attitude indicator ------------------------------------------
		local horizon = Instrument.buildHorizon(screen, {
			name = "AI",
			pitchLimit = 60,
		}, 160)

		Instrument.setAttitude(horizon, 0, 0)
		record(
			"Level flight puts the horizon across the middle",
			horizon.horizonLine.Position == UDim2.new(0.5, 0, 0.5, 0) and horizon.horizonLine.Rotation == 0,
			"centred and unrotated"
		)

		--[[
			Nose up must move the horizon DOWN the display - the instrument shows
			the world holding still while the aeroplane pitches around it. Up
			would be an instrument that is confidently and readably wrong, which
			is worse than a blank one.
		]]
		Instrument.setAttitude(horizon, 10, 0)
		record(
			"Nose up moves the horizon DOWN",
			horizon.horizonLine.Position.Y.Offset > 0,
			string.format("%+.1f px at 10 deg nose up", horizon.horizonLine.Position.Y.Offset)
		)
		Instrument.setAttitude(horizon, -10, 0)
		record(
			"Nose down moves it up, by the same amount",
			math.abs(horizon.horizonLine.Position.Y.Offset + 10 * horizon.pixelsPerDegree) < 1e-6,
			string.format("%+.1f px at 10 deg nose down", horizon.horizonLine.Position.Y.Offset)
		)

		--[[
			Nose up must also mean MORE SKY. The line moving is not proof the
			picture moved with it - an earlier structure had the line and the
			fill driven from different places, and this is what would catch
			them disagreeing.
		]]
		local function skyBars(): number
			local n = 0
			for _, bar in horizon.bars do
				if bar.frame.BackgroundColor3 == COLOR_SKY then
					n += 1
				end
			end
			return n
		end
		Instrument.setAttitude(horizon, -20, 0)
		local skyLow = skyBars()
		Instrument.setAttitude(horizon, 20, 0)
		local skyHigh = skyBars()
		record(
			"Pitching up fills the instrument with more sky",
			skyHigh > skyLow,
			string.format("%d sky bars at 20 up vs %d at 20 down, of %d", skyHigh, skyLow, #horizon.bars)
		)

		--[[
			Bank right rotates the horizon COUNTER-clockwise, because the horizon
			stays where it is and the aeroplane rolls. Roblox's positive Rotation
			is clockwise - verified on the working airspeed dial - so this is a
			negation and not an identity.
		]]
		Instrument.setAttitude(horizon, 0, 30)
		record(
			"Banking right rotates the horizon counter-clockwise",
			math.abs(horizon.horizonLine.Rotation + 30) < 1e-6,
			string.format("Rotation %+.1f at 30 deg of right bank", horizon.horizonLine.Rotation)
		)
		record(
			"Every bar of the picture banks together",
			horizon.bars[1].frame.Rotation == horizon.horizonLine.Rotation
				and horizon.bars[#horizon.bars].frame.Rotation == horizon.horizonLine.Rotation,
			"first and last bar agree with the horizon line"
		)
		record(
			"The bank pointer rides round with it",
			math.abs(horizon.bankPointer.Rotation - horizon.horizonLine.Rotation) < 1e-6,
			"pointer and horizon agree"
		)
		record(
			"The aircraft symbol does NOT move",
			horizon.symbol.Rotation == 0 and horizon.symbol.Position == UDim2.fromScale(0.5, 0.5),
			"fixed to the case, which is what it represents"
		)

		--[[
			THE CONTAINMENT CHECK, and the one that matters most on this
			instrument.

			ClipsDescendants does not clip rotated descendants - measured three
			ways, see buildHorizon - so nothing can be trimmed at the rim and
			every piece has to fit by its own geometry. A corner's distance from
			the dial's centre does not depend on rotation at all, so this holds
			for every bank angle at once: sqrt((w/2)^2 + (|d| + h/2)^2) <= R.

			Without this, the failure is a horizon smeared across the airspeed
			indicator and the altimeter, with no error raised anywhere.
		]]
		local worst, worstName = 0, ""
		for _, bar in horizon.bars do
			if bar.frame.Visible then
				local halfW = bar.frame.Size.X.Offset * 0.5
				local halfH = bar.frame.Size.Y.Offset * 0.5
				local corner = math.sqrt(halfW * halfW + (math.abs(bar.offset) + halfH) ^ 2)
				if corner > worst then
					worst, worstName = corner, bar.frame.Name
				end
			end
		end
		record(
			"No part of the horizon can reach outside the dial",
			worst <= horizon.radius + 1.5,
			string.format("worst corner %.1f px (%s) against a %.1f px radius", worst, worstName, horizon.radius)
		)

		--[[
			The same must hold at a steep attitude, where the pitch ladder is
			driven far off centre. Rungs leave the dial entirely and must be
			hidden rather than drawn beyond the rim.
		]]
		Instrument.setAttitude(horizon, 45, 45)
		local strayed = 0
		for _, rung in horizon.rungs do
			if rung.frame.Visible then
				local d = (horizon.pitchValue - rung.angle) * horizon.pixelsPerDegree
				local halfW = rung.frame.Size.X.Offset * 0.5
				if math.sqrt(halfW * halfW + (math.abs(d) + 1) ^ 2) > horizon.radius + 1.5 then
					strayed += 1
				end
			end
		end
		record(
			"Pitch ladder rungs hide instead of leaving the instrument",
			strayed == 0,
			string.format("%d stray rung(s) at 45 up and 45 of bank", strayed)
		)

		--[[
			Clamping is asserted on the VALUE, not on the horizon line's
			position, and the first version of this check got that wrong.

			At the 60 degree limit the horizon is 192 px from the centre of an
			80 px dial - properly off the instrument, so it hides itself and
			stops having a position at all. Reading Position there was reading
			something the code deliberately no longer writes. The state that
			actually says "clamped" is pitchValue.
		]]
		Instrument.setAttitude(horizon, 300, 0)
		record(
			"Pitch stops at the spec's limit instead of scrolling away",
			horizon.pitchValue == horizon.spec.pitchLimit,
			string.format("%.0f deg commanded 300, limit %d", horizon.pitchValue, horizon.spec.pitchLimit)
		)
		record(
			"...and a horizon that far off the dial hides rather than overhangs",
			horizon.horizonLine.Visible == false,
			"nothing drawn outside the case"
		)
		--[[
			But the picture must not go blank: past the limit the instrument
			should be showing solid sky, which is exactly what a 60 degree climb
			looks like on a real one.
		]]
		local allSky = true
		for _, bar in horizon.bars do
			if bar.frame.BackgroundColor3 ~= COLOR_SKY then
				allSky = false
			end
		end
		record(
			"Past the limit the instrument reads solid sky, not blank",
			allSky,
			string.format("all %d bars are sky at the nose-up limit", #horizon.bars)
		)
		Instrument.setAttitude(horizon, 0 / 0, 0 / 0)
		record(
			"A NaN attitude levels the instrument rather than blanking it",
			horizon.horizonLine.Position.Y.Offset == 0 and horizon.horizonLine.Rotation == 0,
			"NaN -> level"
		)
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
