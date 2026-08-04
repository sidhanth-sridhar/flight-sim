# Flight Simulator — Developer Handoff

**Read this first.** It is the source of truth for continuing development.

---

## 0. Resume here — state at 2026-08-04

**All 282 checks green across 10 suites.** Nine run in **Play mode, Client datamodel**; `AircraftService` runs in the **Server** datamodel (see §4).

**The mouse is now PTFS-style**: free cursor, position = deflection, inverted. See §6g — including the GUI-inset trap, which would otherwise have baked in a permanent nose-up bias.

**The aircraft now taxis, rotates and flies** — verified with real keyboard and mouse input, not just tests. Measured: 0 → 65.9 kt in 340 m of ground roll, rotation at 56 kt, climb to 45 m. Holding full back-stick then produced a genuine stall, wing drop and spiral departure, which is the model behaving correctly rather than a fault.

**A bug that made the whole simulator look dead was found and fixed** — the tyres were glued to the runway. See §6f. It predated the server migration and was not caused by it; it had simply never been exposed, because nobody had taxied before.

**Committed** through the PTFS control change; the working tree is clean.

**Phase 1 remaining**: the raw-numbers debug HUD (IAS, altitude, AoA, G-load, thrust, force vectors — no gauges). Then the flight gate — taxi, take off, coordinated turn, deliberate stall, recover, land — which the pilot flies before Phase 2.

**Verified live this session, not just in tests**: the server spawns the aircraft, grants the client network ownership, the client adopts it and runs the frame loop, and boarding moves the aircraft **0.000 m**. Getting to that last number took three fixes — see §6e, because two of them are not obvious and both were found by measuring rather than reasoning.

**Open questions for the pilot**, none blocking:
- **No reset-aircraft key.** Requesting a spawn replaces your existing aircraft, so the recovery path from an aeroplane on its back is currently *die, or respawn from the Roblox menu*. Binding a key is a one-line change but the bindings are yours — say which key.
- Pause (P) is a stopgap that zeroes control forces; it is not a real pause and probably should not be bound until designed.
- The `Controls/` vs `Controllers/` folder split is deliberate for now — the rename was flagged as a separate task.
- Aircraft park 30 m south of the spawn pad, which is a short walk. §6e says why they cannot park on it.

---

## 1. What this project is

A realistic Roblox flight simulator built around a genuine per-surface aerodynamics model, not an arcade approximation. The goal is that the aircraft *feels* like an aircraft because the physics is actually right — stalls, roll damping, adverse yaw and the region of reverse command all emerge from the model rather than being special-cased.

The first aircraft is a Cessna 172S, chosen because it is slow, forgiving, and has extensively published performance data to validate against.

---

## 2. Locked architecture decisions

These were decided deliberately and are expensive to reverse. Do not change them without explicit discussion.

| Decision | Choice | Why |
|---|---|---|
| **Physics authority** | Client-owned. Aerodynamic forces applied via `VectorForce` + `Torque`; network ownership goes to the pilot's client. | At 120 kt, a server round-trip between mouse input and response makes precise flying impossible. Server owns *state* (fuel, spawns, damage) and does loose position sanity checks only. |
| **World scale** | 1 stud = 1 metre. `Workspace.Gravity = 9.80665`. | Roblox's default 196.2 studs/s² would make a metre-scale aircraft fall 20× too hard — equivalent to running the whole sim ~4.5× too fast. |
| **Aero model** | Per-surface strip theory. Wing split into left/right panels. | Gives roll damping, asymmetric stalls, pitch stability and adverse yaw *for free*. A whole-aircraft model can never produce these. |
| **Source of truth** | **Files**, via Rojo. | See §3. |

---

## 3. Workflow — read carefully

**Rojo syncs one-way: files → Studio.** There is no sync back.

- Edit files in `src/`. **Never** edit scripts inside Studio — they are overwritten on the next sync.
- Anything present in Studio but absent from `src/` gets **deleted** from Studio when Rojo syncs a managed folder.
- Studio is for *running tests and flying*, not authoring.
- `default.project.json` manages only the three `FlightSim` folders, plus `Workspace.Baseplate` and `Lighting`. `Workspace.World` is **not** version-controlled yet — worth adding before Phase 3.

**Studio MCP tools** (if available) should be used only to run test suites, inspect state, and start/stop Play. Not to edit scripts.

⚠️ **`require` caches per Studio session.** After editing a module, re-running `runTests()` in the same session gives you the *stale* copy. Restart the session, or clone the module tree to a temp folder and require the clone.

