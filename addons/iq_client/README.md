# IQClient — on-chain access for apps running under GodOnChain

`iq_client.gd` lets a Godot app read and write IQ Labs on-chain data through
the host that launched it, **without shipping any keys, GDExtensions, or a
copy of the SDK**.

Copy `iq_client.gd` into your project. That's the whole install — it is plain
GDScript over `HTTPRequest`, so it runs under whatever stock Godot binary
GodOnChain used to launch you.

## Quick start

```gdscript
var iq := IQClient.new()
add_child(iq)

if not await iq.discover():
    push_error(iq.last_error)   # No host; degrade gracefully.
    return

var doc = await iq.read_code_in("<signature>", "sol")
if doc:
    print(doc.metadata)
    print(doc.data)
```

Every call is a coroutine — always `await`. On failure they return `null` or
an empty `Dictionary`/`String` and set `last_error` to something you can show
a user.

## How it finds the host

1. **Environment variables**, set by GodOnChain when it launched you:
   `GODONCHAIN_IQ_URL`, `GODONCHAIN_IQ_TOKEN`, `GODONCHAIN_IQ_APP`. You get
   your own token labelled with your app name, so the user sees who is asking
   when you request a write.
2. **A discovery file**, for when the user starts your app directly while
   GodOnChain happens to be running:
   `%APPDATA%/GodOnChain/host.json` on Windows,
   `~/.local/share/GodOnChain/host.json` on Linux,
   `~/Library/Application Support/GodOnChain/host.json` on macOS.
   That token is read-only and anonymous.

`discover()` tries them in that order and confirms the host actually answers.

Nothing here is guaranteed to exist. Treat on-chain access as an optional
capability and keep working without it.

## Reads

Free, and always allowed.

```gdscript
await iq.read_code_in(signature, chain, progress_callback)  # -> {metadata, data}
await iq.read_metadata(signature, chain)                    # -> Dictionary, cheap
await iq.get_db_table_list(db_root_id, chain, progress_callback)
await iq.read_db_table_rows(table_pda, db_root_id, table_name, chain, limit, before, cb)
await iq.han_encrypt(text)
await iq.han_decrypt(text)
```

`chain` is `"sol"` or `"mon"`. `progress_callback` is an optional `Callable`
taking one float from 0 to 100 — useful for large reads, which can take a
while as chunks are walked.

For `read_db_table_rows`, SOL wants `table_pda`; MON wants `db_root_id` plus
`table_name`.

## Writes

```gdscript
var signature = await iq.write_code_in(data, filename, filetype, chain, progress_callback)
```

**This spends the user's money, and they are asked first.** Unless they have
already granted your app write access, the call blocks while GodOnChain shows
a prompt naming your app, the chain, the payload size and an estimated cost.

Consequences for you:

- `write_code_in()` can sit unresolved for minutes. Don't block your UI on it,
  and don't put it on a timer.
- It returns `null` if the user declines, with `last_error` explaining why.
  Declining is a normal outcome, not an error state — handle it quietly.
- If the user picks "Always allow this app", later writes go straight through
  for the rest of that GodOnChain session.
- Apps discovered through the discovery file (rather than launched by
  GodOnChain) hold a read-only token and cannot request writes at all.

### Database tables

```gdscript
await iq.create_table(db_root_id, table_name, columns, id_col, chain, options, cb)
await iq.write_row(db_root_id, table_name, row, chain, options, cb)
```

Both spend, so both behave exactly like `write_code_in()` — they block on the
user's approval and return `null` if it is refused.

`row` takes a Dictionary and encodes it for you, or an already-encoded JSON
String if you would rather do it yourself.

The two chains disagree about table identity, and the client smooths over what
it honestly can. Solana derives the table's address from a **table seed** and
also wants a **table hint**; both default to `table_name`, so you only pass
them when they need to differ. Monad uses `table_name` alone and supports
`is_private`. Everything chain-specific goes in `options`:

| Option | Chain | Meaning |
|---|---|---|
| `table_seed` | SOL | Address-deriving seed. Defaults to `table_name`. |
| `table_hint` | SOL | Required by the SDK. Defaults to `table_name`. |
| `skip_confirmation` | SOL | Don't wait for confirmation on `write_row`. |
| `is_private` | MON | Create the table private. |
| `gate` | both | Token gate. Shapes differ per chain — see the sidecar README. |
| `writers` | both | Whitelist of addresses allowed to write. |
| `ext_keys` | both | Extra keys, passed straight through. |

**If you set a `table_seed` at creation, pass the same one to every
`write_row`** — it is what addresses the table on Solana, and a different seed
silently means a different table.

Results carry the host's own fields (`dbRootId`, `tableName`, the chain) plus a
`signature` key, aliased from Monad's `txHash` so you don't have to branch on
chain to find the transaction id.

Ask for a write when the user did something that implies one. An app that
prompts on startup is an app that gets denied.

## Reference

| Member | Purpose |
|---|---|
| `discover() -> bool` | Find and confirm a host. Call once, `await` it. |
| `create_table(...)` | Create a table. Spends; blocks on approval. |
| `write_row(...)` | Append a row. Spends; blocks on approval. |
| `is_available() -> bool` | Whether the last contact succeeded. |
| `last_error: String` | Why the last call failed. Safe to display. |
| `app_label: String` | The name the host knows you by, when launched by it. |
| `base_url`, `token` | The resolved connection. Read-only in practice. |
| `host_found(url)` | Signal: a host answered. |
| `host_missing(reason)` | Signal: no host, or it stopped answering. |

`IQClient.discovery_path()` is a static helper returning the discovery file
location for the current platform.
