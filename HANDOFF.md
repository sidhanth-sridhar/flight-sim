# Flight Simulator — Developer Handoff

**Read this first.** It is the source of truth for continuing development.

---

## 0. Resume here — state at 2026-08-04

**All 378 checks green across 12 suites.** Eleven run in **Play mode, Client datamodel**; `AircraftService` runs in the **Server** datamodel (see §4).

# ✅ **PHASE 1 IS SIGNED OFF.** The flight gate was flown and passed on 2026-08-04 — see §9 for the pilot's report and what it found.

Taxi, takeoff, climb, coordinated turns, forward slip, deliberate stall and recovery, and landing were all flown. **The behaviour in the air was reported as right**: rotation at the expected speed, Vy pitch holding, clean turns, a predictable stall near the expected AoA with no deep-stall tendency, correct left-turning tendency answered by right rudder, and rudder authority that fades with airspeed as it should.

➡️ **NEXT TASK: fly a few landings and judge the flare (§10), then Phase 2 cockpit instruments.** Ground effect is now modelled — but it is worth **only ~45 fpm of cushion out of ~900**, because a high wing gets little of it. That is the physically correct answer rather than a disappointing one, and it means **it will not by itself make landings easy**. If the flare still feels wrong after flying it, the cause is elsewhere and §10 lists where to look next.

**What landed this session**
- **`ResetAircraft` on Backspace** (§6j) — the pilot named the key. It does **not** require being seated, and the reasoning is in §6j because it decided where the code lives.
- **`ViewToggle` on T** (§6k) — first person ↔ third person in one press, asked for as a "button". It is a **key** rather than an on-screen button, and §6k records why: the cursor is the yoke, so a button in a screen corner can only be clicked by dragging the controls to near-full deflection on the way to it.
- **The board prompt now hides while somebody is aboard** (§9) — a gate finding, fixed.
- **The landing model was reviewed against published figures and left alone** (§9). All three suspects the pilot named measured correct.
- **Ground effect is now modelled** (§10) — the one real gap §9 found. Induced drag only, standard Wieselsberger, inert above one wingspan. Measured cushion: **45–48 fpm, 5–7%**.

**Landed the session before**
- `CameraController` (§6h) — cockpit / chase / free on V, world-locked while C is held.
- `DebugHud` (§6i) — raw numbers, 30 Hz with per-frame peak capture.
- The seated pilot is now **invisible** as well as massless and non-collidable (§6e).
- Two real bugs found by the new tools, not by reasoning: windmilling **RPM read negative** when parked, and restoring pilot transparency **clobbered the HumanoidRootPart**. Both fixed with regression tests. See §7.

**The mouse is now PTFS-style**: free cursor, position = deflection, inverted. See §6g — including the GUI-inset trap, which would otherwise have baked in a permanent nose-up bias.

**The aircraft now taxis, rotates and flies** — verified with real keyboard and mouse input, not just tests. Measured: 0 → 65.9 kt in 340 m of ground roll, rotation at 56 kt, climb to 45 m. Holding full back-stick then produced a genuine stall, wing drop and spiral departure, which is the model behaving correctly rather than a fault.

**A bug that made the whole simulator look dead was found and fixed** — the tyres were glued to the runway. See §6f. It predated the server migration and was not caused by it; it had simply never been exposed, because nobody had taxied before.

**Committed** through the PTFS control change; the working tree is clean.

**Phase 1 remaining**: nothing. The gate was flown and passed — §9.

**Verified live this session, not just in tests**: the server spawns the aircraft, grants the client network ownership, the client adopts it and runs the frame loop, and boarding moves the aircraft **0.000 m**. Getting to that last number took three fixes — see §6e, because two of them are not obvious and both were found by measuring rather than reasoning.

**Open questions for the pilot**, none blocking:
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

### Verified green (366 checks total)

| Module | Path | Checks | Datamodel |
|---|---|---|---|
| `Atmosphere` | `Physics/Atmosphere.luau` | 17/17 | Client |
| `Aerodynamics` | `Physics/Aerodynamics.luau` | 37/37 | Client |
| `Engine` | `Physics/Engine.luau` | 24/24 | Client |
| `Cessna172` | `Aircraft/Definitions/Cessna172.luau` | 26/26 | Client |
| `AircraftBuilder` | `Aircraft/AircraftBuilder.luau` | 20/20 | Client |
| `FlightModel` | `Physics/FlightModel.luau` | 38/38 | Client |
| `GroundHandling` | `Physics/GroundHandling.luau` | 25/25 | Client |
| `InputController` | `StarterPlayer/.../FlightSim/Controls/InputController.luau` | 80/80 | Client |
| `FlightController` | `StarterPlayer/.../FlightSim/Controllers/FlightController.luau` | 29/29 | Client |
| `CameraController` | `StarterPlayer/.../FlightSim/Controllers/CameraController.luau` | 24/24 | Client |
| `DebugHud` | `StarterPlayer/.../FlightSim/UI/Instruments/DebugHud.luau` | 26/26 | Client |
| `AircraftService` | `ServerScriptService/FlightSim/Services/AircraftService.luau` | 32/32 | **Server** |

