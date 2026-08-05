--!strict
--[[
	AircraftBuilder
	---------------
	Turns an aircraft definition into a physical Roblox assembly.

	WHAT AN "ASSEMBLY" IS, AND WHY IT MATTERS
	-----------------------------------------
	Roblox groups rigidly connected parts into a single rigid body called an
	assembly, and simulates it as one object with one mass, one centre of mass
	and one velocity. Everything in the flight model depends on the aircraft
	being exactly one assembly:

	  - AssemblyLinearVelocity and AssemblyAngularVelocity are what the
	    aerodynamics reads.
	  - Network ownership is granted per assembly, so a split aircraft would
	    have parts owned by different machines and tear itself apart.
	  - Forces applied to any part act on the whole body.

	So every part is welded to one root part, and the builder verifies the
	result really is a single assembly before handing it back.

	FORCE APPLICATION
	-----------------
	Rather than attaching a separate constraint to every wing and tail
	surface, the flight model sums all aerodynamic forces into ONE resultant
	force and ONE resultant torque about the centre of mass, and writes them
	to a single VectorForce and a single Torque. Fewer constraints, identical
	physics, and far less per-frame work.
]]

local FlightSim = script.Parent.Parent

local AircraftBuilder = {}

-- Roblox refuses densities outside this range. At 1 stud = 1 m this caps any
-- part at 100 kg per cubic metre of its bounding box, which is a real design
-- constraint for a metre-scale aircraft - see the note in the definition.
local MIN_DENSITY = 0.01
local MAX_DENSITY = 100

--[[
	Roblox computes mass from a part's TRUE geometric volume, not from its
	bounding box. A cylinder fills only pi/4 of its box and a sphere pi/6, so
	solving density against the box would leave every wheel about 21% light.

	Small in absolute terms - but it is exactly the sort of quiet error that
	makes a landing gear behave subtly wrong and takes an afternoon to find.
]]
local SHAPE_VOLUME_FACTOR = {
	Block = 1,
	Cylinder = math.pi / 4,
	Ball = math.pi / 6,
}

local function effectiveVolume(spec: any): number
	local size = spec.size
	local factor = SHAPE_VOLUME_FACTOR[spec.shape or "Block"] or 1
	return size.X * size.Y * size.Z * factor
end

-- =========================================================================
-- VALIDATION
-- =========================================================================

--[[
	Checks every part can actually reach its stated mass before building.

	This runs first, and hard-errors rather than warning. A part that silently
	clamps to a lower density produces an aircraft that is too light - it
	will fly, badly, and the cause is extremely hard to see from the symptoms.
	Failing loudly at build time costs seconds; failing quietly costs hours.
]]
function AircraftBuilder.validate(definition: any): (boolean, { string })
	local problems = {}
	local model = definition.model

	if not model or not model.parts or #model.parts == 0 then
		table.insert(problems, "definition has no model.parts")
		return false, problems
	end

	local totalMass = 0
	local foundRoot = false

	for _, spec in model.parts do
		if not spec.mass then
			table.insert(problems, string.format("part '%s' has no mass. Structural parts must state one; cosmetic items belong in model.decorations.", tostring(spec.name)))
			continue
		end

		local volume = effectiveVolume(spec)
		local density = spec.mass / volume

		if density > MAX_DENSITY then
			table.insert(problems, string.format(
				"part '%s' needs density %.1f (max %d): %.0f kg in %.3f m^3. Enlarge the part or move mass elsewhere. Largest possible mass at this size is %.1f kg.",
				spec.name, density, MAX_DENSITY, spec.mass, volume, volume * MAX_DENSITY
			))
		elseif density < MIN_DENSITY then
			table.insert(problems, string.format(
				"part '%s' needs density %.4f (min %.2f): too light for its size.",
				spec.name, density, MIN_DENSITY
			))
		end

		--[[
			ROTATION IS FOR COSMETIC PARTS ONLY.

			Roblox reports an assembly's inertia in world axes, so tipping a
			mass-bearing box rewrites the inertia tensor without changing a
			single mass number - the budget still totals 1,111 kg, the centre
			of mass barely moves, and nothing in the definition looks wrong.
			§4's published figures and §29's measured pitch inertia are both
			taken against the current layout, so this fails the build rather
			than letting Phase 4's modelling quietly move the physics.
		]]
		if spec.rotation then
			table.insert(problems, string.format(
				"part '%s' has a rotation. Structural parts must stay axis-aligned because rotating one rewrites the inertia tensor; put the shaped geometry in model.decorations.",
				tostring(spec.name)
			))
		end

		totalMass += spec.mass
		if spec.name == model.rootPart then
			foundRoot = true
		end
	end

	if not foundRoot then
		table.insert(problems, string.format("rootPart '%s' is not in the parts list", tostring(model.rootPart)))
	end

	--[[
		EVERY NAME MUST BE UNIQUE, ACROSS PARTS AND DECORATIONS BOTH.

		build() keys one table by name to weld from, so a decoration sharing a
		structural part's name REPLACES it there - and the structural part is
		then never welded on. It stays in the model, still visible, still
		carrying its mass, but as a second assembly the aeroplane is not
		attached to.

		This is not hypothetical. Phase 4's skin named a part "Stabilizer",
		which is also a structural part, and the aircraft silently lost 20 kg
		and its tailplane: measured 1,091 kg against 1,111, two assemblies
		instead of one, and a centre of mass 82 mm forward of prediction. Every
		number in the definition was still correct. Only the build was wrong,
		and nothing said so.
	]]
	local seen: { [string]: string } = {}
	local function claim(name: string, kind: string)
		local previous = seen[name]
		if previous then
			table.insert(problems, string.format(
				"duplicate part name '%s' (%s and %s). Names must be unique across parts AND decorations, or the second silently replaces the first and the first is never welded on.",
				name, previous, kind
			))
		end
		seen[name] = kind
	end
	for _, spec in model.parts do
		claim(tostring(spec.name), "structural")
	end
	for _, spec in model.decorations or {} do
		claim(tostring(spec.name), "decoration")
	end

	if definition.mass and definition.mass.maxTakeoff and totalMass > definition.mass.maxTakeoff then
		table.insert(problems, string.format(
			"total mass %.0f kg exceeds max takeoff weight %.0f kg",
			totalMass, definition.mass.maxTakeoff
		))
	end

	return #problems == 0, problems
