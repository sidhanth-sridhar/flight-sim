--!strict
--[[
	SurfaceAnimation - the control surfaces move with the controls.

	Phase 4, scope item 2. Ailerons, elevators, rudder, flaps and the trim tab
	visibly deflect with the pilot's actual inputs, and the propeller spins
	with engine RPM.

	⚠️ THIS IS PURELY VISUAL AND MUST STAY THAT WAY.

	Every surface it drives is a massless decoration (see the skin in the
	Cessna172 definition), joined by a Motor6D rather than a weld. The flight
	model reads the pilot's control values directly and has never looked at a
	part; moving these changes nothing it computes. That is the whole reason
	the phase can model freely without re-verifying §4's published figures.

	It also reads controls rather than producing them. Nothing here writes to
	the Controls contract, so the six fields FlightModel consumes are
	untouched - this module is downstream of the input layer, in the same way
	the instruments are.

	THE SPLIT: surfaceAngle() is pure arithmetic over a hinge spec and a set
	of control values, so every sign convention below is pinned by a test
	rather than checked by looking at the aeroplane. step() is the only
	impure part, and it does nothing but write CFrames.
]]

local SurfaceAnimation = {}

--[[
	How fast a surface catches up with its commanded position, as a time
	constant in seconds.

	Real control surfaces are moved by cables and follow the yoke essentially
	instantly; flaps are driven by an electric motor and take about 8 seconds
	to run full travel. Trim is a wheel and is slower still. Smoothing the
	fast ones very slightly stops a 60 Hz control input looking like a
	vibration without introducing any lag a pilot could feel.
]]
local RESPONSE_TAU = {
	aileron = 0.05,
	elevator = 0.05,
	rudder = 0.05,
	flaps = 2.5,
	trim = 1.2,
}

--[[
	Propeller blur.

	Below IDLE_RPM the blade is drawn solid and the disc is invisible - a
	stopped or barely-turning propeller has visible blades. Above BLUR_RPM the
	blade is nearly gone and the disc carries the image.

	A solid blade at 2,400 rpm strobes against any frame rate, which is the
	one thing a real propeller never looks like. 60 Hz sampling of a 40 Hz
	rotation aliases to a slow backwards crawl, so this is not a detail that
	can be left to the renderer.
]]
local IDLE_RPM = 400
local BLUR_RPM = 1200
local BLADE_MAX_TRANSPARENCY = 0.85
local DISC_MIN_TRANSPARENCY = 0.72

local TAU = math.pi * 2

local function clamp(v: number, lo: number, hi: number): number
	return math.max(lo, math.min(hi, v))
end

--[[
	The angle a hinged surface should sit at, in RADIANS.

	`sources` carries the driving values, all in the same signs the Controls
	contract uses: roll/pitch/yaw in -1..1, flaps 0..1, trim -1..1.

	SIGN CONVENTIONS, all of which are tested rather than trusted:

	  - A hinge rotates about the DATUM axis it names, through the hinge point.
	    Rotating about +X by a positive angle carries the part's aft edge DOWN,
	    because the local +Z axis maps to (0, -sin, cos).
	  - Elevator therefore declares sign = -1: stick back is pitch positive,
	    and a positive pitch command must raise the elevator's trailing edge.
	  - Ailerons declare mirrorSign = -1 so the two move in opposition. The
	    right aileron rises on a right roll command, which is what drops the
	    right wing.
	  - Flaps only ever deflect down, so their input is clamped to 0..1 rather
	    than -1..1. A negative flap setting is not a thing.
	  - The trim tab moves OPPOSITE the surface it trims. Nose-up trim needs
	    the tab DOWN, which is what pushes the elevator up and holds it there.
]]
function SurfaceAnimation.surfaceAngle(hinge: any, sources: any): number
	if not hinge or not hinge.channel then
		return 0
	end

	local channel = hinge.channel
	local input: number

	if channel == "aileron" then
		input = sources.roll or 0
	elseif channel == "elevator" then
		input = sources.pitch or 0
	elseif channel == "rudder" then
		input = sources.yaw or 0
	elseif channel == "flaps" then
		input = clamp(sources.flaps or 0, 0, 1)
	elseif channel == "trim" then
		--[[
			NOT negated here, and the first version was.

			The tab's opposition to the elevator is already carried by the
			SIGNS the two surfaces declare: the elevator is -1, the tab is +1.
			Negating the input as well cancelled that out and produced a tab
			that FOLLOWED the elevator, which is an anti-servo tab off a
			different aeroplane. The test asserts the product of the two
			deflections is negative, which is what caught it.
		]]
		input = sources.trim or 0
	else
		return 0
	end

	input = clamp(input, -1, 1)
	local maxDeg = hinge.maxDeg or 0
	local sign = hinge.sign or 1
	return math.rad(maxDeg) * input * sign
