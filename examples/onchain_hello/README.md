# On-Chain Hello

The smallest useful app that reads and writes IQ Labs on-chain data through
GodOnChain.

It ships **no keys, no GDExtension and no copy of the IQ SDK**. The only thing
it carries is `addons/iq_client/iq_client.gd`, copied verbatim from
[GodOnChain's addon](../../addons/iq_client/README.md). Everything else comes
from whichever GodOnChain launched it.

## Running it

**From GodOnChain** — the real path. Export to `.pck`, inscribe it, then load
it with the data type set to *Godot PCK*. GodOnChain mints this app its own
read-only token and passes it in the environment, so `discover()` just works
and approval prompts name it.

**From the editor**, with GodOnChain running alongside. It falls back to the
discovery file and connects anonymously, read-only.

**On its own**, with nothing running. `discover()` fails, the app says so and
stays usable. That is the case worth copying: on-chain access is an optional
capability, not a requirement.

Headless, for scripting:

```bash
Godot --headless --path . -- --read <signature> --quit-when-done
Godot --headless --path . -- --write "some text" --quit-when-done
```

## What to copy from it

- `discover()` once in `_ready()`, and degrade gracefully when it returns false.
- Reads (`read_metadata`, `read_code_in`) are free and silent.
- `write_code_in()` **blocks while GodOnChain asks the user**, and returns
  `null` if they decline. Don't put it behind a timer, don't call it on
  startup, and treat refusal as a normal outcome rather than an error.
- `last_error` is written for humans; show it.
