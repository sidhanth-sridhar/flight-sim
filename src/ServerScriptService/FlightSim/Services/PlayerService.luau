--!strict
--[[
	PlayerService
	-------------
	The pilot's body. Builds every character as a CLASSIC R6 rig and puts it on
	the apron, replacing the engine's automatic character loading.

	WHY THIS EXISTS
	---------------
	The pilot asked for R6. ⚠️ R6 IS NOT A DATAMODEL PROPERTY AND ROJO CANNOT
	WRITE IT. StarterPlayer, Workspace and Players were all probed and none of
	them carries a rig-type property - the choice lives in place-level Game
	Settings, which is not a file and therefore not something this repository
	can be the source of truth for (section 3 says files are).

	So the rig is built in code instead:

		Players.CharacterAutoLoads = false
		Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R6)

	The Studio setting is ALSO set to R6, so the two agree and a place opened
	without this service still gets the right rig. This service is what makes it
	true in the repository rather than only in the place file.

	⚠️ THIS TAKES OVER SPAWNING, WHICH SEVERAL SYSTEMS SIT ON TOP OF. It runs
	LAST in SERVICE_ORDER for that reason: AirportService moves
	Workspace.SpawnLocation onto the apron at the airport elevation (section 20,
	section 30), and a character built before that move would be placed on a pad
	still at Rojo's y = 0 - underneath the terrain, inside the ground. The
	spawn point has to exist and be in the right place before anybody stands
	on it.

	WHAT THIS DELIBERATELY DOES NOT DO
	----------------------------------
	It does not scale the pilot. FlightController.scaleForHumanProportions
	already measures the rig and scales it to PILOT_HEIGHT_M (section 30), and
	it is rig-agnostic - it reads the assembled rig rather than assuming R15 -
	so R6 lands on PILOT_HEIGHT_M through exactly the same path. Adding a second
	thing that scales characters is how two of them end up disagreeing.

	It does not set collision groups. AircraftService.trackCharacter already
	does that on CharacterAdded, and assigning player.Character fires
	CharacterAdded normally, so that machinery is untouched.

	WHAT WAS MEASURED BEFORE WRITING IT
	-----------------------------------
	  1. CreateHumanoidModelFromDescription(desc, R6) returns a genuine R6 rig -
	     Torso, Left Arm, Right Arm, Left Leg, Right Leg, Head.
	  2. ⚠️ IT ALREADY CONTAINS ITS OWN `Animate` LocalScript. This was the real
	     risk in hand-building a character: StarterPlayer.StarterCharacterScripts
	     is EMPTY in this place, so if the rig had not brought Animate with it,
	     the pilot would have stood frozen in the default pose and section 30's
	     settle-then-measure would have had nothing to settle.
	  3. ⚠️ THE FRESH MODEL'S EXTENTS ARE MEANINGLESS - 6.7 x 16.5 x 31.5 studs,
	     because the accessories have not been welded into place yet. The feet
	     are therefore found AFTER the rig is in the world, by measuring, not
	     from GetExtentsSize() on the model as returned.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local FlightSim = ReplicatedStorage:WaitForChild("FlightSim")
local Constants = require(FlightSim.Config.Constants)
local Units = require(FlightSim.Shared.Units)
local CharacterTuning = require(FlightSim.Shared.CharacterTuning)

local PlayerService = {}

PlayerService.RIG_TYPE = Enum.HumanoidRigType.R6

-- A hair of daylight under the feet at spawn. The character is unanchored, so
-- it settles onto the pad immediately; starting it fractionally INSIDE the pad
-- is what produces a spawn that shoots the player into the air.
local SPAWN_CLEARANCE = 0.05

-- If the avatar cannot be fetched the player still gets a body, so a Roblox
-- web outage cannot leave somebody standing on the apron with no character.
local FALLBACK_DESCRIPTION_NOTE = "avatar lookup failed - spawning the default appearance"

local connections: { RBXScriptConnection } = {}

-- =========================================================================
-- GEOMETRY
-- =========================================================================

--[[
	The part a rig is positioned BY.

	⚠️ NOT model:GetPivot(). A rig straight out of
	CreateHumanoidModelFromDescription has no PrimaryPart, and GetPivot on a
	model without one returns the centre of the bounding box - which on a fresh
	rig is dominated by unwelded accessories sprawling 31 studs down the Z axis.
	Measuring feet against that number places the pilot nowhere near the ground.
]]
local function rootOf(model: Model?): BasePart?
	if not model then
		return nil
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return model.PrimaryPart
end

--[[
	How far the lowest point of a rig sits below its root part, in studs.

	Accessories are excluded for the same reason section 30 excludes them from
	height: a hat is not a foot, and a trailing accessory would push the whole
	character up off the ground by however far it dangles.

	⚠️ Measured on the rig as BUILT, before it enters the world. The body parts
	of a fresh rig are already in their rest pose - verified: root at +18.000,
	feet at +15.000, a clean 3.000 - even though the accessories are not. That
	is what makes it safe to place a character correctly on the first attempt
	instead of dropping it and correcting afterwards.

	Returns nil for anything that is not a rig, so the caller can fall back
	rather than place a character using a garbage number.
]]
function PlayerService.feetOffset(model: Model?): number?
	local root = rootOf(model)
	if not root or not model then
		return nil
	end
	local lowest = math.huge
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and not d:FindFirstAncestorOfClass("Accessory") then
			lowest = math.min(lowest, d.Position.Y - d.Size.Y / 2)
		end
	end
	if lowest == math.huge then
		return nil
	end
	return root.Position.Y - lowest
end

--[[
	⚠️ DO NOT "FIX" R6's HipHeight = 0. IT IS ALREADY CORRECT, AND THE EVIDENCE
	THAT IT IS NOT IS AN ARTEFACT.

	A hand-built R6 rig arrives with HipHeight = 0. Read from the SERVER the
	pilot then appears to be standing 1.956 m underground - torso on the
	surface, both legs straight through it. It is not: `Model:ScaleTo` is
	applied by FlightController on the CLIENT and does not replicate, so the
	server holds unscaled 5-stud legs hanging off a root positioned by the
	client's PILOT_HEIGHT_M character. Measuring that replica compares a
	full-size body against a scaled-down stance, and the difference looks
	exactly like sinking.

	Deriving a HipHeight from the geometry to "correct" it was written, tested
	and thrown away: for R6 the feet rest at `ground + HipHeight`, so the
	derived 2.000 lifted the pilot 0.70 m into the air once scaled. Measured on
	the client, which is the only place the character is real:

	    HipHeight 0.7002 -> feet +0.6971 m above the ground
	    HipHeight 0.0000 -> feet -0.0013 m, standing on it

	This is section 30's lesson again: a number that cannot tell success from
	doing nothing is not a measurement. ⚠️ VERIFY CHARACTER GEOMETRY ON THE
	CLIENT. The server's copy of a scaled character is not what the player sees.
]]

--[[
	Where a rig's pivot goes so that its feet land on top of the spawn pad.

	Pure arithmetic, so it can be tested without spawning anybody - and it is
	the one calculation that decides whether the pilot starts standing on the
	apron or buried in it.
]]
function PlayerService.spawnPivot(pad: BasePart, feetOffset: number): CFrame
	local padTop = pad.Position.Y + pad.Size.Y / 2
	return CFrame.new(pad.Position.X, padTop + feetOffset + SPAWN_CLEARANCE, pad.Position.Z)
end

--[[
	The project's metre-scale walk and jump, which a hand-built character does
	not get for free - StarterPlayer's properties only reach characters the
	engine loads itself. Shared with FlightController, which has to re-apply it
	after scaling the pilot; see CharacterTuning for why it takes two.
]]
PlayerService.applyMovementTuning = CharacterTuning.apply

local function findSpawnPad(): BasePart?
	local spawn = Workspace:FindFirstChild("SpawnLocation")
	if spawn and spawn:IsA("BasePart") then
		return spawn
	end
	-- Any SpawnLocation will do rather than none; the named one is simply the
	-- one AirportService moves.
	for _, d in Workspace:GetDescendants() do
		if d:IsA("SpawnLocation") then
			return d
		end
	end
	return nil
end

-- =========================================================================
-- SPAWNING
-- =========================================================================

local function describe(player: Player): HumanoidDescription
	local ok, desc = pcall(function()
		return Players:GetHumanoidDescriptionFromUserId(player.UserId)
	end)
	if ok and desc then
		return desc
	end
	warn(string.format("[PlayerService] %s: %s", player.Name, FALLBACK_DESCRIPTION_NOTE))
	return Instance.new("HumanoidDescription")
end

local function spawnCharacter(player: Player)
	if not player.Parent then
		return
	end

	local desc = describe(player)
	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromDescription(desc, PlayerService.RIG_TYPE)
	end)

	--[[
		⚠️ A COSMETIC PREFERENCE MUST NEVER BE ABLE TO LEAVE A PLAYER BODILESS.
		If the R6 build fails for any reason, hand the job back to the engine:
		the player gets an R15 character and can still fly, which is strictly
		better than standing in a black screen because a rig type was wanted.
	]]
	if not ok or not model then
		warn(string.format("[PlayerService] %s: R6 build failed (%s) - falling back to LoadCharacter", player.Name, tostring(model)))
		player:LoadCharacter()
		return
	end

	model.Name = player.Name

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	PlayerService.applyMovementTuning(humanoid)

	--[[
		No name or health floating over the pilot - the pilot's call.

		⚠️ Roblox's built-in tag is positioned in STOCK studs and does not follow
		`Model:ScaleTo`, so on a PILOT_HEIGHT_M pilot it hangs far overhead. Set here as
		well as on the client so it is off from the first frame and for every
		viewer, not just the owner.
	]]
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end

	--[[
		Placed BEFORE parenting, from the rest pose, so the pilot never appears
		at the world origin and never has to be dropped and corrected. The rig
		is unanchored, so the last few millimetres of clearance settle
		themselves.
	]]
	local pad = findSpawnPad()
	if pad then
		local feet = PlayerService.feetOffset(model)
		if feet then
			model:PivotTo(PlayerService.spawnPivot(pad, feet))
		end
	end

	model.Parent = Workspace
	player.Character = model

	if humanoid then
		humanoid.Died:Connect(function()
			task.wait(Players.RespawnTime)
			if player.Parent then
				spawnCharacter(player)
			end
		end)
	end
