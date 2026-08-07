--!strict
--[[
	FlightController
	----------------
	The frame loop. Every other module computes something; this one decides
	when to run them and in what order.

	It owns very little on purpose. Input shaping belongs to InputController,
	forces belong to FlightModel and GroundHandling, and the engine model
	belongs to Engine. What lives here is the sequencing, the lifecycle
	(sit down, fly, get out, die, despawn) and nothing else.

	ORDER WITHIN A FRAME - the part that is easy to get wrong
	---------------------------------------------------------
	  1. Read the assembly ONCE. Every consumer gets the same kinematics, so
	     the aerodynamics and the landing gear cannot disagree about where the
	     aircraft is or how fast it is going.
	  2. Feed altitude and vertical speed to the input layer, so altitude hold
	     is working from this frame's state rather than last frame's.
	  3. Aerodynamics, then gear - the gear needs the lift to know how much
	     weight is still on the wheels.
	  4. Sum, and write ONCE. FlightModel.applyForces overwrites; calling it
	     twice silently discards the first contribution.

	Runs on Stepped, which fires immediately before Roblox integrates physics.
	That is where forces belong: applying them on RenderStepped or Heartbeat
	means they are always one frame stale.

	WHERE THE AIRCRAFT COMES FROM
	-----------------------------
	Not from here. AircraftService builds it on the server and grants this
	client network ownership, then fires AircraftAssigned. This controller waits
	for that event and adopts whatever it is given - it never builds an
	aircraft outside its own test suite.

	NETWORK OWNERSHIP
	-----------------
	Granted by the server at spawn, before this client is ever told the aircraft
	exists, and verified there - BasePart:IsNetworkOwner() does not exist on the
	client, so a check here would be dead code that never fires.

	The failure mode is worth knowing because it is silent: forces written to an
	assembly this client does not own are discarded by the engine with no error
	and no motion, which from the cockpit looks exactly like broken
	aerodynamics. If the controls do nothing at all, read the server log before
	suspecting the physics.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local FlightSim = ReplicatedStorage:WaitForChild("FlightSim")

local Constants = require(FlightSim.Config.Constants)
local Remotes = require(FlightSim.Net.Remotes)
local Registry = require(FlightSim.Aircraft.Registry)
local Engine = require(FlightSim.Physics.Engine)
local FlightModel = require(FlightSim.Physics.FlightModel)
local GroundHandling = require(FlightSim.Physics.GroundHandling)
local SurfaceAnimation = require(FlightSim.Aircraft.SurfaceAnimation)

-- Test-only. runTests() builds its own aircraft rather than asking the server
-- for one, so that the sequencing can be verified without a live server.
local AircraftBuilder = require(FlightSim.Aircraft.AircraftBuilder)
local Cessna172 = require(FlightSim.Aircraft.Definitions.Cessna172)
local Units = require(FlightSim.Shared.Units)
local CharacterTuning = require(FlightSim.Shared.CharacterTuning)

--[[
	InputController lives under Controls/, not Controllers/. It is not a
	controller in the bootstrap's sense - it has no Init() and is not started
	by Init.client.luau - it is a library this controller drives. The folder
	rename is a separate task; do not "fix" this path.
]]
local InputController = require(script.Parent.Parent:WaitForChild("Controls"):WaitForChild("InputController"))

local FlightController = {}

local min = math.min
local atan2 = math.atan2
local TAU = math.pi * 2

-- =========================================================================
-- CONFIGURATION
-- =========================================================================

--[[
	How long to wait for a replicated aircraft to become complete.

	The server fires AircraftAssigned with a Model reference, but a reference is
	not a guarantee that every descendant has arrived on this machine yet.
	Constructing the flight model against a half-replicated aircraft would cache
	a centre of mass computed from whichever parts happened to exist - every
	moment arm silently wrong, and nothing to show for it but an aeroplane that
	flies oddly. So adoption waits for the pieces it needs.
]]
local RIG_WAIT_TIMEOUT = 10

--[[
	Shortest gap between two accepted reset requests.

	InputBegan already fires once per physical press, so holding Backspace cannot
	repeat - that is the edge trigger, and it is structural rather than something
	this module has to remember. The cooldown is for MASHING: each reset is an
	InvokeServer round trip that despawns an aircraft and builds another, and a
	pilot jabbing the key while nothing appears to happen would queue a handful of
	spawns and get the last one, several aeroplanes later.
]]
local RESET_COOLDOWN = 1.0

-- =========================================================================
-- STATE
-- =========================================================================

local player = Players.LocalPlayer

local rig: any = nil
local seat: VehicleSeat? = nil

-- Two lifetimes, and conflating them was a real bug waiting to happen. The
-- lifetime connections live as long as the client does; the rig connections
-- belong to one aircraft and are dropped when it is.
local connections: { RBXScriptConnection } = {}
local rigConnections: { RBXScriptConnection } = {}

local stepConnection: RBXScriptConnection? = nil
local initialised = false

-- os.clock() of the last accepted reset. Starts far enough in the past that the
-- first press is never inside the cooldown.
local lastResetAt = -math.huge

--[[
	The last pointer position that was actually on the game view, in usable-area
	pixels. This is the yoke's memory for as long as the cursor is off the view -
	see FlightController.resolvePointer. Cleared whenever the loop starts, so a
	fresh aircraft never inherits a deflection from the last one.
]]
local lastPointer: Vector2? = nil

-- False while the Roblox window does not have focus. A pilot who alt-tabs is
-- not flying, and must not be left holding whatever the yoke was doing.
local windowFocused = true

--[[
	Reused every frame rather than reallocated. One small table per frame per
	aircraft is real collector pressure at 240 fps for no benefit - the input
	layer reads these numbers immediately and never retains them.
]]
local flightState = {
	altitude = 0,
	verticalSpeed = 0,
	-- The lateral three, for the stability augmentation mode. See
	-- InputController.stabilityRoll.
	bankAngle = 0,
	rollRate = 0,
	heading = 0,
	-- Indicated airspeed, m/s. The altitude loop schedules its gain on this;
	-- see InputController's altHold.refAirspeed.
	airspeed = 0,
}

local function log(message: string, ...)
	if Constants.DEBUG.ENABLED then
		print("[FlightSim:Flight] " .. string.format(message, ...))
	end
end

-- =========================================================================
-- FRAME
-- =========================================================================

--[[
	One integration step.

	Separated from the loop and from all Roblox event plumbing so it can be
	driven directly by runTests() with synthetic input, exactly as
	FlightModel.computeForces and InputController.update can.

	`snapshot` is an InputController input snapshot. Returns the summed force
	and torque actually written, for inspection.
]]
function FlightController.stepFrame(r: any, dt: number, snapshot: any): (Vector3, Vector3)
	dt = min(dt, Constants.SIM.MAX_TIMESTEP)
	if dt <= 0 then
		return Vector3.zero, Vector3.zero
	end

	local fm = r.flightModel
	local gear = r.gear

	-- 1. One reading of the assembly, shared by everything downstream.
	local k = FlightModel.readKinematics(fm)

	flightState.altitude = k.altitude
	flightState.verticalSpeed = k.velocity.Y

	--[[
		The lateral state the stability mode needs, taken from the SAME single
		reading of the assembly as everything else this frame.

		Bank and heading use exactly the constructions FlightModel already
		publishes as telemetry (see §15 and §18), rather than second versions of
		them - the DI a pilot reads and the heading this mode steers by must not
		be two different numbers.

		Roll rate is the angular velocity about the aircraft's OWN roll axis, so
		it is projected onto the nose vector. Using the world X component would
		read a pitching aeroplane as rolling the moment it turned onto an
		east-west heading.
	]]
	local cf = k.cframe
	flightState.bankAngle = -atan2(cf.RightVector.Y, cf.UpVector.Y)
	flightState.heading = atan2(cf.LookVector.X, -cf.LookVector.Z) % TAU
	flightState.rollRate = k.angularVelocity:Dot(cf.LookVector)
	--[[
		One frame old, deliberately. Telemetry is written by computeForces,
		which has not run yet this frame, so this is last frame's IAS. That is
		the right trade: it is the SAME number the pilot's ASI shows, and a
		gain schedule reading an airspeed 16 ms late cannot matter when the
		speed it is tracking takes tens of seconds to change.
	]]
	flightState.airspeed = fm.telemetry.airspeedIndicated

	-- 2. Input.
	local controls, systems = InputController.update(r.input, dt, snapshot, flightState)

	--[[
		2b. Move the control surfaces to match.

		Cosmetic, and placed here deliberately: it is downstream of the input
		layer and upstream of nothing. It reads the controls and writes only
		CFrames on massless parts, so it cannot affect anything below it, and
		sitting before the pause check means the surfaces still follow the
		yoke while paused rather than freezing mid-deflection.

		Trim is passed separately because it is NOT one of the six fields in
		the Controls contract, and widening that contract to make an animation
		convenient is exactly what §6c says not to do. RPM is last frame's,
		for the same reason the gain schedule's airspeed is.
	]]
	SurfaceAnimation.step(r.surfaces, dt, controls, r.input.trim, fm.engine.rpm)

	--[[
		Paused: stop integrating, but zero the constraints first.

		Leaving the last frame's force applied while time continues would
		accelerate the aircraft indefinitely - a "pause" that flies away. This
		is a stopgap, not a real pause: Roblox keeps simulating, so the
		aircraft becomes an unpowered glider and falls. Pause needs a proper
		design decision before it is worth binding.
	]]
	if systems.paused then
		FlightModel.release(fm)
		return Vector3.zero, Vector3.zero
	end

	-- 3. Engine. E produces a COMMANDED state; the engine model owns the rest,
	--    including the starter cranking and refusing to catch without fuel.
	if systems.engineCommanded then
		if not fm.engine.running and not fm.engine.starting then
			Engine.start(fm.engine, r.definition.engine)
		end
	elseif fm.engine.running or fm.engine.starting then
		Engine.stop(fm.engine)
	end

	-- 4. Aerodynamics, then gear. The gear needs the lift to know how much
	--    weight the wheels are still carrying.
	local aeroForce, aeroTorque = FlightModel.computeForces(fm, k, dt, controls, nil)
	local gearForce, gearTorque = GroundHandling.computeForces(gear, k, dt, controls, aeroForce.Y)

	local totalForce = aeroForce + gearForce
	local totalTorque = aeroTorque + gearTorque

	-- 5. One write.
	FlightModel.applyForces(fm, totalForce, totalTorque)

	return totalForce, totalTorque
end

-- =========================================================================
-- FLIGHT RECORDER (DEBUG-ONLY)
-- =========================================================================

--[[
	Captures one row per frame while altitude hold is engaged and prints a
	CSV of the last few seconds when it is disengaged. Built to diagnose the
	reported altitude-hold oscillation with numbers instead of feel: the rows
	show whether the elevator is following the law, whether the nose is
	following the elevator, and which variable is actually oscillating.

	Free when disabled: gated on Constants.DEBUG.ENABLED, and the cap holds at
	most a couple of seconds of memory even in the worst case. The formatting
	and summary are pure and exported so runTests() can pin them down with
	synthetic rows.
]]
local recording: { any } = nil
local recordingTime = 0
local RECORDING_CAP = 900 -- ~15 s at 60 Hz
local lastLiveSummary = 0
local LIVE_SUMMARY_PERIOD = 5

function FlightController.recordFlightStep(rig: any, dt: number)
	if not Constants.DEBUG.ENABLED then
		return
	end

	local engaged = rig.input.systems.altitudeHold
	if engaged then
		if not recording then
			recording = {}
			recordingTime = 0
			lastLiveSummary = 0
			-- The marker the pilot can check for: if this does not appear when R
			-- is pressed, this module is not the one the session loaded.
			print("[FlightRec] recording altitude hold...")
		end
		recordingTime += dt
		local tel = rig.flightModel.telemetry
		table.insert(recording, {
			t = recordingTime,
			pitch = rig.input.controls.pitch,
			att = math.deg(tel.pitchAttitude),
			bank = math.deg(tel.bankAngle),
			hdg = math.deg(tel.heading),
			alt = tel.altitude,
			vs = tel.verticalSpeed,
			ias = Units.msToKnots(tel.airspeedIndicated),
		})
		if #recording > RECORDING_CAP then
			table.remove(recording, 1)
		end
		if recordingTime - lastLiveSummary >= LIVE_SUMMARY_PERIOD then
			lastLiveSummary = recordingTime
			for _, line in FlightController.summarizeRecording(recording) do
				print("[FlightRec] " .. line)
			end
		end
	elseif recording then
		FlightController.dumpRecording(recording)
		recording = nil
		recordingTime = 0
		lastLiveSummary = 0
	end
end

--[[
	The raw numbers the summary is built from, as data so the tests can assert
	on them without string-matching the printed report. period is nil when
	there are fewer than two zero crossings to estimate it from.
]]
function FlightController.recordingMetrics(rows: { any }): any
	if #rows == 0 then
		return { altMin = 0, altMax = 0, vsMin = 0, vsMax = 0, pitchMax = 0, crossings = 0, duration = 0, period = nil }
	end
	local first = rows[1]
	local last = rows[#rows]
	local altMin, altMax = first.alt, first.alt
	local vsMin, vsMax = first.vs, first.vs
	local pitchMax = 0
	local crossings = 0
	--[[
		The period is measured BETWEEN CROSSINGS, not across the whole window.

		Dividing the full duration by the crossing count mixes a clean integer
		(how many half-cycles) with a ragged one (a window that starts and ends
		mid-cycle), and the leftovers at each end bias the answer: a known 2.0 s
		sine sampled over 4 s reported 2.66 s. Between the first and last
		crossing the half-cycle count is exact, so the estimate is too.
	]]
	local firstCrossing: number? = nil
	local lastCrossing: number? = nil
	local prevSign = if first.vs >= 0 then 1 else -1
	for i = 2, #rows do
		local r = rows[i]
		if r.alt < altMin then altMin = r.alt end
		if r.alt > altMax then altMax = r.alt end
		if r.vs < vsMin then vsMin = r.vs end
		if r.vs > vsMax then vsMax = r.vs end
		local p = math.abs(r.pitch)
		if p > pitchMax then pitchMax = p end
		local sign = if r.vs >= 0 then 1 else -1
		if sign ~= prevSign then
			crossings += 1
			if firstCrossing == nil then
				firstCrossing = r.t
			end
			lastCrossing = r.t
			prevSign = sign
		end
	end
	local duration = last.t - first.t
	local spanned = if firstCrossing and lastCrossing then lastCrossing - firstCrossing else 0
	return {
		altMin = altMin,
		altMax = altMax,
		vsMin = vsMin,
		vsMax = vsMax,
		pitchMax = pitchMax,
		crossings = crossings,
		duration = duration,
		-- Two crossings bound one half-cycle, so (crossings - 1) half-cycles
		-- span `spanned` seconds and a full period is twice that.
		period = if crossings >= 2 and spanned > 0 then 2 * spanned / (crossings - 1) else nil,
	}
end

function FlightController.summarizeRecording(rows: { any }): { string }
	local m = FlightController.recordingMetrics(rows)
	return {
		string.format("ALT %10.2f .. %10.2f m (swing %6.2f m)", m.altMin, m.altMax, m.altMax - m.altMin),
		string.format("VS  %+7.2f .. %+7.2f m/s (swing %5.2f m/s)", m.vsMin, m.vsMax, m.vsMax - m.vsMin),
		string.format("PITCH max |%.3f|%s", m.pitchMax, if m.pitchMax >= 0.44 then " - SATURATING" else ""),
		string.format("VS zero crossings %d in %.1f s => period ~%.1f s", m.crossings, m.duration, m.period or 0),
	}
end

function FlightController.formatRecording(rows: { any }): { string }
	local out = { "t,pitch,att_deg,bank_deg,hdg_deg,alt_m,vs_mps,ias_kt" }
	for _, r in rows do
		table.insert(out, string.format(
			"%7.3f,%+.3f,%+7.2f,%+7.2f,%+7.2f,%10.2f,%+7.3f,%7.2f",
			r.t, r.pitch, r.att, r.bank, r.hdg, r.alt, r.vs, r.ias))
	end
	return out
end

function FlightController.dumpRecording(rows: { any })
	print("--- FLIGHT RECORDING (altitude hold, " .. #rows .. " frames) ---")
	for _, line in FlightController.summarizeRecording(rows) do
		print("  " .. line)
	end
	for _, line in FlightController.formatRecording(rows) do
		print(line)
	end
end

-- =========================================================================
-- LIFECYCLE
-- =========================================================================

local function isTyping(): boolean
	-- Without this, typing "was" in chat feeds throttle, rudder and flaps.
	return UserInputService:GetFocusedTextBox() ~= nil
end

--[[
	Neutralise the pilot's body while they are aboard.

	A Roblox character is about 5.7 studs tall and cannot be scaled below
	roughly 5 - the avatar scale limits clamp it - which at 1 stud = 1 m makes
	the pilot a 5.7 METRE giant folded into a 1.5 m cabin. That is not
	cosmetic, it breaks the flight model in two ways:

	  - Mass. A seated character welds into the assembly and moves its centre
	    of mass. FlightModel caches comLocal at spawn and measures every moment
	    arm from it, so the arms would all silently be wrong. Measured: 1122 kg
	    seated against the 1111 kg the aircraft was designed and tested at.
	  - Collision. The character's legs reach well below the cabin floor and
	    through the runway, so the ground shoves the aircraft around via a body
	    that is not supposed to be part of it.

	Making the parts massless and non-collidable fixes both exactly: the
	assembly keeps the mass and balance the physics was built around, and the
	pilot stops fighting the aeroplane.

	AND INVISIBLE, which is the third thing.

	The cockpit camera sits at the pilot's eye, inside a 5.7 m body folded into
	a 1.5 m cabin - so without this the view is filled with the inside of the
	pilot's own head. Hiding the body is the same class of fix as hiding the
	cabin shell in CameraController: the aeroplane is solid boxes and so is the
	avatar.

	ORIGINAL TRANSPARENCY IS RECORDED, NOT ASSUMED TO BE ZERO. Restoring
	everything to 0 would make the HumanoidRootPart visible - it ships at
	Transparency = 1 and is meant to stay that way - leaving a large block
	stuck through the middle of the character when they climb out. So each
	value is captured on the way in and put back exactly.

	DECALS NEED THEIR OWN PASS. A Decal is a child of a part, not a property of
	it, and setting a part to Transparency = 1 does NOT hide the decals on it.
	Miss this and the pilot's face floats in the cockpit with no head behind it.

	This is a LOCAL change and deliberately so: property writes from the client
	do not replicate, so other players still see a pilot sitting in the
	aeroplane. Only the person flying it stops seeing their own body.
]]
local originalTransparency: { [Instance]: number } = {}

local function applyTransparency(item: Instance, neutralised: boolean)
	if neutralised then
		if originalTransparency[item] == nil then
			originalTransparency[item] = (item :: any).Transparency
		end
		(item :: any).Transparency = 1
		return
	end

	--[[
		Restore ONLY what we hid. Nothing recorded means we never touched this
		part, and writing a default over it would be inventing a value.

		This is not hypothetical caution - it was a live bug. The restore path
		runs before the hide path ever does: adopt() calls onOccupantChanged()
		the moment an aircraft is assigned, long before anyone sits down, and
		that takes the "not seated" branch. With a fallback of 0 it set the
		HumanoidRootPart - which ships at Transparency = 1 and is meant to stay
		there - to fully opaque, leaving a large block through the middle of the
		character. The unit test missed it because a synthetic fixture never
		reproduces that ordering; a real boarding does.
	]]
	local original = originalTransparency[item]
	if original ~= nil then
		(item :: any).Transparency = original
	end
end

function FlightController.setCharacterNeutralised(character: Model?, neutralised: boolean)
	if not character then
		return
	end

	for _, item in character:GetDescendants() do
		if item:IsA("BasePart") then
			-- Unchanged from before invisibility was added; the mass and
			-- collision behaviour in the notes above depends on exactly this.
			item.Massless = neutralised
			item.CanCollide = not neutralised
			applyTransparency(item, neutralised)
		elseif item:IsA("Decal") then
			-- Covers Texture too, which inherits from Decal.
			applyTransparency(item, neutralised)
		end
	end

	if not neutralised then
		table.clear(originalTransparency)
	end
end

local setCharacterNeutralised = FlightController.setCharacterNeutralised

--[[
	Human proportions, for the pilot character only.

	The world is 1 stud = 1 m and the aircraft are real scale, but a Roblox
	avatar measures ~5.2 studs sole to crown - about 3x a real human - so it
	towers over a parked Cessna. This scales it to PILOT_HEIGHT_M.

	USE Model:ScaleTo(). THE R15 SCALE NumberValues DO NOT WORK, AND THE WAY
	THEY FAIL IS SILENT. All four of these were measured on the live rig:

	  - Humanoid:ScaleTo() and Humanoid:SetScale() do not exist at all
	    ("ScaleTo is not a valid member of Humanoid"). Model:ScaleTo() does -
	    it is a method of Model, which is what a character is.
	  - Setting BodyHeightScale / BodyWidthScale / BodyDepthScale / HeadScale
	    to 0.4 with AutomaticScalingEnabled = true changes NOTHING. The values
	    read back as the 0.4 we wrote while GetAppliedDescription() still
	    reported HeightScale 0.96 and the rig still measured its full 5.16
	    studs. Setting one to 1.0 and back to 0.4 moved the rig 0.00 studs in
	    both directions - the mechanism is simply inert here.
	  - Humanoid:ApplyDescription() is server-only ("can only be called by the
	    backend server"), so the client cannot go via the description either.
	  - There are NO Motor6D joints on this rig to rewrite by hand. It is a
	    constraint rig - AnimationConstraint, BallSocketConstraint, 55
	    Attachments and 15 WrapTargets of layered clothing. Model:ScaleTo
	    handles all of that, and HipHeight with it, needing none of that
	    surgery.

	⚠️ THE OLD MARKER COULD NOT TELL SUCCESS FROM DOING NOTHING, which is why
	this looked like it worked for a whole session. It printed the scale it
	ASKED for beside HumanoidRootPart.Size.Y, and the "1.92 studs" it reported
	was just this player's own untouched avatar. The marker below prints the
	height MEASURED AFTER THE FACT, so it cannot lie the same way.

	COSMETIC, and it changes nothing physical. The seated pilot is already
	invisible, massless and non-collidable (setCharacterNeutralised above), so
	scaling cannot disturb the aircraft's mass budget; the cockpit eye is
	anchored to the PilotSeat, not the head (CameraController.EYE_OFFSET), so
	the view does not move. Nothing here touches the physics, the world scale,
	or the unit conversions. Boarding was re-measured after the change and
	still moves the aircraft 0.000 m (section 6e).
]]
local PILOT_HEIGHT_M = 1.55 -- studs too; 1 stud = 1 m (section 2)
local HEIGHT_TOLERANCE = 0.02
-- A rig caught mid-assembly measures nonsense. Anything outside this band is
-- not a body yet, so it is re-measured rather than scaled from.
local MIN_PLAUSIBLE_HEIGHT = 0.5
local MAX_PLAUSIBLE_HEIGHT = 12.0
-- Two readings this close together mean the pose has stopped moving. At rest
-- the measure repeats to four decimals, so this is a loose bound on "still".
local POSE_EPSILON = 0.005

--[[
	Sole-to-crown height of a character, in studs.

	The HumanoidRootPart is excluded because it is an invisible collision box
	that does not track the visible rig - reading it is precisely the mistake
	the old marker made. Accessories are excluded because hair and hats are
	not height.
]]
function FlightController.rigHeightStuds(character: Model?): number?
	if not character then
		return nil
	end
	local top, bottom = -math.huge, math.huge
	for _, descendant in character:GetDescendants() do
		if
			descendant:IsA("BasePart")
			and descendant.Name ~= "HumanoidRootPart"
			and not descendant:FindFirstAncestorOfClass("Accessory")
		then
			top = math.max(top, descendant.Position.Y + descendant.Size.Y / 2)
			bottom = math.min(bottom, descendant.Position.Y - descendant.Size.Y / 2)
		end
	end
	if top <= bottom then
		return nil
	end
	return top - bottom
end

--[[
	The pilot's target height, in studs (1 stud = 1 m).

	scaleForHumanProportions converges on this, so it is the number the ground
	camera uses to frame a scaled pilot. A pilot who was left full-size for
	any reason measures something else, and rigHeightStuds reports that - which
	is what the camera prefers, when it exists.
]]
function FlightController.getPilotHeight(): number
	return PILOT_HEIGHT_M
end

--[[
	The Model scale that puts a rig of `measuredHeight` at PILOT_HEIGHT_M.

	Model:ScaleTo takes an ABSOLUTE scale relative to the rig as it was built,
	not a multiplier, so the scale the rig is already at has to be folded back
	in. Measuring rather than hard-coding a factor is what makes this land on
	PILOT_HEIGHT_M for any player's avatar rather than only for a default one.

	Idempotent by construction: hand it a rig already at the target and it
	returns the scale that rig is already at, so re-applying is a no-op.
]]
function FlightController.pilotScaleFor(currentScale: number?, measuredHeight: number?): number?
	if not currentScale or not measuredHeight then
		return nil
	end
	if currentScale <= 0 or measuredHeight <= 0 then
		return nil
	end
	return currentScale * PILOT_HEIGHT_M / measuredHeight
end

--[[
	The pilot's name tag: switched off entirely, by the pilot's decision.

	⚠️ ROBLOX'S BUILT-IN NAME TAG DOES NOT SCALE WITH `Model:ScaleTo`. It is
	positioned above the character in STOCK studs, so shrinking the rig to
	PILOT_HEIGHT_M leaves the tag hanging far above the head - reported as
	"floats extremely high". Nothing exposes its offset, so it cannot simply be moved
	down; a replacement billboard sized to the scaled pilot was built and then
	dropped, because the pilot asked for no name in the world at all.

	`HumanoidDisplayDistanceType.None` hides the health bar with it, which is
	wanted: this is a flight simulator and neither belongs over a pilot's head.

	Applied on the client as well as in PlayerService so a character the engine
	loaded - the fallback path when an R6 build fails (section 34) - is covered
	too.
]]
function FlightController.hideNameTag(character: Model?)
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
end

--[[
	Where the character camera's PIVOT sits - the point the on-foot orbit swings
	around - which is the CENTRE OF THE HEAD.

	⚠️ NOT THE NOSE, AND NOT AHEAD OF THE HEAD. Aiming the pivot at the eyes - a
	point on the front of the head - was tried and rejected: walking around with
	the pivot ahead of the head centre makes the orbit swing about a point that
	is not the body, which the pilot reported as "really funky". Moving the pivot
	INSIDE the head, at its centre, makes orbiting seamless: the camera rotates
	about the head's own centre rather than about a point on the skin. (The
	SEATED cockpit view is separate - it is scripted and anchored to the
	PilotSeat via CameraController.EYE_OFFSET - so this only governs the
	character camera on foot.)

	Both the height and the depth come FROM THE HEAD rather than being typed in,
	so they stay right for an R6 or an R15 rig and at any scale.

	⚠️ SCALED, AND APPLIED ONLY ONCE THE SCALE HAS SETTLED. CameraOffset is in
	studs and is NOT rescaled by `Model:ScaleTo`, so it is read off the head as
	it currently measures - and the head is only its final size once the target
	scale has converged (section 30). Sized at spawn it would be built for a
	stock rig and throw the camera a head-height off.
]]
--[[
	⚠️ ROBLOX FOCUSES THE CHARACTER CAMERA A HARD-CODED 1.500 STUDS ABOVE THE
	HumanoidRootPart, AND THAT CONSTANT DOES NOT SCALE WITH `Model:ScaleTo`.

	Measured, by writing offsets and reading back camera.Focus in the root's own
	frame - the focus is exactly (0, 1.500, 0) + CameraOffset, one for one, on
	all three axes and at any scale:

	    CameraOffset (0, 0, 0)      -> focus (0.000, 1.500, 0.000)
	    CameraOffset (0, 0, -0.5)   -> focus (0.000, 1.500, -0.500)
	    CameraOffset (0.5, 0, 0)    -> focus (0.500, 1.500, 0.000)

	1.500 is where a STOCK 5-stud rig's head centre sits. Our pilot is scaled to
	about 0.30 (PILOT_HEIGHT_M over a 5.156-stud rig), so their head centre sits
	a metre or more below that stock focus point - and the camera was therefore
	orbiting and zooming to a point well above their head. Measured at the old
	0.35 scale: head centre 0.514 above the root, focus error 0.905 m. This is
	the same trap as the name tag: a stock-scale constant the engine applies
	over the top of a scaled rig.
]]
local STOCK_FOCUS_ABOVE_ROOT = 1.5

--[[
	The CameraOffset that puts the character camera's pivot at the centre of the
	pilot's head - the point inside the skull that orbiting rotates around.

	Pure arithmetic over measured geometry, so it can be asserted without a
	character, and so it stays right at any scale rather than being a constant
	that happens to suit one:

	    focus = root + (0, STOCK_FOCUS_ABOVE_ROOT, 0) + offset      (measured)
	    want  = root + (0, headAboveRoot, 0)                        (head centre)

	`headAboveRoot` is read off the live rig, which is what makes the correction
	track the pilot as they are scaled to PILOT_HEIGHT_M. X and Z stay zero
	because a rig's head is centred over its root part, so its centre carries no
	horizontal offset from the root.
]]
function FlightController.headPivotOffset(headAboveRoot: number?): Vector3
	if not headAboveRoot then
		return Vector3.zero
	end
	return Vector3.new(0, headAboveRoot - STOCK_FOCUS_ABOVE_ROOT, 0)
end

--[[
	Put the character camera's pivot at the centre of the pilot's head.

	⚠️ APPLIED ONLY ONCE THE SCALE HAS SETTLED. The correction is the difference
	between a stock constant and the live rig's geometry, so it is only right
	when the rig has finished converging on PILOT_HEIGHT_M (section 30). Applied
	at spawn it would be computed for a full-size rig and be a metre out.
]]
function FlightController.fitCameraPivot(character: Model?)
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local head = character:FindFirstChild("Head")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not head or not head:IsA("BasePart") or not root or not root:IsA("BasePart") then
		return
	end
	local headAboveRoot = (root.CFrame:Inverse() * head.CFrame).Position.Y
	humanoid.CameraOffset = FlightController.headPivotOffset(headAboveRoot)
end

function FlightController.scaleForHumanProportions(character: Model?)
	if not character then
		return
	end

	task.spawn(function()
		local humanoid = character:WaitForChild("Humanoid", 10)
		if not humanoid or not humanoid:IsA("Humanoid") then
			return
		end
		-- The measure is meaningless until the part it measures to exists.
		if not character:WaitForChild("Head", 10) then
			return
		end
		if typeof(character.ScaleTo) ~= "function" then
			print("[Avatar] Model:ScaleTo unavailable - pilot left at default size")
			return
		end

		--[[
			⚠️ DO NOT SET humanoid.AutomaticScalingEnabled = false HERE.

			It was set false once as a precaution against the engine re-applying
			the avatar description over the top. It does not do that - ScaleTo
			survives with automatic scaling either way, measured - and turning
			it off BREAKS THE CAMERA. Roblox's default camera picks its focus
			height from R15_HEAD_OFFSET when automatic scaling is on, which
			scales with the root part, and from a fixed 2-stud constant when it
			is off. On a 0.33x pilot that constant puts the camera's centre
			1.30 studs above the head - most of a body length of empty air, and
			reported as "the center is a few studs above our head". Left on, the
			focus sits 0.12 studs above the head, which is normal framing.
		]]

		--[[
			WAIT FOR THE POSE TO STOP MOVING BEFORE MEASURING IT.

			The measure reads the POSED rig, so it is the standing height only
			once the character is actually standing still. Waiting on the
			physics is not enough and was tried first: a character that spawns
			on the pad is already Running with no vertical velocity within a
			frame, while the Animate script is still easing the limbs into the
			idle pose for about a second afterwards. Measured mid-pose it read
			5.06 			and 4.22 studs against a settled 5.156, which scaled the pilot
			to 1.69 m and 1.41 m instead of PILOT_HEIGHT_M.

			So the wait is on the MEASUREMENT settling rather than on any
			state flag: two consecutive readings that agree mean the limbs have
			stopped. At rest the reading repeats to four decimal places, and
			the settled value is repeatable across sessions (5.155, 5.156,
			5.158), which is what makes this safe to key on.
		]]
		local function stableHeight(): number?
			local previous: number? = nil
			for _ = 1, 60 do
				local height = FlightController.rigHeightStuds(character)
				if height and height > MIN_PLAUSIBLE_HEIGHT and height < MAX_PLAUSIBLE_HEIGHT then
					if previous and math.abs(height - previous) < POSE_EPSILON then
						return height
					end
					previous = height
				end
				task.wait(0.1)
			end
			return FlightController.rigHeightStuds(character)
		end

		--[[
			Converge rather than compute once. pilotScaleFor is idempotent, so
			a pass costs nothing when the previous one was right, and corrects
			it when the rig moved while it was being measured - which it does,
			because scaling changes HipHeight and drops the character onto the
			ground again.
		]]
		for _ = 1, 4 do
			local height = stableHeight()
			if not height then
				break
			end
			if math.abs(height - PILOT_HEIGHT_M) <= HEIGHT_TOLERANCE then
				break
			end
			local scale = FlightController.pilotScaleFor(character:GetScale(), height)
			if not scale then
				break
			end
			pcall(character.ScaleTo, character, scale)
			task.wait(0.2)
		end

		--[[
			⚠️ RE-APPLIED AFTER SCALING, NOT AT SPAWN. `Model:ScaleTo` scales
			WalkSpeed and JumpHeight along with the rig, so the tuned 20.00 m/s
			and 1.00 m that PlayerService set arrive here and are quietly
			rescaled to 7.00 and 0.35 by the shrink to PILOT_HEIGHT_M (measured
			at the old 0.35x scale; the factor scales with the rig). Scaling a rig
			does not make its owner a smaller person - section 30's rule is that
			a PILOT_HEIGHT_M human walks at the configured speed whatever the rig
			measures - so the metre-scale values are restored once the scale has
			settled. This is what the pilot reported as a reset leaving them
			unable to jump properly.
		]]
		CharacterTuning.apply(character:FindFirstChildOfClass("Humanoid"))
		FlightController.hideNameTag(character)

		FlightController.fitCameraPivot(character)

		local measured = FlightController.rigHeightStuds(character)
		if measured and math.abs(measured - PILOT_HEIGHT_M) <= HEIGHT_TOLERANCE then
			print(string.format(
				"[Avatar] pilot is %.2f m (model scale %.3fx)",
				measured,
				character:GetScale()
			))
		else
			print(string.format(
				"[Avatar] FAILED to scale pilot - measures %s, wanted %.2f m",
				measured and string.format("%.2f m", measured) or "nothing",
				PILOT_HEIGHT_M
			))
		end
	end)
end

--[[
	Where the yoke is, in screen pixels, and the screen it is measured against.

	THE GUI INSET IS THE TRAP HERE, and the first attempt got it backwards.

	GetMouseLocation() reports in the FULL viewport space, including the strip
	behind Roblox's top bar - so its Y can never be less than the inset, and its
	maximum is the whole viewport height. Measured live on a 1572 x 841 viewport
	with a 58 px inset: the cursor's reachable range is exactly 58 .. 841.

	The previous version reduced the VIEWPORT by the inset and left the POINTER
	alone, on the belief that GetMouseLocation() already excluded it. That put
	neutral at y = 391 when the middle of the visible screen is y = 449 - the
	whole inset of permanent nose-up bias - and, worse, made full nose-down
	UNREACHABLE: the top of the screen produced -0.766 while the bottom produced
	+1.000 and saturated 58 px early. That is what the pilot reported as "very
	easy to pitch up, extremely difficult to pitch down".

	It was verified at the time by checking that a cursor at y 392 gave pitch
	0.000 against a half-height of 391.5 - which only proved the arithmetic was
	self-consistent, not that the cursor was physically halfway down the screen.
	The check that matters is the reachable RANGE, not one point inside it.

	Both are therefore reduced to the same space by subtracting the inset from
	BOTH: the usable area below the top bar, with the pointer expressed in it.
]]
function FlightController.pointerSpace(mouse: Vector2, viewport: Vector2, inset: Vector2): (Vector2, Vector2)
	return mouse - inset, viewport - inset
end

--[[
	What to do when the cursor is not on the game view at all.

	Roblox reports (-1, -1) when it has no mouse position for us - the cursor is
	over another window, or over Studio's own panels in a Play session. Read as a
	position, that is the top-left corner: hard nose-down AND hard left roll,
	arriving in one frame with no warning. A pilot holding full back stick
	through a loop sits on the bottom edge of the screen by definition, so it is
	exactly the manoeuvre most likely to push the cursor off the view and get the
	controls slammed to the opposite corner.

	So an off-view pointer is not a position, it is missing data. The yoke HOLDS
	where the pilot last put it, which is what a real yoke against its stop does
	and what makes the cursor slipping off the bottom edge a non-event. Losing
	window focus is different and is handled separately - see startLoop().

	With no memory to hold - the cursor was already off the view when the loop
	started - the answer is the CENTRE of the usable area, which is neutral.
	Vector2.zero would be the top-left corner, which is the very failure this
	function exists to prevent.

	Pure, and exported, so the boundary can be tested without a mouse.
]]
function FlightController.resolvePointer(mouse: Vector2, usable: Vector2, lastValid: Vector2?): (Vector2, boolean)
	local onView = mouse.X >= 0 and mouse.Y >= 0 and mouse.X <= usable.X and mouse.Y <= usable.Y
	if onView then
		return mouse, true
	end
	return lastValid or (usable * 0.5), false
end

local function readPointer(): (Vector2, Vector2)
	local camera = workspace.CurrentCamera
	if not camera then
		return Vector2.zero, Vector2.zero
	end

	local guiInset = GuiService:GetGuiInset()
	local pointer, usable =
		FlightController.pointerSpace(
			UserInputService:GetMouseLocation(),
			camera.ViewportSize,
			Vector2.new(guiInset.X, guiInset.Y)
		)

	local resolved, onView = FlightController.resolvePointer(pointer, usable, lastPointer)
	if onView then
		lastPointer = resolved
	end

	return resolved, usable
end

local function stopLoop()
	if stepConnection then
		stepConnection:Disconnect()
		stepConnection = nil
	end

	if rig then
		FlightModel.release(rig.flightModel)
	end

	-- Belt and braces. The cursor is already free while flying, but anything
	-- that locks it later must not strand the pilot with a trapped pointer.
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

local function startLoop()
	if stepConnection or not rig then
		return
	end

	--[[
		The cursor stays FREE, and visible, for the whole flight.

		This is the PTFS scheme: the pointer's position on screen is the yoke,
		so the pilot can see exactly where their controls are and put them back
		by moving the mouse to the middle. Locking it to centre - which the
		previous relative scheme required, because GetMouseDelta reports nothing
		unless the cursor is locked - would make an absolute position
		meaningless, since a locked cursor never leaves the centre.
	]]
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true

	-- Forget the last yoke position. Without this a new aircraft would inherit
	-- the deflection the last one was destroyed holding. nil means "no memory
	-- yet", which resolvePointer answers with neutral rather than a corner.
	lastPointer = nil

	stepConnection = RunService.Stepped:Connect(function(_, deltaTime)
		if not rig or not rig.model.Parent then
			stopLoop()
			return
		end

		--[[
			Typing releases the yoke rather than freezing it.

			With a free cursor this is not the nicety it was: reaching for the
			chat box moves the pointer to the bottom-left of the screen, which
			under absolute control is hard nose-up and full left roll. Sending a
			neutral snapshot means chatting can never roll the aircraft
			inverted. Trim is untouched, so a trimmed aircraft keeps its
			attitude exactly as it would with the pilot's hands off the yoke.
		]]
		local snapshot
		if isTyping() or not windowFocused then
			--[[
				Both release the yoke rather than freezing it, and both keep
				trim, so a trimmed aircraft simply flies on hands-off.

				Focus loss is deliberately NOT treated the same way as the cursor
				leaving the game view. Off the view, the pilot is still flying
				and the yoke holds (resolvePointer). Alt-tabbed, they are not
				flying at all, and holding full back stick because that is where
				the cursor happened to be would keep looping the aeroplane while
				they read something else.
			]]
			snapshot = InputController.neutralSnapshot()
		else
			local pointer, viewport = readPointer()
			snapshot = InputController.poll(rig.input, pointer, viewport)
		end

		FlightController.stepFrame(rig, deltaTime, snapshot)
		FlightController.recordFlightStep(rig, deltaTime)
	end)

	log("Flight loop started")
end

local function onOccupantChanged()
	if not seat then
		return
	end

	local occupant = seat.Occupant
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if occupant and occupant == humanoid then
		setCharacterNeutralised(character, true)
		startLoop()
	else
		-- Only report a stop if there was something to stop. This runs once on
		-- adoption, when nobody is aboard yet, and "Flight loop stopped" as the
		-- first line after spawning an aircraft reads like a fault.
		local wasRunning = stepConnection ~= nil
		setCharacterNeutralised(player.Character, false)
		stopLoop()
		if wasRunning then
			log("Flight loop stopped")
		end
	end
end

-- Drop the current aircraft. Lifetime connections survive, so a replacement
-- can be adopted afterwards.
local function releaseRig()
	stopLoop()
	for _, connection in rigConnections do
		connection:Disconnect()
	end
	table.clear(rigConnections)
	rig = nil
	seat = nil
	-- An engagement that outlived the aircraft must not dump into the next one.
	recording = nil
	recordingTime = 0
	lastLiveSummary = 0
end

local function teardown()
	releaseRig()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

-- =========================================================================
-- ADOPTION
-- =========================================================================

--[[
	Block until the replicated model is complete enough to build a flight model
	against, or give up. Returns the definition, or nil and a reason.

	Waiting on these four specifically: the root (everything is measured from
	it), both constraints (there is nothing to write forces to without them),
	and the seat (there is no way aboard without it). Their arrival does not
	strictly prove every wing panel has replicated, but the model is parented
	last by the builder, so in practice the descendants come as one.
]]
local function waitForRig(model: Model): (any?, string?)
	local deadline = os.clock() + RIG_WAIT_TIMEOUT

	while os.clock() < deadline do
		local root = model.PrimaryPart
		if
			root
			and root:FindFirstChild("AeroForce")
			and root:FindFirstChild("AeroTorque")
			and model:FindFirstChild("PilotSeat")
		then
			break
		end
		if not model.Parent then
			return nil, "the aircraft was destroyed before it finished replicating"
		end
		task.wait()
	end

	if not model.PrimaryPart then
		return nil, string.format("aircraft did not finish replicating within %d s", RIG_WAIT_TIMEOUT)
	end

	--[[
		Which aeroplane is this? The server stamps the id on the model and both
		sides resolve it through the same Registry, so the client never assumes
		it was given the aircraft it asked for - a flight plan or a spawn point
		may well hand it something else.
	]]
	local id = model:GetAttribute("AircraftId")
	local definition = Registry.get(if type(id) == "string" then id else nil)
	if not definition then
		return nil, string.format("unknown AircraftId '%s' on the assigned model", tostring(id))
	end

	return definition, nil
end

--[[
	Take ownership of an aircraft the server has assigned to this client.

	Adopting a second one replaces the first, because the server enforces one
	aircraft per player: a new assignment means the old aircraft is already
	gone or about to be.
]]
local function adopt(model: Model)
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		warn("[FlightSim:Flight] AircraftAssigned fired without a model - nothing to fly.")
		return
	end

	if rig and rig.model == model then
		return
	end

	releaseRig()

	local definition, reason = waitForRig(model)
	if not definition then
		warn("[FlightSim:Flight] Could not adopt the assigned aircraft: " .. tostring(reason))
		return
	end

	local pilotSeat = model:FindFirstChild("PilotSeat")
	if not (pilotSeat and pilotSeat:IsA("VehicleSeat")) then
		warn("[FlightSim:Flight] Assigned aircraft has no VehicleSeat named PilotSeat.")
		return
	end

	-- Published only once fully assembled; a half-built rig reaching the frame
	-- loop would be worse than none.
	rig = {
		model = model,
		definition = definition,
		flightModel = FlightModel.new(model, definition),
		gear = GroundHandling.new(model, definition),
		input = InputController.new(definition),
		-- Cosmetic. Binds the hinged control surfaces so they follow the
		-- controls; an aircraft whose definition has none binds nothing.
		surfaces = SurfaceAnimation.new(model, definition),
	}
	seat = pilotSeat

	table.insert(rigConnections, pilotSeat:GetPropertyChangedSignal("Occupant"):Connect(onOccupantChanged))

	-- The aircraft going away must take the loop with it, or Stepped keeps
	-- firing against a destroyed assembly every frame for the rest of the
	-- session.
	table.insert(rigConnections, model.Destroying:Connect(releaseRig))

	log("Adopted %s (%s)", definition.name, model.Name)

	-- Boarding is server-side now: AircraftService puts the ProximityPrompt on
	-- the seat, so every player can see and use it. If the pilot was already
	-- sitting when this arrived - a re-adoption - pick the loop up immediately.
	onOccupantChanged()
end

-- =========================================================================
-- RESET
-- =========================================================================

--[[
	Backspace asks the server for a fresh aircraft.

	The server treats a spawn request from a player who already has an aircraft as
	"replace it" (see AircraftService), so a request IS the reset - there is no
	separate remote and no new server code. Before this, the only route back into
	the air after putting an aeroplane on its back was to die or respawn the
	character from the Roblox menu.

	THE PILOT DOES NOT HAVE TO BE SEATED, and that is the whole point.

	The obvious place for this was InputController.update(), alongside every other
	latched action. It would have been wrong. update() only runs inside the frame
	loop, the frame loop only runs while the pilot is sitting in a working
	aircraft, and the situations worth resetting from are precisely the ones where
	that is not true: an aeroplane on its back that will not let you back into the
	seat, a wreck you climbed out of, or no aircraft at all because the last
	request failed. Requiring a flyable aeroplane in order to recover from an
	unflyable one is circular. So the key is bound in InputController -
	rebindable, and covered by its collision test - but consumed here, on a
	connection that lives as long as the client does.

	It is still edge-triggered like every other latch, and structurally so:
	InputBegan fires once per physical press, so holding Backspace cannot respawn
	repeatedly. RESET_COOLDOWN covers mashing, which InputBegan does not.
]]

--[[
	Which key currently resets.

	The live aircraft's own binding table when there is one, so rebind() is
	honoured; the defaults otherwise - because reset has to work when there is no
	aircraft, and therefore no per-player bindings, to read.
]]
local function resetKey(): Enum.KeyCode
	if rig then
		return rig.input.bindings.ResetAircraft
	end
	return InputController.DEFAULT_BINDINGS.ResetAircraft
end

--[[
	Pure, and exported so runTests() can drive it without a keyboard.

	`blocked` is true when the press belongs to something else - Roblox's own UI
	consumed it, or a text box has focus. That matters more for this key than any
	other: Backspace is what a pilot presses to correct a typo in chat, and
	deleting a character should never also delete their aeroplane.
]]
function FlightController.shouldReset(
	keyCode: Enum.KeyCode,
	blocked: boolean,
	boundKey: Enum.KeyCode,
	now: number,
	lastAt: number
): boolean
	if blocked then
		return false
	end
	if keyCode ~= boundKey then
		return false
	end
	return (now - lastAt) >= RESET_COOLDOWN
end

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end

	local now = os.clock()
	if not FlightController.shouldReset(input.KeyCode, gameProcessed or isTyping(), resetKey(), now, lastResetAt) then
		return
	end

	lastResetAt = now
	log("Reset requested")

	-- On its own thread: InvokeServer yields, and yielding inside an input
	-- handler stalls every other listener on that signal.
	task.spawn(FlightController.requestAircraft)
end

-- =========================================================================
-- INIT
-- =========================================================================

--[[
	Called once by Init.client.luau.

	Ordering: the AircraftAssigned handler is connected BEFORE the spawn is
	requested. The server fires that event during the invocation, so connecting
	afterwards is a race this would sometimes lose - and losing it means sitting
	on the apron with no aeroplane and no error.

	The request itself runs on its own thread. InvokeServer yields, and the
	bootstrap starts controllers in order on one thread, so blocking here would
	hold up every controller after this one for a network round trip.
]]
function FlightController.Init()
	if initialised then
		return
	end
	initialised = true

	table.insert(connections, Remotes.Get("AircraftAssigned").OnClientEvent:Connect(adopt))

	--[[
		Dying while seated does not always fire Occupant changed before the
		character is gone, so release explicitly. Without this the constraints
		keep their last force and the empty aircraft flies itself away.
	]]
	table.insert(connections, player.CharacterRemoving:Connect(stopLoop))

	--[[
		Backspace resets the aircraft, from wherever the pilot is standing.

		A lifetime connection rather than a rig one, deliberately: the key must
		still work when there is no rig - see the note above resetKey().
	]]
	table.insert(connections, UserInputService.InputBegan:Connect(onInputBegan))

	--[[
		Window focus, which the yoke needs because it is absolute.

		A relative stick simply stops receiving deltas when the window loses
		focus and stays where it was. An absolute one keeps reading a cursor
		position that is now being moved for some entirely different purpose, so
		the yoke must be released explicitly. Lifetime connections: focus can be
		lost while standing on the apron and regained while seated.

		It starts true because there is no getter for the current focus state -
		UserInputService exposes the two events and nothing to seed from. Getting
		that wrong in the safe direction would be a dead yoke on startup, so the
		initial value is optimistic and the first WindowFocusReleased corrects it.
	]]
	table.insert(connections, UserInputService.WindowFocused:Connect(function()
		windowFocused = true
	end))
	table.insert(connections, UserInputService.WindowFocusReleased:Connect(function()
		windowFocused = false
	end))

	--[[
		Dying gets you a fresh aircraft.

		The server treats a spawn request from a player who already has one as
		"replace it", which is what Backspace above uses too. Death is the other
		route in, and it stays: an aeroplane can be lost in ways that also kill
		the pilot.

		Death rather than CharacterAdded, deliberately. The initial character
		may arrive either side of this controller starting, so requesting on
		CharacterAdded would sometimes fire a second spawn moments after the
		first and replace an aircraft the pilot had already boarded. Died only
		ever means what it says.
	]]
	local diedConnection: RBXScriptConnection? = nil

	local function watchCharacter(character: Model)
		if diedConnection then
			diedConnection:Disconnect()
		end
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			-- A fresh character after respawn starts at full size; scale every one.
			FlightController.scaleForHumanProportions(character)
			diedConnection = humanoid.Died:Connect(function()
				FlightController.requestAircraft()
			end)
		end
	end

	table.insert(connections, player.CharacterAdded:Connect(watchCharacter))
	if player.Character then
		task.spawn(watchCharacter, player.Character)
	end

	task.spawn(FlightController.requestAircraft)
end

--[[
	Ask the server for an aircraft. The reply is only ever a yes or a reason -
	the aircraft itself arrives on AircraftAssigned, so there is exactly one
	path by which this client ever adopts one.
]]
function FlightController.requestAircraft(aircraftId: string?)
	local ok, accepted, message = pcall(function()
		return Remotes.Get("RequestSpawnAircraft"):InvokeServer(aircraftId or Registry.DEFAULT_ID)
	end)

	if not ok then
		warn("[FlightSim:Flight] Spawn request failed: " .. tostring(accepted))
		return
	end

	if not accepted then
		warn("[FlightSim:Flight] Server refused to spawn an aircraft: " .. tostring(message))
	end
end

-- =========================================================================
-- READ-ONLY ACCESSORS
-- =========================================================================

--[[
	What other controllers are allowed to know about the flight.

	Three narrow readers rather than exposing `rig`, so nothing outside this
	module can reach the flight model, the gear or the constraints and start
	writing to them - the ownership rules in the handoff depend on this module
	being the only writer.

	They deliberately return nil rather than a stale value once the aircraft has
	gone. CameraController calls these every frame instead of caching an
	aircraft, which is exactly what stops it holding a destroyed model.
]]
function FlightController.getAircraft(): Model?
	if rig and rig.model and rig.model.Parent then
		return rig.model
	end
	return nil
end

-- The InputController systems struct: viewIndex, cameraHold, gearDown and the
-- rest. Read-only by convention; writing to it would fight the input layer.
function FlightController.getSystems(): any?
	return if rig then rig.input.systems else nil
end

-- True only while the pilot is seated and the frame loop is actually running.
function FlightController.isFlying(): boolean
	return stepConnection ~= nil
end

--[[
	The live telemetry block, rewritten by FlightModel every physics frame.

	Read-only, and returned by reference on purpose: the debug HUD samples it
	every frame to catch one-frame spikes, and copying twenty fields per frame
	to hand out a snapshot would be pure waste. Nothing outside FlightModel may
	write to it.
]]
function FlightController.getTelemetry(): any?
	return if rig then rig.flightModel.telemetry else nil
end

function FlightController.Shutdown()
	teardown()
	initialised = false
end

-- =========================================================================
-- VERIFICATION
-- =========================================================================

--[[
	Run from the Studio command bar:
		require(game.StarterPlayer.StarterPlayerScripts.FlightSim.Controllers.FlightController).runTests()

	Exercises stepFrame() against a real assembly with synthetic input, which
	covers the sequencing this module exists to get right. It does not test the
	Roblox event plumbing - sitting down, dying - because that needs a player.

	The rig is built 5 km from the origin, on its own pad, because that is where
	the aircraft ISN'T. AircraftService parks live aircraft on the origin, and
	these test parts are created on the client, inside the same workspace, with
	collision on. A test rig materialising inside the pilot's aeroplane would
	shove it - and since the pilot's client owns that assembly, the shove would
	replicate and be entirely real. Distance is the cheap fix.
]]
local TEST_ORIGIN = Vector3.new(5000, 0, 5000)
function FlightController.runTests(): (boolean, { any })
	local results = {}
	local allPassed = true

	local function record(label: string, passed: boolean, detail: string)
		if not passed then
			allPassed = false
		end
		table.insert(results, { label = label, passed = passed, detail = detail })
		print(string.format("  [%s] %-46s %s", passed and "PASS" or "FAIL", label, detail))
	end

	print("=== FlightController: verification ===")

	local pad = Instance.new("Part")
	pad.Name = "__FlightControllerTestPad"
	pad.Size = Vector3.new(400, 4, 400)
	pad.Position = TEST_ORIGIN + Vector3.new(0, -2, 0)
	pad.Anchored = true
	pad.Parent = workspace

	--[[
		How high to place the ROOT so the tyres rest on the pad.

		⚠️ DERIVED, NOT TYPED, BECAUSE §45 MOVED THE WHEELS. This was `1.30`,
		which was the right answer while the wheels sat 0.95 below the datum
		with a 0.2 radius. §45 scales the gear to 1.778 and 0.374, so 1.30 left
		the aeroplane hanging above the pad and the gear check measured an
		aircraft that was airborne - reported as "0 wheels down".

		GroundHandling.runTests() derives the same number the same way, for the
		same reason. Both follow the definition, so both are right at any scale.
	]]
	local rootSpec
	for _, p in Cessna172.model.parts do
		if p.name == Cessna172.model.rootPart then
			rootSpec = p
		end
	end
	local mainWheel = Cessna172.gear.wheels[2]
	local groundY = (rootSpec :: any).position.Y - (mainWheel.offset.Y - mainWheel.radius)

	local model = AircraftBuilder.build(Cessna172, CFrame.new(TEST_ORIGIN + Vector3.new(0, groundY, 0)), workspace)

	--[[
		Everything from here to the matching cleanup runs inside a pcall.

		An earlier version destroyed the rig on the last line, which meant any
		error mid-suite leaked a 1,100 kg aircraft and a 400 m pad into the
		workspace - and in Studio those survive into the next Play session and
		look convincingly like a double-spawn bug. It cost real time to
		diagnose once already.
	]]
	local testRig = {
		model = model,
		definition = Cessna172,
		flightModel = FlightModel.new(model, Cessna172),
		gear = GroundHandling.new(model, Cessna172),
		input = InputController.new(Cessna172),
		surfaces = SurfaceAnimation.new(model, Cessna172),
	}

	local body = function()

	local dt = 1 / 60

	-- A synthetic screen with the cursor parked in the middle, so the yoke sits
	-- neutral and these sequencing tests are not fighting a phantom roll input.
	local VIEWPORT = Vector2.new(1920, 1080)
	local function snap(actions: { string }?, pointerPos: Vector2?)
		local held = {}
		if actions then
			for _, a in actions do
				held[a] = true
			end
		end
		return {
			held = held,
			pointer = pointerPos or VIEWPORT * 0.5,
			viewportSize = VIEWPORT,
		}
	end

	-- 1. A frame runs and produces something finite.
	local f, t = FlightController.stepFrame(testRig, dt, snap())
	record(
		"A frame produces finite force and torque",
		f.Magnitude == f.Magnitude and f.Magnitude < math.huge
			and t.Magnitude == t.Magnitude and t.Magnitude < math.huge,
		string.format("|F| = %.1f N, |T| = %.1f N*m", f.Magnitude, t.Magnitude)
	)

	--[[
		2. THE check this module exists for: exactly one write per frame.

		applyForces overwrites, so if the gear contribution were written
		separately the aerodynamics would be silently discarded. Comparing the
		constraint against the returned sum catches that.
	]]
	local root = model.PrimaryPart :: BasePart
	local aeroForce = root:FindFirstChild("AeroForce") :: VectorForce
	local written = aeroForce.Force / Constants.STUDS_PER_METER
	record(
		"The constraint holds the SUM of both contributors",
		(written - f).Magnitude < 1e-3,
		string.format("written %.1f N vs returned %.1f N", written.Magnitude, f.Magnitude)
	)

	-- 3. On the ground with no power, the gear must be contributing.
	record(
		"Gear forces reach the constraint on the ground",
		testRig.gear.telemetry.onGround,
		string.format("%d wheels down", testRig.gear.telemetry.wheelsOnGround)
	)

	-- 4. dt is clamped, so a frame hitch cannot integrate a huge step.
	local fHitch = FlightController.stepFrame(testRig, 10, snap())
	record(
		"A 10 s frame hitch stays finite",
		fHitch.Magnitude == fHitch.Magnitude and fHitch.Magnitude < math.huge,
		string.format("|F| = %.1f N", fHitch.Magnitude)
	)
	record(
		"Zero dt is a no-op",
		select(1, FlightController.stepFrame(testRig, 0, snap())) == Vector3.zero,
		"returned zero"
	)

	--[[
		4b. Neutralising the pilot.

		Driven against a synthetic character rather than a real one, because a
		real character needs a player and this is the only seam worth testing:
		the rest is Roblox event plumbing. The fixture deliberately includes the
		two things that break a naive implementation - a part that is ALREADY
		transparent, like the HumanoidRootPart, and a Decal, which is a child of
		a part rather than a property of it.
	]]
	local fakeCharacter = Instance.new("Model")
	fakeCharacter.Name = "__TestCharacter"

	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Transparency = 0
	torso.Parent = fakeCharacter

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Transparency = 0
	head.Parent = fakeCharacter

	-- Ships at Transparency = 1 and must go back to 1, not to 0.
	local hrp = Instance.new("Part")
	hrp.Name = "HumanoidRootPart"
	hrp.Transparency = 1
	hrp.Parent = fakeCharacter

	-- An accessory's Handle is a BasePart descendant, so it is covered too.
	local accessory = Instance.new("Accessory")
	accessory.Parent = fakeCharacter
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Transparency = 0
	handle.Parent = accessory

	local face = Instance.new("Decal")
	face.Name = "face"
	face.Transparency = 0
	face.Parent = head

	fakeCharacter.Parent = workspace

	--[[
		THE ordering test, and the one that caught a live bug.

		The restore path runs BEFORE the hide path ever does - adopt() calls
		onOccupantChanged() as soon as an aircraft is assigned, long before
		anyone sits in it. A restore that defaults to 0 therefore clobbers any
		part that ships transparent, and the HumanoidRootPart is exactly that.
		Verified on a real avatar: it came back opaque.
	]]
	FlightController.setCharacterNeutralised(fakeCharacter, false)
	record(
		"Restoring before ever hiding leaves parts untouched",
		hrp.Transparency == 1 and torso.Transparency == 0,
		string.format("HRP still %.0f, torso still %.0f", hrp.Transparency, torso.Transparency)
	)

	FlightController.setCharacterNeutralised(fakeCharacter, true)
	record(
		"Seated pilot goes invisible",
		torso.Transparency == 1 and head.Transparency == 1 and handle.Transparency == 1,
		string.format("torso %.0f, head %.0f, accessory %.0f", torso.Transparency, head.Transparency, handle.Transparency)
	)
	record(
		"The face decal is hidden too, not left floating",
		face.Transparency == 1,
		string.format("decal transparency %.0f", face.Transparency)
	)
	record(
		"Massless and non-collidable still applied",
		torso.Massless and not torso.CanCollide and head.Massless,
		"mass and collision behaviour unchanged"
	)

	FlightController.setCharacterNeutralised(fakeCharacter, false)
	record(
		"Standing up makes the pilot visible again",
		torso.Transparency == 0 and head.Transparency == 0 and handle.Transparency == 0 and face.Transparency == 0,
		string.format("torso %.0f, head %.0f, accessory %.0f, decal %.0f",
			torso.Transparency, head.Transparency, handle.Transparency, face.Transparency)
	)
	--[[
		THE check that stops a visible bug: restoring blindly to 0 would leave
		a large opaque block stuck through the character, because the
		HumanoidRootPart is meant to stay invisible.
	]]
	record(
		"An already-invisible part is restored to invisible, not to 0",
		hrp.Transparency == 1,
		string.format("HumanoidRootPart back to %.0f (must be 1)", hrp.Transparency)
	)
	record(
		"Mass and collision restored on exit",
		not torso.Massless and torso.CanCollide,
		"massless = false, collidable = true"
	)

	-- Toggling repeatedly must not drift the stored originals.
	for _ = 1, 5 do
		FlightController.setCharacterNeutralised(fakeCharacter, true)
		FlightController.setCharacterNeutralised(fakeCharacter, false)
	end
	record(
		"Repeated boarding does not drift the restored values",
		torso.Transparency == 0 and hrp.Transparency == 1,
		string.format("after 5 cycles: torso %.0f, HRP %.0f", torso.Transparency, hrp.Transparency)
	)

	record(
		"A nil character is a no-op, not an error",
		pcall(FlightController.setCharacterNeutralised, nil, true),
		"returned without erroring"
	)

	-- 4c. Scaling the pilot to human proportions is a guarded no-op when the
	-- rig is not there to scale.
	record(
		"A nil character scales as a no-op, not an error",
		pcall(FlightController.scaleForHumanProportions, nil),
		"returned without erroring"
	)
	record(
		"A character with no Humanoid scales as a no-op",
		pcall(FlightController.scaleForHumanProportions, fakeCharacter),
		string.format("Humanoid found: %s", tostring(fakeCharacter:FindFirstChildOfClass("Humanoid")))
	)

	--[[
		A rig 5.0 studs sole to crown, carrying the two things that must NOT
		count toward height: an oversized HumanoidRootPart (the box the old
		marker read, which is why it reported success while nothing had
		happened) and a tall hat.
	]]
	local heightRig = Instance.new("Model")
	heightRig.Name = "__TestHeightRig"

	local sole = Instance.new("Part")
	sole.Name = "LeftFoot"
	sole.Anchored = true
	sole.Size = Vector3.new(1, 1, 1)
	sole.Position = Vector3.new(0, 0.5, 0) -- sole at y = 0
	sole.Parent = heightRig

	local crown = Instance.new("Part")
	crown.Name = "Head"
	crown.Anchored = true
	crown.Size = Vector3.new(1, 1, 1)
	crown.Position = Vector3.new(0, 4.5, 0) -- crown at y = 5
	crown.Parent = heightRig

	local rootBox = Instance.new("Part")
	rootBox.Name = "HumanoidRootPart"
	rootBox.Anchored = true
	rootBox.Size = Vector3.new(2, 20, 1)
	rootBox.Position = Vector3.new(0, 2.5, 0)
	rootBox.Parent = heightRig

	local hat = Instance.new("Accessory")
	hat.Parent = heightRig
	local hatHandle = Instance.new("Part")
	hatHandle.Name = "Handle"
	hatHandle.Anchored = true
	hatHandle.Size = Vector3.new(1, 4, 1)
	hatHandle.Position = Vector3.new(0, 7, 0)
	hatHandle.Parent = hat

	heightRig.Parent = workspace

	local measured = FlightController.rigHeightStuds(heightRig)
	record(
		"Rig height is measured sole to crown",
		measured ~= nil and math.abs(measured - 5.0) < 1e-3,
		string.format("measured %.3f studs, expected 5.000", measured or -1)
	)
	record(
		"The root box and the hat do not count as height",
		measured ~= nil and measured < 20,
		string.format("a 20-stud root box and a hat at y = 9 left the height at %.3f", measured or -1)
	)
	record(
		"A nil character has no measurable height",
		FlightController.rigHeightStuds(nil) == nil,
		"returned nil rather than a number"
	)

	heightRig:Destroy()

	--[[
		THE property that matters, and the one the old approach never had: the
		scale is derived from a measurement, so re-applying it to a rig already
		at the target changes nothing. That is what lets scaleForHumanProportions
		converge in a loop instead of having to measure perfectly the first time.
	]]
	local fullSize = FlightController.pilotScaleFor(1, 5.156)
	local wanted = FlightController.getPilotHeight()
	record(
		("A full-size avatar scales down to %.2f m"):format(wanted),
		fullSize ~= nil and math.abs(fullSize - wanted / 5.156) < 1e-6,
		string.format("5.156 studs -> scale %.4f", fullSize or -1)
	)
	record(
		"Re-applying the scale to a correct rig is a no-op",
		fullSize ~= nil
			and math.abs(FlightController.pilotScaleFor(fullSize, wanted) - fullSize) < 1e-9,
		("scale %.4f measured at %.2f m returns %.4f"):format(
			fullSize or -1,
			wanted,
			FlightController.pilotScaleFor(fullSize, wanted) or -1
		)
	)
	record(
		"A missing or zero height cannot produce a scale",
		FlightController.pilotScaleFor(1, 0) == nil
			and FlightController.pilotScaleFor(1, nil) == nil
			and FlightController.pilotScaleFor(0, 5) == nil,
		"nil rather than a division by zero"
	)

	fakeCharacter:Destroy()

	-- 5. Engine command wiring.
	record("Engine starts stopped", not testRig.flightModel.engine.running, "running = false")

	FlightController.stepFrame(testRig, dt, snap({ "EngineToggle" }))
	for _ = 1, 180 do
		FlightController.stepFrame(testRig, dt, snap())
	end
	record(
		"E commands the engine to start",
		testRig.flightModel.engine.running,
		string.format("running = true, rpm %.0f", testRig.flightModel.engine.rpm)
	)

	--[[
		6. Pause must not leave a force applied.

		Run with the engine live and the throttle open, because a parked
		aircraft with the engine off produces exactly zero force anyway - the
		test would pass whether pause worked or not.
	]]
	for _ = 1, 120 do
		FlightController.stepFrame(testRig, dt, snap({ "ThrottleUp" }))
	end
	local fPowered = select(1, FlightController.stepFrame(testRig, dt, snap()))
	record(
		"Setup: thrust is being produced before pausing",
		fPowered.Magnitude > 100,
		string.format("|F| = %.0f N", fPowered.Magnitude)
	)

	FlightController.stepFrame(testRig, dt, snap({ "Pause" }))
	local fPaused = FlightController.stepFrame(testRig, dt, snap())
	record(
		"Pause zeroes the constraints",
		fPaused == Vector3.zero and aeroForce.Force == Vector3.zero,
		string.format("|F| = %.6f", aeroForce.Force.Magnitude)
	)

	FlightController.stepFrame(testRig, dt, snap({ "Pause" }))
	local fResumed = FlightController.stepFrame(testRig, dt, snap())
	record(
		"Unpausing resumes integration",
		fResumed.Magnitude > 100,
		string.format("|F| = %.0f N", fResumed.Magnitude)
	)

	FlightController.stepFrame(testRig, dt, snap({ "EngineToggle" }))
	FlightController.stepFrame(testRig, dt, snap())
	record(
		"E commands it to stop again",
		not testRig.flightModel.engine.running,
		"running = false"
	)

	-- 7. Telemetry is populated for the HUD that comes next.
	local tel = testRig.flightModel.telemetry
	record(
		"Telemetry is populated",
		type(tel.altitude) == "number" and type(tel.airspeedTrue) == "number" and tel.altitude == tel.altitude,
		string.format("alt %.1f m, IAS %.1f m/s", tel.altitude, tel.airspeedIndicated)
	)

	-- 8. Release leaves nothing applied.
	FlightModel.release(testRig.flightModel)
	record(
		"release() zeroes both constraints",
		aeroForce.Force == Vector3.zero,
		"zeroed"
	)

	--[[
		9. Reset.

		Driven through the pure predicate rather than through UserInputService,
		which needs a real key press. What is left to Roblox - InputBegan firing
		once per physical press - is the edge trigger itself, and it is structural
		rather than something this module implements and could get wrong.
	]]
	local RESET = InputController.DEFAULT_BINDINGS.ResetAircraft
	record(
		"The reset binding this module reads still exists",
		RESET ~= nil,
		tostring(RESET)
	)

	record(
		"The bound key resets",
		FlightController.shouldReset(RESET, false, RESET, 100, -math.huge),
		"accepted"
	)
	record(
		"Any other key does not",
		not FlightController.shouldReset(Enum.KeyCode.W, false, RESET, 100, -math.huge),
		"W ignored"
	)

	--[[
		THE one that matters for this particular key. Backspace is what a pilot
		presses to correct a typo, and deleting a character must never also delete
		their aeroplane.
	]]
	record(
		"Reset is ignored while the press belongs to the UI",
		not FlightController.shouldReset(RESET, true, RESET, 100, -math.huge),
		"blocked press ignored"
	)

	-- Mashing. InputBegan already stops a HELD key repeating; this is what stops
	-- five jabs queueing five spawns and handing back the last aeroplane.
	record(
		"A second press inside the cooldown is dropped",
		not FlightController.shouldReset(RESET, false, RESET, 100 + RESET_COOLDOWN * 0.5, 100),
		string.format("%.1f s cooldown", RESET_COOLDOWN)
	)
	record(
		"A press after the cooldown is accepted",
		FlightController.shouldReset(RESET, false, RESET, 100 + RESET_COOLDOWN * 1.5, 100),
		"accepted"
	)

	-- Rebinding is honoured, because the predicate compares against the key it is
	-- given rather than a constant of its own.
	record(
		"A rebound reset key is honoured, and the old one released",
		FlightController.shouldReset(Enum.KeyCode.Delete, false, Enum.KeyCode.Delete, 100, -math.huge)
			and not FlightController.shouldReset(RESET, false, Enum.KeyCode.Delete, 100, -math.huge),
		"Delete accepted, Backspace ignored"
	)

	--[[
		THE POINTER BOUNDARY - where the GUI inset bug lived.

		Measured live in Studio: a 1572 x 841 viewport with a 58 px inset, and
		GetMouseLocation() reaching exactly 58 at the top of the screen and 841 at
		the bottom. Those are the real numbers this arithmetic has to survive, so
		they are the fixture rather than a round 1920 x 1080 with no inset, which
		is precisely the case that cannot fail.
	]]
	local VIEWPORT_M = Vector2.new(1572, 841)
	local INSET_M = Vector2.new(0, 58)
	local TOP_EDGE = Vector2.new(786, 58) -- highest the cursor can physically go
	local BOTTOM_EDGE = Vector2.new(786, 841) -- lowest

	local topP, usableM = FlightController.pointerSpace(TOP_EDGE, VIEWPORT_M, INSET_M)
	local bottomP = FlightController.pointerSpace(BOTTOM_EDGE, VIEWPORT_M, INSET_M)

	record(
		"The screen's top and bottom edges map to the ends of the yoke",
		math.abs(topP.Y) < 1e-6 and math.abs(bottomP.Y - usableM.Y) < 1e-6,
		string.format("top -> %.1f, bottom -> %.1f of %.0f", topP.Y, bottomP.Y, usableM.Y)
	)

	--[[
		The assertion the original bug would have failed, and the reason it is
		written as a SYMMETRY rather than as two absolute values: it needs no
		agreement about what full deflection should be, only that the yoke can
		reach as much of one as of the other. It read -0.766 against +1.000.
	]]
	local function pitchAt(mouse: Vector2): number
		local p, u = FlightController.pointerSpace(mouse, VIEWPORT_M, INSET_M)
		local st = InputController.new(Cessna172)
		for _ = 1, 60 do
			InputController.update(st, dt, { held = {}, pointer = p, viewportSize = u })
		end
		return st.controls.pitch
	end

	local pitchTop, pitchBottom = pitchAt(TOP_EDGE), pitchAt(BOTTOM_EDGE)
	record(
		"Nose-down authority equals nose-up authority",
		math.abs(pitchTop + pitchBottom) < 1e-3 and math.abs(pitchBottom - 1) < 1e-3,
		string.format("top %+.3f, bottom %+.3f", pitchTop, pitchBottom)
	)

	--[[
		And where neutral physically SITS, which is the half of the bug a
		symmetry check cannot see: both edges could be reachable with the whole
		mapping still shifted. Neutral must be the middle of the visible strip -
		mouse y (58 + 841) / 2 = 449.5 - not the middle of a usable area measured
		from zero, which is where it used to be at y 391.5.
	]]
	local pitchCentre = pitchAt(Vector2.new(786, (TOP_EDGE.Y + BOTTOM_EDGE.Y) * 0.5))
	record(
		"Neutral is the middle of the visible screen",
		math.abs(pitchCentre) < 1e-6,
		string.format("pitch %+.6f at mouse y %.1f", pitchCentre, (TOP_EDGE.Y + BOTTOM_EDGE.Y) * 0.5)
	)

	--[[
		Off the game view, Roblox reports (-1, -1). Read as a position that is the
		top-left corner: hard nose-down AND hard left roll in one frame. It has to
		be recognised as missing data instead.
	]]
	local sentinel = FlightController.pointerSpace(Vector2.new(-1, -1), VIEWPORT_M, INSET_M)
	local held, onView = FlightController.resolvePointer(sentinel, usableM, bottomP)
	record(
		"An off-view cursor holds the yoke instead of jumping to a corner",
		not onView and (held - bottomP).Magnitude < 1e-6,
		string.format("held y %.1f, not %.1f", held.Y, sentinel.Y)
	)

	local fresh = FlightController.resolvePointer(sentinel, usableM, nil)
	record(
		"An off-view cursor with no memory is neutral, not a corner",
		math.abs(fresh.Y - usableM.Y * 0.5) < 1e-6 and math.abs(fresh.X - usableM.X * 0.5) < 1e-6,
		string.format("%.1f, %.1f", fresh.X, fresh.Y)
	)

	local inside, insideOk = FlightController.resolvePointer(Vector2.new(100, 200), usableM, bottomP)
	record(
		"A cursor on the view is passed through untouched",
		insideOk and inside == Vector2.new(100, 200),
		"passed through"
	)

	--[[
		THE FLIGHT RECORDER, built to diagnose a reported altitude-hold
		oscillation with numbers. Its formatting and summary are pinned down
		with a synthetic recording: a 3 m/s-amplitude, 2 s-period sine in
		vertical speed, which must read back as a ~2 s period and the ~1.9 m
		altitude swing that sine integrates to, and a CSV of exactly the
		frames recorded.
	]]
	local sine = {}
	local st = 0
	local salt = 100
	for i = 1, 240 do
		st += 1 / 60
		local svs = 3 * math.sin(math.pi * st)
		salt += svs / 60
		table.insert(sine, { t = st, pitch = 0.3 * math.cos(math.pi * st), att = 0, bank = 0, hdg = 0, alt = salt, vs = svs, ias = 60 })
	end
	local m = FlightController.recordingMetrics(sine)
	record(
		"Recorder metrics see the synthetic VS sine",
		math.abs(m.period - 2) < 0.1 and m.vsMax > 2.98 and m.vsMin < -2.98,
		string.format("period %.2f s, VS %+.2f .. %+.2f m/s", m.period or 0, m.vsMin, m.vsMax)
	)
	record(
		"...and the altitude swing it integrates to",
		m.altMax - m.altMin > 1.5 and m.altMax - m.altMin < 2.3,
		string.format("%.2f m peak to peak", m.altMax - m.altMin)
	)
	record(
		"The recorder formats exactly the frames it was given",
		#FlightController.formatRecording(sine) == #sine + 1,
		string.format("%d data rows + header", #sine)
	)

	--[[
		---- The camera pivots around the centre of the head -------------------

		⚠️ THE BUG THIS PINS, AND IT IS NOT "THE OFFSET WAS SLIGHTLY OFF".
		Roblox focuses the character camera a hard-coded 1.500 studs above the
		HumanoidRootPart, and that constant does NOT scale with
		`Model:ScaleTo` - measured by writing offsets and reading camera.Focus
		back in the root's own frame. A pilot scaled to 0.35 has their head
		centre only 0.514 above the root, so the camera was orbiting a point
		almost a metre ABOVE their head. Zero offset was never "centred on the
		head".

		The correction is therefore the difference between that stock constant
		and the live rig's geometry, which is why the input is measured.
	]]
	local stockOffset = FlightController.headPivotOffset(1.5)

	record(
		"A stock-size rig needs almost no correction",
		math.abs(stockOffset.Y) < 1e-6 and math.abs(stockOffset.Z) < 1e-6,
		string.format("%s - pivot already at the stock focus height", tostring(stockOffset))
	)

	--[[
		The pilot as they actually are: a rig scaled to PILOT_HEIGHT_M over a
		stock 5.156-stud build. The stock head centre sits 1.500 above the root,
		so scaling carries it down to `scale * 1.500` - and the correction has
		to reach DOWN past that, a positive offset would be the bug. The 0.905 m
		error below was measured live at the old 0.35x scale.
	]]
	local pilotScale = FlightController.getPilotHeight() / 5.156
	local pilotHeadAboveRoot = 1.5 * pilotScale
	local scaledOffset = FlightController.headPivotOffset(pilotHeadAboveRoot)
	record(
		"A scaled pilot's pivot is pulled DOWN onto the head",
		scaledOffset.Y < -0.8 and scaledOffset.Y > -1.2,
		string.format("%.3f studs, against the 0.905 m error measured live", scaledOffset.Y)
	)
	record(
		"The pivot sits INSIDE the head, not pushed to the face",
		math.abs(scaledOffset.Z) < 1e-6,
		string.format("%.3f lateral, so the orbit rotates about the head centre", scaledOffset.Z)
	)
	--[[
		The whole point: the corrected pivot must sit on the head wherever the
		stock constant would have put it. Reconstructing focus from the measured
		rule - root + 1.5 + offset - has to land on the head centre.
	]]
	local focusAboveRoot = 1.5 + scaledOffset.Y
	record(
		"The corrected pivot sits on the head, not above it",
		math.abs(focusAboveRoot - pilotHeadAboveRoot) < 1e-6,
		string.format("pivot %.3f above the root, head centre %.3f", focusAboveRoot, pilotHeadAboveRoot)
	)
	record(
		"Missing geometry yields no offset rather than a wrong one",
		FlightController.headPivotOffset(nil) == Vector3.zero,
		"zero, so the camera is left where Roblox put it"
	)
	end

	local ok, err = pcall(body)

	model:Destroy()
	pad:Destroy()

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

return FlightController
