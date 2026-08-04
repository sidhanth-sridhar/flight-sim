--!strict
--[[
	AircraftService
	---------------
	The server's authority over aircraft existence: who has one, where it
	appeared, who is allowed to fly it, and when it goes away.

	WHY THE SERVER BUILDS IT AT ALL
	-------------------------------
	The physics is client-owned - that decision stands and nothing here changes
	it. But a model built on the client exists only on that client: no other
	player can see it, the server cannot enforce anything about it, and it
	vanishes with a rejoin. So the server builds the assembly and then hands
	*simulation* of it to the pilot via SetNetworkOwner. The client still runs
	every force; it simply no longer owns the instance.

	That split is the whole design:

		server   which aircraft exist, where they spawn, who owns each one
		client   what forces act on the one it was given, every frame

	ORDER MATTERS AT SPAWN. Network ownership must be granted BEFORE the client
	is told about the aircraft. A client that starts writing VectorForce.Force
	to an assembly it does not own gets no error and no motion - the engine
	silently discards it - which looks exactly like broken aerodynamics. So the
	AircraftAssigned event is fired last, and it means "this is yours and you
	own it", not merely "this exists".

	WHAT THIS SERVICE DELIBERATELY DOES NOT DO
	------------------------------------------
	It does not replicate position, velocity or control positions. Roblox
	replicates the assembly's motion natively because the pilot owns it, and
	doing it again by hand would be slower and worse. Fuel and engine state
	sync is AircraftStateSync's job and is not built yet.
]]

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local FlightSim = ReplicatedStorage:WaitForChild("FlightSim")

local Constants = require(FlightSim.Config.Constants)
local Remotes = require(FlightSim.Net.Remotes)
local Registry = require(FlightSim.Aircraft.Registry)
local AircraftBuilder = require(FlightSim.Aircraft.AircraftBuilder)

local AircraftService = {}

-- =========================================================================
-- CONFIGURATION
-- =========================================================================

-- Every spawned aircraft lives here, so workspace stays readable and anything
-- that needs to iterate aircraft has one obvious place to look.
local CONTAINER_NAME = "Aircraft"

--[[
	Where aircraft park.

	y = 1.30 m is the height at which the tyres rest exactly on a surface whose
	top face is y = 0 - derived in GroundHandling.runTests(). Spawning higher
	means the aircraft free-falls before anyone reaches it; spawning lower means
	Roblox resolves the interpenetration by launching it.

	The 30 m offset is not arbitrary and was measured, not guessed. Parking on
	the origin puts the aircraft on top of Workspace.SpawnLocation - a 12 x 12 m
	pad whose top face is at y = 1.00 - which does two unhelpful things at once:
	the aeroplane rests a metre above the runway on a ledge it must roll off to
	take off, and the player materialises INSIDE it. A Roblox character is a
	collidable 1.9 m body that spawns unannounced; the first observed live spawn
	shoved a parked 1,111 kg aircraft 4.5 m across the apron before it settled.
	Thirty metres clears the pad entirely and costs the pilot a short walk.
]]
local SPAWN_ORIGIN = CFrame.new(0, 1.30, -30)

--[[
	Lateral spacing between parked aircraft, in metres.

	The 172's span is 11.0 m, so 18 m leaves a comfortable 7 m between wingtips.
	Two aircraft spawned into the same space do not politely overlap - Roblox
	resolves the penetration explosively, and the first thing either pilot sees
	is their aeroplane cartwheeling.
]]
local SPAWN_SPACING = 18

--[[
	How often the position sanity check runs, in seconds.

	Slow on purpose. This is not anti-cheat; it is a tripwire for a client that
	has gone numerically insane (NaN position, escaped the atmosphere) so the
	problem is reported once rather than discovered an hour later in a
	screenshot. See ENFORCE_LIMITS below for why it only warns.
]]
local SANITY_PERIOD = 2

--[[
	Warn on limit violations, do not destroy the aircraft.

	Constants.LIMITS are generous - 400 m/s, 20 km, -500 m - so anything
	tripping them during Phase 1 is far more likely to be a bug in our own
	physics than a cheating client. Deleting the pilot's aircraft mid-test
	would destroy the evidence and the flight. Flip this to true once the
	flight model is trusted and the sim has players who are not us.
]]
local ENFORCE_LIMITS = false