⚠️ **Rojo will not reconcile a subtree whose root instance it did not create.** Solved 2026-08-03; two wrong diagnoses were recorded first, so read this before theorising.

The symptom: `Controls/InputController.luau` existed on disk and Rojo's *served* tree contained it, yet it never appeared in Studio, while new files under `ReplicatedStorage` synced instantly.

The cause: `StarterPlayerScripts.FlightSim` was hand-created in Phase 0. Rojo does not own that instance, so it silently refuses to patch anything beneath it. The stale `Controllers` / `UI` folders sitting in Studio but absent from `src/` were the visible tell — had Rojo owned that subtree it would have deleted them.

**The fix: delete the offending folder in Studio and let Rojo recreate it.** Everything under it is reproducible from `src/`, so nothing is lost. It reappeared complete, with `Controls/InputController` present, within a second.

**Diagnosing this class of problem** — establish which side is broken before touching anything:
```bash
rojo build default.project.json -o probe.rbxlx && grep -c YourModule probe.rbxlx
curl -s http://localhost:34872/api/rojo                  # msgpack, but names are readable
curl -s http://localhost:34872/api/read/<rootInstanceId> | grep -c YourModule
```
If the served tree contains the module, the server is fine and the plugin is the problem. Do not restart anything until you know which.

**Two theories that were wrong, recorded so they are not re-tried:**
- *"It's OneDrive eating file notifications."* It failed identically with OneDrive stopped.
- *"`StarterPlayerScripts` needs an explicit `$className`."* It does not — Rojo already inferred the correct class, verified by diffing builds from before and after. The explicit `$className` now in `default.project.json` is conventional and harmless, but it fixed nothing.

A `tools/srcserve.js` HTTP workaround existed briefly and is **retired — do not use it.**

---

## 4. Current state

### Verified green (282 checks total)

| Module | Path | Checks | Datamodel |
|---|---|---|---|
| `Atmosphere` | `Physics/Atmosphere.luau` | 17/17 | Client |
| `Aerodynamics` | `Physics/Aerodynamics.luau` | 29/29 | Client |
| `Engine` | `Physics/Engine.luau` | 23/23 | Client |
| `Cessna172` | `Aircraft/Definitions/Cessna172.luau` | 26/26 | Client |
| `AircraftBuilder` | `Aircraft/AircraftBuilder.luau` | 20/20 | Client |
| `FlightModel` | `Physics/FlightModel.luau` | 34/34 | Client |
| `GroundHandling` | `Physics/GroundHandling.luau` | 25/25 | Client |
| `InputController` | `StarterPlayer/.../FlightSim/Controls/InputController.luau` | 67/67 | Client |
| `FlightController` | `StarterPlayer/.../FlightSim/Controllers/FlightController.luau` | 13/13 | Client |
| `AircraftService` | `ServerScriptService/FlightSim/Services/AircraftService.luau` | 28/28 | **Server** |

```lua
require(game.ServerScriptService.FlightSim.Services.AircraftService).runTests()   -- Server datamodel
```

⚠️ **Run the suites in PLAY mode, not Edit.** `require` caches per session, and the Edit session accumulates stale copies as modules are edited — a module edited after it was first required will keep serving the old copy for the rest of the session, which shows up as `attempt to call a nil value` on a function you can see in the file. Entering Play creates a fresh DataModel with a clean cache. Use `datamodel_type: "Client"`; the server has no `UserInputService` and cannot load `InputController`.

Also built and working: `Constants`, `MathUtil`, `Signal`, `Units`, `Remotes` (12-entry manifest), and both server/client bootstraps. A live boot logs gravity 9.80665, 12 remotes created, sea-level density 1.2250.

### AircraftBuilder — now verified (2026-08-03)

`Aircraft/AircraftBuilder.luau` passes 20/20. The two outstanding fixes were confirmed correct when finally executed:

1. **Centre-of-mass frame mismatch.** Roblox reports `AssemblyCenterOfMass` relative to the **root part**; the definition measures offsets from a **datum**. They are different origins. Fixed by storing a `DatumOffset` attribute on the root at build time and converting in `measure()`.
2. **Cylinder volume.** Roblox computes mass from *true geometric* volume, not the bounding box — a cylinder is only π/4 of its box, so wheels came out 21% light. Fixed with a `SHAPE_VOLUME_FACTOR` table.

Nothing is currently unverified. Phase 1 is four modules from complete: `FlightController`, `AircraftService`, the debug HUD, and then the flight gate.

### Real physics results achieved so far

All emergent from honest coefficients — none of these were tuned to hit a target:

