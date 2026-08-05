--!strict
--[[
	FlightSim - Server Bootstrap
	----------------------------
	The single entry point for everything the server does. Runs before any
	player can join, and is responsible for:

	  1. Applying world physics settings (gravity, character tuning)
	  2. Creating the network surface, so clients never race against it
	  3. Verifying the physics modules load and produce sane numbers
	  4. Starting services (none yet - Phase 1 onward)

	ORDERING MATTERS. Remotes must exist before the first client requests one,
	and gravity must be set before any physics object is simulated. Doing this
	from one script with an explicit order, rather than from several scripts
	that happen to run at whatever time Roblox chooses, removes an entire
	category of startup bug.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local FlightSim = ReplicatedStorage:WaitForChild("FlightSim")

local Constants = require(FlightSim.Config.Constants)
local Units = require(FlightSim.Shared.Units)
local Remotes = require(FlightSim.Net.Remotes)
local Atmosphere = require(FlightSim.Physics.Atmosphere)

local startClock = os.clock()

local function log(message: string, ...)
	print("[FlightSim:Server] " .. string.format(message, ...))
end

-- =========================================================================
-- 1. WORLD PHYSICS
-- =========================================================================

local function applyWorldPhysics()
	--[[
		The most consequential line in the project.

		Roblox defaults to 196.2 studs/s^2, which assumes the traditional
		stud scale where a character is 5 studs tall. We use 1 stud = 1 metre,
		so gravity must be real gravity - otherwise the aircraft falls 20x too
		hard, which is equivalent to running the whole simulation about 4.5x
		too fast. Stalls would happen faster than a player could react and no
		amount of tuning elsewhere could compensate.
	]]
	Workspace.Gravity = Units.GRAVITY_STUDS

	--[[
		Character movement, retuned for metre scale.

		UseJumpPower must be false. JumpPower is a raw launch velocity, so at
		one twentieth of the usual gravity a default jump would clear a
		five-storey building. JumpHeight is a distance and Roblox derives the
		velocity from current gravity, so it stays correct automatically.
	]]
	StarterPlayer.CharacterUseJumpPower = Constants.CHARACTER.USE_JUMP_POWER
	StarterPlayer.CharacterWalkSpeed = Units.metersToStuds(Constants.CHARACTER.WALK_SPEED)
	StarterPlayer.CharacterJumpHeight = Units.metersToStuds(Constants.CHARACTER.JUMP_HEIGHT)

	log(
		"World physics set - gravity %.4f studs/s^2, walk %.1f, jump height %.2f",
		Workspace.Gravity,
		StarterPlayer.CharacterWalkSpeed,
		StarterPlayer.CharacterJumpHeight
	)
end

-- =========================================================================
-- 2. NETWORK
-- =========================================================================

local function createNetwork()
	local count = Remotes.Init()
	log("Network ready - %d remotes created", count)
end

-- =========================================================================
-- 3. PHYSICS SELF-CHECK
-- =========================================================================

--[[
	A fast sanity check that the atmosphere model loaded correctly, rather
	than the full test suite - that would spam the output on every server
	start. Run the full suites manually from the command bar:

		require(game.ReplicatedStorage.FlightSim.Physics.Atmosphere).runTests()
		require(game.ReplicatedStorage.FlightSim.Physics.Aerodynamics).runTests()

	The point of checking at all is that a silently wrong density would
	produce an aircraft that flies almost right, which is far harder to
	diagnose than one that fails loudly at startup.
]]
local function verifyPhysics()
	local seaLevelDensity = Atmosphere.getDensity(0)
	local expected = 1.225

	if math.abs(seaLevelDensity - expected) > 0.001 then
		warn(string.format(
			"[FlightSim:Server] Atmosphere model is wrong - sea level density is %.5f, expected %.5f. "
				.. "Aircraft performance will be incorrect.",
			seaLevelDensity,
			expected
		))
		return false
	end

	log("Physics verified - sea level density %.4f kg/m3", seaLevelDensity)
	return true
end

-- =========================================================================
-- 4. SERVICES
-- =========================================================================

--[[
	Services are added here as they are built, each as a ModuleScript under
	ServerScriptService/FlightSim/Services exposing an Init() function.

	Built: TerrainService   - the ground itself, and the airport's flat pad
	       AirportService   - the world: runway, taxiway, apron, navigation
	       AircraftService  - spawning, ownership, validation
	Later: FlightPlanService, WeatherService, PlayerDataService

	SERVICE_ORDER exists because Services:GetChildren() returns whatever order
	Roblox feels like, and "whatever order Roblox feels like" is exactly the
	category of startup bug the note at the top of this file says one explicit
	sequence removes. The airport is listed first because it is the world every
	other service places things in.

	Anything not named here still starts, after the listed ones, so adding a
	service cannot silently fail to run - it just does not get to choose when.
]]
local SERVICE_ORDER = {
	--[[
		Terrain first: it is the ground everything else stands on, it retires the
		baseplate, and AirportService's obstruction sweep measures against it.
		It reads the airport's declared elevation, so the dependency is on
		AirportService's CONSTANTS, which are available before any Init() runs -
		see the note at the top of that file.
	]]
	"TerrainService",
	"AirportService",
	"AircraftService",
}

--[[
	WHERE THE SERVICES FOLDER IS DEPENDS ON HOW ROJO NAMED THIS FILE, and
	getting it wrong starts NO services at all while everything else about the
	boot looks perfectly healthy.

	Rojo has two layouts for a directory containing a script:

	  init.server.luau  -> the DIRECTORY becomes the Script. `script` is
	                       ServerScriptService.FlightSim, and Services is its
	                       CHILD. script.Parent is ServerScriptService.
	  Init.server.luau  -> the directory becomes a FOLDER holding a script
	                       named Init. script.Parent is the FlightSim folder,
	                       and Services is a SIBLING.

	This file was renamed from the second form to the first - which is Rojo's
	documented convention - and that silently moved the folder out from under
	`script.Parent`. The symptom was a world with no airport, no terrain and no
	aircraft, while gravity, the remotes and the physics self-check were all
	correct, because those run before this function.

	Both are checked, so the bootstrap survives either layout, and a missing
	folder now WARNS instead of returning zero in silence.
]]
local function findServicesFolder(): Instance?
	return script:FindFirstChild("Services") or script.Parent:FindFirstChild("Services")
end

local function startServices()
	local servicesFolder = findServicesFolder()
	if not servicesFolder then
		warn(
			"[FlightSim:Server] No Services folder found under "
				.. script:GetFullName()
				.. " or its parent - NO services started. The world will be empty."
		)
		return 0
	end

	-- Listed services first, in order; then everything else.
	local ordered: { Instance } = {}
	local seen: { [Instance]: boolean } = {}

	for _, name in SERVICE_ORDER do
		local module = servicesFolder:FindFirstChild(name)
		if module then
			table.insert(ordered, module)
			seen[module] = true
		else
			warn(string.format("[FlightSim:Server] SERVICE_ORDER names '%s', which does not exist.", name))
		end
	end

	for _, module in servicesFolder:GetChildren() do
		if not seen[module] then
			table.insert(ordered, module)
		end
	end

	local started = 0
	for _, module in ordered do
		if module:IsA("ModuleScript") then
			-- One failing service must not prevent the rest from starting, so
			-- each is isolated and its failure reported rather than thrown.
			local ok, err = pcall(function()
				local service = require(module)
				if type(service) == "table" and type(service.Init) == "function" then
					service.Init()
				end
			end)

			if ok then
				started += 1
			else
				warn(string.format("[FlightSim:Server] Service '%s' failed to start: %s", module.Name, tostring(err)))
			end
		end
	end

	return started
end

-- =========================================================================
-- BOOT
-- =========================================================================

log("Starting FlightSim %s", Constants.VERSION)

applyWorldPhysics()
createNetwork()
verifyPhysics()

local serviceCount = startServices()
if serviceCount > 0 then
	log("Started %d service(s)", serviceCount)
end

log("Server ready in %.1f ms", (os.clock() - startClock) * 1000)

