// Does the shared network setting actually get taken in turns?
//
// This is the one piece of new plumbing that can lose money silently: the SDK's
// active network is module state, and it decides which contract a write is
// signed against. If two EVM chains ever overlap, a Monad write can be sent to
// the Robinhood deployment or the reverse — a real transaction, a real fee, and
// nothing where the user expected it.
//
// Runs the real module in-process. No sidecar, no chain, no network.
//
// Run: node tests/evm-turns.mjs
import { createNetworkTurns } from "../evm_network.ts";

let pass = 0, fail = 0;
const check = (label, ok, detail = "") => {
  if (ok) { pass++; console.log("  PASS  " + label); }
  else { fail++; console.log("  FAIL  " + label + "  " + detail); }
};

const later = (ms = 0) => new Promise((r) => setTimeout(r, ms));

/** A turn-taker that records every switch and every overlap it allows. */
const harness = () => {
  const switches = [];
  let current = null;
  let inFlight = 0;
  const violations = [];
  const turns = createNetworkTurns((chain) => {
    if (inFlight > 0) violations.push(`switched to ${chain} with ${inFlight} still working`);
    current = chain;
    switches.push(chain);
  });
  const run = (chain, body) =>
    turns.run(chain, async () => {
      inFlight++;
      // Anyone running while the setting says another chain is the exact bug.
      if (current !== chain) violations.push(`${chain} ran while the setting said ${current}`);
      try {
        return await body();
      } finally {
        if (current !== chain) violations.push(`${chain} finished while the setting said ${current}`);
        inFlight--;
      }
    });
  return { turns, run, switches, violations };
};

console.log("\n--- two chains never overlap ---");
{
  const h = harness();
  const order = [];
  // Interleave aggressively: each body yields several times, which is where a
  // naive setNetwork-then-await would hand the global to somebody else.
  const work = (chain, id) => h.run(chain, async () => {
    for (let i = 0; i < 5; i++) await later(1);
    order.push(`${chain}${id}`);
  });
  await Promise.all([
    work("mon", 1), work("rh", 1), work("mon", 2), work("rh", 2), work("mon", 3),
  ]);
  check("nothing ran on the wrong network", h.violations.length === 0,
    h.violations.join("; "));
  check("  every request completed", order.length === 5, order.join(","));
  check("  and the setting was left free", h.turns.state().chain === null,
    JSON.stringify(h.turns.state()));
}

console.log("\n--- same-chain requests share a turn ---");
{
  // Serialising reads that agree about the chain would be a pointless cost, so
  // arrivals on the chain already held join it rather than queueing.
  const h = harness();
  let peak = 0, live = 0;
  const read = () => h.run("rh", async () => {
    live++; peak = Math.max(peak, live);
    await later(5);
    live--;
  });
  await Promise.all([read(), read(), read()]);
  check("three concurrent rh reads overlapped", peak === 3, `peak ${peak}`);
  check("  on a single turn", h.switches.length === 1, h.switches.join(","));
}

console.log("\n--- a busy chain cannot starve a quiet one ---");
{
  const h = harness();
  const done = [];
  const busy = () => h.run("mon", async () => { await later(2); done.push("mon"); });
  const first = busy();
  // The quiet chain asks once, then the busy one keeps arriving. Once somebody
  // is waiting, later same-chain arrivals must queue behind them.
  const quiet = h.run("rh", async () => { done.push("rh"); });
  const rest = [busy(), busy(), busy(), busy()];
  await Promise.all([first, quiet, ...rest]);
  const waited = done.indexOf("rh");
  check("the quiet chain was not made to wait for all of them",
    waited >= 0 && waited <= 2, `rh ran at position ${waited} of ${done.join(",")}`);
  check("  and nothing overlapped getting there", h.violations.length === 0,
    h.violations.join("; "));
}

console.log("\n--- a failed turn is still given up ---");
{
  // A write that throws mid-turn must release it. Holding it would deadlock
  // every later EVM request in the process — the sidecar would go quiet and
  // stay quiet until it was restarted.
  const h = harness();
  let threw = false;
  try {
    await h.run("mon", async () => { throw new Error("chain rejected it"); });
  } catch {
    threw = true;
  }
  check("the failure reached the caller", threw);
  check("  and the turn was released", h.turns.state().chain === null,
    JSON.stringify(h.turns.state()));

  let ran = false;
  await h.run("rh", async () => { ran = true; });
  check("  so the next request still runs", ran);
}

console.log(`\n${fail} failure(s), ${pass} passed`);
process.exit(fail === 0 ? 0 : 1);