end

-- =========================================================================
-- PART CREATION
-- =========================================================================

--[[
	The rotation a spec asks for, as a CFrame. Degrees about the datum axes,
	applied X then Y then Z.

	Structural parts may not use it - see validate(). Roblox reports an
	assembly's inertia in world axes, so rotating a mass-bearing box silently
	rewrites the inertia tensor, and §4's published figures are all measured
	against the current layout. Cosmetic parts carry no mass and cannot.
]]
local function specRotation(spec: any): CFrame
	local r = spec.rotation
	if not r then
		return CFrame.identity
	end
	return CFrame.Angles(math.rad(r.X), math.rad(r.Y), math.rad(r.Z))
end

local function createPart(spec: any, baseCFrame: CFrame): BasePart
	local className = spec.className or "Part"
	local part = Instance.new(className) :: any

	part.Name = spec.name
	part.Size = spec.size
	part.CFrame = baseCFrame * CFrame.new(spec.position) * specRotation(spec)
	part.Anchored = false
	part.CanCollide = spec.collide == true
	part.Color = spec.color or Color3.fromRGB(200, 200, 200)
	part.Material = spec.material or Enum.Material.SmoothPlastic
	part.Transparency = spec.transparency or 0
	part.Reflectance = spec.reflectance or 0
	part.CastShadow = spec.castShadow ~= false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	-- A Roblox cylinder's axis runs along its X size, which is why the wheel
	-- specs put the thin dimension first - it makes a disc standing upright.
	-- Ball and Cylinder both need SHAPE_VOLUME_FACTOR to keep mass honest.
	if spec.shape and className == "Part" then
		local shape = (Enum.PartType :: any)[spec.shape]
		if shape then
			part.Shape = shape
		end
	end

	--[[
		Solve for the density that produces the requested mass.

		The alternative - authoring densities - means every resize silently
		changes the aircraft's weight and balance. Mass is the quantity the
		physics actually cares about, so mass is what the definition states.

		Decorations carry no mass field: they are made Massless immediately
		after creation, so their density is irrelevant and the lightest legal
		value is used. Without this branch the shared code path divides nil by
		volume the moment an aircraft has any cosmetic parts.
	]]
	local volume = effectiveVolume(spec)
	local density = if spec.mass
		then math.clamp(spec.mass / volume, MIN_DENSITY, MAX_DENSITY)
		else MIN_DENSITY

	part.CustomPhysicalProperties = PhysicalProperties.new(
		density,
		spec.friction or 0.35,
		spec.elasticity or 0.15, -- low bounce; aircraft tyres do not trampoline
		spec.frictionWeight or 1,
		spec.elasticityWeight or 1
	)

	return part
