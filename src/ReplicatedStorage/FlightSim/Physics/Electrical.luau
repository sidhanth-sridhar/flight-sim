--!strict
--[[
	Electrical
	----------
	The 172S's electrical system: two master switches, an avionics master, a
	battery, an alternator, circuit breakers and the ammeter that shows what all
	of it is doing. Phase 4c, item 5.

	WHY THIS IS A SYSTEM AND NOT A BOOLEAN
	--------------------------------------
	The panel parts are already modelled (Phase 4 item 4) and are inert. What
	makes them worth switching is that they are connected to something: the
	lights (item 8) draw current, the current comes from the alternator when the
	engine is turning and from the battery when it is not, and a battery has a
	finite amount in it. That chain is the whole system, and it is what turns
	"leave the master on overnight" into a thing that has a consequence.

	THE PUBLISHED NUMBERS (Cessna 172S POH, section 7 - electrical)
	--------------------------------------------------------------
	  28-volt system, 24-volt battery, 60-amp belt-driven alternator.
	  Ammeter shows the RATE OF CHARGE to the battery, not total system load -
	  which is why it reads a large positive figure straight after a start and
	  settles toward zero as the battery recovers.

	Everything below is asserted against those figures rather than against what
	the code happens to do.

	IT IS PURE, LIKE THE ENGINE
	---------------------------
	`update` is a function of state and dt and touches no Roblox instance. The
	3D switches and lights read this; nothing here reads them.
]]

local MathUtil = require(script.Parent.Parent.Shared.MathUtil)

local Electrical = {}

local max = math.max
local clamp = math.clamp

-- =========================================================================
-- PUBLISHED FIGURES
-- =========================================================================

Electrical.SYSTEM_VOLTS = 28 -- alternator output, bus voltage when charging
Electrical.BATTERY_VOLTS = 24 -- battery nominal
Electrical.ALTERNATOR_AMPS = 60 -- rated output

--[[
	Battery capacity in amp-hours.

	The 172S's Concorde RG-24-15 is a 12.75 Ah battery at the 1-hour rate; 13 Ah
	is the round figure the type is usually quoted at. It is the number that
	decides how long the aeroplane's lights stay on with the engine stopped, so
	it is published rather than picked.
]]
Electrical.BATTERY_CAPACITY_AH = 13

--[[
	The RPM at which the alternator starts producing.

	Belt-driven off the engine, so it does nothing at rest and comes on line
	just above idle - which is why the ammeter swings positive as the engine
	catches and why you do not run the avionics during a start.
]]
Electrical.ALTERNATOR_CUTIN_RPM = 800

--[[
	Steady loads in amps, by system. These are ordinary light-aircraft figures
	rather than POH table entries - the POH publishes the alternator and battery
	sizes, not a per-lamp breakdown - and they are stated here as one list so
	the total can be sanity-checked against the 60 A the alternator can give.
]]
Electrical.LOADS = {
	avionics = 8, -- radios, transponder, the panel's own instruments
	beacon = 2,
	nav = 3, -- both wingtip lamps plus the tail
	strobe = 5,
	taxi = 8,
	landing = 10,
	pitotHeat = 6,
}

--[[
	What a circuit breaker will carry before it pops.

	A breaker exists to protect the WIRE, so it is sized above the load it feeds
	and below what the wire can take. 5 A of headroom over the total switched
	load is an ordinary margin and gives the pilot something that only trips
	when something is actually wrong.
]]
Electrical.BREAKER_HEADROOM_AMPS = 5

export type State = {
	batteryMaster: boolean, -- BAT
	alternatorMaster: boolean, -- ALT
	avionicsMaster: boolean,

	batteryChargeAh: number,
	busVolts: number,
	--[[
		Positive is CHARGING, negative is discharging. This is the rate of
		charge to the battery, which is what the 172S's ammeter actually shows -
		not the total system load.
	]]
	ammeterAmps: number,
	loadAmps: number,
	alternatorOnline: boolean,
	breakerTripped: boolean,
}

