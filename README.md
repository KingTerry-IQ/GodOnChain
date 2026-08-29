# GodOnChain

**Inscribe. Retrieve. Execute.**

GodOnChain is a Godot-powered client for **on-chain code inscriptions** — a way to store and retrieve text, files, and even full Godot applications directly on blockchains, powered by $IQ SDKs: https://iq6900.com/.

Store decentralized apps, encrypted notes, or any data permanently on Solana, Monad, and more. Fetch it later by transaction ID and, for Godot `.pck`/`.zip` packages, launch them straight from the chain.

## ✨ Features

- **Load on-chain data** by signature / transaction ID
  - Metadata view (IQLabs-style)
  - Plain or encrypted text
  - ASCII art
  - Downloadable arbitrary files
  - **Executable Godot apps** — download, optionally cache, and run `.pck` / `.zip` using a local Godot binary
- **"Code In" inscriptions** — write new text or upload files to the blockchain with live cost estimates
- **Bookmarks** — save and quickly reload your favorite inscriptions with full settings (chain, encryption, data type); now organizeable into folders (root-level) with tree view, create/move/delete support in the sidebar. Old flat bookmarks auto-migrate as root items.
- **Encryption options**
  - Public (no encryption)
  - AES-256-CBC + PBKDF2 (passphrase)
  - HanLock (backend-assisted)
- **Multi-chain support**: SOL (Solana), MON (Monad)
- **Encrypted key vault** — signing keys sit under a master password, and are
  never handed to the apps you launch
- **Beautifully unhinged loading screen** — crypto memes + heavy TempleOS / Terry A. Davis energy
- Persistent settings and local downloads

## 🏗️ Architecture

GodOnChain **bundles the IQ Labs SDKs** and runs them itself. There is no
second project to clone or start: the app ships a self-contained service
binary, spawns it on loopback at startup, and reaps it on exit.

It stays a local service rather than in-process GDScript for one reason —
**GodOnChain launches other apps, and they want the SDK too.** Inscribed
`.pck` apps run as separate processes under a stock Godot binary the user
picked, so they can neither call into GodOnChain's GDScript nor load its
GDExtensions. A loopback HTTP service is the one interface every one of them
can reach.

That makes GodOnChain the **host and wallet** for on-chain Godot apps:

- It owns the keys. Launched apps never see them.
- It mints each launched app its own **read-only** token, so reads just work.
- A write is **never silent**. The service parks the request and GodOnChain
  asks the user, naming the app, the chain, the size and an estimated cost.
  "Always allow this app" lasts for that session.
- Apps launched outside GodOnChain can still find a running instance through
  a discovery file, with an anonymous read-only token.

App authors: copy `addons/iq_client/iq_client.gd` into your project. It is
plain GDScript over HTTPRequest — no keys, no addons, no SDK copy. See
[addons/iq_client/README.md](addons/iq_client/README.md), and
[examples/onchain_hello](examples/onchain_hello/README.md) for a working app
that reads and inscribes through the host.

Service details, including the security model, are in
[sidecar/README.md](sidecar/README.md).

## 📋 Requirements

- **Godot 4.6+** (GL Compatibility renderer) to run from source
- **Node.js 18+** — only to *build* the bundled service. Users of an exported
  build need nothing installed.
- To build the **Linux** service binary, a Linux host: WSL, a container, or CI.
  `wsl bash sidecar/build-linux.sh` covers the WSL case, installing its own
  Node under `~/.local` if there isn't one.
- For running inscribed Godot apps: a compatible Godot executable (select once
  in the UI. For sure compatibility, match the Godot version which the pck/zip
  was exported with, but a more recent version may work fine depending on the
  existence of breaking changes to the engine since then.)
- Funds + a signing key on the target chain for uploads (the client estimates
  costs). Reading needs no key at all.
- A master password of your choosing, which encrypts those keys at rest.

## 🚀 Getting Started

1. Clone this repo.
2. Build the bundled on-chain service once:
   ```bash
   cd sidecar && npm install && node build.mjs   # for this platform
   wsl bash build-linux.sh                       # additionally, for Linux exports
   ```
