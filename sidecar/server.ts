import express, { NextFunction, Request, Response } from "express";
import type { AddressInfo } from "net";
import { ed25519 } from "@noble/curves/ed25519.js";
import * as timelock from "./timelock";
import { unlinkSync } from "fs";
import * as solanaIqlabs from "@iqlabs-official/solana-sdk";
import ethIqlabs from "@iqlabs-official/ethereum-sdk";
import {
  Connection,
  Keypair,
  PublicKey,
  SystemProgram,
  Transaction,
  sendAndConfirmTransaction,
} from "@solana/web3.js";
import { Wallet, JsonRpcProvider, formatEther } from "ethers";
import dotenv from "dotenv";
import bs58 from "bs58";
import { decodeWithPassword, encodeWithPassword } from "hanlock";
import { extractIQLabsMetadataFromTx, extractMonadMetadata, getNormalizedChain, safeParseMetadata } from "./helpers";
import {
  authenticate,
  denyAllApprovals,
  listActivity,
  listApprovals,
  listTokens,
  recordActivity,
  registerToken,
  requestApproval,
  requireScope,
  resolveApproval,
  revokeToken,
  type Scope,
} from "./host";

dotenv.config();

let jobCounter: number = 0;
const jobs = new Map<string, {
  progress: number;
  status: "pending" | "completed" | "error";
  result?: any;
  error?: string;
  /** Set while a spend is parked waiting on the user's answer. */
  awaitingApproval?: boolean;
  note?: string;
}>();

// === CLI / host handshake ===
// The host picks a free port and mints the control token, then passes both in.
// Falling back to 6900 + a printed token keeps `npm run dev` usable standalone.
const argOf = (name: string): string | undefined => {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && i + 1 < process.argv.length ? process.argv[i + 1] : undefined;
};

const PORT = Number(argOf("port") ?? process.env.IQ_SIDECAR_PORT ?? 6900);
const HOST_TOKEN = argOf("token") ?? process.env.IQ_SIDECAR_TOKEN;
const standalone = !HOST_TOKEN;

// The host is the user, so it holds every power and never prompts itself.
const hostToken = registerToken(
  "GodOnChain (host)",
  ["read", "write", "reveal", "control"],
  HOST_TOKEN,
)!;

// === RPC URLs ===
const solanaRpcUrl = process.env.SOLANA_RPC_URL || "https://api.mainnet-beta.solana.com";
const monadRpcUrl = process.env.MONAD_RPC_URL || "https://rpc.monad.xyz";

// === Solana setup ===
solanaIqlabs.setRpcUrl(solanaRpcUrl);
const solanaConnection = new Connection(solanaRpcUrl);

const app = express();
app.use(express.json({ limit: "16gb" }));

// No CORS headers by design. This process holds funded signers; letting a page
// in the user's browser drive it would be a wallet-draining bug, and the bearer
// token below forces a preflight that a cross-origin page cannot satisfy.

// Liveness probe — the only unauthenticated route. Deliberately says nothing
// about keys, balances or configuration.
app.get("/health", (_req: Request, res: Response) => {
  res.json({ ok: true, pid: process.pid });
});

app.use(authenticate);

// ==================== CONTROL PLANE (host only) ====================

/** Mints a scoped token for a child app that GodOnChain is about to launch. */
app.post("/control/tokens", requireScope("control"), (req: Request, res: Response) => {
  const { label, scopes } = req.body ?? {};
  if (!label || typeof label !== "string") {
    return res.status(400).json({ error: "Missing label" });
  }
  // No standing grants by default. A token minted holding `read` never
  // reaches the broker, so the user is never asked — which is exactly how
  // reads used to happen silently.
  const requested: Scope[] = Array.isArray(scopes) ? scopes : [];
  if (requested.includes("control")) {
    return res.status(403).json({ error: "Refusing to mint a control token" });
  }
  const record = registerToken(label, requested as Scope[]);
  if (!record) return res.status(429).json({ error: "Too many tokens" });
  res.json({ id: record.id, token: record.token, scopes: [...record.scopes] });
});

app.get("/control/tokens", requireScope("control"), (_req: Request, res: Response) => {
  res.json({ tokens: listTokens() });
});

app.delete("/control/tokens/:id", requireScope("control"), (req: Request, res: Response) => {
  const ok = revokeToken(String(req.params.id));
  if (!ok) return res.status(404).json({ error: "Unknown token id" });
  res.json({ revoked: String(req.params.id) });
});

/**
 * What apps have been asking for, oldest first.
 *
 * `after` is the last sequence number the caller already has, so the host can
 * poll for just what is new. Control scope: it names every app and everything
 * they touched, which is the user's business and nobody else's.
 */
app.get("/control/activity", requireScope("control"), (req: Request, res: Response) => {
  const after = Number(req.query.after ?? 0);
  res.json({ activity: listActivity(Number.isFinite(after) ? after : 0) });
});

/**
 * Trades the shared anonymous token for a private one bearing a name.
 *
 * Apps GodOnChain launches are named by GodOnChain. Apps that find the host on
 * their own share a single "Unidentified app" token, so the user is asked to
 * approve spends for something the prompt cannot name — and worse, two such
 * apps are indistinguishable from each other and from one another's grants.
 *
 * Any authenticated caller may ask, and the result is always marked declared:
 * the name is the app's own claim and nothing verifies it. An app can call
 * itself anything, including "GodOnChain", which is exactly why the prompt
 * shows a claimed name differently from an assigned one.
 *
 * No scopes come with it. Naming yourself earns identity, not trust.
 */
app.post("/session", (req: Request, res: Response) => {
  const name = String(req.body?.name ?? "").trim().slice(0, 48);
  if (!name) return res.status(400).json({ error: "Missing name" });

  const record = registerToken(name, [], undefined, true);
  if (!record) return res.status(429).json({ error: "Too many app sessions" });
  res.json({ id: record.id, token: record.token, label: record.label, declared: true });
});

/** Prompts the host is expected to surface to the user. */
app.get("/control/approvals", requireScope("control"), (_req: Request, res: Response) => {
  res.json({ approvals: listApprovals() });
});

/**
 * Gates a route behind a scope the caller may not hold. The host's own token
 * passes straight through; anyone else parks here until the user answers the
 * prompt GodOnChain raises. Sitting in middleware keeps the handlers untouched.
 */
