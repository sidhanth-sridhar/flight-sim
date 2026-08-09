--!strict
--[[
	FlightSim - Client Bootstrap
	----------------------------
	Entry point for everything that runs on the player's machine.

	The client carries far more responsibility in this project than in a
	typical Roblox game, because the pilot's client OWNS the aircraft physics.
	That is a deliberate decision: at 120 knots, a round trip to the server
	between moving the mouse and seeing the aircraft respond would make
	precise flying impossible. The server keeps authority over state that
	matters to other players - fuel, damage, spawns, weather - and sanity
	checks position, but the flight model itself runs here, at frame rate.

	Order is: wait for the network, load controllers, then start the frame
	loop. Nothing may assume a remote exists before the wait completes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FlightSim = ReplicatedStorage:WaitForChild("FlightSim")

local Constants = require(FlightSim.Config.Constants)
local Remotes = require(FlightSim.Net.Remotes)

local player = Players.LocalPlayer
local startClock = os.clock()

local function log(message: string, ...)
	print("[FlightSim:Client] " .. string.format(message, ...))
end

-- =========================================================================
-- 1. WAIT FOR THE NETWORK
-- =========================================================================

--[[
	Touching any remote forces the registry to resolve its container, which
	blocks until the server's bootstrap has created it. Doing that once here,
	up front, means every controller loaded afterwards can call Remotes.Get()
	synchronously without worrying about ordering.
]]
local function waitForNetwork(): boolean
	local ok, err = pcall(function()
		Remotes.Get("RequestPlayerSettings")
	end)

	if not ok then
		warn("[FlightSim:Client] Network unavailable: " .. tostring(err))
		return false
	end

	return true
end

-- =========================================================================
-- 2. CONTROLLERS
-- =========================================================================

--[[
	Controllers are ModuleScripts under Controllers/, each exposing Init().
	They are loaded in an explicit order rather than by iterating children,
	because the dependencies between them are real:

		SettingsController - loads keybinds and sensitivity; everything else
	                       reads from it, so it must come first
		InputController    - translates raw input into control axes
		FlightController   - runs the flight model each frame
		CameraController   - needs an aircraft to follow
		UIController       - needs aircraft state to display
		TabletController   - needs FlightController, both to read the aircraft's
		                     state for its gate and to hand the yoke back
		AudioController    - needs engine state

	Names not present yet are skipped silently, so this list can be written
	once and filled in as each phase lands.
]]
local CONTROLLER_ORDER = {
	"SettingsController",
	"InputController",
	"FlightController",
	"CameraController",
	"UIController",
	"TabletController",
	"AudioController",
}

local function startControllers(): number
	local folder = script.Parent:FindFirstChild("Controllers")
	if not folder then
		return 0
	end

	local started = 0
	for _, name in CONTROLLER_ORDER do
		local module = folder:FindFirstChild(name)
		if module and module:IsA("ModuleScript") then
			-- Isolate failures: a broken camera should not take down the
			-- flight model and leave the player stranded in an aircraft.
			local ok, err = pcall(function()
				local controller = require(module)
				if type(controller) == "table" and type(controller.Init) == "function" then
					controller.Init()
				end
			end)

			if ok then
				started += 1
			else
				warn(string.format("[FlightSim:Client] Controller '%s' failed: %s", name, tostring(err)))
			end
		end
	end

	-- Catch anything dropped into the folder but missing from the ordered
	-- list - almost always an oversight, and silent failure would be worse.
	for _, module in folder:GetChildren() do
		if module:IsA("ModuleScript") and not table.find(CONTROLLER_ORDER, module.Name) then
			warn(string.format(
				"[FlightSim:Client] Controller '%s' exists but is not in CONTROLLER_ORDER, so it was not started.",
				module.Name
			))
		end
	end

	return started
end

-- =========================================================================
-- BOOT
-- =========================================================================

log("Starting FlightSim %s for %s", Constants.VERSION, player.Name)

if waitForNetwork() then
	log("Network connected")
end

local controllerCount = startControllers()
if controllerCount > 0 then
	log("Started %d controller(s)", controllerCount)
else
	log("No controllers yet - Phase 1 will add input, flight model and camera")
end

log("Client ready in %.1f ms", (os.clock() - startClock) * 1000)