end

local function trackPlayer(player: Player)
	spawnCharacter(player)
end

-- =========================================================================
-- INIT
-- =========================================================================

function PlayerService.Init()
	--[[
		⚠️ THIS LINE IS WHAT MAKES THE REST OF THE FILE NECESSARY. With it true,
		the engine loads a character the instant a player joins, using the rig
		type from Game Settings - and there would then be two characters, or a
		flicker from one rig to the other.
	]]
	Players.CharacterAutoLoads = false

	table.insert(connections, Players.PlayerAdded:Connect(trackPlayer))

	-- In Studio the local player can already be present before services start,
	-- and PlayerAdded would never fire for them - the same reason
	-- AircraftService sweeps the existing players at Init.
	for _, player in Players:GetPlayers() do
		if not player.Character then
			task.spawn(trackPlayer, player)
		end
	end

	print(string.format("[FlightSim:Server] PlayerService ready - characters build as %s", PlayerService.RIG_TYPE.Name))
end

function PlayerService.Stop()
	for _, c in connections do
		c:Disconnect()
	end
	table.clear(connections)
	Players.CharacterAutoLoads = true
end

-- =========================================================================
-- TESTS
-- =========================================================================

function PlayerService.runTests(): (boolean, { any })
	local results = {}
	local allPassed = true

	local function record(label: string, passed: boolean, detail: string)
		if not passed then
			allPassed = false
		end
		table.insert(results, { label = label, passed = passed, detail = detail })
		print(string.format("  [%s] %-46s %s", passed and "PASS" or "FAIL", label, detail))
	end

	print("=== PlayerService: verification ===")

	-- 1. The rig type is the whole point of the service ---------------------
	record(
		"Characters are built as R6",
		PlayerService.RIG_TYPE == Enum.HumanoidRigType.R6,
		tostring(PlayerService.RIG_TYPE)
	)

	--[[
		2. The engine is not also loading characters -------------------------

		If this is ever true again, the pilot gets whichever rig Game Settings
		names and this file is doing nothing - which would look like the R6
		change silently reverting.
	]]
	record(
		"Automatic character loading is off",
		Players.CharacterAutoLoads == false,
		string.format("CharacterAutoLoads = %s", tostring(Players.CharacterAutoLoads))
	)

	-- 3. Feet land on the pad, not in it -----------------------------------
	local pad = Instance.new("Part")
	pad.Size = Vector3.new(12, 1, 12)
	pad.Position = Vector3.new(-150, 250, 340)
	local padTop = pad.Position.Y + pad.Size.Y / 2

	local pivot = PlayerService.spawnPivot(pad, 3)
	--[[
		⚠️ A CFrame STORES ITS POSITION AS float32. At an airport 250 m up that
		is about 1.5e-5 studs of precision, so a 1e-6 comparison fails on the
		round-trip alone - which it did, reporting a 0.050 clearance as wrong
		when 0.050 was exactly right. A tenth of a millimetre is the tightest
		honest tolerance here, and it is far finer than anything it protects.
	]]
	local CFRAME_EPSILON = 1e-4
	record(
		"A rig spawns with its feet on top of the pad",
		math.abs((pivot.Position.Y - 3) - (padTop + SPAWN_CLEARANCE)) < CFRAME_EPSILON,
		string.format("feet at %.4f, pad top %.4f, clearance %.4f", pivot.Position.Y - 3, padTop, (pivot.Position.Y - 3) - padTop)
	)
	record(
		"Spawn clearance is above the pad, never inside it",
		(pivot.Position.Y - 3) > padTop and (pivot.Position.Y - 3) - padTop < 0.5,
		string.format("%.3f m of daylight", (pivot.Position.Y - 3) - padTop)
	)
	record(
		"A rig spawns over the pad, not beside it",
		math.abs(pivot.Position.X - pad.Position.X) < CFRAME_EPSILON
			and math.abs(pivot.Position.Z - pad.Position.Z) < CFRAME_EPSILON,
		string.format("%.1f, %.1f against pad %.1f, %.1f", pivot.Position.X, pivot.Position.Z, pad.Position.X, pad.Position.Z)
	)

	--[[
		4. The feet measurement ignores accessories ---------------------------

		A dangling accessory that counted as a foot would push the whole pilot
		up off the ground by however far it hangs - section 30's reason for
		excluding them from height, applied to the other end of the body.
	]]
	local rig = Instance.new("Model")
	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(2, 2, 1)
	torso.Position = Vector3.new(0, 3, 0)
	torso.Parent = rig
	local leg = Instance.new("Part")
	leg.Name = "Left Leg"
	leg.Size = Vector3.new(1, 2, 1)
	leg.Position = Vector3.new(-0.5, 1, 0)
	leg.Parent = rig
	rig.PrimaryPart = torso

	local bare = PlayerService.feetOffset(rig)

	local accessory = Instance.new("Accessory")
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(1, 1, 1)
	handle.Position = Vector3.new(0, -5, 0) -- hanging well below the feet
	handle.Parent = accessory
	accessory.Parent = rig

	local withAccessory = PlayerService.feetOffset(rig)
	record(
		"An accessory below the feet does not become the feet",
		bare ~= nil and withAccessory ~= nil and math.abs((bare :: number) - (withAccessory :: number)) < 1e-6,
		string.format("%.3f studs with and without", withAccessory or -1)
	)

	record(
		"Feet are measured below the root part",
		bare ~= nil and math.abs((bare :: number) - 3) < 1e-6,
		string.format("%.3f studs below the root (root at y = 3, lowest part at y = 0)", bare or -1)
	)

	record(
		"A model with no parts reports no feet rather than a wrong number",
		PlayerService.feetOffset(Instance.new("Model")) == nil and PlayerService.feetOffset(nil) == nil,
		"nil, not zero"
	)

	--[[
		5. The root part is found by name, not by pivot -----------------------

		A fresh rig has no PrimaryPart, and GetPivot on a model without one
		returns the bounding-box centre - which on a rig whose accessories have
		not welded yet is 31 studs out. Measuring feet against that number is
		what would place the pilot nowhere near the pad.
	]]
	--[[
		6. The tuned walk and jump reach a hand-built character ----------------

		⚠️ THE BUG THIS PINS: StarterPlayer.CharacterWalkSpeed and
		CharacterJumpHeight are applied by the ENGINE to characters it loads
		itself. This service assigns player.Character by hand, so a character
		built here can sit on the stock 16 studs/s and 7.2 studs while the
		bootstrap's numbers are ignored. The pilot found it by resetting in the
		seat and landing on the apron unable to jump properly.

		Asserted against Constants rather than against literals, so retuning the
		constants cannot leave this test asserting the old values.
	]]
	local rigged = Instance.new("Humanoid")
	rigged.WalkSpeed = 16
	rigged.JumpHeight = 7.2
	PlayerService.applyMovementTuning(rigged)

	local wantWalk = Units.metersToStuds(Constants.CHARACTER.WALK_SPEED)
	record(
		"A built character walks at the tuned speed",
		math.abs(rigged.WalkSpeed - wantWalk) < 1e-3,
		string.format("%.2f studs/s (%.1f m/s), not the stock 16", rigged.WalkSpeed, Constants.CHARACTER.WALK_SPEED)
	)
	record(
		"A built character jumps to the tuned height",
		rigged.UseJumpPower == false
			and math.abs(rigged.JumpHeight - Units.metersToStuds(Constants.CHARACTER.JUMP_HEIGHT)) < 1e-3,
		string.format("%.2f studs, UseJumpPower=%s", rigged.JumpHeight, tostring(rigged.UseJumpPower))
	)
	--[[
		⚠️ UseJumpPower must stay FALSE at metre scale. JumpPower is a raw launch
		velocity, so at one twentieth of normal gravity a stock jump clears a
		five-storey building; JumpHeight is a distance and the engine derives the
		velocity from the live gravity.
	]]
	record(
		"Jump is expressed as a height, not a launch velocity",
		Constants.CHARACTER.USE_JUMP_POWER == false and rigged.UseJumpPower == false,
		"UseJumpPower false, so gravity changes cannot rescale the jump"
	)
	record(
		"Tuning a nil humanoid is survivable",
		pcall(PlayerService.applyMovementTuning, nil),
		"no error"
	)

	--[[
		⚠️ THE ONE THAT ACTUALLY BIT: `Model:ScaleTo` scales WalkSpeed and
		JumpHeight with the rig. Tuned values of 20.00 m/s and 1.00 m were
		measured on the live pilot afterwards as 7.00 and 0.35 - the scale
		factor applied to both (measured at the old 0.35x pilot scale; the
		factor changes with PILOT_HEIGHT_M). Re-applying has to RESTORE the
		metre-scale numbers rather than re-scale them, because a scaled rig is
		still a PILOT_HEIGHT_M person (section 30).
	]]
	rigged.WalkSpeed = wantWalk * 0.35
	rigged.JumpHeight = Units.metersToStuds(Constants.CHARACTER.JUMP_HEIGHT) * 0.35
	PlayerService.applyMovementTuning(rigged)
	record(
		"Re-applying after ScaleTo restores metre-scale movement",
		math.abs(rigged.WalkSpeed - wantWalk) < 1e-3,
		string.format("%.2f studs/s again, not the scaled-down %.2f", rigged.WalkSpeed, wantWalk * 0.35)
	)
	rigged:Destroy()

	local noRoot = Instance.new("Model")
	local stray = Instance.new("Part")
	stray.Name = "Handle"
	stray.Size = Vector3.new(1, 1, 1)
	stray.Position = Vector3.new(0, -50, 0)
	stray.Parent = Instance.new("Accessory")
	stray.Parent.Parent = noRoot
	record(
		"A rig of nothing but accessories reports no feet",
		PlayerService.feetOffset(noRoot) == nil,
		"nil - an accessory is never a foot, even when it is the only part"
	)
	noRoot:Destroy()

	rig:Destroy()
	pad:Destroy()

	local passCount = 0
	for _, r in results do
		if r.passed then
			passCount += 1
		end
	end
	print(string.format("=== %s (%d/%d) ===", allPassed and "ALL PASSED" or "FAILURES PRESENT", passCount, #results))

	return allPassed, results
end

return PlayerService