```lua
require(game.ServerScriptService.FlightSim.Services.AircraftService).runTests()   -- Server datamodel
```

⚠️ **Run the suites in PLAY mode, not Edit.** `require` caches per session, and the Edit session accumulates stale copies as modules are edited — a module edited after it was first required will keep serving the old copy for the rest of the session, which shows up as `attempt to call a nil value` on a function you can see in the file. Entering Play creates a fresh DataModel with a clean cache. Use `datamodel_type: "Client"`; the server has no `UserInputService` and cannot load `InputController`.

Also built and working: `Constants`, `MathUtil`, `Signal`, `Units`, `Remotes` (12-entry manifest), and both server/client bootstraps. A live boot logs gravity 9.80665, 12 remotes created, sea-level density 1.2250.

### AircraftBuilder — now verified (2026-08-03)

`Aircraft/AircraftBuilder.luau` passes 20/20. The two outstanding fixes were confirmed correct when finally executed:

1. **Centre-of-mass frame mismatch.** Roblox reports `AssemblyCenterOfMass` relative to the **root part**; the definition measures offsets from a **datum**. They are different origins. Fixed by storing a `DatumOffset` attribute on the root at build time and converting in `measure()`.
2. **Cylinder volume.** Roblox computes mass from *true geometric* volume, not the bounding box — a cylinder is only π/4 of its box, so wheels came out 21% light. Fixed with a `SHAPE_VOLUME_FACTOR` table.

Nothing is currently unverified, and nothing is left to build in Phase 1. Only the flight gate remains, and it is flown rather than written.

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
Pilot-specified (do not change): **W/S** throttle ramp, **A/D** rudder, **F/G** flap detents down/up, **C** camera hold, **R** altitude hold, **E** engine toggle, **Backspace** reset aircraft, mouse = pitch/roll.

Chosen here, open to review: **B** brake, **V** cycle view, **T** toggle first/third person (§6k), **, / .** trim down/up, **L** gear (G was taken; inert on the fixed-gear 172), **P** pause.

**X and M were removed** when the yoke became absolute — see §6g.

**C is momentary** (held only while down); **R latches**. Bindings live in `InputController.DEFAULT_BINDINGS` and are overridable per player via `rebind()`, which is what the settings menu will drive. A test asserts no two actions share a key.

**Backspace is the one binding `update()` does not consume** — it is listed there to be rebindable and to be covered by the collision test, but `FlightController` reads it directly. See §6j for why, because the reason is not stylistic.

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

### The seated pilot is also invisible (2026-08-04)
`FlightController.setCharacterNeutralised()` now hides the body as well as making it massless and non-collidable. The cockpit camera sits at the pilot's eye, inside a 5.7 m avatar folded into a 1.5 m cabin, so without this the view is filled with the inside of the pilot's own head — the same problem as the solid cabin shell, and the same fix.

Three things it has to get right, each of which was a bug before it was a comment:
- **Decals need their own pass.** A Decal is a *child* of a part, not a property, so `Transparency = 1` on the head does not hide the face. Miss it and the face floats with no head behind it.
- **Original transparency is recorded, not assumed to be zero** — the `HumanoidRootPart` ships at 1 and must go back to 1.
- **Restore only what was hidden.** See §7; defaulting to 0 was a live bug.

It is a **local** change: client property writes do not replicate, so other players still see a pilot sitting in the aeroplane. Only the person flying it stops seeing their own body.

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

## 6h. `CameraController` — built and green (2026-08-04, Phase 2)

`src/StarterPlayer/StarterPlayerScripts/FlightSim/Controllers/CameraController.luau`, 22/22. Started by the bootstrap — `CONTROLLER_ORDER` already listed it, so no wiring was needed.

It is the consumer for the two fields `InputController` had been producing since Phase 1 with nothing on the other end: `systems.viewIndex` and `systems.cameraHold`. **The camera owns what those numbers mean**; the input layer knows only that there are `viewCount` of them.