- Max level speed **130 kt** (published ~126)
- Rate of climb at Vy **783 ft/min** (published 730)
- Glide ratio power-off **9.9:1** (published ~9)
- Clean stall **52.9 kt**, full flap **45.4 kt** (published 48 / 40)
- Static margin **+16% MAC** — solidly stable
- Static thrust **2780 N**, endurance **5.5 h**, burn **27.9 kg/h**

---

## 5. Conventions that matter

**Coordinate system** — Roblox body axes, metres:
```
-Z forward (nose)    +X right (starboard)    +Y up
```

**Three distinct frames — most bugs live here:**
- **Datum**: arbitrary reference near the cabin centre. All definition offsets use this.
- **Root part**: what Roblox measures from. Offset from datum by `root:GetAttribute("DatumOffset")`.
- **Centre of mass**: what moment arms must be measured from. Computed by Roblox from the part layout.

**Units**: physics modules are pure SI (metres, m/s, kg, newtons, radians). Studs and knots appear only at the boundaries, converted via `Shared/Units`. The physics never sees knots; the instruments never see newtons.

**Testing**: every module carries its own `runTests()` returning `(allPassed, results)` and printing a PASS/FAIL table. Tests assert against *published real-world aircraft data*, not against whatever the code currently produces. When a test fails, first determine whether the code or the assertion is wrong — twice already the assertion was the wrong one.

---

## 6. `FlightModel` — built and green (2026-08-03)

`src/ReplicatedStorage/FlightSim/Physics/FlightModel.luau`, 34/34.

**API**
```lua
local state = FlightModel.new(model, definition)   -- caches geometry at spawn
FlightModel.step(state, dt, controls, environment) -- once per frame, pilot's client
FlightModel.release(state)                         -- zero the constraints
FlightModel.recomputeGeometry(state)               -- only if mass layout changes
```

`controls` is `{ pitch, roll, yaw, throttle, flaps, brake }` — pitch/roll/yaw in −1..1, positive = nose up / roll right / nose right. `environment` is `{ windVelocity, tempOffsetC }`, both optional. Live numbers for the HUD are in `state.telemetry` (IAS, TAS, altitude, α, β, load factor, thrust, rpm, fuel, per-surface α/CL/CD).

**The split that matters**: `computeForces(state, kinematics, dt, controls, env)` is pure — it reads nothing from the datamodel. `step()` only gathers kinematics off the assembly, calls it, and writes the constraints. That is what lets the tests assert on pitch stability, roll damping and weathervaning without Roblox simulating anything, and it is worth preserving.

**Deliberately not in this module**: gravity (Roblox applies it), ground handling, and input.

## 6b. `GroundHandling` — built and green (2026-08-03)

`src/ReplicatedStorage/FlightSim/Physics/GroundHandling.luau`, 25/25.

```lua
local gear = GroundHandling.new(model, definition)
local f, t = GroundHandling.computeForces(gear, kinematics, dt, controls, liftVertical)
```

Roblox's solver already gives us *contact* — the aircraft rests and rolls on real collidable wheels. What it cannot give us is *tyre* behaviour: Roblox friction is isotropic, so without this module the aircraft slides across the runway like a curling stone. It supplies three things Roblox will not: lateral grip, rolling resistance and brakes, and nose-wheel steering.

**`liftVertical` is not optional in spirit.** Every gear force scales with `weight − lift`, so passing 0 leaves the aircraft braking and steering at full authority right up to rotation. Pass the vertical component of the aero force computed the same frame.

**Steering is a cornering force at the nose wheel, not a commanded yaw rate.** The yaw emerges from `r × F`. That is what makes steering authority fade as lift unloads the nose wheel and vanish entirely when it lifts — handing over to the rudder exactly when it should. `Cessna172.gear.steeringRate` was replaced by `steeringAuthority` (fraction of available grip at full pedal) and `tyreFriction` for this reason.

### Wiring it up (the FlightController's job)
`FlightModel.applyForces` **overwrites**, it does not accumulate. Sum both contributors and write once:
```lua
local k = FlightModel.readKinematics(fm)
local fa, ta = FlightModel.computeForces(fm, k, dt, controls, env)
local fg, tg = GroundHandling.computeForces(gear, k, dt, controls, fa.Y)
FlightModel.applyForces(fm, fa + fg, ta + tg)
```

## 6c. `InputController` — built and green (2026-08-03)

`src/StarterPlayer/StarterPlayerScripts/FlightSim/Controls/InputController.luau`, 56/56 — passed on its first execution once the Rojo subtree problem in §3 was solved.

```lua
local ic = InputController.new(definition, overrides?)
local controls, systems = InputController.update(ic, dt, snapshot, flightState?)
local snapshot = InputController.poll(ic, mouseDelta)   -- the only impure call
InputController.rebind(ic, action, keyCode)
```