const gate =
  (scope: Scope, action: string, describe: (req: Request) => Record<string, unknown>) =>
  async (req: Request, res: Response, next: NextFunction) => {
    let details: Record<string, unknown>;
    try {
      details = describe(req);
    } catch {
      details = {};
    }
    // Always await the answer. An earlier version short-circuited on "no
    // approval id", taking that to mean the caller already held the scope —
    // but a standing refusal also resolves without an id, and so sailed
    // through the gate it was supposed to close.
    const token = req.iqToken!;
    const asked = !token.scopes.has(scope) && !token.blocked.has(scope);
    const { approved } = requestApproval(token, scope, action, details);
    const allowed = await approved;

    // Logged whichever way it went. A standing grant is the case worth seeing
    // most: it raises no prompt, so without this it would be invisible.
    recordActivity({
      label: token.label,
      scope,
      action,
      chain: String(details.chain ?? ""),
      bytes: Number(details.bytes ?? 0),
      subject: String(
        details.tableName ?? details.dbRootId ?? details.signature ?? details.filename ?? "",
      ),
      outcome: allowed ? (asked ? "allowed" : "granted") : asked ? "denied" : "blocked",
    });

    if (allowed) return next();
    return res.status(403).json({ error: "Denied by the user", action, details });
  };

/** Spending gate. Every route using this moves the user's money. */
const gateSpend = (
  action: string,
  describe: (req: Request) => Record<string, unknown>,
) => gate("write", action, describe);

// ==================== TIME LOCKS ====================
// Sealing something behind sequential work nobody can parallelise. Creating a
// puzzle is instant for whoever makes it; opening one is the honest climb.

/** This machine's sequential squaring rate, measured once and reused. */
let squaringRate = 0;

/** Solving pins a core for as long as it takes, so only one runs at a time. */
let solving = false;

app.get("/timelock/rate", (_req: Request, res: Response) => {
  try {
    if (!squaringRate) squaringRate = timelock.benchmark();
    res.json({ squaringsPerSecond: squaringRate });
  } catch (err: any) {
    res.status(500).json({ error: err.message || "Could not measure" });
  }
});

/**
 * Builds a puzzle around a secret. Instant, because the maker holds the
 * trapdoor — which is discarded before this returns.
 */
app.post("/timelock/create", (req: Request, res: Response) => {
  try {
    const { secret, seconds } = req.body ?? {};
    if (typeof secret !== "string" || !/^[0-9a-fA-F]+$/.test(secret) || secret.length % 2) {
      return res.status(400).json({ error: "secret must be hex" });
    }
    const duration = Number(seconds);
    if (!Number.isFinite(duration) || duration <= 0) {
      return res.status(400).json({ error: "seconds must be a positive number" });
    }
    if (!squaringRate) squaringRate = timelock.benchmark();

    const puzzle = timelock.create(Buffer.from(secret, "hex"), duration, squaringRate);
    res.json(puzzle);
  } catch (err: any) {
    res.status(500).json({ error: err.message || "Could not build the puzzle" });
  }
});

/**
 * Solves a puzzle. This is deliberately slow — that is the entire product — so
 * it runs as a job and reports progress like any other long operation.
 */
app.post("/timelock/solve", (req: Request, res: Response) => {
  const { puzzle } = req.body ?? {};
  if (!timelock.isPuzzle(puzzle)) {
    return res.status(400).json({ error: "That is not a time-lock puzzle" });
  }
  if (solving) {
    return res.status(409).json({ error: "A puzzle is already being solved" });
  }

  const jobId = `job_${Date.now()}_${jobCounter++}`;
  jobs.set(jobId, { progress: 0, status: "pending" });
  solving = true;

  (async () => {
    try {
      const secret = await timelock.solve(puzzle, (percent: number) => {
        const job = jobs.get(jobId);
        if (job) job.progress = percent;
      });
      const job = jobs.get(jobId);
      if (job) {
        job.status = "completed";
        job.result = { secret: secret.toString("hex") };
        job.progress = 100;
      }
    } catch (err: any) {
      const job = jobs.get(jobId);
      if (job) {
        job.status = "error";
        // A GCM failure here means the climb finished but the answer was wrong,
        // which in practice means the puzzle was tampered with.
        job.error = err.message || "The puzzle did not open";
      }
    } finally {
      solving = false;
    }
  })();

  res.json({ jobId });
});

// ==================== IDENTITY & ENCRYPTION ====================
// The SDK derives a deterministic X25519 keypair from a wallet signature, so a
// user's Solana key *is* their encryption identity: same wallet, same identity,
// recoverable forever with nothing to store or lose.

/** Signs raw bytes with the configured Solana signer. */
const signWithSolanaKey = async (message: Uint8Array): Promise<Uint8Array> => {
  const secretKeyEnv = process.env.SOLANA_SIGNER_PRIVATE_KEY;
  if (!secretKeyEnv) throw new Error("No Solana signer is configured");
  const signer = Keypair.fromSecretKey(bs58.decode(secretKeyEnv));
  // Keypair.secretKey is the 64-byte expanded form; noble wants the 32-byte seed.
  return ed25519.sign(message, signer.secretKey.slice(0, 32));
};

let cachedIdentity: { privKey: Uint8Array; pubKey: string } | null = null;

const ourIdentity = async () => {
  if (cachedIdentity) return cachedIdentity;
  const pair = await solanaIqlabs.crypto.deriveX25519Keypair(signWithSolanaKey);
  cachedIdentity = {
    privKey: pair.privKey,
    pubKey: Buffer.from(pair.pubKey).toString("hex"),
  };
  return cachedIdentity;
};

/**
 * Which wallets are paying, and what they hold.
 *
 * Read scope: an address and its balance are public on both chains, and no
 * private key is touched beyond deriving the address from it. This exists
 * because a failed write is otherwise unreadable — an empty account and a
 * genuine bug produce the same "simulation failed".
 */
app.get(
  "/wallet",
  gate("read", "readWallet", () => ({})),
 async (_req: Request, res: Response) => {
  const out: Record<string, unknown> = {};

  const solKey = process.env.SOLANA_SIGNER_PRIVATE_KEY;
  if (solKey) {
    try {
      const signer = Keypair.fromSecretKey(bs58.decode(solKey));
      const lamports = await solanaConnection.getBalance(signer.publicKey);
      out.sol = {
        address: signer.publicKey.toBase58(),
        balance: lamports / 1e9,
        unit: "SOL",
        rpc: solanaRpcUrl,
      };
    } catch (err: any) {
      out.sol = { error: err.message || "Could not read the Solana wallet" };
    }
  }

  const monKey = process.env.MON_SIGNER_PRIVATE_KEY;
  if (monKey) {
    try {
      const provider = new JsonRpcProvider(monadRpcUrl);
      const signer = new Wallet(monKey, provider);
      out.mon = {
        address: signer.address,
        balance: Number(formatEther(await provider.getBalance(signer.address))),
        unit: "MON",
        rpc: monadRpcUrl,
      };
    } catch (err: any) {
      out.mon = { error: err.message || "Could not read the Monad wallet" };
    }
  }

  res.json(out);
});

