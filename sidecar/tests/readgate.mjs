// Does a read actually park for approval, and are reads and writes remembered
// separately? Runs against a real sidecar on a spare port with a throwaway
// token. Touches no chain: every request is answered or denied at the gate.
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

const approvals = async () =>
  (await (await call("/control/approvals", CONTROL)).json()).approvals;

const answer = async (id, allowed, remember) =>
  call(`/control/approvals/${id}`, CONTROL, {
    method: "POST",
    body: JSON.stringify({ decision: allowed ? "allow" : "deny", remember }),
  });

// Waits for the broker to register the parked request.
const waitForPrompt = async (action) => {
  for (let i = 0; i < 60; i++) {
    const list = await approvals();
    const found = list.find((a) => a.action === action);
    if (found) return found;
    await new Promise((r) => setTimeout(r, 100));
  }
  return null;
};

const mint = async (label) =>
  (await (await call("/control/tokens", CONTROL, {
    method: "POST", body: JSON.stringify({ label }),
  })).json());

console.log("\n--- a read now asks ---");
const app = await mint("readgate.pck");
check("an app token starts with no standing grants",
  Array.isArray(app.scopes) && app.scopes.length === 0, JSON.stringify(app.scopes));

// Fire a read and leave it hanging while we inspect the prompt.
const reading = call("/db/getTablelistFromRoot?dbRootId=probe&chain=sol", app.token);
const prompt = await waitForPrompt("listTables");
check("a read parks for approval", prompt !== null);
if (prompt) {
  check("  under the read scope, not write", prompt.scope === "read", prompt.scope);
  check("  naming the app", prompt.label === "readgate.pck", prompt.label);
  check("  and what it wants to look at",
    String(prompt.details?.dbRootId) === "probe", JSON.stringify(prompt.details));
  await answer(prompt.id, false, false);
}
const denied = await reading;
check("  a refused read fails the request", denied.status === 403, String(denied.status));

console.log("\n--- allowing reads does not allow spending ---");
const app2 = await mint("readgate2.pck");
const reading2 = call("/db/getTablelistFromRoot?dbRootId=probe&chain=sol", app2.token);
const p2 = await waitForPrompt("listTables");
if (p2) await answer(p2.id, true, true);   // always allow reads
await reading2;

const listed = (await (await call("/control/tokens", CONTROL)).json()).tokens
  .find((t) => t.label === "readgate2.pck");
check("'always' granted the read scope", listed.scopes.includes("read"), JSON.stringify(listed.scopes));
check("  and nothing else", !listed.scopes.includes("write"), JSON.stringify(listed.scopes));

// A second read must now be silent.
const before = (await approvals()).length;
const again = await call("/db/getTablelistFromRoot?dbRootId=probe&chain=sol", app2.token);
check("  so a later read no longer asks", (await approvals()).length === before);
check("  and is answered rather than refused", again.status !== 403, String(again.status));

// But a write still must.
const writing = call("/db/createTable", app2.token, {
  method: "POST",
  body: JSON.stringify({ chain: "sol", dbRootId: "probe", tableSeed: "t", tableName: "t",
    columnNames: ["id"], idCol: "id", tableHint: "t" }),
});
const p3 = await waitForPrompt("createTable");
check("a write still asks, despite reads being allowed", p3 !== null);
if (p3) {
  check("  under the write scope", p3.scope === "write", p3?.scope);
  await answer(p3.id, false, false);
}
await writing.catch(() => {});

console.log("\n--- 'never' is as durable as 'always' ---");
const app3 = await mint("readgate3.pck");
const r3 = call("/db/getTablelistFromRoot?dbRootId=probe&chain=sol", app3.token);
const p4 = await waitForPrompt("listTables");
if (p4) await answer(p4.id, false, true);  // never allow reads
check("a refused read fails", (await r3).status === 403);

const before2 = (await approvals()).length;
const r4 = await call("/db/getTablelistFromRoot?dbRootId=probe&chain=sol", app3.token);
check("  and a later read is refused without asking again",
  r4.status === 403 && (await approvals()).length === before2, String(r4.status));

const blockedTok = (await (await call("/control/tokens", CONTROL)).json()).tokens
  .find((t) => t.label === "readgate3.pck");
check("  recorded as a standing refusal",
  (blockedTok.blocked || []).includes("read"), JSON.stringify(blockedTok.blocked));
check("  without granting it", !blockedTok.scopes.includes("read"));

console.log(`\n${fail} failure(s), ${pass} passed`);
process.exit(fail ? 1 : 0);
