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

--[[
	A sibling service, required directly rather than looked up at Init time.

	Safe in either start order: everything this module asks AirportService is a
	pure function of its constants and works the moment it is required. Only the
	airport's GEOMETRY needs Init(), and nothing here needs the geometry.
]]
local AirportService = require(script.Parent:WaitForChild("AirportService"))

local AircraftService = {}

-- =========================================================================
-- CONFIGURATION
-- =========================================================================

-- Every spawned aircraft lives here, so workspace stays readable and anything
-- that needs to iterate aircraft has one obvious place to look.
local CONTAINER_NAME = "Aircraft"

--[[
	How high an aircraft's origin sits when its tyres are resting on the ground.

	Spawning higher means the aircraft free-falls before anyone reaches it;
	spawning lower means Roblox resolves the interpenetration by launching it.
	This is a fact about the aircraft's gear geometry, which is why it lives
	here with the aircraft rather than with the tarmac.

	⚠️ THIS WAS THE HARDCODED 1.30 THAT §45 BROKE, AND IT IS WHY THE AEROPLANE
	FELL THROUGH THE MAP.

	1.30 was correct while the wheels sat 0.95 below the datum with a 0.2
	radius. §45 scaled the gear to 1.778 and 0.374, putting the tyres 2.302 m
	below the root - so a root spawned only 1.30 m up left every wheel 1.0 m
	UNDERNEATH the apron. The comment above had already predicted exactly what
	happens next, and it happened: Roblox resolved a metre of interpenetration
	against a 1,111 kg assembly the only way it can.

	The three test rigs were fixed to derive this and this one was missed,
	because it is the only copy on the LIVE spawn path rather than in a suite -
	so every check still passed while the game itself was broken.

	Derived now, from the same geometry the wheels are built from.

	WHERE aircraft park is AirportService's answer, not this module's. They sit
	on the apron, facing runway 36.
]]
local function gearHeightOf(definition: any): number
	local rootSpec
	for _, p in definition.model.parts do
		if p.name == definition.model.rootPart then
			rootSpec = p
		end
	end
	assert(rootSpec, "definition has no root part")

	-- The LOWEST wheel, not the first: a taildragger's geometry is not the
	-- 172's, and the aeroplane rests on whichever tyre reaches furthest down.
	local lowest = math.huge
	for _, w in definition.gear.wheels do
		lowest = math.min(lowest, w.offset.Y - w.radius)
	end
	return rootSpec.position.Y - lowest
end

--[[
	Lateral spacing between parked aircraft, in metres.

	Two aircraft spawned into the same space do not politely overlap - Roblox
	resolves the penetration explosively, and the first thing either pilot sees
	is their aeroplane cartwheeling.

	⚠️ ALSO BROKEN BY §45, AND FOR THE SAME REASON. This was 18 m, reasoned as
	"the 172's span is 11.0 m, so 18 m leaves a comfortable 7 m between
	wingtips". §45 draws the span at 20.59 m, so 18 m of spacing had the
	wingtips OVERLAPPING by 2.6 m - the explosive case the paragraph above
	describes, waiting for a second player.

	Derived from the drawn span, keeping the original 18/11 proportion so the
	gap between wingtips stays comfortable at any scale.
]]
local WINGTIP_CLEARANCE_FACTOR = 18 / 11 -- the original 172 figures

local function spanOf(definition: any): number
	local minX, maxX = math.huge, -math.huge
	for _, s in definition.model.decorations do
		minX = math.min(minX, s.position.X - s.size.X / 2)
		maxX = math.max(maxX, s.position.X + s.size.X / 2)
	end
	return maxX - minX
end

--[[
	⚠️ TAKEN FROM THE DEFAULT AIRCRAFT, NOT PER-DEFINITION, AND THAT IS A LIMIT.

	The apron slot layout has to be one fixed grid - `slotIsClear` asks whether
	a patch of tarmac is free before it knows what is going to park on it - so
	the spacing cannot depend on the aeroplane being spawned. The 172 is the
	only aircraft, so this is faithful today.

	When a second aircraft with a different span or different gear arrives, both
	of these become properties the SLOT carries rather than module constants, and
	the grid is sized to the largest. Flagged rather than pre-built.
]]
local DEFAULT_DEFINITION = Registry.get(Registry.DEFAULT_ID)
local SPAWN_HEIGHT = gearHeightOf(DEFAULT_DEFINITION)
local SPAWN_SPACING = spanOf(DEFAULT_DEFINITION) * WINGTIP_CLEARANCE_FACTOR

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
	airport: string,
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