**The Controls contract is untouched.** `state.controls` carries exactly the six fields `FlightModel` declares, with the same signs, and a test asserts there are no extra keys — so it passes straight to `FlightModel`/`GroundHandling` with no edit to either.

**New state went into a separate `state.systems` struct**, not into `Controls`: `engineCommanded`, `cameraHold`, `altitudeHold`, `altitudeTargetM`, `gearDown`, `paused`, `viewIndex`, `mouseMode`. `Controls` is a physics contract where every field is a number the aerodynamics consumes; putting booleans in it would mean FlightModel's type no longer describes what FlightModel reads. `engineCommanded` is a *commanded* state — FlightController wires it to `Engine.start`/`stop`.

**`update()` is pure**, taking a snapshot of held ACTION names rather than reading `UserInputService`. That is what makes ramps, edge-triggered detents and the altitude-hold law testable at all. Edge detection lives inside `update()` (it keeps `wasHeld`), so callers pass held-state only.

**Altitude hold is a cascade**: altitude error → demanded vertical speed → pitch command. Commanding pitch straight from altitude error gives a phugoid that never settles; the inner vertical-speed loop is what damps it. Manual pitch past `disconnectThreshold` disconnects it, as a real autopilot does.

**Mouse is inverted as specified** — pointer forward → nose down. Roblox reports `Delta.Y < 0` when the mouse moves forward and pitch is positive-nose-up, so the accumulation needs *no negation anywhere*. Both directions are asserted separately because this is the likeliest thing in the file to be wrong.

### Review of the three reported bugs (2026-08-03)

1. **`viewIndex` grew unbounded** — real, fixed. Now wraps within `config.viewCount` (3: cockpit/chase/free) so the camera system can index straight into its view list. **The count is an assumption**; correct it when the camera system lands.
2. **`RecenterStick` "should return to neutral controls"** — *half* real. It now also clears the `smoothDamp` velocities, so the controls settle at neutral instead of coasting through and returning from the far side. But it deliberately **does not clear trim**: recentring the stick means letting go of it, and a trimmed aircraft with the stick released holds its trimmed attitude — that is what trim is *for*. Clearing it would pitch the aircraft the moment the pilot tidied their controls. That part was a realism choice, not a bug.
3. **Altitude hold engaged and disconnected on the same frame** — real, and the worst of the three. Fixed by capturing the stick position at engagement and disconnecting on *movement away from it*. See §7 for why absolute deflection cannot work in Direct mouse mode.

### Bindings
Pilot-specified (do not change): **W/S** throttle ramp, **A/D** rudder, **F/G** flap detents down/up, **C** camera hold, **R** altitude hold, **E** engine toggle, mouse = pitch/roll.

Chosen here, open to review: **B** brake, **V** cycle view, **, / .** trim down/up, **L** gear (G was taken; inert on the fixed-gear 172), **P** pause.

**X and M were removed** when the yoke became absolute — see §6g.

**C is momentary** (held only while down); **R latches**. Bindings live in `InputController.DEFAULT_BINDINGS` and are overridable per player via `rebind()`, which is what the settings menu will drive. A test asserts no two actions share a key.

### The complete frame loop `FlightController` has to write

Every piece below already exists and is tested. This is the whole of it:

```lua
local snapshot = InputController.poll(ic, mouseDelta)          -- mouseDelta from UIS
local controls, systems = InputController.update(ic, dt, snapshot, {
    altitude = fm.telemetry.altitude,
    verticalSpeed = fm.telemetry.verticalSpeed,
})

if systems.engineCommanded ~= fm.engine.running then           -- E is a COMMAND
    if systems.engineCommanded then Engine.start(fm.engine, def.engine)
    else Engine.stop(fm.engine) end
end

local k = FlightModel.readKinematics(fm)
local fa, ta = FlightModel.computeForces(fm, k, dt, controls, env)
local fg, tg = GroundHandling.computeForces(gear, k, dt, controls, fa.Y)
FlightModel.applyForces(fm, fa + fg, ta + tg)                  -- ONCE. It overwrites.
```

Order matters in two places: `flightState` for altitude hold comes from *last* frame's telemetry (it is the only thing available at that point in the frame, and one frame of lag is invisible), and `GroundHandling` needs `fa.Y` so it must run after the aerodynamics.

`systems.cameraHold` / `viewIndex` belong to the Phase 2 camera system; `paused` and `gearDown` have no consumer yet.

## 6d. `FlightController` — built and green (2026-08-03)