| View | Behaviour |
|---|---|
| 1 Cockpit | Eye anchored to the `PilotSeat`, rolls with the aircraft. Whatever encloses the eye is made locally invisible. |
| 2 Chase | 18 m behind, 5.5 m above. Follows heading and pitch, **never roll**. Position smoothed, τ = 0.14 s. |
| 3 Free | Handed to Roblox's `Custom` camera with the aircraft root as `CameraSubject`. |

### It never reads the mouse, and that is the point
The cursor is the yoke — its screen position *is* the deflection, and the edge is full travel. A camera that panned near the screen edge would swing the view exactly when the pilot is holding full aileron, taking the horizon away at the moment they most need it. So there is **no edge-panning, no drag-to-look, no cursor input of any kind**. Free view is not an exception: Roblox's Custom camera orbits on *right-drag*, and the yoke reads position rather than buttons, so the two cannot collide.

**Free view clamps `CameraMinZoomDistance` to 8 studs** and restores it on exit. Without that, zooming in reaches first person, which locks the mouse to screen centre — freezing the yoke at neutral and taking the controls away with no explanation.

### C is a world-lock, not a free-look
While held, the camera keeps the world orientation and world-space offset it had when C went down; position still tracks the aircraft's *translation* so the pilot is not left behind at 130 kt. It uses no mouse input, so it cannot fight the yoke. Measured live: **camera turned 0.6° while the aircraft turned 101.5°** through a held yaw. Release eases back over 0.28 s rather than snapping, which the rigid cockpit view would otherwise do.

The rejected alternative was a conventional free-look that pans with the cursor and freezes the yoke while held — on release the yoke would snap to wherever the cursor ended up, which is unpleasant low and slow.

### Geometry that was chosen against the airframe, not by feel
Eye at datum y = 0.75: the seat pan is at 0.25, the nose tops out at 0.625 and the wing centre section starts at 0.825. So the pilot sees **over** the nose, as in a real 172 where the cowling is prominent.

In practice the eye is inside both `Cabin` and `WingCenter`, and both are hidden. Hiding the wing root is correct for a high-wing Cessna — you cannot see it from inside anyway — and the outer wings stay visible, which a test asserts.

`occludingParts()` is a **containment** test, not a proximity one. Proximity would sweep up parts merely near the eye and leave the outer wings apparently floating unattached. The 0.12 m margin is sized against the camera's near plane (0.1 studs = 0.1 m at this scale), so a part close enough to slice through the view is caught before it can.

### Two things worth not rediscovering
- **Bind at `RenderPriority.Camera.Value + 1`.** Roblox's default camera writes `CFrame` at `Camera` priority, so anything scripted at or before it is overwritten the same frame and the camera simply does not move.
- **`CFrame.lookAt` with a world-up hint is undefined when the look direction is vertical**, and this simulator reaches steep attitudes on its own — a measured stall departure hit −64°. The chase view falls back to the aircraft's own up vector; two tests cover straight up and straight down.

### The test that was wrong before the code was
"Chase camera does not roll" was first asserted on `up.Y > 0.99` and failed at 0.9747. The code was right: the camera sits 5.5 m above and looks at the aircraft 24 m away, so it is permanently pitched ~13° down, and `cos(13°) = 0.975`. **Bank shows up in `RightVector.Y`, not in `UpVector.Y`** — an up-vector test fails on a perfectly level camera. This is the third time an assertion, not the code, was the wrong one.

### Coupling
`FlightController` gained three narrow read-only accessors — `getAircraft()`, `getSystems()`, `isFlying()` — rather than exposing `rig`, so nothing outside it can reach the flight model or constraints and start writing to them. The camera calls them **every frame instead of caching an aircraft**, which is exactly what stops it holding a destroyed model: the answer becomes nil the frame the aeroplane goes away.

`#CameraController.VIEWS` must equal `InputController.DEFAULTS.viewCount` or V skips a view or overruns. They are kept in step by **assertion, not dependency** — making the input layer require the camera would point the arrow the wrong way — so `runTests()` checks it and `Init()` warns.

## 6i. `DebugHud` — built and green (2026-08-04, closes Phase 1 build work)

`src/StarterPlayer/StarterPlayerScripts/FlightSim/UI/Instruments/DebugHud.luau`, 26/26, started by `Controllers/UIController.luau`.

Raw numbers only. No gauges, no needles. Every value is printed as a number because a number can be checked against a published figure and a needle cannot.

