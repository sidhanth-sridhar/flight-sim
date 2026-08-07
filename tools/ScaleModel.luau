--!strict
--[[
	ScaleModel - a Studio-only asset scale audit and rescale utility
	================================================================

	NOT part of the game. This directory is not in default.project.json, so
	Rojo never syncs it. It is meant to be pasted into the Command Bar, or
	dropped in as a ModuleScript and required from the Command Bar.

	WHY THIS EXISTS
	---------------
	The project is 1 stud = 1 metre and the CODE-BUILT world is already built
	to published dimensions (see AirportService's RUNWAY_WIDTH = 23, and
	Cessna172.runTests()'s 8.28 x 11.00 x 2.72 m envelope assertion). What is
	NOT covered by those tests is anything IMPORTED - a Sketchfab mesh, a
	toolbox model, anything hand-placed in Studio. Imported assets arrive at
	whatever scale the exporter felt like, and nothing in the repo checks them.

	This tool measures those, tells you the factor, and applies it.

	THE ONE RULE: USE Model:ScaleTo, NEVER SET part.Size
	---------------------------------------------------
	Walking a model and multiplying every part's Size is the obvious approach
	and it is wrong. It leaves behind:

	  - Weld/Motor6D C0 and C1 offsets, so the model comes apart.
	  - Attachment.Position, so constraints, particles and sounds detach.
	  - SpecialMesh.Scale and MeshPart mesh data.
	  - The gaps BETWEEN parts - each part grows about its own centre, so a
	    fuselage made of ten boxes becomes ten larger boxes in the same ten
	    places, with holes between them.

	Model:ScaleTo handles all of the above. It scales the model about its
	PIVOT, and it is absolute rather than relative - Model:GetScale() returns
	where you are, so a relative change is ScaleTo(GetScale() * factor).

	WHAT ScaleTo STILL DOES NOT DO - check these by hand:
	  - Welds joining a part INSIDE the model to a part OUTSIDE it. The inside
	    end moves, the outside end does not. audit() warns when it finds one.
	  - Sound.RollOffMinDistance / RollOffMaxDistance.
	  - Anything you have stored in Attributes or in a script as a literal.
	  - Humanoid rigs: use Humanoid.BodyDepthScale et al, or ScaleTo on the
	    whole character. (See the journal for 2026-08-05 - R15 scale
	    NumberValues on their own moved the rig 0.00 studs. ScaleTo works.)

	UNIFORM ONLY, ON PURPOSE
	------------------------
	There is no per-axis mode. If one uniform factor cannot hit all three
	target dimensions, the SOURCE MODEL IS DISTORTED, and stretching one axis
	to hide that gives you a Cessna with the wrong aspect ratio. fit() reports
	the per-axis residual so you can see the distortion instead of baking it in.

	USAGE
	-----
		local S = require(game.ServerStorage.ScaleModel)

		-- Look before you leap. Nothing below this line mutates anything.
		print(S.report(workspace.cessna172_low, S.REFERENCE.c172))

		-- Fit to the span (the authoritative dimension for an aeroplane) and
		-- keep the wheels on the ground.
		S.apply(workspace.cessna172_low, S.REFERENCE.c172, {
			axis = "x",
			anchor = "bottom",
		})

		-- Or audit a whole folder at once.
		print(S.auditFolder(workspace, S.REFERENCE.c172))
]]

local ScaleModel = {}

-- =========================================================================
-- REFERENCE DIMENSIONS (metres = studs)
-- =========================================================================
-- Published figures. x = span/width, y = height, z = length, matching how
-- GetBoundingBox reports a model that faces -Z, which is this project's
-- convention (see AirportService: "CFrame's LookVector is (0,0,-1)").

export type Target = { x: number, y: number, z: number }

ScaleModel.REFERENCE = {
	-- Light singles
	c152 = { x = 10.11, y = 2.59, z = 7.34 } :: Target,
	c172 = { x = 11.00, y = 2.72, z = 8.28 } :: Target, -- 172S, TRUE published size

	--[[
		⚠️ THE SIZE THIS PROJECT ACTUALLY DRAWS THE 172 AT (§45).

		Not a real aeroplane. It is the published 172S multiplied by
		15.5 / 8.28 = 1.8720, the visual scale chosen so the aeroplane reads
		big beside a 1.55 m pilot. `c172` above is still the true aeroplane and
		is what a REAL 172 asset should be audited against; this is what the
		in-game one should measure.

		Auditing the game's Cessna against `c172` will report it 87% oversize,
		which is correct and is not a fault to fix.
	]]
	c172b = { x = 20.59, y = 5.09, z = 15.50 } :: Target, -- measured on the built model
	pa28 = { x = 10.67, y = 2.22, z = 7.32 } :: Target, -- Piper Archer
	sr22 = { x = 11.68, y = 2.71, z = 7.92 } :: Target, -- Cirrus
	da40 = { x = 11.94, y = 1.98, z = 8.06 } :: Target, -- Diamond

	-- Twins and light jets
	be350 = { x = 17.65, y = 4.37, z = 14.22 } :: Target, -- King Air 350
	cj4 = { x = 15.49, y = 4.65, z = 16.26 } :: Target, -- Citation CJ4

	-- Airliners (Phase 10)
	b737_800 = { x = 35.79, y = 12.55, z = 39.47 } :: Target,
	a320 = { x = 35.80, y = 11.76, z = 37.57 } :: Target,
	b747_8 = { x = 68.45, y = 19.40, z = 76.25 } :: Target,
	a350_900 = { x = 64.75, y = 17.05, z = 66.80 } :: Target,

	-- Scale companions. A model is easiest to judge next to a known object.
	human = { x = 0.50, y = 1.75, z = 0.30 } :: Target, -- matches PILOT_HEIGHT_M
	car = { x = 1.80, y = 1.45, z = 4.50 } :: Target,
	pushbackTug = { x = 2.00, y = 1.50, z = 4.50 } :: Target,
	fuelTruck = { x = 2.50, y = 3.20, z = 8.50 } :: Target,
	shippingContainer = { x = 2.44, y = 2.59, z = 12.19 } :: Target, -- 40 ft
}

-- =========================================================================
-- MEASUREMENT
-- =========================================================================

--[[
	The model's world-axis-aligned extents.

	GetBoundingBox returns the bounds in the model's OWN pivot frame, which is
	what we want: a Cessna parked at a 30 degree heading must still measure
	11 m across the wings, not the 13.6 m a world-aligned box would report.
]]
function ScaleModel.measure(model: Model): Vector3
	local _, size = model:GetBoundingBox()
	return size
end

--[[
	Best uniform factor to take `model` to `target`, plus what it misses by.

	`axis` picks which dimension is authoritative:
	  "x" / "y" / "z" - hit that one exactly, let the others land where they land
	  "fit" (default) - least-squares over all three, so the error is shared

	For an aeroplane, "x" (span) is usually the right answer. Span is the
	number everyone quotes, it is the largest dimension so it carries the least
	relative measurement error, and it is what the eye reads at a distance.
	Height is the worst choice: it depends on whether the model's undercarriage
	is compressed, and on whether the aerial is modelled.
]]
function ScaleModel.fit(
	model: Model,
	target: Target,
	axis: string?
): (number, Vector3, Vector3)
	local size = ScaleModel.measure(model)
	local mode = axis or "fit"

	if size.X <= 0 or size.Y <= 0 or size.Z <= 0 then
		error(string.format("%s has a zero-width bounding box - is it empty?", model:GetFullName()))
	end

	local factor: number
	if mode == "x" then
		factor = target.x / size.X
	elseif mode == "y" then
		factor = target.y / size.Y
	elseif mode == "z" then
		factor = target.z / size.Z
	elseif mode == "fit" then
		--[[
			Least squares on the three ratios, weighted by target size.

			The plain mean of the three ratios lets the smallest dimension -
			usually height, usually the least trustworthy - pull as hard as the
			span does. Weighting by target magnitude makes the big, reliable
			dimensions decide, which is the same reason "x" is the usual choice.
		]]
		local num = target.x * size.X + target.y * size.Y + target.z * size.Z
		local den = size.X * size.X + size.Y * size.Y + size.Z * size.Z
		factor = num / den
	else
		error(string.format("axis must be x, y, z or fit - got %q", tostring(mode)))
	end

	local scaled = size * factor
	local residual = Vector3.new(
		scaled.X / target.x - 1,
		scaled.Y / target.y - 1,
		scaled.Z / target.z - 1
	)
	return factor, scaled, residual
end

-- =========================================================================
-- HAZARD CHECKS
-- =========================================================================

--[[
	Joints that cross the model's boundary.

	ScaleTo moves everything inside the model and nothing outside it, so a weld
	with one end in each place ends up describing a distance that no longer
	exists. Roblox does not warn about this; the part simply teleports or the
	assembly goes rigid at the wrong offset.
]]
function ScaleModel.crossingJoints(model: Model): { string }
	local found = {}
	for _, d in model:GetDescendants() do
		if d:IsA("JointInstance") then
			for _, prop in { "Part0", "Part1" } do
				local part = (d :: any)[prop] :: BasePart?
				if part and not part:IsDescendantOf(model) then
					table.insert(found, string.format("%s.%s -> %s", d:GetFullName(), prop, part:GetFullName()))
				end
			end
		elseif d:IsA("Attachment") then
			-- Constraints reach across via attachments rather than Part0/Part1.
			for _, c in d:GetChildren() do
				if c:IsA("Constraint") then
					local other = if c.Attachment0 == d then c.Attachment1 else c.Attachment0
					if other and not other:IsDescendantOf(model) then
						table.insert(found, string.format("%s -> %s", c:GetFullName(), other:GetFullName()))
					end
				end
			end
		end
	end
	return found
end

-- =========================================================================
-- REPORT (read-only - run this first, always)
-- =========================================================================

function ScaleModel.report(model: Model, target: Target, axis: string?): string
	local size = ScaleModel.measure(model)
	local factor, scaled, residual = ScaleModel.fit(model, target, axis)
	local lines = {}
	local function add(s: string, ...: any)
		table.insert(lines, string.format(s, ...))
	end

	add("%s   [current Model:GetScale() = %.4f]", model:GetFullName(), model:GetScale())
	add("  axis          now        target       after      err")
	local rows = {
		{ "span   (x)", size.X, target.x, scaled.X, residual.X },
		{ "height (y)", size.Y, target.y, scaled.Y, residual.Y },
		{ "length (z)", size.Z, target.z, scaled.Z, residual.Z },
	}
	for _, r in rows do
		add("  %s %8.2f m %10.2f m %10.2f m %+7.1f%%", r[1], r[2], r[3], r[4], (r[5] :: number) * 100)
	end
	add("  uniform factor = %.4f  (apply as ScaleTo(%.4f))", factor, model:GetScale() * factor)

	local worst = math.max(math.abs(residual.X), math.abs(residual.Y), math.abs(residual.Z))
	if worst > 0.02 then
		add("  ⚠ source model is DISTORTED: %.1f%% off on its worst axis after the", worst * 100)
		add("    best uniform fit. No single factor fixes this. Either accept it,")
		add("    or re-export the asset - do NOT stretch one axis to hide it.")
	end

	local crossing = ScaleModel.crossingJoints(model)
	if #crossing > 0 then
		add("  ⚠ %d joint(s)/constraint(s) leave this model and will break:", #crossing)
		for _, c in crossing do
			add("      %s", c)
		end
	end
	return table.concat(lines, "\n")
end

-- =========================================================================
-- APPLY
-- =========================================================================

export type Options = {
	axis: string?, -- "x" | "y" | "z" | "fit"
	anchor: string?, -- "pivot" (default) | "bottom" | "centre"
	dryRun: boolean?,
}

--[[
	Rescale `model` to `target`.

	ANCHORING. ScaleTo scales about the pivot, so where the model ends up
	depends entirely on where its pivot happens to sit. Three choices:

	  "pivot"  - leave it. Correct when the pivot is meaningful (a builder-made
	             model whose PrimaryPart is the datum).
	  "bottom" - hold the lowest point still. This is the one you want for an
	             aeroplane, a building or a vehicle: the wheels/foundations stay
	             on the ground instead of sinking or floating by the difference.
	  "centre" - hold the bounding-box centre still.

	Getting this wrong is the reason a rescaled aeroplane ends up half-buried.
]]
function ScaleModel.apply(model: Model, target: Target, options: Options?): number
	local opts = options or {} :: Options
	local factor = ScaleModel.fit(model, target, opts.axis)
	local anchor = opts.anchor or "pivot"

	if opts.dryRun then
		print(ScaleModel.report(model, target, opts.axis))
		print("  (dryRun - nothing changed)")
		return factor
	end

	local beforeCF, beforeSize = model:GetBoundingBox()

	model:ScaleTo(model:GetScale() * factor)

	if anchor ~= "pivot" then
		local afterCF, afterSize = model:GetBoundingBox()
		local delta: Vector3
		if anchor == "bottom" then
			local beforeBottom = beforeCF.Position.Y - beforeSize.Y / 2
			local afterBottom = afterCF.Position.Y - afterSize.Y / 2
			delta = Vector3.new(
				beforeCF.Position.X - afterCF.Position.X,
				beforeBottom - afterBottom,
				beforeCF.Position.Z - afterCF.Position.Z
			)
		elseif anchor == "centre" then
			delta = beforeCF.Position - afterCF.Position
		else
			error(string.format("anchor must be pivot, bottom or centre - got %q", anchor))
		end
		-- PivotTo moves the whole assembly rigidly, joints and all.
		model:PivotTo(model:GetPivot() + delta)
	end

	return factor
end

-- =========================================================================
-- BATCH
-- =========================================================================

--[[
	Report on every Model directly under `container`.

	Deliberately shallow: recursing would report on every sub-model of an
	aeroplane as though it were an aeroplane. Point it at the folder that holds
	the things you actually mean.
]]
function ScaleModel.auditFolder(container: Instance, target: Target, axis: string?): string
	local lines = {}
	for _, c in container:GetChildren() do
		if c:IsA("Model") and #c:GetDescendants() > 0 then
			local ok, result = pcall(ScaleModel.report, c, target, axis)
			table.insert(lines, ok and result or string.format("%s  <error: %s>", c:GetFullName(), tostring(result)))
		end
	end
	return #lines > 0 and table.concat(lines, "\n\n") or "no models found in " .. container:GetFullName()
end

--[[
	Everything in the world that is not obviously at metre scale.

	The heuristic is crude and says so: anything whose largest dimension is
	under 0.25 m or over 120 m gets flagged, because at 1 stud = 1 m almost
	nothing legitimately falls outside that - terrain, runways and the field
	itself are built by code and excluded by name. It catches the classic
	import failures, which are the 100x (millimetres read as metres) and the
	0.01x (the exporter's own unit confusion).
]]
function ScaleModel.suspects(container: Instance?, skip: { [string]: boolean }?): string
	local root = container or workspace
	local ignore = skip or { Terrain = true, Airport = true, Baseplate = true, Camera = true }
	local lines = {}
	for _, c in root:GetChildren() do
		if not ignore[c.Name] then
			local size: Vector3? = nil
			if c:IsA("Model") and #c:GetDescendants() > 0 then
				local _, s = c:GetBoundingBox()
				size = s
			elseif c:IsA("BasePart") then
				size = c.Size
			end
			if size then
				local biggest = math.max(size.X, size.Y, size.Z)
				if biggest < 0.25 or biggest > 120 then
					table.insert(lines, string.format(
						"  %-28s %7.2f x %7.2f x %7.2f m   (largest %.2f m)",
						c.Name, size.X, size.Y, size.Z, biggest))
				end
			end
		end
	end
	if #lines == 0 then
		return "nothing suspicious in " .. root:GetFullName()
	end
	table.insert(lines, 1, "Possibly mis-scaled under " .. root:GetFullName() .. ":")
	return table.concat(lines, "\n")
end

return ScaleModel