function Electrical.createState(): State
	return {
		--[[
			The aeroplane is handed to the pilot with the masters ON and a full
			battery, in the state the tablet's "start flight" leaves it and the
			state every existing test assumes. Turning them off is a thing the
			pilot does, not a state they have to undo before flying.
		]]
		batteryMaster = true,
		alternatorMaster = true,
		avionicsMaster = true,

		batteryChargeAh = Electrical.BATTERY_CAPACITY_AH,
		busVolts = Electrical.BATTERY_VOLTS,
		ammeterAmps = 0,
		loadAmps = 0,
		alternatorOnline = false,
		breakerTripped = false,
	}
end

-- =========================================================================
-- THE BUS
-- =========================================================================

--[[
	Is the alternator producing?

	Three things have to be true: the engine is turning fast enough to drive the
	belt, the ALT master is on, and the battery master is on - because the
	alternator's field is excited from the bus, which is why an alternator
	cannot bring itself on line with the battery master off. That last one is a
	real property of the aeroplane and the reason the checklist turns BAT on
	before ALT.
]]
function Electrical.alternatorOnline(state: State, engineRunning: boolean, rpm: number): boolean
	return engineRunning
		and rpm >= Electrical.ALTERNATOR_CUTIN_RPM
		and state.alternatorMaster
		and state.batteryMaster
end

--[[
	The total current the switched-on systems are drawing.

	`switches` is a plain table of booleans keyed the same as LOADS, so adding a
	system is one entry in that table and nothing here. Avionics are gated on
	the avionics master, which is what that switch is FOR - it isolates the
	radios from the spikes a start puts on the bus.
]]
function Electrical.demandAmps(state: State, switches: { [string]: boolean }?): number
	if not state.batteryMaster and not state.alternatorOnline then
		-- Nothing is connected to anything.
		return 0
	end

	local total = 0
	for name, amps in Electrical.LOADS do
		local on = switches and switches[name] == true
		if name == "avionics" then
			on = state.avionicsMaster
		end
		if on then
			total += amps
		end
	end
	return total
end

--[[
	What the breaker panel will carry, derived from the loads it protects rather
	than typed, so adding a system cannot silently exceed it.
]]
function Electrical.breakerLimitAmps(): number
	local total = 0
	for _, amps in Electrical.LOADS do
		total += amps
	end
	return total + Electrical.BREAKER_HEADROOM_AMPS
end