`src/StarterPlayer/StarterPlayerScripts/FlightSim/Controllers/FlightController.luau`, 13/13. Exposes `Init()`, started by `Init.client.luau` via `CONTROLLER_ORDER`.

It owns only sequencing and lifecycle. `stepFrame(rig, dt, snapshot)` is factored out of the Roblox event plumbing so the ordering can be tested directly — the loop itself is four lines.

**Confirmed working end to end in Play**: the bootstrap starts it, the aircraft builds, sitting in the seat starts the loop.

**Deviation from the plan in §6c**: `flightState` for altitude hold is taken from *this* frame's `readKinematics`, not last frame's telemetry. `readKinematics` is cheap and pure, so there was no reason to accept a frame of lag.

⚠️ **`InputController` is NOT started by the bootstrap.** It sits in `Controls/`, has no `Init()`, and is a library this controller drives. `CONTROLLER_ORDER` lists its name but the loader only scans `Controllers/`, so it is skipped silently. Do not "fix" that path — the folder rename is a separate task.

### Things this controller decides, open to review
- **Spawn at `CFrame.new(0, 100, 0)`** as specified, so the aircraft free-falls onto the baseplate before anyone reaches it. `CFrame.new(0, 1.30, 0)` parks it on the ground instead — one constant, `SPAWN_CFRAME`.
- **Mouse is locked to centre while seated**, released on exit. `GetMouseDelta()` returns zero unless the mouse is locked, so without this the yoke is simply dead. The camera system may want to take this over.
- **Input is dropped while a text box is focused**, or typing "was" in chat flies the aircraft.
- **Pause zeroes the constraints** rather than leaving the last force applied, which would accelerate the aircraft indefinitely. This is a stopgap, not a real pause — Roblox keeps simulating, so the aircraft becomes an unpowered glider. Pause needs a design decision before it is worth binding.

## 6e. `AircraftService` — built and green (2026-08-04)

`src/ServerScriptService/FlightSim/Services/AircraftService.luau`, 28/28. Started automatically by `Init.server.luau`, which already scanned a `Services/` folder that did not exist until now.

```lua
AircraftService.spawn(owner: Player?, id: string?) -> (Model?, reason: string?)
AircraftService.despawn(model) / despawnFor(player) / despawnAll()
AircraftService.getAircraft(player) -> Model?
AircraftService.evaluate(position, speed) -> reason?   -- pure
AircraftService.checkSanity(model) -> reason?
```

**The split**: the server owns *which aircraft exist and who owns each one*; the client still owns *every force, every frame*. Nothing about client-owned physics changed. What changed is that the aircraft is now a real replicated instance instead of one that existed only inside one client.

**Ordering that matters**: `SetNetworkOwner` happens **before** `AircraftAssigned` is fired. Forces written to an assembly this client does not own are discarded by the engine with no error and no motion — indistinguishable from broken aerodynamics. The server verifies the handover with `GetNetworkOwner()` and warns; a client-side check is impossible because **`BasePart:IsNetworkOwner()` does not exist on the client** (confirmed: *"IsNetworkOwner is not a valid member of Part"*). If the controls do nothing at all, read the server log before suspecting the physics.

**One adoption path on the client.** `RequestSpawnAircraft` returns only `(accepted, reason)`; the aircraft itself always arrives on `AircraftAssigned`. Requesting again *replaces* the player's aircraft, which is what makes it double as a reset.

**A shared `Aircraft/Registry.luau`** maps `id -> definition`. The id is the only thing that crosses the network; the server stamps it on the model and the client reads it back off the attribute, so both sides resolve the same definition without the client assuming it got what it asked for.

### Three fixes that boarding needed, all found by measuring

Boarding a server-spawned aircraft threw it across the apron. The number to watch is the displacement of a parked aeroplane when the pilot sits down: **12.32 m → 7.84 m → 0.000 m**.

1. **Aircraft park 30 m from the origin.** `Workspace.SpawnLocation` is a 12×12 m pad whose top face is at **y = 1.00**, and slot 0 was dead centre on it — so the aeroplane rested a metre up on a ledge it had to roll off, and the player materialised *inside* it. First observed live spawn: a character appearing on top of a parked 1,111 kg aircraft shoved it 4.5 m.
2. **Pilots and aircraft do not collide** (`Aircraft` / `Pilot` collision groups). `Sit()` welds the character into the assembly, but for the frame *before* the weld exists it is a separate rigid body teleported inside a 1.5 m cabin, and Roblox resolves that interpenetration explosively. The client's existing neutralisation runs on Occupant-changed — after the weld, one frame too late. **The trade**: a player can walk through a parked aircraft and cannot stand on the wing.
3. **A seated pilot collides with nothing at all** (`PilotSeated` group). Fixing 2 removed the explosion but left the aircraft floating 5.6 m up. Once welded in, the character's root part sticks out through the cabin floor, and **the Humanoid forces `HumanoidRootPart.CanCollide` back to true every frame** — so neither side can switch it off and make it stay off. The runway pushed on that root part and, since it was now rigidly part of the aeroplane, jacked the whole aeroplane into the air. A seated pilot is cargo; the assembly does the colliding for them.