--[[
	Occupied spawn slots, PER AIRPORT. Freed on despawn so a long session does
	not march the parking off to infinity.

	Nested by airport id because slot 0 exists at every field: a flat table would
	have let Meadow's first aircraft block Ridge's, and the aeroplane would have
	parked one space further out at a field with nothing on it.
]]
local usedSlots: { [string]: { [number]: boolean } } = {}

local function slotsFor(airportId: string): { [number]: boolean }
	local t = usedSlots[airportId]
	if not t then
		t = {}
		usedSlots[airportId] = t
	end
	return t
end

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
	Where slot N parks, on the airport's apron.

	The layout belongs to AirportService - it owns where the tarmac is - and the
	SPACING belongs here, because it is derived from the aircraft's 11 m span
	rather than from the apron. This module adds the gear height on top of the
	surface CFrame it is given.

	AirportService answers this from constants and needs no Init() to do it,
	which is what makes the call safe: Init.server.luau starts services in
	whatever order Services:GetChildren() returns, so this may well run before
	the airport's geometry exists. The numbers are right either way.
]]
local function slotCFrame(airportId: string, slot: number): CFrame
	local surface = AirportService.apronSlotCFrame(airportId, slot, SPAWN_SPACING)
	return surface * CFrame.new(0, SPAWN_HEIGHT, 0)
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
local function slotIsClear(airportId: string, slot: number): boolean
	local position = slotCFrame(airportId, slot).Position
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
local function claimSlot(airportId: string): number
	local slots = slotsFor(airportId)
	local slot = 0
	while slots[slot] or not slotIsClear(airportId, slot) do
		slot += 1
	end
	slots[slot] = true
	return slot
end

--[[
	Which field a player spawns at: the NEAREST one.

	Decided by the pilot and recorded in §0 - there is deliberately no chooser,
	and the destination picker is the Phase 4b tablet's job. The useful property
	is that flying to Ridge, landing, and pressing reset keeps you at Ridge
	rather than teleporting you home.

	Measured from the player's CHARACTER, not from their aircraft: an aircraft
	is about to be replaced when this is called, and after a crash there may not
	be one at all. With no character - a request that arrives before the player
	has spawned - the primary field is the honest default rather than a guess.
]]
local function airportFor(owner: Player?): string
	local character = owner and owner.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	if root and root:IsA("BasePart") then
		return AirportService.nearestAirport(root.Position)
	end

	return AirportService.PRIMARY_ID
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

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "BoardPrompt"
	prompt.ActionText = "Board"
	prompt.ObjectText = definition.name
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = seat

	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occupant = seat.Occupant

		--[[
			Hide the prompt while somebody is aboard.

			Reported from the Phase 1 gate: "Board" stayed on screen for the whole
			flight. It was never actionable - the seat is taken, and Sit() on an
			occupied seat does nothing - so this is cosmetic, but it is cosmetic in
			the middle of the windscreen for the entire flight.

			Set from `occupant` directly rather than inside the branches below,
			and that is the point of it being its own line. The bookkeeping under
			it is about the PREVIOUS occupant and has a nil-seatedCharacter path
			that does nothing; hanging the re-enable off that path would leave the
			prompt hidden forever on any route through it - a crash death being
			the obvious one. Enabled is a plain function of who is sitting there
			now, so it cannot drift out of step with reality.

			Server-side, so it replicates: every player stops seeing the prompt on
			an occupied aeroplane, not just the pilot.
		]]
		prompt.Enabled = occupant == nil

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

	WHERE IT PARKS, AND THE THIRD ARGUMENT (Phase 4b)
	-------------------------------------------------
	`airportId` is optional and normally omitted, in which case the aeroplane
	appears at the field NEAREST the player - the rule §24 settled and the one
	every existing caller relies on. The tablet is the first caller with an
	opinion: a flight plan names its own departure field, and a pilot who plans
	Ridge to Meadow expects to start at Ridge rather than wherever they happen to
	be standing.

	An unknown id falls back to the nearest field rather than erroring. That is
	deliberate: this argument arrives from a remote, and the honest failure for
	"park me at somewhere that does not exist" is to park the pilot somewhere
	that does. StartFlight validates the field for real before it ever gets here,
	so the fallback is a second line of defence rather than the only one.
]]
function AircraftService.spawn(owner: Player?, aircraftId: string?, departureId: string?): (Model?, string?)
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

	local airportId = if departureId and AirportService.getAirport(departureId) then departureId else airportFor(owner)
	local slot = claimSlot(airportId)

	--[[
		build() hard-errors on an impossible definition - a part that cannot
		reach its stated mass, a missing root. That is correct behaviour for a
		developer running the builder, but here it would take the remote handler
		down with it and leave the slot claimed forever, so it is caught.
	]]
	local ok, result = pcall(function()
		return AircraftBuilder.build(definition, slotCFrame(airportId, slot), getContainer())
	end)

	if not ok then
		slotsFor(airportId)[slot] = nil
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
		airport = airportId,
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
	slotsFor(record.airport)[record.slot] = nil

	log("Despawned %s (%s slot %d)", model.Name, record.airport, record.slot)
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
			slotsFor(record.airport)[record.slot] = nil
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
-- FLIGHT REQUESTS (Phase 4b)
-- =========================================================================