--[[
	Pilots and aeroplanes do not collide. Measured, not assumed.

	A Roblox character is a solid ~1.9 m body that cannot be shrunk below the
	avatar scale limits, and the cabin it has to sit in is 1.5 m. Sit() welds
	the two into one assembly, but for the frame BEFORE the weld exists the
	character is a separate rigid body teleported inside the fuselage - and
	Roblox resolves that interpenetration the only way it knows how. Measured on
	a live boarding from 5 m away: the aircraft was thrown 12.3 m sideways and
	11 m into the air, and was still travelling at 5.1 m/s two seconds later.

	The client already makes the seated pilot massless and non-collidable, but
	that runs on the Occupant-changed event - which is to say, after the weld,
	one frame too late to prevent any of it. And it cannot fully succeed anyway:
	the Humanoid forces HumanoidRootPart.CanCollide back to true every frame.

	Separating them by collision group fixes it at the source, and fixes the
	other half of the same problem for free - a player walking into a parked
	aeroplane was shoving 1,111 kg around the apron.

	THE TRADE, stated plainly: a player can now walk through a parked aircraft,
	and cannot stand on the wing. For a simulator boarded by prompt that is a
	fair price for an aeroplane that stays where it was parked.

	A SEATED pilot then needs a third group, and this one is not obvious.

	Separating pilot from aircraft removed the explosion but left the aircraft
	floating 5.6 m in the air. The reason: sitting WELDS the character into the
	aircraft's assembly, and a 1.9 m character folded into a 1.5 m cabin has its
	root part sticking out through the floor. That root is still collidable -
	the Humanoid forces HumanoidRootPart.CanCollide back to true every frame, so
	neither the client nor the server can switch it off and make it stay off -
	so the RUNWAY pushed on it, and since it is now rigidly part of the
	aeroplane, the runway jacked the whole aeroplane up until the pilot's hips
	cleared the ground.

	So a seated pilot collides with nothing at all. They are cargo: the assembly
	they are welded to does all the colliding on their behalf. On standing up
	they go back to the ordinary Pilot group and can walk around again.
]]
local AIRCRAFT_COLLISION_GROUP = "Aircraft"
local PILOT_COLLISION_GROUP = "Pilot"
local SEATED_COLLISION_GROUP = "PilotSeated"

-- =========================================================================
-- STATE
-- =========================================================================

export type Record = {
	model: Model,
	owner: Player?,
	id: string,
	slot: number,
	spawnedAt: number,
	violations: number,
}

--[[
	Keyed by model rather than by player, for two reasons: an aircraft may exist
	with no owner (the test suite spawns them that way, and scenery aircraft
	later will too), and destroying one is then a single table lookup from the
	thing that was destroyed. Owner lookup scans, which is free at these counts.
]]
local active: { [Model]: Record } = {}

-- Occupied spawn slots. Freed on despawn so a long session does not march the
-- parking apron off to infinity.
local usedSlots: { [number]: boolean } = {}

local container: Folder? = nil
local connections: { RBXScriptConnection } = {}
local sanityAccumulator = 0
local initialised = false

local function log(message: string, ...)
	if Constants.DEBUG.ENABLED then
		print("[FlightSim:Aircraft] " .. string.format(message, ...))
	end
end

-- =========================================================================
-- COLLISION GROUPS
-- =========================================================================

-- Idempotent: registering a group that already exists throws, and Init may run
-- more than once across a Studio session.
local function ensureCollisionGroup(name: string)
	for _, group in PhysicsService:GetRegisteredCollisionGroups() do
		if group.name == name then
			return
		end
	end
	PhysicsService:RegisterCollisionGroup(name)
end

local function setupCollisionGroups()
	ensureCollisionGroup(AIRCRAFT_COLLISION_GROUP)
	ensureCollisionGroup(PILOT_COLLISION_GROUP)
	ensureCollisionGroup(SEATED_COLLISION_GROUP)

	PhysicsService:CollisionGroupSetCollidable(AIRCRAFT_COLLISION_GROUP, PILOT_COLLISION_GROUP, false)

	-- A seated pilot collides with NOTHING, including the group they are in -
	-- two pilots in a future two-seater must not push on each other either.
	for _, group in PhysicsService:GetRegisteredCollisionGroups() do
		PhysicsService:CollisionGroupSetCollidable(SEATED_COLLISION_GROUP, group.name, false)
	end
end

local function assignCollisionGroup(root: Instance, group: string)
	if root:IsA("BasePart") then
		root.CollisionGroup = group
	end
	for _, part in root:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = group
		end
	end
end

--[[
	Which group a character's parts belong in right now.

	Recorded on the character rather than in a table so that the DescendantAdded
	handler below can read it without a closure over mutable state, and so it is
	visible in the explorer when something looks wrong.
]]
local GROUP_ATTRIBUTE = "FlightSimCollisionGroup"