/** This signer's public encryption identity. Safe to publish; others use it
 *  to encrypt things only this wallet can open. */
app.get("/crypto/identity", async (_req: Request, res: Response) => {
  try {
    const identity = await ourIdentity();
    res.json({ publicKey: identity.pubKey });
  } catch (err: any) {
    res.status(500).json({ error: err.message || "Could not derive an identity" });
  }
});

/** Encrypts to one or more recipients' public identities. Needs no secret of
 *  ours, so it is an ordinary read-scope call. */
app.post("/crypto/encryptTo", async (req: Request, res: Response) => {
  try {
    const { recipients, data } = req.body ?? {};
    if (!Array.isArray(recipients) || recipients.length === 0) {
      return res.status(400).json({ error: "At least one recipient is required" });
    }
    if (typeof data !== "string" || data.length === 0) {
      return res.status(400).json({ error: "Nothing to encrypt" });
    }
    const envelope = await solanaIqlabs.crypto.multiEncrypt(
      recipients.map((r: any) => String(r)),
      new Uint8Array(Buffer.from(data, "utf8")),
    );
    res.json(envelope);
  } catch (err: any) {
    res.status(500).json({ error: err.message || "Could not encrypt" });
  }
});

/**
 * Opens an envelope addressed to this wallet.
 *
 * Gated on `reveal` rather than `read`: it costs nothing, but an app holding
 * it freely could open anything ever addressed to the user, so the user is
 * asked exactly as they are for a spend.
 */
app.post(
  "/crypto/decrypt",
  gate("reveal", "decrypt", (req) => ({
    recipients: Array.isArray(req.body?.envelope?.recipients)
      ? req.body.envelope.recipients.length
      : 0,
  })),
  async (req: Request, res: Response) => {
    try {
      const { envelope } = req.body ?? {};
      if (!envelope || !Array.isArray(envelope.recipients)) {
        return res.status(400).json({ error: "That is not an envelope" });
      }
      const identity = await ourIdentity();
      const plaintext = await solanaIqlabs.crypto.multiDecrypt(
        identity.privKey,
        identity.pubKey,
        envelope,
      );
      res.json({ data: Buffer.from(plaintext).toString("utf8") });
    } catch (err: any) {
      // The usual cause is that this wallet simply is not a recipient.
      res.status(400).json({ error: err.message || "This is not addressed to you" });
    }
  },
);

app.post("/control/approvals/:id", requireScope("control"), (req: Request, res: Response) => {
  const { decision, remember } = req.body ?? {};
  if (decision !== "allow" && decision !== "deny") {
    return res.status(400).json({ error: "decision must be 'allow' or 'deny'" });
  }
  const ok = resolveApproval(String(req.params.id), decision === "allow", Boolean(remember));
  if (!ok) return res.status(404).json({ error: "Unknown or expired approval" });
  res.json({ resolved: String(req.params.id), decision });
});

// ==================== READ ====================
app.get(
  "/read",
  gate("read", "readCodeIn", (req) => ({
    chain: getNormalizedChain((req.query.chain as string) ?? "sol"),
    signature: req.query.signature ?? null,
  })),
 (req: Request, res: Response) => {
  const { signature, chain } = req.query as { signature?: string; chain?: string };

  if (!signature) {
    return res.status(400).json({ error: "Missing signature query param" });
  }

  let normalizedChain: "sol" | "mon";
  try {
    normalizedChain = getNormalizedChain(chain);
  } catch (e: any) {
    return res.status(400).json({ error: e.message });
  }

  const jobId = `job_${Date.now()}_${jobCounter++}`;
  jobs.set(jobId, { progress: 0, status: "pending" });

  (async () => {
    try {
      let result: any;

      if (normalizedChain === "sol") {
        result = await solanaIqlabs.reader.readCodeIn(
          signature,
          "light",
          (percent: number) => {
            const job = jobs.get(jobId);
            if (job) job.progress = percent;
          },
        );
      } else {
        // === MONAD ===
        const network = "monad";
        const rpc = monadRpcUrl;

        ethIqlabs.setNetwork(network, rpc);

        result = await ethIqlabs.reader.readCodeIn(
          signature, // txHash
          (percent: number) => {
            const job = jobs.get(jobId);
            if (job) job.progress = percent;
          },
        );
      }

      const job = jobs.get(jobId);
      if (job) {
        job.status = "completed";
        job.result = result;
        job.progress = 100;
      }
    } catch (err: any) {
      const job = jobs.get(jobId);
      if (job) {
        job.status = "error";
        job.error = err.message || "Failed to read code";
      }
    }
  })();

  res.json({ jobId });
});

// ==================== WRITE ====================
app.post(
  "/write",
  gateSpend("codeIn", (req) => ({
    chain: getNormalizedChain(req.body?.chain ?? "sol"),
    bytes: typeof req.body?.data === "string" ? Buffer.byteLength(req.body.data, "utf8") : 0,
    filename: req.body?.filename || null,
    filetype: req.body?.filetype || null,
  })),
  (req: Request, res: Response) => {
  try {
    const { data, filename, filetype, chain = "sol" } = req.body;

    if (!data || typeof data !== "string" || data.trim() === "") {
      return res.status(400).json({
        error: "Text input is required and must be a non-empty string",
      });
    }

    let normalizedChain: "sol" | "mon";
    try {
      normalizedChain = getNormalizedChain(chain);
    } catch (e: any) {
      return res.status(400).json({ error: e.message });
    }

    const jobId = `job_${Date.now()}_${jobCounter++}`;
    jobs.set(jobId, { progress: 0, status: "pending" });

    (async () => {
      try {
        let result: any;

        if (normalizedChain === "sol") {
          // === SOLANA ===
          const secretKeyEnv = process.env.SOLANA_SIGNER_PRIVATE_KEY;
          if (!secretKeyEnv) throw new Error("Missing SOLANA_SIGNER_PRIVATE_KEY in .env");

          const secretKey = bs58.decode(secretKeyEnv);
          const signer = Keypair.fromSecretKey(secretKey);

          console.log(`[SOL] Signer: ${signer.publicKey.toBase58()}`);
          const balance = await solanaConnection.getBalance(signer.publicKey);
          console.log("[SOL] Balance before:", balance / 1_000_000_000);

          result = await solanaIqlabs.writer.codeIn(
            { connection: solanaConnection, signer },
            data.trim(),
            filename ?? undefined,
            undefined,
            filetype ?? undefined,
            (percent: number) => {
              const job = jobs.get(jobId);
              if (job) job.progress = percent;
            },
            "light",
          );
        } else {
          // === MONAD ===
          const monPrivateKey = process.env.MON_SIGNER_PRIVATE_KEY;
          if (!monPrivateKey) throw new Error("Missing MON_SIGNER_PRIVATE_KEY in .env");

          const network = "monad";
          const rpc = monadRpcUrl;

          ethIqlabs.setNetwork(network, rpc);

          const provider = new JsonRpcProvider(rpc);
          const signer = new Wallet(monPrivateKey, provider);

          console.log(`[MONAD] Signer: ${signer.address}`);

          await ethIqlabs.assertChainMatches(signer);

          result = await ethIqlabs.writer.codeIn(
            signer,
            data.trim(),
            filename || undefined,
            filetype || undefined,
            (percent: number) => {
              const job = jobs.get(jobId);
              if (job) job.progress = percent;
            },
          );
        }

        const job = jobs.get(jobId);
        if (job) {
          job.status = "completed";
          job.result = result;
          job.progress = 100;
        }
      } catch (err: any) {
        console.error("Write error:", err);
        const job = jobs.get(jobId);
        if (job) {
          job.status = "error";
          job.error = describeChainError(err) || "Failed to write code";
        }
      }
    })();

    res.json({ jobId });
  } catch (err: any) {
    console.error("Write start error:", err);
    res.status(500).json({ error: err.message || "Failed to start write" });
  }
});