end

--[[
	Blade and disc transparency for a given RPM, as (blade, disc).

	Pure, so the crossover can be asserted at the two ends and in the middle
	without an engine running.
]]
function SurfaceAnimation.propellerBlur(rpm: number): (number, number)
	local blur = clamp((rpm - IDLE_RPM) / (BLUR_RPM - IDLE_RPM), 0, 1)
	return blur * BLADE_MAX_TRANSPARENCY, 1 - blur * (1 - DISC_MIN_TRANSPARENCY)
end

--[[
	Exponential approach that is correct at any frame rate.

	The naive `current += (target - current) * rate * dt` moves a different
	distance per second when the frame rate changes, which makes flap travel
	time depend on how busy the renderer is.
]]
local function approach(current: number, target: number, tau: number, dt: number): number
	if tau <= 0 then
		return target
	end
	return target + (current - target) * math.exp(-dt / tau)
end

-- =========================================================================
-- BINDING
-- =========================================================================

--[[
	Find the hinges in a built model and cache what is needed to drive them.

	The definition is the authority on which parts hinge and how, so this
	walks the decoration specs rather than guessing from part names. A
	definition with no hinged surfaces - or a model built before this existed -
	produces an empty state and steps to nothing.
]]
function SurfaceAnimation.new(model: Model, definition: any): any
	local state = {
		surfaces = {},
		propeller = nil :: any,
		propellerDisc = nil :: BasePart?,
		propellerAngle = 0,
	}

	local decorations = definition
		and definition.model
		and definition.model.decorations
	if not decorations then
		return state
	end

	local root = model.PrimaryPart
	for _, spec in decorations do
		local hinge = spec.hinge
		if not hinge then
			continue
		end
		local motor = root and root:FindFirstChild("Hinge_" .. spec.name)
		if not motor or not motor:IsA("Motor6D") then
			continue
		end

		local entry = {
			motor = motor,
			-- The rest position, captured once. Every deflection is applied as
			-- a rotation ON TOP of this, so the surface returns exactly to
			-- where the builder put it rather than drifting frame by frame.
			baseC0 = motor.C0,
			hinge = hinge,
			angle = 0,
			tau = RESPONSE_TAU[hinge.channel] or 0.05,
		}

		if hinge.channel == "propeller" then
			state.propeller = entry
		else
			table.insert(state.surfaces, entry)
		end
	end

	state.propellerDisc = model:FindFirstChild("PropellerDisc") :: BasePart?

	return state
end

--[[
	Drive every surface for one frame.

		controls  the six-field Controls struct, straight from InputController
		trim      InputController's own trim value, which is NOT in Controls
		rpm       engine RPM, for the propeller

	Trim deliberately comes in separately. It is not one of the six fields
	FlightModel consumes, and adding it to them to make this easier would
	change a contract that §6c pins down for good reasons.
]]
function SurfaceAnimation.step(state: any, dt: number, controls: any, trim: number?, rpm: number?)
	if not state then
		return
	end

	local sources = {
		roll = controls and controls.roll or 0,
		pitch = controls and controls.pitch or 0,
		yaw = controls and controls.yaw or 0,
		flaps = controls and controls.flaps or 0,
		trim = trim or 0,
	}

	for _, entry in state.surfaces do
		local target = SurfaceAnimation.surfaceAngle(entry.hinge, sources)
		entry.angle = approach(entry.angle, target, entry.tau, dt)

		local axis = entry.hinge.axis
		local rotation
		if axis == "Y" then
			rotation = CFrame.Angles(0, entry.angle, 0)
		elseif axis == "Z" then
			rotation = CFrame.Angles(0, 0, entry.angle)
		else
			rotation = CFrame.Angles(entry.angle, 0, 0)
		end
		entry.motor.C0 = entry.baseC0 * rotation
	end

	-- ---- Propeller -------------------------------------------------------
	local revs = rpm or 0
	if state.propeller then
		state.propellerAngle = (state.propellerAngle + (revs / 60) * TAU * dt) % TAU
		state.propeller.motor.C0 = state.propeller.baseC0 * CFrame.Angles(0, 0, state.propellerAngle)

		local blade, disc = SurfaceAnimation.propellerBlur(revs)
		local bladePart = state.propeller.motor.Part1
		if bladePart then
			bladePart.Transparency = blade
		end
		if state.propellerDisc then
			state.propellerDisc.Transparency = disc
		end
	end
end

-- =========================================================================
-- VERIFICATION
-- =========================================================================

