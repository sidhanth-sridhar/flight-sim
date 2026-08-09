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
	-- Rudder trim is a wheel on the pedestal, exactly like the pitch trim
	-- wheel, so it moves at the same unhurried rate (Phase 4c, item 1).
	rudderTrim = 1.2,
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
	elseif channel == "rudderTrim" then
		--[[
			Not negated, for exactly the reason the pitch trim tab is not: the
			opposition between a tab and the surface it trims is carried by the
			SIGNS the two declare, and negating the input as well would cancel it
			and give an anti-servo tab off a different aeroplane (Phase 4c).
		]]
		input = sources.rudderTrim or 0
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
function SurfaceAnimation.step(
	state: any,
	dt: number,
	controls: any,
	trim: number?,
	rpm: number?,
	--[[
		Rudder trim, -1..1, added in Phase 4c. Optional and last, so every
		existing caller is unchanged and an aircraft with no rudder trim tab
		simply drives nothing - which is what a definition without the surface
		should do.
	]]
	rudderTrim: number?
)
	if not state then
		return
	end

	local sources = {
		roll = controls and controls.roll or 0,
		pitch = controls and controls.pitch or 0,
		yaw = controls and controls.yaw or 0,
		flaps = controls and controls.flaps or 0,
		trim = trim or 0,
		rudderTrim = rudderTrim or 0,
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
-- LIGHTS (Phase 4c, item 8)
-- =========================================================================

--[[
	Which parts each switch lights, and what colour they burn.

	The parts are ALREADY MODELLED and were inert - §14 item 8's whole
	complaint. This is what gives them a switch, and it lives here rather than
	in a module of its own because it is exactly the same kind of thing as the
	control surfaces: a purely visual consumer of state that the physics does
	not read. Nothing below applies a force or changes a mass.

	`NavLightRight` and `NavLightLeft` carry the real red/green convention -
	RED ON THE LEFT WING, green on the right, which is how you tell which way an
	aircraft is pointing at night. Getting it backwards is the classic error and
	is asserted rather than trusted.
]]
SurfaceAnimation.LIGHTS = {
	beacon = { parts = { "Beacon" }, color = Color3.fromRGB(255, 40, 40), brightness = 3, range = 24 },
	nav = {
		parts = { "NavLightLeft", "NavLightRight", "TailLight" },
		-- Per-part colours override the group's, for the red/green convention.
		colors = {
			NavLightLeft = Color3.fromRGB(255, 40, 40),
			NavLightRight = Color3.fromRGB(40, 255, 80),
			TailLight = Color3.fromRGB(255, 255, 255),
		},
		color = Color3.fromRGB(255, 255, 255),
		brightness = 2,
		range = 18,
	},
	strobe = { parts = { "StrobeLeft", "StrobeRight" }, color = Color3.fromRGB(255, 255, 255), brightness = 6, range = 30 },
	taxi = { parts = { "TaxiLight" }, color = Color3.fromRGB(255, 240, 200), brightness = 5, range = 40 },
	landing = { parts = { "LandingLight" }, color = Color3.fromRGB(255, 250, 230), brightness = 8, range = 70 },
}

--[[
	How fast a strobe flashes, in flashes per second.

	Roughly 1 Hz, which is what an anti-collision strobe actually does. A strobe
	that flashed at frame rate would be a different, much worse thing.
]]
local STROBE_HZ = 1.0
local STROBE_DUTY = 0.08 -- fraction of the cycle it is actually lit

--[[
	Is a light on THIS frame?

	Pure, so the strobe's duty cycle can be asserted without a clock. `powered`
	is the electrical bus - §47 item 5 - and it outranks the switch entirely:
	a landing light switched on with the master off is a switch that does
	nothing, which is the whole reason item 8 waited for item 5.
]]
function SurfaceAnimation.lightIsLit(name: string, switchedOn: boolean, powered: boolean, clock: number): boolean
	if not switchedOn or not powered then
		return false
	end
	if name == "strobe" then
		return (clock * STROBE_HZ) % 1 < STROBE_DUTY
	end
	return true
end

--[[
	Bind the light parts once, the same way `new` binds the hinges.

	A definition that does not have a given lamp simply binds nothing, so this
	is safe on any aircraft - the Phase 5 jet will have its own set.
]]
function SurfaceAnimation.bindLights(model: Model): any
	local bound: { [string]: { any } } = {}

	for switch, spec in SurfaceAnimation.LIGHTS do
		bound[switch] = {}
		for _, partName in spec.parts do
			local part = model:FindFirstChild(partName)
			if part and part:IsA("BasePart") then
				--[[
					A PointLight as well as the Neon material, because Neon makes
					a part LOOK bright without lighting anything around it. A
					landing light that does not put light on the runway is a
					decoration, and the runway is the entire reason it exists.
				]]
				local emitter = part:FindFirstChildOfClass("PointLight")
				if not emitter then
					emitter = Instance.new("PointLight")
					emitter.Name = "Lamp"
					emitter.Parent = part
				end
				emitter.Color = (spec.colors and spec.colors[partName]) or spec.color
				emitter.Brightness = spec.brightness
				emitter.Range = spec.range
				emitter.Enabled = false

				table.insert(bound[switch], {
					part = part,
					emitter = emitter,
					-- Captured so an unlit lamp goes back to the colour the
					-- builder painted it rather than to a hardcoded grey.
					baseColor = part.Color,
					baseMaterial = part.Material,
					litColor = (spec.colors and spec.colors[partName]) or spec.color,
				})
			end
		end
	end

	return bound
end

--[[
	Drive every lamp for one frame.

	`switches` is `systems.lights`; `powered` is `Electrical.isPowered`. Both
	come from the layers that own them, and this function decides nothing except
	what that means for a part.
]]
function SurfaceAnimation.stepLights(bound: any, switches: any, powered: boolean, clock: number)
	if not bound or not switches then
		return
	end

	for switch, lamps in bound do
		local lit = SurfaceAnimation.lightIsLit(switch, switches[switch] == true, powered, clock)
		for _, lamp in lamps do
			lamp.emitter.Enabled = lit
			if lit then
				lamp.part.Material = Enum.Material.Neon
				lamp.part.Color = lamp.litColor
			else
				lamp.part.Material = lamp.baseMaterial
				lamp.part.Color = lamp.baseColor
			end
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

	-- ---- Rudder trim (Phase 4c, item 1) ----------------------------------
	--[[
		The same relationship the elevator tab has, on the other axis. Read from
		the DEFINITION rather than restated, so this cannot drift away from the
		aeroplane the builder actually makes.
	]]
	local rudderTab = bySpec.RudderTrimTab
	record(
		"The rudder has a trim tab at all",
		rudderTab ~= nil and rudderTab.hinge.channel == "rudderTrim",
		rudderTab and string.format("%s on channel %s", rudderTab.name, rudderTab.hinge.channel) or "missing"
	)
	record(
		"...hinged to the RUDDER, so it rides with it rather than off the fin",
		rudderTab ~= nil and rudderTab.hinge.parent == "Rudder",
		rudderTab and tostring(rudderTab.hinge.parent) or "missing"
	)
	record(
		"...on the same axis as the rudder it trims",
		rudderTab ~= nil and rudderTab.hinge.axis == bySpec.Rudder.hinge.axis,
		rudderTab and string.format("both about %s", rudderTab.hinge.axis) or "missing"
	)
	--[[
		A tab OPPOSES the surface it trims. Right rudder trim must swing the tab
		LEFT, which is what pushes the rudder right and holds it there.
	]]
	record(
		"The rudder tab opposes the rudder it trims",
		rudderTab ~= nil
			and deg(rudderTab.hinge, { rudderTrim = 1 }) * deg(bySpec.Rudder.hinge, { yaw = 1 }) < 0,
		rudderTab and string.format(
			"trim %+.1f against rudder %+.1f",
			deg(rudderTab.hinge, { rudderTrim = 1 }),
			deg(bySpec.Rudder.hinge, { yaw = 1 })
		) or "missing"
	)
	--[[
		⚠️ AND ITS TRAVEL IS SMALLER THAN THE PITCH TAB'S, deliberately: rudder
		trim takes the footwork out of a climb, it does not fly the aeroplane
		sideways.
	]]
	record(
		"Rudder trim has less authority than pitch trim",
		rudderTab ~= nil and rudderTab.hinge.maxDeg < bySpec.TrimTab.hinge.maxDeg,
		rudderTab and string.format("%d deg against the elevator tab's %d",
			rudderTab.hinge.maxDeg, bySpec.TrimTab.hinge.maxDeg) or "missing"
	)
	--[[
		The two trim channels must be independent. One `trim` source driving
		both tabs would mean trimming the nose up also kicked the rudder, which
		would be very confusing and entirely invisible in the arithmetic above.
	]]
	record(
		"Pitch trim does not move the rudder tab, and vice versa",
		rudderTab ~= nil
			and deg(rudderTab.hinge, { trim = 1 }) == 0
			and deg(bySpec.TrimTab.hinge, { rudderTrim = 1 }) == 0,
		"the two trim channels are independent"
	)

	-- ---- Lights (Phase 4c, item 8) ---------------------------------------
	--[[
		⚠️ THE BUS OUTRANKS THE SWITCH, and this is the check item 8 waited for
		item 5 to make possible. A landing light switched on with the master off
		is a switch that does nothing - which is what makes the master switch
		mean something rather than being a boolean with a lamp behind it.
	]]
	record(
		"A switched-on light does not light with the bus dead",
		not SurfaceAnimation.lightIsLit("landing", true, false, 0),
		"master off beats the switch"
	)
	record(
		"...and lights when it is powered",
		SurfaceAnimation.lightIsLit("landing", true, true, 0),
		"lit"
	)
	record(
		"A switched-off light stays off on a live bus",
		not SurfaceAnimation.lightIsLit("landing", false, true, 0),
		"off"
	)

	--[[
		The strobe FLASHES rather than burning. Asserted across a full cycle,
		because a duty cycle checked at one instant proves nothing - it would
		pass on a lamp that was always on and on one that was always off.
	]]
	local litFrames, totalFrames = 0, 600
	for i = 0, totalFrames - 1 do
		if SurfaceAnimation.lightIsLit("strobe", true, true, i / 60) then
			litFrames += 1
		end
	end
	local duty = litFrames / totalFrames
	record(
		"The strobe flashes rather than burning steadily",
		duty > 0.02 and duty < 0.2,
		string.format("lit %.1f%% of a 10 s window, at about %.1f Hz", duty * 100, STROBE_HZ)
	)
	record(
		"...and does not flash at all with the bus dead",
		not SurfaceAnimation.lightIsLit("strobe", true, false, 0.0)
			and not SurfaceAnimation.lightIsLit("strobe", true, false, 0.5),
		"dark through the whole cycle"
	)

	--[[
		⚠️ RED ON THE LEFT, GREEN ON THE RIGHT. The convention that tells you
		which way an aircraft is pointing at night, and the classic thing to get
		backwards. Read off the LIGHTS table rather than restated.
	]]
	local navColors = SurfaceAnimation.LIGHTS.nav.colors
	record(
		"Navigation lights are red to port and green to starboard",
		navColors.NavLightLeft.R > 0.8 and navColors.NavLightLeft.G < 0.3
			and navColors.NavLightRight.G > 0.8 and navColors.NavLightRight.R < 0.3,
		"left red, right green"
	)

	--[[
		Every switch must drive at least one part that the definition actually
		has. A switch bound to a part nobody modelled is a key that does nothing
		and reports nothing - and four of these lamps did not exist until this
		phase added them.
	]]
	local partNames = {}
	for _, spec in Cessna.model.decorations do
		partNames[spec.name] = true
	end
	local unbacked = {}
	for switch, spec in SurfaceAnimation.LIGHTS do
		local found = false
		for _, partName in spec.parts do
			if partNames[partName] then
				found = true
			end
		end
		if not found then
			table.insert(unbacked, switch)
		end
	end
	record(
		"Every light switch drives a part the aeroplane actually has",
		#unbacked == 0,
		#unbacked == 0 and "all five switches are backed by real parts"
			or ("no part for: " .. table.concat(unbacked, ", "))
	)

	--[[
		And no part is claimed by two switches, which would have them fighting
		over its colour every frame - whichever ran last would win, and the
		iteration order of a table is not defined.
	]]
	local claimedBy: { [string]: string } = {}
	local conflict = nil
	for switch, spec in SurfaceAnimation.LIGHTS do
		for _, partName in spec.parts do
			if claimedBy[partName] then
				conflict = string.format("%s claimed by %s and %s", partName, claimedBy[partName], switch)
			end
			claimedBy[partName] = switch
		end
	end
	record(
		"No lamp is driven by two switches",
		conflict == nil,
		conflict or "every part belongs to exactly one switch"
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

	--[[
		---- The trim tab rides the elevator ----------------------------------

		⚠️ EVERYTHING ABOVE IS PURE ARITHMETIC, AND THIS BUG LIVED WHERE THE
		ARITHMETIC WAS ALREADY RIGHT. `surfaceAngle` returned a perfectly good
		trim deflection the whole time; the tab still did not follow the
		elevator, because the BUILDER hung its motor off the airframe. The
		pilot saw "a small piece on the right elevator that does not move".

		So this one drives a REAL built model - the only place the two layers
		meet - and asserts the compound motion a tab must have: it rides the
		elevator, AND it holds its own deflection relative to it.

		Required lazily so the module itself keeps no build-time dependency on
		the builder or on any particular aircraft.
	]]
	local FlightSimRoot = script.Parent.Parent
	local okBuild, AircraftBuilder = pcall(require, FlightSimRoot.Aircraft.AircraftBuilder)
	local okDef, Cessna172 = pcall(require, FlightSimRoot.Aircraft.Definitions.Cessna172)

	if okBuild and okDef then
		local model = AircraftBuilder.build(Cessna172, CFrame.new(0, 2000, 0), workspace)
		model.PrimaryPart.Anchored = true
		local state = SurfaceAnimation.new(model, Cessna172)
		local elevator = model:FindFirstChild("ElevatorRight") :: BasePart
		local tabPart = model:FindFirstChild("TrimTab") :: BasePart

		local function angleBetween(part: BasePart, reference: BasePart): number
			local rel = reference.CFrame:Inverse() * part.CFrame
			return math.deg(math.asin(math.clamp(rel.UpVector.Z, -1, 1)))
		end
		local function settle(controls: any, trimValue: number)
			for _ = 1, 2000 do
				SurfaceAnimation.step(state, 1 / 60, controls, trimValue, 0)
			end
		end
		local none = { pitch = 0, roll = 0, yaw = 0, flaps = 0, throttle = 0, brake = 0 }

		settle(none, 0)
		local restTab = angleBetween(tabPart, elevator)

		settle({ pitch = 1, roll = 0, yaw = 0, flaps = 0, throttle = 0, brake = 0 }, 0)
		local elevatorMoved = angleBetween(elevator, model.PrimaryPart)
		local tabWithElevator = angleBetween(tabPart, elevator)

		record(
			"Full elevator carries the trim tab with it",
			math.abs(elevatorMoved) > 20 and math.abs(tabWithElevator - restTab) < 0.1,
			string.format("elevator %+.1f deg, tab still %+.1f deg relative to it", elevatorMoved, tabWithElevator)
		)

		--[[
			And it must still trim. A tab welded to the elevator would pass the
			check above and be useless - it needs BOTH motions.
		]]
		settle(none, 1)
		local tabTrimmed = angleBetween(tabPart, elevator)
		record(
			"...and still deflects on trim, against the elevator",
			math.abs(tabTrimmed) > 10 and tabTrimmed * elevatorMoved < 0,
			string.format("tab %+.1f deg relative to the elevator, opposing its %+.1f", tabTrimmed, elevatorMoved)
		)

		--[[
			The two motions are independent: full stick AND full trim together
			must give the sum, not one overriding the other.
		]]
		settle({ pitch = 1, roll = 0, yaw = 0, flaps = 0, throttle = 0, brake = 0 }, 1)
		local bothWorld = angleBetween(tabPart, model.PrimaryPart)
		local bothRelative = angleBetween(tabPart, elevator)
		record(
			"Stick and trim compound rather than override",
			math.abs(bothRelative - tabTrimmed) < 0.1
				and math.abs(bothWorld - (elevatorMoved + tabTrimmed)) < 0.5,
			string.format("carried to %+.1f deg while holding %+.1f against the elevator", bothWorld, bothRelative)
		)

		--[[
			---- And the SAME compound motion on the rudder (Phase 4c) --------

			Driven on a real built model for exactly the reason §37 gives: every
			check above this block is pure arithmetic, and the bug §37 found
			lived in the JOINT the builder made rather than in the arithmetic.
			The rudder tab is built the same way, so it gets the same test - on
			the Y axis, where a sign convention that happened to be right about X
			proves nothing.
		]]
		local rudderPart = model:FindFirstChild("Rudder") :: BasePart
		local rudderTabPart = model:FindFirstChild("RudderTrimTab") :: BasePart

		if rudderPart and rudderTabPart then
			-- Yaw about Y, read off the part's own look direction relative to
			-- its reference, which is the Y-axis analogue of angleBetween above.
			local function yawBetween(part: BasePart, reference: BasePart): number
				local rel = reference.CFrame:Inverse() * part.CFrame
				return math.deg(math.asin(math.clamp(rel.LookVector.X, -1, 1)))
			end

			local function settleRudder(yaw: number, rudderTrimValue: number)
				for _ = 1, 2000 do
					SurfaceAnimation.step(
						state,
						1 / 60,
						{ pitch = 0, roll = 0, yaw = yaw, flaps = 0, throttle = 0, brake = 0 },
						0,
						0,
						rudderTrimValue
					)
				end
			end

			settleRudder(0, 0)
			local restRudderTab = yawBetween(rudderTabPart, rudderPart)

			settleRudder(1, 0)
			local rudderMoved = yawBetween(rudderPart, model.PrimaryPart)
			local tabCarried = yawBetween(rudderTabPart, rudderPart)
			record(
				"Full rudder carries the rudder trim tab with it",
				math.abs(rudderMoved) > 20 and math.abs(tabCarried - restRudderTab) < 0.1,
				string.format("rudder %+.1f deg, tab still %+.1f deg relative to it", rudderMoved, tabCarried)
			)

			settleRudder(0, 1)
			local rudderTabTrimmed = yawBetween(rudderTabPart, rudderPart)
			record(
				"...and still trims against it, on neutral pedals",
				math.abs(rudderTabTrimmed) > 8 and rudderTabTrimmed * rudderMoved < 0,
				string.format("tab %+.1f deg, opposing a full rudder's %+.1f", rudderTabTrimmed, rudderMoved)
			)

			settleRudder(1, 1)
			local rudderBoth = yawBetween(rudderTabPart, model.PrimaryPart)
			record(
				"Pedal and rudder trim compound rather than override",
				math.abs(rudderBoth - (rudderMoved + rudderTabTrimmed)) < 0.5,
				string.format("carried to %+.1f deg, the sum of %+.1f and %+.1f",
					rudderBoth, rudderMoved, rudderTabTrimmed)
			)
		else
			record("The rudder trim tab is built onto the model", false, "RudderTrimTab or Rudder missing from the built model")
		end

		model:Destroy()
	else
		record("Trim tab rides the elevator", false, "could not load the builder or the definition")
	end

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