3. Open `project.godot` in Godot 4.6+ and press **F5**.
4. Click **KEYS** (top right) and enter your signing keys and RPC URLs, plus a
   master password to encrypt them with. They are stored encrypted on this
   machine only and passed to the local service. Skip it entirely if you only
   want to read — reading needs no key.
   On later launches you are asked for that master password, and can choose
   **Read-only** to carry on without it.
5. (Optional but recommended for PCKs) Click **Select** next to "Godot Path"
   and point to your Godot executable.
6. Enter a transaction/signature ID, pick chain + options, hit **Go**.
7. Or click **Code In** (top of bookmarks panel) to inscribe something new.

Downloads (files & PCKs) go to `user://downloads` and `user://app/<signature>/`.

Bookmarks are stored in `user://bookmarks.json`.

## 🖥️ Exporting

Export presets are configured for:
- Windows (`.exe`)
- Linux (`.x86_64`)

## 🎨 Icon & Visual Identity

The app icon blends Godot's distinctive three-lobe abstract mascot, blockchain chain links ("OnChain"), and a glowing cross (TempleOS / divine "God" inspiration) in a bold neon green-on-black terminal aesthetic that matches the UI theme and the project's chaotic based energy.

## 🗂️ Project Layout

```
.
├── addons/
│   ├── GDQuest_GDScript_formatter/
│   └── iq_client/            # Drop-in on-chain client for apps you launch
├── examples/
│   └── onchain_hello/       # Example app using that client
├── sidecar/                 # The bundled IQ Labs SDK service (built to bin/)
├── tools/                   # Headless test harnesses
├── Assets/                  # iq_theme.tres, IBMPlexMono font, spinner shader
├── Resources/
│   └── Options.gd           # Persisted user settings (godot exe path)
├── Scenes/
│   ├── Backend/
│   │   ├── IQ_SDK.gd        # App-level SDK surface (reads, writes, PCKs)
│   │   ├── iq_host.gd       # Spawns/reaps the service, mints app tokens
│   │   ├── iq_approvals.gd  # "App X wants to spend" prompts
│   │   ├── iq_settings.gd   # Encrypted key vault (unlock + keys screens)
│   │   ├── iq_overlay.gd    # Shared prompt-overlay builders
│   │   ├── data_handler.gd  # AES + HanLock encrypt/decrypt
│   │   └── pck_executor.gd  # Launches external Godot --main-pack <pck>
│   └── UI/
│       ├── browser_ui.gd    # Main application logic & UI wiring
│       ├── browser_ui.tscn  # The browser interface
│       └── spinner.gd       # Meme-filled loading overlay
├── export_presets.cfg
└── project.godot
```

## 🛠️ Development Notes

- All chain I/O is asynchronous via HTTPRequest + polling.
- Large file uploads are base64-encoded client-side then sent to the local service for chunking.
- PCK execution uses `OS.create_process` with `--main-pack` so the inscribed app runs independently.
- The app and the apps it launches use the *same* client (`addons/iq_client/iq_client.gd`);
  GodOnChain just always has a host available.
- Changing keys restarts the service, since it reads them from its environment at spawn.
- Prompt overlays added in code go through `IQOverlay`, so they match the
  ones already in `browser_ui.tscn` and inherit `iq_theme.tres`.
- Two headless test harnesses:
  ```bash
  Godot --headless --path . --script res://tools/iq_selftest.gd   # vault, host, approvals
  Godot --headless --path . --script res://tools/iq_apptest.gd    # a launched app, cross-process
  ```
- The loading phrases are lovingly excessive (see `spinner.gd`).

## ⚠️ Disclaimer

This is experimental, meme-grade, on-chain software. Inscribing costs real gas. Data on public blockchains is public (optionally protected via encryption). Running arbitrary downloaded code has obvious risks — only load things you trust. Apps you launch can read on-chain data freely and can *ask* to spend from your configured wallet; you approve each request, and "always allow" lasts only for that session. Deny anything you did not expect.  pck/zip exported Godot applications are inherently open source and therefore may rightly be considered to be worth examination before running.

---

*Built with Godot. Blessed by our good King Terry. Powered by $IQ.*
