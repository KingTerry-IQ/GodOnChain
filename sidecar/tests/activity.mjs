// Does the sidecar record what apps ask it to do, and does the record say who
// asked? Every request here is answered or refused at the gate, so nothing
// reaches a chain.
const PORT = Number(process.argv[2]);
const CONTROL = process.argv[3];
const base = `http://127.0.0.1:${PORT}`;

let pass = 0, fail = 0;
const check = (label, ok, detail = "") => {
  if (ok) { pass++; console.log("  PASS  " + label); }
  else { fail++; console.log("  FAIL  " + label + "  " + detail); }
};

const call = (path, token, opts = {}) =>
  fetch(base + path, {
    ...opts,
    signal: AbortSignal.timeout(opts.patience ?? 8000),
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", ...(opts.headers || {}) },
  }).catch((e) => ({ status: e.name === "TimeoutError" ? 0 : -1, aborted: true }));

const activity = async (after = 0) =>
  (await (await call(`/control/activity?after=${after}`, CONTROL)).json()).activity;

const approvals = async () =>
  (await (await call("/control/approvals", CONTROL)).json()).approvals;

const answer = (id, allowed, remember) =>
  call(`/control/approvals/${id}`, CONTROL, {
    method: "POST",
    body: JSON.stringify({ decision: allowed ? "allow" : "deny", remember }),
  });

const waitForPrompt = async (action) => {
  for (let i = 0; i < 60; i++) {
    const found = (await approvals()).find((a) => a.action === action);
    if (found) return found;
    await new Promise((r) => setTimeout(r, 100));
  }
  return null;
};

const mint = async (label, scopes) =>
  (await (await call("/control/tokens", CONTROL, {
    method: "POST", body: JSON.stringify({ label, scopes }),
  })).json());

console.log("\n--- the sidecar keeps a record ---");

const start = (await activity()).length;
check("the log starts somewhere", Number.isInteger(start), String(start));

// A read that is refused.
const app = await mint("ledger-probe.pck");
const refused = call("/db/getTablelistFromRoot?dbRootId=probe&chain=sol", app.token);
const prompt = await waitForPrompt("listTables");
if (prompt) await answer(prompt.id, false, false);
await refused;

let seen = await activity(start);
check("a refused read is recorded", seen.length >= 1, String(seen.length));
const denial = seen.find((e) => e.action === "listTables");
check("  naming the app that asked", denial?.label === "ledger-probe.pck", denial?.label);
check("  under the read scope", denial?.scope === "read", denial?.scope);
check("  on the right chain", denial?.chain === "sol", denial?.chain);
check("  and marked as refused", denial?.outcome === "denied", denial?.outcome);
check("  with a subject naming what it wanted",
  String(denial?.subject) === "probe", denial?.subject);

console.log("\n--- a standing grant is the case worth seeing ---");

// This is the traffic that raises no prompt, so without the log it is silent.
const trusted = await mint("trusted.pck", ["read"]);
const mark = (await activity()).at(-1)?.seq ?? 0;
await call("/db/getTablelistFromRoot?dbRootId=probe&chain=sol", trusted.token, { patience: 3000 });

const quiet = (await activity(mark)).find((e) => e.label === "trusted.pck");
check("a silently-granted read still appears", quiet !== undefined);
check("  marked as granted rather than allowed", quiet?.outcome === "granted", quiet?.outcome);

console.log("\n--- writes carry what they would cost ---");

const spender = await mint("spender.pck");
const writing = call("/db/writeRow", spender.token, {
  method: "POST",
  body: JSON.stringify({
    chain: "mon", dbRootId: "probe", tableName: "flame_x",
    rowJson: JSON.stringify({ id: "1", ts: "2", note: "x".repeat(300) }),
  }),
});
const p2 = await waitForPrompt("writeRow");
check("a write is parked for approval", p2 !== null);
if (p2) await answer(p2.id, false, false);
await writing;

const write = (await activity(mark)).find((e) => e.action === "writeRow");
check("the write is recorded", write !== undefined);
check("  under the write scope", write?.scope === "write", write?.scope);
check("  carrying the payload size", Number(write?.bytes) > 300, String(write?.bytes));
check("  and the table it targeted", String(write?.subject) === "flame_x", write?.subject);

console.log("\n--- the log is incremental ---");

const all = await activity();
const last = all.at(-1).seq;
check("asking after the last entry returns nothing", (await activity(last)).length === 0);
check("  while asking from zero returns everything", (await activity(0)).length === all.length);
check("  and sequence numbers only increase",
  all.every((e, i) => i === 0 || e.seq > all[i - 1].seq));

console.log(`\n${fail} failure(s), ${pass} passed`);
process.exit(fail ? 1 : 0);