--[[
	Advance the electrical system one step.

	`switches` names which consumers are on. The engine's state decides whether
	the alternator can produce; everything else follows from that.
]]
function Electrical.update(
	state: State,
	dt: number,
	engineRunning: boolean,
	rpm: number,
	switches: { [string]: boolean }?,
	--[[
		Current drawn by something that is NOT a switch: a short, a seized
		motor, a chafed loom. Zero in normal operation.

		It exists because a breaker that can only be tripped by switching on
		more lamps than the aeroplane has is a breaker that can never trip - the
		switched loads are sized to fit inside the alternator by design. A fault
		is the only thing that legitimately exceeds the panel, which is what
		breakers are FOR, and it is the seam Phase 6's damage model drives.
	]]
	faultAmps: number?
)
	state.alternatorOnline = Electrical.alternatorOnline(state, engineRunning, rpm)

	local demand = Electrical.demandAmps(state, switches) + max(faultAmps or 0, 0)

	--[[
		A breaker pops when the load exceeds what it protects, and STAYS popped
		until the pilot resets it - that is the difference between a breaker and
		a fuse holder, and it is why a popped breaker is a thing you notice.
	]]
	if demand > Electrical.breakerLimitAmps() then
		state.breakerTripped = true
	end
	if state.breakerTripped then
		demand = 0
	end

	state.loadAmps = demand

	--[[
		⚠️ A FLAT BATTERY WITH THE ALTERNATOR OFF IS A DEAD BUS. Checked before
		the voltage is set, because everything downstream - the lights, the
		avionics, the ammeter itself - reads the bus rather than the switches.
	]]
	local batteryAvailable = state.batteryMaster and state.batteryChargeAh > 0

	-- ---- The battery and the ammeter -------------------------------------
	--[[
		⚠️ THE BATTERY IS UPDATED BEFORE THE BUS VOLTAGE, and the order is
		load-bearing. Written the other way round, the step that drains the last
		of the charge sets the voltage from a battery that still had something
		in it - so the bus reported 20.4 V on a battery measured at 0.00 Ah, and
		the test that asks "is a flat battery a dead bus" failed on a system
		that was otherwise correct. The bus reflects the battery at the END of
		the step, not at the start of it.
	]]
	local hours = dt / 3600

	if state.alternatorOnline then
		--[[
			The alternator carries the load and puts the rest into the battery,
			up to what it can produce. The charge rate falls as the battery
			fills, which is why the ammeter swings hard positive after a start
			and settles toward zero - the behaviour that makes this gauge worth
			having.
		]]
		local room = clamp(1 - state.batteryChargeAh / Electrical.BATTERY_CAPACITY_AH, 0, 1)
		local spare = max(Electrical.ALTERNATOR_AMPS - demand, 0)
		local charge = math.min(spare, Electrical.ALTERNATOR_AMPS * 0.5 * room + 0.5)

		state.batteryChargeAh = math.min(
			state.batteryChargeAh + charge * hours,
			Electrical.BATTERY_CAPACITY_AH
		)
		state.ammeterAmps = charge
	elseif batteryAvailable then
		-- Everything is coming out of the battery.
		state.batteryChargeAh = max(0, state.batteryChargeAh - demand * hours)
		state.ammeterAmps = -demand
	else
		state.ammeterAmps = 0
	end

	-- ---- The bus, from the battery as it now stands -----------------------
	if state.alternatorOnline then
		state.busVolts = Electrical.SYSTEM_VOLTS
	elseif state.batteryMaster and state.batteryChargeAh > 0 then
		--[[
			A battery under load sags. Not modelled in detail - this is a
			trainer, not a battery bench - but a bus that reads 24 V flat until
			the instant it dies would tell the pilot nothing on the way down.
		]]
		local charge = clamp(state.batteryChargeAh / Electrical.BATTERY_CAPACITY_AH, 0, 1)
		state.busVolts = Electrical.BATTERY_VOLTS * (0.85 + 0.15 * charge)
	else
		state.busVolts = 0
	end
end

--[[
	Is a given consumer actually powered?

	The question the lights and the avionics ask. A switch that is ON with a
	dead bus is a switch that does nothing, which is the entire point of wiring
	item 8's lights to this rather than to a boolean.
]]
function Electrical.isPowered(state: State): boolean
	return state.busVolts > 1 and not state.breakerTripped
end

function Electrical.resetBreaker(state: State)
	state.breakerTripped = false
end

-- =========================================================================
-- VERIFICATION
-- =========================================================================