--[[
	How far to the aeroplane's LEFT the pilot is stood, in metres.

	6 m, which puts them under the wing beside the door - where you actually walk
	up to a 172. It has to clear the fuselage and it must not be so far that the
	pilot lands on the next slot: §45 draws the aeroplane at 1.872x, so the
	fuselage is about 1.9 m half-width and the parked slots are 25 m apart.
]]
local PILOT_STANDOFF = 6

--[[
	Stand the pilot beside their new aeroplane.

	⚠️ WITHOUT THIS THE TABLET IS A BROKEN FEATURE, and no unit test could have
	said so. Found by starting a real flight from Ridge while standing at Meadow:
	the aeroplane appeared correctly at Ridge, 1.6 km away, and the pilot was
	left on Meadow's apron with a 1.6 km walk to a board prompt they could not
	see. Worse than not seeing it - WORKSPACE STREAMING IS ON in this place, so
	the client held the model's shell with 0 of its 128 parts replicated, which
	from the apron is indistinguishable from the spawn having silently failed.

	So "start a flight from Ridge" moves the pilot to Ridge. That is what the
	words mean, and it is what §24's spawn-at-the-nearest-field rule already does
	for the ordinary case - this is the same rule, with the tablet choosing the
	field instead of the pilot's position.

	THE STANDING HEIGHT IS DERIVED FROM THE RIG, NOT FROM A RAYCAST, AND THE
	DIFFERENCE COST A DEAD PILOT.

	The first version measured it: raycast down from the character's root, and
	take root.Y minus the ground it found. That is the obvious approach and it is
	wrong here, because `groundHeightAt` excludes the Aircraft folder and NOTHING
	ELSE - including the character the ray is being fired out of. The ray starts
	at root + 1 m, which on this R6 rig is exactly the top of the torso, so it
	sometimes hits the pilot's OWN HEAD at 253.25 instead of the apron at 250.00.
	The standing height came out as -2.3 m, the pilot was placed 2.3 m INSIDE
	Ridge's terrain, fell through the world, died, and respawned at Meadow -
	taking their aeroplane with them (§7: dying requests a new one).

	The bounding box cannot make that mistake. It is the rig's own extent, so it
	stays correct through §34's R6 change and §36's 1.55 m scaling, and there is
	no ray to hit the wrong thing.

	Returns false when there is nothing to move, which is not an error: a player
	whose character has not loaded still gets their aeroplane.
]]
--[[
	WHERE the pilot stands, as a pure function of the aeroplane's CFrame.

	Split out from the moving for the same reason evaluate() is split from
	checkSanity(): there is no way to fabricate a Player, so the half with the
	arithmetic in it - which side is left, which way they face, how the height is
	built - has to be reachable without one. The impure half below is then three
	lookups and a PivotTo.

	`groundY` is the surface beside the aeroplane and `standingHeight` is how far
	the character's root sits above whatever it is standing on. Neither is
	assumed here, because both are facts about the world and the rig rather than
	about this arithmetic.
]]
function AircraftService.pilotStandingCFrame(aircraft: CFrame, groundY: number, standingHeight: number): CFrame
	-- The aeroplane's own left, so this works at any field on any heading -
	-- Ridge's runway runs east-west where Meadow's runs north-south, and a
	-- world-axis offset would put the pilot in front of the propeller at one of
	-- them.
	local beside = (aircraft * CFrame.new(-PILOT_STANDOFF, 0, 0)).Position
	local position = Vector3.new(beside.X, groundY + standingHeight, beside.Z)

	-- Facing the aeroplane, which is where a pilot walking up to it is looking.
	-- Levelled to the pilot's own height so they look AT it rather than up or
	-- down at its centre.
	return CFrame.lookAt(position, Vector3.new(aircraft.Position.X, position.Y, aircraft.Position.Z))
end

