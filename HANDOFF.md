# Flight Simulator — Developer Handoff

**Read this first.** It is the source of truth for continuing development.

---

## 0. Resume here — state at 2026-08-09

**All 1,004 checks green across 24 suites.** Twenty run in **Play mode, Client datamodel**; `TerrainService`, `AirportService`, `AircraftService` and `PlayerService` run in the **Server** datamodel (see §4).

# ✅ **PHASE 4c IS SIGNED OFF AND NOW COMPLETE — ALL EIGHT ITEMS.** The systems were **flown and passed on 2026-08-09** — the mag check on start, BOTH for takeoff, rudder trim hands-off in the climb, and the mixture stopping the engine. The **visual half was then built at the pilot's request** (§47b): three engine gauges with POH bands, and five lights that actually light. **1,004 checks green across 24 suites.** ⚠️ **The gauges and lights themselves have NOT been flown** — they were built after the gate.

🔌 **THE LIGHTS ARE GATED ON THE BUS, NOT ON THE SWITCH (§47b).** A landing light switched on with the battery master off does nothing, which is what makes item 5 worth having and is why item 8 waited for it. **Red to port, green to starboard**, asserted rather than trusted. The strobe **flashes at ~1 Hz on an 8% duty cycle**, checked across a whole cycle because a duty cycle sampled at one instant would pass on a lamp that was always on.

⚠️ **NUMBER KEYS 1–9 ARE ROBLOX COREGUI HOTBAR SLOTS.** Found when Studio's virtual input refused to send `1`: *"key is permanently bound to a CoreGUI core action"*. **The sim reads them anyway** — `InputController.poll` uses `IsKeyDown`, which is raw key state and is not filtered by `gameProcessed` — and the lights were switched with real 6/8/9 presses to prove it. But a player carrying a Tool would also be equipping it, so if a backpack ever exists, the electrical and light keys need moving.

⚙️ **PHASE 4c — THE 172S SYSTEMS ARE IN, SIX OF EIGHT ITEMS COMPLETE (§47).** Rudder trim, the fuel selector, mixture, magnetos and the electrical system are **built, wired and tested against the POH**; the engine gauges are **modelled but not yet drawn**, and the lights and cabin switches **hold state and draw current but do not yet change the 3D parts**. ⚠️ **Twenty-two new keys — forty-two bindings total — so the binds reference (K) was built with them**, read from `DEFAULT_BINDINGS` rather than a copy of it. **The Controls contract is untouched**: every system lives in `state.systems`. **NOT YET FLOWN — the Phase 4c gate is open.**

🔎 **THE BRIEF'S PREMISE ABOUT THE FUEL SPLIT WAS WRONG, AND MEASURING IT IS THE FINDING (§47).** Two tanks were expected to move the CoM. They do not: the fuel is **already** carried in the definition's *static* mass boxes — `WingLeft` and `WingRight` at 110 kg each, commented "structure plus the fuel it carries" — and those never change as fuel burns. `fuelKg` was never a mass, it is bookkeeping the engine drinks from. **So §4 stands unchanged, verified rather than assumed.** Making a lateral imbalance produce a real rolling moment means making the wing boxes *dynamic*, which is a **§4 mass-model decision for the pilot**, not a side effect of fitting a fuel valve.

🐛 **THREE BUGS THE SUITES CAUGHT ON CORRECT-LOOKING CODE (§47).** The rudder trim tab was built with `sign = +1` like the rudder and so **followed** it instead of opposing it — an anti-servo tab off a different aeroplane, and §37's exact lesson on the other axis. It also **hung past the rudder's trailing edge** and grew the aeroplane to 15.755 m against §45's 15.500 target; the real tab is *inset*, and the published-length check found it immediately. And the mixture curve **disagreed with its own comment** — a plain square gave 0.87 power at best economy where the note claimed 0.95, so the exponent is now derived from the figure it has to hit (2.5, not 2).

📱 **THE FLIGHT TABLET IS IN, AND PHASE 4b'S OPEN DECISION IS CLOSED (§46).** ⚠️ **The pilot's answer was neither option §14 wrote down.** Not "modal, releases the yoke anywhere" and not "ground only", but **on the ground OR with altitude hold engaged** — and the second half costs nothing, because §28 already made the mode on R ignore the cursor entirely, so the pilot's hands are off the controls by construction and a clickable panel takes nothing away. **M opens it** (free since the absolute yoke retired MouseModeToggle). Departure/destination pickers and an aircraft picker, with distance, bearing, climb and cruise altitude presented from `AirportService.flightPlan()` — **a lookup, never a second implementation.** ⚠️ **The gate is re-checked EVERY FRAME, not just on open**: opened during the take-off roll it is legal, and thirty seconds later the aeroplane is airborne on trim with a clickable panel over the windscreen — so it closes itself and says why. Verified live: opens seated on the ground, **slams shut the instant the wheels leave**, opens again with R engaged.

🐛 **STARTING A FLIGHT FROM A FIELD YOU ARE NOT AT KILLED THE PILOT, AND ONLY FLYING IT FOUND THAT (§46).** Every unit test passed and the feature was still broken: `StartFlight` parked the aeroplane at Ridge exactly right and left the pilot on Meadow's apron 1.6 km away — with **workspace streaming ON**, holding the model's shell and **0 of its 128 parts**, which from the apron is indistinguishable from the spawn having failed silently. So the pilot now travels with the flight. ⚠️ **The first fix then buried them 2.3 m inside the hillside**: the standing height was measured with `AirportService.groundHeightAt`, which excludes the *Aircraft* folder **and nothing else** — the ray starts at the top of the R6 torso and hit the pilot's **own head**, giving a standing height of **−2.3 m**. It is derived from the rig's bounding box now.

🟨 **GRAYBOXING (§44):** all aircraft/cockpit 3D modeling is postponed until the first version of the game with all of its features is done. Existing geometry stays as the graybox; **airport design is feature work and happens BEFORE the 3D modeling pass**; the cockpit 3D work in §42/§43 is parked. The screen panel remains the live instrument set.

🛋️ **THE SEAT CAME DOWN AND THE COCKPIT WENT IN (§39).** `PilotSeat` is structural, so it was a pilot decision: pan **0.63 → 0.30 m above the cabin floor**, headroom **0.60 → 0.93 m**, so a seated avatar clears the roof. **Mass, assemblies and static margin unchanged; the CoM moved 0.3 mm.** 38 massless interior decorations went in — panel, seats, yokes, pedals, throttle, trim wheel, switches — and **the six-pack now mounts on a real `PanelBoard` via `SixPack.mountOnPart`, with no drawing code changed** (§19, waiting since Phase 2). ⚠️ **The eye did NOT follow the seat down** — it is held at y 0.80 by a larger `EYE_OFFSET`, because riding the seat down would put it below the glareshield. ⚠️ **`UIController` still drives the SCREEN panel; nothing wires the 3D one to a flying aircraft yet**, and the seated avatar is not rigged — see §39.

⌨️ **PITCH TRIM NOSE-DOWN MOVED H → J, BECAUSE H WAS ALREADY THE HUD (§38).** Two actions on one key means the pilot cannot tell why a control is dead. ⚠️ **The guard caught this the whole time and it was read past** — `InputController` was reporting **109/110**, not the 110/110 quoted in earlier sessions, because the clash arrived in an uncommitted edit after those runs. Read the failing check, not the aggregate.

🎛️ **THE TRIM TAB RIDES THE ELEVATOR NOW (§37).** Reported as "a small piece on the right elevator that does not move". ⚠️ **Every hinge got `Part0 = root`**, so the tab was bolted to the airframe and only ever did its own trim. An optional **`hinge.parent`** chains a surface's Motor6D to another surface, and the tab is now carried up 22° with the elevator while still sitting 15° nose-down of it. ⚠️ **The arithmetic was already right, which is why nothing caught it** — `SurfaceAnimation`'s 21 checks are all *pure*, and the bug lived in the joint the builder made. There is now a check that drives a **real built model**, because that is the only place the two layers meet.

🐛 **THE FIRST FLIGHT OF THE RESIZED AEROPLANE FOUND FOUR BUGS, ALL FIXED (§35).** The flight itself was good. ⚠️ **Three of the four were something silently rescaling or replacing a value that every source file still reported correctly** — §30's lesson again. `Model:ScaleTo` **rescales WalkSpeed and JumpHeight with the rig** (a tuned 20.00 m/s and 1.00 m measured as **7.00 and 0.35**), so the tuning is now restored *after* the scale converges through the shared `CharacterTuning`. A reset from the seat left the camera at the aeroplane, because a stale `CameraSubject` is the **wrong object, not a missing one**. ⚠️ **The character camera focuses a hard-coded 1.500 studs above the HumanoidRootPart and does NOT scale with `ScaleTo`**, so on a 0.35x pilot it orbited a point **0.905 m above their face**; `Humanoid.CameraOffset` now corrects it onto the pilot (§35 landed it on the nose, §36 moved it to the **head centre**), derived from the live rig. The name tag is **off entirely**, by the pilot's call.

🐛 **THE "VESTIGIAL PIECE ON THE TAIL" WAS THE FUSELAGE, AND §33 EXPOSED IT (§35).** The loft's last station ended at z = 4.70, so the tail cone stopped in mid-air just short of the fin's trailing edge — a square-ended block sticking out the back. Moving the vertical tail 0.106 m forward for §33's length fix pulled the fin off the end of the cone that used to hide it. It now dies at **z = 4.35**, inside the fin and tailplane. **Envelope, mass and part count unchanged.** ⚠️ **Do not fix a loft like this by deleting its last station** — that leaves a bigger blunt face further forward, where nothing covers it.

