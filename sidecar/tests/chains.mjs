// Does the service actually know three chains, and does it keep them apart?
//
// Runs against a real sidecar on a spare port with a throwaway token. Reaches
// no chain: every request here is either refused at the gate or rejected as
// malformed before anything is signed or fetched. That is deliberate — the
// point is which chain a request is *understood* to be for, and asking a real
// RPC would only add flakiness to a question it cannot answer.
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

const answer = async (id, allowed) =>
  call(`/control/approvals/${id}`, CONTROL, {
    method: "POST",
    body: JSON.stringify({ decision: allowed ? "allow" : "deny", remember: false }),
  });

const waitForPrompt = async (action) => {
  for (let i = 0; i < 60; i++) {
    const found = (await approvals()).find((a) => a.action === action);
    if (found) return found;
    await new Promise((r) => setTimeout(r, 100));
  }
  return null;
};

const mint = async (label) =>
  (await (await call("/control/tokens", CONTROL, {
    method: "POST", body: JSON.stringify({ label }),
  })).json());

const activity = async () =>
  (await (await call("/control/activity", CONTROL)).json()).activity;

console.log("\n--- every spelling lands on one code ---");
// The prompt, the activity log and the cost estimate all key on the chain the
// service decided this request was for. If "robinhood" and "rh" resolved
// differently, a user could approve a spend on one chain and pay on another.
for (const [spelling, code] of [
  ["rh", "rh"],
  ["robinhood", "rh"],
  ["ROBINHOOD", "rh"],
  ["monad", "mon"],
  ["MON", "mon"],
  ["solana", "sol"],
]) {
  const app = await mint(`spelling-${spelling}`);
  const pending = call(
    `/db/getTablelistFromRoot?dbRootId=probe&chain=${encodeURIComponent(spelling)}`,
    app.token,
  );
  const prompt = await waitForPrompt("listTables");
  check(`"${spelling}" is understood as ${code}`,
    prompt !== null && prompt.details?.chain === code,
    JSON.stringify(prompt?.details));
  if (prompt) await answer(prompt.id, false);
  await pending;
}

console.log("\n--- an unknown chain is refused, not guessed ---");
{
  // Silently falling back to Solana would be the dangerous failure: the caller
  // asked for a chain the service does not have, and a guess spends real funds
  // somewhere they did not name.
  const response = await call("/db/getTablelistFromRoot?dbRootId=probe&chain=ethereum", CONTROL);
  check("a chain we do not speak is a 400", response.status === 400, String(response.status));
  const body = await response.json().catch(() => ({}));
  check("  and the message names what we do speak",
    String(body.error).includes("rh") && String(body.error).includes("mon"),
    JSON.stringify(body));
}

console.log("\n--- a Robinhood write is priced and named before it happens ---");
{
  const app = await mint("rh-writer.pck");
  const payload = "x".repeat(900);
  const pending = call("/write", app.token, {
    method: "POST",
    body: JSON.stringify({ data: payload, chain: "robinhood", filename: "note.txt" }),
  });
  const prompt = await waitForPrompt("codeIn");
  check("the write parks for approval", prompt !== null);
  if (prompt) {
    check("  under the write scope", prompt.scope === "write", prompt.scope);
    check("  naming Robinhood Chain, not the spelling asked for",
      prompt.details?.chain === "rh", JSON.stringify(prompt.details));
    check("  and carrying the payload size the estimate is built from",
      prompt.details?.bytes === payload.length, String(prompt.details?.bytes));
    await answer(prompt.id, false);
  }
  const refused = await pending;
  check("  refusing it fails the request", refused.status === 403, String(refused.status));

  const logged = (await activity()).filter((entry) => entry.chain === "rh");
  check("  and the refusal is logged against rh",
    logged.some((entry) => entry.action === "codeIn" && entry.outcome === "denied"),
    JSON.stringify(logged.slice(-3)));
}

console.log("\n--- an EVM chain still wants a table name ---");
{
  // Solana addresses a table by a program-derived address and the EVM chains
  // by name. Robinhood has to be on the EVM side of that split, or a row read
  // would go looking for an address no EVM chain has.
  const started = await call(
    "/db/readTableRows?dbRootId=probe&chain=rh&tablePda=notanaddress",
    CONTROL,
  );
  const { jobId } = await started.json();
  let job = {};
  for (let i = 0; i < 60; i++) {
    job = await (await call(`/progress?jobId=${jobId}`, CONTROL)).json();
    if (job.status !== "pending") break;
    await new Promise((r) => setTimeout(r, 100));
  }
  check("rh row reads refuse a Solana-shaped request",
    job.status === "error" && String(job.error).includes("tableName"),
    JSON.stringify(job));
  check("  and say which chain refused",
    String(job.error).includes("RH"), String(job.error));
}

console.log(`\n${fail} failure(s), ${pass} passed`);
process.exit(fail === 0 ? 0 : 1);