### Why two files
The bootstrap **only scans `Controllers/`** — the same trap already documented for `Controls/InputController`, which it silently skips. So a module in `UI/Instruments/` can never be reached by `CONTROLLER_ORDER` whatever it is named. The widget therefore lives where widgets belong and a thin `UIController` — a name `CONTROLLER_ORDER` has listed since Phase 0 — owns its lifecycle. Extending the loader to scan more folders was rejected: "controller" would stop meaning anything, and the explicit ordering is what makes startup dependencies visible.

### What it shows
`IAS`, `TAS` (kt), `ALT` (m), `VS` (m/s and fpm), `AoA`, `BETA` (deg), `G` (g), `THRUST` (N), `RPM`, `FUEL` (kg), `RHO`, `Q`, then `FORCE` and `TORQUE` as raw signed X/Y/Z components, then **one row per aerodynamic surface** with α, CL and CD.

The per-surface rows are the reason this model exists, made visible: an asymmetric stall appears directly as WingLeft and WingRight diverging. Observed live during a departure — `WingLeft CL -0.021` against `WingRight CL +0.779`.

**Units convert here and only here.** The physics stays pure SI; m/s become knots and radians become degrees at this boundary, and nothing converted ever travels back.

### Update rate: 30 Hz drawn, every frame sampled
Redraw is `Constants.SIM.INSTRUMENT_HZ`. But **load factor and force magnitude are sampled every frame** and the peak since the last redraw is shown beside them. A plain 30 Hz readout aliases exactly the events worth catching — `FlightModel` clamps force at 20 g precisely because spikes happen, and a one-frame spike would otherwise never appear.

### Two things that will confuse someone later
- **`telemetry.force` is the aerodynamic and propulsive force only.** `FlightController` adds `GroundHandling`'s contribution before writing the constraint, so **on the ground the HUD legitimately disagrees with `AeroForce.Force`, and the difference is the gear load**. In the air they agree. This was noticed as a 2258 vs 1935 N mismatch and chased down before it could look like a bug.
- **Nothing in the HUD may be `Active` or a `GuiButton`.** The cursor is the yoke and covers the whole screen, so an input-absorbing element here would eat the flight controls. A test counts them and requires zero.

`IgnoreGuiInset` is left **false**, which sidesteps the coordinate trap in §6g by construction: the GUI's origin is already the usable area below the top bar, so a plain pixel offset needs no correction. Nothing here mixes that space with `Camera.ViewportSize`.

### It found a bug on its first flight
It displayed `RPM -0` on a stationary aeroplane. Not a formatting artefact: `Engine.update`'s windmilling branch used `math.min(airspeedMs * 12, ...)`, and `airspeedMs` is the **forward** component, which drifts slightly negative on a parked aircraft — so the tachometer read backwards. Now clamped at zero, with a regression test asserting rpm stays ≥ 0 at −3 m/s of forward airspeed. This is exactly what the HUD is for.

## 6j. Reset on Backspace — built and green (2026-08-04, closes Phase 1 build work)

`ResetAircraft = Enum.KeyCode.Backspace` in `InputController.DEFAULT_BINDINGS`; consumed by `FlightController`. The pilot named the key. This closes the open question §0 had been carrying since the service landed: the recovery path from an aeroplane on its back was *die, or respawn from the Roblox menu*.

**No new server code, and none was needed.** `AircraftService` already treats a spawn request from a player who has an aircraft as *replace it* (§6e), so a reset **is** a request — `FlightController.requestAircraft()`, the same call `Humanoid.Died` already made. There is no reset remote and no second adoption path.

### The pilot does NOT have to be seated, and that decided where the code lives

The obvious home was `InputController.update()`, alongside every other latched action, and it would have been wrong. `update()` only runs inside the frame loop; the frame loop only runs while the pilot is sitting in a working aircraft. The situations worth resetting from are exactly the ones where that is not true — an aeroplane on its back that will not let you back into the seat, a wreck you climbed out of, or no aircraft at all because a request failed. **Requiring a flyable aeroplane in order to recover from an unflyable one is circular.**

So the binding lives in `InputController` — rebindable, and swept up by the existing "no two actions share a key" test — but `update()` deliberately ignores it, and `FlightController` connects `UserInputService.InputBegan` as a **lifetime** connection rather than a rig one. Two `InputController` tests pin the key down as inert there: holding it must move no control and flip no system flag, so it cannot quietly acquire a second meaning later.

### Edge-triggered structurally, plus a cooldown for mashing
`InputBegan` fires once per physical press, so holding Backspace cannot respawn repeatedly — the rising edge is a property of the signal, not something this module remembers. What `InputBegan` does *not* stop is **mashing**, and each reset is an `InvokeServer` round trip that despawns an aircraft and builds another, so five jabs would queue five spawns and hand back the last aeroplane. `RESET_COOLDOWN = 1.0 s`.