// ==================== METADATA ====================
app.get(
  "/metadata",
  gate("read", "readMetadata", (req) => ({
    chain: getNormalizedChain((req.query.chain as string) ?? "sol"),
    signature: req.query.signature ?? null,
  })),
 async (req: Request, res: Response) => {
  const { signature, chain } = req.query as { signature?: string; chain?: string };

  if (!signature) {
    return res.status(400).json({ error: "Missing signature query param" });
  }

  let normalizedChain: "sol" | "mon";
  try {
    normalizedChain = getNormalizedChain(chain);
  } catch (e: any) {
    return res.status(400).json({ error: e.message });
  }

  try {
    if (normalizedChain === "sol") {
      // === SOLANA - Exact SDK metadata from initial tx only ===
      const tx = await solanaConnection.getTransaction(signature, {
        commitment: "confirmed",
        maxSupportedTransactionVersion: 0,
      });

      if (!tx) {
        return res.status(404).json({ error: "Transaction not found on Solana" });
      }

      // Extract signer (fee payer)
      const signer = tx.transaction.message.getAccountKeys().staticAccountKeys[0]?.toBase58() ?? null;

      // Replicate exact SDK extraction (decodeUserInventoryCodeIn logic)
      const metadataResult = extractIQLabsMetadataFromTx(tx);

      if (!metadataResult) {
        return res.status(404).json({ error: "No IQLabs code-in instruction found in transaction" });
      }

      const parsedMeta = safeParseMetadata(metadataResult.metadata);

      const enhanced = {
        ...parsedMeta,
        onChainPath: metadataResult.onChainPath,
        signer,
        chain: "sol",
        signature,
      };

      return res.json(enhanced);
    } else {
      // === MONAD / EVM ===
      const provider = new JsonRpcProvider(monadRpcUrl);

      const [tx, receipt] = await Promise.all([
        provider.getTransaction(signature),
        provider.getTransactionReceipt(signature),
      ]);

      if (!tx) {
        return res.status(404).json({ error: "Transaction not found on Monad" });
      }

      const signer = tx.from;

      // Best-effort metadata extraction for EVM
      const evmMeta = extractMonadMetadata(tx, receipt);

      const parsedMeta = safeParseMetadata(evmMeta?.metadata ?? null);

      const enhanced = {
        ...parsedMeta,
        signer,
        chain: "mon",
        signature,
        ...(evmMeta?.onChainPath && { onChainPath: evmMeta.onChainPath }),
      };

      return res.json(enhanced);
    }
  } catch (err: any) {
    console.error("Metadata error:", err);
    return res.status(500).json({
      error: err.message || "Failed to extract metadata",
      signature,
      chain: normalizedChain,
    });
  }
});

// ==================== PROGRESS ====================
app.get("/progress", (req: Request, res: Response) => {
  const { jobId } = req.query as { jobId?: string };

  if (!jobId || !jobs.has(jobId)) {
    return res.status(404).json({ error: "Job not found or expired" });
  }

  const job = jobs.get(jobId)!;

  const responseData = {
    progress: job.progress,
    status: job.status,
    result: job.result ?? null,
    error: job.error ?? null,
  };

  if (job.status === "completed" || job.status === "error") {
    jobs.delete(jobId);
  }

  res.json(responseData);
});

// ==================== HANLOCK ====================
app.post("/han_encrypt", async (req: Request, res: Response) => {
  try {
    const { data } = req.body;
    if (!data) return res.status(400).json({ error: "Missing data" });

    const secretHanPass = process.env.HANLOCK_PASS;
    if (!secretHanPass) return res.status(500).json({ error: "Missing HANLOCK_PASS" });

    const encrypted = encodeWithPassword(data, secretHanPass);
    res.status(200).send(encrypted);
  } catch (err: any) {
    res.status(500).json({ error: err.message || "Failed to hanlock encrypt" });
  }
});

app.post(
  "/han_decrypt",
  gate("reveal", "hanDecrypt", () => ({})),
  async (req: Request, res: Response) => {
  try {
    const { data } = req.body;
    if (!data) return res.status(400).json({ error: "Missing data" });

    const secretHanPass = process.env.HANLOCK_PASS;
    if (!secretHanPass) return res.status(500).json({ error: "Missing HANLOCK_PASS" });

    const decrypted = decodeWithPassword(data, secretHanPass);
    res.status(200).send(decrypted);
  } catch (err: any) {
    res.status(500).json({ error: err.message || "Failed to hanlock decrypt" });
  }
});

