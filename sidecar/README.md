# IQ sidecar

The IQ Labs SDKs, wrapped in a local HTTP service that GodOnChain bundles,
spawns and reaps. This replaces the separate
`iqlabs-solana-sdk-local-server-wrapper` repo — there is no second project to
clone, install or run.

## Why it is still a service

GodOnChain launches inscribed `.pck` apps as **separate OS processes**, under
a **stock Godot binary the user picked** (see `Scenes/Backend/pck_executor.gd`).
Those apps cannot call into GodOnChain's GDScript, and cannot rely on any
GDExtension GodOnChain uses — `.gdextension` libraries generally can't be
loaded from inside a `--main-pack` package either.

A loopback HTTP service is the one interface all of them can reach, whatever
engine version or extensions they have. So the SDK stays a service; what
changed is that GodOnChain now ships and owns it.

## Building

```bash
cd sidecar
npm install
node build.mjs
```

That bundles `server.ts` with esbuild and injects it into a copy of the Node
runtime, producing `bin/iq-sidecar[.exe]` (~88 MB) — self-contained, with no
Node install needed on the user's machine. The Godot export presets pick up
`sidecar/bin/*`; `IQHost` extracts it to `user://bin/` at startup, because a
binary cannot be executed from inside a `.pck`.

That builds for the platform you run it on. Node's SEA format cannot
cross-compile, so the Linux binary needs a Linux host:

```bash
wsl bash build-linux.sh     # from Windows, with WSL installed
bash build-linux.sh         # from inside Linux or CI
npm run build:linux         # same thing
```

`build-linux.sh` handles the two things a bare `node build.mjs` does not:
it stages sources onto the Linux filesystem (building on `/mnt/c` is slow, and
the `node_modules` there holds win32 esbuild binaries), and it finds a Linux
Node even when the PATH is full of Windows ones — under WSL, `npm` usually
resolves to `/mnt/c/Program Files/nodejs/npm`, which would quietly produce a
Windows build. If no Linux Node is present it installs one under `~/.local`,
no sudo. It then starts the result and checks it answers `/health` and refuses
unauthenticated calls before installing it into `bin/`.

**Do not strip the Linux binary.** It is ~124 MB with debug info, and `strip`
looks tempting, but the SEA blob does not survive it — the binary segfaults on
start. (The relocation warnings `strip` prints are the tell.)

Each export preset carries only its own platform's binary:
`sidecar/bin/iq-sidecar.exe` for Windows, `sidecar/bin/iq-sidecar` for Linux.
The executable bit is lost when the Linux binary sits on a Windows mount;
`IQHost` re-applies it with `chmod +x` after extracting to `user://bin`.

On Windows, postject prints `warning: The signature seems corrupted!`. That is
expected — injecting the blob invalidates node.exe's Authenticode signature.
Sign the finished binary yourself if you ship signed builds.

Other scripts:

```bash
npm run bundle     # just build/sidecar.cjs, no executable
npm run typecheck  # tsc --noEmit
npm run dev        # ts-node, standalone on :6900
```

If `bin/` is empty but `build/sidecar.cjs` exists, `IQHost` falls back to
running the bundle through a local `node`, so you can iterate from the editor
without a full build.

## Chains

Three: `sol` (Solana), `mon` (Monad) and `rh` (Robinhood Chain). The long
spellings — `solana`, `monad`, `robinhood` — are accepted everywhere the short
code is, and every route reports back the short one. An unrecognised chain is a
400, never a silent fall back to Solana: a guess here spends real funds
somewhere the caller did not name.

`mon` and `rh` are the same IQ Labs Ethereum SDK against different
deployments, so they share every code path. Adding another EVM chain means one
entry in `EVM_CHAINS` in `helpers.ts` — its SDK network mode, its currency,
and the two environment variables it reads — and nothing else.

They do need taking in turns, though. The SDK holds its active network in
module state, and that state picks the contract address a write is signed
against; two chains overlapping would send a Monad write to the Robinhood
deployment or the reverse. `evm_network.ts` is that turn-taking, kept separate
from the SDK so it can be tested without one. Requests on the chain already
held join its turn, so concurrent reads still overlap; they queue once the
other chain is waiting, so neither can starve the other.

## Security model

The process holds funded signers, so:

- **Loopback only.** It binds `127.0.0.1` on an ephemeral port chosen by the
  host, not `0.0.0.0:6900`.
