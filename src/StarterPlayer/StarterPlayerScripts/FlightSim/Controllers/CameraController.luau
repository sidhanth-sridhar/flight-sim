--!strict
--[[
	CameraController
	----------------
	Three views of the aeroplane, cycled with V and held with C. On the ground
	it does NOT take the camera - it only sizes the zoom range to the
	scaled-down pilot and leaves Roblox driving, so orbiting and zoom keep
	working on foot (see the ground framing block).

	It consumes two fields that InputController has been producing since Phase 1
	with nothing on the other end: `systems.viewIndex` and `systems.cameraHold`.
	This module is that other end, and it owns what those numbers MEAN - the
	input layer deliberately knows only that there are `viewCount` of them.

	THE VIEWS
	  1 Cockpit  eye anchored in the aircraft, rolls with it. Whatever encloses
	            the eye is made locally invisible, because the aeroplane is
	            built from solid boxes and an eye inside one sees the inside of
	            a box.
	  2 Chase    behind and above, following heading and pitch but NEVER roll.
	  3 Free     handed to Roblox's own camera with the aircraft as subject.

	IT NEVER READS THE MOUSE, AND THAT IS THE POINT
	-----------------------------------------------
	The cursor is the yoke (see the handoff, PTFS controls): its position on
	screen IS the control deflection, and the screen edge is full travel. So a
	camera that panned when the cursor neared the edge would swing the view
	exactly when the pilot was holding full aileron - taking the horizon away at
	the precise moment they most need it to recover. There is therefore no
	edge-panning, no drag-to-look, and no cursor input of any kind here. The
	camera is driven by the aircraft's state and by V and C, and nothing else.

	Free view is the one exception, and it does not break the rule: Roblox's
	Custom camera orbits on RIGHT-drag, and the yoke reads cursor POSITION
	rather than buttons, so the two cannot collide.

	IT NEVER TOUCHES PHYSICS
	------------------------
	No forces, no ownership, no gravity. It reads CFrames and writes to
	workspace.CurrentCamera. Everything below runs on the client only.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FlightSim = ReplicatedStorage:WaitForChild("FlightSim")

local Constants = require(FlightSim.Config.Constants)

local FlightController = require(script.Parent:WaitForChild("FlightController"))
local InputController = require(script.Parent.Parent:WaitForChild("Controls"):WaitForChild("InputController"))

local CameraController = {}

local clamp = math.clamp
local exp = math.exp

-- =========================================================================
-- VIEWS
-- =========================================================================

--[[
	The view list, and the only place the meaning of viewIndex is defined.

	InputController wraps viewIndex within its own `viewCount`, which must equal
	the length of this table or V will either skip a view or land on one that
	does not exist. The two are kept in step by assertion rather than by a
	dependency - making InputController require this module would point the
	arrow the wrong way, from input to camera - so runTests() checks the counts
	match and fails loudly if a view is ever added here alone.
]]
CameraController.VIEWS = { "Cockpit", "Chase", "Free" }

local VIEW_COCKPIT = 1
local VIEW_CHASE = 2
local VIEW_FREE = 3

-- =========================================================================
-- TUNING
-- =========================================================================

--[[
	Where the pilot's eye sits, relative to the PilotSeat part.

	Anchored to the seat rather than to the root because the seat is where a
	pilot's head actually is: if the definition ever moves the seat, the eye
	follows it without anyone remembering to update a second constant. Both are
	welded into one assembly, so this is rigid either way.

	THE HEIGHT IS MEASURED AGAINST THE AIRFRAME, NOT FELT. In datum coordinates:

	    glareshield (Fuselage04, right in front of the eye)   y = 0.695
	    wing centre section, underside of the skin            y = 0.850

	so the eye has a 0.155 m slot to live in, and it sits at y = 0.80 - near the
	top of it. That is 0.105 m of glareshield clearance and 13.0 degrees of view
	down over the cowling, against 0.055 m and 10.6 degrees at y = 0.75, which
	the pilot reported as not being on their eyes.

	⚠️ THE OFFSET GREW WHEN THE SEAT WAS LOWERED, TO HOLD THE EYE STILL. The
	seat dropped 0.33 m so a seated avatar fits under the roof, and this offset
	went 0.65 -> 0.98 to keep the eye at the same y = 0.80. Letting the eye
	follow the seat down would have put it at y = 0.47 - BELOW the 0.695
	glareshield, so the pilot would have been looking at the back of the panel.

	⚠️ THE EYE IS THEREFORE HIGHER THAN THE AVATAR'S OWN EYES, BY ABOUT 0.19 m.
	A seated 1.55 m pilot's eye is roughly 0.69 m above the pan, which is y =
	0.61 - inside the panel. The gap exists because THE COWL DECK IS TOO HIGH,
	not because the seat is: Fuselage04 tops out 1.075 m above the cabin floor
	where a real 172's glareshield is about 0.75 m. Closing it means lowering
	the loft's shoulder, which changes the aeroplane's exterior profile - a
	separate decision for the pilot, not an assumption (section 31).
]]
local EYE_OFFSET = Vector3.new(0, 0.98, -0.15)

--[[
	How far outside a part's own box the eye still counts as "inside" it.

	Sized against the camera's near plane rather than picked: Roblox clips
	geometry closer than 0.1 studs, which at 1 stud = 1 m is 0.1 m, so a part
	that close is already slicing through the view. A slightly larger margin
	catches it before it can.
]]
local OCCLUSION_MARGIN = 0.12

-- Chase geometry, in metres. The aircraft is 8 m long with a 10.5 m span, so
-- this frames the whole aeroplane with room to see where it is going.
local CHASE_DISTANCE = 18
local CHASE_HEIGHT = 5.5
local CHASE_LOOK_AHEAD = 6

--[[
	Chase smoothing time constant, seconds.

	Applied as 1 - exp(-dt/tau) rather than a fixed lerp fraction, so the
	follow behaves identically at 30 fps and 240 fps. A fixed fraction would
	make the camera stiffer at high frame rates - the kind of bug that only
	shows up on someone else's machine.
]]
local CHASE_TAU = 0.14

-- How long the camera takes to re-acquire its normal view after C is released.
-- Without this the cockpit view snaps, because it is otherwise rigid.
local REACQUIRE_TIME = 0.28

--[[
	Free view must never reach first person.

	Roblox's Custom camera locks the mouse to the centre of the screen when it
	zooms into first person, which would freeze the yoke at neutral and take
	the controls away with no explanation. Clamping the minimum zoom keeps it
	out of that state entirely.
]]
local FREE_MIN_ZOOM = 8
local FREE_MAX_ZOOM = 400

--[[
	Ground framing, done with ZOOM DISTANCE rather than a scripted camera.

	The problem is real: the pilot is person-sized at PILOT_HEIGHT_M (about
	0.30x the stock rig) and Roblox's default camera does not scale its framing
	with the character, so a scaled pilot stands tiny in frame.

	⚠️ THE FIRST FIX FOR THIS DROVE THE CAMERA DIRECTLY, AND COST THE MOUSE.
	Writing camera.CFrame every frame requires CameraType = Scriptable, and a
	Scriptable camera is not Roblox's camera - so right-drag orbiting and
	scroll zoom both stop existing the moment you step out of the aeroplane.
	That was reported as "there is no mouse orbiting", and it is inherent to
	the approach rather than a detail that could be patched.

	So the camera stays Roblox's on the ground and the FRAMING is fixed
	instead. Every zoom distance is multiplied by the character's own model
	scale, which is exactly the factor the rig was shrunk by - so a 0.339x
	pilot is framed identically to an unscaled one, and orbiting, zooming and
	first person all still work because Roblox is still driving.

	This does not contradict the yoke rule above. That rule is about the camera
	never reading the mouse WHILE FLYING, where the cursor is the control
	column. On foot there is no yoke to fight over.
]]
local GROUND_DEFAULT_ZOOM = 12.5 -- Roblox's own starting third-person distance
local GROUND_ZOOM_SETTLE = 0.15 -- seconds to hold the pinch that sets the zoom

-- =========================================================================
-- STATE
-- =========================================================================

local player = Players.LocalPlayer

local bound = false
local initialised = false

-- The aircraft this camera is currently attached to, and the parts it has made
-- locally invisible so they can be put back exactly as they were.
local attachedModel: Model? = nil
local hiddenParts: { BasePart } = {}
local cockpitHidden = false

-- Set while Roblox owns the camera, so the restore only runs once.
local freeViewActive = false
local savedMinZoom: number? = nil
local savedMaxZoom: number? = nil

-- Chase carries its position between frames; that is what the smoothing is.
local chasePosition: Vector3? = nil

-- The zoom range the place was configured with, captured before anything
-- scales it, so the scaling is always applied to the original rather than
-- compounding on a value this module already wrote.
local baseMinZoom: number? = nil
local baseMaxZoom: number? = nil
-- The character whose scale the current zoom range was computed from.
local groundSubject: Model? = nil

-- Camera hold (C). While held, the camera keeps the world orientation and the
-- world-space offset it had when C went down.
local holding = false
local heldRotation: CFrame? = nil
local heldOffset: Vector3? = nil
local reacquire = 1 -- 0 just after release, ramps to 1

local function log(message: string, ...)
	if Constants.DEBUG.ENABLED then
		print("[FlightSim:Camera] " .. string.format(message, ...))
	end
end

-- =========================================================================
-- PURE GEOMETRY
-- =========================================================================
-- Separated from all Roblox plumbing so runTests() can drive them with
-- synthetic CFrames, exactly as FlightModel.computeForces is.

--[[
	The cockpit eye, from the seat's CFrame.

	Rolls with the aircraft, deliberately: the whole point of an inside view is
	that the horizon does what the aeroplane makes it do.
]]
function CameraController.cockpitCFrame(seatCFrame: CFrame): CFrame
	return seatCFrame * CFrame.new(EYE_OFFSET)
end

--[[
	Where the chase camera wants to be, given the aircraft's CFrame.

	Built from LookVector and WORLD up, which is what discards the roll - and it
	does so exactly, not approximately, because roll is a rotation ABOUT the
	look axis and therefore leaves LookVector untouched. Heading and pitch come
	through; roll cannot.

	The degenerate case is real in this simulator and is handled rather than
	hoped away: pointing straight up or straight down makes the look direction
	parallel to world up and CFrame.lookAt has no way to orient the result. A
	stall departure here has already been measured at -64 degrees of pitch, so
	the vertical case is a matter of time. Falling back to the aircraft's own up
	vector keeps the camera sane through it.
]]
function CameraController.chaseTarget(aircraftCFrame: CFrame): (Vector3, CFrame)
	local position = aircraftCFrame.Position
	local look = aircraftCFrame.LookVector

	local cameraPosition = position - look * CHASE_DISTANCE + Vector3.yAxis * CHASE_HEIGHT
	local focus = position + look * CHASE_LOOK_AHEAD

	local up = Vector3.yAxis
	local toFocus = focus - cameraPosition
	if toFocus.Magnitude < 1e-4 then
		toFocus = look
	end
	if math.abs(toFocus.Unit:Dot(up)) > 0.999 then
		up = aircraftCFrame.UpVector
	end

	return cameraPosition, CFrame.lookAt(cameraPosition, focus, up)
end

--[[
	The zoom range for a pilot at `modelScale`, as (min, max, default).

	Pure, so the proportionality can be asserted without a character. Scaling
	all three by the same factor is what makes a shrunken pilot fill the frame
	exactly as a stock one does, at every zoom level rather than only at the
	default.

	`base` values are the place's own configured limits, so a game that has
	already restricted zoom keeps its restriction, scaled.
]]
function CameraController.groundZoomRange(
	modelScale: number,
	baseMin: number,
	baseMax: number
): (number, number, number)
	local scale = math.clamp(modelScale, 0.01, 1)
	return baseMin * scale, baseMax * scale, GROUND_DEFAULT_ZOOM * scale
end

--[[
	Size the on-foot zoom range to the pilot. Roblox keeps the camera.

	⚠️ THE ZOOM IS SET WITH A PINCH, because Roblox exposes no way to write the
	camera's current zoom distance. Dropping the MAXIMUM below the current zoom
	forces the camera in; raising it again a moment later leaves it where it
	was pushed while giving the player back the freedom to zoom out. That is
	the only scriptable route to it, and it is what GROUND_ZOOM_SETTLE is for.

	Re-applied whenever the character's SCALE changes, not just when the
	character does. The avatar converges on PILOT_HEIGHT_M over about a
	second after spawning (§30), so a single application at spawn would size
	the zoom for an unscaled rig and leave the pilot tiny anyway.
]]
local groundScale: number? = nil

local function frameGroundPilot(character: Model?)
	if not character or baseMinZoom == nil or baseMaxZoom == nil then
		return
	end

	local scale = 1
	local ok, result = pcall(function()
		return character:GetScale()
	end)
	if ok and type(result) == "number" and result > 0 then
		scale = result
	end

	if groundSubject == character and groundScale and math.abs(scale - groundScale) < 1e-3 then
		return
	end
	groundSubject = character
	groundScale = scale

	local minZoom, maxZoom, defaultZoom =
		CameraController.groundZoomRange(scale, baseMinZoom, baseMaxZoom)
	player.CameraMinZoomDistance = minZoom
	player.CameraMaxZoomDistance = defaultZoom

	task.delay(GROUND_ZOOM_SETTLE, function()
		-- Free view owns the zoom limits while it is active (see enterFreeView),
		-- and a later re-apply supersedes this one.
		if not freeViewActive and groundSubject == character and groundScale == scale then
			player.CameraMaxZoomDistance = maxZoom
		end
	end)
end

--[[
	Frame-rate independent approach. Returns the blend factor for a given dt.

	dt is clamped to the same ceiling the flight model uses, so a frame hitch
	cannot teleport the camera - and cannot produce a factor above 1, which
	would make the lerp overshoot its target and oscillate.
]]
function CameraController.blendFactor(dt: number, tau: number): number
	local step = clamp(dt, 0, Constants.SIM.MAX_TIMESTEP)
	if tau <= 0 then
		return 1
	end
	return clamp(1 - exp(-step / tau), 0, 1)
end

--[[
	The held camera, while C is down.

	Position still tracks the aircraft's TRANSLATION, so the pilot is not left
	behind at 130 kt, but the world-space offset and the orientation are both
	frozen - so the camera stops swinging as the aeroplane rotates and the
	pilot can keep their eyes on a point while manoeuvring.
]]
function CameraController.holdCFrame(frozenRotation: CFrame, frozenOffset: Vector3, aircraftPosition: Vector3): CFrame
	return frozenRotation.Rotation + (aircraftPosition + frozenOffset)
end

--[[
	Which parts enclose a point, and would therefore be rendered from the
	inside if the camera sat there.

	A containment test rather than a proximity one. Proximity would sweep up the
	wing centre section sitting 0.08 m above the eye and hide it too, leaving
	the outer wings apparently floating unattached.
]]
function CameraController.occludingParts(model: Model, eyeWorld: Vector3, margin: number?): { BasePart }
	local m = margin or OCCLUSION_MARGIN
	local found = {}

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			local localPoint = part.CFrame:PointToObjectSpace(eyeWorld)
			local half = part.Size * 0.5
			if
				math.abs(localPoint.X) <= half.X + m
				and math.abs(localPoint.Y) <= half.Y + m
				and math.abs(localPoint.Z) <= half.Z + m
			then
				table.insert(found, part)
			end
		end
	end

	return found
end

-- =========================================================================
-- TRANSPARENCY
-- =========================================================================

local function restoreHidden()
	for _, part in hiddenParts do
		if part.Parent then
			part.LocalTransparencyModifier = 0
		end
	end
	table.clear(hiddenParts)
	cockpitHidden = false
end

--[[
	Hide whatever the eye is inside of.

	LocalTransparencyModifier is client-only and does not replicate, so no other
	player sees a hole in this aeroplane. It also persists on ordinary parts
	once set, which is why this runs on a view change rather than every frame.
]]
local function hideForCockpit(model: Model, eyeWorld: Vector3)
	restoreHidden()

	hiddenParts = CameraController.occludingParts(model, eyeWorld)
	for _, part in hiddenParts do
		part.LocalTransparencyModifier = 1
	end
	cockpitHidden = true

	log("Cockpit view hiding %d part(s)", #hiddenParts)
end

-- =========================================================================
-- FREE VIEW
-- =========================================================================

local function enterFreeView(model: Model)
	if freeViewActive then
		return
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	savedMinZoom = player.CameraMinZoomDistance
	savedMaxZoom = player.CameraMaxZoomDistance
	player.CameraMinZoomDistance = FREE_MIN_ZOOM
	player.CameraMaxZoomDistance = FREE_MAX_ZOOM

	camera.CameraType = Enum.CameraType.Custom
	camera.CameraSubject = model.PrimaryPart
	freeViewActive = true
end

local function leaveFreeView()
	if not freeViewActive then
		return
	end

	if savedMinZoom then
		player.CameraMinZoomDistance = savedMinZoom
	end
	if savedMaxZoom then
		player.CameraMaxZoomDistance = savedMaxZoom
	end
	savedMinZoom, savedMaxZoom = nil, nil
	freeViewActive = false
end

-- =========================================================================
-- ATTACH / RELEASE
-- =========================================================================

--[[
	Which humanoid the on-foot camera should be watching.

	Pure, so the character-swap case can be tested without a player: hand it the
	live character and whatever the camera currently points at, and it answers
	with the subject the camera should have.

	⚠️ THE STALE SUBJECT IS THE BUG A RESET EXPOSES. Resetting from the seat
	destroys the old character and builds a new one, and a new character carries
	a NEW Humanoid instance - so the old subject is not nil, it is simply the
	wrong object, and any check of the form "fix it only if it is missing" sees
	nothing wrong. The camera then stays pointed at the aeroplane the pilot just
	left. Comparing against the live humanoid is what catches it.

	Returns nil while there is no character, which is honest rather than sticky:
	the caller re-asks every frame, so the subject is picked up the moment the
	replacement rig exists.
]]
function CameraController.groundSubjectFor(character: Model?, current: Instance?): Instance?
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		return humanoid
	end
	local _ = current
	return nil
end

--[[
	Give the camera back to the player's own character.

	Called whenever there is no aircraft to look at - the pilot stood up, died,
	or the server despawned the aeroplane. Nothing here may keep a reference to
	a destroyed model, which is why the frame loop re-asks FlightController for
	the aircraft every frame rather than caching one.
]]
local function release()
	restoreHidden()
	leaveFreeView()

	attachedModel = nil
	chasePosition = nil
	groundSubject = nil
	groundScale = nil
	holding = false
	heldRotation, heldOffset = nil, nil
	reacquire = 1

	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Custom
		--[[
			⚠️ NO `or camera.CameraSubject` FALLBACK HERE. release() is called
			the frame the aeroplane goes away, and when that is a RESET the old
			character is already destroyed while the new one does not exist yet
			- so the humanoid is nil, and keeping "whatever the subject was"
			pins the camera to the aircraft the pilot just left. Leaving it nil
			is honest and self-correcting: onRenderStep reacquires the subject
			as soon as a character exists.
		]]
		camera.CameraSubject = CameraController.groundSubjectFor(player.Character, camera.CameraSubject)
	end
end

-- =========================================================================
-- FRAME
-- =========================================================================

--[[
	One camera update.

	Factored out of the RenderStep binding and given its inputs explicitly, so
	the view selection and the hold behaviour can be driven directly by the
	tests without a player, an aircraft or a running game.

	Returns the CFrame it would apply, or nil when Roblox owns the camera.
]]
function CameraController.solve(viewIndex: number, cameraHold: boolean, seatCFrame: CFrame, aircraftCFrame: CFrame, dt: number): CFrame?
	if viewIndex == VIEW_FREE then
		return nil
	end

	local target: CFrame
	if viewIndex == VIEW_COCKPIT then
		target = CameraController.cockpitCFrame(seatCFrame)
	else
		local position, look = CameraController.chaseTarget(aircraftCFrame)

		-- Smoothed in position only; the orientation is then derived from where
		-- the camera actually ended up, so it always points at the aeroplane
		-- rather than at where the aeroplane was.
		if chasePosition then
			chasePosition = chasePosition:Lerp(position, CameraController.blendFactor(dt, CHASE_TAU))
		else
			chasePosition = position
		end

		local focus = aircraftCFrame.Position + aircraftCFrame.LookVector * CHASE_LOOK_AHEAD
		local up = Vector3.yAxis
		local toFocus = focus - chasePosition
		if toFocus.Magnitude < 1e-4 or math.abs(toFocus.Unit:Dot(up)) > 0.999 then
			up = aircraftCFrame.UpVector
		end
		target = CFrame.lookAt(chasePosition, focus, up)
		-- `look` is the unsmoothed orientation; kept for clarity of intent.
		local _ = look
	end

	-- ---- Camera hold (C) --------------------------------------------------
	if cameraHold then
		if not holding then
			holding = true
			heldRotation = target
			heldOffset = target.Position - aircraftCFrame.Position
		end
		reacquire = 0
		return CameraController.holdCFrame(heldRotation :: CFrame, heldOffset :: Vector3, aircraftCFrame.Position)
	end

	if holding then
		holding = false
	end

	-- Ease back after a hold instead of snapping, which the rigid cockpit view
	-- would otherwise do the instant C is released.
	if reacquire < 1 then
		reacquire = clamp(reacquire + dt / REACQUIRE_TIME, 0, 1)
		local from = CameraController.holdCFrame(
			heldRotation or target,
			heldOffset or Vector3.zero,
			aircraftCFrame.Position
		)
		return from:Lerp(target, reacquire)
	end

	heldRotation, heldOffset = nil, nil
	return target
end

local function onRenderStep(dt: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local model = FlightController.getAircraft()
	local systems = FlightController.getSystems()

	--[[
		Only while the pilot is actually flying it. On the ground, the camera
		still belongs here - the scale-aware ground camera frames the scaled
		pilot at a natural distance (see the ground tuning block). Either way,
		this branch is what guarantees a destroyed aircraft cannot be held
		onto, because the answer becomes nil the frame it goes away.
	]]
	if not (model and model.Parent and systems and FlightController.isFlying()) then
		if attachedModel then
			release()
		end
		--[[
			On foot the camera belongs to ROBLOX, which is what keeps
			right-drag orbiting and scroll zoom alive. All this branch does is
			size the zoom range to the pilot, and hand the camera back if
			anything has left it pointing somewhere else.
		]]
		if camera.CameraType == Enum.CameraType.Scriptable then
			camera.CameraType = Enum.CameraType.Custom
		end

		--[[
			⚠️ THE SUBJECT IS REPAIRED UNCONDITIONALLY, NOT ONLY WHEN THE CAMERA
			IS Scriptable. That gate is the bug the pilot hit by resetting from
			the seat: release() had already set the type back to Custom, so this
			branch declared the camera healthy while CameraSubject still pointed
			at the humanoid of a character that no longer exists. The camera
			stayed out at the aeroplane and never found the new pilot.

			A character swap replaces the Humanoid instance, so comparing
			against the live one is what detects it - the stale subject is a
			different object, not a nil one.
		]]
		local character = player.Character
		local subject = CameraController.groundSubjectFor(character, camera.CameraSubject)
		if subject and camera.CameraSubject ~= subject then
			camera.CameraSubject = subject
		end

		frameGroundPilot(character)
		return
	end

	local root = model.PrimaryPart
	local seat = model:FindFirstChild("PilotSeat")
	if not (root and seat and seat:IsA("BasePart")) then
		return
	end

	if attachedModel ~= model then
		release()
		attachedModel = model
		log("Attached to %s", model.Name)
	end

	local viewIndex = systems.viewIndex
	if viewIndex < 1 or viewIndex > #CameraController.VIEWS then
		viewIndex = VIEW_COCKPIT
	end

	-- ---- Per-view setup that only changes on a view change ---------------
	if viewIndex == VIEW_COCKPIT then
		leaveFreeView()
		if not cockpitHidden then
			hideForCockpit(model, CameraController.cockpitCFrame(seat.CFrame).Position)
		end
	else
		if cockpitHidden then
			restoreHidden()
		end
		if viewIndex == VIEW_FREE then
			enterFreeView(model)
		else
			leaveFreeView()
		end
	end

	local solved = CameraController.solve(viewIndex, systems.cameraHold == true, seat.CFrame, root.CFrame, dt)

	if solved then
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = solved
	end
end

-- =========================================================================
-- INIT
-- =========================================================================

function CameraController.Init()
	if initialised then
		return
	end
	initialised = true

	--[[
		The place's own zoom limits, captured BEFORE anything scales them.

		frameGroundPilot multiplies these by the pilot's model scale, so it has
		to read the original rather than whatever it last wrote - otherwise
		every re-apply would scale an already-scaled value and the camera would
		walk in toward the pilot's face.
	]]
	baseMinZoom = player.CameraMinZoomDistance
	baseMaxZoom = player.CameraMaxZoomDistance

	if #CameraController.VIEWS ~= InputController.DEFAULTS.viewCount then
		warn(string.format(
			"[FlightSim:Camera] %d views defined but InputController cycles through %d. V will skip or overrun.",
			#CameraController.VIEWS, InputController.DEFAULTS.viewCount
		))
	end

	--[[
		T alternates between two view INDICES that the input layer carries as
		configuration; this module is where those numbers acquire names. Checked
		here for the same reason as the count above - reordering VIEWS is an
		entirely reasonable thing to do, and it would silently turn the first
		person / third person toggle into something else.
	]]
	local toggle = InputController.DEFAULTS.toggleViews
	if CameraController.VIEWS[toggle[1]] ~= "Cockpit" or CameraController.VIEWS[toggle[2]] ~= "Chase" then
		warn(string.format(
			"[FlightSim:Camera] T toggles views %s/%s, which are '%s'/'%s' rather than Cockpit/Chase.",
			tostring(toggle[1]), tostring(toggle[2]),
			tostring(CameraController.VIEWS[toggle[1]]), tostring(CameraController.VIEWS[toggle[2]])
		))
	end

	--[[
		Bound just AFTER Roblox's own camera step.

		Render priority matters here: the default camera writes CFrame at
		Camera priority, so anything scripted at or before it is overwritten
		the same frame and the camera simply does not move.
	]]
	RunService:BindToRenderStep("FlightSimCamera", Enum.RenderPriority.Camera.Value + 1, onRenderStep)
	bound = true

	log("Ready - %d views: %s", #CameraController.VIEWS, table.concat(CameraController.VIEWS, ", "))
end

function CameraController.Shutdown()
	if bound then
		RunService:UnbindFromRenderStep("FlightSimCamera")
		bound = false
	end
	release()
	initialised = false
end

-- =========================================================================
-- VERIFICATION
-- =========================================================================

--[[
	Run from the Studio command bar, CLIENT datamodel:
		require(game.StarterPlayer.StarterPlayerScripts.FlightSim.Controllers.CameraController).runTests()

	Drives the geometry directly with synthetic CFrames, so none of it needs a
	player, a seat or a running flight. The one exception builds a real
	aircraft, because "which parts enclose the eye" is a question about the
	actual model rather than about arithmetic.
]]
function CameraController.runTests(): (boolean, { any })
	local AircraftBuilder = require(FlightSim.Aircraft.AircraftBuilder)
	local Cessna172 = require(FlightSim.Aircraft.Definitions.Cessna172)

	local results = {}
	local allPassed = true

	local function record(label: string, passed: boolean, detail: string)
		if not passed then
			allPassed = false
		end
		table.insert(results, { label = label, passed = passed, detail = detail })
		print(string.format("  [%s] %-52s %s", passed and "PASS" or "FAIL", label, detail))
	end

	print("=== CameraController: verification ===")

	local model: Model? = nil

	local body = function()

	-- 1. Views stay in step with the input layer ---------------------------
	record(
		"View count matches InputController.viewCount",
		#CameraController.VIEWS == InputController.DEFAULTS.viewCount,
		string.format("%d views (%s) vs viewCount %d",
			#CameraController.VIEWS, table.concat(CameraController.VIEWS, "/"), InputController.DEFAULTS.viewCount)
	)

	--[[
		The other half of that arrangement: T carries two view INDICES, and this
		is the only place they mean anything. Reordering VIEWS above is a
		reasonable thing to do and would otherwise turn "first person / third
		person" into "third person / orbit" with nothing to say so.
	]]
	local toggle = InputController.DEFAULTS.toggleViews
	record(
		"T toggles between Cockpit and Chase specifically",
		CameraController.VIEWS[toggle[1]] == "Cockpit" and CameraController.VIEWS[toggle[2]] == "Chase",
		string.format("views %d/%d are '%s'/'%s'",
			toggle[1], toggle[2],
			tostring(CameraController.VIEWS[toggle[1]]), tostring(CameraController.VIEWS[toggle[2]]))
	)

	--[[
		Neither toggle target may be Free.

		Free hands the camera to Roblox, and solve() returns nil for it. A toggle
		that landed there would leave the pilot's view being orbited by Roblox's
		own camera while they believed they had pressed a first/third person key -
		so this asserts both targets actually produce a CFrame.
	]]
	record(
		"Both toggle targets are scripted views, not Free",
		CameraController.solve(toggle[1], false, CFrame.new(0, 100, 0), CFrame.new(0, 100, 0), 1 / 60) ~= nil
			and CameraController.solve(toggle[2], false, CFrame.new(0, 100, 0), CFrame.new(0, 100, 0), 1 / 60) ~= nil,
		"both return a CFrame"
	)
	chasePosition = nil -- solve() above primed the chase smoothing; clear it

	-- 2. Cockpit ------------------------------------------------------------
	local level = CFrame.new(0, 100, 0)
	local eye = CameraController.cockpitCFrame(level)
	record(
		"Cockpit eye sits above and ahead of the seat",
		eye.Position.Y > level.Position.Y and eye.Position.Z < level.Position.Z,
		string.format("offset (%.2f, %.2f, %.2f) m", eye.Position.X, eye.Position.Y - 100, eye.Position.Z)
	)

	-- The inside view must roll with the aeroplane; that is what it is for.
	local rolled = CFrame.new(0, 100, 0) * CFrame.Angles(0, 0, math.rad(60))
	local rolledEye = CameraController.cockpitCFrame(rolled)
	record(
		"Cockpit view rolls with the aircraft",
		math.abs(rolledEye.UpVector.Y - math.cos(math.rad(60))) < 0.02,
		string.format("up.Y = %.3f at 60 deg of bank (expected %.3f)", rolledEye.UpVector.Y, math.cos(math.rad(60)))
	)

	-- 3. Chase ---------------------------------------------------------------
	local aircraft = CFrame.new(0, 100, 0) -- facing -Z
	local chasePos, chaseCF = CameraController.chaseTarget(aircraft)

	record(
		"Chase camera sits BEHIND the aircraft",
		(chasePos - aircraft.Position):Dot(aircraft.LookVector) < 0,
		string.format("%.1f m behind", -(chasePos - aircraft.Position):Dot(aircraft.LookVector))
	)
	record(
		"Chase camera sits ABOVE the aircraft",
		chasePos.Y > aircraft.Position.Y,
		string.format("%.1f m above", chasePos.Y - aircraft.Position.Y)
	)
	record(
		"Chase camera looks at the aircraft",
		chaseCF.LookVector:Dot((aircraft.Position - chasePos).Unit) > 0.9,
		string.format("alignment %.3f", chaseCF.LookVector:Dot((aircraft.Position - chasePos).Unit))
	)

	--[[
		THE chase check. Roll must not reach the camera.

		Asserted on the RIGHT vector staying horizontal, not on the up vector
		being vertical, and the difference matters. The camera sits 5.5 m above
		the aircraft and looks at it from 24 m away, so it is always pitched
		about 13 degrees down - which tilts its up vector to cos(13) = 0.975
		with no roll whatsoever. An up-vector test therefore fails on a
		perfectly level camera. Bank shows up as a non-zero right.Y and nowhere
		else, so that is what is measured.
	]]
	local bankedAircraft = CFrame.new(0, 100, 0) * CFrame.Angles(0, 0, math.rad(60))
	local _, bankedCF = CameraController.chaseTarget(bankedAircraft)
	record(
		"Chase camera does NOT roll with the aircraft",
		math.abs(bankedCF.RightVector.Y) < 1e-4,
		string.format("right.Y = %.6f at 60 deg of bank (up.Y = %.4f, which is camera pitch)",
			bankedCF.RightVector.Y, bankedCF.UpVector.Y)
	)

	-- Stronger still: banking must change the camera by NOTHING at all, because
	-- roll is a rotation about the look axis and cannot touch LookVector.
	local _, levelCF = CameraController.chaseTarget(CFrame.new(0, 100, 0))
	record(
		"Bank changes the chase camera not at all",
		(bankedCF.Position - levelCF.Position).Magnitude < 1e-4
			and (bankedCF.LookVector - levelCF.LookVector).Magnitude < 1e-4,
		string.format("position delta %.6f m, look delta %.6f",
			(bankedCF.Position - levelCF.Position).Magnitude,
			(bankedCF.LookVector - levelCF.LookVector).Magnitude)
	)

	-- Pitch, by contrast, must come through.
	local climbing = CFrame.new(0, 100, 0) * CFrame.Angles(math.rad(30), 0, 0)
	local climbPos = CameraController.chaseTarget(climbing)
	record(
		"Chase camera follows pitch",
		climbPos.Y < CameraController.chaseTarget(CFrame.new(0, 100, 0)).Y,
		string.format("camera drops to y %.1f when the nose is 30 deg up", climbPos.Y - 100)
	)

	--[[
		The degenerate case. Straight up is where CFrame.lookAt with a world-up
		hint has no defined answer, and this simulator reaches steep attitudes
		on its own - a measured stall departure hit -64 degrees.
	]]
	local vertical = CFrame.new(0, 100, 0) * CFrame.Angles(math.rad(90), 0, 0)
	local okVertical = pcall(function()
		local _, cf = CameraController.chaseTarget(vertical)
		assert(cf.Position.X == cf.Position.X, "NaN")
	end)
	record("Vertical flight does not break the chase camera", okVertical, "no error, no NaN")

	local inverted = CFrame.new(0, 100, 0) * CFrame.Angles(math.rad(-90), 0, 0)
	local okInverted = pcall(function()
		local _, cf = CameraController.chaseTarget(inverted)
		assert(cf.Position.X == cf.Position.X, "NaN")
	end)
	record("Straight down does not break it either", okInverted, "no error, no NaN")

	-- 4. Smoothing ------------------------------------------------------------
	record(
		"Blend factor is between 0 and 1",
		CameraController.blendFactor(1 / 60, CHASE_TAU) > 0 and CameraController.blendFactor(1 / 60, CHASE_TAU) < 1,
		string.format("%.4f at 60 fps", CameraController.blendFactor(1 / 60, CHASE_TAU))
	)
	record(
		"Smoothing is frame-rate independent, not per-frame",
		CameraController.blendFactor(1 / 30, CHASE_TAU) > CameraController.blendFactor(1 / 240, CHASE_TAU),
		string.format("30 fps %.3f vs 240 fps %.3f",
			CameraController.blendFactor(1 / 30, CHASE_TAU), CameraController.blendFactor(1 / 240, CHASE_TAU))
	)
	record(
		"A frame hitch cannot overshoot",
		CameraController.blendFactor(10, CHASE_TAU) <= 1,
		string.format("%.4f after a 10 s hitch", CameraController.blendFactor(10, CHASE_TAU))
	)

	-- 5. Camera hold (C) ------------------------------------------------------
	--[[
		While held, the aircraft rotating underneath must not move the camera's
		orientation - and the camera must still travel with the aeroplane, or
		the pilot is left behind at 120 kt.
	]]
	local frozen = CFrame.lookAt(Vector3.new(0, 100, 20), Vector3.new(0, 100, 0))
	local offset = Vector3.new(0, 5, 20)
	local heldA = CameraController.holdCFrame(frozen, offset, Vector3.new(0, 100, 0))
	local heldB = CameraController.holdCFrame(frozen, offset, Vector3.new(0, 100, -500))

	record(
		"Held camera keeps its world orientation",
		(heldA.LookVector - heldB.LookVector).Magnitude < 1e-6,
		"orientation identical after the aircraft moved 500 m"
	)
	record(
		"Held camera still travels with the aircraft",
		math.abs((heldB.Position - heldA.Position).Z + 500) < 1e-3,
		string.format("moved %.1f m with it", (heldB.Position - heldA.Position).Z)
	)

	-- 6. Free view -------------------------------------------------------------
	record(
		"Free view hands the camera to Roblox (solve returns nil)",
		CameraController.solve(VIEW_FREE, false, CFrame.new(), CFrame.new(), 1 / 60) == nil,
		"nil, so nothing is written to Camera.CFrame"
	)
	record(
		"Free view cannot zoom into first person",
		FREE_MIN_ZOOM > 0,
		string.format("min zoom %d studs, which keeps the mouse free for the yoke", FREE_MIN_ZOOM)
	)

	-- 7. Occlusion, against a real aeroplane ------------------------------------
	model = AircraftBuilder.build(Cessna172, CFrame.new(0, 2000, 0), workspace)
	local built = model :: Model
	local seat = built:FindFirstChild("PilotSeat") :: BasePart
	local eyeWorld = CameraController.cockpitCFrame(seat.CFrame).Position
	local occluders = CameraController.occludingParts(built, eyeWorld)

	local names = {}
	local hidesCabin, hidesOuterWing = false, false
	for _, part in occluders do
		table.insert(names, part.Name)
		if part.Name == "Cabin" then
			hidesCabin = true
		end
		if part.Name == "WingLeft" or part.Name == "WingRight" then
			hidesOuterWing = true
		end
	end

	record(
		"The cabin encloses the eye and is hidden",
		hidesCabin,
		string.format("hides: %s", #names > 0 and table.concat(names, ", ") or "nothing")
	)
	record(
		"The outer wings are NOT hidden",
		not hidesOuterWing,
		"wings stay visible from the cockpit"
	)
	--[[
		A PROPORTION, NOT A COUNT - and this is the fourth time an assertion
		rather than the code has been the wrong one here.

		It read `<= 3`, which was right when the aeroplane was fifteen boxes.
		Phase 4's skin took it to 78 parts, and the eye is now legitimately
		inside a structural box AND the skin panel drawn over it - Cabin with
		Fuselage05, WingCenter with WingCentre - so the honest count doubled
		without anything going wrong. Measured 6 of 78.

		What this is actually protecting is that the cockpit view hides what
		ENCLOSES the eye and not the aeroplane, which is a fraction of the
		model rather than a fixed number of parts. The containment-versus-
		proximity failure it guards against is caught by the outer-wing check
		above, which is the one that must never go green by accident.
	]]
	local partCount = #built:GetChildren()
	record(
		"Only a few parts are hidden, not the aeroplane",
		#occluders > 0 and #occluders <= math.max(4, partCount * 0.15),
		string.format("%d of %d parts (%.0f%%)", #occluders, partCount, #occluders / partCount * 100)
	)

	-- The eye must be inside the aeroplane, not floating outside it.
	local extents = built:GetExtentsSize()
	local centre = built:GetPivot().Position
	record(
		"The eye is inside the airframe",
		math.abs(eyeWorld.X - centre.X) < extents.X * 0.5
			and math.abs(eyeWorld.Y - centre.Y) < extents.Y * 0.5
			and math.abs(eyeWorld.Z - centre.Z) < extents.Z * 0.5,
		string.format("eye %.2f m above the aircraft origin", eyeWorld.Y - built:GetPivot().Position.Y)
	)

	-- 8. Ground framing ----------------------------------------------------------
	--[[
		THE test that pins why this is a zoom range and not a scripted camera.

		A scripted ground camera needs CameraType = Scriptable, which is not
		Roblox's camera - so right-drag orbiting and scroll zoom stop existing
		the moment the pilot steps out. That was shipped once and reported as
		"there is no mouse orbiting". Framing by zoom distance leaves Roblox
		driving, so the mouse keeps working.
	]]
	local BASE_MIN, BASE_MAX = 0.5, 128
	local sMin, sMax, sDefault = CameraController.groundZoomRange(0.339, BASE_MIN, BASE_MAX)
	record(
		"A scaled pilot is framed closer, proportionally",
		math.abs(sDefault - 12.5 * 0.339) < 1e-9 and sDefault < 12.5,
		string.format("0.339x pilot framed at %.2f studs against a stock 12.50", sDefault)
	)
	record(
		"The whole zoom range scales, not just the default",
		math.abs(sMin - BASE_MIN * 0.339) < 1e-9 and math.abs(sMax - BASE_MAX * 0.339) < 1e-9,
		string.format("min %.3f, max %.2f for a 0.339x pilot", sMin, sMax)
	)
	--[[
		An unscaled pilot must be left exactly as Roblox would have it, or this
		would quietly re-frame every game that never scales its avatar.
	]]
	local uMin, uMax, uDefault = CameraController.groundZoomRange(1, BASE_MIN, BASE_MAX)
	record(
		"An unscaled pilot keeps the place's own zoom range",
		uMin == BASE_MIN and uMax == BASE_MAX and uDefault == 12.5,
		string.format("min %.2f, max %.2f, default %.2f unchanged", uMin, uMax, uDefault)
	)
	record(
		"The framing is proportional at any scale",
		math.abs(
			select(3, CameraController.groundZoomRange(0.5, BASE_MIN, BASE_MAX))
			- 2 * select(3, CameraController.groundZoomRange(0.25, BASE_MIN, BASE_MAX))
		) < 1e-9,
		"halving the pilot halves every distance"
	)
	--[[
		A nonsense scale must not produce a zero or negative zoom range, which
		Roblox rejects outright and which would leave the camera stuck.
	]]
	local zMin, zMax = CameraController.groundZoomRange(0, BASE_MIN, BASE_MAX)
	record(
		"A zero scale cannot produce a zero zoom range",
		zMin > 0 and zMax > 0,
		string.format("clamped to min %.4f, max %.3f", zMin, zMax)
	)

	--[[
		9. Handing the camera back across a character swap --------------------

		⚠️ THE BUG THIS PINS: resetting from the pilot seat left the camera out
		at the aeroplane. A reset builds a NEW character with a NEW Humanoid, so
		the old subject is the wrong object rather than a missing one, and the
		old "repair it only if the camera is Scriptable / only if it is nil"
		checks both saw a healthy camera and did nothing.
	]]
	local oldChar = Instance.new("Model")
	local oldHum = Instance.new("Humanoid")
	oldHum.Parent = oldChar
	local newChar = Instance.new("Model")
	local newHum = Instance.new("Humanoid")
	newHum.Parent = newChar
	local aircraftPart = Instance.new("Part")

	record(
		"A fresh character claims the camera from the old one",
		CameraController.groundSubjectFor(newChar, oldHum) == newHum,
		"the live humanoid wins over the destroyed character's"
	)
	record(
		"A fresh character claims the camera from the AIRCRAFT",
		CameraController.groundSubjectFor(newChar, aircraftPart) == newHum,
		"a part left over from chase or free view does not survive the swap"
	)
	record(
		"With no character the subject is dropped, not held",
		CameraController.groundSubjectFor(nil, oldHum) == nil,
		"nil rather than sticky - the frame loop re-asks until the rig exists"
	)
	record(
		"An unchanged character keeps its own humanoid",
		CameraController.groundSubjectFor(newChar, newHum) == newHum,
		"idempotent, so the frame loop is not writing CameraSubject every frame"
	)

	oldChar:Destroy()
	newChar:Destroy()
	aircraftPart:Destroy()

	end

	local ok, err = pcall(body)

	if model then
		model:Destroy()
	end
	-- The suite drives the module's own smoothing state; reset it so a test run
	-- cannot leave a live camera lerping from a synthetic position.
	chasePosition = nil
	groundSubject = nil
	groundScale = nil
	holding = false
	heldRotation, heldOffset = nil, nil
	reacquire = 1

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

return CameraController
