/**
 * timelock.ts — Rivest–Shamir–Wagner time-lock puzzles.
 *
 * Seals a secret behind work that cannot be parallelised. Recovering it means
 * computing y = x^(2^t) mod N by performing t squarings *in sequence*: each one
 * needs the previous result, so a thousand machines are no faster than one.
 *
 * The creator cheats legitimately. Knowing φ(N) = (p-1)(q-1) they reduce the
 * exponent first — e = 2^t mod φ(N) — and get y in milliseconds. **p and q are
 * then discarded and never leave this function.** They are the trapdoor; if
 * they were ever written down the puzzle would be worthless, and everything
 * this app produces is published permanently.
 *
 * What this does and does not buy you:
 *
 *   It buys real work. Nobody reads the secret without spending the CPU.
 *
 *   It does not buy an accurate date. The difficulty is fixed at creation
 *   against today's hardware, and faster hardware simply arrives sooner. Treat
 *   the duration as a floor for an ordinary machine, not a deadline — a tuned
 *   C implementation is roughly 20x this runtime, and dedicated hardware more.
 *
 *   Its clock starts when the puzzle is *made*, not when anything expires.
 *   Anyone can begin solving the moment it is published.
 */

import {
  createCipheriv,
  createDecipheriv,
  createHash,
  generateKeyPairSync,
  randomBytes,
} from "crypto";

/** 2048 bits: factoring it is the only shortcut, and that is the point. */
const MODULUS_BITS = 2048;

/**
 * Squarings per yield. Big enough that the bookkeeping is noise, small enough
 * that the HTTP server stays responsive while a solve is running — a solve can
 * last days, and a sidecar that stops answering for that long is broken.
 */
const CHUNK = 25_000;

export interface Puzzle {
  /** Modulus, base and squaring count. Everything needed to solve it. */
  n: string;
  x: string;
  t: string;
  /** The secret, encrypted under a key derived from the answer. */
  iv: string;
  ciphertext: string;
  tag: string;
  /** What the duration was calibrated against, for honest display. */
  createdAt: number;
  estimatedSeconds: number;
  calibratedRate: number;
}

const bytesToBigInt = (b: Buffer): bigint =>
  b.length === 0 ? 0n : BigInt("0x" + b.toString("hex"));

const base64urlToBigInt = (s: string): bigint =>
  bytesToBigInt(Buffer.from(s, "base64url"));

/** Fixed-width so the key derivation is unambiguous. */
const bigIntToBytes = (v: bigint, byteLength: number): Buffer => {
  let hex = v.toString(16);
  if (hex.length > byteLength * 2) hex = hex.slice(-byteLength * 2);
  return Buffer.from(hex.padStart(byteLength * 2, "0"), "hex");
};

/** Square-and-multiply. Only ever used with the trapdoor in hand. */
function modPow(base: bigint, exponent: bigint, modulus: bigint): bigint {
  let result = 1n;
  let b = base % modulus;
  let e = exponent;
  while (e > 0n) {
    if (e & 1n) result = (result * b) % modulus;
    b = (b * b) % modulus;
    e >>= 1n;
  }
  return result;
}

/** The answer becomes an AES key, so a wrong answer fails loudly. */
const keyFromAnswer = (y: bigint, byteLength: number): Buffer =>
  createHash("sha256").update(bigIntToBytes(y, byteLength)).digest();

/**
 * Measures this machine's sequential squaring rate. Used to turn a requested
 * duration into a squaring count, and reported back so the caller can say what
 * the number was based on rather than pretending it is a guarantee.
 */
export function benchmark(milliseconds = 250): number {
  const { privateKey } = generateKeyPairSync("rsa", { modulusLength: MODULUS_BITS });
  const jwk = privateKey.export({ format: "jwk" }) as { n: string };
  const n = base64urlToBigInt(jwk.n);

  let x = 3n;
  let count = 0;
  const started = Date.now();
  while (Date.now() - started < milliseconds) {
    for (let i = 0; i < 2000; i++) x = (x * x) % n;
    count += 2000;
  }
  const elapsed = (Date.now() - started) / 1000;
  return Math.max(1, Math.round(count / elapsed));
}