// Tolerant SOL DB rows collector.
// Walks signatures for the tablePda (which receives all writes + management txs),
// then only includes rows from txs that successfully decode as db_code_in / db_instruction_code_in via the SDK.
// This avoids RangeError / borsh decode crashes on non-row txs that happen to touch the table account
// (common for apps like blockchan that create many threads under the same root).
async function tolerantSolDbRows(solanaIqlabs: any, tablePda: string, options: any = {}): Promise<any[]> {
  const desiredLimit = options.limit ?? 50;
  const before = options.before;
  const speed = options.speed ?? "light";

  // Properly support cursor "before" by fetching sig pages starting from the before point.
  // This fixes pagination when the before sig is older than a small cap window.
  const pubkey = new PublicKey(tablePda);
  const pageSize = Math.max(100, desiredLimit * 3);
  let candidates: string[] = [];
  let currentBefore = before || undefined;
  let safety = 0;
  while (candidates.length < desiredLimit * 5 && safety < 10) {
    safety++;
    const page = await solanaConnection.getSignaturesForAddress(pubkey, {
      before: currentBefore,
      limit: pageSize,
    });
    if (page.length === 0) break;
    for (const p of page) {
      candidates.push(p.signature);
    }
    currentBefore = page[page.length - 1].signature;
    if (page.length < pageSize) break;
  }

  // Now process candidates (in order from "newer" to older in this window), but only return up to desiredLimit good rows.
  const rows: any[] = [];
  for (const sig of candidates) {
    if (rows.length >= desiredLimit) break;
    let gotRow = false;

    // Always attempt the robust tx-level extract first (light on RPC for the tx itself, catches all db_code_in variants the metadata helper knows about).
    // This maximizes visibility for BlockChan-style "threads" that may not fully reconstruct via readCodeIn (images, chain links, rate limits, etc.).
    let txForSalvage: any = null;
    try {
      txForSalvage = await solanaConnection.getTransaction(sig, {
        maxSupportedTransactionVersion: 0,
      });
      if (txForSalvage) {
        const metaExtract = extractIQLabsMetadataFromTx(txForSalvage);
        if (metaExtract) {
          let data: string | null = null;
          let cleanedMetadata = metaExtract.metadata || "";
          try {
            const parsed = JSON.parse(cleanedMetadata);
            if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
              if (Object.prototype.hasOwnProperty.call(parsed, "data")) {
                const dataValue = parsed.data;
                delete parsed.data;
                cleanedMetadata = JSON.stringify(parsed);
                if (typeof dataValue === "string") {
                  data = dataValue;
                } else if (dataValue !== undefined && dataValue !== null) {
                  data = JSON.stringify(dataValue);
                }
              }
            }
          } catch {}
          rows.push({ signature: sig, metadata: cleanedMetadata, data: data || null, __salvaged: true, __txSignature: sig });
          gotRow = true;
        }
      }
    } catch {}

    if (!gotRow) {
      // Try full readCodeIn for complete data reconstruction (follows onChainPath for larger posts, etc.)
      try {
        const result = await solanaIqlabs.reader.readCodeIn(sig, speed);
        if (result) {
          const { data, metadata } = result as any;
          if (data) {
            try {
              const parsed = JSON.parse(data);
              if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
                rows.push({ ...parsed, __txSignature: sig });
                gotRow = true;
              }
            } catch {}
            if (!gotRow) {
              rows.push({ signature: sig, metadata, data, __txSignature: sig });
              gotRow = true;
            }
          } else if (metadata) {
            rows.push({ signature: sig, metadata, data: null, __txSignature: sig });
            gotRow = true;
          }
        }
      } catch (e: any) {
        // ignore; we already tried salvage above
      }
    }

    // If we still didn't get anything from this sig, it was a non-row tx that touched the tablePda (create, other op, etc.). Skip silently.
  }

  return rows;
}

// ==================== UNIFIED DB OPERATIONS (chain-aware) ====================
// Single set of endpoints for both chains. Pass "chain": "sol" | "mon" in body/query.

/**
 * Turns a chain error into something a person can act on.
 *
 * Solana reports any rejected instruction as "Transaction simulation failed"
 * and puts the actual reason in the program logs, which the SDK does not
 * include in the message. Without them every failure looks the same.
 */
const describeChainError = (err: any): string => {
  const base = String(err?.message || "The transaction failed");
  const logs: unknown = err?.logs;
  if (!Array.isArray(logs) || logs.length === 0) return base;
  const lines = logs as string[];
  const blamed = lines.filter((l) =>
    /error|failed|insufficient|constraint|unauthorized/i.test(l),
  );
  return [base, ...(blamed.length > 0 ? blamed : lines).slice(-4)].join("\n");
};

/**
 * Below this a Solana account cannot pay rent for anything at all, so the
 * failure is worth naming before simulation rejects it opaquely. Deliberately
 * far under any real cost: this catches an empty wallet, and leaves every
 * genuine judgement about affordability to the chain.
 */
const SOL_DUST_LAMPORTS = 2_000_000; // 0.002 SOL

/**
 * Attaches the transaction signer to each row, as `__signer`.
 *
 * Who signed a row is the only trustworthy statement of who wrote it. A row's
 * own fields are written by whoever sent the transaction and can claim
 * anything; the signature cannot. This is what lets a reader tell a keeper's
 * own proof-of-life from a row a stranger wrote into the same table — which
 * matters for any table created without a writer list, since those accept a
 * row from anybody.
 *
 * Costs one transaction fetch per distinct signature, so it is opt-in rather
 * than always-on. Rows whose signature cannot be resolved get a null signer
 * and are left for the caller to judge; guessing would defeat the point.
 */
const attachSigners = async (
  rows: any[],
  chain: "sol" | "mon",
): Promise<any[]> => {
  if (!Array.isArray(rows) || rows.length === 0) return rows;

  const signatureOf = (row: any): string =>
    String(row?.__txSignature ?? row?.signature ?? row?.txHash ?? "").trim();

  // One lookup per signature: a chunked write puts many rows behind one.
  const cache = new Map<string, string | null>();
  const provider = chain === "mon" ? new JsonRpcProvider(monadRpcUrl) : null;

  for (const row of rows) {
    const signature = signatureOf(row);
    if (!signature) continue;
    if (!cache.has(signature)) {
      let signer: string | null = null;
      try {
        if (chain === "mon") {
          signer = (await provider!.getTransaction(signature))?.from ?? null;
        } else {
          const tx = await solanaConnection.getTransaction(signature, {
            maxSupportedTransactionVersion: 0,
          });
          // The fee payer is the first static key, and is always a signer.
          signer =
            tx?.transaction.message.getAccountKeys().staticAccountKeys[0]?.toBase58() ?? null;
        }
      } catch {
        signer = null;
      }
      cache.set(signature, signer);
    }
    row.__signer = cache.get(signature) ?? null;
  }

  return rows;
};

/**
 * Makes sure a Solana db_root account exists before anything hangs off it.
 *
 * The two SDKs differ here and the difference is invisible until it bites:
 * Monad's writer initialises the root itself, while Solana's createTable throws
 * "db_root not found" and creates nothing. So the same app builds fine on MON
 * and fails on SOL. Levelling it here keeps that out of every app.
 *
 * Idempotent, and it never touches a root that already exists — including one
 * somebody else created, which stays theirs.
 */