function Electrical.runTests(): (boolean, { any })
	local results = {}
	local allPassed = true

	local function record(label: string, passed: boolean, detail: string)
		if not passed then
			allPassed = false
		end
		table.insert(results, { label = label, passed = passed, detail = detail })
		print(string.format("  [%s] %-52s %s", passed and "PASS" or "FAIL", label, detail))
	end

	local function checkRange(label: string, actual: number, lo: number, hi: number, unit: string)
		record(label, actual >= lo and actual <= hi, string.format("%.2f %s (expected %.2f..%.2f)", actual, unit, lo, hi))
	end

	print("=== Electrical: verification ===")

	-- 1. The published figures ---------------------------------------------
	record(
		"A 28-volt system on a 24-volt battery with a 60 A alternator",
		Electrical.SYSTEM_VOLTS == 28
			and Electrical.BATTERY_VOLTS == 24
			and Electrical.ALTERNATOR_AMPS == 60,
		string.format("%d V / %d V / %d A, per the POH",
			Electrical.SYSTEM_VOLTS, Electrical.BATTERY_VOLTS, Electrical.ALTERNATOR_AMPS)
	)

	--[[
		Everything switched on at once must fit inside the alternator. If it did
		not, the aeroplane would discharge its battery in the cruise with
		nothing wrong - which would be a modelling error rather than a system.
	]]
	local everything = 0
	for _, amps in Electrical.LOADS do
		everything += amps
	end
	record(
		"Every load at once still fits inside the alternator",
		everything < Electrical.ALTERNATOR_AMPS,
		string.format("%d A of load against a %d A alternator", everything, Electrical.ALTERNATOR_AMPS)
	)

	-- 2. The alternator needs the engine AND both masters --------------------
	local state = Electrical.createState()
	record(
		"A stopped engine means no alternator, whatever the switches say",
		not Electrical.alternatorOnline(state, false, 0),
		"offline - it is belt-driven"
	)
	record(
		"Idling below cut-in is still not enough",
		not Electrical.alternatorOnline(state, true, 600),
		string.format("offline below %d rpm", Electrical.ALTERNATOR_CUTIN_RPM)
	)
	record(
		"A running engine above cut-in brings it on line",
		Electrical.alternatorOnline(state, true, 2000),
		"online at 2000 rpm"
	)

	--[[
		⚠️ THE ONE THAT IS A REAL PROPERTY OF THE AEROPLANE, and the reason the
		checklist turns BAT on before ALT: the alternator's field is excited
		from the bus, so with the battery master off it cannot bring itself on
		line however fast the engine is turning.
	]]
	local noBattery = Electrical.createState()
	noBattery.batteryMaster = false
	record(
		"The alternator cannot self-excite with the battery master off",
		not Electrical.alternatorOnline(noBattery, true, 2400),
		"offline - the field comes off the bus, which is why BAT goes on first"
	)

	-- 3. The ammeter ---------------------------------------------------------
	--[[
		The 172S's ammeter shows the RATE OF CHARGE, not the load. So it reads
		POSITIVE with the alternator on line and NEGATIVE on the battery alone,
		and that sign is the whole of what a pilot reads it for.
	]]
	local charging = Electrical.createState()
	charging.batteryChargeAh = Electrical.BATTERY_CAPACITY_AH * 0.5
	Electrical.update(charging, 1, true, 2400, { beacon = true, nav = true })
	record(
		"Alternator on line, the ammeter shows a charge",
		charging.ammeterAmps > 0,
		string.format("%+.1f A into a half-flat battery", charging.ammeterAmps)
	)
	checkRange("...and the bus is at system voltage", charging.busVolts, 27.9, 28.1, "V")

	local discharging = Electrical.createState()
	Electrical.update(discharging, 1, false, 0, { beacon = true, nav = true, landing = true })
	record(
		"Engine stopped, the ammeter shows a discharge",
		discharging.ammeterAmps < 0,
		string.format("%+.1f A out of the battery", discharging.ammeterAmps)
	)
	record(
		"...equal to what is switched on",
		math.abs(discharging.ammeterAmps + discharging.loadAmps) < 1e-9,
		string.format("%.0f A of load, %+.1f A on the ammeter", discharging.loadAmps, discharging.ammeterAmps)
	)

	--[[
		A full battery is not charged any harder than it needs. The rate falls
		as it fills, which is why the needle settles toward zero in the cruise
		instead of sitting pegged for the whole flight.
	]]
	local full = Electrical.createState()
	Electrical.update(full, 1, true, 2400, {})
	local halfFlat = Electrical.createState()
	halfFlat.batteryChargeAh = Electrical.BATTERY_CAPACITY_AH * 0.4
	Electrical.update(halfFlat, 1, true, 2400, {})
	record(
		"A flat battery charges harder than a full one",
		halfFlat.ammeterAmps > full.ammeterAmps,
		string.format("%+.1f A at 40%% against %+.1f A at full", halfFlat.ammeterAmps, full.ammeterAmps)
	)

	-- 4. Master off kills everything -----------------------------------------
	--[[
		THE CHECK THE BRIEF ASKED FOR BY NAME: master off kills the ammeter.
		And with it the bus, which is what the lights and avionics read.
	]]
	local off = Electrical.createState()
	off.batteryMaster = false
	off.alternatorMaster = false
	Electrical.update(off, 1, false, 0, { beacon = true, landing = true })
	record(
		"Master off kills the ammeter",
		off.ammeterAmps == 0,
		string.format("%.1f A", off.ammeterAmps)
	)
	record(
		"...and the bus, so nothing switched on is actually powered",
		off.busVolts == 0 and not Electrical.isPowered(off),
		string.format("%.1f V", off.busVolts)
	)

	--[[
		The avionics master isolates the radios and nothing else. It is not a
		second battery master, and conflating the two is the obvious way to get
		this wrong.
	]]
	local avionicsOff = Electrical.createState()
	avionicsOff.avionicsMaster = false
	Electrical.update(avionicsOff, 1, true, 2400, { beacon = true })
	record(
		"The avionics master drops the radios but leaves the bus up",
		avionicsOff.loadAmps == Electrical.LOADS.beacon and Electrical.isPowered(avionicsOff),
		string.format("%.0f A - the beacon only, bus still at %.0f V", avionicsOff.loadAmps, avionicsOff.busVolts)
	)

	-- 5. The battery runs down -----------------------------------------------
	--[[
		A finite battery is the entire reason the master switch matters. Left on
		with the lights, it must go flat in a believable time - a 13 Ah battery
		carrying 20 A is flat in about 40 minutes, and that arithmetic is the
		assertion.
	]]
	local draining = Electrical.createState()
	local drainSwitches = { beacon = true, nav = true, landing = true, taxi = true }
	local minutes = 0
	for _ = 1, 60 * 4 do
		Electrical.update(draining, 60, false, 0, drainSwitches)
		minutes += 1
		if draining.batteryChargeAh <= 0 then
			break
		end
	end
	local expected = Electrical.BATTERY_CAPACITY_AH / (Electrical.LOADS.beacon + Electrical.LOADS.nav
		+ Electrical.LOADS.landing + Electrical.LOADS.taxi + Electrical.LOADS.avionics) * 60
	checkRange("The battery goes flat in the time its capacity allows", minutes, expected - 2, expected + 2, "min")
	record(
		"...and a flat battery is a dead bus",
		not Electrical.isPowered(draining),
		string.format("%.2f Ah left, bus %.1f V", draining.batteryChargeAh, draining.busVolts)
	)

	-- 6. Breakers ------------------------------------------------------------
	record(
		"The breaker limit is derived from the loads it protects",
		Electrical.breakerLimitAmps() == everything + Electrical.BREAKER_HEADROOM_AMPS,
		string.format("%.0f A against %.0f A of total load", Electrical.breakerLimitAmps(), everything)
	)

	--[[
		A breaker protects the wire, so it must NOT trip on every load the
		aeroplane can legitimately switch on at once. A breaker that popped
		during a normal night takeoff would be a modelling error.
	]]
	local allOn = Electrical.createState()
	Electrical.update(allOn, 1, true, 2400, {
		beacon = true, nav = true, strobe = true, taxi = true, landing = true, pitotHeat = true,
	})
	record(
		"Everything on at once does NOT trip a breaker",
		not allOn.breakerTripped,
		string.format("%.0f A carried against a %.0f A limit", allOn.loadAmps, Electrical.breakerLimitAmps())
	)

	--[[
		A FAULT is the only thing that can legitimately exceed the panel, which
		is what the fault current exists for. The first version of this test
		inflated LOADS.beacon instead - and that moved the breaker limit, which
		is DERIVED from LOADS, so the limit rose with the fault and nothing ever
		tripped. Testing a threshold by changing the thing the threshold is
		computed from proves nothing.
	]]
	local faulty = Electrical.createState()
	Electrical.update(faulty, 1, true, 2400, { beacon = true }, Electrical.breakerLimitAmps() + 10)
	record(
		"An overload trips the breaker and it STAYS tripped",
		faulty.breakerTripped and faulty.loadAmps == 0,
		string.format("tripped at %.0f A of fault, now carrying %.0f A", Electrical.breakerLimitAmps() + 10, faulty.loadAmps)
	)
	--[[
		And it stays tripped through a step with no fault at all - that is the
		difference between a breaker and a thermal cut-out that resets itself.
	]]
	Electrical.update(faulty, 1, true, 2400, { beacon = true })
	record(
		"...through a later step with the fault gone",
		faulty.breakerTripped and faulty.loadAmps == 0,
		"still open"
	)
	Electrical.resetBreaker(faulty)
	record(
		"...until the pilot resets it",
		not faulty.breakerTripped,
		"reset"
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

return Electrical