Server-side `Massless` is set on seated characters too, so the server and the client agree the aircraft weighs 1,111 kg rather than 1,122 kg.

### Things this service decides, open to review
- **Warn-only limit checks.** `Constants.LIMITS` are generous (400 m/s, 20 km), so anything tripping them in Phase 1 is far more likely to be our own physics bug than a cheating client, and deleting the pilot's aircraft mid-test destroys the evidence. `ENFORCE_LIMITS = false` flips it.
- **Spawn slots** alternate ±18 m about the apron and are reclaimed on despawn. Occupancy is checked against the *world*, not just our bookkeeping — see §7 for the Studio-specific reason that matters.
- **Only the owner may board.** A second player sitting in your aircraft would be sitting in an assembly simulated on your machine, with their own client's forces being discarded.

## 6f. The tyres were glued to the runway (fixed 2026-08-04)

**Symptom**: the pilot boards and nothing works. No pitch, no roll, no yaw, no movement. It looks exactly like dead controls or broken aerodynamics, and there is no error anywhere.

**It was neither.** The input chain was perfect and the flight model was perfect. Measured with real key presses on a live aircraft: E started the engine (0 → 377 N idle), W ramped to full thrust (2,780 N), D produced a 2,367 N·m yaw moment. Every number was right. The aeroplane simply did not move — 0.000 m/s with full power applied.

**Cause**: the wheels shipped with `friction = 0.6`, which Roblox combines with a default runway to about **0.45**. Static thrust is 2,780 N against a weight of 10,895 N, so the aircraft can only break traction below **μ = 2780 / 10895 = 0.255**. It was pinned by static friction with roughly twice the grip the propeller could overcome.

**Fix**: wheels are now `friction = 0`, `frictionWeight = 100`. `GroundHandling` already models rolling resistance, brakes, lateral grip and nose-wheel steering as real forces — that is the entire reason it exists (§6b) — so Roblox's isotropic contact friction was both double-counting and swamping it.

**`frictionWeight` matters as much as `friction`**, and this cost a wrong diagnosis. Roblox combines two surfaces as `(f1*w1 + f2*w2) / (w1 + w2)`. The first attempt set wheel friction to 0 with weight 0, which just handed the whole combination to the runway and changed nothing — it looked like friction had been ruled out. Weight 100 makes the tyre dominate, so behaviour is the same on any surface.

Measured, same aircraft, same thrust:

| wheel friction / weight | result |
|---|---|
| 0.6 / 1 (as shipped) | **0.00 m — immovable** |
| 0.0 / 0 (the botched test) | 0.00 m — runway friction still applied |
| 0.0 / 100 | 13.9 m in 2.5 s, accelerating normally |

**Regression test**: `Cessna172.runTests()` now asserts *"Static thrust can break the tyres loose"*, computing the worst-case combined μ against a deliberately grippy 0.5 runway and requiring the thrust to exceed it. It reports μ 0.005 needing 54 N against 2,780 N available, and would have failed at the old value (μ 0.55, 5,992 N needed).

**Diagnostic order that worked**, worth reusing: confirm the force reaches the constraint → confirm the client owns the assembly → **apply the force in free air**. That last step is what cracked it: in mid-air the same 2,780 N produced −2.33 m/s² against −2.50 predicted, proving the force, the ownership and the flight model were all fine and the fault was in ground contact alone.

## 6g. PTFS-style free-mouse controls (2026-08-04)

The relative yoke is gone. The cursor is **free on screen and visible**, and its POSITION is the control deflection: centre is neutral, the edges are full travel. Inverted, as specified — pointer forward pitches the nose down.

**What replaced what.** The old scheme locked the cursor to centre and accumulated `GetMouseDelta()` into a virtual stick (`state.stickX/stickY`) with Direct and Centering modes. All of that is deleted. There is now no stick state between frames at all, which is the point: the controls can never disagree with the cursor the pilot can see.

```lua
InputController.poll(state, pointer, viewportSize)  -- caller supplies both
InputController.neutralSnapshot()                   -- hands off the yoke
```