function SurfaceAnimation.runTests(): (boolean, { any })
	local results = {}
	local allPassed = true

	local function record(label: string, passed: boolean, detail: string)
		table.insert(results, { name = label, passed = passed, detail = detail })
		if not passed then
			allPassed = false
		end
		print(string.format("  [%s] %s - %s", if passed then "PASS" else "FAIL", label, detail))
	end

	print("\n=== SurfaceAnimation ===")

	local function deg(hinge: any, sources: any): number
		return math.deg(SurfaceAnimation.surfaceAngle(hinge, sources))
	end

	-- ---- Elevator --------------------------------------------------------
	local elevator = { axis = "X", channel = "elevator", maxDeg = 22, sign = -1 }
	record(
		"Stick back raises the elevator",
		deg(elevator, { pitch = 1 }) < 0,
		string.format("pitch +1 gives %+.1f deg, and negative about X is trailing edge UP", deg(elevator, { pitch = 1 }))
	)
	record(
		"Elevator travel is symmetric and reaches its stop",
		math.abs(math.abs(deg(elevator, { pitch = 1 })) - 22) < 1e-9
			and math.abs(deg(elevator, { pitch = -1 }) + deg(elevator, { pitch = 1 })) < 1e-9,
		string.format("%+.1f / %+.1f deg", deg(elevator, { pitch = 1 }), deg(elevator, { pitch = -1 }))
	)
	record(
		"A centred stick leaves the elevator faired",
		deg(elevator, { pitch = 0 }) == 0,
		"0.0 deg"
	)

	-- ---- Ailerons oppose each other -------------------------------------
	--[[
		The signs here are the ones the DEFINITION uses, read from it rather
		than restated, so this cannot drift away from the aeroplane.
	]]
	local Cessna = require(script.Parent.Definitions.Cessna172)
	local bySpec = {}
	for _, spec in Cessna.model.decorations do
		bySpec[spec.name] = spec
	end
	local right = bySpec.AileronRight.hinge
	local left = bySpec.AileronLeft.hinge
	local rollRight = { roll = 1 }
	record(
		"Ailerons deflect in opposition",
		math.abs(deg(right, rollRight) + deg(left, rollRight)) < 1e-9 and deg(right, rollRight) ~= 0,
		string.format("right %+.1f, left %+.1f deg", deg(right, rollRight), deg(left, rollRight))
	)
	--[[
		THE test that caught a live bug, and the reasoning matters because the
		first version asserted the opposite and passed.

		Positive rotation about X carries a trailing edge DOWN. A right roll
		must RAISE the right aileron - spoiling lift on the wing that is going
		down - so the right deflection has to be NEGATIVE. Shipped the other
		way round, the ailerons visibly contradicted the roll.
	]]
	record(
		"A right roll command raises the right aileron",
		deg(right, rollRight) < 0,
		string.format("right aileron %+.1f deg; negative about X is trailing edge UP", deg(right, rollRight))
	)
	record(
		"...and drops the left one",
		deg(left, rollRight) > 0,
		string.format("left aileron %+.1f deg", deg(left, rollRight))
	)

	--[[
		THE mirroring test. addPair is what actually produces the left surface,
		and a mirrorSign that failed to invert would give an aeroplane whose
		ailerons move together - which looks almost right and is completely
		wrong.
	]]
	local la, ra = bySpec.AileronLeft, bySpec.AileronRight
	record(
		"The definition's mirrored ailerons carry opposite signs",
		la ~= nil
			and ra ~= nil
			and (la.hinge.sign or 1) == -(ra.hinge.sign or 1),
		string.format(
			"left sign %s against right %s",
			tostring(la and la.hinge.sign),
			tostring(ra and ra.hinge.sign)
		)
	)
	local lf, rf = bySpec.FlapLeft, bySpec.FlapRight
	record(
		"Flaps are mirrored but NOT opposed",
		lf ~= nil and rf ~= nil and (lf.hinge.sign or 1) == (rf.hinge.sign or 1),
		string.format("left sign %s, right %s", tostring(lf and lf.hinge.sign), tostring(rf and rf.hinge.sign))
	)
	record(
		"A mirrored part is placed on the other side",
		la ~= nil and ra ~= nil and la.position.X == -ra.position.X and la.position.X < 0,
		string.format("left x %.2f against right x %.2f", la and la.position.X or 0, ra and ra.position.X or 0)
	)
	record(
		"A mirrored dihedral rotation is negated",
		la ~= nil and ra ~= nil and la.rotation.Z == -ra.rotation.Z,
		string.format("left %.2f deg, right %.2f deg", la and la.rotation.Z or 0, ra and ra.rotation.Z or 0)
	)

	-- ---- Flaps -----------------------------------------------------------
	local flaps = { axis = "X", channel = "flaps", maxDeg = 30 }
	record(
		"Flaps deflect down and only down",
		math.abs(deg(flaps, { flaps = 1 }) - 30) < 1e-9 and math.abs(deg(flaps, { flaps = -1 })) < 1e-9,
		string.format("flaps 1 -> %+.1f, flaps -1 -> %+.1f deg (clamped)", deg(flaps, { flaps = 1 }), deg(flaps, { flaps = -1 }))
	)
	record(
		"A flap detent part-way gives part travel",
		math.abs(deg(flaps, { flaps = 0.333 }) - 10) < 0.1,
		string.format("flaps 0.333 -> %.1f deg of 30", deg(flaps, { flaps = 0.333 }))
	)

	-- ---- Trim tab --------------------------------------------------------
	--[[
		The tab opposes the surface it trims. Nose-up trim needs the tab DOWN
		so that it pushes the elevator up - a tab that followed the elevator
		would be an anti-servo tab off a different aeroplane.
	]]
	local tab = { axis = "X", channel = "trim", maxDeg = 15, sign = 1 }
	record(
		"The trim tab opposes the elevator it trims",
		deg(tab, { trim = 1 }) * deg(elevator, { pitch = 1 }) < 0,
		string.format("nose-up trim %+.1f against nose-up elevator %+.1f", deg(tab, { trim = 1 }), deg(elevator, { pitch = 1 }))
	)

	-- ---- Rudder ----------------------------------------------------------
	local rudder = { axis = "Y", channel = "rudder", maxDeg = 22 }
	record(
		"Right rudder swings the trailing edge right",
		deg(rudder, { yaw = 1 }) > 0,
		string.format("%+.1f deg about Y", deg(rudder, { yaw = 1 }))
	)

	-- ---- Guards ----------------------------------------------------------
	record(
		"An unknown channel is inert rather than an error",
		SurfaceAnimation.surfaceAngle({ axis = "X", channel = "nonsense", maxDeg = 30 }, { pitch = 1 }) == 0,
		"returned 0"
	)
	record(
		"A missing hinge is inert rather than an error",
		SurfaceAnimation.surfaceAngle(nil, { pitch = 1 }) == 0,
		"returned 0"
	)
	record(
		"Input beyond full travel clamps at the stop",
		deg(elevator, { pitch = 5 }) == deg(elevator, { pitch = 1 }),
		string.format("pitch 5 gives %+.1f, same as pitch 1", deg(elevator, { pitch = 5 }))
	)

	-- ---- Propeller blur --------------------------------------------------
	local bladeStopped, discStopped = SurfaceAnimation.propellerBlur(0)
	record(
		"A stopped propeller shows a solid blade and no disc",
		bladeStopped == 0 and discStopped == 1,
		string.format("blade %.2f, disc %.2f transparency", bladeStopped, discStopped)
	)
	local bladeFast, discFast = SurfaceAnimation.propellerBlur(2400)
	record(
		"A spinning propeller fades to a disc",
		bladeFast > 0.8 and discFast < 0.8,
		string.format("blade %.2f, disc %.2f transparency at 2400 rpm", bladeFast, discFast)
	)
	local bladeIdle = SurfaceAnimation.propellerBlur(IDLE_RPM)
	record(
		"The blur starts at idle, not before",
		bladeIdle == 0,
		string.format("blade %.2f transparency at %d rpm", bladeIdle, IDLE_RPM)
	)

	-- ---- Frame-rate independence ----------------------------------------
	--[[
		Flap travel must take the same wall-clock time whatever the frame rate.
		The naive lerp fails this and makes travel depend on how busy the
		renderer is, which is exactly the sort of thing that is never noticed
		and never quite right.
	]]
	local function travel(dt: number, seconds: number): number
		local v = 0
		for _ = 1, math.floor(seconds / dt) do
			v = approach(v, 1, RESPONSE_TAU.flaps, dt)
		end
		return v
	end
	local at60 = travel(1 / 60, 3)
	local at20 = travel(1 / 20, 3)
	record(
		"Surface travel is frame-rate independent",
		math.abs(at60 - at20) < 0.005,
		string.format("3 s of flap travel: %.4f at 60 Hz against %.4f at 20 Hz", at60, at20)
	)

	local passed, total = 0, #results
	for _, r in results do
		if r.passed then
			passed += 1
		end
	end
	print(string.format("=== SurfaceAnimation: %d/%d ===", passed, total))

	return allPassed, results
end

return SurfaceAnimation