/**
 * Builds a puzzle that takes roughly `seconds` of sequential work on a machine
 * like this one, and seals `secret` behind it.
 */
export function create(secret: Buffer, seconds: number, rate?: number): Puzzle {
  if (secret.length === 0) throw new Error("Nothing to lock");
  if (!Number.isFinite(seconds) || seconds <= 0) throw new Error("Duration must be positive");

  const measured = rate && rate > 0 ? rate : benchmark();
  const t = BigInt(Math.max(1, Math.round(measured * seconds)));

  const { privateKey } = generateKeyPairSync("rsa", { modulusLength: MODULUS_BITS });
  const jwk = privateKey.export({ format: "jwk" }) as { n: string; p: string; q: string };

  const n = base64urlToBigInt(jwk.n);
  const p = base64urlToBigInt(jwk.p);
  const q = base64urlToBigInt(jwk.q);

  const x = (bytesToBigInt(randomBytes(32)) % (n - 3n)) + 2n;

  // The trapdoor: reduce the exponent modulo φ(N) and skip the whole climb.
  const phi = (p - 1n) * (q - 1n);
  const y = modPow(x, modPow(2n, t, phi), n);

  const byteLength = Math.ceil(n.toString(16).length / 2);
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", keyFromAnswer(y, byteLength), iv);
  const ciphertext = Buffer.concat([cipher.update(secret), cipher.final()]);

  // p, q and phi go out of scope here and are never returned, logged or stored.
  return {
    n: n.toString(16),
    x: x.toString(16),
    t: t.toString(),
    iv: iv.toString("hex"),
    ciphertext: ciphertext.toString("hex"),
    tag: cipher.getAuthTag().toString("hex"),
    createdAt: Math.floor(Date.now() / 1000),
    estimatedSeconds: Math.round(seconds),
    calibratedRate: measured,
  };
}

/**
 * Does the work. There is no shortcut here — this is the honest climb, one
 * squaring at a time, yielding periodically so the server keeps answering.
 *
 * `onProgress` receives 0-100.
 */
export async function solve(
  puzzle: Puzzle,
  onProgress?: (percent: number) => void,
): Promise<Buffer> {
  const n = BigInt("0x" + puzzle.n);
  const t = BigInt(puzzle.t);
  let y = BigInt("0x" + puzzle.x);

  let done = 0n;
  while (done < t) {
    const step = t - done < BigInt(CHUNK) ? t - done : BigInt(CHUNK);
    for (let i = 0n; i < step; i++) y = (y * y) % n;
    done += step;

    if (onProgress) onProgress(Number((done * 100n) / t));
    // Hand the event loop back so /progress and /health keep responding.
    await new Promise((resolve) => setImmediate(resolve));
  }

  const byteLength = Math.ceil(n.toString(16).length / 2);
  const decipher = createDecipheriv(
    "aes-256-gcm",
    keyFromAnswer(y, byteLength),
    Buffer.from(puzzle.iv, "hex"),
  );
  decipher.setAuthTag(Buffer.from(puzzle.tag, "hex"));

  // GCM authenticates, so a wrong answer throws rather than returning noise.
  return Buffer.concat([
    decipher.update(Buffer.from(puzzle.ciphertext, "hex")),
    decipher.final(),
  ]);
}


/** Rejects anything that is not a puzzle before a caller waits days on it. */
export function isPuzzle(value: any): value is Puzzle {
  return (
    !!value &&
    typeof value.n === "string" &&
    typeof value.x === "string" &&
    typeof value.t === "string" &&
    typeof value.iv === "string" &&
    typeof value.ciphertext === "string" &&
    typeof value.tag === "string"
  );
}