`InputSnapshot` carries `pointer` and `viewportSize` in raw pixels rather than a pre-normalised offset, so `update()` still owns the whole mapping — centre, deadzone, expo, inversion, clamping — and stays pure and testable with plain numbers. **The Controls contract is untouched**: the same six fields, same signs, same ranges.

### Decisions the pilot made
- **Full deflection at the screen edge, per axis.** Roll normalises against half the width, pitch against half the height, so on 16:9 roll is ~1.8× less sensitive per pixel than pitch. Deliberate, and matches PTFS.
- **X and M removed.** There are no mouse modes left, and Roblox exposes no API to warp the cursor, so "recentre the stick" could only have lied about where the pointer is. Recentring is now what it is in PTFS: move the mouse to the middle. `systems.mouseMode` is gone with them.
- **Typing releases the yoke.** With a free cursor, reaching for the chat box would otherwise command hard nose-up and full left roll. `FlightController` sends `neutralSnapshot()` while a text box is focused. Trim is untouched, so a trimmed aircraft holds its attitude exactly as it would hands-off.

### The GUI inset, which is the trap in this file
`GetMouseLocation()` and `Camera.ViewportSize` are **not** in the same coordinate space. The viewport includes the strip behind Roblox's top bar; the mouse does not. Comparing one against the other puts "centre" half the inset too low — about 18 px on a 1080p screen, a few percent of permanent nose-up that reads as a mistrimmed aircraft and that nobody would think to blame on a coordinate space.

`FlightController.readPointer()` therefore reduces both to the usable area, `ViewportSize - GetGuiInset()`.

**Verified rather than assumed**, and worth knowing how, because the obvious tests are inconclusive: a 20 px tall Frame at GUI y 300..320 is found by `GetGuiObjectsAtPosition(700, 310)` and **not** at `(700, 368)`. Since that function shares its coordinate space with `GetMouseLocation()`, the mouse is proven to be in inset-respecting GUI space. Live probe confirms it: cursor at (663, 392) on a 1326×783 usable area gives exactly `roll +0.000, pitch +0.000`.

### Verified live
Real cursor, real code, all four quadrants:

| cursor vs centre | result |
|---|---|
| right and below | roll **+0.201**, pitch **+0.085** (right, nose up) |
| left and above | roll **−0.234**, pitch **−0.115** (left, nose down) |
| dead centre | roll **+0.000**, pitch **+0.000** |

And in flight: a cursor offset of +0.144 (mild nose-up) held pitch torque steadily positive through the takeoff roll, +1722 → +2670 N·m, rotating at ~70 kt. `MouseBehavior` stays `Default` and `MouseIconEnabled` true for the whole flight.

### Tests
`InputController` went 65 → 67. Removed as meaningless: the two mouse-mode tests and the three X-recentre tests. Added: centre is neutral, returning to centre releases the controls, deflection is proportional to distance, off-screen clamps at full travel, **axes normalise independently** (270 px gives roll 0.180 but pitch 0.359 — the test that would catch the two axes being collapsed onto one radius), deadzone is exactly neutral, a neutral snapshot releases the yoke without clearing trim, and a half-screen offset commands the shaped value end to end.

### Then
Debug HUD — raw numbers only: IAS, altitude, AoA, G-load, thrust, force vectors. **No pretty gauges yet.** This is the diagnostic tool for tuning and where bugs actually get found.

**Phase 1 test gate**: taxi, take off, coordinated turn, deliberate stall, recover, land — on the flat baseplate. Do not proceed to Phase 2 until the user has flown it and signed off.

---

## 7. Gotchas already discovered — don't rediscover these