### Backspace is the key you press to fix a typo
Which makes the guard against consuming it while a text box has focus more than housekeeping — deleting a character must never also delete the aeroplane. Both `gameProcessedEvent` and the existing `isTyping()` check are applied.

### Testing a keyboard without a keyboard
`FlightController.shouldReset(keyCode, blocked, boundKey, now, lastAt)` is pure and exported, the same shape as `AircraftService.evaluate()`. Six checks drive it directly: the bound key accepts, another key does not, a blocked press does not, a second press inside the cooldown is dropped and one after it is not, and a rebound key is honoured while the old one goes quiet. Comparing against a `boundKey` **passed in** rather than a constant is what makes `rebind()` work, and the last check is what asserts it.

### Verified live, not only in tests
Real Backspace press, `1` aircraft before and `1` after, but a different model instance — and the server log carries the whole chain: `Reset requested` → `Despawned c172_… (slot 0)` → `Spawned Cessna 172S Skyhawk (c172) at slot 0` → `Adopted`. **Pressed while standing on the apron, never having boarded**, which is precisely the case a seated-only reset would have failed.

## 6k. First person ↔ third person on T (2026-08-04)

`ViewToggle = Enum.KeyCode.T` in `InputController.DEFAULT_BINDINGS`. One press swaps Cockpit and Chase. **V is unchanged** and still cycles all three.

No camera work was needed — both views already existed (§6h). This is one edge-triggered latch and a config pair.

### Asked for as a "button", built as a key, and the reason is structural
**The cursor is the yoke.** Its screen position *is* the control deflection and the edges are full travel (§6g), so a clickable button in a corner of the screen can only be reached by dragging the controls to near-full deflection on the way to it — a top-right button is full nose-down and full right roll. That is not a styling preference, it is a spiral dive. §6i already forbids `Active` elements and `GuiButton`s in the HUD for the adjacent reason, with a test asserting zero.

A key costs no cursor movement at all, which is what makes it safe to press mid-turn. The alternative offered and declined was a non-interactive HUD label showing the current view; it remains available and breaks nothing, because a `TextLabel` absorbs no input.

### The view indices stayed where they belong
§6h is explicit that **the camera owns what a `viewIndex` means** and the input layer knows only that there are `viewCount` of them. Hardcoding "1 is the cockpit" into `InputController.update()` would have reversed that arrow, so the pair travels as configuration instead:

```lua
InputController.DEFAULTS.toggleViews = { 1, 2 }   -- indices, not names
```

`CameraController` is where those numbers acquire names, so that is where the check lives — `runTests()` asserts `VIEWS[toggleViews[1]] == "Cockpit"` and `[2] == "Chase"`, and `Init()` warns. Same **assertion, not dependency** arrangement already used for `viewCount`. Reordering `VIEWS` is a reasonable thing to do and would otherwise silently turn the toggle into "third person / orbit".

### The asymmetry is deliberate
Only the *first* view maps to the second; **everything else maps back to the first**. So pressing T while in Free lands in the cockpit rather than doing nothing — which is the case a pilot hits hardest, lost in the orbit camera and wanting the cockpit back now. A strict two-way swap would leave the key dead exactly then.

### `table.clone` is shallow, and that was a latent bug
`new()` cloned `config.altHold` but the new `toggleViews` would have been shared by reference across every `InputController` in the game — so a per-player rebind would have rebound everybody's. Both nested tables are now cloned, and a test asserts mutating one instance leaves the other and the defaults alone.

### Verified live, not only in tests
Real T presses on a seated pilot, camera distance from the aircraft measured each time:

| action | result |
|---|---|
| seated, start | **0.45 m** — cockpit, `Scriptable` |
| T | **18.82 m** back, **5.50 m** up — chase, and √(18² + 5.5²) = 18.82 exactly |
| T | **0.75 m** — back in the cockpit |
| V, V → Free | `CameraType` **Custom**, min zoom clamped to 8 |
| T from Free | **0.75 m**, `Scriptable` — cockpit, and free view's zoom clamp restored to 0.5 |