🧍 **THE PILOT IS NOW 1.55 m, AND THE ON-FOOT CAMERA PIVOTS INSIDE THE HEAD (§36).** The pilot asked why the Cessna reads smaller than PTFS's — it is the avatar-to-plane ratio, not the aircraft's size (§33's 8.28 × 11.00 × 2.72 m is unchanged). Decision: **shrink the pilot to 1.55 m** via the existing uniform `Model:ScaleTo` path (1.30–1.40 m rejected as child-sized; no uniform scale fixes the ratio). **Nothing else moved, by construction**: the cockpit eye is anchored to the `PilotSeat`, and the on-foot framing reads the live `character:GetScale()`. The orbit pivot was then moved **from the nose to the head centre** (`headPivotOffset`), because §35's own notes had already found the eyes/nose placement "really funky" on foot — the pivot must sit inside the skull for seamless orbiting. ⚠️ **A 1.55 m pilot still cannot sit naturally in this airframe** (real seated eye ~datum 0.95, slot tops out at 0.80) — that stays a structural decision (§31/§35).

✅ **THE RE-FLY CLEARED IT, AND PHASE 4 ITEMS 4 AND 5 HAVE BEGUN.** The pilot re-flew the committed §36/§37 build and reported it good: the **1.55 m pilot feels right**, the **head-centre orbit pivots seamlessly**, and the **trim tab rides the elevator**. ⚠️ **Still open, and a decision rather than a task: a realistic seated eye height does not fit this airframe.** The seat pan is 1.40 m above the wheels where a real 172's is about 0.95 m, so the eye is 0.55 m above the pan instead of 0.78 m. Fixing it means moving the **structural** `PilotSeat` (§31). See §35. This is now **urgent** because the player's own avatar has to physically fit in the interior Phase 4 item 4 builds. **DECIDED (2026-08-06, pilot): lower the seat ~0.4 m AND shift it left to x ≈ −0.30 for a two-seat 172 layout** — pilot left, copilot right, shared centre pedestal; the copilot gets its own yoke/throttle and panel/pedestal reach (HANDOFF §14 item 6).

🧱 **THE PILOT IS A CLASSIC R6 NOW, BUILT IN CODE (§34).** ⚠️ **R6 is not a property Rojo can write** — `StarterPlayer`, `Workspace` and `Players` were all probed and none has one, so the new `PlayerService` builds every character with `Players:CreateHumanoidModelFromDescription(desc, R6)` and `CharacterAutoLoads = false`. It runs **last** in `SERVICE_ORDER` because it stands the pilot on the `SpawnLocation` that AirportService moves. Settled: **1.741 m tall at the 1.75 m setting, feet on the apron, scale 0.3500** (the height is now **1.55 m** after §36; the mechanism is unchanged) — and `FlightController`'s scaling needed no change, because it measures the rig rather than assuming R15. 🐛 **A "sinking pilot" cost a fix that had to be thrown away: `Model:ScaleTo` does not replicate, so the SERVER's copy of a scaled character is not evidence — measure it on the CLIENT.**

🗑️ **THE IMPORTED MESH IS GONE, ON THE PILOT'S CALL (§33).** It sat wrong on the aeroplane and its fitted scale was abnormal, so it was **removed rather than patched** — deferred, not abandoned. The exterior is the pre-mesh primitive Cessna of §31 again: 79 parts (78 until §35 tapered the tail cone), 1,111 kg, one assembly, all six surfaces still deflecting. The diff is **100% deletions** bar one identifier rename. `exteriorFromMesh` and `keepWithMesh` went with it, one step past "restore the flag to false", because deleting `useMesh` left nothing reading either.

📏 **THE AEROPLANE IS NOW THE SIZE OF THE PUBLISHED AEROPLANE — 11.000 × 2.720 × 8.280 m (§33).** It measured 10.500 × 2.920 × 8.450: **three errors in three different directions**, which is why there was no scale factor to fix and why each axis was corrected in the part layout. ⚠️ **Not one structural box moved** — every change is massless decoration, and the original 29 `Cessna172` checks including static margin pass untouched. Four new checks pin the dimensions against the definition. **The whole-model envelope still reads 2.85 m and that is correct**: the invisible structural fin box tops out 0.13 m above the visible fin, and shrinking it would move mass to improve something nobody can see.

🧍 **THE PILOT IS NOW 1.55 m AND CANNOT ALSO BE 0.50 m WIDE (§33, height superseded by §36).** Measured settled at **1.7502 studs** with **0.547 m** shoulders before the pilot asked for 1.55 m (§36). The R15 rig is built **9.4% too broad for its height** (ratio 0.3125 against a human's 0.2857) and a uniform `ScaleTo` carries that ratio whatever value it takes — scale for width instead and the pilot is 1.60 m tall. The two mechanisms that could narrow it are the ones §30 measured as inert (`BodyWidthScale`) or destructive (hand-resizing a constraint rig with 15 `WrapTarget`s of layered clothing).

The pilot's answer was to change the rig instead — **classic R6, now done in §34**. Note that R6 is **broader still** — a 2-stud torso on a 5-stud rig is a 0.40 ratio — so it was a choice of *look*, not a fix for the width.

🎛️ **THE INSTRUMENTS NOW READ LIKE INSTRUMENTS (§32).** The ASI carries the POH's static-source position error (48 kt calibrated indicates **40**), the DI reads **magnetic** rather than true, and the altimeter reads what its baro setting says. **Display errors only** — injected in `SixPack.samplers`, never in the physics. A wet-compass turning-error model is written and tested for the compass scope item 4 will mount; it is **not** on the DI, because a gyro is steady in a turn by design.

✈️ **PHASE 4 — THE CESSNA LOOKS LIKE A CESSNA (§31).** The exterior is modelled (78 parts, lofted fuselage, dihedral wing, struts, swept fin, gear legs) and **the control surfaces move with the controls** — ailerons, elevators, rudder, flaps, trim tab and a spinning prop, all on `Motor6D` hinges. **The physics did not move**: the structural boxes are unchanged and merely hidden, and `Cessna172` is still 29/29 at 1,111 kg with the CoM where it predicts. Two real bugs were caught doing it — a duplicate part name that **silently detached the tailplane and lost 20 kg**, and **ailerons that deflected backwards** past a test asserting the wrong sign. Scope items 3–5 (instrument realism, cockpit interior, 3D controls) are **not started**.

🧍 **THE PILOT IS 1.75 m (NOW 1.55 m, §36), AND THE PREVIOUS ATTEMPT AT IT DID NOTHING AT ALL (§30).** `d19d805` set the R15 scale `NumberValue`s and printed a success line while moving the rig **0.00 studs** — the marker reported the scale it *asked for* beside an unrelated `HumanoidRootPart` number, so it could not tell success from doing nothing. The answer is **`Model:ScaleTo()`** — `Humanoid` has no `ScaleTo`, but a character is a `Model` and that one exists. **There is no 0.4 floor** (it was inferred from a mechanism that was never working) and **no `Motor6D` joints on this rig to rewrite** — it is a constraint rig. The planned manual part-rescaling was never needed. ⚠️ **Leave `AutomaticScalingEnabled` TRUE**: setting it false moves the camera focus onto an unscaled 2-stud constant, putting it 1.30 studs above a shrunken pilot's head. Boarding still moves the aircraft **0.000 m**.

✅ **THE ALTITUDE-HOLD PORPOISE IS FIXED, FLOWN, AND SIGNED OFF (§29).** Recorded at **125.1 kt** — above the 112–118 kt band that used to limit-cycle — **0 vertical-speed crossings and a peak command of 0.219** against the old saturated 0.450. ⚠️ **The slow climb/descent while engaged is WANTED and is not a bug** — the pilot asked for that variability as realism, so **do not add an integrator to flatten it**. Revisit the loop with **weather (Phase 5)**, when density, thermals and hot pockets give it something real to fight; the ~29 m droop is parked there too.

🌍 **PHASE 3 HAS STARTED. The world is real terrain now, and the airport sits on it at 250 m (§20).** The baseplate is retired at run time, and the y = 0 assumption §14 called the largest known trap in Phase 3 is gone: `AirportService` declares an elevation and terrain is fitted to it. The height field blends **multiple** pads by weight and is built in 16 m blocks — both forced by measurement, because nearest-pad blending measured a **45.8 m cliff** and 64 m blocks a **21.5 m staircase** between airports at different elevations.

📋 **Phase 3 decisions, made by the pilot**: each airport declares its own elevation; a player spawns at the airport **nearest** them; and the field **stays 2,048 m**, so **streaming is explicitly deferred, not skipped**. That last one constrains the next system — a second *full-size* airport does not fit beside the first, so airport B must be a shorter strip about 1 km out. See §20.

🛰️ **ALTITUDE HOLD NOW IGNORES THE CURSOR (§28).** While engaged (R), the mouse is not read as the yoke at all — it can neither fight the roll law through the "pilot is flying" hand-off nor drop the mode out through the old stick-movement disconnect, which were the two ways the cursor caused the hunting. Only R disengages. The rudder still works and still re-targets the heading reference. `disconnectThreshold` is gone. InputController's suite is 101 checks now (was 102); **not yet flown and not yet re-run in Studio — a pilot has not pressed R in the air since the change.**

🐛 **"WHY IS THERE NOTHING WHEN I RUN PLAY" — found and fixed (§20).** Renaming the bootstrap to Rojo's lowercase `init.server.luau` changed the tree shape: `ServerScriptService.FlightSim` became the **Script** instead of a Folder holding an `Init` child, so `script.Parent:FindFirstChild("Services")` looked in `ServerScriptService` and found nothing. **No services started at all, in complete silence** — while gravity, the remotes and the physics self-check were all correct, because those run first. It now checks both layouts and **warns** instead of returning zero quietly.

🌱 **Terrain grass was burying the runway, and only a screenshot found it (§20).** Roblox draws grass blades sized for the default stud scale; at 1 stud = 1 m they are metre-tall and grow through 0.4 m of pavement. `Terrain.Decoration` does not exist in engine 0.732, so the ground is now **`Ground` tinted green** via `SetMaterialColor`. Every number was right — height, flatness, continuity, pavement standing proud — while the runway was invisible.

⚠️ **`ServerScriptService/FlightSim/init.server.luau` is not syncing into Studio.** Rojo's own build contains the change and every other file syncs, so the server is fine and the plugin is holding a connect-time snapshot of that one instance. **Reconnect the Rojo plugin in Studio** — until then the bootstrap runs an old `SERVICE_ORDER` that does not start `TerrainService`, and a Play session has no terrain unless it is built by hand. The file was also renamed `Init.server.luau` → `init.server.luau` to match Rojo's documented lowercase convention.

# ✅ **PHASE 2 IS SIGNED OFF.** The instrument circuit was flown and passed on 2026-08-04 — an altitude held on the altimeter, a speed on the ASI, a heading on the DI, and the AoA indication marking the stall (§14, §18).

⚙️ **Tachometer and fuel are in, and the debug HUD toggles on H (§19).** The tach's green arc and redline come from `engine.maxRPM` by identity; the fuel gauge **reads a level, not a mass**, marked E/½/F against `fuelCapacityKg` with a red reserve band derived from 45 minutes at cruise burn. H replaces `Constants.DEBUG.SHOW_PHYSICS_OVERLAY` as the pilot-facing control — the constant is now only the starting state.

🧭 **The 3D-panel roadmap is now written down (§19), because it was not recorded anywhere.** The instruments will eventually live on a real panel inside the Cessna, so `Instrument.luau` stays rendering-agnostic and `SixPack` is split: `buildPanel()` is a fixed-pixel frame that knows nothing about a screen, and `build()` is the throwaway `ScreenGui` wrapper. **A test builds the panel into a real `SurfaceGui` and drives it**, so the constraint cannot rot.

🎛️ **THE SIX-PACK IS FLYING (§18).** Airspeed, attitude, altimeter, turn coordinator, heading and VSI, in the standard layout, driven by real telemetry — verified live in the cockpit, not just in tests. `FlightModel` now publishes **heading, turn rate and lateral acceleration**; the ball is real lateral acceleration rather than sideslip, because in a forward slip the two disagree and only the ball tells the pilot what their feet are doing. The gauge framework (§17) grew multi-needle dials, a rotating compass card, the inclinometer ball and a wings symbol — **all of it as spec data, no bespoke gauge code**.

⚠️ **`ClipsDescendants` cannot clip a rotated descendant** — measured three ways, no workaround (§7). The attitude indicator is therefore drawn as a stack of chords, each one inscribed in the dial by construction. **The suite passed 33/33 while the horizon smeared across the airspeed indicator and the altimeter**; only a screenshot found it, which is now the second time. If a module draws something, look at it.

✅ **The VSI's 2.0 s lag is confirmed by the pilot and is not to be touched.** A real one is 6–9 s; the snappier instrument is the right trade when you cannot feel the g-forces, and the circuit gate needs it.

🕹️ **THE YOKE WAS BIASED NOSE-UP BY THE GUI INSET, AND FULL NOSE-DOWN WAS UNREACHABLE** (§16). Reported as *"it breaks the mouse cursor movement, extremely difficult to pitch down and very easy to pitch up"* in a loop. All of it was true. Measured: the top of the screen produced **−0.766** against the bottom's **+1.000**, neutral sat 58 px above the middle of the screen, and a cursor off the game view — which Roblox reports as (−1, −1) — slammed the controls to **hard nose-down and hard left roll**. §6g had the inset the wrong way round and its live verification only proved the arithmetic was self-consistent. **The aerodynamics were not involved**: elevator authority measures exactly proportional to dynamic pressure. Phase 2 has not started.

🛫 **THE FLIGHT-TEST ENVIRONMENT IS NOW AN AIRPORT, NOT THE BASEPLATE.** Runway 18/36, 1,000 × 23 m, with a parallel taxiway, an apron, full markings and vertical reference objects. See §11 — including why the markings are load-bearing rather than decorative.

# ✅ **PHASE 1 IS SIGNED OFF.** The flight gate was flown and passed on 2026-08-04 — see §9 for the pilot's report and what it found.

Taxi, takeoff, climb, coordinated turns, forward slip, deliberate stall and recovery, and landing were all flown. **The behaviour in the air was reported as right**: rotation at the expected speed, Vy pitch holding, clean turns, a predictable stall near the expected AoA with no deep-stall tendency, correct left-turning tendency answered by right rudder, and rudder authority that fades with airspeed as it should.

➡️ **NEXT TASK: re-fly the landing gate on the real runway.** The Phase 1 gate passed technically, but landings were judged on a featureless baseplate with no depth or speed cue, which is why the flare felt impossible. §11 exists to fix that. Ground effect (§10) is also modelled now, though it is worth only **~45 fpm of cushion out of ~900** — a high wing gets little of it, so the runway markings are expected to help far more than the physics did.

📐 **The AoA readout was not bugged — the panel was missing two things** (§15). Alpha was correct all along; it looked stuck because **attitude was never shown beside it** (20.8° nose-up with only 8.7° of alpha is normal in a climbing pull) and because **alpha had no peak capture**, so a sub-second stall break fell between 30 Hz redraws. The HUD now shows ATT and bank, captures peak alpha, and marks `< buffet` / `<< STALL`.

📋 **Phases 2 to 6 are planned in §14**, written before the instrument work began, with Phases 5 (weather) and 6 (audio, damage, persistence, tutorial) planned the same day once Phase 2 had a full instrument set. **Phase 4 is now the aircraft itself** — the Cessna modelled inside and out with a proper 3D panel, controls and switches (visual-only for now, interactive later) — and the flight tablet moved to Phase 4b, because there is no point choosing a destination in an aeroplane until it has an interior. Weather (Phase 5) is what makes Phase 4's instrument realism visible.

⚖️ **The tailplane was rigged the wrong way round, and the aircraft could not be trimmed hands-off anywhere** (§13). Reported as "really hard to nose down on approach". It needed **−0.79 stick** at 65 kt with full flap and **−0.38 in cruise**, against a trim range of only ±0.35. `STAB_INCIDENCE` is now **+1.0°** and `trimLimit` **±0.7**; every configuration now trims hands-off. **No published performance figure moved.**

🛞 **Nosewheel steering was rebuilt** (§12). Reported as too weak and too rudder-dependent; measured at a **207 m turn radius** with full pedal, now **19.3 m**. The nose wheel was being shoved sideways while pointed straight ahead; it is now actually steered.

✅ **The pitch axis was re-flown by the pilot after §16 and signed off** — the yoke reads correctly, full nose-down is reachable, and the loop no longer throws the controls.

**Open items for the pilot**, in order:
1. Re-fly landings on runway 36 and say whether the flare is judgeable now.
2. Taxi and confirm the steering feel — and check the takeoff roll is not darty at 40+ kt, which is what the speed fade guards against.

**What landed this session**
- **Tachometer, fuel and the H toggle (§19)** — Phase 2's build is complete. `SixPack` 34 → 48, `UIController` +10.
- **The six-pack (§18)** — all six instruments, live on real telemetry. `SixPack` 34, `Instrument` 38 → 59, `FlightModel` 44 → 53.
- **The gauge framework (§17)** — Phase 2's first system.
- **The yoke's inset bug (§16)** — the pointer is now reduced to the same space as the viewport, an off-view cursor holds the yoke instead of jumping to a corner, and losing window focus releases it. Six new checks; `FlightController` 29 → 35.
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
- `default.project.json` manages the three `FlightSim` folders, `Lighting`, and two `Workspace` instances: **`Baseplate`** (the 2,048 m grass field) and **`SpawnLocation`** (on the apron). The airport itself is **built in code** by `AirportService` — see §11 for why that is better than a JSON tree of 130 parts.

⚠️ **Rojo reads `default.project.json` at SERVE START and never again.** Editing the project file while `rojo serve` is running changes nothing at all — no error, no warning, and the served tree keeps the old definition. This cost real time: the baseplate was resized in JSON four times before it was clear the server had never read any of them.

**The full recovery, in order** — all three steps are needed:
```bash
# 1. restart the server so it reads the new project file
taskkill /F /IM rojo.exe ; rojo serve default.project.json
# 2. verify YOUR side before blaming Studio
rojo build default.project.json -o probe.rbxlx   # then grep it
```
3. **Reconnect the Rojo plugin in Studio.** Killing the server drops the connection and the plugin does not come back on its own. Until it is reconnected, *no* file syncs — which looks exactly like the §3 subtree bug and is not.

⚠️ **`Workspace.Baseplate` from the Studio template is NOT Rojo's**, so Rojo silently refuses to patch its properties — the same trap as the `StarterPlayerScripts` subtree below, now confirmed for `Workspace` instances too. **Delete it in Studio and let Rojo recreate it.** It comes back with the properties the JSON actually specifies. The same applies to `SpawnLocation`.

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

### Verified green (1,004 checks total)

⚠️ `UIController.runTests()` runs **all five** UI suites — `DebugHud`, `Instrument`, `InstrumentError`, `SixPack` and its own. Its 10 own checks are `UIController.runOwnTests()`.
⚠️ `TabletController.runTests()` does the same for the tablet: `Tablet` plus its own 9. `TabletController.runOwnTests()` is the 9 alone.

| Module | Path | Checks | Datamodel |
|---|---|---|---|
| `Atmosphere` | `Physics/Atmosphere.luau` | 17/17 | Client |
| `Aerodynamics` | `Physics/Aerodynamics.luau` | 37/37 | Client |
| `Engine` | `Physics/Engine.luau` | 57/57 | Client |
| `Electrical` | `Physics/Electrical.luau` | 21/21 | Client |
| `Cessna172` | `Aircraft/Definitions/Cessna172.luau` | 33/33 | Client |
| `AircraftBuilder` | `Aircraft/AircraftBuilder.luau` | 28/28 | Client |
| `SurfaceAnimation` | `Aircraft/SurfaceAnimation.luau` | 41/41 | Client |
| `FlightModel` | `Physics/FlightModel.luau` | 53/53 | Client |
| `GroundHandling` | `Physics/GroundHandling.luau` | 29/29 | Client |
| `InputController` | `StarterPlayer/.../FlightSim/Controls/InputController.luau` | 155/155 | Client |
| `FlightController` | `StarterPlayer/.../FlightSim/Controllers/FlightController.luau` | 51/51 | Client |
| `CameraController` | `StarterPlayer/.../FlightSim/Controllers/CameraController.luau` | 45/45 | Client |
| `DebugHud` | `StarterPlayer/.../FlightSim/UI/Instruments/DebugHud.luau` | 36/36 | Client |
| `Instrument` | `StarterPlayer/.../FlightSim/UI/Instruments/Instrument.luau` | 59/59 | Client |
| `SixPack` | `StarterPlayer/.../FlightSim/UI/Instruments/SixPack.luau` | 58/58 | Client |
| `InstrumentError` | `StarterPlayer/.../FlightSim/UI/Instruments/InstrumentError.luau` | 23/23 | Client |
| `UIController` | `StarterPlayer/.../FlightSim/Controllers/UIController.luau` | 10/10 (aggregate 196) | Client |
| `BindsPanel` | `StarterPlayer/.../FlightSim/UI/Binds/BindsPanel.luau` | 10/10 | Client |
| `Tablet` | `StarterPlayer/.../FlightSim/UI/Tablet/Tablet.luau` | 32/32 | Client |
| `TabletController` | `StarterPlayer/.../FlightSim/Controllers/TabletController.luau` | 9/9 (aggregate 41) | Client |
| `AircraftService` | `ServerScriptService/FlightSim/Services/AircraftService.luau` | 54/54 | **Server** |
| `TerrainService` | `ServerScriptService/FlightSim/Services/TerrainService.luau` | 23/23 | **Server** |
| `AirportService` | `ServerScriptService/FlightSim/Services/AirportService.luau` | 109/109 | **Server** |
| `PlayerService` | `ServerScriptService/FlightSim/Services/PlayerService.luau` | 14/14 | **Server** |

⚠️ `CameraController` (36 → 45, §45), `SixPack` (48 → 53) and `InstrumentError` (24 → 23) were **stale in this table** and were corrected on 2026-08-09 by running each suite rather than by inheriting the row. The old figures summed to 877 against a measured 881.

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
- Static margin **+14.2% MAC** — solidly stable (this line read +16% for a while; the suite has reported 14.2% throughout and rigging incidence cannot move it)
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

**Steering is a cornering force at the nose wheel, not a commanded yaw rate.** The yaw emerges from `r × F`. That is what makes steering authority fade as lift unloads the nose wheel and vanish entirely when it lifts — handing over to the rudder exactly when it should. `Cessna172.gear.steeringRate` was replaced by `tyreFriction` and a steering term for this reason.

⚠️ **That steering term is now an ANGLE, not a force fraction — see §12.** `steeringAuthority = 0.55` was replaced by `steeringAngle = 10°` after the old model measured a 207 m turn radius. The principle above is unchanged; the wheel is simply aimed before the grip acts on it.

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

**Altitude hold is a cascade**: altitude error → demanded vertical speed → pitch command. Commanding pitch straight from altitude error gives a phugoid that never settles; the inner vertical-speed loop is what damps it. **Since §28 the cursor is ignored while engaged** — it can neither override the law nor disconnect the mode; only R disengages.

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

⚠️ **This section got the inset BACKWARDS, and it was a live bug for two sessions. §16 has the measurement and the fix. What follows is kept because the reasoning is still right — only the direction was wrong.**

`GetMouseLocation()` and `Camera.ViewportSize` are **not** in the same coordinate space, and comparing one against the other biases the pitch axis. The original conclusion was that the viewport includes the strip behind Roblox's top bar and the mouse does not, so `readPointer()` reduced the **viewport** by the inset and left the **pointer** alone.

**Measured, it is the other way round.** `GetMouseLocation()` reports in the FULL viewport space: on a 1572 × 841 viewport with a 58 px inset, the cursor's reachable Y range is exactly **58 … 841**. Both must therefore be reduced, and `readPointer()` now subtracts the inset from the pointer as well.

**The "verification" here is what let it through**, and it is the useful lesson: the live probe checked that a cursor at y 392 gave `pitch +0.000` against a half-height of 391.5. That proved the arithmetic was self-consistent and nothing else — the cursor was not physically halfway down the screen, it was 57 px above centre. **Check the reachable RANGE, not one point inside it.** The `GetGuiObjectsAtPosition` experiment was misread the same way: it shares its space with GUI objects, not with `GetMouseLocation()`.

### Verified live
Real cursor, real code, all four quadrants. **These readings are pre-§16** — the roll figures still hold (the horizontal inset is 0), the pitch figures were biased nose-up by the whole vertical inset:

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
- **Altitude hold disconnects on stick MOVEMENT, not absolute deflection.** In Direct mouse mode the stick holds wherever it was put, so testing absolute deflection meant a pilot flying with real pitch input would press R and have it engage and disconnect on the same frame — a dead key with no feedback. The reference position is captured at engagement. **SUPERSEDED by §28:** while engaged the cursor is ignored entirely, so there is no stick movement left to measure and no disconnect — only R turns the mode off.
- **Cross-product order for the lateral axis.** `rollDir:Cross(groundNormal)` points to the aircraft's right; `groundNormal:Cross(rollDir)` points left. Getting it backwards inverts nose-wheel steering and the reported skid direction *without* breaking lateral grip, because grip is sign-symmetric — so the tests that would catch it are the steering ones, not the friction ones. This was caught on the first `GroundHandling` run.
- **A "restore" that defaults to a hardcoded value will clobber something.** Pilot invisibility recorded each part's transparency on the way in, then restored, with a fallback of 0 when nothing was recorded — and the fallback fired, because the restore path runs BEFORE the hide path ever does: `adopt()` calls `onOccupantChanged()` the moment an aircraft is assigned, long before anyone sits. That set the `HumanoidRootPart` — which ships at 1 and is meant to stay hidden — to fully opaque. **Restore only what you actually changed; touch nothing else.** The unit test missed it entirely because a synthetic fixture never reproduces the real call ordering. The live check did.
- **Windmilling RPM read NEGATIVE on a parked aircraft.** `Engine.update` used `math.min(airspeedMs * 12, ...)` for a dead engine, and `airspeedMs` is the *forward* component, which drifts slightly negative when stationary — so the tachometer ran backwards. Now clamped at zero. Found by the debug HUD showing `RPM -0` on its first flight, which is precisely what that HUD is for.
- **The client bootstrap only scans `Controllers/`.** A module anywhere else — `Controls/`, `UI/Instruments/` — is never started by `CONTROLLER_ORDER`, whatever it is called, and fails **silently**. Give it a thin owner in `Controllers/` instead (see §6i).
- **`string.format("%.0f", x)` rounds halves to EVEN**, so `1204.5` prints as `1204`, not `1205`. A test fixture sitting on an exact `.5` boundary is testing the C library's rounding mode, not your code. Cost one wrong assertion.
- **Roblox friction can pin an aircraft to the runway, and it looks like dead controls.** Effective μ must stay below thrust/weight (0.255 for the 172) or full power moves it 0.00 m. Tyre friction belongs to `GroundHandling`, not to Roblox — see §6f. **`frictionWeight` is half the story**: surfaces combine as `(f1*w1 + f2*w2)/(w1+w2)`, so friction 0 at weight 1 still inherits half the runway's grip.
- **"The controls do nothing" is not evidence that input or aerodynamics is broken.** Both were provably fine in §6f. Before touching either, apply the force with the aircraft in **free air** — if it accelerates correctly there, the fault is in ground contact, and that one test skips the entire search.
- **Dying respawns your aircraft**, by design (`FlightController` requests a new one on `Humanoid.Died`). **Backspace does the same thing deliberately** (§6j). During either, the old model is despawned and a new one spawned, so anything holding a reference to `workspace.Aircraft:GetChildren()[1]` can momentarily find nothing. That is the designed reset, not a despawn bug — it cost time to re-derive once. Consumers should follow `CameraController` and re-ask `FlightController.getAircraft()` every frame rather than caching a model.
- **Angle of attack is not pitch attitude, and a panel showing only one of them will be read as broken.** Alpha is measured against the airflow, attitude against the horizon; 20° of attitude with 8° of alpha is normal in a climbing pull. Show both, adjacent. See §15.
- **Whatever gets peak capture, alpha needs it too.** The 30 Hz redraw argument in §6i was applied to g and force and not to alpha — so the stall break, which lasts under a second, fell between samples and the readout looked stuck at a middling number. Peak capture is what made it visible.
- **A tail DOWNLOAD pitches the nose UP**, because it acts behind the centre of mass. On this aircraft the wing's AC is also ahead of the CoM, so wing lift is nose-up too — the two add rather than cancel, and the textbook "tail carries a download to balance the wing" picture is simply wrong here. Getting it backwards left the aeroplane untrimmable in every configuration for months, with nothing reporting it. **The CG is aft of the wing AC on a 172, so the tail must LIFT to trim.** See §13.
- **Trim range must be measured against the aircraft's actual trim requirement, not chosen.** `trimLimit` was ±0.35 against a requirement spanning −0.43 to +0.65 — so the pilot flew every approach holding the stick off-centre. If a control cannot reach the condition the aeroplane needs, it is a missing control.
- **Studio does not always step CLIENT physics in a Play session.** A plain unanchored part dropped from y = 60 on the Client datamodel did not move at all, with `Workspace.Gravity` correct at 9.8067 — while the identical test on the **Server** datamodel ran normally. Static suites are fine on the client, but **any test that needs the aircraft to actually move must run in the Server datamodel.** This cost a wrong diagnosis: a taxi measurement read 0.0 kt and looked like the steering change had broken thrust, when the force was reaching the constraint the whole time (1,462 N, verified) and nothing was being integrated.
- **A sideways FORCE on a wheel that stays pointed straight ahead does not steer an aircraft.** The main tyres' lateral grip cancels the resulting rotation, and the two fight to a standstill — 1,300 N·m produced a 207 m turn radius. Steered wheels need their own rotated axes. See §12.
- **Rojo reads `default.project.json` at serve start and never again.** Editing the project file while `rojo serve` is running does nothing, silently. Restart the server, then **reconnect the plugin in Studio** — killing the server drops the connection and it does not return on its own, after which no file syncs at all and it looks exactly like the subtree bug in §3. Full recovery is in §3.
- **Anything sitting at the world origin is now sitting on the runway.** `Workspace.SpawnLocation` was, with its top face a metre up. `AirportService.runTests()` sweeps the whole runway and taxiway for obstructions because of it — one probe point would not have found it either.
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
- **`ClipsDescendants` DOES NOT CLIP A ROTATED DESCENDANT**, and there is no workaround. Measured three ways — a plain `Frame` clipper, a `CanvasGroup` clipper, and a clipper that is itself rotated — and in all three the rotated child escaped and smeared across the neighbouring instruments. So anything rotated must fit inside its container **by its own geometry**. The attitude indicator is therefore drawn as a stack of chords (§18), and a needle's rotating pivot is checked against the dial radius rather than trusted to be trimmed. Note the corollary that makes this cheap to assert: **a corner's distance from the centre of rotation does not depend on the rotation**, so one check covers every angle at once.
- **Roblox rotates a `GuiObject` about its own CENTRE, not about its `AnchorPoint`.** The AnchorPoint positions the frame and has nothing to do with the pivot. **Measured, not read**: a needle anchored (0.5, 1) at a dial's centre and set to `Rotation = 180` pointed straight *up*, identical to 0 — an anchor pivot would have pointed straight down. To pivot about a point, the rotating frame's **centre** must be that point, so a needle is a transparent frame of twice its length centred on the hub with the visible bar as a child in its top half. See §17. The failure is silent: every angle can be correct and every arithmetic test can pass while the needle points at the wrong number.
- **Arithmetic tests cannot verify a rendering.** All 37 checks on the gauge framework passed while every needle pointed somewhere wrong. If a module draws something, look at it — one screenshot found what the whole suite could not. **It happened twice**: the six-pack then passed 33/33 while the attitude indicator painted itself across the airspeed indicator and the altimeter.
- **A feature gated at CONSTRUCTION cannot be toggled at RUNTIME.** `DebugHud.Init()` used to return early when `Constants.DEBUG.SHOW_PHYSICS_OVERLAY` was false, building no panel at all — so when the pilot asked for a toggle key there was nothing for it to switch back on, and the key would have worked in one direction only. Build the thing and gate its **visibility**; a constant that decides whether something *exists* is a constant nobody can override in flight. Toggling now costs no instances, so flicking it through a landing is free.
- **A Play session snapshots the datamodel when it STARTS, so entering Play before Rojo has synced runs the old code.** It looks exactly like a test you just wrote failing to appear — the suite runs and reports the previous count. Check the **Edit** datamodel's `Source` for a string you just added before pressing play; the whole cost is one `execute_luau` call.
- **`UserInputService:GetMouseLocation()` reports in the FULL viewport space, including the strip behind the top bar.** Its Y can never be below `GetGuiInset().Y` and its maximum is `ViewportSize.Y` — measured as a reachable range of exactly 58…841 on a 1572×841 viewport. So a pointer compared against `ViewportSize - inset` is biased by the whole inset. **Subtract the inset from both.** §6g asserted the opposite for two sessions; see §16.
- **Checking one point inside a mapping does not verify the mapping.** The bug above survived a live probe that confirmed a cursor at y 392 gave pitch 0.000 against a half-height of 391.5 — self-consistent arithmetic, and the cursor was nowhere near the middle of the screen. **Verify the reachable RANGE: both extremes and the centre.**
- **Roblox reports `GetMouseLocation()` as (−1, −1) when the cursor is not on the game view** — another window, or Studio's own panels in a Play session. Read as a position that is the top-left corner, which for an absolute yoke is hard nose-down and hard left roll in one frame. Treat it as missing data. See §16.
- **An absolute yoke has to handle window focus explicitly, and a relative one does not.** A relative stick simply stops receiving deltas and stays where it was; an absolute one keeps reading a cursor position that is now being moved for some entirely different purpose. `WindowFocusReleased` releases it to neutral (trim kept), the same path typing already used.
- **A Roblox terrain surface lands HALF A VOXEL above the top of the block you fill** — +2.000 studs on the 4-stud grid, constant to within 16 mm. Derive it from the voxel size rather than typing "2", and measure it in a test so a change in the engine fails loudly instead of floating the runway. See §20.
- **A uniform terrain fill is exactly flat; a sloped one is not.** 0.0000 m peak-to-peak over 1,000 × 22 m, against up to **1.23 m** deviation on a slope, because the isosurface smooths it. Terrain is scenery, not survey — anything that has to be flat to a centimetre, like a runway, stays a part resting on a terrain pad.
- **Terrain writes are not queryable in the same frame.** A raycast straight after a `FillBlock` finds nothing at all. Yield once. This cost a whole sweep that reported empty ground.
- **Filling terrain as flat columns makes the block size the resolution of every slope.** The step between neighbours is the local gradient times the block size, so gentle relief hides it and a real elevation change exposes it: two pads 50 m apart in height gave a **21.5 m staircase** at 64 m blocks and 1.14 m at 16 m. See §20 for the measured table.
- **"Nearest thing wins" blending is discontinuous where the regions meet.** A height field that picks the nearest pad's elevation and fades toward a base jumps by the difference between the two pads — measured as a **45.8 m cliff**. Weight the contributions instead; it is continuous by construction.
- **A tolerance of `1e-9` is finer than float32, and moving the world revealed it.** Roblox part positions are float32, so at y = 250 the spacing between representable values is about 1.5e-5 and `Position.Y + Size.Y/2` lands on 250.000003. Assertions that passed at y = 0 failed on correct code. Use tolerances sized to the engine, not to the maths.
- **A suite that depends on another service having run is flaky, not passing.** `TerrainService`'s pavement check read the terrain height and failed because it assumed `AirportService.Init()` had already built a runway — so it passed or failed depending on how far through booting the server was. Build what you need, as every other suite here does.
- **Rojo can hold a connect-time snapshot of ONE instance while syncing everything else.** `init.server.luau` stayed stale through a file edit, a case-rename and a full `rojo serve` restart, while every other file in the project updated normally and `rojo build` contained the change. When exactly one file will not move, it is the plugin, not the server: **reconnect the plugin**. Diagnose with `rojo build` and grep for a string unique to that file — grepping for a symbol that also appears in other files will tell you the build is fine when it is not the question you asked.
- **`Workspace.Gravity` does the weight.** Never add a gravity force in the flight model — `AeroForce` carries aerodynamic and propulsive force only. This is also why `telemetry.loadFactor` reads 1 g in level flight without any special-casing: it is exactly what a real accelerometer measures.
- **A Play restart DOES load edited modules — the "you must restart Studio" claim is a myth.** Entering Play creates a fresh DataModel with a clean module cache. Verified directly (§29) after the belief had already cost real time. What *is* cached separately is the **Command Bar**: `require()` there returns a **second copy** of a module, so a controller's `rig` is `nil` and `getSystems()`/`isFlying()` tell you nothing about the running aircraft. Observe the real one through side effects — GUI `Enabled` state, console output.
- **The test harness has been wrong more often than the code — five times in three sessions.** Terrain written outside `Terrain.MaxExtents`; `Engine.start()` never called; throttle left at 0.000 because `IC.update()` derives it from held keys; pitch inertia *guessed* at 1825 kg·m² when the model has **4922**; and airspeed force-held in a way that broke the energy balance and produced +50 m/s of climb. **Print the entry condition** — speed, vertical speed, throttle, thrust, attitude — and read it before believing anything downstream of it.
- **Assert inside the range the law is defined for.** Three assertions have now failed on *correct* code because the input was outside it: a heading error of exactly 180° (where the shortest turn is genuinely ambiguous), a gain-schedule check at 187 kt (past Vne, where the floor legitimately takes over), and a clamp check whose command `pitchLimit` had already cut. Say in the test why the range was chosen.
- **`AirportService.groundHeightAt` excludes the `Aircraft` folder AND NOTHING ELSE — including the character you are asking about.** Measuring "how high does this rig stand" by raycasting down from the character's own root starts the ray at `root + 1 m`, which on the R6 pilot is exactly the top of the torso, so it hits the pilot's **own head** at 253.25 instead of the apron at 250.00. The standing height came out **−2.3 m** and the pilot was placed 2.3 m inside a hillside, fell through the world, died, and respawned at the wrong airport with a fresh aeroplane. **Derive a rig's dimensions from the rig** — `Model:GetBoundingBox()` — not from a ray fired out of it. See §46.
- **WORKSPACE STREAMING IS ON in this place, and it changes what "the aircraft spawned correctly" means.** A model 1.6 km from the player replicates as a **shell with 0 of its 128 parts**, and `model.PrimaryPart` is `nil` on the client while being perfectly correct on the server. So a client-side check of a distant aeroplane proves nothing, and teleporting a character into an unstreamed region drops them through the ground. `Player:RequestStreamAroundAsync(position)` before the move is the documented fix; it yields, which is free inside a `RemoteFunction` handler the client is already waiting on. This was never noticed before because nothing had ever put a player and their aeroplane at *different* aerodromes.
- **Every derivative term tried on the altitude loop has made it worse — three so far (§29).** Any derivative here is taken on a signal that already lags the elevator by the time the nose moves and the wing answers, which at this model's pitch inertia is most of a second, so it arrives *in phase* with the motion instead of against it. A regression test pins the loop's shape; if you are about to add a fourth, read §29 first.

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

✅ **Ground was assumed at y = 0 — no longer.** That note stood until the airport landed; `Kinematics.groundY` is now measured by a raycast in `readKinematics`. See §11 for where it lives and why it is not inside `computeForces`.

### Two wrong assertions, both caught by the suite

Both were tests failing against correct code, which is now the fourth and fifth time in this project.

1. **`force.Y` is not lift.** Lift and drag resolve about the *relative wind*, so at 8° of alpha the drag vector has a real Y component — reducing drag moved `force.Y` by 38 N and an "in ground effect, lift is unchanged" assertion failed against perfectly correct code.
2. **Comparing drag at two altitudes confounds density with ground effect.** 30 m vs 400 m differ because the air is thinner, not because of this term.

Both were fixed by asserting on the wing's own **CL and CD** — dimensionless and density-free, so they isolate exactly the thing being changed. A third bound (`reduction < 8%`) was picked by eye and failed at a correct 8.97%; the ceiling is now derived instead, from the fact that a CD reduction can never exceed the induced-term reduction that causes it.

---

## 11. The airport — built and green (2026-08-04)

`src/ServerScriptService/FlightSim/Services/AirportService.luau`, 48/48, Server datamodel. **This replaces the bare baseplate as the flight-test environment.**

### The markings are load-bearing, not decoration

The gate was flown on a featureless grey plane and the landing reported as extremely hard. §9 measured the approach and the flare against published figures and both were correct — so the problem was never the flight model, it was that **there was nothing to see**. No depth cue, no closure cue, nothing to judge the last five metres against.

So each marking is there for a reason:
- **Centreline dashes are a ruler.** 30 m painted, 20 m gap — a 50 m period, one every 1.6 s at 60 kt. That is how closure rate is read without an instrument.
- **Edge markers are the depth cue.** 0.8 m posts every 60 m down both sides. Objects of known size passing at a known spacing give height; flat paint cannot.
- **The aiming point** (300 m in, the real figure for a runway under 1,200 m) is what the approach is actually flown at.

### Layout

| Element | Dimension |
|---|---|
| Runway 18/36 | 1,000 × 23 m (3,280 × 75 ft), along the Z axis |
| Taxiway Alpha | parallel, 15 m wide, 60 m west, connectors + hold-shorts at both thresholds |
| Apron | 180 × 100 m, west of Alpha, 7 spawn slots at 18 m |
| Field | 2,048 m grass — Roblox's max part size, and it contains the whole circuit |

**-Z is north.** There is no magnetic model, so a designator is just the world heading over ten: taking off toward -Z is runway 36. That was chosen because aircraft already spawned facing -Z, so `SPAWN_ORIGIN` needed no rotation — only a new position.

### Data is available before Init(), geometry is not

Every question-answering function — `getRunway`, `navPoints`, `apronSlotCFrame` — is a pure function of the constants and works the moment the module is required. Only `build()` touches the world.

That is a **load-order fix, not tidiness**: `Init.server.luau` started services by walking `Services:GetChildren()`, whose order Roblox does not define, and `AircraftService` asks for an apron slot during its own `Init()`. Making the answer pure means the race cannot exist. An explicit `SERVICE_ORDER` was added to the bootstrap as well, listing the airport first — belt and braces, and consistent with what that file already says about explicit ordering.

### The ground is now a raycast, closing §10's note

`Kinematics` gained `groundY`, measured by one downward ray in `readKinematics` — **not** in `computeForces`, which stays pure. §6 calls that purity out as worth preserving and it is what lets the aero model be tested without Roblox simulating anything; a raycast inside it would have ended that for one term.

The ray is capped at 1.2 × the largest declared `groundEffectSpan`, so it can only find ground that could matter, and returns `nil` above that — which is almost always, making the early-out free. `nil` means no ground effect, which is a real answer beyond the edge of the field.

Deliberately **not** shared with `GroundHandling`'s probes: those are per wheel and about a tyre radius long. They answer "is this wheel touching?", which is a different question and stops far short of the distance ground effect still cares about.

Verified live: **4.5e-8 over the runway, −0.050 over the grass, nil at 400 m.**

### Two real bugs the suite caught immediately

1. **The circuit did not fit the world.** `CIRCUIT_EXTENSION = 800` put the upwind point at Z = −1,300, three hundred metres past the edge of a ±1,024 m field — a pilot flying the circuit would have been over open space. Now 450, and asserted.
2. **`Workspace.SpawnLocation` was sitting on the runway.** Its 12 × 12 m pad has its top face at y = 1.00 (§6e) and it was on the world origin, which the runway now runs through — a one-metre ledge in the middle of the takeoff roll. It is now on the apron at (−150, 340), **flush at y = 0**, and Rojo-managed.

That second one generalises, so `runTests()` now **sweeps the whole runway and taxiway** for obstructions rather than probing one point. Anything dropped into `Workspace` near the origin lands on the runway and nothing else would report it.

It also closes the §0 note about aircraft parking 30 m from the spawn pad: **the pilot now materialises on the apron beside their aeroplane.**

### Why the airport is built in code

`AircraftBuilder` already builds the aircraft from a definition, and the airport follows it. A JSON tree of 130 parts would be unreadable, undiffable and untestable, whereas constants can be asserted — that the runway part matches the registered dimensions, that the top face is exactly y = 0, that no marking is collidable or queryable. The grass stays with Rojo because a runtime-built field would leave Studio's Edit view with no ground at all.

---

## 12. Nose wheel steering — rebuilt (2026-08-04)

Reported by the pilot as "not sensitive enough, entirely reliant on rudder". **Both halves of that were worth measuring, and the measurement disagreed with the diagnosis while confirming the complaint.**

### What the measurement actually showed

The nose wheel was already doing nearly all the work — gear yaw moment against aerodynamic yaw moment, full pedal:

| ground speed | gear | rudder | ratio |
|---|---|---|---|
| 2 kt | 1,576 N·m | 1.7 N·m | 924 : 1 |
| 10 kt | 1,303 N·m | 43 N·m | 31 : 1 |
| 19 kt | 954 N·m | 171 N·m | 5.6 : 1 |
| 39 kt | 286 N·m | 682 N·m | 0.4 : 1 |

So it was never rudder-dependent. But the aircraft **still would not turn**: full pedal at 12 kt gave **5.8° in five seconds, 1.7°/s, a 207 m turn radius**, against about 10 m for a real 172.

### Why 1,300 N·m turned nothing

All three wheels shared **one fuselage-fixed lateral axis**, and steering was a sideways *force* applied at a nose wheel that stayed **pointed straight ahead**. Meanwhile the main tyres' lateral grip cancels sideways motion within a single timestep — so the mains were vetoing precisely the rotation the nose was requesting. The two fought, and the mains won.

A real steered wheel does not push sideways. It **points**, and the aircraft follows because the wheel rolls where it is aimed.

### The fix

Each wheel now has **its own** rolling and lateral axes; the steered one is rotated by `steerAngle`. The cornering force then emerges from slip angle through the grip machinery that was already there. `steeringAuthority = 0.55` (a fraction of grip) became **`steeringAngle = 10°`** — the real pedals-only figure, which with the 1.8 m wheelbase gives an Ackermann radius of 1.8/tan(10°) = **10.2 m**.

This keeps §6b's principle exactly: steering is still a force and the yaw still comes from `r × F`. The wheel is merely aimed first.

**Measured after, same test:** **88.9° in five seconds, 20.3°/s, a 19.3 m radius** at 13 kt. Larger than the 10.2 m ideal because the speed fade has already pulled the angle back to ~7° by 13 kt, plus real tyre slip — which is the behaviour wanted, not an error.

### A tyre curve was needed to make the speed fade work again

The first version broke "steering authority fades with speed" — 2,943 N·m at 5 m/s against 2,984 N·m at 24 m/s. The one-timestep lateral cancellation is effectively **infinite cornering stiffness**, so the tyre sat at its grip limit for *any* steering angle, and reducing the angle from 10° to 0.4° left it just as saturated.

The steered wheel therefore got a real tyre curve: cornering force rises with slip angle and saturates at **`tyreSlipAngle = 6°`**, the ordinary figure for a pneumatic tyre. A 10° taxi input is past saturation and pulls full grip; the fraction of a degree left at rotation speed produces almost nothing, which is what hands the aircraft to the rudder.

Applied to the steered wheel only, deliberately. For a main wheel tracking straight the slip is incidental and tiny, so infinite stiffness is a fine approximation and the existing lateral-grip tests cover it; for the steered wheel the slip is *commanded* and large, and it is exactly the thing being modelled.

### One side effect, and it is correct
**A stationary aircraft no longer steers at all**, however hard the pedals are pressed. Cornering now needs slip, and slip needs rolling. That is true of the real aeroplane — it turns on the ground by rolling, or by differential braking, which is not modelled. A test asserts it.

### `GroundHandling`'s test rig had to move (§12)
Its fixture built a 400 m pad and a 1,111 kg aircraft at **the world origin** — which is now the middle of runway 18/36. Running the suite would have dropped a slab coincident with the runway surface and an aeroplane on the centreline in front of anyone on short final. Now at (−5,000, −5,000) on its own pad. Same class as the leaked rigs in §7; the airport turned it from untidy into dangerous.

---

## 13. Pitch trim — the tailplane was rigged backwards (2026-08-04)

Reported by the pilot as "really hard to nose down when coming in for the landing", with a guess that the yoke's centre relative to the mouse was off. **The complaint was exactly right and the guess was not** — the cursor centre is provably neutral (§6g verified the GUI inset live, and a test asserts a centred cursor gives pitch and roll of exactly 0).

### What was actually wrong

Stick required to hold level flight, measured by solving for the attitude where the pitching moment is zero *and* lift equals weight:

| configuration | before | after |
|---|---|---|
| cruise 100 kt | −0.38 | **−0.02** |
| 65 kt clean, idle | +0.29 | +0.65 |
| **65 kt full flap, idle** | **−0.79** | **−0.43** |
| 70 kt full flap, power | −0.94 | −0.58 |
| Vy climb 74 kt | — | +0.37 |

The aeroplane needed **79% nose-down stick** to hold an approach, and trim reached only ±0.35 — so it could not be trimmed off. With `mouseExpo = 0.35` that meant holding the cursor about 80% of the way to the top of the screen for the whole approach, while judging the flare. There was no way to fly it hands-off anywhere in the envelope, including cruise.

### Two sign errors, compounding

Reading the per-surface moments showed the `Stabilizer` producing **CL 0.000 and 0 N** — carrying no load at all — while the wing produced +2,873 N·m nose-up with flaps down.

1. **The wing's aerodynamic centre is 0.19 m AHEAD of the centre of mass**, so wing lift is a nose-**up** moment. That geometry is correct for a 172, whose CG range (35–47% MAC) is genuinely aft of the quarter-chord — so it is not the bug, but it inverts the usual textbook picture.
2. **A tail download acts behind the CoM and therefore also pitches the nose up.** So `STAB_INCIDENCE = -2.0` was *adding* to the moment it was supposed to balance.

The old comment on those constants asserted the opposite of both — "a download that balances the nose-down pitching moment of the cambered wing". Two wrong claims in one sentence, and nothing tested either of them.

**With the CG aft of the wing AC, the tail must LIFT to trim**, so the incidence has to be positive. The first sweep I ran went the wrong way (−2 → −5 made it steadily worse) precisely because I reached for the textbook picture before checking the sign.

### The fix, and why these numbers

- **`STAB_INCIDENCE` −2.0° → +1.0°.** Chosen by measurement: it is the value that puts the cruise stick at −0.02 and centres the whole envelope (−0.43 to +0.65) about neutral rather than hard against the nose-down stop.
- **`trimLimit` 0.35 → 0.7.** Derived from the span above, not felt. Trim exists so the yoke can sit neutral in any configuration; a limit less than half the aircraft's own trim requirement is a missing control, not a safety margin.

### Nothing else moved

This changes **trim, not stability** — static margin depends on lift slopes and moment arms, not on rigging incidence. Verified rather than assumed; every published figure is identical:

| | before | after |
|---|---|---|
| Max level speed | 130 kt | **130.2 kt** |
| Rate of climb at Vy | 783 ft/min | **783 ft/min** |
| Glide ratio power-off | 9.9:1 | **9.88:1** |
| Clean stall | 52.9 kt | **53.0 kt** |
| Full-flap stall | 45.4 kt | **45.4 kt** |
| Static margin | 14.2% MAC | **14.2% MAC** |

### Three regression tests
`Cessna172.runTests()` now asserts the wing AC is ahead of the CoM, that the tailplane is rigged to **lift** (a sign check, because it is the sign that was wrong and a CG change would silently flip it), and that the incidence stays in a range that keeps cruise trim near neutral. `InputController` asserts the trim range covers the aircraft's measured trim requirement, and its "trim is limited" check now derives from the constant instead of hardcoding 0.35.

---

## 14. Plan — Phases 2 to 14 (with 4b, 4c)

Written 2026-08-04, at the pilot's request, **before** starting Phase 2. The rule from §8 still holds: each phase ends with a gate the pilot flies and signs off, and nothing downstream begins until they do. Phases 5 and 6 were planned the same day, at the pilot's request, once Phase 2 had a full instrument set to carry them — a weather system no instrument can read is pointless, so the order is deliberate.

Phases 7–12 were added on 2026-08-06, at the pilot's request, as the game's direction past the flight model: the world (more airports, scenery), UI depth and the interactive map, ATC, airliners, fighter/carrier ops, and mesh as the deliberate final polish. They are deliberately lighter than Phases 2–6 — goals rather than gates — because they are about *world* and *content*, not *physics*, and they are why the primitive shell (§31) carries the game for a long time.

Two phases already ran out of order and it is worth knowing why, because the roadmap in memory still reads as though they have not:
- **`CameraController` (§6h)** landed during Phase 1 — flying the gate through Roblox's default character camera would have been miserable.
- **`AirportService` (§11)** is a Phase 3 item, brought forward because the Phase 1 landing gate could not be judged on a featureless baseplate. Phase 3 therefore starts from a working airport rather than nothing.

### Phase 2 — Cockpit instruments ← NEXT, and the only one to build now

**Goal:** replace reading raw numbers with reading instruments, so the aircraft can be flown on the panel rather than on the debug HUD.

**Scope**
1. **An instrument framework.** A shared module owning the redraw loop at `Constants.SIM.INSTRUMENT_HZ`, the needle-angle maths, and the dial/tick drawing. Individual gauges should be data — arc ranges, tick spacing, needle mapping — not bespoke code each.
2. **The six-pack**, in the standard layout: airspeed, attitude, altimeter, turn coordinator, heading, vertical speed.
3. **Engine and fuel**: tachometer, fuel quantity, and the AoA/stall indication added in §15.
4. **The debug HUD stays**, on a toggle key. It is the diagnostic that found two real bugs (§6i, §15) and the gauges do not replace it.

**Constraints that are already known, and are not negotiable**
- **Nothing may be `Active` or a `GuiButton`** (§6i). The cursor is the yoke and covers the whole screen; an input-absorbing element eats the flight controls. A test counts them and requires zero.
- **`IgnoreGuiInset` stays false**, which sidesteps the coordinate trap in §6g by construction.
- **Units convert at this boundary and nowhere else.** The physics stays pure SI; m/s become knots and radians become degrees here, and nothing converted travels back.
- **Arcs come from `Cessna172.limits`**, which already carries vs0/vs1/vx/vy/vfe/vno/vne for exactly this purpose. The white and green arcs and the redline are then the aircraft's real numbers rather than drawn by eye.

**How to test it.** The needle mapping is a pure function of a telemetry value, so it can be driven with synthetic numbers: 0 kt sits at the start of the dial, Vne at the redline, and the arcs land on the published speeds. That is the same shape as every other suite here — assert against the published figure, not against what the code currently draws.

**Gate:** fly a circuit on instruments — hold an altitude on the altimeter, a speed on the ASI, and a heading on the DI, and confirm the AoA indication marks the stall.

🧭 **The gauges are a stepping stone to a 3D panel inside the Cessna** — a `SurfaceGui` on a part, not a screen overlay. That is why `Instrument.luau` is rendering-agnostic and `SixPack.buildPanel()` is separable from its `ScreenGui` wrapper. See §19; the constraint is held by a test rather than by prose.

### Phase 3 — The world

**Goal:** somewhere to fly *to*. Depends on Phase 2 only for the navigation display.

- **Terrain.** The single largest known trap is already documented: **`FlightModel`'s ground probe assumes nothing** now that it raycasts (§11), but `AirportService` still assumes its pavement sits at y = 0. Terrain means the airport has to be placed *on* it, and the runway surface becomes whatever the terrain says.
- **More than one airport.** `AirportService` is already a registry keyed by runway id; it needs a layer above that keyed by airport, and `AircraftService` needs to ask which airport a player is spawning at rather than assuming the only one.
- **Navigation points** already exist per runway (threshold, aiming point, the circuit). Phase 3 extends them between airports.
- **Streaming.** Roblox's max part size is 2,048 studs and the current field is exactly that; anything larger needs several parts and a streaming config.

### Phase 4 — The aircraft

**Goal:** make the Cessna look like a Cessna. The physics has been flown against a crude box model since Phase 0 — deliberately, because the numbers were the priority — and the box is now the most visible thing left. This phase replaces it with a properly modelled inside and out.

**Scope**
1. **Exterior.** The fuselage, wing, tail, struts, gear and prop modelled to the 172S's real shape, replacing the `Cessna172.model` boxes. **The aerodynamic offsets and part layout must NOT change** — `FlightModel` caches geometry at spawn from the definition, the CoM and static margin depend on the mass layout, and §4's published figures are all measured against the current budget. If the model is redrawn, the definition is re-verified, not assumed.
2. **Cockpit interior.** Panel, seats, yokes, rudder pedals, trim wheel, throttle — and the 3D instruments from §19's roadmap, now that they have somewhere to live. The gauges already drop in almost unchanged: `SixPack.buildPanel()` builds into any parent, `Instrument.luau` is rendering-agnostic. **Two seats, offset like the real 172 (2026-08-06, pilot): pilot LEFT (x ≈ −0.30), copilot RIGHT (x ≈ +0.30), shared centre pedestal between them.** ⚠️ `PilotSeat` today sits on the centreline (0, 0.15, −0.40); the interior shifts it left, and the right seat is a second occupant position (Phase 13). The right seat must have its own yoke and throttle within reach, and the panel/pedestal switches must be reachable from BOTH seats — the copilot presses buttons too.
3. **Controls and switches as 3D parts** — buttons, knobs, circuit breakers, the whole panel face — **visual only for now**, inert and non-interactive.
4. **Interactive later, not now — and when it comes, it is keyboard-bound.** The cursor-is-the-yoke rule (§6g, §7) means a clickable switch mid-flight *is* the flight controls by construction. **Decision (2026-08-06, pilot): interior switches get keyboard binds, not clickable UI** — each switch is assigned a key that flips it on/off, and the 3D part visibly toggles state as the key is pressed. No modal state, no cursor capture, no ground-only gating: a key press costs no cursor movement at all (the same reasoning that made ViewToggle a key, §6k). This resolves the decision here and in §4b/4c — the switch *state* is driven by the same key system `InputController` already owns, and the cockpit part is a mirror of that state.
5. **The pilot you see in the cockpit IS the player's avatar — not a random prop.** **Decision (2026-08-06, pilot): when you sit down, the arms and body inside the cockpit are your own character.** The player's real rig is positioned into the pilot seat and rigged so its hands grip the yoke, its feet reach the rudder pedals, and one arm rests on the throttle — driven from the **same control signals** that already move the ailerons, so the yoke visibly swings with your stick, the pedals with rudder, and the hands animate between yoke / throttle / flap lever as you use each function. In first person you look down and see your own avatar's hands and legs on the controls; in chase view it is your avatar sitting in the seat. ⚠️ This brings the avatar's own proportions into the cockpit — the R6's blocky 0.40 shoulder ratio (§33/§36) is now visible in the seat, and the ~0.60 m shoulders in a 1.16 m cabin is the trade-off the pilot accepted with this choice. Nothing touches physics — the character is neutralised (massless, non-collidable) as §6d already does, so §4's budget and the CoM are untouched.
6. **The copilot is another player's avatar.** **Decision (2026-08-06, pilot): the right-seat occupant is a second player's real character, not a generic rig** — in the future multiplayer, the copilot is whoever boards the right seat, rigged to the same pedestal/yoke/pedals. In single-player there is no generic stand-in; the right seat is simply empty (or occupied only when a second player boards, Phase 13). One shared rigging recipe, applied to whichever player sits where. ⚠️ **The copilot must be ABLE TO DO THE JOB, not just sit there (2026-08-06, pilot):** the right seat gets its own yoke, its own throttle, and reach to the panel and centre pedestal so the copilot can press switches and handle the controls. Each player has their own keyboard, so the keyboard-bound switch decision (item 4) gives the copilot their own binds into the same `state.systems` switches. Two ~0.60 m-shoulder avatars side by side in a 1.30 m cabin is snug but realistic — a real 172's occupants do touch shoulders — and it is the look the pilot chose.

**Refined for realism (2026-08-04), at the pilot's request.** This phase is *modelling*, not *physics* — §4's figures are measured against the current mass and aero layout and must not move. Realism here means the aeroplane **looks and reads like a 172S** without changing what the physics does:

1. **Control surfaces move with the controls.** Ailerons, elevators, rudder, flaps and the trim tab visibly deflect with the pilot's actual inputs, and the prop spins up with RPM. Purely visual, driven by the same signals the physics already reads — the flight model is untouched by definition.
2. **The instruments read like a real 172, not like the physics.** The gauges have until now shown the perfect number. A real ASI carries static-source position error and the pitot is not where the airflow says it is; a real compass reads magnetic, not true, and lags in turns; the altimeter reads what its baro setting says, and `Atmosphere.getPressureAltitude` already feeds QNH in. These are **display errors, injected in the instrument layer and never in the physics**, and they are the entire training value of the phase — a pilot who learns on a perfect altimeter cannot read a real one.
3. **Cockpit detail from the real aircraft.** Panel, seats, yokes, pedals, trim wheel, throttle and circuit breakers laid out per the published 172S interior, so §19's `SurfaceGui` panel drops onto its real position. Reference material is already gathered (published 172S panel guides: flightnerdairforce, pilotmall, cessna172sim). **Left-seat pilot, right-seat copilot, shared centre pedestal — the 172's actual seating (2026-08-06, pilot).**
4. **Anything that moves the mass or the aero is a decision point, not an assumption.** Passengers and baggage shift the CG, and the CoM and static margin depend on the mass layout. If a phase ever wants loadable weight it starts by re-verifying §4's figures with the new layout — it does not silently change them. The modelled aircraft uses exactly the mass budget §4 measures.

The seated avatar (scope item 5) is part of this realism pass, with one extra rule: **its limbs read the same controls the surfaces read.** No new input plumbing and no separate body geometry involved — the player's own hands/feet are driven by `SurfaceAnimation`-style signals, so the first-person body and the ailerons can never disagree, because they are driven by the same numbers.

**Why this is Phase 4 and not before:** it depends on nothing in Phase 3, but it is the prerequisite for the tablet — there is no point choosing a destination "in the aeroplane" until the aeroplane has an interior. And the 3D-panel roadmap (§19) has been waiting on exactly this since Phase 2.

**How to test the seated avatar.** Same shape as the rest of the phase: pure functions of state. The rigged avatar's limb angles are a function of the same control values that drive the surfaces — assert the hands sit on the yoke at neutral, move with stick deflection, and migrate to the throttle/flap lever when those are commanded; the feet track rudder. The character stays neutralised (massless, non-collidable) while seated, so the existing mass-budget and one-assembly checks must stay green unchanged (§31, §6d). **Both seats get the same recipe (2026-08-06, pilot):** the rigging is written once and applied to whichever player sits where — assert it drives the left seat's pilot and the right seat's copilot identically, and that each seat's hands reach its own yoke/throttle at neutral.

### Phase 4b — Flight tablet ✅ BUILT, 2026-08-09 — see §46

**Goal:** choose an aircraft and a destination without leaving the aeroplane.

⚠️ **The decision this section demanded be made "before building it, not during" was made on 2026-08-09, and it is neither of the two options written below.** The pilot's answer: **on the ground OR with altitude hold engaged.** §46 has the build and the reasoning.

- Departure and destination pickers reading the Phase 3 airport registry.
- Distance and bearing to destination, which is `AirportService` navigation data presented rather than new physics.
- Aircraft picker driven by `Aircraft/Registry.luau`, which already maps id → definition and is the only thing that crosses the network at spawn.
- **The tablet is the first thing in this project that genuinely wants to absorb input.** The cursor-is-the-yoke rule (§6g, §7) means it cannot simply be a clickable UI while flying. ⚠️ **The 2026-08-06 keyboard-bind decision (Phase 4 item 4, 4c) resolves the SWITCHES but not the tablet** — a switch flips state on a key, but a picker chooses among airports/aircraft, which a key cannot do. The tablet still needs either a modal state that releases the yoke, or to be usable only on the ground. **Decide that before building it, not during.**

### Phase 4c — The missing 172S systems: rudder trim and everything the POH lists that we do not fly yet

**Goal:** close the gap between the aeroplane we have and the aeroplane the POH describes. Written 2026-08-06, at the pilot's request, after researching the full published 172S systems list and comparing it against what is modelled. The research source is the POH's systems chapter (fuel, electrics, trim, cockpit environment) and the Cessna 172S trainer guides; the rule from §4 holds — **anything that moves mass or aero is a decision point, re-verified against §4's figures, never silently changed.**

This phase is the systems *behind* the cockpit Phase 4 item 4 builds: **rudder trim, fuel selection, mixture, magnetos, master/electrical, engine gauges, cabin environment, and the lights**. It is deliberately separate from Phase 4 (the interior is visual-only; the switches are inert parts) — this is where some of them become real. Nothing here is needed for the world or the ATC phases, so it slots after the aircraft build work and before the weather.

**Scope — what the research found missing, in one list:**

1. **Rudder trim tab.** The 172S has a small tab on the rudder's trailing edge, driven by a knob on the pedestal. **There is no rudder trim at all** — `Rudder` (Cessna172.luau ~945) hinges only on the rudder channel, and no RudderTrim symbol exists anywhere. Model the tab like the elevator's (§37's `TrimTab`, including `hinge.parent = "Rudder"` so it rides the rudder *and* trims against it — compound motion, the §37 test shape), add a binding, and drive it on its own trim channel in `SurfaceAnimation`.
2. **Fuel selector.** The real 172S has a LEFT/BOTH/RIGHT/OFF valve in the pedestal feeding from two wing tanks. The sim has one `fuelKg` tank in the engine state. A selector changes *where* the engine draws from and makes tank imbalance a real behaviour (the POH's takeoff-and-land-on-BOTH rule becomes flyable).
3. **Mixture.** The 172S is fuel-injected (no carb heat — that is the 172R's carburetted engine) but it has a mixture knob for leaning. A leaner mixture changes fuel flow and the air/fuel ratio at the engine; at minimum it is a control the engine model reads.
4. **Magnetos / keyed ignition.** The 172S starts off a key with OFF-R-L-BOTH-START and a mag check is part of the run-up. The sim's `EngineToggle` (E) is a straight on/off. A keyed start makes the engine's `startTime`/starter work (§6's starter already exists) and adds a real procedure.
5. **Master / avionics / electrical.** BAT and ALT master switches, avionics master, circuit breakers, ammeter. The panel parts are modelled (Phase 4 item 4); this wires the *state* behind them — what is powered when, and the electrical load on the alternator.
6. **Engine gauges the POH lists that we do not read:** oil pressure, oil temperature, fuel flow. `SixPack` already samples telemetry; these are three more samplers and dials, with the POH's green bands.
7. **Cabin environment.** Cabin heat, ventilating and defrost controls (§ the POH systems list) — mostly switches and vents for now; doors and windows as detail.
8. **Lights that actually switch.** Beacon, NAV, strobe, taxi, landing — the parts exist (NavLightRight/Left, LandingLight, Beacon in Cessna172.luau) but are **inert**: no switch, no electrical dependence, no night effect. The electrical state from item 5 gives them a home.

**Constraints that are already known, not negotiable**
- **The Controls contract (six fields) must not change.** Trim, mixture, fuel selector, mags, master and lights are *systems* state in the `state.systems` style the engine toggle already uses — never new Controls fields (§6c's contract is pinned by tests).
- **Anything that changes the fuel mass split or engine behaviour re-verifies §4.** The 153 kg tank is one lump today; a two-tank layout moves CoM assumptions. Same rule as passengers/baggage in Phase 4 item 4.
- **The cursor-is-the-yoke rule (§6g, §7) applies to every switch.** **Decision (2026-08-06, pilot): switches are keyboard-bound, not clickable.** A clickable knob mid-flight IS the flight controls by construction, so each switch gets a key that flips it on/off and the 3D part toggles with the press — no modal state, no cursor capture, no ground-only gating (Phase 4 item 4, same reasoning as §6k). This phase builds the state the key drives and the cockpit part that mirrors it; the inert parts are already modelled.

**How to test it.** Same shape as every suite here: pure functions of state. Fuel selector BOTH drains both tanks, LEFT drains the left faster, OFF starves the engine in the POH's time; mixture leans fuel flow against a published figure; mag check shows the expected RPM drop; master off kills the ammeter read. Assert against the published numbers, not against what the code currently does.

**Gate:** the pilot re-flies with real systems — a start on the mag check, tank selection on BOTH for takeoff, trim flying hands-off in climb, and the engine gauges reading like the POH's green bands.

### Phase 5 — Weather and the air through which you fly

**Goal:** make the atmosphere the pilot's environment rather than a constant. Phase 4's instrument realism and this phase are two halves of the same thing — the aeroplane reads like a real one because the air it flies through behaves like real air. `Atmosphere.luau` is already the ISA foundation, verified against published tables, so weather is **inputs to existing, proven code, not new physics**.

**Scope**
1. **Wind.** At minimum a wind *layer* that changes with altitude — one wind at the surface and another aloft is what makes a real circuit different from a still-air one, and it makes crosswind landings exist by construction, which is the single highest-value skill this game can teach. `FlightModel`'s relative-wind model already acts on the air, so wind is a field added to it.
2. **Turbulence.** A gust model on the standard — Dryden or Von Kármán spectra, per MIL-F-8785C / MIL-HDBK-1797 — driving gust velocities the aircraft's own stability damps, as a real pilot damps them. The tuning rule: *persistent enough to feel like rough air, mild enough that a trimmed aeroplane still holds its trim.* §6i's peak-capture lesson applies here too — gusts act between physics frames, so any instrument fed by them needs the same peak treatment §15 proved was necessary for alpha.
3. **Wind shear and the microburst.** Low-level shear is the deadliest weather near the ground; the canonical case is the burst ~150 ft AGL on a 90 kt approach, where the loss of headwind is answered by a downdraft. This is the phase's gate, and the reason weather is not decorative — a scenario that makes a landing genuinely hard to save.
4. **Temperature and QNH as weather inputs.** `Atmosphere` already takes `tempOffsetC` and `qnhPa` — ISA deviation for hot-day performance and the pressure setting an altimeter reads. Phase 5 wires these to selectable presets rather than constants, and Phase 4's instrument-error mechanism becomes visible for the first time.
5. **A second aircraft — the jet.** `Aircraft/Registry.luau` is already id → definition and the only thing crossing the network at spawn. The jet proves the registry generalises and is where the compressibility correction `Atmosphere` notes for "the Phase 5 jet" actually gets exercised. **It is deliberately the last item in the phase**, not because it is small but because it is the risk: a second aircraft touches every assumption the first one made.

**How to test it.** Wind and gusts are deterministic fields given a seed, so the same seed must reproduce the same flight — assertable in the existing style. The shear gate is a scenario scripted to the canonical numbers (headwind loss, downdraft, height above threshold), flown on instruments.

**Gate:** fly a crosswind landing and fly the wind-shear scenario. The microburst must be **survivable but hard** — if it is not both, the numbers are wrong.

### Phase 6 — Audio, damage, persistence, tutorial

**Goal:** make the aeroplane *feel* like an aeroplane and *remember* what happens to it. Deliberately after Phase 5: audio and damage both need the aircraft and the weather they describe to exist first.

**Scope**
1. **Audio.** Engine note from RPM (the tach's own source signal), wind over the panel from airspeed, and the stall-warning horn wired to §15's `< buffet` threshold — the instrument layer already computes the exact events the sounds attach to. The panel is the centre of the mix, not the world: this is a cockpit sim, and the sounds that matter are the ones a pilot hears in the seat.
2. **Damage, in the damage-tolerance spirit of FAA AC 25.571.** A hard landing or an over-G pull should **mark** the aeroplane, not snap it. The design constraint is that a failure state must never invalidate §4's published figures silently — a bent wing changes the numbers, so the change is *surfaced* (visible damage, an instrument marking, a limitation) rather than hidden. Fatigue and overstress tracking at most: this is a training sim teaching "what the aeroplane is telling you", not a maintenance sim.
3. **Persistence.** The aeroplane remembers where it was parked, its fuel, its damage state and its hours — a DataStore behind `AircraftService`, which already owns the spawn path. Single-player by architecture; the store is the only new piece.
4. **Tutorial, which already has a skeleton: the gates.** Every phase gate is a task a pilot can actually do — taxi, circuit on instruments, crosswind landing. Phase 6 turns them into an in-game syllabus: choose a lesson, get the aeroplane and weather set up for it (the Phase 5 presets do this for free), fly the gate, and the logbook records the pass.

**How to test it.** Damage thresholds are numbers against §4's verified limits — assert the published envelope holds up to its edge and marks beyond it. Persistence is save → reload → assert the same state. Audio is the one thing arithmetic cannot check: same rule as §17's trap — **if a module makes a sound, listen to it.**

**Gate:** fly a full session with weather, land hard enough to bend something, reload, and find the aeroplane where you left it — damaged, with the hours to prove it.

### Beyond Phase 6 — where the game goes after the flight model is finished

**Phase 5 is NOT the finish line.** It is the end of the *current flight-physics scope*; the pilot has confirmed the game continues after it. The roadmap below is deliberately lighter than Phases 2–6 — written as goals rather than gates, because these phases are about *world*, not *physics*, and they are the reason meshing is the very last thing on the list. The primitive shell (§31) carries the game through every phase up to it.

**Phase 7 — The world grows: more airports and what they sit in**

- **More airports.** `AirportService.AIRPORTS` is already a registry keyed by airport id, each declaring its own elevation and grass type (§23, §24). Ridge Strip proved the pattern generalises; the next aerodromes are mostly *content* — new registry entries, runway geometry on a new heading, elevation and surface — plus whatever `getRunway()` needs to stay scoped per field. The "second full-size airport does not fit beside the first" constraint (§37) still shapes how far apart they go.
- **Buildings and scenery.** Hangars, terminal, fuel pumps, windsock, ground clutter — static, massless, welded, and most importantly **collidable where they need to be** (a pilot should be able to clip a wing, not fly through a hangar). The structural-box rule does not apply here: these are world objects, not part of the aircraft, so they get ordinary `CanCollide`. Painted cheap — see the mesh note below.
- **Runway and apron detail.** Approach lighting, PAPI/VASI, taxiway signage, holding points, tie-downs — the depth cues §11 proved a landing gate needs, extended to the whole field.

**Phase 8 — UI depth, inside and out**

- **Interface and menus.** Main menu, pause, settings (controls remap, audio, weather preset selection from Phase 5), flight log. The cursor-is-the-yoke rule (§6g, §7) already dictates the hard part — anything clickable needs the same modal-state-or-ground-only decision the tablet (§4b) and switches (§14 Phase 4 item 4) already settled.
- **The interactive map.** The tablet's Phase 4b destination picker grows into a real moving map — airports, runways, your own position/heading, distance and bearing, later course lines — built on the same `AirportService` registry and navigation data it already reads. This is the natural home for it: the map is interface, not physics, and by Phase 8 every aerodrome it draws actually exists.
- **Cockpit indicators.** Beyond the six-pack: the wet compass on the windscreen frame (§32's turning-error model is already written and waiting), trim indicator, flap position, gear, circuit breakers that actually pop, the G-meter the damage phase hints at. Instrument.luau is rendering-agnostic and `SixPack.buildPanel()` builds into any parent, so new instruments are spec data, not new gauge code.
- **HUD polish.** The debug HUD becomes a *pilot's* HUD — airspeed, altitude, heading, glideslope on approach, trimmed, toggled on H as today.

**Phase 9 — ATC: clearance and conversation**

**Goal:** a tower that talks back. The pilot chats to a controller and gets real clearances — *"N172SP, cleared for takeoff runway 36"* — for the full procedural loop: clearance → taxi → line up → takeoff → frequency handoff between airports, and approach/landing back in. This is what makes the training sim *procedural* rather than *freeform*: the gates (§26) already teach flying; ATC teaches flying *the way it is actually flown*.

- **Rules-based core, first and load-bearing.** A deterministic server-side state machine per airport that knows its runways, taxiways and procedures, parses the pilot's chat for the standard calls ("request taxi", "ready for departure", "clearance to"), and answers from its state — issuing clearances only when the aircraft is actually where it must be. Zero cost, zero latency, fully testable in the existing style (same seed → same session). This is the whole product if the AI layer never ships; it is also the safety net under it.
- **LLM layer, on top, interchangeable.** An optional real-AI controller wired through `HttpService` from a **server** script (⚠️ the API key lives server-side only — never in a client script, which anyone can read), fed the aircraft's live state (position, altitude, airspeed, phase) as context. It converses freely and can handle anything the rules would answer with a canned line. Rate-limited and paid per message, so it defaults off with the rules core running underneath, and **when it fails or is disabled, the rules still answer**.
- **Chat plumbing.** The pilot's chat is read server-side and routed to whichever ATC layer is active; responses appear as the controller's speech in the same chat. Ground-only and in-air frequencies (local tower → departure → approach) give the handoff something to do.
- **How to test it.** The rules core is a state machine — assert clearance is refused when the aircraft is on the wrong taxiway, granted when it is lined up, and handed off at the airport boundary. The LLM layer is the one thing arithmetic cannot check: same rule as §17's trap — **if a module talks, listen to it.**

**Phase 10 — Airliners: Boeing and Airbus definitions**

**Goal:** fly the big stuff. Where Phase 5's jet (§14) proves the aircraft registry generalises, this phase does it at scale: a fleet of airliner definitions — the 737, 747, A320, A350 class — each with its published geometry, mass, performance and cockpit, through the same definition → builder → registry path the 172 uses. `Aircraft/Registry.luau` is already id → definition and the only thing crossing the network at spawn, so a new airliner is a definition, not new plumbing.

- **The definitions are the work.** Each airliner is a `Cessna172`-shaped definition: `Aerodynamics` surfaces from real wing area/AR/CL, an engine spec (high-bypass turbofan — the Phase 5 jet already exercises compressibility, the airliners exercise it in cruise), a mass budget in the 40–400 t range, and a cockpit with its own panel layout. The physics first: same rule as §4 — published figures measured against the mass and aero layout, and every phase gate flown.
- **Flying them is the point, not collecting them.** Airliner handling differs from the 172 in kind — far higher wing loading, inertial response, retracted-gear flap discipline, an autopilot that has to earn the Phase 5 / §29 altitude-hold work. Each aircraft type is signed off by a gate flown in that type before the next is added.
- **Meshing per type is deferred to Phase 12.** One airliner is meshed as the proof of the primitive-shell workflow; the rest ride the primitive shell until then. The control-surface rule holds (§31): a single mesh cannot deflect its own ailerons, so surfaces stay definition-driven whatever the exterior.

**Phase 11 — Fighter jets, and aircraft carriers in the ocean**

**Goal:** carrier ops. The ocean is the biggest thing Phase 3's terrain never touched — `Terrain` ends at the coast, so a carrier needs water that an aircraft can take off from and land on. Then the jet: a high-performance fighter definition (supersonic-era geometry and thrust, Phase 5's compressibility and the engine model's real work), flown off a moving deck.

- **The ocean and the carrier come first.** Water surface, deck geometry, catapult/arresting-gear physics — `GroundHandling` currently assumes a runway; carrier recovery is launch-and-recover forces on a ship that moves and pitches. This is a decision-heavy phase (moving-platform physics is new), so it is scoped before the jet that uses it.
- **The fighter definition.** Same definition → builder → registry path as Phase 10's airliners, but a very different flight envelope — high alpha, afterburner thrust, a stall that must not bite a pilot in the circuit. It is the risk case for the flight model: if the physics cannot hold a fast, low-AR, unstable platform, it fails here, where the 172 and the airliners could never expose it.
- **Gate: a carrier circuit.** Launch, transit, a bolter (touch and go without catching) and a trap — flown and signed off, with the arrested landing the phase's load-bearing moment.

**Phase 12 — Mesh: the final polish, deliberately last**

- The primitive 78-part shell is the exterior until here. Meshing is a **pure visual swap over unchanged physics** — the structural boxes stay, the control surfaces stay ours (a single mesh cannot deflect its own ailerons, §31), and nothing re-tunes. One aircraft to make beautiful, dropped onto a finished world.
- This is why everything else comes first: mesh work is the one thing that touches only appearance, so doing it after the world, the aircraft and the carrier exist means a single mesh project covers all of it and cannot break anything.
- The purged Sketchfab import (§33) and `CREDITS.md` are the standing note: when the day comes, either re-evaluate that asset or commission/reference a fresh one.

**Beyond — deliberately not planned yet**

Phase 13 (multiplayer sky) and Phase 14 (career — the tablet's destinations as goals) stay as headings only. They are where the architecture already points — server-authority since Phase 1, the tablet's destination picker since Phase 4b — but planning them now would be guessing about a game that has not yet been flown end to end.

---

## 15. The AoA readout — not a bug, two missing things (2026-08-04)

Reported as "the AoA indicator is bugged — it flutters around a number and doesn't go higher when I've clearly pitched well past 20 degrees". **Alpha was correct throughout.** Flown as a real stall entry on the server, full aft stick from cruise:

| time | AoA | pitch attitude | wing CL |
|---|---|---|---|
| cruise | +1.1° | −3.7° | 0.48 |
| +1.5 s | +8.7° | **+20.8°** | 1.13 |
| +4.5 s | +10.6° | **+45.4°** | 1.29 |
| +7.5 s | **+18.6°** | +22.9° | **0.84 ← the break** |

Alpha does exceed 18°, and CL collapses from 1.48 to 0.84 exactly where it should. What was missing was the context to read it by.

### Missing thing 1: attitude was never on the panel

**Alpha is measured against the AIRFLOW; attitude against the HORIZON.** In a climbing pull the flight path curves up to follow the nose, so 20.8° of attitude with 8.7° of alpha is not a fault — it is what a pull looks like. With only alpha displayed there was nothing to reveal that, and it reads as a number that refuses to move.

`telemetry.pitchAttitude` and `telemetry.bankAngle` are now computed in the same block as alpha and beta — `asin(LookVector.Y)` and one `atan2`, so effectively free — and the HUD shows `ATT` directly beneath `AoA`.

### Missing thing 2: alpha had no peak capture

§6i already argues that a 30 Hz readout drops most of what happens between samples, and applies per-frame peak capture to load factor and force magnitude. **The same argument applies to alpha and was never applied to it.**

That is precisely what hid the stall. Measured with peak capture live: at +8 s the instantaneous alpha had already fallen back to 13.3°, while the peak over that interval was **19.4°** — so the panel now still reads `<< STALL` for an event that had finished before the redraw. Without the peak, the single most important number of the whole manoeuvre was the one most likely to be missed.

### And the marking the pilot actually asked for

`FlightModel` now publishes **`telemetry.stallAlpha`** — the stall angle of the largest surface by area, which is the main wing on anything that flies. Static, written once at construction, and in the telemetry table because it is meaningless to the physics and essential to an instrument: alpha alone cannot say whether the number in front of you is fine or a departure.

`DebugHud.stallState(alpha, stallAlpha)` is pure and exported, returning `"stall"`, `"approaching"` or nil. The buffet warning starts **3° early**, roughly where a real stall warning horn is set. Three details are asserted:
- **Magnitude, not sign** — an aeroplane can stall inverted, and a positive-only check stays silent through exactly the departure worth warning about.
- **No stall angle means no marking**, not a guessed one. An instrument that invents its own limit is worse than one that stays quiet.
- A NaN alpha never claims a stall.

Measured live: `< buffet` at 13.6°, `<< STALL` at 18.5°, against a 16.0° stall angle.

### Reading this later
The lesson generalises past this panel and is worth carrying into the Phase 2 gauges: **a raw number is not an instrument.** Alpha was right, available and displayed, and still told the pilot nothing useful, because an instrument has to carry the reference the number is judged against.

---

## 16. The yoke was biased nose-up by the GUI inset (2026-08-04)

Reported by the pilot: *"when I pitch up into a stall and do a loop de loop, it breaks the mouse cursor movement, it is extremely difficult to pitch down and is very easy to pitch up."*

**All three halves of that were literally true, and there were two separate defects behind them.** `FlightController` 29 → 35; everything else is untouched. **459/459 across 13 suites.**

### The measurement that found it

Injecting the cursor down a ladder of screen positions and reading `UserInputService:GetMouseLocation()` back, on a 1572 × 841 viewport with a 58 px inset:

| cursor | `GetMouseLocation().Y` |
|---|---|
| top of the game view | **58** |
| bottom of the game view | **841** |
| pushed below the view | 841 — clamped |
| off the view entirely | **−1** |

So the cursor's reachable range is `inset .. viewportHeight`, **not** `0 .. usable`. `readPointer()` was reducing `ViewportSize` by the inset (giving a half-height of 391.5) while feeding it a pointer that never went below 58 (whose true centre is 449.5).

Driving the real `InputController` with real pointer values, before the fix:

| cursor | pitch command |
|---|---|
| top of the screen — full nose-down | **−0.766** |
| mouse y 391 (nowhere in particular) | +0.000 |
| **middle of the screen** | **+0.085** |
| mouse y 783 — 58 px above the bottom | +1.000 |
| bottom of the screen | +1.000 — already saturated |
| **off the game view** | **−1.000, and roll −1.000** |

### Defect 1: neutral sat 58 px above the middle of the screen

Every one of the pilot's three complaints falls out of that table.

- **"Very easy to pitch up"** — the yoke's neutral point was the whole inset above centre, so resting the cursor in the visual middle of the screen already commanded +0.085 nose-up, and full nose-up arrived 58 px before the bottom edge with the last 58 px dead.
- **"Extremely difficult to pitch down"** — full nose-down was **unreachable**. The top edge of the screen, as far as the cursor can physically go, produced **−0.766** against the bottom's **+1.000**. A third of the nose-down authority did not exist.

**The fix is one line of arithmetic**: subtract the inset from the pointer as well as from the viewport. Verified live, real cursor through the real code path — top **−1.000**, middle **+0.000**, bottom **+1.000**.

### Defect 2: off the game view, Roblox reports (−1, −1)

Which the mapping read as a position: the top-left corner, **hard nose-down and hard left roll, arriving in a single frame**. That is the "breaks the mouse cursor movement", and defect 1 is what caused it — a pilot holding full back stick sits on the bottom edge of the screen by definition, and the last 58 px being dead invites pushing further, straight off the view and into the opposite corner.

An off-view pointer is now treated as **missing data, not a position**: `FlightController.resolvePointer()` holds the yoke where the pilot last put it, which is what a real yoke against its stop does. With no memory yet it answers with the **centre**, because `Vector2.zero` is the very corner this exists to prevent.

**Losing window focus is handled differently, and the distinction is deliberate.** Cursor off the view → the pilot is still flying, so the yoke holds. Alt-tabbed → they are not flying at all, so the yoke is released to neutral via the `neutralSnapshot()` path that typing already used. Trim survives both, so a trimmed aircraft simply flies on hands-off. An absolute yoke needs this and a relative one does not: a relative stick stops receiving deltas and stays put, while an absolute one keeps reading a cursor that is now being moved for something else entirely.

### What was NOT wrong

**The aerodynamics.** Elevator authority was measured at a loop-top condition — 20° alpha, full nose-down stick, across the speed range — and it scales **exactly** with dynamic pressure: 102 N·m at 40 kt to 638 N·m at 100 kt, and (100/40)² = 6.25 against a measured ratio of 6.25. It also pushes the same way as the aircraft's own high-alpha restoring moment, which is large and nose-down at 20° alpha — the aeroplane wants to recover, and was never fighting the pilot.

So **a slow loop still going mushy over the top is correct and will stay**: control authority falls with the square of airspeed, and that is the aeroplane, not the mapping.

**Trim, though it compounded this badly and is worth knowing.** `commandedPitch = clamp(rawPitch + trim, -1, 1)`, so full nose-up trim genuinely costs nose-down authority — measured, +0.70 of trim leaves **−0.300** of nose-down. That is real aircraft behaviour and §13 chose the ±0.7 limit deliberately. But **before this fix the two stacked to −0.066**, which is no nose-down authority at all. A pilot who had trimmed for the climb and then pulled into a loop had effectively no way out of it.

### The tests that would have caught it

Six new checks in `FlightController.runTests()`, and the fixture is the **measured** 1572 × 841 viewport with its 58 px inset rather than a round 1920 × 1080 with no inset — which is precisely the case that cannot fail.

The load-bearing one is written as a **symmetry**: *nose-down authority equals nose-up authority*. It needs no agreement about what full deflection ought to be, only that the yoke reaches as much of one as of the other, and it read −0.766 against +1.000. A second check pins where neutral physically **sits** — the middle of the visible strip, mouse y 449.5 — because a symmetry check alone cannot see the whole mapping being shifted. The rest cover the two edges mapping to the ends of travel, the off-view sentinel holding rather than jumping to a corner, the no-memory case being neutral, and an on-view cursor passing through untouched.

`FlightController.pointerSpace()` and `FlightController.resolvePointer()` are pure and exported for exactly this, the same shape as `shouldReset()` — the impure `readPointer()` is now only the two datamodel reads and a call to each.

---

## 17. `Instrument` — the gauge framework, built and green (2026-08-04, Phase 2 begins)

`src/StarterPlayer/StarterPlayerScripts/FlightSim/UI/Instruments/Instrument.luau`, **38/38**. The first item of §14's Phase 2 scope. **No gauge is built on it yet** — that is the next system.

It has no `Init()` and starts nothing. Like `InputController`, it is a library its consumer drives; `UIController` requires it only so `runTests()` covers the whole UI surface from one entry point.

### A gauge is a spec, not a module

An ASI and an altimeter differ in their numbers, not their behaviour: both map a value to a needle angle, tick at intervals, and paint bands over parts of the range. Written as code each they would be six near-copies drifting apart. So a dial is a `DialSpec` table, and **if a new instrument needs new code here rather than a new spec, the spec format is what is wrong.**

**The face is a breakpoint table** — `{ value, angle }` pairs, interpolated between and clamped outside — and that one mechanism covers every face in the six-pack:

| face | expressed as |
|---|---|
| linear dial | two breakpoints (`Instrument.linearFace`) |
| VSI, compressed above 1,000 fpm | three or four breakpoints |
| heading card | `period = 360` |
| altimeter hundreds needle | `period = 1000` |

A `curve` function was the alternative and was rejected: **a function cannot be inspected**, so the tests could not assert the green arc lands exactly on Vno without re-running the code they are meant to be checking.

**Angles are degrees clockwise from 12 o'clock**, which is exactly what `GuiObject.Rotation` does — so the computed angle is written straight to `Rotation` with no conversion. That is the whole reason for the convention.

### Ticks, arcs and the needle all go through `angleFor`

Which is what makes *"the needle is on the redline at Vne"* true by construction rather than by eye, and it is asserted anyway — "by construction" is precisely what §6g claimed about the yoke's centre. `arcBands` resolves each band's ends through the same function the needle uses, so the paint and the pointer cannot disagree.

**Arcs come from `Cessna172.limits`.** The white arc *is* vs0…vfe, the green *is* vs1…vno, the yellow *is* vno…vne, and the redline *is* vne — asserted against the definition, never against a number typed twice.

### The trap: Roblox rotates about the CENTRE, not the AnchorPoint

**All 38 checks' worth of arithmetic was correct and every needle still pointed at the wrong speed.** The suite passed 37/37 on its first run; a screenshot showed 95 kt indicating up and to the left, where it should have been down and to the right.

Measured rather than reasoned about, and the second probe is the decisive one: a needle anchored (0.5, 1) at the dial's centre and set to `Rotation = 180` pointed straight **up**, identical to 0. An anchor pivot would have pointed straight down. At `Rotation = 90` it sat as a horizontal bar centred half a needle-length *above* the hub — rotation about the frame's own centre, exactly.

So the frame that carries `Rotation` is now a **transparent pivot of twice the needle's length, centred on the hub**, with the visible bar a child occupying its top half. Two structural checks pin it down, because the failure mode is silent — no error, no crash, just a gauge that lies.

**The general lesson is in §7: arithmetic tests cannot verify a rendering.** If a module draws something, look at it.

### Two rates, which is §6i's lesson carried forward rather than rediscovered

The shared loop is **one** Heartbeat connection for the whole panel — eight gauges with eight accumulators would redraw at eight phases and make the panel shimmer. `update` runs at `INSTRUMENT_HZ`; **`sample` runs every frame.** §6i and §15 learned twice that a 30 Hz readout drops what happens between samples, and that the stall break lasts under a second. Anything needing a peak or an edge registers a sampler.

`stepLoop(dt)` is exported and driven by hand from the tests, which is the only way to assert the redraw rate without waiting on real frames: 60 calls at 1/60 give exactly 30 redraws and 60 samples. The accumulator keeps its **remainder** (zeroing runs the panel slower than requested for any rate the frame time does not divide) but **discards a backlog**, so a 10 s hitch redraws once rather than three hundred times — nothing here needs to catch up, because a gauge shows the current value.

### Needle lag is data

`lagTau` on the spec, first-order and **frame-rate independent** via `1 - exp(-dt/tau)`. The naive `current + (target-current)*k` settles four times faster at 240 fps than at 60, so an instrument tuned by eye on one machine is wrong on every other — the same correction `CameraController`'s smoothing needed. A real VSI is famously slow and will use this; 0 or nil is an immediate needle.

### Decisions worth not re-litigating

- **A value off the end of the scale clamps, it does not wrap.** A needle that ran past Vne and reappeared at the bottom would show a gross overspeed as a comfortable cruise.
- **A NaN parks the needle at the start of the scale.** Roblox does not reject a NaN `Rotation` — it renders nothing — so the needle would silently vanish and the gauge would look switched off rather than broken. Unlike the debug HUD, which prints `NaN` deliberately, a dial has nowhere to say it.
- **A face whose breakpoints descend is rejected at build time** and `build()` errors rather than drawing it. A silently mirrored face is the worst failure an instrument can have.
- **Arcs are painted as short tangential segments**, not as an image — an image would mean a new asset every time an aircraft's limits changed, which defeats deriving them from the definition. Segment size is `(length, thickness)`; ticks pass theirs the other way round, `(width, length)`, because at 12 o'clock a frame's height runs along the radius.
- **Minor/major tick coincidence is tested with a tolerance**, not a table lookup on the value. Both loops accumulate by repeated addition, so a fractional interval — a 0.1 g turn coordinator — lands on 0.30000000000000004 in one and 0.3 in the other, and an exact-key match would stack two frames at every major tick.

### Still to come in Phase 2
~~The six-pack~~ (built, §18), then the tachometer and fuel, then the debug HUD's toggle key.

---

## 18. The six-pack — built and green (2026-08-04)

`src/StarterPlayer/StarterPlayerScripts/FlightSim/UI/Instruments/SixPack.luau`, **34/34**, with the framework extended to 59/59 and `FlightModel` to 53/53. **561/561 across 15 suites.** Started by `UIController`; appears whenever the pilot is flying.

The standard layout, because it is the one every pilot's scan is built around:

| | | |
|---|---|---|
| airspeed | **attitude** | altimeter |
| turn coordinator | heading | vertical speed |

### Three new telemetry values, and why the ball is not beta

`FlightModel` now publishes `heading`, `turnRate` and `lateralAcceleration`, in the same block as `pitchAttitude` — §15's precedent. All three are SI and the instruments convert.

- **`heading`** is `atan2(look.X, -look.Z)`, so **-Z reads 000/360**. That is not a free choice: §11 defines runway 36 as the one flown along -Z, so the DI has to agree with the numbers painted on the ground. Asserted at all four cardinal points. **Verified live: parked on the apron the card reads 000, and the aircraft is facing runway 36.**
- **`turnRate`** is angular velocity about the **world** vertical, not the aircraft's yaw axis — they differ in a bank, and a standard rate turn is 3°/s of *heading* however steeply you bank to get it. Negated, because Roblox's positive yaw is to the left.
- **`lateralAcceleration`** is the ball, in m/s², positive to the aircraft's right — the same construction as `loadFactor` one line above, and correct for the same reason: gravity is never applied by this model, so `totalForce` is exactly what an accelerometer senses. **Sideslip could not have stood in for it**: β says where the nose points relative to the airflow, the ball is a pendulum answering to the resultant of every force. In a forward slip — flown and signed off in the Phase 1 gate — they part company, and only the ball tells the pilot what their feet are doing.

### The framework grew four things, all data

Each was driven by an instrument that could not otherwise exist, and each stayed in `DialSpec` rather than becoming code:

- **Multiple needles per dial** — the altimeter is one altitude geared two ways, hundreds and thousands.
- **The inclinometer ball** — not a needle, since it slides along a tube rather than sweeping about the hub.
- **A rotating card** (`rotatingCard`) — a DI turns its *face* under a fixed lubber line. A fixed card with a moving pointer is a different instrument and is far harder to hold a heading on, which is exactly what the gate asks for. Each number is printed at its own angle so it stands upright as it reaches the lubber line.
- **A wings symbol** (`shape = "wings"`) — a turn coordinator banks a little aeroplane, it does not sweep a pointer.

**The attitude indicator is the one exception to "a gauge is a spec"**, and it earns it: it has no needle at all. It is a moving picture, so it gets `buildHorizon`. Five pointer instruments genuinely are one mechanism; this is genuinely a second, and torturing a breakpoint table into drawing a horizon would have been the worse abstraction.

### `ClipsDescendants` cannot clip a rotated child, and that rebuilt the horizon

The obvious attitude indicator is an oversized sky/ground pair inside a rotating frame, clipped to a circle. **It cannot be built that way.** The suite passed 33/33 while the horizon painted itself across the airspeed indicator and the altimeter — §17's lesson, immediately repeated: a gauge that lies raises no error.

Measured three ways, all failing: a plain `Frame` clipper, a `CanvasGroup` clipper, and a clipper that is itself rotated. In the last of these the clipper's own rounded background rendered correctly while its child escaped — which is what makes the rule precise, and it is now in §7.

**So the horizon is drawn as a stack of chords.** A bar at perpendicular distance `d` from the centre is `2·sqrt(R² − d²)` wide — exactly the width that touches the rim and never crosses it — and the stack is rotated and recoloured sky-or-ground about the horizon. Rotate a chord and it is still a chord: containment is a property of the geometry, not of a clip that does not work. Bar count scales with the dial (~2 px each), because a count that looks smooth at 116 px is visibly serrated at 300 — measured by drawing one of each.

The containment check that pins this down is cheap because **a corner's distance from the centre of rotation does not depend on the rotation**, so `sqrt((w/2)² + (|d| + h/2)²) ≤ R` covers every bank angle at once. The same check is applied panel-wide to every needle.

### Faces worth knowing about

- **Airspeed** — 40…200 kt over 320°. Arcs entirely from `Cessna172.limits`: white *is* vs0…vfe, green *is* vs1…vno, yellow *is* vno…vne, redline *is* vne. A test asserts the scale reaches past Vne, or the redline would be off the dial through the whole overspeed it warns about.
- **Altimeter** — 1,000 ft per revolution, two needles. The face wraps, so the closing tick is suppressed: 1,000 ft is drawn where 0 is, and without that the labels stack.
- **VSI** — zero at nine o'clock, and **compressed above 1,000 fpm**: 80° for the first thousand, 50° for the second. That compression is the whole reason the framework takes a breakpoint table rather than a range.
- **Turn coordinator** — the symbol banks with *rate of turn*, index marks at ±3°/s. No numbers, because the real face has none. Ball full scale 3.0 m/s².

⚠️ **The VSI's lag is set to 2.0 s and a real one is slower** — six to nine seconds, because it measures the leak rate from a calibrated orifice. Two seconds is a deliberate playability compromise for a simulator where the pilot cannot feel the seat, and it is **the pilot's to overrule**.

### Three bugs the suites caught, one of which was mine twice over

1. **A needle inheriting the dial's face lost its own `period`.** The altimeter's hundreds needle reuses the 0…1,000 face but declares `period = 1000`; "inherit the face" threw that away and the needle clamped at 1,000 ft instead of wrapping. Inheritance is now per **field**. Code, not assertion.
2. **Lag across a wrapping face sends the needle the long way round.** Rolling out from 359° to 001° would drive a lagged compass card 358° backwards. Wrapping faces are never lagged, and neither the DI nor the altimeter wanted lag anyway.
3. **A clamp assertion read a position the code deliberately stops writing.** At the 60° pitch limit the horizon is 192 px from the centre of an 80 px dial, so it hides itself — the state that says "clamped" is `pitchValue`, not a position. **Seventh time the assertion was the wrong one.**

### How to test it

```lua
require(game.Players.LocalPlayer.PlayerScripts.FlightSim.UI.Instruments.SixPack).runTests()
require(game.Players.LocalPlayer.PlayerScripts.FlightSim.Controllers.UIController).runTests()  -- all three UI suites
```

**And look at it.** Twice now the arithmetic has been perfect while the picture was wrong. `SixPack.build(parent)` and `SixPack.render(built, telemetry)` are exported precisely so a panel can be driven with synthetic numbers and photographed without flying.

Verified live rather than only in tests: seated in the aircraft on the apron, the panel reads **0 kt on the bottom peg, 5 ft, 000 on the DI, level horizon, zero VSI, ball centred** — every one of them from real telemetry.

---

## 19. Tachometer, fuel, and the HUD toggle — Phase 2 build complete (2026-08-04)

**585/585 across 16 suites.** `SixPack` 34 → 48, `UIController` gains its own 10, `Cessna172.limits` gains two entries. **This closes the Phase 2 build; only the gate is left.**

### 🧭 THE 3D-PANEL ROADMAP, recorded here because it was not written down anywhere

**The instruments are eventually going to live inside the Cessna on a real panel, not floating on the screen.** That constraint was given verbally and was **not in this handoff** — it is now, because it changes how everything in `UI/Instruments/` must be written and would otherwise be lost.

The rule: **`Instrument.luau` stays rendering-agnostic.** No viewport, no GUI inset, no camera, no screen-space assumption anywhere in it — a gauge is a pixel-sized frame inside whatever parent it is given. In Roblox a 3D panel is a `SurfaceGui` on a part, and a SurfaceGui hosts exactly the same `GuiObject`s, so nothing has to be rewritten when the move happens.

`SixPack` is therefore split in two:

| | |
|---|---|
| `SixPack.buildPanel(parent)` | The panel itself — a fixed-pixel `Frame` of eight instruments, no scale positioning, **no knowledge of a screen**. This is what gets reparented into the cockpit. |
| `SixPack.build(parent)` | Wraps it in a `ScreenGui` and hangs it bottom-centre, under the cowling, where the 3D panel will sit. **This is the only throwaway part.** |

**A test builds the panel into a real `SurfaceGui` and drives it**, asserting the airspeed needle lands where its face says. If that check ever fails, something screen-specific has leaked into `buildPanel` and the 3D cockpit has quietly become a rewrite.

### The two gauges

**Tachometer** — 0…3,000 rpm. The green arc is `limits.rpmGreenLow` to **`engine.maxRPM`**, and the redline **is** `engine.maxRPM` by identity rather than by a matching literal, so changing the engine moves the arc with it. Same rule as the airspeed arcs.

Zero sits at the **lower left** and the scale sweeps clockwise through the top to the redline at the lower right. That is not decoration and it was a correction: the first version started at the top, which drove the cruise range round to the left-hand side of the dial. The green arc belongs across the top right, where the eye lands.

**Fuel** — and **it reads a LEVEL, not a mass**, which is why there is no unit conversion in it and no invented fuel density. A real float-type gauge measures how full the tank is; showing `fuelKg` as a fraction of `fuelCapacityKg` is the honest presentation of what the model actually has. Printing gallons would have meant inventing a kg-per-gallon constant the definition does not contain.

Marked **E, ½, F** with unlabelled quarter ticks. Five labels across 120° overlapped — drawn, looked at, and fixed — and the real gauge is sparse for the same reason. The red band is `limits.fuelReserveKg`, **derived** in the definition: 45 minutes at the cruise burn of 27.9 kg/h ≈ 21 kg.

Both are heavily lagged, and deliberately: 0.25 s on the tachometer because a real one is mechanically damped, **4 s on the fuel** because a gauge that twitched as the fuel sloshed through every turn would be worse than useless.

`ticks.labelNames` is the one framework addition — text labels matched to the labelled majors **by position, not keyed by value**, because both tick loops accumulate by repeated addition and a table keyed on 38.25 would miss 38.249999999999996. Same float trap the major/minor coincidence check already had to solve.

### The debug HUD toggles on H

The pilot's key, and it **replaces `Constants.DEBUG.SHOW_PHYSICS_OVERLAY` as the pilot-facing control**. The constant survives as the *starting* state and nothing reads it afterwards.

That forced a real change: `DebugHud.Init()` used to return early when the flag was false and build **nothing**, so there would have been no panel for a key to switch back on. The HUD is now always built and only its visibility is gated — see §7, because the lesson generalises.

**Owned by `UIController` on a lifetime `InputBegan` connection, not by `update()`** — the same rule as `ResetAircraft` (§6j) and for the same reason: `update()` only runs while a flyable aircraft is being flown, and the pilot must be able to set this from the apron so the HUD is already in the state they want when they board. Two checks assert H stays inert inside `update()`.

**H is a letter**, which makes the typing guard more than housekeeping: without it, typing "how high" in chat would strobe the panel. Both `gameProcessedEvent` and a focused-text-box check are applied, exactly as Backspace does.

`UIController.shouldToggleHud(keyCode, blocked, boundKey)` is pure and exported — the same shape as `FlightController.shouldReset()` — so the key is tested without a keyboard. **Verified live too**: real H presses, HUD off then on, with the six-pack unaffected both times.

### Verified live, not only in tests
Seated, engine started with E, full throttle on the takeoff roll, every gauge cross-checked against the debug HUD it does not replace:

| debug HUD | panel |
|---|---|
| RPM 2618 | needle in the green arc, below the redline |
| FUEL 152.8 of 153 kg | needle at F |
| IAS 68.9 kt | needle in the green arc |
| ALT 1.4 m | 5 ft on the hundreds needle |
| heading | 000 under the lubber line, on runway 36 |

### What is left in Phase 2
**Nothing to build. The gate remains**: fly a circuit on instruments — hold an altitude on the altimeter, a speed on the ASI and a heading on the DI, and confirm the AoA indication marks the stall.

---

## 20. Terrain, and the airport's elevation (2026-08-04 / 05, Phase 3 begins)

`src/ServerScriptService/FlightSim/Services/TerrainService.luau`, **19/19**, Server datamodel. Started first in `SERVICE_ORDER`, because it is the ground everything else stands on.

**This closes the largest known trap in §14**: `AirportService` assumed its pavement sat at y = 0, and terrain breaks that. The airport now declares an elevation of **250 m** and terrain is fitted to it.

### Everything here was measured before anything was built

Roblox terrain does not behave the way a height map does, and five measurements decided the whole design:

| measurement | result |
|---|---|
| surface height vs the top of the block you fill | **+2.000 studs**, constant to within 16 mm — half a voxel |
| flatness of a uniform fill, 1,000 × 22 m | **0.0000 m** peak-to-peak — exactly flat |
| a *sloped* fill vs what was requested | up to **1.23 m** deviation — the isosurface smooths it |
| a pavement part resting on terrain | the probe finds **the part**, which is what the wheels need |
| a terrain write, queried the same frame | **finds nothing** — writes need a frame to settle |

The flatness result is why an airport can sit on terrain at all. The slope result is why **the runway is still parts on a terrain pad** rather than terrain itself: a metre of error is not a runway, and §11's markings are load-bearing and cannot be painted onto voxels.

### Who decides the elevation

**The airport does, and terrain is fitted to it.** The arrow points that way deliberately: §11's load-order fix requires every question `AirportService` answers to be answerable *before* anything initialises, and taking the elevation from a service would put it back behind an `Init()`.

`AirportService.AIRPORTS` is now a registry keyed by airport id, with `elevationOf(id)` and `grassOf(id)`. The pilot's decision was that **each airport declares its own elevation**. The geometry below the registry still describes the primary field only — a second aerodrome's runway, taxiway and apron are the next system, and the registry is the seam they hang off rather than a finished feature.

**`grassOf` is not `elevationOf`.** Terrain is the *field*, 5 cm below the pavement. Building pads to `elevationOf()` put the ground exactly coplanar with the runway, and the test that asks whether the pavement still stands proud caught it immediately.

### The height field: weighted, not nearest-wins

Two pads at different elevations are each **exactly flat** (0.0000 m peak-to-peak, measured). But the obvious blending rule — nearest pad wins, fade to a base — is **discontinuous**, and measured as a **45.8 m cliff**: where two pads' regions meet, the chosen elevation flips while the fade factor does not.

Each pad's contribution is therefore **weighted**, which is continuous by construction. A pad reads exactly its own elevation only while no other pad's influence reaches it, so **pads must be further apart than `BLEND_DISTANCE`** — asserted for every pair, so whoever adds the second aerodrome finds out at test time rather than on short final.

### Block size is the resolution of every slope

Terrain is filled as flat columns, so the step between neighbours is the local gradient times the block size. Gentle relief hid this completely; two pads 50 m apart in elevation exposed it. Measured over the same field:

| block | fills | build | worst step between pads |
|---|---|---|---|
| 64 m | 1,024 | — | **21.51 m** — a staircase |
| 32 m | 4,096 | 0.22 s | 2.09 m |
| **16 m** | 16,384 | **0.41 s** | **1.14 m** |

16 m is chosen because 1.14 m *is* the isosurface's own error floor, so smaller blocks buy nothing. 0.41 s of server startup is worth a world without cliffs in it.

### What the baseplate became

`Workspace.Baseplate` is **retired at run time**, not deleted from `default.project.json`. It stays in the project file so the Studio *edit* view has a floor — terrain only exists at runtime. The same applies to `SpawnLocation`, which Rojo puts at y = 0 and `AirportService.build()` now lifts to the surface; a player would otherwise have spawned 250 m underground.

**Retiring the baseplate also removed the 2,048 m ceiling.** That was Roblox's maximum *part* size; terrain is not a part, and `Terrain.MaxExtents` measures ±32,000 studs. The world can grow far beyond the old field whenever a later phase wants it to.

### Two assertions that were wrong, not the code

- **A nanometre tolerance is finer than float32.** `"the runway top face is exactly y = 0"` compared `Position.Y + Size.Y/2` against the surface within `1e-9`. At y = 0 that passed; at y = 250 the spacing between representable float32 values is about 1.5e-5, so the sum lands on 250.000003. Tolerances are now a millimetre — still three orders of magnitude tighter than anything a wheel could feel.
- **A suite that depends on another service having run is flaky, not passing.** `TerrainService`'s "the pavement stands proud" check read the terrain height and failed, because it silently assumed `AirportService.Init()` had already built a runway — so the same code passed or failed depending on how far through booting the server was. It now builds the airport if it is missing, as every other suite in this project builds what it needs.

### Still to come in Phase 3
1. **A second aerodrome's geometry**, hanging off the registry seam. The pilot chose to **keep the 2,048 m field**, which constrains it: airport A's pad already occupies x −560…340, z −900…800, so a second *full-size* airport does not fit. Airport B has to be a shorter strip roughly 1 km out, not the 1.5 km hop originally sketched.
2. **Navigation between airports** — distance and bearing, presented the way the existing per-runway nav data is.
3. **Streaming is explicitly DEFERRED, not skipped.** The field is not growing, so nothing exceeds a part's 2,048 m limit and no streaming config is needed. Revisit only if the world grows.

### How to test it
```lua
-- Server datamodel. The suite BUILDS terrain, which replaces whatever is there.
require(game.ServerScriptService.FlightSim.Services.TerrainService).runTests()
```
**604/604 across 17 suites** — 502 client, 102 server.

⚠️ **The visual check was not completed.** Terrain exists only at run time, so the Edit view cannot show it, and `screen_capture` fights the running client's camera. The ground is verified numerically — pads flat to 0.0000 m, the field continuous to under 2 m over a 10 m step, relief inside its declared amplitude, pavement standing proud — but **nobody has looked at it yet**. Worth an eyeball on the next flight.

---

## 21. "Why is there nothing when I run play" (2026-08-05)

Two separate faults, found by measuring and then by looking. **604 → 605 checks; `TerrainService` 19 → 20.**

### Fault 1: no services started, in silence

The world had no airport, no terrain and no aircraft. But `Workspace.Gravity` read **9.80665** and `CharacterWalkSpeed` **7.00**, which proved the bootstrap had run and got past its requires — so this was never a sync or a load-order problem.

`startServices()` looked up `script.Parent:FindFirstChild("Services")`. Renaming the bootstrap from `Init.server.luau` to Rojo's documented lowercase `init.server.luau` **changed the tree shape**:

| file name | resulting tree | `script.Parent` |
|---|---|---|
| `Init.server.luau` | `FlightSim` **Folder** holding a Script named `Init` | the FlightSim folder — `Services` is a **sibling** ✅ |
| `init.server.luau` | `FlightSim` **is** the Script | `ServerScriptService` — `Services` is a **child**, not found ❌ |

So the rename silently moved the folder out from under the lookup. `startServices()` returned 0 and the bootstrap logged nothing about it.

**Both layouts are now checked, and a missing folder WARNS.** The failure was invisible precisely because it returned a number rather than raising anything.

### Fault 2: the runway was buried in grass

Numerically the world was perfect — pads flat to 0.0000 m, the field continuous, the pavement standing proud of the terrain by exactly 5 cm. Standing on the runway, it was **waist-deep in grass blades that grew straight through the pavement**.

Roblox draws grass decoration on `Grass` and `LeafyGrass`, sized for the **default stud scale** where a character is 5 studs tall. At 1 stud = 1 m (§2) those blades are one to two **metres** high — taller than the 0.4 m pavement they poke through.

That is not cosmetic: §11 exists because the Phase 1 landing gate was flown on a featureless plane and judged impossible, and the centreline dashes and edge markers **are** the depth and closure cues. Grass over them takes the runway away again.

`Terrain.Decoration` is the direct control and **does not exist in engine 0.732** — reading or assigning it errors. (Assigning it inside `build()` made the service throw before it filled anything, which is why the world briefly had no ground at all and the character fell through.) The material is therefore the only lever: the ground is **`Enum.Material.Ground`, tinted green** with `SetMaterialColor`, which has no decoration at all and reads as a mown airfield.

**Only looking found this**, which is now the fourth time in this project. A test asserts the ground material is never `Grass` or `LeafyGrass`.

### How to test it
```lua
require(game.ServerScriptService.FlightSim.Services.TerrainService).runTests()  -- Server
```
**605/605 across 17 suites** — 502 client, 103 server. Verified live: airport, terrain at 249.953 beside a runway at 250.000, aircraft spawned, baseplate retired, spawn lifted to 250.50, and the runway visible from ground level with its markings running to the horizon.

---

## 22. The ground for a second aerodrome (2026-08-05)

**608/608 across 17 suites**; `TerrainService` 20 → 23. The world is now **4,096 m** and carries **two flat pads at different elevations**. Ridge Strip's *runway geometry is not built yet* — this is the ground it will stand on, and the measurements that decided where it can go.

### A second aerodrome did not fit, and the reason was a stale constraint

Searching the real constants for the largest pad that satisfies the pad-separation rule inside the 2,048 m field returned **280 m square**, against the ~370 m of runway a 172 needs to leave the ground. No usable aerodrome fits.

**The 2,048 m limit was Roblox's maximum PART size**, and the field used to be one part. Terrain is not a part — `Terrain.MaxExtents` measures ±32,000 — so retiring the baseplate in §20 had quietly removed the ceiling without anyone noticing. The field is now 4,096 m, at a cost of 65,536 fills instead of 16,384: **1.96 s against 0.41 s**.

**Streaming remains explicitly deferred, and this is the same fact from the other side**: nothing in the world is a 2,048 m object any more, so there is nothing for a streaming config to solve. Revisit only if a *part* ever needs to exceed that.

### Blend distance is a trade-off against pad separation

Climbing 150 m between two fields, the worst gradient along the leg:

| blend | worst gradient |
|---|---|
| 400 m (the old value) | **108%** — a cliff |
| 600 m | 74% |
| 800 m | 55% |

A wider blend is always smoother, but **it must never exceed the narrowest gap between two pads** or they pull each other off their declared elevations. 700 m is the value chosen: it leaves 210 m of slack against the 910 m gap, and measures **54%** in the built world — a hillside.

That is why Ridge Strip sits at x = 1600 rather than 1500. At 1500 the gap is 810 m, which would have left ten metres of slack.

### Measured in the built world

| | |
|---|---|
| Meadow pad | 392 samples, **0.0000 m** peak-to-peak, at 249.953 |
| Ridge pad | 154 samples, **0.0000 m** peak-to-peak, at 399.953 |
| Meadow → Ridge, 1,728 m | worst step 4.29 m per 8 m = **54%** |

Both pads are *exactly* flat at their **own** airport's elevation, which is the property the registry exists for and which a single-pad world could not have tested.

### Ridge Strip, declared but not built

`AirportService.AIRPORTS.ridge` — elevation **400 m**, grass, runways **09/27**, origin (1600, 0, 200). It exercises everything a second aerodrome is for: a different elevation, a shorter runway, a different surface, and **a runway on the other axis**. 09/27 runs east–west where Meadow's 18/36 runs along Z, so the geometry builder will need a heading it has never had — and `getRunway()` is currently keyed by designator *globally*, which two airports break.

**Airport A's geometry is untouched**, as instructed.

### Two wrong assertions and one wrong measurement

- **Relief was bounded against ONE airport's height.** The check asserted the whole field stayed within `RELIEF_AMPLITUDE` of the primary field's grass — true of a one-pad world, false the moment a second aerodrome sat 150 m higher. It now bounds the field against the *spread* of declared elevations, which is what it was always trying to say.
- **The continuity threshold described a world that no longer existed.** 2 m over a 10 m step was fair with one pad and gentle relief; a 150 m climb has to be steep somewhere. It is now 8 m, which still catches the thing it exists for — nearest-pad blending produced a **45.8 m** vertical jump.
- **And one measurement was wrong before the code was.** A blend comparison reported Meadow's pad breaking by exactly 150 m at BLEND 800 — alarming, and entirely an artefact of writing test terrain at x = 34,000, outside `Terrain.MaxExtents`. Re-run inside the limit, both pads were exactly flat. **Check the harness before believing the result.**

### Still to come in Phase 3
1. **Ridge Strip's runway geometry** — needs a heading in the builder and `getRunway()` scoped per airport.
2. **`AircraftService` asking which airport** — the pilot's decision is *nearest to the player*, recorded in §0.
3. **Navigation between airports** — distance and bearing.
4. Streaming: deferred, recorded above.

### How to test it
```lua
require(game.ServerScriptService.FlightSim.Services.TerrainService).runTests()  -- Server
```
Verified live: both pads flat to 0.0000 m at their own elevations, and standing on the Ridge pad shows level green ground with no geometry on it yet.

---

## 23. Ridge Strip — the second aerodrome (2026-08-05)

**628/628 across 17 suites**; `AirportService` 48 → 68. Two airports now exist in the world: **Meadow Field** (paved, 250 m, 18/36) and **Ridge Strip** (grass, 400 m, 09/27, 550 × 18 m). **Meadow's geometry is untouched**, and a test asserts it.

### The registry is scoped by airport, because two fields collide on a designator

`RUNWAYS` was one flat table keyed by designator, which worked exactly as long as there was one aerodrome. Meadow and Ridge could each own a "09", and a flat table silently returns whichever was written last — no error, just the wrong runway.

Every entry now carries the airport it belongs to, and the lookups take both:

```lua
AirportService.getRunway(airportId, runwayId)   -- airport first: "Ridge's zero-niner"
AirportService.navPoints(airportId, runwayId)
AirportService.runwayIds(airportId)
AirportService.allRunways()                     -- every runway everywhere
```

Only **one** call site outside this module needed changing, which is why the refactor was cheap: `AircraftService` asked for `getRunway("36")`.

**The entries are GENERATED from specs**, not written out. A runway's threshold, departure end and direction all follow from its airport's origin, elevation and heading, so writing them by hand means maintaining the same fact in four places — and Ridge's east-west pair would have been four more chances to get a sign wrong. Meadow's generated values reproduce the old hand-written ones exactly.

⚠️ **`math.sin(math.rad(360))` is about −2.4e-16, not 0.** Generating Meadow's direction naively put its threshold 1.2e-13 off the centreline, which breaks assertions that have always compared against exactly zero. `directionFor()` snaps near-zero components, so the cardinal headings stay exact.

### The builder no longer assumes one orientation

Meadow's builder writes world coordinates and works because its runway happens to run along Z. Rather than rewrite geometry that is signed off, Ridge is built from **vectors**: `along` runs from the centre toward the departure end, `across` is the pilot's right, `up` is height. **No world axis appears in it at all**, so the same code lays out a strip at any heading — 09, 27, 18 or 143.

Part orientation comes from `CFrame.lookAt(position, position + direction)`. `LookVector` is the part's −Z and `Size.Z` is its Z, so a size of `(width, thickness, length)` lands length-along-runway at any heading. A test asserts the strip actually **lies along** its runway rather than across it — a builder that assumed one orientation would put a 550 m strip across the field, and a size check alone would still pass.

### What Ridge Strip is

A mown surface, threshold bars at both ends, edge markers every 60 m, and a windsock. Sparser than Meadow, as a grass strip should be — but **it keeps the edge markers**, because §11 is explicit that vertical objects of known size at known spacing are the depth cue, and a strip has no painted centreline to judge against instead.

**The strip's colour was wrong on first look.** At (104, 138, 72) against terrain at (86, 122, 62) it was very nearly invisible from the ground — the §11 failure again, a surface you cannot see being one you cannot land on. It is now (132, 156, 92): a mown strip really is paler than rough grass, so this is both more legible and more honest.

### One wrong assertion, and it is the float32 trap again
`|d45.Magnitude − 1| < 1e-9` failed on a correct unit vector. **Vector3 components are float32**, so a unit vector's magnitude is only good to about 1e-7. The *cardinal* checks can still use exact equality — the snap makes those components literally 0 and 1 — but 045 has no exact float32 representation and never will. Same lesson as the y = 250 tolerances already in §7.

### How to test it
```lua
require(game.ServerScriptService.FlightSim.Services.AirportService).runTests()  -- Server
```
Verified live: strip 18 × 550 m with its top face at exactly y = 400, `LookVector` (1, 0, 0) = east, threshold bars 5.4 m either side of **both** thresholds, 18 edge markers, and 09's departure end exactly 27's threshold.

### Still to come in Phase 3
1. **`AircraftService` asking which airport** — nearest to the player, already decided (§0).
2. **Navigation between airports** — distance and bearing.
3. Streaming: deferred, recorded in §22.

---

## 24. Spawning at the nearest aerodrome (2026-08-05)

**640/640 across 17 suites**; `AirportService` 68 → 80. `AircraftService` no longer assumes there is one airport.

### The rule, and the one it replaced

A player spawns at the field **nearest them**, horizontally. That is the pilot's decision and **there is deliberately no chooser** — the destination picker is the Phase 4b tablet's job, and building one now would be building ahead.

The useful property is what happens after a trip: fly to Ridge, land, press Backspace, and you get an aeroplane **at Ridge**, not teleported home.

`AirportService.nearestAirport(position)` is pure, like everything else that answers a question here, so `AircraftService` can ask before any geometry exists.

⚠️ **The comparison is HORIZONTAL, and that is not a detail.** Ridge is 150 m higher than Meadow, so a 3D distance would have made a high overflight of Ridge resolve to *Meadow* purely because Ridge is further up. An aeroplane 3 km above Ridge is at Ridge. A test pins it.

The field is chosen from the player's **character**, not their aircraft: the aircraft is about to be replaced when this is called, and after a crash there may not be one. With no character at all — a request arriving before the player has spawned — the primary field is the honest default rather than a guess.

### Parking generalised across the runway

`apronSlotCFrame` now takes an airport, and slots spread **across the runway** rather than along the X axis.

That generalisation is the whole of the change. Meadow's runway runs north–south, so its "right" vector *is* +X and the old X-spread was correct by coincidence. Ridge's runs east–west, and spreading along X would have parked its aircraft **nose to tail down the strip**. Slots now spread along `direction × up`, which reproduces Meadow exactly and lays Ridge's out correctly — and parked aircraft face the runway they will depart from, at any heading.

Parking is declared as an offset **along and across** the field's default runway rather than as world coordinates, so it rotates with the aerodrome instead of being re-derived per heading. Meadow's reproduces the old `APRON_CENTRE` exactly; Ridge parks on the grass beside the threshold end, 34 m off the centreline, which is what actually happens at a strip. A test asserts that clearance, because an aircraft spawning on the runway is the first thing a landing pilot would meet.

### Slots are per-airport

`usedSlots` was a flat table, and **slot 0 exists at every field**. Left flat, Meadow's first aircraft would have blocked Ridge's, and an aeroplane would have parked one space further out at a field with nothing on it. It is now nested by airport id, and `Record` carries the airport so despawn frees the right one.

### How to test it
```lua
require(game.ServerScriptService.FlightSim.Services.AirportService).runTests()  -- Server
```
Verified live rather than only in tests — the same player, moved between fields:

| player standing at | aircraft appeared at |
|---|---|
| no character | (−132, 251.3, 300) — Meadow apron |
| Meadow | (−132, 251.3, 300) — Meadow apron |
| Ridge | **(1390, 401.3, 166)** — Ridge parking, at Ridge's own elevation |

### Still to come in Phase 3
1. **Navigation between airports** — distance and bearing.
2. Streaming: deferred, recorded in §22.

Then the altitude-hold oscillation, which is now in scope.

---

## 25. Navigation between airports (2026-08-05, Phase 3 build complete)

**658/658 across 17 suites**; `AirportService` 80 → 98. **This is the last item in §14's Phase 3 list.** Terrain ✅, more than one airport ✅, navigation between them ✅, streaming explicitly deferred ✅.

### A flight plan, not two numbers

`AirportService.flightPlan(fromId, toId)` is shaped **like `navPoints`** on purpose — named keys, world `Vector3`s for the geographic points, `nil` for a route that does not exist — so the two read as one navigation system rather than two.

```
Meadow Field -> Ridge Strip: 1,612 m on 097, back 277
climb +150 m, cruise 705 m, depart runway 18, arrive runway 09
Departure (0, 250, 500) -> TopOfClimb (400, 705, 50)
  -> CircuitEntry (1600, 705, -700) -> Destination (1325, 400, 200)
```

**Everything is derived, nothing is chosen to look plausible.** The cruise is circuit height above the *higher* of the two fields (arriving below the destination would be the alternative). The arrival runway is whichever best matches the inbound course — `bestRunwayFor` maximises the dot product, so it stays right if a runway is added or a field moves. The climb is simply the difference in elevation.

**It hands off to `navPoints` rather than duplicating the circuit.** `CircuitEntry` *is* the arrival runway's own `Downwind` — a test asserts they are the same point, because two copies of a circuit will drift.

Also added: `headingOf(direction)` (the exact inverse of `directionFor`), `bearingBetween`, and `bestRunwayFor`.

⚠️ **A published bearing is a number the pilot flies by reading the DI**, so the conventions must agree or the plan is wrong in a way that only shows up in the air. `headingOf` round-trips through `directionFor` at every cardinal, and is checked against **FlightModel's own** `atan2(look.X, -look.Z)` — verified live at 97.125 from both, dot product 1.000000000. North reads **360**, not 0, matching how runways are designated.

### The bug this exposed: a circuit leg that was not at its own airport

Building the plan surfaced a real pre-existing fault. **`Downwind` was the only circuit point with no airport anchor** — computed as `lateral * DOWNWIND_OFFSET + up * PATTERN_ALTITUDE`, an offset from *nothing*:

| | was | should be |
|---|---|---|
| Meadow Downwind | (−900, **305**, 0) | (−900, **555**, 0) |
| Ridge Downwind | (**0**, **305**, **−900**) | (**1600**, **705**, **−700**) |

It was **correct by coincidence** while Meadow was the only field, sitting on the world origin, at y = 0. Both assumptions died: §20 lifted the airport to 250 m, and §23 put a second field 1.6 km east. The result was a downwind leg 250 m too low at Meadow, and at Ridge one that was *over Meadow entirely*.

Every other point in that table was already built from `threshold` or `departureEnd` and was correct throughout.

**Nothing reported it** because the existing checks only asked whether airborne points were above ground points and whether they fitted inside the world — both of which a badly wrong point passes comfortably. Two new checks ask the questions that matter, for **every runway at every field**: is each circuit point *near its own aerodrome*, and is it at circuit height *above that field*.

### And one more wrong assertion
`"Pattern altitude is a standard 1000 ft"` read `nav.Downwind.Y` directly and expected ~305 m. It passed only because Downwind's Y was the pattern altitude **by accident rather than being an altitude at all**. It now measures height above the field: Meadow's downwind is 555 m, being 250 m of field plus 305 m of circuit, which is what a 1,000 ft pattern means.

### How to test it
```lua
require(game.ServerScriptService.FlightSim.Services.AirportService).runTests()  -- Server
```

### Phase 3 is built
Nothing in §14's Phase 3 list is outstanding. **Phase 3 has no gate** in §14 — unlike Phases 2, 5 and 6 — so there is nothing specified for the pilot to fly and sign off. If one is wanted, the obvious shape is *fly Meadow → Ridge on this plan, land on the strip, press reset and confirm you are still at Ridge*, which exercises §23, §24 and §25 at once. Not invented here, because it was not asked for.

---

## 26. Altitude hold: the capture fix (2026-08-05)

**665/665 across 17 suites**; `InputController` 81 → 88. Engaging R in a climb no longer slams the nose down.

### Measured first, and the mechanism is arithmetic

Engaging sets the target to the **current** altitude, so the outer loop's error is zero and it demands **zero climb — instantly**, however fast the aeroplane is going up. The inner loop then sees the whole climb as error:

| vs at engagement | demanded climb | climb error | commanded pitch |
|---|---|---|---|
| +1.0 m/s | 0 | −1.0 | −0.180 |
| +2.5 m/s | 0 | −2.5 | **−0.450 saturated** |
| +3.98 m/s (Vy) | 0 | −3.98 | **−0.450 saturated** |

**Saturation begins at 2.50 m/s (492 ft/min)** — that is `pitchLimit / verticalSpeedGain` exactly — and the 172's own Vy rate of climb is **783 ft/min**. So engaging during a normal climb *always* commanded full nose-down.

### The fix

The demanded climb now **starts at whatever the aeroplane is already doing** and is walked toward what the outer loop wants, so the inner loop never sees a step. Engagement is a no-op on the first frame by construction.

Closed-loop, real aerodynamics, engaging at a Vy climb:

| | as shipped | with capture |
|---|---|---|
| first-frame command | **−0.450** (limit) | **−0.003** |
| frames saturated | 22 / 901 | **0 / 901** |
| peak vertical jolt | **0.69 g** | **0.49 g** |
| max altitude error | 2.9 m | 5.5 m |
| error after 10 s | 2.8 m | **1.4 m** |

It eases off instead of banging: the excursion is slightly larger because it no longer slams, and it settles **twice as tight**. Engaging in a 4 m/s descent behaves the same way — first frame +0.003.

**No tuned gain was touched.** The one new number, `captureAccel = 1.0 m/s²`, is derived rather than felt: almost exactly 0.1 g, the vertical acceleration a passenger would call a gentle level-off, rolling a full-rate climb off to level in about four seconds.

### A wrong hypothesis, killed by fixing the harness

Mid-way the traces showed the aircraft sinking away with the elevator hard against its limit, and a trim sweep said level flight needed **+0.480 at 70 kt and +0.670 at 65 kt** against a ±0.45 limit. That looked like a second, deeper bug — the autopilot discards the pilot's trim, so it must supply the whole deflection from a budget too small for it — and the obvious fix was to add trim as a baseline.

**The engine was never started.** Thrust was 0.0 N in every one of those runs: the harness was flying a glider, and both the sink and the trim table were artefacts. With power the aeroplane accelerates once levelled, so:

| | max error | after 10 s |
|---|---|---|
| capture only | 5.5 m | **1.4 m** |
| capture **+ trim baseline** | 17.8 m | **17.8 m and rising** |

The trim baseline measured clearly **worse** — the autopilot ends up driving to −0.33 to fight a trim it no longer needs. It was reverted, and the code now carries a note saying why, so nobody re-derives it.

That is the second time this session a result was an artefact of the harness rather than the code. **Check the harness before believing the result** — §7.

### And a bug in the fix, caught by its own test
The first version clamped the capture to `maxClimbRate`, which put back the exact step capture exists to remove, precisely when it was largest: entering at 12 m/s captured at 5, leaving 7 m/s of error on frame one and commanding the full limit again. `maxClimbRate` bounds what **altitude error** may ask for; it says nothing about what the aeroplane is currently doing. The capture is now unclamped and the walk brings it inside the limit anyway.

### How to test it
```lua
require(game.Players.LocalPlayer.PlayerScripts.FlightSim.Controls.InputController).runTests()  -- Client
```
Seven new checks: the uncaptured cascade saturates at Vy and above 2.5 m/s (the bug, pinned), capture commands nothing on the first frame for entries from −5 to +12 m/s, a fast entry is captured at its true rate, the demand walks at `captureAccel` and converges, and a settled capture still commands full authority when far off.

**Not yet flown.** The measurements are closed-loop against the real aerodynamics, but a pilot has not pressed R in the air since the change.

---

## 27. R is a stability augmentation mode (2026-08-05)

**679/679 across 17 suites**; `InputController` 88 → 102. Rescoped by the pilot: R is no longer "hold this altitude", it is **help me hold the aeroplane**.

### The prime suspect was innocent

The reported symptom was pitch hunting, and the named suspect was the cascade saturating at ±0.45. **Measured, in level flight the pitch channel was already fine** — 2.2 m of error over 15 s, zero saturation, zero reversals.

The real fault was in an axis nothing was controlling. Engaging mid-climb:

| | bank | heading | vs | pitch |
|---|---|---|---|---|
| 0 s | −29.9° | 315.7 | +2.52 | +0.242 |
| 15 s | **−61.3°** | **106.4** — 209° of turn | −7.74 | **+0.450 saturated** |

A **spiral**. Nothing held the wings, so the aeroplane rolled off; the bank stole vertical lift; the altitude channel pulled harder — and **in a bank, pulling tightens the turn instead of climbing**. Pitch saturated for 723 of 901 frames fighting a problem that lives in roll. That is the hunting: the pitch axis chasing a lateral divergence it cannot fix.

### What the mode does now

`InputController.stabilityRoll` — pure, and three terms in order of authority:

1. **Rate damping** opposes whatever roll rate exists. A spiral is a rate before it is an angle, so this is what actually stops one.
2. **Wings level** rolls out bank the pilot did not ask for.
3. **Heading hold** banks — gently, never past `maxBank` = 20° — to steer back to the heading captured at engagement.

**And it gets out of the way.** Since §28 the cursor cannot reach the law while engaged, so this hand-off is only ever triggered by the rudder now: any rudder at all returns the pilot's roll command untouched and the heading reference **follows the aeroplane**. So a bootful of rudder yaws the aircraft, the mode accepts the new heading, and letting go does not snap back to where R was pressed.

**`controls.yaw` is never written anywhere in this mode.** The rudder is the pilot's alone; the augmentation only reads it to know when to stand down.

### Before and after

| | level: max err | level: heading drift | climb: max err | climb: bank | climb: saturated |
|---|---|---|---|---|---|
| before | 2.2 m | **56°** | **69.6 m** | **−61.3°** | **723 / 901** |
| after | **0.2 m** | **1°** | **2.9 m** | rolls out to +1.6° | **0 / 901** |

Rudder while engaged: roll command goes to exactly **+0.000**, heading moves 344.5 → 355 under rudder, and on release settles near **351** — followed, not snapped back. Altitude error stayed ≤ 0.3 m throughout.

**No tuned pitch gain was touched.** `altitudeGain`, `verticalSpeedGain`, `maxClimbRate` and `pitchLimit` are all unchanged — the measurement showed they were never the problem. The new gains live in a separate `stability` block. (`disconnectThreshold` was later **removed** with §28 — its whole job was to read the cursor, and the cursor no longer reaches the law while engaged.)

`FlightState` gained `bankAngle`, `rollRate` and `heading`, all optional: without them only the pitch channel augments, which is the previous behaviour and a sane degraded state. `FlightController` fills them from the **same single reading** of the assembly, using the constructions `FlightModel` already publishes — the DI a pilot reads and the heading this mode steers by must not be two different numbers. Roll rate is projected onto the nose vector, because the world X component reads a *pitching* aeroplane as rolling once it turns east–west.

### How to test it
```lua
require(game.Players.LocalPlayer.PlayerScripts.FlightSim.Controls.InputController).runTests()  -- Client
```
In the air: **engage level** (wings should settle and stay), **engage mid-climb** (should roll level and level off without hunting), and **kick the rudder while engaged** — the aeroplane must yaw, and when you release it should hold the *new* heading rather than turning back.

### Three harness bugs in two sessions
The first measurement of this bug was taken with **throttle at 0.000** — `IC.update()` derives throttle from held keys and nothing was held, so the aeroplane was gliding at idle and every trace showed a sink that was pure artefact. That is the **third** harness fault in two sessions, after the terrain written outside `MaxExtents` and the engine never started. **Check the harness before believing the result** is now earning its place in §7 repeatedly: measure the entry condition and print it, rather than assuming the setup did what it was told.

### And one more wrong assertion
A heading-hold check used an error of **exactly 180°**, where the shortest way round is genuinely ambiguous and `angleDelta` returns −π as legitimately as +π. It asserted a turn direction that has no correct answer, and failed on correct code.

⚠️ **Not yet flown.** Every number here is closed-loop against the real aerodynamics with the engine running and the throttle commanded, but a pilot has not pressed R in the air since the change.

## 28. The cursor is ignored while altitude hold is engaged (2026-08-05)

The pilot's report: altitude hold still hunts, and the suspicion is the mouse — the cursor is the yoke, and its input keeps fighting the autopilot while the mode is active. Implemented exactly as requested: **while engaged, the mode overrides the mouse entirely.** The cursor is not read as the yoke at all, the autopilot has unopposed authority, and only R disengages it.

Why this is more than an authority question — the cursor had **two** live paths into the engaged mode:

1. **The roll hand-off.** `stabilityRoll` hands the roll axis back to any command past `pilotRollThreshold` (0.06). The cursor does not need to move far for that — it only had to sit slightly off centre while R was pressed, and the autopilot then fought a deflected aileron instead of flying. That is the hunting as it presents in the cockpit.
2. **The disconnect.** Pitch movement past `disconnectThreshold` (0.15) dropped the mode out entirely. A cursor nudge could silently turn the autopilot off — which presents as the aeroplane "hunting" when it is actually the law being disengaged and re-engaged.

Both are gone: `rawPitch` and `rawRoll` are forced to 0 while `systems.altitudeHold` is true, the stick-reference capture and the disconnect block are deleted, and `disconnectThreshold` is removed from config.

**What is deliberately still live:**
- The **rudder**. `controls.yaw` is not the mouse, is never zeroed, still reaches the aeroplane, and still releases the heading reference — the pilot's requirement that the mode never fight the rudder is untouched.
- The **altitude capture** and the **heading capture** at engagement.
- **Pitch/roll smoothing**, so the handover to the autopilot is eased rather than stepped.

**No tuning was touched.** `altitudeGain`, `verticalSpeedGain`, `maxClimbRate`, `pitchLimit`, the whole `stability` block and the smoothing constants are unchanged. The one deleted number is `disconnectThreshold`, because its entire job was to read the cursor and the cursor no longer reaches the law.

**Tests**: the five disconnect/reference tests are replaced by four that assert the opposite behaviour end to end — a cursor slammed into the corner while engaged changes pitch and roll by nothing and the mode stays engaged; R disengages; and after disengagement the same cursor commands the aircraft again. InputController 102 → 101 checks.

⚠️ **Not yet flown, and not yet re-run in Studio.** These are unit-level assertions; run `InputController.runTests()` and fly it — engage level (should hold without hunting), engage mid-climb (should level off without banging), and jam the cursor around while engaged (must do nothing).

---

## 29. The porpoise was a gain-schedule bug (2026-08-05)

**690/690 across 17 suites**; `InputController` → 110, `FlightController` → 38.

The reported symptom, across several sessions: altitude hold **porpoises** — pure pitch, load factor swinging roughly 0 to 2.5 g, no roll or yaw, and (as it seemed) only over open water.

### The cause: loop gain rises with the SQUARE of airspeed

`verticalSpeedGain` converts a vertical-speed error into an **elevator deflection**. But a deflection is not a pitching moment — the moment it makes is proportional to **dynamic pressure**. So the loop gain climbs with V², and somewhere above about 110 kt it crosses the stability boundary and settles into a limit cycle instead of damping out.

**The pilot's own flight recording proved it.** Two dumps, one session, same code, same aeroplane:

| recording | IAS | pitch command | behaviour |
|---|---|---|---|
| first | 83–104 kt | max \|0.127\| | calm |
| second | **112–118 kt** | **\|0.450\| — SATURATING** | 1.2 s limit cycle, ±5° attitude |

Bank held +0.40° and heading 344.9° in both — **pure pitch**, exactly as reported. Reproduced in the harness by engaging with a target below and letting the aeroplane accelerate into the descent: calm at 94–111 kt with the elevator inside 0.16, then at 115–116 kt the command swung −0.359 → +0.083, reached the stop, and the load factor ranged **−0.16 to 2.28 g**.

**The "only over water" correlation was incidental.** Ground effect is inert above ~11 m and the porpoise happens at altitude. What actually correlated was **speed** — the open-water legs were the fast ones.

### The fix: schedule the gain on dynamic pressure

`altitudeHoldPitchCaptured` now takes an optional `airspeedMs` and divides the gain by q, normalised to `refAirspeed`. **Indicated** airspeed is exactly the right variable: it already carries air density, so the schedule is altitude-correct for free.

```lua
refAirspeed  = 48.0,  -- m/s, about 93 kt: the middle of the measured calm band
minGainScale = 0.35,  -- reached near 158 kt, just under Vne; stops it going deaf in a dive
maxGainScale = 1.0,   -- ATTENUATE ONLY
```

⚠️ **`maxGainScale` is 1.0 on purpose — the schedule must never amplify.** The first version allowed 2.0, which raised the gain 1.6× in a 74 kt Vy climb and started a **second** oscillation: 20 vertical-speed crossings in a minute, elevator at 0.448, load factor 0.55–1.44 g. The unscheduled gain was already steady everywhere from 69 to 111 kt; amplifying where nothing was wrong only created a new porpoise. Below `refAirspeed` the law is now *exactly* the unscheduled one.

| case (60 s each) | G swing before | after | crossings | max pitch |
|---|---|---|---|---|
| capture 40 m down | **−0.18 … +2.33** | **+0.81 … +1.08** | 60 → 2 | 0.450 → 0.184 |
| capture 40 m up | −0.10 … +2.23 | +0.81 … +1.10 | 18 → **0** | 0.450 → 0.157 |
| Vy climb | 0.60 … 1.10 | 0.60 … 1.10 | 2 → 2 | 0.254 → 0.254 |
| 100 kt level | 1.00 … 1.01 | 1.00 … 1.01 | 1 → 1 | 0.009 → 0.009 |

The Vy and level rows are **identical** before and after — that is the attenuate-only rule working.

`FlightState` gained `airspeed`; `FlightController` fills it from `telemetry.airspeedIndicated`, deliberately one frame old (telemetry is written by `computeForces`, which has not run yet). That is the right trade: it is the same number the ASI shows, and a schedule reading IAS 16 ms late cannot matter when the speed takes tens of seconds to move.

### ⚠️ OUTSTANDING: it holds level, but ~29 m LOW

Measured over 180 s: vertical speed 0.003 m/s, load factor 1.00, dead level — and **29 m below target, not closing**.

That is **proportional droop**. With no integrator, the loop needs a standing vertical-speed error to hold the elevator where level flight requires it, and the altitude error is what produces it. It existed before (~18 m); attenuating the gain widens it to ~29 m at 120 kt.

Removing it needs an **integrator on altitude error**, deliberately NOT added here — an integrator is the same class of term that caused the regression below, and it must be measured against the full speed sweep before it ships.

### The damping term from `40c197c` was reverted — it caused a porpoise of its own

`40c197c` added a low-pass-filtered derivative on the vertical-speed error (`verticalDamping` 0.1, `vsFilterTau` 0.15, `dampingLimit` 0.2). Measured against the real aerodynamics with the model's **own** pitch inertia, it turned a dead-steady autopilot into a violent limit cycle:

| | G swing | period | max pitch | error |
|---|---|---|---|---|
| damping OFF | **0.97…1.04** | — | **0.022** | **0.2 m** |
| damping 0.1 (shipped) | **0.10…1.90** | 1.2 s | 0.450 | 1.5 m |
| damping 0.3 | 0.03…1.94 | 1.1 s | 0.450 | 3.4 m |

**That is the third derivative term to fail on this loop** (after raw vertical acceleration, §26 notes). The reason is structural and worth writing down once: *any* derivative here is taken on a signal that already lags the elevator by the time it takes the nose to move and the wing to answer — at this aircraft's pitch inertia, most of a second. A term meant to oppose the motion arrives pointing the same way as it.

**A regression test now pins the loop's SHAPE**, not a number: the command must equal `(demand − VS) × verticalSpeedGain × scale`, and the capture must carry no history. A fourth attempt at a derivative will fail there and send whoever tries it to this section.

### ⚠️ The modelled aircraft has 2.7× the pitch inertia of a real 172

Measured from the built model (exact box tensors plus parallel axis):

| | model | real C172 |
|---|---|---|
| Ixx roll | 2951 | ~1285 |
| **Iyy pitch** | **4922** | **~1825** |
| Izz yaw | 2535 | ~2667 |

This is a genuine fidelity gap from the crude box layout, and it **predisposes any pitch loop to lag-driven oscillation** — it is why derivative terms keep failing here. Fixing it is Phase 4 work (remodelling), not something to patch in the autopilot. **Record it rather than rediscovering it.**

### The flight recorder (kept from `40c197c`)

`FlightController.recordFlightStep` records while altitude hold is engaged, gated on `Constants.DEBUG.ENABLED`.

- Press **R** → `[FlightRec] recording altitude hold...` prints immediately. **If that line does not appear, the recorder is not live** — check you are seated (the loop only runs in the aircraft) and that the Output window's filter is not hiding Print/Client messages.
- Live summaries every 5 s; press **R** again to dump the full CSV: `t,pitch,att_deg,bank_deg,hdg_deg,alt_m,vs_mps,ias_kt`.
- The `PITCH` summary line flags `SATURATING` at ≥ 0.44.

Its period estimator was wrong and is fixed: dividing the whole window by the crossing count mixed a clean integer (half-cycles) with a ragged one (a window starting and ending mid-cycle), and reported **2.66 s for a known 2.0 s sine**. It now measures between the first and last crossing, where the half-cycle count is exact.

### ❌ MYTH, CORRECTED: a Play restart DOES load new code

Earlier notes claimed only a full Studio-application restart picks up edited modules. **That is wrong and cost real time.** Verified directly: entering Play creates a fresh DataModel with a clean module cache, and `require` returns the new source. Stop and start Play — that is enough.

What *is* true (§7): **the Command Bar has its own cache**. `require(FlightController)` there returns a **second copy** with `rig = nil`, so `getSystems()` and `isFlying()` report nothing about the running aircraft. Observe the real controller through side effects instead — the HUD's `Enabled` state, or its console output.

### Three more harness faults — that is five in three sessions

1. **Throttle at 0.000.** `IC.update()` derives throttle from held keys and none were held, so the aeroplane glided at idle and every trace showed a sink that was pure artefact.
2. **Guessed pitch inertia.** The harness assumed 1825 kg·m² from published C172 data when the model actually has 4922 — so it flew an aeroplane 2.7× crisper than the real one and **could not reproduce the bug at all**.
3. **Forcing airspeed.** A hack that re-injected horizontal velocity each frame to hold a test speed broke the energy balance and produced a vertical speed of +50 m/s.

**Check the harness before believing the result** (§7). The standing fix: **print the entry condition** — speed, vertical speed, throttle, thrust, attitude — and read it, rather than assuming the setup did what it was told.

### And three more wrong assertions

All three failed on *correct* code because the test input was outside the range being asserted:
- a heading error of **exactly 180°**, where the shortest way round is genuinely ambiguous and `angleDelta` returns −π as legitimately as +π;
- the square law checked at **2× the reference speed** — 187 kt, past Vne, where `minGainScale` correctly takes over;
- the low-speed cap checked with a **5 m/s** error, whose command (0.9) `pitchLimit` had already clamped before the schedule could show.

**Assert inside the range the law is defined for**, and say in the test why that range was chosen.

### How to test it

```lua
require(game.Players.LocalPlayer.PlayerScripts.FlightSim.Controls.InputController).runTests()  -- Client
```

In the air, and **fast** — this bug only shows above ~110 kt: get to 115–120 kt, press **R**, and it must hold steady instead of hunting. Then engage level, engage mid-climb, and kick the rudder while engaged (it must yaw, and hold the new heading on release). Expect it to settle **low** — see the droop above.

### ✅ FLOWN AND CONFIRMED — the porpoise is gone (2026-08-05)

The pilot flew it and recorded 900 frames over 15 s. **At IAS 125.1 kt**, which is *above* the 112–118 kt band where the old code limit-cycled:

| | before (§29 recording) | flown, after |
|---|---|---|
| VS zero crossings | 60 in 60 s | **0** |
| peak pitch command | **0.450 — SATURATING** | **0.219** |
| behaviour | 1.2 s limit cycle, ±5° | no oscillation |

Engage state: ALT 325.5 m, VS +0.23 m/s, attitude −0.95°. **The gain schedule works in the air.** Peak command is half the 0.45 stop, so there is real margin left rather than a fix that only just holds.

### ⚠️ What that recording does NOT establish

**It had not settled.** Vertical speed peaked at +2.68 m/s and was still decaying (~+1.0 m/s) when the recording ended, averaging ~1.6 m/s of climb over the window. **15 s is the capture transient**; §29's ~29 m droop was measured over **180 s**. Where this one ends up — levelling off high, or climbing on — is not answered by this data.

Worth noting for whoever reads the next trace: the autopilot held **~−0.19 of command steadily while the aeroplane climbed**. That is ~42% of the available authority pointed the other way, so the loop was demanding a descent and losing. That is the proportional-droop mechanism of §29 showing up as a **climb** rather than as the documented level-but-low case — the sign depends on the energy state at engagement, and only the low case had been recorded before.

⚠️ **`pitch` in the CSV is a normalised elevator command, not an angle.** It runs to `pitchLimit` = 0.45, which is what the 0.44 SATURATING flag is against. Attitude is the separate `att_deg` column. This was misread once already as "−0.19 rad ≈ −11°", which makes a climbing aeroplane look gently nose-down instead of fighting the autopilot.

**Still unflown from the test list above**: engage while level, engage mid-climb, and kicking the rudder while engaged (it must yaw and hold the new heading on release).

### ✅ SIGNED OFF BY THE PILOT — the drift is WANTED, do not "fix" it

> *"Altitude hold works perfectly, even though there is a climb, there should be some variability when holding to keep it realistic."*

**The slow climb or descent is the intended behaviour, not a defect.** Altitude hold does not hold a true altitude and is not meant to: while engaged there is always a slight steady increase or decrease, and the sign depends on the energy state at engagement. **Do not add an integrator to flatten it**, and do not treat a drifting hold as a bug report — a dead-flat hold is what would be unrealistic.

**Revisit it with the weather system (Phase 5), not before.** The pilot's reasoning: air density, thermals and hot pockets are what a real autopilot is fighting, so the drift only becomes meaningful to tune once there is something real for it to fight. The ~29 m droop of §29 and the unsettled window above are both parked under that heading.

---

## 30. The pilot is 1.75 m — and the previous attempt did nothing at all (2026-08-05; the height is now 1.55 m, see §36)

**698/698 across 17 suites**; `FlightController` 38 → 46.

The pilot was **1.75 m** standing beside the real-scale Cessna, measured live: `[Avatar] pilot is 1.75 m (model scale 0.339x)`. §36 lowers the target to **1.55 m** at the pilot's request; every mechanism in this section is unchanged.

### The previous commit `d19d805` was completely inert, and its marker hid that

It set the R15 scale `NumberValue`s (`BodyHeightScale` and friends) to 0.4 with `AutomaticScalingEnabled = true`, printed a success line, and **changed nothing whatsoever**. Measured on the live rig, all four of these:

| attempt | result |
|---|---|
| `Humanoid:ScaleTo()` / `Humanoid:SetScale()` | do not exist — *"ScaleTo is not a valid member of Humanoid"* |
| set the four scale `NumberValue`s to 0.4 | **rig moved 0.00 studs.** Values read back 0.4 while `GetAppliedDescription()` still reported `HeightScale 0.96` and the rig still measured its full 5.16 studs |
| set `BodyHeightScale` to 1.0, then back to 0.4 | **0.00 studs in both directions** — the mechanism is simply inert here |
| `Humanoid:ApplyDescription()` | **server-only** — *"can only be called by the backend server"* |

⚠️ **The marker could not tell success from doing nothing, which is why this survived a whole session.** It printed the scale it *asked for* next to `HumanoidRootPart.Size.Y`, and the "root part 1.92 studs" it reported was just this player's own untouched avatar — the HRP is an invisible collision box that does not track the visible rig. **The marker now prints the height measured AFTER the fact**, so it cannot lie the same way. This is the same class of mistake as §6g's inset "verification": it checked that the arithmetic was self-consistent, not that the thing had moved.

### The answer was `Model:ScaleTo()` — no rig surgery, no floor

`Humanoid` has no `ScaleTo`; **`Model` does**, and a character is a Model. `character:ScaleTo(0.339)` took the rig from 5.156 studs to 1.752 in one call, scaled `HipHeight` with it (2.147 → 0.729), and left the Humanoid alive and Running.

**The "0.4 engine floor" does not exist** — it was inferred from a mechanism that was not working at all. There is no clamp to work around, so **the planned manual part-rescaling was never needed** and was not done.

⚠️ **There are also no `Motor6D` joints on this rig to rewrite.** It is a constraint rig — `AnimationConstraint`, `BallSocketConstraint`, 55 `Attachment`s and 15 `WrapTarget`s of layered clothing, and **zero Motor6D**. Any plan that starts "rewrite the Motor6D C0/C1 offsets" is written against a rig this game does not have. `ScaleTo` handles all of it.

### ⚠️ `AutomaticScalingEnabled = false` breaks the camera — leave it TRUE

Setting it false was a precaution against the engine re-applying the description over the top. **The engine does not do that** (`ScaleTo` survives either way, measured), and turning it off moves the camera's focus onto a fixed 2-stud constant instead of one that scales with the root part:

| `AutomaticScalingEnabled` | camera focus above the head |
|---|---|
| `false` | **+1.296 studs** — most of a body length of empty air |
| `true` | **+0.116 studs** — normal framing |

Reported by the pilot as *"the center is a few studs above our head, it drills in that we have been scaled down"*. It was self-inflicted, and the fix was to delete the line.

### The height must be measured with the rig STANDING STILL

`rigHeightStuds()` reads the *posed* rig, so it is the standing height only once the character has stopped moving. **Waiting on the physics is not enough and was tried first**: a character spawning on the pad is already `Running` with no vertical velocity within a frame, while the `Animate` script is still easing the limbs into the idle pose for about a second afterwards.

| measured | scaled the pilot to |
|---|---|
| 4.22 studs (mid-pose) | 1.41 m |
| 5.06 studs (mid-pose) | 1.69 m |
| **5.156 studs (settled)** | **1.75 m** ✅ |

So the wait is on **the measurement settling**, not on any state flag: two consecutive readings agreeing within 0.005 studs mean the limbs have stopped. At rest the reading repeats to four decimal places, and the settled value is repeatable across sessions (5.155 / 5.156 / 5.158), which is what makes it safe to key on.

`pilotScaleFor()` is **idempotent by construction** — `ScaleTo` takes an absolute scale, not a multiplier, so the current scale is folded back in and re-applying to a correct rig is a no-op. That is what lets the applier converge in a loop instead of having to measure perfectly first time, and a test pins it.

**The height is measured, not hard-coded**, so it lands on PILOT_HEIGHT_M (1.55 m after §36) for any player's avatar rather than only for a default one. Accessories and the `HumanoidRootPart` are excluded — hair is not height, and the HRP is the box that produced the misleading 1.92.

### Nothing physical changed
- **Boarding still moves the aircraft 0.000 m** — re-measured after the change (§6e).
- The scale holds through the `Sit` weld and back out; the pilot walks normally with no vertical drift.
- `WalkSpeed` is untouched — it is the project's own metre-scale 2.4 m/s from `Constants.CHARACTER`, and a PILOT_HEIGHT_M human should walk at that speed whatever the rig measures.
- The cockpit eye is anchored to the `PilotSeat`, not the head, so the view does not move.

### The spawn pad is hidden, and **sunk flush** rather than just made invisible
It sat *on* the apron with its top face a metre proud — the same 1 m ledge that obstructed the runway before it was moved here (§20). Hiding a ledge without lowering it only makes it an **invisible** ledge to trip over on the walk to the aeroplane. Its top face is now level with the apron at y = 250.00 and it is indistinguishable from the pavement.

**The `Decal` needs its own pass** — it is a child of the part, not a property, so `Transparency` on the part alone leaves the spawn logo lying on the tarmac. Same trap as the invisible pilot in §6e.

Done at run time in `AirportService`, beside the code that already moves the pad to the airport elevation, because editing `default.project.json` costs a Rojo restart *and* a plugin reconnect (§3) and nothing here needs the Edit view to change.

---

## 31. Phase 4 — the Cessna looks like a Cessna (2026-08-05)

**719/719 across 18 suites**; new `SurfaceAnimation` at 21, `FlightController` 46, `AircraftBuilder` 20, `CameraController` 24.

Scope items **1 (exterior)** and **2 (control surfaces move)** are done. Items 3 (instrument realism), 4 (cockpit interior) and 5 (3D controls) are **not started**.

### The seam that makes this safe: `parts` is physics, `decorations` is appearance

The definition already had the split. `AircraftBuilder` forces `Massless` on every decoration and `measure()` skips massless parts, so **a skin cannot move the mass budget, the centre of mass, the static margin or the inertia tensor** — it is not a promise, it is a property of the build.

So the structural boxes are **unchanged and now invisible** (`hideStructuralParts`), and 78 parts of modelled 172S are drawn over them. `Cessna172.runTests()` is **29/29 unchanged** and `AircraftBuilder` still measures **1,111 kg** with the CoM where it predicts — which is the proof, not the intention.

⚠️ **Do not "tidy" a structural box to match the skin. The skin exists to match the box.**

**Rotation is rejected on structural parts, by the validator.** Roblox reports inertia in world axes, so tipping a mass-bearing box silently rewrites the inertia tensor while every mass number in the file still reads correct. Cosmetic parts carry no mass and cannot.

**Geometry is code, not a mesh** — same reasoning as the airport (§11): a mesh is an opaque binary Rojo cannot diff and cannot be adjusted without leaving the repository. The fuselage is a `loft()` over twelve stations, which is what tapers a 1.16 m cabin down to a 0.34 m tailpost with no hand-placed wedges.

### 🐛 A duplicate part name silently detached the tailplane

The skin named a part `Stabilizer`. So does the structure. `build()` keys one table by name to weld from, so **the decoration replaced the structural part there and the real stabilizer was never welded on** — it stayed in the model, visible, carrying its mass, as a second assembly the aeroplane was not attached to.

| | measured | expected |
|---|---|---|
| mass | **1,091 kg** | 1,111 |
| assemblies | **2** | 1 |
| centre of mass | 82 mm forward of prediction | on it |

**Every number in the definition was still correct. Only the build was wrong, and nothing said so.** `validate()` now refuses to build on a duplicate name across parts *and* decorations.

### 🐛 The ailerons were backwards, and the first test asserted the wrong sign

Positive rotation about X carries a trailing edge **down**. The aileron shipped at the default `sign = +1`, so a right-roll command **dropped** the right aileron — adding lift to the wing that is supposed to be going down. The surfaces visibly contradicted the roll.

The unit test passed, because it asserted `> 0` with the same wrong reasoning. It was caught by driving a **real built model** and measuring the part's `LookVector`, not by reading the code. The test now derives its signs **from the definition** rather than restating them, so the two cannot drift apart again.

### The surfaces are hinged with `Motor6D`, and the rest position is captured once

A `Motor6D` places `Part1` at `Part0.CFrame * C0 * Transform * C1:Inverse()`. `C0` is built with the **hinge point as its origin and no rotation of its own**, so it is expressed in the datum's axes — that is what lets the animation layer say "rotate about X" and mean the aircraft's lateral axis, whatever angle the surface is mounted at. `C1` folds the mounting rotation back out, so at rest the motor reproduces exactly what `createPart` would have given.

Every deflection is applied on top of a **`baseC0` captured once**, so a surface returns exactly to where the builder put it instead of drifting frame by frame.

Verified on a built model: elevator −22° on stick back (trailing edge up), ailerons ∓20° in opposition, rudder trailing edge right on right pedal, flaps 30° down, trim tab opposing the elevator.

**Flap travel is frame-rate independent** and takes ~7.5 s for full deflection, from an exponential approach rather than a per-frame lerp — the naive version makes travel time depend on how busy the renderer is.

⚠️ **Trim is passed to the animator separately and is NOT in the Controls contract.** Widening those six fields to make an animation convenient is exactly what §6c says not to do.

### An assertion was wrong again — the fourth time

`CameraController`'s "only a few parts are hidden" was `#occluders <= 3`, correct when the aeroplane was fifteen boxes. At 78 parts the eye is legitimately inside a structural box **and** the skin panel over it — `Cabin` with `Fuselage05`, `WingCenter` with `WingCentre` — so the honest count doubled with nothing wrong. Measured 6 of 78. It is now a **proportion**, because what it protects is "the view hides what encloses the eye, not the aeroplane", and that is a fraction. The outer-wing check above it is the one that must never go green by accident.

### ⚠️ Two traps this phase re-confirmed

- **The Edit session's `require` cache is real and it lied twice.** A verification run in Edit reported the ailerons still backwards *after* they were fixed, and reported 20 checks when the file had 21. §29's correction stands — **Play** gets a clean cache, Edit does not. The documented workaround (clone the module tree and require the clone) works and was used to render the final views.
- **`screen_capture`'s camera override only applies in Edit.** In Play the game's own camera controller writes `CFrame` at a higher render priority and wins, so a requested viewpoint is silently ignored.

### Still open in Phase 4

1. **Instrument realism (scope item 3)** — ASI position error, magnetic compass with turning lag, altimeter on its baro setting. Display errors in the instrument layer, never in the physics.
2. **Cockpit interior (item 4)** and **3D controls (item 5)** — `SixPack.buildPanel()` already builds into any parent and a test already drives it through a real `SurfaceGui`, so §19's roadmap is waiting rather than blocked.
3. ⚠️ **§29's pitch-inertia gap is NOT fixed and was not touched.** The model has 2.7× a real 172's `Iyy`. §29 calls remodelling the fix, but closing it means moving mass, which Phase 4 declares a **decision point for the pilot, not an assumption** — the skin deliberately changed nothing. Raise it before acting on it.

### The imported mesh drops in on one flag

An exterior mesh is being imported (Sketchfab, KOG_THORNS, CC BY 4.0 — attributed in `CREDITS.md`). The primitive shell above and a mesh are **both exteriors**, and running both would put the aeroplane in two skins.

`Cessna172.model.exteriorFromMesh = true` drops the static shell and keeps everything the mesh cannot do for itself:

| | shell on | shell off |
|---|---|---|
| parts | 78 | **22** |
| hinged surfaces | 9 | **9** |
| animated surfaces bound | 8 | **8** |
| **mass / assemblies** | **1,111 kg / 1** | **1,111 kg / 1** |

**A single imported mesh cannot deflect its own ailerons**, which is exactly why scope item 2 was built mesh-independent — the control surfaces stay ours whatever the exterior is. The mass column is the point: identical either way, because both exteriors are massless decoration over the structural boxes.

The primitive shell stays in the file rather than being deleted. It is what the aeroplane looks like until the mesh arrives, and the fallback if the import is rejected.

---

## 32. The instruments read like instruments, not like the physics (2026-08-05)

**743/743 across 19 suites**; `UIController`'s aggregate 153 → 177.

Phase 4 scope item 3. Every gauge showed the perfect number until now, which is the one thing a real cockpit never does.

⚠️ **THESE ARE DISPLAY ERRORS AND LIVE ONLY IN THE INSTRUMENT LAYER.** Nothing is fed back into the flight model — the aeroplane still flies on true values and only the needles lie. That is what keeps §4's published figures meaningful, and it is the training value of the phase: *a pilot who learns on a perfect altimeter cannot read a real one.*

They are injected in `SixPack.samplers`, which was already the one door every panel value came through.

### ASI position error, from the POH calibration table

A static port sits on a fuselage whose local pressure differs from ambient, and by how much depends on angle of attack — so the error is worst **slow and nose-high**, exactly when the number matters most.

| CAS | indicates | error |
|---|---|---|
| 48 kt | **40 kt** | −8 |
| 80 kt | 80 kt | 0 |
| 118 kt | **120 kt** | +2 |

Straight off the published table, anchored at (0, 0) so a parked aeroplane indicates zero. **Flaps get their own table** — the POH prints two because at a given speed the flapped aeroplane sits at lower alpha — and the two are blended on flap position. `FlightModel` now publishes `telemetry.flaps` for this; telemetry is the display channel and already carries alpha and beta the same way, so **the six-field Controls contract was not widened** (§6c).

### The DI reads MAGNETIC — and gets nothing else

Headings have been **true** since Phase 1, which means the DI and the runway numbering have quietly disagreed by however much variation would be. `MAGNETIC_VARIATION_DEG = -12.0`, one number in one place.

⚠️ **The turning error is NOT applied to the DI, deliberately.** A directional gyro and a wet compass are different instruments that fail differently — the gyro is *steady in a turn by design* and precesses instead; the wet compass is honest in level flight and useless in a turn. Putting dip error on the DI would be modelling the wrong instrument.

**Gyro precession is also deliberately not modelled**: a real DI drifts and the pilot resets it against the compass, and adding drift with no reset control would be a usability trap, not realism.

### 🐛 The turning error was on cosine, and shipped on sine

The wet-compass model (written now, for the compass scope item 4 puts on the windscreen frame) had the error proportional to `sin(heading)`. That puts the maxima on **east and west** — the exact opposite instrument. It must be `cos(heading)`: largest through north and south, **zero through east and west**, which is why a pilot can roll out onto east by the compass and cannot roll out onto north.

Caught by the assertion "turning error vanishes on east and west", which reported 20° of error at both.

Sign check at north with left bank: `cos(0) = 1`, bank negative, error positive — the card swings right while the aeroplane turns left. **Undershoot North**, as it should be.

### Altimeter: what the Kollsman window says

An altimeter reads true height only when set to the actual QNH. **"High to low, look out below"** falls straight out: a setting left higher than actual makes it over-read, so the aeroplane is *lower* than indicated. Verified at the 273 ft per 10 hPa rule of thumb, and symmetric in both directions.

The conversion goes through `Atmosphere.getPressureAltitude` **twice** rather than restating its feet-per-pascal constant — two readings of the same altitude against two datums differ by exactly the datum difference. QNH and the setting default to standard, so nothing changes until Phase 5's weather supplies them.

### Six existing tests asserted the perfect instrument

Changing what the gauges display made six `SixPack` checks fail, correctly — they demanded the raw number back. They were updated **deliberately, not to green**:

- The unit-boundary check now feeds **80 kt**, the one speed the POH says the ASI reads correctly, so it tests the unit boundary and nothing else.
- Needle-position checks assert against **what the sampler produced**, not against the raw input — the needle's job is to point at what the instrument shows, and asserting the raw value would make the gauge and the instrument model disagree.
- "Absent telemetry reads zero" became "is survivable": **a true heading of zero is genuinely not magnetic zero**, and demanding it be would assert the absence of the feature.

Two new checks pin that the error reaches the panel at all, so a future "simplification" back to the raw number fails loudly.

---

## 33. The mesh is purged, and the aeroplane is the size of the published aeroplane (2026-08-06)

**752/752 across 19 suites**; `Cessna172` 29 → 33, `CameraController` 24 → 29.

### The imported mesh was imported, wired in, and removed on the pilot's call

`0fab920` loaded a Sketchfab 172 through `InsertService`, fitted its scale, and posed every control surface onto it. The pilot flew it and reported the shell *"really weird"* and the *"scaling very abnormal"* — it did not sit on the aeroplane. **Removed rather than patched**, and deferred rather than abandoned: a mesh may come back as its own stage, re-decided from scratch.

What went, in two files and nothing else:

| `Cessna172.luau` | `AircraftBuilder.luau` |
|---|---|
| `MESH_GREY`, the `meshPose` mirror in `addPair`, seven `meshPose` blocks, the `meshShell` spec | the `MESH SHELL` section — `loadMeshShell`, `meshShellProblem`, `meshShellScale` and their state — plus `posed()` and the shell build block |

⚠️ **`exteriorFromMesh` and `keepWithMesh` went too, and that is one step past "restore the flag to false".** Deleting `useMesh` — which the purge instructions called for — leaves nothing that reads either of them, and a dead boolean named after a deleted feature is exactly the trace the purge was for. Both are one line to reinstate if a mesh returns. **The diff is otherwise 100% deletions**: no mass, no aero, no surface definition moved, and the one added line renames `rawSpec` back to `decoSpec`.

**The exterior is the pre-mesh primitive shell of §31** — 78 parts, lofted fuselage, dihedral wing, struts, swept fin, gear legs — not the invisible structural boxes. Verified after the purge: **78 parts, 1 assembly, 1,111 kg**, and all six control surfaces still driven (elevator up on stick back, ailerons opposed with the right one raised on right roll, rudder right on right pedal, flap 30° down, trim tab opposing the elevator) — measured as **where each trailing edge physically moved**, not from the sign of an angle.

### The aeroplane was the wrong size in three directions at once

There was **no scale factor to fix**. The hand-built shell measured:

| | built | published 172S | error |
|---|---|---|---|
| span | 10.500 m | 11.00 | **−4.5%** |
| height | 2.920 m | 2.72 | **+7.4%** |
| length | 8.450 m | 8.28 | **+2.1%** |

Three errors in three directions, so one uniform factor cannot correct them and each axis is fixed in the part layout instead. It now measures **11.000 × 2.720 × 8.280** — and that is the *visible* shell, because the shell is what a pilot sees and measures.

- **Span** — the outer wing is 0.25 m longer each side and the tip and nav light follow it out. The aerodynamic `WING_SPAN` was **already 11.0**, so the drawn wing was 0.5 m shorter than the wing the model flies on; this closes that, it does not open it.
- **Height** — everything above y = 0.50 is compressed by 0.8425, so the fin keeps its proportions rather than having its tip sliced off, and the beacon still sits exactly on the fin tip. Its top face **is** the 2.72 m.
- **Length** — split between the nose (0.064 m aft) and the tail (0.106 m forward) in proportion to how far each already stood from the datum, so the aeroplane is trimmed to length without being shifted along it. The vertical tail moves as a **group**, or the rudder buries itself in the fin.

⚠️ **NOT ONE STRUCTURAL BOX MOVED.** Every change is a decoration: massless, skipped by `measure()`, incapable of touching the mass budget, the centre of mass, the static margin or the inertia tensor. `Cessna172`'s original 29 checks — static margin included — pass unchanged. §31's rule stands: *the skin exists to match the box*, and here the box was never what the published dimensions describe.

⚠️ **The whole-model envelope still reads 2.85 m, and that is correct.** The invisible structural `Fin` box tops out 0.13 m above the visible fin. Shrinking it to tidy the number would move mass and rewrite the inertia tensor to improve something nobody can see — §31's decision point, not a cleanup.

### Four checks now pin the dimensions

Computed in `Cessna172.runTests()` from the same numbers the builder reads, with each part's rotation folded in exactly as `createPart` folds it, so the check cannot drift from what is built. It agrees with the built model to four decimals by an independent path. The fourth asserts **the shell's lowest point is the wheel contact plane at −1.15 m** — without it, a fin lowered to hit 2.72 m against a sunken undercarriage would pass while sitting wrong on the runway.

### The pilot: 1.75 m is exact, 0.50 m wide is not reachable with it

Measured settled (§30's discipline — five consecutive readings within 0.005 studs, rig standing and still):

| | measured | wanted |
|---|---|---|
| height | **1.7502 studs** ✅ | 1.75 |
| shoulder width | **0.547** | ~0.50 |

⚠️ **One uniform `Model:ScaleTo` cannot deliver both, and no code change makes it.** The R15 rig is built with a shoulder-width-to-height ratio of **0.3125** against a human's 0.2857 — it is **9.4% too broad for its height**, and a uniform scale carries that ratio with it whatever value it takes. Scale for height and the shoulders come out 0.547 m; scale for width and the pilot is 1.60 m tall.

The two mechanisms that could narrow the rig are the ones §30 already measured: the R15 `BodyWidthScale` `NumberValue`s are **inert on this rig**, and per-part rescaling means hand-resizing a constraint rig carrying 15 `WrapTarget`s of layered clothing — the "manual part-rescaling" §30 established was never needed.

**Raised with the pilot rather than silently chosen**, per the scale-fix brief. The pilot's answer was to change the rig instead: **classic R6**, proportioned to look right beside the aeroplane rather than measured against a human. See the open item in §0 — **R6 is not a property Rojo can write**, which is a decision before it is a task.

**Boarding still moves the aircraft 0.000 m**, re-measured with the aeroplane confirmed at rest first.

⚠️ **`AircraftService` reports 33/35 if the suite is run the instant Play starts.** It was chased down rather than assumed: the first guess — that hand-built aircraft earlier in the session contaminated it — was **tested and disproved** (building aeroplanes by hand first, and running the whole client sweep first, both still give 35/35). Every 33/35 was a run fired immediately after "Game Started"; every run with a few seconds' wait passes. **Give the services time to start before believing a server-suite failure.** The suite is fine.

---

## 34. The pilot is a classic R6, built in code (2026-08-06)

**761/761 across 20 suites**; new `PlayerService` at 9.

The pilot asked for R6 — *"it doesn't have to be realistic in measurements, just very well proportional to the aircraft to hide that we even scaled down at all"* — after §33 established that no uniform scale can make an R15 rig both 1.75 m and 0.50 m wide.

### R6 is not a property Rojo can write, so the rig is built in code

`StarterPlayer`, `Workspace` and `Players` were all probed: **none of them carries a rig-type property.** The choice lives in place-level Game Settings, which is not a file, so §3's "files are the source of truth" cannot cover it. `PlayerService` makes it true in the repository instead:

```lua
Players.CharacterAutoLoads = false
Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R6)
```

The Studio setting is set to R6 as well, so the two agree and a place opened without the service still gets the right rig.

⚠️ **`PlayerService` runs LAST in `SERVICE_ORDER`, and that is load-bearing.** It stands the character on `Workspace.SpawnLocation`, which **AirportService moves** onto the apron at the airport elevation (§20, §30). Started any earlier, the pad is still at Rojo's y = 0 and the pilot spawns under the terrain.

**Nothing else needed changing.** `FlightController.scaleForHumanProportions` is rig-agnostic — it measures the assembled rig rather than assuming R15 — so R6 lands on 1.75 m through the same path, and `AircraftService.trackCharacter` still gets its `CharacterAdded` because assigning `player.Character` fires it normally. ⚠️ **A cosmetic preference must never leave a player bodiless**: if the R6 build fails the service falls back to `player:LoadCharacter()`, and the pilot gets an R15 body they can still fly.

### 🐛 The trap: the server's view of a scaled character is not evidence

Read from the **server**, the new pilot appeared to be standing **1.956 m underground** — torso on the apron, both legs straight through it — while the `Humanoid` reported `Running` throughout.

**It was an artefact.** `Model:ScaleTo` is applied by `FlightController` on the **client** and **does not replicate**, so the server holds unscaled 5-stud legs hanging off a root positioned by the client's 1.75 m character. Comparing that replica against the ground compares a full-size body to a scaled-down stance, and the difference looks exactly like sinking.

A `hipHeightFor()` was derived from the rig geometry to "fix" it, written with three tests, and **thrown away** — for R6 the feet rest at `ground + HipHeight`, so the derived 2.000 lifted the pilot into the air once scaled:

| HipHeight | feet vs ground |
|---|---|
| 0.7002 (the "fix", scaled) | **+0.6971 m** — floating |
| 0.0000 (the default) | **−0.0013 m** — standing on it |

**R6's HipHeight of 0 was right all along.** This is §30's lesson a second time: a number that cannot tell success from doing nothing is not a measurement. ⚠️ **Verify character geometry on the CLIENT.** The comment recording this is in the file, where the next person to see the server reading will be.

### Two smaller things that were measured, not assumed

- ⚠️ **The rig brings its own `Animate` LocalScript.** This was the real risk in hand-building a character: `StarterPlayer.StarterCharacterScripts` is **empty** in this place, so had the rig not carried Animate, the pilot would have stood frozen and §30's settle-then-measure would have had nothing to settle. Checked before the service was written.
- ⚠️ **A fresh rig's `GetExtentsSize()` is meaningless — 6.7 × 16.5 × 31.5 studs** — because its accessories have not welded on yet, and it has **no `PrimaryPart`**, so `GetPivot()` returns that sprawl's centre. The root is therefore found **by name**, and the feet are measured from the body parts only, which *are* already in their rest pose (root +18.000, feet +15.000, a clean 3.000). That is what lets a character be placed correctly on the first attempt instead of dropped and corrected.
- ⚠️ **A `CFrame` stores its position as float32.** At an airport 250 m up that is ~1.5e-5 studs of precision, and a test comparing to 1e-6 failed on the round-trip alone — reporting a spawn clearance of 0.050 as wrong when 0.050 was exactly right.

### What the pilot measures now

| | R6, settled on the apron |
|---|---|
| height | **1.741 m** (tolerance is 0.02) |
| feet vs ground | **−0.003 m** |
| torso width | 0.700 m |
| across the arms | 1.408 m |
| model scale | 0.3500 |

⚠️ **R6 is BROADER than R15, not narrower** — a 2-stud torso on a 5-stud rig is a **0.40** width-to-height ratio, against R15's 0.3125 and a human's 0.2857. It was chosen as a *look*, not as a fix for §33's width, and the pilot said so explicitly. What matters is the one they asked for: **against a 2.72 m Cessna, a 1.75 m pilot reads right**, and the wingtip sits just above their head where a high wing should.

---

## 35. Four bugs from the first flight of the resized aeroplane (2026-08-06)

**775/775 across 20 suites**; `PlayerService` 9 → 14, `FlightController` 46 → 51, `CameraController` 29 → 33. New shared `CharacterTuning`.

The pilot flew §33's resized Cessna with §34's R6 pilot, reported the flight itself as good, and brought back four faults. All four are fixed. **Three of them were caused by something silently rescaling or replacing a value that every source file still reported correctly** — the same shape of bug as §30's inert marker.

### 🐛 1a. `ScaleTo` scales WalkSpeed and JumpHeight with the rig

Reported as a reset leaving the pilot unable to jump properly. The first theory — that `StarterPlayer.CharacterWalkSpeed` never reaches a hand-built character — is **true and was fixed**, but it was not the cause. Measured on the live pilot afterwards:

| | `Constants` says | Humanoid carried |
|---|---|---|
| WalkSpeed | 20.00 m/s | **7.00** |
| JumpHeight | 1.00 m | **0.35** |

Both are exactly the tuning times **0.35**, the pilot's model scale. `Model:ScaleTo` rescales movement along with the rig, so `PlayerService` set the right numbers and `FlightController` shrank them a second later.

⚠️ **Scaling a rig does not make its owner a smaller person.** §30's rule is that a 1.75 m human walks at the configured speed whatever the rig measures, so the metre-scale values are **restored after the scale converges**, not scaled to match the model. Both callers now share `Shared/CharacterTuning.luau` so the two applications cannot drift apart.

### 🐛 1b. A reset left the camera at the aeroplane

`release()` handed the camera back with `CameraSubject = humanoid or camera.CameraSubject`, and the on-foot branch only repaired the subject **if the camera was still `Scriptable`**. On a reset from the seat both fail together: the old character is destroyed before the new one exists, so the humanoid is nil and the old subject is kept; `release()` has already set the type back to `Custom`, so the repair never runs. The camera stayed pointed at the aeroplane the pilot had just left.

⚠️ **A stale subject is the WRONG object, not a missing one.** A new character carries a new `Humanoid`, so every check of the form "fix it only if it is nil" sees a healthy camera. `groundSubjectFor()` is pure and compares against the live humanoid, and four checks pin the swap.

### 🐛 2. The camera was focusing a metre above the pilot's head

**Two wrong fixes shipped before this was measured properly, and both were wrong because the premise was.** "Roblox focuses on the centre of the head" is **false**.

⚠️ **ROBLOX FOCUSES THE CHARACTER CAMERA A HARD-CODED 1.500 STUDS ABOVE THE `HumanoidRootPart`, AND THAT CONSTANT DOES NOT SCALE WITH `Model:ScaleTo`.** Measured by writing offsets and reading `camera.Focus` back in the root's own frame — the focus is exactly `(0, 1.500, 0) + CameraOffset`, one for one, on all three axes:

| `CameraOffset` | focus, in the root's frame |
|---|---|
| `(0, 0, 0)` | `(0.000, 1.500, 0.000)` |
| `(0, 0, −0.5)` | `(0.000, 1.500, −0.500)` |
| `(0.5, 0, 0)` | `(0.500, 1.500, 0.000)` |

1.500 is where a **stock 5-stud rig's** head sits. The pilot is scaled to 0.35, so their head is only **0.514** above the root — the camera was orbiting and zooming to a point **0.905 m above their face**. Zero offset was never "centred on the head"; it was above the head entirely, which is why nudging the offset never helped and the first attempt read as *"really funky"* while walking.

The offset is now the **difference between that stock constant and the live rig's geometry**, so it lands on the nose — the point between the eyes, on the front of the head. Measured after the fix: focus **1.7 mm** from the nose point, against 0.905 m before. Same trap as the name tag: a stock-scale constant the engine applies over a scaled rig. (⚠️ §36 then moved the pivot from the nose **into the head centre** — the pilot found the on-foot orbit swings around a point ahead of the body, which §2's earlier notes had already called *"really funky"*.)

**The cockpit `EYE_OFFSET` was also raised, 0.60 → 0.65**, which was what the written brief asked for before the on-foot problem was clarified. Measured against the airframe:

| eye (datum) | glareshield clearance | view down over the cowling |
|---|---|---|
| 0.75 (was) | 0.055 m | 10.6° |
| **0.80 (now)** | **0.105 m** | **13.0°** |

⚠️ **A REALISTIC SEATED EYE HEIGHT DOES NOT FIT THIS AIRFRAME, and that is a decision point.** A 1.75 m person's eye sits ~0.78 m above the seat pan, which would be datum 1.03 — inside the wing centre section and above the cabin roof. It is 0.55 m above the pan instead, because the pan is **1.40 m above the wheels where a real 172's is about 0.95 m**: the seat is roughly 0.4 m too high in a cabin that is otherwise the right size. Fixing it means moving `PilotSeat`, which is **structural** (§31). Raise it with the pilot before acting.

### 3. The name tag floated far above the head

⚠️ **Roblox's built-in name tag is positioned in stock studs and does not follow `Model:ScaleTo`**, so on a 1.75 m pilot it hangs overhead, and nothing exposes its offset to move it down. A replacement billboard scaled to the pilot was built, and then **deleted on the pilot's instruction** — they asked for no name in the world at all. `HumanoidDisplayDistanceType.None` on both the server and the client, which takes the health bar with it. Neither belongs over a pilot's head in a flight simulator.

### 🐛 4. The vestigial piece on the tail was the fuselage itself

The loft's last station sat at z = 4.70, so the tail cone **stopped in mid-air a few centimetres short of the fin's trailing edge** — a square-ended block sticking out the back of the aeroplane with nothing behind it.

⚠️ **§33 caused it, and §33's own numbers are still correct.** Moving the vertical tail 0.106 m forward to trim the aircraft to its published length pulled the fin off the end of the cone it used to hide. The cone was always blunt; it simply used to be covered.

It was found by **census, not by eye**: every visible part was checked against the definition — 78 parts, 66 declarations, no duplicates, none missing, nothing floating — which proved there was no stray part to delete, and then by colouring the tail part by part until the offender was unambiguous.

⚠️ **IT TOOK THREE GOES, BECAUSE THE FIRST TWO MOVED THE BLUNT FACE INSTEAD OF SHRINKING IT.** The pilot had to report it twice more.

| attempt | last station | result |
|---|---|---|
| original | z = 4.70 | stopped in mid-air just short of the fin's trailing edge — a square block hanging off the back |
| first fix | z = 4.35 | inside the fin's chord, but still a **0.35 × 0.44** face. The fin is only 0.13 thick and the tailplane 0.15, so its corners stood proud above and below the tailplane on both sides of the fin |
| **now** | z = 4.30 **and** 4.60 | a **0.15 × 0.22** post, about a tenth the area, dying between the tailplane and the fin |

⚠️ **A loft can only ever end in a flat face, so the question is how BIG it is and what covers it — not where it is.** Moving a blunt end does not stop it being blunt.

⚠️ **AND ONE STATION CANNOT TAPER IT.** Each box is sized to the **mean** of its two stations, so the last box can never reach the last station's dimensions — shrinking the final station only pulls the box halfway. It takes **another station beyond it** to bring the last box down, which is why this ends in two stations rather than one smaller one.

⚠️ **Do not "simplify" this by deleting the last station.** That leaves a *bigger* face (0.51 × 0.58) further forward, where even less covers it.

**Envelope, mass and balance are unchanged**: still 11.000 × 2.720 × 8.280, still **1,111.0 kg**, one assembly, the same centre of mass, `Cessna172` still 33/33. The part count is **79** (was 78) — one more massless loft box.

---

## 36. The pilot is 1.55 m, and the on-foot camera pivots inside the head (2026-08-06)

**Test counts unchanged from §35** — the `FlightController` suite still passes, with the two `faceCameraOffset` checks re-expressed for the head-centre pivot.

The pilot asked why the Cessna reads smaller than PTFS's Cessna. **It is not the aircraft's size** — §33 fixed that to the published 8.28 × 11.00 × 2.72 m — it is the **avatar-to-plane ratio**. PTFS leans the same ratio toward the aeroplane; our 1.75 m pilot stood at a ratio that read small.

### Decision: shrink the pilot to 1.55 m, and only via the existing uniform scale

- **1.30–1.40 m was rejected** — it reads child-sized, and a uniform `ScaleTo` carries the width-to-height ratio whatever value it takes, so no uniform shrink ever fixes a "too small next to the plane" reading.
- **1.55 m keeps a compact adult** while tipping the ratio toward the aeroplane the way PTFS does.
- The mechanism was already there: `pilotScaleFor()` = `currentScale * PILOT_HEIGHT_M / measuredHeight` applied through `Model:ScaleTo` (§30). **Only the constant changed**: `PILOT_HEIGHT_M` 1.75 → 1.55 in `FlightController`.

### Nothing else needed to move, and that is by construction

- **The cockpit eye does not move** — it is anchored to the `PilotSeat` (`CameraController.EYE_OFFSET`), not to the head, so pilot scale is irrelevant to the seated view.
- **The on-foot framing follows automatically** — `frameGroundPilot` reads the live `character:GetScale()` rather than a hard-coded height, so the zoom range tracks a 1.55 m pilot the same way it tracked 1.75 m.
- ⚠️ **A 1.55 m pilot still cannot sit naturally in this airframe.** Their real seated eye would be about datum y = 0.95; the eye slot tops out at 0.80 (§35's 0.155 m slot). The shrink was a *look* decision, not a fix for the seat — the seat stays a structural decision (§31/§35, raised with the pilot before acting).

### The on-foot orbit pivot moved from the nose to the head centre

§35's fix landed the camera focus on the **nose** (front of the head). The pilot reported the orbit still did not pivot seamlessly and asked for the pivot **inside the head**. This is consistent with §35's own history: aiming at the eyes/front of the head was tried earlier and rejected as *"really funky"* — the orbit swings about a point that is not the body.

- `faceCameraOffset` → **`headPivotOffset(headAboveRoot)`**, which returns `(0, headAboveRoot − 1.5, 0)`: the focus lands at the head centre in the root's frame, exactly the stock constant minus the live geometry. `NOSE_RISE` and the `headSize` input are gone.
- `fitCameraToEyes` → **`fitCameraPivot(character)`**, applied after the scale converges, same as before.
- X and Z are zero because a rig's head is centred over its root part — no lateral push, the orbit rotates about the skull.
- Tests re-expressed: a stock rig needs no correction; a scaled pilot's pivot is pulled down onto the head centre (not the nose); the pivot sits inside the head (Z = 0); the reconstructed focus equals `headAboveRoot`; missing geometry yields zero.

⚠️ **Comments in `FlightController` and `CameraController` previously described the 1.75 m / 0.35x pilot and the nose pivot.** The now-stale ones were updated to reference `PILOT_HEIGHT_M`; historical measurement numbers (7.00 / 0.35 movement rescale, 0.905 m focus error) are retained but labelled as measured at the old 0.35x scale.

### The re-fly cleared it (2026-08-06)

The pilot re-flew the committed §36/§37 build and reported it good: the **1.55 m pilot feels right**, the **head-centre orbit pivots seamlessly**, and the **trim tab rides the elevator**. ⚠️ The earlier "avatar reads wider than the fuselage" report was the **pre-§36 build** (an unscaled ~5.16 m avatar with ~2 m shoulders next to a 1.16 m cabin); the §36 shrink resolves it by construction. With the re-fly green, **Phase 4 items 4 and 5 begin** (HANDOFF §14), including the seat-height open decision now being urgent because the player's own avatar must physically fit the interior.

---

## 37. The trim tab now rides the elevator (2026-08-06)

**783/783 across 20 suites**; `AircraftBuilder` 20 → 25, `SurfaceAnimation` 21 → 24.

The pilot reported **a small piece on the right elevator that does not move** while the elevator swung around it. It was the trim tab.

### Every hinge was bolted to the airframe

`AircraftBuilder.build` gave **every** hinged surface a Motor6D with `Part0 = root`. That is right for the eight surfaces bolted straight to the aeroplane, and wrong for the one that is not: a real 172's trim tab hinges on the **elevator's trailing edge**, so it has to do two things at once — ride the elevator wherever the pilot puts it, and add its own trim deflection on top. Anchored to the airframe it only ever did the second.

⚠️ **THE ARITHMETIC WAS ALREADY CORRECT, WHICH IS WHY NOTHING CAUGHT IT.** `SurfaceAnimation.surfaceAngle` returned a perfectly good trim deflection the whole time, and its suite passed 21/21 — every check in it is **pure**, and the bug lived in the joint the builder made. The two layers were each right on their own.

### The fix: `hinge.parent`

An optional `hinge.parent` names the part a surface swings from; absent, it is the root, which is every other surface. `TrimTab.hinge.parent = "ElevatorRight"`, and the builder chains the motor to that part.

The C0 maths generalises rather than special-cases: `C0 = Rparent⁻¹ * (p + h − pParent)` folds the parent's own mounting rotation back out, so C0 still lands in the **datum's axes at rest** and the animation layer keeps saying "rotate about X" meaning the aircraft's lateral axis. With the parent as the root it reduces to exactly the old expression, so the other eight surfaces are untouched — and **nothing moves at rest**, which a check now pins.

Measured on a built model, driven through the animator:

| | elevator | tab, world | tab **relative to the elevator** |
|---|---|---|---|
| stick back | −22.00° | −22.00° | **+0.00°** — rides it |
| stick forward | +22.00° | +22.00° | **+0.00°** — rides it |
| nose-up trim, stick neutral | +0.00° | +15.00° | +15.00° — its own deflection |
| stick back **and** nose-up trim | −22.00° | **−7.00°** | **+15.00°** — both at once |

Carried up 22° with the elevator and still sitting 15° nose-down of it. **Mass 1,111.0 kg, one assembly, the same centre of mass** — the tab was already massless decoration, and a chained motor keeps it in the assembly.

### Two traps worth keeping

⚠️ **THE MOTOR STAYS PARENTED TO THE ROOT even though `Part0` is not the root.** `SurfaceAnimation.new` finds each motor with `root:FindFirstChild("Hinge_"..name)`, so re-parenting it to the elevator would hide it from the animator and the tab would stop moving **altogether** — a worse bug than the one being fixed. A Roblox joint works from anywhere; only `Part0`/`Part1` decide what it connects.

⚠️ **A wrong `hinge.parent` would not error.** `Part0 = nil` builds a motor that silently leaves the surface hanging in space, so `validate()` now refuses a parent name that is not a part or a decoration, and refuses a surface hinged onto itself — the same reasoning as the duplicate-name check in §31.

**A new check drives a real built model inside `SurfaceAnimation.runTests`**, because that is the only place the builder and the animator meet, and this bug was invisible to either alone. It asserts all three properties: the tab is carried by the elevator, it still deflects on trim against it, and full stick with full trim **compounds** rather than one overriding the other.

---

## 38. Two actions were on H (2026-08-06)

**783/783 across 20 suites**, `InputController` back to 110/110 from **109/110**.

Asked for as a scan for overlapping keybinds. There was exactly one, and it was live:

| key | claimed by |
|---|---|
| **H** | `ToggleHud` **and** `TrimNoseDown` |

`ToggleHud = H` is **pilot-specified** and documented in §19 as the pilot-facing control for the raw-numbers panel. `TrimNoseDown = H` arrived later, in an **uncommitted edit** that moved pitch trim off `Comma`/`Period` onto `H`/`U`. So the newer, unspecified binding moved: **nose-down is now `J`**, directly below `U`, keeping the vertical up-above-down pair the edit was reaching for. `TrimNoseUp = U` is unchanged.

The full set, verified with no collisions: `W`/`S` throttle · `A`/`D` yaw · `F`/`G` flaps · `U`/`J` trim · `B` brake · `C` camera hold · `V` view cycle · `T` view toggle · `R` altitude hold · `E` engine · `L` gear · `P` pause · `H` HUD · `Backspace` reset.

### ⚠️ The guard was working. The aggregate was being read instead.

`"No two actions share a key"` had been **failing** — `InputController` was **109/110**, not the 110/110 quoted in the sessions before the edit landed. Nothing was wrong with the test; the clash simply arrived after those runs, and later sweeps printed only per-suite totals that were skimmed rather than read. **A suite total is not a pass. Read the failing check.**

### What the scan covered beyond the table

- **Every raw input handler resolves its key through the bindings table.** `FlightController.onInputBegan` uses `resetKey()` and `UIController.onInputBegan` uses `hudKey()`, so there are **no hard-coded keys anywhere outside `DEFAULT_BINDINGS`** and the collision check genuinely covers the whole game.
- **On-foot versus flying does not create a second clash.** `update()` only runs while an aircraft is being flown, so `W`/`A`/`S`/`D` are throttle and yaw only in the air and plain character movement on the apron. The two actions consumed outside `update()` — `ToggleHud` and `ResetAircraft` — are on `H` and `Backspace`, neither of which Roblox claims.

⚠️ **`InputController.rebind` does NOT reject a clash** — it asserts the action exists and then assigns. A settings menu could therefore reproduce this bug at runtime, and only `DEFAULT_BINDINGS` is checked by the suite. **Left alone deliberately**: an existing test rebinds `Brake` onto `V` (which `ViewCycle` holds) to exercise the mechanics, so rejecting clashes would change that contract. Worth deciding when the settings menu is actually built.

---

## 39. The seat came down and the cockpit went in (2026-08-06, Phase 4 items 4 and 5 begun)

**787/787 across 20 suites**; `UIController`'s aggregate 177 → 181. The aeroplane is **116 parts**, still **1,111.0 kg**, one assembly.

### The seat, lowered on the pilot's decision

`PilotSeat` is **structural**, so moving it was a decision (§31/§35), and §4's figures were re-verified rather than assumed:

| | before | after |
|---|---|---|
| seat centre | y +0.150 | **y −0.180** |
| pan above the cabin floor | 0.63 m | **0.30 m** |
| headroom above the pan | 0.60 m | **0.93 m** |
| mass / assemblies | 1,111.0 kg / 1 | **unchanged** |
| centre of mass | — | moved **0.3 mm** |
| static margin | 14.2% MAC | **14.183% MAC** |

0.63 m above the floor was a bar stool. At 0.30 m a seated avatar clears the roof — a 1.55 m pilot needs about 0.81 m of sitting height against the 0.93 m now available, which was the pilot's actual complaint.

### ⚠️ The eye did NOT follow the seat down, and that is deliberate

`EYE_OFFSET` went **0.65 → 0.98** to hold the cockpit eye at **y = 0.80**, where §35 measured it good. Letting it ride the seat down would have put it at **y = 0.47** — below the **0.695** glareshield, so the pilot would have been looking at the back of the panel.

⚠️ **THE EYE IS THEREFORE ~0.19 m ABOVE THE AVATAR'S OWN EYES.** A seated 1.55 m pilot's eye is about 0.69 m above the pan, which is y = 0.61 — inside the panel. **The gap is the cowl deck, not the seat**: `Fuselage04` tops out 1.075 m above the cabin floor where a real 172's glareshield is about 0.75 m. Closing it means lowering the loft's shoulder, which changes the exterior profile — **a separate decision for the pilot, not an assumption.**

### The interior (item 4)

38 massless decorations: cabin floor, two seats with backs and headrests, panel board, glareshield, breaker panel, two yokes with wheels and grips, four rudder pedals, throttle quadrant with throttle and mixture knobs, trim wheel and indicator, fuel selector, six switches and a magneto key. **Physics untouched by construction** — `measure()` skips massless parts, and mass, assemblies and centre of mass are identical to before the interior existed.

⚠️ **THE FUSELAGE IS SOLID, NOT A SHELL, SO THE INTERIOR LIVES INSIDE IT.** There is no hollow cabin to furnish. It works because `hideForCockpit` already hides whatever encloses the eye — `Cabin`, `Fuselage04`, `Fuselage05`, `Windscreen` and both wing centre parts vanish from the inside — which is the same mechanism that already lets the pilot see out at all.

🐛 **The panel was first built 0.07 m in front of the eye** — directly under the pilot's chin and invisible from the seat, because it was tucked under the aft end of the glareshield. ⚠️ **Its station is set by the WINDSCREEN, not by eye distance**: the glass is a raked slab, so how high the board may reach depends on how far forward it sits (z −1.05 → glass at 0.565; z −0.98 → 0.605; z −0.90 → 0.652). At **z = −0.98** the board tops out at 0.576 just under the glass, 0.43 m ahead of the eye and 27° below it.

### The six-pack is on a real panel now (§19, waiting since Phase 2)

`SixPack.mountOnPart(board)` puts the existing panel frame on a `SurfaceGui` on the cockpit's `PanelBoard`. **No drawing code changed** — that was §19's whole point, and it held.

⚠️ **THE BOARD'S ASPECT RATIO IS THE SIX-PACK'S, NOT A GUESS.** The frame is 488 × 240 px, so the board is **0.96 × 0.472 m** — 2.0333:1. A SurfaceGui maps a fixed-pixel frame onto the face, so a board of any other shape renders every circular dial as an **oval and nothing errors**. A check asserts the two agree to 1%.

### Still to do in this phase

1. ⚠️ **`UIController` still drives the screen panel, not the 3D one.** `mountOnPart` exists and is tested, but nothing wires it to the flying aircraft yet — the gauges above were driven by hand. That wiring is the next step, and it needs a decision on whether the screen panel stays as well.
2. **The seated avatar is not rigged.** The geometry it needs is in place (wheel positions, pedal positions, throttle), but no limb posing exists. ⚠️ **`Model:ScaleTo` does not scale Roblox's seat weld** — §35 measured a seated rig sitting **2.1 m above the seat**, invisible only because the seated pilot is transparent (§6e). **That has to be solved before an avatar can be shown in the cockpit at all.**
3. **Switches are inert geometry**, as decided — no `ClickDetector`, no `ProximityPrompt`. Keyboard wiring is Phase 4c.
4. ⚠️ **Both seats are symmetric about the centreline and the eye is in neither.** The structural `PilotSeat` is at x = 0, so the camera is too; a real 172 pilot sits left. Moving it is another structural change *and* puts a lateral offset on the centre of mass. Recorded, not acted on.

---

## 40. The cockpit view now shows the cockpit, and the pilot sits on the left (2026-08-06)

**790/790 across 20 suites**; `CameraController` 33 → 36. Physics unchanged: **1,111.0 kg, one assembly**.

The pilot reported: *"I cannot see the yoke. I cannot see the control panel inside the cockpit."* They were right, and it was measurable.

### 🐛 The cockpit is below the eye line, and the camera looked level

The eye is a **position-only anchor** and `cockpitCFrame` aimed level along −Z. Measured from the left-seat eye against a 35° half-frame:

| | angle below the eye | in frame? |
|---|---|---|
| glareshield | −10.7 .. −31.7° | yes — the only thing that was |
| panel board | −13.9 .. −57.5° | **no** |
| yoke wheel | −53° | **no** |

`COCKPIT_PITCH_DEG = 22` fixes it: the panel sits in the lower half, the yoke is above the bottom edge, and the horizon is still 13° inside the top. ⚠️ **It is ORIENTATION ONLY** — the eye does not move, so the occlusion set, the airframe and the physics are all untouched by it.

⚠️ **`cockpitEyePosition` exists so occlusion never carries the pitch.** What encloses a point cannot depend on which way you look from it, and `hideForCockpit` takes a position. A check asserts the two agree, or the hidden set would start changing with the camera's attitude and the aeroplane would flicker as the pilot rolls.

### The pilot moved to the left seat

`PilotSeat` went to **x = −0.30** (structural, so §4 was re-verified): mass, assemblies, extents and static margin unchanged, and the lateral centre of mass moved **0.27 mm** against a 10 mm bound. `SEAT_X` is the single number placing the seat, cushion, yoke and eye, so they agree by construction.

### 🐛 Two exact-symmetry tests were measuring the seat

`"Wing arms are mirrored about the centreline"` and `"Steering is symmetric"` both asserted to **1e-6** — and the arms are measured from the **centre of mass**, which is now 0.27 mm off-centre *by design*. Both now carry a physical tolerance (1 mm of arm, 0.1% of torque). A real asymmetry is off by whole metres or reverses sign; neither test loses any power.

### ⚠️ The eye could NOT go the full 0.30, and the wing is why

An eye directly over the left seat lands **inside the structural `WingLeft` box** — it reaches inboard to x = −0.25 and sits 0.825 above the floor, only 0.025 above the eye — so the occlusion margin counted the wing as enclosing the eye and hid it. `"The outer wings are NOT hidden"` failed exactly as §31 says that check must.

The eye therefore sits at **x = −0.10**: inside the pilot's own cushion (−0.53..−0.07), still the left seat rather than the centreline, but clear of the wing's box. Going the full 0.30 needs the wing root raised or the eye lowered — **airframe changes, not camera ones**.

### The yoke was moved to be visible

Once the seat went left, the pilot's eye sat directly **above** their own yoke: the wheel measured **75° below**, and no sane pitch brings that into frame. At y 0.42 / z −0.84 it is 53° below, which the 22° pitch clears. ⚠️ It is higher than a seated pilot's hands really are — **the same 0.19 m the eye is too high by, with the same root cause: the cowl deck.**

### ⚠️ Still open from this session

1. **T free-look is NOT built.** T still toggles Cockpit ↔ Chase. The rebind, `viewCount`/`VIEWS`/`toggleViews` and the `Init` assertions that pin T are untouched.
2. **The instruments are NOT view-dependent yet.** `UIController` still drives the screen panel; `mountOnPart` is built and tested but nothing wires it to a flying aircraft. The dials in the verification screenshot were driven by hand.
3. **The seated avatar is not rigged**, and still blocked on §35's seat-weld measurement.

---

## 41. The sight line: sitting in the seat, looking slightly up (2026-08-06)

**790/790 across 20 suites**, physics unchanged (1,111.0 kg, one assembly, lateral CoM 0.27 mm).

The pilot: *"The view of the character is too high and we are looking down. The view on a Cessna is not like that — you would be looking slightly up and see all the instruments in front of you."*

### The 22° pitch-down was a symptom, and the eye height was the cause

§40 bought visibility with `COCKPIT_PITCH_DEG = 22`, which is precisely what reads as "looking down". The eye was **0.19 m above the avatar's real seated eye** — the camera was at the top of the pilot's head.

⚠️ **THE FIX WAS TO DROP THE EYE, NOT TO REBUILD THE AEROPLANE.** The measurement that decided it: the panel is only **0.43 m** from the eye and subtends **57.5°** of a 70° frame, so at the old eye height nothing but a steep gaze could contain it. Lowering the eye to the avatar's own seated height (**y 0.61**, `EYE_OFFSET.y` 0.98 → 0.79) and dropping the dashboard group 0.116 m with it lets a **16°** gaze hold the horizon *and* the whole board:

| | in frame at 16° down |
|---|---|
| horizon | **+16°** |
| cowl top | +12.4° — you look **slightly up** over it |
| glareshield | +8.0 .. −0.6° |
| panel board | **+4.5 .. −32.2°** — fully visible |
| yoke wheel | **−11.8 .. −31.1°** — fully visible |

**No exterior geometry changed.** The cowl-deck remodel §40 flagged turned out not to be needed: `Fuselage04` is *hidden in cockpit view anyway*, so its height never blocked the sight line — only the visible **glareshield decoration** did, and that is a decoration.

⚠️ **THE OCCLUSION SET SHRANK, AND THAT IS THE POINT.** At the lower eye only `Cabin`, `Fuselage04` and `Fuselage05` enclose it — the **windscreen and both wing parts are no longer hidden**, so the pilot sees the glass and the wings. The board, glareshield and yoke are never enclosed, so nothing hides the instruments the pilot has to read.

### Still open

1. **Task B is NOT done: the 3D board is still blank in flight.** `SixPack.mountOnPart` is built and tested, but `UIController` still drives the screen panel and nothing wires the 3D one to a flying aircraft — the dials in the verification shots were driven by hand, both times. The view-dependence decision (cockpit → 3D live, screen off; chase/free → screen live, 3D off) is recorded and unimplemented.
2. **T free-look** — untouched (§40 item 1).
3. **Seated avatar** — untouched, still blocked on §35's seat-weld measurement.

---

## 42. Sight line moved into the left seat; the 3D panel is wired but UNVERIFIED (2026-08-06)

**620/620 client checks green**, physics unchanged.

### The eye is now genuinely in the left seat

| | §41 | now |
|---|---|---|
| eye x | −0.10 | **−0.30 (full left seat)** |
| eye y | 0.61 | **0.58** |
| gaze | 16° down | **13° down** |

⚠️ **§40's WingLeft blocker was an artefact of the HIGH eye, and it is gone.** At y 0.80 an eye over the left seat sat inside the wing box and hid the wing; at y 0.58 the wing is 0.245 above it, well outside the 0.12 margin. Re-measured: the hidden set is `Cabin`, `Fuselage04`, `Fuselage05` only — **the wings are not hidden**, and the check that caught it before stays green. The eye could go the full 0.30 all along once it came down.

⚠️ **THE HORIZON AND THE BOARD'S BOTTOM EDGE CANNOT BOTH FIT BELOW ~18° OF PITCH.** The board is 0.43 m from the eye and subtends **57.5°** of a 70° frame, so horizon-to-board-bottom spans about 53°. At 13° the glareshield and yoke are fully in view and the board's lower rim is clipped by a few degrees. Closing that needs the panel FURTHER FORWARD, which is cabin geometry — not a camera tune.

### ⚠️ The 3D instrument wiring is written but NOT verified

`SixPack.Init`'s loop now mounts `mountOnPart` on the flying aircraft's `PanelBoard` and switches sets by view: **cockpit → 3D live and the screen panel off; chase/free → screen panel live and the 3D off; neither while not flying.** It re-mounts when the aircraft changes, because a reset builds a new board and a cached SurfaceGui would adorn a destroyed part.

⚠️ **NONE OF THAT HAS BEEN SEEN WORKING.** `Seat:Sit()` from a script does not make `FlightController` adopt the aircraft — `getSystems()` stays nil and `isFlying()` false — so the branch never ran in testing. One reading during the attempt showed the 3D `SurfaceGui` **Enabled while not flying**, which the code should not allow; it was not chased down. **Treat this as unproven until a pilot boards through the real prompt and looks.** The suites passing says only that nothing else broke.

### Still open

1. The verification above.
2. **Working yoke/throttle** — not started; they are still inert decorations.
3. **T free-look** — untouched (§40 item 1).
4. **Seated avatar** — untouched, blocked on §35's seat-weld measurement.

---

## 43. The cabin is closed, in white (2026-08-06)

**623/623 green**, physics unchanged (1,111.0 kg, one assembly, 11.000 × 2.850 × 8.280). 128 parts.

The interior shell is now white — walls, headliner, floor, firewall and rear bulkhead — and the **door posts, window sill and window rail** close the forward-left quadrant that the walls alone could not. The walls run floor-to-sill and the side glass carries on above them; between the windscreen's edge and the window's leading edge there had been nothing at all, which is what the pilot kept seeing straight out of.

Also this session: the **glareshield slab over the instruments is gone** (it was `GlareShield`, and it read as a black bar across the panel), and the **glass is natural** — 0.55 transparency / 0.2 reflectance / a heavy blue tint was why it looked like a coloured slab rather than glass; it is now 0.88 / 0.05 and near-neutral.

⚠️ **Every one of these is a massless decoration, so the enclosure cannot touch the mass budget** — and, like the walls, each is thin and hard against the cabin side so it never encloses the eye and is never taken by `hideForCockpit`. The hidden set is still exactly `Cabin`, `Fuselage04`, `Fuselage05`.

### Right-button free look

Hold the right mouse button while flying and the pilot's head turns; release and it eases back to forward. ⚠️ **The cursor is LOCKED IN PLACE for the duration.** The cursor *is* the yoke (§6g), so a drag-to-look that let the pointer travel would haul the controls across their range while the pilot was only looking around — the exact failure §7 warns about. `LockCurrentPosition` freezes the pointer, the yoke keeps its deflection, and the deltas still arrive. `Shutdown` hands the cursor back, because being left with a frozen pointer is worse than any camera fault. Clamped to ±120° yaw / ±70° pitch and rotation-only, all three pinned by checks.

⚠️ **NOT HANDS-VERIFIED.** Free look and §42's view-dependent 3D panel wiring are both code-verified only — a real mouse button has never been pressed on them, and boarding through the prompt is still not reachable from a script. Treat both as unproven.

---

## 44. Grayboxing: all aircraft/cockpit 3D modeling postponed until the feature-complete v1 (2026-08-06)

**Decision (pilot):** ALL aircraft/cockpit 3D modeling is postponed until the first version of the game with all of its features is done. The project runs in **GRAYBOX mode** from here.

- **Keep the existing geometry as-is** — the lofted Cessna exterior, the cockpit interior, the 38 decorations, the closed white cabin (§43) — it is the graybox. No further 3D modeling, no 3D polish, no sight-line tuning, no tangible-instrument visuals, no avatar-rigging visuals until v1 is feature-complete.
- **The §42 parked cockpit work stays parked**: the working yoke/throttle (inert decorations still), §42's UNVERIFIED view-dependent 3D panel wiring (written, never seen working — the 3D board stays blank), and the seated avatar (still blocked on §35). Right-button free-look is done (§43) and supersedes the old T free-look idea. The **screen panel remains the live instrument set**.
- **Airport design happens BEFORE the 3D modeling pass** (pilot, 2026-08-06) — airports are feature work, not part of the postponed 3D pass.
- **New features build on the graybox**: whatever a feature needs visually uses the geometry that exists or a graybox placeholder — never a modeling detour.
- **Phase order from here:** the feature phases first — 4b (flight tablet) → 4c (172S systems) → 5 (weather + jet) → 6 (audio, damage, persistence, tutorial) → the remaining feature phases, **including airport design** — then the **3D modeling pass at the very end**.

---

## 45. The aeroplane is drawn 1.872× life size, and the physics is not (2026-08-07)

**799/799 across 20 suites** (was 790; +9 new checks). `CameraController` 36 → 45, every other suite unchanged in count.

### The decision

**Pilot's call:** the 172 read too small beside the 1.55 m R6 pilot (§36). Enlarge the **aeroplane**; do not shrink the pilot — shrinking was already rejected in §36 as child-sized.

```
K = target length / published length = 15.5 / 8.28 = 1.8720
```

| | published 172S | drawn at K | measured on the built model |
|---|---|---|---|
| length | 8.28 | 15.50 | **15.500** |
| span | 11.00 | 20.59 | **20.592** |
| height | 2.72 | 5.09 | **5.092** |
| wing root / underside | 0.96 / 0.85 | 1.80 / 1.59 | **1.797 / 1.591** |

### ⚠️ Only the SKIN, the GEAR and the SEAT scale. The nine mass boxes do not.

This is the whole design, and it was measured before it was chosen. Moment of inertia goes as K² at fixed mass, so scaling the structural boxes multiplies **every axis by exactly 3.50×**:

| axis | real 172S | current | if the boxes had scaled |
|---|---|---|---|
| pitch | 1,825 | 2,951 (1.62×) | 10,341 (**5.67×**) |
| yaw | 2,667 | 4,922 (1.85×) | 17,249 (**6.47×**) |
| roll | 1,285 | 2,535 (1.97×) | 8,884 (**6.91×**) |

§29/§31 already record pitch inertia as too high and **unfixed**, and call closing it a decision point for the pilot rather than an assumption. An aeroplane at 6.9× a real 172's roll inertia rolls like an airliner and would not survive the §9/§14 gates. So the nine boxes holding 1,104 of the 1,111 kg were left alone.

**Scaled:** the 116 `decorations` (whole skin including the interior), the three wheel boxes, `PilotSeat`, and `gear.wheels` offsets and radii.

**Not scaled:** `WING_AREA` 16.17, `WING_SPAN` 11.0, the aero coefficients, `surfaces`, the mass budget, the nine mass boxes.

The drawn wing is visibly larger than the wing the strip theory acts on. **That mismatch is the intended look**, made explicitly in one place instead of by drift.

⚠️ §31's rule is inverted here **knowingly**: normally the skin exists to match the box. This is the one case where the skin is deliberately allowed to outgrow it.

### The wheels and the seat are the exceptions, and both are forced

- **Wheels** — contact is Roblox's solver against real collidable parts (see the gear block). An unscaled wheel leaves the enlarged aeroplane drawn about a metre into the runway, standing on invisible gear.
- **PilotSeat** — the pilot has to sit in the enlarged cockpit.

Together they are 7 kg of 1,111, so they move the centre of mass by about a millimetre and the inertia by roughly 1.5%. Measured, not assumed.

### ⚠️ There was no density work to do, and the brief assumed there was

The brief called for adjusting part **densities** after K³ ≈ 6.56× volume growth, and forbade touching `mass` fields. **It is the other way round.** `parts` specify **mass in kilograms** and `AircraftBuilder` solves for the density each one needs (`density = spec.mass / volume`, AircraftBuilder line 263).

Mass is the **input**, so growing a part cannot change its mass — it lowers the density the builder asks for, moving **away** from the ceiling of 100 rather than toward it. Minimum density across the scaled parts fell 16.53 → 2.52, still far above the 0.01 floor. **Nothing needed adjusting and nothing was adjusted.**

### §4's numbers, before and after

| | before | after |
|---|---|---|
| assembly mass | 1,111 kg | **1,111 kg** |
| assemblies | 1 | **1** |
| centre of mass (datum z) | −0.0601 | **−0.0613** (1.2 mm aft) |
| static margin | 14.18% MAC | **14.27% MAC** |
| tail arm | 4.210 m | **4.209 m** |

### Goal ratios against the 1.55 m pilot

| | target | achieved | |
|---|---|---|---|
| (a) length / pilot height | ~10× | **10.00×** | ✅ authoritative |
| (b) head below the wing root | yes | **1.55 < 1.591** | ✅ by 41 mm |
| (c) pilot width / fuselage width | ~0.5 | **0.23** | ⚠️ soft |
| (d) pilot height / plane height | ~0.5 | **0.30** | ⚠️ soft |

⚠️ **(c) and (d) cannot be met while (a) is met, and the brief said so in advance.** They are eyeballed from screenshots; (a) is the authoritative target. Hitting 0.5 on either would need K ≈ 1.1–1.4, which breaks both (a) and (b). Recorded as a known, accepted discrepancy — **not a defect to chase.**

### Sight lines are preserved exactly, by construction

The eye scales about the datum by the same K as the cockpit:

```
measured eye (datum) = (−0.562, 1.086, −1.030)
÷ K                  = (−0.300,  0.580, −0.550)
seat + EYE_OFFSET    = (−0.300,  0.580, −0.550)   exact
```

Every vector from the eye to every skin part is therefore `K ×` the original, so **every angle is unchanged**. `COCKPIT_PITCH_DEG` is an angle and was left alone. Verified live: the eye is still enclosed by `Fuselage04`/`Fuselage05`, and `WingLeft`/`WingCentre` still do not block it.

⚠️ §41's published figures (panel +4.5..−32.2°, yoke −11.8..−31.1°, cowl +12.4°) were **not reproduced numerically** — the part subjects, and whether the 13° gaze tilt is folded in, are not recorded, so the convention could not be matched. The invariance argument above is stronger than a re-measurement would have been, but those specific numbers remain unconfirmed.

### Five assertions were pinned to life size and are now derived

None of these were code faults. All five stated an output instead of the reasoning behind it.

| where | was | now |
|---|---|---|
| `Cessna172` envelope | `11.00 / 2.72 / 8.28`, tol 0.01 | `published * AIRCRAFT_SCALE`, tolerance scaled |
| `Cessna172` contact plane | `−1.15` | `−1.15 * AIRCRAFT_SCALE` |
| `AircraftBuilder` dimensions | flat ranges | ranges `* VISUAL_SCALE` |
| `FlightModel` wing mirror | flat 1 mm | derived from the seat's mass × offset |
| `GroundHandling` / `FlightController` rigs | `GROUND_Y = 1.30` | derived: root − (wheel offset − radius) |

⚠️ **`GROUND_Y = 1.30` was the expensive one.** It hung the aeroplane a metre above the test pad, so every wheel reported airborne and **sixteen GroundHandling checks plus one FlightController check silently measured nothing** rather than failing one. A rig constant that encodes geometry must be derived from the definition, or it dies quietly the next time the geometry moves.

⚠️ `CameraController`'s "the cabin encloses the eye" is **the fifth time the assertion rather than the code was wrong** here. The eye now sits at datum y 1.086 while the unscaled `Cabin` box tops out at 0.90, so the structural box genuinely no longer encloses it — and nothing is lost, because `Cabin` is invisible anyway and the skin panels that *are* seen are hidden correctly. The check now accepts the box **or** the `Fuselage%d` panels over it.

### Camera lengths that had to follow the airframe

`CHASE_DISTANCE` 18 → 33.7, `CHASE_HEIGHT` 5.5 → 10.3, `CHASE_LOOK_AHEAD` 6 → 11.2, `FREE_MIN_ZOOM` 8 → 15.0. An 18 m standoff around a 20.6 m span is a close-up of the cabin.

`AIRCRAFT_VISUAL_SCALE` is **duplicated** in `CameraController` rather than imported — §6h forbids the camera depending on one aircraft definition — and `runTests()` asserts the two agree, so they cannot drift silently.

### ⚠️ Ground handling is where this leaves the real aeroplane, and it cannot be tuned back

| | real 172 | now |
|---|---|---|
| wheelbase | 1.80 m | **3.37 m** |
| taxi turn radius | ~10.2 m | **19.1 m** |

An aeroplane drawn 87% larger needs 87% more taxiway to turn in; any other answer has the visible wheels sliding sideways across the pavement. **This is the one §4 figure that could not be brought back to its published value.**

Both assertions now pin the *ratio* against the scale, so they still assert a 172's proportions and would still catch §12's 207 m bug.


### 🐛 The aeroplane fell through the map — `SPAWN_HEIGHT` was a fourth hardcoded 1.30

Reported by the pilot immediately after §45 landed. **`AircraftService.SPAWN_HEIGHT = 1.30`** was the same life-size constant already fixed in the `GroundHandling` and `FlightController` test rigs — and it was missed because it is the only copy on the **live spawn path** rather than in a suite.

With the gear scaled, the tyres hang **2.303 m** below the root, so a root placed 1.30 m up left every wheel **1.0 m underneath the apron**. Its own comment had already predicted the outcome:

> *"spawning lower means Roblox resolves the interpenetration by launching it"*

⚠️ **ALL 799 CHECKS PASSED WHILE THE GAME WAS BROKEN.** The suites derive their own ground height and never call `slotCFrame()`, so nothing tested the number the game actually spawns with. A geometry constant on a live path needs a test that exercises *that* path, not an equivalent one beside it.

Fixed by deriving it, like the rigs: `gearHeightOf(definition)` = root y − (lowest wheel offset − radius). It takes the **lowest** wheel, not the first, so a taildragger is right too.

Verified live: root spawns 2.303 m above the apron, wheel bottoms at **+0.000 m** vs the surface, and after 3 s it has drifted **0.5 mm** at zero velocity.

### 🐛 `SPAWN_SPACING` was broken the same way, and had not been hit yet

18 m, reasoned from the 11.0 m span. The drawn span is 20.59 m, so parked aircraft **overlapped by 2.6 m** — the explosive case its own comment describes, waiting for a second player to spawn. Now `spanOf(definition) * 18/11`, preserving the original wingtip clearance proportion. 33.7 m today.

⚠️ Both are taken from the **default** definition, because `slotIsClear()` has to ask whether a patch of apron is free *before* it knows what will park there. Faithful while the 172 is the only aircraft; when a second arrives with different gear or span, these become properties the **slot** carries and the grid is sized to the largest. Flagged, not pre-built.

### It does NOT phase through terrain — that was a measurement error

Chased on the same report and worth recording so it is not re-chased. An aircraft dropped on bare terrain appeared to sink 0.86 m, and a life-size-gear control variant appeared to sink 0.88 m — which looked like a pre-existing collision fault.

**It was neither.** Measuring the terrain **directly beneath the aircraft** instead of at the drop point shows the height holding at **+2.303 m — exactly the rest height — for six seconds**, with a vertical velocity of 0.03 m/s against 4.38 m/s horizontal.

The aeroplane was **rolling downhill**. Wheel friction is 0 by §6f (`GroundHandling` models grip itself), there is no parking brake, and the terrain has 18 m of relief — so a 172 left on a slope rolls, which is correct. The "sink" was the terrain at the original probe point being higher than the ground it had rolled 14 m down to.

⚠️ **Measure the clearance under the object, not against where it started.** Ground contact on sloping terrain cannot be judged from a fixed reference height.
### ✅ The scale is signed off (2026-08-07)

**Pilot:** *"sizing is fine, we can keep this scale."* K = 1.8720 is **accepted and settled** — it is no longer an open question, and the ratio discrepancies in (c) and (d) above are accepted with it. Do not re-litigate the factor; if a future change needs the aeroplane at a different size, that is a new decision with a new section.

### ⚠️ NOT DONE: the flight gates have not been re-flown

§9/§14 (taxi, takeoff, circuit, landing) **require a pilot** and are flown, not written. Everything above is static verification. The resized airframe is **unflown**, and the first taxi is where the 19.1 m turn radius and the enlarged ground clearance will actually be judged.

### ⚠️ KNOCK-ON, recorded and NOT fixed here

The 20.59 m span is **0.90× the 23 m runway** — the aeroplane is nearly as wide as the pavement it lands on, and the 15 m taxiway is now **narrower than the aircraft**. Runway, taxiway and apron very likely need widening to keep the landing and taxi feel.

**Airport design is feature work per §44 and is a separate task.** Logged in `NEXT_PROMPT.txt`. Do not fix it as part of this change.

---

## 46. The flight tablet (2026-08-09, Phase 4b built)

**881/881 across 22 suites** (was 799; +82 new checks). `InputController` 110 → 121, `AirportService` 98 → 109, `AircraftService` 35 → 54, plus two new suites: `Tablet` 32 and `TabletController` 9 (aggregate 41). Three stale rows in §4's table were corrected by measurement at the same time.

### The decision, which was the whole reason this needed asking

§14 said the tablet needed "either a modal state that releases the yoke, or to be usable only on the ground", and to decide before building. **The pilot chose neither:**

> **On the ground, or with altitude hold engaged.**

That is a better answer than either option offered, and the reason is §28. While the mode on R is engaged, `InputController.update()` already **ignores the cursor entirely** — `rawPitch` and `rawRoll` are zeroed — and the augmentation holds the wings, the heading and the altitude. So in that state the pilot's hands are off the controls *by construction*. A clickable panel takes nothing from them, and there is no new modal state, no new hand-off, and nothing to tune. The only mode in this project that flies the aeroplane for you is exactly the mode in which a cursor is free to be a cursor.

On the ground the argument is simpler: a parked aeroplane does not care where the elevator is. And "not flying at all" — standing on the apron, or after bending one — is allowed too, which is what the tablet is mostly for.

The rule is one pure function, `InputController.tabletMayOpen(flying, onGround, altitudeHold)`, asserted in all four states. **The single `false` in that table is the whole safety property: nothing clickable can ever appear while the cursor is the yoke.**

### ⚠️ The gate is a CONDITION, not an event, and that closes a real hole

Checking it only on open is not enough, and this is not defensive programming — it is a reachable way to hurt the pilot:

> Open the tablet during the take-off roll. Legal: the wheels are down. Now do nothing. The throttle is a lever and **holds its setting** with the keys neutral, so the aeroplane keeps accelerating, rotates on trim, and is airborne and hand-flying with the yoke released and a clickable panel over the windscreen.

So `TabletController` re-evaluates the gate on **Heartbeat**, and the moment it stops being true the tablet closes itself and says why. Three boolean reads a frame. **Verified live**: opened seated on the ground, the aeroplane was lifted, and the panel was shut within 0.3 s with the message on screen.

### What was built

| Piece | Where | Does |
|---|---|---|
| `Tablet` | `UI/Tablet/Tablet.luau` | The panel and every pure decision — default selection, the swap rule, the plan lookup, the exact rows a pilot reads |
| `TabletController` | `Controllers/TabletController.luau` | The key, the gate, the round trips, the lifecycle |
| `tabletSnapshot()` | `AirportService` | The registry and every flight plan, as one payload |
| `evaluateFlightRequest()` | `AircraftService` | Validates a flight plan from an untrusted client |
| `tabletMayOpen()` | `InputController` | The pilot's rule, as a pure function |

**M opens it.** M was free precisely because §6g's absolute yoke retired `MouseModeToggle`, and it is a long way from the left-hand flight cluster — which matters for a key that hands the controls over. It is read off `InputBegan` by the controller, **not** by `update()`: the third action wired that way after `ResetAircraft` and `ToggleHud`, and for the same reason every time — `update()` only runs while an aircraft is being flown, and the point of this key is planning a flight with no aeroplane at all. It is also the *only* way the closing press can work, because an open tablet is feeding `update()` a snapshot with no keys in it.

**The Controls contract is untouched.** `tabletOpen` is `state.systems`, in the style §6c pins by test. It is the odd one out in that table and the file says so: it is an *input* to `update()` rather than a decision `update()` made, because the tablet has to work with no aircraft.

### The arrow between the two controllers points one way

`TabletController` requires `FlightController` — for the aircraft, the systems and whether the wheels are down. So `FlightController` must not require it back. The tablet **pushes** its state in through `setTabletOpen()`, and `FlightController` knows nothing about the tablet beyond one boolean. It then sends `neutralSnapshot()` while the tablet is up — the identical path §6g built for typing, so trim is kept and **a trimmed aeroplane flies on hands-off while the pilot plans.** A new reader, `isOnGround()`, reports the **gear's own telemetry** rather than comparing altitude against a field elevation: an aeroplane 0.4 m above the runway on its way down is not on the ground, and one on the grass a hundred metres off the strip is.

### Navigation is presented, never recomputed

`AirportService.tabletSnapshot()` sends the airports **and every ordered pair's `flightPlan()`**, so the tablet's answer to "how far and which way" is that module's own arithmetic rather than a second copy that can drift. `Tablet.planFor()` is a **lookup**. There is deliberately no heading arithmetic on the client at all.

- **No aircraft in the payload.** `Aircraft/Registry.luau` is in ReplicatedStorage, so the aircraft picker costs no network — and a second source of truth was not invented for something both sides can already see.
- **The plan matrix is N².** Two fields, two plans. At ~20 airports this should become a per-pair request; the seam is that one function and nothing downstream would know.
- **The snapshot is fetched at STARTUP, not on first open.** Found by looking at the built panel rather than by reasoning: opened cold, the two airport columns were empty while the round trip completed, while the aircraft column was already full because it needs no network.

### 🐛 Three bugs, and only one of them was findable by testing

**1. The fixture disagreed with the aeroplane.** The obvious departure runway for Meadow → Ridge is Meadow's default, 36. The live answer is **18**: `bestRunwayFor()` picks the runway pointing most nearly at the destination, and Ridge is 200 m *south* as well as 1,600 m east. A fixture written from the guess passed while describing a different flight from the one the pilot was given. It is now read off a live `RequestAirportList`.

**2. ⚠️ Starting a flight from a field you were not standing at left the pilot behind.** Everything measured correct — the plan, the validation, the aeroplane parked exactly on Ridge's slot — and the feature was still broken. The pilot stayed on Meadow's apron **1.6 km away**, and because **streaming is on**, their client held the model's shell with **0 of its 128 parts**: from the apron, indistinguishable from the spawn having failed in silence. *No unit test in this project could have found that.* Starting a flight now brings the pilot with it, `RequestStreamAroundAsync` first.

**3. ⚠️ And the first fix buried them 2.3 m inside the hillside.** The standing height was measured by raycasting down from the character's root through `groundHeightAt` — which excludes the `Aircraft` folder **and nothing else**. The ray starts at `root + 1 m`, exactly the top of the R6 torso, and hit the pilot's **own head** at 253.25 rather than the apron at 250.00. Standing height: **−2.3 m**. The pilot was placed inside Ridge's terrain, fell through the world, died, and respawned at Meadow — taking their aeroplane with them (§7: dying requests a new one). It is derived from `Model:GetBoundingBox()` now, which cannot make that mistake and survives the next change to the rig, as §34 and §36 both already were.

A fourth was caught by the suite and is worth one line, because it is §7's cross-product lesson from the other direction: the pilot stands off the aeroplane's **left**, and facing east, left is **north** — so the offset *reduces* Z. The assertion was first written as `+` and failed on correct code.

### Verified live, not only in tests

Real keypresses, the real bootstrap, the real remotes:

- The tablet builds **disabled**, so a closed tablet absorbs no cursor travel at all.
- Both airport columns and the aircraft column populate at startup; the summary reads `Meadow Field 18 -> Ridge Strip 09`, `0.87 nm (1.61 km)`, `097 T (back 277 T)`, `+150 m`, `705 m` — identical to what the pure suite asserts.
- `StartFlight` Ridge → Meadow: the aeroplane parked on Ridge's slot **and the pilot standing beside it**, stable, all 128 parts streamed.
- **M seated on the ground → opens. Aeroplane lifted → shuts itself within 0.3 s with the reason on screen. R engaged at altitude → opens again.** All four refusal messages come back readable from the server.

### Not built, and deliberately

- **No live "distance to run" from the aircraft's own position.** §14 asks for the field-to-field figures and that is what is presented. A live readout needs a heading on the client, which would be a second implementation of `headingOf` — exactly the thing this section was careful to avoid. §14 already homes the moving map in **Phase 8**, on this same snapshot.
- **`FlightEvent` is still unwired.** Milestones — airborne, waypoint, landed — are its own task; the tablet starts a flight, it does not yet follow one.

### How to test it

```lua
-- Client datamodel, in Play
require(game.StarterPlayer.StarterPlayerScripts.FlightSim.Controllers.TabletController).runTests()  -- 41
require(game.StarterPlayer.StarterPlayerScripts.FlightSim.Controls.InputController).runTests()      -- 121
-- Server datamodel, in Play
require(game.ServerScriptService.FlightSim.Services.AirportService).runTests()                       -- 109
require(game.ServerScriptService.FlightSim.Services.AircraftService).runTests()                      -- 54
```

And by hand, which is the part that matters:

1. **On the apron, before boarding, press M.** It opens. Pick Ridge as departure, Meadow as destination, and press START FLIGHT — you should be standing beside a 172 at Ridge, 150 m higher and 1.6 km east.
2. **Board, and press M on the ground.** It opens.
3. **Take off, and press M.** It refuses, and says to land or engage altitude hold.
4. **Open it during the take-off roll and let the aeroplane fly itself off.** It must close itself the instant the wheels leave.
5. **At altitude, press R, then M.** It opens, and the autopilot keeps flying while you pick a destination.

---

## 47. Phase 4c — the 172S systems (2026-08-09, six of eight items built)

**991/991 across 24 suites** (was 881; +110 new checks). `Engine` 24 → 57, `SurfaceAnimation` 24 → 33, `InputController` 121 → 155, `AircraftBuilder` 25 → 28, `UIController` 181 → 191, plus two new suites: `Electrical` 21 and `BindsPanel` 10.

✅ **FLOWN AND PASSED, 2026-08-09.** The pilot started on a mag check, took off on BOTH, trimmed the rudder hands-off in the climb, and stopped the engine with the mixture. **Phase 4c is signed off.**

⚠️ **BUT ITEMS 6, 7 AND 8 WERE SIGNED OFF ON THEIR MODEL, NOT THEIR DISPLAY.** The gauges are not drawn and the lights do not light, so *none of those three was flown* — there was nothing to look at. The sign-off covers the systems behind them. Their visual half is the next task, at the pilot's request, before Phase 5.

### What is built, and what is honestly not

| # | Item | State |
|---|---|---|
| 1 | **Rudder trim tab** | ✅ Built. Tab, channel, keys, wiring, compound-motion test on a real model. |
| 2 | **Fuel selector** | ✅ Built. Two tanks, OFF/LEFT/BOTH/RIGHT, line fuel, starvation. |
| 3 | **Mixture** | ✅ Built. Leaning, the power/fuel trade, idle cutoff. |
| 4 | **Magnetos / keyed ignition** | ✅ Built. OFF-R-L-BOTH, held starter, mag check against POH limits. |
| 5 | **Master / avionics / electrical** | ✅ Built. New `Electrical` module: BAT/ALT/avionics, bus, ammeter, breakers, battery drain. |
| 6 | **Engine gauges** | 🟨 **Half.** Oil pressure, oil temperature and fuel flow are **modelled** and asserted in the POH's bands. **They are not drawn** — no `SixPack` dials yet. |
| 7 | **Cabin environment** | 🟨 **Half.** Heat, vent, defrost and pitot heat hold state and draw current. **No 3D part mirrors them.** |
| 8 | **Lights that switch** | 🟨 **Half.** Beacon, NAV, strobe, taxi and landing hold state and load the bus. **The parts do not illuminate yet.** |
| — | **Binds reference** | ✅ Built. K, read-only, from the live bindings table. |

The three halves are all the same missing piece: **the visual layer**. The state, the electrical dependency and the tests exist; what does not is the code that turns a `systems.lights.landing = true` into a part that glows and a needle that moves. That is the next task and it is small — it is a consumer of what is already here, not a redesign.

### The constraint that shaped everything: the Controls contract

⚠️ **Twenty-two new switches, and not one of them is a Controls field.** §6c pins the six-field contract with tests in three suites, and §14 made it non-negotiable for this phase. Everything here is `state.systems`, in the style the engine toggle already used, and a test drives *all twenty-three new keys for sixty frames* and asserts that Controls gained no field and no flight control moved.

The physics reads these through the modules that own them — `Engine` for the valve, the knob and the key, `Electrical` for the bus — never through the control contract.

### 🔎 The brief's premise about the fuel split was wrong, and measuring it is the finding

The task said: *"Re-verify §4 (153 kg tank is one lump; two tanks move CoM)."*

**Measured, two tanks move nothing at all.** The fuel is *already* in the definition's mass boxes:

```
{ name = "WingLeft",  mass = 110 },  -- "structure plus the fuel it carries"
{ name = "WingRight", mass = 110 },
```

Those are **static**. They do not change as fuel burns, they are already symmetric, and `Engine.fuelKg` has never been a mass in the model — it is bookkeeping the engine drinks from. Splitting it into `fuelLeftKg` and `fuelRightKg` therefore moves no mass whatsoever, and **§4 stands unchanged — verified by a test that reads the two wing masses out of the definition, not assumed.**

⚠️ **This is a finding, not a shortcut, and it leaves a real decision open.** `Engine.fuelImbalanceKg()` reports the imbalance, and today it is a *number on a gauge* rather than a wing that wants to drop. Making it produce a genuine rolling moment means making the wing boxes **vary with tank contents** — a change to the mass model, and therefore a **§4 decision for the pilot**, with Roblox `CustomPhysicalProperties` being rewritten as fuel burns. It is deliberately not done here.

### How each system is modelled, and against what

Every figure is a published Lycoming IO-360-L2A or Cessna 172S number, or is derived from one and says so.

- **Mag check.** The POH allows *no more than 150 RPM drop on either magneto, and no more than 50 RPM between them*, at 1,800 RPM. `SINGLE_MAG_POWER_FACTOR` is **derived from that limit**, not chosen for feel, and the factor reaches the **RPM as well as the power** — because the drop is something the pilot *reads on the tachometer*, and a magneto that changed power without changing RPM would be a system with no instrument. Both magnetos carry the same factor deliberately, so the differential is exactly zero: **a differential is a fault, and this engine is not faulty.** When Phase 6's damage model arrives, an unhealthy magneto is one number.
- **Mixture.** The correct mixture *is* the density ratio — that is the whole physical content of leaning, and it is why full rich at 8,000 ft is 27% too much fuel. Power is unaffected rich of correct (deliberately: full rich at sea level is the reference condition §4 was verified in, and modelling the real 2–3% loss would silently re-tune the whole aeroplane). Lean of correct it falls away, reaching zero *at* the cutoff so the engine quits without a step. **Fuel flow scales with the lean ratio and power does not** — that asymmetry is the entire reason leaning is worth doing, and the test asserts it as an inequality rather than a number.
- **Fuel.** BOTH draws evenly and makes up a shortfall from either side, which is *why it is the position you take off and land on*. LEFT and RIGHT draw from one tank only, so an empty selected tank starves the engine **with the other one full** — the classic mismanagement accident — and a paired test shows BOTH surviving the identical starting state.
- **⚠️ OFF does not stop it instantly**, and there is **no published figure** for how long it runs: the POH does not certify flight with the fuel off. So `lineFuelKg` is stated as a *mechanism* with a plausible volume (~70 ml, about six seconds at cruise burn) and the test asserts the resulting time is in the handful-of-seconds band a real one gives — **not a POH number dressed up as one.**
- **Electrical.** 28-volt system, 24-volt battery, 60-amp alternator, 13 Ah battery — all published. The ammeter shows the **rate of charge**, not the system load, which is why it swings positive after a start and settles toward zero. **The alternator cannot self-excite with the battery master off**, because its field comes off the bus — a real property of the aeroplane and the reason the checklist turns BAT on before ALT.
- **Oil.** Pressure tracks RPM (zero stopped, the POH's 25 psi minimum at idle, mid-green at cruise) and **cold oil reads higher because it is thicker** — the needle near the top of the green on a cold start, settling as it warms. Temperature starts at ambient and takes minutes, which is why a run-up is not the first thing you do after a start.

### 🐛 Three bugs the suites caught on code that looked right

**1. The rudder trim tab followed the rudder instead of opposing it.** Built with `sign = +1`, matching the rudder's default — and a tab that follows the surface it trims is an **anti-servo tab off a different aeroplane**. This is §37's lesson arriving on the other axis: the opposition lives entirely in the two signs, and the elevator pair reads −1/+1 only because the elevator *declares* −1. The rudder takes the default, so its tab must be the mirror: **+1/−1**.

**2. The tab hung past the trailing edge and grew the aeroplane.** It measured **15.755 m against §45's 15.500 m target** — and the published-length check found it on the first run. The 172S's 8.28 m is measured to the rearmost point, which on the real aeroplane is the *rudder*, because the real tab is **inset into the trailing edge**. Moved so its aft face is exactly flush at z 5.184; envelope restored, `Cessna172` still 33/33.

**3. The mixture curve disagreed with its own comment.** The note claimed 0.95 of power at best economy; a plain square gave **0.87**, a far harsher penalty than leaning really costs. The exponent is now **derived from the figure it has to hit** — `shortfall^2.5`, from `ln(0.05)/ln(0.3077)` — rather than picked. The comment was right and the arithmetic was wrong, which is the useful direction for that disagreement to be found in.

A fourth was caught in the electrical suite and is worth a line, because the test was the broken thing: it tried to trip a breaker by inflating `LOADS.beacon`, and the breaker limit is **derived from `LOADS`** — so the limit rose with the fault and nothing ever tripped. **Testing a threshold by changing the thing the threshold is computed from proves nothing.** `update()` now takes an explicit `faultAmps`, which is also the seam Phase 6's damage model drives. A fifth: the bus voltage was computed *before* the battery drained, so a battery measured at 0.00 Ah reported a live 20.4 V bus.

### The keyed start needed one line, and it was nearly missed

`engineCommanded` is E's latch, and the branch below it stops the engine whenever it is false. So a pilot who started with the **Y** starter would have had the engine stopped **one frame after it caught**, the instant they released the key. Cranking now *sets* the commanded state — the two controls must agree afterwards or they fight. Both ways in are kept deliberately: **E** is the one-key start that every existing test and pilot habit depends on, **Y** is the keyed start the run-up procedure needs.

### The binds reference (K)

Nineteen bindings were memorable. **Forty-two are not**, and a control the pilot cannot find is a control that is not there.

⚠️ **It is built from `InputController.DEFAULT_BINDINGS`, not from a copy.** A second hand-written list is a list that goes stale, and *a controls reference that lies is worse than none at all* — the pilot trusts it and concludes the feature is broken. `rows()` walks the live table, so a rebind appears with no edit, and tests assert every binding appears **exactly once**, **with the key actually bound**, and that the list **contains its own toggle key** (it is drawn over the windscreen; guessing your way out happens in flight).

An action nobody has filed into a section still appears, under **Other** — the failure mode of a hand-maintained grouping is a binding that silently vanishes, and that fallback makes it impossible.

**It absorbs nothing**, and that is counted rather than trusted: a test walks the built panel for any `GuiButton` or `Active` element and requires zero. That is what makes it safe to show mid-flight, which is exactly when it is needed. §7's rule, satisfied by construction.

**Verified live and looked at** (§17: arithmetic cannot verify a rendering). A real K press opens it: 94 labels, **0 interactive**, all forty-two bindings drawn in two ordered columns. The screenshot showed the punctuation keys correctly — confirmed by reading the label bytes (44 = `,`, 46 = `.`) rather than squinting at 13-pixel glyphs.

### Key map, for reference

| Group | Keys |
|---|---|
| Rudder trim | `,` `.` |
| Mixture | `Q` rich, `Z` lean (**Z can stop the engine** — idle cutoff is how a 172 shuts down) |
| Fuel selector | `[` toward OFF, `]` toward RIGHT — **clamped, never wrapping** |
| Magnetos | `-` toward OFF, `=` toward BOTH |
| Starter | `Y`, **held** (the real key is spring-loaded) |
| Electrical | `1` BAT, `2` ALT, `3` avionics, `4` breaker reset |
| Lights | `5` beacon, `6` NAV, `7` strobe, `8` taxi, `9` landing |
| Cabin | `I` heat, `O` vent, `0` defrost, `` ` `` pitot heat |
| Binds list | `K` |

### How to test it

```lua
-- Client datamodel, in Play
require(game.ReplicatedStorage.FlightSim.Physics.Engine).runTests()          -- 57
require(game.ReplicatedStorage.FlightSim.Physics.Electrical).runTests()      -- 21
require(game.ReplicatedStorage.FlightSim.Aircraft.SurfaceAnimation).runTests() -- 33
require(game.StarterPlayer.StarterPlayerScripts.FlightSim.Controls.InputController).runTests() -- 155
require(game.StarterPlayer.StarterPlayerScripts.FlightSim.Controllers.UIController).runTests() -- 191
```

**The gate, unchanged from §14** — a pilot re-flies with real systems:

1. **Start on a mag check.** Mixture rich (`Q`), BAT/ALT on, fuel on BOTH, hold `Y` to crank. Run up to ~1,800, step `-` to L and read the drop, `=` back to BOTH, `-` `-` to R, read it, back to BOTH. Both drops inside 150 RPM.
2. **BOTH for takeoff**, then fly an hour on `[` LEFT and watch the imbalance appear on the gauge.
3. **Trim hands-off in the climb** — pitch on `U`/`J`, rudder on `,`/`.`.
4. **Pull `Z` to idle cutoff** and confirm the engine stops, then that only the mixture and the mags can do that.
5. Turn `1` BAT off in flight and confirm the ammeter dies.

⚠️ **Items 6, 7 and 8 cannot be flown yet** — the gauges are not drawn and the lights do not light. Do those before the gate, or gate items 1–5 alone.

---

## 47b. Phase 4c signed off, and the visual half built (2026-08-09)

**1,004/1,004 across 24 suites** (was 991). `SurfaceAnimation` 33 → 41, `SixPack` 53 → 58, `UIController` 191 → 196.

### The gate

✅ **Flown and passed, 2026-08-09.** The pilot started on a mag check, took off on BOTH, trimmed the rudder hands-off in the climb, and stopped the engine with the mixture. **Phase 4c is signed off.**

⚠️ **Items 6, 7 and 8 were signed off on their MODEL, not their display** — at the time of the gate the gauges were not drawn and the lights did not light, so there was nothing to look at. The pilot then asked for the visual half before Phase 5, and that is what this section records. **The gauges and the lights have not themselves been flown.**

### Item 6 — the engine cluster

Oil pressure, oil temperature and fuel flow, as three more `Instrument` specs. No new gauge code: §17's framework took them as data, which is what it was built for.

⚠️ **THEY ARE A SEPARATE CLUSTER, NOT A THIRD ROW ON THE PANEL**, and that is a constraint rather than a preference. The main panel is 4 × 2 and **its frame's aspect ratio is asserted against the cockpit's `PanelBoard` part to 1%** — a SurfaceGui maps a fixed-pixel frame onto a face, so a mismatch renders every circular dial as an oval and nothing errors (§19). A third row would change that aspect and force the board from 0.47 m to 0.72 m tall: **a 3D modelling detour, which §44 forbids outright while the project is in graybox.** It is also what a real 172 looks like — the engine instruments are their own cluster beside the flight panel.

**Every band is `Engine`'s own constant by identity, not retyped** — the same arrangement §19 uses for the tachometer's redline, and for the same reason: a gauge whose green arc disagrees with the engine driving it is worse than no gauge. Oil pressure carries a **red band below 25 psi** as well as the POH's 50–90 green, because that reading is the one that means land now. Oil temperature is marked in **Celsius**, converting the published 245 °F red line once rather than carrying two scales. Fuel flow reads **kg/h** for the same honesty the fuel gauge has (§19): the physics burns kilograms, so inventing a fuel density to print gallons would be making up a number the definition does not have.

`FlightModel.telemetry` publishes five new fields — the three gauge values plus both tank quantities, so an imbalance the pilot created is visible.

### Item 8 — lights that actually switch

⚠️ **GATED ON THE ELECTRICAL BUS, NOT ON THE SWITCH.** A landing light switched on with the battery master off does nothing at all. That is the whole reason item 8 waited for item 5, and it is what makes a master switch mean something rather than being a boolean with a lamp behind it.

- **Red to port, green to starboard** — the convention that tells you which way an aircraft is pointing at night, and the classic thing to get backwards. Read off the `LIGHTS` table by the test rather than restated.
- **The strobe flashes**, ~1 Hz on an 8% duty cycle. Asserted **across a whole cycle**, because a duty cycle sampled at one instant proves nothing — it would pass on a lamp that was always on *and* one that was always off.
- **A `PointLight` as well as the Neon material.** Neon makes a part *look* bright without lighting anything around it, and a landing light that puts no light on the runway is a decoration — the runway is the entire reason it exists.
- Two tests guard the wiring: **every switch drives a part the aeroplane actually has**, and **no lamp is driven by two switches** (they would fight over its colour every frame, and table iteration order is undefined).

**Four lamp parts did not exist and were added**: `StrobeLeft/Right`, `TailLight`, `TaxiLight`. ⚠️ **The strobes are placed INBOARD of the nav lights, at x 5.38 against their 5.45, so the span cannot grow** — §45 pins the aeroplane at 20.592 m and the rudder trim tab had already grown the *length* earlier in this same phase by hanging off the trailing edge. `Cessna172` is still 33/33.

### ⚠️ Number keys 1–9 are Roblox CoreGUI hotbar slots

Found when Studio's virtual input refused to send `1`: *"key is permanently bound to a CoreGUI core action"*.

**The simulator reads them anyway.** `InputController.poll` uses `UserInputService:IsKeyDown`, which is raw key state and is **not** filtered by `gameProcessed` — verified by switching the nav, taxi and landing lights with real 6/8/9 presses on a seated pilot. So the electrical and light bindings work today.

But a player carrying a `Tool` would *also* be equipping it on those presses. **There is no backpack in this game, so it is harmless now** — and if one ever appears, the eight number-key bindings are the ones that have to move.

### Verified live

Real keypresses on a seated pilot, in a real Play session: all eight lamp parts bound with a `PointLight` each; `6` lit the navigation lights **red on the left, green on the right**; `8` and `9` lit the taxi and landing lights; the strobe stayed dark because `7` was not pressed. The bus-gating path is covered by unit tests rather than live, because the master-switch keys are the two Studio's virtual input cannot send.

### What is left

Nothing in Phase 4c. **Item 7's cabin switches hold state and draw current but still have no 3D part to mirror** — the cabin heat, vent and defrost controls are pedestal knobs the graybox does not model, and §44 parks that until the 3D pass. It is recorded here rather than left implied.

**Next: Phase 5 — weather.** Wind layers, Dryden/Von Kármán turbulence, the wind-shear gate, temperature and QNH presets, and the jet last.