local function standPilotBeside(owner: Player?, model: Model): boolean
	local character = owner and owner.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local aircraftRoot = model.PrimaryPart

	if not character or not root or not root:IsA("BasePart") or not aircraftRoot then
		return false
	end

	--[[
		How far the root sits above the rig's own lowest point. See the note
		above for what measuring this with a raycast did instead.
	]]
	local boundsCFrame, boundsSize = character:GetBoundingBox()
	local standing = root.Position.Y - (boundsCFrame.Position.Y - boundsSize.Y / 2)

	--[[
		Probed from well above, because the ray has to start clear of the
		aeroplane it is standing next to. groundHeightAt already excludes the
		Aircraft folder, so this is belt and braces rather than the only guard.
	]]
	local beside = (aircraftRoot.CFrame * CFrame.new(-PILOT_STANDOFF, 0, 0)).Position
	local ground = AirportService.groundHeightAt(Vector3.new(beside.X, aircraftRoot.Position.Y + 50, beside.Z), 200)
		or aircraftRoot.Position.Y

	--[[
		PivotTo rather than writing the root's CFrame, so the whole rig moves as
		one instead of being dragged through its own joints.
	]]
	character:PivotTo(AircraftService.pilotStandingCFrame(aircraftRoot.CFrame, ground, standing))
	return true
end

--[[
	Is this flight plan flyable? Returns (true, accepted) or (false, nil, why).

	PURE, AND SPLIT OUT FOR THE SAME REASON evaluate() IS: the remote handler
	needs a real Player and a real spawn, and none of the interesting failures
	here involve either. Every refusal below can be driven with a plain table.

	The refusal messages are written to be READ BY THE PILOT, on the tablet,
	because that is where they end up. "unknown airport 'ridg'" tells them they
	mistyped; "the request was not a table" tells a developer their client is
	broken. Both are more use than a bare false.
]]
export type AcceptedFlight = {
	aircraftId: string,
	from: string,
	to: string,
	plan: any,
}

