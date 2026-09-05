/**
 * host.ts — token auth, scope enforcement and the write-approval broker.
 *
 * The sidecar holds funded signers, and GodOnChain launches arbitrary
 * downloaded .pck apps that can reach it over loopback. So every caller
 * carries a token, and only the host's own token may spend without asking.
 *
 * Scope model. A scope is a *standing grant*, not a capability: holding one
 * means "never ask me about this kind again", and lacking one means "ask".
 *
 *   read    — reads chain data or discloses the wallet. Costs nothing, but
 *             says what the user is looking at and whose records.
 *   write   — spends from the configured signer.
 *   reveal  — opens something addressed to the user's identity key.
 *   control — /control/* . Held only by the host process.
 *
 * The three are answered and remembered separately, because they are separate
 * questions: letting an app watch a covenant is not letting it spend, and an
 * app allowed to spend has not thereby been allowed to read your mail.
 *
 * A caller without the scope is not rejected outright: the request parks as a
 * pending approval, the host prompts the user, and the original request
 * proceeds or fails on their answer. The caller's protocol never changes — it
 * polls /progress exactly as before.
 *
 * Purely local work is not gated at all: /timelock/* is arithmetic, /han_* is
 * crypto over a payload the caller supplied, and /progress polls a job that
 * was already approved. Prompting for those would teach people to click
 * through prompts, which is how a real one gets waved past.
 */

import type { Request, Response, NextFunction } from "express";
import { randomBytes, timingSafeEqual } from "crypto";

export type Scope = "read" | "write" | "reveal" | "control";

export interface TokenRecord {
  id: string;
  token: string;
  label: string;
  /** Standing grants: these kinds proceed without asking. */
  scopes: Set<Scope>;
  /**
   * Standing refusals: these kinds fail immediately without asking.
   *
   * Needed because a refusal has to be as durable as a grant. An app that is
   * told no mid-refresh will fire its remaining reads regardless, and without
   * this the user answers the same question once per read.
   */
  blocked: Set<Scope>;
  /**
   * Whether the label is this app's own claim about itself.
   *
   * A token GodOnChain minted while launching something carries a name the
   * host chose. A token an app asked for carries whatever the app said — which
   * could be anything, including another app's name. The prompt has to be able
   * to tell the user which kind it is looking at, or a self-chosen name would
   * borrow the trust of a host-assigned one.
   */
  declared: boolean;
  createdAt: number;
}

export interface PendingApproval {
  id: string;
  tokenId: string;
  label: string;
  /** Whether that label is the app's own claim. See TokenRecord.declared. */
  declared: boolean;
  scope: Scope;
  action: string;
  details: Record<string, unknown>;
  createdAt: number;
  resolve: (allowed: boolean) => void;
  timer: NodeJS.Timeout;
}

/**
 * One thing an app asked the sidecar to do.
 *
 * The host shows these as a running log. The point is accountability: this
 * process holds funded keys and serves apps the user downloaded, and without a
 * record the only visible events are the prompts — so everything auto-approved
 * by a standing grant happens silently, which is exactly the traffic worth
 * being able to look at.
 */
export interface ActivityEntry {
  seq: number;
  at: number;
  /** Which app asked. The token's label, so it matches the approval prompt. */
  label: string;
  scope: Scope;
  action: string;
  chain: string;
  /** Encoded payload size, for the ones that spend. 0 when not applicable. */
  bytes: number;
  /** "allowed" after a prompt, "granted" by a standing grant, and so on. */
  outcome: "allowed" | "granted" | "denied" | "blocked";
  /** Table, root or signature — whatever names the thing being touched. */
  subject: string;
}

/** How long a prompt waits for the user before it gives up and denies. */
const APPROVAL_TIMEOUT_MS = 5 * 60 * 1000;

/**
 * Kept in memory and capped. A log that grows without bound in a process
 * holding wallet keys is a slow leak; a log the user can scroll for the last
 * few hundred operations is the useful part of one.
 */
const ACTIVITY_LIMIT = 400;
const activity: ActivityEntry[] = [];
let activitySeq = 0;

export function recordActivity(
  entry: Omit<ActivityEntry, "seq" | "at">,
): ActivityEntry {
  const full: ActivityEntry = { ...entry, seq: ++activitySeq, at: Date.now() };
  activity.push(full);
  if (activity.length > ACTIVITY_LIMIT) activity.splice(0, activity.length - ACTIVITY_LIMIT);
  return full;
}

/**
 * Everything since `after`, oldest first, so a caller can poll incrementally
 * without re-reading what it already has. Passing 0 returns the whole buffer.
 */
export function listActivity(after: number = 0): ActivityEntry[] {
  return after <= 0 ? [...activity] : activity.filter((e) => e.seq > after);
}

const tokens = new Map<string, TokenRecord>();
const pending = new Map<string, PendingApproval>();

let counter = 0;
const nextId = (prefix: string) => `${prefix}_${Date.now()}_${counter++}`;

const newToken = () => randomBytes(32).toString("hex");