### Then
**Phase 1 test gate — the only thing left in Phase 1**: taxi, take off, coordinated turn, deliberate stall, recover, land, on the flat baseplate. **The pilot flies it and signs off.** Do not proceed further into Phase 2 until that happens.

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
- **A "restore" that defaults to a hardcoded value will clobber something.** Pilot invisibility recorded each part's transparency on the way in, then restored, with a fallback of 0 when nothing was recorded — and the fallback fired, because the restore path runs BEFORE the hide path ever does: `adopt()` calls `onOccupantChanged()` the moment an aircraft is assigned, long before anyone sits. That set the `HumanoidRootPart` — which ships at 1 and is meant to stay hidden — to fully opaque. **Restore only what you actually changed; touch nothing else.** The unit test missed it entirely because a synthetic fixture never reproduces the real call ordering. The live check did.
- **Windmilling RPM read NEGATIVE on a parked aircraft.** `Engine.update` used `math.min(airspeedMs * 12, ...)` for a dead engine, and `airspeedMs` is the *forward* component, which drifts slightly negative when stationary — so the tachometer ran backwards. Now clamped at zero. Found by the debug HUD showing `RPM -0` on its first flight, which is precisely what that HUD is for.
- **The client bootstrap only scans `Controllers/`.** A module anywhere else — `Controls/`, `UI/Instruments/` — is never started by `CONTROLLER_ORDER`, whatever it is called, and fails **silently**. Give it a thin owner in `Controllers/` instead (see §6i).
- **`string.format("%.0f", x)` rounds halves to EVEN**, so `1204.5` prints as `1204`, not `1205`. A test fixture sitting on an exact `.5` boundary is testing the C library's rounding mode, not your code. Cost one wrong assertion.
- **Roblox friction can pin an aircraft to the runway, and it looks like dead controls.** Effective μ must stay below thrust/weight (0.255 for the 172) or full power moves it 0.00 m. Tyre friction belongs to `GroundHandling`, not to Roblox — see §6f. **`frictionWeight` is half the story**: surfaces combine as `(f1*w1 + f2*w2)/(w1+w2)`, so friction 0 at weight 1 still inherits half the runway's grip.
- **"The controls do nothing" is not evidence that input or aerodynamics is broken.** Both were provably fine in §6f. Before touching either, apply the force with the aircraft in **free air** — if it accelerates correctly there, the fault is in ground contact, and that one test skips the entire search.
- **Dying respawns your aircraft**, by design (`FlightController` requests a new one on `Humanoid.Died`). **Backspace does the same thing deliberately** (§6j). During either, the old model is despawned and a new one spawned, so anything holding a reference to `workspace.Aircraft:GetChildren()[1]` can momentarily find nothing. That is the designed reset, not a despawn bug — it cost time to re-derive once. Consumers should follow `CameraController` and re-ask `FlightController.getAircraft()` every frame rather than caching a model.
- **`force.Y` is not lift, and `force.Z` is not drag.** Lift and drag are resolved about the *relative wind*, not the world axes, so at any real angle of attack the drag vector has a Y component and the lift vector a Z one. An assertion of the form "this change must not affect lift" written against `force.Y` will fail on correct code. Assert on the surface telemetry's **CL and CD** instead — they are dimensionless and isolate the term being changed. See §10.
- **Comparing a force at two altitudes confounds DENSITY with whatever you meant to measure.** Air is thinner at 400 m than at 30 m, so the drag differs for reasons unrelated to your term. Compare coefficients, or hold altitude fixed and vary the one thing under test. Also §10.
- **A "best glide L/D" is not an approach sink rate, and confusing them nearly caused a wrong tuning fix.** The full-flap best-L/D point sits at a speed nobody approaches at, so comparing it against a remembered glide-ratio figure says nothing about how the aeroplane actually lands. Measure the operational condition — trimmed for L = W at the speed actually flown — before touching a coefficient. See §9.
- **An on-screen button cannot be a flight control in this game.** The cursor is the yoke, so moving it to a corner to click something commands near-full deflection on both axes on the way there — a top-right button is full nose-down and full right roll. Anything the pilot needs *in flight* has to be a key. This is the same constraint §6i states as "nothing in the HUD may be `Active` or a `GuiButton`", arrived at from the other direction. Non-interactive `TextLabel`s are fine and absorb nothing.
- **`table.clone` is shallow, and `InputController.DEFAULTS` has nested tables.** `altHold` and `toggleViews` must each be cloned in `new()` or every `InputController` in the game shares one, and a per-player rebind silently rebinds everybody's. It cost nothing this time only because the omission was caught while adding the second one.
- **A binding in `DEFAULT_BINDINGS` is not proof `update()` consumes it.** `ResetAircraft` is listed there to be rebindable and to be covered by the collision test, but is read by `FlightController` off `InputBegan`, because it has to work when there is no aircraft and therefore no frame loop. `poll()` still reports it as held; nothing acts on that. See §6j.
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
- **Append to this handoff at the end of every task**, so the general outline stays current. A task is not done until §0 and the relevant section reflect it.
- **Commit before moving on.** Once a task's suites pass, stage and commit it. Never leave work uncommitted at the end of a task.