const ensureSolanaDbRoot = async (
  signer: Keypair,
  dbRootId: string,
): Promise<{ created: boolean; address: string; signature?: string }> => {
  const seed = solanaIqlabs.utils.toSeedBytes(dbRootId);
  const address = solanaIqlabs.contract.getDbRootPda(seed);

  const existing = await solanaConnection.getAccountInfo(address);
  if (existing) return { created: false, address: address.toBase58() };

  const builder = solanaIqlabs.contract.createInstructionBuilder();
  const instruction = solanaIqlabs.contract.initializeDbRootInstruction(
    builder,
    {
      db_root: address,
      signer: signer.publicKey,
      system_program: SystemProgram.programId,
    },
    { db_root_id: seed },
  );

  const signature = await sendAndConfirmTransaction(
    solanaConnection,
    new Transaction().add(instruction),
    [signer],
    { commitment: "confirmed" },
  );
  return { created: true, address: address.toBase58(), signature };
};

// --- createTable (unified) ---
app.post(
  "/db/createTable",
  gateSpend("createTable", (req) => ({
    chain: getNormalizedChain(req.body?.chain ?? "sol"),
    dbRootId: req.body?.dbRootId ?? null,
    tableName: req.body?.tableName ?? req.body?.tableSeed ?? null,
  })),
  (req: Request, res: Response) => {
  const body = req.body as any;
  const { chain = "sol", dbRootId } = body;

  let normalizedChain: "sol" | "mon";
  try {
    normalizedChain = getNormalizedChain(chain);
  } catch (e: any) {
    return res.status(400).json({ error: e.message });
  }

  if (!dbRootId) {
    return res.status(400).json({ error: "Missing required field: dbRootId" });
  }

  const jobId = `job_${Date.now()}_${jobCounter++}`;
  jobs.set(jobId, { progress: 0, status: "pending" });

  (async () => {
    try {
      if (normalizedChain === "mon") {
        // ==================== MONAD path ====================
        const {
          tableName,
          columns,
          idCol,
          extKeys = [],
          gate,
          writers = [],
          isPrivate = false,
        } = body;

        if (!tableName || !columns || !idCol) {
          throw new Error("MON createTable requires: tableName, columns (array), idCol");
        }

        const monPrivateKey = process.env.MON_SIGNER_PRIVATE_KEY;
        if (!monPrivateKey) throw new Error("Missing MON_SIGNER_PRIVATE_KEY in .env");

        const network = "monad";
        const rpc = monadRpcUrl;
        ethIqlabs.setNetwork(network, rpc);

        const provider = new JsonRpcProvider(rpc);
        const signer = new Wallet(monPrivateKey, provider);

        console.log(`[MON][createTable] Signer: ${signer.address} dbRoot="${dbRootId}" table="${tableName}"`);

        await ethIqlabs.assertChainMatches(signer);

        // Auto-initialize DbRoot if necessary (check via getTablelistFromRoot)
        let alreadyInitialized = false;
        try {
          const list = await ethIqlabs.reader.getTablelistFromRoot(dbRootId.trim());
          if (list && list.creator) {
            alreadyInitialized = true;
          }
        } catch {
          // not initialized yet
        }

        if (!alreadyInitialized) {
          console.log(`[MON] Auto-initializing DbRoot "${dbRootId}"...`);
          await ethIqlabs.writer.initializeDbRoot(signer, dbRootId.trim());
          await new Promise(r => setTimeout(r, 1500));
        }

        const gateParam = gate
          ? {
              tokenAddress: gate.tokenAddress,
              amount: gate.amount !== undefined ? (typeof gate.amount === "string" ? BigInt(gate.amount) : gate.amount) : undefined,
              gateType: gate.gateType,
            }
          : undefined;

        const txHash = await ethIqlabs.writer.createTable(
          signer,
          dbRootId.trim(),
          tableName.trim(),
          columns,
          idCol.trim(),
          extKeys.length ? extKeys : undefined,
          gateParam,
          writers.length ? writers : undefined,
          isPrivate,
        );

        const job = jobs.get(jobId);
        if (job) {
          job.status = "completed";
          job.result = { txHash, dbRootId: dbRootId.trim(), tableName: tableName.trim(), chain: "mon", isPrivate };
          job.progress = 100;
        }
      } else {
        // ==================== SOLANA path ====================
        const {
          tableSeed,
          tableName,
          columnNames,
          idCol,
          extKeys = [],
          gate,
          writers = [],
          tableHint,
        } = body;

        if (!tableSeed || !tableName || !columnNames || !idCol || !tableHint) {
          throw new Error("SOL createTable requires: tableSeed, tableName, columnNames (array), idCol, tableHint");
        }

        const secretKeyEnv = process.env.SOLANA_SIGNER_PRIVATE_KEY;
        if (!secretKeyEnv) throw new Error("Missing SOLANA_SIGNER_PRIVATE_KEY in .env");

        const secretKey = bs58.decode(secretKeyEnv);
        const signer = Keypair.fromSecretKey(secretKey);

        console.log(`[SOL][createTable] Signer: ${signer.publicKey.toBase58()} dbRoot="${dbRootId}" tableHint="${tableHint}"`);

        const lamports = await solanaConnection.getBalance(signer.publicKey);
        if (lamports < SOL_DUST_LAMPORTS) {
          throw new Error(
            `The Solana wallet ${signer.publicKey.toBase58()} holds ` +
              `${(lamports / 1e9).toFixed(6)} SOL. Creating a table pays rent for ` +
              `several accounts, so fund it before trying again.`,
          );
        }

        // Solana will not create this for us the way Monad does.
        const root = await ensureSolanaDbRoot(signer, String(dbRootId).trim());
        if (root.created) {
          console.log(`[SOL] Initialised db_root "${dbRootId}" at ${root.address}`);
          // Let it land before a table tries to reference it.
          await new Promise((r) => setTimeout(r, 1500));
        }

        // Convert gate.mint and writers to PublicKey if strings provided
        let gateForCall: any = undefined;
        if (gate && gate.mint) {
          gateForCall = {
            mint: typeof gate.mint === "string" ? new PublicKey(gate.mint) : gate.mint,
            amount: gate.amount,
            gateType: gate.gateType,
          };
        }

        let writersForCall: PublicKey[] | undefined;
        if (Array.isArray(writers) && writers.length > 0) {
          writersForCall = writers.map((w: any) => (typeof w === "string" ? new PublicKey(w) : w));
        }

        const txSignature = await solanaIqlabs.writer.createTable(
          solanaConnection,
          signer,
          dbRootId,
          tableSeed,
          tableName,
          columnNames,
          idCol,
          extKeys,
          gateForCall,
          writersForCall,
          tableHint,
        );

        const job = jobs.get(jobId);
        if (job) {
          job.status = "completed";
          job.result = {
            signature: txSignature,
            dbRootId: String(dbRootId),
            tableHint,
            tableName: String(tableName),
            chain: "sol",
            // A root costs rent, so say when one was paid for.
            rootCreated: root.created,
            rootAddress: root.address,
          };
          job.progress = 100;
        }
      }
    } catch (err: any) {
      console.error(`[${normalizedChain.toUpperCase()}] createTable error:`, err);
      const job = jobs.get(jobId);
      if (job) {
        job.status = "error";
        job.error = describeChainError(err) || `Failed to create table on ${normalizedChain}`;
      }
    }
  })();

  res.json({ jobId });
});