- Roblox density is capped at **100**. At metre scale that means 100 kg per m³ of bounding box. An 1111 kg aircraft needs ≥11.1 m³ of parts. `AircraftBuilder.validate()` hard-errors on violations, because the silent failure mode is an aircraft that's too light and flies like a balloon.
- `VectorForce.ApplyAtCenterOfMass = true` is required. Without it, force acts at the attachment position and injects a phantom pitching moment that scales with thrust.
- `VehicleSeat` gives automatic network-ownership transfer to the occupant — that's why it's used. Its own `MaxSpeed`/`Torque`/`TurnSpeed` must be zeroed or Roblox applies steering torques on top of the aerodynamics.
- Parasitic drag must sit **outside** the stall-separation blend. Blending it away means a surface in exactly reversed flow produces zero drag and coasts forever.
- The stall blend is centred ~3° *beyond* `alphaStall`, so peak CL occurs *at* the stated stall angle. Centring it on `alphaStall` puts CL_max several degrees early and well below the real value.
- When splitting a wing into panels: halve the **area**, keep the **full wing's aspect ratio**. Induced drag depends on total span. Getting this wrong roughly doubles induced drag and the aircraft mysteriously won't climb.
- **The thrust line is BELOW the centre of mass**, by about 0.28 m — the high wing and its fuel carry the balance point above the propeller shaft. So power produces a nose-**up** moment ("power up, nose up"), which is correct for a high-wing Cessna. A comment in the definition claimed the opposite for a while; the sign is now asserted by `FlightModel.runTests()` rather than trusted to prose.
- **A `runTests()` that errors mid-suite leaks its rig into the workspace**, and in Studio that debris survives into the next Play session — where a leftover aircraft looks exactly like a double-spawn bug. It cost real time to diagnose once. `FlightController.runTests` now wraps its body in a `pcall` and destroys the rig either way; **`AircraftBuilder`, `FlightModel` and `GroundHandling` still destroy on the last line and have the same flaw.** If a Play session shows more aircraft than expected, clean `workspace` in *Edit* first.
- **Altitude hold disconnects on stick MOVEMENT, not absolute deflection.** In Direct mouse mode the stick holds wherever it was put, so testing absolute deflection meant a pilot flying with real pitch input would press R and have it engage and disconnect on the same frame — a dead key with no feedback. The reference position is captured at engagement.
- **Cross-product order for the lateral axis.** `rollDir:Cross(groundNormal)` points to the aircraft's right; `groundNormal:Cross(rollDir)` points left. Getting it backwards inverts nose-wheel steering and the reported skid direction *without* breaking lateral grip, because grip is sign-symmetric — so the tests that would catch it are the steering ones, not the friction ones. This was caught on the first `GroundHandling` run.
- **Roblox friction can pin an aircraft to the runway, and it looks like dead controls.** Effective μ must stay below thrust/weight (0.255 for the 172) or full power moves it 0.00 m. Tyre friction belongs to `GroundHandling`, not to Roblox — see §6f. **`frictionWeight` is half the story**: surfaces combine as `(f1*w1 + f2*w2)/(w1+w2)`, so friction 0 at weight 1 still inherits half the runway's grip.
- **"The controls do nothing" is not evidence that input or aerodynamics is broken.** Both were provably fine in §6f. Before touching either, apply the force with the aircraft in **free air** — if it accelerates correctly there, the fault is in ground contact, and that one test skips the entire search.
- **Dying respawns your aircraft**, by design (`FlightController` requests a new one on `Humanoid.Died`). During a crash the old model is despawned and a new one spawned, so anything holding a reference to `workspace.Aircraft:GetChildren()[1]` can momentarily find nothing. That is the designed reset, not a despawn bug — it cost time to re-derive once.
- **Studio's command bar has its OWN module cache, separate from the running server's.** `require(SomeService)` from the command bar returns a *second copy* of the module with its own state — its `Init()` has never run, and its bookkeeping tables are empty. This is why `AircraftService.runTests()` reported "0 active" while a live aircraft sat in the workspace, and why its first test spawn tried to park on top of that live aeroplane. Slot occupancy is therefore checked against the world, and `runTests()` registers its collision groups itself.
- **Roblox sanitises NaN inside property setters.** A NaN velocity is stored as `(0, 0, 0)` and a NaN CFrame position as `y = -1,000,000`. So a NaN check cannot be tested through the datamodel — the assertion would only prove Roblox scrubs NaN. Test the pure predicate directly. (The −1,000,000 does trip the altitude floor, so a position that has gone numerically bad is still caught.)
- **`BasePart:IsNetworkOwner()` does not exist on the client** — *"IsNetworkOwner is not a valid member of Part"*. A client-side ownership check is dead code that silently never fires. Verify with `GetNetworkOwner()` on the server. (`ReceiveAge == 0` is the usable client-side hint, and was used to confirm the handover by hand.)
- **The Humanoid forces `HumanoidRootPart.CanCollide = true` every frame.** You cannot make a seated pilot non-collidable by setting `CanCollide`; it will be reverted. Use a collision group. See §6e.
- **`Workspace.Gravity` does the weight.** Never add a gravity force in the flight model — `AeroForce` carries aerodynamic and propulsive force only. This is also why `telemetry.loadFactor` reads 1 g in level flight without any special-casing: it is exactly what a real accelerometer measures.

---

## 8. Working agreement with the user

- Build **one system at a time**, test it, explain what was created / where / what it does / how to test it, then move on.
- Do not build ahead of the current phase.
- Ask rather than guess when something is ambiguous.
- Report honestly: if tests fail, say so and show the output.