---

## 9. Phase 1 flight gate — flown and passed (2026-08-04)

**Signed off by the pilot.** Taxi, takeoff, climb, coordinated turns, forward slip, deliberate stall and recovery, and landing were all flown on the flat baseplate.

**Reported good, verified in the air rather than in a test:**
- Takeoff roll and rotation — natural, tracked the expected speeds
- Climb — pitch for Vy held well, HUD numbers consistent with the model
- Coordinated turns — clean
- Deliberate stall and recovery — stalled predictably near the expected AoA and speed, recovered without drama, **no deep-stall tendency**
- Forward slip — worked correctly
- AoA and stall indication — matched what the aircraft actually did
- **Left-turning tendency on takeoff was correct**, and right rudder answered it
- Rudder responsive at speed, and **correctly unresponsive at low speed** — no rudder authority without airflow

Also confirmed by the pilot, and worth recording because it looks like a bug and is not: **S does not give true power-off.** A running engine keeps its idle floor (§Engine, `idlePowerFraction = 0.05`). True power-off is **E**.

### Finding 1: the board prompt stayed up after boarding — FIXED

The `BoardPrompt` on the `PilotSeat` remained visible for the whole flight. Never actionable — the seat was taken, and `Sit()` on an occupied seat does nothing — but cosmetic in the middle of the windscreen.

`AircraftService.attachBoardPrompt` now sets `prompt.Enabled = occupant == nil` in the seat's existing Occupant handler. Two details:
- **The prompt is created before the handler now**, not after it. It has to exist for the handler to close over.
- **`Enabled` is set from `occupant` directly, not inside the branches below it.** Those branches are about the *previous* occupant and have a nil path that does nothing; hanging the re-enable off that path would strand the prompt hidden forever on any route through it — a crash death being the obvious one.

Server-side, so it replicates: every player stops seeing the prompt on an occupied aeroplane.

Tested with a real `Sit()` against a synthetic character rather than by poking the property, because `Occupant` is read-only and it is the seat's own signal the fix hangs off — a fixture that set the flag by hand would test the assignment and not the wiring. `AircraftService` 28 → 32.

### Finding 2: landing is hard — the model was reviewed and left ALONE

All three suspects the pilot named were measured against published C172 figures. **All three are correct.** Nothing was tuned.

**Idle-thrust float — correct.** The 5% power floor gives 6.7 kW, which is 377 N static and only **148 N at 65 kt** — 9% of the 1,652 N of drag in the landing configuration, worth about 88 fpm of reduced sink. Small and real, which is what it should be.

**Approach sink rates — correct.** Trimmed for L = W at each speed, idle power:

| configuration | model | real C172 |
|---|---|---|
| full flap, idle, 60 kt | **784 fpm** | ~750–800 |
| full flap, idle, 65 kt | **909 fpm** | ~800–900 |
| clean, idle, 65 kt | **563 fpm** | ~600 |

**Flare authority — correct.** Full aft stick trims to 14.4° AoA against a 13.9° stall, so the elevator can reach CLmax and the flare is not blocked. At 60 kt full flap the wing reaches L/W 1.88 — 0.88 g of excess, which arrests a 909 fpm descent in about 0.5 s and 1.2 m of height. That is a normal flare, not a marginal one.

⚠️ **One measurement nearly caused a wrong fix, recorded so it is not repeated.** Comparing *full-flap best-glide L/D* (7.19 in the model) against the folk figure of "5:1 with full flaps" suggested flap drag was ~40% too low, and a sweep of `flapDragEffect` was already running before the error showed up. **Those are not the same quantity.** The model's best-L/D point with full flap sits at 52.6 kt, which is a speed nobody approaches at; at the speeds actually flown the sink rates are right, as the table above shows. Operational numbers, not polar summaries. `flapDragEffect` is unchanged at 0.045.

### The one real gap: ground effect is not modelled

`FlightModel`'s own comment lists it as future work. Within about one wingspan (11 m) of the ground a real light aircraft loses a large fraction of its induced drag, and that is what produces the **cushion in the flare** — the aeroplane settles rather than arrives, and the flare becomes forgiving of being a foot high or a foot low.

Without it the pilot must arrest *all* of the sink with elevator alone, at exactly the right height, with no help. **That matches the report precisely: everything in the air felt right, and only the last few feet were hard** — which is the signature of a defect that exists solely near the ground.

