# Flight Simulator — Developer Handoff

**Read this first.** It is the source of truth for continuing development. Last updated at the end of Phase 1, step 3.

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

---

## 4. Current state

### Verified green (94 checks total)

| Module | Path | Checks |
|---|---|---|
| `Atmosphere` | `Physics/Atmosphere.luau` | 17/17 |
| `Aerodynamics` | `Physics/Aerodynamics.luau` | 29/29 |
| `Engine` | `Physics/Engine.luau` | 23/23 |
| `Cessna172` | `Aircraft/Definitions/Cessna172.luau` | 25/25 |

Also built and working: `Constants`, `MathUtil`, `Signal`, `Units`, `Remotes` (12-entry manifest), and both server/client bootstraps. A live boot logs gravity 9.80665, 12 remotes created, sea-level density 1.2250.

### ⚠️ Unverified — do this first

`Aircraft/AircraftBuilder.luau` — roughly 19 checks, **never run successfully end to end**. Its last run failed one check; two fixes were applied but not executed:

1. **Centre-of-mass frame mismatch.** Roblox reports `AssemblyCenterOfMass` relative to the **root part**; the definition measures offsets from a **datum**. They are different origins. Fixed by storing a `DatumOffset` attribute on the root at build time and converting in `measure()`.
2. **Cylinder volume.** Roblox computes mass from *true geometric* volume, not the bounding box — a cylinder is only π/4 of its box, so wheels came out 21% light. Fixed with a `SHAPE_VOLUME_FACTOR` table.

**First task: run `AircraftBuilder.runTests()` and confirm it is green.**

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

## 6. Next task: `FlightModel`

This is the module that makes it fly. Intended design, already worked out:

**Location**: `src/ReplicatedStorage/FlightSim/Physics/FlightModel.luau`

**Per frame, on the pilot's client:**
1. Read `AssemblyLinearVelocity`, `AssemblyAngularVelocity`, `AssemblyCenterOfMass`, root `CFrame`.
2. Altitude → `Atmosphere.getDensity()`.
3. For each surface: compute its offset from CoM (cached at spawn), get point velocity via `Aerodynamics.getPointVelocity(v - wind, ω, r)`, call `Aerodynamics.solveSurface(...)`.
4. Accumulate total force and total torque: `τ += r × F`.
5. Add engine thrust along the thrust axis, plus torque reaction and slipstream yaw.
6. Add airframe parasitic drag (`definition.drag.airframeCD0` + `Engine.getPropDragCD0`) opposing velocity.
7. Sanitise via `MathUtil.sanitizeVector` — **a single NaN permanently destroys a Roblox assembly**.
8. Write to the `AeroForce` / `AeroTorque` constraints (convert N → Roblox units with `Units.newtonsToRobloxForceVector`).

**Cache at spawn**, not per frame: `comLocal`, each surface's `offsetFromCoM = surface.offset - datumOffset - comLocal`.

**Clamp `dt`** to `Constants.SIM.MAX_TIMESTEP` (1/20 s) so a frame hitch cannot launch the aircraft into orbit.

### Then, in order
1. `InputController` — keyboard axes first (deterministic and verifiable), then mouse modes.
2. `FlightController` — client frame loop, network ownership handling.
3. `AircraftService` — server-side spawning.
4. Debug HUD — raw numbers only: IAS, altitude, AoA, G-load, thrust, force vectors. **No pretty gauges yet.** This is the diagnostic tool for tuning and where bugs actually get found.

**Phase 1 test gate**: taxi, take off, coordinated turn, deliberate stall, recover, land — on the flat baseplate. Do not proceed to Phase 2 until the user has flown it and signed off.

---

## 7. Gotchas already discovered — don't rediscover these

- Roblox density is capped at **100**. At metre scale that means 100 kg per m³ of bounding box. An 1111 kg aircraft needs ≥11.1 m³ of parts. `AircraftBuilder.validate()` hard-errors on violations, because the silent failure mode is an aircraft that's too light and flies like a balloon.
- `VectorForce.ApplyAtCenterOfMass = true` is required. Without it, force acts at the attachment position and injects a phantom pitching moment that scales with thrust.
- `VehicleSeat` gives automatic network-ownership transfer to the occupant — that's why it's used. Its own `MaxSpeed`/`Torque`/`TurnSpeed` must be zeroed or Roblox applies steering torques on top of the aerodynamics.
- Parasitic drag must sit **outside** the stall-separation blend. Blending it away means a surface in exactly reversed flow produces zero drag and coasts forever.
- The stall blend is centred ~3° *beyond* `alphaStall`, so peak CL occurs *at* the stated stall angle. Centring it on `alphaStall` puts CL_max several degrees early and well below the real value.
- When splitting a wing into panels: halve the **area**, keep the **full wing's aspect ratio**. Induced drag depends on total span. Getting this wrong roughly doubles induced drag and the aircraft mysteriously won't climb.

---

## 8. Working agreement with the user

- Build **one system at a time**, test it, explain what was created / where / what it does / how to test it, then move on.
- Do not build ahead of the current phase.
- Ask rather than guess when something is ambiguous.
- Report honestly: if tests fail, say so and show the output.