function AircraftService.evaluateFlightRequest(request: any): (boolean, AcceptedFlight?, string?)
	if type(request) ~= "table" then
		return false, nil, string.format("the request was not a table (got %s)", typeof(request))
	end

	--[[
		The aircraft. Omitted means the default, exactly as RequestSpawnAircraft
		treats it, so a tablet that has not drawn its aircraft picker yet still
		produces a flyable request.
	]]
	local aircraftId = if type(request.aircraftId) == "string" then request.aircraftId else Registry.DEFAULT_ID
	if not Registry.get(aircraftId) then
		return false, nil, string.format("unknown aircraft '%s' (known: %s)", tostring(aircraftId), table.concat(Registry.ids(), ", "))
	end

	local from = if type(request.from) == "string" then request.from else nil
	local to = if type(request.to) == "string" then request.to else nil

	if not from or not AirportService.getAirport(from) then
		return false, nil, string.format("unknown departure airport '%s'", tostring(request.from))
	end
	if not to or not AirportService.getAirport(to) then
		return false, nil, string.format("unknown destination airport '%s'", tostring(request.to))
	end

	--[[
		Same field twice. Refused here rather than left to flightPlan()'s nil,
		because "you cannot fly to where you already are" is a thing to tell the
		pilot, and a nil plan three lines later is not.
	]]
	if from == to then
		return false, nil, "departure and destination are the same field"
	end

	--[[
		The plan itself is AirportService's answer, not a second one. If this is
		ever nil with two valid and different fields, the registry and the
		planner disagree and that is a server fault rather than a bad request.
	]]
	local plan = AirportService.flightPlan(from, to)
	if not plan then
		return false, nil, string.format("no route from '%s' to '%s'", from, to)
	end

	return true, { aircraftId = aircraftId, from = from, to = to, plan = plan }, nil
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

	--[[
		THE TABLET'S "START FLIGHT" (Phase 4b).

		Validated here and spawned here rather than in AirportService, because
		this is the module that owns spawning - AirportService owns where the
		tarmac is and what the leg looks like, and it has already answered both
		by the time this runs.

		It lives on RequestSpawnAircraft's own path deliberately: a flight plan
		that could not put an aeroplane on the ground would be a plan the pilot
		cannot fly, so this IS a spawn, with a departure field and a validated
		selection attached. Replacing an existing aircraft is inherited from
		spawn() rather than restated.
	]]
	local startFlight = Remotes.Get("StartFlight")
	startFlight.OnServerInvoke = function(player: Player, request: any)
		--[[
			Everything below arrives from a client and is treated as such. The
			shape is checked before any field is read, because `request.from` on
			a number is not an error in Lua - it is nil, and nil would silently
			become "the nearest field" three calls further down.
		]]
		local ok, evaluated, message = AircraftService.evaluateFlightRequest(request)
		if not ok then
			return false, message
		end

		local accepted = evaluated :: AcceptedFlight

		--[[
			⚠️ STREAM THE DEPARTURE FIELD IN BEFORE ANYONE GOES THERE. This is
			not an optimisation, it is the difference between the feature working
			and killing the pilot.

			WORKSPACE STREAMING IS ON in this place. Measured, starting a flight
			from Ridge while standing at Meadow: the pilot was teleported to
			Ridge's parking correctly - and then FELL, because their client had
			not streamed Ridge's terrain yet and there was nothing under them.
			Three seconds later they were 45 m below the strip and accelerating;
			shortly after that they died and respawned at Meadow, which also
			respawned their aeroplane (§7 - dying requests a new one). From the
			pilot's seat the tablet simply killed them.

			RequestStreamAroundAsync is the documented answer: it yields until
			the client holds that region. Yielding here is free - this is a
			RemoteFunction handler and the tablet is already waiting on the
			round trip.

			pcall'd because it can time out on a slow client, and a timeout must
			not take the whole flight request down with it: a pilot who arrives
			slightly early falls a metre, which the fall damage in this game does
			not care about, and the alternative is refusing to start the flight
			at all.
		]]
		local departure = AirportService.getAirport(accepted.from) :: any
		local streamOk, streamErr = pcall(function()
			player:RequestStreamAroundAsync(
				Vector3.new(departure.origin.X, departure.elevation, departure.origin.Z)
			)
		end)
		if not streamOk then
			warn(string.format(
				"[FlightSim:Aircraft] could not stream %s in for %s: %s - they may arrive before the ground does",
				accepted.from, player.Name, tostring(streamErr)
			))
		end

		local model, spawnMessage = AircraftService.spawn(player, accepted.aircraftId, accepted.from)
		if not model then
			warn(string.format("[FlightSim:Aircraft] flight refused for %s: %s", player.Name, tostring(spawnMessage)))
			return false, spawnMessage
		end

		--[[
			And the pilot goes with it. See standPilotBeside for what starting a
			flight from a field you are not standing on looks like without this.
		]]
		local moved = standPilotBeside(player, model)

		log(
			"%s starts %s -> %s in a %s (%.1f km on %03.0f)%s",
			player.Name,
			accepted.plan.fromName,
			accepted.plan.toName,
			accepted.aircraftId,
			accepted.plan.distance / 1000,
			accepted.plan.bearing,
			if moved then " - pilot moved to the aeroplane" else ""
		)

		return true, accepted.plan
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
	--[[
		SPAWN_HEIGHT is measured from the SURFACE, not from sea level, and this
		assertion has to say so now that the airport sits at an elevation. It
		read `y == SPAWN_HEIGHT` while the surface was y = 0, which was the same
		statement by accident rather than on purpose.

		Nothing in the spawn path itself needed changing: slotCFrame() already
		builds on AirportService.apronSlotCFrame(), so the aircraft followed the
		aerodrome up without being told.
	]]
	record(
		"Parks on the ground rather than spawning airborne",
		math.abs(root.Position.Y - (AirportService.SURFACE_Y + SPAWN_HEIGHT)) < 0.01,
		string.format("y = %.3f m, which is %.2f m above a surface at %.0f m",
			root.Position.Y, root.Position.Y - AirportService.SURFACE_Y, AirportService.SURFACE_Y)
	)

	--[[
		⚠️ THE ONE ABOVE IS CIRCULAR, AND THAT IS WHY THE AEROPLANE SPAWNED
		UNDERGROUND WITH EVERY SUITE GREEN.

		It compares the spawn against `SPAWN_HEIGHT` - the very constant that
		was wrong - so it passed happily while the tyres sat a metre below the
		apron. A test that restates its subject cannot fail with it.

		This one asks the question the constant exists to answer, from the
		other side: DO THE WHEELS TOUCH THE TARMAC. It measures the built
		model's actual collidable geometry against the actual surface and never
		mentions SPAWN_HEIGHT, so it is independent of anything the spawn path
		believes about itself.

		Tolerance is a centimetre either way: resting ON the surface, not
		hovering above it and not buried in it.
	]]
	local lowestWheel = math.huge
	for _, p in a:GetDescendants() do
		if p:IsA("BasePart") and p.CanCollide and not p.Massless then
			lowestWheel = math.min(lowestWheel, p.Position.Y - p.Size.Y / 2)
		end
	end
	record(
		"The wheels rest ON the surface, measured not assumed",
		math.abs(lowestWheel - AirportService.SURFACE_Y) < 0.01,
		string.format("lowest collidable point %.3f m vs surface %.3f m (%+.3f m)",
			lowestWheel, AirportService.SURFACE_Y, lowestWheel - AirportService.SURFACE_Y)
	)

	-- 4b. Parked at the airport, not at the old origin -----------------------
	--[[
		The three things that have to be true of a real spawned aircraft once the
		apron owns placement. AirportService tests the slot ARITHMETIC; these
		test that a genuine 1,111 kg aeroplane came out where the arithmetic
		said, which is the part that would silently break if the two modules ever
		disagreed about what a slot CFrame means.
	]]
	local apron = AirportService.APRON_CENTRE
	record(
		"Spawns on the apron rather than at the world origin",
		math.abs(root.Position.X - apron.X) < AirportService.APRON_SIZE.X / 2
			and math.abs(root.Position.Z - apron.Z) < AirportService.APRON_SIZE.Y / 2,
		string.format("(%.0f, %.0f) against an apron at (%.0f, %.0f)", root.Position.X, root.Position.Z, apron.X, apron.Z)
	)

	--[[
		THE one that matters for safety. An aeroplane materialising on the
		centreline in front of somebody on short final is the worst thing this
		service could do, and it is a one-constant mistake away.
	]]
	local runway36 = AirportService.getRunway("meadow", "36") :: any
	record(
		"A spawned aircraft is nowhere near the runway",
		math.abs(root.Position.X) > runway36.width / 2 + 11,
		string.format("%.0f m off the centreline, runway is %.1f m wide", math.abs(root.Position.X), runway36.width)
	)

	record(
		"A parked aircraft already faces runway 36",
		root.CFrame.LookVector:Dot(runway36.direction) > 0.99,
		string.format("look %s", tostring(root.CFrame.LookVector))
	)

	-- 5. Boarding -----------------------------------------------------------
	local seat = a:FindFirstChild("PilotSeat")
	local boardPrompt = seat and seat:FindFirstChild("BoardPrompt") :: ProximityPrompt?
	record(
		"Has a board prompt on the pilot seat",
		boardPrompt ~= nil,
		seat and "BoardPrompt present" or "no PilotSeat"
	)
	record(
		"The prompt is showing on an empty aircraft",
		boardPrompt ~= nil and boardPrompt.Enabled,
		"Enabled = true with nobody aboard"
	)

	--[[
		The prompt must go away once somebody is in the seat.

		Driven with a REAL Sit() against a synthetic character rather than by
		poking the property, because Occupant is read-only - the only way to
		change it is to actually seat a humanoid, and it is the seat's own
		Occupant signal that this fix hangs off. A fixture that set the flag by
		hand would test the assignment and not the wiring.

		Reported from the Phase 1 gate: "Board" stayed on screen for the whole
		flight.
	]]
	local dummy = Instance.new("Model")
	dummy.Name = "__BoardPromptTestCharacter"
	local dummyRoot = Instance.new("Part")
	dummyRoot.Name = "HumanoidRootPart"
	dummyRoot.Size = Vector3.new(0.5, 1, 0.3)
	dummyRoot.CFrame = (seat :: BasePart).CFrame
	dummyRoot.Parent = dummy
	local dummyHumanoid = Instance.new("Humanoid")
	dummyHumanoid.Parent = dummy
	dummy.PrimaryPart = dummyRoot
	dummy.Parent = workspace

	;(seat :: VehicleSeat):Sit(dummyHumanoid)
	-- Occupant is set by the engine, and the property-changed signal it drives is
	-- deferred; one step is enough for both to land.
	task.wait()

	local seatedOk = (seat :: VehicleSeat).Occupant == dummyHumanoid
	record(
		"Setup: the dummy is actually seated",
		seatedOk,
		seatedOk and "Occupant set" or "Sit() did not take - the check below proves nothing"
	)
	record(
		"The board prompt hides once somebody is aboard",
		boardPrompt ~= nil and not boardPrompt.Enabled,
		string.format("Enabled = %s while occupied", tostring(boardPrompt and boardPrompt.Enabled))
	)

	dummyHumanoid.Sit = false
	;(seat :: VehicleSeat):Sit(nil :: any)
	task.wait()
	record(
		"...and comes back when the seat is vacated",
		boardPrompt ~= nil and boardPrompt.Enabled,
		string.format("Enabled = %s after standing up", tostring(boardPrompt and boardPrompt.Enabled))
	)

	dummy:Destroy()

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
		-- %.1f, not %d: the spacing is derived from the drawn span now and is
		-- not an integer, and string.format("%d", 33.7) is an error in Luau.
		string.format("%.1f m apart (spacing %.1f m)", separation.Magnitude, SPAWN_SPACING)
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

	-- 10. Flight requests from the tablet (Phase 4b) -------------------------
	--[[
		The remote handler itself needs a Player and cannot be tested here, for
		the same reason network ownership cannot - see this suite's header. What
		CAN be tested is everything the handler decides before it spawns
		anything, which is why evaluateFlightRequest() is a separate function.

		Every one of these refusals is reachable from a client, so each is
		asserted rather than assumed: this is the project's first remote that
		takes a structured payload rather than a single string.
	]]
	local goodRequest = { aircraftId = "c172", from = "meadow", to = "ridge" }
	local accepted, acceptedPlan = AircraftService.evaluateFlightRequest(goodRequest)
	record(
		"A well-formed flight plan is accepted",
		accepted and acceptedPlan ~= nil and (acceptedPlan :: AcceptedFlight).plan.toName == "Ridge Strip",
		accepted and string.format("%s -> %s", (acceptedPlan :: AcceptedFlight).from, (acceptedPlan :: AcceptedFlight).to) or "refused"
	)

	--[[
		The plan handed back must be AirportService's, not a rebuild of it. Same
		argument as the snapshot check in that module: two navigation
		implementations is one too many.
	]]
	local reference = AirportService.flightPlan("meadow", "ridge") :: any
	record(
		"...and carries AirportService's own plan, not a copy of the arithmetic",
		acceptedPlan ~= nil
			and math.abs((acceptedPlan :: AcceptedFlight).plan.distance - reference.distance) < 1e-6
			and math.abs((acceptedPlan :: AcceptedFlight).plan.bearing - reference.bearing) < 1e-6,
		string.format("%.1f m on %03.0f", reference.distance, reference.bearing)
	)

	-- Omitting the aircraft is legal and means the default, exactly as
	-- RequestSpawnAircraft treats it.
	local defaulted, defaultedPlan = AircraftService.evaluateFlightRequest({ from = "meadow", to = "ridge" })
	record(
		"An omitted aircraft defaults rather than failing",
		defaulted and (defaultedPlan :: AcceptedFlight).aircraftId == Registry.DEFAULT_ID,
		defaulted and (defaultedPlan :: AcceptedFlight).aircraftId or "refused"
	)

	local refusals = {
		{ label = "A request that is not a table", request = "meadow" },
		{ label = "An unknown aircraft", request = { aircraftId = "spitfire", from = "meadow", to = "ridge" } },
		{ label = "An unknown departure field", request = { from = "heathrow", to = "ridge" } },
		{ label = "An unknown destination field", request = { from = "meadow", to = "heathrow" } },
		{ label = "A missing destination", request = { from = "meadow" } },
		--[[
			The same field twice. Refused with a message a pilot can read rather
			than left to flightPlan()'s nil, which would surface as "no route"
			and read like a fault in the registry.
		]]
		{ label = "Departing and arriving at one field", request = { from = "ridge", to = "ridge" } },
		--[[
			A number where a string belongs. This is the shape that motivated
			checking the payload at all: `request.from` on a non-table is nil in
			Lua, not an error, and nil silently means "the nearest field".
		]]
		{ label = "A field id that is a number", request = { from = 36, to = "ridge" } },
	}

	for _, case in refusals do
		local ok, plan, message = AircraftService.evaluateFlightRequest(case.request)
		record(
			case.label .. " is refused with a reason",
			not ok and plan == nil and type(message) == "string" and #message > 0,
			tostring(message)
		)
	end

	--[[
		SPAWNING AT A CHOSEN FIELD, which is the whole point of the third
		argument and the one behaviour that would otherwise only be discovered
		by flying to Ridge and finding the aeroplane at Meadow.
	]]
	local atRidge = AircraftService.spawn(nil, "c172", "ridge")
	if atRidge then
		table.insert(spawned, atRidge)
	end
	local ridge = AirportService.getAirport("ridge") :: any
	local ridgeRoot = atRidge and atRidge.PrimaryPart
	record(
		"A flight from Ridge parks the aeroplane at Ridge",
		ridgeRoot ~= nil
			and (Vector3.new(ridgeRoot.Position.X - ridge.origin.X, 0, ridgeRoot.Position.Z - ridge.origin.Z)).Magnitude < 400,
		ridgeRoot and string.format(
			"(%.0f, %.0f) against a field origin at (%.0f, %.0f)",
			ridgeRoot.Position.X, ridgeRoot.Position.Z, ridge.origin.X, ridge.origin.Z
		) or "no aircraft"
	)

	--[[
		And it sits on RIDGE's surface, 150 m above Meadow's. An aeroplane
		parked at the right X and Z but the wrong elevation would be buried in
		the hillside or dropped onto it, and the horizontal check above cannot
		see that at all.
	]]
	record(
		"...at Ridge's own elevation, not Meadow's",
		ridgeRoot ~= nil and math.abs(ridgeRoot.Position.Y - (ridge.elevation + SPAWN_HEIGHT)) < 0.01,
		ridgeRoot and string.format(
			"y = %.2f m against a field at %.0f m",
			ridgeRoot.Position.Y, ridge.elevation
		) or "no aircraft"
	)

	--[[
		An unknown field falls back rather than erroring - the second line of
		defence described on spawn(). Meadow is the primary and there is no
		character in this suite, so that is where it must land.
	]]
	local fallback = AircraftService.spawn(nil, "c172", "heathrow")
	if fallback then
		table.insert(spawned, fallback)
	end
	record(
		"An unknown departure field falls back to a real one",
		fallback ~= nil
			and fallback.PrimaryPart ~= nil
			and math.abs((fallback.PrimaryPart :: BasePart).Position.Y - (AirportService.SURFACE_Y + SPAWN_HEIGHT)) < 0.01,
		fallback and "parked at the primary field" or "no aircraft"
	)

	-- 11. Standing the pilot beside their aeroplane (Phase 4b) ---------------
	--[[
		⚠️ THE BEHAVIOUR THIS ASSERTS WAS MISSING ENTIRELY UNTIL A REAL FLIGHT
		WAS STARTED. Everything else about StartFlight measured correct - the
		plan, the validation, the aeroplane parked exactly on Ridge's slot - and
		the feature was still broken, because the pilot stayed on Meadow's apron
		1.6 km away, with workspace streaming holding 0 of the aeroplane's 128
		parts on their client. No unit test in this file could have found it;
		flying it did, immediately.

		The arithmetic is asserted here. That the whole thing works is asserted
		by starting a flight, which is in the handoff.
	]]
	local FACING_NORTH = CFrame.lookAt(Vector3.new(0, 250, 0), Vector3.new(0, 250, -1))
	local stood = AircraftService.pilotStandingCFrame(FACING_NORTH, 250, 0.93)

	--[[
		To the aeroplane's LEFT, which for something facing north (-Z) is -X.
		Left rather than right because that is the side a 172's pilot door is on,
		and because it must be a side rather than in front of the propeller.
	]]
	record(
		"The pilot stands off the aeroplane's left wing",
		math.abs(stood.Position.X - (-PILOT_STANDOFF)) < 1e-4 and math.abs(stood.Position.Z) < 1e-4,
		string.format("(%.2f, %.2f) beside an aeroplane facing north", stood.Position.X, stood.Position.Z)
	)

	record(
		"...standing on the ground, not floating or buried",
		math.abs(stood.Position.Y - (250 + 0.93)) < 1e-4,
		string.format("y = %.3f, which is the surface plus the rig's own standing height", stood.Position.Y)
	)

	--[[
		Facing the aeroplane. Its LookVector must point back toward the
		aeroplane's centre - +X for a pilot stood to the left of it.
	]]
	record(
		"...and facing it, so the board prompt is in front of them",
		stood.LookVector.X > 0.99 and math.abs(stood.LookVector.Y) < 1e-3,
		string.format("look %s", tostring(stood.LookVector))
	)

	--[[
		THE ONE THAT GENERALISES, and the reason the offset is taken in the
		aeroplane's own frame rather than along an axis. Ridge's runway runs
		east-west, so an aeroplane there faces +X - and a world-X offset would
		put the pilot squarely in front of the propeller instead of beside the
		door. Meadow's north-south runway would never have shown it.
	]]
	--[[
		⚠️ AND THE SIGN IS THE POINT. Facing EAST, the pilot's left hand points
		NORTH, and north is -Z in this project's convention (AirportService's
		header). So the offset REDUCES Z. This assertion was first written as
		166 + 6 and failed on correct code - the same class of mistake §7 records
		for the lateral cross product, arrived at from the other direction.
	]]
	local facingEast = CFrame.lookAt(Vector3.new(1390, 400, 166), Vector3.new(1391, 400, 166))
	local atRidgeStand = AircraftService.pilotStandingCFrame(facingEast, 400, 0.93)
	record(
		"The offset follows the aeroplane, so it works at Ridge too",
		math.abs(atRidgeStand.Position.X - 1390) < 1e-3
			and math.abs(atRidgeStand.Position.Z - (166 - PILOT_STANDOFF)) < 1e-3,
		string.format("(%.1f, %.1f) beside an aeroplane facing east - left of east is north, so Z falls",
			atRidgeStand.Position.X, atRidgeStand.Position.Z)
	)

	--[[
		And clear of the aeroplane it is parked beside. §45 draws the fuselage
		about 1.9 m half-width; the standoff must clear that and must NOT reach
		the next slot, which is SPAWN_SPACING away.
	]]
	record(
		"The standoff clears the fuselage without reaching the next slot",
		PILOT_STANDOFF > 2 and PILOT_STANDOFF < SPAWN_SPACING / 2,
		string.format("%.0f m, against a %.0f m slot spacing", PILOT_STANDOFF, SPAWN_SPACING)
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
