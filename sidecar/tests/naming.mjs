// Can an app that found the host on its own say who it is, and does the host
// keep that claim distinguishable from a name it assigned?
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
  }).catch((e) => ({ status: e.name === "TimeoutError" ? 0 : -1, json: async () => ({}) }));

const tokens = async () => (await (await call("/control/tokens", CONTROL)).json()).tokens;
const approvals = async () => (await (await call("/control/approvals", CONTROL)).json()).approvals;

const mint = async (label) =>
  (await (await call("/control/tokens", CONTROL, {
    method: "POST", body: JSON.stringify({ label }),
  })).json());

console.log("\n--- an app can say who it is ---");

// Stand in for the shared anonymous token the discovery file hands out.
const anonymous = await mint("Unidentified app (discovery)");
const named = await (await call("/session", anonymous.token, {
  method: "POST", body: JSON.stringify({ name: "Burning Bush Protocol" }),
})).json();

check("it gets a token of its own", typeof named.token === "string" && named.token.length > 0);
check("  distinct from the shared one", named.token !== anonymous.token);
check("  bearing the name it asked for", named.label === "Burning Bush Protocol", named.label);
check("  marked as its own claim", named.declared === true, String(named.declared));

const listed = (await tokens()).find((t) => t.id === named.id);
check("the host records it as declared", listed?.declared === true);
check("  and grants it nothing", (listed?.scopes ?? []).length === 0, JSON.stringify(listed?.scopes));

console.log("\n--- the claim reaches the prompt ---");

const reading = call("/db/getTablelistFromRoot?dbRootId=probe&chain=sol", named.token);
let prompt = null;
for (let i = 0; i < 60 && !prompt; i++) {
  prompt = (await approvals()).find((a) => a.action === "listTables");
  if (!prompt) await new Promise((r) => setTimeout(r, 100));
}
check("the prompt names the app", prompt?.label === "Burning Bush Protocol", prompt?.label);
check("  and says the name is self-declared", prompt?.declared === true, String(prompt?.declared));
if (prompt) {
  await call(`/control/approvals/${prompt.id}`, CONTROL, {
    method: "POST", body: JSON.stringify({ decision: "deny", remember: false }),
  });
}
await reading;

console.log("\n--- a name is a claim, not a credential ---");

// Nothing stops an app calling itself anything. The defence is that the host
// marks it, not that it refuses — refusing a name list is unwinnable.
const impostor = await (await call("/session", anonymous.token, {
  method: "POST", body: JSON.stringify({ name: "GodOnChain (host)" }),
})).json();
check("an app may claim a trusted name", impostor.label === "GodOnChain (host)");
check("  but it is still marked as claimed", impostor.declared === true);
check("  and the real host token is not", (await tokens()).some(
  (t) => t.label === "GodOnChain (host)" && t.declared === false));
check("  nor does claiming grant anything", (await tokens())
  .find((t) => t.id === impostor.id)?.scopes.length === 0);

console.log("\n--- refusals ---");
const blank = await call("/session", anonymous.token, {
  method: "POST", body: JSON.stringify({ name: "   " }),
});
check("a blank name is refused", blank.status === 400, String(blank.status));

const unauth = await fetch(`${base}/session`, {
  method: "POST", headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ name: "nobody" }),
}).catch(() => ({ status: -1 }));
check("naming requires a token at all", unauth.status === 401, String(unauth.status));

console.log(`\n${fail} failure(s), ${pass} passed`);
process.exit(fail ? 1 : 0);