- **No CORS headers.** Combined with the required bearer token, a page in the
  user's browser cannot drive it.
- **Every route needs a token** except `GET /health`.
- **Scopes.** `read` covers `/read`, `/metadata`, `/db/*` reads and `/han_*` —
  no key material, no cost. `write` covers `/write` and the DB writers.
  `control` is the host's alone.
- **Writes without `write` are not rejected, they are parked.** The request
  waits while GodOnChain asks the user, then proceeds or fails on their
  answer. The caller's protocol is unchanged: it still polls `/progress`.
  Prompts expire after 5 minutes and default to denied.
- **Watchdog.** `--parent-pid` makes it exit on its own if the host dies
  without reaping it, so it never lingers holding keys.

Keys come from the environment at spawn (`SOLANA_SIGNER_PRIVATE_KEY`,
`MON_SIGNER_PRIVATE_KEY`, `RH_SIGNER_PRIVATE_KEY`, `HANLOCK_PASS`, and the
three RPC URLs — `SOLANA_RPC_URL`, `MONAD_RPC_URL`, `ROBINHOOD_RPC_URL`; each
falls back to a public default). GodOnChain
keeps them in an encrypted vault under `user://`, opened with a master
password the user chooses, and sets them in the environment just long enough
to spawn this process. Callers never send or see a key.

The vault is `user://iq_secrets.cfg`, written with Godot's encrypted container
under a key stretched from the master password with PBKDF2-HMAC-SHA256 (100k
iterations, salt in `user://iq_secrets.salt`). The stretching matters: Godot
hashes a passphrase straight to an AES key, which is too weak for something a
person types. Unlocking is optional, since reads need no key — declining
leaves the app in a read-only session.

## Arguments

| Flag | Meaning |
|---|---|
| `--port N` | Port to bind. Defaults to `IQ_SIDECAR_PORT`, then 6900. |
| `--token T` | The control token. Without it, runs standalone and prints one. |
| `--parent-pid N` | Exit if that process disappears. |
| `--discovery-file P` | Delete this file on exit, so apps do not chase a dead port. |

On startup it prints `IQ_SIDECAR_READY {"port":N,"pid":N}`.

## Control plane

Host-only, requires the `control` scope.

| Route | Purpose |
|---|---|
| `POST /control/tokens` | Mint a scoped token for an app being launched. |
| `GET /control/tokens` | List issued tokens. |
| `DELETE /control/tokens/:id` | Revoke one, e.g. when its app exits. |
| `GET /control/approvals` | Prompts waiting on the user. |
| `POST /control/approvals/:id` | `{decision: "allow"\|"deny", remember: bool}` |

`remember` widens that token's scopes for the rest of the session.

The data routes (`/read`, `/write`, `/metadata`, `/progress`, `/db/*`,
`/han_*`) are unchanged from the original wrapper apart from requiring a
token; see that repo's README for their payloads.

## Testing

```bash
Godot --headless --path . --script res://tools/iq_selftest.gd
```

Exercises the vault (save, lock, wrong password, unlock, round-trip), the
sidecar lifecycle, token minting and revocation, and the full write-approval
round-trip. Exits non-zero on failure.

```bash
Godot --headless --path . --script res://tools/iq_apptest.gd
```

The cross-process one: launches `examples/onchain_hello` as its own Godot
process with a minted token, and answers the approval its write raises. This
is what proves a launched app can reach the SDK without keys or extensions.

```bash
npm run test:chains
```

Which chain a request is understood to be for, end to end: every accepted
spelling resolving to one code, an unknown chain refused rather than guessed
at, and a Robinhood write reaching the prompt named and sized. It reaches no
chain — a request that gets that far is refused at the gate.

```bash
npm run test:turns
```

The turn-taking in `evm_network.ts`, in-process and without a sidecar: that two
chains never overlap, that same-chain requests still share a turn, that a busy
chain cannot starve a quiet one, and that a turn is released even when the work
throws. This is the one new piece that can lose money quietly, so it is tested
on its own rather than only through the routes that use it.

## Upstream

`server.ts` and `helpers.ts` came from
`iqlabs-solana-sdk-local-server-wrapper`. To pull in a newer IQ SDK, bump
`@iqlabs-official/solana-sdk` / `@iqlabs-official/ethereum-sdk` in
`package.json`, reinstall, and rebuild. No protocol logic is duplicated in
GDScript, so there is nothing else to keep in sync.