// --- writeRow ---
app.post(
  "/db/writeRow",
  gateSpend("writeRow", (req) => ({
    chain: getNormalizedChain(req.body?.chain ?? "sol"),
    dbRootId: req.body?.dbRootId ?? null,
    tableName: req.body?.tableName ?? req.body?.tableSeed ?? null,
    bytes: typeof req.body?.rowJson === "string" ? Buffer.byteLength(req.body.rowJson, "utf8") : 0,
  })),
  (req: Request, res: Response) => {
  const body = req.body as any;
  const { chain = "sol", dbRootId, rowJson } = body;

  let normalizedChain: "sol" | "mon";
  try {
    normalizedChain = getNormalizedChain(chain);
  } catch (e: any) {
    return res.status(400).json({ error: e.message });
  }

  if (!dbRootId || !rowJson) {
    return res.status(400).json({ error: "Missing required: dbRootId, rowJson" });
  }

  const jobId = `job_${Date.now()}_${jobCounter++}`;
  jobs.set(jobId, { progress: 0, status: "pending" });

  (async () => {
    try {
      if (normalizedChain === "mon") {
        const { tableName } = body;
        if (!tableName) throw new Error("MON writeRow requires tableName");

        const monPrivateKey = process.env.MON_SIGNER_PRIVATE_KEY;
        if (!monPrivateKey) throw new Error("Missing MON_SIGNER_PRIVATE_KEY in .env");

        const network = "monad";
        const rpc = monadRpcUrl;
        ethIqlabs.setNetwork(network, rpc);

        const provider = new JsonRpcProvider(rpc);
        const signer = new Wallet(monPrivateKey, provider);

        console.log(`[MON][writeRow] Signer: ${signer.address} db="${dbRootId}" table="${tableName}"`);

        await ethIqlabs.assertChainMatches(signer);

        const txHash = await ethIqlabs.writer.writeRow(
          signer,
          dbRootId.trim(),
          tableName.trim(),
          rowJson,
          (percent: number) => {
            const job = jobs.get(jobId);
            if (job) job.progress = percent;
          },
        );

        const job = jobs.get(jobId);
        if (job) {
          job.status = "completed";
          job.result = { txHash, dbRootId: dbRootId.trim(), tableName: tableName.trim(), chain: "mon" };
          job.progress = 100;
        }
      } else {
        const { tableSeed } = body;
        if (!tableSeed) throw new Error("SOL writeRow requires tableSeed");

        const secretKeyEnv = process.env.SOLANA_SIGNER_PRIVATE_KEY;
        if (!secretKeyEnv) throw new Error("Missing SOLANA_SIGNER_PRIVATE_KEY in .env");

        const secretKey = bs58.decode(secretKeyEnv);
        const signer = Keypair.fromSecretKey(secretKey);

        console.log(`[SOL][writeRow] Signer: ${signer.publicKey.toBase58()} db="${dbRootId}" seed="${tableSeed}"`);

        const txSignature = await solanaIqlabs.writer.writeRow(
          solanaConnection,
          signer,
          dbRootId,
          tableSeed,
          rowJson,
          body.skipConfirmation ?? false,
        );

        const job = jobs.get(jobId);
        if (job) {
          job.status = "completed";
          job.result = { signature: txSignature, dbRootId: String(dbRootId), tableSeed: String(tableSeed), chain: "sol" };
          job.progress = 100;
        }
      }
    } catch (err: any) {
      console.error(`[${normalizedChain.toUpperCase()}] writeRow error:`, err);
      const job = jobs.get(jobId);
      if (job) {
        job.status = "error";
        job.error = describeChainError(err) || `Failed to write row on ${normalizedChain}`;
      }
    }
  })();

  res.json({ jobId });
});

// --- readTableRows ---
app.get(
  "/db/readTableRows",
  gate("read", "readTableRows", (req) => ({
    chain: getNormalizedChain((req.query.chain as string) ?? "sol"),
    dbRootId: req.query.dbRootId ?? null,
    tableName: req.query.tableName ?? req.query.account ?? null,
  })),
 async (req: Request, res: Response) => {
  const query = req.query as any;
  const { chain = "sol", dbRootId, tableName, tablePda, limit, before, speed, signatures } = query;
  // Opt-in: resolving signers costs a transaction fetch per signature.
  const wantSigners = String(query.withSigners ?? "").toLowerCase() === "true";

  let normalizedChain: "sol" | "mon";
  try {
    normalizedChain = getNormalizedChain(chain);
  } catch (e: any) {
    return res.status(400).json({ error: e.message });
  }

  const jobId = `job_${Date.now()}_${jobCounter++}`;
  jobs.set(jobId, { progress: 0, status: "pending" });

  (async () => {
    try {
      if (normalizedChain === "mon") {
        if (!dbRootId || !tableName) {
          throw new Error("MON readTableRows requires query params: dbRootId, tableName");
        }

        const network = "monad";
        const rpc = monadRpcUrl;
        ethIqlabs.setNetwork(network, rpc);

        const options = limit ? { limit: parseInt(limit, 10) } : undefined;

        console.log(`[MON][readTableRows] db="${dbRootId}" table="${tableName}" limit=${limit || "all"}`);

        let rows = await ethIqlabs.reader.readTableRows(dbRootId.trim(), tableName.trim(), options);
        if (wantSigners) rows = await attachSigners(rows as any[], "mon");

        const job = jobs.get(jobId);
        if (job) {
          job.status = "completed";
          job.result = { rows, count: rows?.length ?? 0, dbRootId: dbRootId.trim(), tableName: tableName.trim(), chain: "mon" };
          job.progress = 100;
        }
      } else {
        if (!tablePda) {
          throw new Error("SOL readTableRows requires query param: tablePda");
        }

        const options: any = {};
        if (limit) options.limit = parseInt(limit, 10);
        if (before) options.before = before;
        if (speed) options.speed = speed;
        if (signatures) {
          try { options.signatures = JSON.parse(signatures); } catch { options.signatures = String(signatures).split(",").map(s => s.trim()); }
        }
        // Default to a reasonable small page for browser UX + to avoid huge history on active tables like blockchan
        if (!options.limit) options.limit = 50;

        console.log(`[SOL][readTableRows] tablePda=${tablePda} options=${JSON.stringify(options)}`);

        let rows: any[] = [];
        try {
          rows = await solanaIqlabs.reader.readTableRows(tablePda, options);
        } catch (sdkErr: any) {
          // Some tables (e.g. blockchan) have mixed tx history on the tablePda (creates, other ops, db_code_in rows).
          // The SDK reader can hit decode errors on non-row txs (borsh layout mismatch in instruction data).
          // Fall back to a tolerant collector: walk sigs and only keep ones that successfully decode as DB rows via readCodeIn.
          console.warn(`[SOL] readTableRows SDK error for ${tablePda}, using tolerant collector: ${sdkErr.message}`);
          rows = await tolerantSolDbRows(solanaIqlabs, tablePda, options);
        }

        if (wantSigners) rows = await attachSigners(rows as any[], "sol");

        const job = jobs.get(jobId);
        if (job) {
          job.status = "completed";
          job.result = { rows, count: rows?.length ?? 0, tablePda, chain: "sol" };
          job.progress = 100;
        }
      }
    } catch (err: any) {
      console.error(`[${normalizedChain.toUpperCase()}] readTableRows error:`, err);
      const job = jobs.get(jobId);
      if (job) {
        job.status = "error";
        job.error = err.message || `Failed to read table rows on ${normalizedChain}`;
      }
    }
  })();

  res.json({ jobId });
});