local function setCharacterSeated(character: Model, seated: boolean)
	local group = if seated then SEATED_COLLISION_GROUP else PILOT_COLLISION_GROUP
	character:SetAttribute(GROUP_ATTRIBUTE, group)
	assignCollisionGroup(character, group)

	--[[
		Massless while seated, for the same reason the client does it: a seated
		character welds into the assembly and moves its centre of mass, and the
		flight model caches every moment arm from that point at spawn. Measured
		at 1,122 kg seated against the 1,111 kg the aircraft was designed and
		tested at. The client already does this locally; doing it on the server
		too keeps both views of the aeroplane agreeing about what it weighs.
	]]
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			part.Massless = seated
		end
	end
end

--[[
	Put a character into the pilot group and keep it there.

	The DescendantAdded connection is not belt-and-braces. A character is not
	finished when CharacterAdded fires: accessories, and on R15 some limbs,
	arrive over the following frames, and every one of them defaults to the
	Default group. One stray collidable hat is enough to shove an aeroplane.

	This arguably belongs to a PlayerService, which does not exist. When one
	does, move it there - AircraftService is only doing it because it is the
	system that suffers when nobody does.
]]
local function trackCharacter(character: Model)
	setCharacterSeated(character, false)

	character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			local group = character:GetAttribute(GROUP_ATTRIBUTE)
			descendant.CollisionGroup = if type(group) == "string" then group else PILOT_COLLISION_GROUP
		end
	end)
end

local function trackPlayer(player: Player)
	if player.Character then
		trackCharacter(player.Character)
	end
	player.CharacterAdded:Connect(trackCharacter)
end

-- =========================================================================
-- PLACEMENT
-- =========================================================================

local function getContainer(): Folder
	if container and container.Parent then
		return container
	end

	local existing = Workspace:FindFirstChild(CONTAINER_NAME)
	if existing and existing:IsA("Folder") then
		container = existing
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = CONTAINER_NAME
	folder.Parent = Workspace
	container = folder
	return folder
end

--[[
	Slot 0 sits on the origin; the rest alternate right and left of it, so a
	handful of aircraft stay clustered around the spawn point instead of
	trailing off in one direction.
]]
local function slotCFrame(slot: number): CFrame
	if slot == 0 then
		return SPAWN_ORIGIN
	end

	local step = math.ceil(slot / 2)
	local side = if slot % 2 == 1 then 1 else -1
	return SPAWN_ORIGIN * CFrame.new(side * step * SPAWN_SPACING, 0, 0)
end

--[[
	Is anything already parked here?

	Checked against the WORLD rather than only against our own bookkeeping,
	because our bookkeeping is not the only thing that spawns aircraft. Studio's
	command bar keeps a module cache separate from the running server's, so a
	developer calling require(AircraftService) from the command bar gets a
	second copy of this service with an empty usedSlots table - and its first
	spawn would land precisely on top of a live player's aeroplane. Roblox does
	not resolve that overlap gently.

	Half the spacing is the threshold: far enough that a 11 m wingspan clears,
	close enough that an aircraft parked slightly off-slot still counts.
]]
local function slotIsClear(slot: number): boolean
	local position = slotCFrame(slot).Position
	local threshold = SPAWN_SPACING * 0.5

	for _, model in getContainer():GetChildren() do
		if model:IsA("Model") and model.PrimaryPart then
			if (model.PrimaryPart.Position - position).Magnitude < threshold then
				return false
			end
		end
	end

	return true
end

-- Lowest free slot, so a player who despawns and respawns lands back on the
-- same patch of apron rather than drifting one space further out each time.
local function claimSlot(): number
	local slot = 0
	while usedSlots[slot] or not slotIsClear(slot) do
		slot += 1
	end
	usedSlots[slot] = true
	return slot
end

-- =========================================================================
-- QUERIES
-- =========================================================================

function AircraftService.getAircraft(player: Player): Model?
	for model, record in active do
		if record.owner == player then
			return model
		end
	end
	return nil
end

function AircraftService.getRecord(model: Model): Record?
	return active[model]
end

function AircraftService.list(): { Record }
	local records = {}
	for _, record in active do
		table.insert(records, record)
	end
	return records
end

-- =========================================================================
-- BOARDING
-- =========================================================================