It is additive and bounded — zero above one wingspan — so it cannot touch any validated figure in §4, all of which are measured well clear of the ground. **Not built: it is a new physics feature rather than a fix, and the pilot chooses whether it comes before the Phase 2 instruments.**

Absent that, the honest answer on landing is **pilot technique**, with one control-scheme note worth knowing: the flare needs the pitch command to go from roughly 0 to 0.9, which with `mouseExpo = 0.35` means dragging the cursor about **87% of the way from centre to the bottom of the screen** — and any sideways drift on the way is roll, because one cursor carries both axes.

*(Ground effect was subsequently built — §10. Read the measured magnitude there before assuming it changed the landing.)*

---

## 10. Ground effect — built and green (2026-08-04)

The gap §9 identified, now modelled. Induced drag only, and **it is worth far less than it sounds**: read the measurement before forming an expectation of it.

```lua
Aerodynamics.groundEffectFactor(heightM, span) -> number   -- pure, 0.25..1
Aerodynamics.dragCoefficient(alpha, cl, surface, flap, groundEffect?)
Aerodynamics.solveSurface(..., flap, heightAboveGround?)
```

**The relation**, as McCormick gives Wieselsberger: `phi = (16h/b)^2 / (1 + (16h/b)^2)`, multiplying the induced term. `h` is the height of the **wing**, `b` the **full span**. Returns exactly 1 at and above one span, so it costs nothing and changes nothing for the whole of normal flight.

### It is small, and that is the correct answer

| condition | 30 m | in the flare | cushion |
|---|---|---|---|
| 65 kt full flap | 909 fpm | **864 fpm** | 45 fpm (5.0%) |
| 60 kt full flap | 785 fpm | **738 fpm** | 47 fpm (5.9%) |
| 55 kt full flap | 690 fpm | **641 fpm** | 48 fpm (7.0%) |
| 65 kt clean | 564 fpm | **526 fpm** | 39 fpm (6.9%) |

**Because it is a high wing.** The 172's wing sits **2.10 m up on an 11 m span** — h/b = 0.19, giving phi ≈ 0.90, a ~10% cut in induced drag and ~5–7% in total. A low-wing trainer at h/b = 0.08 gets phi ≈ 0.62. The 172 not floating much is a real property of the aeroplane, and a version of this that produced a dramatic cushion would be **wrong**. The upper bound is asserted as firmly as the lower one for exactly that reason.

**So this did not fix landing**, and was never going to. If the flare still feels wrong, look at approach speed discipline first (the model floats if flown fast, correctly), then at the cursor-travel note at the end of §9.

### Three decisions worth not re-litigating

**Per surface, not per aircraft.** `solveSurface` takes each surface's own height. `FlightModel` already has `armWorld` for every surface, so `altitude + armWorld.Y` costs one addition — and it means **in a bank the low wing gets more effect than the high one**, a real force asymmetry that helps pick up a dropped wing in the flare.

**`groundEffectSpan` is declared, never derived.** A wing split into panels keeps the **full** wing's aspect ratio but **half** its area (see §7), so `sqrt(AR * area)` on a panel returns 7.78 m for an 11 m wing — a 30% error straight into a squared term. It is `nil` on the tail and fin deliberately: both are small, both sit higher, and modelling them would add a term nobody could measure in flight.

**Drag only; the lift curve is untouched.** Changing CL near the ground would move the stall speed there and quietly invalidate the figures in §4. A test asserts CL is bit-identical in and out of ground effect.

⚠️ **Ground is assumed at y = 0.** True of the Phase 1 baseplate, and **not** true of the Phase 3 world. When terrain arrives this needs the ground height under the aircraft — one raycast per frame shared with `GroundHandling`, not one per surface.

### Two wrong assertions, both caught by the suite

Both were tests failing against correct code, which is now the fourth and fifth time in this project.

1. **`force.Y` is not lift.** Lift and drag resolve about the *relative wind*, so at 8° of alpha the drag vector has a real Y component — reducing drag moved `force.Y` by 38 N and an "in ground effect, lift is unchanged" assertion failed against perfectly correct code.
2. **Comparing drag at two altitudes confounds density with ground effect.** 30 m vs 400 m differ because the air is thinner, not because of this term.

Both were fixed by asserting on the wing's own **CL and CD** — dimensionless and density-free, so they isolate exactly the thing being changed. A third bound (`reduction < 8%`) was picked by eye and failed at a correct 8.97%; the ceiling is now derived instead, from the fact that a CD reduction can never exceed the induced-term reduction that causes it.
