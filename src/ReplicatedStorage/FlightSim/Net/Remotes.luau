--!strict
--[[
	Remotes
	-------
	Central registry for every RemoteEvent and RemoteFunction in the project.

	The problem this solves: the usual approach scatters
		ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("SomeEvent")
	across forty scripts. A typo produces an infinite yield with no error, and
	nobody can tell what the game's network surface actually is.

	Here, MANIFEST below is the complete, readable list of every message that
	crosses the network. The server creates the instances from it at startup;
	the client waits for them. Both sides then access them by key:

		local Remotes = require(ReplicatedStorage.FlightSim.Net.Remotes)
		Remotes.Get("WeatherChanged").OnClientEvent:Connect(fn)

	Asking for a name that is not in the manifest raises an immediate, clear
	error instead of hanging forever.

	WHAT DOES *NOT* GO THROUGH HERE
	-------------------------------
	Aircraft position, orientation and velocity are never sent as remotes.
	The pilot's client owns the aircraft assembly, so Roblox replicates its
	motion natively - far more efficient and better interpolated than anything
	we would write. Remotes carry state that Roblox does not replicate on its
	own: fuel, engine condition, weather, flight plans, settings.
]]

local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()

-- =========================================================================
-- MANIFEST
-- =========================================================================
-- Every network message in the game. Adding a feature means adding a line
-- here first, which keeps the network surface reviewable at a glance.
--
-- Direction is documentation for humans; Roblox does not enforce it, but
-- stating it makes the wrong usage obvious in code review.

type RemoteKind = "Event" | "Function"

local MANIFEST: { [string]: { kind: RemoteKind, direction: string, purpose: string } } = {
	-- ---- Aircraft lifecycle ------------------------------------------------
	RequestSpawnAircraft = {
		kind = "Function",
		direction = "Client -> Server",
		purpose = "Ask the server to spawn an aircraft by id; returns (accepted, reasonIfNot). "
			.. "The aircraft itself arrives on AircraftAssigned, so the client has one adoption path, not two. "
			.. "Requesting again replaces the player's existing aircraft.",
	},
	RequestDespawnAircraft = {
		kind = "Event",
		direction = "Client -> Server",
		purpose = "Player has left the aircraft or ended their flight.",
	},
	AircraftAssigned = {
		kind = "Event",
		direction = "Server -> Client",
		purpose = "Server hands the client its aircraft and confirms network ownership.",
	},

	-- ---- Aircraft state ----------------------------------------------------
	AircraftStateSync = {
		kind = "Event",
		direction = "Client -> Server",
		purpose = "Pilot reports non-physics state (fuel, RPM, gear, flaps) at Constants.SIM.STATE_SYNC_HZ.",
	},
	AircraftStateBroadcast = {
		kind = "Event",
		direction = "Server -> Client",
		purpose = "Server relays other players' aircraft state for external visuals (prop blur, lights, gear).",
	},

	-- ---- Weather -----------------------------------------------------------
	WeatherChanged = {
		kind = "Event",
		direction = "Server -> Client",
		purpose = "New authoritative weather state; clients apply visuals and feed wind into the flight model.",
	},
	RequestWeather = {
		kind = "Function",
		direction = "Client -> Server",
		purpose = "Fetch current weather on join, or for a specific airport in the flight tablet.",
	},

	-- ---- Flight planning ---------------------------------------------------
	RequestAirportList = {
		kind = "Function",
		direction = "Client -> Server",
		purpose = "Tablet asks for all known airports with positions and runway data.",
	},
	StartFlight = {
		kind = "Function",
		direction = "Client -> Server",
		purpose = "Begin a flight plan: validates selection, spawns aircraft at departure runway.",
	},
	FlightEvent = {
		kind = "Event",
		direction = "Server -> Client",
		purpose = "Flight milestones: airborne, waypoint reached, landed, plan completed or failed.",
	},

	-- ---- Player data -------------------------------------------------------
	RequestPlayerSettings = {
		kind = "Function",
		direction = "Client -> Server",
		purpose = "Load saved keybinds, sensitivity, assists and difficulty on join.",
	},
	SavePlayerSettings = {
		kind = "Event",
		direction = "Client -> Server",
		purpose = "Persist changed settings; server debounces before writing to DataStore.",
	},
}

-- =========================================================================
-- IMPLEMENTATION
-- =========================================================================

local Remotes = {}

local CONTAINER_NAME = "Objects"
local WAIT_TIMEOUT = 15

-- Cache instances after first lookup. Get() is called from hot paths on join
-- and every state sync, and FindFirstChild in a loop is wasted work.
local cache: { [string]: Instance } = {}
local container: Folder? = nil

local function getContainer(): Folder
	if container then
		return container
	end

	local net = script.Parent

	if IS_SERVER then
		local existing = net:FindFirstChild(CONTAINER_NAME)
		if existing then
			container = existing :: Folder
		else
			local folder = Instance.new("Folder")
			folder.Name = CONTAINER_NAME
			folder.Parent = net
			container = folder
		end
	else
		-- Client: the server creates this during its startup, which always
		-- completes before players can join.
		local folder = net:WaitForChild(CONTAINER_NAME, WAIT_TIMEOUT)
		if not folder then
			error("[Remotes] Network container never appeared. Did the server FlightSim.Init script run?", 2)
		end
		container = folder :: Folder
	end

	return container :: Folder
end

--[[
	Server only. Creates every remote instance in the manifest.
	Must be called by the server bootstrap before anything else touches the
	network. Safe to call twice - existing instances are reused, so a hot
	reload during development does not orphan connections.
]]
function Remotes.Init(): number
	if not IS_SERVER then
		error("[Remotes] Init() is server-only. Clients should just call Get().", 2)
	end

	local parent = getContainer()
	local count = 0

	for name, spec in MANIFEST do
		local className = if spec.kind == "Function" then "RemoteFunction" else "RemoteEvent"
		local existing = parent:FindFirstChild(name)

		if existing and not existing:IsA(className) then
			-- The manifest changed kind (Event <-> Function) since last run.
			existing:Destroy()
			existing = nil
		end

		if not existing then
			local remote = Instance.new(className)
			remote.Name = name
			remote.Parent = parent
			existing = remote
		end

		cache[name] = existing :: Instance
		count += 1
	end

	return count
end

--[[
	Fetch a remote by its manifest key. Works on both server and client.

	The manifest check happens first and deliberately: a typo fails loudly and
	immediately here, rather than becoming a silent infinite yield inside
	WaitForChild that takes an hour to track down.
]]
function Remotes.Get(name: string): any
	local cached = cache[name]
	if cached then
		return cached
	end

	local spec = MANIFEST[name]
	if not spec then
		error(string.format("[Remotes] '%s' is not in the manifest. Add it to Remotes.luau first.", name), 2)
	end

	local parent = getContainer()
	local remote = parent:WaitForChild(name, WAIT_TIMEOUT)
	if not remote then
		error(string.format("[Remotes] '%s' is in the manifest but was never created on the server.", name), 2)
	end

	cache[name] = remote
	return remote
end

-- Returns the manifest for tooling and documentation (the settings menu can
-- display it, and it makes the network surface printable during debugging).
function Remotes.GetManifest()
	return table.clone(MANIFEST)
end

return Remotes