--[[
	Boarding is a prompt, not a touch, and it is created here rather than on the
	client for the obvious reason: the client cannot make other players' seats
	work, and a prompt that exists on one machine is not a boarding mechanism.

	The touch route is not merely inferior, it is unavailable. Roblox seats
	trigger on the character touching them, and at 1 stud = 1 m a 5.7 m
	character cannot touch a 0.55 m seat buried in a 1.5 m cabin - the root part
	passes nearly a metre above it. Sit() sidesteps the geometry entirely.
]]
local function attachBoardPrompt(model: Model, definition: any, owner: Player?)
	local seat = model:FindFirstChild("PilotSeat")
	if not (seat and seat:IsA("VehicleSeat")) then
		return
	end

	--[[
		Move the occupant in and out of the seated collision group.

		This is server-side because the group assignment has to hold on every
		machine - the aircraft's simulation happens on the pilot's client, but
		the character is a replicated instance and a collision group set only
		locally would not be what other clients, or the server, simulate.

		The previous occupant is remembered because the Occupant property has
		already been cleared by the time we hear that somebody stood up, and
		leaving them in the seated group would let them walk through the world.
	]]
	local seatedCharacter: Model? = nil

	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occupant = seat.Occupant

		if occupant then
			local character = occupant.Parent
			if character and character:IsA("Model") then
				seatedCharacter = character
				setCharacterSeated(character, true)
			end
		elseif seatedCharacter then
			-- Guard against a character destroyed while seated (a crash death).
			if seatedCharacter.Parent then
				setCharacterSeated(seatedCharacter, false)
			end
			seatedCharacter = nil
		end
	end)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "BoardPrompt"
	prompt.ActionText = "Board"
	prompt.ObjectText = definition.name
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = seat

	prompt.Triggered:Connect(function(player)
		--[[
			Only the owner may board, when there is one.

			Not a rule about politeness: the aircraft's network ownership is
			pinned to its owner, so a second player sitting in it would be
			sitting in an assembly simulated on somebody else's machine, with
			their own client's FlightController writing forces that the engine
			discards. It would look like an aircraft that ignores the controls.
		]]
		local record = active[model]
		if record and record.owner and record.owner ~= player then
			return
		end

		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			seat:Sit(humanoid)
		end
	end)
end

-- =========================================================================
-- SPAWN / DESPAWN
-- =========================================================================

