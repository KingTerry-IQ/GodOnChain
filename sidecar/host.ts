/**
 * host.ts — token auth, scope enforcement and the write-approval broker.
 *
 * The sidecar holds funded signers, and GodOnChain launches arbitrary
 * downloaded .pck apps that can reach it over loopback. So every caller
 * carries a token, and only the host's own token may spend without asking.
 *
 * Scope model:
 *   read    — /read, /metadata, /db/*, /han_* . No key material, no cost.
 *   write   — /write and DB writers. Spends from the configured signer.
 *   control — /control/* . Held only by the host process.
 *
 * A caller without `write` does not get rejected outright: the request parks
 * as a pending approval, the host prompts the user, and the original request
 * proceeds or fails on their answer. The caller's protocol never changes —
 * it polls /progress exactly as before.
 */

import type { Request, Response, NextFunction } from "express";
import { randomBytes, timingSafeEqual } from "crypto";

export type Scope = "read" | "write" | "reveal" | "control";

export interface TokenRecord {
  id: string;
  token: string;
  label: string;
  scopes: Set<Scope>;
  createdAt: number;
}

export interface PendingApproval {
  id: string;
  tokenId: string;
  label: string;
  scope: Scope;
  action: string;
  details: Record<string, unknown>;
  createdAt: number;
  resolve: (allowed: boolean) => void;
  timer: NodeJS.Timeout;
}

/** How long a prompt waits for the user before it gives up and denies. */
const APPROVAL_TIMEOUT_MS = 5 * 60 * 1000;

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

export function registerToken(
  label: string,
  scopes: Scope[],
  presetToken?: string,
): TokenRecord {
  const record: TokenRecord = {
    id: nextId("tok"),
    token: presetToken ?? newToken(),
    label,
    scopes: new Set(scopes),
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

  if (allowed && remember) {
    tokens.get(record.tokenId)?.scopes.add(record.scope);
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
