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
- **Bookmarks** — save and quickly reload your favorite inscriptions with full settings (chain, encryption, data type)
- **Encryption options**
  - Public (no encryption)
  - AES-256-CBC + PBKDF2 (passphrase)
  - HanLock (backend-assisted)
- **Multi-chain support**: SOL (Solana), MON (Monad)
- **Beautifully unhinged loading screen** — crypto memes + heavy TempleOS / Terry A. Davis energy
- Persistent settings and local downloads

## 🏗️ Architecture

GodOnChain is the **frontend only**. It talks to a local backend server (default `http://localhost:6900`, self-hosted by running an instance of https://github.com/KingTerry-IQ/iqlabs-sdk-local-server-wrapper) that handles:

- Reading/writing inscription data
- Chunked uploads + job progress polling
- HanLock encryption endpoints
- Chain-specific logic and metadata

The Godot client focuses on the UI, encryption (AES), PCK execution, bookmark management, and progress feedback.

## 📋 Requirements

- **Godot 4.6** (GL Compatibility renderer) to run from source
- Running **backend server** on port 6900 (https://github.com/KingTerry-IQ/iqlabs-sdk-local-server-wrapper)
- For running inscribed Godot apps: a compatible Godot executable (select once in the UI.  For sure compatibility, match the Godot version which the pck/zip was exported with, but a more recent version may work fine depending on the existence of breaking changes to the engine since then.)
- Funds + compatible wallet setup on the target chain for uploads (the client estimates costs)

## 🚀 Getting Started

1. Clone this repo and open `project.godot` in Godot 4.6+.
2. Start your local backend server.
3. Press **F5** (or run the main scene `browser_ui.tscn`).
4. (Optional but recommended for PCKs) Click **Select** next to "Godot Path" and point to your Godot executable.
5. Enter a transaction/signature ID, pick chain + options, hit **Go**.
6. Or click **Code In** (top of bookmarks panel) to inscribe something new.

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
├── addons/                  # GDQuest GDScript formatter
├── Assets/                  # iq_theme.tres, IBMPlexMono font, spinner shader
├── Resources/
│   └── Options.gd           # Persisted user settings (godot exe path)
├── Scenes/
│   ├── Backend/
│   │   ├── IQ_SDK.gd        # Core client ↔ backend communication + job polling
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
- Large file uploads are base64-encoded client-side then sent to backend for chunking.
- PCK execution uses `OS.create_process` with `--main-pack` so the inscribed app runs independently.
- The loading phrases are lovingly excessive (see `spinner.gd`).

## ⚠️ Disclaimer

This is experimental, meme-grade, on-chain software. Inscribing costs real gas. Data on public blockchains is public (optionally protected via encryption). Running arbitrary downloaded code has obvious risks — only load things you trust.  pck/zip exported Godot applications are inherently open source and therefore may rightly be considered to be worth examination before running.

---

*Built with Godot. Blessed by our good King Terry. Powered by $IQ.*