// --- getTablelistFromRoot ---
app.get(
  "/db/getTablelistFromRoot",
  gate("read", "listTables", (req) => ({
    chain: getNormalizedChain((req.query.chain as string) ?? "sol"),
    dbRootId: req.query.dbRootId ?? null,
  })),
 async (req: Request, res: Response) => {
  const { chain = "sol", dbRootId } = req.query as { chain?: string; dbRootId?: string };

  let normalizedChain: "sol" | "mon";
  try {
    normalizedChain = getNormalizedChain(chain);
  } catch (e: any) {
    return res.status(400).json({ error: e.message });
  }

  if (!dbRootId) {
    return res.status(400).json({ error: "Missing query param: dbRootId" });
  }

  const jobId = `job_${Date.now()}_${jobCounter++}`;
  jobs.set(jobId, { progress: 0, status: "pending" });

  (async () => {
    try {
      if (normalizedChain === "mon") {
        const network = "monad";
        const rpc = monadRpcUrl;
        ethIqlabs.setNetwork(network, rpc);

        console.log(`[MON][getTablelistFromRoot] dbRootId="${dbRootId}"`);

        const list = await ethIqlabs.reader.getTablelistFromRoot(dbRootId.trim());

        const job = jobs.get(jobId);
        if (job) {
          job.status = "completed";
          job.result = { ...list, chain: "mon" };
          job.progress = 100;
        }
      } else {
        console.log(`[SOL][getTablelistFromRoot] dbRootId="${dbRootId}"`);

        const list = await solanaIqlabs.reader.getTablelistFromRoot(solanaConnection, dbRootId);

        // Compute tablePdas for convenience so clients can directly use them in readTableRows without deriving PDAs themselves.
        // For BlockChan-style apps, the globalTableSeeds include the thread tables (po/thread/...) .
        // Use 'any' for enhancedList because the SDK's TableList type is closed and we are adding parallel pda arrays.
        let enhancedList: any = { ...list, chain: "sol" };
        try {
          const dbRootPda = list.rootPda instanceof PublicKey ? list.rootPda : new PublicKey(list.rootPda);
          if (list.tableSeeds && Array.isArray(list.tableSeeds)) {
            enhancedList.tablePdas = list.tableSeeds.map((seedHex: string) => {
              const raw = Buffer.from(seedHex, "hex");
              const name = raw.toString();
              const seedB = solanaIqlabs.utils.toSeedBytes(name);
              const pda = solanaIqlabs.contract.getTablePda(dbRootPda, seedB);
              return pda.toBase58();
            });
          }
          if (list.globalTableSeeds && Array.isArray(list.globalTableSeeds)) {
            enhancedList.globalTablePdas = list.globalTableSeeds.map((seedHex: string) => {
              const raw = Buffer.from(seedHex, "hex");
              const name = raw.toString();
              const seedB = solanaIqlabs.utils.toSeedBytes(name);
              const pda = solanaIqlabs.contract.getTablePda(dbRootPda, seedB);
              return pda.toBase58();
            });
          }
        } catch (e: any) {
          console.warn("[SOL] Failed to compute some tablePdas for list:", e.message);
        }

        const job = jobs.get(jobId);
        if (job) {
          job.status = "completed";
          job.result = enhancedList;
          job.progress = 100;
        }
      }
    } catch (err: any) {
      console.error(`[${normalizedChain.toUpperCase()}] getTablelistFromRoot error:`, err);
      const job = jobs.get(jobId);
      if (job) {
        job.status = "error";
        job.error = err.message || `Failed to get table list from root on ${normalizedChain}`;
      }
    }
  })();

  res.json({ jobId });
});


// Loopback only. This process signs with real funds and must never be
// reachable from another machine.
const server = app.listen(PORT, "127.0.0.1", () => {
  const actual = (server.address() as AddressInfo).port;
  console.log(`IQ sidecar listening on http://127.0.0.1:${actual}`);
  if (standalone) {
    console.log("No --token supplied; running standalone for development.");
    console.log(`Control token: ${hostToken.token}`);
  }
  // Machine-readable handshake line, in case a host prefers to read stdout
  // rather than poll /health.
  console.log(`IQ_SIDECAR_READY ${JSON.stringify({ port: actual, pid: process.pid })}`);
});

// The host publishes a discovery file pointing at us. Remove it on the way
// out so an app started later does not chase a dead port.
const discoveryFile = argOf("discovery-file");
const clearDiscoveryFile = () => {
  if (!discoveryFile) return;
  try {
    unlinkSync(discoveryFile);
  } catch {
    // Already gone, or never written. Nothing to do.
  }
};

// If GodOnChain dies without reaping us, don't linger holding signing keys.
const parentPid = Number(argOf("parent-pid") ?? 0);
if (parentPid > 0) {
  const watchdog = setInterval(() => {
    try {
      process.kill(parentPid, 0);
    } catch {
      console.log("Host process is gone; shutting down.");
      clearDiscoveryFile();
      denyAllApprovals();
      process.exit(0);
    }
  }, 2000);
  watchdog.unref();
}

const shutdown = (signal: string) => {
  console.log(`Received ${signal}; shutting down.`);
  clearDiscoveryFile();
  denyAllApprovals();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
};
process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
