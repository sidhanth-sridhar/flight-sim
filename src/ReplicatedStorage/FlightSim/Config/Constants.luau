--!strict
--[[
	Constants
	---------
	Single source of truth for every global tunable in the flight simulator.
	Nothing in this module depends on anything else, so it can be required from
	any context (server, client, command bar) without ordering concerns.

	WORLD SCALE
	-----------
	This project uses 1 stud = 1 metre. That choice has one large consequence:
	Roblox's default gravity of 196.2 studs/s^2 is wrong for us. If we left it
	alone, a metre-scale aircraft would fall 20x too hard, which is equivalent
	to running the entire simulation ~4.5x too fast (time scales with 1/sqrt(g)).
	Stalls would happen in a blink and landings would be impossible.

	So the server sets Workspace.Gravity = 9.80665 at startup. Everything else
	- character walk speed, jump height - is retuned to match, because a human
	is now ~1.8 studs tall instead of 5.
]]

local Constants = {}

-- =========================================================================
-- WORLD SCALE
-- =========================================================================

-- How many studs represent one real-world metre.
-- Every unit conversion in Units.luau derives from this, so changing the
-- scale of the entire project is a one-line edit here.
Constants.STUDS_PER_METER = 1.0

-- Standard gravity (m/s^2). Applied to Workspace.Gravity by the server at
-- startup, scaled into studs by Units.metersToStuds.
Constants.GRAVITY_MS2 = 9.80665

-- =========================================================================
-- CHARACTER TUNING
-- =========================================================================
-- Retuned for metre-scale gravity. Roblox defaults (WalkSpeed 16, JumpHeight
-- 7.2) would mean a person sprinting at 58 km/h and jumping over a car.
--
-- Note: JumpHeight is expressed in studs and Roblox derives the launch
-- velocity from current gravity, so it stays correct automatically. JumpPower
-- does NOT, which is why we force UseJumpPower off.

Constants.CHARACTER = {
	--[[
		A jog, not a walk, and knowingly faster than a person moves.

		At 1 stud = 1 m the world is 20x larger in feet-on-the-ground terms than
		a normal Roblox place, so a realistic 1.4 m/s walk makes crossing an
		apron a chore. The aircraft park 30 m from the spawn pad, which is the
		trip that has to not be annoying.
	]]
	WALK_SPEED = 7.0, -- m/s (~25 km/h)
	JUMP_HEIGHT = 0.9, -- m, a realistic standing jump
	USE_JUMP_POWER = false,
}

-- =========================================================================
-- SIMULATION
-- =========================================================================

Constants.SIM = {
	-- The flight model runs on the pilot's client every RenderStep. This caps
	-- the integration timestep so a frame hitch (alt-tab, asset load) cannot
	-- inject a huge dt and launch the aircraft into orbit.
	MAX_TIMESTEP = 1 / 20,

	-- Rate at which the pilot's client publishes authoritative aircraft state
	-- (fuel, engine, control positions) to the server. Position/velocity are
	-- NOT sent here - Roblox replicates those automatically because the
	-- pilot owns the assembly.
	STATE_SYNC_HZ = 10,

	-- Instruments and HUD refresh rate. Gauges do not need 240 Hz; decoupling
	-- them from render frames is a meaningful saving once a full panel exists.
	INSTRUMENT_HZ = 30,
}

-- =========================================================================
-- VALIDATION (server-side sanity checks, not anti-cheat theatre)
-- =========================================================================
-- Because the pilot's client owns the physics, a modified client could fly
-- anywhere. These bounds catch the obviously-impossible so the server can
-- reset an aircraft rather than let it corrupt world state.

Constants.LIMITS = {
	MAX_SPEED_MS = 400, -- ~778 knots; far above any aircraft we plan to ship
	MAX_ALTITUDE_M = 20000, -- top of the modelled atmosphere
	MIN_ALTITUDE_M = -500, -- below the lowest terrain, allows for deep valleys
}

-- =========================================================================
-- DEBUG
-- =========================================================================

Constants.DEBUG = {
	-- Master switch for verbose logging from every FlightSim system.
	ENABLED = true,

	-- Draws force vectors and shows the raw-numbers panel in flight.
	SHOW_PHYSICS_OVERLAY = true,
}

Constants.VERSION = "0.1.0-phase0"

-- Freeze recursively so a typo like Constants.SIM.MAX_TIMESTEP = 5 raises an
-- error instead of silently changing physics for one context only.
-- (table.freeze is shallow, hence the recursion.)
local function deepFreeze(t: { [any]: any })
	for _, v in t do
		if type(v) == "table" and not table.isfrozen(v) then
			deepFreeze(v)
		end
	end
	return table.freeze(t)
end

return deepFreeze(Constants)