/** Constant-time compare so the token can't be recovered by timing the 401s. */
function tokenEquals(a: string, b: string): boolean {
  const ab = Buffer.from(a, "utf8");
  const bb = Buffer.from(b, "utf8");
  if (ab.length !== bb.length) return false;
  return timingSafeEqual(ab, bb);
}

/**
 * Tokens are cheap but not free, and an app can ask for one. Capped so a loop
 * cannot fill memory with names nobody will ever read.
 */
const MAX_TOKENS = 64;

export function registerToken(
  label: string,
  scopes: Scope[],
  presetToken?: string,
  declared: boolean = false,
): TokenRecord | null {
  if (tokens.size >= MAX_TOKENS) return null;
  const record: TokenRecord = {
    id: nextId("tok"),
    token: presetToken ?? newToken(),
    label,
    scopes: new Set(scopes),
    blocked: new Set<Scope>(),
    declared,
    createdAt: Date.now(),
  };
  tokens.set(record.id, record);
  return record;
}

export function revokeToken(id: string): boolean {
  return tokens.delete(id);
}

export function listTokens() {
  return [...tokens.values()].map((t) => ({
    id: t.id,
    label: t.label,
    scopes: [...t.scopes],
    blocked: [...t.blocked],
    declared: t.declared,
    createdAt: t.createdAt,
  }));
}

function findByToken(presented: string): TokenRecord | null {
  for (const record of tokens.values()) {
    if (tokenEquals(record.token, presented)) return record;
  }
  return null;
}

declare global {
  namespace Express {
    interface Request {
      iqToken?: TokenRecord;
    }
  }
}

/** Pulls the bearer token off the request and attaches its record. */
export function authenticate(req: Request, res: Response, next: NextFunction) {
  const header = req.headers.authorization ?? "";
  const presented = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  if (!presented) {
    return res.status(401).json({ error: "Missing bearer token" });
  }
  const record = findByToken(presented);
  if (!record) {
    return res.status(401).json({ error: "Invalid token" });
  }
  req.iqToken = record;
  next();
}

export function requireScope(scope: Scope) {
  return (req: Request, res: Response, next: NextFunction) => {
    if (!req.iqToken?.scopes.has(scope)) {
      return res.status(403).json({ error: `Token lacks '${scope}' scope` });
    }
    next();
  };
}

/**
 * Resolves true if the caller already holds `scope`. Everyone else parks here
 * until the host answers or the prompt times out.
 *
 * Both spending and revealing go through this: they are different powers, but
 * the user's decision is the same shape, and so is the machinery.
 */
export function requestApproval(
  token: TokenRecord,
  scope: Scope,
  action: string,
  details: Record<string, unknown>,
): { approved: Promise<boolean>; approvalId: string | null } {
  if (token.scopes.has(scope)) {
    return { approved: Promise.resolve(true), approvalId: null };
  }
  // A standing refusal answers without troubling the user again.
  if (token.blocked.has(scope)) {
    return { approved: Promise.resolve(false), approvalId: null };
  }

  const id = nextId("apr");
  let resolveFn!: (allowed: boolean) => void;
  const approved = new Promise<boolean>((resolve) => {
    resolveFn = resolve;
  });

  const timer = setTimeout(() => {
    const record = pending.get(id);
    if (record) {
      pending.delete(id);
      record.resolve(false);
    }
  }, APPROVAL_TIMEOUT_MS);
  // Don't hold the event loop open on an unanswered prompt.
  if (typeof timer.unref === "function") timer.unref();

  pending.set(id, {
    id,
    tokenId: token.id,
    label: token.label,
    declared: token.declared,
    scope,
    action,
    details,
    createdAt: Date.now(),
    resolve: resolveFn,
    timer,
  });

  return { approved, approvalId: id };
}

export function listApprovals() {
  return [...pending.values()].map((a) => ({
    id: a.id,
    tokenId: a.tokenId,
    label: a.label,
    declared: a.declared,
    scope: a.scope,
    action: a.action,
    details: a.details,
    createdAt: a.createdAt,
  }));
}

/**
 * Answers a pending prompt. `remember` widens that token's scopes for the rest
 * of the session, so a trusted app isn't re-prompted on every chunk.
 */
export function resolveApproval(
  id: string,
  allowed: boolean,
  remember: boolean,
): boolean {
  const record = pending.get(id);
  if (!record) return false;

  clearTimeout(record.timer);
  pending.delete(id);

  // "Always" cuts both ways, and only ever for the kind that was asked
  // about: allowing an app to read has never allowed it to spend.
  const token = tokens.get(record.tokenId);
  if (token && remember) {
    if (allowed) {
      token.scopes.add(record.scope);
      token.blocked.delete(record.scope);
    } else {
      token.blocked.add(record.scope);
      token.scopes.delete(record.scope);
    }
  }

  record.resolve(allowed);
  return true;
}

/** Denies everything outstanding — used when the host shuts the sidecar down. */
export function denyAllApprovals(): void {
  for (const record of [...pending.values()]) {
    clearTimeout(record.timer);
    pending.delete(record.id);
    record.resolve(false);
  }
}
