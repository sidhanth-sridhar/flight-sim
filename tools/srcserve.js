/*
 * srcserve — read-only static server over src/, for Studio.
 *
 * Fallback for when Rojo's file watcher stops delivering changes (see
 * HANDOFF.md §3). Files remain the source of truth; this only lets Studio
 * pull them in on demand via HttpService:GetAsync.
 *
 *   node tools/srcserve.js
 *
 * Then from the Studio command bar:
 *   local src = game:GetService("HttpService"):GetAsync(
 *     "http://127.0.0.1:8791/ReplicatedStorage/FlightSim/Physics/FlightModel.luau")
 *   game.ReplicatedStorage.FlightSim.Physics.FlightModel.Source = src
 *
 * Serves nothing outside src/, binds to loopback only, and never writes.
 */
const http = require("http");
const fs = require("fs");
const path = require("path");

const ROOT = path.join(__dirname, "..", "src");
const PORT = 8791;

http
  .createServer((req, res) => {
    const rel = decodeURIComponent(req.url.split("?")[0]).replace(/^\/+/, "");
    const full = path.join(ROOT, rel);

    // Refuse anything that escapes the served root.
    if (!full.startsWith(ROOT)) {
      res.writeHead(403, { "Content-Type": "text/plain" }).end("forbidden");
      return;
    }
    fs.readFile(full, "utf8", (err, data) => {
      if (err) {
        res.writeHead(404, { "Content-Type": "text/plain" }).end("not found: " + rel);
        return;
      }
      res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" }).end(data);
    });
  })
  .listen(PORT, "127.0.0.1", () => {
    console.log("srcserve: " + ROOT + " -> http://127.0.0.1:" + PORT);
  });