--[[
	Build an aircraft and, if it has an owner, hand simulation of it to them.

	Returns (model, nil) on success or (nil, message) on failure. It returns a
	message rather than erroring because every caller is either a remote handler
	relaying the reason to a client, or a test.

	An owner who already has an aircraft gets their old one removed first. That
	makes RequestSpawnAircraft double as "reset my aircraft", which is what a
	pilot wants after putting one on its back, and it enforces one-per-player
	without a second code path.
]]
function AircraftService.spawn(owner: Player?, aircraftId: string?): (Model?, string?)
	local id = aircraftId or Registry.DEFAULT_ID
	local definition = Registry.get(id)

	if not definition then
		return nil, string.format("unknown aircraft id '%s' (known: %s)", tostring(id), table.concat(Registry.ids(), ", "))
	end

	if owner then
		local existing = AircraftService.getAircraft(owner)
		if existing then
			AircraftService.despawn(existing)
		end
	end

	local slot = claimSlot()

	--[[
		build() hard-errors on an impossible definition - a part that cannot
		reach its stated mass, a missing root. That is correct behaviour for a
		developer running the builder, but here it would take the remote handler
		down with it and leave the slot claimed forever, so it is caught.
	]]
	local ok, result = pcall(function()
		return AircraftBuilder.build(definition, slotCFrame(slot), getContainer())
	end)

	if not ok then
		usedSlots[slot] = nil
		return nil, string.format("build failed: %s", tostring(result))
	end

	local model = result :: Model

	-- Before anything can touch it. See AIRCRAFT_COLLISION_GROUP above for what
	-- happens to an aeroplane a pilot is allowed to collide with.
	assignCollisionGroup(model, AIRCRAFT_COLLISION_GROUP)

	if owner then
		model.Name = string.format("%s_%s", definition.id, owner.Name)
		model:SetAttribute("OwnerUserId", owner.UserId)
	end

	attachBoardPrompt(model, definition, owner)

	active[model] = {
		model = model,
		owner = owner,
		id = definition.id,
		slot = slot,
		spawnedAt = os.clock(),
		violations = 0,
	}

	--[[
		Hand over simulation. This is the line that makes the client's flight
		model do anything at all.

		pcall because SetNetworkOwner throws if the assembly is anchored or the
		player has already left - both survivable, and both far better reported
		than crashing the spawn. If it fails the aircraft still exists, it is
		just server-simulated and will not respond to the controls, so the
		warning says so.
	]]
	local root = model.PrimaryPart
	if owner and root then
		local ownershipOk, ownershipErr = pcall(function()
			root:SetNetworkOwner(owner)
		end)

		--[[
			Verified here, on the server, and nowhere else.

			The obvious place for this check is the client, just before it starts
			writing forces - but BasePart:IsNetworkOwner() does not exist on the
			client in this Studio version (confirmed: "IsNetworkOwner is not a
			valid member of Part"), so a client-side check is dead code that
			silently never fires. GetNetworkOwner() is server-side and real, so
			the assertion lives where it actually works.

			Worth stating the failure mode plainly, because it is silent and
			looks like something else entirely: forces written to an assembly
			this client does not own are discarded by the engine with no error
			and no motion, which from the cockpit is indistinguishable from
			broken aerodynamics.
		]]
		if not ownershipOk then
			warn(string.format(
				"[FlightSim:Aircraft] could not give %s ownership of %s: %s - it will not respond to controls",
				owner.Name, model.Name, tostring(ownershipErr)
			))
		elseif root:GetNetworkOwner() ~= owner then
			warn(string.format(
				"[FlightSim:Aircraft] %s did not take ownership of %s - it will not respond to controls",
				owner.Name, model.Name
			))
		end
	end

	--[[
		Told last, and only once everything above has happened. See the header:
		AircraftAssigned means "yours, and you own it".
	]]
	if owner then
		Remotes.Get("AircraftAssigned"):FireClient(owner, model)
	end

	log("Spawned %s (%s) at slot %d for %s", definition.name, definition.id, slot, owner and owner.Name or "nobody")

	return model, nil
end

function AircraftService.despawn(model: Model): boolean
	local record = active[model]
	if not record then
		return false
	end

	active[model] = nil
	usedSlots[record.slot] = nil

	log("Despawned %s (slot %d)", model.Name, record.slot)
	model:Destroy()

	return true
end

function AircraftService.despawnFor(player: Player): boolean
	local model = AircraftService.getAircraft(player)
	if model then
		return AircraftService.despawn(model)
	end
	return false
end

function AircraftService.despawnAll(): number
	local count = 0
	for model in active do
		if AircraftService.despawn(model) then
			count += 1
		end
	end
	return count
end

-- =========================================================================
-- SANITY
-- =========================================================================

--[[
	Is this position and speed physically possible? Returns a reason, or nil.

	Pure, and split out from checkSanity so the thresholds can be tested by
	passing numbers rather than by trying to force an aircraft into each state.
	That is not a stylistic preference - see the NaN note below, where the
	datamodel flatly refuses to hold the value under test.

	NaN is checked first and explicitly. It is the one value that fails every
	comparison, so a naive range check reports an aircraft at NaN as perfectly
	healthy, which is the exact opposite of the truth.
]]
function AircraftService.evaluate(position: Vector3, speed: number): string?
	if position ~= position or speed ~= speed then
		return "position or velocity is NaN"
	end

	local limits = Constants.LIMITS

	if position.Y > limits.MAX_ALTITUDE_M then
		return string.format("altitude %.0f m above the %.0f m limit", position.Y, limits.MAX_ALTITUDE_M)
	end
	if position.Y < limits.MIN_ALTITUDE_M then
		return string.format("altitude %.0f m below the %.0f m floor", position.Y, limits.MIN_ALTITUDE_M)
	end
	if speed > limits.MAX_SPEED_MS then
		return string.format("speed %.0f m/s above the %.0f m/s limit", speed, limits.MAX_SPEED_MS)
	end

	return nil
end

--[[
	The same question asked of a live aircraft.

	Worth knowing, and verified in Studio rather than assumed: ROBLOX SANITISES
	NaN ON ASSIGNMENT. Writing a NaN velocity to a part stores (0, 0, 0), and a
	NaN CFrame position stores y = -1,000,000. So the datamodel can never hand
	this function a NaN in the first place - and the -1,000,000 lands far below
	MIN_ALTITUDE_M, which means the floor check is what actually catches a
	position that has gone numerically bad. The NaN branch in evaluate() stays
	regardless, because it costs one comparison and it is the correct guard for
	numbers that have not been through a Roblox property setter.
]]
function AircraftService.checkSanity(model: Model): string?
	local root = model.PrimaryPart
	if not root then
		return "no PrimaryPart"
	end

	return AircraftService.evaluate(root.Position, root.AssemblyLinearVelocity.Magnitude)
end

local function runSanityPass()
	for model, record in active do
		if not model.Parent then
			-- Destroyed by something other than despawn(). Reap the record so
			-- the slot is released and the loop stops visiting a dead model.
			active[model] = nil
			usedSlots[record.slot] = nil
			continue
		end

		local reason = AircraftService.checkSanity(model)
		if reason then
			record.violations += 1

			-- Only the first is worth reading; an aircraft stuck out of bounds
			-- would otherwise fill the output every two seconds forever.
			if record.violations == 1 then
				warn(string.format(
					"[FlightSim:Aircraft] %s (%s) is out of bounds: %s",
					model.Name, record.owner and record.owner.Name or "unowned", reason
				))
			end

			if ENFORCE_LIMITS then
				AircraftService.despawn(model)
			end
		elseif record.violations > 0 then
			record.violations = 0
		end
	end
end

-- =========================================================================
-- INIT
-- =========================================================================

function AircraftService.Init()
	if initialised then
		return
	end
	initialised = true

	getContainer()
	setupCollisionGroups()

	-- Existing players first: in Studio's Play Solo the local player can be
	-- present before this service starts, and PlayerAdded would never fire.
	for _, player in Players:GetPlayers() do
		trackPlayer(player)
	end
	table.insert(connections, Players.PlayerAdded:Connect(trackPlayer))

	--[[
		Validate every registered definition once, now, at server start.

		build() validates too, but that is at the moment a player asks for one -
		by which point a bad definition is a failed spawn for somebody rather
		than a line in the server log. Definitions do not change at runtime, so
		checking them all up front costs nothing and moves the failure to where
		a developer will actually see it.
	]]
	for _, id in Registry.ids() do
		local ok, problems = AircraftBuilder.validate(Registry.get(id))
		if not ok then
			warn(string.format("[FlightSim:Aircraft] definition '%s' is invalid:\n  %s", id, table.concat(problems, "\n  ")))
		end
	end

	local requestSpawn = Remotes.Get("RequestSpawnAircraft")
	requestSpawn.OnServerInvoke = function(player: Player, aircraftId: any)
		--[[
			The id is whatever the client sent, so it is treated as untrusted
			text. Registry.get returns nil for anything that is not a known id,
			including a table, a function, or a 4 MB string, and spawn() turns
			that into a message.
		]]
		local model, message = AircraftService.spawn(player, if type(aircraftId) == "string" then aircraftId else nil)
		if not model then
			warn(string.format("[FlightSim:Aircraft] spawn refused for %s: %s", player.Name, tostring(message)))
			return false, message
		end
		return true, nil
	end

	table.insert(connections, Remotes.Get("RequestDespawnAircraft").OnServerEvent:Connect(function(player)
		AircraftService.despawnFor(player)
	end))

	-- A player leaving must take their aircraft with them, or the apron fills
	-- with abandoned aeroplanes holding their spawn slots.
	table.insert(connections, Players.PlayerRemoving:Connect(function(player)
		AircraftService.despawnFor(player)
	end))

	table.insert(connections, RunService.Heartbeat:Connect(function(dt)
		sanityAccumulator += dt
		if sanityAccumulator >= SANITY_PERIOD then
			sanityAccumulator = 0
			runSanityPass()
		end
	end))

	log("Ready - %d aircraft type(s): %s", #Registry.ids(), table.concat(Registry.ids(), ", "))
end

function AircraftService.Shutdown()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	AircraftService.despawnAll()
	initialised = false
end

-- =========================================================================
-- VERIFICATION
-- =========================================================================

--[[
	Run from the Studio command bar, SERVER datamodel:
		require(game.ServerScriptService.FlightSim.Services.AircraftService).runTests()

	What is covered: placement, the registry, slot allocation and reuse,
	one-aircraft-per-owner, teardown, and the sanity thresholds.

	What is not: network ownership and the remote handlers, both of which need a
	real Player. SetNetworkOwner cannot be called with a fake one and there is
	no way to fabricate a Player instance. Those are verified by flying - if the
	aircraft responds to the controls, the client owns it, because that is the
	only circumstance in which it can.
]]
function AircraftService.runTests(): (boolean, { any })
	local results = {}
	local allPassed = true

	local function record(label: string, passed: boolean, detail: string)
		if not passed then
			allPassed = false
		end
		table.insert(results, { label = label, passed = passed, detail = detail })
		print(string.format("  [%s] %-50s %s", passed and "PASS" or "FAIL", label, detail))
	end

	print("=== AircraftService: verification ===")

	-- Preserve whatever is already flying: this may be run on a live server.
	local preexisting: { [Model]: Record } = table.clone(active)

	--[[
		Everything below runs inside a pcall.

		An error mid-suite would otherwise leak 1,100 kg aircraft into the
		workspace, and in Studio that debris survives into the next Play session
		where it looks exactly like a double-spawn bug. It has cost real time
		once already.
	]]
	local spawned: { Model } = {}

	--[[
		Registered here as well as in Init(), because Studio's command bar keeps
		a module cache separate from the running server's: require() from the
		command bar yields a second copy of this service whose Init() has never
		run. Without this, spawn() would be assigning parts to a group that does
		not exist in that copy's world.
	]]
	setupCollisionGroups()

	local body = function()

	-- 1. Registry -----------------------------------------------------------
	record(
		"Registry knows the default aircraft",
		Registry.get(Registry.DEFAULT_ID) ~= nil,
		string.format("%d type(s): %s", #Registry.ids(), table.concat(Registry.ids(), ", "))
	)

	local bogus, bogusMessage = AircraftService.spawn(nil, "spitfire")
	record(
		"An unknown id is refused with a message",
		bogus == nil and type(bogusMessage) == "string",
		tostring(bogusMessage)
	)

	-- 2. Spawn --------------------------------------------------------------
	local a, aErr = AircraftService.spawn(nil)
	if a then
		table.insert(spawned, a)
	end
	record("Spawns an aircraft", a ~= nil, a and a.Name or tostring(aErr))
	assert(a, "cannot continue without an aircraft")

	record(
		"Parented into the Aircraft container",
		a.Parent == getContainer(),
		a.Parent and a.Parent:GetFullName() or "nil"
	)

	record(
		"Registered as active",
		active[a] ~= nil and #AircraftService.list() >= 1,
		string.format("%d active", #AircraftService.list())
	)

	-- 3. The model is actually flyable --------------------------------------
	local measurement = AircraftBuilder.measure(a)
	record(
		"Built as ONE assembly",
		measurement.assemblyCount == 1,
		string.format("%d assembly/assemblies, %.0f kg", measurement.assemblyCount, measurement.mass)
	)

	local root = a.PrimaryPart :: BasePart
	record(
		"Has the force constraints the flight model drives",
		root:FindFirstChild("AeroForce") ~= nil and root:FindFirstChild("AeroTorque") ~= nil,
		"AeroForce + AeroTorque"
	)

	--[[
		Anchored parts cannot be network-owned and cannot move. This is checked
		because it is the single cheapest way to turn the whole simulator into a
		statue, and nothing else would report it.
	]]
	local anchoredCount = 0
	for _, part in a:GetDescendants() do
		if part:IsA("BasePart") and part.Anchored then
			anchoredCount += 1
		end
	end
	record("Nothing is anchored", anchoredCount == 0, string.format("%d anchored parts", anchoredCount))

	--[[
		Collision groups. One part left in the Default group is all it takes -
		the pilot's character catches on it while boarding and throws the
		aeroplane, which is precisely the failure this was added to stop.
	]]
	local wrongGroup = 0
	for _, part in a:GetDescendants() do
		if part:IsA("BasePart") and part.CollisionGroup ~= AIRCRAFT_COLLISION_GROUP then
			wrongGroup += 1
		end
	end
	record(
		"Every part is in the Aircraft collision group",
		wrongGroup == 0,
		string.format("%d part(s) outside '%s'", wrongGroup, AIRCRAFT_COLLISION_GROUP)
	)

	record(
		"Pilots and aircraft cannot collide",
		not PhysicsService:CollisionGroupsAreCollidable(AIRCRAFT_COLLISION_GROUP, PILOT_COLLISION_GROUP),
		"Aircraft vs Pilot: non-collidable"
	)

	record(
		"Aircraft still collide with the world",
		PhysicsService:CollisionGroupsAreCollidable(AIRCRAFT_COLLISION_GROUP, "Default"),
		"Aircraft vs Default: collidable (the runway has to work)"
	)

	-- 4. Parked on the ground, not falling or embedded ----------------------
	record(
		"Parks on the ground rather than spawning airborne",
		math.abs(root.Position.Y - SPAWN_ORIGIN.Position.Y) < 0.01,
		string.format("y = %.3f m", root.Position.Y)
	)

	-- 5. Boarding -----------------------------------------------------------
	local seat = a:FindFirstChild("PilotSeat")
	record(
		"Has a board prompt on the pilot seat",
		seat ~= nil and seat:FindFirstChild("BoardPrompt") ~= nil,
		seat and "BoardPrompt present" or "no PilotSeat"
	)

	-- 6. Slots --------------------------------------------------------------
	local b = AircraftService.spawn(nil)
	if b then
		table.insert(spawned, b)
	end
	assert(b, "second spawn failed")

	local separation = (b.PrimaryPart :: BasePart).Position - root.Position
	record(
		"A second aircraft is parked clear of the first",
		math.abs(separation.X) >= SPAWN_SPACING - 0.01,
		string.format("%.1f m apart (spacing %d m)", separation.Magnitude, SPAWN_SPACING)
	)

	local slotA = (active[a] :: Record).slot
	local slotB = (active[b] :: Record).slot
	record("Slots are distinct", slotA ~= slotB, string.format("slot %d and slot %d", slotA, slotB))

	-- 7. Despawn ------------------------------------------------------------
	local despawned = AircraftService.despawn(a)
	record(
		"Despawn removes the model and deregisters it",
		despawned and a.Parent == nil and active[a] == nil,
		"gone"
	)

	local c = AircraftService.spawn(nil)
	if c then
		table.insert(spawned, c)
	end
	assert(c, "third spawn failed")
	record(
		"A freed slot is reused rather than drifting outward",
		(active[c] :: Record).slot == slotA,
		string.format("reclaimed slot %d", (active[c] :: Record).slot)
	)

	record(
		"Despawning an aircraft twice is a no-op, not an error",
		AircraftService.despawn(a) == false,
		"returned false"
	)

	-- 8. Sanity thresholds --------------------------------------------------
	record(
		"A parked aircraft is within limits",
		AircraftService.checkSanity(c) == nil,
		"no violation"
	)

	local cRoot = c.PrimaryPart :: BasePart
	local parked = cRoot.CFrame

	c:PivotTo(CFrame.new(0, Constants.LIMITS.MAX_ALTITUDE_M + 5000, 0))
	record(
		"Excessive altitude is flagged",
		AircraftService.checkSanity(c) ~= nil,
		tostring(AircraftService.checkSanity(c))
	)

	c:PivotTo(CFrame.new(0, Constants.LIMITS.MIN_ALTITUDE_M - 100, 0))
	record(
		"Flying below the floor is flagged",
		AircraftService.checkSanity(c) ~= nil,
		tostring(AircraftService.checkSanity(c))
	)

	c:PivotTo(parked)
	cRoot.AssemblyLinearVelocity = Vector3.new(Constants.LIMITS.MAX_SPEED_MS * 2, 0, 0)
	record(
		"Excessive speed is flagged",
		AircraftService.checkSanity(c) ~= nil,
		tostring(AircraftService.checkSanity(c))
	)
	cRoot.AssemblyLinearVelocity = Vector3.zero

	record(
		"Back within limits once returned",
		AircraftService.checkSanity(c) == nil,
		"no violation"
	)

	--[[
		NaN goes through evaluate() directly, and it has to.

		The obvious test - assign a NaN velocity to the aircraft and ask - was
		written first and failed, for a reason worth recording: Roblox sanitises
		NaN inside the property setter. A NaN velocity is stored as (0, 0, 0)
		and a NaN position as y = -1,000,000, so the datamodel cannot be made to
		hold the value under test. Asserting through the model would only ever
		have proved that Roblox scrubs NaN, not that we catch it.
	]]
	local nan = 0 / 0
	record(
		"NaN velocity is flagged",
		AircraftService.evaluate(Vector3.new(0, 100, 0), nan) ~= nil,
		tostring(AircraftService.evaluate(Vector3.new(0, 100, 0), nan))
	)
	record(
		"NaN position is flagged",
		AircraftService.evaluate(Vector3.new(nan, nan, nan), 0) ~= nil,
		tostring(AircraftService.evaluate(Vector3.new(nan, nan, nan), 0))
	)
	record(
		"A sanitised NaN position still trips the floor",
		AircraftService.evaluate(Vector3.new(0, -1000000, 0), 0) ~= nil,
		"Roblox stores NaN positions as y = -1,000,000"
	)

	-- 9. Ownership bookkeeping ----------------------------------------------
	-- No Player to test against, so this checks the query does not invent one.
	record(
		"Unowned aircraft belong to no player",
		(active[c] :: Record).owner == nil,
		"owner = nil"
	)

	end

	local ok, err = pcall(body)

	-- Cleanup, whatever happened.
	for _, model in spawned do
		AircraftService.despawn(model)
		if model.Parent then
			model:Destroy()
		end
	end

	if not ok then
		allPassed = false
		record("Suite completed without erroring", false, tostring(err))
	end

	--[[
		The suite must leave the server exactly as it found it. Counting rather
		than comparing tables, and counting what was there BEFORE, so this is
		still meaningful when run on a live server with aircraft already flying.
	]]
	local before = 0
	for _ in preexisting do
		before += 1
	end
	record(
		"Cleanup left nothing behind",
		#AircraftService.list() == before,
		string.format("%d active, %d before the suite", #AircraftService.list(), before)
	)

	local passCount = 0
	for _, r in results do
		if r.passed then
			passCount += 1
		end
	end
	print(string.format("=== %s (%d/%d) ===", allPassed and "ALL PASSED" or "FAILURES PRESENT", passCount, #results))

	return allPassed, results
end

return AircraftService
