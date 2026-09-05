// Starts a sidecar on a spare port, runs the scope checks against it, and
// stops only the process it started. Never touches a running GodOnChain: it
// binds its own port and publishes no discovery file.
import { spawn } from "child_process";
import { randomBytes } from "crypto";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const binary = join(here, "..", "bin", process.platform === "win32" ? "iq-sidecar.exe" : "iq-sidecar");
const port = 39300 + Math.floor(Math.random() * 200);
const token = randomBytes(16).toString("hex");

const child = spawn(binary, ["--port", String(port), "--token", token], { stdio: "ignore" });

const alive = async () => {
  for (let i = 0; i < 120; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${port}/health`, { signal: AbortSignal.timeout(1000) });
      if (r.ok) return true;
    } catch {}
    await new Promise((r) => setTimeout(r, 250));
  }
  return false;
};

if (!(await alive())) {
  console.error("the sidecar did not come up");
  child.kill();
  process.exit(1);
}

const suite = process.argv[2] ?? "readgate.mjs";
const run = spawn(process.execPath, [join(here, suite), String(port), token], { stdio: "inherit" });
run.on("exit", (code) => {
  child.kill();
  process.exit(code ?? 1);
});
