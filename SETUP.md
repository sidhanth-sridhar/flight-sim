# Setup Guide — VS Code + Roblox Studio workflow

How to get this project onto a machine, open it in VS Code, connect Roblox Studio,
and keep the work backed up with git. Read HANDOFF.md first for project context.

---

## 1. What you need installed

| Tool | Purpose | Get it from |
|---|---|---|
| Git | version control / getting the code | git-scm.com |
| VS Code | editing the Luau source | code.visualstudio.com |
| Roblox Studio | running tests and flying | create.roblox.com (via Roblox app) |
| Rojo plugin | connects Studio to the Rojo server | Studio plugin marketplace, search "Rojo" |
| Aftman | installs `rojo` CLI from `aftman.toml` | aftman.github.io (single .exe) |

After installing Aftman, run once in the project folder to install the pinned
`rojo 7.7.0`:

```powershell
aftman install
```

(On a machine where you've already cloned before, skip this — it's already there.)

---

## 2. The mental model (read this once)

- **The files in `src/` are the source of truth.** Roblox Studio is a viewer/simulator,
  never the place you edit scripts.
- Rojo syncs **one way: files -> Studio**. Studio content is always deleted/replaced
  to match `src/`. Anything you build in Studio by hand is lost.
- The physics runs in the browser-free engine: you test by pressing Play in Studio.
- Git is how the code moves between machines. Studio and VS Code are never connected
  to each other directly — Rojo is the bridge.

---

## 3. Chronology — first time on a new machine

Do these in order. Do not skip ahead.

**Step 1 — Get the code onto this machine.**
```powershell
git clone https://github.com/sidhanth-sridhar/flight-sim.git
cd flight-sim
```

**Step 2 — Open the project in VS Code.**
```powershell
code .
```
Or File > Open Folder in VS Code. You should see `src/`, `default.project.json`,
`aftman.toml`, `HANDOFF.md`.

**Step 3 — Install the tools pinned in the repo.**
```powershell
aftman install
```

**Step 4 — Start the Rojo server.**
```powershell
rojo serve default.project.json
```
Leave this terminal window running. It serves the file tree to Studio. If `rojo` is
not on your PATH, use the full path Aftman created (shown by `aftman install`).

**Step 5 — Open Roblox Studio and connect.**
1. Open Studio -> open the project place (File > Open, pick the `.rbxlx`/`.rbxl` place,
   or New if the place lives purely in `src/`).
2. In Studio, open the **Plugins** tab -> click **Rojo**.
3. In the Rojo plugin panel, click **Connect** (it connects to `localhost:34872`).
4. When connected you'll see the served tree. The `FlightSim` folders appear in
   Studio Explorer as the server syncs.

**Step 6 — Sanity check the sync.**
You should see the three `FlightSim` folders (ReplicatedStorage, ServerScriptService,
StarterPlayerScripts) plus the Baseplate. If the plugin shows "connected" but nothing
appears, or a new folder you created is missing, see the Rojo troubleshooting in
HANDOFF.md §3 — the usual fix is disconnecting and reconnecting the plugin, then
deleting the stale folder in Studio so Rojo recreates it.

**Step 7 — Run the test suites.**
Per HANDOFF §4: run in **Play mode, Client datamodel** (the server has no
`UserInputService`, so `InputController` can't load there). Use Studio MCP or the
command bar:

```lua
require(game.ReplicatedStorage.FlightSim.Physics.Atmosphere).runTests()
require(game.ReplicatedStorage.FlightSim.Physics.Aerodynamics).runTests()
require(game.ReplicatedStorage.FlightSim.Physics.Engine).runTests()
require(game.ReplicatedStorage.FlightSim.Aircraft.Definitions.Cessna172).runTests()
require(game.ReplicatedStorage.FlightSim.Aircraft.AircraftBuilder).runTests()
require(game.ReplicatedStorage.FlightSim.Physics.FlightModel).runTests()
require(game.ReplicatedStorage.FlightSim.Physics.GroundHandling).runTests()
require(game.StarterPlayer.StarterPlayerScripts.FlightSim.Controls.InputController).runTests()
require(game.StarterPlayer.StarterPlayerScripts.FlightSim.Controllers.FlightController).runTests()
```

All nine should print ALL PASSED (251 checks). Then press Play and fly the gate:
taxi, take off, coordinated turn, deliberate stall, recover, land.

---

## 4. Pulling the latest code into VS Code

**If the repo is already on this machine** (it is, from now on):

```powershell
git pull
```

That fetches whatever was pushed to GitHub — from this machine or any other — and
merges it into your local folder. VS Code's Explorer shows the updated files
automatically; if it doesn't, File > Open Folder and pick the project.

**If the repo is NOT on this machine yet** (clone once, then it's as above forever):

```powershell
git clone https://github.com/sidhanth-sridhar/flight-sim.git
cd flight-sim
code .
```

**Rule: pull before you start editing, never after.** Editing first and then pulling
collides your local changes with the incoming ones, and git will make you resolve
conflicts by hand.

---

## 5. Chronology — every normal working session

1. `git pull` (get the latest before editing).
2. Start the Rojo server: `rojo serve default.project.json`.
2. Start the Rojo server: `rojo serve default.project.json`.
3. Open the project in VS Code and edit files in `src/`.
4. Open Studio -> Rojo plugin -> Connect (reconnect if the plugin went stale).
5. Run the suites + fly to verify your changes.
6. Commit and push (below).

---

## 6. Commit and push (after you finish working)

Run these in the project root:

```powershell
# 1. See what changed
git status

# 2. Stage everything you intend to commit
git add -A

# 3. Review what's staged before committing
git diff --cached --stat

# 4. Commit with a message describing the change
git commit -m "Describe what changed"

# 5. Push to GitHub
git push
```

Notes:
- `git add -A` stages new files too — this matters here, because `src/` has untracked
  folders (`Controls/`, `Controllers/`) that a plain `git commit` would silently leave
  behind and lose.
- Commit messages: short, past tense, one line — e.g. `Add InputController and
  FlightController` or `Fix altitude-hold disconnect`.
- Don't commit secrets or credentials. `.gitignore` already excludes `.vscode/`,
  `.rojo/` and lock files; keep anything sensitive out of `src/`.
- If `git push` rejects because the remote has commits you don't have, run
  `git pull --rebase` and push again.

---

## 7. Getting back to it on another machine

```powershell
git clone https://github.com/sidhanth-sridhar/flight-sim.git
cd flight-sim
aftman install
rojo serve default.project.json   # in one terminal
code .                             # then connect Studio as in §3
```

---

## 8. Common mistakes

- **Editing scripts inside Studio.** Rojo overwrites them on the next sync. Edit `src/`.
- **Forgetting to `git add -A`.** New folders are untracked; a plain commit drops them.
- **Running tests in Edit mode.** `require` caches per session, so you get stale copies.
  Use Play mode / Client datamodel (HANDOFF §4).
- **Having the repo inside a cloud-synced folder (e.g. OneDrive).** Git and cloud sync
  fight over the same files. Keep the working copy outside OneDrive.
- **Killing the `rojo serve` terminal.** The plugin then can't sync. Restart it and
  reconnect the plugin.