end

-- =========================================================================
-- BUILD
-- =========================================================================

--[[
	Build a complete aircraft.

		definition  an aircraft definition module
		cframe      where to place it; the root part lands here
		parent      where to put the finished model

	Returns the Model. Its PrimaryPart is the root, and it carries the
	constraints the flight model drives.
]]
function AircraftBuilder.build(definition: any, cframe: CFrame?, parent: Instance?): Model
	local ok, problems = AircraftBuilder.validate(definition)
	if not ok then
		error(string.format(
			"[AircraftBuilder] cannot build '%s':\n  %s",
			tostring(definition.name),
			table.concat(problems, "\n  ")
		), 2)
	end

	local base = cframe or CFrame.new(0, 5, 0)
	local spec = definition.model

	local model = Instance.new("Model")
	model.Name = definition.id or "Aircraft"

	--[[
		---- Structural parts -------------------------------------------------

		hideStructuralParts makes the mass-bearing boxes invisible so a modelled
		skin can be drawn over them. They are still built, still welded, still
		collidable where they say so, and still exactly the mass and balance the
		definition declares - only the appearance changes. Deleting one would
		delete the mass and the aerodynamic reference point with it.
	]]
	local hideStructure = spec.hideStructuralParts == true
	local parts: { [string]: BasePart } = {}
	for _, partSpec in spec.parts do
		local part = createPart(partSpec, base)
		if hideStructure and partSpec.transparency == nil then
			part.Transparency = 1
			part.CastShadow = false
		end
		part.Parent = model
		parts[partSpec.name] = part
	end

	local root = parts[spec.rootPart]
	model.PrimaryPart = root

	-- ---- Decoration ------------------------------------------------------
	-- Cosmetic only: massless, so they cannot disturb the weight and balance
	-- the definition was carefully built around.
	--[[
		`exteriorFromMesh` is the switch for the imported visual shell.

		The primitive skin and an imported mesh are both EXTERIORS, and running
		both gives an aeroplane wearing two skins. Setting this flag drops the
		static shell so the mesh can be parented over the same physics
		assembly, and keeps everything the mesh cannot do for itself:

		  - HINGED SURFACES. A single imported mesh cannot deflect its own
		    ailerons. The control surfaces stay ours whatever the exterior is,
		    which is exactly why scope item 2 was built mesh-independent.
		  - Anything marked `keepWithMesh`, for parts paired to a hinge (the
		    propeller's blur disc) that would otherwise be orphaned.

		The structural boxes are untouched either way. They are the physics and
		they collide; both exteriors are massless decoration over the top.
	]]
	local useMesh = spec.exteriorFromMesh == true
	local hingedSpecs: { [string]: any } = {}
	if spec.decorations then
		for _, decoSpec in spec.decorations do
			local isShell = not decoSpec.hinge and not decoSpec.keepWithMesh
			if useMesh and isShell then
				continue
			end
			local deco = createPart(decoSpec, base)
			deco.Massless = true
			deco.CanCollide = false
			deco.Parent = model
			parts[decoSpec.name] = deco
			if decoSpec.hinge then
				hingedSpecs[decoSpec.name] = decoSpec
			end
		end
	end

	-- ---- Weld into one rigid body ---------------------------------------
	-- Hinged surfaces are skipped: they get a Motor6D below instead, and a
	-- part carrying both a weld and a motor cannot move.
	for name, part in parts do
		if part ~= root and not hingedSpecs[name] then
			local weld = Instance.new("WeldConstraint")
			weld.Name = "Weld_" .. name
			weld.Part0 = root
			weld.Part1 = part
			weld.Parent = root
		end
	end

	--[[
		---- Hinged control surfaces ------------------------------------------

		A Motor6D places Part1 at:

			Part0.CFrame * C0 * Transform * C1:Inverse()

		C0 is built with the HINGE POINT as its origin and NO rotation of its
		own, so it is expressed in the datum's axes. That is what makes the
		animation layer able to say "rotate about X" and mean the aircraft's
		lateral axis, whatever angle the surface itself is mounted at - the
		swept fin and the dihedral wings are mounted rotated, and their
		surfaces must still hinge about a sensible axis.

		C1 folds that mounting rotation back out, so at rest the motor
		reproduces exactly the CFrame createPart would have given the part:

			root * C0 * C1:Inverse()
			  = base * rootPos * (p + h - rootPos) * (-h) * R
			  = base * p * R                                    ✓

		The surfaces stay massless, so driving them changes nothing physical -
		the flight model reads the pilot's controls, never these parts.
	]]
	local rootSpecPosition = Vector3.zero
	for _, partSpec in spec.parts do
		if partSpec.name == spec.rootPart then
			rootSpecPosition = partSpec.position
		end
	end

	for name, decoSpec in hingedSpecs do
		local hingeOffset = decoSpec.hinge.offset or Vector3.zero
		local motor = Instance.new("Motor6D")
		motor.Name = "Hinge_" .. name
		motor.Part0 = root
		motor.Part1 = parts[name]
		motor.C0 = CFrame.new(decoSpec.position + hingeOffset - rootSpecPosition)
		motor.C1 = specRotation(decoSpec):Inverse() * CFrame.new(hingeOffset)
		motor.Parent = root
	end

	-- ---- Seat ------------------------------------------------------------
	local seat = parts.PilotSeat
	if seat and seat:IsA("VehicleSeat") then
		--[[
			Neutralise the VehicleSeat's built-in driving behaviour. We want it
			purely for two things: detecting who is aboard, and the automatic
			transfer of network ownership to the occupant.

			Leaving these non-zero would have Roblox applying its own steering
			torques on top of the aerodynamics, which shows up as an aircraft
			that mysteriously resists turning.
		]]
		seat.MaxSpeed = 0
		seat.Torque = 0
		seat.TurnSpeed = 0
		seat.HeadsUpDisplay = false
	end

	-- ---- Force constraints ----------------------------------------------
	local attachment = Instance.new("Attachment")
	attachment.Name = "FlightAttachment"
	attachment.Parent = root

	--[[
		One force and one torque for the entire aircraft.

		ApplyAtCenterOfMass matters: without it the force acts at the
		attachment's position, which is the root part's origin, and any offset
		between that and the true centre of mass would inject a phantom
		pitching moment that scales with thrust. With it on, the resultant
		force is pure translation and every rotation comes from the Torque -
		which is exactly the split the flight model computes.

		Both are RelativeTo World because the aerodynamics works in world
		space; converting to body space each frame would only add work and a
		place for sign errors to hide.
	]]
	local force = Instance.new("VectorForce")
	force.Name = "AeroForce"
	force.Attachment0 = attachment
	force.ApplyAtCenterOfMass = true
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	force.Force = Vector3.zero
	force.Parent = root

	local torque = Instance.new("Torque")
	torque.Name = "AeroTorque"
	torque.Attachment0 = attachment
	torque.RelativeTo = Enum.ActuatorRelativeTo.World
	torque.Torque = Vector3.zero
	torque.Parent = root

	-- ---- Metadata --------------------------------------------------------
	model:SetAttribute("AircraftId", definition.id)
	model:SetAttribute("AircraftName", definition.name)

	--[[
		Where the root part sits in DATUM coordinates.

		This is easy to overlook and produces very confusing bugs. The
		definition measures every aerodynamic offset from an arbitrary datum,
		but Roblox measures everything from the root part's origin - and the
		two are not the same point. Anything converting between the definition
		and the live model must apply this offset, so it is recorded on the
		model itself rather than left for each consumer to rediscover.
	]]
	local rootSpec
	for _, partSpec in spec.parts do
		if partSpec.name == spec.rootPart then
			rootSpec = partSpec
			break
		end
	end
	root:SetAttribute("DatumOffset", rootSpec.position)

	model.Parent = parent or workspace

	-- Position after parenting so the assembly is resolved before we measure.
	model:PivotTo(base)

	return model
end

-- =========================================================================
-- MEASUREMENT
-- =========================================================================

--[[
	Reports what Roblox actually built, as opposed to what the definition
	asked for. Used by the tests and by AircraftService at spawn.

	The centre of mass is the number worth watching: it is computed by Roblox
	from the real part layout, and the flight model derives every moment arm
	from it. If it drifts from where the definition expects, the aircraft's
	stability changes without a single aerodynamic coefficient being touched.
]]
function AircraftBuilder.measure(model: Model): { [string]: any }
	local root = model.PrimaryPart
	assert(root, "[AircraftBuilder] model has no PrimaryPart")

	local totalMass = 0
	local partCount = 0
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and not part.Massless then
			totalMass += part:GetMass()
			partCount += 1
		end
	end

	local comWorld = root.AssemblyCenterOfMass
	local comLocal = root.CFrame:PointToObjectSpace(comWorld)

	-- The same point expressed in the definition's datum frame, which is what
	-- the aerodynamic offsets are measured against.
	local datumOffset = root:GetAttribute("DatumOffset") or Vector3.zero
	local comDatum = comLocal + datumOffset

	-- Count the distinct assemblies. Anything above 1 means a weld is missing
	-- and the aircraft would fly in pieces.
	local assemblies = {}
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			assemblies[part.AssemblyRootPart] = true
		end
	end
	local assemblyCount = 0
	for _ in assemblies do
		assemblyCount += 1
	end

	return {
		mass = root.AssemblyMass,
		summedPartMass = totalMass,
		partCount = partCount,
		centerOfMassLocal = comLocal, -- relative to the root part
		centerOfMassDatum = comDatum, -- relative to the definition's datum
		centerOfMassWorld = comWorld,
		datumOffset = datumOffset,
		assemblyCount = assemblyCount,
		extents = model:GetExtentsSize(),
	}
end

-- =========================================================================
-- VERIFICATION
-- =========================================================================

--[[
	Builds a real aircraft in the world, measures it, then removes it.

	Run from the Studio command bar:
		require(game.ReplicatedStorage.FlightSim.Aircraft.AircraftBuilder).runTests()

	This is the first test that touches the actual engine rather than pure
	maths, so it is checking Roblox's behaviour as much as ours: that the
	densities produce the intended mass, that everything welds into one body,
	and that the centre of mass lands where the definition assumed.
]]
function AircraftBuilder.runTests(definitionOverride: any?): (boolean, { any })
	local definition = definitionOverride or require(FlightSim.Aircraft.Definitions.Cessna172)

	local results = {}
	local allPassed = true

	local function record(label: string, passed: boolean, detail: string)
		if not passed then
			allPassed = false
		end
		table.insert(results, { label = label, passed = passed, detail = detail })
		print(string.format("  [%s] %-40s %s", passed and "PASS" or "FAIL", label, detail))
	end

	local function checkRange(label: string, actual: number, lo: number, hi: number, unit: string)
		record(label, actual >= lo and actual <= hi, string.format("%.4f %s (expected %.3f..%.3f)", actual, unit, lo, hi))
	end

	print("=== AircraftBuilder: verification ===")

	-- 1. Validation --------------------------------------------------------
	local valid, problems = AircraftBuilder.validate(definition)
	record("Definition validates", valid, valid and "no problems" or table.concat(problems, " | "))
	if not valid then
		return false, results
	end

	-- The validator must actually catch an impossible part, or it is useless.
	local broken = table.clone(definition)
	broken.model = table.clone(definition.model)
	broken.model.parts = table.clone(definition.model.parts)
	broken.model.parts[1] = table.clone(definition.model.parts[1])
	broken.model.parts[1].mass = 99999
	local brokenOk, brokenProblems = AircraftBuilder.validate(broken)
	record(
		"Validator rejects impossible density",
		not brokenOk and #brokenProblems > 0,
		brokenOk and "accepted a 99,999 kg part!" or "rejected as expected"
	)

	-- 2. Build -------------------------------------------------------------
	local model = AircraftBuilder.build(definition, CFrame.new(0, 500, 0), workspace)
	local m = AircraftBuilder.measure(model)

	-- 3. Mass --------------------------------------------------------------
	local expectedMass = 0
	for _, p in definition.model.parts do
		expectedMass += p.mass
	end

	checkRange("Assembly mass matches definition", m.mass, expectedMass * 0.99, expectedMass * 1.01, "kg")
	record(
		"No part silently clamped its density",
		math.abs(m.summedPartMass - expectedMass) < expectedMass * 0.01,
		string.format("%.1f kg built vs %.1f kg specified", m.summedPartMass, expectedMass)
	)

	-- 4. THE assembly check ------------------------------------------------
	record(
		"Everything welds into ONE assembly",
		m.assemblyCount == 1,
		string.format("%d assembly/assemblies", m.assemblyCount)
	)

	-- 5. Centre of mass ----------------------------------------------------
	-- Compare Roblox's computed centre of mass against the definition's own
	-- arithmetic. A mismatch means the built model is not what was designed.
	local predictedZ, predictedY, totalM = 0, 0, 0
	for _, p in definition.model.parts do
		totalM += p.mass
		predictedZ += p.mass * p.position.Z
		predictedY += p.mass * p.position.Y
	end
	predictedZ /= totalM
	predictedY /= totalM

	-- Compare in the DATUM frame. Roblox reports the centre of mass relative
	-- to the root part, which sits at its own offset from the datum, so the
	-- two must be brought into the same frame before they mean anything.
	record(
		"Centre of mass",
		true,
		string.format(
			"datum (%.3f, %.3f, %.3f) | root-relative (%.3f, %.3f, %.3f)",
			m.centerOfMassDatum.X, m.centerOfMassDatum.Y, m.centerOfMassDatum.Z,
			m.centerOfMassLocal.X, m.centerOfMassLocal.Y, m.centerOfMassLocal.Z
		)
	)
	record(
		"Centre of mass matches the definition",
		math.abs(m.centerOfMassDatum.Z - predictedZ) < 0.02 and math.abs(m.centerOfMassDatum.Y - predictedY) < 0.02,
		string.format("predicted z=%.3f y=%.3f, got z=%.3f y=%.3f", predictedZ, predictedY, m.centerOfMassDatum.Z, m.centerOfMassDatum.Y)
	)
	record(
		"Centre of mass is on the centreline",
		math.abs(m.centerOfMassDatum.X) < 0.01,
		string.format("x = %.5f m", m.centerOfMassDatum.X)
	)

	-- Cylinders and spheres must reach their stated mass despite Roblox using
	-- true geometric volume rather than the bounding box.
	local wheel = model:FindFirstChild("WheelLeft")
	if wheel and wheel:IsA("BasePart") then
		record(
			"Cylindrical parts reach their stated mass",
			math.abs(wheel:GetMass() - 2) < 0.05,
			string.format("%.3f kg (specified 2.0)", wheel:GetMass())
		)
	end

	-- 6. Dimensions --------------------------------------------------------
	-- Against the real aircraft: 11.0 m span, 8.28 m long, 2.72 m tall.
	checkRange("Wingspan", m.extents.X, 10.0, 11.5, "m")
	checkRange("Length", m.extents.Z, 7.5, 9.0, "m")
	checkRange("Height", m.extents.Y, 2.0, 3.2, "m")

	-- 7. Constraints -------------------------------------------------------
	local root = model.PrimaryPart :: BasePart
	local aeroForce = root:FindFirstChild("AeroForce") :: VectorForce
	local aeroTorque = root:FindFirstChild("AeroTorque") :: Torque

	record("AeroForce constraint exists", aeroForce ~= nil, aeroForce and aeroForce.ClassName or "missing")
	record("AeroTorque constraint exists", aeroTorque ~= nil, aeroTorque and aeroTorque.ClassName or "missing")

	if aeroForce then
		record(
			"Force applies at the centre of mass",
			aeroForce.ApplyAtCenterOfMass,
			tostring(aeroForce.ApplyAtCenterOfMass)
		)
		record(
			"Force is in world space",
			aeroForce.RelativeTo == Enum.ActuatorRelativeTo.World,
			tostring(aeroForce.RelativeTo)
		)
	end

	-- 8. Seat --------------------------------------------------------------
	local seat = model:FindFirstChild("PilotSeat")
	record("Pilot seat exists and is a VehicleSeat", seat ~= nil and seat:IsA("VehicleSeat"), seat and seat.ClassName or "missing")
	if seat and seat:IsA("VehicleSeat") then
		record(
			"Seat's own driving forces are disabled",
			seat.Torque == 0 and seat.TurnSpeed == 0 and seat.MaxSpeed == 0,
			string.format("torque=%.1f turn=%.1f maxSpeed=%.1f", seat.Torque, seat.TurnSpeed, seat.MaxSpeed)
		)
	end

	-- 9. Wing loading ------------------------------------------------------
	-- A sanity check tying the built mass back to the aerodynamics. The 172
	-- sits around 67 kg/m^2; trainers are light, jets are far heavier.
	local wingLoading = m.mass / definition.reference.wingArea
	checkRange("Wing loading", wingLoading, 55, 80, "kg/m2")

	-- Power loading, kg per kilowatt. The 172 is about 8.3.
	local powerLoading = m.mass / (definition.engine.maxPowerW / 1000)
	checkRange("Power loading", powerLoading, 6, 11, "kg/kW")

	model:Destroy()

	local passCount = 0
	for _, r in results do
		if r.passed then
			passCount += 1
		end
	end
	print(string.format("=== %s (%d/%d) ===", allPassed and "ALL PASSED" or "FAILURES PRESENT", passCount, #results))

	return allPassed, results
end

return AircraftBuilder
