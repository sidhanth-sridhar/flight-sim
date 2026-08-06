--!strict
--[[
	CharacterTuning
	---------------
	The project's metre-scale walk and jump, applied to a Humanoid.

	WHY THIS IS SHARED, AND WHY IT IS APPLIED TWICE
	-----------------------------------------------
	Two separate things undo this tuning, on two sides of the wire, so both
	sides have to re-assert it - and they must not drift apart, which is why the
	arithmetic lives here rather than being written out twice.

	  1. ⚠️ StarterPlayer.CharacterWalkSpeed / CharacterJumpHeight ONLY REACH
	     CHARACTERS THE ENGINE LOADS ITSELF. PlayerService assigns
	     player.Character by hand (section 34), so a character built there can
	     keep the stock 16 studs/s and 7.2 studs and ignore the bootstrap
	     entirely.

	  2. ⚠️ `Model:ScaleTo` SCALES WalkSpeed AND JumpHeight WITH THE RIG. This is
	     the one that actually bit. FlightController shrinks the pilot to
	     PILOT_HEIGHT_M and the engine helpfully rescales the movement with it:
	     a tuned 20.00 m/s and 1.00 m were measured afterwards as **7.00 and
	     0.35** (at the old 0.35x scale; the factor scales with the rig). The
	     pilot reported it as a reset leaving them unable to jump properly, and
	     every number in Constants was correct the whole time.

	(2) is why FlightController re-applies this AFTER its scale loop converges
	rather than at spawn. Scaling a rig does not make its owner a smaller
	person: section 30's rule is that a PILOT_HEIGHT_M human walks at the
	configured speed whatever the rig measures, so the speed is restored in
	metres per second and not scaled to match the model.

	⚠️ UseJumpPower must stay FALSE at metre scale. JumpPower is a raw launch
	velocity, so at one twentieth of normal gravity a stock jump clears a
	five-storey building; JumpHeight is a distance and the engine derives the
	velocity from the live gravity, so it stays correct on its own.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FlightSim = ReplicatedStorage:WaitForChild("FlightSim")
local Constants = require(FlightSim.Config.Constants)
local Units = require(FlightSim.Shared.Units)

local CharacterTuning = {}

--[[
	The tuned values, in studs, as the engine wants them.

	Exposed separately from the applier so a test can assert the numbers without
	needing a Humanoid, and so both callers agree on one conversion.
]]
function CharacterTuning.values(): (number, number, boolean)
	local character = Constants.CHARACTER
	return Units.metersToStuds(character.WALK_SPEED),
		Units.metersToStuds(character.JUMP_HEIGHT),
		character.USE_JUMP_POWER == true
end

--[[
	Put a Humanoid back on the project's tuning. Safe to call repeatedly, which
	is the point: it is called once when the character is built and again every
	time the pilot's scale settles.
]]
function CharacterTuning.apply(humanoid: Humanoid?)
	if not humanoid then
		return
	end
	local walk, jump, usePower = CharacterTuning.values()
	humanoid.WalkSpeed = walk
	humanoid.UseJumpPower = usePower
	if usePower then
		humanoid.JumpPower = jump
	else
		humanoid.JumpHeight = jump
	end
end

return CharacterTuning
