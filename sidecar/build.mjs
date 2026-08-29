/**
 * Builds the sidecar into a single self-contained executable that GodOnChain
 * ships inside its export and spawns at startup. No Node install on the
 * user's machine, no second repo to clone.
 *
 *   node build.mjs --bundle-only   # just the bundled .cjs (fast, for dev)
 *   node build.mjs                 # bundle + single executable
 *
 * Builds for the platform you run it on. Producing the Linux binary means
 * running this on Linux (or in CI); Node's SEA format can't cross-compile.
 */

import { build } from "esbuild";
import { execFileSync } from "child_process";
import { copyFileSync, mkdirSync, rmSync, writeFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const root = dirname(fileURLToPath(import.meta.url));
const buildDir = join(root, "build");
const outDir = join(root, "bin");

const isWindows = process.platform === "win32";
// Must match the name Godot looks for in iq_host.gd.
const exeName = isWindows ? "iq-sidecar.exe" : "iq-sidecar";
const bundlePath = join(buildDir, "sidecar.cjs");

rmSync(buildDir, { recursive: true, force: true });
mkdirSync(buildDir, { recursive: true });
mkdirSync(outDir, { recursive: true });

console.log("Bundling...");
await build({
  entryPoints: [join(root, "server.ts")],
  bundle: true,
  platform: "node",
  target: "node22",
  format: "cjs",
  outfile: bundlePath,
  minify: true,
  // Optional native accelerators for `ws`. They're behind try/catch upstream,
  // so leaving them unbundled just means the pure-JS path is used.
  external: ["bufferutil", "utf-8-validate"],
  logOverride: { "require-resolve-not-external": "silent" },
});
console.log(`  -> ${bundlePath}`);

if (process.argv.includes("--bundle-only")) {
  console.log("Bundle only; stopping here.");
  process.exit(0);
}

console.log("Preparing SEA blob...");
const seaConfig = join(buildDir, "sea-config.json");
writeFileSync(
  seaConfig,
  JSON.stringify(
    {
      main: bundlePath,
      output: join(buildDir, "sea-prep.blob"),
      disableExperimentalSEAWarning: true,
      // The bundle is CJS with no runtime require() of app files.
      useSnapshot: false,
      useCodeCache: true,
    },
    null,
    2,
  ),
);
execFileSync(process.execPath, ["--experimental-sea-config", seaConfig], {
  stdio: "inherit",
});

console.log("Copying Node runtime...");
const exePath = join(outDir, exeName);
rmSync(exePath, { force: true });
copyFileSync(process.execPath, exePath);

console.log("Injecting bundle...");
const postjectArgs = [
  exePath,
  "NODE_SEA_BLOB",
  join(buildDir, "sea-prep.blob"),
  "--sentinel-fuse",
  "NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2",
];
if (process.platform === "darwin") postjectArgs.push("--macho-segment-name", "NODE_SEA");

execFileSync(
  process.execPath,
  [join(root, "node_modules", "postject", "dist", "cli.js"), ...postjectArgs],
  { stdio: "inherit" },
);

console.log(`\nBuilt ${exePath}`);
console.log("Godot loads it from res://sidecar/bin/ and extracts it at startup.");
